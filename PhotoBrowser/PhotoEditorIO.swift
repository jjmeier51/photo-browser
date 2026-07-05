import CoreImage
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Image load + **metadata-preserving, non-destructive save** for the editor (PRD §5). This is the
/// *only* component that writes edited image files, so the preservation guarantee lives in one place.
///
/// Save path: read the original's full properties dictionary, render the edited pixels, then write
/// with `CGImageDestination` copying those properties — so **all EXIF (incl. `DateTimeOriginal`),
/// TIFF (`DateTime`), GPS, IPTC and color profile survive, and the capture date is unchanged**. The
/// edited pixels are baked upright, so the orientation tag is reset to 1 (applied exactly once,
/// PRD §5.3). The original file is never modified — output goes to a new file.
enum PhotoEditorIO {
    /// One shared GPU context for previews + export (creating a `CIContext` per render is costly).
    static let context = CIContext(options: [.useSoftwareRenderer: false])

    enum ExportFormat: String, CaseIterable, Identifiable {
        case heic, jpeg, png
        var id: String { rawValue }
        var label: String { rawValue.uppercased() }
        var ext: String { self == .jpeg ? "jpg" : rawValue }
        var utType: CFString {
            switch self {
            case .heic: return UTType.heic.identifier as CFString
            case .jpeg: return UTType.jpeg.identifier as CFString
            case .png:  return UTType.png.identifier as CFString
            }
        }
    }

    /// Optional output upscaling applied at save time. `x2` adds light denoise + sharpening (the app's
    /// "AI Upscale" recipe) on top of the high-quality Lanczos resample.
    enum Upscale { case none, x1_5, x2 }

    static func upscaled(_ image: CIImage, _ option: Upscale) -> CIImage {
        switch option {
        case .none:
            return image
        case .x1_5:
            return lanczos(image, 1.5)
        case .x2:
            let scaled = lanczos(image, 2.0)
            return scaled
                .applyingFilter("CINoiseReduction", parameters: ["inputNoiseLevel": 0.012, "inputSharpness": 0.4])
                .applyingFilter("CIUnsharpMask", parameters: [kCIInputRadiusKey: 2.0, kCIInputIntensityKey: 0.5])
                .cropped(to: scaled.extent)
        }
    }

