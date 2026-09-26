import SwiftUI
import ImageIO
import CryptoKit
import UIKit

/// The **Astria.ai Browser**: every image the account has ever generated (across Edit, Create,
/// Extend and the Astria web UI), newest first, grouped by prompt. Tap to preview at full size;
/// tap Select to pick many. Any image can be saved into any folder on the drive — the last
/// destination is remembered and offered as a one-tap "Save to <folder>" next time. Read-only over
/// the network: it only lists and downloads; nothing is uploaded.
///
/// Thumbnails are the full result images downsampled once and cached on disk
/// (`AstriaImageCache`), so a second visit is instant and scrolling never re-downloads.
struct AstriaBrowserView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    /// The folder the browser was opened from — the default destination when nothing is remembered.
    let currentFolder: URL

    @State private var prompts: [AIExtend.AstriaPrompt] = []
    @State private var tunes: [AIExtend.AstriaTune] = []
    @State private var loading = true
    @State private var note: String?
    @State private var selecting = false
    @State private var selected: Set<String> = []          // AstriaImageRef ids
    @State private var preview: AstriaImageRef?
    @State private var pendingSave: [AstriaImageRef] = []   // waiting on the folder picker
    @State private var showFolderPicker = false
    @State private var saving: String?                      // progress line while saving
    @State private var savedNote: String?                   // completion alert
    @State private var showSettings = false

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 3)]

    /// Flat list of every image, in display order.
    private var refs: [AstriaImageRef] {
        prompts.flatMap { p in p.images.indices.map { AstriaImageRef(prompt: p, index: $0) } }
    }

    var body: some View {
        NavigationStack {
            Group {
                if !AIExtend.isConfigured {
                    ContentUnavailableView {
                        Label("No Astria API key", systemImage: "key")
                    } description: {
                        Text("Add your Astria API key in Settings to browse your past generations.")
                    } actions: {
                        Button("Open Settings") { showSettings = true }.buttonStyle(.borderedProminent)
                    }
                } else if loading && prompts.isEmpty {
                    ProgressView("Loading your Astria generations…")
                } else if prompts.isEmpty {
                    ContentUnavailableView {
                        Label("Nothing generated yet", systemImage: "wand.and.stars")
                    } description: {
                        Text(note ?? "Images you generate with Edit, Create or Extend with AI will show up here.")
                    } actions: {
                        Button("Reload") { Task { await load(force: true) } }.buttonStyle(.bordered)
                    }
                } else {
                    grid
                }
            }
            .navigationTitle(selecting ? "\(selected.count) selected" : "Astria.ai Browser")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.disabled(saving != nil)
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    if !prompts.isEmpty {
                        Button(selecting ? "Cancel" : "Select") {
                            selecting.toggle()
                            if !selecting { selected = [] }
                        }
                    }
                    Button { Task { await load(force: true) } } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(loading)
                }
            }
            .safeAreaInset(edge: .bottom) { if selecting && !selected.isEmpty { selectionBar } }
            .overlay { if let saving { savingOverlay(saving) } }
            .sheet(item: $preview) { ref in
                AstriaImagePreview(ref: ref, modelName: modelName(for: ref.prompt),
                                   saved: library.astriaSavedImages[ref.url.absoluteString] != nil,
                                   lastFolder: library.astriaSaveFolder) { destination in
                    switch destination {
                    case .pick:
                        // The preview sheet is still dismissing; presenting the picker during that
                        // gets swallowed — defer past the transition.
                        pendingSave = [ref]
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { showFolderPicker = true }
                    case .folder(let folder):
                        save([ref], to: folder)
                    }
                }
                .environment(library)
            }
            .sheet(isPresented: $showFolderPicker) {
                if let root = library.rootURL {
                    FolderPicker(root: root, confirmTitle: "Save Here",
                                 startAt: library.astriaSaveFolder ?? currentFolder) { dest in
                        let refs = pendingSave; pendingSave = []
                        save(refs, to: dest)
                    }
                    .environment(library)
                }
            }
            .sheet(isPresented: $showSettings, onDismiss: { Task { await load(force: true) } }) { SettingsView() }
            .alert("Saved", isPresented: Binding(get: { savedNote != nil }, set: { if !$0 { savedNote = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(savedNote ?? "") }
            .task { await load(force: false) }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Grid

    private var grid: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18, pinnedViews: []) {
                if let note {
                    Text(note).font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
                }
                ForEach(prompts) { p in
                    if !p.images.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            promptHeader(p)
                            LazyVGrid(columns: columns, spacing: 3) {
                                ForEach(p.images.indices, id: \.self) { i in
                                    let ref = AstriaImageRef(prompt: p, index: i)
                                    AstriaThumbCell(ref: ref,
                                                    selecting: selecting,
                                                    selected: selected.contains(ref.id),
                                                    saved: library.astriaSavedImages[ref.url.absoluteString] != nil)
                                        .onTapGesture { tap(ref) }
                                        .contextMenu { contextMenu(for: ref) }
                                }
                            }
                        }
                    }
                }
                if loading { HStack { Spacer(); ProgressView(); Spacer() }.padding() }
            }
            .padding(.vertical, 8)
        }
    }

    private func promptHeader(_ p: AIExtend.AstriaPrompt) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(modelName(for: p)).font(.caption.weight(.semibold))
                if let d = p.createdAt {
                    Text(d.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if selecting {
                    Button(allSelected(p) ? "Deselect All" : "Select All") { toggleAll(p) }
                        .font(.caption).buttonStyle(.bordered).controlSize(.mini)
                }
            }
            if !p.text.isEmpty {
                Text(p.text).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.horizontal, 12)
    }

    @ViewBuilder
    private func contextMenu(for ref: AstriaImageRef) -> some View {
        if let last = library.astriaSaveFolder {
            Button { save([ref], to: last) } label: {
                Label("Save to “\(last.lastPathComponent)”", systemImage: "square.and.arrow.down")
            }
        }
        Button { pendingSave = [ref]; showFolderPicker = true } label: {
            Label("Save to Folder…", systemImage: "folder")
        }
        Button { UIPasteboard.general.string = ref.prompt.text } label: {
            Label("Copy Prompt", systemImage: "doc.on.doc")
        }
    }

    private var selectionBar: some View {
        HStack(spacing: 10) {
            if let last = library.astriaSaveFolder {
                Button { save(selectedRefs, to: last) } label: {
                    Label("Save to “\(last.lastPathComponent)”", systemImage: "square.and.arrow.down")
                        .lineLimit(1).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            pickFolderButton(prominent: library.astriaSaveFolder == nil) {
                pendingSave = selectedRefs; showFolderPicker = true
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .disabled(saving != nil)
    }

    /// "Save to Folder…" — prominent only when there's no remembered folder to be the primary action.
    /// (A ternary between two button styles doesn't type-check, hence the branch.)
    @ViewBuilder
    private func pickFolderButton(prominent: Bool, action: @escaping () -> Void) -> some View {
        if prominent {
            Button(action: action) { Label("Save to Folder…", systemImage: "folder").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent)
        } else {
            Button(action: action) { Label("Save to Folder…", systemImage: "folder").frame(maxWidth: .infinity) }
                .buttonStyle(.bordered)
        }
    }

    private func savingOverlay(_ line: String) -> some View {
        VStack(spacing: 12) {
            ProgressView().tint(.white)
            Text(line).font(.callout.weight(.medium)).foregroundStyle(.white)
        }
        .padding(24)
        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Selection

    private var selectedRefs: [AstriaImageRef] { refs.filter { selected.contains($0.id) } }
    private func allSelected(_ p: AIExtend.AstriaPrompt) -> Bool {
        p.images.indices.allSatisfy { selected.contains(AstriaImageRef(prompt: p, index: $0).id) }
    }
    private func toggleAll(_ p: AIExtend.AstriaPrompt) {
        let ids = p.images.indices.map { AstriaImageRef(prompt: p, index: $0).id }
        if allSelected(p) { ids.forEach { selected.remove($0) } } else { ids.forEach { selected.insert($0) } }
    }
    private func tap(_ ref: AstriaImageRef) {
        if selecting {
            if selected.contains(ref.id) { selected.remove(ref.id) } else { selected.insert(ref.id) }
        } else {
            preview = ref
        }
    }

    private func modelName(for p: AIExtend.AstriaPrompt) -> String {
        AIExtend.modelName(forTune: p.tuneID, tunes: tunes)
    }

    // MARK: - Loading

    private func load(force: Bool) async {
        guard AIExtend.isConfigured else { loading = false; return }
        loading = true; note = nil
        tunes = await library.loadAITunes(force: force)      // cached ~2 min; names the tune each prompt ran on
        let p = await AIExtend.listPrompts()
        prompts = p
        loading = false
        if p.isEmpty {
            note = "Nothing came back from Astria. Check your API key in Settings, or pull to reload once you're back online."
        }
    }

    // MARK: - Saving

    /// Downloads each image (full size, validated) and writes it into `folder` with the prompt's
    /// date and provenance. Runs the downloads + file writes off the main actor; the folder is
    /// remembered as the next default. Images already saved are saved again only if the user
    /// explicitly picked them (the badge tells them).
    private func save(_ refs: [AstriaImageRef], to folder: URL) {
        guard !refs.isEmpty, saving == nil else { return }
        library.setAstriaSaveFolder(folder)
        let lib = library
        Task {
            var savedCount = 0, failed = 0
            for (n, ref) in refs.enumerated() {
                saving = "Saving \(n + 1) of \(refs.count) to “\(folder.lastPathComponent)”…"
                let url = ref.url, text = ref.prompt.text, date = ref.prompt.createdAt
                let model = modelName(for: ref.prompt)
                let dest: URL? = await Task.detached(priority: .userInitiated) { () -> URL? in
                    guard let data = await AstriaImageCache.fullImage(for: url) else { return nil }
                    return AIExtend.saveGeneratedToFolder(data, in: folder, model: model, prompt: text,
                                                          date: date, intoAISubfolder: false)
                }.value
                if let dest {
                    savedCount += 1
                    lib.markAIGenerated(dest, model: model, prompt: text)
                    lib.markAstriaImageSaved(url, as: dest)
                } else {
                    failed += 1
                }
            }
            saving = nil
            if savedCount > 0 { lib.contentDidChange(under: folder) }
            selected = []; selecting = false
            savedNote = failed == 0
                ? "\(savedCount) image\(savedCount == 1 ? "" : "s") saved to “\(folder.lastPathComponent)”."
                : "\(savedCount) saved to “\(folder.lastPathComponent)”; \(failed) couldn’t be downloaded — try again in a moment."
        }
    }
}

/// One image of one prompt — the unit the browser selects, previews and saves.
struct AstriaImageRef: Identifiable, Hashable {
    let prompt: AIExtend.AstriaPrompt
    let index: Int
    var url: URL { prompt.images[index] }
    var id: String { "\(prompt.id):\(index)" }
}

/// Where the preview's Save should go.
enum AstriaSaveDestination {
    case pick                 // open the folder picker
    case folder(URL)          // the remembered folder
}

// MARK: - Cells

private struct AstriaThumbCell: View {
    let ref: AstriaImageRef
    let selecting: Bool
    let selected: Bool
    let saved: Bool
    @State private var image: UIImage?

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Rectangle().fill(.quaternary).overlay { ProgressView().controlSize(.small) }
                }
            }
            .clipped()
            .overlay(alignment: .topTrailing) {
                if selecting {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(selected ? Color.accentColor : .white)
                        .shadow(radius: 2)
                        .padding(6)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if saved {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.caption).foregroundStyle(.green)
                        .padding(4)
                        .background(.black.opacity(0.45), in: Circle())
                        .padding(4)
                        .accessibilityLabel("Saved to the drive")
                }
            }
            .overlay { if selecting && selected { Color.accentColor.opacity(0.25) } }
            .contentShape(Rectangle())
            .task(id: ref.id) {
                if image == nil { image = await AstriaImageCache.thumbnail(for: ref.url) }
            }
    }
}

/// Full-size preview of one generated image, with its prompt and a Save action.
private struct AstriaImagePreview: View {
    @Environment(\.dismiss) private var dismiss
    let ref: AstriaImageRef
    let modelName: String
    let saved: Bool
    let lastFolder: URL?
    let onSave: (AstriaSaveDestination) -> Void
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                ZStack {
                    if let image {
                        Image(uiImage: image).resizable().scaledToFit()
                    } else if failed {
                        ContentUnavailableView("Couldn’t load this image", systemImage: "exclamationmark.triangle")
                    } else {
                        ProgressView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(modelName).font(.caption.weight(.semibold))
                        if let d = ref.prompt.createdAt {
                            Text(d.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if saved { Label("On the drive", systemImage: "checkmark.seal.fill").font(.caption).foregroundStyle(.green) }
                    }
                    if !ref.prompt.text.isEmpty {
                        ScrollView { Text(ref.prompt.text).font(.footnote).foregroundStyle(.secondary) }
                            .frame(maxHeight: 90)
                    }
                }
                .padding(.horizontal)
                HStack(spacing: 10) {
                    if let lastFolder {
                        Button { onSave(.folder(lastFolder)); dismiss() } label: {
                            Label("Save to “\(lastFolder.lastPathComponent)”", systemImage: "square.and.arrow.down")
                                .lineLimit(1).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        Button { onSave(.pick); dismiss() } label: {
                            Label("Save to Folder…", systemImage: "folder").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Button { onSave(.pick); dismiss() } label: {
                            Label("Save to Folder…", systemImage: "folder").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding([.horizontal, .bottom])
            }
            .navigationTitle("Astria Image")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { UIPasteboard.general.string = ref.prompt.text } label: { Image(systemName: "doc.on.doc") }
                        .disabled(ref.prompt.text.isEmpty)
                }
            }
            .task {
                let url = ref.url
                let ui = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                    guard let data = await AstriaImageCache.fullImage(for: url) else { return nil }
                    return AstriaImageCache.decode(data, maxPixel: 2200)
                }.value
                if let ui { image = ui } else { failed = true }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Cache

/// Thumbnails and full images for the Astria browser. Everything is `nonisolated` — downloads,
/// ImageIO decodes and the disk cache must stay off the main actor. Thumbnails (≤ 480 px JPEG) are
/// kept in Caches/`astriaThumbs`, keyed by the SHA-256 of the image URL (result URLs are stable per
/// image), plus an in-memory `NSCache` so scrolling back is free. Full images are cached in memory
/// only (a handful, by cost) — saving pulls them once.
nonisolated enum AstriaImageCache {
    private static let memoryThumbs: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>(); c.countLimit = 600; return c
    }()
    private static let memoryFull: NSCache<NSString, NSData> = {
        let c = NSCache<NSString, NSData>(); c.totalCostLimit = 160 * 1024 * 1024; return c
    }()
    static let thumbSide: CGFloat = 480

    static var directory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("astriaThumbs", isDirectory: true)
    }

    private static func key(_ url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// A display thumbnail: memory → disk → download + downsample (then written back to disk).
    static func thumbnail(for url: URL) async -> UIImage? {
        let k = key(url)
        if let hit = memoryThumbs.object(forKey: k as NSString) { return hit }
        let file = directory.appendingPathComponent(k).appendingPathExtension("jpg")
        let fromDisk: UIImage? = await Task.detached(priority: .utility) {
            guard let d = try? Data(contentsOf: file), let ui = decode(d, maxPixel: thumbSide) else { return nil }
            return ui
        }.value
        if let fromDisk { memoryThumbs.setObject(fromDisk, forKey: k as NSString); return fromDisk }
        guard let data = await fullImage(for: url) else { return nil }
        let made: UIImage? = await Task.detached(priority: .utility) {
            guard let ui = decode(data, maxPixel: thumbSide) else { return nil }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let jpeg = ui.jpegData(compressionQuality: 0.82) { try? jpeg.write(to: file, options: .atomic) }
            return ui
        }.value
        if let made { memoryThumbs.setObject(made, forKey: k as NSString) }
        return made
    }

    /// The full result image bytes (validated by the shared downloader; retried on transient errors).
    static func fullImage(for url: URL) async -> Data? {
        let k = url.absoluteString as NSString
        if let hit = memoryFull.object(forKey: k) { return hit as Data }
        guard let data = await AIExtend.downloadImage(url) else { return nil }
        memoryFull.setObject(data as NSData, forKey: k, cost: data.count)
        return data
    }

    /// ImageIO downsample to `maxPixel` on the long side, fully decoded (no main-thread work at draw).
    static func decode(_ data: Data, maxPixel: CGFloat) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}
