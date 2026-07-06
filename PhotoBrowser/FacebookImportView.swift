import SwiftUI
import UIKit
import WebKit

/// "Download Facebook Profile" / "Get New Facebook Photos": logs in via a real
/// in-app web view (only the session cookie is kept), then pulls a profile's
/// photos/videos — every album (uploads, profile pictures, cover photos), tagged
/// photos, and videos — into a folder shown as a blue-ringed highlight bubble.
/// Capture date, caption, and the poster's name are set where available, and
/// photos can run through the app's 2× AI Upscale as they land. Best-effort,
/// opt-in, download-only; Facebook fights scraping, so this is experimental.
struct FacebookImportView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let targetFolder: URL
    let existing: FBFolderInfo?
    let onFinished: () -> Void

    @State private var profileURL = ""
    @State private var upscale2x = true
    @State private var loggedIn = false
    @State private var showLogin = false

    private var isUpdate: Bool { existing != nil }

    var body: some View {
        NavigationStack {
            Form {
                if isUpdate {
                    Section { Label(existing?.profileName ?? "Facebook Profile", systemImage: "person.crop.circle") }
                    footer: { Text("Fetches photos/videos you don’t already have into “\(targetFolder.lastPathComponent)”.") }
                } else {
                    Section {
                        TextField("facebook profile or share link", text: $profileURL)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .keyboardType(.URL)
                    } header: { Text("Facebook profile") }
                    footer: { Text("Paste a profile or share link (e.g. facebook.com/share/…). Downloads into a new folder inside “\(targetFolder.lastPathComponent)”. Nothing is uploaded.") }
                }

                Section {
                    Toggle("2× AI Upscale photos", isOn: $upscale2x)
                } footer: {
                    Text("Every downloaded photo is enhanced with the app’s 2× AI Upscale — denoise, sharpen, and double the resolution. The download runs in the background — you can keep using the app (or leave it briefly) and watch progress at the bottom of the screen. Facebook actively limits scraping, so coverage is best-effort.")
                }

                if !loggedIn {
                    Section {
                        Button { showLogin = true } label: { Label("Log in to Facebook", systemImage: "person.badge.key") }
                    } footer: { Text("You log in inside the app; only the session cookie is kept, on this device.") }
                }
            }
            .navigationTitle(isUpdate ? "Get New Facebook Photos" : "Add from Facebook")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isUpdate ? "Get New" : "Download") { start() }
                        .disabled(!loggedIn || (!isUpdate && profileURL.trimmingCharacters(in: .whitespaces).isEmpty))
                }
            }
            .sheet(isPresented: $showLogin) {
                FacebookLoginView { Task { loggedIn = await FacebookAuth.isLoggedIn() } }
            }
            .task { loggedIn = await FacebookAuth.isLoggedIn() }
            .onAppear {
                if let existing { profileURL = existing.profileURL }
                else if profileURL.isEmpty { profileURL = library.lastFacebookURL(for: targetFolder) ?? "" }
            }
        }
    }

    /// Completion message shown as the activity-result popup (mirrors Instagram's).
    private func summary(_ r: FacebookService.DownloadResult) -> String {
        let n = r.photos + r.videos
        guard n > 0 else { return r.note ?? "Nothing downloaded." }
        var s = "Downloaded \(r.photos) photo\(r.photos == 1 ? "" : "s") and \(r.videos) video\(r.videos == 1 ? "" : "s")"
        if r.failed > 0 { s += "; \(r.failed) failed" }
        return s + "."
    }

    private func firstItemThumbnail(in dir: URL) async -> UIImage? {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        guard let first = files.filter({ [.image, .video].contains(classify(url: $0, isDirectory: false)) })
            .sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }).first else { return nil }
        let entry = Entry(url: first, name: first.lastPathComponent, kind: classify(url: first, isDirectory: false), size: 0, modified: Date())
        return await Thumbnailer.shared.thumbnail(for: entry, size: CGSize(width: 200, height: 200), scale: 2)
    }

    /// Kicks off the download as an **app-wide background activity** (progress pill,
    /// best-effort background window) and dismisses immediately — so, just like the
    /// Instagram downloader, the user can keep browsing the app or leave it briefly
    /// while the run continues. The whole flow (profile resolve, discovery, download,
    /// metadata) runs off the closed sheet, driven off `Library`.
    private func start() {
        let link = isUpdate ? (existing?.profileURL ?? "") : profileURL.trimmingCharacters(in: .whitespaces)
        guard !link.isEmpty else { return }
        let target = targetFolder, isUpd = isUpdate, upscale = upscale2x, ex = existing
        let finish = onFinished
        let id = library.beginActivity(isUpd ? "Facebook — new photos" : "Downloading Facebook profile", indeterminate: true)
        library.setActivity(id, status: "Starting…")
        dismiss()        // let the user navigate; the download runs in the background
        let bg = BackgroundTaskHolder(); bg.begin(name: "Facebook Download")
        Task {
            guard let creds = await FacebookAuth.credentials() else {
                library.endActivity(id, result: "Couldn’t start — not logged in to Facebook."); bg.end(); return
            }

            // First run resolves a folder name from the profile; updates reuse the folder.
            let prior = isUpd ? ex : nil
            let already = Set(prior?.downloaded ?? [])
            let dest: URL
            if isUpd { dest = target }
            else if let p = await FacebookService.resolveProfile(link, creds: creds) {
                let sub = target.appendingPathComponent(sanitize(p.name), isDirectory: true)
                try? FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
                dest = sub
                library.setLastFacebookURL(link, for: target)
            } else {
                library.endActivity(id, result: "Couldn’t open that profile. Check the link and that you’re logged in.")
                bg.end(); return
            }

            let r = await FacebookService.run(profileURL: link, into: dest, alreadyDownloaded: already,
                                              creds: creds, upscalePhotos: upscale) { p in
                Task { @MainActor in
                    library.setActivity(id, status: p.phase.isEmpty ? "Working…" : p.phase,
                                        fraction: p.total > 0 ? p.fraction : nil)
                }
            }
            library.setCaptions(r.captions)
            library.setPostedBy(r.postedBy)
            if let picData = r.profilePic, let img = UIImage(data: picData) { library.setCover(img, for: dest) }
            else if library.coverURL(for: dest) == nil, let cover = await firstItemThumbnail(in: dest) { library.setCover(cover, for: dest) }

            if let profile = r.profile {
                let info = FBFolderInfo(profileName: profile.name, profileID: profile.id, profileURL: profile.url,
                                        lastUpdated: Date().timeIntervalSince1970,
                                        downloaded: Array(already.union(r.newIDs)),
                                        photos: (prior?.photos ?? 0) + r.photos,
                                        videos: (prior?.videos ?? 0) + r.videos)
                library.setFacebookInfo(info, for: dest)
            } else if !isUpd, let contents = try? FileManager.default.contentsOfDirectory(atPath: dest.path), contents.isEmpty {
                try? FileManager.default.removeItem(at: dest)
            }

            library.endActivity(id, result: summary(r))
            if r.photos + r.videos > 0 { library.contentDidChange(); finish() }
            bg.end()
        }
    }

    private func sanitize(_ name: String) -> String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Facebook Profile" : String(cleaned.prefix(80))
    }
}

/// A real Facebook login in a `WKWebView` (persistent cookie store).
struct FacebookLoginView: View {
    @Environment(\.dismiss) private var dismiss
    let onDone: () -> Void
    @State private var loggedIn = false

    var body: some View {
        NavigationStack {
            FBWebView(loggedIn: $loggedIn)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Log in to Facebook")
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

private struct FBWebView: UIViewRepresentable {
    @Binding var loggedIn: Bool

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        let web = WKWebView(frame: .zero, configuration: cfg)
        web.navigationDelegate = context.coordinator
        // System (mobile) UA: the login page renders phone-sized, and the captured
        // cookies are UA-independent — the service then uses them with a desktop UA.
        if let url = URL(string: "https://m.facebook.com/login/") { web.load(URLRequest(url: url)) }
        return web
    }
    func updateUIView(_ web: WKWebView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(loggedIn: $loggedIn) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        @Binding var loggedIn: Bool
        init(loggedIn: Binding<Bool>) { _loggedIn = loggedIn }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in loggedIn = await FacebookAuth.isLoggedIn() }
        }
    }
}
