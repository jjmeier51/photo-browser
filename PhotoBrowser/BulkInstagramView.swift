import SwiftUI
import UIKit

/// "Bulk Download Instagram Profiles" — map existing folders on the drive to Instagram
/// handles, then either **Set Handles** (just save the folder ⇄ handle mappings, no
/// download) or **Download** every mapped profile in one pass. Each download is identical
/// to a single import (posts + tagged → the folder, stories → its "Stories" subfolder,
/// highlights → their own bubble subfolders, HD profile-photo cover, captions/"posted
/// by"/dates), and any stories found today are also collected into the shared
/// "Today's Instagram Stories" folder. The download pass **skips** any folder that's
/// already a downloaded Instagram profile (its record shows ≥1 pulled item). Handles are
/// remembered per folder for next time.
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
    struct BulkSummary: Identifiable {
        let id = UUID()
        let name: String
        let handle: String
        let photos: Int
        let videos: Int
        let stories: Int
        let note: String?
    }

    @State private var mappings: [Mapping] = []
    @State private var loadingFolders = true
    @State private var loggedIn = false
    @State private var showLogin = false
    @State private var running = false
    @State private var finished = false
    @State private var statusLine = ""
    @State private var overallDone = 0
    @State private var overallTotal = 0
    @State private var currentFraction = 0.0
    @State private var results: [BulkSummary] = []
    @State private var settingMode = false       // true while "Set Handles" runs (vs. download)
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
                        Button("Download (\(readyCount))") { start() }
                            .disabled(!loggedIn || readyCount == 0)
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
                Text("Type a handle next to each folder you want to fill. Blank folders are skipped. “Download” pulls posts, tagged media, stories and highlights into each folder — just like a single Instagram download — and today's stories are also added to “Today's Instagram Stories”. Folders that are already downloaded profiles are skipped.")
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
            if currentFraction > 0 {
                ProgressView(value: currentFraction).progressViewStyle(.linear).frame(width: 220)
            }
            Text(settingMode
                 ? "Saving \(overallTotal) handle\(overallTotal == 1 ? "" : "s")…"
                 : "Downloading \(overallTotal) profile\(overallTotal == 1 ? "" : "s"). Keep the app open.")
                .font(.caption2).foregroundStyle(.tertiary)
            Spacer()
        }
        .padding()
    }

    private var summaryView: some View {
        if let count = setResultCount {
            return AnyView(Form {
                Section {
                    Label("Set \(count) handle\(count == 1 ? "" : "s").", systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                } footer: {
                    Text("These folders are now mapped to their handles. Download their media anytime — per profile, here with Download, or via “Get All New Instagram Stories”.")
                }
            })
        }
        return AnyView(Form {
            Section {
                if results.isEmpty {
                    Label("Nothing downloaded.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                } else {
                    ForEach(results) { r in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Label("@\(r.handle)", systemImage: "person.crop.circle")
                                Spacer()
                                Text("\(r.photos + r.videos) item\(r.photos + r.videos == 1 ? "" : "s")")
                                    .foregroundStyle(.secondary).monospacedDigit()
                            }
                            Text(detail(r)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text(totalItems == 0 ? "Done" : "Downloaded \(totalItems) item\(totalItems == 1 ? "" : "s")")
            }
        })
    }

    private func detail(_ r: BulkSummary) -> String {
        if let note = r.note, r.photos + r.videos == 0 { return note }
        var parts: [String] = []
        if r.photos > 0 { parts.append("\(r.photos) photo\(r.photos == 1 ? "" : "s")") }
        if r.videos > 0 { parts.append("\(r.videos) video\(r.videos == 1 ? "" : "s")") }
        if r.stories > 0 { parts.append("\(r.stories) stor\(r.stories == 1 ? "y" : "ies") today") }
        return "\(r.name) — " + (parts.isEmpty ? "no new media" : parts.joined(separator: ", "))
    }

    private var totalItems: Int { results.reduce(0) { $0 + $1.photos + $1.videos } }

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

    private func start() {
        Task {
            guard let creds = await InstagramAuth.credentials() else { showLogin = true; return }
            let jobs = mappings.compactMap { m -> (folder: URL, name: String, handle: String)? in
                let h = cleanHandle(m.handle)
                return h.isEmpty ? nil : (m.folder, m.name, h)
            }
            guard !jobs.isEmpty else { return }
            running = true; results = []; settingMode = false; setResultCount = nil
            overallTotal = jobs.count
            let bg = BackgroundTaskHolder(); bg.begin(name: "Bulk Instagram Download")

            // Shared rolling temp folder (append within 24h, replace across days).
            let tempFolder = library.prepareTodaysStoriesFolder(root: root)

            for (i, job) in jobs.enumerated() {
                overallDone = i
                currentFraction = 0
                statusLine = "@\(job.handle) → \(job.name) (\(i + 1) of \(jobs.count))…"
                library.setLastIGHandle(job.handle, for: job.folder)     // remember the mapping

                // The Instagram folder lives *inside* the person folder, so the person
                // folder stays a regular folder and only the "@handle" folder is a bubble.
                let dest = igFolder(for: job.folder, handle: job.handle)

                // Skip folders that are already a downloaded Instagram profile (≥1 pulled item).
                if alreadyDownloaded(dest) {
                    results.append(BulkSummary(name: job.name, handle: job.handle,
                                               photos: 0, videos: 0, stories: 0,
                                               note: "Skipped — already downloaded"))
                    continue
                }
                try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

                let prior = library.instagramInfo(for: dest)
                let already = Set(prior?.downloaded ?? [])
                let r = await InstagramService.run(handle: job.handle, into: dest, alreadyDownloaded: already,
                                                   creds: creds, includeTagged: !skipTagged) { p in
                    Task { @MainActor in currentFraction = p.fraction }
                }
                await InstagramApply.apply(r, to: dest, already: already, prior: prior,
                                           forceFull: false, library: library)
                if upscale1080 {
                    await InstagramApply.upscaleVideosTo1080(r.files) { done, total in
                        statusLine = "@\(job.handle): upscaling videos — \(done) of \(total)…"
                    }
                }

                // Any stories pulled this run are today's — collect them into the shared folder.
                let storiesFolder = dest.appendingPathComponent("Stories", isDirectory: true)
                let storyFiles = r.files.filter { $0.hasPrefix(storiesFolder.path + "/") }
                if !storyFiles.isEmpty {
                    let copied = await InstagramService.copyToTemp(storyFiles, handle: job.handle, into: tempFolder)
                    library.setStoryLinks(copied, to: storiesFolder)        // metadata link → person's Stories
                }

                results.append(BulkSummary(name: job.name, handle: job.handle,
                                           photos: r.photos, videos: r.videos,
                                           stories: storyFiles.count, note: r.note))
            }
            overallDone = jobs.count

            // Drop the shared folder if this run added nothing to it.
            if let contents = try? FileManager.default.contentsOfDirectory(atPath: tempFolder.path), contents.isEmpty {
                try? FileManager.default.removeItem(at: tempFolder)
            }

            running = false; finished = true; bg.end()
            library.contentDidChange()
            onFinished()
        }
    }

    /// True when `folder` (or an immediate subfolder, for the single-download "@handle"
    /// layout) is already a tracked Instagram profile whose record shows pulled content.
    /// Uses the `IGFolderInfo` counters rather than counting files on disk, so a folder
    /// that merely has the handle *set* (or unrelated photos) isn't mistaken for done.
    private func alreadyDownloaded(_ folder: URL) -> Bool {
        func hasContent(_ url: URL) -> Bool {
            guard let info = library.instagramInfo(for: url) else { return false }
            return info.photos + info.videos > 0 || !info.downloaded.isEmpty
        }
        if hasContent(folder) { return true }
        let children = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return children.contains { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true && hasContent($0) }
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
            running = true; settingMode = true; results = []
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
