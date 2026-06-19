import SwiftUI
import AVFoundation
import UIKit

/// A clean-up swipe decision, shared by the view and its flash overlay.
private enum CleanupDecision { case delete, keep, favorite }

/// "Tinder"-style clean-up for a folder: one card at a time — swipe left to
/// delete (red flash), swipe up to keep (green flash), swipe down to favorite
/// (pink flash); no extra confirmation, the risk is understood. Each decided item
/// is remembered per folder, so the queue on (re-)open is "viewable items not yet
/// reviewed" — it resumes correctly every run. Videos auto-play and can be
/// scrubbed, and the current item can be moved or copied to another folder.
///
/// `randomized` presents the same items in a shuffled order (the "Randomized Clean
/// Up" entry point) rather than the caller's order; it shares the same per-folder
/// review progress, so the two modes complement each other.
struct FrameCleanupView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let folder: URL
    let randomized: Bool

    @State private var items: [Entry]              // live list (deleted items removed)
    @State private var reviewed: Set<String> = []  // paths decided this session (kept/deleted/favorited)
    @State private var loaded = false
    @State private var drag = CGSize.zero
    @State private var cardToken = 0
    @State private var flash: Flash?
    @State private var busy = false
    @State private var player: CleanupPlayer?      // shared player for the current video (scrubbable)
    @State private var showMovePicker = false
    @State private var showCopyPicker = false
    @State private var moveToast: String?          // brief "Moved to …" confirmation

    private let threshold: CGFloat = 90

    /// Quick-sort destinations offered when cleaning up the "iMessage" folder.
    private static let iMessagePeople = ["Caitlin Turney", "Keri", "Kelsey", "Shannon",
                                         "Mrs. McCarthy", "Leighanne", "Kim Murphy", "Tyler Haas"]
    private var isIMessage: Bool { folder.lastPathComponent == "iMessage" }

    init(folder: URL, items: [Entry], randomized: Bool = false) {
        self.folder = folder
        self.randomized = randomized
        _items = State(initialValue: randomized ? items.shuffled() : items)
    }

    private struct Flash: Identifiable { let id = UUID(); let decision: CleanupDecision }
    /// Items still awaiting a decision, in order.
    private var pending: [Entry] { items.filter { !reviewed.contains($0.url.path) } }
    private var current: Entry? { pending.first }

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(colors: [Color(red: 0.12, green: 0.05, blue: 0.0), Color(red: 0.58, green: 0.24, blue: 0.0)],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
                content
                if let flash { CleanupFlash(decision: flash.decision).id(flash.id) }
                if let moveToast { MoveToast(text: moveToast).id(moveToast) }
            }
            .navigationTitle(randomized ? "Randomized Clean Up" : "Clean Up")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if current != nil {
                        Text("\(items.count - pending.count + 1) / \(items.count)")
                            .font(.subheadline.monospacedDigit()).foregroundStyle(.white.opacity(0.85))
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if current != nil {
                        Button { showMovePicker = true } label: { Image(systemName: "folder") }
                        Button { showCopyPicker = true } label: { Image(systemName: "doc.on.doc") }
                    }
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showMovePicker) {
                FolderPicker(root: library.rootURL ?? folder, startAt: library.lastTransferDestination) { dest in
                    moveCurrent(to: dest, confirm: dest.lastPathComponent)
                }
            }
            .sheet(isPresented: $showCopyPicker) {
                FolderPicker(root: library.rootURL ?? folder, confirmTitle: "Copy Here", startAt: library.lastTransferDestination) { dest in copyCurrent(to: dest) }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            guard !loaded else { return }
            reviewed = library.reviewedInCleanup(folder)   // resume: skip already-decided items
            loaded = true
        }
        // Set up / tear down the scrubbable player as the current video changes.
        .task(id: current?.url.path ?? "·") {
            player?.stop(); player = nil
            if let c = current, c.kind == .video { player = CleanupPlayer(url: c.url) }
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
                scrubber
                if isIMessage { sortRow }
                controls
            }
        }
    }

    /// Quick "sort to person" chips shown when cleaning up the iMessage folder. One
    /// tap moves the current item to that person's folder (a sibling of iMessage),
    /// confirms, and advances. "Elsewhere" opens the folder picker.
    private var sortRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Self.iMessagePeople, id: \.self) { name in
                    Button { sortTo(name) } label: { chipLabel(name, system: "person.fill") }
                }
                Button { showMovePicker = true } label: { chipLabel("Move elsewhere…", system: "folder") }
            }
            .padding(.horizontal, 14)
        }
        .padding(.vertical, 6)
    }

    private func chipLabel(_ text: String, system: String) -> some View {
        Label(text, systemImage: system)
            .font(.caption.weight(.medium)).foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(.white.opacity(0.18), in: Capsule())
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
            RoundedRectangle(cornerRadius: 20).fill(.pink).opacity(favoriteProgress * 0.35)
        }
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.12)))
        .overlay(alignment: .topLeading) {
            stamp("DELETE", icon: "trash.fill", color: .red).opacity(deleteProgress).padding(26)
        }
        .overlay(alignment: .top) {
            stamp("KEEP", icon: "checkmark", color: .green).opacity(keepProgress).padding(.top, 26)
        }
        .overlay(alignment: .bottom) {
            stamp("FAVORITE", icon: "heart.fill", color: .pink).opacity(favoriteProgress).padding(.bottom, 26)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .offset(drag)
        .rotationEffect(.degrees(Double(drag.width) / 22))
        .id(cardToken)
        .gesture(
            DragGesture()
                .onChanged { drag = $0.translation }
                .onEnded { v in
                    let t = v.translation
                    if t.height < -threshold && abs(t.height) >= abs(t.width) { commit(.keep) }
                    else if t.height > threshold && abs(t.height) >= abs(t.width) { commit(.favorite) }
                    else if t.width < -threshold { commit(.delete) }
                    else { withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { drag = .zero } }
                }
        )
    }

    @ViewBuilder private func mediaView(_ entry: Entry) -> some View {
        if entry.kind == .video {
            if let player { CleanupVideoLayer(player: player.player) }
            else { Color.black }
        } else { CleanupPhoto(url: entry.url) }
    }

    /// Scrubber for the current video (auto-playing); seeks as it's dragged. Sits
    /// below the card so it never conflicts with the card's swipe gestures.
    @ViewBuilder private var scrubber: some View {
        if current?.kind == .video, let player, player.duration > 0 {
            HStack(spacing: 8) {
                Text(timecode(player.current)).font(.caption2.monospacedDigit()).foregroundStyle(.white.opacity(0.8))
                Slider(value: Binding(get: { min(player.current, player.duration) },
                                      set: { player.seek(to: $0) }),
                       in: 0...player.duration)
                    .tint(.white)
                Text(timecode(player.duration)).font(.caption2.monospacedDigit()).foregroundStyle(.white.opacity(0.8))
            }
            .padding(.horizontal, 18).padding(.top, 8)
        }
    }

    private func timecode(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        let t = Int(s.rounded()); return String(format: "%d:%02d", t / 60, t % 60)
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
    private var favoriteProgress: Double {
        guard drag.height > 0, abs(drag.height) >= abs(drag.width) else { return 0 }
        return min(1, Double(drag.height) / Double(threshold))
    }

    // MARK: - Controls / states

    private var controls: some View {
        HStack(spacing: 30) {
            circleButton("trash.fill", .red) { commit(.delete) }
            circleButton("heart.fill", .pink) { commit(.favorite) }
            circleButton("checkmark", .green) { commit(.keep) }
        }
        .padding(.top, 10).padding(.bottom, 14)
    }

    private func circleButton(_ icon: String, _ color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.title.weight(.bold)).foregroundStyle(color)
                .frame(width: 62, height: 62)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(color.opacity(0.5), lineWidth: 1.5))
        }
    }

    private var completion: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 76)).foregroundStyle(.green)
            Text("All cleaned up!").font(.title2.weight(.bold))
            Text("\(items.count) \(items.count == 1 ? "item" : "items") kept.")
                .foregroundStyle(.white.opacity(0.85))
            Button { startOver() } label: { Label("Review Again", systemImage: "arrow.counterclockwise") }
                .buttonStyle(.bordered).tint(.white).padding(.top, 6)
        }
        .foregroundStyle(.white)
    }

    private func message(_ text: String, icon: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 60)).foregroundStyle(.white.opacity(0.8))
            Text(text).font(.headline).foregroundStyle(.white.opacity(0.85))
        }
    }

    // MARK: - Actions

    private func commit(_ decision: CleanupDecision) {
        guard !busy, current != nil else { return }   // ignore a second swipe mid-animation
        busy = true
        flash = Flash(decision: decision)
        UIImpactFeedbackGenerator(style: decision == .delete ? .rigid : .soft).impactOccurred()
        withAnimation(.easeIn(duration: 0.16)) {
            switch decision {
            case .delete:   drag = CGSize(width: -900, height: drag.height)
            case .keep:     drag = CGSize(width: drag.width, height: -1100)
            case .favorite: drag = CGSize(width: drag.width, height: 1100)
            }
        }
        Task {
            try? await Task.sleep(nanoseconds: 160_000_000)
            switch decision {
            case .delete:   performDelete()
            case .keep:     performKeep()
            case .favorite: performFavorite()
            }
            drag = .zero
            cardToken += 1                 // fresh, centered card for the next item
            busy = false
            try? await Task.sleep(nanoseconds: 300_000_000)
            if flash?.decision == decision { flash = nil }
        }
    }

    private func performKeep() {
        guard let item = current else { return }
        reviewed.insert(item.url.path)
        library.markCleanupReviewed(item.url, in: folder)
    }

    private func performFavorite() {
        guard let item = current else { return }
        if !library.isFavorite(item.url) { library.toggleFavorite(item.url) }   // keep + favorite
        reviewed.insert(item.url.path)
        library.markCleanupReviewed(item.url, in: folder)
    }

    private func performDelete() {
        guard let item = current else { return }
        FileActions.delete([item])               // risk understood — no extra confirmation
        reviewed.insert(item.url.path)            // recorded so progress survives a restart
        library.markCleanupReviewed(item.url, in: folder)
        items.removeAll { $0.url == item.url }    // gone from disk
    }

    /// Moves the current item to another folder (re-keying its labels), confirms with
    /// a brief toast, and advances — no "Done" needed.
    private func moveCurrent(to dest: URL, confirm: String? = nil) {
        guard let item = current else { return }
        let outcome = FileActions.move([item.url], to: dest, renameOnCollision: true)
        guard !outcome.moved.isEmpty else { return }
        for (from, to) in outcome.moved { library.itemMoved(from: from, to: to) }
        library.setLastTransferDestination(dest)
        items.removeAll { $0.url == item.url }    // left this folder
        library.contentDidChange()
        if let confirm { showToast("Moved to \(confirm)") }
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        cardToken += 1
    }

    /// iMessage quick-sort: move the current item into the named person's folder (a
    /// sibling of "iMessage", created if needed).
    private func sortTo(_ person: String) {
        let dest = folder.deletingLastPathComponent().appendingPathComponent(person, isDirectory: true)
        try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        moveCurrent(to: dest, confirm: person)
    }

    private func showToast(_ text: String) {
        moveToast = text
        Task { try? await Task.sleep(nanoseconds: 1_200_000_000); if moveToast == text { moveToast = nil } }
    }

    /// Copies the current item to another folder (fresh file, no labels); the item
    /// stays in the queue.
    private func copyCurrent(to dest: URL) {
        guard let item = current else { return }
        _ = FileActions.copy([item.url], to: dest)
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        library.contentDidChange()
    }

    private func startOver() {
        library.resetCleanup(folder)
        reviewed = []                             // re-review what's left (deleted items stay gone)
        cardToken += 1
    }
}

