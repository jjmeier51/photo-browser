import Foundation

/// Salvages the (defunct) kardashianworld.net photo gallery from the Internet
/// Archive. The live domain is now parked, so this queries the Wayback Machine's
/// CDX API for every archived image under the domain, keeps the best version of
/// each (full-size over `normal_`/`thumb_`), groups them into per-member subfolders,
/// and downloads each via the Wayback `id_` raw endpoint (original bytes, no
/// toolbar). Best-effort and download-only, like the MEGA/taylorpictures features —
/// the Archive's coverage is partial, so failures are surfaced as notes.
///
/// All `nonisolated`: networking + file writes must stay off the main actor.
enum KardashianWorldDownloader {
    nonisolated static let host = "kardashianworld.net"
    nonisolated static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    struct Progress: Sendable { var phase: String; var fraction: Double; var done: Int; var total: Int }
    struct DownloadResult: Sendable {
        var downloaded = 0, failed = 0, members = 0
        var folderName: String?
        var note: String?
    }

    nonisolated static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.httpMaximumConnectionsPerHost = 6
        cfg.timeoutIntervalForRequest = 90
        cfg.urlCache = URLCache(memoryCapacity: 32 << 20, diskCapacity: 256 << 20)
        cfg.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: cfg)
    }()

    private struct Shot: Sendable { let original: String; let timestamp: String }
    private struct Job: Sendable { let member: String; let url: String; let timestamp: String; let name: String }

    /// Members in priority order (more-specific names first; "kim" last so it can't
    /// pre-empt the others). First path-segment match wins.
    nonisolated private static let members: [(key: String, name: String)] = [
        ("khloe", "Khloé Kardashian"), ("kourtney", "Kourtney Kardashian"),
        ("kendall", "Kendall Jenner"), ("kylie", "Kylie Jenner"),
        ("kris", "Kris Jenner"), ("caitlyn", "Caitlyn Jenner"), ("bruce", "Caitlyn Jenner"),
        ("rob", "Rob Kardashian"), ("kim", "Kim Kardashian")
    ]

    // MARK: - Run

    nonisolated static func run(into parent: URL,
                               progress: @escaping @Sendable (Progress) -> Void) async -> DownloadResult {
        var result = DownloadResult()
        progress(Progress(phase: "Searching the Internet Archive…", fraction: 0, done: 0, total: 0))
        let shots = await fetchCDX()
        guard !shots.isEmpty else {
            result.note = "Couldn’t find archived photos — the Internet Archive may have none, or be unreachable."
            return result
        }
        let jobs = buildJobs(shots)
        guard !jobs.isEmpty else { result.note = "No gallery photos were archived for this site."; return result }

        let root = uniqueDir(parent.appendingPathComponent("KardashianWorld", isDirectory: true))
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        result.folderName = root.lastPathComponent
        result.members = Set(jobs.map { $0.member }).count

        let total = jobs.count
        var done = 0
        await withTaskGroup(of: Bool.self) { group in
            var idx = 0
            let maxConcurrent = 4               // the Archive throttles; keep it modest
            func addNext() {
                guard idx < jobs.count else { return }
                let job = jobs[idx]; idx += 1
                group.addTask { await download(job, into: root) }
            }
            for _ in 0..<min(maxConcurrent, total) { addNext() }
            while let ok = await group.next() {
                if ok { result.downloaded += 1 } else { result.failed += 1 }
                done += 1
                progress(Progress(phase: "Downloading", fraction: Double(done) / Double(total), done: done, total: total))
                addNext()
            }
        }
        if result.downloaded == 0 { result.note = "Found \(total) archived photo(s) but none could be downloaded." }
        else if result.failed > 0 { result.note = "\(result.failed) image(s) couldn’t be downloaded from the Archive." }
        return result
    }

    // MARK: - Wayback CDX

    /// Every unique archived JPEG under the domain: `original` URL + best timestamp.
    nonisolated private static func fetchCDX() async -> [Shot] {
        let q = "https://web.archive.org/cdx/search/cdx?url=\(host)&matchType=domain"
            + "&filter=mimetype:image/jpeg&filter=statuscode:200&collapse=urlkey"
            + "&fl=original,timestamp&output=text"
        guard let url = URL(string: q) else { return [] }
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 180
        guard let (data, _) = try? await session.data(for: req),
              let text = String(data: data, encoding: .utf8) else { return [] }
        var shots: [Shot] = []
        for line in text.split(separator: "\n") {
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            guard cols.count >= 2 else { continue }
            shots.append(Shot(original: String(cols[0]), timestamp: String(cols[1])))
        }
        return shots
    }

    /// Best version of each unique gallery image (full > `normal_` > `thumb_`), as
    /// download jobs grouped by member. UI/theme assets are skipped.
    nonisolated private static func buildJobs(_ shots: [Shot]) -> [Job] {
        struct Best { var shot: Shot; var rank: Int; var base: String }
        var best: [String: Best] = [:]
        for s in shots {
            guard let path = URLComponents(string: s.original)?.path, !path.isEmpty else { continue }
            let lower = path.lowercased()
            if junk.contains(where: { lower.contains($0) }) { continue }       // skip UI/theme images
            let file = (path as NSString).lastPathComponent
            var base = file, rank = 2
            if file.hasPrefix("thumb_")  { base = String(file.dropFirst(6)); rank = 0 }
            else if file.hasPrefix("normal_") { base = String(file.dropFirst(7)); rank = 1 }
            let dir = (path as NSString).deletingLastPathComponent
            let key = (dir + "/" + base).lowercased()
            if let e = best[key], e.rank >= rank { continue }                  // already have an equal/better one
            best[key] = Best(shot: s, rank: rank, base: base)
        }
        return best.values.compactMap { b -> Job? in
            guard let path = URLComponents(string: b.shot.original)?.path else { return nil }
            return Job(member: member(for: path), url: b.shot.original, timestamp: b.shot.timestamp, name: sanitize(b.base))
        }
    }

    nonisolated private static let junk = ["/themes/", "/templates/", "/images/", "/css/", "/js/", "/include",
                               "smilies", "/avatars/", "/ratings/", "/buttons/", "favicon", "/docs/", "/banner"]

    nonisolated private static func member(for path: String) -> String {
        let segs = path.lowercased().split(separator: "/").map {
            $0.replacingOccurrences(of: "[^a-z0-9]", with: "", options: .regularExpression)
        }
        for (key, name) in members where segs.contains(where: { $0.contains(key) }) { return name }
        return "Other"
    }

    // MARK: - Download

    nonisolated private static func download(_ job: Job, into root: URL) async -> Bool {
        let dir = root.appendingPathComponent(job.member, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // `id_` returns the original archived bytes (no Wayback rewriting/toolbar).
        guard let url = URL(string: "https://web.archive.org/web/\(job.timestamp)id_/\(job.url)") else { return false }
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 120
        guard let (tmp, resp) = try? await session.download(for: req),
              (resp as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) ?? true else { return false }
        let dest = uniqueDestination(for: job.name, in: dir)
        return (try? FileManager.default.moveItem(at: tmp, to: dest)) != nil
    }

    // MARK: - Helpers

    nonisolated private static func sanitize(_ name: String) -> String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "image.jpg" : String(cleaned.prefix(120))
    }

    nonisolated private static func uniqueDir(_ dir: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else { return dir }
        var n = 2
        var candidate = dir.deletingLastPathComponent().appendingPathComponent(dir.lastPathComponent + " \(n)", isDirectory: true)
        while fm.fileExists(atPath: candidate.path) { n += 1; candidate = dir.deletingLastPathComponent().appendingPathComponent(dir.lastPathComponent + " \(n)", isDirectory: true) }
        return candidate
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
