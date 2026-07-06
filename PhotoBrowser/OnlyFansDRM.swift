import Foundation

/// OnlyFans DRM (Widevine) support via a user-supplied **CDMPOOL** account
/// (cdmpool.xyz). OnlyFans serves some videos as encrypted DASH with no plain file;
/// those need Widevine content keys, which require a CDM. Rather than ship one, we
/// use the user's CDMPOOL token: we fetch the manifest ourselves (OnlyFans' CDN
/// 403s cdmpool's servers, so their MPD-analyze can't), pull the Widevine PSSH, and
/// hand cdmpool the PSSH + the OnlyFans license URL + our signed headers. CDMPOOL
/// runs the license handshake and returns the content key; `VideoTranscoder`
/// (FFmpegKit) then downloads + decrypts the stream to a plain MP4.
///
/// Entirely opt-in and gated behind the token (empty token = feature off). Note the
/// one-shot cdmpool flow relays the OnlyFans license headers through their service,
/// so — unlike the rest of the app — this path does send session headers to a third
/// party; that's inherent to using a hosted CDM and is the user's explicit choice.
enum OnlyFansDRM {
    private static let tokenKey = "photoBrowser.cdmpoolToken"
    nonisolated static var token: String { UserDefaults.standard.string(forKey: tokenKey) ?? "" }
    nonisolated static func setToken(_ t: String) {
        UserDefaults.standard.set(t.trimmingCharacters(in: .whitespacesAndNewlines), forKey: tokenKey)
    }
    /// DRM downloading is available only when a token is set.
    nonisolated static var isEnabled: Bool { !token.isEmpty }

    struct KeyResult: Sendable { let key: String?; let error: String?; var quota: Bool = false }

    /// Caches extracted content keys (media id → key hex) so a re-run — or a retry
    /// after a *decrypt* failure — never re-spends a cdmpool quota unit on a video
    /// whose key we already have. Persisted; an actor so concurrent writes don't race.
    private actor KeyCache {
        private var map: [String: String]
        init() { map = (UserDefaults.standard.dictionary(forKey: "photoBrowser.ofDrmKeys") as? [String: String]) ?? [:] }
        func get(_ id: String) -> String? { map[id] }
        func set(_ key: String, _ id: String) { map[id] = key; UserDefaults.standard.set(map, forKey: "photoBrowser.ofDrmKeys") }
    }
    nonisolated private static let keyCache = KeyCache()
    nonisolated static func cachedKey(for id: String) async -> String? { await keyCache.get(id) }
    nonisolated static func cacheKey(_ key: String, for id: String) async { await keyCache.set(key, id) }

    /// The Widevine PSSH (base64) from a DASH manifest. A manifest usually carries
    /// several `<cenc:pssh>` boxes (PlayReady, Widevine, common-enc) — grab them all
    /// and pick the one whose pssh-box **SystemID** is Widevine, so we never hand
    /// cdmpool a PlayReady PSSH by mistake (which is what E_PSSH_DRM_MISMATCH was).
    nonisolated static func widevinePSSH(fromMPD mpd: String) -> String? {
        // Widevine SystemID: edef8ba9-79d6-4ace-a3c8-27dcd51d21ed
        let widevine: [UInt8] = [0xed, 0xef, 0x8b, 0xa9, 0x79, 0xd6, 0x4a, 0xce,
                                 0xa3, 0xc8, 0x27, 0xdc, 0xd5, 0x1d, 0x21, 0xed]
        for b64 in allMatches(mpd, "<cenc:pssh[^>]*>\\s*([A-Za-z0-9+/=\\s]+?)\\s*</cenc:pssh>") {
            guard let data = Data(base64Encoded: b64.replacingOccurrences(of: "\\s", with: "", options: .regularExpression)) else { continue }
            let bytes = [UInt8](data)
            // pssh box: [size 4][ 'pssh' 4][version+flags 4][SystemID 16] …
            if bytes.count >= 28, Array(bytes[12..<28]) == widevine { return b64.replacingOccurrences(of: "\\s", with: "", options: .regularExpression) }
        }
        return nil        // no Widevine PSSH — don't fall back to a PlayReady one
    }

