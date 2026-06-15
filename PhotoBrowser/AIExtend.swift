import Foundation
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
        /// Best-known tune id (Seedream 4.0 / Nano Banana Gemini 2.5 as fallbacks).
        var fallbackTune: Int {
            switch self {
            case .seedream45:    return 3225353
            case .nanoBanana2:   return 3159068
            case .nanoBananaPro: return 3159068
            }
        }
        var maxLongSide: CGFloat { 2048 }
        fileprivate var tuneKey: String { "photoBrowser.astriaTune.\(rawValue)" }
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
                                     count: Int, width: Int?, height: Int?) async -> Result<[Data], AIError> {
        guard isConfigured else { return .failure(.notConfigured) }
        let tune = tuneID(for: model)
        guard let url = URL(string: "\(base)/tunes/\(tune)/prompts") else { return .failure(.server("Bad endpoint URL.")) }

        var fields: [String: String] = [
            "prompt[text]": prompt,
            "prompt[num_images]": String(min(max(count, 1), 8))
        ]
        if let width { fields["prompt[w]"] = String((width / 8) * 8) }
        if let height { fields["prompt[h]"] = String((height / 8) * 8) }
        let files: [(name: String, filename: String, mime: String, data: Data)] = [
            ("prompt[input_image]", "input.jpg", "image/jpeg", imageData)
        ]

        let boundary = "PB-\(UUID().uuidString)"
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
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
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
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
    nonisolated static func uploadJPEG(of url: URL, maxPixel: CGFloat) -> (data: Data, width: Int, height: Int)? {
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
            let f = DateFormatter(); f.dateFormat = "yyyy:MM:dd HH:mm:ss"; f.timeZone = .current
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
        let f = DateFormatter(); f.dateFormat = "yyyy:MM:dd HH:mm:ss"; f.timeZone = .current
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

    private nonisolated static func message(from data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let m = json["message"] as? String { return m }
            if let errors = json["errors"] as? [String], let m = errors.first { return m }
            if let e = json["error"] as? String { return e }
        }
        return String(data: data.prefix(300), encoding: .utf8) ?? "The provider rejected the request."
    }
}
