import SwiftUI
import UIKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import CoreImage
import CoreImage.CIFilterBuiltins

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
/// crop window, choose an aspect ratio, and rotate in 90° steps; "Save" writes the
/// result back over the original file in place (no duplicate is created), carrying
/// the original's EXIF/creation metadata along so capture date, location and Age
/// survive. The save runs under a background-task window so it keeps going if the
/// app is briefly backgrounded (iOS still can't finish it once the app is killed).
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
        let bg = BackgroundTaskHolder()
        bg.begin(name: "Save Edit")   // best-effort: keep saving if the app is backgrounded
        Task {
            let ok: Bool
            if isImage {
                ok = await Task.detached { MediaEditing.applyPhotoInPlace(url: url, quarters: q, crop: crop) }.value
            } else {
                ok = await MediaEditing.exportVideoInPlace(url: url, quarters: q, crop: crop) { p in
                    Task { @MainActor in progress = p }
                }
            }
            working = false
            bg.end()
            if ok {
                library.contentDidChange(under: url.deletingLastPathComponent())   // reload folder → new mtime/size → fresh thumbnail
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
    nonisolated static func rotate(_ image: CGImage, quarters: Int) -> CGImage {
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

    // MARK: - Photo (edit in place, preserving metadata)

    /// The EXIF orientation whose display correction equals a clockwise rotation by
    /// `quarters` × 90° — used to bake the same rotation the CGImage/UIImage helpers do
    /// onto a Core Image buffer (6 = 90° CW, 3 = 180°, 8 = 90° CCW).
    nonisolated static func exifOrientation(forQuarters quarters: Int) -> Int32 {
        switch ((quarters % 4) + 4) % 4 {
        case 1:  return 6      // 90° clockwise
        case 2:  return 3      // 180°
        case 3:  return 8      // 90° counter-clockwise
        default: return 1
        }
    }

    /// Rotates/crops the photo at `url` and writes the result back over the original
    /// file (same name and container), preserving EXIF/GPS so capture date, location
    /// and Age survive the edit. Returns true on success.
    /// `nonisolated`: called from `Task.detached` save paths — the decode/re-encode
    /// of a full-resolution photo must never run on the main actor.
    nonisolated static func applyPhotoInPlace(url: URL, quarters: Int, crop: CGRect) -> Bool {
        // HDR sources (gain-map/PQ/HLG HEIC, RAW) take a 10-bit Core Image path so the
        // headroom survives — the 8-bit `loadFullCGImage` path below would flatten them
        // to SDR. Falls through to SDR if the HDR encode isn't possible.
        if PhotoEditorIO.isHDRSource(url),
           applyPhotoHDRInPlace(url: url, quarters: quarters, crop: crop) {
            return true
        }

        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let full = loadFullCGImage(src) else { return false }
        let rotated = rotate(full, quarters: quarters)
        let w = CGFloat(rotated.width), h = CGFloat(rotated.height)
        var px = CGRect(x: crop.minX * w, y: crop.minY * h, width: crop.width * w, height: crop.height * h).integral
        px = px.intersection(CGRect(x: 0, y: 0, width: rotated.width, height: rotated.height))
        guard !px.isEmpty, let cropped = rotated.cropping(to: px) else { return false }

        // Carry the original metadata, but reset orientation (the rotation is now
        // baked into the pixels) and update the stored dimensions.
        var props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
        props[kCGImagePropertyOrientation] = 1
        props[kCGImagePropertyPixelWidth] = cropped.width
        props[kCGImagePropertyPixelHeight] = cropped.height
        if var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            props[kCGImagePropertyTIFFDictionary] = tiff
        }

        // Re-encode into the original's container so the file extension stays valid;
        // fall back to JPEG if that type can't be written (e.g. HEIC on a simulator).
        let folder = url.deletingLastPathComponent()
        let tmp = folder.appendingPathComponent(".\(UUID().uuidString).edit")
        func encode(_ type: CFString) -> Bool {
            guard let dst = CGImageDestinationCreateWithURL(tmp as CFURL, type, 1, nil) else { return false }
            CGImageDestinationAddImage(dst, cropped, props as CFDictionary)
            return CGImageDestinationFinalize(dst)
        }
        let original = CGImageSourceGetType(src) ?? (UTType.jpeg.identifier as CFString)
        if !encode(original) {
            try? FileManager.default.removeItem(at: tmp)
            guard encode(UTType.jpeg.identifier as CFString) else {
                try? FileManager.default.removeItem(at: tmp); return false
            }
        }
        let dates = fileDates(of: url)                 // capture before the swap replaces the source
        guard replaceInPlace(original: url, temp: tmp) else { return false }
        restoreFileDates(dates, to: url)               // keep the file's creation/modification stamps
        return true
    }

    /// HDR-preserving in-place rotate/crop: loads the source **expanded to HDR** (gain map
    /// applied, extended range), bakes the rotation and crop into the pixels, and writes a
    /// 10-bit HDR HEIC carrying the original metadata + capture date. Returns false so
    /// `applyPhotoInPlace` can fall back to the SDR path. `nonisolated` — all pixel work is
    /// off the main actor.
    nonisolated private static func applyPhotoHDRInPlace(url: URL, quarters: Int, crop: CGRect) -> Bool {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let ci = CIImage(contentsOf: url, options: [.expandToHDR: true]) else { return false }
        var props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
        let orientation = Int32((props[kCGImagePropertyOrientation] as? UInt32) ?? 1)
        // RAW/DNG is already oriented by Core Image's RAW pipeline; everything else needs the
        // EXIF orientation baked in first (same rule as PhotoEditorIO.load/loadHDR).
        let upright = PhotoEditorIO.isRAWSource(url) ? ci : ci.oriented(forExifOrientation: orientation)

        // Bake the rotation, then apply the (normalized, top-left-origin) crop. CIImage is
        // Y-up with an arbitrary origin, so normalize origin to (0,0) and flip the crop's Y.
        let rotated = atOrigin(upright.oriented(forExifOrientation: exifOrientation(forQuarters: quarters)))
        let w = rotated.extent.width, h = rotated.extent.height
        guard w > 0, h > 0 else { return false }
        var cropped = rotated
        if crop != CGRect(x: 0, y: 0, width: 1, height: 1) {
            let rect = CGRect(x: crop.minX * w,
                              y: (1 - crop.minY - crop.height) * h,     // top-left → Y-up
                              width: crop.width * w, height: crop.height * h).integral
            let clamped = rect.intersection(rotated.extent)
            guard !clamped.isNull, !clamped.isEmpty else { return false }
            cropped = atOrigin(rotated.cropped(to: clamped))
        }
        guard !cropped.extent.isInfinite, !cropped.extent.isNull else { return false }

        props[kCGImagePropertyOrientation] = 1                          // rotation baked into pixels
        props[kCGImagePropertyPixelWidth] = Int(cropped.extent.width.rounded())
        props[kCGImagePropertyPixelHeight] = Int(cropped.extent.height.rounded())
        if var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            props[kCGImagePropertyTIFFDictionary] = tiff
        }
        // CIImage properties are string-keyed; embed them so EXIF/GPS/dates survive the encode.
        let stringProps = Dictionary(props.map { ($0.key as String, $0.value) }, uniquingKeysWith: { a, _ in a })
        let withMeta = cropped.settingProperties(stringProps)

        let ctx = CIContext(options: nil)
        let outSpace = CGColorSpace(name: CGColorSpace.displayP3_PQ) ?? ci.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let data = try? ctx.heif10Representation(of: withMeta, colorSpace: outSpace, options: [:]) else { return false }

        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).edit")
        do { try data.write(to: tmp) } catch { return false }
        // Verify it decodes before swapping it in, so a bad encode can't corrupt the photo.
        guard CGImageSourceCreateWithURL(tmp as CFURL, nil) != nil else {
            try? FileManager.default.removeItem(at: tmp); return false
        }
        let dates = fileDates(of: url)
        guard replaceInPlace(original: url, temp: tmp) else { return false }
        restoreFileDates(dates, to: url)
        return true
    }

    /// Translates `image` so its extent's origin sits at (0, 0) — Core Image crops/rotations
    /// leave the extent at an arbitrary origin, which trips up cropping math and encoders.
    nonisolated private static func atOrigin(_ image: CIImage) -> CIImage {
        image.transformed(by: CGAffineTransform(translationX: -image.extent.origin.x, y: -image.extent.origin.y))
    }

    /// The file's creation/modification dates, re-applied after an in-place swap so the
    /// browser's timeline stays stable (the re-encoded file would otherwise get "now").
    nonisolated private static func fileDates(of url: URL) -> [FileAttributeKey: Any] {
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path) else { return [:] }
        var set: [FileAttributeKey: Any] = [:]
        if let c = a[.creationDate] { set[.creationDate] = c }
        if let m = a[.modificationDate] { set[.modificationDate] = m }
        return set
    }

    nonisolated private static func restoreFileDates(_ dates: [FileAttributeKey: Any], to url: URL) {
        guard !dates.isEmpty else { return }
        try? FileManager.default.setAttributes(dates, ofItemAtPath: url.path)
    }

    /// Doubles a photo's pixel dimensions with a high-quality (Lanczos) upscale, re-encoding in
    /// place while preserving its metadata (EXIF capture date, GPS, …). Writes to a sibling temp
    /// file and **verifies it decodes before replacing the original**, so a bad encode never
    /// corrupts the photo. SDR pixels only — an HDR gain map isn't carried (most story photos are
    /// SDR); the base image + all metadata are kept. Returns true on success, false (no-op) otherwise.
    static func upscalePhotoInPlace(url: URL, scale: CGFloat = 2) -> Bool {
        guard scale > 1, let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let full = loadFullCGImage(src) else { return false }
        let targetW = Int((CGFloat(full.width) * scale).rounded())
        let targetH = Int((CGFloat(full.height) * scale).rounded())
        guard targetW > 1, targetH > 1 else { return false }

        let ci = CIImage(cgImage: full).clampedToExtent()
            .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1.0])
            .cropped(to: CGRect(x: 0, y: 0, width: targetW, height: targetH))
        let ctx = CIContext(options: nil)
        guard let scaled = ctx.createCGImage(ci, from: ci.extent) else { return false }

        var props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
        props[kCGImagePropertyPixelWidth] = targetW
        props[kCGImagePropertyPixelHeight] = targetH

        let folder = url.deletingLastPathComponent()
        let tmp = folder.appendingPathComponent(".\(UUID().uuidString).up")
        let type = CGImageSourceGetType(src) ?? (UTType.heic.identifier as CFString)
        func encode(_ t: CFString) -> Bool {
            guard let dst = CGImageDestinationCreateWithURL(tmp as CFURL, t, 1, nil) else { return false }
            CGImageDestinationAddImage(dst, scaled, props as CFDictionary)
            return CGImageDestinationFinalize(dst)
        }
        if !encode(type) {
            try? FileManager.default.removeItem(at: tmp)
            guard encode(UTType.jpeg.identifier as CFString) else { try? FileManager.default.removeItem(at: tmp); return false }
        }
        // Verify the re-encode is a readable image before swapping it in.
        guard CGImageSourceCreateWithURL(tmp as CFURL, nil).flatMap({ CGImageSourceCreateImageAtIndex($0, 0, nil) }) != nil else {
            try? FileManager.default.removeItem(at: tmp); return false
        }
        return replaceInPlace(original: url, temp: tmp)
    }

    /// "AI Upscale" for a single photo: a light Core Image enhancement — gentle noise reduction,
    /// a subtle unsharp mask, and a slight (1.5×) Lanczos resolution bump — re-encoded in place
    /// while preserving metadata (EXIF capture date, GPS, …). Writes to a temp file and verifies
    /// it decodes before replacing the original, so it can't corrupt the photo. SDR pixels only
    /// (an HDR gain map isn't carried). Returns true on success.
    /// `nonisolated`: called from download pipelines (Facebook) and detached tasks — the
    /// pixel work must never run on the main actor.
    nonisolated static func enhancePhotoInPlace(url: URL, scale: CGFloat = 1.5) -> Bool {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let full = loadFullCGImage(src) else { return false }
        let s = max(1, scale)
        let targetW = Int((CGFloat(full.width) * s).rounded())
        let targetH = Int((CGFloat(full.height) * s).rounded())
        guard targetW > 1, targetH > 1 else { return false }

        var ci = CIImage(cgImage: full).clampedToExtent()
        if s > 1 {
            ci = ci.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: s, kCIInputAspectRatioKey: 1.0])
        }
        ci = ci.applyingFilter("CINoiseReduction", parameters: ["inputNoiseLevel": 0.012, "inputSharpness": 0.4])
                .applyingFilter("CIUnsharpMask", parameters: [kCIInputRadiusKey: 2.0, kCIInputIntensityKey: 0.5])
                .cropped(to: CGRect(x: 0, y: 0, width: targetW, height: targetH))
        let ctx = CIContext(options: nil)
        guard let out = ctx.createCGImage(ci, from: ci.extent) else { return false }

        var props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
        props[kCGImagePropertyPixelWidth] = targetW
        props[kCGImagePropertyPixelHeight] = targetH

        let folder = url.deletingLastPathComponent()
        let tmp = folder.appendingPathComponent(".\(UUID().uuidString).up")
        let type = CGImageSourceGetType(src) ?? (UTType.heic.identifier as CFString)
        func encode(_ t: CFString) -> Bool {
            guard let dst = CGImageDestinationCreateWithURL(tmp as CFURL, t, 1, nil) else { return false }
            CGImageDestinationAddImage(dst, out, props as CFDictionary)
            return CGImageDestinationFinalize(dst)
        }
        if !encode(type) {
            try? FileManager.default.removeItem(at: tmp)
            guard encode(UTType.jpeg.identifier as CFString) else { try? FileManager.default.removeItem(at: tmp); return false }
        }
        guard CGImageSourceCreateWithURL(tmp as CFURL, nil).flatMap({ CGImageSourceCreateImageAtIndex($0, 0, nil) }) != nil else {
            try? FileManager.default.removeItem(at: tmp); return false
        }
        return replaceInPlace(original: url, temp: tmp)
    }

    /// Resizes a photo to exactly `targetWidth`×`targetHeight` pixels (high-quality Lanczos), re-encoded in
    /// place while **preserving metadata** (EXIF capture date, GPS, …). Handles both down- and up-scaling.
    /// The caller supplies a proportional target (aspect-preserving). Writes to a temp file and verifies it
    /// decodes before swapping it in, so a bad encode can't corrupt the photo. SDR pixels only. Returns true.
    static func resizePhotoInPlace(url: URL, targetWidth: Int, targetHeight: Int) -> Bool {
        guard targetWidth > 1, targetHeight > 1,
              let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let full = loadFullCGImage(src), full.width > 0, full.height > 0 else { return false }
        // No-op if the size is unchanged.
        if targetWidth == full.width, targetHeight == full.height { return true }
        let sx = CGFloat(targetWidth) / CGFloat(full.width)
        let sy = CGFloat(targetHeight) / CGFloat(full.height)
        let ci = CIImage(cgImage: full).clampedToExtent()
            .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: sx, kCIInputAspectRatioKey: sy / sx])
            .cropped(to: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        let ctx = CIContext(options: nil)
        guard let out = ctx.createCGImage(ci, from: ci.extent) else { return false }

        var props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
        props[kCGImagePropertyPixelWidth] = targetWidth
        props[kCGImagePropertyPixelHeight] = targetHeight

        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).rsz")
        let type = CGImageSourceGetType(src) ?? (UTType.heic.identifier as CFString)
        func encode(_ t: CFString) -> Bool {
            guard let dst = CGImageDestinationCreateWithURL(tmp as CFURL, t, 1, nil) else { return false }
            CGImageDestinationAddImage(dst, out, props as CFDictionary)
            return CGImageDestinationFinalize(dst)
        }
        if !encode(type) {
            try? FileManager.default.removeItem(at: tmp)
            guard encode(UTType.jpeg.identifier as CFString) else { try? FileManager.default.removeItem(at: tmp); return false }
        }
        guard CGImageSourceCreateWithURL(tmp as CFURL, nil).flatMap({ CGImageSourceCreateImageAtIndex($0, 0, nil) }) != nil else {
            try? FileManager.default.removeItem(at: tmp); return false
        }
        return replaceInPlace(original: url, temp: tmp)
    }

    /// The stored pixel dimensions of an image file (upright), without decoding the pixels.
    static func pixelSize(of url: URL) -> (width: Int, height: Int)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        // EXIF orientation 5–8 swaps width/height when displayed upright.
        let o = (props[kCGImagePropertyOrientation] as? Int) ?? 1
        return (5...8).contains(o) ? (h, w) : (w, h)
    }

    /// Full-resolution, upright CGImage from an open image source.
    nonisolated private static func loadFullCGImage(_ src: CGImageSource) -> CGImage? {
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

    /// Atomically swaps `temp` in for `original`, keeping the original's name and
    /// location. Falls back to remove-then-move if the volume rejects replace.
    nonisolated static func replaceInPlace(original: URL, temp: URL) -> Bool {
        let fm = FileManager.default
        if (try? fm.replaceItemAt(original, withItemAt: temp)) != nil {
            DriveWriter.fullSyncFileAndParent(original)   // durably commit the swap so a later unplug can't leak clusters
            return true
        }
        do {
            if fm.fileExists(atPath: original.path) { try fm.removeItem(at: original) }
            try fm.moveItem(at: temp, to: original)
            DriveWriter.fullSyncFileAndParent(original)
            return true
        } catch {
            try? fm.removeItem(at: temp)
            return false
        }
    }

    // MARK: - Resize / extend (fit to an aspect ratio, on-device fill)

    /// How the extended area is filled when fitting a photo to a new aspect ratio.
    enum ResizeFill: String, CaseIterable, Identifiable {
        case blur = "Blur", mirror = "Mirror", white = "White", black = "Black"
        var id: String { rawValue }
    }

    private static let ciContext = CIContext()

    /// Composites `image` centered on a larger canvas of aspect `targetAspect`
    /// (extending the shorter side — never cropping), filling the new area per
    /// `fill`. Returns the composited image (no file I/O); used for preview + save.
    static func composeCanvas(_ image: CGImage, targetAspect: CGFloat, fill: ResizeFill) -> CGImage? {
        let W = CGFloat(image.width), H = CGFloat(image.height)
        guard W > 0, H > 0, targetAspect > 0 else { return nil }
        let imgAR = W / H
        // Smallest target-aspect canvas that contains the image (extend one axis).
        let canvasW = Int((imgAR >= targetAspect ? W : (H * targetAspect)).rounded())
        let canvasH = Int((imgAR >= targetAspect ? (W / targetAspect) : H).rounded())
        return composeCanvas(image, canvasWidth: canvasW, canvasHeight: canvasH, fill: fill)
    }

    /// Freeform variant: composites `image` on an explicit canvas size (each
    /// dimension at least the image's, so it never crops). `offsetX`/`offsetY` in
    /// 0…1 position the image within the extra space (0.5 = centered; note the
    /// CGContext origin is bottom-left, so offsetY 0 = bottom).
    static func composeCanvas(_ image: CGImage, canvasWidth: Int, canvasHeight: Int, fill: ResizeFill,
                              offsetX: CGFloat = 0.5, offsetY: CGFloat = 0.5) -> CGImage? {
        let W = CGFloat(image.width), H = CGFloat(image.height)
        let canvasW = CGFloat(max(canvasWidth, image.width)), canvasH = CGFloat(max(canvasHeight, image.height))
        let canvas = CGSize(width: canvasW, height: canvasH)
        let cs = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: Int(canvasW), height: Int(canvasH), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let dx = ((canvasW - W) * min(max(offsetX, 0), 1)).rounded()
        let dy = ((canvasH - H) * min(max(offsetY, 0), 1)).rounded()
        let imgRect = CGRect(x: dx, y: dy, width: W, height: H)

        switch fill {
        case .white, .black:
            ctx.setFillColor((fill == .white ? UIColor.white : .black).cgColor)
            ctx.fill(CGRect(origin: .zero, size: canvas))
        case .blur:
            if let bg = blurredBackground(image, canvas: canvas) { ctx.draw(bg, in: CGRect(origin: .zero, size: canvas)) }
            else { ctx.setFillColor(UIColor.black.cgColor); ctx.fill(CGRect(origin: .zero, size: canvas)) }
        case .mirror:
            ctx.setFillColor(UIColor.black.cgColor); ctx.fill(CGRect(origin: .zero, size: canvas))   // base for any uncovered area
            drawMirrorFill(ctx, image: image, imgRect: imgRect, canvas: canvas)
        }
        ctx.draw(image, in: imgRect)   // the sharp original on top
        return ctx.makeImage()
    }

    /// A grayscale outpaint mask matching a composed canvas: white where new content
    /// should be generated, black over the original's rect (which is preserved).
    /// Same coordinate math as `composeCanvas` so it lines up exactly.
    static func outpaintMask(canvasWidth: Int, canvasHeight: Int, imageWidth: Int, imageHeight: Int,
                             offsetX: CGFloat = 0.5, offsetY: CGFloat = 0.5) -> CGImage? {
        let cw = CGFloat(max(canvasWidth, imageWidth)), ch = CGFloat(max(canvasHeight, imageHeight))
        let W = CGFloat(imageWidth), H = CGFloat(imageHeight)
        guard let ctx = CGContext(data: nil, width: Int(cw), height: Int(ch), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.setFillColor(gray: 1, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: cw, height: ch))   // white = generate
        let dx = ((cw - W) * min(max(offsetX, 0), 1)).rounded(), dy = ((ch - H) * min(max(offsetY, 0), 1)).rounded()
        ctx.setFillColor(gray: 0, alpha: 1); ctx.fill(CGRect(x: dx, y: dy, width: W, height: H))    // black = keep
        return ctx.makeImage()
    }

    /// The original scaled to *fill* the canvas, blurred — the Instasize-style backdrop.
    private static func blurredBackground(_ image: CGImage, canvas: CGSize) -> CGImage? {
        let ci = CIImage(cgImage: image)
        let scale = max(canvas.width / CGFloat(image.width), canvas.height / CGFloat(image.height))
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let dx = (canvas.width - scaled.extent.width) / 2 - scaled.extent.origin.x
        let dy = (canvas.height - scaled.extent.height) / 2 - scaled.extent.origin.y
        let centered = scaled.transformed(by: CGAffineTransform(translationX: dx, y: dy))
        let blurred = centered.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 24])
            .cropped(to: CGRect(origin: .zero, size: canvas))
        return ciContext.createCGImage(blurred, from: CGRect(origin: .zero, size: canvas))
    }

    /// Fills the extended strips by reflecting the image across its edges.
    private static func drawMirrorFill(_ ctx: CGContext, image: CGImage, imgRect: CGRect, canvas: CGSize) {
        let W = imgRect.width, H = imgRect.height
        func clipped(_ rect: CGRect, _ body: () -> Void) {
            ctx.saveGState(); ctx.clip(to: rect); body(); ctx.restoreGState()
        }
        func flipped(_ rect: CGRect, vertical: Bool) {
            ctx.saveGState()
            if vertical { ctx.translateBy(x: 0, y: rect.midY); ctx.scaleBy(x: 1, y: -1); ctx.translateBy(x: 0, y: -rect.midY) }
            else { ctx.translateBy(x: rect.midX, y: 0); ctx.scaleBy(x: -1, y: 1); ctx.translateBy(x: -rect.midX, y: 0) }
            ctx.draw(image, in: rect); ctx.restoreGState()
        }
        if canvas.height > H + 0.5 {            // extended vertically → mirror up & down
            clipped(CGRect(x: 0, y: 0, width: canvas.width, height: imgRect.minY)) {
                flipped(CGRect(x: imgRect.minX, y: imgRect.minY - H, width: W, height: H), vertical: true)
            }
            clipped(CGRect(x: 0, y: imgRect.maxY, width: canvas.width, height: canvas.height - imgRect.maxY)) {
                flipped(CGRect(x: imgRect.minX, y: imgRect.maxY, width: W, height: H), vertical: true)
            }
        } else if canvas.width > W + 0.5 {      // extended horizontally → mirror left & right
            clipped(CGRect(x: 0, y: 0, width: imgRect.minX, height: canvas.height)) {
                flipped(CGRect(x: imgRect.minX - W, y: imgRect.minY, width: W, height: H), vertical: false)
            }
            clipped(CGRect(x: imgRect.maxX, y: 0, width: canvas.width - imgRect.maxX, height: canvas.height)) {
                flipped(CGRect(x: imgRect.maxX, y: imgRect.minY, width: W, height: H), vertical: false)
            }
        }
    }

    /// Fits the photo at `url` to `targetAspect` with an on-device `fill`, in place.
    static func resizeCanvasInPlace(url: URL, targetAspect: CGFloat, fill: ResizeFill) -> Bool {
        resizeCanvasInPlace(url: url, fill: fill) { composeCanvas($0, targetAspect: targetAspect, fill: fill) }
    }

    /// Freeform variant: extends each side by the given factors (>= 1), in place,
    /// with the image positioned by `offsetX`/`offsetY` (0…1).
    static func resizeCanvasInPlace(url: URL, widthFactor: CGFloat, heightFactor: CGFloat, fill: ResizeFill,
                                    offsetX: CGFloat = 0.5, offsetY: CGFloat = 0.5) -> Bool {
        resizeCanvasInPlace(url: url, fill: fill) {
            composeCanvas($0, canvasWidth: Int(CGFloat($0.width) * widthFactor),
                          canvasHeight: Int(CGFloat($0.height) * heightFactor), fill: fill,
                          offsetX: offsetX, offsetY: offsetY)
        }
    }

    /// Loads the full upright photo, lets `compose` build the result, and writes it
    /// back over the original preserving EXIF/GPS (like `applyPhotoInPlace`).
    private static func resizeCanvasInPlace(url: URL, fill: ResizeFill, compose: (CGImage) -> CGImage?) -> Bool {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(src),
              let full = loadFullCGImage(src),
              let out = compose(full) else { return false }

        var props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
        props[kCGImagePropertyOrientation] = 1                       // upright pixels now baked
        props[kCGImagePropertyPixelWidth] = out.width
        props[kCGImagePropertyPixelHeight] = out.height
        if var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1; props[kCGImagePropertyTIFFDictionary] = tiff
        }
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).edit")
        func encode(_ t: CFString) -> Bool {
            guard let dst = CGImageDestinationCreateWithURL(tmp as CFURL, t, 1, nil) else { return false }
            CGImageDestinationAddImage(dst, out, props as CFDictionary)
            return CGImageDestinationFinalize(dst)
        }
        if !encode(type) {
            try? FileManager.default.removeItem(at: tmp)
            guard encode(UTType.jpeg.identifier as CFString) else { try? FileManager.default.removeItem(at: tmp); return false }
        }
        return replaceInPlace(original: url, temp: tmp)
    }

    // MARK: - Video (edit in place, preserving metadata)

    /// Rotates/crops the video at `url` and writes the result back over the original
    /// (same name), carrying over creation date/location metadata. Returns true on
    /// success. Re-encodes via `AVAssetExportSession`, so it's inherently lossy.
    static func exportVideoInPlace(url: URL, quarters: Int, crop: CGRect,
                                   progress: @escaping @Sendable (Double) -> Void) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return false }
        let natural = (try? await track.load(.naturalSize)) ?? .zero
        let pt = (try? await track.load(.preferredTransform)) ?? .identity
        let duration = (try? await asset.load(.duration)) ?? .zero
        let fps = (try? await track.load(.nominalFrameRate)).map { $0 > 0 ? $0 : 30 } ?? 30
        guard natural.width > 0, natural.height > 0, duration.seconds > 0 else { return false }

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

        // Detect the source's HDR transfer function so the rotate/crop re-encode keeps HDR
        // (HLG or PQ/HDR10) instead of tone-mapping it to SDR — otherwise rotating an HDR
        // video silently stripped its HDR. Same handling as `upscaleVideo`.
        var isPQ = false, isHLG = false
        if let fd = (try? await track.load(.formatDescriptions))?.first,
           let ext = CMFormatDescriptionGetExtensions(fd) as? [CFString: Any] {
            let tf = ext[kCMFormatDescriptionExtension_TransferFunction] as? String
            isPQ = tf == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String)
            isHLG = tf == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
        }
        let isHDR = isPQ || isHLG

        let videoComposition = AVMutableVideoComposition()
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(fps.rounded(), 1)))
        videoComposition.renderSize = CGSize(width: cw, height: ch)
        if isHDR {
            videoComposition.colorPrimaries = AVVideoColorPrimaries_ITU_R_2020
            videoComposition.colorTransferFunction = isPQ ? AVVideoTransferFunction_SMPTE_ST_2084_PQ
                                                          : AVVideoTransferFunction_ITU_R_2100_HLG
            videoComposition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_2020
        }
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(full, at: .zero)
        instruction.layerInstructions = [layer]
        videoComposition.instructions = [instruction]

        // Export to a sibling temp file (same volume → atomic replace) in the
        // QuickTime container, then swap it in for the original (which keeps its name).
        // HEVC (10-bit) for HDR so the wide gamut/transfer survives; H.264 otherwise.
        let folder = url.deletingLastPathComponent()
        let tmp = folder.appendingPathComponent(".\(UUID().uuidString).mov")
        let preset = isHDR ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetHighestQuality
        guard let export = AVAssetExportSession(asset: asset, presetName: preset) else { return false }
        export.videoComposition = videoComposition
        export.outputURL = tmp
        export.outputFileType = .mov
        if let md = try? await asset.load(.metadata) { export.metadata = md }   // keep date/location

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
        guard export.status == .completed else { try? FileManager.default.removeItem(at: tmp); return false }
        progress(1)
        let dates = fileDates(of: url)                 // capture before the swap replaces the source
        guard replaceInPlace(original: url, temp: tmp) else { return false }
        restoreFileDates(dates, to: url)               // keep the file's creation/modification stamps
        return true
    }

    enum UpscaleResult: Sendable { case upscaled, skipped, failed }

    /// Upscales a video so its short side is at least `targetShort` px (1080 = 1080p,
    /// 2160 = 4K), preserving aspect and orientation. **HDR is preserved**: when the
    /// source is HLG or PQ (HDR10) the video composition renders in BT.2020 with the
    /// matching transfer function and exports 10-bit HEVC, instead of tone-mapping to
    /// SDR. Capture date and location are read robustly (across container formats) and
    /// re-stamped so they reliably survive the re-encode; all other metadata is carried
    /// across. **Replaces the file in place** — so its path-keyed labels/captions/
    /// Favorite state are kept and the original is gone. Videos already ≥ `targetShort`
    /// are skipped (never downscaled). Lossy by nature, and best-effort.
    static func upscaleVideo(url: URL, targetShort: CGFloat,
                             progress: @escaping @Sendable (Double) -> Void) async -> UpscaleResult {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return .failed }
        let natural = (try? await track.load(.naturalSize)) ?? .zero
        let pt = (try? await track.load(.preferredTransform)) ?? .identity
        let duration = (try? await asset.load(.duration)) ?? .zero
        let fps = (try? await track.load(.nominalFrameRate)).map { $0 > 0 ? $0 : 30 } ?? 30
        guard natural.width > 0, natural.height > 0, duration.seconds > 0 else { return .failed }

        let dispRect = CGRect(origin: .zero, size: natural).applying(pt)
        let dispW = abs(dispRect.width), dispH = abs(dispRect.height)
        let shortSide = min(dispW, dispH)
        guard shortSide > 0 else { return .failed }
        guard shortSide < targetShort else { return .skipped }     // already at/above target — don't downscale
        let scale = targetShort / shortSide
        let targetW = max(2, (dispW * scale / 2).rounded() * 2)    // even dimensions
        let targetH = max(2, (dispH * scale / 2).rounded() * 2)

        // Detect the source's HDR transfer function from its format description.
        var isPQ = false, isHLG = false
        if let fd = (try? await track.load(.formatDescriptions))?.first,
           let ext = CMFormatDescriptionGetExtensions(fd) as? [CFString: Any] {
            let tf = ext[kCMFormatDescriptionExtension_TransferFunction] as? String
            isPQ = tf == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String)
            isHLG = tf == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
        }
        let isHDR = isPQ || isHLG

        let comp = AVMutableVideoComposition()
        comp.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(fps.rounded(), 1)))
        comp.renderSize = CGSize(width: targetW, height: targetH)
        if isHDR {
            // Keep the working/output color space in HDR so it isn't tone-mapped to SDR.
            comp.colorPrimaries = AVVideoColorPrimaries_ITU_R_2020
            comp.colorTransferFunction = isPQ ? AVVideoTransferFunction_SMPTE_ST_2084_PQ
                                              : AVVideoTransferFunction_ITU_R_2100_HLG
            comp.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_2020
        }
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(pt.concatenating(CGAffineTransform(scaleX: scale, y: scale)), at: .zero)
        instruction.layerInstructions = [layer]
        comp.instructions = [instruction]

        // Preserve metadata across containers, then re-stamp the capture date so it
        // reliably survives (it was previously read from common metadata only, which
        // misses videos that carry the date in QuickTime metadata).
        var meta = ((try? await asset.load(.metadata)) ?? [])
            + ((try? await asset.loadMetadata(for: .quickTimeMetadata)) ?? [])
        meta = meta.filter { $0.commonKey != .commonKeyCreationDate
            && $0.identifier != .quickTimeMetadataCreationDate && $0.identifier != .commonIdentifierCreationDate }
        let captureDate = await videoCreationDate(asset)
        if let captureDate {
            let iso = ISO8601DateFormatter().string(from: captureDate)
            for id in [AVMetadataIdentifier.commonIdentifierCreationDate, .quickTimeMetadataCreationDate] {
                let item = AVMutableMetadataItem(); item.identifier = id; item.value = iso as NSString; meta.append(item)
            }
        }

        // The original file's date — used as a fallback so the re-encode never gets
        // stamped with "today" when the source carries no embedded capture date.
        let sourceFileDate: Date? = {
            let a = try? FileManager.default.attributesOfItem(atPath: url.path)
            return (a?[.creationDate] as? Date) ?? (a?[.modificationDate] as? Date)
        }()

        let folder = url.deletingLastPathComponent()
        let tmp = folder.appendingPathComponent(".\(UUID().uuidString).mov")
        // HEVC for HDR (10-bit); HighestQuality (H.264) otherwise.
        let preset = isHDR ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetHighestQuality
        guard let export = AVAssetExportSession(asset: asset, presetName: preset) else { return .failed }
        export.videoComposition = comp
        export.outputURL = tmp
        export.outputFileType = .mov
        export.metadata = meta

        let poll = Task {
            while !Task.isCancelled { progress(Double(export.progress)); try? await Task.sleep(nanoseconds: 200_000_000) }
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { cont.resume() }
        }
        poll.cancel()
        guard export.status == .completed else { try? FileManager.default.removeItem(at: tmp); return .failed }
        progress(1)
        guard replaceInPlace(original: url, temp: tmp) else { return .failed }
        // Stamp the file's dates with the capture date, or the original file's date if
        // the source carried none — never leave it at the re-encode time ("today").
        if let fileDate = captureDate ?? sourceFileDate {
            try? FileManager.default.setAttributes([.creationDate: fileDate, .modificationDate: fileDate], ofItemAtPath: url.path)
        }
        return .upscaled
    }

    /// "AI Enhance & Upscale": upscales so the short side is ≥ `targetShort` *and* runs each
    /// frame through a Core Image enhancement pipeline — light noise reduction to clean up
    /// compression blocking, then an unsharp mask to recover perceived detail — for a sharper,
    /// cleaner result than a plain rescale. SDR only: HDR sources fall back to the standard
    /// `upscaleVideo` so their wide-gamut/transfer isn't tone-mapped to SDR. Replaces the file
    /// in place, preserving metadata, labels, and capture date. Lossy and best-effort.
    static func enhanceVideo(url: URL, targetShort: CGFloat,
                             progress: @escaping @Sendable (Double) -> Void) async -> UpscaleResult {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return .failed }
        let natural = (try? await track.load(.naturalSize)) ?? .zero
        let pt = (try? await track.load(.preferredTransform)) ?? .identity
        let duration = (try? await asset.load(.duration)) ?? .zero
        let fps = (try? await track.load(.nominalFrameRate)).map { $0 > 0 ? $0 : 30 } ?? 30
        guard natural.width > 0, natural.height > 0, duration.seconds > 0 else { return .failed }

        // HDR → standard upscale (Core Image would tone-map the wide gamut/transfer to SDR).
        if let fd = (try? await track.load(.formatDescriptions))?.first,
           let ext = CMFormatDescriptionGetExtensions(fd) as? [CFString: Any] {
            let tf = ext[kCMFormatDescriptionExtension_TransferFunction] as? String
            if tf == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String)
                || tf == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String) {
                return await upscaleVideo(url: url, targetShort: targetShort, progress: progress)
            }
        }

        let dispRect = CGRect(origin: .zero, size: natural).applying(pt)
        let dispW = abs(dispRect.width), dispH = abs(dispRect.height)
        let shortSide = min(dispW, dispH)
        guard shortSide > 0 else { return .failed }
        guard shortSide < targetShort else { return .skipped }     // already at/above target
        let scale = targetShort / shortSide
        let targetW = max(2, (dispW * scale / 2).rounded() * 2)
        let targetH = max(2, (dispH * scale / 2).rounded() * 2)
        let renderSize = CGSize(width: targetW, height: targetH)

        // The convenience initializer hands us display-oriented frames at the natural size; we
        // scale up and enhance, then crop to the target render size.
        let ciContext = CIContext()
        let comp = AVMutableVideoComposition(asset: asset, applyingCIFiltersWithHandler: { request in
            var img = request.sourceImage.clampedToExtent()
            img = img.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            img = img.applyingFilter("CINoiseReduction", parameters: ["inputNoiseLevel": 0.015, "inputSharpness": 0.4])
            img = img.applyingFilter("CIUnsharpMask", parameters: [kCIInputRadiusKey: 2.5, kCIInputIntensityKey: 0.7])
            img = img.cropped(to: CGRect(origin: .zero, size: renderSize))
            request.finish(with: img, context: ciContext)
        })
        comp.renderSize = renderSize
        comp.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(fps.rounded(), 1)))

        // Preserve + re-stamp capture date exactly like upscaleVideo (so Age/year/place survive).
        var meta = ((try? await asset.load(.metadata)) ?? [])
            + ((try? await asset.loadMetadata(for: .quickTimeMetadata)) ?? [])
        meta = meta.filter { $0.commonKey != .commonKeyCreationDate
            && $0.identifier != .quickTimeMetadataCreationDate && $0.identifier != .commonIdentifierCreationDate }
        let captureDate = await videoCreationDate(asset)
        if let captureDate {
            let iso = ISO8601DateFormatter().string(from: captureDate)
            for id in [AVMetadataIdentifier.commonIdentifierCreationDate, .quickTimeMetadataCreationDate] {
                let item = AVMutableMetadataItem(); item.identifier = id; item.value = iso as NSString; meta.append(item)
            }
        }
        let sourceFileDate: Date? = {
            let a = try? FileManager.default.attributesOfItem(atPath: url.path)
            return (a?[.creationDate] as? Date) ?? (a?[.modificationDate] as? Date)
        }()

        let folder = url.deletingLastPathComponent()
        let tmp = folder.appendingPathComponent(".\(UUID().uuidString).mov")
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else { return .failed }
        export.videoComposition = comp
        export.outputURL = tmp
        export.outputFileType = .mov
        export.metadata = meta

        let poll = Task {
            while !Task.isCancelled { progress(Double(export.progress)); try? await Task.sleep(nanoseconds: 200_000_000) }
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { cont.resume() }
        }
        poll.cancel()
        guard export.status == .completed else { try? FileManager.default.removeItem(at: tmp); return .failed }
        progress(1)
        guard replaceInPlace(original: url, temp: tmp) else { return .failed }
        if let fileDate = captureDate ?? sourceFileDate {
            try? FileManager.default.setAttributes([.creationDate: fileDate, .modificationDate: fileDate], ofItemAtPath: url.path)
        }
        return .upscaled
    }

    /// The video's capture date, read across container formats (the synthesized
    /// `.creationDate`, then QuickTime, then common metadata) so it isn't missed.
    private static func videoCreationDate(_ asset: AVURLAsset) async -> Date? {
        func parse(_ s: String) -> Date? {
            ISO8601DateFormatter().date(from: s) ?? {
                let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
                f.dateFormat = "yyyy:MM:dd HH:mm:ss"; return f.date(from: s)
            }()
        }
        if let item = try? await asset.load(.creationDate) {
            if let d = try? await item.load(.dateValue) { return d }
            if let s = try? await item.load(.stringValue), let d = parse(s) { return d }
        }
        let groups = [(try? await asset.loadMetadata(for: .quickTimeMetadata)) ?? [],
                      (try? await asset.load(.metadata)) ?? []]
        for group in groups {
            for item in group where item.identifier == .quickTimeMetadataCreationDate || item.commonKey == .commonKeyCreationDate {
                if let d = try? await item.load(.dateValue) { return d }
                if let s = try? await item.load(.stringValue), let d = parse(s) { return d }
            }
        }
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
