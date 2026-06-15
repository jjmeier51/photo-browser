import SwiftUI
import AVFoundation
import UIKit

/// "Tinder"-style clean-up for a frames folder: one card at a time — swipe left to
/// delete (red flash, no extra confirmation; the risk is understood), swipe up to
/// keep (green flash). Progress is a per-folder cursor (kept items stay at the front
/// of the list, deleted ones vanish), so re-opening resumes where it left off.
struct FrameCleanupView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let folder: URL

    @State private var items: [Entry]
    @State private var cursor = 0
    @State private var started = false
    @State private var drag = CGSize.zero
    @State private var cardToken = 0
    @State private var flash: Flash?

    private let threshold: CGFloat = 90

    init(folder: URL, items: [Entry]) {
        self.folder = folder
        _items = State(initialValue: items)
    }

    private struct Flash: Identifiable { let id = UUID(); let delete: Bool }
    private var current: Entry? { items.indices.contains(cursor) ? items[cursor] : nil }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                content
                if let flash { CleanupFlash(delete: flash.delete).id(flash.id) }
            }
            .navigationTitle("Clean Up")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if current != nil {
                        Text("\(min(cursor + 1, items.count)) / \(items.count)")
                            .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            guard !started else { return }
            cursor = min(max(0, library.cleanupCursor(for: folder)), items.count)
            started = true
        }
    }

    @ViewBuilder private var content: some View {
        if items.isEmpty {
            message("Nothing to clean up", icon: "tray")
        } else if current == nil {
            completion
        } else {
            VStack(spacing: 0) {
                card
                controls
            }
        }
    }

    // MARK: - Card

    private var card: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20).fill(Color(white: 0.08))
            if let current {
                mediaView(current).clipShape(RoundedRectangle(cornerRadius: 20))
            }
            RoundedRectangle(cornerRadius: 20).fill(.red).opacity(deleteProgress * 0.35)
            RoundedRectangle(cornerRadius: 20).fill(.green).opacity(keepProgress * 0.35)
        }
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.12)))
        .overlay(alignment: .topLeading) {
            stamp("DELETE", icon: "trash.fill", color: .red).opacity(deleteProgress).padding(26)
        }
        .overlay(alignment: .top) {
            stamp("KEEP", icon: "checkmark", color: .green).opacity(keepProgress).padding(.top, 26)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .offset(drag)
        .rotationEffect(.degrees(Double(drag.width) / 22))
        .id(cardToken)
        .gesture(
            DragGesture()
                .onChanged { drag = $0.translation }
                .onEnded { v in
                    let t = v.translation
                    if t.height < -threshold && abs(t.height) >= abs(t.width) { commit(delete: false) }
                    else if t.width < -threshold { commit(delete: true) }
                    else { withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { drag = .zero } }
                }
        )
    }

    @ViewBuilder private func mediaView(_ entry: Entry) -> some View {
        if entry.kind == .video { CleanupVideo(url: entry.url) }
        else { CleanupPhoto(url: entry.url) }
    }

    private func stamp(_ text: String, icon: String, color: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.title2.weight(.heavy)).foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(color, in: RoundedRectangle(cornerRadius: 10))
            .rotationEffect(.degrees(-8))
    }

    private var deleteProgress: Double {
        guard drag.width < 0, abs(drag.width) > abs(drag.height) else { return 0 }
        return min(1, Double(-drag.width) / Double(threshold))
    }
    private var keepProgress: Double {
        guard drag.height < 0, abs(drag.height) >= abs(drag.width) else { return 0 }
        return min(1, Double(-drag.height) / Double(threshold))
    }

    // MARK: - Controls / states

    private var controls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 44) {
                circleButton("trash.fill", .red) { commit(delete: true) }
                circleButton("checkmark", .green) { commit(delete: false) }
            }
            Text("Swipe ← to delete  ·  swipe ↑ to keep")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 18)
    }

    private func circleButton(_ icon: String, _ color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.title.weight(.bold)).foregroundStyle(color)
                .frame(width: 66, height: 66)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(color.opacity(0.5), lineWidth: 1.5))
        }
    }

    private var completion: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 76)).foregroundStyle(.green)
            Text("All cleaned up!").font(.title2.weight(.bold))
            Text("\(items.count) \(items.count == 1 ? "item" : "items") kept.")
                .foregroundStyle(.secondary)
            Button { startOver() } label: { Label("Review Again", systemImage: "arrow.counterclockwise") }
                .buttonStyle(.bordered).tint(.white).padding(.top, 6)
        }
        .foregroundStyle(.white)
    }

    private func message(_ text: String, icon: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 60)).foregroundStyle(.secondary)
            Text(text).font(.headline).foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    private func commit(delete: Bool) {
        guard current != nil else { return }
        flash = Flash(delete: delete)
        UIImpactFeedbackGenerator(style: delete ? .rigid : .soft).impactOccurred()
        withAnimation(.easeIn(duration: 0.24)) {
            drag = delete ? CGSize(width: -900, height: drag.height)
                          : CGSize(width: drag.width, height: -1100)
        }
        Task {
            try? await Task.sleep(nanoseconds: 240_000_000)
            if delete { performDelete() } else { performKeep() }
            drag = .zero
            cardToken += 1                 // fresh, centered card for the next item
            try? await Task.sleep(nanoseconds: 350_000_000)
            if flash?.delete == delete { flash = nil }
        }
    }

    private func performKeep() {
        cursor += 1
        library.setCleanupCursor(cursor, for: folder)
    }

    private func performDelete() {
        guard items.indices.contains(cursor) else { return }
        FileActions.delete([items[cursor]])      // risk understood — no extra confirmation
        items.remove(at: cursor)                 // next item slides into `cursor`
        library.setCleanupCursor(cursor, for: folder)
    }

    private func startOver() {
        cursor = 0
        library.setCleanupCursor(0, for: folder)
        cardToken += 1
    }
}

