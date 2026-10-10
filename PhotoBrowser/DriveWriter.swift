import Foundation

/// Serializes the **final placement** of downloaded/exported files onto the external
/// drive, and flushes each file + its parent directory to disk before the next.
///
/// The drive is usually **exFAT**, whose single FAT + directory structure has no
/// journaling: when many concurrent downloads finish at once they update the same
/// directory simultaneously, and if iOS jetsam-kills the app mid-write the directory can
/// be left corrupt (folders showing up as data files, create/delete failing). Downloading
/// the *bytes* can stay as concurrent as we like — only the commit (the temp→final move
/// that mutates the directory) has to be one-at-a-time and durably flushed. Routing every
/// download's placement through this actor guarantees that: no two directory-entry updates
/// overlap, and each is `fsync`'d so a later kill can't tear a half-written entry.
///
/// **Safe removal.** A serialized+flushed commit bounds the corruption window to a single
/// in-flight directory entry, but physically yanking an exFAT drive *during* that write can
/// still tear the FAT — the filesystem has no journal, which is why desktops make you
/// "Eject" first. This actor exposes the hooks the app needs to offer the same guarantee:
/// `quiesce()` drains any in-flight commit and returns once the drive is idle and flushed
/// (call it on background / before a deliberate unplug), and `pause()` / `resume()` gate new
/// commits so a "Prepare Drive for Removal" flow can hold the drive quiet until the user
/// reconnects. Crucially, pausing is **opt-in** — normal background download windows never
/// pause, so bulk downloads keep running at full speed.
actor DriveWriter {
    static let shared = DriveWriter()

    /// How hard we flush each write, chosen from the drive's filesystem (see `configureForVolume`).
    /// - `.full`    — exFAT/FAT: no journal, so force every write to stable media with `F_FULLFSYNC`
    ///                *and* flush the parent directory. This is what prevents the "clusters used but
    ///                not referenced" corruption those volumes suffer on an unclean unplug.
    /// - `.barrier` — APFS/HFS+: journaled / copy-on-write with atomic renames, so a lightweight
    ///                ordering barrier (`F_BARRIERFSYNC`) already gives durability and the full
    ///                device flush is just wasted time; directory entries are journaled with the
    ///                rename, so the separate parent-dir flush is skipped too. Net: much faster
    ///                downloads, edits, moves and thumbnails, with the same crash-safety APFS
    ///                already guarantees.
    enum SyncMode { case full, barrier }

    /// Read on every write from background threads, written only when the root drive changes (rare,
    /// on the main actor). A stale read across that single transition is harmless — it just uses the
    /// previous, equally-valid strategy for a beat — so the unchecked static access is safe.
    nonisolated(unsafe) static var syncMode: SyncMode = .full

    /// Pick the flush strategy from the filesystem hosting `url`. Call whenever the root drive is
    /// set or reconnects. Defaults to the safe `.full` when the type can't be determined.
    nonisolated static func configureForVolume(at url: URL) {
        var s = statfs()
        guard statfs(url.path, &s) == 0 else { syncMode = .full; return }
        let fsType = withUnsafeBytes(of: &s.f_fstypename) { raw -> String in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        // "apfs"/"hfs" are journaled or copy-on-write; "exfat"/"msdos" (FAT) are not.
        syncMode = (fsType == "apfs" || fsType == "hfs") ? .barrier : .full
    }

    /// Number of commits currently placing a file on the drive. `> 0` means a directory
    /// write may be in flight, so it is *not* safe to remove the drive yet.
    private(set) var inFlight = 0

    /// When paused, new commits wait here until `resume()`. Used only by the explicit
    /// "Prepare Drive for Removal" flow — automatic background quiescing does not pause,
    /// so active download windows are never throttled.
    private var paused = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Atomically moves `temp` to `dest` (replacing an existing file), then flushes the
    /// new file and its parent directory. Serialized against every other commit.
    func commit(_ temp: URL, to dest: URL) async throws {
        // Actor reentrancy note: an `await` suspension point here (waiting to un-pause)
        // is fine — the actor still serializes the FileManager work below, and `paused`
        // is only ever set while the drive is meant to be quiet.
        while paused { await waitForResume() }

        inFlight += 1
        defer { inFlight -= 1 }

        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) {
            _ = try fm.replaceItemAt(dest, withItemAt: temp)
        } else {
            try fm.moveItem(at: temp, to: dest)
        }
        flush(dest)                                   // file contents durable (the folder is never flushed — see `fullSync`)
    }

    /// Durable, serialized write of in-memory `data` to `dest` on the drive.
    ///
    /// Deliberately does NOT use `Data.write(options:.atomic)`: on an exFAT volume that creates a
    /// hidden `.sb-*` temp on the drive, and a brown-out mid-write leaves that orphan behind (the junk
    /// that was cluttering download folders) while the real file never lands. Instead it writes to a
    /// **controlled** `.pbtmp_*` temp (which the folder listing hides + sweeps), forces the bytes to
    /// media, then does a same-volume rename into place. So: no stray `.sb-*`, the payload is durable
    /// before the file becomes visible, and `dest` only ever appears complete — a partial download
    /// can't masquerade as a finished photo (a re-run correctly re-fetches it).
    func writeData(_ data: Data, to dest: URL, dates: (created: Date?, modified: Date?)? = nil) async throws {
        while paused { await waitForResume() }
        try performWrite(data, to: dest, dates: dates)
    }

    /// `writeData` that also **picks the file name inside the actor**: `name`, then `base 1.ext`,
    /// `base 2.ext`… — the first that doesn't exist. Several results saving into one folder at the
    /// same time (an AI batch's "Keep all") used to compute the same "unique" name in parallel and
    /// the second write clobbered the first; choosing the name and writing in one actor turn (no
    /// suspension in between) makes that impossible. Returns the URL actually written.
    func writeDataUnique(_ data: Data, named name: String, in folder: URL,
                         dates: (created: Date?, modified: Date?)? = nil) async throws -> URL {
        while paused { await waitForResume() }
        let dest = Self.uniqueURL(for: name, in: folder)
        try performWrite(data, to: dest, dates: dates)
        return dest
    }

    /// `name`, else `base 1.ext`, `base 2.ext`… (the AI folders' naming scheme).
    nonisolated static func uniqueURL(for name: String, in folder: URL) -> URL {
        let fm = FileManager.default
        var dest = folder.appendingPathComponent(name)
        let base = dest.deletingPathExtension().lastPathComponent, ext = dest.pathExtension
        var n = 1
        while fm.fileExists(atPath: dest.path) {
            dest = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return dest
    }

    private func performWrite(_ data: Data, to dest: URL, dates: (created: Date?, modified: Date?)?) throws {
        inFlight += 1
        defer { inFlight -= 1 }
        let fm = FileManager.default
        // The destination folder is created *inside* the actor (durably, see `createDirectory`), so
        // several callers saving into the same brand-new folder can't race to create it.
        try Self.createDirectory(at: dest.deletingLastPathComponent())
        let tmp = dest.deletingLastPathComponent().appendingPathComponent(".pbtmp_" + UUID().uuidString)
        do {
            try data.write(to: tmp)                       // plain write → no `.sb-*` atomic temp
            if let dates {
                // Stamp the temp so the final directory entry is written exactly once.
                var attrs: [FileAttributeKey: Any] = [:]
                if let c = dates.created { attrs[.creationDate] = c }
                if let m = dates.modified { attrs[.modificationDate] = m }
                if !attrs.isEmpty { try? fm.setAttributes(attrs, ofItemAtPath: tmp.path) }
            }
            Self.fullSync(tmp)                            // payload durable on media BEFORE it's named
            if fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) }
            try fm.moveItem(at: tmp, to: dest)            // same-volume rename = atomic
            flush(dest)
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
    }

    /// Syncs the whole volume at an inter-commit boundary. Because the actor runs one job at
    /// a time and this method has no interior `await`, it can only execute *between* commits —
    /// never mid-write — so when it runs, whatever committed last has already finished its
    /// `fsync`. This adds a whole-volume `sync()` on top (never a per-folder flush — see `fullSync`).
    ///
    /// Called on app-background as the lightweight "arm the safe state" step: it does NOT
    /// pause, so any active download window keeps committing at full speed; it just guarantees
    /// a flushed baseline the instant we background, in case the user then unplugs while
    /// suspended. The full drain (for a deliberate eject) is `pause()` + `waitUntilIdle()`.
    func quiesce(root: URL? = nil) {
        if root != nil { sync() }      // whole-volume sync — never a per-folder flush (see `fullSync`)
    }

    /// Awaits until no commit is in flight. After `pause()` no *new* commit can start
    /// (they block before incrementing `inFlight`), so this converges as soon as the one
    /// possibly-running commit finishes its move + `fsync`. Polls the actor's own state;
    /// commits are short, so this returns within a few tens of ms in practice.
    func waitUntilIdle() async {
        while inFlight > 0 {
            try? await Task.sleep(nanoseconds: 40_000_000)   // 40ms
        }
    }

    /// Blocks new commits until `resume()`. For the explicit eject flow only — call
    /// `quiesce()` afterwards to drain anything that was mid-flight when pause landed.
    func pause() { paused = true }

    /// Releases any commits waiting on `pause()` and lets new ones proceed.
    func resume() {
        paused = false
        let pending = waiters
        waiters.removeAll()
        for w in pending { w.resume() }
    }

    private func waitForResume() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            waiters.append(c)
        }
    }

    /// Best-effort full flush of a file or directory. Failure is non-fatal — some
    /// file-provider volumes don't permit opening a directory fd; the serialization
    /// alone still prevents overlapping directory writes.
    private func flush(_ url: URL) { Self.fullSync(url) }

    /// Force a **file** durable, using the strategy `syncMode` selected for this drive. Directories are
    /// deliberately skipped — never `fsync`/`F_FULLFSYNC` a folder on these drives:
    ///
    /// Field finding (Oct 2026): every folder iOS refused to open ("opendir errno 22", Drive Health's
    /// unreadable list) had been flushed as a *directory* right after it was created or while it was
    /// growing — the AI / Screenshots / Duplicate PNGs helper folders (`createDirectory` flushed each new
    /// level and every commit flushed the parent), the Kardashian member folders (a parent flush after
    /// each of 46k photos), Force Refresh (flushed the folder it re-read), and Mac tools that did the
    /// same (Safe Finder). The one Mac writer whose folders iOS always read — the copy rebuild — never
    /// flushes a folder. The drive root, flushed on every backgrounding, stayed fine: it has no record
    /// in a parent. This matches Apple's exFAT driver writing a stale copy of a folder's own record
    /// (size / cluster chain) into its parent when that folder is flushed (fsck: "Directory /X/AI has
    /// zero length"). So: file data is flushed; directory metadata is left to the driver, and the whole
    /// volume is synced with `sync()` at `quiesce` (backgrounding / eject).
    ///
    /// On exFAT/FAT (`.full`) this uses `F_FULLFSYNC`, **not** plain `fsync`: on Apple platforms
    /// `fsync` only pushes data to the drive's own write cache and returns — the drive may still hold
    /// it in volatile RAM, which for a no-journal volume is exactly where "clusters marked used but
    /// not referenced" corruption comes from on an unplug. `F_FULLFSYNC` commits that cache to stable
    /// storage. On APFS/HFS+ (`.barrier`) the filesystem is journaled/copy-on-write with atomic
    /// renames, so the cheaper `F_BARRIERFSYNC` ordering barrier gives the same crash-safety without
    /// F_FULLFSYNC's expensive physical flush. Both fall back to `fsync` on a volume that rejects the
    /// fcntl. `nonisolated static` so any write path (in-place edits, unzip, downloads) can flush
    /// without hopping onto the actor.
    nonisolated static func fullSync(_ url: URL) {
        var st = stat()
        guard stat(url.path, &st) == 0, (st.st_mode & S_IFMT) != S_IFDIR else { return }   // never a folder — see above
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return }
        let cmd: Int32 = (syncMode == .full) ? F_FULLFSYNC : F_BARRIERFSYNC
        if fcntl(fd, cmd) == -1 { fsync(fd) }
        close(fd)
    }

    /// Copy `src` → `dest`, preferring an APFS **clone** — an instant, zero-extra-space
    /// copy-on-write copy that `FileManager.copyItem` can't do. `clonefile` only works within one
    /// volume and when `dest` doesn't exist; every other case (cross-volume, non-APFS/exFAT, dest
    /// exists) returns nonzero and we fall back to a normal byte copy. It duplicates the file's
    /// bytes + metadata/xattrs exactly like `copyItem`, so provenance rides along; the app's
    /// path-keyed labels live in UserDefaults and are unaffected either way. Caller flushes.
    nonisolated static func copyItem(at src: URL, to dest: URL) throws {
        if clonefile(src.path, dest.path, 0) == 0 { return }
        try FileManager.default.copyItem(at: src, to: dest)
    }

    /// Create `dir` (and any missing parents). An existing directory costs one `stat`, so this is safe
    /// on hot paths. The new folders are **not** flushed: flushing a just-created folder is what left
    /// "zero length" AI folders iOS couldn't open (see `fullSync`).
    nonisolated static func createDirectory(at dir: URL) throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: dir.path, isDirectory: &isDir) {
            if isDir.boolValue { return }
            throw CocoaError(.fileWriteFileExists)
        }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// The folder named `name` inside `parent`, guaranteed to exist and be **readable on iOS** —
    /// created (flushed, via `createDirectory`) if missing.
    ///
    /// Why not just `createDirectory`: an old, damaged exFAT folder entry (e.g. a "zero length"
    /// `AI` directory from before `DriveWriter` existed) is listed by macOS but can't be stat'd by
    /// iOS. `fileExists` then says "no", the create fails with "file exists", and every save into
    /// that folder failed — which read as "new AI images / screenshots don't create their folder".
    /// Here such a name is skipped and the first usable "`name` 2", "`name` 3"… is used instead, so
    /// the files land somewhere visible; the damaged original still shows (flagged) in the grid.
    ///
    /// Only the leaf is ever created: `parent` must already exist. Creating missing ancestors (as
    /// `createDirectory` does) silently rebuilt a phantom copy of a folder that had been renamed or
    /// moved — or one under a previous mount path after the drive was replugged — so results landed
    /// somewhere the user would never look.
    nonisolated static func usableDirectory(named name: String, in parent: URL) throws -> URL {
        let fm = FileManager.default
        var parentIsDir: ObjCBool = false
        guard fm.fileExists(atPath: parent.path, isDirectory: &parentIsDir), parentIsDir.boolValue else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: parent.path])
        }
        var lastError: Error?
        for n in 1...30 {
            let dir = parent.appendingPathComponent(n == 1 ? name : "\(name) \(n)", isDirectory: true)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dir.path, isDirectory: &isDir) {
                if isDir.boolValue, isListable(dir) { return dir }
                continue                                   // a file of that name, or a folder iOS can't list
            }
            do {
                try createDirectory(at: dir)
            } catch {
                lastError = error
                if Self.isNameTaken(error) { continue }   // held by an entry iOS can't stat — try the next name
                throw error
            }
            // Field case (Oct 2026): iOS's exFAT driver sometimes can't open a folder it has itself just
            // created — the empty "AI" / "Screenshots" folders that Drive Health lists with
            // "opendir errno 22". Never hand such a folder back (every write into it fails), and never
            // move on to create "AI 2", "AI 3"… — they'd be just as unreadable and litter the drive.
            // Remove the empty folder we made and report the failure instead.
            if isListable(dir) { return dir }
            rmdir(dir.path)
            throw CocoaError(.fileWriteUnknown, userInfo: [
                NSFilePathErrorKey: dir.path,
                NSLocalizedDescriptionKey: "iOS created “\(dir.lastPathComponent)” but then couldn't open it — the drive needs attention on a Mac (see Drive Health)."])
        }
        throw lastError ?? CocoaError(.fileWriteUnknown)
    }

    /// Whether iOS can list `dir` — remembered once true, so repeated saves into a big folder don't
    /// re-list it every time.
    nonisolated private static func isListable(_ dir: URL) -> Bool {
        listableLock.lock()
        let known = listable.contains(dir.path)
        listableLock.unlock()
        if known { return true }
        guard (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) != nil else { return false }
        listableLock.lock(); listable.insert(dir.path); listableLock.unlock()
        return true
    }
    nonisolated(unsafe) private static var listable = Set<String>()
    nonisolated private static let listableLock = NSLock()

    /// "Something already has that name" — Cocoa's file-exists, or POSIX EEXIST underneath.
    nonisolated static func isNameTaken(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileWriteFileExistsError { return true }
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(EEXIST) { return true }
        if let under = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
           under.domain == NSPOSIXErrorDomain, under.code == Int(EEXIST) { return true }
        return false
    }

    /// Synchronous durable write for callers that can't `await` the actor: controlled `.pbtmp_` temp
    /// in the destination folder → payload flushed → same-volume rename → file + directory flushed.
    /// Not serialized against other commits (prefer the actor's `writeData` where possible), but the
    /// destination only ever appears complete and nothing is left half-written. `dates` are set on
    /// the temp so the final directory entry is written once.
    nonisolated static func writeDataSync(_ data: Data, to dest: URL, dates: (created: Date?, modified: Date?)? = nil) throws {
        let fm = FileManager.default
        try createDirectory(at: dest.deletingLastPathComponent())
        let tmp = dest.deletingLastPathComponent().appendingPathComponent(".pbtmp_" + UUID().uuidString)
        do {
            try data.write(to: tmp)
            if let dates {
                var attrs: [FileAttributeKey: Any] = [:]
                if let c = dates.created { attrs[.creationDate] = c }
                if let m = dates.modified { attrs[.modificationDate] = m }
                if !attrs.isEmpty { try? fm.setAttributes(attrs, ofItemAtPath: tmp.path) }
            }
            fullSync(tmp)
            if fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) }
            try fm.moveItem(at: tmp, to: dest)
            fullSyncFileAndParent(dest)
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
    }

    /// Flush a just-written file. (It used to flush the parent folder too; that is what made folders
    /// unreadable on iOS — see `fullSync` — so the name is historical.) Use from non-`commit` write
    /// paths (edits, unzip, service downloads, copies).
    nonisolated static func fullSyncFileAndParent(_ url: URL) {
        fullSync(url)
    }
}
