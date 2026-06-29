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

        let noseP = pts(lms.nose)
        f.nose = centroid(noseP); f.noseRadius = radius(noseP, f.nose)

        let lipsP = pts(lms.outerLips)
        f.mouth = centroid(lipsP); f.mouthRadius = radius(lipsP, f.mouth)
        f.mouthLeft = lipsP.min(by: { $0.x < $1.x })
        f.mouthRight = lipsP.max(by: { $0.x < $1.x })

        let contour = pts(lms.faceContour)
        f.chin = contour.max(by: { $0.y < $1.y })             // lowest point (top-left → max y)
        f.faceLeft = contour.min(by: { $0.x < $1.x })
        f.faceRight = contour.max(by: { $0.x < $1.x })

        let brows = pts(lms.leftEyebrow) + pts(lms.rightEyebrow)
        if let by = centroid(brows)?.y { f.browY = Double(by) }

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
        let ankleY = b.flatMap { avgY($0.ankleL, $0.ankleR) ?? avgY($0.kneeL, $0.kneeR) }
        let halfW = b.map(bodyHalfWidth) ?? 0.2
        let topY = b?.nose.map { Double($0.y) } ?? shoulderY ?? 0.1

        for j in 1..<(rows - 1) {
            for i in 1..<(cols - 1) {
                let u = Double(i) / Double(cols - 1)
                let v = Double(j) / Double(rows - 1)
                var dx = 0.0, dy = 0.0

                // ----- Body -----
                if let cX = cx, let sY = shoulderY, let hY = hipY {
                    let torso = max(0.05, hY - sY)
                    if s.slim != 0 {
                        dx -= s.slim * 0.26 * (u - cX) * gaussian(v, sY + torso * 0.55, torso * 0.9)
                    }
                    if s.waist != 0 {
                        dx -= s.waist * 0.26 * (u - cX) * gaussian(v, sY + torso * 0.72, torso * 0.45)
                    }
                    if s.breasts != 0 {
                        let f2 = gaussian(v, sY + torso * 0.18, torso * 0.35)
                        dx += s.breasts * 0.18 * (u - cX) * f2
                        dy += s.breasts * 0.05 * f2
                    }
                    if s.arms != 0 {
                        // Narrow the lateral regions beside the torso (where arms hang).
                        let band = gaussian(v, sY + torso * 0.45, torso * 0.7)
                        if abs(u - cX) > halfW {
                            dx -= s.arms * 0.18 * sign(u - cX) * band
                        }
                    }
                }
                if let cX = cx, let hY = hipY {
                    if s.hips != 0 { dx -= s.hips * 0.22 * (u - cX) * gaussian(v, hY, 0.09) }
                    if s.butt != 0 {
                        let f2 = gaussian(v, hY + 0.05, 0.08)
                        dx += s.butt * 0.18 * (u - cX) * f2
                        dy += s.butt * 0.05 * f2
                    }
                }
                if s.legs != 0, let hY = hipY {
                    let endY = ankleY ?? 1.0
                    if v > hY { dy += s.legs * 0.18 * min(1.0, (v - hY) / max(0.05, endY - hY)) }
                }
                if s.height != 0, v > topY { dy += s.height * 0.13 * (v - topY) }
                if s.ankles != 0, let b {
                    for a in [b.ankleL, b.ankleR] {
                        if let a {
                            let fall = gaussian(v, Double(a.y), 0.05) * gaussian(u, Double(a.x), 0.06)
                            dx -= s.ankles * 0.22 * (u - Double(a.x)) * fall
                        }
                    }
                }
                if s.neck != 0, let cX = cx, let sY = shoulderY {
                    let chinY = fc?.chin.map { Double($0.y) } ?? (sY - 0.06)
                    let neckY = (chinY + sY) / 2
                    dx -= s.neck * 0.16 * (u - cX) * gaussian(v, neckY, max(0.03, (sY - chinY) * 0.8))
                }

                // ----- Face -----
                if let fc {
                    if s.eyes != 0 {
                        for eye in [fc.leftEye, fc.rightEye] where eye != nil {
                            let (rx, ry, fall) = radial(u, v, eye!, fc.eyeRadius * 2.4, asp)
                            dx += s.eyes * 0.42 * rx * fall      // slightly wider than tall
                            dy += s.eyes * 0.32 * ry * fall
                        }
                    }
                    if s.nose != 0, let c = fc.nose {
                        let (rx, ry, fall) = radial(u, v, c, fc.noseRadius * 1.8, asp)
                        dx += s.nose * 0.30 * rx * fall
                        dy += s.nose * 0.30 * ry * fall
                    }
                    if s.lips != 0, let c = fc.mouth {
                        let (rx, ry, fall) = radial(u, v, c, fc.mouthRadius * 1.5, asp)
                        dx += s.lips * 0.30 * rx * fall
                        dy += s.lips * 0.30 * ry * fall
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
                        if v > mouthY { dy += s.chin * 0.16 * gaussian(v, Double(c.y), 0.06) }
                    }
                    if s.smile != 0 {
                        for corner in [fc.mouthLeft, fc.mouthRight] where corner != nil {
                            let fall = gaussian(v, Double(corner!.y), 0.04) * gaussian(u, Double(corner!.x), 0.05)
                            dy -= s.smile * 0.07 * fall            // lift the corners
                        }
                    }
                    if s.forehead != 0, let by = fc.browY, let top = fc.faceTop, by > top {
                        if v < by { dy -= s.forehead * 0.10 * gaussian(v, (top + by) / 2, (by - top) * 0.9) }
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
    private static func bodyHalfWidth(_ lm: BodyLandmarks) -> Double {
        var w = 0.18
        if let l = lm.shoulderL, let r = lm.shoulderR { w = max(w, abs(Double(l.x - r.x)) / 2 + 0.04) }
        if let l = lm.hipL, let r = lm.hipR { w = max(w, abs(Double(l.x - r.x)) / 2 + 0.04) }
        return min(w, 0.42)
    }
    private static func gaussian(_ x: Double, _ center: Double, _ sigma: Double) -> Double {
        let d = (x - center) / max(0.0001, sigma)
        return exp(-0.5 * d * d)
    }
    private static func smoothstep(_ t: Double) -> Double {
        let c = min(1, max(0, t)); return c * c * (3 - 2 * c)
    }
    private static func sign(_ v: Double) -> Double { v >= 0 ? 1 : -1 }
    private static func clamp(_ v: Double) -> Double { max(-0.3, min(0.3, v)) }
}
