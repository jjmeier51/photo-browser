# Enabling 1440p / 4K downloads (FFmpegKit)

YouTube and Instagram serve their highest renditions (1440p/4K) as **VP9 or AV1**
video. AVFoundation can neither demux nor mux/encode those codecs, so an on-device
transcoder is required. The app is already wired for **FFmpegKit**: the moment its
xcframework is linked, `VideoTranscoder.isAvailable` becomes `true` and the YouTube /
Instagram download paths automatically pick the tallest rendition (any codec) and
transcode it to **HEVC (hvc1)** — hardware-accelerated encode via VideoToolbox — so the
result plays everywhere. Without it, both features cap at the best **H.264 ≤1080p**
rendition. **No code changes are needed to turn this on — only the binary.**

## One-time setup (in Xcode)

FFmpegKit was retired upstream in 2025, so use a community re-publish that includes the
codecs we need (VP9 + AV1 decode):

1. Download a **full-gpl** iOS build, e.g.
   `NooruddinLakhani/ffmpeg-kit-ios-full-gpl` →
   `ffmpeg-kit-full-gpl-6.0-ios-xcframework.zip`. Unzip it.
2. In Xcode, select the **PhotoBrowser** target → **General** → **Frameworks,
   Libraries, and Embedded Content**.
3. Drag in **every** `*.xcframework` from the unzipped folder — `ffmpegkit.xcframework`
   plus all the `libav*` / `libsw*` frameworks it ships with — and set each to
   **Embed & Sign**.
4. Build. The Swift module is imported as `ffmpegkit` (already guarded by
   `#if canImport(ffmpegkit)` in `VideoTranscoder.swift`).

## Verify it's linked

Open **Download YouTube Video Here…** — the footer reads
**"1440p/4K enabled (FFmpegKit linked)"** when it's working (and the Instagram
downloader's console log prints `FFmpegKit transcoder available: true`).

## Notes

- **App size:** the full-gpl build adds ~30–50 MB. Licensing is GPL — fine for personal
  use; review before any redistribution.
- **Speed/battery:** HEVC *encode* is hardware-accelerated, but VP9/AV1 *decode* in
  ffmpeg is software, so a 4K transcode is CPU-heavy and not instant. 1080p stays on the
  fast AVFoundation mux path (no transcode).
- **API drift:** the exact FFmpegKit Swift API can vary by build. If the calls in
  `VideoTranscoder.muxTranscode` (`FFmpegKit.execute`, `ReturnCode.isSuccess`,
  `session?.getReturnCode()`) don't resolve against your chosen build, adjust them to
  that build's signatures — the ffmpeg command string itself stays the same.
