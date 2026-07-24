import SwiftUI
import AVFoundation
import UIKit
import CoreImage

/// A video page that behaves like the Photos player: pinch / double-tap to zoom
/// and pan, a simple scrubber, plus a resolution/HDR badge. Swipe up = info,
/// swipe down = dismiss (when not zoomed).
struct VideoPage: View {
    let url: URL
    var coverSource: CoverFrameSource? = nil
    var infoShown: Bool = false
    let onDismiss: () -> Void
    let onInfo: () -> Void
    var onZoomChanged: (Bool) -> Void = { _ in }
    var onControlsHidden: (Bool) -> Void = { _ in }
    var onPrev: () -> Void = {}
    var onNext: () -> Void = {}
    var onCaptured: () -> Void = {}

    @State private var quality: String?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ZoomableVideo(url: url, coverSource: coverSource, infoShown: infoShown,
                          onDismiss: onDismiss, onInfo: onInfo,
                          onZoomChanged: onZoomChanged, onControlsHidden: onControlsHidden,
                          onPrev: onPrev, onNext: onNext, onCaptured: onCaptured)
                .ignoresSafeArea()

            if let quality {
                Text(quality)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 50).padding(.trailing, 12)
            }
        }
        .task(id: url) { quality = await MetadataLoader.videoQuality(url: url) }
    }
}

private struct ZoomableVideo: UIViewControllerRepresentable {
    let url: URL
    var coverSource: CoverFrameSource? = nil
    var infoShown: Bool = false
    let onDismiss: () -> Void
    let onInfo: () -> Void
    let onZoomChanged: (Bool) -> Void
    var onControlsHidden: (Bool) -> Void = { _ in }
    let onPrev: () -> Void
    let onNext: () -> Void
    var onCaptured: () -> Void = {}

    func makeUIViewController(context: Context) -> ZoomableVideoController {
        ZoomableVideoController(url: url)
    }

    func updateUIViewController(_ vc: ZoomableVideoController, context: Context) {
        vc.onDismiss = onDismiss
        vc.onInfo = onInfo
        vc.onZoomChanged = onZoomChanged
        vc.onControlsVisibilityChanged = onControlsHidden
        vc.onPrev = onPrev
        vc.onNext = onNext
        vc.onCaptured = onCaptured
        // Pause playback while the info panel is up: a playing video contends with
        // the metadata read (a second AVAsset on the same file) and the main-queue
        // time observer, which together can wedge the UI. Resume on dismiss.
        vc.setOverlayPaused(infoShown)
        // This page owns the album-cover source while it's visible: grab the
        // current video frame on demand (and its player time, for the HDR re-render).
        coverSource?.staticImage = nil
        coverSource?.liveProvider = { [weak vc] in vc?.currentFrameImage() }
        coverSource?.liveTime = { [weak vc] in vc?.currentPlaybackSeconds() ?? 0 }
    }

    static func dismantleUIViewController(_ vc: ZoomableVideoController, coordinator: ()) {
        vc.teardown()
    }
}

/// Custom AVPlayer view: the player layer lives inside a zoomable scroll view,
/// with a minimal control bar overlaid on top (which does not zoom).
final class ZoomableVideoController: UIViewController, UIScrollViewDelegate {
    var onDismiss: () -> Void = {}
    var onInfo: () -> Void = {}
    var onZoomChanged: (Bool) -> Void = { _ in }
    var onPrev: () -> Void = {}
    var onNext: () -> Void = {}
    var onControlsVisibilityChanged: (Bool) -> Void = { _ in }
    var onCaptured: () -> Void = {}

    /// Player time of the frame `currentFrameImage()` grabs — the cover flow records this so
    /// an HDR re-render can pull the same frame straight from the file.
    func currentPlaybackSeconds() -> Double { player.currentTime().seconds }

    private let player: AVPlayer
    private let playerLayer: AVPlayerLayer
    private let scrollView = UIScrollView()
    private let contentView = UIView()

    private let controlsBar = UIView()
    private let playButton = UIButton(type: .system)
    private let captureButton = UIButton(type: .system)
    private let slider = UISlider()
    private let currentLabel = UILabel()
    private let durationLabel = UILabel()

