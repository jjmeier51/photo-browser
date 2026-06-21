import Foundation
import AVFoundation
import WebKit

/// Per-folder record for a downloaded TikTok profile (drives "Get New videos", the
/// pinned highlight bubble, and dedup). Stored on `Library`, keyed by the `@handle`
/// folder path. Mirrors `IGFolderInfo` / `FBFolderInfo`.
struct TTFolderInfo: Codable, Sendable {
    var handle: String
    var secUid: String
    var lastUpdated: Double           // unix time of the last successful run
    var downloaded: [String]          // video ids already pulled (dedup)
    var videos: Int
}

/// Reads the logged-in TikTok session from the in-app browser's cookie store.
@MainActor
enum TikTokAuth {
    static func cookies() async -> [HTTPCookie] {
        await withCheckedContinuation { cont in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { all in
                cont.resume(returning: all.filter { $0.domain.contains("tiktok.com") })
            }
        }
    }
    static func cookieHeader() async -> String {
        await cookies().map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }
}

/// Downloads a TikTok user's own videos (not reposts) — like ssstik, but for a whole
/// profile. The profile's video list is harvested by a visible in-app web view (the
/// only reliable way past TikTok's request-signing + lazy-loaded grid); this service
/// then resolves each video's best-quality source from its page's SSR JSON, downloads
/// it (HDR preserved via passthrough), and stamps the post date + caption.
///
/// Best-effort and download-only, like the MEGA/Instagram features — TikTok changes
/// constantly and rate-limits hard, so failures are surfaced as notes.
enum TikTokService {
    nonisolated static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    struct User: Sendable { let id: String; let secUid: String; let nickname: String; let avatarURL: String }
    struct Progress: Sendable { var phase: String; var fraction: Double; var done: Int; var total: Int }
    struct DownloadResult: Sendable {
        var videos = 0, skippedReposts = 0, failed = 0
        var captions: [String: String] = [:]
        var downloadedIDs: [String] = []     // ids successfully pulled this run (for dedup)
        var secUid = ""
        var nickname = ""
        var avatar: Data?
        var note: String?
    }
    private struct VideoInfo: Sendable {
        let id: String; let authorId: String; let createTime: Date; let desc: String; let url: String
    }

