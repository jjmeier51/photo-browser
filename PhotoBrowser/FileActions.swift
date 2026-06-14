import SwiftUI
import Photos
import PhotosUI
import UIKit
import QuickLook
import CoreImage
import CoreVideo
import AVFoundation
import ImageIO
import CoreLocation
import UniformTypeIdentifiers

/// Save-to-Photos / delete-from-drive helpers for the selection toolbar.
enum FileActions {

    // MARK: - Metadata editing (capture date + location), photos and videos

    /// Edits a single photo/video's capture date and/or GPS location. `date` nil
    /// leaves the date; `location` sets it; `removeLocation` strips it.
    static func applyMetadata(date: Date?, location: CLLocationCoordinate2D?,
                              removeLocation: Bool, to url: URL) async -> Bool {
        switch classify(url: url, isDirectory: false) {
        case .image: return writeImageMetadata(date: date, location: location, removeLocation: removeLocation, to: url)
        case .video: return await writeVideoMetadata(date: date, location: location, removeLocation: removeLocation, to: url)
        default:     return false
        }
    }

    /// Bulk version (off the main thread); returns the count written.
    static func applyMetadata(date: Date?, location: CLLocationCoordinate2D?, removeLocation: Bool,
                              to urls: [URL], progress: @escaping @Sendable (Double) -> Void = { _ in }) async -> Int {
        var count = 0
        for (i, url) in urls.enumerated() {
            if await applyMetadata(date: date, location: location, removeLocation: removeLocation, to: url) { count += 1 }
            progress(Double(i + 1) / Double(max(urls.count, 1)))
        }
        return count
    }

    /// Lossless EXIF rewrite (the encoded image is copied; only metadata changes).
    private static func writeImageMetadata(date: Date?, location: CLLocationCoordinate2D?,
                                           removeLocation: Bool, to url: URL) -> Bool {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(src) else { return false }
        var props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]

