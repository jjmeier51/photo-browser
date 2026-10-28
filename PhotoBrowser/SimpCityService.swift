import UIKit
import WebKit
import Observation

/// "Download from SimpCity…" on a person's folder: reads a simpcity.cr thread page by page, resolves
/// every goonbox.cr image to its full-size file and every turbo.cr video to its file, and saves them into
/// `<person>/simpcity`, tagged "simpcity" — photos and videos keep their own capture date, and get the
/// forum post's date when they have none. What's been downloaded is the shared record
/// (`SimpCityRecord.swift`), also read and written by Safe Finder on the Mac (`mac/simpcity.py`), so
/// neither ever fetches what the other already has.
///
/// **Why a browser.** Both sites check that a real browser is asking (DDoS-Guard on simpcity.cr,
/// Cloudflare on goonbox.cr), their file servers turn away anything that isn't a browser engine (like
/// bunkr's — see `BunkrWebDownloader`), and SimpCity shows links only to members. So everything goes
/// through WebKit with the app's persistent cookie store: the thread is read in a web view the person
/// can see (the SimpCity screen shows it — they log in there once, and answer a "you're human?" check
/// if one appears), the files are found by reading each goonbox/turbo page, and fetched with
/// `WKDownload`. Four lanes work at once, each with its own web view.
///
/// **Leaving the screen.** The run carries on with the web views parked behind the app (like
/// `TikTokWebFetcher`). If a site then asks for a person, the run stops with the record saved and says
/// so; "Get New" on the screen picks up where it stopped. WebKit pauses when the app is in the
/// background, so a long run needs the app open (the screen stays awake while it runs).
///
/// The page scripts are kept identical to `mac/simpcity.py`'s (`EXTRACT_POSTS_JS`, `RESOLVE_JS`).
@Observable @MainActor
final class SimpCityDownloader {
    static let shared = SimpCityDownloader()

    private(set) var running = false
    private(set) var status = ""
    private(set) var saved = 0
    private(set) var failed = 0
    private(set) var total = 0
    /// Files handled so far this run (downloaded, failed, or an earlier one brought up to date).
    private(set) var done = 0
    /// The person folder of the run in progress.
    private(set) var person: URL?
    /// Whether the SimpCity screen is showing (a check or the login can be answered right there).
    var showing = false

    /// The page the screen shows: the thread being read, the login, a check waiting for the person.
    @ObservationIgnored let main = SimpCityPage()
    /// The download lanes — their own pages, so a check shown on `main` never swaps a page under one.
    @ObservationIgnored private let lanes = [SimpCityPage(), SimpCityPage(), SimpCityPage(), SimpCityPage()]
    @ObservationIgnored private var record: SimpCity.Record?
    @ObservationIgnored private var queue: [SimpCity.Item] = []
    @ObservationIgnored private var lastPage: [String: Any] = [:]
    @ObservationIgnored private var untagged: [URL] = []
    /// Tagged "upscaled" too, like the app's own upscales.
    @ObservationIgnored private var upscaledFiles: [URL] = []
    @ObservationIgnored private var fixedDates = 0
    @ObservationIgnored private var converted = 0
    @ObservationIgnored private var enlarged = 0
    @ObservationIgnored private var failHosts: [String: Int] = [:]
    @ObservationIgnored private var failWhy: [String: String] = [:]
    @ObservationIgnored private var written: [URL] = []
    @ObservationIgnored private var activity: UUID?
    @ObservationIgnored private var stopRequested = false
    @ObservationIgnored private var stopNote: String?
    @ObservationIgnored private var kept = 0
    @ObservationIgnored private var postDated = 0
    @ObservationIgnored private weak var library: Library?

    static let loginURL = URL(string: "https://simpcity.cr/login/")!

    /// The thread the person folder's record last read (for "Get New"), if any.
    nonisolated static func lastThread(in person: URL) -> String? {
        let folder = person.appendingPathComponent(SimpCity.folderName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent(SimpCity.recordName).path) else { return nil }
        return SimpCity.Record(folder: folder).lastThread
    }

    func stop() {
        guard running else { return }
        stopRequested = true
        status = "Stopping after the files in hand…"
    }

    func start(person: URL, thread raw: String, full: Bool, library: Library) {
        guard !running, let base = SimpCity.threadBase(raw) else { return }
        running = true
        stopRequested = false; stopNote = nil
        saved = 0; failed = 0; total = 0; done = 0; kept = 0; postDated = 0
        fixedDates = 0; converted = 0; enlarged = 0; failHosts = [:]; failWhy = [:]
        queue = []; untagged = []; written = []; upscaledFiles = []
        self.person = person
        self.library = library
        let id = library.beginActivity("SimpCity — \(person.lastPathComponent)", indeterminate: true, cancellable: true)
        activity = id
        let bg = BackgroundTaskHolder(); bg.begin(name: "SimpCity Download")
        UIApplication.shared.isIdleTimerDisabled = true
        Task {
            let note = await run(person: person, base: base, full: full)
            await saveAndTag()
            let dest = person.appendingPathComponent(SimpCity.folderName, isDirectory: true)
            if !written.isEmpty { library.contentDidChange(under: dest) }
            let msg = summary(note)
            status = msg
            library.endActivity(id, result: msg)
            running = false
            activity = nil
            UIApplication.shared.isIdleTimerDisabled = false
            bg.end()
        }
    }

