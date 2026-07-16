import SwiftUI
import AVFoundation

/// Full-screen player for audio files (mp3 / m4a / wav / aac / …). The browser's folders can
/// hold audio alongside photos and videos, so tapping an audio tile opens this. Playback is
/// on-device only (`AVAudioPlayer`), matching the app's offline model — no network.
///
/// `AudioEngine` owns the player. Creating an `AVAudioPlayer` reads the file, which on a slow
/// external drive must not happen on the main actor (project constraint #1), so the player is
/// built on a detached task. The audio session is set to `.playback` so it sounds even with the
/// ringer silenced.
struct AudioPlayerView: View {
    let entry: Entry
    let onDismiss: () -> Void

    @State private var engine = AudioEngine()
    @State private var fraction: Double = 0        // slider position, 0…1
    @State private var scrubbing = false

    private let tick = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            AppGradient().ignoresSafeArea()
            VStack(spacing: 30) {
                artwork
                Text(entry.name)
                    .font(.headline).multilineTextAlignment(.center)
                    .lineLimit(3).padding(.horizontal, 32)
                if engine.failed {
                    Label("Couldn't play this file", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                } else {
                    scrubber
                    controls
                }
            }
            .padding()
            .frame(maxWidth: 520)
        }
        .overlay(alignment: .topLeading) { closeButton }
        .task { await engine.load(entry.url) }
        .onDisappear { engine.stop() }
        .onReceive(tick) { _ in
            guard !scrubbing, engine.duration > 0 else { return }
            fraction = engine.currentTime / engine.duration
        }
    }

    private var artwork: some View {
        ZStack {
            Circle().fill(.ultraThinMaterial)
            Image(systemName: "music.note")
                .font(.system(size: 74, weight: .light))
                .foregroundStyle(.white.opacity(0.85))
                .symbolEffect(.pulse, isActive: engine.isPlaying)
        }
        .frame(width: 220, height: 220)
        .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
    }

    private var scrubber: some View {
        VStack(spacing: 4) {
            Slider(value: $fraction, in: 0...1) { editing in
                scrubbing = editing
                if !editing { engine.seek(toFraction: fraction) }
            }
            HStack {
                Text(Self.time(fraction * engine.duration))
                Spacer()
                Text(Self.time(engine.duration))
            }
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24)
    }

    private var controls: some View {
        HStack(spacing: 44) {
            Button { engine.seek(by: -15) } label: {
                Image(systemName: "gobackward.15").font(.title2)
            }
            Button { engine.toggle() } label: {
                Image(systemName: engine.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 62))
            }
            Button { engine.seek(by: 15) } label: {
                Image(systemName: "goforward.15").font(.title2)
            }
        }
        .foregroundStyle(.white)
        .overlay(alignment: .trailing) {
            Button { engine.setLoop(!engine.loops) } label: {
                Image(systemName: "repeat")
                    .font(.title3)
                    .foregroundStyle(engine.loops ? Color.accentColor : .secondary)
            }
            .offset(x: 0, y: 54)
        }
    }

    private var closeButton: some View {
        Button(action: onDismiss) {
            Image(systemName: "xmark")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .padding(12)
                .background(.black.opacity(0.35), in: Circle())
        }
        .padding(.leading, 16).padding(.top, 8)
    }

    private static func time(_ t: TimeInterval) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let s = Int(t.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Owns the `AVAudioPlayer` for `AudioPlayerView`. MainActor-isolated state; the file read
/// (player construction) is pushed off-main because it can block on a slow external drive.
@MainActor @Observable final class AudioEngine: NSObject, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    var duration: TimeInterval = 0
    var isPlaying = false
    var loops = false
    var failed = false

    var currentTime: TimeInterval { player?.currentTime ?? 0 }

    func load(_ url: URL) async {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
        // Read the bytes off the main actor (the slow part on an external drive); a memory-mapped
        // read stays cheap even for a big file. `Data` is Sendable, so it crosses back cleanly —
        // then build the player here on the main actor (parsing in-memory data doesn't touch disk).
        let data = await Task.detached(priority: .userInitiated) { () -> Data? in
            try? Data(contentsOf: url, options: .mappedIfSafe)
        }.value
        guard let data, let made = try? AVAudioPlayer(data: data) else { failed = true; return }
        made.delegate = self
        made.prepareToPlay()
        player = made
        duration = made.duration
        play()
    }

    func play() { player?.play(); isPlaying = true }
    func pause() { player?.pause(); isPlaying = false }
    func toggle() { isPlaying ? pause() : play() }

    func seek(toFraction f: Double) {
        guard let player else { return }
        player.currentTime = max(0, min(1, f)) * player.duration
    }
    func seek(by delta: TimeInterval) {
        guard let player else { return }
        player.currentTime = max(0, min(player.duration, player.currentTime + delta))
    }
    func setLoop(_ on: Bool) { loops = on; player?.numberOfLoops = on ? -1 : 0 }

    func stop() {
        player?.stop(); player = nil; isPlaying = false
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.isPlaying = false }
    }
}
