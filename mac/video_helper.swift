// The video helper for Safe Finder's Instagram and Facebook downloads (mac/video_tools.py): AVFoundation
// for what Python can't do — putting a DASH video's two halves together, and upscaling a video to 1080p.
// The code is the iPhone app's (InstagramService.mux, MediaEditing.upscaleVideo), so a video comes out of
// Safe Finder the way it comes out of the iPhone. Safe Finder builds it once with `swiftc` (Xcode or its
// Command Line Tools) into ~/Library/Caches/PhotoBrowser/; without it, ffmpeg does the same when it's
// installed.
//
//   video_helper mux <video> <audio> <out.mp4> <unix time> [<lat> <lng>]   → exit 0 when <out> is written
//   video_helper upscale <in> <out.mov> <short side>                       → prints upscaled / skipped / failed
//   video_helper size <in>                                                 → prints "<width> <height>" (as shown)
//
// The mux copies the streams as they are (no re-encode, HDR kept) and writes the post's date and place as
// the iPhone does. The upscale scales so the short side is <short side> (never down), H.264 at the highest
// quality — HEVC for HDR, so it stays HDR — with the source's metadata and capture date carried over.
import AVFoundation
import CoreMedia
import Foundation

func videoMetadata(date: Date, lat: Double?, lng: Double?) -> [AVMetadataItem] {
    var meta: [AVMetadataItem] = []
    let iso = ISO8601DateFormatter().string(from: date)
    for id in [AVMetadataIdentifier.commonIdentifierCreationDate, .quickTimeMetadataCreationDate] {
        let item = AVMutableMetadataItem(); item.identifier = id; item.value = iso as NSString; meta.append(item)
    }
    if let lat, let lng, !(lat == 0 && lng == 0), abs(lat) <= 90, abs(lng) <= 180 {
        let iso6709 = String(format: "%+09.5f%+010.5f/", lat, lng)
        for id in [AVMetadataIdentifier.quickTimeMetadataLocationISO6709, .commonIdentifierLocation] {
            let item = AVMutableMetadataItem(); item.identifier = id; item.value = iso6709 as NSString; meta.append(item)
        }
    }
    return meta
}

func export(_ session: AVAssetExportSession) async {
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in session.exportAsynchronously { c.resume() } }
}

func mux(video: URL, audio: URL, to dest: URL, date: Date, lat: Double?, lng: Double?) async -> Bool {
    let comp = AVMutableComposition()
    let vAsset = AVURLAsset(url: video)
    guard let vTrack = try? await vAsset.loadTracks(withMediaType: .video).first,
          let compV = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
          let dur = try? await vAsset.load(.duration), dur.seconds > 0 else { return false }
    try? compV.insertTimeRange(CMTimeRange(start: .zero, duration: dur), of: vTrack, at: .zero)
    if let t = try? await vTrack.load(.preferredTransform) { compV.preferredTransform = t }
    let aAsset = AVURLAsset(url: audio)
    if let aTrack = try? await aAsset.loadTracks(withMediaType: .audio).first,
       let compA = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
        let aDur = (try? await aAsset.load(.duration)) ?? dur
        try? compA.insertTimeRange(CMTimeRange(start: .zero, duration: CMTimeMinimum(dur, aDur)), of: aTrack, at: .zero)
    }
    guard let session = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough) else { return false }
    session.metadata = videoMetadata(date: date, lat: lat, lng: lng)
    session.outputURL = dest
    session.outputFileType = .mp4
    await export(session)
    return session.status == .completed
}

/// The size a video is shown at (its track's size turned by its transform).
func shownSize(_ url: URL) async -> CGSize? {
    let asset = AVURLAsset(url: url)
    guard let track = try? await asset.loadTracks(withMediaType: .video).first,
          let natural = try? await track.load(.naturalSize) else { return nil }
    let pt = (try? await track.load(.preferredTransform)) ?? .identity
    let r = CGRect(origin: .zero, size: natural).applying(pt)
    return CGSize(width: abs(r.width), height: abs(r.height))
}

