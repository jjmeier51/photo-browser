import Foundation

/// Persistent record of finished web-browser downloads (saved / failed / cancelled), so the
/// Downloads sheet can show history across launches and offer retry — the live list in
/// `WebController.downloads` is in-memory only and dies with the process.
///
/// Stored as one small JSON file in Application Support: NOT UserDefaults (keeps the defaults
/// plist lean — records carry URLs, captions and paths), and NOT inside the `thumbs` /
/// `folderCovers` cache directories, so no cache scheme is touched. A record carries everything
/// needed to re-run the download (URL, page, destination folder, scraped date/caption), which is
/// what makes retry-after-relaunch work. Capped at 200 records, newest first.
struct WebDownloadRecord: Codable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case video, file }
    enum Status: String, Codable, Sendable { case done, failed, cancelled }
    var id: UUID
    var name: String
    var urlString: String
    var pageURL: String
    var destPath: String?
    var folderPath: String
    var suggestedName: String?
    var caption: String?
    var captureDate: Date?
    var kind: Kind
    var status: Status
    var note: String?
    var date: Date
}

/// An actor so the JSON read/write stays off the main actor (CLAUDE.md: no blocking I/O on main).
actor WebDownloadHistory {
    static let shared = WebDownloadHistory()
    private var cache: [WebDownloadRecord]?

    private var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("webDownloadHistory.json")
    }

    func all() -> [WebDownloadRecord] { load() }

    /// The saved path of a *completed* download of this exact `urlString` into this `folderPath`,
    /// if one is on record. Drives true dedup: a re-download is a duplicate only when the same
    /// source URL was already saved to the same folder — not merely when some file there happens
    /// to share a name. (The old filename-only check wrongly collapsed distinct media that a site
    /// names with a constant page title, e.g. passes.com posts.)
    func completedDestination(urlString: String, folderPath: String) -> String? {
        load().first { $0.status == .done && $0.urlString == urlString && $0.folderPath == folderPath }?.destPath
    }

    func append(_ record: WebDownloadRecord) {
        var list = load()
        list.removeAll { $0.id == record.id }
        list.insert(record, at: 0)
        if list.count > 200 { list.removeLast(list.count - 200) }
        save(list)
    }

    func remove(id: UUID) {
        var list = load()
        list.removeAll { $0.id == id }
        save(list)
    }

    func clear() { save([]) }

    private func load() -> [WebDownloadRecord] {
        if let cache { return cache }
        let list = (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode([WebDownloadRecord].self, from: $0) } ?? []
        cache = list
        return list
    }

    private func save(_ list: [WebDownloadRecord]) {
        cache = list
        if let data = try? JSONEncoder().encode(list) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
