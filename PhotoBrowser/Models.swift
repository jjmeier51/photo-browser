import Foundation
import UniformTypeIdentifiers

/// What a directory entry is. `other` covers anything not specifically handled.
enum FileKind: String, Sendable, Codable {
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
struct Entry: Identifiable, Hashable, Sendable, Codable {
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

extension URL {
    /// A per-file identity that survives external-drive reconnects. External volumes mount under
    /// `…/com.apple.filesystems.userfsd/<UUID>/…`, and that `<UUID>` changes every time the drive is
    /// replugged — so the absolute path changes and every cache keyed on it (thumbnails, capture
    /// dates, media specs, durations) misses, regenerating the whole library on each reconnect.
    /// Dropping the mount-UUID segment yields a stable, drive-relative key. Non-external paths
    /// (no marker) fall through to the full path unchanged.
    /// `nonisolated`: a pure function of `path`, and the listing/index snapshot
    /// helpers key their files with it from detached tasks — under the project's
    /// default-MainActor isolation an unannotated extension member is
    /// MainActor-bound and can't be touched off-main.
    nonisolated var stableCacheID: String {
        let p = path
        guard let r = p.range(of: "/com.apple.filesystems.userfsd/") else { return p }
        let after = p[r.upperBound...]                          // "<UUID>/rest…"
        guard let slash = after.firstIndex(of: "/") else { return String(after) }
        return String(after[after.index(after: slash)...])      // "rest…" (drive-relative)
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
/// Codable so specs persist across launches (see `MetadataLoader`'s spec store) —
/// reading one means opening the file with ImageIO/AVFoundation, far too slow to
/// redo every launch on an external drive.
struct MediaSpec: Sendable, Codable {
    var longSide: Int = 0
    var pixels: Int = 0
    var isHDR: Bool = false
    var duration: Double = 0          // seconds (videos); 0 for photos
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
    case likesDesc    = "Most liked"
    case durationDesc = "Longest first"
    case durationAsc  = "Shortest first"
    var id: String { rawValue }
    /// Age sorting is applied in the folder view (it needs per-file ages).
    var isAge: Bool { self == .ageAsc || self == .ageDesc }
    /// Likes sorting (TikTok folders) is applied in the folder view (needs per-file likes).
    var isLikes: Bool { self == .likesDesc }
    /// Length sorting is applied in the folder view (needs per-file video durations).
    var isDuration: Bool { self == .durationDesc || self == .durationAsc }
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
