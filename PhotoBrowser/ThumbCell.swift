import SwiftUI
import AVFoundation

/// One square tile: a folder, or a file with a lazily-loaded thumbnail.
/// The thumbnail is framed to the cell and clipped so wide/tall images can't
/// bleed over neighbouring tiles.
struct EntryCell: View {
    let entry: Entry
    var selecting: Bool = false
    var selected: Bool = false
    var favorited: Bool = false
    var aiLabeled: Bool = false
    var isLive: Bool = false
    var isAIGenerated: Bool = false
    var coverURL: URL? = nil

    @State private var image: UIImage?
    @State private var duration: String?
    @State private var cover: UIImage?

    var body: some View {
        Rectangle()
            .fill(Color(white: 0.10))
            .aspectRatio(1, contentMode: .fit)
            .overlay { content }
            .overlay(alignment: .bottomTrailing) {
                if entry.kind == .video {
                    Image(systemName: "play.circle.fill")
                        .foregroundStyle(.white).shadow(radius: 2).padding(5)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if entry.kind == .video, let duration {
                    Text(duration)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(.black.opacity(0.5), in: Capsule())
                        .padding(4)
                }
            }
            .overlay(alignment: .topTrailing) {
                VStack(alignment: .trailing, spacing: 3) {
                    if isLive { cornerBadge("LIVE", "livephoto", .black.opacity(0.5)) }
                    if isAIGenerated { cornerBadge("AI", "sparkles", .purple.opacity(0.85)) }
                }
                .padding(4)
            }
            .overlay(alignment: .topLeading) {
                if favorited || aiLabeled {
                    HStack(spacing: 3) {
                        if favorited { Image(systemName: "heart.fill").foregroundStyle(.red) }
                        if aiLabeled { Image(systemName: "sparkles").foregroundStyle(.yellow) }
                    }
                    .font(.system(size: 11, weight: .bold))
                    .shadow(color: .black.opacity(0.6), radius: 1)
                    .padding(5)
                }
            }
            .overlay { if selecting { selectionOverlay } }
            .clipShape(Rectangle())
            .contentShape(Rectangle())
            .task(id: entry.id) {
                if entry.kind == .video { duration = await Self.loadDuration(entry) }
                guard entry.kind == .image || entry.kind == .video || entry.kind == .pdf else { return }
                image = await Thumbnailer.shared.thumbnail(
                    for: entry,
                    size: CGSize(width: 110, height: 110),
                    scale: UIScreen.main.scale)
            }
            .task(id: coverURL) {
                cover = coverURL.flatMap { UIImage(contentsOfFile: $0.path) }
            }
    }

    @ViewBuilder private var content: some View {
        if entry.isFolder {
            if let cover {
                GeometryReader { geo in
                    Image(uiImage: cover)
                        .resizable().scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                }
                .overlay(alignment: .bottom) {
                    Text(entry.name)
                        .font(.caption2).lineLimit(1)
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.8), radius: 2)
                        .padding(.horizontal, 4).padding(.vertical, 2)
                        .frame(maxWidth: .infinity)
                }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "folder.fill").font(.system(size: 34)).foregroundStyle(.tint)
                    Text(entry.name)
                        .font(.caption2).lineLimit(2)
                        .multilineTextAlignment(.center).padding(.horizontal, 4)
                }
            }
        } else if let image {
            GeometryReader { geo in
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
            }
        } else if entry.kind == .other {
            VStack(spacing: 6) {
                Image(systemName: otherIcon).font(.system(size: 30)).foregroundStyle(.secondary)
                Text(extLabel).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        } else {
            Image(systemName: entry.kind.systemImage).font(.title3).foregroundStyle(.secondary)
        }
    }

    /// Tiles recycle as the grid scrolls, so without a cache every pass over a
    /// video re-opens its AVAsset just to re-read the duration — slow on an
    /// external drive. Keyed by path|mtime|size so in-place edits invalidate.
    private static let durationCache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 20_000
        return cache
    }()

    private static func loadDuration(_ entry: Entry) async -> String? {
        let key = "\(entry.url.path)|\(Int(entry.modified.timeIntervalSince1970))|\(entry.size)" as NSString
        if let cached = durationCache.object(forKey: key) { return cached as String }
        let asset = AVURLAsset(url: entry.url)
        guard let d = try? await asset.load(.duration) else { return nil }
        let s = d.seconds
        guard s.isFinite, s > 0 else { return nil }
        let t = Int(s.rounded())
        let label = String(format: "%d:%02d", t / 60, t % 60)
        durationCache.setObject(label as NSString, forKey: key)
        return label
    }

    private func cornerBadge(_ text: String, _ icon: String, _ bg: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(bg, in: Capsule())
    }

    private var otherIcon: String {
        switch entry.url.pathExtension.lowercased() {
        case "zip", "rar", "7z", "tar", "gz", "gzip": return "doc.zipper"
        case "txt", "rtf", "md": return "doc.text"
        default: return "doc"
        }
    }

    private var extLabel: String {
        let ext = entry.url.pathExtension.lowercased()
        return ext.isEmpty ? "File" : ".\(ext) File"
    }

    private var selectionOverlay: some View {
        ZStack {
            if selected { Color.accentColor.opacity(0.25) }
            VStack { Spacer(); HStack {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : .white)
                    .background(Circle().fill(.black.opacity(0.25)))
                    .padding(5)
                Spacer()
            } }
        }
    }
}
