import Foundation
import Vision
import CoreImage
import CoreGraphics

/// Key body landmarks (normalized, **top-left** origin) used to anchor body-shaping warps. Detected
/// on-device with Vision; resolution-independent, so one detection drives both the preview and the
/// full-res save. A struct of optional points — any joint Vision isn't confident about stays nil.
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

/// On-device body-pose detection (Vision `VNDetectHumanBodyPoseRequest`). Off-main; returns nil if no
/// person (or no usable torso) is found.
enum BodyPose {
    static func detect(in image: CIImage) -> BodyLandmarks? {
        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        let request = VNDetectHumanBodyPoseRequest()
        guard (try? handler.perform([request])) != nil, let obs = request.results?.first else { return nil }

        func point(_ joint: VNHumanBodyPoseObservation.JointName) -> CGPoint? {
            guard let p = try? obs.recognizedPoint(joint), p.confidence > 0.1 else { return nil }
            return CGPoint(x: p.location.x, y: 1 - p.location.y)   // Vision is bottom-left → top-left
        }
        var lm = BodyLandmarks()
        lm.nose = point(.nose)
        lm.shoulderL = point(.leftShoulder); lm.shoulderR = point(.rightShoulder)
        lm.hipL = point(.leftHip); lm.hipR = point(.rightHip)
        lm.kneeL = point(.leftKnee); lm.kneeR = point(.rightKnee)
        lm.ankleL = point(.leftAnkle); lm.ankleR = point(.rightAnkle)
        // Need at least a shoulder or hip to anchor anything.
        guard lm.shoulderL != nil || lm.shoulderR != nil || lm.hipL != nil || lm.hipR != nil else { return nil }
        return lm
    }
}

/// Turns body-shaping slider amounts + landmarks into a displacement mesh (`ReshapeField`) that the
/// existing `ReshapeWarp` renders. Anchored to the torso/hip/leg/head landmarks with smooth falloffs.
/// The amounts are intentionally conservative so results stay natural; positive = slimmer / narrower
/// hips / longer legs / taller / bigger head.
enum BodyWarp {
    static func field(for body: BodyShape, landmarks lm: BodyLandmarks, imageAspect aspect: CGFloat) -> ReshapeField? {
        guard !body.isZero else { return nil }
        var f = ReshapeField()
        let cols = f.cols, rows = f.rows

        let cx = centerX(lm)
        let shoulderY = avgY(lm.shoulderL, lm.shoulderR)
        let hipY = avgY(lm.hipL, lm.hipR)
        let ankleY = avgY(lm.ankleL, lm.ankleR) ?? avgY(lm.kneeL, lm.kneeR)
        let topY = lm.nose.map { Double($0.y) } ?? shoulderY ?? 0.1
        let halfW = bodyHalfWidth(lm)
        let asp = Double(aspect > 0 ? aspect : 1)

        for j in 1..<(rows - 1) {
            for i in 1..<(cols - 1) {
                let u = Double(i) / Double(cols - 1)
                let v = Double(j) / Double(rows - 1)
                var dx = 0.0, dy = 0.0

                // Slim: horizontal squeeze toward the body centerline, peaking at the waist.
                if body.slim != 0, let sY = shoulderY, let hY = hipY, let cX = cx {
                    let waistY = sY + (hY - sY) * 0.55
                    let sigma = max(0.04, (hY - sY) * 0.9)
                    dx -= body.slim * 0.28 * (u - cX) * gaussian(v, waistY, sigma)
                }
                // Hips: widen/narrow a band around the hip line.
                if body.hips != 0, let hY = hipY, let cX = cx {
                    dx -= body.hips * 0.22 * (u - cX) * gaussian(v, hY, 0.09)
                }
                // Legs: lengthen below the hips (push downward, growing toward the ankles).
                if body.legs != 0, let hY = hipY {
                    let endY = ankleY ?? 1.0
                    if v > hY { dy += body.legs * 0.18 * min(1.0, (v - hY) / max(0.04, endY - hY)) }
                }
                // Height: stretch the whole body below the head downward.
                if body.height != 0, v > topY {
                    dy += body.height * 0.13 * (v - topY)
                }
                // Head: radial scale around the nose (round in pixel space via the aspect term).
                if body.head != 0, let nose = lm.nose {
                    let hx = u - Double(nose.x)
                    let hy = (v - Double(nose.y)) / asp
                    let dist = (hx * hx + hy * hy).squareRoot()
                    let r = max(0.06, halfW)
                    if dist < r {
                        let fall = smoothstep(1 - dist / r)
                        dx += body.head * 0.25 * hx * fall
                        dy += body.head * 0.25 * (v - Double(nose.y)) * fall
                    }
                }

                let idx = j * cols + i
                f.dx[idx] = clamp(dx)
                f.dy[idx] = clamp(dy)
            }
        }
        return f.isZero ? nil : f
    }

    // MARK: Helpers

    private static func centerX(_ lm: BodyLandmarks) -> Double? {
        let xs = [lm.shoulderL, lm.shoulderR, lm.hipL, lm.hipR].compactMap { $0.map { Double($0.x) } }
        return xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count)
    }
    private static func avgY(_ a: CGPoint?, _ b: CGPoint?) -> Double? {
        let ys = [a, b].compactMap { $0.map { Double($0.y) } }
        return ys.isEmpty ? nil : ys.reduce(0, +) / Double(ys.count)
    }
    private static func bodyHalfWidth(_ lm: BodyLandmarks) -> Double {
        var w = 0.2
        if let l = lm.shoulderL, let r = lm.shoulderR { w = max(w, abs(Double(l.x - r.x)) / 2 + 0.05) }
        if let l = lm.hipL, let r = lm.hipR { w = max(w, abs(Double(l.x - r.x)) / 2 + 0.05) }
        return min(w, 0.4)
    }
    private static func gaussian(_ x: Double, _ center: Double, _ sigma: Double) -> Double {
        let d = (x - center) / sigma
        return exp(-0.5 * d * d)
    }
    private static func smoothstep(_ t: Double) -> Double {
        let c = min(1, max(0, t))
        return c * c * (3 - 2 * c)
    }
    private static func clamp(_ v: Double) -> Double { max(-0.3, min(0.3, v)) }
}
