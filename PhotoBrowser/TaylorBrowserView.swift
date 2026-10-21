import SwiftUI

/// In-app browser for the taylorpictures.net gallery: drill through categories →
/// albums → an image grid, and download whole albums into the current drive folder
/// (intended to be used from inside the "Taylor Swift" folder). Read-only over the
/// network; nothing is uploaded. Presented on its own screen so it can't collide with
/// the folder view's other dialogs.
///
/// Downloads go through `TaylorDownloads`, a queue that outlives this screen: pick as
/// many albums as you like (from an album's page, a row's button, a swipe, or "Download
/// All"), keep browsing while they come in one after another, and close the browser
/// whenever — the queue carries on (under a best-effort background-task window, so it
/// can't finish once the app is fully closed) and shows its progress as an app-wide pill.
struct TaylorBrowserView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(Library.self) private var library
    let targetFolder: URL
    let onFinished: () -> Void

    var body: some View {
        NavigationStack {
            GalleryCategoryView(category: nil, title: "taylorpictures.net", targetFolder: targetFolder)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                }
        }
        .safeAreaInset(edge: .bottom) { DownloadQueueBar() }
        .onAppear { TaylorDownloads.shared.attach(library: library, onAlbumDone: onFinished) }
    }
}

// MARK: - Download queue

/// The album download queue: albums go in, come down one after another (each with eight
/// images in flight), and the views watching it update as they go. Lives for the app's
/// lifetime so a download outlasts the browser screen.
@Observable @MainActor
final class TaylorDownloads {
    static let shared = TaylorDownloads()

    enum State: Equatable { case queued, downloading, done, failed(String) }
    struct Item: Identifiable {
        let album: TaylorGallery.Album
        let folder: URL
        var state: State = .queued
        var progress = TaylorGallery.Progress(fraction: 0, done: 0, total: 0, currentName: "")
        var id: Int { album.id }
    }

    private(set) var items: [Item] = []
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var activity: UUID?
    @ObservationIgnored private var bg: BackgroundTaskHolder?
    @ObservationIgnored private weak var library: Library?
    @ObservationIgnored private var onAlbumDone: (() -> Void)?

    func attach(library: Library, onAlbumDone: @escaping () -> Void) {
        self.library = library
        self.onAlbumDone = onAlbumDone
    }

    func state(of albumID: Int) -> State? { items.first { $0.id == albumID }?.state }
    var current: Item? { items.first { $0.state == .downloading } }
    var queuedCount: Int { items.filter { $0.state == .queued }.count }
    var finishedCount: Int { items.filter { $0.state == .done }.count }
    var failedCount: Int { items.filter { if case .failed = $0.state { return true }; return false }.count }

    /// Add an album (ignored while it's queued or downloading; a finished one can be run again).
    func enqueue(_ album: TaylorGallery.Album, into folder: URL) {
        if let i = items.firstIndex(where: { $0.id == album.id }) {
            if items[i].state == .queued || items[i].state == .downloading { return }
            items.remove(at: i)
        }
        items.append(Item(album: album, folder: folder))
        if task == nil { start() }
    }

    func cancelAll() {
        for i in items.indices where items[i].state == .queued { items[i].state = .failed("Cancelled") }
        task?.cancel()
    }

    /// Forget the finished and failed entries (keeps what's queued or running).
    func clearFinished() {
        items.removeAll { $0.state != .queued && $0.state != .downloading }
    }

    private func start() {
        guard let library else { return }
        let bg = BackgroundTaskHolder(); bg.begin(name: "Taylor Gallery Downloads")
        self.bg = bg
        let activity = library.beginActivity("Downloading albums")
        self.activity = activity
        task = Task { [weak self] in
            guard let self else { return }
            while let next = items.firstIndex(where: { $0.state == .queued }), !Task.isCancelled {
                items[next].state = .downloading
                let item = items[next]
                library.setActivity(activity, status: item.album.title, fraction: 0)
                // Detached: the download re-encodes images to stamp their dates, which must not
                // run on the main actor (constraint 13).
                let r = await Task.detached(priority: .userInitiated) {
                    await TaylorGallery.downloadAlbum(item.album, into: item.folder) { [weak self] p in
                        Task { @MainActor in
                            guard let self, let i = self.items.firstIndex(where: { $0.id == item.id }) else { return }
                            self.items[i].progress = p
                            library.setActivity(activity, status: "\(item.album.title) — \(p.done) of \(p.total)", fraction: p.fraction)
                        }
                    }
                }.value
                if let i = items.firstIndex(where: { $0.id == item.id }) {
                    if r.downloaded > 0 && r.failed == 0 && !Task.isCancelled {
                        items[i].state = .done
                    } else {
                        items[i].state = .failed(r.note ?? (r.downloaded > 0 ? "\(r.failed) failed" : "Nothing downloaded."))
                    }
                }
                if r.downloaded > 0 {
                    library.markTaylorAlbumDownloaded(item.album.id)
                    onAlbumDone?()
                }
            }
            let done = finishedCount
            library.endActivity(activity, result: done > 0 ? "Downloaded \(done) album\(done == 1 ? "" : "s") from taylorpictures.net" : nil)
            self.activity = nil
            self.bg?.end(); self.bg = nil
            task = nil
        }
    }
}

