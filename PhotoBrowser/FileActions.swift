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

    /// Moves items into `folder`; returns each successful (old, new) URL pair so
    /// labels and captions can be migrated to the new locations.
    @discardableResult
    static func move(_ urls: [URL], to folder: URL) -> [(from: URL, to: URL)] {
        var moved: [(from: URL, to: URL)] = []
        for url in urls where url.deletingLastPathComponent().standardizedFileURL != folder.standardizedFileURL {
            let dest = folder.appendingPathComponent(url.lastPathComponent)
            if (try? FileManager.default.moveItem(at: url, to: dest)) != nil { moved.append((url, dest)) }
        }
        return moved
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

    /// Repairs items whose modified date was changed to the import time: walks
    /// `folder` (recursively) and resets each photo/video's modified date to its
    /// *embedded* capture date (EXIF / QuickTime), which the import never touched.
    /// Only rewrites when the dates actually differ; files with no embedded date
    /// are left as-is. Returns (fixed, scanned).
    nonisolated static func restoreCaptureDates(
        in folder: URL, progress: @escaping @Sendable (Int, Int) -> Void) async -> (fixed: Int, scanned: Int) {
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
        guard total > 0 else { return (0, 0) }

        var fixed = 0, done = 0, index = 0
        await withTaskGroup(of: Bool.self) { group in
            func addNext() {
                guard index < total else { return }
                let url = files[index]; index += 1
                group.addTask {
                    let kind = classify(url: url, isDirectory: false)
                    let entry = Entry(url: url, name: url.lastPathComponent, kind: kind, size: 0, modified: Date())
                    guard let captured = await MetadataLoader.captureDate(for: entry) else { return false }
                    let current = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                    if let current, abs(current.timeIntervalSince(captured)) < 1 { return false }   // already correct
                    try? FileManager.default.setAttributes([.modificationDate: captured], ofItemAtPath: url.path)
                    return true
                }
            }
            for _ in 0..<min(6, total) { addNext() }
            while let changed = await group.next() {
                if changed { fixed += 1 }
                done += 1
                progress(done, total)
                addNext()
            }
        }
        return (fixed, total)
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

    /// Encodes a captured frame and saves it to Photos.
    static func saveFrame(_ pixelBuffer: CVPixelBuffer,
                          transform: CGAffineTransform = .identity,
                          properties: [String: Any] = [:]) async -> Bool {
        guard let data = encodeFrame(pixelBuffer, transform: transform, properties: properties) else { return false }
        return await savePhotoData(data)
    }

    /// Upper bound on exported frames per second of video.
    static let exportFramesPerSecond = 10.0
    /// Minimum source-frame stride: take at most 1 of every 6 frames, so 60fps →
    /// 10/sec (600/min) and 30fps → 5/sec (300/min). Higher-fps video uses a
    /// larger stride so it never exceeds `exportFramesPerSecond`.
    static let minExportStride = 6

    /// Exports frames of a video — evenly sampled to `exportFramesPerSecond` — as
    /// upright, metadata-preserving HEICs into a new folder (named `folderName`)
    /// beside the video. HDR videos export 10-bit HDR HEICs (via a reader that
    /// restarts on failure so one bad frame can't end the export); SDR videos use
    /// AVAssetImageGenerator (each frame decoded independently).
    /// `onProgress` is called (off the main thread) with 0…1 completion.
    static func exportAllFrames(of url: URL,
                                folderName: String,
                                onProgress: @escaping @Sendable (Double) -> Void = { _ in })
    async -> (folder: URL?, count: Int) {
        let name = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeName = name.isEmpty ? (url.deletingPathExtension().lastPathComponent + " Frames") : name
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return (nil, 0) }
        let isHDR = ((try? await track.load(.mediaCharacteristics))?.contains(.containsHDRVideo)) ?? false
        let props = await MetadataLoader.exifProperties(forVideo: url)
        let duration = (try? await asset.load(.duration))?.seconds ?? 0
        let fps = (try? await track.load(.nominalFrameRate)).map(Double.init) ?? 0
        // 1 of every `stride` frames → 30fps ≈ 5/s, 60fps ≈ 10/s, capped at 10/s.
        let stride = max(minExportStride, Int((fps / exportFramesPerSecond).rounded()))
        let interval = fps > 0 ? Double(stride) / fps : 1.0 / exportFramesPerSecond
        guard duration > 0, interval > 0 else { return (nil, 0) }

        let dir = url.deletingLastPathComponent().appendingPathComponent(safeName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        if isHDR {
            let transform = (try? await track.load(.preferredTransform)) ?? .identity
            return await exportFramesHDR(asset: asset, track: track, transform: transform, dir: dir,
                                         safeName: safeName, props: props, duration: duration,
                                         interval: interval, onProgress: onProgress)
        }
        return await exportFramesSDR(asset: asset, dir: dir, safeName: safeName, props: props,
                                     duration: duration, interval: interval, onProgress: onProgress)
    }

    /// SDR path: AVAssetImageGenerator at evenly-spaced times (one bad frame is skipped).
    private static func exportFramesSDR(asset: AVURLAsset, dir: URL, safeName: String,
                                        props: [String: Any], duration: Double, interval: Double,
                                        onProgress: @escaping @Sendable (Double) -> Void) async -> (URL?, Int) {
        var times: [NSValue] = []
        var t = 0.0
        while t < duration { times.append(NSValue(time: CMTime(seconds: t, preferredTimescale: 600))); t += interval }
        let total = times.count
        guard total > 0 else { return (dir, 0) }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true                 // upright frames
        generator.requestedTimeToleranceBefore = CMTime(seconds: interval / 2, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: interval / 2, preferredTimescale: 600)

        let outcome: (URL?, Int) = await withCheckedContinuation { (cont: CheckedContinuation<(URL?, Int), Never>) in
            let lock = NSLock()
            var written = 0
            var processed = 0
            var lastPct = -1
            generator.generateCGImagesAsynchronously(forTimes: times) { _, image, _, result, _ in
                autoreleasepool {
                    lock.lock()
                    processed += 1
                    if result == .succeeded, let image,
                       let data = encodeCGImage(image, properties: props) {
                        written += 1
                        try? data.write(to: dir.appendingPathComponent("\(safeName) (\(written)).heic"))
                    }
                    let pct = Int(Double(processed) / Double(total) * 100)
                    let report = pct != lastPct
                    if report { lastPct = pct }
                    let finished = processed >= total
                    let count = written
                    lock.unlock()
                    if report { onProgress(min(1.0, Double(pct) / 100.0)) }
                    if finished { cont.resume(returning: (dir, count)) }
                }
            }
        }
        withExtendedLifetime(generator) {}        // keep the generator alive until done
        return outcome
    }

    /// HDR path: 10-bit AVAssetReader, time-sampled, restarting after the last
    /// good frame whenever the reader fails — so one undecodable frame can't end
    /// the whole export. Frames keep their HDR (10-bit HEIC via `encodeFrame`).
    private static func exportFramesHDR(asset: AVURLAsset, track: AVAssetTrack, transform: CGAffineTransform,
                                        dir: URL, safeName: String, props: [String: Any],
                                        duration: Double, interval: Double,
                                        onProgress: @escaping @Sendable (Double) -> Void) async -> (URL?, Int) {
        await Task.detached(priority: .userInitiated) { () -> (URL?, Int) in
            let settings: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            ]
            var written = 0
            var nextTime = 0.0      // next target sample time (seconds)
            var startTime = 0.0     // where the current reader begins
            var failures = 0
            var lastPct = -1
            while startTime < duration, failures < 6 {
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
                while reader.status == .reading, let sample = output.copyNextSampleBuffer() {
                    autoreleasepool {
                        let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                        if pts.isFinite { lastPTS = pts; advanced = true }
                        if pts.isFinite, pts + 1e-4 >= nextTime,
                           let pb = CMSampleBufferGetImageBuffer(sample),
                           let data = encodeFrame(pb, transform: transform, properties: props) {
                            written += 1
                            try? data.write(to: dir.appendingPathComponent("\(safeName) (\(written)).heic"))
                            nextTime += interval
                            if nextTime <= pts { nextTime = pts + interval }
                            let pct = Int(min(1.0, pts / duration) * 100)
                            if pct != lastPct { lastPct = pct; onProgress(min(1.0, pts / duration)) }
                        }
                        CMSampleBufferInvalidate(sample)
                    }
                }
                if reader.status == .completed { break }
                if reader.status == .failed {
                    failures += 1
                    startTime = advanced ? lastPTS + interval : startTime + max(interval, 0.5)
                    if nextTime < startTime { nextTime = startTime }
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

    static func savePhotoData(_ data: Data) async -> Bool {
        guard Bundle.main.object(forInfoDictionaryKey: "NSPhotoLibraryAddUsageDescription") != nil,
              await ensureAddPermission() else { return false }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
            }
            return true
        } catch {
            return false
        }
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
