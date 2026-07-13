import SwiftUI
import WebKit
import UIKit

/// An in-app web browser with **long-press-to-download video**, like Aloha Browser's core
/// feature. Browse any site; when a video is playing, long-press it and the app offers to save
/// it into the current folder.
///
/// Detection mirrors how these downloaders work: an injected script (a) hooks `fetch`/`XHR` to
/// capture media URLs the page requests (direct files and `.m3u8` HLS playlists), and (b) reports
/// the `<video>` under a long-press point. `WebVideoDownloader` then fetches + assembles the
/// video (carrying the browser's cookies + Referer). DRM (Widevine/FairPlay) and pure-`blob:`
/// MSE with no discoverable manifest can't be captured — the same limits Aloha has.
struct WebBrowserView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let targetFolder: URL

    @StateObject private var controller = WebController()
    @State private var address = ""
    @State private var editingAddress = false
    @State private var pending: WebController.FoundVideo?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                addressBar
                if controller.isLoading {
                    ProgressView(value: controller.progress)
                        .progressViewStyle(.linear).tint(.accentColor)
                        .frame(height: 2)
                }
                WebViewContainer(controller: controller)
                    .ignoresSafeArea(edges: .bottom)
                bottomBar
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    if controller.hasVideo {
                        Image(systemName: "video.badge.checkmark").foregroundStyle(.green)
                            .accessibilityLabel("A downloadable video is playing")
                    }
                }
            }
        }
        .onAppear {
            controller.onVideoLongPress = { found in pending = found }
            if controller.currentURLString.isEmpty { controller.load("https://www.google.com") }
        }
        .onDisappear { controller.teardown() }
        .confirmationDialog("Download video?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            titleVisibility: .visible, presenting: pending) { v in
            Button("Download to “\(targetFolder.lastPathComponent)”") { startDownload(v) }
            Button("Copy Video Link") { UIPasteboard.general.string = v.url }
            Button("Cancel", role: .cancel) {}
        } message: { v in
            Text(v.isHLS ? "This is a streaming video — it’ll be fetched and merged into one file."
                         : "Save this video into your folder.")
        }
    }

    private var addressBar: some View {
        HStack(spacing: 8) {
            Image(systemName: controller.currentURLString.hasPrefix("https") ? "lock.fill" : "globe")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Search or enter website", text: $address)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .keyboardType(.webSearch).submitLabel(.go)
                .onSubmit { controller.load(address); editingAddress = false }
                .onTapGesture { editingAddress = true }
            if controller.isLoading {
                Button { controller.stop() } label: { Image(systemName: "xmark") }
            } else {
                Button { controller.reload() } label: { Image(systemName: "arrow.clockwise") }
            }
        }
        .font(.callout)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .onChange(of: controller.currentURLString) { _, new in if !editingAddress { address = new } }
    }

    private var bottomBar: some View {
        VStack(spacing: 4) {
            Text(controller.hasVideo ? "Video detected — long-press it, or tap ⬇︎ to download"
                                     : "Long-press a playing video to download it")
                .font(.caption2).foregroundStyle(controller.hasVideo ? .green : .secondary)
            HStack {
                Button { controller.goBack() } label: { Image(systemName: "chevron.left") }.disabled(!controller.canGoBack)
                Spacer()
                Button { controller.goForward() } label: { Image(systemName: "chevron.right") }.disabled(!controller.canGoForward)
                Spacer()
                if controller.hasVideo, let v = controller.bestVideo() {
                    Button { pending = v } label: { Image(systemName: "arrow.down.circle.fill").foregroundStyle(.green) }
                } else {
                    Image(systemName: "arrow.down.circle").opacity(0.25)
                }
                Spacer()
                Menu {
                    Button { controller.load("https://www.google.com") } label: { Label("Home", systemImage: "house") }
                    Button { UIPasteboard.general.string = controller.currentURLString } label: { Label("Copy Page Link", systemImage: "doc.on.doc") }
                } label: { Image(systemName: "ellipsis.circle") }
            }
            .font(.title3)
        }
        .padding(.horizontal, 24).padding(.top, 5).padding(.bottom, 10)
        .background(.ultraThinMaterial)
    }

    private func startDownload(_ v: WebController.FoundVideo) {
        let folder = targetFolder
        let id = library.beginActivity("Downloading video", indeterminate: true)
        library.setActivity(id, status: "Starting…")
        let title = controller.pageTitle
        Task {
            let cookieHeader = await controller.cookieHeader(forURLString: v.url)
            let outcome = await WebVideoDownloader.download(
                urlString: v.url, pageURL: v.pageURL, cookieHeader: cookieHeader,
                into: folder, suggestedName: title) { p in
                    Task { @MainActor in library.setActivity(id, status: p.phase, fraction: p.fraction > 0 ? p.fraction : nil) }
                }
            switch outcome {
            case .saved:
                library.endActivity(id, result: "Saved the video to “\(folder.lastPathComponent)”.")
                library.contentDidChange(under: folder)
            case .failed(let msg):
                library.endActivity(id, result: msg)
            }
        }
    }
}

