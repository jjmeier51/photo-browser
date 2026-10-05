import SwiftUI
import UIKit

// MARK: - Model handed to the timeline

struct VETimelineClipModel: Equatable, Identifiable {
    var id: String
    var mediaID: String
    var kind: VEClipKind
    var start: VETime
    var duration: VETime
    var sourceStart: VETime
    var sourceDuration: VETime          // 0 = unbounded (stills, freezes)
    var rate: Double
    var reversed: Bool
    var muted: Bool
    var hasAudio: Bool
    var name: String
    var aspect: CGFloat
    var missing: Bool
}

struct VETimelineModel: Equatable {
    var clips: [VETimelineClipModel] = []
    var duration: VETime = 0
    var frameRate: Int = 30
    var selectedID: String?
    var snapping = true
    var haptics = true
}

enum VETrimSide { case left, right }

@MainActor protocol VETimelineDelegate: AnyObject {
    func timelineDidScrub(to time: VETime, final: Bool)
    func timelineDidSelect(_ clipID: String?)
    /// `delta` is timeline time; left handle: start moves by delta (duration shrinks); right handle: duration grows by delta.
    func timelineTrim(_ clipID: String, side: VETrimSide, delta: VETime, phase: VEGesturePhase)
    func timelineReorder(from: Int, to: Int)
    func timelineAdd(atPlayhead: Bool)
    func timelineCover()
    func timelineCut(at index: Int)
}

/// Thumbnail frames and waveform peaks for clip views; the editor's store implements it over the
/// package's `thumbs/` and `waveforms/` caches.
@MainActor protocol VEThumbProviding: AnyObject {
    func frame(mediaID: String, sourceTime: VETime) -> UIImage?
    func waveform(mediaID: String) -> (peaks: [(Float, Float)], intervalMs: Int)?
}

// MARK: - SwiftUI wrapper

struct VETimeline: UIViewRepresentable {
    var model: VETimelineModel
    var playhead: VETime
    var isPlaying: Bool
    /// Bumped by the thumbnail store when a strip lands; clip views redraw without a relayout.
    var thumbsRevision: Int
    weak var provider: VEThumbProviding?
    weak var delegate: VETimelineDelegate?

    func makeUIView(context: Context) -> VETimelineView {
        let v = VETimelineView()
        v.provider = provider
        v.delegate = delegate
        return v
    }

    func updateUIView(_ v: VETimelineView, context: Context) {
        v.provider = provider
        v.delegate = delegate
        v.apply(model)
        v.setPlayhead(playhead, following: isPlaying)
        v.redrawClips(ifRevisionChanged: thumbsRevision)
    }
}

// MARK: - Timeline view

