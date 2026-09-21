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

    /// Recursively checks every folder under `root`, off the main actor. Uses the coordinated read so
    /// an exFAT/file-provider folder is reconciled before we judge it (an uncoordinated read can look
    /// empty when it isn't). Distinguishes a real read error from a genuinely empty folder by
    /// attempting a direct read only when the coordinated one comes back empty.
    nonisolated static func scan(root: URL, progress: @escaping @Sendable (Int) -> Void) async -> [DriveIssue] {
        await Task.detached(priority: .utility) {
            let fm = FileManager.default
            var issues: [DriveIssue] = []
            var stack = [root]
            var count = 0
            while let dir = stack.popLast() {
                count += 1
                if count % 25 == 0 { progress(count) }
                if count > 50_000 { break }        // safety bound on pathological trees
                let kids = Library.coordinatedContents(of: dir, keys: [.isDirectoryKey, .fileSizeKey])
                if kids.isEmpty {
                    // Empty vs unreadable: a direct read that throws means the directory is bad.
                    if (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) == nil {
                        issues.append(DriveIssue(url: dir, kind: .unreadableFolder,
                                                 detail: "The folder couldn't be read"))
                    }
                    continue
                }
                for u in kids {
                    let rv = try? u.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
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
            return "These folders errored on read — often a half-committed copy. Re-copy them from the Mac, then eject the drive properly (Finder ⏏ or `diskutil eject`) before unplugging."
        case .unreadableFile:
            return "The file's attributes couldn't be read. Delete and re-copy it cleanly."
        case .emptyFile:
            return "Zero-byte photos/videos are almost always interrupted copies. Deleting them here lets you re-copy the real file."
        }
    }
    /// Folders aren't deleted from here (the fix is a clean re-copy); bad files can be removed.
    var deletable: Bool { self != .unreadableFolder }
}
