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
/// **Tags travel with the file.** The tables are keyed by path, so on their own a file moved or copied
/// by anything else (Finder, the Files app, `cp`) would leave its tags behind. So each file also
/// *carries* its tags in two extended attributes — Finder's own tags
/// (`com.apple.metadata:_kMDItemUserTags`, which every Apple tool keeps through a copy or move, and which
/// Finder and Spotlight show) and a marker (`com.photobrowser.tags`: the drive-relative path and tags it
/// had when last written). Not on exFAT, where macOS would scatter `._` files. A sync writes them for
/// every file whose tags changed (all of them, once, the first time — `Base.carried`); a file new to
/// the index (`Library.adoptCarriedTags`) is squared with the store by `reconcile`: a marker naming
/// another path means the file arrived from elsewhere, so its tags are adopted here (and dropped from
/// the old path when nothing is there any more — a move); Finder tags that differ from the marker were
/// edited in Finder and are merged in three ways; Finder tags without a marker are adopted. Safe Finder
/// does the same for every folder it opens (`mac/shared_tags.py`).
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
        var carried: Bool?          // every file's own attributes were written at that sync (nil: not yet)
    }

    /// `com.photobrowser.tags` on a file: where it was, and what it carried, when last written.
    nonisolated struct Marker: Codable, Sendable {
        var path: String
        var tags: [String]
    }

    /// What a file carries: Finder's entries as stored ("Name\nColour") and the marker.
    nonisolated struct Carried: Sendable {
        var finder: [String]?
        var marker: Marker?
    }

    /// What files new to the index brought (store-key spelled): new tags per path, and old paths of
    /// files that moved (nothing left there).
    nonisolated struct Adoption: Sendable {
        var updates: [String: [String]] = [:]
        var forget: [String] = []
    }

    /// How the last sync went — for Drive Health.
    nonisolated struct Status: Sendable, Equatable {
        var date: Date
        var files: Int                  // tagged files in the drive's file
        var error: String?
    }

    nonisolated enum Outcome: Sendable {
        /// `adopted`: drive-relative keys whose files carried tags the store lacked; `movedAway`: keys
        /// whose files moved elsewhere (their tags went with them).
        case synced(merged: [String: [String]], id: String, by: String?, carried: Bool,
                    adopted: [String: [String]], movedAway: [String])
        case failed(String)
    }

    static let finderTagsName = "com.apple.metadata:_kMDItemUserTags"
    static let markerName = "com.photobrowser.tags"
    /// In a `.pbgallery` from the Mac (`mac/airdrop_to_iphone.py`), beside the files: their tags.
    static let archiveSidecar = ".photobrowser-tags.json"

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

    // MARK: Tags carried by the file

    static func getAttribute(_ path: String, _ name: String) -> Data? {
        let length = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard length > 0, length < 1_048_576 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        let read = getxattr(path, name, &buffer, length, 0, XATTR_NOFOLLOW)
        guard read > 0 else { return nil }
        return Data(buffer.prefix(read))
    }

    static func setAttribute(_ path: String, _ name: String, _ data: Data) -> Bool {
        data.withUnsafeBytes { setxattr(path, name, $0.baseAddress, data.count, 0, XATTR_NOFOLLOW) == 0 }
    }

    /// Finder's "Name\nColour" entries → the names.
    static func finderNames(_ entries: [String]) -> [String] {
        clean(entries.map { String($0.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? "") })
    }

    static func readCarried(_ path: String) -> Carried {
        var carried = Carried()
        if let data = getAttribute(path, finderTagsName),
           let list = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [Any] {
            carried.finder = list.compactMap { $0 as? String }
        }
        if let data = getAttribute(path, markerName) {
            carried.marker = try? JSONDecoder().decode(Marker.self, from: data)
        }
        return carried
    }

    /// Puts `tags` on the file (Finder's tags + the marker), or takes both off when there are none. A
    /// tag Finder had already coloured keeps its colour; new ones get none.
    @discardableResult
    static func writeCarried(_ path: String, key: String, tags: [String], finderBefore: [String]?) -> Bool {
        if tags.isEmpty {
            removexattr(path, finderTagsName, XATTR_NOFOLLOW)
            removexattr(path, markerName, XATTR_NOFOLLOW)
            return true
        }
        var colours: [String: String] = [:]
        for entry in finderBefore ?? [] {
            let parts = entry.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            guard let name = parts.first else { continue }
            colours[Library.normalizedTag(String(name)).lowercased()] = parts.count > 1 ? String(parts[1]) : "0"
        }
        let entries = tags.map { "\($0)\n\(colours[$0.lowercased()] ?? "0")" }
        guard let plist = try? PropertyListSerialization.data(fromPropertyList: entries, format: .binary, options: 0),
              let marker = try? JSONEncoder().encode(Marker(path: key, tags: tags)) else { return false }
        return setAttribute(path, finderTagsName, plist) && setAttribute(path, markerName, marker)
    }

    /// The tag attributes a file carries, raw — kept across an in-place rewrite that replaces the file
    /// (a crop, a rotate, a capture-date write), which would otherwise drop them.
    static func carriedAttributes(of url: URL) -> [(String, Data)] {
        [finderTagsName, markerName].compactMap { name in getAttribute(url.path, name).map { (name, $0) } }
    }

    static func restoreAttributes(_ attributes: [(String, Data)], to url: URL) {
        for (name, data) in attributes { _ = setAttribute(url.path, name, data) }
    }

    /// Squares a file's carried tags with what the store has for it (`have`), at drive-relative `key`.
    /// Returns the tags the file should have, whether its attributes need rewriting, and — when its
    /// marker names another path — that path (a move if nothing is there any more).
    static func reconcile(have: [String], carried: Carried, key: String) -> (tags: [String], write: Bool, movedFrom: String?) {
        let onFile = finderNames(carried.finder ?? [])
        let markTags = carried.marker.map { clean($0.tags) }
        var movedFrom: String?
        let new: [String]
        if let marker = carried.marker, marker.path == key {
            new = onFile != markTags ? merge(local: have, base: markTags ?? [], remote: onFile) : have
        } else {
            new = clean(have + onFile)                 // put on in Finder, or arrived from elsewhere
            movedFrom = carried.marker?.path
        }
        let write = onFile != new
            || (new.isEmpty ? carried.marker != nil : (carried.marker?.path != key || markTags != new))
        return (new, write, movedFrom)
    }

    /// Reads, reconciles and (if needed) rewrites one file's carried tags. Blocking.
    static func settle(path: String, key: String, have: [String]) -> (tags: [String], movedFrom: String?) {
        let carried = readCarried(path)
        let r = reconcile(have: have, carried: carried, key: key)
        if r.write { writeCarried(path, key: key, tags: r.tags, finderBefore: carried.finder) }
        return (r.tags, r.movedFrom)
    }

    /// Files that turned up in the index since the last walk — moved or copied in by Finder or the Files
    /// app — bring the tags they carry. `store` is the store's tags (keys spelled under `root.path`).
    static func adoptCarried(newFiles: [String], root: URL, store: [String: [String]]) -> Adoption {
        var out = Adoption()
        let fm = FileManager.default
        let rootPath = root.path, prefix = rootPath + "/"
        for path in newFiles where path.hasPrefix(prefix) {
            let key = String(path.dropFirst(prefix.count))
            guard isShared(key) else { continue }
            let carried = readCarried(path)
            guard carried.finder != nil || carried.marker != nil else { continue }
            let have = store[path] ?? []
            let r = reconcile(have: have, carried: carried, key: key)
            if r.write { writeCarried(path, key: key, tags: r.tags, finderBefore: carried.finder) }
            if r.tags != have { out.updates[path] = r.tags }
            if let from = r.movedFrom, !from.hasPrefix("/"), isShared(from), from != key,
               !fm.fileExists(atPath: prefix + from) {
                out.forget.append(prefix + from)       // moved here, not copied: nothing left at the old path
            }
        }
        return out
    }

    /// Reads the drive's file, merges it with `local` (drive-relative) against the base its `id`
    /// has in `bases`, and writes the result back when the drive's copy differs. With `carry`, every
    /// file whose tags changed (every tagged file, the first time) gets its own attributes written too.
    /// Blocking file I/O.
    static func sync(root: URL, local: [String: [String]], bases: [String: Base], carry: Bool) -> Outcome {
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
        // The files' own copies: what changed since the last sync (everything, the first time).
        var adopted: [String: [String]] = [:]
        var movedAway: [String] = []
        if carry {
            let prior = base?.carried == true ? base?.files : nil
            let keys = prior.map { p in Set(merged.keys).union(p.keys).filter { merged[$0] != p[$0] } } ?? Set(merged.keys)
            let prefix = root.path + "/"
            for key in keys {
                let path = prefix + key
                guard fm.fileExists(atPath: path) else { continue }
                let r = settle(path: path, key: key, have: merged[key] ?? [])
                if r.tags != (merged[key] ?? []) { adopted[key] = r.tags }
                if let from = r.movedFrom, !from.hasPrefix("/"), isShared(from), from != key,
                   !fm.fileExists(atPath: prefix + from) {
                    movedAway.append(from)
                }
            }
        }
        return .synced(merged: merged, id: id, by: remote?.by, carried: carry, adopted: adopted, movedAway: movedAway)
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
        let carry = DriveWriter.syncMode != .full           // exFAT: no attributes (macOS would make `._` files)
        let outcome = await Task.detached(priority: .utility) {
            SharedTags.sync(root: root, local: mine, bases: bases, carry: carry)
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
        case .synced(let merged, let id, let by, let carried, let adopted, let movedAway):
            var changed = 0
            for rel in Set(local.keys).union(merged.keys) {
                let new = merged[rel] ?? [], old = local[rel] ?? []
                guard new != old else { continue }
                let key = stored[rel] ?? rootPath + "/" + rel
                guard (tags[key] ?? []) == old else { continue }   // edited during the sync: the next one merges it
                if new.isEmpty { tags.removeValue(forKey: key) } else { tags[key] = new }
                changed += 1
            }
            // Tags the files themselves brought (moved or copied in, edited in Finder) — they reach
            // the drive's file at the next sync, which `noteTagsEdited` schedules.
            var carriedIn = 0
            for (rel, new) in adopted {
                let key = stored[rel] ?? rootPath + "/" + rel
                guard (tags[key] ?? []) == (merged[rel] ?? []) else { continue }
                if new.isEmpty { tags.removeValue(forKey: key) } else { tags[key] = new }
                carriedIn += 1
            }
            for rel in movedAway {
                let key = stored[rel] ?? rootPath + "/" + rel
                if tags.removeValue(forKey: key) != nil { carriedIn += 1 }
            }
            tagSyncBases[id] = SharedTags.Base(files: merged, date: Date().timeIntervalSince1970,
                                               carried: carried ? true : tagSyncBases[id]?.carried)
            scheduleBulkSave(tagSyncBases, "tagSyncBase")
            if carriedIn > 0 {
                scheduleBulkSave(tags, "tags")
                noteTagsEdited()
                labelsVersion += 1
            }
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

    /// After a walk or a patch of the index: files new to it — moved or copied in by Finder, the Files
    /// app or anything else — bring the tags they carry (see `SharedTags.adoptCarried`). `within`: only
    /// what's under these folders changed (a patch). Skipped on exFAT (nothing is carried there) and
    /// when there's no earlier index to compare with.
    func adoptCarriedTags(before: [Entry], after: [Entry], within folders: Set<String>? = nil) {
        guard let root = rootURL, DriveWriter.syncMode != .full, !before.isEmpty else { return }
        let store = tags
        Task {
            let found = await Task.detached(priority: .utility) { () -> SharedTags.Adoption in
                func inScope(_ e: Entry) -> Bool {
                    guard !e.isFolder else { return false }
                    guard let folders else { return true }
                    let p = e.url.path
                    return folders.contains { p.hasPrefix($0 + "/") }
                }
                let known = Set(before.lazy.filter(inScope).map(\.url.path))
                let fresh = after.lazy.filter { inScope($0) && !known.contains($0.url.path) }.map(\.url.path)
                return SharedTags.adoptCarried(newFiles: Array(fresh), root: root, store: store)
            }.value
            guard rootURL == root else { return }
            var changed = 0
            for (path, new) in found.updates where tags[path] == store[path] {   // untouched meanwhile
                if new.isEmpty { tags.removeValue(forKey: path) } else { tags[path] = new }
                changed += 1
            }
            for path in found.forget where tags[path] == store[path] && tags[path] != nil {
                tags.removeValue(forKey: path)
                changed += 1
            }
            guard changed > 0 else { return }
            scheduleBulkSave(tags, "tags")
            noteTagsEdited()
            labelsVersion += 1
        }
    }

    /// An archive AirDropped from the Mac unpacked into `folder`: the tags its files had there (the
    /// hidden `.photobrowser-tags.json` it carries) go onto them, and the sidecar is removed.
    func applyArchiveTags(in folder: URL) async {
        let found = await Task.detached(priority: .utility) { () -> [String: [String]] in
            let fm = FileManager.default
            let sidecar = folder.appendingPathComponent(SharedTags.archiveSidecar)
            guard let data = try? Data(contentsOf: sidecar) else { return [:] }
            try? fm.removeItem(at: sidecar)
            guard let doc = try? JSONDecoder().decode(SharedTags.File.self, from: data) else { return [:] }
            var out: [String: [String]] = [:]
            for (rel, list) in doc.files where SharedTags.isShared(rel) {
                let path = folder.appendingPathComponent(rel).path
                let tags = SharedTags.clean(list)
                if !tags.isEmpty, fm.fileExists(atPath: path) { out[path] = tags }
            }
            return out
        }.value
        var added = 0
        for (path, list) in found {
            let merged = SharedTags.clean((tags[path] ?? []) + list)
            if merged != (tags[path] ?? []) { tags[path] = merged; added += 1 }
        }
        guard added > 0 else { return }
        scheduleBulkSave(tags, "tags")
        noteTagsEdited()
        labelsVersion += 1
    }

    /// A copy made in the app gets its original's tags — a copied folder's files theirs. Tags are the
    /// label that travels with copies; favorites, captions and the rest stay with the original.
    func copyTags(_ pairs: [(from: URL, to: URL)]) {
        var map: [String: String] = [:]
        for pair in pairs { map[pair.from.path] = pair.to.path }
        guard !map.isEmpty else { return }
        var adds: [(String, [String])] = []
        for (path, list) in tags where !list.isEmpty {
            var probe = path
            while true {                                   // the file itself, or a copied folder above it
                if let dst = map[probe] { adds.append((dst + path.dropFirst(probe.count), list)); break }
                guard let slash = probe.lastIndex(of: "/"), slash > probe.startIndex else { break }
                probe = String(probe[..<slash])
            }
        }
        var added = 0
        for (target, list) in adds {
            let merged = SharedTags.clean((tags[target] ?? []) + list)
            if merged != (tags[target] ?? []) { tags[target] = merged; added += 1 }
        }
        guard added > 0 else { return }
        scheduleBulkSave(tags, "tags")
        noteTagsEdited()
        labelsVersion += 1
    }
}
