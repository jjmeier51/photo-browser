import Foundation

/// Collects timestamped diagnostic lines for one download run and writes them to a
/// `<kind>-log.txt` file **in the download folder**, so a run's decisions and failures can be
/// inspected afterwards and shared.
///
/// Two hard-won details:
/// * **Write the log directly in place — do NOT route it through `DriveWriter.writeData`.** That
///   method writes a controlled `.pbtmp_*` temp *on the drive* and then renames it over the existing
///   file; on a userspace (FSKit) external volume that rename was silently failing (the log's
///   best-effort `try?` swallowed it), so every rewrite was lost and the folder kept showing a stale
///   log from an *older* run — even though the media downloads, which use `DriveWriter.commit`
///   (a plain `moveItem`/`replaceItemAt`), landed fine. A diagnostic log doesn't need the anti-tear
///   rename dance (a half-written log is fine — it's fully rewritten on the next flush), so a plain
///   overwrite of the final file is both simpler and what actually lands here. `writeData` is kept
///   only as a last-resort fallback in case a future volume rejects the direct overwrite instead.
/// * **Flush incrementally, not once at the end.** A big run under memory/disk pressure can be
///   jetsam-killed before it finishes, and a buffer-then-write-once log would be lost with it. So we
///   rewrite the whole (small) log every so often and on `finish`. Rewriting via `writeData` holds
///   no file handle open on the drive, so it doesn't reintroduce the exFAT directory-churn the
///   original once-only design was avoiding. Best-effort throughout; a logging failure never touches
///   the download.
actor DownloadLog {
    private let folder: URL
    private let kind: String
    private var header = ""
    private var lines: [String] = []
    private var flushedAt = -1        // `lines.count` at the last successful flush (-1 = never)
    private var lastFlush = Date.distantPast

    private static let time: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()
    private static let full: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f
    }()

    init(folder: URL, kind: String) {
        self.folder = folder
        self.kind = kind
    }

    /// Records the dated session header + opening line, and writes the file immediately so it
    /// exists (with just the header) from the start of the run. Call once, first.
    func begin(_ header: String) async {
        self.header = "===== \(Self.full.string(from: Date())) — \(header) ====="
        await flushToDisk()
    }

    /// Buffers one timestamped line and flushes to disk periodically — often enough that a killed
    /// run leaves a useful partial log, but rarely enough that its durable drive-fsync doesn't
    /// contend with (and slow) the downloads themselves. Bounded by both time and line count.
    func log(_ s: String) async {
        lines.append("\(Self.time.string(from: Date()))  \(s)")
        if Date().timeIntervalSince(lastFlush) >= 10 || lines.count - flushedAt >= 400 {
            await flushToDisk()
        }
    }

    /// Appends an optional final summary and writes the whole log to the folder.
    func finish(_ summary: String? = nil) async {
        if let summary { lines.append("\(Self.time.string(from: Date()))  SUMMARY: \(summary)") }
        await flushToDisk()
    }

    /// Rewrites the accumulated log to `<folder>/<kind>-log.txt` with a plain in-place overwrite
    /// (see the type doc for why the durable temp+rename path is deliberately avoided here — it was
    /// silently dropping the log on a userspace/FSKit drive). Records the line count so `log` only
    /// reflushes on new lines.
    private func flushToDisk() async {
        guard flushedAt < lines.count else { return }        // nothing new since the last flush
        let text = ([header] + lines).filter { !$0.isEmpty }.joined(separator: "\n") + "\n"
        guard let data = text.data(using: .utf8) else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let dest = folder.appendingPathComponent("\(kind)-log.txt")
        do {
            // Write and fsync on ONE file handle, then close. An earlier version used
            // `Data.write` followed by a separate open-for-fsync; on a userspace (FSKit) drive that
            // left the file visible at 0 bytes — the bytes sat in the filesystem cache and fsync on
            // a *different* descriptor didn't push them. Truncating + writing + `synchronize()` on
            // the same handle commits the bytes before it closes. No temp + rename — that step was
            // what silently dropped the log here in the first place.
            if !fm.fileExists(atPath: dest.path) { fm.createFile(atPath: dest.path, contents: nil) }
            let fh = try FileHandle(forWritingTo: dest)
            do {
                try fh.truncate(atOffset: 0)
                try fh.write(contentsOf: data)
                try fh.synchronize()
                try fh.close()
            } catch { try? fh.close(); throw error }
            flushedAt = lines.count
            lastFlush = Date()
        } catch {
            // Last resort: the durable temp+rename path, in case a volume rejects the direct write.
            do {
                try await DriveWriter.shared.writeData(data, to: dest)
                flushedAt = lines.count
                lastFlush = Date()
            } catch {}
        }
    }
}
