import SwiftUI
import UIKit

/// AI image editing (Astria): the user describes the edit and how many variations
/// to generate, and reviews the results (Keep saves to the AI folder). Past
/// prompts are kept as a tap-to-reuse history below the prompt box.
struct AIEditView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let entry: Entry

    @State private var prompt = ""
    @State private var count = 1
    @State private var model = AIExtend.defaultModel
    @State private var resolution = AIExtend.OutputResolution.k2
    @State private var aspect = AIExtend.OutputAspect.original
    @State private var lastPrompt = ""                       // prompt/model actually sent, for result metadata
    @State private var lastModel = AIExtend.defaultModel
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
                if !library.aiPromptHistory.isEmpty {
                    Section {
                        // A self-contained scroll region so a long history doesn't push the
                        // Model / image-count settings far down the form. Caps at ~4 rows
                        // and scrolls internally; sizes to content when the list is short.
                        ScrollView {
                            VStack(spacing: 0) {
                                ForEach(library.aiPromptHistory, id: \.self) { past in
                                    // Tap = paste it into the prompt box above.
                                    Button { prompt = past } label: {
                                        HStack {
                                            Text(past).lineLimit(2).foregroundStyle(.primary)
                                            Spacer()
                                            Image(systemName: "arrow.up.circle")
                                                .font(.callout).foregroundStyle(.secondary)
                                        }
                                        .padding(.vertical, 10)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        Button { prompt = past } label: {
                                            Label("Use as Prompt", systemImage: "text.insert")
                                        }
                                        Button { UIPasteboard.general.string = past } label: {
                                            Label("Copy", systemImage: "doc.on.doc")
                                        }
                                        Button(role: .destructive) { library.deleteAIPrompt(past) } label: {
                                            Label("Remove from History", systemImage: "trash")
                                        }
                                    }
                                    if past != library.aiPromptHistory.last { Divider() }
                                }
                            }
                        }
                        .frame(height: min(CGFloat(library.aiPromptHistory.count) * 52, 220))
                    } header: {
                        Text("Previous prompts")
                    } footer: {
                        Text("Tap a prompt to use it again. Long-press to copy it or remove it.")
                    }
                }
                Section("Model") {
                    Picker("Model", selection: $model) {
                        ForEach(AIExtend.AIModel.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.segmented)
                }
                Section("Output") {
                    Picker("Resolution", selection: $resolution) {
                        ForEach(AIExtend.OutputResolution.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Picker("Dimensions", selection: $aspect) {
                        ForEach(AIExtend.OutputAspect.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                Section {
                    Picker("Images to generate", selection: $count) {
                        ForEach(counts, id: \.self) { Text("\($0)").tag($0) }
                    }
                } footer: {
                    Text("Uploads the photo to Astria to generate edits. “4K” super-resolves the result; “Original” keeps the photo's shape. Results are reviewed before anything is saved (to an “AI” subfolder, keeping the original's EXIF).")
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
                        Text("Generating \(count) image\(count == 1 ? "" : "s") with Astria…")
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
                AIResultsView(original: entry.url, results: box.data,
                              model: lastModel.rawValue, prompt: lastPrompt)
            }
        }
    }

    private func generate() {
        guard AIExtend.isConfigured else { showSettings = true; return }
        library.recordAIPrompt(prompt)     // history, newest first (reuse moves it to the top)
        running = true; error = nil
        let url = entry.url, p = prompt, n = count, m = model
        lastPrompt = p; lastModel = m       // snapshot for the results sheet's metadata
        let res = resolution, asp = aspect
        let bg = BackgroundTaskHolder(); bg.begin(name: "AI Edit")
        let activity = AIProgressActivity()
        activity.begin(title: "AI Edit", detail: "Generating with Astria…")
        Task {
            guard let prep = await Task.detached(priority: .userInitiated) { AIExtend.uploadJPEG(of: url, maxPixel: res.uploadLongSide) }.value else {
                running = false; bg.end(); error = "Couldn’t read the photo."
                activity.finish(success: false, message: "Couldn’t read the photo."); return
            }
            let result = await AIExtend.generate(model: m, prompt: p, imageData: prep.data, count: n,
                                                 width: prep.width, height: prep.height,
                                                 aspectOverride: asp.ratio, superResolution: res.superResolution)
            running = false; bg.end()
            switch result {
            case .success(let data):
                results = data
                activity.finish(success: true, message: "\(data.count) AI image\(data.count == 1 ? "" : "s") ready to review.")
            case .failure(.notConfigured):
                showSettings = true; activity.finish(success: false, message: "Add your Astria API key in Settings.")
            case .failure(.network):
                error = "Couldn’t reach the provider."; activity.finish(success: false, message: "Couldn’t reach the provider.")
            case .failure(.badImage), .failure(.badResult):
                error = "The image couldn’t be processed."; activity.finish(success: false, message: "The image couldn’t be processed.")
            case .failure(.server(let m)):
                error = m; activity.finish(success: false, message: m)
            }
        }
    }
}

private struct ResultsBox: Identifiable { let id = UUID(); let data: [Data] }
