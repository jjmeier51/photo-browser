import SwiftUI
import UIKit
import WebKit
import Observation

/// "Download TikTok Profile": opens the profile in a real in-app web view (so
/// TikTok's lazy-loaded video grid actually populates and any login/captcha can be
/// handled), auto-scrolls to harvest *every* video link, then downloads each video
/// (highest quality, HDR preserved, post date + caption set) into an "@handle" folder
/// nested in the current folder and shown as a pinned highlight bubble — like the
/// Instagram one. Reposts are skipped, and the profile is remembered per folder so a
/// re-run only pulls new videos. Best-effort: TikTok actively blocks scraping.
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
                        .onSubmit { open() }
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
                Text(opened ? "Log in if prompted, then tap Download All. It scrolls the whole profile to find every video."
                            : "Enter a handle and tap Open. You can log in in the page below if TikTok asks.")
                    .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .padding(8).frame(maxWidth: .infinity).background(.bar)
            }
            .onAppear {
                // Resume the same profile this folder was last downloaded with.
                if handle.isEmpty, let last = library.lastTikTokHandle(for: targetFolder) {
                    handle = last
                    open()
                }
            }
            // Keep the screen awake while the (potentially long) scrape + download runs.
            .onChange(of: running) { _, isRunning in UIApplication.shared.isIdleTimerDisabled = isRunning }
            .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
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
            // The TikTok folder lives *inside* the current (person) folder as "@handle", so the
            // person folder stays a regular folder and only the "@handle" folder is a bubble.
            let dest = targetFolder.appendingPathComponent("@\(user)", isDirectory: true)
            let prior = library.tiktokInfo(for: dest)
            let already = Set(prior?.downloaded ?? [])

            let urls = await scraper.scanVideos()
            let cookie = await TikTokAuth.cookieHeader()
            try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

            let r = await TikTokService.run(username: user, videoURLs: urls, into: dest,
                                            cookie: cookie, alreadyDownloaded: already) { p in
                Task { @MainActor in progress = p }
            }
            library.setCaptions(r.captions)
            if let avatar = r.avatar, let img = UIImage(data: avatar) {
                library.setCover(img, for: dest)                              // bubble shows the avatar
                if library.coverURL(for: targetFolder) == nil,               // person folder gets it too if bare
                   library.instagramInfo(for: targetFolder) == nil, !library.isTikTokFolder(targetFolder) {
                    library.setCover(img, for: targetFolder)
                }
            }

            let resolvedProfile = !r.secUid.isEmpty || prior != nil
            if r.videos > 0 || resolvedProfile {
                // Register / update the profile record: pinned bubble + remembered for "Get New".
                let info = TTFolderInfo(handle: user,
                                        secUid: r.secUid.isEmpty ? (prior?.secUid ?? "") : r.secUid,
                                        lastUpdated: Date().timeIntervalSince1970,
                                        downloaded: Array(already.union(r.downloadedIDs)),
                                        videos: (prior?.videos ?? 0) + r.videos)
                library.setTikTokInfo(info, for: dest)
                library.setLastTikTokHandle(user, for: targetFolder)
            } else if let contents = try? FileManager.default.contentsOfDirectory(atPath: dest.path), contents.isEmpty {
                try? FileManager.default.removeItem(at: dest)                 // nothing came down — drop the empty folder
            }
            if r.videos > 0 { library.contentDidChange(); onFinished() }

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
/// TikTok virtualizes its grid (it drops off-screen tiles from the DOM), so a single
/// `querySelectorAll` at the end only sees the last screenful — the cause of "only the
/// last ~12 videos". We instead install a `Set` accumulator plus a `MutationObserver`
/// that captures every `/video/` link the moment it appears, then scroll the whole page
/// so all tiles render at least once. That harvests the entire profile.
@Observable
@MainActor
final class TikTokScraper: NSObject, WKNavigationDelegate {
    @ObservationIgnored let webView: WKWebView
    var status = ""

    override init() {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()       // persistent cookies, shared with TikTokAuth
        cfg.allowsInlineMediaPlayback = true
        webView = WKWebView(frame: .zero, configuration: cfg)
        super.init()
        webView.customUserAgent = TikTokService.userAgent
        webView.navigationDelegate = self
    }

    func load(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        status = "Loading profile…"
        webView.load(URLRequest(url: url))
    }

    // Surface page load state so a blank/blocked page isn't a silent mystery.
    nonisolated func webView(_ wv: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in status = "" }
    }
    nonisolated func webView(_ wv: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in status = "Couldn’t load the page — check the handle / your connection." }
    }
    nonisolated func webView(_ wv: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in status = "Couldn’t load the page — check the handle / your connection." }
    }

    /// Scrolls the whole profile, accumulating every `/video/` link as it renders, until the
    /// count stops growing at the bottom. Returns all unique links seen.
    func scanVideos(maxScrolls: Int = 300) async -> [String] {
        status = "Finding videos…"
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        // Install the accumulator + observer (idempotent; survives until the next navigation).
        _ = await eval("""
        (function(){
          if(!window.__ttSet){window.__ttSet=new Set();}
          window.__ttCollect=function(){var ls=document.querySelectorAll('a[href*="/video/"]');for(var i=0;i<ls.length;i++){window.__ttSet.add(ls[i].href);}return window.__ttSet.size;};
          if(!window.__ttObs){window.__ttObs=new MutationObserver(window.__ttCollect);window.__ttObs.observe(document.documentElement,{childList:true,subtree:true});}
          return window.__ttCollect();
        })();
        """)
        var last = -1, stable = 0
        for _ in 0..<maxScrolls {
            _ = await eval("window.scrollBy(0, Math.round(window.innerHeight*0.85)); 1")
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            let count = (await eval("window.__ttCollect()")) as? Int ?? 0
            let atBottom = (await eval("(window.innerHeight + window.scrollY) >= (document.body.scrollHeight - 100)")) as? Bool ?? false
            status = "Found \(count) videos…"
            if count <= last { stable += 1 } else { stable = 0 }
            if atBottom && stable >= 3 { break }     // settled at the end
            if stable >= 8 { break }                 // safety: no growth for a while
            last = count
        }
        let res = (await eval("Array.from(window.__ttSet)")) as? [String] ?? []
        status = ""
        return Array(Set(res))
    }

    private func eval(_ js: String) async -> Any? {
        await withCheckedContinuation { cont in
            webView.evaluateJavaScript(js) { value, _ in cont.resume(returning: value) }
        }
    }
}
