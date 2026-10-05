import Foundation
import os

/// Everything the video editor persists lives under `<DriveRoot>/VideoEditor/` (STO-1). These are
/// the only path builders — no other editor code spells a folder name — so the host can rename the
/// root and every write stays on the drive (STO-3/STO-4).
nonisolated enum VEDriveLayout {
    nonisolated(unsafe) static var rootFolderName = "VideoEditor"
    static let packageExtension = "vep"
    static let libraryFolders = ["Music", "SFX", "Fonts", "Stickers", "LUTs", "Backgrounds"]

    static func editorRoot(driveRoot: URL) -> URL { driveRoot.appendingPathComponent(rootFolderName, isDirectory: true) }
    static func settingsFile(_ root: URL) -> URL { root.appendingPathComponent("settings.json") }
    static func logs(_ root: URL) -> URL { root.appendingPathComponent("logs", isDirectory: true) }
    static func projects(_ root: URL) -> URL { root.appendingPathComponent("Projects", isDirectory: true) }
    static func exports(_ root: URL) -> URL { root.appendingPathComponent("Exports", isDirectory: true) }
    static func library(_ root: URL) -> URL { root.appendingPathComponent("Library", isDirectory: true) }
    static func library(_ root: URL, _ sub: String) -> URL { library(root).appendingPathComponent(sub, isDirectory: true) }

    // Package (one project)
    static func document(_ pkg: URL) -> URL { pkg.appendingPathComponent("project.json") }
    static func documentBackup(_ pkg: URL) -> URL { pkg.appendingPathComponent("project.json.bak") }
    static func lock(_ pkg: URL) -> URL { pkg.appendingPathComponent("project.lock") }
    static func media(_ pkg: URL) -> URL { pkg.appendingPathComponent("media", isDirectory: true) }
    static func derived(_ pkg: URL) -> URL { media(pkg).appendingPathComponent("derived", isDirectory: true) }
    static func proxies(_ pkg: URL) -> URL { pkg.appendingPathComponent("proxies", isDirectory: true) }
    static func thumbs(_ pkg: URL) -> URL { pkg.appendingPathComponent("thumbs", isDirectory: true) }
    static func waveforms(_ pkg: URL) -> URL { pkg.appendingPathComponent("waveforms", isDirectory: true) }
    static func audio(_ pkg: URL) -> URL { pkg.appendingPathComponent("audio", isDirectory: true) }
    static func audioDerived(_ pkg: URL) -> URL { audio(pkg).appendingPathComponent("derived", isDirectory: true) }
    static func cover(_ pkg: URL) -> URL { pkg.appendingPathComponent("cover.jpg") }
    static func renders(_ pkg: URL) -> URL { pkg.appendingPathComponent("renders", isDirectory: true) }

    /// Folders that are pure caches and rebuild lazily (STO-7 "Clear caches").
    static func cacheFolders(_ pkg: URL) -> [URL] { [proxies(pkg), thumbs(pkg), waveforms(pkg), renders(pkg)] }
    static func packageFolders(_ pkg: URL) -> [URL] {
        [media(pkg), derived(pkg), proxies(pkg), thumbs(pkg), waveforms(pkg), audio(pkg), audioDerived(pkg), renders(pkg)]
    }
}

/// JSON coders shared by the document, settings and lock files — ISO-8601 dates, stable key order
/// (so two saves of the same state are byte-identical, PRJ-9).
nonisolated enum VEJSON {
    static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }
    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

