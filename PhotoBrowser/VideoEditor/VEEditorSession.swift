import SwiftUI
import UIKit
import AVFoundation

/// Everything the editor screen needs for one open project: the document, the preview player, the
/// thumbnail store, drive monitoring, derived-asset scheduling and every edit command (TL-3 to
/// TL-11). Views call these methods; nothing here touches the document except through `VEDocument`.
@MainActor @Observable final class VEEditorSession: VETimelineDelegate {
    let store: VEDriveStore
    let document: VEDocument
    let monitor: VEDriveMonitor
    let playback = VEPlayback()
    let thumbs: VEThumbStore
    var settings: VEEditorSettings

    var selectedClipID: String?
    var useProxies: Bool
    var driveLost = false
    var toast: String?
    var error: VEError?
    var importProgress: (fraction: Double, name: String)?
    var importSkipped: [VEMediaService.ImportSkip] = []
    var relinkSearching = false

    private var derivedJobs: [(key: String, run: () async -> Void)] = []
    private var derivedRunning: Set<String> = []
    private var derivedActive = 0
    private var coverDirty = false
    private var rebuildTask: Task<Void, Never>?
    private var trimOriginal: VEClip?
    private var transformOriginal: VETransform?
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var closed = false

    var project: VEProject { document.project }
    var selectedClip: VEClip? { selectedClipID.flatMap { document.project.mainClip($0) } }
    var selectedIndex: Int? { selectedClipID.flatMap { document.project.mainIndex(of: $0) } }

    init(document: VEDocument, store: VEDriveStore, settings: VEEditorSettings) {
        self.document = document
        self.store = store
        self.settings = settings
        self.monitor = VEDriveMonitor(store: store)
        self.thumbs = VEThumbStore(package: document.packageURL, store: store)
        self.useProxies = settings.proxyPlayback == .always
        VELog.diagnosticsRoot = settings.diagnostics ? store.editorRoot : nil
    }

    // MARK: Lifecycle

    private var started = false

