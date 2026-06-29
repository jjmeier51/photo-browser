import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics

/// A preset filter look (PRD FR-FILT-01). Identified by a stable `id` (stored in the recipe);
/// `make` produces the full-strength look, which the pipeline cross-dissolves toward by intensity.
struct EditFilter: Identifiable {
    let id: String
    let name: String
    let make: @Sendable (CIImage) -> CIImage

    static let all: [EditFilter] = [
        EditFilter(id: "vivid",   name: "Vivid")    { $0.applyingFilter("CIVibrance", parameters: ["inputAmount": 0.6])
                                                        .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.12, kCIInputContrastKey: 1.06]) },
        EditFilter(id: "warm",    name: "Warm")     { $0.applyingFilter("CITemperatureAndTint", parameters: ["inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: 4800, y: 0)])
                                                        .applyingFilter("CIVibrance", parameters: ["inputAmount": 0.2]) },
        EditFilter(id: "cool",    name: "Cool")     { $0.applyingFilter("CITemperatureAndTint", parameters: ["inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: 8800, y: 0)]) },
        EditFilter(id: "film",    name: "Film")     { $0.applyingFilter("CIPhotoEffectInstant") },
        EditFilter(id: "fade",    name: "Faded")    { $0.applyingFilter("CIPhotoEffectFade") },
        EditFilter(id: "process", name: "Lo-Fi")    { $0.applyingFilter("CIPhotoEffectProcess") },
        EditFilter(id: "chrome",  name: "Chrome")   { $0.applyingFilter("CIPhotoEffectChrome") },
        EditFilter(id: "mono",    name: "B&W")      { $0.applyingFilter("CIPhotoEffectMono") },
        EditFilter(id: "noir",    name: "Noir")     { $0.applyingFilter("CIPhotoEffectNoir") },
        EditFilter(id: "tonal",   name: "Silver")   { $0.applyingFilter("CIPhotoEffectTonal") },
    ]
    static func by(id: String?) -> EditFilter? { id.flatMap { id in all.first { $0.id == id } } }
}

/// Pure rendering of an `EditRecipe` over a source `CIImage` (PRD §8). Operations apply in the fixed
/// order **geometry → tone/color → filter → detail → effects** so results are deterministic and the
/// preview proxy and the full-res export render identically.
enum EditPipeline {
    static func render(_ source: CIImage, recipe r: EditRecipe) -> CIImage {
        var img = source
        img = geometry(img, r)
        img = toneColor(img, r)
        img = filter(img, r)
        img = detail(img, r)
        img = effects(img, r)
        img = reshapeStage(img, r)
        return img.cropped(to: img.extent)      // settle the extent
    }

    // MARK: Reshape

    private static func reshapeStage(_ image: CIImage, _ r: EditRecipe) -> CIImage {
        guard let field = r.reshape, !field.isZero else { return image }
        return ReshapeWarp.apply(image, field: field)
    }

    // MARK: Geometry

    private static func geometry(_ image: CIImage, _ r: EditRecipe) -> CIImage {
        var img = image
        if r.flipH { img = recenter(img.transformed(by: CGAffineTransform(scaleX: -1, y: 1))) }
        if r.flipV { img = recenter(img.transformed(by: CGAffineTransform(scaleX: 1, y: -1))) }
        if r.rotationQuarters % 4 != 0 {
            let angle = CGFloat(r.rotationQuarters % 4) * .pi / 2
            img = recenter(img.transformed(by: CGAffineTransform(rotationAngle: angle)))
        }
        if r.straighten != 0 {
            let θ = CGFloat(r.straighten) * .pi / 180
            let w = img.extent.width, h = img.extent.height
            let c = CGPoint(x: img.extent.midX, y: img.extent.midY)
            let t = CGAffineTransform(translationX: c.x, y: c.y).rotated(by: θ).translatedBy(x: -c.x, y: -c.y)
            img = img.transformed(by: t)
            let inner = largestInnerRect(w: w, h: h, angle: θ)
            img = recenter(img.cropped(to: CGRect(x: c.x - inner.width / 2, y: c.y - inner.height / 2,
                                                  width: inner.width, height: inner.height)))
        }
        if let cr = r.cropRect, !isFullCrop(cr) {
            img = recenter(applyCrop(img, normalizedTopLeft: cr))
        }
        return img
    }

    private static func recenter(_ img: CIImage) -> CIImage {
        img.transformed(by: CGAffineTransform(translationX: -img.extent.origin.x, y: -img.extent.origin.y))
    }

    /// A `cropRect` covering essentially the whole frame is treated as no crop.
    private static func isFullCrop(_ r: CGRect) -> Bool {
        r.minX <= 0.001 && r.minY <= 0.001 && r.maxX >= 0.999 && r.maxY >= 0.999
    }

    /// Crops `img` (origin at 0,0) to a normalized **top-left** rect, converting to Core Image's
    /// bottom-left extent coordinates. Clamped so a stray rect can't produce an empty/!finite extent.
    private static func applyCrop(_ img: CIImage, normalizedTopLeft cr: CGRect) -> CIImage {
        let e = img.extent
        let x = min(max(cr.minX, 0), 1), y = min(max(cr.minY, 0), 1)
        let w = min(max(cr.width, 0.02), 1 - x), h = min(max(cr.height, 0.02), 1 - y)
        let rect = CGRect(x: e.minX + x * e.width,
                          y: e.minY + (1 - y - h) * e.height,   // flip top-left → bottom-left
                          width: w * e.width, height: h * e.height)
        return img.cropped(to: rect)
    }

    /// Largest axis-aligned rectangle (same aspect as w×h) that fits inside a w×h rectangle rotated
    /// by `angle` — used to auto-crop a straighten so no blank corners show.
    private static func largestInnerRect(w: CGFloat, h: CGFloat, angle: CGFloat) -> CGSize {
        guard w > 0, h > 0 else { return .zero }
        let widthIsLonger = w >= h
        let sideLong = widthIsLonger ? w : h
        let sideShort = widthIsLonger ? h : w
        let sinA = abs(sin(angle)), cosA = abs(cos(angle))
        var wr: CGFloat, hr: CGFloat
        if sideShort <= 2 * sinA * cosA * sideLong || abs(sinA - cosA) < 1e-10 {
            let x = 0.5 * sideShort
            if widthIsLonger { wr = sinA > 0 ? x / sinA : w; hr = cosA > 0 ? x / cosA : h }
            else { wr = cosA > 0 ? x / cosA : w; hr = sinA > 0 ? x / sinA : h }
        } else {
            let cos2a = cosA * cosA - sinA * sinA
            wr = (w * cosA - h * sinA) / cos2a
            hr = (h * cosA - w * sinA) / cos2a
        }
        return CGSize(width: max(1, min(w, wr)), height: max(1, min(h, hr)))
    }

    // MARK: Tone & color

    private static func toneColor(_ image: CIImage, _ r: EditRecipe) -> CIImage {
        var img = image
        if r.exposure != 0 {
            img = img.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: r.exposure * 1.5])
        }
        if r.contrast != 0 || r.saturation != 0 {
            img = img.applyingFilter("CIColorControls", parameters: [
                kCIInputContrastKey: 1 + r.contrast * 0.5,
                kCIInputSaturationKey: 1 + r.saturation,
            ])
        }
        if r.highlights != 0 || r.shadows != 0 {
            // Bidirectional highlights/shadows via a gentle tone curve (CIHighlightShadowAdjust only
            // works one direction). Small offsets keep the curve monotonic.
            let s = r.shadows * 0.18, h = r.highlights * 0.18
            func y(_ v: Double) -> CGFloat { CGFloat(min(1, max(0, v))) }
            img = img.applyingFilter("CIToneCurve", parameters: [
                "inputPoint0": CIVector(x: 0,    y: y(max(0, s * 0.5))),
                "inputPoint1": CIVector(x: 0.25, y: y(0.25 + s)),
                "inputPoint2": CIVector(x: 0.5,  y: y(0.5 + (s + h) * 0.25)),
                "inputPoint3": CIVector(x: 0.75, y: y(0.75 + h)),
                "inputPoint4": CIVector(x: 1,    y: 1),
            ])
        }
        if r.vibrance != 0 {
            img = img.applyingFilter("CIVibrance", parameters: ["inputAmount": r.vibrance])
        }
        if r.temperature != 0 || r.tint != 0 {
            // +temperature warms (lowers the target neutral); +tint pushes magenta.
            img = img.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: 6500 - r.temperature * 2500, y: -r.tint * 80),
            ])
        }
        return img
    }

    // MARK: Filter

    private static func filter(_ image: CIImage, _ r: EditRecipe) -> CIImage {
        guard let f = EditFilter.by(id: r.filterID), r.filterIntensity > 0 else { return image }
        let looked = f.make(image).cropped(to: image.extent)
        if r.filterIntensity >= 1 { return looked }
        // Cross-dissolve from the original (time 0) toward the filtered look (time 1) by intensity.
        // CIDissolveTransition's blend target is `inputTargetImage` — there is no inputBackgroundImage.
        return image.applyingFilter("CIDissolveTransition", parameters: [
            kCIInputTargetImageKey: looked,
            kCIInputTimeKey: r.filterIntensity,
        ]).cropped(to: image.extent)
    }

    // MARK: Detail

    private static func detail(_ image: CIImage, _ r: EditRecipe) -> CIImage {
        var img = image
        if r.sharpen > 0 {
            img = img.applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: r.sharpen * 1.5])
        }
        if r.structure != 0 {
            img = img.applyingFilter("CIUnsharpMask", parameters: [
                kCIInputRadiusKey: 12.0, kCIInputIntensityKey: r.structure * 0.6,
            ])
        }
        return img.cropped(to: image.extent)
    }

    // MARK: Effects

    private static func effects(_ image: CIImage, _ r: EditRecipe) -> CIImage {
        var img = image
        if r.fade > 0 {
            img = img.applyingFilter("CIToneCurve", parameters: [
                "inputPoint0": CIVector(x: 0, y: CGFloat(r.fade) * 0.2),     // lift blacks
                "inputPoint1": CIVector(x: 0.25, y: 0.25 + CGFloat(r.fade) * 0.12),
                "inputPoint2": CIVector(x: 0.5, y: 0.5),
                "inputPoint3": CIVector(x: 0.75, y: 0.75 - CGFloat(r.fade) * 0.05),
                "inputPoint4": CIVector(x: 1, y: 1 - CGFloat(r.fade) * 0.06),
            ])
        }
        if r.grain > 0 {
            let noise = CIFilter.randomGenerator().outputImage?
                .cropped(to: img.extent)
                .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0, kCIInputBrightnessKey: 0, kCIInputContrastKey: 1])
            if let noise {
                // Composite the grain over the image, then dissolve from the clean image toward the
                // grainy one by the grain amount. (Target image is `inputTargetImage`, not background.)
                let grainy = noise.applyingFilter("CISourceOverCompositing", parameters: [
                    kCIInputBackgroundImageKey: img,
                ]).cropped(to: img.extent)
                img = img.applyingFilter("CIDissolveTransition", parameters: [
                    kCIInputTargetImageKey: grainy,
                    kCIInputTimeKey: min(0.18, r.grain * 0.18),
                ]).cropped(to: img.extent)
            }
        }
        if r.vignette != 0 {
            // Positive = darken corners; negative = lighten corners.
            img = img.applyingFilter("CIVignetteEffect", parameters: [
                kCIInputCenterKey: CIVector(x: img.extent.midX, y: img.extent.midY),
                kCIInputRadiusKey: max(img.extent.width, img.extent.height) * 0.65,
                kCIInputIntensityKey: r.vignette,
                "inputFalloff": 0.5,
            ])
        }
        return img.cropped(to: image.extent)
    }
}
