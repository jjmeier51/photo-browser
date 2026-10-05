import SwiftUI
import UIKit
import AVFoundation
import Combine

/// The preview player (PRV-1/2/5/7): one `AVPlayer` whose item is rebuilt from the document after
/// each committed edit (keeping the playhead), with coalesced zero-tolerance seeks for scrubbing,
/// frame stepping, and a stall counter that flips the preview onto proxies.
@MainActor @Observable final class VEPlayback {
    let player = AVPlayer()
    private(set) var currentTime: VETime = 0
    private(set) var isPlaying = false
    private(set) var duration: VETime = 0
    private(set) var usesProxy = false
    private(set) var missingClipIDs: [String] = []
    private(set) var isBuilding = false
    var frameRate = 30
    /// Pixel size of the preview view; the composition renders at this size, capped at 1920 (PRV-3).
    var previewPixelSize: CGSize = .zero
    /// Called when original-media playback stalled twice within 10 s (PRV-7).
    @ObservationIgnored var onStall: (() -> Void)?

    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var keepUpObservation: NSKeyValueObservation?
    private var stallTimes: [Date] = []
    @ObservationIgnored private var buildTask: Task<Void, Never>?
    private var pendingSeek: VETime?
    private var seekInFlight = false
    private var lastSeekAt = Date.distantPast
    private var scrubMuted = false

    init() {
        player.actionAtItemEnd = .pause
        player.automaticallyWaitsToMinimizeStalling = false
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 60), queue: .main) { [weak self] t in
            Task { @MainActor [weak self] in
                guard let self, self.isPlaying else { return }
                self.currentTime = VETimeUtil.us(t)
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] n in
            Task { @MainActor [weak self] in
                guard let self, let item = n.object as? AVPlayerItem, item === self.player.currentItem else { return }
                self.isPlaying = false
                self.currentTime = max(0, self.duration - VETimeUtil.frame(self.frameRate))
            }
        }
    }

    /// Rebuild the composition from the document (PRV-5). Builds are coalesced: a newer request
    /// cancels one still in flight. The new item lands at the same time position.
    func rebuild(document: VEDocument, useProxies: Bool) {
        buildTask?.cancel()
        let project = document.project
        let package = document.packageURL
        let store = document.store
        var opts = VECompositionBuilder.Options()
        opts.useProxies = useProxies
        opts.renderSize = previewPixelSize
        frameRate = project.settings.frameRate
        isBuilding = true
        buildTask = Task { [weak self] in
            let built = try? await VECompositionBuilder.build(project, package: package, store: store, options: opts)
            guard !Task.isCancelled, let self else { return }
            self.isBuilding = false
            guard let built else { return }
            self.install(built)
        }
    }

    private func install(_ built: VEBuiltComposition) {
        let wasPlaying = isPlaying
        let t = min(currentTime, max(0, VETimeUtil.us(built.duration) - 1))
        duration = VETimeUtil.us(built.duration)
        usesProxy = built.usesProxy
        missingClipIDs = built.missingClipIDs
        let item = built.playerItem()
        keepUpObservation?.invalidate()
        keepUpObservation = item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] _, change in
            guard change.newValue == false else { return }
            Task { @MainActor [weak self] in self?.noteStall() }
        }
        player.replaceCurrentItem(with: item)
        currentTime = t
        player.seek(to: VETimeUtil.cm(t), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, wasPlaying else { return }
                self.player.play()
            }
        }
    }

    private func noteStall() {
        guard isPlaying, !usesProxy else { return }
        let now = Date()
        stallTimes = stallTimes.filter { now.timeIntervalSince($0) < 10 } + [now]
        if stallTimes.count >= 2 {
            stallTimes.removeAll()
            onStall?()
        }
    }

    // MARK: Transport

    func play() {
        guard player.currentItem != nil else { return }
        if currentTime >= duration - 1 { currentTime = 0; player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) }
        restoreAudio()
        isPlaying = true
        player.play()
    }

    func pause() {
        isPlaying = false
        player.pause()
        if let t = player.currentItem?.currentTime(), t.isNumeric { currentTime = VETimeUtil.us(t) }
    }

    func togglePlay() { isPlaying ? pause() : play() }

    /// Move the playhead. `scrubbing` keeps audio silent (PRV-2) and coalesces at ≤ 60 seeks/s.
    func seek(to time: VETime, scrubbing: Bool = false) {
        let clamped = max(0, min(time, max(0, duration - 1)))
        currentTime = clamped
        if isPlaying { pause() }
        if scrubbing && !scrubMuted { scrubMuted = true; player.isMuted = true }
        pendingSeek = clamped
        pumpSeek()
    }

    func endScrub() { restoreAudio() }

    private func restoreAudio() {
        if scrubMuted { scrubMuted = false; player.isMuted = false }
    }

    private func pumpSeek() {
        guard !seekInFlight, let target = pendingSeek else { return }
        let since = Date().timeIntervalSince(lastSeekAt)
        if since < 1.0 / 60 {
            seekInFlight = true
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64((1.0 / 60 - since) * 1_000_000_000))
                await MainActor.run { self?.seekInFlight = false; self?.pumpSeek() }
            }
            return
        }
        pendingSeek = nil
        seekInFlight = true
        lastSeekAt = Date()
        player.seek(to: VETimeUtil.cm(target), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.seekInFlight = false
                self?.pumpSeek()      // the newest position always lands
            }
        }
    }

    /// Exactly one project frame forward or back (PRV-1).
    func step(_ frames: Int) {
        let f = VETimeUtil.frame(frameRate)
        let snapped = VETimeUtil.snapToFrame(currentTime, fps: frameRate)
        seek(to: snapped + VETime(frames) * f)
    }

    /// Re-render the current frame (after a live parameter change) without moving.
    func refreshFrame() { seek(to: currentTime) }

    func shutdown() {
        buildTask?.cancel()
        pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        keepUpObservation?.invalidate()
        player.replaceCurrentItem(with: nil)
    }
}

