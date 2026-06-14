import Foundation
import UniformTypeIdentifiers

/// What a directory entry is. `other` covers anything not specifically handled.
enum FileKind: String, Sendable {
    case folder, image, video, pdf, other

    var sortRank: Int {
        switch self {
        case .folder: return 0
        case .image:  return 1
        case .video:  return 2
        case .pdf:    return 3
        case .other:  return 4
        }
    }

    var systemImage: String {
        switch self {
        case .folder: return "folder.fill"
        case .image:  return "photo"
        case .video:  return "film"
        case .pdf:    return "doc.richtext"
        case .other:  return "doc"
        }
    }
}

/// One item in a folder — a subfolder or a file.
struct Entry: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    let kind: FileKind
    let size: Int64
    let modified: Date
    var id: URL { url }
    var isFolder: Bool { kind == .folder }
    var isViewable: Bool { kind == .image || kind == .video }
    /// Heuristic: iPhone screenshots are PNGs (or named "Screenshot…").
    var isScreenshot: Bool {
        kind == .image && (url.pathExtension.lowercased() == "png"
                           || name.localizedCaseInsensitiveContains("screenshot"))
    }
}

/// Content-type filter for the folder view.
enum TypeFilter: String, CaseIterable, Identifiable {
    case all        = "All"
    case photo      = "Photos"
    case video      = "Videos"
    case screenshot = "Screenshots"
    var id: String { rawValue }
}

/// Resolution filter for videos.
enum VideoRes: String, CaseIterable, Identifiable {
    case all = "All", uhd = "4K", fhd = "1080p", hd = "720p", low = "Low-Res"
    var id: String { rawValue }
}

/// Resolution filter for images.
enum ImageRes: String, CaseIterable, Identifiable {
    case all = "All", high = "2MP+", low = "Low-Res"
    var id: String { rawValue }
}

/// Sub-filter used inside Favorites / To AI views.
enum LabelKind: String, CaseIterable, Identifiable {
    case all = "All", folders = "Folders", photos = "Photos", videos = "Videos"
    var id: String { rawValue }
}

/// Dimensions + HDR for a media file (for resolution/HDR filters).
struct MediaSpec: Sendable {
    var longSide: Int = 0
    var pixels: Int = 0
    var isHDR: Bool = false
    var videoRes: VideoRes { longSide >= 3840 ? .uhd : longSide >= 1920 ? .fhd : longSide >= 1280 ? .hd : .low }
    var imageRes: ImageRes { pixels >= 2_000_000 ? .high : .low }
}

/// Aggregate info for a folder's Get Info screen.
struct FolderStats: Sendable {
    var created: Date?
    var modified: Date?
    var photos = 0
    var videos = 0
    var subfolders = 0
    var size: Int64 = 0
    var minDate: Date?
    var maxDate: Date?
    var mediaURLs: [URL] = []      // temporary, cleared before returning
    var mediaModified: [Date] = [] // temporary, cleared before returning
}

extension Int64 {
    /// File size as KB/MB/GB to two decimals.
    var sizeString: String {
        let bytes = Double(self)
        if bytes >= 1_073_741_824 { return String(format: "%.2f GB", bytes / 1_073_741_824) }
        if bytes >= 1_048_576 { return String(format: "%.2f MB", bytes / 1_048_576) }
        return String(format: "%.2f KB", bytes / 1024)
    }
}

enum SortKey: String, CaseIterable, Identifiable {
    case smart    = "Default"
    case nameAsc  = "Name A–Z"
    case nameDesc = "Name Z–A"
    case dateDesc = "Newest first"
    case dateAsc  = "Oldest first"
    case sizeDesc = "Largest first"
    case sizeAsc  = "Smallest first"
    case kind     = "Kind"
    case ageAsc   = "Age: youngest"
    case ageDesc  = "Age: oldest"
    var id: String { rawValue }
    /// Age sorting is applied in the folder view (it needs per-file ages).
    var isAge: Bool { self == .ageAsc || self == .ageDesc }
}

func classify(url: URL, isDirectory: Bool) -> FileKind {
    if isDirectory { return .folder }
    guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return .other }
    if type.conforms(to: .image) { return .image }
    if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
    if type.conforms(to: .pdf) { return .pdf }
    return .other
}

/// Video extensions that can serve as a Live Photo's motion part.
let livePhotoVideoExtensions = ["mov", "MOV", "mp4", "MP4", "m4v", "M4V"]

/// The sibling motion video for a still image — same base name, a video
/// extension, in the same folder — or nil. The cheap basis for Live Photo
/// pairing (whether the pair is a *valid* Live Photo is confirmed at play time).
func livePhotoVideoURL(for imageURL: URL) -> URL? {
    guard classify(url: imageURL, isDirectory: false) == .image else { return nil }
    let dir = imageURL.deletingLastPathComponent()
    let base = imageURL.deletingPathExtension().lastPathComponent
    let fm = FileManager.default
    for ext in livePhotoVideoExtensions {
        let candidate = dir.appendingPathComponent("\(base).\(ext)")
        if fm.fileExists(atPath: candidate.path) { return candidate }
    }
    return nil
}
