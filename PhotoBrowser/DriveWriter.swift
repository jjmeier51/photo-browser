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
        flush(dest)                                   // file contents durable…
        // …and, on exFAT/FAT, the directory entry that names it. APFS/HFS+ journal the rename with
        // its metadata, so the separate directory flush is redundant there.
        if Self.syncMode == .full { flush(dest.deletingLastPathComponent()) }
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
    func writeData(_ data: Data, to dest: URL) async throws {
        while paused { await waitForResume() }
        inFlight += 1
        defer { inFlight -= 1 }
        let fm = FileManager.default
        let tmp = dest.deletingLastPathComponent().appendingPathComponent(".pbtmp_" + UUID().uuidString)
        do {
            try data.write(to: tmp)                       // plain write → no `.sb-*` atomic temp
            Self.fullSync(tmp)                            // payload durable on media BEFORE it's named
            if fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) }
            try fm.moveItem(at: tmp, to: dest)            // same-volume rename = atomic
            flush(dest)
            if Self.syncMode == .full { flush(dest.deletingLastPathComponent()) }
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
    }

    /// Flushes the drive root at an inter-commit boundary. Because the actor runs one job at
    /// a time and this method has no interior `await`, it can only execute *between* commits —
    /// never mid-write — so when it runs, whatever committed last has already finished its
    /// `fsync`. This adds a final flush of the volume root on top.
    ///
    /// Called on app-background as the lightweight "arm the safe state" step: it does NOT
    /// pause, so any active download window keeps committing at full speed; it just guarantees
    /// a flushed baseline the instant we background, in case the user then unplugs while
    /// suspended. The full drain (for a deliberate eject) is `pause()` + `waitUntilIdle()`.
    func quiesce(root: URL? = nil) {
        if let root { flush(root) }
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

    /// Force a file (or directory) durable, using the strategy `syncMode` selected for this drive.
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

    /// Flush a just-written file, plus (on exFAT/FAT) the directory entry that names it — the pair
    /// that must agree for a no-journal volume to stay consistent. On APFS/HFS+ the rename is
    /// journaled with its metadata, so only the file is flushed. Use from non-`commit` write paths
    /// (edits, unzip, service downloads, copies).
    nonisolated static func fullSyncFileAndParent(_ url: URL) {
        fullSync(url)
        if syncMode == .full { fullSync(url.deletingLastPathComponent()) }
    }
}
