import Foundation
import ImageIO
import UniformTypeIdentifiers
import CoreLocation
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
/// tagged) using the user's own logged-in session, via Facebook's lightweight
/// `mbasic` HTML site (the GraphQL API needs per-session fb_dtsg/lsd tokens and is
/// heavily obfuscated). Best-effort and download-only, like the Instagram/MEGA
/// features — Facebook actively fights scraping, so HTML parsing is defensive and
/// failures are surfaced as notes. All `nonisolated`: networking + parsing + writes.
enum FacebookService {
    struct Credentials: Sendable { let cookie: String }
    struct Profile: Sendable { let id: String; let name: String; let url: String; let picURL: String }
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

    /// A photo/video page to fetch the full media + metadata from.
    private struct Ref: Sendable, Hashable { let id: String; let isVideo: Bool; let page: String }

    nonisolated static let host = "https://mbasic.facebook.com/"
    // A basic UA so Facebook serves the simple mbasic HTML rather than the JS app.
    nonisolated static let userAgent = "Mozilla/5.0 (Linux; Android 7.0; SM-G930V) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/60.0 Mobile Safari/537.36"

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
        result.profilePic = await downloadData(profile.picURL, creds: creds)

        // Collect photo/video page references from the profile's sections.
        var refs: [Ref] = []; var seen = Set<String>()
        func gather(_ list: [Ref], phase: String) {
            progress(Progress(phase: phase, fraction: 0, done: refs.count, total: 0))
            for r in list where seen.insert(r.id).inserted && !alreadyDownloaded.contains(r.id) { refs.append(r) }
        }
        gather(await collect(path: "\(profile.id)/photos", creds: creds, isVideo: false), phase: "Finding uploaded photos…")
        gather(await collect(path: "profile.php?id=\(profile.id)&v=photos", creds: creds, isVideo: false), phase: "Finding photos…")
        gather(await collect(path: "\(profile.id)/photos_of", creds: creds, isVideo: false), phase: "Finding tagged photos…")
        gather(await collect(path: "\(profile.id)/videos", creds: creds, isVideo: true), phase: "Finding videos…")

        guard !refs.isEmpty else {
            result.note = alreadyDownloaded.isEmpty
                ? "No downloadable photos or videos found (Facebook may be blocking access)."
                : "No new photos or videos."
            return result
        }

