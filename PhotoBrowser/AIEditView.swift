import SwiftUI
import UIKit

/// AI image editing (Astria): the user describes the edit and how many variations
/// to generate, and reviews the results (Keep saves to the AI folder). Past
/// prompts are kept as a tap-to-reuse history below the prompt box.
struct AIEditView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let entry: Entry
    // Reopen path: when the user taps the completion notification, ContentView reopens this UI
    // pre-loaded with the finished job's results so they show immediately over the Edit-with-AI UI.
    var initialResults: [Data]? = nil
    var initialPrompt: String = ""
    var initialModel: AIExtend.AIModel = AIExtend.defaultModel

    @State private var prompt = ""
    @State private var count = 1
    @State private var model = AIExtend.defaultModel
    @State private var resolution = AIExtend.OutputResolution.k2
    @State private var aspect = AIExtend.OutputAspect.original
    @State private var lastPrompt = ""                       // prompt/model actually sent, for result metadata
    @State private var lastModel = AIExtend.defaultModel
    @State private var results: [Data]?
    @State private var showSettings = false
    @State private var seeded = false

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
                    Text("Uploads the photo to Astria to generate edits — it runs in the background, so you can keep browsing while it works. You'll get a notification when the images are ready; tap it to review them here. “4K” super-resolves the result; “Original” keeps the photo's shape. Kept results save to an “AI” subfolder, keeping the original's EXIF.")
                }
            }
            .navigationTitle("Edit with AI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Generate") { generate() }
                        .disabled(prompt.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(item: Binding(get: { results.map { ResultsBox(data: $0) } }, set: { results = $0?.data })) { box in
                AIResultsView(original: entry.url, results: box.data,
                              model: lastModel.rawValue, prompt: lastPrompt)
            }
        }
        // Reopen path: seed the finished results so they show over the Edit-with-AI UI. Deferred a
        // tick so the outer sheet finishes presenting before its inner results sheet is triggered
        // (presenting one straight from the other's onAppear can be swallowed).
        .onAppear {
            guard !seeded, let initialResults else { return }
            seeded = true
            lastPrompt = initialPrompt
            lastModel = initialModel
            DispatchQueue.main.async { results = initialResults }
        }
    }

    /// Kicks off generation app-wide (it keeps running while you browse) and closes this sheet, so
    /// you're free to navigate. A progress pill shows it working; a notification arrives when it's
    /// done — tapping it reopens this UI on the photo with the results.
    private func generate() {
        guard AIExtend.isConfigured else { showSettings = true; return }
        library.startAIEdit(entry: entry, prompt: prompt, count: count, model: model,
                            resolution: resolution, aspect: aspect)
        dismiss()
    }
}

private struct ResultsBox: Identifiable { let id = UUID(); let data: [Data] }
