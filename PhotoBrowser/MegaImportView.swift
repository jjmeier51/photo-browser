import SwiftUI
import UIKit

/// "Add from MEGA": paste a public MEGA folder link, then download its photos and
/// videos into the current drive folder (in a subfolder named after the MEGA
/// folder, preserving its structure).
///
/// The download runs as an **app-wide activity** (the progress pill), not inside this
/// sheet: tapping Download kicks it off and closes the sheet, so the user can keep
/// browsing / navigating while it downloads. Best-effort background window; like every
/// transfer it can't finish once the app is fully terminated.
struct MegaImportView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let targetFolder: URL
    let onFinished: () -> Void

    @State private var link = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://mega.nz/folder/…", text: $link, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                } header: {
                    Text("MEGA folder link")
                } footer: {
                    Text("Photos and videos in the link are downloaded into “\(targetFolder.lastPathComponent)”. "
                        + "Downloading runs in the background — you can keep using the app while it finishes. Nothing is uploaded.")
                }
            }
            .navigationTitle("Add from MEGA")
            .navigationBarTitleDisplayMode(.inline)
            // Convenience: pre-fill from the clipboard so a freshly-copied MEGA link
            // is ready to go without pasting by hand.
            .onAppear {
                if link.isEmpty,
                   let pasted = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !pasted.isEmpty {
                    link = pasted
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Download") { start() }
                        .disabled(link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func start() {
        library.startMegaImport(link: link, into: targetFolder)
        onFinished()
        dismiss()
    }
}