    private var videoOutput: AVPlayerItemVideoOutput?
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var appeared = false
    private var scrubbing = false
    private var overlayPaused = false
    private var controlsHidden = false
    private var hideWork: DispatchWorkItem?
    private var videoSize = CGSize(width: 16, height: 9)
    private var wasPlayingBeforeScrub = false
    private var isSeeking = false
    private var pendingSeekValue: Float?
    private var captureFlash: UILabel?
    private let url: URL
    private var preferredTransform: CGAffineTransform = .identity

    init(url: URL) {
        self.url = url
        player = AVPlayer(url: url)
        playerLayer = AVPlayerLayer(player: player)
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        scrollView.delegate = self
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 8
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.backgroundColor = .clear
        view.addSubview(scrollView)

        scrollView.addSubview(contentView)
        playerLayer.videoGravity = .resizeAspect
        contentView.layer.addSublayer(playerLayer)

        player.actionAtItemEnd = .none      // loop instead of stopping at the end
        NotificationCenter.default.addObserver(
            self, selector: #selector(playerDidReachEnd),
            name: .AVPlayerItemDidPlayToEndTime, object: player.currentItem)
        // Output for capturing the current frame (native format preserves HDR).
        let output = AVPlayerItemVideoOutput(outputSettings: nil)
        player.currentItem?.add(output)
        videoOutput = output

        // Load the video's orientation so captured frames aren't sideways.
        Task { [weak self] in
            guard let asset = self?.player.currentItem?.asset,
                  let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let t = try? await track.load(.preferredTransform) else { return }
            await MainActor.run { self?.preferredTransform = t }
        }
        if let item = player.currentItem {
            statusObservation = item.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
                guard let self, item.status == .readyToPlay else { return }
                if item.presentationSize != .zero { self.videoSize = item.presentationSize }
                self.view.setNeedsLayout()
                self.updateDuration()
                self.playIfNeeded()
            }
        }

