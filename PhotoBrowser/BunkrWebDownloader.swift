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
    /// One-shot diagnostics surfaced in the failure popup: the hub page's download-element
    /// markup (`pageDebug`) and the first CDN response the click produced — its status +
    /// URL (`respDebug`) — so we can see whether the handler's URL is tokenized and where
    /// it 403s.
    static var pageDebug = ""
    static var respDebug = ""

    static func download(_ items: [LinkDownloadService.MediaItem], into folder: URL, albumURL: String? = nil,
                         log: DownloadLog? = nil,
                         onProgress: @escaping @MainActor (Int) -> Void)
        async -> (downloaded: Int, failed: Int, statuses: [Int: Int], debug: String) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        pageDebug = ""; respDebug = ""
        var downloaded = 0, failed = 0, statuses: [Int: Int] = [:]
        var done = 0
        let maxConcurrent = 4

        // Unlock step: present a VISIBLE browser for the first file. A real user tap on
        // bunkr's Download button carries the user-activation that our synthetic click
        // can't — that's what runs the c1fr-b priming and sets the CDN cookie. We capture
        // that first file, then auto-download the rest through the (now cookie-warmed) pool.
        var pool = items
        if albumURL != nil, let first = items.first {
            await log?.log("unlock: presenting first file — waiting for a manual Download tap…")
            let ok = await BunkrLiveBrowser().run(first, into: folder, log: log)
            done += 1
            if ok { downloaded += 1 } else { failed += 1; statuses[499, default: 0] += 1 }
            onProgress(done)
            let cdn = await BunkrWebSupport.cookieCount("cdn")
            await log?.log("after tap: cdn cookies:\(cdn); auto-downloading remaining \(items.count - 1)")
            pool = Array(items.dropFirst())
        }

        await withTaskGroup(of: Int.self) { group in
            var idx = 0
            func addNext() {
                guard idx < pool.count else { return }
                let item = pool[idx]; let verbose = idx == 0; idx += 1
                // The first auto file logs its full navigation sequence, so we can see whether
                // the CDN cookie the tap set now lets the priming/download proceed.
                group.addTask { @MainActor in await BunkrWebJob().run(item, into: folder, log: log, verbose: verbose) }
            }
            for _ in 0..<min(maxConcurrent, pool.count) { addNext() }
            while let status = await group.next() {
                done += 1
                if status == 0 { downloaded += 1 } else { failed += 1; statuses[status, default: 0] += 1 }
                onProgress(done)
                addNext()
            }
        }
        let debug = [pageDebug, respDebug].filter { !$0.isEmpty }.joined(separator: "; ")
        return (downloaded, failed, statuses, debug)
    }
}

/// One file's WebKit download: hub page → navigate to CDN URL → capture via `WKDownload`.
/// A fresh instance per file keeps the navigation/download delegate state isolated so the
/// pool's concurrent jobs don't interfere.
@MainActor
private final class BunkrWebJob: NSObject, WKNavigationDelegate, WKDownloadDelegate, WKUIDelegate {
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
    private var downloadStarted = false
    private var watchdog: Task<Void, Never>?
    private var clicker: Task<Void, Never>?
    private var pendingTemp: URL?
    private var log: DownloadLog?
    private var name = ""
    private var verbose = false

