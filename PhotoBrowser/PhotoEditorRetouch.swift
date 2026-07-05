import UIKit
import CoreImage

/// One brushed retouch stroke: a polyline (normalized, top-left) and a brush radius (fraction of image
/// width). Strokes are stored so the mask can be rebuilt at any resolution (proxy preview vs full-res
/// save).
struct RetouchStroke: Sendable {
    let points: [CGPoint]
    let radius: CGFloat
}

enum RetouchMask {
    /// A black/white removal mask (white = remove) at `size`, painted from the strokes.
    static func image(for strokes: [RetouchStroke], size: CGSize) -> CIImage? {
        guard !strokes.isEmpty, size.width >= 2, size.height >= 2 else { return nil }
        let fmt = UIGraphicsImageRendererFormat.default(); fmt.scale = 1; fmt.opaque = true
        let img = UIGraphicsImageRenderer(size: size, format: fmt).image { rctx in
            let ctx = rctx.cgContext
            ctx.setFillColor(UIColor.black.cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
            ctx.setStrokeColor(UIColor.white.cgColor); ctx.setFillColor(UIColor.white.cgColor)
            ctx.setLineCap(.round); ctx.setLineJoin(.round)
            for s in strokes {
                let pts = s.points.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
                let w = max(2, s.radius * size.width * 2)
                guard let first = pts.first else { continue }
                if pts.count == 1 {
                    ctx.fillEllipse(in: CGRect(x: first.x - w / 2, y: first.y - w / 2, width: w, height: w))
                } else {
                    ctx.setLineWidth(w)
                    ctx.beginPath(); ctx.move(to: first)
                    for p in pts.dropFirst() { ctx.addLine(to: p) }
                    ctx.strokePath()
                }
            }
        }
        return img.cgImage.map { CIImage(cgImage: $0) }
    }
}

/// On-device "magic" object removal, done the way TouchRetouch and Photoshop's Content-Aware Fill
/// do it: **exemplar-based patch synthesis**. Real 9×9 patches of the surrounding image are copied
/// into the hole (best-match search, onion-peel fill order, locality bias), so the fill carries
/// genuine texture and structure instead of the fuzzy grey average a diffusion fill produces. The
/// synthesis runs on the CPU inside a working window around the mask (resolution-capped, so it's
/// fast at any image size), and only the masked region plus a feathered seam is composited back —
/// every other pixel is the untouched original. Degenerate cases (mask covering most of the image,
/// render failures) fall back to the old diffusion fill rather than failing.
///
/// When a CoreML inpainting model is bundled (see `MLInpainter` / `docs/ml-inpainting.md`) it runs
/// first: a generative LaMa-class network understands structure (railings, skin, fabric) that patch
/// copying can only approximate. Any failure there falls straight through to exemplar synthesis, so
/// the model is a pure upgrade, never a dependency.
enum ObjectRemoval {
    static func inpaint(_ image: CIImage, mask: CIImage) -> CIImage {
        let e = image.extent
        guard e.width >= 4, e.height >= 4 else { return image }
        let m = alignMask(mask, to: e)
        guard let bbox = maskBounds(of: m, extent: e) else { return image }   // empty mask
        if let out = mlFill(image, mask: m, extent: e, bbox: bbox) { return out }
        if let out = exemplarFill(image, mask: m, extent: e, bbox: bbox) { return out }
        return diffusionFill(image, mask: m, extent: e)
    }

    // MARK: - ML inpainting (tier 1, only when a model is bundled)

    private static func mlFill(_ image: CIImage, mask m: CIImage, extent e: CGRect, bbox: CGRect) -> CIImage? {
        guard MLInpainter.shared.isAvailable else { return nil }
        // Window: generous context around the hole, grown toward the model's native
        // input size so small strokes aren't upscaled into a fixed 512² input (which
        // would soften the fill against its full-res surroundings).
        let margin = max(max(bbox.width, bbox.height), 96)
        var win = bbox.insetBy(dx: -margin, dy: -margin)
        let minSide: CGFloat = 512
        if win.width < minSide { win = win.insetBy(dx: -(minSide - win.width) / 2, dy: 0) }
        if win.height < minSide { win = win.insetBy(dx: 0, dy: -(minSide - win.height) / 2) }
        win = win.intersection(e).integral
        guard win.width >= 32, win.height >= 32 else { return nil }
        let shift = CGAffineTransform(translationX: -win.minX, y: -win.minY)
        guard let filled = MLInpainter.shared.fill(
            window: image.cropped(to: win).transformed(by: shift),
            mask: m.cropped(to: win).transformed(by: shift),
            context: PhotoEditorIO.context) else { return nil }
        let placed = filled.transformed(by: CGAffineTransform(translationX: win.minX, y: win.minY))
        return compositeHole(placed, over: image, mask: m, extent: e)
    }