    func start() {
        guard !started else { return }
        started = true
        document.onIOError = { [weak self] e in self?.monitor.report(e) }
        monitor.onLost = { [weak self] in
            guard let self else { return }
            self.playback.pause()
            self.driveLost = true
        }
        monitor.onRestored = { [weak self] in
            guard let self else { return }
            self.driveLost = false
            Task { await self.document.saveNow() }
        }
        monitor.start()
        playback.onStall = { [weak self] in
            guard let self, self.settings.proxyPlayback != .never else { return }
            self.useProxies = true
            self.toast = "Playback is struggling from this drive — switching the preview to proxies."
            self.scheduleProxiesIfNeeded(force: true)
            self.rebuildPreview()
        }
        thumbs.onChanged = { [weak self] in self?.thumbsRevision &+= 1 }
        let nc = NotificationCenter.default
        lifecycleObservers.append(nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.document.saveNow() }
        })
        lifecycleObservers.append(nc.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.document.saveNow() }
        })
        lifecycleObservers.append(nc.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.thumbs.flush(); VEImageCache.shared.removeAll() }
        })
        if document.recoveredFromBackup { toast = "The last save couldn't be read, so the previous good save was restored." }
        if let reason = document.readOnlyReason { toast = reason }
        validateReferences()
        scheduleDerivedAssets()
        rebuildPreview()
    }

    /// Save, cover, locks, player — then the editor can go away.
    func close() async {
        guard !closed else { return }
        closed = true
        playback.shutdown()
        monitor.stop()
        lifecycleObservers.forEach { NotificationCenter.default.removeObserver($0) }
        lifecycleObservers.removeAll()
        if coverDirty || !FileManager.default.fileExists(atPath: VEDriveLayout.cover(document.packageURL).path) { await regenerateCover() }
        await document.close()
        store.saveSettings(settings)
    }

    /// Bumped whenever a thumbnail strip lands so the timeline redraws.
    private(set) var thumbsRevision = 0

    // MARK: Preview

    func rebuildPreview() {
        rebuildTask?.cancel()
        let delay: UInt64 = document.inTransaction ? 120_000_000 : 0
        rebuildTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            guard !Task.isCancelled, let self else { return }
            self.playback.rebuild(document: self.document, useProxies: self.previewUsesProxies)
        }
    }

    private var previewUsesProxies: Bool {
        switch settings.proxyPlayback {
        case .never: return false
        case .always: return true
        case .auto: return useProxies
        }
    }

    var timelineModel: VETimelineModel {
        let p = document.project
        let starts = p.mainStarts()
        let missing = Set(playback.missingClipIDs)
        let clips = p.tracks.main.enumerated().map { i, c -> VETimelineClipModel in
            let src = p.source(c.mediaId)
            let size = src?.displaySize ?? VESize(width: 16, height: 9)
            let aspect = CGFloat(max(0.3, min(3, Double(size.width) / Double(max(1, size.height)) * (c.crop.rect.w / max(0.01, c.crop.rect.h)))))
            return VETimelineClipModel(id: c.id, mediaID: c.mediaId, kind: c.kind, start: starts[i], duration: c.timelineDuration,
                                       sourceStart: c.sourceRange.start, sourceDuration: c.hasSpeed ? (src?.duration ?? 0) : 0,
                                       rate: c.rate, reversed: c.reversed, muted: c.audioMuted || p.settings.muteOriginalAudio,
                                       hasAudio: (src?.hasAudio ?? false) && !c.audioExtracted, name: src?.displayName ?? "Missing",
                                       aspect: aspect, missing: missing.contains(c.id) || src == nil)
        }
        return VETimelineModel(clips: clips, duration: p.duration, frameRate: p.settings.frameRate, selectedID: selectedClipID,
                               snapping: settings.snapping, haptics: settings.haptics)
    }

    // MARK: Edits

    private func edit(_ label: String, _ mutate: (inout VEProject) -> Void) {
        document.perform(label, mutate)
        coverDirty = true
        rebuildPreview()
    }

    var canSplit: Bool {
        guard let hit = project.mainClip(at: playback.currentTime) else { return false }
        let f = VETimeUtil.frame(project.settings.frameRate)
        let off = playback.currentTime - hit.start
        return off >= f && off <= hit.clip.timelineDuration - f
    }

    /// TL-3: cut the clip under the playhead; both halves keep every attribute.
    func split() {
        let t = playback.currentTime
        guard let hit = project.mainClip(at: t), canSplit else { return }
        let offset = t - hit.start
        edit("Split") { p in
            var left = hit.clip
            var right = hit.clip
            right.id = VEIDs.new()
            if left.hasSpeed {
                let srcOffset = VETime((Double(offset) * left.rate).rounded())
                left.sourceRange.duration = srcOffset
                right.sourceRange.start += srcOffset
                right.sourceRange.duration = max(1, hit.clip.sourceRange.duration - srcOffset)
                // Keyframes stay with the half that contains their source time (one at the cut is duplicated).
                let cut = right.sourceRange.start
                left.keyframes = hit.clip.keyframes.filter { Self.keyframeTime($0).map { $0 <= cut } ?? true }
                right.keyframes = hit.clip.keyframes.filter { Self.keyframeTime($0).map { $0 >= cut } ?? true }
            } else {
                left.sourceRange.duration = offset
                right.sourceRange.duration = max(1, hit.clip.sourceRange.duration - offset)
            }
            p.tracks.main[hit.index] = left
            p.tracks.main.insert(right, at: hit.index + 1)
            // The transition that followed the clip stays with the right half; the new cut has none.
            for i in p.transitions.indices where p.transitions[i].afterMainClip == hit.clip.id { p.transitions[i].afterMainClip = right.id }
        }
        selectedClipID = hit.clip.id
    }

    private static func keyframeTime(_ v: JSONValue) -> VETime? {
        if case .object(let o) = v, case .number(let n)? = o["sourceTime"] { return VETime(n) }
        return nil
    }

    /// TL-5: remove; the gap closes and transitions on either side go with it.
    func deleteSelected() {
        guard let id = selectedClipID, let idx = project.mainIndex(of: id) else { return }
        edit("Delete") { p in
            let prev = idx > 0 ? p.tracks.main[idx - 1].id : nil
            p.tracks.main.remove(at: idx)
            p.transitions.removeAll { $0.afterMainClip == id || $0.afterMainClip == prev }
        }
        selectedClipID = nil
    }

    /// TL-6: identical clip right after the original.
    func duplicateSelected() {
        guard let c = selectedClip, let idx = selectedIndex else { return }
        var copy = c
        copy.id = VEIDs.new()
        edit("Copy") { p in p.tracks.main.insert(copy, at: idx + 1) }
        selectedClipID = copy.id
    }

    func setSpeed(_ rate: Double, keepPitch: Bool, commit: Bool) {
        applyToSelected("Speed", commit: commit) { c in
            c.speed.mode = "constant"; c.speed.rate = max(0.1, min(100, rate)); c.speed.keepPitch = keepPitch
        }
    }

    func setVolume(_ volume: Double, commit: Bool) {
        applyToSelected("Volume", commit: commit) { c in c.volume = max(0, min(10, volume)) }
    }

    func toggleMuteSelected() {
        guard let c = selectedClip else { return }
        let m = !c.audioMuted
        applyToSelected(m ? "Mute" : "Unmute", commit: true) { $0.audioMuted = m }
    }

    func setOpacity(_ opacity: Double, commit: Bool) {
        applyToSelected("Opacity", commit: commit) { c in c.opacity = max(0, min(1, opacity)) }
    }

    /// Photo clips: timeline duration (0.5–30 s) — the main track ripples (TL-2 Duration).
    func setStillDuration(_ seconds: Double, commit: Bool) {
        applyToSelected("Duration", commit: commit) { c in
            guard !c.hasSpeed else { return }
            c.sourceRange.duration = VETimeUtil.fromSeconds(max(0.5, min(30, seconds)))
        }
    }

    func rotateSelected90() {
        applyToSelected("Rotate", commit: true) { c in c.transform.rotation = (c.transform.rotation + 90).truncatingRemainder(dividingBy: 360) }
    }

    func mirrorSelected() {
        applyToSelected("Mirror", commit: true) { c in c.transform.flipH.toggle() }
    }

    func setCrop(_ crop: VECrop) {
        applyToSelected("Crop", commit: true) { c in c.crop = crop }
    }

    func resetTransformSelected() {
        applyToSelected("Reset", commit: true) { c in c.transform = VETransform() }
    }

    /// TL-9 Fit / Fill.
    func fitSelected(fill: Bool) {
        guard let c = selectedClip, let src = project.source(c.mediaId) else { return }
        let cr = VELayerMath.cropRect(sourceSize: src.displaySize.cgSize, crop: c.crop)
        let canvas = project.settings.canvas.size
        let fit = min(canvas.width / cr.width, canvas.height / cr.height)
        let cover = max(canvas.width / cr.width, canvas.height / cr.height)
        applyToSelected(fill ? "Fill" : "Fit", commit: true) { c in
            c.transform.scale = fill ? Double(cover / fit) : 1
            c.transform.x = 0; c.transform.y = 0
        }
    }

    /// Canvas gestures (TL-9): one undo step per gesture.
    func canvasTransform(_ t: VETransform, phase: VEGesturePhase) {
        guard let id = selectedClipID else { return }
        switch phase {
        case .began:
            document.beginTransaction("Move")
        case .changed:
            document.updateTransaction { p in
                if let i = p.mainIndex(of: id) { p.tracks.main[i].transform = t }
            }
            rebuildPreview()
        case .ended:
            document.updateTransaction { p in
                if let i = p.mainIndex(of: id) { p.tracks.main[i].transform = t }
            }
            document.commitTransaction()
            coverDirty = true
            rebuildPreview()
        }
    }

    /// Tool-sheet edits: `commit == false` updates a live transaction (one undo step on confirm).
    private func applyToSelected(_ label: String, commit: Bool, _ mutate: (inout VEClip) -> Void) {
        guard let id = selectedClipID else { return }
        if commit {
            if document.inTransaction {
                document.updateTransaction { p in if let i = p.mainIndex(of: id) { mutate(&p.tracks.main[i]) } }
                document.commitTransaction()
                coverDirty = true
                rebuildPreview()
            } else {
                edit(label) { p in if let i = p.mainIndex(of: id) { mutate(&p.tracks.main[i]) } }
            }
        } else {
            if !document.inTransaction { document.beginTransaction(label) }
            document.updateTransaction { p in if let i = p.mainIndex(of: id) { mutate(&p.tracks.main[i]) } }
            rebuildPreview()
        }
    }

    /// Tool sheets: X restores the pre-sheet state in one step (TL-2).
    func beginTool(_ label: String) { document.beginTransaction(label) }
    func confirmTool() { document.commitTransaction(); coverDirty = true; rebuildPreview() }
    func cancelTool() { document.cancelTransaction(); rebuildPreview() }

    func setRatio(_ ratio: VERatio) {
        edit("Ratio") { p in
            p.settings.canvas.ratio = ratio
            p.refreshCanvas()
        }
    }

    func setProjectSettings(frameRate: Int, resolution: VEResolution, photoDuration: VETime, freeze: VETime, layer: VETime, proxy: VEProxyMode) {
        edit("Project settings") { p in
            p.settings.frameRate = frameRate
            p.settings.resolution = resolution
            p.settings.defaultPhotoDuration = photoDuration
            p.settings.defaultFreezeDuration = freeze
            p.settings.defaultLayerDuration = layer
            p.settings.proxyPlayback = proxy
            p.refreshCanvas()
        }
        settings.proxyPlayback = proxy
        store.saveSettings(settings)
    }

    func toggleMuteOriginalAudio() {
        edit(project.settings.muteOriginalAudio ? "Unmute original audio" : "Mute original audio") { p in p.settings.muteOriginalAudio.toggle() }
    }

    func rename(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        edit("Rename") { p in p.name = n }
    }

    func undo() { document.undo(); coverDirty = true; rebuildPreview(); ensureSelectionValid() }
    func redo() { document.redo(); coverDirty = true; rebuildPreview(); ensureSelectionValid() }
    private func ensureSelectionValid() {
        if let id = selectedClipID, project.mainIndex(of: id) == nil { selectedClipID = nil }
    }

    // MARK: Timeline delegate

    func timelineDidScrub(to time: VETime, final: Bool) {
        playback.seek(to: time, scrubbing: !final)
        if final { playback.endScrub() }
    }

    func timelineDidSelect(_ clipID: String?) {
        selectedClipID = clipID
        if settings.haptics { Haptics.light() }
    }

    func timelineTrim(_ clipID: String, side: VETrimSide, delta: VETime, phase: VEGesturePhase) {
        switch phase {
        case .began:
            trimOriginal = project.mainClip(clipID)
            document.beginTransaction("Trim")
        case .changed, .ended:
            guard let o = trimOriginal else { return }
            let frame = VETimeUtil.frame(project.settings.frameRate)
            var c = o
            if side == .left {
                if c.hasSpeed {
                    let d = VETime((Double(delta) * c.rate).rounded())
                    c.sourceRange.start = max(0, o.sourceRange.start + d)
                    c.sourceRange.duration = max(frame, o.sourceRange.duration - (c.sourceRange.start - o.sourceRange.start))
                } else {
                    c.sourceRange.duration = max(frame, o.sourceRange.duration - delta)
                }
            } else {
                if c.hasSpeed {
                    let d = VETime((Double(delta) * c.rate).rounded())
                    c.sourceRange.duration = max(frame, o.sourceRange.duration + d)
                } else {
                    c.sourceRange.duration = max(frame, o.sourceRange.duration + delta)
                }
            }
            let newClip = c
            document.updateTransaction { p in if let i = p.mainIndex(of: clipID) { p.tracks.main[i] = newClip } }
            if phase == .ended {
                // Transitions adjacent to a clip that got too short are shortened or dropped (TL-4).
                document.updateTransaction { p in Self.conformTransitions(&p) }
                document.commitTransaction()
                trimOriginal = nil
                coverDirty = true
            }
            rebuildPreview()
        }
    }

    static func conformTransitions(_ p: inout VEProject) {
        p.transitions = p.transitions.compactMap { t in
            guard let i = p.mainIndex(of: t.afterMainClip), i + 1 < p.tracks.main.count else { return nil }
            let shorter = min(p.tracks.main[i].timelineDuration, p.tracks.main[i + 1].timelineDuration)
            if shorter < VETimeUtil.fromSeconds(0.2) { return nil }
            var t2 = t
            t2.duration = min(t.duration, shorter / 2)
            return t2
        }
    }

    func timelineReorder(from: Int, to: Int) {
        guard from != to, from < project.tracks.main.count else { return }
        edit("Reorder") { p in
            let c = p.tracks.main.remove(at: from)
            let dest = min(to, p.tracks.main.count)
            p.tracks.main.insert(c, at: dest)
            // Transitions at the boundaries the clip left and the one it entered are removed.
            let touched: Set<String> = [c.id, dest > 0 ? p.tracks.main[dest - 1].id : "", from > 0 ? p.tracks.main[min(from - 1, p.tracks.main.count - 1)].id : ""]
            p.transitions.removeAll { touched.contains($0.afterMainClip) }
        }
    }

    var showImport: VEImportRequest?
    func timelineAdd(atPlayhead: Bool) { showImport = VEImportRequest(insertAtPlayhead: atPlayhead) }
    var showCoverSheet = false
    func timelineCover() { showCoverSheet = true }
    func timelineCut(at index: Int) { toast = "Transitions arrive with the next editor update." }

    // MARK: Import (IMP-5)

    /// Import picked URLs and place them on the main track (end, or the cut nearest the playhead).
    func importURLs(_ urls: [URL], insertAtPlayhead: Bool) {
        guard !urls.isEmpty, !document.readOnly else { return }
        let package = document.packageURL
        let store = self.store
        let existing = project.media
        importProgress = (0, "")
        Task {
            let result = await VEMediaService.shared.importFiles(urls, into: package, existing: existing, store: store) { f, name in
                Task { @MainActor [weak self] in self?.importProgress = (f, name) }
            }
            importProgress = nil
            if result.driveLost { driveLost = true; monitor.report(NSError(domain: NSPOSIXErrorDomain, code: Int(ENODEV))) }
            importSkipped = result.skipped
            appendSources(result.sources, insertAtPlayhead: insertAtPlayhead)
        }
    }

    func appendSources(_ sources: [VEMediaSource], insertAtPlayhead: Bool) {
        guard !sources.isEmpty else { return }
        let photoDuration = project.settings.defaultPhotoDuration
        let playhead = playback.currentTime
        var firstNewID: String?
        edit("Add media") { p in
            var insertIndex = p.tracks.main.count
            if insertAtPlayhead {
                // Nearest cut to the playhead; never splits a clip.
                let cuts = p.mainCuts()
                if let nearest = cuts.enumerated().min(by: { abs($0.element - playhead) < abs($1.element - playhead) }) { insertIndex = nearest.offset }
            }
            for s in sources {
                if p.source(s.id) == nil { p.media.append(s) }
                let clip: VEClip
                switch s.kind {
                case .image:
                    clip = VEClip(mediaId: s.id, kind: .image, sourceRange: VERange(start: 0, duration: photoDuration))
                case .gif:
                    // Natural loop length repeated to reach at least 3 s (IMP-4).
                    var d = max(1, s.duration)
                    while d < photoDuration { d += max(1, s.duration) }
                    clip = VEClip(mediaId: s.id, kind: .gif, sourceRange: VERange(start: 0, duration: d))
                case .video:
                    clip = VEClip(mediaId: s.id, kind: .video, sourceRange: VERange(start: 0, duration: max(1, s.duration)))
                case .audio:
                    if p.tracks.audio.isEmpty { p.tracks.audio.append([]) }
                    let lane = 0
                    let start = p.tracks.audio[lane].map(\.timelineEnd).max() ?? 0
                    p.tracks.audio[lane].append(VEAudioClip(mediaId: s.id, sourceRange: VERange(start: 0, duration: max(1, s.duration)), timelineStart: max(start, playhead)))
                    continue
                }
                if firstNewID == nil { firstNewID = clip.id }
                p.tracks.main.insert(clip, at: min(insertIndex, p.tracks.main.count))
                insertIndex += 1
            }
            p.refreshCanvas()
        }
        if let id = firstNewID { selectedClipID = id }
        scheduleDerivedAssets()
    }

    // MARK: Derived assets (IMP-7: thumbnails first, then waveforms, then proxies)

    func scheduleDerivedAssets() {
        let package = document.packageURL
        let store = self.store
        for s in project.media {
            if s.kind != .audio, s.derived.thumbs == nil {
                enqueue("thumbs:" + s.id) { [weak self] in
                    if let rel = await VEMediaService.shared.generateThumbnails(for: s, package: package, store: store) {
                        await MainActor.run {
                            self?.document.updateMedia { m in if let i = m.firstIndex(where: { $0.id == s.id }) { m[i].derived.thumbs = rel } }
                            self?.thumbs.invalidate(mediaID: s.id)
                        }
                    }
                }
            }
            if (s.hasAudio || s.kind == .audio), s.derived.waveform == nil {
                enqueue("wave:" + s.id) { [weak self] in
                    if let rel = await VEMediaService.shared.generateWaveform(for: s, package: package, store: store) {
                        await MainActor.run {
                            self?.document.updateMedia { m in if let i = m.firstIndex(where: { $0.id == s.id }) { m[i].derived.waveform = rel } }
                            self?.thumbs.invalidate(mediaID: s.id)
                        }
                    }
                }
            }
        }
        scheduleProxiesIfNeeded(force: false)
    }

    func scheduleProxiesIfNeeded(force: Bool) {
        guard settings.proxyPlayback != .never, !ProcessInfo.processInfo.isLowPowerModeEnabled || force else { return }
        let package = document.packageURL
        let store = self.store
        let sample = project.media.first { $0.kind == .video }.map { store.resolve($0.path, package: package) }
        Task.detached(priority: .utility) { [weak self] in
            let mbps = VEMediaService.shared.throughput(sample: sample)
            await MainActor.run {
                guard let self else { return }
                if mbps < 80 && self.settings.proxyPlayback == .auto { self.useProxies = true }
                for s in self.project.media where s.kind == .video && s.derived.proxy == nil
                    && (force || self.settings.proxyPlayback == .always || VEMediaService.shared.needsProxy(s, throughputMBps: mbps)) {
                    self.enqueue("proxy:" + s.id) { [weak self] in
                        if let rel = await VEMediaService.shared.generateProxy(for: s, package: package, store: store) {
                            await MainActor.run {
                                guard let self else { return }
                                self.document.updateMedia { m in if let i = m.firstIndex(where: { $0.id == s.id }) { m[i].derived.proxy = rel } }
                                if self.previewUsesProxies { self.rebuildPreview() }
                            }
                        }
                    }
                }
            }
        }
    }

    private func enqueue(_ key: String, _ run: @escaping () async -> Void) {
        guard !derivedRunning.contains(key), !derivedJobs.contains(where: { $0.key == key }) else { return }
        derivedJobs.append((key, run))
        pumpDerived()
    }

    private func pumpDerived() {
        let limit = ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical ? 1 : 2
        while derivedActive < limit, !derivedJobs.isEmpty, !closed {
            let job = derivedJobs.removeFirst()
            derivedRunning.insert(job.key)
            derivedActive += 1
            Task.detached(priority: .utility) { [weak self] in
                await job.run()
                await MainActor.run {
                    guard let self else { return }
                    self.derivedActive -= 1
                    self.derivedRunning.remove(job.key)
                    self.pumpDerived()
                }
            }
        }
    }

    // MARK: Missing media (STO-10)

    /// Validate every reference; a missing file triggers a background identity search and a silent
    /// relink on a match.
    func validateReferences() {
        let package = document.packageURL
        let store = self.store
        let media = project.media
        let missing = media.filter { !FileManager.default.fileExists(atPath: store.resolve($0.path, package: package).path) }
        guard !missing.isEmpty else { return }
        relinkSearching = true
        Task.detached(priority: .utility) { [weak self] in
            var found: [(String, String)] = []
            for s in missing {
                if let url = VEMediaService.shared.findByIdentity(s.identity, under: store.driveRoot, preferredName: s.originalName),
                   let ref = store.reference(for: url, package: package) {
                    found.append((s.id, ref))
                }
            }
            let relinked = found
            await MainActor.run {
                guard let self else { return }
                self.relinkSearching = false
                if !relinked.isEmpty {
                    self.document.updateMedia { m in
                        for (id, ref) in relinked { if let i = m.firstIndex(where: { $0.id == id }) { m[i].path = ref; m[i].derived = VEDerived() } }
                    }
                    self.toast = "Relinked \(relinked.count) moved file\(relinked.count == 1 ? "" : "s")."
                    self.scheduleDerivedAssets()
                    self.rebuildPreview()
                }
            }
        }
    }

    /// Manual relink from the picker: the chosen file replaces the source's path if its kind matches.
    func relink(sourceID: String, to url: URL) {
        guard let s = project.source(sourceID), let ref = store.reference(for: url, package: document.packageURL) else { return }
        let kind = s.kind
        Task {
            guard let probe = try? await VEMediaService.shared.probe(url), probe.kind == kind || (kind == .image && probe.kind == .gif) else {
                toast = "That file isn't the same kind of media."
                return
            }
            let ident = (try? VEMediaService.shared.identity(of: url)) ?? s.identity
            document.updateMedia { m in
                if let i = m.firstIndex(where: { $0.id == sourceID }) {
                    m[i].path = ref; m[i].identity = ident; m[i].derived = VEDerived()
                    m[i].duration = probe.duration > 0 ? probe.duration : m[i].duration
                    m[i].width = probe.width; m[i].height = probe.height; m[i].transform = probe.transform
                }
            }
            scheduleDerivedAssets()
            rebuildPreview()
        }
    }

    var missingSources: [VEMediaSource] {
        let used = project.usedMediaIDs
        return project.media.filter { used.contains($0.id) && !FileManager.default.fileExists(atPath: store.resolve($0.path, package: document.packageURL).path) }
    }

    // MARK: Cover (PRJ-7)

    func setCoverToPlayhead() {
        let t = playback.currentTime
        edit("Cover") { p in p.cover = VECover(); p.cover.time = t; p.cover.kind = "frame"; p.cover.path = "cover.jpg" }
        Task { await regenerateCover() }
    }

    func regenerateCover() async {
        let p = document.project
        guard p.duration > 0 else { return }
        let package = document.packageURL
        let store = self.store
        let t = min(p.cover.time ?? 0, max(0, p.duration - 1))
        let dest = VEDriveLayout.cover(package)
        await Task.detached(priority: .utility) {
            guard let built = try? await VECompositionBuilder.build(p, package: package, store: store),
                  let img = await VEFrameRenderer.image(of: built, at: t, maxPixel: 1280),
                  let data = img.jpegData(compressionQuality: 0.85) else { return }
            try? store.writeData(data, to: dest)
        }.value
        coverDirty = false
    }
}

