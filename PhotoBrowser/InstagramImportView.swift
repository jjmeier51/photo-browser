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
    let onFinished: () -> Void

    @State private var handle = ""
    @State private var running = false
    @State private var loggedIn = false
    @State private var showLogin = false
    @State private var progress = InstagramService.Progress(phase: "", fraction: 0, done: 0, total: 0)
    @State private var result: InstagramService.DownloadResult?

    private var isUpdate: Bool { existing != nil }

    var body: some View {
        NavigationStack {
            Form {
                if isUpdate {
                    Section {
                        Label("@\(existing?.handle ?? "")", systemImage: "person.crop.circle")
                    } footer: {
                        Text("Fetches posts you don’t already have into “\(targetFolder.lastPathComponent)”.")
                    }
                } else {
                    Section {
                        TextField("instagram handle (e.g. nasa)", text: $handle)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .keyboardType(.URL).disabled(running)
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

                if running {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            ProgressView(value: progress.total > 0 ? progress.fraction : 0)
                            Text(progressLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            Text("Keep the app open. It keeps going briefly if you switch away, but iOS can’t guarantee long background time.")
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
            .navigationTitle(isUpdate ? "Get New Posts" : "Add from Instagram")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(running)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(result != nil ? "Done" : "Cancel") { dismiss() }.disabled(running)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isUpdate ? "Get New" : "Download") { start() }
                        .disabled(running || !loggedIn || (!isUpdate && sanitizedHandle.isEmpty))
                }
            }
            .sheet(isPresented: $showLogin) {
                InstagramLoginView { Task { loggedIn = await InstagramAuth.isLoggedIn() } }
            }
            .task { loggedIn = await InstagramAuth.isLoggedIn() }
            .onAppear { if let existing { handle = existing.handle } }
        }
    }

    private var sanitizedHandle: String {
        var h = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = h.range(of: "instagram.com/") { h = String(h[r.upperBound...]) }
        h = String(h.split(separator: "/").first ?? "")
        h = String(h.split(separator: "?").first ?? "")
        return h.replacingOccurrences(of: "@", with: "")
    }

    private var progressLine: String {
        if progress.total > 0 { return "Downloading \(progress.done) of \(progress.total)…" }
        return progress.phase
    }

    private func summary(_ r: InstagramService.DownloadResult) -> String {
        let n = r.photos + r.videos
        guard n > 0 else { return "Nothing downloaded." }
        var s = "Downloaded \(r.photos) photo\(r.photos == 1 ? "" : "s") and \(r.videos) video\(r.videos == 1 ? "" : "s")"
        if r.failed > 0 { s += "; \(r.failed) failed" }
        return s + "."
    }

    private func start() {
        Task {
            guard let creds = await InstagramAuth.credentials() else { showLogin = true; return }
            let h = isUpdate ? (existing?.handle ?? "") : sanitizedHandle
            guard !h.isEmpty else { return }
            running = true; result = nil
            let bg = BackgroundTaskHolder(); bg.begin(name: "Instagram Download")

            let dest: URL
            if isUpdate {
                dest = targetFolder                                    // current folder is the profile folder
            } else {
                let sub = targetFolder.appendingPathComponent(h, isDirectory: true)
                try? FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
                dest = sub
            }
            let already = Set(existing?.downloaded ?? [])

            let r = await InstagramService.run(handle: h, into: dest, alreadyDownloaded: already, creds: creds) { p in
                Task { @MainActor in progress = p }
            }

            // Apply the app-side metadata: captions, folder cover, and the tracking record.
            for (path, caption) in r.captions { library.setCaption(caption, for: URL(fileURLWithPath: path)) }
            if let picData = r.profilePic, let img = UIImage(data: picData) { library.setCover(img, for: dest) }
            if let profile = r.profile {
                let info = IGFolderInfo(handle: profile.handle, userID: profile.userID,
                                        lastUpdated: Date().timeIntervalSince1970,
                                        downloaded: Array(already.union(r.newIDs)),
                                        photos: (existing?.photos ?? 0) + r.photos,
                                        videos: (existing?.videos ?? 0) + r.videos)
                library.setInstagramInfo(info, for: dest)
            } else if !isUpdate {
                // Profile never loaded — drop the empty folder we created.
                if let contents = try? FileManager.default.contentsOfDirectory(atPath: dest.path), contents.isEmpty {
                    try? FileManager.default.removeItem(at: dest)
                }
            }

            running = false; bg.end()
            result = r
            if r.photos + r.videos > 0 { library.contentDidChange(); onFinished() }
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
