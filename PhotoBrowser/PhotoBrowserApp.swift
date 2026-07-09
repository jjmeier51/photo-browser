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
                .preferredColorScheme(.dark)
                .task { library.restoreLastFolder() }
                // On every return to foreground: retry the drive if it was missing
                // (or moved to a new mount path), then file any background downloads
                // that completed while we were away.
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        library.reconnectIfNeeded()
                        library.processPendingTikTok()
                    } else if phase == .background {
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
        return true
    }

    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        BackgroundDownloader.shared.backgroundCompletion = completionHandler
        BackgroundDownloader.shared.activate()
    }
}
