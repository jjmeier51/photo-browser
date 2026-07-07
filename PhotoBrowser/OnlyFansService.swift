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

    /// DRM (Widevine) info for an encrypted item — its DASH manifest, the CloudFront
    /// cookies to fetch it, and the OnlyFans license URL to sign. Present only when
    /// cdmpool is configured and FFmpegKit is available.
    private struct DRMInfo: Sendable {
        let mpdURL: String
        let cfCookie: String
        let licenseURL: String
    }
    /// One discovered media item: id + direct source URL + metadata, ready to download.
    private struct Item: Sendable {
        let id: String
        let isVideo: Bool
        let url: String
        let caption: String
        let date: Date?
        var drm: DRMInfo? = nil
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
        cfg.httpMaximumConnectionsPerHost = 16      // wide CDN pipe for fast parallel downloads
        return URLSession(configuration: cfg)
    }()

    private enum APIResult { case ok(Any); case authError(String); case failed(String) }

    // MARK: - Coordination (mirrors FacebookService)

    /// Spaces API page fetches globally so parallel discovery (posts + messages)
    /// stays gentle on OnlyFans' rate limiter while overlapping request latency.
    private actor Pacer {
        private var next = ContinuousClock.now
        func waitTurn() async {
            let now = ContinuousClock.now
            let slot = max(next, now)
            next = slot + .milliseconds(100)
            if slot > now { try? await Task.sleep(until: slot, clock: .continuous) }
        }
    }
    nonisolated private static let pacer = Pacer()

    /// Bounds concurrent FFmpegKit DRM decrypts to 2 — each is a full download+decode
    /// session, and the 18-wide download group would otherwise fire many at once and
    /// jetsam-kill the app.
    private actor DecryptGate {
        private var active = 0
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func acquire() async { if active < 2 { active += 1; return }; await withCheckedContinuation { waiters.append($0) } }
        func release() { if waiters.isEmpty { active -= 1 } else { waiters.removeFirst().resume() } }
    }
    nonisolated private static let decryptGate = DecryptGate()

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
        // Coverage counters (surfaced in the result note so missing media is diagnosable).
        private var postsScanned = 0, messagesScanned = 0, mediaSeen = 0
        private var skipLocked = 0, skipAudio = 0, skipDRM = 0, skipHLS = 0, skipOther = 0
        private var drmError: String?
        private(set) var drmQuotaHit = false
        func noteDRMQuota() { drmQuotaHit = true }

        init(already: Set<String>, continuation: AsyncStream<Item>.Continuation,
             progress: @escaping @Sendable (Progress) -> Void) {
            self.already = already; self.continuation = continuation; self.progress = progress
        }
        /// Counts tallied locally per post/message, folded in once — one actor hop per
        /// container instead of one per media item (that per-item hopping is what made
        /// discovery slow).
        struct Tally: Sendable { var seen = 0, locked = 0, audio = 0, drm = 0, hls = 0, other = 0 }
        func ingest(_ items: [Item], tally t: Tally) {
            mediaSeen += t.seen; skipLocked += t.locked; skipAudio += t.audio
            skipDRM += t.drm; skipHLS += t.hls; skipOther += t.other
            var yielded = false
            for item in items where ids.insert(item.id).inserted && !already.contains(item.id) {
                foundCount += 1
                continuation.yield(item)
                yielded = true
            }
            if yielded, foundCount <= 5 || foundCount % 10 == 0 { report() }
        }
        func scanned(posts: Int) { postsScanned += posts }
        func scanned(messages: Int) { messagesScanned += messages }
        func noteDRMError(_ s: String) { if drmError == nil { drmError = s } }
        var diagnostics: String {
            var s = "posts \(postsScanned), msgs \(messagesScanned); media \(mediaSeen) → new \(foundCount), skipped \(skipLocked) locked / \(skipAudio) audio / no-url: \(skipDRM) drm, \(skipHLS) hls, \(skipOther) other"
            if skipDRM > 0, OnlyFansDRM.isEnabled, !VideoTranscoder.isAvailable { s += " (DRM needs FFmpegKit)" }
            if skipDRM > 0, !OnlyFansDRM.isEnabled { s += " (set a cdmpool token in Settings for DRM)" }
            if let drmError { s += "; drm error: \(drmError)" }
            return s
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
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Verbose per-run log written into the creator's folder (onlyfans-log.txt) so
        // failures can be inspected and shared. Best-effort, never affects the download.
        let log = DownloadLog(folder: folder, kind: "onlyfans")
        await log.begin("@\(username) — messages=\(includeMessages), known=\(alreadyDownloaded.count)")
        progress(Progress(phase: "Loading OnlyFans signing rules…", fraction: 0, done: 0, total: 0))
        guard let rules = await fetchDynamicRules() else {
            result.note = "Couldn’t load OnlyFans’ signing rules (the network may be blocked). Try again later."
            await log.finish("FAILED: couldn’t load signing rules")
            return result
        }
        // Probe /users/me first: it validates the login + signing and gives a precise
        // reason (the real HTTP status + OnlyFans error) instead of a vague "couldn’t
        // open the creator", so a failed run points at what actually broke.
        switch await apiGet("/users/me", creds: creds, rules: rules) {
        case .ok: await log.log("auth OK (/users/me)")
        case .authError(let detail):
            result.note = "OnlyFans didn’t accept the login (\(detail)). Tap “Log in to OnlyFans”, sign in again, and retry."
            await log.finish("FAILED: auth rejected — \(detail)")
            return result
        case .failed(let detail):
            result.note = "Couldn’t verify the OnlyFans login (\(detail)). Try again in a moment."
            await log.finish("FAILED: couldn’t verify login — \(detail)")
            return result
        }

        progress(Progress(phase: "Loading @\(username)…", fraction: 0, done: 0, total: 0))
        guard let creator = await resolveCreator(username, creds: creds, rules: rules) else {
            result.note = "Couldn’t open @\(username). Check the username, that you’re logged in, and that you subscribe to them."
            await log.finish("FAILED: couldn’t resolve creator @\(username)")
            return result
        }
        result.creator = creator
        await log.log("creator id=\(creator.id), name=\(creator.name.isEmpty ? creator.username : creator.name)")
        if !creator.avatarURL.isEmpty { result.profilePic = await downloadData(creator.avatarURL, creds: creds) }

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
            // Downloads stream straight to disk (no in-memory buffering). 12-wide is
            // the sweet spot — fast, but not so many concurrent writes to a slow
            // external drive that a jetsam kill risks corrupting its directory.
            let maxConcurrent = 12
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
                group.addTask { await download(item, into: folder, creds: creds, rules: rules, hub: hub, log: log) }
                active += 1
            }
            while let r = await group.next() { apply(r); await hub.savedOne() }
        }
        await discovery.value

        let diag = await hub.diagnostics
        if await hub.foundCount == 0 {
            let base = await hub.hitLoginWall
                ? "OnlyFans asked for a fresh login. Tap “Log in to OnlyFans”, sign in again, and retry."
                : (alreadyDownloaded.isEmpty
                    ? "No downloadable posts or messages found (are you subscribed to this creator?)."
                    : "No new posts or messages.")
            result.note = "\(base) [\(diag)]"
        } else {
            // Always surface the coverage diagnostic so any missing media can be traced.
            var prefix = ""
            if result.photos + result.videos == 0 { prefix = "Couldn’t download any media (OnlyFans may be blocking access). " }
            else if result.failed > 0 { prefix = "\(result.failed) item(s) couldn’t be downloaded. " }
            result.note = "\(prefix)[\(diag)]"
        }
        await log.finish("photos \(result.photos), videos \(result.videos), failed \(result.failed) — \(diag)")
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
            await hub.scanned(posts: list.count)
            for post in list { await emitMedia(from: post, source: "post", hub: hub) }
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
            await hub.scanned(messages: list.count)
            for msg in list { await emitMedia(from: msg, source: "message", hub: hub) }
            guard let last = list.last, let lid = idString(last["id"]), lid != lastID else { return }
            if !hasMore { return }
            lastID = lid
        }
    }

    /// Emits every viewable image/video in a post or message. Only **explicitly**
    /// locked media (`canView == false`) and audio are skipped — an absent/odd
    /// `canView` or `type` is treated as viewable so single-rendition or untyped
    /// videos aren't silently dropped; `mediaURL` (which returns nil for anything
    /// without a real file) is the real gate.
    nonisolated private static func emitMedia(from container: [String: Any], source: String, hub: Hub) async {
        let caption = stripHTML(container["text"] as? String ?? "")
        let date = postDate(container)
        let postID = idString(container["id"]) ?? ""
        guard let media = container["media"] as? [[String: Any]] else { return }
        var items: [Item] = []
        var t = Hub.Tally()
        for m in media {
            t.seen += 1
            let type = (m["type"] as? String ?? "").lowercased()
            if type == "audio" { t.audio += 1; continue }
            if (m["canView"] as? Bool) == false { t.locked += 1; continue }   // only explicit locks
            guard let mid = idString(m["id"]) else { continue }
            // DRM (encrypted DASH): downloadable only via cdmpool + FFmpegKit.
            if let files = m["files"] as? [String: Any], let drm = files["drm"] as? [String: Any] {
                if OnlyFansDRM.isEnabled, VideoTranscoder.isAvailable,
                   let di = drmInfo(drm, mediaId: mid, source: source, postID: postID) {
                    items.append(Item(id: mid, isVideo: true, url: di.mpdURL, caption: caption, date: date, drm: di))
                } else {
                    t.drm += 1        // no cdmpool token / no FFmpegKit → can't handle it
                }
                continue
            }
            // Video when the type says so, or when it carries video-only fields.
            let isVideo = type == "video" || type == "gif"
                || (type != "photo" && (m["videoSources"] != nil || (m["source"] as? [String: Any])?["source"] != nil))
            guard let url = mediaURL(m, isVideo: isVideo) else {
                switch noURLReason(m) {                 // classify so we know what's unreachable
                case .drm: t.drm += 1
                case .hls: t.hls += 1
                case .other: t.other += 1
                }
                continue
            }
            items.append(Item(id: mid, isVideo: isVideo, url: url, caption: caption, date: date))
        }
        await hub.ingest(items, tally: t)
    }

    /// The best (source / original) media URL from a media object. Always prefers the
    /// untouched original upload so quality — **including HDR for video** — is kept:
    /// the file is streamed to disk byte-for-byte (no transcode), so whatever colour
    /// space / HDR the creator uploaded survives intact. Transcoded `videoSources`
    /// renditions (which are re-encoded and typically SDR) are a last resort only.
    nonisolated private static func mediaURL(_ m: [String: Any], isVideo: Bool) -> String? {
        // `source.source` is the original upload — the highest quality OnlyFans keeps.
        if let source = m["source"] as? [String: Any] {
            if let s = source["source"] as? String, !s.isEmpty { return s }
            if let s = source["url"] as? String, !s.isEmpty { return s }
        }
        if let s = m["source"] as? String, !s.isEmpty, s.hasPrefix("http") { return s }
        if let files = m["files"] as? [String: Any] {
            // For video the "source" file is the untouched original (keeps HDR); for a
            // photo, "full" is the full-resolution image.
            for key in (isVideo ? ["source", "full"] : ["full", "source"]) {
                if let d = files[key] as? [String: Any], let s = d["url"] as? String, !s.isEmpty { return s }
            }
        }
        if let full = m["full"] as? [String: Any], let s = full["url"] as? String, !s.isEmpty { return s }
        if let s = m["full"] as? String, !s.isEmpty { return s }
        // Transcoded progressive renditions. Take the best of *whatever* is present —
        // single-quality videos (no quality gear on the site) expose just one rendition,
        // sometimes under a non-standard key, and a fixed key list silently dropped them.
        if isVideo, let best = bestVideoSource(m["videoSources"]) { return best }
        for key in ["src", "url", "videoUrl", "video", "link"] {
            if let s = m[key] as? String, !s.isEmpty, s.hasPrefix("http") { return s }
        }
        // Deep catch-all: a direct progressive file (mp4/mov/…) hiding anywhere in the
        // object. Manifests (m3u8/mpd) are deliberately excluded — they can't be saved
        // as a playable file byte-for-byte (and are usually DRM anyway).
        if isVideo, let deep = deepFindURL(m, exts: ["mp4", "mov", "m4v", "webm"]) { return deep }
        return nil
    }

    /// Why a video had no downloadable URL — DRM (encrypted manifest only), a plain
    /// HLS/DASH stream (a manifest we don't yet mux), or something else.
    private enum NoURLReason { case drm, hls, other }
    nonisolated private static func noURLReason(_ m: [String: Any]) -> NoURLReason {
        let files = m["files"] as? [String: Any]
        if files?["drm"] != nil || m["drm"] != nil || (m["hasDrm"] as? Bool) == true { return .drm }
        if deepFindURL(m, exts: ["m3u8", "mpd"]) != nil { return .hls }
        return .other
    }

    /// Recursively finds the first http string whose path ends in one of `exts`.
    nonisolated private static func deepFindURL(_ any: Any, exts: [String]) -> String? {
        if let s = any as? String, s.hasPrefix("http") {
            let path = (URLComponents(string: s)?.path ?? "").lowercased()
            return exts.contains { path.hasSuffix("." + $0) } ? s : nil
        }
        if let dict = any as? [String: Any] {
            for (_, v) in dict { if let f = deepFindURL(v, exts: exts) { return f } }
        } else if let arr = any as? [Any] {
            for v in arr { if let f = deepFindURL(v, exts: exts) { return f } }
        }
        return nil
    }

    /// Picks the highest-resolution playable URL from a `videoSources` value, which
    /// may be a `{"720": url, …}` map (keys are resolutions, sometimes non-standard)
    /// or a `[{height/label, url}]` list. Returns nil if none carry a usable URL.
    nonisolated private static func bestVideoSource(_ any: Any?) -> String? {
        var best: (score: Int, url: String)?
        func consider(_ url: String?, _ score: Int) {
            guard let u = url, !u.isEmpty, u.hasPrefix("http") else { return }
            if best == nil || score > best!.score { best = (score, u) }
        }
        if let dict = any as? [String: Any] {
            for (k, v) in dict {
                let score = Int(k.filter(\.isNumber)) ?? 0
                // The value may be the URL string, or a nested {url/src: …} object.
                consider((v as? String) ?? (v as? [String: Any]).flatMap { ($0["url"] as? String) ?? ($0["src"] as? String) }, score)
            }
        } else if let arr = any as? [[String: Any]] {
            for e in arr {
                let score = (e["height"] as? Int) ?? Int(((e["label"] as? String) ?? "").filter(\.isNumber)) ?? 0
                consider((e["url"] as? String) ?? (e["src"] as? String), score)
            }
        }
        return best?.url
    }

    /// Builds `DRMInfo` from a media's `files.drm`: the DASH manifest, the CloudFront
    /// cookies that authorize fetching it, and the OnlyFans license URL to sign.
    nonisolated private static func drmInfo(_ drm: [String: Any], mediaId: String, source: String, postID: String) -> DRMInfo? {
        guard let manifest = drm["manifest"] as? [String: Any],
              let mpd = manifest["dash"] as? String, !mpd.isEmpty else { return nil }
        var cf = ""
        if let sig = drm["signature"] as? [String: Any], let dash = sig["dash"] as? [String: Any] {
            cf = ["CloudFront-Policy", "CloudFront-Signature", "CloudFront-Key-Pair-Id"]
                .compactMap { k in (dash[k] as? String).map { "\(k)=\($0)" } }.joined(separator: "; ")
        }
        let license = "\(apiBase)/users/media/\(mediaId)/drm/\(source)/\(postID)?type=widevine"
        return DRMInfo(mpdURL: mpd, cfCookie: cf, licenseURL: license)
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

    nonisolated private static func download(_ item: Item, into folder: URL, creds: Credentials,
                                             rules: DynamicRules, hub: Hub, log: DownloadLog? = nil) async -> (ok: Bool, isVideo: Bool, id: String, path: String?, caption: String) {
        if let drm = item.drm { return await downloadDRM(item, drm: drm, into: folder, creds: creds, rules: rules, hub: hub, log: log) }
        let ext = fileExt(of: item.url, isVideo: item.isVideo)
        let dest = uniqueDestination("OF_\(item.id).\(ext)", in: folder)
        guard await downloadFile(item.url, to: dest, creds: creds) else {
            await log?.log("• \(item.isVideo ? "video" : "photo") \(item.id): download failed. url \(String(item.url.prefix(110)))")
            return (false, item.isVideo, item.id, nil, "")
        }
        await log?.log("✓ \(item.isVideo ? "video" : "photo") \(item.id): saved OF_\(item.id).\(ext)")
        // Photos: write the caption + capture date into the file's EXIF/IPTC so the
        // post text and date travel with it. Videos are left byte-identical to the
        // source download (never re-encoded) so their HDR / colour space is preserved;
        // they only get the post date stamped via file attributes below.
        if !item.isVideo { writeImageMeta(date: item.date, caption: item.caption, to: dest) }
        setFileDate(dest, item.date)     // set the post date as the item's capture/file date
        return (true, item.isVideo, item.id, dest.path, item.caption)
    }

    /// DRM pipeline: fetch the manifest → pull the Widevine PSSH → have cdmpool run
    /// the OnlyFans license handshake (with our signed headers) for the content key →
    /// FFmpegKit downloads + decrypts the DASH to a plain MP4. Each failure stage is
    /// reported to the hub so the result note says exactly where it stopped.
    nonisolated private static func downloadDRM(_ item: Item, drm: DRMInfo, into folder: URL, creds: Credentials,
                                                rules: DynamicRules, hub: Hub, log: DownloadLog? = nil) async -> (ok: Bool, isVideo: Bool, id: String, path: String?, caption: String) {
        func fail(_ why: String) async -> (ok: Bool, isVideo: Bool, id: String, path: String?, caption: String) {
            await log?.log("• DRM video \(item.id): \(why)")
            await hub.noteDRMError(why); return (false, true, item.id, nil, "")
        }
        guard let mpd = await fetchText(drm.mpdURL, cookie: drm.cfCookie) else { return await fail("manifest fetch failed") }
        guard let pssh = OnlyFansDRM.widevinePSSH(fromMPD: mpd) else { return await fail("no PSSH in manifest") }
        // A key we already extracted (e.g. a prior run that failed at decrypt) is reused
        // — never spend a cdmpool quota unit twice on the same video.
        let key: String
        if let cached = await OnlyFansDRM.cachedKey(for: item.id) {
            key = cached
        } else {
            if await hub.drmQuotaHit { return await fail("cdmpool daily quota reached (5/day) — skipping remaining DRM") }
            guard let licURL = URL(string: drm.licenseURL) else { return await fail("bad license URL") }
            var headers = signedHeaders(for: licURL, creds: creds, rules: rules)
            let cookies = cookieDict(creds.cookie)
            headers.removeValue(forKey: "cookie")          // cdmpool takes cookies separately
            let kr = await OnlyFansDRM.extractKey(pssh: pssh, licenseURL: drm.licenseURL, headers: headers,
                                                  cookies: cookies, mpdURL: drm.mpdURL)
            if kr.quota { await hub.noteDRMQuota() }        // stop hammering a spent quota
            guard let k = kr.key else { return await fail(kr.error ?? "key extraction failed") }
            await OnlyFansDRM.cacheKey(k, for: item.id)
            key = k
        }
        // Download the encrypted media ourselves (with the CloudFront cookies) into the
        // app's temp dir, then hand FFmpeg local files — `-decryption_key` works on the
        // mov demuxer but not through the DASH demuxer, and our own download guarantees
        // the segment cookies are sent.
        let mf = OnlyFansDRM.mediaFiles(mpd, mpdURL: drm.mpdURL)
        guard !mf.video.isEmpty else { return await fail("manifest not a single-file DASH (\(mf.note))") }
        let tmpDir = FileManager.default.temporaryDirectory
        let vEnc = tmpDir.appendingPathComponent("of_v_\(item.id)_\(UUID().uuidString).mp4")
        var aEnc: URL? = tmpDir.appendingPathComponent("of_a_\(item.id)_\(UUID().uuidString).mp4")
        func cleanup() { try? FileManager.default.removeItem(at: vEnc); if let aEnc { try? FileManager.default.removeItem(at: aEnc) } }
        guard await downloadToFile(mf.video, cookie: drm.cfCookie, to: vEnc) else { cleanup(); return await fail("encrypted video download failed") }
        if let a = mf.audio, let aURL = aEnc {
            if !(await downloadToFile(a, cookie: drm.cfCookie, to: aURL)) { aEnc = nil }   // fall back to muxed audio
        } else { aEnc = nil }

        let out = tmpDir.appendingPathComponent("of_drm_\(item.id)_\(UUID().uuidString).mp4")
        await decryptGate.acquire()
        let ok = await VideoTranscoder.decryptMux(videoEnc: vEnc, audioEnc: aEnc, keyHex: key, date: item.date ?? Date(), to: out)
        await decryptGate.release()
        cleanup()
        guard ok else { try? FileManager.default.removeItem(at: out); return await fail("decrypt failed (FFmpegKit)") }
        // Move the finished MP4 onto the drive in one step (a failed/killed decrypt
        // never leaves a half-written file corrupting the external drive's directory).
        let dest = uniqueDestination("OF_\(item.id).mp4", in: folder)
        // Serialized, flushed commit so concurrent OnlyFans downloads + FFmpegKit writes
        // can't corrupt the exFAT directory (this path was the reported corruption source).
        do { try await DriveWriter.shared.commit(out, to: dest) }
        catch {
            guard (try? FileManager.default.copyItem(at: out, to: dest)) != nil else {
                try? FileManager.default.removeItem(at: out); return await fail("couldn’t save decrypted file")
            }
            try? FileManager.default.removeItem(at: out)
        }
        setFileDate(dest, item.date)
        await log?.log("✓ DRM video \(item.id): decrypted + saved OF_\(item.id).mp4")
        return (true, true, item.id, dest.path, item.caption)
    }

    /// A simple authenticated GET returning text (for the DRM manifest, fetched with
    /// the CloudFront cookies rather than the API session).
    nonisolated private static func fetchText(_ urlString: String, cookie: String) async -> String? {
        guard let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if !cookie.isEmpty { req.setValue(cookie, forHTTPHeaderField: "Cookie") }
        req.setValue(referer, forHTTPHeaderField: "Referer")
        guard let (data, resp) = try? await session.data(for: req) else { return nil }
        if let code = (resp as? HTTPURLResponse)?.statusCode, code >= 400 { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Streams a (DRM-encrypted) media file to disk using CDN cookies rather than the
    /// API session — retried, like the other downloads.
    nonisolated private static func downloadToFile(_ urlString: String, cookie: String, to dest: URL) async -> Bool {
        guard let url = URL(string: urlString) else { return false }
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000) }
            var req = URLRequest(url: url)
            req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            if !cookie.isEmpty { req.setValue(cookie, forHTTPHeaderField: "Cookie") }
            req.setValue(referer, forHTTPHeaderField: "Referer")
            req.timeoutInterval = 600
            guard let (tmp, resp) = try? await session.download(for: req) else { continue }
            if let code = (resp as? HTTPURLResponse)?.statusCode {
                if code == 429 || code >= 500 { continue }
                if code >= 400 { return false }
            }
            do { try await DriveWriter.shared.commit(tmp, to: dest); return true } catch { return false }
        }
        return false
    }

    /// Parses a `k=v; k=v` cookie header into a dict (cdmpool wants cookies as JSON).
    nonisolated private static func cookieDict(_ header: String) -> [String: String] {
        var d: [String: String] = [:]
        for pair in header.split(separator: ";") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { d[kv[0].trimmingCharacters(in: .whitespaces)] = kv[1].trimmingCharacters(in: .whitespaces) }
        }
        return d
    }

    nonisolated private static func imageExt(of urlString: String) -> String {
        let path = URLComponents(string: urlString)?.path.lowercased() ?? ""
        for ext in ["jpg", "jpeg", "png", "webp", "gif", "heic"] where path.hasSuffix("." + ext) {
            return ext == "jpeg" ? "jpg" : ext
        }
        return "jpg"
    }

    /// The file extension from the URL when it carries one (so an odd/untyped video
    /// still gets `.mp4`/`.mov` etc.), else `mp4` for video / `jpg` for a photo.
    nonisolated private static func fileExt(of urlString: String, isVideo: Bool) -> String {
        let path = URLComponents(string: urlString)?.path.lowercased() ?? ""
        for ext in ["jpg", "jpeg", "png", "webp", "gif", "heic", "mp4", "mov", "m4v", "webm", "mkv"] where path.hasSuffix("." + ext) {
            return ext == "jpeg" ? "jpg" : ext
        }
        return isVideo ? "mp4" : "jpg"
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
            // Always revalidate: OnlyFans rotates its signing scheme often, and a
            // CDN-cached (stale) rules file would sign with an outdated static_param
            // → "Please refresh the page".
            req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            req.setValue("no-cache", forHTTPHeaderField: "Pragma")
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
        // `remove_headers` can list headers to omit, but we keep everything the
        // signature depends on. Critically `user-id` is part of the signed message,
        // and OnlyFans re-signs the request server-side using the `user-id` header —
        // dropping it produces a "Please refresh the page" sign mismatch. So the
        // essentials (and user-id) are never removed; only a genuinely-extra header
        // the rules flag would be.
        let essential: Set<String> = ["sign", "time", "cookie", "x-bc", "app-token", "user-id", "user-agent", "accept"]
        for h in rules.removeHeaders where !essential.contains(h) {
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
    /// short backoff. 401/403 (and the `{"error":{"code":0}}` bad-sign envelope)
    /// report as `.authError`; both failure cases carry a short diagnostic (HTTP
    /// status + OnlyFans' own error message) so the UI can show what actually broke.
    nonisolated private static func apiGet(_ pathAndQuery: String, creds: Credentials, rules: DynamicRules) async -> APIResult {
        guard let url = URL(string: apiBase + pathAndQuery) else { return .failed("bad URL") }
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: UInt64(attempt) * 1_500_000_000) }
            await pacer.waitTurn()
            var req = URLRequest(url: url)
            for (k, v) in signedHeaders(for: url, creds: creds, rules: rules) { req.setValue(v, forHTTPHeaderField: k) }
            req.setValue(referer, forHTTPHeaderField: "Referer")
            guard let (data, resp) = try? await session.data(for: req) else { continue }
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 200
            if status == 429 || status >= 500 { continue }               // rate-limited / transient
            let obj = try? JSONSerialization.jsonObject(with: data)
            // OnlyFans' own error message (a bad signature / expired login comes back
            // as HTTP 400 with `{"error":{"code":0,"message":…}}`).
            var ofCode = Int.min
            var ofMsg = ""
            if let dict = obj as? [String: Any], let err = dict["error"] as? [String: Any] {
                ofCode = (err["code"] as? Int) ?? Int.min
                ofMsg = (err["message"] as? String) ?? ""
            }
            let detail = "HTTP \(status)" + (ofCode != Int.min ? ", error \(ofCode)" : "")
                + (ofMsg.isEmpty ? "" : ": \(ofMsg)")
            if status == 401 || status == 403 || ofCode == 0 || ofCode == 401 { return .authError(detail) }
            if status >= 400 { return .failed(detail) }
            guard let obj else { return .failed("non-JSON response (HTTP \(status))") }
            return .ok(obj)
        }
        return .failed("network error / timeout")
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
                try await DriveWriter.shared.commit(tmp, to: dest)
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