    /// Extracts the content key via cdmpool's one-shot `/api/extract`. cdmpool calls
    /// the OnlyFans license server itself (with the headers/cookies we pass) and
    /// returns `keys:[{kid,key}]`. Returns the first key's hex, or an error hint.
    nonisolated static func extractKey(pssh: String, licenseURL: String, headers: [String: String],
                                       cookies: [String: String], mpdURL: String) async -> KeyResult {
        guard !token.isEmpty else { return KeyResult(key: nil, error: "no cdmpool token") }
        guard let url = URL(string: "https://cdmpool.xyz/api/extract") else { return KeyResult(key: nil, error: "bad url") }
        let payload: [String: Any] = [
            "token": token, "drm": "widevine", "pssh": pssh, "license_url": licenseURL,
            "headers": headers, "cookies": cookies, "mpd_url": mpdURL,
            "channel_name": "PhotoBrowser OnlyFans",
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return KeyResult(key: nil, error: "encode failed") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        req.timeoutInterval = 60
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return KeyResult(key: nil, error: "cdmpool unreachable")
        }
        if (json["ok"] as? Bool) == true, let keys = json["keys"] as? [[String: Any]],
           let key = keys.first?["key"] as? String, !key.isEmpty {
            return KeyResult(key: key, error: nil)
        }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let rawCode = (json["error_code"] as? String) ?? ""
        let hint = (json["hint"] as? String) ?? (json["error"] as? String) ?? "extract failed"
        let quota = status == 429 || rawCode.uppercased().contains("QUOTA")
        return KeyResult(key: nil, error: "cdmpool \(rawCode.isEmpty ? "" : rawCode + " ")\(hint)", quota: quota)
    }

    /// The encrypted media file URLs from the manifest — the video representation's
    /// file (best bandwidth) and, if audio is a separate AdaptationSet, its file.
    /// OnlyFans packages each representation as one CloudFront-signed file (SegmentBase),
    /// so a whole-file download is a valid encrypted fragmented MP4 for FFmpeg to
    /// decrypt. `note` records the manifest's segmenting style for diagnostics.
    nonisolated static func mediaFiles(_ mpd: String, mpdURL: String) -> (video: String, audio: String?, note: String) {
        let base = firstMatch(mpd, "<BaseURL>\\s*([^<]+?)\\s*</BaseURL>").map { resolve($0, base: mpdURL) } ?? mpdURL
        let note = mpd.contains("SegmentTemplate") ? "SegmentTemplate"
                 : (mpd.contains("SegmentTimeline") ? "SegmentTimeline" : "BaseURL")
        func file(_ kind: String) -> String? {
            guard let set = adaptationSet(mpd, kind) else { return nil }
            let reps = blocks(set, "Representation")
            let best = reps.max { bandwidth($0) < bandwidth($1) } ?? reps.first ?? set
            if let bu = firstMatch(best, "<BaseURL>\\s*([^<]+?)\\s*</BaseURL>")
                ?? firstMatch(set, "<BaseURL>\\s*([^<]+?)\\s*</BaseURL>") {
                return resolve(bu, base: base)
            }
            return nil
        }
        return (file("video") ?? "", file("audio"), note)
    }

    /// Resolves a possibly-relative URL against a base.
    nonisolated static func resolve(_ u: String, base: String) -> String {
        u.hasPrefix("http") ? u : (URL(string: u, relativeTo: URL(string: base))?.absoluteString ?? u)
    }

    /// The `<AdaptationSet>` block whose head declares the given media `kind`.
    nonisolated private static func adaptationSet(_ mpd: String, _ kind: String) -> String? {
        for b in blocks(mpd, "AdaptationSet") {
            let head = String(b.prefix(500)).lowercased()
            if head.contains("\(kind)/mp4") || head.contains("contenttype=\"\(kind)\"") || head.contains("mimetype=\"\(kind)") {
                return b
            }
        }
        return nil
    }
    nonisolated private static func blocks(_ s: String, _ tag: String) -> [String] {
        allMatches(s, "(<\(tag)\\b[^>]*?(?:/>|>[\\s\\S]*?</\(tag)>))")
    }
    nonisolated private static func bandwidth(_ s: String) -> Int { Int(firstMatch(s, "bandwidth=\"(\\d+)\"") ?? "0") ?? 0 }

    nonisolated private static func firstMatch(_ s: String, _ pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges > 1 else { return nil }
        let r = m.range(at: 1)
        return r.location == NSNotFound ? nil : ns.substring(with: r).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    nonisolated private static func allMatches(_ s: String, _ pattern: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            guard m.numberOfRanges > 1 else { return nil }
            let r = m.range(at: 1)
            return r.location == NSNotFound ? nil : ns.substring(with: r).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
