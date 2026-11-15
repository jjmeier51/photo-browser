"""Stitch Videos for Photo Browser for Mac — several clips joined into one video (stitch_window.py is the window).

Select two or more videos ▸ right-click ▸ Stitch Videos… (or Photos ▸ Video ▸ Stitch Videos…).

**How they're joined** (`plan`): when every clip is the same kind — codec, size, frame rate, pixel format, turn,
sound — they are joined **as they are** (ffmpeg's concat with `-c copy`): no quality lost, done in seconds.
Otherwise they're re-encoded onto one canvas — each clip fitted inside it, bars where a clip is another shape
— at one frame rate, H.264 + AAC (HDR clips: 10-bit HEVC, their curve kept), silence for clips without sound.
"Always re-encode" is there for clips that look alike on paper and still won't join cleanly.

**What the new video inherits** (`Inherit`, `finish`):
- **the oldest date** of the clips — its capture date in the metadata, and the file's created and modified dates;
- **the place** — the oldest clip's, else the first clip that has one;
- the oldest clip's other descriptive metadata (camera make and model, title, description, keywords…) when
  ExifTool is here (the date and place are written by ffmpeg itself too, so they don't depend on it);
- the oldest clip's extended attributes ("where from", Finder's tags) — not on exFAT;
- and, in the window's `on_done`, **the tags of every clip** — plus "stitched".

It is written beside the first clip as "name (stitched).mp4" — to a hidden temporary file first, given its
name only once it's whole (straight to its name on exFAT, CLAUDE.md #12) — and never over anything.

ffmpeg does the work (`video_tools.ffmpeg()`); without it, `stitch_helper.swift` (AVFoundation) is tried on a
Mac. No Qt here.
"""
from __future__ import annotations

import json
import os
import subprocess
import tempfile
import threading
import time
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable

import video_tools

STITCHED_TAG = "stitched"
LABEL = "stitched"
HDR_CURVES = ("smpte2084", "arib-std-b67")
problem = ""                                  # why the last stitch failed, in a sentence


class StitchError(Exception):
    pass


class Stopped(StitchError):
    pass


@dataclass
class Clip:
    path: str
    duration: float = 0.0
    width: int = 0                            # as shown (after its turn)
    height: int = 0
    rotation: int = 0
    fps: float = 0.0
    vcodec: str = ""
    pix_fmt: str = ""
    transfer: str = ""
    timebase: str = ""
    acodec: str = ""                          # "" = no sound
    arate: int = 0
    channels: int = 0
    created: float = 0.0                      # unix: its capture date, else its file's earliest date
    dated: bool = False                       # the capture date came from the video's own metadata
    place: tuple[float, float] | None = None
    size: int = 0
    profile: str = ""
    level: int = 0
    primaries: str = ""
    start: float = 0.0                        # trimmed: where it starts (seconds into the clip)
    end: float = 0.0                          # …and ends; 0 = to its end

    @property
    def hdr(self) -> bool:
        return self.transfer in HDR_CURVES

    @property
    def trimmed(self) -> bool:
        return self.start > 0.001 or (0 < self.end < self.duration - 0.001)

    @property
    def length(self) -> float:
        """How long it plays, trimmed."""
        return max(0.0, (self.end if 0 < self.end < self.duration else self.duration) - max(0.0, self.start))

    def kind(self) -> tuple:
        """What must match for clips to be joined as they are: not only the codec and the size, but its
        profile and level (two encoders' H.264 don't always play on as one stream) and its colours. The frame
        rate is compared loosely — an iPhone's is never exactly 30."""
        return (self.vcodec, self.profile, self.level, self.width, self.height, self.rotation, self.pix_fmt,
                rate_class(self.fps), self.timebase, self.transfer, self.primaries, self.acodec, self.arate, self.channels)


RATES = (23.976, 24.0, 25.0, 29.97, 30.0, 48.0, 50.0, 59.94, 60.0, 120.0, 240.0)


def rate_class(fps: float) -> float:
    """Coarser still, for "are these the same kind": 29.97 and 30 are (the frames keep their own times)."""
    near = min((24.0, 25.0, 30.0, 48.0, 50.0, 60.0, 120.0, 240.0), key=lambda r: abs(r - fps)) if fps > 0 else 0.0
    return near if near and abs(near - fps) / near < 0.02 else round(fps, 1)


