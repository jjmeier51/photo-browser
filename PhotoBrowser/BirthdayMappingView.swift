import SwiftUI
import UIKit

/// Settings → **Folder Birthdays**: one screen that maps every **top-level folder** of the library
/// to a birthday, for adding, editing and clearing them in bulk (the per-folder editor,
/// `BirthdayEditorView`, still handles one folder at a time from inside a folder).
///
/// Edits are staged in `draft` and written together on Save (`Library.setBirthdays`), so nothing
/// changes on the drive's metadata until the user commits, and the folder views reload once, not
/// once per row. Bulk tools: filter to the folders still missing a birthday, **paste a text list**
/// ("Taylor — 1989-12-13", one per line, any common date format; names are matched to folders),
/// **copy the mapping as text** (edit it in Notes, paste it back), and clear everything.
struct BirthdayMappingView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss

    @State private var folders: [Entry] = []
    @State private var loading = true
    @State private var original: [String: Date] = [:]     // path → birthday as saved
    @State private var draft: [String: Date] = [:]        // path → birthday as edited
    @State private var search = ""
    @State private var filter: Filter = .all
    @State private var showImport = false
    @State private var confirmClear = false
    @State private var confirmDiscard = false
    @State private var toast: String?

    private enum Filter: String, CaseIterable, Identifiable {
        case all = "All", missing = "Missing", set = "Set"
        var id: String { rawValue }
    }

    private var changes: [URL: Date?] {
        var out: [URL: Date?] = [:]
        for f in folders {
            let before = original[f.url.path], after = draft[f.url.path]
            if before != after { out[f.url] = .some(after) }
        }
        return out
    }
    private var changeCount: Int { changes.count }

    private var visible: [Entry] {
        folders.filter { f in
            switch filter {
            case .all:     break
            case .missing: if draft[f.url.path] != nil { return false }
            case .set:     if draft[f.url.path] == nil { return false }
            }
            return search.isEmpty || f.name.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        List {
            summarySection
            toolsSection
            Section {
                if loading {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else if folders.isEmpty {
                    Text(library.rootURL == nil ? "Open a library folder first." : "No folders at the top level of the library.")
                        .foregroundStyle(.secondary)
                } else if visible.isEmpty {
                    Text("No folders match.").foregroundStyle(.secondary)
                } else {
                    ForEach(visible) { folder in row(folder) }
                }
            } header: {
                Text(filter == .all ? "Top-level folders" : "\(filter.rawValue) — \(visible.count)")
            }
        }
        .searchable(text: $search, prompt: "Folder name")
        .navigationTitle("Folder Birthdays")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(changeCount > 0 ? "Save (\(changeCount))" : "Save") { save() }
                    .disabled(changeCount == 0)
            }
        }
        .navigationBarBackButtonHidden(changeCount > 0)
        .toolbar {
            if changeCount > 0 {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { confirmDiscard = true }
                }
            }
        }
        .confirmationDialog("Discard \(changeCount) unsaved change\(changeCount == 1 ? "" : "s")?",
                            isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard Changes", role: .destructive) { draft = original; dismiss() }
            Button("Keep Editing", role: .cancel) {}
        }
        .confirmationDialog("Clear every top-level folder's birthday?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear All", role: .destructive) { for f in folders { draft.removeValue(forKey: f.url.path) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This only stages the change — nothing is removed until you tap Save.")
        }
        .sheet(isPresented: $showImport) {
            BirthdayTextImportView(folders: folders) { matched in
                for (path, date) in matched { draft[path] = date }
                toast = "\(matched.count) birthday\(matched.count == 1 ? "" : "s") filled in — tap Save to keep them."
            }
        }
        .alert("Folder Birthdays", isPresented: Binding(get: { toast != nil }, set: { if !$0 { toast = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(toast ?? "") }
        .task { await load() }
    }

    // MARK: - Sections

    private var summarySection: some View {
        Section {
            Picker("Show", selection: $filter) {
                ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
        } footer: {
            let set = folders.filter { draft[$0.url.path] != nil }.count
            Text("\(set) of \(folders.count) top-level folders have a birthday. Files inside a folder (and its subfolders) show an Age computed from that date and their capture date.")
        }
    }

    private var toolsSection: some View {
        Section("Bulk") {
            Button { showImport = true } label: {
                Label("Paste a List of Birthdays…", systemImage: "doc.on.clipboard")
            }
            .disabled(folders.isEmpty)
            Button { copyAsText() } label: {
                Label("Copy Mapping as Text", systemImage: "doc.on.doc")
            }
            .disabled(folders.isEmpty)
            Button(role: .destructive) { confirmClear = true } label: {
                Label("Clear All Birthdays", systemImage: "trash")
            }
            .disabled(folders.allSatisfy { draft[$0.url.path] == nil })
        }
    }

    private func row(_ folder: Entry) -> some View {
        let path = folder.url.path
        let changed = original[path] != draft[path]
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(folder.name).lineLimit(1)
                if let d = draft[path] {
                    Text(subtitle(for: d)).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("No birthday").font(.caption).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 8)
            if changed {
                Circle().fill(Color.accentColor).frame(width: 7, height: 7).accessibilityLabel("Unsaved")
            }
            if draft[path] != nil {
                DatePicker("", selection: Binding(
                    get: { draft[path] ?? Self.defaultBirthday },
                    set: { draft[path] = $0 }),
                    in: ...Date(), displayedComponents: .date)
                    .labelsHidden()
            } else {
                Button("Add") { draft[path] = Self.defaultBirthday }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if draft[path] != nil {
                Button(role: .destructive) { draft.removeValue(forKey: path) } label: {
                    Label("Clear", systemImage: "xmark.circle")
                }
            }
            if changed {
                Button { if let o = original[path] { draft[path] = o } else { draft.removeValue(forKey: path) } } label: {
                    Label("Revert", systemImage: "arrow.uturn.backward")
                }
                .tint(.gray)
            }
        }
    }

    private func subtitle(for date: Date) -> String {
        let s = date.formatted(date: .long, time: .omitted)
        if let age = Library.ageBetween(date, Date()) { return "\(s) · \(age) today" }
        return s
    }

    private static var defaultBirthday: Date {
        Calendar.current.date(byAdding: .year, value: -25, to: Date()) ?? Date()
    }

    // MARK: - Actions

    private func load() async {
        guard let root = library.rootURL else { loading = false; return }
        let list = await library.subfolders(of: root)
        var saved: [String: Date] = [:]
        for f in list { if let d = library.birthday(for: f.url) { saved[f.url.path] = d } }
        folders = list
        original = saved
        draft = saved
        loading = false
    }

    private func save() {
        let c = changes
        library.setBirthdays(c)
        original = draft
        toast = "Saved \(c.count) change\(c.count == 1 ? "" : "s")."
    }

    /// "Name = yyyy-MM-dd" per folder (blank date when unset), in the same order as the list — the
    /// shape the importer reads back, so the whole mapping can be edited in a text app.
    private func copyAsText() {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        let lines = folders.map { folder -> String in
            let d = draft[folder.url.path].map { f.string(from: $0) } ?? ""
            return "\(folder.name) = \(d)"
        }
        UIPasteboard.general.string = lines.joined(separator: "\n")
        toast = "Copied \(folders.count) line\(folders.count == 1 ? "" : "s"). Edit the dates (yyyy-mm-dd, or any date format) and paste the list back with “Paste a List of Birthdays…”."
    }
}

// MARK: - Text import

/// Paste any "Name – date" list and match it to the top-level folders. Each line is one folder:
/// the date is found anywhere in the line (ISO, numeric or written-out forms) and the rest of the
/// line is the name, matched case-insensitively to a folder — exactly, else as a unique prefix /
/// containment either way. Lines with a name but no date clear that folder's birthday (so the
/// copied-out mapping round-trips). Nothing is applied until "Use N".
private struct BirthdayTextImportView: View {
    @Environment(\.dismiss) private var dismiss
    let folders: [Entry]
    let onApply: ([String: Date?]) -> Void

    private struct Match: Identifiable {
        let folder: Entry
        let date: Date?
        var id: URL { folder.url }
    }

    @State private var text = ""
    @State private var matched: [Match] = []
    @State private var unmatched: [String] = []

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .font(.callout.monospaced())
                        .frame(minHeight: 160)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button { text = UIPasteboard.general.string ?? text } label: {
                        Label("Paste from Clipboard", systemImage: "doc.on.clipboard")
                    }
                } header: {
                    Text("One folder per line")
                } footer: {
                    Text("Examples: “Taylor = 1989-12-13”, “Selena: 7/22/1992”, “Zendaya — September 1, 1996”. A line with a name but no date clears that folder's birthday.")
                }
                if !matched.isEmpty {
                    Section("Matched — \(matched.count)") {
                        ForEach(matched) { m in
                            HStack {
                                Text(m.folder.name).lineLimit(1)
                                Spacer()
                                Text(m.date.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "clear")
                                    .foregroundStyle(m.date == nil ? .red : .secondary)
                            }
                        }
                    }
                }
                if !unmatched.isEmpty {
                    Section {
                        ForEach(unmatched, id: \.self) { Text($0).foregroundStyle(.secondary).lineLimit(1) }
                    } header: {
                        Text("Not matched to a folder — \(unmatched.count)")
                    } footer: {
                        Text("Names must match a top-level folder (case doesn't matter; a unique partial match is fine).")
                    }
                }
            }
            .navigationTitle("Paste Birthdays")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use \(matched.count)") {
                        var out: [String: Date?] = [:]
                        for m in matched { out[m.folder.url.path] = .some(m.date) }
                        onApply(out); dismiss()
                    }
                    .disabled(matched.isEmpty)
                }
            }
            .onChange(of: text) { _, _ in parse() }
            .onAppear { if text.isEmpty, let clip = UIPasteboard.general.string, clip.contains("\n") { text = clip } }
        }
    }

    private func parse() {
        var found: [Match] = []
        var missed: [String] = []
        var used = Set<String>()
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let (name, date) = Self.split(line)
            guard !name.isEmpty, let folder = Self.match(name, in: folders), used.insert(folder.url.path).inserted else {
                missed.append(line); continue
            }
            found.append(Match(folder: folder, date: date))
        }
        matched = found; unmatched = missed
    }

    /// (name, date?) for one line. The date is located with the system data detector (handles
    /// "12/13/1989", "1989-12-13", "December 13, 1989", "13 Dec 1989"…); an ISO date is also tried
    /// by hand since the detector occasionally skips a bare "yyyy-mm-dd". The name is whatever is
    /// left once the date and the separator around it are trimmed.
    private static func split(_ line: String) -> (String, Date?) {
        var name = line
        var date: Date?
        if let r = line.range(of: #"\b(\d{4})-(\d{1,2})-(\d{1,2})\b"#, options: .regularExpression) {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-M-d"
            date = f.date(from: String(line[r]))
            if date != nil { name.removeSubrange(r) }
        }
        if date == nil, let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
           let m = det.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
           let d = m.date, let r = Range(m.range, in: line) {
            date = d
            name.removeSubrange(r)
        }
        let separators = CharacterSet(charactersIn: " \t=:,;-–—|")
        name = name.trimmingCharacters(in: separators)
        return (name, date)
    }

    private static func normalize(_ s: String) -> String {
        s.lowercased().components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func match(_ name: String, in folders: [Entry]) -> Entry? {
        let n = normalize(name)
        guard !n.isEmpty else { return nil }
        if let exact = folders.first(where: { normalize($0.name) == n }) { return exact }
        let partial = folders.filter { let f = normalize($0.name); return f.hasPrefix(n) || n.hasPrefix(f) || f.contains(n) || n.contains(f) }
        return partial.count == 1 ? partial[0] : nil
    }
}
