import Foundation
import UIKit

/// Google Drive download (photos/videos), matching the app's other public-link importers (MEGA etc.):
/// pure `URLSession` + Apple frameworks, no SDK, no upload. Auth is a user-supplied **OAuth access token**
/// (for private Drive — browse + download) and/or an **API key** (for items shared "anyone with the link").
/// Downloads are streamed to disk, run off-main, and are best-effort (failures are non-fatal).
///
/// Config lives in `UserDefaults` under `photoBrowser.gdrive*`, set in Settings.
enum GoogleDrive {
    static let apiBase = "https://www.googleapis.com/drive/v3"

    private static let tokenKey = "photoBrowser.gdriveToken"
    private static let keyKey = "photoBrowser.gdriveKey"

    nonisolated static var accessToken: String { UserDefaults.standard.string(forKey: tokenKey) ?? "" }
    nonisolated static var apiKey: String { UserDefaults.standard.string(forKey: keyKey) ?? "" }
    nonisolated static var isConfigured: Bool { !accessToken.isEmpty || !apiKey.isEmpty }

    nonisolated static func save(accessToken: String, apiKey: String) {
        let d = UserDefaults.standard
        d.set(accessToken.trimmingCharacters(in: .whitespacesAndNewlines), forKey: tokenKey)
        d.set(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), forKey: keyKey)
    }

    // MARK: Model

    struct Item: Identifiable, Sendable, Equatable {
        let id: String
        let name: String
        let mimeType: String
        let size: Int64
        let modified: Date?
        var isFolder: Bool { mimeType == "application/vnd.google-apps.folder" }
        /// Google-native docs (Docs/Sheets/…) have no raw bytes to download via alt=media — skip them.
        var isGoogleDoc: Bool { mimeType.hasPrefix("application/vnd.google-apps.") && !isFolder }
        var isMedia: Bool { mimeType.hasPrefix("image/") || mimeType.hasPrefix("video/") }
    }

    struct Progress: Sendable { var fraction: Double; var done: Int; var total: Int; var currentName: String }
    struct Result: Sendable { var downloaded: Int; var failed: Int; var folderName: String?; var note: String? }

    enum DriveError: Error { case notConfigured, badLink, auth, network, server(String) }

    // MARK: Requests

    private nonisolated static func request(_ url: URL) -> URLRequest {
        var req = URLRequest(url: url)
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("PhotoBrowser/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
        if !accessToken.isEmpty { req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization") }
        return req
    }

    /// Appends the API key when no OAuth token is set (public-link mode).
    private nonisolated static func authedURL(_ base: String, _ query: [String: String]) -> URL? {
        var comps = URLComponents(string: base)
        var items = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        if accessToken.isEmpty, !apiKey.isEmpty { items.append(URLQueryItem(name: "key", value: apiKey)) }
        comps?.queryItems = items
        return comps?.url
    }

    // MARK: Listing

    /// One level of a folder's children (handles pagination). Sorted folders-first, then name.
    nonisolated static func list(folderID: String) async -> [Item] {
        var out: [Item] = []
        var pageToken: String? = nil
        repeat {
            var q: [String: String] = [
                "q": "'\(folderID)' in parents and trashed = false",
                "fields": "nextPageToken,files(id,name,mimeType,size,modifiedTime)",
                "pageSize": "1000",
                "supportsAllDrives": "true",
                "includeItemsFromAllDrives": "true",
            ]
            if let pageToken { q["pageToken"] = pageToken }
            guard let url = authedURL("\(apiBase)/files", q),
                  let (data, resp) = try? await URLSession.shared.data(for: request(url)),
                  (resp as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) == true,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { break }
            for f in (json["files"] as? [[String: Any]]) ?? [] { if let item = item(from: f) { out.append(item) } }
            pageToken = json["nextPageToken"] as? String
        } while pageToken != nil
        return out.sorted { a, b in
            a.isFolder != b.isFolder ? a.isFolder : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// Metadata for a single file (used when the user pastes a file link).
    nonisolated static func fileInfo(id: String) async -> Item? {
        let q = ["fields": "id,name,mimeType,size,modifiedTime", "supportsAllDrives": "true"]
        guard let url = authedURL("\(apiBase)/files/\(id)", q),
              let (data, resp) = try? await URLSession.shared.data(for: request(url)),
              (resp as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) == true,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return item(from: json)
    }

    private nonisolated static func item(from f: [String: Any]) -> Item? {
        guard let id = f["id"] as? String, let name = f["name"] as? String,
              let mime = f["mimeType"] as? String else { return nil }
        let size = Int64((f["size"] as? String).flatMap { Int($0) } ?? 0)
        let modified = (f["modifiedTime"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        return Item(id: id, name: name, mimeType: mime, size: size, modified: modified)
    }

    /// Extracts a Drive file/folder ID from a shared link (or returns the string if it already looks like an ID).
    nonisolated static func extractID(from link: String) -> String? {
        let s = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        for pattern in ["/folders/([A-Za-z0-9_-]+)", "/file/d/([A-Za-z0-9_-]+)", "[?&]id=([A-Za-z0-9_-]+)"] {
            if let r = try? NSRegularExpression(pattern: pattern),
               let m = r.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
               let range = Range(m.range(at: 1), in: s) { return String(s[range]) }
        }
        // Bare ID (no URL).
        if !s.contains("/"), s.range(of: "^[A-Za-z0-9_-]{10,}$", options: .regularExpression) != nil { return s }
        return nil
    }

    // MARK: Download

    /// Streams one file's bytes to `dest`, carrying Drive's modified date onto the file. Returns success.
    nonisolated static func download(fileID: String, to dest: URL, modified: Date?) async -> Bool {
        let q = ["alt": "media", "supportsAllDrives": "true"]
        guard let url = authedURL("\(apiBase)/files/\(fileID)", q) else { return false }
        guard let (tmp, resp) = try? await URLSession.shared.download(for: request(url)),
              (resp as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) == true else { return false }
        let fm = FileManager.default
        try? fm.removeItem(at: dest)
        guard (try? fm.moveItem(at: tmp, to: dest)) != nil else { try? fm.removeItem(at: tmp); return false }
        if let modified { try? fm.setAttributes([.modificationDate: modified], ofItemAtPath: dest.path) }
        return true
    }

    /// A flat download plan (fileID → local destination), building the subfolder tree under `into`.
    /// Recurses concurrently; only real media/binary files are included (Google-native docs skipped).
    nonisolated static func buildPlan(folderID: String, named name: String, into parent: URL) async -> [(item: Item, dest: URL)] {
        let fm = FileManager.default
        let root = uniqueChild(named: name, in: parent)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        var result: [(item: Item, dest: URL)] = []
        let children = await list(folderID: folderID)
        // Recurse into subfolders concurrently, collect files.
        await withTaskGroup(of: [(item: Item, dest: URL)].self) { group in
            for child in children where child.isFolder {
                group.addTask { await buildPlan(folderID: child.id, named: child.name, into: root) }
            }
            for await sub in group { result.append(contentsOf: sub) }
        }
        for child in children where !child.isFolder && !child.isGoogleDoc {
            result.append((item: child, dest: uniqueChild(named: child.name, in: root)))
        }
        return result
    }

    /// Downloads a whole plan with bounded concurrency, reporting progress. Returns (downloaded, failed).
    nonisolated static func run(plan: [(item: Item, dest: URL)],
                                progress: @escaping @Sendable (Progress) -> Void) async -> (Int, Int) {
        let total = plan.count
        guard total > 0 else { return (0, 0) }
        var done = 0, ok = 0
        await withTaskGroup(of: Bool.self) { group in
            var idx = 0
            let maxConcurrent = 6                     // fast, but polite to the API
            func addNext() {
                guard idx < plan.count else { return }
                let job = plan[idx]; idx += 1
                progress(Progress(fraction: total > 0 ? Double(done) / Double(total) : 0,
                                  done: done, total: total, currentName: job.item.name))
                group.addTask { await download(fileID: job.item.id, to: job.dest, modified: job.item.modified) }
            }
            for _ in 0..<min(maxConcurrent, plan.count) { addNext() }
            while let success = await group.next() {
                done += 1; if success { ok += 1 }
                progress(Progress(fraction: Double(done) / Double(total), done: done, total: total, currentName: ""))
                addNext()
            }
        }
        return (ok, total - ok)
    }

    /// Top-level: resolve a pasted link (folder → whole tree, file → single item) and download into `dest`.
    nonisolated static func importLink(_ link: String, into dest: URL,
                                       progress: @escaping @Sendable (Progress) -> Void) async -> Result {
        guard isConfigured else { return Result(downloaded: 0, failed: 0, folderName: nil, note: "Add a Google Drive access token or API key in Settings.") }
        guard let id = extractID(from: link) else { return Result(downloaded: 0, failed: 0, folderName: nil, note: "Couldn't read a Drive folder/file ID from that link.") }
        // Decide folder vs file by fetching metadata.
        guard let info = await fileInfo(id: id) else {
            return Result(downloaded: 0, failed: 0, folderName: nil,
                          note: "Couldn't access that item. Check the link is shared and your token/key is valid.")
        }
        return await importItems([info], into: dest, progress: progress)
    }

    /// Downloads the given items (files and/or folders) into `dest`.
    nonisolated static func importItems(_ items: [Item], into dest: URL,
                                        progress: @escaping @Sendable (Progress) -> Void) async -> Result {
        var jobs: [(item: Item, dest: URL)] = []
        for item in items {
            if item.isFolder {
                jobs.append(contentsOf: await buildPlan(folderID: item.id, named: item.name, into: dest))
            } else if !item.isGoogleDoc {
                jobs.append((item: item, dest: uniqueChild(named: item.name, in: dest)))
            }
        }
        let firstFolder = items.first(where: { $0.isFolder })?.name
        let (ok, failed) = await run(plan: jobs, progress: progress)
        let note = (ok == 0 && failed == 0) ? "No downloadable photos or videos found." : nil
        return Result(downloaded: ok, failed: failed, folderName: firstFolder, note: note)
    }

    // MARK: - Cookie-session download (from the built-in browser login)

    /// Downloads the given Drive file IDs using the signed-in **web session cookies** captured from the
    /// in-app browser — no API key/token needed. Each file is fetched from Drive's `uc?export=download`
    /// endpoint; the saved name comes from the response's Content-Disposition. Best-effort and concurrent:
    /// folders / Google-native docs / oversized (virus-scan-gated) files are skipped rather than failing.
    nonisolated static func downloadViaCookies(fileIDs: [String], cookieHeader: String, into folder: URL,
                                               progress: @escaping @Sendable (Progress) -> Void) async -> Result {
        let ids = Array(Set(fileIDs)).filter { !$0.isEmpty }
        let total = ids.count
        guard total > 0 else {
            return Result(downloaded: 0, failed: 0, folderName: nil,
                          note: "No items found on this page. Open a folder (or select items) first, and scroll so they load.")
        }
        var done = 0, ok = 0
        var firstReason: String?
        await withTaskGroup(of: (Bool, String?).self) { group in
            var idx = 0
            let maxConcurrent = 5
            func addNext() {
                guard idx < ids.count else { return }
                let id = ids[idx]; idx += 1
                progress(Progress(fraction: Double(done) / Double(total), done: done, total: total, currentName: ""))
                group.addTask { await downloadOneViaCookie(id: id, cookieHeader: cookieHeader, into: folder) }
            }
            for _ in 0..<min(maxConcurrent, ids.count) { addNext() }
            while let (success, reason) = await group.next() {
                done += 1; if success { ok += 1 }
                if !success, firstReason == nil, let reason { firstReason = reason }
                progress(Progress(fraction: Double(done) / Double(total), done: done, total: total, currentName: ""))
                addNext()
            }
        }
        // Name the actual cause — the failure modes (folders/Docs selected, expired
        // sign-in, Google changing the download flow) each need a different user action.
        let note = ok == 0
            ? "Nothing downloaded — " + (firstReason ?? "the items may be folders or Google Docs; open the folder, select items, and try again") + "."
            : nil
        return Result(downloaded: ok, failed: total - ok, folderName: folder.lastPathComponent, note: note)
    }

    /// (success, failure reason) — the reason is surfaced to the user, so keep it actionable.
    private nonisolated static func downloadOneViaCookie(id: String, cookieHeader: String, into folder: URL) async -> (Bool, String?) {
        // Downloads *stage on the phone* (URLSession writes to app temp storage) before
        // moving onto the drive — a nearly-full iPhone fails every download no matter
        // how much room the SSD has, so say that instead of a misleading auth error.
        if let free = freeDeviceSpace(), free < 250 * 1024 * 1024 {
            return (false, "your iPhone is nearly out of storage (\(free.sizeString) free) — downloads stage on the phone before moving to the drive, so free up space and try again")
        }
        // Step 1: the standard download URL. Small files return their bytes directly; **large** files
        // (>~100 MB, which can't be virus-scanned) return an HTML confirm page instead.
        guard let url = URL(string: "https://drive.google.com/uc?export=download&id=\(id)") else { return (false, nil) }
        let tmp: URL, http: HTTPURLResponse
        switch await fetch(url, cookieHeader) {
        case .failure(let why): return (false, why)
        case .file(let t, let h): tmp = t; http = h
        }
        if !isHTML(http) {
            let saved = save(tmp, http: http, id: id, into: folder)
            return (saved, saved ? nil : "the file downloaded but couldn’t be saved onto the drive")
        }
        // Step 2: it answered with HTML — the large-file confirm page, or a sign-in/consent page.
        let html = (try? String(contentsOf: tmp, encoding: .utf8)) ?? ""
        try? FileManager.default.removeItem(at: tmp)
        if looksLikeSignIn(html) {
            return (false, "Google answered with a sign-in page — reopen “Browse Google Drive…” and log in again")
        }
        // A real confirm page carries the download form; anything else (Google changed the
        // page) → try the modern usercontent endpoint directly before giving up.
        let hasConfirmForm = html.contains("usercontent.google.com/download")
            || html.contains("name=\"uuid\"") || html.contains("confirm=")
        let confirmURL = hasConfirmForm
            ? parseConfirmForm(html, fallbackID: id)
            : URL(string: "https://drive.usercontent.google.com/download?id=\(id)&export=download&confirm=t")
        guard let confirmURL else {
            return (false, "the download confirmation step was refused (Google may have changed the flow, or the item isn’t downloadable)")
        }
        let tmp2: URL, http2: HTTPURLResponse
        switch await fetch(confirmURL, cookieHeader) {
        case .failure(let why): return (false, why)
        case .file(let t, let h): tmp2 = t; http2 = h
        }
        if isHTML(http2) {   // still blocked (e.g. quota, or the flow changed again)
            let html2 = (try? String(contentsOf: tmp2, encoding: .utf8)) ?? ""
            try? FileManager.default.removeItem(at: tmp2)
            return (false, looksLikeSignIn(html2)
                ? "Google answered with a sign-in page — reopen “Browse Google Drive…” and log in again"
                : "Drive kept answering with a web page instead of the file (quota-limited, or the download flow changed)")
        }
        let saved = save(tmp2, http: http2, id: id, into: folder)
        return (saved, saved ? nil : "the file downloaded but couldn’t be saved onto the drive")
    }

    /// Heuristic for Google's sign-in/consent interstitials.
    private nonisolated static func looksLikeSignIn(_ html: String) -> Bool {
        html.contains("accounts.google.com") || html.contains("ServiceLogin") || html.contains("signin/identifier")
    }

    private enum Fetch { case file(URL, HTTPURLResponse), failure(String) }

    private nonisolated static func fetch(_ url: URL, _ cookieHeader: String) async -> Fetch {
        var req = URLRequest(url: url); req.timeoutInterval = 300     // room for big files
        req.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
                     forHTTPHeaderField: "User-Agent")
        do {
            let (tmp, resp) = try await URLSession.shared.download(for: req)
            guard let http = resp as? HTTPURLResponse else { return .failure("unexpected response") }
            guard (200...299).contains(http.statusCode) else {
                return .failure("Drive answered HTTP \(http.statusCode)"
                                + (http.statusCode == 401 || http.statusCode == 403
                                   ? " — reopen “Browse Google Drive…” and log in again" : ""))
            }
            return .file(tmp, http)
        } catch {
            // A full *phone* kills the staging write — name it, or it masquerades as auth.
            let urlCode = (error as? URLError)?.code
            if urlCode == .cannotWriteToFile || urlCode == .cannotCreateFile
                || (error as? CocoaError)?.code == .fileWriteOutOfSpace {
                return .failure("your iPhone ran out of storage while staging the download — free up space and try again")
            }
            return .failure(error.localizedDescription)
        }
    }

    /// Free space on the phone (where downloads stage before moving to the drive).
    private nonisolated static func freeDeviceSpace() -> Int64? {
        let values = try? FileManager.default.temporaryDirectory
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    private nonisolated static func isHTML(_ http: HTTPURLResponse) -> Bool {
        (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased().contains("text/html")
    }

    private nonisolated static func save(_ tmp: URL, http: HTTPURLResponse, id: String, into folder: URL) -> Bool {
        let fm = FileManager.default
        let dest = uniqueChild(named: filename(from: http) ?? "drive-\(id)", in: folder)
        guard (try? fm.moveItem(at: tmp, to: dest)) != nil else { try? fm.removeItem(at: tmp); return false }
        return true
    }

    /// Rebuilds the real download URL from Drive's large-file confirm page (a `<form>` with hidden inputs
    /// including a `confirm` token and a `uuid`).
    private nonisolated static func parseConfirmForm(_ html: String, fallbackID id: String) -> URL? {
        let action = (firstMatch("<form[^>]*action=\"([^\"]+)\"", html) ?? "https://drive.usercontent.google.com/download")
            .replacingOccurrences(of: "&amp;", with: "&")
        var params: [String: String] = ["id": id, "export": "download", "confirm": "t"]
        // Hidden inputs (name/value in either attribute order).
        for (pattern, nameFirst) in [("<input[^>]*name=\"([^\"]+)\"[^>]*value=\"([^\"]*)\"", true),
                                     ("<input[^>]*value=\"([^\"]*)\"[^>]*name=\"([^\"]+)\"", false)] {
            guard let r = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let ns = html as NSString
            for m in r.matches(in: html, range: NSRange(location: 0, length: ns.length)) where m.numberOfRanges >= 3 {
                let a = ns.substring(with: m.range(at: 1)), b = ns.substring(with: m.range(at: 2))
                params[nameFirst ? a : b] = nameFirst ? b : a
            }
        }
        var comps = URLComponents(string: action)
        comps?.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        return comps?.url
    }

    private nonisolated static func firstMatch(_ pattern: String, _ s: String) -> String? {
        guard let r = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = s as NSString
        guard let m = r.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 1, m.range(at: 1).location != NSNotFound else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    /// The download's filename from a `Content-Disposition` header (`filename*=UTF-8''…` preferred).
    private nonisolated static func filename(from http: HTTPURLResponse) -> String? {
        guard let cd = http.value(forHTTPHeaderField: "Content-Disposition") else { return nil }
        if let r = cd.range(of: "filename\\*=UTF-8''[^;\\r\\n]+", options: .regularExpression) {
            return String(cd[r]).replacingOccurrences(of: "filename*=UTF-8''", with: "").removingPercentEncoding
        }
        if let r = cd.range(of: "filename=\"[^\"]+\"", options: .regularExpression) {
            return String(cd[r]).replacingOccurrences(of: "filename=", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return nil
    }

    private nonisolated static func uniqueChild(named name: String, in folder: URL) -> URL {
        let safe = name.replacingOccurrences(of: "/", with: "-")
        let fm = FileManager.default
        var dest = folder.appendingPathComponent(safe)
        guard fm.fileExists(atPath: dest.path) else { return dest }
        let base = (safe as NSString).deletingPathExtension, ext = (safe as NSString).pathExtension
        var n = 1
        repeat {
            let nm = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            dest = folder.appendingPathComponent(nm); n += 1
        } while fm.fileExists(atPath: dest.path)
        return dest
    }
}
