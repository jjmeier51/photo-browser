import Foundation
import CoreLocation
import ImageIO
import CoreGraphics

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
    struct Album: Identifiable, Sendable, Hashable { let id: Int; let title: String; var thumbURL: URL? = nil }
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
    /// Coppermine paginates the album list within a category, so we read *every*
    /// album page (not just the first) — otherwise large categories lose all but
    /// their first page of albums. Cached in memory so re-navigating is instant.
    nonisolated static func browse(category cat: Int?) async -> (categories: [Category], albums: [Album], note: String?) {
        let key = cat ?? -1
        if let hit = await GalleryCache.shared.browse(key) { return (hit.0, hit.1, nil) }
        func path(_ p: Int) -> String {
            if let cat { return "index.php?cat=\(cat)&page=\(p)" }
            return "index.php?page=\(p)"
        }
        guard let first = await fetchHTML(path(1)) else { return ([], [], "Couldn’t reach taylorpictures.net.") }
        let categories = parseCategories(first, excluding: cat)
        var byID: [Int: Album] = [:]; var order: [Int] = []
        @discardableResult func add(_ list: [Album]) -> Int {
            var added = 0
            for a in list where byID[a.id] == nil { byID[a.id] = a; order.append(a.id); added += 1 }
            return added
        }
        add(parseAlbums(first))
        var p = 2
        while p <= 500 {                                // keep paging until one adds nothing new
            guard let html = await fetchHTML(path(p)) else { break }
            if add(parseAlbums(html)) == 0 { break }
            p += 1
        }
        let albums = order.compactMap { byID[$0] }
        if !(categories.isEmpty && albums.isEmpty) { await GalleryCache.shared.setBrowse(key, (categories, albums)) }
        return (categories, albums, nil)
    }

    /// Every image in an album. Pages until one adds nothing new, so a windowed
    /// thumbnail pager can't truncate a big album. Cached in memory.
    nonisolated static func images(inAlbum id: Int) async -> [Image] {
        if let hit = await GalleryCache.shared.images(id) { return hit }
        var all: [Image] = []; var seen = Set<String>()
        var p = 1
        while p <= 500 {
            guard let html = await fetchHTML("thumbnails.php?album=\(id)&page=\(p)") else { break }
            var added = 0
            for img in parseImages(html) where seen.insert(img.fullURL.absoluteString).inserted { all.append(img); added += 1 }
            if added == 0 { break }
            p += 1
        }
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
        // The event date parsed from the album title (gallery JPGs usually carry no
        // EXIF date), written into each image so they don't default to "today".
        let albumDate = parseAlbumDate(album.title, year: nil)

        let total = images.count
        var done = 0, downloaded = 0, failed = 0, index = 0
        let maxConcurrent = 4
        await withTaskGroup(of: Bool.self) { group in
            func addNext() {
                guard index < total else { return }
                let image = images[index]; index += 1
                group.addTask { await downloadImage(image, into: folder, albumDate: albumDate) }
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

    nonisolated private static func downloadImage(_ image: Image, into folder: URL, albumDate: Date?) async -> Bool {
        var req = URLRequest(url: image.fullURL)
        req.setValue(host, forHTTPHeaderField: "Referer")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: req),
              (response as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) ?? true,
              data.count >= 256 else { return false }
        let dest = uniqueDestination(for: sanitize(image.filename), in: folder)
        return saveImage(data, to: dest, date: albumDate)
    }

    /// Writes the bytes, embedding the album date as the capture date when the image
    /// has no EXIF date of its own (the usual case for gallery JPGs) and stamping the
    /// file's dates so it never shows up as "today".
    nonisolated private static func saveImage(_ data: Data, to dest: URL, date: Date?) -> Bool {
        if let src = CGImageSourceCreateWithData(data as CFData, nil), let type = CGImageSourceGetType(src) {
            let existing = exifDate(src)
            if existing == nil, let date {
                var props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
                let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
                f.dateFormat = "yyyy:MM:dd HH:mm:ss"; f.timeZone = .current
                let s = f.string(from: date)
                var exif = (props[kCGImagePropertyExifDictionary] as? [CFString: Any]) ?? [:]
                exif[kCGImagePropertyExifDateTimeOriginal] = s; exif[kCGImagePropertyExifDateTimeDigitized] = s
                props[kCGImagePropertyExifDictionary] = exif
                var tiff = (props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]) ?? [:]
                tiff[kCGImagePropertyTIFFDateTime] = s; props[kCGImagePropertyTIFFDictionary] = tiff
                if let d = CGImageDestinationCreateWithURL(dest as CFURL, type, 1, nil) {
                    CGImageDestinationAddImageFromSource(d, src, 0, props as CFDictionary)
                    if CGImageDestinationFinalize(d) { setFileDate(dest, date); return true }
                }
            }
            // Already had a date (keep its bytes) or embedding failed — fall through.
            if (try? data.write(to: dest, options: .atomic)) != nil { setFileDate(dest, existing ?? date); return true }
            return false
        }
        guard (try? data.write(to: dest, options: .atomic)) != nil else { return false }
        setFileDate(dest, date)
        return true
    }

    /// The image's embedded EXIF/TIFF capture date, if any.
    nonisolated private static func exifDate(_ src: CGImageSource) -> Date? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
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

    nonisolated private static func setFileDate(_ url: URL, _ date: Date?) {
        guard let date else { return }
        try? FileManager.default.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: url.path)
    }

    // MARK: - Networking

    // A realistic mobile-Safari User-Agent: the server varies on it (`Vary:
    // User-Agent`) and some hosts/WAFs reject unfamiliar agents outright, which on
    // device surfaced as a connection-level "couldn't reach" throw.
    nonisolated static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

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
        func request(ignoreCache: Bool) -> URLRequest {
            var req = URLRequest(url: url)
            req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            req.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
            req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
            if ignoreCache { req.cachePolicy = .reloadIgnoringLocalCacheData }
            return req
        }
        // One retry (bypassing the cache) so a single network blip — the only thing
        // that makes this throw — doesn't surface as a hard "couldn't reach".
        for attempt in 0..<2 {
            if let (data, _) = try? await session.data(for: request(ignoreCache: attempt > 0)) {
                return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
            }
        }
        return nil
    }

    // MARK: - Parsing (Coppermine HTML — best-effort, defensive)

    nonisolated private static func parseCategories(_ html: String, excluding current: Int?) -> [Category] {
        var seen = Set<Int>(); var out: [Category] = []
        for g in matches(html, "<a[^>]+href=[\"']?index\\.php\\?cat=(\\d+)[^>]*>([\\s\\S]*?)</a>") {
            guard let id = Int(g[1]), id != current, !seen.contains(id) else { continue }
            let title = decode(stripTags(g[2]))
            guard !title.isEmpty else { continue }
            seen.insert(id); out.append(Category(id: id, title: title))
        }
        return out
    }

    nonisolated private static func parseAlbums(_ html: String) -> [Album] {
        // An album appears both as an image-wrapping anchor (the cover thumbnail) and
        // a title anchor (the text we want); keep the first non-empty title per id and
        // the first cover thumbnail (the album's `thumb_…` image on the listing page).
        var titles: [Int: String] = [:]; var order: [Int] = []; var covers: [Int: URL] = [:]
        for g in matches(html, "<a[^>]+href=[\"']?thumbnails\\.php\\?album=(\\d+)[^>]*>([\\s\\S]*?)</a>") {
            guard let id = Int(g[1]) else { continue }
            let title = decode(stripTags(g[2]))
            if titles[id] == nil { order.append(id) }
            if (titles[id] ?? "").isEmpty, !title.isEmpty { titles[id] = title }
            else if titles[id] == nil { titles[id] = "" }
            if covers[id] == nil,
               let m = matches(g[2], "<img[^>]+src=\"([^\"]+thumb_[^\"]+)\"").first,
               let u = absolute(decode(m[1])) { covers[id] = u }
        }
        return order.map { Album(id: $0, title: titles[$0] ?? "", thumbURL: covers[$0]) }
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
/// - Default matching is by filename (generic names like 001.jpg that map to
///   conflicting events are skipped, not mis-dated). For renamed local files an
///   optional content match downloads and perceptual-hashes every site thumbnail
///   during the build (much slower) and matches by hash distance.
/// - Date: the photo's own EXIF capture date wins when present; otherwise the
///   album/event date parsed from the album title (month-day + the year from the
///   category, or just the year). Location: the place parsed from the album title
///   (text after "… in …"), forward-geocoded to coordinates.
extension TaylorGallery {
    struct IndexEntry: Codable, Sendable, Equatable { var date: Double?; var place: String? }
    struct AlbumRef: Codable, Sendable { var id: Int; var title: String; var year: Int? }
    /// A site image's perceptual hash + event, for matching renamed local files.
    struct HashEntry: Codable, Sendable { var hash: UInt64; var date: Double?; var place: String? }
    struct SiteIndex: Codable, Sendable {
        var byFilename: [String: [IndexEntry]] = [:]
        var hashes: [HashEntry] = []          // only populated when content matching is on
        var albumRefs: [AlbumRef] = []        // the full album list (so a resume skips re-listing)
        var doneAlbumIDs: Set<Int> = []       // albums already indexed (resume skips them)
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

    /// Builds (or resumes) the gallery index. The album list and per-album progress
    /// are saved to disk periodically, so exiting mid-crawl no longer reindexes from
    /// scratch — pass the cached index to resume. With `matchContent`, each image's
    /// thumbnail is also perceptual-hashed so renamed local files can still match.
    nonisolated static func buildIndex(resuming prior: SiteIndex?, matchContent: Bool,
                                       progress: @escaping @Sendable (CrossRefProgress) -> Void) async -> SiteIndex {
        var index = prior ?? SiteIndex()

        // 1. Album list — (re)crawl the category tree and MERGE any newly-found albums
        //    into the saved list, so resuming picks up albums a previous (truncated)
        //    crawl missed without re-indexing the ones already done. Already-indexed
        //    albums (doneAlbumIDs) are skipped in step 2, so only the new ones cost time.
        progress(CrossRefProgress(phase: "Listing albums…", fraction: 0))
        let collected = await collectAlbums { found, sections in
            progress(CrossRefProgress(phase: "Listing albums — \(found) found in \(sections) sections…", fraction: 0))
        }
        var seenRefs = Set(index.albumRefs.map { $0.id })
        for c in collected where seenRefs.insert(c.album.id).inserted {
            index.albumRefs.append(AlbumRef(id: c.album.id, title: c.album.title, year: c.year))
        }
        saveIndex(index)
        let total = index.albumRefs.count
        guard total > 0 else { return index }

        // 2. Index the albums that aren't done yet (concurrently), saving periodically.
        let pending = index.albumRefs.filter { !index.doneAlbumIDs.contains($0.id) }
        var idx = 0, sinceSave = 0
        await withTaskGroup(of: (AlbumRef, [Image], [UInt64]).self) { group in
            func addNext() {
                guard idx < pending.count else { return }
                let ref = pending[idx]; idx += 1
                group.addTask {
                    let imgs = await images(inAlbum: ref.id)
                    var hs: [UInt64] = []
                    if matchContent { for img in imgs { hs.append(await imageHash(img.thumbURL) ?? 0) } }
                    return (ref, imgs, hs)
                }
            }
            for _ in 0..<min(6, pending.count) { addNext() }
            while let (ref, imgs, hs) = await group.next() {
                let entry = IndexEntry(date: parseAlbumDate(ref.title, year: ref.year)?.timeIntervalSince1970,
                                       place: parseAlbumPlace(ref.title))
                for (i, img) in imgs.enumerated() {
                    index.byFilename[img.filename.lowercased(), default: []].append(entry)
                    index.images += 1
                    if matchContent, i < hs.count, hs[i] != 0 {
                        index.hashes.append(HashEntry(hash: hs[i], date: entry.date, place: entry.place))
                    }
                }
                index.doneAlbumIDs.insert(ref.id)
                index.albums = index.doneAlbumIDs.count
                sinceSave += 1
                if sinceSave >= 50 { sinceSave = 0; saveIndex(index) }   // persist progress
                let done = index.doneAlbumIDs.count
                progress(CrossRefProgress(phase: "Indexing \(done)/\(total) albums…", fraction: Double(done) / Double(total)))
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
            // 1. Filename match.
            var matchDate: Double?; var matchPlace: String?; var matched = false
            let entries = index.byFilename[url.lastPathComponent.lowercased()] ?? []
            if !entries.isEmpty {
                if Set(entries.map { "\($0.date ?? 0)|\($0.place ?? "")" }).count == 1, let e = entries.first {
                    matchDate = e.date; matchPlace = e.place; matched = true
                } else { result.ambiguous += 1; continue }   // generic name in conflicting events
            }
            // 2. Content (perceptual-hash) match for renamed files, if hashes exist.
            //    A coarse dHash means visually-similar shots from *different* events can
            //    land a few bits apart, which was assigning wrong dates (e.g. an Eras
            //    Tour photo dated 2007). So only accept a *close* match (≤6 bits) whose
            //    near-equal candidates all agree on the date; conflicting events → skip.
            if !matched, !index.hashes.isEmpty, let lh = await localHash(url) {
                var bestD = 65
                var near: [(entry: HashEntry, dist: Int)] = []
                for he in index.hashes {
                    let d = (lh ^ he.hash).nonzeroBitCount
                    if d < bestD { bestD = d }
                    if d <= 8 { near.append((he, d)) }
                }
                if bestD <= 6 {
                    let window = near.filter { $0.dist <= bestD + 2 }       // candidates ~as close as the best
                    let days = Set(window.compactMap { $0.entry.date.map { Int($0 / 86400) } })
                    if days.count <= 1, let pick = window.min(by: { $0.dist < $1.dist }) {
                        matchDate = pick.entry.date; matchPlace = pick.entry.place; matched = true
                    } else { result.ambiguous += 1; continue }              // similar but conflicting events
                }
            }
            guard matched else { result.unmatched += 1; continue }

            let localEntry = Entry(url: url, name: url.lastPathComponent, kind: .image, size: 0, modified: Date())
            let date = await MetadataLoader.captureDate(for: localEntry) ?? matchDate.map { Date(timeIntervalSince1970: $0) }
            var coord: CLLocationCoordinate2D?
            if let place = matchPlace {
                if let cached = geocodeCache[place] { coord = cached }
                else { coord = await geocode(place); geocodeCache[place] = coord }
            }
            guard date != nil || coord != nil else { result.noData += 1; continue }
            if await FileActions.applyMetadata(date: date, location: coord, removeLocation: false, to: url) { result.updated += 1 }
        }
        return result
    }

    // MARK: Perceptual hashing (renamed-file content match)

    /// 64-bit difference hash (dHash) of a remote thumbnail (cached via `session`).
    private nonisolated static func imageHash(_ url: URL) async -> UInt64? {
        var req = URLRequest(url: url)
        req.setValue(host, forHTTPHeaderField: "Referer")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await session.data(for: req),
              let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        return dHash(cg)
    }

    private nonisolated static func localHash(_ url: URL) async -> UInt64? {
        await Task.detached(priority: .utility) {
            let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                         kCGImageSourceCreateThumbnailWithTransform: true,
                                         kCGImageSourceThumbnailMaxPixelSize: 64]
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
            return dHash(cg)
        }.value
    }

    private nonisolated static func dHash(_ cg: CGImage) -> UInt64 {
        let w = 9, h = 8
        var px = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return 0 }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var hash: UInt64 = 0, bit: UInt64 = 0
        for y in 0..<h { for x in 0..<(w - 1) {
            if px[y * w + x] < px[y * w + x + 1] { hash |= (1 << bit) }
            bit += 1
        }}
        return hash
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
