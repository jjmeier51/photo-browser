import SwiftUI
import WebKit

/// A built-in browser for Google Drive. You sign in with your normal Google login (the session persists in
/// a private, on-device data store), navigate to any folder, and tap **This Folder** to download every item
/// loaded in the view, or **Selected** to download just the items you've selected. Downloads use the
/// signed-in **web session** (cookies) — no API key/token — and run as an app-wide background task so you
/// can keep using the app while they finish. Nothing is uploaded.
struct GoogleDriveBrowserView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let targetFolder: URL

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
                        Button { download(selectedOnly: true) } label: {
                            Label("Selected", systemImage: "checkmark.circle")
                        }
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

    /// Scrapes the Drive page for item IDs (all loaded, or just the selected ones), grabs the session
    /// cookies, kicks off the background download, and closes so you can keep using the app.
    private func download(selectedOnly: Bool) {
        let js = """
        (function() {
          function ids(sel) {
            return Array.from(document.querySelectorAll(sel))
              .map(function(e) { return e.getAttribute('data-id'); })
              .filter(Boolean);
          }
          var sel = Array.from(new Set(ids('[data-id][aria-selected="true"]')));
          var all = Array.from(new Set(ids('[data-id]')));
          return JSON.stringify({ selected: sel, all: all });
        })();
        """
        webView.evaluateJavaScript(js) { result, _ in
            guard let s = result as? String, let data = s.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: [String]] else { return }
            let ids = selectedOnly ? (obj["selected"] ?? []) : (obj["all"] ?? [])
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