    // MARK: - Exemplar synthesis

    private static let patch = 9        // odd; 9 balances texture fidelity vs. search cost
    private static let half = 4

    /// Bounding box of the white (remove) area of the mask, in image coordinates, measured on a
    /// small probe raster. Nil when the mask is empty; the full extent when the probe can't render
    /// (better to hand downstream tiers an oversized window than to skip the removal).
    private static func maskBounds(of m: CIImage, extent e: CGRect) -> CGRect? {
        let probeLong = 256.0
        let ps = min(1.0, probeLong / Double(max(e.width, e.height)))
        let pw = max(1, Int((Double(e.width) * ps).rounded()))
        let ph = max(1, Int((Double(e.height) * ps).rounded()))
        let maskAtOrigin = m.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
        guard let probe = rasterize(maskAtOrigin.transformed(by: CGAffineTransform(scaleX: CGFloat(ps), y: CGFloat(ps))),
                                    w: pw, h: ph) else { return e }
        var minPX = Int.max, minPY = Int.max, maxPX = -1, maxPY = -1
        for y in 0..<ph {
            for x in 0..<pw where probe[(y * pw + x) * 4] > 32 {
                if x < minPX { minPX = x }; if x > maxPX { maxPX = x }
                if y < minPY { minPY = y }; if y > maxPY { maxPY = y }
            }
        }
        guard maxPX >= 0 else { return nil }                 // empty mask — nothing to remove
        // Probe rows are top-down; convert to CI coordinates (bottom-up).
        return CGRect(x: e.minX + CGFloat(Double(minPX) / ps),
                      y: e.maxY - CGFloat(Double(maxPY + 1) / ps),
                      width: CGFloat(Double(maxPX - minPX + 1) / ps),
                      height: CGFloat(Double(maxPY - minPY + 1) / ps))
    }

