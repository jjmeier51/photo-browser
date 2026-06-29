import SwiftUI
import UIKit

/// "Get All New Instagram Stories" — a homepage sweep that walks every tracked
/// Instagram profile folder on the drive and pulls each user's current (last-24h)
/// stories into their own "Stories" subfolder, then gathers the collective new
/// stories into a shared **"Today's Instagram Stories"** folder at the drive root.
///
/// The shared folder is rolling: while it's under 24h old new stories are appended;
/// once it ages past 24h it's cleared and refilled with whatever this run finds (its
/// start time lives in `Library.igStoriesTempStart`). Per-user dedup (`IGFolderInfo
/// .downloaded`) means re-runs only fetch — and only copy — genuinely new stories, so
/// appends never duplicate. When it finishes, a summary lists the per-user counts
/// ("@spottssa 2 stories, @brenn_smith 4 stories"). Best-effort, opt-in, download-only.
struct AllStoriesView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let root: URL
    var onFinished: () -> Void = {}

    private struct StorySummary: Identifiable { let id = UUID(); let handle: String; let count: Int }

    @State private var loggedIn = false
    @State private var showLogin = false
    @State private var started = false
    @State private var running = false
    @State private var finished = false
    @State private var statusLine = ""
    @State private var overallDone = 0
    @State private var overallTotal = 0
    @State private var currentFraction = 0.0
    @State private var results: [StorySummary] = []
    @State private var upscaleVideos = false
    @State private var upscalePhotos = false

    /// Per-profile network outcome, applied to `Library` on the main actor after the concurrent fetch.
    private struct ProfileOutcome: Sendable {
        let url: URL; let info: IGFolderInfo; let userID: String
        let photos: Int; let videos: Int
        let captions: [String: String]; let postedBy: [String: String]
        let newIDs: [String]; let files: [String]; let copied: [String]
        let picData: Data?
    }

    /// Profile folders this sweep will cover (tracked Instagram folders still on disk).
    private var trackedCount: Int { library.instagramFolders.count }

    var body: some View {
        NavigationStack {
            Form {
                if trackedCount == 0 {
                    Section {
                        Label("No Instagram folders yet", systemImage: "camera")
                    } footer: {
                        Text("Download an Instagram profile first (More → Download Instagram Profile). Once a profile is saved, this checks all of them for new stories.")
                    }
                } else if !loggedIn {
                    Section {
                        Button { showLogin = true } label: {
                            Label("Log in to Instagram", systemImage: "person.badge.key")
                        }
                    } header: {
                        Text("\(trackedCount) profile\(trackedCount == 1 ? "" : "s") tracked")
                    } footer: {
                        Text("You log in inside the app; only the session cookie is kept, on this device.")
                    }
                } else if running {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            ProgressView(value: overallTotal > 0 ? Double(overallDone) / Double(overallTotal) : 0)
                            Text(statusLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            if currentFraction > 0 {
                                ProgressView(value: currentFraction).progressViewStyle(.linear)
                            }
                            Text("Keep the app open. It keeps going briefly if you switch away, but iOS can’t guarantee long background time.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("Checking \(overallTotal) profile\(overallTotal == 1 ? "" : "s") for new stories")
                    }
                } else if finished {
                    Section {
                        if results.isEmpty {
                            Label("No new stories found.", systemImage: "checkmark.circle")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(results) { r in
                                HStack {
                                    Label("@\(r.handle)", systemImage: "person.crop.circle")
                                    Spacer()
                                    Text("\(r.count) stor\(r.count == 1 ? "y" : "ies")")
                                        .foregroundStyle(.secondary).monospacedDigit()
                                }
                            }
                        }
                    } header: {
                        Text(totalFound == 0 ? "Done" : "Found \(totalFound) new stor\(totalFound == 1 ? "y" : "ies")")
                    } footer: {
                        if totalFound > 0 {
                            Text("Saved to each profile’s “Stories” folder and collected in “Today’s Instagram Stories”.")
                        }
                    }
                } else {
                    Section {
                        Toggle("Upscale videos to 1080p", isOn: $upscaleVideos)
                        Toggle("Double photo resolution (2×)", isOn: $upscalePhotos)
                    } header: {
                        Text("Enhance new stories (optional)")
                    } footer: {
                        Text("Applied to newly-downloaded stories, in place — capture dates are kept (videos keep HDR; photo HDR gain maps aren’t carried).")
                    }
                    Section {
                        Button { start() } label: {
                            Label("Get All New Stories", systemImage: "sparkles.rectangle.stack")
                        }
                    } header: {
                        Text("\(trackedCount) profile\(trackedCount == 1 ? "" : "s") tracked")
                    } footer: {
                        Text("Checks every saved Instagram profile for stories posted in the last 24 hours and downloads any you don’t already have.")
                    }
                }
            }
            .navigationTitle("All New Stories")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(running)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(finished ? "Done" : "Cancel") { dismiss() }.disabled(running)
                }
            }
            .sheet(isPresented: $showLogin) {
                InstagramLoginView {
                    Task { loggedIn = await InstagramAuth.isLoggedIn() }
                }
            }
            .task {
                loggedIn = await InstagramAuth.isLoggedIn()     // show the options screen; the user taps to run
            }
            // Keep the screen awake while the (potentially long) sweep runs.
            .onChange(of: running) { _, isRunning in UIApplication.shared.isIdleTimerDisabled = isRunning }
            .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        }
    }

    private var totalFound: Int { results.reduce(0) { $0 + $1.count } }

    private func start() {
        guard !started, trackedCount > 0 else { return }
        started = true
        Task {
            guard let creds = await InstagramAuth.credentials() else { started = false; showLogin = true; return }
            running = true; results = []
            let bg = BackgroundTaskHolder(); bg.begin(name: "Instagram Stories")

            // Snapshot the tracked Instagram folders that still exist on disk, A–Z by handle.
            // Include every tracked profile whose @handle folder exists *or* whose parent (person)
            // folder does — so "Set Handles" profiles (mapped but never downloaded) are checked too,
            // and the Stories folder is created on demand. Only truly-orphaned paths are skipped.
            // `hasCover` lets us skip the profile-pic refetch on re-runs (one fewer request each).
            let fm = FileManager.default
            let folders: [(url: URL, info: IGFolderInfo, hasCover: Bool)] = library.instagramFolders.compactMap { path, info in
                let url = URL(fileURLWithPath: path)
                var isDir: ObjCBool = false
                let folderExists = fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
                guard folderExists || fm.fileExists(atPath: url.deletingLastPathComponent().path) else { return nil }
                return (url, info, library.coverURL(for: url) != nil)
            }.sorted { $0.info.handle.localizedCaseInsensitiveCompare($1.info.handle) == .orderedAscending }
            overallTotal = folders.count

            // Shared temp folder: clear + replace once it ages past 24h, otherwise append.
            let now = Date().timeIntervalSince1970
            let tempFolder = library.prepareTodaysStoriesFolder(root: root)
            let tempPath = tempFolder.path

            var summary: [StorySummary] = []
            var newVideoFiles: [String] = []
            var newPhotoFiles: [String] = []
            var done = 0

            // Sweep the profiles concurrently (bounded) — each is independent. Kept modest to
            // avoid tripping Instagram's rate limiting.
            await withTaskGroup(of: ProfileOutcome?.self) { group in
                var idx = 0
                let maxConcurrent = 3
                func addNext() {
                    guard idx < folders.count else { return }
                    let f = folders[idx]; idx += 1
                    group.addTask { await Self.fetchStories(folder: f, creds: creds, tempPath: tempPath) }
                }
                for _ in 0..<min(maxConcurrent, folders.count) { addNext() }
                while let outcome = await group.next() {
                    done += 1; overallDone = done
                    statusLine = "Checked \(done) of \(folders.count)…"
                    if let o = outcome, o.photos + o.videos > 0 {
                        if let picData = o.picData, let img = UIImage(data: picData) { library.setCover(img, for: o.url) }
                        library.setCaptions(o.captions)
                        library.setPostedBy(o.postedBy)
                        var updated = o.info
                        updated.userID = o.userID
                        updated.downloaded = Array(Set(o.info.downloaded).union(o.newIDs))
                        updated.lastUpdated = now
                        updated.photos += o.photos
                        updated.videos += o.videos
                        library.setInstagramInfo(updated, for: o.url)
                        library.setStoryLinks(o.copied, to: o.url.appendingPathComponent("Stories", isDirectory: true))
                        summary.append(StorySummary(handle: o.info.handle, count: o.photos + o.videos))
                        for f in o.files {
                            switch classify(url: URL(fileURLWithPath: f), isDirectory: false) {
                            case .video: newVideoFiles.append(f)
                            case .image: newPhotoFiles.append(f)
                            default: break
                            }
                        }
                    }
                    addNext()
                }
            }
            overallDone = folders.count

            // Optional enhancement passes over the new stories (in place, dates preserved).
            if upscaleVideos, !newVideoFiles.isEmpty {
                await InstagramApply.upscaleVideosTo1080(newVideoFiles) { d, t in statusLine = "Upscaling videos to 1080p — \(d) of \(t)…" }
            }
            if upscalePhotos, !newPhotoFiles.isEmpty {
                await InstagramApply.upscalePhotos2x(newPhotoFiles) { d, t in statusLine = "Doubling photo resolution — \(d) of \(t)…" }
            }

            // Drop the shared folder if this run left it empty (nothing new to show).
            if let contents = try? FileManager.default.contentsOfDirectory(atPath: tempFolder.path), contents.isEmpty {
                try? FileManager.default.removeItem(at: tempFolder)
            }

            results = summary.sorted { $0.count > $1.count }
            running = false; finished = true; bg.end()
            library.contentDidChange()
            onFinished()
        }
    }

    /// One profile's story fetch — pure network/file work, off the main actor; results are applied
    /// to `Library` by the caller. Skips the profile-pic request when the folder already has a cover.
    nonisolated private static func fetchStories(
        folder: (url: URL, info: IGFolderInfo, hasCover: Bool),
        creds: InstagramService.Credentials, tempPath: String) async -> ProfileOutcome? {
        var userID = folder.info.userID
        if userID.isEmpty { userID = await InstagramService.fetchProfile(handle: folder.info.handle, creds: creds)?.userID ?? "" }
        guard !userID.isEmpty else { return nil }
        let picData = folder.hasCover ? nil
            : await InstagramService.fetchProfilePic(userID: userID, handle: folder.info.handle, creds: creds, fallback: "")
        let storiesFolder = folder.url.appendingPathComponent("Stories", isDirectory: true)
        try? FileManager.default.createDirectory(at: storiesFolder, withIntermediateDirectories: true)   // create @handle/Stories on demand
        let r = await InstagramService.runStories(handle: folder.info.handle, userID: userID, into: storiesFolder,
                                                  already: Set(folder.info.downloaded), creds: creds) { _ in }
        guard r.photos + r.videos > 0 else {
            return ProfileOutcome(url: folder.url, info: folder.info, userID: userID, photos: 0, videos: 0,
                                  captions: [:], postedBy: [:], newIDs: [], files: [], copied: [], picData: picData)
        }
        let copied = await InstagramService.copyToTemp(r.files, handle: folder.info.handle, into: URL(fileURLWithPath: tempPath))
        return ProfileOutcome(url: folder.url, info: folder.info, userID: userID, photos: r.photos, videos: r.videos,
                              captions: r.captions, postedBy: r.postedBy, newIDs: r.newIDs, files: r.files,
                              copied: copied, picData: picData)
    }
}

/// Full-screen viewer for an Instagram folder's profile photo (the folder cover, which
/// holds the highest-resolution profile picture). Pinch/double-tap to zoom; swipe down
/// or tap the close button to exit. Reached via long-press → "View Profile Photo".
struct ProfilePhotoView: View {
    let url: URL
    var onClose: () -> Void = {}

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ZoomableImageView(url: url, onDismiss: onClose)
        }
        .overlay(alignment: .topLeading) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.headline).foregroundStyle(.white)
                    .padding(10).background(.ultraThinMaterial, in: Circle())
            }
            .padding(.top, 50).padding(.leading, 16)
        }
        .statusBarHidden()
    }
}
