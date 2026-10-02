import SwiftUI
import CryptoKit

/// "Compare PNGs" — finds every PNG in one folder that matches another photo there and lets the
/// user settle each match: **hide** a copy (it leaves the grid but stays on the drive), **delete**
/// copies, or say they're **not the same photo**. Built to look and work like Find Duplicates.
///
/// What counts as a match (`PNGMatching`, pure and unit-tested):
/// * A PNG and a JPEG / HEIC / HEIF / RAW original or another PNG whose **names line up** —
///   `IMG_2225.png` ↔ `IMG_2225.jpg`, `IMG_2225_402C6DBE.png` ↔ `IMG_2225.heic`, `x.png` ↔ `x (1).png`.
/// * A PNG and any of those that **look alike** (perceptual dHash within a tight distance and the
///   same aspect ratio) — the typical "exported / upscaled / re-saved the same shot as a PNG" case.
/// * **"Frame" files** (video-frame screenshots) are only ever matched **by name, to other PNGs** —
///   `Frame 97.png` ↔ `Frame 97_XHDN3.png`. They are never hashed and never paired with a JPEG: a
///   folder of frames from one video is hundreds of look-alike images that are not the same photo.
/// Every match involves at least one PNG; two JPEGs are never compared here (that's Find Duplicates).
///
/// Scan is **non-recursive** (this folder only). ImageIO property reads and hashing run off the main
/// actor with bounded fan-out, and hashes go through `DuplicateDetection.HashCache` (shared with the
/// move/copy dedupe, keyed `name|size|mtime`), so a folder is hashed once, ever. **Results are
/// remembered** (`PNGMatchScanCache`, Application Support/`pngMatchScans`): reopening shows the last
/// result instantly; hiding, deleting, renaming and "not the same photo" update it in place, and a
/// rescan only happens when a file was added or changed, or on ↻. Hidden files are left out of the
/// scan, so a pair the user settled by hiding one side doesn't come back.
struct PNGMatchesView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let folder: URL

    @State private var groups: [PNGMatchGroup] = []
    @State private var scanning = true
    @State private var loaded = false                    // `.task` guard: never rescan on a re-appear
    @State private var scannedAt: Date?
    @State private var fingerprint: [String: String] = [:]   // path → "size|mtime" of every file the result covers
    @State private var selectedFiles = Set<URL>()         // files ticked for deletion / hiding
    @State private var filter: Filter = .all
    @State private var confirmDelete = false
    @State private var compareGroup: PNGMatchGroup?
    @State private var viewer: PNGViewerPresentation?
    @State private var scanNote = "Comparing PNGs…"

    private enum Filter: Hashable { case all, name, visual }

    private var shownGroups: [PNGMatchGroup] {
        switch filter {
        case .all:    return groups
        case .name:   return groups.filter { $0.reasons.contains(.name) }
        case .visual: return groups.filter { $0.reasons.contains(.visual) }
        }
    }
    private var nameCount: Int { groups.filter { $0.reasons.contains(.name) }.count }
    private var visualCount: Int { groups.filter { $0.reasons.contains(.visual) }.count }
    /// Ticked files that aren't hidden yet — what "Hide Selected" would act on.
    private var hideableSelection: [URL] { selectedFiles.filter { !library.isHiddenFile($0) }.sorted { $0.path < $1.path } }

    var body: some View {
        NavigationStack {
            Group {
                if scanning {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(scanNote).foregroundStyle(.secondary)
                    }
                } else if groups.isEmpty {
                    ContentUnavailableView {
                        Label("No PNG Matches", systemImage: "checkmark.circle")
                    } description: {
                        Text("No PNG in this folder shares a name with, or looks like, another photo here. Hidden files are left out.")
                    } actions: {
                        Button("Rescan") { Task { await load(force: true) } }.buttonStyle(.bordered)
                    }
                } else {
                    VStack(spacing: 0) {
                        Picker("Filter", selection: $filter) {
                            Text("All (\(groups.count))").tag(Filter.all)
                            Text("Same name (\(nameCount))").tag(Filter.name)
                            Text("Look alike (\(visualCount))").tag(Filter.visual)
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal).padding(.top, 8).padding(.bottom, 6)

                        List {
                            Section {
                                ForEach(shownGroups) { group in
                                    PNGMatchRow(group: group, selectedFiles: $selectedFiles,
                                                hiddenPaths: library.hiddenFiles,
                                                onToggle: { toggle($0) },
                                                onView: { view(group.entries, at: $0) },
                                                onHide: { url, hide in setHidden(hide, url) },
                                                onCompare: { compareGroup = group })
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        Button { markNotSame([group]) } label: {
                                            Label("Not the Same", systemImage: "checkmark.circle")
                                        }
                                        .tint(.green)
                                    }
                                    .contextMenu {
                                        Button { compareGroup = group } label: { Label("Compare", systemImage: "rectangle.split.2x1") }
                                        Button { markNotSame([group]) } label: { Label("Not the Same Photo", systemImage: "checkmark.circle") }
                                        Divider()
                                        Button { for e in group.entries { selectedFiles.insert(e.url) } } label: {
                                            Label("Select All in Group", systemImage: "checkmark.circle.fill")
                                        }
                                        Button { for e in group.entries { selectedFiles.remove(e.url) } } label: {
                                            Label("Deselect Group", systemImage: "circle")
                                        }
                                    }
                                }
                            } header: {
                                if let scannedAt {
                                    Text("Results from \(scannedAt.formatted(.relative(presentation: .named))) · tap ↻ to rescan")
                                }
                            } footer: {
                                Text("Each group is a PNG and the photo(s) it matches: the same name (IMG_2225.png ↔ IMG_2225.jpg, or an upscaler's IMG_2225_402C6DBE.png) and/or the same picture by look. “Frame” files are only matched to other PNGs with the same name (Frame 97.png ↔ Frame 97_XHDN3.png). Tap a picture to see it full size and swipe between the files; tap the circle to tick files, then Hide or Delete them from the bar below. Long-press a picture to hide or unhide just that file. Swipe a group to say they're not the same photo; › compares two side by side.")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Compare PNGs")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(item: $compareGroup) { group in
                DuplicateCompareView(group: group.asDuplicateGroup,
                                     dismissLabel: "Not the Same Photo",
                                     onDelete: { removed in remove(removed) },
                                     onRename: { old, new in renamed(old, to: new) },
                                     onView: { items, i in view(items, at: i) },
                                     onNotDuplicates: { markNotSame([group]) })
            }
            // The viewer can delete or move a file itself; when it closes, drop anything that's
            // gone from the drive so the groups (and the remembered result) stay truthful.
            .fullScreenCover(item: $viewer, onDismiss: pruneMissingFiles) { p in
                ViewerView(items: p.items, startIndex: p.startIndex)
                    .environment(library)
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
                        Button("Clear") { selectedFiles.removeAll() }
                        Spacer()
                        Button { hideSelected() } label: {
                            Label("Hide (\(hideableSelection.count))", systemImage: "eye.slash")
                        }
                        .disabled(hideableSelection.isEmpty)
                        Spacer()
                        Button(role: .destructive) { confirmDelete = true } label: {
                            Label("Delete (\(selectedFiles.count))", systemImage: "trash")
                        }
                    }
                }
            }
            .confirmationDialog("Delete \(selectedFiles.count) file\(selectedFiles.count == 1 ? "" : "s")? This permanently removes the files you ticked from the drive."
                                + (fullyTickedGroups > 0 ? " \(fullyTickedGroups) group\(fullyTickedGroups == 1 ? " loses" : "s lose") every file — nothing of \(fullyTickedGroups == 1 ? "that photo" : "those photos") will remain." : ""),
                                isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete \(selectedFiles.count)", role: .destructive) { deleteSelectedFiles() }
                Button("Cancel", role: .cancel) {}
            }
            .task(id: folder) { await load(force: false) }
        }
    }

    // MARK: - Full-size viewing

    private func view(_ items: [Entry], at index: Int) {
        guard items.indices.contains(index) else { return }
        viewer = PNGViewerPresentation(items: items, startIndex: index)
    }

    private func pruneMissingFiles() {
        let fm = FileManager.default
        var removed: [URL] = []
        for i in groups.indices.reversed() {
            let gone = groups[i].entries.filter { !fm.fileExists(atPath: $0.url.path) }
            guard !gone.isEmpty else { continue }
            removed += gone.map(\.url)
            groups[i].entries.removeAll { e in gone.contains { $0.url == e.url } }
            if groups[i].entries.count < 2 { groups.remove(at: i) }
        }
        guard !removed.isEmpty else { return }
        for u in removed { fingerprint.removeValue(forKey: u.path); selectedFiles.remove(u) }
        persist()
    }

    // MARK: - Selection, hide, delete

    private func toggle(_ url: URL) {
        if selectedFiles.contains(url) { selectedFiles.remove(url) } else { selectedFiles.insert(url) }
    }

    /// Groups whose every file is ticked — called out in the delete confirmation.
    private var fullyTickedGroups: Int {
        shownGroups.filter { g in g.entries.allSatisfy { selectedFiles.contains($0.url) } }.count
    }

    /// Hiding is the app's existing per-file hide (`Library.setFileHidden`): the file vanishes from
    /// the folder grid (unless "Show Hidden Items" is on) and from future scans here, but stays on
    /// the drive untouched. The group keeps showing it, dimmed, for the rest of this visit so the
    /// choice can be undone on the spot.
    private func setHidden(_ hidden: Bool, _ url: URL) {
        library.setFileHidden(hidden, for: url)
        if hidden { selectedFiles.remove(url) }
    }

    private func hideSelected() {
        for u in hideableSelection { library.setFileHidden(true, for: u) }
        selectedFiles.removeAll()
    }

    /// Deletes exactly the ticked files, then trims the groups and updates the remembered result.
    private func deleteSelectedFiles() {
        let urls = selectedFiles
        var seen = Set<URL>()
        let targets = groups.flatMap { $0.entries }.filter { urls.contains($0.url) && seen.insert($0.url).inserted }
        guard !targets.isEmpty else { return }
        FileActions.delete(targets)
        for e in targets {
            library.clearOrigins([e.url]); library.clearLabels([e.url])
            if library.isHiddenFile(e.url) { library.setFileHidden(false, for: e.url) }   // don't leave a stale hidden mark
        }
        library.contentDidChange(under: folder)
        for u in urls { remove(u, persisting: false) }
        selectedFiles.removeAll()
        persist()
    }

    /// Records every pair in each group as "not duplicates" (the same store Find Duplicates uses,
    /// so a pair settled in one screen is settled in both) and drops the groups.
    private func markNotSame(_ marked: [PNGMatchGroup]) {
        for g in marked { library.markNotDuplicates(g.entries.map { $0.url.path }) }
        let ids = Set(marked.map { $0.id })
        groups.removeAll { ids.contains($0.id) }
        for g in marked { for e in g.entries { selectedFiles.remove(e.url) } }
        if compareGroup.map({ ids.contains($0.id) }) == true { compareGroup = nil }
        persist()
    }

    /// A file renamed from the Compare screen keeps its place under its new name instead of
    /// counting as a removed + added file that would force a rescan next time.
    private func renamed(_ old: URL, to new: Entry) {
        for i in groups.indices {
            if let j = groups[i].entries.firstIndex(where: { $0.url == old }) { groups[i].entries[j] = new }
        }
        if let v = fingerprint.removeValue(forKey: old.path) { fingerprint[new.url.path] = v }
        if selectedFiles.remove(old) != nil { selectedFiles.insert(new.url) }
        persist()
    }

    /// A deleted file leaves every group it was in and the remembered result.
    private func remove(_ url: URL, persisting: Bool = true) {
        for i in groups.indices.reversed() {
            groups[i].entries.removeAll { $0.url == url }
            if groups[i].entries.count < 2 { groups.remove(at: i) }
        }
        fingerprint.removeValue(forKey: url.path)
        selectedFiles.remove(url)
        if persisting { persist() }
    }

    // MARK: - Loading (remembered result first, full scan only when needed)

    private func load(force: Bool) async {
        if loaded && !force { return }
        loaded = true
        scanning = true
        scanNote = "Comparing PNGs…"
        // Only PNGs and camera originals take part; hidden files are left out (hiding is how a
        // settled pair stays settled). Non-recursive: this folder's own files.
        let media = await library.listing(of: folder, sort: .nameAsc)
            .filter { $0.kind == .image && PNGMatching.isCandidate($0.url) && !library.isHiddenFile($0.url) }
        let current = DuplicateScanCache.fingerprint(media)

        if !force, let record = await PNGMatchScanCache.load(folder: folder) {
            // Only a NEW or CHANGED file can create a match we don't know about; vanished and
            // hidden files just drop out of their groups.
            let changed = current.contains { path, value in record.files[path] != value }
            if !changed {
                groups = record.rebuild(with: media, dismissed: allPairsDismissed)
                // Keep what the record knows about files now hidden, so unhiding one later doesn't
                // read as a "new file" and force a rescan.
                fingerprint = record.files.merging(current) { _, new in new }
                    .filter { path, _ in current[path] != nil || library.isHiddenFile(URL(fileURLWithPath: path)) }
                scannedAt = Date(timeIntervalSince1970: record.scannedAt)
                scanning = false
                persist()
                return
            }
        }

        groups = await fullScan(media: media)
        fingerprint = current
        scannedAt = Date()
        scanning = false
        persist()
    }

    private func persist() {
        let record = PNGMatchScanCache.Record(scannedAt: scannedAt?.timeIntervalSince1970 ?? Date().timeIntervalSince1970,
                                              files: fingerprint, groups: groups.map(PNGMatchScanCache.StoredGroup.init))
        let folder = folder
        Task.detached(priority: .utility) { PNGMatchScanCache.save(record, folder: folder) }
    }

    /// Reads each file's facts + hash off the main actor (8 at a time; "Frame" files are never
    /// decoded), pairs and clusters them with the pure `PNGMatching` functions, then drops pairs
    /// the user has already dismissed.
    private func fullScan(media: [Entry]) async -> [PNGMatchGroup] {
        guard media.contains(where: { DuplicateDetection.isPNG($0.url) }) else { return [] }
        scanNote = "Comparing \(media.count) image\(media.count == 1 ? "" : "s")…"
        let candidates: [PNGMatching.Candidate] = await Task.detached(priority: .userInitiated) {
            var out = [PNGMatching.Candidate?](repeating: nil, count: media.count)
            await withTaskGroup(of: (Int, PNGMatching.Candidate).self) { group in
                var idx = 0
                let maxConcurrent = 8
                func addNext() {
                    guard idx < media.count else { return }
                    let i = idx; let url = media[i].url; idx += 1
                    group.addTask { (i, PNGMatching.candidate(for: url)) }
                }
                for _ in 0..<min(maxConcurrent, media.count) { addNext() }
                while let (i, c) = await group.next() { out[i] = c; addNext() }
            }
            DuplicateDetection.HashCache.shared.flush()
            return out.compactMap { $0 }
        }.value
        let rawPairs = await Task.detached(priority: .userInitiated) { PNGMatching.pairs(candidates) }.value
        // Dismissals live on the main actor (Library) — filter here, then cluster (cheap).
        let pairs = rawPairs.filter { !library.areNotDuplicates(candidates[$0.a].url.path, candidates[$0.b].url.path) }
        let clusters = PNGMatching.cluster(count: candidates.count, pairs: pairs)
        let byURL = Dictionary(media.map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
        return clusters.compactMap { c -> PNGMatchGroup? in
            let entries = c.indices.compactMap { byURL[candidates[$0].url] }
            guard entries.count > 1 else { return nil }
            return PNGMatchGroup(entries: PNGMatchGroup.ordered(entries), reasons: c.reasons)
        }
        .sorted(by: PNGMatchGroup.displayOrder)
    }

    /// True only if every pair among `paths` was marked not-the-same.
    private func allPairsDismissed(_ paths: [String]) -> Bool {
        for i in 0..<paths.count { for j in (i + 1)..<paths.count {
            if !library.areNotDuplicates(paths[i], paths[j]) { return false }
        }}
        return true
    }
}

