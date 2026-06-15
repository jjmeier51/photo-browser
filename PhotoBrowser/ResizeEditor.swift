import SwiftUI

/// Fits a photo to a chosen aspect ratio by *extending* it (never cropping),
/// filling the new space on-device with a blurred backdrop, mirrored edges, or a
/// solid color — the Instasize-style "resize". Writes back in place, preserving
/// metadata. (A cloud AI "extend" mode is layered on separately.)
struct ResizeEditorView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let entry: Entry

    @State private var source: UIImage?
    @State private var preview: UIImage?
    @State private var aspect: ResizeAspect = .square
    @State private var fill: MediaEditing.ResizeFill = .blur
    @State private var saving = false
    @State private var confirmAI = false
    @State private var showSettings = false
    @State private var aiError: String?

    enum ResizeAspect: String, CaseIterable, Identifiable {
        case square = "1:1", portrait45 = "4:5", landscape = "16:9"
        case portrait916 = "9:16", classic = "4:3", classicPortrait = "3:4"
        var id: String { rawValue }
        var ratio: CGFloat {
            switch self {
            case .square: return 1
            case .portrait45: return 4.0 / 5.0
            case .landscape: return 16.0 / 9.0
            case .portrait916: return 9.0 / 16.0
            case .classic: return 4.0 / 3.0
            case .classicPortrait: return 3.0 / 4.0
            }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                ZStack {
                    Color.black
                    if let preview { Image(uiImage: preview).resizable().scaledToFit() }
                    else { ProgressView().tint(.white) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Picker("Aspect", selection: $aspect) {
                    ForEach(ResizeAspect.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).padding(.horizontal)

                Picker("Fill", selection: $fill) {
                    ForEach(MediaEditing.ResizeFill.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).padding(.horizontal)

                Button {
                    if AIExtend.isConfigured { confirmAI = true } else { showSettings = true }
                } label: {
                    Label("Extend with AI (cloud)…", systemImage: "sparkles")
                        .font(.subheadline).frame(maxWidth: .infinity).padding(.vertical, 4)
                }
                .buttonStyle(.bordered).tint(.purple).padding(.horizontal).padding(.bottom, 8)
                .disabled(saving)
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
            .confirmationDialog("Extend with AI", isPresented: $confirmAI, titleVisibility: .visible) {
                Button("Upload & Extend") { runAI() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This uploads the photo to your configured provider (e.g. fal.ai / Seedream) to extend it. The photo leaves your device for this edit.")
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .alert("Couldn’t extend", isPresented: Binding(get: { aiError != nil }, set: { if !$0 { aiError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(aiError ?? "") }
            .overlay {
                if saving {
                    ProgressView().tint(.white).padding(28)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func loadSource() async {
        source = await ZoomableImageView.decode(url: entry.url, maxPixel: 1400, fullQuality: true)
        regenerate()
    }

    private func regenerate() {
        guard let cg = source?.cgImage else { return }
        let ratio = aspect.ratio, style = fill
        Task.detached(priority: .userInitiated) {
            let out = MediaEditing.composeCanvas(cg, targetAspect: ratio, fill: style).map { UIImage(cgImage: $0) }
            await MainActor.run { preview = out }
        }
    }

    private func save() {
        saving = true
        let url = entry.url, ratio = aspect.ratio, style = fill
        Task {
            let ok = await Task.detached(priority: .userInitiated) {
                MediaEditing.resizeCanvasInPlace(url: url, targetAspect: ratio, fill: style)
            }.value
            saving = false
            if ok { library.contentDidChange() }
            dismiss()
        }
    }

    private func runAI() {
        saving = true
        let url = entry.url, ratio = aspect.ratio
        Task {
            let err = await AIExtend.extendInPlace(url: url, targetAspect: ratio)
            saving = false
            switch err {
            case nil:
                library.contentDidChange(); dismiss()
            case .notConfigured?: showSettings = true
            case .network?: aiError = "Couldn’t reach the provider. Check your connection."
            case .badImage?, .badResult?: aiError = "The image couldn’t be processed."
            case .server(let m)?: aiError = m
            }
        }
    }
}
