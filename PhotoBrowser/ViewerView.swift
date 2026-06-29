import SwiftUI
import AVFoundation

/// Full-screen viewer. Shows one item at a time as a plain SwiftUI view (no
/// UIPageViewController — that left the first page never appearing). Navigation
/// is via left/right swipes handled inside each page (reliable over the zoom
/// view). Decoding one image at a time keeps big folders fast.
/// - swipe left/right = next/previous, swipe down = exit, swipe up = info
/// - photos: pinch & double-tap zoom; videos: zoom + scrubber
struct ViewerView: View {
    @State private var items: [Entry]      // mutable so Delete/Move can drop the current item and advance
    let slideshow: Bool
    @State private var index: Int
    @State private var isZoomed = false
    @State private var chromeHidden = false      // single-tap hides all overlays
    @State private var showInfo = false
    @State private var headerDate: Date?
    @State private var coverSource = CoverFrameSource()
    @State private var coverEntry: Entry?
    @State private var croppedCover: UIImage?
    @State private var showCoverFolderPicker = false
    @State private var showEditor = false
    @State private var showStudio = false
    @State private var showResize = false
    @State private var showAIEdit = false
    @State private var showMovePicker = false
    @State private var showCopyPicker = false
    @State private var confirmDelete = false
    @State private var actionNote: String?
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss

    init(items: [Entry], startIndex: Int, slideshow: Bool = false) {
        _items = State(initialValue: items)
        self.slideshow = slideshow
        _index = State(initialValue: startIndex)
        _chromeHidden = State(initialValue: slideshow)
    }

    private var current: Entry? { items.indices.contains(index) ? items[index] : nil }
    /// All overlays hide while zoomed in or after a single tap (and, for videos,
    /// when the player controls are tapped away).
    private var showChrome: Bool { !isZoomed && !chromeHidden }
    private var showHeader: Bool { current?.kind == .image && showChrome }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            if let item = current {
                PageView(item: item,
                         coverSource: coverSource,
                         infoShown: showInfo,
                         onDismiss: { dismiss() },
                         onInfo: { showInfo = true },
                         onZoomChanged: { isZoomed = $0 },
                         onControlsHidden: { chromeHidden = $0 },
                         onToggleChrome: { chromeHidden.toggle() },
                         onPrev: { go(-1) },
                         onNext: { go(1) })
                    .id(item.url)      // keyed on the entry, so removing the current item refreshes the page
            }

