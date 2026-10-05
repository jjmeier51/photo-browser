import Foundation
import AVFoundation
import CoreImage
import UIKit
import Photos
import UserNotifications
import VideoToolbox

// MARK: - Settings

nonisolated enum VEExportQuality: String, CaseIterable, Sendable {
    case lower, recommended, higher, custom
    var label: String {
        switch self {
        case .lower: return "Lower"
        case .recommended: return "Recommended"
        case .higher: return "Higher"
        case .custom: return "Custom"
        }
    }
}

nonisolated enum VEExportCodec: String, CaseIterable, Sendable {
    case h264, hevc
    var label: String { self == .h264 ? "H.264" : "HEVC" }
}

nonisolated struct VEExportSettings: Sendable, Equatable {
    var resolution: VEResolution
    var frameRate: Int
    var quality: VEExportQuality
    var customMbps: Double
    var codec: VEExportCodec
    var fileName: String
    var saveToPhotos: Bool

    /// EXP-3 Recommended table (Mb/s): [resolution: (30 fps, 60 fps)].
    static func recommendedMbps(resolution: VEResolution, frameRate: Int, codec: VEExportCodec) -> Double {
        let h264: [VEResolution: (Double, Double)] = [.p480: (2.5, 3.75), .p720: (6, 9), .p1080: (12, 18), .p1440: (24, 36), .p2160: (45, 70)]
        let hevc: [VEResolution: (Double, Double)] = [.p480: (1.8, 2.7), .p720: (4, 6), .p1080: (8, 12), .p1440: (16, 24), .p2160: (30, 45)]
        let row = (codec == .h264 ? h264 : hevc)[resolution] ?? (12, 18)
        // Nearest row scaled by frame rate.
        if frameRate <= 30 { return row.0 * Double(frameRate) / 30 }
        return row.1 * Double(frameRate) / 60
    }

    var videoBitrateBps: Int {
        let rec = Self.recommendedMbps(resolution: resolution, frameRate: frameRate, codec: codec)
        let mbps: Double
        switch quality {
        case .lower: mbps = rec * 0.6
        case .recommended: mbps = rec
        case .higher: mbps = rec * 1.6
        case .custom: mbps = max(1, min(120, customMbps))
        }
        return Int((mbps * 1_000_000).rounded())
    }

    var audioBitrateBps: Int {
        switch quality {
        case .lower: return 192_000
        case .higher, .custom: return 320_000
        case .recommended: return 256_000
        }
    }

    /// Estimated output size: bitrate × duration plus 3 % container overhead (EXP-1).
    func estimatedBytes(duration: VETime) -> Int64 {
        let secs = VETimeUtil.seconds(duration)
        return Int64(Double(videoBitrateBps + audioBitrateBps) / 8 * secs * 1.03)
    }

    static func codecDefault(for resolution: VEResolution) -> VEExportCodec {
        resolution == .p1440 || resolution == .p2160 ? .hevc : .h264
    }
}

// MARK: - Pre-flight (EXP-2)

nonisolated struct VEPreflightReport: Sendable, Equatable {
    var blockers: [VEError] = []
    var warnings: [String] = []
    var estimatedBytes: Int64 = 0
    var freeBytes: Int64?
    var ok: Bool { blockers.isEmpty }
}

nonisolated enum VEExportPreflight {
    static func check(project: VEProject, settings: VEExportSettings, store: VEDriveStore, package: URL) -> VEPreflightReport {
        var r = VEPreflightReport()
        let dur = project.duration
        r.estimatedBytes = settings.estimatedBytes(duration: dur)
        if !store.isReachable() { r.blockers.append(.driveUnavailable); return r }
        if store.isReadOnly { r.blockers.append(.readOnlyVolume) }
        if dur <= 0 { r.warnings.append("The project is empty.") }
        // Missing media blocks export (STO-10).
        let missing = project.allClips.filter { c in
            guard let s = project.source(c.mediaId) else { return true }
            return !FileManager.default.fileExists(atPath: store.resolve(s.path, package: package).path)
        }
        if !missing.isEmpty { r.blockers.append(.missingMedia(missing.map(\.id))) }
        if let free = store.freeSpace() {
            r.freeBytes = free
            let needed = Int64(Double(r.estimatedBytes) * 1.5)
            if free < needed { r.blockers.append(.insufficientSpace(neededBytes: needed - free)) }
        }
        if let limit = store.maxFileSize, r.estimatedBytes > limit { r.blockers.append(.fileTooLargeForVolume(limitBytes: limit)) }
        if dur > 30 * 60 * VETimeUtil.second { r.warnings.append("Projects over 30 minutes take a while to export. Keep the app open.") }
        // Audio past the main track's end is not exported (AUD-12 / TL-18).
        let overhang = project.tracks.audio.flatMap { $0 }.filter { $0.timelineEnd > dur }
        if !overhang.isEmpty { r.warnings.append("\(overhang.count) audio clip\(overhang.count == 1 ? "" : "s") extend\(overhang.count == 1 ? "s" : "") past the end of the video and will be cut off.") }
        return r
    }
}

