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
                // File any background downloads that completed while we were away.
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { library.processPendingTikTok() }
                }
        }
    }
}

/// Captures background `URLSession` relaunch events for `BackgroundDownloader` so TikTok
/// downloads can finish while the app is suspended or closed.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        BackgroundDownloader.shared.backgroundCompletion = completionHandler
        BackgroundDownloader.shared.activate()
    }
}