    func run(_ item: LinkDownloadService.MediaItem, into folder: URL, log: DownloadLog? = nil, verbose: Bool = false) async -> Int {
        self.log = log
        self.verbose = verbose
        name = item.filename
        guard let hub = item.referer, let hubURL = URL(string: hub) else {
            await log?.log("• \(name): no hub URL"); return 404
        }
        // A best-effort CDN URL only sharpens the "is this the CDN response?" host check;
        // we no longer navigate to it (bunkr's own button does), so a resolve miss is fine.
        if let resolve = item.resolve { cdnURL = await resolve() ?? "" }
        else { cdnURL = item.url }
        await log?.log("· \(name): loading hub \(hub); resolved CDN \(cdnURL.isEmpty ? "(none)" : String(cdnURL.prefix(90)))")
        dest = LinkDownloadService.uniqueDestination(
            LinkDownloadService.sanitize(item.filename), in: folder)

        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        let w = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 400), configuration: cfg)
        // Do NOT set a custom User-Agent: a WebKit engine advertising a Windows-Chrome UA
        // is a UA/TLS-fingerprint mismatch that DDoS-Guard blocks. The native iOS Safari
        // UA matches WebKit's fingerprint — exactly what a working Safari download sends.
        w.navigationDelegate = self
        w.uiDelegate = self               // so a target=_blank download opens in this view, not a dropped popup
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

    // Hub page (dl.{host}/file/{id}) finished loading (DDoS-Guard cleared). Click bunkr's
    // *own* Download control and let its JS mint the authorized download in-session — do
    // NOT inject our apidl URL (that URL was fetched by the flagged URLSession client and
    // the CDN 403s it even through WebKit; bunkr's page produces a fresh one that works).
    // Retry every 2s because these pages often gate the button behind a short countdown.
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !triggered, let host = webView.url?.host, host.contains("bunkr") else { return }
        triggered = true
        // One-shot: snapshot the hub page's download-candidate elements so we can see the
        // real button markup in the popup (only if not already captured by another job).
        if BunkrWebDownloader.pageDebug.isEmpty {
            webView.evaluateJavaScript(Self.inspectJS) { result, _ in
                if BunkrWebDownloader.pageDebug.isEmpty, let s = result as? String { BunkrWebDownloader.pageDebug = s }
            }
        }
        clicker = Task { [weak self] in
            for _ in 0..<20 {
                guard let self, !self.settled, !self.downloadStarted else { return }
                self.web?.evaluateJavaScript(Self.clickDownloadJS, completionHandler: nil)
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    /// Reports the hub page's download-candidate elements (tag/id/class/href/text) — or,
    /// if none match, the page's link/button counts and title — so the real markup is
    /// visible for targeting.
    private static let inspectJS = """
    (function(){
      var out=[],els=document.querySelectorAll('a,button');
      for(var i=0;i<els.length&&out.length<6;i++){var e=els[i];
        var t=(e.textContent||'').trim(),h=(e.getAttribute('href')||'');
        var c=((e.className||'')+' '+(e.id||'')).toLowerCase();
        if(h.toLowerCase().indexOf('cdn')>-1||h.toLowerCase().indexOf('download')>-1||
           t.toLowerCase().indexOf('download')>-1||c.indexOf('download')>-1){
          out.push(e.tagName+(e.id?'#'+e.id:'')+'.'+String(e.className||'').split(' ')[0]+
                   '['+h.slice(0,55)+'] "'+t.slice(0,18)+'"');}
      }
      return out.length?out.join(' || '):('none; a='+document.querySelectorAll('a').length+
             ' btn='+document.querySelectorAll('button').length+' t='+document.title.slice(0,40));
    })();
    """

    /// Finds and clicks bunkr's real download control: an anchor/button whose href points
    /// at a CDN, or whose text/class/id says "download". Clicking runs the page's own
    /// handler (which sets `location`/opens a tab to the authorized CDN URL).
    private static let clickDownloadJS = """
    (function(){
      var els=document.querySelectorAll('a,button');
      for(var i=0;i<els.length;i++){var e=els[i];
        var t=(e.textContent||'').trim().toLowerCase();
        var h=(e.getAttribute('href')||'').toLowerCase();
        var c=((e.className||'')+' '+(e.id||'')).toLowerCase();
        if(h.indexOf('.cdn.')>-1||h.indexOf('cdn.')>-1||h.indexOf('/download')>-1||
           t==='download'||t.indexOf('download ')>-1||c.indexOf('download')>-1){
          try{e.removeAttribute('target');}catch(x){}  /* stay in-frame so the referrer survives */
          e.click();return 'ok';}
      }
      return 'none';
    })();
    """

    // The CDN response: force it to download (WebKit would otherwise try to *play* the
    // video). Match by CDN host (so a 30x to another CDN node still counts), and treat a
    // 4xx/5xx or an HTML body (a block/challenge page, not media) as a failure rather
    // than saving it. The hub page and any ddos-guard interstitial stay on bunkr / cdn.cr /
    // ddos-guard.net hosts, so the hub falls through to `.allow` and loads normally.
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let resp = navigationResponse.response
        let http = resp as? HTTPURLResponse
        let status = http?.statusCode ?? 200
        let disposition = (http?.value(forHTTPHeaderField: "Content-Disposition") ?? "").lowercased()
        let url = resp.url

        // Record the last CDN response we see, for diagnostics if the run comes up short.
        if let u = url?.absoluteString, u.contains("cdn") {
            BunkrWebDownloader.respDebug = "cdn \(status) \(disposition.contains("attachment") ? "attach " : "")\(String(u.prefix(70)))"
        }
        if verbose, let u = url?.absoluteString {
            let l = log
            Task { await l?.log("    ← resp \(status)\(disposition.contains("attachment") ? " [attachment]" : ""): \(String(u.prefix(90)))") }
        }

        // The bunkr download is a two-step dance (user-confirmed): the button first hits
        // the CDN, which redirects and sets a DDoS-Guard cookie and *bounces back* to the
        // file page, and only then is the file served with `Content-Disposition: attachment`.
        // Previously we forced EVERY cdn.cr response to download, which intercepted that
        // priming redirect and 403'd it. So: only the actual **attachment** (or a type
        // WebKit can't display, e.g. octet-stream) becomes a download — every other
        // navigation (the priming hit, the redirect, the file page, ddos-guard interstitials)
        // is allowed to proceed so the cookie gets set and the real download can start.
        let isFile = disposition.contains("attachment") || !navigationResponse.canShowMIMEType
        if isFile {
            if status >= 400 { decisionHandler(.cancel); finish(status); return }
            if (resp.mimeType ?? "").contains("html") { decisionHandler(.cancel); finish(409); return }
            downloadStarted = true; clicker?.cancel(); clicker = nil     // stop re-clicking mid-download
            watchdog?.cancel()
            watchdog = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 300_000_000_000)      // ≤ 5 min per file transfer
                self?.finish(408)
            }
            decisionHandler(.download); return
        }
        decisionHandler(.allow)
    }

    // Verbose (first file only): log every navigation the button triggers, so the priming
    // sequence (hub → c1fr-b → back → prxp-b) is visible in the log.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if verbose, let u = navigationAction.request.url?.absoluteString {
            let l = log
            Task { await l?.log("    → nav \(navigationAction.navigationType.rawValue): \(String(u.prefix(95)))") }
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse,
                 didBecome download: WKDownload) {
        download.delegate = self
    }

    // If bunkr's button still opens a new tab, funnel it back into this view so the CDN
    // navigation goes through decidePolicyFor (and becomes a WKDownload) instead of being
    // dropped as an unhandled popup.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Load the popup's *original request* (keeps its Referer) in this view, rather than
        // a bare new request that would drop the referrer and get hotlink-403'd.
        if navigationAction.request.url != nil { webView.load(navigationAction.request) }
        return nil
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
        // Commit via the serialized drive writer (avoids concurrent exFAT directory writes
        // across the pool of jobs, and flushes to disk).
        Task { [weak self] in
            do { try await DriveWriter.shared.commit(tmp, to: dest); self?.finish(0) }
            catch { try? FileManager.default.removeItem(at: tmp); self?.finish(410) }
        }
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
        clicker?.cancel(); clicker = nil
        web?.stopLoading(); web?.removeFromSuperview(); web = nil
        if let log {
            let reason: String
            switch status {
            case 0: reason = "saved"
            case 404: reason = "no CDN url"
            case 408: reason = "timeout (hub/button never produced a download)"
            case 409: reason = "CDN returned HTML (block/challenge, not media)"
            case 410: reason = "download error"
            case 411: reason = "empty file"
            default: reason = "CDN HTTP \(status)"
            }
            let mark = status == 0 ? "✓" : "•"
            let nm = name
            Task { await log.log("\(mark) \(nm): \(reason)") }
        }
        cont?.resume(returning: status); cont = nil
    }

    private static var keyWindow: UIWindow? { BunkrWebSupport.keyWindow }
}

