import Foundation
import Vision
import CoreImage
import CoreGraphics

/// Key body landmarks (normalized, **top-left** origin) for body-shaping warps. Detected on-device with
/// Vision; resolution-independent. Any joint Vision isn't confident about stays nil.
struct BodyLandmarks: Sendable, Equatable {
    var nose: CGPoint?
    var shoulderL: CGPoint?
    var shoulderR: CGPoint?
    var elbowL: CGPoint?
    var elbowR: CGPoint?
    var wristL: CGPoint?
    var wristR: CGPoint?
    var hipL: CGPoint?
    var hipR: CGPoint?
    var kneeL: CGPoint?
    var kneeR: CGPoint?
    var ankleL: CGPoint?
    var ankleR: CGPoint?
}

/// Key face anchors (normalized, **top-left** origin) for face-shaping warps + makeup. Centers and rough
/// radii are precomputed from Vision's face-landmark regions so the warp generator just reads them.
struct FaceLandmarks: Sendable, Equatable {
    var leftEye: CGPoint?
    var rightEye: CGPoint?
    var eyeRadius: Double = 0.03
    var nose: CGPoint?
    var noseRadius: Double = 0.04
    var mouth: CGPoint?
    var mouthLeft: CGPoint?
    var mouthRight: CGPoint?
    var mouthRadius: Double = 0.05
    var chin: CGPoint?
    var faceLeft: CGPoint?
    var faceRight: CGPoint?
    var browY: Double?
    var faceTop: Double?
    var center: CGPoint?
    var width: Double = 0.2
    var height: Double = 0.25
    // Region polygons (normalized, top-left) for makeup overlays.
    var outerLips: [CGPoint] = []
    var innerLips: [CGPoint] = []
    var leftEyePoly: [CGPoint] = []
    var rightEyePoly: [CGPoint] = []
    var leftBrowPoly: [CGPoint] = []
    var rightBrowPoly: [CGPoint] = []
    var contour: [CGPoint] = []
    var cheekL: CGPoint?
    var cheekR: CGPoint?
}

/// Combined landmark set passed to the renderer (either part may be nil).
struct EditLandmarks: Sendable, Equatable {
    var body: BodyLandmarks?
    var face: FaceLandmarks?
    var isEmpty: Bool { body == nil && face == nil }
}

/// On-device body-pose detection.
enum BodyPose {
    static func detect(in image: CIImage) -> BodyLandmarks? {
        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        let request = VNDetectHumanBodyPoseRequest()
        guard (try? handler.perform([request])) != nil, let obs = request.results?.first else { return nil }
        func point(_ joint: VNHumanBodyPoseObservation.JointName) -> CGPoint? {
            guard let p = try? obs.recognizedPoint(joint), p.confidence > 0.1 else { return nil }
            return CGPoint(x: p.location.x, y: 1 - p.location.y)
        }
        var lm = BodyLandmarks()
        lm.nose = point(.nose)
        lm.shoulderL = point(.leftShoulder); lm.shoulderR = point(.rightShoulder)
        lm.elbowL = point(.leftElbow); lm.elbowR = point(.rightElbow)
        lm.wristL = point(.leftWrist); lm.wristR = point(.rightWrist)
        lm.hipL = point(.leftHip); lm.hipR = point(.rightHip)
        lm.kneeL = point(.leftKnee); lm.kneeR = point(.rightKnee)
        lm.ankleL = point(.leftAnkle); lm.ankleR = point(.rightAnkle)
        guard lm.shoulderL != nil || lm.shoulderR != nil || lm.hipL != nil || lm.hipR != nil else { return nil }
        return lm
    }
}

