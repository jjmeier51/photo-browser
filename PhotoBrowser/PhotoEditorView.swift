import SwiftUI
import CoreImage
import UIKit

/// The full-screen photo editor (Hypic/Facetune-style) built on the non-destructive `EditRecipe`
/// backbone (PRD Phase 1). A downscaled **proxy** of the source drives a live preview at interactive
/// framerates; every control mutates the recipe and re-renders off the main actor. "Save" writes a
/// **new** file beside the original via `PhotoEditorIO` (metadata + capture date preserved, original
/// untouched) as a background activity, so the user can keep browsing while it encodes.
///
/// Geometry (crop/rotate/straighten/flip), tone/color sliders + one-tap Auto, preset filters with an
/// intensity blend, and detail/effects are all reflected live. Liquify/reshape, background & object
/// removal are deferred to later phases.
struct PhotoEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(Library.self) private var library
    let entry: Entry

    private enum Tab: String, CaseIterable, Identifiable {
        case adjust, filters, crop, reshape, body, makeup, cutout
        var id: String { rawValue }
        var title: String { self == .cutout ? "Cut Out" : rawValue.capitalized }
        var icon: String {
            switch self {
            case .adjust:  return "slider.horizontal.3"
            case .filters: return "camera.filters"
            case .crop:    return "crop.rotate"
            case .reshape: return "hand.draw"
            case .body:    return "figure.stand"
            case .makeup:  return "paintbrush.pointed.fill"
            case .cutout:  return "person.and.background.dotted"
            }
        }
    }

    // Source proxy + rendered preview
    @State private var proxy: CIImage?
    @State private var fastProxy: CIImage?      // smaller proxy for high-FPS preview during reshape drags
    @State private var reshaping = false        // true while a reshape stroke is in progress
    @State private var preview: UIImage?
    @State private var originalPreview: UIImage?    // unedited proxy, for the hold-to-compare overlay
    @State private var showOriginal = false
    @State private var showSaveOptions = false
    @State private var originalThumb: UIImage?
    @State private var filterThumbs: [String: UIImage] = [:]
    @State private var loadFailed = false
    @State private var rendering = false
    @State private var renderPending = false

    // Edit state + history
    @State private var recipe = EditRecipe()
    @State private var undoStack: [EditRecipe] = []
    @State private var redoStack: [EditRecipe] = []

    @State private var tab: Tab = .adjust
    @State private var selected: Adjustment = Adjustment.all[0]
    @State private var cropAspect: EditAspect = .freeform   // which crop chip is active (drag constraint)
    @State private var reshapeRadius: CGFloat = 0.18         // brush radius, fraction of image width
    @State private var reshapeStrength: CGFloat = 0.45       // 0…1, how much a drag pushes pixels
    @State private var cutoutMask: CIImage?                  // subject mask (proxy space) for background removal
    @State private var cutoutDetecting = false
    @State private var cutoutNoSubject = false
    @State private var editLandmarks: EditLandmarks?        // detected body + face, drives shaping warps
    @State private var bodyDetecting = false
    @State private var bodyNoPerson = false
    @State private var selectedBody = "slim"                // active body/face control chip
    @State private var selectedMakeup = "looks"             // active makeup category chip

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                previewArea
                controls
            }
        }
        .preferredColorScheme(.dark)
        .task { await load() }
        .onChange(of: tab) {
            if tab == .cutout { detectSubjectIfNeeded() }
            if tab == .body { detectBodyIfNeeded(); detectSubjectIfNeeded() }   // mask confines the warp
            if tab == .makeup { detectBodyIfNeeded() }   // makeup needs face landmarks
            scheduleRender()                      // crop tab shows the uncropped frame; others bake the crop
        }
        .confirmationDialog("Save Photo", isPresented: $showSaveOptions, titleVisibility: .visible) {
            Button("Save") { performSave(.none) }
            Button("Save at 1.5×") { performSave(.x1_5) }
            Button("Save at 2× (AI Upscale)") { performSave(.x2) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Upscale the saved photo?")
        }
    }

    /// Computes the subject mask once (off-main) the first time the Cut Out tab is opened.
    private func detectSubjectIfNeeded() {
        guard cutoutMask == nil, !cutoutDetecting, let proxy else { return }
        cutoutDetecting = true; cutoutNoSubject = false
        Task.detached(priority: .userInitiated) {
            let mask = PhotoEditorCutout.subjectMask(for: proxy)
            await MainActor.run {
                cutoutMask = mask
                cutoutNoSubject = (mask == nil)
                cutoutDetecting = false
                scheduleRender()             // re-render once the mask is ready (confines body shaping)
            }
        }
    }

    /// Detects body + face landmarks once (off-main) the first time the Body tab is opened.
    private func detectBodyIfNeeded() {
        guard editLandmarks == nil, !bodyDetecting, let proxy else { return }
        bodyDetecting = true; bodyNoPerson = false
        Task.detached(priority: .userInitiated) {
            let lm = EditLandmarks(body: BodyPose.detect(in: proxy), face: FaceDetect.detect(in: proxy))
            await MainActor.run {
                editLandmarks = lm.isEmpty ? nil : lm
                bodyNoPerson = lm.isEmpty
                bodyDetecting = false
            }
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 18) {
            Button("Cancel") { dismiss() }
            Spacer()
            compareButton
            Button { undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(undoStack.isEmpty)
            Button { redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(redoStack.isEmpty)
            Button { reset() } label: { Image(systemName: "arrow.counterclockwise") }
                .disabled(recipe.isIdentity)
            Spacer()
            Button { showSaveOptions = true } label: { Text("Save").fontWeight(.semibold) }
                .disabled(recipe.isIdentity)
        }
        .font(.body)
        .tint(.white)
        .padding(.horizontal)
        .padding(.vertical, 12)
    }

    /// Press and hold to peek at the unedited original (disabled when there are no edits to compare).
    private var compareButton: some View {
        Image(systemName: showOriginal ? "rectangle.fill.on.rectangle.fill" : "rectangle.on.rectangle")
            .font(.body)
            .foregroundStyle(recipe.isIdentity ? Color.secondary : Color.white)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !recipe.isIdentity, originalPreview != nil else { return }
                        if !showOriginal { withAnimation(.easeOut(duration: 0.1)) { showOriginal = true } }
                    }
                    .onEnded { _ in withAnimation(.easeOut(duration: 0.1)) { showOriginal = false } }
            )
            .accessibilityLabel("Hold to compare with original")
    }

    // MARK: - Preview

    private var previewArea: some View {
        ZStack {
            if let preview {
                if tab == .reshape {
                    // Pinch-zoom + two-finger pan (UIScrollView) with a one-finger reshape brush.
                    ReshapeCanvas(image: preview,
                                  brushRadius: reshapeRadius,
                                  onBegin: { reshaping = true; snapshot() },
                                  onPush: { p, d in applyReshape(at: p, delta: d) },
                                  onEnd: { reshaping = false; scheduleRender() })
                        .padding(10)
                } else if tab == .body || tab == .makeup {
                    // Pinch-zoom + pan so the user can zoom into a face/body area while adjusting.
                    ZoomablePreview(image: preview).padding(10)
                } else {
                    ZStack {
                        if recipe.cutout == .transparent {
                            CheckerboardView()                 // so removed areas read as transparent
                        }
                        Image(uiImage: preview)
                            .resizable()
                            .scaledToFit()
                            // No crossfade while dragging a warp — instant frames track the finger
                            // smoothly instead of trailing behind a 0.12s fade.
                            .animation(reshaping ? nil : .easeOut(duration: 0.12), value: preview)
                        if tab == .crop {
                            CropOverlay(box: cropBoxBinding,
                                        imageSize: preview.size,
                                        normalizedRatio: cropConstraint,
                                        onBegin: { snapshot() })
                        }
                    }
                    .padding(10)
                }
            } else if loadFailed {
                ContentUnavailableView("Couldn't open this photo", systemImage: "exclamationmark.triangle")
            } else {
                ProgressView().tint(.white)
            }

            // Hold-to-compare: the unedited original covers the edited preview while the button is held.
            if showOriginal, let originalPreview {
                Image(uiImage: originalPreview)
                    .resizable()
                    .scaledToFit()
                    .padding(10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
                    .overlay(alignment: .top) {
                        Text("Original")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(.top, 8)
                    }
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(spacing: 14) {
            switch tab {
            case .adjust:  adjustPanel
            case .filters: filterPanel
            case .crop:    cropPanel
            case .reshape: reshapePanel
            case .body:    bodyPanel
            case .makeup:  makeupPanel
            case .cutout:  cutoutPanel
            }
            tabBar
        }
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(.black)
    }

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 22) {
                ForEach(Tab.allCases) { t in
                    Button { tab = t } label: {
                        VStack(spacing: 4) {
                            Image(systemName: t.icon).font(.system(size: 18))
                            Text(t.title).font(.caption2)
                        }
                        .frame(minWidth: 44)
                        .foregroundStyle(tab == t ? Color.white : Color.secondary)
                    }
                }
            }
            .padding(.horizontal)
        }
        .padding(.top, 4)
    }

    // MARK: Adjust panel

    private var adjustPanel: some View {
        VStack(spacing: 12) {
            HStack {
                Text(selected.name).font(.subheadline.weight(.medium))
                Spacer()
                Text(valueLabel(selected)).font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)

            Slider(value: sliderBinding(for: selected), in: selected.range) { editing in
                if editing { snapshot() }
            }
            .tint(.white)
            .padding(.horizontal)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    autoChip
                    ForEach(Adjustment.all) { a in adjustChip(a) }
                }
                .padding(.horizontal)
            }
        }
    }

    private var autoChip: some View {
        Button { applyAuto() } label: {
            VStack(spacing: 6) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 20))
                    .frame(width: 52, height: 52)
                    .background(Circle().fill(Color.white.opacity(0.12)))
                Text("Auto").font(.caption2)
            }
            .foregroundStyle(.white)
        }
    }

    private func adjustChip(_ a: Adjustment) -> some View {
        let isSel = selected.id == a.id
        let edited = recipe[keyPath: a.keyPath] != 0
        return Button { selected = a } label: {
            VStack(spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: a.systemImage)
                        .font(.system(size: 20))
                        .frame(width: 52, height: 52)
                        .background(Circle().fill(isSel ? Color.white.opacity(0.22) : Color.white.opacity(0.08)))
                        .overlay(Circle().stroke(isSel ? Color.white : .clear, lineWidth: 1.5))
                    if edited {
                        Circle().fill(Color.yellow).frame(width: 9, height: 9).offset(x: 1, y: -1)
                    }
                }
                Text(a.name).font(.caption2)
            }
            .foregroundStyle(isSel ? Color.white : Color.secondary)
        }
    }

    // MARK: Filter panel

    private var filterPanel: some View {
        VStack(spacing: 12) {
            if recipe.filterID != nil {
                HStack {
                    Text("Intensity").font(.subheadline.weight(.medium))
                    Spacer()
                    Text("\(Int((recipe.filterIntensity * 100).rounded()))")
                        .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                }
                .padding(.horizontal)
                Slider(value: filterIntensityBinding, in: 0...1) { editing in
                    if editing { snapshot() }
                }
                .tint(.white)
                .padding(.horizontal)

                Toggle(isOn: Binding(
                    get: { recipe.filterBackgroundOnly },
                    set: { on in
                        commit { recipe.filterBackgroundOnly = on }
                        if on { detectSubjectIfNeeded() }
                    })) {
                    Label("Background only", systemImage: "person.crop.rectangle.badge.plus")
                        .font(.subheadline)
                }
                .tint(.white)
                .padding(.horizontal)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    filterTile(id: nil, name: "Original", thumb: originalThumb)
                    ForEach(EditFilter.all) { f in
                        filterTile(id: f.id, name: f.name, thumb: filterThumbs[f.id])
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    private func filterTile(id: String?, name: String, thumb: UIImage?) -> some View {
        let isSel = recipe.filterID == id
        return Button { selectFilter(id) } label: {
            VStack(spacing: 6) {
                Group {
                    if let thumb {
                        Image(uiImage: thumb).resizable().scaledToFill()
                    } else {
                        Color.white.opacity(0.08)
                    }
                }
                .frame(width: 60, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .stroke(isSel ? Color.white : Color.white.opacity(0.15), lineWidth: isSel ? 2 : 1))
                Text(name).font(.caption2)
            }
            .foregroundStyle(isSel ? Color.white : Color.secondary)
        }
    }

    // MARK: Crop / geometry panel

    private var cropPanel: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Straighten").font(.subheadline.weight(.medium))
                Spacer()
                Text("\(Int(recipe.straighten.rounded()))°")
                    .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            Slider(value: straightenBinding, in: -45...45) { editing in
                if editing { snapshot() }
            }
            .tint(.white)
            .padding(.horizontal)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    geomButton("rotate.left", "Left") {
                        commit { recipe.rotationQuarters = (recipe.rotationQuarters + 3) % 4 }
                    }
                    geomButton("rotate.right", "Right") {
                        commit { recipe.rotationQuarters = (recipe.rotationQuarters + 1) % 4 }
                    }
                    geomButton("arrow.left.and.right.righttriangle.left.righttriangle.right", "Flip H") {
                        commit { recipe.flipH.toggle() }
                    }
                    geomButton("arrow.up.and.down.righttriangle.up.righttriangle.down", "Flip V") {
                        commit { recipe.flipV.toggle() }
                    }
                    Divider().frame(height: 44).overlay(Color.white.opacity(0.2))
                    ForEach(EditAspect.allCases) { asp in
                        aspectChip(asp)
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    private func geomButton(_ icon: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 18))
                    .frame(width: 50, height: 50)
                    .background(Circle().fill(Color.white.opacity(0.08)))
                Text(label).font(.caption2)
            }
            .foregroundStyle(.white)
        }
    }

    private func aspectChip(_ asp: EditAspect) -> some View {
        let isSel = cropAspect == asp
        return Button { applyAspect(asp) } label: {
            VStack(spacing: 6) {
                Image(systemName: asp.systemImage).font(.system(size: 18))
                    .frame(width: 50, height: 50)
                    .background(Circle().fill(isSel ? Color.white.opacity(0.22) : Color.white.opacity(0.08)))
                    .overlay(Circle().stroke(isSel ? Color.white : .clear, lineWidth: 1.5))
                Text(asp.label).font(.caption2)
            }
            .foregroundStyle(isSel ? Color.white : Color.secondary)
        }
    }

    /// Selects a crop aspect: Original clears the crop, fixed ratios set a centered box of that ratio,
    /// Freeform keeps the current box but lets the user drag any rectangle. The interactive box on the
    /// preview then edits `recipe.cropRect` directly.
    private func applyAspect(_ asp: EditAspect) {
        commit {
            cropAspect = asp
            switch asp {
            case .original:
                recipe.cropRect = nil
            case .freeform:
                break                      // keep current crop; box stays draggable
            default:
                if let r = asp.fixedRatio, let box = centeredBox(pixelRatio: r) {
                    recipe.cropRect = box
                }
            }
        }
    }

    // MARK: - Crop helpers

    /// Live binding for the crop overlay. `nil` (no crop) reads as the full frame; a full-frame write
    /// collapses back to `nil` so an untouched crop doesn't count as an edit.
    private var cropBoxBinding: Binding<CGRect> {
        Binding(
            get: { recipe.cropRect ?? CGRect(x: 0, y: 0, width: 1, height: 1) },
            set: { recipe.cropRect = isFullRect($0) ? nil : $0 }
        )
    }

    private func isFullRect(_ r: CGRect) -> Bool {
        r.minX <= 0.001 && r.minY <= 0.001 && r.maxX >= 0.999 && r.maxY >= 0.999
    }

    /// Image ratio of the (post-geometry) preview, used to map pixel aspect ratios into the normalized
    /// crop space. The crop box is normalized to the *image*, so a pixel ratio R becomes R / imageRatio.
    private var previewImageRatio: CGFloat? {
        guard let sz = preview?.size, sz.width > 0, sz.height > 0 else { return nil }
        return sz.width / sz.height
    }

    /// The normalized w/h the crop box must keep for the active chip (nil = unconstrained Freeform).
    private var cropConstraint: CGFloat? {
        guard let rImg = previewImageRatio else { return nil }
        switch cropAspect {
        case .freeform: return nil
        case .original: return 1            // normalized 1:1 keeps the image's own ratio
        default:        return (cropAspect.fixedRatio ?? 1) / rImg
        }
    }

    /// A centered, maximal normalized crop rect for a target **pixel** ratio.
    private func centeredBox(pixelRatio R: CGFloat) -> CGRect? {
        guard let rImg = previewImageRatio else { return nil }
        let nr = R / rImg                   // normalized width/height
        var w: CGFloat, h: CGFloat
        if nr >= 1 { w = 1; h = 1 / nr } else { h = 1; w = nr }
        return CGRect(x: (1 - w) / 2, y: (1 - h) / 2, width: w, height: h)
    }

    // MARK: Cut-out panel

    private var cutoutPanel: some View {
        VStack(spacing: 12) {
            if cutoutDetecting {
                HStack(spacing: 8) {
                    ProgressView().tint(.white)
                    Text("Finding subject…").font(.subheadline).foregroundStyle(.secondary)
                }
            } else if cutoutNoSubject {
                Text("No subject found in this photo.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                Text("Replace the background").font(.caption).foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        cutoutChip(nil, label: "Original", systemImage: "photo")
                        ForEach(CutoutBackground.allCases) { bg in
                            cutoutChip(bg, label: bg.label, systemImage: bg.systemImage)
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
    }

    private func cutoutChip(_ bg: CutoutBackground?, label: String, systemImage: String) -> some View {
        let isSel = recipe.cutout == bg
        return Button { commit { recipe.cutout = bg } } label: {
            VStack(spacing: 6) {
                Image(systemName: systemImage).font(.system(size: 18))
                    .foregroundStyle(bg == .white ? .black : .white)
                    .frame(width: 52, height: 52)
                    .background(Circle().fill(swatchFill(bg, selected: isSel)))
                    .overlay(Circle().stroke(isSel ? Color.white : Color.white.opacity(0.15),
                                             lineWidth: isSel ? 2 : 1))
                Text(label).font(.caption2)
            }
            .foregroundStyle(isSel ? Color.white : Color.secondary)
        }
    }

    private func swatchFill(_ bg: CutoutBackground?, selected: Bool) -> Color {
        guard let bg else { return Color.white.opacity(selected ? 0.22 : 0.08) }
        switch bg {
        case .white: return .white
        case .black: return .black
        default:     return Color.white.opacity(selected ? 0.22 : 0.08)
        }
    }

    // MARK: Body panel

    private struct BodyControl: Identifiable {
        let id: String
        let name: String
        let systemImage: String
        let keyPath: WritableKeyPath<BodyShape, Double>
        let isFace: Bool
        var range: ClosedRange<Double> = -1 ... 1
    }

    private static let bodyControls: [BodyControl] = [
        .init(id: "slim",     name: "Slim",     systemImage: "arrow.left.and.right",        keyPath: \.slim,     isFace: false),
        .init(id: "waist",    name: "Waist",    systemImage: "arrow.right.and.line.vertical.and.arrow.left", keyPath: \.waist, isFace: false),
        .init(id: "hips",     name: "Hips",     systemImage: "oval.portrait",               keyPath: \.hips,     isFace: false),
        .init(id: "butt",     name: "Butt",     systemImage: "oval.fill",                   keyPath: \.butt,     isFace: false),
        .init(id: "breasts",  name: "Breasts",  systemImage: "heart",                       keyPath: \.breasts,  isFace: false),
        .init(id: "legs",     name: "Legs",     systemImage: "figure.walk",                 keyPath: \.legs,     isFace: false),
        .init(id: "height",   name: "Height",   systemImage: "arrow.up.and.down",           keyPath: \.height,   isFace: false),
        .init(id: "arms",     name: "Arms",     systemImage: "figure.arms.open",            keyPath: \.arms,     isFace: false),
        .init(id: "ankles",   name: "Ankles",   systemImage: "shoeprints.fill",             keyPath: \.ankles,   isFace: false),
        .init(id: "neck",     name: "Neck",     systemImage: "person.bust",                 keyPath: \.neck,     isFace: false, range: 0 ... 1),
        .init(id: "head",     name: "Head",     systemImage: "circle.dashed",               keyPath: \.head,     isFace: true),
        .init(id: "forehead", name: "Forehead", systemImage: "rectangle.tophalf.filled",    keyPath: \.forehead, isFace: true),
        .init(id: "eyes",     name: "Eyes",     systemImage: "eye",                         keyPath: \.eyes,     isFace: true),
        .init(id: "nose",     name: "Nose",     systemImage: "triangle",                    keyPath: \.nose,     isFace: true),
        .init(id: "ears",     name: "Ears",     systemImage: "ear",                         keyPath: \.ears,     isFace: true),
        .init(id: "chin",     name: "Chin",     systemImage: "mouth",                       keyPath: \.chin,     isFace: true),
        .init(id: "lips",     name: "Lips",     systemImage: "mouth.fill",                  keyPath: \.lips,     isFace: true),
        .init(id: "smile",    name: "Smile",    systemImage: "face.smiling",                keyPath: \.smile,    isFace: true),
    ]

    /// Only show chips whose landmark set was detected (body chips need a body, face chips need a face).
    private var availableBodyControls: [BodyControl] {
        let hasBody = editLandmarks?.body != nil
        let hasFace = editLandmarks?.face != nil
        return Self.bodyControls.filter { $0.isFace ? hasFace : hasBody }
    }

    private var bodyPanel: some View {
        VStack(spacing: 12) {
            if bodyDetecting {
                HStack(spacing: 8) {
                    ProgressView().tint(.white)
                    Text("Finding person…").font(.subheadline).foregroundStyle(.secondary)
                }
            } else if bodyNoPerson {
                Text("No person found in this photo.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                let controls = availableBodyControls
                if let sel = controls.first(where: { $0.id == selectedBody }) ?? controls.first {
                    HStack {
                        Text(sel.name).font(.subheadline.weight(.medium))
                        Spacer()
                        Text("\(Int((recipe.body[keyPath: sel.keyPath] * 100).rounded()))")
                            .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal)
                    Slider(value: bodyBinding(sel.keyPath), in: sel.range) { editing in
                        reshaping = editing                  // lighter proxy while dragging the warp
                        if editing { snapshot() } else { scheduleRender() }
                    }
                    .tint(.white)
                    .padding(.horizontal)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(controls) { c in bodyChip(c) }
                    }
                    .padding(.horizontal)
                }
            }
        }
    }

    private func bodyChip(_ c: BodyControl) -> some View {
        let isSel = selectedBody == c.id
        let edited = recipe.body[keyPath: c.keyPath] != 0
        return Button { selectedBody = c.id } label: {
            VStack(spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: c.systemImage)
                        .font(.system(size: 18))
                        .frame(width: 50, height: 50)
                        .background(Circle().fill(isSel ? Color.white.opacity(0.22) : Color.white.opacity(0.08)))
                        .overlay(Circle().stroke(isSel ? Color.white : .clear, lineWidth: 1.5))
                    if edited {
                        Circle().fill(Color.yellow).frame(width: 9, height: 9).offset(x: 1, y: -1)
                    }
                }
                Text(c.name).font(.caption2)
            }
            .foregroundStyle(isSel ? Color.white : Color.secondary)
        }
    }

    private func bodyBinding(_ keyPath: WritableKeyPath<BodyShape, Double>) -> Binding<Double> {
        Binding(get: { recipe.body[keyPath: keyPath] },
                set: { recipe.body[keyPath: keyPath] = $0; scheduleRender() })
    }

    // MARK: Makeup panel

    private struct MakeupCat: Identifiable {
        let id: String; let name: String; let systemImage: String
    }
    private static let makeupCats: [MakeupCat] = [
        .init(id: "looks",    name: "Looks",     systemImage: "sparkles"),
        .init(id: "lips",     name: "Lips",      systemImage: "mouth.fill"),
        .init(id: "blush",    name: "Blush",     systemImage: "circle.fill"),
        .init(id: "shadow",   name: "Shadow",    systemImage: "eye.fill"),
        .init(id: "liner",    name: "Liner",     systemImage: "pencil.tip"),
        .init(id: "lashes",   name: "Lashes",    systemImage: "eye"),
        .init(id: "brows",    name: "Brows",     systemImage: "eyebrow"),
        .init(id: "freckles", name: "Freckles",  systemImage: "circle.dotted"),
    ]
    private static let lipColors = [
        MakeupColor(0.80, 0.12, 0.24), MakeupColor(0.88, 0.34, 0.40), MakeupColor(0.91, 0.47, 0.40),
        MakeupColor(0.72, 0.42, 0.40), MakeupColor(0.56, 0.10, 0.28), MakeupColor(0.46, 0.13, 0.30),
    ]
    private static let blushColors = [
        MakeupColor(0.94, 0.42, 0.46), MakeupColor(0.96, 0.56, 0.45),
        MakeupColor(0.90, 0.50, 0.56), MakeupColor(0.86, 0.34, 0.34),
    ]
    private static let shadowColors = [
        MakeupColor(0.52, 0.30, 0.42), MakeupColor(0.45, 0.30, 0.20), MakeupColor(0.62, 0.46, 0.26),
        MakeupColor(0.40, 0.20, 0.36), MakeupColor(0.36, 0.36, 0.41),
    ]
    private struct MakeupLook: Identifiable { let id: String; let recipe: MakeupRecipe }
    private static let makeupLooks: [MakeupLook] = [
        MakeupLook(id: "Natural", recipe: { var m = MakeupRecipe(); m.lips = 0.30; m.lipsColor = MakeupColor(0.84, 0.46, 0.42)
            m.blush = 0.30; m.brows = 0.20; return m }()),
        MakeupLook(id: "Glam", recipe: { var m = MakeupRecipe(); m.lips = 0.55; m.eyeshadow = 0.45; m.eyeliner = 0.7
            m.lashes = 0.5; m.blush = 0.35; m.brows = 0.3; return m }()),
        MakeupLook(id: "Bold", recipe: { var m = MakeupRecipe(); m.lips = 0.7; m.lipsColor = MakeupColor(0.78, 0.08, 0.20)
            m.eyeliner = 0.6; m.brows = 0.3; return m }()),
        MakeupLook(id: "Sweet", recipe: { var m = MakeupRecipe(); m.lips = 0.4; m.lipsColor = MakeupColor(0.90, 0.45, 0.50)
            m.blush = 0.5; m.blushColor = MakeupColor(0.96, 0.56, 0.55); m.freckles = 2; return m }()),
        MakeupLook(id: "Smoky", recipe: { var m = MakeupRecipe(); m.eyeshadow = 0.6; m.eyeshadowColor = MakeupColor(0.36, 0.34, 0.40)
            m.eyeliner = 0.8; m.lashes = 0.7; m.lips = 0.35; m.lipsColor = MakeupColor(0.70, 0.42, 0.40); return m }()),
        MakeupLook(id: "Gothic", recipe: { var m = MakeupRecipe(); m.lips = 1.0; m.lipsColor = MakeupColor(0.02, 0.02, 0.03)
            m.eyeshadow = 1.0; m.eyeshadowColor = MakeupColor(0.03, 0.03, 0.05); m.eyeliner = 1.0; m.lashes = 0.9
            m.brows = 0.5; return m }()),
        MakeupLook(id: "Bronze", recipe: { var m = MakeupRecipe(); m.eyeshadow = 0.5; m.eyeshadowColor = MakeupColor(0.60, 0.42, 0.22)
            m.lips = 0.40; m.lipsColor = MakeupColor(0.85, 0.45, 0.38); m.blush = 0.4; m.blushColor = MakeupColor(0.92, 0.55, 0.42)
            m.brows = 0.25; m.freckles = 1; return m }()),
        MakeupLook(id: "Vintage", recipe: { var m = MakeupRecipe(); m.lips = 0.6; m.lipsColor = MakeupColor(0.74, 0.10, 0.16)
            m.eyeliner = 0.45; m.brows = 0.3; m.blush = 0.25; return m }()),
        MakeupLook(id: "Doll", recipe: { var m = MakeupRecipe(); m.lashes = 0.85; m.eyeliner = 0.45
            m.lips = 0.5; m.lipsColor = MakeupColor(0.92, 0.42, 0.52); m.blush = 0.5; m.blushColor = MakeupColor(0.96, 0.55, 0.58)
            m.freckles = 2; return m }()),
        MakeupLook(id: "Editorial", recipe: { var m = MakeupRecipe(); m.eyeshadow = 0.6; m.eyeshadowColor = MakeupColor(0.55, 0.25, 0.30)
            m.eyeliner = 0.8; m.lips = 0.4; m.lipsColor = MakeupColor(0.72, 0.42, 0.40); m.brows = 0.3; return m }()),
    ]

    private var makeupPanel: some View {
        VStack(spacing: 12) {
            if bodyDetecting {
                HStack(spacing: 8) {
                    ProgressView().tint(.white)
                    Text("Finding face…").font(.subheadline).foregroundStyle(.secondary)
                }
            } else if editLandmarks?.face == nil {
                Text("No face found in this photo.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                makeupControls(for: selectedMakeup)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(Self.makeupCats) { c in makeupCatChip(c) }
                    }
                    .padding(.horizontal)
                }
            }
        }
    }

    @ViewBuilder
    private func makeupControls(for cat: String) -> some View {
        switch cat {
        case "lips":     makeupItem("Lips", \.lips, color: \.lipsColor, palette: Self.lipColors)
        case "blush":    makeupItem("Blush", \.blush, color: \.blushColor, palette: Self.blushColors)
        case "shadow":   makeupItem("Eyeshadow", \.eyeshadow, color: \.eyeshadowColor, palette: Self.shadowColors)
        case "liner":    makeupSlider("Eyeliner", \.eyeliner)
        case "lashes":   makeupSlider("Lashes", \.lashes)
        case "brows":    makeupSlider("Brows", \.brows)
        case "freckles": freckleControls
        default:         looksControls
        }
    }

    private var looksControls: some View {
        VStack(spacing: 10) {
            if !recipe.makeup.isZero {
                HStack {
                    Text("Strength").font(.subheadline.weight(.medium))
                    Spacer()
                    Text("\(Int((recipe.makeup.strength * 100).rounded()))")
                        .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                }
                .padding(.horizontal)
                Slider(value: makeupBinding(\.strength), in: 0...1) { editing in
                    reshaping = editing
                    if editing { snapshot() } else { scheduleRender() }
                }
                .tint(.white)
                .padding(.horizontal)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    Button { commit { recipe.makeup = MakeupRecipe() } } label: { lookLabel("None", on: recipe.makeup.isZero) }
                    ForEach(Self.makeupLooks) { look in
                        Button { commit { recipe.makeup = look.recipe } } label: {
                            lookLabel(look.id, on: recipe.makeup == look.recipe)
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    private func lookLabel(_ name: String, on: Bool) -> some View {
        Text(name)
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 16).padding(.vertical, 9)
            .background(Capsule().fill(on ? Color.white.opacity(0.22) : Color.white.opacity(0.08)))
            .overlay(Capsule().stroke(on ? Color.white : .clear, lineWidth: 1.5))
            .foregroundStyle(on ? Color.white : Color.secondary)
    }

    private var freckleControls: some View {
        VStack(spacing: 8) {
            Text("Freckles — none to lots").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                ForEach(0...5, id: \.self) { lvl in
                    Button { commit { recipe.makeup.freckles = lvl } } label: {
                        Text(lvl == 0 ? "None" : "\(lvl)")
                            .font(.subheadline).frame(width: 46, height: 38)
                            .background(RoundedRectangle(cornerRadius: 9)
                                .fill(recipe.makeup.freckles == lvl ? Color.white.opacity(0.22) : Color.white.opacity(0.08)))
                            .overlay(RoundedRectangle(cornerRadius: 9)
                                .stroke(recipe.makeup.freckles == lvl ? Color.white : .clear, lineWidth: 1.5))
                            .foregroundStyle(recipe.makeup.freckles == lvl ? Color.white : Color.secondary)
                    }
                }
            }
        }
        .padding(.horizontal)
    }

    private func makeupItem(_ name: String, _ intensity: WritableKeyPath<MakeupRecipe, Double>,
                            color: WritableKeyPath<MakeupRecipe, MakeupColor>, palette: [MakeupColor]) -> some View {
        VStack(spacing: 10) {
            makeupSlider(name, intensity)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(palette.indices, id: \.self) { i in
                        let c = palette[i]
                        let sel = recipe.makeup[keyPath: color] == c
                        Button { commit { recipe.makeup[keyPath: color] = c } } label: {
                            Circle().fill(Color(red: c.r, green: c.g, blue: c.b))
                                .frame(width: 30, height: 30)
                                .overlay(Circle().stroke(sel ? Color.white : Color.white.opacity(0.3),
                                                         lineWidth: sel ? 2.5 : 1))
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    private func makeupSlider(_ name: String, _ keyPath: WritableKeyPath<MakeupRecipe, Double>) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(name).font(.subheadline.weight(.medium))
                Spacer()
                Text("\(Int((recipe.makeup[keyPath: keyPath] * 100).rounded()))")
                    .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: makeupBinding(keyPath), in: 0...1) { editing in
                reshaping = editing                  // lighter proxy while scrubbing the overlay
                if editing { snapshot() } else { scheduleRender() }
            }
            .tint(.white)
        }
        .padding(.horizontal)
    }

    private func makeupCatChip(_ c: MakeupCat) -> some View {
        let isSel = selectedMakeup == c.id
        return Button { selectedMakeup = c.id } label: {
            VStack(spacing: 6) {
                Image(systemName: c.systemImage).font(.system(size: 17))
                    .frame(width: 48, height: 48)
                    .background(Circle().fill(isSel ? Color.white.opacity(0.22) : Color.white.opacity(0.08)))
                    .overlay(Circle().stroke(isSel ? Color.white : .clear, lineWidth: 1.5))
                Text(c.name).font(.caption2)
            }
            .foregroundStyle(isSel ? Color.white : Color.secondary)
        }
    }

    private func makeupBinding(_ keyPath: WritableKeyPath<MakeupRecipe, Double>) -> Binding<Double> {
        Binding(get: { recipe.makeup[keyPath: keyPath] },
                set: { recipe.makeup[keyPath: keyPath] = $0; scheduleRender() })
    }

    // MARK: Reshape panel

    private var reshapePanel: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Drag on the photo to push pixels").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { commit { recipe.reshape = nil } } label: {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                }
                .font(.caption).tint(.white)
                .disabled(recipe.reshape == nil)
            }
            .padding(.horizontal)

            labeledSlider("Size", systemImage: "circle.dashed",
                          value: $reshapeRadius, range: 0.06...0.4)
            labeledSlider("Strength", systemImage: "scribble.variable",
                          value: $reshapeStrength, range: 0.1...1.0)
        }
    }

    private func labeledSlider(_ title: String, systemImage: String,
                               value: Binding<CGFloat>, range: ClosedRange<CGFloat>) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage).font(.system(size: 15)).frame(width: 22)
            Text(title).font(.subheadline).frame(width: 70, alignment: .leading)
            Slider(value: Binding(get: { Double(value.wrappedValue) },
                                  set: { value.wrappedValue = CGFloat($0) }),
                   in: Double(range.lowerBound)...Double(range.upperBound))
                .tint(.white)
        }
        .padding(.horizontal)
    }

    /// Accumulates a push at normalized point `p` (top-down) in normalized drag direction `delta` into
    /// the reshape mesh, with a smooth round-brush falloff, then re-renders.
    private func applyReshape(at p: CGPoint, delta: CGSize) {
        guard let aspect = previewImageRatio else { return }
        var f = recipe.reshape ?? ReshapeField()
        let cols = f.cols, rows = f.rows
        let r = Double(reshapeRadius)
        let strength = Double(reshapeStrength)
        let dxn = Double(delta.width), dyn = Double(delta.height)
        guard r > 0, (dxn != 0 || dyn != 0) else { return }

        for j in 1..<(rows - 1) {
            for i in 1..<(cols - 1) {
                let vu = Double(i) / Double(cols - 1)
                let vv = Double(j) / Double(rows - 1)
                let ax = vu - Double(p.x)
                let ay = (vv - Double(p.y)) / Double(aspect)   // aspect-correct → round brush in pixels
                let dist = (ax * ax + ay * ay).squareRoot()
                guard dist < r else { continue }
                let t = 1 - dist / r
                let fall = t * t * (3 - 2 * t)                  // smoothstep
                let idx = j * cols + i
                f.dx[idx] = clampDisp(f.dx[idx] + dxn * strength * fall)
                f.dy[idx] = clampDisp(f.dy[idx] + dyn * strength * fall)
            }
        }
        recipe.reshape = f.isZero ? nil : f
        scheduleRender()
    }

    private func clampDisp(_ v: Double) -> Double { max(-0.3, min(0.3, v)) }

    // MARK: - Bindings

    private func sliderBinding(for a: Adjustment) -> Binding<Double> {
        Binding(get: { recipe[keyPath: a.keyPath] },
                set: { recipe[keyPath: a.keyPath] = $0; scheduleRender() })
    }
    private var filterIntensityBinding: Binding<Double> {
        Binding(get: { recipe.filterIntensity },
                set: { recipe.filterIntensity = $0; scheduleRender() })
    }
    private var straightenBinding: Binding<Double> {
        Binding(get: { recipe.straighten },
                set: { recipe.straighten = $0; scheduleRender() })
    }

    private func valueLabel(_ a: Adjustment) -> String {
        let v = recipe[keyPath: a.keyPath]
        let n = Int((v * 100).rounded())
        return a.bipolar && n > 0 ? "+\(n)" : "\(n)"
    }

    // MARK: - Edit actions (undo-aware)

    /// Records the current recipe for undo, then performs a discrete change and re-renders.
    private func commit(_ change: () -> Void) {
        snapshot()
        change()
        scheduleRender()
    }
    private func snapshot() {
        undoStack.append(recipe)
        redoStack.removeAll()
        if undoStack.count > 40 { undoStack.removeFirst() }
    }
    private func undo() {
        guard let last = undoStack.popLast() else { return }
        redoStack.append(recipe)
        recipe = last
        scheduleRender()
    }
    private func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(recipe)
        recipe = next
        scheduleRender()
    }
    private func reset() {
        guard !recipe.isIdentity else { return }
        commit { recipe = EditRecipe() }
    }
    private func selectFilter(_ id: String?) {
        commit {
            recipe.filterID = id
            if id != nil, recipe.filterIntensity == 0 { recipe.filterIntensity = 1 }
        }
    }
    private func applyAuto() {
        guard let proxy else { return }
        let base = recipe
        Task.detached(priority: .userInitiated) {
            let r = PhotoEditorIO.autoRecipe(for: proxy, base: base)
            await MainActor.run {
                snapshot()
                recipe = r
                scheduleRender()
            }
        }
    }

    // MARK: - Rendering

    /// In the Crop tab the preview shows the full (uncropped) frame so the crop box can be dragged over
    /// it; everywhere else the live crop is baked in. Geometry (rotate/flip/straighten) always applies.
    private var renderRecipe: EditRecipe {
        guard tab == .crop else { return recipe }
        var r = recipe; r.cropRect = nil; return r
    }

    /// Renders the current recipe over the proxy off-main. Single-flight: at most one render runs at a
    /// time and the newest state always renders last, so rapid input (reshape/crop drags, slider scrubs)
    /// coalesces instead of spawning a backlog of full rasterizations.
    private func scheduleRender() {
        guard let proxy else { return }
        if rendering { renderPending = true; return }
        rendering = true
        let src = reshaping ? (fastProxy ?? proxy) : proxy
        let r = renderRecipe
        let mask = cutoutMask
        let landmarks = editLandmarks
        let fast = reshaping
        Task.detached(priority: .userInitiated) {
            let img = PhotoEditorIO.renderUIImage(src, recipe: r, mask: mask, landmarks: landmarks, fast: fast)
            await MainActor.run {
                rendering = false
                if let img { preview = img }
                if renderPending { renderPending = false; scheduleRender() }
            }
        }
    }

    private func load() async {
        let url = entry.url
        let loaded = await Task.detached(priority: .userInitiated) { PhotoEditorIO.load(url: url) }.value
        guard let loaded else { loadFailed = true; return }
        let p = PhotoEditorIO.proxy(loaded.image, maxDimension: 2200)   // higher-res preview → stays sharp when zoomed
        proxy = p
        fastProxy = PhotoEditorIO.proxy(p, maxDimension: 1000)   // lighter render → higher FPS while dragging a warp
        scheduleRender()
        originalPreview = await Task.detached(priority: .utility) {
            PhotoEditorIO.renderUIImage(p, recipe: EditRecipe())   // unedited proxy for compare
        }.value
        // Build the filter strip + the "Original" tile off-main.
        let thumbs = await Task.detached(priority: .utility) { () -> (UIImage?, [String: UIImage]) in
            let small = PhotoEditorIO.proxy(p, maxDimension: 200)
            let orig = PhotoEditorIO.renderUIImage(small, recipe: EditRecipe())
            var out: [String: UIImage] = [:]
            for f in EditFilter.all {
                var fr = EditRecipe(); fr.filterID = f.id; fr.filterIntensity = 1
                if let img = PhotoEditorIO.renderUIImage(small, recipe: fr) { out[f.id] = img }
            }
            return (orig, out)
        }.value
        originalThumb = thumbs.0
        filterThumbs = thumbs.1
    }

    // MARK: - Save

    private func performSave(_ upscale: PhotoEditorIO.Upscale) {
        guard !recipe.isIdentity else { dismiss(); return }
        let r = recipe
        let src = entry.url
        let title = upscale == .none ? "Saving edited photo…" : "Saving & upscaling photo…"
        let id = library.beginActivity(title, indeterminate: true)
        dismiss()
        Task.detached(priority: .userInitiated) {
            // A transparent cut-out needs an alpha-capable format (PNG). HDR sources save as 10-bit
            // HEIC to keep the headroom. Otherwise match the source.
            let fmt: PhotoEditorIO.ExportFormat
            if r.cutout == .transparent {
                fmt = .png
            } else if PhotoEditorIO.isHDRSource(src) {
                fmt = .heic
            } else {
                fmt = PhotoEditorIO.format(forSource: src)
            }
            let dest = PhotoEditorIO.editedDestination(for: src, format: fmt)
            let ok = PhotoEditorIO.save(recipe: r, sourceURL: src, to: dest, format: fmt, upscale: upscale)
            await MainActor.run {
                library.endActivity(id, result: ok ? "Saved edited photo" : "Couldn’t save the edit")
                if ok { library.contentDidChange() }
            }
        }
    }
}