/// CapCut-style strip under a fixed centre playhead (TL-1): the content scrolls beneath it, pinch
/// zooms between one minute per screen and 20 pt per frame, clip handles trim with ripple, a
/// long-press lifts a clip to reorder, and edges snap to the playhead and to other clips with a
/// haptic tick.
final class VETimelineView: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    weak var provider: VEThumbProviding? { didSet { clipViews.values.forEach { $0.provider = provider } } }
    weak var delegate: VETimelineDelegate?

    static let rulerHeight: CGFloat = 18
    static let mainRowHeight: CGFloat = 58
    static let tileWidth: CGFloat = 44
    static let handleWidth: CGFloat = 16
    static let snapDistance: CGFloat = 8
    static let snapRelease: CGFloat = 16

    private let scrollView = UIScrollView()
    private let contentView = UIView()
    private let rulerView = VERulerView()
    private let playheadView = UIView()
    private let coverTile = VETileView(symbol: "photo", title: "Cover")
    private let addTile = VETileView(symbol: "plus", title: nil)
    private var clipViews: [String: VEClipView] = [:]
    private var cutViews: [UIView] = []
    private var model = VETimelineModel()
    private var playhead: VETime = 0
    private(set) var pointsPerSecond: CGFloat = 60
    private var programmaticScroll = false
    private var userScrolling = false
    private var zoomAnchorTime: VETime = 0

    // Trim / reorder state
    private var trimming: (id: String, side: VETrimSide, startX: CGFloat, accumulated: VETime, snapped: Bool)?
    private var lifting: (id: String, index: Int, offsetX: CGFloat, dropIndex: Int)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 0.08, alpha: 1)
        scrollView.delegate = self
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        scrollView.decelerationRate = .fast
        scrollView.delaysContentTouches = false
        scrollView.addSubview(contentView)
        addSubview(scrollView)
        contentView.addSubview(rulerView)
        contentView.addSubview(coverTile)
        contentView.addSubview(addTile)
        coverTile.addTarget(self, action: #selector(coverTapped), for: .touchUpInside)
        addTile.addTarget(self, action: #selector(addTapped), for: .touchUpInside)
        addTile.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(addLongPressed(_:))))
        playheadView.backgroundColor = .white
        playheadView.layer.cornerRadius = 1
        playheadView.isUserInteractionEnabled = false
        addSubview(playheadView)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        scrollView.addGestureRecognizer(pinch)
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleBackgroundTap(_:)))
        tap.delegate = self
        scrollView.addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Layout

    private var sidePadding: CGFloat { bounds.width / 2 }
    private func x(for t: VETime) -> CGFloat { sidePadding + CGFloat(VETimeUtil.seconds(t)) * pointsPerSecond }
    private func time(for x: CGFloat) -> VETime { VETimeUtil.fromSeconds(Double((x - sidePadding) / pointsPerSecond)) }

    private var minPPS: CGFloat { max(2, bounds.width / 60) }                      // 1 min per screen width
    private var maxPPS: CGFloat { 20 * CGFloat(max(1, model.frameRate)) }        // 20 pt per frame

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        playheadView.frame = CGRect(x: bounds.midX - 1, y: 0, width: 2, height: bounds.height)
        pointsPerSecond = max(minPPS, min(maxPPS, pointsPerSecond))
        layoutContent()
        scrollToPlayhead(animated: false)
    }

    func apply(_ newModel: VETimelineModel) {
        let selectionChanged = newModel.selectedID != model.selectedID
        let clipsChanged = newModel.clips != model.clips || newModel.frameRate != model.frameRate
        model = newModel
        if clipsChanged || selectionChanged { layoutContent() }
        if selectionChanged { for (id, v) in clipViews { v.isSelected = id == model.selectedID } }
    }

    private func layoutContent() {
        let totalWidth = x(for: model.duration) + Self.tileWidth + 8 + sidePadding
        contentView.frame = CGRect(x: 0, y: 0, width: totalWidth, height: bounds.height)
        scrollView.contentSize = contentView.frame.size
        rulerView.frame = CGRect(x: 0, y: 0, width: totalWidth, height: Self.rulerHeight)
        rulerView.configure(pointsPerSecond: pointsPerSecond, leftPadding: sidePadding, duration: model.duration, frameRate: model.frameRate)

        let rowY = Self.rulerHeight + 6
        let rowH = Self.mainRowHeight
        coverTile.frame = CGRect(x: sidePadding - Self.tileWidth - 4, y: rowY, width: Self.tileWidth, height: rowH)
        addTile.frame = CGRect(x: x(for: model.duration) + 4, y: rowY, width: Self.tileWidth, height: rowH)

        // Reconcile clip views by id.
        var seen: Set<String> = []
        for (i, c) in model.clips.enumerated() {
            seen.insert(c.id)
            let v: VEClipView
            if let existing = clipViews[c.id] { v = existing } else {
                v = VEClipView()
                v.provider = provider
                clipViews[c.id] = v
                contentView.addSubview(v)
                let tap = UITapGestureRecognizer(target: self, action: #selector(clipTapped(_:)))
                v.addGestureRecognizer(tap)
                let pan = UIPanGestureRecognizer(target: self, action: #selector(clipPanned(_:)))
                pan.delegate = self
                v.addGestureRecognizer(pan)
                let press = UILongPressGestureRecognizer(target: self, action: #selector(clipPressed(_:)))
                press.minimumPressDuration = 0.35
                press.delegate = self
                v.addGestureRecognizer(press)
            }
            v.model = c
            v.pointsPerSecond = pointsPerSecond
            v.isSelected = c.id == model.selectedID
            v.index = i
            if lifting?.id != c.id {
                v.frame = CGRect(x: x(for: c.start), y: rowY, width: max(2, x(for: c.start + c.duration) - x(for: c.start)), height: rowH)
            }
            v.setNeedsDisplay()
        }
        for (id, v) in clipViews where !seen.contains(id) { v.removeFromSuperview(); clipViews[id] = nil }
        // Keep z-order: selected on top, lifted above all.
        for c in model.clips { if let v = clipViews[c.id] { contentView.bringSubviewToFront(v) } }
        if let sel = model.selectedID, let v = clipViews[sel] { contentView.bringSubviewToFront(v) }
        if let l = lifting, let v = clipViews[l.id] { contentView.bringSubviewToFront(v) }

        // Cut handles between main clips (the white square transition handle, TL-1).
        cutViews.forEach { $0.removeFromSuperview() }
        cutViews.removeAll()
        if model.clips.count > 1 {
            for i in 1..<model.clips.count {
                let b = UIButton(type: .custom)
                b.backgroundColor = .white
                b.layer.cornerRadius = 3
                b.layer.borderColor = UIColor.black.withAlphaComponent(0.6).cgColor
                b.layer.borderWidth = 1
                b.tag = i
                b.frame = CGRect(x: x(for: model.clips[i].start) - 7, y: rowY + rowH / 2 - 7, width: 14, height: 14)
                b.addTarget(self, action: #selector(cutTapped(_:)), for: .touchUpInside)
                contentView.addSubview(b)
                cutViews.append(b)
            }
        }
    }

    private var drawnThumbsRevision = -1
    func redrawClips(ifRevisionChanged rev: Int) {
        guard rev != drawnThumbsRevision else { return }
        drawnThumbsRevision = rev
        clipViews.values.forEach { $0.setNeedsDisplay() }
    }

    // MARK: Playhead

    func setPlayhead(_ t: VETime, following: Bool) {
        guard t != playhead || following else { return }
        playhead = t
        if !userScrolling { scrollToPlayhead(animated: false) }
    }

    private func scrollToPlayhead(animated: Bool) {
        let target = CGPoint(x: x(for: playhead) - bounds.midX, y: 0)
        guard abs(scrollView.contentOffset.x - target.x) > 0.5 else { return }
        programmaticScroll = true
        scrollView.setContentOffset(target, animated: animated)
        programmaticScroll = false
    }

    // MARK: UIScrollViewDelegate

    func scrollViewDidScroll(_ sv: UIScrollView) {
        guard !programmaticScroll, userScrolling else { return }
        let t = max(0, min(model.duration, time(for: sv.contentOffset.x + bounds.midX)))
        playhead = t
        delegate?.timelineDidScrub(to: t, final: false)
    }
    func scrollViewWillBeginDragging(_ sv: UIScrollView) { userScrolling = true }
    func scrollViewDidEndDragging(_ sv: UIScrollView, willDecelerate decelerate: Bool) { if !decelerate { endUserScroll() } }
    func scrollViewDidEndDecelerating(_ sv: UIScrollView) { endUserScroll() }
    func scrollViewWillEndDragging(_ sv: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        // Momentum stops exactly on a frame (TL-1).
        let t = VETimeUtil.snapToFrame(max(0, min(model.duration, time(for: targetContentOffset.pointee.x + bounds.midX))), fps: model.frameRate)
        targetContentOffset.pointee.x = x(for: t) - bounds.midX
    }
    private func endUserScroll() {
        userScrolling = false
        let t = max(0, min(model.duration, time(for: scrollView.contentOffset.x + bounds.midX)))
        playhead = t
        delegate?.timelineDidScrub(to: t, final: true)
    }

    // MARK: Zoom

    @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
        switch g.state {
        case .began:
            zoomAnchorTime = time(for: g.location(in: contentView).x)
        case .changed:
            let anchorX = g.location(in: scrollView).x    // in scroll-view coordinates (moves with content)
            let newPPS = max(minPPS, min(maxPPS, pointsPerSecond * g.scale))
            g.scale = 1
            guard newPPS != pointsPerSecond else { return }
            pointsPerSecond = newPPS
            layoutContent()
            // Keep the pinched time under the fingers.
            let desiredContentX = x(for: zoomAnchorTime)
            let viewX = anchorX - scrollView.contentOffset.x
            programmaticScroll = true
            scrollView.contentOffset.x = max(0, desiredContentX - viewX)
            programmaticScroll = false
            playhead = max(0, min(model.duration, time(for: scrollView.contentOffset.x + bounds.midX)))
            delegate?.timelineDidScrub(to: playhead, final: false)
        case .ended, .cancelled:
            delegate?.timelineDidScrub(to: playhead, final: true)
        default: break
        }
    }

    var showsFrames: Bool { pointsPerSecond / CGFloat(max(1, model.frameRate)) > 10 }

    // MARK: Taps

    @objc private func handleBackgroundTap(_ g: UITapGestureRecognizer) {
        let p = g.location(in: contentView)
        if clipViews.values.contains(where: { $0.frame.contains(p) }) { return }
        if model.selectedID != nil { delegate?.timelineDidSelect(nil); return }
        // Tap positions the playhead without playing (PRV-2).
        let t = max(0, min(model.duration, time(for: p.x)))
        playhead = t
        scrollToPlayhead(animated: true)
        delegate?.timelineDidScrub(to: t, final: true)
    }

    @objc private func clipTapped(_ g: UITapGestureRecognizer) {
        guard let v = g.view as? VEClipView, let m = v.model else { return }
        delegate?.timelineDidSelect(m.id == model.selectedID ? nil : m.id)
    }

    @objc private func coverTapped() { delegate?.timelineCover() }
    @objc private func addTapped() { delegate?.timelineAdd(atPlayhead: false) }
    @objc private func addLongPressed(_ g: UILongPressGestureRecognizer) {
        if g.state == .began { delegate?.timelineAdd(atPlayhead: true) }
    }
    @objc private func cutTapped(_ b: UIButton) { delegate?.timelineCut(at: b.tag) }

    // MARK: Trim (TL-4)

    @objc private func clipPanned(_ g: UIPanGestureRecognizer) {
        guard let v = g.view as? VEClipView, let m = v.model else { return }
        switch g.state {
        case .began:
            guard v.isSelected, let side = v.handle(at: g.location(in: v)) else { return }
            trimOriginals.removeAll()
            _ = originalClip(for: m.id)
            trimming = (m.id, side, g.location(in: contentView).x, 0, false)
            delegate?.timelineTrim(m.id, side: side, delta: 0, phase: .began)
        case .changed:
            guard var t = trimming, let cur = model.clips.first(where: { $0.id == t.id }) else { return }
            let frame = VETimeUtil.frame(model.frameRate)
            let rawDelta = VETimeUtil.fromSeconds(Double((g.location(in: contentView).x - t.startX) / pointsPerSecond))
            // Bounds in timeline time.
            var lo: VETime, hi: VETime
            let original = originalClip(for: t.id) ?? cur
            switch t.side {
            case .left:
                let minStart: VETime = original.sourceDuration > 0 ? -VETime(Double(original.sourceStart) / max(0.01, original.rate)) : -(2 * 3600 * VETimeUtil.second)
                lo = minStart; hi = original.duration - frame
            case .right:
                lo = -(original.duration - frame)
                hi = original.sourceDuration > 0
                    ? VETime(Double(original.sourceDuration - original.sourceStart) / max(0.01, original.rate)) - original.duration
                    : 2 * 3600 * VETimeUtil.second
            }
            var delta = max(lo, min(hi, rawDelta))
            // Snap the moving edge to the playhead and other clip edges (TL-1).
            let edgeTime = t.side == .left ? original.start + delta : original.start + original.duration + delta
            if model.snapping, let snapped = snapTarget(for: edgeTime, excluding: t.id, movingLeftEdge: t.side == .left, original: original) {
                let cand = t.side == .left ? snapped - original.start : snapped - (original.start + original.duration)
                if cand >= lo && cand <= hi {
                    if !t.snapped && model.haptics { Haptics.selection() }
                    delta = cand; t.snapped = true
                } else { t.snapped = false }
            } else { t.snapped = false }
            delta = VETimeUtil.snapToFrame(delta, fps: model.frameRate)
            guard delta != t.accumulated else { trimming = t; return }
            t.accumulated = delta
            trimming = t
            v.trimBubble = "\(VETimeUtil.formatShort(t.side == .left ? original.duration - delta : original.duration + delta))  \(delta >= 0 ? "+" : "−")\(VETimeUtil.formatShort(abs(delta)))"
            delegate?.timelineTrim(t.id, side: t.side, delta: delta, phase: .changed)
        case .ended, .cancelled, .failed:
            guard let t = trimming else { return }
            trimming = nil
            trimOriginals.removeAll()
            v.trimBubble = nil
            delegate?.timelineTrim(t.id, side: t.side, delta: t.accumulated, phase: .ended)
        default: break
        }
    }

    private var trimOriginals: [String: VETimelineClipModel] = [:]
    private func originalClip(for id: String) -> VETimelineClipModel? {
        if let o = trimOriginals[id] { return o }
        if let c = model.clips.first(where: { $0.id == id }) { trimOriginals[id] = c; return c }
        return nil
    }

    /// Nearest snap point (playhead, other edges, project end) within 8 pt; releases past 16 pt.
    private func snapTarget(for edge: VETime, excluding id: String, movingLeftEdge: Bool, original: VETimelineClipModel) -> VETime? {
        var points: [VETime] = [playhead, 0]
        for c in model.clips where c.id != id { points.append(c.start); points.append(c.start + c.duration) }
        let threshold = VETimeUtil.fromSeconds(Double(Self.snapDistance / pointsPerSecond))
        var best: (VETime, VETime)?
        for p in points {
            let d = abs(p - edge)
            if d <= threshold, best == nil || d < best!.1 { best = (p, d) }
        }
        return best?.0
    }

    // MARK: Reorder (TL-7)

    @objc private func clipPressed(_ g: UILongPressGestureRecognizer) {
        guard let v = g.view as? VEClipView, let m = v.model, let index = model.clips.firstIndex(where: { $0.id == m.id }) else { return }
        switch g.state {
        case .began:
            trimming = nil
            lifting = (m.id, index, g.location(in: v).x, index)
            if model.haptics { Haptics.medium() }
            UIView.animate(withDuration: 0.15) {
                v.transform = CGAffineTransform(scaleX: 1.04, y: 1.08)
                v.alpha = 0.9
            }
            contentView.bringSubviewToFront(v)
        case .changed:
            guard var l = lifting else { return }
            let px = g.location(in: contentView).x
            v.center.x = px - l.offsetX + v.bounds.width / 2
            // Drop slot: compare the lifted clip's centre with the other clips' centres.
            let others = model.clips.filter { $0.id != l.id }
            var drop = others.count
            for (i, c) in others.enumerated() {
                let mid = x(for: c.start + c.duration / 2)
                if v.center.x < mid { drop = i; break }
            }
            if drop != l.dropIndex {
                l.dropIndex = drop
                if model.haptics { Haptics.selection() }
                partClips(around: l)
            }
            lifting = l
        case .ended, .cancelled, .failed:
            guard let l = lifting else { return }
            lifting = nil
            UIView.animate(withDuration: 0.15) { v.transform = .identity; v.alpha = 1 }
            if l.dropIndex != l.index { delegate?.timelineReorder(from: l.index, to: l.dropIndex) }
            layoutContent()
        default: break
        }
    }

    /// Slide the other clips to open the drop slot while a clip is lifted.
    private func partClips(around l: (id: String, index: Int, offsetX: CGFloat, dropIndex: Int)) {
        let lifted = model.clips[l.index]
        let others = model.clips.filter { $0.id != l.id }
        var t: VETime = 0
        var frames: [String: CGFloat] = [:]
        for (i, c) in others.enumerated() {
            if i == l.dropIndex { t += lifted.duration }
            frames[c.id] = x(for: t)
            t += c.duration
        }
        UIView.animate(withDuration: 0.15) {
            for (id, fx) in frames { self.clipViews[id]?.frame.origin.x = fx }
        }
    }

    // MARK: Gesture delegate

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        g is UIPinchGestureRecognizer || other is UIPinchGestureRecognizer
    }

    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        if let pan = g as? UIPanGestureRecognizer, let v = pan.view as? VEClipView {
            // Only a handle drag on the selected clip is a trim; everything else scrolls.
            guard v.isSelected, v.handle(at: pan.location(in: v)) != nil else { return false }
            let vel = pan.velocity(in: v)
            return abs(vel.x) > abs(vel.y)
        }
        return true
    }
}

