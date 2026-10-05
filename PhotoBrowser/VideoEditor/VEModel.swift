import Foundation
import CoreMedia
import CoreGraphics

// MARK: - Time

/// Video-editor time unit: **integer microseconds** (the unit CapCut's own drafts use), so
/// arithmetic on clip ranges is exact and the document never carries floating-point drift. The UI
/// snaps to frames of the project frame rate; `CMTime` is only produced at the AVFoundation edge.
typealias VETime = Int64

nonisolated enum VETimeUtil {
    static let second: VETime = 1_000_000

    static func cm(_ t: VETime) -> CMTime { CMTime(value: t, timescale: 1_000_000) }
    static func us(_ t: CMTime) -> VETime {
        guard t.isNumeric else { return 0 }
        return VETime((t.seconds * 1_000_000).rounded())
    }
    static func seconds(_ t: VETime) -> Double { Double(t) / 1_000_000 }
    static func fromSeconds(_ s: Double) -> VETime { VETime((s * 1_000_000).rounded()) }
    /// Duration of one frame at `fps`.
    static func frame(_ fps: Int) -> VETime { max(1, VETime((1_000_000.0 / Double(max(fps, 1))).rounded())) }
    static func snapToFrame(_ t: VETime, fps: Int) -> VETime {
        let f = frame(fps)
        return (t + f / 2) / f * f
    }
    /// `m:ss.d` normally, `m:ss:ff` (frames) when the timeline is zoomed past 10 pt per frame.
    static func format(_ t: VETime, fps: Int, frames: Bool = false) -> String {
        let total = max(0, t)
        let s = total / second
        let m = s / 60
        if frames {
            let ff = (total % second) * VETime(fps) / second
            return String(format: "%lld:%02lld:%02lld", m, s % 60, ff)
        }
        let tenths = (total % second) / 100_000
        return String(format: "%lld:%02lld.%lld", m, s % 60, tenths)
    }
    static func formatShort(_ t: VETime) -> String {
        let s = Double(max(0, t)) / 1_000_000
        if s < 60 { return String(format: "%.1fs", s) }
        return String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }
}

// MARK: - Generic JSON (unknown-key preservation)

/// A JSON tree used to keep fields this build doesn't understand (newer documents survive older
/// builds, PRJ-1) and for layer kinds that later phases define (text, stickers, effects, …).
nonisolated indirect enum JSONValue: Codable, Equatable, Sendable, Hashable {
    case string(String), number(Double), bool(Bool), null
    case array([JSONValue]), object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unrecognised JSON value") }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

/// Coding key that accepts any string — used to walk every key of a container so the ones this
/// build doesn't know are captured into `extra` and written back unchanged.
nonisolated struct VEDynamicKey: CodingKey, Hashable {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ s: String) { stringValue = s }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

/// Lenient keyed decoding/encoding over `VEDynamicKey` containers: defaults for missing keys, and
/// the unknown-key capture/replay that keeps newer documents intact. Plain static functions (not
/// extensions on the Foundation containers) so nothing picks up main-actor inference.
nonisolated enum VECoding {
    typealias Dec = KeyedDecodingContainer<VEDynamicKey>
    typealias Enc = KeyedEncodingContainer<VEDynamicKey>

    static func get<T: Decodable>(_ c: Dec, _ key: String, _ fallback: T) -> T {
        (try? c.decodeIfPresent(T.self, forKey: VEDynamicKey(key))) ?? fallback
    }
    static func opt<T: Decodable>(_ c: Dec, _ key: String) -> T? {
        try? c.decodeIfPresent(T.self, forKey: VEDynamicKey(key))
    }
    static func req<T: Decodable>(_ c: Dec, _ key: String) throws -> T {
        try c.decode(T.self, forKey: VEDynamicKey(key))
    }
    /// Every key not in `known`, as raw JSON.
    static func extras(_ c: Dec, known: Set<String>) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for k in c.allKeys where !known.contains(k.stringValue) {
            if let v = try? c.decode(JSONValue.self, forKey: k) { out[k.stringValue] = v }
        }
        return out
    }
    static func put<T: Encodable>(_ c: inout Enc, _ key: String, _ value: T) throws { try c.encode(value, forKey: VEDynamicKey(key)) }
    static func putIfPresent<T: Encodable>(_ c: inout Enc, _ key: String, _ value: T?) throws {
        if let value { try c.encode(value, forKey: VEDynamicKey(key)) }
    }
    static func putExtras(_ c: inout Enc, _ extras: [String: JSONValue]) throws {
        for (k, v) in extras.sorted(by: { $0.key < $1.key }) { try c.encode(v, forKey: VEDynamicKey(k)) }
    }
}

// MARK: - Enumerations