def snapped(fps: float) -> float:
    """A measured frame rate as the usual one it's within 2% of (29.98 → 30… the nearest wins)."""
    if fps <= 0:
        return 0.0
    near = min(RATES, key=lambda r: abs(r - fps))
    return near if abs(near - fps) / near < 0.02 else round(fps, 1)


def ffprobe() -> str | None:
    ff = video_tools.ffmpeg()
    if not ff:
        return None
    exe = os.path.join(os.path.dirname(ff), os.path.basename(ff).replace("ffmpeg", "ffprobe"))
    return exe if os.path.exists(exe) else None


def _rate(text: str) -> float:
    num, _, den = str(text or "").partition("/")
    try:
        return float(num) / float(den or 1) if float(den or 1) else 0.0
    except ValueError:
        return 0.0


def probe(path: str) -> Clip:
    """What the clip is. Raises StitchError when it can't be read as a video."""
    c = Clip(path)
    try:
        st = os.stat(path)
        c.size = st.st_size
        file_date = min(st.st_mtime, getattr(st, "st_birthtime", st.st_mtime))
    except OSError as e:
        raise StitchError(f"“{os.path.basename(path)}” isn't there ({e})") from e
    try:
        import media_info
        info = media_info.video_info(path) or {}
    except Exception:  # noqa: BLE001
        info = {}
    if info.get("created"):
        c.created, c.dated = float(info["created"]), True
    else:
        c.created = file_date
    if info.get("place"):
        c.place = tuple(info["place"])
    exe = ffprobe()
    if exe:
        try:
            r = subprocess.run([exe, "-v", "error", "-show_streams", "-show_format", "-of", "json", path],
                               capture_output=True, text=True, timeout=120)
            doc = json.loads(r.stdout or "{}")
        except (OSError, subprocess.SubprocessError, ValueError):
            doc = {}
        v = next((s for s in doc.get("streams", []) if s.get("codec_type") == "video"
                  and not (s.get("disposition") or {}).get("attached_pic")), None)
        a = next((s for s in doc.get("streams", []) if s.get("codec_type") == "audio"), None)
        if v is None:
            raise StitchError(f"“{os.path.basename(path)}” has no video in it")
        rot = 0
        for side in v.get("side_data_list") or []:
            if "rotation" in side:
                rot = int(round(float(side["rotation"]))) % 360
        if not rot and (v.get("tags") or {}).get("rotate"):
            rot = int(float(v["tags"]["rotate"])) % 360
        w, h = int(v.get("width") or 0), int(v.get("height") or 0)
        c.rotation = rot
        c.width, c.height = (h, w) if rot in (90, 270) else (w, h)
        c.fps = _rate(v.get("avg_frame_rate")) or _rate(v.get("r_frame_rate"))
        c.vcodec, c.pix_fmt = v.get("codec_name") or "", v.get("pix_fmt") or ""
        c.transfer, c.timebase = v.get("color_transfer") or "", v.get("time_base") or ""
        c.profile, c.primaries = str(v.get("profile") or ""), v.get("color_primaries") or ""
        try:
            c.level = int(v.get("level") or 0)
        except (TypeError, ValueError):
            c.level = 0
        try:
            c.duration = float((doc.get("format") or {}).get("duration") or v.get("duration") or 0)
        except ValueError:
            c.duration = 0.0
        if a is not None:
            c.acodec, c.arate, c.channels = a.get("codec_name") or "?", int(a.get("sample_rate") or 0), int(a.get("channels") or 0)
    else:                                         # no ffprobe: what the file's own boxes say…
        c.duration = float(info.get("duration") or 0)
        c.width, c.height = int(info.get("width") or 0), int(info.get("height") or 0)
        c.fps = float(info.get("fps") or 0)
        c.rotation = int(info.get("rotation") or 0)
        _probe_with_ffmpeg(c)                     # …and what ffmpeg prints about it (its sound, above all)
    if c.width < 2 or c.height < 2:
        raise StitchError(f"“{os.path.basename(path)}” can't be read as a video")
    return c


