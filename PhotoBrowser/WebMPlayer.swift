import SwiftUI
import UIKit
import WebKit

/// WebM (VP8/VP9/AV1 in Matroska) playback and posters.
///
/// AVFoundation can't open WebM on iOS — AVPlayer, AVAssetImageGenerator and QuickLook all fail —
/// but WebKit plays it natively (iOS 17+). So a `.webm` gets its own viewer page: a `WKWebView`
/// whose `<video>` element streams the file, and grid posters come from the same engine drawing a
/// frame to a canvas offscreen.
///
/// The bytes reach WebKit through `WebMMediaSchemeHandler` (`pbmedia://`), not `file://`: the web
/// content process can't be relied on to read a security-scoped file on the external drive, and
/// copying a multi-GB video to the sandbox first would be slow and wasteful. The handler answers
/// HTTP **Range** requests (206 + `Content-Range`) so seeking reads only what's needed, and does
/// all file I/O on a background queue — never on the main thread (the drive can be slow).

/// Extensions played through WebKit instead of AVPlayer.
let webVideoExtensions: Set<String> = ["webm"]

nonisolated func isWebVideo(_ url: URL) -> Bool { webVideoExtensions.contains(url.pathExtension.lowercased()) }

// MARK: - Scheme handler

/// Serves one local file to a `WKWebView` as `pbmedia://media/<name>`, with Range support.
final class WebMMediaSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "pbmedia"
    static let pageURL = URL(string: "pbmedia://media/")!
    static func mediaURL(for file: URL) -> URL {
        let name = file.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "video.webm"
        return URL(string: "pbmedia://media/\(name)")!
    }

    private let file: URL
    private let ioQueue = DispatchQueue(label: "pbmedia.io", qos: .userInitiated)
    private var live = Set<ObjectIdentifier>()   // tasks not yet stopped (calling a stopped task throws)

    init(file: URL) { self.file = file }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        let id = ObjectIdentifier(task)
        live.insert(id)
        let file = self.file
        let range = Self.parseRange(task.request.value(forHTTPHeaderField: "Range"))
        let requestURL = task.request.url ?? Self.pageURL
        ioQueue.async { [weak self] in
            guard let handle = try? FileHandle(forReadingFrom: file),
                  let size = try? handle.seekToEnd() else {
                DispatchQueue.main.async { self?.fail(task, id) }
                return
            }
            defer { try? handle.close() }
            let total = Int64(size)
            // A Range request gets one bounded 206 slice (WebKit asks again for the rest); a plain
            // request gets a 200 with the full length, streamed in chunks — never the whole file in
            // memory at once.
            var start: Int64 = 0, end: Int64 = total - 1
            if let range {
                start = range.start ?? max(0, total - (range.suffix ?? 0))
                end = min(range.end ?? total - 1, total - 1, start + Self.sliceCap - 1)
            }
            guard total > 0, start <= end else {
                DispatchQueue.main.async { self?.respond(task, id, url: requestURL, status: 416, length: 0, range: nil, total: total) }
                return
            }
            let length = end - start + 1
            DispatchQueue.main.async {
                self?.respond(task, id, url: requestURL, status: range == nil ? 200 : 206,
                              length: length, range: range == nil ? nil : (start, end), total: total)
            }
            var offset = start
            while offset <= end {
                let n = Int(min(Self.chunk, end - offset + 1))
                guard (try? handle.seek(toOffset: UInt64(offset))) != nil,
                      let data = try? handle.read(upToCount: n), !data.isEmpty else {
                    DispatchQueue.main.async { self?.fail(task, id) }
                    return
                }
                offset += Int64(data.count)
                let last = offset > end
                var stopped = false
                DispatchQueue.main.sync {
                    guard let self, self.live.contains(id) else { stopped = true; return }
                    task.didReceive(data)
                    if last { self.live.remove(id); task.didFinish() }
                }
                if stopped { return }
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        live.remove(ObjectIdentifier(task))
    }

    private static let sliceCap: Int64 = 8 * 1024 * 1024   // max bytes per Range answer
    private static let chunk: Int64 = 1024 * 1024          // bytes per didReceive

    private func respond(_ task: any WKURLSchemeTask, _ id: ObjectIdentifier, url: URL, status: Int,
                         length: Int64, range: (Int64, Int64)?, total: Int64) {
        guard live.contains(id) else { return }
        var headers = ["Content-Type": "video/webm", "Content-Length": String(length),
                       "Accept-Ranges": "bytes", "Access-Control-Allow-Origin": "*"]
        if let r = range { headers["Content-Range"] = "bytes \(r.0)-\(r.1)/\(total)" }
        if status == 416 { headers["Content-Range"] = "bytes */\(total)" }
        task.didReceive(HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)
        if length == 0 { live.remove(id); task.didFinish() }
    }

    private func fail(_ task: any WKURLSchemeTask, _ id: ObjectIdentifier) {
        guard live.contains(id) else { return }
        live.remove(id)
        task.didFailWithError(URLError(.cannotOpenFile))
    }

    /// `bytes=a-b`, `bytes=a-` or `bytes=-n` (first range only); nil when absent or malformed.
    nonisolated private static func parseRange(_ header: String?) -> (start: Int64?, end: Int64?, suffix: Int64?)? {
        guard let header, header.hasPrefix("bytes=") else { return nil }
        let spec = header.dropFirst("bytes=".count).split(separator: ",").first ?? ""
        let parts = spec.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        if let a = Int64(parts[0]) { return (a, Int64(parts[1]), nil) }
        if let n = Int64(parts[1]) { return (nil, nil, n) }
        return nil
    }
}

