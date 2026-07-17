import Foundation
import ImageIO
import AVFoundation

/// Downloads a video discovered in the in-app web browser (`WebBrowserView`) to a folder.
///
/// Two shapes are handled, like Aloha's downloader:
/// * **Direct files** (`.mp4`/`.m4v`/`.mov`/`.webm`) — a single authenticated `URLSession`
///   download, streamed to disk.
/// * **HLS** (`.m3u8`) — fetch the playlist, pick the highest-bitrate variant, download every
///   segment (bounded-concurrent, in order), decrypt AES-128 segments on the fly (CommonCrypto),
///   and concatenate: an fMP4/CMAF stream (has an `EXT-X-MAP` init) merges into a clean `.mp4`;
///   an MPEG-TS stream is concatenated to `.ts`. If FFmpegKit happens to be linked
///   (`VideoTranscoder`), the TS result is remuxed to a faststart `.mp4`.
///
/// All requests carry the browser's cookies + a real UA + the page as `Referer`, so hotlink-/
/// login-gated media downloads the same way it played. `nonisolated` throughout — network,
/// crypto and large file writes stay off the main actor. Best-effort: DRM (Widevine/FairPlay)
/// and pure-MSE `blob:` streams with no discoverable manifest can't be captured, and that's
/// surfaced as a note rather than a crash.
enum WebVideoDownloader {
    struct Progress: Sendable { var fraction: Double; var phase: String }
    /// `authRequired` means the server returned 401 and we sent no credentials — the caller should
    /// prompt for a username/password and retry. The associated value is the host to sign in to.
    enum Outcome: Sendable { case saved(URL); case failed(String); case authRequired(String) }

