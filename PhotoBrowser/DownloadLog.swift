import Foundation

/// Appends timestamped diagnostic lines to a `<kind>-log.txt` file **in the download
/// folder**, so a run's decisions and failures can be inspected after the fact and shared.
///
/// An actor, so the many concurrent download tasks serialize their writes instead of
/// interleaving. Writes are buffered and flushed in chunks (and on `finish`) via a single
/// appending file handle — appending to one growing file is safe on exFAT (unlike the
/// concurrent *new-file* churn `DriveWriter` guards), and keeps log I/O off the hot path.
/// Every call is best-effort and never throws into the download flow. Successive runs
/// append under a dated session header, so recent history is preserved.
actor DownloadLog {
    private let url: URL
    private var handle: FileHandle?
    private var buffer = Data()

    private static let time: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()
    private static let full: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f
    }()

    init(folder: URL, kind: String) {
        url = folder.appendingPathComponent("\(kind)-log.txt")
    }

    /// Writes the dated session header + an opening line. Call once, first.
    func begin(_ header: String) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        write("\n===== \(Self.full.string(from: Date())) — \(header) =====")
    }

    /// Appends one timestamped line.
    func log(_ s: String) { write(s) }

    /// Appends an optional final summary and flushes/closes.
    func finish(_ summary: String? = nil) {
        if let summary { write("SUMMARY: \(summary)") }
        flush()
        try? handle?.close()
        handle = nil
    }

    private func write(_ s: String) {
        buffer.append(Data("\(Self.time.string(from: Date()))  \(s)\n".utf8))
        if buffer.count >= 4096 { flush() }
    }

    private func flush() {
        guard !buffer.isEmpty else { return }
        if handle == nil {
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            handle = try? FileHandle(forWritingTo: url)
            try? handle?.seekToEnd()
        }
        try? handle?.write(contentsOf: buffer)
        buffer.removeAll(keepingCapacity: true)
    }
}
