import UIKit

/// Supplies the viewer's current image/frame for the album-cover crop. The
/// active page keeps it updated: photos set `staticImage`; videos set a live
/// `liveProvider` that grabs the current frame on demand.
final class CoverFrameSource {
    var staticImage: UIImage?
    var liveProvider: (() -> UIImage?)?
    func current() -> UIImage? { liveProvider?() ?? staticImage }
}
