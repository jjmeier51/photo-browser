import SwiftUI

/// Shown when a move would collide with same-named files in the destination.
/// Previews each conflict — the item being moved next to the file already there —
/// and lets the user pick *per item* which ones to move (kept under a new name)
/// and which to leave behind. Anything not in conflict moves normally regardless.
struct MoveConflictView: View {
    @Environment(\.dismiss) private var dismiss
    let dest: URL
    let items: [Entry]
    let verb: String        // "Move" or "Copy"
    /// The conflicting items the user chose to keep (under a new name); rest skipped.
    let onConfirm: (Set<URL>) -> Void

    @State private var keep: Set<URL>

    init(dest: URL, items: [Entry], verb: String = "Move", onConfirm: @escaping (Set<URL>) -> Void) {
        self.dest = dest
        self.items = items
        self.verb = verb
        self.onConfirm = onConfirm
        _keep = State(initialValue: Set(items.map(\.url)))   // default: keep both for all
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                Text("\(items.count) item\(items.count == 1 ? "" : "s") already have a file with the same name in “\(dest.lastPathComponent)”. They may be different — compare below and pick which to \(verb.lowercased()) (kept under a new name). Unselected ones are skipped; everything else in your selection \(verb.lowercased())s normally.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding()

                LazyVStack(spacing: 16) {
                    ForEach(items) { item in
                        Button { toggle(item.url) } label: { row(item) }
                            .buttonStyle(.plain)
                        Divider()
                    }
                }
                .padding(.horizontal)
            }
            .navigationTitle("Same Names")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button(allSelected ? "Deselect All" : "Select All") {
                        keep = allSelected ? [] : Set(items.map(\.url))
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button { onConfirm(keep) } label: {
                    Text(confirmLabel).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding().background(.bar)
            }
        }
    }

    private var allSelected: Bool { keep.count == items.count }

    private var confirmLabel: String {
        if keep.isEmpty { return "Skip All & \(verb) the Rest" }
        if allSelected { return "\(verb) All (Keep Both)" }
        return "\(verb) \(keep.count) Selected (Keep Both)"
    }

    private func toggle(_ u: URL) { if keep.contains(u) { keep.remove(u) } else { keep.insert(u) } }

    private func row(_ item: Entry) -> some View {
        let on = keep.contains(item.url)
        return VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.title3).foregroundStyle(on ? Color.accentColor : Color.secondary)
                Text(item.name).font(.caption.weight(.medium)).lineLimit(1)
                Spacer()
            }
            HStack(spacing: 10) {
                thumb(item, caption: verb == "Copy" ? "Copying" : "Moving")
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                thumb(existing(item), caption: "Already here")
            }
        }
        .opacity(on ? 1 : 0.45)
        .contentShape(Rectangle())
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
