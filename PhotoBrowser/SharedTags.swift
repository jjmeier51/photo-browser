import Foundation

/// Tags shared with Safe Finder on the Mac (`mac/shared_tags.py`): the drive's
/// `.Photo Browser Metadata/shared-tags.json`, keyed by each file's path inside the drive — the same
/// key for a file on the Mac (`/Volumes/SSD/…`) and here (`…/SSD/…`).
///
/// The drive is plugged into one device at a time. Safe Finder edits the drive's file directly; the
/// app keeps its own `tags` store and, whenever the drive is here — opened, reconnected, back in the
/// foreground, a couple of seconds after a tag changes, on the way to the background — merges the two
/// **three ways** against what they agreed on at the last sync (`Base`): a tag added or removed on one
/// side wins over one left alone, and both sides' additions are kept. The result goes back to the drive
/// (through `DriveWriter`) and into the store.
///
/// The base is kept per drive file, by the file's `id` — not by the root path, which changes every
/// time the drive is replugged. A file the app has no base for (new, started afresh by Safe Finder
/// after damage, or a drive it has never synced) shares no history with the store, so nothing is taken
/// as removed: the two are combined. A lost or damaged file can therefore never wipe tags. Hidden paths
/// (`.Trash`, …) are never shared.
///
/// Everything here runs off the main actor; reading and applying the store is `Library.syncDriveTags`.
nonisolated enum SharedTags {
    static let fileName = "shared-tags.json"
    static let format = "Photo Browser shared tags"

    /// The file on the drive (Safe Finder writes the same shape).
    nonisolated struct File: Codable, Sendable {
        var format: String?
        var version: Int?
        var id: String?
        var updated: Double?
        var by: String?
        var files: [String: [String]]
    }

    /// What the app and one drive's file agreed on at the last sync.
    nonisolated struct Base: Codable, Sendable {
        var files: [String: [String]]
        var date: Double
    }

    /// How the last sync went — for Drive Health.
    nonisolated struct Status: Sendable, Equatable {
        var date: Date
        var files: Int                  // tagged files in the drive's file
        var error: String?
    }

    nonisolated enum Outcome: Sendable {
        case synced(merged: [String: [String]], id: String, by: String?)
        case failed(String)
    }

    static func fileURL(root: URL) -> URL {
        MetadataBackup.driveBackupDirectory(root: root).appendingPathComponent(fileName)
    }

    /// A drive-relative path the file may hold: not empty, nothing hidden along it.
    static func isShared(_ rel: String) -> Bool {
        !rel.isEmpty && !rel.split(separator: "/").contains { $0.hasPrefix(".") }
    }

    /// Tags as stored: normalized like `Library.normalizedTag`, empty ones dropped, each once
    /// whatever its case (first spelling wins), in order.
    static func clean(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in tags {
            let t = Library.normalizedTag(raw)
            if !t.isEmpty, seen.insert(t.lowercased()).inserted { out.append(t) }
        }
        return out
    }

    /// One file's tags, three ways: a side that left the base alone takes the other side's; when
    /// both changed, every tag either side removed goes and every tag either side added stays.
    static func merge(local l: [String], base b: [String], remote r: [String]) -> [String] {
        if l == b { return r }
        if r == b { return l }
        let inBase = Set(b.map { $0.lowercased() })
        let removed = inBase.subtracting(l.map { $0.lowercased() })
            .union(inBase.subtracting(r.map { $0.lowercased() }))
        return clean((l + r).filter { !removed.contains($0.lowercased()) })
    }

    /// The whole table. `base` nil: no shared history — combine, remove nothing.
    static func merge(local: [String: [String]], base: [String: [String]]?,
                      remote: [String: [String]]) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for key in Set(local.keys).union(remote.keys) {
            let l = local[key] ?? [], r = remote[key] ?? []
            let m = base.map { merge(local: l, base: $0[key] ?? [], remote: r) } ?? clean(l + r)
            if !m.isEmpty { out[key] = m }
        }
        return out
    }

    /// Reads the drive's file, merges it with `local` (drive-relative) against the base its `id`
    /// has in `bases`, and writes the result back when the drive's copy differs. Blocking file I/O.
    static func sync(root: URL, local: [String: [String]], bases: [String: Base]) -> Outcome {
        let fm = FileManager.default
        let url = fileURL(root: root)
        guard fm.fileExists(atPath: root.path) else { return .failed("The drive isn't connected.") }
        var remote: File?
        if let data = try? Data(contentsOf: url) {
            remote = try? JSONDecoder().decode(File.self, from: data)   // damaged: treated as a new file
        }
        var theirs: [String: [String]] = [:]
        for (key, list) in remote?.files ?? [:] where isShared(key) {
            let tags = clean((theirs[key] ?? []) + list)
            if !tags.isEmpty { theirs[key] = tags }
        }
        let base = remote?.id.flatMap { bases[$0] }
        let merged = merge(local: local, base: base?.files, remote: theirs)
        let id = remote?.id ?? UUID().uuidString
        if remote == nil || merged != theirs {
            let out = File(format: format, version: 1, id: id, updated: Date().timeIntervalSince1970,
                           by: "Photo Browser", files: merged)
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            do {
                // Through DriveWriter (temp → flush → rename): never a half-written file under its name.
                try DriveWriter.writeDataSync(try enc.encode(out), to: url)
            } catch {
                return .failed(error.localizedDescription)
            }
        }
        return .synced(merged: merged, id: id, by: remote?.by)
    }
}

