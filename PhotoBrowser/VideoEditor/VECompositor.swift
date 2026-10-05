import Foundation
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Metal
import ImageIO
import UIKit

/// The one renderer behind preview, export and thumbnails (ARC-3): a Core Image graph on a
/// Metal-backed `CIContext`. For each request it fetches the source frame per layer, orients and
/// crops it, places it on the canvas (fit → scale → rotate → flip → position), applies opacity and
/// composites over the clip's background. Runs on AVFoundation's rendering queue; reads only the
/// immutable `VEInstruction` and never touches the document.
nonisolated final class VECompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    private let renderQueue = DispatchQueue(label: "VideoEditor.compositor", qos: .userInteractive)
    private var renderContext: AVVideoCompositionRenderContext?
    private let ciContext: CIContext
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    override init() {
        if let device = MTLCreateSystemDefaultDevice() {
            ciContext = CIContext(mtlDevice: device, options: [.cacheIntermediates: false, .name: "VideoEditor"])
        } else {
            ciContext = CIContext(options: [.cacheIntermediates: false])
        }
        super.init()
    }

    var sourcePixelBufferAttributes: [String: any Sendable]? {
        [kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                                      kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                                      kCVPixelFormatType_32BGRA],
         kCVPixelBufferMetalCompatibilityKey as String: true]
    }

    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA],
         kCVPixelBufferMetalCompatibilityKey as String: true]
    }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        renderQueue.sync { renderContext = newRenderContext }
    }

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        renderQueue.async { [weak self] in
            autoreleasepool { self?.render(request) }
        }
    }

    func cancelAllPendingVideoCompositionRequests() {
        // Requests are short; nothing is queued beyond the dispatch queue itself.
    }

    // MARK: Frame pipeline

    private func render(_ request: AVAsynchronousVideoCompositionRequest) {
        let ctx = request.renderContext
        guard let out = ctx.newPixelBuffer() else {
            request.finish(with: NSError(domain: "VideoEditor", code: 1, userInfo: [NSLocalizedDescriptionKey: "No render context"]))
            return
        }
        let renderSize = CGSize(width: CVPixelBufferGetWidth(out), height: CVPixelBufferGetHeight(out))
        let bounds = CGRect(origin: .zero, size: renderSize)
        guard let instruction = request.videoCompositionInstruction as? VEInstruction else {
            // Not ours (shouldn't happen): black frame.
            ciContext.render(CIImage(color: .black).cropped(to: bounds), to: out, bounds: bounds, colorSpace: colorSpace)
            request.finish(withComposedVideoFrame: out)
            return
        }
        let image = Self.compose(instruction: instruction, at: request.compositionTime, renderSize: renderSize) { trackID in
            request.sourceFrame(byTrackID: trackID).map { CIImage(cvPixelBuffer: $0) }
        }
        ciContext.render(image, to: out, bounds: bounds, colorSpace: colorSpace)
        request.finish(withComposedVideoFrame: out)
    }

    /// Pure composition of one frame (also used by the cover generator). `frame(trackID)` supplies
    /// decoded source frames; stills come from `VEImageCache`.
    static func compose(instruction: VEInstruction, at time: CMTime, renderSize: CGSize,
                        frame: (CMPersistentTrackID) -> CIImage?) -> CIImage {
        let canvas = instruction.canvasSize
        let scale = renderSize.width / max(1, canvas.width)
        let bounds = CGRect(origin: .zero, size: renderSize)
        var result = CIImage(color: .black).cropped(to: bounds)

        for layer in instruction.layers {
            // Background under this clip (CAN-4).
            result = background(for: layer, source: nil, canvas: canvas, scale: scale, bounds: bounds, over: result)
            var source: CIImage?
            if layer.trackID != kCMPersistentTrackID_Invalid, let f = frame(layer.trackID) {
                source = VELayerMath.orient(f, rotation: layer.rotation)
            } else if let url = layer.imageURL {
                let sourceTime = sourceTime(for: layer, at: time)
                source = VEImageCache.shared.image(url, maxPixel: Int(max(canvas.width, canvas.height) * 2), kind: layer.kind, sourceTime: sourceTime,
                                                   loopDuration: layer.loopDuration)
            }
            guard var img = source else { continue }
            if layer.background.kind == "blur" {
                result = background(for: layer, source: img, canvas: canvas, scale: scale, bounds: bounds, over: result)
            }
            // The frame may be a proxy or downsampled still: scale it to the recorded source size so
            // crop fractions and placement stay independent of the decode resolution.
            let e = img.extent
            if e.width > 0, e.height > 0, abs(e.width - layer.sourceSize.width) > 1 || abs(e.height - layer.sourceSize.height) > 1 {
                img = img.transformed(by: CGAffineTransform(scaleX: layer.sourceSize.width / e.width, y: layer.sourceSize.height / e.height))
            }
            img = img.transformed(by: CGAffineTransform(translationX: -img.extent.origin.x, y: -img.extent.origin.y))
            // Crop + straighten (TL-8).
            let cropRect = VELayerMath.cropRect(sourceSize: layer.sourceSize, crop: layer.crop)
            if layer.crop.straighten != 0 {
                let s = VELayerMath.coverScale(width: cropRect.width, height: cropRect.height, degrees: layer.crop.straighten)
                var t = CGAffineTransform(translationX: cropRect.midX, y: cropRect.midY)
                t = t.rotated(by: CGFloat(-layer.crop.straighten) * .pi / 180).scaledBy(x: s, y: s)
                t = t.translatedBy(x: -cropRect.midX, y: -cropRect.midY)
                img = img.transformed(by: t)
            }
            img = img.cropped(to: cropRect).transformed(by: CGAffineTransform(translationX: -cropRect.origin.x, y: -cropRect.origin.y))
            // Place on the canvas, then into render pixels.
            var place = VELayerMath.placement(cropSize: cropRect.size, canvasSize: canvas, transform: layer.transform)
            place = place.concatenating(CGAffineTransform(scaleX: scale, y: scale))
            img = img.transformed(by: place, highQualityDownsample: true)
            if layer.opacity < 0.999 {
                img = img.applyingFilter("CIColorMatrix", parameters: [kCIInputAVectorKey: CIVector(x: 0, y: 0, z: 0, w: CGFloat(max(0, layer.opacity)))])
            }
            result = img.cropped(to: bounds).composited(over: result)
        }
        return result.cropped(to: bounds)
    }

    /// Source time for a still/GIF layer at composition time `t` (GIFs loop at their natural length).
    static func sourceTime(for layer: VELayerSpec, at t: CMTime) -> VETime {
        let offset = max(0, VETimeUtil.us(t - layer.compositionStart))
        var s = layer.sourceStart + VETime(Double(offset) * layer.rate)
        if layer.loopDuration > 0 { s = s % layer.loopDuration }
        return s
    }

    private static func background(for layer: VELayerSpec, source: CIImage?, canvas: CGSize, scale: CGFloat, bounds: CGRect, over: CIImage) -> CIImage {
        switch layer.background.kind {
        case "none":
            return over
        case "blur":
            guard let src = source else { return over }
            let e = src.extent
            guard e.width > 0, e.height > 0 else { return over }
            let cover = max(bounds.width / e.width, bounds.height / e.height)
            var img = src.transformed(by: CGAffineTransform(translationX: -e.origin.x, y: -e.origin.y))
            img = img.transformed(by: CGAffineTransform(scaleX: cover, y: cover))
            img = img.transformed(by: CGAffineTransform(translationX: (bounds.width - e.width * cover) / 2, y: (bounds.height - e.height * cover) / 2))
            let sigmaPct: [Int: CGFloat] = [1: 0.01, 2: 0.02, 3: 0.04, 4: 0.08]
            let sigma = (sigmaPct[layer.background.blurLevel] ?? 0.02) * min(bounds.width, bounds.height)
            let blurred = img.clampedToExtent().applyingGaussianBlur(sigma: Double(sigma)).cropped(to: bounds)
            return blurred.composited(over: over)
        case "image":
            guard let p = layer.background.path else { return over }
            // Background images resolve to absolute paths at build time (stored in `path`).
            let url = URL(fileURLWithPath: p)
            guard let img0 = VEImageCache.shared.image(url, maxPixel: Int(max(canvas.width, canvas.height)), kind: .image, sourceTime: 0, loopDuration: 0) else { return over }
            let e = img0.extent
            let cover = max(bounds.width / e.width, bounds.height / e.height)
            var img = img0.transformed(by: CGAffineTransform(scaleX: cover, y: cover))
            img = img.transformed(by: CGAffineTransform(translationX: (bounds.width - e.width * cover) / 2, y: (bounds.height - e.height * cover) / 2))
            return img.cropped(to: bounds).composited(over: over)
        default:
            return CIImage(color: VEColor.ciColor(layer.background.color)).cropped(to: bounds).composited(over: over)
        }
    }
}

