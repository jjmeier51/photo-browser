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
            case .nanoBanana2:   return "https://fal.run/fal-ai/nano-banana/edit"
            case .nanoBananaPro: return "https://fal.run/fal-ai/nano-banana-pro/edit"
            }
        }
    }

    enum AIError: Error { case notConfigured, badImage, network, badResult, server(String) }

    // MARK: - Config (user-supplied; nothing ships by default)

    private static let keyKey = "photoBrowser.falKey"
    private static let promptKey = "photoBrowser.falPrompt"
    private static let modelKey = "photoBrowser.falModel"
    static let defaultPrompt = "Replace the blurred border around the photo with a seamless, photorealistic continuation of the scene. Keep the central subject and composition unchanged; match the lighting, colors, grain and perspective."

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

    /// Sends one input image + prompt to the model, asking for `count` images.
    /// Returns the generated image data (one per result) for the Keep/Delete UI.
    nonisolated static func generate(model: AIModel, prompt: String, imageData: Data,
                                     count: Int) async -> Result<[Data], AIError> {
        guard isConfigured else { return .failure(.notConfigured) }
        guard let url = URL(string: model.endpoint) else { return .failure(.server("Bad endpoint URL.")) }
        var body: [String: Any] = [
            "prompt": prompt,
            "image_urls": ["data:image/jpeg;base64," + imageData.base64EncodedString()]
        ]
        if count > 1 { body["num_images"] = count }

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

    /// Downscales a photo to a JPEG suitable for upload (<= `maxPixel` per side).
    nonisolated static func uploadJPEG(of url: URL, maxPixel: CGFloat = 2048) -> Data? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return UIImage(cgImage: cg).jpegData(compressionQuality: 0.92)
    }

    nonisolated static func uploadJPEG(of cg: CGImage) -> Data? {
        UIImage(cgImage: cg).jpegData(compressionQuality: 0.92)
    }

    /// Saves a generated image into an "AI" subfolder beside `original`, inheriting
    /// the original's EXIF/GPS. Returns the new file URL.
    nonisolated static func saveToAIFolder(_ data: Data, basedOn original: URL) -> URL? {
        guard let resultSrc = CGImageSourceCreateWithData(data as CFData, nil),
              let resultCG = CGImageSourceCreateImageAtIndex(resultSrc, 0, nil) else { return nil }
        let aiDir = original.deletingLastPathComponent().appendingPathComponent("AI", isDirectory: true)
        try? FileManager.default.createDirectory(at: aiDir, withIntermediateDirectories: true)

        var props: [CFString: Any] = [:]
        if let src = CGImageSourceCreateWithURL(original as CFURL, nil) {
            props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
        }
        props[kCGImagePropertyOrientation] = 1
        props[kCGImagePropertyPixelWidth] = resultCG.width
        props[kCGImagePropertyPixelHeight] = resultCG.height
        if var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1; props[kCGImagePropertyTIFFDictionary] = tiff
        }
        let dest = uniqueURL(for: "\(original.deletingPathExtension().lastPathComponent) AI.jpg", in: aiDir)
        guard let d = CGImageDestinationCreateWithURL(dest as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(d, resultCG, props as CFDictionary)
        return CGImageDestinationFinalize(d) ? dest : nil
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
