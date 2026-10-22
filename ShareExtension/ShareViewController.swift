import UIKit
import UniformTypeIdentifiers

/// The Share-sheet extension's entry point. It runs when you tap **PhotoBrowser** in the iOS
/// share sheet (e.g. from Instagram's "Share story" → the story's link, or an archive in Files).
/// It does the minimum an app extension safely can: pull the shared link (or copy the shared
/// image/video/archive into the App Group container), record it, then open the main app to
/// finish — pick a folder, choose upscale options, download, or unpack. The main app does the
/// drive + network work. Every usable item in the share is recorded (several archives at once).
///
/// Self-contained on purpose: the App-Group hand-off (the constants + the `PendingShare` shape
/// below) is **duplicated** from `PhotoBrowser/StorySharing.swift` rather than shared, so this
/// file is the extension target's *only* Swift source and the target needs no cross-target file
/// membership. The two copies MUST stay in sync — the app reads exactly what this writes:
///   • App Group id `group.jayymei.PhotoBrowser`
///   • UserDefaults key `photoBrowser.pendingSharedItems`
///   • `PendingShare` fields: id, kind ("url"/"file"/"archive"), value, isVideoHint, timestamp
///     (an archive's value is `share_<id>/<original name>` inside the container)
///   • URL scheme `photobrowser://share`
final class ShareViewController: UIViewController {

    // MARK: - App Group hand-off (keep in sync with StorySharing.swift)

    private static let appGroupID = "group.jayymei.PhotoBrowser"
    private static let defaultsKey = "photoBrowser.pendingSharedItems"
    /// Archives the app unpacks: zips, and its own `.pbgallery` (declared by the app's Info.plist,
    /// which the extension shares, so the type resolves here too).
    private static let archiveTypes: [UTType] = [UTType.zip, UTType("jayymei.PhotoBrowser.gallery-archive")].compactMap { $0 }

    private struct PendingShare: Codable {
        enum Kind: String, Codable { case url, file, archive }
        var id = UUID()
        var kind: Kind
        var value: String
        var isVideoHint: Bool = false
        var timestamp: Double
    }

    private static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    private func record(_ item: PendingShare) {
        guard let d = UserDefaults(suiteName: Self.appGroupID) else { return }
        var items = (d.data(forKey: Self.defaultsKey)).flatMap { try? JSONDecoder().decode([PendingShare].self, from: $0) } ?? []
        items.append(item)
        if let data = try? JSONEncoder().encode(items) { d.set(data, forKey: Self.defaultsKey) }
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        let spinner = UIActivityIndicatorView(style: .large)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimating()
        view.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        Task { await handleShare() }
    }

