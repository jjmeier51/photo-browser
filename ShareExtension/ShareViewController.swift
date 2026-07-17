import UIKit
import UniformTypeIdentifiers

/// The Share-sheet extension's entry point. It runs when you tap **PhotoBrowser** in the iOS
/// share sheet (e.g. from Instagram's "Share story" → the story's link). It does the minimum an
/// app extension safely can: pull the shared link (or copy the shared image/video into the App
/// Group container), record it via `StorySharing`, then open the main app to finish — pick a
/// folder, choose upscale options, and download. The main app does the drive + network work.
///
/// No storyboard: `Info.plist` names this class as `NSExtensionPrincipalClass`. The view is a
/// brief spinner; the extension completes as soon as it has handed off.
final class ShareViewController: UIViewController {

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

        for p in providers {
            // A shared story is a web link.
            if p.hasItemConformingToTypeIdentifier(UTType.url.identifier),
               let url = await loadURL(p) {
                record(.init(kind: .url, value: url.absoluteString, timestamp: Date().timeIntervalSince1970))
                return openAppAndFinish()
            }
            // Some apps share the link as plain text.
            if p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
               let text = await loadText(p), let link = firstURL(in: text) {
                record(.init(kind: .url, value: link, timestamp: Date().timeIntervalSince1970))
                return openAppAndFinish()
            }
            // A shared photo/video file (e.g. from Photos): copy it into the App Group container.
            let isMovie = p.hasItemConformingToTypeIdentifier(UTType.movie.identifier)
            if isMovie || p.hasItemConformingToTypeIdentifier(UTType.image.identifier),
               let name = await copyFile(p, movie: isMovie) {
                record(.init(kind: .file, value: name, isVideoHint: isMovie, timestamp: Date().timeIntervalSince1970))
                return openAppAndFinish()
            }
        }
        finish()   // nothing usable
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
        let src: URL? = await withCheckedContinuation { cont in
            p.loadFileRepresentation(forTypeIdentifier: typeID) { url, _ in
                // The file is only valid inside this callback — copy it synchronously here.
                guard let url, let container = StorySharing.containerURL else { cont.resume(returning: nil); return }
                let name = "share_\(UUID().uuidString).\(url.pathExtension.isEmpty ? (movie ? "mov" : "jpg") : url.pathExtension)"
                let dest = container.appendingPathComponent(name)
                do { try FileManager.default.copyItem(at: url, to: dest); cont.resume(returning: dest) }
                catch { cont.resume(returning: nil) }
            }
        }
        return src?.lastPathComponent
    }

    private func firstURL(in text: String) -> String? {
        guard let d = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        return d.firstMatch(in: text, range: range)?.url?.absoluteString
    }

    private func record(_ item: StorySharing.PendingShare) { StorySharing.enqueue(item) }

    // MARK: - Hand off to the app

    private func openAppAndFinish() {
        if let url = URL(string: "\(StorySharing.urlScheme)://\(StorySharing.openHost)") {
            openURL(url)
        }
        finish()
    }

    /// Opens a URL from within an app extension. `UIApplication.shared` is unavailable to
    /// extensions, so walk the responder chain to whoever implements `openURL:` (the classic,
    /// still-working approach for share extensions).
    @discardableResult
    private func openURL(_ url: URL) -> Bool {
        var responder: UIResponder? = self
        let selector = sel_registerName("openURL:")
        while let r = responder {
            if r.responds(to: selector) {
                r.perform(selector, with: url)
                return true
            }
            responder = r.next
        }
        return false
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }
}
