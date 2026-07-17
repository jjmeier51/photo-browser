import SwiftUI
import UniformTypeIdentifiers

/// Presented when the Share Extension hands something off (an Instagram story link, or a
/// photo/video). Asks **where** to save and **which upscale** to apply, then downloads the
/// story with the app's existing `InstagramService` (using your logged-in session) and applies
/// the chosen AI upscale — the manual, on-demand alternative to the automated browser sweeps.
struct StoryImportView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss

    @State private var destination: URL?
    @State private var showFolderPicker = false
    @State private var upscalePhotos = false
    @State private var upscaleVideos = false
    @State private var running = false
    @State private var phase = ""
    @State private var result: String?

    private var shares: [StorySharing.PendingShare] { library.pendingShares }

    var body: some View {
        NavigationStack {
            Form {
                Section("Sharing") {
                    ForEach(shares) { s in
                        Label {
                            Text(displayValue(s)).lineLimit(2).font(.callout)
                        } icon: {
                            Image(systemName: s.kind == .url ? "link" : (s.isVideoHint ? "film" : "photo"))
                        }
                    }
                }

                Section("Save to") {
                    Button {
                        showFolderPicker = true
                    } label: {
                        HStack {
                            Label(destination?.lastPathComponent ?? "Choose a folder…", systemImage: "folder")
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(library.rootURL == nil)
                }

                Section("Options") {
                    Toggle("2× AI upscale photos", isOn: $upscalePhotos)
                    Toggle("Upscale videos to 1080p", isOn: $upscaleVideos)
                }

                if running {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(phase.isEmpty ? "Working…" : phase).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                } else if let result {
                    Section { Text(result).font(.callout).foregroundStyle(.secondary) }
                }

                if library.rootURL == nil {
                    Section {
                        Text("Open your drive folder in the app first, then try sharing again.")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("Save Shared Story")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(result == nil ? "Cancel" : "Done") { finish() }.disabled(running)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { start() }
                        .disabled(running || destination == nil || shares.isEmpty)
                }
            }
            .sheet(isPresented: $showFolderPicker) {
                if let root = library.rootURL {
                    FolderPicker(root: root, confirmTitle: "Save Here", startAt: destination) { destination = $0 }
                        .environment(library)
                }
            }
        }
        .interactiveDismissDisabled(running)
        .onAppear { if destination == nil { destination = library.rootURL } }
        .onChange(of: library.rootURL) { if destination == nil { destination = library.rootURL } }
    }

    private func displayValue(_ s: StorySharing.PendingShare) -> String {
        s.kind == .url ? s.value : "Shared \(s.isVideoHint ? "video" : "photo")"
    }

    private func finish() {
        library.pendingShares = []
        StorySharing.clear()
        dismiss()
    }

    private func start() {
        guard let dest = destination else { return }
        let items = shares
        running = true; result = nil
        Task {
            var saved = 0, failed = 0
            for item in items {
                let paths: [String]
                switch item.kind {
                case .url:  paths = await importURL(item.value, into: dest)
                case .file: paths = await Self.importFile(item.value, into: dest)
                }
                if paths.isEmpty { failed += 1; continue }
                saved += paths.count
                await applyUpscales(to: paths)
            }
            phase = ""
            running = false
            result = saved > 0
                ? "Saved \(saved) item\(saved == 1 ? "" : "s") to “\(dest.lastPathComponent)”."
                : "Couldn’t save the shared story. Make sure you’re logged into Instagram in the app."
            StorySharing.clear()
            library.contentDidChange(under: dest)
        }
    }

    // MARK: - Import

    /// Downloads the shared user's current stories into `folder` via the logged-in session.
    private func importURL(_ urlString: String, into folder: URL) async -> [String] {
        phase = "Reading link…"
        guard let handle = await Self.instagramHandle(from: urlString) else { return [] }
        guard let creds = await InstagramAuth.credentials() else { return [] }   // not logged in
        phase = "Loading @\(handle)…"
        guard let profile = await InstagramService.fetchProfile(handle: handle, creds: creds) else { return [] }
        let outcome = await InstagramService.runStories(
            handle: profile.handle, userID: profile.userID, into: folder,
            already: [], creds: creds,
            progress: { p in Task { @MainActor in phase = p.phase } })
        // Attach captions the download surfaced, so they show in the app like other stories.
        for (path, caption) in outcome.captions where !caption.isEmpty {
            library.setCaption(caption, for: URL(fileURLWithPath: path))
        }
        return outcome.files
    }

    /// Moves a photo/video the extension copied into the App Group container into `folder`.
    /// Off-main: the App Group container and the external drive are different volumes, so this
    /// is a copy-then-delete that shouldn't run on the main actor.
    nonisolated static func importFile(_ name: String, into folder: URL) async -> [String] {
        await Task.detached(priority: .userInitiated) { () -> [String] in
            let fm = FileManager.default
            guard let container = StorySharing.containerURL else { return [] }
            let src = container.appendingPathComponent(name)
            guard fm.fileExists(atPath: src.path) else { return [] }
            let base = src.deletingPathExtension().lastPathComponent, ext = src.pathExtension
            var dest = folder.appendingPathComponent(name)
            var n = 2
            while fm.fileExists(atPath: dest.path) {
                dest = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"); n += 1
            }
            do { try fm.moveItem(at: src, to: dest); return [dest.path] }
            catch { try? fm.removeItem(at: src); return [] }
        }.value
    }

    /// Applies the chosen upscales to each downloaded file (photos → 2× AI, videos → 1080p),
    /// in place. Off-main; each is best-effort.
    private func applyUpscales(to paths: [String]) async {
        for path in paths {
            let url = URL(fileURLWithPath: path)
            let kind = classify(url: url, isDirectory: false)
            if kind == .image, upscalePhotos {
                phase = "Upscaling photo…"
                _ = await Task.detached(priority: .userInitiated) { MediaEditing.enhancePhotoInPlace(url: url, scale: 2.0) }.value
            } else if kind == .video, upscaleVideos {
                phase = "Upscaling video…"
                _ = await MediaEditing.enhanceVideo(url: url, targetShort: 1080, progress: { _ in })
            }
        }
    }

    // MARK: - URL parsing

    /// Extracts the Instagram handle from a shared link. Handles `/stories/<handle>/…` and a
    /// bare `/<handle>` profile URL; follows a share shortlink (`/s/…`, `share.` hosts) once to
    /// resolve it. Networking stays off the main actor.
    nonisolated static func instagramHandle(from urlString: String) async -> String? {
        if let h = handleFromPath(urlString) { return h }
        // Resolve a redirect (share shortlink) to its final URL, then re-parse.
        guard let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url)
        req.setValue(InstagramService.userAgent, forHTTPHeaderField: "User-Agent")
        if let (_, resp) = try? await InstagramService.session.data(for: req),
           let final = (resp as? HTTPURLResponse)?.url?.absoluteString, final != urlString {
            return handleFromPath(final)
        }
        return nil
    }

    private nonisolated static func handleFromPath(_ urlString: String) -> String? {
        guard let url = URL(string: urlString), let host = url.host, host.contains("instagram.com") else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        if let i = parts.firstIndex(of: "stories"), i + 1 < parts.count {
            let h = parts[i + 1]
            return h == "highlights" ? nil : h    // a highlights link isn't a per-user handle
        }
        // A profile URL: instagram.com/<handle>. Skip known non-handle first segments.
        let reserved: Set<String> = ["p", "reel", "reels", "tv", "explore", "s", "stories", "accounts", "direct"]
        if let first = parts.first, !reserved.contains(first) { return first }
        return nil
    }
}
