import SwiftUI
import CoreLocation

/// The swipe-up details sheet — like the iOS Photos info card.
struct InfoPanel: View {
    @Environment(Library.self) private var library
    let entry: Entry
    @State private var info: MediaInfo?
    @State private var fileCaption: String?
    @State private var savedFrom: String?
    @State private var placeName: String?
    @State private var showCaptionEditor = false
    @State private var captionDraft = ""

    /// App override wins (incl. "" = cleared); otherwise the file's embedded caption.
    private var effectiveCaption: String {
        if let override = library.captions[entry.url.path] { return override }
        return fileCaption ?? ""
    }

    private var inTaylorSwift: Bool { entry.url.pathComponents.contains("Taylor Swift") }

    var body: some View {
        NavigationStack {
            List {
                Section("Caption") {
                    if effectiveCaption.isEmpty {
                        Button("Add Caption") { captionDraft = ""; showCaptionEditor = true }
                    } else {
                        Text(effectiveCaption)
                        Button("Edit Caption") { captionDraft = effectiveCaption; showCaptionEditor = true }
                            .font(.callout)
                    }
                }

                Section {
                    if let date = info?.date, let age = library.age(forFile: entry.url, captureDate: date) {
                        row("Age", "\(age)")
                    }
                    row("Name", entry.name)
                    if let date = info?.date {
                        row("Date", date.formatted(date: .abbreviated, time: .shortened))
                    }
                    if let device = info?.device {
                        row("Device", device)
                    }
                    if let dimensions = info?.dimensions {
                        row("Dimensions", dimensions)
                    }
                    row("Size", ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                    if let place = placeName {
                        row("Location", place)
                    } else if let c = info?.coordinate {
                        row("Location", String(format: "%.5f, %.5f", c.latitude, c.longitude))
                    }
                    if let savedFrom { row("Saved from", savedFrom) }
                    if let poster = library.postedBy(for: entry.url) { row("Posted by", "@\(poster)") }
                    row("Folder", entry.url.deletingLastPathComponent().lastPathComponent)
                    row("Path", entry.url.deletingLastPathComponent().path)
                    let labels = [library.isFavorite(entry.url) ? "Favorite" : nil,
                                  library.isAI(entry.url) ? "To AI" : nil,
                                  library.postedBy(for: entry.url) != nil ? "Instagram" : nil].compactMap { $0 }
                    row("Labels", labels.isEmpty ? "None" : labels.joined(separator: ", "))
                }

                if inTaylorSwift {
                    Section("Taylor Swift Labels") {
                        ForEach(Library.taylorSwiftLabels, id: \.self) { name in
                            Button { library.toggleLabel(name, on: entry.url) } label: {
                                HStack {
                                    Text(name).foregroundStyle(.primary)
                                    Spacer()
                                    if library.hasLabel(name, entry.url) {
                                        Image(systemName: "checkmark").foregroundStyle(.tint)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        library.toggleAI(entry.url)
                    } label: {
                        Image(systemName: library.isAI(entry.url) ? "sparkles" : "sparkles")
                            .foregroundStyle(library.isAI(entry.url) ? .yellow : .primary)
                    }
                    Button {
                        library.toggleFavorite(entry.url)
                    } label: {
                        Image(systemName: library.isFavorite(entry.url) ? "heart.fill" : "heart")
                            .foregroundStyle(library.isFavorite(entry.url) ? .red : .primary)
                    }
                }
            }
            .alert("Caption", isPresented: $showCaptionEditor) {
                TextField("Caption", text: $captionDraft)
                Button("Save") { library.setCaption(captionDraft, for: entry.url) }
                Button("Cancel", role: .cancel) {}
            }
        }
        .presentationDetents([.medium, .large])
        // Load the three sources concurrently and each time-boxed, so one slow read
        // (a huge photo, a damaged video, a stalled xattr on an external drive)
        // can't delay the others or hang the panel.
        .task(id: entry.id) {
            // Core metadata first, then paint it before anything riskier runs.
            let loaded = await MetadataLoader.load(for: entry)
            info = loaded
            await Task.yield()
            // Caption + "saved from" are independent and time-boxed.
            async let captionTask = MetadataLoader.timeBoxedCaption(for: entry)
            async let sourceTask = MetadataLoader.timeBoxedSource(url: entry.url)
            fileCaption = await captionTask
            savedFrom = await sourceTask
            // Reverse-geocoding is the one read documented to crash uncatchably on
            // bad GPS data and it needs the network — so it runs dead last, after
            // every other field is already on screen.
            if let coord = loaded.coordinate {
                placeName = await MetadataLoader.placeName(for: coord)
            }
        }
    }

    private func row(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(key).foregroundStyle(.secondary)
            Spacer(minLength: 16)
            Text(value).multilineTextAlignment(.trailing)
        }
    }
}
