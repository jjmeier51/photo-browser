import SwiftUI
import UniformTypeIdentifiers

/// The app-wide background (behind the browsing surfaces): whatever the chosen theme says —
/// by default a subtle deep navy at the top fading to black (see `AppTheme`).
struct AppGradient: View {
    @Environment(Library.self) private var library
    var body: some View {
        library.theme.backgroundView.ignoresSafeArea()
    }
}

struct ContentView: View {
    @Environment(Library.self) private var library
    @State private var showActivities = false

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
            // The drive went away mid-session: say so, instead of a normal-looking grid whose taps
            // do nothing. It clears itself when the drive comes back.
            if library.waitingForDrive && library.rootURL != nil {
                VStack { DriveBanner(); Spacer() }
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            // Bottom of the screen: a confirmation toast above the activity pill. Neither blocks
            // what's underneath (the empty space of this stack passes touches through).
            VStack(spacing: 8) {
                Spacer()
                if let toast = library.toast {
                    ToastView(text: toast.text)
                        .onTapGesture { library.toast = nil }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if !library.activities.isEmpty {
                    // One pill for every background job (frame export, downloads, upscales…); tap it
                    // for each job's progress and, where a job allows it, Stop.
                    Button { showActivities = true } label: { activityPill }
                        .buttonStyle(.plain)
                        .accessibilityHint("Shows background tasks")
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.bottom, 30)
        }
        .animation(.default, value: library.activities.count)
        .animation(.easeOut(duration: 0.25), value: library.toast)
        .animation(.easeOut(duration: 0.25), value: library.waitingForDrive)
        // Notice an unplugged drive while the app sits idle (otherwise only the next reload would).
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                await library.checkDrivePresence()
            }
        }
        .sheet(isPresented: $showActivities) { ActivitiesSheet() }
        // A job that failed or needs reading: one at a time, titled with what it's about. (Successes
        // are toasts.) Dismissed only through the binding — a button that also dismissed used to skip
        // the next queued message.
        .alert(library.notices.first?.title ?? "",
               isPresented: Binding(get: { !library.notices.isEmpty },
                                    set: { if !$0 { library.dismissNotice() } }),
               presenting: library.notices.first) { notice in
            if notice.opensSettings {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            }
            Button("OK", role: .cancel) {}
        } message: { notice in
            Text(notice.message)
        }
        // Portuguese→English caption translation for accessKardashian downloads —
        // hosted app-wide so it completes even after the download screen is closed.
        .modifier(CaptionTranslation(pending: $library.akPendingCaptions) { translated in
            library.setCaptions(translated)
            library.akPendingCaptions = [:]
        })
        // Something shared to us via the Share Extension → ask where to save + upscale options.
        .sheet(isPresented: Binding(
            get: { !library.pendingShares.isEmpty },
            set: { if !$0 { library.pendingShares = []; StorySharing.clear() } })) {
            StoryImportView()
        }
        // A file handed to the app (an AirDrop opened with Photo Browser, Files ▸ Open in) → ask where
        // on the drive it goes: archives unpack into folders, other files are placed as they are.
        // Closing with items still waiting keeps them staged; the sheet returns for the next arrival
        // or from Settings ▸ Received Files.
        .sheet(isPresented: Binding(
            get: { library.receivedSheetShown },
            set: { library.receivedSheetShown = $0 })) {
            ReceivedArchivesView()
        }
        // AI results (and the creator reopened after review) are NOT sheets here: a root-view sheet
        // can't present while the viewer's full-screen cover is up, so they go through
        // `ModalPresenter` onto whatever is top-most (see `Library.showAIResults`).
    }

    private func pillTitle(_ a: Library.Activity) -> String {
        a.fraction >= 0 ? "\(a.title) — \(Int(a.fraction * 100))%" : a.title
    }

    /// The job in progress — or, with several, how many and the first one's name.
    private var activityPill: some View {
        let first = library.activities[0]
        let many = library.activities.count > 1
        return HStack(spacing: 10) {
            ProgressView().controlSize(.small).tint(.primary)
            VStack(alignment: .leading, spacing: 1) {
                Text(many ? "\(library.activities.count) tasks running" : pillTitle(first))
                    .font(.caption.weight(.semibold))
                let status = many ? first.title : first.status
                if !status.isEmpty {
                    Text(status).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if !many, first.fraction >= 0 {
                ProgressView(value: first.fraction).progressViewStyle(.linear).frame(width: 70)
            }
            Image(systemName: "chevron.up").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .contentShape(Capsule())
    }
}

/// A short confirmation that fades by itself (see `Library.showToast`). Tap to dismiss early.
private struct ToastView: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.subheadline.weight(.medium))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.horizontal, 24)
    }
}

/// Every background job with its progress, and Stop for the ones that can stop between items.
private struct ActivitiesSheet: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(library.activities) { a in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(a.title).font(.subheadline.weight(.semibold))
                        Spacer()
                        if a.fraction >= 0 {
                            Text("\(Int(a.fraction * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    if !a.status.isEmpty {
                        Text(a.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    if a.fraction >= 0 { ProgressView(value: a.fraction) } else { ProgressView().frame(maxWidth: .infinity, alignment: .leading) }
                    if a.cancellable && !a.stopping {
                        Button("Stop", role: .destructive) { library.cancelActivity(a.id) }
                            .font(.subheadline)
                            .buttonStyle(.borderless)
                    }
                }
                .padding(.vertical, 4)
            }
            .overlay {
                if library.activities.isEmpty {
                    ContentUnavailableView("Nothing Running", systemImage: "checkmark.circle",
                                           description: Text("Background jobs show here while they run."))
                }
            }
            .navigationTitle("Activity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Shown over the browser when the drive disappears mid-session. Re-checks every couple of
/// seconds; when the drive is back (same or new mount path) the library reopens and the folder on
/// screen re-reads.
private struct DriveBanner: View {
    @Environment(Library.self) private var library

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.title3).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Drive disconnected").font(.subheadline.weight(.semibold))
                Text("Plug it back in and the library reopens on its own.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            ProgressView().controlSize(.small)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
        .task {
            while !Task.isCancelled && library.waitingForDrive {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                library.reconnectIfNeeded()
            }
            if !Task.isCancelled && !library.waitingForDrive { library.contentDidChange() }   // re-list what's on screen
        }
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
            PureTransferToggle()
                .padding(.top, 24)
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

/// The Pure File Transfer switch shown before a drive is connected (and in Settings). See
/// `Library.pureTransferMode` for exactly what it turns off.
struct PureTransferToggle: View {
    @Environment(Library.self) private var library

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(get: { library.pureTransferMode }, set: { library.setPureTransferMode($0) })) {
                Label("Pure File Transfer", systemImage: "arrow.left.arrow.right.square")
                    .font(.subheadline.weight(.semibold))
            }
            .tint(.accentColor)
            Text(library.pureTransferMode
                 ? "On: just move and copy files from this phone to the drive. No thumbnail library is kept on the phone, and the downloaders and photo editors stay out of the way. Duplicate detection still runs on every move."
                 : "Turn on to use the app only for moving files onto the drive — nothing is cached on the phone and the extra tools are hidden.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 28)
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
            PureTransferToggle()
                .padding(.top, 24)
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
