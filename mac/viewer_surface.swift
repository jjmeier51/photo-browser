// The viewer's picture for Safe Finder (mac/viewer_surface.py, mac/media_viewer.py), drawn by macOS itself.
//
// Qt draws video with its own decoder (FFmpeg since Qt 6.5) and its own HDR → standard-range curve, so an HDR
// video came out brighter and harsher than in QuickTime Player, and Qt shows an HDR photo's standard-range
// picture only. Here the picture is drawn the way QuickTime Player and Preview draw it:
//
//   - a video by AVFoundation (AVPlayer into an AVPlayerLayer, QuickTime's own player): HDR in HDR on a
//     display that has the headroom (EDR), tone-mapped by the system on one that hasn't, colour-managed;
//   - an HDR photo by Core Image (the gain map applied — the iPhone's or the ISO one — or the HLG/PQ curve
//     read) into an extended-range picture, shown by an NSImageView allowed HDR (AppKit's own HDR path,
//     which tone-maps it on a display without the headroom).
//
// Built with `swiftc -emit-library` into ~/Library/Caches/PhotoBrowser/ and loaded into Safe Finder with
// ctypes. It's a plain C interface (`pbv_*`): Python makes the surface inside a Qt widget's own NSView (its
// `winId()`), says which file to show and where the picture goes (`pbv_set_rect` — Qt keeps fit, zoom and
// pan), and asks how playback is going on a timer. Every click passes through to Qt (`hitTest` → nil), so
// the viewer's taps, drags and gestures are Qt's as before. Everything runs on the main thread (Qt's), except
// decoding a photo, which happens on a background queue.
import AppKit
import AVFoundation
import CoreImage

private let renderContext = CIContext(options: [.cacheIntermediates: false])

// What `pbv_state` answers.
private let stateNothing: Int32 = 0
private let stateLoading: Int32 = 1
private let stateReady: Int32 = 2
private let stateFailed: Int32 = 3

/// A view that's only there to be seen: clicks, drags and gestures go to the view under it (Qt's).
final class PassThroughView: NSView {
    override var isFlipped: Bool { true }       // top-left origin, like Qt's coordinates
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A view whose own layer is the player's.
final class PlayerView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { return nil }

    override func makeBackingLayer() -> CALayer { playerLayer }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The photo, stretched to the view (which is placed where the photo goes). AppKit draws it in HDR — on a
/// display without the headroom, tone-mapped as Preview does — once it's told it may (`allowHDR`).
final class PictureView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func allowHDR() {
        // preferredImageDynamicRange = .high (macOS 14+), asked by name so this builds with any SDK; on an
        // older macOS the photo is shown in standard range.
        if responds(to: NSSelectorFromString("setPreferredImageDynamicRange:")) {
            setValue(2, forKey: "preferredImageDynamicRange")       // NSImageDynamicRangeHigh
        }
    }
}

/// An HDR photo as an extended-range picture: the gain map applied (macOS 14+), turned upright, scaled down to
/// at most `maxPixels` (0: as it is). nil when Core Image can't read it.
func hdrPicture(_ url: URL, maxPixels: Int) -> CGImage? {
    var options: [CIImageOption: Any] = [.applyOrientationProperty: true]
    if #available(macOS 14.0, *) {
        options[.expandToHDR] = true
    }
    guard var image = CIImage(contentsOf: url, options: options) else { return nil }
    let extent = image.extent
    guard extent.width >= 1, extent.height >= 1, extent.width.isFinite, extent.height.isFinite else { return nil }
    let pixels = Double(extent.width) * Double(extent.height)
    if maxPixels > 0, pixels > Double(maxPixels), let lanczos = CIFilter(name: "CILanczosScaleTransform") {
        lanczos.setValue(image, forKey: kCIInputImageKey)
        lanczos.setValue(sqrt(Double(maxPixels) / pixels), forKey: kCIInputScaleKey)
        lanczos.setValue(1.0, forKey: kCIInputAspectRatioKey)
        if let out = lanczos.outputImage { image = out }
    }
    let rect = image.extent.integral
    guard rect.width >= 1, rect.height >= 1,
          let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) else { return nil }
    return renderContext.createCGImage(image, from: rect, format: .RGBAh, colorSpace: space)
}

