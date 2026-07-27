import Foundation

/// Collects timestamped diagnostic lines for one download run and writes them to a
/// `<kind>-log.txt` file **in the download folder**, so a run's decisions and failures can be
/// inspected afterwards and shared.
///
/// Two hard-won details:
/// * **Write through `DriveWriter.writeData`, not a raw cross-volume `moveItem`.** The drive is
///   usually a file-provider / exFAT volume; a plain `FileManager.moveItem` from the app's temp dir
///   into it silently fails there (no coordination), which is why the log never appeared even though
///   the downloaded files — which go through `DriveWriter` — landed fine. `writeData` does the same
///   safe same-volume `.pbtmp_*` write + fsync + rename the file downloads use.
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

    /// Buffers one timestamped line and flushes to disk every so often, so a run that's killed
    /// mid-way still leaves a partial log.
    func log(_ s: String) async {
        lines.append("\(Self.time.string(from: Date()))  \(s)")
        if lines.count - flushedAt >= 25 { await flushToDisk() }
    }

    /// Appends an optional final summary and writes the whole log to the folder.
    func finish(_ summary: String? = nil) async {
        if let summary { lines.append("\(Self.time.string(from: Date()))  SUMMARY: \(summary)") }
        await flushToDisk()
    }

    /// Rewrites the accumulated log to `<folder>/<kind>-log.txt` via `DriveWriter` (durable,
    /// serialized, file-provider-safe). Records the line count so `log` only reflushes on new lines.
    private func flushToDisk() async {
        let text = ([header] + lines).filter { !$0.isEmpty }.joined(separator: "\n") + "\n"
        guard let data = text.data(using: .utf8) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dest = folder.appendingPathComponent("\(kind)-log.txt")
        do {
            try await DriveWriter.shared.writeData(data, to: dest)
            flushedAt = lines.count
        } catch {}
    }
}
