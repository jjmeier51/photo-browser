import UIKit

/// Centralized haptic feedback so call sites stay one-liners and the underlying
/// `UIFeedbackGenerator`s are reused (allocating a fresh generator per event adds latency and
/// wastes the Taptic Engine "prepare" warm-up). MainActor because UIKit feedback generators are
/// main-bound; the whole app runs default-MainActor-isolated anyway.
///
/// Deliberately tiny and non-throwing: haptics are a nicety, never load-bearing, so every call is
/// best-effort and safe to sprinkle anywhere. Devices without a Taptic Engine simply no-op.
@MainActor
enum Haptics {
    private static let selectionGen = UISelectionFeedbackGenerator()
    private static let lightGen = UIImpactFeedbackGenerator(style: .light)
    private static let mediumGen = UIImpactFeedbackGenerator(style: .medium)
    private static let rigidGen = UIImpactFeedbackGenerator(style: .rigid)
    private static let softGen = UIImpactFeedbackGenerator(style: .soft)
    private static let notificationGen = UINotificationFeedbackGenerator()

    /// A discrete "tick" for moving through a set — multi-select paint, filter/chip changes, scrubbing
    /// past a boundary. The crispest, lowest-key feedback.
    static func selection() { selectionGen.selectionChanged() }

    /// A light tap — favorite toggle, chrome toggle, slideshow advance.
    static func light() { lightGen.impactOccurred() }

    /// A medium tap — a committed action (added to a folder, paste-edit applied).
    static func medium() { mediumGen.impactOccurred() }

    /// A crisp, hard tap for hitting a limit or a precise step — zoom min/max, video frame-step.
    static func rigid(intensity: CGFloat = 1) { rigidGen.impactOccurred(intensity: max(0, min(1, intensity))) }

    /// A soft, muted tap.
    static func soft() { softGen.impactOccurred() }

    static func success() { notificationGen.notificationOccurred(.success) }
    static func warning() { notificationGen.notificationOccurred(.warning) }
    static func error() { notificationGen.notificationOccurred(.error) }

    /// Warm up the generators most likely to fire next (drag-select, scrubbing) to cut first-event
    /// latency. Cheap and best-effort; the engine idles back down on its own.
    static func prepare() { selectionGen.prepare(); lightGen.prepare(); rigidGen.prepare() }
}