@MainActor
final class Surface {
    let root: PassThroughView
    let playerView: PlayerView
    let pictureView: PictureView
    let player: AVPlayer
    var showing = 0                       // 0 nothing, 1 a video, 2 a photo
    var pictureState = stateNothing
    var pictureSize = CGSize.zero
    var token = 0                         // the photo being read: a late one for another photo is dropped
    var loop = true
    var ended = false
    var rate: Float = 1
    var seeking = false
    var seekGeneration = 0                // bumped when the video changes: a late seek's end is ignored
    var pendingSeek: CMTime?
    var endObserver: NSObjectProtocol?

    init(host: NSView) {
        root = PassThroughView(frame: host.bounds)
        playerView = PlayerView(frame: .zero)
        pictureView = PictureView(frame: .zero)
        player = AVPlayer()
        root.autoresizingMask = [.width, .height]
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.black.cgColor
        root.layer?.masksToBounds = true
        playerView.playerLayer.player = player
        playerView.playerLayer.videoGravity = .resizeAspect
        playerView.playerLayer.backgroundColor = NSColor.black.cgColor
        playerView.isHidden = true
        pictureView.imageScaling = .scaleAxesIndependently
        pictureView.imageFrameStyle = .none
        pictureView.isEditable = false
        pictureView.animates = false
        pictureView.allowHDR()
        pictureView.isHidden = true
        root.addSubview(playerView)
        root.addSubview(pictureView)
        player.actionAtItemEnd = .pause
        host.addSubview(root)
    }

    func layout() {
        if let host = root.superview { root.frame = host.bounds }
    }

    /// Where the picture goes, in the host's points from its top left.
    func place(_ rect: NSRect) {
        playerView.frame = rect
        pictureView.frame = rect
    }

    func clear() {
        if let observer = endObserver {
            NotificationCenter.default.removeObserver(observer)
            endObserver = nil
        }
        player.pause()
        if player.currentItem != nil { player.replaceCurrentItem(with: nil) }
        token += 1
        pictureView.image = nil
        pictureState = stateNothing
        pictureSize = .zero
        playerView.isHidden = true
        pictureView.isHidden = true
        showing = 0
        ended = false
        pendingSeek = nil
        seeking = false
        seekGeneration += 1
        rate = 1
    }

    func destroy() {
        clear()
        root.removeFromSuperview()
    }

    // MARK: video

