import SwiftUI
import Photos
import AVKit

extension PHAsset: Identifiable { public var id: String { localIdentifier } }

/// One album/collection row in the Photos browser. PhotoKit model objects are
/// immutable and thread-safe, so it's fine to build these off-main (`@unchecked`
/// only because PHAssetCollection itself isn't marked Sendable).
struct AlbumEntry: Identifiable, @unchecked Sendable {
    let id: String
    let title: String
    let collection: PHAssetCollection
    let count: Int
}

/// Browses the iOS Photos library in-app by album (Recents, Favorites, Videos,
/// Screenshots, user albums, …). If `targetFolder` is set, an individual item
/// can be saved into that drive folder.
struct PhotosLibraryView: View {
    let targetFolder: URL?
    var deleteOriginals: Bool = false        // "Move" mode: remove from Photos after import
    @Environment(\.dismiss) private var dismiss
    @State private var albums: [AlbumEntry] = []
    @State private var status: PHAuthorizationStatus = .notDetermined
    @State private var loading = true

    var body: some View {
        NavigationStack {
            Group {
                if status == .authorized || status == .limited {
                    if loading {
                        ProgressView("Loading albums…")
                    } else {
                        List(albums) { album in
                            NavigationLink {
                                AssetGridView(collection: album.collection, title: album.title,
                                              targetFolder: targetFolder, deleteOriginals: deleteOriginals)
                            } label: {
                                AlbumRow(album: album)
                            }
                        }
                        .listStyle(.plain)
                    }
                } else {
                    permissionPrompt
                }
            }
            .navigationTitle(deleteOriginals ? "Add from iOS Album" : "Photos Library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } } }
        }
        .task { await load() }
    }

    private var permissionPrompt: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled").font(.largeTitle).foregroundStyle(.secondary)
            Text("Photos access is off").font(.headline)
            Text("Allow access to browse your iOS Photos library here.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if status == .denied || status == .restricted {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }.buttonStyle(.borderedProminent)
            }
        }
        .padding(40)
    }

    private func load() async {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        status = current == .notDetermined
            ? await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            : current
        guard status == .authorized || status == .limited else { loading = false; return }
        // Collection fetches and per-album asset counts are synchronous PhotoKit
        // I/O — run them off the main actor so a big library can't stall the sheet.
        albums = await Task.detached(priority: .userInitiated) { Self.loadAlbums() }.value
        loading = false
    }

    /// Curated smart albums (in Photos-app order) followed by the user's albums A→Z.
    nonisolated private static func loadAlbums() -> [AlbumEntry] {
        func entry(_ collection: PHAssetCollection, _ title: String) -> AlbumEntry? {
            let count = PHAsset.fetchAssets(in: collection, options: nil).count
            guard count > 0 else { return nil }
            return AlbumEntry(id: collection.localIdentifier, title: title,
                              collection: collection, count: count)
        }
        var result: [AlbumEntry] = []
        let smarts: [(PHAssetCollectionSubtype, String)] = [
            (.smartAlbumUserLibrary, "Recents"),
            (.smartAlbumFavorites, "Favorites"),
            (.smartAlbumVideos, "Videos"),
            (.smartAlbumScreenshots, "Screenshots"),
            (.smartAlbumRecentlyAdded, "Recently Added"),
            (.smartAlbumSelfPortraits, "Selfies"),
            (.smartAlbumLivePhotos, "Live Photos"),
            (.smartAlbumPanoramas, "Panoramas"),
            (.smartAlbumDepthEffect, "Portrait"),
            (.smartAlbumSlomoVideos, "Slo-mo"),
            (.smartAlbumTimelapses, "Time-lapse"),
            (.smartAlbumBursts, "Bursts"),
            (.smartAlbumAnimated, "Animated")
        ]
        for (subtype, title) in smarts {
            PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: subtype, options: nil)
                .enumerateObjects { collection, _, _ in
                    if let e = entry(collection, title) { result.append(e) }
                }
        }
        // PhotoKit returns user albums in its internal order; show them
        // alphabetized (Finder-style, so "Trip 2" sorts before "Trip 10").
        var userAlbums: [AlbumEntry] = []
        PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
            .enumerateObjects { collection, _, _ in
                if let e = entry(collection, collection.localizedTitle ?? "Album") { userAlbums.append(e) }
            }
        userAlbums.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return result + userAlbums
    }
}

