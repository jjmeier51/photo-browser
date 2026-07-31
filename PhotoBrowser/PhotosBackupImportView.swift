import SwiftUI
import ImageIO
import AVFoundation
import UniformTypeIdentifiers

/// "Import from Mac Photos Backup" — a sibling of `DriveTransferView` tuned for a folder of files
/// exported from an old Mac Photos Library. Those exports mix full-size originals with smaller
/// **preview** copies (`IMG_1234.jpg` alongside `IMG_1234_preview.jpg` / `IMG_1234preview.jpg`).
///
/// The importer:
///  • recursively finds every photo/video under the picked source folder,
///  • copies (or moves) the non-duplicate/non-preview ones into the current folder, preserving the
///    embedded EXIF/QuickTime metadata (byte copy) and setting the **displayed** capture date to the
///    OLDER of each file's Created/Modified date (written into the file so the app shows it), and
///  • at the end lists every file that already has a match here — an exact duplicate, or a preview
///    whose original is already present — with thumbnails/size/dimensions/date and a Select-All /
///    some / none picker, so the user can still bring over the ones they want.
///
/// Matching is by base filename (preview suffix stripped) **and** date, so `IMG_1234_preview.jpg`
/// is recognized as the preview of an already-present `IMG_1234.jpg`, while a coincidental
/// same-number photo from a different day is not.
struct PhotosBackupImportView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(Library.self) private var library
    let source: URL
    let destination: URL

    private enum Phase { case scanning, confirm, working, review, done }
    @State private var phase: Phase = .scanning
    @State private var toMove: [PhotosBackupImporter.ScanItem] = []
    @State private var held: [PhotosBackupImporter.HeldItem] = []
    @State private var selectedHeld = Set<UUID>()
    @State private var deleteOriginals = false

    @State private var progress: Double = 0
    @State private var statusLine = ""
    @State private var movedCount = 0
    @State private var failedCount = 0
    @State private var importError: String?
    @State private var resultText = ""

    @State private var accessing = false
    @State private var bgTask = BackgroundTaskHolder()

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .scanning: scanningView
                case .confirm:  confirmView
                case .working:  workingView
                case .review:   reviewView
                case .done:     doneView
                }
            }
            .navigationTitle("Import Photos Backup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if phase == .confirm || phase == .scanning {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                }
                if phase == .review {
                    ToolbarItem(placement: .topBarTrailing) { Button("Done") { finish() } }
                }
            }
            .interactiveDismissDisabled(phase == .working)
            .task { await beginScan() }
            .onDisappear { releaseAccess() }
        }
    }

    // MARK: - Phase views

    private var scanningView: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text("Scanning “\(source.lastPathComponent)”…").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var confirmView: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "photo.on.rectangle.angled").font(.system(size: 52)).foregroundStyle(.tint)
            Text(headline).font(.headline).multilineTextAlignment(.center)
            Text(subhead).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .padding(.horizontal, 26)
            if toMove.isEmpty && held.isEmpty {
                Button("Done") { dismiss() }.buttonStyle(.borderedProminent).padding(.top, 6)
            } else {
                VStack(spacing: 10) {
                    if !toMove.isEmpty {
                        Button { start(delete: false) } label: {
                            Text("Copy Here (keep originals)").frame(maxWidth: .infinity)
                        }.buttonStyle(.borderedProminent)
                        Button(role: .destructive) { start(delete: true) } label: {
                            Text("Move Here (delete originals)").frame(maxWidth: .infinity)
                        }.buttonStyle(.bordered)
                    } else {
                        // Nothing new to auto-import — go straight to reviewing the matches.
                        Button { deleteOriginals = false; phase = .review } label: {
                            Text("Review \(held.count) matching item(s)…").frame(maxWidth: .infinity)
                        }.buttonStyle(.borderedProminent)
                    }
                }
                .padding(.horizontal, 34).padding(.top, 6)
            }
            Spacer()
        }
        .padding()
    }

    private var workingView: some View {
        VStack(spacing: 18) {
            Spacer()
            ProgressView(value: progress).progressViewStyle(.linear).frame(width: 250)
            Text("\(Int(progress * 100))%").font(.headline.monospacedDigit())
            Text(statusLine.isEmpty ? "Importing…" : statusLine)
                .font(.subheadline).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).frame(maxWidth: 280)
            Text("Keep the backup drive connected.").font(.caption2).foregroundStyle(.tertiary)
            Spacer()
        }
        .padding()
    }

    @ViewBuilder private var reviewView: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(selectedHeld.count) of \(held.count) selected").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Button(selectedHeld.count == held.count ? "Deselect All" : "Select All") {
                    selectedHeld = selectedHeld.count == held.count ? [] : Set(held.map { $0.id })
                }.font(.subheadline)
            }
            .padding(.horizontal).padding(.vertical, 8)

            List {
                Section {
                    ForEach(held) { h in
                        Button { toggle(h.id) } label: {
                            HeldRow(held: h, selected: selectedHeld.contains(h.id))
                        }
                        .buttonStyle(.plain)
                    }
                } footer: {
                    Text("These already have a matching item in “\(destination.lastPathComponent)” — an exact duplicate, or a preview whose original is already here. Select any you still want to bring over.")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button { moveSelectedHeld() } label: {
                Text(selectedHeld.isEmpty ? "Skip — none of these" : "\(deleteOriginals ? "Move" : "Copy") \(selectedHeld.count) Selected")
                    .fontWeight(.semibold).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .padding()
            .background(.ultraThinMaterial)
        }
    }

    private var doneView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.circle.fill").font(.system(size: 52)).foregroundStyle(.green)
            Text(resultText).font(.headline).multilineTextAlignment(.center).padding(.horizontal, 24)
            Button("Done") { dismiss() }.buttonStyle(.borderedProminent).padding(.top, 6)
            Spacer()
        }
        .padding()
    }

    private var headline: String {
        if toMove.isEmpty && held.isEmpty { return "No photos or videos found in “\(source.lastPathComponent)”." }
        if toMove.isEmpty { return "Everything here already has a match in “\(destination.lastPathComponent)”." }
        return "Import \(toMove.count) item\(toMove.count == 1 ? "" : "s") into “\(destination.lastPathComponent)”?"
    }
    private var subhead: String {
        var parts: [String] = []
        if !toMove.isEmpty {
            parts.append("EXIF and dates are preserved; each item's shown date is the older of its Created/Modified date.")
        }
        if !held.isEmpty {
            parts.append("\(held.count) file\(held.count == 1 ? "" : "s") already have a matching item here (a duplicate or a preview of an original that's already present) — you'll review those next.")
        }
        return parts.joined(separator: " ")
    }

    // MARK: - Actions

    private func beginScan() async {
        guard phase == .scanning else { return }
        if !accessing { accessing = source.startAccessingSecurityScopedResource() }
        let result = await PhotosBackupImporter.scan(source: source, destination: destination)
        toMove = result.toMove
        held = result.held
        phase = .confirm
    }

    private func start(delete: Bool) {
        deleteOriginals = delete
        phase = .working
        progress = 0
        bgTask.begin(name: "Import Photos Backup")
        let items = toMove
        Task {
            let r = await PhotosBackupImporter.move(items, into: destination, deleteOriginals: delete) { frac, name in
                Task { @MainActor in progress = frac; statusLine = name.isEmpty ? "" : "Importing \(name)" }
            }
            movedCount += r.moved
            failedCount += r.failed
            if let reason = r.reason { importError = reason }
            library.contentDidChange(under: destination)
            if held.isEmpty {
                finish()
            } else {
                phase = .review
            }
        }
    }

    private func toggle(_ id: UUID) {
        if selectedHeld.contains(id) { selectedHeld.remove(id) } else { selectedHeld.insert(id) }
    }

    private func moveSelectedHeld() {
        let chosen = held.filter { selectedHeld.contains($0.id) }.map { $0.item }
        guard !chosen.isEmpty else { finish(); return }
        phase = .working
        progress = 0
        bgTask.begin(name: "Import Photos Backup")
        Task {
            let r = await PhotosBackupImporter.move(chosen, into: destination, deleteOriginals: deleteOriginals) { frac, name in
                Task { @MainActor in progress = frac; statusLine = name.isEmpty ? "" : "Importing \(name)" }
            }
            movedCount += r.moved
            failedCount += r.failed
            if let reason = r.reason { importError = reason }
            library.contentDidChange(under: destination)
            finish()
        }
    }

    private func finish() {
        let verb = deleteOriginals ? "Moved" : "Copied"
        if movedCount == 0 {
            resultText = failedCount > 0
                ? "Couldn’t import \(failedCount) item\(failedCount == 1 ? "" : "s")\(importError.map { " — \($0)" } ?? ".")"
                : "Nothing was imported."
        } else {
            resultText = "\(verb) \(movedCount) item\(movedCount == 1 ? "" : "s")"
                + (failedCount > 0 ? ", \(failedCount) couldn’t be imported\(importError.map { " (\($0))" } ?? "")." : ", with EXIF and dates kept.")
        }
        phase = .done
    }

    private func releaseAccess() {
        if accessing { source.stopAccessingSecurityScopedResource(); accessing = false }
        bgTask.end()
    }
}

