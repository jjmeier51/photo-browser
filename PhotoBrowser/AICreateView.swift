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

    @State private var prompt = ""
    @State private var count = 1
    @State private var choice: AIGenChoice = .model(AIExtend.defaultModel)
    @State private var tunes: [AIExtend.AstriaTune] = []
    @State private var resolution = AIExtend.OutputResolution.k2
    @State private var aspect = AIExtend.OutputAspect.square
    @State private var showSettings = false

    private let counts = [1, 2, 3, 4, 8]
    // Create has no source photo, so "Original" doesn't apply — offer the fixed shapes only.
    private var aspects: [AIExtend.OutputAspect] { AIExtend.OutputAspect.allCases.filter { $0 != .original } }

    var body: some View {
        NavigationStack {
            Form {
                Section("Describe the image to create") {
                    TextField("e.g. a golden retriever puppy on a beach at sunset, photorealistic", text: $prompt, axis: .vertical)
                        .lineLimit(2...6)
                }
                if !library.aiPromptHistory.isEmpty { promptHistorySection }
                Section {
                    AIGeneratorPicker(choice: $choice, tunes: tunes)
                } header: {
                    Text("Model or Tune")
                } footer: {
                    if case .tune(let t) = choice, !t.token.isEmpty {
                        Text("Using your tune “\(t.label)”. Its subject word “\(t.token)” is added to the prompt automatically.")
                    }
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
            .task { tunes = await library.loadAITunes() }
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

    private func generate() {
        guard AIExtend.isConfigured else { showSettings = true; return }
        library.startAICreate(folder: folder, prompt: prompt, count: count,
                              tune: choice.tuneID, modelLabel: choice.label, token: choice.token,
                              resolution: resolution, aspect: aspect)
        dismiss()
    }
}
