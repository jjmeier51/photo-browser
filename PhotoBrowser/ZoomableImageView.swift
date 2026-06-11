import SwiftUI
import ImageIO
import UIKit

/// Shows a photo with pinch + double-tap zoom. Loads a fast embedded-thumbnail
/// preview first, then the full image. Swipes (handled in UIKit, reliable over
/// the scroll view) at 1×: left/right = next/prev, up = info, down = exit.
struct ZoomableImageView: View {
    let url: URL
    var coverSource: CoverFrameSource? = nil
    var onDismiss: () -> Void = {}
    var onInfo: () -> Void = {}
    var onZoomChanged: ((Bool) -> Void)? = nil
    var onToggleChrome: () -> Void = {}
    var onPrev: () -> Void = {}
    var onNext: () -> Void = {}

    @State private var displayImage: UIImage?
    @State private var badge: String?

    var body: some View {
        Group {
            if let displayImage {
                ZoomScrollView(image: displayImage, onZoomChanged: onZoomChanged,
                               onDismiss: onDismiss, onInfo: onInfo, onToggleChrome: onToggleChrome,
                               onPrev: onPrev, onNext: onNext)
            } else {
                Color.clear
            }
        }
        .ignoresSafeArea()                 // fill the whole screen, like the video page
        .overlay(alignment: .topTrailing) {
            if let badge {
                Text(badge)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 50).padding(.trailing, 12)
            }
        }
        .task(id: url) {
            badge = await MetadataLoader.photoBadge(url: url)
            // This page owns the album-cover source while it's visible.
            coverSource?.liveProvider = nil
            // Fast embedded-thumbnail preview first, then the full image.
            if let preview = await Self.decode(url: url, maxPixel: 1400, fullQuality: false) {
                if displayImage == nil { displayImage = preview; coverSource?.staticImage = preview }
            }
            if let full = await Self.decode(url: url, maxPixel: 2600, fullQuality: true) {
                displayImage = full
                coverSource?.staticImage = full
            }
        }
    }

    /// `fullQuality == false` allows ImageIO to use the file's embedded thumbnail
    /// (fast); `true` forces a high-quality downsample from the full image.
    static func decode(url: URL, maxPixel: CGFloat, fullQuality: Bool) async -> UIImage? {
        await Task.detached(priority: fullQuality ? .userInitiated : .high) { () -> UIImage? in
            let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: fullQuality,
                kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return UIImage(cgImage: cg)
        }.value
    }
}

/// A scroll view that fits the image to the screen at zoomScale 1 (exactly like
/// the video player), keeps it centered, and exposes the scale that fills the
/// screen so a double-tap can zoom to fill.
private final class CenteringScrollView: UIScrollView {
    let imageView = UIImageView()
    private var imageSize: CGSize = .zero
    private var fitSize: CGSize = .zero          // imageView size at zoomScale 1
    private var configuredFor: CGSize = .zero
    private var lastBounds: CGSize = .zero

    /// The zoom scale (relative to the fitted state) that fills the whole screen.
    var fillScale: CGFloat {
        guard fitSize.width > 0, fitSize.height > 0 else { return 1 }
        return max(bounds.width / fitSize.width, bounds.height / fitSize.height)
    }

    func setImage(_ image: UIImage) {
        imageView.image = image
        imageSize = image.size
        configuredFor = .zero          // force a reconfigure for the new size
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard imageSize.width > 0, bounds.width > 0, bounds.height > 0 else { return }
        if configuredFor != imageSize || lastBounds != bounds.size {
            configure()
            configuredFor = imageSize
            lastBounds = bounds.size
        }
        centerContent()
    }

    private func configure() {
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        fitSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        zoomScale = 1
        imageView.frame = CGRect(origin: .zero, size: fitSize)
        contentSize = fitSize
        minimumZoomScale = 1
        maximumZoomScale = max(6, fillScale * 2)
    }

    func centerContent() {
        let ox = max(0, (bounds.width - imageView.frame.width) / 2)
        let oy = max(0, (bounds.height - imageView.frame.height) / 2)
        imageView.center = CGPoint(x: imageView.frame.width / 2 + ox,
                                   y: imageView.frame.height / 2 + oy)
    }
}