/// A scrubbable, looping, auto-playing player shared between the card (display) and
/// the scrubber (control) for the current video.
@Observable @MainActor
final class CleanupPlayer {
    @ObservationIgnored let player: AVQueuePlayer
    @ObservationIgnored private var looper: AVPlayerLooper?
    @ObservationIgnored private var observer: Any?
    var current: Double = 0
    var duration: Double = 0

    init(url: URL) {
        let item = AVPlayerItem(url: url)
        let p = AVQueuePlayer()
        looper = AVPlayerLooper(player: p, templateItem: item)
        p.isMuted = true
        player = p
        observer = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main) { [weak self] t in
            guard let self else { return }
            current = t.seconds.isFinite ? t.seconds : 0
            if duration == 0, let d = p.currentItem?.duration.seconds, d.isFinite, d > 0 { duration = d }
        }
        p.play()
    }

    func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func stop() {
        if let observer { player.removeTimeObserver(observer); self.observer = nil }
        player.pause()
    }
}

/// Renders an existing (externally-owned) AVPlayer.
private struct CleanupVideoLayer: UIViewRepresentable {
    let player: AVQueuePlayer
    func makeUIView(context: Context) -> PlayerLayerView {
        let v = PlayerLayerView(); v.playerLayer.player = player; v.playerLayer.videoGravity = .resizeAspect; return v
    }
    func updateUIView(_ v: PlayerLayerView, context: Context) {
        if v.playerLayer.player !== player { v.playerLayer.player = player }
    }
    final class PlayerLayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}

