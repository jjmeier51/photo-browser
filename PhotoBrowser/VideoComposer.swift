import AVFoundation
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

    /// Concatenates `urls` (in the given order) into one video at `dest`. Uses the first clip's
    /// orientation/size for the composition; clips are joined back-to-back with their audio. Best for
    /// clips that share an orientation (a v1 without per-segment repositioning).
    nonisolated static func stitch(_ urls: [URL], to dest: URL,
                                   progress: (@Sendable (Double) -> Void)? = nil) async -> Bool {
        let comp = AVMutableComposition()
        guard let vTrack = comp.addMutableTrack(withMediaType: .video,
                                                preferredTrackID: kCMPersistentTrackID_Invalid) else { return false }
        let aTrack = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        var cursor = CMTime.zero
        var transform = CGAffineTransform.identity
        var first = true
        for url in urls {
            let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            guard let dur = try? await asset.load(.duration), dur.seconds > 0 else { continue }
            let range = CMTimeRange(start: .zero, duration: dur)
            if let srcV = try? await asset.loadTracks(withMediaType: .video).first {
                try? vTrack.insertTimeRange(range, of: srcV, at: cursor)
                if first { transform = (try? await srcV.load(.preferredTransform)) ?? .identity; first = false }
            }
            if let aTrack, let srcA = try? await asset.loadTracks(withMediaType: .audio).first {
                try? aTrack.insertTimeRange(range, of: srcA, at: cursor)
            }
            cursor = cursor + dur
        }
        vTrack.preferredTransform = transform
        guard cursor > .zero,
              let export = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality) else { return false }
        export.outputURL = dest
        export.outputFileType = fileType(for: dest)
        try? FileManager.default.removeItem(at: dest)
        return await run(export, progress: progress)
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
