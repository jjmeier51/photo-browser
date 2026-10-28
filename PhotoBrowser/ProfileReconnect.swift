import Foundation

/// "Reconnect Profile Folders" (Drive Health ▸ Metadata safety): re-attaches Instagram and
/// TikTok profile records to download folders that are still on the drive but are no longer
/// registered — so they lost their bubble, their "@handle" subtitle, "Get New Posts / Videos"
/// and the stories sweep. The records go missing when metadata is pruned while the folders
/// couldn't be read (a "Forget All Missing Entries" taken while their lists sat past the 2.2 TB
/// line — CLAUDE.md #12 — prunes `instagramFolders` / `tiktokFolders` along with everything
/// else), or after a reinstall that restored only part of a backup. The files themselves are
/// never touched.
///
/// Two sources, newest first:
/// 1. **Backups** — the drive's `.Photo Browser Metadata` folder and the phone's last snapshots.
///    A record there whose folder exists on the drive today is merged back exactly as it was
///    (user id, downloaded ids, counts, highlight bubbles, like counts, posted-by, handle
///    prefills, covers) through the same `restoreMetadata` merge Restore uses — but trimmed to the
///    profile stores of those folders only, so nothing else in an old backup is resurrected.
/// 2. **The folders themselves** — for a folder no backup knows, the record is rebuilt from what
///    the downloaders left behind: TikTok files are `<post id>.mp4` / `<post id>_<n>.jpg` inside an
///    `@handle` folder; Instagram files are `<shortcode>` / `<story id>` (`_<n>` for carousels) in a
///    folder named after the handle, with its highlights as subfolders (and "posted by" entries, the
///    remembered handle on the parent, or a highlight already marked inside it as further evidence).
///    The rebuilt record carries the ids on disk, so "Get New" dedups against them and backfills the
///    rest; `lastUpdated` is the newest file's date. The Instagram user id / TikTok author id are
///    left blank and resolved by the next run.
///
/// Both passes run off the main actor (backup reads, a bounded coordinated walk of the drive);
/// only the merge touches `Library` state.
extension Library {
    nonisolated struct ProfileReconnectReport: Sendable {
        var instagramFromBackup = 0, tiktokFromBackup = 0
        var instagramRebuilt = 0, tiktokRebuilt = 0
        var highlights = 0
        var handles: [String] = []
        var walkCutShort = false                       // the drive walk hit its folder bound
        var total: Int { instagramFromBackup + tiktokFromBackup + instagramRebuilt + tiktokRebuilt }

        var summary: String {
            guard total > 0 else {
                return "Every Instagram and TikTok download folder on the drive is already linked to its profile."
                    + (walkCutShort ? " (The drive is very large; folders deeper than the walk reached weren't checked.)" : "")
            }
            func n(_ c: Int, _ word: String) -> String { "\(c) \(word)\(c == 1 ? "" : "s")" }
            let ig = instagramFromBackup + instagramRebuilt, tt = tiktokFromBackup + tiktokRebuilt
            var parts: [String] = []
            if ig > 0 { parts.append(n(ig, "Instagram profile")) }
            if tt > 0 { parts.append(n(tt, "TikTok profile")) }
            var s = "Reconnected " + parts.joined(separator: " and ") + "."
            let fromBackup = instagramFromBackup + tiktokFromBackup, rebuilt = instagramRebuilt + tiktokRebuilt
            if fromBackup > 0 && rebuilt > 0 {
                s += " \(fromBackup) came back from a metadata backup; \(rebuilt) were rebuilt from the folders themselves."
            } else if rebuilt > 0 {
                s += " They were rebuilt from the folders themselves — run “Get New” on each to refresh its profile photo and counts."
            } else {
                s += " They came back from a metadata backup."
            }
            if highlights > 0 { s += " \(n(highlights, "highlight bubble")) restored." }
            if !handles.isEmpty {
                let shown = handles.prefix(12).map { "@\($0)" }.joined(separator: ", ")
                s += "\n\n" + shown + (handles.count > 12 ? ", and \(handles.count - 12) more." : ".")
            }
            if walkCutShort { s += "\n\nThe drive is very large; folders deeper than the walk reached weren't checked." }
            return s
        }
    }

