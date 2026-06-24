import Foundation
import AVFoundation

/// Per-folder record for a downloaded TikTok profile (drives "Get New videos", the pinned
/// highlight bubble, and dedup). Stored on `Library`, keyed by the `@handle` folder path.
struct TTFolderInfo: Codable, Sendable {
    var handle: String
    var secUid: String                // TikTok author id (kept for future use)
    var lastUpdated: Double           // unix time of the last successful run
    var downloaded: [String]          // video ids already pulled (dedup)
    var videos: Int
}

/// Downloads a whole TikTok profile's own videos — like ssstik/snaptik, but for the entire
/// profile rather than one URL. Those tools don't scrape TikTok's web grid (which TikTok
/// caps to a screenful, virtualizes, and gates behind login); they go through a resolver API.
/// This uses the public **tikwm.com** API, which needs no login or request-signing: its
/// `user/posts` endpoint paginates the full video list and returns direct, watermark-free **HD**
/// download URLs. We page through every video, then download each at the highest quality
/// offered, stamping post date + caption.
///
/// Download-only and best-effort, like the MEGA / Instagram features: only the public handle
/// is sent to the resolver, nothing is uploaded, and because the API is unofficial and
/// rate-limited, failures are surfaced as notes rather than treated as fatal.
enum TikTokService {
    nonisolated static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
    nonisolated static let apiBase = "https://www.tikwm.com"

    struct Progress: Sendable { var phase: String; var fraction: Double; var done: Int; var total: Int }
    struct DownloadResult: Sendable {
        var videos = 0, failed = 0
        var captions: [String: String] = [:]
        var downloadedIDs: [String] = []     // ids successfully pulled this run (for dedup)
        var secUid = ""
        var nickname = ""
        var avatar: Data?
        var note: String?
    }
    private struct Video: Sendable { let id: String; let url: String; let createTime: Date; let desc: String }

