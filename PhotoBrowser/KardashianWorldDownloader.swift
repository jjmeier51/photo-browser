import Foundation
import ImageIO
import Compression

/// Salvages the (defunct) kardashianworld.net photo gallery from public web
/// archives. The live domain is now parked, so this scans **two** archives for
/// every image the site ever served and downloads the original bytes:
///
///   1. the **Internet Archive** (Wayback CDX API) — every archived image under
///      the domain, fetched via the `id_` raw endpoint (no toolbar rewriting), and
///   2. **Common Crawl** — its per-crawl URL indexes, fetched by WARC byte-range
///      out of the public S3 mirror and gunzipped on the fly.
///
/// Results from both are merged and de-duplicated, keeping the *best* version of
/// each gallery image (full-size over `normal_`/`thumb_`, larger archived bytes as
/// a tiebreaker), grouped into per-member subfolders. Best-effort and
/// download-only, like the MEGA/taylorpictures features — coverage is partial, so
/// failures are surfaced as notes.
///
/// All `nonisolated`: networking + crypto + file writes must stay off the main actor.
enum KardashianWorldDownloader {
    nonisolated static let host = "kardashianworld.net"
    nonisolated static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    struct Progress: Sendable { var phase: String; var fraction: Double; var done: Int; var total: Int }
    struct BatchResult: Sendable {
        var downloaded = 0, failed = 0
        var nextIndex = 0           // where the next batch resumes
        var total = 0              // total archived photos available
        var membersTouched: Set<String> = []
        var note: String?
    }

    /// Member birthdays (for the per-folder "Age" feature). Names match `members`.
    nonisolated static let birthdays: [String: DateComponents] = [
        "Kim Kardashian":      DateComponents(year: 1980, month: 10, day: 21),
        "Kylie Jenner":        DateComponents(year: 1997, month: 8, day: 10),
        "Kendall Jenner":      DateComponents(year: 1995, month: 11, day: 3),
        "Khloé Kardashian":    DateComponents(year: 1984, month: 6, day: 27),
        "Kourtney Kardashian": DateComponents(year: 1979, month: 4, day: 18),
    ]

