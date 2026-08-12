import SwiftUI

/// Previews AI-generated images with a Keep/Delete choice each. Keep saves into
/// an "AI" subfolder of the original's folder (created on first use), inheriting
/// the original's EXIF. Delete discards.
struct AIResultsView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let original: URL
    let results: [Data]
    var model: String? = nil       // AI model used (e.g. "Seedream 4.5"), for metadata + search
    var prompt: String? = nil      // the edit prompt used

    private enum Decision { case kept, deleted }
    @State private var decided: [Int: Decision] = [:]
    @State private var savedAny = false
    /// Decoded once (not per body pass): re-decoding every full-res result on each Keep/Delete tap —
    /// every one re-renders this body — is what made the review feel laggy.
    @State private var images: [UIImage?] = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    ForEach(results.indices, id: \.self) { i in
                        VStack(spacing: 10) {
                            if let ui = images.indices.contains(i) ? images[i] : UIImage(data: results[i]) {
                                Image(uiImage: ui).resizable().scaledToFit()
                                    .frame(maxHeight: 380)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                            switch decided[i] {
                            case .kept:
                                Label("Saved to “AI” folder", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                            case .deleted:
                                Label("Discarded", systemImage: "trash").foregroundStyle(.secondary)
                            case nil:
                                HStack(spacing: 12) {
                                    Button { keep(i) } label: { Label("Keep", systemImage: "checkmark").frame(maxWidth: .infinity) }
                                        .buttonStyle(.borderedProminent)
                                    Button(role: .destructive) { decided[i] = .deleted; finishIfDone() } label: {
                                        Label("Delete", systemImage: "trash").frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle(results.count == 1 ? "AI Result" : "\(results.count) AI Results")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { if savedAny { library.contentDidChange() }; dismiss() }
                }
            }
        }
        .interactiveDismissDisabled(decided.count < results.count)
        .task {
            guard images.isEmpty else { return }
            images = results.map { UIImage(data: $0) }   // decode wrappers once, reused across re-renders
        }
    }

    private func keep(_ i: Int) {
        let data = results[i], orig = original, m = model, p = prompt
        Task {
            let url = await Task.detached(priority: .userInitiated) {
                AIExtend.saveToAIFolder(data, basedOn: orig, model: m, prompt: p)
            }.value
            decided[i] = .kept
            if let url { savedAny = true; library.markAIGenerated(url, model: m, prompt: p) }
            finishIfDone()
        }
    }

    /// Once every result is kept or discarded, return to the photo automatically.
    private func finishIfDone() {
        guard decided.count >= results.count else { return }
        if savedAny { library.contentDidChange() }
        dismiss()
    }
}
