import UIKit
import CoreImage
import CoreGraphics

/// Renders face makeup as a feathered overlay drawn from Vision face landmarks, composited over the
/// image (`FR — makeup`). The overlay is drawn in a normal SDR layer and laid over the base with
/// source-over, so an HDR base keeps its headroom everywhere except the painted makeup pixels.
///
/// Everything is on-device, landmark-anchored, and conservative; freckles use a fixed-seed PRNG so they
/// don't shimmer between renders. Applied to the primary detected face.
enum MakeupRenderer {
    static func apply(_ image: CIImage, makeup mRaw: MakeupRecipe, face: FaceLandmarks) -> CIImage {
        let m = mRaw.scaled                          // bake the overall look strength
        let e = image.extent
        guard !m.isZero, !e.isInfinite, !e.isNull, e.width >= 8, e.height >= 8 else { return image }
        let size = CGSize(width: e.width, height: e.height)
        var out = image
        // Soft pass — blush + eyeshadow, lightly feathered. (A heavy blur here is what produced the
        // earlier "big splotch", so the feather is kept modest.)
        if m.blush > 0 || m.eyeshadow > 0 {
            out = composite({ drawSoft($0, size: size, makeup: m, face: face) },
                            over: out, extent: e, feather: Double(e.width) * 0.006)
        }
        // Sharp pass — lips, liner, lashes, brows, freckles with only a light feather.
        if m.lips > 0 || m.eyeliner > 0 || m.lashes > 0 || m.brows > 0 || m.freckles > 0 {
            out = composite({ drawSharp($0, size: size, makeup: m, face: face) },
                            over: out, extent: e, feather: max(1, Double(e.width) * 0.0016))
        }
        return out
    }