/// Brief full-screen tint + label confirming the swipe (red = deleted, green = kept).
private struct CleanupFlash: View {
    let delete: Bool
    @State private var faded = false

    var body: some View {
        ZStack {
            (delete ? Color.red : Color.green).opacity(faded ? 0 : 0.4)
            Label(delete ? "Deleted" : "Kept", systemImage: delete ? "trash.fill" : "checkmark.circle.fill")
                .font(.title.weight(.bold)).foregroundStyle(.white)
                .shadow(color: .black.opacity(0.5), radius: 5)
                .scaleEffect(faded ? 1.2 : 1).opacity(faded ? 0 : 1)
        }
        .ignoresSafeArea().allowsHitTesting(false)
        .onAppear { withAnimation(.easeOut(duration: 0.55)) { faded = true } }
    }
}

/// Async photo for a clean-up card: a fast preview, then the full image.
private struct CleanupPhoto: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image { Image(uiImage: image).resizable().scaledToFit() }
            else { ProgressView().tint(.white) }
        }
        .task(id: url) {
            if let preview = await ZoomableImageView.decode(url: url, maxPixel: 1200, fullQuality: false) { image = preview }
            if let full = await ZoomableImageView.decode(url: url, maxPixel: 2400, fullQuality: true) { image = full }
        }
    }
}

/// Looping, muted, auto-playing video preview for a clean-up card.
private struct CleanupVideo: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> LoopView { let v = LoopView(); v.load(url); return v }
    func updateUIView(_ v: LoopView, context: Context) { if v.url != url { v.load(url) } }
    static func dismantleUIView(_ v: LoopView, coordinator: ()) { v.stop() }

    final class LoopView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        private(set) var url: URL?
        private var player: AVQueuePlayer?
        private var looper: AVPlayerLooper?
        private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

        func load(_ url: URL) {
            self.url = url
            let p = AVQueuePlayer()
            looper = AVPlayerLooper(player: p, templateItem: AVPlayerItem(url: url))
            p.isMuted = true
            playerLayer.player = p
            playerLayer.videoGravity = .resizeAspect
            player = p
            p.play()
        }

        func stop() { player?.pause() }
    }
}
