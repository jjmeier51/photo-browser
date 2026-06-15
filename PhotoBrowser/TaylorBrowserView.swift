import SwiftUI

/// In-app browser for the taylorpictures.net gallery: drill through categories →
/// albums → an image grid, and download a whole album into the current drive
/// folder (intended to be used from inside the "Taylor Swift" folder). Read-only
/// over the network; nothing is uploaded. Presented on its own screen so it can't
/// collide with the folder view's other dialogs. Like every transfer it runs
/// under a best-effort background-task window and can't finish once the app is
/// fully closed.
struct TaylorBrowserView: View {
    @Environment(\.dismiss) private var dismiss
    let targetFolder: URL
    let onFinished: () -> Void

    var body: some View {
        NavigationStack {
            GalleryCategoryView(category: nil, title: "taylorpictures.net",
                                targetFolder: targetFolder,
                                onDownloaded: { onFinished(); dismiss() })
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                }
        }
    }
}

/// One level of the Coppermine category tree: its sub-categories and albums.
private struct GalleryCategoryView: View {
    let category: Int?
    let title: String
    let targetFolder: URL
    let onDownloaded: () -> Void

    @Environment(Library.self) private var library
    @State private var categories: [TaylorGallery.Category] = []
    @State private var albums: [TaylorGallery.Album] = []
    @State private var loading = true
    @State private var note: String?

    var body: some View {
        List {
            if loading { HStack { Spacer(); ProgressView(); Spacer() } }
            if let note { Text(note).font(.callout).foregroundStyle(.secondary) }
            if !categories.isEmpty {
                Section("Categories") {
                    ForEach(categories) { c in
                        NavigationLink(c.title) {
                            GalleryCategoryView(category: c.id, title: c.title,
                                                targetFolder: targetFolder, onDownloaded: onDownloaded)
                        }
                    }
                }
            }
            if !albums.isEmpty {
                Section("Albums") {
                    ForEach(albums) { a in
                        NavigationLink {
                            GalleryAlbumView(album: a, targetFolder: targetFolder, onDownloaded: onDownloaded)
                        } label: {
                            HStack(spacing: 10) {
                                albumThumb(a)
                                Text(a.title.isEmpty ? "Album \(a.id)" : a.title).lineLimit(2)
                                Spacer(minLength: 6)
                                if library.isTaylorAlbumDownloaded(a.id) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green).accessibilityLabel("Downloaded")
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: category) { await load() }
    }

    private func load() async {
        loading = true; note = nil
        let r = await TaylorGallery.browse(category: category)
        categories = r.categories; albums = r.albums
        note = r.note ?? ((categories.isEmpty && albums.isEmpty) ? "Nothing here." : nil)
        loading = false
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

/// An album's images, with a button to download them all into `targetFolder`.
private struct GalleryAlbumView: View {
    let album: TaylorGallery.Album
    let targetFolder: URL
    let onDownloaded: () -> Void

    @Environment(Library.self) private var library
    @State private var images: [TaylorGallery.Image] = []
    @State private var loading = true
    @State private var downloading = false
    @State private var progress = TaylorGallery.Progress(fraction: 0, done: 0, total: 0, currentName: "")
    @State private var resultNote: String?

    private let columns = [GridItem(.adaptive(minimum: 90), spacing: 4)]

    var body: some View {
        ScrollView {
            if loading { ProgressView().padding(40) }
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(images) { img in
                    GalleryThumb(url: img.thumbURL)
                        .aspectRatio(1, contentMode: .fill)
                        .clipped()
                }
            }
            .padding(4)
            if let resultNote { Text(resultNote).font(.caption).foregroundStyle(.secondary).padding() }
        }
        .navigationTitle(album.title.isEmpty ? "Album" : album.title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: album.id) { images = await TaylorGallery.images(inAlbum: album.id); loading = false }
        .safeAreaInset(edge: .bottom) { downloadBar }
        .overlay { if downloading { progressOverlay } }
    }

    private var downloadBar: some View {
        Button { download() } label: {
            Label(downloadLabel, systemImage: "arrow.down.circle.fill")
                .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .disabled(images.isEmpty || downloading || loading)
        .padding()
        .background(.ultraThinMaterial)
    }

    private var downloadLabel: String {
        if loading { return "Loading…" }
        if images.isEmpty { return "No images" }
        return "Download \(images.count) to “\(targetFolder.lastPathComponent)”"
    }

    private var progressOverlay: some View {
        VStack(spacing: 12) {
            ProgressView(value: progress.fraction)
                .progressViewStyle(.linear).frame(width: 220)
            Text("Downloading \(progress.done) of \(progress.total)…")
                .font(.caption).foregroundStyle(.secondary)
            Text("Keep the app open; it keeps going briefly in the background.")
                .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(24).frame(maxWidth: 280)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func download() {
        downloading = true; resultNote = nil
        let bg = BackgroundTaskHolder()
        bg.begin(name: "Taylor Gallery Download")
        Task {
            let r = await TaylorGallery.downloadAlbum(album, into: targetFolder) { p in
                Task { @MainActor in progress = p }
            }
            downloading = false
            bg.end()
            if r.downloaded > 0 {
                library.markTaylorAlbumDownloaded(album.id)   // remember it (checkmark in the list)
                onDownloaded()            // reloads the folder and dismisses the browser
            } else {
                resultNote = r.note ?? "Nothing downloaded."
            }
        }
    }
}

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

    private static let cache: NSCache<NSURL, UIImage> = {
        let c = NSCache<NSURL, UIImage>(); c.countLimit = 5000; return c
    }()

    private static func load(_ url: URL) async -> UIImage? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        var req = URLRequest(url: url)
        req.setValue(TaylorGallery.host, forHTTPHeaderField: "Referer")
        req.setValue(TaylorGallery.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await TaylorGallery.session.data(for: req), let img = UIImage(data: data) else { return nil }
        cache.setObject(img, forKey: url as NSURL)
        return img
    }
}
