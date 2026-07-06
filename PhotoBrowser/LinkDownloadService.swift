import Foundation
import ImageIO
import CryptoKit

/// "Download from a Link": pulls the photos/videos behind a pasted **album or file
/// link** on one of the common file/media hosts into the current folder. One paste
/// box, many hosts — the link's domain picks a resolver that turns the album/file
/// page into a list of direct media URLs, which are then streamed to disk (12-wide,
/// byte-for-byte so EXIF and HDR survive), exactly like the OnlyFans downloader.
///
/// Supported, with a tailored resolver: **pixeldrain**, **gofile**, **bunkr**
/// (+ its `.cr`/`.pk`/… mirrors and the bunkr-family `turbo.cr` / `goonbox.cr`),
/// **cyberdrop**, and **pixl** (Chevereto). Anything else — `cyberfile.me`,
/// `filester.gg`, or a host that moved — falls back to a generic page scrape
/// (`og:image`/`og:video` + direct media links). All of these are unofficial and
/// actively fight scraping, so this is best-effort and download-only, like the
/// Instagram/Facebook/MEGA/OnlyFans features. Everything is `nonisolated`:
/// networking + parsing + big writes stay off the main actor.
enum LinkDownloadService {
    struct Progress: Sendable { var phase: String; var fraction: Double; var done: Int; var total: Int }
    struct DownloadResult: Sendable {
        var downloaded = 0, failed = 0
        var albumName: String?
        var note: String?
    }
    /// One resolved file, ready to stream. `referer`/`cookie` carry any host-specific
    /// headers the CDN needs (gofile wants an `accountToken` cookie; bunkr wants a Referer).
    struct MediaItem: Sendable {
        let url: String
        let filename: String
        var referer: String?
        var cookie: String?
        init(url: String, filename: String, referer: String? = nil, cookie: String? = nil) {
            self.url = url; self.filename = filename; self.referer = referer; self.cookie = cookie
        }
    }

