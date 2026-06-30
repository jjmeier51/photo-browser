import CoreGraphics
import Foundation

/// `EditRecipe` is the single source of truth for the photo editor (PRD §8): a serializable set of
/// operations + parameters. Rendering is a pure function of (original image, recipe) — see
/// `EditPipeline`. Stored fields are neutral by default so a fresh recipe is the identity edit.
///
/// Operations apply in the fixed, documented order **geometry → tone/color → filter → detail →
/// effects** (PRD §8) for deterministic results. All ranges are normalized to make the UI sliders
/// uniform; the pipeline maps them onto Core Image inputs.
struct EditRecipe: Codable, Equatable {
    var version = 1

    // MARK: Geometry
    var rotationQuarters = 0            // 0…3, applied as 90° steps
    var flipH = false
    var flipV = false
    var straighten: Double = 0          // degrees, −45…45 (auto-cropped to valid bounds)
    /// The crop window as a normalized **top-left** rect (x,y,w,h in 0…1) within the image *after*
    /// rotate/flip/straighten. `nil` means the full frame (no crop). Fixed-ratio chips set a centered
    /// rect of that ratio; Freeform lets the user drag an arbitrary rect.
    var cropRect: CGRect?

    // MARK: Light & color  (neutral 0, range −1…1)
    var exposure = 0.0                  // Exposure / Brightness
    var contrast = 0.0
    var highlights = 0.0
    var shadows = 0.0
    var saturation = 0.0
    var vibrance = 0.0                  // protects skin tones / already-saturated pixels
    var temperature = 0.0              // warm ↔ cool
    var tint = 0.0                      // green ↔ magenta

    // MARK: Detail
    var sharpen = 0.0                   // 0…1
    var structure = 0.0                 // −1…1 (mid-tone local contrast / clarity)

    // MARK: Effects
    var vignette = 0.0                  // −1…1 (dark ↔ light corners)
    var grain = 0.0                     // 0…1
    var fade = 0.0                      // 0…1 (lifted-blacks film fade)

    // MARK: Filter
    var filterID: String?              // see EditFilter.all; nil = none
    var filterIntensity = 1.0          // 0…1

    // MARK: Reshape (manual liquify; applied last, per PRD §8 order)
    var reshape: ReshapeField?         // nil = no warp

    // MARK: Cutout (on-device background removal; needs the subject mask supplied at render time)
    var cutout: CutoutBackground?      // nil = background untouched

    // MARK: Body shaping (warp driven by Vision body landmarks, supplied at render time)
    var body = BodyShape()

    // MARK: Makeup (face-landmark-driven overlays, supplied at render time)
    var makeup = MakeupRecipe()

    /// True when nothing has been changed (used to gate the Save button / "no edits").
    var isIdentity: Bool { self == EditRecipe() }

    /// True when the geometry is untouched (preview can skip the geometry pass).
    var hasGeometry: Bool {
        rotationQuarters != 0 || flipH || flipV || straighten != 0 || cropRect != nil
    }
}

/// A serializable displacement mesh for manual reshape/liquify (`FR-RESH-01`). A regular `cols`×`rows`
/// grid of control points carries a normalized push offset (`dx` in image-width units, `dy` in
/// image-height units, top-down). The renderer warps the image by this mesh (`ReshapeWarp`); a fresh
/// field is all-zero (identity). Stored as flat arrays so it stays trivially `Codable`.
struct ReshapeField: Codable, Equatable {
    var cols: Int
    var rows: Int
    var dx: [Double]
    var dy: [Double]

    init(cols: Int = 25, rows: Int = 25) {
        self.cols = max(3, cols)
        self.rows = max(3, rows)
        dx = Array(repeating: 0, count: self.cols * self.rows)
        dy = Array(repeating: 0, count: self.cols * self.rows)
    }

    var isZero: Bool { !dx.contains { $0 != 0 } && !dy.contains { $0 != 0 } }
}

