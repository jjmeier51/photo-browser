import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins

/// The Filters tool's presets: named Core Image looks a clip can wear at a chosen intensity.
/// Everything is a pure `CIImage → CIImage` function so the compositor applies it identically in
/// the preview, the export and the cover, and the tool strip can render the same look on a
/// poster thumbnail. Ids are stable document strings (`VEFilter.id`) — rename the labels freely,
/// never the ids.
nonisolated struct VEFilterDef: Identifiable, Sendable {
    let id: String
    let name: String
    let apply: @Sendable (CIImage) -> CIImage
}

nonisolated enum VEFilterCatalog {
    static let all: [VEFilterDef] = [
        VEFilterDef(id: "vivid", name: "Vivid") { img in
            controls(vibrance(img, 0.6), contrast: 1.05, saturation: 1.15)
        },
        VEFilterDef(id: "bright", name: "Bright") { img in
            controls(exposure(img, 0.4), saturation: 1.05)
        },
        VEFilterDef(id: "warm", name: "Warm") { img in temperature(img, target: 8000) },
        VEFilterDef(id: "cool", name: "Cool") { img in temperature(img, target: 4800) },
        VEFilterDef(id: "cinema", name: "Cinema") { img in
            vignette(controls(img, contrast: 1.12, saturation: 0.9), intensity: 0.5, radius: 1.6)
        },
        VEFilterDef(id: "dramatic", name: "Dramatic") { img in
            vignette(controls(img, brightness: -0.03, contrast: 1.3, saturation: 0.85), intensity: 0.8, radius: 1.4)
        },
        VEFilterDef(id: "matte", name: "Matte") { img in
            controls(img, brightness: 0.04, contrast: 0.88, saturation: 0.9)
        },
        VEFilterDef(id: "fade", name: "Fade") { img in photo(CIFilter.photoEffectFade(), img) },
        VEFilterDef(id: "chrome", name: "Chrome") { img in photo(CIFilter.photoEffectChrome(), img) },
        VEFilterDef(id: "instant", name: "Instant") { img in photo(CIFilter.photoEffectInstant(), img) },
        VEFilterDef(id: "process", name: "Process") { img in photo(CIFilter.photoEffectProcess(), img) },
        VEFilterDef(id: "transfer", name: "Transfer") { img in photo(CIFilter.photoEffectTransfer(), img) },
        VEFilterDef(id: "retro", name: "Retro") { img in
            vignette(photo(CIFilter.photoEffectInstant(), img), intensity: 0.7, radius: 1.5)
        },
        VEFilterDef(id: "sepia", name: "Sepia") { img in
            let f = CIFilter.sepiaTone()
            f.inputImage = img
            f.intensity = 0.9
            return f.outputImage ?? img
        },
        VEFilterDef(id: "mono", name: "Mono") { img in photo(CIFilter.photoEffectMono(), img) },
        VEFilterDef(id: "tonal", name: "Tonal") { img in photo(CIFilter.photoEffectTonal(), img) },
        VEFilterDef(id: "noir", name: "Noir") { img in photo(CIFilter.photoEffectNoir(), img) },
    ]

    static func def(_ id: String) -> VEFilterDef? { all.first { $0.id == id } }
    static func name(_ id: String) -> String { def(id)?.name ?? "None" }

    /// The look at its intensity: a dissolve between the original and the filtered picture, so
    /// 0 is the untouched clip and 1 the full preset. The result keeps the input's extent.
    static func apply(_ filter: VEFilter, to image: CIImage) -> CIImage {
        guard filter.isActive, let d = def(filter.id) else { return image }
        let filtered = d.apply(image).cropped(to: image.extent)
        let t = max(0, min(1, filter.intensity))
        if t >= 0.999 { return filtered }
        let mix = CIFilter.dissolveTransition()
        mix.inputImage = image
        mix.targetImage = filtered
        mix.time = Float(t)
        return (mix.outputImage ?? filtered).cropped(to: image.extent)
    }

    // MARK: Building blocks

    private static func photo(_ f: CIFilter & CIPhotoEffect, _ img: CIImage) -> CIImage {
        f.inputImage = img
        return f.outputImage ?? img
    }

    private static func controls(_ img: CIImage, brightness: Float = 0, contrast: Float = 1, saturation: Float = 1) -> CIImage {
        let f = CIFilter.colorControls()
        f.inputImage = img
        f.brightness = brightness
        f.contrast = contrast
        f.saturation = saturation
        return f.outputImage ?? img
    }

    private static func vibrance(_ img: CIImage, _ amount: Float) -> CIImage {
        let f = CIFilter.vibrance()
        f.inputImage = img
        f.amount = amount
        return f.outputImage ?? img
    }

    private static func exposure(_ img: CIImage, _ ev: Float) -> CIImage {
        let f = CIFilter.exposureAdjust()
        f.inputImage = img
        f.ev = ev
        return f.outputImage ?? img
    }

    /// Shifts the white point: a `target` above 6500 K warms the picture, below cools it.
    private static func temperature(_ img: CIImage, target: CGFloat) -> CIImage {
        let f = CIFilter.temperatureAndTint()
        f.inputImage = img
        f.neutral = CIVector(x: 6500, y: 0)
        f.targetNeutral = CIVector(x: target, y: 0)
        return f.outputImage ?? img
    }

    private static func vignette(_ img: CIImage, intensity: Float, radius: Float) -> CIImage {
        let f = CIFilter.vignette()
        f.inputImage = img
        f.intensity = intensity
        f.radius = radius
        return f.outputImage ?? img
    }
}
