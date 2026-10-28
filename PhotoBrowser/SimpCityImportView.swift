import SwiftUI
import UIKit

/// "Download from SimpCity…" on a person's folder: paste a thread address and download its goonbox
/// photos and turbo videos into the folder's "simpcity" subfolder (see `SimpCityDownloader`). The
/// screen shows the downloader's own browser — log in to SimpCity there once, and answer a "you're
/// human?" check there if a site asks. "Hide" leaves the run going in the background (its progress is
/// at the bottom of the app like any download); a person folder downloaded before offers "Get New",
/// which reads the thread from the last page it reached.
struct SimpCityImportView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(Library.self) private var library
    /// The person's folder (opened from inside its "simpcity" folder, that folder's parent).
    let personFolder: URL
    let onFinished: () -> Void

    @State private var thread = ""
    @State private var full = false
    @State private var readBefore = false

    private var downloader: SimpCityDownloader { SimpCityDownloader.shared }
    private var base: String? { SimpCity.threadBase(thread) }
    private var otherRun: Bool { downloader.running && downloader.person != personFolder }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("https://simpcity.cr/threads/…", text: $thread)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .keyboardType(.URL).textFieldStyle(.roundedBorder)
                        .disabled(downloader.running)
                    Toggle("Read every page again", isOn: $full)
                        .font(.subheadline)
                        .disabled(downloader.running || !readBefore)
                    if downloader.running, downloader.total > 0 {
                        ProgressView(value: Double(downloader.done), total: Double(downloader.total))
                    }
                    Text(statusLine)
                        .font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding()
                Divider()
                SimpCityWebHost()
            }
            .navigationTitle("SimpCity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(downloader.running ? "Hide" : "Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if downloader.running {
                        Button("Stop", role: .destructive) { downloader.stop() }
                    } else {
                        Button(readBefore ? "Get New" : "Download") { start() }
                            .fontWeight(.semibold)
                            .disabled(base == nil)
                    }
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button("Log In") { downloader.main.load(SimpCityDownloader.loginURL) }
                    Spacer()
                    Button("Thread") {
                        if let base, let url = URL(string: base) { downloader.main.load(url) }
                    }
                    .disabled(base == nil || downloader.running)
                }
            }
            .onAppear { downloader.showing = true }
            .onDisappear { downloader.showing = false }
            .task {
                let person = personFolder
                let last = await Task.detached(priority: .userInitiated) { SimpCityDownloader.lastThread(in: person) }.value
                readBefore = last != nil
                if thread.isEmpty { thread = last ?? "" }
                if !downloader.running {
                    downloader.main.load(URL(string: base ?? "https://simpcity.cr/") ?? SimpCityDownloader.loginURL)
                }
            }
        }
    }

    private var statusLine: String {
        if otherRun { return "A SimpCity download for “\(downloader.person?.lastPathComponent ?? "")” is running — this one can start when it’s done." }
        if downloader.running || !downloader.status.isEmpty, downloader.person == personFolder { return downloader.status }
        return "Saves into “\(personFolder.lastPathComponent)/\(SimpCity.folderName)”, tagged “\(SimpCity.tag)”. Log in to SimpCity below if you haven’t; if a site asks whether you’re human, answer it below."
    }

    private func start() {
        guard let base, !downloader.running else { return }
        thread = base
        downloader.start(person: personFolder, thread: base, full: full, library: library)
        readBefore = true
        onFinished()
    }
}

/// Hosts the downloader's main web view while the screen is up; it goes back behind the app (and a
/// run carries on) when the screen closes.
private struct SimpCityWebHost: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let host = UIView()
        host.backgroundColor = .systemBackground
        SimpCityDownloader.shared.main.present(in: host)
        return host
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    static func dismantleUIView(_ uiView: UIView, coordinator: ()) {
        SimpCityDownloader.shared.main.retire()
    }
}
