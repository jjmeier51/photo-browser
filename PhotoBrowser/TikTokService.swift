import Foundation

/// Per-folder record for a downloaded TikTok profile (drives "Get New videos", the pinned
/// highlight bubble, and dedup). Stored on `Library`, keyed by the `@handle` folder path.
struct TTFolderInfo: Codable, Sendable {
    var handle: String
    var secUid: String                // TikTok author id (kept for future use)
    var lastUpdated: Double           // unix time of the last successful run
    var downloaded: [String]          // video ids already pulled (dedup)
    var videos: Int
    var newestDate: Double?           // post date of the newest video *filed onto the drive* — the incremental cutoff
}

/// Resolves a whole TikTok profile's own videos — like ssstik/snaptik, but for the entire
/// profile rather than one URL. Those tools don't scrape TikTok's web grid (which TikTok caps
/// to a screenful, virtualizes, and gates behind login); they go through a resolver API. This
/// uses the public **tikwm.com** API (no login, no request-signing): its `user/posts` endpoint
/// paginates the full video list, and — to guarantee the **highest quality** (1080p/HD,
/// watermark-free) — each video is resolved through the single-video endpoint with `hd=1`,
/// exactly like ssstik does per URL.
///
/// This type only *enumerates and resolves* download URLs (with post date + caption); the actual
/// transfers run on a background `URLSession` (see `BackgroundDownloader`) so they continue when
/// the app is closed. Download-only and best-effort: only the public handle is sent to the
/// resolver, nothing is uploaded, and because the API is unofficial and rate-limited, failures
/// are surfaced as notes rather than treated as fatal.
enum TikTokService {
    nonisolated static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
    nonisolated static let apiBase = "https://www.tikwm.com"
    /// Hosts tried (rotated) for the resolver API — tikwm answers on both, and rotating past a
    /// throttled/blocked one occasionally gets through when a single host keeps refusing.
    nonisolated private static let apiHosts = ["https://www.tikwm.com", "https://tikwm.com"]

    struct Progress: Sendable { var phase: String; var fraction: Double; var done: Int; var total: Int }
    /// A post ready to download: either a direct best-quality video `url`, or — for a
    /// photo/slideshow post — a list of `images` (both never set at once). Plus the metadata
    /// to stamp on the file(s).
    struct ResolvedVideo: Sendable { let id: String; let url: String; let images: [String]; let createTime: Date; let desc: String; let likes: Int }
    private struct Video: Sendable { let id: String; let hd: String; let sd: String; let images: [String]; let createTime: Date; let desc: String; let likes: Int }

