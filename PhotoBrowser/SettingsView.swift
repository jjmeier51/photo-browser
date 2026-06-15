import SwiftUI

/// App settings — currently the opt-in cloud AI features (fal.ai). An empty key
/// keeps the app fully offline.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var key = AIExtend.apiKey
    @State private var model = AIExtend.defaultModel
    @State private var prompt = AIExtend.extendPrompt

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("fal.ai API key", text: $key)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Picker("Default model", selection: $model) {
                        ForEach(AIExtend.AIModel.allCases) { Text($0.rawValue).tag($0) }
                    }
                } header: {
                    Text("AI (cloud)")
                } footer: {
                    Text("Used only for “Extend with AI” and “Edit with AI”. Those upload the photo to the chosen provider; the rest of the app stays offline. Leave the key blank to disable. Note: providers run content moderation and may refuse some edits.")
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
                    Button("Save") { AIExtend.save(apiKey: key, prompt: prompt, model: model); dismiss() }
                }
            }
        }
    }
}
