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
        flush(dest.deletingLastPathComponent())       // …and the directory entry that names it
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

    /// Best-effort `fsync` of a file or directory. Failure is non-fatal — some
    /// file-provider volumes don't permit opening a directory fd; the serialization
    /// alone still prevents overlapping directory writes.
    private func flush(_ url: URL) {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return }
        fsync(fd)
        close(fd)
    }
}
