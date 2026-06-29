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
        case adjust, filters, crop, reshape
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var icon: String {
            switch self {
            case .adjust:  return "slider.horizontal.3"
            case .filters: return "camera.filters"
            case .crop:    return "crop.rotate"
            case .reshape: return "hand.draw"
            }
        }
    }

    // Source proxy + rendered preview
    @State private var proxy: CIImage?
    @State private var fastProxy: CIImage?      // smaller proxy for high-FPS preview during reshape drags
    @State private var reshaping = false        // true while a reshape stroke is in progress
    @State private var preview: UIImage?
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
        .onChange(of: tab) { scheduleRender() }   // crop tab shows the uncropped frame; others bake the crop
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 18) {
            Button("Cancel") { dismiss() }
            Spacer()
            Button { undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(undoStack.isEmpty)
            Button { redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(redoStack.isEmpty)
            Button { reset() } label: { Image(systemName: "arrow.counterclockwise") }
                .disabled(recipe.isIdentity)
            Spacer()
            Button { save() } label: { Text("Save").fontWeight(.semibold) }
                .disabled(recipe.isIdentity)
        }
        .font(.body)
        .tint(.white)
        .padding(.horizontal)
        .padding(.vertical, 12)
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
                } else {
                    ZStack {
                        Image(uiImage: preview)
                            .resizable()
                            .scaledToFit()
                            .animation(.easeOut(duration: 0.12), value: preview)
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
            }
            tabBar
        }
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(.black)
    }

    private var tabBar: some View {
        HStack {
            ForEach(Tab.allCases) { t in
                Button { tab = t } label: {
                    VStack(spacing: 4) {
                        Image(systemName: t.icon).font(.system(size: 18))
                        Text(t.title).font(.caption2)
                    }
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(tab == t ? Color.white : Color.secondary)
                }
            }
        }
        .padding(.horizontal)
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
        Task.detached(priority: .userInitiated) {
            let img = PhotoEditorIO.renderUIImage(src, recipe: r)
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
        let p = PhotoEditorIO.proxy(loaded.image, maxDimension: 1600)
        proxy = p
        fastProxy = PhotoEditorIO.proxy(p, maxDimension: 1000)   // lighter render while actively reshaping
        scheduleRender()
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

    private func save() {
        guard !recipe.isIdentity else { dismiss(); return }
        let r = recipe
        let src = entry.url
        let id = library.beginActivity("Saving edited photo…", indeterminate: true)
        dismiss()
        Task.detached(priority: .userInitiated) {
            let fmt = PhotoEditorIO.format(forSource: src)
            let dest = PhotoEditorIO.editedDestination(for: src, format: fmt)
            let ok = PhotoEditorIO.save(recipe: r, sourceURL: src, to: dest, format: fmt)
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
        if abs(a - aspect) > 0.0001 { aspect = a; configured = false; setNeedsLayout() }
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
