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

    /// True when nothing has been changed (used to gate the Save button / "no edits").
    var isIdentity: Bool { self == EditRecipe() }

    /// True when the geometry is untouched (preview can skip the geometry pass).
    var hasGeometry: Bool {
        rotationQuarters != 0 || flipH || flipV || straighten != 0 || cropRect != nil
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
