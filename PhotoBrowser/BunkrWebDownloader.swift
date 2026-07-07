import WebKit
import UIKit

/// Downloads bunkr files through **WebKit**, the only client whose TLS/HTTP fingerprint
/// clears bunkr's CDN. The CDN (DDoS-Guard + "Angie") fingerprints the client itself and
/// hard-403s anything that isn't a real browser engine — even a correct referer (proven:
/// with `dl.bunkr.cr` referer, URLSession still 403s but Safari downloads fine).
///
/// Per file we run exactly what Safari does: a `WKWebView` loads the file's live hub page
/// `dl.{host}/file/{id}` (WebKit clears DDoS-Guard there), then navigates **from that
/// page** to the resolved CDN URL — so the CDN request carries both the real browser
/// fingerprint and a legitimate `dl.{host}` referrer. `WKDownload` captures the bytes
/// untouched (EXIF/HDR preserved) and writes them to the drive folder.
///
/// This is slower than the URLSession path (a small pool of WebViews, not 12-wide) and
/// can't fully background (WebKit stalls when the app is suspended) — accepted costs,
/// since it's the only thing that works. MainActor: WebKit is main-bound.
@MainActor
enum BunkrWebDownloader {
    /// Downloads every item via WebKit, `maxConcurrent` at a time. `onProgress(done)` is
    /// called as each finishes. Returns success/failure counts and a status histogram
    /// (0 = ok; see `BunkrWebJob` for the failure codes) so the caller's diagnostic shows
    /// *why* it failed rather than a blanket 403.
    static func download(_ items: [LinkDownloadService.MediaItem], into folder: URL,
                         onProgress: @escaping @MainActor (Int) -> Void)
        async -> (downloaded: Int, failed: Int, statuses: [Int: Int]) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var downloaded = 0, failed = 0, statuses: [Int: Int] = [:]
        var done = 0
        let maxConcurrent = 4

        await withTaskGroup(of: Int.self) { group in
            var idx = 0
            func addNext() {
                guard idx < items.count else { return }
                let item = items[idx]; idx += 1
                group.addTask { @MainActor in await BunkrWebJob().run(item, into: folder) }
            }
            for _ in 0..<min(maxConcurrent, items.count) { addNext() }
            while let status = await group.next() {
                done += 1
                if status == 0 { downloaded += 1 } else { failed += 1; statuses[status, default: 0] += 1 }
                onProgress(done)
                addNext()
            }
        }
        return (downloaded, failed, statuses)
    }
}

/// One file's WebKit download: hub page → navigate to CDN URL → capture via `WKDownload`.
/// A fresh instance per file keeps the navigation/download delegate state isolated so the
/// pool's concurrent jobs don't interfere.
@MainActor
private final class BunkrWebJob: NSObject, WKNavigationDelegate, WKDownloadDelegate {
    // Failure codes are HTTP-shaped so the caller's diagnostic renders them as "HTTP N",
    // telling us *where* it broke: 0 ok · 404 no CDN url · 408 timeout (hub/trigger never
    // fired) · 409 CDN served HTML (block/challenge, not media) · 410 download error ·
    // 411 empty file · else the CDN's real status (e.g. 403).
    private var web: WKWebView?
    private var cont: CheckedContinuation<Int, Never>?
    private var dest: URL?
    private var cdnURL: String = ""
    private var triggered = false
    private var settled = false
    private var watchdog: Task<Void, Never>?
    private var pendingTemp: URL?

