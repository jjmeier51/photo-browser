import Foundation
import ImageIO
import WebKit

/// Per-folder record for a downloaded OnlyFans creator (drives "Get New OnlyFans
/// Posts", the blue-ringed highlight bubble, the folder subtitle, and dedup). On
/// `Library`. Mirrors `IGFolderInfo` / `FBFolderInfo`.
struct OFFolderInfo: Codable, Sendable {
    var username: String
    var userID: String
    var name: String
    var lastUpdated: Double          // unix time of the last successful run
    var downloaded: [String]         // media ids already pulled (dedup for "Get New")
    var photos: Int
    var videos: Int
}

/// Reads the logged-in OnlyFans session from the in-app browser. Unlike Instagram /
/// Facebook, OnlyFans needs three things to talk to its private API: the session
/// cookies (`auth_id` + `sess`), and the `x-bc` device token — which OnlyFans keeps
/// in **`localStorage`** (`bcTokenSha`), not a cookie. The login web view captures
/// the `x-bc` while it's on the page and stashes it here; `credentials()` then joins
/// it with the cookies. MainActor — `WKHTTPCookieStore` is main-bound.
@MainActor
enum OnlyFansAuth {
    private static let xbcKey = "photoBrowser.onlyfansXBC"

    static func cookies() async -> [HTTPCookie] {
        await withCheckedContinuation { cont in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { all in
                cont.resume(returning: all.filter { $0.domain.contains("onlyfans.com") })
            }
        }
    }

    /// The device token OnlyFans stores in `localStorage`, captured during login.
    static var storedXBC: String { UserDefaults.standard.string(forKey: xbcKey) ?? "" }
    static func setStoredXBC(_ value: String) {
        guard !value.isEmpty else { return }
        UserDefaults.standard.set(value, forKey: xbcKey)
    }

    /// Logged in enough to hit the API: session cookies present *and* an x-bc captured.
    static func isLoggedIn() async -> Bool {
        guard !storedXBC.isEmpty else { return false }
        let cs = await cookies()
        return cs.contains { $0.name == "auth_id" && !$0.value.isEmpty }
            && cs.contains { $0.name == "sess" && !$0.value.isEmpty }
    }

    static func credentials() async -> OnlyFansService.Credentials? {
        let cs = await cookies()
        guard let authID = cs.first(where: { $0.name == "auth_id" })?.value, !authID.isEmpty,
              cs.contains(where: { $0.name == "sess" && !$0.value.isEmpty }) else { return nil }
        let xbc = storedXBC
        guard !xbc.isEmpty else { return nil }
        let header = cs.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        return OnlyFansService.Credentials(cookie: header, userID: authID, xbc: xbc)
    }
}

/// Downloads an OnlyFans creator's posts and messages (all the photos/videos the
/// signed-in user can view) using the user's own logged-in session — the same
/// approach as the reference `onlyfans-dl` scrapers. OnlyFans' private API
/// (`/api2/v2`) requires every request to be **signed**: a SHA-1 over
/// `static_param\ntime\npath\nuserId`, folded into a checksum, formatted per a small
/// set of "dynamic rules" the community publishes (they rotate, so we fetch them at
/// run time). Media in the JSON responses is pre-signed by OnlyFans, and we always
/// pick the **original / source** rendition (highest quality). Discovery (posts +
/// messages) and downloading overlap, both throttled through one shared pacer, so a
/// large creator pulls fast. Capture date + caption are written into each file.
/// Best-effort, opt-in, download-only like the Instagram/Facebook/MEGA features:
/// the protocol is unofficial, parsing is defensive, and failures surface as notes.
/// All `nonisolated`: networking + crypto + parsing + big writes stay off the main actor.
enum OnlyFansService {
    struct Credentials: Sendable { let cookie: String; let userID: String; let xbc: String }
    struct Creator: Sendable {
        let id: String
        let username: String
        let name: String
        let avatarURL: String
        let posts: Int
        let photos: Int
        let videos: Int
    }
    struct Progress: Sendable { var phase: String; var fraction: Double; var done: Int; var total: Int }
    struct DownloadResult: Sendable {
        var photos = 0, videos = 0, failed = 0
        var newIDs: [String] = []
        var captions: [String: String] = [:]   // path → caption
        var postedBy: [String: String] = [:]   // path → creator name
        var profilePic: Data?
        var creator: Creator?
        var note: String?
    }

