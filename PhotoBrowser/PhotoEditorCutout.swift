import Vision
import CoreImage

/// On-device subject masking for background removal (`FR-CUT-01`). Uses Vision's iOS 17
/// `VNGenerateForegroundInstanceMaskRequest` to find the foreground subject(s) and returns a grayscale
/// mask (1 = subject) in the image's pixel space. Entirely on-device — no network, per the PRD.
///
/// All work is synchronous and CPU/Neural-Engine heavy, so callers must run it off the main actor
/// (`Task.detached`), matching the rest of the editor's pipeline.
enum PhotoEditorCutout {
    /// The combined foreground mask for `image`, or nil if Vision finds no subject (or the request fails).
    static func subjectMask(for image: CIImage) -> CIImage? {
        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        let request = VNGenerateForegroundInstanceMaskRequest()
        do {
            try handler.perform([request])
            guard let result = request.results?.first, !result.allInstances.isEmpty else { return nil }
            let buffer = try result.generateScaledMaskForImage(forInstances: result.allInstances, from: handler)
            return CIImage(cvPixelBuffer: buffer)
        } catch {
            return nil
        }
    }
}
