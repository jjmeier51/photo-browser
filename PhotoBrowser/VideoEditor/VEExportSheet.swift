import SwiftUI
import AVKit
import Combine

/// EXP-1 export sheet → EXP-6 progress modal → EXP-10 completion. Defaults come from `settings.json`
/// on the drive and are written back on Export.
struct VEExportSheet: View {
    let session: VEEditorSession
    /// Called with the exported file when the user taps "Show in browser".
    var onShowInBrowser: (URL) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var resolution: VEResolution = .p1080
    @State private var frameRate = 30
    @State private var quality: VEExportQuality = .recommended
    @State private var customMbps: Double = 12
    @State private var codecChoice = "auto"
    @State private var fileName = ""
    @State private var saveToPhotos = false
    @State private var hdr = false
    @State private var report = VEPreflightReport()
    @State private var job: VEExportJob?
    @State private var loaded = false

    private var project: VEProject { session.project }

    private var codec: VEExportCodec {
        if hdr { return .hevc }
        return codecChoice == "h264" ? .h264 : (codecChoice == "hevc" ? .hevc : VEExportSettings.codecDefault(for: resolution))
    }

    private var exportSettings: VEExportSettings {
        VEExportSettings(resolution: resolution, frameRate: frameRate, quality: quality, customMbps: customMbps, codec: codec,
                         fileName: fileName, saveToPhotos: saveToPhotos, hdr: hdr)
    }

    /// The date the export will carry (the oldest embedded capture date; the service falls back
    /// to file dates when no source has one).
    private var captureDateText: String {
        project.oldestCaptureDate.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "From the files' dates"
    }

    /// 2K / 4K are offered always but labelled when no source is that large (EXP-1).
    private func upscales(_ r: VEResolution) -> Bool {
        guard r == .p1440 || r == .p2160 else { return false }
        let maxShort = project.media.filter { $0.kind == .video || $0.kind == .image }.map { min($0.width, $0.height) }.max() ?? 0
        return maxShort < r.shortEdge
    }

