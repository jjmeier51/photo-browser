import SwiftUI
import UniformTypeIdentifiers

/// Presented when the Share Extension hands something off (an Instagram story or post link, or a
/// photo/video). Asks **where** to save and **which upscale** to apply, then downloads it with the
/// app's existing `InstagramService` (using your logged-in session) and applies the chosen AI
/// upscale — the manual, on-demand alternative to the automated browser sweeps. The download writes
/// each item's capture date (the post/story's `taken_at`) + EXIF, like the profile crawl.
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
    @State private var loggedIn = true          // assume yes until the check; avoids a login-button flash
    @State private var showLogin = false

    private var shares: [StorySharing.PendingShare] { library.pendingShares }
    private var needsLogin: Bool { !loggedIn && shares.contains { $0.kind == .url } }

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

                if needsLogin {
                    Section {
                        Button { showLogin = true } label: {
                            Label("Log in to Instagram", systemImage: "person.badge.key")
                        }
                    } footer: {
                        Text("Downloading a shared story or post uses your logged-in Instagram session.")
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
            .navigationTitle("Save Shared")
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
            .sheet(isPresented: $showLogin) {
                InstagramLoginView { Task { loggedIn = await InstagramAuth.isLoggedIn() } }
            }
        }
        .interactiveDismissDisabled(running)
        .task { loggedIn = await InstagramAuth.isLoggedIn() }
        .onAppear { if destination == nil { destination = defaultDestination() } }
        .onChange(of: library.rootURL) { if destination == nil { destination = defaultDestination() } }
    }

    /// Default save folder: the last place a shared story/post was saved (if it still exists),
    /// else the drive root.
    private func defaultDestination() -> URL? {
        if let d = library.lastStoryDestination, FileManager.default.fileExists(atPath: d.path) { return d }
        return library.rootURL
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
            var saved = 0
            for item in items {
                let paths: [String]
                switch item.kind {
                case .url:  paths = await importURL(item.value, into: dest)
                case .file: paths = await Self.importFile(item.value, into: dest)
                }
                guard !paths.isEmpty else { continue }
                saved += paths.count
                await applyUpscales(to: paths)
            }
            phase = ""
            running = false
            if saved > 0 {
                library.setLastStoryDestination(dest)
                result = "Saved \(saved) item\(saved == 1 ? "" : "s") to “\(dest.lastPathComponent)”."
            } else {
                result = needsLogin
                    ? "Log in to Instagram above, then tap Save again."
                    : "Couldn’t save it. If it’s an Instagram link, make sure you’re logged in and the account is public or one you follow."
            }
            StorySharing.clear()
            library.contentDidChange(under: dest)
        }
    }

    // MARK: - Import

    /// Downloads the shared Instagram link into `folder` via the logged-in session — a specific
    /// story (by media pk), an account's current stories, or a single post/reel (photo, carousel,
    /// or video). Captions the download surfaces are attached so they show like other downloads.
    private func importURL(_ urlString: String, into folder: URL) async -> [String] {
        phase = "Reading link…"
        guard let creds = await InstagramAuth.credentials() else { return [] }   // not logged in
        let outcome: InstagramService.DownloadResult
        switch await Self.resolveShared(from: urlString) {
        case .story(let handle, let pk):
            phase = "Loading @\(handle)…"
            guard let profile = await InstagramService.fetchProfile(handle: handle, creds: creds) else { return [] }
            outcome = await InstagramService.runStories(
                handle: profile.handle, userID: profile.userID, into: folder,
                already: [], creds: creds, onlyPK: pk,
                progress: { p in Task { @MainActor in phase = p.phase } })
        case .post(let code):
            phase = "Loading post…"
            outcome = await InstagramService.runPost(
                shortcode: code, into: folder, already: [], creds: creds,
                progress: { p in Task { @MainActor in phase = p.phase } })
        case nil:
            return []
        }
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

    private enum Shared: Sendable {
        case story(handle: String, pk: String?)   // /stories/<handle>/<pk?>/ or a bare profile
        case post(shortcode: String)              // /p|reel|tv/<code>/
    }

    /// Classifies a shared Instagram link. Follows a share shortlink (`/s/…`) once to resolve it.
    /// Networking stays off the main actor.
    nonisolated private static func resolveShared(from urlString: String) async -> Shared? {
        if let s = sharedFromPath(urlString) { return s }
        guard let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url)
        req.setValue(InstagramService.userAgent, forHTTPHeaderField: "User-Agent")
        if let (_, resp) = try? await InstagramService.session.data(for: req),
           let final = (resp as? HTTPURLResponse)?.url?.absoluteString, final != urlString {
            return sharedFromPath(final)
        }
        return nil
    }

    private nonisolated static func sharedFromPath(_ urlString: String) -> Shared? {
        guard let url = URL(string: urlString), let host = url.host, host.contains("instagram.com") else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        // A post / reel / IGTV link.
        if let i = parts.firstIndex(where: { $0 == "p" || $0 == "reel" || $0 == "tv" }), i + 1 < parts.count {
            return .post(shortcode: parts[i + 1])
        }
        // A story link: /stories/<handle>/<pk?>/
        if let i = parts.firstIndex(of: "stories"), i + 1 < parts.count {
            let h = parts[i + 1]
            guard h != "highlights" else { return nil }
            let pk = (i + 2 < parts.count && parts[i + 2].allSatisfy(\.isNumber)) ? parts[i + 2] : nil
            return .story(handle: h, pk: pk)
        }
        // A profile URL: instagram.com/<handle> → the account's current stories.
        let reserved: Set<String> = ["p", "reel", "reels", "tv", "explore", "s", "stories", "accounts", "direct"]
        if let first = parts.first, !reserved.contains(first) { return .story(handle: first, pk: nil) }
        return nil
    }
}
