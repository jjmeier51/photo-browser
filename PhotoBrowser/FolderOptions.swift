import Foundation

/// Per-folder choices shared with Safe Finder — so far one: **Videos at the Top** (a folder's
/// videos listed before its photos; folders and highlights still first).
///
/// The choice is kept by folder path in `Library.videosFirst` (a `FilePrefs` dictionary:
/// path → stamp), and — for the drive that's open — in
/// `<drive>/.Photo Browser Metadata/folder-options.json`
/// (`{"videos_first": {"<folder, drive-relative>": stamp}}`), which Safe Finder reads and writes
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

    /// What the drive's file says: folder (drive-relative, "" = the drive itself) → stamp.
    static func read(root: URL) -> [String: Double] {
        guard let data = try? Data(contentsOf: file(root: root)),
              let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              doc["format"] as? String == format,
              let raw = doc["videos_first"] as? [String: Any] else { return [:] }
        var out: [String: Double] = [:]
        for (folder, value) in raw {
            if let n = value as? NSNumber { out[folder] = n.doubleValue }
        }
        return out
    }

    /// Best-effort: a drive that's gone or read-only just keeps the file it had.
    static func write(_ entries: [String: Double], root: URL) {
        let doc: [String: Any] = ["format": format, "version": 1, "by": "Photo Browser",
                                  "updated": Date().timeIntervalSince1970, "videos_first": entries]
        guard let data = try? JSONSerialization.data(withJSONObject: doc, options: [.sortedKeys]) else { return }
        let dest = file(root: root)
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

    /// One merge with the drive's `folder-options.json`: what Safe Finder set comes in, what was
    /// set here goes out. The file is only written when there's something it doesn't have.
    func syncFolderOptions() async {
        guard let root = rootURL, !waitingForDrive else { return }
        let rootPath = root.path
        let canonicalRoot = Self.canonicalPath(rootPath)
        var local: [String: Double] = [:]          // drive-relative folder → stamp
        var stored: [String: String] = [:]         // drive-relative folder → the key it's kept under here
        for (path, stamp) in videosFirst {
            let canonical = Self.canonicalPath(path)
            let rel: String
            if canonical == canonicalRoot {
                rel = ""
            } else if canonical.hasPrefix(canonicalRoot + "/") {
                rel = String(canonical.dropFirst(canonicalRoot.count + 1))
            } else {
                continue                           // another drive's folder
            }
            local[rel] = stamp
            stored[rel] = path
        }
        let mine = local
        let merged = await Task.detached(priority: .utility) { () -> [String: Double] in
            let theirs = FolderOptions.read(root: root)
            let all = FolderOptions.merged(mine, theirs)
            if !all.isEmpty && all != theirs { FolderOptions.write(all, root: root) }
            return all
        }.value
        guard rootURL?.path == rootPath else { return }      // another drive was opened meanwhile
        var changed = false
        for (rel, stamp) in merged where local[rel] != stamp {
            let key = stored[rel] ?? (rel.isEmpty ? rootPath : rootPath + "/" + rel)
            videosFirst[key] = stamp
            changed = true
        }
        if changed { FilePrefs.shared.set(videosFirst, forKey: FolderOptions.prefsKey) }
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
