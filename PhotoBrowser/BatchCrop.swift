import SwiftUI
import UIKit
import ImageIO

/// Batch crop: one crop (and, optionally, a quarter turn) chosen on a photo and put on every selected
/// photo, each written **in place** (`MediaEditing.applyPhotoInPlace` — EXIF, capture date, HDR and the
/// tags the file carries all stay). Every photo that comes out cropped gets the "cropped" tag, the one
/// the crop was drawn on included. The crop is kept as fractions of the photo, so it lands on the same
/// spot of photos of another size; a fixed-ratio crop (1:1, 4:5…) also keeps its own shape on photos
/// shaped differently from the one it was drawn on (`CropSpec.rect(forWidth:height:)`).
///
/// The last crop saved here, in the Edit screen or in the photo editor is remembered
/// (`Library.lastCrop`), so "Last Crop" can put a crop made earlier on one photo onto others.
/// Mac twin: Safe Finder's Crop window (`mac/batch_crop.py`) — same fractions, same tag.

/// A crop that can be put on other photos: the turn, then a normalized **top-left** rect within the
/// turned photo — the same convention as `MediaEditing.applyPhotoInPlace` and `EditRecipe.cropRect`.
nonisolated struct CropSpec: Codable, Equatable, Sendable {
    static let croppedTag = "cropped"
    static let full = CGRect(x: 0, y: 0, width: 1, height: 1)

    var quarters: Int
    var rect: CGRect
    /// The size of the photo the crop was drawn on, after the turn — only its shape matters.
    var refWidth: Double
    var refHeight: Double
    /// A fixed ratio was chosen: on a photo shaped differently, keep the crop's own ratio.
    var keepsShape: Bool
    /// The photo it was drawn on, for the "Last Crop" label.
    var source: String?

    /// True when the rect trims something off (an untouched box, or one off by a rounding, doesn't).
    var trims: Bool { Self.isTrim(rect) }
    /// True when saving it changes the photo at all.
    var changes: Bool { trims || ((quarters % 4) + 4) % 4 != 0 }

    static func isTrim(_ r: CGRect) -> Bool {
        let e: CGFloat = 0.004
        return !(r.minX <= e && r.minY <= e && r.maxX >= 1 - e && r.maxY >= 1 - e)
    }

    /// The crop for a photo of `w`×`h` (after the turn): the same fractions of each side — or, when
    /// `keepsShape` and the photo isn't shaped like the reference, a rect of the crop's own pixel
    /// ratio, centered on the same spot, as tall (or as wide) as the fractions allow, kept inside.
    func rect(forWidth w: Double, height h: Double) -> CGRect {
        let r = rect.intersection(Self.full)
        guard !r.isNull, r.width > 0, r.height > 0 else { return Self.full }
        guard keepsShape, w > 0, h > 0, refWidth > 0, refHeight > 0 else { return r }
        let refRatio = refWidth / refHeight
        if abs(w / h - refRatio) / refRatio < 0.01 { return r }
        let rw = Double(r.width), rh = Double(r.height)
        let want = (rw * refWidth) / (rh * refHeight)        // the crop's pixel w/h
        var pw = rw * w, ph = rh * h
        if pw / ph > want { pw = ph * want } else { ph = pw / want }
        if pw > w { pw = w; ph = pw / want }
        if ph > h { ph = h; pw = ph * want }
        let x = min(max(Double(r.midX) * w - pw / 2, 0), w - pw)
        let y = min(max(Double(r.midY) * h - ph / 2, 0), h - ph)
        return CGRect(x: x / w, y: y / h, width: pw / w, height: ph / h)
    }

    /// `r` turned with its photo: one quarter clockwise (`step` 1) or counter-clockwise (−1).
    static func turned(_ r: CGRect, by step: Int) -> CGRect {
        step > 0 ? CGRect(x: 1 - r.maxY, y: r.minX, width: r.height, height: r.width)
                 : CGRect(x: r.minY, y: 1 - r.maxX, width: r.height, height: r.width)
    }
}

