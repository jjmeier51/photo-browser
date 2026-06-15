import Foundation
import CoreLocation

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
    /// Results are cached in memory so re-navigating is instant (no re-fetch).
    nonisolated static func browse(category cat: Int?) async -> (categories: [Category], albums: [Album], note: String?) {
        let key = cat ?? -1
        if let hit = await GalleryCache.shared.browse(key) { return (hit.0, hit.1, nil) }
        let path = cat.map { "index.php?cat=\($0)" } ?? "index.php"
        guard let html = await fetchHTML(path) else { return ([], [], "Couldn’t reach taylorpictures.net.") }
        let categories = parseCategories(html, excluding: cat)
        let albums = parseAlbums(html)
        if !(categories.isEmpty && albums.isEmpty) { await GalleryCache.shared.setBrowse(key, (categories, albums)) }
        return (categories, albums, nil)
    }

    /// Every image in an album (across all Coppermine pages). Cached in memory.
    /// Page 1 determines the page count, then the rest are fetched concurrently.
    nonisolated static func images(inAlbum id: Int) async -> [Image] {
        if let hit = await GalleryCache.shared.images(id) { return hit }
        guard let first = await fetchHTML("thumbnails.php?album=\(id)&page=1") else { return [] }
        let last = min(maxPage(first), 200)
        var pages: [Int: [Image]] = [1: parseImages(first)]
        if last > 1 {
            await withTaskGroup(of: (Int, [Image]).self) { group in
                for p in 2...last { group.addTask { (p, parseImages(await fetchHTML("thumbnails.php?album=\(id)&page=\(p)") ?? "")) } }
                while let (p, imgs) = await group.next() { pages[p] = imgs }
            }
        }
        var all: [Image] = []; var seen = Set<String>()
        for p in 1...last { for img in (pages[p] ?? []) where seen.insert(img.fullURL.absoluteString).inserted { all.append(img) } }
        if !all.isEmpty { await GalleryCache.shared.setImages(id, all) }
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
        guard let (tmp, response) = try? await session.download(for: req),
              (response as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) ?? true else { return false }
        let dest = uniqueDestination(for: sanitize(image.filename), in: folder)
        return (try? FileManager.default.moveItem(at: tmp, to: dest)) != nil
    }

    // MARK: - Networking

    nonisolated static let userAgent = "Mozilla/5.0 (iPhone) PhotoBrowser"

    /// Shared session: a wide connection pool plus a big on-disk cache so thumbnails
    /// and pages load fast and survive relaunches. Images/pages on this gallery are
    /// effectively static, so `returnCacheDataElseLoad` is a big speed win.
    nonisolated static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.httpMaximumConnectionsPerHost = 12
        cfg.timeoutIntervalForRequest = 30
        cfg.urlCache = URLCache(memoryCapacity: 64 << 20, diskCapacity: 512 << 20)
        cfg.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: cfg)
    }()

    nonisolated private static func fetchHTML(_ path: String) async -> String? {
        guard let url = URL(string: host + path) else { return nil }
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await session.data(for: req) else { return nil }
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

    /// Album thumbnails, found by their Coppermine `thumb_` src directly (robust to
    /// theme differences in the surrounding anchor/pid markup). Deduped by URL.
    nonisolated private static func parseImages(_ html: String) -> [Image] {
        var out: [Image] = []; var seen = Set<String>()
        for g in matches(html, "<img[^>]+src=\"([^\"]*thumb_[^\"]+\\.(?:jpe?g|png|gif))\"") {
            let thumbPath = decode(g[1])
            guard let thumbURL = absolute(thumbPath), let fullURL = absolute(fullImagePath(from: thumbPath)),
                  seen.insert(fullURL.absoluteString).inserted else { continue }
            out.append(Image(pid: out.count, fullURL: fullURL, thumbURL: thumbURL, filename: fullURL.lastPathComponent))
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

// MARK: - Cross-referencing local photos against the gallery

/// Builds a filename→event index of the whole gallery (cached), then matches the
/// photos in a local folder by filename and writes the gallery's date + location
/// into each match. Same-file extension so it can reuse the private parsers above.
///
/// Honest limits (this is a fuzzy, untestable-here feature — expect tuning):
/// - Matching is by filename. Coppermine often uses generic sequential names
///   (001.jpg) that repeat across albums; when a name maps to albums that
///   *disagree* on date/place it's skipped rather than mis-dated. A content
///   (perceptual-hash) fallback isn't included because hashing all ~223k site
///   images on-device is impractical — filename matching is the scalable path.
/// - Date: the photo's own EXIF capture date wins when present; otherwise the
///   album/event date parsed from the album title (month-day + the year from the
///   category, or just the year). Location: the place parsed from the album title
///   (text after "… in …"), forward-geocoded to coordinates.
extension TaylorGallery {
    struct IndexEntry: Codable, Sendable, Equatable { var date: Double?; var place: String? }
    struct SiteIndex: Codable, Sendable {
        var byFilename: [String: [IndexEntry]] = [:]
        var albums = 0
        var images = 0
        var builtAt = Date().timeIntervalSince1970
    }
    struct CrossRefProgress: Sendable { var phase: String; var fraction: Double }
    struct CrossRefResult: Sendable {
        var updated = 0, ambiguous = 0, unmatched = 0, noData = 0, scanned = 0
        var indexImages = 0, indexAlbums = 0
        var sampleSite: String?, sampleLocal: String?
        var note: String?
    }

    // MARK: Index (crawl + cache)

    nonisolated static func buildIndex(progress: @escaping @Sendable (CrossRefProgress) -> Void) async -> SiteIndex {
        progress(CrossRefProgress(phase: "Listing albums…", fraction: 0))
        let albums = await collectAlbums { found, sections in
            progress(CrossRefProgress(phase: "Listing albums — \(found) found in \(sections) sections…", fraction: 0))
        }
        guard !albums.isEmpty else { return SiteIndex() }

        var index = SiteIndex()
        var done = 0, idx = 0
        await withTaskGroup(of: (Album, Int?, [Image]).self) { group in
            func addNext() {
                guard idx < albums.count else { return }
                let item = albums[idx]; idx += 1
                group.addTask { (item.album, item.year, await images(inAlbum: item.album.id)) }
            }
            for _ in 0..<min(6, albums.count) { addNext() }
            while let (album, year, imgs) = await group.next() {
                let entry = IndexEntry(date: parseAlbumDate(album.title, year: year)?.timeIntervalSince1970,
                                       place: parseAlbumPlace(album.title))
                for img in imgs {
                    index.byFilename[img.filename.lowercased(), default: []].append(entry)
                    index.images += 1
                }
                index.albums += 1
                done += 1
                progress(CrossRefProgress(phase: "Indexing \(done)/\(albums.count) albums…",
                                          fraction: Double(done) / Double(albums.count)))
                addNext()
            }
        }
        saveIndex(index)
        return index
    }

    /// Breadth-first walk of the category tree, carrying the current year (set by a
    /// 4-digit-year sub-category) so albums inherit it. A `visited` set is
    /// essential: every Coppermine page links back to all the other top categories
    /// and breadcrumbs, so without it the crawl re-fetches the same sections
    /// endlessly. `progress` reports (albums found, sections visited).
    private nonisolated static func collectAlbums(progress: @escaping @Sendable (Int, Int) -> Void) async -> [(album: Album, year: Int?)] {
        var out: [(album: Album, year: Int?)] = []
        var seenAlbums = Set<Int>()
        var visited = Set<Int>()
        var queue: [(cat: Int?, year: Int?, depth: Int)] = [(nil, nil, 0)]
        var head = 0
        while head < queue.count {
            let node = queue[head]; head += 1
            if let cat = node.cat {
                guard visited.insert(cat).inserted else { continue }   // fetch each section once
            }
            guard node.depth < 6 else { continue }
            let r = await browse(category: node.cat)
            for a in r.albums where seenAlbums.insert(a.id).inserted { out.append((a, node.year)) }
            for c in r.categories where !visited.contains(c.id) {
                let parsed = Int(c.title.trimmingCharacters(in: .whitespaces))
                let y = (parsed.map { (1990...2100).contains($0) } ?? false) ? parsed : node.year
                queue.append((c.id, y, node.depth + 1))
            }
            progress(out.count, visited.count)
        }
        return out
    }

    nonisolated static func parseAlbumDate(_ title: String, year: Int?) -> Date? {
        if let d = MetadataLoader.dateFromFilename(title) { return d }   // full yyyy-mm-dd etc.
        let cal = Calendar(identifier: .gregorian)
        if let y = year, let g = matches(title, "(?:^|[^0-9])([0-9]{1,2})[-/]([0-9]{1,2})(?:[^0-9]|$)").first,
           let mo = Int(g[1]), let day = Int(g[2]), (1...12).contains(mo), (1...31).contains(day) {
            var c = DateComponents(); c.year = y; c.month = mo; c.day = day; c.hour = 12
            return cal.date(from: c)
        }
        if let y = year {                                                // year known, day unknown
            var c = DateComponents(); c.year = y; c.month = 1; c.day = 1; c.hour = 12
            return cal.date(from: c)
        }
        return nil
    }

    nonisolated static func parseAlbumPlace(_ title: String) -> String? {
        guard let r = title.range(of: " in ", options: [.backwards, .caseInsensitive]) else { return nil }
        let place = String(title[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (3...60).contains(place.count) ? place : nil
    }

    nonisolated static func cachedIndex() -> SiteIndex? {
        guard let data = try? Data(contentsOf: indexCacheURL) else { return nil }
        return try? JSONDecoder().decode(SiteIndex.self, from: data)
    }

    private nonisolated static func saveIndex(_ index: SiteIndex) {
        let dir = indexCacheURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(index) { try? data.write(to: indexCacheURL) }
    }

    private nonisolated static var indexCacheURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("taylorIndex.json")
    }

    // MARK: Cross-reference + write

    nonisolated static func crossReference(folder: URL, index: SiteIndex,
                                           progress: @escaping @Sendable (CrossRefProgress) -> Void) async -> CrossRefResult {
        let fm = FileManager.default
        var files: [URL] = []
        if let walker = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
            for case let url as URL in walker where classify(url: url, isDirectory: false) == .image { files.append(url) }
        }
        var result = CrossRefResult(); result.scanned = files.count
        result.indexImages = index.images; result.indexAlbums = index.albums
        result.sampleSite = index.byFilename.keys.first
        result.sampleLocal = files.first?.lastPathComponent
        guard !files.isEmpty else { result.note = "No photos in this folder."; return result }

        var geocodeCache: [String: CLLocationCoordinate2D?] = [:]
        for (i, url) in files.enumerated() {
            defer { progress(CrossRefProgress(phase: "Updating \(i + 1)/\(files.count)…",
                                              fraction: Double(i + 1) / Double(files.count))) }
            let entries = index.byFilename[url.lastPathComponent.lowercased()] ?? []
            guard !entries.isEmpty else { result.unmatched += 1; continue }
            // Skip if the matched albums disagree (a generic filename in many events).
            guard Set(entries.map { "\($0.date ?? 0)|\($0.place ?? "")" }).count == 1, let entry = entries.first else {
                result.ambiguous += 1; continue
            }

            let localEntry = Entry(url: url, name: url.lastPathComponent, kind: .image, size: 0, modified: Date())
            let date = await MetadataLoader.captureDate(for: localEntry) ?? entry.date.map { Date(timeIntervalSince1970: $0) }
            var coord: CLLocationCoordinate2D?
            if let place = entry.place {
                if let cached = geocodeCache[place] { coord = cached }
                else { coord = await geocode(place); geocodeCache[place] = coord }
            }
            guard date != nil || coord != nil else { result.noData += 1; continue }
            if await FileActions.applyMetadata(date: date, location: coord, removeLocation: false, to: url) { result.updated += 1 }
        }
        return result
    }

    private nonisolated static func geocode(_ place: String) async -> CLLocationCoordinate2D? {
        guard let marks = try? await CLGeocoder().geocodeAddressString(place),
              let c = marks.first?.location?.coordinate, CLLocationCoordinate2DIsValid(c) else { return nil }
        return c
    }
}

/// In-memory cache of parsed browse/album results so the browser doesn't re-fetch
/// (and re-parse) a section every time it's revisited. Album image lists are
/// capped so the index crawl can't pin every album's images in memory.
private actor GalleryCache {
    static let shared = GalleryCache()

    private var browseByCat: [Int: ([TaylorGallery.Category], [TaylorGallery.Album])] = [:]
    private var imagesByAlbum: [Int: [TaylorGallery.Image]] = [:]
    private var imageOrder: [Int] = []
    private let imageCap = 60

    func browse(_ key: Int) -> ([TaylorGallery.Category], [TaylorGallery.Album])? { browseByCat[key] }
    func setBrowse(_ key: Int, _ value: ([TaylorGallery.Category], [TaylorGallery.Album])) { browseByCat[key] = value }

    func images(_ id: Int) -> [TaylorGallery.Image]? { imagesByAlbum[id] }
    func setImages(_ id: Int, _ value: [TaylorGallery.Image]) {
        if imagesByAlbum[id] == nil { imageOrder.append(id) }
        imagesByAlbum[id] = value
        while imageOrder.count > imageCap { imagesByAlbum[imageOrder.removeFirst()] = nil }
    }
}