    /// Reconnects every Instagram / TikTok download folder on the drive that has lost its profile
    /// record (see the file comment). Never overwrites a record that exists.
    func reconnectProfileFolders() async -> ProfileReconnectReport {
        guard let root = rootURL else { return ProfileReconnectReport() }
        var report = ProfileReconnectReport()

        // MARK: 1. Backups — newest first, trimmed to the profile stores of folders on the drive.
        let knownBefore = Set(instagramFolders.keys).union(tiktokFolders.keys)
        let rootPath = root.path
        let trimmed: [(dir: URL, snapshot: MetadataSnapshot)] = await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            var dirs: [(URL, Date)] = []
            let driveDir = MetadataBackup.driveBackupDirectory(root: root)
            if fm.fileExists(atPath: driveDir.appendingPathComponent(MetadataBackup.jsonName).path) {
                dirs.append((driveDir, MetadataBackup.date(of: driveDir) ?? .distantPast))
            }
            for d in MetadataBackup.containerBackups() { dirs.append((d, MetadataBackup.date(of: d) ?? .distantPast)) }
            dirs.sort { $0.1 > $1.1 }
            var claimed = knownBefore                   // a folder is taken from the newest backup that has it
            var out: [(dir: URL, snapshot: MetadataSnapshot)] = []
            for (dir, _) in dirs {
                guard let s = MetadataBackup.read(from: dir) else { continue }
                if let t = Self.profileSlice(of: s, rootPath: rootPath, claimed: &claimed) { out.append((dir, t)) }
            }
            return out
        }.value
        for (dir, slice) in trimmed {
            let ig = instagramFolders.count, tt = tiktokFolders.count, hl = instagramHighlights.count
            _ = restoreMetadata(slice, root: root, imagesAt: dir)
            report.instagramFromBackup += instagramFolders.count - ig
            report.tiktokFromBackup += tiktokFolders.count - tt
            report.highlights += instagramHighlights.count - hl
            report.handles += slice.instagramFolders.values.map(\.handle) + slice.tiktokFolders.values.map(\.handle)
        }

        // MARK: 2. The folders themselves — anything still unregistered.
        let input = ProfileScanInput(
            root: root,
            known: Set(instagramFolders.keys).union(tiktokFolders.keys).union(facebookFolders.keys)
                .union(ofFolders.keys).union(vscoFolders.keys).union(instagramHighlights),
            highlights: instagramHighlights,
            postedBy: igPostedBy, igLastHandle: igLastHandle, tiktokLastHandle: lastTikTokHandleByFolder)
        let found = await Task.detached(priority: .userInitiated) { Self.scanProfileFolders(input) }.value
        report.walkCutShort = found.cutShort
        for c in found.instagram where instagramFolders[c.path] == nil {
            let folder = URL(fileURLWithPath: c.path, isDirectory: true)
            setInstagramInfo(IGFolderInfo(handle: c.handle, userID: "", lastUpdated: c.newest,
                                          downloaded: c.ids, photos: c.photos, videos: c.videos), for: folder)
            for h in c.highlights where !instagramHighlights.contains(h) {
                markInstagramHighlight(URL(fileURLWithPath: h, isDirectory: true))
                report.highlights += 1
            }
            let parent = folder.deletingLastPathComponent()
            if parent.path != rootPath, igLastHandle[parent.path] == nil { setLastIGHandle(c.handle, for: parent) }
            report.instagramRebuilt += 1
            report.handles.append(c.handle)
        }
        for c in found.tiktok where tiktokFolders[c.path] == nil {
            let folder = URL(fileURLWithPath: c.path, isDirectory: true)
            setTikTokInfo(TTFolderInfo(handle: c.handle, secUid: "", lastUpdated: c.newest,
                                       downloaded: c.ids, videos: c.ids.count, newestDate: nil, profileVideoCount: nil),
                          for: folder)
            let parent = folder.deletingLastPathComponent()
            if parent.path != rootPath, lastTikTokHandleByFolder[parent.path] == nil { setLastTikTokHandle(c.handle, for: parent) }
            report.tiktokRebuilt += 1
            report.handles.append(c.handle)
        }