    private static func composite(_ drawing: (CGContext) -> Void, over base: CIImage,
                                  extent e: CGRect, feather: Double) -> CIImage {
        let size = CGSize(width: e.width, height: e.height)
        let fmt = UIGraphicsImageRendererFormat.default(); fmt.scale = 1; fmt.opaque = false
        fmt.preferredRange = .standard   // plain sRGB overlay — no extended/wide-gamut values to skew an HDR base
        let img = UIGraphicsImageRenderer(size: size, format: fmt).image { rctx in
            drawing(rctx.cgContext)
        }
        guard let cg = img.cgImage else { return base }
        var overlay = CIImage(cgImage: cg)
        if feather > 0.5 {
            overlay = overlay.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: feather])
                .cropped(to: CGRect(origin: .zero, size: size))
        }
        overlay = overlay.transformed(by: CGAffineTransform(translationX: e.minX, y: e.minY))
        return overlay.applyingFilter("CISourceOverCompositing",
                                      parameters: [kCIInputBackgroundImageKey: base]).cropped(to: e)
    }

    // MARK: Soft pass

    private static func drawSoft(_ ctx: CGContext, size: CGSize, makeup m: MakeupRecipe, face f: FaceLandmarks) {
        let W = size.width, H = size.height
        func px(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * W, y: p.y * H) }
        func col(_ c: MakeupColor, _ a: Double) -> CGColor {
            UIColor(red: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b),
                    alpha: CGFloat(max(0, min(1, a)))).cgColor
        }
        if m.eyeshadow > 0 {
            for poly in [f.leftEyePoly, f.rightEyePoly] where poly.count >= 3 {
                let bb = bbox(poly.map(px))
                let cxp = bb.midX, cyp = bb.minY - bb.height * 0.15
                let rx = bb.width * 0.8, ry = bb.height * 1.1
                ctx.setFillColor(col(m.eyeshadowColor, m.eyeshadow * 0.75))
                ctx.fillEllipse(in: CGRect(x: cxp - rx, y: cyp - ry, width: rx * 2, height: ry * 2))
            }
        }
        if m.blush > 0 {
            for cheek in [f.cheekL, f.cheekR] where cheek != nil {
                radial(ctx, center: px(cheek!), radius: max(8, W * 0.07), color: col(m.blushColor, m.blush * 0.62))
            }
        }
    }

    // MARK: Sharp pass

    private static func drawSharp(_ ctx: CGContext, size: CGSize, makeup m: MakeupRecipe, face f: FaceLandmarks) {
        let W = size.width, H = size.height
        func px(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * W, y: p.y * H) }
        func col(_ c: MakeupColor, _ a: Double) -> CGColor {
            UIColor(red: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b),
                    alpha: CGFloat(max(0, min(1, a)))).cgColor
        }
        let faceH = CGFloat(max(0.1, f.height)) * H

        if m.brows > 0 {
            for poly in [f.leftBrowPoly, f.rightBrowPoly] where poly.count >= 2 {
                stroke(ctx, poly.map(px), color: col(MakeupColor(0.24, 0.16, 0.10), m.brows * 0.5),
                       width: faceH * 0.035)
            }
        }
        if m.lashes > 0 {
            for poly in [f.leftEyePoly, f.rightEyePoly] where poly.count >= 4 {
                let bb = bbox(poly.map(px))
                let line = upperLid(poly.map(px)).map { CGPoint(x: $0.x, y: $0.y - bb.height * 0.08) }
                stroke(ctx, line, color: col(MakeupColor(0.05, 0.04, 0.04), m.lashes * 0.7), width: bb.height * 0.11)
            }
        }
        if m.eyeliner > 0 {
            for poly in [f.leftEyePoly, f.rightEyePoly] where poly.count >= 4 {
                let pts = poly.map(px); let bb = bbox(pts)
                var line = upperLid(pts)
                if line.count >= 2, let last = line.last, let prev = line.dropLast().last {
                    let dx = last.x - prev.x, dy = last.y - prev.y, len = max(1, hypot(dx, dy))
                    line.append(CGPoint(x: last.x + dx / len * bb.width * 0.22,
                                        y: last.y + dy / len * bb.width * 0.22 - bb.height * 0.12))   // wing up/out
                }
                stroke(ctx, line, color: col(MakeupColor(0.04, 0.03, 0.03), m.eyeliner), width: bb.height * 0.15)
            }
        }
        if m.lips > 0, f.outerLips.count >= 3 {
            let path = CGMutablePath()
            addPoly(path, f.outerLips.map(px))
            if f.innerLips.count >= 3 { addPoly(path, f.innerLips.map(px)) }
            ctx.addPath(path)
            ctx.setFillColor(col(m.lipsColor, m.lips * 0.92))   // strong (so a 100% dark look reads as black lips)
            ctx.fillPath(using: .evenOdd)
        }
        // Freckles — many *tiny, soft-edged, warm* specks, biased to the nose/cheek band the way real
        // freckles cluster (densest over the nose bridge and upper cheeks, sparser toward the hairline and
        // jaw). Each is a soft radial dab — not a hard brown dot — with per-speck size/opacity/hue jitter,
        // so the result reads as pigment rather than painted spots. Level 5 visibly covers the face.
        if m.freckles > 0, let center = f.center {
            let counts = [0, 110, 240, 430, 680, 980]
            let n = counts[min(5, max(0, m.freckles))]
            let fcx = center.x * W, fcy = center.y * H
            let frx = CGFloat(max(0.08, f.width)) * W * 0.50
            let fry = CGFloat(max(0.10, f.height)) * H * 0.58
            let bandY = (f.nose?.y).map { $0 * H } ?? fcy        // dense band centred on the nose
            let browY = f.browY.map { CGFloat($0) * H } ?? (fcy - fry * 0.4)
            let eyes = [f.leftEye, f.rightEye].compactMap { $0 }.map(px)
            let lipsPx = f.outerLips.map(px)
            let eyeExclude = max(W * 0.035, CGFloat(f.eyeRadius) * W * 1.6)
            var rng = LCG(seed: 0x9E3779B97F4A7C15)
            var placed = 0, tries = 0
            while placed < n && tries < n * 20 {
                tries += 1
                // Uniform sample inside the face ellipse (polar with sqrt for even area density).
                let ang = rng.next() * 2 * Double.pi
                let rad = rng.next().squareRoot()
                let p = CGPoint(x: fcx + CGFloat(cos(ang) * rad) * frx,
                                y: fcy + CGFloat(sin(ang) * rad) * fry)
                // Vertical density bias: keep more near the nose/cheek band, fewer toward forehead/jaw.
                let vDist = Double(abs(p.y - bandY) / max(1, fry))
                if rng.next() > max(0.18, 1 - vDist * vDist * 0.9) { continue }
                if p.y < browY - fry * 0.05, rng.next() > 0.25 { continue }   // sparse above the brows
                if eyes.contains(where: { hypot($0.x - p.x, $0.y - p.y) < eyeExclude }) { continue }
                if !lipsPx.isEmpty, pointInPolygon(p, lipsPx) { continue }
                // Mostly very small with the occasional larger one; soft alpha; warm reddish-tan with jitter.
                let big = rng.next() < 0.12
                let dot = W * (big ? 0.0016 : 0.0009) * CGFloat(0.7 + rng.next() * 0.8)
                let alpha = (big ? 0.30 : 0.22) + rng.next() * 0.22
                let warm = rng.next()
                let speck = UIColor(red: CGFloat(0.50 + warm * 0.18), green: CGFloat(0.30 + warm * 0.10),
                                    blue: CGFloat(0.20 + warm * 0.06), alpha: CGFloat(alpha)).cgColor
                softSpeck(ctx, center: p, radius: dot, color: speck)
                placed += 1
            }
        }
    }

    /// A single freckle: a radial dab whose centre is near-solid and whose edge fades to transparent, so it
    /// reads as soft pigment instead of a hard dot.
    private static func softSpeck(_ ctx: CGContext, center: CGPoint, radius: CGFloat, color: CGColor) {
        guard radius > 0.3, let clear = color.copy(alpha: 0) else { return }
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let grad = CGGradient(colorsSpace: cs, colors: [color, color, clear] as CFArray,
                                    locations: [0, 0.45, 1]) else { return }
        ctx.drawRadialGradient(grad, startCenter: center, startRadius: 0,
                               endCenter: center, endRadius: radius, options: [])
    }

    // MARK: Helpers

    private static func radial(_ ctx: CGContext, center: CGPoint, radius: CGFloat, color: CGColor) {
        guard let clear = color.copy(alpha: 0) else { return }
        let cs = CGColorSpaceCreateDeviceRGB()
        let locations: [CGFloat] = [0, 1]
        guard let grad = CGGradient(colorsSpace: cs, colors: [color, clear] as CFArray,
                                    locations: locations) else { return }
        ctx.saveGState()
        ctx.drawRadialGradient(grad, startCenter: center, startRadius: 0,
                               endCenter: center, endRadius: radius, options: [])
        ctx.restoreGState()
    }

    private static func stroke(_ ctx: CGContext, _ pts: [CGPoint], color: CGColor, width: CGFloat) {
        guard pts.count >= 2, width > 0 else { return }
        ctx.setStrokeColor(color); ctx.setLineWidth(width)
        ctx.setLineCap(.round); ctx.setLineJoin(.round)
        ctx.beginPath(); ctx.move(to: pts[0])
        for p in pts.dropFirst() { ctx.addLine(to: p) }
        ctx.strokePath()
    }

    private static func addPoly(_ path: CGMutablePath, _ pts: [CGPoint]) {
        guard pts.count >= 2 else { return }
        path.move(to: pts[0])
        for p in pts.dropFirst() { path.addLine(to: p) }
        path.closeSubpath()
    }

    private static func bbox(_ pts: [CGPoint]) -> CGRect {
        guard !pts.isEmpty else { return .zero }
        let xs = pts.map(\.x), ys = pts.map(\.y)
        let minX = xs.min()!, maxX = xs.max()!, minY = ys.min()!, maxY = ys.max()!
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Upper-lid points of an eye polygon (top-left coords → smaller y is higher), left→right.
    private static func upperLid(_ pts: [CGPoint]) -> [CGPoint] {
        guard !pts.isEmpty else { return [] }
        let cy = pts.reduce(0) { $0 + $1.y } / CGFloat(pts.count)
        return pts.filter { $0.y <= cy }.sorted { $0.x < $1.x }
    }

    private static func pointInPolygon(_ p: CGPoint, _ poly: [CGPoint]) -> Bool {
        guard poly.count >= 3 else { return false }
        var inside = false, j = poly.count - 1
        for i in 0..<poly.count {
            let a = poly[i], b = poly[j]
            if (a.y > p.y) != (b.y > p.y),
               p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }

    /// Small fixed-seed PRNG so freckles are stable across renders.
    private struct LCG {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(UInt64(1) << 53)
        }
    }
}