        setupControls()
        setupGestures()

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] t in
            self?.updateProgress(t)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        scrollView.frame = view.bounds
        if scrollView.zoomScale == 1 {
            let fit = AVMakeRect(aspectRatio: videoSize, insideRect: view.bounds)
            contentView.frame = fit
            playerLayer.frame = contentView.bounds
            scrollView.contentSize = fit.size
        }
        layoutControls()
    }

    // MARK: - Zoom

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { contentView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        // Frame-based centering (matches the image viewer) so zooming back to 1×
        // returns the video to its correct, centered aspect-fit position.
        let bounds = scrollView.bounds.size
        let content = contentView.frame.size
        let x = max(0, (bounds.width - content.width) / 2)
        let y = max(0, (bounds.height - content.height) / 2)
        contentView.center = CGPoint(x: content.width / 2 + x, y: content.height / 2 + y)
        onZoomChanged(scrollView.zoomScale > scrollView.minimumZoomScale + 0.001)
    }

    // MARK: - Controls

    private func setupControls() {
        controlsBar.backgroundColor = UIColor.black.withAlphaComponent(0.4)
        controlsBar.layer.cornerRadius = 14
        view.addSubview(controlsBar)

        playButton.tintColor = .white
        playButton.setImage(UIImage(systemName: "pause.fill"), for: .normal)
        playButton.addTarget(self, action: #selector(togglePlay), for: .touchUpInside)
        controlsBar.addSubview(playButton)

        for label in [currentLabel, durationLabel] {
            label.textColor = .white
            label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            label.textAlignment = .center
            label.text = "0:00"
            controlsBar.addSubview(label)
        }

        slider.minimumTrackTintColor = .white
        // Slightly smaller thumb than the default.
        let thumb = UIGraphicsImageRenderer(size: CGSize(width: 22, height: 22)).image { _ in
            UIColor.white.setFill()
            UIBezierPath(ovalIn: CGRect(x: 1, y: 1, width: 20, height: 20)).fill()
        }
        slider.setThumbImage(thumb, for: .normal)
        slider.setThumbImage(thumb, for: .highlighted)
        slider.addTarget(self, action: #selector(sliderChanged), for: .valueChanged)
        slider.addTarget(self, action: #selector(sliderDown), for: .touchDown)
        slider.addTarget(self, action: #selector(sliderUp), for: [.touchUpInside, .touchUpOutside])
        controlsBar.addSubview(slider)

        captureButton.tintColor = .white
        captureButton.setImage(UIImage(systemName: "camera.fill"), for: .normal)
        captureButton.addTarget(self, action: #selector(captureFrame), for: .touchUpInside)
        controlsBar.addSubview(captureButton)
    }

    private func layoutControls() {
        let h: CGFloat = 44
        let margin: CGFloat = 16
        let bottomInset = view.safeAreaInsets.bottom
        controlsBar.frame = CGRect(x: margin,
                                   y: view.bounds.height - bottomInset - h - 12,
                                   width: view.bounds.width - margin * 2, height: h)
        let curW: CGFloat = 66   // wider to fit milliseconds while scrubbing
        let durW: CGFloat = 46
        let camW: CGFloat = 40
        playButton.frame = CGRect(x: 6, y: 0, width: 40, height: h)
        currentLabel.frame = CGRect(x: playButton.frame.maxX + 2, y: 0, width: curW, height: h)
        captureButton.frame = CGRect(x: controlsBar.bounds.width - camW - 6, y: 0, width: camW, height: h)
        durationLabel.frame = CGRect(x: captureButton.frame.minX - durW - 2, y: 0, width: durW, height: h)
        slider.frame = CGRect(x: currentLabel.frame.maxX + 4, y: 0,
                              width: durationLabel.frame.minX - currentLabel.frame.maxX - 8, height: h)
    }

    // MARK: - Gestures

    private func setupGestures() {
        let single = UITapGestureRecognizer(target: self, action: #selector(toggleControls))
        let double = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        double.numberOfTapsRequired = 2
        single.require(toFail: double)
        scrollView.addGestureRecognizer(single)
        scrollView.addGestureRecognizer(double)

        for (dir, sel) in [(UISwipeGestureRecognizer.Direction.up,    #selector(swipeUp)),
                           (.down,  #selector(swipeDown)),
                           (.left,  #selector(swipeLeft)),
                           (.right, #selector(swipeRight))] {
            let g = UISwipeGestureRecognizer(target: self, action: sel)
            g.direction = dir
            scrollView.addGestureRecognizer(g)
        }
    }

    private var atRest: Bool { scrollView.zoomScale <= 1.001 }
    @objc private func swipeUp()    { if atRest { onInfo() } }
    @objc private func swipeDown()  { if atRest { onDismiss() } }
    @objc private func swipeLeft()  { if atRest { onNext() } }
    @objc private func swipeRight() { if atRest { onPrev() } }

    /// Three-stage double-tap: fit → fill the screen → a bit more → back to fit.
    @objc private func handleDoubleTap(_ g: UITapGestureRecognizer) {
        let loc = g.location(in: view)
        let x = loc.x
        let w = view.bounds.width
        // Lower-LEFT corner → step back a frame; lower-RIGHT corner → step forward.
        // The lower-MIDDLE is intentionally excluded (it falls through to the zoom
        // logic) so a double-tap near the center/scrubber doesn't nudge frames.
        if loc.y > view.bounds.height * 2 / 3 {
            if x < w / 3 { stepFrame(by: -1); return }
            if x > w * 2 / 3 { stepFrame(by: 1); return }
        }
        // Left third → back 15s, right third → forward 15s, center column → zoom.
        if x < w / 3 { skip(by: -15); return }
        if x > w * 2 / 3 { skip(by: 15); return }

        let fitRect = AVMakeRect(aspectRatio: videoSize, insideRect: view.bounds)
        let fill = max(view.bounds.width / max(fitRect.width, 1),
                       view.bounds.height / max(fitRect.height, 1))
        let more = fill * 1.5
        let s = scrollView.zoomScale
        let p = g.location(in: contentView)
        if s < fill - 0.02 {
            zoomVideo(to: fill, at: p)
        } else if s < more - 0.02 {
            zoomVideo(to: more, at: p)
        } else {
            scrollView.setZoomScale(1, animated: true)
        }
    }

    /// Seeks `seconds` forward/back (clamped to the video's bounds) with a brief flash.
    private func skip(by seconds: Double) {
        guard let item = player.currentItem else { return }
        let dur = item.duration.seconds
        var target = player.currentTime().seconds + seconds
        if target < 0 { target = 0 }
        if dur.isFinite, dur > 0, target > dur { target = dur }
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        flashCapture(seconds < 0 ? "⟲ 15s" : "15s ⟳")
        if !controlsHidden { scheduleHide() }
    }

    /// Steps the video one frame forward (count > 0) or back (count < 0).
    /// Frame-stepping implies paused playback, so it pauses first.
    private func stepFrame(by count: Int) {
        guard let item = player.currentItem else { return }
        if player.timeControlStatus == .playing {
            player.pause()
            playButton.setImage(UIImage(systemName: "play.fill"), for: .normal)
        }
        let canStep = count < 0 ? item.canStepBackward : item.canStepForward
        guard canStep else { return }
        item.step(byCount: count)
        flashCapture(count < 0 ? "◀ Frame" : "Frame ▶")
        if !controlsHidden { scheduleHide() }
    }

    private func zoomVideo(to scale: CGFloat, at p: CGPoint) {
        let w = scrollView.bounds.width / scale
        let h = scrollView.bounds.height / scale
        scrollView.zoom(to: CGRect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h), animated: true)
    }

    @objc private func toggleControls() { setControls(hidden: !controlsHidden) }

    private func setControls(hidden: Bool) {
        controlsHidden = hidden
        onControlsVisibilityChanged(hidden)        // also hides the viewer's close button
        UIView.animate(withDuration: 0.2) { self.controlsBar.alpha = hidden ? 0 : 1 }
        if !hidden { scheduleHide() }
    }

    private func scheduleHide() {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.setControls(hidden: true) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5, execute: work)
    }

    // MARK: - Frame capture

    /// The current playback frame as an upright UIImage (for the album cover).
    func currentFrameImage() -> UIImage? {
        guard let output = videoOutput,
              let pb = output.copyPixelBuffer(forItemTime: player.currentTime(), itemTimeForDisplay: nil) else {
            return nil
        }
        var ci = CIImage(cvImageBuffer: pb)
        if !preferredTransform.isIdentity {
            var t = preferredTransform
            t.b = -t.b; t.c = -t.c                      // CIImage is Y-up; conjugate the rotation
            ci = ci.transformed(by: t)
            ci = ci.transformed(by: CGAffineTransform(translationX: -ci.extent.origin.x,
                                                      y: -ci.extent.origin.y))
        }
        let context = CIContext()
        guard let cg = context.createCGImage(ci, from: ci.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    @objc private func captureFrame() {
        let time = player.currentTime()
        // Save into a "Screenshots" folder beside the video (created on first use)
        // rather than the iOS Photos library.
        guard let folder = FileActions.screenshotsFolder(beside: url) else {
            flashCapture("Couldn’t save"); return
        }
        let fileURL = url
        if let output = videoOutput,
           let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
            flashCapture("Saving…")
            let transform = preferredTransform
            Task {
                let props = await MetadataLoader.exifProperties(forVideo: fileURL)
                let saved = FileActions.saveFrame(buffer, transform: transform, properties: props, in: folder)
                await MainActor.run { self.finishCapture(saved) }
            }
        } else if let asset = player.currentItem?.asset {
            flashCapture("Saving…")
            Task {
                let props = await MetadataLoader.exifProperties(forVideo: fileURL)
                let saved = await Self.saveViaGenerator(asset: asset, at: time, props: props, in: folder)
                await MainActor.run { self.finishCapture(saved) }
            }
        }
    }

    private func finishCapture(_ saved: URL?) {
        flashCapture(saved != nil ? "Saved to Screenshots" : "Couldn’t save")
        if saved != nil { onCaptured() }   // refresh the folder grid so it appears
    }

    /// SDR fallback when no decoded pixel buffer is available.
    private static func saveViaGenerator(asset: AVAsset, at time: CMTime,
                                         props: [String: Any], in folder: URL) async -> URL? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        guard let cg = try? await generator.image(at: time).image else { return nil }
        return FileActions.saveFrame(cgImage: cg, properties: props, in: folder)
    }

    private func flashCapture(_ text: String) {
        captureFlash?.removeFromSuperview()
        let label = UILabel()
        label.text = "  \(text)  "
        label.textColor = .white
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        label.layer.cornerRadius = 10
        label.layer.masksToBounds = true
        label.textAlignment = .center
        label.alpha = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.heightAnchor.constraint(equalToConstant: 38)
        ])
        captureFlash = label
        UIView.animate(withDuration: 0.2, animations: { label.alpha = 1 }) { _ in
            UIView.animate(withDuration: 0.4, delay: 1.0, options: []) {
                label.alpha = 0
            } completion: { _ in label.removeFromSuperview() }
        }
    }

    // MARK: - Playback

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        appeared = true
        playIfNeeded()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        appeared = false
        player.pause()
        player.seek(to: .zero)
    }

    private func playIfNeeded() {
        guard appeared, !overlayPaused, player.currentItem?.status == .readyToPlay else { return }
        player.play()
        playButton.setImage(UIImage(systemName: "pause.fill"), for: .normal)
        scheduleHide()
    }

    /// Pauses (and later resumes) playback while an overlay like the info panel is
    /// shown, so the player doesn't fight the metadata read for media services.
    func setOverlayPaused(_ paused: Bool) {
        guard paused != overlayPaused else { return }
        overlayPaused = paused
        if paused {
            player.pause()
            playButton.setImage(UIImage(systemName: "play.fill"), for: .normal)
            hideWork?.cancel()
        } else if appeared {
            playIfNeeded()
        }
    }

    /// Loop: jump back to the start and keep playing when the video ends.
    @objc private func playerDidReachEnd() {
        player.seek(to: .zero)
        if appeared { player.play() }
    }

    @objc private func togglePlay() {
        if player.timeControlStatus == .playing {
            player.pause()
            playButton.setImage(UIImage(systemName: "play.fill"), for: .normal)
            hideWork?.cancel()
        } else {
            player.play()
            playButton.setImage(UIImage(systemName: "pause.fill"), for: .normal)
            scheduleHide()
        }
    }

    @objc private func sliderDown() {
        scrubbing = true
        wasPlayingBeforeScrub = (player.timeControlStatus == .playing)
        player.pause()
        hideWork?.cancel()
    }

    @objc private func sliderChanged() {
        currentLabel.text = Self.fmt(Double(slider.value), ms: true)   // show milliseconds while scrubbing
        smoothSeek(to: slider.value)          // live, frame-accurate preview while dragging
    }

    @objc private func sliderUp() {
        scrubbing = false
        let final = CMTime(seconds: Double(slider.value), preferredTimescale: 600)
        player.seek(to: final, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            if self?.wasPlayingBeforeScrub == true { self?.player.play() }
        }
        scheduleHide()
    }

    /// Coalesced zero-tolerance seeking: only one seek runs at a time, always to
    /// the latest requested position — smooth and accurate, like Photos.
    private func smoothSeek(to seconds: Float) {
        pendingSeekValue = seconds
        guard !isSeeking else { return }
        seekToPending()
    }

    private func seekToPending() {
        guard let value = pendingSeekValue else { isSeeking = false; return }
        pendingSeekValue = nil
        isSeeking = true
        player.seek(to: CMTime(seconds: Double(value), preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            self?.seekToPending()
        }
    }

    private func updateProgress(_ t: CMTime) {
        guard !scrubbing else { return }
        if let dur = player.currentItem?.duration.seconds, dur.isFinite, dur > 0 {
            slider.maximumValue = Float(dur)
        }
        slider.value = Float(t.seconds)
        currentLabel.text = Self.fmt(t.seconds)
    }

    private func updateDuration() {
        if let dur = player.currentItem?.duration.seconds, dur.isFinite, dur > 0 {
            slider.maximumValue = Float(dur)
            durationLabel.text = Self.fmt(dur)
        }
    }

    func teardown() {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        statusObservation?.invalidate(); statusObservation = nil
        NotificationCenter.default.removeObserver(self, name: .AVPlayerItemDidPlayToEndTime, object: player.currentItem)
        player.pause()
    }

    private static func fmt(_ s: Double, ms: Bool = false) -> String {
        guard s.isFinite, s >= 0 else { return ms ? "0:00.000" : "0:00" }
        let total = Int(s)
        let m = total / 60, sec = total % 60
        if ms {
            let millis = Int((s - Double(total)) * 1000)
            return String(format: "%d:%02d.%03d", m, sec, millis)
        }
        return String(format: "%d:%02d", m, sec)
    }
}
