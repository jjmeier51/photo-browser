import SwiftUI

/// "Storage" — shows what Photo Browser keeps in its own on-device container (NOT on the SSD),
/// split into your data (kept) and regenerable caches (safe to clear), with per-category sizes and
/// a one-tap cache purge. Handy because reinstalling the app (e.g. after the 7-day sideload expiry)
/// wipes this container, and because caches can grow large on a big library.
struct StorageView: View {
    @State private var items: [StorageItem] = []
    @State private var loading = true
    @State private var clearing = false

    var body: some View {
        List {
            if loading {
                HStack(spacing: 10) { ProgressView(); Text("Measuring…").foregroundStyle(.secondary) }
            } else {
                Section {
                    ForEach(items.filter { !$0.clearable }) { row($0) }
                } header: {
                    Text("Your data — kept on this device")
                } footer: {
                    Text("Created in the app and keyed to your files' paths — labels, captions, covers, birthdays, custom thumbnails. These aren't on the SSD, so a reinstall loses them, but you can re-attach labels and covers with “Re-link Favorites from a Drive.”")
                }

                Section {
                    ForEach(items.filter { $0.clearable }) { row($0) }
                    Button(role: .destructive) { Task { await clearCaches() } } label: {
                        HStack {
                            Label("Clear Caches", systemImage: "trash")
                            Spacer()
                            if clearing { ProgressView() } else { Text(clearableBytes.sizeString).foregroundStyle(.secondary) }
                        }
                    }
                    .disabled(clearing || clearableBytes == 0)
                } header: {
                    Text("Caches — safe to clear")
                } footer: {
                    Text("Thumbnails, per-file metadata (dates, dimensions, places, text-in-photos, faces) and folder snapshots. These rebuild automatically as you browse — clearing only frees space and makes the next browse a little slower.")
                }

                Section {
                    HStack {
                        Text("Total app storage").fontWeight(.medium)
                        Spacer()
                        Text(items.reduce(0) { $0 + $1.bytes }.sizeString).foregroundStyle(.secondary).monospacedDigit()
                    }
                } footer: {
                    Text("This is only the app's own storage. Your photos and videos live on the SSD and aren't counted here.")
                }
            }
        }
        .navigationTitle("Storage")
        .navigationBarTitleDisplayMode(.inline)
        .task { if loading { await measure() } }
    }

    private func row(_ item: StorageItem) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                Text(item.detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(item.bytes.sizeString).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private var clearableBytes: Int64 { items.filter { $0.clearable }.reduce(0) { $0 + $1.bytes } }

    private func measure() async {
        let base = Self.catalog()
        items = await Task.detached(priority: .utility) {
            base.map { var i = $0; i.bytes = i.urls.reduce(0) { $0 + Self.size(of: $1) }; return i }
        }.value
        loading = false
    }

    private func clearCaches() async {
        clearing = true
        let targets = items.filter(\.clearable).flatMap(\.urls)
        await Task.detached(priority: .utility) {
            let fm = FileManager.default
            for u in targets {
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: u.path, isDirectory: &isDir) else { continue }
                if isDir.boolValue {
                    // Empty the directory but keep it — the app writes into these dirs lazily.
                    for k in (try? fm.contentsOfDirectory(at: u, includingPropertiesForKeys: nil)) ?? [] {
                        try? fm.removeItem(at: k)
                    }
                } else {
                    try? fm.removeItem(at: u)
                }
            }
        }.value
        await measure()
        clearing = false
    }

    // MARK: - Catalog + sizing (off the main actor)

    /// The app-container stores, grouped. `clearable` marks regenerable caches.
    nonisolated static func catalog() -> [StorageItem] {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        func s(_ c: String) -> URL { support.appendingPathComponent(c) }
        return [
            StorageItem(name: "Labels & organization", detail: "Favorites, captions, people, birthdays", urls: [s("bulkStore")], clearable: false),
            StorageItem(name: "Folder covers", detail: "Album cover images", urls: [s("folderCovers")], clearable: false),
            StorageItem(name: "Custom thumbnails", detail: "Per-item cover overrides", urls: [s("itemThumbs")], clearable: false),
            StorageItem(name: "Text-message archives", detail: "Saved message threads", urls: [s("textMessages")], clearable: false),
            StorageItem(name: "Web download history", detail: "Recent link/web downloads", urls: [s("webDownloadHistory.json")], clearable: false),
            StorageItem(name: "Thumbnails", detail: "Grid preview cache", urls: [s("thumbs")], clearable: true),
            StorageItem(name: "Metadata caches", detail: "Dates, dimensions, places, text, faces",
                        urls: ["captureDates", "mediaSpecs", "ocrText", "placeIndex", "faces", "taylorIndex"].map { s("\($0).json") }, clearable: true),
            StorageItem(name: "Folder snapshots", detail: "Instant-open listings", urls: [caches.appendingPathComponent("listings")], clearable: true),
            StorageItem(name: "Download staging", detail: "Temporary background downloads", urls: [s("bgInbox")], clearable: true),
            StorageItem(name: "Web album cache", detail: "Browsed gallery indexes", urls: [s("accessKardashian")], clearable: true),
        ]
    }

    /// Allocated size of a file or (recursively) a directory. 0 if it doesn't exist.
    nonisolated static func size(of url: URL) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        func bytes(_ u: URL) -> Int64 {
            let v = try? u.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            return Int64(v?.totalFileAllocatedSize ?? v?.fileSize ?? 0)
        }
        if !isDir.boolValue { return bytes(url) }
        var total: Int64 = 0
        if let e = fm.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]) {
            for case let f as URL in e { total += bytes(f) }
        }
        return total
    }
}

/// One storage category: the files/dirs that make it up, whether it's a clearable cache, and its size.
struct StorageItem: Identifiable, Sendable {
    let id = UUID()
    let name: String
    let detail: String
    let urls: [URL]
    let clearable: Bool
    var bytes: Int64 = 0
}
