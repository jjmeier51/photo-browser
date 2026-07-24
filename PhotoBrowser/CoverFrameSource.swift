import UIKit

/// Supplies the viewer's current image/frame for the album-cover crop. The
/// active page keeps it updated: photos set `staticImage`; videos set a live
/// `liveProvider` that grabs the current frame on demand (plus `liveTime`, the
/// player time of that frame — recorded at grab so an HDR re-render can pull
/// the exact same frame back out of the file).
final class CoverFrameSource {
    var staticImage: UIImage?
    var liveProvider: (() -> UIImage?)?
    var liveTime: (() -> Double)?
    /// Player time (seconds) of the most recent `current()` grab, nil for photos.
    private(set) var lastCaptureTime: Double?

    func current() -> UIImage? {
        lastCaptureTime = liveProvider != nil ? liveTime?() : nil
        return liveProvider?() ?? staticImage
    }
}
