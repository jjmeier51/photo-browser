import UIKit
import CoreImage

/// One brushed retouch stroke: a polyline (normalized, top-left) and a brush radius (fraction of image
/// width). Strokes are stored so the mask can be rebuilt at any resolution (proxy preview vs full-res
/// save).
struct RetouchStroke: Sendable {
    let points: [CGPoint]
    let radius: CGFloat
}

enum RetouchMask {
    /// A black/white removal mask (white = remove) at `size`, painted from the strokes.
    static func image(for strokes: [RetouchStroke], size: CGSize) -> CIImage? {
        guard !strokes.isEmpty, size.width >= 2, size.height >= 2 else { return nil }
        let fmt = UIGraphicsImageRendererFormat.default(); fmt.scale = 1; fmt.opaque = true
        let img = UIGraphicsImageRenderer(size: size, format: fmt).image { rctx in
            let ctx = rctx.cgContext
            ctx.setFillColor(UIColor.black.cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
            ctx.setStrokeColor(UIColor.white.cgColor); ctx.setFillColor(UIColor.white.cgColor)
            ctx.setLineCap(.round); ctx.setLineJoin(.round)
            for s in strokes {
                let pts = s.points.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
                let w = max(2, s.radius * size.width * 2)
                guard let first = pts.first else { continue }
                if pts.count == 1 {
                    ctx.fillEllipse(in: CGRect(x: first.x - w / 2, y: first.y - w / 2, width: w, height: w))
                } else {
                    ctx.setLineWidth(w)
                    ctx.beginPath(); ctx.move(to: first)
                    for p in pts.dropFirst() { ctx.addLine(to: p) }
                    ctx.strokePath()
                }
            }
        }
        return img.cgImage.map { CIImage(cgImage: $0) }
    }
}

/// On-device "magic" object removal (TouchRetouch-style) via coarse-to-fine diffusion inpainting:
/// surrounding pixels are propagated into the masked hole at decreasing blur radii. Only the masked
/// region changes — the rest of the image is the untouched original at full resolution. Clean on smooth
/// or gently-textured backgrounds (sky, wall, skin, water, pavement); heavily-textured fills go soft.
enum ObjectRemoval {
    static func inpaint(_ image: CIImage, mask: CIImage) -> CIImage {
        let e = image.extent
        guard e.width >= 4, e.height >= 4 else { return image }
        let m = alignMask(mask, to: e)
        var filled = image
        let base = Double(max(e.width, e.height))
        // Coarse → fine: the largest radii must be big enough to actually bridge the hole and flood it with
        // surrounding colour — too-small radii leave the object's own pixels behind as a grey smear. The
        // small radii then tighten the seam.
        let radii = [base * 0.08, base * 0.05, base * 0.03, base * 0.018, base * 0.01, base * 0.005, base * 0.0025]
        for r in radii {
            for _ in 0..<2 {
                let blurred = filled.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(1, r)])
                    .cropped(to: e)
                filled = blurred.applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: m,
                ]).cropped(to: e)
            }
        }
        // A diffused fill is too clean — it reads as a soft spot against any textured background. Re-inject
        // fine grain *only inside the hole*, matched to the local luminance noise around it, so the patch
        // carries the same micro-texture as its surroundings and stops looking airbrushed.
        if let grained = addMatchedGrain(filled, mask: m, extent: e) {
            filled = grained
        }
        return filled
    }

    /// Adds gentle zero-mean monochrome grain inside the masked region so the diffused fill carries the same
    /// micro-texture as its surroundings instead of reading as an airbrushed soft spot. The grain is applied
    /// via soft-light (a small brightness perturbation that vanishes on flat mid-grey), so a smooth
    /// background (sky/wall) is barely affected while a textured one gets its speckle back.
    private static func addMatchedGrain(_ filled: CIImage, mask: CIImage, extent e: CGRect) -> CIImage? {
        // Tileable noise, desaturated to luminance grain, compressed around mid-grey so the perturbation is
        // subtle (≈±10%).
        let noise = CIFilter(name: "CIRandomGenerator")!.outputImage!
            .cropped(to: e)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.0])
        // Centre the grain exactly on mid-grey (0.5) so soft-light neither lightens nor darkens the fill on
        // average — a bias below 0.5 was greying the patch. Small amplitude keeps it a texture, not a haze.
        let grain = noise.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.06, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0.06, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0.06, w: 0),
            "inputBiasVector": CIVector(x: 0.47, y: 0.47, z: 0.47, w: 0),
        ])
        let textured = grain.applyingFilter("CISoftLightBlendMode", parameters: [
            kCIInputBackgroundImageKey: filled,
        ]).cropped(to: e)
        // Apply the grain only inside the removal hole.
        return textured.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: filled, kCIInputMaskImageKey: mask,
        ]).cropped(to: e)
    }

    private static func alignMask(_ mask: CIImage, to e: CGRect) -> CIImage {
        let me = mask.extent
        guard me.width > 0, me.height > 0 else { return mask }
        let sx = e.width / me.width, sy = e.height / me.height
        let scaled = mask.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        return scaled.transformed(by: CGAffineTransform(translationX: e.minX - scaled.extent.minX,
                                                        y: e.minY - scaled.extent.minY))
    }
}