extension Library {
    /// Merges the tags with the drive's shared file a moment from now — coalesced, so a run of tag
    /// edits syncs once. Called after a tag change, when the drive is opened or comes back, and on
    /// return to the foreground (the drive may have been on the Mac meanwhile).
    func scheduleTagSync(after delay: Double = 2) {
        tagSyncTask?.cancel()
        tagSyncTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.tagSyncTask = nil
            await self.syncDriveTags()
        }
    }

    /// A tag was added or removed, or moved with its file: the drive's copy follows shortly.
    func noteTagsEdited() {
        tagEditGeneration &+= 1
        scheduleTagSync()
    }

    /// On the way to the background: a sync still waiting runs now, under a background-task window,
    /// and its results are saved before the window closes — so the drive's copy is current if the
    /// drive goes to the Mac next.
    func flushTagSync() {
        guard tagSyncTask != nil else { return }
        tagSyncTask?.cancel()
        tagSyncTask = nil
        let holder = BackgroundTaskHolder()
        holder.begin(name: "Sync tags to the drive")
        Task {
            await syncDriveTags()
            flushBulkSaves(wait: true)
            holder.end()
        }
    }

    /// One sync with the drive's shared tag file (see `SharedTags`). `announce`: say so even when
    /// nothing changed (the Sync button in Drive Health).
    func syncDriveTags(announce: Bool = false) async {
        guard let root = rootURL, !waitingForDrive else { return }
        if tagSyncRunning { tagSyncAgain = true; return }
        tagSyncRunning = true
        let rootPath = root.path
        let prefix = Self.canonicalPath(rootPath) + "/"
        // The store's tags under this drive, drive-relative — remembering the key each is stored
        // under here, so a change is written back to that same entry.
        var local: [String: [String]] = [:]
        var stored: [String: String] = [:]
        for (path, list) in tags where !list.isEmpty {
            let canonical = Self.canonicalPath(path)
            guard canonical.hasPrefix(prefix) else { continue }
            let rel = String(canonical.dropFirst(prefix.count))
            guard SharedTags.isShared(rel) else { continue }
            local[rel] = list
            stored[rel] = path
        }
        let mine = local, bases = tagSyncBases
        let generation = tagEditGeneration
        let outcome = await Task.detached(priority: .utility) {
            SharedTags.sync(root: root, local: mine, bases: bases)
        }.value
        tagSyncRunning = false
        defer {
            if tagSyncAgain { tagSyncAgain = false; scheduleTagSync(after: 0.5) }
        }
        guard rootURL?.path == rootPath else { return }          // another drive was opened meanwhile
        switch outcome {
        case .failed(let why):
            tagSyncStatus = SharedTags.Status(date: Date(), files: local.count, error: why)
            if announce { postNotice("Couldn't Sync Tags", why) }
        case .synced(let merged, let id, let by):
            var changed = 0
            for rel in Set(local.keys).union(merged.keys) {
                let new = merged[rel] ?? [], old = local[rel] ?? []
                guard new != old else { continue }
                let key = stored[rel] ?? rootPath + "/" + rel
                guard (tags[key] ?? []) == old else { continue }   // edited during the sync: the next one merges it
                if new.isEmpty { tags.removeValue(forKey: key) } else { tags[key] = new }
                changed += 1
            }
            tagSyncBases[id] = SharedTags.Base(files: merged, date: Date().timeIntervalSince1970)
            scheduleBulkSave(tagSyncBases, "tagSyncBase")
            tagSyncStatus = SharedTags.Status(date: Date(), files: merged.count, error: nil)
            if changed > 0 {
                scheduleBulkSave(tags, "tags")
                labelsVersion += 1
                let from = by == "Safe Finder" ? "Safe Finder" : "the drive"
                showToast("Tags from \(from): \(changed) file\(changed == 1 ? "" : "s") updated")
            } else if announce {
                showToast("Tags are in step with the drive (\(merged.count) tagged file\(merged.count == 1 ? "" : "s"))")
            }
            if tagEditGeneration != generation { tagSyncAgain = true }
        }
    }
}
