import SwiftUI

/// A simple destination picker for moving files: browse the folder tree and tap
/// "Move Here".
struct FolderPicker: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let onPick: (URL) -> Void
    let confirmTitle: String

    @State private var stack: [URL]
    @State private var folders: [Entry] = []

    init(root: URL, confirmTitle: String = "Move Here", startAt: URL? = nil, onPick: @escaping (URL) -> Void) {
        self.onPick = onPick
        self.confirmTitle = confirmTitle
        // Open at the last-used destination (if it's under root and still exists), with
        // back-navigation up to root.
        var initial = [root]
        if let startAt, startAt.standardizedFileURL != root.standardizedFileURL,
           FileManager.default.fileExists(atPath: startAt.path) {
            let rootComps = root.standardizedFileURL.pathComponents
            let destComps = startAt.standardizedFileURL.pathComponents
            if destComps.count > rootComps.count, Array(destComps.prefix(rootComps.count)) == rootComps {
                var cur = root.standardizedFileURL
                for comp in destComps[rootComps.count...] { cur.appendPathComponent(comp); initial.append(cur) }
            }
        }
        _stack = State(initialValue: initial)
    }

    private var current: URL { stack.last ?? stack[0] }

    var body: some View {
        NavigationStack {
            List {
                if folders.isEmpty {
                    Text("No subfolders here").foregroundStyle(.secondary)
                }
                ForEach(folders) { folder in
                    Button {
                        stack.append(folder.url)
                    } label: {
                        HStack {
                            Label(folder.name, systemImage: "folder").foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle(current.lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if stack.count > 1 {
                        Button("Back") { stack.removeLast() }
                    } else {
                        Button("Cancel") { dismiss() }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(confirmTitle) { onPick(current); dismiss() }
                }
            }
            .task(id: current) {
                folders = await library.listing(of: current, sort: .nameAsc).filter { $0.isFolder }
            }
        }
    }
}
