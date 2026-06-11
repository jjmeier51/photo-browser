import SwiftUI

/// Drive-to-drive move, presented as its own screen so it doesn't collide with
/// the folder view's other dialogs/overlays. Confirms, copies (with progress),
/// migrates Favorites/covers/captions, then deletes the originals.
struct DriveTransferView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(Library.self) private var library
    let source: URL
    let destination: URL

    private enum Phase { case confirm, working, done }
    @State private var phase: Phase = .confirm
    @State private var progress: Double = 0
    @State private var statusLine = "Scanning…"
    @State private var countLine = ""
    @State private var resultText = ""

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
                    Text("Its contents are copied here (keeping Favorites, album covers and captions), then the originals are deleted from “\(source.lastPathComponent)”. Keep both drives connected.")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button(role: .destructive) { start() } label: {
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
                    Text("Keep both drives connected.").font(.caption2).foregroundStyle(.tertiary)

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
        }
    }

    private func start() {
        phase = .working
        progress = 0
        let bg = BackgroundTaskHolder(); bg.begin(name: "Transfer Drive")
        let accessed = source.startAccessingSecurityScopedResource()
        Task {
            let result = await FileActions.transferContents(from: source, into: destination, move: true) { p in
                Task { @MainActor in
                    progress = p.fraction
                    statusLine = p.total == 0 ? p.currentName : "Copying \(p.currentName)"
                    countLine = p.total == 0 ? "" : "\(p.done) of \(p.total) files"
                }
            }
            if let dest = result.destFolder {
                library.migrateMetadata(fromRoot: source, toRoot: dest, removeSource: true, verifyExists: true)
            }
            if accessed { source.stopAccessingSecurityScopedResource() }
            bg.end()
            library.contentDidChange()       // make the folder reload to show the new items
            resultText = result.moved == 0
                ? "Nothing could be moved — check the drive is still connected."
                : (result.failed > 0
                    ? "Moved \(result.moved) item(s); \(result.failed) couldn’t be moved."
                    : "Moved \(result.moved) item(s), with Favorites kept.")
            phase = .done
        }
    }
}