/// Interactive crop rectangle drawn over the (uncropped) preview. Edits a normalized **top-left** rect
/// (`box`, 0…1 within the image). Drag the interior to move, drag a corner to resize; when
/// `normalizedRatio` is set the box keeps that width/height (fixed-ratio chips), otherwise it's free.
private struct CropOverlay: View {
    @Binding var box: CGRect
    let imageSize: CGSize
    let normalizedRatio: CGFloat?
    let onBegin: () -> Void

    private enum Corner: CaseIterable { case topLeft, topRight, bottomLeft, bottomRight }
    @State private var startBox: CGRect?

    var body: some View {
        GeometryReader { geo in
            let frame = fittedRect(in: geo.size)
            let r = viewRect(in: frame)
            ZStack(alignment: .topLeading) {
                Path { p in
                    p.addRect(CGRect(origin: .zero, size: geo.size))
                    p.addRect(r)
                }
                .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)

                Rectangle().stroke(Color.white, lineWidth: 1)
                    .frame(width: r.width, height: r.height).position(x: r.midX, y: r.midY)
                    .allowsHitTesting(false)
                gridLines(r).allowsHitTesting(false)

                Color.white.opacity(0.001)
                    .frame(width: r.width, height: r.height).position(x: r.midX, y: r.midY)
                    .gesture(moveGesture(frame: frame))

                ForEach(Corner.allCases, id: \.self) { c in
                    cornerHandle.position(point(of: c, in: r))
                        .gesture(resizeGesture(c, frame: frame))
                }
            }
        }
    }

    private var cornerHandle: some View {
        ZStack {
            Color.clear.frame(width: 44, height: 44).contentShape(Rectangle())
            RoundedRectangle(cornerRadius: 2).fill(Color.white)
                .frame(width: 18, height: 18).shadow(radius: 1)
        }
    }

    private func gridLines(_ r: CGRect) -> some View {
        Path { p in
            for i in 1...2 {
                let x = r.minX + r.width * CGFloat(i) / 3
                p.move(to: CGPoint(x: x, y: r.minY)); p.addLine(to: CGPoint(x: x, y: r.maxY))
                let y = r.minY + r.height * CGFloat(i) / 3
                p.move(to: CGPoint(x: r.minX, y: y)); p.addLine(to: CGPoint(x: r.maxX, y: y))
            }
        }
        .stroke(Color.white.opacity(0.4), lineWidth: 0.5)
    }

    // MARK: Coordinate mapping

    private func fittedRect(in bounds: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, bounds.width > 0, bounds.height > 0
        else { return CGRect(origin: .zero, size: bounds) }
        let s = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let w = imageSize.width * s, h = imageSize.height * s
        return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }

    private func viewRect(in frame: CGRect) -> CGRect {
        CGRect(x: frame.minX + box.minX * frame.width,
               y: frame.minY + box.minY * frame.height,
               width: box.width * frame.width, height: box.height * frame.height)
    }

    private func point(of c: Corner, in r: CGRect) -> CGPoint {
        switch c {
        case .topLeft:     return CGPoint(x: r.minX, y: r.minY)
        case .topRight:    return CGPoint(x: r.maxX, y: r.minY)
        case .bottomLeft:  return CGPoint(x: r.minX, y: r.maxY)
        case .bottomRight: return CGPoint(x: r.maxX, y: r.maxY)
        }
    }

    // MARK: Gestures

    private func moveGesture(frame: CGRect) -> some Gesture {
        DragGesture()
            .onChanged { v in
                if startBox == nil { startBox = box; onBegin() }
                guard let s = startBox, frame.width > 0, frame.height > 0 else { return }
                let dx = v.translation.width / frame.width
                let dy = v.translation.height / frame.height
                var nb = s
                nb.origin.x = min(max(s.minX + dx, 0), 1 - s.width)
                nb.origin.y = min(max(s.minY + dy, 0), 1 - s.height)
                box = nb
            }
            .onEnded { _ in startBox = nil }
    }

    private func resizeGesture(_ c: Corner, frame: CGRect) -> some Gesture {
        DragGesture()
            .onChanged { v in
                if startBox == nil { startBox = box; onBegin() }
                guard let s = startBox, frame.width > 0, frame.height > 0 else { return }
                let dx = v.translation.width / frame.width
                let dy = v.translation.height / frame.height
                box = resized(corner: c, start: s, dx: dx, dy: dy)
            }
            .onEnded { _ in startBox = nil }
    }

    /// Resizes by moving `corner` while its opposite corner stays fixed; keeps `normalizedRatio` when set.
    private func resized(corner c: Corner, start s: CGRect, dx: CGFloat, dy: CGFloat) -> CGRect {
        let minS: CGFloat = 0.08
        let fx: CGFloat, fy: CGFloat, sx: CGFloat, sy: CGFloat, mStartX: CGFloat, mStartY: CGFloat
        switch c {
        case .topLeft:     fx = s.maxX; fy = s.maxY; sx = -1; sy = -1; mStartX = s.minX; mStartY = s.minY
        case .topRight:    fx = s.minX; fy = s.maxY; sx =  1; sy = -1; mStartX = s.maxX; mStartY = s.minY
        case .bottomLeft:  fx = s.maxX; fy = s.minY; sx = -1; sy =  1; mStartX = s.minX; mStartY = s.maxY
        case .bottomRight: fx = s.minX; fy = s.minY; sx =  1; sy =  1; mStartX = s.maxX; mStartY = s.maxY
        }
        let mx = min(max(mStartX + dx, 0), 1)
        let my = min(max(mStartY + dy, 0), 1)
        let roomX = sx > 0 ? 1 - fx : fx
        let roomY = sy > 0 ? 1 - fy : fy
        var w = min(max(abs(mx - fx), minS), roomX)
        var h = min(max(abs(my - fy), minS), roomY)
        if let nr = normalizedRatio {
            if w / h > nr { w = h * nr } else { h = w / nr }
            if w > roomX { w = roomX; h = w / nr }
            if h > roomY { h = roomY; w = h * nr }
            w = max(w, minS); h = max(h, minS)
        }
        let nmx = fx + sx * w, nmy = fy + sy * h
        return CGRect(x: min(fx, nmx), y: min(fy, nmy), width: w, height: h)
    }
}