    private static func lanczos(_ image: CIImage, _ scale: CGFloat) -> CIImage {
        image.applyingFilter("CILanczosScaleTransform",
                             parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1.0])
    }

    /// Loads the source upright (EXIF orientation applied to the pixels) along with its full
    /// properties dictionary and the original orientation tag.
    static func load(url: URL) -> (image: CIImage, properties: [CFString: Any], orientation: Int32)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let ci = CIImage(contentsOf: url) else { return nil }
        let props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
        let orientation = Int32((props[kCGImagePropertyOrientation] as? UInt32) ?? 1)
        return (ci.oriented(forExifOrientation: orientation), props, orientation)
    }

    /// A downscaled copy for the live preview proxy (PRD FR-SESS-01 — interactive framerates).
    static func proxy(_ image: CIImage, maxDimension: CGFloat) -> CIImage {
        let longSide = max(image.extent.width, image.extent.height)
        guard longSide > maxDimension, longSide > 0 else { return image }
        let s = maxDimension / longSide
        return image.transformed(by: CGAffineTransform(scaleX: s, y: s))
    }

    /// Renders a (proxy or full) CIImage through `recipe` and turns it into a `UIImage` for display.
    /// Pass `mask` (subject mask) when `recipe.cutout` is set and `landmarks` when body shaping is used.
    static func renderUIImage(_ source: CIImage, recipe: EditRecipe, mask: CIImage? = nil,
                              landmarks: EditLandmarks? = nil, fast: Bool = false) -> UIImage? {
        let out = EditPipeline.render(source, recipe: recipe, mask: mask, landmarks: landmarks, fast: fast)
        guard !out.extent.isInfinite, !out.extent.isNull,
              let cg = context.createCGImage(out, from: out.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// Renders the edit at **full resolution** and writes it to `destURL` (a new file — the original
    /// at `sourceURL` is never touched), preserving all metadata + the capture date. Off-main safe.
    /// When `recipe.cutout` is set, the subject mask is computed here at full resolution.
    static func save(recipe: EditRecipe, sourceURL: URL, to destURL: URL,
                     format: ExportFormat = .heic, quality: Double = 0.92,
                     upscale: Upscale = .none, stickers: [EditSticker] = [],
                     retouch: [RetouchStroke] = []) -> Bool {
        // HDR retention: only when the *output* is HEIC (HEIC-family/RAW source) and the
        // source genuinely carries HDR — write a 10-bit HDR HEIC keeping the headroom.
        // Never for PNG/JPEG outputs: the container must match the source, and writing
        // HEIC bytes behind a .png/.jpg name produced mislabeled files.
        if format == .heic, isHDRSource(sourceURL),
           saveHDR(recipe: recipe, sourceURL: sourceURL, to: destURL, upscale: upscale,
                   stickers: stickers, retouch: retouch) {
            return true
        }

        guard let loaded = load(url: sourceURL) else { return false }
        let source = inpaintIfNeeded(loaded.image, retouch)    // object removal before everything else
        // The subject mask is needed for the cut-out and to confine body shaping to the subject.
        let needsMask = recipe.cutout != nil || !recipe.body.isZero || (recipe.filterBackgroundOnly && recipe.filterID != nil) || recipe.skinTone != 0
        let mask = needsMask ? PhotoEditorCutout.subjectMask(for: source) : nil
        let landmarks = detectLandmarks(for: recipe, in: source)
        let rendered = upscaled(EditPipeline.render(source, recipe: recipe, mask: mask,
                                                    landmarks: landmarks, stickers: stickers), upscale)
        guard !rendered.extent.isInfinite, !rendered.extent.isNull,
              let cg = context.createCGImage(rendered, from: rendered.extent) else { return false }

        // Copy the original properties; the pixels are now upright + edited, so reset orientation
        // and refresh the stored dimensions. Dates / GPS / IPTC / maker notes are carried untouched.
        var props = loaded.properties
        props[kCGImagePropertyOrientation] = 1
        props[kCGImagePropertyPixelWidth] = cg.width
        props[kCGImagePropertyPixelHeight] = cg.height
        if var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            props[kCGImagePropertyTIFFDictionary] = tiff
        }
        if format != .png { props[kCGImageDestinationLossyCompressionQuality as CFString] = quality }

        let tmp = destURL.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).edit")
        guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, format.utType, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        guard CGImageDestinationFinalize(dest),
              CGImageSourceCreateWithURL(tmp as CFURL, nil).flatMap({ CGImageSourceCreateImageAtIndex($0, 0, nil) }) != nil
        else { try? FileManager.default.removeItem(at: tmp); return false }

        try? FileManager.default.removeItem(at: destURL)
        do { try FileManager.default.moveItem(at: tmp, to: destURL) }
        catch { try? FileManager.default.removeItem(at: tmp); return false }

        copyFileDates(from: sourceURL, to: destURL)   // keep the browser's timeline stable
        return true
    }

    /// Applies object-removal inpainting to `image` if there are retouch strokes (else returns it).
    /// One stroke at a time, each in its own tight working window — a combined mask
    /// made distant removals share one giant window (union bbox), dropping the fill
    /// resolution and re-synthesizing earlier, unrelated areas.
    static func inpaintIfNeeded(_ image: CIImage, _ retouch: [RetouchStroke]) -> CIImage {
        var out = image
        for stroke in retouch {
            if let mask = RetouchMask.image(for: [stroke], size: out.extent.size) {
                out = ObjectRemoval.inpaint(out, mask: mask)
            }
        }
        return out
    }

    /// Detects whichever landmark sets the recipe needs (body shaping and/or makeup). Off-main,
    /// resolution-independent.
    static func detectLandmarks(for recipe: EditRecipe, in image: CIImage) -> EditLandmarks? {
        let needBody = recipe.body.hasBodyEdit
        let needFace = recipe.body.hasFaceEdit || !recipe.makeup.isZero
        guard needBody || needFace else { return nil }
        let lm = EditLandmarks(body: needBody ? BodyPose.detect(in: image) : nil,
                               face: needFace ? FaceDetect.detect(in: image) : nil)
        return lm.isEmpty ? nil : lm
    }

    // MARK: - HDR

    /// True when the file carries HDR worth preserving: an Apple/ISO HDR gain map, a PQ/HLG (BT.2100)
    /// profile, or a RAW file (whose scene data exceeds 8-bit). Such sources take the 10-bit save path.
    static func isHDRSource(_ url: URL) -> Bool {
        if let type = UTType(filenameExtension: url.pathExtension.lowercased()), type.conforms(to: .rawImage) {
            return true
        }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        if CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, kCGImageAuxiliaryDataTypeHDRGainMap) != nil { return true }
        if #available(iOS 18.0, *),
           CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, kCGImageAuxiliaryDataTypeISOGainMap) != nil { return true }
        if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            let name = ((props[kCGImagePropertyProfileName] as? String) ?? "").uppercased()
            // PQ/HLG/BT.2100 are HDR *transfer functions*. Plain "2020" is deliberately
            // NOT matched — BT.2020 is just a gamut, and SDR files tagged with it were
            // being misdetected as HDR (and saved as HDR HEIC).
            if name.contains("PQ") || name.contains("HLG") || name.contains("2100") {
                return true
            }
        }
        return false
    }

    /// Loads the source **expanded to HDR** (gain map applied, extended range), upright, with its props.
    private static func loadHDR(url: URL) -> (image: CIImage, properties: [CFString: Any])? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let ci = CIImage(contentsOf: url, options: [.expandToHDR: true]) else { return nil }
        let props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
        let orientation = Int32((props[kCGImagePropertyOrientation] as? UInt32) ?? 1)
        return (ci.oriented(forExifOrientation: orientation), props)
    }

    /// Renders the edit on the HDR-expanded source and writes a 10-bit HDR HEIC, carrying the original
    /// metadata + capture date. Returns false so the caller can fall back to the standard SDR path.
    private static func saveHDR(recipe: EditRecipe, sourceURL: URL, to destURL: URL,
                                upscale: Upscale = .none, stickers: [EditSticker] = [],
                                retouch: [RetouchStroke] = []) -> Bool {
        guard let loaded = loadHDR(url: sourceURL) else { return false }
        let source = inpaintIfNeeded(loaded.image, retouch)
        // Vision (subject mask + face/body landmarks) expects standard-range pixels. The HDR-expanded
        // source carries extended-range values (>1.0) that degrade face detection — which scatters makeup
        // overlays across the frame and reads as a blown-out, oversaturated result. Detect on a clamped
        // SDR copy, but render on the real HDR `source` so the headroom survives in the output.
        let visionSrc = source.applyingFilter("CIColorClamp").cropped(to: source.extent)
        let needsMask = recipe.cutout != nil || !recipe.body.isZero || (recipe.filterBackgroundOnly && recipe.filterID != nil) || recipe.skinTone != 0
        let mask = needsMask ? PhotoEditorCutout.subjectMask(for: visionSrc) : nil
        let landmarks = detectLandmarks(for: recipe, in: visionSrc)
        let rendered = upscaled(EditPipeline.render(source, recipe: recipe, mask: mask,
                                                    landmarks: landmarks, stickers: stickers, hdr: true), upscale)
        guard !rendered.extent.isInfinite, !rendered.extent.isNull else { return false }

        var props = loaded.properties
        props[kCGImagePropertyOrientation] = 1
        props[kCGImagePropertyPixelWidth] = Int(rendered.extent.width.rounded())
        props[kCGImagePropertyPixelHeight] = Int(rendered.extent.height.rounded())
        if var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            props[kCGImagePropertyTIFFDictionary] = tiff
        }
        // CIImage properties are string-keyed; embed them so EXIF/GPS/dates survive the HDR encode.
        let stringProps = Dictionary(props.map { ($0.key as String, $0.value) }, uniquingKeysWith: { a, _ in a })
        let withMeta = rendered.settingProperties(stringProps)

        // A PQ-encoded wide-gamut space holds the headroom for the 10-bit HEIC.
        let outSpace = CGColorSpace(name: CGColorSpace.displayP3_PQ) ?? loaded.image.colorSpace
            ?? CGColorSpaceCreateDeviceRGB()
        guard let data = try? context.heif10Representation(of: withMeta, colorSpace: outSpace, options: [:])
        else { return false }

        let tmp = destURL.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).edit")
        do { try data.write(to: tmp) } catch { return false }
        guard CGImageSourceCreateWithURL(tmp as CFURL, nil) != nil else {
            try? FileManager.default.removeItem(at: tmp); return false
        }
        try? FileManager.default.removeItem(at: destURL)
        do { try FileManager.default.moveItem(at: tmp, to: destURL) }
        catch { try? FileManager.default.removeItem(at: tmp); return false }
        copyFileDates(from: sourceURL, to: destURL)
        return true
    }

    /// Copies the original's file creation/modification dates onto the edited file.
    private static func copyFileDates(from sourceURL: URL, to destURL: URL) {
        guard let a = try? FileManager.default.attributesOfItem(atPath: sourceURL.path) else { return }
        var set: [FileAttributeKey: Any] = [:]
        if let c = a[.creationDate] { set[.creationDate] = c }
        if let m = a[.modificationDate] { set[.modificationDate] = m }
        if !set.isEmpty { try? FileManager.default.setAttributes(set, ofItemAtPath: destURL.path) }
    }

    /// Picks an export format matching the source: PNG stays PNG, JPEG stays JPEG.
    /// Only HEIC-family sources — and RAW, whose scene data needs the 10-bit path —
    /// map to HEIC. Anything else (webp/tiff/bmp/…) exports as JPEG, so an SDR
    /// source can never come back as an HDR HEIC.
    static func format(forSource url: URL) -> ExportFormat {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "png":                  return .png
        case "jpg", "jpeg":          return .jpeg
        case "heic", "heif", "avif": return .heic
        default:
            if UTType(filenameExtension: ext)?.conforms(to: .rawImage) == true { return .heic }
            return .jpeg
        }
    }

    /// Mean luminance (0…1) of `image`, used by the one-tap Auto to decide how to nudge exposure.
    static func averageLuma(of image: CIImage) -> Double {
        guard !image.extent.isInfinite, !image.extent.isNull else { return 0.5 }
        let avg = image.applyingFilter("CIAreaAverage",
                                       parameters: [kCIInputExtentKey: CIVector(cgRect: image.extent)])
        var px = [UInt8](repeating: 0, count: 4)
        context.render(avg, toBitmap: &px, rowBytes: 4,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return (0.2126 * Double(px[0]) + 0.7152 * Double(px[1]) + 0.0722 * Double(px[2])) / 255.0
    }

    /// A tasteful one-tap enhancement (PRD FR-ADJ-02). Keeps the recipe's geometry/filter, replaces
    /// the tone/color with values derived from the image's average brightness.
    static func autoRecipe(for image: CIImage, base: EditRecipe) -> EditRecipe {
        var r = base
        let luma = averageLuma(of: image)
        r.exposure = max(-0.4, min(0.5, (0.5 - luma) * 1.1))
        r.contrast = 0.12
        r.vibrance = 0.22
        r.shadows = luma < 0.40 ? 0.25 : 0.10
        r.highlights = luma > 0.65 ? -0.20 : 0.0
        r.sharpen = max(r.sharpen, 0.15)
        return r
    }

    /// A new, non-colliding URL beside `source` for the edited copy (e.g. "Photo edited.heic").
    static func editedDestination(for source: URL, format: ExportFormat) -> URL {
        let dir = source.deletingLastPathComponent()
        let base = source.deletingPathExtension().lastPathComponent
        var candidate = dir.appendingPathComponent("\(base) edited.\(format.ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base) edited \(n).\(format.ext)"); n += 1
        }
        return candidate
    }
}
