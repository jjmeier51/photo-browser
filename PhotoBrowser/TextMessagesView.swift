import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Model

/// One text message inside a conversation.
struct TMMessage: Identifiable, Hashable, Sendable {
    let id = UUID()
    let text: String
    let date: Date?
    let isFromMe: Bool          // outgoing (right, blue) vs incoming (left, gray)
    let sender: String          // display sender for group threads ("" when unknown / it's me)
}

/// All messages exchanged with one address (phone number / handle / contact), grouped together.
struct TMConversation: Identifiable, Sendable {
    let id = UUID()
    let displayName: String     // contact name, or the phone number if that's all we have
    let address: String         // normalized phone/handle — the grouping key
    var messages: [TMMessage]

    var lastDate: Date? { messages.compactMap(\.date).max() }
    var preview: String {
        (messages.last { !$0.text.isEmpty })?.text ?? messages.last?.text ?? ""
    }
    /// Whether more than one person (besides me) appears — drives showing sender names.
    var isGroup: Bool {
        Set(messages.filter { !$0.isFromMe }.map(\.sender).filter { !$0.isEmpty }).count > 1
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

    @State private var conversations: [TMConversation] = []
    @State private var loading = false
    @State private var loadedOnce = false
    @State private var showImporter = false
    @State private var note: String?
    @State private var query = ""

    private var sorted: [TMConversation] {
        conversations.sorted { ($0.lastDate ?? .distantPast) > ($1.lastDate ?? .distantPast) }
    }

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
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                ForEach(sorted) { convo in
                    NavigationLink { MessageThreadView(conversation: convo) } label: { ConversationRow(convo: convo) }
                }
            } else {
                searchResults
            }
        }
        .listStyle(.plain)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search Messages")
    }

    /// iOS-Messages-style search: matching conversations (by name/number), then matching messages.
    @ViewBuilder private var searchResults: some View {
        let q = query.trimmingCharacters(in: .whitespaces)
        let convoHits = sorted.filter {
            $0.displayName.localizedCaseInsensitiveContains(q) || $0.address.localizedCaseInsensitiveContains(q)
        }
        let msgHits: [MessageHit] = Array(sorted.flatMap { convo in
            convo.messages.filter { $0.text.localizedCaseInsensitiveContains(q) }
                .map { MessageHit(convo: convo, message: $0) }
        }.prefix(300))
        if convoHits.isEmpty && msgHits.isEmpty {
            Text("No results").foregroundStyle(.secondary)
        }
        if !convoHits.isEmpty {
            Section("Conversations") {
                ForEach(convoHits) { convo in
                    NavigationLink { MessageThreadView(conversation: convo, initialSearch: q) } label: { ConversationRow(convo: convo) }
                }
            }
        }
        if !msgHits.isEmpty {
            Section("Messages") {
                ForEach(msgHits) { hit in
                    NavigationLink {
                        MessageThreadView(conversation: hit.convo, initialSearch: q, scrollTo: hit.message.id)
                    } label: {
                        MessageHitRow(hit: hit, query: q)
                    }
                }
            }
        }
    }

    fileprivate struct MessageHit: Identifiable {
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
        conversations = []; note = nil; query = ""
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
    @State private var didInit = false

    private var effectiveTerm: String { query.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(rows) { row in
                        if let sep = row.separator {
                            Text(sep).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity).padding(.vertical, 8).id(row.id)
                        } else if let m = row.message {
                            MessageBubble(message: m, showSender: row.showSender, highlight: effectiveTerm).id(m.id)
                        }
                    }
                    Color.clear.frame(height: 1).id(Self.bottomID)
                }
                .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 10)
            }
            .background(Color(.systemBackground))
            .onAppear {
                guard !didInit else { return }
                didInit = true
                if !initialSearch.isEmpty { query = initialSearch }
                // Jump to the searched message, else to the newest (bottom), like opening a thread.
                DispatchQueue.main.async {
                    if let scrollTo { withAnimation { proxy.scrollTo(scrollTo, anchor: .center) } }
                    else { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                }
            }
            .onChange(of: effectiveTerm) { _, term in
                guard !term.isEmpty, let first = conversation.messages.first(where: { $0.text.localizedCaseInsensitiveContains(term) }) else { return }
                withAnimation { proxy.scrollTo(first.id, anchor: .center) }
            }
        }
        .navigationTitle(conversation.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Search this conversation")
    }

    private static let bottomID = "tm-bottom"

    // Rows: date separators interleaved with messages (chronological).
    private var rows: [ThreadRow] {
        let msgs = conversation.messages.sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
        var out: [ThreadRow] = []
        var lastDate: Date?
        var lastSender: String? = nil
        for m in msgs {
            if let d = m.date, lastDate == nil || d.timeIntervalSince(lastDate!) > 3600 {
                out.append(ThreadRow(separator: Self.separator(d)))
                lastSender = nil
            }
            // Show the sender name above a received bubble in a group thread when the sender changes.
            let show = conversation.isGroup && !m.isFromMe && !m.sender.isEmpty && m.sender != lastSender
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

    private struct ThreadRow: Identifiable {
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
                    .background(message.isFromMe ? Color.blue : Color(.systemGray5),
                                in: RoundedRectangle(cornerRadius: 18, style: .continuous))
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

/// Parses an exported text-message HTML file into per-address conversations.
///
/// ⚠️ Text-message HTML exports have **no single standard shape** (iMazing, iExplorer, AnyTrans,
/// "SMS Backup & Restore", decompiled carrier exports, and hand-rolled ones all differ). This is a
/// best-effort generic pass and the one piece meant to be tuned to the exact export the user
/// provides — the model and the whole viewer above are format-independent, so finalizing this
/// function is all that's needed once the real HTML is in hand.
///
/// The generic pass: strip scripts/styles → split into conversation sections at heading/contact
/// markers (else treat the whole file as one) → within each, read message blocks (an element whose
/// class hints at a message / bubble / sent / received), pulling the text, a timestamp, and the
/// direction. Returns `[]` cleanly when nothing is recognized.
enum TextMessageParser {
    nonisolated static func parse(html raw: String) -> [TMConversation] {
        let html = stripped(raw)

        // Split into conversation chunks at common section markers; fall back to one conversation.
        let chunks = conversationChunks(html)
        var conversations: [TMConversation] = []
        for chunk in chunks {
            let msgs = messages(in: chunk.body)
            guard !msgs.isEmpty else { continue }
            let name = chunk.title.isEmpty ? (inferAddress(from: msgs) ?? "Unknown") : chunk.title
            conversations.append(TMConversation(displayName: name, address: chunk.address.isEmpty ? name : chunk.address,
                                                messages: msgs))
        }
        // Merge chunks that resolved to the same address (some exports repeat a thread per page).
        return mergedByAddress(conversations)
    }

    // MARK: chunking

    private struct Chunk: Sendable { var title: String; var address: String; var body: String }

    /// Splits the document at conversation headers. Recognizes a few common markers; when none are
    /// present the whole document is one conversation.
    nonisolated private static func conversationChunks(_ html: String) -> [Chunk] {
        // Heading tags (h1/h2/h3) or elements whose class marks a conversation/thread/contact header.
        let headerPattern = "<(?:h[1-3])[^>]*>([\\s\\S]*?)</(?:h[1-3])>"
        let heads = ranges(of: headerPattern, in: html)
        guard heads.count >= 2 else {
            return [Chunk(title: "", address: "", body: html)]
        }
        var chunks: [Chunk] = []
        for (i, head) in heads.enumerated() {
            let bodyStart = head.range.upperBound
            let bodyEnd = i + 1 < heads.count ? heads[i + 1].range.lowerBound : html.endIndex
            let title = plainText(head.capture)
            chunks.append(Chunk(title: title, address: phone(in: title) ?? "", body: String(html[bodyStart..<bodyEnd])))
        }
        return chunks
    }

    // MARK: messages within a chunk

    nonisolated private static func messages(in html: String) -> [TMMessage] {
        // Message blocks: elements whose class contains a message-ish word. Captures the class (for
        // direction) and the inner HTML (for text + timestamp).
        let pattern = "<(?:div|p|li|tr|td|span)[^>]*class=\"([^\"]*(?:message|bubble|msg|sms|imessage|sent|received|outgoing|incoming|from-me|to-me)[^\"]*)\"[^>]*>([\\s\\S]*?)</(?:div|p|li|tr|td|span)>"
        var out: [TMMessage] = []
        for m in matches(of: pattern, in: html) {
            let cls = m[1].lowercased()
            let inner = m[2]
            let text = messageText(inner)
            guard !text.isEmpty else { continue }
            let fromMe = cls.contains("sent") || cls.contains("outgoing") || cls.contains("from-me")
                || cls.contains("from_me") || cls.contains("me ") || cls.hasSuffix("me")
            out.append(TMMessage(text: text, date: timestamp(inner), isFromMe: fromMe, sender: sender(inner)))
        }
        return out
    }

    /// The message body text — prefer an inner element that looks like the text, else all text minus
    /// obvious timestamp/sender chrome.
    nonisolated private static func messageText(_ inner: String) -> String {
        if let t = firstCapture("class=\"[^\"]*(?:text|body|content|bubble-text)[^\"]*\"[^>]*>([\\s\\S]*?)<", in: inner) {
            let s = plainText(t); if !s.isEmpty { return s }
        }
        return plainText(inner)
    }

    nonisolated private static func sender(_ inner: String) -> String {
        firstCapture("class=\"[^\"]*(?:sender|author|name|from)[^\"]*\"[^>]*>([\\s\\S]*?)<", in: inner).map(plainText) ?? ""
    }

    /// A timestamp inside a block — from a `datetime`/`data-*` attribute (epoch or ISO), or visible text.
    nonisolated private static func timestamp(_ inner: String) -> Date? {
        if let epoch = firstCapture("data-(?:time|timestamp|date)=\"(\\d{9,13})\"", in: inner), let t = Double(epoch) {
            return Date(timeIntervalSince1970: t > 1_000_000_000_000 ? t / 1000 : t)
        }
        if let iso = firstCapture("(?:datetime|data-time)=\"([^\"]+)\"", in: inner), let d = parseDate(iso) { return d }
        // Visible timestamp text in a timestamp-classed element, else any date-looking run.
        if let vis = firstCapture("class=\"[^\"]*(?:time|date|timestamp)[^\"]*\"[^>]*>([\\s\\S]*?)<", in: inner) {
            if let d = parseDate(plainText(vis)) { return d }
        }
        return parseDate(plainText(inner))
    }

    // MARK: helpers

    nonisolated private static func mergedByAddress(_ convos: [TMConversation]) -> [TMConversation] {
        var byKey: [String: TMConversation] = [:]
        var order: [String] = []
        for c in convos {
            let key = normalize(c.address)
            if var existing = byKey[key] {
                existing.messages.append(contentsOf: c.messages)
                byKey[key] = existing
            } else {
                byKey[key] = c; order.append(key)
            }
        }
        return order.compactMap { byKey[$0] }
    }

    nonisolated private static func inferAddress(from messages: [TMMessage]) -> String? {
        messages.lazy.compactMap { $0.sender.isEmpty ? nil : $0.sender }.first
    }

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

    nonisolated private static func phone(in s: String) -> String? {
        firstCapture("(\\+?\\d[\\d\\-\\(\\)\\s]{6,}\\d)", in: s).map { $0.trimmingCharacters(in: .whitespaces) }
    }
    nonisolated private static func normalize(_ address: String) -> String {
        let digits = address.filter { $0.isNumber }
        return digits.count >= 7 ? String(digits.suffix(11)) : address.lowercased()
    }

    nonisolated private static let isoFormatter = ISO8601DateFormatter()
    nonisolated private static func parseDate(_ s: String) -> Date? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 6 else { return nil }
        if let d = isoFormatter.date(from: trimmed) { return d }
        for fmt in ["MMM d, yyyy h:mm:ss a", "MMM d, yyyy h:mm a", "MMM d, yyyy, h:mm a",
                    "M/d/yy h:mm a", "M/d/yyyy h:mm a", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss",
                    "MMMM d, yyyy 'at' h:mm a", "dd/MM/yyyy HH:mm"] {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = fmt
            if let d = f.date(from: trimmed) { return d }
        }
        return nil
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