nonisolated enum VEResolution: String, Codable, CaseIterable, Sendable {
    case p480 = "480p", p720 = "720p", p1080 = "1080p", p1440 = "2K", p2160 = "4K"
    /// The resolution names the **short-edge** pixel count for every ratio (CAN-2).
    var shortEdge: Int {
        switch self {
        case .p480: return 480
        case .p720: return 720
        case .p1080: return 1080
        case .p1440: return 1440
        case .p2160: return 2160
        }
    }
    var label: String {
        switch self {
        case .p1440: return "2K (1440p)"
        case .p2160: return "4K (2160p)"
        default: return rawValue
        }
    }
}

nonisolated enum VERatio: String, Codable, CaseIterable, Sendable {
    case original = "Original"
    case r9x16 = "9:16", r16x9 = "16:9", r1x1 = "1:1", r4x3 = "4:3", r3x4 = "3:4"
    case r2x1 = "2:1", r185x1 = "1.85:1", r235x1 = "2.35:1"

    /// Width ÷ height; `nil` for Original (resolved from the first clip when chosen).
    var aspect: Double? {
        switch self {
        case .original: return nil
        case .r9x16: return 9.0 / 16.0
        case .r16x9: return 16.0 / 9.0
        case .r1x1: return 1
        case .r4x3: return 4.0 / 3.0
        case .r3x4: return 3.0 / 4.0
        case .r2x1: return 2
        case .r185x1: return 1.85
        case .r235x1: return 2.35
        }
    }
}

nonisolated enum VEProxyMode: String, Codable, CaseIterable, Sendable { case auto, always, never }

nonisolated enum VEMediaKind: String, Codable, Sendable { case video, image, audio, gif }
nonisolated enum VEClipKind: String, Codable, Sendable { case video, image, gif, freeze }
nonisolated enum VERotation: String, Codable, Sendable {
    case none, rotate90, rotate180, rotate270
    var degrees: Int {
        switch self {
        case .none: return 0
        case .rotate90: return 90
        case .rotate180: return 180
        case .rotate270: return 270
        }
    }
    var swapsAxes: Bool { self == .rotate90 || self == .rotate270 }
}

// MARK: - Geometry

nonisolated struct VERect: Codable, Equatable, Sendable, Hashable {
    var x: Double, y: Double, w: Double, h: Double
    static let full = VERect(x: 0, y: 0, w: 1, h: 1)
    var cgRect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
    init(x: Double, y: Double, w: Double, h: Double) { self.x = x; self.y = y; self.w = w; self.h = h }
    init(_ r: CGRect) { x = r.origin.x; y = r.origin.y; w = r.width; h = r.height }
}

nonisolated struct VESize: Codable, Equatable, Sendable, Hashable {
    var width: Int, height: Int
    var cgSize: CGSize { CGSize(width: width, height: height) }
    var aspect: Double { height > 0 ? Double(width) / Double(height) : 1 }
}

nonisolated struct VECanvas: Codable, Equatable, Sendable, Hashable {
    var ratio: VERatio
    var width: Int
    var height: Int
    var aspect: Double { height > 0 ? Double(width) / Double(height) : 1 }
    var size: CGSize { CGSize(width: width, height: height) }

    /// CAN-2: the resolution's short edge, the other edge from the ratio, rounded to even.
    static func make(ratio: VERatio, resolution: VEResolution, originalAspect: Double?) -> VECanvas {
        let aspect = ratio.aspect ?? originalAspect ?? (16.0 / 9.0)
        return make(ratio: ratio, resolution: resolution, aspect: aspect)
    }
    static func make(ratio: VERatio, resolution: VEResolution, aspect: Double) -> VECanvas {
        let short = resolution.shortEdge
        func even(_ v: Double) -> Int { max(2, Int((v / 2).rounded()) * 2) }
        if aspect >= 1 { return VECanvas(ratio: ratio, width: even(Double(short) * aspect), height: short) }
        return VECanvas(ratio: ratio, width: short, height: even(Double(short) / aspect))
    }
    /// Same ratio at another resolution (export can pick a resolution other than the project's).
    func scaled(to resolution: VEResolution) -> VECanvas {
        VECanvas.make(ratio: ratio, resolution: resolution, aspect: aspect)
    }
}

// MARK: - Settings

