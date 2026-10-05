import SwiftUI
import AVFoundation

/// The editor screen: preview with on-canvas gizmo, transport row, the UIKit timeline and a
/// context-sensitive tool bar (TL-2). Tool sheets replace the bar and confirm with ✓ / cancel
/// with ✕, each one undo step.
struct VEEditorView: View {
    @Environment(Library.self) private var library
    @State var session: VEEditorSession
    var onClose: (() -> Void)?
    /// Called with the Exports folder so the host can navigate there (EXP-10).
    var onShowInBrowser: ((URL) -> Void)?

    @State private var tool: VETool?
    @State private var showExport = false
    @State private var showSettings = false
    @State private var showRename = false
    @State private var renameDraft = ""
    @State private var fullScreen = false
    @State private var showMissing = false
    @State private var relinkSource: VEMediaSource?
    @State private var closing = false

    private var doc: VEDocument { session.document }
    private var project: VEProject { session.project }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let landscape = geo.size.width > geo.size.height && geo.size.width > 700
                Group {
                    if landscape {
                        HStack(spacing: 0) {
                            VStack(spacing: 0) { preview; transport }
                                .frame(width: geo.size.width * 0.55)
                            Divider()
                            VStack(spacing: 0) { timeline; toolArea }
                        }
                    } else {
                        VStack(spacing: 0) {
                            preview.frame(height: fullScreen ? geo.size.height - 60 : max(200, geo.size.height * 0.38))
                            transport
                            if !fullScreen {
                                timeline
                                toolArea
                            }
                        }
                    }
                }
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle(project.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(Color(white: 0.08), for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { close() }.disabled(closing)
                }
                ToolbarItem(placement: .principal) {
                    Button { renameDraft = project.name; showRename = true } label: {
                        Text(project.name).font(.headline).lineLimit(1)
                    }
                    .disabled(doc.readOnly)
                }
                ToolbarItem(placement: .confirmationAction) {
                    HStack(spacing: 10) {
                        Button { showSettings = true } label: {
                            Text(project.settings.resolution.rawValue).font(.caption.bold())
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(Color(white: 0.2), in: Capsule())
                        }
                        Button("Export") { showExport = true }
                            .buttonStyle(.borderedProminent)
                            .disabled(project.duration <= 0 || doc.readOnly)
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { session.start() }
        .sheet(item: $session.showImport) { req in
            VEImportPicker(session: session, mode: .add(insertAtPlayhead: req.insertAtPlayhead))
        }
        .sheet(isPresented: $showExport) {
            VEExportSheet(session: session) { url in
                showExport = false
                close { onShowInBrowser?(url.deletingLastPathComponent()) }
            }
        }
        .sheet(isPresented: $showSettings) { VEProjectSettingsSheet(session: session) }
        .sheet(isPresented: $session.showCoverSheet) { VECoverSheet(session: session) }
        .sheet(item: $relinkSource) { src in
            VEImportPicker(session: session, mode: .relink(sourceID: src.id, kind: src.kind))
        }
        .sheet(isPresented: $session.driveLost) {
            VEDriveLostSheet(lastSaved: doc.lastSavedAt)
                .interactiveDismissDisabled(true)
        }
        .alert("Rename Project", isPresented: $showRename) {
            TextField("Name", text: $renameDraft)
            Button("Rename") { session.rename(renameDraft) }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Some files were skipped", isPresented: Binding(get: { !session.importSkipped.isEmpty }, set: { if !$0 { session.importSkipped = [] } })) {
            Button("OK") { session.importSkipped = [] }
        } message: {
            Text(session.importSkipped.prefix(5).map { "\($0.name): \($0.reason)" }.joined(separator: "\n"))
        }
        .overlay(alignment: .bottom) { toastView }
        .overlay { importOverlay }
    }

    // MARK: Preview

    private var preview: some View {
        ZStack {
            VEPreviewView(player: session.playback.player, canvasSize: project.settings.canvas.size, gizmo: gizmoState,
                          onPixelSize: { px in
                              if session.playback.previewPixelSize != px { session.playback.previewPixelSize = px; session.rebuildPreview() }
                          },
                          onTransform: { t, phase in session.canvasTransform(t, phase: phase) },
                          onTapCanvas: { if session.selectedClipID == nil, let hit = project.mainClip(at: session.playback.currentTime) { session.selectedClipID = hit.clip.id } else { session.selectedClipID = nil } })
            VStack {
                HStack {
                    if session.playback.usesProxy {
                        Text("Proxy").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    if session.playback.isBuilding { ProgressView().controlSize(.small) }
                    Spacer()
                    if !session.missingSources.isEmpty {
                        Button { showMissing = true } label: {
                            Label("Missing media", systemImage: "exclamationmark.triangle.fill").font(.caption.bold())
                                .padding(.horizontal, 8).padding(.vertical, 4).background(.yellow.opacity(0.9), in: Capsule()).foregroundStyle(.black)
                        }
                        .confirmationDialog("Missing media", isPresented: $showMissing, titleVisibility: .visible) {
                            ForEach(session.missingSources) { s in
                                Button("Relink \(s.displayName)…") { relinkSource = s }
                            }
                        } message: {
                            Text(session.relinkSearching ? "Searching the drive for moved files…" : "These files aren't where the project expects them. Relink them to export.")
                        }
                    }
                }
                .padding(8)
                Spacer()
                if let e = doc.saveError {
                    Text(e).font(.caption).padding(6).background(.red.opacity(0.8), in: RoundedRectangle(cornerRadius: 6)).padding(.bottom, 4)
                }
            }
        }
        .background(Color.black)
    }

    private var gizmoState: VEGizmoState? {
        guard let c = session.selectedClip, let s = project.source(c.mediaId), tool == nil || tool == .edit else { return nil }
        return VEGizmoState(clipID: c.id, sourceSize: s.displaySize.cgSize, crop: c.crop, transform: c.transform,
                            snapping: session.settings.snapping, haptics: session.settings.haptics)
    }

    // MARK: Transport (PRV-1)

    private var transport: some View {
        let p = session.playback
        return HStack(spacing: 18) {
            Text("\(VETimeUtil.format(p.currentTime, fps: p.frameRate)) / \(VETimeUtil.format(project.duration, fps: p.frameRate))")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .frame(minWidth: 110, alignment: .leading)
            Spacer()
            Button { session.undo() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(!doc.canUndo || tool != nil)
            Button { session.redo() } label: { Image(systemName: "arrow.uturn.forward") }.disabled(!doc.canRedo || tool != nil)
            Button { p.step(-1) } label: { Image(systemName: "backward.frame") }
            Button { p.togglePlay() } label: { Image(systemName: p.isPlaying ? "pause.fill" : "play.fill").font(.title2) }
                .disabled(project.duration <= 0)
            Button { p.step(1) } label: { Image(systemName: "forward.frame") }
            Spacer()
            Button { withAnimation { fullScreen.toggle() } } label: {
                Image(systemName: fullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
            }
        }
        .font(.body)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Color(white: 0.1))
        .highPriorityGesture(undoSwipe)
    }

    /// PRJ-4: three-finger swipes mirror undo / redo. SwiftUI can't count fingers, so a horizontal
    /// drag on the transport row with the system's three-finger undo gesture is left to UIKit; this
    /// is the keyboard-free fallback.
    private var undoSwipe: some Gesture {
        DragGesture(minimumDistance: 60).onEnded { v in
            if v.translation.width < -60 { session.undo() } else if v.translation.width > 60 { session.redo() }
        }
    }

    // MARK: Timeline

    private var timeline: some View {
        VETimeline(model: session.timelineModel, playhead: session.playback.currentTime, isPlaying: session.playback.isPlaying,
                   thumbsRevision: session.thumbsRevision, provider: session.thumbs, delegate: session)
            .frame(minHeight: 120, maxHeight: 170)
    }

    // MARK: Tools (TL-2)

    private var toolArea: some View {
        Group {
            if let activeTool = tool {
                VEToolSheet(session: session, tool: activeTool, onDismiss: closeTool)
                    .transition(.move(edge: .bottom))
            } else if session.selectedClip != nil {
                clipToolBar
            } else {
                topToolBar
            }
        }
        .frame(maxWidth: .infinity)
        .background(Color(white: 0.08))
        .animation(.easeInOut(duration: 0.15), value: tool)
    }

    /// Closes the open tool sheet. A named method rather than an inline `{ tool = nil }`: inside
    /// `if let tool` the shorthand binding shadows the `@State` property, and the Swift 6.4
    /// type-checker asserts (NamingPatternRequest) instead of diagnosing the assignment.
    private func closeTool() {
        tool = nil
    }

    private var topToolBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                toolButton("Add", "plus.square") { session.showImport = VEImportRequest(insertAtPlayhead: false) }
                toolButton("Ratio", "aspectratio") { tool = .ratio }
                toolButton(project.settings.muteOriginalAudio ? "Unmute" : "Mute clips", project.settings.muteOriginalAudio ? "speaker.slash" : "speaker.wave.2") {
                    session.toggleMuteOriginalAudio()
                }
                toolButton("Cover", "photo.on.rectangle") { session.showCoverSheet = true }
                toolButton("Settings", "gearshape") { showSettings = true }
            }
            .padding(.horizontal, 8).padding(.vertical, 8)
        }
        .frame(height: 72)
    }

    private var clipToolBar: some View {
        let clip = session.selectedClip
        let isStill = clip?.hasSpeed == false
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                toolButton("Split", "scissors") { session.split() }.disabled(!session.canSplit)
                if !isStill { toolButton("Speed", "gauge.with.needle") { tool = .speed } }
                if !isStill, let c = clip, project.source(c.mediaId)?.hasAudio == true, !c.audioExtracted { toolButton("Volume", "speaker.wave.2") { tool = .volume } }
                if isStill { toolButton("Duration", "timer") { tool = .duration } }
                toolButton("Delete", "trash") { session.deleteSelected() }
                toolButton("Edit", "crop.rotate") { tool = .edit }
                toolButton("Opacity", "circle.lefthalf.filled") { tool = .opacity }
                toolButton("Copy", "plus.square.on.square") { session.duplicateSelected() }
                toolButton("Canvas", "rectangle.on.rectangle") { tool = .canvas }
                toolButton("Done", "checkmark") { session.selectedClipID = nil }
            }
            .padding(.horizontal, 8).padding(.vertical, 8)
        }
        .frame(height: 72)
    }

    private func toolButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 18))
                Text(title).font(.caption2)
            }
            .frame(width: 64, height: 54)
        }
        .foregroundStyle(.white)
        .disabled(doc.readOnly)
    }

    // MARK: Overlays

    private var toastView: some View {
        Group {
            if let t = session.toast {
                Text(t).font(.footnote).multilineTextAlignment(.center)
                    .padding(10).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .padding(.bottom, 90).padding(.horizontal)
                    .transition(.opacity)
                    .task { try? await Task.sleep(nanoseconds: 4_000_000_000); if session.toast == t { session.toast = nil } }
            }
        }
        .animation(.easeInOut, value: session.toast)
    }

    private var importOverlay: some View {
        Group {
            if let p = session.importProgress {
                VStack(spacing: 10) {
                    ProgressView(value: p.fraction)
                    Text(p.name.isEmpty ? "Importing…" : "Importing \(p.name)…").font(.footnote).lineLimit(1)
                }
                .padding(16).frame(width: 260).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private func close(then: (() -> Void)? = nil) {
        guard !closing else { return }
        closing = true
        Task {
            await session.close()
            onClose?()
            then?()
        }
    }
}

enum VETool: Equatable { case speed, volume, opacity, duration, edit, ratio, canvas }

/// The bottom tool sheet with ✕ / ✓ (TL-2). Cancel restores the pre-sheet state as one undo step.
struct VEToolSheet: View {
    let session: VEEditorSession
    let tool: VETool
    var onDismiss: () -> Void

    @State private var speed: Double = 1
    @State private var keepPitch = true
    @State private var volume: Double = 100
    @State private var opacity: Double = 100
    @State private var duration: Double = 3
    @State private var started = false

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Button { session.cancelTool(); onDismiss() } label: { Image(systemName: "xmark").font(.headline) }
                Spacer()
                Text(title).font(.subheadline.bold())
                Spacer()
                Button { session.confirmTool(); onDismiss() } label: { Image(systemName: "checkmark").font(.headline) }
            }
            .padding(.horizontal, 16)
            content
        }
        .padding(.vertical, 10)
        .frame(minHeight: 72)
        .onAppear {
            guard !started else { return }
            started = true
            if let c = session.selectedClip {
                speed = c.speed.rate; keepPitch = c.speed.keepPitch
                volume = c.volume * 100; opacity = c.opacity * 100
                duration = VETimeUtil.seconds(c.sourceRange.duration)
            }
            session.beginTool(title)
        }
    }

    /// Log slider 0.1x–100x (SPD-1 range) with 1x in the middle; snaps to 1x within ±4 %.
    private var speedBinding: Binding<Double> {
        Binding<Double>(
            get: { log10(speed) },
            set: { (v: Double) in
                var s: Double = pow(10.0, v)
                if abs(s - 1) < 0.04 { s = 1 }
                speed = (s * 100).rounded() / 100
                session.setSpeed(speed, keepPitch: keepPitch, commit: false)
            })
    }

    private var title: String {
        switch tool {
        case .speed: return "Speed"
        case .volume: return "Volume"
        case .opacity: return "Opacity"
        case .duration: return "Duration"
        case .edit: return "Edit"
        case .ratio: return "Ratio"
        case .canvas: return "Canvas"
        }
    }

    @ViewBuilder private var content: some View {
        switch tool {
        case .speed:
            VStack(spacing: 4) {
                HStack {
                    Text(String(format: "%.2fx", speed)).font(.caption.monospacedDigit()).frame(width: 56)
                    // Log slider 0.1x–100x (SPD-1 range), 1x in the middle.
                    Slider(value: speedBinding, in: -1.0...2.0)
                    Toggle("Keep pitch", isOn: $keepPitch).labelsHidden()
                        .onChange(of: keepPitch) { _, v in session.setSpeed(speed, keepPitch: v, commit: false) }
                }
                Text("Pitch is kept when the switch is on").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
        case .volume:
            HStack {
                Text("\(Int(volume))").font(.caption.monospacedDigit()).frame(width: 44)
                Slider(value: $volume, in: 0...1000, step: 1).onChange(of: volume) { _, v in session.setVolume(v / 100, commit: false) }
                Button { session.toggleMuteSelected(); } label: {
                    Image(systemName: session.selectedClip?.audioMuted == true ? "speaker.slash.fill" : "speaker.wave.2.fill")
                }
            }
            .padding(.horizontal, 16)
        case .opacity:
            HStack {
                Text("\(Int(opacity))").font(.caption.monospacedDigit()).frame(width: 44)
                Slider(value: $opacity, in: 0...100, step: 1).onChange(of: opacity) { _, v in session.setOpacity(v / 100, commit: false) }
            }
            .padding(.horizontal, 16)
        case .duration:
            HStack {
                Text(String(format: "%.1f s", duration)).font(.caption.monospacedDigit()).frame(width: 56)
                Slider(value: $duration, in: 0.5...30, step: 0.1).onChange(of: duration) { _, v in session.setStillDuration(v, commit: false) }
            }
            .padding(.horizontal, 16)
        case .edit:
            VEEditToolRow(session: session)
        case .ratio:
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(VERatio.allCases, id: \.self) { r in
                        let on = session.project.settings.canvas.ratio == r
                        Button(r.rawValue) { session.document.updateTransaction { p in p.settings.canvas.ratio = r; p.refreshCanvas() }; session.rebuildPreview() }
                            .font(.caption.bold())
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(on ? Color.accentColor : Color(white: 0.2), in: Capsule())
                            .foregroundStyle(.white)
                    }
                }
                .padding(.horizontal, 16)
            }
        case .canvas:
            VECanvasToolRow(session: session)
        }
    }
}

