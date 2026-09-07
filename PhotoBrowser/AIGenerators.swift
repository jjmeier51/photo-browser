import SwiftUI

/// Two independent pickers for Edit / Create with AI: a base **Model** and, optionally, one of the
/// account's own **Tunes**. Picking Flux as the model composes the tune as a LoRA on top (a real
/// model+tune combination); a partner model can't run a LoRA, so a selected tune runs on its own base.
struct AIModelTunePicker: View {
    @Binding var model: AIExtend.AIModel
    @Binding var tune: AIExtend.AstriaTune?     // nil = None
    let tunes: [AIExtend.AstriaTune]

    var body: some View {
        Picker("Model", selection: $model) {
            ForEach(AIExtend.AIModel.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.menu)
        Picker("Tune", selection: $tune) {
            Text("None").tag(AIExtend.AstriaTune?.none)
            ForEach(tunes) { t in
                Text(t.ready ? t.label : "\(t.label) (training…)").tag(AIExtend.AstriaTune?.some(t))
            }
        }
        .pickerStyle(.menu)
        .disabled(tunes.isEmpty)
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
    var note: String {
        switch self {
        case .nanoBanana2:   return "Nano Banana 2 — trains on the partner model."
        case .seedream5Pro:  return "Seedream 5.0 Pro — trains on the partner model."
        case .flux:          return "Flux — high quality, and the only base you can later layer on a prompt as a tune."
        case .sdxl:          return "SDXL — faster/cheaper training."
        case .sd15:          return "SD 1.5 — smallest/oldest base."
        }
    }
}
