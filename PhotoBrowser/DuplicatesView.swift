import SwiftUI

/// Finds likely-duplicate photos/videos in a single folder and lets the user
/// compare and prune them.
///
/// Two files are grouped when they share the same **file size** and the same
/// **pixel dimensions** (long side + total pixels, which together fix W×H). If
/// two also share a **filename** it's flagged a *perfect* match; otherwise it's
/// a probable match with a different name. The comparison screen shows the two
/// items side-by-side with a same/different metadata breakdown, an inline
/// metadata editor, and a per-side delete.
///
/// The scan is **non-recursive** (the chosen folder only). Dimension reads go
/// through `Library.mediaSpecs` (cached, bounded concurrency, off the main
/// actor) so a big folder on a slow external drive doesn't stall the UI.
struct DuplicatesView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let folder: URL

    @State private var groups: [DuplicateGroup] = []
    @State private var scanning = true

    var body: some View {
        NavigationStack {
            Group {
                if scanning {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Scanning for duplicates…").foregroundStyle(.secondary)
                    }
                } else if groups.isEmpty {
                    ContentUnavailableView("No Duplicates", systemImage: "checkmark.circle",
                        description: Text("No files in this folder share the same size and dimensions."))
                } else {
                    List {
                        Section {
                            ForEach(groups) { group in
                                NavigationLink {
                                    DuplicateCompareView(group: group) { removed in remove(removed, from: group) }
                                } label: {
                                    DuplicateGroupRow(group: group)
                                }
                            }
                        } footer: {
                            Text("Files grouped by matching size and dimensions. Tap a group to compare.")
                        }
                    }
                }
            }
            .navigationTitle("Find Duplicates")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .task { await scan() }
        }
    }

    private func scan() async {
        scanning = true
        let media = await library.listing(of: folder, sort: .nameAsc).filter { $0.isViewable }
        let specs = await library.mediaSpecs(for: media)
        var buckets: [String: [Entry]] = [:]
        for e in media {
            guard let spec = specs[e.url], spec.pixels > 0 else { continue }   // skip unreadable
            buckets["\(e.size)|\(spec.longSide)|\(spec.pixels)", default: []].append(e)
        }
        var result: [DuplicateGroup] = []
        for items in buckets.values where items.count > 1 {
            let sorted = items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            let spec = specs[sorted[0].url] ?? MediaSpec()
            result.append(DuplicateGroup(entries: sorted, size: sorted[0].size,
                                         longSide: spec.longSide, pixels: spec.pixels))
        }
        groups = result.sorted { $0.size > $1.size }   // biggest payoff first
        scanning = false
    }

    private func remove(_ url: URL, from group: DuplicateGroup) {
        guard let gi = groups.firstIndex(where: { $0.id == group.id }) else { return }
        groups[gi].entries.removeAll { $0.url == url }
        if groups[gi].entries.count < 2 { groups.remove(at: gi) }   // no longer a duplicate
    }
}

/// A set of files in one folder that share size + dimensions.
struct DuplicateGroup: Identifiable {
    let id = UUID()
    var entries: [Entry]
    let size: Int64
    let longSide: Int
    let pixels: Int

    /// "W × H" derived from the long side and total pixels (orientation-agnostic).
    var dimensionLabel: String {
        guard longSide > 0 else { return "—" }
        return "\(longSide) × \(pixels / longSide)"
    }

    /// Two items sharing a filename means an exact (size + dimensions + name) match.
    var hasPerfectMatch: Bool {
        let names = entries.map { $0.name.lowercased() }
        return Set(names).count < names.count
    }
}

/// One row in the duplicate-groups list: a couple of thumbnails plus a summary.
private struct DuplicateGroupRow: View {
    let group: DuplicateGroup
    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                ForEach(group.entries.prefix(2)) { DuplicateThumb(entry: $0, side: 52) }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("\(group.entries.count) matching files").font(.subheadline.weight(.medium))
                Text("\(group.size.sizeString) · \(group.dimensionLabel)")
                    .font(.caption).foregroundStyle(.secondary)
                Label(group.hasPerfectMatch ? "Perfect match" : "Same size & dimensions",
                      systemImage: group.hasPerfectMatch ? "checkmark.seal.fill" : "rectangle.on.rectangle")
                    .font(.caption2)
                    .foregroundStyle(group.hasPerfectMatch ? Color.green : Color.orange)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Small cached thumbnail used in the list and column headers.
private struct DuplicateThumb: View {
    let entry: Entry
    var side: CGFloat
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Rectangle().fill(.quaternary)
                    .overlay { Image(systemName: entry.kind.systemImage).foregroundStyle(.secondary) }
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: entry.id) {
            image = await Thumbnailer.shared.thumbnail(
                for: entry, size: CGSize(width: side, height: side), scale: UIScreen.main.scale)
        }
    }
}

