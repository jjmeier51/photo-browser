import WebKit
import UIKit

/// Clears bunkr's download-hub protection so its CDN (`*.cdn.cr`) will serve.
///
/// The CDN itself does **not** run a solvable challenge — it hard-403s ("Angie"
/// server) any request that isn't refered from bunkr's download hub,
/// `get.bunkrr.su`. That hub *is* DDoS-Guard-protected (a real JS "checking your
/// browser…" challenge). So we present a **visible in-app browser** at
/// `get.bunkrr.su`, let WebKit run its JS — and if it escalates to a CAPTCHA the user
/// can tap through it — then harvest the resulting session cookie and hand it (with a
/// `get.bunkrr.su` referer, set on each item) to the downloader.
///
/// Why visible, not hidden: an offscreen/detached WKWebView has its JS timers
/// throttled by WebKit, so the challenge never runs (a hidden version always produced
/// `ddg: n`). A foreground, interactive web view is the only reliable way to clear
/// DDoS-Guard. We auto-dismiss the moment a target-domain cookie appears, so the user
/// usually just sees a brief "checking your browser…" flash.
///
/// MainActor: WebKit is main-bound. Best-effort — Cancel (or a timeout) returns no
/// cookie and the downloader just tries with the referer alone.
@MainActor
final class BunkrSession: NSObject, WKNavigationDelegate {
    static let shared = BunkrSession()

    private var web: WKWebView?
    private var host: UIViewController?
    private var cont: CheckedContinuation<String, Never>?
    private var poll: Task<Void, Never>?
    private var finished = false
    private var domains: [String] = []

    /// Presents the browser at `warmupURL`, waits until a cookie appears on one of
    /// `domains` (or the user dismisses / a timeout fires), then returns the Cookie
    /// header (`name=value; …`) for cookies on those domains — empty if it didn't clear.
    func warmCookies(warmupURL: String, domains: [String], userAgent: String) async -> String {
        guard let url = URL(string: warmupURL), let top = Self.topVC else { return "" }
        finished = false
        self.domains = domains
        return await withCheckedContinuation { (c: CheckedContinuation<String, Never>) in
            cont = c
            present(url: url, ua: userAgent, over: top)
        }
    }

    private func present(url: URL, ua: String, over top: UIViewController) {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()                 // shared store: the cookie persists for downloads
        let w = WKWebView(frame: .zero, configuration: cfg)
        w.customUserAgent = ua                            // must match the download UA (DDoS-Guard binds the cookie to it)
        w.navigationDelegate = self
        web = w

        let vc = UIViewController()
        vc.view.backgroundColor = .systemBackground
        w.translatesAutoresizingMaskIntoConstraints = false
        vc.view.addSubview(w)
        NSLayoutConstraint.activate([
            w.topAnchor.constraint(equalTo: vc.view.safeAreaLayoutGuide.topAnchor),
            w.leadingAnchor.constraint(equalTo: vc.view.leadingAnchor),
            w.trailingAnchor.constraint(equalTo: vc.view.trailingAnchor),
            w.bottomAnchor.constraint(equalTo: vc.view.bottomAnchor),
        ])
        vc.title = "Checking your browser…"
        vc.navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancelTapped))
        vc.navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Use", style: .done, target: self, action: #selector(useTapped))
        let nav = UINavigationController(rootViewController: vc)
        nav.modalPresentationStyle = .fullScreen
        host = nav

        top.present(nav, animated: true)
        w.load(URLRequest(url: url))

        // Auto-finish as soon as the DDoS-Guard cookie lands; hard cap at 45s so a
        // stuck challenge doesn't trap the user (they can also Cancel/Use any time).
        poll = Task { [weak self] in
            for _ in 0..<45 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !self.finished else { return }
                if (await self.targetCookies()).contains(where: { $0.name.lowercased().hasPrefix("__ddg") }) {
                    self.finish(); return
                }
            }
            self?.finish()
        }
    }

    @objc private func cancelTapped() { finished = true; complete("") }
    @objc private func useTapped() { finish() }

    /// Harvest whatever target-domain cookies exist and complete.
    private func finish() {
        guard !finished else { return }
        finished = true
        Task { [weak self] in
            guard let self else { return }
            let jar = await self.targetCookies()
            let header = jar.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            self.complete(header)
        }
    }

    private func complete(_ header: String) {
        poll?.cancel(); poll = nil
        web?.stopLoading(); web = nil
        host?.dismiss(animated: true); host = nil
        cont?.resume(returning: header); cont = nil
    }

    private func targetCookies() async -> [HTTPCookie] {
        let doms = domains
        return await withCheckedContinuation { c in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { all in
                c.resume(returning: all.filter { cookie in doms.contains { cookie.domain.hasSuffix($0) } })
            }
        }
    }

    private static var topVC: UIViewController? {
        let root = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }?.rootViewController
        var top = root
        while let p = top?.presentedViewController { top = p }
        return top
    }
}
