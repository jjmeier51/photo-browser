import SwiftUI
import UIKit

/// Order-picker shown before combining videos: the selected clips in a drag-to-reorder list, so you
/// choose the sequence they're stitched in. "Combine" hands the ordered URLs back to the caller.
struct VideoCombineView: View {
    @Environment(\.dismiss) private var dismiss
    let onCombine: ([URL]) -> Void
    @State private var ordered: [Entry]

    init(videos: [Entry], onCombine: @escaping ([URL]) -> Void) {
        self.onCombine = onCombine
        _ordered = State(initialValue: videos)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Array(ordered.enumerated()), id: \.element.id) { index, entry in
                        HStack(spacing: 12) {
                            Text("\(index + 1)")
                                .font(.callout.monospacedDigit().weight(.semibold))
                                .foregroundStyle(.secondary).frame(width: 22)
                            CombineThumb(entry: entry)
                                .frame(width: 52, height: 52)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            Text(entry.name).lineLimit(1)
                            Spacer(minLength: 0)
                            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                        }
                    }
                    .onMove { from, to in ordered.move(fromOffsets: from, toOffset: to) }
                } header: {
                    Text("Drag to set the order they’re joined")
                } footer: {
                    Text("The clips are stitched top to bottom into one new video.")
                }
            }
            .environment(\.editMode, .constant(.active))     // handles always visible; drag to reorder
            .navigationTitle("Combine \(ordered.count) Videos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Combine") {
                        Haptics.medium()
                        onCombine(ordered.map(\.url))
                        dismiss()
                    }.fontWeight(.semibold)
                }
            }
        }
    }
}

/// A square, lazily-loaded thumbnail for one clip in the reorder list.
private struct CombineThumb: View {
    let entry: Entry
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "video").foregroundStyle(.secondary)
            }
            Image(systemName: "play.circle.fill")
                .font(.callout).foregroundStyle(.white.opacity(0.9)).shadow(radius: 1)
        }
        .task(id: entry.id) {
            image = await Thumbnailer.shared.thumbnail(for: entry, size: CGSize(width: 120, height: 120), scale: 2)
        }
    }
}
