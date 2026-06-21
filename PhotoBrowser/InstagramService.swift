import Foundation
import ImageIO
import UniformTypeIdentifiers
import CoreLocation
import AVFoundation
import WebKit

/// Per-folder record for a downloaded Instagram profile (drives "Get New posts",
/// the highlight-bubble display, the folder subtitle, and dedup). On `Library`.
struct IGFolderInfo: Codable, Sendable {
    var handle: String
    var userID: String
    var lastUpdated: Double          // unix time of the last successful run
    var downloaded: [String]         // post/story/highlight/tagged ids already pulled (dedup)
    var photos: Int
    var videos: Int
}

/// Reads the logged-in Instagram session from the in-app browser's persistent
/// cookie store. MainActor — `WKHTTPCookieStore` is main-bound.
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
    static func credentials() async -> InstagramService.Credentials? {
        let cs = await cookies()
        guard cs.contains(where: { $0.name == "sessionid" && !$0.value.isEmpty }) else { return nil }
        let header = cs.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        let csrf = cs.first { $0.name == "csrftoken" }?.value ?? ""
        return InstagramService.Credentials(cookie: header, csrf: csrf)
    }
}

/// Downloads a profile's posts, tagged media, stories and highlights via Instagram's
/// (unofficial) mobile API, using the user's own logged-in session. Best-effort and
/// download-only like the MEGA client. Video uses the highest practical quality: the
/// best DASH rendition muxed on-device (and, when FFmpegKit is present, VP9/AV1
/// renditions transcoded to HEVC with HDR preserved), else the best progressive
/// stream. Everything is `nonisolated` — networking, ImageIO/AVFoundation, big writes.
enum InstagramService {
    struct Credentials: Sendable { let cookie: String; let csrf: String }
    struct Profile: Sendable { let userID: String; let handle: String; let fullName: String; let profilePicURL: String; let postCount: Int }
    struct Progress: Sendable { var phase: String; var fraction: Double; var done: Int; var total: Int }

    private struct Job: Sendable {
        let id: String                 // dedup key (post code or story/highlight pk)
        let folder: URL                // destination folder
        let name: String               // base filename (no extension)
        let poster: String             // the posting account's handle
        let isVideo: Bool
        let url: String                // image url, or progressive/dash video url
        let audioURL: String?          // separate dash audio (mux it with the video url)
        let fallbackURL: String?       // progressive url, used if mux/transcode fails
        let transcode: Bool            // re-encode the (VP9/AV1) video to HEVC
        let quality: String            // human label of the chosen rendition (for logging)
        let date: Date; let lat: Double?; let lng: Double?; let caption: String
    }
    private struct MediaRef: Sendable { let isVideo: Bool; let url: String; let audio: String?; let fallback: String?; let transcode: Bool; let quality: String }

    struct DownloadResult: Sendable {
        var photos = 0, videos = 0, failed = 0
        var newIDs: [String] = []
        var files: [String] = []                 // dest paths of every file written this run
        var captions: [String: String] = [:]    // file path → caption
        var postedBy: [String: String] = [:]    // file path → posting handle
        var highlightFolders: [String] = []     // folder paths that hold a highlight
        var profilePic: Data?
        var profile: Profile?
        var note: String?
    }

