import Foundation
import Compression

/// Zip / unzip for the browser and folder view, using **only Apple frameworks** (no third-party
/// zip library, per the project's no-dependencies rule).
///
/// * **Zipping** goes through `NSFileCoordinator`'s `.forUploading` option — the documented way to
///   produce a `.zip` of a file or folder on iOS. It's a verbatim byte copy of the contents, so any
///   embedded EXIF/metadata is preserved exactly.
/// * **Unzipping** parses the ZIP container by hand (End-of-Central-Directory → central directory →
///   local headers) and inflates each entry's raw DEFLATE stream with the `Compression` framework
///   (`COMPRESSION_ZLIB` = raw RFC-1951, which is what ZIP stores). Extracted bytes are written
///   verbatim, so EXIF survives, and each file's modification date is restored from the entry's DOS
///   timestamp. `Foundation` has no public unzip API, hence the manual reader.
///
/// Everything is `nonisolated` — it's file I/O + decompression and must stay off the main actor
/// (call it from `Task.detached`). Best-effort on exotic archives: ZIP64 and encrypted entries
/// aren't handled and surface as a thrown error rather than a crash.
enum Archiver {
    enum ArchiveError: LocalizedError {
        case notAZip, unsupportedEntry(String), corrupt
        var errorDescription: String? {
            switch self {
            case .notAZip: return "That file isn’t a readable .zip archive."
            case .unsupportedEntry(let n): return "“\(n)” uses an unsupported compression or is encrypted."
            case .corrupt: return "The archive is incomplete or corrupt."
            }
        }
    }

    // MARK: - Zip

    /// Zip a single file or folder to `dest` (overwriting). The archive's top entry is `source`'s
    /// name (a folder zips as a tree).
    nonisolated static func zip(_ source: URL, to dest: URL) throws {
        let coordinator = NSFileCoordinator()
        var coordErr: NSError?
        var thrown: Error?
        coordinator.coordinate(readingItemAt: source, options: [.forUploading], error: &coordErr) { tmpZip in
            do {
                if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
                try FileManager.default.copyItem(at: tmpZip, to: dest)
                DriveWriter.fullSyncFileAndParent(dest)
            } catch { thrown = error }
        }
        if let e = coordErr { throw e }
        if let e = thrown { throw e }
    }