struct VEImportRequest: Identifiable {
    var insertAtPlayhead: Bool
    var id: String { insertAtPlayhead ? "playhead" : "end" }
}

// MARK: - Thumbnail store (PRV-9)

/// Filmstrip frames and waveform peaks read from the package caches, with grey placeholders until a
/// strip arrives. Strips load off-main; cropped frames are cached up to 64 MB (NFR-2).
@MainActor final class VEThumbStore: VEThumbProviding {
    var onChanged: (() -> Void)?
    private let package: URL
    private let store: VEDriveStore
    private var indexes: [String: VEMediaService.StripIndex] = [:]
    private var indexCheckedAt: [String: Date] = [:]
    private var loading: Set<String> = []
    private var waveforms: [String: (peaks: [(Float, Float)], intervalMs: Int)] = [:]
    private var waveformMissing: Set<String> = []
    private let strips: NSCache<NSString, UIImage> = { let c = NSCache<NSString, UIImage>(); c.totalCostLimit = 48 * 1024 * 1024; return c }()
    private let frames: NSCache<NSString, UIImage> = { let c = NSCache<NSString, UIImage>(); c.totalCostLimit = 64 * 1024 * 1024; return c }()

    init(package: URL, store: VEDriveStore) { self.package = package; self.store = store }