        // Fetch each item's full media + metadata, then download.
        let total = refs.count
        var done = 0
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        await withTaskGroup(of: (ok: Bool, isVideo: Bool, id: String, path: String?, caption: String).self) { group in
            var idx = 0
            let maxConcurrent = 5
            func addNext() {
                guard idx < refs.count else { return }
                let ref = refs[idx]; idx += 1
                group.addTask { await fetchAndDownload(ref, into: folder, poster: profile.name, creds: creds) }
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

    /// Resolves a profile/share URL to its mbasic id, name, and picture by following
    /// the link (share links redirect to the real profile) and parsing the page.
    nonisolated static func resolveProfile(_ profileURL: String, creds: Credentials) async -> Profile? {
        // Normalize to the mbasic host and follow redirects to the canonical URL.
        let normalized = profileURL.replacingOccurrences(of: "https://www.facebook.com/", with: host)
            .replacingOccurrences(of: "https://facebook.com/", with: host)
            .replacingOccurrences(of: "https://m.facebook.com/", with: host)
        guard let (html, finalURL) = await fetchHTML(normalized.hasPrefix("http") ? normalized : host + normalized, creds: creds) else { return nil }

        // Profile id: a numeric id in the final URL or page (profile.php?id=…, owner_id, etc.).
        let idPatterns = ["[?&]id=(\\d{5,})", "profile_id=(\\d{5,})", "owner_id=(\\d{5,})", "/(\\d{8,})(?:[/?]|$)"]
        var pid: String?
        for p in idPatterns { if let m = matches(finalURL + " " + html, p).first { pid = m[1]; break } }
        // Username fallback (vanity URL) — usable directly as an mbasic path.
        let username = vanityName(from: finalURL)
        guard let id = pid ?? username else { return nil }

        let name = decode(firstMatch(html, "<title>([^<]+)</title>")) ?? decode(firstMatch(html, "\"name\":\"([^\"]+)\"")) ?? "Facebook Profile"
        let pic = firstMatch(html, "<img[^>]+src=\"(https://[^\"]*scontent[^\"]+)\"").map(decode) ?? ""
        return Profile(id: id, name: cleanName(name), url: finalURL, picURL: pic)
    }

    nonisolated private static func vanityName(from url: String) -> String? {
        guard let comps = URLComponents(string: url), let host = comps.host, host.contains("facebook.com") else { return nil }
        let path = comps.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let first = path.split(separator: "/").first.map(String.init) ?? ""
        let reserved = ["profile.php", "photo.php", "story.php", "share", "people", "pages", "watch", ""]
        return reserved.contains(first) ? nil : first
    }

    nonisolated private static func cleanName(_ s: String) -> String {
        s.replacingOccurrences(of: " | Facebook", with: "")
            .replacingOccurrences(of: "Facebook", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Collecting media references

    /// Walks a section (uploaded/tagged/videos), following mbasic's "see more"
    /// pagination, and returns photo/video page references.
    nonisolated private static func collect(path: String, creds: Credentials, isVideo: Bool, maxPages: Int = 40) async -> [Ref] {
        var out: [Ref] = []; var seen = Set<String>()
        var next: String? = path
        var pages = 0
        while let p = next, pages < maxPages {
            pages += 1
            guard let (html, _) = await fetchHTML(p.hasPrefix("http") ? p : host + p, creds: creds) else { break }
            // Photo pages: photo.php?fbid=… or /photo/?fbid=…  Video pages: /…/videos/…
            let pat = isVideo ? "href=\"(/[^\"]*?/videos/(\\d+)[^\"]*)\"" : "href=\"(/photo\\.php\\?[^\"]*fbid=(\\d+)[^\"]*)\""
            for g in matches(html, pat) {
                let id = g[2]
                guard seen.insert(id).inserted else { continue }
                out.append(Ref(id: id, isVideo: isVideo, page: decode(g[1])))
            }
            // Pagination: an anchor whose text is "See more" / "Show more" or a cursor link.
            next = firstMatch(html, "href=\"(/[^\"]*(?:cursor|more|pages/?)[^\"]*)\"[^>]*>\\s*(?:See [Mm]ore|Show more|More)")
                ?? firstMatch(html, "href=\"([^\"]*&cursor=[^\"]+)\"")
            if let n = next, seen.contains(n) { break } else if let n = next { seen.insert(n) }
        }
        return out
    }

    // MARK: - Per-item fetch + download

    nonisolated private static func fetchAndDownload(_ ref: Ref, into folder: URL, poster: String,
                                                     creds: Credentials) async -> (ok: Bool, isVideo: Bool, id: String, path: String?, caption: String) {
        guard let (html, _) = await fetchHTML(ref.page.hasPrefix("http") ? ref.page : host + ref.page, creds: creds) else {
            return (false, ref.isVideo, ref.id, nil, "")
        }
        // Highest-quality media URL: the "View full size" link for photos, the source
        // for videos. Several fallbacks because mbasic markup varies.
        let mediaURL: String?
        if ref.isVideo {
            mediaURL = firstMatch(html, "<source[^>]+src=\"([^\"]+)\"").map(decode)
                ?? firstMatch(html, "href=\"(https://[^\"]+\\.mp4[^\"]*)\"").map(decode)
        } else {
            mediaURL = firstMatch(html, "href=\"(https://[^\"]*scontent[^\"]+)\"[^>]*>\\s*View full size").map(decode)
                ?? firstMatch(html, "<a[^>]+href=\"(https://[^\"]*scontent[^\"]+\\.(?:jpg|jpeg|png|webp)[^\"]*)\"").map(decode)
                ?? firstMatch(html, "<img[^>]+src=\"(https://[^\"]*scontent[^\"]+)\"").map(decode)
        }
        guard let urlString = mediaURL, let data = await downloadData(urlString, creds: creds), data.count >= 512 else {
            return (false, ref.isVideo, ref.id, nil, "")
        }
        let caption = decode(firstMatch(html, "<div[^>]*>([^<]{3,400})</div>\\s*</div>\\s*<[^>]*>\\s*(?:Like|Comment)") ?? "")
        let date = parsePostDate(html)
        let coord = parsePlace(html)

        let ext = ref.isVideo ? "mp4" : "jpg"
        let dest = uniqueDestination("FB_\(ref.id).\(ext)", in: folder)
        guard (try? data.write(to: dest, options: .atomic)) != nil else { return (false, ref.isVideo, ref.id, nil, "") }
        if ref.isVideo {
            setFileDate(dest, date)
        } else {
            writeImageMeta(date: date, caption: caption, poster: poster, lat: coord?.lat, lng: coord?.lng, to: dest)
            setFileDate(dest, date)
        }
        return (true, ref.isVideo, ref.id, dest.path, caption)
    }

    /// Post date: an absolute date in the page, else nil (so the caller keeps EXIF /
    /// sets the file date). mbasic shows dates like "June 5, 2026" or "5 June 2026".
    nonisolated private static func parsePostDate(_ html: String) -> Date? {
        let text = stripTags(html)
        let formats = ["MMMM d, yyyy", "d MMMM yyyy", "MMM d, yyyy", "yyyy-MM-dd"]
        for pat in ["([A-Z][a-z]+ \\d{1,2}, \\d{4})", "(\\d{1,2} [A-Z][a-z]+ \\d{4})", "(\\d{4}-\\d{2}-\\d{2})"] {
            for g in matches(text, pat) {
                for fmt in formats {
                    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = fmt
                    if let d = f.date(from: g[1]) { return d }
                }
            }
        }
        return nil
    }

    nonisolated private static func parsePlace(_ html: String) -> (lat: Double, lng: Double)? { nil }   // best-effort: not in mbasic

    // MARK: - Metadata writing

    nonisolated private static func writeImageMeta(date: Date?, caption: String, poster: String,
                                                   lat: Double?, lng: Double?, to url: URL) {
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
        if let lat, let lng {
            props[kCGImagePropertyGPSDictionary] = [
                kCGImagePropertyGPSLatitude: abs(lat), kCGImagePropertyGPSLatitudeRef: lat >= 0 ? "N" : "S",
                kCGImagePropertyGPSLongitude: abs(lng), kCGImagePropertyGPSLongitudeRef: lng >= 0 ? "E" : "W"
            ] as [CFString: Any]
        }
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

    nonisolated private static func fetchHTML(_ urlString: String, creds: Credentials) async -> (html: String, finalURL: String)? {
        guard let url = URL(string: urlString) else { return nil }
        guard let (data, resp) = try? await session.data(for: request(url, creds: creds, html: true)),
              let s = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }
        return (s, resp.url?.absoluteString ?? urlString)
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
    nonisolated private static func stripTags(_ s: String) -> String {
        (try? NSRegularExpression(pattern: "<[^>]+>"))
            .map { $0.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: " ") } ?? s
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