/// Edit: Crop, Rotate, Mirror, Fit, Fill, Reset (TL-8, TL-9).
struct VEEditToolRow: View {
    let session: VEEditorSession
    @State private var showCrop = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                item("Crop", "crop") { showCrop = true }
                item("Rotate", "rotate.right") { session.rotateSelected90() }
                item("Mirror", "arrow.left.and.right.righttriangle.left.righttriangle.right") { session.mirrorSelected() }
                item("Fit", "arrow.down.right.and.arrow.up.left.square") { session.fitSelected(fill: false) }
                item("Fill", "arrow.up.left.and.arrow.down.right.square") { session.fitSelected(fill: true) }
                item("Reset", "arrow.counterclockwise") { session.resetTransformSelected() }
            }
            .padding(.horizontal, 8)
        }
        .fullScreenCover(isPresented: $showCrop) {
            if let clip = session.selectedClip, let src = session.project.source(clip.mediaId) {
                VECropScreen(session: session, clip: clip, source: src)
            }
        }
    }

    private func item(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) { Image(systemName: symbol).font(.system(size: 18)); Text(title).font(.caption2) }.frame(width: 64, height: 50)
        }
        .foregroundStyle(.white)
    }
}

/// Canvas background per clip (CAN-4, colour tab + blur in Phase 1) with "Apply to all".
struct VECanvasToolRow: View {
    let session: VEEditorSession
    private let swatches = ["#000000", "#FFFFFF", "#1C1C1E", "#8E8E93", "#FF3B30", "#FF9500", "#FFCC00", "#34C759", "#00C7BE", "#30B0C7",
                            "#007AFF", "#5856D6", "#AF52DE", "#FF2D55", "#A2845E", "#2C2C54", "#0B3D2E", "#4A1C40", "#F5E6CC", "#D9E8F5"]

