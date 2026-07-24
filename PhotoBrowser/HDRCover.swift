import UIKit
import CoreImage
import AVFoundation
import ImageIO

/// Renders a "Use as Album Cover" crop in HDR when the source content is HDR. The cropper UI
/// works on an SDR preview; this re-derives the same square from the original media — the photo
/// file expanded to HDR (gain map applied), or the video frame at the captured player time read
/// 10-bit — and encodes a 10-bit HDR HEIC, mirroring the app's other HDR-preserving paths
/// (`MediaEditing.applyPhotoHDRInPlace`, `FileActions.encodeFrame`). Returns nil for SDR sources
/// or on any failure, and the caller falls back to the existing SDR JPEG cover.
enum HDRCover {
    /// `region` is the crop square in normalized (0–1) top-left-origin coordinates of the
    /// upright image (as the cropper showed it). `videoTime` is the player time of the frame
    /// the user cropped (videos only).
    nonisolated static func render(entry: Entry, region: CGRect?, videoTime: Double?) async -> Data? {
        guard let region else { return nil }
        return await Task.detached(priority: .userInitiated) { () -> Data? in
            switch entry.kind {
            case .image: return photoCover(url: entry.url, region: region)
            case .video: return await videoCover(url: entry.url, region: region, at: videoTime ?? 0)
            default:     return nil
            }
        }.value
    }

    nonisolated private static func photoCover(url: URL, region: CGRect) -> Data? {
        guard let ci = CIImage(contentsOf: url, options: [.expandToHDR: true]) else { return nil }
        let src = CGImageSourceCreateWithURL(url as CFURL, nil)
        // Only worth a 10-bit cover when the image actually carries HDR. `contentHeadroom` is
        // iOS 18+ (deployment target is 17): on 17, fall back to checking for a gain map.
        let isHDR: Bool
        if #available(iOS 18.0, *) {
            isHDR = ci.contentHeadroom > 1.01
        } else {
            isHDR = src.map { CGImageSourceCopyAuxiliaryDataInfoAtIndex($0, 0, kCGImageAuxiliaryDataTypeHDRGainMap) != nil } ?? false
        }
        guard isHDR else { return nil }
        let props = src.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] } ?? [:]
        let orientation = Int32((props[kCGImagePropertyOrientation] as? UInt32) ?? 1)
        let upright = ci.oriented(forExifOrientation: orientation)
        return encodeCrop(upright, region: region, fallbackSpace: ci.colorSpace)
    }

    nonisolated private static func videoCover(url: URL, region: CGRect, at seconds: Double) async -> Data? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              ((try? await track.load(.mediaCharacteristics))?.contains(.containsHDRVideo)) == true else {
            return nil
        }
        let transform = (try? await track.load(.preferredTransform)) ?? .identity
        // AVAssetImageGenerator tone-maps to SDR — read the exact frame 10-bit instead.
        guard let reader = try? AVAssetReader(asset: asset) else { return nil }
        reader.timeRange = CMTimeRange(start: CMTime(seconds: max(0, seconds), preferredTimescale: 600),
                                       duration: CMTime(seconds: 1, preferredTimescale: 600))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }
        defer { reader.cancelReading() }
        guard let sample = output.copyNextSampleBuffer(),
              let pb = CMSampleBufferGetImageBuffer(sample) else { return nil }
        var ci = CIImage(cvImageBuffer: pb)
        if !transform.isIdentity {
            // CIImage is Y-up but the video transform is Y-down — conjugate (see encodeFrame).
            var t = transform
            t.b = -t.b
            t.c = -t.c
            ci = ci.transformed(by: t)
            ci = ci.transformed(by: CGAffineTransform(translationX: -ci.extent.origin.x,
                                                      y: -ci.extent.origin.y))
        }
        return encodeCrop(ci, region: region, fallbackSpace: ci.colorSpace)
    }

    /// Apply the normalized top-left-origin crop (converted to CIImage's Y-up space) and encode
    /// a 10-bit HEIC in an HDR color space.
    nonisolated private static func encodeCrop(_ image: CIImage, region: CGRect, fallbackSpace: CGColorSpace?) -> Data? {
        let img = atOrigin(image)
        let w = img.extent.width, h = img.extent.height
        guard w > 0, h > 0 else { return nil }
        let rect = CGRect(x: region.minX * w,
                          y: (1 - region.minY - region.height) * h,     // top-left → Y-up
                          width: region.width * w, height: region.height * h).integral
        let clamped = rect.intersection(img.extent)
        guard !clamped.isNull, !clamped.isEmpty else { return nil }
        let cropped = atOrigin(img.cropped(to: clamped))
        let ctx = CIContext()
        let outSpace = CGColorSpace(name: CGColorSpace.displayP3_PQ) ?? fallbackSpace ?? CGColorSpaceCreateDeviceRGB()
        return try? ctx.heif10Representation(of: cropped, colorSpace: outSpace, options: [:])
    }

    nonisolated private static func atOrigin(_ ci: CIImage) -> CIImage {
        ci.transformed(by: CGAffineTransform(translationX: -ci.extent.origin.x, y: -ci.extent.origin.y))
    }
}
