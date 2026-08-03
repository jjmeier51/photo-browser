import SwiftUI
import UIKit

/// Bulk "Export All Frames": exports every selected video's frames at once — each into its own
/// "<name> Frames" folder beside it (IMG_1234.mov → "IMG_1234 Frames") — reusing the single-video
/// framework (`FileActions.exportAllFrames`), so every export is HDR-preserving, EXIF-preserving,
/// resumable, and caches each frame's thumbnail as it's written.
///
/// The screen is deliberately modal and non-dismissible while it runs: the whole point is to hand
/// all of the device's resources to the export instead of splitting them with a browsing UI, so it
/// keeps the display awake and runs several videos concurrently. A "Stop" halts scheduling new
/// videos (the ones already in flight finish — each is checkpointed, so nothing is wasted).
struct BulkFrameExportView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let videos: [Entry]

    private enum Status: Equatable { case waiting, running, done(Int), failed }

    @State private var fractions: [URL: Double] = [:]      // 0…1 per video
    @State private var statuses: [URL: Status] = [:]
    @State private var started = false
    @State private var finished = false
    @State private var stopping = false
    @State private var exportedCount = 0
    @State private var failedCount = 0
    @State private var firstNote: String?

    private var overall: Double {
        guard !videos.isEmpty else { return 0 }
        return videos.reduce(0.0) { $0 + (fractions[$1.url] ?? 0) } / Double(videos.count)
    }
    private var completed: Int { exportedCount + failedCount }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                List {
                    ForEach(videos) { row($0) }
                }
            }
            .navigationTitle("Export All Frames")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if finished {
                        Button("Done") { dismiss() }
                    } else {
                        Button("Stop") { stopping = true }.disabled(stopping)
                    }
                }
            }
            .interactiveDismissDisabled(true)
            .task { await run() }
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            if finished {
                Image(systemName: failedCount == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 40)).foregroundStyle(failedCount == 0 ? .green : .orange)
                Text(resultText).font(.headline).multilineTextAlignment(.center)
            } else {
                ProgressView(value: overall).progressViewStyle(.linear).frame(maxWidth: 320)
                Text("\(Int(overall * 100))% · \(completed) of \(videos.count) videos")
                    .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                Text(stopping
                     ? "Finishing the videos already in progress…"
                     : "Exporting frames from \(videos.count) video\(videos.count == 1 ? "" : "s"). Keep this screen open — all resources are on the export.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20).padding(.vertical, 16)
    }

    private var resultText: String {
        if exportedCount == 0 { return "Couldn’t export frames" + (firstNote.map { " — \($0)" } ?? ".") }
        var s = "Exported frames from \(exportedCount) video\(exportedCount == 1 ? "" : "s")."
        if failedCount > 0 { s += " \(failedCount) couldn’t be exported." }
        return s
    }

    @ViewBuilder private func row(_ v: Entry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "film").foregroundStyle(.secondary).frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(v.name).font(.subheadline).lineLimit(1)
                switch statuses[v.url] ?? .waiting {
                case .waiting:
                    Text("Waiting…").font(.caption).foregroundStyle(.tertiary)
                case .running:
                    ProgressView(value: fractions[v.url] ?? 0).progressViewStyle(.linear)
                case .done(let n):
                    Label("\(n) frame\(n == 1 ? "" : "s")", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green)
                case .failed:
                    Label("Couldn’t export", systemImage: "xmark.circle").font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    /// Runs the exports concurrently (bounded), keeping the display awake and holding a background
    /// window. Each video is handed to the shared `exportAllFrames` framework.
    private func run() async {
        guard !started else { return }
        started = true
        guard !videos.isEmpty else { finished = true; return }
        let bg = BackgroundTaskHolder(); bg.begin(name: "Export All Frames")
        UIApplication.shared.isIdleTimerDisabled = true      // long run — keep the screen alive
        // Several videos at once so the whole device works the task; capped so concurrent HDR frame
        // decoders don't exhaust memory.
        let maxConcurrent = min(videos.count, 4)
        await withTaskGroup(of: Void.self) { group in
            var next = 0
            func schedule() {
                guard next < videos.count, !stopping else { return }
                let v = videos[next]; next += 1
                group.addTask { await exportOne(v) }
            }
            for _ in 0..<maxConcurrent { schedule() }
            while let _ = await group.next() { schedule() }
        }
        UIApplication.shared.isIdleTimerDisabled = false
        bg.end()
        library.contentDidChange()                           // surface the new frame folders
        finished = true
    }

    /// Exports one video's frames into its "<name> Frames" folder, then seeds that folder's cover —
    /// mirroring the single-video `Library.startFrameExport`. The heavy decode/encode loop runs
    /// off-main inside `exportAllFrames`; here we only update progress/state on the main actor.
    private func exportOne(_ v: Entry) async {
        statuses[v.url] = .running
        let (folder, count, firstFrame, note) = await FileActions.exportAllFrames(
            of: v.url, folderName: "", requestedFPS: 0) { frac in
                Task { @MainActor in fractions[v.url] = frac }
            }
        fractions[v.url] = 1
        if count > 0, let folder {
            library.markFramesFolder(folder)
            if let firstFrame, let cover = UIImage(contentsOfFile: firstFrame.path) {
                library.setCover(cover, for: folder)
            }
            statuses[v.url] = .done(count)
            exportedCount += 1
        } else {
            statuses[v.url] = .failed
            failedCount += 1
            if firstNote == nil { firstNote = note }
        }
    }
}
