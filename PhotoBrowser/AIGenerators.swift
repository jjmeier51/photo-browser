import SwiftUI

/// Two independent pickers for Edit / Create with AI: a base **Model** and, optionally, one of the
/// account's own **Tunes**. Picking Flux as the model composes the tune as a LoRA on top (a real
/// model+tune combination); a partner model can't run a LoRA, so a selected tune runs on its own base.
struct AIModelTunePicker: View {
    @Binding var model: AIExtend.AIModel
    @Binding var tunes: [AIExtend.AstriaTune]   // selected tunes (0…maxTunes), layering order preserved
    let allTunes: [AIExtend.AstriaTune]

    /// Only the tunes that can actually run on the chosen model — a Flux LoRA can't run on a partner
    /// model and vice-versa, so filtering here keeps the user from ever building an impossible pair.
    private var compatible: [AIExtend.AstriaTune] { AIExtend.tunes(allTunes, compatibleWith: model) }

    var body: some View {
        Picker("Model", selection: $model) {
            ForEach(AIExtend.AIModel.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.menu)
        .onChange(of: model) { _, _ in
            // Switching to a model the selected tunes can't run on drops the incompatible ones, so an
            // impossible combination (and its cryptic Astria error) can never be submitted.
            tunes = tunes.filter { t in compatible.contains { $0.id == t.id } }
        }
        NavigationLink {
            TuneMultiSelectView(selected: $tunes, options: compatible)
        } label: {
            HStack {
                Text("Tunes")
                Spacer()
                Text(summary).foregroundStyle(.secondary)
            }
        }
        .disabled(compatible.isEmpty)
    }

    private var summary: String {
        switch tunes.count {
        case 0: return "None"
        case 1: return tunes[0].label
        default: return "\(tunes.count) selected"
        }
    }
}

/// Multi-select list of the tunes compatible with the chosen model. Tapping toggles membership
/// (up to `AIExtend.maxTunes`); the selection order is the layering order used in the prompt.
struct TuneMultiSelectView: View {
    @Binding var selected: [AIExtend.AstriaTune]
    let options: [AIExtend.AstriaTune]

    private func isSelected(_ t: AIExtend.AstriaTune) -> Bool { selected.contains { $0.id == t.id } }
    private func toggle(_ t: AIExtend.AstriaTune) {
        if let i = selected.firstIndex(where: { $0.id == t.id }) { selected.remove(at: i) }
        else if selected.count < AIExtend.maxTunes { selected.append(t) }
    }

    var body: some View {
        List {
            Section {
                ForEach(options) { t in
                    Button { toggle(t) } label: {
                        HStack {
                            Text(t.ready ? t.label : "\(t.label) (training…)")
                                .foregroundStyle(.primary)
                            Spacer()
                            if let n = selected.firstIndex(where: { $0.id == t.id }) {
                                // Show the layering order (1-based) next to the check.
                                Text("\(n + 1)").foregroundStyle(.secondary)
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!isSelected(t) && selected.count >= AIExtend.maxTunes)
                }
            } footer: {
                Text("Combine up to \(AIExtend.maxTunes) tunes in one generation. On Flux they stack as LoRAs; on Seedream/Nano as FaceIDs. Fewer, complementary tunes (e.g. a subject + a style) work best — many of the same subject can dilute the likeness.")
            }
        }
        .navigationTitle("Tunes — \(selected.count) selected")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The base model a NEW tune is trained on. This can be a partner gallery model (Nano Banana 2 /
/// Seedream 5.0 Pro) — sent as `base_tune_id` with the branch inherited — or a raw branch
/// (Flux / SDXL / SD 1.5). Flux is the only base that can later be composed as a LoRA on a prompt.
enum TuneBaseModel: String, CaseIterable, Identifiable, Sendable {
    case nanoBanana2 = "Nano Banana 2"
    case seedream5Pro = "Seedream 5.0 Pro"
    case flux = "Flux"
    case sdxl = "SDXL"
    case sd15 = "SD 1.5"
    var id: String { rawValue }

    /// Astria `branch` to send, or nil to inherit it from the base tune (the partner models).
    var branch: String? {
        switch self {
        case .flux: return "flux1"
        case .sdxl: return "sdxl1"
        case .sd15: return "sd15"
        case .nanoBanana2, .seedream5Pro: return nil     // inherited from the base gallery tune
        }
    }
    /// `base_tune_id` to train on, or nil to let Astria default it from the branch (SDXL / SD1.5).
    var baseTuneID: Int? {
        switch self {
        case .flux:          return AIExtend.trainingBaseTune
        case .nanoBanana2:   return AIExtend.tuneID(for: .nanoBanana2)
        case .seedream5Pro:  return AIExtend.tuneID(for: .seedream5Pro)
        case .sdxl, .sd15:   return nil
        }
    }
    /// Astria `model_type`. The partner models train as **FaceID** (identify by face, no token);
    /// the rest train as LoRA (SDXL is silently switched to PTI by Astria).
    var modelType: String {
        switch self {
        case .nanoBanana2, .seedream5Pro: return "faceid"
        case .flux, .sdxl, .sd15:         return "lora"
        }
    }
    /// FaceID tunes don't use a subject token; the others do.
    var usesToken: Bool { modelType != "faceid" }
    /// Fewest training photos the Train button requires. FaceID only builds an embedding from a
    /// few faces (Astria uses ~3), so requiring 4 made no sense for it; a real fine-tune (LoRA/PTI)
    /// still wants at least a handful.
    var minPhotos: Int { modelType == "faceid" ? 3 : 4 }
    var note: String {
        switch self {
        case .nanoBanana2:   return "Nano Banana 2 — FaceID: builds a face adapter from only your ~3 sharpest photos (extra photos aren't used for training), then generates on Nano Banana 2."
        case .seedream5Pro:  return "Seedream 5.0 Pro — FaceID: builds a face adapter from only your ~3 sharpest photos (extra photos aren't used for training), then generates on Seedream 5.0 Pro."
        case .flux:          return "Flux — a real LoRA trained on ALL your selected photos; the only base you can later layer on a prompt as a tune. Choose this to train on many photos."
        case .sdxl:          return "SDXL — a real fine-tune on all your selected photos; faster/cheaper training."
        case .sd15:          return "SD 1.5 — a real fine-tune on all your selected photos; smallest/oldest base."
        }
    }
}
