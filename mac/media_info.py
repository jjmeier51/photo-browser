"""What Safe Finder shows about a photo or video, read straight from the file — quickly, with no ExifTool —
for the Photos grid's video lengths and the viewer's Info panel.

**Videos** (`video_info`): an MP4/MOV/M4V's `moov` box says it all — `mvhd` its length and when it was
recorded, each video track's `tkhd` its size and how it's turned. The boxes are walked by seeking, so even
a 4 GB file costs a few small reads; a file without a readable `moov` (a WebM, a damaged file) answers {}.
QuickTime's own creation date (`com.apple.quicktime.creationdate`, the one the iPhone writes, with its time
zone) wins over `mvhd`'s when it's there.

**Photos** (`image_info`): Pillow (HEIC through pillow-heif) — the size the photo shows at (turned by its
EXIF orientation), when it was taken, the camera, where (GPS), and its caption (IPTC or EXIF).

Both are cached by path, modified date and size, so a grid of hundreds of videos reads each file once.
Everything here is safe on worker threads.
"""
from __future__ import annotations

import os
import struct
import threading
import time
from datetime import datetime, timezone

VIDEO_EXTS = {".mp4", ".mov", ".m4v", ".3gp", ".qt"}
_MAC_EPOCH = 2082844800                       # seconds from 1904-01-01 (QuickTime's epoch) to 1970-01-01
_cache: dict[tuple[str, int, int, str], dict] = {}
_lock = threading.Lock()


def _key(path: str, kind: str) -> tuple[str, int, int, str] | None:
    try:
        st = os.stat(path)
    except OSError:
        return None
    return (path, st.st_mtime_ns, st.st_size, kind)


def forget(paths) -> None:
    """Drops what was read for these files (after their metadata was rewritten — a write that kept the size and
    the modified date would otherwise still show the old)."""
    gone = set(paths)
    with _lock:
        for key in [k for k in _cache if k[0] in gone]:
            del _cache[key]


def _cached(path: str, kind: str, read) -> dict:
    key = _key(path, kind)
    if key is None:
        return {}
    with _lock:
        if key in _cache:
            return _cache[key]
    try:
        info = read(path)
    except (OSError, ValueError, struct.error):
        info = {}
    with _lock:
        if len(_cache) > 20000:
            _cache.clear()
        _cache[key] = info
    return info


# ----------------------------------------------------------------------------- videos

def _boxes(f, start: int, end: int):
    """(type, payload start, box end) for each box between `start` and `end`."""
    pos = start
    while pos + 8 <= end:
        f.seek(pos)
        head = f.read(8)
        if len(head) < 8:
            return
        size, kind = struct.unpack(">I4s", head)
        header = 8
        if size == 1:
            size = struct.unpack(">Q", f.read(8))[0]
            header = 16
        elif size == 0:
            size = end - pos
        if size < header:
            return
        yield kind.decode("latin-1"), pos + header, min(pos + size, end)
        pos += size


def _find(f, start: int, end: int, kind: str):
    for k, a, b in _boxes(f, start, end):
        if k == kind:
            return a, b
    return None


def _read_video(path: str) -> dict:
    out: dict = {}
    with open(path, "rb") as f:
        f.seek(0, 2)
        size = f.tell()
        moov = _find(f, 0, size, "moov")
        if not moov:
            return {}
        for kind, a, b in _boxes(f, *moov):
            if kind == "mvhd":
                f.seek(a)
                version = f.read(1)[0]
                f.read(3)
                if version == 1:
                    created, _mod, scale, length = struct.unpack(">QQIQ", f.read(28))
                else:
                    created, _mod, scale, length = struct.unpack(">IIII", f.read(16))
                if scale:
                    out["duration"] = length / scale
                if created > _MAC_EPOCH + 86400 * 365:      # 0 (not set) and 1904 aren't dates
                    out["created"] = float(created - _MAC_EPOCH)
            elif kind == "trak" and "width" not in out:
                track = _read_track(f, a, b)
                if track:
                    out.update(track)
            elif kind == "meta":
                when = _quicktime_date(f, a, b)
                if when:
                    out["created"] = when
    return out


