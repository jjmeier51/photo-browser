// The video helper for Safe Finder (mac/video_tools.py, mac/frame_export.py): AVFoundation for what Python
// can't do — putting a DASH video's two halves together, upscaling a video to 1080p, and the iPhone's frame
// screenshot and Export All Frames.
// The code is the iPhone app's (InstagramService.mux, MediaEditing.upscaleVideo), so a video comes out of
// Safe Finder the way it comes out of the iPhone. Safe Finder builds it once with `swiftc` (Xcode or its
// Command Line Tools) into ~/Library/Caches/PhotoBrowser/; without it, ffmpeg does the same when it's
// installed.
//
//   video_helper mux <video> <audio> <out.mp4> <unix time> [<lat> <lng>]   → exit 0 when <out> is written
//   video_helper upscale <in> <out.mov> <short side>                       → prints upscaled / skipped / failed
//   video_helper size <in>                                                 → prints "<width> <height>" (as shown)
//   video_helper frame <in> <seconds> <out.png>                            → exit 0 when <out> is written
//   video_helper frames <in> <dir> <base> <fps|0> <sdr|hdr> <start> <atomic|direct>
//                                       → prints "total N", "progress i N" now and then, then "done <written>"
//   video_helper fetch <url> <referer> <user agent> <out>               → prints "status <code>" (exit 0) or
//                                                                          "failed <why>" (exit 1)
//
// `fetch` is one web page or picture through the Mac's own networking — URLSession, what the iPhone app
// uses — for Safe Finder's taylorpictures.net browser when Python's can't get through (macOS completes a
// server's certificate chain and speaks TLS as Safari does). The request is the iPhone app's
// (TaylorGallery.fetchHTML): its agent, Accept and Accept-Language, and the referer.
//
// `frame` is the iPhone's press-and-hold screenshot (FileActions.saveStandardRangePNG): the frame upright,
// tone-mapped to standard range when the video is HDR, 8-bit sRGB PNG, doubled up to a 4K long side, the
// video's capture date in its EXIF. `frames` is the iPhone's Export All Frames (FileActions.exportAllFrames):
// one sequential reader (10-bit for HDR), every frame — or every Nth at <fps> — as "<base> <index>.heic",
// 1.5× Lanczos, the capture date kept; an HDR frame tone-mapped to standard range (`sdr`, like the
// screenshot) or kept HDR with the screenshot look (`hdr`); frames already there skipped (so a stopped export
// carries on); a reader that fails restarted after the last good frame. `atomic` writes each frame through a
// temporary name and a rename (APFS); `direct` writes it in place (exFAT: no renames — CLAUDE.md #12).
//
// The mux copies the streams as they are (no re-encode, HDR kept) and writes the post's date and place as
// the iPhone does. The upscale scales so the short side is <short side> (never down), H.264 at the highest
// quality — HEVC for HDR, so it stays HDR — with the source's metadata and capture date carried over.
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreMedia
import Foundation
import ImageIO
import UniformTypeIdentifiers

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

// MARK: - Frames (the iPhone's screenshot and Export All Frames)

let ciContext = CIContext()

func isHDRSpace(_ cs: CGColorSpace?) -> Bool {
    guard let cs else { return false }
    if CGColorSpaceUsesITUR_2100TF(cs) || CGColorSpaceUsesExtendedRange(cs) { return true }
    let name = (cs.name as String?) ?? ""
    return name.contains("2100") || name.contains("2020") || name.contains("HLG") || name.contains("PQ")
}

/// HDR → standard range, the press-and-hold screenshot's mapping (macOS 15+: from HLG's 4.93 headroom down
/// to SDR white); before macOS 15 the screenshot look's highlight trim is the closest there is.
func standardRange(_ ci: CIImage) -> CIImage {
    if #available(macOS 15.0, *) {
        let tone = CIFilter.toneMapHeadroom()
        tone.inputImage = ci
        tone.sourceHeadroom = 4.93
        tone.targetHeadroom = 1
        return tone.outputImage ?? ci
    }
    return softened(ci)
}

/// The tap screenshot's HDR look: highlights eased to 3× SDR white, a light exposure trim.
func softened(_ ci: CIImage) -> CIImage {
    var out = ci
    var trim: Float = -0.15
    if #available(macOS 15.0, *) {
        let tone = CIFilter.toneMapHeadroom()
        tone.inputImage = out
        tone.sourceHeadroom = 4.93
        tone.targetHeadroom = 3.0
        out = tone.outputImage ?? out
    } else {
        trim *= 2
    }
    let e = CIFilter.exposureAdjust()
    e.inputImage = out
    e.ev = trim
    return e.outputImage ?? out
}