nonisolated struct VEProjectSettings: Codable, Equatable, Sendable {
    var frameRate: Int = 30
    var resolution: VEResolution = .p1080
    var canvas: VECanvas = VECanvas(ratio: .r9x16, width: 1080, height: 1920)
    var hdr: Bool = false
    var muteOriginalAudio: Bool = false
    var defaultPhotoDuration: VETime = 3 * VETimeUtil.second
    var defaultFreezeDuration: VETime = 3 * VETimeUtil.second
    var defaultLayerDuration: VETime = 3 * VETimeUtil.second
    var proxyPlayback: VEProxyMode = .auto

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: VEDynamicKey.self)
        frameRate = VECoding.get(c, "frameRate", 30)
        resolution = VECoding.get(c, "resolution", VEResolution.p1080)
        canvas = VECoding.get(c, "canvas", VECanvas(ratio: .r9x16, width: 1080, height: 1920))
        hdr = VECoding.get(c, "hdr", false)
        muteOriginalAudio = VECoding.get(c, "muteOriginalAudio", false)
        defaultPhotoDuration = VECoding.get(c, "defaultPhotoDuration", 3 * VETimeUtil.second)
        defaultFreezeDuration = VECoding.get(c, "defaultFreezeDuration", 3 * VETimeUtil.second)
        defaultLayerDuration = VECoding.get(c, "defaultLayerDuration", 3 * VETimeUtil.second)
        proxyPlayback = VECoding.get(c, "proxyPlayback", VEProxyMode.auto)
    }
}

// MARK: - Media sources

nonisolated struct VEIdentity: Codable, Equatable, Sendable, Hashable {
    var size: Int64
    var mtime: Date
    var hash: String          // "sha256:…" of the first and last 1 MiB
}

nonisolated struct VEDerived: Codable, Equatable, Sendable {
    var proxy: String?
    var thumbs: String?
    var waveform: String?
    var reversed: String?
    init() {}
}

/// One imported file. `path` is never absolute: `drive://…` (relative to the drive root, STO-2),
/// `media/…` or `audio/…` (relative to the project package) or `Library/…` (the shared editor
/// library). The identity record lets a moved file be found again (STO-10).
nonisolated struct VEMediaSource: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var kind: VEMediaKind
    var path: String
    var identity: VEIdentity
    var duration: VETime
    var width: Int
    var height: Int
    var transform: VERotation = .none
    var fps: Double = 0
    var vfr: Bool = false
    var codec: String?
    var bitDepth: Int?
    var colorTransfer: String?        // "SDR", "HLG", "PQ"
    var hasAudio: Bool = false
    var hasAlpha: Bool = false
    var audioChannels: Int?
    var audioSampleRate: Double?
    var createdAt: Date?
    var originalName: String
    var derived: VEDerived = VEDerived()
    var extra: [String: JSONValue] = [:]

    /// Pixel size after the file's rotation is applied (what the viewer sees).
    var displaySize: VESize {
        transform.swapsAxes ? VESize(width: height, height: width) : VESize(width: width, height: height)
    }
    var displayName: String { originalName.isEmpty ? (path as NSString).lastPathComponent : originalName }
    var isStill: Bool { kind == .image }

    private static let known: Set<String> = ["id", "kind", "path", "identity", "duration", "width", "height", "transform", "fps", "vfr",
                                             "codec", "bitDepth", "colorTransfer", "hasAudio", "hasAlpha", "audioChannels",
                                             "audioSampleRate", "createdAt", "originalName", "derived"]

    init(id: String, kind: VEMediaKind, path: String, identity: VEIdentity, duration: VETime, width: Int, height: Int, originalName: String) {
        self.id = id; self.kind = kind; self.path = path; self.identity = identity
        self.duration = duration; self.width = width; self.height = height; self.originalName = originalName
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: VEDynamicKey.self)
        id = try VECoding.req(c, "id")
        kind = VECoding.get(c, "kind", VEMediaKind.video)
        path = try VECoding.req(c, "path")
        identity = VECoding.get(c, "identity", VEIdentity(size: 0, mtime: Date(timeIntervalSince1970: 0), hash: ""))
        duration = VECoding.get(c, "duration", 0)
        width = VECoding.get(c, "width", 0)
        height = VECoding.get(c, "height", 0)
        transform = VECoding.get(c, "transform", VERotation.none)
        fps = VECoding.get(c, "fps", 0)
        vfr = VECoding.get(c, "vfr", false)
        codec = VECoding.opt(c, "codec")
        bitDepth = VECoding.opt(c, "bitDepth")
        colorTransfer = VECoding.opt(c, "colorTransfer")
        hasAudio = VECoding.get(c, "hasAudio", false)
        hasAlpha = VECoding.get(c, "hasAlpha", false)
        audioChannels = VECoding.opt(c, "audioChannels")
        audioSampleRate = VECoding.opt(c, "audioSampleRate")
        createdAt = VECoding.opt(c, "createdAt")
        originalName = VECoding.get(c, "originalName", "")
        derived = VECoding.get(c, "derived", VEDerived())
        extra = VECoding.extras(c, known: Self.known)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: VEDynamicKey.self)
        try VECoding.put(&c, "id", id); try VECoding.put(&c, "kind", kind); try VECoding.put(&c, "path", path); try VECoding.put(&c, "identity", identity)
        try VECoding.put(&c, "duration", duration); try VECoding.put(&c, "width", width); try VECoding.put(&c, "height", height)
        try VECoding.put(&c, "transform", transform); try VECoding.put(&c, "fps", fps); try VECoding.put(&c, "vfr", vfr)
        try VECoding.putIfPresent(&c, "codec", codec); try VECoding.putIfPresent(&c, "bitDepth", bitDepth); try VECoding.putIfPresent(&c, "colorTransfer", colorTransfer)
        try VECoding.put(&c, "hasAudio", hasAudio); try VECoding.put(&c, "hasAlpha", hasAlpha)
        try VECoding.putIfPresent(&c, "audioChannels", audioChannels); try VECoding.putIfPresent(&c, "audioSampleRate", audioSampleRate)
        try VECoding.putIfPresent(&c, "createdAt", createdAt); try VECoding.put(&c, "originalName", originalName); try VECoding.put(&c, "derived", derived)
        try VECoding.putExtras(&c, extra)
    }
}

