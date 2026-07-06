import Foundation
import ImageIO
import WebKit

/// Per-folder record for a downloaded Facebook profile (drives "Get New Facebook
/// Photos", the blue-ringed highlight bubble, the subtitle, and dedup). On `Library`.
struct FBFolderInfo: Codable, Sendable {
    var profileName: String
    var profileID: String
    var profileURL: String
    var lastUpdated: Double          // unix time of the last successful run
    var downloaded: [String]         // media ids already pulled (dedup for "Get New")
    var photos: Int
    var videos: Int
}

/// Reads the logged-in Facebook session from the in-app browser's cookie store.
@MainActor
enum FacebookAuth {
    static func cookies() async -> [HTTPCookie] {
        await withCheckedContinuation { cont in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { all in
                cont.resume(returning: all.filter { $0.domain.contains("facebook.com") })
            }
        }
    }
    static func isLoggedIn() async -> Bool {
        await cookies().contains { $0.name == "c_user" && !$0.value.isEmpty }
    }
    static func credentials() async -> FacebookService.Credentials? {
        let cs = await cookies()
        guard cs.contains(where: { $0.name == "c_user" && !$0.value.isEmpty }) else { return nil }
        let header = cs.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        return FacebookService.Credentials(cookie: header)
    }
}

/// Downloads a Facebook profile's photos/videos (uploaded, profile pictures, and
/// tagged) using the user's own logged-in session, by parsing the **JSON that
/// www.facebook.com embeds in its pages** — the approach maintained scrapers use
/// since Facebook retired the old `mbasic` HTML site. Coverage is the union of the
/// profile's **real albums** (Timeline/Mobile Uploads, Profile Pictures, Cover
/// Photos, custom albums), the classic `pb` uploads set (which alone truncates
/// around 100 photos), and the tagged set — deduped by media id. Media sets are
/// walked photo by photo via each page's "next media" pointer (no GraphQL doc_ids
/// to go stale), and every photo page hands us the full-resolution URL, the exact
/// `created_time`, the caption, and the actual poster. Discovery walks run
/// concurrently (throttled through one shared pacer) and downloads start while
/// discovery is still going. Best-effort and download-only, like the
/// Instagram/MEGA features — Facebook actively fights scraping, so parsing is
/// defensive, failures are surfaced as notes, and a login wall is reported as
/// exactly that. All `nonisolated`: networking + parsing + writes.
enum FacebookService {
    struct Credentials: Sendable { let cookie: String }
    struct Profile: Sendable {
        let id: String              // numeric when resolvable (tagged set needs it)
        let vanity: String?         // username path component, when the URL has one
        let name: String
        let url: String
        let picURL: String
    }
    struct Progress: Sendable { var phase: String; var fraction: Double; var done: Int; var total: Int }
    struct DownloadResult: Sendable {
        var photos = 0, videos = 0, failed = 0
        var newIDs: [String] = []
        var captions: [String: String] = [:]   // path → caption
        var postedBy: [String: String] = [:]   // path → poster name
        var profilePic: Data?
        var profile: Profile?
        var note: String?
    }

    /// One discovered media item: id + direct full-res URL + metadata, ready to download.
    private struct Item: Sendable {
        let id: String
        let isVideo: Bool
        let url: String
        let caption: String
        let date: Date?
        let poster: String          // the item's actual owner ("" → the profile)
    }

    nonisolated static let host = "https://www.facebook.com/"
    // Desktop Safari: www serves full pages (with the embedded JSON we parse) to a
    // desktop browser; mobile UAs get shunted to the JS-only app shell.
    nonisolated static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"

