import Foundation
import ImageIO
import AVFoundation
import CoreLocation
import UniformTypeIdentifiers
import Vision

/// Everything the swipe-up info panel shows.
struct MediaInfo: Sendable {
    var date: Date?
    var device: String?
    var dimensions: String?
    var coordinate: CLLocationCoordinate2D?
    var placeName: String?
}

/// Read-only metadata for photos/videos. All heavy reads (ImageIO, AVFoundation,
/// CoreLocation, xattrs) run inside `Task.detached` so the project's
/// default-MainActor isolation can't pull them onto the main thread — the single
/// biggest source of "the app froze" bugs on a slow external drive.
enum MetadataLoader {

    // MARK: - Per-file result cache

    /// Capture dates, captions and media specs are re-requested every time a
    /// folder is opened, and each miss is a full EXIF/AVAsset read — the
    /// dominant cost of browsing on an external drive. Results are cached keyed
    /// by path|mtime|size (the Thumbnailer's scheme), so an in-place edit
    /// invalidates naturally. Negative results are cached too — "no embedded
    /// caption / date" is the common case and just as expensive to discover.
    private final class CachedValue<T> {
        let value: T?
        init(_ value: T?) { self.value = value }
    }

    private static let dateCache = makeCache(of: Date.self)
    private static let captionCache = makeCache(of: String.self)
    private static let specCache = makeCache(of: MediaSpec.self)

    private static func makeCache<T>(of _: T.Type) -> NSCache<NSString, CachedValue<T>> {
        let cache = NSCache<NSString, CachedValue<T>>()
        cache.countLimit = 20_000
        return cache
    }

    private static func cacheKey(for entry: Entry) -> NSString {
        "\(entry.url.stableCacheID)|\(Int(entry.modified.timeIntervalSince1970))|\(entry.size)" as NSString
    }

    // MARK: - Persistent capture-date cache

    /// Capture dates are the sort key for the whole app, so reading EXIF/AVAsset
    /// for every file on every launch (the in-memory cache is lost on relaunch)
    /// makes browsing a big folder on a slow external drive crawl. This store
    /// persists `path|mtime|size → capture timestamp` to disk so a file's date is
    /// read at most once, ever. `0` records a known "no embedded date" so those
    /// files aren't re-read either. The key includes mtime+size, so an in-place
    /// edit re-reads naturally.
    private final class DateStore: @unchecked Sendable {
        private let lock = NSLock()
        private var map: [String: Double]
        private var dirty = false
        private let fileURL: URL

        init() {
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            fileURL = dir.appendingPathComponent("captureDates.json")
            map = (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode([String: Double].self, from: $0) } ?? [:]
        }

        /// `.some(date?)` when the key is known (date or known-absent), `nil` when unseen.
        func lookup(_ key: String) -> Date?? {
            lock.lock(); defer { lock.unlock() }
            guard let ts = map[key] else { return nil }
            return .some(ts == 0 ? nil : Date(timeIntervalSince1970: ts))
        }

        func store(_ key: String, _ date: Date?) {
            lock.lock(); map[key] = date?.timeIntervalSince1970 ?? 0; dirty = true; lock.unlock()
        }

