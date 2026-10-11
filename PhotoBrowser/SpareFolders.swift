import Foundation
import Darwin

/// Ready-made empty folders whose *list of contents* sits below 2.2 TB on the SSD — every folder the
/// app creates on the drive is made from one of these.
///
/// Why: iOS's exFAT driver misreads a folder whose list (its exFAT directory data) lies more than
/// 2^32 × 512 bytes = 2.20 TB into the drive — the folder fails with "Invalid argument", shows
/// nothing, or shows stale items — and nearly all of the 8 TB SSD's free space is past that point, so
/// a folder created the usual way usually lands there (CLAUDE.md, constraint 12). iOS gives an app no
/// say in where a new folder goes, but renaming or moving a folder never moves its list. So the Mac
/// tool `mac/relocate_folders.py --spares N` keeps N empty folders in `<drive>/.Spare Folders` with
/// their lists below the line, and `DriveWriter.createDirectory` makes a folder by *renaming a spare
/// into place* — with POSIX `rename`, which can never quietly turn into a copy. When the pool is empty
/// (or the drive has none) the folder is made the usual way and counted, so Drive Health can say to top
/// the pool up on the Mac, which also moves those folders' lists below the line.
///
/// `nonisolated`: called from every write path, off the main actor. The lock serializes taking spares
/// so two saves can't grab the same one.
nonisolated enum SpareFolders {
    static let poolName = ".Spare Folders"
    private static let plainKey = "photoBrowser.foldersWithoutSpare"
    private static let lock = NSLock()
    /// The drive root being browsed (set alongside `DriveWriter.configureForVolume`). Only folders under
    /// it use spares — app-container folders never do. Written rarely on the main actor, read under `lock`.
    nonisolated(unsafe) private static var root: URL?

    static func configure(root url: URL) {
        lock.lock(); defer { lock.unlock() }
        root = url.standardizedFileURL
    }

    private static func currentRoot() -> URL? {
        lock.lock(); defer { lock.unlock() }
        return root
    }

    /// A path compared without the "/private" that iOS adds to or drops from "/var/…" depending on how
    /// a URL was made — otherwise the same folder could look like it's not on the drive.
    private static func comparable(_ url: URL) -> String {
        let p = url.standardizedFileURL.path
        return p.hasPrefix("/private/") ? String(p.dropFirst("/private".count)) : p
    }

    /// Whether `dir` is a folder on the browsed drive (outside the pool itself).
    static func isOnDrive(_ dir: URL) -> Bool {
        guard let root = currentRoot() else { return false }
        let d = comparable(dir), r = comparable(root)
        let pool = comparable(root.appendingPathComponent(poolName))
        return d.hasPrefix(r + "/") && d != pool && !d.hasPrefix(pool + "/")
    }

    /// The pool for a new folder at `dir`, when `dir` is on the browsed drive and the drive has one.
    static func pool(for dir: URL) -> URL? {
        guard isOnDrive(dir), let root = currentRoot() else { return nil }
        let pool = root.appendingPathComponent(poolName, isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: pool.path, isDirectory: &isDir), isDir.boolValue else { return nil }
        return pool
    }

    /// The pool's candidate names, oldest first (each still has to pass `isSpare`).
    private static func names(in pool: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: pool.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }

    /// Whether `url` is a usable spare: an empty folder (a stray .DS_Store or "._" file doesn't count).
    private static func isSpare(_ url: URL) -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue,
              let inside = try? fm.contentsOfDirectory(atPath: url.path) else { return false }
        return inside.allSatisfy { $0 == ".DS_Store" || $0.hasPrefix("._") }
    }

    /// The pool's ready spares, oldest name first. Checks every one — for counting, not for taking.
    static func spares(in pool: URL) -> [URL] {
        names(in: pool).map { pool.appendingPathComponent($0, isDirectory: true) }.filter(isSpare)
    }

    /// Spares left on the browsed drive; nil when it has no pool. Reads the drive — call off main.
    static func remaining() -> Int? {
        guard let root = currentRoot() else { return nil }
        let pool = root.appendingPathComponent(poolName, isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: pool.path, isDirectory: &isDir), isDir.boolValue else { return nil }
        return spares(in: pool).count
    }

    /// Make the folder `dir` (which must not exist; its parent must) by renaming a spare into place.
    /// False when there's no pool, it's empty, or the rename can't be done — make it the usual way then.
    static func take(as dir: URL) -> Bool {
        guard let pool = pool(for: dir) else { return false }
        lock.lock(); defer { lock.unlock() }
        for name in names(in: pool) {               // stop at the first usable one — each check reads the drive
            let spare = pool.appendingPathComponent(name, isDirectory: true)
            guard isSpare(spare) else { continue }
            if Darwin.rename(spare.path, dir.path) == 0 {
                let now = Date()       // today's dates, not the day the spare was made on the Mac
                try? FileManager.default.setAttributes([.creationDate: now, .modificationDate: now], ofItemAtPath: dir.path)
                return true
            }
            if errno == ENOENT { continue }      // taken a moment ago — try the next
            break                                // anything else (another volume…) — make it the usual way
        }
        return false
    }

    /// Folders made on the drive without a spare since the count was last cleared.
    static var madeWithoutSpare: Int { UserDefaults.standard.integer(forKey: plainKey) }

    /// Count a folder made on the exFAT drive without a spare (its list may sit past 2.2 TB).
    static func notePlain(_ dir: URL) {
        guard DriveWriter.syncMode == .full, isOnDrive(dir) else { return }   // only exFAT/FAT drives
        lock.lock(); defer { lock.unlock() }
        UserDefaults.standard.set(madeWithoutSpare + 1, forKey: plainKey)
    }

    static func clearMadeWithoutSpare() { UserDefaults.standard.removeObject(forKey: plainKey) }
}
