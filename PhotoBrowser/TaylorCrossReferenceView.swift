import SwiftUI

/// Cross-references the photos in a folder against taylorpictures.net by filename
/// and writes each match's date + location into the file. Building the site index
/// browses thousands of public album pages (cached after the first run); only the
/// date/location metadata of local files is changed. Presented on its own screen.
struct TaylorCrossReferenceView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let folder: URL
    let onFinished: () -> Void

    @State private var running = false
    @State private var phase = ""
    @State private var fraction = 0.0
    @State private var rebuildIndex = false
    @State private var result: TaylorGallery.CrossRefResult?
    @State private var cached: TaylorGallery.SiteIndex?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Matches the photos in “\(folder.lastPathComponent)” to taylorpictures.net by filename, then writes the matching date and location into each file. A photo's own EXIF date is kept when present; location comes from the album/event title.")
                        .font(.callout)
                } footer: {
                    Text("Only date/location metadata of your local files is changed. Building the gallery index browses thousands of public album pages and can take several minutes the first time — it's cached afterward.")
                }

                if let cached {
                    Section {
                        Toggle("Rebuild gallery index", isOn: $rebuildIndex)
                        Text("Cached index: \(cached.albums) albums, \(cached.images) images.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                if running {
                    Section {
                        ProgressView(value: fraction)
                        Text(phase).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Text("Keep the app open; it keeps going briefly in the background.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }

                if let result {
                    Section("Result") {
                        Label("\(result.updated) of \(result.scanned) updated", systemImage: result.updated > 0 ? "checkmark.circle" : "exclamationmark.triangle")
                            .foregroundStyle(result.updated > 0 ? .green : .orange)
                        if result.unmatched > 0 { Text("\(result.unmatched) not found on the site").font(.caption).foregroundStyle(.secondary) }
                        if result.ambiguous > 0 { Text("\(result.ambiguous) skipped (filename appears across multiple events)").font(.caption).foregroundStyle(.secondary) }
                        if result.noData > 0 { Text("\(result.noData) matched but had no date or place").font(.caption).foregroundStyle(.secondary) }
                        if let note = result.note { Text(note).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            .navigationTitle("Cross-Reference")
            .navigationBarTitleDisplayMode(.inline)
            .task { cached = await Task.detached { TaylorGallery.cachedIndex() }.value }
            .interactiveDismissDisabled(running)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(result != nil ? "Done" : "Cancel") { dismiss() }.disabled(running)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") { start() }.disabled(running)
                }
            }
        }
    }

    private func start() {
        running = true; result = nil; fraction = 0
        let useCache = cached != nil && !rebuildIndex
        let bg = BackgroundTaskHolder()
        bg.begin(name: "Cross-Reference")
        Task {
            let index: TaylorGallery.SiteIndex
            if useCache, let c = cached {
                index = c
            } else {
                index = await TaylorGallery.buildIndex { p in
                    Task { @MainActor in phase = p.phase; fraction = p.fraction * 0.5 }
                }
            }
            let r = await TaylorGallery.crossReference(folder: folder, index: index) { p in
                Task { @MainActor in phase = p.phase; fraction = (useCache ? 0 : 0.5) + p.fraction * (useCache ? 1 : 0.5) }
            }
            running = false
            bg.end()
            result = r
            if r.updated > 0 { library.contentDidChange(); onFinished() }
        }
    }
}
