import SwiftUI

/// "Get Info" for a folder: counts, size, dates, labels, and content year span.
struct FolderInfoView: View {
    @Environment(Library.self) private var library
    let folder: URL
    @State private var stats: FolderStats?

    var body: some View {
        NavigationStack {
            List {
                if let s = stats {
                    Section {
                        row("Name", folder.lastPathComponent)
                        if let bd = library.birthday(for: folder) {
                            row("Birthday", bd.formatted(date: .long, time: .omitted))
                        }
                        if let c = s.created { row("Created", c.formatted(date: .abbreviated, time: .shortened)) }
                        if let m = s.modified { row("Modified", m.formatted(date: .abbreviated, time: .shortened)) }
                    }
                    Section("Contents") {
                        row("Photos", "\(s.photos)")
                        row("Videos", "\(s.videos)")
                        row("Subfolders", "\(s.subfolders)")
                        row("Size", s.size.sizeString)
                        if let mn = s.minDate, let mx = s.maxDate {
                            row("Content", Self.span(from: mn, to: mx))
                        }
                    }
                    Section {
                        let labels = [library.isFavorite(folder) ? "Favorite" : nil,
                                      library.isAI(folder) ? "To AI" : nil].compactMap { $0 }
                        row("Labels", labels.isEmpty ? "None" : labels.joined(separator: ", "))
                    }
                } else {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Calculating…").foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Folder Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { library.toggleAI(folder) } label: {
                        Image(systemName: "sparkles").foregroundStyle(library.isAI(folder) ? .yellow : .primary)
                    }
                    Button { library.toggleFavorite(folder) } label: {
                        Image(systemName: library.isFavorite(folder) ? "heart.fill" : "heart")
                            .foregroundStyle(library.isFavorite(folder) ? .red : .primary)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task { stats = await library.folderStats(of: folder) }
    }

    private func row(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(key).foregroundStyle(.secondary)
            Spacer(minLength: 16)
            Text(value).multilineTextAlignment(.trailing)
        }
    }

    /// "2016-2022" for multi-year spans; "September 2025 - December 2025" within a year.
    static func span(from min: Date, to max: Date) -> String {
        let cal = Calendar.current
        let minY = cal.component(.year, from: min)
        let maxY = cal.component(.year, from: max)
        if minY != maxY { return "\(minY)-\(maxY)" }
        let f = DateFormatter(); f.dateFormat = "MMMM yyyy"
        let a = f.string(from: min), b = f.string(from: max)
        return a == b ? a : "\(a) - \(b)"
    }
}
