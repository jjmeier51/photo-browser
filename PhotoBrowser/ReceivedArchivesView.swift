import SwiftUI

/// The **Received** sheet: files that reached the app as files — an AirDrop opened with Photo
/// Browser (a `.pbgallery` from `mac/airdrop_to_iphone.py`, a folder AirDropped from Finder, which
/// arrives as a zip, a PDF, a video, any document), a file opened from Files, or one shared through
/// the extension — and where on the drive they go. Several arrive together (one AirDrop of a star's
/// galleries, a handful of files), so they're listed as a batch with one destination folder.
///
/// An **archive** unpacks into its own folder there, named after the folder that was sent: a
/// Mac-made archive (or a Finder-zipped folder) carries that folder at its top level, which is
/// dropped on the way out so a gallery lands as `<destination>/<Gallery Name>/…` with `gallery.json`
/// beside the photos, not two levels deep. A folder that already exists is **merged** into — re-sending
/// a gallery only adds what's new, the way the Mac downloaders re-run — unless "Keep both" is
/// chosen, which numbers the new one. Any **other file** is placed in the destination as it is; one
/// that's already there (same name and size) is skipped, and a same-named different file gets a
/// number — nothing on the drive is ever overwritten.
///
/// The work runs one item at a time off the main actor under a background-task window; an item
/// leaves staging only once it's on the drive, so a failure keeps it listed for another try (a fresh,
/// half-written folder is removed). "Later" keeps everything staged.
struct ReceivedArchivesView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss

    @State private var destination: URL?
    @State private var showFolderPicker = false
    @State private var merge = true
    @State private var peeks: [String: Archiver.Peek] = [:]
    @State private var running = false
    @State private var currentID: String?
    @State private var position = 0           // 1-based index of the item being handled
    @State private var batchCount = 0
    @State private var progress = 0.0
    @State private var results: [String] = []
    @State private var failures: [String: String] = [:]
    @State private var confirmDiscardAll = false

    private var items: [ArchiveIntake.Received] { library.pendingArchives }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if items.isEmpty {
                        Text(results.isEmpty ? "Nothing waiting." : "All saved.").foregroundStyle(.secondary)
                    }
                    ForEach(items) { item in
                        row(item)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) { library.discardArchive(item) } label: {
                                    Label("Discard", systemImage: "trash")
                                }
                                .disabled(running)
                            }
                    }
                } header: {
                    Text(items.count <= 1 ? "Received" : "Received (\(items.count))")
                } footer: {
                    if !items.isEmpty { Text("Swipe an item left to discard it without saving.") }
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
                    if items.contains(where: \.isArchive) {
                        Picker("If a folder already exists", selection: $merge) {
                            Text("Merge").tag(true)
                            Text("Keep both").tag(false)
                        }
                        .disabled(running)
                    }
                } header: {
                    Text("Save to")
                } footer: {
                    Text(saveFooter)
                }

                if running {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(workingLabel).font(.callout)
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
                        Text("Open your drive folder in the app first, then come back here (Settings ▸ Received Files).")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                }

                if items.count > 1 {
                    Section {
                        Button("Discard All…", role: .destructive) { confirmDiscardAll = true }.disabled(running)
                    }
                }
            }
            .navigationTitle("Received")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(items.isEmpty ? "Done" : "Later") { dismiss() }.disabled(running)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { start() }
                        .disabled(running || destination == nil || items.isEmpty)
                }
            }
            .confirmationDialog("Discard everything received?", isPresented: $confirmDiscardAll, titleVisibility: .visible) {
                Button("Discard \(items.count) Items", role: .destructive) {
                    for item in items { library.discardArchive(item) }
                }
            } message: {
                Text("None of it has been put on the drive — you'd have to AirDrop it again.")
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
        .task(id: items.map(\.id)) { await peekAll() }
    }

    // MARK: - Rows

    private var saveFooter: String {
        let archives = items.contains(where: \.isArchive), files = items.contains { !$0.isArchive }
        var parts: [String] = []
        if archives {
            parts.append("Each archive becomes its own folder here, named after the folder that was sent. Merge adds a re-sent gallery's new photos to the folder it already has; Keep both makes a numbered copy.")
        }
        if files || !archives {
            parts.append("Files are placed here as they are; one that's already here (same name and size) is skipped, and nothing is overwritten.")
        }
        return parts.joined(separator: " ")
    }

    private func row(_ item: ArchiveIntake.Received) -> some View {
        let failed = failures[item.id] != nil
        return HStack(spacing: 12) {
            Image(systemName: currentID == item.id ? "arrow.down.circle" : (failed ? "exclamationmark.triangle" : icon(for: item)))
                .foregroundStyle(failed ? Color.orange : Color.accentColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName(for: item)).lineLimit(2)
                Text(subtitle(for: item)).font(.caption).foregroundStyle(.secondary)
                if let why = failures[item.id] {
                    Text(why).font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }

    private func icon(for item: ArchiveIntake.Received) -> String {
        if item.isArchive { return "archivebox" }
        switch classify(url: item.url, isDirectory: false) {
        case .image: return "photo"
        case .video: return "film"
        case .audio: return "waveform"
        case .pdf:   return "doc.richtext"
        default:     return "doc"
        }
    }

    /// What the item becomes: an archive's single top-level folder (else its own name), a file's name.
    private func displayName(for item: ArchiveIntake.Received) -> String {
        item.isArchive ? (peeks[item.id]?.topFolder ?? item.title) : item.title
    }

    private func subtitle(for item: ArchiveIntake.Received) -> String {
        guard item.isArchive, let p = peeks[item.id] else { return item.size.sizeString }
        var parts: [String] = []
        if p.photos > 0 { parts.append("\(p.photos) photo\(p.photos == 1 ? "" : "s")") }
        if p.videos > 0 { parts.append("\(p.videos) video\(p.videos == 1 ? "" : "s")") }
        if parts.isEmpty { parts.append("\(p.files) file\(p.files == 1 ? "" : "s")") }
        parts.append(p.bytes.sizeString)
        return parts.joined(separator: " · ")
    }

    private var workingLabel: String {
        guard let item = items.first(where: { $0.id == currentID }) else { return "Working…" }
        let verb = item.isArchive ? "Unpacking" : "Saving"
        return "\(verb) “\(displayName(for: item))”… (\(position) of \(batchCount))"
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
        for item in items where item.isArchive && peeks[item.id] == nil {
            let url = item.url
            if let p = await Task.detached(priority: .utility) { try? Archiver.peek(url) }.value {
                peeks[item.id] = p
            }
        }
    }

    // MARK: - Saving

    /// What one item came to: the folder or file it became on the drive, or why it couldn't, or that
    /// an identical file was already there.
    private enum Outcome: Sendable {
        case folder(URL), file(URL), alreadyThere, failed(String)
    }

    private func start() {
        guard let dest = destination else { return }
        let batch = items
        let mergeExisting = merge
        running = true; failures = [:]; batchCount = batch.count; position = 0
        let bg = BackgroundTaskHolder(); bg.begin(name: "Save Received Files")
        Task {
            var folders = 0, files = 0, already = 0
            for item in batch {
                position += 1; currentID = item.id; progress = 0
                let outcome: Outcome = await Task.detached(priority: .userInitiated) { () -> Outcome in
                    if item.isArchive { return await unpack(item, into: dest, merge: mergeExisting) }
                    return place(item, into: dest)
                }.value
                switch outcome {
                case .folder(let folder):
                    folders += 1
                    await library.applyArchiveTags(in: folder)   // the tags the files had on the Mac
                    library.discardArchive(item)
                case .file:         files += 1; library.discardArchive(item)
                case .alreadyThere: already += 1; library.discardArchive(item)
                case .failed(let why): failures[item.id] = why
                }
            }
            currentID = nil; running = false; bg.end()
            if folders + files > 0 {
                library.setLastArchiveDestination(dest)
                library.contentDidChange(under: dest)
                var what: [String] = []
                if folders > 0 { what.append("\(folders) folder\(folders == 1 ? "" : "s")") }
                if files > 0 { what.append("\(files) file\(files == 1 ? "" : "s")") }
                results.append("Saved \(what.joined(separator: " and ")) to “\(displayPath(dest))”.")
            }
            if already > 0 { results.append("\(already) \(already == 1 ? "was" : "were") already there — skipped.") }
            if !failures.isEmpty {
                results.append("\(failures.count) couldn’t be saved — they stay listed so you can try again.")
            }
        }
    }

    /// An archive → `<dest>/<its top folder or name>/…`, merged into an existing folder or numbered.
    private nonisolated func unpack(_ item: ArchiveIntake.Received, into dest: URL, merge: Bool) async -> Outcome {
        let fm = FileManager.default
        let name = (try? Archiver.peek(item.url))?.topFolder ?? item.title
        var folder = dest.appendingPathComponent(name, isDirectory: true)
        if !merge {
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
            return .folder(folder)
        } catch {
            if fresh { try? fm.removeItem(at: folder) }     // only a folder we made is safe to remove
            return .failed(error.localizedDescription)
        }
    }

    /// Any other file → `<dest>/<its name>`; an identical file already there is a skip, a different one
    /// of the same name makes this a numbered copy. The staged copy is moved (copy + delete across
    /// volumes, through `DriveWriter`), so a failed copy leaves it staged for another try.
    private nonisolated func place(_ item: ArchiveIntake.Received, into dest: URL) -> Outcome {
        let fm = FileManager.default
        let base = item.url.deletingPathExtension().lastPathComponent, ext = item.url.pathExtension
        var target = dest.appendingPathComponent(item.url.lastPathComponent)
        if fm.fileExists(atPath: target.path) {
            let there = ((try? fm.attributesOfItem(atPath: target.path))?[.size] as? NSNumber)?.int64Value ?? -1
            if there == item.size { return .alreadyThere }
            var n = 2
            while fm.fileExists(atPath: target.path) {
                target = dest.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"); n += 1
            }
        }
        do {
            try DriveWriter.moveItem(at: item.url, to: target)
            return .file(target)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
