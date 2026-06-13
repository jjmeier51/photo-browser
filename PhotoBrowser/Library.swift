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
    var sort: SortKey = .nameAsc
    var favorites: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "photoBrowser.favorites") ?? [])
    var aiLabels: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "photoBrowser.ai") ?? [])
    /// Custom labels offered inside the "Taylor Swift" folder, keyed labelName →
    /// set of file paths (an item may carry several). Persisted as a dict of
    /// arrays since `UserDefaults` can't store `Set`.
    var customLabels: [String: Set<String>] = {
        let raw = UserDefaults.standard.dictionary(forKey: "photoBrowser.customLabels") as? [String: [String]] ?? [:]
        return raw.mapValues(Set.init)
    }()
    /// Bumps on any label change (toggle or move) so views re-query even when the
    /// label count is unchanged (e.g. a move rewrites a path without adding one).
    var labelsVersion = 0
    /// Bumps when files are added/edited from outside the folder view (e.g. the
    /// editor saving a cropped copy) so the current folder reloads.
    var changeToken = 0
    func contentDidChange() { changeToken += 1 }

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

    nonisolated static func birthdayForFile(_ file: URL, in birthdays: [String: Double]) -> Date? {
        guard !birthdays.isEmpty else { return nil }
        var dir = file.deletingLastPathComponent()
        while true {
            if let ts = birthdays[dir.path] { return Date(timeIntervalSince1970: ts) }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { return nil }
            dir = parent
        }
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
            let order = Self.sortEntries(media.filter { ageByURL[$0.url] != nil }, by: sort)
            return order.map { (entry: $0, age: ageByURL[$0.url] ?? 0) }
        }.value
    }

    // MARK: - Captions

    func setCaption(_ text: String, for url: URL) {
        captions[url.path] = text.trimmingCharacters(in: .whitespacesAndNewlines)
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
                                    "Midnights Bodysuit", "Reputation Bodysuit"]

    private func persistCustomLabels() {
        UserDefaults.standard.set(customLabels.mapValues(Array.init), forKey: "photoBrowser.customLabels")
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
    func itemMoved(from oldURL: URL, to newURL: URL) {
        let old = oldURL.path, new = newURL.path
        favorites = remapPaths(favorites, old: old, new: new)
        aiLabels  = remapPaths(aiLabels,  old: old, new: new)
        customLabels = customLabels.mapValues { remapPaths($0, old: old, new: new) }

        captions = remapDict(captions, old: old, new: new)
        folderCovers = remapDict(folderCovers, old: old, new: new)
        photoOrigins = remapDict(photoOrigins, old: old, new: new)

        UserDefaults.standard.set(Array(favorites), forKey: "photoBrowser.favorites")
        UserDefaults.standard.set(Array(aiLabels), forKey: "photoBrowser.ai")
        UserDefaults.standard.set(captions, forKey: "photoBrowser.captions")
        UserDefaults.standard.set(folderCovers, forKey: "photoBrowser.folderCovers")
        UserDefaults.standard.set(photoOrigins, forKey: "photoBrowser.photoOrigins")
        persistCustomLabels()
        labelsVersion += 1
    }

    /// Returns `dict` with any key equal to `old` (or under `old/`) re-pointed to `new`.
    private func remapDict(_ dict: [String: String], old: String, new: String) -> [String: String] {
        var result = dict
        for (key, value) in dict where key == old || key.hasPrefix(old + "/") {
            result.removeValue(forKey: key)
            result[new + key.dropFirst(old.count)] = value
        }
        return result
    }

    /// Returns `set` with `old` (and any path under `old/`) re-pointed to `new`.
    private func remapPaths(_ set: Set<String>, old: String, new: String) -> Set<String> {
        var result = set
        for path in set where path == old || path.hasPrefix(old + "/") {
            result.remove(path)
            result.insert(new + path.dropFirst(old.count))
        }
        return result
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
                let nameMatch = url.lastPathComponent.lowercased().contains(q)
                let capMatch = captions[url.path]?.lowercased().contains(q) ?? false
                guard nameMatch || capMatch else { continue }
                let rv = try? url.resourceValues(forKeys: keys)
                let isDir = rv?.isDirectory ?? false
                result.append(Entry(url: url, name: url.lastPathComponent,
                                    kind: classify(url: url, isDirectory: isDir),
                                    size: Int64(rv?.fileSize ?? 0),
                                    modified: rv?.contentModificationDate ?? .distantPast))
            }
            return Self.sortEntries(result, by: sort)
        }.value
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
            (e.name.lowercased().contains(q) || (captions[e.url.path]?.lowercased().contains(q) ?? false))
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
        return entries.sorted { a, b in
            if a.isFolder != b.isFolder { return a.isFolder }   // folders always first
            switch sort {
            case .nameAsc:  return nameAsc(a, b)
            case .nameDesc: return a.name.localizedStandardCompare(b.name) == .orderedDescending
            case .dateDesc: return a.modified > b.modified
            case .dateAsc:  return a.modified < b.modified
            case .sizeDesc: return a.size > b.size
            case .sizeAsc:  return a.size < b.size
            case .kind, .ageAsc, .ageDesc: return nameAsc(a, b)   // age applied in the view
            }
        }
    }
}