/// On-device face-landmark detection (used by face shaping and makeup).
enum FaceDetect {
    static func detect(in image: CIImage) -> FaceLandmarks? {
        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        let request = VNDetectFaceLandmarksRequest()
        guard (try? handler.perform([request])) != nil,
              let obs = request.results?.first, let lms = obs.landmarks else { return nil }

        // Region points in normalized top-left image space (pointsInImage with a unit size = normalized).
        func pts(_ region: VNFaceLandmarkRegion2D?) -> [CGPoint] {
            guard let region else { return [] }
            return region.pointsInImage(imageSize: CGSize(width: 1, height: 1)).map { CGPoint(x: $0.x, y: 1 - $0.y) }
        }
        func centroid(_ p: [CGPoint]) -> CGPoint? {
            guard !p.isEmpty else { return nil }
            let sx = p.reduce(0) { $0 + $1.x }, sy = p.reduce(0) { $0 + $1.y }
            return CGPoint(x: sx / CGFloat(p.count), y: sy / CGFloat(p.count))
        }
        func radius(_ p: [CGPoint], _ c: CGPoint?) -> Double {
            guard let c, !p.isEmpty else { return 0.03 }
            let maxd = p.map { hypot(Double($0.x - c.x), Double($0.y - c.y)) }.max() ?? 0.03
            return max(0.02, maxd)
        }

        var f = FaceLandmarks()
        let leftEyeP = pts(lms.leftEye), rightEyeP = pts(lms.rightEye)
        f.leftEye = centroid(leftEyeP); f.rightEye = centroid(rightEyeP)
        f.eyeRadius = max(radius(leftEyeP, f.leftEye), radius(rightEyeP, f.rightEye))
        f.leftEyePoly = leftEyeP; f.rightEyePoly = rightEyeP

        let noseP = pts(lms.nose)
        f.nose = centroid(noseP); f.noseRadius = radius(noseP, f.nose)

        let lipsP = pts(lms.outerLips)
        f.mouth = centroid(lipsP); f.mouthRadius = radius(lipsP, f.mouth)
        f.mouthLeft = lipsP.min(by: { $0.x < $1.x })
        f.mouthRight = lipsP.max(by: { $0.x < $1.x })
        f.outerLips = lipsP; f.innerLips = pts(lms.innerLips)

        let contour = pts(lms.faceContour)
        f.chin = contour.max(by: { $0.y < $1.y })             // lowest point (top-left → max y)
        f.faceLeft = contour.min(by: { $0.x < $1.x })
        f.faceRight = contour.max(by: { $0.x < $1.x })
        f.contour = contour

        f.leftBrowPoly = pts(lms.leftEyebrow); f.rightBrowPoly = pts(lms.rightEyebrow)
        let brows = f.leftBrowPoly + f.rightBrowPoly
        if let by = centroid(brows)?.y { f.browY = Double(by) }

        // Cheeks: between each eye and the nearer mouth corner (a natural blush placement).
        func mid(_ a: CGPoint?, _ b: CGPoint?) -> CGPoint? {
            guard let a, let b else { return nil }
            return CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        }
        f.cheekL = mid(f.leftEye, f.mouthLeft)
        f.cheekR = mid(f.rightEye, f.mouthRight)

        // Face box from the observation (normalized, bottom-left → top-left).
        let bb = obs.boundingBox
        f.faceTop = Double(1 - bb.maxY)
        f.center = CGPoint(x: bb.midX, y: 1 - bb.midY)
        f.width = Double(bb.width); f.height = Double(bb.height)

        guard f.leftEye != nil || f.rightEye != nil || f.mouth != nil || f.nose != nil else { return nil }
        return f
    }
}