// MARK: - Viewer page

/// Full-screen WebM page for the viewer: WebKit's own video controls, looping, plus the viewer's
/// swipe gestures (left/right = next/previous, down = close, up = info) recognized alongside them.
struct WebMPage: UIViewRepresentable {
    let url: URL
    let onDismiss: () -> Void
    let onInfo: () -> Void
    let onPrev: () -> Void
    let onNext: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.setURLSchemeHandler(WebMMediaSchemeHandler(file: url), forURLScheme: WebMMediaSchemeHandler.scheme)
        let web = WKWebView(frame: .zero, configuration: cfg)
        web.isOpaque = false
        web.backgroundColor = .black
        web.scrollView.backgroundColor = .black
        web.scrollView.isScrollEnabled = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        for direction in [UISwipeGestureRecognizer.Direction.left, .right, .down, .up] {
            let swipe = UISwipeGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.swiped(_:)))
            swipe.direction = direction
            swipe.cancelsTouchesInView = false
            swipe.delegate = context.coordinator
            web.addGestureRecognizer(swipe)
        }
        web.loadHTMLString(Self.html(for: url), baseURL: WebMMediaSchemeHandler.pageURL)
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) { context.coordinator.parent = self }

    static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) {
        web.evaluateJavaScript("var v=document.querySelector('video'); if(v){v.pause(); v.removeAttribute('src'); v.load();}")
        web.stopLoading()
    }

    private static func html(for url: URL) -> String {
        let src = WebMMediaSchemeHandler.mediaURL(for: url).absoluteString
        return """
        <!doctype html><html><head>
        <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
        <style>html,body{margin:0;height:100%;background:#000;overflow:hidden}
        video{position:fixed;inset:0;width:100%;height:100%;object-fit:contain;background:#000}
        #err{display:none;position:fixed;inset:0;color:#aaa;font:15px -apple-system;align-items:center;justify-content:center;text-align:center;padding:24px}</style>
        </head><body>
        <video src="\(src)" controls autoplay loop playsinline></video>
        <div id="err">This WebM can’t be played on this device.</div>
        <script>document.querySelector('video').addEventListener('error',function(){document.getElementById('err').style.display='flex'});</script>
        </body></html>
        """
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: WebMPage
        init(_ parent: WebMPage) { self.parent = parent }

        @objc func swiped(_ g: UISwipeGestureRecognizer) {
            switch g.direction {
            case .left:  parent.onNext()
            case .right: parent.onPrev()
            case .down:  parent.onDismiss()
            case .up:    parent.onInfo()
            default:     break
            }
        }

        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}

