import SwiftUI
import UniformTypeIdentifiers

/// The app-wide background gradient (behind the browsing surfaces): a subtle deep
/// navy blue at the top fading to black at the bottom.
struct AppGradient: View {
    var body: some View {
        LinearGradient(colors: [Color(red: 0.05, green: 0.09, blue: 0.20),
                                Color.black],
                       startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
    }
}

struct ContentView: View {
    @Environment(Library.self) private var library

    var body: some View {
        @Bindable var library = library
        ZStack {
            AppGradient()
            NavigationStack(path: $library.path) {
                Group {
                    if let root = library.rootURL {
                        FolderView(url: root, isRoot: true)
                            .id(root)            // reload when the root folder changes
                    } else if library.waitingForDrive {
                        // A library exists but its drive isn't reachable — wait for it
                        // instead of dropping to the first-run screen ("forgetting").
                        WaitingForDrive()
                    } else {
                        EmptyState()
                    }
                }
                .navigationDestination(for: URL.self) { url in
                    FolderView(url: url, isRoot: false)
                        .id(url)            // fresh identity per folder, so a path *replace* (e.g. "Open Stories") reloads the listing
                }
            }
            // Non-blocking, app-wide progress pills for background jobs (frame export, Instagram
            // downloads, …) — so they keep running while you browse and view media.
            if !library.activities.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    ForEach(library.activities) { activity in
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small).tint(.white)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(pillTitle(activity)).font(.caption.weight(.semibold))
                                if !activity.status.isEmpty {
                                    Text(activity.status).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            if activity.fraction >= 0 {
                                ProgressView(value: activity.fraction).progressViewStyle(.linear).frame(width: 70)
                            }
                        }
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .allowsHitTesting(false)         // never intercepts taps
                    }
                }
                .padding(.bottom, 30)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.default, value: library.activities.count)
        .alert("Done", isPresented: Binding(
            get: { !library.activityResults.isEmpty },
            set: { if !$0 { library.dismissActivityResult() } })) {
            Button("OK", role: .cancel) { library.dismissActivityResult() }
        } message: {
            Text(library.activityResults.first ?? "")
        }
    }

    private func pillTitle(_ a: Library.Activity) -> String {
        a.fraction >= 0 ? "\(a.title) — \(Int(a.fraction * 100))%" : a.title
    }
}

/// Shown when a saved library exists but its drive isn't reachable (e.g. the app
/// launched before the SSD was plugged in). Retries quietly and reopens the
/// library the moment the drive mounts; opening a different folder stays
/// available as an escape hatch.
struct WaitingForDrive: View {
    @Environment(Library.self) private var library
    @State private var showImporter = false

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "externaldrive.badge.questionmark")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)
            Text("Waiting for your drive…")
                .font(.title3.bold())
            Text("Plug in the drive that holds your library and it will reopen automatically.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            ProgressView()
                .padding(.top, 4)
            Button {
                showImporter = true
            } label: {
                Label("Open a Different Folder", systemImage: "folder.badge.plus").padding(.horizontal, 8)
            }
            .buttonStyle(.bordered)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppGradient())
        .navigationTitle("Photo Browser")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.folder],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                library.chooseFolder(url)
            }
        }
        // Poll while visible: iOS gives apps no volume-mount notification, so a
        // light retry loop is the only way to notice the drive coming back while
        // the app stays foregrounded. (Foregrounding also retries, in the App.)
        .task {
            while !Task.isCancelled {
                library.reconnectIfNeeded()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }
}

struct EmptyState: View {
    @Environment(Library.self) private var library
    @State private var showImporter = false
    @State private var showPhotosLibrary = false

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "externaldrive.badge.plus")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)
            Text("No folder yet")
                .font(.title3.bold())
            Text("Plug in your drive, then add a folder. Subfolders stay as folders you can open.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button {
                showImporter = true
            } label: {
                Label("Add Folder", systemImage: "folder.badge.plus").padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
            Button {
                showPhotosLibrary = true
            } label: {
                Label("Add Photo Library", systemImage: "photo.stack").padding(.horizontal, 8)
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppGradient())
        .navigationTitle("Photo Browser")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.folder],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                library.chooseFolder(url)
            }
        }
        .fullScreenCover(isPresented: $showPhotosLibrary) {
            PhotosLibraryView(targetFolder: nil)
        }
    }
}