// MARK: - Ruler

final class VERulerView: UIView {
    private var pps: CGFloat = 60
    private var left: CGFloat = 0
    private var duration: VETime = 0
    private var fps = 30

    override init(frame: CGRect) { super.init(frame: frame); backgroundColor = .clear; isOpaque = false; contentMode = .redraw }
    required init?(coder: NSCoder) { fatalError() }

    func configure(pointsPerSecond: CGFloat, leftPadding: CGFloat, duration: VETime, frameRate: Int) {
        pps = pointsPerSecond; left = leftPadding; self.duration = duration; fps = frameRate
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        // Tick spacing: pick the step so labels are ≥ 60 pt apart.
        let steps: [Double] = [0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300]
        let step = steps.first { CGFloat($0) * pps >= 60 } ?? 300
        let total = max(1, VETimeUtil.seconds(duration))
        let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular), .foregroundColor: UIColor(white: 0.6, alpha: 1)]
        ctx.setFillColor(UIColor(white: 0.35, alpha: 1).cgColor)
        var s = 0.0
        while s <= total + step {
            let x = left + CGFloat(s) * pps
            if x >= rect.minX - 80 && x <= rect.maxX + 80 {
                ctx.fill(CGRect(x: x, y: bounds.height - 4, width: 1, height: 4))
                let label = step < 1 ? String(format: "%.1f", s) : VETimeUtil.format(VETimeUtil.fromSeconds(s), fps: fps)
                (label as NSString).draw(at: CGPoint(x: x + 2, y: 1), withAttributes: attrs)
                // Minor ticks
                let minor = step / 5
                for k in 1..<5 {
                    let mx = x + CGFloat(Double(k) * minor) * pps
                    ctx.fill(CGRect(x: mx, y: bounds.height - 2, width: 1, height: 2))
                }
            }
            s += step
        }
    }
}

