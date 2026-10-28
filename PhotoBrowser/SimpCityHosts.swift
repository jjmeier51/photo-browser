import Foundation
import CryptoKit

/// The file hosts a SimpCity post links videos on — pixeldrain, gofile, cyberdrop, bunkr, filester and
/// fileditch — for the SimpCity downloader (`SimpCityService`). The Mac side is `mac/filehosts.py`; the
/// two must agree (link keys, file ids, which copy is preferred).
///
/// A post's link to one of these hosts is a **`Link`**: one file (`pixeldrain.com/u/…`, `bunkr.cr/f/…`,
/// `filester.me/d/…`, a fileditch file) or a folder (`gofile.io/d/…`, `pixeldrain.com/l/…`,
/// `cyberdrop.cr/a/…`, `bunkr.cr/a/…`, `filester.me/f/…`). `expand` turns it into the **videos** in it
/// (`Remote`s — photos, archives and the rest are left alone), with what the host says up front: the
/// name, and for most hosts the exact size (pixeldrain also the SHA-256) — how the downloader knows two
/// links are the same video before fetching either. A file's own address is asked just before its
/// download (`directURL`): cyberdrop's and bunkr's don't last.
///
/// pixeldrain, gofile (a guest account, what the site makes for every visitor, plus its rotating website
/// token), cyberdrop and bunkr are read with plain requests, like `LinkDownloadService`. filester and
/// fileditch have no public API, so their pages are read in a downloader web view (`hostPageScript`);
/// a host that answers with a "you're human?" check (`Failure.needsBrowser`) goes the same way.
/// Everything here is `nonisolated` and called from detached tasks — network and parsing stay off main.
nonisolated enum SimpCityHosts {
    static let hosts = ["pixeldrain", "gofile", "cyberdrop", "bunkr", "filester", "fileditch"]
    /// Which copy is fetched when the same video is on several hosts (lower first) — `filehosts.PREFERENCE`.
    static let preference: [String: Int] = ["pixeldrain": 0, "gofile": 1, "cyberdrop": 2, "turbo": 3,
                                            "filester": 4, "fileditch": 5, "bunkr": 6]
    static let userAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
    static let bunkrAPI = "https://apidl.bunkr.ru/api/_001_v2"
    static let gofileAPI = "https://api.gofile.io"
    static let gofileSalt = "5d4f7g8sd45fsd"

    nonisolated enum Failure: Error, CustomStringConvertible {
        /// A "you're human?" check, or no plain way in — read it in a web view.
        case needsBrowser(String)
        /// A dead link: nothing to download, nothing to try again.
        case gone(String)
        case failed(String)
        var description: String {
            switch self { case .needsBrowser(let s), .gone(let s), .failed(let s): return s }
        }
    }

    nonisolated struct Link: Sendable {
        let host: String
        /// "file" | "folder"
        let kind: String
        /// The id in the address: file id, folder id, slug — or fileditch's path.
        let ident: String
        let url: String
        var post = ""
        var posted: Double = 0
        var key: String { "\(host):\(kind):\(ident)" }
    }

    /// One video on a host.
    nonisolated struct Remote: Sendable {
        let host: String
        /// The host's id for the file (safe for a file name).
        let fid: String
        var name = ""
        /// Bytes, when the host says (0: unknown).
        var size: Int64 = 0
        var sha256 = ""
        /// The file itself, when known up front.
        var url = ""
        /// Its page — read in a web view when there's no url.
        var page = ""
        var referer = ""
        var headers: [String: String] = [:]
        /// Set in WebKit too, for its download (gofile's guest account).
        var cookies: [String: String] = [:]
        /// bunkr: "id" + "hub"; cyberdrop: "auth".
        var extra: [String: String] = [:]
        var key: String { "\(host):\(fid)" }
    }

    // MARK: - Links in posts

    private static let videoPattern = #"\.(?:mp4|mov|m4v|webm|mkv)(?:[?#]|$)"#
    private static let notVideoPattern = #"\.(?:jpe?g|png|gif|webp|heic|avif|bmp|tiff?|zip|rar|7z|pdf|txt|mp3|m4a|wav)(?:[?#]|$)"#

    static func isVideoName(_ s: String) -> Bool { groups(s, "(" + videoPattern + ")") != nil }
    /// Not known to be something else (a name without an extension may still be a video).
    static func maybeVideo(_ s: String) -> Bool { groups(s, "(" + notVideoPattern + ")") == nil }

    /// An id fit for a file name: letters, digits, `_` and `-`.
    static func safeID(_ s: String, limit: Int = 80) -> String {
        String(String(s.unicodeScalars.filter { ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || $0 == "_" || $0 == "-" })
            .prefix(limit))
    }

    /// The host link a post's address is, or nil when it isn't one (`filehosts.classify`).
    static func classify(_ raw: String) -> Link? {
        let u = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let m = groups(u, #"^https?://(?:www\.)?pixeldra(?:in)?\.[a-z]+/(u|l|api/file)/([A-Za-z0-9]{4,})"#) {
            let list = m[0].lowercased() == "l"
            return Link(host: "pixeldrain", kind: list ? "folder" : "file", ident: m[1],
                        url: "https://pixeldrain.com/\(list ? "l" : "u")/\(m[1])")
        }
        if let m = groups(u, #"^https?://(?:www\.)?gofile\.io/(?:d|w)/([A-Za-z0-9-]{4,})"#) {
            return Link(host: "gofile", kind: "folder", ident: m[0], url: "https://gofile.io/d/\(m[0])")
        }
        if let m = groups(u, #"^https?://(?:www\.)?(cyberdrop\.[a-z]+)/(a|f|e)/([A-Za-z0-9_-]{4,})"#) {
            let host = m[0].lowercased(), album = m[1].lowercased() == "a"
            return Link(host: "cyberdrop", kind: album ? "folder" : "file", ident: m[2], url: "https://\(host)/\(album ? "a" : "f")/\(m[2])")
        }
        if let m = groups(u, #"^https?://(?:www\.)?((?:[a-z0-9-]+\.)?bunkrr?\.[a-z]+)/(a|f|v|i|d)/([A-Za-z0-9_-]{4,})"#) {
            let host = m[0].lowercased(), kind = m[1].lowercased()
            // A CDN or the download hub, not a page.
            guard let first = host.split(separator: ".").first, ["bunkr", "bunkrr"].contains(String(first)) else { return nil }
            return Link(host: "bunkr", kind: kind == "a" ? "folder" : "file", ident: m[2], url: "https://\(host)/\(kind)/\(m[2])")
        }
        if let m = groups(u, #"^https?://(?:www\.)?(filester\.[a-z]+)/(d|f)/([A-Za-z0-9_-]{4,})"#) {
            let host = m[0].lowercased(), kind = m[1].lowercased()
            return Link(host: "filester", kind: kind == "f" ? "folder" : "file", ident: m[2], url: "https://\(host)/\(kind)/\(m[2])")
        }
        if groups(u, #"^https?://(?:[a-z0-9-]+\.)?(fileditch[a-z]*\.[a-z]+)(/[^#]*)$"#) != nil, let comps = URLComponents(string: u) {
            let f = comps.queryItems?.first(where: { $0.name == "f" })?.value ?? ""
            let path = f.isEmpty ? comps.path : f
            let name = path.split(separator: "/").last.map(String.init) ?? ""
            guard !name.isEmpty, !["file.php", "index.php", "upload.php"].contains(name.lowercased()),
                  maybeVideo(name) else { return nil }
            return Link(host: "fileditch", kind: "file", ident: path.trimmingCharacters(in: CharacterSet(charactersIn: "/")), url: u)
        }
        return nil
    }

    // MARK: - The videos behind a link

    /// The videos behind `link`. Throws `.gone` for a dead link, `.needsBrowser` when the host must be
    /// read in a web view (`fromPage`), `.failed` for anything else.
    static func expand(_ link: Link, ua: String = userAgent) async throws -> [Remote] {
        switch link.host {
        case "pixeldrain": return try await pixeldrain(link, ua: ua)
        case "gofile": return try await gofile(link, ua: ua)
        case "cyberdrop": return try await cyberdrop(link, ua: ua)
        case "bunkr": return try await bunkr(link, ua: ua)
        case "filester":
            guard link.kind == "file" else { throw Failure.needsBrowser("filester folders are read in the browser") }
            return [Remote(host: "filester", fid: safeID(link.ident), page: link.url, referer: link.url)]
        case "fileditch":
            let name = link.ident.split(separator: "/").last.map(String.init) ?? link.ident
            let stem = name.contains(".") ? String(name[..<name.lastIndex(of: ".")!]) : name
            let fid = safeID(stem).isEmpty ? safeID(link.ident) : safeID(stem)
            let direct = ["mp4", "mov", "m4v", "webm", "mkv"].contains((URL(string: link.url)?.pathExtension ?? "").lowercased())
            return [Remote(host: "fileditch", fid: fid, name: name, url: direct ? link.url : "",
                           page: direct ? "" : link.url, referer: direct ? "" : link.url)]
        default:
            throw Failure.failed("\(link.host) isn't a host the downloader reads")
        }
    }

    /// The file's address, asked just before its download. Throws `.needsBrowser` when only its page can
    /// say (then `hostPageScript` on `remote.page`).
    static func directURL(_ remote: Remote, ua: String = userAgent) async throws -> String {
        if !remote.url.isEmpty { return remote.url }
        if remote.host == "cyberdrop", let auth = remote.extra["auth"] {
            let j = try await json(auth, ua: ua)
            guard let url = j["url"] as? String, url.hasPrefix("http") else { throw Failure.failed("cyberdrop didn't give the file's address") }
            return url
        }
        if remote.host == "bunkr", let id = remote.extra["id"], !id.isEmpty {
            return try await bunkrFileURL(id, hub: remote.extra["hub"] ?? "https://dl.bunkr.cr", ua: ua)
        }
        throw Failure.needsBrowser("\(remote.host) shows the file only on its page")
    }

    // MARK: - Plain requests

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpShouldSetCookies = false
        cfg.httpCookieStorage = nil
        cfg.timeoutIntervalForRequest = 25
        cfg.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: cfg)
    }()

    /// (status, content type, body) — an HTTP error is an answer too.
    static func fetch(_ urlString: String, ua: String, method: String = "GET", body: Data? = nil,
                     headers: [String: String] = [:]) async throws -> (Int, String, Data) {
        guard let url = URL(string: urlString) else { throw Failure.failed("a bad address: \(urlString.prefix(80))") }
        var req = URLRequest(url: url, timeoutInterval: 25)
        req.httpMethod = method
        req.httpBody = body
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json, text/html;q=0.9, */*;q=0.8", forHTTPHeaderField: "Accept")
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        do {
            let (data, resp) = try await session.data(for: req)
            let http = resp as? HTTPURLResponse
            return (http?.statusCode ?? 0, http?.value(forHTTPHeaderField: "Content-Type") ?? "", data)
        } catch {
            throw Failure.failed("couldn't connect to \(url.host ?? "the host") (\(error.localizedDescription))")
        }
    }

    static func isCheckPage(_ text: String) -> Bool {
        groups(String(text.prefix(20000)), #"(Just a moment|DDoS-Guard|Checking your browser|Attention Required|challenge-platform|cf-turnstile)"#) != nil
    }

    static func text(_ url: String, ua: String) async throws -> String {
        let (status, _, data) = try await fetch(url, ua: ua)
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        let host = URL(string: url)?.host ?? "the host"
        if isCheckPage(text) || ([403, 429, 503].contains(status) && text.prefix(2000).lowercased().contains("<html")) {
            throw Failure.needsBrowser("\(host) answered with a check page")
        }
        if status == 404 || status == 410 { throw Failure.gone("\(url) isn't there any more") }
        if status >= 400 { throw Failure.failed("HTTP \(status) from \(host)") }
        return text
    }

    static func json(_ url: String, ua: String, method: String = "GET", body: Data? = nil,
                     headers: [String: String] = [:]) async throws -> [String: Any] {
        let (status, _, data) = try await fetch(url, ua: ua, method: method, body: body, headers: headers)
        let host = URL(string: url)?.host ?? "the host"
        guard let doc = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            if isCheckPage(String(decoding: data, as: UTF8.self)) { throw Failure.needsBrowser("\(host) answered with a check page") }
            if status == 404 || status == 410 { throw Failure.gone("\(url) isn't there any more") }
            throw Failure.failed("HTTP \(status) from \(host), not the expected answer")
        }
        let said = (doc["message"] as? String) ?? (doc["value"] as? String) ?? (doc["status"] as? String) ?? ""
        if status == 404 || status == 410 { throw Failure.gone(said.isEmpty ? "not found" : said) }
        if status >= 400 { throw Failure.failed("HTTP \(status) from \(host): \(said)") }
        return doc
    }

    /// `work` over `args`, a few at a time; the ones that fail are left out.
    private static func pool<T: Sendable>(_ args: [String], _ work: @escaping @Sendable (String) async throws -> T?) async -> [T] {
        await withTaskGroup(of: (Int, T?).self) { group in
            var out: [(Int, T)] = []
            var next = 0
            func add() {
                guard next < args.count else { return }
                let i = next, a = args[next]; next += 1
                group.addTask { (i, try? await work(a)) }
            }
            for _ in 0..<min(6, args.count) { add() }
            while let (i, r) = await group.next() {
                if let r { out.append((i, r)) }
                add()
            }
            return out.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    // MARK: - pixeldrain

    private static func pixeldrainRemote(_ f: [String: Any]) -> Remote? {
        let fid = safeID((f["id"] as? String) ?? "")
        let name = (f["name"] as? String) ?? fid
        let mime = (f["mime_type"] as? String) ?? ""
        guard !fid.isEmpty, mime.hasPrefix("video/") || isVideoName(name) else { return nil }
        return Remote(host: "pixeldrain", fid: fid, name: name, size: int64(f["size"]),
                      sha256: ((f["hash_sha256"] as? String) ?? "").lowercased(),
                      url: "https://pixeldrain.com/api/file/\(fid)?download", page: "https://pixeldrain.com/u/\(fid)",
                      referer: "https://pixeldrain.com/u/\(fid)")
    }

    private static func pixeldrain(_ link: Link, ua: String) async throws -> [Remote] {
        if link.kind == "folder" {
            let j = try await json("https://pixeldrain.com/api/list/\(link.ident)", ua: ua)
            return ((j["files"] as? [[String: Any]]) ?? []).compactMap(pixeldrainRemote)
        }
        var j = try await json("https://pixeldrain.com/api/file/\(link.ident)/info", ua: ua)
        if (j["id"] as? String)?.isEmpty ?? true { j["id"] = link.ident }
        return pixeldrainRemote(j).map { [$0] } ?? []
    }

    // MARK: - gofile

    private static let gofileLock = NSLock()
    nonisolated(unsafe) private static var gofileToken = ""
    nonisolated(unsafe) private static var gofileTokenAt = Date.distantPast

    /// `sha256(userAgent::en::accountToken::(unix time / 4 h)::salt)` — gofile's own client token.
    static func gofileWebsiteToken(ua: String, token: String, now: Date = Date()) -> String {
        let window = Int(now.timeIntervalSince1970) / 14400
        return SHA256.hash(data: Data("\(ua)::en::\(token)::\(window)::\(gofileSalt)".utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// A guest account for this run (what the site makes for every visitor), kept for an hour.
    private static func gofileGuest(ua: String) async throws -> String {
        gofileLock.lock()
        let kept = Date().timeIntervalSince(gofileTokenAt) < 3600 ? gofileToken : ""
        gofileLock.unlock()
        if !kept.isEmpty { return kept }
        let j = try await json("\(gofileAPI)/accounts", ua: ua, method: "POST", body: Data("{}".utf8),
                               headers: ["Content-Type": "application/json"])
        guard (j["status"] as? String) == "ok", let token = (j["data"] as? [String: Any])?["token"] as? String, !token.isEmpty else {
            throw Failure.failed("gofile didn't open a guest session (\((j["status"] as? String) ?? "no token"))")
        }
        gofileLock.lock(); gofileToken = token; gofileTokenAt = Date(); gofileLock.unlock()
        return token
    }

    private static func gofile(_ link: Link, ua: String) async throws -> [Remote] {
        let token = try await gofileGuest(ua: ua)
        var out: [Remote] = []
        try await gofileWalk(link.ident, token: token, ua: ua, into: &out, depth: 0)
        return out
    }

    private static func gofileWalk(_ content: String, token: String, ua: String, into out: inout [Remote], depth: Int) async throws {
        guard depth <= 5 else { return }
        let wt = gofileWebsiteToken(ua: ua, token: token)
        let id = content.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? content
        let j = try await json("\(gofileAPI)/contents/\(id)?wt=\(wt)", ua: ua,
                               headers: ["Authorization": "Bearer \(token)", "X-Website-Token": wt])
        let status = (j["status"] as? String) ?? ""
        if status == "error-notFound" { throw Failure.gone("gofile: not found") }
        guard status == "ok" else { throw Failure.failed("gofile said \(status.isEmpty ? "nothing" : status)") }
        let data = (j["data"] as? [String: Any]) ?? [:]
        let nodes: [[String: Any]] = (data["type"] as? String) == "file"
            ? [data] : ((data["children"] as? [String: Any]) ?? [:]).values.compactMap { $0 as? [String: Any] }
        for c in nodes {
            if (c["type"] as? String) == "folder", let sub = c["id"] as? String {
                try await gofileWalk(sub, token: token, ua: ua, into: &out, depth: depth + 1)
                continue
            }
            let name = (c["name"] as? String) ?? "", mime = (c["mimetype"] as? String) ?? ""
            let fid = safeID((c["id"] as? String) ?? "")
            guard !fid.isEmpty, let dl = c["link"] as? String, mime.hasPrefix("video/") || isVideoName(name) else { continue }
            out.append(Remote(host: "gofile", fid: fid, name: name, size: int64(c["size"]), url: dl,
                              page: "https://gofile.io/d/\(content)", referer: "https://gofile.io/",
                              headers: ["Cookie": "accountToken=\(token)"], cookies: ["accountToken": token]))
        }
    }

    // MARK: - cyberdrop

    private static func cyberdrop(_ link: Link, ua: String) async throws -> [Remote] {
        let host = URL(string: link.url)?.host ?? "cyberdrop.cr"
        let api = "https://api.\(host)"
        var ids = [link.ident]
        if link.kind == "folder" {
            let html = try await text(link.url, ua: ua)
            var seen = Set<String>()
            ids = allGroups(html, #"href="/f/([A-Za-z0-9_-]+)""#).filter { seen.insert($0).inserted }
            guard !ids.isEmpty else { throw Failure.needsBrowser("no files listed on the album page") }
        }
        let single = link.kind == "file"
        let info: @Sendable (String) async throws -> Remote? = { fid in
            let j = try await json("\(api)/api/file/info/\(fid)", ua: ua)
            let name = (j["name"] as? String) ?? (j["filename"] as? String) ?? fid
            let type = (j["type"] as? String) ?? ""
            guard type.hasPrefix("video/") || isVideoName(name) || (single && maybeVideo(name)) else { return nil }
            return Remote(host: "cyberdrop", fid: safeID(fid), name: name, size: int64(j["size"]),
                          page: "https://\(host)/f/\(fid)", referer: "https://\(host)/",
                          extra: ["auth": (j["auth_url"] as? String) ?? "\(api)/api/file/auth/\(fid)"])
        }
        if single { return try await info(ids[0]).map { [$0] } ?? [] }
        return await pool(ids, info)
    }

    // MARK: - bunkr

    /// `albumFiles` on a bunkr album page: [(id, name, slug, size, type)] — its keys are unquoted JS.
    static func bunkrAlbumFiles(_ html: String) -> [(id: String, name: String, slug: String, size: Int64, type: String)] {
        guard let arr = LinkDownloadService.balancedArray(in: html, after: "albumFiles") else { return [] }
        var out: [(id: String, name: String, slug: String, size: Int64, type: String)] = []
        for obj in allGroups(arr, #"(\{[^{}]*\})"#) {
            guard let id = groups(obj, #"[,{\s]["']?id["']?\s*:\s*["']?(\d+)"#)?.first else { continue }
            func s(_ key: String) -> String {
                guard let m = groups(obj, #"[,{\s]["']?"# + key + #"["']?\s*:\s*(["'])((?:(?!\1)[^\\]|\\.)*)\1"#), m.count > 1 else { return "" }
                return unescape(m[1])
            }
            let size = Int64(groups(obj, #"[,{\s]["']?size["']?\s*:\s*["']?(\d+)"#)?.first ?? "") ?? 0
            let original = s("original")
            out.append((id, original.isEmpty ? s("name") : original, s("slug"), size, s("type")))
        }
        return out
    }

    /// bunkr's file address: base64, XOR'd with `SECRET_KEY_<timestamp / 3600>`.
    static func bunkrDecrypt(_ b64: String, timestamp: Int) -> String? {
        let padded = b64 + String(repeating: "=", count: (4 - b64.count % 4) % 4)
        guard let data = Data(base64Encoded: padded) else { return nil }
        let key = Array("SECRET_KEY_\(timestamp / 3600)".utf8)
        return String(decoding: data.enumerated().map { $0.element ^ key[$0.offset % key.count] }, as: UTF8.self)
    }

    /// The file's CDN address from bunkr's download API (armed for a short while — asked just before).
    static func bunkrFileURL(_ id: String, hub: String, ua: String) async throws -> String {
        let body = try JSONSerialization.data(withJSONObject: ["id": id])
        let j = try await json(bunkrAPI, ua: ua, method: "POST", body: body,
                               headers: ["Content-Type": "application/json", "Referer": "\(hub)/file/\(id)", "Origin": hub])
        var url = (j["url"] as? String) ?? ""
        if (j["encrypted"] as? Bool) == true, !url.isEmpty {
            url = bunkrDecrypt(url, timestamp: Int(int64(j["timestamp"]))) ?? ""
        }
        guard url.hasPrefix("http") else { throw Failure.failed("bunkr didn't give the file's address") }
        if url.hasSuffix("/maint.mp4") || url.hasSuffix("/maintenance-vid.mp4") {
            throw Failure.failed("bunkr shows its maintenance clip for this file (its server is down) — try again later")
        }
        return url
    }

    private static func bunkr(_ link: Link, ua: String) async throws -> [Remote] {
        let host = URL(string: link.url)?.host ?? "bunkr.cr"
        let origin = "https://\(host)", hub = "https://dl.\(host)"
        let url = link.url
        let remote: @Sendable (String, String, String, Int64) -> Remote = { fid, slug, name, size in
            Remote(host: "bunkr", fid: safeID(slug.isEmpty ? fid : slug), name: name, size: size,
                   page: slug.isEmpty ? url : "\(origin)/f/\(slug)", referer: fid.isEmpty ? url : "\(hub)/file/\(fid)",
                   extra: fid.isEmpty ? [:] : ["id": fid, "hub": hub])
        }
        let filePage: @Sendable (String) async throws -> Remote? = { slug in
            let html = try await text("\(origin)/f/\(slug)", ua: ua)
            let fid = groups(html, #"data-file-id="(\d+)""#)?.first ?? groups(html, #""id"\s*:\s*"?(\d{4,})"#)?.first ?? ""
            let name = groups(html, #"<h1[^>]*>\s*([^<]+?)\s*</h1>"#).map { unescape($0[0]) } ?? slug
            guard maybeVideo(name) else { return nil }
            return remote(fid, slug, name, 0)
        }
        if link.kind == "file" {
            do { return try await filePage(link.ident).map { [$0] } ?? [] } catch Failure.needsBrowser(_) {
                return [Remote(host: "bunkr", fid: safeID(link.ident), page: link.url, referer: link.url)]
            }
        }
        let html = try await text(link.url + (link.url.contains("?") ? "&" : "?") + "advanced=1", ua: ua)
        let files = bunkrAlbumFiles(html)
        if !files.isEmpty {
            return files.filter { $0.type.hasPrefix("video/") || isVideoName($0.name) }
                .map { remote($0.id, $0.slug, $0.name.isEmpty ? ($0.slug.isEmpty ? $0.id : $0.slug) : $0.name, $0.size) }
        }
        var seen = Set<String>()
        let slugs = allGroups(html, #"href="(?:https?://[^"/]+)?/[fv]/([A-Za-z0-9_-]{4,})""#).filter { seen.insert($0).inserted }
        guard !slugs.isEmpty else { throw Failure.needsBrowser("no file list on the album page") }
        return await pool(slugs, filePage)
    }

    // MARK: - Read in a web view

    /// A file's id from its address, when only that is known (a file a page plays or links).
    static func fileID(host: String, url: String) -> String {
        if host == "gofile", let m = groups(url, #"/download/(?:web/)?([0-9a-fA-F-]{20,})/"#) { return safeID(m[0]) }
        if host == "pixeldrain", let m = groups(url, #"/api/file/([A-Za-z0-9]{4,})"#) { return m[0] }
        let name = URL(string: url)?.lastPathComponent ?? ""
        let stem = name.contains(".") ? String(name[..<name.lastIndex(of: ".")!]) : name
        let id = safeID(stem)
        return id.isEmpty ? String(Insecure.SHA1.hash(data: Data(url.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16)) : id
    }

    /// The videos a folder's page showed (`hostPageScript`): the files it plays or links, and the pages of
    /// the files in it (each read in a web view when its turn comes). Pages named as something other than
    /// a video (a photo, an archive) are left out.
    static func fromPage(_ link: Link, page: [String: Any]) -> [Remote] {
        var out: [Remote] = []
        var seen = Set<String>()
        let href = (page["href"] as? String) ?? link.url
        for f in (page["files"] as? [[String: Any]]) ?? [] {
            let url = (f["url"] as? String) ?? "", name = (f["name"] as? String) ?? ""
            guard url.hasPrefix("http") else { continue }
            let r = Remote(host: link.host, fid: fileID(host: link.host, url: url),
                           name: name.isEmpty ? ((URL(string: url)?.lastPathComponent) ?? "") : name, url: url, page: href, referer: href)
            if seen.insert(r.key).inserted { out.append(r) }
        }
        for p in (page["pages"] as? [[String: Any]]) ?? [] {
            let name = (p["name"] as? String) ?? ""
            guard let sub = classify((p["url"] as? String) ?? ""), sub.kind == "file", sub.host == link.host, maybeVideo(name) else { continue }
            let r: Remote
            if sub.host == "fileditch" {
                let n = sub.ident.split(separator: "/").last.map(String.init) ?? sub.ident
                let stem = n.contains(".") ? String(n[..<n.lastIndex(of: ".")!]) : n
                r = Remote(host: "fileditch", fid: safeID(stem).isEmpty ? safeID(sub.ident) : safeID(stem), name: n, page: sub.url, referer: sub.url)
            } else {
                r = Remote(host: sub.host, fid: safeID(sub.ident), name: isVideoName(name) ? name : "", page: sub.url, referer: sub.url)
            }
            if seen.insert(r.key).inserted { out.append(r) }
        }
        return out
    }

    /// The file a single file's page plays or links: (address, name).
    static func bestFile(_ page: [String: Any]) -> (url: String, name: String)? {
        for f in (page["files"] as? [[String: Any]]) ?? [] {
            if let url = f["url"] as? String, url.hasPrefix("http") {
                let name = (f["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (page["name"] as? String) ?? ""
                return (url, name)
            }
        }
        return nil
    }

    // MARK: - Page scripts (kept identical to mac/filehosts.py)

    /// What a host's page holds: the video it plays or links (`files`, best first), the pages of the files
    /// in a folder (`pages`), and its heading (`name`).
    static let hostPageScript = #"""
(() => {
  const title = document.title || '';
  const text = ((document.body && document.body.innerText) || '').slice(0, 2000);
  const checking = /Just a moment|DDoS-Guard|Checking your browser|Attention Required|Verify you are human/i.test(title)
    || !!document.querySelector('#challenge-form, #cf-challenge-running, .cf-turnstile, [data-ddg-origin]');
  const abs = (v) => { try { return new URL(v || '', location.href).href; } catch (e) { return ''; } };
  const VIDEO = /\.(mp4|mov|m4v|webm|mkv)(?:[?#]|$)/i;
  const bad = (u) => !/^https?:/i.test(u) || /\/thumbs?\/|[._-](thumb|preview|poster)[._-]|maint(enance)?(-vid)?\.mp4/i.test(u);
  const clean = (s) => (s || '').replace(/\s+/g, ' ').trim().slice(0, 200);
  const files = [];
  const seen = new Set();
  const add = (raw, name, w) => {
    const u = abs(raw);
    const n = clean(name);
    if (!u || bad(u) || seen.has(u)) return;
    if (!(w >= 100 || VIDEO.test(u) || VIDEO.test(n))) return;
    seen.add(u);
    files.push({ url: u, name: n, w: w });
  };
  try { document.querySelectorAll('video').forEach((v) => { if (v.paused && v.play) { v.muted = true; v.play().catch(() => {}); } }); } catch (e) {}
  document.querySelectorAll('video').forEach((v) => add(v.currentSrc || v.getAttribute('src'), '', 100));
  document.querySelectorAll('video source[src]').forEach((s) => add(s.getAttribute('src'), '', 100));
  try { performance.getEntriesByType('resource').forEach((e) => { if (VIDEO.test(e.name)) add(e.name, '', 95); }); } catch (e) {}
  document.querySelectorAll('a[href]').forEach((a) => {
    const h = a.getAttribute('href') || '';
    const n = a.getAttribute('download') || a.getAttribute('title') || a.textContent || '';
    if (VIDEO.test(h) || (VIDEO.test(n) && (a.hasAttribute('download') || /\/(download|dl|files?|get)\b/i.test(h)))) add(h, n, 90);
  });
  document.querySelectorAll('meta[property="og:video"], meta[property="og:video:url"], meta[property="og:video:secure_url"]')
    .forEach((m) => add(m.getAttribute('content'), '', 70));
  files.sort((a, b) => b.w - a.w);
  const here = location.href.split('#')[0];
  const pages = [];
  const seenPages = new Set([here]);
  document.querySelectorAll('a[href]').forEach((a) => {
    const u = abs(a.getAttribute('href')).split('#')[0];
    if (seenPages.has(u)) return;
    if (!/^https?:\/\/(?:[^\/]*\.)?(bunkrr?|cyberdrop|filester|pixeldra(?:in)?|fileditch[a-z]*)\.[a-z]+\/(?:f|v|i|d|u)\/[A-Za-z0-9_-]{4,}|fileditch[a-z]*\.[a-z]+\/file\.php\?/i.test(u)) return;
    seenPages.add(u);
    pages.push({ url: u, name: clean(a.getAttribute('title') || a.getAttribute('download') || a.textContent) });
  });
  const h1 = document.querySelector('h1');
  const og = document.querySelector('meta[property="og:title"]');
  const name = clean((h1 && h1.textContent) || (og && og.getAttribute('content')) || title);
  const gone = files.length === 0 && /not found|404|removed|deleted|does ?n[o']t exist|no longer available|expired/i.test(title + ' ' + text.slice(0, 600));
  return { challenge: checking && files.length === 0, files: files.slice(0, 500), pages: pages.slice(0, 1000), name: name,
           title: title, gone: gone, ready: document.readyState, href: location.href };
})()
"""#

    /// A file page that shows its file only behind a button: press the one that says "download".
    static let clickDownloadScript = #"""
(() => {
  const label = (e) => ((e.textContent || '') + ' ' + (e.value || '') + ' ' + (e.id || '') + ' '
    + (typeof e.className === 'string' ? e.className : '') + ' ' + (e.getAttribute('aria-label') || '')).toLowerCase();
  const shown = (e) => { const r = e.getBoundingClientRect(); return r.width > 0 && r.height > 0; };
  const hit = Array.from(document.querySelectorAll('a, button, [role="button"], input[type="submit"], input[type="button"]'))
    .find((e) => shown(e) && /download/.test(label(e)) && !/\bapp\b|premium|upgrade|torrent|log ?in|sign ?up|register/.test(label(e)));
  if (!hit) return { clicked: false };
  hit.click();
  return { clicked: true, label: label(hit).replace(/\s+/g, ' ').trim().slice(0, 80) };
})()
"""#

    // MARK: - Helpers

    static func int64(_ v: Any?) -> Int64 {
        if let n = v as? NSNumber { return n.int64Value }
        if let s = v as? String { return Int64(s) ?? 0 }
        return 0
    }

    private static func unescape(_ raw: String) -> String {
        var s = raw
        if s.contains("\\"), let data = "\"\(s)\"".data(using: .utf8),
           let decoded = (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)) as? String {
            s = decoded
        }
        for (k, v) in [("&amp;", "&"), ("&#039;", "'"), ("&#39;", "'"), ("&quot;", "\""), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " ")] {
            s = s.replacingOccurrences(of: k, with: v)
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func regex(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    /// The first match's groups (nil when no match).
    static func groups(_ s: String, _ pattern: String) -> [String]? {
        guard let re = regex(pattern), let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (1..<max(1, m.numberOfRanges)).map { i in Range(m.range(at: i), in: s).map { String(s[$0]) } ?? "" }
    }

    /// Group 1 of every match.
    static func allGroups(_ s: String, _ pattern: String) -> [String] {
        guard let re = regex(pattern) else { return [] }
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { m in
            m.numberOfRanges > 1 ? Range(m.range(at: 1), in: s).map { String(s[$0]) } : nil
        }
    }
}