/// The queue's status, docked at the bottom of the browser while anything is queued or running.
private struct DownloadQueueBar: View {
    var body: some View {
        let q = TaylorDownloads.shared
        Group {
            if let cur = q.current {
                HStack(spacing: 12) {
                    ProgressView(value: cur.progress.total > 0 ? cur.progress.fraction : 0)
                        .progressViewStyle(.circular).controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(cur.album.title.isEmpty ? "Album \(cur.album.id)" : cur.album.title)
                            .font(.subheadline.weight(.medium)).lineLimit(1)
                        Text(cur.progress.total > 0 ? "\(cur.progress.done) of \(cur.progress.total)"
                             + (q.queuedCount > 0 ? "  ·  \(q.queuedCount) more queued" : "")
                             : "Listing…")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Cancel") { q.cancelAll() }.font(.subheadline)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.ultraThinMaterial)
            } else if !q.items.isEmpty {
                HStack {
                    Image(systemName: q.failedCount == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(q.failedCount == 0 ? Color.green : Color.orange)
                    Text(q.failedCount == 0 ? "\(q.finishedCount) album\(q.finishedCount == 1 ? "" : "s") downloaded"
                         : "\(q.finishedCount) downloaded · \(q.failedCount) didn’t finish")
                        .font(.subheadline)
                    Spacer()
                    Button("Clear") { q.clearFinished() }.font(.subheadline)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.ultraThinMaterial)
            }
        }
    }
}

// MARK: - Category

/// One level of the Coppermine category tree: its sub-categories and albums, searchable,
/// each album with its download state and a button to queue it.
private struct GalleryCategoryView: View {
    let category: Int?
    let title: String
    let targetFolder: URL

    @Environment(Library.self) private var library
    @State private var categories: [TaylorGallery.Category] = []
    @State private var albums: [TaylorGallery.Album] = []
    @State private var loading = true
    @State private var note: String?
    @State private var query = ""

    private var shownCategories: [TaylorGallery.Category] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? categories : categories.filter { $0.title.localizedCaseInsensitiveContains(q) }
    }
    private var shownAlbums: [TaylorGallery.Album] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? albums : albums.filter { $0.title.localizedCaseInsensitiveContains(q) || String($0.id) == q }
    }
    private var notYetDownloaded: [TaylorGallery.Album] {
        shownAlbums.filter { !library.isTaylorAlbumDownloaded($0.id) && TaylorDownloads.shared.state(of: $0.id) == nil }
    }

    var body: some View {
        List {
            if loading { HStack { Spacer(); ProgressView(); Spacer() } }
            if let note { Text(note).font(.callout).foregroundStyle(.secondary) }
            if !shownCategories.isEmpty {
                Section("Categories") {
                    ForEach(shownCategories) { c in
                        NavigationLink(c.title) {
                            GalleryCategoryView(category: c.id, title: c.title, targetFolder: targetFolder)
                        }
                    }
                }
            }
            if !shownAlbums.isEmpty {
                Section(albums.count == shownAlbums.count ? "Albums (\(albums.count))" : "Albums (\(shownAlbums.count) of \(albums.count))") {
                    ForEach(shownAlbums) { a in
                        NavigationLink {
                            GalleryAlbumView(album: a, targetFolder: targetFolder)
                        } label: {
                            HStack(spacing: 10) {
                                albumThumb(a)
                                Text(a.title.isEmpty ? "Album \(a.id)" : a.title).lineLimit(2)
                                Spacer(minLength: 6)
                                albumStatus(a)
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button { TaylorDownloads.shared.enqueue(a, into: targetFolder) } label: {
                                Label("Download", systemImage: "arrow.down.circle")
                            }
                            .tint(.blue)
                        }
                    }
                }
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Find an album")
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !albums.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            for a in notYetDownloaded { TaylorDownloads.shared.enqueue(a, into: targetFolder) }
                        } label: {
                            Label(notYetDownloaded.isEmpty ? "Everything here is downloaded"
                                  : "Download \(notYetDownloaded.count) Album\(notYetDownloaded.count == 1 ? "" : "s")\(query.isEmpty ? " Here" : " Shown")",
                                  systemImage: "arrow.down.circle")
                        }
                        .disabled(notYetDownloaded.isEmpty)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .task(id: category) { await load() }
    }

    private func load() async {
        loading = true; note = nil
        let cat = category
        let r = await Task.detached(priority: .userInitiated) { await TaylorGallery.browse(category: cat) }.value
        categories = r.categories; albums = r.albums
        note = r.note ?? ((categories.isEmpty && albums.isEmpty) ? "Nothing here." : nil)
        loading = false
    }

    @ViewBuilder private func albumStatus(_ a: TaylorGallery.Album) -> some View {
        switch TaylorDownloads.shared.state(of: a.id) {
        case .queued:
            Image(systemName: "clock").foregroundStyle(.secondary).accessibilityLabel("Queued")
        case .downloading:
            ProgressView().controlSize(.small)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityLabel("Didn't finish")
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Downloaded")
        case nil:
            if library.isTaylorAlbumDownloaded(a.id) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Downloaded")
            } else {
                Button { TaylorDownloads.shared.enqueue(a, into: targetFolder) } label: {
                    Image(systemName: "arrow.down.circle").font(.title3)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Download")
            }
        }
    }

    @ViewBuilder private func albumThumb(_ a: TaylorGallery.Album) -> some View {
        if let t = a.thumbURL {
            GalleryThumb(url: t)
                .frame(width: 46, height: 46)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.15))
                .frame(width: 46, height: 46)
                .overlay { Image(systemName: "photo").font(.caption).foregroundStyle(.secondary) }
        }
    }
}

