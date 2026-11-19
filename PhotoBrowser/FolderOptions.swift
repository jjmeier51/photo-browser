import Foundation

/// Per-folder choices shared with Photo Browser for Mac: **Videos at the Top** (a folder's videos listed
/// before its photos; folders and highlights still first), **album highlight** (the folder shown as a
/// bubble in its parent — `Library.albumHighlights`) and **Reviews folder** (`Library.reviewsFolders`).
/// The Mac shows the same bubbles (`mac/highlights.py`), so a highlight made on either is one on both.
///
/// The choice is kept by folder path in `Library.videosFirst` (a `FilePrefs` dictionary:
/// path → stamp), and — for the drive that's open — in
/// `<drive>/.Photo Browser Metadata/folder-options.json`
/// (`{"videos_first": {"<folder, drive-relative>": stamp}, "highlight": {…}, "reviews": {…}}`), which Photo Browser for Mac reads and writes
/// too (`mac/folder_options.py`). So a folder set to "Videos at the Top" on the Mac is shown that
/// way here, and the other way round.
///
/// A stamp is when the choice was last made (Unix time): **positive = on, negative = off**.
/// Merging takes, for each folder, whichever stamp is later — so "off" on one side isn't undone
/// by the other's older "on", and neither side needs to remember what the file said before.
///
/// The file is read and written off the main actor (`Library.syncFolderOptions`, run with the tag
/// sync: drive opened or back, foreground, and a moment after a change). A rename or move re-keys
/// `videosFirst` with everything else (`applyRemap`).
nonisolated enum FolderOptions {
    static let fileName = "folder-options.json"
    static let format = "photobrowser-folder-options"
    static let prefsKey = "photoBrowser.videosFirst"

    static func file(root: URL) -> URL {
        MetadataBackup.driveBackupDirectory(root: root).appendingPathComponent(fileName)
    }

    /// The choices kept in the file, by their key there.
    static let options = ["videos_first", "highlight", "reviews"]
    static let highlightStampsKey = "photoBrowser.albumHighlightStamps"
    static let reviewsStampsKey = "photoBrowser.reviewsStamps"

    /// What the drive's file says, by choice: folder (drive-relative, "" = the drive itself) → stamp.
    static func readAll(root: URL) -> [String: [String: Double]] {
        var out: [String: [String: Double]] = [:]
        for option in options { out[option] = [:] }
        guard let data = try? Data(contentsOf: file(root: root)),
              let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              doc["format"] as? String == format else { return out }
        for option in options {
            guard let raw = doc[option] as? [String: Any] else { continue }
            var entries: [String: Double] = [:]
            for (folder, value) in raw {
                if let n = value as? NSNumber { entries[folder.precomposedStringWithCanonicalMapping] = n.doubleValue }
            }
            out[option] = entries
        }
        return out
    }

    /// Best-effort: a drive that's gone or read-only just keeps the file it had. Whatever else the file
    /// holds (a key a later version of either app added) is kept.
    static func writeAll(_ all: [String: [String: Double]], root: URL) {
        let dest = file(root: root)
        var doc: [String: Any] = [:]
        if let data = try? Data(contentsOf: dest),
           let old = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           old["format"] as? String == format {
            doc = old
        }
        doc["format"] = format
        doc["version"] = 1
        doc["by"] = "Photo Browser"
        doc["updated"] = Date().timeIntervalSince1970
        for option in options {
            let entries = all[option] ?? [:]
            if !entries.isEmpty || option == "videos_first" { doc[option] = entries }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: doc, options: [.sortedKeys]) else { return }
        let dir = dest.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) { try? DriveWriter.createDirectory(at: dir) }
        try? DriveWriter.writeDataSync(data, to: dest)
    }

    /// For each folder, the later of the two stamps (by size, whichever its sign).
    static func merged(_ a: [String: Double], _ b: [String: Double]) -> [String: Double] {
        var out = a
        for (folder, stamp) in b {
            if let have = out[folder], abs(have) >= abs(stamp) { continue }
            out[folder] = stamp
        }
        return out
    }
}

extension Library {
    /// Whether `folder` lists its videos before its other files.
    func videosAtTop(in folder: URL) -> Bool { (videosFirst[folder.path] ?? 0) > 0 }

    /// Turns "Videos at the Top" on or off for `folder`; the drive's copy follows shortly.
    func setVideosAtTop(_ on: Bool, in folder: URL) {
        let now = Date().timeIntervalSince1970
        videosFirst[folder.path] = on ? now : -now
        FilePrefs.shared.set(videosFirst, forKey: FolderOptions.prefsKey)
        scheduleTagSync(after: 1)          // `syncDriveTags` runs `syncFolderOptions`
    }

