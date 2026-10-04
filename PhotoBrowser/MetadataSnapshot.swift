import Foundation

/// A drive's app metadata in portable form — **every** path-keyed store (Favorites, To AI, custom
/// labels, captions, covers, custom thumbnails, Photos origins, birthdays, hidden items, frames /
/// reviews / highlight folders, bubble order, Instagram / Facebook / TikTok / VSCO / OF profile
/// records and prefills, likes, story links, Messages archives, AI provenance, Clean Up progress,
/// Not-Duplicates pairs, People, Access Kardashian state) with keys **relative to the drive
/// folder**. Relative keys are what make it a real backup: the same drive re-copied, reformatted,
/// renamed, or opened after a reinstall mounts under a different absolute path, and an absolute
/// key would never match again.
///
/// Written by `MetadataBackup` as `metadata.json` next to copies of the cover / thumbnail /
/// archive image files it references, both into the app container and (on request) into a hidden
/// folder on the drive itself, so the backup travels with the photos. Restoring **merges**: it adds
/// what's missing under the current root and never overwrites a value that already exists.
struct MetadataSnapshot: Codable, Sendable {
    var version = 1
    var createdAt: Double
    var rootName: String

    var favorites: [String] = []
    var aiLabels: [String] = []
    var customLabels: [String: [String]] = [:]
    var captions: [String: String] = [:]
    var folderCovers: [String: String] = [:]          // relative folder → cover filename (in covers/)
    var itemThumbnails: [String: String] = [:]        // relative file → thumbnail filename (in itemThumbs/)
    var photoOrigins: [String: String] = [:]
    var folderBirthdays: [String: Double] = [:]
    var hiddenFolders: [String] = []
    var hiddenFiles: [String] = []
    var framesFolders: [String] = []
    var kardashianFolders: [String] = []
    var instagramHighlights: [String] = []
    var albumHighlights: [String] = []
    var reviewsFolders: [String] = []
    var bubbleOrders: [String: [String]] = [:]
    var igPostedBy: [String: String] = [:]
    var igLastHandle: [String: String] = [:]
    var storyLinks: [String: String] = [:]
    var instagramFolders: [String: IGFolderInfo] = [:]
    var facebookFolders: [String: FBFolderInfo] = [:]
    var tiktokFolders: [String: TTFolderInfo] = [:]
    var tiktokLikes: [String: Int] = [:]
    var lastTikTokHandleByFolder: [String: String] = [:]
    var vscoFolders: [String: VSCOFolderInfo] = [:]
    var lastVSCOUsernameByFolder: [String: String] = [:]
    var ofFolders: [String: OFFolderInfo] = [:]
    var lastOFUsernameByFolder: [String: String] = [:]
    var lastFacebookURLByFolder: [String: String] = [:]
    var textMessageArchives: [String: String] = [:]   // relative folder → archive filename (in messages/)
    var aiGeneratedPaths: [String] = []
    var aiGenerations: [String: Library.AIGenInfo] = [:]
    var editedInAppPaths: [String] = []
    var cleanupReviewed: [String: [String]] = [:]
    var notDuplicatePairs: [[String]] = []
    var people: [String: [String]] = [:]              // name → face ids ("relative path#index")
    var accessKardashian: [String: Library.AKMember] = [:]   // folderPath relative

    /// How many entries the snapshot holds, for the UI.
    var entryCount: Int {
        favorites.count + aiLabels.count + customLabels.values.reduce(0) { $0 + $1.count } + captions.count
            + folderCovers.count + itemThumbnails.count + photoOrigins.count + folderBirthdays.count
            + hiddenFolders.count + hiddenFiles.count + framesFolders.count + kardashianFolders.count
            + instagramHighlights.count + albumHighlights.count + reviewsFolders.count + bubbleOrders.count
            + igPostedBy.count + igLastHandle.count + storyLinks.count + instagramFolders.count
            + facebookFolders.count + tiktokFolders.count + tiktokLikes.count + lastTikTokHandleByFolder.count
            + vscoFolders.count + lastVSCOUsernameByFolder.count + ofFolders.count + lastOFUsernameByFolder.count
            + lastFacebookURLByFolder.count + textMessageArchives.count + aiGeneratedPaths.count
            + aiGenerations.count + editedInAppPaths.count + cleanupReviewed.count + notDuplicatePairs.count
            + people.values.reduce(0) { $0 + $1.count } + accessKardashian.count
    }
}

