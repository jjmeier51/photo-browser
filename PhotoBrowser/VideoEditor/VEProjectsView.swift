import SwiftUI

/// PRJ-6 Projects screen: every `.vep` under `VideoEditor/Projects/` with cover, name, duration,
/// ratio, last edited and last saved; open, rename, duplicate, delete, clear caches; sort and
/// search. Sizes (media / caches / exports) load lazily per row.
struct VEProjectsView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss

    enum Sort: String, CaseIterable { case edited = "Last edited", name = "Name", duration = "Duration" }

    @State private var projects: [VEProjectSummary] = []
    @State private var sizes: [String: VEProjectSizes] = [:]
    @State private var loaded = false
    @State private var sort: Sort = .edited
    @State private var search = ""
    @State private var launch: VEEditorLaunch?
    @State private var renameTarget: VEProjectSummary?
    @State private var renameDraft = ""
    @State private var deleteTarget: VEProjectSummary?
    @State private var confirmClearAll = false
    @State private var message: String?

    private var store: VEDriveStore? { VideoEditorModule.store(for: library) }

    private var visible: [VEProjectSummary] {
        var list = projects
        if !search.isEmpty { list = list.filter { $0.name.localizedCaseInsensitiveContains(search) } }
        switch sort {
        case .edited: list.sort { $0.modifiedAt > $1.modifiedAt }
        case .name: list.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .duration: list.sort { $0.duration > $1.duration }
        }
        return list
    }

    var body: some View {
        NavigationStack {
            List {
                if loaded && projects.isEmpty {
                    ContentUnavailableView("No video projects", systemImage: "film.stack",
                                           description: Text("Select photos or videos in a folder and choose “New Video Project”, or tap + to start empty."))
                }
                ForEach(visible) { p in
                    Button { launch = .open(p.packageURL) } label: {
                        VEProjectRow(summary: p, sizes: sizes[p.id])
                    }
                    .buttonStyle(.plain)
                    .task(id: p.id) { await loadSizes(p) }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { deleteTarget = p } label: { Label("Delete", systemImage: "trash") }
                        Button { renameTarget = p; renameDraft = p.name } label: { Label("Rename", systemImage: "pencil") }.tint(.blue)
                    }
                    .contextMenu {
                        Button { launch = .open(p.packageURL) } label: { Label("Open", systemImage: "play.rectangle") }
                        Button { renameTarget = p; renameDraft = p.name } label: { Label("Rename", systemImage: "pencil") }
                        Button { duplicate(p) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                        Button { clearCaches(p) } label: { Label("Clear Caches", systemImage: "trash.slash") }
                        Button(role: .destructive) { deleteTarget = p } label: { Label("Delete", systemImage: "trash") }
                    }
                }
            }
            .searchable(text: $search, prompt: "Search projects")
            .navigationTitle("Video Projects")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    HStack {
                        Menu {
                            Picker("Sort", selection: $sort) { ForEach(Sort.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                            Divider()
                            Button { confirmClearAll = true } label: { Label("Clear All Caches", systemImage: "trash.slash") }
                            if let store {
                                Button { launch = nil; VideoEditorModule.showInBrowser(VEDriveLayout.exports(store.editorRoot), library: library); dismiss() } label: {
                                    Label("Show Exports Folder", systemImage: "folder")
                                }
                            }
                        } label: { Image(systemName: "ellipsis.circle") }
                        Button { launch = .new(items: []) } label: { Image(systemName: "plus") }
                    }
                }
            }
            .task { await reload() }
            .refreshable { await reload() }
            .fullScreenCover(item: $launch, onDismiss: { Task { await reload() } }) { l in
                VEEditorHostView(launch: l)
            }
            .alert("Rename Project", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
                TextField("Name", text: $renameDraft)
                Button("Rename") { if let t = renameTarget { rename(t, to: renameDraft) } }
                Button("Cancel", role: .cancel) { renameTarget = nil }
            }
            .confirmationDialog("Delete “\(deleteTarget?.name ?? "")”?", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }), titleVisibility: .visible) {
                Button("Delete Project", role: .destructive) { if let t = deleteTarget { delete(t) } }
                Button("Cancel", role: .cancel) { deleteTarget = nil }
            } message: {
                Text("The project and its imported copies are removed permanently. Exported videos and files elsewhere on the drive are not affected.")
            }
            .confirmationDialog("Clear caches for every project?", isPresented: $confirmClearAll, titleVisibility: .visible) {
                Button("Clear All Caches", role: .destructive) { clearAll() }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Thumbnails, waveforms and proxies rebuild on their own the next time a project opens.") }
            .alert("Video Projects", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK") { message = nil }
            } message: { Text(message ?? "") }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: Operations

    private func reload() async {
        guard let store else { loaded = true; return }
        let list = await Task.detached(priority: .userInitiated) { () -> [VEProjectSummary] in
            try? store.ensureLayout()
            return VEProjectCatalog.list(store: store)
        }.value
        projects = list
        sizes = sizes.filter { k, _ in list.contains { $0.id == k } }
        loaded = true
    }

    private func loadSizes(_ p: VEProjectSummary) async {
        guard sizes[p.id] == nil, let store else { return }
        let s = await Task.detached(priority: .utility) { VEProjectCatalog.sizes(of: p.packageURL, projectName: p.name, store: store) }.value
        sizes[p.id] = s
    }

    private func rename(_ p: VEProjectSummary, to name: String) {
        renameTarget = nil
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, let store else { return }
        Task {
            do {
                _ = try await Task.detached { try VEProjectCatalog.rename(p.packageURL, to: n, store: store) }.value
            } catch { message = "The project couldn't be renamed." }
            await reload()
        }
    }

    private func duplicate(_ p: VEProjectSummary) {
        guard let store else { return }
        Task {
            do { _ = try await Task.detached { try VEProjectCatalog.duplicate(p.packageURL, store: store) }.value }
            catch { message = "The project couldn't be duplicated." }
            await reload()
        }
    }

    private func delete(_ p: VEProjectSummary) {
        deleteTarget = nil
        guard let store else { return }
        Task {
            do { try await Task.detached { try VEProjectCatalog.delete(p.packageURL, store: store) }.value }
            catch { message = "The project couldn't be deleted." }
            await reload()
        }
    }

    private func clearCaches(_ p: VEProjectSummary) {
        guard let store else { return }
        Task {
            await Task.detached { VEProjectCatalog.clearCaches(p.packageURL, store: store) }.value
            sizes[p.id] = nil
            await reload()
        }
    }

    private func clearAll() {
        guard let store else { return }
        Task {
            await Task.detached { VEProjectCatalog.clearAllCaches(store: store) }.value
            sizes.removeAll()
            await reload()
        }
    }
}

