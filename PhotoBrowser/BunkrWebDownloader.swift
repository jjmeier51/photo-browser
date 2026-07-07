import WebKit
import UIKit

/// Downloads bunkr files through **WebKit**, the only client whose TLS/HTTP fingerprint
/// clears bunkr's CDN. The CDN (DDoS-Guard + "Angie") fingerprints the client itself and
/// hard-403s anything that isn't a real browser engine — so no `URLSession` request, with
/// any headers/referer/cookies, can pass it (Safari works, our downloader never could).
///
/// Per file we run exactly what Safari does: a `WKWebView` loads the file's
/// `get.bunkrr.su/file/{id}` hub page (WebKit clears DDoS-Guard there), then we navigate
/// **from that page** to the resolved CDN URL — so the CDN request carries both the real
/// browser fingerprint and a legitimate `get.bunkrr.su` referrer. `WKDownload` captures
/// the bytes untouched (EXIF/HDR preserved) and writes them to the drive folder.
///
/// This is slower than the URLSession path (a small pool of WebViews, not 12-wide) and
/// can't fully background (WebKit stalls when the app is suspended) — accepted costs,
/// since it's the only thing that works. MainActor: WebKit is main-bound.
@MainActor
enum BunkrWebDownloader {
    /// Downloads every item via WebKit, `maxConcurrent` at a time. `onProgress(done)` is
    /// called as each finishes. Returns success/failure counts and a status histogram
    /// (0 = ok) shaped like `downloadOne`'s so the caller's diagnostic is uniform.
    static func download(_ items: [LinkDownloadService.MediaItem], into folder: URL,
                         onProgress: @escaping @MainActor (Int) -> Void)
        async -> (downloaded: Int, failed: Int, statuses: [Int: Int]) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var downloaded = 0, failed = 0, statuses: [Int: Int] = [:]
        var done = 0
        let maxConcurrent = 4

        await withTaskGroup(of: Bool.self) { group in
            var idx = 0
            func addNext() {
                guard idx < items.count else { return }
                let item = items[idx]; idx += 1
                group.addTask { @MainActor in await BunkrWebJob().run(item, into: folder) }
            }
            for _ in 0..<min(maxConcurrent, items.count) { addNext() }
            while let ok = await group.next() {
                done += 1
                if ok { downloaded += 1 } else { failed += 1; statuses[403, default: 0] += 1 }
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
    private var web: WKWebView?
    private var cont: CheckedContinuation<Bool, Never>?
    private var dest: URL?
    private var cdnURL: String = ""
    private var triggered = false
    private var settled = false
    private var watchdog: Task<Void, Never>?

    func run(_ item: LinkDownloadService.MediaItem, into folder: URL) async -> Bool {
        guard let hub = item.referer, let hubURL = URL(string: hub) else { return false }
        // Resolve the CDN URL fresh (bunkr arms it briefly) right before driving the browser.
        let resolved: String?
        if let resolve = item.resolve { resolved = await resolve() }
        else { resolved = item.url.isEmpty ? nil : item.url }
        guard let cdn = resolved else { return false }
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

        return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            cont = c
            w.load(URLRequest(url: hubURL))
            watchdog = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 45_000_000_000)   // whole job ≤ 45s
                self?.finish(false)
            }
        }
    }

    // Hub page finished loading (DDoS-Guard cleared). Navigate to the CDN URL *from here*
    // so the request inherits this page's referrer + WebKit's fingerprint. Give the
    // challenge a beat to settle, and only trigger once.
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !triggered, let host = webView.url?.host, host.contains("bunkrr.su") else { return }
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
    // than saving it. The hub page and any ddos-guard interstitial stay on bunkrr.su /
    // ddos-guard.net, so they fall through to `.allow` and load normally.
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let url = navigationResponse.response.url
        let cdnHost = URL(string: cdnURL)?.host
        let isCDN = (url?.host == cdnHost) || (url?.host?.contains("cdn") ?? false)
        if isCDN {
            let mime = navigationResponse.response.mimeType ?? ""
            if let http = navigationResponse.response as? HTTPURLResponse, http.statusCode >= 400 {
                decisionHandler(.cancel); finish(false); return
            }
            if mime.contains("html") { decisionHandler(.cancel); finish(false); return }
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

    private var pendingTemp: URL?

    func downloadDidFinish(_ download: WKDownload) {
        guard let dest, let tmp = pendingTemp else { finish(false); return }
        let size = (try? tmp.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        if size < 64 { try? FileManager.default.removeItem(at: tmp); finish(false); return }
        try? FileManager.default.removeItem(at: dest)
        do { try FileManager.default.moveItem(at: tmp, to: dest); finish(true) }
        catch { try? FileManager.default.removeItem(at: tmp); finish(false) }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        if let tmp = pendingTemp { try? FileManager.default.removeItem(at: tmp) }
        finish(false)
    }

    // MARK: -

    private func finish(_ ok: Bool) {
        guard !settled else { return }
        settled = true
        watchdog?.cancel(); watchdog = nil
        web?.stopLoading(); web?.removeFromSuperview(); web = nil
        cont?.resume(returning: ok); cont = nil
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