def _probe_with_ffmpeg(c: Clip) -> None:
    """Fills in a clip from `ffmpeg -i`'s own description — for an ffmpeg that came without ffprobe. Without
    this every clip looked silent, and the stitched video came out mute."""
    import re
    ff = video_tools.ffmpeg()
    if not ff:
        return
    try:
        said = subprocess.run([ff, "-hide_banner", "-i", c.path], capture_output=True, text=True, timeout=60).stderr
    except (OSError, subprocess.SubprocessError):
        return
    m = re.search(r"Duration: (\d+):(\d+):(\d+(?:\.\d+)?)", said)
    if m and not c.duration:
        c.duration = int(m.group(1)) * 3600 + int(m.group(2)) * 60 + float(m.group(3))
    v = re.search(r"Stream #\S+ Video: (\w+)[^\n]*?, (\w+)[^\n]*?, (\d{2,5})x(\d{2,5})[^\n]*", said)
    if v:
        c.vcodec, c.pix_fmt = v.group(1), v.group(2)
        w, h = int(v.group(3)), int(v.group(4))
        turn = re.search(r"rotation of (-?\d+(?:\.\d+)?) degrees", said)
        c.rotation = int(round(float(turn.group(1)))) % 360 if turn else c.rotation
        c.width, c.height = (h, w) if c.rotation in (90, 270) else (w, h)
        rate = re.search(r"(\d+(?:\.\d+)?) fps", v.group(0))
        if rate and not c.fps:
            c.fps = float(rate.group(1))
        for curve in HDR_CURVES:
            if curve in v.group(0):
                c.transfer = curve
    a = re.search(r"Stream #\S+ Audio: (\w+)[^\n]*?, (\d+) Hz, ([^,\n]+)", said)
    if a:
        c.acodec, c.arate = a.group(1), int(a.group(2))
        c.channels = {"mono": 1, "stereo": 2}.get(a.group(3).strip(), 6 if "5.1" in a.group(3) else 2)


ORDERS = [("selected", "As Selected"), ("date", "Oldest First"), ("newest", "Newest First"), ("name", "By Name")]


def ordered(clips: list[Clip], how: str) -> list[Clip]:
    if how == "date":
        return sorted(clips, key=lambda c: (c.created, os.path.basename(c.path).casefold()))
    if how == "newest":
        return sorted(clips, key=lambda c: (-c.created, os.path.basename(c.path).casefold()))
    if how == "name":
        import re
        def natural(c: Clip):
            return [int(t) if t.isdigit() else t.casefold() for t in re.split(r"(\d+)", os.path.basename(c.path))]
        return sorted(clips, key=natural)
    return list(clips)


@dataclass
class Plan:
    copy: bool                                # joined as they are
    width: int = 0
    height: int = 0
    fps: float = 30.0
    hdr: bool = False
    transfer: str = ""
    sound: bool = True
    why: str = ""                             # a sentence for the window

    @property
    def duration_note(self) -> str:
        return self.why or ("Joined as they are — no quality lost." if self.copy else "")


SIZES = [("first", "The First Clip's"), ("largest", "The Largest Clip's"), ("1080", "1080p"), ("2160", "4K")]


def plan(clips: list[Clip], reencode: bool = False, size: str = "first", fps: float = 0.0) -> Plan:
    """How these clips, in this order, will be joined."""
    if not clips:
        return Plan(False)
    sound = any(c.acodec for c in clips)
    kinds = {c.kind() for c in clips}
    if not reencode and len(kinds) == 1 and clips[0].vcodec in ("h264", "hevc") and video_tools.ffmpeg():
        note = "Joined as they are — no quality lost."
        if any(c.trimmed for c in clips):
            note += " Trimmed clips are cut at the nearest key frames (tick Always re-encode for exact cuts)."
        return Plan(True, clips[0].width, clips[0].height, clips[0].fps, clips[0].hdr, clips[0].transfer, sound, note)
    first = clips[0]
    if size == "largest":
        pick = max(clips, key=lambda c: c.width * c.height)
        w, h = pick.width, pick.height
    elif size in ("1080", "2160"):
        short = int(size)
        w, h = (round(short * first.width / max(first.height, 1)), short) if first.width >= first.height \
            else (short, round(short * first.height / max(first.width, 1)))
    else:
        w, h = first.width, first.height
    w, h = max(2, w - w % 2), max(2, h - h % 2)
    rate = fps or snapped(max((c.fps for c in clips), default=30.0)) or 30.0
    rate = min(rate, 120.0)
    hdr = all(c.hdr for c in clips) and len({c.transfer for c in clips}) == 1
    different = []
    if len({(c.width, c.height) for c in clips}) > 1:
        different.append("sizes")
    if len({rate_class(c.fps) for c in clips}) > 1:
        different.append("frame rates")
    if len({(c.vcodec, c.pix_fmt, c.profile, c.level, c.transfer) for c in clips}) > 1:
        different.append("formats")
    if len({(c.acodec, c.arate, c.channels) for c in clips}) > 1:
        different.append("sound")
    why = ("Re-encoded, as asked" if reencode else
           "Re-encoded — the clips differ in " + ", ".join(different) if different else "Re-encoded onto one timeline")
    why += f": {w} × {h} at {rate:g} fps, {'10-bit HEVC (HDR kept)' if hdr else 'H.264'}."
    if any(c.hdr for c in clips) and not hdr:
        why += " HDR and standard clips are mixed: the HDR ones are brought to standard range."
    return Plan(False, w, h, rate, hdr, clips[0].transfer if hdr else "", sound, why)


