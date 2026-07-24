import SwiftUI
import UIKit
import WebKit

/// "Download OF Profile" / "Get New OF Posts": logs in via a real
/// in-app web view (only the session cookies + device token are kept, never the
/// password), then pulls a creator's posts, messages, photos and videos — at the
/// highest quality OF keeps (source/original) — into a handle-named subfolder,
/// or, when the current folder already tracks a creator, just the new content.
/// Capture date and caption are written onto each item. Like the Instagram
/// downloader, the run happens as an app-wide background activity, so the user can
/// keep browsing the app (or leave it briefly) while it works. Best-effort, opt-in,
/// download-only; you can only download creators you subscribe to.
struct OFImportView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let targetFolder: URL
    let existing: OFFolderInfo?
    let onFinished: () -> Void

    @State private var username = ""
    @State private var includeMessages = true
    @State private var loggedIn = false
    @State private var showLogin = false

    private var isUpdate: Bool { existing != nil }

    var body: some View {
        NavigationStack {
            Form {
                if isUpdate {
                    Section {
                        Label("@\(existing?.username ?? "")", systemImage: "person.crop.circle")
                    } footer: {
                        Text("Fetches posts and messages you don’t already have into “\(targetFolder.lastPathComponent)”.")
                    }
                } else {
                    Section {
                        TextField("OF username (e.g. creator)", text: $username)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .keyboardType(.URL)
                    } header: {
                        Text("OF creator")
                    } footer: {
                        Text("Enter the username of a creator you subscribe to. Downloads into a new “username” folder inside “\(targetFolder.lastPathComponent)”. Nothing is uploaded.")
                    }
                }

                if !loggedIn {
                    Section {
                        Button { showLogin = true } label: {
                            Label("Log in to OF", systemImage: "person.badge.key")
                        }
                    } footer: {
                        Text("You log in inside the app; only the session cookies and device token are kept, on this device.")
                    }
                }

                Section {
                    Toggle("Include messages (DMs)", isOn: $includeMessages)
                } header: {
                    Text("Options")
                } footer: {
                    Text("The download runs in the background — you can keep using the app (or leave it briefly) and watch progress at the bottom of the screen. Everything is pulled in the highest quality available.")
                }
            }
            .navigationTitle(isUpdate ? "Get New OF Posts" : "Add from OF")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isUpdate ? "Get New" : "Download") { start() }
                        .disabled(!loggedIn || (!isUpdate && OFService.sanitizeUsername(username).isEmpty))
                }
            }
            .sheet(isPresented: $showLogin) {
                OFLoginView { Task { loggedIn = await OFAuth.isLoggedIn() } }
            }
            .task { loggedIn = await OFAuth.isLoggedIn() }
            .onAppear {
                if let existing { username = existing.username }
                else if username.isEmpty { username = library.lastOFUsername(for: targetFolder) ?? "" }
            }
        }
    }

    /// Kicks off the download as an **app-wide background activity** (progress pill,
    /// best-effort background window) and dismisses immediately — so, just like the
    /// Instagram downloader, the user can keep browsing the app or leave it briefly
    /// while the run continues. The whole flow runs off the closed sheet, driven off
    /// `Library`.
    private func start() {
        let h = isUpdate ? (existing?.username ?? "") : OFService.sanitizeUsername(username)
        guard !h.isEmpty else { return }
        let target = targetFolder, isUpd = isUpdate, msgs = includeMessages, ex = existing
        let finish = onFinished
        if !isUpd { library.setLastOFUsername(h, for: target) }
        let id = library.beginActivity(isUpd ? "OF @\(h) — new posts" : "Downloading OF @\(h)", indeterminate: true)
        library.setActivity(id, status: "Starting…")
        dismiss()        // let the user navigate; the download runs in the background
        let bg = BackgroundTaskHolder(); bg.begin(name: "OF Download")
        Task {
            guard let creds = await OFAuth.credentials() else {
                library.endActivity(id, result: "Couldn’t start — not logged in to OF."); bg.end(); return
            }
            let dest: URL
            if isUpd { dest = target }
            else {
                dest = target.appendingPathComponent(h, isDirectory: true)
                try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            }
            let prior = isUpd ? ex : library.ofInfo(for: dest)
            let already = Set(prior?.downloaded ?? [])

            let r = await OFService.run(username: h, into: dest, alreadyDownloaded: already,
                                              creds: creds, includeMessages: msgs) { p in
                Task { @MainActor in
                    library.setActivity(id, status: p.phase.isEmpty ? "Working…" : p.phase,
                                        fraction: p.total > 0 ? p.fraction : nil)
                }
            }
            library.setCaptions(r.captions)
            library.setPostedBy(r.postedBy)
            if let picData = r.profilePic, let img = UIImage(data: picData) { library.setCover(img, for: dest) }
            else if library.coverURL(for: dest) == nil, let cover = await firstItemThumbnail(in: dest) { library.setCover(cover, for: dest) }

            if let creator = r.creator {
                let info = OFFolderInfo(username: creator.username, userID: creator.id,
                                        name: creator.name.isEmpty ? creator.username : creator.name,
                                        lastUpdated: Date().timeIntervalSince1970,
                                        downloaded: Array(already.union(r.newIDs)),
                                        photos: (prior?.photos ?? 0) + r.photos,
                                        videos: (prior?.videos ?? 0) + r.videos)
                library.setOFInfo(info, for: dest)
            } else if !isUpd, let contents = try? FileManager.default.contentsOfDirectory(atPath: dest.path), contents.isEmpty {
                try? FileManager.default.removeItem(at: dest)   // creator never loaded — drop the empty folder
            }

            library.endActivity(id, result: summary(r, handle: h))
            if r.photos + r.videos > 0 { library.contentDidChange(); finish() }
            bg.end()
        }
    }

    /// Completion message shown as the activity-result popup.
    private func summary(_ r: OFService.DownloadResult, handle: String) -> String {
        let n = r.photos + r.videos
        guard n > 0 else { return r.note ?? "No new content for @\(handle)." }
        var s = "@\(handle): downloaded \(r.photos) photo\(r.photos == 1 ? "" : "s") and \(r.videos) video\(r.videos == 1 ? "" : "s")"
        if r.failed > 0 { s += "; \(r.failed) failed" }
        s += "."
        if let note = r.note, !note.isEmpty { s += " " + note }   // coverage diagnostic
        return s
    }

    private func firstItemThumbnail(in dir: URL) async -> UIImage? {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        guard let first = files.filter({ [.image, .video].contains(classify(url: $0, isDirectory: false)) })
            .sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }).first else { return nil }
        let entry = Entry(url: first, name: first.lastPathComponent, kind: classify(url: first, isDirectory: false), size: 0, modified: Date())
        return await Thumbnailer.shared.thumbnail(for: entry, size: CGSize(width: 200, height: 200), scale: 2)
    }
}

