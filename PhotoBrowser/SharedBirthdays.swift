import Foundation

/// Folder birthdays (the "Age" feature) shared with Photo Browser for Mac through the drive.
///
/// The birthdays themselves stay where they always were — `Library.folderBirthdays` (folder path →
/// Unix time, `FilePrefs`) — and for the drive that's open they're also in
/// `<drive>/.Photo Browser Metadata/birthdays.json`:
/// `{"birthdays": {"<folder, drive-relative>": {"date": <Unix time | null>, "at": <when it was set>}}}`,
/// which Photo Browser for Mac reads and writes too (`mac/birthdays.py`). So a birthday set on the Mac
/// shows an Age here, and the other way round.
///
/// `"date": null` is a birthday that was removed — kept with its time so the other app's older copy
/// doesn't bring it back. When each birthday was last set or removed is `Library.birthdayStamps`
/// (path → Unix time); birthdays set before this existed have none and count as time 0, so anything
/// set since — on either side — wins over them. Merging takes, for each folder, the entry set later;
/// a tie keeps this phone's.
///
/// Read and written off the main actor (`Library.syncBirthdays`, run with the tag sync: drive
/// opened or back, foreground, and a moment after a change). A rename or move re-keys the stamps
/// with the birthdays (`applyRemap`, `migrateMetadata`).
nonisolated enum SharedBirthdays {
    static let fileName = "birthdays.json"
    static let format = "photobrowser-birthdays"
    static let stampsKey = "photoBrowser.birthdayStamps"

    struct Entry: Equatable, Sendable {
        var date: Double?          // nil = removed
        var at: Double
    }

    static func file(root: URL) -> URL {
        MetadataBackup.driveBackupDirectory(root: root).appendingPathComponent(fileName)
    }

    /// What the drive's file says: folder (drive-relative, "" = the drive itself) → entry.
    static func read(root: URL) -> [String: Entry] {
        guard let data = try? Data(contentsOf: file(root: root)),
              let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              doc["format"] as? String == format,
              let raw = doc["birthdays"] as? [String: Any] else { return [:] }
        var out: [String: Entry] = [:]
        for (folder, value) in raw {
            guard let v = value as? [String: Any], let at = (v["at"] as? NSNumber)?.doubleValue else { continue }
            let date = (v["date"] as? NSNumber)?.doubleValue          // NSNull / missing = removed
            out[folder.precomposedStringWithCanonicalMapping] = Entry(date: date, at: at)
        }
        return out
    }

    /// Best-effort: a drive that's gone or read-only just keeps the file it had.
    static func write(_ entries: [String: Entry], root: URL) {
        var body: [String: Any] = [:]
        for (folder, e) in entries {
            let date: Any = e.date ?? NSNull()
            body[folder] = ["date": date, "at": e.at] as [String: Any]
        }
        let doc: [String: Any] = ["format": format, "version": 1, "by": "Photo Browser",
                                  "updated": Date().timeIntervalSince1970, "birthdays": body]
        guard let data = try? JSONSerialization.data(withJSONObject: doc, options: [.sortedKeys]) else { return }
        let dest = file(root: root)
        let dir = dest.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) { try? DriveWriter.createDirectory(at: dir) }
        try? DriveWriter.writeDataSync(data, to: dest)
    }

    /// For each folder, the entry set later; a tie keeps `a`'s.
    static func merged(_ a: [String: Entry], _ b: [String: Entry]) -> [String: Entry] {
        var out = a
        for (folder, entry) in b {
            if let have = out[folder], have.at >= entry.at { continue }
            out[folder] = entry
        }
        return out
    }
}

extension Library {
    /// One merge with the drive's `birthdays.json`: what Photo Browser for Mac set comes in, what was set
    /// here goes out. The file is only written when there's something it doesn't have.
    func syncBirthdays() async {
        guard let root = rootURL, !waitingForDrive else { return }
        let rootPath = root.path
        let canonicalRoot = Self.canonicalPath(rootPath)
        var local: [String: SharedBirthdays.Entry] = [:]    // drive-relative folder → entry
        var stored: [String: String] = [:]                  // drive-relative folder → the key it's kept under here
        for path in Set(folderBirthdays.keys).union(birthdayStamps.keys) {
            let canonical = Self.canonicalPath(path)
            let rel: String
            if canonical == canonicalRoot {
                rel = ""
            } else if canonical.hasPrefix(canonicalRoot + "/") {
                rel = String(canonical.dropFirst(canonicalRoot.count + 1)).precomposedStringWithCanonicalMapping
            } else {
                continue                                    // another drive's folder
            }
            local[rel] = SharedBirthdays.Entry(date: folderBirthdays[path], at: birthdayStamps[path] ?? 0)
            stored[rel] = path
        }
        let mine = local
        let merged = await Task.detached(priority: .utility) { () -> [String: SharedBirthdays.Entry] in
            let theirs = SharedBirthdays.read(root: root)
            let all = SharedBirthdays.merged(mine, theirs)
            if !all.isEmpty && all != theirs { SharedBirthdays.write(all, root: root) }
            return all
        }.value
        guard rootURL?.path == rootPath else { return }     // another drive was opened meanwhile
        var changed = false
        for (rel, entry) in merged where local[rel] != entry {
            let key = stored[rel] ?? (rel.isEmpty ? rootPath : rootPath + "/" + rel)
            if let date = entry.date { folderBirthdays[key] = date } else { folderBirthdays.removeValue(forKey: key) }
            birthdayStamps[key] = entry.at
            changed = true
        }
        if changed {
            FilePrefs.shared.set(folderBirthdays, forKey: "photoBrowser.birthdays")
            FilePrefs.shared.set(birthdayStamps, forKey: SharedBirthdays.stampsKey)
            labelsVersion += 1
            changeToken += 1
        }
    }
}
