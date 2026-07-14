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
    var skipped: Int = 0        // files already present on disk (a re-import fills only the gaps)
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

    /// A dedicated session with a higher per-host connection cap than `URLSession.shared` (which
    /// tops out around 6). MEGA serves all of a file's range chunks from a single storage host, so
    /// more connections directly means faster large downloads. Used for the API and every fetch.
    nonisolated private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.httpMaximumConnectionsPerHost = 10
        cfg.timeoutIntervalForRequest = 60
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData   // encrypted blobs, nothing to cache
        return URLSession(configuration: cfg)
    }()

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
        // Reuse an existing folder of the same name instead of making "Name 1". This is what lets a
        // re-import fill in only the files that aren't there yet (e.g. ones that failed last time).
        let destRoot = parent.appendingPathComponent(sanitize(rootName ?? "MEGA Import"), isDirectory: true)
        try? fm.createDirectory(at: destRoot, withIntermediateDirectories: true)

        // Assign every file a stable destination up front, single-threaded: duplicate names in the
        // same MEGA folder de-dupe deterministically (by order, NOT by what's on disk), so a re-run
        // maps each file to the exact same path and can tell what's already downloaded.
        var used = Set<String>()
        var planned: [(node: MegaNode, dest: URL)] = []
        planned.reserveCapacity(files.count)
        for item in files {
            let dir = destRoot.appendingPathComponent(item.relativeDir, isDirectory: true)
            planned.append((item.node, dedupedURL(dir, sanitize(item.node.name), &used)))
        }

        let total = planned.count
        // Download several files at once (each large file is itself split into parallel range chunks
        // by downloadFile). Kept bounded so files × chunks doesn't open too many connections; the
        // `g` requests self-heal from rate-limit (-3) replies via apiRequest's retry.
        let maxConcurrent = 6
        var imported = 0, failed = 0, skipped = 0, completed = 0
        var firstFailure: String?
        await withTaskGroup(of: (ok: Bool, error: String?, skipped: Bool).self) { group in
            var index = 0
            func addNext() {
                guard index < planned.count else { return }
                let p = planned[index]; index += 1
                group.addTask {
                    do {
                        try FileManager.default.createDirectory(at: p.dest.deletingLastPathComponent(),
                                                                withIntermediateDirectories: true)
                        // Already fully downloaded (byte-for-byte the expected size)? Leave it be.
                        if isComplete(p.dest, expected: p.node.size) { return (true, nil, true) }
                        try await downloadFile(p.node, folderID: folderID, to: p.dest)
                        return (true, nil, false)
                    } catch {
                        return (false, friendlyError(error), false)
                    }
                }
            }
            for _ in 0..<min(maxConcurrent, planned.count) { addNext() }
            while let result = await group.next() {
                completed += 1
                if result.ok {
                    if result.skipped { skipped += 1 } else { imported += 1 }
                } else {
                    failed += 1; if firstFailure == nil { firstFailure = result.error }
                }
                progress(MegaProgress(fraction: Double(completed) / Double(total),
                                      done: imported + skipped, total: total, currentName: ""))
                addNext()
            }
        }
        progress(MegaProgress(fraction: 1, done: imported + skipped, total: total, currentName: ""))

        let note: String?
        if imported == 0 && failed == 0 {
            note = skipped > 0 ? "All \(skipped) file(s) were already downloaded — nothing new to fetch." : nil
        } else if imported == 0 {
            note = "Couldn’t download any files. " + (firstFailure ?? "Unknown error.")
        } else {
            var parts: [String] = []
            if skipped > 0 { parts.append("\(skipped) already present") }
            if failed > 0 { parts.append("\(failed) failed: \(firstFailure ?? "unknown error")") }
            note = parts.isEmpty ? nil : "(" + parts.joined(separator: ", ") + ")"
        }
        return MegaImportResult(imported: imported, failed: failed, skipped: skipped,
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
            let (data, _) = try await session.data(for: req)
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

    private static let chunkThreshold: Int64 = 8 << 20   // chunk files larger than 8 MB
    private static let chunkSize: Int64 = 4 << 20        // 4 MB per chunk (16-aligned)
    private static let chunkConcurrency = 8              // parallel range requests per large file

    nonisolated private static func downloadFile(_ node: MegaNode, folderID: String, to dest: URL) async throws {
        // `ssl:1` asks MEGA for a TLS download URL; even so it often returns a plain
        // http:// gfs URL, which iOS App Transport Security blocks. The same storage
        // host serves the identical (still-encrypted) bytes over TLS, so force https.
        let result = try await apiRequest(folderID: folderID,
                                          payload: [["a": "g", "g": 1, "ssl": 1, "n": node.handle]])
        guard let first = result.first as? [String: Any] else { throw MegaError.badResponse }
        if let e = first["e"] as? Int { throw MegaError.api(e) }
        guard var link = first["g"] as? String else { throw MegaError.badResponse }
        if link.hasPrefix("http://") { link = "https://" + link.dropFirst(7) }
        guard let url = URL(string: link) else { throw MegaError.badResponse }
        let size = (first["s"] as? Int).map(Int64.init) ?? node.size

        // CTR IV base = 8-byte nonce followed by an 8-byte zero block counter.
        var iv = node.nonce
        while iv.count < 16 { iv.append(0) }
        let baseIV = Array(iv.prefix(16))

        // Decrypt into a sibling temp on the same volume, then hand the final placement to
        // DriveWriter so the rename is serialized against every other download and F_FULLFSYNC'd.
        // Writing straight to `dest` (as before) left a large file's clusters allocated but its
        // directory entry unflushed — exactly the "used but not referenced" exFAT corruption that
        // showed up after an unplug mid-download.
        let tmp = dest.deletingLastPathComponent().appendingPathComponent(".pbtmp_" + UUID().uuidString)
        do {
            // Big files: download in parallel byte-range chunks (CTR is seekable, so each
            // chunk decrypts on its own) — this is what makes a single large video fast,
            // like the MEGA app. Small files: one request, then stream-decrypt to disk.
            if size > chunkThreshold {
                try await downloadChunked(url: url, size: size, key: node.aesKey, baseIV: baseIV, to: tmp)
            } else {
                let (encrypted, _) = try await session.download(from: url)
                defer { try? FileManager.default.removeItem(at: encrypted) }
                try MegaCrypto.decryptCTR(input: encrypted, output: tmp, key: node.aesKey, iv: baseIV)
            }
            try await DriveWriter.shared.commit(tmp, to: dest)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }

    /// Downloads `url` in parallel 4 MB byte-range chunks, decrypting each with the
    /// CTR counter advanced to its block offset, and writes them at the right place
    /// in the output file. MEGA storage honors HTTP range requests, so this keeps
    /// several connections busy at once instead of trickling through one.
    nonisolated private static func downloadChunked(url: URL, size: Int64, key: [UInt8],
                                                    baseIV: [UInt8], to dest: URL) async throws {
        let writer = try ChunkFileWriter(url: dest, size: size)
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                var offset: Int64 = 0
                var inFlight = 0
                func addNext() {
                    guard offset < size else { return }
                    let start = offset
                    let length = Int(min(chunkSize, size - start))
                    offset += Int64(length)
                    inFlight += 1
                    group.addTask {
                        let encrypted = try await fetchRange(url: url, start: start, length: length)
                        let iv = counterIV(base: baseIV, blockOffset: start / 16)
                        let decrypted = try MegaCrypto.decryptCTRData(encrypted, key: key, iv: iv)
                        try await writer.write(decrypted, at: start)
                    }
                }
                for _ in 0..<chunkConcurrency { addNext() }
                while inFlight > 0 {
                    try await group.next()
                    inFlight -= 1
                    addNext()
                }
            }
        } catch {
            await writer.close()
            try? FileManager.default.removeItem(at: dest)   // don't leave a half-written file
            throw error
        }
        await writer.close()
    }

    /// One byte range (`start`..<start+length) of `url` as raw, still-encrypted data.
    nonisolated private static func fetchRange(url: URL, start: Int64, length: Int) async throws -> Data {
        var req = URLRequest(url: url)
        req.setValue("bytes=\(start)-\(start + Int64(length) - 1)", forHTTPHeaderField: "Range")
        let (data, response) = try await session.data(for: req)
        // If the server ignored Range (200 with the whole file instead of 206) the
        // bytes won't line up — fail rather than write a corrupt file.
        if let http = response as? HTTPURLResponse, http.statusCode == 200, data.count != length {
            throw MegaError.badResponse
        }
        guard data.count == length else { throw MegaError.badResponse }
        return data
    }

    /// `base` (nonce ‖ 0) with the trailing 8-byte big-endian block counter set to
    /// `blockOffset` — the CTR IV for a chunk that starts at that 16-byte block.
    nonisolated private static func counterIV(base: [UInt8], blockOffset: Int64) -> [UInt8] {
        var iv = base
        var counter = UInt64(blockOffset)
        for j in 0..<8 { iv[15 - j] = UInt8(counter & 0xFF); counter >>= 8 }
        return iv
    }

    // MARK: - Helpers

    /// A filesystem-safe version of a MEGA name (no path separators / control chars).
    nonisolated private static func sanitize(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Untitled" : cleaned
    }

    /// Deterministic, collision-free path: appends " 2", " 3"… only for genuine duplicate *names*
    /// within this import (tracked in `used`, NOT based on what's already on disk). Because it
    /// doesn't look at existing files, a re-import maps each MEGA file to the same destination every
    /// time — which is what makes the "skip what's already downloaded" resume reliable.
    nonisolated private static func dedupedURL(_ dir: URL, _ name: String, _ used: inout Set<String>) -> URL {
        let ns = (name.isEmpty ? "File" : name) as NSString
        let base = ns.deletingPathExtension
        let ext = ns.pathExtension
        var candidate = ns as String
        var n = 1
        while used.contains(dir.appendingPathComponent(candidate).path.lowercased()) {
            n += 1
            candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
        }
        used.insert(dir.appendingPathComponent(candidate).path.lowercased())
        return dir.appendingPathComponent(candidate)
    }

    /// True when `url` already holds the whole file. MEGA's `s` is the decrypted (plaintext) length
    /// and CTR is length-preserving, so a fully-downloaded file is exactly that many bytes — a
    /// partial/failed one from a prior run won't match and gets re-fetched.
    nonisolated private static func isComplete(_ url: URL, expected: Int64) -> Bool {
        guard expected > 0,
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.int64Value else { return false }
        return size == expected
    }

    nonisolated private static func friendlyError(_ error: Error) -> String {
        if let mega = error as? MegaError {
            switch mega {
            case .badLink:     return "That MEGA link couldn’t be read."
            case .badResponse: return "MEGA returned an unexpected response (the download URL was missing)."
            case .crypto:      return "Couldn’t decrypt the file content."
            case .io:          return "Couldn’t write the file to the drive."
            case .api(let n) where n == -3:  return "MEGA is rate-limiting requests (code -3). Try again shortly."
            case .api(let n) where n == -9:  return "A file no longer exists on MEGA (code -9)."
            case .api(let n) where n == -11: return "MEGA denied access to the file (code -11)."
            case .api(let n) where n == -16: return "The MEGA file is blocked or unavailable (code -16)."
            case .api(let n) where n == -18: return "MEGA asked to retry (code -18)."
            case .api(let n):  return "MEGA reported an error (code \(n))."
            }
        }
        // Surface the real network / ATS / filesystem reason so we can diagnose it.
        return "\(error.localizedDescription)"
    }
}

/// Serializes out-of-order chunk writes into the output file (each chunk lands at
/// its byte offset). An actor provides the synchronization; the file is truncated
/// to its final size up front so chunks can be written in any order.
private actor ChunkFileWriter {
    private let handle: FileHandle

    init(url: URL, size: Int64) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: url)
        guard fm.createFile(atPath: url.path, contents: nil),
              let h = try? FileHandle(forWritingTo: url) else { throw MegaError.io }
        try? h.truncate(atOffset: UInt64(max(0, size)))
        handle = h
    }

    func write(_ data: Data, at offset: Int64) throws {
        do {
            try handle.seek(toOffset: UInt64(offset))
            try handle.write(contentsOf: data)
        } catch { throw MegaError.io }
    }

    func close() { try? handle.close() }
}