// MARK: - Tiles (cover / add)

final class VETileView: UIControl {
    init(symbol: String, title: String?) {
        super.init(frame: .zero)
        backgroundColor = UIColor(white: 0.18, alpha: 1)
        layer.cornerRadius = 8
        let icon = UIImageView(image: UIImage(systemName: symbol))
        icon.tintColor = .white
        icon.contentMode = .scaleAspectFit
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        NSLayoutConstraint.activate([icon.centerXAnchor.constraint(equalTo: centerXAnchor),
                                     icon.centerYAnchor.constraint(equalTo: centerYAnchor, constant: title == nil ? 0 : -6),
                                     icon.widthAnchor.constraint(equalToConstant: 18), icon.heightAnchor.constraint(equalToConstant: 18)])
        if let title {
            let l = UILabel()
            l.text = title; l.font = .systemFont(ofSize: 9); l.textColor = UIColor(white: 0.8, alpha: 1); l.textAlignment = .center
            l.translatesAutoresizingMaskIntoConstraints = false
            addSubview(l)
            NSLayoutConstraint.activate([l.centerXAnchor.constraint(equalTo: centerXAnchor), l.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 2)])
        }
        icon.isUserInteractionEnabled = false
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isHighlighted: Bool { didSet { alpha = isHighlighted ? 0.6 : 1 } }
}

