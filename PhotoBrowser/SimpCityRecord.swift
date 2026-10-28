import Foundation
import ImageIO
import UniformTypeIdentifiers
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CryptoKit

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
/// A post time is XenForo's `data-timestamp` (2.2+: `data-time` is a label like "12:34 PM" — reading it
/// as a number dated the first downloads 12/31/1969); anything before 2000 is no date at all, and an
/// embedded 1969/1970 date (what that misread wrote) doesn't count as the file's own.
///
/// **Photos.** A WebP becomes a JPEG and a photo under 250 KB is upscaled 2× (Lanczos) — tagged
/// "upscaled" like the app's own upscales. Entries written before these rules (no `made` mark) are
/// brought up to them once, where they lie (`fixes`, `SimpCityDownloader.fixFile`), and a record with
/// misread post times has its thread read from page 1 again to recover them (`misdated`, `redate`).
///
/// **Videos on file hosts** (`SimpCityHosts`): a post's pixeldrain/gofile/cyberdrop/bunkr/filester/
/// fileditch videos are keyed `<host>:<file id>` and named `<host>-<file id>.<ext>`; the links are kept
/// under `links` (one done isn't listed again). The same video posted on several hosts is fetched once
/// (`Dedup`: the hosts' sizes up front, the server's size as a download starts, the SHA-256 once it's in)
/// and the other copies are recorded `same_as` the one kept. With "Download videos" off, turbo and the
/// links are noted (`skipped`) so a later run gets them without reading the thread again.
nonisolated enum SimpCity {
    static let folderName = "simpcity"
    static let recordName = ".simpcity.json"
    static let format = "photobrowser-simpcity"
    static let tag = "simpcity"
    static let upscaledTag = "upscaled"
    /// 2000-01-01: no post is older — a time below this is a misread, not a date.
    static let minPost: Double = 946_684_800
    /// A photo smaller than this is upscaled 2× (Lanczos).
    static let upscaleUnder = 250 * 1024
    /// Record mark: the file went through the current rules (WebP → JPEG, the upscale, a real post date).
    static let made = 2
    /// Thread mark: its pages were read for file-host links too.
    static let hostsRead = 1
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

    /// The file extension for a resolved file URL (its path, not the query) — or, for a file-host video,
    /// its name there.
    static func fileExtension(_ url: String, kind: String, name: String = "") -> String {
        for last in [name, URL(string: url)?.lastPathComponent ?? ""] {
            var ext = last.contains(".") ? (last.split(separator: ".").last.map(String.init) ?? "").lowercased() : ""
            if ext == "jpeg" { ext = "jpg" }
            if imageExts.contains(ext) || videoExts.contains(ext) { return ext }
        }
        return kind == "goonbox" ? "jpg" : "mp4"
    }

    /// Something the downloader takes: a goonbox/turbo link or a file-host link.
    static func isLink(_ url: String) -> Bool { mediaKey(url) != nil || SimpCityHosts.classify(url) != nil }

    nonisolated struct Item: Sendable {
        /// "goonbox" | "turbo" | a file host (`SimpCityHosts.hosts`).
        let kind: String
        let id: String
        let link: String
        var post: String
        var posted: Double
        /// A file-host video: what the host said about it.
        var remote: SimpCityHosts.Remote? = nil
        /// A file-host video: the key of the link it was listed from.
        var via = ""
        var key: String { "\(kind):\(id)" }
        /// Its file name without the extension: `<id>`, or `<host>-<id>` for a file-host video.
        var stem: String { kind == "goonbox" || kind == "turbo" ? id : "\(kind)-\(id)" }
        var isVideo: Bool { kind != "goonbox" }
    }

    /// Items from the posts one page read returned (`[{id, time, urls}]`), one per key, keeping the
    /// earliest post a file appeared in — and, into `links`, the file-host links, the same way.
    static func collect(posts: [[String: Any]], into out: inout [String: Item], links: inout [String: SimpCityHosts.Link]) {
        for p in posts {
            var when = (p["time"] as? NSNumber)?.doubleValue ?? 0
            if when < minPost { when = 0 }
            let post = (p["id"] as? String) ?? (p["id"] as? NSNumber)?.stringValue ?? ""
            for case let u as String in (p["urls"] as? [Any] ?? []) {
                guard let k = mediaKey(u) else {
                    if var lk = SimpCityHosts.classify(u) {
                        lk.post = post; lk.posted = when
                        if let have = links[lk.key] {
                            if when > 0, have.posted == 0 || when < have.posted { links[lk.key] = lk }
                        } else {
                            links[lk.key] = lk
                        }
                    }
                    continue
                }
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
        /// File-host links: what each held (its videos' keys), whether it's done.
        private(set) var links: [String: [String: Any]] = [:]

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
            for (k, v) in doc["links"] as? [String: Any] ?? [:] {
                guard let v = v as? [String: Any] else { continue }
                // A link done on either side is done; otherwise the newer word on it stands.
                let theirsDone = (v["done"] as? Bool) == true
                if let mine = links[k] {
                    let mineDone = (mine["done"] as? Bool) == true
                    guard (theirsDone && !mineDone) || (theirsDone == mineDone && num(v["checked"]) > num(mine["checked"])) else { continue }
                }
                links[k] = v
            }
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

        /// A file saved into the folder. For a video, `size`/`sha256` are those of the file as downloaded
        /// (before its date was written into it) — what another host's copy is compared with.
        mutating func add(_ item: Item, file: String, upscaled: Bool = false, size: Int64 = 0, sha256: String = "") {
            var entry: [String: Any] = ["file": file, "post": item.post, "posted": Int(item.posted),
                                        "at": Int(Date().timeIntervalSince1970), "made": SimpCity.made]
            if upscaled || (items[item.key]?["upscaled"] as? Bool) == true { entry["upscaled"] = true }
            if size > 0 { entry["size"] = size }
            if !sha256.isEmpty { entry["sha256"] = sha256 }
            if !item.via.isEmpty { entry["via"] = item.via }
            if let name = item.remote?.name, !name.isEmpty { entry["name"] = name }
            items[item.key] = entry
            failed[item.key] = nil
        }

        /// A video that is one already downloaded (`other`'s key), on another host or link: done, not saved.
        mutating func addSame(_ item: Item, other: String) {
            var entry: [String: Any] = ["same_as": other, "post": item.post, "posted": Int(item.posted),
                                        "at": Int(Date().timeIntervalSince1970), "made": SimpCity.made]
            if !item.via.isEmpty { entry["via"] = item.via }
            items[item.key] = entry
            failed[item.key] = nil
        }

        /// Nothing to keep (a file-host link that turned out not to be a video): done, never tried again.
        mutating func addSkipped(_ item: Item, why: String) {
            var entry: [String: Any] = ["skipped": why, "post": item.post, "posted": Int(item.posted),
                                        "at": Int(Date().timeIntervalSince1970), "made": SimpCity.made]
            if !item.via.isEmpty { entry["via"] = item.via }
            items[item.key] = entry
            failed[item.key] = nil
        }

        /// The file a key was saved as — following `same_as` to the copy kept.
        func fileOf(_ key: String) -> String {
            let e = items[key] ?? [:]
            if let f = e["file"] as? String, !f.isEmpty { return f }
            return (items[(e["same_as"] as? String) ?? ""]?["file"] as? String) ?? ""
        }

        /// Entries written while post times were misread — a full read of the thread recovers them.
        var misdated: Bool {
            items.values.contains { let p = num($0["posted"]); return p > 0 && p < SimpCity.minPost }
        }

        /// After reading the thread: a misread post time is replaced by the real one; when every page was
        /// read, one still unknown (its post is gone) becomes 0 so the thread isn't read again for it.
        mutating func redate(_ fresh: [String: Item], readAll: Bool) {
            for (k, v) in items {
                let p = num(v["posted"])
                guard p > 0, p < SimpCity.minPost else { continue }
                var e = v
                if let f = fresh[k], f.posted >= SimpCity.minPost { e["posted"] = Int(f.posted) }
                else if readAll { e["posted"] = 0 } else { continue }
                items[k] = e
            }
        }

        /// Downloaded files still in the folder that predate the current rules (`made`), each with the
        /// best post date known: the one just read from the thread, else the recorded one if it's real.
        func fixes(_ fresh: [String: Item], present: Set<String>) -> [(item: Item, name: String)] {
            var out: [(item: Item, name: String)] = []
            for (key, entry) in items.sorted(by: { $0.key < $1.key }) {
                guard let name = entry["file"] as? String, present.contains(name),
                      Int(num(entry["made"])) < SimpCity.made else { continue }
                let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                let f = fresh[key]
                let recorded = num(entry["posted"])
                let posted = (f?.posted ?? 0) >= SimpCity.minPost ? f!.posted : (recorded >= SimpCity.minPost ? recorded : 0)
                out.append((Item(kind: parts[0], id: parts[1], link: f?.link ?? SimpCity.pageLink(kind: parts[0], id: parts[1]),
                                 post: f?.post ?? (entry["post"] as? String ?? ""), posted: posted), name))
            }
            return out
        }

        /// Remembered so a later run tries it again. A file-host video is tried again through its link
        /// (`via`), which stays not done. `skipped`: a video left alone because "Download videos" was off.
        mutating func noteFailed(_ item: Item, skipped: Bool = false) {
            var entry: [String: Any] = ["link": item.link, "post": item.post, "posted": Int(item.posted)]
            if !item.via.isEmpty { entry["via"] = item.via }
            if skipped { entry["skipped"] = true }
            failed[item.key] = entry
        }

        /// What failed before, as items to try again (turbo's only with videos on).
        func retryItems(videos: Bool = true) -> [String: Item] {
            var out: [String: Item] = [:]
            for (k, v) in failed where items[k] == nil {
                let parts = k.split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2, ["goonbox", "turbo"].contains(parts[0]), !parts[1].isEmpty else { continue }
                if parts[0] == "turbo", !videos { continue }
                out[k] = Item(kind: parts[0], id: parts[1],
                              link: (v["link"] as? String) ?? SimpCity.pageLink(kind: parts[0], id: parts[1]),
                              post: (v["post"] as? String) ?? "", posted: num(v["posted"]))
            }
            return out
        }

        // MARK: File-host links

        /// The file-host links to list this run: the ones the pages read hold that aren't done (all of them
        /// when `again` — a folder can gain files), plus every earlier one not done. With videos off none
        /// are listed; the ones found are noted (`skipped`) so a later run with videos on gets them.
        mutating func linksTodo(_ found: [String: SimpCityHosts.Link], videos: Bool, again: Bool) -> [SimpCityHosts.Link] {
            var out: [String: SimpCityHosts.Link] = [:]
            for (k, lk) in found {
                let done = (links[k]?["done"] as? Bool) == true
                if !videos {
                    if links[k] == nil {
                        links[k] = ["url": lk.url, "post": lk.post, "posted": Int(lk.posted), "done": false, "skipped": true,
                                    "checked": Int(Date().timeIntervalSince1970)]
                    }
                    continue
                }
                if done, !again { continue }
                if links[k] == nil || links[k]?["skipped"] != nil {
                    // Noted now, so a run stopped before it's listed still lists it next time.
                    links[k] = ["url": lk.url, "post": lk.post, "posted": Int(lk.posted), "done": false,
                                "checked": Int(Date().timeIntervalSince1970)]
                }
                out[k] = lk
            }
            if videos {
                let vias = Set(failed.values.compactMap { $0["via"] as? String })
                for (k, e) in links where out[k] == nil {
                    if (e["done"] as? Bool) == true, !vias.contains(k) { continue }
                    if var lk = SimpCityHosts.classify((e["url"] as? String) ?? ""), lk.key == k {
                        lk.post = (e["post"] as? String) ?? ""; lk.posted = num(e["posted"])
                        out[k] = lk
                    }
                }
            }
            return out.values.sorted { ($0.posted, $0.key) < ($1.posted, $1.key) }
        }

        /// What a link held (its videos' keys) — done once every one is in `items`; a dead link is done. A
        /// video that failed before and the link no longer holds (or the link is gone) is done too.
        mutating func noteLink(_ lk: SimpCityHosts.Link, files: [String], why: String = "", gone: Bool = false) {
            if why.isEmpty {
                for (k, v) in failed where (v["via"] as? String) == lk.key && (gone || !files.contains(k)) {
                    items[k] = ["skipped": gone ? "its link is gone" : "no longer in its link", "via": lk.key,
                                "post": (v["post"] as? String) ?? "", "posted": Int(num(v["posted"])),
                                "at": Int(Date().timeIntervalSince1970), "made": SimpCity.made]
                    failed[k] = nil
                }
            }
            var e: [String: Any] = ["url": lk.url, "post": lk.post, "posted": Int(lk.posted), "files": files,
                                    "done": gone || (why.isEmpty && files.allSatisfy { items[$0] != nil }),
                                    "checked": Int(Date().timeIntervalSince1970)]
            if !why.isEmpty { e["why"] = why }
            if gone { e["gone"] = true }
            links[lk.key] = e
        }

        /// At the end of a run: a link is done when everything it held is.
        mutating func settleLinks() {
            for (k, e) in links {
                guard (e["done"] as? Bool) != true, e["why"] == nil, e["skipped"] == nil, let files = e["files"] as? [String] else { continue }
                var d = e
                d["done"] = files.allSatisfy { items[$0] != nil }
                links[k] = d
            }
        }

        mutating func noteThread(_ base: String, title: String, pages: Int, hosts: Bool = false) {
            var t = threads[base] ?? [:]
            t["title"] = title.isEmpty ? (t["title"] as? String ?? "") : title
            t["pages"] = max(pages, Int(num(t["pages"])))
            t["checked"] = Int(Date().timeIntervalSince1970)
            if hosts { t["hosts"] = SimpCity.hostsRead }
            threads[base] = t
        }

        /// Where a run picks the thread up: the last page read (it may have grown since), else 1 — and 1
        /// while any entry's date was misread, to read it again, or when the thread was last read before
        /// file-host links were collected and videos are wanted.
        func startPage(_ base: String, videos: Bool = false) -> Int {
            if misdated { return 1 }
            if videos, Int(num(threads[base]?["hosts"])) < SimpCity.hostsRead { return 1 }
            return max(1, Int(num(threads[base]?["pages"])))
        }

        /// The thread most recently read here — what "Get New" offers.
        var lastThread: String? {
            threads.max { num($0.value["checked"]) < num($1.value["checked"]) }?.key
        }

        /// Writes the record, merged with whatever is on the drive now (Safe Finder may have added to it).
        mutating func save() throws {
            merge(read())
            let doc: [String: Any] = ["format": SimpCity.format, "version": 1,
                                      "updated": Int(Date().timeIntervalSince1970), "by": "Photo Browser",
                                      "threads": threads, "items": items, "failed": failed, "links": links]
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
    /// the record, they're done). With videos off, turbo's are noted for later instead.
    static func todo(_ items: [String: Item], record: inout Record, folder: URL, videos: Bool = true) -> (left: [Item], adopted: Int) {
        var items = items
        for (k, it) in record.retryItems(videos: videos) where items[k] == nil { items[k] = it }
        let onDisk = filesByID(in: folder)
        var left: [Item] = [], adopted = 0
        for item in items.values where !record.has(item.key) {
            if let name = onDisk[item.stem] { record.add(item, file: name); adopted += 1; continue }
            if item.isVideo, !videos {
                if record.failed[item.key] == nil { record.noteFailed(item, skipped: true) }
                continue
            }
            left.append(item)
        }
        left.sort { ($0.posted, $0.key) < ($1.posted, $1.key) }
        return (left, adopted)
    }

    /// The file-host videos still to download, from the links listed this run (one item per file, the copy
    /// on the preferred host first). One the record has, or the folder holds, is done; one the host says
    /// is the same size (or SHA-256) as one already downloaded is recorded as that one; one the same size
    /// as another to download this run waits on it (`Dedup.wait`) — fetched only if that fails.
    static func hostItems(_ listed: [(link: SimpCityHosts.Link, remotes: [SimpCityHosts.Remote])], record: inout Record,
                          folder: URL, dedup: Dedup) -> (left: [Item], adopted: Int, same: Int) {
        let onDisk = filesByID(in: folder)
        var seen: [String: Item] = [:]
        for (lk, remotes) in listed {
            for r in remotes {
                let it = Item(kind: r.host, id: r.fid, link: r.page.isEmpty ? (r.url.isEmpty ? lk.url : r.url) : r.page,
                              post: lk.post, posted: lk.posted, remote: r, via: lk.key)
                if let have = seen[it.key], !(it.posted > 0 && (have.posted == 0 || it.posted < have.posted)) { continue }
                seen[it.key] = it
            }
        }
        // A locked pixeldrain file (its hotlink captcha) comes last: any other host's copy is fetched instead.
        func rank(_ i: Item) -> Int { i.remote?.locked == true ? 99 : (SimpCityHosts.preference[i.kind] ?? 9) }
        let ordered = seen.values.sorted { (rank($0), $0.posted, $0.key) < (rank($1), $1.posted, $1.key) }
        var left: [Item] = [], adopted = 0, same = 0
        var lockedSizes: [Int64: String] = [:]
        for it in ordered where !record.has(it.key) {
            if let name = onDisk[it.stem] { record.add(it, file: name); adopted += 1; continue }
            let r = it.remote
            if let r, r.locked {
                // Never claims a size: a copy that turns up elsewhere (turbo, a browser-read host) still wins.
                let other = dedup.peekHash(r.sha256) ?? dedup.peek(r.size)
                    ?? (r.size >= Dedup.minSize ? lockedSizes[r.size] : nil)
                if let other, record.has(other) { record.addSame(it, other: other); same += 1 }
                else if let other { _ = dedup.wait(other, it) }
                else {
                    if r.size >= Dedup.minSize { lockedSizes[r.size] = it.key }
                    left.append(it)
                }
                continue
            }
            var other: String?
            if let sha = r?.sha256, !sha.isEmpty { other = dedup.matchHash(it.key, sha) }
            if other == nil, let size = r?.size, size > 0 { other = dedup.claim(it.key, size: size) }
            if let other, record.has(other) { record.addSame(it, other: other); same += 1 }
            else if let other { _ = dedup.wait(other, it) }
            else { left.append(it) }
        }
        left.sort { ($0.posted, $0.key) < ($1.posted, $1.key) }
        return (left, adopted, same)
    }

    /// A download not to keep, known as it starts or once it's in.
    nonisolated enum Skip: Error {
        /// The same video as this key (another host's copy, or one downloaded before).
        case duplicate(String)
        /// A file-host link that turned out to be something other than a video.
        case notVideo(String)
    }

    /// Which videos are which: by the exact size of the file as downloaded, and its SHA-256 (`simpcity.Dedup`).
    /// A size is only trusted from 1 MB up. Thread-safe. `waiting` holds the copies waiting on another to
    /// download (`wait`); they're recorded as it if it's saved, and tried themselves if it fails (`settle`).
    nonisolated final class Dedup: @unchecked Sendable {
        static let minSize: Int64 = 1 << 20
        private let lock = NSLock()
        private var sizes: [Int64: String] = [:]
        private var hashes: [String: String] = [:]
        private var waiting: [String: [Item]] = [:]
        private var lost = Set<String>()

        /// What's downloaded already: the recorded sizes and hashes — and, for videos recorded before these
        /// were kept, the size of the file in the folder (right whenever its own date was kept).
        func seed(_ record: Record, folder: URL) {
            lock.lock(); defer { lock.unlock() }
            for (k, v) in record.items {
                guard let name = v["file"] as? String, !name.isEmpty, SimpCity.isVideo(URL(fileURLWithPath: name)) else { continue }
                var size = SimpCityHosts.int64(v["size"])
                if size == 0 {
                    size = Int64((try? folder.appendingPathComponent(name).resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                }
                if size >= Self.minSize, sizes[size] == nil { sizes[size] = k }
                if let sha = v["sha256"] as? String, !sha.isEmpty, hashes[sha.lowercased()] == nil { hashes[sha.lowercased()] = k }
            }
        }

        /// The key of a video already this size (downloaded or on its way) — else `size` is `key`'s.
        func claim(_ key: String, size: Int64?) -> String? {
            guard let size, size >= Self.minSize else { return nil }
            lock.lock(); defer { lock.unlock() }
            if let other = sizes[size], other != key { return other }
            sizes[size] = key
            return nil
        }

        func matchHash(_ key: String, _ sha: String) -> String? {
            guard !sha.isEmpty else { return nil }
            lock.lock(); defer { lock.unlock() }
            if let other = hashes[sha.lowercased()], other != key { return other }
            hashes[sha.lowercased()] = key
            return nil
        }

        /// The key of a video already this size, without claiming the size.
        func peek(_ size: Int64) -> String? {
            guard size >= Self.minSize else { return nil }
            lock.lock(); defer { lock.unlock() }
            return sizes[size]
        }

        func peekHash(_ sha: String) -> String? {
            guard !sha.isEmpty else { return nil }
            lock.lock(); defer { lock.unlock() }
            return hashes[sha.lowercased()]
        }

        /// A downloaded video's size, for the copies still to come.
        func noteSize(_ key: String, _ size: Int64) {
            guard size >= Self.minSize else { return }
            lock.lock(); defer { lock.unlock() }
            if sizes[size] == nil { sizes[size] = key }
        }

        /// `item` is the same video as `other`, still on its way: it waits for `other`'s outcome. False when
        /// `other` already failed (then `item` should be tried itself).
        func wait(_ other: String, _ item: Item) -> Bool {
            lock.lock(); defer { lock.unlock() }
            if lost.contains(other) { return false }
            waiting[other, default: []].append(item)
            return true
        }

        /// `key`'s download ended: the copies that waited on it. When it failed, its size and hash are let
        /// go — the copies are tried instead.
        func settle(_ key: String, ok: Bool) -> [Item] {
            lock.lock(); defer { lock.unlock() }
            let waiters = waiting.removeValue(forKey: key) ?? []
            if !ok {
                lost.insert(key)
                sizes = sizes.filter { $0.value != key }
                hashes = hashes.filter { $0.value != key }
            }
            return waiters
        }

        func leftWaiting() -> [Item] {
            lock.lock(); defer { lock.unlock() }
            let out = waiting.values.flatMap { $0 }
            waiting = [:]
            return out
        }
    }

    /// SHA-256 of a file, read in 4 MB pieces.
    static func fileSHA256(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Dates

    static func isVideo(_ url: URL) -> Bool { videoExts.contains(url.pathExtension.lowercased()) }

    /// The capture date the file carries itself — the same fields, in the same order, the app sorts by
    /// (`MetadataLoader.readCaptureDate`).
    static func embeddedDate(_ url: URL) async -> Date? {
        if isVideo(url) {
            let asset = AVURLAsset(url: url)
            if let item = try? await asset.load(.creationDate) {
                if let d = try? await item.load(.dateValue), real(d) { return d }
                if let s = try? await item.load(.stringValue), let d = ISO8601DateFormatter().date(from: s), real(d) { return d }
            }
            if let qt = try? await asset.loadMetadata(for: .quickTimeMetadata) {
                for item in qt where (item.key as? String) == "com.apple.quicktime.creationdate" {
                    if let s = try? await item.load(.stringValue), let d = ISO8601DateFormatter().date(from: s), real(d) { return d }
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
            if let d = f.date(from: s), real(d) { return d }
        }
        return nil
    }

    /// Unset dates read as 1904/0000, and the 1969-12-31/1970-01-01 a misread post time wrote, are no date.
    private static func real(_ d: Date) -> Bool { d.timeIntervalSince1970 >= 31_536_000 }

    /// Keeps a capture date the downloaded file (a local temp) already has; otherwise writes `posted`
    /// into it. Returns the date the file now stands for (for its file dates), or nil if neither.
    /// Photos: a metadata-only rewrite (`CGImageDestinationCopyImageSource`, no re-encode) for the
    /// formats ImageIO can write; WebP/GIF/AVIF just get file dates. Videos: a passthrough remux.
    static func settleDate(_ temp: URL, posted: Double) async -> (date: Date?, own: Bool) {
        if let have = await embeddedDate(temp) { return (have, true) }
        guard posted >= minPost else { return (nil, false) }
        let date = Date(timeIntervalSince1970: posted)
        if isVideo(temp) { await stampVideo(temp, date: date) } else { stampPhoto(temp, date: date) }
        return (date, false)
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
        // Any creation date already there (a misread 1970 one) goes, so the new one is the one read.
        let replaced: Set<AVMetadataIdentifier> = [.commonIdentifierCreationDate, .quickTimeMetadataCreationDate]
        var meta = ((try? await asset.load(.metadata)) ?? []).filter { item in
            item.identifier.map { !replaced.contains($0) } ?? true
        }
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

    // MARK: - Photos: WebP → JPEG, small → 2×

    /// A downloaded photo (a local temp) made ready: a WebP becomes a JPEG, and one under 250 KB is
    /// upscaled 2× with Lanczos (`CILanczosScaleTransform`). EXIF/TIFF/GPS and the orientation tag are
    /// carried over (pixels aren't turned); a transparent WebP is put on white. Returns the file now to
    /// use (a `.jpg` beside it for a WebP) and whether it was upscaled. Animated images, other formats,
    /// and anything ImageIO can't read are left as they are. Same rules as `simpcity.prepare_image`.
    static func prepareImage(_ url: URL) -> (url: URL, upscaled: Bool) {
        let ext = url.pathExtension.lowercased()
        guard ["jpg", "jpeg", "png", "webp"].contains(ext) else { return (url, false) }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? Int.max
        let small = size < upscaleUnder
        guard ext == "webp" || small,
              let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(src) == 1,
              var image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return (url, false) }
        var props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
        if small {
            let filter = CIFilter.lanczosScaleTransform()
            filter.inputImage = CIImage(cgImage: image)
            filter.scale = 2
            filter.aspectRatio = 1
            let rect = CGRect(x: 0, y: 0, width: image.width * 2, height: image.height * 2)
            guard let out = filter.outputImage,
                  let scaled = CIContext().createCGImage(out, from: rect) else { return (url, false) }
            image = scaled
        }
        let asPNG = ext == "png"
        let opaque: [CGImageAlphaInfo] = [CGImageAlphaInfo.none, .noneSkipFirst, .noneSkipLast]
        if !asPNG, !opaque.contains(image.alphaInfo), let flat = flattened(image) {
            image = flat
        }
        props[kCGImagePropertyPixelWidth] = nil
        props[kCGImagePropertyPixelHeight] = nil
        if var exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = image.width
            exif[kCGImagePropertyExifPixelYDimension] = image.height
            props[kCGImagePropertyExifDictionary] = exif
        }
        if !asPNG { props[kCGImageDestinationLossyCompressionQuality] = 0.95 }
        let dest = url.deletingPathExtension().appendingPathExtension(asPNG ? "png" : "jpg")
        let part = url.deletingLastPathComponent().appendingPathComponent(".sc_" + UUID().uuidString)
            .appendingPathExtension(asPNG ? "png" : "jpg")
        let type = (asPNG ? UTType.png : UTType.jpeg).identifier as CFString
        guard let out = CGImageDestinationCreateWithURL(part as CFURL, type, 1, nil) else { return (url, false) }
        CGImageDestinationAddImage(out, image, props as CFDictionary)
        guard CGImageDestinationFinalize(out) else { try? FileManager.default.removeItem(at: part); return (url, false) }
        let fm = FileManager.default
        if dest == url {
            guard (try? fm.replaceItemAt(url, withItemAt: part)) != nil else { try? fm.removeItem(at: part); return (url, false) }
        } else {
            try? fm.removeItem(at: dest)
            guard (try? fm.moveItem(at: part, to: dest)) != nil else { try? fm.removeItem(at: part); return (url, false) }
            try? fm.removeItem(at: url)
        }
        return (dest, small)
    }

    /// The image on white, without alpha (JPEG has none).
    private static func flattened(_ image: CGImage) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        return ctx.makeImage()
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
