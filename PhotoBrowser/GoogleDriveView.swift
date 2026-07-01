import SwiftUI
import UIKit

/// "Download from Google Drive": paste a shared folder/file link, or (with an access token) browse your
/// Drive and pick folders/items. Starting a download hands it to `Library` as an app-wide background
/// activity and dismisses — so it runs in the background and you can keep navigating the app. Downloads
/// are concurrent (fast) and never upload anything.
struct GoogleDriveView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let targetFolder: URL

    @State private var link = ""
    @State private var token = GoogleDrive.accessToken
    @State private var apiKey = GoogleDrive.apiKey
    @State private var editingAuth = !GoogleDrive.isConfigured

    // Browser state (needs an access token).
    @State private var stack: [(id: String, name: String)] = [(id: "root", name: "My Drive")]
    @State private var items: [GoogleDrive.Item] = []
    @State private var selected: [String: GoogleDrive.Item] = [:]     // id → item
    @State private var loading = false

    private var canBrowse: Bool { !token.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                if editingAuth || !GoogleDrive.isConfigured {
                    authSection
                }

                Section {
                    HStack {
                        TextField("Paste a Drive folder or file link", text: $link)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        if !link.isEmpty { Button { link = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) } }
                    }
                    Button {
                        library.startGoogleDriveDownload(link: link, into: targetFolder)
                        dismiss()
                    } label: { Label("Download this link", systemImage: "arrow.down.circle") }
                        .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty || !GoogleDrive.isConfigured)
                } header: {
                    Text("Download a link")
                } footer: {
                    Text("Works with a shared folder or file link (folder = the whole tree, file = that item). Downloads into “\(targetFolder.lastPathComponent)” and runs in the background — you can keep using the app.")
                }

                if canBrowse {
                    browserSection
                }
            }
            .navigationTitle("Google Drive")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if link.isEmpty, let p = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                   p.contains("drive.google.com") { link = p }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                if !selected.isEmpty {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Download (\(selected.count))") {
                            library.startGoogleDriveDownload(items: Array(selected.values), into: targetFolder)
                            dismiss()
                        }
                    }
                }
            }
        }
    }

    private var authSection: some View {
        Section {
            SecureField("Access token (OAuth)", text: $token)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            SecureField("API key (for public links)", text: $apiKey)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Save") {
                GoogleDrive.save(accessToken: token, apiKey: apiKey)
                editingAuth = false
                if canBrowse { Task { await load() } }
            }
        } header: {
            Text("Connect")
        } footer: {
            Text("An **access token** lets you browse and download from your own Drive (get one from Google's OAuth 2.0 Playground with the Drive scope; it expires after ~1 hour). An **API key** works for items shared “anyone with the link”. Everything stays on device — nothing is uploaded.")
        }
    }

    @ViewBuilder private var browserSection: some View {
        Section {
            // Breadcrumb + up button.
            HStack {
                if stack.count > 1 {
                    Button { stack.removeLast(); Task { await load() } } label: {
                        Image(systemName: "chevron.left")
                    }
                }
                Text(stack.map(\.name).joined(separator: " / ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if loading { ProgressView() }
            }
            ForEach(items) { item in
                row(item)
            }
            if !loading && items.isEmpty {
                Text("Empty folder.").font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                Text("Browse")
                Spacer()
                Button("Change token") { editingAuth = true }.font(.caption)
            }
        }
        .task(id: stack.map(\.id).joined()) { await load() }
    }

    private func row(_ item: GoogleDrive.Item) -> some View {
        HStack(spacing: 12) {
            Button {
                if selected[item.id] == nil { selected[item.id] = item } else { selected[item.id] = nil }
            } label: {
                Image(systemName: selected[item.id] != nil ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected[item.id] != nil ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)

            Image(systemName: icon(for: item)).frame(width: 22).foregroundStyle(item.isFolder ? Color.accentColor : Color.secondary)

            if item.isFolder {
                Button { stack.append((id: item.id, name: item.name)) } label: {
                    HStack {
                        Text(item.name).foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            } else {
                Text(item.name).foregroundStyle(item.isGoogleDoc ? .secondary : .primary)
                Spacer()
                if item.size > 0 { Text(item.size.sizeString).font(.caption2).foregroundStyle(.secondary) }
            }
        }
    }

    private func icon(for item: GoogleDrive.Item) -> String {
        if item.isFolder { return "folder.fill" }
        if item.mimeType.hasPrefix("image/") { return "photo" }
        if item.mimeType.hasPrefix("video/") { return "video" }
        if item.isGoogleDoc { return "doc.text" }
        return "doc"
    }

    private func load() async {
        guard canBrowse, let current = stack.last?.id else { return }
        loading = true
        items = await GoogleDrive.list(folderID: current)
        loading = false
    }
}