/// A kind of path-keyed metadata, for Drive Health's "pointing at missing items" breakdown.
enum MetadataCategory: Int, CaseIterable, Identifiable, Sendable {
    case favorites, toAI, labels, captions, covers, itemThumbnails, birthdays, hidden, profiles, folderRoles, people, aiProvenance, other
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .favorites:      return "Favorites"
        case .toAI:           return "To AI"
        case .labels:         return "Custom labels"
        case .captions:       return "Captions"
        case .covers:         return "Folder covers"
        case .itemThumbnails: return "Custom thumbnails"
        case .birthdays:      return "Birthdays"
        case .hidden:         return "Hidden items"
        case .profiles:       return "Linked social profiles"
        case .folderRoles:    return "Highlights, frames & review folders"
        case .people:         return "People (faces)"
        case .aiProvenance:   return "AI & edit provenance"
        case .other:          return "Story links, likes, Messages archives"
        }
    }
}

extension Library {
    /// Every path-keyed entry under `root`, keyed drive-relative. Entries on other drives are left
    /// out — they belong to those drives' own backups.
    func makeMetadataSnapshot(root: URL) -> MetadataSnapshot {
        let base = root.path
        let prefix = base + "/"
        func rel(_ p: String) -> String? {
            if p == base { return "" }
            return p.hasPrefix(prefix) ? String(p.dropFirst(prefix.count)) : nil
        }
        func relSet(_ s: Set<String>) -> [String] { s.compactMap(rel).sorted() }
        func relDict<V>(_ d: [String: V]) -> [String: V] {
            var out: [String: V] = [:]
            for (k, v) in d { if let r = rel(k) { out[r] = v } }
            return out
        }
        var s = MetadataSnapshot(createdAt: Date().timeIntervalSince1970, rootName: root.lastPathComponent)
        s.favorites = relSet(favorites)
        s.aiLabels = relSet(aiLabels)
        s.customLabels = customLabels.mapValues(relSet).filter { !$0.value.isEmpty }
        s.captions = relDict(captions)
        s.folderCovers = relDict(folderCovers)
        s.itemThumbnails = relDict(itemThumbnails)
        s.photoOrigins = relDict(photoOrigins)
        s.folderBirthdays = relDict(folderBirthdays)
        s.hiddenFolders = relSet(hiddenFolders)
        s.hiddenFiles = relSet(hiddenFiles)
        s.framesFolders = relSet(framesFolders)
        s.kardashianFolders = relSet(kardashianFolders)
        s.instagramHighlights = relSet(instagramHighlights)
        s.albumHighlights = relSet(albumHighlights)
        s.reviewsFolders = relSet(reviewsFolders)
        s.bubbleOrders = relDict(bubbleOrders).mapValues { $0.compactMap(rel) }
        s.igPostedBy = relDict(igPostedBy)
        s.igLastHandle = relDict(igLastHandle)
        s.storyLinks = relDict(storyLinks).compactMapValues(rel)
        s.instagramFolders = relDict(instagramFolders)
        s.facebookFolders = relDict(facebookFolders)
        s.tiktokFolders = relDict(tiktokFolders)
        s.tiktokLikes = relDict(tiktokLikes)
        s.lastTikTokHandleByFolder = relDict(lastTikTokHandleByFolder)
        s.vscoFolders = relDict(vscoFolders)
        s.lastVSCOUsernameByFolder = relDict(lastVSCOUsernameByFolder)
        s.ofFolders = relDict(ofFolders)
        s.lastOFUsernameByFolder = relDict(lastOFUsernameByFolder)
        s.lastFacebookURLByFolder = relDict(lastFacebookURLByFolder)
        s.textMessageArchives = relDict(textMessageArchives)
        s.aiGeneratedPaths = relSet(aiGeneratedPaths)
        s.aiGenerations = relDict(aiGenerations)
        s.editedInAppPaths = relSet(editedInAppPaths)
        s.cleanupReviewed = relDict(cleanupReviewed).mapValues { $0.compactMap(rel) }
        s.notDuplicatePairs = notDuplicatePairs.compactMap { key in
            guard let (a, b) = Library.notDuplicatePairPaths(key), let ra = rel(a), let rb = rel(b) else { return nil }
            return [ra, rb]
        }
        s.people = people.mapValues { ids in
            ids.compactMap { id -> String? in
                let path = Library.pathOfFaceID(id)
                guard let r = rel(path) else { return nil }
                return r + id.dropFirst(path.count)
            }.sorted()
        }.filter { !$0.value.isEmpty }
        for (name, member) in accessKardashian {
            guard let r = rel(member.folderPath) else { continue }
            var m = member; m.folderPath = r; s.accessKardashian[name] = m
        }
        return s
    }

