import SwiftUI
import UIKit

/// Square cropper for choosing a folder's album cover. The user pans/zooms the
/// image inside a fixed square window; "Use" returns the cropped square image.
struct AlbumCoverCropper: View {
    let entry: Entry
    var providedImage: UIImage? = nil       // e.g. the current video frame
    let onCrop: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var box = CropControllerBox()
    @State private var image: UIImage?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let image {
                    CropRepresentable(image: image, box: box).ignoresSafeArea()
                } else {
                    ProgressView().tint(.white)
                }
            }
            .navigationTitle("Crop Cover")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use") {
                        if let cropped = box.controller?.croppedImage() { onCrop(cropped) }
                        dismiss()
                    }
                    .disabled(image == nil)
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        if let providedImage { image = providedImage; return }
        if entry.kind == .image {
            // Size-bounded decode (huge full-res photos could exhaust memory).
            image = await ZoomableImageView.decode(url: entry.url, maxPixel: 2000, fullQuality: true)
        } else {
            image = await MediaEditorView.videoPoster(entry.url)
        }
    }
}

/// Bridges the SwiftUI "Use" button to the UIKit controller's crop method.
final class CropControllerBox {
    weak var controller: CropController?
}

private struct CropRepresentable: UIViewControllerRepresentable {
    let image: UIImage
    let box: CropControllerBox

    func makeUIViewController(context: Context) -> CropController {
        let controller = CropController(image: image)
        box.controller = controller
        return controller
    }

    func updateUIViewController(_ controller: CropController, context: Context) {}
}

final class CropController: UIViewController, UIScrollViewDelegate {
    private let scrollView = UIScrollView()
    private let imageView: UIImageView
    private let image: UIImage
    private var cropSize: CGFloat = 0
    private var configured = false

    init(image: UIImage) {
        self.image = image
        self.imageView = UIImageView(image: image)
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        scrollView.delegate = self
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.backgroundColor = .black
        view.addSubview(scrollView)
        scrollView.addSubview(imageView)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        scrollView.frame = view.bounds
        guard !configured, view.bounds.width > 0, image.size.width > 0 else { return }
        configured = true

        cropSize = min(view.bounds.width, view.bounds.height)
        imageView.frame = CGRect(origin: .zero, size: image.size)
        scrollView.contentSize = image.size

        // Zoom so the image at least fills the square crop window.
        let minScale = max(cropSize / image.size.width, cropSize / image.size.height)
        scrollView.minimumZoomScale = minScale
        scrollView.maximumZoomScale = minScale * 4
        scrollView.zoomScale = minScale

        // Inset so the crop square (centered) can reach every edge of the image.
        let hInset = (view.bounds.width - cropSize) / 2
        let vInset = (view.bounds.height - cropSize) / 2
        scrollView.contentInset = UIEdgeInsets(top: vInset, left: hInset, bottom: vInset, right: hInset)
        // Center the image in the crop window.
        scrollView.contentOffset = CGPoint(x: scrollView.contentSize.width / 2 - view.bounds.width / 2,
                                           y: scrollView.contentSize.height / 2 - view.bounds.height / 2)
        addOverlay()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    private var cropRect: CGRect {
        CGRect(x: (view.bounds.width - cropSize) / 2,
               y: (view.bounds.height - cropSize) / 2,
               width: cropSize, height: cropSize)
    }

    /// The square of the original image currently framed by the crop window.
    func croppedImage() -> UIImage? {
        guard configured, scrollView.zoomScale > 0 else { return nil }
        let zoom = scrollView.zoomScale
        let cr = cropRect
        let originX = (scrollView.contentOffset.x + cr.minX) / zoom
        let originY = (scrollView.contentOffset.y + cr.minY) / zoom
        let side = cropSize / zoom
        var rect = CGRect(x: originX, y: originY, width: side, height: side).integral
        rect = rect.intersection(CGRect(origin: .zero, size: image.size))
        guard !rect.isEmpty, let cg = image.cgImage?.cropping(to: rect) else { return nil }
        return UIImage(cgImage: cg, scale: 1, orientation: image.imageOrientation)
    }

    /// Dims everything outside the crop square and draws its border.
    private func addOverlay() {
        let overlay = UIView(frame: view.bounds)
        overlay.isUserInteractionEnabled = false
        overlay.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        let path = UIBezierPath(rect: overlay.bounds)
        path.append(UIBezierPath(rect: cropRect).reversing())
        let mask = CAShapeLayer()
        mask.path = path.cgPath
        overlay.layer.mask = mask
        view.addSubview(overlay)

        let border = CAShapeLayer()
        border.path = UIBezierPath(rect: cropRect).cgPath
        border.fillColor = UIColor.clear.cgColor
        border.strokeColor = UIColor.white.cgColor
        border.lineWidth = 1.5
        overlay.layer.addSublayer(border)
    }
}