private struct AlbumRow: View {
    let album: AlbumEntry
    @State private var image: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.15)).frame(width: 56, height: 56)
                if let image {
                    Image(uiImage: image).resizable().scaledToFill().frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(album.title)
                Text("\(album.count)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .task(id: album.id) {
            let options = PHFetchOptions(); options.fetchLimit = 1
            if let first = PHAsset.fetchAssets(in: album.collection, options: options).firstObject {
                image = await PhotosThumbs.thumbnail(for: first)
            }
        }
    }
}

/// A grid of the assets inside one album, with multi-select and bulk import.
private struct AssetGridView: View {
    let collection: PHAssetCollection
    let title: String
    let targetFolder: URL?
    var deleteOriginals: Bool = false
    @Environment(Library.self) private var library
    @State private var assets: [PHAsset] = []
    @State private var selected: PHAsset?
    @State private var selecting = false
    @State private var selectedIDs = Set<String>()
    @State private var importing = false
    @State private var importDone = 0
    @State private var importTotal = 0
    @State private var importTask: Task<Void, Never>?
    @State private var note: String?

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 2)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(assets) { asset in
                    PhotoAssetCell(asset: asset, selecting: selecting,
                                   selected: selectedIDs.contains(asset.localIdentifier))
                        .onTapGesture { tap(asset) }
                }
            }
            .padding(2)
        }
        .navigationTitle(selecting ? "\(selectedIDs.count) Selected" : title)
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if assets.isEmpty { ProgressView() } }
        .overlay { if importing { importOverlay } }
        .toolbar { toolbar }
        .fullScreenCover(item: $selected) { asset in
            AssetViewer(asset: asset, targetFolder: targetFolder)
        }
        .alert("Photos", isPresented: Binding(get: { note != nil }, set: { if !$0 { note = nil } })) {
            Button("OK") { note = nil }
        } message: { Text(note ?? "") }
        .task { await load() }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if targetFolder != nil {
                let verb = deleteOriginals ? "Move" : "Add"
                if selecting {
                    Button(selectedIDs.count == assets.count ? "None" : "All") { toggleAll() }
                    Button("\(verb) (\(selectedIDs.count))") {
                        importAssets(assets.filter { selectedIDs.contains($0.localIdentifier) })
                    }.disabled(selectedIDs.isEmpty || importing)
                    Button("Done") { selecting = false; selectedIDs.removeAll() }
                } else {
                    Menu {
                        Button { selecting = true } label: { Label("Select", systemImage: "checkmark.circle") }
                        Button { importAssets(assets) } label: {
                            Label("\(verb) All to Folder (\(assets.count))", systemImage: "square.and.arrow.down")
                        }
                    } label: { Image(systemName: "square.and.arrow.down") }
                    .disabled(assets.isEmpty || importing)
                }
            }
        }
    }

    private var importOverlay: some View {
        VStack(spacing: 12) {
            ProgressView(value: Double(importDone), total: Double(max(importTotal, 1)))
                .progressViewStyle(.linear).frame(width: 220)
            Text("\(deleteOriginals ? "Moving" : "Adding") \(importDone) of \(importTotal)…").font(.subheadline)
            Button("Cancel") { importTask?.cancel() }
        }
        .padding(24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func tap(_ asset: PHAsset) {
        if selecting {
            let id = asset.localIdentifier
            if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
        } else {
            selected = asset
        }
    }

    private func toggleAll() {
        if selectedIDs.count == assets.count { selectedIDs.removeAll() }
        else { selectedIDs = Set(assets.map { $0.localIdentifier }) }
    }

    /// Copies the given assets into the target folder (origin-tracked), with a
    /// cancellable progress overlay.
    private func importAssets(_ list: [PHAsset]) {
        guard let folder = targetFolder, !list.isEmpty else { return }
        importing = true; importDone = 0; importTotal = list.count
        importTask = Task {
            // Skip anything already in the destination folder (by origin, or name+size).
            let present = await FileActions.assetsAlreadyInFolder(list, folder: folder, origins: library.photoOrigins)
            let toImport = list.filter { !present.contains($0.localIdentifier) }
            let skipped = list.count - toImport.count
            importTotal = toImport.count; importDone = 0
            guard !toImport.isEmpty else {
                importing = false; selecting = false; selectedIDs.removeAll()
                note = "All \(list.count) already in “\(folder.lastPathComponent)”."
                return
            }
            var saved = 0
            var cancelled = false
            var importedIDs: [String] = []
            // Import several at once — each asset downloads from iCloud before it's
            // written to the drive, so overlapping them is much faster than a loop.
            let maxConcurrent = 5
            await withTaskGroup(of: (id: String, url: URL?).self) { group in
                var i = 0
                func addNext() {
                    guard i < toImport.count, !Task.isCancelled else { return }
                    let asset = toImport[i]; i += 1
                    let id = asset.localIdentifier
                    group.addTask { (id: id, url: await PhotosThumbs.importAsset(asset, to: folder)) }
                }
                for _ in 0..<min(maxConcurrent, toImport.count) { addNext() }
                while let result = await group.next() {
                    if let dest = result.url {
                        library.setOrigin(result.id, for: dest)
                        importedIDs.append(result.id)
                        saved += 1
                    }
                    importDone += 1
                    if Task.isCancelled { cancelled = true; break }
                    addNext()
                }
            }
            library.contentDidChange()

            // Move mode: remove the imported originals from Photos (→ Recently Deleted).
            var removed = false
            if deleteOriginals, !cancelled, !importedIDs.isEmpty {
                removed = await FileActions.deletePhotosAssets(importedIDs)
                await load()                 // refresh the album grid
            }

            importing = false
            selecting = false; selectedIDs.removeAll()
            let extra = skipped > 0 ? " (\(skipped) already here)" : ""
            if cancelled {
                note = "Stopped — \(deleteOriginals ? "moved" : "added") \(saved)." + extra
            } else if deleteOriginals {
                note = removed
                    ? "Moved \(saved) to “\(folder.lastPathComponent)” and removed them from Photos." + extra
                    : "Added \(saved) to “\(folder.lastPathComponent)”; Photos removal was cancelled or failed." + extra
            } else {
                note = "Added \(saved) to “\(folder.lastPathComponent)”." + extra
            }
        }
    }

    private func load() async {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let result = PHAsset.fetchAssets(in: collection, options: options)
        var list: [PHAsset] = []
        list.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in list.append(asset) }
        assets = list
    }
}