    private func dir(_ mediaID: String) -> URL { VEDriveLayout.thumbs(package).appendingPathComponent(mediaID, isDirectory: true) }

    func invalidate(mediaID: String) {
        indexes[mediaID] = nil
        indexCheckedAt[mediaID] = nil
        waveforms[mediaID] = nil
        waveformMissing.remove(mediaID)
        onChanged?()
    }

    func flush() {
        strips.removeAllObjects()
        frames.removeAllObjects()
    }

    private func index(for mediaID: String, needFrame: Int) -> VEMediaService.StripIndex? {
        if let i = indexes[mediaID], needFrame < i.count { return i }
        // Re-read at most every 2 s while generation is in progress (index.partial.json grows).
        if let at = indexCheckedAt[mediaID], Date().timeIntervalSince(at) < 2 { return indexes[mediaID] }
        indexCheckedAt[mediaID] = Date()
        let d = dir(mediaID)
        for name in ["index.json", "index.partial.json"] {
            if let data = try? Data(contentsOf: d.appendingPathComponent(name)),
               let idx = try? VEJSON.decoder.decode(VEMediaService.StripIndex.self, from: data) {
                indexes[mediaID] = idx
                return idx
            }
        }
        return indexes[mediaID]
    }

    func frame(mediaID: String, sourceTime: VETime) -> UIImage? {
        let guess = Int(max(0, sourceTime) / max(1, VETimeUtil.second))
        guard let idx = index(for: mediaID, needFrame: guess), idx.count > 0 else { return nil }
        let frameNo = min(idx.count - 1, Int(max(0, sourceTime) / max(1, idx.interval)))
        let frameKey = "\(mediaID)|\(frameNo)" as NSString
        if let f = frames.object(forKey: frameKey) { return f }
        let stripNo = frameNo / idx.framesPerStrip
        let stripKey = "\(mediaID)|s\(stripNo)" as NSString
        guard let strip = strips.object(forKey: stripKey) else {
            requestStrip(mediaID: mediaID, stripNo: stripNo, key: stripKey)
            return nil
        }
        let col = frameNo % idx.framesPerStrip
        let rect = CGRect(x: col * idx.frameWidth, y: 0, width: idx.frameWidth, height: idx.frameHeight)
        guard let cg = strip.cgImage?.cropping(to: rect) else { return nil }
        let img = UIImage(cgImage: cg)
        frames.setObject(img, forKey: frameKey, cost: idx.frameWidth * idx.frameHeight * 4)
        return img
    }

