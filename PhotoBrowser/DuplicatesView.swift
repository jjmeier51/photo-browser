import SwiftUI
import CoreLocation

/// Finds likely-duplicate photos/videos in a single folder and lets the user
/// compare and prune them.
///
/// Groups are built from **two independent criteria, never chained together**:
/// an *Exact* group is files with identical **size + pixel dimensions** (a
/// near-certain duplicate), and a *Similar name* group is files whose names
/// normalize the same (copies like `name (1)`). Keeping them separate avoids the
/// old failure where union-find chained A↔B (size) and B↔C (name) into one group
/// of unrelated files. An **Exact Matches** filter hides the weaker name-only
/// groups. The comparison screen shows the two items side-by-side with a
/// same/different metadata breakdown, an inline metadata editor, a "Not
/// Duplicates" action, and a per-side delete.
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
    @State private var selection = Set<UUID>()
    @State private var exactOnly = false

    /// The groups currently shown, honoring the Exact-Matches filter.
    private var shownGroups: [DuplicateGroup] {
        exactOnly ? groups.filter { $0.matchKind == .exact } : groups
    }
    private var exactCount: Int { groups.filter { $0.matchKind == .exact }.count }

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
                        description: Text("No files in this folder share the same size & dimensions or a similar name."))
                } else {
                    VStack(spacing: 0) {
                        Picker("Filter", selection: $exactOnly) {
                            Text("All (\(groups.count))").tag(false)
                            Text("Exact Matches (\(exactCount))").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal).padding(.vertical, 8)

                        List(selection: $selection) {
                            Section {
                                ForEach(shownGroups) { group in
                                    NavigationLink {
                                        DuplicateCompareView(group: group) { removed in remove(removed, from: group) }
                                            onNotDuplicates: { markNotDuplicates([group]) }
                                    } label: {
                                        DuplicateGroupRow(group: group)
                                    }
                                    .tag(group.id)
                                }
                            } footer: {
                                Text(exactOnly
                                     ? "Exact matches share identical size and pixel dimensions — almost always true duplicates."
                                     : "“Exact” groups share identical size & dimensions; “Similar name” groups share a copy-style name (like “name (1)”). Tap to compare, or select groups and mark them Not Duplicates.")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Find Duplicates")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { if !groups.isEmpty { EditButton() } }
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .bottomBar) {
                    if !selection.isEmpty {
                        Button("Not Duplicates (\(selection.count))") {
                            markNotDuplicates(groups.filter { selection.contains($0.id) })
                            selection.removeAll()
                        }
                    }
                }
            }
            .task { await scan() }
        }
    }

    /// Records each group's items as confirmed non-duplicates (so they're hidden in
    /// future runs) and removes them from the current list.
    private func markNotDuplicates(_ marked: [DuplicateGroup]) {
        for g in marked { library.markNotDuplicates(g.entries.map { $0.url.path }) }
        let ids = Set(marked.map { $0.id })
        groups.removeAll { ids.contains($0.id) }
    }

    private func scan() async {
        scanning = true
        // All viewable media (images AND videos). Dimensions are only used for the
        // size+dimensions match; the filename match needs none, so videos always count.
        let media = await library.listing(of: folder, sort: .nameAsc).filter { $0.isViewable }
        let specs = await library.mediaSpecs(for: media)

        // Build the two kinds of group SEPARATELY — never chaining across them. The old
        // union-find linked A↔B by size+dimensions and B↔C by name into one component,
        // so A and C landed together despite sharing nothing. Now an "Exact" group is
        // strictly files with identical size+dimensions, and a "Similar name" group is
        // strictly files whose names normalize the same; a file can appear in both.
        var bySizeDims: [String: [Int]] = [:]
        var byName: [String: [Int]] = [:]
        for i in media.indices {
            let name = media[i].name
            // Video-frame screenshots ("Frame.png", "Frame 2.png", "Frame 300.png", …)
            // all share one video's dimensions, so size+dimensions alone would pair
            // different frames. Keep them out of the looser name-based grouping, and
            // only treat them as an *exact* duplicate when the name matches too.
            let isFrame = name.localizedCaseInsensitiveContains("frame")
            if let spec = specs[media[i].url], spec.pixels > 0 {
                let key = "\(media[i].size)|\(spec.longSide)|\(spec.pixels)"
                bySizeDims[isFrame ? "\(key)|\(name.lowercased())" : key, default: []].append(i)
            }
            if !isFrame {
                let nameKey = Self.normalizedBaseName(name)
                if !nameKey.isEmpty { byName[nameKey, default: []].append(i) }
            }
        }

        var result: [DuplicateGroup] = []
        var seenSets = Set<Set<String>>()
        func addGroup(_ indices: [Int], kind: DuplicateMatchKind) {
            guard indices.count > 1 else { return }
            let paths = indices.map { media[$0].url.path }
            if allPairsDismissed(paths) { return }                       // user already confirmed not-dupes
            guard seenSets.insert(Set(paths)).inserted else { return }   // same set already added (prefer Exact)
            let entries = indices.map { media[$0] }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            let rep = entries.max { $0.size < $1.size } ?? entries[0]
            let spec = specs[rep.url] ?? MediaSpec()
            result.append(DuplicateGroup(entries: entries, size: rep.size,
                                         longSide: spec.longSide, pixels: spec.pixels, matchKind: kind))
        }
        for g in bySizeDims.values { addGroup(g, kind: .exact) }         // exact first, so it wins a dedupe tie
        for g in byName.values { addGroup(g, kind: .name) }

        // Exact matches first, then biggest payoff.
        groups = result.sorted {
            $0.matchKind != $1.matchKind ? $0.matchKind == .exact : $0.size > $1.size
        }
        scanning = false
    }

    /// True only if every pair among `paths` was marked Not Duplicates.
    private func allPairsDismissed(_ paths: [String]) -> Bool {
        for i in 0..<paths.count { for j in (i + 1)..<paths.count {
            if !library.areNotDuplicates(paths[i], paths[j]) { return false }
        }}
        return true
    }

    /// A filename reduced to its "stem" so copies match: extension removed, lowercased,
    /// and a trailing copy-suffix stripped — " (1)", " copy"/" copy 2", "-1"/"_1", or a
    /// short trailing " 2". So `0123.jpg`, `0123 (1).jpg`, `0123 2.jpeg` → `0123`.
    static func normalizedBaseName(_ filename: String) -> String {
        var base = (filename as NSString).deletingPathExtension.lowercased()
            .trimmingCharacters(in: .whitespaces)
        let patterns = ["\\s*\\(\\d+\\)$", "\\s+copy(\\s+\\d+)?$", "[-_]\\d{1,2}$", "\\s+\\d{1,2}$"]
        var changed = true
        while changed {
            changed = false
            for p in patterns where base.range(of: p, options: .regularExpression) != nil {
                base.removeSubrange(base.range(of: p, options: .regularExpression)!)
                base = base.trimmingCharacters(in: .whitespaces)
                changed = true
            }
        }
        return base
    }

    private func remove(_ url: URL, from group: DuplicateGroup) {
        guard let gi = groups.firstIndex(where: { $0.id == group.id }) else { return }
        groups[gi].entries.removeAll { $0.url == url }
        if groups[gi].entries.count < 2 { groups.remove(at: gi) }   // no longer a duplicate
    }
}

