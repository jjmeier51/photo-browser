import SwiftUI

/// Fits/extends a photo. On-device "Save" writes a blurred/mirrored/solid fill in
/// place; "Extend with AI" outpaints via the cloud and saves the result(s) into an
/// AI folder (reviewed first). Aspect can be a preset or Freeform (independent
/// width/height extension).
struct ResizeEditorView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let entry: Entry

    @State private var source: UIImage?
    @State private var preview: UIImage?
    @State private var aspect: ResizeAspect = .square
    @State private var freeW = 1.5
    @State private var freeH = 1.5
    @State private var offsetX = 0.5
    @State private var offsetY = 0.5
    @State private var dragBaseX = 0.5
    @State private var dragBaseY = 0.5
    @State private var aiStatus = ""
    @State private var fill: MediaEditing.ResizeFill = .blur
    @State private var extendText = ""
    @State private var model = AIExtend.defaultModel
    @State private var saving = false
    @State private var confirmAI = false
    @State private var showSettings = false
    @State private var aiError: String?
    @State private var aiResults: [Data]?

    enum ResizeAspect: String, CaseIterable, Identifiable {
        case square = "1:1", portrait45 = "4:5", landscape = "16:9"
        case portrait916 = "9:16", classic = "4:3", freeform = "Free"
        var id: String { rawValue }
        var ratio: CGFloat {
            switch self {
            case .square: return 1
            case .portrait45: return 4.0 / 5.0
            case .landscape: return 16.0 / 9.0
            case .portrait916: return 9.0 / 16.0
            case .classic: return 4.0 / 3.0
            case .freeform: return 1
            }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                ZStack {
                    Color.black
                    if let preview { Image(uiImage: preview).resizable().scaledToFit() }
                    else { ProgressView().tint(.white) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture()
                        .onChanged { v in
                            guard aspect == .freeform else { return }
                            offsetX = min(max(dragBaseX + Double(v.translation.width) / 280, 0), 1)
                            offsetY = min(max(dragBaseY - Double(v.translation.height) / 280, 0), 1)   // screen y-down → canvas y-up
                            regenerate()
                        }
                        .onEnded { _ in dragBaseX = offsetX; dragBaseY = offsetY }
                )

                Picker("Aspect", selection: $aspect) {
                    ForEach(ResizeAspect.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).padding(.horizontal)

                if aspect == .freeform {
                    VStack(spacing: 2) {
                        slider("Width", value: $freeW)
                        slider("Height", value: $freeH)
                        Text("Drag the preview to position the photo in the frame.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }.padding(.horizontal)
                }

                Picker("Fill", selection: $fill) {
                    ForEach(MediaEditing.ResizeFill.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).padding(.horizontal)

                TextField("Optional: what to show in the new space…", text: $extendText, axis: .vertical)
                    .lineLimit(1...2).textFieldStyle(.roundedBorder).padding(.horizontal)

                HStack(spacing: 10) {
                    Picker("Model", selection: $model) {
                        ForEach(AIExtend.AIModel.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden().tint(.white)
                    Button { AIExtend.isConfigured ? (confirmAI = true) : (showSettings = true) } label: {
                        Label("Extend with AI", systemImage: "sparkles").font(.subheadline)
                    }
                    .buttonStyle(.bordered).tint(.purple).disabled(saving)
                }
                .padding(.horizontal).padding(.bottom, 8)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Resize")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(saving || source == nil) }
            }
            .task { await loadSource() }
            .onChange(of: aspect) { regenerate() }
            .onChange(of: fill) { regenerate() }
            .onChange(of: freeW) { regenerate() }
            .onChange(of: freeH) { regenerate() }
            .confirmationDialog("Extend with AI", isPresented: $confirmAI, titleVisibility: .visible) {
                Button("Upload & Extend") { runAI() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This uploads the photo to \(model.rawValue) (via Astria) to extend it. The result is reviewed before saving.")
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .alert("Couldn’t extend", isPresented: Binding(get: { aiError != nil }, set: { if !$0 { aiError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(aiError ?? "") }
            .sheet(item: Binding(get: { aiResults.map { ResultsBox(data: $0) } }, set: { aiResults = $0?.data }),
                   onDismiss: { dismiss() }) { box in
                AIResultsView(original: entry.url, results: box.data)
            }
            .overlay { if saving && !aiStatus.isEmpty { aiProgressOverlay } }
        }
        .preferredColorScheme(.dark)
    }

    private var aiProgressOverlay: some View {
        VStack(spacing: 12) {
            ProgressView().tint(.white)
            Text(aiStatus).font(.callout.weight(.medium)).foregroundStyle(.white)
            Text("This can take up to a minute. Keep the app open — it keeps going briefly in the background.")
                .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(28).frame(maxWidth: 300)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func slider(_ label: String, value: Binding<Double>) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
            Slider(value: value, in: 1.0...3.0)
            Text("\(Int(value.wrappedValue * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 44)
        }
    }

    private func loadSource() async {
        source = await ZoomableImageView.decode(url: entry.url, maxPixel: 1400, fullQuality: true)
        regenerate()
    }

    /// Composes the preview for the current aspect/freeform + fill (+ drag offset).
    private func composed(_ cg: CGImage, fill: MediaEditing.ResizeFill) -> CGImage? {
        if aspect == .freeform {
            return MediaEditing.composeCanvas(cg, canvasWidth: Int(Double(cg.width) * freeW),
                                              canvasHeight: Int(Double(cg.height) * freeH), fill: fill,
                                              offsetX: offsetX, offsetY: offsetY)
        }
        return MediaEditing.composeCanvas(cg, targetAspect: aspect.ratio, fill: fill)
    }

    private func regenerate() {
        guard let cg = source?.cgImage else { return }
        let render = { composed(cg, fill: fill) }
        Task.detached(priority: .userInitiated) {
            let out = render().map { UIImage(cgImage: $0) }
            await MainActor.run { preview = out }
        }
    }

    private func save() {
        saving = true
        let url = entry.url, style = fill, free = aspect == .freeform, w = freeW, h = freeH, ratio = aspect.ratio
        let ox = offsetX, oy = offsetY
        Task {
            let ok = await Task.detached(priority: .userInitiated) {
                free ? MediaEditing.resizeCanvasInPlace(url: url, widthFactor: w, heightFactor: h, fill: style, offsetX: ox, offsetY: oy)
                     : MediaEditing.resizeCanvasInPlace(url: url, targetAspect: ratio, fill: style)
            }.value
            saving = false
            if ok { library.contentDidChange() }
            dismiss()
        }
    }

    /// Target output frame for the chosen aspect/freeform, capped to the model's max.
    private func targetCanvas(ow: Int, oh: Int, cap: Int) -> (Int, Int) {
        var cw: Double, ch: Double
        if aspect == .freeform { cw = Double(ow) * freeW; ch = Double(oh) * freeH }
        else {
            let imgAR = Double(ow) / Double(oh), ar = Double(aspect.ratio)
            if imgAR >= ar { cw = Double(ow); ch = Double(ow) / ar } else { ch = Double(oh); cw = Double(oh) * ar }
        }
        let long = max(cw, ch)
        if long > Double(cap) { let s = Double(cap) / long; cw *= s; ch *= s }
        return (max(64, Int(cw.rounded())), max(64, Int(ch.rounded())))
    }

    private func runAI() {
        saving = true; aiStatus = "Preparing…"
        let url = entry.url, m = model
        let extra = extendText.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = extra.isEmpty ? AIExtend.extendPrompt : AIExtend.extendPrompt + " In the newly added areas, include: \(extra)."
        let bg = BackgroundTaskHolder(); bg.begin(name: "AI Extend")
        Task {
            // These models are mask-less editors: send the original and request the
            // larger target frame; they outpaint to fill it.
            let prep = await Task.detached(priority: .userInitiated) { AIExtend.uploadJPEG(of: url, maxPixel: m.maxLongSide) }.value
            guard let prep else { saving = false; bg.end(); aiError = "Couldn’t prepare the image."; return }
            let (cw, ch) = targetCanvas(ow: prep.width, oh: prep.height, cap: Int(m.maxLongSide))
            aiStatus = "Generating with \(m.rawValue)…"
            let result = await AIExtend.generate(model: m, prompt: prompt, imageData: prep.data, count: 1, width: cw, height: ch)
            saving = false; bg.end()
            switch result {
            case .success(let data): aiResults = data
            case .failure(.notConfigured): showSettings = true
            case .failure(.network): aiError = "Couldn’t reach the provider."
            case .failure(.badImage), .failure(.badResult): aiError = "The image couldn’t be processed."
            case .failure(.server(let msg)): aiError = msg
            }
        }
    }
}

private struct ResultsBox: Identifiable { let id = UUID(); let data: [Data] }