        /// Writes the map to disk if anything changed (off the caller's hot path).
        func flush() {
            lock.lock()
            guard dirty else { lock.unlock(); return }
            let snapshot = map; dirty = false
            lock.unlock()
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: fileURL, options: .atomic) }
        }

        /// Copies every entry under `from`'s drive-relative subtree to the matching
        /// key under `to` (backup-drive duplication; originals kept).
        func duplicatePrefix(_ from: String, _ to: String) {
            lock.lock()
            var adds: [String: Double] = [:]
            for (k, v) in map where k.hasPrefix(from + "/") {
                let nk = to + k.dropFirst(from.count)
                if map[nk] == nil { adds[nk] = v }
            }
            for (k, v) in adds { map[k] = v }
            if !adds.isEmpty { dirty = true }
            lock.unlock()
            flush()
        }
    }

    private static let dateStore = DateStore()

    /// Persists any newly-read capture dates. Call after a batch of reads.
    static func flushDateStore() { dateStore.flush() }

    // MARK: - Persistent media-spec cache

    /// Dimensions/HDR/duration back the resolution filters, the duration sort and
    /// the video tiles' length badges. Like capture dates they're expensive to read
    /// (ImageIO/AVAsset per file) and the in-memory cache dies with the app, so
    /// specs persist keyed `path|mtime|size` — each file is inspected at most once,
    /// ever. Single stores debounce their flush: tiles record specs one at a time
    /// as they first appear, and rewriting the whole file per tile would thrash.
    private final class SpecStore: @unchecked Sendable {
        private let lock = NSLock()
        private var map: [String: MediaSpec]
        private var dirty = false
        private var flushScheduled = false
        private let fileURL: URL

        init() {
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            fileURL = dir.appendingPathComponent("mediaSpecs.json")
            map = (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode([String: MediaSpec].self, from: $0) } ?? [:]
        }

        func lookup(_ key: String) -> MediaSpec? { lock.lock(); defer { lock.unlock() }; return map[key] }

        func store(_ key: String, _ spec: MediaSpec) {
            lock.lock(); map[key] = spec; dirty = true; lock.unlock()
            scheduleFlush()
        }

        func flush() {
            lock.lock(); guard dirty else { lock.unlock(); return }
            let snapshot = map; dirty = false; lock.unlock()
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: fileURL, options: .atomic) }
        }

        /// Coalesces a burst of single stores (scrolling a folder of new videos)
        /// into one disk write a few seconds later.
        private func scheduleFlush() {
            lock.lock()
            let start = !flushScheduled
            if start { flushScheduled = true }
            lock.unlock()
            guard start else { return }
            Task.detached(priority: .utility) { [self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                lock.lock(); flushScheduled = false; lock.unlock()
                flush()
            }
        }

        /// Copies every entry under `from`'s drive-relative subtree to the matching
        /// key under `to` (backup-drive duplication; originals kept).
        func duplicatePrefix(_ from: String, _ to: String) {
            lock.lock()
            var adds: [String: MediaSpec] = [:]
            for (k, v) in map where k.hasPrefix(from + "/") {
                let nk = to + k.dropFirst(from.count)
                if map[nk] == nil { adds[nk] = v }
            }
            for (k, v) in adds { map[k] = v }
            if !adds.isEmpty { dirty = true }
            lock.unlock()
            flush()
        }
    }

    private static let specStore = SpecStore()

    /// Persists any newly-read specs immediately. Call after a bulk read.
    static func flushSpecStore() { specStore.flush() }

    /// Duplicates the per-file caches (capture dates, media specs, OCR text) from
    /// one drive-relative root prefix onto another — used when copying metadata to
    /// a backup drive so it browses warm. No-op when the prefixes match (the
    /// stableCacheID keys already hit for an identically-laid-out backup).
    static func duplicateStores(fromStablePrefix from: String, toStablePrefix to: String) {
        guard from != to else { return }
        dateStore.duplicatePrefix(from, to)
        specStore.duplicatePrefix(from, to)
        ocrStore.duplicatePrefix(from, to)
    }

    // MARK: - On-device photo-text (OCR) index

    /// Recognized text per photo, keyed `path|mtime|size` (so an edit re-OCRs).
    /// Persisted to disk so the (slow) Vision pass runs at most once per file.
    /// An empty string records "scanned, no text" so it isn't re-scanned.
    private final class OCRStore: @unchecked Sendable {
        private let lock = NSLock()
        private var map: [String: String]
        private var dirty = false
        private let fileURL: URL

        init() {
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            fileURL = dir.appendingPathComponent("ocrText.json")
            map = (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        }
        func lookup(_ key: String) -> String? { lock.lock(); defer { lock.unlock() }; return map[key] }
        func store(_ key: String, _ text: String) { lock.lock(); map[key] = text; dirty = true; lock.unlock() }
        func flush() {
            lock.lock(); guard dirty else { lock.unlock(); return }
            let snapshot = map; dirty = false; lock.unlock()
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: fileURL, options: .atomic) }
        }

        /// Copies every entry under `from`'s drive-relative subtree to the matching
        /// key under `to` (backup-drive duplication; originals kept).
        func duplicatePrefix(_ from: String, _ to: String) {
            lock.lock()
            var adds: [String: String] = [:]
            for (k, v) in map where k.hasPrefix(from + "/") {
                let nk = to + k.dropFirst(from.count)
                if map[nk] == nil { adds[nk] = v }
            }
            for (k, v) in adds { map[k] = v }
            if !adds.isEmpty { dirty = true }
            lock.unlock()
            flush()
        }
    }

    private static let ocrStore = OCRStore()
    static func flushOCRStore() { ocrStore.flush() }

    private static func storeKey(for entry: Entry) -> String {
        "\(entry.url.stableCacheID)|\(Int(entry.modified.timeIntervalSince1970))|\(entry.size)"
    }

    /// Cache-only recognized text for search — nil if the photo hasn't been indexed
    /// yet (never runs OCR on the search hot path).
    static func ocrTextCached(for entry: Entry) -> String? {
        let text = ocrStore.lookup(storeKey(for: entry))
        return (text?.isEmpty ?? true) ? nil : text
    }

    /// Recognizes (and caches) the text in a photo. Used by the indexing pass; runs
    /// Vision off the main actor on a downsized copy. Non-images return "".
    static func ocrText(for entry: Entry) async -> String {
        guard entry.kind == .image else { return "" }
        let key = storeKey(for: entry)
        if let cached = ocrStore.lookup(key) { return cached }
        let text = await recognizeText(in: entry.url)
        ocrStore.store(key, text)
        return text
    }

    private static func recognizeText(in url: URL) async -> String {
        await Task.detached(priority: .utility) { () -> String in
            let opts = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let src = CGImageSourceCreateWithURL(url as CFURL, opts) else { return "" }
            let thumbOpts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: 2000      // enough for legible text, off-main
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOpts as CFDictionary) else { return "" }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])
            let strings = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            return strings.joined(separator: " ").lowercased()
        }.value
    }

    // MARK: - Dimensions + HDR (for resolution/HDR filters)

    static func mediaSpec(for entry: Entry) async -> MediaSpec {
        let key = cacheKey(for: entry)
        if let cached = specCache.object(forKey: key) { return cached.value ?? MediaSpec() }
        // Disk store: a file's dimensions/duration are read at most once across launches.
        if let known = specStore.lookup(key as String) {
            specCache.setObject(CachedValue(known), forKey: key)
            return known
        }
        // Time-boxed like the info panel's reads: one corrupt/slow file must not stall
        // a bulk spec pass. A timeout stays uncached so a healthy drive retries later.
        guard let spec = await withTimeout(10, { await readMediaSpec(for: entry) }) else { return MediaSpec() }
        specCache.setObject(CachedValue(spec), forKey: key)
        specStore.store(key as String, spec)
        return spec
    }

    private static func readMediaSpec(for entry: Entry) async -> MediaSpec {
        switch entry.kind {
        case .image:
            return await Task.detached(priority: .utility) { () -> MediaSpec in
                var spec = MediaSpec()
                guard let src = CGImageSourceCreateWithURL(entry.url as CFURL, nil) else { return spec }
                if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
                   let w = props[kCGImagePropertyPixelWidth] as? Int,
                   let h = props[kCGImagePropertyPixelHeight] as? Int {
                    spec.pixels = w * h
                    spec.longSide = max(w, h)
                }
                if CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, kCGImageAuxiliaryDataTypeHDRGainMap) != nil {
                    spec.isHDR = true
                }
                return spec
            }.value
        case .video:
            return await Task.detached(priority: .utility) { () -> MediaSpec in
                var spec = MediaSpec()
                let asset = AVURLAsset(url: entry.url)
                if let d = try? await asset.load(.duration) {
                    let s = d.seconds
                    if s.isFinite, s > 0 { spec.duration = s }
                }
                if let track = try? await asset.loadTracks(withMediaType: .video).first {
                    if let size = try? await track.load(.naturalSize) {
                        let w = Int(abs(size.width)), h = Int(abs(size.height))
                        spec.longSide = max(w, h)
                        spec.pixels = w * h
                    }
                    if let chars = try? await track.load(.mediaCharacteristics), chars.contains(.containsHDRVideo) {
                        spec.isHDR = true
                    }
                }
                return spec
            }.value
        default:
            return MediaSpec()
        }
    }

    // MARK: - Photo format badge (RAW / 48MP)

    /// Returns "RAW", "48MP", or nil for the upper-right photo badge.
    static func photoBadge(url: URL) async -> String? {
        let rawExts: Set<String> = ["dng", "raw", "cr2", "cr3", "nef", "arw", "raf", "rw2", "orf", "srw", "pef"]
        if rawExts.contains(url.pathExtension.lowercased()) { return "RAW" }
        return await Task.detached(priority: .utility) { () -> String? in
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            if let t = CGImageSourceGetType(src), let type = UTType(t as String), type.conforms(to: .rawImage) {
                return "RAW"
            }
            guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
                  let w = props[kCGImagePropertyPixelWidth] as? Int,
                  let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
            return (Double(w * h) / 1_000_000 >= 44) ? "48MP" : nil
        }.value
    }

    // MARK: - Existing caption embedded in a file (pull-in)

    static func existingCaption(for entry: Entry) async -> String? {
        let key = cacheKey(for: entry)
        if let cached = captionCache.object(forKey: key) { return cached.value }
        // Time-boxed for the same reason as capture dates; a timeout stays uncached.
        guard let caption = await withTimeout(8, { await readExistingCaption(for: entry) }) else { return nil }
        captionCache.setObject(CachedValue(caption), forKey: key)
        return caption
    }

    private static func readExistingCaption(for entry: Entry) async -> String? {
        switch entry.kind {
        case .image:
            return await Task.detached(priority: .utility) { () -> String? in
                guard let src = CGImageSourceCreateWithURL(entry.url as CFURL, nil),
                      let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
                if let iptc = props[kCGImagePropertyIPTCDictionary] as? [CFString: Any],
                   let s = iptc[kCGImagePropertyIPTCCaptionAbstract] as? String, !s.isEmpty { return s }
                if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
                   let s = tiff[kCGImagePropertyTIFFImageDescription] as? String, !s.isEmpty { return s }
                if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
                   let s = exif[kCGImagePropertyExifUserComment] as? String, !s.isEmpty { return s }
                return nil
            }.value
        case .video:
            let asset = AVURLAsset(url: entry.url)
            guard let meta = try? await asset.load(.metadata) else { return nil }
            for item in meta where item.commonKey == .commonKeyDescription {
                if let s = try? await item.load(.stringValue), !s.isEmpty { return s }
            }
            for item in meta where item.commonKey == .commonKeyTitle {
                if let s = try? await item.load(.stringValue), !s.isEmpty { return s }
            }
            return nil
        default:
            return nil
        }
    }

    // MARK: - Image metadata for a captured video frame (date/location/device)

    static func exifProperties(forVideo url: URL) async -> [String: Any] {
        let info = await loadVideo(url)
        var exif: [String: Any] = [:]
        var tiff: [String: Any] = [:]
        var gps: [String: Any] = [:]

        if let date = info.date {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy:MM:dd HH:mm:ss"
            let s = f.string(from: date)
            exif[kCGImagePropertyExifDateTimeOriginal as String] = s
            exif[kCGImagePropertyExifDateTimeDigitized as String] = s
            tiff[kCGImagePropertyTIFFDateTime as String] = s
        }
        if let device = info.device {
            tiff[kCGImagePropertyTIFFModel as String] = device
            if device.localizedCaseInsensitiveContains("iPhone") || device.localizedCaseInsensitiveContains("iPad") {
                tiff[kCGImagePropertyTIFFMake as String] = "Apple"
            }
        }
        if let c = info.coordinate {
            gps[kCGImagePropertyGPSLatitude as String] = abs(c.latitude)
            gps[kCGImagePropertyGPSLatitudeRef as String] = c.latitude >= 0 ? "N" : "S"
            gps[kCGImagePropertyGPSLongitude as String] = abs(c.longitude)
            gps[kCGImagePropertyGPSLongitudeRef as String] = c.longitude >= 0 ? "E" : "W"
        }

        var props: [String: Any] = [:]
        if !exif.isEmpty { props[kCGImagePropertyExifDictionary as String] = exif }
        if !tiff.isEmpty { props[kCGImagePropertyTIFFDictionary as String] = tiff }
        if !gps.isEmpty  { props[kCGImagePropertyGPSDictionary as String] = gps }
        return props
    }

    // MARK: - "Saved from" (download source, best-effort)

    /// Where the file was downloaded from — e.g. "Safari", "Reddit", "Files" —
    /// read from the file's extended attributes. Nil if unknown.
    static func whereFrom(url: URL) -> String? {
        // kMDItemWhereFroms: a binary-plist array of strings (source URL + title).
        if let data = extendedAttribute("com.apple.metadata:kMDItemWhereFroms", at: url),
           let list = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String] {
            let entries = list.filter { !$0.isEmpty }
            if let link = entries.first(where: { $0.contains("://") }) {
                return friendlySource(from: link)
            }
            if let first = entries.first { return first }
        }
        // Quarantine: "flags;timestamp;agentName;uuid" — agentName is the app.
        if let data = extendedAttribute("com.apple.quarantine", at: url),
           let raw = String(data: data, encoding: .utf8) {
            let parts = raw.components(separatedBy: ";")
            if parts.count >= 3, !parts[2].isEmpty { return friendlyAgent(parts[2]) }
        }
        return nil
    }

    private static func extendedAttribute(_ name: String, at url: URL) -> Data? {
        let path = url.path
        let length = getxattr(path, name, nil, 0, 0, 0)
        guard length > 0, length < 1_048_576 else { return nil }   // sane upper bound
        var buffer = [UInt8](repeating: 0, count: length)
        let read = getxattr(path, name, &buffer, length, 0, 0)
        guard read > 0 else { return nil }
        return Data(buffer.prefix(read))
    }

    private static func friendlySource(from string: String) -> String {
        guard let host = URL(string: string)?.host?.replacingOccurrences(of: "www.", with: "") else { return string }
        let map = ["reddit.com": "Reddit", "redd.it": "Reddit", "twitter.com": "X", "x.com": "X",
                   "instagram.com": "Instagram", "facebook.com": "Facebook", "fb.com": "Facebook",
                   "youtube.com": "YouTube", "youtu.be": "YouTube", "tiktok.com": "TikTok",
                   "pinterest.com": "Pinterest", "imgur.com": "Imgur", "google.com": "Google",
                   "snapchat.com": "Snapchat", "whatsapp.com": "WhatsApp"]
        if let name = map[host] { return name }
        let parts = host.components(separatedBy: ".")
        return parts.count >= 2 ? parts[parts.count - 2].capitalized : host
    }

    private static func friendlyAgent(_ agent: String) -> String {
        if agent.localizedCaseInsensitiveContains("safari") { return "Safari" }
        if agent.localizedCaseInsensitiveContains("chrome") { return "Chrome" }
        if agent.localizedCaseInsensitiveContains("firefox") { return "Firefox" }
        return agent
    }

    // MARK: - Capture date (for year filtering)

    /// The real capture date from EXIF (photos) or creation metadata (videos);
    /// nil if the file carries none.
    static func captureDate(for entry: Entry) async -> Date? {
        let key = cacheKey(for: entry)
        if let cached = dateCache.object(forKey: key) { return cached.value }
        // Disk cache: a file's date is read at most once across launches.
        if let known = dateStore.lookup(key as String) {
            dateCache.setObject(CachedValue(known), forKey: key)
            return known
        }
        // Time-boxed so a slow/corrupt file can't stall a bulk date pass. A timeout is
        // deliberately NOT cached (storing it would permanently record "no date"), so
        // the file is retried once the drive is healthy again.
        guard let date = await withTimeout(10, { await readCaptureDate(for: entry) }) else { return nil }
        dateCache.setObject(CachedValue(date), forKey: key)
        dateStore.store(key as String, date)
        return date
    }

    private static func readCaptureDate(for entry: Entry) async -> Date? {
        switch entry.kind {
        case .image:
            return await Task.detached(priority: .utility) { () -> Date? in
                guard let src = CGImageSourceCreateWithURL(entry.url as CFURL, nil),
                      let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
                // Try the usual EXIF/TIFF capture-date fields in order. (A copied
                // file's modification date is the copy time, so we must read the
                // date embedded in the image, never fall back to the file's mtime.)
                let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
                let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
                let candidates = [exif?[kCGImagePropertyExifDateTimeOriginal] as? String,
                                  exif?[kCGImagePropertyExifDateTimeDigitized] as? String,
                                  tiff?[kCGImagePropertyTIFFDateTime] as? String]
                for case let s? in candidates {
                    if let d = parseExifDate(s) { return d }
                }
                return nil
            }.value
        case .video:
            return await Task.detached(priority: .utility) { () -> Date? in
                let asset = AVURLAsset(url: entry.url)
                // Common creation-date key (as a Date, or a parseable string).
                if let item = try? await asset.load(.creationDate) {
                    if let d = try? await item.load(.dateValue) { return d }
                    if let s = try? await item.load(.stringValue), let d = parseISODate(s) { return d }
                }
                // Some videos only carry the date in QuickTime metadata.
                if let qt = try? await asset.loadMetadata(for: .quickTimeMetadata) {
                    for item in qt where (item.key as? String) == "com.apple.quicktime.creationdate" {
                        if let s = try? await item.load(.stringValue), let d = parseISODate(s) { return d }
                    }
                }
                // Or in the common metadata as a creation-date string.
                if let meta = try? await asset.load(.metadata) {
                    for item in meta where item.commonKey == .commonKeyCreationDate {
                        if let s = try? await item.load(.stringValue), let d = parseISODate(s) { return d }
                    }
                }
                return nil
            }.value
        default:
            return nil
        }
    }

    // MARK: - Fallback capture dates (Restore Capture Dates only)

    /// A plausibility window for any *guessed* capture date: 1990 … tomorrow.
    private nonisolated static func saneDate(_ d: Date) -> Bool {
        d > Date(timeIntervalSince1970: 631_152_000) && d < Date().addingTimeInterval(86_400)
    }

    /// Secondary embedded date for photos that lack a normal EXIF/TIFF capture
    /// date: GPS date/time (UTC) or IPTC DateCreated/TimeCreated. Off-main.
    nonisolated static func auxCaptureDate(for entry: Entry) async -> Date? {
        guard entry.kind == .image else { return nil }
        return await Task.detached(priority: .utility) { () -> Date? in
            guard let src = CGImageSourceCreateWithURL(entry.url as CFURL, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
            if let iptc = props[kCGImagePropertyIPTCDictionary] as? [CFString: Any],
               let day = iptc[kCGImagePropertyIPTCDateCreated] as? String,
               let d = parseIPTCDate(day, iptc[kCGImagePropertyIPTCTimeCreated] as? String) { return d }
            if let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any],
               let stamp = gps[kCGImagePropertyGPSDateStamp] as? String,
               let d = parseGPSDate(stamp, gps[kCGImagePropertyGPSTimeStamp]) { return d }
            return nil
        }.value
    }

    /// IPTC: DateCreated "yyyyMMdd" + optional TimeCreated "HHmmss…" (local time).
    private nonisolated static func parseIPTCDate(_ day: String, _ time: String?) -> Date? {
        guard day.count == 8, let y = Int(day.prefix(4)),
              let mo = Int(day.dropFirst(4).prefix(2)), let d = Int(day.dropFirst(6).prefix(2)) else { return nil }
        var c = DateComponents(); c.year = y; c.month = mo; c.day = d; c.hour = 12
        if let time, time.count >= 6 {
            c.hour = Int(time.prefix(2)); c.minute = Int(time.dropFirst(2).prefix(2)); c.second = Int(time.dropFirst(4).prefix(2))
        }
        let date = Calendar(identifier: .gregorian).date(from: c)
        return date.flatMap { saneDate($0) ? $0 : nil }
    }

    /// GPS: DateStamp "yyyy:MM:dd" + TimeStamp (UTC), as "HH:mm:ss" or [h,m,s].
    private nonisolated static func parseGPSDate(_ stamp: String, _ time: Any?) -> Date? {
        let p = stamp.split(separator: ":")
        guard p.count == 3, let y = Int(p[0]), let mo = Int(p[1]), let d = Int(p[2]) else { return nil }
        var c = DateComponents(); c.year = y; c.month = mo; c.day = d; c.timeZone = TimeZone(identifier: "UTC")
        if let s = time as? String {
            let t = s.split(separator: ":")
            if t.count >= 3 { c.hour = Int(t[0]); c.minute = Int(t[1]); c.second = Int(Double(t[2]) ?? 0) }
        } else if let a = time as? [Any], a.count >= 3 {
            c.hour = (a[0] as? NSNumber)?.intValue; c.minute = (a[1] as? NSNumber)?.intValue; c.second = (a[2] as? NSNumber)?.intValue
        }
        let date = Calendar(identifier: .gregorian).date(from: c)
        return date.flatMap { saneDate($0) ? $0 : nil }
    }

    /// Best-effort capture date parsed from a filename (the app's own screenshot
    /// names, IMG_/PXL_/VID_ camera names, WhatsApp, plain yyyy-MM-dd, or a unix
    /// timestamp). Heuristic — used only when no embedded date exists.
    nonisolated static func dateFromFilename(_ name: String) -> Date? {
        let base = (name as NSString).deletingPathExtension
        var cal = Calendar(identifier: .gregorian); cal.timeZone = .current
        func build(_ y: Int?, _ mo: Int?, _ d: Int?, _ h: Int, _ mi: Int, _ s: Int) -> Date? {
            guard let y, let mo, let d, (1...12).contains(mo), (1...31).contains(d),
                  (0...23).contains(h), (0...59).contains(mi), (0...59).contains(s) else { return nil }
            var c = DateComponents(); c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi; c.second = s
            return cal.date(from: c).flatMap { saneDate($0) ? $0 : nil }
        }
        // 1. The app's screenshot format: "… 2023-01-15 at 12.05.30".
        if let g = firstMatch(base, "((?:19|20)[0-9]{2})-([0-9]{2})-([0-9]{2}) at ([0-9]{2})\\.([0-9]{2})\\.([0-9]{2})"),
           let date = build(Int(g[1]), Int(g[2]), Int(g[3]), Int(g[4]) ?? 12, Int(g[5]) ?? 0, Int(g[6]) ?? 0) { return date }
        // 2. General yyyy MM dd [+ HH mm ss] with common separators.
        for g in allMatches(base, "(?<![0-9])((?:19|20)[0-9]{2})[-_.:]?([0-9]{2})[-_.:]?([0-9]{2})(?:[ _tT-]([0-9]{2})[-_.:]?([0-9]{2})[-_.:]?([0-9]{2})?)?") {
            if let date = build(Int(g[1]), Int(g[2]), Int(g[3]), Int(g[4]) ?? 12, Int(g[5]) ?? 0, Int(g[6]) ?? 0) { return date }
        }
        // 3. Bare unix timestamp (10-digit seconds or 13-digit milliseconds).
        if let g = firstMatch(base, "(?<![0-9])(1[0-9]{9}(?:[0-9]{3})?)(?![0-9])"), let v = Double(g[1]) {
            let date = Date(timeIntervalSince1970: g[1].count >= 13 ? v / 1000 : v)
            if saneDate(date) { return date }
        }
        return nil
    }

    /// Capture groups of the first match (index 0 = whole match); "" for absent groups.
    private nonisolated static func firstMatch(_ s: String, _ pattern: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        let ns = s as NSString
        return (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i); return r.location == NSNotFound ? "" : ns.substring(with: r)
        }
    }

    private nonisolated static func allMatches(_ s: String, _ pattern: String) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { m in
            (0..<m.numberOfRanges).map { i in
                let r = m.range(at: i); return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
        }
    }

    // MARK: - Full info (for the swipe-up panel)

    static func load(for entry: Entry) async -> MediaInfo {
        var info: MediaInfo
        // Both image and video reads are time-boxed so a slow/corrupt file on an
        // external drive can never hang the info panel — fall back to just the
        // file's own attributes. (The image path used to be unbounded, which could
        // still freeze the swipe-up panel on a huge/damaged photo.)
        switch entry.kind {
        case .image: info = await withTimeout(6) { await loadImage(entry.url) } ?? MediaInfo()
        case .video: info = await withTimeout(6) { await loadVideo(entry.url) } ?? MediaInfo()
        default:     info = MediaInfo()
        }
        if info.date == nil { info.date = entry.modified }
        if let coord = info.coordinate, !CLLocationCoordinate2DIsValid(coord) {
            info.coordinate = nil          // drop malformed GPS so nothing geocodes it
        }
        return info
    }

    /// Reverse-geocoded place name for a coordinate, bounded and crash-guarded.
    /// Deliberately kept *out* of `load` so the core info shows immediately and a
    /// slow/offline network lookup can never delay (or endanger) the panel.
    static func placeName(for coordinate: CLLocationCoordinate2D) async -> String? {
        await withTimeout(4) { await reverseGeocode(coordinate) } ?? nil
    }

    // MARK: - Time-boxed convenience wrappers for the info panel

    /// `existingCaption`, bounded so a slow/corrupt file can't stall the panel.
    static func timeBoxedCaption(for entry: Entry) async -> String? {
        await withTimeout(6) { await existingCaption(for: entry) } ?? nil
    }

    /// `whereFrom` (a blocking `getxattr`), run off the main actor and bounded.
    static func timeBoxedSource(url: URL) async -> String? {
        await withTimeout(4) { await Task.detached { whereFrom(url: url) }.value } ?? nil
    }

    /// Runs `op` off the main actor, returning nil if it doesn't finish within
    /// `seconds`. Keeps the swipe-up panel from ever stalling on slow I/O.
    static func withTimeout<T: Sendable>(_ seconds: Double,
                                         _ op: @escaping @Sendable () async -> T) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await op() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private static func loadImage(_ url: URL) async -> MediaInfo {
        await Task.detached(priority: .userInitiated) { () -> MediaInfo in
            var info = MediaInfo()
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else {
                return info
            }
            if let w = props[kCGImagePropertyPixelWidth] as? Int,
               let h = props[kCGImagePropertyPixelHeight] as? Int {
                info.dimensions = "\(w) × \(h)"
            }
            if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                let make = tiff[kCGImagePropertyTIFFMake] as? String
                let model = tiff[kCGImagePropertyTIFFModel] as? String
                let dev = [make, model].compactMap { $0 }.joined(separator: " ")
                info.device = dev.isEmpty ? nil : dev
            }
            let exifDict = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
            let tiffDict = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
            let dateCandidates = [exifDict?[kCGImagePropertyExifDateTimeOriginal] as? String,
                                  exifDict?[kCGImagePropertyExifDateTimeDigitized] as? String,
                                  tiffDict?[kCGImagePropertyTIFFDateTime] as? String]
            for case let ds? in dateCandidates {
                if let d = parseExifDate(ds) { info.date = d; break }
            }
            if let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any],
               let lat = gps[kCGImagePropertyGPSLatitude] as? Double,
               let lon = gps[kCGImagePropertyGPSLongitude] as? Double {
                let latRef = gps[kCGImagePropertyGPSLatitudeRef] as? String ?? "N"
                let lonRef = gps[kCGImagePropertyGPSLongitudeRef] as? String ?? "E"
                info.coordinate = CLLocationCoordinate2D(latitude: latRef == "S" ? -lat : lat,
                                                         longitude: lonRef == "W" ? -lon : lon)
            }
            return info
        }.value
    }

    private static func loadVideo(_ url: URL) async -> MediaInfo {
        // Runs off the main actor: under default-MainActor isolation the
        // synchronous parts of AVURLAsset reads would otherwise stall the UI
        // (worse on a slow external drive), which looked like a freeze.
        await Task.detached(priority: .userInitiated) { () -> MediaInfo in
            await loadVideoBody(url)
        }.value
    }

    private nonisolated static func loadVideoBody(_ url: URL) async -> MediaInfo {
        var info = MediaInfo()
        let asset = AVURLAsset(url: url)
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let size = try? await track.load(.naturalSize),
           let transform = try? await track.load(.preferredTransform) {
            let r = size.applying(transform)
            info.dimensions = "\(Int(abs(r.width))) × \(Int(abs(r.height)))"
        }
        if let meta = try? await asset.load(.metadata) {
            for item in meta {
                guard let key = item.commonKey else { continue }
                if key == .commonKeyCreationDate, let s = try? await item.load(.stringValue) {
                    info.date = parseISODate(s) ?? info.date
                } else if key == .commonKeyModel, let s = try? await item.load(.stringValue) {
                    info.device = s
                }
            }
        }
        if let qt = try? await asset.loadMetadata(for: .quickTimeMetadata) {
            for item in qt {
                let keyStr = item.key as? String
                if keyStr == "com.apple.quicktime.model", let s = try? await item.load(.stringValue) {
                    info.device = s
                } else if keyStr == "com.apple.quicktime.location.ISO6709", let s = try? await item.load(.stringValue) {
                    info.coordinate = parseISO6709(s)
                } else if keyStr == "com.apple.quicktime.creationdate", let s = try? await item.load(.stringValue) {
                    info.date = parseISODate(s) ?? info.date
                }
            }
        }
        return info
    }

    // MARK: - Video resolution / HDR badge

    /// Returns e.g. "4K", "1080p", "720p", "4K HDR" — or nil for lower res.
    static func videoQuality(url: URL) async -> String? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let size = try? await track.load(.naturalSize) else { return nil }
        let longSide = Int(max(abs(size.width), abs(size.height)))
        let res: String
        if longSide >= 3840 { res = "4K" }
        else if longSide >= 1920 { res = "1080p" }
        else if longSide >= 1280 { res = "720p" }
        else { return nil }

        if let chars = try? await track.load(.mediaCharacteristics), chars.contains(.containsHDRVideo) {
            return res + " HDR"
        }
        return res
    }

    // MARK: - Helpers

    private nonisolated static func reverseGeocode(_ c: CLLocationCoordinate2D) async -> String? {
        // Reverse-geocoding (or building a CLLocation) with an invalid coordinate
        // can blow up, so bail out on anything out of range / NaN.
        guard CLLocationCoordinate2DIsValid(c),
              c.latitude.isFinite, c.longitude.isFinite,
              !(c.latitude == 0 && c.longitude == 0) else { return nil }
        let placemarks = try? await CLGeocoder().reverseGeocodeLocation(
            CLLocation(latitude: c.latitude, longitude: c.longitude))
        guard let p = placemarks?.first else { return nil }
        return [p.locality, p.administrativeArea, p.country].compactMap { $0 }.joined(separator: ", ")
    }

    private nonisolated static func parseExifDate(_ s: String) -> Date? {
        let f = DateFormatter()
        // POSIX locale: EXIF dates are a fixed format, so parsing must not depend
        // on the device's locale/calendar (a non-Gregorian locale otherwise fails
        // the parse and the date silently falls back to the file's copy time).
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f.date(from: s)
    }

    private nonisolated static func parseISODate(_ s: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: s)
    }

    /// Parses an ISO-6709 string like "+37.7749-122.4194/" into a coordinate.
    private nonisolated static func parseISO6709(_ s: String) -> CLLocationCoordinate2D? {
        let scanner = Scanner(string: s)
        guard let lat = scanner.scanDouble(), let lon = scanner.scanDouble() else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}
