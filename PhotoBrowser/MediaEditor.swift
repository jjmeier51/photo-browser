import SwiftUI
import UIKit
import AVFoundation
import ImageIO
import CoreImage

/// Crop aspect-ratio options for the editor.
enum CropAspect: String, CaseIterable, Identifiable {
    case original = "Original", square = "Square"
    case r43 = "4:3", r34 = "3:4", r169 = "16:9", r916 = "9:16"
    var id: String { rawValue }
    /// Width / height for the crop window (Original follows the image).
    func ratio(for imageSize: CGSize) -> CGFloat {
        switch self {
        case .original: return imageSize.height > 0 ? imageSize.width / imageSize.height : 1
        case .square:   return 1
        case .r43:      return 4.0 / 3.0
        case .r34:      return 3.0 / 4.0
        case .r169:     return 16.0 / 9.0
        case .r916:     return 9.0 / 16.0
        }
    }
}

/// Crop + rotate editor for a photo or video. Pan/zoom the image behind a fixed
/// crop window, choose an aspect ratio, and rotate in 90° steps; "Save" writes a
/// new edited copy beside the original (the original is never modified).
struct MediaEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(Library.self) private var library
    let entry: Entry

    @State private var poster: UIImage?
    @State private var box = EditorBox()
    @State private var aspect: CropAspect = .original
    @State private var quarters = 0
    @State private var working = false
    @State private var progress: Double = 0
    @State private var errorNote: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let poster {
                    EditorRepresentable(image: poster, aspect: aspect, quarters: quarters, box: box)
                } else {
                    ProgressView().tint(.white)
                }
                if working { progressOverlay }
            }
            .navigationTitle("Edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(working)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(working || poster == nil)
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button { quarters -= 1 } label: { Image(systemName: "rotate.left") }
                    Button { quarters += 1 } label: { Image(systemName: "rotate.right") }
                    Spacer()
                    Menu {
                        ForEach(CropAspect.allCases) { a in
                            Button { aspect = a } label: {
                                if a == aspect { Label(a.rawValue, systemImage: "checkmark") } else { Text(a.rawValue) }
                            }
                        }
                    } label: { Label(aspect.rawValue, systemImage: "crop") }
                }
            }
        }
        .task { await loadPoster() }
        .alert("Couldn’t save", isPresented: Binding(get: { errorNote != nil }, set: { if !$0 { errorNote = nil } })) {
            Button("OK") { errorNote = nil }
        } message: { Text(errorNote ?? "") }
    }

    private var progressOverlay: some View {
        VStack(spacing: 12) {
            if entry.kind == .video {
                Text("Saving…").font(.subheadline.weight(.medium))
                ProgressView(value: progress).progressViewStyle(.linear).frame(width: 220)
                Text("\(Int(progress * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.large)
                Text("Saving…").font(.subheadline)
            }
        }
        .padding(24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func loadPoster() async {
        if entry.kind == .image {
            poster = await ZoomableImageView.decode(url: entry.url, maxPixel: 2200, fullQuality: true)
        } else {
            poster = await Self.videoPoster(entry.url)
        }
    }

    static func videoPoster(_ url: URL) async -> UIImage? {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 2200, height: 2200)
        let time = CMTime(seconds: 0.1, preferredTimescale: 600)
        guard let cg = try? await gen.image(at: time).image else { return nil }
        return UIImage(cgImage: cg)
    }

    private func save() {
        guard let crop = box.controller?.normalizedCrop() else { return }
        let q = quarters
        let url = entry.url
        let isImage = entry.kind == .image
        working = true; progress = 0
        Task {
            let dest: URL?
            if isImage {
                dest = await Task.detached { MediaEditing.applyPhoto(url: url, quarters: q, crop: crop) }.value
            } else {
                dest = await MediaEditing.exportVideo(url: url, quarters: q, crop: crop) { p in
                    Task { @MainActor in progress = p }
                }
            }
            working = false
            if dest != nil {
                library.contentDidChange()
                dismiss()
            } else {
                errorNote = "The edit could not be saved."
            }
        }
    }
}

/// Bridges the SwiftUI "Save" button to the UIKit editor's crop computation.
final class EditorBox {
    weak var controller: EditorController?
}

private struct EditorRepresentable: UIViewControllerRepresentable {
    let image: UIImage
    let aspect: CropAspect
    let quarters: Int
    let box: EditorBox

    func makeUIViewController(context: Context) -> EditorController {
        let controller = EditorController(image: image)
        box.controller = controller
        return controller
    }

    func updateUIViewController(_ controller: EditorController, context: Context) {
        controller.apply(quarters: quarters, aspect: aspect)
    }
}

final class EditorController: UIViewController, UIScrollViewDelegate {
    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private let original: UIImage
    private var displayed: UIImage
    private var quarters = 0
    private var aspect: CropAspect = .original
    private var cropSize: CGSize = .zero
    private var cropOverlay: UIView?
    private var laidOut = false

    init(image: UIImage) {
        self.original = image
        self.displayed = image
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        scrollView.delegate = self
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.backgroundColor = .black
        view.addSubview(scrollView)
        imageView.contentMode = .scaleAspectFill
        scrollView.addSubview(imageView)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        scrollView.frame = view.bounds
        if !laidOut, view.bounds.width > 0 {
            laidOut = true
            reconfigure()
        }
    }

    func apply(quarters: Int, aspect: CropAspect) {
        guard quarters != self.quarters || aspect != self.aspect else { return }
        self.quarters = quarters
        self.aspect = aspect
        if laidOut { reconfigure() }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    private func reconfigure() {
        displayed = MediaEditing.rotate(original, quarters: quarters)
        // Reset the zoom state before swapping in the rotated image, otherwise the
        // previous scale clamps/translates it (rotate "zooms in and won't zoom out").
        scrollView.minimumZoomScale = 0.01
        scrollView.maximumZoomScale = 100
        scrollView.zoomScale = 1
        imageView.image = displayed
        imageView.frame = CGRect(origin: .zero, size: displayed.size)
        scrollView.contentSize = displayed.size

        // Crop window: largest rect of the chosen aspect that fits the view.
        let avail = view.bounds.insetBy(dx: 10, dy: 10).size
        let ar = aspect.ratio(for: displayed.size)
        var w = avail.width, h = w / ar
        if h > avail.height { h = avail.height; w = h * ar }
        cropSize = CGSize(width: w, height: h)

        let minScale = max(cropSize.width / displayed.size.width, cropSize.height / displayed.size.height)
        scrollView.minimumZoomScale = minScale
        scrollView.maximumZoomScale = minScale * 5
        scrollView.zoomScale = minScale

        let cr = cropRect
        scrollView.contentInset = UIEdgeInsets(top: cr.minY, left: cr.minX,
                                               bottom: view.bounds.height - cr.maxY,
                                               right: view.bounds.width - cr.maxX)
        scrollView.contentOffset = CGPoint(x: scrollView.contentSize.width / 2 - view.bounds.midX,
                                           y: scrollView.contentSize.height / 2 - view.bounds.midY)
        rebuildOverlay()
    }

    private var cropRect: CGRect {
        CGRect(x: (view.bounds.width - cropSize.width) / 2,
               y: (view.bounds.height - cropSize.height) / 2,
               width: cropSize.width, height: cropSize.height)
    }

    /// The crop window as a normalized rect (0…1) of the displayed (rotated) image.
    func normalizedCrop() -> CGRect {
        guard displayed.size.width > 0, scrollView.zoomScale > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let zoom = scrollView.zoomScale
        let cr = cropRect
        let w = displayed.size.width, h = displayed.size.height
        var nx = (scrollView.contentOffset.x + cr.minX) / zoom / w
        var ny = (scrollView.contentOffset.y + cr.minY) / zoom / h
        var nw = (cr.width / zoom) / w
        var nh = (cr.height / zoom) / h
        nx = min(max(0, nx), 1); ny = min(max(0, ny), 1)
        nw = min(nw, 1 - nx); nh = min(nh, 1 - ny)
        return CGRect(x: nx, y: ny, width: nw, height: nh)
    }

    private func rebuildOverlay() {
        cropOverlay?.removeFromSuperview()
        let overlay = UIView(frame: view.bounds)
        overlay.isUserInteractionEnabled = false
        overlay.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        let path = UIBezierPath(rect: overlay.bounds)
        path.append(UIBezierPath(rect: cropRect).reversing())
        let mask = CAShapeLayer(); mask.path = path.cgPath
        overlay.layer.mask = mask
        let border = CAShapeLayer()
        border.path = UIBezierPath(rect: cropRect).cgPath
        border.fillColor = UIColor.clear.cgColor
        border.strokeColor = UIColor.white.cgColor
        border.lineWidth = 1.5
        overlay.layer.addSublayer(border)
        view.addSubview(overlay)
        cropOverlay = overlay
    }
}

/// The actual pixel work: rotate + crop a photo, or export an edited video.
enum MediaEditing {

    // MARK: - Rotation helpers

    /// Rotates a UIImage clockwise by `quarters` × 90° (for the editor preview).
    static func rotate(_ image: UIImage, quarters: Int) -> UIImage {
        let q = ((quarters % 4) + 4) % 4
        if q == 0 { return image }
        let swap = q % 2 == 1
        let newSize = swap ? CGSize(width: image.size.height, height: image.size.width) : image.size
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { ctx in
            let c = ctx.cgContext
            c.translateBy(x: newSize.width / 2, y: newSize.height / 2)
            c.rotate(by: CGFloat(q) * .pi / 2)
            image.draw(in: CGRect(x: -image.size.width / 2, y: -image.size.height / 2,
                                  width: image.size.width, height: image.size.height))
        }
    }

    /// Rotates a CGImage clockwise by `quarters` × 90° at full resolution.
    static func rotate(_ image: CGImage, quarters: Int) -> CGImage {
        let q = ((quarters % 4) + 4) % 4
        if q == 0 { return image }
        let swap = q % 2 == 1
        let outW = swap ? image.height : image.width
        let outH = swap ? image.width : image.height
        let cs = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: outW, height: outH, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        ctx.translateBy(x: CGFloat(outW) / 2, y: CGFloat(outH) / 2)
        ctx.rotate(by: -CGFloat(q) * .pi / 2)               // CGContext is Y-up
        ctx.draw(image, in: CGRect(x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2,
                                   width: CGFloat(image.width), height: CGFloat(image.height)))
        return ctx.makeImage() ?? image
    }

    // MARK: - Photo

    static func applyPhoto(url: URL, quarters: Int, crop: CGRect) -> URL? {
        guard let full = loadFullImage(url) else { return nil }
        let rotated = rotate(full, quarters: quarters)
        let w = CGFloat(rotated.width), h = CGFloat(rotated.height)
        var px = CGRect(x: crop.minX * w, y: crop.minY * h, width: crop.width * w, height: crop.height * h).integral
        px = px.intersection(CGRect(x: 0, y: 0, width: rotated.width, height: rotated.height))
        guard !px.isEmpty, let cropped = rotated.cropping(to: px) else { return nil }

        let folder = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent + " (edited)"
        let ci = CIImage(cgImage: cropped)
        let ctx = CIContext()
        let cs = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
        if let data = try? ctx.heifRepresentation(of: ci, format: .RGBA8, colorSpace: cs, options: [:]) {
            let dest = FileActions.uniqueDestination(for: base + ".heic", in: folder)
            if (try? data.write(to: dest)) != nil { return dest }
        }
        if let data = UIImage(cgImage: cropped).jpegData(compressionQuality: 0.95) {
            let dest = FileActions.uniqueDestination(for: base + ".jpg", in: folder)
            if (try? data.write(to: dest)) != nil { return dest }
        }
        return nil
    }

    /// Full-resolution, upright CGImage for a photo URL.
    private static func loadFullImage(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let w = props?[kCGImagePropertyPixelWidth] as? Int ?? 4096
        let h = props?[kCGImagePropertyPixelHeight] as? Int ?? 4096
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(w, h)
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
    }

    // MARK: - Video

    static func exportVideo(url: URL, quarters: Int, crop: CGRect,
                            progress: @escaping @Sendable (Double) -> Void) async -> URL? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return nil }
        let natural = (try? await track.load(.naturalSize)) ?? .zero
        let pt = (try? await track.load(.preferredTransform)) ?? .identity
        let duration = (try? await asset.load(.duration)) ?? .zero
        let fps = (try? await track.load(.nominalFrameRate)).map { $0 > 0 ? $0 : 30 } ?? 30
        guard natural.width > 0, natural.height > 0, duration.seconds > 0 else { return nil }

        // Oriented (display) size, then the rotated display size.
        let dispRect = CGRect(origin: .zero, size: natural).applying(pt)
        let dispW = abs(dispRect.width), dispH = abs(dispRect.height)
        let q = ((quarters % 4) + 4) % 4
        let rotW = (q % 2 == 1) ? dispH : dispW
        let rotH = (q % 2 == 1) ? dispW : dispH

        // Crop rect in rotated display pixels (even dimensions, clamped).
        var cw = (crop.width * rotW).rounded()
        var ch = (crop.height * rotH).rounded()
        cw = max(16, (cw / 2).rounded() * 2)
        ch = max(16, (ch / 2).rounded() * 2)
        var cx = (crop.minX * rotW).rounded()
        var cy = (crop.minY * rotH).rounded()
        cx = min(max(0, cx), max(0, rotW - cw))
        cy = min(max(0, cy), max(0, rotH - ch))

        // preferredTransform → extra rotation → translate the crop origin to (0,0).
        let rot = rotationTransform(quarters: q, displayW: dispW, displayH: dispH)
        let cropT = CGAffineTransform(translationX: -cx, y: -cy)
        let full = pt.concatenating(rot).concatenating(cropT)

        let videoComposition = AVMutableVideoComposition()
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(fps.rounded(), 1)))
        videoComposition.renderSize = CGSize(width: cw, height: ch)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(full, at: .zero)
        instruction.layerInstructions = [layer]
        videoComposition.instructions = [instruction]

        let folder = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent + " (edited)"
        let dest = FileActions.uniqueDestination(for: base + ".mov", in: folder)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else { return nil }
        export.videoComposition = videoComposition
        export.outputURL = dest
        export.outputFileType = .mov

        let poll = Task {
            while !Task.isCancelled {
                progress(Double(export.progress))
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { cont.resume() }
        }
        poll.cancel()
        if export.status == .completed { progress(1); return dest }
        return nil
    }

    /// Rotates an already display-oriented frame clockwise by `quarters` × 90°,
    /// keeping it in the positive quadrant (display size W×H).
    private static func rotationTransform(quarters: Int, displayW: CGFloat, displayH: CGFloat) -> CGAffineTransform {
        switch ((quarters % 4) + 4) % 4 {
        case 1: return CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: displayH, ty: 0)
        case 2: return CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: displayW, ty: displayH)
        case 3: return CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: displayW)
        default: return .identity
        }
    }
}