// MARK: - Job state (observed by the progress sheet)

@MainActor @Observable final class VEExportJob {
    nonisolated enum Status: Equatable, Sendable {
        case preparing, exporting, finishing, done(URL), failed(VEError), cancelled
    }
    private(set) var status: Status = .preparing
    private(set) var fraction: Double = 0
    private(set) var startedAt = Date()
    private(set) var framesWritten = 0
    private(set) var thumbnail: UIImage?
    private(set) var outputBytes: Int64 = 0
    let settings: VEExportSettings
    let duration: VETime
    private var cancelFlag = VECancelFlag()
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    init(settings: VEExportSettings, duration: VETime) {
        self.settings = settings
        self.duration = duration
    }

    var elapsed: TimeInterval { Date().timeIntervalSince(startedAt) }
    var remaining: TimeInterval? {
        guard fraction > 0.02 else { return nil }
        return elapsed / fraction - elapsed
    }
    var isRunning: Bool { status == .preparing || status == .exporting || status == .finishing }

    func cancel() {
        cancelFlag.cancel()
        if status == .preparing { status = .cancelled }
    }

    /// Runs the export with a best-effort background window (EXP-7). Expiry cancels the export and
    /// posts a local notification telling the user to open the app and export again.
    func start(project: VEProject, package: URL, store: VEDriveStore) {
        startedAt = Date()
        UIApplication.shared.isIdleTimerDisabled = true
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "VideoEditor.export") { [weak self] in
            self?.cancelFlag.cancel()
            Self.postInterruptedNotification()
            self?.endBackgroundTask()
        }
        let flag = cancelFlag
        let settings = self.settings
        Task {
            let result = await VEExportService.run(project: project, package: package, store: store, settings: settings, cancel: flag) { [weak self] update in
                Task { @MainActor in self?.apply(update) }
            }
            switch result {
            case .success(let url):
                outputBytes = store.fileSize(url)
                status = .done(url)
                if settings.saveToPhotos { Self.saveCopyToPhotos(url) }
            case .failure(let e):
                status = flag.isCancelled ? .cancelled : .failed(e)
            }
            UIApplication.shared.isIdleTimerDisabled = false
            endBackgroundTask()
        }
    }

    private func apply(_ u: VEExportService.Update) {
        switch u {
        case .status(let s): if isRunning { status = s }
        case .progress(let f, let frames): fraction = f; framesWritten = frames
        case .thumbnail(let img): thumbnail = img
        }
    }

    private func endBackgroundTask() {
        if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask); backgroundTask = .invalid }
    }

    private static func postInterruptedNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Export was interrupted"
        content.body = "Open the app to export again."
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "VideoEditor.exportInterrupted", content: content, trigger: nil))
    }

    /// EXP-10: the optional Photos copy; a failure here never fails the export.
    private static func saveCopyToPhotos(_ url: URL) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else { return }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }, completionHandler: { _, error in
                if let error { VELog.export.error("Photos copy failed: \(error.localizedDescription)") }
            })
        }
    }
}

nonisolated final class VECancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func cancel() { lock.lock(); flag = true; lock.unlock() }
}

// MARK: - Export pipeline (EXP-3, EXP-5, EXP-6)

