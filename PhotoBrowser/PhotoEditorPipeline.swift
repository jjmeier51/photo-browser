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
        EditFilter(id: "vivid",   name: "Vivid")    { fgGrade($0, sat: 1.12, con: 1.06, vib: 0.6) },
        EditFilter(id: "warm",    name: "Warm")     { fgGrade($0, temp: 4800, vib: 0.2) },
        EditFilter(id: "cool",    name: "Cool")     { fgGrade($0, temp: 8800) },
        EditFilter(id: "film",    name: "Film")     { $0.applyingFilter("CIPhotoEffectInstant") },
        EditFilter(id: "fade",    name: "Faded")    { $0.applyingFilter("CIPhotoEffectFade") },
        EditFilter(id: "process", name: "Lo-Fi")    { $0.applyingFilter("CIPhotoEffectProcess") },
        EditFilter(id: "chrome",  name: "Chrome")   { $0.applyingFilter("CIPhotoEffectChrome") },
        EditFilter(id: "mono",    name: "B&W")      { $0.applyingFilter("CIPhotoEffectMono") },
        EditFilter(id: "noir",    name: "Noir")     { $0.applyingFilter("CIPhotoEffectNoir") },
        EditFilter(id: "tonal",   name: "Silver")   { $0.applyingFilter("CIPhotoEffectTonal") },
        // --- 30 more ---
        EditFilter(id: "teal",     name: "Teal")     { fgGrade($0, temp: 7600, tint: -8, sat: 1.05, con: 1.05) },
        EditFilter(id: "sunset",   name: "Sunset")   { fgGrade($0, temp: 4200, tint: 14, sat: 1.1, vib: 0.3) },
        EditFilter(id: "vintage",  name: "Vintage")  { fgLift($0.applyingFilter("CISepiaTone", parameters: [kCIInputIntensityKey: 0.4]), 0.06) },
        EditFilter(id: "matte",    name: "Matte")    { fgLift(fgGrade($0, sat: 0.95, con: 0.9), 0.09) },
        EditFilter(id: "crisp",    name: "Crisp")    { fgGrade($0, temp: 6800, sat: 1.05, con: 1.14) },
        EditFilter(id: "moody",    name: "Moody")    { fgGrade($0, temp: 6000, sat: 0.8, con: 1.12, bri: -0.04) },
        EditFilter(id: "golden",   name: "Golden")   { fgGrade($0, temp: 4500, tint: 6, sat: 1.05, vib: 0.35) },
        EditFilter(id: "pastel",   name: "Pastel")   { fgLift(fgGrade($0, sat: 0.85, con: 0.9, bri: 0.05), 0.08) },
        EditFilter(id: "dramatic", name: "Drama")    { fgGrade($0, sat: 1.1, con: 1.25, vib: 0.3) },
        EditFilter(id: "cinema",   name: "Cinema")   { fgGrade(fgSplit($0, shadow: -10, highlight: 8), sat: 1.04, con: 1.08) },
        EditFilter(id: "sepia",    name: "Sepia")    { $0.applyingFilter("CISepiaTone", parameters: [kCIInputIntensityKey: 0.8]) },
        EditFilter(id: "cross",    name: "X-Pro")    { fgGrade($0, temp: 5600, tint: -12, sat: 1.2, con: 1.18) },
        EditFilter(id: "frost",    name: "Frost")    { fgGrade($0, temp: 9000, sat: 0.85, con: 0.95, bri: 0.04) },
        EditFilter(id: "ember",    name: "Ember")    { fgGrade($0, temp: 3900, tint: 10, sat: 1.1, con: 1.06) },
        EditFilter(id: "olive",    name: "Olive")    { fgGrade($0, temp: 6200, tint: -16, sat: 0.95) },
        EditFilter(id: "rose",     name: "Rose")     { fgGrade($0, temp: 5800, tint: 18, sat: 1.0, bri: 0.03) },
        EditFilter(id: "azure",    name: "Azure")    { fgGrade($0, temp: 9500, tint: -6, sat: 1.05) },
        EditFilter(id: "mocha",    name: "Mocha")    { fgGrade($0.applyingFilter("CISepiaTone", parameters: [kCIInputIntensityKey: 0.25]), temp: 5200, sat: 0.9) },
        EditFilter(id: "honey",    name: "Honey")    { fgGrade($0, temp: 4600, tint: 4, sat: 1.08, vib: 0.4) },
        EditFilter(id: "slate",    name: "Slate")    { fgGrade($0, temp: 7800, sat: 0.6, con: 1.05) },
        EditFilter(id: "punch",    name: "Punch")    { fgGrade($0, sat: 1.35, con: 1.15, vib: 0.4) },
        EditFilter(id: "velvet",   name: "Velvet")   { fgGrade($0, temp: 4900, sat: 1.05, con: 1.2, bri: -0.03) },
        EditFilter(id: "dusk",     name: "Dusk")     { fgGrade($0, temp: 7200, tint: 12, sat: 0.95, bri: -0.03) },
        EditFilter(id: "bloom",    name: "Bloom")    { fgLift(fgGrade($0, temp: 5400, sat: 1.05, bri: 0.06), 0.05) },
        EditFilter(id: "retro",    name: "Retro")    { fgLift(fgGrade($0, temp: 4700, sat: 0.85, con: 0.92), 0.1) },
        EditFilter(id: "ivory",    name: "Ivory")    { fgGrade($0, temp: 5600, sat: 0.8, bri: 0.06) },
        EditFilter(id: "carbon",   name: "Carbon")   { fgGrade($0.applyingFilter("CIPhotoEffectMono"), con: 1.25) },
        EditFilter(id: "coral",    name: "Coral")    { fgGrade($0, temp: 4400, tint: 16, sat: 1.12, vib: 0.3) },
        EditFilter(id: "mint",     name: "Mint")     { fgGrade($0, temp: 7000, tint: -18, sat: 1.0, bri: 0.03) },
        EditFilter(id: "plum",     name: "Plum")     { fgGrade($0, temp: 7400, tint: 20, sat: 1.05, con: 1.08, bri: -0.03) },
        EditFilter(id: "lush",     name: "Lush")     { fgGrade($0, temp: 6000, tint: -10, sat: 1.18, vib: 0.35) },
        EditFilter(id: "smolder",  name: "Smolder")  { fgGrade(fgSplit($0, shadow: 6, highlight: -6), sat: 0.95, con: 1.15, bri: -0.04) },
    ]
    static func by(id: String?) -> EditFilter? { id.flatMap { id in all.first { $0.id == id } } }
}

