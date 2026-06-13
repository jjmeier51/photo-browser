import SwiftUI
import UniformTypeIdentifiers
import PhotosUI

/// Carries the viewer's data so it's presented via `.fullScreenCover(item:)`,
/// which captures the items/index reliably (isPresented can capture stale state).
struct ViewerPresentation: Identifiable {
    let id = UUID()
    let items: [Entry]
    let startIndex: Int
    var slideshow: Bool = false
}

/// What the single folder picker is being used for (one `.fileImporter` total —
/// multiple `.fileImporter` modifiers on one view conflict in SwiftUI).
enum ImportPurpose { case open, transfer, relink }

/// Browses one directory: subfolders + files, with sort, search, a full-screen
/// viewer for photos/videos, and a Select mode for save/delete.
struct FolderView: View {
    @Environment(Library.self) private var library
    let url: URL
    let isRoot: Bool

    @State private var entries: [Entry] = []
    @State private var query = ""

    @State private var selecting = false
    @State private var selection = Set<URL>()

    @State private var viewerPresentation: ViewerPresentation?

    @State private var previewItem: PreviewItem?
    @State private var confirmDelete = false
    @State private var showExporter = false
    @State private var exportURLs: [URL] = []
    @State private var resultMessage: String?
    @State private var showFolderPicker = false
    @State private var folderPurpose: ImportPurpose = .open
    @State private var loaded = false
    @State private var yearFilter: Int?
    @State private var typeFilter: TypeFilter = .all
    @State private var showFavoritesOnly = false
    @State private var favoriteEntries: [Entry] = []
    @State private var captureDates: [URL: Date] = [:]
    @State private var fileCaptions: [URL: String] = [:]
    @State private var showCaptionEditor = false
    @State private var captionDraft = ""
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var renameTarget: Entry?
    @State private var renameDraft = ""
    @State private var showMovePicker = false
    @State private var showCopyPicker = false
    @State private var exporting = false
    @State private var exportProgress: Double = 0
    @State private var searchResults: [Entry] = []
    @State private var searching = false
    @State private var exportTarget: Entry?
    @State private var exportName = ""
    @State private var showExportPrompt = false
    @State private var showAIOnly = false
    @State private var aiEntries: [Entry] = []
    @State private var labelKind: LabelKind = .all
    @State private var tsLabelFilter: Set<String> = []
    @State private var tsLabelEntries: [Entry] = []
    @State private var showDuplicates = false
    @State private var videoRes: VideoRes = .all
    @State private var imageRes: ImageRes = .all
    @State private var hdrOnly = false
    @State private var fileSpecs: [URL: MediaSpec] = [:]
    @State private var infoEntry: Entry?
    @State private var folderInfoItem: PreviewItem?
    @State private var birthdayFolderItem: PreviewItem?
    @State private var ageFilter: Int?
    @State private var agedList: [(entry: Entry, age: Int)] = []
    @State private var loadingAges = false
    @State private var showLibrary = false
    @State private var showPhotosPicker = false
    @State private var showPhotosLibrary = false
    @State private var photosLibraryMoves = false
    @State private var showMegaImport = false
    @State private var importing = false
    @State private var editEntry: Entry?
    @State private var editProcessing = false
    @State private var editProgress: Double = 0
    @State private var metadataTargets: [URL] = []
    @State private var showMetadataEditor = false
    @State private var transferItem: PreviewItem?
    @State private var cellFrames: [URL: CGRect] = [:]
    @State private var dragSelectAdding = true
    @State private var lastDragURL: URL?
    @State private var lastDragPoint: CGPoint?
    @State private var gridSize: CGSize = .zero
    @State private var autoScrollDir = 0
    @State private var autoScrollTask: Task<Void, Never>?

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: CGFloat(library.thumbSize)), spacing: 4)]
    }

    private var advancedActive: Bool { videoRes != .all || imageRes != .all || hdrOnly }
    private var labelMode: Bool { showFavoritesOnly || showAIOnly }
    /// The bespoke labeling/filtering only appears inside the "Taylor Swift"
    /// folder (or any folder nested under it).
    private var inTaylorSwift: Bool { url.pathComponents.contains("Taylor Swift") }
    private var tsLabelMode: Bool { !tsLabelFilter.isEmpty }
    private var availableAges: [Int] { Array(Set(agedList.map { $0.age })).sorted() }

    /// Real capture year (EXIF/creation) when known, else the file's modified year.
    private func year(of entry: Entry) -> Int {
        Calendar.current.component(.year, from: captureDates[entry.url] ?? entry.modified)
    }

    /// App caption override wins; otherwise the caption pulled from the file.
    private func effectiveCaption(for entry: Entry) -> String {
        if let override = library.captions[entry.url.path] { return override }
        return fileCaptions[entry.url] ?? ""
    }

    private var filtered: [Entry] {
        let list = filteredRaw
        return library.sort.isAge ? sortByAge(list) : list
    }

    /// Sorts entries by computed age (folders first; items without an age last).
    /// Ages are precomputed once into a dict so the sort comparator stays O(1) —
    /// computing per comparison (n·log n × an ancestor walk) froze the app.
    private func sortByAge(_ list: [Entry]) -> [Entry] {
        var ages: [URL: Int] = [:]
        for item in agedList { ages[item.entry.url] = item.age }
        // Fill in any displayed media not already in agedList — once, not per compare.
        for e in list where !e.isFolder && ages[e.url] == nil {
            if let d = captureDates[e.url], let a = library.age(forFile: e.url, captureDate: d) {
                ages[e.url] = a
            }
        }
        let ascending = (library.sort == .ageAsc)
        return list.sorted { a, b in
            if a.isFolder != b.isFolder { return a.isFolder }
            let aa = ages[a.url], ba = ages[b.url]
            if let x = aa, let y = ba {
                return x != y ? (ascending ? x < y : x > y)
                              : a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            if aa == nil && ba == nil {
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            return aa != nil    // items with an age come before those without
        }
    }

    private var filteredRaw: [Entry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()

        // Taylor Swift label mode: items carrying every selected label (AND),
        // gathered recursively under this folder.
        if tsLabelMode {
            let base = applyType(tsLabelEntries)
            return q.isEmpty ? base : base.filter { matches($0, q) }
        }

        // Favorites / To AI mode: labeled items + folder/photo/video sub-filter.
        if labelMode {
            let base = applyLabelKind(showAIOnly ? aiEntries : favoriteEntries)
            return q.isEmpty ? base : base.filter { matches($0, q) }
        }

        // Age mode: recursive aged media (folder + subfolders) of the chosen age.
        if let ageFilter {
            let base = applyType(agedList.filter { $0.age == ageFilter }.map { $0.entry })
            return q.isEmpty ? base : base.filter { matches($0, q) }
        }

        // Searching: recursive results (current folder + all subfolders).
        if !q.isEmpty {
            var results = applyType(searchResults)
            // Age search: a numeric query also matches media of that age.
            if let target = Int(q) {
                let existing = Set(results.map { $0.url })
                let aged = applyType(agedList.filter { $0.age == target }.map { $0.entry })
                results += aged.filter { !existing.contains($0.url) }
            }
            return results
        }

        var list = entries
        if let yearFilter {
            list = list.filter { $0.isFolder || year(of: $0) == yearFilter }
        }
        list = applyType(list)
        if advancedActive { list = list.filter { passesAdvanced($0) } }
        return list
    }

    /// Content-type filter (hides subfolders when a type is chosen).
    private func applyType(_ list: [Entry]) -> [Entry] {
        switch typeFilter {
        case .all:        return list
        case .photo:      return list.filter { $0.kind == .image && !$0.isScreenshot }
        case .video:      return list.filter { $0.kind == .video }
        case .screenshot: return list.filter { $0.isScreenshot }
        }
    }

    /// Folder / photo / video sub-filter used in Favorites / To AI views.
    private func applyLabelKind(_ list: [Entry]) -> [Entry] {
        switch labelKind {
        case .all:     return list
        case .folders: return list.filter { $0.isFolder }
        case .photos:  return list.filter { $0.kind == .image }
        case .videos:  return list.filter { $0.kind == .video }
        }
    }

    /// Resolution / HDR filter (folders & not-yet-scanned media are hidden).
    /// HDR is combined with the resolution filters (AND); a video-resolution and
    /// an image-resolution selection combine as OR across the two media types.
    private func passesAdvanced(_ entry: Entry) -> Bool {
        guard let spec = fileSpecs[entry.url] else { return false }
        if hdrOnly, !spec.isHDR { return false }
        let resActive = videoRes != .all || imageRes != .all
        guard resActive else { return true }
        switch entry.kind {
        case .video: return videoRes != .all ? spec.videoRes == videoRes : imageRes == .all
        case .image: return imageRes != .all ? spec.imageRes == imageRes : videoRes == .all
        default:     return false
        }
    }

    /// Search matches filename or caption.
    private func matches(_ entry: Entry, _ q: String) -> Bool {
        entry.name.lowercased().contains(q) || effectiveCaption(for: entry).lowercased().contains(q)
    }

    private var mediaItems: [Entry] { filtered.filter { $0.isViewable } }

    private var availableYears: [Int] {
        Array(Set(entries.filter { !$0.isFolder }.map { year(of: $0) })).sorted(by: >)
    }

    private var grid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, spacing: 4) {
                    ForEach(filtered) { entry in
                        cell(for: entry)
                    }
                }
                .padding(4)
            }
            .coordinateSpace(name: "grid")
            .background(
                GeometryReader { g in
                    Color.clear
                        .onAppear { gridSize = g.size }
                        .onChange(of: g.size) { _, newValue in gridSize = newValue }
                }
            )
            .onPreferenceChange(CellFramesKey.self) { cellFrames = $0 }
            // Pinch out → bigger thumbnails (+30%), pinch in → smaller (−30%).
            .simultaneousGesture(
                MagnificationGesture(minimumScaleDelta: 0.05)
                    .onEnded { scale in
                        if scale > 1.08 { library.setThumbSize(library.thumbSize * 1.3) }
                        else if scale < 0.93 { library.setThumbSize(library.thumbSize * 0.7) }
                    }
            )
            // Smoothly animate the thumbnail-size change.
            .animation(.easeInOut(duration: 0.22), value: library.thumbSize)
            // In Select mode: tap a cell to toggle it (handled by each cell's own
            // tap gesture), and press-and-hold then drag to multi-select. This is a
            // plain `.gesture` (not high-priority) so it sits *below* the cells' tap
            // gesture — a high-priority long-press here would swallow the taps and
            // make tap-to-select do nothing.
            .gesture(
                LongPressGesture(minimumDuration: 0.22)
                    .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named("grid")))
                    .onChanged { value in
                        if case .second(true, let drag?) = value {
                            lastDragPoint = drag.location
                            dragSelect(at: drag.location)
                            updateAutoScroll(for: drag.location)
                        }
                    }
                    .onEnded { _ in endDragSelect() },
                including: selecting ? .all : .subviews
            )
            .onChange(of: autoScrollDir) { runAutoScroll(proxy) }
        }
    }

    private func cell(for entry: Entry) -> some View {
        EntryCell(entry: entry, selecting: selecting, selected: selection.contains(entry.url),
                  favorited: library.isFavorite(entry.url), aiLabeled: library.isAI(entry.url),
                  coverURL: entry.isFolder ? library.coverURL(for: entry.url) : nil)
            .background {
                if selecting {
                    GeometryReader { geo in
                        Color.clear.preference(key: CellFramesKey.self,
                                               value: [entry.url: geo.frame(in: .named("grid"))])
                    }
                }
            }
            .onTapGesture { tap(entry) }
            // No long-press menu while selecting — press-and-hold there starts a drag-select.
            .contextMenu { if !selecting { contextMenu(for: entry) } }
    }

    /// Selects (or deselects) cells as a drag passes over them in Select mode.
    private func dragSelect(at point: CGPoint) {
        guard let url = cellFrames.first(where: { $0.value.contains(point) })?.key else { return }
        if lastDragURL == nil { dragSelectAdding = !selection.contains(url) }
        guard url != lastDragURL else { return }
        lastDragURL = url
        if dragSelectAdding { selection.insert(url) } else { selection.remove(url) }
    }

    /// Sets the auto-scroll direction when the drag nears the top/bottom edge.
    private func updateAutoScroll(for point: CGPoint) {
        guard gridSize.height > 0 else { autoScrollDir = 0; return }
        let edge: CGFloat = 70
        if point.y < edge { autoScrollDir = -1 }
        else if point.y > gridSize.height - edge { autoScrollDir = 1 }
        else { autoScrollDir = 0 }
    }

    private func endDragSelect() {
        lastDragURL = nil
        lastDragPoint = nil
        autoScrollDir = 0
    }

    /// Starts/stops the repeating edge auto-scroll, re-selecting at the held point.
    private func runAutoScroll(_ proxy: ScrollViewProxy) {
        autoScrollTask?.cancel()
        let dir = autoScrollDir
        guard dir != 0 else { return }
        autoScrollTask = Task { @MainActor in
            while !Task.isCancelled {
                autoScrollStep(proxy, direction: dir)
                try? await Task.sleep(nanoseconds: 180_000_000)
                if Task.isCancelled { break }
                if let p = lastDragPoint { dragSelect(at: p) }
            }
        }
    }

    private func autoScrollStep(_ proxy: ScrollViewProxy, direction: Int) {
        let indices = cellFrames.keys.compactMap { url in filtered.firstIndex(where: { $0.url == url }) }
        guard let edge = (direction > 0 ? indices.max() : indices.min()) else { return }
        let target = edge + direction * 4
        guard target >= 0, target < filtered.count else { return }
        withAnimation(.linear(duration: 0.18)) {
            proxy.scrollTo(filtered[target].id, anchor: direction > 0 ? .bottom : .top)
        }
    }

    @ViewBuilder
    private func contextMenu(for entry: Entry) -> some View {
        if entry.isFolder {
            Button { folderInfoItem = PreviewItem(url: entry.url) } label: {
                Label("Get Info", systemImage: "info.circle")
            }
            Button { birthdayFolderItem = PreviewItem(url: entry.url) } label: {
                Label(library.birthday(for: entry.url) != nil ? "Edit Birthday" : "Add Birthday",
                      systemImage: "birthday.cake")
            }
            Button { renameTarget = entry; renameDraft = entry.name } label: {
                Label("Rename", systemImage: "pencil")
            }
        } else {
            if entry.isViewable {
                Button { infoEntry = entry } label: {
                    Label("Get Info", systemImage: "info.circle")
                }
                Button { editEntry = entry } label: {
                    Label("Crop & Rotate", systemImage: "crop.rotate")
                }
                Button { metadataTargets = [entry.url]; showMetadataEditor = true } label: {
                    Label("Edit Metadata", systemImage: "calendar.badge.clock")
                }
                Button { library.toggleFavorite(entry.url) } label: {
                    Label(library.isFavorite(entry.url) ? "Unfavorite" : "Favorite",
                          systemImage: library.isFavorite(entry.url) ? "heart.slash" : "heart")
                }
                Button { library.toggleAI(entry.url) } label: {
                    Label(library.isAI(entry.url) ? "Remove To AI" : "To AI", systemImage: "sparkles")
                }
                Button { saveSingleToPhotos(entry) } label: {
                    Label("Save to Photos", systemImage: "photo.on.rectangle")
                }
                Button { duplicateEntries([entry]) } label: {
                    Label("Duplicate", systemImage: "plus.square.on.square")
                }
                Button { startSingleMove(entry) } label: {
                    Label("Move", systemImage: "folder")
                }
                Button { startSingleCopy(entry) } label: {
                    Label("Copy to Folder…", systemImage: "doc.on.doc")
                }
            }
            if entry.kind == .video {
                Button {
                    exportTarget = entry
                    exportName = ""
                    showExportPrompt = true
                } label: {
                    Label("Export all frames", systemImage: "square.stack.3d.down.right")
                }
            }
            if entry.isViewable {
                Button(role: .destructive) { startSingleDelete(entry) } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    // Single-item actions from the long-press menu, reusing the selection plumbing.
    private func saveSingleToPhotos(_ entry: Entry) {
        Task {
            let r = await FileActions.saveToPhotos([entry])
            resultMessage = r.note ?? (r.failed == 0 ? "Saved to Photos." : "Couldn’t save to Photos.")
        }
    }

    private func startSingleMove(_ entry: Entry) {
        selection = [entry.url]
        showMovePicker = true
    }

    private func startSingleCopy(_ entry: Entry) {
        selection = [entry.url]
        showCopyPicker = true
    }

    private func playSlideshow() {
        let media = mediaItems.shuffled()
        guard !media.isEmpty else { return }
        viewerPresentation = ViewerPresentation(items: media, startIndex: 0, slideshow: true)
    }

    private func duplicateEntries(_ entries: [Entry]) {
        let n = FileActions.duplicate(entries)
        if selecting { selecting = false; selection.removeAll() }
        if entries.count > 1 { resultMessage = "Duplicated \(n) item(s)." }
        Task { await reload() }
    }

    private func startSingleDelete(_ entry: Entry) {
        selection = [entry.url]
        confirmDelete = true
    }

    private func runSearch() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { searchResults = []; searching = false; return }
        searching = true
        try? await Task.sleep(nanoseconds: 300_000_000)   // debounce
        if Task.isCancelled { return }
        if !library.index.isEmpty {
            searchResults = library.searchIndex(under: url, query: q, captions: library.captions, sort: library.sort)
            searching = false
        } else {
            let results = await library.search(in: url, query: q, captions: library.captions, sort: library.sort)
            if !Task.isCancelled { searchResults = results; searching = false }
        }
    }

    var body: some View {
        content
            .fileImporter(isPresented: $showFolderPicker,
                          allowedContentTypes: [.folder],
                          allowsMultipleSelection: false) { result in
                let purpose = folderPurpose
                guard case .success(let urls) = result, let picked = urls.first else { return }
                // Defer so the document picker fully dismisses before we present the
                // confirmation / start work (otherwise it gets swallowed mid-dismiss).
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                    switch purpose {
                    case .open:     library.chooseFolder(picked)
                    case .transfer: transferItem = PreviewItem(url: picked)
                    case .relink:   performRelink(oldRoot: picked)
                    }
                }
            }
            .sheet(item: $previewItem) { item in
                QuickLookPreview(url: item.url).ignoresSafeArea()
            }
            .fullScreenCover(item: $viewerPresentation) { p in
                ViewerView(items: p.items, startIndex: p.startIndex, slideshow: p.slideshow)
            }
            .sheet(isPresented: $showExporter) {
                FilesExporter(urls: exportURLs) { showExporter = false }
            }
            .sheet(isPresented: $showMovePicker) {
                FolderPicker(root: library.rootURL ?? url) { dest in performMove(to: dest) }
            }
            .sheet(isPresented: $showCopyPicker) {
                FolderPicker(root: library.rootURL ?? url, confirmTitle: "Copy Here") { dest in performCopy(to: dest) }
            }
            .confirmationDialog("Delete \(selection.count) item(s)? This permanently removes them from the drive.",
                                isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { performDelete() }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Done", isPresented: Binding(get: { resultMessage != nil },
                                                set: { if !$0 { resultMessage = nil } })) {
                Button("OK") { resultMessage = nil }
            } message: {
                Text(resultMessage ?? "")
            }
            .alert("Caption", isPresented: $showCaptionEditor) {
                TextField("Caption", text: $captionDraft)
                Button("Save") { applyCaption() }
                Button("Cancel", role: .cancel) {}
            }
            .alert("New Folder", isPresented: $showNewFolder) {
                TextField("Name", text: $newFolderName)
                Button("Create") { createFolder() }
                Button("Cancel", role: .cancel) { newFolderName = "" }
            }
            .alert("Export All Frames", isPresented: $showExportPrompt) {
                TextField("Folder name", text: $exportName)
                Button("Export") { if let t = exportTarget { exportFrames(t, name: exportName) } }
                Button("Cancel", role: .cancel) { exportTarget = nil }
            } message: {
                Text("Saves every frame into a new folder beside the video. Leave blank to use the video’s name.")
            }
            .alert("Rename Folder",
                   isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
                TextField("Name", text: $renameDraft)
                Button("Rename") { performRename() }
                Button("Cancel", role: .cancel) { renameTarget = nil }
            }
            .sheet(item: $infoEntry) { e in InfoPanel(entry: e) }
            .sheet(item: $folderInfoItem) { item in FolderInfoView(folder: item.url) }
            .sheet(item: $birthdayFolderItem) { item in
                BirthdayEditorView(folder: item.url, existing: library.birthday(for: item.url))
            }
            .sheet(isPresented: $showMetadataEditor) {
                if !metadataTargets.isEmpty { MetadataEditorView(urls: metadataTargets) }
            }
            .sheet(isPresented: $showLibrary) { LibraryView() }
            .sheet(isPresented: $showPhotosPicker) {
                PhotosImportPicker { results in handlePhotosImport(results) }
                    .ignoresSafeArea()
            }
            .fullScreenCover(item: $editEntry) { e in MediaEditorView(entry: e) }
            .fullScreenCover(isPresented: $showPhotosLibrary) {
                PhotosLibraryView(targetFolder: url, deleteOriginals: photosLibraryMoves)
            }
            .fullScreenCover(isPresented: $showMegaImport) {
                MegaImportView(targetFolder: url) { Task { await reload() } }
            }
            .fullScreenCover(isPresented: $showDuplicates) {
                DuplicatesView(folder: url)
            }
            .overlay(alignment: .bottom) { if selecting { selectionBar } }
            .overlay(alignment: .bottomLeading) {
                if isRoot && !selecting {
                    Button { showLibrary = true } label: {
                        Label("Library", systemImage: "photo.stack")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    .padding(.leading, 16).padding(.bottom, 16)
                }
            }
            .overlay { if exporting { exportingOverlay } }
            .overlay { if editProcessing { editingOverlay } }
            .overlay { if importing { importingOverlay } }
            .overlay { emptyOverlay }
            .fullScreenCover(item: $transferItem) { item in
                DriveTransferView(source: item.url, destination: url)
            }
    }

    /// Opens the folder picker for a given purpose. Deferred a beat so the
    /// toolbar menu finishes dismissing before the picker presents (otherwise the
    /// presentation can be swallowed and nothing happens).
    private func pickFolder(_ purpose: ImportPurpose) {
        folderPurpose = purpose
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { showFolderPicker = true }
    }

    /// Re-keys Favorites/covers/captions from an already-copied drive onto this one.
    private func performRelink(oldRoot: URL) {
        let accessed = oldRoot.startAccessingSecurityScopedResource()
        library.migrateMetadata(fromRoot: oldRoot, toRoot: url, removeSource: true, verifyExists: true)
        if accessed { oldRoot.stopAccessingSecurityScopedResource() }
        resultMessage = "Re-linked Favorites, covers, and captions to this drive."
    }

    @ViewBuilder private var editingOverlay: some View {
        VStack(spacing: 12) {
            Text("Rotating…").font(.subheadline.weight(.medium))
            ProgressView(value: editProgress).progressViewStyle(.linear).frame(width: 220)
            Text("\(Int(editProgress * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Text("You can leave the app — it keeps going briefly in the background.")
                .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(24).frame(maxWidth: 280)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder private var importingOverlay: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large)
            Text("Adding from Photos…").font(.subheadline)
        }
        .padding(24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func handlePhotosImport(_ results: [PHPickerResult]) {
        showPhotosPicker = false
        guard !results.isEmpty else { return }
        importing = true
        Task {
            let imported = await FileActions.importFromPhotos(results, into: url)
            for item in imported {
                if let id = item.assetID { library.setOrigin(id, for: item.url) }
            }
            importing = false
            resultMessage = imported.isEmpty
                ? "Couldn’t add the selected items."
                : "Added \(imported.count) item(s) from Photos."
            await reload()
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            if !entries.isEmpty { filterBar }
            grid
        }
        .navigationTitle(isRoot ? library.rootName : url.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Search folder + subfolders")
        .toolbar { toolbar }
        .task(id: library.sort) { await reload() }
        .onChange(of: library.changeToken) { Task { await reload() } }
        .task(id: "search-\(query)-\(library.sort.rawValue)-\(library.index.count)") { await runSearch() }
        .task(id: "labels-\(showFavoritesOnly)-\(showAIOnly)-\(library.labelsVersion)-\(library.sort.rawValue)") {
            let root = library.rootURL ?? url
            if showFavoritesOnly {
                favoriteEntries = await library.labeledEntries(under: root, paths: library.favorites, sort: library.sort)
            }
            if showAIOnly {
                aiEntries = await library.labeledEntries(under: root, paths: library.aiLabels, sort: library.sort)
            }
        }
        // Taylor Swift label filter: gather items (recursively under this folder)
        // that carry every selected label.
        .task(id: "tslabels-\(tsLabelFilter.sorted().joined(separator: "|"))-\(library.labelsVersion)-\(library.sort.rawValue)") {
            tsLabelEntries = tsLabelMode
                ? await library.labeledEntries(under: url, paths: library.pathsMatchingAll(tsLabelFilter), sort: library.sort)
                : []
        }
        // Load dimensions/HDR only when the resolution filter is on, and only once.
        .task(id: "specs-\(advancedActive)-\(entries.count)-\(url.path)") {
            if advancedActive, fileSpecs.isEmpty {
                fileSpecs = await library.mediaSpecs(for: entries)
            }
        }
        // Compute ages (folder + subfolders) when a birthday is in context — used
        // by the Age filter and age search.
        .task(id: "ages-\(library.changeToken)-\(url.path)") {
            if library.hasBirthdayContext(url) {
                loadingAges = true
                agedList = await library.agedMedia(under: url, birthdays: library.folderBirthdays, sort: library.sort)
                loadingAges = false
            } else {
                agedList = []
                if ageFilter != nil { ageFilter = nil }
            }
        }
    }

    @ViewBuilder private var exportingOverlay: some View {
        VStack(spacing: 12) {
            Text("Exporting frames…").font(.subheadline.weight(.medium))
            ProgressView(value: exportProgress)
                .progressViewStyle(.linear)
                .frame(width: 220)
            Text("\(Int(exportProgress * 100))%")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Text("You can leave this screen — it keeps going in the background.")
                .font(.caption2).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: 280)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder private var emptyOverlay: some View {
        if filtered.isEmpty {
            VStack(spacing: 8) {
                if loadingAges && (ageFilter != nil || !query.trimmingCharacters(in: .whitespaces).isEmpty) {
                    ProgressView()
                    Text("Calculating ages…").foregroundStyle(.secondary)
                } else if searching {
                    ProgressView()
                    Text("Searching…").foregroundStyle(.secondary)
                } else if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                    Image(systemName: "magnifyingglass").font(.largeTitle).foregroundStyle(.secondary)
                    Text("No results").foregroundStyle(.secondary)
                } else if loaded {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.largeTitle).foregroundStyle(.secondary)
                    Text(tsLabelMode ? "No items match these labels"
                         : showFavoritesOnly ? "No favorites here yet"
                         : showAIOnly ? "Nothing marked To AI yet"
                         : advancedActive ? "No matches for this filter"
                         : "This folder is empty")
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            }
        }
    }

    // MARK: - Filter bar

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                Button {
                    showFavoritesOnly.toggle()
                    if showFavoritesOnly { showAIOnly = false; tsLabelFilter.removeAll() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: showFavoritesOnly ? "heart.fill" : "heart")
                        Text("Favorites").font(.subheadline.weight(.medium))
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.thinMaterial, in: Capsule())
                    .foregroundStyle(showFavoritesOnly ? Color.red : Color.primary)
                }

                Button {
                    showAIOnly.toggle()
                    if showAIOnly { showFavoritesOnly = false; tsLabelFilter.removeAll() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                        Text("To AI").font(.subheadline.weight(.medium))
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.thinMaterial, in: Capsule())
                    .foregroundStyle(showAIOnly ? Color.yellow : Color.primary)
                }

                if inTaylorSwift {
                    Menu {
                        ForEach(Library.taylorSwiftLabels, id: \.self) { name in
                            Button { toggleTSLabelFilter(name) } label: { check(name, tsLabelFilter.contains(name)) }
                        }
                        if tsLabelMode {
                            Divider()
                            Button(role: .destructive) { tsLabelFilter.removeAll() } label: {
                                Label("Clear Labels", systemImage: "xmark.circle")
                            }
                        }
                    } label: {
                        chip(tsLabelFilter.isEmpty ? "Labels" : "Labels (\(tsLabelFilter.count))")
                            .foregroundStyle(tsLabelMode ? Color.accentColor : Color.primary)
                    }
                }

                if labelMode {
                    Menu {
                        ForEach(LabelKind.allCases) { kind in
                            Button { labelKind = kind } label: { check(kind.rawValue, labelKind == kind) }
                        }
                    } label: { chip("Show: \(labelKind.rawValue)") }
                } else {
                    if library.hasBirthdayContext(url) {
                        Menu {
                            Button { ageFilter = nil } label: { check("All Ages", ageFilter == nil) }
                            ForEach(availableAges, id: \.self) { age in
                                Button { ageFilter = age } label: { check("Age \(age)", ageFilter == age) }
                            }
                        } label: {
                            chip("Age: \(ageFilter.map { "\($0)" } ?? "All")")
                                .foregroundStyle(ageFilter != nil ? Color.accentColor : Color.primary)
                        }
                    }

                    Menu {
                        Button { yearFilter = nil } label: { check("All Years", yearFilter == nil) }
                        ForEach(availableYears, id: \.self) { year in
                            Button { yearFilter = year } label: { check(String(year), yearFilter == year) }
                        }
                    } label: { chip("Year: \(yearFilter.map(String.init) ?? "All")") }

                    Menu {
                        ForEach(TypeFilter.allCases) { type in
                            Button { typeFilter = type } label: { check(type.rawValue, typeFilter == type) }
                        }
                    } label: { chip("Type: \(typeFilter.rawValue)") }
                }

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    private func chip(_ text: String) -> some View {
        HStack(spacing: 4) {
            Text(text).font(.subheadline.weight(.medium))
            Image(systemName: "chevron.down").font(.caption2)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.thinMaterial, in: Capsule())
    }

    @ViewBuilder private func check(_ title: String, _ on: Bool) -> some View {
        if on { Label(title, systemImage: "checkmark") } else { Text(title) }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if selecting {
                Button("Done") { selecting = false; selection.removeAll() }
            } else {
                Button("Select") { selecting = true }.disabled(entries.isEmpty)
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            if selecting {
                Button(selection.count == filtered.count ? "None" : "All") { toggleAll() }
            } else {
                if !isRoot {
                    Button { library.goHome() } label: { Image(systemName: "house") }
                }
                if !labelMode {
                    filterMenu
                }
                Menu {
                    ForEach(SortKey.allCases) { key in
                        // Age sorting only where a birthday is in context.
                        if !key.isAge || library.hasBirthdayContext(url) {
                            Button {
                                library.sort = key
                            } label: {
                                if key == library.sort {
                                    Label(key.rawValue, systemImage: "checkmark")
                                } else {
                                    Text(key.rawValue)
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                Menu {
                    Button { playSlideshow() } label: { Label("Play Slideshow", systemImage: "play.rectangle") }
                        .disabled(mediaItems.isEmpty)
                    Button { showNewFolder = true } label: { Label("New Folder", systemImage: "folder.badge.plus") }
                    Button { showDuplicates = true } label: { Label("Find Duplicates", systemImage: "doc.on.doc") }
                    Button { photosLibraryMoves = false; showPhotosLibrary = true } label: { Label("Photos Library", systemImage: "photo.stack") }
                    Divider()
                    Button { pickFolder(.transfer) } label: {
                        Label("Move Here from Another Drive…", systemImage: "externaldrive.badge.minus")
                    }
                    Button { photosLibraryMoves = true; showPhotosLibrary = true } label: {
                        Label("Add from iOS Album…", systemImage: "photo.badge.arrow.down")
                    }
                    Button { showMegaImport = true } label: {
                        Label("Add from MEGA…", systemImage: "arrow.down.circle")
                    }
                    Button { pickFolder(.relink) } label: {
                        Label("Re-link Favorites from a Drive…", systemImage: "link")
                    }
                    if isRoot {
                        Button { pickFolder(.open) } label: { Label("Open Folder…", systemImage: "externaldrive") }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }

    /// Resolution / HDR filter menu (videos, images, and HDR — combinable).
    private var filterMenu: some View {
        Menu {
            Menu("Video Resolution") {
                ForEach(VideoRes.allCases) { r in
                    Button { videoRes = r } label: { check(r.rawValue, videoRes == r) }
                }
            }
            Menu("Image Resolution") {
                ForEach(ImageRes.allCases) { r in
                    Button { imageRes = r } label: { check(r.rawValue, imageRes == r) }
                }
            }
            Button { hdrOnly.toggle() } label: { check("HDR", hdrOnly) }
            if advancedActive {
                Divider()
                Button(role: .destructive) {
                    videoRes = .all; imageRes = .all; hdrOnly = false
                } label: { Label("Clear Filters", systemImage: "xmark.circle") }
            }
        } label: {
            Image(systemName: advancedActive ? "line.3.horizontal.decrease.circle.fill"
                                             : "line.3.horizontal.decrease.circle")
        }
    }

    // MARK: - Selection action bar

    private var selectionBar: some View {
        HStack {
            barButton("Delete", "trash", role: .destructive) { confirmDelete = true }
            Spacer()
            barButton("Favorite", "heart") { bulkFavorite() }
            Spacer()
            barButton("To AI", "sparkles") { bulkAI() }
            Spacer()
            barButton("Caption", "text.bubble") { startCaptionEdit() }
            Spacer()
            barButton("Move", "folder.fill") { showMovePicker = true }
            Spacer()
            Menu {
                Button { startBulkMetadataEdit() } label: { Label("Edit Metadata", systemImage: "calendar.badge.clock") }
                if inTaylorSwift {
                    Menu {
                        ForEach(Library.taylorSwiftLabels, id: \.self) { name in
                            Button { bulkToggleTSLabel(name) } label: {
                                check(name, !selection.isEmpty && selectedEntries().allSatisfy { library.hasLabel(name, $0.url) })
                            }
                        }
                    } label: { Label("Taylor Swift Label", systemImage: "tag") }
                }
                Menu {
                    Button { bulkRotate(2) } label: { Label("Rotate 180°", systemImage: "arrow.clockwise") }
                    Button { bulkRotate(-1) } label: { Label("Rotate Left", systemImage: "rotate.left") }
                    Button { bulkRotate(1) } label: { Label("Rotate Right", systemImage: "rotate.right") }
                } label: { Label("Rotate", systemImage: "rotate.right") }
                Button { duplicateEntries(selectedEntries()) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                Button { showCopyPicker = true } label: { Label("Copy to Folder…", systemImage: "doc.on.doc") }
                Divider()
                Button { saveToPhotos() } label: { Label("Save to Photos", systemImage: "photo.on.rectangle") }
                Button { exportToFiles() } label: { Label("Save to Files", systemImage: "folder") }
            } label: {
                VStack(spacing: 2) {
                    Image(systemName: "ellipsis.circle")
                    Text("More").font(.caption2)
                }
            }
        }
        .disabled(selection.isEmpty)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    /// Rotates every selected photo/video in place (mainly a 180° turn to fix
    /// upside-down videos). Re-encodes each file and re-keys nothing — paths are
    /// unchanged. Runs under a background-task window so a brief backgrounding is OK.
    private func bulkRotate(_ quarters: Int) {
        let targets = selectedEntries().filter { $0.isViewable }
        guard !targets.isEmpty else { resultMessage = "Select one or more photos or videos."; return }
        selecting = false; selection.removeAll()
        editProcessing = true; editProgress = 0
        let bg = BackgroundTaskHolder()
        bg.begin(name: "Rotate Media")
        Task {
            let full = CGRect(x: 0, y: 0, width: 1, height: 1)
            var failed = 0
            for (i, e) in targets.enumerated() {
                let ok: Bool
                if e.kind == .image {
                    ok = await Task.detached { MediaEditing.applyPhotoInPlace(url: e.url, quarters: quarters, crop: full) }.value
                } else {
                    ok = await MediaEditing.exportVideoInPlace(url: e.url, quarters: quarters, crop: full) { _ in }
                }
                if !ok { failed += 1 }
                editProgress = Double(i + 1) / Double(targets.count)
            }
            editProcessing = false
            bg.end()
            resultMessage = failed == 0
                ? "Rotated \(targets.count) item(s)."
                : "Rotated \(targets.count - failed) of \(targets.count); \(failed) couldn’t be saved."
            library.contentDidChange()
            await reload()
        }
    }

    private func startBulkMetadataEdit() {
        let media = selectedEntries().filter { $0.isViewable }.map(\.url)
        guard !media.isEmpty else { resultMessage = "Select one or more photos or videos."; return }
        metadataTargets = media
        selecting = false; selection.removeAll()
        showMetadataEditor = true
    }

    /// Favorite all selected (or un-favorite if every one is already favorited).
    private func bulkFavorite() {
        let sel = selectedEntries()
        let allOn = sel.allSatisfy { library.isFavorite($0.url) }
        for e in sel where library.isFavorite(e.url) == allOn { library.toggleFavorite(e.url) }
        selecting = false; selection.removeAll()
    }

    /// To-AI all selected (or remove if every one is already labeled).
    private func bulkAI() {
        let sel = selectedEntries()
        let allOn = sel.allSatisfy { library.isAI($0.url) }
        for e in sel where library.isAI(e.url) == allOn { library.toggleAI(e.url) }
        selecting = false; selection.removeAll()
    }

    /// Toggles a Taylor Swift label in the filter (and leaves the other modes).
    private func toggleTSLabelFilter(_ name: String) {
        if tsLabelFilter.contains(name) { tsLabelFilter.remove(name) }
        else { tsLabelFilter.insert(name); showFavoritesOnly = false; showAIOnly = false }
    }

    /// Adds a Taylor Swift label to every selected item (or removes it if all
    /// already carry it) — the same all-or-nothing rule as Favorite / To AI.
    private func bulkToggleTSLabel(_ name: String) {
        let sel = selectedEntries()
        guard !sel.isEmpty else { return }
        let allOn = sel.allSatisfy { library.hasLabel(name, $0.url) }
        for e in sel { library.setLabel(name, on: e.url, !allOn) }
        selecting = false; selection.removeAll()
    }

    private func barButton(_ title: String, _ icon: String, role: ButtonRole? = nil,
                           action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon)
                Text(title).font(.caption2)
            }
        }
    }

    // MARK: - Actions

    private func tap(_ entry: Entry) {
        if selecting {
            if selection.contains(entry.url) { selection.remove(entry.url) } else { selection.insert(entry.url) }
        } else if entry.isFolder {
            library.path.append(entry.url)
        } else if entry.isViewable {
            let media = mediaItems
            viewerPresentation = ViewerPresentation(items: media,
                                                    startIndex: media.firstIndex(of: entry) ?? 0)
        } else {
            previewItem = PreviewItem(url: entry.url)   // PDFs and other files open in QuickLook
        }
    }

    private func toggleAll() {
        if selection.count == filtered.count { selection.removeAll() }
        else { selection = Set(filtered.map(\.url)) }
    }

    private func reload() async {
        loaded = false
        captureDates = [:]; fileCaptions = [:]; fileSpecs = [:]
        let list = await library.listing(of: url, sort: library.sort)
        entries = list
        loaded = true
        // Capture dates + captions only (cheap). Media specs — which open every
        // video with AVAsset — load lazily, only when the resolution/HDR filter
        // is actually used; otherwise opening a folder (or returning from an
        // export) would needlessly scan every file and stall.
        async let dates = library.captureDates(for: list)
        async let caps = library.fileCaptions(for: list)
        captureDates = await dates
        fileCaptions = await caps
    }

    // MARK: - Caption / folder / move actions

    private func startCaptionEdit() {
        let sel = selectedEntries()
        captionDraft = sel.count == 1 ? effectiveCaption(for: sel[0]) : ""
        showCaptionEditor = true
    }

    private func applyCaption() {
        for e in selectedEntries() { library.setCaption(captionDraft, for: e.url) }
        selecting = false; selection.removeAll()
    }

    private func createFolder() {
        let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        newFolderName = ""
        guard FileActions.createFolder(named: name, in: url) else { return }
        library.contentDidChange()                       // refresh this folder's listing
        library.path.append(url.appendingPathComponent(name, isDirectory: true))   // open the new folder
    }

    private func performRename() {
        if let target = renameTarget, let newURL = FileActions.rename(target.url, to: renameDraft) {
            library.itemMoved(from: target.url, to: newURL)   // keep labels/captions attached
        }
        renameTarget = nil
        Task { await reload() }
    }

    private func performMove(to dest: URL) {
        let moved = FileActions.move(selectedEntries().map(\.url), to: dest)
        for pair in moved { library.itemMoved(from: pair.from, to: pair.to) }   // labels follow
        selection.removeAll(); selecting = false
        resultMessage = "Moved \(moved.count) item(s)."
        Task { await reload() }
    }

    private func performCopy(to dest: URL) {
        let copied = FileActions.copy(selectedEntries().map(\.url), to: dest)
        selection.removeAll(); selecting = false
        resultMessage = "Copied \(copied.count) item(s)."
        // Copies don't carry labels (the originals keep theirs), so no metadata
        // migration. Only reload if the copies landed in the folder on screen.
        if dest.standardizedFileURL == url.standardizedFileURL { Task { await reload() } }
    }

    private func exportFrames(_ entry: Entry, name: String) {
        exporting = true
        exportProgress = 0
        let bg = BackgroundTaskHolder()
        bg.begin(name: "Export All Frames")   // keep running if the app is backgrounded
        Task {
            let (folder, count) = await FileActions.exportAllFrames(of: entry.url, folderName: name) { p in
                Task { @MainActor in exportProgress = p }
            }
            exporting = false
            bg.end()
            let frameWord = count == 1 ? "frame" : "frames"
            resultMessage = count > 0
                ? "Exported \(count) \(frameWord) to “\(folder?.lastPathComponent ?? "Frames")”."
                : "Couldn’t export frames."
            await reload()
        }
    }

    private func selectedEntries() -> [Entry] { filtered.filter { selection.contains($0.url) } }

    private func performDelete() {
        let targets = selectedEntries()
        let assetIDs = targets.compactMap { library.origin(for: $0.url) }   // Photos-imported items
        FileActions.delete(targets)
        library.clearOrigins(targets.map(\.url))
        selection.removeAll(); selecting = false
        if !assetIDs.isEmpty {
            // Also remove the originals from the iOS Photos library (→ Recently
            // Deleted). iOS shows its own confirmation prompt.
            Task { await FileActions.deletePhotosAssets(assetIDs) }
        }
        Task { await reload() }
    }

    private func saveToPhotos() {
        let targets = selectedEntries()
        Task {
            let r = await FileActions.saveToPhotos(targets)
            selecting = false; selection.removeAll()
            resultMessage = r.note ?? (r.failed == 0
                ? "Saved \(r.saved) to Photos."
                : "Saved \(r.saved), \(r.failed) couldn't be saved.")
        }
    }

    private func exportToFiles() {
        exportURLs = selectedEntries().map(\.url)
        showExporter = true
    }
}

/// Collects each visible cell's frame (in the grid's coordinate space) so a
/// drag can hit-test which cell the finger is over for swipe-to-select.
private struct CellFramesKey: PreferenceKey {
    static var defaultValue: [URL: CGRect] = [:]
    static func reduce(value: inout [URL: CGRect], nextValue: () -> [URL: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}