/// Side-by-side comparison of two items in a duplicate group, with a
/// same/different metadata breakdown, inline metadata editing, and delete.
private struct DuplicateCompareView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let group: DuplicateGroup
    var onDelete: (URL) -> Void

    @State private var leftIndex = 0
    @State private var rightIndex = 1
    @State private var leftInfo: MediaInfo?
    @State private var rightInfo: MediaInfo?
    @State private var editURL: URLBox?
    @State private var confirmDelete: Entry?
    /// Bumped after an edit to force the metadata to reload.
    @State private var reloadToken = 0

    private var entries: [Entry] { group.entries }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                if entries.count > 2 { pairPicker }

                HStack(alignment: .top, spacing: 12) {
                    column(index: leftIndex)
                    column(index: rightIndex)
                }

                legend
                comparison
            }
            .padding()
        }
        .navigationTitle("Compare")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editURL, onDismiss: { reloadToken += 1 }) { wrapper in
            MetadataEditorView(urls: [wrapper.url])
        }
        .confirmationDialog("Delete this file? This permanently removes it from the drive.",
                            isPresented: Binding(get: { confirmDelete != nil },
                                                 set: { if !$0 { confirmDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) { if let e = confirmDelete { delete(e) } }
            Button("Cancel", role: .cancel) { confirmDelete = nil }
        }
        .task(id: "left-\(leftIndex)-\(reloadToken)") { leftInfo = await MetadataLoader.load(for: entries[leftIndex]) }
        .task(id: "right-\(rightIndex)-\(reloadToken)") { rightInfo = await MetadataLoader.load(for: entries[rightIndex]) }
    }

    // MARK: - Pieces

    /// When a group has more than two items, choose which two to compare.
    private var pairPicker: some View {
        HStack {
            Picker("Left", selection: $leftIndex) {
                ForEach(entries.indices, id: \.self) { Text(entries[$0].name).tag($0) }
            }
            Image(systemName: "arrow.left.arrow.right").foregroundStyle(.secondary)
            Picker("Right", selection: $rightIndex) {
                ForEach(entries.indices, id: \.self) { Text(entries[$0].name).tag($0) }
            }
        }
        .font(.caption)
    }

    private func column(index: Int) -> some View {
        let entry = entries[index]
        return VStack(spacing: 8) {
            DuplicateThumb(entry: entry, side: 150)
            Text(entry.name).font(.caption).lineLimit(2).multilineTextAlignment(.center)
            HStack(spacing: 10) {
                Button { editURL = URLBox(url: entry.url) } label: {
                    Label("Edit", systemImage: "pencil").labelStyle(.iconOnly)
                }
                Button(role: .destructive) { confirmDelete = entry } label: {
                    Label("Delete", systemImage: "trash").labelStyle(.iconOnly)
                }
            }
            .font(.title3)
        }
        .frame(maxWidth: .infinity)
    }

    private var legend: some View {
        HStack(spacing: 16) {
            Label("Same", systemImage: "circle.fill").foregroundStyle(.green)
            Label("Different", systemImage: "circle.fill").foregroundStyle(.orange)
        }
        .font(.caption2)
        .labelStyle(DotLabelStyle())
    }

    private var comparison: some View {
        VStack(spacing: 6) {
            ForEach(rows()) { r in
                let same = r.left == r.right
                VStack(spacing: 2) {
                    Text(r.label).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(alignment: .top) {
                        Text(r.left).frame(maxWidth: .infinity, alignment: .leading)
                        Text(r.right).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.caption)
                }
                .padding(8)
                .background((same ? Color.green : Color.orange).opacity(0.15),
                            in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    // MARK: - Data

    private func rows() -> [CompareRow] {
        let l = entries[leftIndex], r = entries[rightIndex]
        func date(_ i: MediaInfo?) -> String { i?.date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—" }
        func place(_ i: MediaInfo?) -> String {
            if let p = i?.placeName { return p }
            if let c = i?.coordinate { return String(format: "%.4f, %.4f", c.latitude, c.longitude) }
            return "—"
        }
        return [
            CompareRow(label: "Name", left: l.name, right: r.name),
            CompareRow(label: "Size", left: l.size.sizeString, right: r.size.sizeString),
            CompareRow(label: "Dimensions", left: leftInfo?.dimensions ?? group.dimensionLabel,
                       right: rightInfo?.dimensions ?? group.dimensionLabel),
            CompareRow(label: "Date", left: date(leftInfo), right: date(rightInfo)),
            CompareRow(label: "Device", left: leftInfo?.device ?? "—", right: rightInfo?.device ?? "—"),
            CompareRow(label: "Location", left: place(leftInfo), right: place(rightInfo)),
        ]
    }

    private func delete(_ entry: Entry) {
        FileActions.delete([entry])
        library.clearOrigins([entry.url])
        library.clearLabels([entry.url])
        library.contentDidChange()
        confirmDelete = nil
        onDelete(entry.url)
        dismiss()
    }
}

/// One attribute compared across the two files.
private struct CompareRow: Identifiable {
    let label: String
    let left: String
    let right: String
    var id: String { label }
}

/// `URL` isn't `Identifiable`; this wraps it for `.sheet(item:)`.
private struct URLBox: Identifiable { let url: URL; var id: URL { url } }

/// Shows just the dot (no text) for the comparison legend.
private struct DotLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) { configuration.icon.font(.system(size: 8)); configuration.title }
    }
}