    func openVideo(_ url: URL) {
        clear()
        showing = 1
        let item = AVPlayerItem(url: url)
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item,
                                                             queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.itemEnded() }
        }
        player.replaceCurrentItem(with: item)
        playerView.isHidden = false
    }

    func itemEnded() {
        guard showing == 1 else { return }
        if loop {
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            player.rate = rate
        } else {
            ended = true
        }
    }

    var state: Int32 {
        switch showing {
        case 1:
            guard let item = player.currentItem else { return stateNothing }
            switch item.status {
            case .readyToPlay: return stateReady
            case .failed: return stateFailed
            default: return stateLoading
            }
        case 2:
            return pictureState
        default:
            return stateNothing
        }
    }

    func play() {
        guard showing == 1, let item = player.currentItem else { return }
        let duration = item.duration
        if duration.isNumeric, duration.seconds > 0, player.currentTime().seconds >= duration.seconds - 0.05 {
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        ended = false
        player.rate = rate
    }

    func pause() {
        player.pause()
    }

    var isPlaying: Bool { showing == 1 && player.rate != 0 }

    func setRate(_ value: Float) {
        rate = value > 0 ? value : 1
        if isPlaying { player.rate = rate }
    }

    /// Exact seeks, one at a time: while one is under way the latest target waits, so dragging the scrubber
    /// follows the pointer instead of queueing up every position it passed.
    func seek(_ seconds: Double) {
        guard showing == 1, player.currentItem != nil, seconds.isFinite else { return }
        pendingSeek = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        ended = false
        if !seeking { nextSeek() }
    }

    func nextSeek() {
        guard let target = pendingSeek else {
            seeking = false
            return
        }
        pendingSeek = nil
        seeking = true
        let generation = seekGeneration
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if generation == self.seekGeneration { self.nextSeek() }
                }
            }
        }
    }

    /// One frame back or on — paused first (the iPhone's frame step).
    func step(_ frames: Int) {
        guard showing == 1, let item = player.currentItem, frames != 0 else { return }
        player.pause()
        if frames > 0 ? item.canStepForward : item.canStepBackward {
            item.step(byCount: frames)
        }
    }

    var position: Double {
        let t = player.currentTime().seconds
        return t.isFinite ? max(0, t) : 0
    }

    var duration: Double {
        guard let d = player.currentItem?.duration, d.isNumeric else { return 0 }
        let s = d.seconds
        return s.isFinite ? max(0, s) : 0
    }

    var videoSize: CGSize { player.currentItem?.presentationSize ?? .zero }

    // MARK: photo

    func openPicture(_ url: URL, maxPixels: Int) {
        clear()
        showing = 2
        pictureState = stateLoading
        let mine = token
        DispatchQueue.global(qos: .userInitiated).async {
            let picture = hdrPicture(url, maxPixels: maxPixels)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.pictureRead(picture, token: mine) }
            }
        }
    }

    func pictureRead(_ picture: CGImage?, token mine: Int) {
        guard mine == token, showing == 2 else { return }
        guard let picture = picture else {
            pictureState = stateFailed
            return
        }
        let size = NSSize(width: picture.width, height: picture.height)
        pictureView.image = NSImage(cgImage: picture, size: size)
        pictureSize = size
        pictureView.isHidden = false
        pictureState = stateReady
    }
}

// MARK: the C interface — every call from Qt's (the main) thread

private func withSurface<T>(_ handle: UnsafeMutableRawPointer?, _ otherwise: T,
                            _ body: @MainActor (Surface) -> T) -> T where T: Sendable {
    guard let handle = handle else { return otherwise }
    let address = Int(bitPattern: handle)
    return MainActor.assumeIsolated {
        guard let pointer = UnsafeMutableRawPointer(bitPattern: address) else { return otherwise }
        return body(Unmanaged<Surface>.fromOpaque(pointer).takeUnretainedValue())
    }
}

/// A surface filling `host` (an NSView — a Qt widget's `winId()`), or NULL.
@_cdecl("pbv_create")
public func pbv_create(_ host: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? {
    guard let host = host else { return nil }
    let address = Int(bitPattern: host)
    let made: Int = MainActor.assumeIsolated {
        guard let pointer = UnsafeMutableRawPointer(bitPattern: address) else { return 0 }
        let view = Unmanaged<NSView>.fromOpaque(pointer).takeUnretainedValue()
        let surface = Surface(host: view)
        return Int(bitPattern: Unmanaged.passRetained(surface).toOpaque())
    }
    return UnsafeMutableRawPointer(bitPattern: made)
}

@_cdecl("pbv_destroy")
public func pbv_destroy(_ handle: UnsafeMutableRawPointer?) {
    guard let handle = handle else { return }
    let address = Int(bitPattern: handle)
    MainActor.assumeIsolated {
        guard let pointer = UnsafeMutableRawPointer(bitPattern: address) else { return }
        let surface = Unmanaged<Surface>.fromOpaque(pointer)
        surface.takeUnretainedValue().destroy()
        surface.release()
    }
}

@_cdecl("pbv_layout")
public func pbv_layout(_ handle: UnsafeMutableRawPointer?) {
    withSurface(handle, ()) { $0.layout() }
}

@_cdecl("pbv_set_rect")
public func pbv_set_rect(_ handle: UnsafeMutableRawPointer?, _ x: Double, _ y: Double, _ w: Double, _ h: Double) {
    withSurface(handle, ()) { $0.place(NSRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(max(0, w)), height: CGFloat(max(0, h)))) }
}

@_cdecl("pbv_clear")
public func pbv_clear(_ handle: UnsafeMutableRawPointer?) {
    withSurface(handle, ()) { $0.clear() }
}

