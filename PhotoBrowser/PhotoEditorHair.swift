import UIKit
import CoreImage

/// Best-effort on-device hair recolor. iOS has no stock hair segmentation, so the hair region is
/// approximated geometrically — a head ellipse around the face, minus the face itself, intersected with
/// the Vision subject mask (so it never spills onto the background). The recolor preserves luminance
/// (via `CIColorMonochrome`) so hair texture/highlights survive. Captures the hair framing the face well;
/// very long hair flowing past the shoulders is only partially covered (a dedicated hair model would be
/// needed for that).
enum HairRecolor {
    static func apply(_ image: CIImage, color c: MakeupColor, strength: Double,
                      face f: FaceLandmarks, subjectMask: CIImage) -> CIImage {
        let e = image.extent
        guard e.width >= 8, e.height >= 8, let center = f.center else { return image }
        let size = CGSize(width: e.width, height: e.height)

        // Grayscale region mask: black bg, white head ellipse, black face ellipse (top-left coords).
        let fmt = UIGraphicsImageRendererFormat.default(); fmt.scale = 1; fmt.opaque = true
        let regionImg = UIGraphicsImageRenderer(size: size, format: fmt).image { rctx in
            let ctx = rctx.cgContext
            let W = size.width, H = size.height
            ctx.setFillColor(UIColor.black.cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
            let cx = center.x * W, cy = center.y * H
            let fw = CGFloat(max(0.08, f.width)) * W, fh = CGFloat(max(0.10, f.height)) * H
            ctx.setFillColor(UIColor.white.cgColor)
            let headRX = fw * 0.98, headRY = fh * 1.08
            ctx.fillEllipse(in: CGRect(x: cx - headRX, y: cy - fh * 0.14 - headRY, width: headRX * 2, height: headRY * 2))
            ctx.setFillColor(UIColor.black.cgColor)
            let faceRX = fw * 0.44, faceRY = fh * 0.54
            ctx.fillEllipse(in: CGRect(x: cx - faceRX, y: cy - faceRY, width: faceRX * 2, height: faceRY * 2))
        }
        guard let regionCG = regionImg.cgImage else { return image }
        var region = CIImage(cgImage: regionCG)
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(2.0, Double(e.width) * 0.004)])
            .cropped(to: CGRect(origin: .zero, size: size))
            .transformed(by: CGAffineTransform(translationX: e.minX, y: e.minY))

        // Confine to the subject so the wall/background hair-colored region can't appear.
        let sm = alignMask(subjectMask, to: e)
        let hairMask = region.applyingFilter("CIMultiplyCompositing",
                                             parameters: [kCIInputBackgroundImageKey: sm]).cropped(to: e)

        let target = CIColor(red: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b))
        let tinted = image.applyingFilter("CIColorMonochrome",
                                          parameters: ["inputColor": target, "inputIntensity": max(0, min(1, strength))])
        return tinted.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: hairMask]).cropped(to: e)
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
