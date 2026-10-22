import SwiftUI
import UIKit

@main
struct PhotoBrowserApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var library = Library()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(library)
                .preferredColorScheme(library.theme.colorScheme)
                .tint(library.theme.accentColor)
                .fontDesign(library.theme.fontDesign)
                .environment(\.font, library.theme.defaultFont)
                .task {
                    library.applyPureTransferMode()
                    library.restoreLastFolder()
                    library.configureAINotificationRouting()
                    library.refreshPendingArchives()        // file management — on in every mode
                    // Pure File Transfer: no background jobs — the app is only here to move files.
                    if !library.pureTransferMode {
                        library.refreshPendingShares()
                        library.resumePendingAIEdits()
                    }
                }
                // The Share Extension opens us via photobrowser://share after stashing what was
                // shared in the App Group; pick it up so ContentView can present the import sheet.
                // A file handed to us — an AirDropped `.pbgallery`/zip ("Open with Photo Browser") or
                // "Open in Photo Browser" from Files — arrives as a file URL (iOS has copied it into
                // Documents/Inbox); the Received sheet asks where on the drive it unpacks.
                .onOpenURL { url in
                    if url.scheme == StorySharing.urlScheme { library.refreshPendingShares() }
                    else if url.isFileURL { library.receiveArchive(url) }
                }
                // On every return to foreground: retry the drive if it was missing
                // (or moved to a new mount path), then file any background downloads
                // that completed while we were away, and finish any Astria job whose
                // wait was cut short (suspended app, lost network) — Astria keeps the
                // images, so this is when they can finally be fetched.
                // A TikTok download that finished while the app is in use is filed straight away.
                .onReceive(NotificationCenter.default.publisher(for: BackgroundDownloader.landed)) { _ in
                    if !library.pureTransferMode { library.processPendingTikTok() }
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        BackgroundDownloader.shared.setForeground(true)
                        library.reconnectIfNeeded()
                        library.refreshPendingArchives()
                        if !library.pureTransferMode {
                            library.processPendingTikTok()
                            library.refreshPendingShares()
                            library.resumePendingAIEdits()
                        }
                    } else if phase == .background {
                        // Hand any in-flight TikTok downloads to the background session first — the
                        // fast lane only runs while we're on screen.
                        BackgroundDownloader.shared.setForeground(false)
                        // Arm the drive's "safe to remove" state on the way out. This drains
                        // any commit already in flight and flushes the drive root, so if the
                        // user unplugs while the app is suspended, the last thing that touched
                        // the exFAT directory was a completed, fsync'd write — not a torn one.
                        // It does NOT pause active downloads: a background-task download window
                        // keeps committing at full speed; this just guarantees a flushed
                        // baseline the moment we background.
                        let root = library.rootURL
                        Task.detached(priority: .utility) {
                            await DriveWriter.shared.quiesce(root: root)
                        }
                    }
                }
        }
    }
}

/// Captures background `URLSession` relaunch events for `BackgroundDownloader` so TikTok
/// downloads can finish while the app is suspended or closed.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Install the notification delegate before launch completes so AI-completion alerts
        // present reliably while the app is foreground (iOS only fires `willPresent` when the
        // delegate is set this early).
        AINotifications.configureAtLaunch()
        AppTheme.load().applyNavigationBarFont()    // appearance proxies only reach bars made after this
        return true
    }

    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        BackgroundDownloader.shared.backgroundCompletion = completionHandler
        BackgroundDownloader.shared.setForeground(false)       // relaunched in the background for the session's events
        BackgroundDownloader.shared.activate()
    }
}
