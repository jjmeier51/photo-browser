import SwiftUI
import os
import UIKit
import PhotosUI
import UniformTypeIdentifiers

/// IMP-2 picker: one sheet with Drive, Files and Photos tabs. Drive items are referenced in place;
/// Files and Photos items are copied onto the drive. Selection order is timeline order (numbered
/// badges); "Add (n)" confirms. In relink mode it single-selects a file of the missing source's kind.
struct VEImportPicker: View {
    enum Mode: Equatable {
        case add(insertAtPlayhead: Bool)
        case relink(sourceID: String, kind: VEMediaKind)
    }

    let session: VEEditorSession
    let mode: Mode
    @Environment(\.dismiss) private var dismiss
    @State private var tab = 0
    @State private var selected: [URL] = []
    @State private var showFiles = false
    @State private var showPhotos = false
    @State private var preparing: (done: Int, total: Int)?

    private var isRelink: Bool { if case .relink = mode { return true }; return false }
    private var relinkKind: VEMediaKind? { if case .relink(_, let k) = mode { return k }; return nil }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Source", selection: $tab) {
                    Text("Drive").tag(0); Text("Files").tag(1); Text("Photos").tag(2)
                }
                .pickerStyle(.segmented).padding()
                switch tab {
                case 0: VEDriveBrowser(root: session.store.driveRoot, store: session.store, selected: $selected, singleSelect: isRelink, kindFilter: relinkKind)
                case 1: filesTab
                default: photosTab
                }
            }
            .navigationTitle(isRelink ? "Relink Media" : "Add Media")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isRelink ? "Relink" : "Add (\(selected.count))") { confirm(selected) }
                        .disabled(selected.isEmpty)
                }
            }
            .sheet(isPresented: $showFiles) {
                VEDocumentPicker(types: pickerTypes, multiple: !isRelink) { urls in confirm(urls) }
            }
            .sheet(isPresented: $showPhotos) {
                VEPhotosPicker(single: isRelink, imagesOnly: relinkKind == .image, videosOnly: relinkKind == .video) { providers in
                    stagePhotos(providers)
                }
            }
            .overlay {
                if let p = preparing {
                    VStack(spacing: 10) {
                        ProgressView(value: Double(p.done), total: Double(max(1, p.total)))
                        Text("Preparing \(p.done + 1) of \(p.total)…").font(.footnote)
                        Text("Slow-motion and iCloud videos take a moment to come across.").font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(16).frame(width: 260).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    private var pickerTypes: [UTType] {
        switch relinkKind {
        case .image?: return [.image]
        case .video?, .gif?: return [.movie, .video]
        case .audio?: return [.audio]
        case nil: return [.movie, .video, .image, .audio]
        }
    }

    private var filesTab: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "folder").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("Pick videos, photos or audio from Files. Items already on this drive are referenced in place; anything else is copied into the project.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 32)
            Button("Choose from Files…") { showFiles = true }.buttonStyle(.borderedProminent)
            Spacer()
        }
    }

    private var photosTab: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "photo.on.rectangle.angled").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("Pick from your Photos library. No library permission is needed — the items you choose are copied into the project on the drive and nothing stays on the phone. Live Photos import as the still image.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 32)
            Button("Choose from Photos…") { showPhotos = true }.buttonStyle(.borderedProminent)
            Spacer()
        }
    }

    private func confirm(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        switch mode {
        case .add(let atPlayhead):
            session.importURLs(urls, insertAtPlayhead: atPlayhead)
        case .relink(let id, _):
            if let u = urls.first { session.relink(sourceID: id, to: u) }
        }
        dismiss()
    }

    /// IMP-1 Photos: `loadFileRepresentation` hands back a temp copy iOS deletes when the handler
    /// returns, so the copy onto the drive happens synchronously inside the handler, straight into
    /// the project's `media/`; nothing is kept in the sandbox (STO-3).
    private func stagePhotos(_ providers: [NSItemProvider]) {
        guard !providers.isEmpty else { return }
        let mediaDir = VEDriveLayout.media(session.document.packageURL)
        let store = session.store
        preparing = (0, providers.count)
        Task {
            var staged: [URL] = []
            for (i, p) in providers.enumerated() {
                if let url = await Self.stage(p, into: mediaDir, store: store) { staged.append(url) }
                preparing = (i + 1, providers.count)
            }
            preparing = nil
            confirm(staged)
        }
    }

    nonisolated private static func stage(_ provider: NSItemProvider, into dir: URL, store: VEDriveStore) async -> URL? {
        let type: UTType
        if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) { type = .movie }
        else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) { type = .image }
        else { return nil }
        return await withCheckedContinuation { cont in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { tmp, _ in
                guard let tmp else { cont.resume(returning: nil); return }
                do {
                    try DriveWriter.createDirectory(at: dir)
                    let base = VENames.sanitize(tmp.deletingPathExtension().lastPathComponent, fallback: "Photo")
                    let name = VENames.unique(base, ext: tmp.pathExtension, in: dir)
                    let dst = dir.appendingPathComponent(name)
                    store.assertUnderDrive(dst)
                    // Copy into a hidden temp, flush, then rename — must all finish before this handler
                    // returns (iOS deletes `tmp` then), and `dst` only ever appears complete on the drive.
                    let staging = dir.appendingPathComponent(".pbtmp_" + UUID().uuidString)
                    try FileManager.default.copyItem(at: tmp, to: staging)
                    DriveWriter.fullSync(staging)
                    try FileManager.default.moveItem(at: staging, to: dst)
                    DriveWriter.fullSyncFileAndParent(dst)
                    cont.resume(returning: dst)
                } catch {
                    VELog.media.error("Photos import failed: \(error.localizedDescription)")
                    cont.resume(returning: nil)
                }
            }
        }
    }
}