/// A real OF login in a `WKWebView` (persistent cookie + storage). When the
/// session cookies appear, the coordinator also captures the `x-bc` device token
/// from `localStorage` (OF keeps it there, not in a cookie) so the API can be
/// signed later; "Done" enables once both are in hand.
struct OFLoginView: View {
    @Environment(\.dismiss) private var dismiss
    let onDone: () -> Void
    @State private var loggedIn = false

    var body: some View {
        NavigationStack {
            OFWebView(loggedIn: $loggedIn)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Log in to OF")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { onDone(); dismiss() }.fontWeight(.semibold).disabled(!loggedIn)
                    }
                }
                .overlay(alignment: .bottom) {
                    if loggedIn {
                        Label("Logged in — tap Done", systemImage: "checkmark.circle.fill")
                            .font(.footnote).foregroundStyle(.green)
                            .padding(8).background(.ultraThinMaterial, in: Capsule()).padding(.bottom, 10)
                    }
                }
        }
    }
}

private struct OFWebView: UIViewRepresentable {
    @Binding var loggedIn: Bool

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()                 // persistent: the login survives relaunch
        let web = WKWebView(frame: .zero, configuration: cfg)
        web.navigationDelegate = context.coordinator
        web.customUserAgent = OFService.userAgent   // match the UA the API uses
        if let url = URL(string: "https://onlyfans.com/") { web.load(URLRequest(url: url)) }
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(loggedIn: $loggedIn) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        @Binding var loggedIn: Bool
        init(loggedIn: Binding<Bool>) { _loggedIn = loggedIn }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Grab the x-bc device token from localStorage while we're on the page
            // (OF keeps it under `bcTokenSha`; fall back to any hex-looking
            // token in case the key changes), then re-check the login state.
            let js = """
            (function(){try{var t=localStorage.getItem('bcTokenSha')||localStorage.getItem('bcTokenCache');if(t)return t;\
            for(var i=0;i<localStorage.length;i++){var k=localStorage.key(i);if(/bc/i.test(k)){\
            var v=localStorage.getItem(k);if(v&&/^[a-f0-9]{20,}$/i.test(v))return v;}}}catch(e){}return '';})()
            """
            webView.evaluateJavaScript(js) { value, _ in
                if let token = value as? String, !token.isEmpty {
                    Task { @MainActor in OFAuth.setStoredXBC(token) }
                }
                Task { @MainActor in self.loggedIn = await OFAuth.isLoggedIn() }
            }
        }
    }
}
