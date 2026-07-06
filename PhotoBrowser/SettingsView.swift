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
    @State private var flux = String(AIExtend.fluxTune)
    @State private var prompt = AIExtend.extendPrompt
    @State private var cdmpoolToken = OnlyFansDRM.token

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
                    Text("Used only for “Extend with AI” (Flux, masked outpaint) and “Edit with AI” (the model below). Those upload the photo to Astria; the rest of the app stays offline. Leave the key blank to disable. Note: providers run content moderation and may refuse some edits.")
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
                    HStack {
                        Text("Flux (extend)")
                        Spacer()
                        TextField("Tune ID", text: $flux)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 120)
                    }
                } header: {
                    Text("Model tune IDs")
                } footer: {
                    Text("Each model is an Astria gallery tune. Paste the tune ID from its gallery page to override the built-in default. “Edit with AI” uses the chosen model; “Extend with AI” uses Flux (it’s the one that supports masked outpainting).")
                }

                Section("Extend prompt") {
                    TextField("Prompt", text: $prompt, axis: .vertical).font(.callout)
                    Button("Reset to default") { prompt = AIExtend.defaultPrompt }
                }

                Section {
                    SecureField("CDMPOOL API token", text: $cdmpoolToken)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: {
                    Text("OnlyFans DRM")
                } footer: {
                    Text("Optional. Lets the OnlyFans downloader decrypt DRM-protected videos using your cdmpool.xyz account: the app fetches the manifest, and cdmpool runs the Widevine license handshake to return the key (decryption uses FFmpegKit, which must be added to the project). Note: this relays your OnlyFans license headers through cdmpool. Leave blank to skip DRM videos.")
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
                        if let id = Int(flux.trimmingCharacters(in: .whitespaces)) { AIExtend.setFluxTune(id) }
                        AIExtend.save(apiKey: key, defaultModel: model, prompt: prompt)
                        OnlyFansDRM.setToken(cdmpoolToken)
                        dismiss()
                    }
                }
            }
        }
    }
}