    private static func exemplarFill(_ image: CIImage, mask m: CIImage, extent e: CGRect, bbox: CGRect) -> CIImage? {
        // --- 1. Working window: the mask bbox expanded by its own size on every side
        //        so the window holds plenty of source texture, clamped to the image ---
        let bw = bbox.width, bh = bbox.height
        let margin = max(max(bw, bh), CGFloat(48))
        let roi = bbox.insetBy(dx: -margin, dy: -margin).intersection(e).integral
        guard roi.width >= CGFloat(patch * 3), roi.height >= CGFloat(patch * 3) else { return nil }

        // --- 2. Working rasters (image + mask) at adaptive resolution ---
        // Small removals (an earring, a blemish) run at (near-)native resolution — a
        // fixed cap upscaled the synthesized window and printed visible square patch
        // seams. Bigger masks scale down so the fill stays fast.
        let maskLong = Double(max(bw, bh))
        let roiLong = Double(max(roi.width, roi.height))
        let ws = min(1.0, min(320.0 / max(maskLong, 1.0), 896.0 / roiLong))
        let w = max(patch * 3, Int((Double(roi.width) * ws).rounded()))
        let h = max(patch * 3, Int((Double(roi.height) * ws).rounded()))
        func working(_ ci: CIImage) -> CIImage {
            ci.cropped(to: roi)
                .transformed(by: CGAffineTransform(translationX: -roi.minX, y: -roi.minY))
                .transformed(by: CGAffineTransform(scaleX: CGFloat(w) / roi.width, y: CGFloat(h) / roi.height))
        }
        guard var rgba = rasterize(working(image), w: w, h: h),
              let maskBuf = rasterize(working(m), w: w, h: h) else { return nil }

        // --- 3. Unknown map, dilated 3px so the stroke's anti-aliased rim (still
        //        holding object colour — the classic leftover-sliver source) can't
        //        seed the fill or survive it ---
        let total = w * h
        var raw = [Bool](repeating: false, count: total)
        for i in 0..<total { raw[i] = maskBuf[i * 4] > 64 }
        let rawSum = integral(raw, w: w, h: h)
        var needs = [Bool](repeating: false, count: total)
        var unknownCount = 0
        for y in 0..<h {
            for x in 0..<w where rectSum(rawSum, w: w, h: h, x - 3, y - 3, x + 3, y + 3) > 0 {
                needs[y * w + x] = true; unknownCount += 1
            }
        }
        guard unknownCount > 0 else { return image }
        guard unknownCount < total / 2 else { return nil }   // hole too big for exemplar quality

        // --- 4. Source-patch candidates: centers whose full patch is originally known ---
        let unknownSum = integral(needs, w: w, h: h)
        var candidates: [Int] = []
        var stride = 2
        while true {
            candidates.removeAll(keepingCapacity: true)
            var y = half
            while y <= h - 1 - half {
                var x = half
                while x <= w - 1 - half {
                    if rectSum(unknownSum, w: w, h: h, x - half, y - half, x + half, y + half) == 0 {
                        candidates.append(y * w + x)
                    }
                    x += stride
                }
                y += stride
            }
            if candidates.count <= 3500 || stride >= 16 { break }
            stride *= 2
        }
        guard candidates.count >= 8 else { return nil }

        // --- 5. Onion-peel fill: highest-confidence boundary patches first, each
        //        filled from its best-matching (SSD over known pixels, locality-
        //        biased) source patch ---
        var remaining = unknownCount
        var synth = [Bool](repeating: false, count: total)   // synthesized (vs originally known)
        var rings = 0
        while remaining > 0 {
            rings += 1
            if rings > 600 { return nil }                    // safety valve → diffusion fallback
            let needsSum = integral(needs, w: w, h: h)
            var targets: [(score: Int, idx: Int)] = []
            for y in 0..<h {
                for x in 0..<w {
                    let i = y * w + x
                    guard needs[i] else { continue }
                    let onBoundary = (x > 0 && !needs[i - 1]) || (x < w - 1 && !needs[i + 1])
                        || (y > 0 && !needs[i - w]) || (y < h - 1 && !needs[i + w])
                    guard onBoundary else { continue }
                    let known = patch * patch - rectSum(needsSum, w: w, h: h, x - half, y - half, x + half, y + half)
                    targets.append((known, i))
                }
            }
            if targets.isEmpty { return nil }
            targets.sort { $0.score > $1.score }

            for t in targets {
                guard needs[t.idx] else { continue }          // an earlier patch already filled it
                let tx = t.idx % w, ty = t.idx / w
                let cx = min(max(tx, half), w - 1 - half)
                let cy = min(max(ty, half), h - 1 - half)
                var bestCost = Int.max
                var bestIdx = -1
                for c in candidates {
                    let sx = c % w, sy = c / w
                    // Locality bias: nearby texture is likelier to belong.
                    let ddx = sx - cx, ddy = sy - cy
                    var cost = ddx * ddx + ddy * ddy
                    if cost >= bestCost { continue }
                    var dy = -half
                    scan: while dy <= half {
                        var dx = -half
                        while dx <= half {
                            let tp = (cy + dy) * w + (cx + dx)
                            if !needs[tp] {
                                let to = tp * 4, so = ((sy + dy) * w + (sx + dx)) * 4
                                let dr = Int(rgba[to]) - Int(rgba[so])
                                let dg = Int(rgba[to + 1]) - Int(rgba[so + 1])
                                let db = Int(rgba[to + 2]) - Int(rgba[so + 2])
                                cost += dr * dr + dg * dg + db * db
                                if cost >= bestCost { break scan }
                            }
                            dx += 1
                        }
                        dy += 1
                    }
                    if cost < bestCost { bestCost = cost; bestIdx = c }
                }
                guard bestIdx >= 0 else { continue }
                let sx = bestIdx % w, sy = bestIdx / w
                for dy in -half...half {
                    for dx in -half...half {
                        let tp = (cy + dy) * w + (cx + dx)
                        let to = tp * 4, so = ((sy + dy) * w + (sx + dx)) * 4
                        if needs[tp] {
                            rgba[to] = rgba[so]; rgba[to + 1] = rgba[so + 1]
                            rgba[to + 2] = rgba[so + 2]; rgba[to + 3] = rgba[so + 3]
                            needs[tp] = false
                            synth[tp] = true
                            remaining -= 1
                        } else if synth[tp] {
                            // Cross-blend where this patch overlaps earlier synthesized
                            // pixels — verbatim copies met in hard square seams.
                            rgba[to] = UInt8((Int(rgba[to]) * 13 + Int(rgba[so]) * 7) / 20)
                            rgba[to + 1] = UInt8((Int(rgba[to + 1]) * 13 + Int(rgba[so + 1]) * 7) / 20)
                            rgba[to + 2] = UInt8((Int(rgba[to + 2]) * 13 + Int(rgba[so + 2]) * 7) / 20)
                        }
                    }
                }
            }
        }

        // --- 5b. Refine: re-search & vote. With the hole now complete, every
        //        synthesized patch re-finds its best match against *full* patches and
        //        overlapping matches average in (Gaussian-weighted) — the
        //        PatchMatch-style EM step that turns a first-pass patch collage into
        //        continuous texture. This is what makes the fill read as "nothing was
        //        ever there" instead of a faintly visible repair.
        do {
            let synthSum = integral(synth, w: w, h: h)
            var accR = [Float](repeating: 0, count: total)
            var accG = [Float](repeating: 0, count: total)
            var accB = [Float](repeating: 0, count: total)
            var accW = [Float](repeating: 0, count: total)
            var lut = [Float](repeating: 0, count: patch * patch)
            let sigma2 = Float(half * half)
            for dy in -half...half {
                for dx in -half...half {
                    lut[(dy + half) * patch + (dx + half)] = expf(-Float(dx * dx + dy * dy) / (2 * sigma2))
                }
            }
            var cy = half
            while cy <= h - 1 - half {
                var cx = half
                while cx <= w - 1 - half {
                    defer { cx += 3 }
                    guard rectSum(synthSum, w: w, h: h, cx - half, cy - half, cx + half, cy + half) > 0 else { continue }
                    var bestCost = Int.max
                    var bestIdx = -1
                    for c in candidates {
                        let sx = c % w, sy = c / w
                        let ddx = sx - cx, ddy = sy - cy
                        var cost = ddx * ddx + ddy * ddy
                        if cost >= bestCost { continue }
                        var dy = -half
                        scan: while dy <= half {
                            var dx = -half
                            while dx <= half {
                                let to = ((cy + dy) * w + (cx + dx)) * 4
                                let so = ((sy + dy) * w + (sx + dx)) * 4
                                let dr = Int(rgba[to]) - Int(rgba[so])
                                let dg = Int(rgba[to + 1]) - Int(rgba[so + 1])
                                let db = Int(rgba[to + 2]) - Int(rgba[so + 2])
                                cost += dr * dr + dg * dg + db * db
                                if cost >= bestCost { break scan }
                                dx += 1
                            }
                            dy += 1
                        }
                        if cost < bestCost { bestCost = cost; bestIdx = c }
                    }
                    guard bestIdx >= 0 else { continue }
                    let sx = bestIdx % w, sy = bestIdx / w
                    for dy in -half...half {
                        for dx in -half...half {
                            let tp = (cy + dy) * w + (cx + dx)
                            guard synth[tp] else { continue }
                            let wgt = lut[(dy + half) * patch + (dx + half)]
                            let so = ((sy + dy) * w + (sx + dx)) * 4
                            accR[tp] += Float(rgba[so]) * wgt
                            accG[tp] += Float(rgba[so + 1]) * wgt
                            accB[tp] += Float(rgba[so + 2]) * wgt
                            accW[tp] += wgt
                        }
                    }
                }
                cy += 3
            }
            for i in 0..<total where synth[i] && accW[i] > 0 {
                let o = i * 4
                rgba[o] = UInt8(max(0, min(255, (accR[i] / accW[i]).rounded())))
                rgba[o + 1] = UInt8(max(0, min(255, (accG[i] / accW[i]).rounded())))
                rgba[o + 2] = UInt8(max(0, min(255, (accB[i] / accW[i]).rounded())))
            }
        }

        // --- 6. Paste the synthesized window back, hole-only, with a feathered seam ---
        guard let outCG = makeCG(&rgba, w: w, h: h) else { return nil }
        let placed = CIImage(cgImage: outCG)
            .transformed(by: CGAffineTransform(scaleX: roi.width / CGFloat(w), y: roi.height / CGFloat(h)))
            .transformed(by: CGAffineTransform(translationX: roi.minX, y: roi.minY))
        return compositeHole(placed, over: image, mask: m, extent: e)
    }

