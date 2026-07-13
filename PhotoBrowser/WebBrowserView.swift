import SwiftUI
import WebKit
import UIKit
import Combine

/// An in-app web browser with **long-press-to-download**, like Aloha Browser's core feature.
/// Browse any site; when a video is playing, long-press it to save it into the current folder.
/// Beyond video it also downloads ordinary files: long-press a file link (`.zip`, `.pdf`, an
/// image, …) or just tap a site's download button — any response the web view can't render inline
/// (or that's marked `Content-Disposition: attachment`) is intercepted and offered as a download.
///
/// Detection mirrors how these downloaders work: an injected script (a) hooks `fetch`/`XHR` to
/// capture media URLs the page requests (direct files and `.m3u8` HLS playlists), and (b) reports
/// the `<video>` or `<a>` link under a long-press point. `WebVideoDownloader` then fetches +
/// assembles the file (carrying the browser's cookies + Referer + any Basic-Auth login). DRM
/// (Widevine/FairPlay) and pure-`blob:` MSE with no discoverable manifest can't be captured — the
/// same limits Aloha has.
struct WebBrowserView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let targetFolder: URL

    // Shared, app-lifetime controller so the WKWebView (and its back/forward history) survives
    // dismissing the browser and re-opening it — navigating to a folder and back doesn't reset the
    // session. `@ObservedObject` (not `@StateObject`): the view observes the singleton, it doesn't own it.
    @ObservedObject private var controller = WebController.shared
    @State private var address = ""
    @State private var editingAddress = false
    @State private var pending: WebController.FoundVideo?
    @State private var pendingFile: WebController.PendingFile?
    @State private var showDownloads = false
    @State private var showBookmarks = false

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
                    Button { controller.setVideoPlayback(!controller.videoPlaybackEnabled) } label: {
                        Image(systemName: controller.videoPlaybackEnabled ? "play.circle.fill" : "play.slash.fill")
                            .foregroundStyle(controller.videoPlaybackEnabled ? Color.green : Color.secondary)
                    }
                    .accessibilityLabel(controller.videoPlaybackEnabled ? "Video playback on — tap to disable"
                                                                        : "Video playback off — tap to watch")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if controller.hasVideo {
                        Image(systemName: "video.badge.checkmark").foregroundStyle(.green)
                            .accessibilityLabel("A downloadable video is playing")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showDownloads = true } label: {
                        Image(systemName: "arrow.down.circle")
                            .overlay(alignment: .topTrailing) {
                                if controller.activeDownloads > 0 {
                                    Text("\(controller.activeDownloads)")
                                        .font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                                        .padding(3).background(Circle().fill(.red)).offset(x: 6, y: -6)
                                } else if !controller.downloads.isEmpty {
                                    Circle().fill(.green).frame(width: 7, height: 7).offset(x: 4, y: -4)
                                }
                            }
                    }
                    .accessibilityLabel("Downloads")
                }
            }
        }
        .onAppear {
            controller.onVideoLongPress = { found in pending = found }
            controller.onFileDownload = { file in pendingFile = file }
            if controller.currentURLString.isEmpty {
                controller.load(WebController.lastSavedURL ?? "https://www.google.com")
            }
        }
        // Keep the controller + WKWebView alive across dismissals (that's what preserves the
        // session); just pause any playing media so audio doesn't continue in the background.
        .onDisappear { controller.pauseMedia() }
        .confirmationDialog("Download video?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            titleVisibility: .visible, presenting: pending) { v in
            Button("Download to “\(targetFolder.lastPathComponent)”") { startDownload(v) }
            Button("Copy Video Link") { UIPasteboard.general.string = v.url }
            Button("Cancel", role: .cancel) {}
        } message: { v in
            // Show the actual video URL that would be downloaded.
            Text((v.isHLS ? "Streaming video (segments will be merged):\n" : "") + v.url)
        }
        .confirmationDialog("Download file?", isPresented: Binding(get: { pendingFile != nil }, set: { if !$0 { pendingFile = nil } }),
                            titleVisibility: .visible, presenting: pendingFile) { f in
            Button("Download to “\(targetFolder.lastPathComponent)”") { startFileDownload(f) }
            Button("Copy Link") { UIPasteboard.general.string = f.url }
            Button("Cancel", role: .cancel) {}
        } message: { f in
            Text((f.filename.map { "\($0)\n" } ?? "") + f.url)
        }
        .sheet(isPresented: $showDownloads) { DownloadsSheet(controller: controller) }
        .sheet(isPresented: $showBookmarks) { BookmarksSheet(controller: controller) { controller.load($0) } }
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
            Button { controller.toggleBookmark() } label: {
                Image(systemName: controller.isCurrentBookmarked ? "star.fill" : "star")
                    .foregroundStyle(controller.isCurrentBookmarked ? Color.yellow : Color.secondary)
            }
            .disabled(!controller.hasSession)
            .accessibilityLabel(controller.isCurrentBookmarked ? "Remove bookmark" : "Add bookmark")
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
                 : controller.videoPlaybackEnabled ? "Long-press a video or file link to download • download buttons work too"
                                                    : "Long-press a video or file link to download • tap ▶ to watch video")
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
                    Button { controller.toggleBookmark() } label: {
                        Label(controller.isCurrentBookmarked ? "Remove Bookmark" : "Add Bookmark",
                              systemImage: controller.isCurrentBookmarked ? "star.slash" : "star")
                    }.disabled(!controller.hasSession)
                    Button { showBookmarks = true } label: { Label("Bookmarks", systemImage: "book") }
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
        showDownloads = true            // surface the Downloads tab so its real progress is visible
        controller.startDownload(v, into: folder, suggestedName: controller.pageTitle) { entry in
            if entry.state == .done {
                if let c = entry.caption, let dest = entry.dest { library.setCaption(c, for: dest) }
                library.contentDidChange(under: folder)
            }
        }
    }

    private func startFileDownload(_ f: WebController.PendingFile) {
        let folder = targetFolder
        showDownloads = true
        controller.startFileDownload(f, into: folder) { entry in
            if entry.state == .done {
                if let c = entry.caption, let dest = entry.dest { library.setCaption(c, for: dest) }
                library.contentDidChange(under: folder)
            }
        }
    }
}