// MARK: - Clips

nonisolated struct VERange: Codable, Equatable, Sendable, Hashable {
    var start: VETime
    var duration: VETime
    var end: VETime { start + duration }
    static func == (a: VERange, b: VERange) -> Bool { a.start == b.start && a.duration == b.duration }
}

nonisolated struct VESpeedPoint: Codable, Equatable, Sendable { var t: Double; var rate: Double }

nonisolated struct VESpeed: Codable, Equatable, Sendable {
    var mode: String = "constant"           // "constant" | "curve"
    var rate: Double = 1
    var points: [VESpeedPoint] = []
    var keepPitch: Bool = true
    var frameBlending: Bool = false
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: VEDynamicKey.self)
        mode = VECoding.get(c, "mode", "constant"); rate = VECoding.get(c, "rate", 1.0); points = VECoding.get(c, "points", [])
        keepPitch = VECoding.get(c, "keepPitch", true); frameBlending = VECoding.get(c, "frameBlending", false)
    }
    /// Effective constant rate (curve speeds average over the curve for duration purposes).
    var effectiveRate: Double {
        if mode == "curve", points.count >= 2 {
            // Mean of the piecewise-linear curve ≈ timeline duration factor.
            var area = 0.0
            for i in 1..<points.count { area += (points[i].t - points[i - 1].t) * (points[i].rate + points[i - 1].rate) / 2 }
            return max(0.01, area)
        }
        return max(0.01, rate)
    }
}

nonisolated struct VECrop: Codable, Equatable, Sendable {
    var preset: String = "free"
    var rect: VERect = .full
    var straighten: Double = 0
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: VEDynamicKey.self)
        preset = VECoding.get(c, "preset", "free"); rect = VECoding.get(c, "rect", VERect.full); straighten = VECoding.get(c, "straighten", 0.0)
    }
    var isIdentity: Bool { rect == .full && straighten == 0 }
}

/// Position in canvas half-widths / half-heights (0 = centre, 1 = right/top edge), `scale` 1 = the
/// clip fitted inside the canvas, rotation in degrees (PRJ-1 normalized units).
nonisolated struct VETransform: Codable, Equatable, Sendable {
    var x: Double = 0, y: Double = 0, scale: Double = 1, rotation: Double = 0
    var flipH: Bool = false, flipV: Bool = false
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: VEDynamicKey.self)
        x = VECoding.get(c, "x", 0.0); y = VECoding.get(c, "y", 0.0); scale = VECoding.get(c, "scale", 1.0); rotation = VECoding.get(c, "rotation", 0.0)
        flipH = VECoding.get(c, "flipH", false); flipV = VECoding.get(c, "flipV", false)
    }
    var isIdentity: Bool { x == 0 && y == 0 && scale == 1 && rotation == 0 && !flipH && !flipV }
}

nonisolated struct VEBackground: Codable, Equatable, Sendable {
    var kind: String = "color"          // color | blur | image | none
    var color: String = "#000000"
    var blurLevel: Int = 2
    var path: String?
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: VEDynamicKey.self)
        kind = VECoding.get(c, "kind", "color"); color = VECoding.get(c, "color", "#000000"); blurLevel = VECoding.get(c, "blurLevel", 2); path = VECoding.opt(c, "path")
    }
}