/// 0 nothing shown, 1 loading, 2 ready, 3 failed (macOS can't play or read it).
@_cdecl("pbv_state")
public func pbv_state(_ handle: UnsafeMutableRawPointer?) -> Int32 {
    withSurface(handle, stateNothing) { $0.state }
}

@_cdecl("pbv_open_video")
public func pbv_open_video(_ handle: UnsafeMutableRawPointer?, _ path: UnsafePointer<CChar>?) {
    guard let path = path else { return }
    let url = URL(fileURLWithPath: String(cString: path))
    withSurface(handle, ()) { $0.openVideo(url) }
}

@_cdecl("pbv_open_image")
public func pbv_open_image(_ handle: UnsafeMutableRawPointer?, _ path: UnsafePointer<CChar>?, _ maxPixels: Int64) {
    guard let path = path else { return }
    let url = URL(fileURLWithPath: String(cString: path))
    let limit = Int(clamping: maxPixels)
    withSurface(handle, ()) { $0.openPicture(url, maxPixels: limit) }
}

@_cdecl("pbv_play")
public func pbv_play(_ handle: UnsafeMutableRawPointer?) {
    withSurface(handle, ()) { $0.play() }
}

@_cdecl("pbv_pause")
public func pbv_pause(_ handle: UnsafeMutableRawPointer?) {
    withSurface(handle, ()) { $0.pause() }
}

@_cdecl("pbv_is_playing")
public func pbv_is_playing(_ handle: UnsafeMutableRawPointer?) -> Int32 {
    withSurface(handle, Int32(0)) { $0.isPlaying ? 1 : 0 }
}

@_cdecl("pbv_set_rate")
public func pbv_set_rate(_ handle: UnsafeMutableRawPointer?, _ rate: Double) {
    withSurface(handle, ()) { $0.setRate(Float(rate)) }
}

@_cdecl("pbv_seek")
public func pbv_seek(_ handle: UnsafeMutableRawPointer?, _ seconds: Double) {
    withSurface(handle, ()) { $0.seek(seconds) }
}

@_cdecl("pbv_step")
public func pbv_step(_ handle: UnsafeMutableRawPointer?, _ frames: Int32) {
    withSurface(handle, ()) { $0.step(Int(frames)) }
}

@_cdecl("pbv_position")
public func pbv_position(_ handle: UnsafeMutableRawPointer?) -> Double {
    withSurface(handle, 0.0) { $0.position }
}

@_cdecl("pbv_duration")
public func pbv_duration(_ handle: UnsafeMutableRawPointer?) -> Double {
    withSurface(handle, 0.0) { $0.duration }
}

@_cdecl("pbv_set_loop")
public func pbv_set_loop(_ handle: UnsafeMutableRawPointer?, _ on: Int32) {
    withSurface(handle, ()) { $0.loop = on != 0 }
}

/// 1 once when the video has played to its end (and isn't looping).
@_cdecl("pbv_take_ended")
public func pbv_take_ended(_ handle: UnsafeMutableRawPointer?) -> Int32 {
    withSurface(handle, Int32(0)) { surface in
        let ended = surface.ended
        surface.ended = false
        return ended ? 1 : 0
    }
}

@_cdecl("pbv_set_muted")
public func pbv_set_muted(_ handle: UnsafeMutableRawPointer?, _ on: Int32) {
    withSurface(handle, ()) { $0.player.isMuted = on != 0 }
}

/// The picture's size in pixels as shown (a video's once it's loaded, a photo's as read); 0 × 0 until known.
@_cdecl("pbv_content_size")
public func pbv_content_size(_ handle: UnsafeMutableRawPointer?, _ width: UnsafeMutablePointer<Double>?,
                             _ height: UnsafeMutablePointer<Double>?) {
    let w = withSurface(handle, 0.0) { Double($0.showing == 2 ? $0.pictureSize.width : $0.videoSize.width) }
    let h = withSurface(handle, 0.0) { Double($0.showing == 2 ? $0.pictureSize.height : $0.videoSize.height) }
    width?.pointee = w
    height?.pointee = h
}
