import UIKit
import QuickLookThumbnailing
import CryptoKit

/// Generates thumbnails for photos, videos and PDFs via QuickLook, with a
/// memory + disk cache and de-duplication of concurrent requests, so scrolling
/// big folders stays fast and never does the same work twice.
final class Thumbnailer: @unchecked Sendable {
    static let shared = Thumbnailer()

    private let memory = NSCache<NSString, UIImage>()
    private let diskDir: URL
    private let lock = NSLock()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        diskDir = caches.appendingPathComponent("thumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskDir, withIntermediateDirectories: true)
        memory.countLimit = 1000
    }

    func thumbnail(for entry: Entry, size: CGSize, scale: CGFloat) async -> UIImage? {
        let key = cacheKey(for: entry)
        if let cached = memory.object(forKey: key as NSString) { return cached }

        // Reuse an in-flight task for the same key instead of starting another.
        let task: Task<UIImage?, Never>
        lock.lock()
        if let existing = inFlight[key] {
            task = existing
        } else {
            // Detached + low priority so thumbnail work runs OFF the main thread
            // and yields to foreground work (e.g. opening the full-screen viewer).
            task = Task.detached(priority: .utility) { [weak self] in
                await self?.produce(key: key, url: entry.url, size: size, scale: scale) ?? nil
            }
            inFlight[key] = task
        }
        lock.unlock()

        let image = await task.value
        lock.lock(); inFlight[key] = nil; lock.unlock()
        return image
    }

    private func produce(key: String, url: URL, size: CGSize, scale: CGFloat) async -> UIImage? {
        let nsKey = key as NSString
        let diskURL = diskDir.appendingPathComponent(key).appendingPathExtension("jpg")
        if let data = try? Data(contentsOf: diskURL), let img = UIImage(data: data) {
            memory.setObject(img, forKey: nsKey)
            return img
        }
        guard let img = await generate(url: url, size: size, scale: scale) else { return nil }
        memory.setObject(img, forKey: nsKey)
        if let data = img.jpegData(compressionQuality: 0.8) {
            try? data.write(to: diskURL, options: .atomic)
        }
        return img
    }

    private func generate(url: URL, size: CGSize, scale: CGFloat) async -> UIImage? {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: scale,
                                                   representationTypes: .thumbnail)
        return await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
                continuation.resume(returning: rep?.uiImage)
            }
        }
    }

    private func cacheKey(for entry: Entry) -> String {
        let raw = "\(entry.url.path)|\(Int(entry.modified.timeIntervalSince1970))|\(entry.size)"
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
