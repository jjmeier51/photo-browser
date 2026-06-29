import SwiftUI
import UIKit

/// "Get All New Instagram Stories" — a homepage sweep that walks every tracked Instagram profile
/// folder on the drive and pulls each user's current (last-24h) stories into their own "Stories"
/// subfolder, then gathers the collective new stories into a shared **"Today's Instagram Stories"**
/// folder at the drive root.
///
/// This screen is just a launcher: pick the options and tap once. The sweep then runs as an
/// app-wide background activity (progress pill + completion popup, see ContentView), so you can
/// navigate the app and use it while it runs. Best-effort, opt-in, download-only.
struct AllStoriesView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let root: URL
    var onFinished: () -> Void = {}

    private struct StorySummary: Sendable { let handle: String; let count: Int }

    @State private var loggedIn = false
    @State private var showLogin = false
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
                        Text("Checks every saved Instagram profile for stories posted in the last 24 hours. It runs in the background — you can keep using the app and watch its progress at the bottom of the screen.")
                    }
                }
            }
            .navigationTitle("All New Stories")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .sheet(isPresented: $showLogin) {
                InstagramLoginView { Task { loggedIn = await InstagramAuth.isLoggedIn() } }
            }
            .task { loggedIn = await InstagramAuth.isLoggedIn() }
        }
    }

    private func start() {
        guard trackedCount > 0 else { return }
        let upVideos = upscaleVideos, upPhotos = upscalePhotos
        let rootURL = root
        let finish = onFinished
        let id = library.beginActivity("Checking stories", indeterminate: true)
        library.setActivity(id, status: "Starting…")
        dismiss()        // let the user navigate; the sweep runs in the background
        let bg = BackgroundTaskHolder(); bg.begin(name: "Instagram Stories")
        Task {
            guard let creds = await InstagramAuth.credentials() else {
                library.endActivity(id, result: "Couldn’t start — not logged in to Instagram."); bg.end(); return
            }
            let fm = FileManager.default
            let folders: [(url: URL, info: IGFolderInfo, hasCover: Bool)] = library.instagramFolders.compactMap { path, info in
                let url = URL(fileURLWithPath: path)
                var isDir: ObjCBool = false
                let folderExists = fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
                guard folderExists || fm.fileExists(atPath: url.deletingLastPathComponent().path) else { return nil }
                return (url, info, library.coverURL(for: url) != nil)
            }.sorted { $0.info.handle.localizedCaseInsensitiveCompare($1.info.handle) == .orderedAscending }

            let now = Date().timeIntervalSince1970
            let tempFolder = library.prepareTodaysStoriesFolder(root: rootURL)
            let tempPath = tempFolder.path

            var summary: [StorySummary] = []
            var newVideoFiles: [String] = [], newPhotoFiles: [String] = []
            var done = 0
            let total = folders.count

            await withTaskGroup(of: ProfileOutcome?.self) { group in
                var idx = 0
                let maxConcurrent = 3        // modest — avoid tripping Instagram's rate limiting
                func addNext() {
                    guard idx < folders.count else { return }
                    let f = folders[idx]; idx += 1
                    group.addTask { await Self.fetchStories(folder: f, creds: creds, tempPath: tempPath) }
                }
                for _ in 0..<min(maxConcurrent, folders.count) { addNext() }
                while let outcome = await group.next() {
                    done += 1
                    library.setActivity(id, status: "Checked \(done) of \(total)…", fraction: total > 0 ? Double(done) / Double(total) : 0)
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

            if upVideos, !newVideoFiles.isEmpty {
                await InstagramApply.upscaleVideosTo1080(newVideoFiles) { d, t in library.setActivity(id, status: "Upscaling videos — \(d) of \(t)…") }
            }
            if upPhotos, !newPhotoFiles.isEmpty {
                await InstagramApply.upscalePhotos2x(newPhotoFiles) { d, t in library.setActivity(id, status: "Doubling photos — \(d) of \(t)…") }
            }

            if let contents = try? fm.contentsOfDirectory(atPath: tempFolder.path), contents.isEmpty {
                try? fm.removeItem(at: tempFolder)
            }

            let found = summary.reduce(0) { $0 + $1.count }
            library.endActivity(id, result: found == 0
                ? "No new Instagram stories found."
                : "Downloaded \(found) new stor\(found == 1 ? "y" : "ies") from \(summary.count) profile\(summary.count == 1 ? "" : "s").")
            library.contentDidChange()
            finish()
            bg.end()
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

/// Full-screen viewer for an Instagram folder's profile photo (the folder cover, which holds the
/// highest-resolution profile picture). Pinch/double-tap to zoom; swipe down or tap the close button
/// to exit. Reached via long-press → "View Profile Photo".
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