    /// One merge with the drive's `folder-options.json`: what Photo Browser for Mac set comes in, what was
    /// set here goes out — Videos at the Top, album highlights and Reviews folders. The file is only
    /// written when there's something it doesn't have.
    ///
    /// Highlights and Reviews folders are sets here (`albumHighlights`, `reviewsFolders`); when each was
    /// last turned on or off is kept beside them (`albumHighlightStamps`, `reviewsStamps`: path → stamp,
    /// positive on, negative off). One made before the stamps existed counts as turned on at time 1 — so
    /// it reaches the drive, and anything chosen since, on either side, wins over it.
    func syncFolderOptions() async {
        guard let root = rootURL, !waitingForDrive else { return }
        let rootPath = root.path
        let canonicalRoot = Self.canonicalPath(rootPath)
        func relative(_ path: String) -> String? {
            let canonical = Self.canonicalPath(path)
            if canonical == canonicalRoot { return "" }
            guard canonical.hasPrefix(canonicalRoot + "/") else { return nil }      // another drive's folder
            return String(canonical.dropFirst(canonicalRoot.count + 1)).precomposedStringWithCanonicalMapping
        }
        func stamped(_ members: Set<String>, _ stamps: [String: Double]) -> [String: Double] {
            var out = stamps
            for path in members where out[path] == nil { out[path] = 1 }
            return out
        }
        let byPath: [String: [String: Double]] = [
            "videos_first": videosFirst,
            "highlight": stamped(albumHighlights, albumHighlightStamps),
            "reviews": stamped(reviewsFolders, reviewsStamps),
        ]
        var local: [String: [String: Double]] = [:]        // choice → drive-relative folder → stamp
        var stored: [String: [String: String]] = [:]       // choice → drive-relative folder → the key it's kept under here
        for (option, entries) in byPath {
            var rels: [String: Double] = [:], keys: [String: String] = [:]
            for (path, stamp) in entries {
                guard let rel = relative(path) else { continue }
                rels[rel] = stamp
                keys[rel] = path
            }
            local[option] = rels
            stored[option] = keys
        }
        let mine = local
        let merged = await Task.detached(priority: .utility) { () -> [String: [String: Double]] in
            let theirs = FolderOptions.readAll(root: root)
            var all: [String: [String: Double]] = [:]
            for option in FolderOptions.options {
                all[option] = FolderOptions.merged(mine[option] ?? [:], theirs[option] ?? [:])
            }
            if all != theirs && all.values.contains(where: { !$0.isEmpty }) { FolderOptions.writeAll(all, root: root) }
            return all
        }.value
        guard rootURL?.path == rootPath else { return }      // another drive was opened meanwhile
        func key(_ option: String, _ rel: String) -> String {
            stored[option]?[rel] ?? (rel.isEmpty ? rootPath : rootPath + "/" + rel)
        }
        var changedVideos = false
        for (rel, stamp) in merged["videos_first"] ?? [:] where local["videos_first"]?[rel] != stamp {
            videosFirst[key("videos_first", rel)] = stamp
            changedVideos = true
        }
        if changedVideos { FilePrefs.shared.set(videosFirst, forKey: FolderOptions.prefsKey) }
        var changedRoles = false
        for (rel, stamp) in merged["highlight"] ?? [:] where local["highlight"]?[rel] != stamp {
            let path = key("highlight", rel)
            albumHighlightStamps[path] = stamp
            if stamp > 0 { albumHighlights.insert(path) } else { albumHighlights.remove(path) }
            changedRoles = true
        }
        for (rel, stamp) in merged["reviews"] ?? [:] where local["reviews"]?[rel] != stamp {
            let path = key("reviews", rel)
            reviewsStamps[path] = stamp
            if stamp > 0 { reviewsFolders.insert(path) } else { reviewsFolders.remove(path) }
            changedRoles = true
        }
        if changedRoles {
            FilePrefs.shared.set(Array(albumHighlights), forKey: "photoBrowser.albumHighlights")
            FilePrefs.shared.set(Array(reviewsFolders), forKey: "photoBrowser.reviewsFolders")
            FilePrefs.shared.set(albumHighlightStamps, forKey: FolderOptions.highlightStampsKey)
            FilePrefs.shared.set(reviewsStamps, forKey: FolderOptions.reviewsStampsKey)
            labelsVersion += 1
            changeToken += 1
        }
    }

    /// `list` with its videos moved ahead of its other files — folders first, and every group in
    /// the order it already had (so the sort still orders the videos, and the photos).
    nonisolated static func videosAhead(_ list: [Entry]) -> [Entry] {
        var folders: [Entry] = [], videos: [Entry] = [], rest: [Entry] = []
        for entry in list {
            if entry.isFolder {
                folders.append(entry)
            } else if entry.kind == .video {
                videos.append(entry)
            } else {
                rest.append(entry)
            }
        }
        return folders + videos + rest
    }
}