    nonisolated static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpShouldSetCookies = false
        cfg.httpCookieStorage = nil
        cfg.timeoutIntervalForRequest = 60
        cfg.httpMaximumConnectionsPerHost = 5
        return URLSession(configuration: cfg)
    }()

    // MARK: - Orchestration

    /// `videoURLs` are the `/@user/video/<id>` links harvested from the profile grid.
    nonisolated static func run(username: String, videoURLs: [String], into folder: URL,
                                cookie: String, alreadyDownloaded: Set<String>,
                                progress: @escaping @Sendable (Progress) -> Void) async -> DownloadResult {
        var result = DownloadResult()
        progress(Progress(phase: "Loading @\(username)…", fraction: 0, done: 0, total: 0))
        let user = await resolveUser(username: username, cookie: cookie)
        if let user {
            result.avatar = await downloadData(user.avatarURL)
            result.secUid = user.secUid
            result.nickname = user.nickname
        }

        // De-dup by id, keeping the newest (TikTok lists newest-first, so first-seen wins).
        var seen = Set<String>()
        let ids = videoURLs.compactMap { videoID(from: $0) }
            .filter { seen.insert($0).inserted && !alreadyDownloaded.contains($0) }
        guard !ids.isEmpty else { result.note = alreadyDownloaded.isEmpty ? "No videos found on the profile." : "No new videos."; return result }

        let total = ids.count
        var done = 0
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        await withTaskGroup(of: (ok: Bool, repost: Bool, path: String, caption: String, id: String).self) { group in
            var idx = 0
            let maxConcurrent = 4
            func addNext() {
                guard idx < ids.count else { return }
                let id = ids[idx]; idx += 1
                let uid = user?.id ?? ""
                group.addTask { await fetchAndDownload(id: id, username: username, ownerId: uid, cookie: cookie, into: folder) }
            }
            for _ in 0..<min(maxConcurrent, total) { addNext() }
            while let r = await group.next() {
                if r.repost { result.skippedReposts += 1 }
                else if r.ok {
                    result.videos += 1
                    result.downloadedIDs.append(r.id)
                    if !r.caption.isEmpty { result.captions[r.path] = r.caption }
                }
                else { result.failed += 1 }
                done += 1
                progress(Progress(phase: "Downloading", fraction: Double(done) / Double(total), done: done, total: total))
                addNext()
            }
        }
        if result.videos == 0 { result.note = "Couldn’t download any videos (TikTok may be blocking or rate-limiting)." }
        return result
    }

    // MARK: - Profile + video resolution (SSR JSON)

    nonisolated static func resolveUser(username: String, cookie: String) async -> User? {
        guard let json = await fetchSSR("https://www.tiktok.com/@\(username)", cookie: cookie),
              let scope = json["__DEFAULT_SCOPE__"] as? [String: Any],
              let user = ((scope["webapp.user-detail"] as? [String: Any])?["userInfo"] as? [String: Any])?["user"] as? [String: Any]
        else { return nil }
        return User(id: idString(user["id"]) ?? "",
                    secUid: user["secUid"] as? String ?? "",
                    nickname: user["nickname"] as? String ?? username,
                    avatarURL: (user["avatarLarger"] as? String) ?? (user["avatarMedium"] as? String) ?? "")
    }

    nonisolated private static func fetchAndDownload(id: String, username: String, ownerId: String,
                                                     cookie: String, into folder: URL) async -> (ok: Bool, repost: Bool, path: String, caption: String, id: String) {
        guard let info = await videoInfo(id: id, username: username, cookie: cookie) else { return (false, false, "", "", id) }
        // Skip reposts: the item's author isn't the profile owner.
        if !ownerId.isEmpty, !info.authorId.isEmpty, info.authorId != ownerId { return (false, true, "", "", id) }

        let dest = folder.appendingPathComponent("\(id).mp4")
        if FileManager.default.fileExists(atPath: dest.path) { return (true, false, dest.path, info.desc, id) }   // already have it
        guard let vurl = URL(string: info.url) else { return (false, false, "", "", id) }
        var req = URLRequest(url: vurl)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("https://www.tiktok.com/", forHTTPHeaderField: "Referer")
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        req.timeoutInterval = 180
        guard let (tmp, resp) = try? await session.download(for: req),
              (resp as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) ?? true,
              (try? FileManager.default.moveItem(at: tmp, to: dest)) != nil else { return (false, false, "", "", id) }
        await writeVideoDate(info.createTime, to: dest)                 // EXIF/QuickTime capture date (HDR preserved)
        try? FileManager.default.setAttributes([.creationDate: info.createTime, .modificationDate: info.createTime], ofItemAtPath: dest.path)
        return (true, false, dest.path, info.desc, id)
    }

    nonisolated private static func videoInfo(id: String, username: String, cookie: String) async -> VideoInfo? {
        guard let json = await fetchSSR("https://www.tiktok.com/@\(username)/video/\(id)", cookie: cookie),
              let scope = json["__DEFAULT_SCOPE__"] as? [String: Any],
              let item = ((scope["webapp.video-detail"] as? [String: Any])?["itemInfo"] as? [String: Any])?["itemStruct"] as? [String: Any]
        else { return nil }
        let author = item["author"] as? [String: Any]
        let video = item["video"] as? [String: Any]
        guard let url = bestVideoURL(video) else { return nil }
        return VideoInfo(id: idString(item["id"]) ?? id,
                         authorId: idString(author?["id"]) ?? "",
                         createTime: Date(timeIntervalSince1970: Double(intValue(item["createTime"]) ?? 0)),
                         desc: item["desc"] as? String ?? "",
                         url: url)
    }

    /// Highest-bitrate, watermark-free source from the video's `bitrateInfo`
    /// (falls back to `playAddr`). TikTok's HDR renditions, when present, are the
    /// top bitrate, so picking max bitrate also gets HDR.
    nonisolated private static func bestVideoURL(_ video: [String: Any]?) -> String? {
        guard let video else { return nil }
        if let infos = video["bitrateInfo"] as? [[String: Any]] {
            let best = infos.max { (intValue($0["Bitrate"]) ?? 0) < (intValue($1["Bitrate"]) ?? 0) }
            if let urls = (best?["PlayAddr"] as? [String: Any])?["UrlList"] as? [String], let u = urls.first { return u }
        }
        return (video["playAddr"] as? String) ?? (video["downloadAddr"] as? String)
    }

    // MARK: - SSR fetch

    /// Fetches a TikTok page and parses its `__UNIVERSAL_DATA_FOR_REHYDRATION__` JSON.
    nonisolated private static func fetchSSR(_ urlString: String, cookie: String) async -> [String: Any]? {
        guard let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        req.timeoutInterval = 45
        guard let (data, _) = try? await session.data(for: req),
              let html = String(data: data, encoding: .utf8) else { return nil }
        // <script id="__UNIVERSAL_DATA_FOR_REHYDRATION__" type="application/json">{…}</script>
        guard let m = firstMatch(html, "__UNIVERSAL_DATA_FOR_REHYDRATION__\"[^>]*>([\\s\\S]*?)</script>"),
              let jsonData = m.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else { return nil }
        return json
    }

    nonisolated static func downloadData(_ urlString: String) async -> Data? {
        guard !urlString.isEmpty, let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url); req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return (try? await session.data(for: req))?.0
    }

    /// Sets a video's creation date via a passthrough re-mux (preserves HDR).
    nonisolated private static func writeVideoDate(_ date: Date, to url: URL) async {
        let asset = AVURLAsset(url: url)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else { return }
        var meta = (try? await asset.load(.metadata)) ?? []
        let iso = ISO8601DateFormatter().string(from: date)
        for id in [AVMetadataIdentifier.commonIdentifierCreationDate, .quickTimeMetadataCreationDate] {
            let item = AVMutableMetadataItem(); item.identifier = id; item.value = iso as NSString; meta.append(item)
        }
        export.metadata = meta
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".tttmp_" + UUID().uuidString).appendingPathExtension("mp4")
        export.outputURL = tmp; export.outputFileType = .mp4
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in export.exportAsynchronously { c.resume() } }
        guard export.status == .completed else { try? FileManager.default.removeItem(at: tmp); return }
        _ = try? FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }

    // MARK: - Helpers

    nonisolated static func videoID(from url: String) -> String? {
        firstMatch(url, "/video/(\\d+)")
    }
    nonisolated static func sanitizeHandle(_ s: String) -> String {
        var h = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = h.range(of: "tiktok.com/@") { h = String(h[r.upperBound...]) }
        h = String(h.split(separator: "/").first ?? "")
        h = String(h.split(separator: "?").first ?? "")
        return h.replacingOccurrences(of: "@", with: "")
    }
    nonisolated private static func idString(_ any: Any?) -> String? {
        if let s = any as? String { return s }
        if let n = any as? NSNumber { return n.stringValue }
        return nil
    }
    nonisolated private static func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s) }
        return nil
    }
    nonisolated private static func firstMatch(_ s: String, _ pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let m = re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)),
              m.numberOfRanges > 1 else { return nil }
        let r = m.range(at: 1)
        return r.location == NSNotFound ? nil : (s as NSString).substring(with: r)
    }
}
