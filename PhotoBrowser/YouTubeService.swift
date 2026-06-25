import Foundation
import AVFoundation

/// Downloads a YouTube video into a drive folder at the highest quality the device can assemble.
///
/// YouTube serves anything above 720p as **separate** video-only + audio streams (DASH), with
/// ciphered URLs — exactly the problem yt-dlp solves. Rather than reimplement YouTube's player
/// signature/n-parameter deciphering in Swift (huge and breaks constantly), this resolves through
/// a public **Piped** API instance, which deciphers server-side and returns direct stream URLs
/// plus the title, description, and upload date. We pick the best AVFoundation-muxable rendition
/// (H.264 + AAC, typically ≤1080p), download video + audio in parallel, and mux them on-device.
/// When FFmpegKit is linked (see `VideoTranscoder`), VP9/AV1 renditions (1440p/4K) are taken too
/// and transcoded to HEVC; otherwise it caps at the best H.264 rendition.
///
/// Download-only and best-effort, like the other network features: only the public video URL is
/// sent out, nothing is uploaded, and the resolver is unofficial — failures are surfaced, not fatal.
enum YouTubeService {
    nonisolated static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
    /// Public Piped API instances, tried in order until one answers.
    nonisolated static let instances = [
        "https://pipedapi.kavin.rocks",
        "https://pipedapi.adminforge.de",
        "https://api.piped.private.coffee",
        "https://pipedapi.reallyaweso.me"
    ]

    struct Resolved: Sendable {
        let title: String
        let description: String
        let date: Date
        let videoURL: String        // video-only (mux with audioURL) or progressive (audioURL == nil)
        let audioURL: String?
        let transcode: Bool         // VP9/AV1 → needs FFmpegKit transcode to HEVC
        let quality: String         // e.g. "1080p avc1"
    }