/// Shared helpers for the bunkr WebKit path: the key window (so offscreen web views run
/// their JS) and the session **warm-up** — loading the album page once, like a real
/// browsing session, so the shared cookie store accumulates the DDoS-Guard / CDN cookies
/// Safari has before any download runs (our fresh, un-browsed session is what the CDN 403s).
@MainActor
enum BunkrWebSupport {
    static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
        ?? UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }.first
    }

    /// Count of cookies whose domain contains `needle` (for the warm-up diagnostic).
    static func cookieCount(_ needle: String) async -> Int {
        await withCheckedContinuation { c in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { all in
                c.resume(returning: all.filter { $0.domain.contains(needle) }.count)
            }
        }
    }

    static var topVC: UIViewController? {
        var top = keyWindow?.rootViewController
        while let p = top?.presentedViewController { top = p }
        return top
    }
}

/// A **visible** browser for the album's first file. bunkr's Download button only runs
/// its `c1fr-b` priming (which sets the CDN cookie) for a *real* user tap — a synthetic
/// click lacks the user-activation. So we show the file page, the user taps Download once,
/// and WebKit does the full priming→download. We save that file; the cookie it set then
/// lets the rest of the album download automatically.
@MainActor
private final class BunkrLiveBrowser: NSObject, WKNavigationDelegate, WKDownloadDelegate, WKUIDelegate {
    private var web: WKWebView?
    private var host: UIViewController?
    private var cont: CheckedContinuation<Bool, Never>?
    private var dest: URL?
    private var pendingTemp: URL?
    private var settled = false
    private var watchdog: Task<Void, Never>?
    private var log: DownloadLog?