    /// Zip several items into one archive at `dest`. They're staged under a `stagingName` folder
    /// (so the archive contains `stagingName/…`) and that folder is zipped.
    nonisolated static func zip(items: [URL], to dest: URL, stagingName: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let staging = root.appendingPathComponent(stagingName, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for item in items {
            var d = staging.appendingPathComponent(item.lastPathComponent)
            var n = 1
            while FileManager.default.fileExists(atPath: d.path) {
                let base = item.deletingPathExtension().lastPathComponent, ext = item.pathExtension
                d = staging.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
                n += 1
            }
            try FileManager.default.copyItem(at: item, to: d)
        }
        try zip(staging, to: dest)
    }

    // MARK: - Unzip

    private struct CDEntry {
        let name: String, method: Int, compSize: Int, uncompSize: Int, localOffset: Int, mtime: Int, mdate: Int
    }

    /// Extract `archive` into `destDir` (created if needed), reporting 0…1 progress per entry.
    nonisolated static func unzip(_ archive: URL, to destDir: URL, progress: (@Sendable (Double) -> Void)? = nil) throws {
        // The archive lives on the security-scoped external drive — claim access for the read (the
        // root's access usually covers it, but claiming the file directly is safe on exFAT/file-provider).
        let scoped = archive.startAccessingSecurityScopedResource()
        defer { if scoped { archive.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: archive)
        let entries = try centralDirectory(data)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        let total = max(entries.count, 1)
        for (i, e) in entries.enumerated() {
            // Skip macOS resource-fork sidecars that clutter every Finder-made zip.
            if !e.name.hasPrefix("__MACOSX/") { try extract(e, from: data, into: destDir) }
            progress?(Double(i + 1) / Double(total))
        }
    }

    private nonisolated static func centralDirectory(_ data: Data) throws -> [CDEntry] {
        guard data.count >= 22 else { throw ArchiveError.notAZip }
        // Find the End-of-Central-Directory record by scanning back from the end (its variable-length
        // comment means it isn't at a fixed offset).
        let eocdSig = 0x06054b50, cdSig = 0x02014b50
        var i = data.count - 22
        let minI = max(0, data.count - 22 - 0xFFFF)
        while i >= minI, le32(data, i) != eocdSig { i -= 1 }
        guard i >= minI, le32(data, i) == eocdSig else { throw ArchiveError.notAZip }
        var count = le16(data, i + 10)
        var cdOffset = le32(data, i + 16)
        // ZIP64 (archives >4 GB or >65535 entries — likely for a big SSD zip): the EOCD holds
        // 0xFFFF/0xFFFFFFFF placeholders and the real values live in the ZIP64 EOCD, located via the
        // ZIP64 locator that sits just before the regular EOCD.
        if count == 0xFFFF || cdOffset == 0xFFFFFFFF {
            let locOff = i - 20
            if locOff >= 0, le32(data, locOff) == 0x07064b50 {
                let z64 = le64(data, locOff + 8)
                if z64 >= 0, z64 + 56 <= data.count, le32(data, z64) == 0x06064b50 {
                    count = le64(data, z64 + 32)
                    cdOffset = le64(data, z64 + 48)
                }
            }
        }
        guard cdOffset >= 0, cdOffset < data.count else { throw ArchiveError.corrupt }

        var p = cdOffset
        var entries: [CDEntry] = []
        for _ in 0..<count {
            guard p + 46 <= data.count, le32(data, p) == cdSig else { break }
            let method = le16(data, p + 10)
            let mtime = le16(data, p + 12), mdate = le16(data, p + 14)
            var compSize = le32(data, p + 20)
            var uncompSize = le32(data, p + 24)
            let nameLen = le16(data, p + 28)
            let extraLen = le16(data, p + 30)
            let commentLen = le16(data, p + 32)
            var localOff = le32(data, p + 42)
            guard p + 46 + nameLen + extraLen <= data.count else { throw ArchiveError.corrupt }
            let nameData = data.subdata(in: (p + 46)..<(p + 46 + nameLen))
            let name = String(data: nameData, encoding: .utf8) ?? String(decoding: nameData, as: UTF8.self)
            // Per-entry ZIP64 extra field overrides any 0xFFFFFFFF size/offset placeholder.
            if compSize == 0xFFFFFFFF || uncompSize == 0xFFFFFFFF || localOff == 0xFFFFFFFF {
                zip64Extra(data, at: p + 46 + nameLen, len: extraLen,
                           uncomp: &uncompSize, comp: &compSize, localOff: &localOff)
            }
            entries.append(CDEntry(name: name, method: method, compSize: compSize, uncompSize: uncompSize,
                                   localOffset: localOff, mtime: mtime, mdate: mdate))
            p += 46 + nameLen + extraLen + commentLen
        }
        guard !entries.isEmpty else { throw ArchiveError.corrupt }
        return entries
    }

    /// Read the ZIP64 extended-information extra field (id 0x0001), filling in only the fields that
    /// were 0xFFFFFFFF placeholders, in the spec's order: uncompressed, compressed, local offset.
    private nonisolated static func zip64Extra(_ data: Data, at extraStart: Int, len: Int,
                                               uncomp: inout Int, comp: inout Int, localOff: inout Int) {
        var p = extraStart
        let extraEnd = extraStart + len
        while p + 4 <= extraEnd {
            let id = le16(data, p), size = le16(data, p + 2)
            let fieldStart = p + 4, fieldEnd = min(fieldStart + size, extraEnd)
            if id == 0x0001 {
                var q = fieldStart
                if uncomp == 0xFFFFFFFF, q + 8 <= fieldEnd { uncomp = le64(data, q); q += 8 }
                if comp == 0xFFFFFFFF, q + 8 <= fieldEnd { comp = le64(data, q); q += 8 }
                if localOff == 0xFFFFFFFF, q + 8 <= fieldEnd { localOff = le64(data, q) }
                return
            }
            p = fieldStart + size
        }
    }

    private nonisolated static func extract(_ e: CDEntry, from data: Data, into destDir: URL) throws {
        guard let rel = safeRelativePath(e.name) else { return }        // drop absolute / "../" traversal
        let isDir = e.name.hasSuffix("/")
        let outURL = destDir.appendingPathComponent(rel, isDirectory: isDir)
        if isDir {
            try? FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)
            applyDate(e, to: outURL)
            return
        }
        guard e.localOffset + 30 <= data.count, le32(data, e.localOffset) == 0x04034b50 else { throw ArchiveError.corrupt }
        let nameLen = le16(data, e.localOffset + 26)
        let extraLen = le16(data, e.localOffset + 28)
        let start = e.localOffset + 30 + nameLen + extraLen
        let end = start + e.compSize
        guard start >= 0, end <= data.count, start <= end else { throw ArchiveError.corrupt }
        let payload = data.subdata(in: start..<end)

        let raw: Data
        switch e.method {
        case 0:  raw = payload                                          // stored, no compression
        case 8:  guard let inf = inflate(payload, expected: e.uncompSize) else { throw ArchiveError.corrupt }; raw = inf
        default: throw ArchiveError.unsupportedEntry(e.name)
        }
        let parent = outURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        DriveWriter.fullSync(parent)                                    // commit the new dir before writing into it
        try writeFile(raw, to: outURL)                                  // verbatim bytes → EXIF intact
        applyDate(e, to: outURL)
        DriveWriter.fullSyncFileAndParent(outURL)                       // durable per file — no leaked clusters on unplug
    }

    /// Write extracted bytes to the drive. Uses a **non-atomic** write: `Data.write(options:.atomic)`
    /// creates a hidden temp in the same directory and renames it, and that temp/rename step is
    /// exactly what an exFAT/file-provider volume rejects (surfacing as "couldn't be saved in the
    /// folder"). A direct write, with an explicit file-handle fallback, is what these volumes accept.
    private nonisolated static func writeFile(_ data: Data, to url: URL) throws {
        do {
            try data.write(to: url)
        } catch {
            try? FileManager.default.removeItem(at: url)
            guard FileManager.default.createFile(atPath: url.path, contents: nil),
                  let h = try? FileHandle(forWritingTo: url) else { throw error }
            defer { try? h.close() }
            try h.write(contentsOf: data)
        }
    }

    /// True when the file starts with a ZIP local/EOCD/spanned signature ("PK…"), regardless of its
    /// extension — a download saved without a `.zip` suffix (shown as a "data" file) is still a zip.
    /// Reads only the first 4 bytes.
    nonisolated static func isZip(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        guard let s = try? h.read(upToCount: 4), s.count == 4 else { return false }
        return s[0] == 0x50 && s[1] == 0x4B && (s[2] == 0x03 || s[2] == 0x05 || s[2] == 0x07)
    }

    // MARK: - Inflate (raw DEFLATE via Compression)

    /// Inflate a ZIP method-8 (raw DEFLATE) payload. Uses the streaming API — the same approach
    /// shipping ZIP libraries rely on — because the one-shot `compression_decode_buffer` can return
    /// short/incorrect results on some streams. Validates against the expected size when known.
    private nonisolated static func inflate(_ input: Data, expected: Int) -> Data? {
        guard let out = inflateStreaming(input) else { return nil }
        if expected > 0, out.count != expected { return nil }
        return out
    }

    /// Streaming fallback when the uncompressed size isn't known up front (data-descriptor entries).
    private nonisolated static func inflateStreaming(_ input: Data) -> Data? {
        guard !input.isEmpty else { return Data() }
        let streamPtr = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { streamPtr.deallocate() }
        guard compression_stream_init(streamPtr, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { return nil }
        defer { compression_stream_destroy(streamPtr) }
        let bufSize = 64 * 1024
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { dst.deallocate() }
        return input.withUnsafeBytes { (srcRaw: UnsafeRawBufferPointer) -> Data? in
            guard let src = srcRaw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            streamPtr.pointee.src_ptr = src
            streamPtr.pointee.src_size = input.count
            var output = Data()
            while true {
                streamPtr.pointee.dst_ptr = dst
                streamPtr.pointee.dst_size = bufSize
                let status = compression_stream_process(streamPtr, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = bufSize - streamPtr.pointee.dst_size
                output.append(dst, count: produced)
                switch status {
                case COMPRESSION_STATUS_END: return output
                case COMPRESSION_STATUS_OK:  if produced == 0 { return nil }   // no progress → malformed
                default:                     return nil
                }
            }
        }
    }

    // MARK: - Helpers

    private nonisolated static func le16(_ d: Data, _ o: Int) -> Int { Int(d[d.startIndex + o]) | (Int(d[d.startIndex + o + 1]) << 8) }
    private nonisolated static func le32(_ d: Data, _ o: Int) -> Int {
        let b = d.startIndex + o
        return Int(d[b]) | (Int(d[b + 1]) << 8) | (Int(d[b + 2]) << 16) | (Int(d[b + 3]) << 24)
    }
    private nonisolated static func le64(_ d: Data, _ o: Int) -> Int {
        let b = d.startIndex + o
        var v = 0
        for k in 0..<8 { v |= Int(d[b + k]) << (8 * k) }
        return v
    }

    /// Reject path-traversal / absolute names; return a clean relative path or nil to skip the entry.
    private nonisolated static func safeRelativePath(_ name: String) -> String? {
        let comps = name.split(separator: "/").map(String.init)
        if comps.contains("..") { return nil }
        let cleaned = comps.filter { !$0.isEmpty && $0 != "." }
        return cleaned.isEmpty ? nil : cleaned.joined(separator: "/")
    }

    private nonisolated static func applyDate(_ e: CDEntry, to url: URL) {
        guard let date = dosDate(time: e.mtime, date: e.mdate) else { return }
        try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    /// Convert a ZIP/DOS date+time pair into a `Date` (local time, per the format).
    private nonisolated static func dosDate(time: Int, date: Int) -> Date? {
        guard date != 0 else { return nil }
        var c = DateComponents()
        c.second = (time & 0x1F) * 2
        c.minute = (time >> 5) & 0x3F
        c.hour   = (time >> 11) & 0x1F
        c.day    = date & 0x1F
        c.month  = (date >> 5) & 0x0F
        c.year   = ((date >> 9) & 0x7F) + 1980
        return Calendar(identifier: .gregorian).date(from: c)
    }
}
