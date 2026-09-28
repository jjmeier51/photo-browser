import SwiftUI
import CoreLocation
import CryptoKit

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
///
/// **Deleting is per file, never "keep the largest":** every group row shows each of its files as
/// a tile; the user ticks the exact copies to remove and deletes them together (one file in every
/// group is always kept). **Results are remembered** (`DuplicateScanCache`): reopening the screen
/// shows the last scan instantly, deletions / renames / Not-Duplicates update the saved result in
/// place, and a full rescan only happens when files were added or changed, or on Rescan.
struct DuplicatesView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let folder: URL

    @State private var groups: [DuplicateGroup] = []
    @State private var scanning = true
    @State private var loaded = false                    // `.task` guard: never rescan on a re-appear
    @State private var scannedAt: Date?
    @State private var fingerprint: [String: String] = [:]   // path → "size|mtime" of every file the result covers
    @State private var selectedFiles = Set<URL>()         // files ticked for deletion
    @State private var exactOnly = false
    @State private var confirmDelete = false
    @State private var compareGroup: DuplicateGroup?
    /// Capture dates (EXIF, falling back to the file date) for every file in the result — drives
    /// the Older / Newer markers on the tiles. Loaded once per result from the per-file cache.
    @State private var captureDates: [URL: Date] = [:]
    /// Leave out files with "Frame" in the name (video-frame screenshots): a folder full of frames
    /// from one video is hundreds of visually similar images that are never duplicates.
    @AppStorage("photoBrowser.duplicatesExcludeFrames") private var excludeFrames = false

    /// The groups currently shown, honoring the Exact-Matches filter and the Frame exclusion.
    private var shownGroups: [DuplicateGroup] {
        let base = exactOnly ? groups.filter { $0.matchKind == .exact } : groups
        return excludeFrames ? Self.withoutFrames(base) : base
    }
    private var visibleGroups: [DuplicateGroup] { excludeFrames ? Self.withoutFrames(groups) : groups }
    private var exactCount: Int { visibleGroups.filter { $0.matchKind == .exact }.count }

    static func isFrameFile(_ e: Entry) -> Bool { e.name.localizedCaseInsensitiveContains("frame") }
    /// Groups with the Frame files taken out; a group left with one file is no longer a duplicate.
    static func withoutFrames(_ groups: [DuplicateGroup]) -> [DuplicateGroup] {
        groups.compactMap { g in
            var copy = g
            copy.entries.removeAll(where: isFrameFile)
            return copy.entries.count > 1 ? copy : nil
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if scanning {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Scanning for duplicates…").foregroundStyle(.secondary)
                    }
                } else if visibleGroups.isEmpty {
                    ContentUnavailableView {
                        Label("No Duplicates", systemImage: "checkmark.circle")
                    } description: {
                        Text(excludeFrames && !groups.isEmpty
                             ? "Every group found here only involves “Frame” files, which are being left out."
                             : "No files here share the same size & dimensions, look visually alike, or share a copy-style name.")
                    } actions: {
                        if excludeFrames && !groups.isEmpty {
                            Button("Include Frame Files") { excludeFrames = false }.buttonStyle(.bordered)
                        }
                        Button("Rescan") { Task { await load(force: true) } }.buttonStyle(.bordered)
                    }
                } else {
                    VStack(spacing: 0) {
                        Picker("Filter", selection: $exactOnly) {
                            Text("All (\(visibleGroups.count))").tag(false)
                            Text("Exact Matches (\(exactCount))").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal).padding(.top, 8)
                        Toggle(isOn: $excludeFrames) {
                            Label("Leave out “Frame” files", systemImage: "film")
                                .font(.subheadline)
                        }
                        .tint(.accentColor)
                        .padding(.horizontal).padding(.vertical, 6)

                        List {
                            Section {
                                ForEach(shownGroups) { group in
                                    DuplicateGroupRow(group: group, selectedFiles: $selectedFiles,
                                                      dates: dates(for: group),
                                                      onToggle: { toggle($0, in: group) },
                                                      onCompare: { compareGroup = group })
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        Button { markNotDuplicates([group]) } label: {
                                            Label("Not Duplicates", systemImage: "checkmark.circle")
                                        }
                                        .tint(.green)
                                    }
                                    .contextMenu {
                                        Button { compareGroup = group } label: { Label("Compare", systemImage: "rectangle.split.2x1") }
                                        Button { markNotDuplicates([group]) } label: { Label("Not Duplicates", systemImage: "checkmark.circle") }
                                    }
                                }
                            } header: {
                                if let scannedAt {
                                    Text("Results from \(scannedAt.formatted(.relative(presentation: .named))) · tap ↻ to rescan")
                                }
                            } footer: {
                                Text(exactOnly
                                     ? "Exact matches share identical size and pixel dimensions — almost always true duplicates. Tap the copies you don't want, then Delete Selected; one file in each group is always kept. When capture dates differ, the oldest and newest copies are marked."
                                     : "“Exact” = identical size & dimensions; “Visually similar” = the same picture re-encoded/resized/lightly edited; “Similar name” = a copy-style name (like “name (1)”). Tap the copies you don't want, then Delete Selected — one file in each group is always kept. When capture dates differ, the oldest and newest copies are marked. Swipe a group to mark it Not Duplicates; › compares the files side by side.")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Find Duplicates")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(item: $compareGroup) { group in
                DuplicateCompareView(group: group,
                                     onDelete: { removed in remove(removed, from: group) },
                                     onRename: { old, new in renamed(old, to: new, in: group) },
                                     onNotDuplicates: { markNotDuplicates([group]) })
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { Task { await load(force: true) } } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(scanning)
                        .accessibilityLabel("Rescan")
                }
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
                ToolbarItemGroup(placement: .bottomBar) {
                    if !selectedFiles.isEmpty {
                        Button("Clear Selection") { selectedFiles.removeAll() }
                        Spacer()
                        Button(role: .destructive) { confirmDelete = true } label: {
                            Text("Delete Selected (\(selectedFiles.count))")
                        }
                    }
                }
            }
            .confirmationDialog("Delete \(selectedFiles.count) file\(selectedFiles.count == 1 ? "" : "s")? This permanently removes the copies you ticked from the drive.",
                                isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete \(selectedFiles.count)", role: .destructive) { deleteSelectedFiles() }
                Button("Cancel", role: .cancel) {}
            }
            .task(id: folder) { await load(force: false) }
            // Turning the Frame exclusion OFF may need files the last scan skipped: reload, which
            // rescans only if the remembered result doesn't cover them. Turning it ON is just a
            // display filter.
            .onChange(of: excludeFrames) { _, isOn in if !isOn { Task { await load(force: false, reloadOnly: true) } } }
        }
    }

    // MARK: - Dates (Older / Newer markers)

    /// Each file's date for the markers: EXIF capture date, else the file's modified date.
    private func dates(for group: DuplicateGroup) -> [URL: Date] {
        var out: [URL: Date] = [:]
        for e in group.entries { out[e.url] = captureDates[e.url] ?? e.modified }
        return out
    }

    private func loadCaptureDates() async {
        let all = groups.flatMap { $0.entries }
        guard !all.isEmpty else { captureDates = [:]; return }
        captureDates = await library.captureDates(for: all)
    }

    // MARK: - Selection

    /// Ticks/unticks one file for deletion. The last unticked file of a group can't be ticked —
    /// something always stays.
    private func toggle(_ url: URL, in group: DuplicateGroup) {
        if selectedFiles.contains(url) { selectedFiles.remove(url); return }
        let othersAllTicked = group.entries.filter { $0.url != url }.allSatisfy { selectedFiles.contains($0.url) }
        guard !othersAllTicked else { return }
        selectedFiles.insert(url)
    }

    /// Deletes exactly the ticked files (a file that sits in two groups is deleted once), then
    /// trims the groups and updates the remembered result.
    private func deleteSelectedFiles() {
        let urls = selectedFiles
        var seen = Set<URL>()
        let targets = groups.flatMap { $0.entries }.filter { urls.contains($0.url) && seen.insert($0.url).inserted }
        guard !targets.isEmpty else { return }
        FileActions.delete(targets)
        for e in targets { library.clearOrigins([e.url]); library.clearLabels([e.url]) }
        library.contentDidChange(under: folder)
        for i in groups.indices.reversed() {
            groups[i].entries.removeAll { urls.contains($0.url) }
            if groups[i].entries.count < 2 { groups.remove(at: i) }   // no longer a duplicate
        }
        for u in urls { fingerprint.removeValue(forKey: u.path) }
        selectedFiles.removeAll()
        persist()
    }

    /// Records each group's items as confirmed non-duplicates (so they're hidden in
    /// future runs) and removes them from the current list.
    private func markNotDuplicates(_ marked: [DuplicateGroup]) {
        for g in marked { library.markNotDuplicates(g.entries.map { $0.url.path }) }
        let ids = Set(marked.map { $0.id })
        groups.removeAll { ids.contains($0.id) }
        for g in marked { for e in g.entries { selectedFiles.remove(e.url) } }
        persist()
    }

    /// A file renamed from the Compare screen keeps its place in every group (and in the
    /// remembered result) under its new name, instead of counting as a removed + added file that
    /// would force a rescan next time.
    private func renamed(_ old: URL, to new: Entry, in group: DuplicateGroup) {
        for i in groups.indices {
            if let j = groups[i].entries.firstIndex(where: { $0.url == old }) { groups[i].entries[j] = new }
        }
        if let v = fingerprint.removeValue(forKey: old.path) { fingerprint[new.url.path] = v }
        if selectedFiles.remove(old) != nil { selectedFiles.insert(new.url) }
        persist()
    }

    // MARK: - Loading (remembered result first, full scan only when needed)

    /// `reloadOnly` re-checks the remembered result against the folder (used when the Frame
    /// exclusion is switched off) without the "already loaded" short-circuit.
    private func load(force: Bool, reloadOnly: Bool = false) async {
        if loaded && !force && !reloadOnly { return }
        loaded = true
        scanning = true
        // All viewable media (images AND videos). Dimensions are only used for the
        // size+dimensions match; the filename match needs none, so videos always count.
        // With the Frame exclusion on, frame files are left out of the scan itself — they are
        // the bulk of the hashing work in a screenshot-heavy folder and never true duplicates.
        var media = await library.listing(of: folder, sort: .nameAsc).filter { $0.isViewable }
        if excludeFrames { media.removeAll(where: Self.isFrameFile) }
        let current = DuplicateScanCache.fingerprint(media)

        if !force, let record = await DuplicateScanCache.load(folder: folder) {
            // Files that vanished (deleted/moved elsewhere) just drop out of their groups; only a
            // file that is NEW or CHANGED (size/mtime) can create a match we don't know about, and
            // only that forces a rescan.
            let changed = current.contains { path, value in record.files[path] != value }
            if !changed {
                groups = record.rebuild(with: media, dismissed: allPairsDismissed)
                // Keep the record's knowledge of files this pass didn't look at (frames left out),
                // so switching the exclusion back off doesn't read as "new files".
                fingerprint = record.files.merging(current) { _, new in new }
                    .filter { path, _ in current[path] != nil || (excludeFrames && record.files[path] != nil) }
                scannedAt = Date(timeIntervalSince1970: record.scannedAt)
                scanning = false
                await loadCaptureDates()
                persist()          // write back the pruned result
                return
            }
        }

        groups = await fullScan(media: media)
        fingerprint = current
        scannedAt = Date()
        scanning = false
        await loadCaptureDates()
        persist()
    }

    private func persist() {
        let record = DuplicateScanCache.Record(scannedAt: scannedAt?.timeIntervalSince1970 ?? Date().timeIntervalSince1970,
                                               files: fingerprint, groups: groups.map(DuplicateScanCache.StoredGroup.init))
        let folder = folder
        Task.detached(priority: .utility) { DuplicateScanCache.save(record, folder: folder) }
    }

    private func fullScan(media: [Entry]) async -> [DuplicateGroup] {
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
        func addEntries(_ groupEntries: [Entry], kind: DuplicateMatchKind) {
            guard groupEntries.count > 1 else { return }
            let paths = groupEntries.map { $0.url.path }
            if allPairsDismissed(paths) { return }                       // user already confirmed not-dupes
            guard seenSets.insert(Set(paths)).inserted else { return }   // same set already added (prefer stronger kind)
            let entries = groupEntries.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            let rep = entries.max { $0.size < $1.size } ?? entries[0]
            let spec = specs[rep.url] ?? MediaSpec()
            result.append(DuplicateGroup(entries: entries, size: rep.size,
                                         longSide: spec.longSide, pixels: spec.pixels, matchKind: kind))
        }
        for g in bySizeDims.values { addEntries(g.map { media[$0] }, kind: .exact) }   // exact wins a dedupe tie

        // Visually-similar images (perceptual dHash), clustered by Hamming distance. Images only —
        // videos can't be perceptually hashed here. Added AFTER exact so an identical set that also
        // hashes alike stays labelled "exact"; the looser name grouping is added last.
        for g in await similarGroups(among: media) { addEntries(g, kind: .similar) }
        for g in byName.values { addEntries(g.map { media[$0] }, kind: .name) }

        // Strongest kind first (exact → similar → name), then biggest payoff.
        return result.sorted {
            $0.matchKind.rank != $1.matchKind.rank ? $0.matchKind.rank < $1.matchKind.rank : $0.size > $1.size
        }
    }

    /// Clusters images that look the same via a perceptual dHash (Hamming distance ≤ threshold),
    /// using union-find so a run of near-identical shots forms one group. Hashing decodes each image
    /// once at a tiny size, off the main actor with bounded concurrency, so a big folder stays smooth.
    private func similarGroups(among media: [Entry]) async -> [[Entry]] {
        let images = media.filter { $0.kind == .image }
        guard images.count > 1 else { return [] }
        // Hash AND cluster off the main actor — the O(n²) pairwise compare would hitch the UI on a
        // big folder if it ran on the main thread.
        return await Task.detached(priority: .userInitiated) {
            var hashes = [UInt64?](repeating: nil, count: images.count)
            await withTaskGroup(of: (Int, UInt64?).self) { group in
                var idx = 0
                let maxConcurrent = 8
                func addNext() {
                    guard idx < images.count else { return }
                    let i = idx; let url = images[i].url; idx += 1
                    group.addTask { (i, PerceptualHash.dHash(url)) }
                }
                for _ in 0..<min(maxConcurrent, images.count) { addNext() }
                while let (i, h) = await group.next() { hashes[i] = h; addNext() }
            }
            // Union-find over all pairs within a tight Hamming threshold. Kept low (≈ same picture
            // re-encoded/resized/lightly edited) so a whole photoshoot of similar poses doesn't chain
            // into one giant group — 6/64 bits is close without over-clustering.
            var parent = Array(images.indices)
            func find(_ x: Int) -> Int { var r = x; while parent[r] != r { parent[r] = parent[parent[r]]; r = parent[r] }; return r }
            let threshold = 6
            for i in images.indices {
                guard let hi = hashes[i] else { continue }
                for j in (i + 1)..<images.count {
                    guard let hj = hashes[j] else { continue }
                    if PerceptualHash.distance(hi, hj) <= threshold { parent[find(i)] = find(j) }
                }
            }
            var clusters: [Int: [Entry]] = [:]
            for i in images.indices where hashes[i] != nil { clusters[find(i), default: []].append(images[i]) }
            return clusters.values.filter { $0.count > 1 }
        }.value
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

    /// A file deleted from the Compare screen leaves every group it was in (a file can sit in an
    /// exact group and a name group at once) and the remembered result.
    private func remove(_ url: URL, from group: DuplicateGroup) {
        for i in groups.indices.reversed() {
            groups[i].entries.removeAll { $0.url == url }
            if groups[i].entries.count < 2 { groups.remove(at: i) }   // no longer a duplicate
        }
        fingerprint.removeValue(forKey: url.path)
        selectedFiles.remove(url)
        persist()
    }
}

