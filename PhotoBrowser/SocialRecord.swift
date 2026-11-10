import Foundation

/// The **shared record** of an Instagram, Facebook or TikTok profile folder — `.instagram.json` /
/// `.facebook.json` / `.tiktok.json` in the folder itself — so this app and Safe Finder (`mac/social.py`,
/// `mac/instagram.py`, `mac/facebook.py`, `mac/tiktok.py`) never download a post the other already has.
/// A TikTok record also carries each video's like count (`likes`: post id → count), which Safe Finder
/// reads again on every run — this app takes them on its next run (`applyTikTokLikes`). It lists every post id downloaded into
/// the folder (by either app), the profile's handle or name, its numeric id and link, when it was last
/// brought up to date, and running photo/video counts.
///
/// Why a file on the drive and not just the names in the folder: both apps already skip what's named in
/// the folder (`postIDsOnDisk`, `FB_<id>`), but a post deleted from the folder would come back on the next
/// run — this app's own record (`IGFolderInfo`/`FBFolderInfo`) lives on the phone, where Safe Finder can't
/// read it. A run here adds the file's ids to "already downloaded" and writes its own into it. A folder
/// Safe Finder made has no record on the phone, so a download into it takes the profile's id and last
/// update from the file (`Snapshot.instagramInfo` / `facebookInfo`).
///
/// Every save re-reads the file and merges: ids are added, never dropped; the counts get this run's
/// additions; fields the other app writes are kept. Read and written off the main actor (it's the drive —
/// callers use `Task.detached`); written with `DriveWriter.writeDataSync` (temp → fsync → rename).
nonisolated enum SocialRecord {
    nonisolated enum Kind: Sendable {
        case instagram, facebook, tiktok
        var fileName: String {
            switch self {
            case .instagram: return ".instagram.json"
            case .facebook: return ".facebook.json"
            case .tiktok: return ".tiktok.json"
            }
        }
        var format: String {
            switch self {
            case .instagram: return "photobrowser-instagram"
            case .facebook: return "photobrowser-facebook"
            case .tiktok: return "photobrowser-tiktok"
            }
        }
        /// The tag every downloaded file gets, as Safe Finder tags them.
        var tag: String {
            switch self {
            case .instagram: return "instagram"
            case .facebook: return "facebook"
            case .tiktok: return "tiktok"
            }
        }
    }

    /// What the file says, as plain values (safe to hand to the main actor).
    nonisolated struct Snapshot: Sendable {
        var exists = false
        var ids: Set<String> = []
        var handle = "", userID = ""                       // Instagram
        var name = "", profileID = "", url = ""            // Facebook
        var lastUpdated: Double = 0
        var photos = 0, videos = 0
        var authorID = ""                                  // TikTok
        var likes: [String: Int] = [:]                     // TikTok: post id → like count
        var profileVideoCount = 0                          // TikTok: the profile's size at the last full listing
    }

    static func snapshot(_ kind: Kind, in folder: URL) -> Snapshot {
        let doc = read(kind, in: folder)
        guard !doc.isEmpty else { return Snapshot() }
        var s = Snapshot(exists: true)
        s.ids = ids(of: doc)
        s.handle = string(doc["handle"]); s.userID = string(doc["user_id"])
        s.name = string(doc["profile_name"]); s.profileID = string(doc["profile_id"]); s.url = string(doc["profile_url"])
        s.lastUpdated = number(doc["last_updated"])
        s.photos = Int(number(doc["photos"])); s.videos = Int(number(doc["videos"]))
        s.authorID = string(doc["author_id"])
        s.profileVideoCount = Int(number(doc["profile_video_count"]))
        for (id, n) in (doc["likes"] as? [String: Any]) ?? [:] {
            let count = Int(number(n))
            if count > 0 { s.likes[id] = count }
        }
        return s
    }

    /// Adds `done` to the record's ids and this run's counts, and sets `info` (handle/ids/link) — merged
    /// into what the file says now. Best-effort: a drive that's gone just leaves the file as it was.
    /// `likes` (TikTok) are laid over the counts the file has; `numbers` are set as they are.
    static func save(_ kind: Kind, in folder: URL, done: Set<String>, photos: Int, videos: Int, info: [String: String],
                     likes: [String: Int] = [:], numbers: [String: Double] = [:]) {
        var doc = read(kind, in: folder)
        let all = ids(of: doc).union(done)
        for (k, v) in info where !v.isEmpty { doc[k] = v }
        if !likes.isEmpty {
            var counts = (doc["likes"] as? [String: Any]) ?? [:]
            for (id, n) in likes where n > 0 { counts[id] = n }
            doc["likes"] = counts
            doc["likes_updated"] = Date().timeIntervalSince1970
        }
        for (k, v) in numbers { doc[k] = v }
        doc["format"] = kind.format
        doc["version"] = max(1, Int(number(doc["version"])))
        doc["last_updated"] = max(number(doc["last_updated"]), Date().timeIntervalSince1970)
        doc["photos"] = Int(number(doc["photos"])) + photos
        doc["videos"] = Int(number(doc["videos"])) + videos
        doc["downloaded"] = all.sorted()
        guard let data = try? JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? DriveWriter.writeDataSync(data, to: folder.appendingPathComponent(kind.fileName))
    }

    private static func read(_ kind: Kind, in folder: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(kind.fileName)),
              let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              doc["format"] as? String == kind.format else { return [:] }
        return doc
    }

    private static func ids(of doc: [String: Any]) -> Set<String> {
        Set((doc["downloaded"] as? [Any] ?? []).compactMap { ($0 as? String) ?? ($0 as? NSNumber)?.stringValue })
    }

    private static func string(_ v: Any?) -> String {
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return ""
    }

    private static func number(_ v: Any?) -> Double {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) ?? 0 }
        return 0
    }
}

extension SocialRecord.Snapshot {
    /// The phone's record for a profile folder only the file knows (one Safe Finder made).
    var instagramInfo: IGFolderInfo? {
        guard exists, !handle.isEmpty else { return nil }
        return IGFolderInfo(handle: handle, userID: userID, lastUpdated: lastUpdated, downloaded: Array(ids),
                            photos: photos, videos: videos)
    }

    /// A TikTok folder only the file knows (one Safe Finder made). The incremental cutoff is left for the
    /// first run here to set.
    var tiktokInfo: TTFolderInfo? {
        guard exists, !handle.isEmpty else { return nil }
        return TTFolderInfo(handle: handle, secUid: authorID, lastUpdated: lastUpdated, downloaded: ids.sorted(),
                            videos: ids.count, newestDate: nil,
                            profileVideoCount: profileVideoCount > 0 ? profileVideoCount : nil)
    }

    var facebookInfo: FBFolderInfo? {
        guard exists, !profileID.isEmpty else { return nil }
        return FBFolderInfo(profileName: name, profileID: profileID, profileURL: url, lastUpdated: lastUpdated,
                            downloaded: Array(ids), photos: photos, videos: videos)
    }
}
