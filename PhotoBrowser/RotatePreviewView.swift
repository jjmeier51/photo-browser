import SwiftUI

/// Preview-and-confirm sheet for bulk-rotating a multi-selection of photos **and/or videos**.
/// Shows **one** of the selected items rotated the chosen way (a video is previewed on its
/// poster frame) so the direction can be confirmed before it's applied to all of them.
/// Applying rotates each item *in place* (the original file is replaced), preserving
/// EXIF/metadata, capture date and HDR — photos via a 10-bit path when they carry HDR,
/// videos via an HDR-aware re-encode — handled by the caller via `onApply`.
struct RotatePreviewView: View {
    let entries: [Entry]
    /// Called with the chosen rotation (1 = right/CW, -1 = left/CCW, 2 = 180°) when the user confirms.
    let onApply: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var quarters = 1
    @State private var base: UIImage?
    @State private var loadFailed = false

    private var count: Int { entries.count }
    private var photoCount: Int { entries.filter { $0.kind == .image }.count }
    private var videoCount: Int { entries.filter { $0.kind == .video }.count }

    /// "3 photos", "2 videos", or "2 photos & 1 video" — matches the mix being rotated.
    private var itemsPhrase: String {
        func plural(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }
        switch (photoCount, videoCount) {
        case let (p, 0): return plural(p, "photo")
        case let (0, v): return plural(v, "video")
        case let (p, v): return "\(plural(p, "photo")) & \(plural(v, "video"))"
        }
    }

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

                Text("Preview of 1 of \(count) item\(count == 1 ? "" : "s"). All are rotated the same way. Originals are replaced; EXIF, capture date and HDR are kept.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                Button {
                    onApply(quarters); dismiss()
                } label: {
                    Text("Rotate \(itemsPhrase)").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(base == nil)
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
            .navigationTitle("Rotate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .task {
                guard let first = entries.first else { loadFailed = true; return }
                // A downscaled, EXIF-upright preview — a decode for photos, the poster frame for videos.
                if first.kind == .video {
                    base = await MediaEditorView.videoPoster(first.url)
                } else {
                    base = await ZoomableImageView.decode(url: first.url, maxPixel: 1400, fullQuality: false)
                }
                if base == nil { loadFailed = true }
            }
        }
    }
}
