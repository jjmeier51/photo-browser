import SwiftUI

/// Tags on folders. A folder carries tags of its own, like a file (`Library.tags`, keyed by its path —
/// re-keyed on move/rename with everything else, shared with Safe Finder through the drive's tag file,
/// carried in the folder's own attribute). It shows up under those tags in the Tags filter, checked in
/// its long-press Tags menu, and in its Get Info.
///
/// When a tag goes on (or comes off) folders, the person is asked whether the files inside them — at any
/// depth, from the drive index — change too: "Folder and Items Inside" / "Folder Only" / Cancel. Only the
/// files the change would touch are counted, and when there are none, nothing is asked. Safe Finder asks
/// the same question (`mac/safe_finder.py`, `ask_inside`).

/// A tag about to go on (or come off) some items, folders among them, waiting on the question.
struct FolderTagQuestion: Identifiable {
    let id = UUID()
    let tag: String
    let remove: Bool
    let targets: [URL]          // the items themselves, folders included
    let folders: [URL]
    let inside: [URL]           // files inside the folders that the change would touch

    var title: String { remove ? "Remove “\(tag)”" : "Tag “\(tag)”" }

    var message: String {
        let what = folders.count == 1 ? "“\(folders[0].lastPathComponent)”" : "these \(folders.count) folders"
        let n = inside.count
        let items = "\(n) item\(n == 1 ? "" : "s")"
        return remove ? "Also remove it from the \(items) inside \(what) that have it?"
                      : "Also tag the \(items) inside \(what)?"
    }

    var bothLabel: String { folders.count == 1 ? "Folder and Items Inside" : "Folders and Items Inside" }
    var onlyLabel: String { folders.count == 1 ? "Folder Only" : "Folders Only" }
}

extension Library {
    /// The files inside `folders`, at any depth — from the drive index when it covers them, else read
    /// from the drive — leaving out hidden items and the downloaders' sidecars. Off the main actor.
    func filesInside(_ folders: [URL]) async -> [URL] {
        let prefixes = folders.map { $0.path + "/" }
        guard !prefixes.isEmpty else { return [] }
        let idx = index                                    // snapshot on the main actor
        let rootPath = rootURL?.path
        return await Task.detached(priority: .userInitiated) { () -> [URL] in
            func keep(_ url: URL) -> Bool {
                !url.lastPathComponent.hasPrefix(".") && !GalleryCategories.isSidecar(url)
            }
            if let rootPath, !idx.isEmpty, folders.allSatisfy({ $0.path.hasPrefix(rootPath + "/") }) {
                return idx.compactMap { e -> URL? in
                    guard !e.isFolder, keep(e.url) else { return nil }
                    let p = e.url.path
                    return prefixes.contains { p.hasPrefix($0) } ? e.url : nil
                }
            }
            var out: [URL] = []
            for folder in folders {
                guard let walk = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                                                options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
                for case let url as URL in walk {
                    let dir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                    if !dir && keep(url) { out.append(url) }
                }
            }
            return out
        }.value
    }

    /// What putting `tag` on `targets` (or taking it off) needs: nil when no folder is among them, or
    /// none of the files inside would change — then just `applyTag`; else the question to put.
    func folderTagQuestion(_ tag: String, remove: Bool, targets: [URL], folders: [URL]) async -> FolderTagQuestion? {
        guard !folders.isEmpty else { return nil }
        let inside = await filesInside(folders).filter { hasTag(tag, $0) == remove }
        guard !inside.isEmpty else { return nil }
        return FolderTagQuestion(tag: tag, remove: remove, targets: targets, folders: folders, inside: inside)
    }

    /// Puts the tag on (or takes it off) every one of `targets`. Returns the result line for a toast.
    @discardableResult
    func applyTag(_ tag: String, remove: Bool, targets: [URL]) -> String {
        let n = remove ? removeTag(tag, from: targets) : addTag(tag, to: targets)
        let items = "\(n) item\(n == 1 ? "" : "s")"
        if n == 0 { return remove ? "None of those have “\(tag)”." : "Those already have “\(tag)”." }
        return remove ? "Removed “\(tag)” from \(items)." : "Tagged \(items) “\(tag)”."
    }

    /// The question answered: the items themselves, and the files inside too when `inside`.
    func answer(_ q: FolderTagQuestion, inside: Bool) -> String {
        applyTag(q.tag, remove: q.remove, targets: q.targets + (inside ? q.inside : []))
    }
}

/// Puts a `FolderTagQuestion` as an alert and applies the answer; `done` gets the result line.
struct FolderTagPrompt: ViewModifier {
    @Environment(Library.self) private var library
    @Binding var question: FolderTagQuestion?
    let done: (String) -> Void

    func body(content: Content) -> some View {
        content.alert(question?.title ?? "", isPresented: Binding(get: { question != nil },
                                                                 set: { if !$0 { question = nil } }),
                      presenting: question) { q in
            Button(q.bothLabel) { done(library.answer(q, inside: true)); question = nil }
            Button(q.onlyLabel) { done(library.answer(q, inside: false)); question = nil }
            Button("Cancel", role: .cancel) { question = nil }
        } message: { q in
            Text(q.message)
        }
    }
}

extension View {
    /// Asks about the items inside when a tag goes on (or comes off) folders — see `FolderTagQuestion`.
    func folderTagPrompt(_ question: Binding<FolderTagQuestion?>, done: @escaping (String) -> Void) -> some View {
        modifier(FolderTagPrompt(question: question, done: done))
    }
}
