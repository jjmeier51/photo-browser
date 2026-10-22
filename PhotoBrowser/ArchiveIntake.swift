import Foundation

/// Files that reach the app *as files*: anything AirDropped and opened with Photo Browser (a
/// `.pbgallery` from `mac/airdrop_to_iphone.py`, a folder AirDropped from Finder — which arrives as
/// a zip — a PDF, a video, a document…), a file opened from Files ("Open in Photo Browser"), or a
/// file shared through the Share Extension. iOS copies an opened file into `Documents/Inbox`; it is
/// moved at once into the app's own staging folder (Application Support/receivedArchives, excluded
/// from backup) and listed from there, so it outlives a crash or a dismissed sheet and goes away
/// only once it has been put on the drive or discarded. `Library.pendingArchives` is the queue;
/// `ReceivedArchivesView` works it: an archive unpacks into its own folder, any other file is placed
/// as it is. (Named for the archives it started with; it takes every kind of file now.)
///
/// Everything here is synchronous file work on the app's own container — call it from
/// `Task.detached` (constraint 13: a `nonisolated` function awaited from the main actor still runs
/// there).
nonisolated enum ArchiveIntake {

    /// One staged file. `id` is the staged file name, unique within the staging folder.
    struct Received: Identifiable, Sendable, Equatable, Hashable {
        let url: URL
        let size: Int64
        let receivedAt: Date
        /// A zip / `.pbgallery` (by extension or by its first bytes): unpacked into a folder. Any
        /// other file is placed on the drive as it is.
        let isArchive: Bool
        var id: String { url.lastPathComponent }
        /// The name shown — an archive without its extension ("Beautiful Woman Posing" for
        /// "….pbgallery"; also the folder it unpacks to when it has no single top folder), a file as is.
        var title: String { isArchive ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent }
    }

    /// Extensions treated as archives (`Archiver.isZip` catches a zip under any other name).
    static let archiveExtensions: Set<String> = ["pbgallery", "zip"]

    static let stagingDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var dir = base.appendingPathComponent("receivedArchives", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        return dir
    }()

    /// iOS's drop box for files handed to the app ("Open with", "Open in"). Swept on every launch and
    /// foreground in case one arrived while the app wasn't running to see the open-URL call.
    static var inboxDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Inbox", isDirectory: true)
    }

    static func isArchive(_ url: URL) -> Bool {
        archiveExtensions.contains(url.pathExtension.lowercased()) || Archiver.isZip(url)
    }

    /// Moves the file at `url` into staging under its own name (made unique if needed) and returns
    /// the staged item; nil when it isn't a file or can't be moved — the source is left alone then.
    @discardableResult
    static func stage(_ url: URL) -> Received? {
        let fm = FileManager.default
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { return nil }
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var dest = stagingDir.appendingPathComponent(url.lastPathComponent)
        var n = 2
        while fm.fileExists(atPath: dest.path) {
            dest = stagingDir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"); n += 1
        }
        do {
            try fm.moveItem(at: url, to: dest)          // same container → a rename
        } catch {
            // Another volume (a file opened in place) or a refused rename: copy, then drop the source.
            guard (try? fm.copyItem(at: url, to: dest)) != nil else { return nil }
            try? fm.removeItem(at: url)
        }
        // The Share Extension stages each file in a folder of its own so its name survives; sweep
        // that folder once it's empty.
        let parent = url.deletingLastPathComponent()
        if parent.lastPathComponent.hasPrefix("share_"),
           (try? fm.contentsOfDirectory(atPath: parent.path))?.isEmpty == true {
            try? fm.removeItem(at: parent)
        }
        return received(dest)
    }

    /// Everything staged, oldest first.
    static func pending() -> [Received] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: stagingDir, includingPropertiesForKeys: [.fileSizeKey, .creationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        return urls.compactMap(received).sorted { $0.receivedAt < $1.receivedAt }
    }

    /// Moves anything iOS left in Documents/Inbox into staging. Returns what was newly staged.
    static func sweepInbox() -> [Received] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: inboxDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return urls.compactMap(stage)
    }

    static func discard(_ item: Received) {
        try? FileManager.default.removeItem(at: item.url)
    }

    private static func received(_ url: URL) -> Received? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attrs[.type] as? FileAttributeType) != .typeDirectory else { return nil }
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let when = (attrs[.creationDate] as? Date) ?? (attrs[.modificationDate] as? Date) ?? Date()
        return Received(url: url, size: size, receivedAt: when, isArchive: isArchive(url))
    }
}
