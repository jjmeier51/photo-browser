import UIKit
import CoreImage

/// One placed image sticker for the render pipeline: a CIImage positioned by a normalized **top-left**
/// center, a width given as a fraction of the base image width, and a rotation. The view manipulates a
/// `StickerItem` (UIImage + transform) interactively and converts to `EditSticker` for compositing.
struct EditSticker: Sendable {
    let image: CIImage
    let center: CGPoint   // normalized top-left
    let scale: Double     // sticker width / base width
    let rotation: Double  // radians
}

enum StickerImaging {
    /// Removes the background from a sticker image (transparent where it isn't the subject), on-device.
    /// Returns nil if Vision finds no subject.
    static func cutout(_ uiImage: UIImage) -> UIImage? {
        guard let ci = CIImage(image: uiImage) else { return nil }
        let e = ci.extent
        guard e.width > 1, e.height > 1, let mask = PhotoEditorCutout.subjectMask(for: ci) else { return nil }
        let sx = e.width / max(1, mask.extent.width), sy = e.height / max(1, mask.extent.height)
        let m = mask.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            .transformed(by: CGAffineTransform(translationX: e.minX, y: e.minY))
        let masked = ci.applyingFilter("CIBlendWithMask", parameters: [kCIInputMaskImageKey: m]).cropped(to: e)
        guard let cg = PhotoEditorIO.context.createCGImage(masked, from: e) else { return nil }
        return UIImage(cgImage: cg)
    }
}