    /// Merges a snapshot back under `root`: adds every entry that isn't already present and
    /// never overwrites an existing value. Cover / thumbnail / archive image files are copied in
    /// from `imagesAt` (the backup folder) when the app doesn't already have them. Returns the
    /// number of entries added. Persists everything once.
    @discardableResult
    func restoreMetadata(_ s: MetadataSnapshot, root: URL, imagesAt backup: URL?) -> Int {
        let base = root.path
        func abs(_ r: String) -> String { r.isEmpty ? base : base + "/" + r }
        var added = 0
        func addSet(_ set: inout Set<String>, _ rels: [String]) {
            for r in rels where set.insert(abs(r)).inserted { added += 1 }
        }
        func addDict<V>(_ dict: inout [String: V], _ rels: [String: V], value: (V) -> V = { $0 }) {
            for (r, v) in rels {
                let k = abs(r)
                if dict[k] == nil { dict[k] = value(v); added += 1 }
            }
        }
        addSet(&favorites, s.favorites)
        addSet(&aiLabels, s.aiLabels)
        for (name, rels) in s.customLabels {
            var set = customLabels[name] ?? []
            addSet(&set, rels)
            customLabels[name] = set
        }
        addDict(&captions, s.captions)
        addDict(&photoOrigins, s.photoOrigins)
        addDict(&folderBirthdays, s.folderBirthdays)
        addSet(&hiddenFolders, s.hiddenFolders)
        addSet(&hiddenFiles, s.hiddenFiles)
        addSet(&framesFolders, s.framesFolders)
        addSet(&kardashianFolders, s.kardashianFolders)
        addSet(&instagramHighlights, s.instagramHighlights)
        addSet(&albumHighlights, s.albumHighlights)
        addSet(&reviewsFolders, s.reviewsFolders)
        addDict(&bubbleOrders, s.bubbleOrders, value: { $0.map(abs) })
        addDict(&igPostedBy, s.igPostedBy)
        addDict(&igLastHandle, s.igLastHandle)
        addDict(&storyLinks, s.storyLinks, value: abs)
        addDict(&instagramFolders, s.instagramFolders)
        addDict(&facebookFolders, s.facebookFolders)
        addDict(&tiktokFolders, s.tiktokFolders)
        addDict(&tiktokLikes, s.tiktokLikes)
        addDict(&lastTikTokHandleByFolder, s.lastTikTokHandleByFolder)
        addDict(&vscoFolders, s.vscoFolders)
        addDict(&lastVSCOUsernameByFolder, s.lastVSCOUsernameByFolder)
        addDict(&ofFolders, s.ofFolders)
        addDict(&lastOFUsernameByFolder, s.lastOFUsernameByFolder)
        addDict(&lastFacebookURLByFolder, s.lastFacebookURLByFolder)
        addSet(&aiGeneratedPaths, s.aiGeneratedPaths)
        addDict(&aiGenerations, s.aiGenerations)
        addSet(&editedInAppPaths, s.editedInAppPaths)
        addDict(&cleanupReviewed, s.cleanupReviewed, value: { $0.map(abs) })
        for pair in s.notDuplicatePairs where pair.count == 2 {
            if notDuplicatePairs.insert(Library.notDuplicatePairKey(abs(pair[0]), abs(pair[1]))).inserted { added += 1 }
        }
        for (name, ids) in s.people {
            var set = people[name] ?? []
            for id in ids {
                let r = Library.pathOfFaceID(id)
                if set.insert(abs(r) + id.dropFirst(r.count)).inserted { added += 1 }
            }
            people[name] = set
        }
        for (name, member) in s.accessKardashian where accessKardashian[name] == nil {
            var m = member; m.folderPath = abs(member.folderPath); accessKardashian[name] = m; added += 1
        }
        // Image-backed stores: bring the file along (same UUID filename — no clash possible).
        let fm = FileManager.default
        func addImages(_ table: inout [String: String], _ rels: [String: String], from sub: String, into dir: URL) {
            for (r, filename) in rels {
                let k = abs(r)
                guard table[k] == nil else { continue }
                let dest = dir.appendingPathComponent(filename)
                if !fm.fileExists(atPath: dest.path) {
                    guard let backup else { continue }
                    let src = backup.appendingPathComponent(sub).appendingPathComponent(filename)
                    guard (try? fm.copyItem(at: src, to: dest)) != nil else { continue }
                }
                table[k] = filename; added += 1
            }
        }
        addImages(&folderCovers, s.folderCovers, from: MetadataBackup.coversSubfolder, into: coverImagesDirectory)
        addImages(&itemThumbnails, s.itemThumbnails, from: MetadataBackup.thumbsSubfolder, into: itemThumbnailImagesDirectory)
        addImages(&textMessageArchives, s.textMessageArchives, from: MetadataBackup.messagesSubfolder, into: textMessageArchivesDirectory)

        persistAllMetadataNow()
        return added
    }

