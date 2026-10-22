import SwiftUI

/// The **Received** sheet: archives that reached the app as files — an AirDrop from the Mac
/// (`mac/airdrop_to_iphone.py` makes `.pbgallery` archives; the phone's "Open with ▸ Photo Browser"
/// delivers them), a zip opened from Files, or an archive shared through the extension — and where
/// on the drive they go. Several arrive together (one AirDrop of a star's galleries), so they're
/// listed as a batch: one destination folder, and each archive unpacks into its own folder there,
/// named after the folder that was sent. A Mac-made archive (or a Finder-zipped folder) carries that
/// folder at its top level; it's dropped on the way out so a gallery lands as
/// `<destination>/<Gallery Name>/…` with `gallery.json` beside the photos, not two levels deep.
///
/// A folder that already exists is **merged** into — re-sending a gallery only adds what's new, the
/// way the Mac downloaders re-run — unless "Keep both" is chosen, which numbers the new one.
/// Extraction runs one archive at a time off the main actor under a background-task window; an
/// archive leaves staging only once it unpacked completely, so a failure keeps it listed for another
/// try (a fresh, half-written folder is removed). "Later" keeps everything staged.
struct ReceivedArchivesView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss

    @State private var destination: URL?
    @State private var showFolderPicker = false
    @State private var merge = true
    @State private var peeks: [String: Archiver.Peek] = [:]
    @State private var running = false
    @State private var currentID: String?
    @State private var position = 0           // 1-based index of the archive being unpacked
    @State private var batchCount = 0
    @State private var progress = 0.0
    @State private var results: [String] = []
    @State private var failures: [String: String] = [:]
    @State private var confirmDiscardAll = false

    private var archives: [ArchiveIntake.Received] { library.pendingArchives }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if archives.isEmpty {
                        Text(results.isEmpty ? "Nothing waiting." : "All unpacked.").foregroundStyle(.secondary)
                    }
                    ForEach(archives) { item in
                        row(item)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) { library.discardArchive(item) } label: {
                                    Label("Discard", systemImage: "trash")
                                }
                                .disabled(running)
                            }
                    }
                } header: {
                    Text(archives.count <= 1 ? "Received" : "Received (\(archives.count))")
                } footer: {
                    if !archives.isEmpty { Text("Swipe an archive left to discard it without unpacking.") }
                }

                Section {
                    Button { showFolderPicker = true } label: {
                        HStack {
                            Label(destination.map(displayPath) ?? "Choose a folder…", systemImage: "folder")
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(running || library.rootURL == nil)
                    Picker("If a folder already exists", selection: $merge) {
                        Text("Merge").tag(true)
                        Text("Keep both").tag(false)
                    }
                    .disabled(running)
                } header: {
                    Text("Save to")
                } footer: {
                    Text("Each archive becomes its own folder here, named after the folder that was sent. Merge adds a re-sent gallery's new photos to the folder it already has; Keep both makes a numbered copy.")
                }

                if running {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(unpackingLabel).font(.callout)
                            ProgressView(value: progress)
                        }
                    }
                }

                if !results.isEmpty {
                    Section("Done") {
                        ForEach(results, id: \.self) { Text($0).font(.callout).foregroundStyle(.secondary) }
                    }
                }

                if library.rootURL == nil {
                    Section {
                        Text("Open your drive folder in the app first, then come back here (Settings ▸ Received Archives).")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                }

                if archives.count > 1 {
                    Section {
                        Button("Discard All…", role: .destructive) { confirmDiscardAll = true }.disabled(running)
                    }
                }
            }
            .navigationTitle("Received")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(archives.isEmpty ? "Done" : "Later") { dismiss() }.disabled(running)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { start() }
                        .disabled(running || destination == nil || archives.isEmpty)
                }
            }
            .confirmationDialog("Discard all received archives?", isPresented: $confirmDiscardAll, titleVisibility: .visible) {
                Button("Discard \(archives.count) Archives", role: .destructive) {
                    for item in archives { library.discardArchive(item) }
                }
            } message: {
                Text("They haven't been unpacked — you'd have to AirDrop them again.")
            }
            .sheet(isPresented: $showFolderPicker) {
                if let root = library.rootURL {
                    FolderPicker(root: root, confirmTitle: "Save Here", startAt: destination) { destination = $0 }
                        .environment(library)
                }
            }
        }
        .interactiveDismissDisabled(running)
        .onAppear { if destination == nil { destination = defaultDestination() } }
        .onChange(of: library.rootURL) { if destination == nil { destination = defaultDestination() } }
        .task(id: archives.map(\.id)) { await peekAll() }
    }

    // MARK: - Rows

    private func row(_ item: ArchiveIntake.Received) -> some View {
        let failed = failures[item.id] != nil
        return HStack(spacing: 12) {
            Image(systemName: currentID == item.id ? "arrow.down.circle" : (failed ? "exclamationmark.triangle" : "archivebox"))
                .foregroundStyle(failed ? Color.orange : Color.accentColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(folderName(for: item)).lineLimit(2)
                Text(subtitle(for: item)).font(.caption).foregroundStyle(.secondary)
                if let why = failures[item.id] {
                    Text(why).font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }

    /// The folder the archive becomes: its single top-level folder, else the archive's own name.
    private func folderName(for item: ArchiveIntake.Received) -> String {
        peeks[item.id]?.topFolder ?? item.title
    }

    private func subtitle(for item: ArchiveIntake.Received) -> String {
        guard let p = peeks[item.id] else { return item.size.sizeString }
        var parts: [String] = []
        if p.photos > 0 { parts.append("\(p.photos) photo\(p.photos == 1 ? "" : "s")") }
        if p.videos > 0 { parts.append("\(p.videos) video\(p.videos == 1 ? "" : "s")") }
        if parts.isEmpty { parts.append("\(p.files) file\(p.files == 1 ? "" : "s")") }
        parts.append(p.bytes.sizeString)
        return parts.joined(separator: " · ")
    }

    private var unpackingLabel: String {
        let name = archives.first { $0.id == currentID }.map(folderName(for:)) ?? ""
        return "Unpacking “\(name)”… (\(position) of \(batchCount))"
    }

    /// The destination shown relative to the drive root ("Porn ▸ Lucie Wilde"), or the root's name.
    private func displayPath(_ url: URL) -> String {
        guard let root = library.rootURL else { return url.lastPathComponent }
        let rc = root.standardizedFileURL.pathComponents, dc = url.standardizedFileURL.pathComponents
        guard dc.count > rc.count, Array(dc.prefix(rc.count)) == rc else { return url.lastPathComponent }
        return dc[rc.count...].joined(separator: " ▸ ")
    }

    /// Where the last batch went (if it still exists), else the folder open in the app, else the root.
    private func defaultDestination() -> URL? {
        if let d = library.lastArchiveDestination, FileManager.default.fileExists(atPath: d.path) { return d }
        return library.path.last ?? library.rootURL
    }

    /// Reads each archive's central directory (off-main) for the name, counts and size in its row.
    private func peekAll() async {
        for item in archives where peeks[item.id] == nil {
            let url = item.url
            if let p = await Task.detached(priority: .utility) { try? Archiver.peek(url) }.value {
                peeks[item.id] = p
            }
        }
    }

    // MARK: - Unpacking

    private func start() {
        guard let dest = destination else { return }
        let batch = archives
        let mergeExisting = merge
        running = true; failures = [:]; batchCount = batch.count; position = 0
        let bg = BackgroundTaskHolder(); bg.begin(name: "Unpack Received Archives")
        Task {
            var saved: [String] = []
            for item in batch {
                position += 1; currentID = item.id; progress = 0
                let outcome: (folder: URL?, error: String?) = await Task.detached(priority: .userInitiated) { () -> (URL?, String?) in
                    let fm = FileManager.default
                    let name = (try? Archiver.peek(item.url))?.topFolder ?? item.title
                    var folder = dest.appendingPathComponent(name, isDirectory: true)
                    if !mergeExisting {
                        var n = 2
                        while fm.fileExists(atPath: folder.path) {
                            folder = dest.appendingPathComponent("\(name) \(n)", isDirectory: true); n += 1
                        }
                    }
                    let fresh = !fm.fileExists(atPath: folder.path)
                    do {
                        try await Archiver.unzip(item.url, to: folder, dropTopFolder: true) { f in
                            Task { @MainActor in progress = f }
                        }
                        return (folder, nil)
                    } catch {
                        if fresh { try? fm.removeItem(at: folder) }     // only a folder we made is safe to remove
                        return (nil, error.localizedDescription)
                    }
                }.value
                if let folder = outcome.folder {
                    library.discardArchive(item)
                    saved.append(folder.lastPathComponent)
                } else {
                    failures[item.id] = outcome.error ?? "Couldn’t unpack it."
                }
            }
            currentID = nil; running = false; bg.end()
            if !saved.isEmpty {
                library.setLastArchiveDestination(dest)
                library.contentDidChange(under: dest)
                let what = saved.count == 1 ? "“\(saved[0])”" : "\(saved.count) folders"
                results.append("Saved \(what) to “\(displayPath(dest))”.")
            }
            if !failures.isEmpty {
                results.append("\(failures.count) couldn’t be unpacked — they stay listed so you can try again.")
            }
        }
    }
}
