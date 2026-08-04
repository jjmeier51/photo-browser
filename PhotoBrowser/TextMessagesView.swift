import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Model

/// One text message inside a conversation.
struct TMMessage: Identifiable, Hashable, Sendable {
    let id = UUID()
    let text: String
    let date: Date?
    let isFromMe: Bool          // outgoing (right) vs incoming (left, gray)
    var isSMS: Bool = false      // outgoing SMS (green) vs iMessage (blue); ignored for incoming
    let sender: String          // display sender for group threads ("" when unknown / it's me)
}

/// All messages exchanged with one address (phone number / handle / contact), grouped together.
/// Metadata (`lastDate`/`preview`/`isGroup`) and the chronological message order are computed ONCE
/// in the initializer and stored — recomputing them per render is what froze a 31 MB import.
struct TMConversation: Identifiable, Sendable {
    let id = UUID()
    let displayName: String     // contact name, or the phone number if that's all we have
    let address: String         // normalized phone/handle — the grouping key
    let messages: [TMMessage]   // pre-sorted oldest → newest
    let lastDate: Date?
    let preview: String
    let isGroup: Bool           // more than one sender (besides me) → show sender names

    init(displayName: String, address: String, messages rawMessages: [TMMessage]) {
        let sorted = rawMessages.sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
        self.displayName = displayName
        self.address = address
        self.messages = sorted
        self.lastDate = sorted.last?.date ?? sorted.compactMap(\.date).max()
        self.preview = (sorted.last { !$0.text.isEmpty })?.text ?? sorted.last?.text ?? ""
        self.isGroup = Set(sorted.lazy.filter { !$0.isFromMe }.compactMap { $0.sender.isEmpty ? nil : $0.sender }).count > 1
    }
}

// MARK: - Viewer