/// `os.Logger` per component (ARC-10). With Diagnostics on, lines are also appended to a rolling
/// `VideoEditor/logs/editor.log` on the drive — never to the sandbox.
nonisolated enum VELog {
    static let general = Logger(subsystem: "VideoEditor", category: "general")
    static let store = Logger(subsystem: "VideoEditor", category: "store")
    static let media = Logger(subsystem: "VideoEditor", category: "media")
    static let render = Logger(subsystem: "VideoEditor", category: "render")
    static let export = Logger(subsystem: "VideoEditor", category: "export")

    nonisolated(unsafe) static var diagnosticsRoot: URL?
    private static let queue = DispatchQueue(label: "VideoEditor.log", qos: .utility)
    private static let maxBytes = 2 * 1024 * 1024

    static func file(_ message: String) {
        guard let root = diagnosticsRoot else { return }
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        queue.async {
            let dir = VEDriveLayout.logs(root)
            try? DriveWriter.createDirectory(at: dir)
            let url = dir.appendingPathComponent("editor.log")
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? Int, size > maxBytes {
                let old = dir.appendingPathComponent("editor.1.log")
                try? FileManager.default.removeItem(at: old)
                try? FileManager.default.moveItem(at: url, to: old)
            }
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}

/// The editor's only persistence layer (ARC-1 DriveStore): knows the drive root, guarantees an
/// active security scope and `NSFileCoordinator` coordination for document and copy operations,
/// saves documents atomically (STO-5), and answers space / filesystem questions (STO-7, STO-8).
/// Entirely off the main actor — a slow drive must never block the UI.
nonisolated final class VEDriveStore: @unchecked Sendable {
    let driveRoot: URL
    let editorRoot: URL

    init(driveRoot: URL) {
        self.driveRoot = driveRoot.standardizedFileURL
        self.editorRoot = VEDriveLayout.editorRoot(driveRoot: self.driveRoot)
    }

    // MARK: Layout

    func ensureLayout() throws {
        let fm = FileManager.default
        var dirs = [editorRoot, VEDriveLayout.projects(editorRoot), VEDriveLayout.exports(editorRoot), VEDriveLayout.library(editorRoot)]
        dirs += VEDriveLayout.libraryFolders.map { VEDriveLayout.library(editorRoot, $0) }
        for d in dirs where !fm.fileExists(atPath: d.path) {
            try DriveWriter.createDirectory(at: d)
        }
    }

    func ensurePackageLayout(_ pkg: URL) throws {
        let fm = FileManager.default
        for d in [pkg] + VEDriveLayout.packageFolders(pkg) where !fm.fileExists(atPath: d.path) {
            try DriveWriter.createDirectory(at: d)
        }
    }

    // MARK: Security scope

    /// The host already holds the root's scope for the session; this balances an extra start/stop
    /// around the editor's own work so it stays correct if the host ever stops holding it (STO-5).
    func withScope<T>(_ body: () throws -> T) rethrows -> T {
        let started = driveRoot.startAccessingSecurityScopedResource()
        defer { if started { driveRoot.stopAccessingSecurityScopedResource() } }
        return try body()
    }

    // MARK: Coordinated I/O

    func readData(_ url: URL) throws -> Data {
        assertUnderDrive(url)
        var result: Data?
        var coordError: NSError?
        var readError: Error?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordError) { u in
            do { result = try Data(contentsOf: u) } catch { readError = error }
        }
        if let coordError { throw coordError }
        if let readError { throw readError }
        return result ?? Data()
    }

    /// Writes a sibling temp file then swaps it in. Used for caches and settings.
    func writeData(_ data: Data, to url: URL) throws {
        assertUnderDrive(url)
        try DriveWriter.createDirectory(at: url.deletingLastPathComponent())
        var coordError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordError) { u in
            do {
                let tmp = u.deletingLastPathComponent().appendingPathComponent(".\(u.lastPathComponent).tmp")
                try? FileManager.default.removeItem(at: tmp)
                try data.write(to: tmp)
                DriveWriter.fullSync(tmp)
                _ = try FileManager.default.replaceItemAt(u, withItemAt: tmp)
                DriveWriter.fullSyncFileAndParent(u)
            } catch { writeError = error }
        }
        if let coordError { throw coordError }
        if let writeError { throw writeError }
    }

    /// STO-5 document save: `project.json.tmp` → `replaceItemAt` with the previous version kept as
    /// `project.json.bak`. The document is never written in place.
    func saveDocument(_ data: Data, to url: URL, backupName: String) throws {
        assertUnderDrive(url)
        let dir = url.deletingLastPathComponent()
        try DriveWriter.createDirectory(at: dir)
        var coordError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordError) { u in
            do {
                let fm = FileManager.default
                let tmp = dir.appendingPathComponent("\(u.lastPathComponent).tmp")
                try? fm.removeItem(at: tmp)
                try data.write(to: tmp)
                DriveWriter.fullSync(tmp)
                if fm.fileExists(atPath: u.path) {
                    // Keep our own backup: replaceItemAt's backupItemName is not honoured on every
                    // filesystem (exFAT), so copy the previous good save explicitly.
                    let bak = dir.appendingPathComponent(backupName)
                    try? fm.removeItem(at: bak)
                    try? fm.copyItem(at: u, to: bak)
                    _ = try fm.replaceItemAt(u, withItemAt: tmp)
                } else {
                    try fm.moveItem(at: tmp, to: u)
                }
                DriveWriter.fullSyncFileAndParent(u)
            } catch { writeError = error }
        }
        if let coordError { throw coordError }
        if let writeError { throw writeError }
    }

    func coordinatedCopy(from src: URL, to dst: URL) throws {
        assertUnderDrive(dst)
        try DriveWriter.createDirectory(at: dst.deletingLastPathComponent())
        var coordError: NSError?
        var opError: Error?
        NSFileCoordinator().coordinate(readingItemAt: src, options: [], writingItemAt: dst, options: .forReplacing, error: &coordError) { s, d in
            do {
                try? FileManager.default.removeItem(at: d)
                try DriveWriter.copyItem(at: s, to: d)
                DriveWriter.fullSyncFileAndParent(d)
            } catch { opError = error }
        }
        if let coordError { throw coordError }
        if let opError { throw opError }
    }

    func coordinatedMove(from src: URL, to dst: URL) throws {
        assertUnderDrive(dst)
        try DriveWriter.createDirectory(at: dst.deletingLastPathComponent())
        var coordError: NSError?
        var opError: Error?
        NSFileCoordinator().coordinate(writingItemAt: src, options: .forMoving, writingItemAt: dst, options: .forReplacing, error: &coordError) { s, d in
            do {
                try FileManager.default.moveItem(at: s, to: d)
                DriveWriter.fullSyncFileAndParent(d)
            } catch { opError = error }
        }
        if let coordError { throw coordError }
        if let opError { throw opError }
    }

    func coordinatedRemove(_ url: URL) throws {
        assertUnderDrive(url)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var coordError: NSError?
        var opError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &coordError) { u in
            do { try FileManager.default.removeItem(at: u) } catch { opError = error }
        }
        if let coordError { throw coordError }
        if let opError { throw opError }
    }

    /// Directory listing with the first-enumeration retry (ARC-6: a freshly picked folder can
    /// enumerate empty once).
    func contents(of dir: URL, keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]) -> [URL] {
        var urls = Library.coordinatedContents(of: dir, keys: keys)
        if urls.isEmpty {
            Thread.sleep(forTimeInterval: 0.2)
            urls = Library.coordinatedContents(of: dir, keys: keys)
        }
        return urls
    }

    // MARK: Paths

    func isUnderDrive(_ url: URL) -> Bool {
        let p = url.standardizedFileURL.path
        return p == driveRoot.path || p.hasPrefix(driveRoot.path + "/")
    }

    /// Debug-only guard that no editor write escapes the drive (STO-3).
    func assertUnderDrive(_ url: URL) {
        #if DEBUG
        assert(isUnderDrive(url), "Video editor write outside the drive: \(url.path)")
        #endif
    }

    /// `drive://…` / `media/…` / `Library/…` → absolute URL (STO-9).
    func resolve(_ raw: String, package: URL) -> URL {
        if raw.hasPrefix("drive://") {
            let rel = String(raw.dropFirst("drive://".count))
            return rel.isEmpty ? driveRoot : driveRoot.appendingPathComponent(rel)
        }
        if raw.hasPrefix("Library/") { return editorRoot.appendingPathComponent(raw) }
        return package.appendingPathComponent(raw)
    }

    /// The portable reference for a file: package-relative when it's inside the package, editor
    /// library-relative inside `Library/`, drive-relative anywhere else on the drive, else nil.
    func reference(for url: URL, package: URL) -> String? {
        let p = url.standardizedFileURL.path
        let pkg = package.standardizedFileURL.path
        if p.hasPrefix(pkg + "/") { return String(p.dropFirst(pkg.count + 1)) }
        let lib = VEDriveLayout.library(editorRoot).path
        if p.hasPrefix(lib + "/") { return "Library/" + String(p.dropFirst(lib.count + 1)) }
        if isUnderDrive(url) { return "drive://" + String(p.dropFirst(driveRoot.path.count + 1)) }
        return nil
    }

    /// Does `url` live on the same volume as the drive? (Files-picker results: reference vs copy.)
    func sameVolume(as url: URL) -> Bool {
        if isUnderDrive(url) { return true }
        guard let a = try? driveRoot.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier,
              let b = try? url.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier else { return false }
        return a.isEqual(b)
    }

    // MARK: Capabilities

    func isReachable() -> Bool {
        (try? driveRoot.checkResourceIsReachable()) == true && FileManager.default.fileExists(atPath: driveRoot.path)
    }

    /// Free bytes on the drive. `volumeAvailableCapacityForImportantUsageKey` can come back nil on
    /// external volumes, so fall back to the plain capacity key (ARC-6).
    func freeSpace() -> Int64? {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
        guard let v = try? driveRoot.resourceValues(forKeys: keys) else { return nil }
        if let i = v.volumeAvailableCapacityForImportantUsage, i > 0 { return i }
        if let c = v.volumeAvailableCapacity { return Int64(c) }
        return nil
    }

    var isReadOnly: Bool {
        if let v = try? driveRoot.resourceValues(forKeys: [.volumeIsReadOnlyKey]), let ro = v.volumeIsReadOnly { return ro }
        return false
    }

    var fileSystemName: String {
        var s = statfs()
        guard statfs(driveRoot.path, &s) == 0 else { return "" }
        return withUnsafeBytes(of: &s.f_fstypename) { raw -> String in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
    }

    /// FAT32 ("msdos") caps single files at 4 GiB − 1 (STO-8).
    var isFAT32: Bool { fileSystemName == "msdos" }
    var maxFileSize: Int64? { isFAT32 ? Int64(4) * 1024 * 1024 * 1024 - 1 : nil }

    func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    func directorySize(_ url: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e {
            if let v = try? f.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), v.isRegularFile == true { total += Int64(v.fileSize ?? 0) }
        }
        return total
    }

    /// STO-6: a failure that means the drive itself is gone, not just one file.
    static func isDriveLoss(_ error: Error) -> Bool {
        let e = error as NSError
        if e.domain == NSPOSIXErrorDomain { return [Int(ENODEV), Int(EIO), Int(ENXIO), Int(ENOTCONN)].contains(e.code) }
        if e.domain == NSCocoaErrorDomain, let under = e.userInfo[NSUnderlyingErrorKey] as? NSError, under.domain == NSPOSIXErrorDomain {
            return [Int(ENODEV), Int(EIO), Int(ENXIO), Int(ENOTCONN)].contains(under.code)
        }
        return false
    }

    // MARK: Settings

    func loadSettings() -> VEEditorSettings {
        guard let data = try? readData(VEDriveLayout.settingsFile(editorRoot)),
              let s = try? VEJSON.decoder.decode(VEEditorSettings.self, from: data) else { return VEEditorSettings() }
        return s
    }

    func saveSettings(_ s: VEEditorSettings) {
        guard let data = try? VEJSON.encoder.encode(s) else { return }
        try? writeData(data, to: VEDriveLayout.settingsFile(editorRoot))
    }
}