/// Embeds the controller's `WKWebView`.
private struct WebViewContainer: UIViewRepresentable {
    let controller: WebController
    func makeUIView(context: Context) -> WKWebView { controller.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

/// Owns and drives the `WKWebView`: navigation state, injected media-detection script, the
/// long-press handler, and cookie extraction for downloads.
@MainActor
final class WebController: NSObject, ObservableObject, WKNavigationDelegate, WKScriptMessageHandler, UIGestureRecognizerDelegate {
    struct FoundVideo: Identifiable { let id = UUID(); let url: String; let pageURL: String
        var isHLS: Bool { url.lowercased().contains(".m3u8") }
    }

    @Published var currentURLString = ""
    @Published var pageTitle = ""
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var progress: Double = 0
    @Published var isLoading = false
    @Published var hasVideo = false

    var onVideoLongPress: ((FoundVideo) -> Void)?

    /// Media URLs the page has requested (direct files + `.m3u8`), newest last.
    private var captured: [String] = []
    /// The `<video>` element's own current source (may be a `blob:` for MSE).
    private var playingSrc: String?

    override init() { super.init() }

    lazy var webView: WKWebView = {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []     // let videos play so they're detectable
        cfg.websiteDataStore = .default()                     // persistent cookies (logins / hotlink gates)
        let ucc = WKUserContentController()
        ucc.add(WeakScriptHandler(self), name: "pb")          // weak: avoid the config→handler→config retain cycle
        ucc.addUserScript(WKUserScript(source: Self.detectorJS, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        cfg.userContentController = ucc
        let web = WKWebView(frame: .zero, configuration: cfg)
        web.navigationDelegate = self
        web.allowsBackForwardNavigationGestures = true
        web.customUserAgent = WebVideoDownloader.userAgent
        for kp in ["estimatedProgress", "title", "URL", "canGoBack", "canGoForward", "loading"] {
            web.addObserver(self, forKeyPath: kp, options: .new, context: nil)
        }
        let lp = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        lp.minimumPressDuration = 0.55
        lp.delegate = self
        web.addGestureRecognizer(lp)
        return web
    }()

    // MARK: Navigation commands

    func load(_ text: String) {
        guard let url = Self.normalizeURL(text) else { return }
        webView.load(URLRequest(url: url))
    }
    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload() { webView.reload() }
    func stop() { webView.stopLoading() }

    /// The best downloadable URL currently known (video src or captured media).
    func bestVideo() -> FoundVideo? {
        guard let url = Self.pickBest(src: playingSrc, media: captured) else { return nil }
        return FoundVideo(url: url, pageURL: currentURLString)
    }

    // MARK: KVO → published state

    nonisolated override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                                           change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        // WebKit posts KVO on the main thread; assert that so we can touch MainActor state.
        MainActor.assumeIsolated {
            switch keyPath {
            case "estimatedProgress": progress = webView.estimatedProgress
            case "title": pageTitle = webView.title ?? ""
            case "URL": currentURLString = webView.url?.absoluteString ?? currentURLString
            case "canGoBack": canGoBack = webView.canGoBack
            case "canGoForward": canGoForward = webView.canGoForward
            case "loading": isLoading = webView.isLoading
            default: break
            }
        }
    }

    // MARK: WKNavigationDelegate — reset detection per page

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        captured.removeAll(); playingSrc = nil; hasVideo = false
    }

    // MARK: WKScriptMessageHandler — media capture

    nonisolated func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        let url = (body["url"] as? String) ?? ""
        Task { @MainActor in
            switch type {
            case "media":
                if !url.isEmpty, !self.captured.contains(url) { self.captured.append(url); if self.captured.count > 40 { self.captured.removeFirst() } }
            case "playing":
                if !url.isEmpty { self.playingSrc = url }
                self.hasVideo = true
            default: break
            }
            if Self.pickBest(src: self.playingSrc, media: self.captured) != nil { self.hasVideo = true }
        }
    }

    // MARK: Long-press → find the video under the finger

    @objc private func handleLongPress(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began else { return }
        let p = g.location(in: webView)
        let js = "window.__pbVideoAt ? window.__pbVideoAt(\(Int(p.x)),\(Int(p.y))) : null"
        webView.evaluateJavaScript(js) { [weak self] result, _ in
          MainActor.assumeIsolated {
            guard let self else { return }
            var src: String?
            var media: [String] = self.captured
            if let json = result as? String, let data = json.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                src = obj["src"] as? String
                if let m = obj["media"] as? [String] { media = self.captured + m }
            }
            // Fall back to the page's known video if the hit-test missed but media exists.
            let effectiveSrc = src ?? self.playingSrc
            guard let best = Self.pickBest(src: effectiveSrc, media: media) else { return }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            self.onVideoLongPress?(FoundVideo(url: best, pageURL: self.currentURLString))
          }
        }
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    // MARK: Cookies for the downloader

    /// The cookie header (`name=value; …`) the download should send to the media host.
    func cookieHeader(forURLString urlString: String) async -> String {
        guard let host = URL(string: urlString)?.host else { return "" }
        let store = webView.configuration.websiteDataStore.httpCookieStore
        let cookies: [HTTPCookie] = await withCheckedContinuation { cont in
            store.getAllCookies { cont.resume(returning: $0) }
        }
        return cookies.filter { c in
            let d = c.domain.hasPrefix(".") ? String(c.domain.dropFirst()) : c.domain
            return host == d || host.hasSuffix("." + d) || d.hasSuffix(host)
        }.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    // MARK: Helpers

    /// Pick the best downloadable URL: prefer an HLS playlist (a full stream), then a file-like
    /// direct source, then any captured direct file. `blob:`/`data:` sources are unusable.
    static func pickBest(src: String?, media: [String]) -> String? {
        func fileLike(_ s: String) -> Bool {
            let l = s.lowercased()
            return ["\\.mp4", "\\.m4v", "\\.mov", "\\.webm"].contains { l.range(of: $0, options: .regularExpression) != nil }
        }
        let usableSrc = (src?.hasPrefix("http") == true) ? src : nil
        if let m3u8 = media.last(where: { $0.lowercased().contains(".m3u8") }) { return m3u8 }
        if let s = usableSrc, fileLike(s) { return s }
        if let f = media.last(where: { fileLike($0) }) { return f }
        if let s = usableSrc, s.lowercased().contains(".m3u8") { return s }
        return usableSrc
    }

    static func normalizeURL(_ text: String) -> URL? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if t.hasPrefix("http://") || t.hasPrefix("https://") { return URL(string: t) }
        // Looks like a domain? (has a dot, no spaces) → prepend https. Otherwise Google-search it.
        if !t.contains(" "), t.contains("."), !t.hasSuffix(".") {
            return URL(string: "https://\(t)")
        }
        let q = t.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? t
        return URL(string: "https://www.google.com/search?q=\(q)")
    }

    private var teardownDone = false
    /// Remove KVO observers + the script handler while still on the main actor (called from the
    /// view's `onDisappear`, before dealloc) — a nonisolated `deinit` can't safely touch these.
    func teardown() {
        guard !teardownDone else { return }
        teardownDone = true
        for kp in ["estimatedProgress", "title", "URL", "canGoBack", "canGoForward", "loading"] {
            webView.removeObserver(self, forKeyPath: kp)
        }
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "pb")
        webView.stopLoading()
    }