    nonisolated static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpShouldSetCookies = false
        cfg.httpCookieStorage = nil
        cfg.timeoutIntervalForRequest = 60
        cfg.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: cfg)
    }()

    // MARK: - Orchestration

    /// Lists every video on `@username` (paginated) and downloads the ones not in
    /// `alreadyDownloaded` into `folder`, newest-quality first.
    nonisolated static func run(username: String, into folder: URL, alreadyDownloaded: Set<String>,
                                progress: @escaping @Sendable (Progress) -> Void) async -> DownloadResult {
        var result = DownloadResult()
        progress(Progress(phase: "Finding @\(username)’s videos…", fraction: 0, done: 0, total: 0))
        let listing = await listAllVideos(username: username, progress: progress)
        result.secUid = listing.authorId
        result.nickname = listing.nickname
        if !listing.avatar.isEmpty { result.avatar = await downloadData(absolute(listing.avatar)) }

        let pending = listing.videos.filter { !alreadyDownloaded.contains($0.id) }
        guard !pending.isEmpty else {
            result.note = listing.videos.isEmpty
                ? "Couldn’t find any videos — TikTok or the resolver may be blocking, or the handle is wrong."
                : "No new videos."
            return result
        }

        let total = pending.count
        var done = 0
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        await withTaskGroup(of: (ok: Bool, id: String, path: String, caption: String).self) { group in
            var idx = 0
            let maxConcurrent = 4
            func addNext() {
                guard idx < pending.count else { return }
                let v = pending[idx]; idx += 1
                group.addTask { await downloadOne(v, into: folder) }
            }
            for _ in 0..<min(maxConcurrent, total) { addNext() }
            while let r = await group.next() {
                if r.ok {
                    result.videos += 1
                    result.downloadedIDs.append(r.id)
                    if !r.caption.isEmpty { result.captions[r.path] = r.caption }
                } else { result.failed += 1 }
                done += 1
                progress(Progress(phase: "Downloading", fraction: Double(done) / Double(total), done: done, total: total))
                addNext()
            }
        }
        if result.videos == 0 { result.note = "Couldn’t download any videos (the resolver may be rate-limiting — try again)." }
        return result
    }

    // MARK: - Listing (tikwm user/posts, paginated)

    nonisolated private static func listAllVideos(username: String, progress: @escaping @Sendable (Progress) -> Void)
        async -> (videos: [Video], avatar: String, authorId: String, nickname: String) {
        var all: [Video] = []
        var seen = Set<String>()
        var avatar = "", authorId = "", nickname = ""
        var cursor = "0"
        // Safety cap: 60 pages × 35 ≈ 2100 videos. Stops earlier when the API says no more.
        for _ in 0..<60 {
            guard let data = await apiGet("/api/user/posts",
                                          query: ["unique_id": username, "count": "35", "cursor": cursor]),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  intValue(json["code"]) == 0,
                  let d = json["data"] as? [String: Any] else { break }
            let vids = (d["videos"] as? [[String: Any]]) ?? []
            for v in vids {
                guard let id = idString(v["video_id"]) ?? idString(v["aweme_id"]) ?? idString(v["id"]),
                      seen.insert(id).inserted else { continue }
                let url = (v["hdplay"] as? String) ?? (v["play"] as? String) ?? ""
                guard !url.isEmpty else { continue }
                let ct = Date(timeIntervalSince1970: Double(intValue(v["create_time"]) ?? 0))
                all.append(Video(id: id, url: url, createTime: ct, desc: (v["title"] as? String) ?? ""))
                if let author = v["author"] as? [String: Any] {
                    if avatar.isEmpty { avatar = (author["avatar"] as? String) ?? "" }
                    if authorId.isEmpty { authorId = idString(author["id"]) ?? "" }
                    if nickname.isEmpty { nickname = (author["nickname"] as? String) ?? "" }
                }
            }
            progress(Progress(phase: "Found \(all.count) videos…", fraction: 0, done: 0, total: 0))
            let hasMore = (d["hasMore"] as? Bool) ?? (intValue(d["hasMore"]) == 1)
            let next = idString(d["cursor"]) ?? ""
            if !hasMore || next.isEmpty || next == cursor { break }
            cursor = next
            try? await Task.sleep(nanoseconds: 1_100_000_000)     // tikwm rate-limits ~1 req/sec
        }
        return (all, avatar, authorId, nickname)
    }

    nonisolated private static func downloadOne(_ v: Video, into folder: URL) async -> (ok: Bool, id: String, path: String, caption: String) {
        let dest = folder.appendingPathComponent("\(v.id).mp4")
        if FileManager.default.fileExists(atPath: dest.path) { return (true, v.id, dest.path, v.desc) }   // already have it
        guard let url = URL(string: absolute(v.url)) else { return (false, v.id, "", "") }
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("\(apiBase)/", forHTTPHeaderField: "Referer")
        req.timeoutInterval = 180
        guard let (tmp, resp) = try? await session.download(for: req),
              (resp as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) ?? true,
              (try? FileManager.default.moveItem(at: tmp, to: dest)) != nil else { return (false, v.id, "", "") }
        await writeVideoDate(v.createTime, to: dest)                 // EXIF/QuickTime capture date (HDR preserved)
        try? FileManager.default.setAttributes([.creationDate: v.createTime, .modificationDate: v.createTime], ofItemAtPath: dest.path)
        return (true, v.id, dest.path, v.desc)
    }

    // MARK: - HTTP

    nonisolated private static func apiGet(_ path: String, query: [String: String]) async -> Data? {
        guard var comps = URLComponents(string: apiBase + path) else { return nil }
        comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 30
        return (try? await session.data(for: req))?.0
    }

    nonisolated static func downloadData(_ urlString: String) async -> Data? {
        guard !urlString.isEmpty, let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url); req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return (try? await session.data(for: req))?.0
    }

    /// tikwm sometimes returns site-relative media paths; make them absolute.
    nonisolated private static func absolute(_ u: String) -> String {
        u.hasPrefix("http") ? u : apiBase + (u.hasPrefix("/") ? u : "/" + u)
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
