import Foundation

/// Hand-off channel between the **Share Extension** and the main app.
///
/// When you share an Instagram story (or a photo/video) to PhotoBrowser from the system
/// share sheet, the extension can't do the heavy work — it has no drive access and little
/// time/memory. So it just records *what* was shared into the App Group (a URL, or a file it
/// copied into the shared container) and opens the main app via the `photobrowser://` scheme.
/// The app then reads these, asks where to save + which upscale to apply, and downloads.
///
/// This file is intentionally dependency-free (Foundation only) so it can belong to **both**
/// the app and the extension targets — the App Group id and payload shape must match exactly,
/// and sharing one source file guarantees they can't drift.
enum StorySharing {
    /// Must equal the App Group enabled on BOTH targets (see setup steps).
    static let appGroupID = "group.jayymei.PhotoBrowser"
    /// Custom URL scheme the extension uses to wake the app. Declared in the app's URL Types.
    static let urlScheme = "photobrowser"
    static let openHost = "share"                 // photobrowser://share
    private static let key = "photoBrowser.pendingSharedItems"

    /// One thing the user shared into the app.
    struct PendingShare: Codable, Identifiable, Sendable, Equatable {
        enum Kind: String, Codable, Sendable { case url, file }
        var id = UUID()
        var kind: Kind
        /// For `.url`: the shared link. For `.file`: the filename inside the App Group container.
        var value: String
        var isVideoHint: Bool = false             // for `.file`, whether it was a movie
        var timestamp: Double
    }

    static var defaults: UserDefaults? { UserDefaults(suiteName: appGroupID) }

    /// Shared container both targets can write/read files in (extension copies a shared file here).
    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    static func enqueue(_ item: PendingShare) {
        guard let d = defaults else { return }
        var items = load()
        items.append(item)
        if let data = try? JSONEncoder().encode(items) { d.set(data, forKey: key) }
    }

    static func load() -> [PendingShare] {
        guard let d = defaults, let data = d.data(forKey: key),
              let items = try? JSONDecoder().decode([PendingShare].self, from: data) else { return [] }
        return items
    }

    static func clear() { defaults?.removeObject(forKey: key) }
}
