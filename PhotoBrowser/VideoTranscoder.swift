import Foundation
#if canImport(ffmpegkit)
import ffmpegkit
#endif

/// On-device video mux + (VP9/AV1 → HEVC) transcode via FFmpegKit, used to pull
/// Instagram's highest DASH renditions — the high-res streams are often VP9, which
/// AVFoundation can't mux/save, so a real transcoder is required (this is exactly
/// what the "a-Shell + ffmpeg" Shortcuts do).
///
/// FFmpegKit is a large third-party binary and was retired upstream in 2025, so it
/// is **not bundled**. Add the `ffmpegkit` xcframework to the Xcode project and this
/// lights up automatically (`#if canImport(ffmpegkit)`); without it, the app falls
/// back to the best AVFoundation-muxable (H.264/HEVC) rendition.
///
/// To enable VP9/AV1 → HEVC transcoding, add a re-published FFmpegKit build, e.g.
/// NooruddinLakhani/ffmpeg-kit-ios-full-gpl (FFmpeg 6.0, full-gpl): download its
/// `ffmpeg-kit-full-gpl-6.0-ios-xcframework.zip`, unzip, and drag every `*.xcframework`
/// (`ffmpegkit` + the `libav*`/`libsw*` frameworks) into the target with "Embed &
/// Sign". The Swift module is `ffmpegkit` regardless of distribution. The exact
/// FFmpegKit Swift API can differ by build — adjust the calls below if they don't
/// resolve.
enum VideoTranscoder {
    /// True only when FFmpegKit is linked into the build.
    nonisolated static var isAvailable: Bool {
        #if canImport(ffmpegkit)
        return true
        #else
        return false
        #endif
    }

    /// Muxes `video` (+ optional `audio`) into `dest`. When `transcode` is true the
    /// video is re-encoded to 10-bit HEVC (HDR color tags carried through); otherwise
    /// the video stream is copied. Embeds the capture date / location. Returns false
    /// (no-op) when FFmpegKit isn't present.
    nonisolated static func muxTranscode(video: URL, audio: URL?, to dest: URL,
                                         transcode: Bool, date: Date, lat: Double?, lng: Double?) async -> Bool {
        #if canImport(ffmpegkit)
        return await Task.detached(priority: .userInitiated) { () -> Bool in
            try? FileManager.default.removeItem(at: dest)
            var cmd = "-y -i \"\(video.path)\""
            if let audio { cmd += " -i \"\(audio.path)\"" }
            cmd += " -map 0:v:0"
            cmd += audio != nil ? " -map 1:a:0?" : " -map 0:a:0?"
            // HEVC via VideoToolbox (hardware); hvc1 tag so iOS/Photos plays it. HDR
            // color metadata is carried from the source.
            cmd += transcode ? " -c:v hevc_videotoolbox -tag:v hvc1 -q:v 60" : " -c:v copy"
            cmd += " -c:a aac -b:a 192k -movflags +faststart"
            cmd += " -metadata creation_time=\"\(ISO8601DateFormatter().string(from: date))\""
            if let lat, let lng, !(lat == 0 && lng == 0) {
                cmd += " -metadata location=\"\(String(format: "%+.5f%+.5f/", lat, lng))\""
            }
            cmd += " \"\(dest.path)\""
            let session = FFmpegKit.execute(cmd)
            let ok = ReturnCode.isSuccess(session?.getReturnCode())
            return ok && FileManager.default.fileExists(atPath: dest.path)
        }.value
        #else
        return false
        #endif
    }
}