    nonisolated static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    nonisolated static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpShouldSetCookies = false
        cfg.httpCookieStorage = nil
        cfg.timeoutIntervalForRequest = 60
        cfg.httpMaximumConnectionsPerHost = 8
        return URLSession(configuration: cfg)
    }()

    // MARK: - Entry point

    /// Downloads `urlString` (a direct media URL or an `.m3u8`) into `folder`. `pageURL` becomes
    /// the Referer; `cookieHeader` is the browser's cookies for the media host.
    nonisolated static func download(urlString: String, pageURL: String, cookieHeader: String,
                                     into folder: URL, suggestedName: String?, authHeader: String? = nil,
                                     captureDate: Date? = nil, caption: String? = nil,
                                     progress: @escaping @Sendable (Progress) -> Void) async -> Outcome {
        // Loom serves the page player a per-track ("…-video…") HLS playlist with no audio. Its
        // session API hands back a pre-merged URL (progressive MP4 or muxed HLS) that includes
        // audio — the same source yt-dlp uses. Resolve that first; fall back to the captured URL.
        var effectiveURL = urlString
        if let id = loomVideoID(pageURL) ?? loomVideoID(urlString) {
            progress(Progress(fraction: 0, phase: "Resolving Loom video…"))
            if let resolved = await resolveLoomURL(id: id, referer: pageURL, cookieHeader: cookieHeader) { effectiveURL = resolved }
        }
        guard let url = URL(string: effectiveURL) else { return .failed("That video URL couldn’t be read.") }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let outcome: Outcome
        if isHLS(url) {
            outcome = await downloadHLS(url, pageURL: pageURL, cookieHeader: cookieHeader, authHeader: authHeader,
                                        into: folder, suggestedName: suggestedName, progress: progress)
        } else {
            outcome = await downloadDirect(url, pageURL: pageURL, cookieHeader: cookieHeader, authHeader: authHeader,
                                           into: folder, suggestedName: suggestedName, progress: progress)
        }
        // Stamp the page-provided date/caption off the main actor (a video re-mux / image rewrite
        // here would freeze the UI if it ran on the main thread).
        if case .saved(let dest) = outcome, captureDate != nil || caption != nil {
            progress(Progress(fraction: 1, phase: "Setting date…"))
            await stampMetadata(date: captureDate, caption: caption, to: dest)
        }
        return outcome
    }

    nonisolated static func isHLS(_ url: URL) -> Bool {
        let s = url.absoluteString.lowercased()
        return url.pathExtension.lowercased() == "m3u8" || s.contains(".m3u8")
    }

    // MARK: - Loom

    /// The 32-hex session id from a Loom URL (loom.com/id|share|embed/<id>, luna.loom.com/id/<id>).
    nonisolated private static func loomVideoID(_ s: String) -> String? {
        guard s.lowercased().contains("loom.com") else { return nil }
        return firstMatch(s, "loom\\.com/(?:id|share|embed)/([0-9a-fA-F]{32})")?.lowercased()
    }

    /// Asks Loom's session URL API for a pre-merged, signed media URL (progressive MP4 or muxed
    /// HLS) that includes audio, instead of the per-track "…-video…" playlist the page player
    /// requests. Tries the transcoded URL, then the raw URL; returns nil if neither responds, in
    /// which case the caller keeps the captured URL. Same anonymous API yt-dlp uses; the browser's
    /// cookies are forwarded in case the video is team-restricted.
    nonisolated private static func resolveLoomURL(id: String, referer: String, cookieHeader: String) async -> String? {
        for endpoint in ["transcoded-url", "raw-url"] {
            guard let api = URL(string: "https://www.loom.com/api/campaigns/sessions/\(id)/\(endpoint)") else { continue }
            var req = URLRequest(url: api)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            if !referer.isEmpty { req.setValue(referer, forHTTPHeaderField: "Referer") }
            if !cookieHeader.isEmpty { req.setValue(cookieHeader, forHTTPHeaderField: "Cookie") }
            let body: [String: Any] = ["anonID": UUID().uuidString, "deviceID": NSNull(),
                                       "force_original": false, "password": NSNull()]
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            guard let (data, resp) = try? await session.data(for: req),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  var out = json["url"] as? String, !out.isEmpty else { continue }
            // Loom's split (demuxed) HLS has a pre-merged twin: dropping "-split" yields a muxed
            // playlist whose segments already carry audio — no separate audio track to fetch/mux.
            if out.contains("-split.m3u8") { out = out.replacingOccurrences(of: "-split.m3u8", with: ".m3u8") }
            return out
        }
        return nil
    }

    // MARK: - Direct file

    nonisolated private static func downloadDirect(_ url: URL, pageURL: String, cookieHeader: String,
                                                   authHeader: String?, into folder: URL, suggestedName: String?,
                                                   progress: @escaping @Sendable (Progress) -> Void) async -> Outcome {
        progress(Progress(fraction: 0, phase: "Downloading video…"))
        guard let (tmp, resp) = await downloadToTemp(url, referer: pageURL, cookieHeader: cookieHeader, authHeader: authHeader,
                                                     progress: { f in progress(Progress(fraction: f, phase: "Downloading video…")) }) else {
            return .failed("The download failed (the video may be protected or the link expired).")
        }
        if let code = (resp as? HTTPURLResponse)?.statusCode, code >= 400 {
            try? FileManager.default.removeItem(at: tmp)
            if code == 401, authHeader == nil { return .authRequired(url.host ?? "") }
            if code == 401 || code == 403 {
                return .failed("The server refused the download (HTTP \(code)). The saved login may be wrong or expired — sign in through the browser again.")
            }
            return .failed("The server refused the download (HTTP \(code)).")
        }
        let ext = magicExtension(forFileAt: tmp) ?? fileExtension(url: url, response: resp, fallback: "mp4")
        let dest = uniqueDestination(name: baseName(suggestedName, url: url, ext: ext), in: folder)
        do {
            try await DriveWriter.shared.commit(tmp, to: dest)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            return .failed("Couldn’t save to the folder.")
        }
        stampNow(dest)
        progress(Progress(fraction: 1, phase: "Saved"))
        return .saved(dest)
    }

    // MARK: - Arbitrary file (zip, pdf, image, apk, …)

    /// Downloads any non-streaming file discovered in the browser — a link the user long-pressed,
    /// or a response the web view can't render inline (a `Content-Disposition: attachment`). Unlike
    /// the video path there's no HLS/segment handling: a single authenticated GET streamed to disk,
    /// keeping the server-suggested filename + extension. Carries cookies / Referer / Basic-Auth so
    /// members-only downloads work the same way the page did.
    nonisolated static func downloadFile(urlString: String, pageURL: String, cookieHeader: String,
                                         authHeader: String? = nil, into folder: URL, suggestedName: String?,
                                         captureDate: Date? = nil, caption: String? = nil,
                                         progress: @escaping @Sendable (Progress) -> Void) async -> Outcome {
        guard let url = URL(string: urlString) else { return .failed("That link couldn’t be read.") }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        progress(Progress(fraction: 0, phase: "Downloading file…"))
        guard let (tmp, resp) = await downloadToTemp(url, referer: pageURL, cookieHeader: cookieHeader, authHeader: authHeader,
                                                     progress: { f in progress(Progress(fraction: f, phase: "Downloading file…")) }) else {
            return .failed("The download failed (the link may be protected or expired).")
        }
        if let code = (resp as? HTTPURLResponse)?.statusCode, code >= 400 {
            try? FileManager.default.removeItem(at: tmp)
            if code == 401, authHeader == nil { return .authRequired(url.host ?? "") }
            if code == 401 || code == 403 {
                return .failed("The server refused the download (HTTP \(code)). The saved login may be wrong or expired — sign in through the browser again.")
            }
            return .failed("The server refused the download (HTTP \(code)).")
        }
        let sniffed = magicExtension(forFileAt: tmp)   // trust the actual bytes for the extension
        let dest = uniqueDestination(name: fileName(suggested: suggestedName, url: url, response: resp, sniffedExt: sniffed), in: folder)
        do {
            try await DriveWriter.shared.commit(tmp, to: dest)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            return .failed("Couldn’t save to the folder.")
        }
        // The bytes are copied verbatim, so any embedded EXIF/metadata is already intact. If the page
        // gave us a date/caption, write those (real EXIF for images); otherwise set the file's own date
        // from its EXIF so Age/date are correct rather than showing the download time.
        if captureDate != nil || caption != nil {
            progress(Progress(fraction: 1, phase: "Setting date…"))
            await stampMetadata(date: captureDate, caption: caption, to: dest)
        } else {
            stampFromMetadata(dest)
        }
        progress(Progress(fraction: 1, phase: "Saved"))
        return .saved(dest)
    }

    // MARK: - HLS

    nonisolated private static func downloadHLS(_ manifestURL: URL, pageURL: String, cookieHeader: String,
                                                authHeader: String?, into folder: URL, suggestedName: String?,
                                                progress: @escaping @Sendable (Progress) -> Void) async -> Outcome {
        progress(Progress(fraction: 0, phase: "Reading stream…"))
        guard var text = await fetchText(manifestURL, referer: pageURL, cookieHeader: cookieHeader, authHeader: authHeader) else {
            return .failed("Couldn’t read the video stream (m3u8).")
        }
        var playlistURL = manifestURL
        var masterText: String?          // kept so demuxed audio can be found from the master
        var masterURL: URL?
        // Master playlist → pick the highest-bandwidth variant, then fetch it.
        if text.contains("#EXT-X-STREAM-INF") {
            masterText = text; masterURL = manifestURL
            guard let variant = bestVariant(text, base: manifestURL),
                  let vtext = await fetchText(variant, referer: pageURL, cookieHeader: cookieHeader, authHeader: authHeader) else {
                return .failed("Couldn’t read the stream’s quality list.")
            }
            playlistURL = variant; text = vtext
        }

        // Download the (video, or muxed audio+video) media playlist.
        let vres = await downloadMediaPlaylist(playlistURL, text: text, pageURL: pageURL, cookieHeader: cookieHeader,
                                               authHeader: authHeader, label: "video", progress: progress)
        guard let videoInfo = vres.data else { return .failed(vres.reason ?? "Couldn’t download the video.") }

        // Demuxed streams (Loom, and most CMAF HLS) carry audio as a SEPARATE rendition, so the
        // video playlist alone is silent. Find the audio playlist — from the master we already read,
        // or by probing for one next to a "…video…" media playlist — download it, and mux it in.
        var audioTmp: URL?
        if let audioURL = await findAudioPlaylistURL(videoPlaylistURL: playlistURL, masterText: masterText,
                                                     masterURL: masterURL, pageURL: pageURL,
                                                     cookieHeader: cookieHeader, authHeader: authHeader),
           let atext = await fetchText(audioURL, referer: pageURL, cookieHeader: cookieHeader, authHeader: authHeader),
           let a = await downloadMediaPlaylist(audioURL, text: atext, pageURL: pageURL,
                                               cookieHeader: cookieHeader, authHeader: authHeader,
                                               label: "audio", progress: progress).data {
            audioTmp = a.url
        }

        progress(Progress(fraction: 1, phase: "Assembling…"))
        var finalTmp = videoInfo.url
        var finalExt = videoInfo.isFMP4 ? "mp4" : "ts"

        // Mux the separate audio track into the video (no re-encode). On failure, keep video-only
        // rather than losing the whole download.
        if let audioTmp {
            let muxed = FileManager.default.temporaryDirectory.appendingPathComponent("webvid_\(UUID().uuidString).mp4")
            if await muxVideoAudio(video: videoInfo.url, audio: audioTmp, to: muxed) {
                try? FileManager.default.removeItem(at: videoInfo.url)
                finalTmp = muxed; finalExt = "mp4"
            }
            try? FileManager.default.removeItem(at: audioTmp)
        }

        // If TS and FFmpegKit is available, remux to a clean faststart MP4; otherwise keep .ts.
        if finalExt == "ts", VideoTranscoder.isAvailable {
            let mp4 = finalTmp.deletingPathExtension().appendingPathExtension("mp4")
            if await VideoTranscoder.muxTranscode(video: finalTmp, audio: nil, to: mp4, transcode: false, date: Date(), lat: nil, lng: nil) {
                try? FileManager.default.removeItem(at: finalTmp); finalTmp = mp4; finalExt = "mp4"
            }
        }
        let dest = uniqueDestination(name: baseName(suggestedName, url: manifestURL, ext: finalExt), in: folder)
        do {
            try await DriveWriter.shared.commit(finalTmp, to: dest)
        } catch {
            try? FileManager.default.removeItem(at: finalTmp)
            return .failed("Couldn’t save to the folder.")
        }
        stampNow(dest)
        return .saved(dest)
    }

    /// Downloads every segment of ONE media playlist and assembles them into a single temp file
    /// (fMP4 → `.mp4`, MPEG-TS → `.ts`). Handles AES-128 decryption, the fMP4 init segment, and the
    /// refetch-on-failure retry (signed segment URLs expire / drop). Reused for the video and, on a
    /// demuxed stream, the separate audio rendition. Returns the file (+ whether it's fMP4) or a reason.
    nonisolated private static func downloadMediaPlaylist(_ playlistURL: URL, text: String, pageURL: String,
                                                          cookieHeader: String, authHeader: String?, label: String,
                                                          progress: @escaping @Sendable (Progress) -> Void) async -> (data: (url: URL, isFMP4: Bool)?, reason: String?) {
        let segs = parseSegments(text, base: playlistURL)
        guard !segs.isEmpty else { return (nil, "The stream had no downloadable \(label) segments.") }
        let key = await resolveKey(text, base: playlistURL, referer: pageURL, cookieHeader: cookieHeader, authHeader: authHeader)
        if key == nil, text.contains("#EXT-X-KEY"), !text.uppercased().contains("METHOD=NONE") {
            return (nil, "This video is encrypted in a way that can’t be saved (DRM-protected).")
        }
        let initSeg = parseInitSegment(text, base: playlistURL)     // fMP4/CMAF init
        let isFMP4 = initSeg != nil || segs.first?.url.pathExtension.lowercased() == "m4s"

        // Bounded-concurrent, order-preserving download. On a flaky network — or a stream whose
        // segment URLs carry short-lived signed tokens — some segments fail even after per-request
        // retries; refetch the playlist (fresh, re-signed URLs) and retry only the still-missing ones.
        var datas = [Data?](repeating: nil, count: segs.count)
        var currentSegs = segs
        let total = segs.count
        var refreshes = 0
        var lastReason: String?
        while true {
            let missing = datas.indices.filter { datas[$0] == nil }
            if missing.isEmpty { break }
            var done = total - missing.count
            let lock = NSLock()
            await withTaskGroup(of: (Int, Data?, String?).self) { group in
                var k = 0
                let maxConcurrent = 6
                func addNext() {
                    guard k < missing.count else { return }
                    let i = missing[k]; let seg = currentSegs[i]; k += 1
                    group.addTask {
                        let r = await fetchSegmentData(seg.url, referer: pageURL, cookieHeader: cookieHeader, authHeader: authHeader)
                        guard var d = r.data else { return (i, nil, r.reason) }
                        if let key { d = aesCBCDecrypt(d, key: key.key, iv: seg.iv ?? key.iv(forSequence: i)) ?? d }
                        return (i, d, nil)
                    }
                }
                for _ in 0..<min(maxConcurrent, missing.count) { addNext() }
                while let (i, d, reason) = await group.next() {
                    if let d { datas[i] = d } else if let reason { lastReason = reason }
                    lock.lock(); done += 1; let dn = done; lock.unlock()
                    if dn % 3 == 0 || dn == total {
                        progress(Progress(fraction: Double(dn) / Double(total), phase: "Downloading \(label) \(dn)/\(total)…"))
                    }
                    addNext()
                }
            }
            if datas.allSatisfy({ $0 != nil }) { break }
            refreshes += 1
            if refreshes > 2 { break }
            progress(Progress(fraction: Double(total - missing.count) / Double(total), phase: "Refreshing stream…"))
            guard let refreshed = await fetchText(playlistURL, referer: pageURL, cookieHeader: cookieHeader, authHeader: authHeader) else { break }
            let newSegs = parseSegments(refreshed, base: playlistURL)
            guard newSegs.count == total else { break }
            currentSegs = newSegs
        }
        if !datas.allSatisfy({ $0 != nil }) {
            let failed = datas.filter { $0 == nil }.count
            let detail = lastReason.map { " — \($0)" } ?? ""
            return (nil, "Couldn’t download \(failed) of \(total) \(label) segments\(detail). The stream may have expired or blocked the request.")
        }

        let ext = isFMP4 ? "mp4" : "ts"
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("webvid_\(UUID().uuidString).\(ext)")
        guard let handle = createFile(tmp) else { return (nil, "Couldn’t assemble the \(label) file.") }
        if let initSeg, let initData = await fetchData(initSeg, referer: pageURL, cookieHeader: cookieHeader, authHeader: authHeader) {
            try? handle.write(contentsOf: initData)
        }
        for d in datas { if let d { try? handle.write(contentsOf: d) } }
        try? handle.close()
        return ((tmp, isFMP4), nil)
    }

    /// Locates the audio media playlist for a demuxed stream. Preferred source is a master playlist
    /// we already read (its `#EXT-X-MEDIA:TYPE=AUDIO` line); otherwise, when we were handed a
    /// "…video…" media playlist directly (Loom), probe the usual master names alongside it. Returns
    /// nil for a normal muxed stream (audio already lives inside the video segments).
    nonisolated private static func findAudioPlaylistURL(videoPlaylistURL: URL, masterText: String?, masterURL: URL?,
                                                         pageURL: String, cookieHeader: String, authHeader: String?) async -> URL? {
        if let masterText, let masterURL, let u = audioMediaURI(masterText, base: masterURL) { return u }
        guard videoPlaylistURL.lastPathComponent.lowercased().contains("video") else { return nil }
        // Loom's master sits beside the media playlists (…/resource/hls/); names vary, so try the
        // common ones. Each is validated by `audioMediaURI` (only a real master with an AUDIO
        // rendition returns a URL), so a wrong guess that turns out to be a media playlist is ignored.
        for name in ["multivariantplaylist.m3u8", "playlist.m3u8", "master.m3u8", "index.m3u8"] {
            guard let cand = resolve(name, base: videoPlaylistURL),
                  let mtext = await fetchText(cand, referer: pageURL, cookieHeader: cookieHeader, authHeader: authHeader) else { continue }
            if let u = audioMediaURI(mtext, base: cand) { return u }
        }
        return nil
    }

    /// The audio rendition's playlist URL from a master's `#EXT-X-MEDIA:TYPE=AUDIO` entries (the
    /// DEFAULT=YES one if present, else the first).
    nonisolated private static func audioMediaURI(_ master: String, base: URL) -> URL? {
        var first: URL?
        for line in master.components(separatedBy: .newlines)
            where line.hasPrefix("#EXT-X-MEDIA") && line.uppercased().contains("TYPE=AUDIO") {
            guard let uri = firstMatch(line, "URI=\"([^\"]+)\""), let u = resolve(uri, base: base) else { continue }
            if line.uppercased().contains("DEFAULT=YES") { return u }
            if first == nil { first = u }
        }
        return first
    }

    /// Combines a video-only file and an audio-only file into one `.mp4` without re-encoding
    /// (passthrough), preserving the video's orientation. Returns false if the mux fails (caller
    /// then keeps the video-only result).
    nonisolated private static func muxVideoAudio(video: URL, audio: URL, to out: URL) async -> Bool {
        let comp = AVMutableComposition()
        let vAsset = AVURLAsset(url: video)
        guard let vTrack = try? await vAsset.loadTracks(withMediaType: .video).first,
              let vComp = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { return false }
        let vDur = (try? await vAsset.load(.duration)) ?? .zero
        guard vDur > .zero else { return false }
        do { try vComp.insertTimeRange(CMTimeRange(start: .zero, duration: vDur), of: vTrack, at: .zero) }
        catch { return false }
        if let t = try? await vTrack.load(.preferredTransform) { vComp.preferredTransform = t }

        let aAsset = AVURLAsset(url: audio)
        if let aTrack = try? await aAsset.loadTracks(withMediaType: .audio).first,
           let aComp = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let aRange = (try? await aTrack.load(.timeRange)) ?? CMTimeRange(start: .zero, duration: vDur)
            try? aComp.insertTimeRange(aRange, of: aTrack, at: .zero)
        }
        guard let export = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough) else { return false }
        export.outputURL = out
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in export.exportAsynchronously { c.resume() } }
        return export.status == .completed
    }

    // MARK: - Playlist parsing

    private struct Segment { let url: URL; let iv: Data? }
    private struct HLSKey { let key: Data; let baseIV: Data?
        /// Per-segment IV when the playlist doesn't pin one: the media sequence number, big-endian.
        func iv(forSequence n: Int) -> Data {
            if let baseIV { return baseIV }
            var iv = Data(count: 16)
            var v = UInt64(n).bigEndian
            withUnsafeBytes(of: &v) { iv.replaceSubrange(8..<16, with: $0) }
            return iv
        }
    }

    nonisolated private static func bestVariant(_ master: String, base: URL) -> URL? {
        var best: (Int, URL)?
        let lines = master.components(separatedBy: .newlines)
        for (i, line) in lines.enumerated() where line.hasPrefix("#EXT-X-STREAM-INF") {
            let bw = Int(firstMatch(line, "BANDWIDTH=(\\d+)") ?? "0") ?? 0
            // The URI is the next non-comment line.
            var j = i + 1
            while j < lines.count, lines[j].trimmingCharacters(in: .whitespaces).hasPrefix("#") { j += 1 }
            guard j < lines.count else { continue }
            let uri = lines[j].trimmingCharacters(in: .whitespaces)
            guard !uri.isEmpty, let u = resolve(uri, base: base) else { continue }
            if best == nil || bw > best!.0 { best = (bw, u) }
        }
        return best?.1
    }

    nonisolated private static func parseSegments(_ playlist: String, base: URL) -> [Segment] {
        var out: [Segment] = []
        var currentIV: Data?
        for raw in playlist.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-KEY") {
                if let ivHex = firstMatch(line, "IV=0x([0-9A-Fa-f]+)") { currentIV = hexData(ivHex) }
                else { currentIV = nil }
                continue
            }
            if line.isEmpty || line.hasPrefix("#") { continue }
            if let u = resolve(line, base: base) { out.append(Segment(url: u, iv: currentIV)) }
        }
        return out
    }

    nonisolated private static func parseInitSegment(_ playlist: String, base: URL) -> URL? {
        for raw in playlist.components(separatedBy: .newlines) where raw.contains("#EXT-X-MAP") {
            if let uri = firstMatch(raw, "URI=\"([^\"]+)\"") { return resolve(uri, base: base) }
        }
        return nil
    }

    /// The AES-128 content key (+ optional pinned IV) for an encrypted playlist, or nil if the
    /// stream is unencrypted (METHOD=NONE) or uses an unsupported method (SAMPLE-AES / DRM).
    nonisolated private static func resolveKey(_ playlist: String, base: URL, referer: String, cookieHeader: String, authHeader: String?) async -> HLSKey? {
        guard let line = playlist.components(separatedBy: .newlines).first(where: { $0.hasPrefix("#EXT-X-KEY") }) else { return nil }
        let method = firstMatch(line, "METHOD=([A-Z0-9-]+)") ?? "NONE"
        guard method == "AES-128", let uri = firstMatch(line, "URI=\"([^\"]+)\""), let keyURL = resolve(uri, base: base),
              let keyData = await fetchData(keyURL, referer: referer, cookieHeader: cookieHeader, authHeader: authHeader), keyData.count == 16 else {
            return nil
        }
        let iv = firstMatch(line, "IV=0x([0-9A-Fa-f]+)").flatMap { hexData($0) }
        return HLSKey(key: keyData, baseIV: iv)
    }

    // MARK: - Crypto (AES-128-CBC, CommonCrypto)

    nonisolated private static func aesCBCDecrypt(_ data: Data, key: Data, iv: Data) -> Data? {
        guard key.count == kCCKeySizeAES128, iv.count == kCCBlockSizeAES128 else { return nil }
        var out = Data(count: data.count + kCCBlockSizeAES128)
        var moved = 0
        // Use each buffer pointer's own `.count` (not the Data's) inside the closures — reading
        // `out.count` while `out` is mutably borrowed by withUnsafeMutableBytes is overlapping access.
        let status: Int32 = out.withUnsafeMutableBytes { o in
            data.withUnsafeBytes { i in
                key.withUnsafeBytes { k in
                    iv.withUnsafeBytes { v in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                k.baseAddress, k.count, v.baseAddress,
                                i.baseAddress, i.count, o.baseAddress, o.count, &moved)
                    }
                }
            }
        }
        guard status == Int32(kCCSuccess) else { return nil }
        out.removeSubrange(moved..<out.count)
        return out
    }

    // MARK: - HTTP

    nonisolated private static func request(_ url: URL, referer: String, cookieHeader: String, authHeader: String? = nil) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        if !referer.isEmpty { req.setValue(referer, forHTTPHeaderField: "Referer") }
        if let host = url.host, let scheme = url.scheme { req.setValue("\(scheme)://\(host)/", forHTTPHeaderField: "Origin") }
        if !cookieHeader.isEmpty { req.setValue(cookieHeader, forHTTPHeaderField: "Cookie") }
        if let authHeader, !authHeader.isEmpty { req.setValue(authHeader, forHTTPHeaderField: "Authorization") }
        return req
    }

    nonisolated private static func fetchText(_ url: URL, referer: String, cookieHeader: String, authHeader: String? = nil) async -> String? {
        guard let d = await fetchData(url, referer: referer, cookieHeader: cookieHeader, authHeader: authHeader) else { return nil }
        return String(data: d, encoding: .utf8)
    }

    /// Like `fetchData` but reports *why* it failed (HTTP status or a network error), so the HLS
    /// downloader can tell the user the real reason a segment couldn't be fetched instead of a
    /// generic "expired". `reason` is nil on success.
    nonisolated private static func fetchSegmentData(_ url: URL, referer: String, cookieHeader: String,
                                                     authHeader: String? = nil) async -> (data: Data?, reason: String?) {
        var reason = "no response"
        for attempt in 0..<4 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: UInt64(1 << (attempt - 1)) * 400_000_000) }
            do {
                let (data, resp) = try await session.data(for: request(url, referer: referer, cookieHeader: cookieHeader, authHeader: authHeader))
                if let code = (resp as? HTTPURLResponse)?.statusCode {
                    if code == 429 || code >= 500 { reason = "HTTP \(code)"; continue }
                    if code >= 400 { return (nil, "HTTP \(code)") }   // won't recover on the same URL
                }
                return (data, nil)
            } catch {
                reason = "network error (\((error as NSError).code))"
                continue
            }
        }
        return (nil, reason)
    }

    nonisolated private static func fetchData(_ url: URL, referer: String, cookieHeader: String, authHeader: String? = nil) async -> Data? {
        for attempt in 0..<4 {
            // Exponential backoff (0.4s, 0.8s, 1.6s) so a brief cellular drop doesn't burn the retries.
            if attempt > 0 { try? await Task.sleep(nanoseconds: UInt64(1 << (attempt - 1)) * 400_000_000) }
            guard let (data, resp) = try? await session.data(for: request(url, referer: referer, cookieHeader: cookieHeader, authHeader: authHeader)) else { continue }
            if let code = (resp as? HTTPURLResponse)?.statusCode {
                if code == 429 || code >= 500 { continue }
                // 4xx (expired/forbidden token) won't recover on the same URL — the caller refetches
                // the playlist for a fresh one and retries, so give up on this URL now.
                if code >= 400 { return nil }
            }
            return data
        }
        return nil
    }

    // MARK: - Fast download (parallel HTTP range requests)

    private static let rangeChunk: Int64 = 4 << 20        // 4 MB per range request
    private static let rangeConcurrency = 6               // parallel connections
    private static let rangeMinSize: Int64 = 6 << 20      // only parallelize files bigger than this

    /// Downloads `url` to a temp file. When the server supports HTTP range requests and the file is
    /// large, it's pulled in parallel 4 MB chunks over several connections (a big speed-up for the
    /// members video/zip downloads, the same trick the MEGA downloader uses); otherwise it streams
    /// over a single connection. Returns the temp file + the response (for status / MIME).
    nonisolated private static func downloadToTemp(_ url: URL, referer: String, cookieHeader: String, authHeader: String?,
                                                   progress: @escaping @Sendable (Double) -> Void) async -> (URL, URLResponse)? {
        // HEAD probe: learn the size + whether ranges are supported, WITHOUT pulling any body (a
        // ranged-GET probe would download the whole file if the server ignored the Range header).
        var head = request(url, referer: referer, cookieHeader: cookieHeader, authHeader: authHeader)
        head.httpMethod = "HEAD"
        if let (_, hresp) = try? await session.data(for: head), let http = hresp as? HTTPURLResponse, http.statusCode == 200 {
            let acceptsRanges = (http.value(forHTTPHeaderField: "Accept-Ranges") ?? "").lowercased().contains("bytes")
            let total = http.expectedContentLength
            if acceptsRanges, total > rangeMinSize,
               let out = await rangedDownload(url, total: total, referer: referer, cookieHeader: cookieHeader,
                                              authHeader: authHeader, response: http, progress: progress) {
                return out
            }
        }
        // Single-connection fallback (small file, no range support, HEAD unsupported, or a mid-download
        // failure). This path also carries the 4xx/auth response through so the caller can prompt + retry.
        let req = request(url, referer: referer, cookieHeader: cookieHeader, authHeader: authHeader)
        let dl = ProgressDownloadDelegate { progress($0) }
        return await dl.run(req)
    }

    /// Parallel range download of a known-size file into a temp. Fails (returns nil → single-stream
    /// fallback) if any chunk can't be fetched as a 206 partial.
    nonisolated private static func rangedDownload(_ url: URL, total: Int64, referer: String, cookieHeader: String,
                                                   authHeader: String?, response: URLResponse,
                                                   progress: @escaping @Sendable (Double) -> Void) async -> (URL, URLResponse)? {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("webdl_\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: tmp.path, contents: nil),
              let fh = try? FileHandle(forWritingTo: tmp) else { return nil }
        let writer = RangeWriter(fh)
        let prog = RangeProgress(total: total, report: progress)
        let ok = await withTaskGroup(of: Bool.self) { group -> Bool in
            var offset: Int64 = 0
            var active = 0
            func addNext() {
                guard offset < total else { return }
                let start = offset, end = min(start + rangeChunk, total) - 1
                offset = end + 1
                active += 1
                group.addTask {
                    var req = request(url, referer: referer, cookieHeader: cookieHeader, authHeader: authHeader)
                    req.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
                    for _ in 0..<3 {
                        guard let (data, resp) = try? await session.data(for: req) else { continue }
                        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                        if code == 206, !data.isEmpty {
                            try? await writer.write(data, at: start)
                            await prog.add(Int64(data.count))
                            return true
                        }
                        if code == 429 || code >= 500 { continue }   // transient — retry
                        return false                                  // 200 (no range support) / 4xx — bail to fallback
                    }
                    return false
                }
            }
            for _ in 0..<rangeConcurrency { addNext() }
            var allOK = true
            while active > 0 { if let r = await group.next() { active -= 1; if !r { allOK = false }; addNext() } }
            return allOK
        }
        await writer.close()
        guard ok else { try? FileManager.default.removeItem(at: tmp); return nil }
        return (tmp, response)
    }

    // MARK: - Helpers

    nonisolated private static func resolve(_ uri: String, base: URL) -> URL? {
        let resolved = uri.hasPrefix("http") ? URL(string: uri) : URL(string: uri, relativeTo: base)?.absoluteURL
        guard let u = resolved else { return nil }
        // AWS/CloudFront-signed streams (Loom, and many CDN-hosted HLS) sign the *playlist* URL
        // — `?Signature=…&Policy=…&Key-Pair-Id=…` — and the policy authorizes the whole path, so
        // the player must append that same query to every segment/key/init request. The m3u8 lists
        // those as relative URIs with no query of their own; without carrying the playlist's query
        // over, each segment hits the CDN unsigned and 403s (all 885 segments failed for exactly
        // this reason). Inherit the base's query when the target has none and is on the same host.
        if u.query == nil, u.host == base.host,
           let baseQuery = URLComponents(url: base, resolvingAgainstBaseURL: false)?.percentEncodedQuery,
           !baseQuery.isEmpty {
            var comps = URLComponents(url: u, resolvingAgainstBaseURL: false)
            comps?.percentEncodedQuery = baseQuery
            return comps?.url ?? u
        }
        return u
    }

    /// The real file extension inferred from a file's leading magic bytes — trusted over a server's
    /// Content-Disposition / MIME / URL, which for these "high-res" downloads gave no extension at all
    /// (the files showed up as a "data" tile and couldn't be recognized as zips). Reads 16 bytes.
    nonisolated static func magicExtension(forFileAt url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let d = try? h.read(upToCount: 16), d.count >= 4 else { return nil }
        let b = [UInt8](d)
        func has(_ sig: [UInt8], at off: Int = 0) -> Bool {
            guard b.count >= off + sig.count else { return false }
            for (i, v) in sig.enumerated() where b[off + i] != v { return false }
            return true
        }
        if has([0x50, 0x4B, 0x03, 0x04]) || has([0x50, 0x4B, 0x05, 0x06]) || has([0x50, 0x4B, 0x07, 0x08]) { return "zip" }
        if has([0xFF, 0xD8, 0xFF]) { return "jpg" }
        if has([0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if has([0x47, 0x49, 0x46, 0x38]) { return "gif" }
        if has([0x25, 0x50, 0x44, 0x46]) { return "pdf" }
        if has([0x52, 0x49, 0x46, 0x46]), has([0x57, 0x45, 0x42, 0x50], at: 8) { return "webp" }
        if has([0x66, 0x74, 0x79, 0x70], at: 4) { return "mp4" }        // ....ftyp
        if has([0x1A, 0x45, 0xDF, 0xA3]) { return "webm" }             // Matroska/WebM (EBML)
        if has([0x52, 0x61, 0x72, 0x21]) { return "rar" }
        if has([0x37, 0x7A, 0xBC, 0xAF]) { return "7z" }
        if has([0x1F, 0x8B]) { return "gz" }
        return nil
    }

    nonisolated private static func fileExtension(url: URL, response: URLResponse?, fallback: String) -> String {
        let ext = url.pathExtension.lowercased()
        if ["mp4", "m4v", "mov", "webm", "mkv", "ts"].contains(ext) { return ext == "m4v" ? "mp4" : ext }
        switch (response?.mimeType ?? "").lowercased() {
        case let m where m.contains("mp4"): return "mp4"
        case let m where m.contains("webm"): return "webm"
        case let m where m.contains("quicktime"): return "mov"
        default: return fallback
        }
    }

    nonisolated private static func baseName(_ suggested: String?, url: URL, ext: String) -> String {
        var name = (suggested?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? url.deletingPathExtension().lastPathComponent
        name = name.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "-")
        if name.isEmpty || name.count < 2 {
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm.ss"
            name = "Web Video \(f.string(from: Date()))"
        }
        return "\(String(name.prefix(120))).\(ext)"
    }

    /// A safe on-disk filename for an arbitrary download. The server's suggested filename (from a
    /// `Content-Disposition` header, else synthesized from the URL) wins because it carries the
    /// correct extension; a long-press `download` attribute name is the next choice; the URL's own
    /// last path component is the fallback. A missing extension is filled from the MIME type.
    nonisolated private static func fileName(suggested: String?, url: URL, response: URLResponse?, sniffedExt: String? = nil) -> String {
        var name = (suggested?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
        if name == nil, let s = response?.suggestedFilename, !s.isEmpty { name = s }
        if name == nil { let last = url.lastPathComponent; name = last.isEmpty ? nil : last }
        var out = sanitize(name ?? "download")
        if out.isEmpty { out = "download" }
        if let sniffedExt {
            // The bytes are authoritative — a server that named the file "…highres" with no extension
            // still gets a real ".zip"/".jpg"/… so it's recognizable and (for zips) extractable.
            out = "\((out as NSString).deletingPathExtension).\(sniffedExt)"
        } else if (out as NSString).pathExtension.isEmpty {
            let ext = !url.pathExtension.isEmpty ? url.pathExtension : mimeExtension(response?.mimeType)
            out += ".\(ext)"
        }
        return String(out.prefix(160))
    }

    /// Strip path separators and characters exFAT/HFS reject from a candidate filename.
    nonisolated private static func sanitize(_ s: String) -> String {
        s.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A file extension for a MIME type when neither the filename nor the URL carries one.
    nonisolated private static func mimeExtension(_ mime: String?) -> String {
        switch (mime ?? "").lowercased() {
        case let m where m.contains("zip"): return "zip"
        case let m where m.contains("pdf"): return "pdf"
        case let m where m.contains("jpeg"): return "jpg"
        case let m where m.contains("png"): return "png"
        case let m where m.contains("gif"): return "gif"
        case let m where m.contains("mp4"): return "mp4"
        case let m where m.contains("mpeg"): return "mp3"
        case let m where m.contains("gzip"): return "gz"
        case let m where m.contains("x-7z"): return "7z"
        case let m where m.contains("rar"): return "rar"
        case let m where m.contains("plain"): return "txt"
        default: return "bin"
        }
    }

    nonisolated private static func uniqueDestination(name: String, in folder: URL) -> URL {
        let fm = FileManager.default
        var dest = folder.appendingPathComponent(name)
        let base = dest.deletingPathExtension().lastPathComponent, ext = dest.pathExtension
        var n = 1
        while fm.fileExists(atPath: dest.path) { dest = folder.appendingPathComponent("\(base) \(n).\(ext)"); n += 1 }
        return dest
    }

    nonisolated private static func createFile(_ url: URL) -> FileHandle? {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return try? FileHandle(forWritingTo: url)
    }

    nonisolated private static func stampNow(_ url: URL) {
        let now = Date()
        try? FileManager.default.setAttributes([.creationDate: now, .modificationDate: now], ofItemAtPath: url.path)
    }

    /// Set the file's creation/modification date from its embedded EXIF capture date when it's an
    /// image that has one; otherwise stamp "now". The EXIF bytes themselves are never touched.
    nonisolated private static func stampFromMetadata(_ url: URL) {
        let date = exifCaptureDate(url) ?? Date()
        try? FileManager.default.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: url.path)
    }

    /// Write a page-provided capture `date` and/or `caption` into a saved download — real EXIF/IPTC
    /// for images, a lossless passthrough metadata re-mux for videos — plus the filesystem date.
    /// All off the main actor (this whole type is `nonisolated`).
    nonisolated private static func stampMetadata(date: Date?, caption: String?, to url: URL) async {
        switch classify(url: url, isDirectory: false) {
        case .image: writeImageMeta(date: date, caption: caption, to: url)
        case .video: await writeVideoMeta(date: date, caption: caption, to: url)
        default:     break
        }
        if let date {
            try? FileManager.default.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: url.path)
        }
    }

    /// Lossless rewrite: the encoded image is copied, only the date (EXIF/TIFF) and caption
    /// (IPTC CaptionAbstract + TIFF ImageDescription + EXIF UserComment) fields change.
    nonisolated private static func writeImageMeta(date: Date?, caption: String?, to url: URL) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(src) else { return }
        var props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
        var exif = (props[kCGImagePropertyExifDictionary] as? [CFString: Any]) ?? [:]
        var tiff = (props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]) ?? [:]
        if let date {
            let f = DateFormatter(); f.dateFormat = "yyyy:MM:dd HH:mm:ss"; f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = .current
            let stamp = f.string(from: date)
            exif[kCGImagePropertyExifDateTimeOriginal] = stamp
            exif[kCGImagePropertyExifDateTimeDigitized] = stamp
            tiff[kCGImagePropertyTIFFDateTime] = stamp
        }
        if let caption {
            var iptc = (props[kCGImagePropertyIPTCDictionary] as? [CFString: Any]) ?? [:]
            iptc[kCGImagePropertyIPTCCaptionAbstract] = caption
            props[kCGImagePropertyIPTCDictionary] = iptc
            tiff[kCGImagePropertyTIFFImageDescription] = caption
            exif[kCGImagePropertyExifUserComment] = caption
        }
        props[kCGImagePropertyExifDictionary] = exif
        props[kCGImagePropertyTIFFDictionary] = tiff
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".pbtmp_" + UUID().uuidString).appendingPathExtension(url.pathExtension)
        guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, type, 1, nil) else { return }
        CGImageDestinationAddImageFromSource(dest, src, 0, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { try? FileManager.default.removeItem(at: tmp); return }
        if (try? FileManager.default.replaceItemAt(url, withItemAt: tmp)) != nil { DriveWriter.fullSyncFileAndParent(url) }
    }

    /// Passthrough export (no re-encode) that writes the creation date and/or description into a
    /// video's metadata, then swaps it in — the app reads a video's date/caption from embedded
    /// metadata, not the file date.
    nonisolated private static func writeVideoMeta(date: Date?, caption: String?, to url: URL) async {
        let asset = AVURLAsset(url: url)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else { return }
        var meta = ((try? await asset.load(.metadata)) ?? []).filter { item in
            item.commonKey != .commonKeyCreationDate && item.commonKey != .commonKeyDescription
                && item.identifier != .quickTimeMetadataCreationDate
                && item.identifier != .commonIdentifierCreationDate
                && item.identifier != .quickTimeMetadataDescription
                && item.identifier != .commonIdentifierDescription
        }
        if let date {
            let iso = ISO8601DateFormatter().string(from: date)
            for id in [AVMetadataIdentifier.commonIdentifierCreationDate, .quickTimeMetadataCreationDate] {
                let item = AVMutableMetadataItem(); item.identifier = id; item.value = iso as NSString; meta.append(item)
            }
        }
        if let caption {
            for id in [AVMetadataIdentifier.commonIdentifierDescription, .quickTimeMetadataDescription] {
                let item = AVMutableMetadataItem()
                item.identifier = id; item.value = caption as NSString; item.extendedLanguageTag = "und"
                meta.append(item)
            }
        }
        export.metadata = meta
        let ext = url.pathExtension.lowercased()
        let fileType: AVFileType = ext == "mp4" ? .mp4 : (ext == "m4v" ? .m4v : .mov)
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".pbtmp_" + UUID().uuidString).appendingPathExtension(ext.isEmpty ? "mov" : ext)
        export.outputURL = tmp
        export.outputFileType = fileType
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { cont.resume() }
        }
        guard export.status == .completed else { try? FileManager.default.removeItem(at: tmp); return }
        if (try? FileManager.default.replaceItemAt(url, withItemAt: tmp)) != nil { DriveWriter.fullSyncFileAndParent(url) }
    }

    nonisolated private static func exifCaptureDate(_ url: URL) -> Date? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        guard let s = (exif?[kCGImagePropertyExifDateTimeOriginal] as? String)
                ?? (exif?[kCGImagePropertyExifDateTimeDigitized] as? String)
                ?? (tiff?[kCGImagePropertyTIFFDateTime] as? String) else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.date(from: s)
    }

    nonisolated private static func hexData(_ hex: String) -> Data? {
        var h = hex; if h.count % 2 == 1 { h = "0" + h }
        var out = Data(); var idx = h.startIndex
        while idx < h.endIndex {
            let next = h.index(idx, offsetBy: 2)
            guard let b = UInt8(h[idx..<next], radix: 16) else { return nil }
            out.append(b); idx = next
        }
        return out
    }

    nonisolated private static func firstMatch(_ s: String, _ pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges > 1 else { return nil }
        let r = m.range(at: 1)
        return r.location == NSNotFound ? nil : ns.substring(with: r)
    }
}

