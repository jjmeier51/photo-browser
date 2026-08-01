import SwiftUI

/// Drive-to-drive move, presented as its own screen so it doesn't collide with
/// the folder view's other dialogs/overlays. Confirms, moves the files here with
/// live progress (8-way, off-main), migrates Favorites/covers/captions, and — since
/// it's a move — deletes the originals as it goes.
///
/// Two ways to move: **everything** in the picked folder, or a **chosen subset** of its
/// files (recursively listed, with a Select-All / some / none picker). Either way the
/// picked items keep their subfolder layout at the destination.
///
/// The transfer is **pausable**: Pause lets the in-flight files finish, then parks
/// the job so you can come back to it. Resume picks up where it left off — already
/// transferred files are skipped (`reuseDestination` + same-size check in
/// `FileActions.transferContents` / `transferItems`), so no work is repeated and nothing is
/// duplicated. The source's security-scoped access and the background-task window are held
/// for the lifetime of the screen so a pause doesn't drop them.
struct DriveTransferView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(Library.self) private var library
    let source: URL
    let destination: URL

    private enum Phase { case confirm, scanning, choose, working, paused, done }
    @State private var phase: Phase = .confirm
    @State private var progress: Double = 0
    @State private var statusLine = "Scanning…"
    @State private var countLine = ""
    @State private var resultText = ""

    // Selective transfer: the scanned files, the picked ids, and (once started) the chosen
    // subset. `chosenItems == nil` means "move the whole folder" (the original behavior).
    @State private var scanItems: [FileActions.TransferItem] = []
    @State private var chosen = Set<UUID>()
    @State private var chosenItems: [FileActions.TransferItem]?

    /// The subfolder the first pass created; reused on resume so we keep filling the
    /// same destination instead of making "Folder 1", "Folder 2", …
    @State private var destFolder: URL?
    /// Distinct files moved across all (possibly paused/resumed) passes.
    @State private var movedSoFar = 0
    @State private var failedSoFar = 0

    /// Polled by the off-main transfer between files; set on Pause, cleared on Resume.
    @State private var pauseFlag = PauseFlag()
    /// Ensures the metadata migration runs at most once.
    @State private var migrated = false
    /// Security scope + background window, acquired once and released when the screen goes away.
    @State private var accessing = false
    @State private var bgTask = BackgroundTaskHolder()

    var body: some View {
        NavigationStack {
            Group {
                if phase == .choose { chooseView }
                else { centeredView }
            }
            .navigationTitle("Transfer Drive")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if phase == .confirm || phase == .scanning {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                }
                if phase == .choose {
                    ToolbarItem(placement: .cancellationAction) { Button("Back") { phase = .confirm } }
                }
            }
            .interactiveDismissDisabled(phase == .working)
            .onDisappear {
                // If a paused job is dismissed without finishing, still re-key the labels
                // of whatever already moved so they aren't orphaned.
                if phase == .paused { finishMigration() }
                releaseAccess()
            }
        }
    }

    // MARK: - Centered phases (confirm / scanning / working / paused / done)

    private var centeredView: some View {
        VStack(spacing: 22) {
            Spacer()
            switch phase {
            case .confirm:
                Image(systemName: "externaldrive.badge.minus")
                    .font(.system(size: 54)).foregroundStyle(.tint)
                Text("Move from “\(source.lastPathComponent)” into “\(destination.lastPathComponent)”?")
                    .font(.headline).multilineTextAlignment(.center)
                Text("Move everything, or choose specific files. What moves is copied here (keeping Favorites, album covers and captions), then the originals are deleted from “\(source.lastPathComponent)”. You can pause and resume; keep both drives connected.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button(role: .destructive) { chosenItems = nil; start(resume: false) } label: {
                    Text("Move Everything (delete originals)").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).padding(.horizontal, 30).padding(.top, 8)
                Button { beginChoose() } label: {
                    Text("Choose Specific Items…").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).padding(.horizontal, 30)

            case .scanning:
                ProgressView()
                Text("Scanning “\(source.lastPathComponent)”…").foregroundStyle(.secondary)

            case .working:
                ProgressView(value: progress).progressViewStyle(.linear).frame(width: 250)
                Text("\(Int(progress * 100))%").font(.headline.monospacedDigit())
                Text(statusLine)
                    .font(.subheadline).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).frame(maxWidth: 280)
                if !countLine.isEmpty {
                    Text(countLine).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Button { requestPause() } label: {
                    Label("Pause", systemImage: "pause.circle").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).padding(.horizontal, 60).padding(.top, 4)
                Text("Keep both drives connected.").font(.caption2).foregroundStyle(.tertiary)

            case .paused:
                Image(systemName: "pause.circle.fill")
                    .font(.system(size: 54)).foregroundStyle(.tint)
                Text("Paused").font(.headline)
                Text(movedSoFar == 0 ? "Nothing moved yet."
                     : "\(movedSoFar) item(s) moved so far. Resume to finish the rest.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button { start(resume: true) } label: {
                    Label("Resume", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).padding(.horizontal, 40).padding(.top, 8)
                Button("Leave for Now") { finishMigration(); dismiss() }
                    .padding(.top, 2)

            case .done:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 54)).foregroundStyle(.green)
                Text(resultText).font(.headline).multilineTextAlignment(.center)
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent).padding(.top, 8)

            case .choose:
                EmptyView()   // handled by chooseView
            }
            Spacer()
        }
        .padding()
    }

    // MARK: - Choose-specific-items

    /// The scanned files with a thumbnail/size/location and a check, so the user can move a subset
    /// instead of the whole folder. Files keep their subfolder layout at the destination.
    private var chooseView: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(chosen.count) of \(scanItems.count) selected").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Button(chosen.count == scanItems.count ? "Deselect All" : "Select All") {
                    chosen = chosen.count == scanItems.count ? [] : Set(scanItems.map { $0.id })
                }.font(.subheadline)
            }
            .padding(.horizontal).padding(.vertical, 8)

            List {
                ForEach(scanItems) { item in
                    Button {
                        if chosen.contains(item.id) { chosen.remove(item.id) } else { chosen.insert(item.id) }
                    } label: {
                        TransferPickRow(item: item, selected: chosen.contains(item.id))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button { startChosen() } label: {
                Text(chosen.isEmpty ? "Select items to move"
                     : "Move \(chosen.count) Selected (delete originals)")
                    .fontWeight(.semibold).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent).disabled(chosen.isEmpty)
            .padding().background(.ultraThinMaterial)
        }
    }

    /// Acquire access (once), then scan the source's files off-main for the picker.
    private func beginChoose() {
        if !accessing {
            accessing = source.startAccessingSecurityScopedResource()
            bgTask.begin(name: "Transfer Drive")
        }
        phase = .scanning
        Task {
            let items = await FileActions.scanTransferItems(under: source)
            scanItems = items
            chosen = Set(items.map { $0.id })      // default: everything selected
            if items.isEmpty {
                resultText = "No files found in “\(source.lastPathComponent)”."
                phase = .done
            } else {
                phase = .choose
            }
        }
    }

    private func startChosen() {
        let picks = scanItems.filter { chosen.contains($0.id) }
        guard !picks.isEmpty else { return }
        chosenItems = picks
        start(resume: false)
    }

    // MARK: - Transfer

    /// Begins (or resumes) the move — the whole folder, or the chosen subset when `chosenItems` is
    /// set. The security scope and background window are acquired once on the first pass and held
    /// until the screen disappears, so a pause/resume cycle doesn't lose access mid-transfer.
    private func start(resume: Bool) {
        if !accessing {
            accessing = source.startAccessingSecurityScopedResource()
            bgTask.begin(name: "Transfer Drive")
        }
        pauseFlag.paused = false
        phase = .working
        progress = 0
        let flag = pauseFlag
        let reuse = destFolder
        let picks = chosenItems
        let onProgress: @Sendable (FileActions.TransferProgress) -> Void = { p in
            Task { @MainActor in
                progress = p.fraction
                statusLine = p.total == 0 ? p.currentName : "Copying \(p.currentName)"
                countLine = p.total == 0 ? "" : "\(p.done) of \(p.total) files"
            }
        }
        Task {
            let result: FileActions.TransferResult
            if let picks {
                result = await FileActions.transferItems(
                    picks, from: source, into: destination, reuseDestination: reuse, move: true,
                    isPaused: { flag.paused }, progress: onProgress)
            } else {
                result = await FileActions.transferContents(
                    from: source, into: destination, reuseDestination: reuse, move: true,
                    isPaused: { flag.paused }, progress: onProgress)
            }
            destFolder = result.destFolder
            // A move empties the source, so successes across passes are disjoint (accumulate).
            // Failures stay in the source and get retried next pass, so keep only the latest.
            movedSoFar += result.moved
            failedSoFar = result.failed
            if result.paused {
                phase = .paused
            } else {
                finishMigration()
                resultText = movedSoFar == 0
                    ? "Nothing could be moved — check the drive is still connected."
                    : (failedSoFar > 0
                        ? "Moved \(movedSoFar) item(s); \(failedSoFar) couldn’t be moved."
                        : "Moved \(movedSoFar) item(s), with Favorites kept.")
                phase = .done
            }
        }
    }

    private func requestPause() {
        pauseFlag.paused = true
        statusLine = "Pausing — finishing current files…"
    }

    /// Re-keys labels/covers/captions from the source paths to the destination and
    /// reloads the folder. Safe to run once at the very end (it's path-based, not
    /// dependent on which files have moved yet) — so it's only called on completion
    /// or when the user leaves a paused job. Idempotent via `verifyExists`.
    private func finishMigration() {
        guard !migrated, let dest = destFolder else { return }
        migrated = true
        library.migrateMetadata(fromRoot: source, toRoot: dest, removeSource: true, verifyExists: true)
        library.contentDidChange()
    }

    private func releaseAccess() {
        if accessing { source.stopAccessingSecurityScopedResource(); accessing = false }
        bgTask.end()
    }
}