    var body: some View {
        VStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(1...4, id: \.self) { level in
                        let on = session.selectedClip?.background.kind == "blur" && session.selectedClip?.background.blurLevel == level
                        Button { set { $0.kind = "blur"; $0.blurLevel = level } } label: {
                            Text("Blur \(level)").font(.caption2.bold()).frame(width: 52, height: 30)
                                .background(on ? Color.accentColor : Color(white: 0.25), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                    ForEach(swatches, id: \.self) { hex in
                        let on = session.selectedClip?.background.kind == "color" && session.selectedClip?.background.color.uppercased() == hex
                        Button { set { $0.kind = "color"; $0.color = hex } } label: {
                            Circle().fill(Color(VEColor.uiColor(hex))).frame(width: 30, height: 30)
                                .overlay(Circle().stroke(on ? Color.white : Color.gray.opacity(0.5), lineWidth: on ? 3 : 1))
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            Button("Apply to all clips") {
                guard let bg = session.selectedClip?.background else { return }
                session.document.updateTransaction { p in for i in p.tracks.main.indices { p.tracks.main[i].background = bg } }
                session.rebuildPreview()
            }
            .font(.caption)
        }
        .foregroundStyle(.white)
    }

    private func set(_ mutate: (inout VEBackground) -> Void) {
        guard let id = session.selectedClipID else { return }
        session.document.updateTransaction { p in if let i = p.mainIndex(of: id) { mutate(&p.tracks.main[i].background) } }
        session.rebuildPreview()
    }
}

/// STO-6: blocking sheet while the drive is gone; dismisses itself on reconnect.
struct VEDriveLostSheet: View {
    var lastSaved: Date?
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "externaldrive.badge.xmark").font(.system(size: 48)).foregroundStyle(.secondary)
            Text("Drive disconnected").font(.title2.bold())
            Text("Reconnect the drive to keep editing. Your edits are kept in memory and will be saved as soon as it comes back.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            if let lastSaved {
                Text("Last saved \(lastSaved.formatted(date: .omitted, time: .standard))").font(.footnote).foregroundStyle(.secondary)
            } else {
                Text("Not saved yet").font(.footnote).foregroundStyle(.secondary)
            }
            ProgressView()
        }
        .padding(32)
        .presentationDetents([.medium])
    }
}

/// PRJ-7 cover: the frame under the playhead (rendered through the full composition).
struct VECoverSheet: View {
    let session: VEEditorSession
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let image {
                    Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 300).clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.15)).frame(height: 200).overlay(Text("No cover yet").foregroundStyle(.secondary))
                }
                Text("The cover is the thumbnail on the Projects screen. It doesn't add a frame to the exported video.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Use the frame at \(VETimeUtil.format(session.playback.currentTime, fps: session.project.settings.frameRate))") {
                    session.setCoverToPlayhead()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(session.project.duration <= 0)
            }
            .padding()
            .navigationTitle("Cover")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .task { image = UIImage(contentsOfFile: VEDriveLayout.cover(session.document.packageURL).path) }
        }
        .presentationDetents([.medium, .large])
    }
}

