import SwiftUI
import UIKit

/// "Add from MEGA": paste a public MEGA folder link, then download its photos and
/// videos into the current drive folder (in a subfolder named after the MEGA
/// folder, preserving its structure). Presented on its own screen so it doesn't
/// collide with the folder view's other dialogs. Runs under a background-task
/// window, so a brief app backgrounding is fine — but, like every transfer, it
/// can't finish once the app is terminated.
struct MegaImportView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let targetFolder: URL
    let onFinished: () -> Void

    @State private var link = ""
    @State private var running = false
    @State private var progress = MegaProgress(fraction: 0, done: 0, total: 0, currentName: "")
    @State private var result: MegaImportResult?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://mega.nz/folder/…", text: $link, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .disabled(running)
                } header: {
                    Text("MEGA folder link")
                } footer: {
                    Text("Photos and videos in the link are downloaded into “\(targetFolder.lastPathComponent)”. Nothing is uploaded.")
                }

                if running {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            ProgressView(value: progress.fraction)
                            Text(progressLine)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            Text("Keep the app open. It keeps going briefly if you switch away, but can’t finish once the app is closed.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }

                if let result {
                    Section {
                        Label(summary(result),
                              systemImage: result.imported > 0 ? "checkmark.circle" : "exclamationmark.triangle")
                            .foregroundStyle(result.imported > 0 ? .green : .orange)
                        if let note = result.note {
                            Text(note).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Add from MEGA")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(running)
            // Convenience: pre-fill from the clipboard so a freshly-copied MEGA link
            // is ready to go without pasting by hand.
            .onAppear {
                if link.isEmpty,
                   let pasted = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !pasted.isEmpty {
                    link = pasted
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(result != nil ? "Done" : "Cancel") { dismiss() }.disabled(running)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Download") { start() }
                        .disabled(running || link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private var progressLine: String {
        guard progress.total > 0 else { return progress.currentName }
        let base = "Downloading \(progress.done) of \(progress.total)"
        return progress.currentName.isEmpty ? base + "…" : base + " — \(progress.currentName)"
    }

    private func summary(_ r: MegaImportResult) -> String {
        guard r.imported > 0 else { return "Nothing downloaded." }
        let base = "Downloaded \(r.imported) item(s)" + (r.folderName.map { " to “\($0)”" } ?? "")
        return r.failed > 0 ? base + "; \(r.failed) failed." : base + "."
    }

    private func start() {
        let url = link
        let dest = targetFolder
        running = true; result = nil
        let bg = BackgroundTaskHolder()
        bg.begin(name: "MEGA Import")   // keep going if the app is briefly backgrounded
        Task {
            let r = await MegaDownloader.importFolder(link: url, into: dest) { p in
                Task { @MainActor in progress = p }
            }
            running = false
            bg.end()
            result = r
            if r.imported > 0 {
                library.contentDidChange()
                onFinished()
            }
        }
    }
}
