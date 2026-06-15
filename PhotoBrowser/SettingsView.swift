import SwiftUI

/// App settings — the opt-in cloud AI features (Astria). An empty key keeps the
/// app fully offline.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var key = AIExtend.apiKey
    @State private var tune = String(AIExtend.tuneID)
    @State private var prompt = AIExtend.extendPrompt

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Astria API key", text: $key)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Tune ID", text: $tune)
                        .keyboardType(.numberPad)
                } header: {
                    Text("AI (cloud)")
                } footer: {
                    Text("Used only for “Extend with AI” and “Edit with AI”. Those upload the photo to Astria; the rest of the app stays offline. Leave the key blank to disable. Tune ID is the Astria model — \(AIExtend.defaultTune) is Flux. Note: providers run content moderation and may refuse some edits.")
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
                        AIExtend.save(apiKey: key, tuneID: Int(tune) ?? AIExtend.defaultTune, prompt: prompt)
                        dismiss()
                    }
                }
            }
        }
    }
}
