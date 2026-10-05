import SwiftUI
import UIKit

/// AI image editing (Astria): the user describes the edit, picks a model or one of their own tunes,
/// and how many variations to generate. Generation runs app-wide (a progress pill + a notification
/// when ready); results are reviewed via `AIResultsView`. Past prompts are kept as a tap-to-reuse
/// history below the prompt box.
struct AIEditView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let entry: Entry

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

    /// Pre-fill every control from the previous Edit-with-AI run so a repeat run starts where the
    /// last one left off (the tune is resolved once the account tunes load).
    init(entry: Entry) {
        self.entry = entry
        let s = AIExtend.lastRunSettings(create: false)
        _prompt = State(initialValue: s.prompt)
        _negativeEnabled = State(initialValue: s.negativeEnabled)
        _negativePrompt = State(initialValue: s.negativePrompt)
        // Last run's references, minus any that have since moved or gone — and never the source itself.
        _referenceURLs = State(initialValue: s.referencePaths.map { URL(fileURLWithPath: $0) }
                                .filter { $0 != entry.url && FileManager.default.fileExists(atPath: $0.path) })
        _count = State(initialValue: [1, 2, 3, 4, 8].contains(s.count) ? s.count : 1)
        _model = State(initialValue: AIExtend.AIModel(rawValue: s.model) ?? AIExtend.defaultModel)
        _pendingTuneIDs = State(initialValue: s.tuneIDs)
        _resolution = State(initialValue: AIExtend.OutputResolution(rawValue: s.resolution) ?? .k2)
        _aspect = State(initialValue: AIExtend.OutputAspect(rawValue: s.aspect) ?? .original)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("e.g. make the sky a sunset, remove the sign…", text: $prompt, axis: .vertical)
                        .lineLimit(2...5)
                    NegativePromptField(enabled: $negativeEnabled, text: $negativePrompt)
                } header: {
                    Text("What would you like to change?")
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
                        ForEach(AIExtend.OutputAspect.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                Section {
                    Picker("Images to generate", selection: $count) {
                        ForEach(counts, id: \.self) { Text("\($0)").tag($0) }
                    }
                } footer: {
                    Text("Uploads the photo to Astria to generate edits — it runs in the background, so you can keep browsing while it works. You'll get a notification when the images are ready; tap it to review them. “4K” asks for the highest resolution; “Original” keeps the photo's shape. Kept results save to an “AI” subfolder, keeping the original's EXIF.")
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

    /// Up to the model's limit of extra photos (from the same folder, never the source itself) for
    /// the model to draw on alongside the photo being edited.
    private var referenceSection: some View {
        let folder = entry.url.deletingLastPathComponent()
        return Section {
            NavigationLink {
                ReferenceImagesPicker(folder: folder, exclude: entry.url, limit: model.maxReferenceImages, selected: $referenceURLs)
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
                 : "Besides the photo you're editing, up to \(model.maxReferenceImages) more from “\(folder.lastPathComponent)” for \(model.rawValue) to draw on — a face to keep, an outfit, a product, a style. Refer to them in the prompt (“the jacket from the reference”); they're sent in the order you picked them.")
        }
    }

    /// Explains how the chosen Model + Tune combine (they run differently on Flux vs a partner model).
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

    /// Kicks off generation app-wide (it keeps running while you browse) and closes this sheet.
    private func generate() {
        guard AIExtend.isConfigured else { showSettings = true; return }
        // Remember these settings so the sheet reopens pre-filled the same way after review.
        AIExtend.saveRunSettings(AIExtend.RunSettings(prompt: prompt, model: model.rawValue,
                                                      tuneIDs: selectedTunes.map(\.id),
                                                      resolution: resolution.rawValue,
                                                      aspect: aspect.rawValue, count: count,
                                                      negativeEnabled: negativeEnabled, negativePrompt: negativePrompt,
                                                      referencePaths: referenceURLs.map(\.path)),
                                 create: false)
        let gen = AIExtend.resolveGeneration(model: model, tunes: selectedTunes)
        library.startAIEdit(entry: entry, prompt: prompt, negativePrompt: negativeEnabled ? negativePrompt : nil,
                            referenceURLs: Array(referenceURLs.prefix(model.maxReferenceImages)),
                            promptPrefix: gen.promptPrefix, count: count,
                            tune: gen.tuneID, modelLabel: gen.label, token: gen.token,
                            supportsResolution: gen.supportsResolution, resolution: resolution, aspect: aspect)
        dismiss()
    }
}

/// The "Negative Prompt" switch that sits under the prompt box in Edit and Create with AI. On, it
/// reveals a text field; what's typed there is appended to the prompt as free text when the job is
/// sent — a blank line, then "Negative Prompt: …" (`AIExtend.composePrompt`) — because the partner
/// models take no separate negative field. Off, the text is kept but not sent.
struct NegativePromptField: View {
    @Binding var enabled: Bool
    @Binding var text: String

    static let footer = "Sent as the last line of your prompt, e.g. “A cinematic photo of a man carrying an umbrella in the dark.” then “Negative Prompt: light, woman, no umbrella.” Turn the switch off to keep the text without sending it."

    var body: some View {
        Toggle(isOn: $enabled.animation()) {
            Label("Negative Prompt", systemImage: "minus.circle")
        }
        if enabled {
            TextField("e.g. light, woman, no umbrella", text: $text, axis: .vertical)
                .lineLimit(1...4)
        }
    }
}
