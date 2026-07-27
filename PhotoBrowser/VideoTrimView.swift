import SwiftUI
import AVKit
import AVFoundation
import UIKit

/// A focused video **trim** editor: a preview player above a **filmstrip** scrubber with two drag
/// handles that mark the keep range. Saving exports that range losslessly (passthrough — no
/// re-encode, so quality/HDR survive) to a new "… trimmed" file beside the original, so the source is
/// never destroyed. The filmstrip is generated off-main via `VideoComposer.filmstrip`.
struct VideoTrimView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let url: URL
    var onDone: () -> Void = {}

    @State private var player = AVPlayer()
    @State private var duration: Double = 0
    @State private var startFrac: Double = 0
    @State private var endFrac: Double = 1
    @State private var thumbs: [UIImage] = []
    @State private var exporting = false
    @State private var errorMsg: String?

    private var startTime: Double { startFrac * duration }
    private var endTime: Double { endFrac * duration }
    private var minGap: Double { duration > 0 ? min(0.4, 0.5 / duration) : 0.05 }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                VideoPlayer(player: player)
                    .frame(maxHeight: 380)
                    .background(Color.black)

                filmstrip
                    .frame(height: 66)
                    .padding(.horizontal)

                Text("\(fmt(startTime)) – \(fmt(endTime))   ·   keeps \(fmt(endTime - startTime))")
                    .font(.footnote.monospacedDigit()).foregroundStyle(.secondary)

                HStack(spacing: 24) {
                    Button { seek(to: startTime); player.play() } label: {
                        Label("Preview", systemImage: "play.fill")
                    }
                    Button { player.pause() } label: { Label("Pause", systemImage: "pause.fill") }
                }
                .font(.callout)
                Spacer()
            }
            .navigationTitle("Trim Video")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { export() }.disabled(exporting || endTime - startTime < 0.3)
                }
            }
            .overlay {
                if exporting {
                    ProgressView("Saving…")
                        .padding(20).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .alert("Couldn’t Trim", isPresented: Binding(get: { errorMsg != nil }, set: { if !$0 { errorMsg = nil } })) {
                Button("OK") { errorMsg = nil }
            } message: { Text(errorMsg ?? "") }
            .task { await load() }
            .onDisappear { player.pause() }
        }
    }

    private var filmstrip: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let startX = CGFloat(startFrac) * w
            let endX = CGFloat(endFrac) * w
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    ForEach(thumbs.indices, id: \.self) { i in
                        Image(uiImage: thumbs[i]).resizable().scaledToFill()
                            .frame(width: w / CGFloat(max(thumbs.count, 1)), height: 66).clipped()
                    }
                    if thumbs.isEmpty { Rectangle().fill(.quaternary) }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))

                // Dim the trimmed-away regions.
                Rectangle().fill(.black.opacity(0.55)).frame(width: max(0, startX))
                Rectangle().fill(.black.opacity(0.55)).frame(width: max(0, w - endX)).offset(x: endX)

                // Selection outline.
                RoundedRectangle(cornerRadius: 6).stroke(Color.yellow, lineWidth: 3)
                    .frame(width: max(0, endX - startX)).offset(x: startX)

                // Handles.
                handle.offset(x: startX - 11).gesture(dragHandle(isStart: true, width: w))
                handle.offset(x: endX - 11).gesture(dragHandle(isStart: false, width: w))
            }
            .coordinateSpace(name: "strip")
        }
    }

    private var handle: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color.yellow)
            .frame(width: 22, height: 76)
            .overlay(Image(systemName: "line.3.horizontal").font(.caption2).foregroundStyle(.black))
            .shadow(radius: 2)
    }

    private func dragHandle(isStart: Bool, width w: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("strip"))
            .onChanged { v in
                guard w > 0 else { return }
                let f = Double(min(max(v.location.x / w, 0), 1))
                if isStart {
                    startFrac = min(f, endFrac - minGap)
                    seek(to: startTime)
                } else {
                    endFrac = max(f, startFrac + minGap)
                    seek(to: endTime)
                }
            }
    }

    private func load() async {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let d = (try? await asset.load(.duration).seconds) ?? 0
        duration = (d.isFinite && d > 0) ? d : 0
        player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
        thumbs = await VideoComposer.filmstrip(url: url, count: 12)
    }

    private func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func export() {
        player.pause()
        exporting = true
        let s = startTime, e = endTime, src = url
        Task {
            let dest = trimDestination(for: src)
            let ok = await VideoComposer.trim(src, start: s, end: e, to: dest)
            exporting = false
            if ok {
                Haptics.success()
                library.contentDidChange(under: src.deletingLastPathComponent())
                onDone()
                dismiss()
            } else {
                Haptics.error()
                errorMsg = "The trimmed video couldn’t be exported."
            }
        }
    }

    /// A non-colliding "<name> trimmed.<ext>" beside the source (keeps mov/mp4/m4v, else mov).
    private func trimDestination(for src: URL) -> URL {
        let dir = src.deletingLastPathComponent()
        let base = src.deletingPathExtension().lastPathComponent
        let ext = ["mov", "mp4", "m4v"].contains(src.pathExtension.lowercased()) ? src.pathExtension : "mov"
        var c = dir.appendingPathComponent("\(base) trimmed.\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: c.path) {
            c = dir.appendingPathComponent("\(base) trimmed \(n).\(ext)"); n += 1
        }
        return c
    }

    private func fmt(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
