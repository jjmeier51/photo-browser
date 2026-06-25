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
                    remaining = await BackgroundDownloader.shared.remainingCount()
                    if remaining == 0 && !resolving { break }   // keep going while more links are still resolving
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                }
            }
        }
    }

    private func start() {
        let user = username
        guard !user.isEmpty else { return }
        resolving = true; note = nil; queued = 0; remaining = 0

        let dest = targetFolder.appendingPathComponent("@\(user)", isDirectory: true)
        let parent = targetFolder
        let prior = library.tiktokInfo(for: dest)
        let already = Set(prior?.downloaded ?? [])
        batchToken += 1                                          // start the monitor loop

        // A background-task window so link resolution keeps going for a few minutes after the app
        // is backgrounded; each resolved video's download is handed to the background session
        // immediately, so it continues even after the app is fully closed.
        let bg = BackgroundTaskHolder(); bg.begin(name: "TikTok Resolve")
        Task {
            let destPath = dest.path
            let result = await TikTokService.enumerateStreaming(
                username: user, alreadyDownloaded: already,
                onAvatar: { data in
                    Task { @MainActor in
                        guard let img = UIImage(data: data) else { return }
                        library.setCover(img, for: dest)
                        if library.coverURL(for: parent) == nil,
                           library.instagramInfo(for: parent) == nil, !library.isTikTokFolder(parent) {
                            library.setCover(img, for: parent)
                        }
                    }
                },
                onResolved: { v in
                    guard let url = URL(string: v.url) else { return }
                    let meta = BackgroundDownloader.Meta(dest: dest.appendingPathComponent("\(v.id).mp4").path,
                                                         createTime: v.createTime.timeIntervalSince1970,
                                                         caption: v.desc, folder: destPath, id: v.id)
                    BackgroundDownloader.shared.enqueue(url: url, meta: meta)
                    Task { @MainActor in
                        // On the first resolved video, register the profile (pinned bubble +
                        // remembered handle) and create its folder so the bubble can appear.
                        if library.tiktokInfo(for: dest) == nil {
                            try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
                            let info = TTFolderInfo(handle: user, secUid: prior?.secUid ?? "",
                                                    lastUpdated: Date().timeIntervalSince1970,
                                                    downloaded: prior?.downloaded ?? [], videos: prior?.videos ?? 0)
                            library.setTikTokInfo(info, for: dest)
                            library.setLastTikTokHandle(user, for: parent)
                            library.contentDidChange()           // surface the new @handle bubble
                        }
                        queued += 1                               // `remaining` is owned by the monitor poll
                    }
                },
                progress: { p in Task { @MainActor in phase = p.phase } })

            // Record the resolved author id (kept for future use) without disturbing counts.
            if !result.authorId.isEmpty, var info = library.tiktokInfo(for: dest), info.secUid.isEmpty {
                info.secUid = result.authorId
                library.setTikTokInfo(info, for: dest)
            }
            resolving = false
            note = (queued == 0) ? (result.note ?? "Nothing to download.") : nil
            if queued > 0 { onFinished() }
            bg.end()
        }
    }
}
