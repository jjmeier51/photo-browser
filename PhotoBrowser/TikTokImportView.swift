import SwiftUI
import UIKit

/// "Download TikTok Profile": enter a handle and pull the profile's own videos (highest
/// quality, watermark-free, with post date + caption) into an "@handle" folder nested in the
/// current folder, shown as a pinned highlight bubble — like the Instagram one. The profile is
/// remembered per folder, so a re-run only fetches new videos (dedup by video id). No browser
/// or login needed: resolution goes through a public TikTok resolver (see `TikTokService`).
/// Best-effort — the resolver is unofficial and rate-limited.
struct TikTokImportView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let targetFolder: URL
    let onFinished: () -> Void

    @State private var handle = ""
    @State private var running = false
    @State private var progress = TikTokService.Progress(phase: "", fraction: 0, done: 0, total: 0)
    @State private var result: TikTokService.DownloadResult?

    private var username: String { TikTokService.sanitizeHandle(handle) }
    private var isUpdate: Bool { library.lastTikTokHandle(for: targetFolder) != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("tiktok handle (e.g. zachking)", text: $handle)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .keyboardType(.twitter).disabled(running)
                } header: {
                    Text("TikTok profile")
                } footer: {
                    Text("Downloads this profile's own videos (reposts excluded) into an “@\(username.isEmpty ? "handle" : username)” folder here, watermark-free at the highest quality offered. Only the public handle is sent out; nothing is uploaded.")
                }

                if running {
                    Section {
                        VStack(spacing: 10) {
                            ProgressView(value: progress.total > 0 ? progress.fraction : 0)
                                .progressViewStyle(.linear)
                            Text(progress.total > 0 ? "Downloading \(progress.done) of \(progress.total)…"
                                                    : (progress.phase.isEmpty ? "Working…" : progress.phase))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                if let result {
                    Section { Text(summary(result)).foregroundStyle(result.videos > 0 ? .green : .orange) }
                }
            }
            .navigationTitle(isUpdate ? "Get New TikTok Videos" : "Download TikTok Profile")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(running)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(result != nil ? "Done" : "Cancel") { dismiss() }.disabled(running)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Download") { start() }.disabled(running || username.isEmpty)
                }
            }
            .onAppear {
                if handle.isEmpty, let last = library.lastTikTokHandle(for: targetFolder) { handle = last }
            }
            // Keep the screen awake while the (potentially long) download runs.
            .onChange(of: running) { _, isRunning in UIApplication.shared.isIdleTimerDisabled = isRunning }
            .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        }
    }

    private func summary(_ r: TikTokService.DownloadResult) -> String {
        guard r.videos > 0 else { return r.note ?? "Nothing downloaded." }
        return "Downloaded \(r.videos) video\(r.videos == 1 ? "" : "s")."
    }

    private func start() {
        let user = username
        guard !user.isEmpty else { return }
        running = true; result = nil
        let bg = BackgroundTaskHolder(); bg.begin(name: "TikTok Download")
        Task {
            // The TikTok folder lives *inside* the current (person) folder as "@handle", so the
            // person folder stays a regular folder and only the "@handle" folder is a bubble.
            let dest = targetFolder.appendingPathComponent("@\(user)", isDirectory: true)
            let prior = library.tiktokInfo(for: dest)
            let already = Set(prior?.downloaded ?? [])

            let r = await TikTokService.run(username: user, into: dest, alreadyDownloaded: already) { p in
                Task { @MainActor in progress = p }
            }
            library.setCaptions(r.captions)
            if let avatar = r.avatar, let img = UIImage(data: avatar) {
                library.setCover(img, for: dest)                              // bubble shows the avatar
                if library.coverURL(for: targetFolder) == nil,               // person folder gets it too if bare
                   library.instagramInfo(for: targetFolder) == nil, !library.isTikTokFolder(targetFolder) {
                    library.setCover(img, for: targetFolder)
                }
            }

            let resolvedProfile = !r.secUid.isEmpty || prior != nil
            if r.videos > 0 || resolvedProfile {
                let info = TTFolderInfo(handle: user,
                                        secUid: r.secUid.isEmpty ? (prior?.secUid ?? "") : r.secUid,
                                        lastUpdated: Date().timeIntervalSince1970,
                                        downloaded: Array(already.union(r.downloadedIDs)),
                                        videos: (prior?.videos ?? 0) + r.videos)
                library.setTikTokInfo(info, for: dest)
                library.setLastTikTokHandle(user, for: targetFolder)
            } else if let contents = try? FileManager.default.contentsOfDirectory(atPath: dest.path), contents.isEmpty {
                try? FileManager.default.removeItem(at: dest)                 // nothing came down — drop the empty folder
            }
            if r.videos > 0 { library.contentDidChange(); onFinished() }

            running = false; bg.end()
            result = r
        }
    }
}