    nonisolated static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.httpMaximumConnectionsPerHost = 6
        cfg.timeoutIntervalForRequest = 90
        cfg.urlCache = URLCache(memoryCapacity: 32 << 20, diskCapacity: 256 << 20)
        cfg.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: cfg)
    }()

    /// Where a shot can be fetched from — the two archives need different download
    /// strategies (Wayback `id_` URL vs. a Common Crawl WARC byte-range).
    private enum Source: Sendable {
        case wayback(timestamp: String)
        case commonCrawl(warc: String, offset: Int, length: Int)
    }
    private struct Shot: Sendable { let original: String; let length: Int; let source: Source }
    nonisolated private static let minBytes = 150 * 1024        // weed out low-res photos
    private struct Job: Sendable { let member: String; let url: String; let name: String; let source: Source }

    /// Members in priority order (more-specific names first; "kim" last so it can't
    /// pre-empt the others). First path-segment match wins.
    nonisolated private static let members: [(key: String, name: String)] = [
        ("khloe", "Khloé Kardashian"), ("kourtney", "Kourtney Kardashian"),
        ("kendall", "Kendall Jenner"), ("kylie", "Kylie Jenner"),
        ("kris", "Kris Jenner"), ("caitlyn", "Caitlyn Jenner"), ("bruce", "Caitlyn Jenner"),
        ("rob", "Rob Kardashian"), ("kim", "Kim Kardashian")
    ]

    // MARK: - Run

    /// Downloads up to `batchSize` photos starting at `startIndex` into `root`
    /// (already sorted into per-member subfolders). The job list is deterministically
    /// ordered, so `startIndex` resumes exactly where a previous batch stopped.
    nonisolated static func runBatch(into root: URL, startIndex: Int, batchSize: Int = 1000,
                                     progress: @escaping @Sendable (Progress) -> Void) async -> BatchResult {
        var result = BatchResult()
        progress(Progress(phase: "Searching web archives…", fraction: 0, done: 0, total: 0))
        // Query both archives concurrently and merge — each fills gaps in the other.
        async let waybackShots = fetchCDX()
        async let commonCrawlShots = fetchCommonCrawl()
        let shots = await waybackShots + commonCrawlShots
        guard !shots.isEmpty else {
            result.note = "Couldn’t find archived photos — the Internet Archive and Common Crawl may have none, or be unreachable."
            return result
        }
        let jobs = buildJobs(shots)
        result.total = jobs.count
        if jobs.isEmpty { result.note = "No photos over \(minBytes / 1024) KB were archived."; return result }
        guard startIndex < jobs.count else { result.nextIndex = jobs.count; return result }   // already finished
        let batch = Array(jobs[startIndex..<min(startIndex + batchSize, jobs.count)])
        result.nextIndex = startIndex + batch.count

        let total = batch.count
        var done = 0
        await withTaskGroup(of: (ok: Bool, member: String).self) { group in
            var idx = 0
            let maxConcurrent = 4               // the archives throttle; keep it modest
            func addNext() {
                guard idx < batch.count else { return }
                let job = batch[idx]; idx += 1
                group.addTask { (ok: await download(job, into: root), member: job.member) }
            }
            for _ in 0..<min(maxConcurrent, total) { addNext() }
            while let r = await group.next() {
                if r.ok { result.downloaded += 1; result.membersTouched.insert(r.member) } else { result.failed += 1 }
                done += 1
                progress(Progress(phase: "Downloading", fraction: Double(done) / Double(total), done: done, total: total))
                addNext()
            }
        }
        if result.downloaded == 0 { result.note = "This batch couldn’t be downloaded from the archives." }
        else if result.failed > 0 { result.note = "\(result.failed) image(s) in this batch couldn’t be downloaded." }
        return result
    }

    // MARK: - Wayback CDX

    /// Every archived image under the domain, with its archived byte `length`. We
    /// collapse only by content digest (not by url), so different resolutions and
    /// re-crawls all stay visible — letting us pick the largest version per image.
    /// The mimetype filter is broadened to any `image/*` so PNG/GIF gallery assets
    /// aren't dropped.
    nonisolated private static func fetchCDX() async -> [Shot] {
        let q = "https://web.archive.org/cdx/search/cdx?url=\(host)&matchType=domain"
            + "&filter=mimetype:image/.*&filter=statuscode:200&collapse=digest"
            + "&fl=original,timestamp,length&output=text"
        guard let url = URL(string: q) else { return [] }
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 300
        guard let (data, _) = try? await session.data(for: req),
              let text = String(data: data, encoding: .utf8) else { return [] }
        var shots: [Shot] = []
        for line in text.split(separator: "\n") {
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            guard cols.count >= 3 else { continue }
            shots.append(Shot(original: String(cols[0]), length: Int(cols[2]) ?? 0,
                              source: .wayback(timestamp: String(cols[1]))))
        }
        return shots
    }

    // MARK: - Common Crawl

    /// Common Crawl is a second, independent web archive. We ask its CDX servers
    /// (one per monthly crawl) for every captured URL under the domain; each row
    /// carries the WARC file + byte offset/length where the original response is
    /// stored, which `download` later fetches via an S3 Range request. We scan the
    /// few most recent crawls that overlap the site's lifetime — enough to backfill
    /// images the Wayback Machine missed without scanning all ~100 crawls.
    nonisolated private static func fetchCommonCrawl() async -> [Shot] {
        let crawls = await recentCrawlIDs(limit: 6)
        guard !crawls.isEmpty else { return [] }
        var shots: [Shot] = []
        await withTaskGroup(of: [Shot].self) { group in
            for id in crawls { group.addTask { await fetchCommonCrawlIndex(id) } }
            for await s in group { shots += s }
        }
        return shots
    }

    /// The most recent crawl IDs (e.g. "CC-MAIN-2022-05") from collinfo.json.
    nonisolated private static func recentCrawlIDs(limit: Int) async -> [String] {
        guard let url = URL(string: "https://index.commoncrawl.org/collinfo.json") else { return [] }
        var req = URLRequest(url: url); req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 60
        guard let (data, _) = try? await session.data(for: req),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return arr.compactMap { $0["id"] as? String }.prefix(limit).map { $0 }
    }

    /// One crawl's index rows for the domain, as Shots pointing into its WARCs.
    nonisolated private static func fetchCommonCrawlIndex(_ crawlID: String) async -> [Shot] {
        let q = "https://index.commoncrawl.org/\(crawlID)-index?url=\(host)%2F*&output=json"
        guard let url = URL(string: q) else { return [] }
        var req = URLRequest(url: url); req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 180
        guard let (data, _) = try? await session.data(for: req),
              let text = String(data: data, encoding: .utf8) else { return [] }
        var shots: [Shot] = []
        for line in text.split(separator: "\n") {
            guard let row = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let original = row["url"] as? String,
                  (row["status"] as? String) == "200" else { continue }
            let mime = (row["mime"] as? String ?? "").lowercased()
            if !mime.hasPrefix("image/") { continue }
            guard let warc = row["filename"] as? String,
                  let offset = Int(row["offset"] as? String ?? ""),
                  let length = Int(row["length"] as? String ?? "") else { continue }
            // Common Crawl's `length` is the gzipped WARC record size, not the image
            // size, so it isn't a reliable resolution signal — record it as unknown (0).
            shots.append(Shot(original: original, length: 0,
                              source: .commonCrawl(warc: warc, offset: offset, length: length)))
        }
        return shots
    }

    // MARK: - Job building

    /// One job per unique gallery image — the *best* archived version of it. Variant
    /// rank is primary (full image beats `normal_` beats `thumb_`), with archived
    /// byte `length` only as a tiebreaker. This fixes the old length-only pick, which
    /// dropped a full-res image whenever its archived `length` was unknown (0) and a
    /// thumbnail happened to report a size. UI/theme assets are skipped.
    nonisolated private static func buildJobs(_ shots: [Shot]) -> [Job] {
        // rank: 2 = full image, 1 = normal_, 0 = thumb_ (higher is better)
        struct Best { var shot: Shot; var base: String; var rank: Int }
        var best: [String: Best] = [:]
        for s in shots {
            guard let path = URLComponents(string: s.original)?.path, !path.isEmpty else { continue }
            let lower = path.lowercased()
            if junk.contains(where: { lower.contains($0) }) { continue }       // skip UI/theme images
            let file = (path as NSString).lastPathComponent
            var base = file, rank = 2
            if file.hasPrefix("thumb_")  { base = String(file.dropFirst(6)); rank = 0 }   // canonicalize to the full image
            else if file.hasPrefix("normal_") { base = String(file.dropFirst(7)); rank = 1 }
            let key = ((path as NSString).deletingLastPathComponent + "/" + base).lowercased()
            if let e = best[key], (e.rank, e.shot.length) >= (rank, s.length) { continue }  // keep the best version
            best[key] = Best(shot: s, base: base, rank: rank)
        }
        return best.values
            // Drop images known to be small. Unknown length (0) is *kept* — Common
            // Crawl never reports image size, and Wayback occasionally omits it; the
            // rank filter already steers us to the full image rather than a thumb.
            .filter { $0.shot.length >= minBytes || $0.shot.length == 0 }
            .compactMap { b -> Job? in
                guard let path = URLComponents(string: b.shot.original)?.path else { return nil }
                return Job(member: member(for: path), url: b.shot.original, name: sanitize(b.base), source: b.shot.source)
            }
            .sorted { $0.url < $1.url }      // deterministic order so a resume index is stable
    }

    nonisolated private static let junk = ["/themes/", "/templates/", "/images/", "/css/", "/js/", "/include",
                               "smilies", "/avatars/", "/ratings/", "/buttons/", "favicon", "/docs/", "/banner"]

    nonisolated private static func member(for path: String) -> String {
        // Check the whole normalized path (not just one segment) so a member name in
        // the album/category dir or filename is caught regardless of where it sits.
        let p = path.lowercased().replacingOccurrences(of: "[^a-z0-9]", with: "", options: .regularExpression)
        for (key, name) in members where p.contains(key) { return name }
        return "Other"
    }

    // MARK: - Download

    nonisolated private static func download(_ job: Job, into root: URL) async -> Bool {
        let dir = root.appendingPathComponent(job.member, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = await fetchBytes(job.source, original: job.url), !data.isEmpty else { return false }
        let dest = uniqueDestination(for: job.name, in: dir)
        guard (try? data.write(to: dest, options: .atomic)) != nil else { return false }
        // Date: the photo's own EXIF capture date if present (preserved), else the
        // archive snapshot date — never "now" (which would show as the current year).
        if let date = exifCaptureDate(of: dest) ?? archiveDate(job.source) {
            try? FileManager.default.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: dest.path)
        }
        return true
    }

    /// Fetch the original image bytes for a shot from whichever archive holds it.
    nonisolated private static func fetchBytes(_ source: Source, original: String) async -> Data? {
        switch source {
        case .wayback(let timestamp):
            // `id_` returns the original archived bytes (no Wayback rewriting/toolbar).
            guard let url = URL(string: "https://web.archive.org/web/\(timestamp)id_/\(original)") else { return nil }
            var req = URLRequest(url: url)
            req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            req.timeoutInterval = 120
            guard let (data, resp) = try? await session.data(for: req),
                  (resp as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) ?? true else { return nil }
            return data
        case .commonCrawl(let warc, let offset, let length):
            // Range-fetch just this record from the public S3 mirror, gunzip it, and
            // strip the WARC + HTTP headers to recover the raw image bytes.
            guard let url = URL(string: "https://data.commoncrawl.org/\(warc)") else { return nil }
            var req = URLRequest(url: url)
            req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            req.setValue("bytes=\(offset)-\(offset + length - 1)", forHTTPHeaderField: "Range")
            req.timeoutInterval = 120
            guard let (gz, resp) = try? await session.data(for: req),
                  (resp as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) ?? true,
                  let record = gunzip(gz) else { return nil }
            return warcBody(record)
        }
    }

    // MARK: - Common Crawl record decoding

    /// Inflate a gzip member (as stored in a WARC) to its raw bytes. Strips the
    /// 10-byte gzip header + optional extra fields, then runs raw DEFLATE through the
    /// Compression framework. The trailing 4-byte ISIZE sizes the output buffer.
    nonisolated private static func gunzip(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count > 18, bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 0x08 else { return nil }
        let flags = bytes[3]
        var i = 10
        if flags & 0x04 != 0 {                                  // FEXTRA
            guard i + 1 < bytes.count else { return nil }
            let xlen = Int(bytes[i]) | (Int(bytes[i + 1]) << 8); i += 2 + xlen
        }
        if flags & 0x08 != 0 { while i < bytes.count && bytes[i] != 0 { i += 1 }; i += 1 }   // FNAME
        if flags & 0x10 != 0 { while i < bytes.count && bytes[i] != 0 { i += 1 }; i += 1 }   // FCOMMENT
        if flags & 0x02 != 0 { i += 2 }                         // FHCRC
        guard i < bytes.count - 8 else { return nil }
        let deflated = Array(bytes[i..<(bytes.count - 8)])
        let isize = Int(bytes[bytes.count - 4]) | (Int(bytes[bytes.count - 3]) << 8)
            | (Int(bytes[bytes.count - 2]) << 16) | (Int(bytes[bytes.count - 1]) << 24)
        let capacity = max(isize, deflated.count * 4) + 1024
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { dst.deallocate() }
        let n = deflated.withUnsafeBufferPointer { src in
            compression_decode_buffer(dst, capacity, src.baseAddress!, src.count, nil, COMPRESSION_ZLIB)
        }
        return n > 0 ? Data(bytes: dst, count: n) : nil
    }

    /// Extract the payload from a WARC `response` record: skip the WARC headers and
    /// the embedded HTTP response headers (both terminated by a blank CRLF line) to
    /// the start of the body — i.e. the raw image bytes.
    nonisolated private static func warcBody(_ record: Data) -> Data? {
        let sep = Data("\r\n\r\n".utf8)
        guard let firstEnd = record.range(of: sep) else { return record }    // after WARC headers
        let afterWarc = firstEnd.upperBound
        if let secondEnd = record.range(of: sep, in: afterWarc..<record.endIndex) {
            return record.subdata(in: secondEnd.upperBound..<record.endIndex)  // after HTTP headers
        }
        return record.subdata(in: afterWarc..<record.endIndex)
    }

    // MARK: - Dates

    /// The image's embedded EXIF/TIFF capture date, if any (POSIX-locale parse).
    nonisolated private static func exifCaptureDate(of url: URL) -> Date? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"; f.timeZone = .current
        for case let s? in [exif?[kCGImagePropertyExifDateTimeOriginal] as? String,
                            exif?[kCGImagePropertyExifDateTimeDigitized] as? String,
                            tiff?[kCGImagePropertyTIFFDateTime] as? String] {
            if let d = f.date(from: s) { return d }
        }
        return nil
    }

    /// The archive snapshot date for a shot (Wayback timestamp, else nil).
    nonisolated private static func archiveDate(_ source: Source) -> Date? {
        guard case .wayback(let timestamp) = source else { return nil }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMddHHmmss"; f.timeZone = TimeZone(identifier: "UTC")
        return f.date(from: timestamp)
    }

    // MARK: - Helpers

    nonisolated private static func sanitize(_ name: String) -> String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "image.jpg" : String(cleaned.prefix(120))
    }

    nonisolated private static func uniqueDestination(for name: String, in folder: URL) -> URL {
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