/// One square thumbnail backed by a PHAsset.
private struct PhotoAssetCell: View {
    let asset: PHAsset
    var selecting: Bool = false
    var selected: Bool = false
    @State private var image: UIImage?

    var body: some View {
        Rectangle()
            .fill(Color(white: 0.1))
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    GeometryReader { geo in
                        Image(uiImage: image).resizable().scaledToFill()
                            .frame(width: geo.size.width, height: geo.size.height).clipped()
                    }
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if asset.mediaType == .video {
                    Image(systemName: "play.circle.fill").foregroundStyle(.white).shadow(radius: 2).padding(4)
                }
            }
            .overlay { if selecting { selectionOverlay } }
            .clipped()
            .task(id: asset.localIdentifier) {
                image = await PhotosThumbs.thumbnail(for: asset)
            }
    }

    private var selectionOverlay: some View {
        ZStack {
            if selected { Color.accentColor.opacity(0.25) }
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? Color.accentColor : .white)
                        .background(Circle().fill(.black.opacity(0.3)))
                        .padding(5)
                }
            }
        }
    }
}

/// Full-screen view of a single asset, with an optional "Save to Folder".
private struct AssetViewer: View {
    let asset: PHAsset
    let targetFolder: URL?
    @Environment(\.dismiss) private var dismiss
    @Environment(Library.self) private var library

    @State private var image: UIImage?
    @State private var player: AVPlayer?
    @State private var saving = false
    @State private var note: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if asset.mediaType == .video, let player {
                VideoPlayer(player: player).ignoresSafeArea()
            } else if let image {
                Image(uiImage: image).resizable().scaledToFit().ignoresSafeArea()
            } else {
                ProgressView().tint(.white)
            }

