import Foundation
import os
import AVFoundation
import CoreMedia
import CoreImage
import UIKit

// MARK: - Render instruction

/// How one clip sits on the canvas for a span of composition time. Everything the compositor needs
/// is in here (immutable after build) so it never reads the document (ARC-4).
nonisolated struct VELayerSpec: @unchecked Sendable {
    var clipID: String
    var kind: VEClipKind
    var trackID: CMPersistentTrackID          // kCMPersistentTrackID_Invalid for stills / missing media
    var imageURL: URL?                        // stills and GIFs
    var isMissing: Bool
    var sourceSize: CGSize                    // oriented (display) size in pixels
    var rotation: VERotation                  // the file's own orientation; frames arrive un-rotated
    var crop: VECrop
    var transform: VETransform
    var opacity: Double
    var background: VEBackground
    var compositionStart: CMTime
    var compositionDuration: CMTime
    var sourceStart: VETime
    var rate: Double
    var reversed: Bool
    var loopDuration: VETime                  // GIF natural loop; 0 otherwise
}

nonisolated final class VEInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    let layers: [VELayerSpec]
    let canvasSize: CGSize

    init(timeRange: CMTimeRange, layers: [VELayerSpec], canvasSize: CGSize) {
        self.timeRange = timeRange
        self.layers = layers
        self.canvasSize = canvasSize
        let ids = layers.map(\.trackID).filter { $0 != kCMPersistentTrackID_Invalid }
        self.requiredSourceTrackIDs = ids.map { NSNumber(value: $0) }
        super.init()
    }
}

// MARK: - Built composition

nonisolated struct VEBuiltComposition: @unchecked Sendable {
    let composition: AVMutableComposition
    let videoComposition: AVMutableVideoComposition
    let audioMix: AVMutableAudioMix?
    let duration: CMTime
    let usesProxy: Bool
    let missingClipIDs: [String]

    func playerItem() -> AVPlayerItem {
        let item = AVPlayerItem(asset: composition)
        item.videoComposition = videoComposition
        item.audioMix = audioMix
        item.appliesPerFrameHDRDisplayMetadata = false
        return item
    }
}

/// Loaded `AVURLAsset`s keyed by path, so rebuilding the composition after every edit never
/// re-parses files over USB (PRV-5).
nonisolated final class VEAssetCache: @unchecked Sendable {
    static let shared = VEAssetCache()
    private let lock = NSLock()
    private var assets: [String: AVURLAsset] = [:]

    func asset(for url: URL) async throws -> AVURLAsset {
        lock.lock()
        if let a = assets[url.path] { lock.unlock(); return a }
        lock.unlock()
        let a = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        _ = try await a.load(.duration, .tracks)
        lock.lock(); assets[url.path] = a; lock.unlock()
        return a
    }
    func evict(_ url: URL) { lock.lock(); assets[url.path] = nil; lock.unlock() }
    func evictAll() { lock.lock(); assets.removeAll(); lock.unlock() }
}

// MARK: - Builder

