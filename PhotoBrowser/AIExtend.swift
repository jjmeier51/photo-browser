import Foundation
import ImageIO
import UniformTypeIdentifiers
import UIKit

/// Opt-in cloud "extend": outpaints a photo to a target aspect ratio via a
/// configurable provider (default fal.ai's Seedream 4.5 *edit* endpoint). This is
/// the app's only feature that uploads a user photo, so it's gated behind a key
/// the user enters and an explicit per-use confirmation. The result is written
/// back over the original, carrying the original's EXIF/GPS so capture date and
/// location survive. All work is off the main actor.
enum AIExtend {
    // MARK: - Configuration (user-supplied; nothing ships by default)

    private static let keyKey = "photoBrowser.falKey"
    private static let endpointKey = "photoBrowser.falEndpoint"
    private static let promptKey = "photoBrowser.falPrompt"
    static let defaultEndpoint = "https://fal.run/fal-ai/bytedance/seedream/v4.5/edit"
    static let defaultPrompt = "Naturally extend this photo to fill the entire frame, continuing the background and scenery seamlessly. Keep the existing subject, faces and composition unchanged; match the lighting, colors, grain and perspective."

    static var apiKey: String { UserDefaults.standard.string(forKey: keyKey) ?? "" }
    static var endpoint: String {
        let v = UserDefaults.standard.string(forKey: endpointKey) ?? ""
        return v.isEmpty ? defaultEndpoint : v
    }
    static var prompt: String {
        let v = UserDefaults.standard.string(forKey: promptKey) ?? ""
        return v.isEmpty ? defaultPrompt : v
    }
    static var isConfigured: Bool { !apiKey.isEmpty }

    static func save(apiKey: String, endpoint: String, prompt: String) {
        let d = UserDefaults.standard
        d.set(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), forKey: keyKey)
        d.set(endpoint.trimmingCharacters(in: .whitespacesAndNewlines), forKey: endpointKey)
        d.set(prompt, forKey: promptKey)
    }

    enum ExtendError: Error { case notConfigured, badImage, network, badResult, server(String) }

    // MARK: - Extend

    /// Uploads the photo, requests an outpaint to `targetAspect`, writes the result
    /// back over `url` preserving metadata. Returns the error so the UI can show it
    /// (provider moderation can refuse some edits).
    nonisolated static func extendInPlace(url: URL, targetAspect: CGFloat) async -> ExtendError? {
        guard isConfigured else { return .notConfigured }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(src),
              let original = decode(src, maxPixel: 2048) else { return .badImage }
        var props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]

        let dims = targetDimensions(width: original.width, height: original.height, aspect: targetAspect)
        guard let jpeg = UIImage(cgImage: original).jpegData(compressionQuality: 0.92) else { return .badImage }

        let body: [String: Any] = [
            "prompt": prompt,
            "image_urls": ["data:image/jpeg;base64," + jpeg.base64EncodedString()],
            "image_size": ["width": dims.w, "height": dims.h]
        ]
        guard let endpointURL = URL(string: endpoint) else { return .server("Bad endpoint URL.") }
        var req = URLRequest(url: endpointURL)
        req.httpMethod = "POST"
        req.timeoutInterval = 180
        req.setValue("Key \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        guard let (data, resp) = try? await URLSession.shared.data(for: req) else { return .network }
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            return .server(message(from: data))
        }
        guard let resultURL = imageURL(from: data),
              let (imgData, _) = try? await URLSession.shared.data(from: resultURL),
              let resultCG = decode(data: imgData) else { return .badResult }

        // Re-encode into the original container, carrying its metadata (capture
        // date / GPS) so they survive — the model output has none.
        props[kCGImagePropertyOrientation] = 1
        props[kCGImagePropertyPixelWidth] = resultCG.width
        props[kCGImagePropertyPixelHeight] = resultCG.height
        if var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1; props[kCGImagePropertyTIFFDictionary] = tiff
        }
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).edit")
        func encode(_ t: CFString) -> Bool {
            guard let dst = CGImageDestinationCreateWithURL(tmp as CFURL, t, 1, nil) else { return false }
            CGImageDestinationAddImage(dst, resultCG, props as CFDictionary)
            return CGImageDestinationFinalize(dst)
        }
        if !encode(type) {
            try? FileManager.default.removeItem(at: tmp)
            guard encode(UTType.jpeg.identifier as CFString) else { try? FileManager.default.removeItem(at: tmp); return .badResult }
        }
        return MediaEditing.replaceInPlace(original: url, temp: tmp) ? nil : .badResult
    }

    // MARK: - Helpers

    /// Target output size that fits `aspect`, extending the shorter side, capped to
    /// 2048 per side (Seedream's limit).
    private nonisolated static func targetDimensions(width: Int, height: Int, aspect: CGFloat) -> (w: Int, h: Int) {
        let W = CGFloat(width), H = CGFloat(height), imgAR = W / H
        var cw = imgAR >= aspect ? W : (H * aspect)
        var ch = imgAR >= aspect ? (W / aspect) : H
        let maxSide = max(cw, ch)
        if maxSide > 2048 { let s = 2048 / maxSide; cw *= s; ch *= s }
        return (max(64, Int(cw.rounded())), max(64, Int(ch.rounded())))
    }

    private nonisolated static func decode(_ src: CGImageSource, maxPixel: CGFloat) -> CGImage? {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    private nonisolated static func decode(data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    /// Pulls `images[0].url` (or `image.url`) out of a fal.ai response.
    private nonisolated static func imageURL(from data: Data) -> URL? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let images = json["images"] as? [[String: Any]], let s = images.first?["url"] as? String { return URL(string: s) }
        if let image = json["image"] as? [String: Any], let s = image["url"] as? String { return URL(string: s) }
        return nil
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
