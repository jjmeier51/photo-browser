import Foundation

/// Reads the `gallery.json` sidecars the Mac pornpics downloaders (`mac/pornpics_*.py`) leave in
/// every gallery folder, so a star's folder (e.g. `Porn/Briana Banks/`) can be filtered by the
/// galleries' site categories ("Blonde", "Stockings", …).
///
/// The sidecars themselves are hidden from the grid (`isSidecar`, applied in `Library.listing`) —
/// they're data for this filter, not something to browse.
///
/// Reads are small but one per gallery folder on a slow external drive, so they run detached with
/// bounded fan-out and are cached per folder keyed by `path|mtime` (adding or replacing the JSON
/// bumps the folder's mtime, so an updated download is re-read). "No sidecar" is cached too —
/// most folders in the library aren't galleries and shouldn't be re-probed on every open.
nonisolated enum GalleryCategories {

    /// Sidecar file names the downloaders write; hidden from the grid.
    static let sidecarNames: Set<String> = ["gallery.json", "pornstar.json"]

    static func isSidecar(_ url: URL) -> Bool {
        sidecarNames.contains(url.lastPathComponent.lowercased())
    }

    private final class CachedCategories {
        let value: [String]?
        init(_ value: [String]?) { self.value = value }
    }

    private static let cache: NSCache<NSString, CachedCategories> = {
        let c = NSCache<NSString, CachedCategories>()
        c.countLimit = 20_000
        return c
    }()

    private struct Sidecar: Decodable {
        let categories: [String]?
    }

    /// Categories for every folder in `folders` that holds a readable `gallery.json` (folders
    /// without one are simply absent from the result).
    static func load(for folders: [Entry]) async -> [URL: [String]] {
        let folders = folders.filter(\.isFolder)
        guard !folders.isEmpty else { return [:] }
        return await Task.detached(priority: .utility) { () -> [URL: [String]] in
            var result: [URL: [String]] = [:]
            await withTaskGroup(of: (URL, [String]?).self) { group in
                var index = 0
                let maxConcurrent = 8
                func addNext() {
                    guard index < folders.count else { return }
                    let entry = folders[index]; index += 1
                    group.addTask { (entry.url, categories(in: entry)) }
                }
                for _ in 0..<min(maxConcurrent, folders.count) { addNext() }
                while let (url, cats) = await group.next() {
                    if let cats, !cats.isEmpty { result[url] = cats }
                    addNext()
                }
            }
            return result
        }.value
    }

    private static func categories(in folder: Entry) -> [String]? {
        let key = "\(folder.url.path)|\(Int(folder.modified.timeIntervalSince1970))" as NSString
        if let hit = cache.object(forKey: key) { return hit.value }
        let file = folder.url.appendingPathComponent("gallery.json")
        var cats: [String]?
        if let data = try? Data(contentsOf: file),
           let sidecar = try? JSONDecoder().decode(Sidecar.self, from: data) {
            var seen = Set<String>()
            cats = (sidecar.categories ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        }
        cache.setObject(CachedCategories(cats), forKey: key)
        return cats
    }
}
