import SwiftUI

/// AI image editing: the user describes the edit, picks a model and how many
/// variations to generate, and reviews the results (Keep saves to the AI folder).
struct AIEditView: View {
    @Environment(\.dismiss) private var dismiss
    let entry: Entry

    @State private var prompt = ""
    @State private var count = 1
    @State private var model = AIExtend.defaultModel
    @State private var running = false
    @State private var results: [Data]?
    @State private var error: String?
    @State private var showSettings = false

    private let counts = [1, 2, 3, 4, 8]

    var body: some View {
        NavigationStack {
            Form {
                Section("What would you like to change?") {
                    TextField("e.g. make the sky a sunset, remove the sign…", text: $prompt, axis: .vertical)
                        .lineLimit(2...5)
                }
                Section {
                    Picker("Model", selection: $model) {
                        ForEach(AIExtend.AIModel.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Images to generate", selection: $count) {
                        ForEach(counts, id: \.self) { Text("\($0)").tag($0) }
                    }
                } footer: {
                    Text("Uploads the photo to your provider to generate edits. Results are reviewed before anything is saved (to an “AI” subfolder, keeping the original's EXIF).")
                }
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout) }
                }
            }
            .navigationTitle("Edit with AI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(running) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Generate") { generate() }
                        .disabled(running || prompt.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .overlay {
                if running {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Generating \(count) image\(count == 1 ? "" : "s") with \(model.rawValue)…")
                            .font(.callout.weight(.medium)).multilineTextAlignment(.center)
                        Text("This can take up to a minute. Keep the app open — it keeps going briefly in the background.")
                            .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .padding(28).frame(maxWidth: 300)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(item: Binding(get: { results.map { ResultsBox(data: $0) } }, set: { results = $0?.data })) { box in
                AIResultsView(original: entry.url, results: box.data)
            }
        }
    }

    private func generate() {
        guard AIExtend.isConfigured else { showSettings = true; return }
        running = true; error = nil
        let url = entry.url, p = prompt, n = count, m = model
        let bg = BackgroundTaskHolder(); bg.begin(name: "AI Edit")
        Task {
            guard let prep = await Task.detached(priority: .userInitiated) { AIExtend.uploadJPEG(of: url, maxPixel: m.maxLongSide) }.value else {
                running = false; bg.end(); error = "Couldn’t read the photo."; return
            }
            let result = await AIExtend.generate(model: m, prompt: p, imageData: prep.data, count: n,
                                                 outputSize: (prep.width, prep.height))
            running = false; bg.end()
            switch result {
            case .success(let data): results = data
            case .failure(.notConfigured): showSettings = true
            case .failure(.network): error = "Couldn’t reach the provider."
            case .failure(.badImage), .failure(.badResult): error = "The image couldn’t be processed."
            case .failure(.server(let m)): error = m
            }
        }
    }
}

private struct ResultsBox: Identifiable { let id = UUID(); let data: [Data] }