    nonisolated static let appID = "936619743392459"
    nonisolated static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    nonisolated static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpShouldSetCookies = false
        cfg.httpCookieStorage = nil
        cfg.timeoutIntervalForRequest = 60
        cfg.httpMaximumConnectionsPerHost = 12      // ~20% more parallel connections
        return URLSession(configuration: cfg)
    }()

    // MARK: - Orchestration

    nonisolated static func run(handle: String, into folder: URL, alreadyDownloaded: Set<String>,
                                creds: Credentials, replaceExisting: Bool = false, includeTagged: Bool = true,
                                progress: @escaping @Sendable (Progress) -> Void) async -> DownloadResult {
        var result = DownloadResult()
        progress(Progress(phase: "Loading @\(handle)…", fraction: 0, done: 0, total: 0))
        guard let profile = await fetchProfile(handle: handle, creds: creds) else {
            result.note = "Couldn’t load @\(handle). Check the handle, that you’re logged in, and that the profile is public or one you follow."
            return result
        }

        print("[Instagram] start @\(handle) — FFmpegKit transcoder available: \(VideoTranscoder.isAvailable)")
        var jobs: [Job] = []
        // Posts → main folder.
        jobs += await collectFeed(base: "feed/user/\(profile.userID)/", folder: folder, already: alreadyDownloaded,
                                  poster: profile.handle, creds: creds) { n in
            progress(Progress(phase: "Finding posts — \(n) item(s)…", fraction: 0, done: 0, total: 0))
        }
        // Tagged media → main folder, but only the specific photos/videos this user is
        // actually tagged in (not whole carousels). The original poster's handle is kept.
        // Skippable (it's the slowest, least-wanted category).
        if includeTagged {
            progress(Progress(phase: "Finding tagged media…", fraction: 0, done: 0, total: 0))
            jobs += await collectFeed(base: "usertags/\(profile.userID)/feed/", folder: folder, already: alreadyDownloaded,
                                      poster: profile.handle, creds: creds,
                                      taggedUser: (id: profile.userID, username: profile.handle)) { _ in }
        }
        // Current stories (the last 24 hours) → "Stories" subfolder. Prefer the
        // reels-media tray (the endpoint that reliably returns the logged-in viewer's
        // story), falling back to the older per-user reel_media.
        progress(Progress(phase: "Finding stories…", fraction: 0, done: 0, total: 0))
        var stories = await fetchReel(path: "feed/reels_media/?reel_ids=\(profile.userID)",
                                      handle: profile.handle, creds: creds, reelKey: profile.userID)
        if stories.isEmpty {
            stories = await fetchReel(path: "feed/user/\(profile.userID)/reel_media/", handle: profile.handle, creds: creds)
        }
        let storiesFolder = folder.appendingPathComponent("Stories", isDirectory: true)
        let storyJobs = reelJobs(items: stories, folder: storiesFolder, already: alreadyDownloaded, poster: profile.handle)
        jobs += storyJobs
        // Highlights → one subfolder per highlight (shown as bubbles inside the folder). The
        // "Stories" folder is treated as a (pinned-first) highlight bubble too.
        progress(Progress(phase: "Finding highlights…", fraction: 0, done: 0, total: 0))
        var highlightDirs: [String] = []
        if !storyJobs.isEmpty { highlightDirs.append(storiesFolder.path) }
        for h in await fetchHighlights(userID: profile.userID, handle: profile.handle, creds: creds) {
            let encoded = h.id.replacingOccurrences(of: ":", with: "%3A")
            let items = await fetchReel(path: "feed/reels_media/?reel_ids=\(encoded)", handle: profile.handle, creds: creds, reelKey: h.id)
            let dir = folder.appendingPathComponent(sanitize(h.title), isDirectory: true)
            let hj = reelJobs(items: items, folder: dir, already: alreadyDownloaded, poster: profile.handle)
            if !hj.isEmpty { jobs += hj; highlightDirs.append(dir.path) }
        }

        guard !jobs.isEmpty else {
            result.profile = profile
            result.highlightFolders = highlightDirs
            result.profilePic = await fetchProfilePic(userID: profile.userID, handle: profile.handle,
                                                       creds: creds, fallback: profile.profilePicURL)
            result.note = alreadyDownloaded.isEmpty ? "No downloadable media found." : "No new posts, stories or highlights."
            return result
        }
        result = await download(jobs: jobs, replace: replaceExisting, progress: progress)
        result.profile = profile
        result.highlightFolders = highlightDirs
        result.profilePic = await fetchProfilePic(userID: profile.userID, handle: profile.handle,
                                                   creds: creds, fallback: profile.profilePicURL)
        return result
    }

    /// Downloads only the **current stories** (last 24h) for one already-known profile
    /// into its `storiesFolder`, skipping anything in `already`. Used by the homepage
    /// "Get All New Instagram Stories" sweep, which already knows each user's id/handle
    /// and doesn't want the full posts/tagged/highlights crawl that `run` performs.
    nonisolated static func runStories(handle: String, userID: String, into storiesFolder: URL,
                                       already: Set<String>, creds: Credentials,
                                       progress: @escaping @Sendable (Progress) -> Void) async -> DownloadResult {
        // Prefer the reels-media tray (reliably returns the logged-in viewer's story),
        // falling back to the older per-user reel_media — same order as `run`.
        var stories = await fetchReel(path: "feed/reels_media/?reel_ids=\(userID)",
                                      handle: handle, creds: creds, reelKey: userID)
        if stories.isEmpty {
            stories = await fetchReel(path: "feed/user/\(userID)/reel_media/", handle: handle, creds: creds)
        }
        let jobs = reelJobs(items: stories, folder: storiesFolder, already: already, poster: handle)
        guard !jobs.isEmpty else { return DownloadResult() }
        return await download(jobs: jobs, replace: false, progress: progress)
    }

    /// Copies freshly-downloaded story files into the shared "Today's Instagram Stories"
    /// folder, prefixing each name with the handle so two users' stories can't collide.
    /// The destination name is deterministic (`handle_storyfile`), so re-running in the
    /// same window **skips files that are already there** — no duplicates. The story files
    /// already carry their capture date; we copy those filesystem dates across rather than
    /// re-reading EXIF. Returns the paths actually written. Best-effort, off-main.
    @discardableResult
    nonisolated static func copyToTemp(_ files: [String], handle: String, into tempFolder: URL) async -> [String] {
        let fm = FileManager.default
        try? fm.createDirectory(at: tempFolder, withIntermediateDirectories: true)
        var written: [String] = []
        for path in files {
            let src = URL(fileURLWithPath: path)
            let dest = tempFolder.appendingPathComponent("\(handle)_\(src.lastPathComponent)")
            if fm.fileExists(atPath: dest.path) { continue }      // already copied this run/window — dedup
            guard (try? fm.copyItem(at: src, to: dest)) != nil else { continue }
            let vals = try? src.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
            if let created = vals?.creationDate, let modified = vals?.contentModificationDate {
                try? fm.setAttributes([.creationDate: created, .modificationDate: modified],
                                      ofItemAtPath: dest.path)
            }
            written.append(dest.path)
        }
        return written
    }

    /// Highest-resolution profile-picture URL for a user. The `web_profile_info` HD
    /// field is usually only ~320px; the private `users/{id}/info/` endpoint exposes the
    /// full set of sizes, so we pick the largest by pixel area. Robust to width/height
    /// arriving as Int, NSNumber or String. Falls back to the next-best source at each
    /// step, finally to whatever `web_profile_info` gave us.
    nonisolated static func bestProfilePicURL(userID: String, handle: String, creds: Credentials, fallback: String) async -> String {
        guard !userID.isEmpty,
              let url = URL(string: "https://i.instagram.com/api/v1/users/\(userID)/info/"),
              let (data, _) = try? await session.data(for: apiRequest(url, handle: handle, creds: creds)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let user = json["user"] as? [String: Any] else { return fallback }
        // Pick the largest across every size list Instagram may return.
        let lists = ["hd_profile_pic_versions", "profile_pic_versions"]
        var best: (area: Int, url: String)?
        for key in lists {
            for v in (user[key] as? [[String: Any]] ?? []) {
                guard let u = v["url"] as? String else { continue }
                let a = picArea(v)
                if best == nil || a > best!.area { best = (a, u) }
            }
        }
        if let best { return best.url }
        if let info = user["hd_profile_pic_url_info"] as? [String: Any], let u = info["url"] as? String { return u }
        return (user["hd_profile_pic_url"] as? String)
            ?? (user["profile_pic_url_hd"] as? String) ?? fallback
    }

    /// Pixel area of a size dictionary, tolerant of numeric or string width/height.
    nonisolated private static func picArea(_ d: [String: Any]) -> Int {
        func n(_ any: Any?) -> Int {
            if let i = any as? Int { return i }
            if let n = any as? NSNumber { return n.intValue }
            if let s = any as? String { return Int(s) ?? 0 }
            return 0
        }
        return n(d["width"]) * n(d["height"])
    }

    /// Downloads a user's highest-resolution profile picture (see `bestProfilePicURL`).
    nonisolated static func fetchProfilePic(userID: String, handle: String, creds: Credentials, fallback: String) async -> Data? {
        let best = await bestProfilePicURL(userID: userID, handle: handle, creds: creds, fallback: fallback)
        return await downloadData(best)
    }

    // MARK: - API

    nonisolated static func fetchProfile(handle: String, creds: Credentials) async -> Profile? {
        guard let url = URL(string: "https://i.instagram.com/api/v1/users/web_profile_info/?username=\(handle)"),
              let (data, resp) = try? await session.data(for: apiRequest(url, handle: handle, creds: creds)),
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

    /// Full media-info for one post (includes `video_dash_manifest` with the high-res
    /// renditions that the feed list omits).
    nonisolated private static func fetchMediaInfo(pk: String, handle: String, creds: Credentials) async -> [String: Any]? {
        guard let url = URL(string: "https://i.instagram.com/api/v1/media/\(pk)/info/"),
              let (data, _) = try? await session.data(for: apiRequest(url, handle: handle, creds: creds)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (json["items"] as? [[String: Any]])?.first
    }

    /// Whether a post has video but no DASH manifest yet (so it's worth a media-info fetch).
    nonisolated private static func lacksDash(_ item: [String: Any]) -> Bool {
        switch item["media_type"] as? Int ?? 1 {
        case 2: return item["video_dash_manifest"] == nil
        case 8:
            let c = item["carousel_media"] as? [[String: Any]] ?? []
            return c.contains { ($0["media_type"] as? Int) == 2 && $0["video_dash_manifest"] == nil }
        default: return false
        }
    }

    /// Paginated, newest-first feed (posts or tagged); stops at the first known item.
    nonisolated private static func collectFeed(base: String, folder: URL, already: Set<String>, poster: String,
                                                creds: Credentials, taggedUser: (id: String, username: String)? = nil,
                                                found: @escaping @Sendable (Int) -> Void) async -> [Job] {
        var jobs: [Job] = []
        var maxID: String?
        var pages = 0
        loop: while pages < 400 {
            pages += 1
            var s = "https://i.instagram.com/api/v1/\(base)?count=33"
            if let maxID { s += "&max_id=\(maxID)" }
            guard let url = URL(string: s),
                  let (data, _) = try? await session.data(for: apiRequest(url, handle: poster, creds: creds)),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { break }
            let items = json["items"] as? [[String: Any]] ?? []
            for item in items {
                guard let code = item["code"] as? String else { continue }
                if already.contains(code) { break loop }
                // The user feed omits the DASH manifest (only progressive video_versions),
                // so the high-res VP9/AV1/HDR renditions are invisible. Fetch the media-info
                // endpoint to get them — only when a transcoder is present to use them.
                var enriched = item
                if VideoTranscoder.isAvailable, lacksDash(item), let pk = idString(item["pk"]),
                   let info = await fetchMediaInfo(pk: pk, handle: poster, creds: creds) {
                    enriched = info
                }
                jobs += jobsFor(item: enriched, id: code, folder: folder, defaultPoster: poster, taggedUser: taggedUser)
            }
            found(jobs.count)
            let more = json["more_available"] as? Bool ?? false
            maxID = json["next_max_id"] as? String
            if !more || maxID == nil || items.isEmpty { break }
        }
        return jobs
    }

    nonisolated private static func fetchReel(path: String, handle: String, creds: Credentials, reelKey: String? = nil) async -> [[String: Any]] {
        guard let url = URL(string: "https://i.instagram.com/api/v1/\(path)"),
              let (data, _) = try? await session.data(for: apiRequest(url, handle: handle, creds: creds)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        if let items = json["items"] as? [[String: Any]] { return items }
        if let reel = json["reel"] as? [String: Any], let items = reel["items"] as? [[String: Any]] { return items }
        if let reels = json["reels"] as? [String: Any] {
            if let key = reelKey, let r = reels[key] as? [String: Any], let items = r["items"] as? [[String: Any]] { return items }
            if let first = reels.values.first as? [String: Any], let items = first["items"] as? [[String: Any]] { return items }
        }
        if let arr = json["reels_media"] as? [[String: Any]], let items = arr.first?["items"] as? [[String: Any]] { return items }
        return []
    }

    nonisolated private static func fetchHighlights(userID: String, handle: String, creds: Credentials) async -> [(id: String, title: String)] {
        guard let url = URL(string: "https://i.instagram.com/api/v1/highlights/\(userID)/highlights_tray/"),
              let (data, _) = try? await session.data(for: apiRequest(url, handle: handle, creds: creds)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tray = json["tray"] as? [[String: Any]] else { return [] }
        return tray.compactMap { node in
            guard let id = idString(node["id"]) else { return nil }
            let rid = id.hasPrefix("highlight:") ? id : "highlight:\(id)"
            return (rid, node["title"] as? String ?? "Highlight")
        }
    }

    nonisolated private static func reelJobs(items: [[String: Any]], folder: URL, already: Set<String>, poster: String) -> [Job] {
        var jobs: [Job] = []
        for item in items {
            let id = (item["code"] as? String) ?? idString(item["pk"]) ?? idString(item["id"])
            guard let id, !already.contains(id) else { continue }
            jobs += jobsFor(item: item, id: id, folder: folder, defaultPoster: poster)
        }
        return jobs
    }

    nonisolated private static func jobsFor(item: [String: Any], id: String, folder: URL, defaultPoster: String,
                                            taggedUser: (id: String, username: String)? = nil) -> [Job] {
        let date = Date(timeIntervalSince1970: Double(item["taken_at"] as? Int ?? 0))
        let caption = ((item["caption"] as? [String: Any])?["text"] as? String) ?? ""
        let loc = item["location"] as? [String: Any]
        let lat = loc?["lat"] as? Double, lng = loc?["lng"] as? Double
        let poster = ((item["user"] as? [String: Any])?["username"] as? String) ?? defaultPoster

        let refs: [MediaRef]
        // Tagged feed: only the carousel items this user is actually tagged in (not
        // the whole post). Single-media tagged posts are kept as-is.
        if let taggedUser, (item["media_type"] as? Int) == 8, let carousel = item["carousel_media"] as? [[String: Any]] {
            let hasTagData = carousel.contains { ($0["usertags"] as? [String: Any])?["in"] != nil }
            let chosen = hasTagData ? carousel.filter { isUserTagged($0, taggedUser) } : carousel
            refs = chosen.flatMap { media(from: $0) }
        } else {
            refs = media(from: item)
        }

        return refs.enumerated().map { (i, m) in
            Job(id: id, folder: folder, name: refs.count > 1 ? "\(id)_\(i + 1)" : id, poster: poster,
                isVideo: m.isVideo, url: m.url, audioURL: m.audio, fallbackURL: m.fallback, transcode: m.transcode,
                quality: m.quality, date: date, lat: lat, lng: lng, caption: caption)
        }
    }

    nonisolated private static func isUserTagged(_ media: [String: Any], _ user: (id: String, username: String)) -> Bool {
        guard let tags = (media["usertags"] as? [String: Any])?["in"] as? [[String: Any]] else { return false }
        return tags.contains { t in
            let u = t["user"] as? [String: Any]
            return idString(u?["pk"]) == user.id || (u?["username"] as? String) == user.username
        }
    }

    // MARK: - Downloading

    nonisolated private static func download(jobs: [Job], replace: Bool, progress: @escaping @Sendable (Progress) -> Void) async -> DownloadResult {
        var result = DownloadResult()
        let total = jobs.count
        var done = 0
        var succeeded = Set<String>(), failedIDs = Set<String>()
        await withTaskGroup(of: (ok: Bool, isVideo: Bool, path: String, caption: String, poster: String, id: String).self) { group in
            var idx = 0
            let maxConcurrent = 9        // modestly wider; Instagram is rate-limit sensitive
            func addNext() {
                guard idx < jobs.count else { return }
                let job = jobs[idx]; idx += 1
                group.addTask { await downloadJob(job, replace: replace) }
            }
            for _ in 0..<min(maxConcurrent, jobs.count) { addNext() }
            while let r = await group.next() {
                done += 1
                if r.ok {
                    if r.isVideo { result.videos += 1 } else { result.photos += 1 }
                    result.files.append(r.path)
                    if !r.caption.isEmpty { result.captions[r.path] = r.caption }
                    if !r.poster.isEmpty { result.postedBy[r.path] = r.poster }
                    succeeded.insert(r.id)
                } else { result.failed += 1; failedIDs.insert(r.id) }
                progress(Progress(phase: "Downloading", fraction: Double(done) / Double(total), done: done, total: total))
                addNext()
            }
        }
        // Mark a post downloaded only when *every* job for it succeeded, so anything
        // that failed (or a carousel that partly failed) is retried on the next
        // "Get New Posts" instead of being treated as already-done.
        result.newIDs = Array(succeeded.subtracting(failedIDs))
        return result
    }

    nonisolated private static func downloadJob(_ job: Job, replace: Bool) async -> (ok: Bool, isVideo: Bool, path: String, caption: String, poster: String, id: String) {
        try? FileManager.default.createDirectory(at: job.folder, withIntermediateDirectories: true)
        let ext = job.isVideo ? "mp4" : "jpg"
        // Re-download replaces the existing file in place; otherwise avoid collisions.
        let dest = replace ? job.folder.appendingPathComponent("\(job.name).\(ext)")
                           : uniqueDestination("\(job.name).\(ext)", in: job.folder)
        if replace { try? FileManager.default.removeItem(at: dest) }

        if job.isVideo { print("[Instagram] video \(job.name).mp4 → \(job.quality)") }

        if job.isVideo, let audio = job.audioURL,
           let v = await downloadToTemp(job.url), let a = await downloadToTemp(audio) {
            let ok = job.transcode
                ? await VideoTranscoder.muxTranscode(video: v, audio: a, to: dest, transcode: true, date: job.date, lat: job.lat, lng: job.lng)
                : await mux(video: v, audio: a, to: dest, date: job.date, lat: job.lat, lng: job.lng)
            try? FileManager.default.removeItem(at: v); try? FileManager.default.removeItem(at: a)
            if ok { setFileDate(dest, job.date); return (true, true, dest.path, job.caption, job.poster, job.id) }
            print("[Instagram]   ⚠️ \(job.transcode ? "transcode" : "mux") failed for \(job.name) — falling back to progressive")
            try? FileManager.default.removeItem(at: dest)
        }

        if job.isVideo {
            let progressive = job.fallbackURL ?? job.url
            guard await downloadFile(progressive, to: dest) else { return (false, true, "", "", "", job.id) }
            await writeVideoMeta(date: job.date, lat: job.lat, lng: job.lng, to: dest)
        } else {
            guard await downloadFile(job.url, to: dest) else { return (false, false, "", "", "", job.id) }
            writeImageMeta(date: job.date, lat: job.lat, lng: job.lng, caption: job.caption, poster: job.poster, to: dest)
        }
        setFileDate(dest, job.date)
        return (true, job.isVideo, dest.path, job.caption, job.poster, job.id)
    }

    nonisolated private static func downloadFile(_ urlString: String, to dest: URL) async -> Bool {
        guard let tmp = await downloadToTemp(urlString) else { return false }
        do { try FileManager.default.moveItem(at: tmp, to: dest); return true }
        catch { try? FileManager.default.removeItem(at: tmp); return false }
    }

    nonisolated private static func downloadToTemp(_ urlString: String) async -> URL? {
        guard let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url); req.setValue(userAgent, forHTTPHeaderField: "User-Agent"); req.timeoutInterval = 240
        guard let (tmp, resp) = try? await session.download(for: req),
              (resp as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) ?? true else { return nil }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("ig_" + UUID().uuidString)
        guard (try? FileManager.default.moveItem(at: tmp, to: out)) != nil else { return nil }
        return out
    }

    nonisolated static func downloadData(_ urlString: String) async -> Data? {
        guard let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url); req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return (try? await session.data(for: req))?.0
    }

    nonisolated private static func setFileDate(_ url: URL, _ date: Date) {
        try? FileManager.default.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: url.path)
    }

    // MARK: - Best media selection (DASH-aware, transcode-aware)

    nonisolated private static func media(from item: [String: Any]) -> [MediaRef] {
        let type = item["media_type"] as? Int ?? 1
        if type == 8, let carousel = item["carousel_media"] as? [[String: Any]] {
            return carousel.flatMap { media(from: $0) }
        }
        if type == 2 {
            let vv = item["video_versions"] as? [[String: Any]] ?? []
            let progBest = vv.max { area($0) < area($1) }
            let progURL = progBest?["url"] as? String
            let progH = progBest?["height"] as? Int ?? 0
            let dash = (item["video_dash_manifest"] as? String).map { dashStreams(decodeEntities($0)) }
            let videos = dash?.videos ?? []
            let audio = dash?.audio
            let bestCompat = videos.filter { isCompat($0.codec) }.max { $0.height < $1.height }
            // Rank by resolution, then prefer an HDR rendition at the same resolution.
            let bestAny = videos.max { rank($0) < rank($1) }
            // With a transcoder, take the highest rendition (any codec) — and grab an
            // HDR rendition even when it isn't taller than the progressive one.
            if VideoTranscoder.isAvailable, let bestAny, let audio,
               bestAny.height > max(progH, bestCompat?.height ?? 0) || (bestAny.height >= progH && isHDR(bestAny.codec)) {
                let xcode = !isCompat(bestAny.codec)
                let q = "\(bestAny.codec) \(bestAny.height)p\(isHDR(bestAny.codec) ? " HDR" : "") (DASH, \(xcode ? "transcode→HEVC" : "mux"))"
                return [MediaRef(isVideo: true, url: bestAny.url, audio: audio, fallback: progURL, transcode: xcode, quality: q)]
            }
            // Otherwise the best H.264/HEVC DASH rendition (muxed by AVFoundation)…
            if let bestCompat, let audio, bestCompat.height > progH {
                let q = "\(bestCompat.codec) \(bestCompat.height)p (DASH, mux)"
                return [MediaRef(isVideo: true, url: bestCompat.url, audio: audio, fallback: progURL, transcode: false, quality: q)]
            }
            // …or the best progressive stream.
            if let progURL {
                return [MediaRef(isVideo: true, url: progURL, audio: nil, fallback: nil, transcode: false, quality: "progressive \(progH)p")]
            }
        }
        if let cands = (item["image_versions2"] as? [String: Any])?["candidates"] as? [[String: Any]],
           let best = bestURL(cands) {
            return [MediaRef(isVideo: false, url: best, audio: nil, fallback: nil, transcode: false, quality: "image")]
        }
        return []
    }

    /// Video representations (any codec) + the best audio stream from a DASH MPD.
    nonisolated private static func dashStreams(_ mpd: String) -> (videos: [(url: String, height: Int, codec: String)], audio: String?) {
        var videos: [(url: String, height: Int, codec: String)] = []
        var audio: String?
        for rep in regex(mpd, "<Representation([^>]*)>([\\s\\S]*?)</Representation>") {
            let attrs = rep[1], body = rep[2]
            guard let base = regex(body, "<BaseURL>([\\s\\S]*?)</BaseURL>").first?[1] else { continue }
            let url = decodeEntities(base.trimmingCharacters(in: .whitespacesAndNewlines))
            let codec = attr(attrs, "codecs").lowercased()
            let h = Int(attr(attrs, "height")) ?? 0
            if codec.hasPrefix("mp4a") || (!attr(attrs, "audioSamplingRate").isEmpty && h == 0) {
                if audio == nil { audio = url }
            } else {
                videos.append((url, h, codec))
            }
        }
        return (videos, audio)
    }

    nonisolated private static func isCompat(_ codec: String) -> Bool {
        codec.hasPrefix("avc") || codec.hasPrefix("hvc") || codec.hasPrefix("hev")
    }
    /// 10-bit / HDR codec strings: VP9 profile 2, HEVC Main10, Dolby Vision.
    nonisolated private static func isHDR(_ codec: String) -> Bool {
        codec.hasPrefix("vp09.02") || codec.hasPrefix("hev1.2") || codec.hasPrefix("hvc1.2") || codec.contains("dvh")
    }
    /// (resolution, HDR) so the highest — then HDR-at-equal-resolution — wins.
    nonisolated private static func rank(_ v: (url: String, height: Int, codec: String)) -> (Int, Int) {
        (v.height, isHDR(v.codec) ? 1 : 0)
    }

    /// Passthrough-mux a separate video + audio stream into one mp4 (no re-encode,
    /// HDR preserved). Only valid for AVFoundation-supported codecs (H.264/HEVC).
    nonisolated private static func mux(video: URL, audio: URL, to dest: URL, date: Date, lat: Double?, lng: Double?) async -> Bool {
        let comp = AVMutableComposition()
        let vAsset = AVURLAsset(url: video)
        guard let vTrack = try? await vAsset.loadTracks(withMediaType: .video).first,
              let compV = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let dur = try? await vAsset.load(.duration), dur.seconds > 0 else { return false }
        try? compV.insertTimeRange(CMTimeRange(start: .zero, duration: dur), of: vTrack, at: .zero)
        if let t = try? await vTrack.load(.preferredTransform) { compV.preferredTransform = t }
        let aAsset = AVURLAsset(url: audio)
        if let aTrack = try? await aAsset.loadTracks(withMediaType: .audio).first,
           let compA = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let aDur = (try? await aAsset.load(.duration)) ?? dur
            try? compA.insertTimeRange(CMTimeRange(start: .zero, duration: CMTimeMinimum(dur, aDur)), of: aTrack, at: .zero)
        }
        guard let export = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough) else { return false }
        export.metadata = videoMetadata(date: date, lat: lat, lng: lng)
        export.outputURL = dest; export.outputFileType = .mp4
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in export.exportAsynchronously { c.resume() } }
        return export.status == .completed
    }

    // MARK: - Metadata writers (nonisolated, off-main)

    nonisolated private static func writeImageMeta(date: Date, lat: Double?, lng: Double?, caption: String, poster: String, to url: URL) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return }
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
        if !poster.isEmpty { tiff[kCGImagePropertyTIFFArtist] = "@\(poster)" }       // "Posted by"
        props[kCGImagePropertyTIFFDictionary] = tiff
        if let c = validCoord(lat, lng) {
            props[kCGImagePropertyGPSDictionary] = [
                kCGImagePropertyGPSLatitude: abs(c.latitude), kCGImagePropertyGPSLatitudeRef: c.latitude >= 0 ? "N" : "S",
                kCGImagePropertyGPSLongitude: abs(c.longitude), kCGImagePropertyGPSLongitudeRef: c.longitude >= 0 ? "E" : "W"
            ] as [CFString: Any]
        }
        var iptc = (props[kCGImagePropertyIPTCDictionary] as? [CFString: Any]) ?? [:]
        if !caption.isEmpty { iptc[kCGImagePropertyIPTCCaptionAbstract] = String(caption.prefix(1800)) }
        if !poster.isEmpty { iptc[kCGImagePropertyIPTCByline] = "@\(poster)" }
        iptc[kCGImagePropertyIPTCKeywords] = ["Instagram"]                            // "Instagram" label
        props[kCGImagePropertyIPTCDictionary] = iptc
        // Always write JPEG (the file is named .jpg): ImageIO can't *write* WebP, so
        // a WebP download (common from Instagram's CDN) must be re-encoded. JPEG
        // sources are copied losslessly (metadata-only).
        let jpegType = UTType.jpeg.identifier as CFString
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".igtmp_" + UUID().uuidString).appendingPathExtension("jpg")
        guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, jpegType, 1, nil) else { return }
        if (CGImageSourceGetType(src) as String?) == UTType.jpeg.identifier {
            CGImageDestinationAddImageFromSource(dest, src, 0, props as CFDictionary)
        } else if let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) {
            var p = props; p[kCGImageDestinationLossyCompressionQuality] = 0.95
            CGImageDestinationAddImage(dest, cg, p as CFDictionary)
        } else { try? FileManager.default.removeItem(at: tmp); return }
        guard CGImageDestinationFinalize(dest) else { try? FileManager.default.removeItem(at: tmp); return }
        _ = try? FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }

    nonisolated private static func writeVideoMeta(date: Date, lat: Double?, lng: Double?, to url: URL) async {
        let asset = AVURLAsset(url: url)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else { return }
        var meta = (try? await asset.load(.metadata)) ?? []
        meta += videoMetadata(date: date, lat: lat, lng: lng)
        export.metadata = meta
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".igtmp_" + UUID().uuidString).appendingPathExtension("mp4")
        export.outputURL = tmp; export.outputFileType = .mp4
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in export.exportAsynchronously { c.resume() } }
        guard export.status == .completed else { try? FileManager.default.removeItem(at: tmp); return }
        _ = try? FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }

    nonisolated private static func videoMetadata(date: Date, lat: Double?, lng: Double?) -> [AVMetadataItem] {
        var meta: [AVMetadataItem] = []
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
        return meta
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

    nonisolated private static func bestURL(_ arr: [[String: Any]]) -> String? {
        arr.max { area($0) < area($1) }?["url"] as? String
    }
    nonisolated private static func area(_ d: [String: Any]) -> Int { (d["width"] as? Int ?? 0) * (d["height"] as? Int ?? 0) }

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

    nonisolated private static func sanitize(_ name: String) -> String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Highlight" : String(cleaned.prefix(60))
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

    nonisolated private static func regex(_ s: String, _ pattern: String) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { m in
            (0..<m.numberOfRanges).map { i in
                let r = m.range(at: i); return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
        }
    }
    nonisolated private static func attr(_ attrs: String, _ name: String) -> String {
        regex(attrs, "\(name)=\"([^\"]*)\"").first?[1] ?? ""
    }
    nonisolated private static func decodeEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
    }
}
