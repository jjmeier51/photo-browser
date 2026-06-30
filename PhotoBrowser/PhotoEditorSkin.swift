import CoreImage
import Foundation

/// Best-effort on-device skin recolor (pale ↔ tan). iOS exposes no skin-segmentation API, so skin is
/// isolated by **colour**: a precomputed skin-probability colour cube turns the image into a skin mask,
/// which is intersected with the Vision **subject mask** so the background (and any skin-coloured surface
/// behind the subject) is never touched. A warm/cool, lighter/darker tone shift is then blended *only* over
/// the skin, so hair, clothes and eyes stay put. Approximate by nature — skin-coloured clothing can be
/// caught too, and it needs the subject mask (returns the image unchanged until one is available).
enum SkinRecolor {
    /// `amount` is −1 (palest) … 0 (neutral) … +1 (most tan).
    static func apply(_ image: CIImage, amount: Double, subjectMask: CIImage?) -> CIImage {
        let e = image.extent
        guard amount != 0, e.width >= 8, e.height >= 8,
              let subjectMask, let cube = skinCubeFilter() else { return image }

        // Skin-colour mask from the LUT, softened, then confined to the subject.
        cube.setValue(image, forKey: kCIInputImageKey)
        var skin = (cube.outputImage ?? image).cropped(to: e)
        skin = skin.applyingFilter("CIGaussianBlur",
                                   parameters: [kCIInputRadiusKey: max(1.0, Double(e.width) * 0.002)]).cropped(to: e)
        let aligned = alignMask(subjectMask, to: e)
        skin = skin.applyingFilter("CIMultiplyCompositing",
                                   parameters: [kCIInputBackgroundImageKey: aligned]).cropped(to: e)

        // Tone shift: tan = warmer + a touch darker + more saturated; pale = cooler + lighter + less saturated.
        let a = max(-1, min(1, amount))
        let warmed = image.applyingFilter("CITemperatureAndTint", parameters: [
            "inputNeutral": CIVector(x: 6500, y: 0),
            "inputTargetNeutral": CIVector(x: 6500 - a * 1500, y: 0),
        ])
        let toned = warmed.applyingFilter("CIColorControls", parameters: [
            kCIInputBrightnessKey: -0.06 * a,
            kCIInputSaturationKey: 1 + 0.20 * a,
            kCIInputContrastKey: 1,
        ])
        return toned.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: skin,
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

    // MARK: Skin-colour LUT

    private static let cubeDimension = 24

    /// A fresh `CIColorCube` each call (a `CIFilter` instance isn't safe to share across threads); the heavy
    /// `cubeData` itself is built once.
    private static func skinCubeFilter() -> CIFilter? {
        guard let f = CIFilter(name: "CIColorCube") else { return nil }
        f.setValue(cubeDimension as NSNumber, forKey: "inputCubeDimension")
        f.setValue(cubeData, forKey: "inputCubeData")
        return f
    }

    /// Maps each RGB cell to white (skin) or black (not), so feeding an image through the cube yields a
    /// skin mask. Red varies fastest, then green, then blue (CIColorCube's required ordering).
    private static let cubeData: Data = {
        let n = cubeDimension
        var cube = [Float](repeating: 0, count: n * n * n * 4)
        var o = 0
        for bi in 0..<n {
            for gi in 0..<n {
                for ri in 0..<n {
                    let r = Float(ri) / Float(n - 1)
                    let g = Float(gi) / Float(n - 1)
                    let b = Float(bi) / Float(n - 1)
                    let v: Float = skinLikely(r, g, b) ? 1 : 0
                    cube[o] = v; cube[o + 1] = v; cube[o + 2] = v; cube[o + 3] = 1
                    o += 4
                }
            }
        }
        return cube.withUnsafeBufferPointer { Data(buffer: $0) }
    }()

    /// Luma-independent skin test in **YCbCr** (the Chai–Ngan chroma locus, broadened). Because skin
    /// chroma is roughly constant across tones, this catches dark→light skin alike — the earlier RGB
    /// rule was calibrated for light skin and missed most of a darker subject. The subject mask already
    /// excludes the background, so the test only has to separate skin from clothing/hair within the person.
    private static func skinLikely(_ r: Float, _ g: Float, _ b: Float) -> Bool {
        let R = r * 255, G = g * 255, B = b * 255
        let y  = 0.299 * R + 0.587 * G + 0.114 * B
        let cb = 128 - 0.168736 * R - 0.331264 * G + 0.5 * B
        let cr = 128 + 0.5 * R - 0.418688 * G - 0.081312 * B
        // Skin is reddish‑warm: Cr above mid, Cb below mid, with a generous window so deep tones qualify.
        guard y > 25 else { return false }                 // exclude near‑black (hair/shadow)
        return cb >= 70 && cb <= 135 && cr >= 132 && cr <= 185 && cr >= cb - 18
    }
}
