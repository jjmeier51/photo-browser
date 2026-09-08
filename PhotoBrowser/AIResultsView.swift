import SwiftUI
import ImageIO
import UniformTypeIdentifiers

/// Where a kept AI result is saved.
/// - `.edit`: over a source photo — saves into an "AI" subfolder beside it, inheriting its EXIF/date.
/// - `.create`: no source (Create with AI) — saves into an "AI" subfolder of the target folder.
enum AISaveTarget: Hashable {
    case edit(original: URL)
    case create(folder: URL)

    /// The folder whose grid should refresh after saving (the AI subfolder's parent).
    var parentFolder: URL {
        switch self {
        case .edit(let original): return original.deletingLastPathComponent()
        case .create(let folder): return folder
        }
    }
}

/// Previews AI-generated images with a Keep/Delete choice each. Keep saves into an "AI" subfolder;
/// Delete discards. Used for both Edit with AI (results based on a source photo) and Create with AI
/// (results generated from a text prompt).
struct AIResultsView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let target: AISaveTarget
    let results: [Data]
    var model: String? = nil       // AI model / tune used, for metadata + search
    var prompt: String? = nil      // the prompt used

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
                            if let ui = images.indices.contains(i) ? images[i] : nil {
                                Image(uiImage: ui).resizable().scaledToFit()
                                    .frame(maxHeight: 380)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                            } else {
                                RoundedRectangle(cornerRadius: 10).fill(.quaternary)
                                    .frame(height: 240)
                                    .overlay { ProgressView() }
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
                    if results.count > 1 {
                        // Bulk Keep-all — a small quality-of-life win when a batch is all good.
                        Button { keepAll() } label: {
                            Label("Keep All", systemImage: "square.and.arrow.down.on.square").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(decided.count >= results.count)
                    }
                }
                .padding()
            }
            .navigationTitle(results.count == 1 ? "AI Result" : "\(results.count) AI Results")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { finish() }
                }
            }
        }
        .interactiveDismissDisabled(decided.count < results.count)
        .task {
            guard images.isEmpty else { return }
            images = Array(repeating: nil, count: results.count)   // show placeholders while decoding
            let data = results
            // Decode DOWNSAMPLED and OFF the main thread. `UIImage(data:)` defers decode to first
            // draw on the main thread — several full-res (up to 4K) results decoding at render time is
            // what made reviewing a batch hitch. ImageIO downsamples to ~display size with immediate
            // caching, so the SwiftUI render is cheap. The full-res `results` Data is still used for
            // saving. Fill them in one at a time so the first result appears fast.
            for i in data.indices {
                let ui = await Task.detached(priority: .userInitiated) { Self.downsample(data[i], maxPixel: 1400) }.value
                if images.indices.contains(i) { images[i] = ui }
            }
        }
    }

    /// Decodes `data` to a display-sized `UIImage` via ImageIO (bounded long side), fully decoded so
    /// no work happens on the main thread at draw time. Falls back to a plain wrapper if it can't.
    private nonisolated static func downsample(_ data: Data, maxPixel: CGFloat) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return UIImage(data: data) }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return UIImage(data: data) }
        return UIImage(cgImage: cg)
    }

    private func keep(_ i: Int) {
        guard decided[i] == nil else { return }
        decided[i] = .kept                       // optimistic — avoids a double-tap re-saving
        let data = results[i], tgt = target, m = model, p = prompt
        Task {
            let url = await Task.detached(priority: .userInitiated) { () -> URL? in
                switch tgt {
                case .edit(let original): return AIExtend.saveToAIFolder(data, basedOn: original, model: m, prompt: p)
                case .create(let folder): return AIExtend.saveGeneratedToFolder(data, in: folder, model: m, prompt: p)
                }
            }.value
            if let url { savedAny = true; library.markAIGenerated(url, model: m, prompt: p) }
            finishIfDone()
        }
    }

    private func keepAll() {
        for i in results.indices where decided[i] == nil { keep(i) }
    }

    /// Once every result is kept or discarded, return automatically.
    private func finishIfDone() {
        guard decided.count >= results.count else { return }
        finish()
    }

    /// Close the review and reopen the creator (Edit/Create) it came from, pre-filled with the same
    /// settings, so the user can immediately run again. The reopen is deferred a moment so SwiftUI
    /// finishes dismissing this sheet before presenting the next.
    private func finish() {
        if savedAny { library.contentDidChange() }
        let tgt = target, lib = library
        dismiss()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            lib.reopenCreator(after: tgt)
        }
    }
}
