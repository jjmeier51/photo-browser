import Foundation
import CoreLocation
import ImageIO
import CoreGraphics

/// Read-only client for accesskardashian.com.br — a Brazilian Coppermine photo
/// gallery, the successor to the (defunct) kardashianworld.net feature. It crawls
/// one member's gallery (Kim, Kourtney, Kendall, or Kylie), downloads every
/// full-size photo into that member's folder, and carries across the gallery's
/// metadata: the category it came from (Candids / Photoshoots / …, applied as a
/// label), the album date (written into EXIF when the file has none), any album
/// location, and per-image captions. Never uploads — the app's third download-only
/// network feature, alongside MEGA and taylorpictures.
///
/// Coppermine conventions (same as `TaylorGallery`): `index.php?cat=N` lists
/// sub-categories + albums; `thumbnails.php?album=ID&page=P` lists images as
/// `thumb_…` thumbnails whose full-size path drops the `thumb_` filename prefix.
/// The gallery is under `/galeria/`, and the site is Portuguese, so category names
/// are normalized to English and captions are translated by the caller (the view,
/// via Apple's on-device Translation on iOS 18+).
///
/// All work is `nonisolated`: networking + parsing + EXIF writes + large file
/// writes must stay off the main actor. Best-effort and defensive — failures are
/// surfaced as notes, never crashes.
enum AccessKardashian {
    nonisolated static let host = "https://accesskardashian.com.br/galeria/"

    // MARK: - Members

    struct Member: Identifiable, Sendable, Hashable {
        let name: String          // folder name, e.g. "Kendall Jenner"
        let token: String         // lowercased name fragment used to find her gallery
        let knownCat: Int?        // category id when we know it (avoids discovery)
        let birthday: DateComponents
        var id: String { name }
    }

    /// The four members the user asked for (no Khloé, no Kris). Kendall's gallery id
    /// (cat=6) is known; the others are discovered by name at run time.
    nonisolated static let members: [Member] = [
        Member(name: "Kim Kardashian", token: "kim", knownCat: nil,
               birthday: DateComponents(year: 1980, month: 10, day: 21)),
        Member(name: "Kourtney Kardashian", token: "kourtney", knownCat: nil,
               birthday: DateComponents(year: 1979, month: 4, day: 18)),
        Member(name: "Kendall Jenner", token: "kendall", knownCat: 6,
               birthday: DateComponents(year: 1995, month: 11, day: 3)),
        Member(name: "Kylie Jenner", token: "kylie", knownCat: nil,
               birthday: DateComponents(year: 1997, month: 8, day: 10)),
    ]

    nonisolated static func birthdayDate(_ m: Member) -> Date? {
        Calendar(identifier: .gregorian).date(from: m.birthday)
    }

    // MARK: - Public types

    struct Progress: Sendable { var phase: String; var fraction: Double; var done: Int; var total: Int }

    struct Result: Sendable {
        var downloaded = 0, skipped = 0, failed = 0, total = 0
        var cancelled = false
        var note: String?
        /// Applied by the caller on the main actor (Library is `@MainActor`):
        var captions: [String: String] = [:]           // path → caption (Portuguese; the view translates)
        var labelsByCategory: [String: [String]] = [:]  // category label → [path]
    }

    private struct Coord: Sendable { let lat: Double; let lng: Double }
    private struct Planned: Sendable {
        let fullURL: URL
        var destName: String
        let category: String
        let date: Date?
        let place: String?
        let caption: String?
    }