/// One held (duplicate / preview) row: thumbnail, name, size · dimensions · date, a match badge,
/// and a selection check. Thumbnail + dimensions load lazily (off-main), like the duplicates view.
private struct HeldRow: View {
    let held: PhotosBackupImporter.HeldItem
    let selected: Bool
    @State private var image: UIImage?
    @State private var dims = "—"

    private var entry: Entry {
        Entry(url: held.item.url, name: held.item.name, kind: held.item.kind,
              size: held.item.size, modified: held.item.older)
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                if let image { Image(uiImage: image).resizable().scaledToFill() }
                else { Rectangle().fill(.quaternary).overlay { Image(systemName: held.item.kind.systemImage).foregroundStyle(.secondary) } }
            }
            .frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 3) {
                Text(held.item.name).font(.subheadline.weight(.medium)).lineLimit(1)
                Text("\(held.item.size.sizeString) · \(dims) · \(held.item.older.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Label(held.matchKind == .exactDuplicate ? "Duplicate of \(held.matchName)" : "Preview of \(held.matchName)",
                      systemImage: held.matchKind == .exactDuplicate ? "doc.on.doc" : "photo.badge.checkmark")
                    .font(.caption2).foregroundStyle(held.matchKind == .exactDuplicate ? Color.orange : Color.blue).lineLimit(1)
            }
            Spacer()
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.title3).foregroundStyle(selected ? Color.accentColor : Color.secondary)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .task(id: held.id) {
            image = await Thumbnailer.shared.thumbnail(for: entry, size: CGSize(width: 56, height: 56), scale: UIScreen.main.scale)
            let spec = await MetadataLoader.mediaSpec(for: entry)
            if spec.longSide > 0 { dims = "\(spec.longSide) × \(spec.pixels / spec.longSide)" }
        }
    }
}