    /// Every path the metadata refers to under `root`, by category — what Drive Health checks
    /// against the files that actually exist. People entries contribute the photo path of each face.
    func metadataPaths(under root: URL) -> [MetadataCategory: Set<String>] {
        let base = root.path, prefix = base + "/"
        func under(_ p: String) -> Bool { p == base || p.hasPrefix(prefix) }
        var out: [MetadataCategory: Set<String>] = [:]
        func add(_ c: MetadataCategory, _ paths: some Sequence<String>) {
            out[c, default: []].formUnion(paths.filter(under))
        }
        add(.favorites, favorites)
        add(.toAI, aiLabels)
        add(.labels, customLabels.values.flatMap { $0 })
        add(.captions, captions.keys)
        add(.covers, folderCovers.keys)
        add(.itemThumbnails, itemThumbnails.keys)
        add(.birthdays, folderBirthdays.keys)
        add(.hidden, hiddenFolders); add(.hidden, hiddenFiles)
        add(.profiles, instagramFolders.keys); add(.profiles, facebookFolders.keys); add(.profiles, tiktokFolders.keys)
        add(.profiles, vscoFolders.keys); add(.profiles, ofFolders.keys)
        add(.profiles, igLastHandle.keys); add(.profiles, lastTikTokHandleByFolder.keys)
        add(.profiles, lastVSCOUsernameByFolder.keys); add(.profiles, lastOFUsernameByFolder.keys)
        add(.profiles, lastFacebookURLByFolder.keys); add(.profiles, accessKardashian.values.map(\.folderPath))
        add(.folderRoles, instagramHighlights); add(.folderRoles, albumHighlights); add(.folderRoles, reviewsFolders)
        add(.folderRoles, framesFolders); add(.folderRoles, kardashianFolders); add(.folderRoles, bubbleOrders.keys)
        add(.people, people.values.flatMap { $0 }.map(Library.pathOfFaceID))
        add(.aiProvenance, aiGeneratedPaths); add(.aiProvenance, aiGenerations.keys); add(.aiProvenance, editedInAppPaths)
        add(.other, igPostedBy.keys); add(.other, storyLinks.keys); add(.other, tiktokLikes.keys); add(.other, textMessageArchives.keys)
        add(.other, photoOrigins.keys)
        return out
    }

    /// Writes a backup of this drive's metadata: always into the app container (the last few are
    /// kept), and when `toDrive` also into a hidden folder at the drive root, so it travels with
    /// the photos and survives a reinstall. The snapshot is taken on the main actor (fast — it's
    /// dictionary work); the file copies run detached.
    func backUpMetadata(toDrive: Bool) async -> (entries: Int, container: URL?, drive: URL?) {
        guard let root = rootURL else { return (0, nil, nil) }
        let snapshot = makeMetadataSnapshot(root: root)
        let covers = coverImagesDirectory, thumbs = itemThumbnailImagesDirectory, messages = textMessageArchivesDirectory
        return await Task.detached(priority: .userInitiated) { () -> (Int, URL?, URL?) in
            let containerDir = MetadataBackup.newContainerDirectory()
            let ok1 = MetadataBackup.write(snapshot, covers: covers, thumbs: thumbs, messages: messages, to: containerDir)
            MetadataBackup.pruneContainerBackups(keep: 3)
            var driveDir: URL?
            if toDrive {
                let d = MetadataBackup.driveBackupDirectory(root: root)
                if MetadataBackup.write(snapshot, covers: covers, thumbs: thumbs, messages: messages, to: d) { driveDir = d }
            }
            return (snapshot.entryCount, ok1 ? containerDir : nil, driveDir)
        }.value
    }

