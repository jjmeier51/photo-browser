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

    private enum Phase { case scanning, confirm, choose, working, review, done }
    @State private var phase: Phase = .scanning
    @State private var toMove: [PhotosBackupImporter.ScanItem] = []
    @State private var held: [PhotosBackupImporter.HeldItem] = []
    @State private var selectedHeld = Set<UUID>()
    @State private var deleteOriginals = false
    // Feature toggles on the confirm screen.
    @State private var upscaleAfter = false          // 2× AI upscale imported photos after moving
    @State private var pickItems = false             // choose specific files instead of the whole folder
    @State private var chosen = Set<UUID>()          // ScanItem ids selected on the choose screen

    @State private var progress: Double = 0
    @State private var statusLine = ""
    @State private var movedCount = 0
    @State private var failedCount = 0
    @State private var upscaledCount = 0
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
                case .choose:   chooseView
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
                if phase == .choose {
                    ToolbarItem(placement: .cancellationAction) { Button("Back") { phase = .confirm } }
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
                if !toMove.isEmpty {
                    VStack(spacing: 4) {
                        Toggle("Choose specific items", isOn: $pickItems)
                        Toggle("AI Upscale imported photos (2×)", isOn: $upscaleAfter)
                    }
                    .font(.subheadline)
                    .padding(.horizontal, 34).padding(.top, 4)
                }
                VStack(spacing: 10) {
                    if !toMove.isEmpty {
                        Button { begin(delete: false) } label: {
                            Text(pickItems ? "Choose to Copy…" : "Copy Here (keep originals)").frame(maxWidth: .infinity)
                        }.buttonStyle(.borderedProminent)
                        Button(role: .destructive) { begin(delete: true) } label: {
                            Text(pickItems ? "Choose to Move…" : "Move Here (delete originals)").frame(maxWidth: .infinity)
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
                            MediaRow(item: h.item, selected: selectedHeld.contains(h.id),
                                     badge: h.matchKind == .exactDuplicate
                                        ? (text: "Duplicate of \(h.matchName)", icon: "doc.on.doc", color: .orange)
                                        : (text: "Preview of \(h.matchName)", icon: "photo.badge.checkmark", color: .blue))
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
        if !accessing { accessing = source.startAccessingSecurityScopedResource(); bgTask.begin(name: "Import Photos Backup") }
        let result = await PhotosBackupImporter.scan(source: source, destination: destination)
        toMove = result.toMove
        held = result.held
        phase = .confirm
    }

    /// Copy/Move tapped on the confirm screen: either go choose specific items, or import all
    /// non-duplicate items straight away.
    private func begin(delete: Bool) {
        deleteOriginals = delete
        if pickItems {
            chosen = Set(toMove.map { $0.id })      // default: everything selected
            phase = .choose
        } else {
            start(toMove)
        }
    }

    /// Import the given (already-scanned, non-duplicate) items, then optionally 2× upscale the
    /// photos among them, then move on to reviewing the held/duplicate items (or finish).
    private func start(_ items: [PhotosBackupImporter.ScanItem]) {
        Task {
            await performMove(items)
            if held.isEmpty { finish() } else { phase = .review }
        }
    }

    /// The shared move (+ optional upscale) pass, driving the working screen.
    private func performMove(_ items: [PhotosBackupImporter.ScanItem]) async {
        phase = .working; progress = 0; statusLine = ""
        let r = await PhotosBackupImporter.move(items, into: destination, deleteOriginals: deleteOriginals) { frac, name in
            Task { @MainActor in progress = frac; statusLine = name.isEmpty ? "" : "Importing \(name)" }
        }
        movedCount += r.moved.count
        failedCount += r.failed
        if let reason = r.reason { importError = reason }
        // 2× AI upscale the photos we just imported (after they've been confirmed non-duplicates).
        // Previews get the preview-tuned pipeline; EXIF + dates are preserved/restored.
        if upscaleAfter {
            let images = r.moved.filter { classify(url: $0, isDirectory: false) == .image }
            if !images.isEmpty {
                progress = 0
                upscaledCount += await PhotosBackupImporter.upscaleImported(images) { frac in
                    Task { @MainActor in progress = frac; statusLine = "AI Upscaling photos…" }
                }
            }
        }
        library.contentDidChange(under: destination)
    }

    private func toggle(_ id: UUID) {
        if selectedHeld.contains(id) { selectedHeld.remove(id) } else { selectedHeld.insert(id) }
    }

    private func moveSelectedHeld() {
        let picks = held.filter { selectedHeld.contains($0.id) }.map { $0.item }
        guard !picks.isEmpty else { finish(); return }
        Task { await performMove(picks); finish() }
    }

    private func finish() {
        let verb = deleteOriginals ? "Moved" : "Copied"
        if movedCount == 0 {
            resultText = failedCount > 0
                ? "Couldn’t import \(failedCount) item\(failedCount == 1 ? "" : "s")\(importError.map { " — \($0)" } ?? ".")"
                : "Nothing was imported."
        } else {
            resultText = "\(verb) \(movedCount) item\(movedCount == 1 ? "" : "s")"
                + (upscaledCount > 0 ? ", \(upscaledCount) upscaled 2×" : "")
                + (failedCount > 0 ? ", \(failedCount) couldn’t be imported\(importError.map { " (\($0))" } ?? "")." : ", EXIF and dates kept.")
        }
        phase = .done
    }

    /// Choose-specific-items screen: every non-duplicate media file with a thumbnail and a check,
    /// so the user can import a subset instead of the whole folder.
    @ViewBuilder private var chooseView: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(chosen.count) of \(toMove.count) selected").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Button(chosen.count == toMove.count ? "Deselect All" : "Select All") {
                    chosen = chosen.count == toMove.count ? [] : Set(toMove.map { $0.id })
                }.font(.subheadline)
            }
            .padding(.horizontal).padding(.vertical, 8)

            List {
                ForEach(toMove) { item in
                    Button {
                        if chosen.contains(item.id) { chosen.remove(item.id) } else { chosen.insert(item.id) }
                    } label: {
                        MediaRow(item: item, selected: chosen.contains(item.id),
                                 badge: item.isPreview ? (text: "Preview", icon: "photo.badge.checkmark", color: .blue) : nil)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button { start(toMove.filter { chosen.contains($0.id) }) } label: {
                Text(chosen.isEmpty ? "Select items to import" : "\(deleteOriginals ? "Move" : "Copy") \(chosen.count) Selected")
                    .fontWeight(.semibold).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent).disabled(chosen.isEmpty)
            .padding().background(.ultraThinMaterial)
        }
    }

    private func releaseAccess() {
        if accessing { source.stopAccessingSecurityScopedResource(); accessing = false }
        bgTask.end()
    }
}

/// One selectable media row: thumbnail, name, size · dimensions · date, an optional badge, and a
/// selection check. Used for both the choose-items list and the held (duplicate/preview) review.
/// Thumbnail + dimensions load lazily (off-main), like the duplicates view.
private struct MediaRow: View {
    let item: PhotosBackupImporter.ScanItem
    let selected: Bool
    let badge: (text: String, icon: String, color: Color)?
    @State private var image: UIImage?
    @State private var dims = "—"

    private var entry: Entry {
        Entry(url: item.url, name: item.name, kind: item.kind, size: item.size, modified: item.older)
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                if let image { Image(uiImage: image).resizable().scaledToFill() }
                else { Rectangle().fill(.quaternary).overlay { Image(systemName: item.kind.systemImage).foregroundStyle(.secondary) } }
            }
            .frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).font(.subheadline.weight(.medium)).lineLimit(1)
                Text("\(item.size.sizeString) · \(dims) · \(item.older.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let badge {
                    Label(badge.text, systemImage: badge.icon)
                        .font(.caption2).foregroundStyle(badge.color).lineLimit(1)
                }
            }
            Spacer()
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.title3).foregroundStyle(selected ? Color.accentColor : Color.secondary)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .task(id: item.id) {
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
                                 progress: @escaping @Sendable (Double, String) -> Void) async -> (moved: [URL], failed: Int, reason: String?) {
        let fm = FileManager.default
        try? fm.createDirectory(at: destination, withIntermediateDirectories: true)
        var moved: [URL] = []
        var failed = 0
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
            moved.append(target)
        }
        progress(1, "")
        return (moved, failed, reason)
    }

    /// 2× AI upscale the just-imported photos in place — Apple Photos "…preview" JPEGs get the
    /// preview-tuned pipeline, others the standard enhance. EXIF (incl. the capture date we wrote)
    /// is preserved by the enhancers; the filesystem dates are read first and restored after (the
    /// in-place re-encode resets them). Returns how many succeeded. `nonisolated` — pixel work.
    nonisolated static func upscaleImported(_ urls: [URL], progress: @escaping @Sendable (Double) -> Void) async -> Int {
        let fm = FileManager.default
        var ok = 0
        for (i, url) in urls.enumerated() {
            progress(Double(i) / Double(max(urls.count, 1)))
            let isPreview = previewInfo(url.lastPathComponent).isPreview
            let dates = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
            let done = isPreview ? MediaEditing.enhancePreviewInPlace(url: url, scale: 2)
                                 : MediaEditing.enhancePhotoInPlace(url: url, scale: 2)
            if done {
                ok += 1
                var attrs: [FileAttributeKey: Any] = [:]
                if let c = dates?.creationDate { attrs[.creationDate] = c }
                if let m = dates?.contentModificationDate { attrs[.modificationDate] = m }
                if !attrs.isEmpty { try? fm.setAttributes(attrs, ofItemAtPath: url.path) }
                DriveWriter.fullSyncFileAndParent(url)
            }
        }
        progress(1)
        return ok
    }

    /// Copies `src` to `dest`. Returns nil on success, else a short human reason for the failure —
    /// so a folder that imports nothing (or fails midway) says *why* instead of just "nothing".
    ///
    /// Primary strategy is `FileManager.copyItem`, the exact mechanism the working "Move Here from
    /// Another Drive" transfer uses (`FileActions.transferContents`). It copies through the file
    /// provider / external volume correctly and preserves EXIF (a byte-identical copy). A raw
    /// `Data.write` into the destination — the previous approach — failed on this user's drive with
    /// `NSFileWriteUnknownError` (512) even though `copyItem` to the *same* folder succeeds. The
    /// coordinated byte-copy is kept only as a fallback for a provider placeholder that `copyItem`
    /// can't serve directly.
    nonisolated private static func copyCoordinated(from src: URL, to dest: URL) -> String? {
        let fm = FileManager.default
        if (try? src.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true {
            try? fm.startDownloadingUbiquitousItem(at: src)   // no-op for a local file
        }
        if fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) }   // clear any partial leftover
        // 1) The proven path: a straight file copy, exactly like the drive-to-drive transfer.
        if (try? fm.copyItem(at: src, to: dest)) != nil { return nil }

        // 2) Fallback — coordinate a read (materializes a not-yet-downloaded provider placeholder)
        //    into concrete bytes, then write them robustly. Concrete memory (no `.mappedIfSafe`): a
        //    mapped `Data` stays backed by the source, so a provider page that can't be served during
        //    the write would fault every write strategy alike.
        if fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) }   // partial from a failed copyItem
        var data: Data?
        var readError: Error?
        var coordError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: src, options: [], error: &coordError) { readURL in
            do { data = try Data(contentsOf: readURL) }
            catch { readError = error }
        }
        // Coordinated read failed (provider couldn't serve it) — try one plain read before giving
        // up, in case the coordinator itself is what's refusing on a defunct provider.
        if data == nil {
            data = try? Data(contentsOf: src)
        }
        guard let bytes = data else {
            if let e = (readError as NSError?) ?? coordError {
                if e.domain == NSCocoaErrorDomain,
                   e.code == NSFileReadNoSuchFileError || e.code == NSFileReadNoPermissionError || e.code == NSFileReadUnknownError {
                    return "a file couldn’t be read (\(e.code)) — it may be an iCloud item whose data isn’t on this device"
                }
                return "couldn’t read the file: \(e.localizedDescription) (\(e.domain) \(e.code))"
            }
            return "the file couldn’t be read"
        }
        // 2) Write the bytes into the destination robustly.
        return writeBytes(bytes, to: dest)
    }

    /// Writes `bytes` to `dest`, trying progressively-less-demanding strategies. `.atomic` (write a
    /// hidden temp file in the folder, then rename) is fastest and crash-safe but some file
    /// providers / external volumes reject the temp-file-then-rename dance with a generic
    /// `NSFileWriteUnknownError` (512) — the failure the user hit. So fall back to a plain direct
    /// write, then a coordinated write, before giving up with a precise reason.
    nonisolated private static func writeBytes(_ bytes: Data, to dest: URL) -> String? {
        do { try bytes.write(to: dest, options: .atomic); return nil } catch {}
        do { try bytes.write(to: dest, options: []); return nil } catch {}
        var writeError: Error?
        var coordError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: dest, options: .forReplacing, error: &coordError) { writeURL in
            do { try bytes.write(to: writeURL, options: []) } catch { writeError = error }
        }
        if FileManager.default.fileExists(atPath: dest.path) { return nil }
        if let e = (writeError as NSError?) ?? coordError {
            return "couldn’t save the file: \(e.localizedDescription) (\(e.domain) \(e.code))"
        }
        return "the file couldn’t be saved"
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