// MARK: - Drive browser (tab 1)

/// Browses the drive folder tree and lists media files with numbered selection badges.
struct VEDriveBrowser: View {
    let root: URL
    let store: VEDriveStore
    @Binding var selected: [URL]
    var singleSelect: Bool
    var kindFilter: VEMediaKind?
    @State private var path: [URL] = []

    var body: some View {
        NavigationStack(path: $path) {
            VEDriveFolderList(folder: root, store: store, selected: $selected, singleSelect: singleSelect, kindFilter: kindFilter, path: $path)
                .navigationDestination(for: URL.self) { url in
                    VEDriveFolderList(folder: url, store: store, selected: $selected, singleSelect: singleSelect, kindFilter: kindFilter, path: $path)
                }
        }
    }
}

struct VEDriveFolderList: View {
    let folder: URL
    let store: VEDriveStore
    @Binding var selected: [URL]
    var singleSelect: Bool
    var kindFilter: VEMediaKind?
    @Binding var path: [URL]
    @State private var entries: [Entry] = []
    @State private var loaded = false

    private let columns = [GridItem(.adaptive(minimum: 92), spacing: 4)]

    var body: some View {
        ScrollView {
            if !loaded { ProgressView().padding(40) }
            else if entries.isEmpty { Text("Nothing here").foregroundStyle(.secondary).padding(40) }
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(entries) { e in
                    if e.isFolder {
                        Button { path.append(e.url) } label: { folderTile(e) }
                    } else {
                        Button { toggle(e.url) } label: { mediaTile(e) }
                    }
                }
            }
            .padding(4)
        }
        .navigationTitle(folder == store.driveRoot ? "Drive" : folder.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: folder) { await load() }
    }

    private func load() async {
        let f = folder
        let st = store
        let filter = kindFilter
        let list: [Entry] = await Task.detached(priority: .userInitiated) {
            let urls = st.contents(of: f, keys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            var out: [Entry] = []
            for u in urls {
                let name = u.lastPathComponent
                if name.hasPrefix(".") || name.hasSuffix(".vep") || name.hasSuffix(".damaged") { continue }
                let rv = try? u.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
                let isDir = rv?.isDirectory ?? false
                let kind: FileKind
                if isDir { kind = .folder } else {
                    let t = UTType(filenameExtension: u.pathExtension)
                    if t?.conforms(to: .movie) == true || t?.conforms(to: .video) == true { kind = .video }
                    else if t?.conforms(to: .image) == true { kind = .image }
                    else if t?.conforms(to: .audio) == true { kind = .audio }
                    else { continue }
                    if let filter {
                        switch filter {
                        case .video, .gif: if kind != .video && !(kind == .image && u.pathExtension.lowercased() == "gif") { continue }
                        case .image: if kind != .image { continue }
                        case .audio: if kind != .audio { continue }
                        }
                    }
                }
                out.append(Entry(url: u, name: name, kind: kind, size: Int64(rv?.fileSize ?? 0), modified: rv?.contentModificationDate ?? .distantPast))
            }
            // Stored `kind`, not the main-actor computed `isFolder`: this runs off-main.
            return out.sorted { a, b in
                let af = a.kind == .folder, bf = b.kind == .folder
                if af != bf { return af }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }.value
        entries = list
        loaded = true
    }

    private func toggle(_ url: URL) {
        if let i = selected.firstIndex(of: url) { selected.remove(at: i) }
        else if singleSelect { selected = [url] }
        else { selected.append(url) }
    }

    private func folderTile(_ e: Entry) -> some View {
        VStack(spacing: 4) {
            Image(systemName: "folder.fill").font(.system(size: 30)).foregroundStyle(.secondary).frame(height: 60)
            Text(e.name).font(.caption2).lineLimit(2).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(6)
        .background(Color(white: 0.14), in: RoundedRectangle(cornerRadius: 8))
        .foregroundStyle(.primary)
    }

    private func mediaTile(_ e: Entry) -> some View {
        let idx = selected.firstIndex(of: e.url)
        return ZStack(alignment: .topTrailing) {
            VEEntryThumb(entry: e)
                .frame(height: 92)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(idx == nil ? Color.clear : Color.accentColor, lineWidth: 3))
            if let idx {
                Text("\(idx + 1)").font(.caption2.bold()).foregroundStyle(.white)
                    .frame(width: 22, height: 22).background(Color.accentColor, in: Circle()).padding(4)
            }
            if e.kind == .video {
                VStack { Spacer(); HStack { Image(systemName: "video.fill").font(.caption2).padding(4); Spacer() } }
            }
        }
    }
}

/// Thumbnail for a drive item via the browser's cache (audio shows a waveform glyph).
struct VEEntryThumb: View {
    let entry: Entry
    @State private var image: UIImage?
    var body: some View {
        ZStack {
            Color(white: 0.16)
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else if entry.kind == .audio { Image(systemName: "waveform").font(.title2).foregroundStyle(.secondary) }
        }
        .clipped()
        .task(id: entry.url) {
            guard entry.kind != .audio else { return }
            image = await Thumbnailer.shared.thumbnail(for: entry, size: CGSize(width: 120, height: 120), scale: 2)
        }
    }
}

// MARK: - System pickers

struct VEDocumentPicker: UIViewControllerRepresentable {
    let types: [UTType]
    var multiple: Bool
    var onPick: ([URL]) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let p = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: false)
        p.allowsMultipleSelection = multiple
        p.delegate = context.coordinator
        return p
    }
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void
        init(onPick: @escaping ([URL]) -> Void) { self.onPick = onPick }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { onPick(urls) }
    }
}

struct VEPhotosPicker: UIViewControllerRepresentable {
    var single: Bool
    var imagesOnly: Bool
    var videosOnly: Bool
    var onPick: ([NSItemProvider]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.selectionLimit = single ? 1 : 0
        config.preferredAssetRepresentationMode = .current
        config.filter = imagesOnly ? .images : (videosOnly ? .videos : .any(of: [.images, .videos]))
        if !single { config.selection = .ordered }
        let p = PHPickerViewController(configuration: config)
        p.delegate = context.coordinator
        return p
    }
    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPick: ([NSItemProvider]) -> Void
        init(onPick: @escaping ([NSItemProvider]) -> Void) { self.onPick = onPick }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            onPick(results.map(\.itemProvider))
        }
    }
}
