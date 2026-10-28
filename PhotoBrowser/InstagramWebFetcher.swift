import UIKit
import WebKit

/// Sends Instagram API calls from **inside a logged-in instagram.com page**, for when Instagram
/// refuses the app's own requests. Instagram ties a login to the browser that made it: a call that
/// carries the session cookie but not that browser's fingerprint, its fresh rotating cookies, or the
/// app id its page uses can come back 401/403 "log in" (or a login page) even though the person is
/// logged in — which read as "Couldn’t open @handle" for a public profile. A `fetch()` from the page
/// is exactly what Instagram's own site sends: WebKit's cookies (kept current by every reply), the
/// page's origin and Sec-Fetch headers, the real TLS stack.
///
/// The page is `www.instagram.com/robots.txt` — same origin as the API, so calls are same-origin
/// with cookies, but no Instagram script runs and nothing navigates the page away. The app id is
/// read once from the home page Instagram serves this browser. Same persistent cookie store and
/// User-Agent as `InstagramLoginView`, so it is the very session the person logged in with.
///
/// `@MainActor` because `WKWebView` is main-bound; the network wait happens in WebKit, not on the
/// main thread. Hidden, the web view sits in the key window behind the app's views (like
/// `TikTokWebFetcher`), since a view outside any window has its page suspended.
@MainActor
final class InstagramWebFetcher {
    static let shared = InstagramWebFetcher()

    nonisolated struct Reply: Sendable { let status: Int; let body: Data }

    private var webView: WKWebView?
    private var preparing: Task<Bool, Never>?
    /// The app id the page Instagram serves this browser declares (the mobile site's can differ from
    /// the desktop one the plain path sends). Falls back to the service's.
    private var appID = InstagramService.appID

    private func ensureWebView() -> WKWebView {
        if let webView { return webView }
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()                 // the login's cookies
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.customUserAgent = InstagramService.userAgent   // the UA the login was made with
        wv.isUserInteractionEnabled = false
        webView = wv
        return wv
    }

    /// Park the web view behind everything in the key window (so its page runs), full size.
    private func attachHidden(_ wv: WKWebView) {
        guard wv.window == nil, let window = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first else { return }
        wv.frame = window.bounds
        wv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        window.insertSubview(wv, at: 0)                   // under the root view: never seen, never touched
    }

    /// Puts the web view on the instagram.com origin (once; again if something moved it off).
    private func prepare() async -> Bool {
        if let preparing { return await preparing.value }
        if let wv = webView, wv.window != nil, wv.url?.host == "www.instagram.com" { return true }
        let task = Task { await load() }
        preparing = task
        let ok = await task.value
        preparing = nil
        return ok
    }

    private func load() async -> Bool {
        let wv = ensureWebView()
        attachHidden(wv)
        guard wv.window != nil, let url = URL(string: "https://www.instagram.com/robots.txt") else { return false }
        wv.load(URLRequest(url: url))
        var loaded = false
        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if !wv.isLoading, wv.url?.host == "www.instagram.com" { loaded = true; break }
        }
        guard loaded else { return false }
        // The app id this browser's Instagram pages send (one fetch of the home page per app run).
        let html: String = await withCheckedContinuation { cont in
            wv.callAsyncJavaScript(
                "try { const r = await fetch('/', {credentials: 'include'}); return await r.text(); } catch (e) { return ''; }",
                arguments: [:], in: nil, in: .page) { result in
                cont.resume(returning: ((try? result.get()) as? String) ?? "")
            }
        }
        // The header's own key is unambiguous; a bare "appId" could be another Meta app's, so only
        // Instagram's two known web ids are taken from it.
        let webIDs: Set<String> = ["936619743392459", "1217981644879628"]
        if let id = Self.firstMatch(html, #""X-IG-App-ID":"(\d{6,})""#)
            ?? Self.firstMatch(html, #""appId":"(\d{6,})""#).flatMap({ webIDs.contains($0) ? $0 : nil }) {
            appID = id
        }
        return true
    }

    /// One API call (GET, or a form POST when `form` is given) from the logged-in page. nil when
    /// there's no window to host the page (the app is in the background) or the page can't load.
    func send(_ url: URL, form: String?) async -> Reply? {
        guard await prepare(), let wv = webView else { return nil }
        let js = """
        const m = document.cookie.match(/(?:^|;\\s*)csrftoken=([^;]+)/);
        const headers = {
            'Accept': '*/*',
            'X-IG-App-ID': appID,
            'X-ASBD-ID': asbd,
            'X-Requested-With': 'XMLHttpRequest',
            'X-IG-WWW-Claim': (() => { try { return sessionStorage.getItem('www-claim-v2') || '0'; } catch (e) { return '0'; } })()
        };
        if (m) headers['X-CSRFToken'] = m[1];
        const init = { method: form === null ? 'GET' : 'POST', headers, credentials: 'include' };
        if (form !== null) { headers['Content-Type'] = 'application/x-www-form-urlencoded'; init.body = form; }
        const ctl = new AbortController();
        const timer = setTimeout(() => ctl.abort(), 45000);
        init.signal = ctl.signal;
        try {
            const r = await fetch(url, init);
            const text = await r.text();
            const claim = r.headers.get('x-ig-set-www-claim');
            if (claim) { try { sessionStorage.setItem('www-claim-v2', claim); } catch (e) {} }
            return { status: r.status, body: text };
        } catch (e) {
            return { status: 0, body: String(e) };
        } finally {
            clearTimeout(timer);
        }
        """
        let args: [String: Any] = ["url": url.absoluteString, "form": form ?? NSNull(),
                                   "appID": appID, "asbd": InstagramService.asbdID]
        return await withCheckedContinuation { cont in
            wv.callAsyncJavaScript(js, arguments: args, in: nil, in: .page) { result in
                guard let out = (try? result.get()) as? [String: Any],
                      let status = (out["status"] as? NSNumber)?.intValue, status > 0 else {
                    cont.resume(returning: nil); return
                }
                cont.resume(returning: Reply(status: status, body: Data(((out["body"] as? String) ?? "").utf8)))
            }
        }
    }

    private static func firstMatch(_ s: String, _ pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }
}