            topChrome
            if let actionNote { toast(actionNote) }
        }
        .statusBarHidden(true)
        .onChange(of: index) { isZoomed = false; if !slideshow { chromeHidden = false } }
        .sheet(isPresented: $showInfo) {
            if let current { InfoPanel(entry: current) }
        }
        // "Open Stories" (etc.) requested a folder jump from the info panel — close the viewer
        // (which also dismisses the info sheet) so the folder view underneath can push.
        .onChange(of: library.pendingFolderNavigation) { _, target in
            if target != nil { dismiss() }
        }
        .fullScreenCover(isPresented: $showEditor) {
            if let current { MediaEditorView(entry: current) }
        }
        .fullScreenCover(isPresented: $showStudio) {
            if let current { PhotoEditorView(entry: current) }
        }
        .sheet(isPresented: $showMovePicker) {
            FolderPicker(root: coverPickerRoot, confirmTitle: "Move Here") { dest in moveCurrent(to: dest) }
        }
        .sheet(isPresented: $showCopyPicker) {
            FolderPicker(root: coverPickerRoot, confirmTitle: "Copy Here") { dest in copyCurrent(to: dest) }
        }
        .confirmationDialog("Delete this item?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { deleteCurrent() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(current?.name ?? "")
        }
        .fullScreenCover(isPresented: $showResize) {
            if let current { ResizeEditorView(entry: current) }
        }
        .sheet(isPresented: $showAIEdit) {
            if let current { AIEditView(entry: current) }
        }
        .fullScreenCover(item: $coverEntry, onDismiss: {
            if croppedCover != nil { showCoverFolderPicker = true }
        }) { entry in
            AlbumCoverCropper(entry: entry,
                              providedImage: entry.kind == .video ? coverSource.current() : nil) { cropped in
                croppedCover = cropped
            }
        }
        .sheet(isPresented: $showCoverFolderPicker) {
            FolderPicker(root: coverPickerRoot, confirmTitle: "Use Here") { folder in
                if let croppedCover { library.setCover(croppedCover, for: folder) }
                croppedCover = nil
            }
        }
        // Show the real capture date (EXIF / video creation) — for exported video
        // frames this is the video's date, not the file's creation/modified time.
        .task(id: current?.url) {
            headerDate = nil
            if let current { headerDate = await MetadataLoader.captureDate(for: current) }
        }
        // Slideshow: hold each item, then advance (wrapping around).
        .task(id: slideshow ? index : -1) {
            guard slideshow, !items.isEmpty else { return }
            let dwell = await slideshowDwell(for: current)
            try? await Task.sleep(nanoseconds: UInt64(dwell * 1_000_000_000))
            if !Task.isCancelled { index = (index + 1) % items.count }
        }
    }

    private func slideshowDwell(for entry: Entry?) async -> Double {
        guard let entry, entry.kind == .video else { return 4 }
        let d = (try? await AVURLAsset(url: entry.url).load(.duration))?.seconds ?? 6
        return min(max(d.isFinite ? d : 6, 4), 30)
    }

    private var coverPickerRoot: URL {
        library.rootURL ?? current?.url.deletingLastPathComponent()
            ?? items.first?.url.deletingLastPathComponent()
            ?? URL(fileURLWithPath: NSHomeDirectory())
    }

    private func useAsAlbumCover() { coverEntry = current }

    private func go(_ delta: Int) {
        let next = index + delta
        guard next >= 0, next < items.count else { return }
        index = next
    }

    // MARK: - Item actions (Duplicate / Copy / Move / Delete)

    private func duplicateCurrent() {
        guard let current else { return }
        let n = FileActions.duplicate([current])
        library.contentDidChange()
        note(n > 0 ? "Duplicated" : "Couldn’t duplicate")
    }

    private func copyCurrent(to dest: URL) {
        guard let current else { return }
        let src = current.url
        Task {
            let outcome = await FileActions.copyItems([src], to: dest, skipCollisions: false) { _ in }
            if !outcome.copied.isEmpty { library.setLastTransferDestination(dest) }
            library.contentDidChange()   // a copy into the visible folder should appear
            note(outcome.copied.isEmpty ? "Couldn’t copy" : "Copied")
        }
    }

    private func moveCurrent(to dest: URL) {
        guard let current else { return }
        let src = current.url
        Task {
            let outcome = await FileActions.moveItems([src], to: dest, renameOnCollision: true) { _ in }
            guard !outcome.moved.isEmpty else { note("Couldn’t move"); return }
            library.itemsMoved(outcome.moved)            // labels/captions follow the file
            library.setLastTransferDestination(dest)
            library.contentDidChange()
            note("Moved")
            removeCurrentAndAdvance()
        }
    }

    private func deleteCurrent() {
        guard let current else { return }
        let assetIDs = library.origin(for: current.url).map { [$0] } ?? []
        FileActions.delete([current])
        library.clearOrigins([current.url])
        library.contentDidChange()
        if !assetIDs.isEmpty { Task { await FileActions.deletePhotosAssets(assetIDs) } }
        removeCurrentAndAdvance()
    }

    /// Drops the current item from the strip after it left the folder (delete/move) and shows the
    /// next one; closes the viewer when nothing remains. The page is keyed on the entry URL, so it
    /// refreshes even though `index` may be unchanged.
    private func removeCurrentAndAdvance() {
        guard items.indices.contains(index) else { dismiss(); return }
        items.remove(at: index)
        isZoomed = false
        if items.isEmpty { dismiss(); return }
        if index >= items.count { index = items.count - 1 }
    }

    /// A brief auto-dismissing status line at the bottom (Duplicate/Copy/Move feedback).
    private func note(_ text: String) {
        actionNote = text
        Task { try? await Task.sleep(nanoseconds: 1_600_000_000); if actionNote == text { actionNote = nil } }
    }

    private func toast(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .font(.subheadline.weight(.medium)).foregroundStyle(.white)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.black.opacity(0.6), in: Capsule())
                .padding(.bottom, 60)
        }
        .frame(maxWidth: .infinity)
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    // Close button + centered title/date; both hidden while zoomed in.
    private var topChrome: some View {
        ZStack(alignment: .top) {
            if showHeader { header }
            if showChrome {
                HStack(spacing: 12) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.headline).foregroundStyle(.white)
                            .padding(10).background(.black.opacity(0.45), in: Circle())
                    }
                    Spacer()
                    Menu {
                        if current?.kind == .image {
                            Button { showStudio = true } label: {
                                Label("Edit Photo", systemImage: "slider.horizontal.3")
                            }
                        }
                        Button { showEditor = true } label: {
                            Label("Crop & Rotate", systemImage: "crop.rotate")
                        }
                        if current?.kind == .image {
                            Button { showResize = true } label: {
                                Label("Resize / Extend", systemImage: "aspectratio")
                            }
                            Button { showAIEdit = true } label: {
                                Label("Edit with AI", systemImage: "wand.and.stars")
                            }
                        }
                        Button { useAsAlbumCover() } label: {
                            Label("Use as Album Cover", systemImage: "rectangle.center.inset.filled.badge.plus")
                        }
                        Divider()
                        Button { duplicateCurrent() } label: {
                            Label("Duplicate", systemImage: "plus.square.on.square")
                        }
                        Button { showCopyPicker = true } label: {
                            Label("Copy to Folder…", systemImage: "doc.on.doc")
                        }
                        Button { showMovePicker = true } label: {
                            Label("Move to Folder…", systemImage: "folder")
                        }
                        Button(role: .destructive) { confirmDelete = true } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.headline).foregroundStyle(.white)
                            .padding(10).background(.black.opacity(0.45), in: Circle())
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 6)
            }
        }
    }

    private var header: some View {
        VStack(spacing: 1) {
            Text(current?.name ?? "")
                .font(.subheadline.weight(.semibold)).lineLimit(1)
            if let date = headerDate ?? current?.modified {
                Text(date, format: .dateTime.month(.abbreviated).day().year().hour().minute())
                    .font(.caption2).opacity(0.85)
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 56)
        .padding(.top, 8)
        .shadow(color: .black.opacity(0.7), radius: 4)
    }
}

private struct PageView: View {
    @Environment(Library.self) private var library
    let item: Entry
    let coverSource: CoverFrameSource
    var infoShown: Bool = false
    let onDismiss: () -> Void
    let onInfo: () -> Void
    let onZoomChanged: (Bool) -> Void
    let onControlsHidden: (Bool) -> Void
    let onToggleChrome: () -> Void
    let onPrev: () -> Void
    let onNext: () -> Void

    var body: some View {
        if item.kind == .video {
            VideoPage(url: item.url, coverSource: coverSource, infoShown: infoShown,
                      onDismiss: onDismiss, onInfo: onInfo,
                      onZoomChanged: onZoomChanged, onControlsHidden: onControlsHidden,
                      onPrev: onPrev, onNext: onNext,
                      onCaptured: { library.contentDidChange() })
        } else {
            ZoomableImageView(url: item.url, coverSource: coverSource, onDismiss: onDismiss, onInfo: onInfo,
                              onZoomChanged: onZoomChanged, onToggleChrome: onToggleChrome,
                              onPrev: onPrev, onNext: onNext)
        }
    }
}
