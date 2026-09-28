import Foundation
import ImageIO
import CoreGraphics
import os

/// Duplicate detection for the move/copy flow: before an incoming photo is written into a
/// destination folder, decide whether the *same photo* is already there and, if so, what to do.
///
/// The rules (see `plan`):
/// * **Rule A** — an incoming ORIGINAL (JPEG/HEIC/RAW…) matches an ORIGINAL already in the
///   destination: keep the older/equal-size copy in place, set the other aside in `DUPLICATES/`.
/// * **Rule B** — an incoming ORIGINAL matches PNG(s) in the destination (upscaler/exports of the
///   same shot): the original goes in, every matching PNG moves to `Duplicate PNGs/`.
/// * **Rule C** — nothing matches: the existing move/copy behaviour, untouched.
/// * An incoming PNG that matches an ORIGINAL already there is diverted to `Duplicate PNGs/`.
///
/// "Same photo" is deliberately strict — a name match alone proves nothing (`Frame 2.PNG` and
/// `Frame 2.jpg` can be unrelated): aspect ratio, capture date (to the second, sub-second when
/// both have it), camera + exposure, and a perceptual dHash must all agree (`samePhoto`).
///
/// Layout: `plan(incoming:candidates:)` is **pure** over `PhotoFacts` values so it's unit-testable
/// with no disk; `DestinationIndex` reads the destination folder's facts **once per batch** (off the
/// main actor, bounded fan-out) and `plan(incoming:in:)` is the URL-level wrapper the move/copy code
/// calls per file. Hashes are computed lazily — only for candidates that already pass rules 1–3 —
/// and cached in a JSON file keyed by `filename|size|mtime` so each image is hashed once.
/// Files are only ever moved (`FileManager.moveItem`) — bytes and metadata are never touched.
///
/// The whole enum is `nonisolated`: everything here runs inside the move/copy batch's detached
/// task, and under the project's default-MainActor isolation an unmarked type would silently hop
/// every call back to the main thread (the `Thumbnailer` lesson in CLAUDE.md).
nonisolated enum DuplicateDetection {
    static let duplicatesFolder = "DUPLICATES"
    static let duplicatePNGsFolder = "Duplicate PNGs"
    static let helperFolders: Set<String> = [duplicatesFolder, duplicatePNGsFolder]
    /// Formats that count as a camera/phone ORIGINAL (case-insensitive extension).
    static let originalExtensions: Set<String> = [
        "jpg", "jpeg", "heic", "heif", "dng", "cr2", "cr3", "nef", "nrw", "arw", "raf", "orf", "rw2", "pef", "srw", "raw"]
    /// dHash Hamming distance at or below which two decodable images are "the same picture".
    static let maxHashDistance = 8
    /// Aspect ratios must agree within this fraction (either orientation).
    static let aspectTolerance = 0.01
    /// Exposure time / f-number / focal length / ISO must agree within this fraction (re-saves round them).
    static let exposureTolerance = 0.05

    private nonisolated static let logger = Logger(subsystem: "jayymei.PhotoBrowser", category: "Duplicates")

    // MARK: - Classification

    nonisolated static func isOriginal(_ url: URL) -> Bool { originalExtensions.contains(url.pathExtension.lowercased()) }
    nonisolated static func isPNG(_ url: URL) -> Bool { url.pathExtension.lowercased() == "png" }

    /// Filename without extension, lowercased. PNGs also lose a trailing `_` + 6–12 hex characters —
    /// the suffix upscalers append (`IMG_1234_402C6DBE.png` → `img_1234`) — so they line up with the
    /// original they were made from.
    nonisolated static func stem(forName name: String) -> String {
        let ns = name as NSString
        var s = ns.deletingPathExtension.lowercased()
        if ns.pathExtension.lowercased() == "png",
           let r = s.range(of: #"_[0-9a-f]{6,12}$"#, options: .regularExpression) {
            s.removeSubrange(r)
        }
        return s
    }

    // MARK: - Facts about one file

    /// Everything the same-photo test needs, read once per file. `hash` is filled lazily (see
    /// `DestinationIndex.ensureHash`) because hashing every file in a large folder up front would
    /// dominate a move; the pure `plan` just uses whatever is present.
    struct PhotoFacts: Sendable, Equatable {
        var url: URL
        var size: Int64 = 0
        var mtime: TimeInterval = 0
        var width: Int = 0                 // 0 = unknown / not decodable
        var height: Int = 0
        var captureDate: Date? = nil       // EXIF DateTimeOriginal → DateTimeDigitized → TIFF DateTime (never mtime)
        var subSecond: String? = nil       // EXIF SubSecTimeOriginal, when present
        var make: String? = nil
        var model: String? = nil
        var exposureTime: Double? = nil
        var fNumber: Double? = nil
        var focalLength: Double? = nil
        var iso: Double? = nil
        var hash: UInt64? = nil            // 64-bit dHash; nil = not computed or not decodable

        var name: String { url.lastPathComponent }
        var isOriginal: Bool { DuplicateDetection.isOriginal(url) }
        var isPNG: Bool { DuplicateDetection.isPNG(url) }
        var stem: String { DuplicateDetection.stem(forName: url.lastPathComponent) }
        /// Capture date truncated to the second — the granularity rule 2 compares at.
        var captureSecond: Int? { captureDate.map { Int($0.timeIntervalSince1970.rounded(.down)) } }
        /// Orientation-independent aspect (long side / short side); nil when dimensions are unknown.
        var aspect: Double? {
            guard width > 0, height > 0 else { return nil }
            return Double(max(width, height)) / Double(min(width, height))
        }

        init(url: URL) { self.url = url }
    }

    /// Reads `PhotoFacts` for `url` with ImageIO — properties only, no pixel decode (`kCGImageSourceShouldCache: false`).
    /// The hash is NOT computed here. Off the main actor only.
    nonisolated static func readFacts(_ url: URL) -> PhotoFacts {
        var f = PhotoFacts(url: url)
        if let vals = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) {
            f.size = Int64(vals.fileSize ?? 0)
            f.mtime = vals.contentModificationDate?.timeIntervalSince1970 ?? 0
        }
        guard f.isOriginal || f.isPNG else { return f }
        let noCache = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithURL(url as CFURL, noCache),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, noCache) as? [String: Any] else { return f }
        f.width = number(props[kCGImagePropertyPixelWidth as String]).map(Int.init) ?? 0
        f.height = number(props[kCGImagePropertyPixelHeight as String]).map(Int.init) ?? 0
        let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let dateStrings = [exif[kCGImagePropertyExifDateTimeOriginal as String] as? String,
                           exif[kCGImagePropertyExifDateTimeDigitized as String] as? String,
                           tiff[kCGImagePropertyTIFFDateTime as String] as? String]
        for case let s? in dateStrings {
            if let d = parseEXIFDate(s) { f.captureDate = d; break }
        }
        if let sub = (exif["SubsecTimeOriginal"] as? String)?.trimmingCharacters(in: .whitespaces), !sub.isEmpty {
            f.subSecond = sub
        }
        f.make = nonEmpty(tiff[kCGImagePropertyTIFFMake as String] as? String)
        f.model = nonEmpty(tiff[kCGImagePropertyTIFFModel as String] as? String)
        f.exposureTime = number(exif[kCGImagePropertyExifExposureTime as String])
        f.fNumber = number(exif[kCGImagePropertyExifFNumber as String])
        f.focalLength = number(exif[kCGImagePropertyExifFocalLength as String])
        if let isos = exif[kCGImagePropertyExifISOSpeedRatings as String] as? [Any], let first = isos.first {
            f.iso = number(first)
        } else {
            f.iso = number(exif[kCGImagePropertyExifISOSpeedRatings as String])
        }
        return f
    }

    private nonisolated static func number(_ any: Any?) -> Double? {
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s) }
        return nil
    }
    private nonisolated static func nonEmpty(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }
    /// EXIF dates are a fixed Gregorian format — parse in the POSIX locale so the device's
    /// calendar can't break it (the same lesson as `MetadataLoader`).
    nonisolated static func parseEXIFDate(_ s: String) -> Date? {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current; f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f.date(from: String(s.prefix(19)))
    }

    // MARK: - The same-photo test

    enum Match: Sendable, Equatable {
        case different
        /// `verified` is false when either side couldn't be hashed (undecodable) and only rules 1–3 held.
        case same(verified: Bool)
    }

    /// Rules 1–4 from the spec. A missing value on either side never counts as a mismatch, except
    /// the hash, whose absence downgrades the match to "unverified".
    nonisolated static func samePhoto(_ a: PhotoFacts, _ b: PhotoFacts) -> Match {
        // 1. Aspect ratio (either orientation), within 1%.
        if let ra = a.aspect, let rb = b.aspect, abs(ra - rb) / max(ra, rb) > aspectTolerance { return .different }
        // 2. Capture date to the second; sub-second too when both carry it.
        if let sa = a.captureSecond, let sb = b.captureSecond {
            if sa != sb { return .different }
            if let ua = a.subSecond, let ub = b.subSecond, ua != ub { return .different }
        }
        // 3. Camera and exposure.
        if let ma = a.make, let mb = b.make, normalize(ma) != normalize(mb) { return .different }
        if let ma = a.model, let mb = b.model, normalize(ma) != normalize(mb) { return .different }
        for (x, y) in [(a.exposureTime, b.exposureTime), (a.fNumber, b.fNumber),
                       (a.focalLength, b.focalLength), (a.iso, b.iso)] {
            if let x, let y, !roughlyEqual(x, y) { return .different }
        }
        // 4. Perceptual hash.
        if let ha = a.hash, let hb = b.hash {
            return PerceptualHash.distance(ha, hb) <= maxHashDistance ? .same(verified: true) : .different
        }
        return .same(verified: false)
    }

    private nonisolated static func normalize(_ s: String) -> String {
        s.lowercased().components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }
    private nonisolated static func roughlyEqual(_ x: Double, _ y: Double) -> Bool {
        let m = max(abs(x), abs(y))
        return m == 0 ? true : abs(x - y) / m <= exposureTolerance
    }

    // MARK: - The plan (pure)

    struct MovePlan: Sendable, Equatable {
        enum Operation: Sendable, Hashable {
            /// A file already in the destination is moved into the named helper subfolder.
            case relocateExisting(URL, into: String)
            /// The incoming file goes into the destination under its own name — the existing
            /// move/copy behaviour (including the caller's same-name collision handling).
            case placeIncoming
            /// The incoming file goes into the named helper subfolder instead of the destination.
            case divertIncoming(into: String)
        }
        var operations: [Operation]
        var log: [String] = []
        /// True when a match relied on rules 1–3 only because a side couldn't be hashed.
        var unverified = false

        /// Rule C / not a photo: exactly what happened before this feature existed.
        static let passthrough = MovePlan(operations: [.placeIncoming])
        var isPassthrough: Bool { operations == [.placeIncoming] }
    }

    /// Decides what to do with `incoming` given the destination's top-level `candidates` (their
    /// facts, hashes filled where available). Pure: no disk access.
    nonisolated static func plan(incoming: PhotoFacts, candidates: [PhotoFacts]) -> MovePlan {
        guard incoming.isOriginal || incoming.isPNG else { return .passthrough }
        var plan = MovePlan(operations: [])
        var matchedOriginals: [PhotoFacts] = []
        var matchedPNGs: [PhotoFacts] = []
        for c in candidates where c.url != incoming.url && (c.isOriginal || c.isPNG) {
            switch samePhoto(incoming, c) {
            case .different:
                continue
            case .same(let verified):
                if !verified {
                    plan.unverified = true
                    plan.log.append("unverified match (no hash): \(incoming.name) ~ \(c.name)")
                }
                if c.isOriginal { matchedOriginals.append(c) } else { matchedPNGs.append(c) }
            }
        }

        // Incoming PNG: only the "matches an ORIGINAL" case changes anything.
        if incoming.isPNG {
            guard let orig = matchedOriginals.first else { return .passthrough }
            plan.operations = [.divertIncoming(into: duplicatePNGsFolder)]
            plan.log.append("PNG \(describe(incoming)) is the same photo as original \(describe(orig)) → \(duplicatePNGsFolder)/")
            return plan
        }

        // Incoming ORIGINAL.
        var incomingHandled = false
        if let existing = bestOriginal(matchedOriginals, for: incoming) {           // Rule A
            let notNewer: Bool
            if let di = incoming.captureDate, let de = existing.captureDate { notNewer = di <= de } else { notNewer = true }
            if incoming.size == existing.size && notNewer {
                plan.operations += [.relocateExisting(existing.url, into: duplicatesFolder), .placeIncoming]
                plan.log.append("Rule A: incoming \(describe(incoming)) replaces \(describe(existing)) (same size, not newer) → existing to \(duplicatesFolder)/")
            } else {
                plan.operations.append(.divertIncoming(into: duplicatesFolder))
                plan.log.append("Rule A: incoming \(describe(incoming)) → \(duplicatesFolder)/ (existing \(describe(existing)) kept)")
            }
            incomingHandled = true
            for other in matchedOriginals where other.url != existing.url {
                plan.log.append("Rule A: also matched \(describe(other)) — left untouched")
            }
        }
        if !matchedPNGs.isEmpty {                                                     // Rule B
            if !incomingHandled { plan.operations.append(.placeIncoming); incomingHandled = true }
            for png in matchedPNGs {
                plan.operations.append(.relocateExisting(png.url, into: duplicatePNGsFolder))
                plan.log.append("Rule B: PNG \(describe(png)) is the same photo as incoming \(describe(incoming)) → \(duplicatePNGsFolder)/")
            }
        }
        if !incomingHandled { return .passthrough }                                  // Rule C
        return plan
    }

    /// The destination ORIGINAL Rule A compares against when several match: same stem first,
    /// then the one whose name sorts first (deterministic).
    private nonisolated static func bestOriginal(_ matches: [PhotoFacts], for incoming: PhotoFacts) -> PhotoFacts? {
        guard !matches.isEmpty else { return nil }
        let sorted = matches.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return sorted.first { $0.stem == incoming.stem } ?? sorted[0]
    }

    private nonisolated static func describe(_ f: PhotoFacts) -> String {
        let date = f.captureDate.map { d -> String in
            let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX"); df.dateFormat = "yyyy-MM-dd HH:mm:ss"
            return df.string(from: d) + (f.subSecond.map { ".\($0)" } ?? "")
        } ?? "no date"
        return "\(f.name) [\(f.size) B, \(date)]"
    }

    // MARK: - Destination index (one read per batch)

    /// Facts for every photo at the destination folder's **top level** (helper folders and other
    /// subfolders are never entered), read once with bounded fan-out. Candidates for an incoming
    /// file are looked up by stem and by capture second; hashes are filled lazily and cached.
    nonisolated final class DestinationIndex: @unchecked Sendable {
        let folder: URL
        let cache: HashCache
        private let lock = NSLock()
        private var facts: [URL: PhotoFacts] = [:]
        private var byStem: [String: Set<URL>] = [:]
        private var bySecond: [Int: Set<URL>] = [:]

        private init(folder: URL, cache: HashCache) { self.folder = folder; self.cache = cache }

        /// Builds the index. Reading properties for thousands of files on an external drive is the
        /// slow part, so it fans out `maxConcurrent` readers and runs entirely off the main actor.
        nonisolated static func build(folder: URL, cache: HashCache = .shared, maxConcurrent: Int = 8) async -> DestinationIndex {
            let index = DestinationIndex(folder: folder, cache: cache)
            let fm = FileManager.default
            let urls = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                                     options: [.skipsHiddenFiles])) ?? [])
                .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true }
                .filter { isOriginal($0) || isPNG($0) }
            await withTaskGroup(of: PhotoFacts?.self) { group in
                var it = urls.makeIterator()
                var started = 0
                // Keep `maxConcurrent` readers in flight; each finished one starts the next.
                for _ in 0..<max(1, maxConcurrent) {
                    if let u = it.next() { started += 1; group.addTask { readFacts(u) } }
                }
                for await f in group {
                    if let f { index.add(f) }
                    if let u = it.next() { started += 1; group.addTask { readFacts(u) } }
                }
                _ = started
            }
            return index
        }

        /// Test/bulk seam: an index over pre-computed facts, no disk.
        nonisolated static func make(folder: URL, facts: [PhotoFacts], cache: HashCache = .shared) -> DestinationIndex {
            let index = DestinationIndex(folder: folder, cache: cache)
            for f in facts { index.add(f) }
            return index
        }

        func add(_ f: PhotoFacts) {
            lock.lock(); defer { lock.unlock() }
            facts[f.url] = f
            byStem[f.stem, default: []].insert(f.url)
            if let s = f.captureSecond { bySecond[s, default: []].insert(f.url) }
        }

        func remove(_ url: URL) {
            lock.lock(); defer { lock.unlock() }
            guard let f = facts.removeValue(forKey: url) else { return }
            byStem[f.stem]?.remove(url)
            if let s = f.captureSecond { bySecond[s]?.remove(url) }
        }

        var count: Int { lock.lock(); defer { lock.unlock() }; return facts.count }

        /// Destination files worth testing against `incoming`: same stem, plus same capture second
        /// (aspect is checked by `samePhoto` itself).
        func candidates(for incoming: PhotoFacts) -> [PhotoFacts] {
            lock.lock(); defer { lock.unlock() }
            var urls = byStem[incoming.stem] ?? []
            if let s = incoming.captureSecond { urls.formUnion(bySecond[s] ?? []) }
            return urls.compactMap { facts[$0] }.sorted { $0.name < $1.name }
        }

        /// The facts with the dHash filled (computed via the cache if missing) and remembered.
        func ensureHash(_ f: PhotoFacts) -> PhotoFacts {
            if f.hash != nil { return f }
            var out = f
            out.hash = cache.hash(for: f)
            lock.lock(); if facts[f.url] != nil { facts[f.url] = out }; lock.unlock()
            return out
        }
    }

    // MARK: - URL-level plan (what the move/copy code calls)

    /// Reads the incoming file's facts, narrows the destination to its candidates, hashes only the
    /// pairs that already pass rules 1–3, and returns the pure plan.
    nonisolated static func plan(incoming url: URL, in index: DestinationIndex) -> MovePlan {
        guard isOriginal(url) || isPNG(url) else { return .passthrough }
        var incoming = readFacts(url)
        var cands = index.candidates(for: incoming).filter { samePhoto(incoming, $0) != .different }
        guard !cands.isEmpty else { return .passthrough }
        incoming.hash = index.cache.hash(for: incoming)
        cands = cands.map { index.ensureHash($0) }
        let result = plan(incoming: incoming, candidates: cands)
        for line in result.log { logger.info("\(line, privacy: .public)") }
        return result
    }

    // MARK: - Helper folders

    /// `name` inside `folder/subfolder` (created on first use), never overwriting: `_1`, `_2`, …
    /// before the extension on a clash.
    nonisolated static func uniqueURL(for name: String, in folder: URL) -> URL {
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let ns = name as NSString
        let base = ns.deletingPathExtension, ext = ns.pathExtension
        var candidate = folder.appendingPathComponent(name)
        var n = 1
        while fm.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent(ext.isEmpty ? "\(base)_\(n)" : "\(base)_\(n).\(ext)")
            n += 1
        }
        return candidate
    }

    // MARK: - Hash cache

    /// dHashes keyed by `filename|size|mtime`, persisted as JSON in Application Support (Caches is
    /// purged under storage pressure, which would make every move re-hash the library). Thread-safe;
    /// call `flush()` at the end of a batch.
    nonisolated final class HashCache: @unchecked Sendable {
        nonisolated static let shared = HashCache(file: {
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            return dir.appendingPathComponent("dupeHashes.json")
        }())

        private let file: URL?
        private let lock = NSLock()
        private var table: [String: UInt64] = [:]
        private var dirty = false
        private var loaded = false

        /// `file: nil` → in-memory only (tests).
        init(file: URL?) { self.file = file }

        nonisolated static func key(for f: PhotoFacts) -> String { "\(f.name)|\(f.size)|\(Int(f.mtime))" }

        func hash(for f: PhotoFacts) -> UInt64? {
            let k = Self.key(for: f)
            lock.lock()
            loadIfNeeded()
            if let h = table[k] { lock.unlock(); return h }
            lock.unlock()
            guard let h = PerceptualHash.dHash(f.url) else { return nil }
            lock.lock(); table[k] = h; dirty = true; lock.unlock()
            return h
        }

        private func loadIfNeeded() {
            guard !loaded else { return }
            loaded = true
            guard let file, let data = try? Data(contentsOf: file),
                  let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return }
            table = dict.compactMapValues { UInt64($0) }
        }

        func flush() {
            lock.lock(); defer { lock.unlock() }
            guard dirty, let file else { return }
            let dict = table.mapValues { String($0) }
            if let data = try? JSONEncoder().encode(dict) {
                try? data.write(to: file, options: .atomic)
                dirty = false
            }
        }
    }
}