    nonisolated static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
    nonisolated static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.httpMaximumConnectionsPerHost = 12       // blazing-fast: a wide connection pool
        cfg.timeoutIntervalForRequest = 45
        cfg.urlCache = URLCache(memoryCapacity: 64 << 20, diskCapacity: 512 << 20)
        cfg.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: cfg)
    }()

    // MARK: - Run

    /// Crawls `member`'s gallery and downloads it into `folder`. `overwrite` re-fetches
    /// images already on disk (Re-download); otherwise existing files are skipped
    /// (Fetch New / Resume). `isCancelled` is polled so the UI can pause/cancel —
    /// everything already downloaded stays put, and a later run resumes by skipping it.
    nonisolated static func run(member: Member, into folder: URL, overwrite: Bool,
                                progress: @escaping @Sendable (Progress) -> Void,
                                isCancelled: @escaping @Sendable () -> Bool) async -> Result {
        var result = Result()
        progress(Progress(phase: "Finding \(member.name)’s gallery…", fraction: 0, done: 0, total: 0))
        guard let rootCat = await memberRootCat(member) else {
            result.note = "Couldn’t find \(member.name)’s gallery on accesskardashian.com.br."
            return result
        }
        progress(Progress(phase: "Listing albums…", fraction: 0, done: 0, total: 0))
        var plan = await buildPlan(rootCat: rootCat, member: member)
        guard !plan.isEmpty else {
            result.note = "No photos found in \(member.name)’s gallery."
            return result
        }
        // Deterministic order (stable across runs so resume lines up) + unique flat
        // filenames, since everything lands directly in the member folder.
        plan.sort { $0.fullURL.absoluteString < $1.fullURL.absoluteString }
        assignDestNames(&plan)
        result.total = plan.count

        // Pre-geocode the distinct album places once (CLGeocoder is rate-limited).
        let distinctPlaces = Set(plan.compactMap(\.place))
        var coords: [String: Coord?] = [:]
        if !distinctPlaces.isEmpty {
            progress(Progress(phase: "Locating \(distinctPlaces.count) place(s)…", fraction: 0, done: 0, total: plan.count))
        }
        for place in distinctPlaces where !isCancelled() { coords[place] = await geocode(place) }

        if isCancelled() { result.cancelled = true; return result }

        let total = plan.count
        var done = 0
        // Collected here (off-actor) and handed back for one batched persist.
        var captions: [String: String] = [:]
        var labels: [String: [String]] = [:]

        await withTaskGroup(of: (ok: Bool, skipped: Bool, path: String?, category: String, caption: String?).self) { group in
            var idx = 0
            let maxConcurrent = 10              // many images at once — speed is the goal
            func addNext() {
                guard idx < plan.count, !isCancelled() else { return }
                let p = plan[idx]; idx += 1
                let coord = p.place.flatMap { coords[$0] ?? nil }
                group.addTask {
                    let dest = folder.appendingPathComponent(p.destName)
                    if !overwrite, FileManager.default.fileExists(atPath: dest.path) {
                        return (true, true, dest.path, p.category, p.caption)   // already have it
                    }
                    let ok = await downloadImage(p.fullURL, to: dest, date: p.date, coord: coord)
                    return (ok, false, ok ? dest.path : nil, p.category, p.caption)
                }
            }
            for _ in 0..<min(maxConcurrent, total) { addNext() }
            while let r = await group.next() {
                if r.skipped { result.skipped += 1 } else if r.ok { result.downloaded += 1 } else { result.failed += 1 }
                if let path = r.path {
                    labels[r.category, default: []].append(path)
                    if let cap = r.caption, !cap.isEmpty { captions[path] = cap }
                }
                done += 1
                progress(Progress(phase: "Downloading", fraction: Double(done) / Double(total), done: done, total: total))
                addNext()
            }
        }
        result.captions = captions
        result.labelsByCategory = labels
        result.cancelled = isCancelled()
        if result.downloaded == 0 && result.skipped == 0 { result.note = "Nothing could be downloaded from the gallery." }
        else if result.failed > 0 { result.note = "\(result.failed) photo(s) couldn’t be downloaded." }
        return result
    }

    /// Flat layout: ensure every planned image has a unique filename in the member
    /// folder (Coppermine filenames can collide across albums).
    nonisolated private static func assignDestNames(_ plan: inout [Planned]) {
        var used = Set<String>()
        for i in plan.indices {
            var name = sanitize(plan[i].fullURL.lastPathComponent)
            if used.contains(name.lowercased()) {
                let base = (name as NSString).deletingPathExtension
                let ext = (name as NSString).pathExtension
                var n = 2
                repeat {
                    name = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"; n += 1
                } while used.contains(name.lowercased())
            }
            used.insert(name.lowercased())
            plan[i].destName = name
        }
    }

    // MARK: - Member discovery

    /// The category id of `member`'s gallery — her known id, else found by matching
    /// her name among the root categories (and one level down).
    nonisolated private static func memberRootCat(_ member: Member) async -> Int? {
        if let c = member.knownCat { return c }
        let root = await browse(category: nil)
        if let hit = root.categories.first(where: { norm($0.title).contains(member.token) }) { return hit.id }
        for c in root.categories {
            let sub = await browse(category: c.id)
            if let hit = sub.categories.first(where: { norm($0.title).contains(member.token) }) { return hit.id }
        }
        return nil
    }

    // MARK: - Crawl + plan

    /// Every full-size image under the member's category, tagged with its category
    /// label, album date, album place, and (best-effort) caption. The crawl is kept
    /// inside the member's subtree by *which child categories it follows*: never into
    /// another member's name, never up into a parent/root section. (Coppermine prints
    /// the category menu + breadcrumb on every page, so we can't prune by what a page
    /// lists — only by what we choose to enqueue.)
    nonisolated private static func buildPlan(rootCat: Int, member: Member) async -> [Planned] {
        let others = Set(members.map(\.token)).subtracting([member.token])
        struct Node { let cat: Int; let category: String?; let year: Int?; let depth: Int }
        struct AlbumMeta: Sendable { let id: Int; let title: String; let category: String; let year: Int? }

        var albums: [AlbumMeta] = []
        var seenAlbums = Set<Int>()
        var visited = Set<Int>()
        var queue = [Node(cat: rootCat, category: nil, year: nil, depth: 0)]
        var head = 0
        while head < queue.count {
            let node = queue[head]; head += 1
            guard visited.insert(node.cat).inserted, node.depth < 6 else { continue }
            let r = await browse(category: node.cat)

            for a in r.albums where seenAlbums.insert(a.id).inserted {
                albums.append(AlbumMeta(id: a.id, title: a.title, category: node.category ?? "Others", year: node.year))
            }
            for c in r.categories where !visited.contains(c.id) {
                let t = norm(c.title)
                if others.contains(where: { t.contains($0) }) { continue }   // don't cross into another member
                if rootWords.contains(where: { t.contains($0) }) { continue } // don't climb to a parent/root section
                let childCategory = normalizeCategory(c.title) ?? node.category
                let parsedYear = Int(c.title.trimmingCharacters(in: .whitespaces))
                let childYear = (parsedYear.map { (1980...2100).contains($0) } ?? false) ? parsedYear : node.year
                queue.append(Node(cat: c.id, category: childCategory, year: childYear, depth: node.depth + 1))
            }
        }
        guard !albums.isEmpty else { return [] }

        // Fetch each album's images concurrently and flatten into the plan.
        var planned: [Planned] = []
        var idx = 0
        await withTaskGroup(of: (AlbumMeta, [Image]).self) { group in
            func addNext() {
                guard idx < albums.count else { return }
                let a = albums[idx]; idx += 1
                group.addTask { (a, await images(inAlbum: a.id)) }
            }
            for _ in 0..<min(8, albums.count) { addNext() }
            while let (a, imgs) = await group.next() {
                let date = parseAlbumDate(a.title, year: a.year)
                let place = parseAlbumPlace(a.title)
                for img in imgs {
                    planned.append(Planned(fullURL: img.fullURL, destName: img.filename,
                                           category: a.category, date: date, place: place, caption: img.caption))
                }
                addNext()
            }
        }
        return planned
    }

    // MARK: - Category normalization (Portuguese/English → canonical English label)

    nonisolated private static let categoryAliases: [(label: String, keys: [String])] = [
        ("Fashion Shows",      ["fashionshow", "desfile", "runway", "passarela"]),
        ("Public Appearances", ["publicappearance", "appearance", "aparicao", "aparicoes", "evento", "event", "premiere", "estreia", "redcarpet", "tapetevermelho"]),
        ("Photoshoots",        ["photoshoot", "photoshoots", "ensaio", "ensaios", "session", "photosession", "shoot", "editorial"]),
        ("Brand Photos",       ["brand", "campanha", "campaign", "marca", "endorsement", "publicidade", "advert", "lookbook"]),
        ("Social Media",       ["socialmedia", "redessociais", "instagram", "snapchat", "twitter", "tiktok", "social"]),
        ("Candids",            ["candid", "candids", "flagra", "flagras", "outandabout", "saindo"]),
        ("Others",             ["outros", "other", "misc", "diversos", "various"]),
    ]

    /// Maps a (Portuguese or English) category title to one of the seven labels, or
    /// nil to inherit the parent's. Fashion Shows is checked before the broader
    /// "appearance/event" bucket so a runway isn't mislabeled.
    nonisolated private static func normalizeCategory(_ title: String) -> String? {
        let t = norm(title)
        for (label, keys) in categoryAliases where keys.contains(where: { t.contains($0) }) { return label }
        return nil
    }

    /// Words marking a parent/root category we must not climb into.
    nonisolated private static let rootWords = ["home", "inicio", "principal", "gallery", "galeria",
                                                "celebrities", "celebridades", "categoria", "categories", "kardashian", "jenner"]

    nonisolated private static func norm(_ s: String) -> String {
        s.folding(options: .diacriticInsensitive, locale: .current)
            .lowercased().replacingOccurrences(of: "[^a-z0-9]", with: "", options: .regularExpression)
    }

    // MARK: - Album date / place parsing

    nonisolated private static let monthIndex: [String: Int] = {
        let en = ["january","february","march","april","may","june","july","august","september","october","november","december"]
        let enAbbr = ["jan","feb","mar","apr","may","jun","jul","aug","sep","sept","oct","nov","dec"]
        let pt = ["janeiro","fevereiro","marco","abril","maio","junho","julho","agosto","setembro","outubro","novembro","dezembro"]
        let ptAbbr = ["jan","fev","mar","abr","mai","jun","jul","ago","set","out","nov","dez"]
        var m: [String: Int] = [:]
        for (i, n) in en.enumerated() { m[n] = i + 1 }
        for (i, n) in pt.enumerated() { m[n] = i + 1 }
        for (i, n) in enAbbr.enumerated() { m[n] = min(i + 1, 12) }
        for (i, n) in ptAbbr.enumerated() { m[n] = i + 1 }
        return m
    }()

    /// The album's date: a full date in the title (yyyy-mm-dd etc.), else a textual
    /// or numeric month+day combined with the year from the enclosing year-category,
    /// else just that year. Diacritic-insensitive so "março"/"marco" both parse.
    nonisolated static func parseAlbumDate(_ title: String, year: Int?) -> Date? {
        if let d = MetadataLoader.dateFromFilename(title) { return d }
        let cal = Calendar(identifier: .gregorian)
        let lowered = title.folding(options: .diacriticInsensitive, locale: .current).lowercased()

        // "June 5" / "5 de junho" — a textual month near a day number.
        if let g = matches(lowered, "([a-z]{3,9})\\s+([0-9]{1,2})").first,
           let mo = monthIndex[g[1]], let day = Int(g[2]), (1...31).contains(day), let y = year {
            var c = DateComponents(); c.year = y; c.month = mo; c.day = day; c.hour = 12
            return cal.date(from: c)
        }
        if let g = matches(lowered, "([0-9]{1,2})\\s*de\\s*([a-z]{3,9})").first,
           let day = Int(g[1]), let mo = monthIndex[g[2]], (1...31).contains(day), let y = year {
            var c = DateComponents(); c.year = y; c.month = mo; c.day = day; c.hour = 12
            return cal.date(from: c)
        }
        // Numeric mm-dd with a known year.
        if let y = year, let g = matches(title, "(?:^|[^0-9])([0-9]{1,2})[-/]([0-9]{1,2})(?:[^0-9]|$)").first,
           let mo = Int(g[1]), let day = Int(g[2]), (1...12).contains(mo), (1...31).contains(day) {
            var c = DateComponents(); c.year = y; c.month = mo; c.day = day; c.hour = 12
            return cal.date(from: c)
        }
        if let y = year {
            var c = DateComponents(); c.year = y; c.month = 1; c.day = 1; c.hour = 12
            return cal.date(from: c)
        }
        return nil
    }

    /// A place named in the album title — text after "… in …" or the Portuguese
    /// "… em …".
    nonisolated static func parseAlbumPlace(_ title: String) -> String? {
        for sep in [" in ", " em "] {
            guard let r = title.range(of: sep, options: [.backwards, .caseInsensitive]) else { continue }
            let place = String(title[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if (3...60).contains(place.count) { return place }
        }
        return nil
    }

    // MARK: - Browsing (Coppermine HTML)

    struct Category: Sendable { let id: Int; let title: String }
    struct Album: Sendable { let id: Int; let title: String }
    struct Image: Sendable { let fullURL: URL; let filename: String; let caption: String? }

    /// Sub-categories + albums under a category. Coppermine paginates the album
    /// list within a category, so we read *every* album page (`&page=P`), not just
    /// the first — otherwise large galleries lose all but their first ~20 albums.
    nonisolated private static func browse(category cat: Int?) async -> (categories: [Category], albums: [Album]) {
        func path(_ p: Int) -> String {
            if let cat { return "index.php?cat=\(cat)&page=\(p)" }
            return "index.php?page=\(p)"
        }
        guard let first = await fetchHTML(path(1)) else { return ([], []) }
        let cats = parseCategories(first, excluding: cat)
        var byID: [Int: Album] = [:]; var order: [Int] = []
        func add(_ list: [Album]) { for a in list where byID[a.id] == nil { byID[a.id] = a; order.append(a.id) } }
        add(parseAlbums(first))
        let last = min(maxPage(first), 100)
        if last > 1 {
            await withTaskGroup(of: [Album].self) { group in
                for p in 2...last { group.addTask { parseAlbums(await fetchHTML(path(p)) ?? "") } }
                for await list in group { add(list) }
            }
        }
        return (cats, order.compactMap { byID[$0] })
    }

    /// Every image in an album across all Coppermine pages (page 1 sets the count).
    nonisolated private static func images(inAlbum id: Int) async -> [Image] {
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
        return all
    }

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

    /// Thumbnails on an album page, by their Coppermine `thumb_` src. The full-size
    /// path drops the `thumb_` prefix; the caption is taken from the `<img>`'s
    /// `title`/`alt` when it's descriptive (not just the filename) — best-effort.
    nonisolated private static func parseImages(_ html: String) -> [Image] {
        var out: [Image] = []; var seen = Set<String>()
        for g in matches(html, "<img[^>]+src=\"([^\"]*thumb_[^\"]+\\.(?:jpe?g|png|gif))\"[^>]*>") {
            let tag = g[0]
            let thumbPath = decode(g[1])
            guard let fullURL = absolute(fullImagePath(from: thumbPath)),
                  seen.insert(fullURL.absoluteString).inserted else { continue }
            let filename = fullURL.lastPathComponent
            var caption: String?
            for attr in ["title", "alt"] {
                if let m = matches(tag, "\(attr)=\"([^\"]*)\"").first {
                    let text = decode(m[1])
                    if isUsefulCaption(text, filename: filename) { caption = text; break }
                }
            }
            out.append(Image(fullURL: fullURL, filename: filename, caption: caption))
        }
        return out
    }

    /// A caption is useful only if it's prose — not the filename, a bare number, or
    /// Coppermine's default "image NNN" alt text.
    nonisolated private static func isUsefulCaption(_ text: String, filename: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 4 else { return false }
        let base = (filename as NSString).deletingPathExtension
        if t.caseInsensitiveCompare(filename) == .orderedSame || t.caseInsensitiveCompare(base) == .orderedSame { return false }
        if Double(t) != nil { return false }
        return t.rangeOfCharacter(from: .letters) != nil
    }

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

    // MARK: - Download + metadata

    /// Download the original bytes, retrying transient failures (the gallery
    /// throttles under load, which surfaced as a high failure rate with no retry).
    /// If the full-size original genuinely can't be fetched, fall back to the
    /// `normal_` (resized) version so the photo isn't lost entirely.
    nonisolated private static func downloadImage(_ fullURL: URL, to dest: URL, date: Date?, coord: Coord?) async -> Bool {
        let filename = fullURL.lastPathComponent
        let normalURL = fullURL.deletingLastPathComponent().appendingPathComponent("normal_" + filename)
        for url in [fullURL, normalURL] {
            for attempt in 0..<3 {
                if let data = await fetchImageData(url) {
                    try? FileManager.default.removeItem(at: dest)          // overwrite / re-run safety
                    if (try? data.write(to: dest, options: .atomic)) != nil {
                        applyDateAndPlace(to: dest, albumDate: date, coord: coord)
                        return true
                    }
                }
                try? await Task.sleep(nanoseconds: UInt64(250_000_000) << attempt)   // 0.25s, 0.5s, 1s
            }
        }
        return false
    }

    /// Fetch image bytes, rejecting non-2xx responses and tiny bodies (HTML error
    /// pages the gallery returns instead of a 404).
    nonisolated private static func fetchImageData(_ url: URL) async -> Data? {
        var req = URLRequest(url: url)
        req.setValue(host, forHTTPHeaderField: "Referer")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 90
        guard let (data, resp) = try? await session.data(for: req) else { return nil }
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) { return nil }
        return data.count >= 512 ? data : nil
    }

    /// Preserve the photo's own EXIF where it exists; only fill gaps from the album.
    /// If the image has no capture date, write the album date into EXIF (so the app's
    /// year/Age features see it — `captureDate` reads EXIF only, never file mtime).
    /// If it has no GPS and the album names a place, write that location.
    nonisolated private static func applyDateAndPlace(to url: URL, albumDate: Date?, coord: Coord?) {
        let have = existingMetadata(of: url)
        let needDate = !have.hasDate ? albumDate : nil
        let needCoord: Coord? = !have.hasGPS ? coord : nil
        if needDate != nil || needCoord != nil {
            _ = writeMetadata(to: url, date: needDate, coord: needCoord)
        }
        // Mirror the effective capture date onto the file's dates too (cheap), so
        // date sorting and Finder show something sane even if the EXIF write failed.
        if let d = have.date ?? albumDate {
            try? FileManager.default.setAttributes([.creationDate: d, .modificationDate: d], ofItemAtPath: url.path)
        }
    }

    nonisolated private static func existingMetadata(of url: URL) -> (hasDate: Bool, date: Date?, hasGPS: Bool) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return (false, nil, false) }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let hasGPS = props[kCGImagePropertyGPSDictionary] != nil
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"; f.timeZone = .current
        for case let s? in [exif?[kCGImagePropertyExifDateTimeOriginal] as? String,
                            exif?[kCGImagePropertyExifDateTimeDigitized] as? String,
                            tiff?[kCGImagePropertyTIFFDateTime] as? String] {
            if let d = f.date(from: s) { return (true, d, hasGPS) }
        }
        return (false, nil, hasGPS)
    }

    /// Additive EXIF write (preserves the rest of the metadata): sets the capture
    /// date and/or GPS, then atomically replaces the file. `nonisolated` so it runs
    /// off the main actor (unlike `FileActions.applyMetadata`, which is MainActor).
    nonisolated private static func writeMetadata(to url: URL, date: Date?, coord: Coord?) -> Bool {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(src) else { return false }
        var props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
        if let date {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy:MM:dd HH:mm:ss"; f.timeZone = .current
            let stamp = f.string(from: date)
            var exif = (props[kCGImagePropertyExifDictionary] as? [CFString: Any]) ?? [:]
            exif[kCGImagePropertyExifDateTimeOriginal] = stamp
            exif[kCGImagePropertyExifDateTimeDigitized] = stamp
            props[kCGImagePropertyExifDictionary] = exif
            var tiff = (props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]) ?? [:]
            tiff[kCGImagePropertyTIFFDateTime] = stamp
            props[kCGImagePropertyTIFFDictionary] = tiff
        }
        if let coord {
            props[kCGImagePropertyGPSDictionary] = [
                kCGImagePropertyGPSLatitude: abs(coord.lat),
                kCGImagePropertyGPSLatitudeRef: coord.lat >= 0 ? "N" : "S",
                kCGImagePropertyGPSLongitude: abs(coord.lng),
                kCGImagePropertyGPSLongitudeRef: coord.lng >= 0 ? "E" : "W"
            ] as [CFString: Any]
        }
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".akmeta_" + UUID().uuidString).appendingPathExtension(url.pathExtension)
        guard let dst = CGImageDestinationCreateWithURL(tmp as CFURL, type, 1, nil) else { return false }
        CGImageDestinationAddImageFromSource(dst, src, 0, props as CFDictionary)
        guard CGImageDestinationFinalize(dst) else { try? FileManager.default.removeItem(at: tmp); return false }
        do { _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp); return true }
        catch { try? FileManager.default.removeItem(at: tmp); return false }
    }

    nonisolated private static func geocode(_ place: String) async -> Coord? {
        guard let marks = try? await CLGeocoder().geocodeAddressString(place),
              let c = marks.first?.location?.coordinate, CLLocationCoordinate2DIsValid(c),
              !(c.latitude == 0 && c.longitude == 0) else { return nil }
        return Coord(lat: c.latitude, lng: c.longitude)
    }

    // MARK: - Networking

    nonisolated private static func fetchHTML(_ path: String) async -> String? {
        guard let url = URL(string: host + path) else { return nil }
        func request(ignoreCache: Bool) -> URLRequest {
            var req = URLRequest(url: url)
            req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            req.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
            req.setValue("en-US,en;q=0.9,pt-BR;q=0.8", forHTTPHeaderField: "Accept-Language")
            if ignoreCache { req.cachePolicy = .reloadIgnoringLocalCacheData }
            return req
        }
        for attempt in 0..<2 {
            if let (data, _) = try? await session.data(for: request(ignoreCache: attempt > 0)) {
                return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
            }
        }
        return nil
    }

    // MARK: - Small helpers (Coppermine HTML)

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
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "image.jpg" : String(cleaned.prefix(120))
    }
}