/// An in-app "Messages" viewer. Import an exported `.html` of your texts; it's parsed into
/// conversations grouped by phone number/contact and shown almost exactly like iOS Messages —
/// a conversations list, then per-conversation bubble threads. Everything is searchable (across
/// conversations and message text, plus within a thread). The import is remembered per folder, so
/// reopening the viewer restores it. Download-only and on-device; nothing leaves the phone.
struct TextMessagesView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let folder: URL

    @State private var conversations: [TMConversation] = []   // already sorted by recency at parse time
    @State private var loading = false
    @State private var loadedOnce = false
    @State private var showImporter = false
    @State private var note: String?
    @State private var query = ""                             // the search-field text
    @State private var convoHits: [TMConversation] = []       // results, computed off-main (debounced)
    @State private var msgHits: [MessageHit] = []
    @State private var searching = false

    private var searchActive: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    VStack(spacing: 12) { ProgressView(); Text("Reading messages…").foregroundStyle(.secondary) }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if conversations.isEmpty {
                    emptyState
                } else {
                    conversationList
                }
            }
            .background(Color(.systemBackground))
            .navigationTitle("Messages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                if !conversations.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button { showImporter = true } label: { Label("Import Another File…", systemImage: "square.and.arrow.down") }
                            Button(role: .destructive) { clear() } label: { Label("Remove Imported Messages", systemImage: "trash") }
                        } label: { Image(systemName: "ellipsis.circle") }
                    }
                }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.html],
                          allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let u = urls.first { importHTML(u) }
            }
        }
        .task {
            guard !loadedOnce else { return }
            loadedOnce = true
            await loadExisting()
        }
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "message.fill").font(.system(size: 54)).foregroundStyle(.tint)
            Text("Import Your Text Messages").font(.title3.weight(.semibold))
            Text("Choose an exported **.html** file of your texts. It's parsed on-device into conversations by phone number, shown like Messages, and made searchable. Nothing is uploaded.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .padding(.horizontal, 30)
            Button { showImporter = true } label: {
                Label("Choose .html File", systemImage: "doc.badge.plus").padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent).padding(.top, 4)
            if let note {
                Text(note).font(.footnote).foregroundStyle(.orange).multilineTextAlignment(.center).padding(.horizontal, 30)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Conversation list

    private var conversationList: some View {
        List {
            if searchActive {
                searchResults
            } else {
                ForEach(conversations) { convo in
                    NavigationLink { MessageThreadView(conversation: convo) } label: { ConversationRow(convo: convo) }
                }
            }
        }
        .listStyle(.plain)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search Messages")
        // Debounced, off-main search. `.task(id: query)` re-runs on each keystroke, cancelling the
        // prior run; the sleep debounces and the scan happens off the main actor — so search stays
        // live and iOS-like without scanning 100k+ messages on every keystroke.
        .task(id: query) { await runSearch() }
    }

    /// iOS-Messages-style results: matching conversations, then matching messages (name + the
    /// matched message, highlighted). "No results" only once the search has actually settled.
    @ViewBuilder private var searchResults: some View {
        let term = query.trimmingCharacters(in: .whitespaces)
        if !convoHits.isEmpty {
            Section("Conversations") {
                ForEach(convoHits) { convo in
                    NavigationLink { MessageThreadView(conversation: convo, initialSearch: term) } label: { ConversationRow(convo: convo) }
                }
            }
        }
        if !msgHits.isEmpty {
            Section("Messages") {
                ForEach(msgHits) { hit in
                    NavigationLink {
                        MessageThreadView(conversation: hit.convo, initialSearch: term, scrollTo: hit.message.id)
                    } label: {
                        MessageHitRow(hit: hit, query: term)
                    }
                }
            }
        }
        if convoHits.isEmpty && msgHits.isEmpty && !searching {
            Text("No results").foregroundStyle(.secondary)
        }
    }

    /// Debounced search driven by `.task(id: query)`: a new keystroke cancels this, so the sleep
    /// throttles and the scan (off-main, capped) runs only after typing pauses.
    private func runSearch() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { convoHits = []; msgHits = []; searching = false; return }
        searching = true
        try? await Task.sleep(nanoseconds: 250_000_000)
        if Task.isCancelled { return }
        let convos = conversations
        let r = await Task.detached(priority: .userInitiated) { Self.computeSearch(convos, q) }.value
        if Task.isCancelled { return }
        convoHits = r.convos; msgHits = r.msgs; searching = false
    }

    /// Runs the search off the main actor: conversations by name/number, then messages (capped so a
    /// common term can't scan the whole archive).
    nonisolated private static func computeSearch(_ conversations: [TMConversation], _ q: String) -> (convos: [TMConversation], msgs: [MessageHit]) {
        let convos = conversations.filter {
            $0.displayName.localizedCaseInsensitiveContains(q) || $0.address.localizedCaseInsensitiveContains(q)
        }
        var msgs: [MessageHit] = []
        outer: for convo in conversations {
            for m in convo.messages where m.text.localizedCaseInsensitiveContains(q) {
                msgs.append(MessageHit(convo: convo, message: m))
                if msgs.count >= 300 { break outer }
            }
        }
        return (convos, msgs)
    }

    fileprivate struct MessageHit: Identifiable, Sendable {
        var id: UUID { message.id }
        let convo: TMConversation
        let message: TMMessage
    }

    // MARK: Import / load

    private func importHTML(_ url: URL) {
        loading = true; note = nil
        let accessed = url.startAccessingSecurityScopedResource()
        Task {
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                loading = false; note = "Couldn't read that file."; return
            }
            library.saveTextMessageArchive(data, for: folder)   // remember it for next time
            let parsed = await parse(data)
            conversations = parsed
            loading = false
            note = parsed.isEmpty ? "No messages were recognized in that file. Send the export format to have it supported." : nil
        }
    }

    private func loadExisting() async {
        guard conversations.isEmpty, let url = library.textMessageArchiveURL(for: folder),
              let data = try? Data(contentsOf: url) else { return }
        loading = true
        conversations = await parse(data)
        loading = false
    }

    private func parse(_ data: Data) async -> [TMConversation] {
        let html = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        return await Task.detached(priority: .userInitiated) { TextMessageParser.parse(html: html) }.value
    }

    private func clear() {
        library.clearTextMessageArchive(for: folder)
        conversations = []; note = nil; query = ""; convoHits = []; msgHits = []; searching = false
    }
}

// MARK: - Conversation row (inbox)

private struct ConversationRow: View {
    let convo: TMConversation