    nonisolated static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieStorage = nil
        cfg.timeoutIntervalForRequest = 60
        cfg.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: cfg)
    }()

    // MARK: - Resolve (Piped)

    /// Resolves the best stream set for `url`, preferring renditions no taller than `maxHeight`.
    nonisolated static func resolve(url: String, maxHeight: Int) async -> Resolved? {
        guard let id = videoID(from: url) else { return nil }
        var data: Data?
        for base in instances {
            if let d = await get("\(base)/streams/\(id)") { data = d; break }
        }
        guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        let title = (json["title"] as? String) ?? "YouTube video"
        let description = stripHTML((json["description"] as? String) ?? "")
        let date = parseDate(uploadedMs: json["uploaded"], uploadDate: json["uploadDate"] as? String)

        let vstreams = (json["videoStreams"] as? [[String: Any]]) ?? []
        let astreams = (json["audioStreams"] as? [[String: Any]]) ?? []
        struct V { let url: String; let height: Int; let codec: String; let videoOnly: Bool }
        let videos: [V] = vstreams.compactMap { s in
            guard let u = s["url"] as? String, !u.isEmpty else { return nil }
            let h = (s["height"] as? Int).flatMap { $0 > 0 ? $0 : nil } ?? heightFromQuality(s["quality"] as? String)
            let codec = ((s["codec"] as? String) ?? (s["format"] as? String) ?? "").lowercased()
            return V(url: u, height: h, codec: codec, videoOnly: (s["videoOnly"] as? Bool) ?? true)
        }
        struct A { let url: String; let bitrate: Int; let codec: String }
        let audios: [A] = astreams.compactMap { s in
            guard let u = s["url"] as? String, !u.isEmpty else { return nil }
            return A(url: u, bitrate: (s["bitrate"] as? Int) ?? 0, codec: ((s["codec"] as? String) ?? (s["mimeType"] as? String) ?? "").lowercased())
        }
        let isAVC: (String) -> Bool = { $0.hasPrefix("avc") || $0.contains("avc1") || $0.contains("h264") }
        let bestAudio = audios.filter { $0.codec.contains("mp4a") || $0.codec.contains("aac") }.max { $0.bitrate < $1.bitrate }
            ?? audios.max { $0.bitrate < $1.bitrate }

        let compat = videos.filter { $0.videoOnly && isAVC($0.codec) && $0.height <= maxHeight }.max { $0.height < $1.height }

        // With a transcoder, take the tallest rendition of any codec (VP9/AV1 → HEVC).
        if VideoTranscoder.isAvailable, let audio = bestAudio {
            let anyVO = videos.filter { $0.videoOnly && $0.height <= maxHeight }.max { $0.height < $1.height }
            if let anyVO, anyVO.height > (compat?.height ?? 0) {
                return Resolved(title: title, description: description, date: date, videoURL: anyVO.url,
                                audioURL: audio.url, transcode: !isAVC(anyVO.codec), quality: "\(anyVO.height)p \(anyVO.codec)")
            }
        }
        // Best H.264 video-only + audio (AVFoundation mux).
        if let compat, let audio = bestAudio {
            return Resolved(title: title, description: description, date: date, videoURL: compat.url,
                            audioURL: audio.url, transcode: false, quality: "\(compat.height)p avc1")
        }
        // Progressive single stream (≤720p, already has audio).
        if let prog = videos.filter({ !$0.videoOnly && $0.height <= maxHeight }).max(by: { $0.height < $1.height }) {
            return Resolved(title: title, description: description, date: date, videoURL: prog.url,
                            audioURL: nil, transcode: false, quality: "\(prog.height)p progressive")
        }
        return nil
    }

    // MARK: - Download + mux

    /// Downloads `r` into `folder` (video + audio in parallel, then muxed), naming the file from the
    /// video title and stamping the upload date. Returns the final file URL, or nil on failure.
    nonisolated static func download(_ r: Resolved, into folder: URL,
                                     progress: @escaping @Sendable (String) -> Void) async -> URL? {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = sanitizeFilename(r.title)
        let dest = uniqueURL(in: folder, base: base.isEmpty ? "YouTube video" : base, ext: "mp4")

        progress("Downloading \(r.quality)…")
        async let vTask = downloadToTemp(r.videoURL)
        async let aTask = audioTemp(r.audioURL)
        let (videoTmp, audioTmp) = await (vTask, aTask)
        guard let videoTmp else { return nil }
        defer { try? FileManager.default.removeItem(at: videoTmp); if let audioTmp { try? FileManager.default.removeItem(at: audioTmp) } }

        if let audioTmp {
            progress(r.transcode ? "Transcoding…" : "Merging audio + video…")
            let ok = (r.transcode && VideoTranscoder.isAvailable)
                ? await VideoTranscoder.muxTranscode(video: videoTmp, audio: audioTmp, to: dest, transcode: true, date: r.date, lat: nil, lng: nil)
                : await mux(video: videoTmp, audio: audioTmp, to: dest, date: r.date)
            guard ok, FileManager.default.fileExists(atPath: dest.path) else { return nil }
        } else {
            // Progressive: passthrough re-mux to embed the upload date; if that fails (odd
            // container), keep the raw file so the download isn't lost.
            if !(await remuxWithDate(videoTmp, to: dest, date: r.date)) {
                try? FileManager.default.moveItem(at: videoTmp, to: dest)
            }
        }
        guard FileManager.default.fileExists(atPath: dest.path) else { return nil }
        try? FileManager.default.setAttributes([.creationDate: r.date, .modificationDate: r.date], ofItemAtPath: dest.path)
        return dest
    }

    /// AVFoundation passthrough mux of a video-only track + an audio track into an mp4.
    nonisolated private static func mux(video: URL, audio: URL, to dest: URL, date: Date) async -> Bool {
        let comp = AVMutableComposition()
        let vAsset = AVURLAsset(url: video)
        guard let vTrack = try? await vAsset.loadTracks(withMediaType: .video).first,
              let compV = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let dur = try? await vAsset.load(.duration), dur.seconds > 0 else { return false }
        try? compV.insertTimeRange(CMTimeRange(start: .zero, duration: dur), of: vTrack, at: .zero)
        if let t = try? await vTrack.load(.preferredTransform) { compV.preferredTransform = t }
        let aAsset = AVURLAsset(url: audio)
        if let aTrack = try? await aAsset.loadTracks(withMediaType: .audio).first,
           let compA = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let aDur = (try? await aAsset.load(.duration)) ?? dur
            try? compA.insertTimeRange(CMTimeRange(start: .zero, duration: CMTimeMinimum(dur, aDur)), of: aTrack, at: .zero)
        }
        return await export(comp, to: dest, date: date)
    }

    nonisolated private static func remuxWithDate(_ src: URL, to dest: URL, date: Date) async -> Bool {
        await export(AVURLAsset(url: src), to: dest, date: date)
    }

    nonisolated private static func export(_ asset: AVAsset, to dest: URL, date: Date) async -> Bool {
        try? FileManager.default.removeItem(at: dest)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else { return false }
        let iso = ISO8601DateFormatter().string(from: date)
        let creation = AVMutableMetadataItem(); creation.identifier = .commonIdentifierCreationDate; creation.value = iso as NSString
        let qt = AVMutableMetadataItem(); qt.identifier = .quickTimeMetadataCreationDate; qt.value = iso as NSString
        export.metadata = [creation, qt]
        export.outputURL = dest; export.outputFileType = .mp4
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in export.exportAsynchronously { c.resume() } }
        return export.status == .completed
    }

    // MARK: - HTTP

    nonisolated private static func get(_ urlString: String) async -> Data? {
        guard let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 30
        guard let (data, resp) = try? await session.data(for: req),
              (resp as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) ?? true else { return nil }
        return data
    }

    nonisolated private static func audioTemp(_ urlString: String?) async -> URL? {
        guard let urlString else { return nil }
        return await downloadToTemp(urlString)
    }

    nonisolated private static func downloadToTemp(_ urlString: String) async -> URL? {
        guard let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url); req.setValue(userAgent, forHTTPHeaderField: "User-Agent"); req.timeoutInterval = 600
        guard let (tmp, resp) = try? await session.download(for: req),
              (resp as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) ?? true else { return nil }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("yt_" + UUID().uuidString)
        guard (try? FileManager.default.moveItem(at: tmp, to: out)) != nil else { return nil }
        return out
    }

    // MARK: - Helpers

    /// Pulls the 11-char video id from watch / youtu.be / shorts / embed URLs (or a bare id).
    nonisolated static func videoID(from raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for pattern in ["[?&]v=([A-Za-z0-9_-]{11})", "youtu\\.be/([A-Za-z0-9_-]{11})",
                        "/shorts/([A-Za-z0-9_-]{11})", "/embed/([A-Za-z0-9_-]{11})"] {
            if let m = firstGroup(s, pattern) { return m }
        }
        if s.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil { return s }
        return nil
    }

    nonisolated private static func parseDate(uploadedMs: Any?, uploadDate: String?) -> Date {
        if let ms = (uploadedMs as? Int) ?? (uploadedMs as? NSNumber)?.intValue, ms > 0 {
            return Date(timeIntervalSince1970: Double(ms) / 1000)
        }
        if let s = uploadDate, !s.isEmpty {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
            if let d = f.date(from: String(s.prefix(10))) { return d }
        }
        return Date()
    }

    nonisolated private static func heightFromQuality(_ q: String?) -> Int {
        guard let q else { return 0 }
        // "1080p" / "1080p60" → 1080 (first run of digits).
        let digits = q.components(separatedBy: CharacterSet.decimalDigits.inverted).first { !$0.isEmpty } ?? ""
        return Int(digits) ?? 0
    }

    nonisolated private static func stripHTML(_ s: String) -> String {
        let noTags = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return noTags.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// File-safe version of a title (no path separators or reserved characters), length-bounded.
    nonisolated static func sanitizeFilename(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        let cleaned = s.components(separatedBy: bad).joined(separator: " ")
            .replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespaces)
        return String(cleaned.prefix(120))
    }

    nonisolated private static func uniqueURL(in folder: URL, base: String, ext: String) -> URL {
        var candidate = folder.appendingPathComponent("\(base).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) (\(n)).\(ext)"); n += 1
        }
        return candidate
    }

    nonisolated private static func firstGroup(_ s: String, _ pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }
}