// MARK: - Posters

/// Grid posters for WebM files: an offscreen `WKWebView` loads the video muted, seeks ~1 s in (or
/// 10% of a short clip), draws the frame to a canvas and returns it as JPEG. One at a time (each
/// web view decodes video), bounded by a timeout so a broken file can't stall the queue.
@MainActor
final class WebMPoster: NSObject, WKScriptMessageHandler {
    static let shared = WebMPoster()

    private var queue: [(url: URL, maxPixel: CGFloat, done: (UIImage?) -> Void)] = []
    private var busy = false
    private var web: WKWebView?
    private var current: ((UIImage?) -> Void)?
    private var timeout: DispatchWorkItem?

    /// Callable from any isolation (the `nonisolated` Thumbnailer): hops to the main actor, where
    /// WebKit lives, and queues the file.
    nonisolated static func poster(for url: URL, maxPixel: CGFloat) async -> UIImage? {
        await withCheckedContinuation { cont in
            Task { @MainActor in
                shared.queue.append((url, maxPixel, { cont.resume(returning: $0) }))
                shared.next()
            }
        }
    }

    private func next() {
        guard !busy, !queue.isEmpty else { return }
        busy = true
        let job = queue.removeFirst()
        current = job.done
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.setURLSchemeHandler(WebMMediaSchemeHandler(file: job.url), forURLScheme: WebMMediaSchemeHandler.scheme)
        cfg.userContentController.add(self, name: "poster")
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 64, height: 64), configuration: cfg)
        // WebKit may not load media for a view outside any window: park it, invisible and
        // untouchable, in the key window while it works.
        web.alpha = 0.01
        web.isUserInteractionEnabled = false
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first { $0.isKeyWindow }
        window?.addSubview(web)
        window?.sendSubviewToBack(web)
        self.web = web
        let src = WebMMediaSchemeHandler.mediaURL(for: job.url).absoluteString
        let maxPx = Int(max(64, job.maxPixel))
        let html = """
        <!doctype html><html><body>
        <video id="v" src="\(src)" muted autoplay playsinline preload="auto" crossorigin="anonymous"></video>
        <script>
        var v=document.getElementById('v'), sent=false, seeking=false;
        function send(x){ if(!sent){ sent=true; v.pause(); window.webkit.messageHandlers.poster.postMessage(x); } }
        function grab(){
          try{ var w=v.videoWidth,h=v.videoHeight; if(!w||!h){send('');return;}
            var s=Math.min(1,\(maxPx)/Math.max(w,h)), c=document.createElement('canvas');
            c.width=Math.round(w*s); c.height=Math.round(h*s);
            c.getContext('2d').drawImage(v,0,0,c.width,c.height);
            send(c.toDataURL('image/jpeg',0.8)); }catch(e){ send(''); } }
        v.addEventListener('loadeddata',function(){
          v.pause();
          var d=isFinite(v.duration)?v.duration:0, t=d>10?1:d*0.1;
          if(t<0.05){ grab(); } else { seeking=true; v.currentTime=t; } });
        v.addEventListener('seeked',function(){ if(seeking) grab(); });
        v.addEventListener('error',function(){ send(''); });
        </script></body></html>
        """
        web.loadHTMLString(html, baseURL: WebMMediaSchemeHandler.pageURL)
        let t = DispatchWorkItem { [weak self] in self?.finish(nil) }
        timeout = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: t)
    }

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let s = message.body as? String, let comma = s.firstIndex(of: ","),
              let data = Data(base64Encoded: String(s[s.index(after: comma)...])),
              let img = UIImage(data: data) else { finish(nil); return }
        finish(img)
    }

    private func finish(_ image: UIImage?) {
        timeout?.cancel(); timeout = nil
        web?.configuration.userContentController.removeScriptMessageHandler(forName: "poster")
        web?.stopLoading()
        web?.removeFromSuperview()
        web = nil
        let done = current
        current = nil
        busy = false
        done?(image)
        next()
    }
}