// MARK: - Preview view (player layer + on-canvas transform gizmo)

/// Hosts the `AVPlayerLayer` letterboxed at the project ratio and, when a clip is selected, the
/// bounding box with pinch / drag / twist gestures (TL-9, CAN-5). Transform values are reported in
/// canvas-normalized units so the compositor and the gizmo agree.
struct VEPreviewView: UIViewRepresentable {
    let player: AVPlayer
    let canvasSize: CGSize
    var gizmo: VEGizmoState?
    var onPixelSize: (CGSize) -> Void
    var onTransform: (VETransform, VEGesturePhase) -> Void
    var onTapCanvas: () -> Void

    func makeUIView(context: Context) -> VEPreviewUIView {
        let v = VEPreviewUIView()
        v.playerLayer.player = player
        v.onTransform = onTransform
        v.onPixelSize = onPixelSize
        v.onTapCanvas = onTapCanvas
        return v
    }

    func updateUIView(_ v: VEPreviewUIView, context: Context) {
        v.canvasSize = canvasSize
        v.gizmo = gizmo
        v.onTransform = onTransform
        v.onPixelSize = onPixelSize
        v.onTapCanvas = onTapCanvas
        v.setNeedsLayout()
        v.gizmoLayer.setNeedsDisplay()
    }
}

enum VEGesturePhase { case began, changed, ended }

/// What the gizmo needs about the selected clip.
struct VEGizmoState: Equatable {
    var clipID: String
    var sourceSize: CGSize
    var crop: VECrop
    var transform: VETransform
    var snapping: Bool
    var haptics: Bool
}

final class VEPreviewUIView: UIView {
    let playerLayer = AVPlayerLayer()
    let gizmoLayer = CAShapeLayer()
    let guideLayer = CAShapeLayer()
    var canvasSize = CGSize(width: 1080, height: 1920) { didSet { if canvasSize != oldValue { setNeedsLayout() } } }
    var gizmo: VEGizmoState? { didSet { if gizmo != oldValue { gizmoLayer.setNeedsDisplay(); drawGizmo() } } }
    var onTransform: ((VETransform, VEGesturePhase) -> Void)?
    var onPixelSize: ((CGSize) -> Void)?
    var onTapCanvas: (() -> Void)?

