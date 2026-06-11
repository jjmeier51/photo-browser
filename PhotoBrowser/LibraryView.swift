import SwiftUI

/// Every photo and video across all folders, filterable by year, sorted newest
/// → oldest so the newest appear at the top.
struct LibraryView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss

    @State private var dates: [URL: Date] = [:]
    @State private var yearFilter: Int?
    @State private var displayItems: [Entry] = []
    @State private var presentation: ViewerPresentation?

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 4)]

    private var media: [Entry] { library.index.filter { $0.isViewable } }
    private func dateOf(_ e: Entry) -> Date { dates[e.url] ?? e.modified }
    private var years: [Int] {
        Array(Set(media.map { Calendar.current.component(.year, from: dateOf($0)) })).sorted(by: >)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 4) {
                    ForEach(Array(displayItems.enumerated()), id: \.element.id) { i, entry in
                        EntryCell(entry: entry,
                                  favorited: library.isFavorite(entry.url),
                                  aiLabeled: library.isAI(entry.url))
                            .onTapGesture { presentation = ViewerPresentation(items: displayItems, startIndex: i) }
                    }
                }
                .padding(4)
            }
            .navigationTitle("Library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { yearFilter = nil } label: { check("All Years", yearFilter == nil) }
                        ForEach(years, id: \.self) { y in
                            Button { yearFilter = y } label: { check(String(y), yearFilter == y) }
                        }
                    } label: {
                        Label("Year: \(yearFilter.map(String.init) ?? "All")", systemImage: "calendar")
                    }
                }
            }
            .overlay {
                if displayItems.isEmpty {
                    VStack(spacing: 8) {
                        if library.indexing || dates.isEmpty {
                            ProgressView()
                            Text("Loading library…").foregroundStyle(.secondary)
                        } else {
                            Text("No photos or videos").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .fullScreenCover(item: $presentation) { p in
                ViewerView(items: p.items, startIndex: p.startIndex)
            }
        }
        .task {
            rebuild()                                    // initial (by modified date)
            dates = await library.captureDates(for: media)
            rebuild()                                    // refine with capture dates
        }
        .onChange(of: yearFilter) { rebuild() }
    }

    private func rebuild() {
        var list = media
        if let y = yearFilter {
            list = list.filter { Calendar.current.component(.year, from: dateOf($0)) == y }
        }
        displayItems = list.sorted { dateOf($0) > dateOf($1) }   // newest first → at the top
    }

    @ViewBuilder private func check(_ title: String, _ on: Bool) -> some View {
        if on { Label(title, systemImage: "checkmark") } else { Text(title) }
    }
}