/// `AVAssetReaderVideoCompositionOutput` (same composition and compositor as preview) →
/// `AVAssetWriter` with explicit bitrate, profile and keyframe interval. Writes to the package's
/// `renders/` on the same volume and renames into `Exports/` on success; a cancel or failure
/// leaves no partial file.
nonisolated enum VEExportService {
    nonisolated enum Update: Sendable {
        case status(VEExportJob.Status)
        case progress(Double, Int)
        case thumbnail(UIImage)
    }

    static func run(project: VEProject, package: URL, store: VEDriveStore, settings: VEExportSettings, cancel: VECancelFlag,
                    update: @escaping @Sendable (Update) -> Void) async -> Result<URL, VEError> {
        let pre = VEExportPreflight.check(project: project, settings: settings, store: store, package: package)
        if let b = pre.blockers.first { return .failure(b) }
        guard project.duration > 0 else { return .failure(.exportFailed("The project has no clips.")) }

        // The export composition renders at the chosen resolution's canvas, at the chosen rate.
        let exportCanvas = project.settings.canvas.scaled(to: settings.resolution)
        var opts = VECompositionBuilder.Options()
        opts.useProxies = false
        opts.frameRate = settings.frameRate
        let built: VEBuiltComposition
        do {
            built = try await VECompositionBuilder.build(project, package: package, store: store, options: opts)
        } catch {
            return .failure(.exportFailed("The timeline couldn't be prepared."))
        }
        built.videoComposition.renderSize = exportCanvas.size
        if !built.missingClipIDs.isEmpty { return .failure(.missingMedia(built.missingClipIDs)) }

        let rendersDir = VEDriveLayout.renders(package)
        let exportsDir = VEDriveLayout.exports(store.editorRoot)
        try? DriveWriter.createDirectory(at: rendersDir)
        try? DriveWriter.createDirectory(at: exportsDir)
        let finalName = VENames.unique(VENames.sanitize(settings.fileName, fallback: "Export"), ext: "mp4", in: exportsDir)
        let partial = rendersDir.appendingPathComponent(".\(finalName).part.mp4")
        try? FileManager.default.removeItem(at: partial)
        store.assertUnderDrive(partial)

        // A dedicated serial queue (EXP-12): the pump blocks on the writer, which must not tie up a
        // cooperative-pool thread.
        let result: Result<URL, VEError> = await withCheckedContinuation { cont in
            DispatchQueue(label: "VideoEditor.export", qos: .userInitiated).async {
                cont.resume(returning: encode(built: built, to: partial, canvas: exportCanvas, settings: settings, cancel: cancel, update: update))
            }
        }

        switch result {
        case .failure(let e):
            try? FileManager.default.removeItem(at: partial)
            return .failure(e)
        case .success:
            update(.status(.finishing))
            let dest = exportsDir.appendingPathComponent(finalName)
            do {
                try store.coordinatedMove(from: partial, to: dest)
                VELog.export.log("exported \(finalName)")
                VELog.file("export \(finalName) ok")
                return .success(dest)
            } catch {
                try? FileManager.default.removeItem(at: partial)
                if VEDriveStore.isDriveLoss(error) { return .failure(.driveUnavailable) }
                return .failure(.exportFailed("The finished video couldn't be moved into Exports."))
            }
        }
    }

    private static func encode(built: VEBuiltComposition, to url: URL, canvas: VECanvas, settings: VEExportSettings,
                               cancel: VECancelFlag, update: @escaping @Sendable (Update) -> Void) -> Result<URL, VEError> {
        let composition = built.composition
        let reader: AVAssetReader
        let writer: AVAssetWriter
        do {
            reader = try AVAssetReader(asset: composition)
            writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        } catch {
            return .failure(.exportFailed("The encoder couldn't be started."))
        }

        // Reader outputs.
        let videoTracks = composition.tracks(withMediaType: .video)
        let videoOut = AVAssetReaderVideoCompositionOutput(videoTracks: videoTracks,
                                                           videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        videoOut.videoComposition = built.videoComposition
        videoOut.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOut) else { return .failure(.exportFailed("The video track couldn't be read.")) }
        reader.add(videoOut)

        let audioTracks = composition.tracks(withMediaType: .audio)
        var audioOut: AVAssetReaderAudioMixOutput?
        if !audioTracks.isEmpty {
            let pcm: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
                                      AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                                      AVLinearPCMIsNonInterleaved: false]
            let a = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: pcm)
            a.audioMix = built.audioMix
            a.audioTimePitchAlgorithm = .spectral
            a.alwaysCopiesSampleData = false
            if reader.canAdd(a) { reader.add(a); audioOut = a }
        }

        // Writer inputs (EXP-3).
        let isHEVC = settings.codec == .hevc
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: settings.videoBitrateBps,
            AVVideoMaxKeyFrameIntervalDurationKey: 2,
            AVVideoExpectedSourceFrameRateKey: settings.frameRate,
            AVVideoAllowFrameReorderingKey: true,
        ]
        compression[AVVideoProfileLevelKey] = isHEVC ? (kVTProfileLevel_HEVC_Main_AutoLevel as String) : AVVideoProfileLevelH264HighAutoLevel
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: isHEVC ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: canvas.width,
            AVVideoHeightKey: canvas.height,
            AVVideoCompressionPropertiesKey: compression,
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
        ]
        guard writer.canApply(outputSettings: videoSettings, forMediaType: .video) else {
            return .failure(.exportFailed("This device can't encode \(settings.codec.label) at \(settings.resolution.label)."))
        }
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoIn.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoIn) else { return .failure(.exportFailed("The video encoder couldn't be configured.")) }
        writer.add(videoIn)

        var audioIn: AVAssetWriterInput?
        if audioOut != nil {
            let aac: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
                                      AVEncoderBitRateKey: settings.audioBitrateBps]
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: aac)
            a.expectsMediaDataInRealTime = false
            if writer.canAdd(a) { writer.add(a); audioIn = a }
        }
        writer.shouldOptimizeForNetworkUse = true
        let created = AVMutableMetadataItem()
        created.identifier = .commonIdentifierCreationDate
        created.value = ISO8601DateFormatter().string(from: Date()) as NSString
        writer.metadata = [created]

        guard reader.startReading() else {
            return .failure(.exportFailed("The timeline couldn't be read: \(reader.error?.localizedDescription ?? "unknown error")."))
        }
        guard writer.startWriting() else {
            reader.cancelReading()
            return .failure(.exportFailed("The file couldn't be created on the drive."))
        }
        writer.startSession(atSourceTime: .zero)
        update(.status(.exporting))

        let total = max(0.001, built.duration.seconds)
        let group = DispatchGroup()
        let videoQueue = DispatchQueue(label: "VideoEditor.export.video")
        let audioQueue = DispatchQueue(label: "VideoEditor.export.audio")
        let thumbContext = CIContext(options: [.cacheIntermediates: false])
        let state = ExportProgressState()

        group.enter()
        videoIn.requestMediaDataWhenReady(on: videoQueue) {
            while videoIn.isReadyForMoreMediaData {
                if cancel.isCancelled { videoIn.markAsFinished(); state.finishVideo(group); return }
                guard let sb = videoOut.copyNextSampleBuffer() else {
                    videoIn.markAsFinished(); state.finishVideo(group); return
                }
                if !videoIn.append(sb) {
                    state.fail("The encoder rejected a frame: \(writer.error?.localizedDescription ?? "unknown error").")
                    videoIn.markAsFinished(); state.finishVideo(group); return
                }
                let pts = CMSampleBufferGetPresentationTimeStamp(sb).seconds
                let frames = state.bumpFrames()
                if frames % 10 == 0 { update(.progress(min(0.99, pts / total), frames)) }
                // Live thumbnail about once a second (EXP-6).
                if frames % max(1, settings.frameRate) == 0, let pb = CMSampleBufferGetImageBuffer(sb) {
                    let ci = CIImage(cvPixelBuffer: pb)
                    let scale = 240 / max(ci.extent.width, ci.extent.height)
                    let small = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                    if let cg = thumbContext.createCGImage(small, from: small.extent) { update(.thumbnail(UIImage(cgImage: cg))) }
                }
            }
        }
        if let audioIn, let audioOut {
            group.enter()
            audioIn.requestMediaDataWhenReady(on: audioQueue) {
                while audioIn.isReadyForMoreMediaData {
                    if cancel.isCancelled { audioIn.markAsFinished(); state.finishAudio(group); return }
                    guard let sb = audioOut.copyNextSampleBuffer() else { audioIn.markAsFinished(); state.finishAudio(group); return }
                    if !audioIn.append(sb) { audioIn.markAsFinished(); state.finishAudio(group); return }
                }
            }
        }
        group.wait()

        if cancel.isCancelled {
            reader.cancelReading(); writer.cancelWriting()
            return .failure(.cancelled)
        }
        if let msg = state.failure {
            reader.cancelReading(); writer.cancelWriting()
            return .failure(.exportFailed(msg))
        }
        if reader.status == .failed {
            writer.cancelWriting()
            let e = reader.error
            if let e, VEDriveStore.isDriveLoss(e) { return .failure(.driveUnavailable) }
            return .failure(.exportFailed("Reading the timeline failed: \(e?.localizedDescription ?? "unknown error")."))
        }
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else {
            let e = writer.error
            if let e, VEDriveStore.isDriveLoss(e) { return .failure(.driveUnavailable) }
            return .failure(.exportFailed("Writing the file failed: \(e?.localizedDescription ?? "unknown error")."))
        }
        DriveWriter.fullSyncFileAndParent(url)
        update(.progress(1, state.frames))
        return .success(url)
    }

    /// Mutable progress shared by the two writer callbacks.
    private final class ExportProgressState: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var frames = 0
        private(set) var failure: String?
        private var videoDone = false, audioDone = false
        func bumpFrames() -> Int { lock.lock(); frames += 1; let f = frames; lock.unlock(); return f }
        func fail(_ m: String) { lock.lock(); if failure == nil { failure = m }; lock.unlock() }
        func finishVideo(_ g: DispatchGroup) { lock.lock(); let was = videoDone; videoDone = true; lock.unlock(); if !was { g.leave() } }
        func finishAudio(_ g: DispatchGroup) { lock.lock(); let was = audioDone; audioDone = true; lock.unlock(); if !was { g.leave() } }
    }
}