/// Turns body/face-shaping slider amounts + landmarks into a displacement mesh (`ReshapeField`) for the
/// existing `ReshapeWarp`. Each control is a small, smooth, landmark-anchored contribution; magnitudes
/// are deliberately conservative. Positive amounts grow/lengthen/slim in the natural direction.
enum BodyWarp {
    static func field(for s: BodyShape, landmarks lm: EditLandmarks, imageAspect aspect: CGFloat) -> ReshapeField? {
        guard !s.isZero else { return nil }
        var f = ReshapeField()
        let cols = f.cols, rows = f.rows
        let asp = Double(aspect > 0 ? aspect : 1)
        let b = lm.body, fc = lm.face

        // Body anchors
        let cx = b.flatMap(centerX)
        let shoulderY = b.flatMap { avgY($0.shoulderL, $0.shoulderR) }
        let hipY = b.flatMap { avgY($0.hipL, $0.hipR) }
        let topY = b?.nose.map { Double($0.y) } ?? shoulderY ?? 0.1

        // Limb tubes start partway down from the root joint so they don't grab the torso/neck/chest.
        let armL = limb(b?.shoulderL, b?.elbowL, b?.wristL, startFrac: 0.50)
        let armR = limb(b?.shoulderR, b?.elbowR, b?.wristR, startFrac: 0.50)
        let legL = limb(b?.hipL, b?.kneeL, b?.ankleL, startFrac: 0.25)
        let legR = limb(b?.hipR, b?.kneeR, b?.ankleR, startFrac: 0.25)
        let mouthCX = fc?.mouth.map { Double($0.x) }

        // Localized breast/butt bulge centers (radial expansion, so neighbors are untouched).
        let shoulderHalf = b.flatMap { lm -> Double? in
            guard let l = lm.shoulderL, let r = lm.shoulderR else { return nil }
            return abs(Double(l.x - r.x)) / 2
        }
        var breastCenters: [CGPoint] = []
        if let cX = cx, let sY = shoulderY, let hY = hipY {
            let cw = (shoulderHalf ?? 0.13) * 0.5
            let chestY = sY + (hY - sY) * 0.26
            breastCenters = [CGPoint(x: cX - cw, y: chestY), CGPoint(x: cX + cw, y: chestY)]
        }
        // Half-width of the hip line — sizes the torso column window *and* the butt bulge.
        let hipHalf = b.flatMap { lm -> Double? in
            guard let l = lm.hipL, let r = lm.hipR else { return nil }
            return abs(Double(l.x - r.x)) / 2
        }
        let breastRadius = max(0.06, (shoulderHalf ?? 0.13) * 0.7)
        let buttRadius = max(0.11, (hipHalf ?? shoulderHalf ?? 0.14) * 1.15)
        let torsoHalf = max(0.12, max(shoulderHalf ?? 0.18, hipHalf ?? 0.18))
        // Facing direction: how far the nose sits from the body axis (sideness 0 = front/back, 1 = profile)
        // and which way the back faces (away from the nose).
        let noseX = (b?.nose ?? fc?.nose).map { Double($0.x) }
        let sideness: Double = (cx != nil && noseX != nil) ? min(1, abs(noseX! - cx!) / max(0.05, torsoHalf)) : 0
        let backDir: Double = (cx != nil && noseX != nil) ? (cx! > noseX! ? 1 : -1) : 0
        // Butt bulge centres. In a front/back view the butt sits just *below* the hip; in a side view it
        // sits *behind* the hip (toward the back) at hip level — placing it below the hip on a profile shot
        // grabs the thigh, so the downward drop fades out as the view turns and a backward shift takes over.
        var buttCenters: [CGPoint] = []
        let buttDrop = 0.06 * (1 - sideness)             // below-hip (front) → at-hip (side)
        let backOff = backDir * sideness * 0.11          // behind the hip in a side view
        for hip in [b?.hipL, b?.hipR] where hip != nil {
            buttCenters.append(CGPoint(x: hip!.x + CGFloat(backOff), y: hip!.y + CGFloat(buttDrop)))
        }
        // Centre-axis fill only for straight-on shots (both hips visible, no thigh confusion).
        if sideness < 0.4, let cX = cx, let hY = hipY, !buttCenters.isEmpty {
            buttCenters.append(CGPoint(x: cX, y: hY + 0.07))
        }

        for j in 1..<(rows - 1) {
            for i in 1..<(cols - 1) {
                let u = Double(i) / Double(cols - 1)
                let v = Double(j) / Double(rows - 1)
                var dx = 0.0, dy = 0.0

                // ----- Body (torso: tight vertical bands, confined to the torso column) -----
                let henv = cx.map { bodyWindow(abs(u - $0), torsoHalf) } ?? 1   // 1 on torso → 0 past the arms
                if let cX = cx, let sY = shoulderY, let hY = hipY {
                    let torso = max(0.06, hY - sY)
                    if s.slim != 0 {
                        dx -= s.slim * 0.28 * (u - cX) * gaussian(v, sY + torso * 0.5, torso * 0.5) * henv
                    }
                    if s.waist != 0 {
                        // Tighter vertical band + lower magnitude so it cinches the waistline instead of
                        // dragging the whole torso.
                        dx -= s.waist * 0.30 * (u - cX) * gaussian(v, sY + torso * 0.72, torso * 0.14) * henv
                    }
                    if s.torso != 0 {
                        // Shorten the torso: compress the chest→hip band vertically toward its centre, so the
                        // waist moves up toward the chest. The displacement is zero at the band centre *and*
                        // tapers to zero at both ends, so the head, hips/legs and background stay put (no
                        // seam, nothing stretched). Confined to the torso column (henv) so the arms aren't
                        // dragged. Compression (not stretch) keeps the area's resolution/clarity intact.
                        let topB = sY + torso * 0.15            // upper chest
                        let botB = hY                           // hip line
                        let cB = (topB + botB) / 2
                        let halfB = max(0.04, (botB - topB) / 2)
                        let w = smoothWindow(v, cB, halfB)
                        dy -= s.torso * 0.34 * (v - cB) * w * henv
                    }
                }
                if s.hips != 0, let cX = cx, let hY = hipY {
                    dx -= s.hips * 0.28 * (u - cX) * gaussian(v, hY, 0.06) * henv
                }
                // Breasts / Butt — localized round, protruding bulges (no vertical band shift).
                if s.breasts != 0, let cX = cx {
                    for c in breastCenters {
                        let (rx, ry, fall) = radial(u, v, c, breastRadius, asp)
                        dx += s.breasts * 0.30 * rx * fall                    // fuller / larger
                        dy += s.breasts * 0.26 * ry * fall
                        dx += s.breasts * 0.12 * (cX - Double(c.x)) * fall    // pull toward centre (busty / cleavage)
                    }
                    // Extra fullness in the centre of the chest, between the breasts.
                    if let sY = shoulderY, let hY = hipY {
                        let chestY = sY + (hY - sY) * 0.26
                        let (rx2, ry2, f2) = radial(u, v, CGPoint(x: cX, y: chestY), breastRadius * 0.9, asp)
                        dx += s.breasts * 0.08 * rx2 * f2
                        dy += s.breasts * 0.12 * ry2 * f2
                    }
                }
                if s.butt != 0 {
                    // The bulge centres are already placed correctly for the view (below the hip head-on,
                    // behind it in profile), so this is a clean radial expansion that tapers to zero at its
                    // edge (no silhouette tearing). The downward fullness is dropped as the view turns to
                    // profile so the protrusion stays on the butt and doesn't thicken the thigh.
                    let down = 0.42 * (1 - sideness * 0.7)
                    for c in buttCenters {
                        let (rx, ry, fall) = radial(u, v, c, buttRadius, asp)
                        dx += s.butt * 0.42 * rx * fall                       // wider / rounder / protruding
                        dy += s.butt * (ry > 0 ? down : 0.26) * ry * fall
                    }
                }
                if s.neck != 0, let cX = cx, let sY = shoulderY {
                    // Skinnier only (slider is 0…1). Tight band between chin and shoulders.
                    let chinY = fc?.chin.map { Double($0.y) } ?? (sY - 0.08)
                    let gap = max(0.05, sY - chinY)
                    dx -= s.neck * 0.24 * (u - cX) * gaussian(v, chinY + gap * 0.5, gap * 0.18)
                }
                if s.height != 0, v > topY { dy += s.height * 0.10 * (v - topY) * henv }

                // ----- Limbs (slim toward the limb axis, confined to a tube around it) -----
                if s.arms != 0 {
                    for poly in [armL, armR] {
                        let (px, py, w) = slimPush(u, v, poly, 0.085, asp)
                        dx += s.arms * 0.55 * px * w; dy += s.arms * 0.55 * py * w
                    }
                }
                if s.legs != 0 {
                    for poly in [legL, legR] {
                        let (px, py, w) = slimPush(u, v, poly, 0.11, asp)
                        dx += s.legs * 0.45 * px * w; dy += s.legs * 0.45 * py * w
                    }
                }
                if s.ankles != 0, let b {
                    for a in [b.ankleL, b.ankleR] where a != nil {
                        let fall = gaussian(v, Double(a!.y), 0.045) * gaussian(u, Double(a!.x), 0.06)
                        dx -= s.ankles * 0.30 * (u - Double(a!.x)) * fall
                    }
                }
                // Feet — radial contraction toward a point just below each ankle, so the foot shrinks
                // toward its own center. The falloff is tight (r ≈ 0.06) and only pulls *inward* (positive
                // = smaller), so the ground/background outside the foot is left untouched.
                if s.feet != 0, let b {
                    for a in [b.ankleL, b.ankleR] where a != nil {
                        let footC = CGPoint(x: a!.x, y: a!.y + 0.045)   // feet sit below the ankle joint
                        let (rx, ry, fall) = radial(u, v, footC, 0.06, asp)
                        dx -= s.feet * 0.30 * rx * fall
                        dy -= s.feet * 0.30 * ry * fall
                    }
                }

                // ----- Face -----
                if let fc {
                    if s.eyes != 0 {
                        for eye in [fc.leftEye, fc.rightEye] where eye != nil {
                            let (rx, ry, fall) = radial(u, v, eye!, fc.eyeRadius * 2.4, asp)
                            dx += s.eyes * 0.6 * rx * fall      // slightly wider than tall
                            dy += s.eyes * 0.45 * ry * fall
                        }
                    }
                    if s.nose != 0, let c = fc.nose {
                        // Positive = smaller nose: pull the sides inward (narrower) and shorten slightly.
                        // Radius is large enough to actually grab the nose but capped so it stays off the
                        // eyes/cheeks.
                        let r = min(max(fc.noseRadius, 0.045) * 1.5, 0.075)
                        let (rx, ry, fall) = radial(u, v, c, r, asp)
                        dx -= s.nose * 0.75 * rx * fall      // narrow horizontally
                        dy -= s.nose * 0.35 * ry * fall      // shorten vertically
                    }
                    if s.lips != 0, let c = fc.mouth {
                        let (rx, ry, fall) = radial(u, v, c, fc.mouthRadius * 1.6, asp)
                        dx += s.lips * 0.6 * rx * fall
                        dy += s.lips * 0.6 * ry * fall
                    }
                    if s.ears != 0 {
                        for ear in [fc.faceLeft, fc.faceRight] where ear != nil {
                            let (rx, ry, fall) = radial(u, v, ear!, max(0.05, fc.width * 0.25), asp)
                            dx += s.ears * 0.28 * rx * fall
                            dy += s.ears * 0.20 * ry * fall
                        }
                    }
                    if s.head != 0, let c = fc.center {
                        let (rx, ry, fall) = radial(u, v, c, max(fc.width, fc.height) * 0.7, asp)
                        dx += s.head * 0.24 * rx * fall
                        dy += s.head * 0.24 * ry * fall
                    }
                    if s.chin != 0, let c = fc.chin {
                        let mouthY = fc.mouth.map { Double($0.y) } ?? (Double(c.y) - 0.08)
                        if v > mouthY { dy += s.chin * 0.06 * gaussian(v, Double(c.y), 0.05) }
                    }
                    if s.smile != 0, let mcx = mouthCX {
                        // Lift + widen each mouth corner inside a *tight* radial brush (hard zero past its
                        // edge) so the smile stays local instead of warping the whole lower face.
                        for corner in [fc.mouthLeft, fc.mouthRight] where corner != nil {
                            let (_, _, fall) = radial(u, v, corner!, 0.055, asp)
                            dy -= s.smile * 0.06 * fall                                      // lift the corner up
                            dx += s.smile * 0.035 * sign(Double(corner!.x) - mcx) * fall     // pull it outward
                        }
                    }
                    // Forehead — very subtle vertical give, strictly inside the forehead band.
                    if s.forehead != 0, let by = fc.browY, let top = fc.faceTop, by > top, v > top, v < by {
                        dy -= s.forehead * 0.04 * gaussian(v, (top + by) / 2, (by - top) * 0.35)
                    }
                }

                let idx = j * cols + i
                f.dx[idx] = clamp(dx)
                f.dy[idx] = clamp(dy)
            }
        }
        return f.isZero ? nil : f
    }

