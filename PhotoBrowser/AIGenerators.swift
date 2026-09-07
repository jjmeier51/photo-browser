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

/// The base model a NEW tune is trained on (Astria `branch`). Flux is the default and the only one
/// that can later be composed as a LoRA on top of another prompt.
enum TuneBaseModel: String, CaseIterable, Identifiable, Sendable {
    case flux = "Flux", sdxl = "SDXL", sd15 = "SD 1.5"
    var id: String { rawValue }
    var branch: String {
        switch self {
        case .flux: return "flux1"
        case .sdxl: return "sdxl1"
        case .sd15: return "sd15"
        }
    }
    /// Flux trains on a specific base tune; SDXL/SD1.5 default their base from the branch.
    var baseTuneID: Int? { self == .flux ? AIExtend.trainingBaseTune : nil }
    var note: String {
        switch self {
        case .flux: return "Flux — best quality, and the only base you can layer on other prompts as a tune."
        case .sdxl: return "SDXL — faster/cheaper training."
        case .sd15: return "SD 1.5 — smallest/oldest base."
        }
    }
}