    /// The signing recipe, fetched from the community "dynamic rules" feed.
    private struct DynamicRules: Sendable {
        let staticParam: String
        let format: String                // e.g. "60953:{}:{:x}:6a3431b5" — {} = sha1, {:x} = checksum in hex
        let checksumIndexes: [Int]
        let checksumConstant: Int
        let appToken: String
        let removeHeaders: [String]       // headers the current rules say to omit (e.g. "user-id")
    }

    /// One discovered media item: id + direct source URL + metadata, ready to download.
    private struct Item: Sendable {
        let id: String
        let isVideo: Bool
        let url: String
        let caption: String
        let date: Date?
    }

    nonisolated static let apiBase = "https://onlyfans.com/api2/v2"
    nonisolated static let referer = "https://onlyfans.com/"
    // A stable desktop UA, used both by the login web view and the API, so x-bc /
    // signing stay consistent with what OnlyFans expects.
    nonisolated static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    nonisolated static let defaultAppToken = "33d57ade8c02dbc5a333db99ff9ae26a"
    nonisolated static let pageLimit = 50

    /// Community-maintained signing rules (DATAHOARDERS is the currently-active
    /// feed; the jsdelivr CDN is a second host in case raw.githubusercontent is
    /// blocked). They rotate as OnlyFans changes its scheme, so we try each in order
    /// and use the first that parses.
    nonisolated static let dynamicRuleURLs = [
        "https://raw.githubusercontent.com/DATAHOARDERS/dynamic-rules/main/onlyfans.json",
        "https://cdn.jsdelivr.net/gh/DATAHOARDERS/dynamic-rules@main/onlyfans.json",
    ]