/// Saved sites. Tap a row to open it (and dismiss); swipe to delete.
private struct BookmarksSheet: View {
    @ObservedObject var controller: WebController
    let onOpen: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if controller.bookmarks.isEmpty {
                    ContentUnavailableView("No Bookmarks", systemImage: "star",
                                           description: Text("Tap the ☆ in the address bar to save the current site."))
                } else {
                    List {
                        ForEach(controller.bookmarks) { b in
                            Button { onOpen(b.url); dismiss() } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(b.title.isEmpty ? b.url : b.title)
                                        .font(.callout.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                                    Text(b.url).font(.caption2).foregroundStyle(.secondary)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                            }
                        }
                        .onDelete { controller.removeBookmarks(at: $0) }
                    }
                }
            }
            .navigationTitle("Bookmarks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                if !controller.bookmarks.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) { EditButton() }
                }
            }
        }
    }
}

/// The Downloads tab: live rows with a real progress bar + % for each video the browser is saving.
private struct DownloadsSheet: View {
    @ObservedObject var controller: WebController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if controller.downloads.isEmpty {
                    ContentUnavailableView("No downloads yet", systemImage: "arrow.down.circle",
                                           description: Text("Long-press a video or file link — or tap a site's download button. Progress shows here."))
                } else {
                    List {
                        ForEach(controller.downloads) { d in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Image(systemName: icon(d.state)).foregroundStyle(color(d.state))
                                    Text(d.name).lineLimit(1).font(.callout.weight(.medium))
                                    Spacer()
                                    if d.state == .downloading { Text("\(Int(d.progress * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                                }
                                if d.state == .downloading {
                                    ProgressView(value: d.progress).tint(.accentColor)
                                    Text(d.phase).font(.caption2).foregroundStyle(.secondary)
                                } else if d.state == .failed {
                                    Text(d.message ?? "Download failed.").font(.caption2).foregroundStyle(.orange)
                                } else {
                                    Text("Saved").font(.caption2).foregroundStyle(.green)
                                }
                                Text(d.urlString).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
            .navigationTitle("Downloads")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    if controller.downloads.contains(where: { $0.state != .downloading }) {
                        Button("Clear") { controller.clearFinishedDownloads() }
                    }
                }
            }
        }
    }

    private func icon(_ s: WebController.DownloadEntry.State) -> String {
        switch s {
        case .downloading: return "arrow.down.circle"
        case .done: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }
    private func color(_ s: WebController.DownloadEntry.State) -> Color {
        switch s {
        case .downloading: return .accentColor
        case .done: return .green
        case .failed: return .orange
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
final class WebController: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, UIGestureRecognizerDelegate {
    struct FoundVideo: Identifiable { let id = UUID(); let url: String; let pageURL: String
        var isHLS: Bool { url.lowercased().contains(".m3u8") }
    }

    /// A non-streaming file the browser offers to save — either a link the user long-pressed or a
    /// response the web view can't render inline (a `Content-Disposition: attachment`).
    struct PendingFile: Identifiable { let id = UUID(); let url: String; let pageURL: String; let filename: String? }

    /// One row in the Downloads tab.
    struct DownloadEntry: Identifiable {
        enum State { case downloading, done, failed }
        let id = UUID()
        var name: String
        var urlString: String
        var progress: Double = 0
        var phase: String = "Starting…"
        var state: State = .downloading
        var dest: URL?
        var message: String?
        var caption: String?          // page-provided caption to apply to the saved file
    }

    @Published var currentURLString = ""
    @Published var pageTitle = ""
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var progress: Double = 0
    @Published var isLoading = false
    @Published var hasVideo = false
    @Published var downloads: [DownloadEntry] = []
    /// Whether videos are allowed to play. Off by default so a page's video can't autoplay/expand
    /// and get in the way of long-pressing things to download; the toolbar toggle turns it on.
    @Published var videoPlaybackEnabled = false

    var activeDownloads: Int { downloads.filter { $0.state == .downloading }.count }

    var onVideoLongPress: ((FoundVideo) -> Void)?
    /// Fired when a downloadable file is discovered (long-pressed link or an attachment response).
    var onFileDownload: ((PendingFile) -> Void)?

    /// App-lifetime instance so the WKWebView and its navigation history persist across the browser
    /// being dismissed and re-opened (folder → back to browser keeps your back button working).
    static let shared = WebController()

    /// True once the browser has loaded a real page this session — drives the folder view's quick
    /// "Back to Browser" button so you can jump back in without the "…" menu.
    var hasSession: Bool { currentURLString.hasPrefix("http") }

    /// Reused + pre-warmed so the long-press haptic doesn't cold-start the Taptic Engine (a hitch).
    private let haptic = UINotificationFeedbackGenerator()

    /// The last page visited, so re-opening the browser resumes where you left off.
    static var lastSavedURL: String? {
        get { UserDefaults.standard.string(forKey: "photoBrowser.webBrowserLastURL") }
        set { UserDefaults.standard.set(newValue, forKey: "photoBrowser.webBrowserLastURL") }
    }

    // MARK: - Bookmarks (saved/favorited sites, persisted across launches)

    struct Bookmark: Identifiable, Codable, Equatable { var id = UUID(); var title: String; var url: String }

    @Published var bookmarks: [Bookmark] = WebController.loadBookmarks()

    private static let bookmarksKey = "photoBrowser.webBookmarks"
    private static func loadBookmarks() -> [Bookmark] {
        guard let data = UserDefaults.standard.data(forKey: bookmarksKey),
              let list = try? JSONDecoder().decode([Bookmark].self, from: data) else { return [] }
        return list
    }
    private func saveBookmarks() {
        if let data = try? JSONEncoder().encode(bookmarks) { UserDefaults.standard.set(data, forKey: Self.bookmarksKey) }
    }

    /// Whether the current page is already bookmarked (drives the ☆/★ toggle).
    var isCurrentBookmarked: Bool { bookmarks.contains { $0.url == currentURLString } }

    /// Bookmark (or un-bookmark) the current page.
    func toggleBookmark() {
        let u = currentURLString
        guard u.hasPrefix("http") else { return }
        if let i = bookmarks.firstIndex(where: { $0.url == u }) {
            bookmarks.remove(at: i)
        } else {
            bookmarks.insert(Bookmark(title: pageTitle.isEmpty ? u : pageTitle, url: u), at: 0)
        }
        saveBookmarks()
    }

    func removeBookmarks(at offsets: IndexSet) {
        bookmarks.remove(atOffsets: offsets)
        saveBookmarks()
    }

    /// Media URLs the page has requested (direct files + `.m3u8`), newest last.
    private var captured: [String] = []
    /// The `<video>` element's own current source (may be a `blob:` for MSE).
    private var playingSrc: String?
    /// HTTP Basic-Auth credentials the user entered, keyed by host — reused so a download of a
    /// members-only (`.htpasswd`-protected) video carries the same login the page used.
    private var basicCreds: [String: (user: String, pass: String)] = [:]

    override init() { super.init() }

    /// The `Authorization: Basic …` header for a media host, if the user has signed in there.
    /// First checks credentials captured from our own Sign-In prompt, then falls back to the shared
    /// `URLCredentialStorage` — WKWebView can satisfy a Basic-Auth challenge silently (from a prior
    /// login) without ever calling our prompt, which is why a members video could still 401.
    func authHeader(forURLString urlString: String) -> String? {
        guard let host = URL(string: urlString)?.host else { return nil }
        func basic(_ user: String, _ pass: String) -> String? {
            ("\(user):\(pass)".data(using: .utf8)).map { "Basic " + $0.base64EncodedString() }
        }
        if let c = basicCreds[host] { return basic(c.user, c.pass) }
        for (space, creds) in URLCredentialStorage.shared.allCredentials where space.host == host {
            let m = space.authenticationMethod
            guard m == NSURLAuthenticationMethodHTTPBasic || m == NSURLAuthenticationMethodDefault else { continue }
            if let cred = creds.values.first(where: { $0.user != nil && $0.password != nil }),
               let u = cred.user, let p = cred.password { return basic(u, p) }
        }
        return nil
    }

    /// Ask for a username/password for `host` (used when a download hits 401 and we have no stored
    /// login — WKWebView can be silently authenticated from a prior session so our page prompt never
    /// fired). Stores what's entered in `basicCreds` and reports whether a username was given.
    private func promptSignIn(host: String) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let alert = UIAlertController(title: "Sign In to Download",
                                          message: "“\(host)” needs a username and password to download this.",
                                          preferredStyle: .alert)
            alert.addTextField { $0.placeholder = "Username"; $0.autocapitalizationType = .none; $0.autocorrectionType = .no; $0.keyboardType = .emailAddress }
            alert.addTextField { $0.placeholder = "Password"; $0.isSecureTextEntry = true }
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in cont.resume(returning: false) })
            alert.addAction(UIAlertAction(title: "Sign In", style: .default) { [weak self] _ in
                let u = alert.textFields?[0].text ?? "", p = alert.textFields?[1].text ?? ""
                if !u.isEmpty { self?.basicCreds[host] = (u, p) }
                cont.resume(returning: !u.isEmpty)
            })
            present(alert)
        }
    }

    /// The date + caption a site prints in the page HTML — hotwiferio uses
    /// `<div class="cell update_date"> 06/30/2003 </div>` for the date and
    /// `<span class="update_description">…</span>` for the caption. Both are used to fill in metadata
    /// the downloaded file lacks. Either may be nil.
    struct PageMedia: Sendable { var date: Date?; var caption: String? }

    func pageMediaInfo() async -> PageMedia {
        let js = """
        (function(){
          function t(sel){ var el=document.querySelector(sel); return el ? (el.textContent||'').trim() : ''; }
          return JSON.stringify({ date: t('.update_date') || t('[class*="update_date"]'),
                                  caption: t('.update_description') || t('[class*="update_description"]') });
        })()
        """
        let json: String = await withCheckedContinuation { cont in
            webView.evaluateJavaScript(js) { result, _ in cont.resume(returning: (result as? String) ?? "") }
        }
        var info = PageMedia()
        if let d = json.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            if let ds = obj["date"] as? String, !ds.isEmpty { info.date = Self.parseCaptureDate(ds) }
            if let cs = obj["caption"] as? String {
                let trimmed = cs.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { info.caption = String(trimmed.prefix(2000)) }
            }
        }
        return info
    }