    private func say(_ s: String) {
        status = s
        if let activity, let library {
            library.setActivity(activity, status: s, fraction: total > 0 ? Double(done) / Double(total) : nil)
        }
    }

    private var shouldStop: Bool {
        if stopRequested || stopNote != nil { return true }
        if let activity, let library, library.isActivityCancelled(activity) { stopRequested = true }
        return stopRequested
    }

    private func summary(_ note: String?) -> String {
        let n = written.count
        var s: String
        if let note, n == 0 { return note }
        if n == 0 && failed == 0 { s = "Nothing new in the thread." }
        else {
            s = "Saved \(n) file\(n == 1 ? "" : "s") into “\(person?.lastPathComponent ?? "")/\(SimpCity.folderName)”"
            if failed > 0 {
                s += "; \(failed) failed (tried again next time)"
                let worst = failHosts.sorted { $0.value > $1.value }.prefix(3)
                if !worst.isEmpty {
                    s += " — " + worst.map { "\($0.key) ×\($0.value) (\(failWhy[$0.key] ?? ""))" }.joined(separator: ", ")
                }
            }
            s += "."
            if n > 0 { s += " \(kept) kept their own date; \(postDated) got the post’s date." }
        }
        if fixedDates + converted + enlarged > 0 {
            s += " Earlier downloads: \(fixedDates) got their post’s real date, \(converted) WebP → JPEG, \(enlarged) small photos upscaled 2×."
        }
        if let note { s += " " + note }
        return s
    }

    // MARK: - The run

    /// Reads the thread, then downloads what's left. Returns a note when it stopped short.
    private func run(person: URL, base: String, full: Bool) async -> String? {
        let dest = person.appendingPathComponent(SimpCity.folderName, isDirectory: true)
        let loaded: SimpCity.Record? = await Task.detached(priority: .userInitiated) {
            guard (try? DriveWriter.createDirectory(at: dest)) != nil
                    || FileManager.default.fileExists(atPath: dest.path) else { return nil }
            return SimpCity.Record(folder: dest)
        }.value
        guard var rec = loaded else { return "Couldn’t make the “\(SimpCity.folderName)” folder." }

        // 1. Every page (from the last one read before, unless asked for all of them).
        let first = full ? 1 : rec.startPage(base)
        var n = first, last = first, title = ""
        var items: [String: SimpCity.Item] = [:]
        var askedLogin = false
        while n <= last, !shouldStop {
            say("Reading page \(n)\(last > n ? " of \(last)" : "")… \(items.count) files found so far.")
            guard let page = await readPage(SimpCity.pageURL(base, n), n: n) else {
                return main.challenged
                    ? "SimpCity is checking that a person is asking. Open Download from SimpCity, answer it there, then tap Get New."
                    : "Couldn’t read page \(n) of the thread: \(describe(lastPage)). Check the address and that you’re logged in, then try again."
            }
            let posts = page["posts"] as? [[String: Any]] ?? []
            var found = 0
            for p in posts {
                for case let u as String in (p["urls"] as? [Any] ?? []) where SimpCity.mediaKey(u) != nil { found += 1 }
            }
            if n == first, found == 0, (page["loggedIn"] as? Bool) != true, !askedLogin {
                askedLogin = true
                if await waitForLogin() { continue }
                return "SimpCity shows its links only to members. Open Download from SimpCity, log in there, then tap Download."
            }
            SimpCity.collect(posts: posts, into: &items)
            last = max(last, (page["last"] as? NSNumber)?.intValue ?? 1)
            if title.isEmpty { title = page["title"] as? String ?? "" }
            n += 1
        }
        rec.noteThread(base, title: title, pages: min(last, max(n - 1, 1)))

        // 2. What's left: not in the record, not already in the folder — and the earlier downloads to
        // bring up to the current rules (a real post date, WebP → JPEG, small photos 2×).
        let snapshot = rec, all = items, readAll = first == 1 && !shouldStop
        let (left, adopted, fixes, merged) = await Task.detached(priority: .userInitiated) {
            () -> ([SimpCity.Item], Int, [(item: SimpCity.Item, name: String)], SimpCity.Record) in
            var r = snapshot
            let present = Set((try? FileManager.default.contentsOfDirectory(atPath: dest.path)) ?? [])
            let fixes = r.fixes(all, present: present)
            r.redate(all, readAll: readAll)
            let t = SimpCity.todo(all, record: &r, folder: dest)
            try? r.save()
            return (t.left, t.adopted, fixes, r)
        }.value
        record = merged
        if adopted > 0 { print("[SimpCity] \(adopted) file(s) already in the folder — counted as done") }
        guard !left.isEmpty || !fixes.isEmpty, !shouldStop else { return stopNote }

        // 3. Resolve + download, four at a time, with the earlier downloads fixed alongside.
        queue = left
        total = left.count + fixes.count
        say("Downloading \(left.count) file\(left.count == 1 ? "" : "s")…")
        await withTaskGroup(of: Void.self) { group in
            if !fixes.isEmpty { group.addTask { @MainActor in await self.fixEarlier(fixes, in: dest) } }
            for lane in lanes.prefix(min(lanes.count, left.count)) {
                group.addTask { @MainActor in await self.work(lane, into: dest) }
            }
        }
        return stopNote
    }

