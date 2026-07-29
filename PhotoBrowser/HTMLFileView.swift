import SwiftUI
import WebKit
import UIKit

/// Full-screen viewer for a local `.html` file (these are hand-made link sheets with many links and
/// "mark done" checkboxes). Behaviours the default QuickLook preview couldn't give:
///  • **Links open in the in-app browser**, not Safari — tapping a link presents `WebBrowserView`
///    over this view (so backing out returns here at the same scroll position), where the app's
///    downloaders can act on the page.
///  • **Checkbox state is remembered** across closing/reopening the file. The boxes have no stable
///    ids, so they're keyed by document order (nth checkbox) and persisted on `Library`.
///  • **Long-press an image to download it** — the same tap-and-hold-to-save gesture the in-app
///    browser has. If the image has a real `http(s)` URL, we offer to save it into the current
///    folder (or another), reusing the browser's proven download path (`WebController`).
struct HTMLFileView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(Library.self) private var library
    let url: URL
    let targetFolder: URL

    @State private var linkItem: LinkItem?
    @State private var imageItem: ImageItem?
    // "Download to Another Folder…" flow: stash the image URL, then present a folder picker.
    @State private var imageForPicker: String?
    @State private var showImageFolderPicker = false
    // Transient "Saved / failed / downloading" banner.
    @State private var toast: String?
    // Text selection is OFF by default so it doesn't fight the long-press-to-download gesture
    // (which was firing only intermittently); the lower-right menu re-enables it for the session.
    @State private var allowTextSelection = false

    private struct LinkItem: Identifiable { let id = UUID(); let value: String }
    private struct ImageItem: Identifiable { let id = UUID(); let url: String }

    var body: some View {
        NavigationStack {
            HTMLWebView(url: url,
                        savedChecks: library.htmlChecks(for: url),
                        allowTextSelection: allowTextSelection,
                        onToggle: { index, checked in library.setHtmlCheck(index, checked: checked, for: url) },
                        onOpenLink: { linkItem = LinkItem(value: $0) },
                        onImageLongPress: { imageItem = ImageItem(url: $0) })
                .ignoresSafeArea(edges: .bottom)
                .overlay(alignment: .top) { toastView }
                .overlay(alignment: .bottomTrailing) { selectionMenu }
                .navigationTitle(url.deletingPathExtension().lastPathComponent)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
        .fullScreenCover(item: $linkItem) { item in
            WebBrowserView(targetFolder: targetFolder, initialURL: item.value)
                .environment(library)
        }
        .confirmationDialog("Download image?",
                            isPresented: Binding(get: { imageItem != nil }, set: { if !$0 { imageItem = nil } }),
                            titleVisibility: .visible, presenting: imageItem) { item in
            Button("Download to “\(targetFolder.lastPathComponent)”") { downloadImage(item.url, into: targetFolder) }
            Button("Download to Another Folder…") {
                imageForPicker = item.url
                DispatchQueue.main.async { showImageFolderPicker = true }   // defer so the dialog dismissal doesn't swallow the sheet
            }
            Button("Copy Image Link") { UIPasteboard.general.string = item.url }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            Text(item.url)
        }
        .sheet(isPresented: $showImageFolderPicker) {
            FolderPicker(root: library.rootURL ?? targetFolder, confirmTitle: "Download Here",
                         startAt: library.lastWebDownloadDestination ?? targetFolder) { folder in
                library.setLastWebDownloadDestination(folder)
                if let u = imageForPicker { downloadImage(u, into: folder) }
                imageForPicker = nil
            }
        }
    }

    /// Downloads an image URL into `folder` via the browser's download engine (cookies, EXIF-verbatim
    /// bytes, drive-safe write, Downloads-sheet progress) — the same path a long-press in the in-app
    /// browser uses. Refreshes the folder listing so the new file appears on the way out.
    private func downloadImage(_ urlString: String, into folder: URL) {
        guard urlString.hasPrefix("http") else { showToast("That image has no downloadable link."); return }
        let file = WebController.PendingFile(url: urlString, pageURL: "", filename: nil)
        showToast("Downloading…")
        WebController.shared.startFileDownload(file, into: folder) { entry in
            switch entry.state {
            case .done: library.contentDidChange(under: folder); showToast("Saved to “\(folder.lastPathComponent)”")
            case .failed: showToast(entry.message ?? "Download failed")
            default: break
            }
        }
    }

    @ViewBuilder private var toastView: some View {
        if let toast {
            Text(toast)
                .font(.subheadline).lineLimit(2)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
                .shadow(color: .black.opacity(0.35), radius: 10, y: 3)
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .allowsHitTesting(false)   // informational only — must never eat taps meant for the page
        }
    }

    private func showToast(_ text: String) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { toast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if toast == text { withAnimation { toast = nil } }
        }
    }

    /// Lower-right menu to re-enable text selection for the session (off by default so it doesn't
    /// interfere with long-press-to-download).
    private var selectionMenu: some View {
        Menu {
            Button { allowTextSelection.toggle() } label: {
                Label(allowTextSelection ? "Turn Off Text Selection" : "Turn On Text Selection",
                      systemImage: allowTextSelection ? "character.cursor.ibeam" : "hand.tap")
            }
        } label: {
            Image(systemName: "ellipsis.circle.fill")
                .font(.title2)
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .black.opacity(0.45))
                .padding(14)
        }
    }
}

