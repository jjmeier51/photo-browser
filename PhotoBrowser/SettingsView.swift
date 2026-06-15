import SwiftUI

/// App settings. Currently just the opt-in cloud "AI Extend" provider (fal.ai
/// Seedream by default). Empty key = the app stays fully offline.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var key = AIExtend.apiKey
    @State private var endpoint = AIExtend.endpoint
    @State private var prompt = AIExtend.prompt

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("fal.ai API key", text: $key)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Endpoint", text: $endpoint, axis: .vertical)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().font(.callout)
                } header: {
                    Text("AI Extend (cloud)")
                } footer: {
                    Text("Used only when you choose “Extend with AI”. That photo is uploaded to this provider for the edit; the rest of the app stays offline. Leave the key blank to disable. Default endpoint is fal.ai Seedream 4.5 — you can point it at any compatible host. Note: providers run content moderation and may refuse some edits.")
                }

                Section("Outpaint prompt") {
                    TextField("Prompt", text: $prompt, axis: .vertical).font(.callout)
                    Button("Reset to default") { prompt = AIExtend.defaultPrompt; endpoint = AIExtend.defaultEndpoint }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { AIExtend.save(apiKey: key, endpoint: endpoint, prompt: prompt); dismiss() }
                }
            }
        }
    }
}
