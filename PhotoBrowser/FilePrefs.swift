import Foundation

/// The path-keyed collections that used to live in `UserDefaults` — folder covers, custom item
/// thumbnails, birthdays, hidden lists, highlight folders, the downloaders' per-folder records,
/// AI prompts, Messages archives — each kept as its own property-list file in Application Support.
///
/// Why: `UserDefaults` rejects any single value of 4 MB or more and corrupts the prefs when it
/// does (the crash `Library.saveBulk` was introduced for), and several of these grow without bound
/// — `folderCovers` gains an entry for every folder ever shown, the downloader records hold every
/// downloaded id. A file has no such limit.
///
/// The API mirrors the slice of `UserDefaults` the library uses (`set`, `dictionary`,
/// `stringArray`, `data`), so moving a store here is a one-word change at each call. A key's
/// `UserDefaults` value moves over on its first read and the old key is then removed. Reads come
/// from memory after the first; writes go to disk on a serial background queue, latest value
/// wins. Thread-safe: the background persist queue writes through it too.
nonisolated final class FilePrefs: @unchecked Sendable {
    static let shared = FilePrefs()

    private let dir: URL
    private let lock = NSLock()
    private var cache: [String: Any] = [:]          // key → value, or NSNull for "absent"
    private let queue = DispatchQueue(label: "photoBrowser.filePrefs", qos: .utility)

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dir = base.appendingPathComponent("prefs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func fileURL(_ key: String) -> URL {
        dir.appendingPathComponent(key.replacingOccurrences(of: "/", with: "_") + ".plist")
    }

    // MARK: - Reading

    func object(forKey key: String) -> Any? {
        lock.lock(); defer { lock.unlock() }
        if let v = cache[key] { return v is NSNull ? nil : v }
        let v = loadLocked(key)
        cache[key] = v ?? NSNull()
        return v
    }

    func dictionary(forKey key: String) -> [String: Any]? { object(forKey: key) as? [String: Any] }
    func stringArray(forKey key: String) -> [String]? { object(forKey: key) as? [String] }
    func data(forKey key: String) -> Data? { object(forKey: key) as? Data }

    /// The file's value, else the legacy `UserDefaults` value — written to its file and then removed
    /// from `UserDefaults` (only once the file is safely written).
    private func loadLocked(_ key: String) -> Any? {
        let url = fileURL(key)
        if let data = try? Data(contentsOf: url),
           let value = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) {
            return value
        }
        guard let legacy = UserDefaults.standard.object(forKey: key) else { return nil }
        if Self.write(legacy, to: url) { UserDefaults.standard.removeObject(forKey: key) }
        return legacy
    }

    // MARK: - Writing

    func set(_ value: Any?, forKey key: String) {
        lock.lock()
        cache[key] = value ?? NSNull()
        lock.unlock()
        let url = fileURL(key)
        queue.async { [weak self] in
            guard let self else { return }
            // Write whatever is current when the queue gets here, so a burst of sets writes the
            // latest value (and a removal removes the file).
            self.lock.lock()
            let current = self.cache[key]
            self.lock.unlock()
            if let current, !(current is NSNull) { _ = Self.write(current, to: url) }
            else { try? FileManager.default.removeItem(at: url) }
        }
    }

    func removeObject(forKey key: String) { set(nil, forKey: key) }

    /// Blocks until every queued write is on disk — for the app going to the background.
    func flush() { queue.sync {} }

    private static func write(_ value: Any, to url: URL) -> Bool {
        guard PropertyListSerialization.propertyList(value, isValidFor: .binary),
              let data = try? PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
        else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }
}