    private var working: VETransform?
    private var lastReportedPixelSize = CGSize.zero
    private var snappedX = false, snappedY = false, snappedRot = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = UIColor.black.cgColor
        layer.addSublayer(playerLayer)
        guideLayer.strokeColor = UIColor.systemYellow.withAlphaComponent(0.9).cgColor
        guideLayer.lineWidth = 1
        guideLayer.fillColor = nil
        layer.addSublayer(guideLayer)
        gizmoLayer.strokeColor = UIColor.white.cgColor
        gizmoLayer.fillColor = nil
        gizmoLayer.lineWidth = 1.5
        gizmoLayer.shadowColor = UIColor.black.cgColor
        gizmoLayer.shadowOpacity = 0.6
        gizmoLayer.shadowRadius = 1
        gizmoLayer.shadowOffset = .zero
        layer.addSublayer(gizmoLayer)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        let rot = UIRotationGestureRecognizer(target: self, action: #selector(handleRotate(_:)))
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        for g in [pan, pinch, rot] as [UIGestureRecognizer] { g.delegate = self; addGestureRecognizer(g) }
        addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Letterboxed video rect in view points.
    var videoRect: CGRect {
        let b = bounds
        guard b.width > 0, b.height > 0, canvasSize.width > 0, canvasSize.height > 0 else { return b }
        let s = min(b.width / canvasSize.width, b.height / canvasSize.height)
        let w = canvasSize.width * s, h = canvasSize.height * s
        return CGRect(x: (b.width - w) / 2, y: (b.height - h) / 2, width: w, height: h)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        gizmoLayer.frame = bounds
        guideLayer.frame = bounds
        CATransaction.commit()
        let px = CGSize(width: (videoRect.width * contentScaleFactor).rounded(), height: (videoRect.height * contentScaleFactor).rounded())
        if px != lastReportedPixelSize, px.width > 0 {
            lastReportedPixelSize = px
            onPixelSize?(px)
        }
        drawGizmo()
    }

    private func toView(_ p: CGPoint) -> CGPoint {
        let r = videoRect
        let s = r.width / max(1, canvasSize.width)
        return CGPoint(x: r.minX + p.x * s, y: r.maxY - p.y * s)
    }

    private func drawGizmo() {
        guard let g = gizmo else { gizmoLayer.path = nil; guideLayer.path = nil; return }
        let t = working ?? g.transform
        let corners = VELayerMath.corners(sourceSize: g.sourceSize, crop: g.crop, canvasSize: canvasSize, transform: t).map(toView)
        let path = UIBezierPath()
        path.move(to: corners[0])
        for c in corners.dropFirst() { path.addLine(to: c) }
        path.close()
        for c in corners {
            path.append(UIBezierPath(ovalIn: CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10)))
        }
        gizmoLayer.path = path.cgPath
        // Guides while a gesture is live.
        let guides = UIBezierPath()
        let r = videoRect
        if working != nil {
            if snappedX { guides.move(to: CGPoint(x: r.midX, y: r.minY)); guides.addLine(to: CGPoint(x: r.midX, y: r.maxY)) }
            if snappedY { guides.move(to: CGPoint(x: r.minX, y: r.midY)); guides.addLine(to: CGPoint(x: r.maxX, y: r.midY)) }
        }
        guideLayer.path = guides.cgPath
    }

    // MARK: Gestures

    @objc private func handleTap(_ g: UITapGestureRecognizer) { onTapCanvas?() }

    private func begin() {
        guard let g = gizmo, working == nil else { return }
        working = g.transform
        snappedX = false; snappedY = false; snappedRot = false
        onTransform?(g.transform, .began)
    }

    private func finish() {
        guard let w = working else { return }
        working = nil
        onTransform?(w, .ended)
        drawGizmo()
    }

    private func report() {
        guard var w = working, let g = gizmo else { return }
        if g.snapping {
            // Centre lines (TL-9): snap within 1.5 % of the canvas, release past 3 %.
            let wasX = snappedX, wasY = snappedY
            if abs(w.x) < 0.015 { w.x = 0; snappedX = true } else if abs(w.x) > 0.03 { snappedX = false }
            if abs(w.y) < 0.015 { w.y = 0; snappedY = true } else if abs(w.y) > 0.03 { snappedY = false }
            // Right angles within 3°.
            let nearest = (w.rotation / 90).rounded() * 90
            let wasRot = snappedRot
            if abs(w.rotation - nearest) < 3 { w.rotation = nearest.truncatingRemainder(dividingBy: 360); snappedRot = true } else { snappedRot = false }
            if g.haptics, (snappedX && !wasX) || (snappedY && !wasY) || (snappedRot && !wasRot) { Haptics.selection() }
        }
        onTransform?(w, .changed)
        drawGizmo()
    }

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        guard gizmo != nil else { return }
        switch g.state {
        case .began: begin()
        case .changed:
            guard working != nil else { return }
            let d = g.translation(in: self)
            g.setTranslation(.zero, in: self)
            let r = videoRect
            working?.x += Double(d.x / max(1, r.width / 2))
            working?.y -= Double(d.y / max(1, r.height / 2))
            if snappedX { working?.x = 0 }
            if snappedY { working?.y = 0 }
            report()
        case .ended, .cancelled, .failed: finish()
        default: break
        }
    }

    @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
        guard gizmo != nil else { return }
        switch g.state {
        case .began: begin()
        case .changed:
            guard let w = working else { return }
            working?.scale = max(0.05, min(10, w.scale * Double(g.scale)))
            g.scale = 1
            report()
        case .ended, .cancelled, .failed: finish()
        default: break
        }
    }

    @objc private func handleRotate(_ g: UIRotationGestureRecognizer) {
        guard gizmo != nil else { return }
        switch g.state {
        case .began: begin()
        case .changed:
            guard let w = working else { return }
            working?.rotation = w.rotation + Double(g.rotation) * 180 / .pi
            g.rotation = 0
            report()
        case .ended, .cancelled, .failed: finish()
        default: break
        }
    }

    // UIView already declares `gestureRecognizerShouldBegin`, hence the override (kept in the class
    // body rather than the delegate extension, where overrides aren't allowed).
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool { gizmo != nil }
}

extension VEPreviewUIView: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}
