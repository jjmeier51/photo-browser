import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Per-folder record for a downloaded VSCO profile (drives "Get New VSCO Photos" and dedup).
/// Stored on `Library`, keyed by the profile folder path.
struct VSCOFolderInfo: Codable, Sendable {
    var username: String
    var siteID: String
    var lastUpdated: Double
    var downloaded: [String]      // media ids already pulled (dedup)
    var photos: Int
    var videos: Int
}

/// Downloads a public VSCO profile's whole gallery by username, using VSCO's public web API
/// (no login): resolve the profile's `site_id` from the username, page through its media, and
/// download each item — photos **and** videos — at full resolution into a "username" folder.
///
/// EXIF is preserved: the bytes VSCO serves are written verbatim, so whatever capture
/// date/camera metadata the file already carries stays intact. When a photo has **no** embedded
/// capture date, VSCO's posting date (the media's capture_date, else upload_date) is written into
/// EXIF and stamped on the file, so it still sorts by when it was posted.
///
/// All `nonisolated` (networking + parsing + ImageIO + drive writes stay off the main actor).
/// Best-effort and download-only, like the Instagram/TikTok/Facebook features — VSCO's web API is
/// unofficial, so parsing is defensive and failures are surfaced as notes, never crashes.
enum VSCOService {
    nonisolated static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
    /// The public anonymous web token VSCO's own site uses for browsing (the same constant the
    /// open-source VSCO downloaders rely on). If VSCO rotates it, a run just comes back empty and
    /// says so — it's never treated as fatal.
    nonisolated static let webToken = "7356455548d0a1d886db010883388d08be84d0c9"

    struct Progress: Sendable { var phase: String; var fraction: Double; var done: Int; var total: Int }
    struct DownloadResult: Sendable {
        var photos = 0, videos = 0, failed = 0
        var newIDs: [String] = []
        var captions: [String: String] = [:]
        var profilePic: Data?
        var siteID = ""
        var note: String?
    }
    private struct Item: Sendable { let id: String; let url: String; let isVideo: Bool; let date: Date?; let caption: String }