/// One selectable file row for the drive-transfer picker: a thumbnail (media) or type icon,
/// the name, and its size · source subfolder. Thumbnails load lazily off-main.
private struct TransferPickRow: View {
    let item: FileActions.TransferItem
    let selected: Bool
    @State private var image: UIImage?

    private var entry: Entry {
        Entry(url: item.url, name: item.name, kind: item.kind, size: item.size, modified: Date())
    }

    private var subtitle: String {
        let folder = (item.rel as NSString).deletingLastPathComponent
        return folder.isEmpty ? item.size.sizeString : "\(item.size.sizeString) · in \(folder)"
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                if let image { Image(uiImage: image).resizable().scaledToFill() }
                else { Rectangle().fill(.quaternary).overlay { Image(systemName: item.kind.systemImage).foregroundStyle(.secondary) } }
            }
            .frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).font(.subheadline.weight(.medium)).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.title3).foregroundStyle(selected ? Color.accentColor : Color.secondary)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .task(id: item.id) {
            if item.kind == .image || item.kind == .video {
                image = await Thumbnailer.shared.thumbnail(for: entry, size: CGSize(width: 48, height: 48),
                                                           scale: UIScreen.main.scale)
            }
        }
    }
}

/// A tiny main-thread-set / background-read flag used to pause the off-main transfer.
/// `@unchecked Sendable`: it's a single `Bool` written only on the main actor and read
/// in the worker loop; a stale read just delays the pause by one file.
final class PauseFlag: @unchecked Sendable {
    var paused = false
}
