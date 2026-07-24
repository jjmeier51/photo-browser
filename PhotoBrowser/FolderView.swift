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
enum ImportPurpose { case open, transfer, relink, backupMetadata }

/// Browses one directory: subfolders + files, with sort, search, a full-screen
/// viewer for photos/videos, and a Select mode for save/delete.
struct FolderView: View {
    @Environment(Library.self) private var library
    @Environment(\.scenePhase) private var scenePhase
    let url: URL
    let isRoot: Bool

    @State private var entries: [Entry] = []
    @State private var query = ""

    @State private var selecting = false
    @State private var selection = Set<URL>()

    @State private var viewerPresentation: ViewerPresentation?

    @State private var previewItem: PreviewItem?
    @State private var pendingArchive: Entry?      // a tapped .zip → offer Extract / Quick Look
    @State private var confirmDelete = false
    @State private var showExporter = false
    @State private var exportURLs: [URL] = []
    @State private var resultMessage: String?
    @State private var showFolderPicker = false
    @State private var folderPurpose: ImportPurpose = .open
    @State private var loaded = false
    @State private var yearFilter: Int?
    @State private var typeFilter: TypeFilter = .all
    @State private var showEditedOnly = false
    @State private var showHiddenFolders = false
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
    @State private var showMoveToNewFolder = false   // multi-select "Move N Items to New Folder…"
    @State private var moveNewFolderName = ""
    @State private var renameTarget: Entry?
    @State private var renameDraft = ""
    @State private var showMovePicker = false
    @State private var moveConflict: MoveConflict?
    struct MoveConflict: Identifiable { let id = UUID(); let dest: URL; let items: [Entry]; var isCopy = false }
    @State private var showCopyPicker = false
    @State private var searchResults: [Entry] = []
    @State private var searching = false
    @State private var exportTarget: Entry?
    @State private var showAIOnly = false
    @State private var aiEntries: [Entry] = []
    @State private var labelKind: LabelKind = .all
    @State private var tsLabelFilter: Set<String> = []
    @State private var tsNoLabel = false
    @State private var tsLabelEntries: [Entry] = []
    @State private var showDuplicates = false
    @State private var showCleanup = false
    @State private var showRandomCleanup = false
    @State private var bubbleItems: [Entry] = []       // live order while dragging highlight bubbles
    @State private var draggingBubble: Entry?
    @State private var showInstagram = false
    @State private var igForceFull = false
    @State private var showAllStories = false
    @State private var showBulkInstagram = false
    @State private var showFacebook = false
    @State private var showOF = false
    @State private var showLinkDownload = false
    @State private var showTikTok = false
    @State private var showVSCO = false
    @State private var showYouTube = false
    @State private var showWebBrowser = false
    @State private var confirmFixDates = false
    @State private var fixingDates = false
    @State private var indexingText = false
    @State private var textIndexProgress = 0.0
    @State private var indexingPlaces = false
    @State private var placeIndexProgress = 0.0
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
    @State private var profilePhotoItem: PreviewItem?    // cover URL of an IG folder, viewed full-screen
    @State private var ageFilter: Int?
    @State private var agedList: [(entry: Entry, age: Int)] = []
    @State private var loadingAges = false
    /// Set when the Age menu is first opened, so ages compute lazily on demand.
    @State private var agesRequested = false
    @State private var showPhotosPicker = false
    @State private var showPhotosLibrary = false
    @State private var photosLibraryMoves = false
    @State private var showMegaImport = false
    @State private var showGoogleDrive = false
    @State private var showTaylorBrowser = false
    @State private var showAccessKardashian = false
    @State private var showTaylorCrossRef = false
    @State private var showEject = false
    @State private var importing = false
    @State private var editEntry: Entry?
    @State private var studioEntry: Entry?
    @State private var resizeEntry: Entry?
    @State private var aiEditEntry: Entry?
    @State private var audioEntry: Entry?          // a tapped audio file → full-screen player
    @State private var reloading = false           // single-flight guard for reload()
    @State private var reloadPending = false
    @State private var showRotatePreview = false   // bulk photo-rotate preview sheet
    @State private var rotateTargets: [Entry] = []
    @State private var audioExtractSources: [URL] = []   // videos queued for "Extract Audio"
    @State private var audioExtractName = ""
    @State private var showAudioExtractPrompt = false
    @State private var editProcessing = false
    @State private var editProgress: Double = 0
    @State private var editLabel = "Working…"
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
    /// Whether anything on screen actually needs per-file ages right now.
    private var agesNeeded: Bool {
        library.sort.isAge || ageFilter != nil || agesRequested
            || Int(query.trimmingCharacters(in: .whitespaces)) != nil
    }

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
        if library.sort.isAge { return sortByAge(list) }
        if library.sort.isLikes { return sortByLikes(list) }
        if library.sort.isDuration { return sortByDuration(list) }
        return list
    }

    /// Sorts by TikTok like count, most-liked first (folders first; items without a count last).
    private func sortByLikes(_ list: [Entry]) -> [Entry] {
        list.sorted { a, b in
            if a.isFolder != b.isFolder { return a.isFolder }
            let la = library.tiktokLikeCount(for: a.url), lb = library.tiktokLikeCount(for: b.url)
            if let x = la, let y = lb { return x != y ? x > y : a.name.localizedStandardCompare(b.name) == .orderedAscending }
            if la == nil && lb == nil { return a.name.localizedStandardCompare(b.name) == .orderedAscending }
            return la != nil      // items with a like count come first
        }
    }

    /// Sorts by video length (folders first; items without a known duration last). Durations
    /// come from the per-file media specs loaded for this folder.
    private func sortByDuration(_ list: [Entry]) -> [Entry] {
        let ascending = (library.sort == .durationAsc)
        return list.sorted { a, b in
            if a.isFolder != b.isFolder { return a.isFolder }
            let da = fileSpecs[a.url]?.duration ?? 0, db = fileSpecs[b.url]?.duration ?? 0
            if da > 0 && db > 0 { return da != db ? (ascending ? da < db : da > db) : a.name.localizedStandardCompare(b.name) == .orderedAscending }
            if da == 0 && db == 0 { return a.name.localizedStandardCompare(b.name) == .orderedAscending }
            return da > 0         // items with a duration come first
        }
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
            return applyHidden(q.isEmpty ? base : base.filter { matches($0, q) })
        }

        // Favorites / To AI mode: labeled items + folder/photo/video sub-filter.
        if labelMode {
            let base = applyLabelKind(showAIOnly ? aiEntries : favoriteEntries)
            return applyHidden(q.isEmpty ? base : base.filter { matches($0, q) })
        }

        // Age mode: recursive aged media (folder + subfolders) of the chosen age.
        if let ageFilter {
            let base = applyType(agedList.filter { $0.age == ageFilter }.map { $0.entry })
            return applyHidden(q.isEmpty ? base : base.filter { matches($0, q) })
        }

        // Searching: recursive results (current folder + all subfolders).
        if !q.isEmpty {
            var results = applyType(searchResults)
            var existing = Set(results.map { $0.url })
            // Always match this folder's own subfolders by name — the index only knows folders that hold
            // indexed media, so this guarantees folders like "Today's Instagram Stories" are findable.
            let folderHits = entries.filter { $0.isFolder && !existing.contains($0.url) && matches($0, q) }
            results += folderHits
            existing.formUnion(folderHits.map { $0.url })
            // Age search: a numeric query also matches media of that age.
            if let target = Int(q) {
                let aged = applyType(agedList.filter { $0.age == target }.map { $0.entry })
                results += aged.filter { !existing.contains($0.url) }
            }
            return applyHidden(applyEdited(results))
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
        list = applyEdited(list)
        if advancedActive { list = list.filter { passesAdvanced($0) } }
        return applyHidden(list)
    }

    /// Removes hidden folders — and, for recursive result sets (search, labels,
    /// ages), anything inside them — unless "Show Hidden Folders" is on.
    private func applyHidden(_ list: [Entry]) -> [Entry] {
        guard !showHiddenFolders, !library.hiddenFolders.isEmpty else { return list }
        return list.filter { !library.isUnderHiddenFolder($0.url.path) }
    }

    /// Keeps only files produced by the in-app editor (when the "Edited" filter is on).
    private func applyEdited(_ list: [Entry]) -> [Entry] {
        // Keep folders visible so you can still navigate / create folders while the filter is on; only the
        // *media* is narrowed to in-app-edited items. (Hiding folders made "Today's Instagram Stories" and
        // newly-created folders seem to vanish.)
        showEditedOnly ? list.filter { $0.isFolder || library.isEditedInApp($0.url) } : list
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

    /// Search matches filename, caption, an indexed place name, or the AI model/prompt
    /// used to generate the item.
    private func matches(_ entry: Entry, _ q: String) -> Bool {
        if entry.name.lowercased().contains(q)
            || effectiveCaption(for: entry).lowercased().contains(q)
            || (MetadataLoader.placeTextCached(for: entry)?.contains(q) ?? false) { return true }
        if let ai = library.aiGeneration(for: entry.url) {
            return ai.model.lowercased().contains(q) || ai.prompt.lowercased().contains(q)
        }
        return false
    }

    private var mediaItems: [Entry] { filtered.filter { $0.isViewable } }

    /// Cheap "does this folder hold any playable media?" for menu enable-state. Using
    /// `mediaItems.isEmpty` here forced the whole `filtered` pipeline (search, place-name
    /// lookups, resolution specs, sort) to recompute several times the instant the toolbar
    /// menu opened — the 2–3s stall before it became scrollable. This short-circuits over
    /// the raw entries with no filtering.
    private var hasViewableMedia: Bool { entries.contains { $0.isViewable } }

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

    /// What the clean-up button should do for this folder, given its current items. Scans
    /// `entries` directly (no sort) — `cleanupItems` sorts every viewable item with a slow
    /// locale-aware compare, and running that just to build the toolbar menu's label was the
    /// ~1s stall when opening the “…” menu in a large folder.
    private var cleanupAction: CleanupAction {
        // Evaluated whenever the toolbar's "…" menu builds, so the common no-history case must
        // stay a bare dictionary lookup — no Set of (possibly thousands of) reviewed paths.
        guard let reviewedList = library.cleanupReviewed[url.path], !reviewedList.isEmpty else { return .start }
        let reviewed = Set(reviewedList)
        return entries.contains { $0.isViewable && !reviewed.contains($0.url.path) } ? .resume : .rerun
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
            .refreshable { await reload() }      // pull down to force a fresh disk re-listing
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
                  coverURL: entry.isFolder ? library.coverURL(for: entry.url) : nil,
                  thumbnailOverrideURL: entry.isFolder ? nil : library.itemThumbnailURL(for: entry.url),
                  likeCount: entry.kind == .video ? library.tiktokLikeCount(for: entry.url) : nil)
            // A revealed hidden folder reads as hidden (dimmed) so it isn't mistaken
            // for a normal one; invisible entirely unless Show Hidden Folders is on.
            .opacity(entry.isFolder && library.isHiddenFolder(entry.url) ? 0.45 : 1)
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
            // Auto-thumbnail: a cover-less folder gets a random photo from inside it the first
            // time its cell appears, so the grid fills in as you browse.
            .task(id: entry.url) {
                if entry.isFolder, library.coverURL(for: entry.url) == nil {
                    await library.ensureRandomCover(for: entry.url)
                }
            }
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
            // Hide = out of sight (tile, bubble, search), nothing touched on the drive.
            Button {
                library.setFolderHidden(!library.isHiddenFolder(entry.url), for: entry.url)
            } label: {
                library.isHiddenFolder(entry.url)
                    ? Label("Unhide Folder", systemImage: "eye")
                    : Label("Hide Folder", systemImage: "eye.slash")
            }
            Button { birthdayFolderItem = PreviewItem(url: entry.url) } label: {
                Label(library.birthday(for: entry.url) != nil ? "Edit Birthday" : "Add Birthday",
                      systemImage: "birthday.cake")
            }
            Button { renameTarget = entry; renameDraft = entry.name } label: {
                Label("Rename", systemImage: "pencil")
            }
            if library.isInstagramFolder(entry.url), let cover = library.coverURL(for: entry.url) {
                Button { profilePhotoItem = PreviewItem(url: cover) } label: {
                    Label("View Profile Photo", systemImage: "person.crop.circle")
                }
            }
            if !library.isInstagramFolder(entry.url) && !library.isInstagramHighlight(entry.url) {
                Button { makeAlbumHighlight(entry) } label: {
                    Label(library.isAlbumHighlight(entry.url) ? "Remove from Highlights" : "Turn into Album Highlight",
                          systemImage: library.isAlbumHighlight(entry.url) ? "circle.badge.minus" : "circle.dashed.inset.filled")
                }
            }
            Button { compress([entry]) } label: {
                Label("Compress to Zip", systemImage: "archivebox")
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
                    Button { studioEntry = entry } label: {
                        Label("Edit Photo", systemImage: "slider.horizontal.3")
                    }
                    Button { resizeEntry = entry } label: {
                        Label("Resize / Extend", systemImage: "aspectratio")
                    }
                    Button { aiEditEntry = entry } label: {
                        Label("Edit with AI", systemImage: "wand.and.stars")
                    }
                    Button { aiUpscale(entry) } label: {
                        Label("AI Upscale", systemImage: "wand.and.rays")
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
            if entry.kind == .audio {
                Button { audioEntry = entry } label: {
                    Label("Play", systemImage: "play.circle")
                }
                Button { infoEntry = entry } label: {
                    Label("Get Info", systemImage: "info.circle")
                }
                Button { startSingleMove(entry) } label: {
                    Label("Move", systemImage: "folder")
                }
                Button { startSingleCopy(entry) } label: {
                    Label("Copy to Folder…", systemImage: "doc.on.doc")
                }
            }
            if entry.kind == .video {
                Menu {
                    Button { aiUpscaleVideo(entry, to: 1080, label: "1080p") } label: { Text("1080p") }
                    Button { aiUpscaleVideo(entry, to: 2160, label: "4K") } label: { Text("4K") }
                } label: {
                    Label("AI Upscale", systemImage: "wand.and.rays")
                }
                Button {
                    let e = entry
                    DispatchQueue.main.async { exportTarget = e }   // defer so the menu dismissal doesn't swallow the sheet
                } label: {
                    Label("Export all frames", systemImage: "square.stack.3d.down.right")
                }
                Button { startAudioExtract([entry]) } label: {
                    Label("Extract Audio…", systemImage: "waveform")
                }
            }
            // File utilities for every file, including non-viewable ones (e.g. a downloaded .zip).
            // Offer Extract for a .zip, or any extension-less "data" file (a zip saved without a
            // suffix) — the extractor validates the contents and reports cleanly if it isn't one.
            if ["zip", ""].contains(entry.url.pathExtension.lowercased()) {
                Button { extractZip(entry) } label: {
                    Label("Extract Here", systemImage: "tray.and.arrow.up")
                }
            }
            Button { compress([entry]) } label: {
                Label("Compress to Zip", systemImage: "archivebox")
            }
            Button(role: .destructive) { startSingleDelete(entry) } label: {
                Label("Delete", systemImage: "trash")
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
        // The presentation chain (≈35 sheets/covers/alerts + ≈10 overlays) nested
        // `ModifiedContent` so deep the runtime overflowed the stack computing the
        // type metadata. Applying it in AnyView-separated chunks caps the depth.
        let g1 = AnyView(content
            .fileImporter(isPresented: $showFolderPicker,
                          allowedContentTypes: [.folder],
                          allowsMultipleSelection: false) { result in
                let purpose = folderPurpose
                guard case .success(let urls) = result, let picked = urls.first else { return }
                // Defer so the document picker fully dismisses before we present the
                // confirmation / start work (otherwise it gets swallowed mid-dismiss).
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                    switch purpose {
                    case .open:           library.chooseFolder(picked)
                    case .transfer:       transferItem = PreviewItem(url: picked)
                    case .relink:         performRelink(oldRoot: picked)
                    case .backupMetadata: performBackupCopy(newRoot: picked)
                    }
                }
            }
            .sheet(item: $previewItem) { item in
                QuickLookPreview(url: item.url).ignoresSafeArea()
            }
            .sheet(item: $moveConflict) { c in
                MoveConflictView(dest: c.dest, items: c.items, verb: c.isCopy ? "Copy" : "Move",
                                 onConfirm: { keep in c.isCopy ? finishCopy(to: c.dest, keepConflicts: keep)
                                                               : finishMove(to: c.dest, keepConflicts: keep) })
            }
            .fullScreenCover(item: $viewerPresentation, onDismiss: {
                // A jump requested from inside the viewer (e.g. "Open Stories") lands here once
                // the cover is fully gone. Defer to the next runloop tick — changing the
                // navigation path *during* the cover's dismissal gets swallowed.
                if let target = library.pendingFolderNavigation {
                    library.pendingFolderNavigation = nil
                    DispatchQueue.main.async { library.path = [target] }
                }
            }) { p in
                ViewerView(items: p.items, startIndex: p.startIndex, slideshow: p.slideshow)
            }
            .sheet(isPresented: $showExporter) {
                FilesExporter(urls: exportURLs) { showExporter = false }
            }
            .sheet(isPresented: $showMovePicker) {
                FolderPicker(root: library.rootURL ?? url, startAt: library.lastTransferDestination) { dest in performMove(to: dest) }
            }
            .sheet(isPresented: $showCopyPicker) {
                FolderPicker(root: library.rootURL ?? url, confirmTitle: "Copy Here", startAt: library.lastTransferDestination) { dest in performCopy(to: dest) }
            }
        )
        let g2 = AnyView(g1
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
            .alert("Move to New Folder", isPresented: $showMoveToNewFolder) {
                TextField("Folder name", text: $moveNewFolderName)
                Button("Move") { moveToNewFolder() }
                Button("Cancel", role: .cancel) { moveNewFolderName = "" }
            } message: {
                Text("Creates a folder here and moves the selected items into it.")
            }
            .alert("Extract Audio", isPresented: $showAudioExtractPrompt) {
                TextField("MP3 name", text: $audioExtractName)
                Button("Extract") { runAudioExtract() }
                Button("Cancel", role: .cancel) { audioExtractSources = [] }
            } message: {
                Text(audioExtractSources.count > 1
                     ? "Audio from \(audioExtractSources.count) videos will be stitched into one file (saved as .m4a — iOS can't write true MP3)."
                     : "The audio will be saved as an .m4a file (iOS can't write true MP3).")
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
            .sheet(item: $exportTarget) { e in
                ExportFramesSheet(entry: e) { name, fps in library.startFrameExport(of: e, name: name, fps: fps) }
            }
            .alert("Rename Folder",
                   isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
                TextField("Name", text: $renameDraft)
                Button("Rename") { performRename() }
                Button("Cancel", role: .cancel) { renameTarget = nil }
            }
            .confirmationDialog("“\(pendingArchive?.name ?? "")”",
                                isPresented: Binding(get: { pendingArchive != nil }, set: { if !$0 { pendingArchive = nil } }),
                                titleVisibility: .visible, presenting: pendingArchive) { archive in
                Button("Extract Here") { extractZip(archive) }
                Button("Quick Look") { previewItem = PreviewItem(url: archive.url) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in Text("Unzip this archive into a new folder here?") }
        )
        let g3 = AnyView(g2
            .sheet(item: $infoEntry) { e in InfoPanel(entry: e) }
            .sheet(item: $folderInfoItem) { item in FolderInfoView(folder: item.url) }
            .sheet(item: $birthdayFolderItem) { item in
                BirthdayEditorView(folder: item.url, existing: library.birthday(for: item.url))
            }
            .sheet(isPresented: $showMetadataEditor) {
                if !metadataTargets.isEmpty { MetadataEditorView(urls: metadataTargets) }
            }
            .sheet(isPresented: $showPhotosPicker) {
                PhotosImportPicker { results in handlePhotosImport(results) }
                    .ignoresSafeArea()
            }
            .fullScreenCover(item: $editEntry) { e in MediaEditorView(entry: e) }
            .fullScreenCover(item: $audioEntry) { e in
                AudioPlayerView(entry: e, onDismiss: { audioEntry = nil })
            }
            .sheet(isPresented: $showRotatePreview) {
                RotatePreviewView(entries: rotateTargets) { quarters in
                    bulkRotateImages(rotateTargets, quarters: quarters)
                }
            }
            .fullScreenCover(item: $studioEntry) { e in PhotoEditorView(entry: e) }
            .fullScreenCover(item: $resizeEntry) { e in ResizeEditorView(entry: e) }
            .sheet(item: $aiEditEntry) { e in AIEditView(entry: e) }
            .fullScreenCover(isPresented: $showPeople) { PeopleView(folder: url) }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showEject) { EjectDriveView(root: library.rootURL) }
        )
        let g4 = AnyView(g3
            .fullScreenCover(isPresented: $showPhotosLibrary) {
                PhotosLibraryView(targetFolder: url, deleteOriginals: photosLibraryMoves)
            }
            .fullScreenCover(isPresented: $showTaylorBrowser) {
                TaylorBrowserView(targetFolder: url) { Task { await reload() } }
            }
            .fullScreenCover(isPresented: $showAccessKardashian) {
                AccessKardashianView(targetFolder: url)   // runs app-wide; contentDidChange refreshes the folder
            }
            .fullScreenCover(isPresented: $showTaylorCrossRef) {
                TaylorCrossReferenceView(folder: url) { Task { await reload() } }
            }
            .fullScreenCover(isPresented: $showMegaImport) {
                MegaImportView(targetFolder: url) { Task { await reload() } }
            }
            .fullScreenCover(isPresented: $showGoogleDrive) {
                GoogleDriveBrowserView(targetFolder: url)
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
            .fullScreenCover(isPresented: $showAllStories, onDismiss: { Task { await reload() } }) {
                AllStoriesView(root: library.rootURL ?? url) { Task { await reload() } }
            }
            .fullScreenCover(isPresented: $showBulkInstagram, onDismiss: { Task { await reload() } }) {
                BulkInstagramView(root: library.rootURL ?? url) { Task { await reload() } }
            }
            .fullScreenCover(item: $profilePhotoItem) { item in
                ProfilePhotoView(url: item.url) { profilePhotoItem = nil }
            }
            .fullScreenCover(isPresented: $showFacebook, onDismiss: { Task { await reload() } }) {
                FacebookImportView(targetFolder: url, existing: library.facebookInfo(for: url)) { Task { await reload() } }
            }
            .fullScreenCover(isPresented: $showOF, onDismiss: { Task { await reload() } }) {
                OFImportView(targetFolder: url, existing: library.ofInfo(for: url)) { Task { await reload() } }
            }
            .sheet(isPresented: $showLinkDownload, onDismiss: { Task { await reload() } }) {
                LinkImportView(targetFolder: url) { Task { await reload() } }
            }
            .fullScreenCover(isPresented: $showTikTok, onDismiss: { Task { await reload() } }) {
                TikTokImportView(targetFolder: url) { Task { await reload() } }
            }
            .sheet(isPresented: $showYouTube, onDismiss: { Task { await reload() } }) {
                YouTubeImportView(targetFolder: url) { Task { await reload() } }
            }
            .sheet(isPresented: $showVSCO, onDismiss: { Task { await reload() } }) {
                VSCOImportView(targetFolder: url) { Task { await reload() } }
            }
            .fullScreenCover(isPresented: $showWebBrowser, onDismiss: { Task { await reload() } }) {
                WebBrowserView(targetFolder: url)
            }
        )
        return AnyView(g4
            .overlay(alignment: .bottom) { if selecting { selectionBar } }
            .overlay { if editProcessing { editingOverlay } }
            .overlay { if makingLive { makingLiveOverlay } }
            .overlay { if importing { importingOverlay } }
            .overlay { if fixingDates { fixingOverlay } }
            .overlay { if indexingText { textIndexOverlay } }
            .overlay { if indexingPlaces { placeIndexOverlay } }
            .overlay { if checkingPhone { phoneCheckOverlay } }
            .overlay { emptyOverlay }
            .fullScreenCover(item: $transferItem) { item in
                DriveTransferView(source: item.url, destination: url)
            }
        )
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

    /// Duplicates ALL metadata under this folder (favorites, labels, captions,
    /// covers, birthdays, People, profile records, cached dates/specs/OCR) onto its
    /// copy on a backup drive — pick the backup's copy of *this* folder. Originals
    /// stay untouched; this drive remains the primary.
    private func performBackupCopy(newRoot: URL) {
        let n = library.duplicateMetadata(from: url, to: newRoot)
        resultMessage = n > 0
            ? "Copied \(n) metadata entr\(n == 1 ? "y" : "ies") — favorites, labels, captions, covers, birthdays, People and profile records — onto “\(newRoot.lastPathComponent)”."
            : "Nothing to copy — no metadata found under “\(url.lastPathComponent)”, or the same folder was picked."
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
            Text(editLabel).font(.subheadline.weight(.medium))
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

    @ViewBuilder private var placeIndexOverlay: some View {
        VStack(spacing: 12) {
            Text(placeIndexProgress < 0.5 ? "Reading photo locations…" : "Naming places…")
                .font(.subheadline.weight(.medium))
            ProgressView(value: placeIndexProgress).progressViewStyle(.linear).frame(width: 220)
            Text("\(Int(placeIndexProgress * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Text("Afterwards, search also finds photos by where they were taken.")
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

    /// Scans photo GPS + names each distinct place under this folder so search can
    /// match locations ("paris", "brooklyn", …). Geocoding is rate-limited and
    /// capped per run — re-run to continue naming a very travelled library.
    private func runLocationIndex() {
        indexingPlaces = true; placeIndexProgress = 0
        let bg = BackgroundTaskHolder()
        bg.begin(name: "Index Locations")
        Task {
            let (photos, places) = await library.buildLocationIndex(under: url) { p in
                Task { @MainActor in placeIndexProgress = p }
            }
            indexingPlaces = false
            bg.end()
            resultMessage = photos == 0 ? "No photos here to scan."
                : places == 0 ? "Scanned \(photos) photo(s) — no new places to name. Search matches the already-indexed locations."
                : "Scanned \(photos) photo(s) and named \(places) place(s). Search now finds photos by location."
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
            library.contentDidChange(under: url)
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
        // Built in AnyView-separated chunks: the modifier chain (background + nav +
        // searchable + toolbar + ~9 tasks) was nesting `ModifiedContent` so deep that
        // the runtime overflowed the stack computing the type's generic metadata
        // (EXC_BAD_ACCESS in content.getter). Type-erasing between groups caps the depth.
        let core = AnyView(
            VStack(spacing: 0) {
                header
                if showBubbles {
                    // Highlights that are album folders (Home, and album-highlight folders
                    // like HD/ and Hilary Duff/) wrap into rows, A–Z, so they're all visible
                    // at once. Social-profile folders (Instagram/Facebook/TikTok/OF)
                    // keep the horizontal scroller with the user's drag-arranged order.
                    if wrapsBubbles {
                        if isRoot { albumHighlightGrid } else { largeHighlightGrid }
                    } else {
                        instagramBubbleRow
                    }
                }
                if !entries.isEmpty { filterBar }
                grid
            }
            .background(AppGradient())
            // Browser downloads keep running after the browser is dismissed — surface them here
            // (the chip observes WebController itself, so this heavy body never re-renders on
            // download progress) with a one-tap way back into the browser.
            .overlay(alignment: .bottomTrailing) {
                WebDownloadsChip { showWebBrowser = true }
                    .padding(.trailing, 16).padding(.bottom, 28)
            }
        )
        let chrome = AnyView(core
            .navigationTitle(isRoot ? "Home" : url.lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Search folder + subfolders")
            .toolbar { toolbar }
        )
        let loaders = AnyView(chrome
            .task(id: library.sort) { await resort() }
            .onChange(of: library.changeToken) { Task { await reload() } }
            // Re-list on return to foreground, so folders created/changed while the app was backgrounded
            // (e.g. a stories run finishing, or a change made in the Files app) show up.
            .onChange(of: scenePhase) { if scenePhase == .active { Task { await reload() } } }
            .task(id: "search-\(query)-\(library.sort.rawValue)-\(library.index.count)") { await runSearch() }
            // Embedded captions are only needed to match a search; load them lazily so a
            // plain folder open doesn't read every file on the drive.
            .task(id: "filecaps-\(query.trimmingCharacters(in: .whitespaces).isEmpty)-\(entries.count)") {
                if query.trimmingCharacters(in: .whitespaces).isEmpty { fileCaptions = [:] }
                else if fileCaptions.isEmpty { fileCaptions = await library.fileCaptions(for: entries) }
            }
            .task(id: "labels-\(showFavoritesOnly)-\(showAIOnly)-\(library.labelsVersion)-\(library.sort.rawValue)") {
                // Favorites / To AI are scoped to *this* folder (and its subfolders).
                if showFavoritesOnly {
                    favoriteEntries = await library.labeledEntries(under: url, paths: library.favorites, sort: library.sort)
                }
                if showAIOnly {
                    aiEntries = await library.labeledEntries(under: url, paths: library.aiLabels, sort: library.sort)
                }
            }
        )
        return AnyView(loaders
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
            // Load dimensions/HDR/duration when the resolution filter is on or sorting by length.
            .task(id: "specs-\(advancedActive)-\(library.sort.isDuration)-\(entries.count)-\(url.path)") {
                if (advancedActive || library.sort.isDuration), fileSpecs.isEmpty {
                    fileSpecs = await library.mediaSpecs(for: entries)
                }
            }
            // Compute ages (folder + subfolders) only when actually engaged — an age
            // sort/filter, a numeric (age) search, or the Age menu being opened. The
            // pass is a recursive walk + EXIF read of the whole subtree, far too heavy
            // to run just because a folder sits somewhere under a birthday folder.
            .task(id: "ages-\(library.changeToken)-\(url.path)-\(agesNeeded)") {
                guard agesNeeded else { return }
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
        )
    }


    @ViewBuilder private var emptyOverlay: some View {
        if filtered.isEmpty {
            VStack(spacing: 8) {
                if loadingAges && (ageFilter != nil || Int(query.trimmingCharacters(in: .whitespaces)) != nil) {
                    // Only block on ages for an actual age filter / numeric (age) query — a text search must
                    // not get stuck behind the age computation.
                    ProgressView()
                    Text("Calculating ages…").foregroundStyle(.secondary)
                } else if searching {
                    ProgressView()
                    Text("Searching…").foregroundStyle(.secondary)
                } else if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                    Image(systemName: "magnifyingglass").font(.largeTitle).foregroundStyle(.secondary)
                    Text("No results").foregroundStyle(.secondary)
                } else if loaded {
                    // A folder presented as album-highlight bubbles isn't "empty" — the albums
                    // ARE its content — so no empty-state text or actions (they collided with
                    // the bubble grid).
                    if !showBubbles {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.largeTitle).foregroundStyle(.secondary)
                        Text(tsNoLabel ? "Everything here is labeled"
                             : tsLabelMode ? "No items match these labels"
                             : showFavoritesOnly ? "No favorites here yet"
                             : showAIOnly ? "Nothing marked To AI yet"
                             : advancedActive ? "No matches for this filter"
                             : "This folder is empty")
                            .foregroundStyle(.secondary)
                        // A genuinely empty folder (no filter hiding things) gets the two ways to
                        // fill it, instead of a dead end.
                        if !tsNoLabel && !tsLabelMode && !showFavoritesOnly && !showAIOnly && !showEditedOnly
                            && !advancedActive && yearFilter == nil && typeFilter == .all && ageFilter == nil {
                            HStack(spacing: 12) {
                                Button { showPhotosPicker = true } label: {
                                    Label("Add from Photos", systemImage: "photo.badge.plus")
                                }
                                .buttonStyle(.bordered)
                                Button { showWebBrowser = true } label: {
                                    Label("Web Browser", systemImage: "safari")
                                }
                                .buttonStyle(.bordered)
                            }
                            .padding(.top, 6)
                        }
                    }
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
    /// Folders shown as circular bubbles: Instagram profiles/highlights, Facebook
    /// profiles, and any folder turned into an "album highlight".
    private func isBubbleFolder(_ url: URL) -> Bool {
        library.isInstagramFolder(url) || library.isInstagramHighlight(url)
            || library.isAlbumHighlight(url) || library.isFacebookFolder(url)
            || library.isTikTokFolder(url) || library.isOFFolder(url)
    }
    /// Pin rank: a profile's "Stories" highlight first, then the Instagram profile, the
    /// Facebook profile, the TikTok profile, the OF creator, and everything else after.
    private func bubbleRank(_ url: URL) -> Int {
        if library.isInstagramHighlight(url) && url.lastPathComponent == "Stories" { return -1 }
        if library.isInstagramFolder(url) { return 0 }
        if library.isFacebookFolder(url) { return 1 }
        if library.isTikTokFolder(url) { return 2 }
        if library.isOFFolder(url) { return 3 }
        return 4
    }
    private var igBubbles: [Entry] {
        let order = library.bubbleOrder(for: url)
        return entries.filter { $0.isFolder && isBubbleFolder($0.url)
                && (showHiddenFolders || !library.isHiddenFolder($0.url)) }
            .sorted { a, b in
                let ra = bubbleRank(a.url), rb = bubbleRank(b.url)
                if ra != rb { return ra < rb }     // Instagram, then Facebook, pinned
                // Then the user's chosen order (drag to rearrange); unordered ones last, A–Z.
                let ia = order.firstIndex(of: a.url.path) ?? Int.max
                let ib = order.firstIndex(of: b.url.path) ?? Int.max
                if ia != ib { return ia < ib }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
    }
    private var showBubbles: Bool {
        query.trimmingCharacters(in: .whitespaces).isEmpty && !labelMode && !tsLabelMode && ageFilter == nil && !igBubbles.isEmpty
    }
    /// Whether this folder's highlights should wrap into a grid rather than sit in the
    /// horizontal scroller. Only the Home page and the two folders the user asked for — HD/
    /// and Hilary Duff/ — wrap; every other folder keeps the drag-arrangeable row it had.
    private var wrapsBubbles: Bool {
        if isRoot { return true }
        let name = url.lastPathComponent.lowercased()
        return name == "hd" || name == "hilary duff"
    }

    private var instagramBubbleRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(bubbleItems.isEmpty ? igBubbles : bubbleItems) { entry in
                    bubbleCell(entry)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
        // Keep the live drag list in sync with the persisted order (and any
        // added/removed bubbles), except mid-drag.
        .task(id: igBubbles.map(\.url)) { bubbleItems = igBubbles }
    }

    /// Home-page highlights: sorted A–Z by album name (the Home page ignores the
    /// drag-arranged order the horizontal scroller uses elsewhere).
    private var homeBubbles: [Entry] {
        igBubbles.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The Home-only highlights layout: a wrapping grid, max 5 per line, so every album
    /// highlight is visible without scrolling. Bubbles are a touch smaller so five fit a
    /// phone's width, and they aren't drag-reorderable here (the order is alphabetical).
    private var albumHighlightGrid: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 4, alignment: .top), count: 5)
        return LazyVGrid(columns: columns, spacing: 12) {
            ForEach(homeBubbles) { entry in
                bubbleCell(entry, diameter: 62, draggable: false)   // 10% larger than the initial 56
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
    }

    /// Album-highlight *folders* (e.g. HD/, Hilary Duff/): the same wrapping A–Z layout as
    /// Home, but with larger bubbles and an adaptive column count so the highlights read big
    /// on a phone (≈4 across) and fill the width on iPad. Not drag-reorderable (order is A–Z).
    ///
    /// Wrapped in a height-bounded `ScrollView` on purpose: these folders can hold hundreds of
    /// album highlights, and a bare `LazyVGrid` in this fixed (non-scrolling) region above the
    /// photo grid isn't actually lazy — it realizes *every* bubble at once, each kicking off a
    /// cover scan (`ensureRandomCover`). That storm of eager cells + I/O is what crashed the app
    /// after browsing into such a folder. Inside a scroll view the grid is truly lazy (only the
    /// visible rows realize), so a big folder stays cheap while still wrapping and scrolling.
    private var largeHighlightGrid: some View {
        let columns = [GridItem(.adaptive(minimum: 86), spacing: 4, alignment: .top)]
        return ScrollView(.vertical, showsIndicators: true) {
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(homeBubbles) { entry in
                    bubbleCell(entry, diameter: 78, draggable: false)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
        }
        .frame(maxHeight: 320)   // a few rows visible; scroll for the rest, keeping the photo grid on screen
    }

    /// One highlight bubble. Long-press initiates a drag to rearrange (the Instagram
    /// bubble is pinned first, so it isn't draggable and can't be displaced).
    @ViewBuilder private func bubbleCell(_ entry: Entry, diameter: CGFloat = 72, draggable: Bool = true) -> some View {
        let button = Button { tap(entry) } label: { bubble(entry, diameter: diameter) }      // select-aware (toggle vs open)
            .buttonStyle(.plain)
            .contextMenu { if !selecting { contextMenu(for: entry) } }
            // Fill a missing bubble thumbnail (e.g. a highlight/Stories folder) from a random
            // item inside it. ensureRandomCover skips IG/TikTok profile folders (they use the avatar).
            .task(id: entry.url) {
                if library.coverURL(for: entry.url) == nil { await library.ensureRandomCover(for: entry.url) }
            }
        if !draggable || selecting || isPinnedBubble(entry.url) {
            button                                              // Home grid (A–Z), Stories, Instagram + Facebook are pinned
        } else {
            button
                .opacity(draggingBubble == entry ? 0.4 : 1)
                .onDrag { draggingBubble = entry; return NSItemProvider(object: entry.url.path as NSString) }
                .onDrop(of: [UTType.text], delegate: BubbleDropDelegate(
                    item: entry, items: $bubbleItems, dragging: $draggingBubble,
                    isPinned: { isPinnedBubble($0) },
                    onReorder: { library.setBubbleOrder($0.map { $0.url.path }, for: url) }))
        }
    }

    /// Bubbles that stay fixed (not drag-rearrangeable): a profile's "Stories" highlight,
    /// the Instagram profile, and the Facebook profile.
    private func isPinnedBubble(_ url: URL) -> Bool {
        (library.isInstagramHighlight(url) && url.lastPathComponent == "Stories")
            || library.isInstagramFolder(url) || library.isFacebookFolder(url)
            || library.isTikTokFolder(url) || library.isOFFolder(url)
    }

    private func bubble(_ entry: Entry, diameter: CGFloat = 72) -> some View {
        let isSel = selection.contains(entry.url)
        let inner = diameter - 10
        let badgeOffset = diameter / 2 - 14
        return VStack(spacing: 5) {
            ZStack {
                Circle()
                    .strokeBorder(bubbleRing(entry.url), lineWidth: 2.5)
                    .frame(width: diameter, height: diameter)
                bubbleImage(entry).frame(width: inner, height: inner).clipShape(Circle())
                    .overlay { if selecting && !isSel { Circle().fill(.black.opacity(0.4)) } }
                if selecting {
                    Image(systemName: isSel ? "checkmark.circle.fill" : "circle")
                        .font(.body).foregroundStyle(isSel ? Color.accentColor : .white)
                        .background(Circle().fill(.black.opacity(0.4)))
                        .offset(x: badgeOffset, y: badgeOffset)
                }
            }
            Text(bubbleLabel(entry))
                .font(.caption2).lineLimit(1).frame(maxWidth: diameter + 4)
        }
    }

    private func bubbleLabel(_ entry: Entry) -> String {
        if let ig = library.instagramInfo(for: entry.url) { return "@\(ig.handle)" }
        if let fb = library.facebookInfo(for: entry.url) { return fb.profileName }
        if let tt = library.tiktokInfo(for: entry.url) { return "@\(tt.handle)" }
        if let of = library.ofInfo(for: entry.url) { return "@\(of.username)" }
        return entry.name
    }

    /// The bubble ring: a blue gradient for a Facebook profile, the Instagram-style
    /// warm gradient otherwise.
    /// Ring color by source: Facebook blue, TikTok cyan→red, else the Instagram gradient.
    private func bubbleRing(_ url: URL) -> AnyShapeStyle {
        if library.isFacebookFolder(url) {
            return AnyShapeStyle(LinearGradient(colors: [Color(red: 0.10, green: 0.46, blue: 0.91),
                                                         Color(red: 0.30, green: 0.62, blue: 0.99)],
                                                startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        if library.isTikTokFolder(url) {
            return AnyShapeStyle(LinearGradient(colors: [Color(red: 0.14, green: 0.96, blue: 0.93),   // #25F4EE
                                                         Color(red: 0.99, green: 0.17, blue: 0.33)],  // #FE2C55
                                                startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        if library.isOFFolder(url) {
            return AnyShapeStyle(LinearGradient(colors: [Color(red: 0.00, green: 0.69, blue: 0.94),   // #00AFF0
                                                         Color(red: 0.00, green: 0.83, blue: 1.00)],
                                                startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        return AnyShapeStyle(LinearGradient(colors: [Color(red: 0.99, green: 0.6, blue: 0.11),
                                                     Color(red: 0.95, green: 0.27, blue: 0.42),
                                                     Color(red: 0.56, green: 0.23, blue: 0.83)],
                                            startPoint: .topLeading, endPoint: .bottomTrailing))
    }

    @ViewBuilder private func bubbleImage(_ entry: Entry) -> some View {
        BubbleCover(coverURL: library.coverURL(for: entry.url))
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
        if showEditedOnly { return "Edited" }
        if let ig = library.instagramInfo(for: url) {
            let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
            let when = f.string(from: Date(timeIntervalSince1970: ig.lastUpdated))
            return "Last Updated on \(when) · \(ig.photos) Photos and \(ig.videos) Videos"
        }
        if let fb = library.facebookInfo(for: url) {
            let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
            let when = f.string(from: Date(timeIntervalSince1970: fb.lastUpdated))
            return "Last Updated on \(when) · \(fb.photos) Photos and \(fb.videos) Videos"
        }
        if let of = library.ofInfo(for: url) {
            let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
            let when = f.string(from: Date(timeIntervalSince1970: of.lastUpdated))
            return "Last Updated on \(when) · \(of.photos) Photos and \(of.videos) Videos"
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
                    if showFavoritesOnly { showAIOnly = false; showEditedOnly = false; tsLabelFilter.removeAll(); tsNoLabel = false }
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
                    if showAIOnly { showFavoritesOnly = false; showEditedOnly = false; tsLabelFilter.removeAll(); tsNoLabel = false }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                        Text("To AI").font(.subheadline.weight(.medium))
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.thinMaterial, in: Capsule())
                    .foregroundStyle(showAIOnly ? Color.yellow : Color.primary)
                }

                Button {
                    showEditedOnly.toggle()
                    if showEditedOnly {
                        showFavoritesOnly = false; showAIOnly = false
                        tsLabelFilter.removeAll(); tsNoLabel = false; ageFilter = nil
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "wand.and.stars")
                        Text("Edited").font(.subheadline.weight(.medium))
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.thinMaterial, in: Capsule())
                    .foregroundStyle(showEditedOnly ? Color.accentColor : Color.primary)
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
                            // Opening this menu is what triggers the lazy age pass.
                            Button { ageFilter = nil } label: { check("All Ages", ageFilter == nil) }
                                .onAppear { agesRequested = true }
                            if loadingAges && availableAges.isEmpty {
                                Text("Calculating ages…")
                            }
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
                    } label: {
                        chip("Year: \(yearFilter.map(String.init) ?? "All")")
                            .foregroundStyle(yearFilter != nil ? Color.accentColor : Color.primary)
                    }

                    Menu {
                        ForEach(TypeFilter.allCases) { type in
                            Button { typeFilter = type } label: { check(type.rawValue, typeFilter == type) }
                        }
                    } label: {
                        chip("Type: \(typeFilter.rawValue)")
                            .foregroundStyle(typeFilter != .all ? Color.accentColor : Color.primary)
                    }

                    // One tap back to an unfiltered view once any menu-driven filter is active.
                    if yearFilter != nil || typeFilter != .all || ageFilter != nil || advancedActive {
                        Button {
                            yearFilter = nil; typeFilter = .all; ageFilter = nil
                            videoRes = .all; imageRes = .all; hdrOnly = false
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "xmark.circle.fill")
                                Text("Clear").font(.subheadline.weight(.medium))
                            }
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(.thinMaterial, in: Capsule())
                            .foregroundStyle(Color.accentColor)
                        }
                    }
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
                // Always visible so the browser is one tap away, not buried in the "…" menu.
                // The icon is intentionally static: FolderView doesn't observe WebController,
                // so a hasSession-dependent icon would go stale.
                Button { showWebBrowser = true } label: { Image(systemName: "safari") }
                    .accessibilityLabel("Browser")
                if !isRoot {
                    Button { library.goHome() } label: { Image(systemName: "house") }
                }
                if !labelMode {
                    filterMenu
                }
                Menu {
                    ForEach(SortKey.allCases) { key in
                        // Age sorting only where a birthday is in context; "Most liked" only in TikTok folders.
                        if (!key.isAge || library.hasBirthdayContext(url)) && (!key.isLikes || library.isTikTokFolder(url)) {
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
                    // Grouped into titled sections so the ~20 items scan as four short lists
                    // instead of one long one. Sections don't change what builds when the menu
                    // opens — the heavy lists still live in the lazy submenus below.
                    Section("This Folder") {
                        Button { playSlideshow() } label: { Label("Play Slideshow", systemImage: "play.rectangle") }
                            .disabled(!hasViewableMedia)
                        Button { showNewFolder = true } label: { Label("New Folder", systemImage: "folder.badge.plus") }
                        Toggle(isOn: $showHiddenFolders) { Label("Show Hidden Folders", systemImage: "eye.slash") }
                        Button {
                            if case .rerun = cleanupAction { library.resetCleanup(url) }   // fresh pass over what's left
                            showCleanup = true
                        } label: {
                            Label(cleanupAction.title, systemImage: "wand.and.sparkles")
                        }
                        .disabled(!hasViewableMedia)
                        Button {
                            if case .rerun = cleanupAction { library.resetCleanup(url) }   // fresh random pass
                            showRandomCleanup = true
                        } label: {
                            Label("Randomized Clean Up", systemImage: "shuffle")
                        }
                        .disabled(!hasViewableMedia)
                    }
                    Section("Add Media") {
                        Button { photosLibraryMoves = true; showPhotosLibrary = true } label: {
                            Label("Add from iOS Album…", systemImage: "photo.badge.arrow.down")
                        }
                        Button { photosLibraryMoves = false; showPhotosLibrary = true } label: { Label("Photos Library", systemImage: "photo.stack") }
                        // Grouped into a submenu so the parent "…" menu doesn't build all ~16 of these
                        // eagerly on every open (that was the 1–2s stall). SwiftUI builds submenu content
                        // lazily, only when this item is opened.
                        Menu {
                            Button { showMegaImport = true } label: {
                                Label("Add from MEGA…", systemImage: "arrow.down.circle")
                            }
                            Button { showLinkDownload = true } label: {
                                Label("Download from a Link…", systemImage: "link.badge.plus")
                            }
                            Button { showGoogleDrive = true } label: {
                                Label("Download from Google Drive…", systemImage: "arrow.down.doc")
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
                            if isRoot && !library.instagramFolders.isEmpty {
                                Button { showAllStories = true } label: {
                                    Label("Get All New Instagram Stories", systemImage: "sparkles.rectangle.stack")
                                }
                            }
                            if isRoot {
                                Button { showBulkInstagram = true } label: {
                                    Label("Bulk Download Instagram Profiles…", systemImage: "person.3.sequence")
                                }
                            }
                            Button { showFacebook = true } label: {
                                Label(library.isFacebookFolder(url) ? "Get New Facebook Photos" : "Download Facebook Profile…",
                                      systemImage: library.isFacebookFolder(url) ? "arrow.triangle.2.circlepath" : "person.2.fill")
                            }
                            Button { showOF = true } label: {
                                Label(library.isOFFolder(url) ? "Get New OF Posts" : "Download OF Profile…",
                                      systemImage: library.isOFFolder(url) ? "arrow.triangle.2.circlepath" : "lock.circle")
                            }
                            Button { showTikTok = true } label: {
                                Label(library.lastTikTokHandle(for: url) != nil ? "Get New TikTok Videos" : "Download TikTok Profile…",
                                      systemImage: "music.note")
                            }
                            Button { showVSCO = true } label: {
                                Label(library.isVSCOFolder(url) || library.lastVSCOUsername(for: url) != nil
                                      ? "Get New VSCO Photos" : "Download VSCO Profile…",
                                      systemImage: "camera.aperture")
                            }
                            Button { showYouTube = true } label: {
                                Label("Download YouTube Video Here…", systemImage: "play.rectangle.fill")
                            }
                            Button { showWebBrowser = true } label: {
                                Label("Browse the Web & Download Video…", systemImage: "safari")
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
                        } label: {
                            Label("Download from the Web…", systemImage: "arrow.down.circle")
                        }
                    }
                    Section {
                        // A lazy submenu like "Download from the Web…" above: these are rarely
                        // used, and SwiftUI builds a toolbar menu's TOP-LEVEL content eagerly
                        // (every toolbar render + every open) — submenu content only when the
                        // item is opened. Trimming the parent menu is what shrinks the hitch.
                        Menu {
                            Button { pickFolder(.transfer) } label: {
                                Label("Move Here from Another Drive…", systemImage: "externaldrive.badge.minus")
                            }
                            Button { pickFolder(.relink) } label: {
                                Label("Re-link Favorites from a Drive…", systemImage: "link")
                            }
                            Button { pickFolder(.backupMetadata) } label: {
                                Label("Copy Metadata to Backup Drive…", systemImage: "externaldrive.badge.checkmark")
                            }
                            if isRoot {
                                Button { pickFolder(.open) } label: { Label("Open Folder…", systemImage: "externaldrive") }
                                Button { showEject = true } label: {
                                    Label("Prepare Drive for Removal…", systemImage: "eject")
                                }
                            }
                        } label: {
                            Label("Drives & Backup…", systemImage: "externaldrive")
                        }
                    }
                    Section("Library") {
                        Button { showPeople = true } label: { Label("People", systemImage: "person.2.crop.square.stack") }
                        // Less-used maintenance tools stay in a submenu — same reason as above:
                        // keep the parent menu cheap to build so it opens instantly.
                        Menu {
                            if library.thumbnailCacheRunning {
                                Button(role: .destructive) { library.stopThumbnailCaching() } label: {
                                    Label("Stop Caching Process", systemImage: "stop.circle")
                                }
                            } else {
                                Button { library.startThumbnailCaching() } label: {
                                    Label("Cache All Thumbnails", systemImage: "square.grid.3x3.square")
                                }
                            }
                            Button { showDuplicates = true } label: { Label("Find Duplicates", systemImage: "doc.on.doc") }
                            Button { confirmFixDates = true } label: { Label("Restore Capture Dates", systemImage: "clock.arrow.circlepath") }
                            Button { runTextIndex() } label: { Label("Index Text in Photos", systemImage: "text.viewfinder") }
                            Button { runLocationIndex() } label: { Label("Index Locations", systemImage: "location.viewfinder") }
                            Button { confirmPhoneCheck = true } label: { Label("Check if on iPhone", systemImage: "iphone") }
                                .disabled(!hasViewableMedia)
                        } label: {
                            Label("Maintenance…", systemImage: "wrench.and.screwdriver")
                        }
                        Button { showSettings = true } label: { Label("Settings", systemImage: "gearshape") }
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

    // MARK: - Zip / unzip

    /// Zip the given items into a new `.zip` in the current folder — a single item becomes
    /// "<name>.zip", several become "Archive.zip". Contents are copied byte-for-byte, so any
    /// embedded EXIF/metadata is preserved exactly. The originals are left untouched.
    /// Queues one or more videos for audio extraction and prompts for the output name. The
    /// default name is the single video's base name, or "Audio" for a multi-select stitch.
    private func startAudioExtract(_ videos: [Entry]) {
        let sources = videos.filter { $0.kind == .video }.map(\.url)
        guard !sources.isEmpty else { resultMessage = "Select one or more videos to extract audio from."; return }
        audioExtractSources = sources
        audioExtractName = sources.count == 1
            ? sources[0].deletingPathExtension().lastPathComponent
            : "Audio"
        // Defer so the presenting menu / context menu dismissal doesn't swallow the alert (constraint #4).
        DispatchQueue.main.async { showAudioExtractPrompt = true }
    }

    /// Extracts (and, for multiple, stitches) the queued videos' audio into one `.m4a` in this
    /// folder, then shows a transient result. Mirrors `compress`'s background-task pattern.
    private func runAudioExtract() {
        let sources = audioExtractSources
        let name = audioExtractName
        audioExtractSources = []
        guard !sources.isEmpty else { return }
        selecting = false; selection.removeAll()
        let folder = url
        editLabel = "Extracting audio…"; editProcessing = true; editProgress = 0
        let bg = BackgroundTaskHolder(); bg.begin(name: "Extract Audio")
        Task {
            let outcome = await FileActions.extractAudio(from: sources, to: folder, name: name)
            editProgress = 1; editProcessing = false; bg.end()
            if let dest = outcome.url {
                resultMessage = "Saved “\(dest.lastPathComponent)”."
                library.contentDidChange(under: folder)
                await reload()
            } else {
                resultMessage = outcome.error ?? "Couldn’t extract the audio."
            }
        }
    }

    private func compress(_ entries: [Entry]) {
        let items = entries.map(\.url)
        guard !items.isEmpty else { resultMessage = "Select one or more items to compress."; return }
        selecting = false; selection.removeAll()
        let folder = url
        let single = items.count == 1
        let baseName = single ? items[0].deletingPathExtension().lastPathComponent : "Archive"
        editLabel = "Compressing…"; editProcessing = true; editProgress = 0
        let bg = BackgroundTaskHolder(); bg.begin(name: "Compress")
        Task {
            let outcome: (url: URL?, error: String?) = await Task.detached { () -> (URL?, String?) in
                let fm = FileManager.default
                var d = folder.appendingPathComponent("\(baseName).zip")
                var n = 1
                while fm.fileExists(atPath: d.path) { d = folder.appendingPathComponent("\(baseName) \(n).zip"); n += 1 }
                do {
                    if single { try Archiver.zip(items[0], to: d) }
                    else { try Archiver.zip(items: items, to: d, stagingName: baseName) }
                    return (d, nil)
                } catch { return (nil, error.localizedDescription) }
            }.value
            editProgress = 1; editProcessing = false; bg.end()
            if let dest = outcome.url {
                resultMessage = "Created “\(dest.lastPathComponent)”."
                library.contentDidChange(under: folder)
                await reload()
            } else {
                resultMessage = outcome.error ?? "Couldn’t create the zip."
            }
        }
    }

    /// Extract a `.zip` into a new subfolder of the current folder. Files are written verbatim
    /// (EXIF kept) and each gets its archived modification date back.
    private func extractZip(_ entry: Entry) {
        let archive = entry.url
        let folder = url
        let destName = archive.deletingPathExtension().lastPathComponent
        editLabel = "Extracting…"; editProcessing = true; editProgress = 0
        let bg = BackgroundTaskHolder(); bg.begin(name: "Extract Zip")
        Task {
            let outcome: (url: URL?, error: String?) = await Task.detached { () -> (URL?, String?) in
                let fm = FileManager.default
                var d = folder.appendingPathComponent(destName, isDirectory: true)
                var n = 1
                while fm.fileExists(atPath: d.path) { d = folder.appendingPathComponent("\(destName) \(n)", isDirectory: true); n += 1 }
                do {
                    try await Archiver.unzip(archive, to: d) { f in Task { @MainActor in editProgress = f } }
                    return (d, nil)
                } catch {
                    // Failed partway → remove the half-extracted folder so no corrupt partial files
                    // are left cluttering the drive.
                    try? fm.removeItem(at: d)
                    return (nil, error.localizedDescription)
                }
            }.value
            editProgress = 1; editProcessing = false; bg.end()
            if let dest = outcome.url {
                // Extraction fully succeeded → remove the now-redundant archive and drop its labels.
                await Task.detached {
                    try? FileManager.default.removeItem(at: archive)
                    DriveWriter.fullSync(folder)
                }.value
                resultMessage = "Extracted to “\(dest.lastPathComponent)” and removed the .zip."
                library.contentDidChange(under: folder)
                await reload()
            } else {
                resultMessage = outcome.error ?? "Couldn’t extract the archive."
            }
        }
    }

    /// Repair a download that was saved without a file extension (a "data" tile): rename it to the
    /// extension its bytes actually are, re-key its labels/caption to the new path, and reload so it's
    /// recognized (a photo becomes viewable, a PDF opens, etc.).
    private func repairExtension(of entry: Entry, to ext: String) async {
        let dest = entry.url.deletingPathExtension().appendingPathExtension(ext)
        guard dest != entry.url, !FileManager.default.fileExists(atPath: dest.path),
              let newURL = FileActions.rename(entry.url, to: dest.lastPathComponent) else {
            previewItem = PreviewItem(url: entry.url); return
        }
        DriveWriter.fullSyncFileAndParent(newURL)
        library.itemMoved(from: entry.url, to: newURL)
        library.contentDidChange(under: url)
        await reload()
        resultMessage = "“\(entry.name)” was saved without an extension — renamed to .\(ext) so it opens now."
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
                Button { startRotatePhotos() } label: { Label("Rotate… (preview)", systemImage: "crop.rotate") }
                Menu {
                    Button { bulkUpscale(to: 1080, label: "1080p") } label: { Label("1080p", systemImage: "arrow.up.right.video") }
                    Button { bulkUpscale(to: 2160, label: "4K") } label: { Label("4K", systemImage: "arrow.up.right.video") }
                    Divider()
                    Button { bulkEnhance(to: 1080, label: "1080p") } label: { Label("AI Enhance to 1080p", systemImage: "wand.and.stars") }
                } label: { Label("Upscale Video", systemImage: "arrow.up.right.video") }
                if selectedEntries().contains(where: { $0.kind == .video }) {
                    Button { startAudioExtract(selectedEntries()) } label: {
                        Label("Extract Audio…", systemImage: "waveform")
                    }
                }
                Button { duplicateEntries(selectedEntries()) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                Button { compress(selectedEntries()) } label: { Label("Compress to Zip", systemImage: "archivebox") }
                Button { showCopyPicker = true } label: { Label("Copy to Folder…", systemImage: "doc.on.doc") }
                Button {
                    moveNewFolderName = ""
                    // Defer so the Menu's dismissal doesn't swallow the alert (constraint #4).
                    DispatchQueue.main.async { showMoveToNewFolder = true }
                } label: {
                    Label("Move \(selection.count) Item\(selection.count == 1 ? "" : "s") to New Folder…",
                          systemImage: "folder.badge.plus")
                }
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
    /// Collects the selected photos and videos and opens the preview sheet (deferred so presenting
    /// from the More menu isn't swallowed). The plain "Rotate" submenu still offers a quick,
    /// no-preview rotation.
    private func startRotatePhotos() {
        let media = selectedEntries().filter { $0.isViewable && ($0.kind == .image || $0.kind == .video) }
        guard !media.isEmpty else { resultMessage = "Select one or more photos or videos."; return }
        rotateTargets = media
        DispatchQueue.main.async { showRotatePreview = true }
    }

    /// Rotates each selected item the same way, in place — the original file is replaced,
    /// preserving EXIF/GPS/capture date and HDR (photos via `applyPhotoInPlace`, which takes a
    /// 10-bit path for HDR sources; videos via `exportVideoInPlace`, an HDR-aware re-encode).
    /// Runs off-main under a background window; scoped to the set confirmed in the preview sheet.
    private func bulkRotateImages(_ targets: [Entry], quarters: Int) {
        guard !targets.isEmpty else { return }
        selecting = false; selection.removeAll()
        editLabel = "Rotating…"; editProcessing = true; editProgress = 0
        let bg = BackgroundTaskHolder(); bg.begin(name: "Rotate Media")
        Task {
            let full = CGRect(x: 0, y: 0, width: 1, height: 1)
            let n = targets.count
            var failed = 0
            for (i, e) in targets.enumerated() {
                let ok: Bool
                if e.kind == .video {
                    // Videos re-encode with per-frame progress; blend it into the overall bar.
                    ok = await MediaEditing.exportVideoInPlace(url: e.url, quarters: quarters, crop: full) { f in
                        Task { @MainActor in editProgress = (Double(i) + f) / Double(n) }
                    }
                } else {
                    ok = await Task.detached { MediaEditing.applyPhotoInPlace(url: e.url, quarters: quarters, crop: full) }.value
                }
                if !ok { failed += 1 }
                editProgress = Double(i + 1) / Double(n)
            }
            editProcessing = false; bg.end()
            resultMessage = failed == 0
                ? "Rotated \(n) item\(n == 1 ? "" : "s")."
                : "Rotated \(n - failed) of \(n); \(failed) couldn’t be saved."
            library.contentDidChange(under: url)
            await reload()
        }
    }

    private func bulkRotate(_ quarters: Int) {
        let targets = selectedEntries().filter { $0.isViewable }
        guard !targets.isEmpty else { resultMessage = "Select one or more photos or videos."; return }
        selecting = false; selection.removeAll()
        editLabel = "Rotating…"; editProcessing = true; editProgress = 0
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
            library.contentDidChange(under: url)
            await reload()
        }
    }

    /// Upscales the selected videos in place to the target resolution (short side
    /// `target` px: 1080 or 2160), preserving HDR, metadata, labels, and capture
    /// date; originals are replaced. Videos already at/above the target are skipped.
    private func bulkUpscale(to target: CGFloat, label: String) {
        let targets = selectedEntries().filter { $0.kind == .video }
        guard !targets.isEmpty else { resultMessage = "Select one or more videos."; return }
        selecting = false; selection.removeAll()
        editLabel = "Upscaling to \(label)…"; editProcessing = true; editProgress = 0
        let bg = BackgroundTaskHolder(); bg.begin(name: "Upscale Videos")
        Task {
            var upscaled = 0, skipped = 0, failed = 0
            let n = targets.count
            for (i, e) in targets.enumerated() {
                // Real progress: per-video index blended with the export's per-frame fraction.
                switch await MediaEditing.upscaleVideo(url: e.url, targetShort: target, progress: { f in
                    Task { @MainActor in editProgress = (Double(i) + f) / Double(n) }
                }) {
                case .upscaled: upscaled += 1
                case .skipped:  skipped += 1
                case .failed:   failed += 1
                }
                editProgress = Double(i + 1) / Double(n)
            }
            editProcessing = false; bg.end()
            var msg = "Upscaled \(upscaled) video\(upscaled == 1 ? "" : "s") to \(label)."
            if skipped > 0 { msg += " \(skipped) already ≥\(label)." }
            if failed > 0 { msg += " \(failed) couldn’t be processed." }
            resultMessage = msg
            library.contentDidChange(under: url)
            await reload()
        }
    }

    /// Like `bulkUpscale`, but runs each frame through a Core Image enhancement pipeline
    /// (denoise + unsharp detail recovery) as it upscales — sharper, cleaner output than a
    /// plain rescale. SDR only; HDR videos fall back to the standard upscale so they aren't
    /// tone-mapped. Replaces in place, preserving metadata/labels/date.
    private func bulkEnhance(to target: CGFloat, label: String) {
        let targets = selectedEntries().filter { $0.kind == .video }
        guard !targets.isEmpty else { resultMessage = "Select one or more videos."; return }
        selecting = false; selection.removeAll()
        editLabel = "Enhancing to \(label)…"; editProcessing = true; editProgress = 0
        let bg = BackgroundTaskHolder(); bg.begin(name: "Enhance Videos")
        Task {
            var done = 0, skipped = 0, failed = 0
            let n = targets.count
            for (i, e) in targets.enumerated() {
                switch await MediaEditing.enhanceVideo(url: e.url, targetShort: target, progress: { f in
                    Task { @MainActor in editProgress = (Double(i) + f) / Double(n) }
                }) {
                case .upscaled: done += 1
                case .skipped:  skipped += 1
                case .failed:   failed += 1
                }
                editProgress = Double(i + 1) / Double(n)
            }
            editProcessing = false; bg.end()
            var msg = "Enhanced \(done) video\(done == 1 ? "" : "s") to \(label)."
            if skipped > 0 { msg += " \(skipped) already ≥\(label)." }
            if failed > 0 { msg += " \(failed) couldn’t be processed." }
            resultMessage = msg
            library.contentDidChange(under: url)
            await reload()
        }
    }

    /// "AI Upscale" a single photo in place: light denoise + sharpen + a 1.5× resolution bump,
    /// metadata preserved. Shows the shared processing overlay; reloads when done.
    private func aiUpscale(_ entry: Entry) {
        editLabel = "AI Upscaling…"; editProcessing = true; editProgress = 0
        let bg = BackgroundTaskHolder(); bg.begin(name: "AI Upscale")
        Task {
            let ok = await Task.detached(priority: .userInitiated) {
                MediaEditing.enhancePhotoInPlace(url: entry.url, scale: 1.5)
            }.value
            editProgress = 1
            editProcessing = false; bg.end()
            resultMessage = ok ? "Upscaled “\(entry.name)”." : "Couldn’t upscale “\(entry.name)”."
            library.contentDidChange(under: url)
            await reload()
        }
    }

    /// "AI Upscale" a single video from the long-press menu — the HDR-preserving enhance
    /// path (denoise + sharpen while rescaling; HDR videos fall back to a plain rescale so
    /// their transfer isn't tone-mapped). Metadata/labels/date preserved.
    private func aiUpscaleVideo(_ entry: Entry, to target: CGFloat, label: String) {
        editLabel = "AI Upscaling to \(label)…"; editProcessing = true; editProgress = 0
        let bg = BackgroundTaskHolder(); bg.begin(name: "AI Upscale Video")
        Task {
            let outcome = await MediaEditing.enhanceVideo(url: entry.url, targetShort: target, progress: { f in
                Task { @MainActor in editProgress = f }
            })
            editProgress = 1; editProcessing = false; bg.end()
            switch outcome {
            case .upscaled: resultMessage = "Upscaled “\(entry.name)” to \(label)."
            case .skipped:  resultMessage = "“\(entry.name)” is already ≥\(label)."
            case .failed:   resultMessage = "Couldn’t upscale “\(entry.name)”."
            }
            library.contentDidChange(under: url)
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
        else { tsLabelFilter.insert(name); tsNoLabel = false; showFavoritesOnly = false; showAIOnly = false; showEditedOnly = false }
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
        // One mutation + one persist — per-item setLabel re-encoded the whole
        // label store per selected item, which froze the app on big selections.
        library.setLabels(name, on: sel.map(\.url), !allOn)
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
        } else if entry.kind == .audio {
            audioEntry = entry
        } else if entry.url.pathExtension.lowercased() == "zip" {
            pendingArchive = entry                      // a zip → offer to extract (or preview)
        } else if entry.kind == .other {
            // An extension-less "data" tile is usually a download that lost its suffix. Sniff the
            // real type off-main: a zip → offer to extract; a photo/video/pdf → repair the extension
            // so it opens; anything else → Quick Look.
            let e = entry
            Task {
                let ext = await Task.detached(operation: { WebVideoDownloader.magicExtension(forFileAt: e.url) }).value
                if ext == "zip" { pendingArchive = e }
                else if let ext { await repairExtension(of: e, to: ext) }
                else { previewItem = PreviewItem(url: e.url) }
            }
        } else {
            previewItem = PreviewItem(url: entry.url)   // PDFs and other files open in QuickLook
        }
    }

    private func toggleAll() {
        let all = selectableEntries
        if selection.count == all.count { selection.removeAll() }
        else { selection = Set(all.map(\.url)) }
    }

    /// Re-orders the already-loaded entries **in memory** when the sort changes — no
    /// filesystem re-read. Re-reading the directory (via `reload`) on every sort change was
    /// the multi-second lag on large folders. Falls back to a full load when nothing is
    /// loaded yet. Age/likes/duration sorts are applied in `filtered`, so they only need
    /// the re-render this triggers; name/size/kind/smart/date sort the entries here.
    private func resort() async {
        guard loaded, !entries.isEmpty else { await reload(); return }
        entries = Library.sortEntries(entries, by: library.sort)
        // Capture-date sorts refine the modified-date order with real EXIF dates.
        if [SortKey.smart, .dateDesc, .dateAsc].contains(library.sort) {
            if captureDates.isEmpty { captureDates = await library.captureDates(for: entries) }
            entries = sortedByCaptureDate(entries)
        }
    }

    private func reload() async {
        // Single-flight: `changeToken` can churn (e.g. every file a download commits), and this
        // handler spawns an unstructured Task per bump — without a guard the same folder ran
        // overlapping disk re-listings that piled up. Coalesce to one at a time; if more arrive
        // mid-reload, run exactly once more afterward so the final state isn't missed.
        if reloading { reloadPending = true; return }
        reloading = true
        defer {
            reloading = false
            if reloadPending { reloadPending = false; Task { await reload() } }
        }
        // Paint a cached listing instantly so re-opening a folder is snappy; we still
        // re-read from disk below and update if anything changed. On a cold launch any
        // folder falls back to its persisted snapshot so it appears immediately.
        if let cached = library.cachedListing(of: url), !cached.isEmpty {
            entries = cached; liveImageURLs = Self.detectLivePairs(in: cached); loaded = true
        } else if let saved = await library.persistedListing(of: url), !saved.isEmpty {
            // Cold launch: every folder (not just the root) paints its last-known
            // listing instantly; the live re-read below refreshes it.
            entries = saved; liveImageURLs = Self.detectLivePairs(in: saved); loaded = true
        } else {
            loaded = false
        }
        fileSpecs = [:]; folderYears = [:]
        let list = await library.listing(of: url, sort: library.sort)
        if list.isEmpty, !FileManager.default.fileExists(atPath: url.path) {
            // The folder vanished under us — most likely the drive was unplugged (or
            // came back under a new mount path). Let the library re-resolve its
            // bookmark; while the drive is offline keep the last-known tiles instead
            // of blanking the grid.
            library.reconnectIfNeeded()
            if let root = library.rootURL, !FileManager.default.fileExists(atPath: root.path) { return }
        }
        library.cacheListing(list, for: url)
        entries = list
        liveImageURLs = Self.detectLivePairs(in: list)
        loaded = true
        // Warm the whole folder's thumbnails ahead of scroll so tiles pop in instantly.
        Thumbnailer.shared.prefetch(list, size: CGSize(width: 110, height: 110), scale: UIScreen.main.scale)
        // Capture dates are only loaded when the active sort/filters need them; on a
        // slow external drive, reading EXIF from every file otherwise starves the
        // thumbnails of disk bandwidth. Embedded captions load lazily (only while
        // searching). Media specs load on demand (resolution/HDR filter).
        let needsDates = [SortKey.smart, .dateDesc, .dateAsc].contains(library.sort)
            || library.sort.isAge || yearFilter != nil || ageFilter != nil
        if needsDates {
            captureDates = await library.captureDates(for: list)
            // Now that real capture dates are in, re-order so "newest" reflects when
            // media was taken (the file's modified date is just when it was added).
            if library.sort == .smart || library.sort == .dateDesc || library.sort == .dateAsc {
                entries = sortedByCaptureDate(entries)
            }
        } else {
            captureDates = [:]
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
        guard !name.isEmpty else { return }
        guard FileActions.createFolder(named: name, in: url) else {
            // Don't fail silently — tell the user why (usually a name clash or a non-writable drive).
            let id = library.beginActivity("New Folder")
            library.endActivity(id, result: "Couldn't create “\(name)”. A folder with that name may already exist, or the drive isn't writable right now.")
            return
        }
        library.contentDidChange(under: url)                       // refresh this folder's listing
        library.path.append(url.appendingPathComponent(name, isDirectory: true))   // open the new folder
    }

    private func performRename() {
        if let target = renameTarget, let newURL = FileActions.rename(target.url, to: renameDraft) {
            library.itemMoved(from: target.url, to: newURL)   // keep labels/captions attached
        }
        renameTarget = nil
        Task { await reload() }
    }

    /// "Move N Items to New Folder…": create (or reuse) a subfolder of this folder, then send the
    /// selection through the normal move path — labels/captions follow, conflicts surface as usual.
    private func moveToNewFolder() {
        let name = moveNewFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        moveNewFolderName = ""
        guard !name.isEmpty else { return }
        let dest = url.appendingPathComponent(name, isDirectory: true)
        var isDir: ObjCBool = false
        if !(FileManager.default.fileExists(atPath: dest.path, isDirectory: &isDir) && isDir.boolValue) {
            guard FileActions.createFolder(named: name, in: url) else {
                resultMessage = "Couldn’t create “\(name)”. A file with that name may already exist, or the drive isn’t writable right now."
                return
            }
        }
        performMove(to: dest)
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

    /// Completes a move (off the main thread, with a progress bar). `keepConflicts`
    /// are the same-name items the user chose to move (renamed to keep both); any
    /// other conflicting item is left behind. Labels follow in one batched re-key.
    private func finishMove(to dest: URL, keepConflicts: Set<URL>) {
        moveConflict = nil
        let allURLs = selectedEntries().map(\.url)
        let skip = Set(FileActions.collisions(allURLs, in: dest)).subtracting(keepConflicts)
        let moveURLs = allURLs.filter { !skip.contains($0) }
        selection.removeAll(); selecting = false
        guard !moveURLs.isEmpty else { resultMessage = "Nothing to move."; return }
        editLabel = "Moving…"; editProcessing = true; editProgress = 0
        let bg = BackgroundTaskHolder(); bg.begin(name: "Move Items")
        Task {
            let outcome = await FileActions.moveItems(moveURLs, to: dest, renameOnCollision: true) { p in
                Task { @MainActor in editProgress = p }
            }
            library.itemsMoved(outcome.moved)                 // labels follow, one persist
            if !outcome.moved.isEmpty { library.setLastTransferDestination(dest) }
            editProcessing = false; bg.end()
            var msg = "Moved \(outcome.moved.count) item(s)."
            if !skip.isEmpty { msg += " Skipped \(skip.count) with matching names." }
            resultMessage = msg
            await reload()
        }
    }

    /// Copy checks for same-name duplicates like Move: it surfaces conflicts so the
    /// user can keep both or skip them, instead of silently making extra copies.
    private func performCopy(to dest: URL) {
        let entries = selectedEntries()
        let collisionURLs = Set(FileActions.collisions(entries.map(\.url), in: dest))
        if collisionURLs.isEmpty { finishCopy(to: dest, keepConflicts: []); return }
        let conflict = MoveConflict(dest: dest, items: entries.filter { collisionURLs.contains($0.url) }, isCopy: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { moveConflict = conflict }
    }

    /// Completes a copy (off the main thread, with a progress bar). `keepConflicts`
    /// copy under a new name; conflicting items the user deselected are skipped as
    /// duplicates. Copies don't carry labels (the originals keep theirs).
    private func finishCopy(to dest: URL, keepConflicts: Set<URL>) {
        moveConflict = nil
        let allURLs = selectedEntries().map(\.url)
        let skip = Set(FileActions.collisions(allURLs, in: dest)).subtracting(keepConflicts)
        let copyURLs = allURLs.filter { !skip.contains($0) }
        selection.removeAll(); selecting = false
        guard !copyURLs.isEmpty else { resultMessage = "Nothing to copy."; return }
        editLabel = "Copying…"; editProcessing = true; editProgress = 0
        let bg = BackgroundTaskHolder(); bg.begin(name: "Copy Items")
        Task {
            let outcome = await FileActions.copyItems(copyURLs, to: dest, skipCollisions: false) { p in
                Task { @MainActor in editProgress = p }
            }
            if !outcome.copied.isEmpty { library.setLastTransferDestination(dest) }
            editProcessing = false; bg.end()
            var msg = "Copied \(outcome.copied.count) item(s)."
            if !skip.isEmpty { msg += " Skipped \(skip.count) duplicate name(s)." }
            resultMessage = msg
            if dest.standardizedFileURL == url.standardizedFileURL { await reload() }
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
                library.contentDidChange(under: url)
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

/// A highlight bubble's cover, decoded off the main thread. The old synchronous
/// `UIImage(contentsOfFile:)` decoded every bubble's JPEG on the main actor during
/// layout — a visible hitch when a row of bubbles appears on a slow drive.
private struct BubbleCover: View {
    let coverURL: URL?
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
                    .allowedDynamicRange(.high)     // HDR covers (10-bit HEIC) keep their headroom
            } else {
                Circle().fill(Color(white: 0.2))
                    .overlay { Image(systemName: "photo.stack").font(.title3).foregroundStyle(.secondary) }
            }
        }
        .task(id: coverURL) {
            guard let coverURL else { image = nil; return }
            // HDR-aware read (see ThumbCell.loadCover) — a plain UIImage(contentsOfFile:)
            // would tone-map an HDR cover to SDR.
            image = await ThumbCell.loadCover(coverURL)
        }
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
