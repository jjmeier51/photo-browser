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

    struct KeyResult: Sendable { let key: String?; let error: String? }

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
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return KeyResult(key: nil, error: "cdmpool unreachable")
        }
        if (json["ok"] as? Bool) == true, let keys = json["keys"] as? [[String: Any]],
           let key = keys.first?["key"] as? String, !key.isEmpty {
            return KeyResult(key: key, error: nil)
        }
        let code = (json["error_code"] as? String).map { "\($0) " } ?? ""
        let hint = (json["hint"] as? String) ?? (json["error"] as? String) ?? "extract failed"
        return KeyResult(key: nil, error: "cdmpool \(code)\(hint)")
    }

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
