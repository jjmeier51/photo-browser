/// Photo Browser for Mac's built-in video joiner — used by `video_stitch.py` only when ffmpeg isn't on the Mac.
///
///     stitch_helper <out.mp4> <unix date, or 0> <ISO 6709 place, or -> <clip> <clip> …
///
/// The clips are laid end to end in an `AVMutableComposition`. When every clip has the same picture size and
/// turn they are passed through as they are (no re-encode); otherwise each is fitted inside the first clip's
/// frame and the whole is exported at the highest quality (HEVC when the first clip is HDR, so its range is
/// kept). The date and place handed in — the oldest clip's, worked out in Python — go into the file's metadata.
///
/// Kept apart from `video_helper.swift` on purpose: that helper does the muxing, upscaling and frame exports,
/// and must go on building whatever happens here. Exit code 0 when the video was written.
import AVFoundation
import CoreMedia
import Foundation

func fail(_ why: String) -> Never {
    FileHandle.standardError.write((why + "\n").data(using: .utf8)!)
    exit(1)
}

func export(_ session: AVAssetExportSession) async {
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in session.exportAsynchronously { c.resume() } }
}

struct Piece {
    let video: AVAssetTrack
    let audio: AVAssetTrack?
    let duration: CMTime
    let size: CGSize                 // as shown, after its turn
    let transform: CGAffineTransform
    let rate: Float
}

func shown(_ size: CGSize, _ t: CGAffineTransform) -> CGSize {
    let r = CGRect(origin: .zero, size: size).applying(t)
    return CGSize(width: abs(r.width), height: abs(r.height))
}

@main
struct StitchHelper {
    static func main() async {
        let a = CommandLine.arguments
        guard a.count >= 6 else { fail("usage: stitch_helper out date place clip clip …") }
        let dest = URL(fileURLWithPath: a[1])
        let when = Double(a[2]) ?? 0
        let place = a[3] == "-" ? nil : a[3]

        var pieces: [Piece] = []
        var hdr = false
        for path in a[4...] {
            let asset = AVURLAsset(url: URL(fileURLWithPath: path))
            guard let v = try? await asset.loadTracks(withMediaType: .video).first,
                  let duration = try? await asset.load(.duration),
                  let (natural, transform, rate) = try? await v.load(.naturalSize, .preferredTransform, .nominalFrameRate)
            else { fail("can't read \(path)") }
            let audio = try? await asset.loadTracks(withMediaType: .audio).first
            if pieces.isEmpty, let formats = try? await v.load(.formatDescriptions), let f = formats.first,
               let ext = CMFormatDescriptionGetExtensions(f) as? [CFString: Any],
               let curve = ext[kCMFormatDescriptionExtension_TransferFunction] as? String {
                hdr = curve == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String)
                    || curve == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
            }
            pieces.append(Piece(video: v, audio: audio, duration: duration, size: shown(natural, transform),
                                transform: transform, rate: rate))
        }

        let comp = AVMutableComposition()
        guard let vTrack = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { fail("can't make the timeline") }
        let aTrack = pieces.contains(where: { $0.audio != nil })
            ? comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) : nil
        var at = CMTime.zero
        var starts: [CMTime] = []
        for p in pieces {
            let range = CMTimeRange(start: .zero, duration: p.duration)
            do {
                try vTrack.insertTimeRange(range, of: p.video, at: at)
                if let audio = p.audio, let aTrack { try aTrack.insertTimeRange(range, of: audio, at: at) }
            } catch { fail("can't add a clip to the timeline: \(error.localizedDescription)") }
            starts.append(at)
            at = at + p.duration
        }

        let first = pieces[0]
        let alike = pieces.allSatisfy { $0.size == first.size && $0.transform == first.transform }
        let preset = alike ? AVAssetExportPresetPassthrough
                           : (hdr ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetHighestQuality)
        guard let session = AVAssetExportSession(asset: comp, presetName: preset) else { fail("can't start the export") }
        if alike {
            vTrack.preferredTransform = first.transform
        } else {
            // Each clip fitted inside the first clip's frame, centred.
            let canvas = CGSize(width: (first.size.width / 2).rounded() * 2, height: (first.size.height / 2).rounded() * 2)
            let video = AVMutableVideoComposition()
            video.renderSize = canvas
            let fps = max(1, min(120, Int32((pieces.map { $0.rate }.max() ?? 30).rounded())))
            video.frameDuration = CMTime(value: 1, timescale: fps)
            var instructions: [AVMutableVideoCompositionInstruction] = []
            for (i, p) in pieces.enumerated() {
                let ins = AVMutableVideoCompositionInstruction()
                ins.timeRange = CMTimeRange(start: starts[i], duration: p.duration)
                let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: vTrack)
                let scale = min(canvas.width / max(p.size.width, 1), canvas.height / max(p.size.height, 1))
                // The clip's own turn first (which may leave it off at a negative origin), brought back to
                // the origin, scaled, then centred.
                let turned = CGRect(origin: .zero, size: p.video.naturalSize).applying(p.transform)
                let t = p.transform
                    .concatenating(CGAffineTransform(translationX: -turned.minX, y: -turned.minY))
                    .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                    .concatenating(CGAffineTransform(translationX: (canvas.width - p.size.width * scale) / 2,
                                                     y: (canvas.height - p.size.height * scale) / 2))
                layer.setTransform(t, at: starts[i])
                ins.layerInstructions = [layer]
                instructions.append(ins)
            }
            video.instructions = instructions
            session.videoComposition = video
        }

        var meta: [AVMetadataItem] = []
        if when > 0 {
            let iso = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: when))
            for id in [AVMetadataIdentifier.commonIdentifierCreationDate, .quickTimeMetadataCreationDate] {
                let item = AVMutableMetadataItem(); item.identifier = id; item.value = iso as NSString; meta.append(item)
            }
        }
        if let place {
            for id in [AVMetadataIdentifier.quickTimeMetadataLocationISO6709, .commonIdentifierLocation] {
                let item = AVMutableMetadataItem(); item.identifier = id; item.value = place as NSString; meta.append(item)
            }
        }
        try? FileManager.default.removeItem(at: dest)
        session.outputURL = dest
        session.outputFileType = .mp4
        session.metadata = meta
        session.shouldOptimizeForNetworkUse = true
        await export(session)
        if session.status != .completed {
            try? FileManager.default.removeItem(at: dest)
            fail(session.error?.localizedDescription ?? "the export didn't finish")
        }
        exit(0)
    }
}