/// The WKWebView that renders the local file, routes link taps out to `onOpenLink`, reports an image
/// under a long-press to `onImageLongPress`, and restores + reports checkbox state.
private struct HTMLWebView: UIViewRepresentable {
    let url: URL
    let savedChecks: [Int]
    let allowTextSelection: Bool
    let onToggle: (Int, Bool) -> Void
    let onOpenLink: (String) -> Void
    let onImageLongPress: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(savedChecks: savedChecks, onToggle: onToggle, onOpenLink: onOpenLink, onImageLongPress: onImageLongPress)
    }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        let ucc = WKUserContentController()
        ucc.add(context.coordinator, name: "checkbox")
        // Installs `window.__pbImgAt(x,y)` — the hit-test the long-press uses to find the image
        // under the finger (and a device-width viewport when the file ships none, so points map to
        // CSS pixels). Same detection the in-app browser uses.
        ucc.addUserScript(WKUserScript(source: Self.imageHitTestJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        // Disable text selection/callout by default so it doesn't fight the long-press download
        // (`window.__pbAllowSelect` re-enables it); shared with the in-app browser.
        ucc.addUserScript(WKUserScript(source: WebController.noSelectJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        cfg.userContentController = ucc
        let web = WKWebView(frame: .zero, configuration: cfg)
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        web.allowsBackForwardNavigationGestures = false
        web.allowsLinkPreview = false            // keep long-press ours (image download), not a system peek
        // Long-press to download an image, exactly like the in-app browser. Its delegate lets it
        // recognize alongside the scroll view's pan so scrolling the file still works.
        let lp = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleLongPress(_:)))
        lp.minimumPressDuration = 0.55
        lp.delegate = context.coordinator
        web.addGestureRecognizer(lp)
        // Load the file's bytes ourselves rather than `loadFileURL`: the app process holds the
        // drive's security-scoped access, but WKWebView's separate content process may not — so
        // `loadFileURL` left some on-drive files blank. Reading the data here (off-main; the drive
        // can be slow) and handing over the bytes means the content process needs no file access.
        let fileURL = url
        Task { @MainActor in
            if let data = await Task.detached(priority: .userInitiated, operation: { try? Data(contentsOf: fileURL) }).value {
                web.load(data, mimeType: "text/html", characterEncodingName: "UTF-8",
                         baseURL: fileURL.deletingLastPathComponent())
            } else {
                web.loadHTMLString("<meta name=viewport content='width=device-width,initial-scale=1'>"
                    + "<body style='font-family:-apple-system;padding:2em;color:#888'>Couldn’t open this file.</body>",
                                   baseURL: nil)
            }
        }
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        context.coordinator.applySelection(allowTextSelection, to: web)
    }

    /// Finds, under a point, both the enclosing link (`<a href>` — often the FULL-SIZE image a
    /// thumbnail links to) and the displayed `<img>` / CSS background image, resolving pinch-zoom
    /// via `visualViewport`. Ensures a device-width viewport when the file ships none. Returns
    /// `{link, image}` JSON so Swift can prefer the linked full image over the thumbnail.
    private static let imageHitTestJS = """
    (function(){
      if (window.__pbImgInstalled) return; window.__pbImgInstalled = true;
      try{
        if(!document.querySelector('meta[name="viewport"]')){
          var vp=document.createElement('meta'); vp.name='viewport';
          vp.content='width=device-width, initial-scale=1';
          (document.head||document.documentElement).appendChild(vp);
        }
      }catch(e){}
      window.__pbImgAt = function(x,y){
        try{ var vv=window.visualViewport; if(vv){ x=vv.offsetLeft + x/vv.scale; y=vv.offsetTop + y/vv.scale; } }catch(e){}
        var n = document.elementFromPoint(x,y), link = '', image = '';
        while(n){
          if(!image && n.tagName==='IMG'){
            var s = n.currentSrc || n.src || n.getAttribute('data-src') || '';
            if(s && s.indexOf('data:')!==0) image = s;
          }
          if(!link && n.tagName==='A' && n.href) link = n.href;
          if(!image && n.nodeType===1){
            var bg = getComputedStyle(n).backgroundImage||'';
            var m = bg.match(/url\\(["']?([^"')]+)["']?\\)/);
            if(m && m[1] && m[1].indexOf('data:')!==0) image = m[1];
          }
          n = n.parentElement;
        }
        return JSON.stringify({ link: link, image: image });
      };
    })();
    """

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, UIGestureRecognizerDelegate {
        private let savedChecks: [Int]
        private let onToggle: (Int, Bool) -> Void
        private let onOpenLink: (String) -> Void
        private let onImageLongPress: (String) -> Void
        /// Reused so the long-press haptic doesn't cold-start the Taptic Engine.
        private let haptic = UINotificationFeedbackGenerator()
        /// Last selection state pushed to the page, so `updateUIView` only re-runs the JS on change.
        private var appliedSelect: Bool?

        init(savedChecks: [Int], onToggle: @escaping (Int, Bool) -> Void,
             onOpenLink: @escaping (String) -> Void, onImageLongPress: @escaping (String) -> Void) {
            self.savedChecks = savedChecks
            self.onToggle = onToggle
            self.onOpenLink = onOpenLink
            self.onImageLongPress = onImageLongPress
        }

        /// Turn text selection/callout on or off (the injected script defaults it off at load).
        func applySelection(_ allow: Bool, to web: WKWebView) {
            guard appliedSelect != allow else { return }
            appliedSelect = allow
            web.evaluateJavaScript("window.__pbAllowSelect && window.__pbAllowSelect(\(allow))", completionHandler: nil)
        }

        /// After the file loads: restore the ticked boxes and post back any future changes.
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let json = (try? JSONSerialization.data(withJSONObject: savedChecks))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            let js = """
            (function(){
              var boxes = Array.prototype.slice.call(document.querySelectorAll('input[type=checkbox]'));
              var saved = \(json);
              saved.forEach(function(i){ if (boxes[i]) boxes[i].checked = true; });
              boxes.forEach(function(b, i){
                b.addEventListener('change', function(){
                  try { window.webkit.messageHandlers.checkbox.postMessage({ index: i, checked: b.checked }); } catch (e) {}
                });
              });
            })();
            """
            webView.evaluateJavaScript(js, completionHandler: nil)
            // The page loaded with selection disabled (injected default) — restore a session opt-in.
            if appliedSelect == true {
                webView.evaluateJavaScript("window.__pbAllowSelect && window.__pbAllowSelect(true)", completionHandler: nil)
            }
        }

        /// Route any http/https navigation (a tapped link) to the in-app browser; allow the local
        /// file load and in-page fragments.
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let u = navigationAction.request.url, let s = u.scheme?.lowercased(), s == "http" || s == "https" {
                decisionHandler(.cancel)
                onOpenLink(u.absoluteString)
                return
            }
            decisionHandler(.allow)
        }

        /// `target="_blank"` links come through here instead — send them to the in-app browser too.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let u = navigationAction.request.url, let s = u.scheme?.lowercased(), s == "http" || s == "https" {
                onOpenLink(u.absoluteString)
            }
            return nil
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "checkbox", let body = message.body as? [String: Any],
                  let index = body["index"] as? Int, let checked = body["checked"] as? Bool else { return }
            onToggle(index, checked)
        }

        /// Long-press → ask the page what's under the finger. Prefer the full-size image the
        /// thumbnail LINKS to (an `<a href="…jpg">`) over the displayed `<img>`, which is usually
        /// just a thumbnail — the same priority the in-app browser uses. Falls back to the image
        /// itself when the link doesn't point at a downloadable file.
        @objc func handleLongPress(_ g: UILongPressGestureRecognizer) {
            guard g.state == .began, let web = g.view as? WKWebView else { return }
            haptic.prepare()                     // warm the engine while the JS hit-test round-trips
            let p = g.location(in: web)
            web.evaluateJavaScript("window.__pbImgAt ? window.__pbImgAt(\(Int(p.x)),\(Int(p.y))) : ''") { [weak self] result, _ in
                guard let self else { return }
                var link: String?, image: String?
                if let json = result as? String, let data = json.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    link = (obj["link"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    image = (obj["image"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                }
                // A link to a real file (…jpg/png/mp4/…) is the full-size target — prefer it.
                if let href = link, href.hasPrefix("http"), WebController.looksDownloadable(href) {
                    self.haptic.notificationOccurred(.success)
                    self.onImageLongPress(href)
                    return
                }
                if let img = image, img.hasPrefix("http") {
                    self.haptic.notificationOccurred(.success)
                    self.onImageLongPress(img)
                }
            }
        }

        /// Let the long-press coexist with the web view's own scroll/gesture recognizers, so a press
        /// that turns into a drag still scrolls the page.
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}
