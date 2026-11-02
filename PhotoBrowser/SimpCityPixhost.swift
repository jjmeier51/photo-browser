import Foundation

/// pixhost images in SimpCity threads — reading pixhost (pixhost.cc, also .to / .org / pixho.st) needs no
/// browser. The Mac twin is `simpcity.pixhost_resolve` / `pixhost_gallery_items` in `mac/simpcity.py`; the
/// link rules (`pixhostLink`, the show/thumbnail/file patterns) live with the record in `SimpCityRecord.swift`.
///
/// **The full-size file.** A post usually embeds the thumbnail (`t<N>.pixhost…/thumbs/<dir>/<id>_<name>`)
/// inside a link to the show page; the file is `img<N>.pixhost…/images/<dir>/<id>_<name>` on the same
/// server N. That address is used when the server answers it with the image itself — a wrong server
/// answers with a redirect to a "removed" picture, which is refused here (`NoRedirect`), never followed and
/// saved. Otherwise the show page says: its main picture (`<img id="image" class="image-img" src=…>`),
/// accepted only as an `/images/` original. A removed image's show page is a 404.
///
/// **Galleries** (`/gallery/<id>`): the gallery page lists every image's show link and thumbnail; each
/// becomes an item dated by the post that linked the gallery. Its own `?page=` links are followed, should a
/// big gallery be split.
///
/// The work is `@concurrent` (network + parsing off the main actor); everything passed in and out is plain
/// values.
extension SimpCity {
    nonisolated static let pixhostReferer = "https://pixhost.cc/"

    nonisolated private static let pixhostAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    nonisolated private static let pixhostSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 25
        cfg.timeoutIntervalForResource = 60
        return URLSession(configuration: cfg)
    }()

    /// Refuses redirects: pixhost answers a wrong server guess with one (to a "removed" picture).
    nonisolated private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    nonisolated private static func pixhostRequest(_ url: URL) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue(pixhostAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(pixhostReferer, forHTTPHeaderField: "Referer")
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        return req
    }

    /// Whether `url` answers with an image itself (headers only; the body isn't read).
    nonisolated private static func pixhostAnswersImage(_ url: URL) async -> Bool {
        guard let (bytes, response) = try? await pixhostSession.bytes(for: pixhostRequest(url), delegate: NoRedirect())
        else { return false }
        bytes.task.cancel()
        guard let http = response as? HTTPURLResponse else { return false }
        return http.statusCode == 200 && (http.value(forHTTPHeaderField: "Content-Type") ?? "").hasPrefix("image/")
    }

    nonisolated private static func pixhostPage(_ url: URL) async -> (text: String?, why: String) {
        do {
            let (data, response) = try await pixhostSession.data(for: pixhostRequest(url))
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else { return (nil, "HTTP \(code)") }
            return (String(decoding: data, as: UTF8.self), "")
        } catch {
            return (nil, "couldn’t connect (\(error.localizedDescription))")
        }
    }

    nonisolated private static func unescaped(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&#038;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
    }

    /// The full-size file a show page shows: its main picture, checked to be an `/images/` original — never
    /// a logo, an ad or a thumbnail.
    nonisolated static func pixhostImage(page: String, show: String) -> String? {
        let tags = [#"<img\b[^>]*\bclass="[^"]*\bimage-img\b[^"]*"[^>]*\bsrc="([^"]+)""#,
                    #"<img\b[^>]*\bsrc="([^"]+)"[^>]*\bclass="[^"]*\bimage-img\b"#,
                    #"<img\b[^>]*\bid="image"[^>]*\bsrc="([^"]+)""#]
        for pattern in tags {
            guard var url = firstGroups(page, pattern)?.first.map(unescaped) else { continue }
            if url.hasPrefix("//") { url = "https:" + url }
            if url.contains("/images/"), firstGroups(url, pixhostFilePattern) != nil { return url }
        }
        // Any original of this very image on the page.
        let want = (show.components(separatedBy: "/show/").last ?? "")
        guard !want.isEmpty else { return nil }
        let escaped = NSRegularExpression.escapedPattern(for: want)
        guard let re = try? NSRegularExpression(pattern: #"https?://img\d+\."# + pixhostDomain + "/images/" + escaped,
                                                options: [.caseInsensitive]),
              let m = re.firstMatch(in: page, range: NSRange(page.startIndex..., in: page)),
              let r = Range(m.range, in: page) else { return nil }
        return String(page[r])
    }

    /// The full-size file for a pixhost link: the address worked out from its thumbnail when the server
    /// answers it with the image, else the one its show page shows. (nil, why) when neither does.
    @concurrent nonisolated static func pixhostResolve(_ link: String) async -> (url: URL?, why: String) {
        if link.contains("/images/"), firstGroups(link, pixhostFilePattern) != nil,
           let direct = URL(string: link), await pixhostAnswersImage(direct) {
            return (direct, "")
        }
        let show = pixhostShow(link)
        guard let showURL = URL(string: show) else { return (nil, "not a pixhost address") }
        let (page, why) = await pixhostPage(showURL)
        guard let page else { return (nil, "its page (\(show)) answered \(why)") }
        guard let image = pixhostImage(page: page, show: show), let url = URL(string: image) else {
            return (nil, "its page (\(show)) shows no image — removed?")
        }
        return (url, "")
    }

    /// The images of a pixhost gallery, as items dated by the post that linked it — each at its full-size
    /// address worked out from its thumbnail, else its show page. ([], why) when it can't be read.
    @concurrent nonisolated static func pixhostGalleryItems(id: String, url: String, post: String,
                                                           posted: Double) async -> (items: [Item], why: String) {
        var out: [String: Item] = [:]
        var order: [String] = []
        var next: String? = url
        var seen: Set<String> = []
        let host = URL(string: url)?.host ?? "pixhost.cc"
        while let current = next, !seen.contains(current), seen.count < 50, let pageURL = URL(string: current) {
            seen.insert(current)
            let (text, why) = await pixhostPage(pageURL)
            guard let page = text else {
                return out.isEmpty ? ([], why) : (order.compactMap { out[$0] }, "")
            }
            guard let attr = try? NSRegularExpression(pattern: #"(?:href|src|data-src)="([^"]+)""#) else { break }
            for m in attr.matches(in: page, range: NSRange(page.startIndex..., in: page)) {
                guard let r = Range(m.range(at: 1), in: page), let p = pixhostLink(unescaped(String(page[r]))) else { continue }
                if let have = out[p.id] {
                    if p.link.contains("/images/"), !have.link.contains("/images/") {
                        out[p.id] = Item(kind: "pixhost", id: p.id, link: p.link, post: post, posted: posted)
                    }
                } else {
                    out[p.id] = Item(kind: "pixhost", id: p.id, link: p.link, post: post, posted: posted)
                    order.append(p.id)
                }
            }
            next = nil
            let pageLinks = #"href="([^"]*/gallery/"# + NSRegularExpression.escapedPattern(for: id) + #"[^"]*[?&]page=\d+[^"]*)""#
            if let re = try? NSRegularExpression(pattern: pageLinks) {
                for m in re.matches(in: page, range: NSRange(page.startIndex..., in: page)) {
                    guard let r = Range(m.range(at: 1), in: page) else { continue }
                    var cand = unescaped(String(page[r]))
                    if !cand.hasPrefix("http") { cand = "https://\(host)\(cand)" }
                    if !seen.contains(cand) { next = cand; break }
                }
            }
        }
        return (order.compactMap { out[$0] }, "")
    }
}
