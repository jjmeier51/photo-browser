import Foundation
import ImageIO
import UniformTypeIdentifiers
import CoreLocation
import AVFoundation
import WebKit

/// Per-folder record for a downloaded Instagram profile (drives "Get New posts",
/// the folder subtitle, and dedup). Persisted on `Library`.
struct IGFolderInfo: Codable, Sendable {
    var handle: String
    var userID: String
    var lastUpdated: Double          // unix time of the last successful run
    var downloaded: [String]         // post shortcodes already pulled (dedup)
    var photos: Int
    var videos: Int
}

/// Reads the logged-in Instagram session straight from the in-app browser's
/// persistent cookie store (so the user logs in once, in a real web view, and we
/// never store their password). MainActor — `WKHTTPCookieStore` is main-bound.
@MainActor
enum InstagramAuth {
    static func cookies() async -> [HTTPCookie] {
        await withCheckedContinuation { cont in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { all in
                cont.resume(returning: all.filter { $0.domain.contains("instagram.com") })
            }
        }
    }

    static func isLoggedIn() async -> Bool {
        await cookies().contains { $0.name == "sessionid" && !$0.value.isEmpty }
    }

    static func logOut() async {
        let store = WKWebsiteDataStore.default().httpCookieStore
        for c in await cookies() {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in store.delete(c) { cont.resume() } }
        }
    }

    /// (Cookie header, csrftoken) for the API requests, or nil if not signed in.
    static func credentials() async -> InstagramService.Credentials? {
        let cs = await cookies()
        guard cs.contains(where: { $0.name == "sessionid" && !$0.value.isEmpty }) else { return nil }
        let header = cs.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        let csrf = cs.first { $0.name == "csrftoken" }?.value ?? ""
        return InstagramService.Credentials(cookie: header, csrf: csrf)
    }
}

/// Downloads a profile's media via Instagram's (unofficial) web/mobile API, using
/// the user's own logged-in session. Like the MEGA client, this is a best-effort
/// reverse-engineered scraper: Instagram changes endpoints/headers often and
/// rate-limits aggressively, so failures are surfaced as notes, never crashes.
/// Everything is `nonisolated` — networking, crypto-free JSON, ImageIO/AVFoundation
/// metadata writes, and large file writes must all stay off the main actor.
enum InstagramService {
    struct Credentials: Sendable { let cookie: String; let csrf: String }
    struct Profile: Sendable { let userID: String; let handle: String; let fullName: String; let profilePicURL: String; let postCount: Int }
    struct Progress: Sendable { var phase: String; var fraction: Double; var done: Int; var total: Int }

    /// One media file to fetch (a post can be a carousel of several).
    private struct Job: Sendable {
        let code: String; let index: Int; let total: Int
        let urlString: String; let isVideo: Bool
        let date: Date; let lat: Double?; let lng: Double?; let caption: String
    }

    struct DownloadResult: Sendable {
        var photos = 0, videos = 0, failed = 0
        var newIDs: [String] = []
        var captions: [String: String] = [:]    // file path → caption (applied to the app's caption field)
        var profilePic: Data?
        var profile: Profile?
        var note: String?
    }