@dataclass
class Inherit:
    """What the stitched video takes from its clips."""
    oldest: Clip | None = None
    when: float = 0.0
    place: tuple[float, float] | None = None
    sources: list[str] = field(default_factory=list)


def inherit(clips: list[Clip]) -> Inherit:
    if not clips:
        return Inherit()
    by_age = sorted(clips, key=lambda c: (not c.dated, c.created))       # clips that know their date count first
    dated = [c for c in clips if c.dated]
    oldest = min(dated, key=lambda c: c.created) if dated else min(clips, key=lambda c: c.created)
    place = oldest.place or next((c.place for c in by_age if c.place), None)
    return Inherit(oldest, oldest.created, place, [c.path for c in clips])


def _iso6709(place: tuple[float, float]) -> str:
    lat, lon = place
    return f"{lat:+08.4f}{lon:+09.4f}/"


def _metadata_args(inh: Inherit) -> list[str]:
    """ffmpeg's own metadata: the date and the place, where the iPhone and macOS read them."""
    out = ["-map_metadata", "-1"]
    if inh.when:
        utc = datetime.fromtimestamp(inh.when, timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000000Z")
        local = datetime.fromtimestamp(inh.when).astimezone().strftime("%Y-%m-%dT%H:%M:%S%z")
        out += ["-metadata", f"creation_time={utc}", "-metadata", f"com.apple.quicktime.creationdate={local}"]
    if inh.place:
        out += ["-metadata", f"com.apple.quicktime.location.ISO6709={_iso6709(inh.place)}",
                "-metadata", f"location={_iso6709(inh.place)}"]
    return out + ["-movflags", "+faststart+use_metadata_tags"]


def out_path(first: str) -> str:
    return video_tools.new_name(first, LABEL)


def _quote(path: str) -> str:
    return "file '" + path.replace("'", "'\\''") + "'"


def _run(cmd: list[str], total: float, progress: Callable[[float], None] | None, stop: threading.Event | None) -> str:
    """Runs ffmpeg, reporting how far through `total` seconds it is. Returns "" or what went wrong."""
    try:
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    except OSError as e:
        return str(e)
    errors: list[str] = []
    threading.Thread(target=lambda: errors.extend(proc.stderr.readlines()[-12:]), daemon=True).start()
    for line in proc.stdout:
        if stop is not None and stop.is_set():
            proc.terminate()
            try:
                proc.wait(10)
            except subprocess.TimeoutExpired:
                proc.kill()
            raise Stopped("stopped")
        if progress and total > 0 and line.startswith("out_time_us="):
            try:
                progress(min(1.0, int(line.split("=", 1)[1]) / 1e6 / total))
            except ValueError:
                pass
    code = proc.wait()
    time.sleep(0.05)
    return "" if code == 0 else ("".join(errors).strip()[-600:] or f"ffmpeg ended with {code}")


def _encoders(ff: str) -> str:
    try:
        return subprocess.run([ff, "-hide_banner", "-encoders"], capture_output=True, text=True, timeout=30).stdout
    except (OSError, subprocess.SubprocessError):
        return ""


def _codec_args(ff: str, p: Plan) -> list[str]:
    have = _encoders(ff)
    if p.hdr:
        color = ["-color_primaries", "bt2020", "-color_trc", p.transfer, "-colorspace", "bt2020nc"]
        if "libx265" in have:
            return ["-c:v", "libx265", "-crf", "18", "-preset", "medium", "-pix_fmt", "yuv420p10le", "-tag:v", "hvc1", *color]
        return ["-c:v", "hevc_videotoolbox", "-q:v", "70", "-profile:v", "main10", "-pix_fmt", "p010le", "-tag:v", "hvc1", *color]
    if "libx264" in have:
        return ["-c:v", "libx264", "-crf", "17", "-preset", "medium", "-pix_fmt", "yuv420p"]
    return ["-c:v", "h264_videotoolbox", "-q:v", "75", "-pix_fmt", "yuv420p"]


_filters_text: str | None = None


def _has_filter(ff: str, name: str) -> bool:
    global _filters_text
    if _filters_text is None:
        try:
            _filters_text = subprocess.run([ff, "-hide_banner", "-filters"], capture_output=True, text=True, timeout=30).stdout
        except (OSError, subprocess.SubprocessError):
            _filters_text = ""
    return f" {name} " in _filters_text


TO_STANDARD = ("zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=tonemap=hable:desat=0,"
               "zscale=t=bt709:m=bt709:r=tv,")       # an HDR clip's picture, as a standard-range one


def _container(out: str) -> str:
    return "mov" if out.lower().endswith(".mov") else "mp4"


def _ffmpeg_join(ff: str, clips: list[Clip], p: Plan, inh: Inherit, out: str,
                 progress: Callable[[float], None] | None, stop: threading.Event | None) -> str:
    total = sum(c.length for c in clips)
    meta = _metadata_args(inh)
    tail = ["-progress", "pipe:1", "-nostats", "-f", _container(out), out]
    if p.copy:
        lines = []
        for c in clips:
            lines.append(_quote(c.path))
            if c.start > 0.001:
                lines.append(f"inpoint {c.start:.3f}")
            if 0 < c.end < c.duration - 0.001:
                lines.append(f"outpoint {c.end:.3f}")
        with tempfile.NamedTemporaryFile("w", suffix=".txt", prefix="stitch-", delete=False, encoding="utf-8") as f:
            f.write("\n".join(lines) + "\n")
            listing = f.name
        try:
            cmd = [ff, "-y", "-v", "error", "-f", "concat", "-safe", "0", "-i", listing, "-map", "0:v:0"]
            cmd += ["-map", "0:a:0"] if p.sound else []
            cmd += ["-c", "copy"] + (["-tag:v", "hvc1"] if clips[0].vcodec == "hevc" else []) + meta + tail
            return _run(cmd, total, progress, stop)
        finally:
            try:
                os.unlink(listing)
            except OSError:
                pass
    cmd = [ff, "-y", "-v", "error"]
    for c in clips:                                    # a trim is asked of the input itself: exact, when re-encoding
        if c.start > 0.001:
            cmd += ["-ss", f"{c.start:.3f}"]
        if 0 < c.end < c.duration - 0.001:
            cmd += ["-to", f"{c.end:.3f}"]
        cmd += ["-i", c.path]
    parts, labels = [], ""
    fmt = "yuv420p10le" if p.hdr else "yuv420p"
    tone = TO_STANDARD if not p.hdr and _has_filter(ff, "zscale") and _has_filter(ff, "tonemap") else ""
    for i, c in enumerate(clips):
        parts.append(f"[{i}:v:0]{tone if c.hdr else ''}scale={p.width}:{p.height}:force_original_aspect_ratio=decrease:flags=lanczos,"
                     f"pad={p.width}:{p.height}:(ow-iw)/2:(oh-ih)/2:black,setsar=1,fps={p.fps:g},format={fmt},"
                     f"setpts=PTS-STARTPTS[v{i}]")
        labels += f"[v{i}]"
        if p.sound:
            if c.acodec:
                parts.append(f"[{i}:a:0]aresample=48000,aformat=sample_fmts=fltp:channel_layouts=stereo,"
                             f"asetpts=PTS-STARTPTS[a{i}]")
            else:
                parts.append(f"anullsrc=channel_layout=stereo:sample_rate=48000,atrim=duration={max(c.length, 0.04):.3f}[a{i}]")
            labels += f"[a{i}]"
    parts.append(f"{labels}concat=n={len(clips)}:v=1:a={1 if p.sound else 0}[v]" + ("[a]" if p.sound else ""))
    cmd += ["-filter_complex", ";".join(parts), "-map", "[v]"] + (["-map", "[a]"] if p.sound else [])
    colours = [] if p.hdr else ["-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709"]
    cmd += _codec_args(ff, p) + colours + (["-c:a", "aac", "-b:a", "192k"] if p.sound else []) + meta + tail
    return _run(cmd, total, progress, stop)


_helper: list[str] | None | bool = False


def helper() -> list[str] | None:
    """The AVFoundation stitcher (stitch_helper.swift), built the first time — for a Mac without ffmpeg."""
    global _helper
    if _helper is not False:
        return _helper  # type: ignore[return-value]
    _helper = None
    env = os.environ.get("PHOTO_BROWSER_STITCH_HELPER")
    if env:
        _helper = env.split("\x1f")
        return _helper
    src = Path(__file__).with_name("stitch_helper.swift")
    if not video_tools.IS_MAC or not src.is_file():
        return None
    out = Path.home() / "Library" / "Caches" / "PhotoBrowser" / "stitch_helper"
    if out.is_file() and out.stat().st_mtime >= src.stat().st_mtime:
        _helper = [str(out)]
        return _helper
    try:
        if subprocess.run(["xcode-select", "-p"], capture_output=True).returncode != 0:
            return None
        out.parent.mkdir(parents=True, exist_ok=True)
        r = subprocess.run(["xcrun", "swiftc", "-O", "-parse-as-library", "-swift-version", "5", "-o", str(out), str(src)],
                           capture_output=True, text=True, timeout=900)
        if r.returncode == 0 and out.is_file():
            _helper = [str(out)]
        else:
            out.with_name("stitch_helper.log").write_text(r.stderr or r.stdout or "")
    except (OSError, subprocess.SubprocessError):
        pass
    return _helper  # type: ignore[return-value]


def can_stitch() -> str:
    """"ffmpeg", "helper" or "" — what will do the joining."""
    if video_tools.ffmpeg():
        return "ffmpeg"
    return "helper" if helper() else ""


NEEDS = ("Joining videos needs ffmpeg (brew install ffmpeg) — or Xcode's Command Line Tools "
         "(xcode-select --install) for the built-in joiner.")


def finish(out: str, inh: Inherit, exfat: bool) -> list[str]:
    """After the join: the oldest clip's other metadata (ExifTool), its attributes, and the file's dates.
    Returns notes about anything that couldn't be carried."""
    notes: list[str] = []
    try:
        import astria
        tool = astria.find_exiftool()
    except Exception:  # noqa: BLE001
        tool = None
    if tool and inh.oldest is not None:
        import metadata_edit
        when = datetime.fromtimestamp(inh.when) if inh.when else None
        args = [tool, "-q", "-q", "-m", "-overwrite_original", "-api", "QuickTimeUTC=1", "-api", "LargeFileSupport=1",
                "-tagsFromFile", inh.oldest.path, "-Keys:Make", "-Keys:Model", "-Keys:Software", "-Keys:Title",
                "-Keys:Description", "-Keys:Keywords", "-Keys:Author", "-Keys:Artist", "-Keys:Comment", "-Keys:Copyright",
                "-Keys:DisplayName", "-ItemList:Title", "-ItemList:Comment", "-ItemList:Artist", "-ItemList:Keyword",
                "-ItemList:Description", "-ItemList:LongDescription", "-UserData:Make", "-UserData:Model", "-XMP:all"]
        if when is not None:
            args += metadata_edit.date_args(True, when, metadata_edit.local_offset(when))
        if inh.place:
            args += metadata_edit.place_args(True, inh.place)
        try:
            r = subprocess.run(args + [out], capture_output=True, text=True, timeout=max(600, os.path.getsize(out) / 2e6))
            if r.returncode != 0:
                notes.append("the camera details couldn't be copied (" + (r.stderr.strip().splitlines() or ["ExifTool failed"])[-1] + ")")
        except (OSError, subprocess.SubprocessError) as e:
            notes.append(f"the camera details couldn't be copied ({e})")
    if not exfat and inh.oldest is not None:
        try:
            import batch_crop
            import shared_tags
            batch_crop.copy_xattrs(inh.oldest.path, out, skip={shared_tags.MARKER})
        except Exception:  # noqa: BLE001 — attributes are a nicety
            pass
    if inh.when:
        try:
            import clone_drive
            ns = int(inh.when * 1e9)
            if not (clone_drive.IS_MAC and clone_drive.set_dates(out, ns, ns, ns)):
                os.utime(out, (inh.when, inh.when))
        except Exception:  # noqa: BLE001
            try:
                os.utime(out, (inh.when, inh.when))
            except OSError:
                notes.append("the file's date couldn't be set")
    return notes


def stitch(clips: list[Clip], p: Plan, progress: Callable[[float], None] | None = None,
           stop: threading.Event | None = None, dest: str | None = None, fallback: Plan | None = None) -> tuple[str, list[str]]:
    """Joins the clips in the order given. Returns (the new video's path, notes). Raises StitchError (Stopped
    when stopped); nothing is left behind then. `fallback`: the re-encoding plan to use when joining the
    clips as they are fails or comes out the wrong length (default: one at the first clip's size)."""
    global problem
    if len(clips) < 2:
        raise StitchError("two or more videos are needed")
    import spare_folders
    final = dest or out_path(clips[0].path)
    folder = os.path.dirname(final)
    exfat = spare_folders.on_exfat(folder)
    ext = os.path.splitext(final)[1] or ".mp4"
    work = final if exfat else os.path.join(folder, f".{os.path.basename(final)}.stitch-{uuid.uuid4().hex[:8]}{ext}")
    inh = inherit(clips)
    ff = video_tools.ffmpeg()
    want = sum(c.length for c in clips)

    def wrong_length() -> str:
        if not os.path.isfile(work) or os.path.getsize(work) < 1024:
            return "nothing was written"
        got = probe(work).duration if ffprobe() else want
        slack = max(1.5, 0.03 * want) + (2.0 * len(clips) if p.copy and any(c.trimmed for c in clips) else 0.0)
        return f"the result is {got:.1f} s long where the clips add up to {want:.1f} s" if want > 1 and abs(got - want) > slack else ""

    try:
        if ff:
            report = (lambda f: progress(0.94 * f)) if progress else None
            why = _ffmpeg_join(ff, clips, p, inh, work, report, stop) or wrong_length()
            if why and p.copy:                             # alike on paper, not in fact: once more, re-encoded
                _remove(work)
                again = fallback if fallback is not None and not fallback.copy else plan(clips, reencode=True)
                why = _ffmpeg_join(ff, clips, again, inh, work, report, stop) or wrong_length()
        elif helper():
            if any(c.trimmed for c in clips):
                raise StitchError("trimming needs ffmpeg (brew install ffmpeg)")
            args = [*helper(), work, str(int(inh.when or 0)), _iso6709(inh.place) if inh.place else "-"] + [c.path for c in clips]
            try:
                r = subprocess.run(args, capture_output=True, text=True, timeout=6 * 3600)
                why = "" if r.returncode == 0 else (r.stderr.strip() or "the joiner failed")
            except (OSError, subprocess.SubprocessError) as e:
                why = str(e)
            why = why or wrong_length()
        else:
            raise StitchError(NEEDS)
        if why:
            raise StitchError(why)
        notes = finish(work, inh, exfat)
        if work != final:
            if os.path.lexists(final):
                final = out_path(clips[0].path)
            os.replace(work, final)
            if inh.when:                                   # (a rename keeps dates; said again in case it didn't)
                try:
                    import clone_drive
                    ns = int(inh.when * 1e9)
                    clone_drive.IS_MAC and clone_drive.set_dates(final, ns, ns, ns)
                except Exception:  # noqa: BLE001
                    pass
        if progress:
            progress(1.0)
        problem = ""
        return final, notes
    except BaseException as e:
        _remove(work)
        _remove(work + "_exiftool_tmp")                    # what ExifTool leaves when it's cut short
        problem = str(e)
        raise


def _remove(path: str) -> None:
    try:
        os.unlink(path)
    except OSError:
        pass


if __name__ == "__main__":                   # python3 mac/video_stitch.py a.mp4 b.mov … — from the shell
    import sys
    paths = [a for a in sys.argv[1:] if not a.startswith("--")]
    cs = [probe(a) for a in paths]
    pl = plan(cs, reencode="--reencode" in sys.argv)
    print(pl.duration_note)
    made, said = stitch(cs, pl, lambda f: print(f"\r{f * 100:5.1f}%", end=""))
    print("\n→", made, *said, sep="\n")
