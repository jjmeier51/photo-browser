// The thumbnail helper for Safe Finder (mac/safe_finder.py): video frames and RAW/odd-image previews.
//
// Qt and Pillow can't read video, and `qlmanage` — the only built-in command that can — starts Quick
// Look afresh for every run and returns nothing until its whole batch is done, so a folder of videos
// filled in slowly. This program stays running and makes each thumbnail with AVFoundation (a frame a
// moment into the video) or ImageIO (RAW and anything else ImageIO reads, from its embedded preview),
// several at once. Safe Finder builds it once with `swiftc` (Xcode or its Command Line Tools) into
// ~/Library/Caches/PhotoBrowser/ and falls back to Quick Look without it, or for anything it can't do.
//
// Protocol, one JSON object per line. In (stdin):  {"id": "…", "path": "…", "out": "…", "px": 512,
// "video": true}. Out (stdout): {"id": "…", "ok": true} once `out` holds the JPEG (written beside it,
// then renamed), or {"id": "…", "ok": false}. Requests run concurrently; Safe Finder bounds how many are
// in flight. Ends when stdin closes, after the ones in hand.
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import UniformTypeIdentifiers

let output = FileHandle.standardOutput
let outputLock = NSLock()
let work = DispatchGroup()

func reply(_ id: String, _ ok: Bool) {
    guard var data = try? JSONSerialization.data(withJSONObject: ["id": id, "ok": ok]) else { return }
    data.append(0x0A)
    outputLock.lock()
    output.write(data)
    outputLock.unlock()
}

/// A frame a moment in (a tenth of the way, at most a second — past a fade from black), upright, at
/// most `px` on its long side. The generator usually tone-maps HDR video; `standardRange` sees to the rest.
func videoFrame(_ url: URL, px: Int) -> CGImage? {
    let asset = AVURLAsset(url: url)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: px, height: px)
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
    let seconds = CMTimeGetSeconds(asset.duration)
    let at = seconds.isFinite && seconds > 0 ? min(1.0, seconds * 0.1) : 0
    if let frame = try? generator.copyCGImage(at: CMTime(seconds: at, preferredTimescale: 600), actualTime: nil) {
        return frame
    }
    return try? generator.copyCGImage(at: .zero, actualTime: nil)
}

/// An image's preview — its embedded one when it has one (RAW), else made from the image — upright.
func imagePreview(_ url: URL, px: Int) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: px,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
}

let ciContext = CIContext()

/// A real HDR curve (PQ / HLG) or extended range — not merely wide colour: a frame the video generator has
/// already tone-mapped can come tagged BT.2020, and mapping it again would dull it (as video_helper.swift).
func isHDRSpace(_ cs: CGColorSpace?) -> Bool {
    guard let cs else { return false }
    if CGColorSpaceUsesITUR_2100TF(cs) || CGColorSpaceUsesExtendedRange(cs) { return true }
    let name = (cs.name as String?) ?? ""
    return name.contains("2100") || name.contains("HLG") || name.contains("PQ")
}

/// `image` as an 8-bit sRGB picture. Safe Finder draws its tiles with Qt, which shows a JPEG's numbers as
/// they are and takes no notice of the colour profile inside it — so a thumbnail left in the photo's own
/// space came out washed (Display P3, BT.2020) or flat and grey (an HDR photo or frame in HLG / PQ). HDR is
/// brought to standard range first (macOS 15+: highlights eased from HLG's 4.93× SDR white down to SDR
/// white, the screenshot mapping; before that Core Image's own conversion, which clips them).
func standardRange(_ image: CGImage) -> CGImage {
    guard let srgb = CGColorSpace(name: CGColorSpace.sRGB) else { return image }
    let name = (image.colorSpace?.name as String?) ?? ""
    if name == (CGColorSpace.sRGB as String), image.bitsPerComponent <= 8 { return image }
    var ci = CIImage(cgImage: image)
    if isHDRSpace(image.colorSpace), #available(macOS 15.0, *) {
        let tone = CIFilter.toneMapHeadroom()
        tone.inputImage = ci
        tone.sourceHeadroom = 4.93
        tone.targetHeadroom = 1
        ci = tone.outputImage ?? ci
    }
    return ciContext.createCGImage(ci, from: ci.extent, format: .RGBA8, colorSpace: srgb) ?? image
}

/// `image` as a JPEG at `out`: written beside it, then renamed, so a half-written file never shows.
func writeJPEG(_ image: CGImage, to out: String) -> Bool {
    let folder = (out as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    let part = out + ".part"
    guard let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: part) as CFURL,
                                                            UTType.jpeg.identifier as CFString, 1, nil) else {
        return false
    }
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
    guard CGImageDestinationFinalize(destination), rename(part, out) == 0 else {
        unlink(part)
        return false
    }
    return true
}

while let line = readLine(strippingNewline: true) {
    guard let data = line.data(using: .utf8),
          let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let id = request["id"] as? String,
          let path = request["path"] as? String,
          let out = request["out"] as? String else { continue }
    let px = (request["px"] as? Int) ?? 512
    let video = (request["video"] as? Bool) ?? false
    work.enter()
    DispatchQueue.global(qos: .userInitiated).async {
        defer { work.leave() }
        let ok: Bool = autoreleasepool {
            let url = URL(fileURLWithPath: path)
            guard let image = video ? videoFrame(url, px: px) : imagePreview(url, px: px) else { return false }
            return writeJPEG(standardRange(image), to: out)
        }
        reply(id, ok)
    }
}
work.wait()