    nonisolated static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpShouldSetCookies = false
        cfg.httpCookieStorage = nil
        cfg.timeoutIntervalForRequest = 60
        cfg.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: cfg)
    }()

    // MARK: - Enumerate + resolve (streaming)

    /// Lists every video on `@username`, then resolves each not-yet-downloaded one to its
    /// best-quality (HD) direct URL — calling `onResolved` for each the *moment* it's ready, so
    /// the caller can start its background download immediately instead of waiting for the whole
    /// profile. `onAvatar` fires once with the profile picture. Honors task cancellation, so it
    /// stops cleanly when its background-task window expires.
    nonisolated static func enumerateStreaming(
        username: String, alreadyDownloaded: Set<String>, since: Date? = nil,
        onAvatar: @escaping @Sendable (Data) -> Void,
        onResolved: @escaping @Sendable (ResolvedVideo) -> Void,
        progress: @escaping @Sendable (Progress) -> Void
    ) async -> (authorId: String, nickname: String, totalFound: Int, resolved: Int, allStats: [String: Int], newest: Double, note: String?) {
        progress(Progress(phase: since == nil ? "Finding @\(username)’s videos…" : "Checking @\(username) for new videos…",
                          fraction: 0, done: 0, total: 0))
        // Stream downloads AS THE PROFILE IS LISTED: any new video that already has its HD URL
        // (or is a photo post) is handed to the caller the instant it's seen, so its background
        // download starts during pagination instead of after the whole profile is scanned — a big
        // head start on large profiles, and more downloads handed off before any background window
        // closes. Only SD-only videos (no HD in the listing) are held back for the per-video HD
        // resolve below.
        var resolved = 0
        let listing = await listAllVideos(username: username, already: alreadyDownloaded, progress: progress) { v in
            guard !alreadyDownloaded.contains(v.id) else { return }
            if !v.images.isEmpty {
                onResolved(ResolvedVideo(id: v.id, url: "", images: v.images.map { absolute($0) },
                                         createTime: v.createTime, desc: v.desc, likes: v.likes))
                resolved += 1
            } else if !v.hd.isEmpty {
                onResolved(ResolvedVideo(id: v.id, url: absolute(v.hd), images: [], createTime: v.createTime, desc: v.desc, likes: v.likes))
                resolved += 1
            }
        }
        if !listing.avatar.isEmpty, let data = await downloadData(absolute(listing.avatar)) { onAvatar(data) }

        // Like counts for *every* listed video (id → likes) — lets the caller refresh the
        // counts on already-downloaded videos too, not just the new ones.
        var allStats: [String: Int] = [:]
        for v in listing.videos where v.likes > 0 { allStats[v.id] = v.likes }

        let pending = listing.videos.filter { !alreadyDownloaded.contains($0.id) }
        guard !pending.isEmpty else {
            // Distinguish a genuinely up-to-date profile from a resolver that failed/rate-limited:
            // the old code reported BOTH as "No new videos.", so a throttled update looked done
            // while new posts silently never arrived. `failed` (never got one good page) says so.
            let note = listing.failed
                ? "Couldn’t check for new videos — \(listing.reason ?? "the resolver may be rate-limiting or blocking"). Try again in a moment."
                : (listing.videos.isEmpty
                   ? (since != nil ? "No new videos." : "Couldn’t find any videos — TikTok or the resolver may be blocking, or the handle is wrong.")
                   : "No new videos.")
            return (listing.authorId, listing.nickname, listing.videos.count, resolved, allStats, listing.newest, note)
        }

        // The stragglers streaming skipped: new videos with no HD (and no images) in the listing —
        // resolve each via the single-video endpoint (rate-limited, so paced).
        let needResolve = pending.filter { $0.hd.isEmpty && $0.images.isEmpty }
        for (i, v) in needResolve.enumerated() {
            if Task.isCancelled { break }
            progress(Progress(phase: "Preparing HD links — \(i + 1) of \(needResolve.count)…", fraction: 0, done: 0, total: 0))
            if i > 0 { try? await Task.sleep(nanoseconds: 1_100_000_000) }   // pace before each (not after the last)
            let best = await resolveDetailHD(id: v.id, username: username) ?? v.sd
            guard !best.isEmpty else { continue }
            onResolved(ResolvedVideo(id: v.id, url: absolute(best), images: [], createTime: v.createTime, desc: v.desc, likes: v.likes))
            resolved += 1
        }
        return (listing.authorId, listing.nickname, listing.videos.count, resolved, allStats, listing.newest,
                resolved == 0 ? "Couldn’t resolve any download links (the resolver may be rate-limiting — try again)." : nil)
    }

    // MARK: - Listing (tikwm user/posts, paginated)

    /// `onDirect` is called synchronously for every video the moment it's listed, so the caller can
    /// start downloading the HD-ready ones during pagination. `failed` is true when not a single
    /// page came back valid (a resolver failure/rate-cap), so callers don't mistake it for "empty".
    nonisolated private static func listAllVideos(
        username: String, already: Set<String>, progress: @escaping @Sendable (Progress) -> Void,
        onDirect: (Video) -> Void
    ) async -> (videos: [Video], avatar: String, authorId: String, nickname: String, newest: Double, failed: Bool, reason: String?) {
        var all: [Video] = []
        var seen = Set<String>()
        var avatar = "", authorId = "", nickname = ""
        var newest: Double = 0
        var cursor = "0"
        var gotAnyPage = false        // at least one page parsed cleanly → not a blanket failure
        var failReason: String?       // why the resolver refused (surfaced when nothing came back)
        // Incremental stop is by *dedup*, not a timestamp cutoff. The old cutoff broke early on
        // accounts whose top post is a pinned/old one (and on any tikwm ordering quirk), so they
        // looked like they had "no new videos". Instead, page until we hit a long run of
        // already-downloaded posts — past the ~3 pins and well into the old timeline. A new post
        // resets the run, so nothing new is ever missed regardless of order.
        let incremental = !already.isEmpty
        var consecutiveSeen = 0
        for _ in 0..<60 {     // safety cap: 60 pages × 35 ≈ 2100 videos
            // Retried through tikwm's rate-cap (`code != 0`) and transient failures, so a throttled
            // request doesn't truncate the list — or, on page 1, masquerade as "no new videos".
            let page = await apiData("/api/user/posts",
                                     query: ["unique_id": username, "count": "35", "cursor": cursor, "hd": "1"])
            guard let d = page.data else { failReason = page.reason; break }
            gotAnyPage = true
            let vids = (d["videos"] as? [[String: Any]]) ?? []
            var stop = false
            for v in vids {
                guard let id = idString(v["video_id"]) ?? idString(v["aweme_id"]) ?? idString(v["id"]) else { continue }
                if let author = v["author"] as? [String: Any] {
                    if avatar.isEmpty { avatar = (author["avatar"] as? String) ?? "" }
                    if authorId.isEmpty { authorId = idString(author["id"]) ?? "" }
                    if nickname.isEmpty { nickname = (author["nickname"] as? String) ?? "" }
                }
                let ctSecs = Double(intValue(v["create_time"]) ?? 0)
                newest = max(newest, ctSecs)
                guard seen.insert(id).inserted else { continue }
                let hd = (v["hdplay"] as? String) ?? ""
                let sd = (v["play"] as? String) ?? (v["wmplay"] as? String) ?? ""
                // Photo/slideshow posts carry an `images` array instead of a video URL.
                let images = ((v["images"] as? [String]) ?? []).filter { !$0.isEmpty }
                guard !(hd.isEmpty && sd.isEmpty && images.isEmpty) else { continue }
                let likes = intValue(v["digg_count"]) ?? 0          // tikwm: likes (hearts)
                let video = Video(id: id, hd: hd, sd: sd, images: images, createTime: Date(timeIntervalSince1970: ctSecs),
                                  desc: (v["title"] as? String) ?? "", likes: likes)
                all.append(video)
                onDirect(video)                                     // stream: start its download now if HD-ready
                if incremental {
                    if already.contains(id) {
                        consecutiveSeen += 1
                        if consecutiveSeen >= 15 { stop = true; break }
                    } else {
                        consecutiveSeen = 0
                    }
                }
            }
            progress(Progress(phase: incremental ? "Checking — \(all.count) scanned…" : "Found \(all.count) videos…",
                              fraction: 0, done: 0, total: 0))
            if stop { break }
            let hasMore = (d["hasMore"] as? Bool) ?? (intValue(d["hasMore"]) == 1)
            let next = idString(d["cursor"]) ?? ""
            if !hasMore || next.isEmpty || next == cursor { break }
            cursor = next
            try? await Task.sleep(nanoseconds: 1_100_000_000)     // tikwm rate-limits ~1 req/sec
        }
        return (all, avatar, authorId, nickname, newest, !gotAnyPage, failReason)
    }

    /// The HD (watermark-free) URL for a single video, via the resolver's single-video endpoint.
    nonisolated private static func resolveDetailHD(id: String, username: String) async -> String? {
        let videoURL = "https://www.tiktok.com/@\(username)/video/\(id)"
        guard let d = await apiData("/api/", query: ["url": videoURL, "hd": "1"]).data else { return nil }
        let hd = (d["hdplay"] as? String) ?? ""
        return hd.isEmpty ? (d["play"] as? String) : hd
    }

    // MARK: - HTTP

    /// One resolver response: parsed JSON, a non-JSON HTTP reply (a block/challenge page), or a
    /// transport error — carried so failures can say *why* instead of a blanket "unreachable".
    private enum ApiResult { case json([String: Any]); case http(code: Int, isHTML: Bool); case network(String) }

    /// GETs a tikwm endpoint and returns its `data` object plus, on failure, a short human reason.
    /// Retries through transient failures and the free-tier rate-cap (`code != 0`), rotates hosts,
    /// and backs off — so a briefly rate-limited/blocked resolver gets several real chances, and a
    /// persistent failure reports the actual cause (HTTP status / block page / network).
    nonisolated private static func apiData(_ path: String, query: [String: String], retries: Int = 4) async -> (data: [String: Any]?, reason: String?) {
        var reason: String?
        for attempt in 0...retries {
            // Backoff grows to a ~4s cap; tikwm's free limit is roughly one request/second, and a
            // short block clears within a few seconds.
            if attempt > 0 { try? await Task.sleep(nanoseconds: UInt64(min(attempt, 4)) * 1_000_000_000) }
            let host = apiHosts[attempt % apiHosts.count]
            switch await apiGet(path, query: query, host: host) {
            case .json(let obj):
                if intValue(obj["code"]) == 0, let d = obj["data"] as? [String: Any] { return (d, nil) }
                reason = "resolver busy (\((obj["msg"] as? String) ?? "code \(intValue(obj["code"]) ?? -1)"))"
            case .http(let code, let isHTML):
                reason = isHTML ? "resolver returned a block page (HTTP \(code))" : "resolver answered HTTP \(code)"
            case .network(let why):
                reason = why
            }
        }
        return (nil, reason)
    }

    nonisolated private static func apiGet(_ path: String, query: [String: String], host: String) async -> ApiResult {
        guard var comps = URLComponents(string: host + path) else { return .network("bad URL") }
        comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = comps.url else { return .network("bad URL") }
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        // Present as a page-driven XHR from tikwm's own site — a bare, refererless request is what
        // its bot/rate protection blocks most readily, which reads to us as "resolver unreachable".
        req.setValue("\(host)/", forHTTPHeaderField: "Referer")
        req.setValue(host, forHTTPHeaderField: "Origin")
        req.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        req.timeoutInterval = 30
        do {
            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return .json(json) }
            // Not JSON — a Cloudflare/CDN block or challenge page rather than the API.
            let head = (String(data: data.prefix(300), encoding: .utf8) ?? "").lowercased()
            let isHTML = head.contains("<html") || head.contains("<!doctype") || head.contains("cloudflare") || head.contains("captcha") || head.contains("attention required")
            return .http(code: code, isHTML: isHTML)
        } catch {
            if let u = error as? URLError {
                switch u.code {
                case .timedOut: return .network("the resolver timed out")
                case .notConnectedToInternet, .networkConnectionLost: return .network("no internet connection")
                case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed: return .network("couldn’t reach the resolver")
                default: return .network("network error (\(u.code.rawValue))")
                }
            }
            return .network("network error (\((error as NSError).code))")
        }
    }

    nonisolated static func downloadData(_ urlString: String) async -> Data? {
        guard !urlString.isEmpty, let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url); req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return (try? await session.data(for: req))?.0
    }

    /// tikwm sometimes returns site-relative media paths; make them absolute.
    nonisolated static func absolute(_ u: String) -> String {
        u.hasPrefix("http") ? u : apiBase + (u.hasPrefix("/") ? u : "/" + u)
    }

    // MARK: - Helpers

    nonisolated static func sanitizeHandle(_ s: String) -> String {
        var h = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = h.range(of: "tiktok.com/@") { h = String(h[r.upperBound...]) }
        h = String(h.split(separator: "/").first ?? "")
        h = String(h.split(separator: "?").first ?? "")
        return h.replacingOccurrences(of: "@", with: "")
    }
    nonisolated private static func idString(_ any: Any?) -> String? {
        if let s = any as? String { return s.isEmpty ? nil : s }
        if let n = any as? NSNumber { return n.stringValue }
        return nil
    }
    nonisolated private static func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s) }
        return nil
    }
}
