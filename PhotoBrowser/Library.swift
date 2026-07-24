import SwiftUI
import Observation
import CryptoKit

/// App-wide state: the chosen root folder (with persistent access), the
/// navigation path, and the current sort. Uses the Observation framework so
/// view updates are reliable under Xcode's default-MainActor isolation.
@Observable
@MainActor
final class Library {
    var rootURL: URL?
    var rootName = ""
    /// True when a saved bookmark exists but the drive it points at isn't reachable
    /// right now (unplugged at launch, or yanked mid-session). Views show a
    /// "waiting for drive" state instead of the first-run empty state, and
    /// `reconnectIfNeeded()` keeps retrying until the volume returns — previously a
    /// launch without the drive silently dropped the library ("forgot" the drive).
    var waitingForDrive = false
    var hasSavedBookmark: Bool { UserDefaults.standard.data(forKey: bookmarkKey) != nil }
    var path: [URL] = []
    /// A folder the user asked to jump to from deep inside the viewer (e.g. "Open Stories"
    /// in the info panel). The info sheet and the viewer cover tear themselves down, then the
    /// folder view performs the push once they're gone — set while presented, consumed on the
    /// viewer's dismissal. Needed because changing `path` under a full-screen cover is hidden.
    var pendingFolderNavigation: URL?
    var sort: SortKey = .smart
    var favorites: Set<String> = Library.migrateBulk("favorites", legacyKey: "photoBrowser.favorites") {
        Set(UserDefaults.standard.stringArray(forKey: $0) ?? [])
    }
    var aiLabels: Set<String> = Library.migrateBulk("ai", legacyKey: "photoBrowser.ai") {
        Set(UserDefaults.standard.stringArray(forKey: $0) ?? [])
    }
    /// Custom labels offered inside the "Taylor Swift" / Kardashian folders, keyed
    /// labelName → set of file paths (an item may carry several). Persisted as one
    /// file **per label** (see `persistCustomLabels`): at 100k+ labeled photos the
    /// old single-file store meant every label tap re-encoded ~20MB of JSON.
    var customLabels: [String: Set<String>] = Library.loadCustomLabels()
    /// People library: person name → set of face IDs ("path#index"). Built by the
    /// approximate on-device "Find People" pass, then renamed/merged by the user.
    var people: [String: Set<String>] = Library.migrateBulk("people", legacyKey: "photoBrowser.people") {
        (UserDefaults.standard.dictionary(forKey: $0) as? [String: [String]] ?? [:]).mapValues(Set.init)
    }
    /// Bumps on any label change (toggle or move) so views re-query even when the
    /// label count is unchanged (e.g. a move rewrites a path without adding one).
    var labelsVersion = 0
    /// Bumps when files are added/edited from outside the folder view (e.g. the
    /// editor saving a cropped copy) so the current folder reloads.
    var changeToken = 0
    /// Items handed off from the Share Extension (a shared Instagram story link, or a
    /// photo/video). Non-empty presents the import sheet (pick folder + upscale options).
    var pendingShares: [StorySharing.PendingShare] = []
    /// Re-reads what the Share Extension left in the App Group. Called on launch/open-URL/foreground.
    func refreshPendingShares() { pendingShares = StorySharing.load() }
    /// Signals a content change. Pass the folder the change happened under to evict
    /// only that subtree's cached listings/years — a global clear forces every folder
    /// (and the year/age passes) to recompute, which made one saved edit or one
    /// finished download re-scan the whole drive. Omit it for genuinely global events.
    func contentDidChange(under folder: URL? = nil) {
        changeToken += 1
        ViewerPageCache.shared.clear()   // pages are path-keyed; an in-place edit must not re-show old pixels
        guard let folder else {
            folderYearsCache.removeAll()
            listingCache.removeAll()
            listingOrder.removeAll()
            return
        }
        // Ancestors matter too: their listings show this folder, and their year sets
        // aggregate the whole subtree.
        let p = folder.path
        func related(_ key: String) -> Bool { key == p || key.hasPrefix(p + "/") || p.hasPrefix(key + "/") }
        for key in Array(listingCache.keys) where related(key) { listingCache.removeValue(forKey: key) }
        listingOrder.removeAll { listingCache[$0] == nil }
        for key in Array(folderYearsCache.keys) where related(key) { folderYearsCache.removeValue(forKey: key) }
    }

    // MARK: - Bulk store (file-backed)

    /// Large per-photo collections (labels/captions/etc.) are stored in JSON files,
    /// NOT UserDefaults: a Kardashian/Instagram download adds tens of thousands of
    /// path keys, and UserDefaults rejects any single value ≥ 4 MB ("invalid"), which
    /// corrupted the prefs and crashed the app. Files have no such limit.
    @ObservationIgnored nonisolated static let bulkDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("bulkStore", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    nonisolated static func loadBulk<T: Decodable>(_ name: String, as type: T.Type = T.self) -> T? {
        guard let data = try? Data(contentsOf: bulkDir.appendingPathComponent(name + ".json")) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
    nonisolated static func saveBulk<T: Encodable>(_ value: T, _ name: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: bulkDir.appendingPathComponent(name + ".json"), options: .atomic)
    }
    /// Loads from the bulk file, else migrates the legacy UserDefaults value once
    /// (then drops the oversized/corrupt UserDefaults key).
    nonisolated static func migrateBulk<T: Codable>(_ name: String, legacyKey: String, legacy: (String) -> T) -> T {
        if let v: T = loadBulk(name) { return v }
        let v = legacy(legacyKey)
        saveBulk(v, name)
        UserDefaults.standard.removeObject(forKey: legacyKey)
        return v
    }

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
        Self.persistListing(entries, for: folder)
    }

