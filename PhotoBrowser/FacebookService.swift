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
        let isPublic: Bool          // page renders logged-OUT → media can be pulled without the session cookie
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
        cfg.httpMaximumConnectionsPerHost = 8       // enough CDN parallelism to stay fast, without
                                                    // the 24-wide burst that reads as automated
        return URLSession(configuration: cfg)
    }()

    // MARK: - Coordination

    /// Spaces www page fetches globally — every concurrent walk draws from the one
    /// budget, so parallel discovery stays gentle on Facebook's rate limiting while
    /// overlapping all the request latency.
    ///
    /// The gap is **randomized around a base, not a fixed interval** on purpose. Meta's
    /// "automated behavior" / "we limit how often you can do certain things" enforcement keys
    /// on machine signatures — a perfectly even request cadence, no idle time, sustained bursts.
    /// A jittered gap (± the base), the occasional longer pause (as if the person stopped to read
    /// a post), and an **adaptive penalty** that widens the spacing after a 429/checkpoint together
    /// make the traffic look human while still averaging ~9 pages/s — fast enough to matter, under
    /// the threshold that trips a re-auth wall on a logged-in session.
    private actor Pacer {
        private var next = ContinuousClock.now
        private let baseMS: Double
        private let jitter: Double
        private var penaltyMS = 0.0
        init(baseMS: Double, jitter: Double) { self.baseMS = baseMS; self.jitter = jitter }
        func waitTurn() async {
            let now = ContinuousClock.now
            let slot = max(next, now)
            var gap = baseMS * (1 + Double.random(in: -jitter...jitter)) + penaltyMS
            if Double.random(in: 0..<1) < 0.05 { gap += Double.random(in: 500...1500) }   // rare human pause
            next = slot + .milliseconds(Int(gap.rounded()))
            penaltyMS = max(0, penaltyMS - baseMS)                                          // decay last penalty
            if slot > now { try? await Task.sleep(until: slot, clock: .continuous) }
        }
        /// Back off after a rate-limit/checkpoint signal — subsequent turns space out further,
        /// the way a person slows down after hitting an "action blocked" wall.
        func penalize() { penaltyMS = min(penaltyMS + 2000, 10_000) }
    }
    nonisolated private static let pacer = Pacer(baseMS: 110, jitter: 0.5)


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
        func savedOne() { saved += 1; if saved <= 5 || saved % 4 == 0 || saved == foundCount { report() } }
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
                                skipTagged: Bool = false, includeSubscriberHub: Bool = false,
                                progress: @escaping @Sendable (Progress) -> Void) async -> DownloadResult {
        var result = DownloadResult()
        progress(Progress(phase: "Loading profile…", fraction: 0, done: 0, total: 0))
        guard let profile = await resolveProfile(profileURL, creds: creds) else {
            result.note = "Couldn’t open that profile. Check the link, that you’re logged in, and that you can view it."
            return result
        }
        result.profile = profile
        // Public profile → fetch the content as a logged-out visitor so the user's session cookie
        // never rides along with the bulk media download (account-footprint reduction). Private/
        // gated profiles still need the session, so they keep it.
        let anon = profile.isPublic
        if !profile.picURL.isEmpty {
            result.profilePic = await downloadData(profile.picURL, creds: anon ? Credentials(cookie: "") : creds)
        }

        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // Dedup is by media id. The persisted `alreadyDownloaded` set only reflects the
        // *last completed* run, so an interrupted run (or a folder built by an older
        // build) would re-fetch everything. Rebuild the real ground truth from the files
        // actually on disk — every saved item is `FB_<id>.<ext>` — and union it in. This
        // makes "Get New" genuinely incremental: previously-saved ids are skipped, the
        // early-stop in `walkSet` trips fast on newest-first sets, and nothing already
        // present is downloaded again.
        let onDiskIDs = existingMediaIDs(in: folder)
        let skip = alreadyDownloaded.union(onDiskIDs)

        // A per-run diagnostic log written into the folder, so an incomplete download can be
        // traced set by set (which media-set tokens were found, how many each walk emitted,
        // and why each walk stopped) without a debugger against live Facebook.
        let log = DownloadLog(folder: folder, kind: "facebook")
        await log.begin("Facebook download — \(profile.name)")
        await log.log("profile: name=\(profile.name), id=\(profile.id), vanity=\(profile.vanity ?? "—"), url=\(profile.url)")
        await log.log("already downloaded: \(alreadyDownloaded.count) recorded id(s) + \(onDiskIDs.count) on disk → \(skip.count) skipped for dedup")
        await log.log("options: skipTagged=\(skipTagged), includeSubscriberHub=\(includeSubscriberHub)")
        await log.log("profile is \(profile.isPublic ? "PUBLIC — downloading media anonymously (no session cookie)" : "not confirmed public — downloading with the session cookie")")

        // Discovery and download overlap: collectors walk concurrently and feed the
        // hub (which dedups across sets) into the stream; the consumer below starts
        // downloading the first photo while the walks are still finding the rest.
        let (stream, continuation) = AsyncStream.makeStream(of: Item.self)
        let hub = Hub(already: skip, continuation: continuation, progress: progress)

        let discovery = Task {
            await withTaskGroup(of: Void.self) { group in
                // Albums cover profile/cover pictures and paginate past the ~100-photo
                // ceiling of the pb virtual set; the pb walk still runs alongside for
                // uploads not filed under an enumerable album — the hub dedups overlap.
                group.addTask { await collectAlbums(profile, skip: skip, creds: creds, hub: hub, log: log) }
                group.addTask {
                    await collectPhotos(profile, tab: "photos_by", fallbackToken: "pb.\(profile.id).-2207520000",
                                        tokenPrefixes: ["pb.", "a."], skip: skip, creds: creds, hub: hub, log: log)
                }
                if !skipTagged {
                    group.addTask {
                        // Tagged photos are posted by someone else — credit the page owner.
                        // Pin to the `t.` (Photos-of) set so the walk can't wander into a
                        // poster's album and drag in their non-tagged uploads.
                        await collectPhotos(profile, tab: "photos_of", fallbackToken: "t.\(profile.id)",
                                            tokenPrefixes: ["t."], skip: skip, creds: creds, hub: hub,
                                            ownerFromPage: true, log: log)
                    }
                }
                group.addTask { await collectVideos(profile, skip: skip, creds: creds, hub: hub, log: log) }
                // Subscriber-only content from the creator's Subscriber Hub (Facebook Subscriptions).
                if includeSubscriberHub {
                    group.addTask { await collectSubscriberHub(profile, skip: skip, creds: creds, hub: hub, log: log) }
                }
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
            // 6-wide, not 24: enough to keep the CDN pipe full, without the wide synchronized burst
            // (plus the per-item stagger below) that reads as an automated client.
            let maxConcurrent = 6
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
                    active -= 1; apply(r)
                }
                group.addTask {
                    // Count the save from inside the task, the moment it finishes — otherwise
                    // `savedOne` only fired when the concurrency cap forced a drain, so a run with
                    // fewer items than `maxConcurrent` showed "downloaded 0" until the whole stream
                    // closed even though downloads were completing all along.
                    let r = await download(item, into: folder, posterFallback: posterFallback, creds: creds, anonymous: anon)
                    await hub.savedOne()
                    return r
                }
                active += 1
            }
            while let r = await group.next() { apply(r) }
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

        let discovered = await hub.foundCount
        let loginWall = await hub.hitLoginWall
        if discovered == 0 {
            result.note = loginWall
                ? "Facebook asked for a fresh login. Tap “Log in to Facebook”, sign in again, and retry."
                : (skip.isEmpty
                    ? "No downloadable photos or videos found (the profile may be private, empty, or Facebook may be blocking access)."
                    : "No new photos or videos.")
        } else if result.photos + result.videos == 0 {
            result.note = "Couldn’t download any media (Facebook may be blocking access)."
        } else if result.failed > 0 {
            result.note = "\(result.failed) item(s) couldn’t be downloaded."
        }
        await log.log("hub: discovered \(discovered) new item(s) across all sets; login wall hit: \(loginWall)")
        await log.finish("photos \(result.photos), videos \(result.videos), failed \(result.failed), discovered \(discovered)")
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
        // Is this profile viewable without a login? Probe the resolved URL with NO cookie: a
        // public profile still renders its og-tags / photo markers logged-out, a private/gated one
        // bounces to a login wall. When public, the media download runs anonymously (below) so the
        // bulk content fetch is never tied to the user's own Facebook session.
        let isPublic = await isProfilePublic(finalURL)
        return Profile(id: pid ?? vanity ?? "", vanity: vanity, name: name, url: finalURL, picURL: pic, isPublic: isPublic)
    }

    /// Whether the profile page renders for a logged-OUT request (a real public profile) rather
    /// than redirecting to a login wall. Best-effort and conservative: any doubt → treated as
    /// non-public, so the download simply falls back to the authenticated path (which always works).
    nonisolated private static func isProfilePublic(_ url: String) async -> Bool {
        guard let (html, finalURL) = await fetchHTML(url, creds: Credentials(cookie: "")) else { return false }
        if looksLikeLogin(html, finalURL) { return false }
        return meta(html, "og:title") != nil || meta(html, "og:image") != nil || firstPhotoID(html) != nil
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
                                                  creds: Credentials, hub: Hub, log: DownloadLog? = nil) async {
        guard let (html, finalURL) = await fetchHTML(host + tabPath(profile, "photos_albums"), creds: creds) else {
            await log?.log("albums tab: fetch failed"); return
        }
        if looksLikeLogin(html, finalURL) { await log?.log("albums tab: login wall"); await hub.loginWalled(); return }
        var tokens: [String] = []; var seen = Set<String>()
        for g in matches(html, "set=a\\.(\\d+)") where seen.insert(g[1]).inserted { tokens.append("a.\(g[1])") }
        for g in matches(html, "\"__typename\":\"Album\",\"id\":\"(\\d+)\"") where seen.insert(g[1]).inserted { tokens.append("a.\(g[1])") }
        // Extra album-id shapes the page can use — a foreign/stale id just walks to nothing
        // (deduped by the hub), so casting a wider net only helps coverage.
        for g in matches(html, "\"album_?id\":\"(\\d+)\"") where seen.insert(g[1]).inserted { tokens.append("a.\(g[1])") }
        for g in matches(html, "albums\\\\?/(\\d{6,})") where seen.insert(g[1]).inserted { tokens.append("a.\(g[1])") }
        await log?.log("albums tab: found \(tokens.count) album token(s)\(tokens.isEmpty ? " (none — the album list may be JS-only; uploads then rely on the pb walk)" : ": \(tokens.joined(separator: ", "))")")
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
                group.addTask { await walkSet(token, firstID: nil, skip: skip, creds: creds, hub: hub, earlyStop: false, label: "album \(token)", log: log) }
            }
            for _ in 0..<min(maxConcurrent, tokens.count) { addNext() }
            while await group.next() != nil { addNext() }
        }
    }

    /// A photo tab (`photos_by` = uploads, `photos_of` = tagged) names a media-set
    /// token; the set is then walked photo by photo. When the tab won't reveal a
    /// token the classic constructed token is tried — worst case the walk finds no
    /// first photo and emits nothing.
    ///
    /// `tokenPrefixes` pins the token to the expected **set family**: the walk
    /// paginates within whatever `set=` it's handed, so on the tagged tab we must
    /// only accept a `t.` (Photos-of-X) token. A thumbnail on that page links each
    /// photo to *its own owning album* (`a.`/`pb.`, owned by whoever posted it);
    /// grabbing one of those sent the walk into that person's whole album and pulled
    /// in every non-tagged upload. Constraining the family (else keeping the `t.`
    /// fallback) keeps tagged discovery to photos the profile is actually in.
    nonisolated private static func collectPhotos(_ profile: Profile, tab: String, fallbackToken: String,
                                                  tokenPrefixes: [String], skip: Set<String>, creds: Credentials,
                                                  hub: Hub, ownerFromPage: Bool = false, log: DownloadLog? = nil) async {
        var token = fallbackToken
        var resolvedToken = false
        var firstID: String?
        if let (html, finalURL) = await fetchHTML(host + tabPath(profile, tab), creds: creds) {
            if looksLikeLogin(html, finalURL) { await log?.log("[\(tab)] login wall"); await hub.loginWalled(); return }
            // `t.` → `t\.`, etc., so the dot is a literal in the alternation.
            let alt = tokenPrefixes.map { $0.replacingOccurrences(of: ".", with: "\\.") }.joined(separator: "|")
            if let t = firstMatch(html, "\"media_?set_?token\":\"((?:\(alt))[^\"]+)\"")
                ?? firstMatch(html, "set=((?:\(alt))[0-9A-Za-z%.\\-]+)") {
                token = decode(t); resolvedToken = true
            }
            firstID = firstPhotoID(html)
        } else {
            await log?.log("[\(tab)] tab fetch failed")
        }
        await log?.log("[\(tab)] token=\(token)\(resolvedToken ? "" : " (fallback — not found on page)") firstID=\(firstID ?? "nil")")
        await walkSet(token, firstID: firstID, skip: skip, creds: creds, hub: hub, ownerFromPage: ownerFromPage, label: tab, log: log)
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
                                            ownerFromPage: Bool = false, maxItems: Int = 10_000,
                                            label: String = "", log: DownloadLog? = nil) async {
        var nextID = firstID
        if nextID == nil {
            guard let (html, finalURL) = await fetchHTML(host + "media/set/?set=\(token)", creds: creds) else {
                await log?.log("[\(label)] set-page fetch failed — 0 emitted"); return
            }
            if looksLikeLogin(html, finalURL) { await log?.log("[\(label)] login wall"); await hub.loginWalled(); return }
            nextID = firstPhotoID(html)
        }
        var visited = Set<String>()
        var knownStreak = 0
        var emitted = 0
        // Distinguish "genuinely reached the end of the chain" from "the chain broke while a
        // page still had a photo" — the latter is the truncation signature (a stale next-id
        // pattern), the single most useful clue when a set comes up short.
        var stop = "end of chain (no next pointer)"
        while let id = nextID, visited.insert(id).inserted {
            if visited.count > maxItems { stop = "hit maxItems (\(maxItems))"; break }
            if await hub.hitLoginWall { stop = "another walk hit the login wall"; return }
            // Keep the best page seen: a failed alternate fetch must not throw away
            // a primary page that still carried the next pointer.
            var page: (html: String, finalURL: String)?
            for form in ["photo/?fbid=\(id)&set=\(token)", "photo.php?fbid=\(id)&set=\(token)"] {
                guard let p = await fetchHTML(host + form, creds: creds) else { continue }
                page = p
                if photoPageLooksComplete(p.html) || looksLikeLogin(p.html, p.finalURL) { break }
            }
            guard let (html, finalURL) = page else { stop = "page fetch failed at id \(id)"; break }
            if looksLikeLogin(html, finalURL) { stop = "login wall at id \(id)"; await hub.loginWalled(); return }
            if skip.contains(id) {
                knownStreak += 1
                if earlyStop, knownStreak >= 30 { stop = "early-stop (30 consecutive known ids)"; break }
            } else {
                knownStreak = 0
                // Only tagged sets credit the page's owner blob — on a profile's own
                // uploads the first "owner" can be a crossposted entity.
                let poster = ownerFromPage ? photoOwner(html) : ""
                if let url = imageURL(html) {
                    await hub.emit(Item(id: id, isVideo: false, url: url, caption: photoCaption(html),
                                        date: createdTime(html), poster: poster)); emitted += 1
                } else if let url = videoURL(html) {
                    // A video sitting in the set (common among tagged media) — grab it
                    // too, so tagged coverage isn't photos-only.
                    await hub.emit(Item(id: id, isVideo: true, url: url, caption: photoCaption(html),
                                        date: createdTime(html), poster: poster)); emitted += 1
                }
            }
            let advance = nextPhotoID(html)
            if advance == nil, imageURL(html) != nil {
                stop = "chain broke at id \(id) — page HAD a photo but no next pointer (likely truncation, not the real end)"
            }
            nextID = advance
        }
        if !label.isEmpty { await log?.log("[\(label)] set=\(token): walked \(visited.count) page(s), emitted \(emitted), stop: \(stop)") }
    }

    /// The videos tab lists permalinks; each watch page embeds direct HD/SD URLs.
    /// Watch pages resolve a few at a time through the shared pacer.
    nonisolated private static func collectVideos(_ profile: Profile, skip: Set<String>,
                                                  creds: Credentials, hub: Hub, log: DownloadLog? = nil) async {
        guard let (html, finalURL) = await fetchHTML(host + tabPath(profile, "videos"), creds: creds) else {
            await log?.log("videos tab: fetch failed"); return
        }
        if looksLikeLogin(html, finalURL) { await log?.log("videos tab: login wall"); await hub.loginWalled(); return }
        var ids: [String] = []; var seen = Set<String>()
        for g in matches(html, "videos\\\\?/(\\d{8,})") where seen.insert(g[1]).inserted { ids.append(g[1]) }
        for g in matches(html, "\"video_?id\":\"(\\d{8,})\"") where seen.insert(g[1]).inserted { ids.append(g[1]) }
        for g in matches(html, "watch/\\?v=(\\d{8,})") where seen.insert(g[1]).inserted { ids.append(g[1]) }
        let targets = ids.filter { !skip.contains($0) }
        await log?.log("videos tab: \(ids.count) id(s) found, \(targets.count) new to fetch")
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

    // MARK: - Subscriber Hub (Facebook Subscriptions / fan subscriptions)

    /// Subscriber-only content from a creator's **Subscriber Hub** — the exclusive posts a paying
    /// subscriber can see. Facebook gates the hub behind the session and doesn't publish a stable
    /// URL for its feed, so this tries the known entry-point forms and harvests media from whichever
    /// real (non-login) page answers, using the same parsers as the other collectors: any media-set
    /// tokens on the page are walked in full (the complete route when exclusive photos live in a
    /// set), and the first feed page's standalone photos/videos are fetched directly. Deep feed
    /// pagination needs volatile GraphQL cursors, so coverage is best-effort and weighted to recent
    /// content; the hub dedups everything against the other sets. A non-subscriber (or a profile
    /// with no subscription) simply finds nothing — surfaced in the per-run log.
    nonisolated private static func collectSubscriberHub(_ profile: Profile, skip: Set<String>,
                                                         creds: Credentials, hub: Hub, log: DownloadLog? = nil) async {
        // Candidate entry points — vanity path and id-based tab forms of the hub.
        var candidates: [String] = []
        if let v = profile.vanity { candidates += ["\(v)/subscriber_hub", "\(v)?sk=subscriber_hub"] }
        if !profile.id.isEmpty, profile.id.allSatisfy({ $0.isNumber }) {
            candidates += ["profile.php?id=\(profile.id)&sk=subscriber_hub",
                           "subscriber_hub/?creator_id=\(profile.id)"]
        }
        var page: String?
        var used = ""
        for path in candidates {
            guard let p = await fetchHTML(host + path, creds: creds) else { continue }
            // A wrong hub URL can redirect to login — treat that as "this candidate isn't it" and
            // try the next, WITHOUT signalling the global login wall (which would abort the primary
            // collectors). A genuine session expiry is still caught by them on their own URLs.
            if looksLikeLogin(p.html, p.finalURL) { await log?.log("subscriber hub [\(path)]: login redirect — skipping"); continue }
            if hasMediaMarkers(p.html) { page = p.html; used = path; break }   // a real hub feed
        }
        guard let html = page else {
            await log?.log("subscriber hub: no reachable feed among \(candidates.count) candidate URL(s) — you may not be subscribed, or this profile has no Subscriptions")
            return
        }

        // Media-set tokens → walk each in full (like albums; exclusive photos are often a set).
        var tokens: [String] = []; var seenTok = Set<String>()
        for g in matches(html, "set=([a-z]+\\.[0-9A-Za-z%.\\-]+)") where seenTok.insert(g[1]).inserted { tokens.append(decode(g[1])) }
        // Standalone photos/videos on the first feed page (capped — deeper pages aren't reachable).
        var photoIDs: [String] = []; var seenP = Set<String>()
        for g in matches(html, "fbid=(\\d{6,})") where seenP.insert(g[1]).inserted { photoIDs.append(g[1]) }
        for g in matches(html, "\"__typename\":\"Photo\",\"id\":\"(\\d{6,})\"") where seenP.insert(g[1]).inserted { photoIDs.append(g[1]) }
        var videoIDs: [String] = []; var seenV = Set<String>()
        for g in matches(html, "\"video_?id\":\"(\\d{8,})\"") where seenV.insert(g[1]).inserted { videoIDs.append(g[1]) }
        for g in matches(html, "watch/\\?v=(\\d{8,})") where seenV.insert(g[1]).inserted { videoIDs.append(g[1]) }
        photoIDs = Array(photoIDs.prefix(80))
        await log?.log("subscriber hub [\(used)]: \(tokens.count) set(s), \(photoIDs.count) photo id(s), \(videoIDs.count) video id(s)")

        await withTaskGroup(of: Void.self) { group in
            for token in tokens {
                // No early stop: an exclusive set may be user-ordered, so walk it fully.
                group.addTask { await walkSet(token, firstID: nil, skip: skip, creds: creds, hub: hub, earlyStop: false, label: "subhub \(token)", log: log) }
            }
            for id in photoIDs where !skip.contains(id) {
                group.addTask { await emitPhotoPage(id: id, creds: creds, hub: hub) }
            }
            for id in videoIDs where !skip.contains(id) {
                group.addTask {
                    if await hub.hitLoginWall { return }
                    guard let (p, u) = await fetchHTML(host + "watch/?v=\(id)", creds: creds) else { return }
                    if looksLikeLogin(p, u) { return }
                    guard let vurl = videoURL(p) else { return }
                    await hub.emit(Item(id: id, isVideo: true, url: vurl, caption: photoCaption(p),
                                        date: createdTime(p), poster: photoOwner(p)))
                }
            }
        }
    }

    /// Fetches a single photo page (an exclusive feed post's attachment) and emits its media.
    /// The owner blob is credited (an exclusive post is the creator's own, but tolerating a
    /// crosspost is harmless — the profile name is the fallback at download time).
    nonisolated private static func emitPhotoPage(id: String, creds: Credentials, hub: Hub) async {
        if await hub.hitLoginWall { return }
        var page: (html: String, finalURL: String)?
        for form in ["photo/?fbid=\(id)", "photo.php?fbid=\(id)"] {
            guard let p = await fetchHTML(host + form, creds: creds) else { continue }
            page = p
            if photoPageLooksComplete(p.html) || looksLikeLogin(p.html, p.finalURL) { break }
        }
        guard let (html, finalURL) = page else { return }
        if looksLikeLogin(html, finalURL) { return }
        if let url = imageURL(html) {
            await hub.emit(Item(id: id, isVideo: false, url: url, caption: photoCaption(html),
                                date: createdTime(html), poster: photoOwner(html)))
        } else if let url = videoURL(html) {
            await hub.emit(Item(id: id, isVideo: true, url: url, caption: photoCaption(html),
                                date: createdTime(html), poster: photoOwner(html)))
        }
    }

    /// Whether a page carries any media markers (a real feed/set) rather than an empty shell or a
    /// wrong-URL redirect — used to pick the subscriber-hub entry point that actually answered.
    nonisolated private static func hasMediaMarkers(_ html: String) -> Bool {
        firstPhotoID(html) != nil
            || firstMatch(html, "set=[a-z]+\\.[0-9A-Za-z]") != nil
            || firstMatch(html, "watch/\\?v=\\d") != nil
            || firstMatch(html, "\"video_?id\":\"\\d") != nil
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
                                             creds: Credentials, anonymous: Bool) async -> (ok: Bool, isVideo: Bool, id: String, path: String?, caption: String, poster: String, date: Date?) {
        // Human-like stagger: without it a batch of downloads fires as one synchronized burst the
        // moment the concurrency slots free up — a classic automated signature. A small random
        // lead-in spreads them out.
        try? await Task.sleep(nanoseconds: UInt64(Double.random(in: 0...0.3) * 1_000_000_000))
        let poster = item.poster.isEmpty ? posterFallback : item.poster
        // Public profile → pull the media as a logged-out visitor (empty cookie). fbcdn URLs are
        // already signed (`?oh=…&oe=…`), so they serve without the session; keeping the user's
        // cookie off the bulk content fetch is exactly what reduces the account's automation footprint.
        let mediaCreds = anonymous ? Credentials(cookie: "") : creds
        var data = await downloadData(item.url, creds: mediaCreds)
        // Safety net: if the anonymous fetch came up empty (mis-detected "public", or a CDN that
        // refused the logged-out request), fall back to the authenticated download so content is
        // never lost — the anonymity is a best-effort footprint reduction, not a hard requirement.
        if anonymous, (data?.count ?? 0) < 512 { data = await downloadData(item.url, creds: creds) }
        guard let data, data.count >= 512 else {
            return (false, item.isVideo, item.id, nil, "", poster, nil)
        }
        let ext = item.isVideo ? "mp4" : imageExt(of: item.url)
        // Deterministic name keyed by media id. Dedup already keeps us from re-fetching an
        // id that's on disk, so this never clobbers a *different* item — and dropping the
        // old " N" collision suffix means a re-run can't spawn `FB_<id> 1.jpg` twins.
        let dest = folder.appendingPathComponent("FB_\(item.id).\(ext)")
        guard (try? data.write(to: dest, options: .atomic)) != nil else { return (false, item.isVideo, item.id, nil, "", poster, nil) }
        if !item.isVideo { writeImageMeta(date: item.date, caption: item.caption, poster: poster, to: dest) }
        setFileDate(dest, item.date)
        DriveWriter.fullSyncFileAndParent(dest)   // exFAT: force the file+dir to media so an unplug can't leak clusters
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
        // An empty cookie means "download this as a logged-out visitor" (public profiles) — send no
        // Cookie header at all rather than an empty one, so the request carries nothing tying the
        // bulk content fetch to the user's session.
        if !creds.cookie.isEmpty { req.setValue(creds.cookie, forHTTPHeaderField: "Cookie") }
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
                if code == 429 || code >= 500 { await pacer.penalize(); continue }   // rate-limited → back off & widen spacing
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
                if code == 429 || code >= 500 { await pacer.penalize(); continue }   // CDN pressure → slow the page walk too
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
    /// Media ids already saved in this folder, read straight off disk. Every download is
    /// named `FB_<id>.<ext>` (older buggy runs could also leave `FB_<id> N.<ext>` twins),
    /// so strip the `FB_` prefix, the extension, and any trailing " N" to recover the id.
    /// This is what makes dedup survive an interrupted run: the persisted id list only
    /// updates on a clean finish, but the files are the real record.
    nonisolated private static func existingMediaIDs(in folder: URL) -> Set<String> {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return [] }
        var ids = Set<String>()
        for name in names where name.hasPrefix("FB_") {
            var stem = (name as NSString).deletingPathExtension
            stem.removeFirst(3)   // drop "FB_"
            // Undo an old collision suffix: "12345 1" → "12345".
            if let sp = stem.lastIndex(of: " "),
               stem[stem.index(after: sp)...].allSatisfy(\.isNumber),
               stem.index(after: sp) != stem.endIndex {
                stem = String(stem[..<sp])
            }
            if !stem.isEmpty { ids.insert(stem) }
        }
        return ids
    }
}