// MARK: Filter grading helpers (file-scope so the @Sendable look closures can call them)

private func fgGrade(_ img: CIImage, temp: CGFloat = 6500, tint: CGFloat = 0,
                     sat: Double = 1, con: Double = 1, bri: Double = 0, vib: Double = 0) -> CIImage {
    var x = img
    if temp != 6500 || tint != 0 {
        x = x.applyingFilter("CITemperatureAndTint", parameters: [
            "inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: temp, y: tint)])
    }
    if sat != 1 || con != 1 || bri != 0 {
        x = x.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: sat, kCIInputContrastKey: con, kCIInputBrightnessKey: bri])
    }
    if vib != 0 { x = x.applyingFilter("CIVibrance", parameters: ["inputAmount": vib]) }
    return x
}

/// Lifts the blacks for a faded/matte look.
private func fgLift(_ img: CIImage, _ amount: Double) -> CIImage {
    img.applyingFilter("CIToneCurve", parameters: [
        "inputPoint0": CIVector(x: 0, y: CGFloat(amount)),
        "inputPoint1": CIVector(x: 0.25, y: 0.25 + CGFloat(amount) * 0.5),
        "inputPoint2": CIVector(x: 0.5, y: 0.5),
        "inputPoint3": CIVector(x: 0.75, y: 0.78),
        "inputPoint4": CIVector(x: 1, y: 1)])
}