/// Editor preferences (what would normally sit in `UserDefaults`) — kept in `settings.json` on the
/// drive (STO-3) so the same drive behaves the same on another device.
nonisolated struct VEEditorSettings: Codable, Equatable, Sendable {
    var defaultPhotoDuration: VETime = 3 * VETimeUtil.second
    var snapping: Bool = true
    var haptics: Bool = true
    var proxyPlayback: VEProxyMode = .auto
    var diagnostics: Bool = false
    var recentProjects: [String] = []
    var favorites: [String] = []
    var lastExport: VEExportPreferences = VEExportPreferences()
    var extra: [String: JSONValue] = [:]

    private static let known: Set<String> = ["defaultPhotoDuration", "snapping", "haptics", "proxyPlayback", "diagnostics", "recentProjects", "favorites", "lastExport"]

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: VEDynamicKey.self)
        defaultPhotoDuration = VECoding.get(c, "defaultPhotoDuration", 3 * VETimeUtil.second)
        snapping = VECoding.get(c, "snapping", true); haptics = VECoding.get(c, "haptics", true)
        proxyPlayback = VECoding.get(c, "proxyPlayback", VEProxyMode.auto); diagnostics = VECoding.get(c, "diagnostics", false)
        recentProjects = VECoding.get(c, "recentProjects", []); favorites = VECoding.get(c, "favorites", [])
        lastExport = VECoding.get(c, "lastExport", VEExportPreferences())
        extra = VECoding.extras(c, known: Self.known)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: VEDynamicKey.self)
        try VECoding.put(&c, "defaultPhotoDuration", defaultPhotoDuration); try VECoding.put(&c, "snapping", snapping); try VECoding.put(&c, "haptics", haptics)
        try VECoding.put(&c, "proxyPlayback", proxyPlayback); try VECoding.put(&c, "diagnostics", diagnostics)
        try VECoding.put(&c, "recentProjects", recentProjects); try VECoding.put(&c, "favorites", favorites); try VECoding.put(&c, "lastExport", lastExport)
        try VECoding.putExtras(&c, extra)
    }
}