/// Project → `AVMutableComposition` + `AVMutableVideoComposition` + `AVMutableAudioMix` (ARC-2).
/// Main-track clips alternate between two video tracks (A/B) so transitions have both sources;
/// stills occupy empty time on track A and are drawn by the compositor from their image file.
/// The same graph feeds preview, export and thumbnails.
nonisolated enum VECompositionBuilder {
    nonisolated struct Options: Sendable {
        var useProxies = false
        var renderSize: CGSize? = nil        // nil = canvas size (export); preview passes its view size
        var frameRate: Int? = nil            // nil = project frame rate
        var muteAll = false                  // scrubbing preview
    }

    static func build(_ project: VEProject, package: URL, store: VEDriveStore, options: Options = Options()) async throws -> VEBuiltComposition {
        let composition = AVMutableComposition()
        let videoA = composition.addMutableTrack(withMediaType: .video, preferredTrackID: 1)!
        let videoB = composition.addMutableTrack(withMediaType: .video, preferredTrackID: 2)!
        let audioA = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: 101)!
        let audioB = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: 102)!
        var mixParams: [AVMutableAudioMixInputParameters] = []
        var instructions: [VEInstruction] = []
        var missing: [String] = []
        var usesProxy = false
        let canvas = project.settings.canvas.size
        let fps = options.frameRate ?? project.settings.frameRate
        let starts = project.mainStarts()
        let total = project.duration
        let fm = FileManager.default

        for (i, clip) in project.tracks.main.enumerated() {
            let start = VETimeUtil.cm(starts[i])
            let dur = VETimeUtil.cm(clip.timelineDuration)
            let source = project.source(clip.mediaId)
            var spec = VELayerSpec(clipID: clip.id, kind: clip.kind, trackID: kCMPersistentTrackID_Invalid, imageURL: nil, isMissing: false,
                                   sourceSize: CGSize(width: 1920, height: 1080), rotation: .none, crop: clip.crop, transform: clip.transform,
                                   opacity: clip.opacity, background: clip.background, compositionStart: start, compositionDuration: dur,
                                   sourceStart: clip.sourceRange.start, rate: clip.rate, reversed: clip.reversed, loopDuration: 0)
            let vTrack = (i % 2 == 0) ? videoA : videoB
            let aTrack = (i % 2 == 0) ? audioA : audioB
            var placedVideo = false

            if let source {
                var url = store.resolve(source.path, package: package)
                if !fm.fileExists(atPath: url.path) {
                    spec.isMissing = true
                    missing.append(clip.id)
                } else {
                    spec.sourceSize = source.displaySize.cgSize
                    spec.rotation = source.transform
                    switch clip.kind {
                    case .image, .gif, .freeze:
                        spec.imageURL = url
                        spec.loopDuration = source.kind == .gif ? source.duration : 0
                    case .video:
                        // Proxy for preview when allowed and present (PRV-3); export always uses originals.
                        if options.useProxies, let p = source.derived.proxy {
                            let proxyURL = store.resolve(p, package: package)
                            if fm.fileExists(atPath: proxyURL.path) { url = proxyURL; usesProxy = true; spec.rotation = .none }
                        }
                        if let asset = try? await VEAssetCache.shared.asset(for: url),
                           let srcVideo = try? await asset.loadTracks(withMediaType: .video).first {
                            let assetDur = VETimeUtil.us(try await asset.load(.duration))
                            let srcStart = min(clip.sourceRange.start, max(0, assetDur - 1))
                            let srcDur = max(1, min(clip.sourceRange.duration, assetDur - srcStart))
                            let srcRange = CMTimeRange(start: VETimeUtil.cm(srcStart), duration: VETimeUtil.cm(srcDur))
                            do {
                                try vTrack.insertTimeRange(srcRange, of: srcVideo, at: start)
                                if abs(clip.rate - 1) > 0.0001 {
                                    vTrack.scaleTimeRange(CMTimeRange(start: start, duration: srcRange.duration), toDuration: dur)
                                }
                                spec.trackID = vTrack.trackID
                                placedVideo = true
                                // Proxies are re-encoded upright; originals keep their rotation flag.
                                if url != store.resolve(source.path, package: package) { spec.sourceSize = source.displaySize.cgSize }
                            } catch {
                                VELog.render.error("insert failed for \(source.displayName): \(error.localizedDescription)")
                                spec.isMissing = true
                                missing.append(clip.id)
                            }
                            // Embedded audio (TL-11, "Mute original audio").
                            if !options.muteAll, source.hasAudio, !clip.audioExtracted, !project.settings.muteOriginalAudio,
                               let srcAudio = try? await asset.loadTracks(withMediaType: .audio).first {
                                do {
                                    try aTrack.insertTimeRange(srcRange, of: srcAudio, at: start)
                                    if abs(clip.rate - 1) > 0.0001 {
                                        aTrack.scaleTimeRange(CMTimeRange(start: start, duration: srcRange.duration), toDuration: dur)
                                    }
                                    let params = AVMutableAudioMixInputParameters(track: aTrack)
                                    params.audioTimePitchAlgorithm = clip.speed.keepPitch ? .spectral : .varispeed
                                    let vol = Float(clip.audioMuted ? 0 : clip.volume)
                                    params.setVolume(vol, at: start)
                                    if clip.fadeIn > 0 {
                                        let fi = min(VETimeUtil.cm(clip.fadeIn), dur)
                                        params.setVolumeRamp(fromStartVolume: 0, toEndVolume: vol, timeRange: CMTimeRange(start: start, duration: fi))
                                    }
                                    if clip.fadeOut > 0 {
                                        let fo = min(VETimeUtil.cm(clip.fadeOut), dur)
                                        params.setVolumeRamp(fromStartVolume: vol, toEndVolume: 0, timeRange: CMTimeRange(start: start + dur - fo, duration: fo))
                                    }
                                    mixParams.append(params)
                                } catch {
                                    VELog.render.error("audio insert failed: \(error.localizedDescription)")
                                }
                            }
                        } else {
                            spec.isMissing = true
                            missing.append(clip.id)
                        }
                    }
                }
            } else {
                spec.isMissing = true
                missing.append(clip.id)
            }
            if !placedVideo {
                // Stills and missing media: keep track A's timeline contiguous so the composition
                // spans this clip; the compositor draws the image (or black) itself.
                videoA.insertEmptyTimeRange(CMTimeRange(start: start, duration: dur))
            }
            instructions.append(VEInstruction(timeRange: CMTimeRange(start: start, duration: dur), layers: [spec], canvasSize: canvas))
        }

        // Independent audio lanes (Phase 2 populates them; built here so the schema is honoured).
        var laneTracks: [AVMutableCompositionTrack] = []
        for lane in project.tracks.audio {
            let t = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
            laneTracks.append(t)
            for a in lane {
                guard !options.muteAll, let source = project.source(a.mediaId) else { continue }
                let url = store.resolve(source.path, package: package)
                guard fm.fileExists(atPath: url.path),
                      let asset = try? await VEAssetCache.shared.asset(for: url),
                      let srcAudio = try? await asset.loadTracks(withMediaType: .audio).first else { continue }
                // Anything past the main track's end is not rendered (TL-18).
                let visible = min(a.timelineDuration, max(0, total - a.timelineStart))
                guard visible > 0 else { continue }
                let srcDur = VETime((Double(visible) * max(0.01, a.rate)).rounded())
                let range = CMTimeRange(start: VETimeUtil.cm(a.sourceRange.start), duration: VETimeUtil.cm(srcDur))
                let at = VETimeUtil.cm(a.timelineStart)
                do {
                    try t.insertTimeRange(range, of: srcAudio, at: at)
                    if abs(a.rate - 1) > 0.0001 { t.scaleTimeRange(CMTimeRange(start: at, duration: range.duration), toDuration: VETimeUtil.cm(visible)) }
                    let params = AVMutableAudioMixInputParameters(track: t)
                    params.audioTimePitchAlgorithm = a.keepPitch ? .spectral : .varispeed
                    let vol = Float(a.muted ? 0 : a.volume)
                    params.setVolume(vol, at: at)
                    let d = VETimeUtil.cm(visible)
                    if a.fadeIn > 0 { params.setVolumeRamp(fromStartVolume: 0, toEndVolume: vol, timeRange: CMTimeRange(start: at, duration: min(VETimeUtil.cm(a.fadeIn), d))) }
                    if a.fadeOut > 0 {
                        let fo = min(VETimeUtil.cm(a.fadeOut), d)
                        params.setVolumeRamp(fromStartVolume: vol, toEndVolume: 0, timeRange: CMTimeRange(start: at + d - fo, duration: fo))
                    }
                    mixParams.append(params)
                } catch { continue }
            }
        }

        // Remove tracks that stayed empty — fewer decoders, less memory.
        for t in [videoB, audioA, audioB] + laneTracks where t.segments.isEmpty {
            composition.removeTrack(t)
        }
        if videoA.segments.isEmpty && total > 0 {
            videoA.insertEmptyTimeRange(CMTimeRange(start: .zero, duration: VETimeUtil.cm(total)))
        }

        let video = AVMutableVideoComposition()
        video.customVideoCompositorClass = VECompositor.self
        video.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))
        video.renderSize = Self.renderSize(canvas: canvas, requested: options.renderSize)
        video.renderScale = 1
        video.instructions = instructions
        video.sourceTrackIDForFrameTiming = kCMPersistentTrackID_Invalid
        // SDR project: BT.709 working space, so HDR sources are converted before compositing (CAN-7).
        video.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        video.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        video.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2

        var mix: AVMutableAudioMix?
        if !mixParams.isEmpty {
            let m = AVMutableAudioMix()
            m.inputParameters = mixParams
            mix = m
        }
        return VEBuiltComposition(composition: composition, videoComposition: video, audioMix: mix,
                                  duration: VETimeUtil.cm(total), usesProxy: usesProxy, missingClipIDs: missing)
    }

    /// Preview renders at the view's pixel size capped at 1920 on the long edge (PRV-3); export at
    /// the canvas size. Always even.
    static func renderSize(canvas: CGSize, requested: CGSize?) -> CGSize {
        guard let r = requested, r.width > 0, r.height > 0 else { return canvas }
        let fit = min(r.width / canvas.width, r.height / canvas.height, 1920 / max(canvas.width, canvas.height), 1)
        func even(_ v: CGFloat) -> CGFloat { max(2, (v / 2).rounded() * 2) }
        return CGSize(width: even(canvas.width * fit), height: even(canvas.height * fit))
    }
}

