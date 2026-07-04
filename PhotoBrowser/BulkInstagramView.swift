import SwiftUI
import UIKit

/// "Bulk Download Instagram Profiles" — map existing folders on the drive to Instagram
/// handles, then either **Set Handles** (just save the folder ⇄ handle mappings, no
/// download) or **Download** every mapped profile in one pass. Each download is identical
/// to a single import (posts + tagged → the folder, stories → its "Stories" subfolder,
/// highlights → their own bubble subfolders, HD profile-photo cover, captions/"posted
/// by"/dates), and any stories found today are also collected into the shared
/// "Today's Instagram Stories" folder. Already-downloaded profiles get an incremental
/// **"new posts only"** check instead of being skipped. Handles are remembered per
/// folder for next time.
///
/// The download itself runs on `Library` as an **app-wide activity** (progress pill +
/// completion popup), so this sheet can be closed and the app navigated freely while
/// it runs — it also keeps going briefly when the app is backgrounded.
struct BulkInstagramView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let root: URL
    var onFinished: () -> Void = {}

    /// One folder ⇄ handle row. `handle` is edited inline; blank rows are skipped.
    struct Mapping: Identifiable {
        let id = UUID()
        let folder: URL
        let name: String
        var handle: String
    }
    @State private var mappings: [Mapping] = []
    @State private var loadingFolders = true
    @State private var loggedIn = false
    @State private var showLogin = false
    @State private var running = false           // "Set Handles" runs in-sheet (it's quick)
    @State private var finished = false
    @State private var statusLine = ""
    @State private var overallDone = 0
    @State private var overallTotal = 0
    @State private var setResultCount: Int?      // non-nil when the finished screen is a Set summary
    @State private var skipTagged = false
    @State private var upscale1080 = false

    private var readyCount: Int { mappings.filter { !cleanHandle($0.handle).isEmpty }.count }

    var body: some View {
        NavigationStack {
            Group {
                if running {
                    runningView
                } else if finished {
                    summaryView
                } else {
                    mappingForm
                }
            }
            .navigationTitle("Bulk Instagram Download")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(running)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(finished ? "Done" : "Cancel") { dismiss() }.disabled(running)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if !running && !finished {
                        Button(library.bulkIGRunning ? "Downloading…" : "Download (\(readyCount))") { start() }
                            .disabled(!loggedIn || readyCount == 0 || library.bulkIGRunning)
                    }
                }
            }
            .sheet(isPresented: $showLogin) {
                InstagramLoginView { Task { loggedIn = await InstagramAuth.isLoggedIn() } }
            }
            .task {
                loggedIn = await InstagramAuth.isLoggedIn()
                await loadFolders()
            }
            // Keep the screen awake while a (potentially long) download runs.
            .onChange(of: running) { _, isRunning in UIApplication.shared.isIdleTimerDisabled = isRunning }
            .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        }
    }

    // MARK: - Phases

    private var mappingForm: some View {
        Form {
            if !loggedIn {
                Section {
                    Button { showLogin = true } label: {
                        Label("Log in to Instagram", systemImage: "person.badge.key")
                    }
                } footer: {
                    Text("You log in inside the app; only the session cookie is kept, on this device.")
                }
            }
            Section {
                if loadingFolders {
                    HStack { ProgressView(); Text("Loading folders…").foregroundStyle(.secondary) }
                } else if mappings.isEmpty {
                    Text("No subfolders here to map.").foregroundStyle(.secondary)
                } else {
                    ForEach($mappings) { $m in
                        VStack(alignment: .leading, spacing: 4) {
                            Label(m.name, systemImage: "folder").font(.subheadline.weight(.medium))
                            TextField("instagram handle (e.g. nasa)", text: $m.handle)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                .keyboardType(.URL).font(.callout)
                        }
                    }
                }
            } header: {
                Text("Map folders to handles")
            } footer: {
                Text("Type a handle next to each folder you want to fill. Blank folders are skipped. “Download” pulls posts, tagged media, stories and highlights into each folder — just like a single Instagram download — and today's stories are also added to “Today's Instagram Stories”. Profiles that are already downloaded are checked for new posts. The run continues app-wide: close this sheet and keep browsing.")
            }

            if !mappings.isEmpty {
                Section("Options") {
                    Toggle("Skip tagged photos & videos", isOn: $skipTagged)
                    Toggle("Upscale videos to 1080p", isOn: $upscale1080)
                }
                Section {
                    Button { setHandles() } label: {
                        Label("Set Handles Without Downloading", systemImage: "tag")
                    }
                    .disabled(readyCount == 0)
                } footer: {
                    Text("Saves each handle to its folder (marking it an Instagram folder) without downloading now. Pull the media later — per profile, with Download here, or via “Get All New Instagram Stories”.")
                }
            }
        }
    }

    private var runningView: some View {
        VStack(spacing: 20) {
            Spacer()
            ProgressView(value: overallTotal > 0 ? Double(overallDone) / Double(overallTotal) : 0)
                .progressViewStyle(.linear).frame(width: 260)
            Text(statusLine).font(.subheadline).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle).frame(maxWidth: 280)
            Text("Saving \(overallTotal) handle\(overallTotal == 1 ? "" : "s")…")
                .font(.caption2).foregroundStyle(.tertiary)
            Spacer()
        }
        .padding()
    }

    private var summaryView: some View {
        Form {
            Section {
                Label("Set \(setResultCount ?? 0) handle\(setResultCount == 1 ? "" : "s").", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
            } footer: {
                Text("These folders are now mapped to their handles. Download their media anytime — per profile, here with Download, or via “Get All New Instagram Stories”.")
            }
        }
    }

    // MARK: - Data

    /// Lists the immediate subfolders of the drive root (the usual "person folder"
    /// level), prefilling any handle we already remember for each.
    private func loadFolders() async {
        let subfolders = await library.listing(of: root, sort: .nameAsc)
            .filter { $0.isFolder && $0.name != "Today's Instagram Stories" }
        mappings = subfolders.map { entry in
            // The remembered handle is kept on the person folder, so it prefills next time.
            Mapping(folder: entry.url, name: entry.name, handle: library.lastIGHandle(for: entry.url) ?? "")
        }
        loadingFolders = false
    }

    /// The Instagram folder for a person folder: a "@handle" subfolder inside it, so the
    /// person folder stays a regular folder and the nested folder is the bubble.
    private func igFolder(for person: URL, handle: String) -> URL {
        person.appendingPathComponent(handle, isDirectory: true)
    }

    private func cleanHandle(_ raw: String) -> String {
        var h = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = h.range(of: "instagram.com/") { h = String(h[r.upperBound...]) }
        h = String(h.split(separator: "/").first ?? "")
        h = String(h.split(separator: "?").first ?? "")
        return h.replacingOccurrences(of: "@", with: "")
    }

    // MARK: - Run

    /// Hands the mapped profiles to `Library`, which runs the whole pass app-wide
    /// (progress pill + completion popup) — then closes this sheet. Fresh profiles
    /// download fully; already-downloaded ones are checked for new posts.
    private func start() {
        let jobs = mappings.compactMap { m -> Library.BulkIGJob? in
            let h = cleanHandle(m.handle)
            return h.isEmpty ? nil : Library.BulkIGJob(folder: m.folder, name: m.name, handle: h)
        }
        guard !jobs.isEmpty else { return }
        library.startBulkInstagramDownload(jobs: jobs, root: root,
                                           skipTagged: skipTagged, upscale1080: upscale1080)
        onFinished()
        dismiss()
    }

    /// Saves the folder ⇄ handle mappings without downloading any media: each mapped
    /// folder becomes a tracked Instagram folder (its handle remembered), with the user
    /// id — and a profile-photo cover — resolved when logged in. Existing download
    /// records (ids/counts) are preserved.
    private func setHandles() {
        Task {
            let creds = await InstagramAuth.credentials()
            let jobs = mappings.compactMap { m -> (folder: URL, name: String, handle: String)? in
                let h = cleanHandle(m.handle)
                return h.isEmpty ? nil : (m.folder, m.name, h)
            }
            guard !jobs.isEmpty else { return }
            running = true; setResultCount = nil
            overallTotal = jobs.count
            let now = Date().timeIntervalSince1970
            for (i, job) in jobs.enumerated() {
                overallDone = i
                statusLine = "@\(job.handle) → \(job.name) (\(i + 1) of \(jobs.count))…"
                // Register the "@handle" subfolder (a bubble inside the regular person folder).
                let dest = igFolder(for: job.folder, handle: job.handle)
                try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
                var info = library.instagramInfo(for: dest)
                    ?? IGFolderInfo(handle: job.handle, userID: "", lastUpdated: now,
                                    downloaded: [], photos: 0, videos: 0)
                info.handle = job.handle
                // Resolve the user id (and refresh the cover to the HD profile photo) when possible.
                if let creds, info.userID.isEmpty,
                   let profile = await InstagramService.fetchProfile(handle: job.handle, creds: creds) {
                    info.userID = profile.userID
                    if let data = await InstagramService.fetchProfilePic(
                        userID: profile.userID, handle: profile.handle, creds: creds, fallback: profile.profilePicURL),
                       let img = UIImage(data: data) {
                        library.setCover(img, for: dest)
                    }
                }
                library.setInstagramInfo(info, for: dest)
                library.setLastIGHandle(job.handle, for: job.folder)
            }
            overallDone = jobs.count
            setResultCount = jobs.count
            running = false; finished = true
            library.contentDidChange()
            onFinished()
        }
    }
}
