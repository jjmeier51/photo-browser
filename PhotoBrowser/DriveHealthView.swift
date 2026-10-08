import SwiftUI

/// "Drive Health" — walks the SSD and calls out what the app can't read or trust: folders that
/// error on enumeration, files whose attributes won't stat, zero-byte media (the classic sign of
/// an interrupted exFAT copy) and, with the deeper check on, files whose first bytes are all zero
/// (size allocated, data never landed) or don't match their extension. It also audits the app's
/// own **metadata** against the drive and keeps it safe while the drive is being fixed:
///
/// * **Back up / restore metadata** — every path-keyed store, drive-relative, written into a hidden
///   folder on the drive and into the app (`MetadataSnapshot`). Restore merges, never overwrites.
/// * **Metadata pointing at missing items** — entries whose file or folder is gone, by category,
///   with **Re-link by Filename** (a unique same-name match elsewhere on the drive re-keys the
///   entry through `Library.itemsMoved`, the same path every in-app move uses).
/// * **Rebuild Folder** for an unreadable folder — copy, verify, swap in place (`DriveRepair`),
///   so the path never changes and nothing attached to it is lost; the original is parked as
///   `<name>.damaged` for the user to delete. A metadata backup is taken first, automatically.
///
/// The scan is read-only; the only mutations are the ones the user asks for by name.
struct DriveHealthView: View {
    @Environment(Library.self) private var library
    @State private var issues: [DriveIssue] = []
    @State private var scanning = true
    @State private var scannedFolders = 0
    @State private var scannedFiles = 0
    @State private var liveIssues = 0
    @State private var lastScan: Date?
    @State private var complete = true                        // the walk covered the whole tree
    @State private var existing = Set<String>()               // every path the scan saw
    @State private var byName: [String: [String]] = [:]       // name → paths, for re-linking
    @State private var unreadable: [String] = []              // folders whose contents are unknown
    @State private var orphans: [MetadataCategory: [String]] = [:]
    @State private var message: String?
    @State private var working = false
    @State private var rebuildTarget: DriveIssue?
    @State private var rebuilding: RebuildProgress?
    @State private var confirmRestore: URL?
    @State private var confirmDeleteLeftover: DriveIssue?
    @State private var driveBackupDate: Date?
    @State private var containerBackup: URL?
    @State private var containerBackupDate: Date?
    @State private var orphanSheet: MetadataCategory?
    @State private var confirmForgetAll = false
    @State private var forgetBackupTaken = false              // one automatic backup before the first Forget
    @AppStorage("photoBrowser.driveHealthDeepCheck") private var deepCheck = false

    private struct RebuildProgress { var name: String; var files: Int; var bytes: Int64 }

    private var grouped: [(kind: DriveIssueKind, items: [DriveIssue])] {
        Dictionary(grouping: issues, by: \.kind)
            .map { (kind: $0.key, items: $0.value.sorted { $0.url.path < $1.url.path }) }
            .sorted { $0.kind < $1.kind }
    }
    private var orphanTotal: Int { orphans.values.reduce(0) { $0 + $1.count } }
    private var driveBackupURL: URL? { library.rootURL.map(MetadataBackup.driveBackupDirectory(root:)) }

