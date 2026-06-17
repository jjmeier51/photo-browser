import SwiftUI

/// "Download from KardashianWorld": salvages the defunct kardashianworld.net gallery
/// from the Internet Archive into a "KardashianWorld" folder (one subfolder per
/// member, each stamped with the member's birthday). Downloads in batches of 1,000
/// and remembers where it left off, so you can keep going across sessions.
struct KardashianWorldView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let targetFolder: URL
    let onFinished: () -> Void

    @State private var root: URL?
    @State private var cursor = 0
    @State private var total = 0
    @State private var loaded = false
    @State private var running = false
    @State private var progress = KardashianWorldDownloader.Progress(phase: "", fraction: 0, done: 0, total: 0)
    @State private var result: KardashianWorldDownloader.BatchResult?

    private let batchSize = 1000
    private var resuming: Bool { root != nil && cursor > 0 }
    private var finished: Bool { total > 0 && cursor >= total }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Internet Archive salvage", systemImage: "clock.arrow.circlepath")
                    if total > 0 {
                        Text("\(cursor) of \(total) downloaded").font(.callout).foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("kardashianworld.net is offline, so this pulls its archived photos from the Wayback Machine into a “KardashianWorld” folder, sorted into a subfolder per member (with each member's birthday set). It downloads 1,000 at a time and remembers where it left off. Coverage is partial — only what the Archive crawled.")
                }

                if running {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            ProgressView(value: progress.total > 0 ? progress.fraction : 0)
                            Text(progressLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            Text("Keep the app open. It keeps going briefly if you switch away, but can’t finish once the app is closed.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }

                if let result, !running {
                    Section {
                        Label(summary(result), systemImage: finished ? "checkmark.circle" : "arrow.down.circle")
                            .foregroundStyle(result.downloaded > 0 ? .green : .orange)
                        if let note = result.note { Text(note).font(.caption).foregroundStyle(.secondary) }
                    }
                }

                if resuming && !running {
                    Section {
                        Button("Start a new download instead", role: .destructive) { startOver() }
                    }
                }
            }
            .navigationTitle("KardashianWorld")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(running)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(result != nil || resuming ? "Done" : "Cancel") { dismiss() }.disabled(running)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if !finished {
                        Button(actionLabel) { start() }.disabled(running)
                    }
                }
            }
            .onAppear { loadProgress() }
        }
    }

    private var actionLabel: String {
        if cursor == 0 { return "Download first \(batchSize)" }
        return "Download next \(batchSize)"
    }

    private var progressLine: String {
        guard progress.total > 0 else { return progress.phase }
        return "Downloading \(progress.done) of \(progress.total)…"
    }

    private func summary(_ r: KardashianWorldDownloader.BatchResult) -> String {
        if finished { return "All \(total) photos downloaded." }
        guard r.downloaded > 0 else { return "Nothing downloaded in this batch." }
        return "Downloaded \(r.downloaded) photo\(r.downloaded == 1 ? "" : "s") — \(cursor) of \(total). Continue?"
    }

    private func loadProgress() {
        guard !loaded else { return }
        loaded = true
        if let p = library.kardashianProgress,
           FileManager.default.fileExists(atPath: p.root), p.cursor < p.total {
            root = URL(fileURLWithPath: p.root); cursor = p.cursor; total = p.total
        } else if library.kardashianProgress != nil {
            library.setKardashianProgress(nil)        // stale (folder gone / finished)
        }
    }

    private func startOver() {
        library.setKardashianProgress(nil)
        root = nil; cursor = 0; total = 0; result = nil
    }

    private func start() {
        running = true; result = nil
        let bg = BackgroundTaskHolder(); bg.begin(name: "KardashianWorld Download")
        Task {
            // Reuse the in-progress folder, else create a fresh "KardashianWorld".
            let useRoot: URL
            if let root { useRoot = root }
            else {
                var dir = targetFolder.appendingPathComponent("KardashianWorld", isDirectory: true)
                var n = 2
                while FileManager.default.fileExists(atPath: dir.path) {
                    dir = targetFolder.appendingPathComponent("KardashianWorld \(n)", isDirectory: true); n += 1
                }
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                useRoot = dir; root = dir
            }

            let r = await KardashianWorldDownloader.runBatch(into: useRoot, startIndex: cursor, batchSize: batchSize) { p in
                Task { @MainActor in progress = p }
            }
            cursor = r.nextIndex
            total = r.total

            // Stamp each member's folder with their birthday (for the Age feature).
            for member in r.membersTouched {
                if let comps = KardashianWorldDownloader.birthdays[member],
                   let date = Calendar(identifier: .gregorian).date(from: comps) {
                    library.setBirthday(date, for: useRoot.appendingPathComponent(member, isDirectory: true))
                }
            }
            // Remember (or clear) where we left off.
            if r.total > 0, r.nextIndex < r.total {
                library.setKardashianProgress(.init(root: useRoot.path, cursor: r.nextIndex, total: r.total))
            } else {
                library.setKardashianProgress(nil)
            }

            running = false; bg.end()
            result = r
            if r.downloaded > 0 { library.contentDidChange(); onFinished() }
        }
    }
}