nonisolated struct VEClip: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var mediaId: String
    var kind: VEClipKind
    var sourceRange: VERange
    var timelineStart: VETime = 0            // overlays only; main-track position is implicit
    var speed: VESpeed = VESpeed()
    var reversed: Bool = false
    var freezeSourceTime: VETime?
    var crop: VECrop = VECrop()
    var transform: VETransform = VETransform()
    var opacity: Double = 1
    var blend: String = "normal"
    var volume: Double = 1                   // 1 = unity; the UI shows 0–1000 with 100 = unity
    var fadeIn: VETime = 0
    var fadeOut: VETime = 0
    var audioMuted: Bool = false
    var audioExtracted: Bool = false
    var filter: JSONValue?
    var adjust: JSONValue?
    var lut: String?
    var mask: JSONValue?
    var chromaKey: JSONValue?
    var animation: JSONValue?
    var background: VEBackground = VEBackground()
    var keyframes: [JSONValue] = []
    var extra: [String: JSONValue] = [:]

    private static let known: Set<String> = ["id", "mediaId", "kind", "sourceRange", "timelineStart", "speed", "reversed", "freezeSourceTime",
                                             "crop", "transform", "opacity", "blend", "volume", "fadeIn", "fadeOut", "audioMuted",
                                             "audioExtracted", "filter", "adjust", "lut", "mask", "chromaKey", "animation", "background", "keyframes"]

    init(id: String = VEIDs.new(), mediaId: String, kind: VEClipKind, sourceRange: VERange) {
        self.id = id; self.mediaId = mediaId; self.kind = kind; self.sourceRange = sourceRange
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: VEDynamicKey.self)
        id = try VECoding.req(c, "id"); mediaId = try VECoding.req(c, "mediaId")
        kind = VECoding.get(c, "kind", VEClipKind.video)
        sourceRange = try VECoding.req(c, "sourceRange")
        timelineStart = VECoding.get(c, "timelineStart", 0)
        speed = VECoding.get(c, "speed", VESpeed())
        reversed = VECoding.get(c, "reversed", false)
        freezeSourceTime = VECoding.opt(c, "freezeSourceTime")
        crop = VECoding.get(c, "crop", VECrop())
        transform = VECoding.get(c, "transform", VETransform())
        opacity = VECoding.get(c, "opacity", 1.0)
        blend = VECoding.get(c, "blend", "normal")
        volume = VECoding.get(c, "volume", 1.0)
        fadeIn = VECoding.get(c, "fadeIn", 0); fadeOut = VECoding.get(c, "fadeOut", 0)
        audioMuted = VECoding.get(c, "audioMuted", false); audioExtracted = VECoding.get(c, "audioExtracted", false)
        filter = VECoding.opt(c, "filter"); adjust = VECoding.opt(c, "adjust"); lut = VECoding.opt(c, "lut"); mask = VECoding.opt(c, "mask")
        chromaKey = VECoding.opt(c, "chromaKey"); animation = VECoding.opt(c, "animation")
        background = VECoding.get(c, "background", VEBackground())
        keyframes = VECoding.get(c, "keyframes", [])
        extra = VECoding.extras(c, known: Self.known)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: VEDynamicKey.self)
        try VECoding.put(&c, "id", id); try VECoding.put(&c, "mediaId", mediaId); try VECoding.put(&c, "kind", kind); try VECoding.put(&c, "sourceRange", sourceRange)
        try VECoding.put(&c, "timelineStart", timelineStart); try VECoding.put(&c, "speed", speed); try VECoding.put(&c, "reversed", reversed)
        try VECoding.putIfPresent(&c, "freezeSourceTime", freezeSourceTime)
        try VECoding.put(&c, "crop", crop); try VECoding.put(&c, "transform", transform); try VECoding.put(&c, "opacity", opacity); try VECoding.put(&c, "blend", blend)
        try VECoding.put(&c, "volume", volume); try VECoding.put(&c, "fadeIn", fadeIn); try VECoding.put(&c, "fadeOut", fadeOut)
        try VECoding.put(&c, "audioMuted", audioMuted); try VECoding.put(&c, "audioExtracted", audioExtracted)
        try VECoding.putIfPresent(&c, "filter", filter); try VECoding.putIfPresent(&c, "adjust", adjust); try VECoding.putIfPresent(&c, "lut", lut)
        try VECoding.putIfPresent(&c, "mask", mask); try VECoding.putIfPresent(&c, "chromaKey", chromaKey); try VECoding.putIfPresent(&c, "animation", animation)
        try VECoding.put(&c, "background", background); try VECoding.put(&c, "keyframes", keyframes)
        try VECoding.putExtras(&c, extra)
    }

    /// Stills and freezes have no speed; their source range *is* their timeline length.
    var hasSpeed: Bool { kind == .video || kind == .gif }
    var rate: Double { hasSpeed ? speed.effectiveRate : 1 }
    /// Length on the timeline after speed.
    var timelineDuration: VETime {
        hasSpeed ? max(1, VETime((Double(sourceRange.duration) / rate).rounded())) : max(1, sourceRange.duration)
    }
    var timelineEnd: VETime { timelineStart + timelineDuration }
    /// Source time for a timeline offset inside the clip (constant speed; reverse handled by the builder).
    func sourceTime(atOffset offset: VETime) -> VETime {
        let o = max(0, min(timelineDuration, offset))
        return sourceRange.start + (hasSpeed ? VETime((Double(o) * rate).rounded()) : o)
    }
}

