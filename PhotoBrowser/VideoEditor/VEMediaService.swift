import Foundation
import os
import AVFoundation
import CoreMedia
import CoreVideo
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
import UIKit

/// Import, identity hashing and derived assets (ARC-1 MediaService). Everything here runs off the
/// main actor: probing an asset over USB, hashing, copying and generating thumbnails are all slow.
/// Sources are opened read-only and never moved, renamed, rewritten or deleted (IMP-11).
nonisolated final class VEMediaService: @unchecked Sendable {
    static let shared = VEMediaService()

    /// Bounded derived-asset concurrency (ARC-4: two at a time at utility QoS).
    private let derivedQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 2
        q.qualityOfService = .utility
        q.name = "VideoEditor.derived"
        return q
    }()
    private let lock = NSLock()
    private var inFlight: Set<String> = []
    private var measuredThroughput: Double?

    // MARK: - Probing

    nonisolated struct Probe: Sendable {
        var kind: VEMediaKind
        var duration: VETime
        var width: Int
        var height: Int
        var transform: VERotation = .none
        var fps: Double = 0
        var vfr: Bool = false
        var codec: String?
        var bitDepth: Int?
        var colorTransfer: String?
        var hasAudio: Bool = false
        var hasAlpha: Bool = false
        var audioChannels: Int?
        var audioSampleRate: Double?
        var createdAt: Date?
    }

    private static let supportedVideoCodecs: Set<String> = ["avc1", "avc3", "hvc1", "hev1", "dvh1", "dvhe", "apch", "apcn", "apcs", "apco", "ap4h", "ap4x", "mp4v"]
    private static let codecNames: [String: String] = [
        "jpeg": "MJPEG", "mjpa": "MJPEG", "mjpb": "MJPEG", "vp08": "VP8", "vp09": "VP9", "av01": "AV1", "WMV3": "WMV", "wmv3": "WMV",
        "FLV1": "FLV", "mpg2": "MPEG-2", "mp2v": "MPEG-2", "xvid": "Xvid", "XVID": "Xvid", "DIVX": "DivX", "divx": "DivX", "theo": "Theora",
    ]

    /// Format detection by track format descriptions, not extensions (IMP-3).
    func probe(_ url: URL) async throws -> Probe {
        let name = url.lastPathComponent
        if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) {
            return try probeImage(url)
        }
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let (duration, protected) = try await asset.load(.duration, .hasProtectedContent)
        if protected { throw VEError.unsupportedMedia(name: name, codec: "a protected (DRM) track") }
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        var p = Probe(kind: videoTracks.isEmpty ? .audio : .video, duration: VETimeUtil.us(duration), width: 0, height: 0)
        if videoTracks.isEmpty && audioTracks.isEmpty {
            throw VEError.unsupportedMedia(name: name, codec: "a file with no video or audio track")
        }
        if let v = videoTracks.first {
            let (size, transform, fps, descs, minDur) = try await v.load(.naturalSize, .preferredTransform, .nominalFrameRate, .formatDescriptions, .minFrameDuration)
            p.width = Int(size.width.rounded()); p.height = Int(size.height.rounded())
            p.transform = Self.rotation(from: transform)
            p.fps = Double(fps)
            if minDur.isNumeric, minDur.seconds > 0 {
                let maxRate = 1 / minDur.seconds
                p.vfr = fps > 0 && abs(maxRate - Double(fps)) > 1.5
            }
            if let d = descs.first {
                let sub = CMFormatDescriptionGetMediaSubType(d)
                let four = Self.fourCC(sub)
                p.codec = four
                if !Self.supportedVideoCodecs.contains(four) {
                    throw VEError.unsupportedMedia(name: name, codec: "the video codec (\(Self.codecNames[four] ?? four))")
                }
                if let depth = CMFormatDescriptionGetExtension(d, extensionKey: kCMFormatDescriptionExtension_BitsPerComponent) as? NSNumber {
                    p.bitDepth = depth.intValue
                } else if let depth = CMFormatDescriptionGetExtension(d, extensionKey: kCMFormatDescriptionExtension_Depth) as? NSNumber {
                    p.bitDepth = depth.intValue >= 30 ? 10 : 8
                }
                if let tf = CMFormatDescriptionGetExtension(d, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String {
                    if tf == (kCVImageBufferTransferFunction_ITU_R_2100_HLG as String) { p.colorTransfer = "HLG" }
                    else if tf == (kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String) { p.colorTransfer = "PQ" }
                    else { p.colorTransfer = "SDR" }
                } else {
                    p.colorTransfer = "SDR"
                }
                if let alpha = CMFormatDescriptionGetExtension(d, extensionKey: kCMFormatDescriptionExtension_ContainsAlphaChannel) as? NSNumber {
                    p.hasAlpha = alpha.boolValue
                }
            }
        }
        if let a = audioTracks.first {
            p.hasAudio = true
            let descs = try await a.load(.formatDescriptions)
            if let d = descs.first, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(d)?.pointee {
                p.audioChannels = Int(asbd.mChannelsPerFrame)
                p.audioSampleRate = asbd.mSampleRate
            }
        }
        if let created = try? await asset.load(.creationDate), let date = try? await created.load(.dateValue) {
            p.createdAt = date
        }
        return p
    }

    private func probeImage(_ url: URL) throws -> Probe {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else {
            throw VEError.unsupportedMedia(name: url.lastPathComponent, codec: "this image format")
        }
        let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        guard w > 0, h > 0 else { throw VEError.unsupportedMedia(name: url.lastPathComponent, codec: "this image format") }
        let count = CGImageSourceGetCount(src)
        var p = Probe(kind: count > 1 ? .gif : .image, duration: 0, width: w, height: h)
        p.hasAlpha = (props[kCGImagePropertyHasAlpha] as? NSNumber)?.boolValue ?? false
        if let o = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue {
            switch o {
            case 3, 4: p.transform = .rotate180
            case 6, 5: p.transform = .rotate90
            case 8, 7: p.transform = .rotate270
            default: p.transform = .none
            }
        }
        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let s = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            let f = DateFormatter(); f.dateFormat = "yyyy:MM:dd HH:mm:ss"; f.locale = Locale(identifier: "en_US_POSIX")
            p.createdAt = f.date(from: s)
        }
        if count > 1 {
            // Animated GIF: natural loop length = sum of frame delays.
            var total = 0.0
            for i in 0..<count {
                guard let fp = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any],
                      let gif = fp[kCGImagePropertyGIFDictionary] as? [CFString: Any] else { total += 0.1; continue }
                let d = (gif[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber)?.doubleValue
                    ?? (gif[kCGImagePropertyGIFDelayTime] as? NSNumber)?.doubleValue ?? 0.1
                total += max(0.02, d)
            }
            p.duration = VETimeUtil.fromSeconds(total)
            p.fps = total > 0 ? Double(count) / total : 10
        }
        p.codec = (props[kCGImagePropertyDepth] as? NSNumber).map { "\($0)-bit" }
        return p
    }

    static func rotation(from t: CGAffineTransform) -> VERotation {
        let angle = atan2(t.b, t.a)
        let deg = Int((angle * 180 / .pi).rounded())
        switch ((deg % 360) + 360) % 360 {
        case 90: return .rotate90
        case 180: return .rotate180
        case 270: return .rotate270
        default: return .none
        }
    }

    static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [UInt8(code >> 24 & 0xff), UInt8(code >> 16 & 0xff), UInt8(code >> 8 & 0xff), UInt8(code & 0xff)]
        return String(bytes: bytes, encoding: .ascii) ?? String(code)
    }

    // MARK: - Identity (STO-2)

    /// Size + modification date + SHA-256 of the first and last 1 MiB.
    func identity(of url: URL) throws -> VEIdentity {
        let rv = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = Int64(rv.fileSize ?? 0)
        let mtime = rv.contentModificationDate ?? Date(timeIntervalSince1970: 0)
        return VEIdentity(size: size, mtime: mtime, hash: try Self.edgeHash(url, size: size))
    }

    static func edgeHash(_ url: URL, size: Int64) throws -> String {
        let chunk = 1024 * 1024
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var sha = SHA256()
        if size <= Int64(2 * chunk) {
            sha.update(data: h.readData(ofLength: Int(size)))
        } else {
            sha.update(data: h.readData(ofLength: chunk))
            try h.seek(toOffset: UInt64(size - Int64(chunk)))
            sha.update(data: h.readData(ofLength: chunk))
        }
        return "sha256:" + sha.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Does the file at `url` still match the recorded identity (cheap size/mtime check first)?
    func matches(_ url: URL, identity: VEIdentity) -> Bool {
        guard let rv = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              Int64(rv.fileSize ?? -1) == identity.size else { return false }
        if let m = rv.contentModificationDate, abs(m.timeIntervalSince(identity.mtime)) < 2 { return true }
        return (try? Self.edgeHash(url, size: identity.size)) == identity.hash
    }

    /// A reference record for a file already on the drive or inside the package (no copy).
    func makeSource(for url: URL, package: URL, store: VEDriveStore) async throws -> VEMediaSource {
        guard let ref = store.reference(for: url, package: package) else {
            throw VEError.unsupportedMedia(name: url.lastPathComponent, codec: "a location outside the drive")
        }
        let p = try await probe(url)
        let ident = try identity(of: url)
        return Self.source(from: p, path: ref, identity: ident, name: url.lastPathComponent)
    }

    static func source(from p: Probe, path: String, identity: VEIdentity, name: String) -> VEMediaSource {
        var s = VEMediaSource(id: VEIDs.new(), kind: p.kind, path: path, identity: identity, duration: p.duration,
                              width: p.width, height: p.height, originalName: name)
        s.transform = p.transform; s.fps = p.fps; s.vfr = p.vfr; s.codec = p.codec; s.bitDepth = p.bitDepth
        s.colorTransfer = p.colorTransfer; s.hasAudio = p.hasAudio; s.hasAlpha = p.hasAlpha
        s.audioChannels = p.audioChannels; s.audioSampleRate = p.audioSampleRate; s.createdAt = p.createdAt
        return s
    }

    // MARK: - Import (IMP-1, IMP-9)

    nonisolated struct ImportSkip: Sendable, Identifiable {
        var name: String
        var reason: String
        var id: String { name + reason }
    }
    nonisolated struct ImportResult: Sendable {
        var sources: [VEMediaSource] = []     // in input order; existing records reused
        var skipped: [ImportSkip] = []
        var driveLost = false
    }

    /// Imports `urls` for a project. Files on the drive are referenced in place; files elsewhere
    /// are copied into `media/` (`destination` overrides that, e.g. `Library/Music`). Items whose
    /// identity already exists in `existing` are reused rather than copied twice.
    func importFiles(_ urls: [URL], into package: URL, existing: [VEMediaSource], store: VEDriveStore,
                     destination: URL? = nil,
                     progress: @escaping @Sendable (_ fraction: Double, _ name: String) -> Void) async -> ImportResult {
        var result = ImportResult()
        let total = max(1, urls.count)
        // Space check for everything that will be copied (1.1× + 500 MB headroom).
        var copyBytes: Int64 = 0
        for u in urls where !store.isUnderDrive(u) { copyBytes += store.fileSize(u) }
        if copyBytes > 0, let free = store.freeSpace() {
            let needed = Int64(Double(copyBytes) * 1.1) + 500 * 1024 * 1024
            if free < needed {
                for u in urls { result.skipped.append(ImportSkip(name: u.lastPathComponent, reason: VEError.insufficientSpace(neededBytes: needed - free).message)) }
                return result
            }
        }
        for (i, url) in urls.enumerated() {
            if Task.isCancelled { break }
            let name = url.lastPathComponent
            progress(Double(i) / Double(total), name)
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                // Identity first: a re-import of a known file reuses its record (IMP-2, IMP-9).
                let ident = try identity(of: url)
                if let known = existing.first(where: { $0.identity == ident }) ?? result.sources.first(where: { $0.identity == ident }) {
                    result.sources.append(known)
                    continue
                }
                if store.isUnderDrive(url) {
                    let p = try await probe(url)
                    guard let ref = store.reference(for: url, package: package) else { continue }
                    result.sources.append(Self.source(from: p, path: ref, identity: ident, name: name))
                } else {
                    // Probe before copying so an unsupported file never lands on the drive.
                    let p = try await probe(url)
                    let dir = destination ?? VEDriveLayout.media(package)
                    try DriveWriter.createDirectory(at: dir)
                    let base = (name as NSString).deletingPathExtension
                    let unique = VENames.unique(VENames.sanitize(base, fallback: "media"), ext: url.pathExtension, in: dir)
                    let dst = dir.appendingPathComponent(unique)
                    let base0 = Double(i) / Double(total), span = 1.0 / Double(total)
                    try await copyWithProgress(from: url, to: dst) { f in progress(base0 + f * span, name) }
                    DriveWriter.fullSyncFileAndParent(dst)
                    let copiedIdent = (try? identity(of: dst)) ?? ident
                    guard let ref = store.reference(for: dst, package: package) else { continue }
                    result.sources.append(Self.source(from: p, path: ref, identity: copiedIdent, name: name))
                }
            } catch let e as VEError {
                result.skipped.append(ImportSkip(name: name, reason: e.message))
            } catch {
                if VEDriveStore.isDriveLoss(error) || !store.isReachable() { result.driveLost = true; break }
                result.skipped.append(ImportSkip(name: name, reason: "The file couldn't be read."))
            }
        }
        progress(1, "")
        return result
    }

    /// Chunked copy with progress at ~10 Hz; cancellation deletes the partial file (IMP-9).
    func copyWithProgress(from src: URL, to dst: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let size = Int64((try? src.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let fm = FileManager.default
        try DriveWriter.createDirectory(at: dst.deletingLastPathComponent())
        try? fm.removeItem(at: dst)
        // The bytes land in a hidden `.pbtmp_` sibling (which the browser hides and sweeps) and are
        // flushed before the same-volume rename, so `dst` only ever appears complete — a yanked cable
        // mid-copy leaves no half-written entry in the folder (the exFAT corruption pattern).
        let tmp = dst.deletingLastPathComponent().appendingPathComponent(".pbtmp_" + UUID().uuidString)
        defer { try? fm.removeItem(at: tmp) }
        if size < 8 * 1024 * 1024 {
            try DriveWriter.copyItem(at: src, to: tmp)
        } else {
            guard fm.createFile(atPath: tmp.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
            let input = try FileHandle(forReadingFrom: src)
            let output = try FileHandle(forWritingTo: tmp)
            defer { try? input.close(); try? output.close() }
            var written: Int64 = 0
            var lastReport = Date.distantPast
            let chunk = 4 * 1024 * 1024
            while true {
                if Task.isCancelled { throw VEError.cancelled }   // the temp is removed by the defer above
                let data = input.readData(ofLength: chunk)
                if data.isEmpty { break }
                try output.write(contentsOf: data)
                written += Int64(data.count)
                if Date().timeIntervalSince(lastReport) > 0.1 {
                    lastReport = Date()
                    progress(size > 0 ? Double(written) / Double(size) : 1)
                }
                await Task.yield()
            }
        }
        // Carry the source's dates so identity and sorting behave like a plain copy.
        if let rv = try? src.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey]) {
            var attrs: [FileAttributeKey: Any] = [:]
            if let m = rv.contentModificationDate { attrs[.modificationDate] = m }
            if let c = rv.creationDate { attrs[.creationDate] = c }
            try? fm.setAttributes(attrs, ofItemAtPath: tmp.path)
        }
        DriveWriter.fullSync(tmp)
        try fm.moveItem(at: tmp, to: dst)
        DriveWriter.fullSyncFileAndParent(dst)
        progress(1)
    }

    // MARK: - Relink (STO-10)

    /// Search the drive for a file with the same identity: size match first (cheap), then hash.
    func findByIdentity(_ identity: VEIdentity, under root: URL, preferredName: String?) -> URL? {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }
        var candidates: [URL] = []
        for case let u as URL in e {
            if u.lastPathComponent.hasPrefix(".") { continue }
            guard let rv = try? u.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), rv.isRegularFile == true,
                  Int64(rv.fileSize ?? -1) == identity.size else { continue }
            candidates.append(u)
            if candidates.count > 200 { break }
        }
        if let n = preferredName { candidates.sort { ($0.lastPathComponent == n ? 0 : 1) < ($1.lastPathComponent == n ? 0 : 1) } }
        for c in candidates where (try? Self.edgeHash(c, size: identity.size)) == identity.hash { return c }
        return nil
    }

    // MARK: - Throughput (IMP-7 proxy rule)

    /// MB/s reading the first 64 MB of `sample`, measured once per session.
    func throughput(sample: URL?) -> Double {
        lock.lock(); let cached = measuredThroughput; lock.unlock()
        if let cached { return cached }
        guard let sample, let h = try? FileHandle(forReadingFrom: sample) else { return 200 }
        defer { try? h.close() }
        let start = Date()
        var total = 0
        while total < 64 * 1024 * 1024 {
            let d = h.readData(ofLength: 8 * 1024 * 1024)
            if d.isEmpty { break }
            total += d.count
        }
        let secs = max(0.01, Date().timeIntervalSince(start))
        let mbps = Double(total) / 1_000_000 / secs
        lock.lock(); measuredThroughput = mbps; lock.unlock()
        VELog.media.log("drive read throughput ≈ \(Int(mbps)) MB/s")
        return mbps
    }

    /// IMP-7: proxy when the source is heavier than 1080p30 8-bit SDR or the drive is slow.
    func needsProxy(_ s: VEMediaSource, throughputMBps: Double) -> Bool {
        guard s.kind == .video else { return false }
        if s.width > 1920 || s.fps > 31 || (s.bitDepth ?? 8) > 8 || (s.colorTransfer ?? "SDR") != "SDR" { return true }
        return throughputMBps < 80
    }

    // MARK: - Derived assets (IMP-7)

    nonisolated struct StripIndex: Codable, Sendable {
        var frameWidth: Int
        var frameHeight: Int
        var framesPerStrip: Int
        var count: Int
        var interval: VETime            // microseconds between frames
    }

    static let stripFrameHeight = 160
    static let framesPerStrip = 60

    private func begin(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if inFlight.contains(key) { return false }
        inFlight.insert(key); return true
    }
    private func end(_ key: String) { lock.lock(); inFlight.remove(key); lock.unlock() }

    /// Poster (320 px) + filmstrip strips (160 px tall, 1 fps, 60 frames per strip) in
    /// `thumbs/<id>/`. Returns the package-relative folder path, or nil when already in flight or
    /// the source can't be read.
    func generateThumbnails(for source: VEMediaSource, package: URL, store: VEDriveStore) async -> String? {
        let key = "thumbs:" + source.id
        guard begin(key) else { return nil }
        defer { end(key) }
        let dir = VEDriveLayout.thumbs(package).appendingPathComponent(source.id, isDirectory: true)
        let rel = "thumbs/\(source.id)/"
        let indexURL = dir.appendingPathComponent("index.json")
        if FileManager.default.fileExists(atPath: indexURL.path) { return rel }
        try? DriveWriter.createDirectory(at: dir)
        let url = store.resolve(source.path, package: package)
        let display = source.displaySize
        let aspect = display.height > 0 ? Double(display.width) / Double(display.height) : 1
        let fh = Self.stripFrameHeight
        let fw = max(40, min(320, Int((Double(fh) * aspect).rounded())))

        switch source.kind {
        case .image, .gif:
            guard let poster = Self.downsampledImage(url, maxPixel: 320), let frame = Self.downsampledImage(url, maxPixel: max(fw, fh)) else { return nil }
            Self.writeJPEG(poster, to: dir.appendingPathComponent("poster.jpg"), store: store)
            let strip = Self.pack([frame], frameSize: CGSize(width: fw, height: fh))
            Self.writeJPEG(strip, to: dir.appendingPathComponent("strip_000.jpg"), store: store)
            let idx = StripIndex(frameWidth: fw, frameHeight: fh, framesPerStrip: Self.framesPerStrip, count: 1, interval: max(1, source.duration))
            if let d = try? VEJSON.encoder.encode(idx) { try? store.writeData(d, to: indexURL) }
            return rel
        case .audio:
            return nil
        case .video:
            let asset = AVURLAsset(url: url)
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
            gen.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
            gen.maximumSize = CGSize(width: fw * 2, height: fh * 2)
            let seconds = max(1, Int(ceil(VETimeUtil.seconds(source.duration))))
            let count = min(seconds, 3600 * 3)      // cap at 3 h of 1 fps frames
            // Poster first (visible immediately).
            if let posterCG = try? await gen.image(at: CMTime(seconds: min(1, VETimeUtil.seconds(source.duration) / 2), preferredTimescale: 600)).image {
                let poster = UIImage(cgImage: posterCG)
                Self.writeJPEG(Self.resized(poster, maxPixel: 320), to: dir.appendingPathComponent("poster.jpg"), store: store)
            }
            var frames: [UIImage?] = []
            frames.reserveCapacity(Self.framesPerStrip)
            var stripIndex = 0
            var last: UIImage?
            for i in 0..<count {
                if Task.isCancelled { return nil }
                let t = CMTime(seconds: Double(i) + 0.5, preferredTimescale: 600)
                if let cg = try? await gen.image(at: t).image { last = UIImage(cgImage: cg) }
                frames.append(last)
                if frames.count == Self.framesPerStrip || i == count - 1 {
                    let strip = Self.pack(frames, frameSize: CGSize(width: fw, height: fh))
                    Self.writeJPEG(strip, to: dir.appendingPathComponent(String(format: "strip_%03d.jpg", stripIndex)), store: store)
                    stripIndex += 1
                    frames.removeAll(keepingCapacity: true)
                    // Progressive index so the UI can show strips as they land.
                    let idx = StripIndex(frameWidth: fw, frameHeight: fh, framesPerStrip: Self.framesPerStrip, count: i + 1, interval: VETimeUtil.second)
                    if let d = try? VEJSON.encoder.encode(idx) { try? store.writeData(d, to: dir.appendingPathComponent("index.partial.json")) }
                }
            }
            let idx = StripIndex(frameWidth: fw, frameHeight: fh, framesPerStrip: Self.framesPerStrip, count: count, interval: VETimeUtil.second)
            if let d = try? VEJSON.encoder.encode(idx) { try? store.writeData(d, to: indexURL) }
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("index.partial.json"))
            return rel
        }
    }

    static func pack(_ frames: [UIImage?], frameSize: CGSize) -> UIImage {
        let size = CGSize(width: frameSize.width * CGFloat(max(1, frames.count)), height: frameSize.height)
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1; fmt.opaque = true
        return UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            for (i, f) in frames.enumerated() {
                guard let f else { continue }
                let slot = CGRect(x: frameSize.width * CGFloat(i), y: 0, width: frameSize.width, height: frameSize.height)
                // Aspect-fill the slot.
                let s = max(slot.width / f.size.width, slot.height / f.size.height)
                let w = f.size.width * s, h = f.size.height * s
                ctx.cgContext.saveGState()
                ctx.cgContext.clip(to: slot)
                f.draw(in: CGRect(x: slot.midX - w / 2, y: slot.midY - h / 2, width: w, height: h))
                ctx.cgContext.restoreGState()
            }
        }
    }

    static func resized(_ image: UIImage, maxPixel: CGFloat) -> UIImage {
        let s = min(1, maxPixel / max(image.size.width, image.size.height))
        guard s < 1 else { return image }
        let size = CGSize(width: (image.size.width * s).rounded(), height: (image.size.height * s).rounded())
        let fmt = UIGraphicsImageRendererFormat.default(); fmt.scale = 1
        return UIGraphicsImageRenderer(size: size, format: fmt).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    }

    static func downsampledImage(_ url: URL, maxPixel: Int) -> UIImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceShouldCacheImmediately: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxPixel]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }

    static func writeJPEG(_ image: UIImage, to url: URL, store: VEDriveStore) {
        guard let data = image.jpegData(compressionQuality: 0.8) else { return }
        try? store.writeData(data, to: url)
    }

    /// Waveform peaks: mono mix-down, 10 ms buckets of (min, max) as Int16 pairs → `waveforms/<id>.pk`.
    func generateWaveform(for source: VEMediaSource, package: URL, store: VEDriveStore) async -> String? {
        guard source.hasAudio || source.kind == .audio else { return nil }
        let key = "wave:" + source.id
        guard begin(key) else { return nil }
        defer { end(key) }
        let rel = "waveforms/\(source.id).pk"
        let out = VEDriveLayout.waveforms(package).appendingPathComponent("\(source.id).pk")
        if FileManager.default.fileExists(atPath: out.path) { return rel }
        let url = store.resolve(source.path, package: package)
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                                       AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false, AVNumberOfChannelsKey: 1]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }
        var peaks = Data()
        peaks.append(contentsOf: Array("VEPK".utf8))
        var bucketMin: Float = 1, bucketMax: Float = -1, inBucket = 0
        var bucketSize = 480  // updated from the real sample rate
        var count: UInt32 = 0
        func flush() {
            var lo = Int16(max(-1, min(1, bucketMin)) * 32767), hi = Int16(max(-1, min(1, bucketMax)) * 32767)
            withUnsafeBytes(of: &lo) { peaks.append(contentsOf: $0) }
            withUnsafeBytes(of: &hi) { peaks.append(contentsOf: $0) }
            count += 1
            bucketMin = 1; bucketMax = -1; inBucket = 0
        }
        while let sb = output.copyNextSampleBuffer() {
            if Task.isCancelled { reader.cancelReading(); return nil }
            if let fd = CMSampleBufferGetFormatDescription(sb), let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee {
                bucketSize = max(1, Int(asbd.mSampleRate / 100))
            }
            guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
            var length = 0
            var ptr: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &ptr) == kCMBlockBufferNoErr,
                  let p = ptr else { continue }
            let n = length / MemoryLayout<Float>.size
            p.withMemoryRebound(to: Float.self, capacity: n) { fp in
                for i in 0..<n {
                    let v = fp[i]
                    if v < bucketMin { bucketMin = v }
                    if v > bucketMax { bucketMax = v }
                    inBucket += 1
                    if inBucket >= bucketSize { flush() }
                }
            }
        }
        if inBucket > 0 { flush() }
        guard reader.status == .completed, count > 0 else { return nil }
        // Header after the magic: version, count, interval(ms).
        var header = Data()
        var version: UInt32 = 1, c = count, interval: UInt32 = 10
        withUnsafeBytes(of: &version) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: &c) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: &interval) { header.append(contentsOf: $0) }
        peaks.insert(contentsOf: header, at: 4)
        try? store.writeData(peaks, to: out)
        return rel
    }

    /// Decode a `.pk` file into (min, max) pairs in −1…1.
    static func readWaveform(_ url: URL) -> (peaks: [(Float, Float)], intervalMs: Int)? {
        guard let d = try? Data(contentsOf: url), d.count >= 16, String(bytes: d.prefix(4), encoding: .utf8) == "VEPK" else { return nil }
        let count = d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self) }
        let interval = d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 12, as: UInt32.self) }
        var out: [(Float, Float)] = []
        out.reserveCapacity(Int(count))
        d.withUnsafeBytes { raw in
            var off = 16
            for _ in 0..<Int(count) where off + 4 <= raw.count {
                let lo = raw.loadUnaligned(fromByteOffset: off, as: Int16.self)
                let hi = raw.loadUnaligned(fromByteOffset: off + 2, as: Int16.self)
                out.append((Float(lo) / 32767, Float(hi) / 32767))
                off += 4
            }
        }
        return (out, Int(interval))
    }

    /// 1280×720 H.264 preview proxy via `AVAssetExportPreset1280x720`, written straight to
    /// `proxies/<id>.mp4`; scratch files stay in the package's `renders/` (STO-4).
    func generateProxy(for source: VEMediaSource, package: URL, store: VEDriveStore,
                       progress: (@Sendable (Double) -> Void)? = nil) async -> String? {
        guard source.kind == .video else { return nil }
        let key = "proxy:" + source.id
        guard begin(key) else { return nil }
        defer { end(key) }
        let rel = "proxies/\(source.id).mp4"
        let out = VEDriveLayout.proxies(package).appendingPathComponent("\(source.id).mp4")
        if FileManager.default.fileExists(atPath: out.path) { return rel }
        if let free = store.freeSpace(), free < 2 * 1024 * 1024 * 1024 { return nil }   // leave 2 GB headroom
        let url = store.resolve(source.path, package: package)
        let asset = AVURLAsset(url: url)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1280x720) else { return nil }
        let partial = VEDriveLayout.renders(package).appendingPathComponent("\(source.id).proxy.part.mp4")
        try? DriveWriter.createDirectory(at: VEDriveLayout.renders(package))
        try? FileManager.default.removeItem(at: partial)
        session.outputURL = partial
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = false
        session.directoryForTemporaryFiles = VEDriveLayout.renders(package)
        let poll = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000)
                progress?(Double(session.progress))
            }
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { cont.resume() }
        }
        poll.cancel()
        guard session.status == .completed else {
            try? FileManager.default.removeItem(at: partial)
            VELog.media.error("proxy failed for \(source.displayName): \(session.error?.localizedDescription ?? "unknown")")
            return nil
        }
        do {
            try store.coordinatedMove(from: partial, to: out)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            return nil
        }
        return rel
    }

    /// Full-resolution still of one source frame (freeze frames, crop UI, covers).
    func frame(of url: URL, at time: VETime, maxPixel: CGFloat = 0) async -> UIImage? {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        if maxPixel > 0 { gen.maximumSize = CGSize(width: maxPixel, height: maxPixel) }
        guard let cg = try? await gen.image(at: VETimeUtil.cm(time)).image else { return nil }
        return UIImage(cgImage: cg)
    }
}
