import SwiftUI
import AVFoundation

/// Full-screen viewer. Shows one item at a time as a plain SwiftUI view (no
/// UIPageViewController — that left the first page never appearing). Navigation
/// is via left/right swipes handled inside each page (reliable over the zoom
/// view). Decoding one image at a time keeps big folders fast.
/// - swipe left/right = next/previous, swipe down = exit, swipe up = info
/// - photos: pinch & double-tap zoom; videos: zoom + scrubber
struct ViewerView: View {
    let items: [Entry]
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
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss

    init(items: [Entry], startIndex: Int, slideshow: Bool = false) {
        self.items = items
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
                         onDismiss: { dismiss() },
                         onInfo: { showInfo = true },
                         onZoomChanged: { isZoomed = $0 },
                         onControlsHidden: { chromeHidden = $0 },
                         onToggleChrome: { chromeHidden.toggle() },
                         onPrev: { go(-1) },
                         onNext: { go(1) })
                    .id(index)
            }

            topChrome
        }
        .statusBarHidden(true)
        .onChange(of: index) { isZoomed = false; if !slideshow { chromeHidden = false } }
        .sheet(isPresented: $showInfo) {
            if let current { InfoPanel(entry: current) }
        }
        .fullScreenCover(isPresented: $showEditor) {
            if let current { MediaEditorView(entry: current) }
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
        .task(id: index) {
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
        library.rootURL ?? current?.url.deletingLastPathComponent() ?? items[0].url
    }

    private func useAsAlbumCover() { coverEntry = current }

    private func go(_ delta: Int) {
        let next = index + delta
        guard next >= 0, next < items.count else { return }
        index = next
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
                        Button { showEditor = true } label: {
                            Label("Crop & Rotate", systemImage: "crop.rotate")
                        }
                        Button { useAsAlbumCover() } label: {
                            Label("Use as Album Cover", systemImage: "rectangle.center.inset.filled.badge.plus")
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
    let item: Entry
    let coverSource: CoverFrameSource
    let onDismiss: () -> Void
    let onInfo: () -> Void
    let onZoomChanged: (Bool) -> Void
    let onControlsHidden: (Bool) -> Void
    let onToggleChrome: () -> Void
    let onPrev: () -> Void
    let onNext: () -> Void

    var body: some View {
        if item.kind == .video {
            VideoPage(url: item.url, coverSource: coverSource, onDismiss: onDismiss, onInfo: onInfo,
                      onZoomChanged: onZoomChanged, onControlsHidden: onControlsHidden,
                      onPrev: onPrev, onNext: onNext)
        } else {
            ZoomableImageView(url: item.url, coverSource: coverSource, onDismiss: onDismiss, onInfo: onInfo,
                              onZoomChanged: onZoomChanged, onToggleChrome: onToggleChrome,
                              onPrev: onPrev, onNext: onNext)
        }
    }
}