/// Why a group was formed: identical size **and** pixel dimensions (a near-certain
/// duplicate), a **visually** matching picture (perceptual hash — catches re-encodes,
/// resizes and light edits), or just a similar/copy name (a weaker signal).
enum DuplicateMatchKind: Int, Hashable, Codable { case exact = 0, similar = 1, name = 2
    /// Sort/display rank: exact first, then visual, then name-only.
    var rank: Int { rawValue }
}

/// A set of files in one folder that share size + dimensions, or a similar (copy) name.
struct DuplicateGroup: Identifiable, Hashable {
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

    var kindNoun: String {
        switch matchKind { case .exact: return "exact"; case .similar: return "visually similar"; case .name: return "similarly-named" }
    }
    var kindLabel: String {
        switch matchKind {
        case .exact: return "Exact match (size & dimensions)"
        case .similar: return "Visually similar (same picture)"
        case .name: return "Similar name"
        }
    }
    var kindIcon: String {
        switch matchKind { case .exact: return "checkmark.seal.fill"; case .similar: return "photo.on.rectangle.angled"; case .name: return "textformat.abc" }
    }
    var kindColor: Color {
        switch matchKind { case .exact: return .green; case .similar: return .blue; case .name: return .orange }
    }
    /// The file type(s) in the group, e.g. "JPG" or "JPG/PNG" when mixed.
    var typeLabel: String {
        let exts = Set(entries.map { $0.url.pathExtension.uppercased() }.filter { !$0.isEmpty })
        return exts.sorted().joined(separator: "/")
    }
}