/// A one-shot download that reports real byte-progress (`didWriteData`) and hands back the temp
/// file + response. Used for direct-file downloads so the browser's Downloads tab shows a true %.
private final class ProgressDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<(URL, URLResponse)?, Never>?
    private var session: URLSession!
    private var lastReport = 0.0

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
        super.init()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpShouldSetCookies = false            // our manual Cookie header is authoritative
        cfg.httpCookieStorage = nil
        cfg.timeoutIntervalForRequest = 60
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }

    func run(_ req: URLRequest) async -> (URL, URLResponse)? {
        await withCheckedContinuation { c in
            continuation = c
            session.downloadTask(with: req).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let f = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        if f - lastReport >= 0.01 || f >= 1 { lastReport = f; onProgress(min(f, 1)) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temp file is removed as soon as this returns — move it somewhere stable synchronously.
        let dst = FileManager.default.temporaryDirectory.appendingPathComponent("webdl_\(UUID().uuidString)")
        do { try FileManager.default.moveItem(at: location, to: dst) }
        catch { try? FileManager.default.copyItem(at: location, to: dst) }
        let resp = downloadTask.response ?? URLResponse()
        let result: (URL, URLResponse)? = FileManager.default.fileExists(atPath: dst.path) ? (dst, resp) : nil
        continuation?.resume(returning: result); continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if error != nil { continuation?.resume(returning: nil); continuation = nil }
    }
}

/// Serializes seek+write of range chunks into the temp file (concurrent chunks write different
/// offsets, but a `FileHandle` isn't safe to touch from several tasks at once).
private actor RangeWriter {
    private let handle: FileHandle
    init(_ handle: FileHandle) { self.handle = handle }
    func write(_ data: Data, at offset: Int64) throws {
        try handle.seek(toOffset: UInt64(offset))
        try handle.write(contentsOf: data)
    }
    func close() { try? handle.close() }
}

/// Accumulates bytes across concurrent range chunks and reports an aggregate 0…1 fraction.
private actor RangeProgress {
    private var done: Int64 = 0
    private let total: Int64
    private let report: @Sendable (Double) -> Void
    init(total: Int64, report: @escaping @Sendable (Double) -> Void) { self.total = total; self.report = report }
    func add(_ n: Int64) { done += n; report(total > 0 ? min(1, Double(done) / Double(total)) : 0) }
}
