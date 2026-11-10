"""Video work for Safe Finder: putting a DASH video's two halves together (`mux`), upscaling a video to 1080p
or 4K (`upscale` — in place or as a new file, its metadata and dates kept; `upscale_1080` for the downloaders)
— and turning a WebM into an MP4
(`webm_to_mp4`, the SimpCity downloader), which only ffmpeg can do: AVFoundation doesn't open WebM.

On a Mac it's AVFoundation, through `video_helper.swift` — the iPhone app's own code for both, built once
with `swiftc` into ~/Library/Caches/PhotoBrowser/ (like the thumbnail helper). Without Xcode's tools,
ffmpeg does it when it's installed (`brew install ffmpeg`). With neither, a DASH video falls back to its
one-file version and no video is upscaled — the log says so once. A helper that won't build leaves the
compiler's output in `video_helper.log` beside it (`problem` says why it isn't there), so falling back to
ffmpeg — which tone-maps HDR its own way — is never silent. `SAFE_FINDER_VIDEO_HELPER` names a stand-in
helper and `SAFE_FINDER_FFMPEG` an ffmpeg (tests).
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
_converting = threading.Semaphore(1)           # one WebM conversion at a time: each one uses every core
_helper: list[str] | None | bool = False       # False = not looked for yet
problem = ""                                   # why there's no helper, once it's been looked for
note = ""                                      # set once when neither tool is here


def _source() -> Path | None:
    for base in (HERE, Path(getattr(sys, "_MEIPASS", HERE))):
        p = base / "video_helper.swift"
        if p.is_file():
            return p
    return None


def helper() -> list[str] | None:
    """The command that runs the helper, building it the first time (or when its source is newer)."""
    global _helper, problem
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
            problem = "the video helper isn't here"
            return None
        out = Path.home() / "Library" / "Caches" / "PhotoBrowser" / "video_helper"
        log = out.with_name("video_helper.log")
        if out.is_file() and out.stat().st_mtime >= src.stat().st_mtime:
            _helper = [str(out)]
            return _helper
        if subprocess.run(["xcode-select", "-p"], capture_output=True).returncode != 0:
            problem = "Xcode's Command Line Tools aren't installed (xcode-select --install)"
            return None                                    # no Command Line Tools: don't pop their installer
        out.parent.mkdir(parents=True, exist_ok=True)
        try:
            r = subprocess.run(["xcrun", "swiftc", "-O", "-parse-as-library", "-swift-version", "5", "-o", str(out),
                                str(src)], capture_output=True, text=True, timeout=900)
        except (OSError, subprocess.SubprocessError) as e:
            problem = f"the video helper couldn't be built ({e})"
            return None
        if r.returncode == 0 and out.is_file():
            _helper = [str(out)]
            try:
                log.unlink()
            except OSError:
                pass
        else:
            problem = f"the video helper didn't build — see {log}"
            try:
                log.write_text(f"swiftc failed ({r.returncode}) building {src}\n\n{r.stderr or ''}{r.stdout or ''}")
            except OSError:
                pass
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


TARGETS = {"1080p": 1080, "4K": 2160}           # the short side each one means
SIZE_TAG = "upscaled"


def _last_line(text: str | None) -> str:
    lines = [x.strip() for x in (text or "").splitlines() if x.strip()]
    return lines[-1] if lines else ""


def upscale_1080(path: str) -> str:
    """The video at `path`, upscaled so its short side is 1080 (never down), in place: "upscaled",
    "skipped" (already 1080p or more) or "failed" (left as it was). Its metadata and file dates are kept."""
    return upscale(path, TARGET)


def probe(path: str) -> dict:
    """What ffprobe says of the first video stream: {"duration", "fps", "transfer"} — what it can read."""
    ff = ffmpeg()
    if not ff:
        return {}
    exe = os.path.join(os.path.dirname(ff), os.path.basename(ff).replace("ffmpeg", "ffprobe"))
    r = _run([exe, "-v", "error", "-select_streams", "v:0", "-show_entries",
              "stream=avg_frame_rate,r_frame_rate,color_transfer,codec_name:format=duration", "-of", "json", path], 120)
    try:
        doc = json.loads(r.stdout)
        st = (doc.get("streams") or [{}])[0]
        out: dict = {"transfer": st.get("color_transfer") or "", "codec": st.get("codec_name") or ""}
        for key in ("avg_frame_rate", "r_frame_rate"):
            num, _, den = str(st.get(key) or "").partition("/")
            if num and float(num) > 0 and float(den or 1) > 0:
                out["fps"] = float(num) / float(den or 1)
                break
        out["duration"] = float((doc.get("format") or {}).get("duration") or 0)
        return out
    except (AttributeError, ValueError, KeyError, IndexError, TypeError, ZeroDivisionError):
        return {}


def new_name(path: str, label: str) -> str:
    """Where an upscale saved as a new file goes: "<name> (1080p).<ext>" beside the original (a WebM/MKV
    becomes an .mp4 — what comes out isn't one), never over a file that's there ("… (1080p) 2")."""
    folder, name = os.path.split(path)
    stem, ext = os.path.splitext(name)
    if ext.lower() not in (".mp4", ".mov", ".m4v"):
        ext = ".mp4"
    out = os.path.join(folder, f"{stem} ({label}){ext}")
    n = 2
    while os.path.lexists(out):
        out = os.path.join(folder, f"{stem} ({label}) {n}{ext}")
        n += 1
    return out


def _keep_attributes(src: str, dst: str) -> None:
    """The original's extended attributes onto the file replacing it — the tags a file carries
    (`com.photobrowser.tags`), Finder's tags and "where from". Best effort; nothing on a drive without them."""
    try:
        import shared_tags
        for name in shared_tags.xattr_names(src):
            if name == "com.apple.quarantine":
                continue
            value = shared_tags.xattr_get(src, name)
            if value is not None:
                try:
                    shared_tags.xattr_set(dst, name, value)
                except OSError:
                    pass
    except Exception:  # noqa: BLE001
        pass


def _stream(cmd: list[str], on_line, stop, timeout: float) -> tuple[int, str]:
    """Runs `cmd`, handing each line it prints to `on_line`; `stop()` true kills it. → (exit code, last line)."""
    import time as _time
    try:
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    except OSError:
        return 1, ""
    last = ""
    started = _time.monotonic()
    killer_done = threading.Event()

    def watch() -> None:
        while not killer_done.wait(0.3):
            if (stop is not None and stop()) or _time.monotonic() - started > timeout:
                try:
                    proc.kill()
                except OSError:
                    pass
                return
    threading.Thread(target=watch, daemon=True).start()
    try:
        for line in proc.stdout:
            line = line.strip()
            if line:
                last = line
                on_line(line)
    finally:
        code = proc.wait()
        killer_done.set()
    return code, last


def upscale(path: str, target: int = TARGET, fps: float | None = None, out: str | None = None,
            progress=None, stop=None) -> str:
    """The video at `path` upscaled so its short side is `target` (1080, or 2160 for 4K) — never down. In
    place (`out` None: the file is replaced, its name, dates, metadata and attributes kept) or written to
    `out` (a new file; the original untouched). `fps` 30 or 60 retimes it as the iPhone's upscale does — frames
    repeated or dropped, none interpolated; None keeps the source's rate. `progress(0–1)` is called as it goes,
    `stop()` true abandons it (nothing is left behind). Returns "upscaled", "skipped" (already that size or
    more), "stopped" or "failed" (the original as it was).

    AVFoundation does it where the helper is built (H.264 at the highest quality; HEVC for HDR, which stays
    HDR); else ffmpeg (Lanczos, x264 CRF 17 — or 10-bit HEVC with the HDR curve kept for an HDR source)."""
    st = os.stat(path)
    shown = size(path)
    if shown and min(shown) >= target:
        return "skipped"
    tool = available()
    folder, name = os.path.split(path)
    final = out or path
    tmp_ext = ".mov" if tool == "helper" else (os.path.splitext(final)[1].lower() if
                                              os.path.splitext(final)[1].lower() in (".mp4", ".mov", ".m4v") else ".mp4")
    tmp = os.path.join(os.path.dirname(final), f".{os.path.basename(final)}.upscaling{tmp_ext}")
    say = progress or (lambda _f: None)
    outcome = "failed"
    if tool == "helper":
        def line(text: str) -> None:
            if text.startswith("progress "):
                try:
                    say(max(0.0, min(1.0, float(text.split()[1]))))
                except (ValueError, IndexError):
                    pass
        _code, last = _stream([*helper(), "upscale", path, tmp, str(target), str(fps or 0), "progress"], line, stop, 6 * 3600)
        outcome = last if last in ("upscaled", "skipped", "failed") else "failed"
    elif tool == "ffmpeg":
        if shown is None:
            return "failed"
        info = probe(path)
        total = info.get("duration") or 0
        hdr = info.get("transfer") in ("smpte2084", "arib-std-b67")
        scale = (f"scale={target}:-2" if shown[0] <= shown[1] else f"scale=-2:{target}") + ":flags=lanczos"
        vf = scale + (f",fps={int(fps)}" if fps else "")
        if hdr:
            color = ["-color_primaries", "bt2020", "-color_trc", info["transfer"], "-colorspace", "bt2020nc"]
            codecs = (["-c:v", "libx265", "-crf", "18", "-preset", "medium", "-pix_fmt", "yuv420p10le", "-tag:v", "hvc1", *color],
                      ["-c:v", "hevc_videotoolbox", "-q:v", "70", "-profile:v", "main10", "-pix_fmt", "p010le", "-tag:v", "hvc1", *color])
        else:
            codecs = (["-c:v", "libx264", "-crf", "17", "-preset", "medium", "-pix_fmt", "yuv420p"],
                      ["-c:v", "h264_videotoolbox", "-q:v", "75", "-pix_fmt", "yuv420p"])

        def line(text: str) -> None:
            if total and text.startswith("out_time_ms="):
                try:
                    say(max(0.0, min(1.0, int(text.split("=", 1)[1]) / 1e6 / total)))
                except ValueError:
                    pass
        for codec in codecs:
            code, _last = _stream([ffmpeg(), "-y", "-v", "error", "-nostats", "-progress", "pipe:1", "-i", path,
                                   "-map", "0:v:0", "-map", "0:a?", "-vf", vf, *codec, "-c:a", "copy",
                                   "-map_metadata", "0", "-movflags", "+faststart+use_metadata_tags", tmp], line, stop, 12 * 3600)
            if code == 0 and os.path.isfile(tmp) and os.path.getsize(tmp) > 0:
                outcome = "upscaled"
                break
            if stop is not None and stop():
                break
    else:
        return "failed"
    if stop is not None and stop():
        outcome = "stopped"
    if outcome != "upscaled" or not os.path.isfile(tmp):
        if os.path.exists(tmp):
            os.remove(tmp)
        return outcome if outcome in ("skipped", "stopped") else "failed"
    _keep_attributes(path, tmp)
    os.replace(tmp, final)
    os.utime(final, (st.st_atime, st.st_mtime))
    say(1.0)
    return "upscaled"


# ----------------------------------------------------------------------------- turning a video

def rotation(path: str) -> int | None:
    """How the video is turned for showing, counter-clockwise in degrees (ffprobe's sense): 0, 90, 180, -90.
    None when ffprobe isn't here or can't read it."""
    ff = ffmpeg()
    if not ff:
        return None
    exe = os.path.join(os.path.dirname(ff), os.path.basename(ff).replace("ffmpeg", "ffprobe"))
    r = _run([exe, "-v", "error", "-select_streams", "v:0", "-show_entries",
              "stream_side_data=rotation:stream_tags=rotate", "-of", "json", path], 120)
    try:
        st = (json.loads(r.stdout).get("streams") or [{}])[0]
        for d in st.get("side_data_list") or []:
            if "rotation" in d:
                return int(round(float(d["rotation"])))
        old = (st.get("tags") or {}).get("rotate")              # the older tag: clockwise
        return -int(round(float(old))) if old not in (None, "") else 0
    except (AttributeError, ValueError, KeyError, IndexError, TypeError):
        return None


def rotate(path: str, quarters: int) -> str:
    """Turns the video `quarters` quarter-turns clockwise (2 = upside down → upright), in place and **without
    re-encoding**: only the "show it turned" note in the file changes (what a phone writes when it's held
    sideways), so nothing is lost and it takes a moment. Its metadata, dates and attributes are kept.
    Returns "rotated", "unchanged" (a full turn), "no-tool" (needs ffmpeg), "unsupported" (a WebM/MKV has no
    such note) or "failed" (left as it was)."""
    q = quarters % 4
    if q == 0:
        return "unchanged"
    ff = ffmpeg()
    if not ff:
        return "no-tool"
    ext = os.path.splitext(path)[1].lower()
    if ext not in (".mp4", ".mov", ".m4v"):
        return "unsupported"
    now = rotation(path)
    if now is None:
        return "failed"
    new = (now - 90 * q) % 360
    if new > 180:
        new -= 360
    st = os.stat(path)
    folder, name = os.path.split(path)
    tmp = os.path.join(folder, f".{name}.turning{ext}")
    done = False
    for maps in (["-map", "0"], ["-map", "0:v", "-map", "0:a?"]):       # every track; else the picture and sound
        r = _run([ff, "-y", "-v", "error", "-display_rotation", str(new), "-i", path, *maps, "-c", "copy",
                  "-map_metadata", "0", "-movflags", "+faststart+use_metadata_tags", tmp], 3600)
        if r is not None and r.returncode == 0 and os.path.isfile(tmp) and os.path.getsize(tmp) > 0 \
                and rotation(tmp) == new:
            done = True
            break
        if os.path.exists(tmp):
            os.remove(tmp)
    if not done:
        return "failed"
    _keep_attributes(path, tmp)
    os.replace(tmp, path)
    os.utime(path, (st.st_atime, st.st_mtime))
    return "rotated"


# ----------------------------------------------------------------------------- WebM → MP4

def is_matroska(path: str) -> bool:
    """WebM/Matroska: the file starts with the EBML header."""
    try:
        with open(path, "rb") as f:
            return f.read(4) == b"\x1a\x45\xdf\xa3"
    except OSError:
        return False


def is_mp4(path: str) -> bool:
    """An MP4/QuickTime file (an `ftyp` box first) — a host can serve one under a .webm name."""
    try:
        with open(path, "rb") as f:
            head = f.read(12)
        return head[4:8] == b"ftyp"
    except OSError:
        return False


_H264 = (["-c:v", "libx264", "-preset", "veryfast", "-crf", "18", "-pix_fmt", "yuv420p"],
         ["-c:v", "h264_videotoolbox", "-q:v", "65", "-pix_fmt", "yuv420p"])     # no libx264: the Mac's encoder


def webm_to_mp4(src: str, out: str) -> str:
    """The WebM at `src` as an MP4 at `out` that the iPhone, Photos and QuickTime play: its VP8/VP9/AV1
    picture as H.264 (x264 CRF 18 — visually the same; the Mac's hardware encoder when ffmpeg has no
    x264), its Opus/Vorbis sound as AAC, at the same size and frame rate (an odd width or height made
    even — H.264 needs that), its metadata (a creation date) carried over. `src` is left as it is.
    Returns "converted", "renamed" (it was an MP4 all along, only named .webm — copied as it is),
    "no-tool" (no ffmpeg here) or "failed" (`out` is never left behind then)."""
    if is_mp4(src) and not is_matroska(src):
        try:
            shutil.copyfile(src, out)
            return "renamed"
        except OSError:
            return "failed"
    ff = ffmpeg()
    if not ff:
        return "no-tool"
    with _converting:
        for codec in _H264:
            r = _run([ff, "-y", "-v", "error", "-i", src, "-map", "0:v:0", "-map", "0:a:0?",
                      "-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2", *codec, "-c:a", "aac", "-b:a", "192k",
                      "-map_metadata", "0", "-movflags", "+faststart", "-f", "mp4", out], 4 * 3600)
            if r is not None and r.returncode == 0 and os.path.isfile(out) and os.path.getsize(out) > 1024:
                return "converted"
            if os.path.exists(out):
                os.remove(out)
    return "failed"
