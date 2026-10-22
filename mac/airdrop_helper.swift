// The AirDrop picker for mac/airdrop_to_iphone.py.
//
// macOS has no command-line way to AirDrop; the sharing service is only reachable from AppKit. This
// program opens the Mac's AirDrop window for the files named on its command line and exits when the
// send finishes. The Python tool builds it once with `swiftc` (Xcode or its Command Line Tools) into
// ~/Library/Caches/PhotoBrowser/ and runs it from there; without swiftc it reveals the archives in
// Finder instead (right-click ▸ Share ▸ AirDrop does the same thing by hand).
//
// Exit codes: 0 sent · 1 failed (reason on stderr) · 2 AirDrop unavailable · 3 cancelled in the picker.
import AppKit

final class Driver: NSObject, NSApplicationDelegate, NSSharingServiceDelegate {
    let urls: [URL]
    init(urls: [URL]) { self.urls = urls }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else {
            FileHandle.standardError.write(Data("AirDrop isn't available on this Mac.\n".utf8))
            exit(2)
        }
        service.delegate = self
        NSApp.activate(ignoringOtherApps: true)
        service.perform(withItems: urls)
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        exit(0)
    }

    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSUserCancelledError { exit(3) }
        FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

let urls = CommandLine.arguments.dropFirst().map { URL(fileURLWithPath: $0) }
guard !urls.isEmpty else {
    FileHandle.standardError.write(Data("usage: airdrop_helper FILE…\n".utf8))
    exit(64)
}
let app = NSApplication.shared
let driver = Driver(urls: Array(urls))
app.delegate = driver
app.setActivationPolicy(.accessory)      // no Dock icon; the AirDrop window still comes to the front
app.run()