    /// Composites a filled window back over the original: only the masked hole (plus a feathered
    /// seam scaled to the image size) takes the new pixels — everything else stays untouched.
    private static func compositeHole(_ placed: CIImage, over image: CIImage, mask m: CIImage, extent e: CGRect) -> CIImage {
        let feather = max(1.0, Double(max(e.width, e.height)) * 0.0015)
        let soft = m.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: feather]).cropped(to: e)
        let over = placed.composited(over: image).cropped(to: e)
        return over.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: soft,
        ]).cropped(to: e)
    }

    /// Renders `ci` (origin-based, w×h) into a top-down RGBA8 buffer via CoreGraphics,
    /// so pixel-space orientation is CG-defined in both directions (no flip ambiguity).
    private static func rasterize(_ ci: CIImage, w: Int, h: Int) -> [UInt8]? {
        guard let cg = PhotoEditorIO.context.createCGImage(ci, from: CGRect(x: 0, y: 0, width: w, height: h)) else { return nil }
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ok = buf.withUnsafeMutableBytes { ptr -> Bool in
            guard let cgctx = CGContext(data: ptr.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                        bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            cgctx.interpolationQuality = .high
            cgctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? buf : nil
    }

    private static func makeCG(_ buf: inout [UInt8], w: Int, h: Int) -> CGImage? {
        buf.withUnsafeMutableBytes { ptr -> CGImage? in
            guard let cgctx = CGContext(data: ptr.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                        bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            return cgctx.makeImage()
        }
    }

    /// Summed-area table of a boolean map, (w+1)×(h+1), for O(1) window counts.
    private static func integral(_ map: [Bool], w: Int, h: Int) -> [Int] {
        var s = [Int](repeating: 0, count: (w + 1) * (h + 1))
        for y in 0..<h {
            var row = 0
            for x in 0..<w {
                if map[y * w + x] { row += 1 }
                s[(y + 1) * (w + 1) + (x + 1)] = s[y * (w + 1) + (x + 1)] + row
            }
        }
        return s
    }

    /// Count of set pixels in the (clamped) inclusive rect [x0…x1]×[y0…y1].
    private static func rectSum(_ s: [Int], w: Int, h: Int, _ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> Int {
        let ax = max(0, x0), ay = max(0, y0)
        let bx = min(w - 1, x1), by = min(h - 1, y1)
        guard ax <= bx, ay <= by else { return 0 }
        let W = w + 1
        return s[(by + 1) * W + (bx + 1)] - s[ay * W + (bx + 1)] - s[(by + 1) * W + ax] + s[ay * W + ax]
    }

    // MARK: - Diffusion fallback (the previous engine)

    private static func diffusionFill(_ image: CIImage, mask m: CIImage, extent e: CGRect) -> CIImage {
        var filled = image
        let base = Double(max(e.width, e.height))
        let radii = [base * 0.08, base * 0.05, base * 0.03, base * 0.018, base * 0.01, base * 0.005, base * 0.0025]
        for r in radii {
            for _ in 0..<2 {
                let blurred = filled.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(1, r)])
                    .cropped(to: e)
                filled = blurred.applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: m,
                ]).cropped(to: e)
            }
        }
        if let grained = addMatchedGrain(filled, mask: m, extent: e) {
            filled = grained
        }
        return filled
    }

    /// Adds gentle zero-mean monochrome grain inside the masked region so the diffused fill carries the same
    /// micro-texture as its surroundings instead of reading as an airbrushed soft spot. The grain is applied
    /// via soft-light (a small brightness perturbation that vanishes on flat mid-grey), so a smooth
    /// background (sky/wall) is barely affected while a textured one gets its speckle back.
    private static func addMatchedGrain(_ filled: CIImage, mask: CIImage, extent e: CGRect) -> CIImage? {
        // Tileable noise, desaturated to luminance grain, compressed around mid-grey so the perturbation is
        // subtle (≈±10%).
        let noise = CIFilter(name: "CIRandomGenerator")!.outputImage!
            .cropped(to: e)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.0])
        // Centre the grain exactly on mid-grey (0.5) so soft-light neither lightens nor darkens the fill on
        // average — a bias below 0.5 was greying the patch. Small amplitude keeps it a texture, not a haze.
        let grain = noise.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.06, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0.06, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0.06, w: 0),
            "inputBiasVector": CIVector(x: 0.47, y: 0.47, z: 0.47, w: 0),
        ])
        let textured = grain.applyingFilter("CISoftLightBlendMode", parameters: [
            kCIInputBackgroundImageKey: filled,
        ]).cropped(to: e)
        // Apply the grain only inside the removal hole.
        return textured.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: filled, kCIInputMaskImageKey: mask,
        ]).cropped(to: e)
    }

    private static func alignMask(_ mask: CIImage, to e: CGRect) -> CIImage {
        let me = mask.extent
        guard me.width > 0, me.height > 0 else { return mask }
        let sx = e.width / me.width, sy = e.height / me.height
        let scaled = mask.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        return scaled.transformed(by: CGAffineTransform(translationX: e.minX - scaled.extent.minX,
                                                        y: e.minY - scaled.extent.minY))
    }
}