def _read_track(f, a: int, b: int) -> dict:
    """A video track's shown size and turn ({} for any other track)."""
    hdlr = None
    mdia = _find(f, a, b, "mdia")
    if mdia:
        h = _find(f, *mdia, "hdlr")
        if h:
            f.seek(h[0] + 8)
            hdlr = f.read(4)
    if hdlr != b"vide":
        return {}
    tk = _find(f, a, b, "tkhd")
    if not tk:
        return {}
    f.seek(tk[0])
    version = f.read(1)[0]
    f.read(3)
    f.read(32 if version == 1 else 20)               # times, track id, reserved, duration
    f.read(16)                                       # reserved, layer, group, volume, reserved
    matrix = struct.unpack(">9i", f.read(36))
    w, h = struct.unpack(">II", f.read(8))
    width, height = w / 65536, h / 65536
    a_, b_ = matrix[0] / 65536, matrix[1] / 65536
    turn = 0
    if abs(a_) < 0.5:
        turn = 90 if b_ > 0 else 270
    elif a_ < 0:
        turn = 180
    if turn in (90, 270):
        width, height = height, width
    out = {"width": int(round(width)), "height": int(round(height)), "rotation": turn}
    fps = _frame_rate(f, *mdia) if mdia else None
    if fps:
        out["fps"] = fps
    if mdia and _video_hdr(f, *mdia):
        out["hdr"] = True
    return out


def _video_hdr(f, a: int, b: int) -> bool:
    """Whether the video track is HDR: its sample entry's colour (`colr` nclx) uses the HLG or PQ transfer —
    what the iPhone records — or it carries Dolby Vision (`dvcC` / `dvvC`, or a `dvh1` / `dvhe` entry)."""
    try:
        minf = _find(f, a, b, "minf")
        stbl = _find(f, *minf, "stbl") if minf else None
        stsd = _find(f, *stbl, "stsd") if stbl else None
        if not stsd:
            return False
        entry = stsd[0] + 8                            # version, flags, entry count
        f.seek(entry)
        size, kind = struct.unpack(">I4s", f.read(8))
        if kind in (b"dvh1", b"dvhe", b"dva1", b"dvav"):
            return True
        for k, x, _y in _boxes(f, entry + 8 + 78, min(entry + size, stsd[1])):   # after the visual entry's fields
            if k in ("dvcC", "dvvC", "dvwC"):
                return True
            if k == "colr":
                f.seek(x)
                if f.read(4) == b"nclx":
                    _prim, transfer, _matrix = struct.unpack(">HHH", f.read(6))
                    if transfer in (16, 18):           # PQ (HDR10, Dolby Vision) / HLG
                        return True
    except (OSError, struct.error):
        return False
    return False


def _frame_rate(f, a: int, b: int) -> float | None:
    """Frames per second: the samples `stts` counts over the length `mdhd` gives, in its own time scale."""
    md = _find(f, a, b, "mdhd")
    minf = _find(f, a, b, "minf")
    stbl = _find(f, *minf, "stbl") if minf else None
    stts = _find(f, *stbl, "stts") if stbl else None
    if not md or not stts:
        return None
    f.seek(md[0])
    version = f.read(1)[0]
    f.read(3)
    if version == 1:
        f.read(16)
        scale, length = struct.unpack(">IQ", f.read(12))
    else:
        f.read(8)
        scale, length = struct.unpack(">II", f.read(8))
    f.seek(stts[0] + 4)
    entries = struct.unpack(">I", f.read(4))[0]
    frames = 0
    for _ in range(min(entries, 100000)):
        count, _delta = struct.unpack(">II", f.read(8))
        frames += count
    if not scale or not length or not frames:
        return None
    return round(frames / (length / scale), 3)


def _quicktime_date(f, a: int, b: int) -> float | None:
    """`com.apple.quicktime.creationdate` from a QuickTime `meta` box (keys + ilst), with its time zone."""
    keys_box = _find(f, a, b, "keys")
    ilst = _find(f, a, b, "ilst")
    if not keys_box or not ilst:
        return None
    f.seek(keys_box[0] + 4)
    count = struct.unpack(">I", f.read(4))[0]
    names = []
    for _ in range(min(count, 200)):
        n, _ns = struct.unpack(">I4s", f.read(8))
        names.append(f.read(max(0, n - 8)).decode("utf-8", "replace"))
    try:
        want = names.index("com.apple.quicktime.creationdate") + 1
    except ValueError:
        return None
    for kind, ia, ib in _boxes(f, *ilst):
        idx = struct.unpack(">I", kind.encode("latin-1"))[0]
        if idx != want:
            continue
        data = _find(f, ia, ib, "data")
        if not data:
            return None
        f.seek(data[0] + 8)
        text = f.read(max(0, data[1] - data[0] - 8)).decode("utf-8", "replace").strip()
        return _parse_iso(text)
    return None


def _parse_iso(text: str) -> float | None:
    for fmt in ("%Y-%m-%dT%H:%M:%S%z", "%Y-%m-%dT%H:%M:%S.%f%z", "%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%d %H:%M:%S%z"):
        try:
            d = datetime.strptime(text, fmt)
            if d.tzinfo is None:
                d = d.replace(tzinfo=timezone.utc)
            return d.timestamp()
        except ValueError:
            continue
    return None


