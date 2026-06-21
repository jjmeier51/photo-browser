import SwiftUI

/// "Bulk Download Instagram Profiles" — map existing folders on the drive to Instagram
/// handles, then download every mapped profile in one pass. Each download is identical
/// to a single import (posts + tagged → the folder, stories → its "Stories" subfolder,
/// highlights → their own bubble subfolders, HD profile-photo cover, captions/"posted
/// by"/dates), and any stories found today are also collected into the shared
/// "Today's Instagram Stories" folder. Handles are remembered per folder for next time.
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
                Text("Type a handle next to each folder you want to fill. Blank folders are skipped. Each downloads posts, tagged media, stories and highlights into that folder — just like a single Instagram download — and today's stories are also added to “Today's Instagram Stories”.")
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
            Text("Downloading \(overallTotal) profile\(overallTotal == 1 ? "" : "s"). Keep the app open.")
                .font(.caption2).foregroundStyle(.tertiary)
            Spacer()
        }
        .padding()
    }

    private var summaryView: some View {
        Form {
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
        }
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
            let prefilled = library.instagramInfo(for: entry.url)?.handle
                ?? library.lastIGHandle(for: entry.url) ?? ""
            return Mapping(folder: entry.url, name: entry.name, handle: prefilled)
        }
        loadingFolders = false
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
            running = true; results = []
            overallTotal = jobs.count
            let bg = BackgroundTaskHolder(); bg.begin(name: "Bulk Instagram Download")

            // Shared rolling temp folder (append within 24h, replace across days).
            let tempFolder = library.prepareTodaysStoriesFolder(root: root)

            for (i, job) in jobs.enumerated() {
                overallDone = i
                currentFraction = 0
                statusLine = "@\(job.handle) → \(job.name) (\(i + 1) of \(jobs.count))…"
                library.setLastIGHandle(job.handle, for: job.folder)     // remember the mapping

                let prior = library.instagramInfo(for: job.folder)
                let already = Set(prior?.downloaded ?? [])
                let r = await InstagramService.run(handle: job.handle, into: job.folder,
                                                   alreadyDownloaded: already, creds: creds) { p in
                    Task { @MainActor in currentFraction = p.fraction }
                }
                await InstagramApply.apply(r, to: job.folder, already: already, prior: prior,
                                           forceFull: false, library: library)

                // Any stories pulled this run are today's — collect them into the shared folder.
                let storiesPrefix = job.folder.appendingPathComponent("Stories", isDirectory: true).path + "/"
                let storyFiles = r.files.filter { $0.hasPrefix(storiesPrefix) }
                if !storyFiles.isEmpty {
                    await InstagramService.copyToTemp(storyFiles, handle: job.handle, into: tempFolder)
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
}
