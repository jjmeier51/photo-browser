import SwiftUI

/// Shown when a move would collide with same-named files in the destination.
/// Previews each conflict — the item being moved next to the file already there —
/// so the user can tell whether they're actually different, then choose to keep
/// both (move under a new name) or skip the matching items.
struct MoveConflictView: View {
    @Environment(\.dismiss) private var dismiss
    let dest: URL
    let items: [Entry]
    let onMoveAll: () -> Void
    let onSkip: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                Text("\(items.count) item\(items.count == 1 ? "" : "s") already have a file with the same name in “\(dest.lastPathComponent)”. They may be different — compare below, then keep both (moved under a new name) or skip them.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding()

                LazyVStack(spacing: 16) {
                    ForEach(items) { item in
                        VStack(spacing: 6) {
                            Text(item.name).font(.caption.weight(.medium)).lineLimit(1)
                            HStack(spacing: 10) {
                                thumb(item, caption: "Moving")
                                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                                thumb(existing(item), caption: "Already here")
                            }
                        }
                        Divider()
                    }
                }
                .padding(.horizontal)
            }
            .navigationTitle("Same Names")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 12) {
                    Button("Skip These") { onSkip() }.buttonStyle(.bordered).frame(maxWidth: .infinity)
                    Button("Move All (Keep Both)") { onMoveAll() }.buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
                }
                .padding().background(.bar)
            }
        }
    }

    private func existing(_ item: Entry) -> Entry {
        let u = dest.appendingPathComponent(item.name)
        return Entry(url: u, name: item.name, kind: classify(url: u, isDirectory: false), size: 0, modified: .distantPast)
    }

    private func thumb(_ e: Entry, caption: String) -> some View {
        VStack(spacing: 3) {
            EntryCell(entry: e)
                .frame(width: 130, height: 130)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(caption).font(.caption2).foregroundStyle(.secondary)
        }
    }
}