/// Why a group was formed: identical size **and** pixel dimensions (a near-certain
/// duplicate), or just a similar/copy name (a weaker signal).
enum DuplicateMatchKind { case exact, name }

/// A set of files in one folder that share size + dimensions, or a similar (copy) name.
struct DuplicateGroup: Identifiable {
    let id = UUID()
    var entries: [Entry]
    let size: Int64
    let longSide: Int
    let pixels: Int
    var matchKind: DuplicateMatchKind = .exact

    /// "W × H" derived from the long side and total pixels (orientation-agnostic).
    var dimensionLabel: String {
        guard longSide > 0 else { return "—" }
        return "\(longSide) × \(pixels / longSide)"
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
                Text("\(group.entries.count) \(group.matchKind == .exact ? "exact" : "similarly-named") files")
                    .font(.subheadline.weight(.medium))
                Text("\(group.size.sizeString) · \(group.dimensionLabel)")
                    .font(.caption).foregroundStyle(.secondary)
                Label(group.matchKind == .exact ? "Exact match (size & dimensions)" : "Similar name",
                      systemImage: group.matchKind == .exact ? "checkmark.seal.fill" : "textformat.abc")
                    .font(.caption2)
                    .foregroundStyle(group.matchKind == .exact ? Color.green : Color.orange)
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
/// same/different metadata breakdown, full per-file editing (rename, EXIF date &
/// location, caption, Favorite / To AI / Taylor Swift labels), and delete.
private struct DuplicateCompareView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let group: DuplicateGroup
    var onDelete: (URL) -> Void
    var onNotDuplicates: () -> Void = {}

    /// A mutable copy of the group's items so a rename (which changes a URL) is
    /// reflected immediately in the previews, comparison, and later edits.
    @State private var items: [Entry]
    @State private var leftIndex = 0
    @State private var rightIndex = 1
    @State private var leftInfo: MediaInfo?
    @State private var rightInfo: MediaInfo?
    @State private var editURL: URLBox?
    @State private var renameTarget: Entry?
    @State private var renameDraft = ""
    @State private var captionTarget: URLBox?
    @State private var captionDraft = ""
    @State private var confirmDelete: Entry?
    /// Bumped after an edit to force the metadata to reload.
    @State private var reloadToken = 0

    init(group: DuplicateGroup, onDelete: @escaping (URL) -> Void, onNotDuplicates: @escaping () -> Void = {}) {
        self.group = group
        self.onDelete = onDelete
        self.onNotDuplicates = onNotDuplicates
        _items = State(initialValue: group.entries)
    }

    private var entries: [Entry] { items }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                // Guarded so the one transient frame after deleting down to a
                // single item (just before this view pops) can't index out of range.
                if entries.count >= 2 {
                    if entries.count > 2 { pairPicker }

                    HStack(alignment: .top, spacing: 12) {
                        column(index: leftIndex)
                        column(index: rightIndex)
                    }

                    legend
                    comparison

                    Button { onNotDuplicates(); dismiss() } label: {
                        Label("Not Duplicates", systemImage: "checkmark.circle")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                            .background(Color.green.opacity(0.2), in: RoundedRectangle(cornerRadius: 10))
                    }
                    .tint(.green).padding(.top, 4)
                }
            }
            .padding()
        }
        .navigationTitle("Compare")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { onNotDuplicates(); dismiss() } label: { Label("Not Duplicates", systemImage: "checkmark.circle") }
            }
        }
        .sheet(item: $editURL, onDismiss: { reloadToken += 1 }) { wrapper in
            MetadataEditorView(urls: [wrapper.url])
        }
        .alert("Rename File", isPresented: Binding(get: { renameTarget != nil },
                                                   set: { if !$0 { renameTarget = nil } })) {
            TextField("Name", text: $renameDraft)
            Button("Rename") { performRename() }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
        .alert("Caption", isPresented: Binding(get: { captionTarget != nil },
                                               set: { if !$0 { captionTarget = nil } })) {
            TextField("Caption", text: $captionDraft)
            Button("Save") { if let t = captionTarget { library.setCaption(captionDraft, for: t.url) }; captionTarget = nil }
            Button("Cancel", role: .cancel) { captionTarget = nil }
        }
        .confirmationDialog("Delete this file? This permanently removes it from the drive.",
                            isPresented: Binding(get: { confirmDelete != nil },
                                                 set: { if !$0 { confirmDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) { if let e = confirmDelete { delete(e) } }
            Button("Cancel", role: .cancel) { confirmDelete = nil }
        }
        .task(id: "left-\(entries[safe: leftIndex]?.url.path ?? "")-\(reloadToken)") {
            if let e = entries[safe: leftIndex] { leftInfo = await MetadataLoader.load(for: e) }
        }
        .task(id: "right-\(entries[safe: rightIndex]?.url.path ?? "")-\(reloadToken)") {
            if let e = entries[safe: rightIndex] { rightInfo = await MetadataLoader.load(for: e) }
        }
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
            Menu {
                Button { renameTarget = entry; renameDraft = entry.name } label: {
                    Label("Rename…", systemImage: "character.cursor.ibeam")
                }
                Button { editURL = URLBox(url: entry.url) } label: {
                    Label("Edit Date & Location…", systemImage: "calendar.badge.clock")
                }
                Button { captionTarget = URLBox(url: entry.url); captionDraft = library.captions[entry.url.path] ?? "" } label: {
                    Label("Caption…", systemImage: "text.bubble")
                }
                Divider()
                Button { library.toggleFavorite(entry.url) } label: {
                    Label(library.isFavorite(entry.url) ? "Unfavorite" : "Favorite",
                          systemImage: library.isFavorite(entry.url) ? "heart.slash" : "heart")
                }
                Button { library.toggleAI(entry.url) } label: {
                    Label(library.isAI(entry.url) ? "Remove To AI" : "To AI", systemImage: "sparkles")
                }
                if entry.url.pathComponents.contains("Taylor Swift") {
                    Menu {
                        ForEach(Library.taylorSwiftLabels, id: \.self) { name in
                            Button { library.toggleLabel(name, on: entry.url) } label: {
                                if library.hasLabel(name, entry.url) { Label(name, systemImage: "checkmark") }
                                else { Text(name) }
                            }
                        }
                    } label: { Label("Taylor Swift Labels", systemImage: "tag") }
                }
            } label: {
                Label("Edit", systemImage: "slider.horizontal.3")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(.thinMaterial, in: Capsule())
            }
            Button(role: .destructive) { confirmDelete = entry } label: {
                Label("Delete", systemImage: "trash")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(.thinMaterial, in: Capsule())
            }
            .tint(.red)
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
        func caption(_ e: Entry) -> String {
            let c = library.captions[e.url.path] ?? ""
            return c.isEmpty ? "—" : c
        }
        func labelList(_ url: URL) -> String {
            let names = (library.isFavorite(url) ? ["Favorite"] : [])
                + (library.isAI(url) ? ["To AI"] : [])
                + Library.taylorSwiftLabels.filter { library.hasLabel($0, url) }
            return names.isEmpty ? "—" : names.joined(separator: ", ")
        }
        return [
            CompareRow(label: "Name", left: l.name, right: r.name),
            CompareRow(label: "Size", left: l.size.sizeString, right: r.size.sizeString),
            CompareRow(label: "Dimensions", left: leftInfo?.dimensions ?? group.dimensionLabel,
                       right: rightInfo?.dimensions ?? group.dimensionLabel),
            CompareRow(label: "Date", left: date(leftInfo), right: date(rightInfo)),
            CompareRow(label: "Device", left: leftInfo?.device ?? "—", right: rightInfo?.device ?? "—"),
            CompareRow(label: "Location", left: place(leftInfo), right: place(rightInfo)),
            CompareRow(label: "Caption", left: caption(l), right: caption(r)),
            CompareRow(label: "Labels", left: labelList(l.url), right: labelList(r.url)),
        ]
    }

    /// Renames the file in place, re-keying its labels/caption, and updates the
    /// local copy so the rest of the screen tracks the new URL.
    private func performRename() {
        defer { renameTarget = nil }
        guard let target = renameTarget,
              let idx = items.firstIndex(where: { $0.url == target.url }),
              let newURL = FileActions.rename(target.url, to: renameDraft) else { return }
        library.itemMoved(from: target.url, to: newURL)
        let old = items[idx]
        items[idx] = Entry(url: newURL, name: newURL.lastPathComponent,
                           kind: old.kind, size: old.size, modified: old.modified)
        library.contentDidChange()
        reloadToken += 1
    }

    private func delete(_ entry: Entry) {
        FileActions.delete([entry])
        library.clearOrigins([entry.url])
        library.clearLabels([entry.url])
        library.contentDidChange()
        confirmDelete = nil
        onDelete(entry.url)
        if let idx = items.firstIndex(where: { $0.url == entry.url }) { items.remove(at: idx) }
        guard items.count >= 2 else { dismiss(); return }   // no longer a duplicate
        leftIndex = min(leftIndex, items.count - 1)
        rightIndex = min(rightIndex, items.count - 1)
        if leftIndex == rightIndex { rightIndex = leftIndex == 0 ? 1 : 0 }
        reloadToken += 1
    }
}

private extension Array {
    /// Bounds-checked subscript — returns nil instead of trapping, so a `.task`
    /// id can reference an index that may have just shrunk after a delete.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
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