    /// Multiplies the displacement at each grid vertex by the subject mask coverage there, so background
    /// vertices (mask ≈ 0) stay put and only the subject is warped. The mask is box-averaged down to the
    /// grid resolution for a smooth, ~one-cell transition at the silhouette.
    static func modulate(_ field: ReshapeField, byMask mask: CIImage, context: CIContext) -> ReshapeField {
        let cols = field.cols, rows = field.rows
        let e = mask.extent
        guard !e.isInfinite, !e.isNull, e.width > 1, e.height > 1 else { return field }
        let sx = CGFloat(cols) / e.width, sy = CGFloat(rows) / e.height
        let small = mask.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        let recentered = small.transformed(by: CGAffineTransform(translationX: -small.extent.minX,
                                                                 y: -small.extent.minY))
        guard let cg = context.createCGImage(recentered,
                                             from: CGRect(x: 0, y: 0, width: CGFloat(cols), height: CGFloat(rows)),
                                             format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()),
              let data = cg.dataProvider?.data, let ptr = CFDataGetBytePtr(data) else { return field }
        let bpr = cg.bytesPerRow
        var f = field
        for j in 0..<rows {
            for i in 0..<cols {
                let m = Double(ptr[j * bpr + i * 4]) / 255.0   // createCGImage is top-left; R = mask coverage
                let idx = j * cols + i
                f.dx[idx] *= m
                f.dy[idx] *= m
            }
        }
        return f
    }

