import Foundation

/// Reaction scores of SimpCity downloads, for the folder view's "Most reactions" sort and the score on
/// each tile. They live in the folder's shared record (`<person>/simpcity/.simpcity.json`, `reactions`),
/// written by this app's downloader and by Safe Finder (its downloads, and its "Get Reaction Scores",
/// which reads the threads again for them) — see `SimpCity.Record.scores`: a file takes its post's score.
///
/// A record can be megabytes, so it's parsed off the main actor and once per change: the parsed scores
/// are kept by folder with the record's modification date and size, and read again only when either
/// moves. Everything here is `nonisolated` and called from detached tasks.
nonisolated enum SimpCityScores {
    nonisolated(unsafe) private static var cache: [String: (stamp: String, scores: [String: Int])] = [:]
    private static let lock = NSLock()

    /// Whether `folder` holds a SimpCity record — where the sort is offered.
    static func hasRecord(in folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(SimpCity.recordName).path)
    }

    /// File name → reaction score for the files in `folder` (empty without a record, or before any score
    /// was read).
    static func scores(in folder: URL) -> [String: Int] {
        let file = folder.appendingPathComponent(SimpCity.recordName)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path) else { return [:] }
        let stamp = "\((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)|\((attrs[.size] as? NSNumber)?.int64Value ?? 0)"
        lock.lock()
        let hit = cache[folder.path]
        lock.unlock()
        if let hit, hit.stamp == stamp { return hit.scores }
        let scores = SimpCity.Record(folder: folder).scores()
        lock.lock()
        cache[folder.path] = (stamp, scores)
        lock.unlock()
        return scores
    }

    /// File → reaction score for these files (one record read per folder they're in); files with none
    /// are left out.
    static func scores(for urls: [URL]) -> [URL: Int] {
        var byFolder: [URL: [URL]] = [:]
        for u in urls { byFolder[u.deletingLastPathComponent(), default: []].append(u) }
        var out: [URL: Int] = [:]
        for (folder, files) in byFolder {
            let s = scores(in: folder)
            guard !s.isEmpty else { continue }
            for f in files { if let n = s[f.lastPathComponent] { out[f] = n } }
        }
        return out
    }
}
