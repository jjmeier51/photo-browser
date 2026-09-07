import SwiftUI

/// App settings — the opt-in cloud AI features (Astria). An empty key keeps the
/// app fully offline. Each model maps to an Astria gallery "tune"; the newest
/// versions' tune ids aren't published, so they're editable here.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var key = AIExtend.apiKey
    @State private var model = AIExtend.defaultModel
    // Flux is excluded here — it shares the separate "Flux (extend)" tune field below.
    @State private var tunes: [AIExtend.AIModel: String] = Dictionary(
        uniqueKeysWithValues: AIExtend.AIModel.partnerModels.map { ($0, String(AIExtend.tuneID(for: $0))) })
    @State private var flux = String(AIExtend.fluxTune)
    @State private var prompt = AIExtend.extendPrompt
    @State private var cdmpoolToken = OFDRM.token

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Astria API key", text: $key)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Picker("Default model", selection: $model) {
                        ForEach(AIExtend.AIModel.partnerModels) { Text($0.rawValue).tag($0) }
                    }
                } header: {
                    Text("AI (cloud)")
                } footer: {
                    Text("Used for the AI features — Edit with AI, Create with AI (text→image), Extend with AI (Flux outpaint), and training your own Tunes. Your account's Tunes are pulled automatically and can be picked in Edit/Create. These upload to Astria; the rest of the app stays offline. Leave the key blank to disable. Note: providers run content moderation and may refuse some prompts.")
                }

                Section {
                    ForEach(AIExtend.AIModel.partnerModels) { m in
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
                    Text("Each model is an Astria gallery tune — paste a tune ID from its gallery page to override the built-in default. The Flux tune powers “Extend with AI” (masked outpaint) and is also the base new Tunes are trained on.")
                }

                Section("Extend prompt") {
                    TextField("Prompt", text: $prompt, axis: .vertical).font(.callout)
                    Button("Reset to default") { prompt = AIExtend.defaultPrompt }
                }

                Section {
                    SecureField("CDMPOOL API token", text: $cdmpoolToken)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: {
                    Text("OF DRM")
                } footer: {
                    Text("Optional. Lets the OF downloader decrypt DRM-protected videos using your cdmpool.xyz account: the app fetches the manifest, and cdmpool runs the Widevine license handshake to return the key (decryption uses FFmpegKit, which must be added to the project). Note: this relays your OF license headers through cdmpool. Leave blank to skip DRM videos.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        for m in AIExtend.AIModel.partnerModels {
                            if let id = Int(tunes[m]?.trimmingCharacters(in: .whitespaces) ?? "") {
                                AIExtend.setTune(id, for: m)
                            }
                        }
                        if let id = Int(flux.trimmingCharacters(in: .whitespaces)) { AIExtend.setFluxTune(id) }
                        AIExtend.save(apiKey: key, defaultModel: model, prompt: prompt)
                        OFDRM.setToken(cdmpoolToken)
                        dismiss()
                    }
                }
            }
        }
    }
}