    /// Earlier downloads brought up to the current rules, one at a time beside the new downloads.
    private func fixEarlier(_ fixes: [(item: SimpCity.Item, name: String)], in dest: URL) async {
        for (item, name) in fixes {
            if shouldStop { break }
            let src = dest.appendingPathComponent(name)
            let posted = item.posted
            if let r = await Task.detached(priority: .utility, operation: { await Self.fixFile(src, posted: posted) }).value {
                if r.url != src {
                    library?.itemMoved(from: src, to: r.url)     // labels and tags go with the new name
                    converted += 1
                }
                if r.upscaled { enlarged += 1; upscaledFiles.append(r.url) }
                if r.dated { fixedDates += 1 }
                record?.add(item, file: r.url.lastPathComponent, upscaled: r.upscaled)
            }
            done += 1
            say("Bringing earlier downloads up to date — \(fixedDates + converted + enlarged) changed.")
        }
    }

    /// One file downloaded before the current rules, brought up to them where it lies: a copy in the
    /// app's temp folder is prepared (WebP → JPEG, the small-photo upscale, the post's date when it has
    /// no real one of its own — the 1969 a misread time wrote doesn't count) and committed back over it,
    /// its tag attribute kept, or beside it under the new name (the caller re-keys its labels; the old
    /// file goes). Returns where it is now and what changed; nil when it couldn't be done.
    nonisolated private static func fixFile(_ src: URL, posted: Double) async -> (url: URL, dated: Bool, upscaled: Bool)? {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("simpcity-fix-" + UUID().uuidString)
            .appendingPathExtension(src.pathExtension)
        guard (try? fm.copyItem(at: src, to: temp)) != nil else { return nil }
        let prepared = SimpCity.prepareImage(temp)
        let settled = await SimpCity.settleDate(prepared.url, posted: posted)
        let dated = settled.date != nil && !settled.own
        guard prepared.url != temp || prepared.upscaled || dated else {
            try? fm.removeItem(at: prepared.url)
            if let d = settled.date { try? fm.setAttributes([.creationDate: d, .modificationDate: d], ofItemAtPath: src.path) }
            return (src, false, false)
        }
        var dest = src
        if prepared.url.pathExtension.lowercased() != src.pathExtension.lowercased() {
            let folder = src.deletingLastPathComponent(), stem = src.deletingPathExtension().lastPathComponent
            let ext = prepared.url.pathExtension
            dest = folder.appendingPathComponent("\(stem).\(ext)")
            var k = 2
            while fm.fileExists(atPath: dest.path) { dest = folder.appendingPathComponent("\(stem) \(k).\(ext)"); k += 1 }
        }
        let carried = dest == src ? SharedTags.carriedAttributes(of: src) : []
        do { try await DriveWriter.shared.commit(prepared.url, to: dest) } catch {
            try? fm.removeItem(at: prepared.url)
            return nil
        }
        if !carried.isEmpty { SharedTags.restoreAttributes(carried, to: dest) }
        if let d = settled.date { try? fm.setAttributes([.creationDate: d, .modificationDate: d], ofItemAtPath: dest.path) }
        if dest != src { try? fm.removeItem(at: src) }
        return (dest, dated, prepared.upscaled)
    }

    /// `/api/images/<id>` asked from a goonbox page — the lane stays on goonbox, so after its first
    /// file each one is a single quick request.
    private func goonboxOriginal(_ item: SimpCity.Item, page: URL, on lane: SimpCityPage) async -> URL? {
        if !lane.isOn("goonbox.cr") {
            lane.load(page)
            let ready = await lane.poll(SimpCityPage.resolveScript(kind: "goonbox"), timeout: 30, patient: false) { r in
                (r["ready"] as? String) == "complete" && ((r["href"] as? String) ?? "").contains("goonbox")
            }
            guard ready != nil else { return nil }      // a check, or no page: the page path deals with it
        }
        let scripts = SimpCityPage.goonboxScripts(id: item.id)
        _ = await lane.string("(\(scripts.start), 'started')")
        let r = await lane.poll(scripts.read, timeout: 25, patient: false, every: 0.08) { $0["status"] != nil }
        guard (r?["status"] as? NSNumber)?.intValue == 200, let s = r?["url"] as? String, !s.isEmpty else { return nil }
        return URL(string: s)
    }