    /// Pull a date out of page text ("06/30/2003", "2003-06-30", possibly with a label around it) and
    /// anchor it at local noon so the calendar day is stable regardless of time zone.
    static func parseCaptureDate(_ raw: String) -> Date? {
        func firstMatch(_ pattern: String) -> String? {
            guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
            let ns = raw as NSString
            guard let m = re.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)) else { return nil }
            return ns.substring(with: m.range)
        }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = .current
        var found: Date?
        if let s = firstMatch("\\d{1,2}/\\d{1,2}/\\d{4}") {
            for fmt in ["MM/dd/yyyy", "M/d/yyyy"] { f.dateFormat = fmt; if let d = f.date(from: s) { found = d; break } }
        }
        if found == nil, let s = firstMatch("\\d{4}-\\d{1,2}-\\d{1,2}") {
            f.dateFormat = "yyyy-MM-dd"; found = f.date(from: s)
        }
        guard let d = found else { return nil }
        // Sanity window: 1970 … tomorrow — ignore garbage like a "00/00/0000".
        guard d > Date(timeIntervalSince1970: 0), d < Date().addingTimeInterval(86_400) else { return nil }
        return Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: d) ?? d
    }

    lazy var webView: WKWebView = {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = .all   // no autoplay; the injected script also
                                                              // blocks playback until the user opts in
        cfg.websiteDataStore = .default()                     // persistent cookies (logins / hotlink gates)
        let ucc = WKUserContentController()
        ucc.add(WeakScriptHandler(self), name: "pb")          // weak: avoid the config→handler→config retain cycle
        ucc.addUserScript(WKUserScript(source: Self.detectorJS, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        cfg.userContentController = ucc
        let web = WKWebView(frame: .zero, configuration: cfg)
        web.navigationDelegate = self
        web.uiDelegate = self
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

    /// Pause any playing audio/video without tearing anything down — called when the browser view
    /// disappears so media doesn't keep playing while the web view is kept alive for the session.
    func pauseMedia() {
        webView.evaluateJavaScript("document.querySelectorAll('video,audio').forEach(function(m){try{m.pause()}catch(e){}})") { _, _ in }
    }

    /// Turn video playback on/off. When off, the injected script pauses any playing video and
    /// rejects `play()`, so nothing expands over the page while you're trying to download.
    func setVideoPlayback(_ on: Bool) {
        videoPlaybackEnabled = on
        webView.evaluateJavaScript("window.__pbSetPlayback && window.__pbSetPlayback(\(on))") { _, _ in }
    }

    /// The best downloadable URL currently known (video src or captured media).
    func bestVideo() -> FoundVideo? {
        guard let url = Self.pickBest(src: playingSrc, media: captured) else { return nil }
        return FoundVideo(url: url, pageURL: currentURLString)
    }

    // MARK: Downloads

    /// Starts a download, tracking it in `downloads` with real progress; `onComplete` fires on the
    /// main actor when it finishes (so the view can refresh the folder).
    func startDownload(_ v: FoundVideo, into folder: URL, suggestedName: String?,
                       onComplete: @escaping (DownloadEntry) -> Void) {
        let name = (suggestedName.flatMap { $0.isEmpty ? nil : $0 }) ?? URL(string: v.url)?.lastPathComponent ?? "video"
        let entry = DownloadEntry(name: name, urlString: v.url)
        downloads.insert(entry, at: 0)
        let id = entry.id
        let urlString = v.url, pageURL = v.pageURL, sName = suggestedName
        Task {
            let cookie = await cookieHeader(forURLString: urlString)
            let info = await self.pageMediaInfo()         // read while the page is still loaded
            self.update(id) { $0.caption = info.caption }
            func run() async -> WebVideoDownloader.Outcome {
                await WebVideoDownloader.download(
                    urlString: urlString, pageURL: pageURL, cookieHeader: cookie, into: folder,
                    suggestedName: sName, authHeader: self.authHeader(forURLString: urlString),
                    captureDate: info.date, caption: info.caption) { p in
                        Task { @MainActor in self.update(id) { $0.progress = p.fraction; $0.phase = p.phase } }
                    }
            }
            var outcome = await run()
            if case .authRequired(let host) = outcome, await self.promptSignIn(host: host) {
                self.update(id) { $0.phase = "Signing in…" }
                outcome = await run()
            }
            self.finish(id, outcome)
            if let done = self.downloads.first(where: { $0.id == id }) { onComplete(done) }
        }
    }

    /// Map a download outcome onto its Downloads-tab row.
    private func finish(_ id: UUID, _ outcome: WebVideoDownloader.Outcome) {
        update(id) { e in
            switch outcome {
            case .saved(let u): e.state = .done; e.progress = 1; e.dest = u; e.phase = "Saved"
            case .failed(let m): e.state = .failed; e.message = m; e.phase = "Failed"
            case .authRequired: e.state = .failed; e.message = "This download needs a members login."; e.phase = "Failed"
            }
        }
    }

    /// Starts a plain file download (zip, pdf, image, …), tracked in `downloads` like a video.
    func startFileDownload(_ f: PendingFile, into folder: URL, onComplete: @escaping (DownloadEntry) -> Void) {
        let name = (f.filename.flatMap { $0.isEmpty ? nil : $0 }) ?? URL(string: f.url)?.lastPathComponent ?? "file"
        let entry = DownloadEntry(name: name, urlString: f.url)
        downloads.insert(entry, at: 0)
        let id = entry.id
        let urlString = f.url, pageURL = f.pageURL, fname = f.filename
        Task {
            let cookie = await cookieHeader(forURLString: urlString)
            let info = await self.pageMediaInfo()         // read while the page is still loaded
            self.update(id) { $0.caption = info.caption }
            func run() async -> WebVideoDownloader.Outcome {
                await WebVideoDownloader.downloadFile(
                    urlString: urlString, pageURL: pageURL, cookieHeader: cookie,
                    authHeader: self.authHeader(forURLString: urlString), into: folder, suggestedName: fname,
                    captureDate: info.date, caption: info.caption) { p in
                        Task { @MainActor in self.update(id) { $0.progress = p.fraction; $0.phase = p.phase } }
                    }
            }
            var outcome = await run()
            if case .authRequired(let host) = outcome, await self.promptSignIn(host: host) {
                self.update(id) { $0.phase = "Signing in…" }
                outcome = await run()
            }
            self.finish(id, outcome)
            if let done = self.downloads.first(where: { $0.id == id }) { onComplete(done) }
        }
    }

    func clearFinishedDownloads() { downloads.removeAll { $0.state != .downloading } }

    private func update(_ id: UUID, _ mutate: (inout DownloadEntry) -> Void) {
        if let i = downloads.firstIndex(where: { $0.id == id }) { mutate(&downloads[i]) }
    }

    // MARK: KVO → published state

    nonisolated override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                                           change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        // WebKit posts KVO on the main thread; assert that so we can touch MainActor state.
        MainActor.assumeIsolated {
            switch keyPath {
            case "estimatedProgress": progress = webView.estimatedProgress
            case "title": pageTitle = webView.title ?? ""
            case "URL":
                currentURLString = webView.url?.absoluteString ?? currentURLString
                if let u = webView.url?.absoluteString, u.hasPrefix("http") { Self.lastSavedURL = u }
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

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // The detector re-injects with playback off at document start; re-assert the user's choice.
        setVideoPlayback(videoPlaybackEnabled)
    }

    /// Catch file downloads: when a response can't be rendered inline (a `.zip`, an installer, …) or
    /// is explicitly `Content-Disposition: attachment`, cancel the navigation and offer to save it.
    /// This is the "tap a Download button → a save prompt appears" path.
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let resp = navigationResponse.response
        let disposition = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")?.lowercased()
        let isAttachment = disposition?.contains("attachment") ?? false
        if (navigationResponse.canShowMIMEType == false || isAttachment),
           let url = resp.url?.absoluteString, url.hasPrefix("http") {
            decisionHandler(.cancel)
            let file = PendingFile(url: url, pageURL: currentURLString, filename: resp.suggestedFilename)
            onFileDownload?(file)
            return
        }
        decisionHandler(.allow)
    }

    /// HTTP Basic/Digest/NTLM auth — present the classic username/password prompt.
    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let method = challenge.protectionSpace.authenticationMethod
        guard method == NSURLAuthenticationMethodHTTPBasic
                || method == NSURLAuthenticationMethodHTTPDigest
                || method == NSURLAuthenticationMethodNTLM else {
            completionHandler(.performDefaultHandling, nil); return
        }
        let host = challenge.protectionSpace.host
        let alert = UIAlertController(title: "Sign In", message: "“\(host)” requires a username and password.", preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "Username"; $0.autocapitalizationType = .none; $0.autocorrectionType = .no; $0.keyboardType = .emailAddress }
        alert.addTextField { $0.placeholder = "Password"; $0.isSecureTextEntry = true }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(.cancelAuthenticationChallenge, nil) })
        alert.addAction(UIAlertAction(title: "Sign In", style: .default) { [weak self] _ in
            let u = alert.textFields?[0].text ?? "", p = alert.textFields?[1].text ?? ""
            // Remember the credential so the separate download URLSession (which does not
            // share WKWebView's protection space) can send it as an Authorization header.
            self?.basicCreds[host] = (u, p)
            completionHandler(.useCredential, URLCredential(user: u, password: p, persistence: .forSession))
        })
        present(alert)
    }

    // MARK: WKUIDelegate — popups (target=_blank), and JS alert/confirm/prompt login dialogs

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Open “_blank”/popup links in this same web view instead of dropping them.
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
            webView.load(URLRequest(url: url))
        }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        present(a)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        present(a)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let a = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
        a.addTextField { $0.text = defaultText }
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(nil) })
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(a.textFields?.first?.text) })
        present(a)
    }

    /// Present a UIKit alert over the browser (topmost view controller in the web view's window).
    private func present(_ alert: UIAlertController) {
        var vc = webView.window?.rootViewController
        while let p = vc?.presentedViewController { vc = p }
        vc?.present(alert, animated: true)
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
        haptic.prepare()                     // warm the engine while the JS hit-test round-trips
        let p = g.location(in: webView)
        let js = "window.__pbHitAt ? window.__pbHitAt(\(Int(p.x)),\(Int(p.y))) : null"
        webView.evaluateJavaScript(js) { [weak self] result, _ in
          MainActor.assumeIsolated {
            guard let self else { return }
            var src: String?
            var media: [String] = self.captured
            var linkHref: String?
            var linkForced = false          // <a download> — an explicit download link
            var linkName: String?
            if let json = result as? String, let data = json.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let vid = obj["video"] as? [String: Any] {
                    src = vid["src"] as? String
                    if let m = vid["media"] as? [String] { media = self.captured + m }
                }
                if let link = obj["link"] as? [String: Any] {
                    linkHref = link["href"] as? String
                    linkForced = (link["download"] as? Bool) ?? false
                    let n = (link["name"] as? String) ?? ""
                    linkName = n.isEmpty ? nil : n
                }
            }
            // A video under the finger (or the page's known video) takes priority.
            let effectiveSrc = src ?? self.playingSrc
            if let best = Self.pickBest(src: effectiveSrc, media: media) {
                self.haptic.notificationOccurred(.success)
                self.onVideoLongPress?(FoundVideo(url: best, pageURL: self.currentURLString))
                return
            }
            // Otherwise, offer to download a file the long-pressed link points to.
            if let href = linkHref, href.hasPrefix("http"), linkForced || Self.looksDownloadable(href) {
                self.haptic.notificationOccurred(.success)
                self.onFileDownload?(PendingFile(url: href, pageURL: self.currentURLString, filename: linkName))
            }
          }
        }
    }

    /// True when a link's path ends in a file extension that isn't an ordinary web page — i.e. it's
    /// worth offering to download (`.zip`, `.pdf`, `.jpg`, `.apk`, …) rather than navigate to.
    static func looksDownloadable(_ urlString: String) -> Bool {
        guard let ext = URL(string: urlString)?.pathExtension.lowercased(), !ext.isEmpty else { return false }
        let pages: Set<String> = ["html", "htm", "php", "asp", "aspx", "jsp", "cgi", "do", "action"]
        return !pages.contains(ext)
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
      // Playback gate: off by default so videos can't autoplay/expand while you're downloading.
      if (window.__pbAllowPlay === undefined) window.__pbAllowPlay = false;
      try {
        var proto = HTMLMediaElement.prototype;
        if (!proto.__pbPatched) {
          proto.__pbPatched = true;
          var origPlay = proto.play;
          proto.play = function(){
            if (!window.__pbAllowPlay && this.tagName === 'VIDEO'){
              try{ this.pause(); }catch(e){}
              return Promise.reject(new DOMException('Playback disabled','AbortError'));
            }
            return origPlay.apply(this, arguments);
          };
        }
      } catch(e){}
      document.addEventListener('play', function(e){
        var v=e.target; if(v && v.tagName==='VIDEO' && !window.__pbAllowPlay){ try{ v.pause(); }catch(e){} }
      }, true);
      window.__pbSetPlayback = function(on){
        window.__pbAllowPlay = !!on;
        if(!on){ var vids=document.querySelectorAll('video'); for(var i=0;i<vids.length;i++){ try{ vids[i].pause(); }catch(e){} } }
      };
      function videoAt(x,y){
        var el = document.elementFromPoint(x,y), v=null, n=el;
        while(n){ if(n.tagName==='VIDEO'){ v=n; break; } n=n.parentElement; }
        if(!v){ var vids=document.querySelectorAll('video'); if(vids.length===1) v=vids[0]; else {
          for(var i=0;i<vids.length;i++){ if(!vids[i].paused){ v=vids[i]; break; } } } }
        if(!v) return null;
        var srcs=[]; if(v.currentSrc) srcs.push(v.currentSrc); if(v.src) srcs.push(v.src);
        var ss=v.querySelectorAll('source'); for(var j=0;j<ss.length;j++){ if(ss[j].src) srcs.push(ss[j].src); }
        return { src: v.currentSrc||v.src||'', media: srcs };
      }
      function linkAt(x,y){
        var el = document.elementFromPoint(x,y), a=null, n=el;
        while(n){ if(n.tagName==='A' && n.href){ a=n; break; } n=n.parentElement; }
        if(!a) return null;
        return { href: a.href, download: a.hasAttribute('download'), name: a.getAttribute('download')||'' };
      }
      window.__pbVideoAt = function(x,y){ var v=videoAt(x,y); return v ? JSON.stringify(v) : null; };
      // Combined hit-test for long-press: a video and/or an anchor link under the finger.
      window.__pbHitAt = function(x,y){ return JSON.stringify({ video: videoAt(x,y), link: linkAt(x,y) }); };
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
