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
    static func renderUIImage(_ source: CIImage, recipe: EditRecipe) -> UIImage? {
        let out = EditPipeline.render(source, recipe: recipe)
        guard out.extent.isFinite, !out.extent.isInfinite,
              let cg = context.createCGImage(out, from: out.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// Renders the edit at **full resolution** and writes it to `destURL` (a new file — the original
    /// at `sourceURL` is never touched), preserving all metadata + the capture date. Off-main safe.
    static func save(recipe: EditRecipe, sourceURL: URL, to destURL: URL,
                     format: ExportFormat = .heic, quality: Double = 0.92) -> Bool {
        guard let loaded = load(url: sourceURL) else { return false }
        let rendered = EditPipeline.render(loaded.image, recipe: recipe)
        guard rendered.extent.isFinite, !rendered.extent.isInfinite,
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

        // Keep the browser's timeline stable: copy the original's file creation/modification dates.
        if let a = try? FileManager.default.attributesOfItem(atPath: sourceURL.path) {
            var set: [FileAttributeKey: Any] = [:]
            if let c = a[.creationDate] { set[.creationDate] = c }
            if let m = a[.modificationDate] { set[.modificationDate] = m }
            if !set.isEmpty { try? FileManager.default.setAttributes(set, ofItemAtPath: destURL.path) }
        }
        return true
    }

    /// Picks an export format matching the source so an edited JPEG stays a JPEG, etc. (HEIC default).
    static func format(forSource url: URL) -> ExportFormat {
        switch url.pathExtension.lowercased() {
        case "png":         return .png
        case "jpg", "jpeg": return .jpeg
        default:            return .heic
        }
    }

    /// Mean luminance (0…1) of `image`, used by the one-tap Auto to decide how to nudge exposure.
    static func averageLuma(of image: CIImage) -> Double {
        guard image.extent.isFinite, !image.extent.isInfinite else { return 0.5 }
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
