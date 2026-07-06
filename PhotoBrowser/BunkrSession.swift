import WebKit

/// Solves bunkr's **DDoS-Guard** challenge so its CDN (`*.cdn.cr`) will serve
/// downloads. A plain HTTP request to the CDN 403s no matter the Referer, because
/// the CDN demands the `__ddg*` session cookie that's only granted after a real
/// browser runs the DDoS-Guard JavaScript. We navigate an **offscreen `WKWebView`**
/// to one of the resolved CDN URLs — WebKit renders the challenge page, runs its JS,
/// gets redirected to the file, and the cookie lands in the shared cookie store — then
/// hand those `cdn.cr` cookies to the downloader for every file in the album.
///
/// MainActor: `WKWebView` and `WKHTTPCookieStore` are main-bound. Best-effort — if the
/// challenge doesn't solve in time the downloader just tries without the cookie.
@MainActor
final class BunkrSession: NSObject, WKNavigationDelegate {
    static let shared = BunkrSession()
    private var web: WKWebView?
    private var cont: CheckedContinuation<Void, Never>?
    private var settled = false

    /// Navigates a WKWebView to `cdnURL` to solve DDoS-Guard, then returns the Cookie
    /// header (`name=value; …`) for cookies on `cdn.cr` (empty if none appeared).
    func cdnCookies(cdnURL: String, userAgent: String) async -> String {
        guard let url = URL(string: cdnURL) else { return "" }
        await solve(url, ua: userAgent)
        let cookies: [HTTPCookie] = await withCheckedContinuation { c in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { c.resume(returning: $0) }
        }
        return cookies.filter { $0.domain.hasSuffix("cdn.cr") }
            .map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    private func solve(_ url: URL, ua: String) async {
        settled = false
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()                 // shared store: the cookie persists for downloads
        let w = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 320), configuration: cfg)
        w.customUserAgent = ua                            // must match the download UA (DDoS-Guard binds the cookie to it)
        w.navigationDelegate = self
        web = w
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            cont = c
            w.load(URLRequest(url: url))
            // Hard cap: the challenge usually solves in a few seconds; a media URL may
            // then play and never fire another didFinish, so don't wait forever.
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in self?.settle() }
        }
        web = nil
    }

    private func settle() {
        guard !settled else { return }
        settled = true
        cont?.resume(); cont = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Challenge page solved and redirected. Give the cookie a beat to be written,
        // then finish (the subsequent media load won't fire a clean didFinish).
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.settle() }
    }
}
