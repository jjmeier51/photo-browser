import Foundation

/// The repair side of Drive Health: rebuilding a folder iOS can't read, and probing a media file's
/// first bytes for the two exFAT failure signatures that a size check can't see. Everything here is
/// filesystem work on an external drive, so the enum is `nonisolated` and callers run it detached.
nonisolated enum DriveRepair {

    // MARK: - Rebuild a folder in place

    struct RebuildResult: Sendable {
        var copiedFiles = 0
        var copiedBytes: Int64 = 0
        var failed: [String] = []          // drive-relative paths that couldn't be copied
        var damagedURL: URL?               // where the original was parked after a successful swap
        var error: String?                 // a reason nothing was changed
        var swapped: Bool { damagedURL != nil }
    }

    /// Rebuilds `folder` **in place**: every entry is copied into a fresh hidden sibling folder
    /// (which gives exFAT a brand-new, compact directory — the fix for directories the iOS file
    /// provider chokes on), the copy is verified file-by-file against the source (count and byte
    /// size), and only then are the two swapped: the original is parked as `<name>.damaged`,
    /// the rebuilt copy takes the original's exact name and path. Because the path doesn't change,
    /// **every piece of app metadata keyed to the folder or anything inside it stays attached** —
    /// Favorites, captions, birthdays, covers, linked profiles, People, all of it — without any
    /// re-keying at all. Nothing is deleted: the parked original is reported for the user to remove
    /// once they're satisfied. Modification dates are carried over per file so the thumbnail and
    /// metadata caches (keyed `path|mtime|size`) stay warm.
    ///
    /// If any entry can't be read or copied, or the verification doesn't match, the temporary copy
    /// is removed and the original is left exactly as it was.
    nonisolated static func rebuildFolder(_ folder: URL, progress: @escaping @Sendable (Int, Int64) -> Void) async -> RebuildResult {
        await Task.detached(priority: .userInitiated) { () -> RebuildResult in
            let fm = FileManager.default
            var result = RebuildResult()
            let parent = folder.deletingLastPathComponent()
            let name = folder.lastPathComponent

            // 1. Inventory the source through the full fallback chain (coordinated → plain →
            //    enumerator → POSIX). A folder none of them can list can't be rebuilt from here.
            guard let plan = inventory(folder) else {
                result.error = "iOS can't list this folder by any method, so it can't be rebuilt from the phone. Re-copy it from the Mac — its name and place on the drive are what the app's metadata is attached to, so keep both."
                return result
            }
            guard !plan.files.isEmpty || !plan.directories.isEmpty else {
                result.error = "The folder reads as empty, so there's nothing to rebuild. If it shouldn't be empty, re-copy it from the Mac."
                return result
            }
            // 2. Room for a full second copy while both exist.
            let total = plan.files.reduce(Int64(0)) { $0 + $1.size }
            if let free = (try? parent.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage,
               free < total + 64 * 1024 * 1024 {
                result.error = "Not enough free space on the drive for a rebuilt copy (\(total.sizeString) needed, \(free.sizeString) free)."
                return result
            }

            // 3. Copy into a hidden sibling.
            let temp = parent.appendingPathComponent("." + name + ".rebuilding", isDirectory: true)
            try? fm.removeItem(at: temp)
            do { try fm.createDirectory(at: temp, withIntermediateDirectories: true) }
            catch { result.error = "Couldn't create a working folder next to it: \(error.localizedDescription)"; return result }

            for d in plan.directories {
                let dest = temp.appendingPathComponent(d, isDirectory: true)
                if (try? fm.createDirectory(at: dest, withIntermediateDirectories: true)) == nil { result.failed.append(d) }
            }
            var copied: Int64 = 0
            for f in plan.files {
                let src = folder.appendingPathComponent(f.relative)
                let dest = temp.appendingPathComponent(f.relative)
                do {
                    try fm.copyItem(at: src, to: dest)
                    if let m = f.modified { try? fm.setAttributes([.modificationDate: m], ofItemAtPath: dest.path) }
                    let size = (try? dest.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init) ?? -1
                    if size != f.size { result.failed.append(f.relative); try? fm.removeItem(at: dest) }
                    else { result.copiedFiles += 1; copied += f.size; result.copiedBytes = copied }
                } catch {
                    result.failed.append(f.relative)
                }
                if result.copiedFiles % 10 == 0 { progress(result.copiedFiles, copied) }
            }
            progress(result.copiedFiles, copied)

            // 4. Anything missing → leave the original untouched.
            guard result.failed.isEmpty else {
                try? fm.removeItem(at: temp)
                result.error = "\(result.failed.count) item\(result.failed.count == 1 ? "" : "s") couldn't be copied, so the folder was left exactly as it was. Those items are the ones to re-copy from the Mac."
                return result
            }

            // 5. Swap. The original is parked, never deleted.
            var damaged = parent.appendingPathComponent(name + ".damaged", isDirectory: true)
            var n = 2
            while fm.fileExists(atPath: damaged.path) { damaged = parent.appendingPathComponent("\(name).damaged \(n)", isDirectory: true); n += 1 }
            do { try fm.moveItem(at: folder, to: damaged) }
            catch {
                try? fm.removeItem(at: temp)
                result.error = "The copy is complete but the original couldn't be moved aside: \(error.localizedDescription). Nothing was changed."
                return result
            }
            do { try fm.moveItem(at: temp, to: folder) }
            catch {
                try? fm.moveItem(at: damaged, to: folder)      // put the original back
                try? fm.removeItem(at: temp)
                result.error = "The rebuilt copy couldn't take the folder's place: \(error.localizedDescription). The original was put back."
                return result
            }
            result.damagedURL = damaged
            return result
        }.value
    }

    private struct FilePlan: Sendable { let relative: String; let size: Int64; let modified: Date? }
    private struct Inventory: Sendable { var directories: [String] = []; var files: [FilePlan] = [] }

    /// Recursive listing of `folder` (relative paths), nil if the top level can't be read at all.
    /// Subfolders that can't be read are reported as failures by the caller's copy step — an
    /// unreadable subfolder appears here as a directory with no files, and its real contents would
    /// then be missing from the copy, so the verification below catches it: the directory's own
    /// enumeration is attempted again and a hard failure marks the rebuild as not possible.
    private nonisolated static func inventory(_ folder: URL) -> Inventory? {
        let fm = FileManager.default
        var inv = Inventory()
        var stack: [String] = [""]
        while let rel = stack.popLast() {
            let dir = rel.isEmpty ? folder : folder.appendingPathComponent(rel, isDirectory: true)
            var kids = Library.coordinatedContents(of: dir, keys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            if kids.isEmpty {
                // Empty, or unreadable? Ask directly; an error anywhere in the tree is fatal — a
                // rebuild that silently dropped a subfolder's files would be worse than no rebuild.
                do { kids = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) }
                catch { return nil }
            }
            for u in kids {
                let r = rel.isEmpty ? u.lastPathComponent : rel + "/" + u.lastPathComponent
                guard let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]) else {
                    return nil      // can't even stat it — not a folder to rebuild blind
                }
                if v.isDirectory == true { inv.directories.append(r); stack.append(r) }
                else { inv.files.append(FilePlan(relative: r, size: Int64(v.fileSize ?? 0), modified: v.contentModificationDate)) }
            }
        }
        return inv
    }

    // MARK: - Header probe (deep check)

    enum HeaderProblem: Sendable, Equatable {
        /// The file's first bytes are all zero: the size was allocated but the data never landed —
        /// the exFAT "interrupted copy" that a size check can't see.
        case blank
        /// The first bytes don't match what the extension promises (e.g. a .jpg that isn't a JPEG).
        /// Often a mislabelled-but-fine file; sometimes garbage.
        case mismatch(expected: String)
    }

    /// Reads the first 16 bytes of `url` and judges them. nil = fine, unknown type, or too small to say.
    nonisolated static func probeHeader(_ url: URL) -> HeaderProblem? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let data = try? h.read(upToCount: 16), data.count >= 12 else { return nil }
        let b = [UInt8](data)
        if b.allSatisfy({ $0 == 0 }) { return .blank }
        let ext = url.pathExtension.lowercased()
        func ascii(_ range: Range<Int>) -> String { String(bytes: b[range], encoding: .ascii) ?? "" }
        let isFtyp = ascii(4..<8) == "ftyp"
        switch ext {
        case "jpg", "jpeg":
            return (b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) ? nil : .mismatch(expected: "JPEG")
        case "png":
            return (b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) ? nil : .mismatch(expected: "PNG")
        case "gif":
            return ascii(0..<4) == "GIF8" ? nil : .mismatch(expected: "GIF")
        case "heic", "heif", "avif", "mp4", "m4v", "mov", "3gp", "cr3":
            return isFtyp ? nil : .mismatch(expected: ext == "mov" ? "QuickTime" : ext.uppercased())
        case "webp":
            return (ascii(0..<4) == "RIFF" && ascii(8..<12) == "WEBP") ? nil : .mismatch(expected: "WebP")
        case "tif", "tiff", "dng", "nef", "arw", "cr2":
            let le = b[0] == 0x49 && b[1] == 0x49 && b[2] == 0x2A && b[3] == 0x00
            let be = b[0] == 0x4D && b[1] == 0x4D && b[2] == 0x00 && b[3] == 0x2A
            return (le || be) ? nil : .mismatch(expected: ext == "tif" || ext == "tiff" ? "TIFF" : ext.uppercased())
        default:
            return nil
        }
    }
}
