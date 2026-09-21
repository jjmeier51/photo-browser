import Foundation
import ImageIO
import CoreGraphics

/// A tiny perceptual **dHash** (difference hash) for near-duplicate image detection: images that are
/// the same picture re-encoded, resized, lightly edited or re-saved hash to the same (or very close)
/// 64-bit value, even when their bytes and exact dimensions differ — which size+dimension matching
/// misses. Pure ImageIO/CoreGraphics (no dependency), and cheap: it decodes each image once at a
/// tiny size. Runs off the main actor (call from a detached task).
enum PerceptualHash {
    /// 64-bit dHash: downscale to 9×8 grayscale, then set one bit per row for each pixel brighter
    /// than its right neighbour (8 comparisons × 8 rows). Returns nil if the image can't be decoded.
    nonisolated static func dHash(_ url: URL) -> UInt64? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 32]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }

        let w = 9, h = 8
        var buf = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.interpolationQuality = .low
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        var hash: UInt64 = 0
        var bit: UInt64 = 0
        for row in 0..<h {
            for col in 0..<(w - 1) {
                if buf[row * w + col] > buf[row * w + col + 1] { hash |= (1 << bit) }
                bit += 1
            }
        }
        return hash
    }

    /// Hamming distance between two hashes — how many of the 64 bits differ. 0 = identical look;
    /// small values (≤ ~10) mean visually the same/near-duplicate.
    nonisolated static func distance(_ a: UInt64, _ b: UInt64) -> Int { (a ^ b).nonzeroBitCount }
}