nonisolated struct VEExportPreferences: Codable, Equatable, Sendable {
    var resolution: VEResolution = .p1080
    var frameRate: Int? = nil             // nil = project frame rate
    var quality: String = "recommended"   // lower | recommended | higher | custom
    var customBitrateMbps: Double = 12
    var codec: String = "auto"            // auto | h264 | hevc
    var saveToPhotos: Bool = false
    var hdr: Bool? = nil                  // nil = follow the project's HDR state
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: VEDynamicKey.self)
        resolution = VECoding.get(c, "resolution", VEResolution.p1080); frameRate = VECoding.opt(c, "frameRate")
        quality = VECoding.get(c, "quality", "recommended"); customBitrateMbps = VECoding.get(c, "customBitrateMbps", 12.0)
        codec = VECoding.get(c, "codec", "auto"); saveToPhotos = VECoding.get(c, "saveToPhotos", false)
        hdr = VECoding.opt(c, "hdr")
    }
}

/// STO-6 drive-loss detection for Files-provided volumes, which post no disconnect notification:
/// a 2 s reachability poll of the drive root (off-main) plus error-driven reports from any I/O.
@MainActor @Observable final class VEDriveMonitor {
    private(set) var isConnected = true
    private(set) var lastSavedAt: Date?
    @ObservationIgnored var onLost: (() -> Void)?
    @ObservationIgnored var onRestored: (() -> Void)?

    @ObservationIgnored private var task: Task<Void, Never>?
    private let store: VEDriveStore

    init(store: VEDriveStore) { self.store = store }

    func start(interval: Double = 2) {
        stop()
        let store = self.store
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { break }
                let ok = await Task.detached(priority: .utility) { store.isReachable() }.value
                self?.apply(connected: ok)
            }
        }
    }

    func stop() { task?.cancel(); task = nil }

    func noteSaved() { lastSavedAt = Date() }

    /// Error-driven detection: any I/O failure that looks like the drive vanished.
    func report(_ error: Error) {
        if VEDriveStore.isDriveLoss(error) { apply(connected: false) }
    }

    private func apply(connected: Bool) {
        guard connected != isConnected else { return }
        isConnected = connected
        if connected { onRestored?() } else { onLost?() }
        VELog.store.log("drive \(connected ? "restored" : "lost")")
    }
}
