import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import UIKit

/// Cloud AI image features via Astria (https://astria.ai). Two ops: "extend"
/// (masked outpaint — the original is preserved by a mask and only the new border
/// is generated) and "edit" (img2img from a free-text instruction). Astria is
/// multipart + asynchronous: POST a prompt, then poll the prompt id until its
/// `images` array is populated, then download. Opt-in: nothing uploads without the
/// user's key. Results are reviewed (Keep/Delete) before being saved.
enum AIExtend {
    static let base = "https://api.astria.ai"

    /// The partner models, each backed by an Astria gallery "tune". The exact tune
    /// ids for these newest versions aren't published, so each has a best-known
    /// default that the user can override in Settings.
    enum AIModel: String, CaseIterable, Identifiable, Sendable {
        case seedream45 = "Seedream 4.5"
        case nanoBanana2 = "Nano Banana 2"
        case nanoBananaPro = "Nano Banana Pro"
        var id: String { rawValue }
        /// Known Astria gallery tune ids (Nano Banana Pro falls back to Nano
        /// Banana 2's tune until its own id is known; override in Settings).
        var fallbackTune: Int {
            switch self {
            case .seedream45:    return 3691308
            case .nanoBanana2:   return 4180298
            case .nanoBananaPro: return 4180298
            }
        }
        var maxLongSide: CGFloat { 2048 }
        fileprivate var tuneKey: String { "photoBrowser.astriaTune.\(rawValue)" }
    }

    /// Output resolution the user picks in the Edit-with-AI sheet. Astria's gallery tunes
    /// reject explicit sizes larger than ~2048 ("use aspect_ratio instead"), so higher
    /// resolution is requested by (a) uploading a larger input where allowed and (b) asking
    /// Astria to super-resolve the result rather than by sending a bigger `w`/`h`.
    enum OutputResolution: String, CaseIterable, Identifiable, Sendable {
        case k1 = "1K", k2 = "2K", k4 = "4K"
        var id: String { rawValue }
        /// Long side (px) of the uploaded input. Capped at 2048 — the tune limit.
        var uploadLongSide: CGFloat { self == .k1 ? 1024 : 2048 }
        /// 4K asks Astria to super-resolve the result (~2×), since we can't upload larger.
        var superResolution: Bool { self == .k4 }
    }

    /// Output shape the user picks. `.original` keeps the source photo's aspect (the prior
    /// behaviour); the others force a fixed ratio that `aspectRatio(_:_:)`'s supported set maps.
    enum OutputAspect: String, CaseIterable, Identifiable, Sendable {
        case original = "Original", square = "1:1", portrait = "4:5", story = "9:16"
        var id: String { rawValue }
        /// Explicit ratio to send, or nil to derive it from the source image's dimensions.
        var ratio: String? {
            switch self {
            case .original: return nil
            case .square:   return "1:1"
            case .portrait: return "4:5"
            case .story:    return "9:16"
            }
        }
    }

    enum AIError: Error { case notConfigured, badImage, network, badResult, server(String) }

    // MARK: - Config

    private static let keyKey = "photoBrowser.astriaKey"
    private static let modelKey = "photoBrowser.astriaModel"
    private static let promptKey = "photoBrowser.astriaPrompt"
    static let defaultPrompt = "Expand this exact photo outward to fill the larger frame, generating realistic new surroundings that seamlessly continue the existing scene. Keep the original subject, framing and details unchanged and sharp. Output one single seamless photograph — no borders, frames, padding, or duplicated copies."

    static var apiKey: String { UserDefaults.standard.string(forKey: keyKey) ?? "" }
    static var isConfigured: Bool { !apiKey.isEmpty }
    static var extendPrompt: String {
        let v = UserDefaults.standard.string(forKey: promptKey) ?? ""
        return v.isEmpty ? defaultPrompt : v
    }
    static var defaultModel: AIModel { AIModel(rawValue: UserDefaults.standard.string(forKey: modelKey) ?? "") ?? .seedream45 }

    static func tuneID(for model: AIModel) -> Int {
        let v = UserDefaults.standard.integer(forKey: model.tuneKey)
        return v > 0 ? v : model.fallbackTune
    }
    static func setTune(_ id: Int, for model: AIModel) {
        UserDefaults.standard.set(id > 0 ? id : model.fallbackTune, forKey: model.tuneKey)
    }
    // Flux tune used for masked outpaint ("Extend with AI"). Editable in Settings.
    private static let fluxKey = "photoBrowser.astriaFluxTune"
    static let defaultFluxTune = 1504944        // Flux1.dev — supports mask_image inpainting
    static var fluxTune: Int {
        let v = UserDefaults.standard.integer(forKey: fluxKey)
        return v > 0 ? v : defaultFluxTune
    }
    static func setFluxTune(_ id: Int) { UserDefaults.standard.set(id > 0 ? id : defaultFluxTune, forKey: fluxKey) }

