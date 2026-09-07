import SwiftUI

/// What generates an AI image: a built-in partner model, or one of the account's own fine-tunes.
/// Both resolve to an Astria tune id (that's the endpoint we POST to); account tunes also carry a
/// subject token to weave into the prompt.
enum AIGenChoice: Hashable {
    case model(AIExtend.AIModel)
    case tune(AIExtend.AstriaTune)

    var tuneID: Int {
        switch self {
        case .model(let m): return AIExtend.tuneID(for: m)
        case .tune(let t):  return t.id
        }
    }
    var label: String {
        switch self {
        case .model(let m): return m.rawValue
        case .tune(let t):  return t.label
        }
    }
    /// Subject token to weave into the prompt (account fine-tunes only).
    var token: String? {
        switch self {
        case .model:        return nil
        case .tune(let t):  return t.token.isEmpty ? nil : t.token
        }
    }
}

/// A menu picker listing the built-in models and — when loaded — the account's own tunes.
struct AIGeneratorPicker: View {
    @Binding var choice: AIGenChoice
    let tunes: [AIExtend.AstriaTune]

    var body: some View {
        Picker("Model", selection: $choice) {
            Section("Built-in") {
                ForEach(AIExtend.AIModel.allCases) { Text($0.rawValue).tag(AIGenChoice.model($0)) }
            }
            if !tunes.isEmpty {
                Section("My Tunes") {
                    ForEach(tunes) { t in
                        Text(t.ready ? t.label : "\(t.label) (training…)").tag(AIGenChoice.tune(t))
                    }
                }
            }
        }
        .pickerStyle(.menu)
    }
}
