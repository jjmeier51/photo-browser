import Foundation
import os
import UIKit

// MARK: - Commands and undo

/// One reversible edit (PRJ-4): the editable state before and after. Snapshotting the whole
/// editable sub-document keeps every command trivially invertible and lets continuous gestures
/// (trims, slider drags) coalesce into one entry on release.
nonisolated struct VEEditCommand: Sendable {
    let label: String
    let before: VEEditableState
    let after: VEEditableState
}

@MainActor @Observable final class VEUndoStack {
    static let limit = 200
    private(set) var undoList: [VEEditCommand] = []
    private(set) var redoList: [VEEditCommand] = []

    var canUndo: Bool { !undoList.isEmpty }
    var canRedo: Bool { !redoList.isEmpty }
    var undoLabel: String? { undoList.last?.label }
    var redoLabel: String? { redoList.last?.label }

    func push(_ c: VEEditCommand) {
        undoList.append(c)
        if undoList.count > Self.limit { undoList.removeFirst(undoList.count - Self.limit) }
        redoList.removeAll()
    }
    func popUndo() -> VEEditCommand? {
        guard let c = undoList.popLast() else { return nil }
        redoList.append(c)
        return c
    }
    func popRedo() -> VEEditCommand? {
        guard let c = redoList.popLast() else { return nil }
        undoList.append(c)
        return c
    }
    func clear() { undoList.removeAll(); redoList.removeAll() }
}

// MARK: - Lock file

/// `project.lock` (PRJ-3): one drive can move between an iPhone and an iPad, so a lock younger than
/// two minutes from another device opens the project read-only.
nonisolated struct VELockInfo: Codable, Sendable {
    var deviceName: String
    var deviceID: String
    var heartbeat: Date

    static let staleAfter: TimeInterval = 120

    @MainActor static func current() -> VELockInfo {
        VELockInfo(deviceName: UIDevice.current.name,
                   deviceID: UIDevice.current.identifierForVendor?.uuidString ?? "unknown",
                   heartbeat: Date())
    }
}

// MARK: - Document

/// The open project: owns the in-memory `VEProject`, routes every edit through the undo stack,
/// autosaves (PRJ-2), holds the lock heartbeat and recovers from a corrupt save (PRJ-3). UI code
/// mutates the project only through `perform` / transactions so nothing escapes undo or autosave.
@MainActor @Observable final class VEDocument {
    let store: VEDriveStore
    let packageURL: URL
    private(set) var project: VEProject
    private(set) var readOnly: Bool
    private(set) var readOnlyReason: String?
    private(set) var isDirty = false
    private(set) var lastSavedAt: Date?
    private(set) var recoveredFromBackup = false
    /// Non-blocking banner text when a save fails for a reason other than drive loss.
    var saveError: String?
    /// Bumped on every change so observers that cache derived layout can refresh cheaply.
    private(set) var revision = 0

    let undoStack = VEUndoStack()
    var canUndo: Bool { undoStack.canUndo }
    var canRedo: Bool { undoStack.canRedo }

    /// Reported drive-loss errors go here (the editor wires it to its `VEDriveMonitor`).
    @ObservationIgnored var onIOError: ((Error) -> Void)?

    @ObservationIgnored private var txnBefore: VEEditableState?
    @ObservationIgnored private var txnLabel = ""
    @ObservationIgnored private var autosaveTask: Task<Void, Never>?
    @ObservationIgnored private var firstDirtyAt: Date?
    @ObservationIgnored private var heartbeatTask: Task<Void, Never>?
    @ObservationIgnored private var closed = false

