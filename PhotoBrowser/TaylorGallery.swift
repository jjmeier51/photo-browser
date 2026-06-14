import Foundation

/// Read-only client for the taylorpictures.net photo gallery (a standard
/// Coppermine install). Lets the browser list categories/albums/images and
/// download whole albums into a drive folder — never uploads anything. This is
/// the app's *second* network feature (alongside MEGA); like MEGA it is a
/// best-effort scraper of someone else's site, so the HTML parsing is defensive
/// and failures are surfaced as notes rather than crashing.
///
/// Coppermine conventions this relies on:
/// - `index.php?cat=N` lists sub-categories (`index.php?cat=M`) and albums
///   (`thumbnails.php?album=ID`); the anchor text is the title.
/// - `thumbnails.php?album=ID&page=P` lists images, each an
///   `displayimage.php?...pid=PID` link wrapping an `<img src=".../thumb_FILE">`.
/// - The full-size image is the thumbnail path with the `thumb_` filename prefix
///   removed (same directory).
///
/// All work is `nonisolated` — networking + parsing + large file writes must stay
/// off the main actor.
enum TaylorGallery {
    nonisolated static let host = "https://taylorpictures.net/"

    struct Category: Identifiable, Sendable, Hashable { let id: Int; let title: String }
    struct Album: Identifiable, Sendable, Hashable { let id: Int; let title: String }
    struct Image: Identifiable, Sendable, Hashable {
        let pid: Int
        let fullURL: URL
        let thumbURL: URL
        let filename: String
        var id: Int { pid }
    }

    struct Progress: Sendable { var fraction: Double; var done: Int; var total: Int; var currentName: String }
    struct DownloadResult: Sendable { var downloaded: Int; var failed: Int; var folderName: String?; var note: String? }

    // MARK: - Browsing

    /// Sub-categories and albums under a category (`nil` = the gallery root).
    nonisolated static func browse(category cat: Int?) async -> (categories: [Category], albums: [Album], note: String?) {
        let path = cat.map { "index.php?cat=\($0)" } ?? "index.php"
        guard let html = await fetchHTML(path) else { return ([], [], "Couldn’t reach taylorpictures.net.") }
        return (parseCategories(html, excluding: cat), parseAlbums(html), nil)
    }

    /// Every image in an album (across all Coppermine pages).
    nonisolated static func images(inAlbum id: Int) async -> [Image] {
        var all: [Image] = []
        var seen = Set<Int>()
        var page = 1
        var lastPage = 1
        repeat {
            guard let html = await fetchHTML("thumbnails.php?album=\(id)&page=\(page)") else { break }
            if page == 1 { lastPage = maxPage(html) }
            let parsed = parseImages(html)
            if parsed.isEmpty { break }                         // safety: stop on an empty page
            for img in parsed where !seen.contains(img.pid) { seen.insert(img.pid); all.append(img) }
            page += 1
        } while page <= lastPage && page <= 200                 // hard cap, just in case
        return all
    }

    // MARK: - Downloading

    /// Downloads every full-size image of `album` into a new subfolder of `parent`
    /// (named after the album), 4 at a time. Returns counts so the caller can
    /// migrate nothing (these are fresh files) and reload.
    nonisolated static func downloadAlbum(_ album: Album, into parent: URL,
                                          progress: @escaping @Sendable (Progress) -> Void) async -> DownloadResult {
        progress(Progress(fraction: 0, done: 0, total: 0, currentName: "Listing…"))
        let images = await images(inAlbum: album.id)
        guard !images.isEmpty else { return DownloadResult(downloaded: 0, failed: 0, folderName: nil, note: "No images found in this album.") }

        let folder = uniqueDestination(for: sanitize(album.title.isEmpty ? "Album \(album.id)" : album.title), in: parent)
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else {
            return DownloadResult(downloaded: 0, failed: 0, folderName: nil, note: "Couldn’t create the album folder.")
        }

        let total = images.count
        var done = 0, downloaded = 0, failed = 0, index = 0
        let maxConcurrent = 4
        await withTaskGroup(of: Bool.self) { group in
            func addNext() {
                guard index < total else { return }
                let image = images[index]; index += 1
                group.addTask { await downloadImage(image, into: folder) }
            }
            for _ in 0..<min(maxConcurrent, total) { addNext() }
            while let ok = await group.next() {
                if ok { downloaded += 1 } else { failed += 1 }
                done += 1
                progress(Progress(fraction: Double(done) / Double(total), done: done, total: total, currentName: ""))
                addNext()
            }
        }
        return DownloadResult(downloaded: downloaded, failed: failed,
                              folderName: folder.lastPathComponent,
                              note: failed > 0 ? "\(failed) image(s) couldn’t be downloaded." : nil)
    }