struct VEProjectRow: View {
    let summary: VEProjectSummary
    let sizes: VEProjectSizes?

    var body: some View {
        HStack(spacing: 12) {
            VECoverThumb(url: summary.coverURL, aspect: summary.canvas?.aspect ?? (16.0 / 9.0))
                .frame(width: 84, height: 64)
            VStack(alignment: .leading, spacing: 3) {
                Text(summary.name).font(.headline).lineLimit(1)
                HStack(spacing: 6) {
                    Text(VETimeUtil.format(summary.duration, fps: 30))
                    Text("·"); Text(summary.ratio.rawValue)
                    Text("·"); Text("\(summary.clipCount) clip\(summary.clipCount == 1 ? "" : "s")")
                }
                .font(.caption).foregroundStyle(.secondary)
                Text("Edited \(summary.modifiedAt.formatted(.relative(presentation: .named)))\(summary.lastSavedAt.map { " · saved \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "")")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                if let s = sizes {
                    Text("Media \(bytes(s.media)) · Caches \(bytes(s.caches)) · Exports \(bytes(s.exports))")
                        .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
                if summary.unreadable {
                    Label("Needs recovery", systemImage: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(.yellow)
                }
            }
            Spacer()
        }
        .contentShape(Rectangle())
    }

    private func bytes(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
}

struct VECoverThumb: View {
    let url: URL
    let aspect: Double
    @State private var image: UIImage?
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.16))
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "film").foregroundStyle(.secondary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: url) {
            let path = url.path
            image = await Task.detached(priority: .utility) { UIImage(contentsOfFile: path).map { VEMediaService.resized($0, maxPixel: 240) } }.value
        }
    }
}