/// The pixel work, off the main actor.
nonisolated enum BatchCrop {
    /// The photo's pixel size as it displays (EXIF orientation applied); nil when it can't be read.
    static func uprightSize(of url: URL) -> CGSize? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = (p[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let h = (p[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              w > 0, h > 0 else { return nil }
        let o = (p[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return (5...8).contains(o) ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    /// Photos the Crop screen takes: not a GIF (it would lose its animation) or a RAW (it can't be
    /// written back as RAW).
    static func canCrop(_ url: URL) -> Bool {
        url.pathExtension.lowercased() != "gif" && !PhotoEditorIO.isRAWSource(url)
    }

    /// Turns and crops one photo in place with `spec`. False when it couldn't be read or saved (the
    /// original is untouched then).
    static func apply(_ spec: CropSpec, to url: URL) -> Bool {
        guard let size = uprightSize(of: url) else { return false }
        let odd = spec.quarters % 2 != 0
        let crop = spec.rect(forWidth: Double(odd ? size.height : size.width),
                             height: Double(odd ? size.width : size.height))
        return MediaEditing.applyPhotoInPlace(url: url, quarters: spec.quarters, crop: crop)
    }
}

/// The Crop screen: the crop box over one photo of the selection (tap another in the strip to see the
/// same crop on it), Freeform / Original / fixed ratios, quarter turns, and "Last Crop". "Crop All"
/// writes every photo in place and tags them "cropped".
struct BatchCropView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(Library.self) private var library
    let photos: [Entry]
    var onDone: () -> Void = {}

    @State private var current = 0
    @State private var upright: UIImage?        // the shown photo as it displays
    @State private var image: UIImage?          // `upright` turned by `quarters` — what the box sits on
    @State private var loadFailed = false
    @State private var quarters = 0
    @State private var box = CropSpec.full
    @State private var aspect: EditAspect = .freeform
    @State private var keepShape = false
    @State private var working = false
    @State private var finished = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ZStack {
                    Color.black
                    if let image {
                        ZStack {
                            Image(uiImage: image).resizable().scaledToFit()
                            CropOverlay(box: $box, imageSize: image.size, normalizedRatio: constraint, onBegin: {})
                        }
                        .padding(16)
                        .allowsHitTesting(!working)
                    } else if loadFailed {
                        ContentUnavailableView("Couldn’t open this photo", systemImage: "exclamationmark.triangle")
                    } else {
                        ProgressView().tint(.white)
                    }
                    if working { progressCard }
                }
                if photos.count > 1 {
                    Text("The same crop goes on all \(photos.count) photos — tap one below to check it.")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.top, 8)
                }
                controls.padding(.vertical, 10)
                if photos.count > 1 { strip.padding(.bottom, 8) }
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle(photos.count == 1 ? "Crop" : "Crop \(photos.count) Photos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(working)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(photos.count == 1 ? "Crop" : "Crop All") { run() }
                        .bold()
                        .disabled(working || image == nil || !spec.changes)
                }
            }
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(working)
        .task(id: current) { await show(current) }
    }

    // MARK: Parts

    private var controls: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                chip("rotate.left", "Left", selected: false) { turn(-1) }
                chip("rotate.right", "Right", selected: false) { turn(1) }
                if let last = library.lastCrop {
                    chip("clock.arrow.circlepath", "Last Crop", selected: false) { useLastCrop(last) }
                }
                Divider().frame(height: 44).overlay(Color.white.opacity(0.2))
                ForEach(EditAspect.allCases) { a in
                    chip(a.systemImage, a.label, selected: aspect == a) { applyAspect(a) }
                }
            }
            .padding(.horizontal)
        }
        .disabled(working || image == nil)
    }

    private func chip(_ icon: String, _ label: String, selected: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 18))
                    .frame(width: 50, height: 50)
                    .background(Circle().fill(Color.white.opacity(selected ? 0.22 : 0.08)))
                    .overlay(Circle().stroke(selected ? Color.white : .clear, lineWidth: 1.5))
                Text(label).font(.caption2)
            }
            .foregroundStyle(selected ? Color.white : Color.secondary)
        }
    }

    private var strip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 6) {
                ForEach(Array(photos.enumerated()), id: \.element.id) { i, e in
                    CropStripThumb(entry: e, selected: i == current)
                        .onTapGesture { if !working { current = i } }
                }
            }
            .padding(.horizontal, 12)
        }
        .frame(height: 60)
    }

    private var progressCard: some View {
        VStack(spacing: 12) {
            Text(photos.count == 1 ? "Cropping…" : "Cropping \(min(finished + 1, photos.count)) of \(photos.count)…")
                .font(.subheadline.weight(.medium))
            ProgressView(value: Double(finished), total: Double(max(photos.count, 1)))
                .progressViewStyle(.linear).frame(width: 220)
        }
        .padding(24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: Crop state

    /// The crop as drawn on the shown photo.
    private var spec: CropSpec {
        CropSpec(quarters: quarters, rect: box,
                 refWidth: Double(image?.size.width ?? 1), refHeight: Double(image?.size.height ?? 1),
                 keepsShape: keepShape, source: photos.indices.contains(current) ? photos[current].name : nil)
    }

    /// The normalized w/h the box keeps (nil = Freeform; 1 = the photo's own ratio).
    private var constraint: CGFloat? {
        guard let image, image.size.width > 0, image.size.height > 0 else { return nil }
        switch aspect {
        case .freeform: return nil
        case .original: return 1
        default:        return (aspect.fixedRatio ?? 1) / (image.size.width / image.size.height)
        }
    }

    /// Shows photo `i`, carrying the crop over from the one shown before.
    private func show(_ i: Int) async {
        guard photos.indices.contains(i) else { return }
        let decoded = await ZoomableImageView.decode(url: photos[i].url, maxPixel: 1600, fullQuality: true)
        guard !Task.isCancelled else { return }
        guard let decoded else { loadFailed = true; image = nil; return }
        let before: CropSpec? = image == nil ? nil : spec
        loadFailed = false
        upright = decoded
        let turned = Self.turnedImage(decoded, quarters)
        if let before { box = before.rect(forWidth: Double(turned.size.width), height: Double(turned.size.height)) }
        image = turned
    }

    private func turn(_ step: Int) {
        guard let upright else { return }
        quarters = (((quarters + step) % 4) + 4) % 4
        let b = box
        image = Self.turnedImage(upright, quarters)
        if aspect == .freeform { box = CropSpec.turned(b, by: step) } else { applyAspect(aspect) }
    }

    /// Original clears the box (and keeps the photo's ratio while dragging); a fixed ratio sets the
    /// largest centered box of that ratio; Freeform keeps the box and lets any side move.
    private func applyAspect(_ a: EditAspect) {
        aspect = a
        keepShape = a.fixedRatio != nil
        switch a {
        case .freeform: break
        case .original: box = CropSpec.full
        default:
            guard let r = a.fixedRatio, let image, image.size.width > 0, image.size.height > 0 else { return }
            let nr = r / (image.size.width / image.size.height)
            box = nr >= 1 ? CGRect(x: 0, y: (1 - 1 / nr) / 2, width: 1, height: 1 / nr)
                          : CGRect(x: (1 - nr) / 2, y: 0, width: nr, height: 1)
        }
    }

    /// Puts the remembered crop on the shown photo (Freeform, so it can be adjusted from there).
    private func useLastCrop(_ last: CropSpec) {
        guard let upright else { return }
        quarters = ((last.quarters % 4) + 4) % 4
        let turned = Self.turnedImage(upright, quarters)
        image = turned
        aspect = .freeform
        keepShape = last.keepsShape
        box = last.rect(forWidth: Double(turned.size.width), height: Double(turned.size.height))
        Haptics.selection()
    }

    /// `img` turned clockwise by `q` quarters, drawn at scale 1 (the screen's 3× would make a 1600-px
    /// preview tens of megabytes).
    private static func turnedImage(_ img: UIImage, _ q: Int) -> UIImage {
        let q = ((q % 4) + 4) % 4
        guard q != 0 else { return img }
        let size = q % 2 == 1 ? CGSize(width: img.size.height, height: img.size.width) : img.size
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let c = ctx.cgContext
            c.translateBy(x: size.width / 2, y: size.height / 2)
            c.rotate(by: CGFloat(q) * .pi / 2)
            img.draw(in: CGRect(x: -img.size.width / 2, y: -img.size.height / 2,
                                width: img.size.width, height: img.size.height))
        }
    }

    // MARK: Save

    private func run() {
        let spec = self.spec
        let urls = photos.map(\.url)
        working = true; finished = 0
        let bg = BackgroundTaskHolder()
        bg.begin(name: "Crop Photos")   // best-effort: keep going if the app is backgrounded
        Task {
            var done: [URL] = []
            var failed: [String] = []
            for url in urls {
                let ok = await Task.detached(priority: .userInitiated) { BatchCrop.apply(spec, to: url) }.value
                if ok { done.append(url) } else { failed.append(url.lastPathComponent) }
                finished += 1
            }
            bg.end()
            if spec.trims {
                library.addTag(CropSpec.croppedTag, to: done)
                library.rememberCrop(spec)
            }
            library.contentDidChange(underFolders: Array(Set(urls.map { $0.deletingLastPathComponent() })))
            working = false
            let verb = spec.trims ? "Cropped" : "Turned"
            if failed.isEmpty {
                library.showToast("\(verb) \(done.count) photo\(done.count == 1 ? "" : "s")")
            } else {
                let names = failed.prefix(5).joined(separator: ", ") + (failed.count > 5 ? "…" : "")
                library.postNotice("Some Photos Weren’t Cropped",
                                   "\(verb) \(done.count) of \(urls.count). These couldn’t be read or saved: \(names)")
            }
            onDone()
            dismiss()
        }
    }
}

/// One photo in the Crop screen's strip.
private struct CropStripThumb: View {
    let entry: Entry
    let selected: Bool
    @State private var thumb: UIImage?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        ZStack {
            Color.white.opacity(0.08)
            if let thumb { Image(uiImage: thumb).resizable().scaledToFill() }
        }
        .frame(width: 52, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Color.white : .clear, lineWidth: 2))
        .task(id: entry.url) {
            thumb = await Thumbnailer.shared.thumbnail(for: entry, size: CGSize(width: 52, height: 52), scale: displayScale)
        }
    }
}
