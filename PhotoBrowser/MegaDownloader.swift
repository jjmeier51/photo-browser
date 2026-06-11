import Foundation

/// Downloads the photos/videos inside a **public MEGA folder link** straight into
/// a drive folder, with no third-party SDK.
///
/// This is the one place the app touches the network. MEGA is end-to-end
/// encrypted, so there is no plain HTTPS file to GET: we speak MEGA's public
/// client API (`g.api.mega.co.nz`) to read the encrypted node tree, decrypt the
/// node keys + names with the key embedded in the folder link, then for each file
/// fetch a temporary storage URL and AES-CTR-decrypt the bytes as they stream to
/// disk. CryptoKit only offers AEAD ciphers, so the AES ECB/CBC/CTR work goes
/// through CommonCrypto (exposed via the bridging header) — see `MegaCrypto`.
///
/// Everything here is `nonisolated` and runs off the main actor: networking,
/// crypto and file writes must never block the UI (same rule as the rest of the
/// app's heavy I/O). The protocol is unofficial/reverse-engineered and MEGA can
/// change it; failures are surfaced as a friendly note rather than crashing.

struct MegaProgress: Sendable {
    var fraction: Double
    var done: Int
    var total: Int
    var currentName: String
}

struct MegaImportResult: Sendable {
    var imported: Int
    var failed: Int
    var folderName: String?
    var note: String?
}

enum MegaError: Error {
    case badLink, badResponse, crypto, io
    case api(Int)
}

/// One node (file or folder) in a MEGA folder tree, with its decrypted key/name.
private struct MegaNode: Sendable {
    let handle: String
    let parent: String
    let type: Int          // 0 = file, 1 = folder, 2 = root
    let name: String
    let size: Int64
    let aesKey: [UInt8]     // 16-byte AES key (file content / attribute key)
    let nonce: [UInt8]      // 8-byte CTR nonce (files only)
}

enum MegaDownloader {

    private static let apiBase = "https://g.api.mega.co.nz/cs"

    // MARK: - Entry point

    /// Imports every photo/video from `link` (a MEGA folder URL) into a new
    /// subfolder of `parent` named after the MEGA folder, preserving subfolders.
    nonisolated static func importFolder(link: String, into parent: URL,
                                         progress: @escaping @Sendable (MegaProgress) -> Void) async -> MegaImportResult {
        guard let (folderID, masterKey) = parseFolderLink(link) else {
            return MegaImportResult(imported: 0, failed: 0, folderName: nil,
                                    note: "That doesn’t look like a MEGA folder link. Use a https://mega.nz/folder/… link.")
        }

        progress(MegaProgress(fraction: 0, done: 0, total: 0, currentName: "Reading folder…"))
        let nodes: [MegaNode]
        do { nodes = try await fetchNodes(folderID: folderID, masterKey: masterKey) }
        catch { return MegaImportResult(imported: 0, failed: 0, folderName: nil, note: friendlyError(error)) }

        // The root is the folder node whose parent isn't itself a folder in the tree.
        let folderHandles = Set(nodes.filter { $0.type >= 1 }.map { $0.handle })
        let rootHandle = nodes.first { $0.type >= 1 && !folderHandles.contains($0.parent) }?.handle
        let rootName = nodes.first { $0.handle == rootHandle }?.name
        let files = mediaFiles(from: nodes, rootHandle: rootHandle)
        guard !files.isEmpty else {
            return MegaImportResult(imported: 0, failed: 0, folderName: rootName,
                                    note: "No photos or videos found in that MEGA folder.")
        }

        let fm = FileManager.default
        let destRoot = uniqueURL(for: sanitize(rootName ?? "MEGA Import"), in: parent)
        try? fm.createDirectory(at: destRoot, withIntermediateDirectories: true)

        let total = files.count
        var imported = 0, failed = 0
        for (i, item) in files.enumerated() {
            progress(MegaProgress(fraction: Double(i) / Double(total), done: imported,
                                  total: total, currentName: item.node.name))
            let targetDir = destRoot.appendingPathComponent(item.relativeDir, isDirectory: true)
            do {
                try fm.createDirectory(at: targetDir, withIntermediateDirectories: true)
                let dest = uniqueURL(for: sanitize(item.node.name), in: targetDir)
                try await downloadFile(item.node, folderID: folderID, to: dest)
                imported += 1
            } catch {
                failed += 1
            }
        }
        progress(MegaProgress(fraction: 1, done: imported, total: total, currentName: ""))

        let note = imported == 0 ? "Couldn’t download any files from that MEGA folder." : nil
        return MegaImportResult(imported: imported, failed: failed,
                                folderName: destRoot.lastPathComponent, note: note)
    }