// MARK: - Matching rules (pure)

/// The rules behind Compare PNGs, kept pure over `Candidate` values so they're unit-testable with no
/// disk (`PhotoBrowserTests/PNGMatchingTests.swift`). `nonisolated`: the scan runs these inside a
/// detached task, and under default-MainActor isolation an unmarked type would hop every call back
/// to the main thread.
nonisolated enum PNGMatching {
    /// dHash Hamming distance at or below which two images "look alike". Tight on purpose: the
    /// groups here are PNG-centred rather than chained, but a photoshoot of similar poses still
    /// mustn't read as one picture.
    static let maxHashDistance = 7
    /// Aspect ratios must agree within this fraction (either orientation) for a visual match.
    static let aspectTolerance = 0.01

    // The nested types are marked `nonisolated` explicitly: nested declarations don't inherit the
    // enclosing enum's isolation, and these are built and encoded inside detached tasks.
    nonisolated enum Reason: Int, Codable, Hashable, Sendable {
        case name = 0      // the names line up
        case visual = 1    // the pictures look alike
    }

    /// Everything the pair test needs about one file.
    nonisolated struct Candidate: Sendable, Hashable {
        var url: URL
        var isPNG: Bool
        var isFrame: Bool
        var nameKey: String
        var aspect: Double?       // long side / short side; nil = unknown
        var hash: UInt64?         // nil = not hashed (frames) or undecodable

        init(url: URL, aspect: Double? = nil, hash: UInt64? = nil) {
            self.url = url
            let name = url.lastPathComponent
            isPNG = DuplicateDetection.isPNG(url)
            isFrame = PNGMatching.isFrame(name)
            nameKey = PNGMatching.nameKey(name)
            self.aspect = aspect
            self.hash = hash
        }
    }

    /// Two candidates (by index) and why they matched.
    nonisolated struct Pair: Hashable, Sendable {
        let a: Int
        let b: Int
        let reasons: Set<Reason>
    }

    /// A cluster of mutually matched files and the union of the reasons.
    nonisolated struct Cluster: Sendable {
        var indices: [Int]
        var reasons: Set<Reason>
    }

    /// PNGs and camera originals (JPEG / HEIC / HEIF / RAW) take part; nothing else.
    nonisolated static func isCandidate(_ url: URL) -> Bool { DuplicateDetection.isOriginal(url) || DuplicateDetection.isPNG(url) }

    nonisolated static func isFrame(_ filename: String) -> Bool { filename.range(of: "frame", options: .caseInsensitive) != nil }

    /// The name reduced for comparison: lowercased, extension off, trailing copy suffixes removed —
    /// " (1)", " copy", " copy 2" — repeatedly. Numbers that are part of the name stay
    /// (`Frame 97` must not collapse to `Frame`).
    nonisolated static func nameKey(_ filename: String) -> String {
        var base = (filename as NSString).deletingPathExtension.lowercased()
            .trimmingCharacters(in: .whitespaces)
        let patterns = [#"\s*\(\d+\)$"#, #"\s+copy(\s+\d+)?$"#]
        var changed = true
        while changed {
            changed = false
            for p in patterns {
                if let r = base.range(of: p, options: .regularExpression) {
                    base.removeSubrange(r)
                    base = base.trimmingCharacters(in: .whitespaces)
                    changed = true
                }
            }
        }
        return base
    }

    /// Whether two name keys belong together: identical, or one is the other plus a `_`/`-` tag —
    /// the suffix an upscaler or export appends (`img_2225_402c6dbe`, `frame 97_xhdn3`) or a short
    /// copy number (`img_2225_1`). The tag must contain a letter or be at most two digits, so
    /// `frame 9` never swallows `frame 97`, and a bare space is not a separator (`Frame` vs
    /// `Frame 97` are different frames).
    nonisolated static func similarNames(_ ka: String, _ kb: String) -> Bool {
        guard !ka.isEmpty, !kb.isEmpty else { return false }
        if ka == kb { return true }
        let (short, long) = ka.count <= kb.count ? (ka, kb) : (kb, ka)
        guard short.count >= 3, long.count > short.count + 1, long.hasPrefix(short) else { return false }
        let rest = long.dropFirst(short.count)
        guard let sep = rest.first, sep == "_" || sep == "-" else { return false }
        let tag = rest.dropFirst()
        guard !tag.isEmpty else { return false }
        if tag.contains(where: { $0.isLetter }) { return true }
        return tag.count <= 2 && tag.allSatisfy(\.isNumber)
    }

    nonisolated static func aspectAgrees(_ a: Double?, _ b: Double?) -> Bool {
        guard let a, let b else { return true }      // unknown never blocks (undecodable → no hash anyway)
        return abs(a - b) / max(a, b) <= aspectTolerance
    }

    /// Why `x` and `y` match — empty when they don't. At least one must be a PNG. A "Frame" file on
    /// either side restricts the test to PNG-to-PNG by name.
    nonisolated static func reasons(_ x: Candidate, _ y: Candidate) -> Set<Reason> {
        guard x.url != y.url, x.isPNG || y.isPNG else { return [] }
        if x.isFrame || y.isFrame {
            guard x.isPNG, y.isPNG, similarNames(x.nameKey, y.nameKey) else { return [] }
            return [.name]
        }
        var out: Set<Reason> = []
        if similarNames(x.nameKey, y.nameKey) { out.insert(.name) }
        if let hx = x.hash, let hy = y.hash, aspectAgrees(x.aspect, y.aspect),
           PerceptualHash.distance(hx, hy) <= maxHashDistance {
            out.insert(.visual)
        }
        return out
    }

    /// Every matching pair among `items`. Only PNGs are pivots, so the work is PNGs × files, not
    /// files²; each unordered pair is reported once.
    nonisolated static func pairs(_ items: [Candidate]) -> [Pair] {
        var out: [Pair] = []
        var seen = Set<[Int]>()
        for i in items.indices where items[i].isPNG {
            for j in items.indices where j != i {
                let key = [min(i, j), max(i, j)]
                guard !seen.contains(key) else { continue }
                let r = reasons(items[i], items[j])
                guard !r.isEmpty else { continue }
                seen.insert(key)
                out.append(Pair(a: key[0], b: key[1], reasons: r))
            }
        }
        return out.sorted { $0.a != $1.a ? $0.a < $1.a : $0.b < $1.b }
    }

    /// Union-find over the pairs: files linked by any match form one group, with the reasons merged.
    nonisolated static func cluster(count: Int, pairs: [Pair]) -> [Cluster] {
        var parent = Array(0..<count)
        func find(_ x: Int) -> Int { var r = x; while parent[r] != r { parent[r] = parent[parent[r]]; r = parent[r] }; return r }
        for p in pairs { parent[find(p.a)] = find(p.b) }
        var members: [Int: [Int]] = [:]
        var reasons: [Int: Set<Reason>] = [:]
        for p in pairs {
            let root = find(p.a)
            reasons[root, default: []].formUnion(p.reasons)
        }
        for i in 0..<count where reasons[find(i)] != nil { members[find(i), default: []].append(i) }
        return members.keys.sorted().map { Cluster(indices: members[$0]!.sorted(), reasons: reasons[$0] ?? []) }
    }

    /// Disk: the candidate for `url`. "Frame" files are names only — no ImageIO at all — which is
    /// what keeps a screenshot-heavy folder quick. Others read properties (aspect) and get their
    /// dHash through the shared persistent cache. Off the main actor only.
    nonisolated static func candidate(for url: URL) -> Candidate {
        var c = Candidate(url: url)
        guard !c.isFrame else { return c }
        let facts = DuplicateDetection.readFacts(url)
        c.aspect = facts.aspect
        c.hash = DuplicateDetection.HashCache.shared.hash(for: facts)
        return c
    }
}

// MARK: - Model

/// A PNG together with the photo(s) it matches in the same folder, and why.
struct PNGMatchGroup: Identifiable, Hashable {
    let id = UUID()
    var entries: [Entry]                      // PNGs first, then the others; each by name
    var reasons: Set<PNGMatching.Reason>

    /// PNGs first (they're the subject), then the originals, each sorted by name.
    static func ordered(_ entries: [Entry]) -> [Entry] {
        entries.sorted {
            let pa = DuplicateDetection.isPNG($0.url), pb = DuplicateDetection.isPNG($1.url)
            if pa != pb { return pa }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// Strongest evidence first (name and look → name → look), then by the first file's name.
    static func displayOrder(_ a: PNGMatchGroup, _ b: PNGMatchGroup) -> Bool {
        if a.rank != b.rank { return a.rank < b.rank }
        return (a.entries.first?.name ?? "").localizedStandardCompare(b.entries.first?.name ?? "") == .orderedAscending
    }
    private var rank: Int { reasons.count == 2 ? 0 : (reasons.contains(.name) ? 1 : 2) }

    var pngs: [Entry] { entries.filter { DuplicateDetection.isPNG($0.url) } }
    var others: [Entry] { entries.filter { !DuplicateDetection.isPNG($0.url) } }

    var kindLabel: String {
        if reasons.count == 2 { return "Same name & look alike" }
        return reasons.contains(.name) ? "Same name" : "Look alike"
    }
    var kindIcon: String {
        if reasons.count == 2 { return "checkmark.seal.fill" }
        return reasons.contains(.name) ? "textformat.abc" : "photo.on.rectangle.angled"
    }
    var kindColor: Color {
        if reasons.count == 2 { return .green }
        return reasons.contains(.name) ? .orange : .blue
    }
    /// The file types in the group, e.g. "PNG/JPG".
    var typeLabel: String {
        let exts = Set(entries.map { $0.url.pathExtension.uppercased() }.filter { !$0.isEmpty })
        return exts.sorted().joined(separator: "/")
    }
    /// The same files as a Find Duplicates group, for the shared side-by-side Compare screen.
    var asDuplicateGroup: DuplicateGroup {
        DuplicateGroup(entries: entries, size: entries.map(\.size).max() ?? 0, longSide: 0, pixels: 0,
                       matchKind: reasons.contains(.visual) ? .similar : .name)
    }
}

/// What to show in the full-screen viewer: a group's files, starting at the tapped one.
private struct PNGViewerPresentation: Identifiable {
    let id = UUID()
    let items: [Entry]
    let startIndex: Int
}

// MARK: - Row

/// One group: the PNG(s) and the photo(s) they match, each as a tile. Tap the picture to see it
/// full size (swipe to the others), tap the circle or caption to tick it, long-press the picture to
/// hide/unhide just that file. Hidden files stay in the row, dimmed with an eye-slash, so the
/// choice can be reversed on the spot.
private struct PNGMatchRow: View {
    let group: PNGMatchGroup
    @Binding var selectedFiles: Set<URL>
    let hiddenPaths: Set<String>
    let onToggle: (URL) -> Void
    let onView: (Int) -> Void              // index into group.entries → open full size
    let onHide: (URL, Bool) -> Void        // (file, hide?) — false = unhide
    let onCompare: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1).truncationMode(.middle)
                    Text("\(group.entries.count) files · \(group.typeLabel)")
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
                    ForEach(Array(group.entries.enumerated()), id: \.element.id) { i, e in fileTile(e, index: i) }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(.vertical, 4)
    }

    /// "IMG_2225.png ↔ IMG_2225.jpg", or "IMG_2225.png ↔ 3 photos".
    private var title: String {
        let pngs = group.pngs, others = group.others
        let lead = pngs.first?.name ?? group.entries.first?.name ?? ""
        let rest = (pngs.dropFirst().map { $0 } + others)
        if rest.count == 1, let only = rest.first { return "\(lead) ↔ \(only.name)" }
        return "\(lead) ↔ \(rest.count) photos"
    }

    private func fileTile(_ e: Entry, index: Int) -> some View {
        let ticked = selectedFiles.contains(e.url)
        let hidden = hiddenPaths.contains(e.url.path)
        let isPNG = DuplicateDetection.isPNG(e.url)
        return VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Button { onView(index) } label: {
                    DuplicateThumb(entry: e, side: 88)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(ticked ? Color.red : .clear, lineWidth: 3))
                        .opacity(ticked ? 0.75 : (hidden ? 0.4 : 1))
                        .overlay(alignment: .topLeading) {
                            Text(e.url.pathExtension.uppercased())
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background((isPNG ? Color.purple : Color.gray).opacity(0.9), in: Capsule())
                                .foregroundStyle(.white)
                                .padding(4)
                        }
                        .overlay(alignment: .bottomLeading) {
                            if hidden {
                                Label("Hidden", systemImage: "eye.slash")
                                    .font(.system(size: 9, weight: .bold))
                                    .padding(.horizontal, 6).padding(.vertical, 3)
                                    .background(Color.black.opacity(0.7), in: Capsule())
                                    .foregroundStyle(.white)
                                    .padding(4)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("View \(e.name) full size")
                .contextMenu {
                    Button { onHide(e.url, !hidden) } label: {
                        Label(hidden ? "Unhide File" : "Hide File", systemImage: hidden ? "eye" : "eye.slash")
                    }
                    Button { onToggle(e.url) } label: {
                        Label(ticked ? "Unmark for Deletion" : "Mark for Deletion", systemImage: ticked ? "circle" : "trash")
                    }
                }
                Button { onToggle(e.url) } label: {
                    Image(systemName: ticked ? "trash.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(ticked ? Color.red : Color.white)
                        .shadow(radius: 2)
                        .padding(6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(ticked ? "Unmark \(e.name)" : "Mark \(e.name)")
            }
            Button { onToggle(e.url) } label: {
                VStack(spacing: 2) {
                    Text(e.name).font(.caption2).lineLimit(1).truncationMode(.middle).frame(width: 88)
                    Text(hidden ? "Hidden" : e.size.sizeString).font(.caption2).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .accessibilityLabel(e.name + (hidden ? ", hidden" : ""))
    }
}

// MARK: - Remembered results

/// The remembered result of a folder's last Compare PNGs scan — one JSON file per folder in
/// Application Support/`pngMatchScans` (listed in Storage). Same shape and reasoning as
/// `DuplicateScanCache`: the groups as paths plus a `size|mtime` fingerprint of every file the scan
/// covered, so the next open can tell "nothing new" from "something was added or changed".
nonisolated enum PNGMatchScanCache {
    nonisolated struct StoredGroup: Codable, Sendable {
        var paths: [String]
        var reasons: [Int]
        init(_ g: PNGMatchGroup) { paths = g.entries.map { $0.url.path }; reasons = g.reasons.map(\.rawValue).sorted() }
    }
    nonisolated struct Record: Codable, Sendable {
        var scannedAt: Double
        var files: [String: String]
        var groups: [StoredGroup]

        /// Groups rebuilt against the folder's *current* candidates: files that are gone (or now
        /// hidden) drop out, groups since dismissed are skipped, groups left with one file vanish.
        func rebuild(with media: [Entry], dismissed: ([String]) -> Bool) -> [PNGMatchGroup] {
            let byPath = Dictionary(media.map { ($0.url.path, $0) }, uniquingKeysWith: { a, _ in a })
            var out: [PNGMatchGroup] = []
            for sg in groups {
                let entries = sg.paths.compactMap { byPath[$0] }
                guard entries.count > 1, entries.contains(where: { DuplicateDetection.isPNG($0.url) }),
                      !dismissed(entries.map { $0.url.path }) else { continue }
                let reasons = Set(sg.reasons.compactMap(PNGMatching.Reason.init(rawValue:)))
                out.append(PNGMatchGroup(entries: PNGMatchGroup.ordered(entries), reasons: reasons.isEmpty ? [.name] : reasons))
            }
            return out.sorted(by: PNGMatchGroup.displayOrder)
        }
    }

    private static var directory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("pngMatchScans", isDirectory: true)
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