nonisolated struct VEAudioClip: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var mediaId: String
    var sourceRange: VERange
    var timelineStart: VETime
    var rate: Double = 1
    var keepPitch: Bool = true
    var volume: Double = 1
    var fadeIn: VETime = 0
    var fadeOut: VETime = 0
    var muted: Bool = false
    var extra: [String: JSONValue] = [:]

    private static let known: Set<String> = ["id", "mediaId", "sourceRange", "timelineStart", "rate", "keepPitch", "volume", "fadeIn", "fadeOut", "muted"]

    init(id: String = VEIDs.new(), mediaId: String, sourceRange: VERange, timelineStart: VETime) {
        self.id = id; self.mediaId = mediaId; self.sourceRange = sourceRange; self.timelineStart = timelineStart
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: VEDynamicKey.self)
        id = try VECoding.req(c, "id"); mediaId = try VECoding.req(c, "mediaId"); sourceRange = try VECoding.req(c, "sourceRange")
        timelineStart = VECoding.get(c, "timelineStart", 0); rate = VECoding.get(c, "rate", 1.0); keepPitch = VECoding.get(c, "keepPitch", true)
        volume = VECoding.get(c, "volume", 1.0); fadeIn = VECoding.get(c, "fadeIn", 0); fadeOut = VECoding.get(c, "fadeOut", 0); muted = VECoding.get(c, "muted", false)
        extra = VECoding.extras(c, known: Self.known)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: VEDynamicKey.self)
        try VECoding.put(&c, "id", id); try VECoding.put(&c, "mediaId", mediaId); try VECoding.put(&c, "sourceRange", sourceRange); try VECoding.put(&c, "timelineStart", timelineStart)
        try VECoding.put(&c, "rate", rate); try VECoding.put(&c, "keepPitch", keepPitch); try VECoding.put(&c, "volume", volume)
        try VECoding.put(&c, "fadeIn", fadeIn); try VECoding.put(&c, "fadeOut", fadeOut); try VECoding.put(&c, "muted", muted)
        try VECoding.putExtras(&c, extra)
    }
    var timelineDuration: VETime { max(1, VETime((Double(sourceRange.duration) / max(0.01, rate)).rounded())) }
    var timelineEnd: VETime { timelineStart + timelineDuration }
}

// MARK: - Tracks, transitions, cover

nonisolated struct VETracks: Codable, Equatable, Sendable {
    var main: [VEClip] = []
    var overlays: [[VEClip]] = []
    var audio: [[VEAudioClip]] = []
    var text: [[JSONValue]] = []
    var stickers: [[JSONValue]] = []
    var effects: [[JSONValue]] = []
    var filters: [[JSONValue]] = []
    var adjust: [[JSONValue]] = []
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: VEDynamicKey.self)
        main = VECoding.get(c, "main", []); overlays = VECoding.get(c, "overlays", []); audio = VECoding.get(c, "audio", [])
        text = VECoding.get(c, "text", []); stickers = VECoding.get(c, "stickers", []); effects = VECoding.get(c, "effects", [])
        filters = VECoding.get(c, "filters", []); adjust = VECoding.get(c, "adjust", [])
    }
}

nonisolated struct VETransition: Codable, Equatable, Sendable {
    var afterMainClip: String
    var id: String
    var duration: VETime
}

nonisolated struct VECover: Codable, Equatable, Sendable {
    var kind: String = "frame"       // frame | image
    var time: VETime? = 0
    var path: String? = "cover.jpg"
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: VEDynamicKey.self)
        kind = VECoding.get(c, "kind", "frame"); time = VECoding.opt(c, "time"); path = VECoding.opt(c, "path")
    }
}

// MARK: - Project document

