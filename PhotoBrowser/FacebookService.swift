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
/// since Facebook retired the old `mbasic` HTML site. Media sets are walked photo
/// by photo via each page's "next media" pointer (no GraphQL doc_ids to go stale),
/// and every photo page hands us the full-resolution URL, the exact `created_time`,
/// and the caption. Best-effort and download-only, like the Instagram/MEGA
/// features — Facebook actively fights scraping, so parsing is defensive, failures
/// are surfaced as notes, and a login wall is reported as exactly that.
/// All `nonisolated`: networking + parsing + writes.
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
        cfg.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: cfg)
    }()

    // MARK: - Orchestration

    nonisolated static func run(profileURL: String, into folder: URL, alreadyDownloaded: Set<String>,
                                creds: Credentials, progress: @escaping @Sendable (Progress) -> Void) async -> DownloadResult {
        var result = DownloadResult()
        progress(Progress(phase: "Loading profile…", fraction: 0, done: 0, total: 0))
        guard let profile = await resolveProfile(profileURL, creds: creds) else {
            result.note = "Couldn’t open that profile. Check the link, that you’re logged in, and that you can view it."
            return result
        }
        result.profile = profile
        if !profile.picURL.isEmpty { result.profilePic = await downloadData(profile.picURL, creds: creds) }

        // Discover media: the profile's own photos, tagged photos, and videos.
        var items: [Item] = []; var seen = Set<String>()
        var loginWall = false
        func add(_ found: (items: [Item], loginWall: Bool)) {
            loginWall = loginWall || found.loginWall
            for i in found.items where seen.insert(i.id).inserted && !alreadyDownloaded.contains(i.id) {
                items.append(i)
            }
        }
        add(await collectPhotos(profile, tab: "photos_by", fallbackToken: "pb.\(profile.id).-2207520000",
                                skip: alreadyDownloaded, creds: creds, progress: progress, phase: "Finding photos"))
        add(await collectPhotos(profile, tab: "photos_of", fallbackToken: "t.\(profile.id)",
                                skip: alreadyDownloaded, creds: creds, progress: progress, phase: "Finding tagged photos"))
        add(await collectVideos(profile, skip: alreadyDownloaded, creds: creds, progress: progress))

        guard !items.isEmpty else {
            result.note = loginWall
                ? "Facebook asked for a fresh login. Tap “Log in to Facebook”, sign in again, and retry."
                : (alreadyDownloaded.isEmpty
                    ? "No downloadable photos or videos found (the profile may be private, empty, or Facebook may be blocking access)."
                    : "No new photos or videos.")
            return result
        }

        // Download the discovered media concurrently.
        let total = items.count
        var done = 0
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        await withTaskGroup(of: (ok: Bool, isVideo: Bool, id: String, path: String?, caption: String).self) { group in
            var idx = 0
            let maxConcurrent = 5
            func addNext() {
                guard idx < items.count else { return }
                let item = items[idx]; idx += 1
                group.addTask { await download(item, into: folder, poster: profile.name, creds: creds) }
            }
            for _ in 0..<min(maxConcurrent, total) { addNext() }
            while let r = await group.next() {
                done += 1
                if r.ok {
                    if r.isVideo { result.videos += 1 } else { result.photos += 1 }
                    result.newIDs.append(r.id)
                    if let path = r.path {
                        result.postedBy[path] = profile.name
                        if !r.caption.isEmpty { result.captions[path] = r.caption }
                    }
                } else { result.failed += 1 }
                if done % 4 == 0 || done == total {
                    progress(Progress(phase: "Downloading", fraction: Double(done) / Double(total), done: done, total: total))
                }
                addNext()
            }
        }
        if result.photos + result.videos == 0 { result.note = "Couldn’t download any media (Facebook may be blocking access)." }
        else if result.failed > 0 { result.note = "\(result.failed) item(s) couldn’t be downloaded." }
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

        let name = meta(html, "og:title").map(decode)
            ?? firstMatch(html, "<title>([^<]+)</title>").map(decode)
            ?? "Facebook Profile"
        let pic = meta(html, "og:image").map(decode) ?? ""
        return Profile(id: pid ?? vanity ?? "", vanity: vanity, name: cleanName(name), url: finalURL, picURL: pic)
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

    /// The profile's photo tab (`photos_by` = uploads, `photos_of` = tagged) names a
    /// media-set token; the set is then walked photo by photo. When the tab won't
    /// reveal a token the classic constructed token is tried — worst case the walk
    /// finds no first photo and returns empty.
    nonisolated private static func collectPhotos(_ profile: Profile, tab: String, fallbackToken: String,
                                                  skip: Set<String>, creds: Credentials,
                                                  progress: @escaping @Sendable (Progress) -> Void,
                                                  phase: String) async -> (items: [Item], loginWall: Bool) {
        progress(Progress(phase: "\(phase)…", fraction: 0, done: 0, total: 0))
        var token = fallbackToken
        var firstID: String?
        if let (html, finalURL) = await fetchHTML(host + tabPath(profile, tab), creds: creds) {
            if looksLikeLogin(html, finalURL) { return ([], true) }
            if let t = firstMatch(html, "\"media_?set_?token\":\"([^\"]+)\"")
                ?? firstMatch(html, "set=((?:a|pb|t)\\.[0-9A-Za-z%.\\-]+)") {
                token = decode(t)
            }
            firstID = firstPhotoID(html)
        }
        return await walkSet(token, firstID: firstID, skip: skip, creds: creds, progress: progress, phase: phase)
    }

    /// Walks a media set photo by photo: each photo page embeds the full-res image
    /// URL, caption, exact post time, **and the id of the next photo** — so
    /// pagination needs no volatile GraphQL doc_ids. Newest-first: on a "Get New"
    /// run the walk stops after a stretch of already-downloaded ids.
    nonisolated private static func walkSet(_ token: String, firstID: String?, skip: Set<String>,
                                            creds: Credentials,
                                            progress: @escaping @Sendable (Progress) -> Void,
                                            phase: String, maxItems: Int = 2000) async -> (items: [Item], loginWall: Bool) {
        var nextID = firstID
        if nextID == nil {
            guard let (html, finalURL) = await fetchHTML(host + "media/set/?set=\(token)", creds: creds) else { return ([], false) }
            if looksLikeLogin(html, finalURL) { return ([], true) }
            nextID = firstPhotoID(html)
        }
        var out: [Item] = []; var visited = Set<String>()
        var knownStreak = 0
        while let id = nextID, visited.count < maxItems, visited.insert(id).inserted {
            guard let (html, finalURL) = await fetchHTML(host + "photo/?fbid=\(id)&set=\(token)", creds: creds) else { break }
            if looksLikeLogin(html, finalURL) { return (out, true) }
            if skip.contains(id) {
                knownStreak += 1
                if knownStreak >= 30 { break }               // deep into already-downloaded territory
            } else {
                knownStreak = 0
                if let url = firstJSONString(html, "\"image\":\\{\"uri\":") {
                    out.append(Item(id: id, isVideo: false, url: url,
                                    caption: photoCaption(html), date: createdTime(html)))
                    if out.count % 5 == 0 {
                        progress(Progress(phase: "\(phase)… \(out.count)", fraction: 0, done: out.count, total: 0))
                    }
                }
            }
            nextID = firstMatch(html, "\"nextMediaAfterNodeId\":\\{\"__typename\":\"Photo\",\"id\":\"(\\d+)\"")
                ?? firstMatch(html, "\"nextMedia\":\\{\"edges\":\\[\\{\"node\":\\{\"__typename\":\"Photo\",\"id\":\"(\\d+)\"")
            try? await Task.sleep(nanoseconds: 120_000_000)   // stay gentle; FB rate-limits aggressively
        }
        return (out, false)
    }

    /// The videos tab lists permalinks; each watch page embeds direct HD/SD URLs.
    nonisolated private static func collectVideos(_ profile: Profile, skip: Set<String>, creds: Credentials,
                                                  progress: @escaping @Sendable (Progress) -> Void) async -> (items: [Item], loginWall: Bool) {
        progress(Progress(phase: "Finding videos…", fraction: 0, done: 0, total: 0))
        guard let (html, finalURL) = await fetchHTML(host + tabPath(profile, "videos"), creds: creds) else { return ([], false) }
        if looksLikeLogin(html, finalURL) { return ([], true) }
        var ids: [String] = []; var seen = Set<String>()
        for g in matches(html, "videos\\\\?/(\\d{8,})") where seen.insert(g[1]).inserted { ids.append(g[1]) }
        for g in matches(html, "\"video_?id\":\"(\\d{8,})\"") where seen.insert(g[1]).inserted { ids.append(g[1]) }

        var out: [Item] = []
        for id in ids where !skip.contains(id) {
            guard let (page, pageURL) = await fetchHTML(host + "watch/?v=\(id)", creds: creds) else { continue }
            if looksLikeLogin(page, pageURL) { return (out, true) }
            guard let url = firstJSONString(page, "\"browser_native_hd_url\":")
                ?? firstJSONString(page, "\"playable_url_quality_hd\":")
                ?? firstJSONString(page, "\"browser_native_sd_url\":")
                ?? firstJSONString(page, "\"playable_url\":") else { continue }
            out.append(Item(id: id, isVideo: true, url: url, caption: photoCaption(page), date: createdTime(page)))
            progress(Progress(phase: "Finding videos… \(out.count)", fraction: 0, done: out.count, total: 0))
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
        return (out, false)
    }

    nonisolated private static func tabPath(_ profile: Profile, _ tab: String) -> String {
        if let v = profile.vanity { return "\(v)/\(tab)" }
        return "profile.php?id=\(profile.id)&sk=\(tab)"
    }

    // MARK: - Page parsing

    nonisolated private static func firstPhotoID(_ html: String) -> String? {
        firstMatch(html, "\\{\"__typename\":\"Photo\",\"id\":\"(\\d+)\"")
            ?? firstMatch(html, "\"__isMedia\":\"Photo\"[^{}]*?\"id\":\"(\\d+)\"")
            ?? firstMatch(html, "fbid=(\\d{6,})")
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

    nonisolated private static func download(_ item: Item, into folder: URL, poster: String,
                                             creds: Credentials) async -> (ok: Bool, isVideo: Bool, id: String, path: String?, caption: String) {
        guard let data = await downloadData(item.url, creds: creds), data.count >= 512 else {
            return (false, item.isVideo, item.id, nil, "")
        }
        let ext = item.isVideo ? "mp4" : imageExt(of: item.url)
        let dest = uniqueDestination("FB_\(item.id).\(ext)", in: folder)
        guard (try? data.write(to: dest, options: .atomic)) != nil else { return (false, item.isVideo, item.id, nil, "") }
        if !item.isVideo {
            writeImageMeta(date: item.date, caption: item.caption, poster: poster, to: dest)
        }
        setFileDate(dest, item.date)
        return (true, item.isVideo, item.id, dest.path, item.caption)
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

    /// Fetches a page, following one JavaScript `window.location.replace` hop —
    /// www answers many requests (canonical-case, share links) with a tiny JS
    /// redirect stub instead of an HTTP redirect.
    nonisolated private static func fetchHTML(_ urlString: String, creds: Credentials, hops: Int = 1) async -> (html: String, finalURL: String)? {
        guard let url = URL(string: urlString) else { return nil }
        guard let (data, resp) = try? await session.data(for: request(url, creds: creds, html: true)),
              (resp as? HTTPURLResponse).map({ $0.statusCode < 400 }) ?? true,
              let s = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }
        let finalURL = resp.url?.absoluteString ?? urlString
        if hops > 0, s.count < 4096,
           let target = firstMatch(s, "window\\.location\\.replace\\(\"((?:[^\"\\\\]|\\\\.)+)\"\\)").map(unescapeJSON),
           target.hasPrefix("https://"), target != finalURL {
            return await fetchHTML(target, creds: creds, hops: hops - 1)
        }
        return (s, finalURL)
    }

    /// True when Facebook answered with a login wall instead of the page.
    nonisolated private static func looksLikeLogin(_ html: String, _ finalURL: String) -> Bool {
        if finalURL.contains("/login") || finalURL.contains("login_via") || finalURL.contains("/checkpoint") { return true }
        return html.contains("id=\"login_form\"") || html.contains("name=\"login\"") && html.contains("name=\"pass\"")
    }

    nonisolated private static func downloadData(_ urlString: String, creds: Credentials) async -> Data? {
        guard let url = URL(string: urlString),
              let (data, resp) = try? await session.data(for: request(url, creds: creds, html: false)),
              (resp as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) ?? true else { return nil }
        return data
    }

    // MARK: - Small helpers

    nonisolated private static func matches(_ s: String, _ pattern: String) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { m in
            (0..<m.numberOfRanges).map { i in
                let r = m.range(at: i); return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
        }
    }
    nonisolated private static func firstMatch(_ s: String, _ pattern: String) -> String? {
        let m = matches(s, pattern).first
        return (m?.count ?? 0) > 1 ? m?[1] : nil
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