    nonisolated static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpShouldSetCookies = false
        cfg.httpCookieStorage = nil
        cfg.timeoutIntervalForRequest = 60
        cfg.httpMaximumConnectionsPerHost = 10
        return URLSession(configuration: cfg)
    }()

    private enum APIResult { case ok(Any); case authError; case failed }

    // MARK: - Coordination (mirrors FacebookService)

    /// Spaces API page fetches globally so parallel discovery (posts + messages)
    /// stays gentle on OnlyFans' rate limiter while overlapping request latency.
    private actor Pacer {
        private var next = ContinuousClock.now
        func waitTurn() async {
            let now = ContinuousClock.now
            let slot = max(next, now)
            next = slot + .milliseconds(120)
            if slot > now { try? await Task.sleep(until: slot, clock: .continuous) }
        }
    }
    nonisolated private static let pacer = Pacer()

    /// Cross-collector hub: dedups discovered media ids (a post and a message can
    /// carry the same media), feeds accepted items into the download stream,
    /// aggregates progress, and remembers whether a collector hit an auth wall.
    private actor Hub {
        private let already: Set<String>
        private let continuation: AsyncStream<Item>.Continuation
        private let progress: @Sendable (Progress) -> Void
        private var ids = Set<String>()
        private var finding = true
        private var saved = 0
        private(set) var foundCount = 0
        private(set) var hitLoginWall = false

        init(already: Set<String>, continuation: AsyncStream<Item>.Continuation,
             progress: @escaping @Sendable (Progress) -> Void) {
            self.already = already; self.continuation = continuation; self.progress = progress
        }
        func emit(_ item: Item) {
            guard ids.insert(item.id).inserted, !already.contains(item.id) else { return }
            foundCount += 1
            continuation.yield(item)
            if foundCount <= 5 || foundCount % 10 == 0 { report() }
        }
        func loginWalled() { hitLoginWall = true }
        func discoveryFinished() { finding = false; continuation.finish(); report() }
        func savedOne() { saved += 1; if saved % 4 == 0 || saved == foundCount { report() } }
        private func report() {
            let phase = finding ? "Found \(foundCount) — downloaded \(saved)…"
                                : "Downloading \(saved) of \(foundCount)…"
            progress(Progress(phase: phase,
                              fraction: !finding && foundCount > 0 ? Double(saved) / Double(foundCount) : 0,
                              done: saved, total: finding ? 0 : foundCount))
        }
    }

    // MARK: - Orchestration

    nonisolated static func run(username: String, into folder: URL, alreadyDownloaded: Set<String>,
                                creds: Credentials, includeMessages: Bool,
                                progress: @escaping @Sendable (Progress) -> Void) async -> DownloadResult {
        var result = DownloadResult()
        progress(Progress(phase: "Loading OnlyFans signing rules…", fraction: 0, done: 0, total: 0))
        guard let rules = await fetchDynamicRules() else {
            result.note = "Couldn’t load OnlyFans’ signing rules (the network may be blocked). Try again later."
            return result
        }
        // Probe /users/me first: it validates the login + signing and gives a precise
        // "log in again" message instead of a vague "couldn’t open the creator".
        if case .authError = await apiGet("/users/me", creds: creds, rules: rules) {
            result.note = "OnlyFans didn’t accept the login. Tap “Log in to OnlyFans”, sign in again, and retry."
            return result
        }

        progress(Progress(phase: "Loading @\(username)…", fraction: 0, done: 0, total: 0))
        guard let creator = await resolveCreator(username, creds: creds, rules: rules) else {
            result.note = "Couldn’t open @\(username). Check the username, that you’re logged in, and that you subscribe to them."
            return result
        }
        result.creator = creator
        if !creator.avatarURL.isEmpty { result.profilePic = await downloadData(creator.avatarURL, creds: creds) }

        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // Discovery and download overlap: collectors walk posts (and messages)
        // concurrently and feed the hub (which dedups) into the stream; the consumer
        // starts downloading the first item while the walks find the rest.
        let (stream, continuation) = AsyncStream.makeStream(of: Item.self)
        let hub = Hub(already: alreadyDownloaded, continuation: continuation, progress: progress)

        let discovery = Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await collectPosts(creator.id, creds: creds, rules: rules, hub: hub) }
                if includeMessages {
                    group.addTask { await collectMessages(creator.id, creds: creds, rules: rules, hub: hub) }
                }
            }
            await hub.discoveryFinished()
        }

        let creatorName = creator.name.isEmpty ? creator.username : creator.name
        await withTaskGroup(of: (ok: Bool, isVideo: Bool, id: String, path: String?, caption: String).self) { group in
            var active = 0
            let maxConcurrent = 6
            func apply(_ r: (ok: Bool, isVideo: Bool, id: String, path: String?, caption: String)) {
                if r.ok {
                    if r.isVideo { result.videos += 1 } else { result.photos += 1 }
                    result.newIDs.append(r.id)
                    if let path = r.path {
                        result.postedBy[path] = creatorName
                        if !r.caption.isEmpty { result.captions[path] = r.caption }
                    }
                } else { result.failed += 1 }
            }
            for await item in stream {
                if active >= maxConcurrent, let r = await group.next() {
                    active -= 1; apply(r); await hub.savedOne()
                }
                group.addTask { await download(item, into: folder, creds: creds) }
                active += 1
            }
            while let r = await group.next() { apply(r); await hub.savedOne() }
        }
        await discovery.value

        if await hub.foundCount == 0 {
            result.note = await hub.hitLoginWall
                ? "OnlyFans asked for a fresh login. Tap “Log in to OnlyFans”, sign in again, and retry."
                : (alreadyDownloaded.isEmpty
                    ? "No downloadable posts or messages found (are you subscribed to this creator?)."
                    : "No new posts or messages.")
        } else if result.photos + result.videos == 0 {
            result.note = "Couldn’t download any media (OnlyFans may be blocking access)."
        } else if result.failed > 0 {
            result.note = "\(result.failed) item(s) couldn’t be downloaded."
        }
        return result
    }

    // MARK: - Creator

    nonisolated private static func resolveCreator(_ username: String, creds: Credentials, rules: DynamicRules) async -> Creator? {
        let clean = sanitizeUsername(username)
        guard !clean.isEmpty else { return nil }
        guard case .ok(let json) = await apiGet("/users/\(clean)", creds: creds, rules: rules),
              let dict = json as? [String: Any], let id = idString(dict["id"]) else { return nil }
        return Creator(id: id,
                       username: (dict["username"] as? String) ?? clean,
                       name: (dict["name"] as? String) ?? "",
                       avatarURL: (dict["avatar"] as? String) ?? "",
                       posts: (dict["postsCount"] as? Int) ?? 0,
                       photos: (dict["photosCount"] as? Int) ?? 0,
                       videos: (dict["videosCount"] as? Int) ?? 0)
    }

    /// Strips a pasted URL / leading `@` down to the bare username handle.
    nonisolated static func sanitizeUsername(_ raw: String) -> String {
        var h = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = h.range(of: "onlyfans.com/") { h = String(h[r.upperBound...]) }
        h = String(h.split(separator: "/").first ?? "")
        h = String(h.split(separator: "?").first ?? "")
        return h.replacingOccurrences(of: "@", with: "")
    }

    // MARK: - Collecting media

    /// Walks the creator's timeline newest-first, paging with `beforePublishTime`
    /// until OnlyFans reports no more (or a page repeats). Every viewable media in
    /// each post is emitted; the hub dedups against already-downloaded ids.
    nonisolated private static func collectPosts(_ creatorID: String, creds: Credentials,
                                                 rules: DynamicRules, hub: Hub) async {
        var before: String?
        var seenMarkers = Set<String>()
        for _ in 0..<1000 {                              // hard cap: 1000 pages ≈ 50k posts
            var path = "/users/\(creatorID)/posts?limit=\(pageLimit)&order=publish_date_desc&skip_users=all&counters=0"
            if let b = before { path += "&beforePublishTime=\(b)" }
            let res = await apiGet(path, creds: creds, rules: rules)
            if case .authError = res { await hub.loginWalled(); return }
            guard case .ok(let json) = res else { return }
            let (list, hasMore) = normalize(json)
            if list.isEmpty { return }
            for post in list { await emitMedia(from: post, hub: hub) }
            guard let last = list.last, let marker = stringify(last["postedAtPrecise"]),
                  seenMarkers.insert(marker).inserted else { return }
            if !hasMore { return }
            before = marker
        }
    }

    /// Walks the creator's message thread newest-first, paging with the oldest
    /// message id per batch. Auth/permission failures here are non-fatal — the run
    /// still keeps whatever posts it found.
    nonisolated private static func collectMessages(_ creatorID: String, creds: Credentials,
                                                    rules: DynamicRules, hub: Hub) async {
        var lastID: String?
        for _ in 0..<1000 {
            var path = "/chats/\(creatorID)/messages?limit=\(pageLimit)&order=desc"
            if let l = lastID { path += "&id=\(l)" }
            let res = await apiGet(path, creds: creds, rules: rules)
            guard case .ok(let json) = res else { return }   // .authError/.failed: stop, don't wall the whole run
            let (list, hasMore) = normalize(json)
            if list.isEmpty { return }
            for msg in list { await emitMedia(from: msg, hub: hub) }
            guard let last = list.last, let lid = idString(last["id"]), lid != lastID else { return }
            if !hasMore { return }
            lastID = lid
        }
    }

    /// Emits every viewable photo/video/gif in a post or message. Locked previews
    /// (`canView == false`) and audio are skipped. Prefers the **source** rendition.
    nonisolated private static func emitMedia(from container: [String: Any], hub: Hub) async {
        let caption = stripHTML(container["text"] as? String ?? "")
        let date = postDate(container)
        guard let media = container["media"] as? [[String: Any]] else { return }
        for m in media {
            guard (m["canView"] as? Bool) ?? false else { continue }
            let type = (m["type"] as? String ?? "").lowercased()
            guard type == "photo" || type == "video" || type == "gif" else { continue }
            guard let mid = idString(m["id"]) else { continue }
            let isVideo = (type == "video" || type == "gif")
            guard let url = mediaURL(m, isVideo: isVideo) else { continue }
            await hub.emit(Item(id: mid, isVideo: isVideo, url: url, caption: caption, date: date))
        }
    }

    /// The best (source / original) media URL from a media object.
    nonisolated private static func mediaURL(_ m: [String: Any], isVideo: Bool) -> String? {
        // `source.source` is the original upload — the highest quality OnlyFans keeps.
        if let source = m["source"] as? [String: Any] {
            if let s = source["source"] as? String, !s.isEmpty { return s }
        }
        if let files = m["files"] as? [String: Any] {
            if let full = files["full"] as? [String: Any], let s = full["url"] as? String, !s.isEmpty { return s }
            if let src = files["source"] as? [String: Any], let s = src["url"] as? String, !s.isEmpty { return s }
        }
        if let full = m["full"] as? [String: Any], let s = full["url"] as? String, !s.isEmpty { return s }
        if let s = m["full"] as? String, !s.isEmpty { return s }
        // Progressive video renditions, best first.
        if isVideo, let vs = m["videoSources"] as? [String: Any] {
            for key in ["1080", "720", "480", "360", "240"] {
                if let s = vs[key] as? String, !s.isEmpty { return s }
            }
        }
        if let s = m["url"] as? String, !s.isEmpty { return s }
        return nil
    }

    /// `{ "list": [...], "hasMore": Bool }` or a bare array — normalize both.
    nonisolated private static func normalize(_ json: Any) -> (list: [[String: Any]], hasMore: Bool) {
        if let arr = json as? [[String: Any]] { return (arr, arr.count >= pageLimit) }
        if let dict = json as? [String: Any] {
            let list = dict["list"] as? [[String: Any]] ?? []
            let hasMore = (dict["hasMore"] as? Bool) ?? (list.count >= pageLimit)
            return (list, hasMore)
        }
        return ([], false)
    }

    /// The post/message date: `postedAtPrecise` (epoch string, most precise), then
    /// the ISO `postedAt` / `createdAt` fields.
    nonisolated private static func postDate(_ obj: [String: Any]) -> Date? {
        if let p = stringify(obj["postedAtPrecise"]), let t = Double(p) { return Date(timeIntervalSince1970: t) }
        for key in ["postedAt", "createdAt"] {
            if let s = obj[key] as? String, let d = parseISO(s) { return d }
        }
        return nil
    }

    // MARK: - Per-item download

    nonisolated private static func download(_ item: Item, into folder: URL,
                                             creds: Credentials) async -> (ok: Bool, isVideo: Bool, id: String, path: String?, caption: String) {
        let ext = item.isVideo ? "mp4" : imageExt(of: item.url)
        let dest = uniqueDestination("OF_\(item.id).\(ext)", in: folder)
        guard await downloadFile(item.url, to: dest, creds: creds) else {
            return (false, item.isVideo, item.id, nil, "")
        }
        // Photos: write the caption + capture date into the file's EXIF/IPTC so the
        // post text and date travel with it (videos get the date via file attrs).
        if !item.isVideo { writeImageMeta(date: item.date, caption: item.caption, to: dest) }
        setFileDate(dest, item.date)     // set the post date as the item's capture/file date
        return (true, item.isVideo, item.id, dest.path, item.caption)
    }

    nonisolated private static func imageExt(of urlString: String) -> String {
        let path = URLComponents(string: urlString)?.path.lowercased() ?? ""
        for ext in ["jpg", "jpeg", "png", "webp", "gif", "heic"] where path.hasSuffix("." + ext) {
            return ext == "jpeg" ? "jpg" : ext
        }
        return "jpg"
    }

    // MARK: - Metadata writing (mirrors FacebookService)

    nonisolated private static func writeImageMeta(date: Date?, caption: String, to url: URL) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(src) else { return }
        var props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
        if let date {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy:MM:dd HH:mm:ss"; f.timeZone = .current
            let s = f.string(from: date)
            var exif = (props[kCGImagePropertyExifDictionary] as? [CFString: Any]) ?? [:]
            exif[kCGImagePropertyExifDateTimeOriginal] = s; exif[kCGImagePropertyExifDateTimeDigitized] = s
            props[kCGImagePropertyExifDictionary] = exif
            var tiff = (props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]) ?? [:]
            tiff[kCGImagePropertyTIFFDateTime] = s; props[kCGImagePropertyTIFFDictionary] = tiff
        }
        if !caption.isEmpty {
            var iptc = (props[kCGImagePropertyIPTCDictionary] as? [CFString: Any]) ?? [:]
            iptc[kCGImagePropertyIPTCCaptionAbstract] = caption
            props[kCGImagePropertyIPTCDictionary] = iptc
        }
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".ofmeta_\(UUID().uuidString).\(url.pathExtension)")
        guard let dst = CGImageDestinationCreateWithURL(tmp as CFURL, type, 1, nil) else { return }
        CGImageDestinationAddImageFromSource(dst, src, 0, props as CFDictionary)
        if CGImageDestinationFinalize(dst) { _ = try? FileManager.default.replaceItemAt(url, withItemAt: tmp) }
        else { try? FileManager.default.removeItem(at: tmp) }
    }

    nonisolated private static func setFileDate(_ url: URL, _ date: Date?) {
        guard let date else { return }
        try? FileManager.default.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: url.path)
    }

    // MARK: - Request signing

    /// Fetches the dynamic signing rules from the first community mirror that parses.
    nonisolated private static func fetchDynamicRules() async -> DynamicRules? {
        for urlString in dynamicRuleURLs {
            guard let url = URL(string: urlString) else { continue }
            var req = URLRequest(url: url)
            req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            req.timeoutInterval = 30
            guard let (data, resp) = try? await session.data(for: req) else { continue }
            if let code = (resp as? HTTPURLResponse)?.statusCode, code >= 400 { continue }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let staticParam = obj["static_param"] as? String,
                  let indexes = obj["checksum_indexes"] as? [Int],
                  let constant = obj["checksum_constant"] as? Int else { continue }
            let appToken = (obj["app_token"] as? String) ?? (obj["app-token"] as? String) ?? defaultAppToken
            var format = obj["format"] as? String
            if format == nil {
                let start = (obj["prefix"] as? String) ?? (obj["start"] as? String) ?? ""
                let end = (obj["suffix"] as? String) ?? (obj["end"] as? String) ?? ""
                if !start.isEmpty || !end.isEmpty { format = "\(start):{}:{:x}:\(end)" }
            }
            guard let fmt = format else { continue }
            let removeHeaders = (obj["remove_headers"] as? [String])?.map { $0.lowercased() } ?? []
            return DynamicRules(staticParam: staticParam, format: fmt,
                                checksumIndexes: indexes, checksumConstant: constant,
                                appToken: appToken, removeHeaders: removeHeaders)
        }
        return nil
    }

    /// Builds the signed request headers for an API URL, per the current dynamic rules.
    nonisolated private static func signedHeaders(for url: URL, creds: Credentials, rules: DynamicRules) -> [String: String] {
        let time = String(Int(Date().timeIntervalSince1970))
        var path = url.path
        if let q = url.query, !q.isEmpty { path += "?" + q }
        let message = [rules.staticParam, time, path, creds.userID].joined(separator: "\n")
        let sha1 = sha1Hex(message)
        let ascii = Array(sha1.utf8)
        let checksum = rules.checksumIndexes.reduce(0) { sum, i in
            (i >= 0 && i < ascii.count) ? sum + Int(ascii[i]) : sum
        } + rules.checksumConstant
        let sign = applyFormat(rules.format, sha1: sha1, checksum: abs(checksum))
        var headers = [
            "accept": "application/json, text/plain, */*",
            "app-token": rules.appToken,
            "cookie": creds.cookie,
            "sign": sign,
            "time": time,
            "user-id": creds.userID,
            "user-agent": userAgent,
            "x-bc": creds.xbc,
        ]
        // The rules can mark headers to omit (e.g. "user-id" — still used in the
        // signed message above, just not sent). Signing/cookie headers are kept.
        for h in rules.removeHeaders where !["sign", "time", "cookie", "x-bc", "app-token"].contains(h) {
            headers.removeValue(forKey: h)
        }
        return headers
    }

    /// Substitutes the format's placeholders: the first `{}` gets the SHA-1 hex, the
    /// next gets the checksum (decimal, or hex when the placeholder is `{:x}`).
    nonisolated private static func applyFormat(_ format: String, sha1: String, checksum: Int) -> String {
        var result = ""
        var argIndex = 0
        var i = format.startIndex
        while i < format.endIndex {
            if format[i] == "{", let close = format[i...].firstIndex(of: "}") {
                let spec = format[format.index(after: i)..<close]
                if argIndex == 0 { result += sha1 }
                else { result += spec.contains(Character("x")) ? String(checksum, radix: 16) : String(checksum) }
                argIndex += 1
                i = format.index(after: close)
            } else {
                result.append(format[i]); i = format.index(after: i)
            }
        }
        return result
    }

    nonisolated private static func sha1Hex(_ s: String) -> String {
        let data = Data(s.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_SHA1($0.baseAddress, CC_LONG(data.count), &digest) }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Networking

    /// A signed GET against the OnlyFans API, retrying transient failures with a
    /// short backoff. 401/403 report as `.authError` so callers can prompt a re-login.
    nonisolated private static func apiGet(_ pathAndQuery: String, creds: Credentials, rules: DynamicRules) async -> APIResult {
        guard let url = URL(string: apiBase + pathAndQuery) else { return .failed }
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: UInt64(attempt) * 1_500_000_000) }
            await pacer.waitTurn()
            var req = URLRequest(url: url)
            for (k, v) in signedHeaders(for: url, creds: creds, rules: rules) { req.setValue(v, forHTTPHeaderField: k) }
            req.setValue(referer, forHTTPHeaderField: "Referer")
            guard let (data, resp) = try? await session.data(for: req) else { continue }
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 200
            if status == 429 || status >= 500 { continue }               // rate-limited / transient
            if status == 401 || status == 403 { return .authError }
            let obj = try? JSONSerialization.jsonObject(with: data)
            // A bad signature / expired login comes back as HTTP 400 with a JSON
            // error envelope (`{"error":{"code":0,…}}`) — detect it before treating
            // the 400 as a generic failure, so we can prompt a clean re-login.
            if let dict = obj as? [String: Any], let err = dict["error"] as? [String: Any] {
                let code = (err["code"] as? Int) ?? -1
                if code == 0 || code == 401 { return .authError }
            }
            if status >= 400 { return .failed }
            guard let obj else { return .failed }
            return .ok(obj)
        }
        return .failed
    }

    /// Streams a media file straight to disk (no in-memory buffering — source videos
    /// can be hundreds of MB), with the same transient-failure retry as the API.
    nonisolated private static func downloadFile(_ urlString: String, to dest: URL, creds: Credentials) async -> Bool {
        guard let url = URL(string: urlString) else { return false }
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000) }
            var req = URLRequest(url: url)
            req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            req.setValue(creds.cookie, forHTTPHeaderField: "Cookie")
            req.setValue(referer, forHTTPHeaderField: "Referer")
            req.timeoutInterval = 600
            guard let (tmp, resp) = try? await session.download(for: req) else { continue }
            if let code = (resp as? HTTPURLResponse)?.statusCode {
                if code == 429 || code >= 500 { continue }
                if code >= 400 { return false }
            }
            do {
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: tmp, to: dest)
                return (try? dest.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0 >= 128
            } catch { return false }
        }
        return false
    }

    /// Raw bytes (used for the small avatar image), with retry.
    nonisolated private static func downloadData(_ urlString: String, creds: Credentials) async -> Data? {
        guard let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(creds.cookie, forHTTPHeaderField: "Cookie")
        req.setValue(referer, forHTTPHeaderField: "Referer")
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000) }
            guard let (data, resp) = try? await session.data(for: req) else { continue }
            if let code = (resp as? HTTPURLResponse)?.statusCode {
                if code == 429 || code >= 500 { continue }
                if code >= 400 { return nil }
            }
            return data
        }
        return nil
    }

    // MARK: - Small helpers

    nonisolated private static func idString(_ v: Any?) -> String? {
        if let s = v as? String, !s.isEmpty { return s }
        if let n = v as? NSNumber { return n.stringValue }
        if let i = v as? Int { return String(i) }
        return nil
    }
    /// A string form of a JSON value that may be a string or a number (e.g. `postedAtPrecise`).
    nonisolated private static func stringify(_ v: Any?) -> String? {
        if let s = v as? String, !s.isEmpty { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }

    nonisolated private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    nonisolated private static let isoPlain = ISO8601DateFormatter()
    nonisolated private static func parseISO(_ s: String) -> Date? {
        isoFractional.date(from: s) ?? isoPlain.date(from: s)
    }

    /// Strips HTML tags/entities from post text down to plain caption text (capped).
    nonisolated private static func stripHTML(_ s: String) -> String {
        guard !s.isEmpty else { return "" }
        var t = s.replacingOccurrences(of: "<br />", with: "\n")
            .replacingOccurrences(of: "<br/>", with: "\n")
            .replacingOccurrences(of: "<br>", with: "\n")
            .replacingOccurrences(of: "</p>", with: "\n")
        t = t.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#039;", with: "'").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
        let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 800 ? String(trimmed.prefix(800)) : trimmed
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
