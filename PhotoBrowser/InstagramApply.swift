import SwiftUI
import UIKit

/// Shared post-download bookkeeping for an Instagram profile download, so the single
/// import, the bulk import, and any future caller apply results identically: captions,
/// "posted by", the high-res profile-photo cover, highlight bubbles, and the
/// `IGFolderInfo` tracking record. Keeping it in one place means "bulk behaves just
/// like single" stays true even as the flow evolves.
@MainActor
enum InstagramApply {
    /// Writes the app-side metadata for a finished `DownloadResult` into `dest`. Counts
    /// are accumulated onto `prior` unless `forceFull` (a full re-download) replaces them.
    /// Does *not* create or delete the folder — the caller owns that.
    static func apply(_ r: InstagramService.DownloadResult, to dest: URL,
                      already: Set<String>, prior: IGFolderInfo?, forceFull: Bool,
                      library: Library) async {
        // Batched so they persist once (per-item writes were O(n²) on big profiles).
        library.setCaptions(r.captions)
        library.setPostedBy(r.postedBy)
        if let picData = r.profilePic, let img = UIImage(data: picData) {
            library.setCover(img, for: dest)     // the @handle folder always shows the profile photo
            // Seed the enclosing person folder's thumbnail too, so it shows the profile photo
            // instead of a bare folder icon. Force it on a fresh download (overriding any
            // auto-generated cover); on a re-download only fill a missing one. Never touch the
            // root or a folder that is itself an Instagram folder.
            let person = dest.deletingLastPathComponent()
            if person.path != library.rootURL?.path,
               library.instagramInfo(for: person) == nil,
               prior == nil || library.coverURL(for: person) == nil {
                library.setCover(img, for: person)
            }
        }
        // Highlights become bubbles inside the folder, thumbnailed by their first item.
        for path in r.highlightFolders {
            let dir = URL(fileURLWithPath: path)
            library.markInstagramHighlight(dir)
            if library.coverURL(for: dir) == nil, let cover = await firstItemThumbnail(in: dir) {
                library.setCover(cover, for: dir)
            }
        }
        if let profile = r.profile {
            let info = IGFolderInfo(handle: profile.handle, userID: profile.userID,
                                    lastUpdated: Date().timeIntervalSince1970,
                                    downloaded: Array(already.union(r.newIDs)),
                                    photos: forceFull ? r.photos : (prior?.photos ?? 0) + r.photos,
                                    videos: forceFull ? r.videos : (prior?.videos ?? 0) + r.videos)
            library.setInstagramInfo(info, for: dest)
        }
    }

    /// Upscales every downloaded video to at least 1080p **in place**, preserving HDR,
    /// metadata, caption and capture date (via `MediaEditing.upscaleVideo`). Videos
    /// already ≥1080p are left untouched. Reports (done, total). Best-effort.
    static func upscaleVideosTo1080(_ files: [String], progress: @escaping (Int, Int) -> Void) async {
        let videos = files.filter { $0.lowercased().hasSuffix(".mp4") || $0.lowercased().hasSuffix(".mov") }
        guard !videos.isEmpty else { return }
        for (i, path) in videos.enumerated() {
            _ = await MediaEditing.upscaleVideo(url: URL(fileURLWithPath: path), targetShort: 1080) { _ in }
            progress(i + 1, videos.count)
        }
    }

    /// 2× AI Upscale (Lanczos ×2 + denoise + sharpen) of every downloaded **photo**, in place,
    /// EXIF/capture-date preserved — the same pass the Facebook downloader runs. Bounded to 2
    /// concurrent renders; file dates are restored after each in-place swap (the swap resets
    /// them, and the size change re-keys the thumbnail cache naturally). Best-effort.
    static func aiUpscalePhotos2x(_ files: [String], progress: @escaping (Int, Int) -> Void) async {
        let photos = files.filter { ["jpg", "jpeg", "png", "heic"].contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }
        let total = photos.count
        guard total > 0 else { return }
        await withTaskGroup(of: Void.self) { group in
            var idx = 0
            let maxConcurrent = 2
            func addNext() {
                guard idx < photos.count else { return }
                let path = photos[idx]; idx += 1
                group.addTask {
                    let url = URL(fileURLWithPath: path)
                    let dates = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
                    guard MediaEditing.enhancePhotoInPlace(url: url, scale: 2) else { return }
                    var attrs: [FileAttributeKey: Any] = [:]
                    if let c = dates?.creationDate { attrs[.creationDate] = c }
                    if let m = dates?.contentModificationDate { attrs[.modificationDate] = m }
                    if !attrs.isEmpty { try? FileManager.default.setAttributes(attrs, ofItemAtPath: url.path) }
                }
            }
            for _ in 0..<min(maxConcurrent, photos.count) { addNext() }
            var done = 0
            while await group.next() != nil { done += 1; progress(done, total); addNext() }
        }
    }

    /// Doubles the pixel dimensions of every downloaded **photo** in place (Lanczos), preserving
    /// EXIF/capture-date. Reports (done, total). Best-effort.
    static func upscalePhotos2x(_ files: [String], progress: @escaping (Int, Int) -> Void) async {
        let photos = files.filter { classify(url: URL(fileURLWithPath: $0), isDirectory: false) == .image }
        guard !photos.isEmpty else { return }
        for (i, path) in photos.enumerated() {
            await Task.detached(priority: .utility) { _ = MediaEditing.upscalePhotoInPlace(url: URL(fileURLWithPath: path), scale: 2) }.value
            progress(i + 1, photos.count)
        }
    }

    /// A thumbnail of the first photo/video in `dir` (for a highlight-bubble cover).
    static func firstItemThumbnail(in dir: URL) async -> UIImage? {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        guard let first = files.filter({ [.image, .video].contains(classify(url: $0, isDirectory: false)) })
            .sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending })
            .first else { return nil }
        let entry = Entry(url: first, name: first.lastPathComponent,
                          kind: classify(url: first, isDirectory: false), size: 0, modified: Date())
        return await Thumbnailer.shared.thumbnail(for: entry, size: CGSize(width: 200, height: 200), scale: 2)
    }
}