/// Decoded stills (and GIF frame sets) for the compositor, keyed by path and size, capped at
/// 64 MB of RAM (NFR-2). GIFs keep their per-frame delays so a layer can pick the frame for a time.
nonisolated final class VEImageCache: @unchecked Sendable {
    static let shared = VEImageCache()

    private final class Entry {
        let frames: [CIImage]
        let cumulative: [Double]      // seconds at the end of each frame
        let cost: Int
        init(frames: [CIImage], delays: [Double]) {
            self.frames = frames
            var acc = 0.0
            cumulative = delays.map { acc += $0; return acc }
            cost = frames.reduce(0) { $0 + Int($1.extent.width * $1.extent.height * 4) }
        }
    }

    private let cache: NSCache<NSString, Entry> = {
        let c = NSCache<NSString, Entry>()
        c.totalCostLimit = 64 * 1024 * 1024
        return c
    }()

    func image(_ url: URL, maxPixel: Int, kind: VEClipKind, sourceTime: VETime, loopDuration: VETime) -> CIImage? {
        let key = "\(url.path)|\(maxPixel)" as NSString
        let entry: Entry
        if let e = cache.object(forKey: key) {
            entry = e
        } else {
            guard let e = Self.load(url, maxPixel: maxPixel, animated: kind == .gif) else { return nil }
            cache.setObject(e, forKey: key, cost: e.cost)
            entry = e
        }
        guard entry.frames.count > 1, let total = entry.cumulative.last, total > 0 else { return entry.frames.first }
        let t = VETimeUtil.seconds(sourceTime).truncatingRemainder(dividingBy: total)
        let idx = entry.cumulative.firstIndex { t < $0 } ?? entry.frames.count - 1
        return entry.frames[idx]
    }

    func removeAll() { cache.removeAllObjects() }

    private static func load(_ url: URL, maxPixel: Int, animated: Bool) -> Entry? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let count = animated ? min(CGImageSourceGetCount(src), 600) : 1
        // GIF frame sets are capped smaller so a long animation doesn't swallow the cache.
        let px = animated && count > 1 ? min(maxPixel, 720) : maxPixel
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceShouldCacheImmediately: true,
                                     kCGImageSourceThumbnailMaxPixelSize: px]
        var frames: [CIImage] = []
        var delays: [Double] = []
        for i in 0..<max(1, count) {
            guard let cg = CGImageSourceCreateThumbnailAtIndex(src, i, opts as CFDictionary) else { continue }
            frames.append(CIImage(cgImage: cg))
            var d = 0.1
            if let fp = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any],
               let gif = fp[kCGImagePropertyGIFDictionary] as? [CFString: Any] {
                d = (gif[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber)?.doubleValue
                    ?? (gif[kCGImagePropertyGIFDelayTime] as? NSNumber)?.doubleValue ?? 0.1
            }
            delays.append(max(0.02, d))
        }
        guard !frames.isEmpty else { return nil }
        return Entry(frames: frames, delays: delays)
    }
}

// MARK: - Cover / single-frame rendering

nonisolated enum VEFrameRenderer {
    /// Renders one composed frame of a built composition (project cover, export completion
    /// thumbnail) through the same compositor as playback.
    static func image(of built: VEBuiltComposition, at time: VETime, maxPixel: CGFloat) async -> UIImage? {
        let gen = AVAssetImageGenerator(asset: built.composition)
        gen.videoComposition = built.videoComposition
        gen.appliesPreferredTrackTransform = false
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        gen.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        let t = min(max(0, time), max(0, VETimeUtil.us(built.duration) - 1))
        guard let cg = try? await gen.image(at: VETimeUtil.cm(t)).image else { return nil }
        return UIImage(cgImage: cg)
    }
}
