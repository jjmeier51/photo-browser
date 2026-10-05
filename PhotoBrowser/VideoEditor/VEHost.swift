import SwiftUI

/// Host adaptation (§2, ARC-1 VideoEditorModule): the browser's root folder is the drive, browser
/// items are file URLs, navigation is the shared `Library.path`. The editor itself never reads
/// `Library` state beyond the root URL.
enum VideoEditorModule {
    /// The drive store for the browser's current root, or nil before a folder is chosen.
    @MainActor static func store(for library: Library) -> VEDriveStore? {
        library.rootURL.map { VEDriveStore(driveRoot: $0) }
    }

    /// EXP-10 "Show in browser": push the Exports folder onto the browser's navigation path.
    @MainActor static func showInBrowser(_ folder: URL, library: Library) {
        guard let store = store(for: library) else { return }
        library.goHome()
        var chain: [URL] = [store.editorRoot]
        if folder.standardizedFileURL.path != store.editorRoot.path { chain.append(folder) }
        library.path = chain
        library.contentDidChange(under: folder)
    }

    /// Items the browser can hand to the editor (videos, photos, GIFs; audio is accepted too).
    static func isEditable(_ entry: Entry) -> Bool { entry.kind == .video || entry.kind == .image || entry.kind == .audio }
}

/// How the editor was opened from the browser (§2 entry points).
enum VEEditorLaunch: Identifiable {
    case open(URL)                          // existing `.vep` package
    case new(items: [URL])                  // "New video project" / "Edit in video editor"
    case addTo(items: [URL])                // "Add to project…" (choose a project first)

    var id: String {
        switch self {
        case .open(let u): return "open:" + u.path
        case .new(let items): return "new:" + items.map(\.path).joined(separator: "|")
        case .addTo(let items): return "add:" + items.map(\.path).joined(separator: "|")
        }
    }
}

/// Resolves a launch into an open `VEEditorSession`, then shows the editor. Handles the
/// "choose a project" step for Add to project…, the corrupt-document recovery offer (PRJ-3) and
/// drive-level errors before the editor exists.
struct VEEditorHostView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let launch: VEEditorLaunch

    @State private var session: VEEditorSession?
    @State private var error: VEError?
    @State private var corruptPackage: URL?
    @State private var choosing = false
    @State private var pendingItems: [URL] = []
    @State private var navigateTo: URL?

    var body: some View {
        Group {
            if let session {
                VEEditorView(session: session, onClose: { dismiss() }, onShowInBrowser: { folder in navigateTo = folder; dismiss() })
            } else if choosing {
                VEProjectChooser(items: pendingItems) { pkg in
                    choosing = false
                    Task { await open(pkg, thenAdd: pendingItems) }
                } onCancel: { dismiss() }
            } else {
                ZStack {
                    Color.black.ignoresSafeArea()
                    if let error {
                        VStack(spacing: 12) {
                            Text(error.title).font(.title3.bold())
                            Text(error.message).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            if let pkg = corruptPackage {
                                Button("Rebuild from media") { Task { await rebuild(pkg) } }.buttonStyle(.borderedProminent)
                            }
                            Button("Close") { dismiss() }
                        }
                        .padding(32)
                    } else {
                        ProgressView("Opening…")
                    }
                }
                .preferredColorScheme(.dark)
            }
        }
        .task { await resolve() }
        .onDisappear {
            if let folder = navigateTo { VideoEditorModule.showInBrowser(folder, library: library) }
        }
    }

    private func resolve() async {
        guard let store = VideoEditorModule.store(for: library) else { error = .driveUnavailable; return }
        do { try await Task.detached { try store.ensureLayout() }.value } catch {
            self.error = store.isReadOnly ? .readOnlyVolume : .driveUnavailable
            return
        }
        switch launch {
        case .open(let pkg):
            await open(pkg, thenAdd: [])
        case .new(let items):
            await create(items: items, store: store)
        case .addTo(let items):
            pendingItems = items
            choosing = true
        }
    }

    private func create(items: [URL], store: VEDriveStore) async {
        let settings = store.loadSettings()
        var ps = VEProjectSettings()
        ps.defaultPhotoDuration = settings.defaultPhotoDuration
        ps.proxyPlayback = settings.proxyPlayback
        ps.canvas.ratio = .original     // re-fitted from the first clip once media lands (CAN-1)
        do {
            let doc = try await VEDocument.create(name: VENames.defaultProjectName(), settings: ps, store: store)
            let s = VEEditorSession(document: doc, store: store, settings: settings)
            session = s
            if !items.isEmpty { s.importURLs(items, insertAtPlayhead: false) }
        } catch let e as VEError {
            error = e
        } catch {
            self.error = store.isReachable() ? .exportFailed("The project couldn't be created on the drive.") : .driveUnavailable
        }
    }

    private func open(_ pkg: URL, thenAdd items: [URL]) async {
        guard let store = VideoEditorModule.store(for: library) else { error = .driveUnavailable; return }
        do {
            let doc = try await VEDocument.open(packageURL: pkg, store: store)
            let s = VEEditorSession(document: doc, store: store, settings: store.loadSettings())
            session = s
            if !items.isEmpty { s.importURLs(items, insertAtPlayhead: false) }
        } catch let e as VEError {
            error = e
            if case .documentCorrupt = e { corruptPackage = pkg }
        } catch {
            self.error = store.isReachable() ? .documentCorrupt(recovered: false) : .driveUnavailable
            corruptPackage = pkg
        }
    }

    private func rebuild(_ pkg: URL) async {
        guard let store = VideoEditorModule.store(for: library) else { return }
        error = nil
        do {
            let doc = try await VEDocument.rebuild(packageURL: pkg, store: store)
            session = VEEditorSession(document: doc, store: store, settings: store.loadSettings())
        } catch {
            self.error = .exportFailed("The project couldn't be rebuilt from its media.")
        }
    }
}

/// "Add to project…": pick the project to append the selected items to.
struct VEProjectChooser: View {
    @Environment(Library.self) private var library
    let items: [URL]
    var onChoose: (URL) -> Void
    var onCancel: () -> Void
    @State private var projects: [VEProjectSummary] = []
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            List {
                if loaded && projects.isEmpty {
                    Text("No projects yet. Use “New Video Project” instead.").foregroundStyle(.secondary)
                }
                ForEach(projects) { p in
                    Button { onChoose(p.packageURL) } label: {
                        VEProjectRow(summary: p, sizes: nil)
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("Add \(items.count) item\(items.count == 1 ? "" : "s") to…")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { onCancel() } } }
            .task {
                guard let store = VideoEditorModule.store(for: library) else { loaded = true; return }
                projects = await Task.detached { VEProjectCatalog.list(store: store).sorted { $0.modifiedAt > $1.modifiedAt } }.value
                loaded = true
            }
        }
        .preferredColorScheme(.dark)
    }
}