    var body: some View {
        HStack(spacing: 12) {
            Avatar(name: convo.displayName)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(convo.displayName).font(.body.weight(.semibold)).lineLimit(1)
                    Spacer()
                    if let d = convo.lastDate {
                        Text(Self.listDate(d)).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Text(convo.preview).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }

    static func listDate(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return d.formatted(date: .omitted, time: .shortened) }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        if let days = cal.dateComponents([.day], from: d, to: Date()).day, days < 7 {
            return d.formatted(.dateTime.weekday(.wide))
        }
        return d.formatted(.dateTime.month(.abbreviated).day().year())
    }
}

/// Circular initials avatar (iOS shows a gray monogram when there's no contact photo).
private struct Avatar: View {
    let name: String
    var body: some View {
        Circle().fill(Color(.systemGray3))
            .frame(width: 44, height: 44)
            .overlay { Text(initials).font(.headline).foregroundStyle(.white) }
    }
    private var initials: String {
        let parts = name.split(whereSeparator: { $0 == " " || $0 == "," }).prefix(2)
        let letters = parts.compactMap { $0.first.map(String.init) }.joined()
        return letters.isEmpty ? "#" : letters.uppercased()
    }
}

/// A message search hit row (conversation name + the matching message, highlighted).
private struct MessageHitRow: View {
    let hit: TextMessagesView.MessageHit
    let query: String
    var body: some View {
        HStack(spacing: 12) {
            Avatar(name: hit.convo.displayName)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(hit.convo.displayName).font(.body.weight(.semibold)).lineLimit(1)
                    Spacer()
                    if let d = hit.message.date {
                        Text(ConversationRow.listDate(d)).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Text(MessageHighlight.attributed(hit.message.text, highlighting: query))
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Thread (bubbles)

/// One conversation's bubble thread — iOS-Messages-style: outgoing blue on the right, incoming gray
/// on the left, centered time separators when there's a gap, sender names in group threads. Its own
/// search highlights matches and jumps to them.
struct MessageThreadView: View {
    let conversation: TMConversation
    var initialSearch: String = ""
    var scrollTo: UUID? = nil

    @State private var query = ""
    @State private var rows: [ThreadRow] = []      // built once off-main; messages are already sorted
    @State private var built = false

    private var term: String { query.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(rows) { row in
                        if let sep = row.separator {
                            Text(sep).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity).padding(.vertical, 8).id(row.id)
                        } else if let m = row.message {
                            MessageBubble(message: m, showSender: row.showSender, highlight: term).id(m.id)
                        }
                    }
                }
                .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 10)
            }
            .background(Color(.systemBackground))
            .defaultScrollAnchor(.bottom)      // open at the newest message, cheaply (no scrollTo over 50k rows)
            .task {
                guard !built else { return }
                built = true
                if !initialSearch.isEmpty { query = initialSearch }
                let convo = conversation
                rows = await Task.detached(priority: .userInitiated) { Self.buildRows(convo) }.value
                // A message tapped from global search: jump to it once the rows exist.
                if let target = scrollTo {
                    try? await Task.sleep(nanoseconds: 120_000_000)
                    withAnimation { proxy.scrollTo(target, anchor: .center) }
                }
            }
        }
        .navigationTitle(conversation.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Search this conversation")
    }

    /// Date separators interleaved with messages (chronological). `nonisolated` so it can run off the
    /// main actor for a huge thread. Messages arrive pre-sorted, so this is a single linear pass.
    nonisolated private static func buildRows(_ conversation: TMConversation) -> [ThreadRow] {
        var out: [ThreadRow] = []
        var lastDate: Date?
        var lastSender: String? = nil
        let isGroup = conversation.isGroup
        for m in conversation.messages {
            if let d = m.date, lastDate == nil || d.timeIntervalSince(lastDate!) > 3600 {
                out.append(ThreadRow(separator: separator(d)))
                lastSender = nil
            }
            // Show the sender name above a received bubble in a group thread when the sender changes.
            let show = isGroup && !m.isFromMe && !m.sender.isEmpty && m.sender != lastSender
            out.append(ThreadRow(message: m, showSender: show))
            if let d = m.date { lastDate = d }
            lastSender = m.isFromMe ? nil : m.sender
        }
        return out
    }