nonisolated struct VEProject: Codable, Equatable, Sendable, Identifiable {
    static let currentSchema = 1

    var schemaVersion: Int = VEProject.currentSchema
    var id: UUID
    var name: String
    var createdAt: Date
    var modifiedAt: Date
    var settings: VEProjectSettings = VEProjectSettings()
    var cover: VECover = VECover()
    var media: [VEMediaSource] = []
    var tracks: VETracks = VETracks()
    var transitions: [VETransition] = []
    var beats: [String: [VETime]] = [:]
    var extra: [String: JSONValue] = [:]

    private static let known: Set<String> = ["schemaVersion", "id", "name", "createdAt", "modifiedAt", "settings", "cover", "media",
                                             "tracks", "transitions", "beats"]

    init(name: String) {
        id = UUID(); self.name = name; createdAt = Date(); modifiedAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: VEDynamicKey.self)
        schemaVersion = VECoding.get(c, "schemaVersion", 1)
        id = VECoding.get(c, "id", UUID())
        name = VECoding.get(c, "name", "Project")
        createdAt = VECoding.get(c, "createdAt", Date())
        modifiedAt = VECoding.get(c, "modifiedAt", createdAt)
        settings = VECoding.get(c, "settings", VEProjectSettings())
        cover = VECoding.get(c, "cover", VECover())
        media = VECoding.get(c, "media", [])
        tracks = VECoding.get(c, "tracks", VETracks())
        transitions = VECoding.get(c, "transitions", [])
        beats = VECoding.get(c, "beats", [:])
        extra = VECoding.extras(c, known: Self.known)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: VEDynamicKey.self)
        try VECoding.put(&c, "schemaVersion", schemaVersion); try VECoding.put(&c, "id", id); try VECoding.put(&c, "name", name)
        try VECoding.put(&c, "createdAt", createdAt); try VECoding.put(&c, "modifiedAt", modifiedAt)
        try VECoding.put(&c, "settings", settings); try VECoding.put(&c, "cover", cover); try VECoding.put(&c, "media", media)
        try VECoding.put(&c, "tracks", tracks); try VECoding.put(&c, "transitions", transitions); try VECoding.put(&c, "beats", beats)
        try VECoding.putExtras(&c, extra)
    }

    /// The part of the project that edits change — snapshotted by every undoable command.
    var editableState: VEEditableState {
        get { VEEditableState(name: name, settings: settings, cover: cover, media: media, tracks: tracks, transitions: transitions, beats: beats) }
        set {
            name = newValue.name; settings = newValue.settings; cover = newValue.cover; media = newValue.media
            tracks = newValue.tracks; transitions = newValue.transitions; beats = newValue.beats
        }
    }

    // MARK: Queries

    func source(_ id: String) -> VEMediaSource? { media.first { $0.id == id } }
    func mainIndex(of clipID: String) -> Int? { tracks.main.firstIndex { $0.id == clipID } }
    func mainClip(_ clipID: String) -> VEClip? { tracks.main.first { $0.id == clipID } }
    func transition(after clipID: String) -> VETransition? { transitions.first { $0.afterMainClip == clipID } }

    /// Timeline start of each main clip. Transitions overlap the clips they join, so a clip after a
    /// transition starts `duration` earlier than the sum of the previous clips (TL-18).
    func mainStarts() -> [VETime] {
        var out: [VETime] = []
        var t: VETime = 0
        for (i, c) in tracks.main.enumerated() {
            if i > 0, let tr = transition(after: tracks.main[i - 1].id) { t -= min(tr.duration, c.timelineDuration) }
            out.append(t)
            t += c.timelineDuration
        }
        return out
    }
    func mainStart(of clipID: String) -> VETime? {
        guard let i = mainIndex(of: clipID) else { return nil }
        return mainStarts()[i]
    }
    /// Project length = the main track's length; everything past it is not rendered (TL-18).
    var duration: VETime {
        let starts = mainStarts()
        guard let last = tracks.main.last, let s = starts.last else { return 0 }
        return s + last.timelineDuration
    }
    /// Main clip under a timeline time (the earlier clip wins at a cut).
    func mainClip(at time: VETime) -> (index: Int, clip: VEClip, start: VETime)? {
        let starts = mainStarts()
        for (i, c) in tracks.main.enumerated() {
            if time >= starts[i] && time < starts[i] + c.timelineDuration { return (i, c, starts[i]) }
        }
        if let last = tracks.main.last, let s = starts.last, time >= s { return (tracks.main.count - 1, last, s) }
        return nil
    }
    /// Cut points (clip boundaries) on the main track, including 0 and the end.
    func mainCuts() -> [VETime] {
        var cuts = mainStarts()
        cuts.append(duration)
        return cuts
    }
    var allClips: [VEClip] { tracks.main + tracks.overlays.flatMap { $0 } }
    var hasMissingMediaReferences: Bool { allClips.contains { source($0.mediaId) == nil } }
    var usedMediaIDs: Set<String> {
        Set(allClips.map(\.mediaId) + tracks.audio.flatMap { $0 }.map(\.mediaId))
    }

    /// Aspect of the first main clip (after crop), for the "Original" ratio.
    func originalAspect() -> Double? {
        guard let first = tracks.main.first, let src = source(first.mediaId) else { return nil }
        let s = src.displaySize
        guard s.width > 0, s.height > 0 else { return nil }
        let r = first.crop.rect
        return (Double(s.width) * r.w) / (Double(s.height) * r.h)
    }

    /// Re-derive the canvas pixel size from resolution + ratio (and the first clip for Original).
    mutating func refreshCanvas() {
        settings.canvas = VECanvas.make(ratio: settings.canvas.ratio, resolution: settings.resolution,
                                        originalAspect: settings.canvas.ratio == .original ? originalAspect() : settings.canvas.aspect)
    }
}

