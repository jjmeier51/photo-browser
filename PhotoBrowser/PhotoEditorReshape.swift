import UIKit
import CoreImage
import CoreGraphics

/// Renders the manual-reshape mesh (`ReshapeField`) into a warped image for `FR-RESH-01`.
///
/// Implementation note: this is a **piecewise-affine mesh warp** done in Core Graphics, deliberately
/// *not* a Metal kernel. Each grid cell is split into two triangles; the source triangle is mapped to
/// its displaced destination triangle with an exact affine transform (3 points fully determine one) and
/// clipped to that triangle. The union of destination triangles tiles the frame, so coverage is
/// complete and there are no gaps. The outer ring of vertices is pinned (never displaced) so the image
/// edges stay put and the canvas is always fully covered. Pure CG keeps it portable and build-safe; the
/// per-triangle cost sums to roughly one full rasterization, so it stays fast on the preview proxy and
/// is run off the main actor for full-res export.
enum ReshapeWarp {
    /// Warps `image` by `field`. Works entirely in the rasterized bitmap's bottom-left pixel space.
    /// When `hdr` is set, the raster is 16-bit float in extended-linear Display P3 so HDR headroom and
    /// wide gamut survive the warp (an 8-bit raster would silently flatten HDR to SDR).
    static func apply(_ image: CIImage, field: ReshapeField, hdr: Bool = false) -> CIImage {
        let e = image.extent
        guard !e.isInfinite, !e.isNull, e.width >= 2, e.height >= 2 else { return image }

        // Choose the raster precision/space: float wide-gamut for HDR, 8-bit device RGB otherwise.
        let space: CGColorSpace
        let bitsPerComponent: Int
        let bitmapInfo: UInt32
        let ciFormat: CIFormat
        if hdr, let ext = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) {
            space = ext
            bitsPerComponent = 16
            bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
            ciFormat = .RGBAh
        } else {
            space = CGColorSpaceCreateDeviceRGB()
            bitsPerComponent = 8
            bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
            ciFormat = .RGBA8
        }

        guard let cg = PhotoEditorIO.context.createCGImage(image, from: e, format: ciFormat, colorSpace: space)
        else { return image }

        let W = CGFloat(cg.width), H = CGFloat(cg.height)
        let cols = field.cols, rows = field.rows
        guard cols >= 3, rows >= 3,
              field.dx.count == cols * rows, field.dy.count == cols * rows else { return image }

        // A raw bitmap context draws a CGImage upright in bottom-left coordinates (no UIKit flip).
        guard let ctx = CGContext(data: nil, width: cg.width, height: cg.height,
                                  bitsPerComponent: bitsPerComponent, bytesPerRow: 0, space: space,
                                  bitmapInfo: bitmapInfo) else { return image }
        ctx.interpolationQuality = .high
        ctx.setShouldAntialias(false)      // sharp triangle edges → adjacent cells meet with no seam

        // Source vertex in bottom-left pixels; v runs top→bottom so y is flipped.
        func src(_ i: Int, _ j: Int) -> CGPoint {
            CGPoint(x: CGFloat(i) / CGFloat(cols - 1) * W,
                    y: (1 - CGFloat(j) / CGFloat(rows - 1)) * H)
        }
        // Displaced vertex; the outer ring is pinned. dy is top-down, so it subtracts in bottom-left y.
        func dst(_ i: Int, _ j: Int) -> CGPoint {
            let s = src(i, j)
            if i == 0 || i == cols - 1 || j == 0 || j == rows - 1 { return s }
            let idx = j * cols + i
            return CGPoint(x: s.x + CGFloat(field.dx[idx]) * W,
                           y: s.y - CGFloat(field.dy[idx]) * H)
        }

        let full = CGRect(x: 0, y: 0, width: W, height: H)
        for j in 0..<(rows - 1) {
            for i in 0..<(cols - 1) {
                let s00 = src(i, j),   s10 = src(i + 1, j)
                let s11 = src(i + 1, j + 1), s01 = src(i, j + 1)
                let d00 = dst(i, j),   d10 = dst(i + 1, j)
                let d11 = dst(i + 1, j + 1), d01 = dst(i, j + 1)
                drawTriangle(ctx, cg, s00, s10, s11, d00, d10, d11, full)
                drawTriangle(ctx, cg, s00, s11, s01, d00, d11, d01, full)
            }
        }
        guard let out = ctx.makeImage() else { return image }
        return CIImage(cgImage: out)
    }

    private static func drawTriangle(_ ctx: CGContext, _ img: CGImage,
                                     _ s0: CGPoint, _ s1: CGPoint, _ s2: CGPoint,
                                     _ d0: CGPoint, _ d1: CGPoint, _ d2: CGPoint,
                                     _ full: CGRect) {
        guard let t = affine(s0, s1, s2, d0, d1, d2) else { return }
        ctx.saveGState()
        ctx.beginPath()
        ctx.move(to: d0); ctx.addLine(to: d1); ctx.addLine(to: d2); ctx.closePath()
        ctx.clip()
        ctx.concatenate(t)
        ctx.draw(img, in: full)
        ctx.restoreGState()
    }

    /// The affine transform taking the source triangle onto the destination triangle (nil if the source
    /// triangle is degenerate). Derived from the standard barycentric solution for 3→3 point mapping.
    private static func affine(_ s0: CGPoint, _ s1: CGPoint, _ s2: CGPoint,
                               _ d0: CGPoint, _ d1: CGPoint, _ d2: CGPoint) -> CGAffineTransform? {
        let den = s0.x * (s1.y - s2.y) + s1.x * (s2.y - s0.y) + s2.x * (s0.y - s1.y)
        guard abs(den) > 1e-6 else { return nil }
        let a = (d0.x * (s1.y - s2.y) + d1.x * (s2.y - s0.y) + d2.x * (s0.y - s1.y)) / den
        let b = (d0.y * (s1.y - s2.y) + d1.y * (s2.y - s0.y) + d2.y * (s0.y - s1.y)) / den
        let c = (d0.x * (s2.x - s1.x) + d1.x * (s0.x - s2.x) + d2.x * (s1.x - s0.x)) / den
        let d = (d0.y * (s2.x - s1.x) + d1.y * (s0.x - s2.x) + d2.y * (s1.x - s0.x)) / den
        let tx = (d0.x * (s1.x * s2.y - s2.x * s1.y) + d1.x * (s2.x * s0.y - s0.x * s2.y) + d2.x * (s0.x * s1.y - s1.x * s0.y)) / den
        let ty = (d0.y * (s1.x * s2.y - s2.x * s1.y) + d1.y * (s2.x * s0.y - s0.x * s2.y) + d2.y * (s0.x * s1.y - s1.x * s0.y)) / den
        return CGAffineTransform(a: a, b: b, c: c, d: d, tx: tx, ty: ty)
    }
}
