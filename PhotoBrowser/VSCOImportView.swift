import SwiftUI
import UIKit

/// "Download VSCO Profile" / "Get New VSCO Photos": enter a public VSCO username and pull the
/// whole gallery (photos + videos, full resolution) into a "username" folder here. EXIF is
/// preserved; photos with no capture date get VSCO's posting date. The run happens as an
/// app-wide background activity — like the Instagram/OnlyFans downloaders — so you can keep
/// browsing the app (or leave it briefly) while it works. No login needed; download-only.
struct VSCOImportView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let targetFolder: URL
    let onFinished: () -> Void

    @State private var username = ""

    private var isUpdate: Bool { library.isVSCOFolder(targetFolder) || library.lastVSCOUsername(for: targetFolder) != nil }
    private var user: String { VSCOService.sanitizeUsername(username) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("vsco username (e.g. jane)", text: $username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .keyboardType(.twitter)
                } header: {
                    Text("VSCO profile")
                } footer: {
                    Text("Downloads this profile's photos and videos into a “\(user.isEmpty ? "username" : user)” folder here, at full resolution. EXIF is kept; photos without a capture date get VSCO's posting date. The download runs in the background — you can keep using the app (or leave it briefly) and watch progress at the bottom of the screen. Only the public username is sent out; nothing is uploaded.")
                }
            }
            .navigationTitle(isUpdate ? "Get New VSCO Photos" : "Download VSCO Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isUpdate ? "Get New" : "Download") { start() }.disabled(user.isEmpty)
                }
            }
            .onAppear {
                if username.isEmpty {
                    username = library.vscoInfo(for: targetFolder)?.username
                        ?? library.lastVSCOUsername(for: targetFolder) ?? ""
                }
            }
        }
    }

    private func start() {
        let u = user
        guard !u.isEmpty else { return }
        let target = targetFolder, upd = isUpdate, finish = onFinished
        let existing = library.vscoInfo(for: target)
        if !upd { library.setLastVSCOUsername(u, for: target) }
        let id = library.beginActivity(upd ? "VSCO @\(u) — new photos" : "Downloading VSCO @\(u)", indeterminate: true)
        library.setActivity(id, status: "Starting…")
        dismiss()
        let bg = BackgroundTaskHolder(); bg.begin(name: "VSCO Download")
        Task {
            // Update runs into the same folder; a fresh download nests a "username" folder.
            let dest: URL
            if upd, library.isVSCOFolder(target) { dest = target }
            else {
                dest = target.appendingPathComponent(u, isDirectory: true)
                try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            }
            let prior = library.vscoInfo(for: dest) ?? existing
            let already = Set(prior?.downloaded ?? [])

            let r = await VSCOService.run(username: u, into: dest, alreadyDownloaded: already) { p in
                Task { @MainActor in
                    library.setActivity(id, status: p.phase.isEmpty ? "Working…" : p.phase,
                                        fraction: p.total > 0 ? p.fraction : nil)
                }
            }
            library.setCaptions(r.captions)
            if let picData = r.profilePic, let img = UIImage(data: picData) { library.setCover(img, for: dest) }

            if !r.siteID.isEmpty && (r.photos + r.videos > 0 || prior != nil) {
                let info = VSCOFolderInfo(username: u, siteID: r.siteID,
                                         lastUpdated: Date().timeIntervalSince1970,
                                         downloaded: Array(already.union(r.newIDs)),
                                         photos: (prior?.photos ?? 0) + r.photos,
                                         videos: (prior?.videos ?? 0) + r.videos)
                library.setVSCOInfo(info, for: dest)
                library.setLastVSCOUsername(u, for: target)
            } else if !upd, let contents = try? FileManager.default.contentsOfDirectory(atPath: dest.path), contents.isEmpty {
                try? FileManager.default.removeItem(at: dest)   // nothing loaded — drop the empty folder
            }

            library.endActivity(id, result: summary(r, handle: u))
            if r.photos + r.videos > 0 { library.contentDidChange(); finish() }
            bg.end()
        }
    }

    private func summary(_ r: VSCOService.DownloadResult, handle: String) -> String {
        let n = r.photos + r.videos
        guard n > 0 else { return r.note ?? "No new posts for @\(handle)." }
        var s = "@\(handle): downloaded \(r.photos) photo\(r.photos == 1 ? "" : "s") and \(r.videos) video\(r.videos == 1 ? "" : "s")"
        if r.failed > 0 { s += "; \(r.failed) failed" }
        s += "."
        if let note = r.note, !note.isEmpty { s += " " + note }
        return s
    }
}
