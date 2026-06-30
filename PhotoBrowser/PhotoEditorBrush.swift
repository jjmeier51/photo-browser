import CoreImage
import UIKit

/// A single freehand brush stroke (Facetune-style). Stored normalized + resolution-independent in the
/// recipe so it re-renders identically at proxy preview and full-res export. `intensity` means: smoothing
/// strength / paint opacity / whitening strength (erase is always full). `color` is paint-only.
struct BrushStroke: Codable, Equatable {
    enum Kind: String, Codable { case smooth, paint, teeth, erase }
    var kind: Kind
    var points: [CGPoint]      // normalized, top-left, in the final (post-geometry) frame
    var radius: Double         // fraction of image width
    var intensity: Double      // 0…1
    var color: MakeupColor?    // paint only
}

/// Builds a soft, grayscale coverage mask for one stroke (white = full effect at the stroke's intensity),
/// at `size`. The round brush is feathered so edges blend.
enum BrushMask {
    static func image(for s: BrushStroke, size: CGSize) -> CIImage? {
        guard !s.points.isEmpty, size.width >= 2, size.height >= 2 else { return nil }
        let level = CGFloat(max(0, min(1, s.intensity)))
        let fmt = UIGraphicsImageRendererFormat.default(); fmt.scale = 1; fmt.opaque = true
        let img = UIGraphicsImageRenderer(size: size, format: fmt).image { rctx in
            let ctx = rctx.cgContext
            ctx.setFillColor(UIColor.black.cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
            let gray = UIColor(white: level, alpha: 1)
            ctx.setStrokeColor(gray.cgColor); ctx.setFillColor(gray.cgColor)
            ctx.setLineCap(.round); ctx.setLineJoin(.round)
            let pts = s.points.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
            let w = max(2, CGFloat(s.radius) * size.width * 2)
            if pts.count == 1 {
                ctx.fillEllipse(in: CGRect(x: pts[0].x - w / 2, y: pts[0].y - w / 2, width: w, height: w))
            } else {
                ctx.setLineWidth(w)
                ctx.beginPath(); ctx.move(to: pts[0])
                for p in pts.dropFirst() { ctx.addLine(to: p) }
                ctx.strokePath()
            }
        }
        guard let cg = img.cgImage else { return nil }
        let feather = max(1.0, Double(s.radius) * Double(size.width) * 0.15)
        return CIImage(cgImage: cg)
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: feather])
            .cropped(to: CGRect(origin: .zero, size: size))
    }
}

/// Applies the stored brush strokes in order over the final image (after all other edits, before stickers).
/// The expensive "smoothed" and "whitened" full-frame layers are built once and reused; each stroke just
/// blends its layer in through its own soft mask. Erase restores the pre-brush pixels in its area.
enum BrushRender {
    static func apply(_ image: CIImage, strokes: [BrushStroke]) -> CIImage {
        guard !strokes.isEmpty else { return image }
        let e = image.extent
        guard e.width >= 8, e.height >= 8 else { return image }
        let base = image
        var img = image
        var smoothed: CIImage?
        var whitened: CIImage?
        let W = Double(e.width)
        for s in strokes {
            guard let raw = BrushMask.image(for: s, size: e.size) else { continue }
            let mask = raw.transformed(by: CGAffineTransform(translationX: e.minX, y: e.minY))
            switch s.kind {
            case .paint:
                guard let c = s.color else { continue }
                let layer = CIImage(color: CIColor(red: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b)))
                    .cropped(to: e)
                img = layer.applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputBackgroundImageKey: img, kCIInputMaskImageKey: mask]).cropped(to: e)
            case .smooth:
                if smoothed == nil { smoothed = makeSmoothed(base, width: W).cropped(to: e) }
                img = smoothed!.applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputBackgroundImageKey: img, kCIInputMaskImageKey: mask]).cropped(to: e)
            case .teeth:
                if whitened == nil { whitened = makeWhitened(base).cropped(to: e) }
                img = whitened!.applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputBackgroundImageKey: img, kCIInputMaskImageKey: mask]).cropped(to: e)
            case .erase:
                img = base.applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputBackgroundImageKey: img, kCIInputMaskImageKey: mask]).cropped(to: e)
            }
        }
        return img
    }

    /// Skin smoothing: a median pass to kill speckle + a gentle blur to remove pores/roughness. Applied
    /// only where brushed (and scaled by the stroke's intensity), so it never goes plastic over the face.
    private static func makeSmoothed(_ image: CIImage, width W: Double) -> CIImage {
        let e = image.extent
        let median = image.applyingFilter("CIMedianFilter").cropped(to: e)
        return median.applyingFilter("CIGaussianBlur",
                                     parameters: [kCIInputRadiusKey: max(2.0, W * 0.006)]).cropped(to: e)
    }

    /// Teeth whitening: cool the warm/yellow cast, drop saturation, lift brightness.
    private static func makeWhitened(_ image: CIImage) -> CIImage {
        let e = image.extent
        return image
            .applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: 7400, y: -8)])
            .applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: 0.07, kCIInputSaturationKey: 0.55])
            .cropped(to: e)
    }
}
