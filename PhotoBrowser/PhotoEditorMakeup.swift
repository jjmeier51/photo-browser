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
        // Sharp pass — lips, liner, lashes, brows with only a light feather.
        if m.lips > 0 || m.eyeliner > 0 || m.lashes > 0 || m.brows > 0 {
            out = composite({ drawSharp($0, size: size, makeup: m, face: face) },
                            over: out, extent: e, feather: max(1, Double(e.width) * 0.0016))
        }
        // Freckle pass — drawn crisp (no extra blur) so the tiny specks stay defined, not washed out.
        if m.freckles > 0 {
            out = composite({ drawFreckles($0, size: size, makeup: m, face: face) },
                            over: out, extent: e, feather: 0)
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
            // Define/fill the brows: a bold dark stroke along the brow. Fall back to a line above the eye
            // when Vision returns a sparse eyebrow region (so it always does *something* visible).
            for (poly, eye) in [(f.leftBrowPoly, f.leftEye), (f.rightBrowPoly, f.rightEye)] {
                let line: [CGPoint]
                if poly.count >= 2 { line = poly.map(px) }
                else if let eye { let e = px(eye); let r = CGFloat(f.eyeRadius) * W
                    line = [CGPoint(x: e.x - r * 1.3, y: e.y - r * 1.5), CGPoint(x: e.x, y: e.y - r * 1.9),
                            CGPoint(x: e.x + r * 1.3, y: e.y - r * 1.5)] }
                else { continue }
                stroke(ctx, line, color: col(MakeupColor(0.18, 0.12, 0.08), min(1, m.brows * 0.9)),
                       width: faceH * 0.05)
            }
        }
        if m.lashes > 0 {
            // A bold dark lash line along the upper lid with a slight outward wing.
            for (poly, eye) in [(f.leftEyePoly, f.leftEye), (f.rightEyePoly, f.rightEye)] {
                var line: [CGPoint]
                var thick: CGFloat
                if poly.count >= 4 {
                    let pts = poly.map(px); let bb = bbox(pts)
                    line = upperLid(pts).map { CGPoint(x: $0.x, y: $0.y - bb.height * 0.06) }
                    thick = max(2, bb.height * 0.22)
                } else if let eye {
                    let e = px(eye); let r = CGFloat(f.eyeRadius) * W
                    line = [CGPoint(x: e.x - r, y: e.y - r * 0.4), CGPoint(x: e.x, y: e.y - r * 0.7),
                            CGPoint(x: e.x + r, y: e.y - r * 0.4)]
                    thick = max(2, r * 0.4)
                } else { continue }
                if line.count >= 2, let last = line.last, let prev = line.dropLast().last {  // outward wing
                    let dx = last.x - prev.x, dy = last.y - prev.y, len = max(1, hypot(dx, dy))
                    line.append(CGPoint(x: last.x + dx / len * thick * 1.6, y: last.y + dy / len * thick * 1.6 - thick))
                }
                stroke(ctx, line, color: col(MakeupColor(0.04, 0.03, 0.04), min(1, m.lashes * 0.95)), width: thick)
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
    }

    /// Freckles — small, defined, dark reddish-brown specks **clustered on the nose bridge and both
    /// cheeks**, where real freckles concentrate. The earlier version scattered them across the whole face
    /// bounding-box ellipse, which on a tilted/cropped face spilled down onto the jaw and neck and looked
    /// off-centre; anchoring to the actual nose/cheek landmarks keeps them on the face and symmetric. They
    /// are rendered crisp (own no-blur pass) and fairly dark so they read like real pigment.
    private static func drawFreckles(_ ctx: CGContext, size: CGSize, makeup m: MakeupRecipe, face f: FaceLandmarks) {
        guard m.freckles > 0 else { return }
        let W = size.width, H = size.height
        func px(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * W, y: p.y * H) }
        let counts = [0, 90, 200, 340, 520, 760]
        let n = counts[min(5, max(0, m.freckles))]
        let faceW = CGFloat(max(0.08, f.width)) * W
        let sig = faceW * 0.13                                // cluster spread
        // Anchors with a weight and an elliptical spread (nose narrower/taller, cheeks rounder).
        var anchors: [(p: CGPoint, weight: Double, sx: CGFloat, sy: CGFloat)] = []
        if let nose = f.nose { anchors.append((px(nose), 0.8, sig * 0.7, sig * 1.2)) }
        if let cl = f.cheekL { anchors.append((px(cl), 1.0, sig * 1.05, sig * 1.1)) }
        if let cr = f.cheekR { anchors.append((px(cr), 1.0, sig * 1.05, sig * 1.1)) }
        if anchors.isEmpty, let c = f.center { anchors.append((px(c), 1.0, faceW * 0.3, faceW * 0.3)) }
        let totalW = anchors.reduce(0) { $0 + $1.weight }
        guard totalW > 0 else { return }
        let eyes = [f.leftEye, f.rightEye].compactMap { $0 }.map(px)
        let lipsPx = f.outerLips.map(px)
        let eyeExclude = max(W * 0.03, CGFloat(f.eyeRadius) * W * 1.3)
        var rng = LCG(seed: 0x9E3779B97F4A7C15)
        var placed = 0, tries = 0
        while placed < n && tries < n * 25 {
            tries += 1
            // Pick an anchor by weight, then a bounded triangular (≈Gaussian) offset around it.
            var pick = rng.next() * totalW, idx = 0
            for (i, a) in anchors.enumerated() { if pick < a.weight { idx = i; break }; pick -= a.weight }
            let a = anchors[idx]
            let gx = rng.next() + rng.next() - 1.0               // −1…1, peaked at 0
            let gy = rng.next() + rng.next() - 1.0
            let p = CGPoint(x: a.p.x + CGFloat(gx) * a.sx * 1.7, y: a.p.y + CGFloat(gy) * a.sy * 1.7)
            if eyes.contains(where: { hypot($0.x - p.x, $0.y - p.y) < eyeExclude }) { continue }
            if !lipsPx.isEmpty, pointInPolygon(p, lipsPx) { continue }
            // Tiny (occasionally a touch bigger), dark reddish-brown, fairly opaque, with per-speck jitter.
            let big = rng.next() < 0.10
            let dot = W * (big ? 0.0011 : 0.00060) * CGFloat(0.6 + rng.next() * 0.6)
            let alpha = (big ? 0.62 : 0.74) + rng.next() * 0.18
            let warm = rng.next()
            let speck = UIColor(red: CGFloat(0.33 + warm * 0.13), green: CGFloat(0.18 + warm * 0.06),
                                blue: CGFloat(0.10 + warm * 0.04), alpha: CGFloat(min(0.95, alpha))).cgColor
            softSpeck(ctx, center: p, radius: dot, color: speck)
            placed += 1
        }
    }

    /// A single freckle: a radial dab whose centre is near-solid and whose edge fades to transparent, so it
    /// reads as soft pigment instead of a hard dot.
    private static func softSpeck(_ ctx: CGContext, center: CGPoint, radius: CGFloat, color: CGColor) {
        let r = max(0.6, radius)
        guard let clear = color.copy(alpha: 0) else { return }
        let cs = CGColorSpaceCreateDeviceRGB()
        // A mostly-solid core that fades only at the very edge, so even tiny specks read as defined pigment.
        guard let grad = CGGradient(colorsSpace: cs, colors: [color, color, clear] as CFArray,
                                    locations: [0, 0.6, 1]) else { return }
        ctx.drawRadialGradient(grad, startCenter: center, startRadius: 0,
                               endCenter: center, endRadius: r, options: [])
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
