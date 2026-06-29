import SwiftUI
import CoreImage

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
        case adjust, filters, crop
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var icon: String {
            switch self {
            case .adjust:  return "slider.horizontal.3"
            case .filters: return "camera.filters"
            case .crop:    return "crop.rotate"
            }
        }
    }

    // Source proxy + rendered preview
    @State private var proxy: CIImage?
    @State private var preview: UIImage?
    @State private var originalThumb: UIImage?
    @State private var filterThumbs: [String: UIImage] = [:]
    @State private var loadFailed = false
    @State private var renderGen = 0

    // Edit state + history
    @State private var recipe = EditRecipe()
    @State private var undoStack: [EditRecipe] = []
    @State private var redoStack: [EditRecipe] = []

    @State private var tab: Tab = .adjust
    @State private var selected: Adjustment = Adjustment.all[0]

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
                Image(uiImage: preview)
                    .resizable()
                    .scaledToFit()
                    .padding(10)
                    .animation(.easeOut(duration: 0.12), value: preview)
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
        let isSel = recipe.aspect == asp
        return Button { commit { recipe.aspect = asp } } label: {
            VStack(spacing: 6) {
                Image(systemName: "aspectratio").font(.system(size: 18))
                    .frame(width: 50, height: 50)
                    .background(Circle().fill(isSel ? Color.white.opacity(0.22) : Color.white.opacity(0.08)))
                    .overlay(Circle().stroke(isSel ? Color.white : .clear, lineWidth: 1.5))
                Text(asp.label).font(.caption2)
            }
            .foregroundStyle(isSel ? Color.white : Color.secondary)
        }
    }

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

    /// Renders the current recipe over the proxy off-main; only the latest render wins (`renderGen`).
    private func scheduleRender() {
        guard let proxy else { return }
        renderGen += 1
        let gen = renderGen
        let r = recipe
        Task.detached(priority: .userInitiated) {
            let img = PhotoEditorIO.renderUIImage(proxy, recipe: r)
            await MainActor.run {
                if gen == renderGen, let img { preview = img }
            }
        }
    }

    private func load() async {
        let url = entry.url
        let loaded = await Task.detached(priority: .userInitiated) { PhotoEditorIO.load(url: url) }.value
        guard let loaded else { loadFailed = true; return }
        let p = PhotoEditorIO.proxy(loaded.image, maxDimension: 1600)
        proxy = p
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
