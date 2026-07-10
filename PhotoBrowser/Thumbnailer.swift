import UIKit
import ImageIO
import QuickLookThumbnailing
import CryptoKit

/// Generates thumbnails for photos, videos and PDFs, with a memory + disk cache and
/// de-duplication of concurrent requests, so scrolling big folders stays fast and never
/// does the same work twice.
///
/// **Photos use ImageIO** (`CGImageSourceCreateThumbnailAtIndex`), which is in-process and far
/// faster than QuickLook for bulk thumbnailing. **Videos and everything else use QuickLook** —
/// it's the robust, well-optimized path for posters (AVAssetImageGenerator is slow per-asset,
/// especially for non-faststart files). Results are cached to disk so re-opening a folder is
/// instant.
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
        // Thumbnails live in Application Support, NOT Caches. iOS is free to purge
        // anything under Caches/ whenever storage is tight — which is why the disk
        // cache used to evaporate and the whole library re-thumbnailed itself a few
        // times a day. Application Support is never auto-purged, so a generated
        // thumbnail stays generated until the file itself changes. We exclude the
        // directory from iCloud/iTunes backups (it's derived data, regenerable) so
        // persisting it doesn't bloat the user's backups.
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var dir = support.appendingPathComponent("thumbs", isDirectory: true)

        // One-time migration: fold the old Caches/thumbs cache into the new home so
        // users keep the thumbnails they've already built instead of regenerating
        // everything once on the update that ships this change.
        let legacy = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("thumbs", isDirectory: true)
        if fm.fileExists(atPath: legacy.path), !fm.fileExists(atPath: dir.path) {
            try? fm.moveItem(at: legacy, to: dir)
        }

        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        diskDir = dir
        // Bound by actual memory, not count — NSCache only evicts cost-tracked entries
        // proactively. Generous so a whole folder's tiles stay resident and re-opening /
        // scrolling back is instant.
        memory.countLimit = 4000
        memory.totalCostLimit = 512 * 1024 * 1024
    }

    /// Warms the cache for a folder's items ahead of scroll, so tiles pop in instead of
    /// generating on demand. Fire-and-forget, bounded to the core count, off the main thread;
    /// in-flight de-duplication means a tile that scrolls into view reuses this work rather than
    /// starting its own. The cache key ignores the requested size, so prefetching at the grid
    /// size also satisfies larger requests. Scales to the whole folder (no fixed cap).
    func prefetch(_ entries: [Entry], size: CGSize, scale: CGFloat) {
        let batch = entries.filter { $0.kind == .image || $0.kind == .video || $0.kind == .pdf }
        guard !batch.isEmpty else { return }
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
            // Force the JPEG decode here, off-main — UIImage(data:) defers it to first render,
            // which shows up as scroll hitches on the main thread.
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
        if kind == .image {
            let maxPixel = max(size.width, size.height) * scale
            if let img = imageThumbnail(url: url, maxPixel: maxPixel) { return img }
        }
        return await quickLook(url: url, size: size, scale: scale)   // videos, PDFs, and image fallback
    }

    /// Fast in-process photo thumbnail via ImageIO (honors EXIF orientation, decoded immediately).
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
        return sha(raw)
    }

    /// The disk-cache key for a file on disk, read from its current mtime/size — matches the
    /// key `cacheKey(for:)` computes from a folder listing's `Entry`. Nil if it can't be stat'd.
    private func cacheKey(forFileAt url: URL) -> String? {
        guard let rv = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else { return nil }
        let mtime = Int((rv.contentModificationDate ?? .distantPast).timeIntervalSince1970)
        return sha("\(url.stableCacheID)|\(mtime)|\(rv.fileSize ?? 0)")
    }

    private func sha(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Pre-generates the disk-cache thumbnail for a file whose full-size bytes we already have
    /// in memory (e.g. a video frame the exporter just wrote), so the folder never has to decode
    /// the full file off the drive later. Keyed exactly like a normal tile request, so the grid
    /// hits it. Generates at the largest scale a tile can ask for (the key ignores size, so one
    /// stored thumbnail satisfies every request). Synchronous + best-effort — the caller runs it
    /// off the main thread and gets natural backpressure (no unbounded queue of frame data).
    func prewarm(imageData: Data, for url: URL) {
        guard let key = cacheKey(forFileAt: url) else { return }
        let diskURL = diskDir.appendingPathComponent(key).appendingPathExtension("jpg")
        guard !FileManager.default.fileExists(atPath: diskURL.path) else { return }   // already cached (e.g. a resumed export)
        let maxPixel = 110.0 * 3.0                                   // grid tile (110pt) at up to @3x
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxPixel)
        ]
        guard let src = CGImageSourceCreateWithData(imageData as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return }
        if let data = UIImage(cgImage: cg).jpegData(compressionQuality: 0.8) {
            try? data.write(to: diskURL, options: .atomic)
        }
    }
}
