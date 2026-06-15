import Foundation
import ImageIO
import UniformTypeIdentifiers
import UIKit

/// Cloud AI image features (opt-in, fal.ai). Two operations share one request
/// shape (prompt + input image + num_images): "extend" (outpaint a composed
/// canvas) and "edit" (free-text edit). Results are returned as image data for a
/// Keep/Delete preview — Keep saves into an "AI" subfolder, inheriting the
/// original's EXIF. Nothing uploads unless the user invokes it with their key.
enum AIExtend {
    enum AIModel: String, CaseIterable, Identifiable, Sendable {
        case seedream = "Seedream 4.5"
        case nanoBanana2 = "Nano Banana 2"
        case nanoBananaPro = "Nano Banana Pro"
        var id: String { rawValue }
        var endpoint: String {
            switch self {
            case .seedream:      return "https://fal.run/fal-ai/bytedance/seedream/v4.5/edit"
            case .nanoBanana2:   return "https://fal.run/fal-ai/nano-banana-2/edit"
            case .nanoBananaPro: return "https://fal.run/fal-ai/nano-banana-pro/edit"
            }
        }
        /// Highest output long-side the model targets (≈4K where supported). The
        /// input is sent at this size and, for Seedream, requested as the output.
        var maxLongSide: CGFloat {
            switch self {
            case .seedream:      return 4096
            case .nanoBananaPro: return 4096
            case .nanoBanana2:   return 4096
            }
        }
    }

    enum AIError: Error { case notConfigured, badImage, network, badResult, server(String) }

    // MARK: - Config (user-supplied; nothing ships by default)

    private static let keyKey = "photoBrowser.falKey"
    private static let promptKey = "photoBrowser.falPrompt"
    private static let modelKey = "photoBrowser.falModel"
    static let defaultPrompt = "Expand this exact photo outward to fill the larger frame, generating realistic new surroundings that seamlessly continue the existing scene. Keep the original subject, framing and details unchanged and sharp. Output one single seamless photograph — no borders, frames, blur, padding, or duplicated copies of the original."

    static var apiKey: String { UserDefaults.standard.string(forKey: keyKey) ?? "" }
    static var isConfigured: Bool { !apiKey.isEmpty }
    static var extendPrompt: String {
        let v = UserDefaults.standard.string(forKey: promptKey) ?? ""
        return v.isEmpty ? defaultPrompt : v
    }
    static var defaultModel: AIModel {
        AIModel(rawValue: UserDefaults.standard.string(forKey: modelKey) ?? "") ?? .seedream
    }
    static func save(apiKey: String, prompt: String, model: AIModel) {
        let d = UserDefaults.standard
        d.set(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), forKey: keyKey)
        d.set(prompt, forKey: promptKey)
        d.set(model.rawValue, forKey: modelKey)
    }

    // MARK: - Generation

    /// Sends one input image + prompt to the model, asking for `count` images at
    /// the model's highest resolution. Returns the generated image data (one per
    /// result) for the Keep/Delete UI.
    nonisolated static func generate(model: AIModel, prompt: String, imageData: Data,
                                     count: Int, outputSize: (width: Int, height: Int)? = nil) async -> Result<[Data], AIError> {
        guard isConfigured else { return .failure(.notConfigured) }
        guard let url = URL(string: model.endpoint) else { return .failure(.server("Bad endpoint URL.")) }
        var body: [String: Any] = [
            "prompt": prompt,
            "image_urls": ["data:image/jpeg;base64," + imageData.base64EncodedString()]
        ]
        if count > 1 { body["num_images"] = count }
        // Ask for the target output size (controls extend aspect + resolution).
        if let outputSize {
            body["image_size"] = ["width": outputSize.width, "height": outputSize.height]
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 240
        req.setValue("Key \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        guard let (data, resp) = try? await URLSession.shared.data(for: req) else { return .failure(.network) }
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            return .failure(.server(message(from: data)))
        }
        let urls = imageURLs(from: data)
        guard !urls.isEmpty else { return .failure(.badResult) }
        var out: [Data] = []
        await withTaskGroup(of: Data?.self) { group in
            for u in urls { group.addTask { (try? await URLSession.shared.data(from: u))?.0 } }
            for await d in group { if let d { out.append(d) } }
        }
        return out.isEmpty ? .failure(.network) : .success(out)
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

    /// A CGImage as an upload JPEG, downscaled so its long side <= `maxPixel`.
    nonisolated static func uploadJPEG(of cg: CGImage, maxPixel: CGFloat) -> (data: Data, width: Int, height: Int)? {
        let capped = downscale(cg, maxLongSide: maxPixel)
        guard let data = UIImage(cgImage: capped).jpegData(compressionQuality: 0.92) else { return nil }
        return (data, capped.width, capped.height)
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

    /// Saves a generated image into an "AI" subfolder beside `original`, carrying
    /// the original's EXIF/GPS and forcing its capture date (EXIF + the file's own
    /// date) so it sorts correctly. Tags it as AI-generated. Returns the new URL.
    nonisolated static func saveToAIFolder(_ data: Data, basedOn original: URL) -> URL? {
        guard let resultSrc = CGImageSourceCreateWithData(data as CFData, nil),
              let resultCG = CGImageSourceCreateImageAtIndex(resultSrc, 0, nil) else { return nil }
        let aiDir = original.deletingLastPathComponent().appendingPathComponent("AI", isDirectory: true)
        try? FileManager.default.createDirectory(at: aiDir, withIntermediateDirectories: true)

        var props: [CFString: Any] = [:]
        if let src = CGImageSourceCreateWithURL(original as CFURL, nil) {
            props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
        }
        // Capture date: from the original's EXIF, else its file modified date.
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
        if let captureDate {   // make the file's date match the capture date
            try? FileManager.default.setAttributes([.creationDate: captureDate, .modificationDate: captureDate], ofItemAtPath: dest.path)
        }
        return dest
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

    // MARK: - Helpers

    private nonisolated static func uniqueURL(for name: String, in folder: URL) -> URL {
        let fm = FileManager.default
        var dest = folder.appendingPathComponent(name)
        let base = dest.deletingPathExtension().lastPathComponent, ext = dest.pathExtension
        var n = 1
        while fm.fileExists(atPath: dest.path) { dest = folder.appendingPathComponent("\(base) \(n).\(ext)"); n += 1 }
        return dest
    }

    private nonisolated static func imageURLs(from data: Data) -> [URL] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        if let images = json["images"] as? [[String: Any]] {
            return images.compactMap { ($0["url"] as? String).flatMap(URL.init) }
        }
        if let image = json["image"] as? [String: Any], let s = image["url"] as? String, let u = URL(string: s) { return [u] }
        return []
    }

    private nonisolated static func message(from data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let detail = json["detail"] as? String { return detail }
            if let detail = json["detail"] as? [[String: Any]], let m = detail.first?["msg"] as? String { return m }
            if let m = json["message"] as? String { return m }
        }
        return String(data: data.prefix(300), encoding: .utf8) ?? "The provider rejected the request."
    }
}
