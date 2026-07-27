import AVFoundation
import CoreMedia
import UIKit

/// AVFoundation helpers for the video editor: a filmstrip of thumbnails, lossless **trim** (passthrough
/// export of a time range), and **stitch** (concatenate several clips into one). All `nonisolated` —
/// AVFoundation load/generate/export must stay off the main actor. Best-effort: a failure returns
/// false / an empty strip rather than throwing into the UI.
enum VideoComposer {

    // MARK: - Filmstrip

    /// `count` evenly-spaced thumbnails across the video, oriented correctly. Fast + approximate
    /// (infinite tolerance) since these are only a scrubbing reference, not frame-accurate stills.
    nonisolated static func filmstrip(url: URL, count: Int) async -> [UIImage] {
        let asset = AVURLAsset(url: url)
        guard count > 0, let dur = try? await asset.load(.duration).seconds, dur > 0, dur.isFinite else { return [] }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 200, height: 200)
        gen.requestedTimeToleranceBefore = .positiveInfinity
        gen.requestedTimeToleranceAfter = .positiveInfinity
        var out: [UIImage] = []
        for i in 0..<count {
            let t = CMTime(seconds: dur * (Double(i) + 0.5) / Double(count), preferredTimescale: 600)
            if let cg = try? await gen.image(at: t).image {
                out.append(UIImage(cgImage: cg))
            }
        }
        return out
    }

    // MARK: - Trim

    /// Exports the `[start, end]` range of `src` to `dest`, lossless (passthrough — no re-encode, so
    /// quality/HDR/colour are byte-preserved). Returns whether it completed.
    nonisolated static func trim(_ src: URL, start: Double, end: Double, to dest: URL) async -> Bool {
        let asset = AVURLAsset(url: src, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard end > start,
              let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else { return false }
        let ts: CMTimeScale = 600
        export.timeRange = CMTimeRange(start: CMTime(seconds: max(0, start), preferredTimescale: ts),
                                       end: CMTime(seconds: end, preferredTimescale: ts))
        export.outputURL = dest
        export.outputFileType = fileType(for: dest)
        try? FileManager.default.removeItem(at: dest)
        return await run(export)
    }

    // MARK: - Stitch

    /// Concatenates `urls` (in the given order) into one video at `dest`. Each clip is rendered — with
    /// its own orientation transform — aspect-fit + centered into one common, even-sized frame (the
    /// largest clip's oriented size), via an `AVMutableVideoComposition`. This is what makes the output
    /// reliably **playable**: without a video composition, clips of differing size/orientation produce
    /// a malformed track that won't play. Audio is joined back-to-back. Re-encoded to H.264/HEVC.
    nonisolated static func stitch(_ urls: [URL], to dest: URL,
                                   progress: (@Sendable (Double) -> Void)? = nil) async -> Bool {
        let comp = AVMutableComposition()
        guard let vTrack = comp.addMutableTrack(withMediaType: .video,
                                                preferredTrackID: kCMPersistentTrackID_Invalid) else { return false }
        let aTrack = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)

        struct Seg { let start: CMTime; let dur: CMTime; let natural: CGSize; let transform: CGAffineTransform }
        var segs: [Seg] = []
        var cursor = CMTime.zero
        var renderSize = CGSize.zero
        var frameDuration = CMTime(value: 1, timescale: 30)
        var oldest: Date?                       // earliest source date → the combined clip's date
        var baseMeta: [AVMetadataItem] = []     // metadata carried over (from the first clip)
        var hdrColor: (primaries: String, transfer: String, matrix: String)?   // set from the first HDR clip

        for url in urls {
            let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            guard let dur = try? await asset.load(.duration), dur.seconds > 0,
                  let srcV = try? await asset.loadTracks(withMediaType: .video).first else { continue }
            let range = CMTimeRange(start: .zero, duration: dur)
            do { try vTrack.insertTimeRange(range, of: srcV, at: cursor) } catch { continue }
            if let aTrack, let srcA = try? await asset.loadTracks(withMediaType: .audio).first {
                try? aTrack.insertTimeRange(range, of: srcA, at: cursor)
            }
            if segs.isEmpty { baseMeta = (try? await asset.load(.commonMetadata)) ?? [] }  // carry the first clip's metadata
            if let d = await sourceDate(asset, url), oldest == nil || d < oldest! { oldest = d }
            if hdrColor == nil, let ci = await colorInfo(of: srcV), ci.isHDR {
                hdrColor = (ci.primaries, ci.transfer, ci.matrix)   // any HDR source → HDR output
            }
            let natural = (try? await srcV.load(.naturalSize)) ?? CGSize(width: 1280, height: 720)
            let transform = (try? await srcV.load(.preferredTransform)) ?? .identity
            let oriented = CGRect(origin: .zero, size: natural).applying(transform)
            renderSize.width = max(renderSize.width, abs(oriented.width))
            renderSize.height = max(renderSize.height, abs(oriented.height))
            if let fr = try? await srcV.load(.nominalFrameRate), fr > 0 {
                let clamped = max(24, min(60, Double(fr).rounded()))
                frameDuration = CMTime(value: 1, timescale: CMTimeScale(clamped))
            }
            segs.append(Seg(start: cursor, dur: dur, natural: natural, transform: transform))
            cursor = cursor + dur
        }
        guard !segs.isEmpty, renderSize.width > 0, renderSize.height > 0 else { return false }

        // H.264/HEVC need even dimensions.
        let rw = Int(renderSize.width.rounded()), rh = Int(renderSize.height.rounded())
        let finalSize = CGSize(width: max(2, rw - rw % 2), height: max(2, rh - rh % 2))

        var instructions: [any AVVideoCompositionInstructionProtocol] = []
        for seg in segs {
            let inst = AVMutableVideoCompositionInstruction()
            inst.timeRange = CMTimeRange(start: seg.start, duration: seg.dur)
            let li = AVMutableVideoCompositionLayerInstruction(assetTrack: vTrack)
            li.setTransform(fitTransform(natural: seg.natural, preferred: seg.transform, into: finalSize), at: seg.start)
            inst.layerInstructions = [li]
            instructions.append(inst)
        }

        let videoComp = AVMutableVideoComposition()
        videoComp.renderSize = finalSize
        videoComp.frameDuration = frameDuration
        videoComp.instructions = instructions
        if let hdrColor {
            // Render + tag the composition in the source's HDR (BT.2020 + HLG/PQ) color space, and
            // export via HEVC so the output is a real 10-bit HDR video, not a tone-mapped SDR one.
            videoComp.colorPrimaries = hdrColor.primaries
            videoComp.colorTransferFunction = hdrColor.transfer
            videoComp.colorYCbCrMatrix = hdrColor.matrix
        }

        let preset = hdrColor != nil ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetHighestQuality
        guard let export = AVAssetExportSession(asset: comp, presetName: preset) else { return false }
        export.videoComposition = videoComp
        export.outputURL = dest
        export.outputFileType = fileType(for: dest)
        export.shouldOptimizeForNetworkUse = true
        export.metadata = combinedMetadata(baseMeta, date: oldest)   // carry over metadata; stamp the oldest date
        try? FileManager.default.removeItem(at: dest)
        let ok = await run(export, progress: progress)
        // Also set the file's dates so the browser's timeline/Age/sort use the oldest source date.
        if ok, let oldest {
            try? FileManager.default.setAttributes([.creationDate: oldest, .modificationDate: oldest],
                                                   ofItemAtPath: dest.path)
        }
        return ok
    }

    /// The video track's color primaries / transfer function / YCbCr matrix, plus whether it's HDR
    /// (an HLG or PQ transfer function). The extension values are the same strings AVVideoComposition
    /// expects, so they can be applied to the composition directly. Falls back to Rec.709 (SDR).
    private nonisolated static func colorInfo(of track: AVAssetTrack) async
        -> (primaries: String, transfer: String, matrix: String, isHDR: Bool)? {
        guard let fmts = try? await track.load(.formatDescriptions), let fmt = fmts.first else { return nil }
        let ext = (CMFormatDescriptionGetExtensions(fmt) as? [CFString: Any]) ?? [:]
        let primaries = (ext[kCMFormatDescriptionExtension_ColorPrimaries] as? String) ?? AVVideoColorPrimaries_ITU_R_709_2
        let transfer  = (ext[kCMFormatDescriptionExtension_TransferFunction] as? String) ?? AVVideoTransferFunction_ITU_R_709_2
        let matrix    = (ext[kCMFormatDescriptionExtension_YCbCrMatrix] as? String) ?? AVVideoYCbCrMatrix_ITU_R_709_2
        let isHDR = transfer == AVVideoTransferFunction_ITU_R_2100_HLG
                 || transfer == AVVideoTransferFunction_SMPTE_ST_2084_PQ
        return (primaries, transfer, matrix, isHDR)
    }

    /// The best available date for a source clip: its embedded creation date, else the file's
    /// creation/modification date. Used to pick the earliest across the combined clips.
    private nonisolated static func sourceDate(_ asset: AVURLAsset, _ url: URL) async -> Date? {
        if let item = (try? await asset.load(.creationDate)) ?? nil,
           let date = (try? await item.load(.dateValue)) ?? nil {
            return date
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.creationDate] as? Date) ?? (attrs?[.modificationDate] as? Date)
    }

    /// The metadata to write onto the combined clip: the carried-over items from the first source
    /// (location, device, etc.), with the creation date replaced by the earliest source date.
    private nonisolated static func combinedMetadata(_ base: [AVMetadataItem], date: Date?) -> [AVMetadataItem] {
        var items = base.filter { $0.commonKey != .commonKeyCreationDate }
        if let date {
            let item = AVMutableMetadataItem()
            item.keySpace = .common
            item.identifier = .commonIdentifierCreationDate
            item.value = date as NSDate
            items.append(item)
        }
        return items
    }

    /// A transform that takes a source of `natural` size, applies its `preferred` orientation
    /// transform, then aspect-fits and centers it into the `render` frame.
    private nonisolated static func fitTransform(natural: CGSize, preferred: CGAffineTransform,
                                                 into render: CGSize) -> CGAffineTransform {
        let oriented = CGRect(origin: .zero, size: natural).applying(preferred)
        let ow = abs(oriented.width), oh = abs(oriented.height)
        guard ow > 0, oh > 0 else { return preferred }
        let scale = min(render.width / ow, render.height / oh)
        let scaledW = ow * scale, scaledH = oh * scale
        return preferred
            .concatenating(CGAffineTransform(translationX: -oriented.minX, y: -oriented.minY))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: (render.width - scaledW) / 2,
                                             y: (render.height - scaledH) / 2))
    }

    // MARK: - Helpers

    /// Runs an export via the iOS 17 completion-handler API (the async `export()` is iOS 18-only),
    /// polling `progress` while it works.
    private nonisolated static func run(_ export: AVAssetExportSession,
                                        progress: (@Sendable (Double) -> Void)? = nil) async -> Bool {
        let poller: Task<Void, Never>? = progress == nil ? nil : Task {
            while !Task.isCancelled {
                progress?(Double(export.progress))
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        let ok = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            export.exportAsynchronously { cont.resume(returning: export.status == .completed) }
        }
        poller?.cancel()
        return ok
    }

    private nonisolated static func fileType(for url: URL) -> AVFileType {
        switch url.pathExtension.lowercased() {
        case "mov":  return .mov
        case "m4v":  return .m4v
        default:      return .mp4
        }
    }
}
