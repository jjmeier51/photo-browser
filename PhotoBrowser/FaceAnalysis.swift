import Foundation
import Vision
import UIKit
import ImageIO

/// One detected face: its normalized bounding box (Vision's bottom-left-origin
/// `boundingBox`, stored [x,y,w,h]) and an image feature-print vector used to
/// approximate identity. Apple exposes no on-device face-identity API, so we use
/// `VNGenerateImageFeaturePrint` on the cropped face and cluster by vector
/// distance — good enough to group, imperfect enough to need manual correction.
struct DetectedFace: Codable, Sendable {
    var rect: [CGFloat]
    var print: [Float]
}

enum FaceAnalysis {

    // MARK: - Detection + feature prints (off-main)

    nonisolated static func analyze(_ url: URL) async -> [DetectedFace] {
        await Task.detached(priority: .utility) { () -> [DetectedFace] in
            guard let cg = decode(url, maxPixel: 1400) else { return [] }
            let req = VNDetectFaceRectanglesRequest()
            try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([req])
            let W = CGFloat(cg.width), H = CGFloat(cg.height)
            var out: [DetectedFace] = []
            for f in (req.results ?? []) {
                let bb = f.boundingBox                                   // normalized, bottom-left origin
                guard bb.width > 0.02, bb.height > 0.02 else { continue }   // skip tiny/false faces
                let px = CGRect(x: bb.minX * W, y: (1 - bb.minY - bb.height) * H,
                                width: bb.width * W, height: bb.height * H)
                let exp = px.insetBy(dx: -px.width * 0.2, dy: -px.height * 0.2)
                    .intersection(CGRect(x: 0, y: 0, width: W, height: H)).integral
                guard !exp.isEmpty, let face = cg.cropping(to: exp) else { continue }
                out.append(DetectedFace(rect: [bb.minX, bb.minY, bb.width, bb.height],
                                        print: featurePrint(face) ?? []))
            }
            return out
        }.value
    }

    private nonisolated static func featurePrint(_ cg: CGImage) -> [Float]? {
        let req = VNGenerateImageFeaturePrintRequest()
        try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([req])
        guard let obs = req.results?.first as? VNFeaturePrintObservation, obs.elementType == .float else { return nil }
        return obs.data.withUnsafeBytes { raw in Array(raw.bindMemory(to: Float.self)) }
    }

    /// L2 distance between two feature-print vectors (smaller = more similar). We
    /// recompute it ourselves because a `VNFeaturePrintObservation` can't be
    /// rebuilt from persisted bytes to call `computeDistance`.
    nonisolated static func distance(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return .greatestFiniteMagnitude }
        var sum: Float = 0
        for i in 0..<a.count { let d = a[i] - b[i]; sum += d * d }
        return sum.squareRoot()
    }

    /// Vector distance below which two faces are treated as the same person.
    /// Empirical — expect to tune this on-device.
    nonisolated static let sameFaceThreshold: Float = 18

    // MARK: - Rendering a face crop for People tiles

    nonisolated static func faceCrop(path: String, rect: [CGFloat]) async -> UIImage? {
        await Task.detached(priority: .utility) { () -> UIImage? in
            guard rect.count == 4, let cg = decode(URL(fileURLWithPath: path), maxPixel: 1000) else { return nil }
            let W = CGFloat(cg.width), H = CGFloat(cg.height)
            let px = CGRect(x: rect[0] * W, y: (1 - rect[1] - rect[3]) * H, width: rect[2] * W, height: rect[3] * H)
            let exp = px.insetBy(dx: -px.width * 0.25, dy: -px.height * 0.25)
                .intersection(CGRect(x: 0, y: 0, width: W, height: H)).integral
            guard !exp.isEmpty, let face = cg.cropping(to: exp) else { return nil }
            return UIImage(cgImage: face)
        }.value
    }

    private nonisolated static func decode(_ url: URL, maxPixel: CGFloat) -> CGImage? {
        let opts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithURL(url as CFURL, opts) else { return nil }
        let thumb: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, thumb as CFDictionary)
    }
}

/// Persisted face detections keyed by file path (re-run "Find People" to refresh).
final class FaceStore: @unchecked Sendable {
    static let shared = FaceStore()
    private let lock = NSLock()
    private var map: [String: [DetectedFace]]
    private var dirty = false
    private let fileURL: URL

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        fileURL = dir.appendingPathComponent("faces.json")
        map = (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode([String: [DetectedFace]].self, from: $0) } ?? [:]
    }

    func faces(_ path: String) -> [DetectedFace]? { lock.lock(); defer { lock.unlock() }; return map[path] }
    func store(_ path: String, _ faces: [DetectedFace]) { lock.lock(); map[path] = faces; dirty = true; lock.unlock() }
    func flush() {
        lock.lock(); guard dirty else { lock.unlock(); return }
        let snapshot = map; dirty = false; lock.unlock()
        if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: fileURL, options: .atomic) }
    }
}
