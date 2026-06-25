import SwiftUI
import UIKit

/// "Download YouTube Video Here": paste (or auto-fill from the clipboard) a YouTube link and
/// download it into the current folder at the highest quality the device can assemble — the title
/// becomes the file name, the description the caption, and the upload date the capture date.
/// Runs under a background-task window so it keeps going briefly if you leave the app.
struct YouTubeImportView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let targetFolder: URL
    let onFinished: () -> Void

    @State private var link = ""
    @State private var maxHeight = 2160
    @State private var running = false
    @State private var phase = ""
    @State private var resultText: String?
    @State private var ok = false

    private let qualities: [(String, Int)] = [("Best (up to 4K)", 2160), ("1440p", 1440), ("1080p", 1080), ("720p", 720)]

    /// Reflects whether the on-device transcoder (FFmpegKit) is linked, so 1440p/4K (VP9/AV1) work.
    private var qualityNote: String {
        VideoTranscoder.isAvailable
            ? "1440p/4K enabled (FFmpegKit linked) — those renditions are transcoded to HEVC on-device."
            : "1440p/4K need FFmpegKit added to the project; without it, this caps at the best 1080p (H.264) rendition."
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("YouTube link", text: $link)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .keyboardType(.URL).disabled(running)
                    Picker("Max quality", selection: $maxHeight) {
                        ForEach(qualities, id: \.1) { Text($0.0).tag($0.1) }
                    }.disabled(running)
                } footer: {
                    Text("Downloads the video into “\(targetFolder.lastPathComponent)”. The title becomes the file name, the description the caption, and the upload date the capture date. \(qualityNote) Only the public link is sent out.")
                }

                if running {
                    Section { Label(phase.isEmpty ? "Working…" : phase, systemImage: "arrow.down.circle").foregroundStyle(.secondary) }
                }
                if let resultText {
                    Section { Text(resultText).foregroundStyle(ok ? Color.green : Color.orange) }
                }
            }
            .navigationTitle("Download YouTube Video")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(running)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(ok ? "Done" : "Cancel") { dismiss() }.disabled(running)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Download") { start() }.disabled(running || YouTubeService.videoID(from: link) == nil)
                }
            }
            .onAppear {
                // Pre-fill from the clipboard when it holds a YouTube link.
                if link.isEmpty, let s = UIPasteboard.general.string, YouTubeService.videoID(from: s) != nil { link = s }
            }
            .onChange(of: running) { _, on in UIApplication.shared.isIdleTimerDisabled = on }
            .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        }
    }

    private func start() {
        let url = link, height = maxHeight, folder = targetFolder
        guard YouTubeService.videoID(from: url) != nil else { return }
        running = true; resultText = nil; ok = false
        let bg = BackgroundTaskHolder(); bg.begin(name: "YouTube Download")
        Task {
            phase = "Resolving…"
            guard let r = await YouTubeService.resolve(url: url, maxHeight: height) else {
                running = false; bg.end()
                resultText = "Couldn’t resolve this video — the resolver may be down or the link is unavailable. Try again or a different quality."
                return
            }
            let dest = await YouTubeService.download(r, into: folder) { p in Task { @MainActor in phase = p } }
            if let dest {
                if !r.description.isEmpty { library.setCaptions([dest.path: r.description]) }
                library.contentDidChange()
                onFinished()
                ok = true
                resultText = "Saved “\(dest.lastPathComponent)” (\(r.quality))."
            } else {
                resultText = "Download or merge failed. Try a lower quality (1440p/4K need FFmpegKit)."
            }
            running = false; bg.end()
        }
    }
}