    nonisolated private static func separator(_ d: Date) -> String {
        let cal = Calendar.current
        let time = d.formatted(date: .omitted, time: .shortened)
        if cal.isDateInToday(d) { return "Today \(time)" }
        if cal.isDateInYesterday(d) { return "Yesterday \(time)" }
        if let days = cal.dateComponents([.day], from: d, to: Date()).day, days < 7 {
            return "\(d.formatted(.dateTime.weekday(.wide))) \(time)"
        }
        return d.formatted(.dateTime.month(.abbreviated).day().year().hour().minute())
    }

    private struct ThreadRow: Identifiable, Sendable {
        let id = UUID()
        var separator: String? = nil
        var message: TMMessage? = nil
        var showSender: Bool = false
    }
}

/// One chat bubble.
private struct MessageBubble: View {
    let message: TMMessage
    let showSender: Bool
    let highlight: String

    /// Incoming gray; outgoing iMessage blue; outgoing SMS green — like iOS.
    private var bubbleColor: Color {
        guard message.isFromMe else { return Color(.systemGray5) }
        return message.isSMS ? Color.green : Color.blue
    }

    var body: some View {
        HStack {
            if message.isFromMe { Spacer(minLength: 44) }
            VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 2) {
                if showSender {
                    Text(message.sender).font(.caption2).foregroundStyle(.secondary).padding(.leading, 12)
                }
                Text(MessageHighlight.attributed(message.text, highlighting: highlight))
                    .font(.body)
                    .foregroundStyle(message.isFromMe ? Color.white : Color.primary)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(bubbleColor, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .textSelection(.enabled)
            }
            if !message.isFromMe { Spacer(minLength: 44) }
        }
    }
}

// MARK: - Search highlight

enum MessageHighlight {
    /// `text` with every case-insensitive occurrence of `term` highlighted (yellow).
    static func attributed(_ text: String, highlighting term: String) -> AttributedString {
        guard !term.isEmpty else { return AttributedString(text) }
        var result = AttributedString()
        var idx = text.startIndex
        while idx < text.endIndex, let r = text.range(of: term, options: .caseInsensitive, range: idx..<text.endIndex) {
            if r.lowerBound > idx { result += AttributedString(String(text[idx..<r.lowerBound])) }
            var hit = AttributedString(String(text[r]))
            hit.backgroundColor = Color.yellow.opacity(0.6)
            hit.foregroundColor = Color.black
            result += hit
            idx = r.upperBound
            if r.isEmpty { break }
        }
        if idx < text.endIndex { result += AttributedString(String(text[idx...])) }
        return result
    }
}

// MARK: - Parser

/// Parses an exported iPhone Messages HTML file (the CopyTrans / "…iPhone's Messages" export shape)
/// into per-conversation threads.
///
/// Format: conversations are delimited by `<h2>Name: … Phone: … Email: …</h2>`. Inside each, elements
/// appear in document order — `<p class="cid">sender</p>` sets the current sender (a contact name or
/// number, emitted only when it changes, like iOS); `<p>… Date: MM-DD-YYYY HH:MM</p>` sets the current
/// timestamp; and a message is a `<div>` whose class gives direction: `main-left` (incoming, gray),
/// `main-right` (outgoing SMS, green), or `main-right-imsg` (outgoing iMessage, blue). Message text
/// lives in `<td class="mid-c">`; a photo attachment is `<img src="image/N.png">` — those image files
/// aren't part of the .html, so they render as a “📷 Photo” placeholder.
enum TextMessageParser {
    nonisolated static func parse(html raw: String) -> [TMConversation] {
        let html = stripped(raw)
        let heads = ranges(of: "<h2\\b[^>]*>([\\s\\S]*?)</h2>", in: html)
        // Accumulate raw messages per address key (some exports split one thread across sections),
        // then build each TMConversation ONCE so its sort + metadata are computed a single time.
        var byKey: [String: (display: String, address: String, messages: [TMMessage])] = [:]
        var order: [String] = []
        func add(_ display: String, _ key: String, _ msgs: [TMMessage]) {
            guard !msgs.isEmpty else { return }
            if byKey[key] == nil { order.append(key); byKey[key] = (display, key, msgs) }
            else { byKey[key]!.messages.append(contentsOf: msgs) }
        }
        if heads.isEmpty {
            add("Messages", "messages", messages(in: html))
        } else {
            for (i, head) in heads.enumerated() {
                let bodyStart = head.range.upperBound
                let bodyEnd = i + 1 < heads.count ? heads[i + 1].range.lowerBound : html.endIndex
                let body = String(html[bodyStart..<bodyEnd])
                let (name, phones) = parseHeader(head.capture)
                let display = !name.isEmpty ? name : (phones.first ?? "Unknown")
                let key = phones.isEmpty ? display.lowercased() : phones.map(normalize).sorted().joined(separator: "|")
                add(display, key, messages(in: body))
            }
        }
        let conversations = order.compactMap { byKey[$0] }
            .map { TMConversation(displayName: $0.display, address: $0.address, messages: $0.messages) }
        // Sort by recency once here (lastDate is stored, so the inbox never re-sorts on render).
        return conversations.sorted { ($0.lastDate ?? .distantPast) > ($1.lastDate ?? .distantPast) }
    }

