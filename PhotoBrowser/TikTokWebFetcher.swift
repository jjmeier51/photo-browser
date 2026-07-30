import UIKit
import WebKit

/// Fetches tikwm resolver URLs through a real WebKit browser, so Cloudflare's bot check — which
/// answers a plain `URLSession` request with **HTTP 403 + a block page** (the "resolver returned a
/// block page" failure) — is passed by actually running its JavaScript challenge. Once WebKit
/// clears the challenge it banks a `cf_clearance` cookie (persistent data store), so later fetches
/// in the session return the JSON immediately.
///
/// `@MainActor` because `WKWebView` is main-bound. The web view is kept **in the key window** at a
/// tiny, effectively-invisible size: a view detached from any window has its JavaScript timers
/// throttled/suspended, so the Cloudflare challenge would never finish. The response body (the JSON
/// the API returns) is read straight out of the rendered page.
@MainActor
final class TikTokWebFetcher: NSObject {
    static let shared = TikTokWebFetcher()

    private var webView: WKWebView?

    private func ensureWebView() -> WKWebView {
        if let webView { return webView }
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()          // persist cf_clearance across calls
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 2, height: 2), configuration: cfg)
        // Use WebKit's own genuine UA (don't spoof) — Cloudflare validates the challenge against the
        // UA, and a real one is what actually clears.
        wv.isOpaque = false
        wv.alpha = 0.02                            // present (so JS runs) but imperceptible
        wv.isUserInteractionEnabled = false
        if let window = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first {
            window.addSubview(wv)                  // attach off-screen so its JavaScript actually runs
        }
        webView = wv
        return wv
    }

    /// Loads `url` and returns its body parsed as JSON, waiting (up to ~20s) for Cloudflare to clear.
    /// Returns nil on timeout, a hard block (non-JSON body), or if there's no key window to host the
    /// web view (e.g. the app is backgrounded). Call serially — a new load supersedes any in flight.
    func fetchJSON(_ url: URL) async -> [String: Any]? {
        let wv = ensureWebView()
        guard wv.window != nil else { return nil }   // no window → JS won't run → pointless
        wv.stopLoading()
        wv.load(URLRequest(url: url))
        // Poll the body text until it parses as JSON (challenge passed) or we give up. The challenge
        // page's text isn't JSON, so it's simply skipped until the real response replaces it.
        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            let text: String? = await withCheckedContinuation { cont in
                wv.evaluateJavaScript(Self.bodyTextJS) { result, _ in cont.resume(returning: result as? String) }
            }
            guard let text, !text.isEmpty, let data = text.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            return obj
        }
        return nil
    }

    private static let bodyTextJS =
        "(document.body && document.body.innerText) || (document.documentElement && document.documentElement.textContent) || ''"
}
