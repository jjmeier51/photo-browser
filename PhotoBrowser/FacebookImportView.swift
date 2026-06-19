import SwiftUI
import UIKit
import WebKit

/// "Download Facebook Profile" / "Get New Facebook Photos": logs in via a real
/// in-app web view (only the session cookie is kept), then pulls a profile's
/// photos/videos — uploaded, profile pictures, and tagged — into a folder shown as
/// a blue-ringed highlight bubble. Capture date, location, caption, and the
/// poster's name are set where available. Best-effort, opt-in, download-only;
/// Facebook fights scraping, so this is experimental.
struct FacebookImportView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let targetFolder: URL
    let existing: FBFolderInfo?
    let onFinished: () -> Void

    @State private var profileURL = ""
    @State private var running = false
    @State private var loggedIn = false
    @State private var showLogin = false
    @State private var progress = FacebookService.Progress(phase: "", fraction: 0, done: 0, total: 0)
    @State private var result: FacebookService.DownloadResult?

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
                            .keyboardType(.URL).disabled(running)
                    } header: { Text("Facebook profile") }
                    footer: { Text("Paste a profile or share link (e.g. facebook.com/share/…). Downloads into a new folder inside “\(targetFolder.lastPathComponent)”. Nothing is uploaded.") }
                }

                if !loggedIn {
                    Section {
                        Button { showLogin = true } label: { Label("Log in to Facebook", systemImage: "person.badge.key") }
                    } footer: { Text("You log in inside the app; only the session cookie is kept, on this device.") }
                }

                if running {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            ProgressView(value: progress.total > 0 ? progress.fraction : 0)
                            Text(progressLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            Text("Keep the app open. Facebook actively limits scraping, so coverage is best-effort.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }

                if let result {
                    Section {
                        Label(summary(result), systemImage: result.photos + result.videos > 0 ? "checkmark.circle" : "exclamationmark.triangle")
                            .foregroundStyle(result.photos + result.videos > 0 ? .green : .orange)
                        if let note = result.note { Text(note).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            .navigationTitle(isUpdate ? "Get New Facebook Photos" : "Add from Facebook")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(running)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(result != nil ? "Done" : "Cancel") { dismiss() }.disabled(running)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isUpdate ? "Get New" : "Download") { start() }
                        .disabled(running || !loggedIn || (!isUpdate && profileURL.trimmingCharacters(in: .whitespaces).isEmpty))
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

    private var progressLine: String {
        progress.total > 0 ? "Downloading \(progress.done) of \(progress.total)…" : progress.phase
    }

    private func summary(_ r: FacebookService.DownloadResult) -> String {
        let n = r.photos + r.videos
        guard n > 0 else { return "Nothing downloaded." }
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

    private func start() {
        Task {
            guard let creds = await FacebookAuth.credentials() else { showLogin = true; return }
            let link = isUpdate ? (existing?.profileURL ?? "") : profileURL.trimmingCharacters(in: .whitespaces)
            guard !link.isEmpty else { return }
            running = true; result = nil
            let bg = BackgroundTaskHolder(); bg.begin(name: "Facebook Download")

            // First run resolves a folder name from the profile; updates reuse the folder.
            let prior = isUpdate ? existing : nil
            let already = Set(prior?.downloaded ?? [])
            let dest: URL
            if isUpdate { dest = targetFolder }
            else {
                // Resolve the profile up front so we can name the folder.
                if let p = await FacebookService.resolveProfile(link, creds: creds) {
                    let sub = targetFolder.appendingPathComponent(sanitize(p.name), isDirectory: true)
                    try? FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
                    dest = sub
                    library.setLastFacebookURL(link, for: targetFolder)
                } else {
                    running = false; bg.end()
                    result = FacebookService.DownloadResult(note: "Couldn’t open that profile. Check the link and that you’re logged in.")
                    return
                }
            }

            let r = await FacebookService.run(profileURL: link, into: dest, alreadyDownloaded: already, creds: creds) { p in
                Task { @MainActor in progress = p }
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
            } else if !isUpdate, let contents = try? FileManager.default.contentsOfDirectory(atPath: dest.path), contents.isEmpty {
                try? FileManager.default.removeItem(at: dest)
            }

            running = false; bg.end()
            result = r
            if r.photos + r.videos > 0 { library.contentDidChange(); onFinished() }
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
        web.customUserAgent = FacebookService.userAgent
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