    nonisolated static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpShouldSetCookies = false
        cfg.httpCookieStorage = nil
        cfg.timeoutIntervalForRequest = 60
        cfg.httpMaximumConnectionsPerHost = 16      // wider CDN pipe for faster downloads
        return URLSession(configuration: cfg)
    }()

    // MARK: - Coordination

    /// Spaces www page fetches globally — every concurrent walk draws from the one
    /// budget, so parallel discovery stays as gentle on Facebook's rate limiting as
    /// the old sequential walk while overlapping all the request latency.
    private actor Pacer {
        private var next = ContinuousClock.now
        func waitTurn() async {
            let now = ContinuousClock.now
            let slot = max(next, now)
            next = slot + .milliseconds(150)
            if slot > now { try? await Task.sleep(until: slot, clock: .continuous) }
        }
    }
    nonisolated private static let pacer = Pacer()


    /// Cross-collector hub: dedups discovered ids (albums overlap the tagged set),
    /// feeds accepted items into the download stream, aggregates progress, and
    /// remembers whether any collector hit a login wall.
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
            // Coalesced: thousands of items would otherwise mean a MainActor hop each.
            if foundCount <= 5 || foundCount % 10 == 0 { report() }
        }
        func loginWalled() { hitLoginWall = true }
        func discoveryFinished() { finding = false; continuation.finish(); report() }
        func savedOne() { saved += 1; if saved % 4 == 0 || saved == foundCount { report() } }
        private func report() {
            // While finding, the denominator is still growing — the bar stays idle
            // (total 0) and the phase text carries the live counts; once discovery
            // ends the bar fills monotonically.
            let phase = finding ? "Found \(foundCount) — downloaded \(saved)…"
                                : "Downloading \(saved) of \(foundCount)…"
            progress(Progress(phase: phase,
                              fraction: !finding && foundCount > 0 ? Double(saved) / Double(foundCount) : 0,
                              done: saved, total: finding ? 0 : foundCount))
        }
    }

    // MARK: - Orchestration

    nonisolated static func run(profileURL: String, into folder: URL, alreadyDownloaded: Set<String>,
                                creds: Credentials, upscalePhotos: Bool,
                                progress: @escaping @Sendable (Progress) -> Void) async -> DownloadResult {
        var result = DownloadResult()
        progress(Progress(phase: "Loading profile…", fraction: 0, done: 0, total: 0))
        guard let profile = await resolveProfile(profileURL, creds: creds) else {
            result.note = "Couldn’t open that profile. Check the link, that you’re logged in, and that you can view it."
            return result
        }
        result.profile = profile
        if !profile.picURL.isEmpty { result.profilePic = await downloadData(profile.picURL, creds: creds) }

        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // Discovery and download overlap: collectors walk concurrently and feed the
        // hub (which dedups across sets) into the stream; the consumer below starts
        // downloading the first photo while the walks are still finding the rest.
        let (stream, continuation) = AsyncStream.makeStream(of: Item.self)
        let hub = Hub(already: alreadyDownloaded, continuation: continuation, progress: progress)

        let discovery = Task {
            await withTaskGroup(of: Void.self) { group in
                // Albums cover profile/cover pictures and paginate past the ~100-photo
                // ceiling of the pb virtual set; the pb walk still runs alongside for
                // uploads not filed under an enumerable album — the hub dedups overlap.
                group.addTask { await collectAlbums(profile, skip: alreadyDownloaded, creds: creds, hub: hub) }
                group.addTask {
                    await collectPhotos(profile, tab: "photos_by", fallbackToken: "pb.\(profile.id).-2207520000",
                                        skip: alreadyDownloaded, creds: creds, hub: hub)
                }
                group.addTask {
                    // Tagged photos are posted by someone else — credit the page owner.
                    await collectPhotos(profile, tab: "photos_of", fallbackToken: "t.\(profile.id)",
                                        skip: alreadyDownloaded, creds: creds, hub: hub, ownerFromPage: true)
                }
                group.addTask { await collectVideos(profile, skip: alreadyDownloaded, creds: creds, hub: hub) }
            }
            await hub.discoveryFinished()
        }

        // Download consumer: a wide, purely-network group fed straight off the stream.
        // Upscaling is intentionally *not* done here — it's CPU/RAM-heavy and would
        // hold a network slot, throttling throughput — so downloads run 16-wide and
        // any 2× upscale is a separate pass afterward (see below).
        let posterFallback = profile.name
        var upscaleTargets: [(path: String, date: Date?)] = []
        await withTaskGroup(of: (ok: Bool, isVideo: Bool, id: String, path: String?, caption: String, poster: String, date: Date?).self) { group in
            var active = 0
            let maxConcurrent = 16
            func apply(_ r: (ok: Bool, isVideo: Bool, id: String, path: String?, caption: String, poster: String, date: Date?)) {
                if r.ok {
                    if r.isVideo { result.videos += 1 } else { result.photos += 1 }
                    result.newIDs.append(r.id)
                    if let path = r.path {
                        result.postedBy[path] = r.poster
                        if !r.caption.isEmpty { result.captions[path] = r.caption }
                        if !r.isVideo, upscalePhotos { upscaleTargets.append((path, r.date)) }
                    }
                } else { result.failed += 1 }
            }
            for await item in stream {
                if active >= maxConcurrent, let r = await group.next() {
                    active -= 1; apply(r); await hub.savedOne()
                }
                group.addTask {
                    await download(item, into: folder, posterFallback: posterFallback, creds: creds)
                }
                active += 1
            }
            while let r = await group.next() { apply(r); await hub.savedOne() }
        }
        await discovery.value

        // 2× AI Upscale pass: runs after the fast download stage so it never starves
        // the network. Bounded to 2 concurrent renders (each holds full-res images in
        // memory; more risks a jetsam kill), re-stamping the post date the in-place
        // swap resets.
        if upscalePhotos, !upscaleTargets.isEmpty {
            await upscalePhotos2x(upscaleTargets) { done, total in
                progress(Progress(phase: "Upscaling \(done) of \(total)…",
                                  fraction: total > 0 ? Double(done) / Double(total) : 0, done: done, total: total))
            }
        }

        if await hub.foundCount == 0 {
            result.note = await hub.hitLoginWall
                ? "Facebook asked for a fresh login. Tap “Log in to Facebook”, sign in again, and retry."
                : (alreadyDownloaded.isEmpty
                    ? "No downloadable photos or videos found (the profile may be private, empty, or Facebook may be blocking access)."
                    : "No new photos or videos.")
        } else if result.photos + result.videos == 0 {
            result.note = "Couldn’t download any media (Facebook may be blocking access)."
        } else if result.failed > 0 {
            result.note = "\(result.failed) item(s) couldn’t be downloaded."
        }
        return result
    }

    // MARK: - Profile

    /// Resolves a profile/share URL to its id, vanity name, display name, and picture,
    /// from the www page's stable markers (`fb://` deep-link metas, `og:` metas).
    nonisolated static func resolveProfile(_ profileURL: String, creds: Credentials) async -> Profile? {
        var start = profileURL.trimmingCharacters(in: .whitespaces)
        if !start.hasPrefix("http") { start = host + start.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
        for m in ["m.facebook.com", "mbasic.facebook.com", "web.facebook.com", "touch.facebook.com"] {
            start = start.replacingOccurrences(of: m, with: "www.facebook.com")
        }
        guard let (html, finalURL) = await fetchHTML(start, creds: creds), !looksLikeLogin(html, finalURL) else { return nil }

        // Numeric id: the fb:// app deep-link metas are the most stable marker; the
        // embedded-JSON owner fields cover profiles those metas are missing on.
        // ("userID" is deliberately NOT used — it's the *viewer's* id.)
        let pid = firstMatch(html, "fb://profile/(\\d+)")
            ?? firstMatch(html, "fb://page/\\?id=(\\d+)")
            ?? firstMatch(html, "\"delegate_page\":\\{\"id\":\"(\\d+)\"")
            ?? firstMatch(html, "\"owner\":\\{\"__typename\":\"(?:User|Page)\",\"id\":\"(\\d+)\"")
            ?? firstMatch(html, "\"profile_id\":\"?(\\d{6,})")
            ?? firstMatch(finalURL, "[?&]id=(\\d{6,})")
        let vanity = vanityName(from: finalURL)
        guard pid != nil || vanity != nil else { return nil }

        // Display name: og:title, an owner blob anchored to the resolved profile id,
        // the title tag, then any owner blob as a last resort (the first one on the
        // page can belong to a crossposted entity; the viewer's "user"/"userID"
        // blobs are never used). cleanName can legitimately empty a candidate (a
        // bare "Facebook" title), so fall through to the next one — an empty name
        // is what made "Posted by" render as just "@".
        let anchoredOwner = pid.flatMap {
            firstJSONString(html, "\"owner\":\\{(?:[^{}]|\\{[^{}]*\\})*?\"id\":\"\($0)\"[^{}]*?\"name\":")
        }
        let name = [meta(html, "og:title").map(decode).map(cleanName),
                    anchoredOwner,
                    firstMatch(html, "<title>([^<]+)</title>").map(decode).map(cleanName),
                    photoOwner(html)]
            .compactMap { $0 }.first { !$0.isEmpty }
            ?? vanity ?? "Facebook Profile"
        let pic = meta(html, "og:image").map(decode) ?? ""
        return Profile(id: pid ?? vanity ?? "", vanity: vanity, name: name, url: finalURL, picURL: pic)
    }

    /// `<meta property="og:…" content="…">`, either attribute order.
    nonisolated private static func meta(_ html: String, _ property: String) -> String? {
        firstMatch(html, "<meta[^>]+property=\"\(property)\"[^>]+content=\"([^\"]+)\"")
            ?? firstMatch(html, "<meta[^>]+content=\"([^\"]+)\"[^>]+property=\"\(property)\"")
    }

    nonisolated private static func vanityName(from url: String) -> String? {
        guard let comps = URLComponents(string: url), let host = comps.host, host.contains("facebook.com") else { return nil }
        let path = comps.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let first = path.split(separator: "/").first.map(String.init) ?? ""
        let reserved = ["profile.php", "photo.php", "photo", "story.php", "share", "people", "pages", "watch", "media", "login", ""]
        return reserved.contains(first) ? nil : first
    }

    nonisolated private static func cleanName(_ s: String) -> String {
        var name = s
        for junk in [" | Facebook", "| Facebook", "Facebook"] { name = name.replacingOccurrences(of: junk, with: "") }
        name = name.replacingOccurrences(of: "^\\(\\d+\\)\\s*", with: "", options: .regularExpression)   // "(3) Name" unread badge
        return name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Collecting media

    /// Enumerates the profile's real albums (Timeline/Mobile Uploads, Profile
    /// Pictures, Cover Photos, custom albums) from the albums tab and walks each
    /// one — this is what makes coverage complete, and the only route to profile
    /// pictures.
    nonisolated private static func collectAlbums(_ profile: Profile, skip: Set<String>,
                                                  creds: Credentials, hub: Hub) async {
        guard let (html, finalURL) = await fetchHTML(host + tabPath(profile, "photos_albums"), creds: creds) else { return }
        if looksLikeLogin(html, finalURL) { await hub.loginWalled(); return }
        var tokens: [String] = []; var seen = Set<String>()
        for g in matches(html, "set=a\\.(\\d+)") where seen.insert(g[1]).inserted { tokens.append("a.\(g[1])") }
        for g in matches(html, "\"__typename\":\"Album\",\"id\":\"(\\d+)\"") where seen.insert(g[1]).inserted { tokens.append("a.\(g[1])") }
        guard !tokens.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            var idx = 0
            let maxConcurrent = 3        // walks already share the global pacer
            func addNext() {
                guard idx < tokens.count else { return }
                let token = tokens[idx]; idx += 1
                // No early stop: unlike the newest-first pb/t sets, albums can be
                // user-ordered (oldest first), so a "Get New" run must walk through
                // known items to reach new ones appended at the end.
                group.addTask { await walkSet(token, firstID: nil, skip: skip, creds: creds, hub: hub, earlyStop: false) }
            }
            for _ in 0..<min(maxConcurrent, tokens.count) { addNext() }
            while await group.next() != nil { addNext() }
        }
    }

    /// A photo tab (`photos_by` = uploads, `photos_of` = tagged) names a media-set
    /// token; the set is then walked photo by photo. When the tab won't reveal a
    /// token the classic constructed token is tried — worst case the walk finds no
    /// first photo and emits nothing.
    nonisolated private static func collectPhotos(_ profile: Profile, tab: String, fallbackToken: String,
                                                  skip: Set<String>, creds: Credentials, hub: Hub,
                                                  ownerFromPage: Bool = false) async {
        var token = fallbackToken
        var firstID: String?
        if let (html, finalURL) = await fetchHTML(host + tabPath(profile, tab), creds: creds) {
            if looksLikeLogin(html, finalURL) { await hub.loginWalled(); return }
            if let t = firstMatch(html, "\"media_?set_?token\":\"([^\"]+)\"")
                ?? firstMatch(html, "set=((?:a|pb|t)\\.[0-9A-Za-z%.\\-]+)") {
                token = decode(t)
            }
            firstID = firstPhotoID(html)
        }
        await walkSet(token, firstID: firstID, skip: skip, creds: creds, hub: hub, ownerFromPage: ownerFromPage)
    }

    /// Walks a media set photo by photo: each photo page embeds the full-res image
    /// URL, caption, exact post time, the actual owner, **and the id of the next
    /// photo** — so pagination needs no volatile GraphQL doc_ids. With `earlyStop`
    /// (newest-first pb/t sets) a "Get New" run stops after a stretch of
    /// already-downloaded ids; album sets walk to the end.
    /// A page that yields neither an image nor a next pointer is retried via the
    /// alternate `photo.php` form — one flaky page used to silently end discovery
    /// for the whole set (the old ~100-photo ceiling).
    nonisolated private static func walkSet(_ token: String, firstID: String?, skip: Set<String>,
                                            creds: Credentials, hub: Hub, earlyStop: Bool = true,
                                            ownerFromPage: Bool = false, maxItems: Int = 10_000) async {
        var nextID = firstID
        if nextID == nil {
            guard let (html, finalURL) = await fetchHTML(host + "media/set/?set=\(token)", creds: creds) else { return }
            if looksLikeLogin(html, finalURL) { await hub.loginWalled(); return }
            nextID = firstPhotoID(html)
        }
        var visited = Set<String>()
        var knownStreak = 0
        while let id = nextID, visited.count < maxItems, visited.insert(id).inserted {
            if await hub.hitLoginWall { return }             // another walk hit the wall; stop hammering it
            // Keep the best page seen: a failed alternate fetch must not throw away
            // a primary page that still carried the next pointer.
            var page: (html: String, finalURL: String)?
            for form in ["photo/?fbid=\(id)&set=\(token)", "photo.php?fbid=\(id)&set=\(token)"] {
                guard let p = await fetchHTML(host + form, creds: creds) else { continue }
                page = p
                if photoPageLooksComplete(p.html) || looksLikeLogin(p.html, p.finalURL) { break }
            }
            guard let (html, finalURL) = page else { break }
            if looksLikeLogin(html, finalURL) { await hub.loginWalled(); return }
            if skip.contains(id) {
                knownStreak += 1
                if earlyStop, knownStreak >= 30 { break }    // deep into already-downloaded territory
            } else {
                knownStreak = 0
                // Only tagged sets credit the page's owner blob — on a profile's own
                // uploads the first "owner" can be a crossposted entity.
                let poster = ownerFromPage ? photoOwner(html) : ""
                if let url = imageURL(html) {
                    await hub.emit(Item(id: id, isVideo: false, url: url, caption: photoCaption(html),
                                        date: createdTime(html), poster: poster))
                } else if let url = videoURL(html) {
                    // A video sitting in the set (common among tagged media) — grab it
                    // too, so tagged coverage isn't photos-only.
                    await hub.emit(Item(id: id, isVideo: true, url: url, caption: photoCaption(html),
                                        date: createdTime(html), poster: poster))
                }
            }
            nextID = nextPhotoID(html)
        }
    }

    /// The videos tab lists permalinks; each watch page embeds direct HD/SD URLs.
    /// Watch pages resolve a few at a time through the shared pacer.
    nonisolated private static func collectVideos(_ profile: Profile, skip: Set<String>,
                                                  creds: Credentials, hub: Hub) async {
        guard let (html, finalURL) = await fetchHTML(host + tabPath(profile, "videos"), creds: creds) else { return }
        if looksLikeLogin(html, finalURL) { await hub.loginWalled(); return }
        var ids: [String] = []; var seen = Set<String>()
        for g in matches(html, "videos\\\\?/(\\d{8,})") where seen.insert(g[1]).inserted { ids.append(g[1]) }
        for g in matches(html, "\"video_?id\":\"(\\d{8,})\"") where seen.insert(g[1]).inserted { ids.append(g[1]) }
        for g in matches(html, "watch/\\?v=(\\d{8,})") where seen.insert(g[1]).inserted { ids.append(g[1]) }
        let targets = ids.filter { !skip.contains($0) }
        guard !targets.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            var idx = 0
            let maxConcurrent = 3
            func addNext() {
                guard idx < targets.count else { return }
                let id = targets[idx]; idx += 1
                group.addTask {
                    if await hub.hitLoginWall { return }     // stop hammering a known wall
                    guard let (page, pageURL) = await fetchHTML(host + "watch/?v=\(id)", creds: creds) else { return }
                    if looksLikeLogin(page, pageURL) { await hub.loginWalled(); return }
                    guard let url = videoURL(page) else { return }
                    await hub.emit(Item(id: id, isVideo: true, url: url, caption: photoCaption(page),
                                        date: createdTime(page), poster: ""))
                }
            }
            for _ in 0..<min(maxConcurrent, targets.count) { addNext() }
            while await group.next() != nil { addNext() }
        }
    }

    nonisolated private static func tabPath(_ profile: Profile, _ tab: String) -> String {
        if let v = profile.vanity { return "\(v)/\(tab)" }
        return "profile.php?id=\(profile.id)&sk=\(tab)"
    }

    // MARK: - Page parsing

    /// The first media id in a set page. Accepts **Photo or Video** nodes: tagged
    /// sets interleave both, and anchoring on Photo alone made a set that opened on
    /// a video start empty.
    nonisolated private static func firstPhotoID(_ html: String) -> String? {
        firstMatch(html, "\\{\"__typename\":\"(?:Photo|Video)\",\"id\":\"(\\d+)\"")
            ?? firstMatch(html, "\"__isMedia\":\"(?:Photo|Video)\"[^{}]*?\"id\":\"(\\d+)\"")
            ?? firstMatch(html, "fbid=(\\d{6,})")
    }

    /// The **next media id** in the set (the pagination pointer each page carries).
    /// Must accept **Video** nodes as well as photos — otherwise the walk dead-ends
    /// at the first tagged video and silently drops every item after it, which was
    /// why tagged coverage kept truncating. Falls back to a typename-agnostic match
    /// so an unexpected node type still advances the chain.
    nonisolated private static func nextPhotoID(_ html: String) -> String? {
        firstMatch(html, "\"nextMediaAfterNodeId\":\\{\"__typename\":\"(?:Photo|Video)\",\"id\":\"(\\d+)\"")
            ?? firstMatch(html, "\"nextMedia\":\\{\"edges\":\\[\\{\"node\":\\{\"__typename\":\"(?:Photo|Video)\",\"id\":\"(\\d+)\"")
            ?? firstMatch(html, "\"nextMediaAfterNodeId\":\\{[^{}]*?\"id\":\"(\\d+)\"")
    }

    /// The full-res image URL from a photo page (`"image":{…"uri":"…"}` — the uri
    /// need not be the object's first key).
    nonisolated private static func imageURL(_ html: String) -> String? {
        firstJSONString(html, "\"image\":\\{[^{}]*?\"uri\":")
    }

    /// A direct video URL embedded in a media/watch page (best rendition first).
    /// Shared by the videos tab and the set walk (a tagged item can be a video).
    nonisolated private static func videoURL(_ html: String) -> String? {
        firstJSONString(html, "\"browser_native_hd_url\":")
            ?? firstJSONString(html, "\"playable_url_quality_hd\":")
            ?? firstJSONString(html, "\"browser_native_sd_url\":")
            ?? firstJSONString(html, "\"playable_url\":")
    }

    /// A media page that carries no image, no video, and no next pointer is a
    /// rate-limit / error shell worth refetching, not the end of the set.
    nonisolated private static func photoPageLooksComplete(_ html: String) -> Bool {
        nextPhotoID(html) != nil || imageURL(html) != nil || videoURL(html) != nil
    }

    /// The item's actual owner — for tagged photos that's the *poster*, not the
    /// profile being downloaded. Tolerates one level of nested object (e.g. a
    /// profile_picture blob) before the name field.
    nonisolated private static func photoOwner(_ html: String) -> String {
        firstJSONString(html, "\"owner\":\\{(?:[^{}]|\\{[^{}]*\\})*?\"name\":")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// The post text: the first `"message":{…"text":"…"}` blob (the post's own
    /// message comes before comments in the payload).
    nonisolated private static func photoCaption(_ html: String) -> String {
        guard let raw = firstMatch(html, "\"message\":\\{[^{}]*?\"text\":\"((?:[^\"\\\\]|\\\\.)*)\"") else { return "" }
        let text = unescapeJSON(raw)
        return text.count > 800 ? String(text.prefix(800)) : text
    }

    nonisolated private static func createdTime(_ html: String) -> Date? {
        guard let s = firstMatch(html, "\"(?:created_time|creation_time|publish_time)\":(\\d{9,11})"),
              let t = TimeInterval(s) else { return nil }
        return Date(timeIntervalSince1970: t)
    }

    /// Extracts the JSON string value following `prefixPattern` (e.g. `"image":{"uri":`)
    /// and fully unescapes it (`\/`, `\uXXXX`, …).
    nonisolated private static func firstJSONString(_ html: String, _ prefixPattern: String) -> String? {
        firstMatch(html, prefixPattern + "\"((?:[^\"\\\\]|\\\\.)+)\"").map(unescapeJSON)
    }

    // MARK: - Per-item download

    /// Downloads one item and writes its metadata. Pure network + file I/O — no
    /// upscaling (that's a separate pass), so the download group stays wide and fast.
    nonisolated private static func download(_ item: Item, into folder: URL, posterFallback: String,
                                             creds: Credentials) async -> (ok: Bool, isVideo: Bool, id: String, path: String?, caption: String, poster: String, date: Date?) {
        let poster = item.poster.isEmpty ? posterFallback : item.poster
        guard let data = await downloadData(item.url, creds: creds), data.count >= 512 else {
            return (false, item.isVideo, item.id, nil, "", poster, nil)
        }
        let ext = item.isVideo ? "mp4" : imageExt(of: item.url)
        let dest = uniqueDestination("FB_\(item.id).\(ext)", in: folder)
        guard (try? data.write(to: dest, options: .atomic)) != nil else { return (false, item.isVideo, item.id, nil, "", poster, nil) }
        if !item.isVideo { writeImageMeta(date: item.date, caption: item.caption, poster: poster, to: dest) }
        setFileDate(dest, item.date)
        return (true, item.isVideo, item.id, dest.path, item.caption, poster, item.date)
    }

    /// 2× AI Upscale (Lanczos ×2 + denoise + sharpen) of the downloaded photos, in
    /// place, metadata carried through. Bounded to 2 concurrent renders and run as
    /// its own pass so it never competes with the network stage. Formats
    /// `CGImageDestination` can't round-trip (webp/gif — the latter would flatten an
    /// animation) are skipped; the post date is re-stamped after each in-place swap.
    nonisolated private static func upscalePhotos2x(_ targets: [(path: String, date: Date?)],
                                                    progress: @escaping @Sendable (Int, Int) -> Void) async {
        let ups = targets.filter { ["jpg", "png", "heic"].contains(URL(fileURLWithPath: $0.path).pathExtension.lowercased()) }
        let total = ups.count
        guard total > 0 else { return }
        await withTaskGroup(of: Void.self) { group in
            var idx = 0
            let maxConcurrent = 2
            func addNext() {
                guard idx < ups.count else { return }
                let t = ups[idx]; idx += 1
                group.addTask {
                    let url = URL(fileURLWithPath: t.path)
                    _ = MediaEditing.enhancePhotoInPlace(url: url, scale: 2)
                    setFileDate(url, t.date)   // the in-place swap resets file dates
                }
            }
            for _ in 0..<min(maxConcurrent, ups.count) { addNext() }
            var done = 0
            while await group.next() != nil { done += 1; progress(done, total); addNext() }
        }
    }

    nonisolated private static func imageExt(of urlString: String) -> String {
        let path = URLComponents(string: urlString)?.path.lowercased() ?? ""
        for ext in ["jpg", "jpeg", "png", "webp", "gif", "heic"] where path.hasSuffix("." + ext) { return ext == "jpeg" ? "jpg" : ext }
        return "jpg"
    }

    // MARK: - Metadata writing

    nonisolated private static func writeImageMeta(date: Date?, caption: String, poster: String, to url: URL) {
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
        // Poster name + caption into IPTC (so "who posted it" and the caption travel
        // with the file).
        var iptc = (props[kCGImagePropertyIPTCDictionary] as? [CFString: Any]) ?? [:]
        if !caption.isEmpty { iptc[kCGImagePropertyIPTCCaptionAbstract] = caption }
        if !poster.isEmpty { iptc[kCGImagePropertyIPTCByline] = poster }
        props[kCGImagePropertyIPTCDictionary] = iptc
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".fbmeta_\(UUID().uuidString).\(url.pathExtension)")
        guard let dst = CGImageDestinationCreateWithURL(tmp as CFURL, type, 1, nil) else { return }
        CGImageDestinationAddImageFromSource(dst, src, 0, props as CFDictionary)
        if CGImageDestinationFinalize(dst) { _ = try? FileManager.default.replaceItemAt(url, withItemAt: tmp) }
        else { try? FileManager.default.removeItem(at: tmp) }
    }

    nonisolated private static func setFileDate(_ url: URL, _ date: Date?) {
        guard let date else { return }
        try? FileManager.default.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: url.path)
    }

    // MARK: - Networking

    nonisolated private static func request(_ url: URL, creds: Credentials, html: Bool) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(creds.cookie, forHTTPHeaderField: "Cookie")
        req.setValue(html ? "text/html,application/xhtml+xml" : "*/*", forHTTPHeaderField: "Accept")
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        return req
    }

    /// Fetches a page through the shared pacer, retrying transient failures
    /// (network errors, 429/5xx) with a short backoff — a momentary blip used to
    /// end a set walk for good. Follows one JavaScript `window.location.replace`
    /// hop: www answers many requests (canonical-case, share links) with a tiny
    /// JS redirect stub instead of an HTTP redirect.
    nonisolated private static func fetchHTML(_ urlString: String, creds: Credentials, hops: Int = 1) async -> (html: String, finalURL: String)? {
        guard let url = URL(string: urlString) else { return nil }
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: UInt64(attempt) * 1_500_000_000) }
            await pacer.waitTurn()
            guard let (data, resp) = try? await session.data(for: request(url, creds: creds, html: true)) else { continue }
            if let code = (resp as? HTTPURLResponse)?.statusCode {
                if code == 429 || code >= 500 { continue }       // rate-limited / transient
                if code >= 400 { return nil }
            }
            guard let s = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }
            let finalURL = resp.url?.absoluteString ?? urlString
            if hops > 0, s.count < 4096,
               let target = firstMatch(s, "window\\.location\\.replace\\(\"((?:[^\"\\\\]|\\\\.)+)\"\\)").map(unescapeJSON),
               target.hasPrefix("https://"), target != finalURL {
                return await fetchHTML(target, creds: creds, hops: hops - 1)
            }
            return (s, finalURL)
        }
        return nil
    }

    /// True when Facebook answered with a login wall instead of the page.
    nonisolated private static func looksLikeLogin(_ html: String, _ finalURL: String) -> Bool {
        if finalURL.contains("/login") || finalURL.contains("login_via") || finalURL.contains("/checkpoint") { return true }
        return html.contains("id=\"login_form\"") || html.contains("name=\"login\"") && html.contains("name=\"pass\"")
    }

    /// Media bytes from the CDN (no pacing — a different host than www), with the
    /// same transient-failure retry as page fetches.
    nonisolated private static func downloadData(_ urlString: String, creds: Credentials) async -> Data? {
        guard let url = URL(string: urlString) else { return nil }
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000) }
            guard let (data, resp) = try? await session.data(for: request(url, creds: creds, html: false)) else { continue }
            if let code = (resp as? HTTPURLResponse)?.statusCode {
                if code == 429 || code >= 500 { continue }
                if code >= 400 { return nil }
            }
            return data
        }
        return nil
    }

    // MARK: - Small helpers

    /// Compiled-pattern cache: every photo page runs the same half-dozen constant
    /// patterns, and a 10k-photo walk would otherwise recompile them per page.
    nonisolated private static let regexCache = NSCache<NSString, NSRegularExpression>()
    nonisolated private static func regex(_ pattern: String) -> NSRegularExpression? {
        if let cached = regexCache.object(forKey: pattern as NSString) { return cached }
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return nil }
        regexCache.setObject(re, forKey: pattern as NSString)
        return re
    }
    nonisolated private static func matches(_ s: String, _ pattern: String) -> [[String]] {
        guard let re = regex(pattern) else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { m in
            (0..<m.numberOfRanges).map { i in
                let r = m.range(at: i); return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
        }
    }
    /// Stops at the first hit — these run against multi-MB pages where patterns
    /// like the caption blob can match dozens of times.
    nonisolated private static func firstMatch(_ s: String, _ pattern: String) -> String? {
        guard let re = regex(pattern) else { return nil }
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 1 else { return nil }
        let r = m.range(at: 1)
        return r.location == NSNotFound ? nil : ns.substring(with: r)
    }
    /// Unescapes a raw JSON string body (`\/`, `\uXXXX` incl. surrogate pairs, `\n`, …).
    nonisolated private static func unescapeJSON(_ s: String) -> String {
        if let data = "\"\(s)\"".data(using: .utf8),
           let decoded = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? String {
            return decoded
        }
        return decode(s)
    }
    nonisolated private static func decode(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#039;", with: "'").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "\\/", with: "/")
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