private struct ZoomScrollView: UIViewRepresentable {
    let image: UIImage
    var onZoomChanged: ((Bool) -> Void)?
    var onDismiss: () -> Void
    var onInfo: () -> Void
    var onToggleChrome: () -> Void
    var onPrev: () -> Void
    var onNext: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onZoomChanged: onZoomChanged, onDismiss: onDismiss, onInfo: onInfo,
                    onToggleChrome: onToggleChrome, onPrev: onPrev, onNext: onNext)
    }

    func makeUIView(context: Context) -> CenteringScrollView {
        let scroll = CenteringScrollView()
        scroll.delegate = context.coordinator
        scroll.bouncesZoom = true
        scroll.isScrollEnabled = false          // enabled only while zoomed in
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.backgroundColor = .clear
        scroll.contentInsetAdjustmentBehavior = .never

        scroll.imageView.contentMode = .scaleAspectFit
        scroll.imageView.isUserInteractionEnabled = true
        scroll.setImage(image)
        scroll.addSubview(scroll.imageView)

        context.coordinator.scrollView = scroll

        let doubleTap = UITapGestureRecognizer(target: context.coordinator,
                                               action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)

        let singleTap = UITapGestureRecognizer(target: context.coordinator,
                                               action: #selector(Coordinator.handleSingleTap))
        singleTap.numberOfTapsRequired = 1
        singleTap.require(toFail: doubleTap)
        scroll.addGestureRecognizer(singleTap)

        for (dir, sel) in [(UISwipeGestureRecognizer.Direction.up,    #selector(Coordinator.swipeUp)),
                           (.down,  #selector(Coordinator.swipeDown)),
                           (.left,  #selector(Coordinator.swipeLeft)),
                           (.right, #selector(Coordinator.swipeRight))] {
            let g = UISwipeGestureRecognizer(target: context.coordinator, action: sel)
            g.direction = dir
            scroll.addGestureRecognizer(g)
        }

        return scroll
    }

    func updateUIView(_ uiView: CenteringScrollView, context: Context) {
        context.coordinator.onDismiss = onDismiss
        context.coordinator.onInfo = onInfo
        context.coordinator.onToggleChrome = onToggleChrome
        context.coordinator.onPrev = onPrev
        context.coordinator.onNext = onNext
        if uiView.imageView.image !== image {
            uiView.setImage(image)
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var scrollView: CenteringScrollView?
        let onZoomChanged: ((Bool) -> Void)?
        var onDismiss: () -> Void
        var onInfo: () -> Void
        var onToggleChrome: () -> Void
        var onPrev: () -> Void
        var onNext: () -> Void

        init(onZoomChanged: ((Bool) -> Void)?, onDismiss: @escaping () -> Void, onInfo: @escaping () -> Void,
             onToggleChrome: @escaping () -> Void, onPrev: @escaping () -> Void, onNext: @escaping () -> Void) {
            self.onZoomChanged = onZoomChanged
            self.onDismiss = onDismiss
            self.onInfo = onInfo
            self.onToggleChrome = onToggleChrome
            self.onPrev = onPrev
            self.onNext = onNext
        }

        @objc func handleSingleTap() { onToggleChrome() }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            (scrollView as? CenteringScrollView)?.imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            let zoomed = scrollView.zoomScale > scrollView.minimumZoomScale + 0.01
            scrollView.isScrollEnabled = zoomed
            onZoomChanged?(zoomed)
            (scrollView as? CenteringScrollView)?.centerContent()
        }

        private var atRest: Bool {
            guard let s = scrollView else { return true }
            return s.zoomScale <= s.minimumZoomScale + 0.01
        }
        @objc func swipeUp()    { if atRest { onInfo() } }
        @objc func swipeDown()  { if atRest { onDismiss() } }
        @objc func swipeLeft()  { if atRest { onNext() } }
        @objc func swipeRight() { if atRest { onPrev() } }

        /// Three-stage double-tap: fit → fill the screen → a bit more → back to fit.
        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scroll = scrollView else { return }
            let fit = scroll.minimumZoomScale
            let fill = max(scroll.fillScale, fit + 0.01)
            let more = fill * 1.5
            let s = scroll.zoomScale
            let point = gesture.location(in: scroll.imageView)
            if s < fill - 0.02 {
                zoom(scroll, to: fill, at: point)
            } else if s < more - 0.02 {
                zoom(scroll, to: more, at: point)
            } else {
                scroll.setZoomScale(fit, animated: true)
            }
        }

        private func zoom(_ scroll: UIScrollView, to scale: CGFloat, at point: CGPoint) {
            let w = scroll.bounds.size.width / scale
            let h = scroll.bounds.size.height / scale
            scroll.zoom(to: CGRect(x: point.x - w / 2, y: point.y - h / 2, width: w, height: h), animated: true)
        }
    }
}