    private init(store: VEDriveStore, packageURL: URL, project: VEProject, readOnly: Bool, reason: String?, recovered: Bool) {
        self.store = store
        self.packageURL = packageURL
        self.project = project
        self.readOnly = readOnly
        self.readOnlyReason = reason
        self.recoveredFromBackup = recovered
        let docURL = VEDriveLayout.document(packageURL)
        lastSavedAt = (try? docURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    // MARK: Opening

    /// Parse `project.json`; fall back to `project.json.bak`; otherwise throw `.documentCorrupt`
    /// so the UI can offer "Rebuild from media".
    static func open(packageURL: URL, store: VEDriveStore) async throws -> VEDocument {
        let docURL = VEDriveLayout.document(packageURL)
        let bakURL = VEDriveLayout.documentBackup(packageURL)
        let loaded: (VEProject, Bool) = try await Task.detached(priority: .userInitiated) { () throws -> (VEProject, Bool) in
            if let p = VEDocument.parseDocument(at: docURL, store: store) { return (p, false) }
            if let p = VEDocument.parseDocument(at: bakURL, store: store) { return (p, true) }
            throw VEError.documentCorrupt(recovered: false)
        }.value
        var project = loaded.0
        var readOnly = store.isReadOnly
        var reason: String? = readOnly ? VEError.readOnlyVolume.message : nil
        if project.schemaVersion > VEProject.currentSchema {
            readOnly = true
            reason = "This project was saved by a newer version of the app, so it opens read-only."
        }
        // Lock check (PRJ-3).
        let mine = VELockInfo.current()
        if let data = try? store.readData(VEDriveLayout.lock(packageURL)),
           let other = try? VEJSON.decoder.decode(VELockInfo.self, from: data),
           other.deviceID != mine.deviceID, Date().timeIntervalSince(other.heartbeat) < VELockInfo.staleAfter {
            readOnly = true
            reason = "“\(other.deviceName)” has this project open, so it opened read-only here."
        }
        // Migrations would run here, ordered by schemaVersion; v1 has none.
        project.schemaVersion = max(project.schemaVersion, 1)
        let doc = VEDocument(store: store, packageURL: packageURL, project: project, readOnly: readOnly, reason: reason, recovered: loaded.1)
        try? store.ensurePackageLayout(packageURL)
        doc.startHeartbeat()
        if loaded.1 && !readOnly { doc.markDirty() }   // persist the restored backup as the live document
        return doc
    }

    /// Read and decode one document file; nil when unreadable or malformed.
    nonisolated static func parseDocument(at url: URL, store: VEDriveStore) -> VEProject? {
        guard let data = try? store.readData(url) else { return nil }
        return try? VEJSON.decoder.decode(VEProject.self, from: data)
    }

    /// Create a fresh package in `Projects/` and open it.
    static func create(name: String, settings: VEProjectSettings, store: VEDriveStore) async throws -> VEDocument {
        let projects = VEDriveLayout.projects(store.editorRoot)
        let pkgURL: URL = try await Task.detached(priority: .userInitiated) {
            try store.ensureLayout()
            let folder = VENames.unique(VENames.sanitize(name), ext: VEDriveLayout.packageExtension, in: projects)
            let pkg = projects.appendingPathComponent(folder, isDirectory: true)
            try store.ensurePackageLayout(pkg)
            var p = VEProject(name: name)
            p.settings = settings
            let data = try VEJSON.encoder.encode(p)
            try store.saveDocument(data, to: VEDriveLayout.document(pkg), backupName: "project.json.bak")
            return pkg
        }.value
        return try await open(packageURL: pkgURL, store: store)
    }

    /// PRJ-3 "Rebuild from media": a fresh document holding the package's `media/` and `audio/`
    /// files on the main track in file-date order.
    static func rebuild(packageURL: URL, store: VEDriveStore) async throws -> VEDocument {
        let name = packageURL.deletingPathExtension().lastPathComponent
        var project = VEProject(name: name)
        let files = await Task.detached(priority: .userInitiated) { () -> [URL] in
            let media = store.contents(of: VEDriveLayout.media(packageURL)).filter { !$0.hasDirectoryPath }
            let audio = store.contents(of: VEDriveLayout.audio(packageURL)).filter { !$0.hasDirectoryPath }
            return (media + audio).sorted { VEDocument.modificationDate($0) < VEDocument.modificationDate($1) }
        }.value
        for url in files {
            guard let src = try? await VEMediaService.shared.makeSource(for: url, package: packageURL, store: store) else { continue }
            project.media.append(src)
            switch src.kind {
            case .video, .gif, .image:
                let dur = src.kind == .image ? project.settings.defaultPhotoDuration : src.duration
                project.tracks.main.append(VEClip(mediaId: src.id, kind: src.kind == .image ? .image : (src.kind == .gif ? .gif : .video),
                                                 sourceRange: VERange(start: 0, duration: dur)))
            case .audio:
                if project.tracks.audio.isEmpty { project.tracks.audio.append([]) }
                project.tracks.audio[0].append(VEAudioClip(mediaId: src.id, sourceRange: VERange(start: 0, duration: src.duration), timelineStart: 0))
            }
        }
        project.refreshCanvas()
        let data = try VEJSON.encoder.encode(project)
        try await Task.detached { try store.saveDocument(data, to: VEDriveLayout.document(packageURL), backupName: "project.json.bak") }.value
        return try await open(packageURL: packageURL, store: store)
    }

    nonisolated static func modificationDate(_ u: URL) -> Date {
        (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }

    // MARK: Editing

    /// One undoable edit. No-op mutations (state unchanged) push nothing.
    func perform(_ label: String, _ mutate: (inout VEProject) -> Void) {
        guard !readOnly else { return }
        let before = project.editableState
        var p = project
        mutate(&p)
        p.refreshCanvas()
        let after = p.editableState
        guard after != before else { return }
        p.modifiedAt = Date()
        project = p
        undoStack.push(VEEditCommand(label: label, before: before, after: after))
        changed()
    }

    /// Transactions coalesce a continuous gesture into one undo entry (PRJ-4): `begin` once,
    /// `update` on every tick (no stack entry), then `commit` or `cancel` (restores the start state).
    func beginTransaction(_ label: String) {
        guard !readOnly, txnBefore == nil else { return }
        txnBefore = project.editableState
        txnLabel = label
    }
    var inTransaction: Bool { txnBefore != nil }

    func updateTransaction(_ mutate: (inout VEProject) -> Void) {
        guard !readOnly else { return }
        var p = project
        mutate(&p)
        p.refreshCanvas()
        guard p.editableState != project.editableState else { return }
        project = p
        revision &+= 1
    }

    func commitTransaction() {
        guard let before = txnBefore else { return }
        txnBefore = nil
        let after = project.editableState
        guard after != before else { return }
        project.modifiedAt = Date()
        undoStack.push(VEEditCommand(label: txnLabel, before: before, after: after))
        changed()
    }

    func cancelTransaction() {
        guard let before = txnBefore else { return }
        txnBefore = nil
        if project.editableState != before {
            project.editableState = before
            revision &+= 1
        }
    }

    func undo() {
        guard !readOnly, txnBefore == nil, let c = undoStack.popUndo() else { return }
        project.editableState = c.before
        project.modifiedAt = Date()
        changed()
    }

    func redo() {
        guard !readOnly, txnBefore == nil, let c = undoStack.popRedo() else { return }
        project.editableState = c.after
        project.modifiedAt = Date()
        changed()
    }

    /// Non-undoable bookkeeping (derived-asset paths, identity refresh after a relink).
    func updateMedia(_ mutate: (inout [VEMediaSource]) -> Void) {
        var m = project.media
        mutate(&m)
        guard m != project.media else { return }
        project.media = m
        markDirty()
        revision &+= 1
    }

    private func changed() {
        revision &+= 1
        markDirty()
    }

    // MARK: Autosave (PRJ-2: 500 ms debounce, 2 s ceiling)

    private func markDirty() {
        guard !readOnly else { return }
        isDirty = true
        if firstDirtyAt == nil { firstDirtyAt = Date() }
        autosaveTask?.cancel()
        let elapsed = Date().timeIntervalSince(firstDirtyAt ?? Date())
        let delay = max(0, min(0.5, 2.0 - elapsed))
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if Task.isCancelled { return }
            await self?.saveNow()
        }
    }

    /// Atomic save (STO-5). Drive loss is reported through `onIOError`; any other failure shows a
    /// banner and the next edit retries.
    func saveNow() async {
        guard !readOnly else { return }
        autosaveTask?.cancel(); autosaveTask = nil
        firstDirtyAt = nil
        let snapshot = project
        let store = self.store
        let docURL = VEDriveLayout.document(packageURL)
        do {
            let data = try VEJSON.encoder.encode(snapshot)
            try await Task.detached(priority: .utility) {
                try store.saveDocument(data, to: docURL, backupName: "project.json.bak")
            }.value
            isDirty = project != snapshot      // edits that landed during the write keep it dirty
            lastSavedAt = Date()
            saveError = nil
            VELog.file("saved \(packageURL.lastPathComponent)")
            if isDirty { markDirty() }
        } catch {
            if VEDriveStore.isDriveLoss(error) || !store.isReachable() {
                onIOError?(error)
            } else {
                saveError = "Couldn't save the project. It will retry on your next edit."
                VELog.store.error("save failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Lock heartbeat

    private func startHeartbeat() {
        guard !readOnly else { return }
        writeLock()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
                if Task.isCancelled { break }
                self?.writeLock()
            }
        }
    }

    private func writeLock() {
        let info = VELockInfo.current()
        let url = VEDriveLayout.lock(packageURL)
        let store = self.store
        Task.detached(priority: .utility) {
            if let data = try? VEJSON.encoder.encode(info) { try? store.writeData(data, to: url) }
        }
    }

    /// Save, drop the lock, stop timers. Safe to call twice.
    func close() async {
        guard !closed else { return }
        closed = true
        heartbeatTask?.cancel(); heartbeatTask = nil
        if isDirty { await saveNow() }
        let lock = VEDriveLayout.lock(packageURL)
        let store = self.store
        let mine = VELockInfo.current().deviceID
        await Task.detached(priority: .utility) {
            if let data = try? store.readData(lock), let info = try? VEJSON.decoder.decode(VELockInfo.self, from: data), info.deviceID == mine {
                try? store.coordinatedRemove(lock)
            }
        }.value
    }

    // MARK: Convenience

    func resolve(_ source: VEMediaSource) -> URL { store.resolve(source.path, package: packageURL) }
    func url(for clip: VEClip) -> URL? { project.source(clip.mediaId).map(resolve) }
}

// MARK: - Projects catalog

/// Row data for the Projects screen (PRJ-6), read from each package's `project.json`.
nonisolated struct VEProjectSummary: Identifiable, Sendable, Equatable {
    var packageURL: URL
    var name: String
    var projectID: UUID?
    var duration: VETime
    var ratio: VERatio
    var canvas: VECanvas?
    var modifiedAt: Date
    var lastSavedAt: Date?
    var clipCount: Int
    var unreadable: Bool
    var id: String { packageURL.path }
    var coverURL: URL { VEDriveLayout.cover(packageURL) }
}

nonisolated struct VEProjectSizes: Sendable, Equatable {
    var media: Int64 = 0
    var caches: Int64 = 0
    var exports: Int64 = 0
    var total: Int64 { media + caches + exports }
}

/// Package-level operations on `VideoEditor/Projects/` (PRJ-6). All blocking; call off-main.
nonisolated enum VEProjectCatalog {
    static func list(store: VEDriveStore) -> [VEProjectSummary] {
        let projects = VEDriveLayout.projects(store.editorRoot)
        let packages = store.contents(of: projects).filter { $0.pathExtension.lowercased() == VEDriveLayout.packageExtension }
        return packages.map { summary(of: $0, store: store) }
    }

    static func summary(of pkg: URL, store: VEDriveStore) -> VEProjectSummary {
        let docURL = VEDriveLayout.document(pkg)
        let saved = (try? docURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let fallbackName = pkg.deletingPathExtension().lastPathComponent
        func decode(_ url: URL) -> VEProject? {
            guard let data = try? store.readData(url) else { return nil }
            return try? VEJSON.decoder.decode(VEProject.self, from: data)
        }
        guard let p = decode(docURL) ?? decode(VEDriveLayout.documentBackup(pkg)) else {
            return VEProjectSummary(packageURL: pkg, name: fallbackName, projectID: nil, duration: 0, ratio: .r9x16, canvas: nil,
                                    modifiedAt: saved ?? .distantPast, lastSavedAt: saved, clipCount: 0, unreadable: true)
        }
        return VEProjectSummary(packageURL: pkg, name: p.name, projectID: p.id, duration: p.duration, ratio: p.settings.canvas.ratio,
                                canvas: p.settings.canvas, modifiedAt: p.modifiedAt, lastSavedAt: saved,
                                clipCount: p.tracks.main.count, unreadable: false)
    }

    /// Rename: edit `name` in the document and move the package folder in one coordinated step.
    /// References inside the package are package-relative, so nothing else changes.
    static func rename(_ pkg: URL, to newName: String, store: VEDriveStore) throws -> URL {
        let docURL = VEDriveLayout.document(pkg)
        let data = try store.readData(docURL)
        var p = try VEJSON.decoder.decode(VEProject.self, from: data)
        p.name = newName
        p.modifiedAt = Date()
        try store.saveDocument(try VEJSON.encoder.encode(p), to: docURL, backupName: "project.json.bak")
        let projects = pkg.deletingLastPathComponent()
        let folder = VENames.unique(VENames.sanitize(newName), ext: VEDriveLayout.packageExtension, in: projects)
        let dst = projects.appendingPathComponent(folder, isDirectory: true)
        if dst.lastPathComponent.lowercased() == pkg.lastPathComponent.lowercased() { return pkg }
        try store.coordinatedMove(from: pkg, to: dst)
        return dst
    }

    /// Duplicate: `project.json`, `media/`, `audio/` and `cover.jpg`; caches rebuild lazily.
    static func duplicate(_ pkg: URL, store: VEDriveStore) throws -> URL {
        let data = try store.readData(VEDriveLayout.document(pkg))
        var p = try VEJSON.decoder.decode(VEProject.self, from: data)
        p.id = UUID()
        p.name = p.name + " copy"
        p.createdAt = Date(); p.modifiedAt = p.createdAt
        let projects = pkg.deletingLastPathComponent()
        let folder = VENames.unique(VENames.sanitize(p.name), ext: VEDriveLayout.packageExtension, in: projects)
        let dst = projects.appendingPathComponent(folder, isDirectory: true)
        try store.ensurePackageLayout(dst)
        let fm = FileManager.default
        for sub in ["media", "audio"] {
            let s = pkg.appendingPathComponent(sub, isDirectory: true)
            let d = dst.appendingPathComponent(sub, isDirectory: true)
            try? fm.removeItem(at: d)
            if fm.fileExists(atPath: s.path) { try store.coordinatedCopy(from: s, to: d) }
        }
        let cover = VEDriveLayout.cover(pkg)
        if fm.fileExists(atPath: cover.path) { try? store.coordinatedCopy(from: cover, to: VEDriveLayout.cover(dst)) }
        // Derived caches aren't copied; drop their references so they rebuild.
        for i in p.media.indices { p.media[i].derived = VEDerived() }
        try store.saveDocument(try VEJSON.encoder.encode(p), to: VEDriveLayout.document(dst), backupName: "project.json.bak")
        try store.ensurePackageLayout(dst)
        return dst
    }

    static func delete(_ pkg: URL, store: VEDriveStore) throws {
        try store.coordinatedRemove(pkg)
    }

    /// Size split for the Projects screen (STO-7): media (incl. audio and derived), caches, exports
    /// whose file name starts with the project's name.
    static func sizes(of pkg: URL, projectName: String, store: VEDriveStore) -> VEProjectSizes {
        var s = VEProjectSizes()
        s.media = store.directorySize(VEDriveLayout.media(pkg)) + store.directorySize(VEDriveLayout.audio(pkg))
        s.caches = VEDriveLayout.cacheFolders(pkg).reduce(0) { $0 + store.directorySize($1) }
        let prefix = VENames.sanitize(projectName).lowercased()
        for f in store.contents(of: VEDriveLayout.exports(store.editorRoot)) where f.lastPathComponent.lowercased().hasPrefix(prefix) {
            s.exports += store.fileSize(f)
        }
        return s
    }

    static func clearCaches(_ pkg: URL, store: VEDriveStore) {
        for d in VEDriveLayout.cacheFolders(pkg) {
            try? store.coordinatedRemove(d)
            try? DriveWriter.createDirectory(at: d)
        }
        // Forget derived paths so the editor regenerates instead of pointing at deleted files.
        let docURL = VEDriveLayout.document(pkg)
        if let data = try? store.readData(docURL), var p = try? VEJSON.decoder.decode(VEProject.self, from: data) {
            for i in p.media.indices {
                p.media[i].derived.proxy = nil; p.media[i].derived.thumbs = nil; p.media[i].derived.waveform = nil
            }
            if let out = try? VEJSON.encoder.encode(p) { try? store.saveDocument(out, to: docURL, backupName: "project.json.bak") }
        }
    }

    static func clearAllCaches(store: VEDriveStore) {
        for s in list(store: store) { clearCaches(s.packageURL, store: store) }
    }
}