/// Body- and face-shaping slider amounts (Hypic-style). The warp is generated from Vision body/face
/// landmarks at render time; only these amounts live in the recipe so it stays light and re-editable.
/// Each is bipolar (−1…1): positive generally = bigger / longer / slimmer in the natural direction.
struct BodyShape: Codable, Equatable {
    // Body (needs body-pose landmarks)
    var slim = 0.0
    var waist = 0.0
    var hips = 0.0
    var butt = 0.0
    var legs = 0.0
    var height = 0.0
    var arms = 0.0
    var breasts = 0.0
    var ankles = 0.0
    var neck = 0.0
    // Face (needs face landmarks)
    var head = 0.0
    var forehead = 0.0
    var eyes = 0.0
    var nose = 0.0
    var ears = 0.0
    var chin = 0.0
    var lips = 0.0
    var smile = 0.0

    var isZero: Bool {
        slim == 0 && waist == 0 && hips == 0 && butt == 0 && legs == 0 && height == 0 && arms == 0 &&
        breasts == 0 && ankles == 0 && neck == 0 && head == 0 && forehead == 0 && eyes == 0 &&
        nose == 0 && ears == 0 && chin == 0 && lips == 0 && smile == 0
    }
    /// True if any body-region slider is engaged (vs. face-only edits).
    var hasBodyEdit: Bool {
        slim != 0 || waist != 0 || hips != 0 || butt != 0 || legs != 0 || height != 0 ||
        arms != 0 || breasts != 0 || ankles != 0 || neck != 0
    }
    var hasFaceEdit: Bool {
        head != 0 || forehead != 0 || eyes != 0 || nose != 0 || ears != 0 || chin != 0 ||
        lips != 0 || smile != 0
    }
}

/// A makeup color (linear-ish sRGB components 0…1), stored in the recipe.
struct MakeupColor: Codable, Equatable {
    var r: Double, g: Double, b: Double
    init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }
}

/// Face makeup amounts + colors. Overlays are drawn from face landmarks at render time; the recipe only
/// stores intensities (0…1), colors, and the freckle density level (0…5). Templated "looks" just set a
/// bundle of these. All bipolar-free (additive) — 0 means that element is off.
struct MakeupRecipe: Codable, Equatable {
    var lips = 0.0
    var lipsColor = MakeupColor(0.80, 0.12, 0.24)       // classic red
    var blush = 0.0
    var blushColor = MakeupColor(0.94, 0.42, 0.46)      // warm pink
    var eyeshadow = 0.0
    var eyeshadowColor = MakeupColor(0.52, 0.30, 0.42)  // mauve
    var eyeliner = 0.0
    var lashes = 0.0
    var brows = 0.0
    var freckles = 0                                    // 0…5 density
    var strength = 1.0                                  // overall multiplier for a chosen look (0…1)

    var isZero: Bool {
        strength <= 0 ||
        (lips == 0 && blush == 0 && eyeshadow == 0 && eyeliner == 0 && lashes == 0 && brows == 0 && freckles == 0)
    }
    /// The recipe with every continuous amount scaled by `strength` (freckles keep their level).
    var scaled: MakeupRecipe {
        var m = self
        m.lips *= strength; m.blush *= strength; m.eyeshadow *= strength
        m.eyeliner *= strength; m.lashes *= strength; m.brows *= strength
        m.strength = 1
        return m
    }
}

/// What to do with the background once the subject is masked out (`FR-CUT-01`). The actual subject mask
/// is computed on-device (Vision) and supplied to the renderer separately — only this lightweight choice
/// lives in the recipe.
enum CutoutBackground: String, Codable, CaseIterable, Identifiable {
    case transparent, blur, white, black
    var id: String { rawValue }
    var label: String {
        switch self {
        case .transparent: return "Transparent"
        case .blur:        return "Blur"
        case .white:       return "White"
        case .black:       return "Black"
        }
    }
    var systemImage: String {
        switch self {
        case .transparent: return "square.dashed"
        case .blur:        return "drop.fill"
        case .white:       return "square.fill"
        case .black:       return "square.fill"
        }
    }
}