            VStack {
                HStack(spacing: 12) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.headline).foregroundStyle(.white)
                            .padding(10).background(.black.opacity(0.45), in: Circle())
                    }
                    Spacer()
                    if targetFolder != nil {
                        Button { save() } label: {
                            Label("Save to Folder", systemImage: "square.and.arrow.down")
                                .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(.black.opacity(0.45), in: Capsule())
                        }.disabled(saving)
                    }
                }
                .padding(.horizontal, 14).padding(.top, 6)
                Spacer()
            }
            if saving { ProgressView().controlSize(.large).tint(.white) }
        }
        .statusBarHidden(true)
        .task { await loadContent() }
        .onDisappear { player?.pause() }
        .alert("Photos", isPresented: Binding(get: { note != nil }, set: { if !$0 { note = nil } })) {
            Button("OK") { note = nil }
        } message: { Text(note ?? "") }
    }

    private func loadContent() async {
        if asset.mediaType == .video {
            player = await PhotosThumbs.playerItem(for: asset).map { AVPlayer(playerItem: $0) }
            player?.play()
        } else {
            image = await PhotosThumbs.fullImage(for: asset)
        }
    }

    private func save() {
        guard let folder = targetFolder else { return }
        saving = true
        Task {
            let dest = await PhotosThumbs.importAsset(asset, to: folder)
            saving = false
            if let dest {
                library.setOrigin(asset.localIdentifier, for: dest)
                library.contentDidChange()
                note = "Saved to “\(folder.lastPathComponent)”."
            } else {
                note = "Couldn’t save this item."
            }
        }
    }
}

/// PhotoKit helpers (thumbnails, full image, video item, single-asset import).
enum PhotosThumbs {
    static func thumbnail(for asset: PHAsset) async -> UIImage? {
        await request(asset, target: CGSize(width: 240, height: 240), mode: .aspectFill)
    }

    static func fullImage(for asset: PHAsset) async -> UIImage? {
        await request(asset, target: PHImageManagerMaximumSize, mode: .aspectFit)
    }

    private static func request(_ asset: PHAsset, target: CGSize, mode: PHImageContentMode) async -> UIImage? {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        return await withCheckedContinuation { (cont: CheckedContinuation<UIImage?, Never>) in
            var resumed = false
            PHImageManager.default().requestImage(for: asset, targetSize: target,
                                                  contentMode: mode, options: options) { img, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if degraded { return }
                if !resumed { resumed = true; cont.resume(returning: img) }
            }
        }
    }

    static func playerItem(for asset: PHAsset) async -> AVPlayerItem? {
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .automatic
        return await withCheckedContinuation { (cont: CheckedContinuation<AVPlayerItem?, Never>) in
            PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { item, _ in
                cont.resume(returning: item)
            }
        }
    }

    static func importAsset(_ asset: PHAsset, to folder: URL) async -> URL? {
        let resources = PHAssetResource.assetResources(for: asset)
        let preferred: [PHAssetResourceType] = [.photo, .video, .fullSizePhoto, .fullSizeVideo]
        let resource = preferred.compactMap { type in resources.first { $0.type == type } }.first ?? resources.first
        guard let resource else { return nil }
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        func write(to dest: URL) async -> Bool {
            await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                PHAssetResourceManager.default().writeData(for: resource, toFile: dest, options: options) { error in
                    cont.resume(returning: error == nil)
                }
            }
        }
        // Stamp the file with the asset's capture date so it sorts by when it was
        // taken, not when it was imported (writeData sets the file's date to "now").
        func finish(_ dest: URL) -> URL {
            if let captured = asset.creationDate {
                try? FileManager.default.setAttributes([.modificationDate: captured], ofItemAtPath: dest.path)
            }
            return dest
        }
        let dest = FileActions.uniqueDestination(for: resource.originalFilename, in: folder)
        if await write(to: dest) { return finish(dest) }
        // Concurrent imports can pick the same name before either file exists; clear
        // any partial write and retry once with a guaranteed-unique name.
        try? FileManager.default.removeItem(at: dest)
        let unique = folder.appendingPathComponent(String(UUID().uuidString.prefix(8)) + "-" + resource.originalFilename)
        return await write(to: unique) ? finish(unique) : nil
    }
}
