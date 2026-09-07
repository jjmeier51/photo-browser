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
    @State private var count: Int
    @State private var model: AIExtend.AIModel
    @State private var selectedTune: AIExtend.AstriaTune? = nil
    @State private var pendingTuneID: Int          // resolved to `selectedTune` once tunes load
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
        _count = State(initialValue: [1, 2, 3, 4, 8].contains(s.count) ? s.count : 1)
        _model = State(initialValue: AIExtend.AIModel(rawValue: s.model) ?? AIExtend.defaultModel)
        _pendingTuneID = State(initialValue: s.tuneID)
        _resolution = State(initialValue: AIExtend.OutputResolution(rawValue: s.resolution) ?? .k2)
        _aspect = State(initialValue: AIExtend.OutputAspect(rawValue: s.aspect) ?? .original)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("What would you like to change?") {
                    TextField("e.g. make the sky a sunset, remove the sign…", text: $prompt, axis: .vertical)
                        .lineLimit(2...5)
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
            .task {
                tunes = await library.loadAITunes()
                if selectedTune == nil, pendingTuneID > 0 {
                    selectedTune = tunes.first { $0.id == pendingTuneID }   // restore the previous tune
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
        } footer: {
            Text("Tap a prompt to use it again. Long-press to copy it or remove it.")
        }
    }

    /// Explains how the chosen Model + Tune combine (they run differently on Flux vs a partner model).
    private var comboNote: String {
        guard let t = selectedTune else { return "Pick a base model. Add one of your tunes to apply it too." }
        if model.composesLoRA { return "Running your tune “\(t.label)” on \(model.rawValue)." }
        return "\(model.rawValue) can't run a tune, so “\(t.label)” runs on its own base. Pick Flux to combine them."
    }

    /// Kicks off generation app-wide (it keeps running while you browse) and closes this sheet.
    private func generate() {
        guard AIExtend.isConfigured else { showSettings = true; return }
        // Remember these settings so the sheet reopens pre-filled the same way after review.
        AIExtend.saveRunSettings(AIExtend.RunSettings(prompt: prompt, model: model.rawValue,
                                                      tuneID: selectedTune?.id ?? 0,
                                                      resolution: resolution.rawValue,
                                                      aspect: aspect.rawValue, count: count), create: false)
        let gen = AIExtend.resolveGeneration(model: model, tune: selectedTune)
        library.startAIEdit(entry: entry, prompt: prompt, promptPrefix: gen.promptPrefix, count: count,
                            tune: gen.tuneID, modelLabel: gen.label, token: gen.token,
                            resolution: resolution, aspect: aspect)
        dismiss()
    }
}
