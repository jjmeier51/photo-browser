import Foundation

/// Renames made on the Mac, carried over to everything this app keeps by path.
///
/// Safe Finder can rename files and folders on the drive (Rename…, "Remove Leading Spaces from
/// Names…" — `mac/rename_tools.py`). The tags, Favorites and To AI follow by themselves (they live
/// in the drive's shared tag file, which Safe Finder re-keys), but captions, covers, birthdays,
/// hidden items, the downloaders' folder records and the rest are keyed by path *on the phone* —
/// a rename made elsewhere would orphan them, exactly as a rename in Finder does.
///
/// So Safe Finder notes every rename it makes in the drive's
/// `.Photo Browser Metadata/renames.json` — `{"renames": [{"id", "from", "to", "dir", "at"}]}`,
/// paths drive-relative, `from` the item's path before the batch and `to` where it ended up. Each
/// time the drive is opened or comes back (the tag sync's moments), the entries this phone hasn't
/// applied yet are put through `itemsMoved` — the same re-keying a rename made here gets — and
/// their ids remembered (`photoBrowser.appliedRenames`, a `FilePrefs` list), so each is applied
/// once. Entries are applied whether or not the item is still there: the rename did happen, and
/// re-keying to a path that has since gone is no worse than leaving the old key.
///
/// The file is read off the main actor; only the re-keying touches `Library`.
nonisolated enum RenameJournal {
    static let fileName = "renames.json"
    static let format = "photobrowser-renames"
    static let appliedKey = "photoBrowser.appliedRenames"
    static let keepApplied = 30_000

    nonisolated struct Move: Sendable {
        let from: String            // drive-relative
        let to: String
        let isDirectory: Bool
    }

    /// The entries not in `applied`, oldest first, with renames of the same item made one after
    /// another folded together (a → b, then b → c, is a → c; a folder renamed later carries the
    /// items already renamed inside it) — so they can go through one `itemsMoved` pass.
    static func pending(root: URL, applied: Set<String>) -> (moves: [Move], ids: [String]) {
        let file = MetadataBackup.driveBackupDirectory(root: root).appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: file),
              let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              doc["format"] as? String == format,
              let list = doc["renames"] as? [[String: Any]] else { return ([], []) }
        var froms: [String] = [], tos: [String] = [], dirs: [Bool] = []
        var ids: [String] = []
        for item in list {
            guard let id = item["id"] as? String, !id.isEmpty, !applied.contains(id),
                  let from = item["from"] as? String, let to = item["to"] as? String,
                  !from.isEmpty, !to.isEmpty, from != to,
                  !from.hasPrefix("/"), !to.hasPrefix("/"),
                  !from.contains("../"), !to.contains("../") else { continue }
            let isDir = (item["dir"] as? Bool) ?? false
            // Fold into the moves before it: anything that had ended up at (or under) `from` is now at `to`.
            for i in tos.indices {
                if tos[i] == from {
                    tos[i] = to
                } else if isDir, tos[i].hasPrefix(from + "/") {
                    tos[i] = to + tos[i].dropFirst(from.count)
                }
            }
            froms.append(from); tos.append(to); dirs.append(isDir)
            ids.append(id)
        }
        var moves: [Move] = []
        for i in froms.indices where froms[i] != tos[i] {
            moves.append(Move(from: froms[i], to: tos[i], isDirectory: dirs[i]))
        }
        // Longest paths first: `itemsMoved` takes the first folder whose path is a prefix, and an
        // item inside two renamed folders must be matched by the deeper one.
        moves.sort { $0.from.count > $1.from.count }
        return (moves, ids)
    }
}

extension Library {
    /// Applies the Mac's renames this phone hasn't applied yet (see `RenameJournal`). Returns how
    /// many were applied.
    @discardableResult
    func applyMacRenames() async -> Int {
        guard let root = rootURL, !waitingForDrive else { return 0 }
        let rootPath = root.path
        let applied = Set(FilePrefs.shared.stringArray(forKey: RenameJournal.appliedKey) ?? [])
        let found = await Task.detached(priority: .utility) {
            RenameJournal.pending(root: root, applied: applied)
        }.value
        guard !found.ids.isEmpty, rootURL?.path == rootPath else { return 0 }
        // Keys may be stored under either spelling of the drive's path (/private/var… and /var…).
        var bases = [rootPath]
        let canonical = Self.canonicalPath(rootPath)
        if canonical != rootPath { bases.append(canonical) }
        var moves: [(from: URL, to: URL)] = []
        for base in bases {
            for m in found.moves {
                moves.append((from: URL(fileURLWithPath: base + "/" + m.from, isDirectory: m.isDirectory),
                              to: URL(fileURLWithPath: base + "/" + m.to, isDirectory: m.isDirectory)))
            }
        }
        if !moves.isEmpty { itemsMoved(moves) }
        var remembered = FilePrefs.shared.stringArray(forKey: RenameJournal.appliedKey) ?? []
        remembered.append(contentsOf: found.ids)
        if remembered.count > RenameJournal.keepApplied {
            remembered.removeFirst(remembered.count - RenameJournal.keepApplied)
        }
        FilePrefs.shared.set(remembered, forKey: RenameJournal.appliedKey)
        if !found.moves.isEmpty { contentDidChange() }
        return found.moves.count
    }
}