// MARK: - Clip view

/// One main-track clip: filmstrip frames, waveform overlay, duration label and badges, selection
/// frame with trim handles (TL-1).
final class VEClipView: UIView {
    var model: VETimelineClipModel? { didSet { if model != oldValue { setNeedsDisplay() } } }
    var pointsPerSecond: CGFloat = 60 { didSet { if pointsPerSecond != oldValue { setNeedsDisplay() } } }
    var isSelected = false { didSet { if isSelected != oldValue { setNeedsDisplay() } } }
    var index = 0
    weak var provider: VEThumbProviding?
    var trimBubble: String? { didSet { bubble.text = trimBubble; bubble.isHidden = trimBubble == nil; setNeedsLayout() } }

    private let bubble = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
        layer.cornerRadius = 6
        clipsToBounds = false
        bubble.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        bubble.textColor = .black
        bubble.backgroundColor = .white
        bubble.layer.cornerRadius = 6
        bubble.layer.masksToBounds = true
        bubble.textAlignment = .center
        bubble.isHidden = true
        addSubview(bubble)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        bubble.sizeToFit()
        bubble.frame = CGRect(x: bounds.midX - (bubble.bounds.width + 12) / 2, y: -24, width: bubble.bounds.width + 12, height: 20)
    }

    /// Which trim handle (if any) sits under `p` (view coordinates). Selected clips only.
    func handle(at p: CGPoint) -> VETrimSide? {
        guard isSelected else { return nil }
        let w = VETimelineView.handleWidth + 8
        if p.x <= w { return .left }
        if p.x >= bounds.width - w { return .right }
        return nil
    }

    override func draw(_ rect: CGRect) {
        guard let m = model, let ctx = UIGraphicsGetCurrentContext() else { return }
        let b = bounds
        let path = UIBezierPath(roundedRect: b, cornerRadius: 6)
        ctx.saveGState()
        path.addClip()
        // Filmstrip
        (m.missing ? UIColor(white: 0.12, alpha: 1) : UIColor(white: 0.22, alpha: 1)).setFill()
        ctx.fill(b)
        if !m.missing, let provider {
            let slotW = max(24, (b.height * m.aspect).rounded())
            var x: CGFloat = 0
            while x < b.width {
                let offset = VETimeUtil.fromSeconds(Double(x / pointsPerSecond))
                let srcTime = m.sourceStart + (m.kind == .video || m.kind == .gif ? VETime(Double(offset) * m.rate) : 0)
                let slot = CGRect(x: x, y: 0, width: slotW, height: b.height)
                if slot.intersects(rect), let img = provider.frame(mediaID: m.mediaID, sourceTime: m.reversed ? max(0, m.sourceDuration - srcTime) : srcTime) {
                    let s = max(slot.width / img.size.width, slot.height / img.size.height)
                    let w = img.size.width * s, h = img.size.height * s
                    ctx.saveGState(); ctx.clip(to: slot)
                    img.draw(in: CGRect(x: slot.midX - w / 2, y: slot.midY - h / 2, width: w, height: h))
                    ctx.restoreGState()
                }
                x += slotW
            }
            // Waveform overlay on the lower third (TL-1).
            if m.hasAudio && !m.muted, let wf = provider.waveform(mediaID: m.mediaID), !wf.peaks.isEmpty {
                let h = b.height * 0.3
                let baseY = b.height - h / 2
                UIColor.systemBlue.withAlphaComponent(0.65).setFill()
                let step: CGFloat = 2
                var px: CGFloat = 0
                while px < b.width {
                    let tOff = Double(px / pointsPerSecond) * m.rate
                    let src = VETimeUtil.seconds(m.sourceStart) + tOff
                    let idx = Int(src * 1000 / Double(max(1, wf.intervalMs)))
                    if idx >= 0 && idx < wf.peaks.count {
                        let p = wf.peaks[idx]
                        let amp = CGFloat(max(abs(p.0), abs(p.1)))
                        let bh = max(1, amp * h / 2)
                        ctx.fill(CGRect(x: px, y: baseY - bh, width: step - 0.5, height: bh * 2))
                    }
                    px += step
                }
            }
        }
        ctx.restoreGState()

        // Labels / badges
        let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold), .foregroundColor: UIColor.white]
        var text = VETimeUtil.formatShort(m.duration)
        if m.missing { text = "Missing: \(m.name)" }
        var badges: [String] = []
        if (m.kind == .video || m.kind == .gif) && abs(m.rate - 1) > 0.001 { badges.append(String(format: "%.1fx", m.rate)) }
        if m.reversed { badges.append("↺") }
        if m.muted && m.hasAudio { badges.append("🔇") }
        if m.kind == .freeze { badges.append("❄︎") }
        let full = ([text] + badges).joined(separator: "  ")
        let size = (full as NSString).size(withAttributes: attrs)
        let pill = CGRect(x: 6, y: 4, width: min(b.width - 12, size.width + 8), height: 14)
        if pill.width > 20 {
            UIColor.black.withAlphaComponent(0.55).setFill()
            UIBezierPath(roundedRect: pill, cornerRadius: 4).fill()
            ctx.saveGState(); ctx.clip(to: pill)
            (full as NSString).draw(at: CGPoint(x: pill.minX + 4, y: pill.minY + 1), withAttributes: attrs)
            ctx.restoreGState()
        }

        // Selection frame + handles
        if isSelected {
            UIColor.white.setStroke()
            let frame = UIBezierPath(roundedRect: b.insetBy(dx: 1, dy: 1), cornerRadius: 6)
            frame.lineWidth = 2
            frame.stroke()
            let hw = VETimelineView.handleWidth
            for r in [CGRect(x: 0, y: 0, width: hw, height: b.height), CGRect(x: b.width - hw, y: 0, width: hw, height: b.height)] {
                UIColor.white.setFill()
                UIBezierPath(roundedRect: r, cornerRadius: 4).fill()
                UIColor.black.setFill()
                ctx.fill(CGRect(x: r.midX - 1, y: r.midY - 8, width: 2, height: 16))
            }
        }
    }
}
