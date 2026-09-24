import SwiftUI
import UIKit

/// Presents a SwiftUI view as a sheet on **whatever is top-most right now** — over the viewer's
/// full-screen cover, over another sheet, wherever the user happens to be.
///
/// Why not a `.sheet` on the root view: SwiftUI routes every presentation in the window through the
/// one hosting controller, and UIKit refuses a second presentation while that controller already has
/// one up ("already presenting"). So a results sheet driven from `ContentView` silently failed to
/// appear whenever the viewer (or the editor, or a picker) was open — which is exactly when most AI
/// jobs are started and finish. The finished images then sat in memory with no way to reach them.
/// Walking the `presentedViewController` chain and presenting on its end sidesteps that entirely.
///
/// A presentation that can't happen *yet* (the top controller is mid-transition, or is an alert,
/// which can't present) is retried on a short timer until it can — never dropped.
@MainActor
enum ModalPresenter {
    /// Presents `view` as a page sheet on the top-most controller. `modalInPresentation` disables
    /// swipe-to-dismiss (the view must dismiss itself via `@Environment(\.dismiss)`).
    static func present<V: View>(_ view: V, modalInPresentation: Bool = false) {
        guard let top = topViewController, canPresent(from: top) else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { present(view, modalInPresentation: modalInPresentation) }
            return
        }
        let host = UIHostingController(rootView: view)
        host.modalPresentationStyle = .pageSheet
        host.isModalInPresentation = modalInPresentation
        host.overrideUserInterfaceStyle = .dark     // the app forces dark; a UIKit-presented host doesn't inherit it
        top.present(host, animated: true)
    }

    /// The end of the presentation chain from the key window's root.
    static var topViewController: UIViewController? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
        let window = windows.first { $0.isKeyWindow } ?? windows.first
        var top = window?.rootViewController
        while let p = top?.presentedViewController { top = p }
        return top
    }

    /// False while `vc` is appearing/disappearing (presenting then throws "already presenting" or
    /// gets swallowed) or is an alert (which can't present anything).
    private static func canPresent(from vc: UIViewController) -> Bool {
        if vc is UIAlertController { return false }
        if vc.isBeingDismissed || vc.isBeingPresented { return false }
        if vc.view.window == nil { return false }
        return true
    }
}