def video_info(path: str) -> dict:
    """{duration (s), width, height (as shown), rotation, fps, created (unix)} — whatever the file says; {}
    for a file that isn't an MP4/MOV or can't be read."""
    if os.path.splitext(path)[1].lower() not in VIDEO_EXTS:
        return {}
    return _cached(path, "video", _read_video)


def video_duration(path: str) -> float | None:
    d = video_info(path).get("duration")
    return d if d and d > 0 else None


def clock(seconds: float | None) -> str:
    """0:07, 12:03, 1:02:03 — the iPhone's duration badge."""
    if seconds is None or seconds < 0:
        return ""
    s = int(round(seconds))
    h, rest = divmod(s, 3600)
    m, s = divmod(rest, 60)
    return f"{h}:{m:02d}:{s:02d}" if h else f"{m}:{s:02d}"


# ----------------------------------------------------------------------------- photos

def _ratio(v) -> float:
    try:
        return float(v[0]) / float(v[1]) if isinstance(v, tuple) else float(v)
    except (TypeError, ValueError, ZeroDivisionError):
        return 0.0


def _gps(g: dict) -> tuple[float, float] | None:
    try:
        lat = sum(_ratio(x) / 60 ** i for i, x in enumerate(g[2]))
        lng = sum(_ratio(x) / 60 ** i for i, x in enumerate(g[4]))
    except (KeyError, TypeError, IndexError):
        return None
    if g.get(1) in ("S", b"S"):
        lat = -lat
    if g.get(3) in ("W", b"W"):
        lng = -lng
    if not (-90 <= lat <= 90 and -180 <= lng <= 180) or (lat == 0 and lng == 0):
        return None
    return round(lat, 6), round(lng, 6)


def _read_image(path: str) -> dict:
    from PIL import Image
    try:
        import batch_crop                             # registers HEIC with Pillow, when it can
    except ImportError:
        pass
    out: dict = {}
    with Image.open(path) as im:
        w, h = im.size
        exif = im.getexif()
        if exif.get(274) in (5, 6, 7, 8):             # turned a quarter: shown the other way round
            w, h = h, w
        out["width"], out["height"] = w, h
        out["format"] = im.format or ""
        when = exif.get_ifd(0x8769).get(36867) or exif.get(306)
        if isinstance(when, str):
            try:
                out["taken"] = time.mktime(datetime.strptime(when.strip()[:19], "%Y:%m:%d %H:%M:%S").timetuple())
            except ValueError:
                pass
        make, model = str(exif.get(271) or "").strip(), str(exif.get(272) or "").strip()
        if model:
            first = make.split()[0].lower() if make else ""
            out["camera"] = model if not make or first in ("apple",) or model.lower().startswith(first) \
                else f"{make} {model}"
        place = _gps(exif.get_ifd(0x8825))
        if place:
            out["place"] = place
        caption = ""
        try:
            from PIL import IptcImagePlugin
            iptc = IptcImagePlugin.getiptcinfo(im) or {}
            raw = iptc.get((2, 120))
            if isinstance(raw, (bytes, bytearray)):
                caption = raw.decode("utf-8", "replace")
        except Exception:  # noqa: BLE001 — a photo whose IPTC can't be read just has no caption here
            caption = ""
        if not caption:
            desc = exif.get(270)
            caption = desc.strip() if isinstance(desc, str) else ""
        if caption:
            out["caption"] = caption.strip()
    return out


def image_hdr(path: str) -> bool:
    """Whether a photo is HDR: an HDR gain map (the iPhone's, the ISO one, or an Ultra HDR JPEG's) or an HLG / PQ
    colour profile — looked for in the file's first megabyte, where the metadata is."""
    try:
        with open(path, "rb") as f:
            head = f.read(1 << 20)
    except OSError:
        return False
    if (b"urn:com:apple:photo:2020:aux:hdrgainmap" in head or b"urn:iso:std:iso:ts:21496:-1" in head
            or b"hdrgm:Version" in head or b"hdrgm:GainMapMax" in head):
        return True
    at = head.find(b"nclx")
    while at >= 0:
        if at + 8 <= len(head):
            transfer = struct.unpack(">H", head[at + 6:at + 8])[0]
            if transfer in (16, 18):
                return True
        at = head.find(b"nclx", at + 4)
    return False


def res_label(width: int, height: int) -> str:
    """8K / 4K / 1440p / 1080p / 720p / 480p — by the long side, as the iPhone app's resolution filter."""
    long_side, short = max(width, height), min(width, height)
    if not long_side:
        return ""
    for edge, label in ((7680, "8K"), (3840, "4K"), (2560, "1440p"), (1920, "1080p"), (1280, "720p"), (854, "480p")):
        if long_side >= edge:
            return label
    return f"{short}p"


def image_info(path: str) -> dict:
    """{width, height (as shown), format, taken (unix), camera, place (lat, lng), caption}."""
    return _cached(path, "image", _read_image)
