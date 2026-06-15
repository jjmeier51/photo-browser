import SwiftUI

/// A "People" library, like Photos' People — but the grouping is approximate
/// (Apple exposes no on-device face-identity API, so faces are clustered by
/// image feature-print similarity). "Find People" scans the folder; the user
/// renames, merges, and deletes to correct the groups.
struct PeopleView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let folder: URL

    @State private var scanning = false
    @State private var progress = 0.0

    private var sortedPeople: [String] {
        library.people.keys.sorted {
            let a = library.people[$0]?.count ?? 0, b = library.people[$1]?.count ?? 0
            return a != b ? a > b : $0.localizedStandardCompare($1) == .orderedAscending
        }
    }
    private let columns = [GridItem(.adaptive(minimum: 108), spacing: 14)]

    var body: some View {
        NavigationStack {
            Group {
                if library.people.isEmpty {
                    ContentUnavailableView {
                        Label("No People Yet", systemImage: "person.crop.circle")
                    } description: {
                        Text("Scan this folder to find faces and group them into people. Grouping is approximate — rename and merge to tidy it up.")
                    } actions: {
                        Button("Find People") { scan() }.buttonStyle(.borderedProminent)
                    }
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 16) {
                            ForEach(sortedPeople, id: \.self) { name in
                                NavigationLink {
                                    PersonDetailView(folder: folder, name: name)
                                } label: {
                                    PersonTile(name: name, faceID: library.people[name]?.first,
                                               count: library.people[name]?.count ?? 0)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("People")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() }.disabled(scanning) }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(library.people.isEmpty ? "Find People" : "Rescan") { scan() }.disabled(scanning)
                }
            }
            .overlay { if scanning { scanOverlay } }
        }
    }

    private var scanOverlay: some View {
        VStack(spacing: 12) {
            Text("Finding people…").font(.subheadline.weight(.medium))
            ProgressView(value: progress).progressViewStyle(.linear).frame(width: 220)
            Text("\(Int(progress * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Text("Detecting and grouping faces. Grouping is approximate.")
                .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(24).frame(maxWidth: 280)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func scan() {
        scanning = true; progress = 0
        let bg = BackgroundTaskHolder()
        bg.begin(name: "Find People")
        Task {
            let result = await library.findPeople(under: folder, existing: library.people) { done, tot in
                Task { @MainActor in progress = tot > 0 ? Double(done) / Double(tot) : 1 }
            }
            library.setPeople(result)
            scanning = false
            bg.end()
        }
    }
}

/// A circular face crop + name + count for the People grid.
private struct PersonTile: View {
    @Environment(Library.self) private var library
    let name: String
    let faceID: String?
    let count: Int
    @State private var image: UIImage?

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().fill(Color(white: 0.15))
                if let image { Image(uiImage: image).resizable().scaledToFill() }
                else { Image(systemName: "person.fill").font(.largeTitle).foregroundStyle(.secondary) }
            }
            .frame(width: 96, height: 96).clipShape(Circle())
            Text(name).font(.subheadline.weight(.medium)).lineLimit(1)
            Text("\(count) photo\(count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
        }
        .task(id: faceID) {
            guard let faceID, let (path, rect) = library.faceRect(for: faceID) else { return }
            image = await FaceAnalysis.faceCrop(path: path, rect: rect)
        }
    }
}

/// One person's photos, with rename / merge / delete.
private struct PersonDetailView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let folder: URL
    let name: String

    @State private var entries: [Entry] = []
    @State private var viewerStart: Int?
    @State private var renaming = false
    @State private var renameText = ""
    @State private var merging = false

    private let columns = [GridItem(.adaptive(minimum: 90), spacing: 4)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { i, e in
                    EntryCell(entry: e).onTapGesture { viewerStart = i }
                }
            }
            .padding(4)
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { renameText = name; renaming = true } label: { Label("Rename", systemImage: "pencil") }
                    if otherPeople.isEmpty == false {
                        Button { merging = true } label: { Label("Merge into…", systemImage: "arrow.triangle.merge") }
                    }
                    Button(role: .destructive) { library.deletePerson(name); dismiss() } label: {
                        Label("Remove Person", systemImage: "trash")
                    }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .alert("Rename Person", isPresented: $renaming) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Save") { library.renamePerson(name, to: renameText); if renameText != name { dismiss() } }
        }
        .confirmationDialog("Merge \(name) into…", isPresented: $merging, titleVisibility: .visible) {
            ForEach(otherPeople, id: \.self) { target in
                Button(target) { library.mergePeople([name], into: target); dismiss() }
            }
        }
        .fullScreenCover(item: Binding(get: { viewerStart.map(IndexBox.init) }, set: { viewerStart = $0?.id })) { box in
            ViewerView(items: entries, startIndex: box.id)
        }
        .task(id: library.labelsVersion) { await load() }
    }

    private var otherPeople: [String] { library.people.keys.filter { $0 != name }.sorted() }

    private func load() async {
        guard library.people[name] != nil else { return }
        entries = await library.labeledEntries(under: library.rootURL ?? folder,
                                                paths: library.photoPaths(forPerson: name), sort: library.sort)
    }
}

private struct IndexBox: Identifiable { let id: Int }
