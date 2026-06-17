import SwiftUI
#if canImport(Translation)
import Translation
#endif

/// "Download from accessKardashian": pick a member (Kim, Kourtney, Kendall, Kylie)
/// and pull her whole Coppermine gallery into a folder named after her — tagged by
/// category (Candids / Photoshoots / …), stamped with her birthday, and carrying
/// the gallery's dates, locations, and captions. Each member remembers her state,
/// so a finished download offers "Fetch New" / "Re-download" and a paused one
/// offers "Resume". Downloads run with high concurrency and keep going briefly in
/// the background.
struct AccessKardashianView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let targetFolder: URL
    let onFinished: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(AccessKardashian.members) { member in
                        NavigationLink {
                            AKMemberDownloadView(member: member, targetFolder: targetFolder, onFinished: onFinished)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(member.name).font(.body)
                                Text(statusLine(member)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } footer: {
                    Text("Photos come from accesskardashian.com.br (a public fan gallery). Each member downloads into her own folder, tagged by category and stamped with her birthday. Coverage and captions are best-effort.")
                }
            }
            .navigationTitle("accessKardashian")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func statusLine(_ member: AccessKardashian.Member) -> String {
        guard let s = library.akMember(member.name) else { return "Not downloaded yet" }
        let when = Self.relative(Date(timeIntervalSince1970: s.updated))
        if s.completed { return "\(s.downloaded) photos · updated \(when)" }
        return "Paused — \(s.downloaded) of \(s.total) · \(when)"
    }

    private static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
}

/// One member's download screen: progress, pause/cancel, and the right action(s)
/// for her current state.
private struct AKMemberDownloadView: View {
    @Environment(Library.self) private var library
    let member: AccessKardashian.Member
    let targetFolder: URL
    let onFinished: () -> Void

    @State private var running = false
    @State private var progress = AccessKardashian.Progress(phase: "", fraction: 0, done: 0, total: 0)
    @State private var result: AccessKardashian.Result?
    @State private var task: Task<Void, Never>?
    @State private var cancel = CancelFlag()

    // Captions come back in Portuguese; setting this drives the on-device
    // translation to English on iOS 18+ (see `CaptionTranslation`).
    @State private var pendingCaptions: [String: String] = [:]

    private var state: Library.AKMember? { library.akMember(member.name) }

