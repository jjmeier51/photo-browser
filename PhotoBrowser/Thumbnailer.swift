import UIKit
import ImageIO
import AVFoundation
import QuickLookThumbnailing
import CryptoKit

/// Generates thumbnails for photos, videos and PDFs, with a memory + disk cache and
/// de-duplication of concurrent requests, so scrolling big folders stays fast and never
/// does the same work twice.
///
/// **Generators are chosen for speed:** photos use **ImageIO** (`CGImageSourceCreateThumbnail…`)
/// and videos use **AVAssetImageGenerator** — both run in-process. QuickLook is reserved for
/// PDFs / other types. The old all-QuickLook path routed *every* tile through an out-of-process
/// XPC service, which is fine for a handful but crawls across the thousands of items in a big
/// folder; the in-process generators are dramatically faster for bulk thumbnailing.
///
/// `nonisolated` matters: under the project's default-MainActor isolation an unmarked class is
/// MainActor-bound, which silently moved the disk-cache reads, JPEG decode/encode and cache
/// writes back onto the main thread even inside a detached task. State is protected by `lock`.
nonisolated final class Thumbnailer: @unchecked Sendable {
    static let shared = Thumbnailer()

    private let memory = NSCache<NSString, UIImage>()
    private let diskDir: URL
    private let lock = NSLock()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        diskDir = caches.appendingPathComponent("thumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskDir, withIntermediateDirectories: true)
        // Bound by actual memory, not count — NSCache only evicts cost-tracked entries
        // proactively. Generous so a whole folder's tiles stay resident and re-opening /
        // scrolling back is instant.
        memory.countLimit = 4000
        memory.totalCostLimit = 512 * 1024 * 1024
    }

    /// Warms the cache for a folder's items ahead of scroll, so tiles pop in instead of
    /// generating on demand. Fire-and-forget, bounded to the core count, off the main thread;
    /// in-flight de-duplication means a tile that scrolls into view reuses this work rather
    /// than starting its own. The cache key ignores the requested size, so prefetching at the
    /// grid size also satisfies larger requests.
    func prefetch(_ entries: [Entry], size: CGSize, scale: CGFloat) {
        let items = entries.filter { $0.kind == .image || $0.kind == .video || $0.kind == .pdf }
        guard !items.isEmpty else { return }
        let batch = Array(items.prefix(2500))          // cap so an enormous folder can't runaway
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            await withTaskGroup(of: Void.self) { group in
                var idx = 0
                let maxConcurrent = max(2, min(ProcessInfo.processInfo.activeProcessorCount, 8))
                func next() {
                    guard idx < batch.count else { return }
                    let e = batch[idx]; idx += 1
                    group.addTask { _ = await self.thumbnail(for: e, size: size, scale: scale) }
                }
                for _ in 0..<min(maxConcurrent, batch.count) { next() }
                while await group.next() != nil { next() }
            }
        }
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
            let kind = entry.kind
            task = Task.detached(priority: .utility) { [weak self] in
                await self?.produce(key: key, url: entry.url, kind: kind, size: size, scale: scale) ?? nil
            }
            inFlight[key] = task
        }
        lock.unlock()

        let image = await task.value
        lock.lock(); inFlight[key] = nil; lock.unlock()
        return image
    }

    private func produce(key: String, url: URL, kind: FileKind, size: CGSize, scale: CGFloat) async -> UIImage? {
        let nsKey = key as NSString
        let diskURL = diskDir.appendingPathComponent(key).appendingPathExtension("jpg")
        if let data = try? Data(contentsOf: diskURL), let raw = UIImage(data: data) {
            // Force the JPEG decode here, off-main — UIImage(data:) defers it to
            // first render, which shows up as scroll hitches on the main thread.
            let img = raw.preparingForDisplay() ?? raw
            memory.setObject(img, forKey: nsKey, cost: cost(of: img))
            return img
        }
        guard let img = await generate(url: url, kind: kind, size: size, scale: scale) else { return nil }
        memory.setObject(img, forKey: nsKey, cost: cost(of: img))
        if let data = img.jpegData(compressionQuality: 0.8) {
            try? data.write(to: diskURL, options: .atomic)
        }
        return img
    }

    /// Approximate decoded size in bytes (RGBA), for the cache's cost limit.
    private func cost(of image: UIImage) -> Int {
        Int(image.size.width * image.scale * image.size.height * image.scale) * 4
    }

    private func generate(url: URL, kind: FileKind, size: CGSize, scale: CGFloat) async -> UIImage? {
        let maxPixel = max(size.width, size.height) * scale
        switch kind {
        case .image:
            return imageThumbnail(url: url, maxPixel: maxPixel) ?? (await quickLook(url: url, size: size, scale: scale))
        case .video:
            return (await videoThumbnail(url: url, maxPixel: maxPixel)) ?? (await quickLook(url: url, size: size, scale: scale))
        default:
            return await quickLook(url: url, size: size, scale: scale)
        }
    }

    /// Fast in-process photo thumbnail via ImageIO (honors EXIF orientation, decodes immediately).
    private func imageThumbnail(url: URL, maxPixel: CGFloat) -> UIImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(max(1, maxPixel))
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// Fast in-process video poster via AVAssetImageGenerator (nearest keyframe, oriented).
    private func videoThumbnail(url: URL, maxPixel: CGFloat) async -> UIImage? {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        gen.requestedTimeToleranceBefore = .positiveInfinity     // any nearby frame → no precise seek
        gen.requestedTimeToleranceAfter = .positiveInfinity
        for t in [CMTime(seconds: 0.3, preferredTimescale: 600), .zero] {
            if let result = try? await gen.image(at: t) { return UIImage(cgImage: result.image) }
        }
        return nil
    }

    private func quickLook(url: URL, size: CGSize, scale: CGFloat) async -> UIImage? {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: scale,
                                                   representationTypes: .thumbnail)
        return await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
                continuation.resume(returning: rep?.uiImage)
            }
        }
    }

    private func cacheKey(for entry: Entry) -> String {
        let raw = "\(entry.url.stableCacheID)|\(Int(entry.modified.timeIntervalSince1970))|\(entry.size)"
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
