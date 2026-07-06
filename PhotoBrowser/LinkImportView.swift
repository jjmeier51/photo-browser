import SwiftUI
import UIKit

/// "Download from a Link": paste an album or file link from a supported host
/// (Bunkr, GoFile, Pixeldrain, Cyberdrop, pixl, …) and pull its photos/videos into
/// the current folder. Like the other downloaders it runs as an app-wide background
/// activity, so the user can keep browsing the app or step away while it works.
struct LinkImportView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let targetFolder: URL
    let onFinished: () -> Void

    @State private var link = ""

    private var canDownload: Bool { LinkDownloadService.looksLikeLink(link) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("album or file link", text: $link, axis: .vertical)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .keyboardType(.URL).lineLimit(1...3)
                } header: {
                    Text("Link")
                } footer: {
                    Text("Paste an album or file link. Downloads into “\(targetFolder.lastPathComponent)”. Nothing is uploaded.")
                }

                Section {
                    // `hasStrings` doesn't trigger the paste banner; the value is only
                    // read when the user taps.
                    if UIPasteboard.general.hasStrings {
                        Button {
                            if let clip = UIPasteboard.general.string { link = clip.trimmingCharacters(in: .whitespacesAndNewlines) }
                        } label: {
                            Label("Paste from Clipboard", systemImage: "doc.on.clipboard")
                        }
                    }
                } footer: {
                    Text("Supported: bunkr, gofile, pixeldrain, cyberdrop, turbo, filester, cyberfile, pixl, goonbox. Files download at full quality (EXIF/HDR preserved), in the background — watch progress at the bottom of the screen. These hosts fight scraping, so coverage is best-effort.")
                }
            }
            .navigationTitle("Download from a Link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Download") { start() }.disabled(!canDownload)
                }
            }
        }
    }

    /// Starts the download as a background activity and dismisses immediately.
    private func start() {
        let url = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard LinkDownloadService.looksLikeLink(url) else { return }
        let target = targetFolder
        let finish = onFinished
        let host = URL(string: url.hasPrefix("http") ? url : "https://\(url)")?.host ?? "link"
        let id = library.beginActivity("Downloading from \(host)", indeterminate: true)
        library.setActivity(id, status: "Resolving…")
        dismiss()
        let bg = BackgroundTaskHolder(); bg.begin(name: "Link Download")
        Task {
            let r = await LinkDownloadService.run(link: url, into: target) { p in
                Task { @MainActor in
                    library.setActivity(id, status: p.total > 0 ? "Downloading \(p.done) of \(p.total)…" : (p.phase.isEmpty ? "Working…" : p.phase),
                                        fraction: p.total > 0 ? p.fraction : nil)
                }
            }
            library.endActivity(id, result: summary(r, host: host))
            if r.downloaded > 0 { library.contentDidChange(); finish() }
            bg.end()
        }
    }

    private func summary(_ r: LinkDownloadService.DownloadResult, host: String) -> String {
        guard r.downloaded > 0 else { return r.note ?? "Nothing downloaded." }
        let where_ = r.albumName.map { " from “\($0)”" } ?? ""
        var s = "Downloaded \(r.downloaded) file\(r.downloaded == 1 ? "" : "s")\(where_)"
        if r.failed > 0 { s += "; \(r.failed) failed" }
        s += "."
        if let note = r.note, !note.isEmpty { s += " " + note }   // diagnostic
        return s
    }
}