    // MARK: Helpers

    /// Radial falloff around `c` within `r`; returns the (x, y) offsets toward the vertex and the falloff
    /// weight (so a caller scales by amount). `aspect` keeps the brush round in pixels.
    private static func radial(_ u: Double, _ v: Double, _ c: CGPoint, _ r: Double, _ aspect: Double)
        -> (Double, Double, Double) {
        let hx = u - Double(c.x)
        let hy = (v - Double(c.y)) / aspect
        let dist = (hx * hx + hy * hy).squareRoot()
        guard dist < r else { return (0, 0, 0) }
        return (u - Double(c.x), v - Double(c.y), smoothstep(1 - dist / r))
    }

    private static func centerX(_ lm: BodyLandmarks) -> Double? {
        let xs = [lm.shoulderL, lm.shoulderR, lm.hipL, lm.hipR].compactMap { $0.map { Double($0.x) } }
        return xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count)
    }
    private static func avgY(_ a: CGPoint?, _ b: CGPoint?) -> Double? {
        let ys = [a, b].compactMap { $0.map { Double($0.y) } }
        return ys.isEmpty ? nil : ys.reduce(0, +) / Double(ys.count)
    }
    /// A limb polyline in normalized points. Requires a mid/end joint (elbow/knee/wrist/ankle) beyond the
    /// root so that — with no limb detected — the slider has no anchor and simply does nothing (rather
    /// than warping the torso). Returns [] when there aren't ≥2 usable points.
    private static func limb(_ root: CGPoint?, _ mid: CGPoint?, _ end: CGPoint?,
                             startFrac: Double = 0) -> [(Double, Double)] {
        guard mid != nil || end != nil else { return [] }
        var p: [(Double, Double)] = []
        if let root, let next = mid ?? end {
            // Trim the start down the first segment so the tube doesn't grab the root joint's area.
            p.append((Double(root.x) + (Double(next.x) - Double(root.x)) * startFrac,
                      Double(root.y) + (Double(next.y) - Double(root.y)) * startFrac))
        } else if let root {
            p.append((Double(root.x), Double(root.y)))
        }
        if let mid { p.append((Double(mid.x), Double(mid.y))) }
        if let end { p.append((Double(end.x), Double(end.y))) }
        return p.count >= 2 ? p : []
    }

    /// Slim toward a limb axis: the push that moves vertex (u,v) toward the nearest point on `poly`,
    /// within a tube of radius `r` (round in pixels via `aspect`). Returns normalized (dx, dy, weight).
    private static func slimPush(_ u: Double, _ v: Double, _ poly: [(Double, Double)],
                                 _ r: Double, _ aspect: Double) -> (Double, Double, Double) {
        guard poly.count >= 2 else { return (0, 0, 0) }
        let pIso = (u, v / aspect)
        var best = (0.0, 0.0), bestD = Double.infinity
        for k in 0..<(poly.count - 1) {
            let a = (poly[k].0, poly[k].1 / aspect)
            let bnd = (poly[k + 1].0, poly[k + 1].1 / aspect)
            let n = nearestOnSegment(pIso, a, bnd)
            let d = hypot(pIso.0 - n.0, pIso.1 - n.1)
            if d < bestD { bestD = d; best = n }
        }
        guard bestD < r else { return (0, 0, 0) }
        return (best.0 - pIso.0, (best.1 - pIso.1) * aspect, smoothstep(1 - bestD / r))
    }

    private static func nearestOnSegment(_ p: (Double, Double), _ a: (Double, Double),
                                         _ b: (Double, Double)) -> (Double, Double) {
        let abx = b.0 - a.0, aby = b.1 - a.1
        let denom = abx * abx + aby * aby
        if denom < 1e-9 { return a }
        let t = min(1, max(0, ((p.0 - a.0) * abx + (p.1 - a.1) * aby) / denom))
        return (a.0 + t * abx, a.1 + t * aby)
    }

    private static func gaussian(_ x: Double, _ center: Double, _ sigma: Double) -> Double {
        let d = (x - center) / max(0.0001, sigma)
        return exp(-0.5 * d * d)
    }
    private static func smoothstep(_ t: Double) -> Double {
        let c = min(1, max(0, t)); return c * c * (3 - 2 * c)
    }
    /// A smooth bump: 1 at `center`, tapering to 0 at `±half` (and beyond). Used to confine a vertical
    /// compression to a band with no hard seam at its edges.
    private static func smoothWindow(_ v: Double, _ center: Double, _ half: Double) -> Double {
        let d = abs(v - center)
        return d >= half ? 0 : smoothstep(1 - d / half)
    }
    private static func sign(_ v: Double) -> Double { v >= 0 ? 1 : -1 }
    private static func clamp(_ v: Double) -> Double { max(-0.3, min(0.3, v)) }

    /// Full strength out to the torso edge (so waist/hips actually move the body's sides), then fades
    /// quickly past it to spare the arms and keep the background still.
    private static func bodyWindow(_ d: Double, _ half: Double) -> Double {
        let inner = half * 0.98, outer = half * 1.08
        if d <= inner { return 1 }
        if d >= outer { return 0 }
        return 1 - smoothstep((d - inner) / (outer - inner))
    }
}