    nonisolated static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    nonisolated static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpShouldSetCookies = false
        cfg.httpCookieStorage = nil
        cfg.timeoutIntervalForRequest = 60
        cfg.httpMaximumConnectionsPerHost = 16
        return URLSession(configuration: cfg)
    }()

    /// True when the pasted string looks like a link one of our resolvers can take
    /// (used to enable the download button). Anything with a host is allowed — the
    /// generic scraper is the catch-all.
    nonisolated static func looksLikeLink(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let host = URL(string: t.hasPrefix("http") ? t : "https://\(t)")?.host else { return false }
        return host.contains(".")
    }

    // MARK: - Orchestration

    nonisolated static func run(link: String, into folder: URL,
                                progress: @escaping @Sendable (Progress) -> Void) async -> DownloadResult {
        var result = DownloadResult()
        progress(Progress(phase: "Resolving link…", fraction: 0, done: 0, total: 0))
        let (items, albumName, note) = await resolve(link)
        result.albumName = albumName
        guard !items.isEmpty else {
            result.note = note ?? "Couldn’t find any downloadable files at that link."
            return result
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let total = items.count
        await withTaskGroup(of: Bool.self) { group in
            var active = 0
            let maxConcurrent = 12          // streams straight to disk — as wide as OnlyFans
            var done = 0
            func report() {
                progress(Progress(phase: "Downloading \(done) of \(total)…",
                                  fraction: total > 0 ? Double(done) / Double(total) : 0, done: done, total: total))
            }
            for item in items {
                if active >= maxConcurrent, let ok = await group.next() {
                    active -= 1; done += 1; if ok { result.downloaded += 1 } else { result.failed += 1 }; report()
                }
                group.addTask { await downloadOne(item, into: folder) }
                active += 1
            }
            while let ok = await group.next() { done += 1; if ok { result.downloaded += 1 } else { result.failed += 1 }; report() }
        }

        if result.downloaded == 0 {
            result.note = "Couldn’t download any files (the host may be blocking access or the link may have expired)."
        } else if result.failed > 0 {
            result.note = "\(result.failed) file(s) couldn’t be downloaded."
        }
        return result
    }

    /// Streams one file to disk byte-for-byte (no re-encode → EXIF/HDR preserved).
    nonisolated private static func downloadOne(_ item: MediaItem, into folder: URL) async -> Bool {
        guard let url = URL(string: item.url) else { return false }
        let dest = uniqueDestination(sanitize(item.filename), in: folder)
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000) }
            var req = URLRequest(url: url)
            req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            if let referer = item.referer { req.setValue(referer, forHTTPHeaderField: "Referer") }
            if let cookie = item.cookie { req.setValue(cookie, forHTTPHeaderField: "Cookie") }
            req.timeoutInterval = 600
            guard let (tmp, resp) = try? await session.download(for: req) else { continue }
            if let code = (resp as? HTTPURLResponse)?.statusCode {
                if code == 429 || code >= 500 { continue }
                if code >= 400 { return false }
            }
            do {
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: tmp, to: dest)
                let ok = (try? dest.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0 >= 64
                if !ok { try? FileManager.default.removeItem(at: dest) }
                return ok
            } catch { return false }
        }
        return false
    }

    // MARK: - Host dispatch

    nonisolated private static func resolve(_ link: String) async -> (items: [MediaItem], albumName: String?, note: String?) {
        let clean = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let host = URL(string: clean.hasPrefix("http") ? clean : "https://\(clean)")?.host?.lowercased() else {
            return ([], nil, "That doesn’t look like a valid link.")
        }
        let url = clean.hasPrefix("http") ? clean : "https://\(clean)"
        if host.contains("pixeldrain")                                   { return await pixeldrain(url) }
        if host.contains("gofile")                                       { return await gofile(url) }
        if host.contains("cyberdrop")                                    { return await cyberdrop(url, host: host) }
        if host.contains("bunkr") || host.contains("turbo.") || host.contains("goonbox") { return await bunkr(url) }
        if host.contains("pixl.")                                        { return await chevereto(url) }
        return await generic(url)     // cyberfile.me, filester.gg, or any unrecognized host
    }

    // MARK: - pixeldrain (clean public API)

    nonisolated private static func pixeldrain(_ link: String) async -> ([MediaItem], String?, String?) {
        if let listID = firstMatch(link, "/l/([A-Za-z0-9]+)") {
            guard let json = await getJSON("https://pixeldrain.com/api/list/\(listID)") as? [String: Any],
                  let files = json["files"] as? [[String: Any]] else { return ([], nil, "Couldn’t load that Pixeldrain list.") }
            let title = json["title"] as? String
            let items: [MediaItem] = files.compactMap { f in
                guard let id = f["id"] as? String else { return nil }
                let name = (f["name"] as? String) ?? "\(id)"
                return MediaItem(url: "https://pixeldrain.com/api/file/\(id)", filename: name)
            }
            return (items, title, nil)
        }
        if let id = firstMatch(link, "/(?:u|api/file)/([A-Za-z0-9]+)") {
            var name = id
            if let info = await getJSON("https://pixeldrain.com/api/file/\(id)/info") as? [String: Any],
               let n = info["name"] as? String { name = n }
            return ([MediaItem(url: "https://pixeldrain.com/api/file/\(id)", filename: name)], nil, nil)
        }
        return ([], nil, "Unrecognized Pixeldrain link.")
    }

    // MARK: - gofile (guest token + dynamic website token)

    nonisolated private static func gofile(_ link: String) async -> ([MediaItem], String?, String?) {
        guard let contentID = firstMatch(link, "gofile\\.io/(?:d|w)/([A-Za-z0-9\\-]+)")
            ?? firstMatch(link, "[?&]c=([A-Za-z0-9\\-]+)") else { return ([], nil, "Unrecognized Gofile link.") }
        // A guest account token is required for the contents API and the download cookie.
        guard let acc = await getJSON("https://api.gofile.io/accounts", method: "POST") as? [String: Any],
              let data = acc["data"] as? [String: Any], let token = data["token"] as? String else {
            return ([], nil, "Couldn’t start a Gofile session.")
        }
        let wt = gofileWebsiteToken(token: token)
        var items: [MediaItem] = []
        var albumName: String?
        await gofileCollect(contentID, token: token, wt: wt, cookie: "accountToken=\(token)", items: &items, albumName: &albumName)
        return (items, albumName, items.isEmpty ? "No files found (the Gofile link may be private or expired)." : nil)
    }

    /// `sha256(userAgent::language::accountToken::(unixTime/14400)::salt)` — Gofile's
    /// client-side website token, rotating every 4 hours (matches their wt.obf.js).
    nonisolated private static func gofileWebsiteToken(token: String) -> String {
        let window = Int(Date().timeIntervalSince1970) / 14400
        let raw = "\(userAgent)::en::\(token)::\(window)::5d4f7g8sd45fsd"
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func gofileCollect(_ contentID: String, token: String, wt: String, cookie: String,
                                                  items: inout [MediaItem], albumName: inout String?, depth: Int = 0) async {
        guard depth < 6 else { return }
        let headers = ["Authorization": "Bearer \(token)", "X-Website-Token": wt]
        guard let json = await getJSON("https://api.gofile.io/contents/\(contentID)?wt=\(wt)", headers: headers) as? [String: Any],
              let data = json["data"] as? [String: Any] else { return }
        if albumName == nil { albumName = data["name"] as? String }
        guard let children = data["children"] as? [String: Any] else { return }
        for (_, value) in children {
            guard let child = value as? [String: Any] else { continue }
            let type = child["type"] as? String
            if type == "folder", let sub = child["id"] as? String {
                await gofileCollect(sub, token: token, wt: wt, cookie: cookie, items: &items, albumName: &albumName, depth: depth + 1)
            } else if let dl = child["link"] as? String {
                let name = (child["name"] as? String) ?? URL(string: dl)?.lastPathComponent ?? "gofile"
                items.append(MediaItem(url: dl, filename: name, referer: "https://gofile.io/", cookie: cookie))
            }
        }
    }

    // MARK: - bunkr family (album JSON + per-file CDN resolve)

    nonisolated private static func bunkr(_ link: String) async -> ([MediaItem], String?, String?) {
        // Album: the page embeds `window.albumFiles = [ {id, original, slug, …}, … ]`.
        if firstMatch(link, "/a/([^/?#]+)") != nil {
            let sep = link.contains("?") ? "&" : "?"
            guard let html = await getText(link + "\(sep)advanced=1") else { return ([], nil, "Couldn’t load that Bunkr album.") }
            let title = firstMatch(html, "<h1[^>]*>\\s*([^<]+?)\\s*</h1>").map(decodeEntities)
            guard let arrayText = firstMatch(html, "window\\.albumFiles\\s*=\\s*(\\[[\\s\\S]*?\\]);"),
                  let arr = (try? JSONSerialization.jsonObject(with: Data(arrayText.utf8))) as? [[String: Any]] else {
                return ([], title, "Couldn’t read the Bunkr album’s file list.")
            }
            let ids: [(id: String, name: String)] = arr.compactMap { f in
                guard let id = idString(f["id"]) else { return nil }
                let name = (f["original"] as? String) ?? (f["name"] as? String) ?? id
                return (id, name)
            }
            let items = await bunkrResolveAll(ids)
            return (items, title, items.isEmpty ? "Couldn’t resolve any Bunkr files (the album may be down)." : nil)
        }
        // Single file page: pull the data id off the page, then resolve it.
        if let html = await getText(link), let id = firstMatch(html, "data-file-id=\"([^\"]+)\"") ?? firstMatch(html, "\"id\":\\s*\"?(\\d{4,})") {
            let name = firstMatch(html, "<h1[^>]*>\\s*([^<]+?)\\s*</h1>").map(decodeEntities) ?? id
            let items = await bunkrResolveAll([(id, name)])
            return (items, nil, items.isEmpty ? "Couldn’t resolve that Bunkr file." : nil)
        }
        return ([], nil, "Unrecognized Bunkr link.")
    }

    /// Resolves each bunkr file id to a direct CDN URL via the `apidl` endpoint,
    /// concurrently. The endpoint may return the URL XOR-encrypted.
    nonisolated private static func bunkrResolveAll(_ ids: [(id: String, name: String)]) async -> [MediaItem] {
        await withTaskGroup(of: MediaItem?.self) { group in
            var out: [MediaItem] = []
            var idx = 0
            let maxConcurrent = 8
            func addNext() {
                guard idx < ids.count else { return }
                let entry = ids[idx]; idx += 1
                group.addTask { await bunkrResolve(entry.id, name: entry.name) }
            }
            for _ in 0..<min(maxConcurrent, ids.count) { addNext() }
            while let r = await group.next() { if let r { out.append(r) }; addNext() }
            return out
        }
    }

    nonisolated private static func bunkrResolve(_ id: String, name: String) async -> MediaItem? {
        let body = try? JSONSerialization.data(withJSONObject: ["id": id])
        let headers = ["Referer": "https://get.bunkrr.su/file/\(id)", "Content-Type": "application/json"]
        guard let json = await getJSON("https://apidl.bunkr.ru/api/_001_v2", method: "POST", body: body, headers: headers) as? [String: Any],
              let raw = json["url"] as? String else { return nil }
        var url = raw
        if (json["encrypted"] as? Bool) == true, let ts = json["timestamp"] as? Int {
            url = bunkrDecrypt(raw, timestamp: ts) ?? raw
        }
        guard url.hasPrefix("http") else { return nil }
        return MediaItem(url: url, filename: name, referer: "https://bunkr.cr/")
    }

    /// XOR-decrypts a base64 URL with the time-bucketed key `SECRET_KEY_{ts/3600}`.
    nonisolated private static func bunkrDecrypt(_ b64: String, timestamp: Int) -> String? {
        guard let data = Data(base64Encoded: b64) else { return nil }
        let key = Array("SECRET_KEY_\(timestamp / 3600)".utf8)
        guard !key.isEmpty else { return nil }
        let out = data.enumerated().map { $0.element ^ key[$0.offset % key.count] }
        return String(bytes: out, encoding: .utf8)
    }

    // MARK: - cyberdrop (lolisafe: album page → per-file info API)

    nonisolated private static func cyberdrop(_ link: String, host: String) async -> ([MediaItem], String?, String?) {
        let apiRoot = "https://api." + (host.hasPrefix("www.") ? String(host.dropFirst(4)) : host)
        if firstMatch(link, "/a/([^/?#]+)") != nil {
            guard let html = await getText(link) else { return ([], nil, "Couldn’t load that Cyberdrop album.") }
            let title = firstMatch(html, "<h1[^>]*id=\"title\"[^>]*>\\s*([^<]+?)\\s*</h1>").map(decodeEntities)
                ?? firstMatch(html, "<title>\\s*([^<]+?)\\s*</title>").map(decodeEntities)
            var seen = Set<String>()
            let ids = matches(html, "href=\"/f/([^\"]+)\"").compactMap { $0.count > 1 ? $0[1] : nil }.filter { seen.insert($0).inserted }
            let items = await cyberdropResolveAll(ids, apiRoot: apiRoot)
            return (items, title, items.isEmpty ? "Couldn’t resolve any Cyberdrop files." : nil)
        }
        if let fid = firstMatch(link, "/[fe]/([^/?#]+)") {
            let items = await cyberdropResolveAll([fid], apiRoot: apiRoot)
            return (items, nil, items.isEmpty ? "Couldn’t resolve that Cyberdrop file." : nil)
        }
        return ([], nil, "Unrecognized Cyberdrop link.")
    }

    nonisolated private static func cyberdropResolveAll(_ ids: [String], apiRoot: String) async -> [MediaItem] {
        await withTaskGroup(of: MediaItem?.self) { group in
            var out: [MediaItem] = []
            var idx = 0
            let maxConcurrent = 8
            func addNext() {
                guard idx < ids.count else { return }
                let id = ids[idx]; idx += 1
                group.addTask { await cyberdropResolve(id, apiRoot: apiRoot) }
            }
            for _ in 0..<min(maxConcurrent, ids.count) { addNext() }
            while let r = await group.next() { if let r { out.append(r) }; addNext() }
            return out
        }
    }

    nonisolated private static func cyberdropResolve(_ id: String, apiRoot: String) async -> MediaItem? {
        guard let info = await getJSON("\(apiRoot)/api/file/info/\(id)") as? [String: Any] else { return nil }
        let name = (info["name"] as? String) ?? (info["filename"] as? String) ?? id
        guard let authURL = info["auth_url"] as? String,
              let auth = await getJSON(authURL) as? [String: Any],
              let url = auth["url"] as? String, url.hasPrefix("http") else { return nil }
        return MediaItem(url: url, filename: name, referer: apiRoot.replacingOccurrences(of: "https://api.", with: "https://") + "/")
    }

    // MARK: - Chevereto (pixl.li and family: album → image pages → og:image)

    nonisolated private static func chevereto(_ link: String) async -> ([MediaItem], String?, String?) {
        // A direct image/video page.
        if firstMatch(link, "/(?:img|image|video|i)/[^/?#]+") != nil {
            if let item = await cheveretoImage(link) { return ([item], nil, nil) }
            return ([], nil, "Couldn’t read that image page.")
        }
        // An album: collect the image-page links, then resolve each.
        guard let html = await getText(link) else { return ([], nil, "Couldn’t load that album.") }
        let title = firstMatch(html, "<meta property=\"og:title\" content=\"([^\"]+)\"").map(decodeEntities)
        guard let u = URL(string: link), let scheme = u.scheme, let h = u.host else { return ([], title, "Bad link.") }
        let origin = "\(scheme)://\(h)"
        var seen = Set<String>()
        let pages = matches(html, "href=\"(https?://[^\"]*/(?:img|image|video|i)/[^\"]+)\"")
            .compactMap { $0.count > 1 ? $0[1] : nil }
            .filter { seen.insert($0).inserted }
        let targets = pages.isEmpty
            ? matches(html, "href=\"(/(?:img|image|video|i)/[^\"]+)\"").compactMap { $0.count > 1 ? origin + $0[1] : nil }.filter { seen.insert($0).inserted }
            : pages
        guard !targets.isEmpty else { return ([], title, "No images found in that album.") }
        let items = await cheveretoResolveAll(targets)
        return (items, title, items.isEmpty ? "Couldn’t resolve any images." : nil)
    }

    nonisolated private static func cheveretoResolveAll(_ pageURLs: [String]) async -> [MediaItem] {
        await withTaskGroup(of: MediaItem?.self) { group in
            var out: [MediaItem] = []
            var idx = 0
            let maxConcurrent = 8
            func addNext() {
                guard idx < pageURLs.count else { return }
                let u = pageURLs[idx]; idx += 1
                group.addTask { await cheveretoImage(u) }
            }
            for _ in 0..<min(maxConcurrent, pageURLs.count) { addNext() }
            while let r = await group.next() { if let r { out.append(r) }; addNext() }
            return out
        }
    }

    nonisolated private static func cheveretoImage(_ pageURL: String) async -> MediaItem? {
        guard let html = await getText(pageURL) else { return nil }
        var url = firstMatch(html, "<meta property=\"og:video\" content=\"([^\"]+)\"")
            ?? firstMatch(html, "<meta property=\"og:image\" content=\"([^\"]+)\"")
        // Some Chevereto skins hide the real link behind an XOR-encrypted `download=` value.
        if url == nil || url!.hasSuffix("/loading.svg"),
           let enc = firstMatch(html, "download=\"?([A-Za-z0-9+/=]{16,})") {
            url = cheveretoDecrypt(enc)
        }
        guard var real = url?.replacingOccurrences(of: "&amp;", with: "&"), real.hasPrefix("http") else { return nil }
        // Prefer the original over a resized variant (Chevereto appends .md/.th before the ext).
        real = real.replacingOccurrences(of: ".md.", with: ".").replacingOccurrences(of: ".th.", with: ".")
        let name = URL(string: real)?.lastPathComponent ?? "image"
        return MediaItem(url: real, filename: name, referer: pageURL)
    }

    nonisolated private static func cheveretoDecrypt(_ b64: String) -> String? {
        guard let data = Data(base64Encoded: b64) else { return nil }
        let key = Array("seltilovessimpcity@simpcityhatesscrapers".utf8)
        let out = data.enumerated().map { $0.element ^ key[$0.offset % key.count] }
        return String(bytes: out, encoding: .utf8)
    }

    // MARK: - Generic fallback (cyberfile / filester / unknown hosts)

    nonisolated private static func generic(_ link: String) async -> ([MediaItem], String?, String?) {
        guard let html = await getText(link) else { return ([], nil, "Couldn’t load that link.") }
        let title = firstMatch(html, "<meta property=\"og:title\" content=\"([^\"]+)\"").map(decodeEntities)
        guard let base = URL(string: link) else { return ([], title, "Bad link.") }
        var seen = Set<String>()
        var items: [MediaItem] = []
        func add(_ raw: String) {
            let s = raw.replacingOccurrences(of: "&amp;", with: "&")
            guard let abs = URL(string: s, relativeTo: base)?.absoluteString, seen.insert(abs).inserted else { return }
            let name = URL(string: abs)?.lastPathComponent ?? "file"
            items.append(MediaItem(url: abs, filename: name.isEmpty ? "file" : name, referer: link))
        }
        // og media first (usually the single-file case).
        for p in ["og:video", "og:image"] {
            if let u = firstMatch(html, "<meta property=\"\(p)\" content=\"([^\"]+)\"") { add(u) }
        }
        // Then any direct media links/sources on the page.
        let ext = "(?:jpg|jpeg|png|gif|webp|heic|mp4|mov|m4v|webm|mkv|zip)"
        for pattern in ["(?:href|src)=\"([^\"]+\\.\(ext)(?:\\?[^\"]*)?)\"",
                        "\"(https?://[^\"]+\\.\(ext)(?:\\?[^\"]*)?)\""] {
            for m in matches(html, pattern) where m.count > 1 { add(m[1]) }
        }
        return (items, title, items.isEmpty ? "No downloadable media found on that page (this host may need a dedicated resolver)." : nil)
    }

    // MARK: - Networking helpers

    nonisolated private static func getText(_ urlString: String, headers: [String: String] = [:]) async -> String? {
        guard let data = await fetch(urlString, headers: headers) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    nonisolated private static func getJSON(_ urlString: String, method: String = "GET",
                                            body: Data? = nil, headers: [String: String] = [:]) async -> Any? {
        guard let data = await fetch(urlString, method: method, body: body, headers: headers) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    nonisolated private static func fetch(_ urlString: String, method: String = "GET",
                                          body: Data? = nil, headers: [String: String] = [:]) async -> Data? {
        guard let url = URL(string: urlString) else { return nil }
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000) }
            var req = URLRequest(url: url)
            req.httpMethod = method
            req.httpBody = body
            req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            req.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
            for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
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

    nonisolated private static let regexCache = NSCache<NSString, NSRegularExpression>()
    nonisolated private static func regex(_ pattern: String) -> NSRegularExpression? {
        if let c = regexCache.object(forKey: pattern as NSString) { return c }
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        regexCache.setObject(re, forKey: pattern as NSString)
        return re
    }
    nonisolated private static func firstMatch(_ s: String, _ pattern: String) -> String? {
        guard let re = regex(pattern) else { return nil }
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges > 1 else { return nil }
        let r = m.range(at: 1)
        return r.location == NSNotFound ? nil : ns.substring(with: r)
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
    nonisolated private static func idString(_ v: Any?) -> String? {
        if let s = v as? String, !s.isEmpty { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }
    nonisolated private static func decodeEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#039;", with: "'").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// A filesystem-safe filename, keeping the extension.
    nonisolated private static func sanitize(_ name: String) -> String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let capped = String(cleaned.prefix(120))
        return capped.isEmpty ? "file" : capped
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