    /// Restores (merges) the backup folder at `dir` under the current root. nil when it can't be read.
    func restoreMetadata(fromBackupAt dir: URL) async -> Int? {
        guard let root = rootURL else { return nil }
        guard let snapshot = await Task.detached(priority: .userInitiated, operation: { MetadataBackup.read(from: dir) }).value else { return nil }
        return restoreMetadata(snapshot, root: root, imagesAt: dir)
    }
}

/// On-disk layout of a metadata backup: a folder holding `metadata.json` plus the cover /
/// thumbnail / Messages-archive files it references. Off the main actor only.
nonisolated enum MetadataBackup {
    static let driveFolderName = ".Photo Browser Metadata"      // dot-prefixed: hidden from every listing and scan
    static let jsonName = "metadata.json"
    static let coversSubfolder = "covers"
    static let thumbsSubfolder = "itemThumbs"
    static let messagesSubfolder = "messages"
    static let lastBackupKey = "photoBrowser.lastMetadataBackup"

    nonisolated static var containerRoot: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("metadataBackups", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    nonisolated static func newContainerDirectory() -> URL {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HHmmss"
        return containerRoot.appendingPathComponent(f.string(from: Date()), isDirectory: true)
    }
    nonisolated static func driveBackupDirectory(root: URL) -> URL {
        root.appendingPathComponent(driveFolderName, isDirectory: true)
    }

    /// The newest backup in the app container, if any.
    nonisolated static func latestContainerBackup() -> URL? {
        containerBackups().last
    }
    nonisolated static func containerBackups() -> [URL] {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: containerRoot, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return dirs.filter { fm.fileExists(atPath: $0.appendingPathComponent(jsonName).path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }      // names sort chronologically
    }
    nonisolated static func pruneContainerBackups(keep: Int) {
        let all = containerBackups()
        guard all.count > keep else { return }
        for old in all.prefix(all.count - keep) { try? FileManager.default.removeItem(at: old) }
    }

    /// Writes the snapshot and copies every referenced image/archive file. Returns false if the
    /// JSON itself couldn't be written (a missing cover file is tolerated).
    nonisolated static func write(_ s: MetadataSnapshot, covers: URL, thumbs: URL, messages: URL, to dir: URL) -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        guard let data = try? enc.encode(s),
              (try? data.write(to: dir.appendingPathComponent(jsonName), options: .atomic)) != nil else { return false }
        func copyAll(_ names: some Sequence<String>, from src: URL, sub: String) {
            let d = dir.appendingPathComponent(sub, isDirectory: true)
            try? fm.createDirectory(at: d, withIntermediateDirectories: true)
            for n in names {
                let to = d.appendingPathComponent(n)
                guard !fm.fileExists(atPath: to.path) else { continue }
                try? fm.copyItem(at: src.appendingPathComponent(n), to: to)
            }
        }
        copyAll(s.folderCovers.values, from: covers, sub: coversSubfolder)
        copyAll(s.itemThumbnails.values, from: thumbs, sub: thumbsSubfolder)
        copyAll(s.textMessageArchives.values, from: messages, sub: messagesSubfolder)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastBackupKey)
        return true
    }

    nonisolated static func read(from dir: URL) -> MetadataSnapshot? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(jsonName)) else { return nil }
        return try? JSONDecoder().decode(MetadataSnapshot.self, from: data)
    }

    /// The backup's own creation date, for the UI (falls back to the JSON's mtime).
    nonisolated static func date(of dir: URL) -> Date? {
        if let s = read(from: dir) { return Date(timeIntervalSince1970: s.createdAt) }
        return (try? dir.appendingPathComponent(jsonName).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}