    var body: some View {
        Group {
            if library.rootURL == nil {
                ContentUnavailableView("No Drive", systemImage: "externaldrive.badge.questionmark",
                    description: Text("Open a folder on the SSD first, then run this scan."))
            } else {
                List {
                    scanSection
                    metadataSection
                    if !scanning {
                        if complete && orphanTotal > 0 { orphanSection }
                        ForEach(grouped, id: \.kind) { section in
                            Section {
                                ForEach(section.items) { issue in row(issue) }
                            } header: {
                                Label("\(section.kind.title) (\(section.items.count))", systemImage: section.kind.systemImage)
                                    .foregroundStyle(section.kind.color)
                            } footer: {
                                Text(section.kind.advice)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Drive Health")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !scanning {
                if !unreadableFolderPaths.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        ShareLink(item: exportText) { Image(systemName: "square.and.arrow.up") }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) { Button("Rescan") { Task { await runScan() } }.disabled(working) }
            }
        }
        .overlay {
            if let r = rebuilding {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Rebuilding “\(r.name)”…").font(.subheadline.weight(.medium))
                    Text("\(r.files) files · \(r.bytes.sizeString) copied").font(.caption).foregroundStyle(.secondary)
                    Text("Keep the drive connected.").font(.caption2).foregroundStyle(.tertiary)
                }
                .padding(24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            } else if working {
                ProgressView().padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .alert("Drive Health", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") { message = nil }
        } message: {
            Text(message ?? "")
        }
        .confirmationDialog("Rebuild this folder in place?",
                            isPresented: Binding(get: { rebuildTarget != nil }, set: { if !$0 { rebuildTarget = nil } }),
                            titleVisibility: .visible, presenting: rebuildTarget) { issue in
            Button("Rebuild “\(issue.url.lastPathComponent)”") { Task { await rebuild(issue) } }
            Button("Cancel", role: .cancel) { rebuildTarget = nil }
        } message: { issue in
            Text("Every file in “\(issue.url.lastPathComponent)” is copied into a fresh folder, checked file by file, and the fresh folder takes the original's exact name and place — so Favorites, captions, birthdays, covers, linked profiles and everything else attached to it stay put. The original is kept beside it as “\(issue.url.lastPathComponent).damaged” until you delete it. A metadata backup is saved first. Needs free space for a second copy.")
        }
        .confirmationDialog("Restore metadata from this backup?",
                            isPresented: Binding(get: { confirmRestore != nil }, set: { if !$0 { confirmRestore = nil } }),
                            titleVisibility: .visible, presenting: confirmRestore) { dir in
            Button("Restore (merge)") { Task { await restore(from: dir) } }
            Button("Cancel", role: .cancel) { confirmRestore = nil }
        } message: { dir in
            Text("Adds every entry from the backup that this drive is missing — favorites, labels, captions, covers, birthdays, linked profiles, People and the rest — matched by each file's place on the drive. Anything already set is left as it is. (\(dir.lastPathComponent))")
        }
        .confirmationDialog("Delete the parked original folder?",
                            isPresented: Binding(get: { confirmDeleteLeftover != nil }, set: { if !$0 { confirmDeleteLeftover = nil } }),
                            titleVisibility: .visible, presenting: confirmDeleteLeftover) { issue in
            Button("Delete “\(issue.url.lastPathComponent)”", role: .destructive) { delete(issue) }
            Button("Cancel", role: .cancel) { confirmDeleteLeftover = nil }
        } message: { issue in
            Text("This is the damaged original that a rebuild replaced. Open the rebuilt folder first and make sure everything is there; then this copy can go.")
        }
        .confirmationDialog("Forget every missing entry?",
                            isPresented: $confirmForgetAll, titleVisibility: .visible) {
            Button("Forget \(orphanTotal) Entr\(orphanTotal == 1 ? "y" : "ies")", role: .destructive) {
                Task { await forget(Array(Set(orphans.values.flatMap { $0 })), announce: true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The app stops keeping covers, labels, captions and the rest for items that are no longer on the drive. Nothing on the drive is touched, and a metadata backup is saved to this phone first, so Restore can bring them back.")
        }
        .sheet(item: $orphanSheet) { c in
            OrphanListSheet(category: c, paths: orphans[c] ?? [],
                            relative: { [root = library.rootURL] u in
                                u.standardizedFileURL.path == root?.standardizedFileURL.path
                                    ? "the drive's top level" : Self.relativePath(u, root: root)
                            },
                            candidates: { [byName] in Self.rankedCandidates(for: $0, in: byName).map { $0.path } },
                            onRelink: { old, new in relink([(from: URL(fileURLWithPath: old), to: URL(fileURLWithPath: new))]) },
                            onForget: { paths in Task { await forget(paths, announce: false) } })
        }
        .task {
            await refreshBackups()
            if scanning { await runScan() }
        }
    }

    // MARK: - Sections

    private var scanSection: some View {
        Section {
            if scanning {
                HStack(spacing: 12) {
                    ProgressView()
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Scanning the drive…")
                        Text("\(scannedFolders) folders · \(scannedFiles) files · \(liveIssues) issue\(liveIssues == 1 ? "" : "s") so far")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                HStack(spacing: 12) {
                    Image(systemName: issues.isEmpty ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(issues.isEmpty ? Color.green : Color.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(issues.isEmpty ? "No problems found" : "\(issues.count) issue\(issues.count == 1 ? "" : "s") found")
                        Text("\(scannedFolders) folders · \(scannedFiles) files"
                             + (lastScan.map { " · \($0.formatted(.relative(presentation: .named)))" } ?? "")
                             + (complete ? "" : " · stopped early (very large tree)"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Toggle(isOn: $deepCheck) {
                Label("Also check file contents", systemImage: "waveform.path.ecg")
            }
            .disabled(scanning)
        } header: {
            Text("Scan")
        } footer: {
            Text("Reads every folder and the size of every file. “Check file contents” also reads the first bytes of each photo and video to catch files whose size looks right but whose data never landed (all zeros), and files whose contents don't match their extension — slower on a big drive. Change it, then Rescan.")
        }
    }

    private var metadataSection: some View {
        Section {
            if !scanning && complete && orphanTotal == 0 {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Every metadata entry points at a file or folder that exists").font(.subheadline)
                }
            }
            Button { Task { await backUp() } } label: {
                Label("Back Up Metadata Now", systemImage: "arrow.down.doc")
            }
            .disabled(working || scanning)
            LabeledContent("On the drive", value: driveBackupDate.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "No backup yet")
            LabeledContent("On this phone", value: containerBackupDate.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "No backup yet")
            if driveBackupDate != nil, let dir = driveBackupURL {
                Button { confirmRestore = dir } label: {
                    Label("Restore from the Drive's Backup", systemImage: "arrow.counterclockwise.circle")
                }
                .disabled(working || scanning)
            }
            if let containerBackup {
                Button { confirmRestore = containerBackup } label: {
                    Label("Restore from this Phone's Backup", systemImage: "arrow.counterclockwise.circle")
                }
                .disabled(working || scanning)
            }
        } header: {
            Text("Metadata safety")
        } footer: {
            Text("Everything the app attaches to your files — Favorites, To AI, labels, captions, folder covers, custom thumbnails, birthdays, hidden items, linked Instagram / Facebook / TikTok / VSCO / OF profiles, highlights, People, AI provenance — is saved by each item's place on the drive into a hidden “.Photo Browser Metadata” folder on the drive and into the app (the last three are kept). Back up before fixing the drive on the Mac; afterwards Restore merges back anything that went missing. Restoring never overwrites what's already set.")
        }
    }

    private var orphanSection: some View {
        Section {
            ForEach(MetadataCategory.allCases.filter { (orphans[$0]?.count ?? 0) > 0 }) { c in
                Button { orphanSheet = c } label: {
                    HStack {
                        Text(c.title).foregroundStyle(.primary)
                        Spacer()
                        Text("\(orphans[c]?.count ?? 0)").foregroundStyle(.secondary).monospacedDigit()
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                }
            }
            Button { Task { await relinkOrphans() } } label: {
                Label("Re-link by Filename", systemImage: "link")
            }
            .disabled(working)
            Button(role: .destructive) { confirmForgetAll = true } label: {
                Label("Forget All Missing Entries…", systemImage: "trash")
            }
            .disabled(working)
        } header: {
            Label("Metadata pointing at missing items (\(orphanTotal))", systemImage: "link.badge.plus")
                .foregroundStyle(.orange)
        } footer: {
            Text("These entries refer to files or folders that aren't on the drive any more — renamed or moved outside the app (for example while fixing the drive on the Mac), or deleted. Re-link looks for each missing name elsewhere on the drive and moves the entry there when one match is clearly right (same name, then the same parent folders). Tap a category to see each entry, pick a match yourself, or Forget it — that's for things deleted for good; a backup is saved first. Items inside unreadable folders and items in Recently Deleted aren't counted.")
        }
    }

    private func row(_ issue: DriveIssue) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(issue.url.lastPathComponent).font(.subheadline)
                Text(relativePath(issue.url)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Text(issue.detail).font(.caption2).foregroundStyle(.tertiary).lineLimit(2)
            }
            Spacer()
        }
        .swipeActions(edge: .trailing) {
            switch issue.kind {
            case .unreadableFolder:
                Button { rebuildTarget = issue } label: { Label("Rebuild", systemImage: "arrow.triangle.2.circlepath") }.tint(.blue)
            case .damagedLeftover:
                Button(role: .destructive) { confirmDeleteLeftover = issue } label: { Label("Delete", systemImage: "trash") }
            default:
                if issue.kind.deletable {
                    Button(role: .destructive) { delete(issue) } label: { Label("Delete", systemImage: "trash") }
                }
            }
        }
        .contextMenu {
            if issue.kind == .unreadableFolder {
                Button { rebuildTarget = issue } label: { Label("Rebuild Folder in Place…", systemImage: "arrow.triangle.2.circlepath") }
            }
            if issue.kind == .damagedLeftover {
                Button(role: .destructive) { confirmDeleteLeftover = issue } label: { Label("Delete Parked Original…", systemImage: "trash") }
            } else if issue.kind.deletable {
                Button(role: .destructive) { delete(issue) } label: { Label("Delete File", systemImage: "trash") }
            }
        }
    }

    // MARK: - Export / paths

    /// Drive-relative paths of the unreadable folders, shallowest first (so rebuilding a parent on
    /// the Mac covers any bad children before they're processed). Shared as plain text for a Mac
    /// script to re-copy in place.
    private var unreadableFolderPaths: [String] {
        issues.filter { $0.kind == .unreadableFolder }
            .map { relativePath($0.url) }
            .sorted { a, b in
                let da = a.components(separatedBy: "/").count, db = b.components(separatedBy: "/").count
                return da != db ? da < db : a.localizedStandardCompare(b) == .orderedAscending
            }
    }
    private var exportText: String { unreadableFolderPaths.joined(separator: "\n") }

    private func relativePath(_ url: URL) -> String { Self.relativePath(url, root: library.rootURL) }

    nonisolated static func relativePath(_ url: URL, root: URL?) -> String {
        guard let root else { return url.path }
        let base = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return url.path.hasPrefix(base) ? String(url.path.dropFirst(base.count)) : url.path
    }

    // MARK: - Actions

    private func delete(_ issue: DriveIssue) {
        try? FileManager.default.removeItem(at: issue.url)
        issues.removeAll { $0.id == issue.id }
        confirmDeleteLeftover = nil
        library.contentDidChange()
    }

    private func backUp() async {
        working = true
        let r = await library.backUpMetadata(toDrive: true)
        await refreshBackups()
        working = false
        if r.container == nil && r.drive == nil {
            message = "The backup couldn't be written."
        } else {
            message = "Backed up \(r.entries) metadata entr\(r.entries == 1 ? "y" : "ies")"
                + (r.drive != nil ? " to the drive and to this phone." : " to this phone. The copy on the drive couldn't be written — is the drive read-only or full?")
        }
    }

    private func restore(from dir: URL) async {
        working = true
        let n = await library.restoreMetadata(fromBackupAt: dir)
        working = false
        confirmRestore = nil
        if let n {
            computeOrphans()
            message = n == 0 ? "Nothing to restore — this drive already has everything in that backup."
                             : "Restored \(n) metadata entr\(n == 1 ? "y" : "ies"). Existing entries were left untouched."
        } else {
            message = "That backup couldn't be read."
        }
    }

    private func refreshBackups() async {
        guard let root = library.rootURL else { return }
        let driveDir = MetadataBackup.driveBackupDirectory(root: root)
        let (dDate, cURL, cDate) = await Task.detached(priority: .userInitiated) { () -> (Date?, URL?, Date?) in
            let d = FileManager.default.fileExists(atPath: driveDir.appendingPathComponent(MetadataBackup.jsonName).path)
                ? MetadataBackup.date(of: driveDir) : nil
            let c = MetadataBackup.latestContainerBackup()
            return (d, c, c.flatMap(MetadataBackup.date(of:)))
        }.value
        driveBackupDate = dDate
        containerBackup = cURL
        containerBackupDate = cDate
    }

    /// Rebuilds an unreadable folder in place (see `DriveRepair.rebuildFolder`), after an automatic
    /// metadata backup into the app. On success the issue is replaced by the parked original.
    private func rebuild(_ issue: DriveIssue) async {
        rebuildTarget = nil
        working = true
        _ = await library.backUpMetadata(toDrive: false)
        let name = issue.url.lastPathComponent
        rebuilding = RebuildProgress(name: name, files: 0, bytes: 0)
        let result = await DriveRepair.rebuildFolder(issue.url) { files, bytes in
            Task { @MainActor in rebuilding = RebuildProgress(name: name, files: files, bytes: bytes) }
        }
        rebuilding = nil
        working = false
        if let damaged = result.damagedURL {
            issues.removeAll { $0.id == issue.id }
            issues.append(DriveIssue(url: damaged, kind: .damagedLeftover,
                                     detail: "Parked original of “\(name)” — \(result.copiedFiles) files were rebuilt"))
            unreadable.removeAll { $0 == issue.url.path }
            library.contentDidChange()
            message = "Rebuilt “\(name)” in place: \(result.copiedFiles) file\(result.copiedFiles == 1 ? "" : "s") (\(result.copiedBytes.sizeString)) copied and verified. Everything attached to the folder is unchanged. The original is parked as “\(damaged.lastPathComponent)” — delete it from the list below once you've checked the rebuilt folder."
        } else {
            message = result.error ?? "The folder couldn't be rebuilt."
        }
    }

    // MARK: - Orphaned metadata

    private func computeOrphans() {
        guard complete, let root = library.rootURL else { orphans = [:]; return }
        let all = library.metadataPaths(under: root)
        let unknownPrefixes = unreadable.map { $0 + "/" }
        // Items in Recently Deleted keep their entries under the original path on purpose, so a
        // restore reconnects them — they aren't missing.
        let trashed = Set(library.trash.map(\.originalPath))
        let trashedPrefixes = library.trash.filter(\.isFolder).map { $0.originalPath + "/" }
        func unknown(_ p: String) -> Bool {
            unreadable.contains(p) || unknownPrefixes.contains { p.hasPrefix($0) }
                || trashed.contains(p) || trashedPrefixes.contains { p.hasPrefix($0) }
        }
        var out: [MetadataCategory: [String]] = [:]
        for (c, paths) in all {
            let missing = paths.filter { !existing.contains($0) && !unknown($0) }
            if !missing.isEmpty { out[c] = missing.sorted() }
        }
        orphans = out
    }

    /// Re-keys every orphaned entry whose filename has one clearly-right match elsewhere on the drive
    /// (see `rankedCandidates`) via `Library.itemsMoved`.
    private func relinkOrphans() async {
        working = true
        defer { working = false }
        let all = Set(orphans.values.flatMap { $0 })
        var moves: [(from: URL, to: URL)] = []
        var ambiguous = 0, unmatched = 0
        for old in all.sorted() {
            let ranked = Self.rankedCandidates(for: old, in: byName)
            if ranked.count == 1 || (ranked.count > 1 && ranked[0].tail >= 1 && ranked[0].tail > ranked[1].tail) {
                moves.append((from: URL(fileURLWithPath: old), to: URL(fileURLWithPath: ranked[0].path)))
            } else if ranked.isEmpty { unmatched += 1 } else { ambiguous += 1 }
        }
        guard !moves.isEmpty else {
            message = "Nothing could be re-linked: \(unmatched) name\(unmatched == 1 ? " isn't" : "s aren't") on the drive at all"
                + (ambiguous > 0 ? ", and \(ambiguous) appear\(ambiguous == 1 ? "s" : "") in more than one place" : "")
                + ". Tap a category to pick matches yourself, or Forget entries for things that were deleted."
            return
        }
        relink(moves)
        message = "Re-linked \(moves.count) item\(moves.count == 1 ? "" : "s")."
            + (unmatched > 0 ? " \(unmatched) couldn't be found on the drive." : "")
            + (ambiguous > 0 ? " \(ambiguous) appear in more than one place — tap a category to pick." : "")
    }

    private func relink(_ moves: [(from: URL, to: URL)]) {
        library.itemsMoved(moves)
        library.contentDidChange()
        computeOrphans()
    }

    /// Forgets every entry for `paths` (all categories — the item is gone), after one automatic
    /// metadata backup into the app per visit, so a Restore can undo it. `announce` is off from the
    /// per-category sheet (an alert can't show behind it; its rows just disappear).
    private func forget(_ paths: [String], announce: Bool) async {
        guard !paths.isEmpty else { return }
        working = true
        if !forgetBackupTaken {
            _ = await library.backUpMetadata(toDrive: false)
            forgetBackupTaken = true
            await refreshBackups()
        }
        let set = Set(paths)
        let n = library.forgetMetadata { set.contains($0) }
        working = false
        computeOrphans()
        if announce {
            message = "Forgot \(n) entr\(n == 1 ? "y" : "ies") for \(paths.count) missing items. A backup was saved to this phone first."
        }
    }

    /// Same-named items elsewhere on the drive for a missing `old` path, best match first: the most
    /// parent-folder names in common (counted up from the item), then the longest shared leading path.
    /// `tail == 0` means only the name matches.
    nonisolated static func rankedCandidates(for old: String, in byName: [String: [String]])
        -> [(path: String, tail: Int, head: Int)] {
        let a = old.split(separator: "/")
        guard let name = a.last else { return [] }
        let found = (byName[String(name)] ?? []).filter { $0 != old }
        return found.map { cand -> (path: String, tail: Int, head: Int) in
            let b = cand.split(separator: "/")
            var tail = 0
            while tail + 1 < min(a.count, b.count), a[a.count - 2 - tail] == b[b.count - 2 - tail] { tail += 1 }
            var head = 0
            while head < min(a.count, b.count) - 1, a[head] == b[head] { head += 1 }
            return (cand, tail, head)
        }
        .sorted { ($0.tail, $0.head, $1.path) > ($1.tail, $1.head, $0.path) }
    }

    // MARK: - Scan

    private func runScan() async {
        scanning = true; scannedFolders = 0; scannedFiles = 0; liveIssues = 0
        guard let root = library.rootURL else { scanning = false; return }
        let r = await Self.scan(root: root, deep: deepCheck) { folders, files, found in
            Task { @MainActor in scannedFolders = folders; scannedFiles = files; liveIssues = found }
        }
        issues = r.issues
        scannedFolders = r.folders; scannedFiles = r.files
        existing = r.paths; byName = r.byName; unreadable = r.unreadable; complete = r.complete
        lastScan = Date()
        scanning = false
        computeOrphans()
    }

    struct ScanResult: Sendable {
        var issues: [DriveIssue] = []
        var folders = 0
        var files = 0
        var paths = Set<String>()
        var byName: [String: [String]] = [:]
        var unreadable: [String] = []
        var complete = true
    }

    /// Recursively checks every folder under `root`, off the main actor. iOS's file provider for an
    /// external/exFAT drive **throttles a fast full-tree walk**, so a single failed read means
    /// nothing — it's retried with backoff, and a folder is only reported as unreadable when it keeps
    /// failing (a genuinely corrupt folder fails every attempt; a throttled one recovers). Plain
    /// reads, not coordinated ones, to keep the walk light. An *empty* folder (a clean `[]`) is fine
    /// and never flagged. Alongside the issues it returns every path seen and a name → paths table,
    /// which the metadata audit and Re-link use without a second walk.
    nonisolated static func scan(root: URL, deep: Bool,
                                 progress: @escaping @Sendable (Int, Int, Int) -> Void) async -> ScanResult {
        await Task.detached(priority: .utility) {
            let fm = FileManager.default
            let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
            var r = ScanResult()
            var stack = [root]
            r.paths.insert(root.path)

            func readDir(_ dir: URL) async -> (urls: [URL], error: String?) {
                let kids = Library.coordinatedContents(of: dir, keys: keys)
                if !kids.isEmpty { return (kids, nil) }
                for attempt in 0..<3 {
                    do { return (try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]), nil) }
                    catch {
                        let ns = error as NSError
                        if attempt == 2 {
                            var detail = "\(ns.domain) \(ns.code) — \(ns.localizedDescription)"
                            // The underlying error says *why* (EINVAL from the exFAT driver vs a timeout…).
                            var under = ns.userInfo[NSUnderlyingErrorKey] as? NSError
                            while let u = under {
                                detail += " · \(u.domain) \(u.code)"
                                under = u.userInfo[NSUnderlyingErrorKey] as? NSError
                            }
                            errno = 0
                            if let dirp = opendir(dir.path) { closedir(dirp) }
                            else { let e = errno; detail += " · opendir errno \(e) (\(String(cString: strerror(e))))" }
                            return ([], detail)
                        }
                        try? await Task.sleep(nanoseconds: UInt64(200_000_000) * UInt64(attempt + 1))
                    }
                }
                return ([], nil)
            }

            while let dir = stack.popLast() {
                r.folders += 1
                if r.folders % 25 == 0 { progress(r.folders, r.files, r.issues.count) }
                if r.folders > 200_000 { r.complete = false; break }        // safety bound on pathological trees
                let (kids, error) = await readDir(dir)
                if let error {
                    r.issues.append(DriveIssue(url: dir, kind: .unreadableFolder, detail: error))
                    r.unreadable.append(dir.path)
                    continue
                }
                let statKeys = Set(keys)
                var toProbe: [URL] = []
                for u in kids {
                    var rv = try? u.resourceValues(forKeys: statKeys)
                    if rv == nil { rv = try? u.resourceValues(forKeys: statKeys) }   // one retry before judging
                    let name = u.lastPathComponent
                    r.paths.insert(u.path)
                    r.byName[name, default: []].append(u.path)
                    if rv?.isDirectory == true {
                        if name.hasSuffix(".damaged") || name.range(of: #"\.damaged \d+$"#, options: .regularExpression) != nil {
                            r.issues.append(DriveIssue(url: u, kind: .damagedLeftover, detail: "Original parked by an earlier Rebuild"))
                            continue                                     // don't walk or audit inside it
                        }
                        stack.append(u)
                    } else if rv == nil, Library.directoryStatus(of: u, statted: nil).isDirectory {
                        // Listed by its parent but not stat-able, and folder-shaped: a damaged folder
                        // entry (macOS still shows it; iOS can't open it). Report it as the folder it
                        // is — it used to be filed under "unreadable files" and never offered Rebuild.
                        r.issues.append(DriveIssue(url: u, kind: .unreadableFolder,
                                                   detail: "iOS can't read this folder's attributes — repair the drive on a Mac (Disk Utility ▸ First Aid, or mac/repair_drive.sh)"))
                        r.unreadable.append(u.path)
                    } else {
                        r.files += 1
                        if rv == nil {
                            r.issues.append(DriveIssue(url: u, kind: .unreadableFile, detail: "File attributes couldn't be read"))
                            continue
                        }
                        let kind = classify(url: u, isDirectory: false)
                        guard [.image, .video, .pdf].contains(kind) else { continue }
                        if (rv?.fileSize ?? 0) == 0 {
                            r.issues.append(DriveIssue(url: u, kind: .emptyFile, detail: "0 bytes — likely an incomplete copy"))
                        } else if deep, kind != .pdf {
                            toProbe.append(u)
                        }
                    }
                }
                if !toProbe.isEmpty {
                    // Header probes read 16 bytes each; bounded fan-out so a 5,000-file folder
                    // doesn't open 5,000 handles at once on a slow drive.
                    let found: [DriveIssue] = await withTaskGroup(of: DriveIssue?.self, returning: [DriveIssue].self) { group in
                        var it = toProbe.makeIterator()
                        for _ in 0..<8 { if let u = it.next() { group.addTask { probe(u) } } }
                        var out: [DriveIssue] = []
                        for await issue in group {
                            if let issue { out.append(issue) }
                            if let u = it.next() { group.addTask { probe(u) } }
                        }
                        return out
                    }
                    r.issues += found
                }
            }
            progress(r.folders, r.files, r.issues.count)
            return r
        }.value
    }

    private nonisolated static func probe(_ u: URL) -> DriveIssue? {
        switch DriveRepair.probeHeader(u) {
        case .blank?:
            return DriveIssue(url: u, kind: .blankFile, detail: "Size looks right but the data is all zeros — the copy never finished")
        case .mismatch(let expected, let actual)?:
            let detail = actual.map { "Named \(expected) but it's really a \($0) — it still opens fine" }
                ?? "Doesn't start like a \(expected) file (unrecognised contents)"
            return DriveIssue(url: u, kind: .headerMismatch, detail: detail)
        case nil:
            return nil
        }
    }
}

/// One thing wrong on the drive.
struct DriveIssue: Identifiable, Sendable {
    let id = UUID()
    let url: URL
    let kind: DriveIssueKind
    let detail: String
}

enum DriveIssueKind: Int, Sendable, Comparable {
    case unreadableFolder = 0, blankFile = 1, unreadableFile = 2, emptyFile = 3, headerMismatch = 4, damagedLeftover = 5
    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    var title: String {
        switch self {
        case .unreadableFolder: return "Unreadable folders"
        case .blankFile:        return "Files with no data"
        case .unreadableFile:   return "Unreadable files"
        case .emptyFile:        return "Empty files"
        case .headerMismatch:   return "Contents don't match the extension"
        case .damagedLeftover:  return "Parked originals from rebuilds"
        }
    }
    var systemImage: String {
        switch self {
        case .unreadableFolder: return "folder.badge.questionmark"
        case .blankFile:        return "doc.badge.ellipsis"
        case .unreadableFile:   return "doc.badge.ellipsis"
        case .emptyFile:        return "doc.badge.gearshape"
        case .headerMismatch:   return "doc.questionmark"
        case .damagedLeftover:  return "folder.badge.minus"
        }
    }
    var color: Color {
        switch self {
        case .unreadableFolder: return .red
        case .blankFile:        return .red
        case .unreadableFile:   return .orange
        case .emptyFile:        return .orange
        case .headerMismatch:   return .yellow
        case .damagedLeftover:  return .secondary
        }
    }
    var advice: String {
        switch self {
        case .unreadableFolder:
            return "These folders kept failing to read even after retries. On a slow external drive that can be throttling — Rescan when the drive is idle. If one still fails, iOS's exFAT driver is rejecting the folder itself (macOS still reads it). Fix it on the Mac: Share this list, then run mac/exfat_inspect.py on it first (read-only — shows what iOS objects to) and mac/rebuild_exfat_folders.py --move, which rebuilds each folder in place without copying, keeping its name and path so everything attached to it stays. Eject the drive in Finder before unplugging."
        case .blankFile:
            return "The file has a size but its data is all zeros — exFAT allocated the space and the copy was interrupted before the bytes landed. These can't be recovered here: delete and re-copy the real file to the same place, and its Favorites, captions and labels will pick up again."
        case .unreadableFile:
            return "The file's attributes couldn't be read. Delete and re-copy it cleanly to the same place."
        case .emptyFile:
            return "Zero-byte photos/videos are almost always interrupted copies. Deleting them here lets you re-copy the real file; keep the same name and folder so its metadata stays attached."
        case .headerMismatch:
            return "The first bytes aren't what the extension says (for example a .jpg that's really a PNG, or a .mov that isn't a movie). Often it's just mislabelled and opens fine — view it before deciding. If it won't open anywhere, delete and re-copy it."
        case .damagedLeftover:
            return "Each is the untouched original a Rebuild replaced. Check the rebuilt folder opens and has everything; then delete the parked copy to get the space back."
        }
    }
    /// Folders aren't deleted from here (the fix is a rebuild or a clean re-copy); bad files can be removed.
    var deletable: Bool { self != .unreadableFolder && self != .damagedLeftover }
}

/// The missing entries of one metadata category: each with the same-named items found elsewhere on
/// the drive (best match first) to re-link it to, or Forget for things deleted for good. Keeps its
/// own list so rows disappear as they're handled; the parent re-audits after each action.
private struct OrphanListSheet: View {
    let category: MetadataCategory
    let relative: (URL) -> String
    let candidates: (String) -> [String]
    let onRelink: (String, String) -> Void
    let onForget: ([String]) -> Void
    @State private var remaining: [String]
    @State private var confirmForgetAll = false
    @Environment(\.dismiss) private var dismiss

    init(category: MetadataCategory, paths: [String], relative: @escaping (URL) -> String,
         candidates: @escaping (String) -> [String], onRelink: @escaping (String, String) -> Void,
         onForget: @escaping ([String]) -> Void) {
        self.category = category
        self.relative = relative
        self.candidates = candidates
        self.onRelink = onRelink
        self.onForget = onForget
        _remaining = State(initialValue: paths)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(remaining, id: \.self) { path in row(path) }
                } footer: {
                    Text("Re-link moves the entry to the item you pick. Forget removes everything the app kept for that missing item (a backup is saved to this phone first).")
                }
            }
            .overlay {
                if remaining.isEmpty {
                    ContentUnavailableView("All Handled", systemImage: "checkmark.circle")
                }
            }
            .navigationTitle(category.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                if remaining.count > 1 {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Forget All", role: .destructive) { confirmForgetAll = true }
                    }
                }
            }
            .confirmationDialog("Forget all \(remaining.count) missing \(category.title.lowercased())?",
                                isPresented: $confirmForgetAll, titleVisibility: .visible) {
                Button("Forget All", role: .destructive) {
                    onForget(remaining)
                    remaining.removeAll()
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private func row(_ path: String) -> some View {
        let url = URL(fileURLWithPath: path)
        let found = candidates(path)
        return VStack(alignment: .leading, spacing: 4) {
            Text(url.lastPathComponent).font(.subheadline)
            Text("was in " + relative(url.deletingLastPathComponent())).font(.caption).foregroundStyle(.secondary)
            if found.isEmpty {
                Text("Not found anywhere on the drive").font(.caption2).foregroundStyle(.tertiary)
            } else {
                ForEach(found.prefix(4), id: \.self) { match in
                    Button {
                        onRelink(path, match)
                        remaining.removeAll { $0 == path }
                    } label: {
                        Label("Re-link to " + relative(URL(fileURLWithPath: match).deletingLastPathComponent()),
                              systemImage: "link")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
                if found.count > 4 {
                    Text("+\(found.count - 4) more with the same name").font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                onForget([path])
                remaining.removeAll { $0 == path }
            } label: { Label("Forget", systemImage: "trash") }
        }
    }
}
