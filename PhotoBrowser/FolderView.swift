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
    /// Years present under each subfolder — fills in while a year filter is active
    /// so folders with nothing from that year can be hidden.
    @State private var folderYears: [URL: Set<Int>] = [:]
    /// Image URLs that have a same-basename sibling video (Live Photo pairs), for
    /// the LIVE badge. Computed once per listing — no per-cell filesystem checks.
    @State private var liveImageURLs: Set<URL> = []
    @State private var fileCaptions: [URL: String] = [:]
    @State private var showCaptionEditor = false
    @State private var captionDraft = ""
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var renameTarget: Entry?
    @State private var renameDraft = ""
    @State private var showMovePicker = false
    @State private var moveConflict: MoveConflict?
    struct MoveConflict: Identifiable { let id = UUID(); let dest: URL; let items: [Entry] }
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
    @State private var tsNoLabel = false
    @State private var tsLabelEntries: [Entry] = []
    @State private var showDuplicates = false
    @State private var showCleanup = false
    @State private var showRandomCleanup = false
    @State private var showInstagram = false
    @State private var igForceFull = false
    @State private var showTikTok = false
    @State private var confirmFixDates = false
    @State private var fixingDates = false
    @State private var indexingText = false
    @State private var textIndexProgress = 0.0
    @State private var confirmPhoneCheck = false
    @State private var checkingPhone = false
    @State private var phoneProgress = 0.0
    @State private var showPeople = false
    @State private var showSettings = false
    @State private var fixProgress: Double = 0
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
    @State private var showTaylorBrowser = false
    @State private var showAccessKardashian = false
    @State private var showTaylorCrossRef = false
    @State private var importing = false
    @State private var editEntry: Entry?
    @State private var resizeEntry: Entry?
    @State private var aiEditEntry: Entry?
    @State private var editProcessing = false
    @State private var editProgress: Double = 0
    @State private var makingLive = false
    @State private var metadataTargets: [URL] = []
    @State private var showMetadataEditor = false
    @State private var transferItem: PreviewItem?
    @State private var cellFrames: [URL: CGRect] = [:]
    @State private var dragSelectAdding = true
    @State private var lastDragPoint: CGPoint?
    // Drag-select state, snapshotted at the start of a drag so it's stable while
    // the grid scrolls: the row-major order, a url→index map, the anchor cell, and
    // the selection before the drag (so moving back shrinks the painted range).
    @State private var dragOrder: [URL] = []
    @State private var dragIndexMap: [URL: Int] = [:]
    @State private var dragAnchorIndex: Int?
    @State private var dragBaseSelection: Set<URL> = []
    @State private var scrollLocked = false        // page scroll off during a select-drag
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
    /// The nearest ancestor folder named "Taylor Swift" strictly above this folder
    /// (nil when we're at it or outside it) — the target for "Move to Taylor Swift".
    private var taylorSwiftRoot: URL? {
        guard let root = library.rootURL?.standardizedFileURL else { return nil }
        var cur = url.standardizedFileURL
        while cur.pathComponents.count > root.pathComponents.count {
            cur = cur.deletingLastPathComponent()
            if cur.lastPathComponent == "Taylor Swift" { return cur }
        }
        return nil
    }
    /// Bespoke category labeling also applies inside an accessKardashian member
    /// folder (or any subfolder), with that member's seven Kardashian categories.
    private var inKardashian: Bool { library.inKardashianContext(url) }
    /// Whether this folder offers custom label chips (Taylor Swift or Kardashian).
    private var hasCustomLabels: Bool { inTaylorSwift || inKardashian }
    /// The label set offered here (Kardashian categories take precedence when both
    /// somehow apply, since the Kardashian folders are the more specific context).
    private var currentLabelSet: [String] { inKardashian ? Library.kardashianLabels : Library.taylorSwiftLabels }
    private var customLabelMenuTitle: String { inKardashian ? "Category" : "Taylor Swift Label" }

    private var tsLabelMode: Bool { !tsLabelFilter.isEmpty || tsNoLabel }
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

        // Bubble folders (Instagram + album highlights) are shown as bubbles, not tiles.
        var list = entries.filter { !($0.isFolder && isBubbleFolder($0.url)) }
        if let yearFilter {
            // Files must match the year; folders are hidden once we know they hold
            // nothing from that year (shown until their years are computed).
            list = list.filter { entry in
                entry.isFolder ? (folderYears[entry.url]?.contains(yearFilter) ?? true)
                               : year(of: entry) == yearFilter
            }
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

    /// Clean-up queue: every viewable item in this folder, stably name-sorted (so the
    /// review order is consistent across sessions regardless of the active sort/filter).
    private var cleanupItems: [Entry] {
        entries.filter { $0.isViewable }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private enum CleanupAction {
        case start, resume, rerun      // no progress / partway / fully reviewed → restart
        var title: String {
            switch self {
            case .start:  return "Start Clean Up"
            case .resume: return "Resume Clean Up"
            case .rerun:  return "Re-run Clean Up"
            }
        }
    }

    /// What the clean-up button should do for this folder, given its current items.
    private var cleanupAction: CleanupAction {
        let reviewed = library.reviewedInCleanup(url)
        if reviewed.isEmpty { return .start }
        return cleanupItems.contains { !reviewed.contains($0.url.path) } ? .resume : .rerun
    }

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
            .scrollDisabled(scrollLocked)        // freeze the page while a select-drag is active
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
            // Photos-style drag-select (Select mode only): a brief press on a cell
            // locks page scrolling, then dragging paints a contiguous selection with
            // edge auto-scroll. The brief hold is what distinguishes a select-drag
            // from a scroll flick — a quick swipe (no hold) still free-scrolls; only a
            // deliberate press-then-drag selects. In browse mode the gesture is limited
            // to subviews so the cells' context menu (long-press) still works.
            // A plain `.gesture` keeps it below the cells' tap gesture (tap toggles).
            .gesture(
                LongPressGesture(minimumDuration: 0.12)
                    .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named("grid")))
                    .onChanged { value in
                        guard case .second(true, let drag) = value else { return }
                        scrollLocked = true                  // hold completed → freeze scroll, then select
                        if let drag {
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
                  isLive: liveImageURLs.contains(entry.url),
                  isAIGenerated: library.isAIGenerated(entry.url),
                  coverURL: entry.isFolder ? library.coverURL(for: entry.url) : nil)
            .background {
                // Always publish cell frames (only the visible LazyVGrid cells exist)
                // so a drag-select can begin immediately — even before Select mode.
                GeometryReader { geo in
                    Color.clear.preference(key: CellFramesKey.self,
                                           value: [entry.url: geo.frame(in: .named("grid"))])
                }
            }
            .onTapGesture { tap(entry) }
            // No long-press menu while selecting — press-and-hold there starts a drag-select.
            .contextMenu { if !selecting { contextMenu(for: entry) } }
    }

    /// Paints a contiguous selection range as the finger moves — like Photos: every
    /// item between the anchor (where the drag began) and the cell under the finger,
    /// in row-major order, is selected (or deselected), so full rows fill in even
    /// when the finger only travels down one column.
    private func dragSelect(at point: CGPoint) {
        guard let curIndex = dragIndex(at: point) else { return }
        if dragAnchorIndex == nil {
            // First touch: snapshot the order + the pre-drag selection, and decide
            // whether this drag adds or removes (based on the anchor's current state).
            dragOrder = filtered.map(\.url)
            dragIndexMap = Dictionary(uniqueKeysWithValues: dragOrder.enumerated().map { ($1, $0) })
            dragAnchorIndex = dragIndexMap[filtered[curIndex].url]
            dragBaseSelection = selection
            dragSelectAdding = curIndex < dragOrder.count ? !selection.contains(dragOrder[curIndex]) : true
        }
        guard let anchor = dragAnchorIndex else { return }
        let lo = min(anchor, curIndex), hi = max(anchor, curIndex)
        var newSel = dragBaseSelection
        for i in lo...hi where i >= 0 && i < dragOrder.count {
            if dragSelectAdding { newSel.insert(dragOrder[i]) } else { newSel.remove(dragOrder[i]) }
        }
        selection = newSel
    }

    /// The row-major index of the cell under `point` — or, when the finger is in a
    /// gap or off the side (e.g. dragging down the right edge), the nearest visible
    /// cell, so the painted range still extends through the whole rows it passes.
    private func dragIndex(at point: CGPoint) -> Int? {
        let map = dragAnchorIndex == nil
            ? Dictionary(uniqueKeysWithValues: filtered.enumerated().map { ($1.url, $0) })
            : dragIndexMap
        if let url = cellFrames.first(where: { $0.value.contains(point) })?.key, let i = map[url] { return i }
        var best: (idx: Int, dist: CGFloat)?
        for (url, frame) in cellFrames {
            guard let i = map[url] else { continue }
            let dx = max(frame.minX - point.x, point.x - frame.maxX, 0)
            let dy = max(frame.minY - point.y, point.y - frame.maxY, 0)
            let d = dx * dx + dy * dy
            if best == nil || d < best!.dist { best = (i, d) }
        }
        return best?.idx
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
        dragAnchorIndex = nil
        dragOrder = []
        dragIndexMap = [:]
        dragBaseSelection = []
        lastDragPoint = nil
        autoScrollDir = 0
        scrollLocked = false
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
            if !library.isInstagramFolder(entry.url) && !library.isInstagramHighlight(entry.url) {
                Button { makeAlbumHighlight(entry) } label: {
                    Label(library.isAlbumHighlight(entry.url) ? "Remove from Highlights" : "Turn into Album Highlight",
                          systemImage: library.isAlbumHighlight(entry.url) ? "circle.badge.minus" : "circle.dashed.inset.filled")
                }
            }
        } else {
            if entry.isViewable {
                Button { infoEntry = entry } label: {
                    Label("Get Info", systemImage: "info.circle")
                }
                Button { editEntry = entry } label: {
                    Label("Crop & Rotate", systemImage: "crop.rotate")
                }
                if entry.kind == .image {
                    Button { resizeEntry = entry } label: {
                        Label("Resize / Extend", systemImage: "aspectratio")
                    }
                    Button { aiEditEntry = entry } label: {
                        Label("Edit with AI", systemImage: "wand.and.stars")
                    }
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
            .sheet(item: $moveConflict) { c in
                MoveConflictView(dest: c.dest, items: c.items,
                                 onConfirm: { keep in finishMove(to: c.dest, keepConflicts: keep) })
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
            .alert("Restore Capture Dates", isPresented: $confirmFixDates) {
                Button("Restore") { runRestoreDates() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Resets each photo and video in this folder (and its subfolders) to its original capture date, fixing items whose date was changed when added. Items with no embedded date are left unchanged.")
            }
            .alert("Check if on iPhone", isPresented: $confirmPhoneCheck) {
                Button("Check & Remove", role: .destructive) { runPhoneCheck() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Finds items in this folder that are still in your iPhone Photos (exact matches) and removes the iPhone copies — the drive copies stay. iOS will ask you to confirm the deletion.")
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
            .fullScreenCover(item: $resizeEntry) { e in ResizeEditorView(entry: e) }
            .sheet(item: $aiEditEntry) { e in AIEditView(entry: e) }
            .fullScreenCover(isPresented: $showPeople) { PeopleView(folder: url) }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .fullScreenCover(isPresented: $showPhotosLibrary) {
                PhotosLibraryView(targetFolder: url, deleteOriginals: photosLibraryMoves)
            }
            .fullScreenCover(isPresented: $showTaylorBrowser) {
                TaylorBrowserView(targetFolder: url) { Task { await reload() } }
            }
            .fullScreenCover(isPresented: $showAccessKardashian) {
                AccessKardashianView(targetFolder: url) { Task { await reload() } }
            }
            .fullScreenCover(isPresented: $showTaylorCrossRef) {
                TaylorCrossReferenceView(folder: url) { Task { await reload() } }
            }
            .fullScreenCover(isPresented: $showMegaImport) {
                MegaImportView(targetFolder: url) { Task { await reload() } }
            }
            .fullScreenCover(isPresented: $showDuplicates) {
                DuplicatesView(folder: url)
            }
            .fullScreenCover(isPresented: $showCleanup, onDismiss: { Task { await reload() } }) {
                FrameCleanupView(folder: url, items: cleanupItems)
            }
            .fullScreenCover(isPresented: $showRandomCleanup, onDismiss: { Task { await reload() } }) {
                FrameCleanupView(folder: url, items: cleanupItems, randomized: true)
            }
            .fullScreenCover(isPresented: $showInstagram, onDismiss: { igForceFull = false; Task { await reload() } }) {
                InstagramImportView(targetFolder: url, existing: library.instagramInfo(for: url), forceFull: igForceFull) { Task { await reload() } }
            }
            .fullScreenCover(isPresented: $showTikTok, onDismiss: { Task { await reload() } }) {
                TikTokImportView(targetFolder: url) { Task { await reload() } }
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
            .overlay { if makingLive { makingLiveOverlay } }
            .overlay { if importing { importingOverlay } }
            .overlay { if fixingDates { fixingOverlay } }
            .overlay { if indexingText { textIndexOverlay } }
            .overlay { if checkingPhone { phoneCheckOverlay } }
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

    @ViewBuilder private var makingLiveOverlay: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Making Live Photo…").font(.subheadline.weight(.medium))
        }
        .padding(24).frame(maxWidth: 280)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
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

    @ViewBuilder private var fixingOverlay: some View {
        VStack(spacing: 12) {
            Text("Restoring dates…").font(.subheadline.weight(.medium))
            ProgressView(value: fixProgress).progressViewStyle(.linear).frame(width: 220)
            Text("\(Int(fixProgress * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(24).frame(maxWidth: 280)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder private var textIndexOverlay: some View {
        VStack(spacing: 12) {
            Text("Reading text in photos…").font(.subheadline.weight(.medium))
            ProgressView(value: textIndexProgress).progressViewStyle(.linear).frame(width: 220)
            Text("\(Int(textIndexProgress * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Text("Afterwards, search also finds words printed inside your photos.")
                .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(24).frame(maxWidth: 280)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder private var phoneCheckOverlay: some View {
        VStack(spacing: 12) {
            Text("Checking your iPhone Photos…").font(.subheadline.weight(.medium))
            ProgressView(value: phoneProgress).progressViewStyle(.linear).frame(width: 220)
            Text("Matching this folder against your library.")
                .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(24).frame(maxWidth: 280)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    /// Finds this folder's items that are still in the iPhone Photos library (exact
    /// matches) and removes the iPhone copies — the drive copies stay.
    private func runPhoneCheck() {
        checkingPhone = true; phoneProgress = 0
        let urls = entries.filter { $0.isViewable }.map(\.url)
        let bg = BackgroundTaskHolder(); bg.begin(name: "Check if on iPhone")
        Task {
            let ids = await FileActions.photosMatches(for: urls, origins: library.photoOrigins) { p in
                Task { @MainActor in phoneProgress = p }
            }
            checkingPhone = false
            if ids.isEmpty {
                bg.end()
                resultMessage = "None of these are still on your iPhone."
                return
            }
            let removed = await FileActions.deletePhotosAssets(ids)   // iOS shows its own confirmation
            bg.end()
            resultMessage = removed
                ? "Removed \(ids.count) item(s) from your iPhone (the copies here are kept)."
                : "Found \(ids.count) on your iPhone, but the removal was cancelled."
        }
    }

    /// OCRs every photo under this folder so search can match text inside them.
    private func runTextIndex() {
        indexingText = true; textIndexProgress = 0
        let bg = BackgroundTaskHolder()
        bg.begin(name: "Index Text in Photos")
        Task {
            let total = await library.buildTextIndex(under: url) { done, tot in
                Task { @MainActor in textIndexProgress = tot > 0 ? Double(done) / Double(tot) : 1 }
            }
            indexingText = false
            bg.end()
            resultMessage = total == 0 ? "No photos here to read." : "Read text in \(total) photo(s). Search now finds words inside them."
        }
    }

    /// Resets each photo/video under this folder to its embedded capture date,
    /// repairing items whose modified date was changed to the import time.
    private func runRestoreDates() {
        fixingDates = true; fixProgress = 0
        let bg = BackgroundTaskHolder()
        bg.begin(name: "Restore Capture Dates")
        Task {
            let r = await FileActions.restoreCaptureDates(in: url, origins: library.photoOrigins) { done, tot in
                Task { @MainActor in fixProgress = tot > 0 ? Double(done) / Double(tot) : 1 }
            }
            fixingDates = false
            bg.end()
            if r.scanned == 0 {
                resultMessage = "No photos or videos here."
            } else {
                var msg = "Restored \(r.fixed) of \(r.scanned) item(s) to their capture date."
                if r.fromFallback > 0 { msg += " \(r.fromFallback) from filename/EXIF/Photos." }
                if r.noDate > 0 { msg += " \(r.noDate) had no date." }
                if r.failed > 0 { msg += " \(r.failed) couldn’t be written." }
                resultMessage = msg
            }
            library.contentDidChange()
            await reload()
        }
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
            header
            if showBubbles { instagramBubbleRow }
            if !entries.isEmpty { filterBar }
            grid
        }
        .navigationTitle(isRoot ? "Home" : url.lastPathComponent)
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
        // Taylor Swift label filter: either items carrying every selected label,
        // or (No Label) every photo/video under this folder with no label yet.
        .task(id: "tslabels-\(tsLabelFilter.sorted().joined(separator: "|"))-\(tsNoLabel)-\(library.labelsVersion)-\(library.sort.rawValue)") {
            if tsNoLabel {
                tsLabelEntries = await library.unlabeledMedia(under: url, labeled: library.allLabeledPaths(), sort: library.sort)
            } else if !tsLabelFilter.isEmpty {
                tsLabelEntries = await library.labeledEntries(under: url, paths: library.pathsMatchingAll(tsLabelFilter), sort: library.sort)
            } else {
                tsLabelEntries = []
            }
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
        // While a year filter is active, learn which years each subfolder holds so
        // folders with nothing from that year drop out (computed lazily, cached).
        .task(id: "folderyears-\(yearFilter ?? -1)-\(entries.count)-\(library.changeToken)-\(url.path)") {
            guard yearFilter != nil else { return }
            for folder in entries where folder.isFolder && folderYears[folder.url] == nil {
                if Task.isCancelled { return }
                folderYears[folder.url] = await library.folderYears(of: folder.url)
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
                    Text(tsNoLabel ? "Everything here is labeled"
                         : tsLabelMode ? "No items match these labels"
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

    // MARK: - Header

    /// Full folder name shown in-content (the inline nav title truncates badly when
    /// crowded by the toolbar + filter chips). Always fully visible above the filters.
    private var header: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(isRoot ? "Home" : url.lastPathComponent)
                .font(.title3.weight(.semibold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text(headerSubtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    // MARK: - Instagram highlight bubbles

    /// Instagram profile subfolders, shown as a row of circular bubbles (like the
    /// highlights on a profile) instead of regular grid tiles.
    /// Folders shown as circular bubbles: Instagram profiles/highlights and any
    /// folder the user turned into an "album highlight".
    private func isBubbleFolder(_ url: URL) -> Bool {
        library.isInstagramFolder(url) || library.isInstagramHighlight(url) || library.isAlbumHighlight(url)
    }
    private var igBubbles: [Entry] {
        entries.filter { $0.isFolder && isBubbleFolder($0.url) }
            .sorted { a, b in
                let ai = library.isInstagramFolder(a.url), bi = library.isInstagramFolder(b.url)
                if ai != bi { return ai }      // the Instagram folder is always listed first
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
    }
    private var showBubbles: Bool {
        query.trimmingCharacters(in: .whitespaces).isEmpty && !labelMode && !tsLabelMode && ageFilter == nil && !igBubbles.isEmpty
    }

    private var instagramBubbleRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(igBubbles) { entry in
                    Button { tap(entry) } label: { bubble(entry) }      // select-aware (toggle vs open)
                        .buttonStyle(.plain)
                        .contextMenu { if !selecting { contextMenu(for: entry) } }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
    }

    private func bubble(_ entry: Entry) -> some View {
        let isSel = selection.contains(entry.url)
        return VStack(spacing: 5) {
            ZStack {
                Circle()
                    .strokeBorder(
                        LinearGradient(colors: [Color(red: 0.99, green: 0.6, blue: 0.11),
                                                Color(red: 0.95, green: 0.27, blue: 0.42),
                                                Color(red: 0.56, green: 0.23, blue: 0.83)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 2.5)
                    .frame(width: 72, height: 72)
                bubbleImage(entry).frame(width: 62, height: 62).clipShape(Circle())
                    .overlay { if selecting && !isSel { Circle().fill(.black.opacity(0.4)) } }
                if selecting {
                    Image(systemName: isSel ? "checkmark.circle.fill" : "circle")
                        .font(.body).foregroundStyle(isSel ? Color.accentColor : .white)
                        .background(Circle().fill(.black.opacity(0.4)))
                        .offset(x: 22, y: 22)
                }
            }
            Text(library.instagramInfo(for: entry.url).map { "@\($0.handle)" } ?? entry.name)
                .font(.caption2).lineLimit(1).frame(maxWidth: 76)
        }
    }

    @ViewBuilder private func bubbleImage(_ entry: Entry) -> some View {
        if let cover = library.coverURL(for: entry.url), let img = UIImage(contentsOfFile: cover.path) {
            Image(uiImage: img).resizable().scaledToFill()
        } else {
            Circle().fill(Color(white: 0.2))
                .overlay { Image(systemName: "photo.stack").font(.title3).foregroundStyle(.secondary) }
        }
    }

    /// Toggles a folder's "album highlight" status; seeds its bubble cover from the
    /// first item when it has none.
    private func makeAlbumHighlight(_ entry: Entry) {
        let on = !library.isAlbumHighlight(entry.url)
        library.setAlbumHighlight(on, for: entry.url)
        if on, library.coverURL(for: entry.url) == nil {
            Task { if let cover = await firstFolderThumbnail(entry.url) { library.setCover(cover, for: entry.url) } }
        }
    }

    private func firstFolderThumbnail(_ dir: URL) async -> UIImage? {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        guard let first = files.filter({ [.image, .video].contains(classify(url: $0, isDirectory: false)) })
            .sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending })
            .first else { return nil }
        let e = Entry(url: first, name: first.lastPathComponent, kind: classify(url: first, isDirectory: false), size: 0, modified: Date())
        return await Thumbnailer.shared.thumbnail(for: e, size: CGSize(width: 200, height: 200), scale: 2)
    }

    private var headerSubtitle: String {
        if showFavoritesOnly { return "Favorites" }
        if showAIOnly { return "To AI" }
        if let ig = library.instagramInfo(for: url) {
            let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
            let when = f.string(from: Date(timeIntervalSince1970: ig.lastUpdated))
            return "Last Updated on \(when) · \(ig.photos) Photos and \(ig.videos) Videos"
        }
        let albums = entries.filter { $0.isFolder }.count
        if isRoot || albums > 0 {
            let items = filtered.filter { !$0.isFolder }.count
            let albumPart = "\(albums) album\(albums == 1 ? "" : "s")"
            return items > 0 ? "\(albumPart) · \(items) item\(items == 1 ? "" : "s")" : albumPart
        }
        let n = filtered.count
        return "\(n) item\(n == 1 ? "" : "s")"
    }

    // MARK: - Filter bar

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                Button {
                    showFavoritesOnly.toggle()
                    if showFavoritesOnly { showAIOnly = false; tsLabelFilter.removeAll(); tsNoLabel = false }
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
                    if showAIOnly { showFavoritesOnly = false; tsLabelFilter.removeAll(); tsNoLabel = false }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                        Text("To AI").font(.subheadline.weight(.medium))
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.thinMaterial, in: Capsule())
                    .foregroundStyle(showAIOnly ? Color.yellow : Color.primary)
                }

                if hasCustomLabels {
                    Menu {
                        Button { toggleTSNoLabel() } label: { check("No Label", tsNoLabel) }
                        Divider()
                        ForEach(currentLabelSet, id: \.self) { name in
                            Button { toggleTSLabelFilter(name) } label: { check(name, tsLabelFilter.contains(name)) }
                        }
                        if tsLabelMode {
                            Divider()
                            Button(role: .destructive) { tsLabelFilter.removeAll(); tsNoLabel = false } label: {
                                Label("Clear", systemImage: "xmark.circle")
                            }
                        }
                    } label: {
                        chip(tsNoLabel ? "No Label" : tsLabelFilter.isEmpty ? "Labels" : "Labels (\(tsLabelFilter.count))")
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
                Button(selection.count == selectableEntries.count ? "None" : "All") { toggleAll() }
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
                    Button {
                        if case .rerun = cleanupAction { library.resetCleanup(url) }   // fresh pass over what's left
                        showCleanup = true
                    } label: {
                        Label(cleanupAction.title, systemImage: "wand.and.sparkles")
                    }
                    .disabled(cleanupItems.isEmpty)
                    Button {
                        if case .rerun = cleanupAction { library.resetCleanup(url) }   // fresh random pass
                        showRandomCleanup = true
                    } label: {
                        Label("Randomized Clean Up", systemImage: "shuffle")
                    }
                    .disabled(cleanupItems.isEmpty)
                    Divider()
                    Button { playSlideshow() } label: { Label("Play Slideshow", systemImage: "play.rectangle") }
                        .disabled(mediaItems.isEmpty)
                    Button { showNewFolder = true } label: { Label("New Folder", systemImage: "folder.badge.plus") }
                    Button { showDuplicates = true } label: { Label("Find Duplicates", systemImage: "doc.on.doc") }
                    Button { confirmFixDates = true } label: { Label("Restore Capture Dates", systemImage: "clock.arrow.circlepath") }
                    Button { runTextIndex() } label: { Label("Index Text in Photos", systemImage: "text.viewfinder") }
                    Button { confirmPhoneCheck = true } label: { Label("Check if on iPhone", systemImage: "iphone") }
                        .disabled(mediaItems.isEmpty)
                    Button { showPeople = true } label: { Label("People", systemImage: "person.2.crop.square.stack") }
                    Button { showSettings = true } label: { Label("Settings", systemImage: "gearshape") }
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
                    Button { igForceFull = false; showInstagram = true } label: {
                        Label(library.isInstagramFolder(url) ? "Get New Instagram Posts" : "Download Instagram Profile…",
                              systemImage: library.isInstagramFolder(url) ? "arrow.triangle.2.circlepath" : "camera")
                    }
                    if library.isInstagramFolder(url) {
                        Button { igForceFull = true; showInstagram = true } label: {
                            Label("Re-download Entire Profile", systemImage: "arrow.clockwise.circle")
                        }
                    }
                    Button { showTikTok = true } label: {
                        Label("Download TikTok Profile…", systemImage: "music.note")
                    }
                    Button { showTaylorBrowser = true } label: {
                        Label("Browse taylorpictures.net…", systemImage: "globe")
                    }
                    Button { showAccessKardashian = true } label: {
                        Label("Download from accessKardashian…", systemImage: "person.2.crop.square.stack.fill")
                    }
                    Button { showTaylorCrossRef = true } label: {
                        Label("Cross-Reference with taylorpictures.net…", systemImage: "calendar.badge.exclamationmark")
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
                if hasCustomLabels {
                    Menu {
                        ForEach(currentLabelSet, id: \.self) { name in
                            Button { bulkToggleTSLabel(name) } label: {
                                check(name, !selection.isEmpty && selectedEntries().allSatisfy { library.hasLabel(name, $0.url) })
                            }
                        }
                    } label: { Label(customLabelMenuTitle, systemImage: "tag") }
                }
                Menu {
                    Button { bulkRotate(2) } label: { Label("Rotate 180°", systemImage: "arrow.clockwise") }
                    Button { bulkRotate(-1) } label: { Label("Rotate Left", systemImage: "rotate.left") }
                    Button { bulkRotate(1) } label: { Label("Rotate Right", systemImage: "rotate.right") }
                } label: { Label("Rotate", systemImage: "rotate.right") }
                Button { bulkUpscale() } label: { Label("Upscale Video to 1080p", systemImage: "arrow.up.right.video") }
                Button { duplicateEntries(selectedEntries()) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                Button { showCopyPicker = true } label: { Label("Copy to Folder…", systemImage: "doc.on.doc") }
                if let tsRoot = taylorSwiftRoot {
                    Button { performMove(to: tsRoot) } label: { Label("Move to “Taylor Swift”", systemImage: "music.mic") }
                }
                if let pair = selectedLivePhotoPair {
                    Button { makeLivePhoto(pair) } label: { Label("Make Live Photo", systemImage: "livephoto") }
                }
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

    /// Upscales the selected videos to 1080p in place (labels/dates/captions kept,
    /// originals replaced). Videos already ≥1080p are skipped.
    private func bulkUpscale() {
        let targets = selectedEntries().filter { $0.kind == .video }
        guard !targets.isEmpty else { resultMessage = "Select one or more videos."; return }
        selecting = false; selection.removeAll()
        editProcessing = true; editProgress = 0
        let bg = BackgroundTaskHolder(); bg.begin(name: "Upscale Videos")
        Task {
            var upscaled = 0, skipped = 0, failed = 0
            for (i, e) in targets.enumerated() {
                switch await MediaEditing.upscaleVideoTo1080(url: e.url, progress: { _ in }) {
                case .upscaled: upscaled += 1
                case .skipped:  skipped += 1
                case .failed:   failed += 1
                }
                editProgress = Double(i + 1) / Double(targets.count)
            }
            editProcessing = false; bg.end()
            var msg = "Upscaled \(upscaled) video\(upscaled == 1 ? "" : "s") to 1080p."
            if skipped > 0 { msg += " \(skipped) already ≥1080p." }
            if failed > 0 { msg += " \(failed) couldn’t be processed." }
            resultMessage = msg
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
        else { tsLabelFilter.insert(name); tsNoLabel = false; showFavoritesOnly = false; showAIOnly = false }
    }

    /// Toggles the "No Label" filter (unlabeled photos/videos), clearing the others.
    private func toggleTSNoLabel() {
        tsNoLabel.toggle()
        if tsNoLabel { tsLabelFilter.removeAll(); showFavoritesOnly = false; showAIOnly = false }
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
        let all = selectableEntries
        if selection.count == all.count { selection.removeAll() }
        else { selection = Set(all.map(\.url)) }
    }

    private func reload() async {
        loaded = false
        captureDates = [:]; fileCaptions = [:]; fileSpecs = [:]; folderYears = [:]
        let list = await library.listing(of: url, sort: library.sort)
        entries = list
        liveImageURLs = Self.detectLivePairs(in: list)
        loaded = true
        // Capture dates + captions only (cheap). Media specs — which open every
        // video with AVAsset — load lazily, only when the resolution/HDR filter
        // is actually used; otherwise opening a folder (or returning from an
        // export) would needlessly scan every file and stall.
        async let dates = library.captureDates(for: list)
        async let caps = library.fileCaptions(for: list)
        captureDates = await dates
        fileCaptions = await caps
        // The date-based sorts order by the *file's* modified date, which for an
        // imported/copied item is the time it was added. Now that the real capture
        // dates are in, re-order by those so "newest" reflects when media was taken
        // (down to the time, not just the day).
        if library.sort == .smart || library.sort == .dateDesc || library.sort == .dateAsc {
            entries = sortedByCaptureDate(entries)
        }
    }

    /// Re-orders a date-sorted listing by true capture date+time (folders first,
    /// then media by `captureDates`, falling back to the file's modified date).
    private func sortedByCaptureDate(_ list: [Entry]) -> [Entry] {
        let ascending = (library.sort == .dateAsc)
        let smart = (library.sort == .smart)
        func key(_ e: Entry) -> Date { captureDates[e.url] ?? e.modified }
        return list.sorted { a, b in
            if a.isFolder != b.isFolder { return a.isFolder }
            if a.isFolder {
                return smart ? a.name.localizedStandardCompare(b.name) == .orderedAscending
                             : (ascending ? a.modified < b.modified : a.modified > b.modified)
            }
            let ka = key(a), kb = key(b)
            if ka != kb { return ascending ? ka < kb : ka > kb }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
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
        // Surface same-name conflicts (which may be *different* files) and let the
        // user choose to skip them or keep both, instead of silently dropping them.
        let entries = selectedEntries()
        let collisionURLs = Set(FileActions.collisions(entries.map(\.url), in: dest))
        if collisionURLs.isEmpty { finishMove(to: dest, keepConflicts: []); return }
        // Defer so the move-picker sheet (or the Menu) finishes dismissing first.
        let conflict = MoveConflict(dest: dest, items: entries.filter { collisionURLs.contains($0.url) })
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { moveConflict = conflict }
    }

    /// Completes a move. `keepConflicts` are the same-name items the user chose to
    /// move (renamed to keep both); any other conflicting item is left behind, while
    /// everything non-conflicting moves normally.
    private func finishMove(to dest: URL, keepConflicts: Set<URL>) {
        moveConflict = nil
        let allURLs = selectedEntries().map(\.url)
        let conflicts = Set(FileActions.collisions(allURLs, in: dest))
        let skip = conflicts.subtracting(keepConflicts)
        let moveURLs = allURLs.filter { !skip.contains($0) }
        let outcome = FileActions.move(moveURLs, to: dest, renameOnCollision: true)
        for pair in outcome.moved { library.itemMoved(from: pair.from, to: pair.to) }   // labels follow
        selection.removeAll(); selecting = false
        var msg = "Moved \(outcome.moved.count) item(s)."
        if !skip.isEmpty { msg += " Skipped \(skip.count) with matching names." }
        resultMessage = msg
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
            let (folder, count, firstFrame) = await FileActions.exportAllFrames(of: entry.url, folderName: name) { p in
                Task { @MainActor in exportProgress = p }
            }
            exporting = false
            bg.end()
            // Remember it as a frames folder (enables "Start Clean Up") and seed its
            // cover with the first frame.
            if count > 0, let folder {
                library.markFramesFolder(folder)
                if let firstFrame, let cover = UIImage(contentsOfFile: firstFrame.path) {
                    library.setCover(cover, for: folder)
                }
            }
            let frameWord = count == 1 ? "frame" : "frames"
            resultMessage = count > 0
                ? "Exported \(count) \(frameWord) to “\(folder?.lastPathComponent ?? "Frames")”."
                : "Couldn’t export frames."
            await reload()
        }
    }

    /// Everything selectable in this view — the grid plus the bubble folders (when shown).
    private var selectableEntries: [Entry] { showBubbles ? filtered + igBubbles : filtered }
    private func selectedEntries() -> [Entry] { selectableEntries.filter { selection.contains($0.url) } }

    /// Image URLs in `entries` that have a same-basename sibling video.
    private static func detectLivePairs(in entries: [Entry]) -> Set<URL> {
        let videoBases = Set(entries.filter { $0.kind == .video }
            .map { $0.url.deletingPathExtension().lastPathComponent.lowercased() })
        guard !videoBases.isEmpty else { return [] }
        return Set(entries.filter {
            $0.kind == .image &&
            videoBases.contains($0.url.deletingPathExtension().lastPathComponent.lowercased())
        }.map(\.url))
    }

    /// Exactly one selected photo + one selected video — the input for Make Live Photo.
    private var selectedLivePhotoPair: (image: URL, video: URL)? {
        let sel = selectedEntries()
        guard sel.count == 2,
              let image = sel.first(where: { $0.kind == .image }),
              let video = sel.first(where: { $0.kind == .video }) else { return nil }
        return (image.url, video.url)
    }

    /// Pairs a photo + video into a Live Photo (shared asset id written into both),
    /// renaming the video to share the photo's base name so the pair is recognised.
    private func makeLivePhoto(_ pair: (image: URL, video: URL)) {
        selecting = false; selection.removeAll()
        makingLive = true
        let bg = BackgroundTaskHolder()
        bg.begin(name: "Make Live Photo")
        Task {
            let result = await FileActions.makeLivePhoto(image: pair.image, video: pair.video)
            makingLive = false
            bg.end()
            if result.ok {
                if let newVideo = result.newVideo, newVideo != pair.video {
                    library.itemMoved(from: pair.video, to: newVideo)   // labels follow the rename
                }
                library.contentDidChange()
                resultMessage = "Live Photo created. Touch and hold the photo to play it."
            } else {
                resultMessage = "Couldn’t make a Live Photo from those two items."
            }
            await reload()
        }
    }

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