/// The off-main scan / classify / move engine for `PhotosBackupImportView`. `nonisolated` — all
/// heavy filesystem work stays off the main actor.
enum PhotosBackupImporter {
    struct ScanItem: Identifiable, Sendable {
        let id = UUID()
        let url: URL
        let name: String
        let size: Int64
        let kind: FileKind
        let older: Date          // min(created, modified) — the date the app is made to display
        let isPreview: Bool
        let base: String         // lowercased base filename (preview suffix stripped), for matching
    }
    enum MatchKind: Sendable { case exactDuplicate, relatedPreview }
    struct HeldItem: Identifiable, Sendable {
        let id = UUID()
        let item: ScanItem
        let matchKind: MatchKind
        let matchName: String
    }

    /// Splits a filename into (isPreview, base). Recognizes `_preview` / `-preview` / ` preview` /
    /// `preview` suffixes (case-insensitive). `IMG_1234_preview.jpg` and `IMG_1234preview.jpg` → base
    /// `IMG_1234`. A bare `preview.jpg` is not treated as a preview (no base to tie it to).
    nonisolated static func previewInfo(_ name: String) -> (isPreview: Bool, base: String) {
        let stem = (name as NSString).deletingPathExtension
        let lower = stem.lowercased()
        for marker in ["_preview", "-preview", " preview", "preview"] where lower.hasSuffix(marker) {
            let base = String(stem.dropLast(marker.count)).trimmingCharacters(in: CharacterSet(charactersIn: "_- "))
            if !base.isEmpty { return (true, base) }
        }
        return (false, stem)
    }

    /// Two dates count as the same capture when within a day — tight enough to reject a coincidental
    /// same-numbered photo from another year, loose enough for export date quirks (originals and
    /// their previews share a capture date, so in practice they're within seconds).
    nonisolated private static let dateTolerance: TimeInterval = 24 * 3600

