import SwiftUI
import Observation

/// App-wide state: the chosen root folder (with persistent access), the
/// navigation path, and the current sort. Uses the Observation framework so
/// view updates are reliable under Xcode's default-MainActor isolation.
@Observable
@MainActor
final class Library {
    var rootURL: URL?
    var rootName = ""
    var path: [URL] = []
    var sort: SortKey = .smart
    var favorites: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "photoBrowser.favorites") ?? [])
    var aiLabels: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "photoBrowser.ai") ?? [])
    /// Custom labels offered inside the "Taylor Swift" folder, keyed labelName →
    /// set of file paths (an item may carry several). Persisted as a dict of
    /// arrays since `UserDefaults` can't store `Set`.
    var customLabels: [String: Set<String>] = {
        let raw = UserDefaults.standard.dictionary(forKey: "photoBrowser.customLabels") as? [String: [String]] ?? [:]
        return raw.mapValues(Set.init)
    }()
    /// People library: person name → set of face IDs ("path#index"). Built by the
    /// approximate on-device "Find People" pass, then renamed/merged by the user.
    var people: [String: Set<String>] = {
        let raw = UserDefaults.standard.dictionary(forKey: "photoBrowser.people") as? [String: [String]] ?? [:]
        return raw.mapValues(Set.init)
    }()
    /// Bumps on any label change (toggle or move) so views re-query even when the
    /// label count is unchanged (e.g. a move rewrites a path without adding one).
    var labelsVersion = 0
    /// Bumps when files are added/edited from outside the folder view (e.g. the
    /// editor saving a cropped copy) so the current folder reloads.
    var changeToken = 0
    func contentDidChange() { changeToken += 1; folderYearsCache.removeAll(); listingCache.removeAll() }

    /// In-memory cache of recent folder listings so re-opening a folder paints
    /// instantly (then refreshes) — a big win on a slow external drive. Cleared on
    /// any content change; bounded to the most-recent folders.
    @ObservationIgnored private var listingCache: [String: [Entry]] = [:]
    @ObservationIgnored private var listingOrder: [String] = []
    func cachedListing(of folder: URL) -> [Entry]? { listingCache[folder.path] }
    func cacheListing(_ entries: [Entry], for folder: URL) {
        if listingCache[folder.path] == nil { listingOrder.append(folder.path) }
        listingCache[folder.path] = entries
        while listingOrder.count > 60 { listingCache.removeValue(forKey: listingOrder.removeFirst()) }
    }

    /// The last folder a Move/Copy sent items to, so the picker can default there.
    var lastTransferDestination: URL? = UserDefaults.standard.string(forKey: "photoBrowser.lastTransferDest")
        .map { URL(fileURLWithPath: $0) }
    func setLastTransferDestination(_ url: URL) {
        lastTransferDestination = url
        UserDefaults.standard.set(url.path, forKey: "photoBrowser.lastTransferDest")
    }

    /// Grid thumbnail minimum size (points); pinch-to-zoom adjusts it ±30%.
    var thumbSize: Double = (UserDefaults.standard.object(forKey: "photoBrowser.thumbSize") as? Double) ?? 110
    func setThumbSize(_ value: Double) {
        thumbSize = min(max(value, 70), 260)
        UserDefaults.standard.set(thumbSize, forKey: "photoBrowser.thumbSize")
    }
    /// App-stored caption overrides keyed by file path ("" = explicitly cleared).
    var captions: [String: String] = (UserDefaults.standard.dictionary(forKey: "photoBrowser.captions") as? [String: String]) ?? [:]
    /// Folder path → cover-image filename (stored under Application Support/folderCovers).
    var folderCovers: [String: String] = (UserDefaults.standard.dictionary(forKey: "photoBrowser.folderCovers") as? [String: String]) ?? [:]
    /// Drive file path → originating Photos-library asset identifier (for imports).
    var photoOrigins: [String: String] = (UserDefaults.standard.dictionary(forKey: "photoBrowser.photoOrigins") as? [String: String]) ?? [:]
    /// Folder path → birthday (stored as a Unix timestamp). Files in the folder and
    /// its subfolders get an "Age" computed from this and their EXIF capture date.
    var folderBirthdays: [String: Double] = (UserDefaults.standard.dictionary(forKey: "photoBrowser.birthdays") as? [String: Double]) ?? [:]
    /// Full recursive index of everything under the root — built once for fast
    /// search and the Library view.
    var index: [Entry] = []
    var indexing = false

    @ObservationIgnored private var activeRoot: URL?
    @ObservationIgnored private let bookmarkKey = "photoBrowser.folderBookmark"
    @ObservationIgnored private lazy var coversDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("folderCovers", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    // MARK: - Folder covers (custom album icons)

    /// File URL of a folder's custom cover image, or nil if it has none.
    func coverURL(for folder: URL) -> URL? {
        guard let name = folderCovers[folder.path] else { return nil }
        return coversDirectory.appendingPathComponent(name)
    }

    /// Saves a cropped image as `folder`'s cover (replacing any existing one).
    func setCover(_ image: UIImage, for folder: URL) {
        if let old = folderCovers[folder.path] {
            try? FileManager.default.removeItem(at: coversDirectory.appendingPathComponent(old))
        }
        guard let data = image.jpegData(compressionQuality: 0.9) else { return }
        let name = UUID().uuidString + ".jpg"
        do {
            try data.write(to: coversDirectory.appendingPathComponent(name))
            folderCovers[folder.path] = name
            UserDefaults.standard.set(folderCovers, forKey: "photoBrowser.folderCovers")
        } catch {}
    }

    // MARK: - Photos-library origin tracking (for imports)

    func setOrigin(_ assetID: String, for url: URL) {
        photoOrigins[url.path] = assetID
        UserDefaults.standard.set(photoOrigins, forKey: "photoBrowser.photoOrigins")
    }

    func origin(for url: URL) -> String? { photoOrigins[url.path] }

    func clearOrigins(_ urls: [URL]) {
        for u in urls { photoOrigins.removeValue(forKey: u.path) }
        UserDefaults.standard.set(photoOrigins, forKey: "photoBrowser.photoOrigins")
    }

    // MARK: - Folder birthday / Age

    /// The birthday set directly on `folder`, if any.
    func birthday(for folder: URL) -> Date? {
        folderBirthdays[folder.path].map { Date(timeIntervalSince1970: $0) }
    }

    func setBirthday(_ date: Date?, for folder: URL) {
        if let date { folderBirthdays[folder.path] = date.timeIntervalSince1970 }
        else { folderBirthdays.removeValue(forKey: folder.path) }
        UserDefaults.standard.set(folderBirthdays, forKey: "photoBrowser.birthdays")
        labelsVersion += 1
        changeToken += 1
    }

    /// The nearest birthday on `file`'s folder or any ancestor folder.
    func birthdayForFile(_ file: URL) -> Date? {
        Self.birthdayForFile(file, in: folderBirthdays)
    }

    /// Whether anything under (or above) `folder` carries a birthday — i.e. the
    /// Age filter/search is meaningful here.
    func hasBirthdayContext(_ folder: URL) -> Bool {
        let p = folder.path
        return folderBirthdays.keys.contains { $0 == p || $0.hasPrefix(p + "/") || p.hasPrefix($0 + "/") }
    }

    /// The nearest birthday on `file`'s folder or any ancestor folder.
    ///
    /// Walks the path as a **string** rather than calling
    /// `URL.deletingLastPathComponent()` in a loop: for some URLs that call never
    /// reaches a fixed point (it keeps prepending `../`), which spun this loop
    /// forever on the main thread and got the app watchdog-killed while rendering
    /// the info panel's "Age" row. Trimming the string strictly shrinks it each
    /// step, so this always terminates.
    nonisolated static func birthdayForFile(_ file: URL, in birthdays: [String: Double]) -> Date? {
        guard !birthdays.isEmpty else { return nil }
        var path = file.path
        while let slash = path.lastIndex(of: "/"), slash != path.startIndex {
            path = String(path[..<slash])              // drop the last component → parent dir
            if let ts = birthdays[path] { return Date(timeIntervalSince1970: ts) }
        }
        return nil
    }

    /// Age in whole years between a birthday and a capture date (nil if negative).
    nonisolated static func ageBetween(_ birthday: Date, _ date: Date) -> Int? {
        let comps = Calendar.current.dateComponents([.year], from: birthday, to: date)
        guard let y = comps.year, y >= 0 else { return nil }
        return y
    }

    /// Age for `file` given its capture date, using the nearest ancestor birthday.
    func age(forFile file: URL, captureDate: Date) -> Int? {
        guard let bd = birthdayForFile(file) else { return nil }
        return Self.ageBetween(bd, captureDate)
    }

    /// Every media file under `folder` (recursively) that has a computable age,
    /// paired with that age. Loads EXIF capture dates, so it's used lazily.
    nonisolated func agedMedia(under folder: URL, birthdays: [String: Double], sort: SortKey) async -> [(entry: Entry, age: Int)] {
        guard !birthdays.isEmpty else { return [] }
        return await Task.detached(priority: .userInitiated) { () -> [(entry: Entry, age: Int)] in
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
            guard let walker = FileManager.default.enumerator(
                at: folder, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else { return [] }
            var media: [Entry] = []
            for case let url as URL in walker {
                let rv = try? url.resourceValues(forKeys: keys)
                if rv?.isDirectory == true { continue }
                let kind = classify(url: url, isDirectory: false)
                guard kind == .image || kind == .video else { continue }
                // Only files actually under a birthday folder can have an age — skip
                // the rest so we don't read EXIF for the whole drive.
                guard Self.birthdayForFile(url, in: birthdays) != nil else { continue }
                media.append(Entry(url: url, name: url.lastPathComponent, kind: kind,
                                   size: Int64(rv?.fileSize ?? 0),
                                   modified: rv?.contentModificationDate ?? .distantPast))
            }
            guard !media.isEmpty else { return [] }

            var ageByURL: [URL: Int] = [:]
            var index = 0
            await withTaskGroup(of: (Entry, Date?).self) { group in
                let maxConcurrent = 8
                func addNext() {
                    guard index < media.count else { return }
                    let e = media[index]; index += 1
                    group.addTask { (e, await MetadataLoader.captureDate(for: e)) }
                }
                for _ in 0..<min(maxConcurrent, media.count) { addNext() }
                while let (e, date) = await group.next() {
                    if let bd = Self.birthdayForFile(e.url, in: birthdays), let date,
                       let age = Self.ageBetween(bd, date) {
                        ageByURL[e.url] = age
                    }
                    addNext()
                }
            }
            MetadataLoader.flushDateStore()    // persist any newly-read dates
            let order = Self.sortEntries(media.filter { ageByURL[$0.url] != nil }, by: sort)
            return order.map { (entry: $0, age: ageByURL[$0.url] ?? 0) }
        }.value
    }

    // MARK: - Captions

    func setCaption(_ text: String, for url: URL) {
        captions[url.path] = text.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(captions, forKey: "photoBrowser.captions")
    }

    /// Batch caption set (persists once) — avoids O(n²) UserDefaults writes when a
    /// bulk import applies hundreds of captions at once.
    func setCaptions(_ map: [String: String]) {
        guard !map.isEmpty else { return }
        for (k, v) in map { captions[k] = v.trimmingCharacters(in: .whitespacesAndNewlines) }
        UserDefaults.standard.set(captions, forKey: "photoBrowser.captions")
    }

    /// Reads existing captions embedded in the files (pull-in), bounded concurrency.
    nonisolated func fileCaptions(for entries: [Entry]) async -> [URL: String] {
        let files = entries.filter { !$0.isFolder }
        guard !files.isEmpty else { return [:] }
        var result: [URL: String] = [:]
        var index = 0
        let maxConcurrent = 8
        await withTaskGroup(of: (URL, String?).self) { group in
            func addNext() {
                guard index < files.count else { return }
                let e = files[index]; index += 1
                group.addTask { (e.url, await MetadataLoader.existingCaption(for: e)) }
            }
            for _ in 0..<min(maxConcurrent, files.count) { addNext() }
            while let (url, cap) = await group.next() {
                if let cap, !cap.isEmpty { result[url] = cap }
                addNext()
            }
        }
        return result
    }

    // MARK: - Favorites / To AI labels

    func isFavorite(_ url: URL) -> Bool { favorites.contains(url.path) }

    func toggleFavorite(_ url: URL) {
        if favorites.contains(url.path) { favorites.remove(url.path) } else { favorites.insert(url.path) }
        UserDefaults.standard.set(Array(favorites), forKey: "photoBrowser.favorites")
        labelsVersion += 1
    }

    func isAI(_ url: URL) -> Bool { aiLabels.contains(url.path) }

    func toggleAI(_ url: URL) {
        if aiLabels.contains(url.path) { aiLabels.remove(url.path) } else { aiLabels.insert(url.path) }
        UserDefaults.standard.set(Array(aiLabels), forKey: "photoBrowser.ai")
        labelsVersion += 1
    }

    // MARK: - Taylor Swift custom labels

    /// The fixed set of labels offered inside the "Taylor Swift" folder.
    static let taylorSwiftLabels = ["The Eras Tour", "Lover Bodysuit", "Grammys",
                                    "Midnights Bodysuit", "Reputation Bodysuit",
                                    "Movie", "AI", "The Life of a Showgirl", "Beach"]

    private func persistCustomLabels() {
        UserDefaults.standard.set(customLabels.mapValues(Array.init), forKey: "photoBrowser.customLabels")
    }

    // MARK: - People (faces)

    /// People scan runs on the Library so it keeps going when the People view is
    /// dismissed; detections are flushed periodically so it resumes after an exit.
    var peopleScanRunning = false
    var peopleScanProgress = 0.0
    @ObservationIgnored private var peopleScanBG = BackgroundTaskHolder()

    func startFindPeople(under folder: URL) {
        guard !peopleScanRunning else { return }
        peopleScanRunning = true; peopleScanProgress = 0
        peopleScanBG.begin(name: "Find People")
        let existing = people
        Task { [weak self] in
            guard let self else { return }
            let result = await self.findPeople(under: folder, existing: existing) { done, total in
                Task { @MainActor in self.peopleScanProgress = total > 0 ? Double(done) / Double(total) : 1 }
            }
            self.setPeople(result)
            self.peopleScanProgress = 1
            self.peopleScanRunning = false
            self.peopleScanBG.end()
        }
    }

    private func persistPeople() {
        UserDefaults.standard.set(people.mapValues(Array.init), forKey: "photoBrowser.people")
        labelsVersion += 1
    }
    func setPeople(_ p: [String: Set<String>]) { people = p.filter { !$0.value.isEmpty }; persistPeople() }
    func renamePerson(_ old: String, to new: String) {
        let name = new.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != old, let faces = people[old] else { return }
        people[old] = nil
        people[name, default: []].formUnion(faces)   // merge if the new name exists
        persistPeople()
    }
    func mergePeople(_ names: [String], into target: String) {
        guard people[target] != nil else { return }
        for n in names where n != target { if let f = people[n] { people[target, default: []].formUnion(f); people[n] = nil } }
        persistPeople()
    }
    func deletePerson(_ name: String) { people[name] = nil; persistPeople() }

    // MARK: - AI-generated images

    var aiGeneratedPaths: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "photoBrowser.aiGenerated") ?? [])
    func markAIGenerated(_ url: URL) {
        aiGeneratedPaths.insert(url.path)
        UserDefaults.standard.set(Array(aiGeneratedPaths), forKey: "photoBrowser.aiGenerated")
        labelsVersion += 1
    }
    func isAIGenerated(_ url: URL) -> Bool { aiGeneratedPaths.contains(url.path) }

    // MARK: - taylorpictures.net downloaded albums

    /// Coppermine album ids already downloaded, so the browser can mark them.
    var downloadedTaylorAlbums: Set<Int> = Set((UserDefaults.standard.array(forKey: "photoBrowser.tpDownloaded") as? [Int]) ?? [])
    func markTaylorAlbumDownloaded(_ id: Int) {
        guard downloadedTaylorAlbums.insert(id).inserted else { return }
        UserDefaults.standard.set(Array(downloadedTaylorAlbums), forKey: "photoBrowser.tpDownloaded")
    }
    func isTaylorAlbumDownloaded(_ id: Int) -> Bool { downloadedTaylorAlbums.contains(id) }

    // MARK: - Frame folders + Tinder-style clean up

    /// Folders produced by "Export All Frames" — "Start Clean Up" appears only here.
    var framesFolders: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "photoBrowser.framesFolders") ?? [])
    func markFramesFolder(_ url: URL) {
        guard framesFolders.insert(url.path).inserted else { return }
        UserDefaults.standard.set(Array(framesFolders), forKey: "photoBrowser.framesFolders")
    }
    func isFramesFolder(_ url: URL) -> Bool { framesFolders.contains(url.path) }

    /// Clean-up review state per folder: the set of item paths already decided on
    /// (kept or deleted). The queue on (re-)open is simply "viewable items not in
    /// this set", so it resumes correctly every run regardless of order.
    var cleanupReviewed: [String: [String]] = (UserDefaults.standard.dictionary(forKey: "photoBrowser.cleanupReviewed") as? [String: [String]]) ?? [:]
    func reviewedInCleanup(_ folder: URL) -> Set<String> { Set(cleanupReviewed[folder.path] ?? []) }
    func markCleanupReviewed(_ url: URL, in folder: URL) {
        var s = Set(cleanupReviewed[folder.path] ?? [])
        guard s.insert(url.path).inserted else { return }
        cleanupReviewed[folder.path] = Array(s)
        UserDefaults.standard.set(cleanupReviewed, forKey: "photoBrowser.cleanupReviewed")
    }
    func resetCleanup(_ folder: URL) {
        guard cleanupReviewed[folder.path] != nil else { return }
        cleanupReviewed.removeValue(forKey: folder.path)
        UserDefaults.standard.set(cleanupReviewed, forKey: "photoBrowser.cleanupReviewed")
    }

    // MARK: - Instagram profile folders

    /// Folder path → the Instagram profile downloaded into it (handle, last-updated,
    /// downloaded post ids for incremental "Get New", and photo/video counts).
    var instagramFolders: [String: IGFolderInfo] = {
        guard let data = UserDefaults.standard.data(forKey: "photoBrowser.instagramFolders"),
              let m = try? JSONDecoder().decode([String: IGFolderInfo].self, from: data) else { return [:] }
        return m
    }()
    func instagramInfo(for folder: URL) -> IGFolderInfo? { instagramFolders[folder.path] }
    func isInstagramFolder(_ folder: URL) -> Bool { instagramFolders[folder.path] != nil }
    func setInstagramInfo(_ info: IGFolderInfo, for folder: URL) {
        instagramFolders[folder.path] = info
        persistInstagramFolders()
        changeToken += 1
    }
    private func persistInstagramFolders() {
        if let data = try? JSONEncoder().encode(instagramFolders) {
            UserDefaults.standard.set(data, forKey: "photoBrowser.instagramFolders")
        }
    }

    /// Highlight subfolders (shown as bubbles inside an Instagram profile folder).
    var instagramHighlights: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "photoBrowser.instagramHighlights") ?? [])
    func isInstagramHighlight(_ folder: URL) -> Bool { instagramHighlights.contains(folder.path) }
    func markInstagramHighlight(_ folder: URL) {
        guard instagramHighlights.insert(folder.path).inserted else { return }
        UserDefaults.standard.set(Array(instagramHighlights), forKey: "photoBrowser.instagramHighlights")
    }

    /// Folders the user turned into "album highlights" — shown as bubbles like the
    /// Instagram ones (but for any folder).
    var albumHighlights: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "photoBrowser.albumHighlights") ?? [])
    func isAlbumHighlight(_ folder: URL) -> Bool { albumHighlights.contains(folder.path) }
    func setAlbumHighlight(_ on: Bool, for folder: URL) {
        if on { albumHighlights.insert(folder.path) } else { albumHighlights.remove(folder.path) }
        UserDefaults.standard.set(Array(albumHighlights), forKey: "photoBrowser.albumHighlights")
    }

    /// User-chosen order of the highlight bubbles within a folder (parent path →
    /// ordered child bubble paths). The Instagram bubble is always pinned first by
    /// the view regardless of this order; everything else follows it.
    var bubbleOrders: [String: [String]] = (UserDefaults.standard.dictionary(forKey: "photoBrowser.bubbleOrder") as? [String: [String]]) ?? [:]
    func bubbleOrder(for parent: URL) -> [String] { bubbleOrders[parent.path] ?? [] }
    func setBubbleOrder(_ paths: [String], for parent: URL) {
        bubbleOrders[parent.path] = paths
        UserDefaults.standard.set(bubbleOrders, forKey: "photoBrowser.bubbleOrder")
    }

    /// File path → posting Instagram handle ("Posted by"); presence also marks the
    /// item as coming from Instagram.
    var igPostedBy: [String: String] = (UserDefaults.standard.dictionary(forKey: "photoBrowser.igPostedBy") as? [String: String]) ?? [:]
    func postedBy(for url: URL) -> String? { igPostedBy[url.path] }
    func setPostedBy(_ handle: String, for url: URL) {
        igPostedBy[url.path] = handle
        UserDefaults.standard.set(igPostedBy, forKey: "photoBrowser.igPostedBy")
    }
    /// Batch "posted by" set (persists once) — avoids O(n²) writes on bulk imports.
    func setPostedBy(_ map: [String: String]) {
        guard !map.isEmpty else { return }
        for (k, v) in map { igPostedBy[k] = v }
        UserDefaults.standard.set(igPostedBy, forKey: "photoBrowser.igPostedBy")
    }

    /// Last Instagram handle downloaded from a folder, so reruns prefill it.
    var igLastHandle: [String: String] = (UserDefaults.standard.dictionary(forKey: "photoBrowser.igLastHandle") as? [String: String]) ?? [:]
    func lastIGHandle(for folder: URL) -> String? { igLastHandle[folder.path] }
    func setLastIGHandle(_ handle: String, for folder: URL) {
        igLastHandle[folder.path] = handle
        UserDefaults.standard.set(igLastHandle, forKey: "photoBrowser.igLastHandle")
    }

    // MARK: - accessKardashian per-member downloads

    /// The fixed Kardashian category labels, used like the Taylor Swift ones inside
    /// a member's folder (downloaded photos are tagged with one of these).
    static let kardashianLabels = ["Public Appearances", "Photoshoots", "Candids",
                                   "Brand Photos", "Fashion Shows", "Social Media", "Others"]

    /// Per-member download state: where the photos live, whether the gallery was
    /// fully crawled, and the last counts — so the UI can offer Resume vs. Fetch New
    /// vs. Re-download and remember it across launches. Keyed by member name.
    struct AKMember: Codable, Sendable {
        var folderPath: String
        var completed: Bool       // the whole gallery was crawled+downloaded (not paused)
        var total: Int            // images the last crawl found
        var downloaded: Int       // images present after the last run
        var updated: Double       // last-run timestamp
    }
    var accessKardashian: [String: AKMember] = {
        guard let data = UserDefaults.standard.data(forKey: "photoBrowser.accessKardashian"),
              let m = try? JSONDecoder().decode([String: AKMember].self, from: data) else { return [:] }
        return m
    }()
    func akMember(_ name: String) -> AKMember? { accessKardashian[name] }
    func setAKMember(_ name: String, _ state: AKMember?) {
        if let state { accessKardashian[name] = state } else { accessKardashian.removeValue(forKey: name) }
        if let data = try? JSONEncoder().encode(accessKardashian) {
            UserDefaults.standard.set(data, forKey: "photoBrowser.accessKardashian")
        }
        changeToken += 1
    }

    /// Member folder paths (so the folder view knows to show the Kardashian filter
    /// chips inside them or any subfolder).
    var kardashianFolders: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "photoBrowser.kardashianFolders") ?? [])
    func markKardashianFolder(_ folder: URL) {
        guard kardashianFolders.insert(folder.path).inserted else { return }
        UserDefaults.standard.set(Array(kardashianFolders), forKey: "photoBrowser.kardashianFolders")
    }
    /// Whether `folder` is a member folder or nested inside one.
    func inKardashianContext(_ folder: URL) -> Bool {
        let p = folder.path
        return kardashianFolders.contains { p == $0 || p.hasPrefix($0 + "/") }
    }

    /// Batch-applies custom labels (labelName → paths) in one persist — used by the
    /// Kardashian importer to tag thousands of downloaded photos by category.
    func addLabels(_ pathsByLabel: [String: [String]]) {
        var changed = false
        for (name, paths) in pathsByLabel where !paths.isEmpty {
            customLabels[name, default: []].formUnion(paths); changed = true
        }
        guard changed else { return }
        persistCustomLabels()
        labelsVersion += 1
    }

    // MARK: - "Not duplicates" (user-confirmed non-duplicate pairs)

    /// Pairs the user marked as NOT duplicates, as "pathA\npathB" (sorted), so a
    /// future Find-Duplicates run hides groups whose every pair is dismissed.
    var notDuplicatePairs: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "photoBrowser.notDuplicates") ?? [])

    private static func pairKey(_ a: String, _ b: String) -> String { a < b ? "\(a)\n\(b)" : "\(b)\n\(a)" }
    func areNotDuplicates(_ a: String, _ b: String) -> Bool { notDuplicatePairs.contains(Self.pairKey(a, b)) }
    /// Records every pair among `paths` as not-duplicates.
    func markNotDuplicates(_ paths: [String]) {
        guard paths.count >= 2 else { return }
        for i in 0..<paths.count { for j in (i + 1)..<paths.count { notDuplicatePairs.insert(Self.pairKey(paths[i], paths[j])) } }
        UserDefaults.standard.set(Array(notDuplicatePairs), forKey: "photoBrowser.notDuplicates")
    }
    /// The distinct photo paths a person appears in (face IDs are "path#index").
    func photoPaths(forPerson name: String) -> Set<String> {
        Set((people[name] ?? []).map(Self.pathOfFaceID))
    }
    /// Splits a face ID ("path#index") at its last "#" (paths rarely contain one).
    static func pathOfFaceID(_ id: String) -> String {
        guard let h = id.lastIndex(of: "#") else { return id }
        return String(id[..<h])
    }
    /// The photo path + normalized face rect for a face ID, for rendering a crop.
    nonisolated func faceRect(for faceID: String) -> (path: String, rect: [CGFloat])? {
        guard let h = faceID.lastIndex(of: "#"), let idx = Int(faceID[faceID.index(after: h)...]) else { return nil }
        let path = String(faceID[..<h])
        guard let faces = FaceStore.shared.faces(path), idx < faces.count else { return nil }
        return (path, faces[idx].rect)
    }

    /// Every path carrying at least one custom label (union across all labels).
    func allLabeledPaths() -> Set<String> {
        customLabels.values.reduce(into: Set<String>()) { $0.formUnion($1) }
    }

    /// All photos/videos under `folder` (recursively) that carry *no* custom
    /// label yet — backs the "No Label" filter. Walks the tree off the main actor.
    nonisolated func unlabeledMedia(under folder: URL, labeled: Set<String>, sort: SortKey) async -> [Entry] {
        await Task.detached(priority: .userInitiated) {
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
            guard let walker = FileManager.default.enumerator(
                at: folder, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else { return [] }
            var result: [Entry] = []
            for case let url as URL in walker {
                let rv = try? url.resourceValues(forKeys: keys)
                if rv?.isDirectory == true { continue }
                let kind = classify(url: url, isDirectory: false)
                guard kind == .image || kind == .video, !labeled.contains(url.path) else { continue }
                result.append(Entry(url: url, name: url.lastPathComponent, kind: kind,
                                    size: Int64(rv?.fileSize ?? 0),
                                    modified: rv?.contentModificationDate ?? .distantPast))
            }
            return Self.sortEntries(result, by: sort)
        }.value
    }

    /// Every custom label currently attached to `url`.
    func labels(for url: URL) -> Set<String> {
        var names: Set<String> = []
        for (name, paths) in customLabels where paths.contains(url.path) { names.insert(name) }
        return names
    }

    func hasLabel(_ name: String, _ url: URL) -> Bool { customLabels[name]?.contains(url.path) ?? false }

    func toggleLabel(_ name: String, on url: URL) { setLabel(name, on: url, !hasLabel(name, url)) }

    func setLabel(_ name: String, on url: URL, _ on: Bool) {
        var paths = customLabels[name] ?? []
        if on { paths.insert(url.path) } else { paths.remove(url.path) }
        customLabels[name] = paths
        persistCustomLabels()
        labelsVersion += 1
    }

    /// Paths carrying *every* one of `names` (AND semantics); empty `names` → empty.
    func pathsMatchingAll(_ names: Set<String>) -> Set<String> {
        guard !names.isEmpty else { return [] }
        var result: Set<String>?
        for name in names {
            let paths = customLabels[name] ?? []
            result = result.map { $0.intersection(paths) } ?? paths
        }
        return result ?? []
    }

    /// Drops the given items from every custom label (used after deletion).
    func clearLabels(_ urls: [URL]) {
        let paths = Set(urls.map(\.path))
        for name in Array(customLabels.keys) { customLabels[name]?.subtract(paths) }
        persistCustomLabels()
        labelsVersion += 1
    }

    /// Keeps Favorite / To AI labels and captions attached to an item after it's
    /// moved or renamed within the app. Rewrites the stored path (and, when a
    /// folder moves, every label/caption for items underneath it).
    /// Keeps labels, captions, covers, etc. attached to an item after it's moved or
    /// renamed within the app, by rewriting the stored path (and, for a folder, every
    /// path underneath it).
    func itemMoved(from oldURL: URL, to newURL: URL) {
        let old = oldURL.path, new = newURL.path
        applyRemap { p in (p == old || p.hasPrefix(old + "/")) ? new + p.dropFirst(old.count) : p }
    }

    /// Batch version: re-keys all moved items in a single pass with one persist, so
    /// moving a large selection doesn't do N×(serialize + write) on the main thread
    /// (which froze/killed the app).
    func itemsMoved(_ moves: [(from: URL, to: URL)]) {
        guard !moves.isEmpty else { return }
        let pairs = moves.map { (old: $0.from.path, new: $0.to.path) }
        applyRemap { p in
            for pr in pairs where p == pr.old || p.hasPrefix(pr.old + "/") { return pr.new + p.dropFirst(pr.old.count) }
            return p
        }
    }

    /// Applies `remap` to every path-keyed collection, then persists once.
    private func applyRemap(_ remap: (String) -> String) {
        favorites = Set(favorites.map(remap))
        aiLabels = Set(aiLabels.map(remap))
        framesFolders = Set(framesFolders.map(remap))
        kardashianFolders = Set(kardashianFolders.map(remap))
        instagramHighlights = Set(instagramHighlights.map(remap))
        albumHighlights = Set(albumHighlights.map(remap))
        customLabels = customLabels.mapValues { Set($0.map(remap)) }
        captions = remapKeys(captions, remap)
        folderCovers = remapKeys(folderCovers, remap)
        photoOrigins = remapKeys(photoOrigins, remap)
        igPostedBy = remapKeys(igPostedBy, remap)
        igLastHandle = remapKeys(igLastHandle, remap)
        folderBirthdays = remapKeys(folderBirthdays, remap)
        instagramFolders = remapKeys(instagramFolders, remap)
        bubbleOrders = Dictionary(bubbleOrders.map { (remap($0.key), $0.value.map(remap)) }, uniquingKeysWith: { a, _ in a })
        for (name, var state) in accessKardashian {
            let nf = remap(state.folderPath)
            if nf != state.folderPath { state.folderPath = nf; accessKardashian[name] = state }
        }

        UserDefaults.standard.set(Array(favorites), forKey: "photoBrowser.favorites")
        UserDefaults.standard.set(Array(aiLabels), forKey: "photoBrowser.ai")
        UserDefaults.standard.set(Array(framesFolders), forKey: "photoBrowser.framesFolders")
        UserDefaults.standard.set(Array(kardashianFolders), forKey: "photoBrowser.kardashianFolders")
        UserDefaults.standard.set(Array(instagramHighlights), forKey: "photoBrowser.instagramHighlights")
        UserDefaults.standard.set(Array(albumHighlights), forKey: "photoBrowser.albumHighlights")
        UserDefaults.standard.set(captions, forKey: "photoBrowser.captions")
        UserDefaults.standard.set(folderCovers, forKey: "photoBrowser.folderCovers")
        UserDefaults.standard.set(photoOrigins, forKey: "photoBrowser.photoOrigins")
        UserDefaults.standard.set(igPostedBy, forKey: "photoBrowser.igPostedBy")
        UserDefaults.standard.set(igLastHandle, forKey: "photoBrowser.igLastHandle")
        UserDefaults.standard.set(folderBirthdays, forKey: "photoBrowser.birthdays")
        UserDefaults.standard.set(bubbleOrders, forKey: "photoBrowser.bubbleOrder")
        persistCustomLabels()
        persistInstagramFolders()
        if let data = try? JSONEncoder().encode(accessKardashian) {
            UserDefaults.standard.set(data, forKey: "photoBrowser.accessKardashian")
        }
        labelsVersion += 1
    }

    private func remapKeys<V>(_ dict: [String: V], _ remap: (String) -> String) -> [String: V] {
        Dictionary(dict.map { (remap($0.key), $0.value) }, uniquingKeysWith: { a, _ in a })
    }

    /// Re-keys all per-item data (Favorites, To AI, captions, album covers, Photos
    /// origins) from items under `fromRoot` to the matching paths under `toRoot` —
    /// used to carry labels across drives. `removeSource` removes the originals (a
    /// move); `verifyExists` only migrates keys whose target file actually exists
    /// at the new location (used by the re-link tool).
    func migrateMetadata(fromRoot: URL, toRoot: URL, removeSource: Bool, verifyExists: Bool) {
        let from = fromRoot.path, to = toRoot.path
        let fm = FileManager.default
        func mapped(_ old: String) -> String? {
            guard old == from || old.hasPrefix(from + "/") else { return nil }
            let np = to + old.dropFirst(from.count)
            if verifyExists, !fm.fileExists(atPath: np) { return nil }
            return np
        }
        favorites = migrateSet(favorites, map: mapped, removeSource: removeSource)
        aiLabels  = migrateSet(aiLabels,  map: mapped, removeSource: removeSource)
        customLabels = customLabels.mapValues { migrateSet($0, map: mapped, removeSource: removeSource) }
        captions     = migrateDict(captions, map: mapped, removeSource: removeSource)
        photoOrigins = migrateDict(photoOrigins, map: mapped, removeSource: removeSource)

        // Folder covers: copy each cover image so the new path owns its own file.
        var newCovers = folderCovers
        for (key, filename) in folderCovers {
            guard let np = mapped(key) else { continue }
            let newName = UUID().uuidString + ".jpg"
            try? fm.copyItem(at: coversDirectory.appendingPathComponent(filename),
                             to: coversDirectory.appendingPathComponent(newName))
            newCovers[np] = newName
            if removeSource {
                try? fm.removeItem(at: coversDirectory.appendingPathComponent(filename))
                newCovers.removeValue(forKey: key)
            }
        }
        folderCovers = newCovers

        // Folder birthdays follow their folders too.
        var newBirthdays = folderBirthdays
        for (key, ts) in folderBirthdays {
            guard let np = mapped(key) else { continue }
            newBirthdays[np] = ts
            if removeSource { newBirthdays.removeValue(forKey: key) }
        }
        folderBirthdays = newBirthdays
        UserDefaults.standard.set(folderBirthdays, forKey: "photoBrowser.birthdays")

        UserDefaults.standard.set(Array(favorites), forKey: "photoBrowser.favorites")
        UserDefaults.standard.set(Array(aiLabels), forKey: "photoBrowser.ai")
        UserDefaults.standard.set(captions, forKey: "photoBrowser.captions")
        UserDefaults.standard.set(folderCovers, forKey: "photoBrowser.folderCovers")
        UserDefaults.standard.set(photoOrigins, forKey: "photoBrowser.photoOrigins")
        persistCustomLabels()
        labelsVersion += 1
        changeToken += 1
    }

    private func migrateSet(_ set: Set<String>, map: (String) -> String?, removeSource: Bool) -> Set<String> {
        var result = set
        for path in set {
            guard let np = map(path) else { continue }
            result.insert(np)
            if removeSource { result.remove(path) }
        }
        return result
    }

    private func migrateDict(_ dict: [String: String], map: (String) -> String?, removeSource: Bool) -> [String: String] {
        var result = dict
        for (key, value) in dict {
            guard let np = map(key) else { continue }
            result[np] = value
            if removeSource { result.removeValue(forKey: key) }
        }
        return result
    }

    /// Labeled items (favorites or To AI) at or below `folder`, including folders.
    /// Resolves saved paths directly (no full-tree walk) so it's fast on big drives.
    nonisolated func labeledEntries(under folder: URL, paths: Set<String>, sort: SortKey) async -> [Entry] {
        guard !paths.isEmpty else { return [] }
        let rootPath = folder.path
        return await Task.detached(priority: .userInitiated) {
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
            var result: [Entry] = []
            for path in paths where path == rootPath || path.hasPrefix(rootPath + "/") {
                let url = URL(fileURLWithPath: path)
                guard let rv = try? url.resourceValues(forKeys: keys) else { continue }
                result.append(Entry(url: url, name: url.lastPathComponent,
                                    kind: classify(url: url, isDirectory: rv.isDirectory ?? false),
                                    size: Int64(rv.fileSize ?? 0),
                                    modified: rv.contentModificationDate ?? .distantPast))
            }
            return Self.sortEntries(result, by: sort)
        }.value
    }

    /// Recursive search by filename (and app caption) from `folder` downward.
    nonisolated func search(in folder: URL, query: String, captions: [String: String], sort: SortKey) async -> [Entry] {
        let q = query.lowercased()
        guard !q.isEmpty else { return [] }
        return await Task.detached(priority: .userInitiated) {
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
            guard let walker = FileManager.default.enumerator(
                at: folder, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else { return [] }
            var result: [Entry] = []
            for case let url as URL in walker {
                let rv = try? url.resourceValues(forKeys: keys)
                let isDir = rv?.isDirectory ?? false
                let entry = Entry(url: url, name: url.lastPathComponent,
                                  kind: classify(url: url, isDirectory: isDir),
                                  size: Int64(rv?.fileSize ?? 0),
                                  modified: rv?.contentModificationDate ?? .distantPast)
                let nameMatch = entry.name.lowercased().contains(q)
                let capMatch = captions[url.path]?.lowercased().contains(q) ?? false
                let ocrMatch = !nameMatch && !capMatch && (MetadataLoader.ocrTextCached(for: entry)?.contains(q) ?? false)
                guard nameMatch || capMatch || ocrMatch else { continue }
                result.append(entry)
            }
            return Self.sortEntries(result, by: sort)
        }.value
    }

    /// Runs on-device OCR over every photo under `folder` (recursively, 8 at a time)
    /// and caches the recognized text so search can match words printed in photos.
    /// Already-indexed photos are skipped by the per-file cache. Returns the count.
    nonisolated func buildTextIndex(under folder: URL, progress: @escaping @Sendable (Int, Int) -> Void) async -> Int {
        let images = await Self.enumerateAll(folder).filter { $0.kind == .image }
        let total = images.count
        guard total > 0 else { return 0 }
        var index = 0, done = 0
        await withTaskGroup(of: Void.self) { group in
            func addNext() {
                guard index < total else { return }
                let e = images[index]; index += 1
                group.addTask { _ = await MetadataLoader.ocrText(for: e) }
            }
            for _ in 0..<min(8, total) { addNext() }
            while await group.next() != nil { done += 1; progress(done, total); addNext() }
        }
        MetadataLoader.flushOCRStore()
        return total
    }

    /// Detects faces under `folder` (cached), then groups still-unassigned faces by
    /// feature-print similarity, attaching each cluster to the closest existing
    /// person or naming a new "Person N". Existing assignments (incl. manual edits)
    /// are never disturbed. Returns the new people map; the caller persists it.
    nonisolated func findPeople(under folder: URL, existing: [String: Set<String>],
                                progress: @escaping @Sendable (Int, Int) -> Void) async -> [String: Set<String>] {
        let images = await Self.enumerateAll(folder).filter { $0.kind == .image }
        let total = images.count
        guard total > 0 else { return existing }

        var index = 0, done = 0
        await withTaskGroup(of: Void.self) { group in
            func addNext() {
                guard index < total else { return }
                let path = images[index].url.path; index += 1
                group.addTask {
                    if FaceStore.shared.faces(path) == nil {
                        FaceStore.shared.store(path, await FaceAnalysis.analyze(URL(fileURLWithPath: path)))
                    }
                }
            }
            for _ in 0..<min(12, total) { addNext() }          // wider fan-out for speed
            while await group.next() != nil {
                done += 1; progress(done, total)
                if done % 20 == 0 { FaceStore.shared.flush() }  // persist progress so a mid-scan exit resumes
                addNext()
            }
        }
        FaceStore.shared.flush()

        // Collect every face's vector, keyed faceID = "path#index".
        var vec: [String: [Float]] = [:]
        for e in images {
            for (i, f) in (FaceStore.shared.faces(e.url.path) ?? []).enumerated() where !f.print.isEmpty {
                vec["\(e.url.path)#\(i)"] = f.print
            }
        }
        let assigned = Set(existing.values.flatMap { $0 })
        let unassigned = vec.keys.filter { !assigned.contains($0) }
        let t = FaceAnalysis.sameFaceThreshold

        // Greedy-cluster the unassigned faces.
        var clusters: [[String]] = []
        var reps: [[Float]] = []
        for id in unassigned {
            guard let v = vec[id] else { continue }
            var best = -1, i = 0; var bestD = Float.greatestFiniteMagnitude
            for r in reps { let d = FaceAnalysis.distance(v, r); if d < bestD { bestD = d; best = i }; i += 1 }
            if best >= 0, bestD < t { clusters[best].append(id) } else { clusters.append([id]); reps.append(v) }
        }

        // Attach each cluster to the closest existing person, else a new "Person N".
        var people = existing
        var personRep: [String: [Float]] = [:]
        for (name, ids) in existing { if let id = ids.first(where: { vec[$0] != nil }) { personRep[name] = vec[id] } }
        var counter = 1
        for (ci, cluster) in clusters.enumerated() {
            let rep = reps[ci]
            var match: String?; var matchD = Float.greatestFiniteMagnitude
            for (name, pr) in personRep { let d = FaceAnalysis.distance(rep, pr); if d < matchD { matchD = d; match = name } }
            if let match, matchD < t {
                people[match, default: []].formUnion(cluster)
            } else {
                var name = "Person \(counter)"
                while people[name] != nil { counter += 1; name = "Person \(counter)" }
                people[name] = Set(cluster); personRep[name] = rep; counter += 1
            }
        }
        return people
    }

    // MARK: - Full index (fast search / Library)

    func buildIndex() {
        guard let root = rootURL else { return }
        indexing = true
        Task {
            let all = await Self.enumerateAll(root)
            self.index = all
            self.indexing = false
        }
    }

    nonisolated static func enumerateAll(_ root: URL) async -> [Entry] {
        await Task.detached(priority: .utility) {
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
            guard let walker = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else { return [] }
            var result: [Entry] = []
            for case let url as URL in walker {
                let rv = try? url.resourceValues(forKeys: keys)
                result.append(Entry(url: url, name: url.lastPathComponent,
                                    kind: classify(url: url, isDirectory: rv?.isDirectory ?? false),
                                    size: Int64(rv?.fileSize ?? 0),
                                    modified: rv?.contentModificationDate ?? .distantPast))
            }
            return result
        }.value
    }

    /// In-memory search over the prebuilt index (instant once the index exists).
    func searchIndex(under folder: URL, query: String, captions: [String: String], sort: SortKey) -> [Entry] {
        let q = query.lowercased()
        let base = folder.path
        let matches = index.filter { e in
            (e.url.path == base || e.url.path.hasPrefix(base + "/")) &&
            (e.name.lowercased().contains(q) || (captions[e.url.path]?.lowercased().contains(q) ?? false)
             || (MetadataLoader.ocrTextCached(for: e)?.contains(q) ?? false))   // text inside photos
        }
        return Self.sortEntries(matches, by: sort)
    }

    // MARK: - Choosing / restoring the root folder

    func chooseFolder(_ url: URL) {
        if let prev = activeRoot { prev.stopAccessingSecurityScopedResource() }
        _ = url.startAccessingSecurityScopedResource()   // best-effort; keep for session
        activeRoot = url
        rootURL = url
        rootName = url.lastPathComponent
        path = []
        if let data = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: bookmarkKey)
        }
        buildIndex()
    }

    func restoreLastFolder() {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [],
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else { return }
        _ = url.startAccessingSecurityScopedResource()
        activeRoot = url
        rootURL = url
        rootName = url.lastPathComponent
        buildIndex()
    }

    func goHome() { path.removeAll() }

    /// Reads capture dates (EXIF/creation) for the given files, bounded to a few
    /// concurrent reads so big folders don't stall.
    nonisolated func captureDates(for entries: [Entry]) async -> [URL: Date] {
        let files = entries.filter { !$0.isFolder }
        guard !files.isEmpty else { return [:] }
        var result: [URL: Date] = [:]
        var index = 0
        let maxConcurrent = 8
        await withTaskGroup(of: (URL, Date?).self) { group in
            func addNext() {
                guard index < files.count else { return }
                let e = files[index]; index += 1
                group.addTask { (e.url, await MetadataLoader.captureDate(for: e)) }
            }
            for _ in 0..<min(maxConcurrent, files.count) { addNext() }
            while let (url, date) = await group.next() {
                if let date { result[url] = date }
                addNext()
            }
        }
        MetadataLoader.flushDateStore()    // persist any newly-read dates
        return result
    }

    /// Reads dimensions + HDR for media files (for resolution/HDR filters).
    nonisolated func mediaSpecs(for entries: [Entry]) async -> [URL: MediaSpec] {
        let media = entries.filter { $0.kind == .image || $0.kind == .video }
        guard !media.isEmpty else { return [:] }
        var result: [URL: MediaSpec] = [:]
        var index = 0
        let maxConcurrent = 8
        await withTaskGroup(of: (URL, MediaSpec).self) { group in
            func addNext() {
                guard index < media.count else { return }
                let e = media[index]; index += 1
                group.addTask { (e.url, await MetadataLoader.mediaSpec(for: e)) }
            }
            for _ in 0..<min(maxConcurrent, media.count) { addNext() }
            while let (url, spec) = await group.next() {
                result[url] = spec
                addNext()
            }
        }
        return result
    }

    // MARK: - Folder year index (for hiding folders under a year filter)

    /// Years present anywhere under a folder (capture date, else file modified).
    /// Cached per folder path and cleared on `contentDidChange`; computed lazily
    /// off the main thread, reusing the per-file capture-date cache.
    @ObservationIgnored private var folderYearsCache: [String: Set<Int>] = [:]

    func folderYears(of folder: URL) async -> Set<Int> {
        if let cached = folderYearsCache[folder.path] { return cached }
        let (media, modified) = await Self.walkMedia(of: folder)
        let dates = await captureDates(for: media)
        let cal = Calendar.current
        var years = Set<Int>()
        for (i, e) in media.enumerated() {
            years.insert(cal.component(.year, from: dates[e.url] ?? modified[i]))
        }
        folderYearsCache[folder.path] = years
        return years
    }

    /// Every media file under `folder` (recursively) with its file modified date.
    private nonisolated static func walkMedia(of folder: URL) async -> (media: [Entry], modified: [Date]) {
        await Task.detached(priority: .utility) { () -> ([Entry], [Date]) in
            var media: [Entry] = []
            var modified: [Date] = []
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .contentModificationDateKey]
            guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: Array(keys),
                                                              options: [.skipsHiddenFiles]) else { return ([], []) }
            for case let url as URL in walker {
                let rv = try? url.resourceValues(forKeys: keys)
                if rv?.isDirectory == true { continue }
                let kind = classify(url: url, isDirectory: false)
                guard kind == .image || kind == .video else { continue }
                media.append(Entry(url: url, name: url.lastPathComponent, kind: kind, size: 0, modified: .distantPast))
                modified.append(rv?.contentModificationDate ?? .distantPast)
            }
            return (media, modified)
        }.value
    }

    // MARK: - Folder statistics (Get Info)

    nonisolated func folderStats(of folder: URL) async -> FolderStats {
        // 1) Walk the tree: counts, size, and the media list (off the main thread).
        let base = await Task.detached(priority: .userInitiated) { () -> FolderStats in
            var stats = FolderStats()
            let fm = FileManager.default
            if let rv = try? folder.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey]) {
                stats.created = rv.creationDate
                stats.modified = rv.contentModificationDate
            }
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
            guard let walker = fm.enumerator(at: folder, includingPropertiesForKeys: Array(keys),
                                             options: [.skipsHiddenFiles]) else { return stats }
            for case let url as URL in walker {
                let rv = try? url.resourceValues(forKeys: keys)
                if rv?.isDirectory == true { stats.subfolders += 1; continue }
                stats.size += Int64(rv?.fileSize ?? 0)
                let kind = classify(url: url, isDirectory: false)
                if kind == .image { stats.photos += 1 }
                else if kind == .video { stats.videos += 1 }
                if kind == .image || kind == .video {
                    stats.mediaURLs.append(url)
                    stats.mediaModified.append(rv?.contentModificationDate ?? .distantPast)
                }
            }
            return stats
        }.value

        // 2) Date span from capture dates (fallback to modified) for the media found.
        var stats = base
        let mediaEntries = base.mediaURLs.map {
            Entry(url: $0, name: $0.lastPathComponent, kind: classify(url: $0, isDirectory: false), size: 0, modified: .distantPast)
        }
        let dates = await captureDates(for: mediaEntries)
        for (i, url) in base.mediaURLs.enumerated() {
            let d = dates[url] ?? base.mediaModified[i]
            if stats.minDate == nil || d < stats.minDate! { stats.minDate = d }
            if stats.maxDate == nil || d > stats.maxDate! { stats.maxDate = d }
        }
        stats.mediaURLs = []; stats.mediaModified = []   // don't retain
        return stats
    }

    // MARK: - Listing a single directory (non-recursive, off the main thread)

    nonisolated func listing(of folder: URL, sort: SortKey) async -> [Entry] {
        await Task.detached(priority: .userInitiated) {
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
            guard let urls = try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else {
                return []
            }
            var entries: [Entry] = []
            entries.reserveCapacity(urls.count)
            for url in urls {
                let rv = try? url.resourceValues(forKeys: keys)
                let isDir = rv?.isDirectory ?? false
                entries.append(Entry(url: url,
                                     name: url.lastPathComponent,
                                     kind: classify(url: url, isDirectory: isDir),
                                     size: Int64(rv?.fileSize ?? 0),
                                     modified: rv?.contentModificationDate ?? .distantPast))
            }
            return Self.sortEntries(entries, by: sort)
        }.value
    }

    nonisolated static func sortEntries(_ entries: [Entry], by sort: SortKey) -> [Entry] {
        let nameAsc: (Entry, Entry) -> Bool = {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        if sort == .kind {
            return entries.sorted { a, b in
                a.kind.sortRank != b.kind.sortRank ? a.kind.sortRank < b.kind.sortRank : nameAsc(a, b)
            }
        }
        if sort == .smart {
            // The default: folders alphabetical, then photos/videos newest-first.
            return entries.sorted { a, b in
                if a.isFolder != b.isFolder { return a.isFolder }
                if a.isFolder { return nameAsc(a, b) }
                return a.modified != b.modified ? a.modified > b.modified : nameAsc(a, b)
            }
        }
        return entries.sorted { a, b in
            if a.isFolder != b.isFolder { return a.isFolder }   // folders always first
            switch sort {
            case .nameAsc:  return nameAsc(a, b)
            case .nameDesc: return a.name.localizedStandardCompare(b.name) == .orderedDescending
            case .dateDesc: return a.modified > b.modified
            case .dateAsc:  return a.modified < b.modified
            case .sizeDesc: return a.size > b.size
            case .sizeAsc:  return a.size < b.size
            case .smart, .kind, .ageAsc, .ageDesc: return nameAsc(a, b)   // handled above / in the view
            }
        }
    }
}