    /// Persisted per-folder listing snapshots, so a cold launch paints **every**
    /// folder instantly (then refreshes from disk) — previously only the root had
    /// this, and each subfolder's first open waited on a live directory read.
    /// One small JSON per folder, named by the drive-relative path so snapshots
    /// survive the drive remounting under a new mount UUID.
    private struct ListingSnapshot: Codable { let folderStable: String; let folderPath: String; let entries: [Entry] }
    @ObservationIgnored nonisolated private static let listingsDir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("listings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    nonisolated private static func listingFile(for folder: URL) -> URL {
        let digest = SHA256.hash(data: Data(folder.stableCacheID.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return listingsDir.appendingPathComponent(name).appendingPathExtension("json")
    }
    nonisolated private static func persistListing(_ entries: [Entry], for folder: URL) {
        let snapshot = ListingSnapshot(folderStable: folder.stableCacheID, folderPath: folder.path, entries: entries)
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: listingFile(for: folder), options: .atomic)
            }
        }
    }
    /// The saved snapshot for `folder`, remapped if the drive reconnected under a
    /// new mount path. Reads off the main actor — call before the live listing.
    nonisolated func persistedListing(of folder: URL) async -> [Entry]? {
        await Task.detached(priority: .userInitiated) { () -> [Entry]? in
            guard let data = try? Data(contentsOf: Self.listingFile(for: folder)),
                  let snapshot = try? JSONDecoder().decode(ListingSnapshot.self, from: data),
                  snapshot.folderStable == folder.stableCacheID else { return nil }
            if snapshot.folderPath == folder.path { return snapshot.entries }
            // Reconnected under a new mount path — remap the entries onto the current folder.
            let old = snapshot.folderPath, new = folder.path
            return snapshot.entries.map { e in
                let p = e.url.path
                guard p.hasPrefix(old) else { return e }
                return Entry(url: URL(fileURLWithPath: new + p.dropFirst(old.count)),
                             name: e.name, kind: e.kind, size: e.size, modified: e.modified)
            }
        }.value
    }

    /// The last folder a Move/Copy sent items to, so the picker can default there.
    var lastTransferDestination: URL? = UserDefaults.standard.string(forKey: "photoBrowser.lastTransferDest")
        .map { URL(fileURLWithPath: $0) }
    func setLastTransferDestination(_ url: URL) {
        lastTransferDestination = url
        UserDefaults.standard.set(url.path, forKey: "photoBrowser.lastTransferDest")
    }

    /// The last folder a web-browser download was sent to via "Download to Another Folder…", so that
    /// picker defaults there next time. Kept separate from Move/Copy's destination on purpose.
    var lastWebDownloadDestination: URL? = UserDefaults.standard.string(forKey: "photoBrowser.lastWebDownloadDest")
        .map { URL(fileURLWithPath: $0) }
    func setLastWebDownloadDestination(_ url: URL) {
        lastWebDownloadDestination = url
        UserDefaults.standard.set(url.path, forKey: "photoBrowser.lastWebDownloadDest")
    }

    /// The last folder a shared Instagram story/post was saved to (from the Share Extension), so
    /// the import sheet defaults there next time.
    var lastStoryDestination: URL? = UserDefaults.standard.string(forKey: "photoBrowser.lastStoryDest")
        .map { URL(fileURLWithPath: $0) }
    func setLastStoryDestination(_ url: URL) {
        lastStoryDestination = url
        UserDefaults.standard.set(url.path, forKey: "photoBrowser.lastStoryDest")
    }

    // MARK: - Facebook profile folders

    /// Folder path → the Facebook profile downloaded into it (drives "Get New",
    /// the blue-ringed bubble, the subtitle, and dedup).
    var facebookFolders: [String: FBFolderInfo] = {
        guard let data = UserDefaults.standard.data(forKey: "photoBrowser.facebookFolders"),
              let m = try? JSONDecoder().decode([String: FBFolderInfo].self, from: data) else { return [:] }
        return m
    }()
    func facebookInfo(for folder: URL) -> FBFolderInfo? { facebookFolders[folder.path] }
    func isFacebookFolder(_ folder: URL) -> Bool { facebookFolders[folder.path] != nil }
    func setFacebookInfo(_ info: FBFolderInfo, for folder: URL) {
        facebookFolders[folder.path] = info
        persistFacebookFolders()
        changeToken += 1
    }
    private func persistFacebookFolders() {
        if let data = try? JSONEncoder().encode(facebookFolders) {
            UserDefaults.standard.set(data, forKey: "photoBrowser.facebookFolders")
        }
    }
    var lastFacebookURLByFolder: [String: String] = (UserDefaults.standard.dictionary(forKey: "photoBrowser.lastFacebookURL") as? [String: String]) ?? [:]
    func lastFacebookURL(for folder: URL) -> String? { lastFacebookURLByFolder[folder.path] }
    func setLastFacebookURL(_ url: String, for folder: URL) {
        lastFacebookURLByFolder[folder.path] = url
        UserDefaults.standard.set(lastFacebookURLByFolder, forKey: "photoBrowser.lastFacebookURL")
    }

    // MARK: - OF creator folders

    /// Folder path → the OF creator downloaded into it (drives "Get New",
    /// the blue-ringed bubble, the subtitle, and dedup). Mirrors `facebookFolders`.
    var ofFolders: [String: OFFolderInfo] = {
        // Legacy defaults key kept verbatim — renaming it would orphan existing folder mappings.
        guard let data = UserDefaults.standard.data(forKey: "photoBrowser.onlyfansFolders"),
              let m = try? JSONDecoder().decode([String: OFFolderInfo].self, from: data) else { return [:] }
        return m
    }()
    func ofInfo(for folder: URL) -> OFFolderInfo? { ofFolders[folder.path] }
    func isOFFolder(_ folder: URL) -> Bool { ofFolders[folder.path] != nil }
    func setOFInfo(_ info: OFFolderInfo, for folder: URL) {
        ofFolders[folder.path] = info
        persistOFFolders()
        changeToken += 1
    }
    private func persistOFFolders() {
        if let data = try? JSONEncoder().encode(ofFolders) {
            UserDefaults.standard.set(data, forKey: "photoBrowser.onlyfansFolders")
        }
    }
    /// Person-folder path → the OF username last downloaded under it, so reruns
    /// prefill the username and resume the same folder.
    var lastOFUsernameByFolder: [String: String] = (UserDefaults.standard.dictionary(forKey: "photoBrowser.lastOFUsername") as? [String: String]) ?? [:]
    func lastOFUsername(for folder: URL) -> String? { lastOFUsernameByFolder[folder.path] }
    func setLastOFUsername(_ username: String, for folder: URL) {
        lastOFUsernameByFolder[folder.path] = username
        UserDefaults.standard.set(lastOFUsernameByFolder, forKey: "photoBrowser.lastOFUsername")
    }

    // MARK: - TikTok profile folders

    /// `@handle` folder path → the TikTok profile downloaded into it (drives "Get New
    /// videos", the pinned highlight bubble, and dedup). Mirrors `facebookFolders`.
    var tiktokFolders: [String: TTFolderInfo] = {
        guard let data = UserDefaults.standard.data(forKey: "photoBrowser.tiktokFolders"),
              let m = try? JSONDecoder().decode([String: TTFolderInfo].self, from: data) else { return [:] }
        return m
    }()
    func tiktokInfo(for folder: URL) -> TTFolderInfo? { tiktokFolders[folder.path] }
    func isTikTokFolder(_ folder: URL) -> Bool { tiktokFolders[folder.path] != nil }
    func setTikTokInfo(_ info: TTFolderInfo, for folder: URL) {
        tiktokFolders[folder.path] = info
        persistTikTokFolders()
        changeToken += 1
    }
    private func persistTikTokFolders() {
        if let data = try? JSONEncoder().encode(tiktokFolders) {
            UserDefaults.standard.set(data, forKey: "photoBrowser.tiktokFolders")
        }
    }
    /// Video file path → its TikTok like count (shown in the info panel).
    var tiktokLikes: [String: Int] = (UserDefaults.standard.dictionary(forKey: "photoBrowser.tiktokLikes") as? [String: Int]) ?? [:]
    func tiktokLikeCount(for url: URL) -> Int? { tiktokLikes[url.path] }
    private func persistTikTokLikes() { UserDefaults.standard.set(tiktokLikes, forKey: "photoBrowser.tiktokLikes") }

    /// Refreshes the like counts of already-downloaded videos in `folder` from a fresh `id → likes`
    /// map (a "Get New" run), so existing videos' counts update too. Persists + reloads once.
    func applyTikTokLikes(_ statsByID: [String: Int], in folder: URL) {
        guard !statsByID.isEmpty else { return }
        let fm = FileManager.default
        var changed = false
        for (id, likes) in statsByID where likes > 0 {
            let path = folder.appendingPathComponent("\(id).mp4").path
            guard fm.fileExists(atPath: path) else { continue }
            if tiktokLikes[path] != likes { tiktokLikes[path] = likes; changed = true }
        }
        if changed { persistTikTokLikes(); contentDidChange() }
    }

    /// Person-folder path → the TikTok handle last downloaded under it, so re-opening the
    /// downloader from that folder prefills the handle and resumes the same `@handle` folder.
    var lastTikTokHandleByFolder: [String: String] = (UserDefaults.standard.dictionary(forKey: "photoBrowser.lastTikTokHandle") as? [String: String]) ?? [:]
    func lastTikTokHandle(for folder: URL) -> String? { lastTikTokHandleByFolder[folder.path] }
    func setLastTikTokHandle(_ handle: String, for folder: URL) {
        lastTikTokHandleByFolder[folder.path] = handle
        UserDefaults.standard.set(lastTikTokHandleByFolder, forKey: "photoBrowser.lastTikTokHandle")
    }

    // MARK: - VSCO profile folders

    /// Profile folder path → the VSCO profile downloaded into it (drives "Get New VSCO
    /// Photos" and dedup).
    var vscoFolders: [String: VSCOFolderInfo] = {
        guard let data = UserDefaults.standard.data(forKey: "photoBrowser.vscoFolders"),
              let m = try? JSONDecoder().decode([String: VSCOFolderInfo].self, from: data) else { return [:] }
        return m
    }()
    func vscoInfo(for folder: URL) -> VSCOFolderInfo? { vscoFolders[folder.path] }
    func isVSCOFolder(_ folder: URL) -> Bool { vscoFolders[folder.path] != nil }
    func setVSCOInfo(_ info: VSCOFolderInfo, for folder: URL) {
        vscoFolders[folder.path] = info
        persistVSCOFolders()
    }
    private func persistVSCOFolders() {
        if let data = try? JSONEncoder().encode(vscoFolders) {
            UserDefaults.standard.set(data, forKey: "photoBrowser.vscoFolders")
        }
    }
    /// Person-folder path → the VSCO username last downloaded under it (prefills the sheet).
    var lastVSCOUsernameByFolder: [String: String] = (UserDefaults.standard.dictionary(forKey: "photoBrowser.lastVSCOUsername") as? [String: String]) ?? [:]
    func lastVSCOUsername(for folder: URL) -> String? { lastVSCOUsernameByFolder[folder.path] }
    func setLastVSCOUsername(_ handle: String, for folder: URL) {
        lastVSCOUsernameByFolder[folder.path] = handle
        UserDefaults.standard.set(lastVSCOUsernameByFolder, forKey: "photoBrowser.lastVSCOUsername")
    }

    /// Files TikTok videos that finished downloading in the background (in the app inbox) onto
    /// the actual drive folder: moves each into place, stamps its capture date, attaches its
    /// caption, and updates the profile record's count/dedup set. Runs in the foreground (drive
    /// mounted, security scope active). Safe to call repeatedly — it consumes the pending queue.
    func processPendingTikTok() {
        guard rootURL != nil else { return }     // need the drive mounted + security scope to file onto it
        let pending = BackgroundDownloader.loadPending()
        guard !pending.isEmpty else { return }
        BackgroundDownloader.shared.removeProcessed(pending.count)
        let fm = FileManager.default
        var captionUpdates: [String: String] = [:]
        var idsByFolder: [String: [String]] = [:]
        var newestByFolder: [String: Double] = [:]   // newest post date actually filed, per profile folder
        var requeue: [[String: Any]] = []        // entries we couldn't file yet (drive busy) — retry later
        var changed = false
        for rec in pending {
            guard let inbox = rec["inbox"] as? String, let dest = rec["dest"] as? String else { continue }
            guard fm.fileExists(atPath: inbox) else { continue }     // inbox file gone (already filed) — drop
            let inboxURL = URL(fileURLWithPath: inbox), destURL = URL(fileURLWithPath: dest)
            try? fm.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest) {
                try? fm.removeItem(at: inboxURL)                     // already have it — drop the dupe
            } else if (try? fm.moveItem(at: inboxURL, to: destURL)) == nil {
                _ = try? fm.copyItem(at: inboxURL, to: destURL)
                if fm.fileExists(atPath: dest) { try? fm.removeItem(at: inboxURL) }
            }
            guard fm.fileExists(atPath: dest) else { requeue.append(rec); continue }   // couldn't file — keep for retry
            if let ct = rec["createTime"] as? Double, ct > 0 {
                let date = Date(timeIntervalSince1970: ct)
                try? fm.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: dest)
            }
            if let caption = rec["caption"] as? String, !caption.isEmpty { captionUpdates[dest] = caption }
            if let likes = rec["likes"] as? Int, likes > 0 { tiktokLikes[dest] = likes }
            if let folder = rec["folder"] as? String, let id = rec["id"] as? String {
                idsByFolder[folder, default: []].append(id)
                if let ct = rec["createTime"] as? Double, ct > 0 {
                    newestByFolder[folder] = max(newestByFolder[folder] ?? 0, ct)
                }
            }
            changed = true
        }
        BackgroundDownloader.shared.requeue(requeue)
        if changed { persistTikTokLikes() }
        setCaptions(captionUpdates)
        for (folder, ids) in idsByFolder {
            guard var info = tiktokFolders[folder] else { continue }
            // Dedup within the batch: a photo/slideshow post files several images that all
            // carry the same post id, so it must count (and be recorded) once, not per file.
            var seenFresh = Set<String>()
            let fresh = ids.filter { !info.downloaded.contains($0) && seenFresh.insert($0).inserted }
            info.downloaded.append(contentsOf: fresh)
            info.videos += fresh.count
            info.lastUpdated = Date().timeIntervalSince1970
            // Advance the incremental "Get New" cutoff only now that these videos are
            // actually on the drive. Advancing at link-resolution time permanently
            // skipped any queued download that later failed — it fell behind the
            // cutoff, so the next run stopped paging before re-listing it and the
            // id-dedup never got a chance to re-fetch it.
            if let newest = newestByFolder[folder], newest > (info.newestDate ?? 0) {
                info.newestDate = newest
            }
            tiktokFolders[folder] = info
        }
        if !idsByFolder.isEmpty { persistTikTokFolders() }
        if changed { contentDidChange() }
    }

    /// Grid thumbnail minimum size (points); pinch-to-zoom adjusts it ±30%.
    var thumbSize: Double = (UserDefaults.standard.object(forKey: "photoBrowser.thumbSize") as? Double) ?? 110
    func setThumbSize(_ value: Double) {
        thumbSize = min(max(value, 70), 260)
        UserDefaults.standard.set(thumbSize, forKey: "photoBrowser.thumbSize")
    }
    /// App-stored caption overrides keyed by file path ("" = explicitly cleared).
    var captions: [String: String] = Library.migrateBulk("captions", legacyKey: "photoBrowser.captions") {
        (UserDefaults.standard.dictionary(forKey: $0) as? [String: String]) ?? [:]
    }
    /// Folder path → cover-image filename (stored under Application Support/folderCovers).
    var folderCovers: [String: String] = (UserDefaults.standard.dictionary(forKey: "photoBrowser.folderCovers") as? [String: String]) ?? [:]
    /// Item file path → custom-thumbnail filename (stored under Application Support/itemThumbs).
    /// A per-item override of the auto-generated grid thumbnail — the item equivalent of a folder cover.
    var itemThumbnails: [String: String] = (UserDefaults.standard.dictionary(forKey: "photoBrowser.itemThumbnails") as? [String: String]) ?? [:]
    /// Drive file path → originating Photos-library asset identifier (for imports).
    var photoOrigins: [String: String] = Library.migrateBulk("photoOrigins", legacyKey: "photoBrowser.photoOrigins") {
        (UserDefaults.standard.dictionary(forKey: $0) as? [String: String]) ?? [:]
    }
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
    @ObservationIgnored private lazy var itemThumbsDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("itemThumbs", isDirectory: true)
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

    /// Saves a pre-encoded 10-bit HDR HEIC as `folder`'s cover (see `HDRCover`) — same store
    /// and keying as the JPEG path, just a different container so the headroom survives.
    func setCover(hdrHEIC data: Data, for folder: URL) {
        if let old = folderCovers[folder.path] {
            try? FileManager.default.removeItem(at: coversDirectory.appendingPathComponent(old))
        }
        let name = UUID().uuidString + ".heic"
        do {
            try data.write(to: coversDirectory.appendingPathComponent(name))
            folderCovers[folder.path] = name
            UserDefaults.standard.set(folderCovers, forKey: "photoBrowser.folderCovers")
        } catch {}
    }

    // MARK: - Custom item thumbnails (per-photo/video grid tile override)

    /// File URL of a custom thumbnail set on this item, or nil if it uses its auto-generated one.
    func itemThumbnailURL(for url: URL) -> URL? {
        guard let name = itemThumbnails[url.path] else { return nil }
        return itemThumbsDirectory.appendingPathComponent(name)
    }

    func hasItemThumbnail(for url: URL) -> Bool { itemThumbnails[url.path] != nil }

    /// Sets a cropped image as this item's grid thumbnail (replacing any existing one). Works like
    /// `setCover` but keyed to the item itself rather than a folder.
    func setItemThumbnail(_ image: UIImage, for url: URL) {
        if let old = itemThumbnails[url.path] {
            try? FileManager.default.removeItem(at: itemThumbsDirectory.appendingPathComponent(old))
        }
        guard let data = image.jpegData(compressionQuality: 0.9) else { return }
        let name = UUID().uuidString + ".jpg"
        do {
            try data.write(to: itemThumbsDirectory.appendingPathComponent(name))
            itemThumbnails[url.path] = name
            UserDefaults.standard.set(itemThumbnails, forKey: "photoBrowser.itemThumbnails")
        } catch {}
    }

    /// Removes the custom thumbnail, reverting to the auto-generated one.
    func removeItemThumbnail(for url: URL) {
        if let old = itemThumbnails[url.path] {
            try? FileManager.default.removeItem(at: itemThumbsDirectory.appendingPathComponent(old))
        }
        itemThumbnails[url.path] = nil
        UserDefaults.standard.set(itemThumbnails, forKey: "photoBrowser.itemThumbnails")
    }

    // MARK: - Photos-library origin tracking (for imports)

    func setOrigin(_ assetID: String, for url: URL) {
        photoOrigins[url.path] = assetID
        Self.saveBulk(photoOrigins, "photoOrigins")
    }

    func origin(for url: URL) -> String? { photoOrigins[url.path] }

    func clearOrigins(_ urls: [URL]) {
        for u in urls { photoOrigins.removeValue(forKey: u.path) }
        Self.saveBulk(photoOrigins, "photoOrigins")
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
            MetadataLoader.scheduleDateStoreFlush()    // persist any newly-read dates (debounced)
            let order = Self.sortEntries(media.filter { ageByURL[$0.url] != nil }, by: sort)
            return order.map { (entry: $0, age: ageByURL[$0.url] ?? 0) }
        }.value
    }

    // MARK: - Captions

    func setCaption(_ text: String, for url: URL) {
        captions[url.path] = text.trimmingCharacters(in: .whitespacesAndNewlines)
        Self.saveBulk(captions, "captions")
    }

    /// Batch caption set (persists once) — avoids O(n²) UserDefaults writes when a
    /// bulk import applies hundreds of captions at once.
    func setCaptions(_ map: [String: String]) {
        guard !map.isEmpty else { return }
        for (k, v) in map { captions[k] = v.trimmingCharacters(in: .whitespacesAndNewlines) }
        Self.saveBulk(captions, "captions")
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
        Self.saveBulk(favorites, "favorites")
        labelsVersion += 1
    }

    func isAI(_ url: URL) -> Bool { aiLabels.contains(url.path) }

    func toggleAI(_ url: URL) {
        if aiLabels.contains(url.path) { aiLabels.remove(url.path) } else { aiLabels.insert(url.path) }
        Self.saveBulk(aiLabels, "ai")
        labelsVersion += 1
    }

    // MARK: - Taylor Swift custom labels

    /// The fixed set of labels offered inside the "Taylor Swift" folder.
    static let taylorSwiftLabels = ["The Eras Tour", "Lover Bodysuit", "Grammys",
                                    "Midnights Bodysuit", "Reputation Bodysuit",
                                    "Movie", "AI", "The Life of a Showgirl", "Beach"]

    // MARK: - Custom-label persistence (per-label files, debounced, off-main)

    /// One label's paths, with the (user-facing) name embedded so the hashed
    /// filename never needs to round-trip back to a label name.
    private struct LabelFile: Codable { let name: String; let paths: [String] }

    nonisolated private static var labelsDir: URL {
        let dir = bulkDir.appendingPathComponent("customLabels", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    nonisolated private static func labelFileURL(_ name: String) -> URL {
        let digest = SHA256.hash(data: Data(name.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return labelsDir.appendingPathComponent(digest).appendingPathExtension("json")
    }
    nonisolated private static func saveLabelFile(_ name: String, _ paths: Set<String>) {
        let url = labelFileURL(name)
        guard !paths.isEmpty else { try? FileManager.default.removeItem(at: url); return }
        if let data = try? JSONEncoder().encode(LabelFile(name: name, paths: Array(paths))) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Loads the per-label files; on first run after the update, migrates the old
    /// monolithic store (bulk file or legacy UserDefaults) into them once.
    nonisolated static func loadCustomLabels() -> [String: Set<String>] {
        if let files = try? FileManager.default.contentsOfDirectory(at: labelsDir, includingPropertiesForKeys: nil,
                                                                    options: [.skipsHiddenFiles]), !files.isEmpty {
            var out: [String: Set<String>] = [:]
            for f in files where f.pathExtension == "json" {
                if let data = try? Data(contentsOf: f),
                   let lf = try? JSONDecoder().decode(LabelFile.self, from: data) {
                    out[lf.name] = Set(lf.paths)
                }
            }
            if !out.isEmpty { return out }
        }
        let legacy: [String: Set<String>] = migrateBulk("customLabels", legacyKey: "photoBrowser.customLabels") {
            (UserDefaults.standard.dictionary(forKey: $0) as? [String: [String]] ?? [:]).mapValues(Set.init)
        }
        for (name, paths) in legacy { saveLabelFile(name, paths) }
        try? FileManager.default.removeItem(at: bulkDir.appendingPathComponent("customLabels.json"))
        return legacy
    }

    @ObservationIgnored private var dirtyLabels: Set<String> = []
    @ObservationIgnored private var labelFlushScheduled = false

    /// Marks `names` changed and coalesces their per-label writes onto a detached
    /// task shortly after — a label tap must never encode 100k+ paths on the main
    /// actor (each tap used to rewrite the entire store synchronously).
    private func persistCustomLabels(_ names: some Sequence<String>) {
        dirtyLabels.formUnion(names)
        guard !labelFlushScheduled else { return }
        labelFlushScheduled = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard let self else { return }
            self.labelFlushScheduled = false
            let toWrite = self.dirtyLabels
            self.dirtyLabels = []
            let snapshot = self.customLabels
            Task.detached(priority: .utility) {
                for name in toWrite { Self.saveLabelFile(name, snapshot[name] ?? []) }
            }
        }
    }

    /// Persist every label (used by the rare whole-store rewrites: moves, remounts,
    /// backup duplication, deletions).
    private func persistCustomLabels() {
        persistCustomLabels(customLabels.keys)
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
        Self.saveBulk(people, "people")
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

    // MARK: - AI prompt history

    /// Recent "Edit with AI" prompts, newest first — shown in the AI edit screen so
    /// a past prompt can be dropped back into the prompt box with a tap. Deduped
    /// case-insensitively (reusing a prompt moves it to the top), capped at 50.
    var aiPromptHistory: [String] = UserDefaults.standard.stringArray(forKey: "photoBrowser.aiPromptHistory") ?? []
    func recordAIPrompt(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        aiPromptHistory.removeAll { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        aiPromptHistory.insert(trimmed, at: 0)
        if aiPromptHistory.count > 50 { aiPromptHistory.removeLast(aiPromptHistory.count - 50) }
        UserDefaults.standard.set(aiPromptHistory, forKey: "photoBrowser.aiPromptHistory")
    }
    func deleteAIPrompt(_ text: String) {
        aiPromptHistory.removeAll { $0 == text }
        UserDefaults.standard.set(aiPromptHistory, forKey: "photoBrowser.aiPromptHistory")
    }
    func deleteAIPrompts(at offsets: IndexSet) {
        aiPromptHistory.remove(atOffsets: offsets)
        UserDefaults.standard.set(aiPromptHistory, forKey: "photoBrowser.aiPromptHistory")
    }

    // MARK: - AI-generated images

    var aiGeneratedPaths: Set<String> = Library.migrateBulk("aiGenerated", legacyKey: "photoBrowser.aiGenerated") {
        Set(UserDefaults.standard.stringArray(forKey: $0) ?? [])
    }
    /// What produced an AI image — the model and the exact prompt — so the info panel can
    /// show them and search can match on them. Path-keyed like captions; JSON in UserDefaults.
    struct AIGenInfo: Codable, Sendable, Hashable { var model: String; var prompt: String }
    var aiGenerations: [String: AIGenInfo] = {
        guard let data = UserDefaults.standard.data(forKey: "photoBrowser.aiGenerations"),
              let m = try? JSONDecoder().decode([String: AIGenInfo].self, from: data) else { return [:] }
        return m
    }()
    private func persistAIGenerations() {
        if let data = try? JSONEncoder().encode(aiGenerations) {
            UserDefaults.standard.set(data, forKey: "photoBrowser.aiGenerations")
        }
    }
    func aiGeneration(for url: URL) -> AIGenInfo? { aiGenerations[url.path] }

    func markAIGenerated(_ url: URL, model: String? = nil, prompt: String? = nil) {
        aiGeneratedPaths.insert(url.path)
        Self.saveBulk(aiGeneratedPaths, "aiGenerated")
        if let model, let prompt {
            let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if !model.isEmpty || !p.isEmpty {
                aiGenerations[url.path] = AIGenInfo(model: model, prompt: p)
                persistAIGenerations()
            }
        }
        labelsVersion += 1
    }
    func isAIGenerated(_ url: URL) -> Bool { aiGeneratedPaths.contains(url.path) }

    // MARK: - Edited in-app

    /// Paths of files produced by the in-app photo editor, so a folder can filter to "Edited" items.
    var editedInAppPaths: Set<String> = Library.migrateBulk("editedInApp", legacyKey: "photoBrowser.editedInApp") {
        Set(UserDefaults.standard.stringArray(forKey: $0) ?? [])
    }
    func markEditedInApp(_ url: URL) {
        editedInAppPaths.insert(url.path)
        // Off-main: this set grows with every edit, and re-encoding it inline on
        // each save eventually hitched the UI.
        let snapshot = editedInAppPaths
        Self.persistQueue.async { Self.saveBulk(snapshot, "editedInApp") }
        labelsVersion += 1
    }
    func isEditedInApp(_ url: URL) -> Bool { editedInAppPaths.contains(url.path) }

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

    // MARK: - Background activities (long jobs the user can navigate away from)

    /// A running background job — shown as a progress pill app-wide (see ContentView) so the user
    /// can keep browsing while frame exports / Instagram downloads run. Multiple can run at once.
    struct Activity: Identifiable, Sendable {
        let id = UUID()
        var title: String
        var status: String = ""
        var fraction: Double = 0          // 0…1, or <0 for indeterminate (spinner only)
    }
    var activities: [Activity] = []
    var activityResults: [String] = []    // completion messages → shown as popups, oldest first

    @discardableResult
    func beginActivity(_ title: String, indeterminate: Bool = false) -> UUID {
        let a = Activity(title: title, fraction: indeterminate ? -1 : 0)
        activities.append(a)
        return a.id
    }
    func setActivity(_ id: UUID, status: String? = nil, fraction: Double? = nil) {
        guard let i = activities.firstIndex(where: { $0.id == id }) else { return }
        if let status { activities[i].status = status }
        if let fraction { activities[i].fraction = fraction }
    }
    func endActivity(_ id: UUID, result: String? = nil) {
        activities.removeAll { $0.id == id }
        if let result { activityResults.append(result) }
    }
    func dismissActivityResult() { if !activityResults.isEmpty { activityResults.removeFirst() } }

    /// Exports every (or every Nth) frame of `entry` into a folder beside it, app-wide so the user
    /// can navigate around while it runs. `fps` of 0 means every frame.
    func startFrameExport(of entry: Entry, name: String, fps: Double) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = trimmed.isEmpty ? (entry.url.deletingPathExtension().lastPathComponent + " Frames") : trimmed
        let id = beginActivity("Exporting frames")
        setActivity(id, status: label)
        let bg = BackgroundTaskHolder(); bg.begin(name: "Export All Frames")
        Task {
            let (folder, count, firstFrame, note) = await FileActions.exportAllFrames(
                of: entry.url, folderName: name, requestedFPS: fps) { p in
                Task { @MainActor in self.setActivity(id, fraction: p) }
            }
            if count > 0, let folder {
                markFramesFolder(folder)
                if let firstFrame, let cover = UIImage(contentsOfFile: firstFrame.path) { setCover(cover, for: folder) }
            }
            endActivity(id, result: count > 0
                ? "Exported \(count) frame\(count == 1 ? "" : "s") to “\(folder?.lastPathComponent ?? "Frames")”."
                : "Couldn’t export frames — " + (note ?? "unknown reason."))
            contentDidChange()
            bg.end()
        }
    }

    /// Backup companion to `duplicateMetadata`: duplicates the cached thumbnails onto the
    /// backup subtree's cache keys in the background, so browsing the backup shows instant
    /// tiles instead of re-thumbnailing the whole drive. Cheap local file copies only.
    func startThumbnailBackup(from oldRoot: URL, to newRoot: URL) {
        let id = beginActivity("Backing Up Thumbnails", indeterminate: true)
        let bg = BackgroundTaskHolder(); bg.begin(name: "Thumbnail Backup")
        Task {
            let n = await Thumbnailer.shared.duplicateThumbnails(from: oldRoot, to: newRoot)
            endActivity(id, result: n > 0 ? "Copied \(n) cached thumbnail\(n == 1 ? "" : "s") for the backup." : nil)
            bg.end()
        }
    }

    // MARK: - Cache All Thumbnails (full-drive background pass)

    /// The running "Cache All Thumbnails" pass — non-nil while it runs. Drives the Maintenance
    /// menu's Cache/Stop toggle.
    private(set) var thumbnailCacheTask: Task<Void, Never>?
    var thumbnailCacheRunning: Bool { thumbnailCacheTask != nil }

    /// Walks the whole drive and generates a disk thumbnail for every photo/video that doesn't
    /// have one yet (already-cached files are skipped — see `Thumbnailer.precache`). Runs as an
    /// app-wide activity pill so the user can keep browsing; the pill shows a fraction and the
    /// folder currently being worked through — deliberately no file counts. Stoppable from the
    /// Maintenance menu.
    func startThumbnailCaching() {
        guard thumbnailCacheTask == nil, let root = rootURL else { return }
        let id = beginActivity("Caching In Progress", indeterminate: true)
        setActivity(id, status: "Scanning drive…")
        let bg = BackgroundTaskHolder(); bg.begin(name: "Cache All Thumbnails")
        UIApplication.shared.isIdleTimerDisabled = true       // long run — keep the screen alive
        thumbnailCacheTask = Task {
            let cancelled = await Self.cacheAllThumbnails(under: root) { fraction, folder in
                Task { @MainActor in self.setActivity(id, status: folder, fraction: fraction) }
            }
            endActivity(id, result: cancelled ? nil : "All thumbnails are cached.")
            thumbnailCacheTask = nil
            UIApplication.shared.isIdleTimerDisabled = false
            bg.end()
        }
    }

    func stopThumbnailCaching() {
        thumbnailCacheTask?.cancel()
    }

    /// The worker: walk the drive and thumbnail as it goes, bounded-concurrent. Returns true if
    /// the pass was cancelled.
    ///
    /// Discovery is INTERLEAVED with the thumbnail work — files feed the task group straight off
    /// the enumerator — so caching starts within seconds. (The first version scanned the whole
    /// drive up front to learn the total; enumerating a huge external drive — any filesystem,
    /// the per-file round-trips dominate — meant minutes of "Scanning drive…" with nothing
    /// visibly happening.) While the walk is still going the
    /// reported fraction is -1 (indeterminate spinner + folder name); when it finishes, the real
    /// fraction takes over. `classify` is memoized per extension — it's a UTType lookup, and one
    /// per file made the old scan CPU-bound on top of the drive I/O.
    ///
    /// The body MUST run in `Task.detached` (hard-won constraint #1): a `nonisolated` async
    /// function still runs on the *caller's* actor here, and the caller is the main actor — the
    /// synchronous drive walk froze the whole UI without it. A detached task doesn't inherit the
    /// caller's cancellation, so the Stop button's cancel is forwarded explicitly.
    private nonisolated static func cacheAllThumbnails(under root: URL,
                                                       progress: @escaping @Sendable (Double, String) -> Void) async -> Bool {
        let worker = Task.detached(priority: .utility) { () -> Bool in
            let fm = FileManager.default
            guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                             options: [.skipsHiddenFiles]) else { return Task.isCancelled }
            var kindByExt: [String: FileKind] = [:]
            func nextMedia() -> (url: URL, kind: FileKind)? {
                while !Task.isCancelled, let url = walker.nextObject() as? URL {
                    let ext = url.pathExtension.lowercased()
                    let kind: FileKind
                    if let known = kindByExt[ext] {
                        kind = known
                    } else {
                        kind = classify(url: url, isDirectory: false)
                        kindByExt[ext] = kind
                    }
                    if kind == .image || kind == .video { return (url, kind) }
                }
                return nil
            }
            var done = 0
            var discovered = 0
            var scanDone = false
            var lastFolder = ""
            await withTaskGroup(of: String.self) { group in
                let maxConcurrent = max(2, min(ProcessInfo.processInfo.activeProcessorCount, 8))
                func addNext() {
                    guard !Task.isCancelled else { return }
                    guard let file = nextMedia() else { scanDone = true; return }
                    discovered += 1
                    group.addTask {
                        guard !Task.isCancelled else { return "" }
                        await Thumbnailer.shared.precache(fileAt: file.url, kind: file.kind)
                        return file.url.deletingLastPathComponent().lastPathComponent
                    }
                }
                for _ in 0..<maxConcurrent { addNext() }
                while let folder = await group.next() {
                    done += 1
                    // Surface the folder currently being worked through (the walk is depth-first,
                    // so consecutive files share a folder) — promptly on a folder change, and on
                    // a steady cadence inside big folders. Still no file counts, by design.
                    if (!folder.isEmpty && folder != lastFolder) || done % 20 == 0 || (scanDone && done == discovered) {
                        if !folder.isEmpty { lastFolder = folder }
                        progress(scanDone ? Double(done) / Double(max(discovered, 1)) : -1, lastFolder)
                    }
                    addNext()
                }
            }
            return Task.isCancelled
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    // MARK: - Google Drive download (app-wide, navigable while it runs)

    func startGoogleDriveDownload(link: String, into folder: URL) {
        runDriveDownload(into: folder) { report in
            await GoogleDrive.importLink(link, into: folder, progress: report)
        }
    }
    func startGoogleDriveDownload(items: [GoogleDrive.Item], into folder: URL) {
        guard !items.isEmpty else { return }
        runDriveDownload(into: folder) { report in
            await GoogleDrive.importItems(items, into: folder, progress: report)
        }
    }
    /// Download from the built-in browser's signed-in session (cookies) — the file IDs scraped from the page.
    func startGoogleDriveCookieDownload(fileIDs: [String], cookieHeader: String, into folder: URL) {
        runDriveDownload(into: folder) { report in
            await GoogleDrive.downloadViaCookies(fileIDs: fileIDs, cookieHeader: cookieHeader, into: folder, progress: report)
        }
    }
    private func runDriveDownload(into folder: URL,
                                 op: @escaping @Sendable (@escaping @Sendable (GoogleDrive.Progress) -> Void) async -> GoogleDrive.Result) {
        let id = beginActivity("Google Drive")
        setActivity(id, status: "Preparing…")
        let bg = BackgroundTaskHolder(); bg.begin(name: "Google Drive Download")
        Task {
            let r = await op { p in
                Task { @MainActor in
                    let line = p.total > 0
                        ? "Downloading \(p.done)/\(p.total)" + (p.currentName.isEmpty ? "…" : " — \(p.currentName)")
                        : "Downloading…"
                    self.setActivity(id, status: line, fraction: p.fraction)
                }
            }
            endActivity(id, result: driveResultMessage(r))
            if r.downloaded > 0 { contentDidChange() }
            bg.end()
        }
    }
    private func driveResultMessage(_ r: GoogleDrive.Result) -> String {
        if r.downloaded == 0, let note = r.note { return note }
        let base = "Downloaded \(r.downloaded) item\(r.downloaded == 1 ? "" : "s")" + (r.folderName.map { " to “\($0)”" } ?? "")
        return r.failed > 0 ? base + "; \(r.failed) failed." : base + "."
    }

    // MARK: - Bulk Instagram download (app-wide)

    /// One mapped profile for the bulk downloader.
    struct BulkIGJob: Sendable { let folder: URL; let name: String; let handle: String }

    var bulkIGRunning = false

    /// Downloads/updates every mapped profile as an app-wide activity (progress
    /// pill, navigable, best-effort background window), replacing the old in-sheet
    /// run that died if the sheet was left. Already-downloaded profiles are no
    /// longer skipped — they get an incremental "new posts only" pass (the id-dedup
    /// in `InstagramService.run` stops paging a dozen posts past the newest one we
    /// have, so a no-news profile costs a couple of requests).
    func startBulkInstagramDownload(jobs: [BulkIGJob], root: URL, skipTagged: Bool, upscale1080: Bool) {
        guard !bulkIGRunning, !jobs.isEmpty else { return }
        bulkIGRunning = true
        let id = beginActivity("Instagram")
        setActivity(id, status: "Starting…")
        let bg = BackgroundTaskHolder(); bg.begin(name: "Bulk Instagram Download")
        UIApplication.shared.isIdleTimerDisabled = true       // long run — keep the screen alive
        Task {
            defer {
                bulkIGRunning = false
                UIApplication.shared.isIdleTimerDisabled = false
                bg.end()
            }
            guard let creds = await InstagramAuth.credentials() else {
                endActivity(id, result: "Not logged in to Instagram — open “Bulk Download Instagram Profiles…” and log in.")
                return
            }
            // Shared rolling temp folder (append within 24h, replace across days).
            let tempFolder = prepareTodaysStoriesFolder(root: root)
            var totalPhotos = 0, totalVideos = 0, totalStories = 0, profilesWithNew = 0
            var firstNote: String?
            for (i, job) in jobs.enumerated() {
                setLastIGHandle(job.handle, for: job.folder)      // remember the mapping
                let dest = resolveIGDestination(person: job.folder, handle: job.handle)
                try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
                let prior = instagramInfo(for: dest)
                let already = Set(prior?.downloaded ?? [])
                setActivity(id, status: "@\(job.handle) — \(already.isEmpty ? "downloading" : "checking for new posts") (\(i + 1) of \(jobs.count))",
                            fraction: Double(i) / Double(jobs.count))
                let r = await InstagramService.run(handle: job.handle, into: dest, alreadyDownloaded: already,
                                                   creds: creds, includeTagged: !skipTagged) { p in
                    Task { @MainActor in
                        self.setActivity(id, fraction: (Double(i) + p.fraction) / Double(jobs.count))
                    }
                }
                await InstagramApply.apply(r, to: dest, already: already, prior: prior,
                                           forceFull: false, library: self)
                if upscale1080 {
                    await InstagramApply.upscaleVideosTo1080(r.files) { done, total in
                        Task { @MainActor in
                            self.setActivity(id, status: "@\(job.handle) — upscaling videos \(done) of \(total)")
                        }
                    }
                }
                // Any stories pulled this run are today's — collect them into the shared folder.
                let storiesFolder = dest.appendingPathComponent("Stories", isDirectory: true)
                let storyFiles = r.files.filter { $0.hasPrefix(storiesFolder.path + "/") }
                if !storyFiles.isEmpty {
                    let copied = await InstagramService.copyToTemp(storyFiles, handle: job.handle, into: tempFolder)
                    setStoryLinks(copied, to: storiesFolder)        // metadata link → person's Stories
                }
                totalPhotos += r.photos; totalVideos += r.videos; totalStories += storyFiles.count
                if r.photos + r.videos > 0 { profilesWithNew += 1 }
                if firstNote == nil, r.photos + r.videos == 0, let note = r.note { firstNote = "@\(job.handle): \(note)" }
            }
            // Drop the shared folder if this run added nothing to it.
            if let contents = try? FileManager.default.contentsOfDirectory(atPath: tempFolder.path), contents.isEmpty {
                try? FileManager.default.removeItem(at: tempFolder)
            }
            let total = totalPhotos + totalVideos
            var msg = total > 0
                ? "Instagram: \(total) new item\(total == 1 ? "" : "s") across \(profilesWithNew) of \(jobs.count) profile\(jobs.count == 1 ? "" : "s")"
                : "Instagram: no new posts across \(jobs.count) profile\(jobs.count == 1 ? "" : "s")"
            if totalStories > 0 { msg += "; \(totalStories) stor\(totalStories == 1 ? "y" : "ies") collected" }
            msg += "."
            if total == 0, let firstNote { msg += " \(firstNote)" }
            endActivity(id, result: msg)
            contentDidChange(under: root)
        }
    }

    /// The folder to download `@handle` into for a person folder: the
    /// already-registered Instagram folder when one exists (the `<handle>`
    /// subfolder, any registered immediate subfolder with that handle, or the
    /// person folder itself from the old flat layout), else a fresh `<handle>`
    /// subfolder. Reusing the registered folder is what turns a bulk re-run into an
    /// incremental "new posts only" pass — a parallel folder would have an empty
    /// dedup record and re-download the entire profile.
    private func resolveIGDestination(person: URL, handle: String) -> URL {
        let direct = person.appendingPathComponent(handle, isDirectory: true)
        if instagramInfo(for: direct) != nil { return direct }
        let children = (try? FileManager.default.contentsOfDirectory(
            at: person, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        for child in children where (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            if instagramFolders[child.path]?.handle.caseInsensitiveCompare(handle) == .orderedSame { return child }
        }
        if instagramFolders[person.path]?.handle.caseInsensitiveCompare(handle) == .orderedSame { return person }
        return direct
    }

    // MARK: - accessKardashian downloads (app-wide, pausable)

    /// Live per-member download state, so the accessKardashian screens can show
    /// progress and offer Pause from anywhere while the run continues app-wide —
    /// the run used to live inside the member screen's own state, so leaving it
    /// orphaned the download.
    var akRunning: Set<String> = []
    var akProgress: [String: AccessKardashian.Progress] = [:]
    /// Captions awaiting Portuguese→English translation. Hosted on `ContentView`'s
    /// translation modifier so translation still happens after the download screen
    /// (which used to host it) is closed.
    var akPendingCaptions: [String: String] = [:]
    @ObservationIgnored private var akCancelFlags: [String: CancelFlag] = [:]
    /// When each member's *download phase* started — drives the live photos/min in
    /// the pill, the first thing to look at when a run feels slow.
    @ObservationIgnored private var akDownloadPhaseStart: [String: Date] = [:]

    func isAKDownloadRunning(_ memberName: String) -> Bool { akRunning.contains(memberName) }
    /// Lets in-flight photo downloads finish, then stops — Resume picks up from here.
    func pauseAKDownload(_ memberName: String) { akCancelFlags[memberName]?.set() }

    /// Crawls + downloads `member`'s gallery as an app-wide background activity
    /// (progress pill, navigable, best-effort background window), pausable at any
    /// time via `pauseAKDownload`. State/labels/captions/covers persist exactly as
    /// the old in-view run did.
    func startAKDownload(member: AccessKardashian.Member, into parentFolder: URL,
                         overwrite: Bool, refreshIndex: Bool) {
        guard !akRunning.contains(member.name) else { return }
        let folder = parentFolder.appendingPathComponent(member.name, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        markKardashianFolder(folder)
        if let d = AccessKardashian.birthdayDate(member) { setBirthday(d, for: folder) }

        let flag = CancelFlag()
        akCancelFlags[member.name] = flag
        akRunning.insert(member.name)
        akProgress[member.name] = AccessKardashian.Progress(phase: "Starting…", fraction: 0, done: 0, total: 0)
        let id = beginActivity("accessKardashian", indeterminate: true)
        setActivity(id, status: member.name)
        let bg = BackgroundTaskHolder(); bg.begin(name: "accessKardashian \(member.name)")
        Task {
            let r = await AccessKardashian.run(
                member: member, into: folder, overwrite: overwrite, refreshIndex: refreshIndex,
                progress: { p in
                    Task { @MainActor in
                        self.akProgress[member.name] = p
                        let line: String
                        if p.phase == "Downloading" {
                            let started = self.akDownloadPhaseStart[member.name] ?? {
                                let now = Date(); self.akDownloadPhaseStart[member.name] = now; return now
                            }()
                            let mins = Date().timeIntervalSince(started) / 60
                            let rate = mins > 0.3 ? " · ~\(Int(Double(p.done) / mins))/min" : ""
                            line = "\(member.name) — \(p.done) of \(p.total)\(rate)"
                        } else {
                            line = "\(member.name) — \(p.phase)"
                        }
                        self.setActivity(id, status: line, fraction: p.phase == "Downloading" ? p.fraction : -1)
                    }
                },
                isCancelled: { flag.isSet })

            // Tag every downloaded photo with its category label, and store captions
            // (Portuguese now; translated to English app-wide on iOS 18+).
            addLabels(r.labelsByCategory)
            if !r.captions.isEmpty {
                setCaptions(r.captions)
                akPendingCaptions.merge(r.captions) { _, new in new }
            }
            // Clear Coppermine file-info tooltips an earlier version wrongly stored as captions.
            let stale = captions.filter { $0.key.hasPrefix(folder.path + "/") && AccessKardashian.isInfoBlock($0.value) }
            if !stale.isEmpty { setCaptions(stale.mapValues { _ in "" }) }

            let present = r.downloaded + r.skipped
            setAKMember(member.name, .init(folderPath: folder.path, completed: !r.cancelled,
                                           total: max(r.total, present), downloaded: present,
                                           updated: Date().timeIntervalSince1970))
            akRunning.remove(member.name)
            akCancelFlags[member.name] = nil
            akProgress[member.name] = nil
            akDownloadPhaseStart[member.name] = nil
            endActivity(id, result: akResultMessage(member: member, r: r, present: present))
            if present > 0 { contentDidChange(under: folder) }
            bg.end()
        }
    }

    private func akResultMessage(member: AccessKardashian.Member, r: AccessKardashian.Result, present: Int) -> String {
        if r.cancelled {
            // A drive-failure abort also lands here (paused, resumable) — surface its note.
            return "Paused \(member.name) at \(present) of \(max(r.total, present))."
                + (r.note.map { " \($0)" } ?? " Resume anytime from “Download from accessKardashian…”.")
        }
        guard r.downloaded > 0 || r.skipped > 0 else { return r.note ?? "Nothing downloaded for \(member.name)." }
        var s = "Downloaded \(r.downloaded) new photo\(r.downloaded == 1 ? "" : "s") for \(member.name)"
        if r.skipped > 0 { s += " (\(r.skipped) already had)" }
        s += "."
        // Diagnostics: the rate plus what dragged on it (retries = the gallery
        // stalling/throttling; reduced size = originals missing on the server).
        if r.downloaded > 0, r.perMinute > 0 { s += " ~\(r.perMinute)/min." }
        if r.retried > 0 { s += " \(r.retried) retr\(r.retried == 1 ? "y" : "ies")." }
        if r.reducedSize > 0 { s += " \(r.reducedSize) at reduced size." }
        if let note = r.note { s += " \(note)" }
        return s
    }

    /// Clean-up review state per folder: the set of item paths already decided on
    /// (kept or deleted). The queue on (re-)open is simply "viewable items not in
    /// this set", so it resumes correctly every run regardless of order.
    var cleanupReviewed: [String: [String]] = Library.migrateBulk("cleanupReviewed", legacyKey: "photoBrowser.cleanupReviewed") {
        (UserDefaults.standard.dictionary(forKey: $0) as? [String: [String]]) ?? [:]
    }
    func reviewedInCleanup(_ folder: URL) -> Set<String> { Set(cleanupReviewed[folder.path] ?? []) }
    func markCleanupReviewed(_ url: URL, in folder: URL) {
        var s = Set(cleanupReviewed[folder.path] ?? [])
        guard s.insert(url.path).inserted else { return }
        cleanupReviewed[folder.path] = Array(s)
        Self.saveBulk(cleanupReviewed, "cleanupReviewed")
    }
    func resetCleanup(_ folder: URL) {
        guard cleanupReviewed[folder.path] != nil else { return }
        cleanupReviewed.removeValue(forKey: folder.path)
        Self.saveBulk(cleanupReviewed, "cleanupReviewed")
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

    /// One-time fix for an earlier model where bulk "Set Handles" / download registered
    /// the *person* folder itself as the Instagram folder (so it showed as a bubble on the
    /// home screen). For each such person folder it creates a `@handle` subfolder, moves
    /// the folder's **Instagram** content into it — known IG post files (tracked in
    /// `igPostedBy`) plus its highlight / "Stories" subfolders — re-keys that content's
    /// metadata, and moves the registration down (copying the profile-photo cover so both the
    /// person folder and the nested bubble keep a thumbnail). The person folder stays a
    /// regular folder with the Instagram folder nested inside. Only files known to be from
    /// Instagram are moved, so the user's own files are never touched. Folders already named
    /// exactly the handle are left alone (never nested into themselves).
    func migrateInstagramPersonFolders() {
        // v2 key — re-runs even if the earlier, empty-only migration already ran.
        guard !UserDefaults.standard.bool(forKey: "photoBrowser.didMigrateIGPersonFolders2") else { return }
        UserDefaults.standard.set(true, forKey: "photoBrowser.didMigrateIGPersonFolders2")
        let fm = FileManager.default
        var moves: [(from: URL, to: URL)] = []
        var newStoryHighlights: [String] = []
        var changed = false

        for (path, info) in Array(instagramFolders) {           // snapshot — we mutate the dict below
            guard !info.handle.isEmpty else { continue }
            let person = URL(fileURLWithPath: path)
            guard person.lastPathComponent.caseInsensitiveCompare(info.handle) != .orderedSame else { continue }
            let igFolder = person.appendingPathComponent(info.handle, isDirectory: true)

            if instagramFolders[igFolder.path] == nil {
                try? fm.createDirectory(at: igFolder, withIntermediateDirectories: true)
                // Move only this folder's *Instagram* content down into the @handle folder:
                // its highlight/Stories subfolders, and files we know came from Instagram.
                let children = (try? fm.contentsOfDirectory(
                    at: person, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
                for child in children where child.path != igFolder.path {
                    let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                    let isStories = isDir && child.lastPathComponent == "Stories"
                    let isIGContent = isDir
                        ? (instagramHighlights.contains(child.path) || isStories)
                        : (igPostedBy[child.path] != nil)
                    guard isIGContent else { continue }
                    let target = igFolder.appendingPathComponent(child.lastPathComponent)
                    guard !fm.fileExists(atPath: target.path) else { continue }     // never overwrite
                    if (try? fm.moveItem(at: child, to: target)) != nil {
                        moves.append((child, target))
                        if isStories { newStoryHighlights.append(target.path) }     // pinned Stories bubble
                    }
                }
                instagramFolders[igFolder.path] = info
                // Give the @handle bubble its *own copy* of the profile-photo cover, and
                // leave the person folder's cover in place — don't strip its thumbnail to a
                // bare folder icon.
                if let coverName = folderCovers[path] {
                    let newName = UUID().uuidString + ".jpg"
                    if (try? fm.copyItem(at: coversDirectory.appendingPathComponent(coverName),
                                         to: coversDirectory.appendingPathComponent(newName))) != nil {
                        folderCovers[igFolder.path] = newName
                    }
                }
            }
            instagramFolders.removeValue(forKey: path)          // person folder is no longer the Instagram folder
            igLastHandle[person.path] = info.handle              // re-mapping still prefills the handle
            changed = true
        }

        guard changed else { return }
        for s in newStoryHighlights { instagramHighlights.insert(s) }   // ensure "Stories" is a highlight bubble
        if moves.isEmpty {
            persistInstagramFolders()
            UserDefaults.standard.set(folderCovers, forKey: "photoBrowser.folderCovers")
            UserDefaults.standard.set(igLastHandle, forKey: "photoBrowser.igLastHandle")
            UserDefaults.standard.set(Array(instagramHighlights), forKey: "photoBrowser.instagramHighlights")
        } else {
            itemsMoved(moves)     // re-keys all moved content + persists every path-keyed collection
        }
        changeToken += 1
    }

    /// Corrective for installs where the first nesting migration *moved* (rather than copied)
    /// each person folder's profile-photo cover down into its `@handle` subfolder, leaving the
    /// person folder a bare folder icon. Gives every such person folder its own copy of the
    /// nested Instagram folder's cover back, so its thumbnail returns. One-time, idempotent.
    func restorePersonFolderCovers() {
        guard !UserDefaults.standard.bool(forKey: "photoBrowser.didRestorePersonCovers") else { return }
        UserDefaults.standard.set(true, forKey: "photoBrowser.didRestorePersonCovers")
        let fm = FileManager.default
        let rootPath = activeRoot?.path ?? rootURL?.path
        var changed = false
        for igPath in instagramFolders.keys {
            let person = URL(fileURLWithPath: igPath).deletingLastPathComponent()
            guard person.path != rootPath else { continue }          // @handle sits directly at the root — no person folder
            guard instagramFolders[person.path] == nil else { continue }   // parent isn't itself an Instagram folder
            guard folderCovers[person.path] == nil, let name = folderCovers[igPath] else { continue }
            let newName = UUID().uuidString + ".jpg"
            if (try? fm.copyItem(at: coversDirectory.appendingPathComponent(name),
                                 to: coversDirectory.appendingPathComponent(newName))) != nil {
                folderCovers[person.path] = newName
                changed = true
            }
        }
        if changed {
            UserDefaults.standard.set(folderCovers, forKey: "photoBrowser.folderCovers")
            changeToken += 1
        }
    }

    /// Highlight subfolders (shown as bubbles inside an Instagram profile folder).
    var instagramHighlights: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "photoBrowser.instagramHighlights") ?? [])
    func isInstagramHighlight(_ folder: URL) -> Bool { instagramHighlights.contains(folder.path) }
    func markInstagramHighlight(_ folder: URL) {
        guard instagramHighlights.insert(folder.path).inserted else { return }
        UserDefaults.standard.set(Array(instagramHighlights), forKey: "photoBrowser.instagramHighlights")
    }

    /// Folders hidden from browsing — no grid tile, no bubble, and (with their
    /// contents) no search hits — without touching anything on the drive. The
    /// "Show Hidden Folders" toggle in the ⋯ menu reveals them for unhiding.
    var hiddenFolders: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "photoBrowser.hiddenFolders") ?? [])
    func isHiddenFolder(_ url: URL) -> Bool { hiddenFolders.contains(url.path) }
    /// Whether `path` is a hidden folder or lives inside one.
    func isUnderHiddenFolder(_ path: String) -> Bool {
        hiddenFolders.contains { path == $0 || path.hasPrefix($0 + "/") }
    }
    func setFolderHidden(_ hidden: Bool, for url: URL) {
        if hidden { hiddenFolders.insert(url.path) } else { hiddenFolders.remove(url.path) }
        UserDefaults.standard.set(Array(hiddenFolders), forKey: "photoBrowser.hiddenFolders")
        labelsVersion += 1
        contentDidChange(under: url.deletingLastPathComponent())
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
    var igPostedBy: [String: String] = Library.migrateBulk("igPostedBy", legacyKey: "photoBrowser.igPostedBy") {
        (UserDefaults.standard.dictionary(forKey: $0) as? [String: String]) ?? [:]
    }
    func postedBy(for url: URL) -> String? { igPostedBy[url.path] }
    func setPostedBy(_ handle: String, for url: URL) {
        igPostedBy[url.path] = handle
        Self.saveBulk(igPostedBy, "igPostedBy")
    }
    /// Batch "posted by" set (persists once) — avoids O(n²) writes on bulk imports.
    func setPostedBy(_ map: [String: String]) {
        guard !map.isEmpty else { return }
        for (k, v) in map { igPostedBy[k] = v }
        Self.saveBulk(igPostedBy, "igPostedBy")
    }

    /// When the shared "Today's Instagram Stories" temp folder was last (re)started.
    /// The homepage stories sweep appends to it while it's under 24h old, and clears +
    /// replaces it once it ages past that. 0 = never created.
    var igStoriesTempStart: Double = UserDefaults.standard.double(forKey: "photoBrowser.igStoriesTempStart")
    func setIGStoriesTempStart(_ when: Double) {
        igStoriesTempStart = when
        UserDefaults.standard.set(when, forKey: "photoBrowser.igStoriesTempStart")
    }

    /// "Today's Instagram Stories" file path → that person's own Stories folder path, so
    /// a collected story can link back to where the rest of that person's stories live
    /// (surfaced as an "Open Stories" action in the info panel).
    var storyLinks: [String: String] = (UserDefaults.standard.dictionary(forKey: "photoBrowser.storyLinks") as? [String: String]) ?? [:]
    func storyLink(for url: URL) -> URL? {
        storyLinks[url.path].map { URL(fileURLWithPath: $0) }
    }
    func setStoryLinks(_ paths: [String], to storiesFolder: URL) {
        guard !paths.isEmpty else { return }
        for p in paths { storyLinks[p] = storiesFolder.path }
        UserDefaults.standard.set(storyLinks, forKey: "photoBrowser.storyLinks")
    }

    /// Returns the shared "Today's Instagram Stories" folder under `root`, clearing it
    /// first when it has aged past 24h (so same-day runs append and a new day replaces).
    /// Both the homepage stories sweep and the bulk profile download collect into it.
    func prepareTodaysStoriesFolder(root: URL) -> URL {
        let folder = root.appendingPathComponent("Today's Instagram Stories", isDirectory: true)
        let now = Date().timeIntervalSince1970
        let fm = FileManager.default
        if igStoriesTempStart == 0 || now - igStoriesTempStart > 24 * 3600 {
            // Clear by an atomic *rename* to a hidden trash name, then delete that in the background. Deleting
            // in place risks leaving a half-removed, un-listable folder if iOS kills the app mid-delete (an
            // external drive is slow) — which corrupts the directory entry so the folder can't even be
            // re-created, moved or deleted afterward.
            if fm.fileExists(atPath: folder.path) {
                let trash = root.appendingPathComponent(".pb-oldstories-\(UUID().uuidString)", isDirectory: true)
                if (try? fm.moveItem(at: folder, to: trash)) != nil {
                    Task.detached(priority: .background) { try? FileManager.default.removeItem(at: trash) }
                } else {
                    try? fm.removeItem(at: folder)
                }
            }
            setIGStoriesTempStart(now)
            storyLinks = [:]                                  // the linked temp files are gone now
            UserDefaults.standard.set(storyLinks, forKey: "photoBrowser.storyLinks")
        }
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        flattenStoriesSubfolders(in: folder)
        return folder
    }

    /// Transition cleanup: earlier builds organized today's stories into per-handle
    /// subfolders; the collection is flat again (handle-prefixed names), so pull any
    /// leftover subfolder's files up and remove it. No-op once none remain.
    private func flattenStoriesSubfolders(in folder: URL) {
        let fm = FileManager.default
        let children = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                                    options: [.skipsHiddenFiles])) ?? []
        var moves: [(from: URL, to: URL)] = []
        for sub in children where (try? sub.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            let handle = sub.lastPathComponent
            let files = (try? fm.contentsOfDirectory(at: sub, includingPropertiesForKeys: nil,
                                                     options: [.skipsHiddenFiles])) ?? []
            var movedAll = true
            for f in files {
                let dest = folder.appendingPathComponent("\(handle)_\(f.lastPathComponent)")
                if fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: f); continue }   // already flat — drop the dupe
                if (try? fm.moveItem(at: f, to: dest)) != nil { moves.append((f, dest)) } else { movedAll = false }
            }
            if movedAll { try? fm.removeItem(at: sub) }
        }
        if !moves.isEmpty { itemsMoved(moves) }   // story links / labels follow the files up
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
        var changed: Set<String> = []
        for (name, paths) in pathsByLabel where !paths.isEmpty {
            customLabels[name, default: []].formUnion(paths); changed.insert(name)
        }
        guard !changed.isEmpty else { return }
        persistCustomLabels(changed)
        labelsVersion += 1
    }

    // MARK: - "Not duplicates" (user-confirmed non-duplicate pairs)

    /// Pairs the user marked as NOT duplicates, as "pathA\npathB" (sorted), so a
    /// future Find-Duplicates run hides groups whose every pair is dismissed.
    var notDuplicatePairs: Set<String> = Library.migrateBulk("notDuplicates", legacyKey: "photoBrowser.notDuplicates") {
        Set(UserDefaults.standard.stringArray(forKey: $0) ?? [])
    }

    private static func pairKey(_ a: String, _ b: String) -> String { a < b ? "\(a)\n\(b)" : "\(b)\n\(a)" }
    func areNotDuplicates(_ a: String, _ b: String) -> Bool { notDuplicatePairs.contains(Self.pairKey(a, b)) }
    /// Records every pair among `paths` as not-duplicates.
    func markNotDuplicates(_ paths: [String]) {
        guard paths.count >= 2 else { return }
        for i in 0..<paths.count { for j in (i + 1)..<paths.count { notDuplicatePairs.insert(Self.pairKey(paths[i], paths[j])) } }
        Self.saveBulk(notDuplicatePairs, "notDuplicates")
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
    /// label yet — backs the "No Label" filter. Derived from the in-memory index
    /// (an in-memory filter) — the old version re-walked the whole 100k-file
    /// subtree on the drive every time it ran. Falls back to the walk only before
    /// the first index build.
    func unlabeledMedia(under folder: URL, labeled: Set<String>, sort: SortKey) async -> [Entry] {
        let rootPath = folder.path
        let idx = index                                    // snapshot on the main actor
        if !idx.isEmpty {
            return await Task.detached(priority: .userInitiated) {
                let result = idx.filter { e in
                    (e.kind == .image || e.kind == .video)
                        && !labeled.contains(e.url.path)
                        && (e.url.path == rootPath || e.url.path.hasPrefix(rootPath + "/"))
                }
                return Self.sortEntries(result, by: sort)
            }.value
        }
        return await Self.walkUnlabeled(under: folder, labeled: labeled, sort: sort)
    }

    nonisolated private static func walkUnlabeled(under folder: URL, labeled: Set<String>, sort: SortKey) async -> [Entry] {
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
        setLabels(name, on: [url], on)
    }

    /// Applies one label to many items in a single mutation + one (debounced)
    /// persist. Looping `setLabel` per item re-encoded the whole store per item —
    /// O(selection × store size) — which froze the app on large selections.
    func setLabels(_ name: String, on urls: [URL], _ on: Bool) {
        guard !urls.isEmpty else { return }
        var paths = customLabels[name] ?? []
        if on { for u in urls { paths.insert(u.path) } }
        else { for u in urls { paths.remove(u.path) } }
        customLabels[name] = paths
        persistCustomLabels([name])
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

    /// Keeps labels, captions, covers, etc. attached to an item after it's moved or
    /// renamed within the app, by rewriting the stored path (and, for a folder, every
    /// path underneath it).
    func itemMoved(from oldURL: URL, to newURL: URL) {
        itemsMoved([(from: oldURL, to: newURL)])
    }

    /// Batch version: re-keys all moved items in a single pass with one persist.
    /// The remap is O(1) per stored path — an exact-match table for files, prefix
    /// pairs only for folders (subtree re-key). Comparing every stored path against
    /// every moved item (with a string concat per check) stalled the main thread
    /// for seconds at 100k-photo scale, so a big move froze on the last progress
    /// frame and the watchdog killed the app before the success message.
    func itemsMoved(_ moves: [(from: URL, to: URL)]) {
        guard !moves.isEmpty else { return }
        var exact: [String: String] = [:]
        var folders: [(old: String, oldSlash: String, new: String)] = []
        for m in moves {
            let old = m.from.path, new = m.to.path
            exact[old] = new
            // Directory-ness: trust the URL flag when set, else ask the filesystem —
            // the just-moved destination is hot in the attribute cache, and a folder
            // misread as a file (e.g. a dotted name off an unmarked URL) would orphan
            // every label underneath it.
            var isDir: ObjCBool = false
            if m.from.hasDirectoryPath
                || (FileManager.default.fileExists(atPath: new, isDirectory: &isDir) && isDir.boolValue) {
                folders.append((old, old + "/", new))
            }
        }
        applyRemap { p in
            if let n = exact[p] { return n }
            for f in folders where p.hasPrefix(f.oldSlash) { return f.new + p.dropFirst(f.old.count) }
            return p
        }
    }

    /// Applies `remap` to every path-keyed collection, then persists once.
    private func applyRemap(_ remap: (String) -> String) {
        favorites = Set(favorites.map(remap))
        aiLabels = Set(aiLabels.map(remap))
        editedInAppPaths = Set(editedInAppPaths.map(remap))
        framesFolders = Set(framesFolders.map(remap))
        kardashianFolders = Set(kardashianFolders.map(remap))
        instagramHighlights = Set(instagramHighlights.map(remap))
        albumHighlights = Set(albumHighlights.map(remap))
        hiddenFolders = Set(hiddenFolders.map(remap))
        customLabels = customLabels.mapValues { Set($0.map(remap)) }
        captions = remapKeys(captions, remap)
        folderCovers = remapKeys(folderCovers, remap)
        itemThumbnails = remapKeys(itemThumbnails, remap)
        photoOrigins = remapKeys(photoOrigins, remap)
        igPostedBy = remapKeys(igPostedBy, remap)
        igLastHandle = remapKeys(igLastHandle, remap)
        storyLinks = Dictionary(storyLinks.map { (remap($0.key), remap($0.value)) }, uniquingKeysWith: { a, _ in a })
        folderBirthdays = remapKeys(folderBirthdays, remap)
        instagramFolders = remapKeys(instagramFolders, remap)
        facebookFolders = remapKeys(facebookFolders, remap)
        tiktokFolders = remapKeys(tiktokFolders, remap)
        tiktokLikes = remapKeys(tiktokLikes, remap)
        lastTikTokHandleByFolder = remapKeys(lastTikTokHandleByFolder, remap)
        vscoFolders = remapKeys(vscoFolders, remap)
        lastVSCOUsernameByFolder = remapKeys(lastVSCOUsernameByFolder, remap)
        bubbleOrders = Dictionary(bubbleOrders.map { (remap($0.key), $0.value.map(remap)) }, uniquingKeysWith: { a, _ in a })
        for (name, var state) in accessKardashian {
            let nf = remap(state.folderPath)
            if nf != state.folderPath { state.folderPath = nf; accessKardashian[name] = state }
        }
        aiGeneratedPaths = Set(aiGeneratedPaths.map(remap))
        aiGenerations = remapKeys(aiGenerations, remap)
        cleanupReviewed = Dictionary(cleanupReviewed.map { (remap($0.key), $0.value.map(remap)) }, uniquingKeysWith: { a, _ in a })
        notDuplicatePairs = Set(notDuplicatePairs.map { pair in
            let parts = pair.split(separator: "\n", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return pair }
            return Self.pairKey(remap(parts[0]), remap(parts[1]))
        })
        // People reference faces as "path#index"; the face detections themselves are
        // keyed by raw path in the FaceStore. Both must follow, or the whole People
        // library silently orphans on a move/rename or a drive remount.
        people = people.mapValues { ids in
            Set(ids.map { id in
                let path = Self.pathOfFaceID(id)
                let np = remap(path)
                return np == path ? id : np + id.dropFirst(path.count)
            })
        }
        FaceStore.shared.remap(remap)

        persistCustomLabels()          // already coalesced onto a later turn
        persistAllPathKeyed()
        labelsVersion += 1
    }

    /// Serial background queue for persisting the path-keyed collections. Encoding
    /// hundreds of thousands of paths to JSON inline on the main thread (the other
    /// half of the post-move freeze) blocked the UI long enough for the watchdog to
    /// kill the app; FIFO ordering keeps a rapid second remap from being overwritten
    /// by a stale earlier snapshot.
    nonisolated private static let persistQueue = DispatchQueue(label: "photoBrowser.persistPathKeyed", qos: .utility)

    /// Snapshots every path-keyed collection (cheap — copy-on-write) and writes them
    /// on the persist queue. `saveBulk` and `UserDefaults` are both thread-safe.
    private func persistAllPathKeyed() {
        let favorites = self.favorites, aiLabels = self.aiLabels
        let editedInAppPaths = self.editedInAppPaths, aiGeneratedPaths = self.aiGeneratedPaths
        let cleanupReviewed = self.cleanupReviewed, notDuplicatePairs = self.notDuplicatePairs
        let people = self.people
        let framesFolders = self.framesFolders, kardashianFolders = self.kardashianFolders
        let instagramHighlights = self.instagramHighlights, albumHighlights = self.albumHighlights
        let hiddenFolders = self.hiddenFolders
        let captions = self.captions, folderCovers = self.folderCovers, photoOrigins = self.photoOrigins
        let itemThumbnails = self.itemThumbnails
        let igPostedBy = self.igPostedBy, igLastHandle = self.igLastHandle, storyLinks = self.storyLinks
        let folderBirthdays = self.folderBirthdays, bubbleOrders = self.bubbleOrders
        let lastTikTokHandleByFolder = self.lastTikTokHandleByFolder
        let instagramFolders = self.instagramFolders, facebookFolders = self.facebookFolders
        let tiktokFolders = self.tiktokFolders, tiktokLikes = self.tiktokLikes
        let accessKardashian = self.accessKardashian
        let aiGenerations = self.aiGenerations
        let vscoFolders = self.vscoFolders, lastVSCOUsernameByFolder = self.lastVSCOUsernameByFolder
        Self.persistQueue.async {
            Self.saveBulk(favorites, "favorites")
            Self.saveBulk(aiLabels, "ai")
            Self.saveBulk(editedInAppPaths, "editedInApp")
            Self.saveBulk(aiGeneratedPaths, "aiGenerated")
            Self.saveBulk(cleanupReviewed, "cleanupReviewed")
            Self.saveBulk(notDuplicatePairs, "notDuplicates")
            Self.saveBulk(people, "people")
            Self.saveBulk(captions, "captions")
            Self.saveBulk(photoOrigins, "photoOrigins")
            Self.saveBulk(igPostedBy, "igPostedBy")
            let ud = UserDefaults.standard
            ud.set(Array(framesFolders), forKey: "photoBrowser.framesFolders")
            ud.set(Array(kardashianFolders), forKey: "photoBrowser.kardashianFolders")
            ud.set(Array(instagramHighlights), forKey: "photoBrowser.instagramHighlights")
            ud.set(Array(albumHighlights), forKey: "photoBrowser.albumHighlights")
            ud.set(Array(hiddenFolders), forKey: "photoBrowser.hiddenFolders")
            ud.set(folderCovers, forKey: "photoBrowser.folderCovers")
            ud.set(itemThumbnails, forKey: "photoBrowser.itemThumbnails")
            ud.set(igLastHandle, forKey: "photoBrowser.igLastHandle")
            ud.set(storyLinks, forKey: "photoBrowser.storyLinks")
            ud.set(folderBirthdays, forKey: "photoBrowser.birthdays")
            ud.set(bubbleOrders, forKey: "photoBrowser.bubbleOrder")
            ud.set(lastTikTokHandleByFolder, forKey: "photoBrowser.lastTikTokHandle")
            ud.set(tiktokLikes, forKey: "photoBrowser.tiktokLikes")
            if let data = try? JSONEncoder().encode(instagramFolders) { ud.set(data, forKey: "photoBrowser.instagramFolders") }
            if let data = try? JSONEncoder().encode(facebookFolders) { ud.set(data, forKey: "photoBrowser.facebookFolders") }
            if let data = try? JSONEncoder().encode(tiktokFolders) { ud.set(data, forKey: "photoBrowser.tiktokFolders") }
            if let data = try? JSONEncoder().encode(accessKardashian) { ud.set(data, forKey: "photoBrowser.accessKardashian") }
            if let data = try? JSONEncoder().encode(aiGenerations) { ud.set(data, forKey: "photoBrowser.aiGenerations") }
            if let data = try? JSONEncoder().encode(vscoFolders) { ud.set(data, forKey: "photoBrowser.vscoFolders") }
            ud.set(lastVSCOUsernameByFolder, forKey: "photoBrowser.lastVSCOUsername")
        }
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

        Self.saveBulk(favorites, "favorites")
        Self.saveBulk(aiLabels, "ai")
        Self.saveBulk(captions, "captions")
        UserDefaults.standard.set(folderCovers, forKey: "photoBrowser.folderCovers")
        Self.saveBulk(photoOrigins, "photoOrigins")
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

    /// Duplicates every piece of path-keyed data under `oldRoot` — Favorites, To AI,
    /// custom labels, captions, covers, birthdays, edited/AI badges, frames folders,
    /// Instagram/Facebook/TikTok records, highlights, bubble order, story links,
    /// likes, Clean Up progress, not-duplicate pairs, People faces — onto the same
    /// relative paths under `newRoot`, **keeping the originals**. For a backup drive
    /// holding a copy of the library: browsing the backup then shows everything the
    /// primary shows. The persistent per-file caches (capture dates, media specs,
    /// OCR text) are duplicated too, so the backup browses warm. Deliberately blind
    /// (no per-file existence checks): stat-ing tens of thousands of keys on an
    /// external drive would take minutes, and an entry for a file the backup lacks
    /// is inert. Returns the number of entries added.
    func duplicateMetadata(from oldRoot: URL, to newRoot: URL) -> Int {
        let from = oldRoot.path, to = newRoot.path
        guard from != to, !to.hasPrefix(from + "/"), !from.hasPrefix(to + "/") else { return 0 }
        var added = 0
        func mapped(_ p: String) -> String? {
            guard p == from || p.hasPrefix(from + "/") else { return nil }
            return to + p.dropFirst(from.count)
        }
        func dupSet(_ set: inout Set<String>) {
            for p in Array(set) { if let np = mapped(p), set.insert(np).inserted { added += 1 } }
        }
        func dupDict<V>(_ dict: inout [String: V], value: (V) -> V = { $0 }) {
            for (k, v) in dict { if let nk = mapped(k), dict[nk] == nil { dict[nk] = value(v); added += 1 } }
        }

        dupSet(&favorites); dupSet(&aiLabels); dupSet(&editedInAppPaths); dupSet(&aiGeneratedPaths)
        dupSet(&framesFolders); dupSet(&kardashianFolders); dupSet(&instagramHighlights); dupSet(&albumHighlights)
        dupSet(&hiddenFolders)
        customLabels = customLabels.mapValues { paths in
            var s = paths
            for p in paths { if let np = mapped(p), s.insert(np).inserted { added += 1 } }
            return s
        }
        dupDict(&captions); dupDict(&photoOrigins); dupDict(&igPostedBy); dupDict(&igLastHandle)
        dupDict(&lastTikTokHandleByFolder); dupDict(&tiktokLikes); dupDict(&folderBirthdays)
        dupDict(&instagramFolders); dupDict(&facebookFolders); dupDict(&tiktokFolders)
        dupDict(&cleanupReviewed, value: { $0.map { mapped($0) ?? $0 } })
        dupDict(&bubbleOrders, value: { $0.map { mapped($0) ?? $0 } })
        for (k, v) in storyLinks {
            if let nk = mapped(k), storyLinks[nk] == nil { storyLinks[nk] = mapped(v) ?? v; added += 1 }
        }
        for pair in Array(notDuplicatePairs) {
            let parts = pair.split(separator: "\n", maxSplits: 1).map(String.init)
            guard parts.count == 2, let a = mapped(parts[0]), let b = mapped(parts[1]) else { continue }
            if notDuplicatePairs.insert(Self.pairKey(a, b)).inserted { added += 1 }
        }
        // People: each person gains her backup-side face references (same groups).
        for (name, ids) in people {
            var set = ids
            for id in ids {
                let path = Self.pathOfFaceID(id)
                guard let np = mapped(path) else { continue }
                if set.insert(np + id.dropFirst(path.count)).inserted { added += 1 }
            }
            people[name] = set
        }
        FaceStore.shared.duplicatePrefix(from: from, to: to)
        // Covers: the backup key gets its own copy of the image file, so deleting
        // either side later can't strip the other's cover.
        let fm = FileManager.default
        var newCovers = folderCovers
        for (key, filename) in folderCovers {
            guard let nk = mapped(key), newCovers[nk] == nil else { continue }
            let newName = UUID().uuidString + ".jpg"
            if (try? fm.copyItem(at: coversDirectory.appendingPathComponent(filename),
                                 to: coversDirectory.appendingPathComponent(newName))) != nil {
                newCovers[nk] = newName; added += 1
            }
        }
        folderCovers = newCovers
        // Per-file caches are keyed drive-relative — a no-op when the backup's
        // in-volume layout matches the primary (they already hit as-is).
        MetadataLoader.duplicateStores(fromStablePrefix: oldRoot.stableCacheID,
                                       toStablePrefix: newRoot.stableCacheID)

        guard added > 0 else { return 0 }
        Self.saveBulk(favorites, "favorites")
        Self.saveBulk(aiLabels, "ai")
        Self.saveBulk(editedInAppPaths, "editedInApp")
        Self.saveBulk(aiGeneratedPaths, "aiGenerated")
        Self.saveBulk(cleanupReviewed, "cleanupReviewed")
        Self.saveBulk(notDuplicatePairs, "notDuplicates")
        Self.saveBulk(people, "people")
        Self.saveBulk(captions, "captions")
        Self.saveBulk(photoOrigins, "photoOrigins")
        Self.saveBulk(igPostedBy, "igPostedBy")
        UserDefaults.standard.set(Array(framesFolders), forKey: "photoBrowser.framesFolders")
        UserDefaults.standard.set(Array(kardashianFolders), forKey: "photoBrowser.kardashianFolders")
        UserDefaults.standard.set(Array(instagramHighlights), forKey: "photoBrowser.instagramHighlights")
        UserDefaults.standard.set(Array(albumHighlights), forKey: "photoBrowser.albumHighlights")
        UserDefaults.standard.set(Array(hiddenFolders), forKey: "photoBrowser.hiddenFolders")
        UserDefaults.standard.set(folderCovers, forKey: "photoBrowser.folderCovers")
        UserDefaults.standard.set(igLastHandle, forKey: "photoBrowser.igLastHandle")
        UserDefaults.standard.set(storyLinks, forKey: "photoBrowser.storyLinks")
        UserDefaults.standard.set(folderBirthdays, forKey: "photoBrowser.birthdays")
        UserDefaults.standard.set(bubbleOrders, forKey: "photoBrowser.bubbleOrder")
        UserDefaults.standard.set(lastTikTokHandleByFolder, forKey: "photoBrowser.lastTikTokHandle")
        persistCustomLabels()
        persistInstagramFolders()
        persistFacebookFolders()
        persistTikTokFolders()
        persistTikTokLikes()
        labelsVersion += 1
        return added
    }

    /// Labeled items (favorites / To AI / custom labels) at or below `folder`,
    /// including folders. Resolves against the in-memory index — a dictionary join,
    /// no drive I/O — and only stats paths the index doesn't know yet (fresh files,
    /// or before the first build), bounded-concurrent. The old version stat'ed
    /// every labeled path serially: tens of seconds over a 100k-photo label set.
    func labeledEntries(under folder: URL, paths: Set<String>, sort: SortKey) async -> [Entry] {
        guard !paths.isEmpty else { return [] }
        let rootPath = folder.path
        let idx = index                                    // snapshot on the main actor
        return await Task.detached(priority: .userInitiated) { () -> [Entry] in
            let inScope = paths.filter { $0 == rootPath || $0.hasPrefix(rootPath + "/") }
            guard !inScope.isEmpty else { return [] }
            var byPath: [String: Entry] = [:]
            byPath.reserveCapacity(idx.count)
            for e in idx { byPath[e.url.path] = e }
            var result: [Entry] = []
            var missing: [String] = []
            for path in inScope {
                if let e = byPath[path] { result.append(e) } else { missing.append(path) }
            }
            if !missing.isEmpty {
                let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
                var slots = [Entry?](repeating: nil, count: missing.count)
                await withTaskGroup(of: (Int, Entry?).self) { group in
                    var i = 0
                    let maxConcurrent = 32
                    func addNext() {
                        guard i < missing.count else { return }
                        let n = i; let url = URL(fileURLWithPath: missing[n]); i += 1
                        group.addTask {
                            guard let rv = try? url.resourceValues(forKeys: keys) else { return (n, nil) }
                            return (n, Entry(url: url, name: url.lastPathComponent,
                                             kind: classify(url: url, isDirectory: rv.isDirectory ?? false),
                                             size: Int64(rv.fileSize ?? 0),
                                             modified: rv.contentModificationDate ?? .distantPast))
                        }
                    }
                    for _ in 0..<min(maxConcurrent, missing.count) { addNext() }
                    while let (n, e) = await group.next() { slots[n] = e; addNext() }
                }
                result.append(contentsOf: slots.compactMap { $0 })
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
                let placeMatch = !nameMatch && !capMatch && !ocrMatch
                    && (MetadataLoader.placeTextCached(for: entry)?.contains(q) ?? false)
                guard nameMatch || capMatch || ocrMatch || placeMatch else { continue }
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

    /// Defers the whole-drive index build (used by search / Library) a moment so it doesn't
    /// contend for drive I/O with the homepage's first listing + thumbnail prefetch on launch.
    /// A persisted snapshot of the previous index loads first, so search and the Library view
    /// are usable immediately instead of waiting out a full drive walk on every launch.
    func scheduleIndexBuild() {
        guard let root = rootURL else { return }
        indexing = true                 // show index-dependent views a loading state during the wait
        Task {
            if index.isEmpty, let saved = await Self.loadIndexSnapshot(for: root), !saved.isEmpty {
                if index.isEmpty && rootURL == root {   // nothing newer arrived while we read
                    index = saved
                    indexing = false
                }
            }
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            buildIndex()
        }
    }

    func buildIndex() {
        guard let root = rootURL else { return }
        if index.isEmpty { indexing = true }    // a snapshot already loaded → refresh silently
        Task {
            let all = await Self.enumerateAll(root)
            self.index = all
            self.indexing = false
            Self.saveIndexSnapshot(all, for: root)
            self.prewarmCaptureDates()
        }
    }

    /// Persisted whole-drive index (same remount-tolerant scheme as the listing
    /// snapshots), so launch #2+ has instant search/Library while the fresh walk runs.
    private struct IndexSnapshot: Codable { let rootStable: String; let rootPath: String; let entries: [Entry] }
    @ObservationIgnored nonisolated private static let indexFile: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("libraryIndex.json")
    }()
    nonisolated private static func saveIndexSnapshot(_ entries: [Entry], for root: URL) {
        let snapshot = IndexSnapshot(rootStable: root.stableCacheID, rootPath: root.path, entries: entries)
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: indexFile, options: .atomic)
            }
        }
    }
    nonisolated private static func loadIndexSnapshot(for root: URL) async -> [Entry]? {
        await Task.detached(priority: .userInitiated) { () -> [Entry]? in
            guard let data = try? Data(contentsOf: indexFile),
                  let snapshot = try? JSONDecoder().decode(IndexSnapshot.self, from: data),
                  snapshot.rootStable == root.stableCacheID else { return nil }
            if snapshot.rootPath == root.path { return snapshot.entries }
            let old = snapshot.rootPath, new = root.path
            return snapshot.entries.map { e in
                let p = e.url.path
                guard p.hasPrefix(old) else { return e }
                return Entry(url: URL(fileURLWithPath: new + p.dropFirst(old.count)),
                             name: e.name, kind: e.kind, size: e.size, modified: e.modified)
            }
        }.value
    }

    /// Fills the persistent capture-date store for the whole library in the
    /// background, so the first visit to any folder finds its dates already cached
    /// instead of paying a full EXIF/AVAsset pass (the default sort wants dates).
    /// Files already in the store short-circuit to a dictionary lookup, so on a
    /// warmed library this whole pass costs almost nothing. Runs once per launch,
    /// at background priority so it never contends with browsing.
    @ObservationIgnored private var didPrewarmDates = false
    private func prewarmCaptureDates() {
        guard !didPrewarmDates else { return }
        didPrewarmDates = true
        let media = index.filter { $0.kind == .image || $0.kind == .video }
        guard !media.isEmpty else { return }
        Task.detached(priority: .background) {
            var next = 0
            var done = 0
            await withTaskGroup(of: Void.self) { group in
                let maxConcurrent = 4       // gentle — browsing keeps priority on the drive
                func addNext() {
                    guard next < media.count else { return }
                    let e = media[next]; next += 1
                    group.addTask { _ = await MetadataLoader.captureDate(for: e) }
                }
                for _ in 0..<min(maxConcurrent, media.count) { addNext() }
                while await group.next() != nil {
                    done += 1
                    if done % 500 == 0 { MetadataLoader.scheduleDateStoreFlush() }   // debounced; survive an early exit
                    addNext()
                }
            }
            MetadataLoader.flushDateStore()   // final: persist everything from the full index walk
        }
    }

    /// Ensures `folder` has a cover thumbnail, picking a **random** photo/video from inside it
    /// (descending into subfolders when it holds only folders). Called lazily as folder cells
    /// appear, so covers fill in as you browse without waiting on the whole-drive index. A
    /// no-op if the folder already has a cover or contains no media. Off-main directory scan;
    /// the cover is set on the main actor.
    func ensureRandomCover(for folder: URL) async {
        guard folderCovers[folder.path] == nil else { return }
        // Profile folders show their avatar (set on download), not a random item.
        guard instagramInfo(for: folder) == nil, tiktokInfo(for: folder) == nil,
              ofInfo(for: folder) == nil else { return }
        guard let pick = await Self.randomMedia(in: folder) else { return }
        let entry = Entry(url: pick, name: pick.lastPathComponent,
                          kind: classify(url: pick, isDirectory: false), size: 0, modified: Date())
        guard let img = await Thumbnailer.shared.thumbnail(
                  for: entry, size: CGSize(width: 240, height: 240), scale: 2) else { return }
        if folderCovers[folder.path] == nil { setCover(img, for: folder) }   // still missing — set it
    }

    /// A random photo/video somewhere under `folder`: prefers a direct child, otherwise
    /// descends breadth-first (bounded) into subfolders for a representative item. Reads only
    /// the folders it needs, off the main actor.
    nonisolated static func randomMedia(in folder: URL) async -> URL? {
        await Task.detached(priority: .utility) {
            let fm = FileManager.default
            var level = [folder]
            var depth = 0
            while !level.isEmpty, depth < 8 {
                var media: [URL] = []
                var subdirs: [URL] = []
                for dir in level {
                    let items = (try? fm.contentsOfDirectory(
                        at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
                    for u in items {
                        if (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { subdirs.append(u) }
                        else if [.image, .video].contains(classify(url: u, isDirectory: false)) { media.append(u) }
                    }
                }
                if let pick = media.randomElement() { return pick }   // prefer the shallowest media
                level = subdirs
                depth += 1
            }
            return nil
        }.value
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
    /// Matches folder names, file names, app captions, OCR'd photo text, and
    /// indexed place names — deduped by URL (a folder can be found both as an
    /// index entry and via parent expansion, and duplicate ids broke the grid).
    func searchIndex(under folder: URL, query: String, captions: [String: String], sort: SortKey) -> [Entry] {
        let q = query.lowercased()
        let base = folder.path
        var matches: [Entry] = []
        var seen = Set<String>()                           // dedup across both match phases
        var parents = Set<String>()                        // folders holding indexed entries (for folder-name search)
        for e in index {
            let p = e.url.path
            guard p == base || p.hasPrefix(base + "/") else { continue }
            if e.name.lowercased().contains(q) || (captions[p]?.lowercased().contains(q) ?? false)
                || (MetadataLoader.ocrTextCached(for: e)?.contains(q) ?? false)       // text inside photos
                || (MetadataLoader.placeTextCached(for: e)?.contains(q) ?? false)     // indexed place names
                || (aiGenerations[p].map { $0.model.lowercased().contains(q) || $0.prompt.lowercased().contains(q) } ?? false) {  // AI model / prompt
                if seen.insert(p).inserted { matches.append(e) }
            }
            parents.insert((p as NSString).deletingLastPathComponent)
        }
        // Safety net for folders the index snapshot may lack (created after the last
        // build): expand every matched entry's ancestor folders and match their names.
        var folders = Set<String>()
        for parent in parents {
            var dir = parent
            while dir.count > base.count, dir.hasPrefix(base), folders.insert(dir).inserted {
                dir = (dir as NSString).deletingLastPathComponent
            }
        }
        for fp in folders where ((fp as NSString).lastPathComponent).lowercased().contains(q) && !seen.contains(fp) {
            seen.insert(fp)
            let u = URL(fileURLWithPath: fp, isDirectory: true)
            matches.append(Entry(url: u, name: u.lastPathComponent, kind: .folder, size: 0, modified: .distantPast))
        }
        return Self.sortEntries(matches, by: sort)
    }

    /// Scans every photo's GPS under `folder` (cached per file, ImageIO only) and
    /// reverse-geocodes each distinct ~1km location once, so search can match
    /// place names ("paris", "brooklyn", …). The geocoding pass is capped per run
    /// (CLGeocoder is rate-limited) — re-running continues where it left off.
    nonisolated func buildLocationIndex(under folder: URL,
                                        progress: @escaping @Sendable (Double) -> Void) async -> (photos: Int, places: Int) {
        let images = await Self.enumerateAll(folder).filter { $0.kind == .image }
        let total = images.count
        guard total > 0 else { return (0, 0) }
        var index = 0, done = 0
        await withTaskGroup(of: Void.self) { group in
            func addNext() {
                guard index < total else { return }
                let e = images[index]; index += 1
                group.addTask { _ = await MetadataLoader.gpsBin(for: e) }
            }
            for _ in 0..<min(8, total) { addNext() }
            while await group.next() != nil {
                done += 1
                if done % 25 == 0 || done == total { progress(0.5 * Double(done) / Double(total)) }
                addNext()
            }
        }
        MetadataLoader.flushPlaceStore()
        let named = await MetadataLoader.geocodeUnnamedBins { d, t in
            progress(0.5 + 0.5 * Double(d) / Double(max(t, 1)))
        }
        return (total, named)
    }

    // MARK: - Choosing / restoring the root folder

    func chooseFolder(_ url: URL) {
        if let prev = activeRoot { prev.stopAccessingSecurityScopedResource() }
        _ = url.startAccessingSecurityScopedResource()   // best-effort; keep for session
        waitingForDrive = false
        activeRoot = url
        rootURL = url
        rootName = url.lastPathComponent
        DriveWriter.configureForVolume(at: url)   // tune write durability to the drive's filesystem
        path = []
        if let data = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: bookmarkKey)
        }
        rekeyRootIfRemounted(to: url.path)   // carry labels/captions across a drive reconnect (new mount UUID)
        migrateInstagramPersonFolders()   // reshape before indexing so the index is current
        restorePersonFolderCovers()       // re-seed person-folder thumbnails lost to the first migration
        BackgroundDownloader.shared.activate()   // reconnect to the background session
        processPendingTikTok()            // file anything that finished while we were closed
        scheduleIndexBuild()
    }

    func restoreLastFolder() {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [],
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else {
            // The bookmark exists but won't resolve — the drive isn't plugged in
            // (yet). Don't drop the library; wait and retry (reconnectIfNeeded).
            waitingForDrive = true
            return
        }
        _ = url.startAccessingSecurityScopedResource()
        // Resolution can also succeed against a volume that isn't actually mounted;
        // treat an unreachable root the same as a failed resolve.
        guard FileManager.default.fileExists(atPath: url.path) else {
            url.stopAccessingSecurityScopedResource()
            waitingForDrive = true
            return
        }
        if stale, let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(fresh, forKey: bookmarkKey)   // refresh the bookmark after a remount
        }
        waitingForDrive = false
        activeRoot = url
        rootURL = url
        rootName = url.lastPathComponent
        DriveWriter.configureForVolume(at: url)   // tune write durability to the drive's filesystem
        rekeyRootIfRemounted(to: url.path)   // carry labels/captions across a drive reconnect (new mount UUID)
        migrateInstagramPersonFolders()   // reshape before indexing so the index is current
        restorePersonFolderCovers()       // re-seed person-folder thumbnails lost to the first migration
        BackgroundDownloader.shared.activate()   // reconnect to the background session
        processPendingTikTok()            // file anything that finished while we were closed
        scheduleIndexBuild()
    }

    /// Re-checks drive availability. Cheap when everything is fine, so it's safe to
    /// call on every foreground and from the waiting screen's retry loop. Covers:
    /// a failed launch restore (drive plugged in later), and a root that vanished
    /// mid-session because the drive was unplugged — including coming back under a
    /// **new** mount path, which the bookmark re-resolves to.
    func reconnectIfNeeded() {
        if rootURL == nil {
            if hasSavedBookmark { restoreLastFolder() }
            return
        }
        guard let root = rootURL else { return }
        if FileManager.default.fileExists(atPath: root.path) {
            waitingForDrive = false
            return
        }
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { waitingForDrive = true; return }
        var stale = false
        guard let fresh = try? URL(resolvingBookmarkData: data, options: [],
                                   relativeTo: nil, bookmarkDataIsStale: &stale),
              fresh.path != root.path,
              FileManager.default.fileExists(atPath: fresh.path) else {
            waitingForDrive = true          // still gone — keep the session, keep retrying
            return
        }
        // The drive is back under a new mount path: swap the root over, re-key all
        // path-keyed metadata, and drop the (now dead-pathed) navigation stack.
        root.stopAccessingSecurityScopedResource()
        _ = fresh.startAccessingSecurityScopedResource()
        if stale, let d = try? fresh.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(d, forKey: bookmarkKey)
        }
        waitingForDrive = false
        activeRoot = fresh
        rootURL = fresh
        rootName = fresh.lastPathComponent
        DriveWriter.configureForVolume(at: fresh)   // tune write durability to the drive's filesystem
        path = []
        rekeyRootIfRemounted(to: fresh.path)
        processPendingTikTok()
        scheduleIndexBuild()
        contentDidChange()
    }

    /// When an external drive is replugged it remounts under a new `…/userfsd/<UUID>/…` path, so
    /// every absolute-path key (Favorites, To AI, captions, folder covers, Instagram/TikTok records,
    /// birthdays, likes, …) would silently orphan. Detect a remount of the *same* drive folder —
    /// identical drive-relative path, different mount UUID — and re-key all of that data from the
    /// old root prefix to the new one, once. A genuinely different folder is left untouched.
    func rekeyRootIfRemounted(to newRoot: String) {
        let key = "photoBrowser.lastRootPath"
        let oldRoot = UserDefaults.standard.string(forKey: key)
        UserDefaults.standard.set(newRoot, forKey: key)
        guard let oldRoot, oldRoot != newRoot,
              URL(fileURLWithPath: oldRoot).stableCacheID == URL(fileURLWithPath: newRoot).stableCacheID
        else { return }
        applyRemap { p in (p == oldRoot || p.hasPrefix(oldRoot + "/")) ? newRoot + p.dropFirst(oldRoot.count) : p }
    }

    func goHome() { path.removeAll() }

    /// Reads capture dates (EXIF/creation) for the given files, bounded to a few
    /// concurrent reads so big folders don't stall.
    nonisolated func captureDates(for entries: [Entry]) async -> [URL: Date] {
        let files = entries.filter { !$0.isFolder }
        guard !files.isEmpty else { return [:] }
        var result: [URL: Date] = [:]
        var index = 0
        let maxConcurrent = 12
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
        MetadataLoader.scheduleDateStoreFlush()    // persist any newly-read dates (debounced)
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
        MetadataLoader.flushSpecStore()    // persist any newly-read specs
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

    /// Just the immediate **subfolders** of `folder`, A–Z — for the Move/Copy/Cover pickers.
    /// Reuses an already-loaded full listing when we have one; otherwise it enumerates with the
    /// directory flag prefetched and *skips statting files entirely* (size/date/type), which is
    /// the slow part on an external drive — so the picker shows folder names near-instantly.
    func subfolders(of folder: URL) async -> [Entry] {
        if let cached = cachedListing(of: folder) { return cached.filter(\.isFolder) }
        return await Self.scanSubfolders(of: folder)
    }

    nonisolated static func scanSubfolders(of folder: URL) async -> [Entry] {
        await Task.detached(priority: .userInitiated) {
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
            return urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
                .map { Entry(url: $0, name: $0.lastPathComponent, kind: .folder, size: 0, modified: .distantPast) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }.value
    }

    nonisolated func listing(of folder: URL, sort: SortKey) async -> [Entry] {
        // Enumerate names only (fast), then read each file's size/date/type concurrently.
        // On a slow external/file-provider drive each stat blocks, so overlapping them is
        // the difference between a folder opening instantly and taking 5–30s; on a local
        // SSD it's neutral. The directory read itself stays on a detached task.
        let urls: [URL] = await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let all = (try? fm.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
            // The Files / exFAT file-provider often ignores `.skipsHiddenFiles`, so dot-files leak
            // into the grid: our own `.pbtmp_*` transients, and macOS's `.sb-*` atomic-write temps.
            // Hide every dot-file — and sweep away STALE `.sb-*` orphans (a brown-out interrupted the
            // download's atomic write, so the temp never got renamed to the real photo). Only delete
            // ones older than 2 minutes so an in-flight write is never yanked out from under itself.
            var visible: [URL] = []
            for u in all {
                let name = u.lastPathComponent
                if name.hasPrefix(".") {
                    if (name.hasPrefix(".sb-") || name.hasPrefix(".pbtmp_")),
                       let mod = try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                       Date().timeIntervalSince(mod) > 120 {
                        try? fm.removeItem(at: u)
                    }
                    continue
                }
                visible.append(u)
            }
            return visible
        }.value
        guard !urls.isEmpty else { return [] }

        var slots = [Entry?](repeating: nil, count: urls.count)
        await withTaskGroup(of: (Int, Entry).self) { group in
            var index = 0
            let maxConcurrent = 32
            func addNext() {
                guard index < urls.count else { return }
                let i = index; let url = urls[i]; index += 1
                group.addTask {
                    let rv = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
                    var isDirectory = rv?.isDirectory ?? false
                    if rv?.isDirectory == nil {
                        // A stat that transiently fails on a busy external drive must not
                        // turn a folder into an extension-less "data" file tile — re-check
                        // the cheap way before classifying.
                        var d: ObjCBool = false
                        if FileManager.default.fileExists(atPath: url.path, isDirectory: &d) { isDirectory = d.boolValue }
                    }
                    return (i, Entry(url: url,
                                     name: url.lastPathComponent,
                                     kind: classify(url: url, isDirectory: isDirectory),
                                     size: Int64(rv?.fileSize ?? 0),
                                     modified: rv?.contentModificationDate ?? .distantPast))
                }
            }
            for _ in 0..<min(maxConcurrent, urls.count) { addNext() }
            while let (i, e) = await group.next() { slots[i] = e; addNext() }
        }
        return Self.sortEntries(slots.compactMap { $0 }, by: sort)
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
            case .smart, .kind, .ageAsc, .ageDesc, .likesDesc, .durationDesc, .durationAsc:
                return nameAsc(a, b)   // handled above / in the view
            }
        }
    }
}