/// Zoomable canvas for the reshape brush. A `UIScrollView` provides pinch-to-zoom and two-finger pan
/// (its built-in pan is set to require two fingers), leaving one-finger drags for the brush — so the
/// user can zoom in and still reshape without gesture conflicts. The brush reports the touch point and
/// incremental delta normalized to the (unzoomed) image, plus a zoom-aware ring for feedback. Touches
/// are read in the image view's own coordinate space, so the normalization stays correct at any zoom.
private struct ReshapeCanvas: UIViewRepresentable {
    let image: UIImage
    let brushRadius: CGFloat                    // fraction of image width
    let onBegin: () -> Void
    let onPush: (CGPoint, CGSize) -> Void       // normalized point (top-down) + normalized delta
    let onEnd: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> ReshapeScrollView {
        let sv = ReshapeScrollView()
        sv.delegate = context.coordinator
        sv.backgroundColor = .clear
        sv.contentInsetAdjustmentBehavior = .never
        sv.showsVerticalScrollIndicator = false
        sv.showsHorizontalScrollIndicator = false
        sv.bouncesZoom = true
        sv.panGestureRecognizer.minimumNumberOfTouches = 2   // one finger stays free for the brush
        sv.imageView.contentMode = .scaleAspectFit
        sv.imageView.isUserInteractionEnabled = true
        sv.addSubview(sv.imageView)
        sv.setImage(image)
        context.coordinator.scroll = sv

        let brush = UIPanGestureRecognizer(target: context.coordinator,
                                           action: #selector(Coordinator.handleBrush(_:)))
        brush.maximumNumberOfTouches = 1
        brush.delegate = context.coordinator
        sv.imageView.addGestureRecognizer(brush)

        let doubleTap = UITapGestureRecognizer(target: context.coordinator,
                                               action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        sv.addGestureRecognizer(doubleTap)

        return sv
    }

    func updateUIView(_ sv: ReshapeScrollView, context: Context) {
        context.coordinator.parent = self
        if sv.imageView.image !== image { sv.setImage(image) }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        var parent: ReshapeCanvas
        weak var scroll: ReshapeScrollView?
        private var last: CGPoint?
        private let ring = CAShapeLayer()

        init(_ parent: ReshapeCanvas) {
            self.parent = parent
            super.init()
            ring.fillColor = UIColor.clear.cgColor
            ring.strokeColor = UIColor.white.withAlphaComponent(0.85).cgColor
            ring.lineWidth = 1.5
            ring.isHidden = true
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            (scrollView as? ReshapeScrollView)?.imageView
        }
        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            (scrollView as? ReshapeScrollView)?.centerContent()
        }
        // The brush coexists with the scroll view's pinch/pan recognizers.
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        @objc func handleBrush(_ g: UIPanGestureRecognizer) {
            guard let iv = scroll?.imageView else { return }
            let size = iv.bounds.size
            guard size.width > 0, size.height > 0 else { return }
            let loc = g.location(in: iv)
            switch g.state {
            case .began:
                last = loc
                parent.onBegin()
                if ring.superlayer == nil { iv.layer.addSublayer(ring) }
                updateRing(at: loc, in: size); ring.isHidden = false
            case .changed:
                let prev = last ?? loc
                last = loc
                let p = CGPoint(x: clamp01(loc.x / size.width), y: clamp01(loc.y / size.height))
                let d = CGSize(width: (loc.x - prev.x) / size.width, height: (loc.y - prev.y) / size.height)
                parent.onPush(p, d)
                updateRing(at: loc, in: size)
            case .ended, .cancelled, .failed:
                last = nil; ring.isHidden = true; parent.onEnd()
            default: break
            }
        }

        @objc func handleDoubleTap(_ g: UITapGestureRecognizer) {
            guard let sv = scroll else { return }
            if sv.zoomScale > sv.minimumZoomScale + 0.01 {
                sv.setZoomScale(sv.minimumZoomScale, animated: true)
            } else {
                let p = g.location(in: sv.imageView)
                let scale = min(sv.maximumZoomScale, 2.5)
                let w = sv.bounds.width / scale, h = sv.bounds.height / scale
                sv.zoom(to: CGRect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h), animated: true)
            }
        }

        private func updateRing(at loc: CGPoint, in size: CGSize) {
            ring.path = UIBezierPath(arcCenter: loc, radius: parent.brushRadius * size.width,
                                     startAngle: 0, endAngle: .pi * 2, clockwise: true).cgPath
            if let z = scroll?.zoomScale, z > 0 { ring.lineWidth = 1.5 / z }   // ~constant on-screen width
        }

        private func clamp01(_ v: CGFloat) -> CGFloat { min(max(v, 0), 1) }
    }
}

