import SwiftUI

/// Drive-to-drive move, presented as its own screen so it doesn't collide with
/// the folder view's other dialogs/overlays. Confirms, moves the files here with
/// live progress (8-way, off-main), migrates Favorites/covers/captions, and — since
/// it's a move — deletes the originals as it goes.
///
/// The transfer is **pausable**: Pause lets the in-flight files finish, then parks
/// the job so you can come back to it. Resume picks up where it left off — already
/// transferred files are skipped (`reuseDestination` + same-size check in
/// `FileActions.transferContents`), so no work is repeated and nothing is duplicated.
/// The source's security-scoped access and the background-task window are held for the
/// lifetime of the screen so a pause doesn't drop them.
struct DriveTransferView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(Library.self) private var library
    let source: URL
    let destination: URL

    private enum Phase { case confirm, working, paused, done }
    @State private var phase: Phase = .confirm
    @State private var progress: Double = 0
    @State private var statusLine = "Scanning…"
    @State private var countLine = ""
    @State private var resultText = ""

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
            VStack(spacing: 22) {
                Spacer()
                switch phase {
                case .confirm:
                    Image(systemName: "externaldrive.badge.minus")
                        .font(.system(size: 54)).foregroundStyle(.tint)
                    Text("Move everything from “\(source.lastPathComponent)” into “\(destination.lastPathComponent)”?")
                        .font(.headline).multilineTextAlignment(.center)
                    Text("Its contents are copied here (keeping Favorites, album covers and captions), then the originals are deleted from “\(source.lastPathComponent)”. You can pause and resume; keep both drives connected.")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button(role: .destructive) { start(resume: false) } label: {
                        Text("Move (delete originals)").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).padding(.horizontal, 30).padding(.top, 8)

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
                }
                Spacer()
            }
            .padding()
            .navigationTitle("Transfer Drive")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if phase == .confirm {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
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

    /// Begins (or resumes) the move. The security scope and background window are
    /// acquired once on the first pass and held until the screen disappears, so a
    /// pause/resume cycle doesn't lose access mid-transfer.
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
        Task {
            let result = await FileActions.transferContents(
                from: source, into: destination, reuseDestination: reuse, move: true,
                isPaused: { flag.paused }) { p in
                    Task { @MainActor in
                        progress = p.fraction
                        statusLine = p.total == 0 ? p.currentName : "Copying \(p.currentName)"
                        countLine = p.total == 0 ? "" : "\(p.done) of \(p.total) files"
                    }
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

/// A tiny main-thread-set / background-read flag used to pause the off-main transfer.
/// `@unchecked Sendable`: it's a single `Bool` written only on the main actor and read
/// in the worker loop; a stale read just delays the pause by one file.
final class PauseFlag: @unchecked Sendable {
    var paused = false
}