    // MARK: - Link parsing

    /// Pulls the folder id and 16-byte master key out of a folder link. Handles the
    /// new `…/folder/<id>#<key>` form and the legacy `…#F!<id>!<key>` form.
    nonisolated private static func parseFolderLink(_ link: String) -> (id: String, key: [UInt8])? {
        let s = link.trimmingCharacters(in: .whitespacesAndNewlines)
        func key(from raw: String) -> [UInt8]? {
            var part = raw
            if let slash = part.firstIndex(of: "/") { part = String(part[..<slash]) }   // drop deep-link tail
            let bytes = MegaCrypto.base64ToBytes(part)
            return bytes.count >= 16 ? Array(bytes.prefix(16)) : nil
        }
        if let r = s.range(of: "/folder/") {
            let rest = String(s[r.upperBound...])
            guard let hash = rest.firstIndex(of: "#") else { return nil }
            let id = String(rest[..<hash])
            guard let k = key(from: String(rest[rest.index(after: hash)...])), !id.isEmpty else { return nil }
            return (id, k)
        }
        if let r = s.range(of: "#F!") {
            let parts = String(s[r.upperBound...]).split(separator: "!", maxSplits: 1,
                                                         omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2, let k = key(from: parts[1]), !parts[0].isEmpty else { return nil }
            return (parts[0], k)
        }
        return nil
    }

    // MARK: - API

    nonisolated private static func apiRequest(folderID: String, payload: [[String: Any]]) async throws -> [Any] {
        var comps = URLComponents(string: apiBase)!
        comps.queryItems = [URLQueryItem(name: "id", value: String(Int.random(in: 0..<10_000_000))),
                            URLQueryItem(name: "n", value: folderID)]
        guard let url = comps.url else { throw MegaError.badResponse }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        for attempt in 0..<5 {
            let (data, _) = try await URLSession.shared.data(for: req)
            let obj = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            if let arr = obj as? [Any] { return arr }
            if let num = obj as? Int {
                // -3 EAGAIN / -4 rate-limited: back off and retry.
                if num == -3 || num == -4 {
                    try? await Task.sleep(nanoseconds: UInt64(attempt + 1) * 1_000_000_000)
                    continue
                }
                throw MegaError.api(num)
            }
            throw MegaError.badResponse
        }
        throw MegaError.api(-3)
    }

    nonisolated private static func fetchNodes(folderID: String, masterKey: [UInt8]) async throws -> [MegaNode] {
        let result = try await apiRequest(folderID: folderID, payload: [["a": "f", "c": 1, "r": 1, "ca": 1]])
        guard let first = result.first as? [String: Any] else { throw MegaError.badResponse }
        if let arr = first["f"] as? [[String: Any]] {
            return arr.compactMap { node(from: $0, masterKey: masterKey) }
        }
        throw MegaError.badResponse
    }

    nonisolated private static func node(from f: [String: Any], masterKey: [UInt8]) -> MegaNode? {
        guard let handle = f["h"] as? String, let type = f["t"] as? Int else { return nil }
        let parent = f["p"] as? String ?? ""
        let size = (f["s"] as? Int).map(Int64.init) ?? 0

        // The node key arrives encrypted with the folder's master key (AES-ECB).
        var decryptedKey = masterKey
        if let kField = f["k"] as? String, let enc = encryptedKey(from: kField) {
            let dec = MegaCrypto.aesEcbDecrypt(key: masterKey, data: enc)
            if !dec.isEmpty { decryptedKey = dec }
        }

        var aesKey = decryptedKey
        var nonce: [UInt8] = []
        if type == 0, decryptedKey.count >= 32 {
            // File key: 32 bytes → 16-byte AES key (first ⊕ last) + 8-byte nonce.
            aesKey = (0..<16).map { decryptedKey[$0] ^ decryptedKey[$0 + 16] }
            nonce = Array(decryptedKey[16..<24])
        } else if decryptedKey.count >= 16 {
            aesKey = Array(decryptedKey.prefix(16))
        }

        let name = (f["a"] as? String).flatMap { MegaCrypto.decryptAttributeName($0, key: aesKey) } ?? handle
        return MegaNode(handle: handle, parent: parent, type: type, name: name,
                        size: size, aesKey: aesKey, nonce: nonce)
    }

    /// The encrypted key bytes from a `k` field ("handle:keyB64[/handle:keyB64…]").
    nonisolated private static func encryptedKey(from field: String) -> [UInt8]? {
        let first = field.split(separator: "/").first.map(String.init) ?? field
        guard let colon = first.firstIndex(of: ":") else { return nil }
        let bytes = MegaCrypto.base64ToBytes(String(first[first.index(after: colon)...]))
        return bytes.isEmpty ? nil : bytes
    }

    // MARK: - File list / paths

    nonisolated private static func mediaFiles(from nodes: [MegaNode],
                                               rootHandle: String?) -> [(node: MegaNode, relativeDir: String)] {
        var byHandle: [String: MegaNode] = [:]
        for n in nodes { byHandle[n.handle] = n }

        func relativeDir(of node: MegaNode) -> String {
            var comps: [String] = []
            var current = byHandle[node.parent]
            var guardCount = 0
            while let c = current, c.type >= 1, c.handle != rootHandle, guardCount < 64 {
                comps.insert(sanitize(c.name), at: 0)
                current = byHandle[c.parent]
                guardCount += 1
            }
            return comps.joined(separator: "/")
        }

        return nodes.compactMap { node -> (node: MegaNode, relativeDir: String)? in
            guard node.type == 0 else { return nil }
            let kind = classify(url: URL(fileURLWithPath: node.name), isDirectory: false)
            guard kind == .image || kind == .video else { return nil }
            return (node, relativeDir(of: node))
        }
    }

    // MARK: - Download + decrypt

    nonisolated private static func downloadFile(_ node: MegaNode, folderID: String, to dest: URL) async throws {
        let result = try await apiRequest(folderID: folderID, payload: [["a": "g", "g": 1, "n": node.handle]])
        guard let first = result.first as? [String: Any] else { throw MegaError.badResponse }
        if let e = first["e"] as? Int { throw MegaError.api(e) }
        guard let link = first["g"] as? String, let url = URL(string: link) else { throw MegaError.badResponse }

        let (encrypted, _) = try await URLSession.shared.download(from: url)
        defer { try? FileManager.default.removeItem(at: encrypted) }

        // CTR IV = 8-byte nonce followed by an 8-byte zero block counter.
        var iv = node.nonce
        while iv.count < 16 { iv.append(0) }
        try MegaCrypto.decryptCTR(input: encrypted, output: dest, key: node.aesKey, iv: Array(iv.prefix(16)))
    }

    // MARK: - Helpers

    /// A filesystem-safe version of a MEGA name (no path separators / control chars).
    nonisolated private static func sanitize(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Untitled" : cleaned
    }

    /// Non-colliding destination URL (mirrors `FileActions.uniqueDestination`, kept
    /// local so it can run off the main actor).
    nonisolated private static func uniqueURL(for name: String, in folder: URL) -> URL {
        let fm = FileManager.default
        var dest = folder.appendingPathComponent(name.isEmpty ? "File" : name)
        let base = dest.deletingPathExtension().lastPathComponent
        let ext = dest.pathExtension
        var n = 1
        while fm.fileExists(atPath: dest.path) {
            let newName = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            dest = folder.appendingPathComponent(newName)
            n += 1
        }
        return dest
    }

    nonisolated private static func friendlyError(_ error: Error) -> String {
        if let mega = error as? MegaError {
            switch mega {
            case .badLink:     return "That MEGA link couldn’t be read."
            case .badResponse: return "MEGA returned an unexpected response. The link may be invalid or expired."
            case .crypto:      return "Couldn’t decrypt the MEGA folder — check the link’s key."
            case .io:          return "Couldn’t write the downloaded files to the drive."
            case .api(let n) where n == -9:  return "That MEGA folder no longer exists."
            case .api(let n) where n == -16: return "That MEGA folder is blocked or unavailable."
            case .api(let n):  return "MEGA reported an error (code \(n))."
            }
        }
        return "Couldn’t reach MEGA. Check your connection and the link."
    }
}