/// Brief "Moved to …" confirmation banner near the top, auto-fading.
private struct MoveToast: View {
    let text: String
    @State private var shown = false

    var body: some View {
        VStack {
            Label(text, systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.green.opacity(0.9), in: Capsule())
                .shadow(color: .black.opacity(0.4), radius: 4)
                .padding(.top, 8)
                .opacity(shown ? 1 : 0).offset(y: shown ? 0 : -12)
            Spacer()
        }
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.spring(response: 0.3)) { shown = true }
            withAnimation(.easeIn(duration: 0.3).delay(0.9)) { shown = false }
        }
    }
}

/// Brief full-screen tint + label confirming the swipe.
private struct CleanupFlash: View {
    let decision: CleanupDecision
    @State private var faded = false

    var body: some View {
        ZStack {
            color.opacity(faded ? 0 : 0.4)
            Label(text, systemImage: icon)
                .font(.title.weight(.bold)).foregroundStyle(.white)
                .shadow(color: .black.opacity(0.5), radius: 5)
                .scaleEffect(faded ? 1.2 : 1).opacity(faded ? 0 : 1)
        }
        .ignoresSafeArea().allowsHitTesting(false)
        .onAppear { withAnimation(.easeOut(duration: 0.4)) { faded = true } }
    }

    private var color: Color { decision == .delete ? .red : decision == .favorite ? .pink : .green }
    private var icon: String { decision == .delete ? "trash.fill" : decision == .favorite ? "heart.fill" : "checkmark.circle.fill" }
    private var text: String { decision == .delete ? "Deleted" : decision == .favorite ? "Favorited" : "Kept" }
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