    /// Injected at document start into every frame: capture media requests + report the video
    /// under a point for long-press.
    private static let detectorJS = """
    (function(){
      if (window.__pbInstalled) return; window.__pbInstalled = true;
      var seen = {};
      function post(m){ try{ window.webkit.messageHandlers.pb.postMessage(m); }catch(e){} }
      function add(u){
        if(!u || typeof u !== 'string') return;
        try{ u = new URL(u, location.href).href; }catch(e){ return; }
        if(u.indexOf('blob:')===0 || u.indexOf('data:')===0) return;
        if(/\\.(m3u8|mp4|m4v|mov|webm)(\\?|#|$)/i.test(u) && !seen[u]){ seen[u]=1; post({type:'media', url:u}); }
      }
      try {
        var of = window.fetch;
        if (of) window.fetch = function(){ try{ var a=arguments[0]; add(a && (a.url||a)); }catch(e){}; return of.apply(this, arguments); };
      } catch(e){}
      try {
        var oo = XMLHttpRequest.prototype.open;
        XMLHttpRequest.prototype.open = function(m,u){ try{ add(u); }catch(e){}; return oo.apply(this, arguments); };
      } catch(e){}
      document.addEventListener('playing', function(e){
        var v=e.target; if(v && v.tagName==='VIDEO'){ add(v.currentSrc||v.src); post({type:'playing', url: v.currentSrc||v.src||''}); }
      }, true);
      window.__pbVideoAt = function(x,y){
        var el = document.elementFromPoint(x,y), v=null, n=el;
        while(n){ if(n.tagName==='VIDEO'){ v=n; break; } n=n.parentElement; }
        if(!v){ var vids=document.querySelectorAll('video'); if(vids.length===1) v=vids[0]; else {
          for(var i=0;i<vids.length;i++){ if(!vids[i].paused){ v=vids[i]; break; } } } }
        if(!v) return null;
        var srcs=[]; if(v.currentSrc) srcs.push(v.currentSrc); if(v.src) srcs.push(v.src);
        var ss=v.querySelectorAll('source'); for(var j=0;j<ss.length;j++){ if(ss[j].src) srcs.push(ss[j].src); }
        return JSON.stringify({ src: v.currentSrc||v.src||'', media: srcs });
      };
    })();
    """
}

/// Weak forwarder so `WKUserContentController` doesn't strongly retain the controller (which the
/// web view — and its config — already own), avoiding a leak that keeps the browser alive.
private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(ucc, didReceive: message)
    }
}
