import Foundation

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
    enum Outcome: Sendable { case saved(URL); case failed(String) }

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
                                     progress: @escaping @Sendable (Progress) -> Void) async -> Outcome {
        guard let url = URL(string: urlString) else { return .failed("That video URL couldn’t be read.") }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if isHLS(url) {
            return await downloadHLS(url, pageURL: pageURL, cookieHeader: cookieHeader, authHeader: authHeader,
                                     into: folder, suggestedName: suggestedName, progress: progress)
        }
        return await downloadDirect(url, pageURL: pageURL, cookieHeader: cookieHeader, authHeader: authHeader,
                                    into: folder, suggestedName: suggestedName, progress: progress)
    }

    nonisolated static func isHLS(_ url: URL) -> Bool {
        let s = url.absoluteString.lowercased()
        return url.pathExtension.lowercased() == "m3u8" || s.contains(".m3u8")
    }

    // MARK: - Direct file

    nonisolated private static func downloadDirect(_ url: URL, pageURL: String, cookieHeader: String,
                                                   authHeader: String?, into folder: URL, suggestedName: String?,
                                                   progress: @escaping @Sendable (Progress) -> Void) async -> Outcome {
        progress(Progress(fraction: 0, phase: "Downloading video…"))
        let req = request(url, referer: pageURL, cookieHeader: cookieHeader, authHeader: authHeader)
        // A delegate download gives real byte-progress (unlike `session.download(for:)`).
        let dl = ProgressDownloadDelegate { f in progress(Progress(fraction: f, phase: "Downloading video…")) }
        guard let (tmp, resp) = await dl.run(req) else {
            return .failed("The download failed (the video may be protected or the link expired).")
        }
        if let code = (resp as? HTTPURLResponse)?.statusCode, code >= 400 {
            try? FileManager.default.removeItem(at: tmp)
            if code == 401 || code == 403 {
                return .failed("The server refused the download (HTTP \(code)). If this is a members-only site, sign in through the browser first — the password prompt lets the download reuse your login.")
            }
            return .failed("The server refused the download (HTTP \(code)).")
        }
        let ext = fileExtension(url: url, response: resp, fallback: "mp4")
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

    // MARK: - HLS

    nonisolated private static func downloadHLS(_ manifestURL: URL, pageURL: String, cookieHeader: String,
                                                authHeader: String?, into folder: URL, suggestedName: String?,
                                                progress: @escaping @Sendable (Progress) -> Void) async -> Outcome {
        progress(Progress(fraction: 0, phase: "Reading stream…"))
        guard var text = await fetchText(manifestURL, referer: pageURL, cookieHeader: cookieHeader, authHeader: authHeader) else {
            return .failed("Couldn’t read the video stream (m3u8).")
        }
        var playlistURL = manifestURL
        // Master playlist → pick the highest-bandwidth variant, then fetch it.
        if text.contains("#EXT-X-STREAM-INF") {
            guard let variant = bestVariant(text, base: manifestURL),
                  let vtext = await fetchText(variant, referer: pageURL, cookieHeader: cookieHeader, authHeader: authHeader) else {
                return .failed("Couldn’t read the stream’s quality list.")
            }
            playlistURL = variant; text = vtext
        }

        let segs = parseSegments(text, base: playlistURL)
        guard !segs.isEmpty else { return .failed("The stream had no downloadable segments.") }
        let key = await resolveKey(text, base: playlistURL, referer: pageURL, cookieHeader: cookieHeader, authHeader: authHeader)
        if key == nil, text.contains("#EXT-X-KEY"), !text.uppercased().contains("METHOD=NONE") {
            // A key line exists but we couldn't fetch/parse it (or it's SAMPLE-AES / DRM).
            return .failed("This video is encrypted in a way that can’t be saved (DRM-protected).")
        }
        let initSeg = parseInitSegment(text, base: playlistURL)     // fMP4/CMAF init
        let isFMP4 = initSeg != nil || segs.first?.url.pathExtension.lowercased() == "m4s"

        // Download every segment (bounded concurrency), preserving order.
        var datas = [Data?](repeating: nil, count: segs.count)
        let total = segs.count
        var done = 0
        let lock = NSLock()
        await withTaskGroup(of: (Int, Data?).self) { group in
            var idx = 0
            let maxConcurrent = 6
            func addNext() {
                guard idx < segs.count else { return }
                let i = idx; let seg = segs[i]; idx += 1
                group.addTask {
                    guard var d = await fetchData(seg.url, referer: pageURL, cookieHeader: cookieHeader, authHeader: authHeader) else { return (i, nil) }
                    if let key { d = aesCBCDecrypt(d, key: key.key, iv: seg.iv ?? key.iv(forSequence: i)) ?? d }
                    return (i, d)
                }
            }
            for _ in 0..<min(maxConcurrent, segs.count) { addNext() }
            while let (i, d) = await group.next() {
                datas[i] = d
                lock.lock(); done += 1; let dn = done; lock.unlock()
                if dn % 3 == 0 || dn == total {
                    progress(Progress(fraction: Double(dn) / Double(total), phase: "Downloading \(dn)/\(total) segments…"))
                }
                addNext()
            }
        }
        guard datas.allSatisfy({ $0 != nil }) else {
            return .failed("Some video segments couldn’t be downloaded (the stream may have expired).")
        }

        // Concatenate: [init] + segments, in order.
        progress(Progress(fraction: 1, phase: "Assembling…"))
        let ext = isFMP4 ? "mp4" : "ts"
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("webvid_\(UUID().uuidString).\(ext)")
        guard let handle = createFile(tmp) else { return .failed("Couldn’t assemble the video file.") }
        if let initSeg, let initData = await fetchData(initSeg, referer: pageURL, cookieHeader: cookieHeader, authHeader: authHeader) {
            try? handle.write(contentsOf: initData)
        }
        for d in datas { if let d { try? handle.write(contentsOf: d) } }
        try? handle.close()

        // If TS and FFmpegKit is available, remux to a clean faststart MP4; otherwise keep .ts.
        var finalTmp = tmp
        var finalExt = ext
        if ext == "ts", VideoTranscoder.isAvailable {
            let mp4 = tmp.deletingPathExtension().appendingPathExtension("mp4")
            if await VideoTranscoder.muxTranscode(video: tmp, audio: nil, to: mp4, transcode: false, date: Date(), lat: nil, lng: nil) {
                try? FileManager.default.removeItem(at: tmp); finalTmp = mp4; finalExt = "mp4"
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

    nonisolated private static func fetchData(_ url: URL, referer: String, cookieHeader: String, authHeader: String? = nil) async -> Data? {
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: UInt64(attempt) * 500_000_000) }
            guard let (data, resp) = try? await session.data(for: request(url, referer: referer, cookieHeader: cookieHeader, authHeader: authHeader)) else { continue }
            if let code = (resp as? HTTPURLResponse)?.statusCode {
                if code == 429 || code >= 500 { continue }
                if code >= 400 { return nil }
            }
            return data
        }
        return nil
    }

    // MARK: - Helpers

    nonisolated private static func resolve(_ uri: String, base: URL) -> URL? {
        if uri.hasPrefix("http") { return URL(string: uri) }
        return URL(string: uri, relativeTo: base)?.absoluteURL
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