    var body: some View {
        Form {
            Section {
                Label(member.name, systemImage: "person.crop.circle")
                if let s = state {
                    Text(s.completed ? "\(s.downloaded) photos downloaded."
                                     : "Paused at \(s.downloaded) of \(s.total).")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            if running {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(value: progress.total > 0 ? progress.fraction : 0)
                        Text(progressLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Text("Keep the app open. It keeps going briefly if you switch away, but can’t finish once the app is closed.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Button(role: .destructive) { pause() } label: {
                        Label("Pause", systemImage: "pause.circle")
                    }
                }
            } else {
                if let r = result {
                    Section {
                        Label(summary(r), systemImage: r.cancelled ? "pause.circle" : "checkmark.circle")
                            .foregroundStyle(r.downloaded > 0 || r.skipped > 0 ? .green : .orange)
                        if let note = r.note, !r.cancelled { Text(note).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                Section { ForEach(actions, id: \.title) { action in
                    Button { run(overwrite: action.overwrite) } label: { Label(action.title, systemImage: action.icon) }
                } }
            }
        }
        .navigationTitle(member.name)
        .navigationBarTitleDisplayMode(.inline)
        .modifier(CaptionTranslation(pending: $pendingCaptions, apply: applyTranslated))
    }

    // MARK: - Actions for the current state

    private struct Action { let title: String; let icon: String; let overwrite: Bool }
    private var actions: [Action] {
        guard let s = state else {
            return [Action(title: "Download Gallery for \(member.name)", icon: "square.and.arrow.down", overwrite: false)]
        }
        if s.completed {
            return [Action(title: "Fetch New Photos for \(member.name)", icon: "arrow.down.circle", overwrite: false),
                    Action(title: "Re-download Gallery for \(member.name)", icon: "arrow.clockwise.circle", overwrite: true)]
        }
        return [Action(title: "Resume Download for \(member.name)", icon: "play.circle", overwrite: false),
                Action(title: "Re-download Gallery for \(member.name)", icon: "arrow.clockwise.circle", overwrite: true)]
    }

    private var progressLine: String {
        guard progress.total > 0 else { return progress.phase }
        return "Downloading \(progress.done) of \(progress.total)…"
    }

    private func summary(_ r: AccessKardashian.Result) -> String {
        if r.cancelled { return "Paused — \(r.downloaded + r.skipped) of \(r.total) downloaded." }
        guard r.downloaded > 0 || r.skipped > 0 else { return r.note ?? "Nothing downloaded." }
        var s = "Downloaded \(r.downloaded) new photo\(r.downloaded == 1 ? "" : "s")"
        if r.skipped > 0 { s += " (\(r.skipped) already had)" }
        return s + "."
    }

    // MARK: - Run / pause

    private func run(overwrite: Bool) {
        let folder = targetFolder.appendingPathComponent(member.name, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        library.markKardashianFolder(folder)
        if let d = AccessKardashian.birthdayDate(member) { library.setBirthday(d, for: folder) }

        let flag = CancelFlag(); cancel = flag
        running = true; result = nil
        let bg = BackgroundTaskHolder(); bg.begin(name: "accessKardashian \(member.name)")
        task = Task {
            let r = await AccessKardashian.run(member: member, into: folder, overwrite: overwrite,
                                               progress: { p in Task { @MainActor in progress = p } },
                                               isCancelled: { flag.isSet })
            // Tag every downloaded photo with its category label, and store captions
            // (Portuguese now; translated to English on iOS 18+).
            library.addLabels(r.labelsByCategory)
            if !r.captions.isEmpty { library.setCaptions(r.captions); pendingCaptions = r.captions }
            // Clear Coppermine file-info tooltips an earlier version wrongly stored as captions.
            let stale = library.captions.filter { $0.key.hasPrefix(folder.path + "/") && AccessKardashian.isInfoBlock($0.value) }
            if !stale.isEmpty { library.setCaptions(stale.mapValues { _ in "" }) }

            let present = r.downloaded + r.skipped
            library.setAKMember(member.name, .init(folderPath: folder.path, completed: !r.cancelled,
                                                   total: max(r.total, present), downloaded: present,
                                                   updated: Date().timeIntervalSince1970))
            running = false; bg.end()
            result = r
            if present > 0 { library.contentDidChange(); onFinished() }
        }
    }

    private func pause() { cancel.set() }    // lets in-flight downloads finish, then stops

    /// Receives path→English from `CaptionTranslation` and overwrites the stored
    /// (Portuguese) captions.
    private func applyTranslated(_ map: [String: String]) {
        guard !map.isEmpty else { return }
        library.setCaptions(map)
        pendingCaptions = [:]
    }
}

/// Thread-safe cancel flag shared with the `nonisolated` downloader (pausing lets
/// in-flight downloads finish, then stops adding new ones).
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

/// Runs the Portuguese→English caption translation on iOS 18+ (Apple's on-device
/// Translation framework); a no-op on iOS 17 / when the framework is unavailable,
/// leaving the original captions in place.
private struct CaptionTranslation: ViewModifier {
    @Binding var pending: [String: String]
    let apply: ([String: String]) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        #if canImport(Translation)
        if #available(iOS 18, *) {
            content.translationTask(currentConfig) { session in await translate(session) }
        } else { content }
        #else
        content
        #endif
    }

    #if canImport(Translation)
    @available(iOS 18, *)
    private var currentConfig: TranslationSession.Configuration? {
        pending.isEmpty ? nil
            : TranslationSession.Configuration(source: Locale.Language(identifier: "pt-BR"),
                                               target: Locale.Language(identifier: "en"))
    }

    @available(iOS 18, *)
    private func translate(_ session: TranslationSession) async {
        let entries = pending
        guard !entries.isEmpty else { return }
        let texts = Array(Set(entries.values))
        let requests = texts.enumerated().map {
            TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset))
        }
        var ptToEn: [String: String] = [:]
        if let responses = try? await session.translations(from: requests) {
            for r in responses {
                if let id = r.clientIdentifier, let i = Int(id), i < texts.count { ptToEn[texts[i]] = r.targetText }
            }
        }
        guard !ptToEn.isEmpty else { return }
        var out: [String: String] = [:]
        for (path, pt) in entries where ptToEn[pt] != nil { out[path] = ptToEn[pt] }
        await MainActor.run { apply(out) }
    }
    #endif
}
