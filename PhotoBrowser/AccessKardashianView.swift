import SwiftUI
#if canImport(Translation)
import Translation
#endif

/// "Download from accessKardashian": pick a member (Kim, Kourtney, Kendall, Kylie)
/// and pull her whole Coppermine gallery into a folder named after her — tagged by
/// category (Candids / Photoshoots / …), stamped with her birthday, and carrying
/// the gallery's dates, locations, and captions. Each member remembers her state,
/// so a finished download offers "Fetch New" / "Re-download" and a paused one
/// offers "Resume".
///
/// The download itself runs on `Library` as an **app-wide activity** (progress
/// pill), so these screens can be closed and the app navigated freely while it
/// runs; it also keeps going briefly when the app is backgrounded. Pause anytime —
/// Resume picks up where it left off.
struct AccessKardashianView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let targetFolder: URL

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(AccessKardashian.members) { member in
                        NavigationLink {
                            AKMemberDownloadView(member: member, targetFolder: targetFolder)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(member.name).font(.body)
                                Text(statusLine(member)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } footer: {
                    Text("Photos come from accesskardashian.com.br (a public fan gallery). Each member downloads into her own folder, tagged by category and stamped with her birthday. Downloads run app-wide — you can close this and keep browsing. Coverage and captions are best-effort.")
                }
            }
            .navigationTitle("accessKardashian")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func statusLine(_ member: AccessKardashian.Member) -> String {
        if library.isAKDownloadRunning(member.name) {
            let p = library.akProgress[member.name]
            return p?.phase == "Downloading" ? "Downloading — \(p?.done ?? 0) of \(p?.total ?? 0)…" : "Downloading…"
        }
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

/// One member's download screen: progress, pause, and the right action(s) for her
/// current state. Purely a control surface — the run itself lives on `Library`, so
/// closing this screen (or the sheet) never interrupts it, and reopening it
/// reattaches to the live progress.
private struct AKMemberDownloadView: View {
    @Environment(Library.self) private var library
    let member: AccessKardashian.Member
    let targetFolder: URL

    private var state: Library.AKMember? { library.akMember(member.name) }
    private var running: Bool { library.isAKDownloadRunning(member.name) }
    private var progress: AccessKardashian.Progress {
        library.akProgress[member.name] ?? AccessKardashian.Progress(phase: "Starting…", fraction: 0, done: 0, total: 0)
    }

    var body: some View {
        Form {
            Section {
                Label(member.name, systemImage: "person.crop.circle")
                if let s = state, !running {
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
                        Text("Runs app-wide — leave this screen and keep browsing; it also keeps going briefly if you switch apps (iOS ends it once the app is closed). Pause anytime; Resume picks up where it left off.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Button(role: .destructive) { library.pauseAKDownload(member.name) } label: {
                        Label("Pause", systemImage: "pause.circle")
                    }
                }
            } else {
                Section { ForEach(actions, id: \.title) { action in
                    Button {
                        library.startAKDownload(member: member, into: targetFolder,
                                                overwrite: action.overwrite, refreshIndex: action.refresh)
                    } label: { Label(action.title, systemImage: action.icon) }
                } }
            }
        }
        .navigationTitle(member.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Actions for the current state

    // `refresh` re-crawls the gallery (Fetch New, to discover new content); the others
    // reuse the cached album index so listing is instant.
    private struct Action { let title: String; let icon: String; let overwrite: Bool; let refresh: Bool }
    private var actions: [Action] {
        guard let s = state else {
            return [Action(title: "Download Gallery for \(member.name)", icon: "square.and.arrow.down", overwrite: false, refresh: false)]
        }
        if s.completed {
            return [Action(title: "Fetch New Photos for \(member.name)", icon: "arrow.down.circle", overwrite: false, refresh: true),
                    Action(title: "Re-download Gallery for \(member.name)", icon: "arrow.clockwise.circle", overwrite: true, refresh: false)]
        }
        return [Action(title: "Resume Download for \(member.name)", icon: "play.circle", overwrite: false, refresh: false),
                Action(title: "Re-download Gallery for \(member.name)", icon: "arrow.clockwise.circle", overwrite: true, refresh: false)]
    }

    private var progressLine: String {
        // During listing the phase text is descriptive ("Listing albums — N found…");
        // only the download phase reports a "done of total" count.
        progress.phase == "Downloading"
            ? "Downloading \(progress.done) of \(progress.total)…"
            : progress.phase
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
/// leaving the original captions in place. Hosted on `ContentView` (bound to
/// `Library.akPendingCaptions`) so translation completes even after the download
/// screen is closed — the download itself runs app-wide on `Library`.
struct CaptionTranslation: ViewModifier {
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
