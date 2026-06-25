import SwiftUI
import UIKit

/// "Download TikTok Profile": enter a handle and pull the profile's own videos (highest
/// quality / HD, watermark-free, with post date + caption) into an "@handle" folder nested in
/// the current folder, shown as a pinned highlight bubble — like the Instagram one. The profile
/// is remembered per folder, so a re-run only fetches new videos (dedup by id).
///
/// Links are resolved up front (while the app is open); the actual downloads run on a background
/// `URLSession`, so they keep going — and finish — even if you close the app. They're filed into
/// the folder when the app is next in the foreground. No browser or login needed.
struct TikTokImportView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let targetFolder: URL
    let onFinished: () -> Void

    @State private var handle = ""
    @State private var resolving = false
    @State private var phase = ""
    @State private var note: String?
    @State private var queued = 0
    @State private var remaining = 0
    @State private var batchToken = 0

    private var username: String { TikTokService.sanitizeHandle(handle) }
    private var isUpdate: Bool { library.lastTikTokHandle(for: targetFolder) != nil }
    private var busy: Bool { resolving }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("tiktok handle (e.g. zachking)", text: $handle)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .keyboardType(.twitter).disabled(busy)
                } header: {
                    Text("TikTok profile")
                } footer: {
                    Text("Downloads this profile's own videos into an “@\(username.isEmpty ? "handle" : username)” folder here, watermark-free at the highest quality offered. Only the public handle is sent out; nothing is uploaded.")
                }

                if resolving {
                    Section { Label(phase.isEmpty ? "Working…" : phase, systemImage: "magnifyingglass").foregroundStyle(.secondary) }
                }
                if queued > 0 {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Label(remaining > 0 ? "\(remaining) of \(queued) still downloading…" : "All \(queued) downloaded.",
                                  systemImage: remaining > 0 ? "arrow.down.circle" : "checkmark.circle.fill")
                                .foregroundStyle(remaining > 0 ? Color.primary : Color.green)
                            Text("Downloads continue in the background — you can close the app. New videos appear in the folder as they finish.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if let note { Section { Text(note).foregroundStyle(.orange) } }
            }
            .navigationTitle(isUpdate ? "Get New TikTok Videos" : "Download TikTok Profile")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(resolving)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(queued > 0 ? "Done" : "Cancel") { dismiss() }.disabled(resolving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Download") { start() }.disabled(busy || username.isEmpty)
                }
            }
            .onAppear {
                if handle.isEmpty, let last = library.lastTikTokHandle(for: targetFolder) { handle = last }
            }
            // Keep the screen awake during the (foreground) link-resolution pass.
            .onChange(of: resolving) { _, on in UIApplication.shared.isIdleTimerDisabled = on }
            .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
            // While open, file completed background downloads and refresh the remaining count.
            .task(id: batchToken) {
                guard batchToken > 0 else { return }
                while !Task.isCancelled {
                    library.processPendingTikTok()
                    let r = await BackgroundDownloader.shared.remainingCount()
                    remaining = r
                    if r == 0 { break }
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                }
            }
        }
    }

    private func start() {
        let user = username
        guard !user.isEmpty else { return }
        resolving = true; note = nil; queued = 0; remaining = 0
        Task {
            let dest = targetFolder.appendingPathComponent("@\(user)", isDirectory: true)
            let prior = library.tiktokInfo(for: dest)
            let already = Set(prior?.downloaded ?? [])

            let result = await TikTokService.enumerate(username: user, alreadyDownloaded: already) { p in
                Task { @MainActor in phase = p.phase }
            }

            // Register the profile up front so the pinned bubble + remembered handle appear now;
            // the per-video count grows as background downloads are filed (processPendingTikTok).
            if result.totalFound > 0 || prior != nil {
                if let avatar = result.avatar, let img = UIImage(data: avatar) {
                    library.setCover(img, for: dest)
                    if library.coverURL(for: targetFolder) == nil,
                       library.instagramInfo(for: targetFolder) == nil, !library.isTikTokFolder(targetFolder) {
                        library.setCover(img, for: targetFolder)
                    }
                }
                let info = TTFolderInfo(handle: user,
                                        secUid: result.authorId.isEmpty ? (prior?.secUid ?? "") : result.authorId,
                                        lastUpdated: Date().timeIntervalSince1970,
                                        downloaded: prior?.downloaded ?? [],
                                        videos: prior?.videos ?? 0)
                library.setTikTokInfo(info, for: dest)
                library.setLastTikTokHandle(user, for: targetFolder)
            }

            try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            for v in result.videos {
                guard let url = URL(string: v.url) else { continue }
                let meta = BackgroundDownloader.Meta(dest: dest.appendingPathComponent("\(v.id).mp4").path,
                                                     createTime: v.createTime.timeIntervalSince1970,
                                                     caption: v.desc, folder: dest.path, id: v.id)
                BackgroundDownloader.shared.enqueue(url: url, meta: meta)
            }

            resolving = false
            queued = result.videos.count
            remaining = result.videos.count
            note = result.videos.isEmpty ? (result.note ?? "Nothing to download.") : nil
            if queued > 0 { batchToken += 1; onFinished() }       // kick the monitor loop
        }
    }
}