/// One row in the duplicate-groups list: the summary, a › to compare, and **every file in the group
/// as a tile** — tap a tile to tick that specific copy for deletion (it gets a red ring and a trash
/// badge). The tiles and the › are separate buttons so a tap never lands on the wrong thing.
private struct DuplicateGroupRow: View {
    let group: DuplicateGroup
    @Binding var selectedFiles: Set<URL>
    /// Per-file date (capture date, else file date). When they differ within the group, the
    /// oldest tile is marked "Oldest" and the newest "Newest" — the cue for which copy to keep.
    var dates: [URL: Date] = [:]
    let onToggle: (URL) -> Void
    let onCompare: () -> Void

    private enum Age { case oldest, newest }
    /// Age markers, only when the group's dates actually differ (by more than a second).
    private var ages: [URL: Age] {
        let ds = group.entries.compactMap { e in dates[e.url].map { (e.url, $0) } }
        guard let lo = ds.min(by: { $0.1 < $1.1 }), let hi = ds.max(by: { $0.1 < $1.1 }),
              hi.1.timeIntervalSince(lo.1) > 1 else { return [:] }
        var out: [URL: Age] = [:]
        for (u, d) in ds where abs(d.timeIntervalSince(lo.1)) <= 1 { out[u] = .oldest }
        for (u, d) in ds where abs(d.timeIntervalSince(hi.1)) <= 1 { out[u] = .newest }
        return out
    }
    private var datesDiffer: Bool { !ages.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(group.entries.count) \(group.kindNoun) files")
                        .font(.subheadline.weight(.medium))
                    Text("\(group.size.sizeString) · \(group.dimensionLabel)\(group.typeLabel.isEmpty ? "" : " · \(group.typeLabel)")")
                        .font(.caption).foregroundStyle(.secondary)
                    Label(group.kindLabel, systemImage: group.kindIcon)
                        .font(.caption2)
                        .foregroundStyle(group.kindColor)
                }
                Spacer(minLength: 6)
                Button(action: onCompare) {
                    Label("Compare", systemImage: "chevron.right")
                        .labelStyle(.iconOnly)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Compare side by side")
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(group.entries) { e in fileTile(e) }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(.vertical, 4)
    }

