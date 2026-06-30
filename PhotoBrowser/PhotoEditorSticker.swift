import UIKit
import CoreImage
import ImageIO

/// One placed image sticker for the render pipeline: a CIImage positioned by a normalized **top-left**
/// center, a width given as a fraction of the base image width, and a rotation. The view manipulates a
/// `StickerItem` (UIImage + transform) interactively and converts to `EditSticker` for compositing.
struct EditSticker: Sendable {
    let image: CIImage
    let center: CGPoint   // normalized top-left
    let scale: Double     // sticker width / base width
    let rotation: Double  // radians
    var effect: StickerEffectKind = .none
    var effectAmount: Double = 0.5   // 0…1 — size/intensity of the shadow or glow
}

/// Optional decoration drawn *under* an image sticker.
enum StickerEffectKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case none, shadow, glow
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var systemImage: String {
        switch self {
        case .none:   return "nosign"
        case .shadow: return "shadow"
        case .glow:   return "sun.max.fill"
        }
    }
}

enum StickerImaging {
    /// Loads the imported sticker **expanded to HDR** (gain map applied) so its highlights survive into
    /// the (HDR-aware) composite, oriented upright. The display copy stays SDR; this is for the render.
    static func hdrImage(from data: Data) -> CIImage? {
        guard let ci = CIImage(data: data, options: [.expandToHDR: true]) else { return nil }
        var orientation: Int32 = 1
        if let src = CGImageSourceCreateWithData(data as CFData, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let o = props[kCGImagePropertyOrientation] as? UInt32 { orientation = Int32(o) }
        return ci.oriented(forExifOrientation: orientation)
    }

    /// HDR-preserving background removal on a CIImage (keeps the float range — no UIImage round-trip).
    static func cutout(ci image: CIImage) -> CIImage? {
        let e = image.extent
        guard e.width > 1, e.height > 1, let mask = PhotoEditorCutout.subjectMask(for: image) else { return nil }
        let sx = e.width / max(1, mask.extent.width), sy = e.height / max(1, mask.extent.height)
        var m = mask.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        m = m.transformed(by: CGAffineTransform(translationX: e.minX - m.extent.minX, y: e.minY - m.extent.minY))
        return image.applyingFilter("CIBlendWithMask", parameters: [kCIInputMaskImageKey: m]).cropped(to: e)
    }

    /// Removes the background from a sticker image for the **interactive display** (SDR UIImage). nil if
    /// Vision finds no subject.
    static func cutout(_ uiImage: UIImage) -> UIImage? {
        guard let ci = CIImage(image: uiImage), let masked = cutout(ci: ci) else { return nil }
        guard let cg = PhotoEditorIO.context.createCGImage(masked, from: masked.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
