import SwiftUI

/// The tag editor for one file, shared by the info panel and the clean-up screens: the file's
/// tags as chips (✕ drops one), a field to type the next (Return or Add adds it), and one-tap
/// suggestions from tags already in use anywhere (prefix-matched to what's typed). Emits its
/// three rows as a `Group`, so inside a `Section` they are separate rows and inside a stack they
/// are stacked. `onDark` styles the field and chips for a dark, non-list surface (the clean-up
/// card's gradient).
struct TagEditor: View {
    @Environment(Library.self) private var library
    let url: URL
    var onDark = false
    @State private var draft = ""

    private var tagsHere: [String] { library.tags(for: url) }

    private var suggestions: [String] {
        let typed = Library.normalizedTag(draft).lowercased()
        let mine = Set(tagsHere.map { $0.lowercased() })
        return library.allTags.filter { !mine.contains($0.lowercased()) && (typed.isEmpty || $0.lowercased().hasPrefix(typed)) }
            .prefix(8).map { $0 }
    }

    private func addFromDraft() {
        let tag = Library.normalizedTag(draft)
        guard !tag.isEmpty else { return }
        library.addTag(tag, to: url)
        draft = ""
    }

    var body: some View {
        Group {
            if !tagsHere.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(tagsHere, id: \.self) { tag in
                            HStack(spacing: 4) {
                                Text(tag).font(.subheadline)
                                Button { library.removeTag(tag, from: url) } label: {
                                    Image(systemName: "xmark.circle.fill").font(.caption)
                                        .foregroundStyle(onDark ? Color.white.opacity(0.7) : Color.secondary)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Remove tag \(tag)")
                            }
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(onDark ? AnyShapeStyle(Color.white.opacity(0.18)) : AnyShapeStyle(.thinMaterial), in: Capsule())
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            HStack {
                TextField("Add a tag", text: $draft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit(addFromDraft)
                    .padding(.horizontal, onDark ? 10 : 0).padding(.vertical, onDark ? 7 : 0)
                    .background(onDark ? AnyShapeStyle(Color.white.opacity(0.12)) : AnyShapeStyle(Color.clear), in: RoundedRectangle(cornerRadius: 8))
                Button("Add", action: addFromDraft)
                    .disabled(Library.normalizedTag(draft).isEmpty)
            }
            if !suggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(suggestions, id: \.self) { tag in
                            Button(tag) { library.addTag(tag, to: url); draft = "" }
                                .buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                }
            }
        }
        .foregroundStyle(onDark ? Color.white : Color.primary)
    }
}
