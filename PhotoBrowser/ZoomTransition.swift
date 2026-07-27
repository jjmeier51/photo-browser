import SwiftUI

/// Shared-element **zoom transition** helpers (iOS 18's `matchedTransitionSource` +
/// `navigationTransition(.zoom:)`), wrapped so call sites stay clean and everything degrades to the
/// standard transition on iOS 17 (the app's deployment target). A grid cell marks itself a source
/// with `zoomSource(id, ns)`; the presented viewer opts in with `zoomDestination(id, ns)` using the
/// tapped item's id — the two are matched by id within the shared namespace, so the cell appears to
/// expand into full screen (and collapse back on dismiss).
extension View {
    /// Marks this view as a zoom-transition source keyed by `id` (iOS 18+); a no-op otherwise.
    @ViewBuilder
    func zoomSource<ID: Hashable & Sendable>(_ id: ID, _ ns: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) {
            self.matchedTransitionSource(id: id, in: ns)
        } else {
            self
        }
    }

    /// Presents this cover/sheet content with a zoom transition from the matching source `id`
    /// (iOS 18+); a no-op when unavailable or when the id/namespace is missing.
    @ViewBuilder
    func zoomDestination<ID: Hashable & Sendable>(_ id: ID?, _ ns: Namespace.ID?) -> some View {
        if #available(iOS 18.0, *), let id, let ns {
            self.navigationTransition(.zoom(sourceID: id, in: ns))
        } else {
            self
        }
    }
}
