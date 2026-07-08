import SwiftUI

/// "Prepare Drive for Removal" — the app-level equivalent of a desktop **Eject**.
///
/// Physically pulling an exFAT drive while a directory write is in flight can tear the FAT
/// (no journaling), so the only real guarantee is to make sure nothing is mid-write when the
/// user unplugs. This sheet does exactly that: it `pause()`s `DriveWriter` so no new file
/// placement can start, waits for any in-flight commit to finish and flush, gives the drive a
/// final `fsync`, and then tells the user it's safe to disconnect. New commits stay blocked
/// until the sheet is dismissed, so the "safe" window can't be silently reopened by a
/// background download landing a file a moment later.
///
/// Dismissing `resume()`s the writer. If the user unplugged, the queued commits simply fail
/// (drive gone) and their downloaders log the failure — harmless. If they changed their mind
/// and kept the drive attached, downloads pick back up where they left off.
struct EjectDriveView: View {
    enum Stage { case preparing, safe }
    @State private var stage: Stage = .preparing
    @Environment(\.dismiss) private var dismiss

    /// The current drive root, so the final flush hits the volume the user is about to pull.
    let root: URL?

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            switch stage {
            case .preparing:
                ProgressView()
                    .controlSize(.large)
                Text("Finishing writes…")
                    .font(.title2.weight(.semibold))
                Text("Making sure no file is mid-write before you disconnect. This takes a moment.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            case .safe:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.green)
                Text("Safe to Disconnect")
                    .font(.title2.weight(.semibold))
                Text("All writes are flushed and paused. You can unplug the drive now.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Text(stage == .safe ? "Done" : "Cancel")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 32)
            .padding(.bottom, 24)
        }
        .interactiveDismissDisabled(stage == .preparing)   // don't let a swipe reopen the write window mid-drain
        .task {
            await DriveWriter.shared.pause()
            await DriveWriter.shared.waitUntilIdle()
            await DriveWriter.shared.quiesce(root: root)
            stage = .safe
        }
        .onDisappear {
            // Whether they unplugged or backed out, let the writer run again. Detached so
            // dismissal isn't gated on the actor.
            Task.detached(priority: .utility) { await DriveWriter.shared.resume() }
        }
    }
}
