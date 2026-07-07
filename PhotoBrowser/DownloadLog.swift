import Foundation

/// Collects timestamped diagnostic lines for one download run and writes them to a
/// `<kind>-log.txt` file **in the download folder** exactly once, at the end — so a run's
/// decisions and failures can be inspected afterwards and shared.
///
/// Why buffer-then-write-once: the drive is usually a file-provider/exFAT volume, and
/// *repeated* coordinated writes to a held-open file (FileHandle/createFile) leave `.sb-…`
/// staging items that exFAT can corrupt into unopenable "folders". So we accumulate lines
/// in memory (an actor, so concurrent download tasks don't race), then on `finish` write the
/// whole thing to the app's temp dir and do a single `removeItem`+`moveItem` onto the drive
/// — one plain file, no held handle, no atomic-replace staging. Best-effort throughout; a
/// logging failure never touches the download. Trade-off: a crash mid-run loses the log.
actor DownloadLog {
    private let folder: URL
    private let kind: String
    private var header = ""
    private var lines: [String] = []

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

    /// Records the dated session header + opening line. Call once, first.
    func begin(_ header: String) {
        self.header = "===== \(Self.full.string(from: Date())) — \(header) ====="
    }

    /// Buffers one timestamped line (in memory; nothing is written until `finish`).
    func log(_ s: String) {
        lines.append("\(Self.time.string(from: Date()))  \(s)")
    }

    /// Appends an optional final summary and writes the whole log to the folder in one shot.
    func finish(_ summary: String? = nil) {
        if let summary { log("SUMMARY: \(summary)") }
        let text = ([header] + lines).filter { !$0.isEmpty }.joined(separator: "\n") + "\n"
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        // Write to app-local temp (fast, no drive coordination), then a single move onto the
        // drive — overwriting any prior log via remove+move (not atomic-replace, which stages
        // a `.sb-` item on the drive).
        let tmp = fm.temporaryDirectory.appendingPathComponent("\(kind)-\(UUID().uuidString).txt")
        guard (try? text.write(to: tmp, atomically: true, encoding: .utf8)) != nil else { return }
        let dest = folder.appendingPathComponent("\(kind)-log.txt")
        try? fm.removeItem(at: dest)
        do { try fm.moveItem(at: tmp, to: dest) } catch { try? fm.removeItem(at: tmp) }
    }
}
