import SwiftUI
import UIKit
import WebKit

/// "Download Instagram Profile" / "Get New Instagram Posts": logs in via a real
/// in-app web view (we keep only the session cookie, never the password), then pulls
/// a profile's photos/videos into a handle-named subfolder — or, when the current
/// folder already tracks a profile, fetches just the new posts. Capture dates,
/// location, and captions are set from each post. Best-effort, opt-in, download-only.
struct InstagramImportView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let targetFolder: URL
    let existing: IGFolderInfo?
    var forceFull: Bool = false           // re-download the whole profile, replacing files
    let onFinished: () -> Void

    @State private var handle = ""
    @State private var loggedIn = false
    @State private var showLogin = false
    @State private var skipTagged = false
    @State private var upscale1080 = false

    private var isUpdate: Bool { existing != nil }

    var body: some View {
        NavigationStack {
            Form {
                if isUpdate {
                    Section {
                        Label("@\(existing?.handle ?? "")", systemImage: "person.crop.circle")
                    } footer: {
                        Text(forceFull
                             ? "Re-downloads the entire profile, replacing existing files (e.g. to re-pull at the latest quality)."
                             : "Fetches posts you don’t already have into “\(targetFolder.lastPathComponent)”.")
                    }
                } else {
                    Section {
                        TextField("instagram handle (e.g. nasa)", text: $handle)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .keyboardType(.URL)
                    } header: {
                        Text("Instagram profile")
                    } footer: {
                        Text("Downloads into a new “@handle” folder inside “\(targetFolder.lastPathComponent)”. Works for public profiles or ones you follow. Nothing is uploaded.")
                    }
                }

                if !loggedIn {
                    Section {
                        Button { showLogin = true } label: {
                            Label("Log in to Instagram", systemImage: "person.badge.key")
                        }
                    } footer: {
                        Text("You log in inside the app; only the session cookie is kept, on this device.")
                    }
                }

                Section {
                    Toggle("Skip tagged photos & videos", isOn: $skipTagged)
                    Toggle("Upscale videos to 1080p", isOn: $upscale1080)
                } header: {
                    Text("Options")
                } footer: {
                    Text("The download runs in the background — you can keep using the app and watch its progress at the bottom of the screen.")
                }
            }
            .navigationTitle(forceFull ? "Re-download Profile" : (isUpdate ? "Get New Posts" : "Add from Instagram"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(forceFull ? "Re-download" : (isUpdate ? "Get New" : "Download")) { start() }
                        .disabled(!loggedIn || (!isUpdate && sanitizedHandle.isEmpty))
                }
            }
            .sheet(isPresented: $showLogin) {
                InstagramLoginView { Task { loggedIn = await InstagramAuth.isLoggedIn() } }
            }
            .task { loggedIn = await InstagramAuth.isLoggedIn() }
            .onAppear {
                if let existing { handle = existing.handle }
                else if handle.isEmpty { handle = library.lastIGHandle(for: targetFolder) ?? "" }   // prefill last used
            }
        }
    }

    private var sanitizedHandle: String {
        var h = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = h.range(of: "instagram.com/") { h = String(h[r.upperBound...]) }
        h = String(h.split(separator: "/").first ?? "")
        h = String(h.split(separator: "?").first ?? "")
        return h.replacingOccurrences(of: "@", with: "")
    }

    private func start() {
        let h = isUpdate ? (existing?.handle ?? "") : sanitizedHandle
        guard !h.isEmpty else { return }
        let target = targetFolder, isUpd = isUpdate, force = forceFull, skipT = skipTagged, up = upscale1080, ex = existing
        let finish = onFinished
        if !isUpd { library.setLastIGHandle(h, for: target) }      // remember it for next time
        let id = library.beginActivity(forceFull ? "Re-downloading @\(h)" : (isUpd ? "@\(h) — new posts" : "Downloading @\(h)"),
                                       indeterminate: true)
        library.setActivity(id, status: "Starting…")
        dismiss()        // let the user navigate; the download runs in the background
        let bg = BackgroundTaskHolder(); bg.begin(name: "Instagram Download")
        Task {
            guard let creds = await InstagramAuth.credentials() else {
                library.endActivity(id, result: "Couldn’t start — not logged in to Instagram."); bg.end(); return
            }
            let dest: URL
            if isUpd { dest = target }
            else {
                dest = target.appendingPathComponent(h, isDirectory: true)
                try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            }
            let prior = isUpd ? ex : library.instagramInfo(for: dest)
            let already = force ? [] : Set(prior?.downloaded ?? [])

            let r = await InstagramService.run(handle: h, into: dest, alreadyDownloaded: already, creds: creds,
                                               replaceExisting: force, includeTagged: !skipT) { p in
                Task { @MainActor in
                    library.setActivity(id, status: p.total > 0 ? "Downloading \(p.done) of \(p.total)…" : p.phase,
                                        fraction: p.total > 0 ? p.fraction : nil)
                }
            }
            await InstagramApply.apply(r, to: dest, already: already, prior: prior, forceFull: force, library: library)
            if r.profile == nil, !isUpd,
               let contents = try? FileManager.default.contentsOfDirectory(atPath: dest.path), contents.isEmpty {
                try? FileManager.default.removeItem(at: dest)        // profile never loaded — drop the empty folder
            }
            if up {
                await InstagramApply.upscaleVideosTo1080(r.files) { d, t in library.setActivity(id, status: "Upscaling videos — \(d) of \(t)…") }
            }

            let n = r.photos + r.videos
            let msg: String
            if r.profile == nil { msg = "Couldn’t open @\(h) — check the handle and that you’re logged in." }
            else if n == 0 { msg = r.note ?? "No new posts for @\(h)." }
            else { msg = "@\(h): downloaded \(r.photos) photo\(r.photos == 1 ? "" : "s") and \(r.videos) video\(r.videos == 1 ? "" : "s")." }
            library.endActivity(id, result: msg)
            if n > 0 { library.contentDidChange(); finish() }
            bg.end()
        }
    }
}

/// A real Instagram login in a `WKWebView` (persistent cookie store). When the
/// session cookie appears, "Done" enables and the caller reads the cookie back.
struct InstagramLoginView: View {
    @Environment(\.dismiss) private var dismiss
    let onDone: () -> Void
    @State private var loggedIn = false

    var body: some View {
        NavigationStack {
            IGWebView(loggedIn: $loggedIn)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Log in to Instagram")
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

private struct IGWebView: UIViewRepresentable {
    @Binding var loggedIn: Bool

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()                 // persistent: the login survives relaunch
        let web = WKWebView(frame: .zero, configuration: cfg)
        web.navigationDelegate = context.coordinator
        web.customUserAgent = InstagramService.userAgent
        if let url = URL(string: "https://www.instagram.com/accounts/login/") {
            web.load(URLRequest(url: url))
        }
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(loggedIn: $loggedIn) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        @Binding var loggedIn: Bool
        init(loggedIn: Binding<Bool>) { _loggedIn = loggedIn }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in loggedIn = await InstagramAuth.isLoggedIn() }
        }
    }
}