func upscale(_ url: URL, to dest: URL, short targetShort: CGFloat) async -> String {
    let asset = AVURLAsset(url: url)
    guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return "failed" }
    let natural = (try? await track.load(.naturalSize)) ?? .zero
    let pt = (try? await track.load(.preferredTransform)) ?? .identity
    let duration = (try? await asset.load(.duration)) ?? .zero
    let fps = (try? await track.load(.nominalFrameRate)).map { $0 > 0 ? $0 : 30 } ?? 30
    guard natural.width > 0, natural.height > 0, duration.seconds > 0 else { return "failed" }
    let shown = CGRect(origin: .zero, size: natural).applying(pt)
    let w = abs(shown.width), h = abs(shown.height)
    let shortSide = min(w, h)
    guard shortSide > 0 else { return "failed" }
    guard shortSide < targetShort else { return "skipped" }
    let scale = targetShort / shortSide
    let outW = max(2, (w * scale / 2).rounded() * 2), outH = max(2, (h * scale / 2).rounded() * 2)

    var isPQ = false, isHLG = false
    if let fd = (try? await track.load(.formatDescriptions))?.first,
       let ext = CMFormatDescriptionGetExtensions(fd) as? [CFString: Any] {
        let tf = ext[kCMFormatDescriptionExtension_TransferFunction] as? String
        isPQ = tf == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String)
        isHLG = tf == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
    }
    let hdr = isPQ || isHLG
    let comp = AVMutableVideoComposition()
    comp.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(fps.rounded(), 1)))
    comp.renderSize = CGSize(width: outW, height: outH)
    if hdr {
        comp.colorPrimaries = AVVideoColorPrimaries_ITU_R_2020
        comp.colorTransferFunction = isPQ ? AVVideoTransferFunction_SMPTE_ST_2084_PQ : AVVideoTransferFunction_ITU_R_2100_HLG
        comp.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_2020
    }
    let instruction = AVMutableVideoCompositionInstruction()
    instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
    let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
    layer.setTransform(pt.concatenating(CGAffineTransform(scaleX: scale, y: scale)), at: .zero)
    instruction.layerInstructions = [layer]
    comp.instructions = [instruction]

    let meta = ((try? await asset.load(.metadata)) ?? []) + ((try? await asset.loadMetadata(for: .quickTimeMetadata)) ?? [])
    guard let session = AVAssetExportSession(asset: asset, presetName: hdr ? AVAssetExportPresetHEVCHighestQuality
                                                                          : AVAssetExportPresetHighestQuality) else { return "failed" }
    session.videoComposition = comp
    session.outputURL = dest
    session.outputFileType = .mov
    session.metadata = meta
    await export(session)
    return session.status == .completed ? "upscaled" : "failed"
}

@main
struct VideoHelper {
    static func main() async {
        let a = CommandLine.arguments
        guard a.count >= 3 else { exit(2) }
        switch a[1] {
        case "mux" where a.count >= 6:
            let lat = a.count >= 8 ? Double(a[6]) : nil, lng = a.count >= 8 ? Double(a[7]) : nil
            let date = Date(timeIntervalSince1970: Double(a[5]) ?? Date().timeIntervalSince1970)
            let ok = await mux(video: URL(fileURLWithPath: a[2]), audio: URL(fileURLWithPath: a[3]),
                               to: URL(fileURLWithPath: a[4]), date: date, lat: lat, lng: lng)
            exit(ok ? 0 : 1)
        case "upscale" where a.count >= 5:
            let r = await upscale(URL(fileURLWithPath: a[2]), to: URL(fileURLWithPath: a[3]), short: CGFloat(Double(a[4]) ?? 1080))
            print(r)
            exit(r == "failed" ? 1 : 0)
        case "size":
            guard let s = await shownSize(URL(fileURLWithPath: a[2])) else { exit(1) }
            print("\(Int(s.width)) \(Int(s.height))")
            exit(0)
        default:
            exit(2)
        }
    }
}