func upscaled(_ ci: CIImage, by scale: CGFloat) -> CIImage {
    guard scale > 1.001 else { return ci }
    let f = CIFilter.lanczosScaleTransform()
    f.inputImage = ci
    f.scale = Float(scale)
    f.aspectRatio = 1
    return f.outputImage ?? ci
}

/// The video's capture date as EXIF/TIFF dates, for its frames.
func frameProperties(_ asset: AVAsset) async -> [String: Any] {
    guard let item = try? await asset.load(.creationDate), let date = try? await item.load(.dateValue) else { return [:] }
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy:MM:dd HH:mm:ss"
    let s = f.string(from: date)
    return [kCGImagePropertyExifDictionary as String: [kCGImagePropertyExifDateTimeOriginal as String: s,
                                                       kCGImagePropertyExifDateTimeDigitized as String: s],
            kCGImagePropertyTIFFDictionary as String: [kCGImagePropertyTIFFDateTime as String: s]]
}

func saveFrame(_ url: URL, at seconds: Double, to dest: URL) async -> Bool {
    let asset = AVURLAsset(url: url)
    let gen = AVAssetImageGenerator(asset: asset)
    gen.appliesPreferredTrackTransform = true
    gen.requestedTimeToleranceBefore = .zero
    gen.requestedTimeToleranceAfter = .zero
    let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
    var frame: CGImage?
    if #available(macOS 13.0, *) {
        frame = try? await gen.image(at: time).image
    } else {
        frame = try? gen.copyCGImage(at: time, actualTime: nil)
    }
    guard let cg = frame else { return false }
    let props = await frameProperties(asset)
    var ci = CIImage(cgImage: cg)
    if isHDRSpace(cg.colorSpace) { ci = standardRange(ci) }
    ci = upscaled(ci, by: max(1, min(2, 3840 / max(CGFloat(max(cg.width, cg.height)), 1))))
    guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
          let out = ciContext.createCGImage(ci, from: ci.extent, format: .RGBA8, colorSpace: srgb),
          let d = CGImageDestinationCreateWithURL(dest as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
    CGImageDestinationAddImage(d, out, props as CFDictionary)
    return CGImageDestinationFinalize(d)
}

func encodeFrame(_ pb: CVPixelBuffer, transform: CGAffineTransform, props: [String: Any], scale: CGFloat,
                 standardRange sdr: Bool) -> Data? {
    var ci = CIImage(cvImageBuffer: pb)
    if !transform.isIdentity {
        // CIImage is Y-up, the video transform Y-down: conjugate it (negate b and c) to turn the right way.
        var t = transform
        t.b = -t.b
        t.c = -t.c
        ci = ci.transformed(by: t)
        ci = ci.transformed(by: CGAffineTransform(translationX: -ci.extent.origin.x, y: -ci.extent.origin.y))
    }
    if !props.isEmpty { ci = ci.settingProperties(ci.properties.merging(props) { _, new in new }) }
    let cs = ci.colorSpace ?? CGColorSpaceCreateDeviceRGB()
    let hdr = isHDRSpace(cs)
    ci = upscaled(ci, by: scale)
    if hdr && sdr, let srgb = CGColorSpace(name: CGColorSpace.sRGB) {
        return ciContext.heifRepresentation(of: standardRange(ci), format: .RGBA8, colorSpace: srgb, options: [:])
    }
    if hdr, #available(macOS 12.0, *), let d = try? ciContext.heif10Representation(of: softened(ci), colorSpace: cs, options: [:]) {
        return d
    }
    let p3 = CGColorSpace(name: CGColorSpace.displayP3) ?? cs
    return ciContext.heifRepresentation(of: ci, format: .RGBA8, colorSpace: p3, options: [:])
}

final class FrameCounter: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var written = 0
    func add() { lock.lock(); written += 1; lock.unlock() }
}

struct FrameJob: @unchecked Sendable {
    let buffer: CVPixelBuffer
    let dest: URL
}

func say(_ line: String) {
    print(line)
    fflush(stdout)
}