/// A simple split-tone: cool/warm shifts pushed differently into shadows vs highlights (teal-orange etc.).
private func fgSplit(_ img: CIImage, shadow: CGFloat, highlight: CGFloat) -> CIImage {
    let lows = img.applyingFilter("CITemperatureAndTint", parameters: [
        "inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: 6500 + shadow * 120, y: 0)])
    let highs = img.applyingFilter("CITemperatureAndTint", parameters: [
        "inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: 6500 - highlight * 120, y: 0)])
    // Blend highs into lows weighted by luminance.
    let lumaMask = img.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
    return highs.applyingFilter("CIBlendWithMask", parameters: [
        kCIInputBackgroundImageKey: lows, kCIInputMaskImageKey: lumaMask]).cropped(to: img.extent)
}

/// Pure rendering of an `EditRecipe` over a source `CIImage` (PRD §8). Operations apply in the fixed
/// order **geometry → tone/color → filter → detail → effects** so results are deterministic and the
/// preview proxy and the full-res export render identically.
enum EditPipeline {
    /// `mask` is the optional subject mask (in `source` pixel space) for background removal; supply it
    /// whenever `recipe.cutout` is set. It is scaled to the working image, so a proxy-resolution mask
    /// can drive both the proxy preview and a downscaled render.
    /// `hdr` routes the reshape warp through a 16-bit float wide-gamut raster so HDR headroom survives
    /// (set it on the HDR save path; the SDR preview/export leave it false for speed).
    static func render(_ source: CIImage, recipe r: EditRecipe, mask: CIImage? = nil,
                       landmarks: EditLandmarks? = nil, stickers: [EditSticker]? = nil,
                       hdr: Bool = false, fast: Bool = false) -> CIImage {
        var img = source
        img = cutout(img, r, mask: mask)        // background replacement first, so later edits apply to it
        img = hairStage(img, r, mask: mask, landmarks: landmarks)   // recolor hair before warps
        img = skinStage(img, r, mask: mask)     // recolor skin under the makeup, confined to the subject
        img = makeupStage(img, r, landmarks: landmarks)   // makeup before warps, so it tracks the face
        img = bodyStage(img, r, landmarks: landmarks, mask: mask, hdr: hdr, fast: fast)   // shape only the subject
        img = geometry(img, r)
        img = toneColor(img, r)
        img = filter(img, r, mask: mask)
        img = detail(img, r)
        img = effects(img, r)
        img = reshapeStage(img, r, hdr: hdr, fast: fast)
        img = stickerStage(img, stickers)       // image stickers go on top of everything
        return img.cropped(to: img.extent)      // settle the extent
    }

    // MARK: Stickers

    private static func stickerStage(_ image: CIImage, _ stickers: [EditSticker]?) -> CIImage {
        guard let stickers, !stickers.isEmpty else { return image }
        let e = image.extent
        guard e.width > 0, e.height > 0 else { return image }
        var img = image
        for s in stickers {
            let se = s.image.extent
            guard se.width > 0, se.height > 0 else { continue }
            let scaleF = (s.scale * Double(e.width)) / Double(se.width)
            let targetX = Double(s.center.x) * Double(e.width) + Double(e.minX)
            let targetY = (1 - Double(s.center.y)) * Double(e.height) + Double(e.minY)   // top-left → bottom-left
            let t = CGAffineTransform(translationX: -se.midX, y: -se.midY)
                .concatenating(CGAffineTransform(scaleX: scaleF, y: scaleF))
                .concatenating(CGAffineTransform(rotationAngle: -s.rotation))            // screen CW → CI CCW
                .concatenating(CGAffineTransform(translationX: targetX, y: targetY))
            let placed = s.image.transformed(by: t)
            img = placed.applyingFilter("CISourceOverCompositing",
                                        parameters: [kCIInputBackgroundImageKey: img]).cropped(to: e)
        }
        return img
    }

    // MARK: Hair

    private static func hairStage(_ image: CIImage, _ r: EditRecipe,
                                  mask: CIImage?, landmarks: EditLandmarks?) -> CIImage {
        guard let color = r.hairColor, let face = landmarks?.face, let mask else { return image }
        return HairRecolor.apply(image, color: color, strength: r.hairStrength, face: face, subjectMask: mask)
    }

    // MARK: Skin tone

    private static func skinStage(_ image: CIImage, _ r: EditRecipe, mask: CIImage?) -> CIImage {
        guard r.skinTone != 0 else { return image }
        return SkinRecolor.apply(image, amount: r.skinTone, subjectMask: mask)
    }

    // MARK: Makeup

    private static func makeupStage(_ image: CIImage, _ r: EditRecipe, landmarks: EditLandmarks?) -> CIImage {
        guard !r.makeup.isZero, let face = landmarks?.face else { return image }
        return MakeupRenderer.apply(image, makeup: r.makeup, face: face)
    }

    // MARK: Body shaping

    private static func bodyStage(_ image: CIImage, _ r: EditRecipe,
                                  landmarks: EditLandmarks?, mask: CIImage?, hdr: Bool, fast: Bool) -> CIImage {
        guard !r.body.isZero, let lm = landmarks, !lm.isEmpty else { return image }
        let aspect = image.extent.height > 0 ? image.extent.width / image.extent.height : 1
        guard var field = BodyWarp.field(for: r.body, landmarks: lm, imageAspect: aspect) else { return image }
        // Confine the warp to the subject so the background stays untouched.
        if let mask { field = BodyWarp.modulate(field, byMask: mask, context: PhotoEditorIO.context) }
        return ReshapeWarp.apply(image, field: field, hdr: hdr, fast: fast)
    }

    // MARK: Cutout (background removal)

    private static func cutout(_ image: CIImage, _ r: EditRecipe, mask: CIImage?) -> CIImage {
        guard let bg = r.cutout, let raw = mask,
              raw.extent.width > 0, raw.extent.height > 0 else { return image }
        // Scale + align the mask to the working image, then soften the edge a touch.
        let sx = image.extent.width / raw.extent.width
        let sy = image.extent.height / raw.extent.height
        var m = raw.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        m = m.transformed(by: CGAffineTransform(translationX: image.extent.minX - m.extent.minX,
                                                y: image.extent.minY - m.extent.minY))
        m = m.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 1.5]).cropped(to: image.extent)

        switch bg {
        case .transparent:
            // No background image → CIBlendWithMask defaults to transparent where the mask is black.
            return image.applyingFilter("CIBlendWithMask",
                                        parameters: [kCIInputMaskImageKey: m]).cropped(to: image.extent)
        case .blur:
            let back = image.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 18])
                .cropped(to: image.extent)
            return blend(image, over: back, mask: m)
        case .white:
            return blend(image, over: solid(.init(red: 1, green: 1, blue: 1), image.extent), mask: m)
        case .black:
            return blend(image, over: solid(.init(red: 0, green: 0, blue: 0), image.extent), mask: m)
        }
    }

    private static func blend(_ fg: CIImage, over bg: CIImage, mask: CIImage) -> CIImage {
        fg.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: bg, kCIInputMaskImageKey: mask,
        ]).cropped(to: fg.extent)
    }
    private static func solid(_ color: CIColor, _ extent: CGRect) -> CIImage {
        CIImage(color: color).cropped(to: extent)
    }

    // MARK: Reshape

    private static func reshapeStage(_ image: CIImage, _ r: EditRecipe, hdr: Bool, fast: Bool) -> CIImage {
        guard let field = r.reshape, !field.isZero else { return image }
        return ReshapeWarp.apply(image, field: field, hdr: hdr, fast: fast)
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

    private static func filter(_ image: CIImage, _ r: EditRecipe, mask: CIImage?) -> CIImage {
        guard let f = EditFilter.by(id: r.filterID), r.filterIntensity > 0 else { return image }
        let look = f.make(image).cropped(to: image.extent)
        var looked = look
        if r.filterIntensity < 1 {
            // Cross-dissolve from the original (time 0) toward the filtered look (time 1) by intensity.
            looked = image.applyingFilter("CIDissolveTransition", parameters: [
                kCIInputTargetImageKey: look, kCIInputTimeKey: r.filterIntensity,
            ]).cropped(to: image.extent)
        }
        // Background-only: keep the subject from the original, take the filtered look only behind it.
        if r.filterBackgroundOnly, let mask {
            let m = alignMask(mask, to: image.extent)
            return image.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: looked, kCIInputMaskImageKey: m,
            ]).cropped(to: image.extent)
        }
        return looked
    }

    /// Scales a (proxy-resolution) mask to fill `extent`, so it lines up with the working image.
    private static func alignMask(_ mask: CIImage, to extent: CGRect) -> CIImage {
        let me = mask.extent
        guard me.width > 0, me.height > 0 else { return mask }
        let sx = extent.width / me.width, sy = extent.height / me.height
        let scaled = mask.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        return scaled.transformed(by: CGAffineTransform(translationX: extent.minX - scaled.extent.minX,
                                                        y: extent.minY - scaled.extent.minY))
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
