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

                Button { AIExtend.isConfigured ? (confirmAI = true) : (showSettings = true) } label: {
                    Label("Extend with AI", systemImage: "sparkles").font(.subheadline).frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).tint(.purple).disabled(saving)
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
                Text("This uploads the photo to Astria (Flux) to extend it — generating new scenery around the original, kept exactly where you placed it. The result is reviewed before saving.")
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

    /// Masked-outpaint extend via Flux. Builds the target canvas with the original
    /// composited at the user's chosen position (same as the preview) plus a matching
    /// outpaint mask (white = generate, black = keep), and sends both: Flux fills only
    /// the new area, so the original stays exactly where it was placed.
    private func runAI() {
        saving = true; aiStatus = "Preparing…"
        let url = entry.url
        let extra = extendText.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = extra.isEmpty ? AIExtend.extendPrompt : AIExtend.extendPrompt + " In the newly added areas, include: \(extra)."
        let free = aspect == .freeform, fw = freeW, fh = freeH, ratio = Double(aspect.ratio)
        let ox = offsetX, oy = offsetY, style = fill
        let bg = BackgroundTaskHolder(); bg.begin(name: "AI Extend")
        let activity = AIProgressActivity()
        activity.begin(title: "AI Extend", detail: "Extending with Astria…")
        Task {
            let prep = await Task.detached(priority: .userInitiated) { () -> (img: Data, mask: Data, w: Int, h: Int)? in
                guard let raw = ZoomableImageView.decodeCG(url: url, maxPixel: 2000) else { return nil }
                // Canvas size (>= the image, so it never crops) for the chosen shape.
                func canvasDims(_ ow: Int, _ oh: Int) -> (Int, Int) {
                    if free { return (max(ow, Int((Double(ow) * fw).rounded())), max(oh, Int((Double(oh) * fh).rounded()))) }
                    let ar = Double(ow) / Double(oh)
                    return ar >= ratio ? (ow, Int((Double(ow) / ratio).rounded()))
                                       : (Int((Double(oh) * ratio).rounded()), oh)
                }
                func scaleCG(_ image: CGImage, longSide: Int) -> CGImage? {
                    let long = max(image.width, image.height)
                    guard long > longSide, long > 0 else { return image }
                    let s = Double(longSide) / Double(long)
                    let w = max(1, Int((Double(image.width) * s).rounded())), h = max(1, Int((Double(image.height) * s).rounded()))
                    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
                    ctx.interpolationQuality = .high
                    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                    return ctx.makeImage()
                }
                var (cw, ch) = canvasDims(raw.width, raw.height)
                // Keep the canvas Flux-friendly: cap the long side by scaling the
                // original down first, so the kept region and the new area scale
                // together (Flux's super-resolution restores output detail).
                let cap = 1536
                var cg = raw
                if max(cw, ch) > cap {
                    let s = Double(cap) / Double(max(cw, ch))
                    let nl = max(8, Int((Double(max(raw.width, raw.height)) * s).rounded()))
                    cg = scaleCG(raw, longSide: nl) ?? raw
                    (cw, ch) = canvasDims(cg.width, cg.height)
                }
                func r8(_ x: Int) -> Int { ((x + 7) / 8) * 8 }   // Flux wants multiples of 8
                cw = r8(cw); ch = r8(ch)
                let ow = cg.width, oh = cg.height
                guard let canvas = MediaEditing.composeCanvas(cg, canvasWidth: cw, canvasHeight: ch, fill: style,
                                                              offsetX: ox, offsetY: oy),
                      let mask = MediaEditing.outpaintMask(canvasWidth: cw, canvasHeight: ch, imageWidth: ow, imageHeight: oh,
                                                           offsetX: ox, offsetY: oy),
                      let img = UIImage(cgImage: canvas).jpegData(compressionQuality: 0.95),
                      let maskData = UIImage(cgImage: mask).pngData() else { return nil }
                return (img, maskData, canvas.width, canvas.height)
            }.value
            guard let prep else {
                saving = false; bg.end(); aiError = "Couldn’t prepare the image."
                activity.finish(success: false, message: "Couldn’t prepare the image."); return
            }
            aiStatus = "Generating…"
            let result = await AIExtend.generateOutpaint(prompt: prompt, imageData: prep.img, maskData: prep.mask,
                                                         width: prep.w, height: prep.h)
            saving = false; bg.end()
            switch result {
            case .success(let data):
                aiResults = data
                activity.finish(success: true, message: "\(data.count) extended image\(data.count == 1 ? "" : "s") ready to review.")
            case .failure(.notConfigured):
                showSettings = true; activity.finish(success: false, message: "Add your Astria API key in Settings.")
            case .failure(.network):
                aiError = "Couldn’t reach the provider."; activity.finish(success: false, message: "Couldn’t reach the provider.")
            case .failure(.badImage), .failure(.badResult):
                aiError = "The image couldn’t be processed."; activity.finish(success: false, message: "The image couldn’t be processed.")
            case .failure(.server(let msg)):
                aiError = msg; activity.finish(success: false, message: msg)
            }
        }
    }
}

private struct ResultsBox: Identifiable { let id = UUID(); let data: [Data] }