    private func work(_ lane: SimpCityPage, into dest: URL) async {
        while !shouldStop, !queue.isEmpty {
            let item = queue.removeFirst()
            defer { done += 1 }
            guard let fileURL = await resolve(item, on: lane) else {
                failed += 1
                record?.noteFailed(item)
                say(progressLine)
                continue
            }
            let ext = SimpCity.fileExtension(fileURL.absoluteString, kind: item.kind)
            // A plain request first — the image server answers them, and it's quick — then WebKit.
            let referer = item.link
            let direct = await Task.detached(priority: .utility) { await Self.fetch(fileURL, referer: referer, ext: ext) }.value
            var downloaded = direct.file
            if downloaded == nil { downloaded = await lane.download(fileURL, referer: item.link, ext: ext) }
            guard let temp = downloaded else {
                noteFailure(fileURL, why: "\(direct.why); in WebKit too")
                failed += 1
                record?.noteFailed(item)
                say(progressLine)
                continue
            }
            let id = item.id, posted = item.posted
            let outcome = await Task.detached(priority: .utility) { await Self.finish(temp, posted: posted, into: dest, id: id) }.value
            if let (final, ownDate, upscaled) = outcome {
                record?.add(item, file: final.lastPathComponent, upscaled: upscaled)
                written.append(final); untagged.append(final)
                if upscaled { upscaledFiles.append(final) }
                saved += 1
                if ownDate { kept += 1 } else { postDated += 1 }
                if written.count % 20 == 0 { await saveAndTag() }
            } else {
                failed += 1
                record?.noteFailed(item)
            }
            say(progressLine)
        }
    }

    /// A failed download, counted by server for the summary (with the last reason), so a host that
    /// won't serve is visible.
    private func noteFailure(_ url: URL, why: String) {
        let host = url.host ?? "?"
        failHosts[host, default: 0] += 1
        failWhy[host] = why
        if failHosts[host] ?? 0 <= 3 { print("[SimpCity] couldn’t download \(url.absoluteString.prefix(120)) — \(why)") }
    }

    /// Downloads `url` with a plain request into the app's temp folder. nil and why when it's refused
    /// (an HTTP status, a page where a file belongs, no answer).
    nonisolated private static func fetch(_ url: URL, referer: String, ext: String) async -> (file: URL?, why: String) {
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue(referer, forHTTPHeaderField: "Referer")
        req.setValue(fetchAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("image/avif,image/webp,image/*,video/*;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        do {
            let (tmp, resp) = try await fetchSession.download(for: req)
            let fm = FileManager.default
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let mime = resp.mimeType ?? ""
            let size = (try? tmp.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            let why = !(200...299).contains(status) ? "HTTP \(status)"
                : mime.hasPrefix("text/") ? "the server sent a page (\(mime)), not the file"
                : size < 64 ? "an empty file" : ""
            guard why.isEmpty else { try? fm.removeItem(at: tmp); return (nil, why) }
            let out = fm.temporaryDirectory.appendingPathComponent("simpcity-" + UUID().uuidString).appendingPathExtension(ext)
            guard (try? fm.moveItem(at: tmp, to: out)) != nil else { try? fm.removeItem(at: tmp); return (nil, "couldn’t keep it") }
            return (out, "")
        } catch {
            return (nil, error.localizedDescription)
        }
    }

    nonisolated private static let fetchAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
    nonisolated private static let fetchSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20                 // no answer for this long: try WebKit instead
        cfg.timeoutIntervalForResource = 600
        cfg.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: cfg)
    }()

    private var progressLine: String {
        "Downloading — \(saved) saved, \(failed) failed, \(queue.count) waiting."
    }

