import SwiftUI

@main
struct PhotoBrowserApp: App {
    @State private var library = Library()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(library)
                .preferredColorScheme(.dark)
                .task { library.restoreLastFolder() }
        }
    }
}