    func run(_ item: LinkDownloadService.MediaItem, into folder: URL) async -> Int {
        guard let hub = item.referer, let hubURL = URL(string: hub) else { return 404 }
        // Resolve the CDN URL fresh (bunkr arms it briefly) right before driving the browser.
        let resolved: String?
        if let resolve = item.resolve { resolved = await resolve() }
        else { resolved = item.url.isEmpty ? nil : item.url }
        guard let cdn = resolved else { return 404 }
        cdnURL = cdn
        dest = LinkDownloadService.uniqueDestination(
            LinkDownloadService.sanitize(item.filename), in: folder)

        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        let w = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 400), configuration: cfg)
        w.customUserAgent = LinkDownloadService.userAgent
        w.navigationDelegate = self
        if let window = Self.keyWindow {          // in-window so WebKit runs the challenge JS
            w.alpha = 0.02; w.isUserInteractionEnabled = false
            window.addSubview(w)
        }
        web = w

        return await withCheckedContinuation { (c: CheckedContinuation<Int, Never>) in
            cont = c
            w.load(URLRequest(url: hubURL))
            watchdog = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 45_000_000_000)   // whole job ≤ 45s
                self?.finish(408)
            }
        }
    }

    // Hub page (dl.{host}/file/{id}) finished loading (DDoS-Guard cleared). Navigate to the
    // CDN URL *from here* so the request inherits this page's referrer + WebKit's
    // fingerprint. Only the bunkr hub host matches (the CDN is *.cdn.cr, ddos-guard
    // interstitials are on ddos-guard.net) so we trigger exactly once, on the real hub page.
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !triggered, let host = webView.url?.host, host.contains("bunkr") else { return }
        triggered = true
        // referrerPolicy=unsafe-url so the CDN sees the full /file/{id} referrer (browsers
        // strip the path cross-origin by default; gallery-dl confirms the full path works).
        let js = """
        (function(){var a=document.createElement('a');a.href="\(cdnURL)";\
        a.referrerPolicy="unsafe-url";a.rel="noopener";\
        document.body.appendChild(a);setTimeout(function(){a.click();},600);})();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    // The CDN response: force it to download (WebKit would otherwise try to *play* the
    // video). Match by CDN host (so a 30x to another CDN node still counts), and treat a
    // 4xx/5xx or an HTML body (a block/challenge page, not media) as a failure rather
    // than saving it. The hub page and any ddos-guard interstitial stay on bunkr / cdn.cr /
    // ddos-guard.net hosts, so the hub falls through to `.allow` and loads normally.
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let url = navigationResponse.response.url
        let cdnHost = URL(string: cdnURL)?.host
        let isCDN = (url?.host == cdnHost) || (url?.host?.contains("cdn") ?? false)
        if isCDN {
            let mime = navigationResponse.response.mimeType ?? ""
            if let http = navigationResponse.response as? HTTPURLResponse, http.statusCode >= 400 {
                decisionHandler(.cancel); finish(http.statusCode); return
            }
            if mime.contains("html") { decisionHandler(.cancel); finish(409); return }
            decisionHandler(.download); return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse,
                 didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {}
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {}

    // MARK: WKDownloadDelegate

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        // Download to a sibling temp file, then move into place on finish (WKDownload
        // requires a non-existent destination).
        guard let dest else { completionHandler(nil); return }
        let tmp = dest.deletingLastPathComponent()
            .appendingPathComponent(".dl-\(UUID().uuidString)")
        completionHandler(tmp)
        pendingTemp = tmp
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let dest, let tmp = pendingTemp else { finish(410); return }
        let size = (try? tmp.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        if size < 64 { try? FileManager.default.removeItem(at: tmp); finish(411); return }
        try? FileManager.default.removeItem(at: dest)
        do { try FileManager.default.moveItem(at: tmp, to: dest); finish(0) }
        catch { try? FileManager.default.removeItem(at: tmp); finish(410) }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        if let tmp = pendingTemp { try? FileManager.default.removeItem(at: tmp) }
        finish(410)
    }

    // MARK: -

    private func finish(_ status: Int) {
        guard !settled else { return }
        settled = true
        watchdog?.cancel(); watchdog = nil
        web?.stopLoading(); web?.removeFromSuperview(); web = nil
        cont?.resume(returning: status); cont = nil
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