func exportFrames(_ url: URL, dir: URL, base: String, fps requested: Double, standardRange sdr: Bool, start: Int,
                  atomic: Bool) async -> Int32 {
    let asset = AVURLAsset(url: url)
    guard let track = try? await asset.loadTracks(withMediaType: .video).first else {
        say("error the video couldn't be opened (no readable video track)")
        return 1
    }
    let isHDR = ((try? await track.load(.mediaCharacteristics))?.contains(.containsHDRVideo)) ?? false
    let duration = (try? await asset.load(.duration))?.seconds ?? 0
    let native = Double((try? await track.load(.nominalFrameRate)) ?? 0)
    let base30 = native > 0 ? native : 30
    let fps = requested > 0 ? min(requested, base30) : base30
    guard duration > 0 else { say("error the video reports no duration"); return 1 }
    let interval = 1.0 / fps
    let total = max(1, Int((duration * fps).rounded()))
    let transform = (try? await track.load(.preferredTransform)) ?? .identity
    let props = await frameProperties(asset)
    say("total \(total)")
    let settings: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String:
                                    isHDR ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_32BGRA]
    var frameIndex = start
    var nextTime = Double(start) * interval
    var startTime = nextTime
    var failures = 0
    let counter = FrameCounter()
    let queue = DispatchQueue(label: "frames", qos: .userInitiated, attributes: .concurrent)
    let slots = DispatchSemaphore(value: 2)                 // two frames encoding while the next is decoded
    let group = DispatchGroup()
    var lastSaid = Date.distantPast
    while startTime < duration, failures < 6, frameIndex < total {
        guard let reader = try? AVAssetReader(asset: asset) else { break }
        if startTime > 0 {
            reader.timeRange = CMTimeRange(start: CMTime(seconds: startTime, preferredTimescale: 600), duration: .positiveInfinity)
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { break }
        reader.add(output)
        guard reader.startReading() else { break }
        var lastPTS = startTime, advanced = false
        while reader.status == .reading, frameIndex < total {
            guard let sample = output.copyNextSampleBuffer() else { break }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            if pts.isFinite { lastPTS = pts; advanced = true }
            guard pts.isFinite, pts + 1e-4 >= nextTime else { continue }
            let dest = dir.appendingPathComponent("\(base) \(frameIndex).heic")
            if !FileManager.default.fileExists(atPath: dest.path), let pb = CMSampleBufferGetImageBuffer(sample) {
                let job = FrameJob(buffer: pb, dest: dest)
                slots.wait()
                group.enter()
                queue.async {
                    defer { slots.signal(); group.leave() }
                    guard let data = encodeFrame(job.buffer, transform: transform, props: props, scale: 1.5, standardRange: sdr)
                    else { return }
                    if atomic {
                        let tmp = job.dest.deletingLastPathComponent().appendingPathComponent(".\(job.dest.lastPathComponent).part")
                        do {
                            try data.write(to: tmp)
                            if let fh = try? FileHandle(forWritingTo: tmp) { try? fh.synchronize(); try? fh.close() }
                            try FileManager.default.moveItem(at: tmp, to: job.dest)
                            counter.add()
                        } catch {
                            try? FileManager.default.removeItem(at: tmp)
                        }
                    } else if (try? data.write(to: job.dest)) != nil {
                        counter.add()
                    }
                }
            }
            frameIndex += 1
            nextTime = Double(frameIndex) * interval
            if nextTime <= pts {                               // sparse frames: skip ahead on the grid
                frameIndex = Int((pts / interval).rounded(.down)) + 1
                nextTime = Double(frameIndex) * interval
            }
            if Date().timeIntervalSince(lastSaid) > 0.25 {
                lastSaid = Date()
                say("progress \(min(frameIndex, total)) \(total)")
            }
        }
        if reader.status == .completed { break }
        if reader.status == .failed {
            failures += 1
            startTime = advanced ? lastPTS + interval : startTime + max(interval, 0.5)
            if nextTime < startTime {
                frameIndex = max(frameIndex, Int((startTime / interval).rounded()))
                nextTime = Double(frameIndex) * interval
            }
        } else {
            break
        }
    }
    group.wait()
    say("progress \(total) \(total)")
    say("done \(counter.written)")
    return 0
}

func fetch(_ address: String, referer: String, agent: String, to out: URL) async -> Int32 {
    guard let url = URL(string: address) else { print("failed not a web address"); return 1 }
    var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
    req.setValue(agent, forHTTPHeaderField: "User-Agent")
    req.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
    req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
    if !referer.isEmpty { req.setValue(referer, forHTTPHeaderField: "Referer") }
    do {
        let (data, response) = try await URLSession.shared.data(for: req)
        try data.write(to: out)
        print("status \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        return 0
    } catch {
        print("failed \(error.localizedDescription)")
        return 1
    }
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
        case "frame" where a.count >= 5:
            let ok = await saveFrame(URL(fileURLWithPath: a[2]), at: Double(a[3]) ?? 0, to: URL(fileURLWithPath: a[4]))
            exit(ok ? 0 : 1)
        case "frames" where a.count >= 9:
            let code = await exportFrames(URL(fileURLWithPath: a[2]), dir: URL(fileURLWithPath: a[3], isDirectory: true),
                                          base: a[4], fps: Double(a[5]) ?? 0, standardRange: a[6] != "hdr",
                                          start: Int(a[7]) ?? 0, atomic: a[8] != "direct")
            exit(code)
        case "fetch" where a.count >= 6:
            exit(await fetch(a[2], referer: a[3], agent: a[4], to: URL(fileURLWithPath: a[5])))
        default:
            exit(2)
        }
    }
}