    nonisolated private static func downloadImage(_ image: Image, into folder: URL) async -> Bool {
        var req = URLRequest(url: image.fullURL)
        req.setValue(host, forHTTPHeaderField: "Referer")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (tmp, response) = try? await URLSession.shared.download(for: req),
              (response as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) ?? true else { return false }
        let dest = uniqueDestination(for: sanitize(image.filename), in: folder)
        return (try? FileManager.default.moveItem(at: tmp, to: dest)) != nil
    }

    // MARK: - Networking

    nonisolated static let userAgent = "Mozilla/5.0 (iPhone) PhotoBrowser"

    nonisolated private static func fetchHTML(_ path: String) async -> String? {
        guard let url = URL(string: host + path) else { return nil }
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    // MARK: - Parsing (Coppermine HTML — best-effort, defensive)

    nonisolated private static func parseCategories(_ html: String, excluding current: Int?) -> [Category] {
        var seen = Set<Int>(); var out: [Category] = []
        for g in matches(html, "<a[^>]+href=\"index\\.php\\?cat=(\\d+)\"[^>]*>([\\s\\S]*?)</a>") {
            guard let id = Int(g[1]), id != current, !seen.contains(id) else { continue }
            let title = decode(stripTags(g[2]))
            guard !title.isEmpty else { continue }
            seen.insert(id); out.append(Category(id: id, title: title))
        }
        return out
    }

    nonisolated private static func parseAlbums(_ html: String) -> [Album] {
        // An album appears both as an image-wrapping anchor (no text) and a title
        // anchor (the text we want); keep the first non-empty title per album id.
        var titles: [Int: String] = [:]; var order: [Int] = []
        for g in matches(html, "<a[^>]+href=\"thumbnails\\.php\\?album=(\\d+)\"[^>]*>([\\s\\S]*?)</a>") {
            guard let id = Int(g[1]) else { continue }
            let title = decode(stripTags(g[2]))
            if titles[id] == nil { order.append(id) }
            if (titles[id] ?? "").isEmpty, !title.isEmpty { titles[id] = title }
            else if titles[id] == nil { titles[id] = "" }
        }
        return order.map { Album(id: $0, title: titles[$0] ?? "") }
    }

    nonisolated private static func parseImages(_ html: String) -> [Image] {
        var out: [Image] = []; var seen = Set<Int>()
        for g in matches(html, "href=\"displayimage\\.php\\?[^\"]*?pid=(\\d+)[^\"]*\"[^>]*>\\s*<img[^>]+src=\"([^\"]+)\"") {
            guard let pid = Int(g[1]), !seen.contains(pid) else { continue }
            let thumbPath = decode(g[2])
            guard let thumbURL = absolute(thumbPath), let fullURL = absolute(fullImagePath(from: thumbPath)) else { continue }
            seen.insert(pid)
            out.append(Image(pid: pid, fullURL: fullURL, thumbURL: thumbURL, filename: fullURL.lastPathComponent))
        }
        return out
    }

    /// The full-size path for a Coppermine thumbnail: strip the `thumb_` filename prefix.
    nonisolated private static func fullImagePath(from thumb: String) -> String {
        var comps = thumb.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard var file = comps.last else { return thumb }
        if file.hasPrefix("thumb_") { file = String(file.dropFirst("thumb_".count)) }
        comps[comps.count - 1] = file
        return comps.joined(separator: "/")
    }

    nonisolated private static func maxPage(_ html: String) -> Int {
        var maxP = 1
        for g in matches(html, "[?&]page=(\\d+)") { if let p = Int(g[1]) { maxP = max(maxP, p) } }
        return maxP
    }

    // MARK: - Small helpers

    /// Returns each match's capture groups (index 0 = whole match); absent → "".
    nonisolated private static func matches(_ s: String, _ pattern: String) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { m in
            (0..<m.numberOfRanges).map { i in
                let r = m.range(at: i); return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
        }
    }

    nonisolated private static func stripTags(_ s: String) -> String {
        (try? NSRegularExpression(pattern: "<[^>]+>"))
            .map { $0.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: " ") }?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? s
    }

    nonisolated private static func decode(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#039;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func absolute(_ path: String) -> URL? {
        if path.hasPrefix("http") { return URL(string: path) }
        return URL(string: host + path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }

    nonisolated private static func sanitize(_ name: String) -> String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "-")
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled" : String(trimmed.prefix(120))
    }

    nonisolated private static func uniqueDestination(for name: String, in folder: URL) -> URL {
        let fm = FileManager.default
        var dest = folder.appendingPathComponent(name.isEmpty ? "item" : name)
        let base = dest.deletingPathExtension().lastPathComponent
        let ext = dest.pathExtension
        var n = 1
        while fm.fileExists(atPath: dest.path) {
            dest = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return dest
    }
}