// MARK: - Layer geometry (shared by the compositor and the on-canvas gizmo)

/// The placement math for one layer, in canvas pixel units with a bottom-left origin (Core Image
/// space). Crop and straighten apply before any transform so keyframed motion later operates on the
/// cropped picture (TL-8).
nonisolated enum VELayerMath {
    /// Source rect after crop (oriented-source pixel space, bottom-left origin).
    static func cropRect(sourceSize: CGSize, crop: VECrop) -> CGRect {
        let r = crop.rect
        let x = CGFloat(r.x) * sourceSize.width
        let yTop = CGFloat(r.y) * sourceSize.height
        let w = max(1, CGFloat(r.w) * sourceSize.width)
        let h = max(1, CGFloat(r.h) * sourceSize.height)
        // UI stores y from the top; Core Image counts from the bottom.
        return CGRect(x: x, y: sourceSize.height - yTop - h, width: w, height: h)
    }

    /// Scale that lets a `w×h` picture rotated by `degrees` still cover its own `w×h` box.
    static func coverScale(width w: CGFloat, height h: CGFloat, degrees: Double) -> CGFloat {
        let t = degrees * .pi / 180
        let c = abs(cos(t)), s = abs(sin(t))
        guard w > 0, h > 0 else { return 1 }
        return max((w * c + h * s) / w, (w * s + h * c) / h)
    }

    /// Transform mapping the cropped picture (origin at 0,0, size `cropSize`) onto the canvas
    /// (`canvasSize`, bottom-left origin), applying fit, user scale, rotation, flips and position.
    static func placement(cropSize: CGSize, canvasSize: CGSize, transform t: VETransform) -> CGAffineTransform {
        let fit = min(canvasSize.width / max(1, cropSize.width), canvasSize.height / max(1, cropSize.height))
        let scale = fit * CGFloat(max(0.0001, t.scale))
        var m = CGAffineTransform.identity
        // Move the picture's centre to the origin, flip/scale/rotate about it, then place it.
        m = m.translatedBy(x: canvasSize.width / 2 + CGFloat(t.x) * canvasSize.width / 2,
                           y: canvasSize.height / 2 + CGFloat(t.y) * canvasSize.height / 2)
        m = m.rotated(by: CGFloat(-t.rotation) * .pi / 180)   // clockwise on screen (y-up space)
        m = m.scaledBy(x: scale * (t.flipH ? -1 : 1), y: scale * (t.flipV ? -1 : 1))
        m = m.translatedBy(x: -cropSize.width / 2, y: -cropSize.height / 2)
        return m
    }

    /// The four corners of the placed picture in canvas pixels (for the selection gizmo).
    static func corners(sourceSize: CGSize, crop: VECrop, canvasSize: CGSize, transform: VETransform) -> [CGPoint] {
        let cr = cropRect(sourceSize: sourceSize, crop: crop)
        let m = placement(cropSize: cr.size, canvasSize: canvasSize, transform: transform)
        return [CGPoint(x: 0, y: 0), CGPoint(x: cr.width, y: 0), CGPoint(x: cr.width, y: cr.height), CGPoint(x: 0, y: cr.height)].map { $0.applying(m) }
    }

    /// Orientation fix for raw decoded frames: the file's rotation flag, as a transform that leaves
    /// the result with its origin at (0,0).
    static func orient(_ image: CIImage, rotation: VERotation) -> CIImage {
        guard rotation != .none else { return image }
        let e = image.extent
        var t: CGAffineTransform
        switch rotation {
        case .rotate90:  t = CGAffineTransform(rotationAngle: -.pi / 2).translatedBy(x: 0, y: 0); t = t.concatenating(CGAffineTransform(translationX: 0, y: e.width))
        case .rotate180: t = CGAffineTransform(rotationAngle: .pi).concatenating(CGAffineTransform(translationX: e.width, y: e.height))
        case .rotate270: t = CGAffineTransform(rotationAngle: .pi / 2).concatenating(CGAffineTransform(translationX: e.height, y: 0))
        case .none: t = .identity
        }
        let out = image.transformed(by: t)
        return out.transformed(by: CGAffineTransform(translationX: -out.extent.origin.x, y: -out.extent.origin.y))
    }
}

nonisolated enum VEColor {
    /// `#RRGGBB` or `#RRGGBBAA` → components 0…1.
    static func components(_ hex: String) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard let v = UInt64(s, radix: 16) else { return (0, 0, 0, 1) }
        if s.count == 8 {
            return (CGFloat((v >> 24) & 0xff) / 255, CGFloat((v >> 16) & 0xff) / 255, CGFloat((v >> 8) & 0xff) / 255, CGFloat(v & 0xff) / 255)
        }
        return (CGFloat((v >> 16) & 0xff) / 255, CGFloat((v >> 8) & 0xff) / 255, CGFloat(v & 0xff) / 255, 1)
    }
    static func ciColor(_ hex: String) -> CIColor {
        let c = components(hex)
        return CIColor(red: c.r, green: c.g, blue: c.b, alpha: c.a)
    }
    static func uiColor(_ hex: String) -> UIColor {
        let c = components(hex)
        return UIColor(red: c.r, green: c.g, blue: c.b, alpha: c.a)
    }
    static func hex(_ color: UIColor) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }
}
