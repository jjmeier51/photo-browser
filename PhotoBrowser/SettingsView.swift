import SwiftUI

/// App settings — the opt-in cloud AI features (Astria). An empty key keeps the
/// app fully offline. Each model maps to an Astria gallery "tune"; the newest
/// versions' tune ids aren't published, so they're editable here.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var key = AIExtend.apiKey
    @State private var model = AIExtend.defaultModel
    @State private var tunes: [AIExtend.AIModel: String] = Dictionary(
        uniqueKeysWithValues: AIExtend.AIModel.allCases.map { ($0, String(AIExtend.tuneID(for: $0))) })
    @State private var prompt = AIExtend.extendPrompt

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Astria API key", text: $key)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Picker("Default model", selection: $model) {
                        ForEach(AIExtend.AIModel.allCases) { Text($0.rawValue).tag($0) }
                    }
                } header: {
                    Text("AI (cloud)")
                } footer: {
                    Text("Used only for “Extend with AI” and “Edit with AI”. Those upload the photo to Astria; the rest of the app stays offline. Leave the key blank to disable. Note: providers run content moderation and may refuse some edits.")
                }

                Section {
                    ForEach(AIExtend.AIModel.allCases) { m in
                        HStack {
                            Text(m.rawValue)
                            Spacer()
                            TextField("Tune ID", text: Binding(
                                get: { tunes[m] ?? "" },
                                set: { tunes[m] = $0 }))
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 120)
                        }
                    }
                } header: {
                    Text("Model tune IDs")
                } footer: {
                    Text("Each model is an Astria gallery tune. Paste the tune ID from its gallery page to override the built-in default.")
                }

                Section("Extend prompt") {
                    TextField("Prompt", text: $prompt, axis: .vertical).font(.callout)
                    Button("Reset to default") { prompt = AIExtend.defaultPrompt }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        for m in AIExtend.AIModel.allCases {
                            if let id = Int(tunes[m]?.trimmingCharacters(in: .whitespaces) ?? "") {
                                AIExtend.setTune(id, for: m)
                            }
                        }
                        AIExtend.save(apiKey: key, defaultModel: model, prompt: prompt)
                        dismiss()
                    }
                }
            }
        }
    }
}