        if let date {
            let f = DateFormatter(); f.dateFormat = "yyyy:MM:dd HH:mm:ss"; f.timeZone = .current
            let stamp = f.string(from: date)
            var exif = (props[kCGImagePropertyExifDictionary] as? [CFString: Any]) ?? [:]
            exif[kCGImagePropertyExifDateTimeOriginal] = stamp
            exif[kCGImagePropertyExifDateTimeDigitized] = stamp
            props[kCGImagePropertyExifDictionary] = exif
            var tiff = (props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]) ?? [:]
            tiff[kCGImagePropertyTIFFDateTime] = stamp
            props[kCGImagePropertyTIFFDictionary] = tiff
        }
        if removeLocation {
            props.removeValue(forKey: kCGImagePropertyGPSDictionary)
        } else if let location {
            props[kCGImagePropertyGPSDictionary] = [
                kCGImagePropertyGPSLatitude: abs(location.latitude),
                kCGImagePropertyGPSLatitudeRef: location.latitude >= 0 ? "N" : "S",
                kCGImagePropertyGPSLongitude: abs(location.longitude),
                kCGImagePropertyGPSLongitudeRef: location.longitude >= 0 ? "E" : "W"
            ] as [CFString: Any]
        }

        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".pbtmp_" + UUID().uuidString).appendingPathExtension(url.pathExtension)
        guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, type, 1, nil) else { return false }
        CGImageDestinationAddImageFromSource(dest, src, 0, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { try? FileManager.default.removeItem(at: tmp); return false }
        do { _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp); return true }
        catch { try? FileManager.default.removeItem(at: tmp); return false }
    }

    /// Rewrites a video's creation date / location via a pass-through export
    /// (no re-encode) into a temp file, then swaps it in.
    private static func writeVideoMetadata(date: Date?, location: CLLocationCoordinate2D?,
                                           removeLocation: Bool, to url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else { return false }

        // Keep existing metadata, drop any old date/location, add the new values.
        var meta = ((try? await asset.load(.metadata)) ?? []).filter { item in
            item.commonKey != .commonKeyCreationDate && item.commonKey != .commonKeyLocation &&
            item.identifier != .quickTimeMetadataCreationDate &&
            item.identifier != .quickTimeMetadataLocationISO6709 &&
            item.identifier != .commonIdentifierCreationDate &&
            item.identifier != .commonIdentifierLocation
        }
        if let date {
            let iso = ISO8601DateFormatter().string(from: date)
            for id in [AVMetadataIdentifier.commonIdentifierCreationDate, .quickTimeMetadataCreationDate] {
                let item = AVMutableMetadataItem()
                item.identifier = id
                item.value = iso as NSString
                meta.append(item)
            }
        }
        if !removeLocation, let location {
            let iso6709 = String(format: "%+09.5f%+010.5f/", location.latitude, location.longitude)
            for id in [AVMetadataIdentifier.quickTimeMetadataLocationISO6709, .commonIdentifierLocation] {
                let item = AVMutableMetadataItem()
                item.identifier = id
                item.value = iso6709 as NSString
                meta.append(item)
            }
        }
        export.metadata = meta

        let ext = url.pathExtension.lowercased()
        let fileType: AVFileType = ext == "mp4" ? .mp4 : (ext == "m4v" ? .m4v : .mov)
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".pbtmp_" + UUID().uuidString).appendingPathExtension(ext.isEmpty ? "mov" : ext)
        export.outputURL = tmp
        export.outputFileType = fileType
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { cont.resume() }
        }
        guard export.status == .completed else { try? FileManager.default.removeItem(at: tmp); return false }
        do { _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp); return true }
        catch { try? FileManager.default.removeItem(at: tmp); return false }
    }

    static func delete(_ entries: [Entry]) {
        for e in entries { try? FileManager.default.removeItem(at: e.url) }
    }

    /// Copies each file in place as "<name> copy.ext" (non-colliding). Returns the count.
    @discardableResult
    static func duplicate(_ entries: [Entry]) -> Int {
        var count = 0
        for e in entries where !e.isFolder {
            let folder = e.url.deletingLastPathComponent()
            let base = e.url.deletingPathExtension().lastPathComponent
            let ext = e.url.pathExtension
            let name = ext.isEmpty ? "\(base) copy" : "\(base) copy.\(ext)"
            let dest = uniqueDestination(for: name, in: folder)
            if (try? FileManager.default.copyItem(at: e.url, to: dest)) != nil { count += 1 }
        }
        return count
    }

    @discardableResult
    static func createFolder(named name: String, in parent: URL) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let dest = parent.appendingPathComponent(trimmed, isDirectory: true)
        return (try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: false)) != nil
    }

    /// Renames an item; returns its new URL on success so labels can follow it.
    @discardableResult
    static func rename(_ url: URL, to newName: String) -> URL? {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let dest = url.deletingLastPathComponent().appendingPathComponent(trimmed)
        return (try? FileManager.default.moveItem(at: url, to: dest)) != nil ? dest : nil
    }

    struct MoveOutcome { var moved: [(from: URL, to: URL)] = []; var skipped: [(name: String, reason: String)] = [] }

    /// Moves items into `folder`. Returns each successful (old, new) pair (so
    /// labels/captions can be migrated) plus the items that were skipped and why.
    /// A same-name file at the destination is skipped (not overwritten/renamed);
    /// a plain `moveItem` failure (e.g. crossing a file-provider/volume boundary,
    /// the documented reason in-folder moves silently failed) falls back to
    /// copy-then-delete so the file actually moves.
    @discardableResult
    static func move(_ urls: [URL], to folder: URL) -> MoveOutcome {
        let fm = FileManager.default
        var outcome = MoveOutcome()
        for url in urls {
            let name = url.lastPathComponent
            if url.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL {
                outcome.skipped.append((name, "already in this folder")); continue
            }
            let dest = folder.appendingPathComponent(name)
            if fm.fileExists(atPath: dest.path) {
                outcome.skipped.append((name, "name already exists")); continue
            }
            do {
                try fm.moveItem(at: url, to: dest)
                outcome.moved.append((url, dest))
            } catch {
                // Cross-volume moves aren't atomic; copy-then-delete instead.
                if (try? fm.copyItem(at: url, to: dest)) != nil {
                    try? fm.removeItem(at: url)
                    outcome.moved.append((url, dest))
                } else {
                    outcome.skipped.append((name, "couldn't move"))
                }
            }
        }
        return outcome
    }

    /// Copies items into `folder`, never colliding (appends " 1", " 2", … on clash,
    /// incl. copy-into-same-folder). Returns each successful (old, new) URL pair.
    /// Copies are fresh files and intentionally carry no labels — the originals keep
    /// theirs — so callers must NOT migrate metadata onto the copies.
    @discardableResult
    static func copy(_ urls: [URL], to folder: URL) -> [(from: URL, to: URL)] {
        var copied: [(from: URL, to: URL)] = []
        for url in urls {
            let dest = uniqueDestination(for: url.lastPathComponent, in: folder)
            if (try? FileManager.default.copyItem(at: url, to: dest)) != nil { copied.append((url, dest)) }
        }
        return copied
    }

    struct SaveResult { var saved: Int; var failed: Int; var note: String? }

    struct TransferResult { var destFolder: URL?; var moved: Int; var failed: Int }
    struct TransferProgress: Sendable { var fraction: Double; var done: Int; var total: Int; var currentName: String }

    /// Copies (or moves) the entire contents of `source` into a new subfolder of
    /// `parent` named after the source, file-by-file (recursively) so progress is
    /// real-time. Cross-volume moves copy-then-delete, so this works between two
    /// external drives. The new subfolder is returned so labels can be migrated to it.
    static func transferContents(from source: URL, into parent: URL, move: Bool,
                                 progress: @escaping @Sendable (TransferProgress) -> Void) async -> TransferResult {
        let fm = FileManager.default
        let folderName = source.lastPathComponent.isEmpty ? "Imported Drive" : source.lastPathComponent
        let destFolder = uniqueDestination(for: folderName, in: parent)
        try? fm.createDirectory(at: destFolder, withIntermediateDirectories: true)

        progress(TransferProgress(fraction: 0, done: 0, total: 0, currentName: "Scanning…"))
        // Every regular file under the source, recursively.
        var files: [URL] = []
        if let walker = fm.enumerator(at: source, includingPropertiesForKeys: [.isRegularFileKey],
                                      options: [.skipsHiddenFiles]) {
            for case let url as URL in walker {
                if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                    files.append(url)
                }
            }
        }
        let total = files.count
        guard total > 0 else { return TransferResult(destFolder: destFolder, moved: 0, failed: 0) }
        let sourcePath = source.path

        var moved = 0, failed = 0, done = 0
        await withTaskGroup(of: (Bool, String).self) { group in
            var index = 0
            func addNext() {
                guard index < total else { return }
                let file = files[index]; index += 1
                let rel = String(file.path.dropFirst(sourcePath.count).drop(while: { $0 == "/" }))
                let target = destFolder.appendingPathComponent(rel)
                group.addTask(priority: .userInitiated) {
                    let fm = FileManager.default
                    try? fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if fm.fileExists(atPath: target.path) { try? fm.removeItem(at: target) }
                    do {
                        if move { try fm.moveItem(at: file, to: target) }
                        else { try fm.copyItem(at: file, to: target) }
                        await preserveCaptureDate(target)   // keep capture date, not the copy time
                        return (true, file.lastPathComponent)
                    } catch { return (false, file.lastPathComponent) }
                }
            }
            for _ in 0..<min(4, total) { addNext() }
            while let (ok, name) = await group.next() {
                if ok { moved += 1 } else { failed += 1 }
                done += 1
                progress(TransferProgress(fraction: Double(done) / Double(total),
                                          done: done, total: total, currentName: name))
                addNext()
            }
        }
        if move { removeEmptyDirectories(under: source) }
        return TransferResult(destFolder: destFolder, moved: moved, failed: failed)
    }

    /// Removes empty directories left behind after a file-by-file move.
    private static func removeEmptyDirectories(under root: URL) {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                         options: []) else { return }
        var dirs: [URL] = []
        for case let url as URL in walker {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { dirs.append(url) }
        }
        // Deepest first so parents become empty too.
        for dir in dirs.sorted(by: { $0.path.count > $1.path.count }) {
            if let contents = try? fm.contentsOfDirectory(atPath: dir.path), contents.isEmpty {
                try? fm.removeItem(at: dir)
            }
        }
    }

    /// Copies images/videos into the iOS Photos library.
    @discardableResult
    static func saveToPhotos(_ entries: [Entry]) async -> SaveResult {
        let media = entries.filter { $0.kind == .image || $0.kind == .video }
        guard !media.isEmpty else {
            return SaveResult(saved: 0, failed: 0, note: "No photos or videos selected.")
        }
        // Calling the Photos add API without this Info.plist key hard-crashes the
        // app — guard so we show a message instead.
        guard Bundle.main.object(forInfoDictionaryKey: "NSPhotoLibraryAddUsageDescription") != nil else {
            return SaveResult(saved: 0, failed: media.count,
                note: "Add the “Photo Library Additions Usage Description” key in Xcode (target → Info) to enable Save to Photos.")
        }
        guard await ensureAddPermission() else {
            return SaveResult(saved: 0, failed: media.count,
                note: "Photos access denied. Enable it in Settings → Photos.")
        }

        var saved = 0, failed = 0
        for e in media {
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    let request = PHAssetCreationRequest.forAsset()
                    let type: PHAssetResourceType = (e.kind == .video) ? .video : .photo
                    request.addResource(with: type, fileURL: e.url, options: nil)
                }
                saved += 1
            } catch {
                failed += 1
            }
        }
        return SaveResult(saved: saved, failed: failed, note: nil)
    }

    private static func ensureAddPermission() async -> Bool {
        let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if current == .authorized || current == .limited { return true }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        return status == .authorized || status == .limited
    }

    private static func ensureReadWritePermission() async -> Bool {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if current == .authorized || current == .limited { return true }
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return status == .authorized || status == .limited
    }

    // MARK: - Import from the iOS Photos library

    /// Copies the picked Photos items into `folder`. Returns each new drive URL
    /// with its source asset identifier (so the origin can be tracked).
    static func importFromPhotos(_ results: [PHPickerResult], into folder: URL) async -> [(url: URL, assetID: String?)] {
        // Import several at once: each item downloads from iCloud before it's copied,
        // so a sequential loop is slow. Bounded concurrency overlaps the downloads.
        let maxConcurrent = 5
        var imported: [(url: URL, assetID: String?)] = []
        var index = 0
        await withTaskGroup(of: (url: URL, assetID: String?)?.self) { group in
            func addNext() {
                guard index < results.count else { return }
                let result = results[index]; index += 1
                group.addTask {
                    let provider = result.itemProvider
                    let typeID: String
                    if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
                        typeID = UTType.movie.identifier
                    } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                        typeID = UTType.image.identifier
                    } else {
                        return nil
                    }
                    guard let dest = await copyRepresentation(provider, typeID: typeID, into: folder) else { return nil }
                    await preserveCaptureDate(dest)
                    return (url: dest, assetID: result.assetIdentifier)
                }
            }
            for _ in 0..<min(maxConcurrent, results.count) { addNext() }
            while let item = await group.next() {
                if let item { imported.append(item) }
                addNext()
            }
        }
        return imported
    }

    /// Sets a media file's modification date to its embedded capture date, so a
    /// freshly imported/copied file sorts by when it was *taken*, not when it was
    /// added to the drive (the import writes the file "now"). No-op for non-media
    /// or files with no readable capture date — those keep their existing date.
    nonisolated static func preserveCaptureDate(_ url: URL) async {
        let kind = classify(url: url, isDirectory: false)
        guard kind == .image || kind == .video else { return }
        let entry = Entry(url: url, name: url.lastPathComponent, kind: kind, size: 0, modified: Date())
        guard let captured = await MetadataLoader.captureDate(for: entry) else { return }
        try? FileManager.default.setAttributes([.modificationDate: captured], ofItemAtPath: url.path)
    }

    struct RestoreResult: Sendable {
        var fixed = 0          // total modified-date writes that succeeded
        var fromFallback = 0   // of those, ones using a non-embedded source
        var scanned = 0
        var noDate = 0         // no date found from any source
        var failed = 0         // a date was found but the write failed
    }

    private enum RestoreOutcome { case fixedEmbedded, fixedFallback, unchanged, noDate, failed }

    /// Repairs items whose modified date was changed to the import time: walks
    /// `folder` (recursively) and resets each photo/video's modified date to its
    /// real capture date. The embedded EXIF/QuickTime date is tried first; when a
    /// file carries none (PNG/screenshots, stripped MP4s, downloads), it falls back
    /// to GPS/IPTC EXIF, then the originating Photos asset (`origins`: path→localId),
    /// then a date parsed from the filename. Only rewrites when the dates differ.
    nonisolated static func restoreCaptureDates(
        in folder: URL, origins: [String: String] = [:],
        progress: @escaping @Sendable (Int, Int) -> Void) async -> RestoreResult {
        let fm = FileManager.default
        var files: [URL] = []
        if let walker = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                      options: [.skipsHiddenFiles]) {
            for case let url as URL in walker {
                let kind = classify(url: url, isDirectory: false)
                if kind == .image || kind == .video { files.append(url) }
            }
        }
        let total = files.count
        guard total > 0 else { return RestoreResult() }

        var result = RestoreResult(); result.scanned = total
        var done = 0, index = 0
        await withTaskGroup(of: RestoreOutcome.self) { group in
            func addNext() {
                guard index < total else { return }
                let url = files[index]; index += 1
                let originId = origins[url.path]
                group.addTask { await restoreOne(url, originId: originId) }
            }
            for _ in 0..<min(6, total) { addNext() }
            while let outcome = await group.next() {
                switch outcome {
                case .fixedEmbedded: result.fixed += 1
                case .fixedFallback: result.fixed += 1; result.fromFallback += 1
                case .noDate:        result.noDate += 1
                case .failed:        result.failed += 1
                case .unchanged:     break
                }
                done += 1
                progress(done, total)
                addNext()
            }
        }
        return result
    }

    private nonisolated static func restoreOne(_ url: URL, originId: String?) async -> RestoreOutcome {
        let kind = classify(url: url, isDirectory: false)
        let entry = Entry(url: url, name: url.lastPathComponent, kind: kind, size: 0, modified: Date())
        var date = await MetadataLoader.captureDate(for: entry)     // 1. embedded EXIF/QuickTime
        var fromFallback = false
        if date == nil {                                            // 2. GPS / IPTC EXIF
            date = await MetadataLoader.auxCaptureDate(for: entry); if date != nil { fromFallback = true }
        }
        if date == nil, let originId {                              // 3. originating Photos asset
            date = await photosCreationDate(for: originId); if date != nil { fromFallback = true }
        }
        if date == nil {                                            // 4. filename
            date = MetadataLoader.dateFromFilename(url.lastPathComponent); if date != nil { fromFallback = true }
        }
        guard let captured = date else { return .noDate }
        let current = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let current, abs(current.timeIntervalSince(captured)) < 1 { return .unchanged }   // already correct
        guard setModificationDate(captured, on: url) else { return .failed }
        return fromFallback ? .fixedFallback : .fixedEmbedded
    }

    /// Writes the file's modified date, retrying via URL resource values if the
    /// POSIX `setAttributes` path is refused on some volumes.
    private nonisolated static func setModificationDate(_ date: Date, on url: URL) -> Bool {
        do {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
            return true
        } catch {
            var u = url
            var values = URLResourceValues(); values.contentModificationDate = date
            return (try? u.setResourceValues(values)) != nil
        }
    }

    /// Creation date of an originating Photos asset (best-effort; no permission prompt).
    private nonisolated static func photosCreationDate(for localId: String) async -> Date? {
        guard Bundle.main.object(forInfoDictionaryKey: "NSPhotoLibraryUsageDescription") != nil else { return nil }
        return PHAsset.fetchAssets(withLocalIdentifiers: [localId], options: nil).firstObject?.creationDate
    }

    // MARK: - Live Photo creation

    struct LivePhotoResult: Sendable { var ok: Bool; var newVideo: URL? }

    /// Pairs a still photo + a video into a Live Photo: writes a shared asset
    /// identifier into the photo's Apple maker note, and writes the motion part as a
    /// QuickTime `.mov` (named to match the photo) carrying the matching
    /// `content.identifier` and a "still-image-time" timed-metadata track, so
    /// `PHLivePhoto` recognises the pair. All off-main. The timed-metadata track can
    /// only be fully verified on-device — failures are non-destructive.
    nonisolated static func makeLivePhoto(image: URL, video: URL) async -> LivePhotoResult {
        let id = UUID().uuidString
        guard writeAssetIdentifier(id, intoImage: image) else { return LivePhotoResult(ok: false, newVideo: nil) }
        // The motion part is a QuickTime .mov named to match the photo (so the pair
        // is detected) — unless a different file already holds that name.
        let desired = video.deletingLastPathComponent()
            .appendingPathComponent("\(image.deletingPathExtension().lastPathComponent).mov")
        let final = (desired == video || !FileManager.default.fileExists(atPath: desired.path)) ? desired : video
        guard await writeLivePhotoVideo(id, source: video, to: final) else { return LivePhotoResult(ok: false, newVideo: nil) }
        if final.standardizedFileURL != video.standardizedFileURL {
            try? FileManager.default.removeItem(at: video)   // original replaced by the identified .mov
        }
        return LivePhotoResult(ok: true, newVideo: final)
    }

    /// Embeds the asset identifier in the still's Apple maker note (key "17"), in
    /// place. All existing image metadata (EXIF/GPS/orientation) is copied across,
    /// and the file's original creation/modification dates are restored afterwards.
    private nonisolated static func writeAssetIdentifier(_ id: String, intoImage url: URL) -> Bool {
        let originalDates = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(src) else { return false }
        var props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
        var maker = (props[kCGImagePropertyMakerAppleDictionary] as? [String: Any]) ?? [:]
        maker["17"] = id
        props[kCGImagePropertyMakerAppleDictionary] = maker
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".live-\(UUID().uuidString).tmp")
        guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, type, 1, nil) else { return false }
        CGImageDestinationAddImageFromSource(dest, src, 0, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { try? FileManager.default.removeItem(at: tmp); return false }
        guard replaceItem(tmp, onto: url) else { return false }
        restoreFileDates(originalDates, to: url)
        return true
    }

    /// Restores creation/modification dates captured from a file's attributes, so an
    /// in-place rewrite doesn't stamp the file with "now".
    private nonisolated static func restoreFileDates(_ attrs: [FileAttributeKey: Any]?, to url: URL) {
        guard let attrs else { return }
        var keep: [FileAttributeKey: Any] = [:]
        if let c = attrs[.creationDate] { keep[.creationDate] = c }
        if let m = attrs[.modificationDate] { keep[.modificationDate] = m }
        if !keep.isEmpty { try? FileManager.default.setAttributes(keep, ofItemAtPath: url.path) }
    }

    /// Rebuilds the video (sample passthrough) adding the content identifier and a
    /// still-image-time metadata track, writing the result to `final`.
    private nonisolated static func writeLivePhotoVideo(_ id: String, source url: URL, to final: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard let reader = try? AVAssetReader(asset: asset),
              let vTrack = try? await asset.loadTracks(withMediaType: .video).first else { return false }
        let originalDates = try? FileManager.default.attributesOfItem(atPath: url.path)
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".live-\(UUID().uuidString).mov")
        guard let writer = try? AVAssetWriter(outputURL: tmp, fileType: .mov) else { return false }

        // Content identifier (ties the video to the still), preserving the source's
        // existing metadata — chiefly the creation date — so it isn't stamped today.
        let idItem = AVMutableMetadataItem()
        idItem.identifier = .quickTimeMetadataContentIdentifier
        idItem.dataType = "com.apple.metadata.datatype.UTF-8"
        idItem.value = id as NSString
        let sourceMeta = ((try? await asset.load(.metadata)) ?? [])
            .filter { $0.identifier != .quickTimeMetadataContentIdentifier }
        writer.metadata = sourceMeta + [idItem]

        // Passthrough video (and audio, if any).
        var pumps: [(AVAssetReaderTrackOutput, AVAssetWriterInput)] = []
        let vOut = AVAssetReaderTrackOutput(track: vTrack, outputSettings: nil); vOut.alwaysCopiesSampleData = false
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: nil); vIn.expectsMediaDataInRealTime = false
        if let t = try? await vTrack.load(.preferredTransform) { vIn.transform = t }
        guard reader.canAdd(vOut), writer.canAdd(vIn) else { return false }
        reader.add(vOut); writer.add(vIn); pumps.append((vOut, vIn))
        if let aTrack = try? await asset.loadTracks(withMediaType: .audio).first {
            let aOut = AVAssetReaderTrackOutput(track: aTrack, outputSettings: nil); aOut.alwaysCopiesSampleData = false
            let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: nil); aIn.expectsMediaDataInRealTime = false
            if reader.canAdd(aOut), writer.canAdd(aIn) { reader.add(aOut); writer.add(aIn); pumps.append((aOut, aIn)) }
        }

        // Still-image-time metadata track (SInt8 value 0 spanning the clip).
        let spec: [String: Any] = [
            kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String: "mdta/com.apple.quicktime.still-image-time",
            kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String: "com.apple.metadata.datatype.int8"
        ]
        var fmt: CMFormatDescription?
        CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
            allocator: kCFAllocatorDefault, metadataType: kCMMetadataFormatType_Boxed,
            metadataSpecifications: [spec] as CFArray, formatDescriptionOut: &fmt)
        let metaIn = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: fmt)
        let metaAdaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: metaIn)
        if writer.canAdd(metaIn) { writer.add(metaIn) }

        guard reader.startReading(), writer.startWriting() else { try? FileManager.default.removeItem(at: tmp); return false }
        writer.startSession(atSourceTime: .zero)

        let duration = (try? await asset.load(.duration)) ?? CMTime(value: 1, timescale: 30)
        let still = AVMutableMetadataItem()
        still.identifier = AVMetadataItem.identifier(forKey: "com.apple.quicktime.still-image-time", keySpace: .quickTimeMetadata)
        still.dataType = "com.apple.metadata.datatype.int8"
        still.value = 0 as NSNumber
        metaAdaptor.append(AVTimedMetadataGroup(items: [still], timeRange: CMTimeRange(start: .zero, duration: duration)))
        metaIn.markAsFinished()

        await withTaskGroup(of: Void.self) { tg in
            for (out, input) in pumps { tg.addTask { await drain(out, into: input) } }
        }
        guard reader.status != .failed else { try? FileManager.default.removeItem(at: tmp); return false }
        await writer.finishWriting()
        guard writer.status == .completed else { try? FileManager.default.removeItem(at: tmp); return false }
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: final.path) { try fm.removeItem(at: final) }   // overwrite source/target
            try fm.moveItem(at: tmp, to: final)
            restoreFileDates(originalDates, to: final)   // keep the original capture date, not today
            return true
        } catch { try? fm.removeItem(at: tmp); return false }
    }

    /// Drains one reader output into one writer input, resuming exactly once.
    private nonisolated static func drain(_ output: AVAssetReaderTrackOutput, into input: AVAssetWriterInput) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let once = ResumeOnce(cont)
            input.requestMediaDataWhenReady(on: DispatchQueue(label: "live.drain")) {
                while input.isReadyForMoreMediaData {
                    guard let sb = output.copyNextSampleBuffer() else { input.markAsFinished(); once.fire(); return }
                    if !input.append(sb) { input.markAsFinished(); once.fire(); return }
                }
            }
        }
    }

    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock(); private var done = false
        private let cont: CheckedContinuation<Void, Never>
        init(_ c: CheckedContinuation<Void, Never>) { cont = c }
        func fire() { lock.lock(); defer { lock.unlock() }; if !done { done = true; cont.resume() } }
    }

    private nonisolated static func replaceItem(_ tmp: URL, onto dest: URL) -> Bool {
        let fm = FileManager.default
        if (try? fm.replaceItemAt(dest, withItemAt: tmp)) != nil { return true }
        do {
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.moveItem(at: tmp, to: dest)
            return true
        } catch { try? fm.removeItem(at: tmp); return false }
    }

    private static func copyRepresentation(_ provider: NSItemProvider, typeID: String, into folder: URL) async -> URL? {
        await withCheckedContinuation { (cont: CheckedContinuation<URL?, Never>) in
            // The temp file is only valid inside this completion, so copy now.
            provider.loadFileRepresentation(forTypeIdentifier: typeID) { tempURL, _ in
                guard let tempURL else { cont.resume(returning: nil); return }
                let fm = FileManager.default
                let name = tempURL.lastPathComponent
                func attempt(_ dest: URL) -> URL? {
                    (try? fm.copyItem(at: tempURL, to: dest)) != nil ? dest : nil
                }
                if let dest = attempt(uniqueDestination(for: name, in: folder)) {
                    cont.resume(returning: dest); return
                }
                // A concurrent import may have taken the same name first — retry unique.
                let unique = folder.appendingPathComponent(String(UUID().uuidString.prefix(8)) + "-" + name)
                cont.resume(returning: attempt(unique))
            }
        }
    }

    /// A non-colliding destination URL inside `folder` for the given filename.
    static func uniqueDestination(for name: String, in folder: URL) -> URL {
        let fm = FileManager.default
        var dest = folder.appendingPathComponent(name.isEmpty ? "Photo" : name)
        let base = dest.deletingPathExtension().lastPathComponent
        let ext = dest.pathExtension
        var n = 1
        while fm.fileExists(atPath: dest.path) {
            let newName = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            dest = folder.appendingPathComponent(newName)
            n += 1
        }
        return dest
    }

    /// Deletes the given assets from the iOS Photos library (→ Recently Deleted).
    /// iOS shows its own confirmation prompt during the change.
    @discardableResult
    static func deletePhotosAssets(_ identifiers: [String]) async -> Bool {
        guard !identifiers.isEmpty else { return true }
        // Requesting read/write access without this Info.plist key hard-crashes;
        // guard so a missing key just skips the Photos-library deletion.
        guard Bundle.main.object(forInfoDictionaryKey: "NSPhotoLibraryUsageDescription") != nil else { return false }
        guard await ensureReadWritePermission() else { return false }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        guard assets.count > 0 else { return false }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assets)
            }
            return true
        } catch {
            return false
        }
    }

    // MARK: - Video frame capture (content only, HDR-aware)

    private static let ciContext = CIContext()

    /// Encodes one video frame to image data: oriented upright, metadata embedded,
    /// 10-bit HDR HEIC when the frame is HDR, otherwise a standard HEIC.
    static func encodeFrame(_ pixelBuffer: CVPixelBuffer,
                            transform: CGAffineTransform,
                            properties: [String: Any]) -> Data? {
        var ci = CIImage(cvImageBuffer: pixelBuffer)
        if !transform.isIdentity {
            // CIImage is Y-up but the video transform is Y-down, so the rotation
            // direction is flipped — conjugate it (negate b/c) to rotate correctly.
            var t = transform
            t.b = -t.b
            t.c = -t.c
            ci = ci.transformed(by: t)
            ci = ci.transformed(by: CGAffineTransform(translationX: -ci.extent.origin.x,
                                                      y: -ci.extent.origin.y))
        }
        if !properties.isEmpty {
            ci = ci.settingProperties(ci.properties.merging(properties) { _, new in new })
        }

        let cs = ci.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let name = (cs.name as String?) ?? ""
        let isHDR = name.contains("2100") || name.contains("2020") || name.contains("HLG") || name.contains("PQ")

        var data: Data?
        if isHDR {
            data = try? ciContext.heif10Representation(of: ci, colorSpace: cs, options: [:])
        }
        if data == nil {
            let sdr = CGColorSpace(name: CGColorSpace.displayP3) ?? cs
            data = ciContext.heifRepresentation(of: ci, format: .RGBA8, colorSpace: sdr, options: [:])
        }
        if data == nil, let cg = ciContext.createCGImage(ci, from: ci.extent) {
            data = UIImage(cgImage: cg).pngData()
        }
        return data
    }

    /// The "Screenshots" folder beside `fileURL`, created on first use (nil on failure).
    static func screenshotsFolder(beside fileURL: URL) -> URL? {
        let dir = fileURL.deletingLastPathComponent().appendingPathComponent("Screenshots", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            guard (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) != nil else { return nil }
        }
        return dir
    }

    /// Encodes a captured frame and writes it into `folder` as a timestamped HEIC
    /// (PNG only on encode fallback). Returns the new file URL, or nil on failure.
    static func saveFrame(_ pixelBuffer: CVPixelBuffer,
                          transform: CGAffineTransform = .identity,
                          properties: [String: Any] = [:],
                          in folder: URL) -> URL? {
        guard let data = encodeFrame(pixelBuffer, transform: transform, properties: properties) else { return nil }
        return writeScreenshot(data, in: folder)
    }

    /// CGImage variant — used by the SDR generator fallback.
    static func saveFrame(cgImage: CGImage, properties: [String: Any] = [:], in folder: URL) -> URL? {
        guard let data = encodeCGImage(cgImage, properties: properties) else { return nil }
        return writeScreenshot(data, in: folder)
    }

    private static func writeScreenshot(_ data: Data, in folder: URL) -> URL? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let ext = data.starts(with: [0x89, 0x50, 0x4E, 0x47] as [UInt8]) ? "png" : "heic"   // PNG magic → png
        let dest = uniqueDestination(for: "Screenshot \(f.string(from: Date())).\(ext)", in: folder)
        return (try? data.write(to: dest)) != nil ? dest : nil
    }

    /// Upper bound on exported frames per second of video.
    static let exportFramesPerSecond = 20.0
    /// Minimum source-frame stride: take at most 1 of every 3 frames, so 24fps →
    /// 8/sec, 30fps → 10/sec, 60fps → 20/sec. Higher-fps video uses a larger
    /// stride so it never exceeds `exportFramesPerSecond`.
    static let minExportStride = 3

    // MARK: - Export-progress persistence (resume after a crash/suspension)

    /// Saved state for an in-progress frame export. Frames are named by index, so
    /// a re-run just continues from `nextIndex` (and skips any frame already on
    /// disk) — robust across crashes and the background-task time limit.
    struct ExportProgress: Codable, Sendable { var folder: String; var total: Int; var nextIndex: Int }

    private static let exportProgressKey = "photoBrowser.exportProgress"
    private static let exportProgressLock = NSLock()

    static func exportProgress(forVideoKey key: String) -> ExportProgress? {
        guard let data = UserDefaults.standard.data(forKey: exportProgressKey),
              let map = try? JSONDecoder().decode([String: ExportProgress].self, from: data) else { return nil }
        return map[key]
    }

    private static func setExportProgress(_ progress: ExportProgress?, forVideoKey key: String) {
        exportProgressLock.lock(); defer { exportProgressLock.unlock() }
        var map: [String: ExportProgress] = [:]
        if let data = UserDefaults.standard.data(forKey: exportProgressKey),
           let decoded = try? JSONDecoder().decode([String: ExportProgress].self, from: data) { map = decoded }
        if let progress { map[key] = progress } else { map.removeValue(forKey: key) }
        if let data = try? JSONEncoder().encode(map) { UserDefaults.standard.set(data, forKey: exportProgressKey) }
    }

    /// Stable per-video key (path|mtime|size) — matches MetadataLoader's scheme.
    static func videoExportKey(for url: URL) -> String {
        let rv = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let mtime = Int((rv?.contentModificationDate ?? .distantPast).timeIntervalSince1970)
        return "\(url.path)|\(mtime)|\(rv?.fileSize ?? 0)"
    }

    /// Exports frames of a video — evenly sampled to `exportFramesPerSecond` — as
    /// upright, metadata-preserving HEICs into a folder (named `folderName`) beside
    /// the video. Frames are named by index and progress is persisted, so a re-run
    /// resumes where a crash/suspension left off (skipping frames already on disk).
    /// HDR videos export 10-bit HDR HEICs (via a reader that restarts on failure);
    /// SDR videos use AVAssetImageGenerator. `onProgress` is called (off the main
    /// thread) with 0…1 completion.
    static func exportAllFrames(of url: URL,
                                folderName: String,
                                onProgress: @escaping @Sendable (Double) -> Void = { _ in })
    async -> (folder: URL?, count: Int, firstFrame: URL?) {
        let name = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeName = name.isEmpty ? (url.deletingPathExtension().lastPathComponent + " Frames") : name
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return (nil, 0, nil) }
        let isHDR = ((try? await track.load(.mediaCharacteristics))?.contains(.containsHDRVideo)) ?? false
        let props = await MetadataLoader.exifProperties(forVideo: url)
        let duration = (try? await asset.load(.duration))?.seconds ?? 0
        let fps = (try? await track.load(.nominalFrameRate)).map(Double.init) ?? 0
        // 1 of every `stride` frames → 30fps ≈ 5/s, 60fps ≈ 10/s, capped at 10/s.
        let stride = max(minExportStride, Int((fps / exportFramesPerSecond).rounded()))
        let interval = fps > 0 ? Double(stride) / fps : 1.0 / exportFramesPerSecond
        guard duration > 0, interval > 0 else { return (nil, 0, nil) }
        let total = max(1, Int((duration / interval).rounded(.up)))

        // Resume into the saved folder if a prior export of this exact file is
        // unfinished; otherwise start a fresh folder beside the video.
        let videoKey = videoExportKey(for: url)
        let dir: URL
        var startIndex = 0
        if let saved = exportProgress(forVideoKey: videoKey),
           FileManager.default.fileExists(atPath: saved.folder) {
            dir = URL(fileURLWithPath: saved.folder)
            startIndex = min(max(0, saved.nextIndex), total)
        } else {
            dir = url.deletingLastPathComponent().appendingPathComponent(safeName, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        setExportProgress(ExportProgress(folder: dir.path, total: total, nextIndex: startIndex), forVideoKey: videoKey)

        let result: (URL?, Int)
        if isHDR {
            let transform = (try? await track.load(.preferredTransform)) ?? .identity
            result = await exportFramesHDR(asset: asset, track: track, transform: transform, dir: dir,
                                           safeName: safeName, props: props, duration: duration, interval: interval,
                                           total: total, startIndex: startIndex, videoKey: videoKey, onProgress: onProgress)
        } else {
            result = await exportFramesSDR(asset: asset, dir: dir, safeName: safeName, props: props,
                                           duration: duration, interval: interval, total: total,
                                           startIndex: startIndex, videoKey: videoKey, onProgress: onProgress)
        }
        setExportProgress(nil, forVideoKey: videoKey)   // finished → forget the checkpoint
        // Report the total frames now on disk (resumed + previously-exported).
        let onDisk = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil,
                                                                   options: [.skipsHiddenFiles]))?.count ?? result.1
        // Index-0 frame, used by the caller to seed the new folder's cover.
        let firstFramePath = dir.appendingPathComponent("\(safeName) 0.heic")
        let firstFrame = FileManager.default.fileExists(atPath: firstFramePath.path) ? firstFramePath : nil
        return (result.0, onDisk, firstFrame)
    }

    /// SDR path: AVAssetImageGenerator at evenly-spaced times (one bad frame is
    /// skipped). Resumes from `startIndex`; frames are named by absolute index.
    private static func exportFramesSDR(asset: AVURLAsset, dir: URL, safeName: String,
                                        props: [String: Any], duration: Double, interval: Double,
                                        total: Int, startIndex: Int, videoKey: String,
                                        onProgress: @escaping @Sendable (Double) -> Void) async -> (URL?, Int) {
        let times: [NSValue] = (startIndex..<total).map {
            NSValue(time: CMTime(seconds: Double($0) * interval, preferredTimescale: 600))
        }
        guard !times.isEmpty else { return (dir, 0) }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true                 // upright frames
        generator.maximumSize = CGSize(width: 3840, height: 3840)       // cap peak memory
        generator.requestedTimeToleranceBefore = CMTime(seconds: interval / 2, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: interval / 2, preferredTimescale: 600)

        let outcome: (URL?, Int) = await withCheckedContinuation { (cont: CheckedContinuation<(URL?, Int), Never>) in
            let lock = NSLock()
            var written = 0
            var processed = 0
            var done = Set<Int>()
            var contig = startIndex
            var lastPct = -1
            let pending = times.count
            generator.generateCGImagesAsynchronously(forTimes: times) { requested, image, _, result, _ in
                autoreleasepool {
                    let i = max(0, Int((requested.seconds / interval).rounded()))
                    let dest = dir.appendingPathComponent("\(safeName) \(i).heic")
                    lock.lock()
                    processed += 1
                    if FileManager.default.fileExists(atPath: dest.path) {
                        done.insert(i)
                    } else if result == .succeeded, let image, let data = encodeCGImage(image, properties: props) {
                        try? data.write(to: dest)
                        written += 1
                        done.insert(i)
                    }
                    while done.contains(contig) { contig += 1 }      // contiguous-done frontier
                    let overall = Double(startIndex + processed) / Double(total)
                    let pct = Int(overall * 100)
                    let report = pct != lastPct; if report { lastPct = pct }
                    let finished = processed >= pending
                    let checkpoint = contig
                    let count = written
                    lock.unlock()
                    if processed % 25 == 0 || finished {
                        setExportProgress(ExportProgress(folder: dir.path, total: total, nextIndex: checkpoint), forVideoKey: videoKey)
                    }
                    if report { onProgress(min(1.0, overall)) }
                    if finished { cont.resume(returning: (dir, count)) }
                }
            }
        }
        withExtendedLifetime(generator) {}        // keep the generator alive until done
        return outcome
    }

    /// HDR path: 10-bit AVAssetReader, time-sampled, restarting after the last
    /// good frame whenever the reader fails — so one undecodable frame can't end
    /// the whole export. Resumes from `startIndex`; frames are named by index.
    private static func exportFramesHDR(asset: AVURLAsset, track: AVAssetTrack, transform: CGAffineTransform,
                                        dir: URL, safeName: String, props: [String: Any],
                                        duration: Double, interval: Double, total: Int, startIndex: Int,
                                        videoKey: String,
                                        onProgress: @escaping @Sendable (Double) -> Void) async -> (URL?, Int) {
        await Task.detached(priority: .userInitiated) { () -> (URL?, Int) in
            let settings: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            ]
            var written = 0
            var frameIndex = startIndex                  // next frame index to capture
            var nextTime = Double(startIndex) * interval  // its target time
            var startTime = nextTime                      // where the current reader begins
            var failures = 0
            var lastPct = -1
            var lastSaved = startIndex
            while startTime < duration, failures < 6, frameIndex < total {
                guard let reader = try? AVAssetReader(asset: asset) else { break }
                if startTime > 0 {
                    reader.timeRange = CMTimeRange(start: CMTime(seconds: startTime, preferredTimescale: 600),
                                                   duration: .positiveInfinity)
                }
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
                output.alwaysCopiesSampleData = false
                guard reader.canAdd(output) else { break }
                reader.add(output)
                guard reader.startReading() else { break }

                var lastPTS = startTime
                var advanced = false
                while reader.status == .reading, frameIndex < total, let sample = output.copyNextSampleBuffer() {
                    autoreleasepool {
                        let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                        if pts.isFinite { lastPTS = pts; advanced = true }
                        if pts.isFinite, pts + 1e-4 >= nextTime {
                            let dest = dir.appendingPathComponent("\(safeName) \(frameIndex).heic")
                            if !FileManager.default.fileExists(atPath: dest.path),
                               let pb = CMSampleBufferGetImageBuffer(sample),
                               let data = encodeFrame(pb, transform: transform, properties: props) {
                                try? data.write(to: dest)
                                written += 1
                            }
                            frameIndex += 1
                            nextTime = Double(frameIndex) * interval
                            if nextTime <= pts {                          // sparse frames: skip ahead on the grid
                                frameIndex = Int((pts / interval).rounded(.down)) + 1
                                nextTime = Double(frameIndex) * interval
                            }
                            let overall = min(1.0, Double(frameIndex) / Double(total))
                            let pct = Int(overall * 100)
                            if pct != lastPct { lastPct = pct; onProgress(overall) }
                            if frameIndex - lastSaved >= 25 {
                                lastSaved = frameIndex
                                setExportProgress(ExportProgress(folder: dir.path, total: total, nextIndex: frameIndex), forVideoKey: videoKey)
                            }
                        }
                        CMSampleBufferInvalidate(sample)
                    }
                }
                if reader.status == .completed { break }
                if reader.status == .failed {
                    failures += 1
                    startTime = advanced ? lastPTS + interval : startTime + max(interval, 0.5)
                    if nextTime < startTime {
                        frameIndex = max(frameIndex, Int((startTime / interval).rounded()))
                        nextTime = Double(frameIndex) * interval
                    }
                } else {
                    break       // cancelled / unknown
                }
            }
            onProgress(1.0)
            return (dir, written)
        }.value
    }

    /// Encodes a (upright) CGImage frame to a metadata-embedded HEIC, JPEG fallback.
    static func encodeCGImage(_ image: CGImage, properties: [String: Any]) -> Data? {
        var ci = CIImage(cgImage: image)
        if !properties.isEmpty {
            ci = ci.settingProperties(ci.properties.merging(properties) { _, new in new })
        }
        let cs = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
        if let data = ciContext.heifRepresentation(of: ci, format: .RGBA8, colorSpace: cs, options: [:]) {
            return data
        }
        return UIImage(cgImage: image).jpegData(compressionQuality: 0.95)
    }

}

/// Requests extra execution time so a long job (e.g. exporting frames) keeps
/// running while the app is backgrounded. iOS grants a limited window — usually
/// a few minutes — and ends it if time runs out or the app is force-quit; it
/// can't run indefinitely or after the app is fully terminated.
@MainActor
final class BackgroundTaskHolder {
    private var id: UIBackgroundTaskIdentifier = .invalid

    func begin(name: String) {
        end()
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            self?.end()
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}

/// Wraps the system document picker in "export a copy" mode for Save to Files.
struct FilesExporter: UIViewControllerRepresentable {
    let urls: [URL]
    let onFinish: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: urls, asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onFinish: () -> Void
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { onFinish() }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { onFinish() }
    }
}

/// Identifiable wrapper so a URL can drive a `.sheet(item:)`.
struct PreviewItem: Identifiable {
    let url: URL
    var id: URL { url }
}

/// QuickLook preview for PDFs and other non-media files.
struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}