    private func fileTile(_ e: Entry) -> some View {
        let ticked = selectedFiles.contains(e.url)
        let age = ages[e.url]
        return Button { onToggle(e.url) } label: {
            VStack(spacing: 4) {
                ZStack(alignment: .topTrailing) {
                    DuplicateThumb(entry: e, side: 88)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(ticked ? Color.red : .clear, lineWidth: 3))
                        .opacity(ticked ? 0.75 : 1)
                        .overlay(alignment: .bottomLeading) {
                            if let age { ageBadge(age) }
                        }
                    Image(systemName: ticked ? "trash.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(ticked ? Color.red : Color.white)
                        .shadow(radius: 2)
                        .padding(5)
                }
                Text(e.name).font(.caption2).lineLimit(1).truncationMode(.middle).frame(width: 88)
                if datesDiffer, let d = dates[e.url] {
                    // The date is what tells the copies apart, so show it under each tile.
                    Text(d.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2).lineLimit(1).minimumScaleFactor(0.8).frame(width: 88)
                        .foregroundStyle(age == .oldest ? Color.orange : age == .newest ? Color.cyan : .secondary)
                } else {
                    Text(e.size.sizeString).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel((ticked ? "Unmark \(e.name)" : "Mark \(e.name) for deletion")
                            + (age == .oldest ? ", oldest copy" : age == .newest ? ", newest copy" : ""))
    }

    /// "Oldest" (orange, clock) / "Newest" (cyan, sparkle) capsule on the tile's corner.
    private func ageBadge(_ age: Age) -> some View {
        Label(age == .oldest ? "Oldest" : "Newest", systemImage: age == .oldest ? "clock" : "sparkle")
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background((age == .oldest ? Color.orange : Color.cyan).opacity(0.9), in: Capsule())
            .foregroundStyle(.black)
            .padding(4)
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
    var onRename: (URL, Entry) -> Void = { _, _ in }
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
    /// Multi-select delete: the files ticked for removal, and its confirmation.
    @State private var selected = Set<URL>()
    @State private var confirmMultiDelete = false
    /// Bumped after an edit to force the metadata to reload.
    @State private var reloadToken = 0

    init(group: DuplicateGroup, onDelete: @escaping (URL) -> Void,
         onRename: @escaping (URL, Entry) -> Void = { _, _ in },
         onNotDuplicates: @escaping () -> Void = {}) {
        self.group = group
        self.onDelete = onDelete
        self.onRename = onRename
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
                    multiDeleteSection

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
        .confirmationDialog("Delete \(selected.count) file\(selected.count == 1 ? "" : "s")? This permanently removes \(selected.count == 1 ? "it" : "them") from the drive.",
                            isPresented: $confirmMultiDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { deleteMultiple() }
            Button("Cancel", role: .cancel) {}
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

    /// A checklist of every file in the group so several can be removed at once — pick one of the two
    /// on show, and/or tick any of the others, then delete them together.
    private var multiDeleteSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Delete files").font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Tap the copies you don't want, then remove them all at once.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(entries) { e in
                Button { toggle(e.url) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: selected.contains(e.url) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selected.contains(e.url) ? .red : .secondary)
                            .font(.title3)
                        DuplicateThumb(entry: e, side: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.name).font(.caption).lineLimit(1)
                            Text(e.size.sizeString).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Button(role: .destructive) { confirmMultiDelete = true } label: {
                Label("Delete Selected (\(selected.count))", systemImage: "trash")
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent).tint(.red)
            .disabled(selected.isEmpty)
        }
        .padding(.top, 4)
    }

    private func toggle(_ url: URL) {
        if selected.contains(url) { selected.remove(url) } else { selected.insert(url) }
    }

    /// Deletes every ticked file in one pass (re-keying labels/origins and notifying the parent list).
    private func deleteMultiple() {
        let urls = selected
        let targets = items.filter { urls.contains($0.url) }
        guard !targets.isEmpty else { return }
        FileActions.delete(targets)
        for e in targets { library.clearOrigins([e.url]); library.clearLabels([e.url]); onDelete(e.url) }
        library.contentDidChange()
        items.removeAll { urls.contains($0.url) }
        selected.removeAll()
        guard items.count >= 2 else { dismiss(); return }   // no longer a duplicate group
        leftIndex = min(leftIndex, items.count - 1)
        rightIndex = min(rightIndex, items.count - 1)
        if leftIndex == rightIndex { rightIndex = leftIndex == 0 ? 1 : 0 }
        reloadToken += 1
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
        let renamed = Entry(url: newURL, name: newURL.lastPathComponent,
                            kind: old.kind, size: old.size, modified: old.modified)
        items[idx] = renamed
        onRename(target.url, renamed)      // the list (and the remembered result) follow the new name
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

/// The remembered result of a folder's last duplicate scan — one JSON file per folder in
/// Application Support/`duplicateScans` (not Caches: iOS purges those under pressure, and a scan of
/// a big folder is minutes of work). Holds the groups (as paths) and a fingerprint (`size|mtime`) of
/// **every** file the scan covered, so the next open can tell "nothing new" (show it instantly,
/// dropping files that vanished) from "something was added or changed" (rescan). `nonisolated`:
/// read and written off the main actor.
nonisolated enum DuplicateScanCache {
    struct StoredGroup: Codable {
        var paths: [String]
        var size: Int64
        var longSide: Int
        var pixels: Int
        var kind: DuplicateMatchKind
        init(_ g: DuplicateGroup) {
            paths = g.entries.map { $0.url.path }; size = g.size; longSide = g.longSide; pixels = g.pixels; kind = g.matchKind
        }
    }
    struct Record: Codable {
        var scannedAt: Double
        var files: [String: String]
        var groups: [StoredGroup]

        /// Groups rebuilt against the folder's *current* listing: files that are gone drop out,
        /// pairs since marked Not Duplicates are skipped, groups left with one file disappear.
        func rebuild(with media: [Entry], dismissed: ([String]) -> Bool) -> [DuplicateGroup] {
            let byPath = Dictionary(media.map { ($0.url.path, $0) }, uniquingKeysWith: { a, _ in a })
            var out: [DuplicateGroup] = []
            for sg in groups {
                let entries = sg.paths.compactMap { byPath[$0] }
                guard entries.count > 1, !dismissed(entries.map { $0.url.path }) else { continue }
                out.append(DuplicateGroup(entries: entries, size: sg.size, longSide: sg.longSide, pixels: sg.pixels, matchKind: sg.kind))
            }
            return out
        }
    }

    static func fingerprint(_ media: [Entry]) -> [String: String] {
        Dictionary(media.map { ($0.url.path, "\($0.size)|\(Int($0.modified.timeIntervalSince1970))") },
                   uniquingKeysWith: { a, _ in a })
    }

    private static var directory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("duplicateScans", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private static func file(for folder: URL) -> URL {
        let key = SHA256.hash(data: Data(folder.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(key).appendingPathExtension("json")
    }

    static func load(folder: URL) async -> Record? {
        let url = file(for: folder)
        return await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(Record.self, from: data)
        }.value
    }

    static func save(_ record: Record, folder: URL) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? data.write(to: file(for: folder), options: .atomic)
    }
}
