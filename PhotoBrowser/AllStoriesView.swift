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
                    Task {
                        loggedIn = await InstagramAuth.isLoggedIn()
                        if loggedIn { start() }                 // tap-through: log in then run
                    }
                }
            }
            .task {
                loggedIn = await InstagramAuth.isLoggedIn()
                if loggedIn && trackedCount > 0 { start() }     // auto-run when ready
            }
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
            let folders: [(url: URL, info: IGFolderInfo)] = library.instagramFolders.compactMap { path, info in
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return nil }
                return (url: URL(fileURLWithPath: path), info: info)
            }.sorted { $0.info.handle.localizedCaseInsensitiveCompare($1.info.handle) == .orderedAscending }
            overallTotal = folders.count

            // Shared temp folder: clear + replace once it ages past 24h, otherwise append.
            let now = Date().timeIntervalSince1970
            let tempFolder = library.prepareTodaysStoriesFolder(root: root)

            var summary: [StorySummary] = []
            for (i, entry) in folders.enumerated() {
                statusLine = "@\(entry.info.handle) (\(i + 1) of \(folders.count))…"
                currentFraction = 0
                // Older records may predate stored user ids — resolve via the profile.
                var userID = entry.info.userID
                if userID.isEmpty {
                    userID = await InstagramService.fetchProfile(handle: entry.info.handle, creds: creds)?.userID ?? ""
                }
                overallDone = i
                guard !userID.isEmpty else { continue }

                // Refresh the folder cover to the user's highest-resolution profile photo.
                if let picData = await InstagramService.fetchProfilePic(
                    userID: userID, handle: entry.info.handle, creds: creds, fallback: ""),
                   let img = UIImage(data: picData) {
                    library.setCover(img, for: entry.url)
                }

                let storiesFolder = entry.url.appendingPathComponent("Stories", isDirectory: true)
                let already = Set(entry.info.downloaded)
                let r = await InstagramService.runStories(
                    handle: entry.info.handle, userID: userID, into: storiesFolder,
                    already: already, creds: creds) { p in
                        Task { @MainActor in currentFraction = p.fraction }
                    }

                let n = r.photos + r.videos
                if n > 0 {
                    library.setCaptions(r.captions)
                    library.setPostedBy(r.postedBy)
                    var updated = entry.info
                    updated.userID = userID
                    updated.downloaded = Array(already.union(r.newIDs))
                    updated.lastUpdated = now
                    updated.photos += r.photos
                    updated.videos += r.videos
                    library.setInstagramInfo(updated, for: entry.url)
                    await InstagramService.copyToTemp(r.files, handle: entry.info.handle, into: tempFolder)
                    summary.append(StorySummary(handle: entry.info.handle, count: n))
                }
            }
            overallDone = folders.count

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
