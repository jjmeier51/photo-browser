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
    @State private var negativeEnabled: Bool
    @State private var negativePrompt: String
    @State private var referenceURLs: [URL]
    @State private var count: Int
    @State private var model: AIExtend.AIModel
    @State private var selectedTunes: [AIExtend.AstriaTune] = []
    @State private var pendingTuneIDs: [Int]       // resolved to `selectedTunes` once tunes load
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
        _negativeEnabled = State(initialValue: s.negativeEnabled)
        _negativePrompt = State(initialValue: s.negativePrompt)
        // Last run's references, minus any that have since moved or gone.
        _referenceURLs = State(initialValue: s.referencePaths.map { URL(fileURLWithPath: $0) }
                                .filter { FileManager.default.fileExists(atPath: $0.path) })
        _count = State(initialValue: [1, 2, 3, 4, 8].contains(s.count) ? s.count : 1)
        _model = State(initialValue: AIExtend.AIModel(rawValue: s.model) ?? AIExtend.defaultModel)
        _pendingTuneIDs = State(initialValue: s.tuneIDs)
        _resolution = State(initialValue: AIExtend.OutputResolution(rawValue: s.resolution) ?? .k2)
        // Create never uses "Original" — fall back to square if that's what was stored.
        let savedAspect = AIExtend.OutputAspect(rawValue: s.aspect)
        _aspect = State(initialValue: (savedAspect == .original ? nil : savedAspect) ?? .square)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("e.g. a golden retriever puppy on a beach at sunset, photorealistic", text: $prompt, axis: .vertical)
                        .lineLimit(2...6)
                    NegativePromptField(enabled: $negativeEnabled, text: $negativePrompt)
                } header: {
                    Text("Describe the image to create")
                } footer: {
                    if negativeEnabled { Text(NegativePromptField.footer) }
                }
                PromptingReminderSection()
                ReusablePromptsSection(prompt: $prompt)
                if !library.aiPromptHistory.isEmpty { PromptHistorySection(prompt: $prompt) }
                Section {
                    AIModelTunePicker(model: $model, tunes: $selectedTunes, allTunes: tunes)
                } header: {
                    Text("Model & Tunes")
                } footer: {
                    Text(comboNote)
                }
                referenceSection
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
            // A model with a smaller reference limit keeps the first N picked.
            .onChange(of: model) { _, m in
                if referenceURLs.count > m.maxReferenceImages { referenceURLs = Array(referenceURLs.prefix(m.maxReferenceImages)) }
            }
            .task {
                tunes = await library.loadAITunes()
                if !pendingTuneIDs.isEmpty {
                    // Restore the previous tunes (in saved order), keeping only those still compatible.
                    // Then clear pendingTuneIDs so this is a TRUE one-shot: `.task` re-runs when we
                    // return from the tune picker, and without clearing it would re-restore the old
                    // selection and clobber a deliberate clear-to-none.
                    if selectedTunes.isEmpty {
                        let compatible = AIExtend.tunes(tunes, compatibleWith: model)
                        selectedTunes = pendingTuneIDs.compactMap { id in compatible.first { $0.id == id } }
                    }
                    pendingTuneIDs = []
                }
            }
        }
    }

    /// Up to the model's limit of extra photos from this folder for the model to draw on.
    private var referenceSection: some View {
        Section {
            NavigationLink {
                ReferenceImagesPicker(folder: folder, limit: model.maxReferenceImages, selected: $referenceURLs)
            } label: {
                HStack {
                    Text("Reference images")
                    Spacer()
                    Text(referenceURLs.isEmpty ? "None" : "\(referenceURLs.count) of \(model.maxReferenceImages)")
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(model.maxReferenceImages == 0)
            if !referenceURLs.isEmpty { ReferenceImagesStrip(selected: $referenceURLs) }
        } header: {
            Text("References")
        } footer: {
            Text(model.maxReferenceImages == 0
                 ? "Flux takes no reference images here — pick a Seedream or Nano Banana model to use them."
                 : "Up to \(model.maxReferenceImages) photos from “\(folder.lastPathComponent)” for \(model.rawValue) to draw on — a person, an outfit, a product, a style. Refer to them in the prompt (“the woman in the reference”, “the dress from image 2”); they're sent in the order you picked them.")
        }
    }

    /// Explains how the chosen Model + Tune combine.
    private var comboNote: String {
        switch selectedTunes.count {
        case 0:
            return "Pick a base model, and optionally one or more of your tunes. The Tunes list only shows tunes that work with the chosen model — Flux shows your trained LoRAs, Seedream/Nano show your FaceID tunes."
        case 1:
            let t = selectedTunes[0]
            return model.composesLoRA ? "Running your tune “\(t.label)” on \(model.rawValue)." : "Using your \(model.rawValue) tune “\(t.label)”."
        default:
            return "Combining \(selectedTunes.count) tunes on \(model.rawValue)\(model.composesLoRA ? " (stacked as LoRAs)" : " (stacked as FaceIDs)")."
        }
    }

    private func generate() {
        guard AIExtend.isConfigured else { showSettings = true; return }
        // Remember these settings so the sheet reopens pre-filled the same way after review.
        AIExtend.saveRunSettings(AIExtend.RunSettings(prompt: prompt, model: model.rawValue,
                                                      tuneIDs: selectedTunes.map(\.id),
                                                      resolution: resolution.rawValue,
                                                      aspect: aspect.rawValue, count: count,
                                                      negativeEnabled: negativeEnabled, negativePrompt: negativePrompt,
                                                      referencePaths: referenceURLs.map(\.path)),
                                 create: true)
        let gen = AIExtend.resolveGeneration(model: model, tunes: selectedTunes)
        library.startAICreate(folder: folder, prompt: prompt, negativePrompt: negativeEnabled ? negativePrompt : nil,
                              referenceURLs: Array(referenceURLs.prefix(model.maxReferenceImages)),
                              promptPrefix: gen.promptPrefix, count: count,
                              tune: gen.tuneID, modelLabel: gen.label, token: gen.token,
                              supportsResolution: gen.supportsResolution, resolution: resolution, aspect: aspect)
        dismiss()
    }
}
