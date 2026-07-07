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
actor DriveWriter {
    static let shared = DriveWriter()

    /// Atomically moves `temp` to `dest` (replacing an existing file), then flushes the
    /// new file and its parent directory. Serialized against every other commit.
    func commit(_ temp: URL, to dest: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) {
            _ = try fm.replaceItemAt(dest, withItemAt: temp)
        } else {
            try fm.moveItem(at: temp, to: dest)
        }
        flush(dest)                                   // file contents durable…
        flush(dest.deletingLastPathComponent())       // …and the directory entry that names it
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