    /// The downloaded temp file made ready (WebP → JPEG, a small photo upscaled 2×), the date rule,
    /// then into the drive folder as `<id>.<ext>` (never over a file). Returns where it landed, whether
    /// it kept its own capture date, and whether it was upscaled.
    nonisolated private static func finish(_ temp: URL, posted: Double, into folder: URL, id: String) async -> (URL, Bool, Bool)? {
        let prepared = SimpCity.prepareImage(temp)
        let settled = await SimpCity.settleDate(prepared.url, posted: posted)
        let fm = FileManager.default
        let ext = prepared.url.pathExtension.lowercased()
        var dest = folder.appendingPathComponent("\(id).\(ext)")
        var k = 2
        while fm.fileExists(atPath: dest.path) { dest = folder.appendingPathComponent("\(id) \(k).\(ext)"); k += 1 }
        do { try await DriveWriter.shared.commit(prepared.url, to: dest) } catch {
            try? fm.removeItem(at: prepared.url)
            return nil
        }
        if let date = settled.date { try? fm.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: dest.path) }
        return (dest, settled.own, prepared.upscaled)
    }

    /// The record and the new files' tag — every 20 files and at the end.
    private func saveAndTag() async {
        if let snapshot = record {
            _ = await Task.detached(priority: .utility) { var r = snapshot; try? r.save() }.value
        }
        if let library {
            if !untagged.isEmpty { library.addTag(SimpCity.tag, to: untagged); untagged = [] }
            if !upscaledFiles.isEmpty { library.addTag(SimpCity.upscaledTag, to: upscaledFiles); upscaledFiles = [] }
        }
    }

    // MARK: - Reading pages

    /// Page `n` of the thread, once it is that page and its posts are there (until then the view can
    /// still show the page before). SimpCity's tracking scripts can keep a page from ever finishing
    /// loading, so one still loading after a while is read as it stands. nil when it can't be read —
    /// or a check is waiting for a person who isn't looking (`main.challenged`); `lastPage` is what it
    /// showed, for the message.
    private func readPage(_ address: String, n: Int) async -> [String: Any]? {
        guard let url = URL(string: address) else { return nil }
        main.load(url)
        lastPage = [:]
        let started = Date()
        return await main.poll(SimpCityPage.extractScript, timeout: 90, patient: showing) { r in
            lastPage = r
            guard r["error"] == nil, ((r["page"] as? NSNumber)?.intValue ?? 1) == n else { return false }
            let ready = r["ready"] as? String
            return !((r["posts"] as? [Any]) ?? []).isEmpty || ready == "complete"
                || (ready == "interactive" && Date().timeIntervalSince(started) > 12)
        }
    }

    /// What a thread page showed, for the message when it couldn't be read (`simpcity.describe_page`).
    private func describe(_ r: [String: Any]) -> String {
        if r.isEmpty { return "the page never answered (still loading, or blocked)" }
        if let e = r["error"] as? String { return "reading it failed: \(e)" }
        let posts = (r["posts"] as? [Any])?.count ?? 0
        return "it showed “\((r["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "no title")” (\(r["href"] as? String ?? "?")), "
            + "\(posts) post\(posts == 1 ? "" : "s"), page \((r["page"] as? NSNumber)?.intValue ?? 0), \(r["ready"] as? String ?? "?")"
    }

    /// SimpCity hides links from guests: show its login page and wait (while the screen is open) for
    /// the person to log in.
    private func waitForLogin() async -> Bool {
        guard showing else { return false }
        main.load(Self.loginURL)
        say("SimpCity shows its links only to members — log in on this screen, and the download starts by itself.")
        let start = Date()
        var sawLogin = false
        while Date().timeIntervalSince(start) < 900, !shouldStop {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            switch await main.string(SimpCityPage.loggedInScript) {
            case "yes": return true
            case "login-page": sawLogin = true
            case "left-login" where sawLogin: return true
            default: break
            }
        }
        return false
    }

    /// The full-size file behind a goonbox/turbo link: goonbox's own API first (`original_url`), else
    /// what the page shows once its script has built it (turbo's player, a download link, the picture).
    /// A check the lane can't pass is shown on the main (visible) page when the screen is open — the
    /// cookie it leaves lets every lane through; with the screen closed, the run stops and says so.
    private func resolve(_ item: SimpCity.Item, on lane: SimpCityPage) async -> URL? {
        guard let page = URL(string: item.link) else { return nil }
        if item.kind == "goonbox", let url = await goonboxOriginal(item, page: page, on: lane) { return url }
        let script = SimpCityPage.resolveScript(kind: item.kind)
        for attempt in 0..<2 {
            lane.load(page)
            let started = Date()
            // Only an answer from this file's own page counts (not the page before it).
            let r = await lane.poll(script, timeout: 45, patient: false) { r in
                ((r["href"] as? String) ?? "").contains(item.id)
                    && (!((r["url"] as? String) ?? "").isEmpty || (r["gone"] as? Bool) == true
                        || ((r["ready"] as? String) == "complete" && Date().timeIntervalSince(started) > 12))
            }
            if let s = r?["url"] as? String, !s.isEmpty, let url = URL(string: s) { return url }
            if (r?["gone"] as? Bool) == true { return nil }
            if lane.challenged {
                guard showing else {
                    stopNote = "\(page.host ?? "A site") is checking that a person is asking. Open Download from SimpCity, tap Get New, and answer it there."
                    return nil
                }
                // Let the person answer it on the visible page; the cleared cookie serves every lane.
                main.load(page)
                say("\(page.host ?? "The site") is checking that a person is asking — answer it on this screen; the download carries on by itself.")
                _ = await main.poll(script, timeout: 900, patient: true) { r in !((r["url"] as? String) ?? "").isEmpty }
            } else if attempt == 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        return nil
    }
}

/// One web view of the downloader: loads a page, runs a page script until its answer is ready, and
/// fetches files with `WKDownload` (WebKit's own network stack, cookies and all). Hidden pages sit in the
/// key window behind the app's views, full size — a web view outside a window has its page suspended.
@MainActor
final class SimpCityPage: NSObject {
    let webView: WKWebView
    /// The last poll ended on a "you're human?" check that wasn't answered.
    private(set) var challenged = false
    private var downloads: Set<SimpCityFileDownload> = []

