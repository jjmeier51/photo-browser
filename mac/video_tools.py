"""Video work for Safe Finder's Instagram and Facebook downloads: putting a DASH video's two halves together
(`mux`) and upscaling a video to 1080p (`upscale_1080`), in place, its metadata and dates kept.

On a Mac it's AVFoundation, through `video_helper.swift` — the iPhone app's own code for both, built once
with `swiftc` into ~/Library/Caches/PhotoBrowser/ (like the thumbnail helper). Without Xcode's tools,
ffmpeg does it when it's installed (`brew install ffmpeg`). With neither, a DASH video falls back to its
one-file version and no video is upscaled — the log says so once. `SAFE_FINDER_VIDEO_HELPER` names a
stand-in helper and `SAFE_FINDER_FFMPEG` an ffmpeg (tests).
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import threading
from pathlib import Path

HERE = Path(__file__).resolve().parent
IS_MAC = sys.platform == "darwin"
TARGET = 1080
_lock = threading.Lock()
_helper: list[str] | None | bool = False       # False = not looked for yet
note = ""                                      # set once when neither tool is here


def _source() -> Path | None:
    for base in (HERE, Path(getattr(sys, "_MEIPASS", HERE))):
        p = base / "video_helper.swift"
        if p.is_file():
            return p
    return None


def helper() -> list[str] | None:
    """The command that runs the helper, building it the first time (or when its source is newer)."""
    global _helper
    with _lock:
        if _helper is not False:
            return _helper
        env = os.environ.get("SAFE_FINDER_VIDEO_HELPER")
        if env:
            _helper = env.split("\x1f")
            return _helper
        _helper = None
        src = _source()
        if not IS_MAC or src is None:
            return None
        out = Path.home() / "Library" / "Caches" / "PhotoBrowser" / "video_helper"
        if out.is_file() and out.stat().st_mtime >= src.stat().st_mtime:
            _helper = [str(out)]
            return _helper
        if subprocess.run(["xcode-select", "-p"], capture_output=True).returncode != 0:
            return None                                    # no Command Line Tools: don't pop their installer
        out.parent.mkdir(parents=True, exist_ok=True)
        try:
            r = subprocess.run(["xcrun", "swiftc", "-O", "-parse-as-library", "-swift-version", "5", "-o", str(out),
                                str(src)], capture_output=True, text=True, timeout=900)
        except (OSError, subprocess.SubprocessError):
            return None
        _helper = [str(out)] if r.returncode == 0 and out.is_file() else None
        return _helper


def ffmpeg() -> str | None:
    env = os.environ.get("SAFE_FINDER_FFMPEG")
    if env is not None:
        return env or None
    for cand in (shutil.which("ffmpeg"), "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"):
        if cand and os.path.exists(cand):
            return cand
    return None


def available() -> str:
    """"helper", "ffmpeg" or "" — what will do the work."""
    global note
    if helper():
        return "helper"
    if ffmpeg():
        return "ffmpeg"
    note = ("Videos can't be put together or upscaled here — install Xcode's Command Line Tools "
            "(xcode-select --install) or ffmpeg (brew install ffmpeg).")
    return ""


def _run(cmd: list[str], timeout: float) -> subprocess.CompletedProcess | None:
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.SubprocessError):
        return None


# ----------------------------------------------------------------------------- the two jobs

def mux(video: str, audio: str, out: str, date: float = 0, lat=None, lng=None) -> bool:
    """`video` + `audio` → `out` (mp4), streams copied as they are."""
    tool = available()
    if tool == "helper":
        args = [*helper(), "mux", video, audio, out, str(int(date or 0))]
        if lat is not None and lng is not None:
            args += [str(lat), str(lng)]
        r = _run(args, 1800)
    elif tool == "ffmpeg":
        r = _run([ffmpeg(), "-y", "-v", "error", "-i", video, "-i", audio, "-map", "0:v:0", "-map", "1:a:0",
                  "-c", "copy", "-movflags", "+faststart", out], 1800)
    else:
        return False
    ok = r is not None and r.returncode == 0 and os.path.isfile(out) and os.path.getsize(out) > 0
    if not ok and os.path.exists(out):
        os.remove(out)
    return ok


def size(path: str) -> tuple[int, int] | None:
    """The size the video is shown at (turned as it plays)."""
    tool = available()
    if tool == "helper":
        r = _run([*helper(), "size", path], 120)
        try:
            w, h = (int(x) for x in r.stdout.split()[:2])
            return w, h
        except (AttributeError, ValueError):
            return None
    if tool == "ffmpeg":
        probe = ffmpeg().replace("ffmpeg", "ffprobe")
        r = _run([probe, "-v", "error", "-select_streams", "v:0", "-show_entries",
                  "stream=width,height:stream_side_data=rotation:stream_tags=rotate", "-of", "json", path], 120)
        try:
            s = json.loads(r.stdout)["streams"][0]
            w, h = int(s["width"]), int(s["height"])
            rot = abs(int(float((s.get("tags") or {}).get("rotate") or
                                next((d.get("rotation") for d in s.get("side_data_list") or [] if "rotation" in d), 0))))
            return (h, w) if rot % 180 == 90 else (w, h)
        except (AttributeError, ValueError, KeyError, IndexError, TypeError):
            return None
    return None


def upscale_1080(path: str) -> str:
    """The video at `path`, upscaled so its short side is 1080 (never down), in place: "upscaled",
    "skipped" (already 1080p or more) or "failed" (left as it was). Its metadata and file dates are kept."""
    st = os.stat(path)
    shown = size(path)
    if shown and min(shown) >= TARGET:
        return "skipped"
    tool = available()
    folder, name = os.path.split(path)
    tmp = os.path.join(folder, f".{name}.upscaling.mov" if tool == "helper" else f".{name}.upscaling.mp4")
    if tool == "helper":
        r = _run([*helper(), "upscale", path, tmp, str(TARGET)], 7200)
        outcome = (r.stdout.strip() if r is not None else "") or "failed"
    elif tool == "ffmpeg":
        if shown is None:
            return "failed"
        scale = (f"scale={TARGET}:-2" if shown[0] <= shown[1] else f"scale=-2:{TARGET}") + ":flags=lanczos"
        outcome = "failed"
        for codec in (["-c:v", "libx264", "-crf", "17", "-preset", "medium", "-pix_fmt", "yuv420p"],
                      ["-c:v", "h264_videotoolbox", "-q:v", "75", "-pix_fmt", "yuv420p"]):
            r = _run([ffmpeg(), "-y", "-v", "error", "-i", path, "-map", "0:v:0", "-map", "0:a?", "-vf", scale, *codec,
                      "-c:a", "copy", "-map_metadata", "0", "-movflags", "+faststart+use_metadata_tags", tmp], 7200)
            if r is not None and r.returncode == 0 and os.path.isfile(tmp) and os.path.getsize(tmp) > 0:
                outcome = "upscaled"
                break
    else:
        return "failed"
    if outcome != "upscaled" or not os.path.isfile(tmp):
        if os.path.exists(tmp):
            os.remove(tmp)
        return outcome if outcome == "skipped" else "failed"
    os.replace(tmp, path)
    os.utime(path, (st.st_atime, st.st_mtime))
    return "upscaled"
