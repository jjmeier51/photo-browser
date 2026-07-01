import SwiftUI
import WebKit

/// A built-in browser for Google Drive. You sign in with your normal Google login (the session persists in
/// a private, on-device data store), navigate to a folder, then either download **This Folder** (every item
/// loaded in the view) or turn on **Select** and tap items to pick specific ones.
///
/// Google Drive's *mobile web* UI has no usable multi-select (a tap just opens the item), so Select mode
/// injects our own tap-to-select layer: while it's on, tapping an item toggles a highlight instead of
/// opening it. Downloads use the signed-in **web session** (cookies) — no API key/token — and run as an
/// app-wide background task so you can keep using the app. Nothing is uploaded.
struct GoogleDriveBrowserView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let targetFolder: URL

    @State private var selectMode = false

    @State private var webView: WKWebView = {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()        // persistent — the Google sign-in sticks across launches
        let wv = WKWebView(frame: .zero, configuration: cfg)
        // A real Safari UA — Google often blocks sign-in in an embedded web view with the default UA.
        wv.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        wv.allowsBackForwardNavigationGestures = true
        return wv
    }()

    var body: some View {
        NavigationStack {
            DriveWebView(webView: webView)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Google Drive")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { webView.goBack() } label: { Image(systemName: "chevron.left") }
                    }
                    ToolbarItemGroup(placement: .bottomBar) {
                        Button { toggleSelectMode() } label: {
                            Label(selectMode ? "Selecting" : "Select",
                                  systemImage: selectMode ? "checkmark.circle.fill" : "checkmark.circle")
                        }
                        .tint(selectMode ? .accentColor : nil)
                        Spacer()
                        Button { download(selectedOnly: true) } label: {
                            Label("Selected", systemImage: "arrow.down.circle")
                        }
                        .disabled(!selectMode)
                        Spacer()
                        Button { download(selectedOnly: false) } label: {
                            Label("This Folder", systemImage: "square.and.arrow.down")
                        }
                    }
                }
                .onAppear {
                    if webView.url == nil,
                       let url = URL(string: "https://drive.google.com/drive/my-drive") {
                        webView.load(URLRequest(url: url))
                    }
                }
        }
    }

    /// Turns tap-to-select on/off. While on, a document-level capture-phase click handler intercepts taps on
    /// Drive items (elements carrying a `data-id`), toggles a blue outline + a tracked set, and prevents the
    /// default open/navigate. While off, taps behave normally so you can browse into folders.
    private func toggleSelectMode() {
        selectMode.toggle()
        let js = """
        (function() {
          window.__pbSel = window.__pbSel || {};
          window.__pbSelectMode = \(selectMode ? "true" : "false");
          if (!window.__pbInstalled) {
            window.__pbInstalled = true;
            document.addEventListener('click', function(e) {
              if (!window.__pbSelectMode) return;
              var el = e.target.closest('[data-id]');
              if (!el) return;
              e.preventDefault(); e.stopImmediatePropagation();
              var id = el.getAttribute('data-id');
              if (window.__pbSel[id]) { delete window.__pbSel[id]; el.style.outline = ''; }
              else { window.__pbSel[id] = true; el.style.outline = '3px solid #4285F4'; el.style.outlineOffset = '-3px'; }
            }, true);
          }
          return '';
        })();
        """
        webView.evaluateJavaScript(js)
    }

    /// Reads the item IDs (the tap-selected set, or every loaded item), grabs the session cookies, starts the
    /// background download, and closes so you can keep using the app.
    private func download(selectedOnly: Bool) {
        let js = selectedOnly
            ? "JSON.stringify(Object.keys(window.__pbSel || {}));"
            : "JSON.stringify(Array.from(new Set(Array.from(document.querySelectorAll('[data-id]')).map(function(e){return e.getAttribute('data-id');}).filter(Boolean))));"
        webView.evaluateJavaScript(js) { result, _ in
            guard let s = result as? String, let data = s.data(using: .utf8),
                  let ids = (try? JSONSerialization.jsonObject(with: data)) as? [String] else { return }
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                let header = cookies.filter { $0.domain.contains("google.com") }
                    .map { "\($0.name)=\($0.value)" }
                    .joined(separator: "; ")
                library.startGoogleDriveCookieDownload(fileIDs: ids, cookieHeader: header, into: targetFolder)
                dismiss()
            }
        }
    }
}

private struct DriveWebView: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
