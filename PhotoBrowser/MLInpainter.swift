import CoreML
import CoreImage
import CoreVideo

/// Optional ML inpainting (LaMa-class) — tier 1 of the object-removal chain when a
/// model is bundled; the app builds and runs identically without one (exemplar
/// synthesis remains the always-available engine). Like FFmpegKit, this is an
/// opt-in heavyweight component gated behind `isAvailable`.
///
/// To enable: convert LaMa to CoreML (see `docs/ml-inpainting.md`) and drop the
/// resulting `.mlpackage` into the `PhotoBrowser/` folder — the synced project
/// picks it up and Xcode compiles it into the bundle automatically.
///
/// The model contract is discovered at load time rather than hard-coded: an
/// image-typed color input (the photo window), an input named "mask" or typed
/// one-component (the removal mask, white = remove), and an image-typed output.
/// Input size comes from the model's own constraints, so 512/800/… conversions
/// all work unmodified.
nonisolated final class MLInpainter: @unchecked Sendable {
    static let shared = MLInpainter()

    private struct Contract {
        let imageName: String
        let maskName: String
        let outputName: String
        let width: Int
        let height: Int
        let maskFormat: OSType
    }

    private let model: MLModel?
    private let contract: Contract?

    var isAvailable: Bool { model != nil && contract != nil }

    private init() {
        // Accept either resource name so the CoreMLaMa output can be dropped in as-is.
        let url = Bundle.main.url(forResource: "Inpainting", withExtension: "mlmodelc")
            ?? Bundle.main.url(forResource: "LaMa", withExtension: "mlmodelc")
        guard let url else { model = nil; contract = nil; return }
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .all                       // prefer the Neural Engine
        guard let m = try? MLModel(contentsOf: url, configuration: cfg) else {
            model = nil; contract = nil; return
        }

        var imageName: String?, maskName: String?
        var width = 0, height = 0
        var maskFormat = kCVPixelFormatType_OneComponent8
        for (name, desc) in m.modelDescription.inputDescriptionsByName {
            guard desc.type == .image, let c = desc.imageConstraint else { continue }
            if name.lowercased().contains("mask") || c.pixelFormatType == kCVPixelFormatType_OneComponent8 {
                maskName = name
                maskFormat = c.pixelFormatType
            } else {
                imageName = name
                width = c.pixelsWide
                height = c.pixelsHigh
            }
        }
        let output = m.modelDescription.outputDescriptionsByName.first { $0.value.type == .image }?.key
        guard let imageName, let maskName, let output, width > 0, height > 0 else {
            model = nil; contract = nil; return
        }
        model = m
        contract = Contract(imageName: imageName, maskName: maskName, outputName: output,
                            width: width, height: height, maskFormat: maskFormat)
    }

    /// Fills the masked area of `window` and returns a same-size image, or nil so
    /// the caller falls back to exemplar synthesis. `window` and `mask` are
    /// origin-based CIImages of equal extent (the working window around a stroke).
    func fill(window: CIImage, mask: CIImage, context: CIContext) -> CIImage? {
        guard let model, let io = contract else { return nil }
        let w = window.extent.width, h = window.extent.height
        guard w > 1, h > 1 else { return nil }

        // Letterbox into the model's fixed input (content anchored at the origin).
        let scale = min(CGFloat(io.width) / w, CGFloat(io.height) / h)
        let sw = max(1, Int((w * scale).rounded())), sh = max(1, Int((h * scale).rounded()))
        let t = CGAffineTransform(scaleX: CGFloat(sw) / w, y: CGFloat(sh) / h)
        guard let imgBuf = render(window.transformed(by: t), w: io.width, h: io.height,
                                  format: kCVPixelFormatType_32BGRA, context: context),
              let maskBuf = render(mask.transformed(by: t), w: io.width, h: io.height,
                                   format: io.maskFormat, context: context),
              let input = try? MLDictionaryFeatureProvider(dictionary: [
                  io.imageName: MLFeatureValue(pixelBuffer: imgBuf),
                  io.maskName: MLFeatureValue(pixelBuffer: maskBuf),
              ]),
              let out = try? model.prediction(from: input),
              let outBuf = out.featureValue(for: io.outputName)?.imageBufferValue
        else { return nil }

        // Un-letterbox: crop the content region and scale back to the window size.
        // The CVPixelBuffer round-trips through Core Image in both directions, so
        // the content region stays at the CI origin.
        return CIImage(cvPixelBuffer: outBuf)
            .cropped(to: CGRect(x: 0, y: 0, width: sw, height: sh))
            .transformed(by: CGAffineTransform(scaleX: w / CGFloat(sw), y: h / CGFloat(sh)))
            .cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
    }

    private func render(_ image: CIImage, w: Int, h: Int, format: OSType, context: CIContext) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]] as CFDictionary
        CVPixelBufferCreate(kCFAllocatorDefault, w, h, format, attrs, &pb)
        guard let pb else { return nil }
        let space: CGColorSpace? = format == kCVPixelFormatType_OneComponent8 ? nil : CGColorSpaceCreateDeviceRGB()
        context.render(image, to: pb, bounds: CGRect(x: 0, y: 0, width: w, height: h), colorSpace: space)
        return pb
    }
}
