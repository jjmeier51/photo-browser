import SwiftUI
import UIKit

/// "Create with AI": generate a brand-new image from a text prompt only — no source photo. Pick a
/// built-in model or one of your own tunes, a shape and resolution, and how many to make. Runs
/// app-wide (progress pill + a notification when ready); results are reviewed via `AIResultsView`
/// and kept ones save into an "AI" subfolder of the current folder.
struct AICreateView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let folder: URL

    @State private var prompt: String
    @State private var count: Int
    @State private var model: AIExtend.AIModel
    @State private var selectedTune: AIExtend.AstriaTune? = nil
    @State private var pendingTuneID: Int          // resolved to `selectedTune` once tunes load
    @State private var tunes: [AIExtend.AstriaTune] = []
    @State private var resolution: AIExtend.OutputResolution
    @State private var aspect: AIExtend.OutputAspect
    @State private var showSettings = false

    private let counts = [1, 2, 3, 4, 8]
    // Create has no source photo, so "Original" doesn't apply — offer the fixed shapes only.
    private var aspects: [AIExtend.OutputAspect] { AIExtend.OutputAspect.allCases.filter { $0 != .original } }

    /// Pre-fill every control from the previous Create-with-AI run.
    init(folder: URL) {
        self.folder = folder
        let s = AIExtend.lastRunSettings(create: true)
        _prompt = State(initialValue: s.prompt)
        _count = State(initialValue: [1, 2, 3, 4, 8].contains(s.count) ? s.count : 1)
        _model = State(initialValue: AIExtend.AIModel(rawValue: s.model) ?? AIExtend.defaultModel)
        _pendingTuneID = State(initialValue: s.tuneID)
        _resolution = State(initialValue: AIExtend.OutputResolution(rawValue: s.resolution) ?? .k2)
        // Create never uses "Original" — fall back to square if that's what was stored.
        let savedAspect = AIExtend.OutputAspect(rawValue: s.aspect)
        _aspect = State(initialValue: (savedAspect == .original ? nil : savedAspect) ?? .square)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Describe the image to create") {
                    TextField("e.g. a golden retriever puppy on a beach at sunset, photorealistic", text: $prompt, axis: .vertical)
                        .lineLimit(2...6)
                }
                if !library.aiPromptHistory.isEmpty { promptHistorySection }
                Section {
                    AIModelTunePicker(model: $model, tune: $selectedTune, tunes: tunes)
                } header: {
                    Text("Model & Tune")
                } footer: {
                    Text(comboNote)
                }
                Section("Output") {
                    Picker("Resolution", selection: $resolution) {
                        ForEach(AIExtend.OutputResolution.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Picker("Dimensions", selection: $aspect) {
                        ForEach(aspects) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                Section {
                    Picker("Images to generate", selection: $count) {
                        ForEach(counts, id: \.self) { Text("\($0)").tag($0) }
                    }
                } footer: {
                    Text("Generates images from your description with Astria — no source photo needed. It runs in the background; you'll get a notification when they're ready to review. Kept results save to an “AI” subfolder of “\(folder.lastPathComponent)”.")
                }
            }
            .navigationTitle("Create with AI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Generate") { generate() }
                        .disabled(prompt.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .task {
                tunes = await library.loadAITunes()
                if selectedTune == nil, pendingTuneID > 0 {
                    // Restore the previous tune only if it's compatible with the restored model.
                    selectedTune = AIExtend.tunes(tunes, compatibleWith: model).first { $0.id == pendingTuneID }
                }
            }
        }
    }

    private var promptHistorySection: some View {
        Section {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(library.aiPromptHistory, id: \.self) { past in
                        Button { prompt = past } label: {
                            HStack {
                                Text(past).lineLimit(2).foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: "arrow.up.circle").font(.callout).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 10).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button { prompt = past } label: { Label("Use as Prompt", systemImage: "text.insert") }
                            Button { UIPasteboard.general.string = past } label: { Label("Copy", systemImage: "doc.on.doc") }
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
        }
    }

    /// Explains how the chosen Model + Tune combine.
    private var comboNote: String {
        guard let t = selectedTune else {
            return "Pick a base model, and optionally one of your tunes. The Tune list only shows tunes that work with the chosen model — Flux shows your trained LoRAs, Seedream/Nano show your FaceID tunes."
        }
        if model.composesLoRA { return "Running your tune “\(t.label)” on \(model.rawValue)." }
        return "Using your \(model.rawValue) tune “\(t.label)”."
    }

    private func generate() {
        guard AIExtend.isConfigured else { showSettings = true; return }
        // Remember these settings so the sheet reopens pre-filled the same way after review.
        AIExtend.saveRunSettings(AIExtend.RunSettings(prompt: prompt, model: model.rawValue,
                                                      tuneID: selectedTune?.id ?? 0,
                                                      resolution: resolution.rawValue,
                                                      aspect: aspect.rawValue, count: count), create: true)
        let gen = AIExtend.resolveGeneration(model: model, tune: selectedTune)
        library.startAICreate(folder: folder, prompt: prompt, promptPrefix: gen.promptPrefix, count: count,
                              tune: gen.tuneID, modelLabel: gen.label, token: gen.token,
                              supportsResolution: gen.supportsResolution, resolution: resolution, aspect: aspect)
        dismiss()
    }
}
