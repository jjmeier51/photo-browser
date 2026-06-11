import Foundation
import ImageIO
import AVFoundation
import CoreLocation
import UniformTypeIdentifiers

/// Everything the swipe-up info panel shows.
struct MediaInfo: Sendable {
    var date: Date?
    var device: String?
    var dimensions: String?
    var coordinate: CLLocationCoordinate2D?
    var placeName: String?
}

enum MetadataLoader {

    // MARK: - Dimensions + HDR (for resolution/HDR filters)

    static func mediaSpec(for entry: Entry) async -> MediaSpec {
        switch entry.kind {
        case .image:
            return await Task.detached(priority: .utility) { () -> MediaSpec in
                var spec = MediaSpec()
                guard let src = CGImageSourceCreateWithURL(entry.url as CFURL, nil) else { return spec }
                if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
                   let w = props[kCGImagePropertyPixelWidth] as? Int,
                   let h = props[kCGImagePropertyPixelHeight] as? Int {
                    spec.pixels = w * h
                    spec.longSide = max(w, h)
                }
                if CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, kCGImageAuxiliaryDataTypeHDRGainMap) != nil {
                    spec.isHDR = true
                }
                return spec
            }.value
        case .video:
            var spec = MediaSpec()
            let asset = AVURLAsset(url: entry.url)
            if let track = try? await asset.loadTracks(withMediaType: .video).first {
                if let size = try? await track.load(.naturalSize) {
                    let w = Int(abs(size.width)), h = Int(abs(size.height))
                    spec.longSide = max(w, h)
                    spec.pixels = w * h
                }
                if let chars = try? await track.load(.mediaCharacteristics), chars.contains(.containsHDRVideo) {
                    spec.isHDR = true
                }
            }
            return spec
        default:
            return MediaSpec()
        }
    }

    // MARK: - Photo format badge (RAW / 48MP)

    /// Returns "RAW", "48MP", or nil for the upper-right photo badge.
    static func photoBadge(url: URL) async -> String? {
        let rawExts: Set<String> = ["dng", "raw", "cr2", "cr3", "nef", "arw", "raf", "rw2", "orf", "srw", "pef"]
        if rawExts.contains(url.pathExtension.lowercased()) { return "RAW" }
        return await Task.detached(priority: .utility) { () -> String? in
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            if let t = CGImageSourceGetType(src), let type = UTType(t as String), type.conforms(to: .rawImage) {
                return "RAW"
            }
            guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
                  let w = props[kCGImagePropertyPixelWidth] as? Int,
                  let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
            return (Double(w * h) / 1_000_000 >= 44) ? "48MP" : nil
        }.value
    }

    // MARK: - Existing caption embedded in a file (pull-in)

    static func existingCaption(for entry: Entry) async -> String? {
        switch entry.kind {
        case .image:
            return await Task.detached(priority: .utility) { () -> String? in
                guard let src = CGImageSourceCreateWithURL(entry.url as CFURL, nil),
                      let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
                if let iptc = props[kCGImagePropertyIPTCDictionary] as? [CFString: Any],
                   let s = iptc[kCGImagePropertyIPTCCaptionAbstract] as? String, !s.isEmpty { return s }
                if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
                   let s = tiff[kCGImagePropertyTIFFImageDescription] as? String, !s.isEmpty { return s }
                if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
                   let s = exif[kCGImagePropertyExifUserComment] as? String, !s.isEmpty { return s }
                return nil
            }.value
        case .video:
            let asset = AVURLAsset(url: entry.url)
            guard let meta = try? await asset.load(.metadata) else { return nil }
            for item in meta where item.commonKey == .commonKeyDescription {
                if let s = try? await item.load(.stringValue), !s.isEmpty { return s }
            }
            for item in meta where item.commonKey == .commonKeyTitle {
                if let s = try? await item.load(.stringValue), !s.isEmpty { return s }
            }
            return nil
        default:
            return nil
        }
    }

    // MARK: - Image metadata for a captured video frame (date/location/device)

    static func exifProperties(forVideo url: URL) async -> [String: Any] {
        let info = await loadVideo(url)
        var exif: [String: Any] = [:]
        var tiff: [String: Any] = [:]
        var gps: [String: Any] = [:]

        if let date = info.date {
            let f = DateFormatter()
            f.dateFormat = "yyyy:MM:dd HH:mm:ss"
            let s = f.string(from: date)
            exif[kCGImagePropertyExifDateTimeOriginal as String] = s
            exif[kCGImagePropertyExifDateTimeDigitized as String] = s
            tiff[kCGImagePropertyTIFFDateTime as String] = s
        }
        if let device = info.device {
            tiff[kCGImagePropertyTIFFModel as String] = device
            if device.localizedCaseInsensitiveContains("iPhone") || device.localizedCaseInsensitiveContains("iPad") {
                tiff[kCGImagePropertyTIFFMake as String] = "Apple"
            }
        }
        if let c = info.coordinate {
            gps[kCGImagePropertyGPSLatitude as String] = abs(c.latitude)
            gps[kCGImagePropertyGPSLatitudeRef as String] = c.latitude >= 0 ? "N" : "S"
            gps[kCGImagePropertyGPSLongitude as String] = abs(c.longitude)
            gps[kCGImagePropertyGPSLongitudeRef as String] = c.longitude >= 0 ? "E" : "W"
        }

        var props: [String: Any] = [:]
        if !exif.isEmpty { props[kCGImagePropertyExifDictionary as String] = exif }
        if !tiff.isEmpty { props[kCGImagePropertyTIFFDictionary as String] = tiff }
        if !gps.isEmpty  { props[kCGImagePropertyGPSDictionary as String] = gps }
        return props
    }

    // MARK: - "Saved from" (download source, best-effort)

    /// Where the file was downloaded from — e.g. "Safari", "Reddit", "Files" —
    /// read from the file's extended attributes. Nil if unknown.
    static func whereFrom(url: URL) -> String? {
        // kMDItemWhereFroms: a binary-plist array of strings (source URL + title).
        if let data = extendedAttribute("com.apple.metadata:kMDItemWhereFroms", at: url),
           let list = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String] {
            let entries = list.filter { !$0.isEmpty }
            if let link = entries.first(where: { $0.contains("://") }) {
                return friendlySource(from: link)
            }
            if let first = entries.first { return first }
        }
        // Quarantine: "flags;timestamp;agentName;uuid" — agentName is the app.
        if let data = extendedAttribute("com.apple.quarantine", at: url),
           let raw = String(data: data, encoding: .utf8) {
            let parts = raw.components(separatedBy: ";")
            if parts.count >= 3, !parts[2].isEmpty { return friendlyAgent(parts[2]) }
        }
        return nil
    }

    private static func extendedAttribute(_ name: String, at url: URL) -> Data? {
        let path = url.path
        let length = getxattr(path, name, nil, 0, 0, 0)
        guard length > 0, length < 1_048_576 else { return nil }   // sane upper bound
        var buffer = [UInt8](repeating: 0, count: length)
        let read = getxattr(path, name, &buffer, length, 0, 0)
        guard read > 0 else { return nil }
        return Data(buffer.prefix(read))
    }

    private static func friendlySource(from string: String) -> String {
        guard let host = URL(string: string)?.host?.replacingOccurrences(of: "www.", with: "") else { return string }
        let map = ["reddit.com": "Reddit", "redd.it": "Reddit", "twitter.com": "X", "x.com": "X",
                   "instagram.com": "Instagram", "facebook.com": "Facebook", "fb.com": "Facebook",
                   "youtube.com": "YouTube", "youtu.be": "YouTube", "tiktok.com": "TikTok",
                   "pinterest.com": "Pinterest", "imgur.com": "Imgur", "google.com": "Google",
                   "snapchat.com": "Snapchat", "whatsapp.com": "WhatsApp"]
        if let name = map[host] { return name }
        let parts = host.components(separatedBy: ".")
        return parts.count >= 2 ? parts[parts.count - 2].capitalized : host
    }

    private static func friendlyAgent(_ agent: String) -> String {
        if agent.localizedCaseInsensitiveContains("safari") { return "Safari" }
        if agent.localizedCaseInsensitiveContains("chrome") { return "Chrome" }
        if agent.localizedCaseInsensitiveContains("firefox") { return "Firefox" }
        return agent
    }

    // MARK: - Capture date (for year filtering)

    /// The real capture date from EXIF (photos) or creation metadata (videos);
    /// nil if the file carries none.
    static func captureDate(for entry: Entry) async -> Date? {
        switch entry.kind {
        case .image:
            return await Task.detached(priority: .utility) { () -> Date? in
                guard let src = CGImageSourceCreateWithURL(entry.url as CFURL, nil),
                      let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
                let f = DateFormatter(); f.dateFormat = "yyyy:MM:dd HH:mm:ss"
                if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
                   let s = exif[kCGImagePropertyExifDateTimeOriginal] as? String, let d = f.date(from: s) {
                    return d
                }
                if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
                   let s = tiff[kCGImagePropertyTIFFDateTime] as? String {
                    return f.date(from: s)
                }
                return nil
            }.value
        case .video:
            let asset = AVURLAsset(url: entry.url)
            guard let item = try? await asset.load(.creationDate) else { return nil }
            return try? await item.load(.dateValue)
        default:
            return nil
        }
    }

    // MARK: - Full info (for the swipe-up panel)

    static func load(for entry: Entry) async -> MediaInfo {
        var info: MediaInfo
        // Both image and video reads are time-boxed so a slow/corrupt file on an
        // external drive can never hang the info panel — fall back to just the
        // file's own attributes. (The image path used to be unbounded, which could
        // still freeze the swipe-up panel on a huge/damaged photo.)
        switch entry.kind {
        case .image: info = await withTimeout(8) { await loadImage(entry.url) } ?? MediaInfo()
        case .video: info = await withTimeout(8) { await loadVideo(entry.url) } ?? MediaInfo()
        default:     info = MediaInfo()
        }
        if info.date == nil { info.date = entry.modified }
        if let coord = info.coordinate, !CLLocationCoordinate2DIsValid(coord) {
            info.coordinate = nil          // drop malformed GPS so the panel can't crash on it
        }
        if let coord = info.coordinate {
            info.placeName = await withTimeout(5) { await reverseGeocode(coord) } ?? nil
        }
        return info
    }

    // MARK: - Time-boxed convenience wrappers for the info panel

    /// `existingCaption`, bounded so a slow/corrupt file can't stall the panel.
    static func timeBoxedCaption(for entry: Entry) async -> String? {
        await withTimeout(6) { await existingCaption(for: entry) } ?? nil
    }

    /// `whereFrom` (a blocking `getxattr`), run off the main actor and bounded.
    static func timeBoxedSource(url: URL) async -> String? {
        await withTimeout(4) { await Task.detached { whereFrom(url: url) }.value } ?? nil
    }

    /// Runs `op` off the main actor, returning nil if it doesn't finish within
    /// `seconds`. Keeps the swipe-up panel from ever stalling on slow I/O.
    static func withTimeout<T: Sendable>(_ seconds: Double,
                                         _ op: @escaping @Sendable () async -> T) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await op() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private static func loadImage(_ url: URL) async -> MediaInfo {
        await Task.detached(priority: .userInitiated) { () -> MediaInfo in
            var info = MediaInfo()
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else {
                return info
            }
            if let w = props[kCGImagePropertyPixelWidth] as? Int,
               let h = props[kCGImagePropertyPixelHeight] as? Int {
                info.dimensions = "\(w) × \(h)"
            }
            if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                let make = tiff[kCGImagePropertyTIFFMake] as? String
                let model = tiff[kCGImagePropertyTIFFModel] as? String
                let dev = [make, model].compactMap { $0 }.joined(separator: " ")
                info.device = dev.isEmpty ? nil : dev
            }
            if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
               let ds = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
                info.date = parseExifDate(ds)
            }
            if let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any],
               let lat = gps[kCGImagePropertyGPSLatitude] as? Double,
               let lon = gps[kCGImagePropertyGPSLongitude] as? Double {
                let latRef = gps[kCGImagePropertyGPSLatitudeRef] as? String ?? "N"
                let lonRef = gps[kCGImagePropertyGPSLongitudeRef] as? String ?? "E"
                info.coordinate = CLLocationCoordinate2D(latitude: latRef == "S" ? -lat : lat,
                                                         longitude: lonRef == "W" ? -lon : lon)
            }
            return info
        }.value
    }

    private static func loadVideo(_ url: URL) async -> MediaInfo {
        // Runs off the main actor: under default-MainActor isolation the
        // synchronous parts of AVURLAsset reads would otherwise stall the UI
        // (worse on a slow external drive), which looked like a freeze.
        await Task.detached(priority: .userInitiated) { () -> MediaInfo in
            await loadVideoBody(url)
        }.value
    }

    private nonisolated static func loadVideoBody(_ url: URL) async -> MediaInfo {
        var info = MediaInfo()
        let asset = AVURLAsset(url: url)
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let size = try? await track.load(.naturalSize),
           let transform = try? await track.load(.preferredTransform) {
            let r = size.applying(transform)
            info.dimensions = "\(Int(abs(r.width))) × \(Int(abs(r.height)))"
        }
        if let meta = try? await asset.load(.metadata) {
            for item in meta {
                guard let key = item.commonKey else { continue }
                if key == .commonKeyCreationDate, let s = try? await item.load(.stringValue) {
                    info.date = parseISODate(s) ?? info.date
                } else if key == .commonKeyModel, let s = try? await item.load(.stringValue) {
                    info.device = s
                }
            }
        }
        if let qt = try? await asset.loadMetadata(for: .quickTimeMetadata) {
            for item in qt {
                let keyStr = item.key as? String
                if keyStr == "com.apple.quicktime.model", let s = try? await item.load(.stringValue) {
                    info.device = s
                } else if keyStr == "com.apple.quicktime.location.ISO6709", let s = try? await item.load(.stringValue) {
                    info.coordinate = parseISO6709(s)
                } else if keyStr == "com.apple.quicktime.creationdate", let s = try? await item.load(.stringValue) {
                    info.date = parseISODate(s) ?? info.date
                }
            }
        }
        return info
    }

    // MARK: - Video resolution / HDR badge

    /// Returns e.g. "4K", "1080p", "720p", "4K HDR" — or nil for lower res.
    static func videoQuality(url: URL) async -> String? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let size = try? await track.load(.naturalSize) else { return nil }
        let longSide = Int(max(abs(size.width), abs(size.height)))
        let res: String
        if longSide >= 3840 { res = "4K" }
        else if longSide >= 1920 { res = "1080p" }
        else if longSide >= 1280 { res = "720p" }
        else { return nil }

        if let chars = try? await track.load(.mediaCharacteristics), chars.contains(.containsHDRVideo) {
            return res + " HDR"
        }
        return res
    }

    // MARK: - Helpers

    private nonisolated static func reverseGeocode(_ c: CLLocationCoordinate2D) async -> String? {
        // Reverse-geocoding (or building a CLLocation) with an invalid coordinate
        // can blow up, so bail out on anything out of range / NaN.
        guard CLLocationCoordinate2DIsValid(c),
              c.latitude.isFinite, c.longitude.isFinite,
              !(c.latitude == 0 && c.longitude == 0) else { return nil }
        let placemarks = try? await CLGeocoder().reverseGeocodeLocation(
            CLLocation(latitude: c.latitude, longitude: c.longitude))
        guard let p = placemarks?.first else { return nil }
        return [p.locality, p.administrativeArea, p.country].compactMap { $0 }.joined(separator: ", ")
    }

    private nonisolated static func parseExifDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f.date(from: s)
    }

    private nonisolated static func parseISODate(_ s: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: s)
    }

    /// Parses an ISO-6709 string like "+37.7749-122.4194/" into a coordinate.
    private nonisolated static func parseISO6709(_ s: String) -> CLLocationCoordinate2D? {
        let scanner = Scanner(string: s)
        guard let lat = scanner.scanDouble(), let lon = scanner.scanDouble() else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}
