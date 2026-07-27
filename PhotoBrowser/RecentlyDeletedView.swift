import SwiftUI
import UIKit

/// Recently Deleted — the drive's 30-day trash. Items moved here by a delete can be restored to their
/// original location or removed permanently; anything older than 30 days is auto-purged when a root
/// opens (and when this view appears). Labels/captions were left keyed to the original path when the
/// item was trashed, so a restore reconnects them automatically.
struct RecentlyDeletedView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var confirmEmpty = false

    private var items: [TrashEntry] { library.trash.sorted { $0.deletedAt > $1.deletedAt } }

    var body: some View {
        NavigationStack {
            Group {
                if items.isEmpty {
                    ContentUnavailableView("No Recently Deleted", systemImage: "trash",
                        description: Text("Items you delete are kept here for 30 days so you can restore them."))
                } else {
                    List {
                        Section {
                            ForEach(items) { row($0) }
                        } footer: {
                            Text("Items are kept for 30 days, then permanently removed.")
                        }
                    }
                }
            }
            .navigationTitle("Recently Deleted")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !items.isEmpty { Button("Empty", role: .destructive) { confirmEmpty = true }.tint(.red) }
                }
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .confirmationDialog("Permanently delete all \(items.count) item(s)? This can't be undone.",
                                isPresented: $confirmEmpty, titleVisibility: .visible) {
                Button("Delete All", role: .destructive) { emptyAll() }
                Button("Cancel", role: .cancel) {}
            }
            .onAppear { library.purgeExpiredTrash() }
        }
    }

    private func row(_ item: TrashEntry) -> some View {
        HStack(spacing: 12) {
            TrashThumb(item: item)
                .frame(width: 54, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).lineLimit(1)
                Text(deletedText(item)).font(.caption).foregroundStyle(.secondary)
                Text(item.originalPath).font(.caption2).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 0)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) { purge(item) } label: { Label("Delete", systemImage: "trash") }
            Button { restore(item) } label: { Label("Restore", systemImage: "arrow.uturn.backward") }.tint(.blue)
        }
        .contextMenu {
            Button { restore(item) } label: { Label("Restore", systemImage: "arrow.uturn.backward") }
            Button(role: .destructive) { purge(item) } label: { Label("Delete Forever", systemImage: "trash") }
        }
    }

    private func deletedText(_ item: TrashEntry) -> String {
        let deleted = Date(timeIntervalSince1970: item.deletedAt)
        let daysLeft = max(0, 30 - Int(Date().timeIntervalSince(deleted) / 86_400))
        let rel = deleted.formatted(.relative(presentation: .named))
        return "Deleted \(rel) · \(daysLeft) day\(daysLeft == 1 ? "" : "s") left"
    }

    private func restore(_ item: TrashEntry) {
        Haptics.light()
        if FileActions.restoreFromTrash(item) != nil {
            library.removeTrashRecords([item.id])
            library.contentDidChange()
        }
    }
    private func purge(_ item: TrashEntry) {
        Haptics.warning()
        FileActions.purgeTrash([item])
        library.removeTrashRecords([item.id])
    }
    private func emptyAll() {
        Haptics.warning()
        let all = library.trash
        FileActions.purgeTrash(all)
        library.removeTrashRecords(all.map(\.id))
    }
}

/// A lazily-loaded thumbnail for a trashed file (built from its current `.Trash` path).
private struct TrashThumb: View {
    let item: TrashEntry
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: item.isFolder ? "folder.fill" : "photo").foregroundStyle(.secondary)
            }
        }
        .task(id: item.id) {
            guard !item.isFolder else { return }
            let url = URL(fileURLWithPath: item.trashedPath)
            let entry = Entry(url: url, name: item.name,
                              kind: classify(url: url, isDirectory: false), size: 0, modified: Date())
            image = await Thumbnailer.shared.thumbnail(for: entry, size: CGSize(width: 120, height: 120), scale: 2)
        }
    }
}
