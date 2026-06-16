import SwiftUI

/// "Download from KardashianWorld": salvages the defunct kardashianworld.net gallery
/// from the Internet Archive into a "KardashianWorld" folder (one subfolder per
/// member) inside the current folder. Runs under a background-task window; like every
/// transfer it can't finish once the app is fully closed.
struct KardashianWorldView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let targetFolder: URL
    let onFinished: () -> Void

    @State private var running = false
    @State private var progress = KardashianWorldDownloader.Progress(phase: "", fraction: 0, done: 0, total: 0)
    @State private var result: KardashianWorldDownloader.DownloadResult?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Internet Archive salvage", systemImage: "clock.arrow.circlepath")
                } footer: {
                    Text("kardashianworld.net is no longer online, so this pulls its archived photos from the Wayback Machine into a “KardashianWorld” folder here, sorted into a subfolder for each member. Coverage is partial — only what the Archive crawled. Nothing is uploaded.")
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

                if let result {
                    Section {
                        Label(summary(result), systemImage: result.downloaded > 0 ? "checkmark.circle" : "exclamationmark.triangle")
                            .foregroundStyle(result.downloaded > 0 ? .green : .orange)
                        if let note = result.note { Text(note).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            .navigationTitle("KardashianWorld")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(running)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(result != nil ? "Done" : "Cancel") { dismiss() }.disabled(running)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Download") { start() }.disabled(running)
                }
            }
        }
    }

    private var progressLine: String {
        guard progress.total > 0 else { return progress.phase }
        return "Downloading \(progress.done) of \(progress.total)…"
    }

    private func summary(_ r: KardashianWorldDownloader.DownloadResult) -> String {
        guard r.downloaded > 0 else { return "Nothing downloaded." }
        return "Downloaded \(r.downloaded) photo\(r.downloaded == 1 ? "" : "s") across \(r.members) member\(r.members == 1 ? "" : "s")"
            + (r.folderName.map { " into “\($0)”." } ?? ".")
    }

    private func start() {
        let dest = targetFolder
        running = true; result = nil
        let bg = BackgroundTaskHolder(); bg.begin(name: "KardashianWorld Download")
        Task {
            let r = await KardashianWorldDownloader.run(into: dest) { p in
                Task { @MainActor in progress = p }
            }
            running = false
            bg.end()
            result = r
            if r.downloaded > 0 { library.contentDidChange(); onFinished() }
        }
    }
}