    nonisolated static let appID = "936619743392459"
    nonisolated static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    /// Cookies are supplied per-request, so this session must not add its own.
    nonisolated static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpShouldSetCookies = false
        cfg.httpCookieStorage = nil
        cfg.timeoutIntervalForRequest = 60
        cfg.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: cfg)
    }()

    // MARK: - Orchestration

    /// Full run: load the profile, enumerate posts (stopping at already-downloaded
    /// ones for an update), download every media file with metadata, and fetch the
    /// profile picture. `alreadyDownloaded` makes "Get New Posts" incremental.
    nonisolated static func run(handle: String, into folder: URL, alreadyDownloaded: Set<String>,
                                creds: Credentials,
                                progress: @escaping @Sendable (Progress) -> Void) async -> DownloadResult {
        var result = DownloadResult()
        progress(Progress(phase: "Loading @\(handle)…", fraction: 0, done: 0, total: 0))
        guard let profile = await fetchProfile(handle: handle, creds: creds) else {
            result.note = "Couldn’t load @\(handle). Check the handle, that you’re logged in, and that the profile is public or one you follow."
            return result
        }
        result.profile = profile

        let jobs = await collectJobs(profile: profile, creds: creds, alreadyDownloaded: alreadyDownloaded) { found in
            progress(Progress(phase: "Finding posts — \(found) item(s) so far…", fraction: 0, done: 0, total: 0))
        }
        guard !jobs.isEmpty else {
            result.profilePic = await downloadData(profile.profilePicURL)
            result.note = alreadyDownloaded.isEmpty ? "No downloadable posts found." : "No new posts."
            return result
        }

        result = await download(jobs: jobs, into: folder, creds: creds, progress: progress)
        result.profile = profile
        result.profilePic = await downloadData(profile.profilePicURL)
        return result
    }

    // MARK: - API

    nonisolated static func fetchProfile(handle: String, creds: Credentials) async -> Profile? {
        guard let url = URL(string: "https://i.instagram.com/api/v1/users/web_profile_info/?username=\(handle)") else { return nil }
        guard let (data, resp) = try? await session.data(for: apiRequest(url, handle: handle, creds: creds)),
              (resp as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) ?? false,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let user = (json["data"] as? [String: Any])?["user"] as? [String: Any] else { return nil }
        let media = user["edge_owner_to_timeline_media"] as? [String: Any]
        return Profile(userID: idString(user["id"]) ?? idString(user["pk"]) ?? "",
                       handle: user["username"] as? String ?? handle,
                       fullName: user["full_name"] as? String ?? "",
                       profilePicURL: (user["profile_pic_url_hd"] as? String) ?? (user["profile_pic_url"] as? String) ?? "",
                       postCount: media?["count"] as? Int ?? 0)
    }

    /// Walks the user feed newest-first, building a flat job list. Stops as soon as
    /// it reaches a post already downloaded (the feed is chronological), making
    /// updates cheap.
    nonisolated private static func collectJobs(profile: Profile, creds: Credentials,
                                                alreadyDownloaded: Set<String>,
                                                found: @escaping @Sendable (Int) -> Void) async -> [Job] {
        var jobs: [Job] = []
        var maxID: String?
        var pages = 0
        loop: while pages < 400 {
            pages += 1
            var s = "https://i.instagram.com/api/v1/feed/user/\(profile.userID)/?count=33"
            if let maxID { s += "&max_id=\(maxID)" }
            guard let url = URL(string: s),
                  let (data, _) = try? await session.data(for: apiRequest(url, handle: profile.handle, creds: creds)),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { break }
            let items = json["items"] as? [[String: Any]] ?? []
            for item in items {
                guard let code = item["code"] as? String else { continue }
                if alreadyDownloaded.contains(code) { break loop }       // reached known posts
                let date = Date(timeIntervalSince1970: Double(item["taken_at"] as? Int ?? 0))
                let caption = ((item["caption"] as? [String: Any])?["text"] as? String) ?? ""
                let loc = item["location"] as? [String: Any]
                let media = mediaURLs(from: item)
                for (i, m) in media.enumerated() {
                    jobs.append(Job(code: code, index: i, total: media.count, urlString: m.0, isVideo: m.1,
                                    date: date, lat: loc?["lat"] as? Double, lng: loc?["lng"] as? Double, caption: caption))
                }
            }
            found(jobs.count)
            let more = json["more_available"] as? Bool ?? false
            maxID = json["next_max_id"] as? String
            if !more || maxID == nil || items.isEmpty { break }
        }
        return jobs
    }

    // MARK: - Downloading + metadata

    nonisolated private static func download(jobs: [Job], into folder: URL, creds: Credentials,
                                             progress: @escaping @Sendable (Progress) -> Void) async -> DownloadResult {
        var result = DownloadResult()
        let total = jobs.count
        var done = 0
        await withTaskGroup(of: (ok: Bool, isVideo: Bool, path: String, caption: String).self) { group in
            var idx = 0
            let maxConcurrent = 5
            func addNext() {
                guard idx < jobs.count else { return }
                let job = jobs[idx]; idx += 1
                group.addTask { await downloadJob(job, into: folder) }
            }
            for _ in 0..<min(maxConcurrent, jobs.count) { addNext() }
            while let r = await group.next() {
                done += 1
                if r.ok {
                    if r.isVideo { result.videos += 1 } else { result.photos += 1 }
                    if !r.caption.isEmpty { result.captions[r.path] = r.caption }
                } else { result.failed += 1 }
                progress(Progress(phase: "Downloading", fraction: Double(done) / Double(total), done: done, total: total))
                addNext()
            }
        }
        result.newIDs = Array(Set(jobs.map { $0.code }))
        return result
    }

    nonisolated private static func downloadJob(_ job: Job, into folder: URL) async -> (ok: Bool, isVideo: Bool, path: String, caption: String) {
        let ext = job.isVideo ? "mp4" : "jpg"
        let name = job.total > 1 ? "\(job.code)_\(job.index + 1).\(ext)" : "\(job.code).\(ext)"
        let dest = uniqueDestination(name, in: folder)
        guard let url = URL(string: job.urlString) else { return (false, job.isVideo, "", "") }
        var req = URLRequest(url: url); req.setValue(userAgent, forHTTPHeaderField: "User-Agent"); req.timeoutInterval = 120
        guard let (tmp, resp) = try? await session.download(for: req),
              (resp as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) ?? true,
              (try? FileManager.default.moveItem(at: tmp, to: dest)) != nil else { return (false, job.isVideo, "", "") }
        // Capture date + location (+ caption into IPTC for photos). HDR video is
        // preserved: the passthrough export copies streams without re-encoding.
        if job.isVideo { await writeVideoMeta(date: job.date, lat: job.lat, lng: job.lng, to: dest) }
        else { writeImageMeta(date: job.date, lat: job.lat, lng: job.lng, caption: job.caption, to: dest) }
        try? FileManager.default.setAttributes([.creationDate: job.date, .modificationDate: job.date], ofItemAtPath: dest.path)
        return (true, job.isVideo, dest.path, job.caption)
    }

    nonisolated static func downloadData(_ urlString: String) async -> Data? {
        guard let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url); req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return (try? await session.data(for: req))?.0
    }

    /// Lossless EXIF rewrite: capture date, GPS, and the caption in IPTC.
    nonisolated private static func writeImageMeta(date: Date, lat: Double?, lng: Double?, caption: String, to url: URL) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(src) else { return }
        var props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"; f.timeZone = .current
        let stamp = f.string(from: date)
        var exif = (props[kCGImagePropertyExifDictionary] as? [CFString: Any]) ?? [:]
        exif[kCGImagePropertyExifDateTimeOriginal] = stamp
        exif[kCGImagePropertyExifDateTimeDigitized] = stamp
        props[kCGImagePropertyExifDictionary] = exif
        var tiff = (props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]) ?? [:]
        tiff[kCGImagePropertyTIFFDateTime] = stamp
        props[kCGImagePropertyTIFFDictionary] = tiff
        if let c = validCoord(lat, lng) {
            props[kCGImagePropertyGPSDictionary] = [
                kCGImagePropertyGPSLatitude: abs(c.latitude), kCGImagePropertyGPSLatitudeRef: c.latitude >= 0 ? "N" : "S",
                kCGImagePropertyGPSLongitude: abs(c.longitude), kCGImagePropertyGPSLongitudeRef: c.longitude >= 0 ? "E" : "W"
            ] as [CFString: Any]
        }
        if !caption.isEmpty {
            var iptc = (props[kCGImagePropertyIPTCDictionary] as? [CFString: Any]) ?? [:]
            iptc[kCGImagePropertyIPTCCaptionAbstract] = String(caption.prefix(1800))
            props[kCGImagePropertyIPTCDictionary] = iptc
        }
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".igtmp_" + UUID().uuidString).appendingPathExtension(url.pathExtension)
        guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, type, 1, nil) else { return }
        CGImageDestinationAddImageFromSource(dest, src, 0, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { try? FileManager.default.removeItem(at: tmp); return }
        _ = try? FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }

    /// Passthrough re-mux to set the video's creation date / location (preserves HDR).
    nonisolated private static func writeVideoMeta(date: Date, lat: Double?, lng: Double?, to url: URL) async {
        let asset = AVURLAsset(url: url)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else { return }
        var meta = (try? await asset.load(.metadata)) ?? []
        let iso = ISO8601DateFormatter().string(from: date)
        for id in [AVMetadataIdentifier.commonIdentifierCreationDate, .quickTimeMetadataCreationDate] {
            let item = AVMutableMetadataItem(); item.identifier = id; item.value = iso as NSString; meta.append(item)
        }
        if let c = validCoord(lat, lng) {
            let iso6709 = String(format: "%+09.5f%+010.5f/", c.latitude, c.longitude)
            for id in [AVMetadataIdentifier.quickTimeMetadataLocationISO6709, .commonIdentifierLocation] {
                let item = AVMutableMetadataItem(); item.identifier = id; item.value = iso6709 as NSString; meta.append(item)
            }
        }
        export.metadata = meta
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".igtmp_" + UUID().uuidString).appendingPathExtension("mp4")
        export.outputURL = tmp; export.outputFileType = .mp4
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in export.exportAsynchronously { c.resume() } }
        guard export.status == .completed else { try? FileManager.default.removeItem(at: tmp); return }
        _ = try? FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }

    // MARK: - Helpers

    nonisolated private static func apiRequest(_ url: URL, handle: String, creds: Credentials) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue(appID, forHTTPHeaderField: "X-IG-App-ID")
        req.setValue("198387", forHTTPHeaderField: "X-ASBD-ID")
        req.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        req.setValue(creds.csrf, forHTTPHeaderField: "X-CSRFToken")
        req.setValue(creds.cookie, forHTTPHeaderField: "Cookie")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("https://www.instagram.com/\(handle)/", forHTTPHeaderField: "Referer")
        req.timeoutInterval = 30
        return req
    }

    /// Best (largest) media URLs for one feed item — recurses into carousels.
    nonisolated private static func mediaURLs(from item: [String: Any]) -> [(String, Bool)] {
        let type = item["media_type"] as? Int ?? 1
        if type == 8, let carousel = item["carousel_media"] as? [[String: Any]] {
            return carousel.flatMap { mediaURLs(from: $0) }
        }
        if type == 2, let vids = item["video_versions"] as? [[String: Any]], let best = bestURL(vids) {
            return [(best, true)]
        }
        if let cands = (item["image_versions2"] as? [String: Any])?["candidates"] as? [[String: Any]],
           let best = bestURL(cands) {
            return [(best, false)]
        }
        return []
    }

    nonisolated private static func bestURL(_ arr: [[String: Any]]) -> String? {
        arr.max { a, b in
            ((a["width"] as? Int ?? 0) * (a["height"] as? Int ?? 0)) < ((b["width"] as? Int ?? 0) * (b["height"] as? Int ?? 0))
        }?["url"] as? String
    }

    nonisolated private static func validCoord(_ lat: Double?, _ lng: Double?) -> CLLocationCoordinate2D? {
        guard let lat, let lng, !(lat == 0 && lng == 0) else { return nil }
        let c = CLLocationCoordinate2D(latitude: lat, longitude: lng)
        return CLLocationCoordinate2DIsValid(c) ? c : nil
    }

    nonisolated private static func idString(_ any: Any?) -> String? {
        if let s = any as? String { return s }
        if let n = any as? NSNumber { return n.stringValue }
        if let i = any as? Int { return String(i) }
        return nil
    }

    nonisolated private static func uniqueDestination(_ name: String, in folder: URL) -> URL {
        let fm = FileManager.default
        var dest = folder.appendingPathComponent(name)
        let base = dest.deletingPathExtension().lastPathComponent, ext = dest.pathExtension
        var n = 1
        while fm.fileExists(atPath: dest.path) {
            dest = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"); n += 1
        }
        return dest
    }
}