    func run(_ item: LinkDownloadService.MediaItem, into folder: URL, log: DownloadLog?) async -> Bool {
        self.log = log
        guard let hub = item.referer, let hubURL = URL(string: hub), let top = BunkrWebSupport.topVC else { return false }
        dest = LinkDownloadService.uniqueDestination(LinkDownloadService.sanitize(item.filename), in: folder)

        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        let w = WKWebView(frame: .zero, configuration: cfg)   // native UA + real interaction
        w.navigationDelegate = self
        w.uiDelegate = self
        w.translatesAutoresizingMaskIntoConstraints = false
        web = w

        let banner = UILabel()
        banner.text = "Tap the file's “Download” button once to unlock this album. The rest will download automatically after."
        banner.numberOfLines = 0
        banner.font = .preferredFont(forTextStyle: .callout)
        banner.textAlignment = .center
        banner.translatesAutoresizingMaskIntoConstraints = false

        let vc = UIViewController()
        vc.view.backgroundColor = .systemBackground
        vc.title = "Unlock bunkr album"
        vc.view.addSubview(banner)
        vc.view.addSubview(w)
        NSLayoutConstraint.activate([
            banner.topAnchor.constraint(equalTo: vc.view.safeAreaLayoutGuide.topAnchor, constant: 8),
            banner.leadingAnchor.constraint(equalTo: vc.view.leadingAnchor, constant: 14),
            banner.trailingAnchor.constraint(equalTo: vc.view.trailingAnchor, constant: -14),
            w.topAnchor.constraint(equalTo: banner.bottomAnchor, constant: 8),
            w.leadingAnchor.constraint(equalTo: vc.view.leadingAnchor),
            w.trailingAnchor.constraint(equalTo: vc.view.trailingAnchor),
            w.bottomAnchor.constraint(equalTo: vc.view.bottomAnchor),
        ])
        vc.navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancelTapped))
        let nav = UINavigationController(rootViewController: vc)
        nav.modalPresentationStyle = .fullScreen
        host = nav

        return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            cont = c
            top.present(nav, animated: true)
            w.load(URLRequest(url: hubURL))
            watchdog = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 180_000_000_000)   // 3 min for the user to tap
                self?.finish(false)
            }
        }
    }

    @objc private func cancelTapped() { finish(false) }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let http = navigationResponse.response as? HTTPURLResponse
        let disposition = (http?.value(forHTTPHeaderField: "Content-Disposition") ?? "").lowercased()
        if disposition.contains("attachment") || !navigationResponse.canShowMIMEType {
            decisionHandler(.download); return
        }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.request.url != nil { webView.load(navigationAction.request) }
        return nil
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        guard let dest else { completionHandler(nil); return }
        let tmp = dest.deletingLastPathComponent().appendingPathComponent(".dl-\(UUID().uuidString)")
        pendingTemp = tmp
        completionHandler(tmp)
    }
    func downloadDidFinish(_ download: WKDownload) {
        guard let dest, let tmp = pendingTemp else { finish(false); return }
        Task { [weak self] in
            do { try await DriveWriter.shared.commit(tmp, to: dest); self?.finish(true) }
            catch { try? FileManager.default.removeItem(at: tmp); self?.finish(false) }
        }
    }
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        if let tmp = pendingTemp { try? FileManager.default.removeItem(at: tmp) }
        finish(false)
    }

    private func finish(_ ok: Bool) {
        guard !settled else { return }
        settled = true
        watchdog?.cancel(); watchdog = nil
        web?.stopLoading(); web = nil
        let l = log
        Task { await l?.log(ok ? "✓ first file saved via manual tap — CDN cookie should now be set"
                               : "• first file not saved (cancelled / timed out)") }
        host?.dismiss(animated: true); host = nil
        cont?.resume(returning: ok); cont = nil
    }
}