// MARK: - Album

/// An album's images — filling in page by page as the site lists them — with a button
/// that puts the album on the download queue.
private struct GalleryAlbumView: View {
    let album: TaylorGallery.Album
    let targetFolder: URL

    @Environment(Library.self) private var library
    @State private var images: [TaylorGallery.Image] = []
    @State private var loading = true

    private let columns = [GridItem(.adaptive(minimum: 90), spacing: 4)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(images) { img in
                    GalleryThumb(url: img.thumbURL)
                        .aspectRatio(1, contentMode: .fill)
                        .clipped()
                }
            }
            .padding(4)
            if loading {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(images.isEmpty ? "Listing…" : "\(images.count) so far…").font(.caption).foregroundStyle(.secondary)
                }
                .padding(20)
            }
            if case .failed(let why)? = TaylorDownloads.shared.state(of: album.id) {
                Text(why).font(.caption).foregroundStyle(.orange).padding()
            }
        }
        .navigationTitle(album.title.isEmpty ? "Album" : album.title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: album.id) {
            loading = true
            let id = album.id
            let all = await Task.detached(priority: .userInitiated) {
                await TaylorGallery.images(inAlbum: id) { page in
                    Task { @MainActor in images.append(contentsOf: page) }
                }
            }.value
            images = all                                 // the full, deduplicated, ordered list
            loading = false
        }
        .safeAreaInset(edge: .bottom) { downloadBar }
    }

    private var downloadBar: some View {
        let state = TaylorDownloads.shared.state(of: album.id)
        let already = library.isTaylorAlbumDownloaded(album.id)
        return Button { TaylorDownloads.shared.enqueue(album, into: targetFolder) } label: {
            Label(downloadLabel(state: state, already: already),
                  systemImage: already || state == .done ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .disabled(images.isEmpty || state == .queued || state == .downloading)
        .padding()
        .background(.ultraThinMaterial)
    }

    private func downloadLabel(state: TaylorDownloads.State?, already: Bool) -> String {
        switch state {
        case .queued: return "Queued"
        case .downloading: return "Downloading…"
        default: break
        }
        if images.isEmpty { return loading ? "Listing…" : "No images" }
        let count = "\(images.count)\(loading ? "+" : "")"
        if already || state == .done { return "Downloaded — Get \(count) Again" }
        return "Download \(count) to “\(targetFolder.lastPathComponent)”"
    }
}

// MARK: - Thumbnail

/// A single remote thumbnail (loaded with a Referer header to satisfy hotlink
/// protection). Coppermine thumbnails are already small, so no downsampling.
private struct GalleryThumb: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color(white: 0.1)
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ProgressView()
            }
        }
        .task(id: url) { image = await Self.load(url) }
    }

    // Bound by BYTES, not just count: `countLimit = 5000` alone let up to 5000 full-size gallery
    // images accumulate with no memory ceiling, spiking memory hard on a long browse.
    private static let cache: NSCache<NSURL, UIImage> = {
        let c = NSCache<NSURL, UIImage>()
        c.countLimit = 800
        c.totalCostLimit = 96 * 1024 * 1024
        return c
    }()

    private static func load(_ url: URL) async -> UIImage? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        var req = URLRequest(url: url)
        req.setValue(TaylorGallery.host, forHTTPHeaderField: "Referer")
        req.setValue(TaylorGallery.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await TaylorGallery.session.data(for: req), let img = UIImage(data: data) else { return nil }
        let cost = Int(img.size.width * img.scale * img.size.height * img.scale) * 4
        cache.setObject(img, forKey: url as NSURL, cost: cost)
        return img
    }
}
