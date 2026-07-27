import SwiftUI
import UIKit

/// "On This Day" — media captured on today's month/day in earlier years, grouped by year. A
/// lightweight Memories surface (no auto-generated montage): tap any item to open that year's set in
/// the viewer. Scoped to the folder it's opened from (the whole library at Home). The lookup runs on
/// `Library.onThisDay`, which reuses the cached capture dates, so a repeat visit is cheap.
struct MemoriesView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let root: URL

    @State private var sections: [(year: Int, items: [Entry])] = []
    @State private var loading = true
    @State private var viewer: ViewerPresentation?

    private var thisYear: Int { Calendar.current.component(.year, from: Date()) }

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView("Looking through your library…")
                } else if sections.isEmpty {
                    ContentUnavailableView("Nothing On This Day", systemImage: "calendar",
                        description: Text("No photos or videos were captured on \(Date().formatted(.dateTime.month(.wide).day())) in earlier years."))
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 24) {
                            ForEach(sections, id: \.year) { section in
                                sectionView(section)
                            }
                        }
                        .padding(.vertical)
                    }
                }
            }
            .navigationTitle("On This Day")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .fullScreenCover(item: $viewer) { p in
                ViewerView(items: p.items, startIndex: p.startIndex).environment(library)
            }
            .task {
                sections = await library.onThisDay(under: root)
                loading = false
            }
        }
    }

    private func sectionView(_ section: (year: Int, items: [Entry])) -> some View {
        let ago = thisYear - section.year
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(ago) year\(ago == 1 ? "" : "s") ago").font(.title3.bold())
                Text("· \(String(section.year))").foregroundStyle(.secondary)
                Spacer()
                Text("\(section.items.count)").foregroundStyle(.secondary).font(.subheadline)
            }
            .padding(.horizontal)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 3)], spacing: 3) {
                ForEach(section.items.indices, id: \.self) { idx in
                    Button {
                        Haptics.light()
                        viewer = ViewerPresentation(items: section.items, startIndex: idx)
                    } label: {
                        MemoryThumb(entry: section.items[idx])
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 3)
        }
    }
}

/// A square, lazily-loaded thumbnail for one memory item.
private struct MemoryThumb: View {
    let entry: Entry
    @State private var image: UIImage?

    var body: some View {
        Color(.secondarySystemBackground)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: entry.kind == .video ? "video" : "photo")
                        .font(.title3).foregroundStyle(.secondary)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if entry.kind == .video {
                    Image(systemName: "play.circle.fill")
                        .foregroundStyle(.white).padding(5).shadow(radius: 2)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .task(id: entry.id) {
                image = await Thumbnailer.shared.thumbnail(for: entry, size: CGSize(width: 220, height: 220), scale: 2)
            }
    }
}
