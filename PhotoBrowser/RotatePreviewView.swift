import SwiftUI

/// Preview-and-confirm sheet for bulk-rotating a multi-selection of photos. Shows **one** of the
/// selected photos rotated the chosen way so the direction can be confirmed before it's applied
/// to all of them. Applying rotates each photo *in place* (the original file is replaced),
/// preserving EXIF/metadata and capture date — handled by the caller via `onApply`.
struct RotatePreviewView: View {
    let entries: [Entry]
    /// Called with the chosen rotation (1 = right/CW, -1 = left/CCW, 2 = 180°) when the user confirms.
    let onApply: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var quarters = 1
    @State private var base: UIImage?
    @State private var loadFailed = false

    private var count: Int { entries.count }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                ZStack {
                    Color.black
                    if let base {
                        Image(uiImage: MediaEditing.rotate(base, quarters: quarters))
                            .resizable().scaledToFit()
                            .padding(6)
                    } else if loadFailed {
                        Label("Couldn’t load a preview", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal)
                .padding(.top, 8)

                Picker("Direction", selection: $quarters.animation(.easeInOut(duration: 0.2))) {
                    Text("Left").tag(-1)
                    Text("Right").tag(1)
                    Text("180°").tag(2)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                Text("Preview of 1 of \(count) photo\(count == 1 ? "" : "s"). All are rotated the same way. Originals are replaced; EXIF and capture date are kept.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                Button {
                    onApply(quarters); dismiss()
                } label: {
                    Text("Rotate \(count) Photo\(count == 1 ? "" : "s")").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(base == nil)
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
            .navigationTitle("Rotate Photos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .task {
                guard let first = entries.first else { loadFailed = true; return }
                // A downscaled, EXIF-upright decode — the same preview decode the viewer uses.
                base = await ZoomableImageView.decode(url: first.url, maxPixel: 1400, fullQuality: false)
                if base == nil { loadFailed = true }
            }
        }
    }
}
