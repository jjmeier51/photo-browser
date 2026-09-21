import SwiftUI

/// "Drive Health" — walks the SSD and calls out folders and files the app can't read: directories
/// that error on enumeration, files whose attributes won't stat, and zero-byte media (the classic
/// sign of an interrupted/half-committed exFAT copy). Read-only scan; the only mutation offered is
/// deleting a clearly-bad file so it can be re-copied cleanly.
struct DriveHealthView: View {
    @Environment(Library.self) private var library
    @State private var issues: [DriveIssue] = []
    @State private var scanning = true
    @State private var scanned = 0

    private var grouped: [(kind: DriveIssueKind, items: [DriveIssue])] {
        Dictionary(grouping: issues, by: \.kind)
            .map { (kind: $0.key, items: $0.value.sorted { $0.url.path < $1.url.path }) }
            .sorted { $0.kind < $1.kind }
    }

    var body: some View {
        Group {
            if scanning {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Scanning the drive…").foregroundStyle(.secondary)
                    Text("\(scanned) folders checked").font(.caption).foregroundStyle(.secondary)
                }
            } else if library.rootURL == nil {
                ContentUnavailableView("No Drive", systemImage: "externaldrive.badge.questionmark",
                    description: Text("Open a folder on the SSD first, then run this scan."))
            } else if issues.isEmpty {
                ContentUnavailableView("No Problems Found", systemImage: "checkmark.seal",
                    description: Text("Every folder read cleanly and no empty or unreadable files were found."))
            } else {
                List {
                    ForEach(grouped, id: \.kind) { section in
                        Section {
                            ForEach(section.items) { issue in
                                row(issue)
                            }
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
        .navigationTitle("Drive Health")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !scanning { ToolbarItem(placement: .topBarTrailing) { Button("Rescan") { Task { await runScan() } } } }
        }
        .task { if scanning { await runScan() } }
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
            if issue.kind.deletable {
                Button(role: .destructive) { delete(issue) } label: { Label("Delete", systemImage: "trash") }
            }
        }
    }

    private func relativePath(_ url: URL) -> String {
        guard let root = library.rootURL else { return url.path }
        let base = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return url.path.hasPrefix(base) ? String(url.path.dropFirst(base.count)) : url.path
    }

    private func delete(_ issue: DriveIssue) {
        try? FileManager.default.removeItem(at: issue.url)
        issues.removeAll { $0.id == issue.id }
        library.contentDidChange()
    }

    private func runScan() async {
        scanning = true; scanned = 0
        guard let root = library.rootURL else { scanning = false; return }
        issues = await Self.scan(root: root) { n in Task { @MainActor in scanned = n } }
        scanning = false
    }

    /// Recursively checks every folder under `root`, off the main actor. iOS's file provider for an
    /// external/exFAT drive **throttles a fast full-tree walk**, so a single failed read means
    /// nothing — it's retried with backoff, and a folder is only reported as unreadable when it keeps
    /// failing (a genuinely corrupt folder fails every attempt; a throttled one recovers). Plain
    /// reads, not coordinated ones, to keep the walk light. An *empty* folder (a clean `[]`) is fine
    /// and never flagged.
    nonisolated static func scan(root: URL, progress: @escaping @Sendable (Int) -> Void) async -> [DriveIssue] {
        await Task.detached(priority: .utility) {
            let fm = FileManager.default
            let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
            var issues: [DriveIssue] = []
            var stack = [root]
            var count = 0

            /// Reads a directory through the full fallback chain (coordinated → plain → no-prefetch →
            /// POSIX). A non-empty result means it's readable — including large exFAT dirs that only
            /// POSIX can enumerate. If the result is empty, a direct read with retries decides whether
            /// it's genuinely empty (fine) or a hard error, and captures the real reason to show.
            func readDir(_ dir: URL) async -> (urls: [URL], error: String?) {
                let kids = Library.coordinatedContents(of: dir, keys: keys)
                if !kids.isEmpty { return (kids, nil) }
                for attempt in 0..<3 {
                    do { return (try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]), nil) }
                    catch {
                        let ns = error as NSError
                        if attempt == 2 { return ([], "\(ns.domain) \(ns.code) — \(ns.localizedDescription)") }
                        try? await Task.sleep(nanoseconds: UInt64(200_000_000) * UInt64(attempt + 1))
                    }
                }
                return ([], nil)
            }

            while let dir = stack.popLast() {
                count += 1
                if count % 25 == 0 { progress(count) }
                if count > 200_000 { break }        // safety bound on pathological trees
                let (kids, error) = await readDir(dir)
                if let error {
                    issues.append(DriveIssue(url: dir, kind: .unreadableFolder, detail: error))
                    continue
                }
                let statKeys = Set(keys)
                for u in kids {
                    var rv = try? u.resourceValues(forKeys: statKeys)
                    if rv == nil { rv = try? u.resourceValues(forKeys: statKeys) }   // one retry before judging
                    if rv?.isDirectory == true {
                        stack.append(u)
                    } else if rv == nil {
                        issues.append(DriveIssue(url: u, kind: .unreadableFile, detail: "File attributes couldn't be read"))
                    } else if (rv?.fileSize ?? 0) == 0, [.image, .video, .pdf].contains(classify(url: u, isDirectory: false)) {
                        issues.append(DriveIssue(url: u, kind: .emptyFile, detail: "0 bytes — likely an incomplete copy"))
                    }
                }
            }
            progress(count)
            return issues
        }.value
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
    case unreadableFolder = 0, unreadableFile = 1, emptyFile = 2
    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    var title: String {
        switch self {
        case .unreadableFolder: return "Unreadable folders"
        case .unreadableFile:   return "Unreadable files"
        case .emptyFile:        return "Empty files"
        }
    }
    var systemImage: String {
        switch self {
        case .unreadableFolder: return "folder.badge.questionmark"
        case .unreadableFile:   return "doc.badge.ellipsis"
        case .emptyFile:        return "doc.badge.gearshape"
        }
    }
    var color: Color {
        switch self {
        case .unreadableFolder: return .red
        case .unreadableFile:   return .orange
        case .emptyFile:        return .orange
        }
    }
    var advice: String {
        switch self {
        case .unreadableFolder:
            return "These folders kept failing to read even after retries. On a slow external drive that's often heavy throttling, not damage — Rescan when the drive is idle and most should clear. If one still fails, re-copy it from the Mac and eject the drive properly (Finder ⏏ or `diskutil eject`) before unplugging."
        case .unreadableFile:
            return "The file's attributes couldn't be read. Delete and re-copy it cleanly."
        case .emptyFile:
            return "Zero-byte photos/videos are almost always interrupted copies. Deleting them here lets you re-copy the real file."
        }
    }
    /// Folders aren't deleted from here (the fix is a clean re-copy); bad files can be removed.
    var deletable: Bool { self != .unreadableFolder }
}