    private func handleShare() async {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
        let now = Date().timeIntervalSince1970
        var recorded = 0

        for p in providers {
            // A shared story is a web link — but ONLY a real http/https link. A shared movie/image
            // item ALSO advertises a `file://` URL for itself, so the old "URL first, any scheme"
            // check recorded that bogus file:// "link" (which the app can't download) instead of the
            // actual video. That's why sharing a *video* story did nothing while photos (whose image
            // item isn't exposed as a URL) worked. Requiring http/https lets a movie's file:// URL
            // fall through to the file branches below.
            if p.hasItemConformingToTypeIdentifier(UTType.url.identifier), let url = await loadURL(p),
               let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                record(.init(kind: .url, value: url.absoluteString, timestamp: now)); recorded += 1
                continue
            }
            // An archive — a `.pbgallery` from the Mac's airdrop tool, or any zip (an AirDropped
            // folder that landed in Files arrives as one): copied into the container under its own
            // name, so the app can name the unpacked folder after it. Before image/movie: a zip is neither.
            if let typeID = Self.archiveType(of: p), let path = await copyArchive(p, typeID: typeID) {
                record(.init(kind: .archive, value: path, timestamp: now)); recorded += 1
                continue
            }
            // A shared photo/video file (from Instagram's "share to", Photos, etc.): copy it into
            // the App Group container. Checked before plain text so a movie always beats any stray
            // text representation.
            let isMovie = p.hasItemConformingToTypeIdentifier(UTType.movie.identifier)
            if isMovie || p.hasItemConformingToTypeIdentifier(UTType.image.identifier),
               let name = await copyFile(p, movie: isMovie) {
                record(.init(kind: .file, value: name, isVideoHint: isMovie, timestamp: now)); recorded += 1
                continue
            }
            // Some apps share the link as plain text.
            if p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
               let text = await loadText(p), let link = firstURL(in: text) {
                record(.init(kind: .url, value: link, timestamp: now)); recorded += 1
            }
        }
        if recorded > 0 { openAppAndFinish() } else { finish() }   // nothing usable → just close
    }

    /// The type identifier to load an archive under, or nil when the item isn't one. A `.pbgallery`
    /// coming from an app that didn't resolve the type is recognised by its name.
    private static func archiveType(of p: NSItemProvider) -> String? {
        for id in p.registeredTypeIdentifiers {
            if let t = UTType(id), archiveTypes.contains(where: { t.conforms(to: $0) }) { return id }
        }
        if p.suggestedName?.lowercased().hasSuffix(".pbgallery") == true {
            return p.registeredTypeIdentifiers.first { UTType($0)?.conforms(to: .data) ?? false }
        }
        return nil
    }

    // MARK: - Item loading

    private func loadURL(_ p: NSItemProvider) async -> URL? {
        await withCheckedContinuation { cont in
            p.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                cont.resume(returning: item as? URL)
            }
        }
    }

    private func loadText(_ p: NSItemProvider) async -> String? {
        await withCheckedContinuation { cont in
            p.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                cont.resume(returning: item as? String)
            }
        }
    }

    /// Copies the provided image/movie into the App Group container under a unique name; returns
    /// the filename (the app moves it into the chosen folder and deletes it from the container).
    private func copyFile(_ p: NSItemProvider, movie: Bool) async -> String? {
        let typeID = movie ? UTType.movie.identifier : UTType.image.identifier
        let dest: URL? = await withCheckedContinuation { cont in
            p.loadFileRepresentation(forTypeIdentifier: typeID) { url, _ in
                // The file is only valid inside this callback — copy it synchronously here.
                guard let url, let container = Self.containerURL else { cont.resume(returning: nil); return }
                let ext = url.pathExtension.isEmpty ? (movie ? "mov" : "jpg") : url.pathExtension
                let out = container.appendingPathComponent("share_\(UUID().uuidString).\(ext)")
                do { try FileManager.default.copyItem(at: url, to: out); cont.resume(returning: out) }
                catch { cont.resume(returning: nil) }
            }
        }
        return dest?.lastPathComponent
    }

    /// Copies an archive into the App Group container as `share_<id>/<its name>` — a folder of its
    /// own so the original name survives (the app names the unpacked folder after it). Returns that
    /// relative path.
    private func copyArchive(_ p: NSItemProvider, typeID: String) async -> String? {
        let suggested = p.suggestedName
        return await withCheckedContinuation { cont in
            p.loadFileRepresentation(forTypeIdentifier: typeID) { url, _ in
                // The file is only valid inside this callback — copy it synchronously here.
                guard let url, let container = Self.containerURL else { cont.resume(returning: nil); return }
                var name = url.lastPathComponent
                if let suggested, !suggested.isEmpty { name = suggested }
                if (name as NSString).pathExtension.isEmpty {
                    name += "." + (url.pathExtension.isEmpty ? "zip" : url.pathExtension)
                }
                let dir = container.appendingPathComponent("share_\(UUID().uuidString)", isDirectory: true)
                do {
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: url, to: dir.appendingPathComponent(name))
                    cont.resume(returning: "\(dir.lastPathComponent)/\(name)")
                } catch {
                    try? FileManager.default.removeItem(at: dir)
                    cont.resume(returning: nil)
                }
            }
        }
    }

    private func firstURL(in text: String) -> String? {
        guard let d = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        return d.firstMatch(in: text, range: range)?.url?.absoluteString
    }

    // MARK: - Hand off to the app

    private func openAppAndFinish() {
        guard let url = URL(string: "photobrowser://share") else { return finish() }
        // Share extensions have no public API to open their containing app. The reliable route is to
        // walk the responder chain to the live `UIApplication` instance (`UIApplication.shared` is
        // off-limits in extensions) and call the MODERN `open(_:options:completionHandler:)`. The
        // previous code performed the *deprecated* `openURL:` selector, which no longer launches the
        // app on current iOS — so the extension just flashed white and dismissed without opening us.
        // `NSExtensionContext.open` is a no-op for share extensions, kept only as a last-ditch.
        // Crucially, DELAY `completeRequest`: tearing the extension down immediately kills the open
        // before it takes effect. Retry briefly in case the view isn't in the window (responder
        // chain not yet reaching UIApplication) the instant we ask.
        openHostApp(url, attemptsLeft: 6)
    }

    /// Opens `url` in the containing app by finding the `UIApplication` in the responder chain and
    /// calling `open(_:options:completionHandler:)`. If the chain doesn't reach a `UIApplication`
    /// yet (the view may not be in the window at the moment of the first try), retries shortly.
    /// Finishes the extension request once the app has been asked to open (or attempts run out).
    private func openHostApp(_ url: URL, attemptsLeft: Int) {
        var responder: UIResponder? = self
        while let r = responder {
            if let app = r as? UIApplication {
                app.open(url, options: [:], completionHandler: nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in self?.finish() }
                return
            }
            responder = r.next
        }
        guard attemptsLeft > 0 else {
            extensionContext?.open(url, completionHandler: nil)   // last-ditch; usually a no-op here
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.finish() }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.openHostApp(url, attemptsLeft: attemptsLeft - 1)
        }
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }
}