    private var is4K60Allowed: Bool {
        // 4K at 50/60 fps needs the newer encoders (NFR-1); approximate "A15 and later" by RAM ≥ 5.5 GB.
        ProcessInfo.processInfo.physicalMemory >= 5_500_000_000
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Video") {
                    Picker("Resolution", selection: $resolution) {
                        ForEach(VEResolution.allCases, id: \.self) { r in
                            Text(upscales(r) ? "\(r.label) · upscales" : r.label).tag(r)
                        }
                    }
                    Picker("Frame rate", selection: $frameRate) {
                        ForEach([24, 25, 30, 50, 60], id: \.self) { f in
                            if f <= 30 || resolution != .p2160 || is4K60Allowed { Text("\(f) fps").tag(f) }
                        }
                    }
                    Picker("Quality", selection: $quality) {
                        ForEach(VEExportQuality.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    if quality == .custom {
                        HStack {
                            Text("\(Int(customMbps)) Mb/s").monospacedDigit().frame(width: 80, alignment: .leading)
                            Slider(value: $customMbps, in: 1...120, step: 1)
                        }
                    } else {
                        LabeledContent("Bitrate", value: String(format: "%.1f Mb/s", Double(exportSettings.videoBitrateBps) / 1_000_000))
                    }
                    Picker("Codec", selection: $codecChoice) {
                        Text("Auto (\(VEExportSettings.codecDefault(for: resolution).label))").tag("auto")
                        Text("H.264").tag("h264")
                        Text("HEVC").tag("hevc")
                    }
                    .disabled(hdr)
                    Toggle("HDR (10-bit HEVC, HLG)", isOn: $hdr)
                }
                Section {
                    TextField("File name", text: $fileName)
                    LabeledContent("Destination", value: "VideoEditor/Exports")
                    LabeledContent("Capture date", value: captureDateText)
                    Toggle("Also save a copy to Photos", isOn: $saveToPhotos)
                } header: { Text("File") } footer: {
                    Text(hdr
                         ? "The file keeps the clips' location, camera and dates; its date is the oldest clip's capture date. HDR exports need HEVC and show as HDR in Photos."
                         : (project.settings.hdr
                            ? "The file keeps the clips' location, camera and dates; its date is the oldest clip's capture date. HDR is off, so the HDR footage is tone-mapped to SDR."
                            : "The file keeps the clips' location, camera and dates; its date is the oldest clip's capture date."))
                }
                Section {
                    LabeledContent("Estimated size", value: ByteCountFormatter.string(fromByteCount: report.estimatedBytes, countStyle: .file))
                    if let free = report.freeBytes { LabeledContent("Free on drive", value: ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) }
                    LabeledContent("Duration", value: VETimeUtil.format(project.duration, fps: project.settings.frameRate))
                    LabeledContent("Output", value: "\(project.settings.canvas.scaled(to: resolution).width) × \(project.settings.canvas.scaled(to: resolution).height) · \(frameRate) fps · \(codec.label)")
                    ForEach(report.blockers.indices, id: \.self) { i in
                        Label("\(report.blockers[i].title). \(report.blockers[i].message)", systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.footnote)
                    }
                    ForEach(report.warnings, id: \.self) { w in
                        Label(w, systemImage: "exclamationmark.triangle").foregroundStyle(.yellow).font(.footnote)
                    }
                } footer: {
                    Text("Keep the app open while exporting — iOS stops the encoder after about 30 seconds in the background.")
                }
            }
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Export") { startExport() }.disabled(!report.ok || fileName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { if !loaded { loaded = true; restoreDefaults(); refreshPreflight() } }
            .onChange(of: resolution) { _, _ in refreshPreflight() }
            .onChange(of: frameRate) { _, _ in refreshPreflight() }
            .onChange(of: quality) { _, _ in refreshPreflight() }
            .onChange(of: customMbps) { _, _ in refreshPreflight() }
            .onChange(of: codecChoice) { _, _ in refreshPreflight() }
            .onChange(of: hdr) { _, _ in refreshPreflight() }
            .fullScreenCover(item: $job) { j in
                VEExportProgressView(job: j, project: project) { url in
                    job = nil
                    onShowInBrowser(url)
                } onDone: { job = nil; dismiss() }
                .interactiveDismissDisabled(true)
            }
        }
        .preferredColorScheme(.dark)
    }

    private func restoreDefaults() {
        let prefs = session.settings.lastExport
        resolution = prefs.resolution
        frameRate = prefs.frameRate ?? project.settings.frameRate
        quality = VEExportQuality(rawValue: prefs.quality) ?? .recommended
        customMbps = prefs.customBitrateMbps
        codecChoice = prefs.codec
        saveToPhotos = prefs.saveToPhotos
        // HDR follows the project unless the user chose otherwise last time; an SDR project can't
        // become HDR by exporting, so the remembered "on" only applies when there is HDR footage.
        hdr = project.settings.hdr ? (prefs.hdr ?? true) : false
        fileName = VENames.exportName(project: project.name)
    }

    private func refreshPreflight() {
        let s = exportSettings
        let p = project
        let store = session.store
        let pkg = session.document.packageURL
        Task.detached(priority: .userInitiated) {
            let r = VEExportPreflight.check(project: p, settings: s, store: store, package: pkg)
            await MainActor.run { report = r }
        }
    }

    private func startExport() {
        var prefs = session.settings.lastExport
        prefs.resolution = resolution; prefs.frameRate = frameRate; prefs.quality = quality.rawValue
        prefs.customBitrateMbps = customMbps; prefs.codec = codecChoice; prefs.saveToPhotos = saveToPhotos
        if project.settings.hdr { prefs.hdr = hdr }
        session.settings.lastExport = prefs
        session.store.saveSettings(session.settings)
        session.playback.pause()
        let settings = exportSettings
        let j = VEExportJob(settings: settings, duration: project.duration)
        job = j
        Task {
            await session.document.saveNow()     // PRJ-2: save before every export
            j.start(project: session.project, package: session.document.packageURL, store: session.store)
        }
    }
}