        if report.total > 0 || report.highlights > 0 {
            labelsVersion += 1
            contentDidChange()
        }
        return report
    }

    // MARK: - Backup slice

    /// The part of a backup worth merging for this job: the Instagram / TikTok records whose folder is
    /// on the drive and not yet claimed, plus what belongs to those folders (highlights, posted-by,
    /// like counts, handle prefills on the parent, covers of the folder and its highlights). nil when
    /// the backup has nothing to add. Marks the folders it takes in `claimed`.
    nonisolated private static func profileSlice(of s: MetadataSnapshot, rootPath: String,
                                                 claimed: inout Set<String>) -> MetadataSnapshot? {
        let fm = FileManager.default
        func abs(_ r: String) -> String { r.isEmpty ? rootPath : rootPath + "/" + r }
        func isDir(_ p: String) -> Bool {
            var d: ObjCBool = false
            return fm.fileExists(atPath: p, isDirectory: &d) && d.boolValue
        }
        var t = MetadataSnapshot(createdAt: s.createdAt, rootName: s.rootName)
        var folders: [String] = []                          // relative paths taken from this backup
        for (rel, info) in s.instagramFolders {
            let p = abs(rel)
            guard !claimed.contains(p), isDir(p) else { continue }
            t.instagramFolders[rel] = info; folders.append(rel); claimed.insert(p)
        }
        for (rel, info) in s.tiktokFolders {
            let p = abs(rel)
            guard !claimed.contains(p), isDir(p) else { continue }
            t.tiktokFolders[rel] = info; folders.append(rel); claimed.insert(p)
        }
        guard !folders.isEmpty else { return nil }
        func inside(_ rel: String) -> Bool { folders.contains { rel.hasPrefix($0 + "/") } }
        func parentRel(_ rel: String) -> String { rel.contains("/") ? String(rel[..<rel.lastIndex(of: "/")!]) : "" }
        let parents = Set(folders.map(parentRel))
        t.instagramHighlights = s.instagramHighlights.filter { inside($0) && isDir(abs($0)) }
        t.igPostedBy = s.igPostedBy.filter { inside($0.key) && fm.fileExists(atPath: abs($0.key)) }
        t.tiktokLikes = s.tiktokLikes.filter { inside($0.key) && fm.fileExists(atPath: abs($0.key)) }
        t.igLastHandle = s.igLastHandle.filter { parents.contains($0.key) && !$0.key.isEmpty }
        t.lastTikTokHandleByFolder = s.lastTikTokHandleByFolder.filter { parents.contains($0.key) && !$0.key.isEmpty }
        let coverFolders = Set(folders).union(t.instagramHighlights)
        t.folderCovers = s.folderCovers.filter { coverFolders.contains($0.key) }
        t.bubbleOrders = s.bubbleOrders.filter { folders.contains($0.key) }
        return t
    }

    // MARK: - Drive walk

    nonisolated struct ProfileScanInput: Sendable {
        let root: URL
        let known: Set<String>                      // registered profile / highlight folders: never re-classified or entered
        let highlights: Set<String>                 // Instagram highlight folders already marked
        let postedBy: [String: String]              // file path → posting handle (Instagram)
        let igLastHandle: [String: String]          // parent folder → handle last downloaded into it
        let tiktokLastHandle: [String: String]
    }
    nonisolated struct InstagramCandidate: Sendable {
        let path: String, handle: String
        let ids: [String], photos: Int, videos: Int, newest: Double
        let highlights: [String]
    }
    nonisolated struct TikTokCandidate: Sendable {
        let path: String, handle: String
        let ids: [String], newest: Double
    }
    nonisolated struct ProfileScanResult: Sendable {
        var instagram: [InstagramCandidate] = []
        var tiktok: [TikTokCandidate] = []
        var cutShort = false
    }

    nonisolated private static let scanMaxDepth = 8
    nonisolated private static let scanMaxFolders = 60_000

    /// Breadth-first over the drive (hidden folders skipped by the reader, so `.Trash`, the spare pool
    /// and the metadata backup never appear). A folder that classifies as a profile is recorded and
    /// not entered — its subfolders are highlights, not profiles.
    nonisolated static func scanProfileFolders(_ input: ProfileScanInput) -> ProfileScanResult {
        var result = ProfileScanResult()
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        var queue: [(URL, Int)] = [(input.root, 0)]
        var next = 0, visited = 0
        while next < queue.count {
            if Task.isCancelled { break }
            if visited >= scanMaxFolders { result.cutShort = true; break }
            let (dir, depth) = queue[next]; next += 1
            visited += 1
            let children = coordinatedContents(of: dir, keys: keys)
            var files: [(URL, Date)] = [], dirs: [URL] = []
            for c in children {
                let v = try? c.resourceValues(forKeys: Set(keys))
                if v?.isDirectory == true { dirs.append(c) } else { files.append((c, v?.contentModificationDate ?? .distantPast)) }
            }
            if depth > 0 {
                if let tt = classifyTikTok(dir, files: files, input: input) { result.tiktok.append(tt); continue }
                if let ig = classifyInstagram(dir, files: files, dirs: dirs, input: input) { result.instagram.append(ig); continue }
            }
            guard depth < scanMaxDepth else { continue }
            for d in dirs where !input.known.contains(d.path) { queue.append((d, depth + 1)) }
        }
        return result
    }

    nonisolated private static func classifyTikTok(_ dir: URL, files: [(URL, Date)], input: ProfileScanInput) -> TikTokCandidate? {
        let name = dir.lastPathComponent
        guard name.hasPrefix("@"), name.count > 1 else { return nil }
        let handle = String(name.dropFirst())
        var ids: [String] = [], seen = Set<String>(), newest = Date.distantPast
        for (f, date) in files {
            guard let p = postID(of: f.lastPathComponent), isTikTokID(p.id) else { continue }
            if seen.insert(p.id).inserted { ids.append(p.id) }
            if date > newest { newest = date }
        }
        let remembered = input.tiktokLastHandle[dir.deletingLastPathComponent().path]?.caseInsensitiveCompare(handle) == .orderedSame
        guard !ids.isEmpty || remembered else { return nil }
        return TikTokCandidate(path: dir.path, handle: handle, ids: ids,
                               newest: ids.isEmpty ? Date().timeIntervalSince1970 : newest.timeIntervalSince1970)
    }

    nonisolated private static func classifyInstagram(_ dir: URL, files: [(URL, Date)], dirs: [URL],
                                                      input: ProfileScanInput) -> InstagramCandidate? {
        let name = dir.lastPathComponent
        guard !name.hasPrefix("@") else { return nil }
        // Evidence, strongest first: files recorded as posted by someone; the handle remembered on the
        // parent; a highlight already marked inside; or a handle-shaped name over Instagram-named files.
        var posters: [String: Int] = [:]
        for (f, _) in files { if let h = input.postedBy[f.path] { posters[h, default: 0] += 1 } }
        let parentPath = dir.deletingLastPathComponent().path
        let remembered = input.igLastHandle[parentPath]?.caseInsensitiveCompare(name) == .orderedSame
        let markedHighlight = dirs.contains { input.highlights.contains($0.path) }
        var media = 0, igNamed = 0
        for (f, _) in files {
            guard let p = postID(of: f.lastPathComponent) else { continue }
            media += 1
            if isInstagramID(p.id) { igNamed += 1 }
        }
        let namedLikeIG = isHandleLike(name) && igNamed >= 3 && igNamed * 5 >= media * 4
        guard !posters.isEmpty || remembered || markedHighlight || namedLikeIG else { return nil }

        let handle: String
        if isHandleLike(name) { handle = name }
        else if let top = posters.max(by: { $0.value < $1.value })?.key { handle = top }
        else { return nil }

        var ids: [String] = [], seen = Set<String>(), photos = 0, videos = 0, newest = Date.distantPast
        func take(_ list: [(URL, Date)]) {
            for (f, date) in list {
                guard let p = postID(of: f.lastPathComponent) else { continue }
                if p.isVideo { videos += 1 } else { photos += 1 }
                if seen.insert(p.id).inserted { ids.append(p.id) }
                if date > newest { newest = date }
            }
        }
        take(files)
        var highlights: [String] = []
        for d in dirs where !input.known.contains(d.path) && !d.lastPathComponent.hasPrefix("@") {
            highlights.append(d.path)
            let inner = coordinatedContents(of: d, keys: [.isDirectoryKey, .contentModificationDateKey])
            take(inner.compactMap { u -> (URL, Date)? in
                let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
                return v?.isDirectory == true ? nil : (u, v?.contentModificationDate ?? .distantPast)
            })
        }
        return InstagramCandidate(path: dir.path, handle: handle, ids: ids, photos: photos, videos: videos,
                                  newest: (newest == .distantPast ? Date() : newest).timeIntervalSince1970,
                                  highlights: highlights)
    }

    // MARK: - What a profile folder already holds

    /// The post ids a profile folder already holds on disk — named the way the downloaders name their
    /// files — in the folder and its subfolders (highlights, "Stories", folders the user sorted things
    /// into, a DUPLICATES set-aside), three levels down, hidden folders skipped. "Get New" skips these as
    /// well as the ids in the folder's record: a record restored from an older backup (or rebuilt, or
    /// missing ids for any other reason) must never make it download what's already there. Both forms of
    /// a `<stem>_<n>` name are returned (a carousel item, or an Instagram shortcode that itself ends in
    /// `_<digits>`). Blocking — call off the main actor.
    nonisolated static func postIDsOnDisk(in folder: URL, tiktok: Bool) -> Set<String> {
        var ids = Set<String>()
        let keys: [URLResourceKey] = [.isDirectoryKey]
        var queue: [(URL, Int)] = [(folder, 0)]
        var next = 0
        while next < queue.count, next < 2_000 {
            let (dir, depth) = queue[next]; next += 1
            for c in coordinatedContents(of: dir, keys: keys) {
                let name = c.lastPathComponent
                guard !name.hasPrefix(".") else { continue }
                if (try? c.resourceValues(forKeys: Set(keys)))?.isDirectory == true {
                    if depth < 3, !name.hasPrefix("@") { queue.append((c, depth + 1)) }   // another profile's folder isn't ours
                    continue
                }
                guard let p = postID(of: name) else { continue }
                let whole = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
                if tiktok {
                    if isTikTokID(p.id) { ids.insert(p.id) }
                } else {
                    ids.insert(p.id)
                    ids.insert(whole)
                }
            }
        }
        return ids
    }

    // MARK: - File-name shapes the downloaders leave behind

    nonisolated private static let mediaExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "heic", "mp4", "mov", "m4v", "webm"]
    nonisolated private static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "webm"]

    /// `<id>.<ext>` or `<id>_<n>.<ext>` (a carousel / slideshow item) → the post id, for media files.
    nonisolated private static func postID(of fileName: String) -> (id: String, isVideo: Bool)? {
        let url = URL(fileURLWithPath: fileName)
        let ext = url.pathExtension.lowercased()
        guard mediaExtensions.contains(ext) else { return nil }
        var stem = url.deletingPathExtension().lastPathComponent
        if let us = stem.lastIndex(of: "_"), us != stem.startIndex {
            let suffix = stem[stem.index(after: us)...]
            if !suffix.isEmpty, suffix.allSatisfy({ $0.isASCII && $0.isNumber }) { stem = String(stem[..<us]) }
        }
        guard !stem.isEmpty else { return nil }
        return (stem, videoExtensions.contains(ext))
    }
    /// TikTok post ids: 15–20 decimal digits.
    nonisolated private static func isTikTokID(_ s: String) -> Bool {
        (15...20).contains(s.count) && s.allSatisfy { $0.isASCII && $0.isNumber }
    }
    /// Instagram: an 11-ish character post shortcode (`A–Z a–z 0–9 - _`) or a story / highlight pk.
    nonisolated private static func isInstagramID(_ s: String) -> Bool {
        if (15...22).contains(s.count), s.allSatisfy({ $0.isASCII && $0.isNumber }) { return true }
        guard (10...12).contains(s.count) else { return false }
        return s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }
    /// An Instagram handle: up to 30 of `A–Z a–z 0–9 . _`.
    nonisolated private static func isHandleLike(_ s: String) -> Bool {
        (1...30).contains(s.count) && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_") }
    }
}
