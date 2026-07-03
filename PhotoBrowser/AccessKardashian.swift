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

    /// The four members the user asked for (no Khloé, no Kris). Gallery category ids
    /// are verified against the live site (Kim=4, Kourtney=5, Kendall=6, Kylie=7),
    /// so no name discovery is needed.
    nonisolated static let members: [Member] = [
        Member(name: "Kim Kardashian", token: "kim", knownCat: 4,
               birthday: DateComponents(year: 1980, month: 10, day: 21)),
        Member(name: "Kourtney Kardashian", token: "kourtney", knownCat: 5,
               birthday: DateComponents(year: 1979, month: 4, day: 18)),
        Member(name: "Kendall Jenner", token: "kendall", knownCat: 6,
               birthday: DateComponents(year: 1995, month: 11, day: 3)),
        Member(name: "Kylie Jenner", token: "kylie", knownCat: 7,
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
        var retried = 0                // transient fetch failures that were retried
        var reducedSize = 0            // photos that fell back to the `normal_` (resized) version
        var perMinute = 0              // average download rate over the download phase
        var note: String?
        /// Applied by the caller on the main actor (Library is `@MainActor`):
        var captions: [String: String] = [:]           // path → caption (Portuguese; the view translates)
        var labelsByCategory: [String: [String]] = [:]  // category label → [path]
    }

    private struct Coord: Sendable { let lat: Double; let lng: Double }
    private struct Planned: Sendable, Codable {
        let fullURL: URL
        var destName: String
        let category: String
        let date: Date?
        let place: String?
        let caption: String?
    }
    /// On-disk cache of a member's fully-built plan, so re-runs (Resume / Re-download)
    /// skip the slow gallery crawl entirely.
    private struct PlanCache: Codable { var plan: [Planned]; var builtAt: Double }

    nonisolated static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
    /// Session for HTML listing pages — cached (pages re-fetched during the crawl).
    nonisolated static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.httpMaximumConnectionsPerHost = 16
        cfg.timeoutIntervalForRequest = 45
        cfg.urlCache = URLCache(memoryCapacity: 64 << 20, diskCapacity: 512 << 20)
        cfg.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: cfg)
    }()

    /// Session for image downloads — a much wider connection pool and **no URL cache**
    /// (the bytes are written straight to disk, so caching them only added a redundant
    /// write + eviction churn per image). Both together speed downloads up several-fold.
    nonisolated static let downloadSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.httpMaximumConnectionsPerHost = 22
        cfg.timeoutIntervalForRequest = 60
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }()

    // MARK: - Run

    /// Crawls `member`'s gallery and downloads it into `folder`. `overwrite` re-fetches
    /// images already on disk (Re-download); otherwise existing files are skipped
    /// (Fetch New / Resume). `refreshIndex` forces a fresh crawl (Fetch New); otherwise
    /// a previously-cached album index is reused so listing is instant. `isCancelled`
    /// is polled so the UI can pause/cancel — everything already downloaded stays put.
    nonisolated static func run(member: Member, into folder: URL, overwrite: Bool, refreshIndex: Bool,
                                progress: @escaping @Sendable (Progress) -> Void,
                                isCancelled: @escaping @Sendable () -> Bool) async -> Result {
        var result = Result()
        // Diagnostic log beside the member folders — plain text, viewable in-app,
        // so a slow run shows *where* the time went (fetch vs stall/retry vs write).
        let log = AKLog(in: folder.deletingLastPathComponent(), member: member.name)
        log.add("config: overwrite=\(overwrite) refreshIndex=\(refreshIndex) concurrency=22 idleTimeout=20s")
        defer { log.flush() }

        // Reuse the cached album index unless a refresh was asked for — this is what
        // makes Resume/Re-download skip the (slow) crawl that was stalling on "Listing".
        var plan: [Planned]
        if !refreshIndex, let cached = loadCachedPlan(member), !cached.isEmpty {
            progress(Progress(phase: "Loaded saved index — \(cached.count) photos", fraction: 0, done: 0, total: cached.count))
            plan = cached
            log.add("plan: cached index, \(plan.count) photos")
        } else {
            progress(Progress(phase: "Finding \(member.name)’s gallery…", fraction: 0, done: 0, total: 0))
            guard let rootCat = await memberRootCat(member) else {
                result.note = "Couldn’t find \(member.name)’s gallery on accesskardashian.com.br."
                log.add("ABORT: gallery not found")
                return result
            }
            plan = await buildPlan(rootCat: rootCat, member: member, progress: progress, isCancelled: isCancelled)
            log.add("plan: fresh crawl, \(plan.count) photos")
            guard !plan.isEmpty else {
                if isCancelled() { result.cancelled = true; log.add("paused during crawl") }
                else { result.note = "No photos found in \(member.name)’s gallery."; log.add("ABORT: no photos found") }
                return result
            }
            // Deterministic order (stable across runs so resume lines up) + unique flat
            // filenames, since everything lands directly in the member folder.
            plan.sort { $0.fullURL.absoluteString < $1.fullURL.absoluteString }
            assignDestNames(&plan)
            // Only cache a *complete* crawl, so a paused listing re-crawls next time.
            if !isCancelled() { saveCachedPlan(member, plan) }
        }
        if isCancelled() { result.cancelled = true; log.add("paused before downloads"); return result }
        result.total = plan.count

        // Pre-geocode the distinct album places once (CLGeocoder is rate-limited, so
        // this is serial). Capped so it can never become the bottleneck before
        // downloads start — beyond the cap, those photos just don't get a location.
        let distinctPlaces = Array(Set(plan.compactMap(\.place)).prefix(60))
        var coords: [String: Coord?] = [:]
        if !distinctPlaces.isEmpty {
            progress(Progress(phase: "Locating \(distinctPlaces.count) place(s)…", fraction: 0, done: 0, total: plan.count))
        }
        let geoStart = Date()
        for place in distinctPlaces where !isCancelled() { coords[place] = await geocode(place) }
        if !distinctPlaces.isEmpty {
            log.add("geocoded \(distinctPlaces.count) place(s) in \(Int(Date().timeIntervalSince(geoStart)))s")
        }

        if isCancelled() { result.cancelled = true; log.add("paused during geocoding"); return result }

        let total = plan.count
        var done = 0
        // Collected here (off-actor) and handed back for one batched persist.
        var captions: [String: String] = [:]
        var labels: [String: [String]] = [:]

        // One directory listing beats a stat per planned photo: a Resume/Fetch New
        // over a big gallery (tens of thousands already on disk) spent its time in
        // per-file `fileExists` on the external drive before any download started.
        // If the listing itself fails (drive hiccup) fall back to per-file stats —
        // never treat "couldn't list" as "have nothing" and re-download everything.
        let existingNames: Set<String>? = overwrite ? []
            : (try? FileManager.default.contentsOfDirectory(atPath: folder.path)).map { Set($0.map { $0.lowercased() }) }
        log.add("already on disk: \(existingNames.map { String($0.count) } ?? "listing failed — per-file stats") · downloads starting")

        let downloadStart = Date()
        var fetchTotal = 0.0, saveTotal = 0.0, bytesTotal = 0
        var slow5 = 0, slow15 = 0
        await withTaskGroup(of: (ok: Bool, skipped: Bool, path: String?, category: String, caption: String?, dl: DLStats?).self) { group in
            var idx = 0
            let maxConcurrent = 22              // matched to the connection pool (higher throttled)
            func addNext() {
                guard idx < plan.count, !isCancelled() else { return }
                let p = plan[idx]; idx += 1
                let coord = p.place.flatMap { coords[$0] ?? nil }
                group.addTask {
                    let dest = folder.appendingPathComponent(p.destName)
                    let alreadyHave = existingNames.map { $0.contains(p.destName.lowercased()) }
                        ?? FileManager.default.fileExists(atPath: dest.path)
                    if !overwrite, alreadyHave {
                        return (true, true, dest.path, p.category, p.caption, nil)   // already have it
                    }
                    let r = await downloadImage(p.fullURL, to: dest, date: p.date, coord: coord)
                    return (r.ok, false, r.ok ? dest.path : nil, p.category, p.caption, r.stats)
                }
            }
            for _ in 0..<min(maxConcurrent, total) { addNext() }
            while let r = await group.next() {
                if r.skipped { result.skipped += 1 } else if r.ok { result.downloaded += 1 } else { result.failed += 1 }
                if let dl = r.dl {
                    result.retried += dl.retries; result.reducedSize += dl.fallbacks
                    fetchTotal += dl.fetchSecs; saveTotal += dl.saveSecs; bytesTotal += dl.bytes
                    if dl.fetchSecs > 5 { slow5 += 1 }
                    if dl.fetchSecs > 15 { slow15 += 1 }
                    // One line per real download (skips excluded) — the raw material
                    // for diagnosing a slow run.
                    let flag = r.ok ? (dl.fallbacks > 0 ? "ok(reduced)" : "ok") : "FAIL"
                    log.add(String(format: "%@ fetch=%.1fs save=%.2fs %dKB retries=%d %@",
                                   flag, dl.fetchSecs, dl.saveSecs, dl.bytes / 1024, dl.retries,
                                   (r.path as NSString?)?.lastPathComponent ?? "?"))
                }
                if let path = r.path {
                    labels[r.category, default: []].append(path)
                    if let cap = r.caption, !cap.isEmpty { captions[path] = cap }
                }
                done += 1
                if done % 200 == 0 {
                    let mins = max(Date().timeIntervalSince(downloadStart) / 60, 1.0 / 60)
                    log.add("progress \(done)/\(total) — \(Int(Double(result.downloaded) / mins))/min downloaded, \(result.skipped) skipped")
                }
                // Throttle UI updates — at this fan-out a callback per image floods the
                // main actor and slows everything down.
                if done == total || done % 12 == 0 {
                    progress(Progress(phase: "Downloading", fraction: Double(done) / Double(total), done: done, total: total))
                }
                addNext()
            }
        }
        let wall = Date().timeIntervalSince(downloadStart)
        let minutes = max(wall / 60, 1.0 / 60)
        result.perMinute = Int(Double(result.downloaded) / minutes)
        if result.downloaded > 0 {
            // avg parallelism = busy-time ÷ wall-time: ~22 means the slots stayed
            // full (host/route is the limit); ~1–3 means something is serializing.
            log.add(String(format: "summary: %d downloaded, %d skipped, %d failed in %.0fs · %d/min · avgFetch=%.1fs avgSave=%.2fs · %.1fMB · retries=%d reduced=%d · fetch>5s=%d >15s=%d · avg parallelism=%.1f",
                           result.downloaded, result.skipped, result.failed, wall, result.perMinute,
                           fetchTotal / Double(result.downloaded), saveTotal / Double(result.downloaded),
                           Double(bytesTotal) / 1_048_576, result.retried, result.reducedSize, slow5, slow15,
                           (fetchTotal + saveTotal) / max(wall, 0.1)))
        } else {
            log.add("summary: nothing downloaded (\(result.skipped) skipped, \(result.failed) failed) cancelled=\(isCancelled())")
        }
        result.captions = captions
        result.labelsByCategory = labels
        result.cancelled = isCancelled()
        if result.downloaded == 0 && result.skipped == 0 { result.note = "Nothing could be downloaded from the gallery." }
        else if result.failed > 0 { result.note = "\(result.failed) photo(s) couldn’t be downloaded." }
        return result
    }

    // MARK: - Plan cache (album index on disk)

    nonisolated private static func planCacheURL(_ member: Member) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("accessKardashian", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(member.token).json")
    }
    nonisolated private static func loadCachedPlan(_ member: Member) -> [Planned]? {
        guard let data = try? Data(contentsOf: planCacheURL(member)),
              let cache = try? JSONDecoder().decode(PlanCache.self, from: data) else { return nil }
        return cache.plan
    }
    nonisolated private static func saveCachedPlan(_ member: Member, _ plan: [Planned]) {
        guard let data = try? JSONEncoder().encode(PlanCache(plan: plan, builtAt: Date().timeIntervalSince1970)) else { return }
        try? data.write(to: planCacheURL(member))
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
    nonisolated private static func buildPlan(rootCat: Int, member: Member,
                                              progress: @escaping @Sendable (Progress) -> Void,
                                              isCancelled: @escaping @Sendable () -> Bool) async -> [Planned] {
        let others = Set(members.map(\.token)).subtracting([member.token])
        struct Node: Sendable { let cat: Int; let category: String?; let year: Int?; let depth: Int }
        struct AlbumMeta: Sendable { let id: Int; let title: String; let category: String; let year: Int? }

        var albums: [AlbumMeta] = []
        var seenAlbums = Set<Int>()
        var visited = Set<Int>([rootCat])

        // Level-synchronized parallel BFS: browse all of a level's categories at once
        // (was sequential, which crawled hundreds of year/month nodes one at a time and
        // stalled on "Listing albums"). Discovery is recorded in `visited` as children
        // are found so the same category isn't queued twice within a level.
        var frontier = [Node(cat: rootCat, category: nil, year: nil, depth: 0)]
        while !frontier.isEmpty && !isCancelled() {
            var next: [Node] = []
            let level = frontier
            var idx = 0
            await withTaskGroup(of: (Node, [Category], [Album]).self) { group in
                func addNext() {
                    guard idx < level.count, !isCancelled() else { return }
                    let n = level[idx]; idx += 1
                    group.addTask { let r = await browse(category: n.cat); return (n, r.categories, r.albums) }
                }
                for _ in 0..<min(12, level.count) { addNext() }
                while let (node, cats, albs) = await group.next() {
                    for a in albs where seenAlbums.insert(a.id).inserted {
                        albums.append(AlbumMeta(id: a.id, title: a.title, category: node.category ?? "Others", year: node.year))
                    }
                    if node.depth < 6 {
                        for c in cats where !visited.contains(c.id) {
                            let t = norm(c.title)
                            if others.contains(where: { t.contains($0) }) { continue }   // don't cross into another member
                            if rootWords.contains(where: { t.contains($0) }) { continue } // don't climb to a parent/root section
                            visited.insert(c.id)
                            let childCategory = normalizeCategory(c.title) ?? node.category
                            let parsedYear = Int(c.title.trimmingCharacters(in: .whitespaces))
                            let childYear = (parsedYear.map { (1980...2100).contains($0) } ?? false) ? parsedYear : node.year
                            next.append(Node(cat: c.id, category: childCategory, year: childYear, depth: node.depth + 1))
                        }
                    }
                    progress(Progress(phase: "Listing albums — \(albums.count) found…", fraction: 0, done: albums.count, total: 0))
                    addNext()
                }
            }
            frontier = next
        }
        guard !albums.isEmpty else { return [] }
        let byCat = Dictionary(grouping: albums, by: \.category).mapValues(\.count)
        print("[AccessKardashian] \(member.name): crawled \(albums.count) albums by category \(byCat)")

        // Fetch each album's images concurrently and flatten into the plan.
        var planned: [Planned] = []
        var idx = 0, doneAlbums = 0
        await withTaskGroup(of: (AlbumMeta, [Image]).self) { group in
            func addNext() {
                guard idx < albums.count, !isCancelled() else { return }
                let a = albums[idx]; idx += 1
                group.addTask { (a, await images(inAlbum: a.id)) }
            }
            for _ in 0..<min(12, albums.count) { addNext() }
            while let (a, imgs) = await group.next() {
                let albumDate = parseAlbumDate(a.title, year: a.year)
                let place = parseAlbumPlace(a.title)
                for img in imgs {
                    // Per-image "Date added" is the most reliable date; fall back to the
                    // album's date when an image doesn't carry one.
                    planned.append(Planned(fullURL: img.fullURL, destName: img.filename,
                                           category: a.category, date: img.dateAdded ?? albumDate,
                                           place: place, caption: img.caption))
                }
                doneAlbums += 1
                progress(Progress(phase: "Listing photos — \(planned.count) in \(doneAlbums)/\(albums.count) albums…",
                                  fraction: Double(doneAlbums) / Double(albums.count), done: planned.count, total: albums.count))
                addNext()
            }
        }
        print("[AccessKardashian] \(member.name): planned \(planned.count) images from \(albums.count) albums")
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

    /// A place named in the album title — text after "… in …" or its Portuguese
    /// equivalents ("… em / no / na …"), taking the last occurrence (real titles
    /// read like "… pop-up … no SoHo, Nova York").
    nonisolated static func parseAlbumPlace(_ title: String) -> String? {
        for sep in [" in ", " em ", " no ", " na "] {
            guard let r = title.range(of: sep, options: [.backwards, .caseInsensitive]) else { continue }
            let place = String(title[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if (3...60).contains(place.count) { return place }
        }
        return nil
    }

    // MARK: - Browsing (Coppermine HTML)

    struct Category: Sendable { let id: Int; let title: String }
    struct Album: Sendable { let id: Int; let title: String }
    struct Image: Sendable { let fullURL: URL; let filename: String; let caption: String?; let dateAdded: Date? }

    /// Sub-categories + albums under a category. Coppermine paginates the album list
    /// within a category; rather than trust the pager's page count (it can show a
    /// windowed range that undercounts), we keep fetching pages until one adds no new
    /// album — guaranteeing we see every album regardless of how the pager renders.
    nonisolated private static func browse(category cat: Int?) async -> (categories: [Category], albums: [Album]) {
        func path(_ p: Int) -> String {
            if let cat { return "index.php?cat=\(cat)&page=\(p)" }
            return "index.php?page=\(p)"
        }
        guard let first = await fetchHTML(path(1)) else { return ([], []) }
        let cats = parseCategories(first, excluding: cat)
        var byID: [Int: Album] = [:]; var order: [Int] = []
        @discardableResult func add(_ list: [Album]) -> Int {
            var added = 0
            for a in list where byID[a.id] == nil { byID[a.id] = a; order.append(a.id); added += 1 }
            return added
        }
        add(parseAlbums(first))
        var p = 2
        while p <= 500 {                                // hard safety cap
            guard let html = await fetchHTML(path(p)) else { break }     // hard failure after retries — stop
            if add(parseAlbums(html)) == 0 { break }    // out-of-range pages repeat/empty → done
            p += 1
        }
        return (cats, order.compactMap { byID[$0] })
    }

    /// Every image in an album. Same "paginate until a page adds nothing new"
    /// approach as `browse`, so a windowed thumbnail pager can't truncate a big album.
    nonisolated private static func images(inAlbum id: Int) async -> [Image] {
        var all: [Image] = []; var seen = Set<String>()
        var p = 1
        while p <= 500 {
            guard let html = await fetchHTML("thumbnails.php?album=\(id)&page=\(p)") else { break }
            var added = 0
            for img in parseImages(html) where seen.insert(img.fullURL.absoluteString).inserted { all.append(img); added += 1 }
            if added == 0 { break }
            p += 1
        }
        return all
    }

    nonisolated private static func parseCategories(_ html: String, excluding current: Int?) -> [Category] {
        var seen = Set<Int>(); var out: [Category] = []
        // Tolerate any params/quoting after the id (e.g. `cat=12&amp;…`), so links
        // aren't silently dropped when they carry extra query parameters.
        for g in matches(html, "<a[^>]+href=[\"']?index\\.php\\?cat=(\\d+)[^>]*>([\\s\\S]*?)</a>") {
            guard let id = Int(g[1]), id != current, !seen.contains(id) else { continue }
            let title = decode(stripTags(g[2]))
            guard !title.isEmpty else { continue }
            seen.insert(id); out.append(Category(id: id, title: title))
        }
        return out
    }

    nonisolated private static func parseAlbums(_ html: String) -> [Album] {
        var titles: [Int: String] = [:]; var order: [Int] = []
        for g in matches(html, "<a[^>]+href=[\"']?thumbnails\\.php\\?album=(\\d+)[^>]*>([\\s\\S]*?)</a>") {
            guard let id = Int(g[1]) else { continue }
            let title = decode(stripTags(g[2]))
            if titles[id] == nil { order.append(id) }
            if (titles[id] ?? "").isEmpty, !title.isEmpty { titles[id] = title }
            else if titles[id] == nil { titles[id] = "" }
        }
        return order.map { Album(id: $0, title: titles[$0] ?? "") }
    }

    /// Thumbnails on an album page, by their Coppermine `thumb_` src. The full-size
    /// path drops the `thumb_` prefix. The `<img>`'s `title`/`alt` holds Coppermine's
    /// info tooltip ("Filename=… Filesize=… Date added=DD.MM.YY"), from which we pull
    /// the per-image date; a genuinely descriptive title is kept as the caption.
    nonisolated private static func parseImages(_ html: String) -> [Image] {
        var out: [Image] = []; var seen = Set<String>()
        for g in matches(html, "<img[^>]+src=\"([^\"]*thumb_[^\"]+\\.(?:jpe?g|png|gif))\"[^>]*>") {
            let tag = g[0]
            let thumbPath = decode(g[1])
            guard let fullURL = absolute(fullImagePath(from: thumbPath)),
                  seen.insert(fullURL.absoluteString).inserted else { continue }
            let filename = fullURL.lastPathComponent
            var caption: String?; var dateAdded: Date?
            for attr in ["title", "alt"] {
                guard let m = matches(tag, "\(attr)=\"([^\"]*)\"").first else { continue }
                let text = decode(m[1])
                if dateAdded == nil { dateAdded = parseDateAdded(text) }
                if caption == nil, isUsefulCaption(text, filename: filename) { caption = text }
            }
            out.append(Image(fullURL: fullURL, filename: filename, caption: caption, dateAdded: dateAdded))
        }
        return out
    }

    /// Coppermine's per-image "Date added=DD.MM.YY" (Brazilian day-first), used as
    /// the capture date when the file carries none. Swaps to mm/dd only when the
    /// first field can't be a day.
    nonisolated private static func parseDateAdded(_ text: String) -> Date? {
        // Prefer the labeled field; fall back to a bare DD.MM.YY (covers a
        // Portuguese-labeled tooltip — "Dimensions=1080x1440" can't match, no dots).
        let g = matches(text, "date\\s*added\\s*[=:]?\\s*([0-9]{1,2})[./-]([0-9]{1,2})[./-]([0-9]{2,4})").first
            ?? matches(text, "([0-9]{1,2})\\.([0-9]{1,2})\\.([0-9]{2,4})").first
        guard let g, var day = Int(g[1]), var mon = Int(g[2]), var year = Int(g[3]) else { return nil }
        if year < 100 { year += 2000 }
        if mon > 12 && day <= 12 { swap(&day, &mon) }
        guard (1...12).contains(mon), (1...31).contains(day), (1990...2100).contains(year) else { return nil }
        var c = DateComponents(); c.year = year; c.month = mon; c.day = day; c.hour = 12
        return Calendar(identifier: .gregorian).date(from: c)
    }

    /// Whether a stored string is Coppermine's file-info tooltip ("Filename=… Date
    /// added=…") — wrongly saved as a caption by an earlier version, so a re-run can
    /// clear it.
    nonisolated static func isInfoBlock(_ s: String) -> Bool {
        let l = s.lowercased()
        return ["filename=", "filesize=", "dimensions=", "date added"].contains { l.contains($0) }
    }

    /// A caption is useful only if it's prose — not Coppermine's file-info tooltip,
    /// the filename, a bare number, or the default "image NNN" alt text.
    nonisolated private static func isUsefulCaption(_ text: String, filename: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 4 else { return false }
        let lower = t.lowercased()
        // The info tooltip ("Filename=… Filesize=… Dimensions=… Date added=…") is metadata, not a caption.
        if ["filename=", "filesize=", "dimensions=", "date added"].contains(where: { lower.contains($0) }) { return false }
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

    // MARK: - Download + metadata

    /// How one photo's download went, aggregated into the run's diagnostics and log.
    struct DLStats: Sendable {
        var retries = 0
        var fallbacks = 0
        var fetchSecs: Double = 0     // total network time incl. retries
        var saveSecs: Double = 0      // metadata-embed + drive write time
        var bytes = 0
    }

    /// Download the original bytes, retrying **transient** failures (the gallery
    /// throttles under load) with short backoff. A hard 4xx skips straight to the
    /// `normal_` (resized) fallback — retrying a 404 three times with sleeps was
    /// pure dead time per photo. No sleep after a final attempt either.
    nonisolated private static func downloadImage(_ fullURL: URL, to dest: URL, date: Date?, coord: Coord?) async -> (ok: Bool, stats: DLStats) {
        var stats = DLStats()
        let t0 = Date()
        let filename = fullURL.lastPathComponent
        let normalURL = fullURL.deletingLastPathComponent().appendingPathComponent("normal_" + filename)
        urls: for url in [fullURL, normalURL] {
            for attempt in 0..<3 {
                switch await fetchImageData(url) {
                case .ok(let data):
                    if url != fullURL { stats.fallbacks += 1 }
                    stats.bytes = data.count
                    stats.fetchSecs = Date().timeIntervalSince(t0)
                    // Bytes arrived — if the drive write fails, retrying the network won't help.
                    let s0 = Date()
                    let ok = saveImage(data, to: dest, albumDate: date, coord: coord)
                    stats.saveSecs = Date().timeIntervalSince(s0)
                    return (ok, stats)
                case .hardMiss:
                    continue urls                    // 404 etc. — go straight to the fallback size
                case .transient:
                    stats.retries += 1
                    if attempt < 2 { try? await Task.sleep(nanoseconds: UInt64(250_000_000) << attempt) }   // 0.25s, 0.5s
                }
            }
        }
        stats.fetchSecs = Date().timeIntervalSince(t0)
        return (false, stats)
    }

    private enum ImageFetch: Sendable { case ok(Data); case hardMiss; case transient }

    /// Fetch image bytes. Distinguishes a hard 4xx (don't retry) from transient
    /// failures (5xx / stall / HTML error body). The idle timeout is deliberately
    /// short: the gallery's host sometimes just stalls or resets a connection, and
    /// at 90s each stalled request parked one of the 22 download slots for a minute
    /// and a half — enough stalls and throughput collapsed to a crawl. 20s frees
    /// the slot fast; the retry reconnects and usually goes straight through.
    nonisolated private static func fetchImageData(_ url: URL) async -> ImageFetch {
        var req = URLRequest(url: url)
        req.setValue(host, forHTTPHeaderField: "Referer")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        guard let (data, resp) = try? await downloadSession.data(for: req) else { return .transient }
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            return (400...499).contains(http.statusCode) ? .hardMiss : .transient
        }
        return data.count >= 512 ? .ok(data) : .transient
    }

    /// Write the downloaded bytes in a *single pass*: if the image lacks a capture
    /// date (or GPS, when the album names a place), embed the album's date/location
    /// straight from the in-memory bytes while writing — no decode/temp-file/replace
    /// round-trip. Files that already carry EXIF are written verbatim. This is the
    /// hot path (tens of thousands of images), so it does exactly one disk write.
    nonisolated private static func saveImage(_ data: Data, to dest: URL, albumDate: Date?, coord: Coord?) -> Bool {
        try? FileManager.default.removeItem(at: dest)            // overwrite / re-run safety
        var effectiveDate = albumDate
        if let src = CGImageSourceCreateWithData(data as CFData, nil), let type = CGImageSourceGetType(src) {
            let have = existingMetadata(src)
            effectiveDate = have.date ?? albumDate
            let needDate = have.hasDate ? nil : albumDate
            let needCoord: Coord? = have.hasGPS ? nil : coord
            if needDate != nil || needCoord != nil,
               writeImage(src: src, type: type, to: dest, date: needDate, coord: needCoord) {
                setFileDate(dest, effectiveDate); return true
            }
        }
        // Nothing to embed (or embedding failed) — write the bytes as-is.
        guard (try? data.write(to: dest, options: .atomic)) != nil else { return false }
        setFileDate(dest, effectiveDate)
        return true
    }

    /// Lossless metadata-embedding write: copies the encoded image (no pixel
    /// re-encode, via `AddImageFromSource`) with the capture date and/or GPS set.
    nonisolated private static func writeImage(src: CGImageSource, type: CFString, to dest: URL,
                                               date: Date?, coord: Coord?) -> Bool {
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
        guard let dst = CGImageDestinationCreateWithURL(dest as CFURL, type, 1, nil) else { return false }
        CGImageDestinationAddImageFromSource(dst, src, 0, props as CFDictionary)
        return CGImageDestinationFinalize(dst)
    }

    nonisolated private static func setFileDate(_ url: URL, _ date: Date?) {
        guard let date else { return }
        try? FileManager.default.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: url.path)
    }

    /// EXIF/TIFF capture date + GPS presence, read from an in-memory image source.
    nonisolated private static func existingMetadata(_ src: CGImageSource) -> (hasDate: Bool, date: Date?, hasGPS: Bool) {
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return (false, nil, false) }
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

    nonisolated private static func geocode(_ place: String) async -> Coord? {
        guard let marks = try? await CLGeocoder().geocodeAddressString(place),
              let c = marks.first?.location?.coordinate, CLLocationCoordinate2DIsValid(c),
              !(c.latitude == 0 && c.longitude == 0) else { return nil }
        return Coord(lat: c.latitude, lng: c.longitude)
    }

    // MARK: - Networking

    /// Fetch a gallery page, retrying hard. This is the load-bearing reliability
    /// fix for coverage: when the site throttles during the listing burst, a failed
    /// fetch would silently drop a whole album (0 images) or even a whole subtree
    /// (a year/month and all its albums). Retry up to 5× with exponential backoff,
    /// bypassing the cache and rejecting throttle responses (non-2xx or a too-short
    /// body), so a transient 429/503/timeout doesn't lose photos.
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
        for attempt in 0..<5 {
            if let (data, resp) = try? await session.data(for: request(ignoreCache: attempt > 0)) {
                let ok = (resp as? HTTPURLResponse).map { (200...299).contains($0.statusCode) } ?? true
                if ok, let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
                   html.count > 200 {                                  // a real Coppermine page is large; short = error/throttle
                    return html
                }
            }
            if attempt < 4 { try? await Task.sleep(nanoseconds: UInt64(400_000_000) << attempt) }   // 0.4,0.8,1.6,3.2s
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

/// Plain-text diagnostic log for accessKardashian runs, written as
/// "accessKardashian Log.txt" beside the member folders (tap it in-app to read it,
/// or open it in Files). Buffered + appended in chunks so logging can't slow the
/// download it's measuring; starts fresh once it grows past a few MB. Best-effort
/// on a `@unchecked Sendable` lock, same pattern as the metadata stores.
final class AKLog: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    private let fileURL: URL
    private let start = Date()

    init(in parent: URL, member: String) {
        fileURL = parent.appendingPathComponent("accessKardashian Log.txt")
        if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 4_000_000 {
            try? FileManager.default.removeItem(at: fileURL)
        }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        add("===== \(df.string(from: start)) — \(member) =====")
    }

    /// Appends one line, stamped with seconds since the run started.
    func add(_ line: String) {
        lock.lock()
        lines.append(String(format: "[%7.1fs] ", Date().timeIntervalSince(start)) + line)
        let buffered = lines.count
        lock.unlock()
        if buffered >= 50 { flush() }
    }

    func flush() {
        lock.lock()
        guard !lines.isEmpty else { lock.unlock(); return }
        let chunk = lines.joined(separator: "\n") + "\n"
        lines.removeAll()
        lock.unlock()
        guard let data = chunk.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL)
        }
    }
}