extension VEExportJob: Identifiable {}

/// EXP-6 full-screen progress with Cancel (confirmed after 10 %), then the EXP-10 completion card.
struct VEExportProgressView: View {
    let job: VEExportJob
    let project: VEProject
    var onShowInBrowser: (URL) -> Void
    var onDone: () -> Void
    @State private var confirmCancel = false
    @State private var showPlayer = false
    @State private var tick = Date()
    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            switch job.status {
            case .done(let url): completion(url)
            case .failed(let e): failure(e)
            case .cancelled:
                Image(systemName: "xmark.circle").font(.system(size: 48)).foregroundStyle(.secondary)
                Text("Export cancelled").font(.title3.bold())
                Button("Done") { onDone() }.buttonStyle(.borderedProminent)
            default: progress
            }
            Spacer()
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onReceive(timer) { t in tick = t }
        .sheet(isPresented: $showPlayer) {
            if case .done(let url) = job.status {
                VideoPlayer(player: AVPlayer(url: url)).ignoresSafeArea()
            }
        }
    }

    private var progress: some View {
        VStack(spacing: 18) {
            if let img = job.thumbnail {
                Image(uiImage: img).resizable().scaledToFit().frame(maxHeight: 180).clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.15)).frame(height: 160).overlay(ProgressView())
            }
            Text(job.status == .preparing ? "Preparing…" : (job.status == .finishing ? "Finishing…" : "Exporting \(Int(job.fraction * 100))%"))
                .font(.title3.bold())
            ProgressView(value: job.fraction).tint(.accentColor)
            HStack {
                Text("Elapsed \(format(job.elapsed))")
                Spacer()
                if let r = job.remaining { Text("About \(format(r)) left") }
            }
            .font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
            Text("Keep the app open while exporting").font(.caption).foregroundStyle(.secondary)
            Button("Cancel", role: .destructive) {
                if job.fraction > 0.1 { confirmCancel = true } else { job.cancel() }
            }
            .buttonStyle(.bordered)
            .confirmationDialog("Cancel the export? The partial file will be deleted.", isPresented: $confirmCancel, titleVisibility: .visible) {
                Button("Cancel Export", role: .destructive) { job.cancel() }
                Button("Keep Exporting", role: .cancel) {}
            }
        }
        .id(tick)   // refresh elapsed/remaining
    }

    private func completion(_ url: URL) -> some View {
        VStack(spacing: 14) {
            if let img = job.thumbnail {
                Image(uiImage: img).resizable().scaledToFit().frame(maxHeight: 180).clipShape(RoundedRectangle(cornerRadius: 10))
            }
            Image(systemName: "checkmark.circle.fill").font(.system(size: 40)).foregroundStyle(.green)
            Text(url.lastPathComponent).font(.headline).multilineTextAlignment(.center)
            let canvas = project.settings.canvas.scaled(to: job.settings.resolution)
            Text("\(ByteCountFormatter.string(fromByteCount: job.outputBytes, countStyle: .file)) · \(VETimeUtil.format(job.duration, fps: job.settings.frameRate)) · \(canvas.width)×\(canvas.height) · \(job.settings.frameRate) fps · \(job.settings.effectiveCodec.label)\(job.settings.hdr ? " · HDR" : "")")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Text("VideoEditor/Exports/\(url.lastPathComponent)").font(.caption2.monospaced()).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button { onShowInBrowser(url) } label: { Label("Show in browser", systemImage: "folder") }.buttonStyle(.bordered)
                Button { showPlayer = true } label: { Label("Play", systemImage: "play.fill") }.buttonStyle(.bordered)
            }
            Button("Done") { onDone() }.buttonStyle(.borderedProminent)
        }
    }

    private func failure(_ e: VEError) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 40)).foregroundStyle(.yellow)
            Text(e.title).font(.title3.bold())
            Text(e.message).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Done") { onDone() }.buttonStyle(.borderedProminent)
        }
    }

    private func format(_ t: TimeInterval) -> String {
        let s = Int(max(0, t))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}