    /// Recursively lists the source's photos/videos and classifies each against what's already in
    /// `destination`: `toMove` (bring over) vs `held` (already has a duplicate/preview match here).
    nonisolated static func scan(source: URL, destination: URL) async -> (toMove: [ScanItem], held: [HeldItem]) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey]

        func scanItem(_ url: URL) -> ScanItem? {
            // Never import Photos-library sidecars — `.xmp` (metadata) and `.aae` (Apple edit
            // instructions) sit next to the media but aren't media themselves.
            let ext = url.pathExtension.lowercased()
            guard ext != "xmp", ext != "aae" else { return nil }
            let kind = classify(url: url, isDirectory: false)
            guard kind == .image || kind == .video else { return nil }
            let vals = try? url.resourceValues(forKeys: Set(keys))
            let created = vals?.creationDate ?? Date()
            let modified = vals?.contentModificationDate ?? created
            let name = url.lastPathComponent
            let (isPrev, base) = previewInfo(name)
            return ScanItem(url: url, name: name, size: Int64(vals?.fileSize ?? 0), kind: kind,
                            older: min(created, modified), isPreview: isPrev, base: base.lowercased())
        }

        // 1) Every media file under the source, recursively.
        var sources: [ScanItem] = []
        if let en = fm.enumerator(at: source, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) {
            for case let url as URL in en {
                if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                   let item = scanItem(url) { sources.append(item) }
            }
        }

        // 2) Index the destination's existing media by base name.
        var targetByBase: [String: [(name: String, older: Date)]] = [:]
        if let items = try? fm.contentsOfDirectory(at: destination, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) {
            for url in items {
                guard let item = scanItem(url) else { continue }
                targetByBase[item.base, default: []].append((item.name, item.older))
            }
        }

        // 3) Classify. Originals first, so a preview can match an original we move in this run.
        let ordered = sources.sorted { a, b in
            a.isPreview != b.isPreview ? (!a.isPreview) : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        func close(_ x: Date, _ y: Date) -> Bool { abs(x.timeIntervalSince(y)) < dateTolerance }

        var toMove: [ScanItem] = []
        var held: [HeldItem] = []
        for item in ordered {
            let candidates = targetByBase[item.base] ?? []
            if let dup = candidates.first(where: { $0.name.lowercased() == item.name.lowercased() && close($0.older, item.older) }) {
                held.append(HeldItem(item: item, matchKind: .exactDuplicate, matchName: dup.name))
                continue
            }
            if item.isPreview, let sib = candidates.first(where: { close($0.older, item.older) }) {
                held.append(HeldItem(item: item, matchKind: .relatedPreview, matchName: sib.name))
                continue
            }
            toMove.append(item)
            targetByBase[item.base, default: []].append((item.name, item.older))   // so later previews match it
        }
        return (toMove, held)
    }

    /// Copies (or moves) each item into `destination`, preserving embedded EXIF/QuickTime (byte copy)
    /// and setting the displayed capture date + filesystem dates to `item.older`. Reports (fraction,
    /// currentName). Collisions get a unique name. `reason` names the first failure (surfaced to the
    /// user) so a folder that imports nothing doesn't just say "nothing" without saying why.
    nonisolated static func move(_ items: [ScanItem], into destination: URL, deleteOriginals: Bool,
                                 progress: @escaping @Sendable (Double, String) -> Void) async -> (moved: Int, failed: Int, reason: String?) {
        let fm = FileManager.default
        try? fm.createDirectory(at: destination, withIntermediateDirectories: true)
        var moved = 0, failed = 0
        var reason: String?
        for (i, item) in items.enumerated() {
            progress(Double(i) / Double(max(items.count, 1)), item.name)
            let target = FileActions.uniqueDestination(for: item.name, in: destination)
            // Read through NSFileCoordinator so a source that lives in iCloud Drive / a file provider
            // (these Photos backups usually do) is DOWNLOADED before we copy it. A plain copyItem on a
            // not-yet-materialized placeholder fails (Files "error 100092"), which is why nothing imported.
            if let why = copyCoordinated(from: item.url, to: target) {
                failed += 1; if reason == nil { reason = why }
                continue
            }
            // Make the app show the older-of-created/modified date: write it into the file's capture
            // metadata (lossless — the rest of the EXIF/QuickTime is untouched), then mirror it onto
            // the filesystem dates (the metadata rewrite resets those). Off-main throughout.
            if item.kind == .image { stampImageDate(item.older, into: target) }
            else if item.kind == .video { await stampVideoDate(item.older, into: target) }
            try? fm.setAttributes([.creationDate: item.older, .modificationDate: item.older], ofItemAtPath: target.path)
            DriveWriter.fullSyncFileAndParent(target)
            if deleteOriginals { try? fm.removeItem(at: item.url) }
            moved += 1
        }
        progress(1, "")
        return (moved, failed, reason)
    }

    /// Reads `src`'s bytes and writes them to `dest`, coordinated so a file-provider–backed source
    /// (iCloud, a third-party provider) is materialized first. Reads the RAW BYTES (memory-mapped)
    /// rather than `copyItem`, which is more robust against provider quirks and still preserves EXIF
    /// (it lives in the bytes). Returns nil on success, else a short human reason for the first
    /// failure — so a folder that imports nothing says *why* instead of just "nothing".
    nonisolated private static func copyCoordinated(from src: URL, to dest: URL) -> String? {
        let fm = FileManager.default
        if (try? src.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true {
            try? fm.startDownloadingUbiquitousItem(at: src)   // no-op for a local file
        }
        var readError: Error?
        var coordError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: src, options: [], error: &coordError) { readURL in
            do {
                let data = try Data(contentsOf: readURL, options: .mappedIfSafe)
                try data.write(to: dest, options: .atomic)
            } catch { readError = error }
        }
        // Coordinated read failed (provider couldn't serve it) — try one plain read before giving
        // up, in case the coordinator itself is what's refusing on a defunct provider.
        if coordError != nil, readError == nil {
            do {
                let data = try Data(contentsOf: src, options: .mappedIfSafe)
                try data.write(to: dest, options: .atomic)
                return nil
            } catch { readError = error }
        }
        if let e = (readError as NSError?) ?? coordError {
            if e.domain == NSCocoaErrorDomain,
               e.code == NSFileReadNoSuchFileError || e.code == NSFileReadNoPermissionError || e.code == NSFileReadUnknownError {
                return "a file couldn’t be read (\(e.code)) — it may be an iCloud item whose data isn’t on this device"
            }
            return "\(e.localizedDescription) (\(e.domain) \(e.code))"
        }
        return fm.fileExists(atPath: dest.path) ? nil : "the file couldn’t be read"
    }

    /// Writes `date` into an image's EXIF/TIFF date fields, copying the encoded image verbatim (no
    /// re-encode, all other metadata preserved). Same lossless rewrite `FileActions` does, but
    /// `nonisolated` so a big import doesn't run it on the main actor.
    nonisolated private static func stampImageDate(_ date: Date, into url: URL) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(src) else { return }
        var props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
        let f = DateFormatter(); f.dateFormat = "yyyy:MM:dd HH:mm:ss"; f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = .current
        let stamp = f.string(from: date)
        var exif = (props[kCGImagePropertyExifDictionary] as? [CFString: Any]) ?? [:]
        exif[kCGImagePropertyExifDateTimeOriginal] = stamp
        exif[kCGImagePropertyExifDateTimeDigitized] = stamp
        props[kCGImagePropertyExifDictionary] = exif
        var tiff = (props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]) ?? [:]
        tiff[kCGImagePropertyTIFFDateTime] = stamp
        props[kCGImagePropertyTIFFDictionary] = tiff
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".pbtmp_" + UUID().uuidString).appendingPathExtension(url.pathExtension)
        guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, type, 1, nil) else { return }
        CGImageDestinationAddImageFromSource(dest, src, 0, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { try? FileManager.default.removeItem(at: tmp); return }
        _ = try? FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }

    /// Passthrough-remuxes a video to set its creation-date metadata (no re-encode; other metadata
    /// preserved). `nonisolated`/off-main. Best-effort — leaves the file as-is on failure.
    nonisolated private static func stampVideoDate(_ date: Date, into url: URL) async {
        let asset = AVURLAsset(url: url)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else { return }
        var meta = ((try? await asset.load(.metadata)) ?? []).filter {
            $0.identifier != .commonIdentifierCreationDate && $0.identifier != .quickTimeMetadataCreationDate
        }
        let iso = ISO8601DateFormatter().string(from: date)
        for id in [AVMetadataIdentifier.commonIdentifierCreationDate, .quickTimeMetadataCreationDate] {
            let item = AVMutableMetadataItem(); item.identifier = id; item.value = iso as NSString; meta.append(item)
        }
        export.metadata = meta
        let ext = url.pathExtension.lowercased()
        let fileType: AVFileType = ext == "mp4" ? .mp4 : (ext == "m4v" ? .m4v : .mov)
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".pbtmp_" + UUID().uuidString).appendingPathExtension(ext.isEmpty ? "mov" : ext)
        export.outputURL = tmp; export.outputFileType = fileType
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in export.exportAsynchronously { c.resume() } }
        guard export.status == .completed else { try? FileManager.default.removeItem(at: tmp); return }
        _ = try? FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }
}