    override init() {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()             // the SimpCity login + the sites' clearance cookies
        cfg.allowsInlineMediaPlayback = true          // turbo's player loads its video only once it plays (muted)
        cfg.mediaTypesRequiringUserActionForPlayback = []
        webView = WKWebView(frame: .zero, configuration: cfg)
        webView.isUserInteractionEnabled = false
        super.init()
    }

    /// Park the web view behind everything in the key window (so its page runs).
    func attachHidden() {
        guard let window = UIApplication.shared.connectedScenes
                .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first else { return }
        webView.removeFromSuperview()
        webView.frame = window.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.isUserInteractionEnabled = false
        window.insertSubview(webView, at: 0)
    }

    /// Show it inside `container` (the SimpCity screen), tappable.
    func present(in container: UIView) {
        webView.removeFromSuperview()
        webView.frame = container.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.isUserInteractionEnabled = true
        container.addSubview(webView)
    }

    /// Back behind the app when the SimpCity screen closes — a run in progress carries on.
    func retire() {
        webView.removeFromSuperview()
        attachHidden()
    }

    /// Whether the page is on `host` (or a subdomain of it).
    func isOn(_ host: String) -> Bool {
        guard let h = webView.url?.host?.lowercased() else { return false }
        return h == host || h.hasSuffix("." + host)
    }

    func load(_ url: URL) {
        if webView.window == nil { attachHidden() }
        webView.stopLoading()
        webView.load(URLRequest(url: url))
    }

