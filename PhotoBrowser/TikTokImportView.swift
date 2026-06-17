import SwiftUI
import WebKit
import Observation

/// "Download TikTok Profile": opens the profile in a real in-app web view (so
/// TikTok's lazy-loaded video grid actually populates and any login/captcha can be
/// handled), auto-scrolls to harvest every video link, then downloads each video
/// (highest quality, HDR preserved, post date + caption set) into an "@handle"
/// folder shown as a highlight bubble like the Instagram one. Reposts are skipped.
/// Best-effort: TikTok actively blocks scraping, so this can be flaky.
struct TikTokImportView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let targetFolder: URL
    let onFinished: () -> Void

    @State private var scraper = TikTokScraper()
    @State private var handle = ""
    @State private var opened = false
    @State private var running = false
    @State private var progress = TikTokService.Progress(phase: "", fraction: 0, done: 0, total: 0)
    @State private var result: TikTokService.DownloadResult?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    TextField("tiktok handle (e.g. zachking)", text: $handle)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder).disabled(running)
                    Button("Open") { open() }
                        .buttonStyle(.bordered).disabled(running || username.isEmpty)
                }
                .padding(.horizontal).padding(.vertical, 8)

                WebViewHolder(webView: scraper.webView)
                    .overlay { if running { overlay } }

                if let result {
                    Text(summary(result)).font(.callout)
                        .foregroundStyle(result.videos > 0 ? .green : .orange)
                        .padding(8).frame(maxWidth: .infinity)
                        .background(.bar)
                }
            }
            .navigationTitle("TikTok")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(running)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(result != nil ? "Done" : "Cancel") { dismiss() }.disabled(running)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Download All") { start() }.disabled(running || !opened)
                }
            }
            .safeAreaInset(edge: .bottom) {
                Text(opened ? "Log in if prompted, then tap Download All. It scrolls the profile to find every video."
                            : "Enter a handle and tap Open. You can log in in the page below if TikTok asks.")
                    .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .padding(8).frame(maxWidth: .infinity).background(.bar)
            }
        }
    }

    private var username: String { TikTokService.sanitizeHandle(handle) }

    private var overlay: some View {
        VStack(spacing: 12) {
            ProgressView(value: progress.total > 0 ? progress.fraction : 0).progressViewStyle(.linear).frame(width: 220)
            Text(progress.total > 0 ? "Downloading \(progress.done) of \(progress.total)…" : (scraper.status.isEmpty ? progress.phase : scraper.status))
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(20).frame(maxWidth: 280)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func summary(_ r: TikTokService.DownloadResult) -> String {
        guard r.videos > 0 else { return r.note ?? "Nothing downloaded." }
        var s = "Downloaded \(r.videos) video\(r.videos == 1 ? "" : "s")"
        if r.skippedReposts > 0 { s += " (skipped \(r.skippedReposts) repost\(r.skippedReposts == 1 ? "" : "s"))" }
        return s + "."
    }

    private func open() {
        guard !username.isEmpty else { return }
        scraper.load("https://www.tiktok.com/@\(username)")
        opened = true
    }

    private func start() {
        let user = username
        guard !user.isEmpty else { return }
        running = true; result = nil
        let bg = BackgroundTaskHolder(); bg.begin(name: "TikTok Download")
        Task {
            let urls = await scraper.scanVideos()
            let cookie = await TikTokAuth.cookieHeader()
            // Reuse an existing "@handle" folder — dedup happens by video-id filename.
            let dest = targetFolder.appendingPathComponent("@\(user)", isDirectory: true)
            try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

            let r = await TikTokService.run(username: user, videoURLs: urls, into: dest,
                                            cookie: cookie, alreadyDownloaded: []) { p in
                Task { @MainActor in progress = p }
            }
            library.setCaptions(r.captions)
            if let avatar = r.avatar, let img = UIImage(data: avatar) { library.setCover(img, for: dest) }
            if r.videos > 0 {
                library.setAlbumHighlight(true, for: dest)         // show it as a bubble, like Instagram
                library.contentDidChange(); onFinished()
            } else if let contents = try? FileManager.default.contentsOfDirectory(atPath: dest.path), contents.isEmpty {
                try? FileManager.default.removeItem(at: dest)      // nothing came down — drop the empty folder
            }
            running = false; bg.end()
            result = r
        }
    }
}

/// Hosts a (shared) WKWebView so the user can see/drive the TikTok page.
private struct WebViewHolder: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

/// Owns a visible WKWebView and drives the auto-scroll harvest of `/video/` links.
@Observable
@MainActor
final class TikTokScraper {
    @ObservationIgnored let webView: WKWebView
    var status = ""

    init() {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()       // persistent cookies, shared with TikTokAuth
        webView = WKWebView(frame: .zero, configuration: cfg)
        webView.customUserAgent = TikTokService.userAgent
    }

    func load(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        webView.load(URLRequest(url: url))
    }

    /// Scrolls to the bottom repeatedly until the video count stops growing, then
    /// returns every unique `/video/` link on the page.
    func scanVideos(maxScrolls: Int = 120) async -> [String] {
        status = "Finding videos…"
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        var last = -1, stable = 0
        for _ in 0..<maxScrolls {
            _ = await eval("window.scrollTo(0, document.body.scrollHeight); 1")
            try? await Task.sleep(nanoseconds: 1_300_000_000)
            let count = (await eval("document.querySelectorAll('a[href*=\"/video/\"]').length")) as? Int ?? 0
            status = "Found \(count) videos…"
            if count <= last { stable += 1; if stable >= 4 { break } } else { stable = 0 }
            last = count
        }
        let res = (await eval("Array.from(document.querySelectorAll('a[href*=\"/video/\"]')).map(function(a){return a.href})")) as? [String] ?? []
        status = ""
        return Array(Set(res))
    }

    private func eval(_ js: String) async -> Any? {
        await withCheckedContinuation { cont in
            webView.evaluateJavaScript(js) { value, _ in cont.resume(returning: value) }
        }
    }
}
