import Foundation

/// Downloads files with a **background** `URLSession`, so transfers keep going when the app is
/// suspended or fully closed — the system continues them and relaunches the app to deliver the
/// results. Used by the TikTok downloader.
///
/// Completed files are moved into a local app-container **inbox** (always writable, needs no
/// security-scoped access and no mounted external drive). The app files them onto the actual
/// drive folder on its next foreground pass — see `Library.processPendingTikTok()` — because
/// writing to the security-scoped drive location isn't reliable from a background relaunch.
/// Each task carries its destination + metadata in `taskDescription`, which the session
/// persists across launches, so completions are handled even after the app was killed.
nonisolated final class BackgroundDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let shared = BackgroundDownloader()
    private static let sessionID = "jayymei.PhotoBrowser.bgdownload"
    private static let pendingKey = "photoBrowser.pendingTikTok"

    /// Set by the app delegate when iOS relaunches us to finish background events; called once
    /// the session has delivered them all.
    var backgroundCompletion: (() -> Void)?

    private let lock = NSLock()
    private var session: URLSession!

    override init() {
        super.init()
        // Recreating the session with the same identifier on launch reconnects to in-flight /
        // completed tasks from a prior run, so their completions are delivered here.
        let cfg = URLSessionConfiguration.background(withIdentifier: Self.sessionID)
        cfg.sessionSendsLaunchEvents = true
        cfg.isDiscretionary = false
        cfg.allowsCellularAccess = true
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }

    /// App-container inbox holding completed downloads until they're filed onto the drive.
    static let inbox: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("bgInbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Travels with each task (persisted by the session) so completions can be filed correctly,
    /// even across an app relaunch.
    struct Meta: Codable, Sendable { let dest: String; let createTime: Double; let caption: String; let folder: String; let id: String }

    /// Touching `shared` already recreates the session (see `init`); this just makes that intent
    /// explicit at the call site (app launch / background relaunch).
    func activate() {}

    func enqueue(url: URL, meta: Meta) {
        var req = URLRequest(url: url)
        req.setValue(TikTokService.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("\(TikTokService.apiBase)/", forHTTPHeaderField: "Referer")
        req.timeoutInterval = 600
        let task = session.downloadTask(with: req)
        if let data = try? JSONEncoder().encode(meta) { task.taskDescription = String(data: data, encoding: .utf8) }
        task.resume()
    }

    /// Number of still-running background downloads (for in-app progress).
    func remainingCount() async -> Int {
        await withCheckedContinuation { cont in
            session.getTasksWithCompletionHandler { _, _, downloads in
                cont.resume(returning: downloads.filter { $0.state == .running || $0.state == .suspended }.count)
            }
        }
    }

    // MARK: - Pending results (UserDefaults; filed onto the drive on next foreground)

    static func loadPending() -> [[String: Any]] {
        (UserDefaults.standard.array(forKey: pendingKey) as? [[String: Any]]) ?? []
    }
    /// Drops the first `n` (oldest) entries — the ones a processing pass just handled — while
    /// preserving any the background delegate appended in the meantime.
    func removeProcessed(_ n: Int) {
        guard n > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        var arr = (UserDefaults.standard.array(forKey: Self.pendingKey) as? [[String: Any]]) ?? []
        arr.removeFirst(min(n, arr.count))
        if arr.isEmpty { UserDefaults.standard.removeObject(forKey: Self.pendingKey) }
        else { UserDefaults.standard.set(arr, forKey: Self.pendingKey) }
    }

    /// Puts entries that couldn't be filed yet (drive busy) back on the queue for a later pass.
    func requeue(_ entries: [[String: Any]]) {
        guard !entries.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        var arr = (UserDefaults.standard.array(forKey: Self.pendingKey) as? [[String: Any]]) ?? []
        arr.append(contentsOf: entries)
        UserDefaults.standard.set(arr, forKey: Self.pendingKey)
    }

    private func appendPending(inbox: String, meta: Meta) {
        lock.lock(); defer { lock.unlock() }
        var arr = (UserDefaults.standard.array(forKey: Self.pendingKey) as? [[String: Any]]) ?? []
        arr.append(["inbox": inbox, "dest": meta.dest, "createTime": meta.createTime,
                    "caption": meta.caption, "folder": meta.folder, "id": meta.id])
        UserDefaults.standard.set(arr, forKey: Self.pendingKey)
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let desc = downloadTask.taskDescription, let data = desc.data(using: .utf8),
              let meta = try? JSONDecoder().decode(Meta.self, from: data) else { return }
        // The temp file is removed as soon as this returns — move it into the inbox synchronously.
        let inboxURL = Self.inbox.appendingPathComponent(UUID().uuidString + ".mp4")
        do { try FileManager.default.moveItem(at: location, to: inboxURL) }
        catch { try? FileManager.default.copyItem(at: location, to: inboxURL) }
        guard FileManager.default.fileExists(atPath: inboxURL.path) else { return }
        appendPending(inbox: inboxURL.path, meta: meta)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Failures are dropped silently — re-running "Get New TikTok Videos" re-fetches missing ids.
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let handler = backgroundCompletion
        backgroundCompletion = nil
        DispatchQueue.main.async { handler?() }
    }
}