    nonisolated static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpShouldSetCookies = false
        cfg.httpCookieStorage = nil
        cfg.timeoutIntervalForRequest = 60
        cfg.httpMaximumConnectionsPerHost = 12
        return URLSession(configuration: cfg)
    }()

    // MARK: - Run

    nonisolated static func run(username: String, into folder: URL, alreadyDownloaded: Set<String>,
                                progress: @escaping @Sendable (Progress) -> Void) async -> DownloadResult {
        var result = DownloadResult()
        let user = sanitizeUsername(username)
        guard !user.isEmpty else { result.note = "Enter a VSCO username."; return result }
        progress(Progress(phase: "Finding @\(user)…", fraction: 0, done: 0, total: 0))

        let log = DownloadLog(folder: folder, kind: "vsco")
        await log.begin("VSCO download — @\(user)")

        guard let site = await resolveSite(user) else {
            result.note = "Couldn’t open @\(user) on VSCO — check the username (and that the profile is public)."
            await log.finish("FAILED: site not found for @\(user)")
            return result
        }
        result.siteID = site.id
        await log.log("site: id=\(site.id) name=\(site.name)")
        if !site.picURL.isEmpty { result.profilePic = await downloadData(site.picURL) }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // Page through the whole gallery.
        progress(Progress(phase: "Listing @\(user)’s posts…", fraction: 0, done: 0, total: 0))
        let items = await listAllMedia(siteID: site.id, log: log)
        await log.log("listed \(items.count) media item(s) across the gallery")
        let pending = items.filter { !alreadyDownloaded.contains($0.id) }
        guard !pending.isEmpty else {
            result.note = items.isEmpty
                ? "Couldn’t find any posts (VSCO may be blocking, or the profile is empty/private)."
                : (alreadyDownloaded.isEmpty ? "No downloadable posts found." : "No new posts.")
            await log.finish("nothing to download — listed \(items.count), all already downloaded")
            return result
        }

        // Download concurrently (bounded), streaming progress.
        let total = pending.count
        var done = 0
        var captions: [String: String] = [:]
        var newIDs: [String] = []
        await withTaskGroup(of: (ok: Bool, isVideo: Bool, id: String, path: String?, caption: String).self) { group in
            var idx = 0
            let maxConcurrent = 6
            func addNext() {
                guard idx < pending.count else { return }
                let it = pending[idx]; idx += 1
                group.addTask { await download(it, into: folder) }
            }
            for _ in 0..<min(maxConcurrent, total) { addNext() }
            while let r = await group.next() {
                if r.ok {
                    if r.isVideo { result.videos += 1 } else { result.photos += 1 }
                    newIDs.append(r.id)
                    if let path = r.path, !r.caption.isEmpty { captions[path] = r.caption }
                } else { result.failed += 1 }
                done += 1
                if done == total || done % 4 == 0 {
                    progress(Progress(phase: "Downloading \(done) of \(total)…",
                                      fraction: Double(done) / Double(total), done: done, total: total))
                }
                addNext()
            }
        }
        result.captions = captions
        result.newIDs = newIDs
        if result.photos + result.videos == 0 { result.note = "Couldn’t download any media (VSCO may be blocking access)." }
        else if result.failed > 0 { result.note = "\(result.failed) item(s) couldn’t be downloaded." }
        await log.finish("photos \(result.photos), videos \(result.videos), failed \(result.failed), listed \(items.count)")
        return result
    }

    // MARK: - Profile + listing

    private struct Site: Sendable { let id: String; let name: String; let picURL: String }

    /// Resolves a username to its VSCO `site_id` (+ display name and avatar).
    nonisolated private static func resolveSite(_ username: String) async -> Site? {
        guard let data = await apiGet("https://vsco.co/api/2.0/sites?subdomain=\(username)"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sites = json["sites"] as? [[String: Any]], let s = sites.first,
              let id = idString(s["id"]) else { return nil }
        let name = (s["name"] as? String) ?? (s["domain"] as? String) ?? username
        let pic = absolute((s["profile_image"] as? String) ?? (s["responsive_url"] as? String) ?? "")
        return Site(id: id, name: name, picURL: pic)
    }

    /// Every media item in the profile, paged (newest-first) until VSCO returns none.
    nonisolated private static func listAllMedia(siteID: String, log: DownloadLog?) async -> [Item] {
        var out: [Item] = []
        var seen = Set<String>()
        var page = 1
        while page <= 200 {          // hard cap: 200 × 100 = 20k media
            guard let data = await apiGet("https://vsco.co/api/2.0/medias?site_id=\(siteID)&page=\(page)&size=100"),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                await log?.log("page \(page): fetch/parse failed — stopping"); break
            }
            let media = (json["media"] as? [[String: Any]]) ?? []
            guard !media.isEmpty else { break }
            var added = 0
            for m in media {
                guard let it = parseItem(m), seen.insert(it.id).inserted else { continue }
                out.append(it); added += 1
            }
            await log?.log("page \(page): \(media.count) item(s), \(added) new (total \(out.count))")
            if added == 0 { break }   // fully-overlapping page → done
            page += 1
        }
        return out
    }

    /// Parses one VSCO media object into a downloadable item, tolerating field-name drift.
    nonisolated private static func parseItem(_ m: [String: Any]) -> Item? {
        guard let id = idString(m["_id"]) ?? idString(m["upload_id"]) ?? idString(m["id"]) else { return nil }
        let isVideo = (m["is_video"] as? Bool) ?? (m["video_url"] != nil)
        let urlStr: String
        if isVideo {
            urlStr = absolute((m["video_url"] as? String) ?? (m["responsive_url"] as? String) ?? "")
        } else {
            urlStr = absolute((m["responsive_url"] as? String) ?? (m["img_url"] as? String) ?? "")
        }
        guard !urlStr.isEmpty else { return nil }
        // Posting date: capture_date is the shot time when VSCO has it, else upload_date.
        // Both are epoch milliseconds.
        let ms = doubleValue(m["capture_date"]).flatMap { $0 > 0 ? $0 : nil }
            ?? doubleValue(m["upload_date"]).flatMap { $0 > 0 ? $0 : nil }
        let date = ms.map { Date(timeIntervalSince1970: $0 / 1000) }
        let caption = ((m["description"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return Item(id: id, url: urlStr, isVideo: isVideo, date: date, caption: caption)
    }

    // MARK: - Per-item download (EXIF preserved; posting date filled in when absent)

    nonisolated private static func download(_ item: Item, into folder: URL) async -> (ok: Bool, isVideo: Bool, id: String, path: String?, caption: String) {
        guard let data = await downloadData(item.url), data.count >= 512 else {
            return (false, item.isVideo, item.id, nil, "")
        }
        let ext = item.isVideo ? "mp4" : imageExt(of: item.url)
        let dest = uniqueDestination("VSCO_\(item.id).\(ext)", in: folder)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("vsco_\(UUID().uuidString).\(ext)")

        if item.isVideo {
            guard (try? data.write(to: tmp, options: .atomic)) != nil else { return (false, true, item.id, nil, "") }
        } else {
            // Write the photo, embedding the VSCO posting date only if the file has no EXIF date
            // of its own (so genuine capture metadata is never overwritten).
            guard writePhoto(data, to: tmp, postingDate: item.date) else { return (false, false, item.id, nil, "") }
        }
        do { try await DriveWriter.shared.commit(tmp, to: dest) }
        catch { try? FileManager.default.removeItem(at: tmp); return (false, item.isVideo, item.id, nil, "") }
        // Stamp the file's dates too (so Age/sort work even with no EXIF).
        if let d = item.date {
            try? FileManager.default.setAttributes([.creationDate: d, .modificationDate: d], ofItemAtPath: dest.path)
        }
        return (true, item.isVideo, item.id, dest.path, item.caption)
    }

    /// Writes photo bytes, preserving all existing metadata; when the image carries no capture
    /// date, the VSCO posting date is added to EXIF/TIFF. Falls back to a verbatim write.
    nonisolated private static func writePhoto(_ data: Data, to dest: URL, postingDate: Date?) -> Bool {
        if let postingDate,
           let src = CGImageSourceCreateWithData(data as CFData, nil),
           let type = CGImageSourceGetType(src),
           !hasExifDate(src) {
            var props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy:MM:dd HH:mm:ss"; f.timeZone = .current
            let stamp = f.string(from: postingDate)
            var exif = (props[kCGImagePropertyExifDictionary] as? [CFString: Any]) ?? [:]
            exif[kCGImagePropertyExifDateTimeOriginal] = stamp
            exif[kCGImagePropertyExifDateTimeDigitized] = stamp
            props[kCGImagePropertyExifDictionary] = exif
            var tiff = (props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]) ?? [:]
            tiff[kCGImagePropertyTIFFDateTime] = stamp
            props[kCGImagePropertyTIFFDictionary] = tiff
            if let dst = CGImageDestinationCreateWithURL(dest as CFURL, type, 1, nil) {
                CGImageDestinationAddImageFromSource(dst, src, 0, props as CFDictionary)
                if CGImageDestinationFinalize(dst) { return true }
            }
        }
        // Nothing to add (or the file already has a date, or embed failed) — write verbatim so
        // the original EXIF is preserved byte-for-byte.
        return (try? data.write(to: dest, options: .atomic)) != nil
    }

    /// Whether the image already carries an EXIF/TIFF capture date.
    nonisolated private static func hasExifDate(_ src: CGImageSource) -> Bool {
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return false }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        return (exif?[kCGImagePropertyExifDateTimeOriginal] != nil)
            || (exif?[kCGImagePropertyExifDateTimeDigitized] != nil)
            || (tiff?[kCGImagePropertyTIFFDateTime] != nil)
    }

    // MARK: - HTTP

    nonisolated private static func apiGet(_ urlString: String) async -> Data? {
        guard let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("Bearer \(webToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("https://vsco.co/", forHTTPHeaderField: "Referer")
        req.timeoutInterval = 30
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: UInt64(attempt) * 800_000_000) }
            guard let (data, resp) = try? await session.data(for: req) else { continue }
            if let code = (resp as? HTTPURLResponse)?.statusCode {
                if code == 429 || code >= 500 { continue }
                if code >= 400 { return nil }
            }
            return data
        }
        return nil
    }

    nonisolated static func downloadData(_ urlString: String) async -> Data? {
        guard !urlString.isEmpty, let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("https://vsco.co/", forHTTPHeaderField: "Referer")
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: UInt64(attempt) * 700_000_000) }
            guard let (data, resp) = try? await session.data(for: req) else { continue }
            if let code = (resp as? HTTPURLResponse)?.statusCode {
                if code == 429 || code >= 500 { continue }
                if code >= 400 { return nil }
            }
            return data
        }
        return nil
    }

    // MARK: - Helpers

    /// VSCO serves `responsive_url` without a scheme (e.g. "im.vsco.co/…/file.jpg").
    nonisolated static func absolute(_ u: String) -> String {
        if u.isEmpty || u.hasPrefix("http") { return u }
        return "https://" + u.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    nonisolated static func sanitizeUsername(_ s: String) -> String {
        var h = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = h.range(of: "vsco.co/") { h = String(h[r.upperBound...]) }
        h = String(h.split(separator: "/").first ?? "")
        h = String(h.split(separator: "?").first ?? "")
        return h.replacingOccurrences(of: "@", with: "").lowercased()
    }

    nonisolated private static func imageExt(of urlString: String) -> String {
        let path = URLComponents(string: urlString)?.path.lowercased() ?? ""
        for ext in ["jpg", "jpeg", "png", "webp", "heic"] where path.hasSuffix("." + ext) { return ext == "jpeg" ? "jpg" : ext }
        return "jpg"
    }

    nonisolated private static func uniqueDestination(_ name: String, in folder: URL) -> URL {
        let fm = FileManager.default
        var dest = folder.appendingPathComponent(name)
        let base = dest.deletingPathExtension().lastPathComponent, ext = dest.pathExtension
        var n = 1
        while fm.fileExists(atPath: dest.path) { dest = folder.appendingPathComponent("\(base) \(n).\(ext)"); n += 1 }
        return dest
    }

    nonisolated private static func idString(_ any: Any?) -> String? {
        if let s = any as? String { return s.isEmpty ? nil : s }
        if let n = any as? NSNumber { return n.stringValue }
        return nil
    }
    nonisolated private static func doubleValue(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s) }
        return nil
    }
}
