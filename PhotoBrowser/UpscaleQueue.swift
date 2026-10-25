import Foundation

/// Upscales as background work. A 1080p / 4K video upscale (one, or a batch) and the AI photo
/// upscales used to hold the folder behind a modal progress overlay; now each request is queued
/// here and runs one batch at a time as an app-wide activity (the progress pill in `ContentView`),
/// so the user keeps browsing — into other folders too — while it runs, and the outcome arrives as
/// an activity popup. Every item that comes out upscaled gets the "upscaled" tag. Videos re-encode
/// in place (`MediaEditing.upscaleVideo` / `enhanceVideo`), photos too (`enhancePhotoInPlace`), so
/// labels, captions and tags stay with the file.
///
/// Frame rate: a video job can ask for 30 or 60 fps (else the source rate is kept). The export's
/// composition is retimed to it — 60 from a 30 fps source repeats frames (no interpolation), 30
/// from 60 drops every other one.
extension Library {
    struct UpscaleJob: Identifiable, Sendable {
        enum Kind: Sendable {
            case video(targetShort: CGFloat, label: String, frameRate: Double?, enhance: Bool)
            case photo(scale: CGFloat)
        }
        let id = UUID()
        let urls: [URL]
        let kind: Kind
        /// The folder to refresh when the batch is done.
        let folder: URL?
    }

    static let upscaledTag = "upscaled"

    func enqueueUpscale(_ job: UpscaleJob) {
        guard !job.urls.isEmpty else { return }
        upscaleJobs.append(job)
        if !upscaleRunning { Task { await drainUpscales() } }
    }

    private func drainUpscales() async {
        upscaleRunning = true
        defer { upscaleRunning = false }
        while !upscaleJobs.isEmpty {
            let job = upscaleJobs.removeFirst()
            await run(job)
        }
    }

    private func run(_ job: UpscaleJob) async {
        let n = job.urls.count
        let plural = n == 1 ? "" : "s"
        let title: String
        switch job.kind {
        case .video(_, let label, let fps, let enhance):
            title = (enhance ? "AI Enhancing" : "Upscaling") + " \(n) video\(plural) to \(label)"
                + (fps.map { " · \(Int($0)) fps" } ?? "")
        case .photo:
            title = "AI Upscaling \(n) photo\(plural)"
        }
        let activity = beginActivity(title, cancellable: true)      // Stop in the activities sheet
        let bg = BackgroundTaskHolder(); bg.begin(name: "Upscale")
        var done = 0, skipped = 0, failed = 0
        var stopped = false
        for (i, url) in job.urls.enumerated() {
            if isActivityCancelled(activity) { stopped = true; break }      // finish the file in hand, then stop
            setActivity(activity, status: url.lastPathComponent, fraction: Double(i) / Double(n))
            let outcome: MediaEditing.UpscaleResult
            switch job.kind {
            case .video(let target, _, let fps, let enhance):
                let progress: @Sendable (Double) -> Void = { f in
                    Task { @MainActor in self.setActivity(activity, fraction: (Double(i) + f) / Double(n)) }
                }
                outcome = enhance
                    ? await MediaEditing.enhanceVideo(url: url, targetShort: target, frameRate: fps, progress: progress)
                    : await MediaEditing.upscaleVideo(url: url, targetShort: target, frameRate: fps, progress: progress)
            case .photo(let scale):
                // Apple Photos "…preview" JPEGs get the pipeline tuned for their compression artifacts.
                let isPreview = PhotosBackupImporter.previewInfo(url.lastPathComponent).isPreview
                let dates = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
                let ok = await Task.detached(priority: .userInitiated) {
                    isPreview ? MediaEditing.enhancePreviewInPlace(url: url, scale: 2)
                              : MediaEditing.enhancePhotoInPlace(url: url, scale: scale)
                }.value
                if ok {
                    // The in-place re-encode resets the file dates — restore them (EXIF is preserved).
                    var attrs: [FileAttributeKey: Any] = [:]
                    if let c = dates?.creationDate { attrs[.creationDate] = c }
                    if let m = dates?.contentModificationDate { attrs[.modificationDate] = m }
                    if !attrs.isEmpty { try? FileManager.default.setAttributes(attrs, ofItemAtPath: url.path) }
                }
                outcome = ok ? .upscaled : .failed
            }
            switch outcome {
            case .upscaled: done += 1; addTag(Self.upscaledTag, to: url)
            case .skipped:  skipped += 1
            case .failed:   failed += 1
            }
        }
        bg.end()
        var msg: String
        switch job.kind {
        case .video(_, let label, _, _):
            msg = "Upscaled \(done) video\(done == 1 ? "" : "s") to \(label)."
            if skipped > 0 { msg += " \(skipped) already ≥\(label)." }
        case .photo:
            msg = "Upscaled \(done) of \(n) photo\(plural)."
        }
        if failed > 0 { msg += " \(failed) couldn’t be processed." }
        if done > 0 { msg += " Tagged “\(Self.upscaledTag)”." }
        if stopped { msg += " Stopped before the rest." }
        endActivity(activity, result: msg)
        contentDidChange(under: job.folder)
    }
}
