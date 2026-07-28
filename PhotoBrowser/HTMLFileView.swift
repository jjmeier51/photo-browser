import SwiftUI
import WebKit

/// Full-screen viewer for a local `.html` file (these are hand-made link sheets with many links and
/// "mark done" checkboxes). Two behaviours the default QuickLook preview couldn't give:
///  • **Links open in the in-app browser**, not Safari — tapping a link presents `WebBrowserView`
///    over this view (so backing out returns here at the same scroll position), where the app's
///    downloaders can act on the page.
///  • **Checkbox state is remembered** across closing/reopening the file. The boxes have no stable
///    ids, so they're keyed by document order (nth checkbox) and persisted on `Library`.
struct HTMLFileView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(Library.self) private var library
    let url: URL
    let targetFolder: URL

    @State private var linkItem: LinkItem?

    private struct LinkItem: Identifiable { let id = UUID(); let value: String }

    var body: some View {
        NavigationStack {
            HTMLWebView(url: url,
                        savedChecks: library.htmlChecks(for: url),
                        onToggle: { index, checked in library.setHtmlCheck(index, checked: checked, for: url) },
                        onOpenLink: { linkItem = LinkItem(value: $0) })
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(url.deletingPathExtension().lastPathComponent)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
        .fullScreenCover(item: $linkItem) { item in
            WebBrowserView(targetFolder: targetFolder, initialURL: item.value)
                .environment(library)
        }
    }
}

/// The WKWebView that renders the local file, routes link taps out to `onOpenLink`, and restores +
/// reports checkbox state.
private struct HTMLWebView: UIViewRepresentable {
    let url: URL
    let savedChecks: [Int]
    let onToggle: (Int, Bool) -> Void
    let onOpenLink: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(savedChecks: savedChecks, onToggle: onToggle, onOpenLink: onOpenLink)
    }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        let ucc = WKUserContentController()
        ucc.add(context.coordinator, name: "checkbox")
        cfg.userContentController = ucc
        let web = WKWebView(frame: .zero, configuration: cfg)
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        web.allowsBackForwardNavigationGestures = false
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

    func updateUIView(_ web: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        private let savedChecks: [Int]
        private let onToggle: (Int, Bool) -> Void
        private let onOpenLink: (String) -> Void

        init(savedChecks: [Int], onToggle: @escaping (Int, Bool) -> Void, onOpenLink: @escaping (String) -> Void) {
            self.savedChecks = savedChecks
            self.onToggle = onToggle
            self.onOpenLink = onOpenLink
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
    }
}