    private func requestStrip(mediaID: String, stripNo: Int, key: NSString) {
        let k = key as String
        guard !loading.contains(k) else { return }
        loading.insert(k)
        let url = dir(mediaID).appendingPathComponent(String(format: "strip_%03d.jpg", stripNo))
        Task.detached(priority: .userInitiated) { [weak self] in
            let img = UIImage(contentsOfFile: url.path)
            await MainActor.run {
                guard let self else { return }
                self.loading.remove(k)
                if let img {
                    self.strips.setObject(img, forKey: key, cost: Int(img.size.width * img.size.height * 4))
                    self.onChanged?()
                }
            }
        }
    }

    func waveform(mediaID: String) -> (peaks: [(Float, Float)], intervalMs: Int)? {
        if let w = waveforms[mediaID] { return w }
        guard !waveformMissing.contains(mediaID) else { return nil }
        let k = "wave|\(mediaID)"
        guard !loading.contains(k) else { return nil }
        loading.insert(k)
        let url = VEDriveLayout.waveforms(package).appendingPathComponent("\(mediaID).pk")
        Task.detached(priority: .utility) { [weak self] in
            let w = VEMediaService.readWaveform(url)
            await MainActor.run {
                guard let self else { return }
                self.loading.remove(k)
                if let w { self.waveforms[mediaID] = w; self.onChanged?() } else { self.waveformMissing.insert(mediaID) }
            }
        }
        return nil
    }
}