    /// Parses an `<h2>` header ("Name: … Phone: … Email: …") into the display name and phone list.
    nonisolated private static func parseHeader(_ inner: String) -> (name: String, phones: [String]) {
        let text = plainText(inner)
        let name = between(text, "Name:", "Phone:") ?? between(text, "Name:", "Email:") ?? ""
        let phoneField = between(text, "Phone:", "Email:") ?? after(text, "Phone:") ?? ""
        let phones = phoneField.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return (name.trimmingCharacters(in: .whitespaces), phones)
    }

    /// Walks a conversation body's elements in document order, keeping the sticky date and sender.
    nonisolated private static func messages(in body: String) -> [TMMessage] {
        var out: [TMMessage] = []
        var currentDate: Date?
        var currentSender = ""
        // Each top-level element: a <p> (sender/date/event) or a message <div>. Non-greedy to the
        // first close tag — messages nest only tables, never other <div>/<p>, so this is exact.
        let elementRE = "<p\\b[^>]*>[\\s\\S]*?</p>|<div class=\"(?:main-left|main-right-imsg|main-right)\">[\\s\\S]*?</div>"
        for m in matches(of: elementRE, in: body) {
            let el = m[0]
            if el.hasPrefix("<p") {
                if el.contains("class=\"cid\"") {
                    let s = plainText(el); if !s.isEmpty { currentSender = s }
                } else if let d = firstCapture("Date:\\s*(\\d{1,2}-\\d{1,2}-\\d{4}\\s+\\d{1,2}:\\d{2})", in: el) {
                    currentDate = parseExportDate(d)
                }
                continue
            }
            // A message div. Direction from the class; text from the mid-c cell(s).
            let incoming = el.contains("\"main-left\"")
            let outgoingSMS = el.contains("\"main-right\"")     // green; main-right-imsg is blue
            let text = messageText(el)
            guard !text.isEmpty else { continue }
            out.append(TMMessage(text: text, date: currentDate, isFromMe: !incoming,
                                 isSMS: outgoingSMS, sender: incoming ? currentSender : ""))
        }
        return out
    }

    /// The message body: the joined `mid-c` cell text, plus a “📷 Photo” marker for a photo
    /// attachment (`<img src="image/…">`) whose file isn't part of the imported .html.
    nonisolated private static func messageText(_ div: String) -> String {
        var parts: [String] = []
        for m in matches(of: "<td class=\"mid-c\">([\\s\\S]*?)</td>", in: div) {
            let t = plainText(m[1]); if !t.isEmpty { parts.append(t) }
        }
        var text = parts.joined(separator: "\n")
        if div.range(of: "<img[^>]*src=\"image/", options: [.regularExpression, .caseInsensitive]) != nil {
            text = text.isEmpty ? "📷 Photo" : text + " 📷"
        }
        return text
    }

    nonisolated private static func parseExportDate(_ s: String) -> Date? {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "M-d-yyyy H:mm"; f.timeZone = .current
        return f.date(from: s.trimmingCharacters(in: .whitespaces))
    }

