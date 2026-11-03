import Foundation

/// The shared record of taylorpictures.net albums downloaded into a Taylor Swift folder —
/// `<folder>/.taylorpictures.json`, written by this app's `TaylorDownloads` and by Safe Finder's
/// taylorpictures.net window (`mac/taylor.py` `Record`), so each marks as downloaded what the other has
/// downloaded. The phone's own list (`Library.downloadedTaylorAlbums`) takes in the record's albums whenever
/// the browser opens on that folder.
///
/// Format (shared with the Mac — keep in step): `{"version": 1, "albums": {"<album id>": {"title", "folder"
/// (relative to the Taylor folder), "files" (names in it), "total" (the album's photo count), "downloaded"
/// (unix time)}}}`. Every write reads the file first and merges (file names unioned, the larger total kept),
/// so the two apps never drop each other's albums. The file is hidden (dot name) and written through
/// `DriveWriter` (CLAUDE.md #12).
enum TaylorRecord {
    nonisolated static let fileName = ".taylorpictures.json"

    /// Album ids the record holds any downloaded photos for.
    nonisolated static func albumIDs(in root: URL) -> Set<Int> {
        guard let albums = read(root) else { return [] }
        var out = Set<Int>()
        for (key, value) in albums {
            guard let id = Int(key), let entry = value as? [String: Any],
                  let files = entry["files"] as? [String], !files.isEmpty else { continue }
            out.insert(id)
        }
        return out
    }

    nonisolated private static func read(_ root: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent(fileName)),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return obj["albums"] as? [String: Any]
    }

    /// Notes an album downloaded into `folder` (inside `root`): the photos now in that folder and how many
    /// the album has. Merged with what's on the drive.
    @concurrent nonisolated static func note(album: TaylorGallery.Album, folder: URL, root: URL, total: Int) async {
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
        guard !files.isEmpty else { return }
        var albums = read(root) ?? [:]
        let key = String(album.id)
        let old = albums[key] as? [String: Any] ?? [:]
        let oldFiles = old["files"] as? [String] ?? []
        let oldTotal = (old["total"] as? NSNumber)?.intValue ?? 0
        let rootPath = root.standardizedFileURL.path
        let folderPath = folder.standardizedFileURL.path
        let relative = folderPath.hasPrefix(rootPath + "/") ? String(folderPath.dropFirst(rootPath.count + 1))
                                                             : folder.lastPathComponent
        let entry: [String: Any] = ["title": album.title, "folder": relative,
                                    "files": Array(Set(oldFiles).union(files)).sorted(),
                                    "total": max(total, oldTotal),
                                    "downloaded": Date().timeIntervalSince1970]
        albums[key] = entry
        let payload: [String: Any] = ["version": 1, "albums": albums]
        guard let data = try? JSONSerialization.data(withJSONObject: payload,
                                                     options: [.prettyPrinted, .sortedKeys]) else { return }
        try? await DriveWriter.shared.writeData(data, to: root.appendingPathComponent(fileName))
    }
}