/// A centering scroll view for `ReshapeCanvas`. It fits the image to the view at zoom 1 and reconfigures
/// only when the image **aspect** changes — so swapping in a different-resolution render of the same
/// photo (the fast vs. full reshape proxy) keeps the current zoom instead of snapping back.
private final class ReshapeScrollView: UIScrollView {
    let imageView = UIImageView()
    private var aspect: CGFloat = 0
    private var fitSize: CGSize = .zero
    private var configured = false
    private var lastBounds: CGSize = .zero

    func setImage(_ image: UIImage) {
        imageView.image = image
        let a = image.size.height > 0 ? image.size.width / image.size.height : 0
        // Only re-fit (which resets zoom) on a *real* aspect change. The fast vs. full reshape proxy
        // differ by a hair from integer pixel rounding; a tight threshold would re-fit mid-stroke and
        // kick the user back to fit. A genuine change (rotate/crop) moves the aspect far more than this.
        if abs(a - aspect) > 0.02 { aspect = a; configured = false; setNeedsLayout() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard aspect > 0, bounds.width > 0, bounds.height > 0 else { return }
        if !configured || lastBounds != bounds.size {
            configure(); configured = true; lastBounds = bounds.size
        }
        centerContent()
    }

    private func configure() {
        var w = bounds.width, h = bounds.width / aspect
        if h > bounds.height { h = bounds.height; w = bounds.height * aspect }
        fitSize = CGSize(width: w, height: h)
        zoomScale = 1
        minimumZoomScale = 1
        maximumZoomScale = 6
        imageView.frame = CGRect(origin: .zero, size: fitSize)
        contentSize = fitSize
    }

    func centerContent() {
        let ox = max(0, (bounds.width - imageView.frame.width) / 2)
        let oy = max(0, (bounds.height - imageView.frame.height) / 2)
        imageView.center = CGPoint(x: imageView.frame.width / 2 + ox,
                                   y: imageView.frame.height / 2 + oy)
    }
}

/// A neutral checkerboard backdrop shown behind a transparent cut-out so the removed area reads as
/// "see-through" rather than black.
private struct CheckerboardView: View {
    var body: some View {
        Canvas { ctx, size in
            let s: CGFloat = 14
            let cols = Int(size.width / s) + 1, rows = Int(size.height / s) + 1
            for row in 0..<rows {
                for col in 0..<cols where (row + col) % 2 == 0 {
                    let rect = CGRect(x: CGFloat(col) * s, y: CGFloat(row) * s, width: s, height: s)
                    ctx.fill(Path(rect), with: .color(.white.opacity(0.18)))
                }
            }
        }
        .background(Color.white.opacity(0.06))
    }
}

/// Pinch-zoom + pan preview (no brush) for the Body and Makeup tabs, so the user can zoom into a region
/// while scrubbing sliders. Reuses `ReshapeScrollView`, which re-fits only on aspect change — so the
/// fast/full proxy swap during a drag keeps the current zoom.
private struct ZoomablePreview: UIViewRepresentable {
    let image: UIImage

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ReshapeScrollView {
        let sv = ReshapeScrollView()
        sv.delegate = context.coordinator
        sv.backgroundColor = .clear
        sv.contentInsetAdjustmentBehavior = .never
        sv.showsVerticalScrollIndicator = false
        sv.showsHorizontalScrollIndicator = false
        sv.bouncesZoom = true
        sv.imageView.contentMode = .scaleAspectFit
        sv.addSubview(sv.imageView)
        sv.setImage(image)
        context.coordinator.scroll = sv

        let doubleTap = UITapGestureRecognizer(target: context.coordinator,
                                               action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        sv.addGestureRecognizer(doubleTap)
        return sv
    }

    func updateUIView(_ sv: ReshapeScrollView, context: Context) {
        if sv.imageView.image !== image { sv.setImage(image) }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var scroll: ReshapeScrollView?
        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            (scrollView as? ReshapeScrollView)?.imageView
        }
        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            (scrollView as? ReshapeScrollView)?.centerContent()
        }
        @objc func handleDoubleTap(_ g: UITapGestureRecognizer) {
            guard let sv = scroll else { return }
            if sv.zoomScale > sv.minimumZoomScale + 0.01 {
                sv.setZoomScale(sv.minimumZoomScale, animated: true)
            } else {
                let p = g.location(in: sv.imageView)
                let scale = min(sv.maximumZoomScale, 2.5)
                let w = sv.bounds.width / scale, h = sv.bounds.height / scale
                sv.zoom(to: CGRect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h), animated: true)
            }
        }
    }
}