    /// Substring strictly between `a` and the first following `b`.
    nonisolated private static func between(_ s: String, _ a: String, _ b: String) -> String? {
        guard let ra = s.range(of: a), let rb = s.range(of: b, range: ra.upperBound..<s.endIndex) else { return nil }
        return String(s[ra.upperBound..<rb.lowerBound])
    }
    nonisolated private static func after(_ s: String, _ a: String) -> String? {
        guard let ra = s.range(of: a) else { return nil }
        return String(s[ra.upperBound...])
    }

    // MARK: helpers

    /// Removes `<script>`/`<style>` blocks and HTML comments so their contents can't be mis-parsed.
    nonisolated private static func stripped(_ html: String) -> String {
        var s = html
        for p in ["<script[\\s\\S]*?</script>", "<style[\\s\\S]*?</style>", "<!--[\\s\\S]*?-->"] {
            s = s.replacingOccurrences(of: p, with: " ", options: [.regularExpression, .caseInsensitive])
        }
        return s
    }

    /// Visible text of an HTML fragment: tags stripped, entities decoded, whitespace collapsed.
    nonisolated private static func plainText(_ html: String) -> String {
        var s = html.replacingOccurrences(of: "<br[^>]*>", with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "</(?:p|div|li|tr)>", with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        s = decodeEntities(s)
        // Collapse runs of spaces/tabs but keep intentional newlines.
        s = s.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: " *\\n *", with: "\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func decodeEntities(_ s: String) -> String {
        var out = s
        // Numeric entities first (so a decoded "&#38;" → "&" isn't then re-read as a named entity).
        out = replaceNumeric(out, "&#x([0-9A-Fa-f]+);", radix: 16)
        out = replaceNumeric(out, "&#(\\d+);", radix: 10)
        let map = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'",
                   "&apos;": "'", "&nbsp;": " ", "&hellip;": "…", "&mdash;": "—", "&ndash;": "–"]
        for (k, v) in map { out = out.replacingOccurrences(of: k, with: v) }
        return out
    }

    /// Replaces `&#N;` / `&#xH;` numeric character references with their scalar.
    nonisolated private static func replaceNumeric(_ s: String, _ pattern: String, radix: Int) -> String {
        guard let re = regex(pattern) else { return s }
        let result = NSMutableString(string: s)
        let ns = s as NSString
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)).reversed() {
            let code = ns.substring(with: m.range(at: 1))
            if let value = UInt32(code, radix: radix), let scalar = UnicodeScalar(value) {
                result.replaceCharacters(in: m.range, with: String(scalar))
            }
        }
        return result as String
    }

    /// Reduces a phone number to its comparable core (last 10 digits, so +1-631-… matches 631-…).
    nonisolated private static func normalize(_ address: String) -> String {
        let digits = address.filter { $0.isNumber }
        return digits.count >= 7 ? String(digits.suffix(10)) : address.lowercased()
    }

    // MARK: regex utilities (local — the app has no HTML DOM parser and no third-party deps)

    nonisolated private static let cache = NSCache<NSString, NSRegularExpression>()
    nonisolated private static func regex(_ pattern: String) -> NSRegularExpression? {
        if let c = cache.object(forKey: pattern as NSString) { return c }
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return nil }
        cache.setObject(re, forKey: pattern as NSString); return re
    }
    nonisolated private static func matches(of pattern: String, in s: String) -> [[String]] {
        guard let re = regex(pattern) else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { m in
            (0..<m.numberOfRanges).map { i in
                let r = m.range(at: i); return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
        }
    }
    nonisolated private static func firstCapture(_ pattern: String, in s: String) -> String? {
        guard let re = regex(pattern) else { return nil }
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges > 1 else { return nil }
        let r = m.range(at: 1); return r.location == NSNotFound ? nil : ns.substring(with: r)
    }
    /// Header ranges + their captured title text, in document order.
    nonisolated private static func ranges(of pattern: String, in s: String) -> [(range: Range<String.Index>, capture: String)] {
        guard let re = regex(pattern) else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            guard let full = Range(m.range, in: s) else { return nil }
            let cap = m.numberOfRanges > 1 && m.range(at: 1).location != NSNotFound ? ns.substring(with: m.range(at: 1)) : ""
            return (full, cap)
        }
    }
}
