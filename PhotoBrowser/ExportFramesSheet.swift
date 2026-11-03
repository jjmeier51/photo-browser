import SwiftUI
import AVFoundation

/// Asks for the destination folder name, how many frames per second, and — for an HDR video — the
/// colour to export in before kicking off "Export All Frames": standard range (tone-mapped like the
/// press-and-hold screenshot; the default) or HDR with the screenshot look. The colour choice is kept
/// (`FileActions.framesStandardRangeKey`) and used by the bulk export too. Every frame (the video's native rate) is the baseline; two lighter
/// rates export fewer frames (faster + smaller). You can't export more than every frame, so the
/// alternatives are subsamples rather than a higher rate.
struct ExportFramesSheet: View {
    let entry: Entry
    let onExport: (_ name: String, _ fps: Double, _ standardRange: Bool) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var nativeFPS: Double = 30
    @State private var choice = 0          // 0 every frame · 1 half · 2 quarter
    @AppStorage(FileActions.framesStandardRangeKey) private var standardRange = true

    private var defaultName: String { entry.url.deletingPathExtension().lastPathComponent + " Frames" }

    var body: some View {
        NavigationStack {
            Form {
                Section("Folder name") {
                    TextField(defaultName, text: $name)
                        .autocorrectionDisabled()
                }
                Section {
                    Picker("Frames per second", selection: $choice) {
                        Text("Every frame · \(fpsLabel(nativeFPS))").tag(0)
                        Text("Half · \(fpsLabel(nativeFPS / 2))").tag(1)
                        Text("Quarter · \(fpsLabel(nativeFPS / 4))").tag(2)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("Frames per second")
                } footer: {
                    Text("“Every frame” exports the video’s full frame rate. The lighter rates export fewer frames — faster and smaller. (Exporting more than every frame isn’t possible.)")
                }
                Section {
                    Picker("Colour", selection: $standardRange) {
                        Text("Standard range").tag(true)
                        Text("HDR").tag(false)
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("HDR video")
                } footer: {
                    Text(standardRange
                         ? "HDR frames are tone-mapped to standard range, like a press-and-hold screenshot — they look right anywhere."
                         : "HDR frames stay HDR, with the screenshot look — highlights eased so they aren’t blown out.")
                }
            }
            .navigationTitle("Export All Frames")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Export") {
                        let fps = choice == 1 ? nativeFPS / 2 : (choice == 2 ? nativeFPS / 4 : 0)
                        onExport(name, fps, standardRange)
                        dismiss()
                    }
                }
            }
            .task {
                let asset = AVURLAsset(url: entry.url)
                if let track = try? await asset.loadTracks(withMediaType: .video).first,
                   let r = try? await track.load(.nominalFrameRate), r > 0 { nativeFPS = Double(r) }
            }
        }
    }

    private func fpsLabel(_ v: Double) -> String { "\(max(1, Int(v.rounded()))) fps" }
}