/// Crop aspect options offered in the editor (PRD FR-CROP-01). This is a **UI-only** enum (the actual
/// crop lives in `EditRecipe.cropRect`); it controls which chip is highlighted and how an interactive
/// drag is constrained. Named `EditAspect` to avoid colliding with the legacy `CropAspect` in
/// `MediaEditor.swift` (the crop-&-rotate tool).
enum EditAspect: String, CaseIterable, Identifiable {
    case freeform, original, r1x1, r4x5, r3x2, r16x9
    var id: String { rawValue }
    var label: String {
        switch self {
        case .freeform: return "Freeform"
        case .original: return "Original"
        case .r1x1:     return "1:1"
        case .r4x5:     return "4:5"
        case .r3x2:     return "3:2"
        case .r16x9:    return "16:9"
        }
    }
    var systemImage: String {
        switch self {
        case .freeform: return "crop"
        case .original: return "rectangle"
        default:        return "aspectratio"
        }
    }
    /// Fixed width / height the crop box must keep, or nil when unconstrained (Freeform) or when the
    /// constraint is the image's own ratio (Original — supplied at drag time).
    var fixedRatio: CGFloat? {
        switch self {
        case .r1x1:  return 1
        case .r4x5:  return 4.0 / 5.0
        case .r3x2:  return 3.0 / 2.0
        case .r16x9: return 16.0 / 9.0
        default:     return nil
        }
    }
}

/// One light/color/detail/effect adjustment, for the UI to enumerate uniformly. The slider edits the
/// `keyPath` on the recipe; `bipolar` controls draw a center-zero track.
struct Adjustment: Identifiable {
    let id: String
    let name: String
    let systemImage: String
    let keyPath: WritableKeyPath<EditRecipe, Double>
    let range: ClosedRange<Double>
    var bipolar: Bool { range.lowerBound < 0 }

    static let all: [Adjustment] = [
        .init(id: "exposure",   name: "Exposure",   systemImage: "sun.max",            keyPath: \.exposure,   range: -1...1),
        .init(id: "contrast",   name: "Contrast",   systemImage: "circle.lefthalf.filled", keyPath: \.contrast, range: -1...1),
        .init(id: "highlights", name: "Highlights", systemImage: "sun.max.fill",        keyPath: \.highlights, range: -1...1),
        .init(id: "shadows",    name: "Shadows",    systemImage: "moon.fill",           keyPath: \.shadows,    range: -1...1),
        .init(id: "saturation", name: "Saturation", systemImage: "drop.fill",           keyPath: \.saturation, range: -1...1),
        .init(id: "vibrance",   name: "Vibrance",   systemImage: "drop",                keyPath: \.vibrance,   range: -1...1),
        .init(id: "warmth",     name: "Warmth",     systemImage: "thermometer.medium",  keyPath: \.temperature, range: -1...1),
        .init(id: "tint",       name: "Tint",       systemImage: "eyedropper.halffull", keyPath: \.tint,       range: -1...1),
        .init(id: "sharpen",    name: "Sharpen",    systemImage: "triangle",            keyPath: \.sharpen,    range: 0...1),
        .init(id: "structure",  name: "Structure",  systemImage: "square.stack.3d.up",  keyPath: \.structure,  range: -1...1),
        .init(id: "vignette",   name: "Vignette",   systemImage: "circle.dotted",       keyPath: \.vignette,   range: -1...1),
        .init(id: "grain",      name: "Grain",      systemImage: "circle.grid.3x3.fill", keyPath: \.grain,     range: 0...1),
        .init(id: "fade",       name: "Fade",       systemImage: "cloud.fog",           keyPath: \.fade,       range: 0...1),
    ]
}