    static func save(apiKey: String, defaultModel: AIModel, prompt: String) {
        let d = UserDefaults.standard
        d.set(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), forKey: keyKey)
        d.set(defaultModel.rawValue, forKey: modelKey)
        d.set(prompt, forKey: promptKey)
    }

    // MARK: - Generation

    /// Creates a prompt against `model`'s tune (img2img from `imageData`), polls
    /// until Astria finishes, and downloads the result image(s).
    nonisolated static func generate(model: AIModel, prompt: String, imageData: Data,
                                     count: Int, width: Int?, height: Int?,
                                     aspectOverride: String? = nil, superResolution: Bool = false) async -> Result<[Data], AIError> {
        guard isConfigured else { return .failure(.notConfigured) }
        let tune = tuneID(for: model)
        guard let url = URL(string: "\(base)/tunes/\(tune)/prompts") else { return .failure(.server("Bad endpoint URL.")) }

        var fields: [String: String] = [
            "prompt[text]": prompt,
            "prompt[num_images]": String(min(max(count, 1), 8))
        ]
        // An explicit aspect (the user picked a fixed shape) wins; otherwise derive it from
        // the source image so "Original" keeps the photo's proportions.
        if let aspectOverride {
            fields["prompt[aspect_ratio]"] = aspectOverride
        } else if let width, let height {
            fields["prompt[aspect_ratio]"] = aspectRatio(width, height)
        }
        // Note: only `super_resolution` here — the partner gallery tunes (Seedream / Nano
        // Banana) reject `hires_fix` ("not supported on Partner"); that flag is Flux-only and
        // lives on the Extend path instead.
        if superResolution {
            fields["prompt[super_resolution]"] = "true"
        }
        let files: [(name: String, filename: String, mime: String, data: Data)] = [
            ("prompt[input_image]", "input.jpg", "image/jpeg", imageData)
        ]
        return await submit(tune: tune, url: url, fields: fields, files: files)
    }

    /// Masked outpaint via Flux (the "Extend" feature). `imageData` is the original
    /// composited onto the target canvas at the user's chosen position; `maskData`
    /// is white where new scenery should be generated and black over the kept
    /// original. Flux regenerates only the white region, so placement is exact —
    /// this is the real "Generative Expand" behaviour the partner edit models
    /// (Seedream / Nano Banana) can't do because they take no mask.
    nonisolated static func generateOutpaint(prompt: String, imageData: Data, maskData: Data,
                                             width: Int, height: Int) async -> Result<[Data], AIError> {
        guard isConfigured else { return .failure(.notConfigured) }
        let tune = fluxTune
        guard let url = URL(string: "\(base)/tunes/\(tune)/prompts") else { return .failure(.server("Bad endpoint URL.")) }
        let fields: [String: String] = [
            "prompt[text]": prompt,
            "prompt[num_images]": "1",
            "prompt[w]": String((width / 8) * 8),
            "prompt[h]": String((height / 8) * 8),
            "prompt[denoising_strength]": "1.0",
            "prompt[super_resolution]": "true",
            "prompt[hires_fix]": "true"
        ]
        let files: [(name: String, filename: String, mime: String, data: Data)] = [
            ("prompt[input_image]", "input.jpg", "image/jpeg", imageData),
            ("prompt[mask_image]", "mask.png", "image/png", maskData)
        ]
        return await submit(tune: tune, url: url, fields: fields, files: files)
    }

    /// Posts a prompt (multipart), polls until Astria finishes, downloads the image(s).
    private nonisolated static func submit(tune: Int, url: URL, fields: [String: String],
                                           files: [(name: String, filename: String, mime: String, data: Data)]) async -> Result<[Data], AIError> {
        let boundary = "PB-\(UUID().uuidString)"
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        applyAPIHeaders(&req)
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = multipart(fields: fields, files: files, boundary: boundary)

        guard let (data, resp) = try? await URLSession.shared.data(for: req) else { return .failure(.network) }
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            return .failure(.server(message(from: data)))
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = intValue(json["id"]) else { return .failure(.badResult) }

        let urls = await poll(promptID: id, tune: tune)
        guard !urls.isEmpty else { return .failure(.server("Generation timed out or returned no images.")) }
        var out: [Data] = []
        await withTaskGroup(of: Data?.self) { group in
            for u in urls { group.addTask { (try? await URLSession.shared.data(from: u))?.0 } }
            for await d in group { if let d { out.append(d) } }
        }
        return out.isEmpty ? .failure(.network) : .success(out)
    }

    /// Polls the prompt until its `images` array is populated (or it times out).
    private nonisolated static func poll(promptID: Int, tune: Int) async -> [URL] {
        guard let url = URL(string: "\(base)/tunes/\(tune)/prompts/\(promptID)") else { return [] }
        for _ in 0..<80 {                                   // ~4 minutes at 3s
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            var req = URLRequest(url: url)
            applyAPIHeaders(&req)
            guard let (data, _) = try? await URLSession.shared.data(for: req),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let images = json["images"] as? [String], !images.isEmpty { return images.compactMap { URL(string: $0) } }
            if let images = json["images"] as? [[String: Any]] {
                let us = images.compactMap { ($0["url"] as? String).flatMap { URL(string: $0) } }
                if !us.isEmpty { return us }
            }
        }
        return []
    }

    // MARK: - Preparing input + saving results

    /// A photo as an upload JPEG (long side <= `maxPixel`), with its pixel size.
    ///
    /// Rendered as a **tone-mapped SDR sRGB** JPEG. HDR photos otherwise upload with their
    /// HDR gain baked in (the `CGImageSource` thumbnail applies the gain map on modern iOS),
    /// so Astria — which treats the input as ordinary SDR — returns washed-out, over-exposed
    /// results. `CIImage(contentsOf:)` loads the **base SDR image** (gain map *not* applied)
    /// for gain-map HEICs; clamping the extended range then handles PQ/HLG too, and encoding
    /// in sRGB gives a file any service interprets correctly.
    nonisolated static func uploadJPEG(of url: URL, maxPixel: CGFloat) -> (data: Data, width: Int, height: Int)? {
        guard var ci = CIImage(contentsOf: url) else { return uploadJPEGViaThumbnail(of: url, maxPixel: maxPixel) }
        // CIImage(contentsOf:) keeps raw sensor orientation — bake the EXIF orientation in.
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let o = props[kCGImagePropertyOrientation] as? UInt32, o != 1 {
            ci = ci.oriented(forExifOrientation: Int32(o))
        }
        let long = max(ci.extent.width, ci.extent.height)
        if long > maxPixel, long > 0 {
            let s = maxPixel / long
            ci = ci.transformed(by: CGAffineTransform(scaleX: s, y: s))
        }
        // Tone-map HDR headroom (>1) down to SDR range. A hard clamp slams every highlight
        // above 1.0 to flat white (the "washed-out / over-exposed" look); a soft rolloff
        // keeps midtones intact and gently compresses the highlights toward white so their
        // detail survives. Falls back to the old hard clamp if the curve can't be built.
        ci = (softClip(ci) ?? ci.applyingFilter("CIColorClamp")).cropped(to: ci.extent)
        guard !ci.extent.isInfinite, !ci.extent.isNull else { return uploadJPEGViaThumbnail(of: url, maxPixel: maxPixel) }
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let opts: [CIImageRepresentationOption: Any] = [
            CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.92]
        guard let data = PhotoEditorIO.context.jpegRepresentation(of: ci, colorSpace: space, options: opts) else {
            return uploadJPEGViaThumbnail(of: url, maxPixel: maxPixel)
        }
        return (data, Int(ci.extent.width.rounded()), Int(ci.extent.height.rounded()))
    }

    /// Fallback upload encoder (used if the CoreImage path can't load the file): the prior
    /// thumbnail-based route. Doesn't tone-map HDR, but keeps uploads working.
    private nonisolated static func uploadJPEGViaThumbnail(of url: URL, maxPixel: CGFloat) -> (data: Data, width: Int, height: Int)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return uploadJPEG(of: cg, maxPixel: maxPixel)
    }

    nonisolated static func uploadJPEG(of cg: CGImage, maxPixel: CGFloat) -> (data: Data, width: Int, height: Int)? {
        let capped = downscale(cg, maxLongSide: maxPixel)
        guard let data = UIImage(cgImage: capped).jpegData(compressionQuality: 0.92) else { return nil }
        return (data, capped.width, capped.height)
    }

    /// PNG of a (mask) image, downscaled so its long side <= `maxPixel` (kept in
    /// lock-step with the matching input JPEG).
    nonisolated static func pngData(of cg: CGImage, maxPixel: CGFloat) -> Data? {
        UIImage(cgImage: downscale(cg, maxLongSide: maxPixel)).pngData()
    }

    private nonisolated static func downscale(_ cg: CGImage, maxLongSide: CGFloat) -> CGImage {
        let long = CGFloat(max(cg.width, cg.height))
        guard long > maxLongSide else { return cg }
        let s = maxLongSide / long
        let w = Int((CGFloat(cg.width) * s).rounded()), h = Int((CGFloat(cg.height) * s).rounded())
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cg.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return cg }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? cg
    }

    /// Saves a generated image into an "AI" subfolder beside `original`, carrying the
    /// original's EXIF/GPS and forcing its capture date (EXIF + the file's own date)
    /// so it sorts correctly. Tags it AI-generated. Returns the new URL.
    nonisolated static func saveToAIFolder(_ data: Data, basedOn original: URL) -> URL? {
        guard let resultSrc = CGImageSourceCreateWithData(data as CFData, nil),
              let resultCG = CGImageSourceCreateImageAtIndex(resultSrc, 0, nil) else { return nil }
        let aiDir = original.deletingLastPathComponent().appendingPathComponent("AI", isDirectory: true)
        try? FileManager.default.createDirectory(at: aiDir, withIntermediateDirectories: true)

        var props: [CFString: Any] = [:]
        if let src = CGImageSourceCreateWithURL(original as CFURL, nil) {
            props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
        }
        let captureDate = exifDate(from: props)
            ?? (try? original.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let captureDate {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy:MM:dd HH:mm:ss"; f.timeZone = .current
            let stamp = f.string(from: captureDate)
            var exif = (props[kCGImagePropertyExifDictionary] as? [CFString: Any]) ?? [:]
            exif[kCGImagePropertyExifDateTimeOriginal] = stamp
            exif[kCGImagePropertyExifDateTimeDigitized] = stamp
            exif[kCGImagePropertyExifUserComment] = "AI-generated"
            props[kCGImagePropertyExifDictionary] = exif
            var tiff = (props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]) ?? [:]
            tiff[kCGImagePropertyTIFFDateTime] = stamp
            tiff[kCGImagePropertyTIFFSoftware] = "PhotoBrowser AI"
            props[kCGImagePropertyTIFFDictionary] = tiff
        }
        props[kCGImagePropertyOrientation] = 1
        props[kCGImagePropertyPixelWidth] = resultCG.width
        props[kCGImagePropertyPixelHeight] = resultCG.height

        let dest = uniqueURL(for: "\(original.deletingPathExtension().lastPathComponent) AI.jpg", in: aiDir)
        guard let d = CGImageDestinationCreateWithURL(dest as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(d, resultCG, props as CFDictionary)
        guard CGImageDestinationFinalize(d) else { return nil }
        if let captureDate {
            try? FileManager.default.setAttributes([.creationDate: captureDate, .modificationDate: captureDate], ofItemAtPath: dest.path)
        }
        return dest
    }

    // MARK: - Helpers

    /// A soft highlight rolloff for HDR uploads. Builds a per-channel tone curve over the
    /// extended-range domain [0, headroom] that is identity through the midtones and
    /// asymptotes toward white above the knee, so highlights above 1.0 keep their gradient
    /// instead of clipping to flat white. Uses stock `CIColorCurves` (which, unlike a plain
    /// clamp, accepts an input domain past 1.0); returns nil if the filter can't be built so
    /// the caller can fall back to a hard clamp.
    private nonisolated static func softClip(_ image: CIImage) -> CIImage? {
        let n = 64
        let knee: Float = 0.9, headroom: Float = 4.0
        var data = [Float](); data.reserveCapacity(n * 3)
        for i in 0..<n {
            let v = headroom * Float(i) / Float(n - 1)
            let out = v <= knee ? v : knee + (1 - knee) * (1 - expf(-(v - knee) / (1 - knee)))
            let c = min(max(out, 0), 1)
            data.append(c); data.append(c); data.append(c)
        }
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let curves = CIFilter(name: "CIColorCurves", parameters: [
            kCIInputImageKey: image,
            "inputCurvesData": Data(bytes: data, count: data.count * MemoryLayout<Float>.size),
            "inputCurvesDomain": CIVector(x: 0, y: CGFloat(headroom)),
            "inputColorSpace": space
        ])
        return curves?.outputImage
    }

    /// Astria's gallery tunes control output shape via `aspect_ratio` (they reject
    /// explicit small `w`/`h` — "requires at least 1920×1920, use aspect_ratio
    /// instead"), so snap the requested width:height to the nearest ratio the tunes
    /// accept. The result then matches the shape the user picked.
    private nonisolated static func aspectRatio(_ w: Int, _ h: Int) -> String {
        let supported: [(String, Double)] = [
            ("1:1", 1.0), ("4:5", 0.8), ("5:4", 1.25), ("3:4", 0.75), ("4:3", 1.0 / 0.75),
            ("2:3", 2.0 / 3.0), ("3:2", 1.5), ("9:16", 9.0 / 16.0), ("16:9", 16.0 / 9.0)
        ]
        let target = Double(max(w, 1)) / Double(max(h, 1))
        return supported.min { abs($0.1 - target) < abs($1.1 - target) }!.0
    }

    private nonisolated static func multipart(fields: [String: String],
                                              files: [(name: String, filename: String, mime: String, data: Data)],
                                              boundary: String) -> Data {
        var body = Data()
        func add(_ s: String) { body.append(s.data(using: .utf8)!) }
        for (k, v) in fields {
            add("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n")
        }
        for f in files {
            add("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(f.name)\"; filename=\"\(f.filename)\"\r\n")
            add("Content-Type: \(f.mime)\r\n\r\n")
            body.append(f.data); add("\r\n")
        }
        add("--\(boundary)--\r\n")
        return body
    }

    private nonisolated static func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s) }
        return nil
    }

    private nonisolated static func exifDate(from props: [CFString: Any]) -> Date? {
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let candidates = [exif?[kCGImagePropertyExifDateTimeOriginal] as? String,
                          exif?[kCGImagePropertyExifDateTimeDigitized] as? String,
                          tiff?[kCGImagePropertyTIFFDateTime] as? String]
        // POSIX locale: EXIF dates are a fixed Gregorian format, so the parse must
        // not depend on the device's locale/calendar (a non-Gregorian default
        // otherwise fails and the date silently falls back to the file's copy time).
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"; f.timeZone = .current
        for case let s? in candidates { if let d = f.date(from: s) { return d } }
        return nil
    }

    private nonisolated static func uniqueURL(for name: String, in folder: URL) -> URL {
        let fm = FileManager.default
        var dest = folder.appendingPathComponent(name)
        let base = dest.deletingPathExtension().lastPathComponent, ext = dest.pathExtension
        var n = 1
        while fm.fileExists(atPath: dest.path) { dest = folder.appendingPathComponent("\(base) \(n).\(ext)"); n += 1 }
        return dest
    }

    /// Standard headers for Astria's API. `Accept: application/json` + a real `User-Agent` are what stop
    /// Astria's Cloudflare layer from serving a "Just a moment…" bot-challenge HTML page instead of the
    /// JSON response (a request with no UA / no Accept reads as an automated bot to Cloudflare).
    private nonisolated static func applyAPIHeaders(_ req: inout URLRequest) {
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if req.value(forHTTPHeaderField: "User-Agent") == nil {
            req.setValue("PhotoBrowser/1.0 (iOS; Astria client)", forHTTPHeaderField: "User-Agent")
        }
    }

    private nonisolated static func message(from data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let m = json["message"] as? String { return m }
            if let errors = json["errors"] as? [String], let m = errors.first { return m }
            if let e = json["error"] as? String { return e }
        }
        // A Cloudflare bot-challenge (or any HTML) came back instead of JSON — don't dump raw HTML at the user.
        let text = (String(data: data.prefix(4000), encoding: .utf8) ?? "").lowercased()
        if text.contains("just a moment") || text.contains("cf-browser-verification")
            || text.contains("/cdn-cgi/") || text.contains("cloudflare")
            || text.hasPrefix("<!doctype") || text.hasPrefix("<html") {
            return "Astria's service blocked the request at its Cloudflare bot check (it returned a "
                + "\"Just a moment…\" page instead of a result). This is usually temporary — wait a minute "
                + "and try again. If it persists, it may be rate-limiting on Astria's side, a network/VPN "
                + "being challenged, or an invalid API key (check Settings)."
        }
        return String(data: data.prefix(300), encoding: .utf8) ?? "The provider rejected the request."
    }
}
