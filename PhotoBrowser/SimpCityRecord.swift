import Foundation
import ImageIO
import UniformTypeIdentifiers
import AVFoundation

/// The SimpCity downloader's addresses, its **shared record**, and its date rule — everything that
/// isn't the browser (that's `SimpCityService`). The Mac side is `mac/simpcity.py`; the two must agree.
///
/// **One record, both apps.** `<person>/simpcity/.simpcity.json` lists every file downloaded from the
/// person's threads (`goonbox:<id>` / `turbo:<id>` → file, post, post time) and each thread's address
/// and last page read (and, under "failed", what didn't download — the next run tries it again). Safe
/// Finder and this app read and write the same file, so whatever one of them
/// downloaded the other never fetches again. Files are named `<id>.<ext>`, so a file in the folder
/// counts as done even when the record doesn't list it; a file deleted from the folder stays deleted.
/// Every save re-reads the file and merges, and the JSON is handled as plain dictionaries so a field
/// the other app adds is carried through, never dropped.
///
/// **Dates.** A photo or video that carries its own capture date keeps it. One that doesn't gets the
/// date of the forum post it came from, written into the file (EXIF for photos, the QuickTime creation
/// date for videos) — on the downloaded copy in the app's temp folder, before it goes to the drive.
nonisolated enum SimpCity {
    static let folderName = "simpcity"
    static let recordName = ".simpcity.json"
    static let format = "photobrowser-simpcity"
    static let tag = "simpcity"
    static let imageExts: Set<String> = ["jpg", "jpeg", "png", "webp", "gif", "heic", "avif"]
    static let videoExts: Set<String> = ["mp4", "mov", "m4v", "webm", "mkv"]

    // MARK: - Addresses

    /// The thread's first-page address, whatever page/post/query the pasted link points at:
    /// `…/threads/helen-owen-ig-helenowen.64622/page-3#post-9` → `…/threads/helen-owen-ig-helenowen.64622/`.
    static func threadBase(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.isEmpty, !s.contains("://") { s = "https://" + s }
        s = String(s.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        s = String(s.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        guard let m = firstGroups(s, #"^(https?://[^/]*simpcity\.[a-z]+/threads/[^/?#]+?\.(\d+))(?:/.*)?$"#) else { return nil }
        return m[0] + "/"
    }

    static func pageURL(_ base: String, _ n: Int) -> String { n <= 1 ? base : "\(base)page-\(n)" }

    /// (kind, id) for a link the downloader takes: a goonbox.cr image page or a turbo.cr video.
    static func mediaKey(_ url: String) -> (kind: String, id: String)? {
        if let m = firstGroups(url, #"^https?://(?:www\.)?goonbox\.[a-z]+/(?:img|i|image|v|f)/([A-Za-z0-9_-]{4,})"#) {
            return ("goonbox", m[0])
        }
        if let m = firstGroups(url, #"^https?://(?:www\.)?turbo\.[a-z]+/(?:v|d|e|embed|f)/([A-Za-z0-9_-]{4,})"#) {
            return ("turbo", m[0])
        }
        return nil
    }

    static func pageLink(kind: String, id: String) -> String {
        kind == "goonbox" ? "https://goonbox.cr/img/\(id)" : "https://turbo.cr/embed/\(id)"
    }

    /// The file extension for a resolved file URL (its path, not the query).
    static func fileExtension(_ url: String, kind: String) -> String {
        let last = URL(string: url)?.lastPathComponent ?? ""
        var ext = last.contains(".") ? (last.split(separator: ".").last.map(String.init) ?? "").lowercased() : ""
        if ext == "jpeg" { ext = "jpg" }
        if imageExts.contains(ext) || videoExts.contains(ext) { return ext }
        return kind == "turbo" ? "mp4" : "jpg"
    }

    nonisolated struct Item: Sendable {
        let kind: String
        let id: String
        let link: String
        var post: String
        var posted: Double
        var key: String { "\(kind):\(id)" }
    }

    /// Items from the posts one page read returned (`[{id, time, urls}]`), one per key, keeping the
    /// earliest post a file appeared in.
    static func collect(posts: [[String: Any]], into out: inout [String: Item]) {
        for p in posts {
            let when = (p["time"] as? NSNumber)?.doubleValue ?? 0
            let post = (p["id"] as? String) ?? (p["id"] as? NSNumber)?.stringValue ?? ""
            for case let u as String in (p["urls"] as? [Any] ?? []) {
                guard let k = mediaKey(u) else { continue }
                // goonbox's image page (its API takes the same id); turbo links are kept as posted.
                let link = k.kind == "goonbox" ? pageLink(kind: k.kind, id: k.id) : u
                let item = Item(kind: k.kind, id: k.id, link: link, post: post, posted: when)
                if let have = out[item.key] {
                    if when > 0, have.posted == 0 || when < have.posted { out[item.key] = item }
                } else {
                    out[item.key] = item
                }
            }
        }
    }

    // MARK: - The shared record

    /// `<person>/simpcity/.simpcity.json` (see the type notes). Plain dictionaries, merged on save; a
    /// plain value, copied into background tasks (its dictionaries hold only strings and numbers).
    nonisolated struct Record: @unchecked Sendable {
        let folder: URL
        private(set) var items: [String: [String: Any]] = [:]
        private(set) var threads: [String: [String: Any]] = [:]
        /// Not downloaded yet — the next run tries these again even when it doesn't re-read their page.
        private(set) var failed: [String: [String: Any]] = [:]

        var file: URL { folder.appendingPathComponent(SimpCity.recordName) }

        init(folder: URL) {
            self.folder = folder
            merge(read())
        }

        private func read() -> [String: Any] {
            guard let data = try? Data(contentsOf: file),
                  let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  doc["format"] as? String == SimpCity.format else { return [:] }
            return doc
        }

        private mutating func merge(_ doc: [String: Any]) {
            for (k, v) in doc["items"] as? [String: Any] ?? [:] {
                if let v = v as? [String: Any], items[k] == nil { items[k] = v }
            }
            for (k, v) in doc["failed"] as? [String: Any] ?? [:] {
                if let v = v as? [String: Any], failed[k] == nil { failed[k] = v }
            }
            for k in failed.keys where items[k] != nil { failed[k] = nil }
            for (k, v) in doc["threads"] as? [String: Any] ?? [:] {
                guard let v = v as? [String: Any] else { continue }
                let mine = threads[k]
                let theirs = num(v["checked"]), ours = num(mine?["checked"])
                if mine == nil || theirs > ours {
                    var t = mine ?? [:]
                    for (kk, vv) in v { t[kk] = vv }
                    t["pages"] = max(Int(num(v["pages"])), Int(num(mine?["pages"])))
                    threads[k] = t
                }
            }
        }

        func has(_ key: String) -> Bool { items[key] != nil }

        mutating func add(_ item: Item, file: String) {
            items[item.key] = ["file": file, "post": item.post, "posted": Int(item.posted),
                               "at": Int(Date().timeIntervalSince1970)]
            failed[item.key] = nil
        }

        mutating func noteFailed(_ item: Item) {
            failed[item.key] = ["link": item.link, "post": item.post, "posted": Int(item.posted)]
        }

        /// What failed before, as items to try again.
        var retryItems: [String: Item] {
            var out: [String: Item] = [:]
            for (k, v) in failed where items[k] == nil {
                let parts = k.split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2, ["goonbox", "turbo"].contains(parts[0]), !parts[1].isEmpty else { continue }
                out[k] = Item(kind: parts[0], id: parts[1],
                              link: (v["link"] as? String) ?? SimpCity.pageLink(kind: parts[0], id: parts[1]),
                              post: (v["post"] as? String) ?? "", posted: num(v["posted"]))
            }
            return out
        }

        mutating func noteThread(_ base: String, title: String, pages: Int) {
            let t = threads[base] ?? [:]
            threads[base] = ["title": title.isEmpty ? (t["title"] as? String ?? "") : title,
                             "pages": max(pages, Int(num(t["pages"]))),
                             "checked": Int(Date().timeIntervalSince1970)]
        }

        /// Where a run picks the thread up: the last page read (it may have grown since), else 1.
        func startPage(_ base: String) -> Int { max(1, Int(num(threads[base]?["pages"]))) }

        /// The thread most recently read here — what "Get New" offers.
        var lastThread: String? {
            threads.max { num($0.value["checked"]) < num($1.value["checked"]) }?.key
        }

        /// Writes the record, merged with whatever is on the drive now (Safe Finder may have added to it).
        mutating func save() throws {
            merge(read())
            let doc: [String: Any] = ["format": SimpCity.format, "version": 1,
                                      "updated": Int(Date().timeIntervalSince1970), "by": "Photo Browser",
                                      "threads": threads, "items": items, "failed": failed]
            let data = try JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys])
            try DriveWriter.writeDataSync(data, to: file)
        }

        private func num(_ v: Any?) -> Double {
            if let n = v as? NSNumber { return n.doubleValue }
            if let s = v as? String { return Double(s) ?? 0 }
            return 0
        }
    }

    /// `<id>` → file name for what's already in the folder (downloads are named `<id>.<ext>`).
    static func filesByID(in folder: URL) -> [String: String] {
        var out: [String: String] = [:]
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] {
            guard !name.hasPrefix("."), let dot = name.lastIndex(of: ".") else { continue }
            let ext = name[name.index(after: dot)...].lowercased()
            guard imageExts.contains(ext) || videoExts.contains(ext) else { continue }
            let stem = String(name[..<dot])
            if out[stem] == nil { out[stem] = name }
        }
        return out
    }

    /// The items still to download (oldest post first) — what the pages read hold plus what failed
    /// last time — and how many the folder already had without the record knowing (those are added to
    /// the record, they're done).
    static func todo(_ items: [String: Item], record: inout Record, folder: URL) -> (left: [Item], adopted: Int) {
        var items = items
        for (k, it) in record.retryItems where items[k] == nil { items[k] = it }
        let onDisk = filesByID(in: folder)
        var left: [Item] = [], adopted = 0
        for item in items.values where !record.has(item.key) {
            if let name = onDisk[item.id] { record.add(item, file: name); adopted += 1; continue }
            left.append(item)
        }
        left.sort { ($0.posted, $0.key) < ($1.posted, $1.key) }
        return (left, adopted)
    }

    // MARK: - Dates

    static func isVideo(_ url: URL) -> Bool { videoExts.contains(url.pathExtension.lowercased()) }

    /// The capture date the file carries itself — the same fields, in the same order, the app sorts by
    /// (`MetadataLoader.readCaptureDate`).
    static func embeddedDate(_ url: URL) async -> Date? {
        if isVideo(url) {
            let asset = AVURLAsset(url: url)
            if let item = try? await asset.load(.creationDate) {
                if let d = try? await item.load(.dateValue) { return d }
                if let s = try? await item.load(.stringValue), let d = ISO8601DateFormatter().date(from: s) { return d }
            }
            if let qt = try? await asset.loadMetadata(for: .quickTimeMetadata) {
                for item in qt where (item.key as? String) == "com.apple.quicktime.creationdate" {
                    if let s = try? await item.load(.stringValue), let d = ISO8601DateFormatter().date(from: s) { return d }
                }
            }
            return nil
        }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        for case let s? in [exif?[kCGImagePropertyExifDateTimeOriginal] as? String,
                            exif?[kCGImagePropertyExifDateTimeDigitized] as? String,
                            tiff?[kCGImagePropertyTIFFDateTime] as? String] {
            if let d = f.date(from: s) { return d }
        }
        return nil
    }

    /// Keeps a capture date the downloaded file (a local temp) already has; otherwise writes `posted`
    /// into it. Returns the date the file now stands for (for its file dates), or nil if neither.
    /// Photos: a metadata-only rewrite (`CGImageDestinationCopyImageSource`, no re-encode) for the
    /// formats ImageIO can write; WebP/GIF/AVIF just get file dates. Videos: a passthrough remux.
    static func settleDate(_ temp: URL, posted: Double) async -> Date? {
        if let have = await embeddedDate(temp) { return have }
        guard posted > 0 else { return nil }
        let date = Date(timeIntervalSince1970: posted)
        if isVideo(temp) { await stampVideo(temp, date: date) } else { stampPhoto(temp, date: date) }
        return date
    }

    private static func stampPhoto(_ url: URL, date: Date) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(src),
              [UTType.jpeg, .png, .heic, .tiff].contains(where: { $0.identifier == type as String }) else { return }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy:MM:dd HH:mm:ss"; f.timeZone = .current
        let stamp = f.string(from: date)
        let meta = CGImageMetadataCreateMutable()
        for (dict, key) in [(kCGImagePropertyExifDictionary, kCGImagePropertyExifDateTimeOriginal),
                            (kCGImagePropertyExifDictionary, kCGImagePropertyExifDateTimeDigitized),
                            (kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFDateTime)] {
            CGImageMetadataSetValueMatchingImageProperty(meta, dict, key, stamp as CFString)
        }
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".sc_" + UUID().uuidString)
            .appendingPathExtension(url.pathExtension)
        guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, type, 1, nil) else { return }
        let options: [CFString: Any] = [kCGImageDestinationMetadata: meta, kCGImageDestinationMergeMetadata: true]
        guard CGImageDestinationCopyImageSource(dest, src, options as CFDictionary, nil) else {
            try? FileManager.default.removeItem(at: tmp); return
        }
        _ = try? FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }

    private static func stampVideo(_ url: URL, date: Date) async {
        let asset = AVURLAsset(url: url)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else { return }
        let iso = ISO8601DateFormatter().string(from: date)
        var meta = (try? await asset.load(.metadata)) ?? []
        for id in [AVMetadataIdentifier.commonIdentifierCreationDate, .quickTimeMetadataCreationDate] {
            let item = AVMutableMetadataItem(); item.identifier = id; item.value = iso as NSString; meta.append(item)
        }
        export.metadata = meta
        let isMov = url.pathExtension.lowercased() == "mov"
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".sc_" + UUID().uuidString)
            .appendingPathExtension(isMov ? "mov" : "mp4")
        export.outputURL = tmp
        export.outputFileType = isMov ? .mov : .mp4
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in export.exportAsynchronously { c.resume() } }
        guard export.status == .completed else { try? FileManager.default.removeItem(at: tmp); return }
        _ = try? FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }

    // MARK: - Helpers

    private static func firstGroups(_ s: String, _ pattern: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (1..<m.numberOfRanges).map { i in
            Range(m.range(at: i), in: s).map { String(s[$0]) } ?? ""
        }
    }
}
