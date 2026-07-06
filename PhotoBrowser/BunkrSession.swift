import WebKit
import UIKit

/// Solves bunkr's **DDoS-Guard** challenge so its CDN (`*.cdn.cr`) will serve
/// downloads. A plain HTTP request to the CDN 403s no matter the Referer, because
/// the CDN demands the `__ddg*` session cookie that's only granted after a real
/// browser runs the DDoS-Guard JavaScript (and sometimes solves an interactive
/// check). We present a **visible in-app browser** pointed at one resolved CDN URL:
/// WebKit renders the challenge, runs its JS — and if it escalates to a CAPTCHA the
/// user can tap through it — then the `__ddg` cookie lands in the shared store and we
/// hand those `cdn.cr` cookies to the downloader for every file in the album.
///
/// Why visible, not hidden: an offscreen/detached WKWebView has its JS timers
/// throttled by WebKit, so the challenge never runs (an earlier hidden version always
/// produced `ddg: n`). A foreground, interactive web view is the only reliable way to
/// clear DDoS-Guard. We auto-dismiss the moment the cookie appears, so the user
/// usually just sees a brief "checking your browser…" flash.
///
/// MainActor: WebKit is main-bound. Best-effort — Cancel (or a timeout) returns no
/// cookie and the downloader just tries without it.
@MainActor
final class BunkrSession: NSObject, WKNavigationDelegate {
    static let shared = BunkrSession()

    private var web: WKWebView?
    private var host: UIViewController?
    private var cont: CheckedContinuation<String, Never>?
    private var poll: Task<Void, Never>?
    private var finished = false

    /// Presents the browser at `cdnURL`, waits until the DDoS-Guard cookie appears (or
    /// the user dismisses / a timeout fires), then returns the Cookie header
    /// (`name=value; …`) for `cdn.cr` cookies — empty if the challenge didn't clear.
    func cdnCookies(cdnURL: String, userAgent: String) async -> String {
        guard let url = URL(string: cdnURL), let top = Self.topVC else { return "" }
        finished = false
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
                if (await self.cdnCookies()).contains(where: { $0.name.lowercased().hasPrefix("__ddg") }) {
                    self.finish(); return
                }
            }
            self?.finish()
        }
    }

    @objc private func cancelTapped() { finished = true; complete("") }
    @objc private func useTapped() { finish() }

    /// Harvest whatever cdn.cr cookies exist and complete.
    private func finish() {
        guard !finished else { return }
        finished = true
        Task { [weak self] in
            guard let self else { return }
            let cdn = await self.cdnCookies()
            let header = cdn.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            self.complete(header)
        }
    }

    private func complete(_ header: String) {
        poll?.cancel(); poll = nil
        web?.stopLoading(); web = nil
        host?.dismiss(animated: true); host = nil
        cont?.resume(returning: header); cont = nil
    }

    private func cdnCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { c in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { all in
                c.resume(returning: all.filter { $0.domain.hasSuffix("cdn.cr") })
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