/// PRJ-5 project settings.
struct VEProjectSettingsSheet: View {
    let session: VEEditorSession
    @Environment(\.dismiss) private var dismiss
    @State private var frameRate = 30
    @State private var resolution: VEResolution = .p1080
    @State private var photo: Double = 3
    @State private var freeze: Double = 3
    @State private var layer: Double = 3
    @State private var proxy: VEProxyMode = .auto
    @State private var snapping = true
    @State private var haptics = true
    @State private var diagnostics = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Project") {
                    Picker("Resolution", selection: $resolution) { ForEach(VEResolution.allCases, id: \.self) { Text($0.label).tag($0) } }
                    Picker("Frame rate", selection: $frameRate) { ForEach([24, 25, 30, 50, 60], id: \.self) { Text("\($0) fps").tag($0) } }
                    LabeledContent("Canvas", value: "\(session.project.settings.canvas.width) × \(session.project.settings.canvas.height)")
                    LabeledContent("Aspect ratio", value: session.project.settings.canvas.ratio.rawValue)
                }
                Section("Defaults") {
                    Stepper("Photo duration: \(photo, specifier: "%.1f") s", value: $photo, in: 0.5...30, step: 0.5)
                    Stepper("Freeze duration: \(freeze, specifier: "%.1f") s", value: $freeze, in: 0.5...30, step: 0.5)
                    Stepper("Layer duration: \(layer, specifier: "%.1f") s", value: $layer, in: 0.5...30, step: 0.5)
                }
                Section {
                    Picker("Proxy playback", selection: $proxy) {
                        Text("Auto").tag(VEProxyMode.auto); Text("Always").tag(VEProxyMode.always); Text("Never").tag(VEProxyMode.never)
                    }
                    Toggle("Snapping", isOn: $snapping)
                    Toggle("Haptics", isOn: $haptics)
                    Toggle("Diagnostics log on the drive", isOn: $diagnostics)
                } header: { Text("Editor") } footer: {
                    Text("Proxies are 720p preview copies kept in the project's caches so 4K and HDR footage scrubs smoothly from the drive. Export always uses the originals.")
                }
                Section {
                    Button("Clear this project's caches", role: .destructive) {
                        let pkg = session.document.packageURL, store = session.store
                        Task.detached { VEProjectCatalog.clearCaches(pkg, store: store) }
                        session.document.updateMedia { m in for i in m.indices { m[i].derived.proxy = nil; m[i].derived.thumbs = nil; m[i].derived.waveform = nil } }
                        session.thumbs.flush()
                        session.scheduleDerivedAssets()
                    }
                } footer: { Text("Thumbnails, waveforms and proxies rebuild on their own.") }
            }
            .navigationTitle("Project Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        session.setProjectSettings(frameRate: frameRate, resolution: resolution, photoDuration: VETimeUtil.fromSeconds(photo),
                                                   freeze: VETimeUtil.fromSeconds(freeze), layer: VETimeUtil.fromSeconds(layer), proxy: proxy)
                        session.settings.snapping = snapping; session.settings.haptics = haptics; session.settings.diagnostics = diagnostics
                        session.settings.defaultPhotoDuration = VETimeUtil.fromSeconds(photo)
                        VELog.diagnosticsRoot = diagnostics ? session.store.editorRoot : nil
                        session.store.saveSettings(session.settings)
                        dismiss()
                    }
                }
            }
            .onAppear {
                let s = session.project.settings
                frameRate = s.frameRate; resolution = s.resolution
                photo = VETimeUtil.seconds(s.defaultPhotoDuration); freeze = VETimeUtil.seconds(s.defaultFreezeDuration); layer = VETimeUtil.seconds(s.defaultLayerDuration)
                proxy = s.proxyPlayback
                snapping = session.settings.snapping; haptics = session.settings.haptics; diagnostics = session.settings.diagnostics
            }
        }
    }
}
