import Foundation

/// Downloads files with a **background** `URLSession`, so transfers keep going when the app is
/// suspended or fully closed — the system continues them and relaunches the app to deliver the
/// results. Used by the TikTok downloader.
///
/// **Two lanes.** A background session runs out of process, scheduled by the system — reliable,
/// but slow: a handful of transfers at a time, each throttled. So while the app is on screen,
/// downloads go through a plain in-process session (`fast`) with more connections per host and
/// no system pacing; the moment the app leaves the foreground every fast download is stopped with
/// its resume data and handed to the background session, which carries on from that byte. Either
/// way a finished file lands in the same inbox and is filed the same way, so nothing else changes.
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
    /// Posted (on main) when a download has landed in the inbox, so the app files it at once.
    static let landed = Notification.Name("photoBrowser.tiktokDownloadLanded")

    /// Set by the app delegate when iOS relaunches us to finish background events; called once
    /// the session has delivered them all.
    var backgroundCompletion: (() -> Void)?

    private let lock = NSLock()
    private var session: URLSession!
    private var fast: URLSession!
    private var inForeground = true                       // the fast lane is open; see `setForeground`

    override init() {
        super.init()
        // Recreating the session with the same identifier on launch reconnects to in-flight /
        // completed tasks from a prior run, so their completions are delivered here.
        let cfg = URLSessionConfiguration.background(withIdentifier: Self.sessionID)
        cfg.sessionSendsLaunchEvents = true
        cfg.isDiscretionary = false                       // run promptly, don't wait for "ideal" conditions
        cfg.allowsCellularAccess = true
        cfg.httpMaximumConnectionsPerHost = 8             // more videos in flight at once (faster overall)
        cfg.timeoutIntervalForResource = 7 * 24 * 3600    // let a big/queued transfer finish across app suspensions
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        // The foreground lane: in-process, nothing between us and the CDN.
        let quick = URLSessionConfiguration.default
        quick.httpMaximumConnectionsPerHost = 10
        quick.allowsCellularAccess = true
        quick.timeoutIntervalForRequest = 120
        quick.timeoutIntervalForResource = 6 * 3600
        fast = URLSession(configuration: quick, delegate: self, delegateQueue: nil)
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
    struct Meta: Codable, Sendable {
        let dest: String; let createTime: Double; let caption: String; let folder: String; let id: String; var likes: Int
        init(dest: String, createTime: Double, caption: String, folder: String, id: String, likes: Int = 0) {
            self.dest = dest; self.createTime = createTime; self.caption = caption; self.folder = folder; self.id = id; self.likes = likes
        }
        // Tolerate `likes` being absent — a download enqueued by an older build won't carry it.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            dest = try c.decode(String.self, forKey: .dest)
            createTime = try c.decode(Double.self, forKey: .createTime)
            caption = try c.decode(String.self, forKey: .caption)
            folder = try c.decode(String.self, forKey: .folder)
            id = try c.decode(String.self, forKey: .id)
            likes = (try? c.decode(Int.self, forKey: .likes)) ?? 0
        }
    }

    /// Touching `shared` already recreates the session (see `init`); this just makes that intent
    /// explicit at the call site (app launch / background relaunch).
    func activate() {}

    func enqueue(url: URL, meta: Meta) {
        var req = URLRequest(url: url)
        req.setValue(TikTokService.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("\(TikTokService.apiBase)/", forHTTPHeaderField: "Referer")
        req.timeoutInterval = 600
        lock.lock(); let lane = inForeground ? fast! : session!; lock.unlock()
        let task = lane.downloadTask(with: req)
        if let data = try? JSONEncoder().encode(meta) { task.taskDescription = String(data: data, encoding: .utf8) }
        task.resume()
    }

    /// Open or close the fast lane as the app comes to the front or leaves it. Leaving: every fast
    /// download in flight is stopped with its resume data and re-queued on the background session,
    /// which picks up from the same byte (TikTok's CDN serves ranges) — so "it keeps going when you
    /// close the app" stays true. Called from the app's scene-phase handler.
    func setForeground(_ active: Bool) {
        lock.lock(); inForeground = active; lock.unlock()
        guard !active else { return }
        fast.getTasksWithCompletionHandler { [self] _, _, downloads in
            for task in downloads where task.state == .running || task.state == .suspended {
                let desc = task.taskDescription
                let request = task.originalRequest
                task.cancel { [self] resumeData in
                    let handoff: URLSessionDownloadTask?
                    if let resumeData { handoff = session.downloadTask(withResumeData: resumeData) }
                    else if let request { handoff = session.downloadTask(with: request) }
                    else { handoff = nil }
                    guard let handoff else { return }
                    handoff.taskDescription = desc
                    handoff.resume()
                }
            }
        }
    }

    /// Number of still-running downloads on both lanes (for in-app progress).
    func remainingCount() async -> Int {
        var total = 0
        for lane in [fast!, session!] {
            total += await withCheckedContinuation { cont in
                lane.getTasksWithCompletionHandler { _, _, downloads in
                    cont.resume(returning: downloads.filter { $0.state == .running || $0.state == .suspended }.count)
                }
            }
        }
        return total
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
                    "caption": meta.caption, "folder": meta.folder, "id": meta.id, "likes": meta.likes])
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
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.landed, object: nil) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // A fast-lane download that failed for a network reason gets one more go on the background
        // session (which also retries on its own); a cancellation is the hand-off above, already
        // re-queued. Anything else is dropped — re-running "Get New TikTok Videos" re-fetches missing ids.
        guard session === fast, let error, (error as NSError).code != NSURLErrorCancelled,
              let request = task.originalRequest else { return }
        let retry = self.session.downloadTask(with: request)
        retry.taskDescription = task.taskDescription
        retry.resume()
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let handler = backgroundCompletion
        backgroundCompletion = nil
        DispatchQueue.main.async { handler?() }
    }
}