/// The part of a project that edits change — snapshotted by every undoable command.
nonisolated struct VEEditableState: Equatable, Sendable {
    var name: String
    var settings: VEProjectSettings
    var cover: VECover
    var media: [VEMediaSource]
    var tracks: VETracks
    var transitions: [VETransition]
    var beats: [String: [VETime]]
}


// MARK: - IDs, names, paths, errors

nonisolated enum VEIDs {
    /// Short, URL-safe ids for clips/media (the document is hand-readable JSON).
    static func new() -> String {
        let raw = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        return String(raw.prefix(12)).lowercased()
    }
}

nonisolated enum VENames {
    static let forbidden: Set<Character> = ["\\", "/", ":", "*", "?", "\"", "<", ">", "|"]

    /// STO-8: strip characters exFAT/FAT refuse, trim, and keep each component well under 255 bytes.
    static func sanitize(_ raw: String, fallback: String = "Project") -> String {
        var s = String(raw.map { forbidden.contains($0) || $0.isNewline ? "-" : $0 })
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix(".") { s.removeFirst() }
        while s.utf8.count > 200 { s.removeLast() }
        return s.isEmpty ? fallback : s
    }

    /// `base`, `base (2)`, `base (3)`… — the first that doesn't exist in `dir` (case-insensitive).
    static func unique(_ base: String, ext: String, in dir: URL) -> String {
        let existing = Set(((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).map { $0.lowercased() })
        func candidate(_ n: Int) -> String {
            let name = n == 1 ? base : "\(base) (\(n))"
            return ext.isEmpty ? name : "\(name).\(ext)"
        }
        var n = 1
        while existing.contains(candidate(n).lowercased()) { n += 1 }
        return candidate(n)
    }

    static func defaultProjectName(_ date: Date = Date()) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm"
        return "Project \(f.string(from: date))"
    }
    static func exportName(project: String, date: Date = Date()) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm"
        return sanitize("\(project) \(f.string(from: date))")
    }
}

/// The user-facing error model (ARC-9). Every failure path renders as a title, one sentence and one
/// action; raw system error text never reaches the screen.
nonisolated enum VEError: Error, Equatable, Sendable {
    case driveUnavailable
    case readOnlyVolume
    case insufficientSpace(neededBytes: Int64)
    case unsupportedMedia(name: String, codec: String)
    case missingMedia([String])
    case tooManyLayers(limit: Int)
    case exportFailed(String)
    case permissionDenied(kind: String)
    case documentCorrupt(recovered: Bool)
    case cancelled
    case fileTooLargeForVolume(limitBytes: Int64)

    var title: String {
        switch self {
        case .driveUnavailable: return "Drive disconnected"
        case .readOnlyVolume: return "Drive is read-only"
        case .insufficientSpace: return "Not enough space"
        case .unsupportedMedia: return "Can't import this file"
        case .missingMedia: return "Missing media"
        case .tooManyLayers: return "Too many layers"
        case .exportFailed: return "Export failed"
        case .permissionDenied: return "Permission needed"
        case .documentCorrupt: return "Project recovered"
        case .cancelled: return "Cancelled"
        case .fileTooLargeForVolume: return "File too large for this drive"
        }
    }
    var message: String {
        switch self {
        case .driveUnavailable: return "Reconnect the drive to keep editing. Your edits are kept in memory until it comes back."
        case .readOnlyVolume: return "This drive mounted read-only, so projects open read-only and import, autosave and export are off."
        case .insufficientSpace(let n): return "Free up about \(ByteCountFormatter.string(fromByteCount: n, countStyle: .file)) on the drive and try again."
        case .unsupportedMedia(let name, let codec): return "Can't import \(name): \(codec) isn't supported."
        case .missingMedia(let ids): return "\(ids.count) clip\(ids.count == 1 ? "" : "s") point\(ids.count == 1 ? "s" : "") to media that isn't on the drive any more. Relink or remove \(ids.count == 1 ? "it" : "them") before exporting."
        case .tooManyLayers(let l): return "This device supports up to \(l) overlays at once."
        case .exportFailed(let why): return why
        case .permissionDenied(let k): return "Allow \(k) access in Settings to use this feature."
        case .documentCorrupt(let recovered): return recovered ? "The last save couldn't be read, so the previous good save was restored." : "The project file couldn't be read."
        case .cancelled: return "The operation was cancelled."
        case .fileTooLargeForVolume(let l): return "This drive is FAT32, which can't hold a file over \(ByteCountFormatter.string(fromByteCount: l, countStyle: .file)). Lower the quality or resolution, or reformat the drive as exFAT."
        }
    }
    var action: String {
        switch self {
        case .driveUnavailable: return "Reconnect drive"
        case .insufficientSpace, .fileTooLargeForVolume: return "Free up space"
        case .missingMedia: return "Relink"
        case .permissionDenied: return "Open Settings"
        default: return "OK"
        }
    }
}
