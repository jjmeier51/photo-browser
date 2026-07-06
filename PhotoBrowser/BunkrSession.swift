import WebKit
import UIKit

/// Solves bunkr's **DDoS-Guard** challenge so its CDN (`*.cdn.cr`) will serve
/// downloads. A plain HTTP request to the CDN 403s no matter the Referer, because
/// the CDN demands the `__ddg*` session cookie that's only granted after a real
/// browser runs the DDoS-Guard JavaScript. We navigate a **WKWebView** to one of the
/// resolved CDN URLs — WebKit renders the challenge page, runs its JS, gets the cookie
/// written to the shared store — then hand those `cdn.cr` cookies to the downloader
/// for every file in the album.
///
/// The web view is **attached to the key window** (offscreen, alpha ~0). This is not
/// cosmetic: a *detached* WKWebView has its JS timers throttled/suspended by WebKit,
/// so the challenge never runs and no cookie appears — which is exactly why an earlier
/// off-window version silently produced nothing. We poll the cookie store until the
/// `__ddg` cookie lands (or a hard timeout) rather than guessing on `didFinish`, since
/// the challenge solves on a *second* navigation the first `didFinish` can't see.
///
/// MainActor: `WKWebView` and `WKHTTPCookieStore` are main-bound. Best-effort — if the
/// challenge doesn't solve in time the downloader just tries without the cookie.
@MainActor
final class BunkrSession: NSObject, WKNavigationDelegate {
    static let shared = BunkrSession()
    private var web: WKWebView?

    /// Navigates a WKWebView to `cdnURL` to solve DDoS-Guard, then returns the Cookie
    /// header (`name=value; …`) for cookies on `cdn.cr` (empty if none appeared).
    func cdnCookies(cdnURL: String, userAgent: String) async -> String {
        guard let url = URL(string: cdnURL) else { return "" }
        startLoad(url, ua: userAgent)
        // Poll for up to ~18s: the DDoS-Guard interstitial loads, runs JS for a few
        // seconds, sets the cookie, then reloads to the real file. Return as soon as
        // the pass cookie (`__ddg`) is present rather than waiting the full window.
        var cdn: [HTTPCookie] = []
        for _ in 0..<18 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            cdn = await cookies().filter { $0.domain.hasSuffix("cdn.cr") }
            if cdn.contains(where: { $0.name.lowercased().hasPrefix("__ddg") }) { break }
        }
        teardown()
        return cdn.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    private func startLoad(_ url: URL, ua: String) {
        teardown()
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()                 // shared store: the cookie persists for downloads
        let w = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 400), configuration: cfg)
        w.customUserAgent = ua                            // must match the download UA (DDoS-Guard binds the cookie to it)
        w.navigationDelegate = self
        // Attach offscreen-but-in-window so WebKit actually schedules the challenge's
        // JS timers (a detached web view suspends them and the challenge never runs).
        if let window = Self.keyWindow {
            w.alpha = 0.02
            w.isUserInteractionEnabled = false
            window.addSubview(w)
        }
        web = w
        w.load(URLRequest(url: url))
    }

    private func teardown() {
        web?.stopLoading()
        web?.removeFromSuperview()
        web = nil
    }

    private func cookies() async -> [HTTPCookie] {
        await withCheckedContinuation { c in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { c.resume(returning: $0) }
        }
    }

    private static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
        ?? UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }.first
    }
}