    /// Runs `script` (an expression) and returns its value as a dictionary — passed as JSON text, and
    /// `{error}` when the script throws (same wrapper as `simpcity.json_call`).
    func json(_ script: String) async -> [String: Any]? {
        let call = "(() => { try { return JSON.stringify(\(script.trimmingCharacters(in: .whitespacesAndNewlines))); } "
            + "catch (e) { return JSON.stringify({ error: String(e) }); } })()"
        guard let text = await string(call), let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    func string(_ script: String) async -> String? {
        await withCheckedContinuation { cont in
            webView.evaluateJavaScript(script) { result, _ in cont.resume(returning: result as? String) }
        }
    }

    /// Runs `script` every `every` seconds until `accept` says its answer is ready (→ the answer) or `timeout`
    /// seconds pass (→ nil). On a "you're human?" check: when `patient` (the person can see this page)
    /// it waits up to 15 minutes for them to answer; otherwise it gives up after 20 s with `challenged`.
    func poll(_ script: String, timeout: Double, patient: Bool, every: Double = 0.25,
              accept: ([String: Any]) -> Bool) async -> [String: Any]? {
        challenged = false
        let start = Date()
        var deadline = start.addingTimeInterval(timeout)
        try? await Task.sleep(nanoseconds: UInt64(min(every, 0.15) * 1_000_000_000))
        while true {
            let r = await json(script) ?? [:]
            if (r["challenge"] as? Bool) == true {
                challenged = true
                deadline = max(deadline, min(Date().addingTimeInterval(patient ? 30 : 20),
                                             start.addingTimeInterval(patient ? 900 : 45)))
            } else {
                challenged = false
                if accept(r) { return r }
            }
            if Date() > deadline { return nil }
            try? await Task.sleep(nanoseconds: UInt64((challenged ? 1.0 : every) * 1_000_000_000))
        }
    }

    /// Downloads `url` through WebKit into a temp file (nil on failure, an error page, or an empty file).
    func download(_ url: URL, referer: String, ext: String) async -> URL? {
        if webView.window == nil { attachHidden() }
        let job = SimpCityFileDownload(ext: ext)
        downloads.insert(job)
        defer { downloads.remove(job) }
        var req = URLRequest(url: url)
        req.setValue(referer, forHTTPHeaderField: "Referer")
        return await job.run(on: webView, request: req)
    }

    // MARK: - Page scripts (kept identical to mac/simpcity.py)

    static let extractScript = #"""
(() => {
  const title = document.title || '';
  const challenge = (/DDoS-Guard|Just a moment|Checking your browser|Attention Required/i.test(title)
    || !!document.querySelector('#challenge-form, #cf-challenge-running, .ddg-captcha, [data-ddg-origin]'))
    && !document.querySelector('.p-body, article.message');
  const html = document.documentElement;
  const loggedIn = html.getAttribute('data-logged-in') === 'true';
  const inQuote = (e) => !!e.closest('blockquote, .bbCodeBlock--quote, .bbCodeQuote, .message-signature');
  const link = (v) => {
    try {
      const x = new URL(v, location.href);
      const to = /\/redirect\/?$/.test(x.pathname) ? x.searchParams.get('to') : null;
      if (to) {
        if (/^https?:\/\//i.test(to)) return to;
        let b = to.replace(/-/g, '+').replace(/_/g, '/');
        while (b.length % 4) b += '=';
        const d = atob(b);
        if (/^https?:\/\//i.test(d)) return d;
      }
      return x.href;
    } catch (e) { return ''; }
  };
  const posts = [];
  document.querySelectorAll('article.message, .message--post, li.message').forEach((p) => {
    const id = (p.getAttribute('data-content') || p.id || '').replace(/^(js-)?post-/, '');
    const t = p.querySelector('.message-attribution time, time.u-dt, time[data-timestamp], time[datetime], time[data-time]');
    let time = 0;
    if (t) {
      // XenForo 2.2+: data-timestamp is the time, data-time is a label ("12:34 PM"); older: data-time.
      const num = (v) => (/^\d{9,}$/.test(v || '') ? parseInt(v, 10) : 0);
      time = num(t.getAttribute('data-timestamp'))
        || Math.floor(Date.parse((t.getAttribute('datetime') || '').replace(/([+-]\d\d)(\d\d)$/, '$1:$2')) / 1000)
        || num(t.getAttribute('data-time')) || 0;
      if (!(time >= 946684800)) time = 0;
    }
    const body = p.querySelector('.message-userContent') || p.querySelector('.message-body') || p;
    const urls = new Set();
    const add = (e, v) => { if (v && !inQuote(e)) urls.add(link(v)); };
    body.querySelectorAll('a[href]').forEach((a) => add(a, a.getAttribute('href')));
    body.querySelectorAll('[data-url]').forEach((e) => add(e, e.getAttribute('data-url')));
    body.querySelectorAll('img').forEach((i) => ['data-url', 'data-src', 'src'].forEach((k) => add(i, i.getAttribute(k))));
    body.querySelectorAll('iframe, embed, video, video source').forEach((e) => add(e, e.getAttribute('src') || e.getAttribute('data-src') || e.getAttribute('data-url')));
    body.querySelectorAll('[data-s9e-mediaembed-src]').forEach((e) => add(e, e.getAttribute('data-s9e-mediaembed-src')));
    posts.push({ id, time, urls: [...urls].filter(Boolean) });
  });
  let last = 1;
  document.querySelectorAll('.pageNav-main a, .pageNav-page a, a.pageNav-jump, .pageNavSimple a').forEach((a) => {
    const m = (a.getAttribute('href') || '').match(/\/page-(\d+)/); if (m) last = Math.max(last, parseInt(m[1], 10));
    const n = parseInt((a.textContent || '').trim(), 10); if (n) last = Math.max(last, n);
  });
  const cur = (location.pathname.match(/\/page-(\d+)/) || [0, 1])[1];
  const heading = document.querySelector('h1.p-title-value');
  return { title: heading ? heading.textContent.trim() : title, challenge, loggedIn, posts, ready: document.readyState, href: location.href,
           last: Math.max(last, parseInt(cur, 10) || 1), page: parseInt(cur, 10) || 1,
           blocked: !!document.querySelector('.blockMessage--error, .p-body-pageContent .blockMessage') && posts.length === 0 };
})()
"""#

    /// goonbox's API, asked from a goonbox page (start it, then poll for the answer — the same pair of
    /// scripts Safe Finder runs): `/api/images/<id>` → `image.original_url`, the full-size file.
    static func goonboxScripts(id: String) -> (start: String, read: String) {
        let safe = String(id.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" })
        return (goonboxStartTemplate.replacingOccurrences(of: "__ID__", with: safe),
                goonboxReadTemplate.replacingOccurrences(of: "__ID__", with: safe))
    }

    static let loggedInScript = #"""
(() => {
  if (document.documentElement.getAttribute('data-logged-in') === 'true') return 'yes';
  if (document.querySelector('input[type="password"]') || /\/login/.test(location.pathname)) return 'login-page';
  return document.readyState === 'complete' ? 'left-login' : 'loading';
})()
"""#

    static func resolveScript(kind: String) -> String {
        resolveTemplate.replacingOccurrences(of: "__KIND__", with: kind == "turbo" ? "turbo" : "goonbox")
    }

    private static let goonboxStartTemplate = #"""
(() => {
  const id = "__ID__";
  window.__simpcity = window.__simpcity || {};
  delete window.__simpcity[id];
  fetch('/api/images/' + encodeURIComponent(id), { headers: { 'Accept': 'application/json' }, credentials: 'include' })
    .then((r) => r.text().then((t) => {
      let j = {}; try { j = JSON.parse(t); } catch (e) {}
      const im = j.image || {};
      window.__simpcity[id] = { status: r.status, url: im.original_url || '', name: im.original_filename || '',
                                deleted: !!(j.is_deleted || im.deleted_at) };
    }))
    .catch(() => { window.__simpcity[id] = { status: 0, url: '' }; });
  return true;
})()
"""#

    private static let goonboxReadTemplate = #"""
((window.__simpcity || {})["__ID__"] || null)
"""#

    private static let resolveTemplate = #"""
(() => {
  const KIND = "__KIND__";
  const title = document.title || '';
  const checking = /Just a moment|DDoS-Guard|Checking your browser|Attention Required|Verify you are human/i.test(title)
    || !!document.querySelector('#challenge-form, #cf-challenge-running, .cf-turnstile, [data-ddg-origin]');
  const abs = (v) => { try { return new URL(v, location.href).href; } catch (e) { return ''; } };
  const thumb = (u) => !u || /^(data|blob):/i.test(u) || /\.(md|th|thumb|sm|small)\.[a-z0-9]+(\?|$)|\/thumbs?\/|favicon|logo|avatar|\.svg(\?|$)/i.test(u);
  const isVideo = (u) => /\.(mp4|mov|m4v|webm|mkv)(\?|$)/i.test(u);
  const isImage = (u) => /\.(jpe?g|png|webp|gif|heic|avif)(\?|$)/i.test(u);
  const cands = [];
  const push = (raw, w) => {
    const u = abs(raw || '');
    if (thumb(u)) return;
    let s = w;
    if (KIND === 'turbo' && isVideo(u)) s += 30;
    if (KIND === 'goonbox' && isImage(u)) s += 30;
    if (/cuckcapital|\/panda\//i.test(u)) s += 20;
    if (/[?&]s=/.test(u)) s += 5;
    cands.push([u, s]);
  };
  try { const v = document.querySelector('video'); if (v && v.paused && v.play) { v.muted = true; v.play().catch(() => {}); } } catch (e) {}
  document.querySelectorAll('video source[src], video[src]').forEach((v) => push(v.currentSrc || v.getAttribute('src'), 100));
  try { performance.getEntriesByType('resource').forEach((e) => { if (isVideo(e.name)) push(e.name, 95); }); } catch (e) {}
  document.querySelectorAll('a[download][href]').forEach((a) => push(a.getAttribute('href'), 90));
  document.querySelectorAll('a[href]').forEach((a) => { const h = a.getAttribute('href') || ''; if (isVideo(h) || isImage(h)) push(h, 80); });
  document.querySelectorAll('meta[property="og:video"], meta[property="og:video:url"], meta[property="og:video:secure_url"]').forEach((m) => push(m.content, 70));
  document.querySelectorAll('meta[property="og:image"], meta[name="twitter:image"]').forEach((m) => push(m.content, 60));
  document.querySelectorAll('link[rel="image_src"]').forEach((l) => push(l.href, 60));
  let best = '', area = 0;
  document.querySelectorAll('img').forEach((i) => {
    const a = (i.naturalWidth || 0) * (i.naturalHeight || 0), src = i.currentSrc || i.src;
    if (a > area && !thumb(src)) { area = a; best = src; }
  });
  if (best && area >= 120000) push(best, 75);
  cands.sort((a, b) => b[1] - a[1]);
  const gone = /not found|404|removed|deleted/i.test(title) && cands.length === 0;
  const challenge = checking && cands.length === 0;
  return { challenge, url: cands.length ? cands[0][0] : '', title, gone, ready: document.readyState, href: location.href };
})()
"""#
}

/// One file fetched with `WKDownload` into the app's temp folder. A non-2xx answer or a page where a
/// file belongs (a block or check page) is a failure, not a file.
@MainActor
private final class SimpCityFileDownload: NSObject, WKDownloadDelegate {
    private let ext: String
    private var cont: CheckedContinuation<URL?, Never>?
    private var temp: URL?
    private var download: WKDownload?
    private var settled = false

    init(ext: String) { self.ext = ext }

    func run(on webView: WKWebView, request: URLRequest) async -> URL? {
        await withCheckedContinuation { c in
            cont = c
            webView.startDownload(using: request) { [weak self] download in
                download.delegate = self
                self?.download = download
            }
            // A download that hasn't started in a minute won't; one still going after 10 minutes is stuck.
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard let self, self.temp == nil else {
                    try? await Task.sleep(nanoseconds: 540_000_000_000)
                    self?.finish(nil)
                    return
                }
                self.finish(nil)
            }
        }
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        if !(200...299).contains(status) || (response.mimeType ?? "").hasPrefix("text/") {
            completionHandler(nil)                    // cancels it
            finish(nil)
            return
        }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("simpcity-" + UUID().uuidString).appendingPathExtension(ext)
        temp = tmp
        completionHandler(tmp)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let temp else { finish(nil); return }
        let size = (try? temp.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        if size < 64 { try? FileManager.default.removeItem(at: temp); finish(nil); return }
        finish(temp)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        if let temp { try? FileManager.default.removeItem(at: temp) }
        finish(nil)
    }

    private func finish(_ url: URL?) {
        guard !settled else { return }
        settled = true
        if url == nil {
            download?.cancel(nil)
            if let temp { try? FileManager.default.removeItem(at: temp) }
        }
        cont?.resume(returning: url)
        cont = nil
    }
}
