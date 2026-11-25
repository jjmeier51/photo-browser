"""What Photo Browser for Mac shows about a photo or video, read straight from the file — quickly, with no ExifTool —
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
    except Exception:  # noqa: BLE001 — a file that can't be read says nothing; it never stops the folder being
        info = {}      # read (Pillow refuses a picture over ~179 MP with an error that isn't an OSError)
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
                _read_meta(f, a, b, out)
            elif kind == "udta":
                _read_udta(f, a, b, out)
    return out


def _read_meta(f, a: int, b: int, out: dict) -> None:
    """A `meta` box's creation date (wins over mvhd's) and place. QuickTime's (`moov/meta`, the iPhone's) is a
    plain box; the ISO one (`udta/meta`) starts with 4 bytes of version and flags — told apart by where `hdlr` is."""
    f.seek(a)
    head = f.read(12)
    start = a + 4 if head[8:12] == b"hdlr" and head[4:8] != b"hdlr" else a
    items = _quicktime_items(f, start, b, (CREATION_KEY, LOCATION_KEY))
    when = _parse_iso(items[CREATION_KEY]) if CREATION_KEY in items else None
    if when:
        out["created"] = when
    place = parse_iso6709(items.get(LOCATION_KEY, ""))
    if place:
        out["place"] = place


def _read_udta(f, a: int, b: int, out: dict) -> None:
    """`udta`: a `meta` inside it, or the older location atoms — `©xyz` (ISO 6709 text, most cameras and Android
    phones) and 3GPP's `loci` (fixed-point degrees)."""
    for kind, ia, ib in _boxes(f, a, b):
        if kind == "meta":
            _read_meta(f, ia, ib, out)
        elif "place" in out:
            continue
        elif kind == "\xa9xyz" and ib - ia > 4:          # text length (2), language (2), text
            f.seek(ia + 4)
            place = parse_iso6709(f.read(min(ib - ia - 4, 200)).decode("latin-1", "replace"))
            if place:
                out["place"] = place
        elif kind == "loci" and ib - ia > 20:             # version/flags, language, name\0, role, lng, lat (16.16)
            f.seek(ia + 6)
            body = f.read(min(ib - ia - 6, 600))
            end = body.find(b"\0")
            if end >= 0 and end + 9 <= len(body):
                lng, lat = struct.unpack(">ii", body[end + 2:end + 10])
                lat, lng = lat / 65536, lng / 65536
                if -90 <= lat <= 90 and -180 <= lng <= 180 and not (lat == 0 and lng == 0):
                    out["place"] = (lat, lng)


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


CREATION_KEY = "com.apple.quicktime.creationdate"
LOCATION_KEY = "com.apple.quicktime.location.ISO6709"


def _quicktime_items(f, a: int, b: int, wanted: tuple[str, ...]) -> dict[str, str]:
    """The `wanted` text items of a QuickTime `meta` box (keys + ilst) — the creation date with its time zone,
    the place as ISO 6709."""
    keys_box = _find(f, a, b, "keys")
    ilst = _find(f, a, b, "ilst")
    if not keys_box or not ilst:
        return {}
    f.seek(keys_box[0] + 4)
    count = struct.unpack(">I", f.read(4))[0]
    names = []
    for _ in range(min(count, 200)):
        n, _ns = struct.unpack(">I4s", f.read(8))
        names.append(f.read(max(0, n - 8)).decode("utf-8", "replace"))
    index = {i + 1: name for i, name in enumerate(names) if name in wanted}
    out: dict[str, str] = {}
    for kind, ia, ib in _boxes(f, *ilst):
        name = index.get(struct.unpack(">I", kind.encode("latin-1"))[0])
        if name is None:
            continue
        data = _find(f, ia, ib, "data")
        if data:
            f.seek(data[0] + 8)
            out[name] = f.read(max(0, min(data[1] - data[0] - 8, 4096))).decode("utf-8", "replace").strip()
    return out


def parse_iso6709(text: str) -> tuple[float, float] | None:
    """"+40.7969-073.2079+032.618/" → (40.7969, -73.2079); None for no place (or 0, 0, or out of range)."""
    import re
    m = re.match(r"\s*([+-]\d+(?:\.\d+)?)([+-]\d+(?:\.\d+)?)", text or "")
    if not m:
        return None
    lat, lng = float(m.group(1)), float(m.group(2))
    if not (-90 <= lat <= 90 and -180 <= lng <= 180) or (lat == 0 and lng == 0):
        return None
    return lat, lng


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
    """{duration (s), width, height (as shown), rotation, fps, created (unix), place (lat, lng)} — whatever the
    file says; {}
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


def user_comment(raw) -> str:
    """An EXIF UserComment as text: its 8-byte character-code header ("ASCII", "UNICODE", …) taken off and the
    rest decoded — UTF-16 in whichever byte order it was written."""
    if isinstance(raw, str):
        return raw.strip("\0 ").strip()
    if not isinstance(raw, (bytes, bytearray)) or not raw:
        return ""
    raw = bytes(raw)
    head, body = raw[:8], raw[8:]
    try:
        if head.startswith(b"UNICODE"):
            if body[:2] in (b"\xff\xfe", b"\xfe\xff"):
                return body.decode("utf-16").strip("\0 ").strip()
            little = body[1::2].count(0) > body[0::2].count(0)       # plain text: the zero bytes say which order
            return body.decode("utf-16-le" if little else "utf-16-be", "replace").strip("\0 ").strip()
        if head.startswith(b"ASCII") or head.strip(b"\0") == b"":
            return body.decode("utf-8", "replace").strip("\0 ").strip()
        return raw.decode("utf-8", "replace").strip("\0 ").strip()
    except (UnicodeDecodeError, ValueError):
        return ""


AI_MARK = "AI-generated"                       # what both apps write first in an AI picture's UserComment
AI_SOFTWARE = "PhotoBrowser AI"                # …and in its Software tag, followed by " — <model>"


def ai_of(comment: str, software: str) -> dict:
    """{"ai": True, "ai_prompt", "ai_model"} from a picture's UserComment and Software tags, as the iPhone app and
    Photo Browser for Mac write them into what Edit / Create with AI saves ("AI-generated · Prompt: …",
    "PhotoBrowser AI — <model>") — {} for any other picture."""
    out: dict = {}
    if comment.startswith(AI_MARK):
        out["ai"] = True
        prompt = comment.partition("Prompt:")[2].strip()
        if prompt:
            out["ai_prompt"] = prompt
    if software.startswith(AI_SOFTWARE):
        out["ai"] = True
        model = software[len(AI_SOFTWARE):].lstrip(" —-–").strip()
        if model:
            out["ai_model"] = model
    return out


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
        software = exif.get(305)
        if isinstance(software, (bytes, bytearray)):
            software = bytes(software).decode("utf-8", "replace")
        elif isinstance(software, str):                # Pillow reads the tag as Latin-1; both apps write UTF-8
            try:
                software = software.encode("latin-1").decode("utf-8")
            except (UnicodeEncodeError, UnicodeDecodeError):
                pass
        out.update(ai_of(user_comment(exif.get_ifd(0x8769).get(37510)),
                         software.strip("\0 ") if isinstance(software, str) else ""))
    return out


def image_hdr(path: str) -> bool:
    """Whether a photo is HDR: an HDR gain map (the iPhone's, the ISO one, or an Ultra HDR JPEG's) or an HLG / PQ
    curve — looked for in the file's first megabyte, where the metadata is. The curve can be declared three ways:
    a HEIF/AVIF `colr` box of type `nclx`, an ICC profile's `cicp` tag (how a 10-bit HLG frame from Save Frame
    on the iPhone or Export All Frames may carry it), or a PNG's `cICP` chunk."""
    try:
        with open(path, "rb") as f:
            head = f.read(1 << 20)
    except OSError:
        return False
    if (b"urn:com:apple:photo:2020:aux:hdrgainmap" in head or b"urn:iso:std:iso:ts:21496:-1" in head
            or b"hdrgm:Version" in head or b"hdrgm:GainMapMax" in head):
        return True
    hdr_curves = (16, 18)                          # PQ (HDR10, Dolby Vision) / HLG
    at = head.find(b"nclx")                        # nclx: primaries (2 bytes), transfer (2), matrix (2), range
    while at >= 0:
        if at + 8 <= len(head) and struct.unpack(">H", head[at + 6:at + 8])[0] in hdr_curves:
            return True
        at = head.find(b"nclx", at + 4)
    at = head.find(b"cicp")                        # ICC cicpType: 'cicp', 4 zero bytes, primaries, transfer, …
    while at >= 0:
        if at + 10 <= len(head) and head[at + 4:at + 8] == b"\0\0\0\0" and head[at + 9] in hdr_curves:
            return True
        at = head.find(b"cicp", at + 4)
    at = head.find(b"cICP")                        # PNG: primaries, transfer, matrix, full range
    if at >= 0 and at + 6 <= len(head) and head[at + 5] in hdr_curves:
        return True
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
    """{width, height (as shown), format, taken (unix), camera, place (lat, lng), caption} — and, for a picture
    Edit / Create with AI made (either app), {ai, ai_prompt, ai_model}."""
    return _cached(path, "image", _read_image)


# ----------------------------------------------------------------------------- resolution (the funnel's filters)

# The iPhone app's resolution filters (`VideoRes`, `ImageRes`, `MediaSpec` in Models.swift), so "4K" and "2MP+"
# mean the same thing on both: a video by its long side, a photo by how many pixels it has.
VIDEO_RES = (("4k", 3840), ("1080p", 1920), ("720p", 1280))          # else "low"
LOW_RES_PIXELS = 2_000_000                                            # a photo under this is "Low-Res"
RAW_EXTS = {".dng", ".cr2", ".nef", ".arw", ".orf", ".rw2", ".raw", ".srw", ".pef", ".sr2", ".3fr", ".erf", ".nrw"}
_TIFF_MAGICS = (42, 0x55, 0x4F52, 0x5352)                             # TIFF/DNG/NEF/ARW/CR2, RW2, ORF (two kinds)


def video_res(long_side: int) -> str:
    """"4k" / "1080p" / "720p" / "low" — the iPhone's `MediaSpec.videoRes` (4K is 3840 and up, so 8K too)."""
    for key, edge in VIDEO_RES:
        if long_side >= edge:
            return key
    return "low"


def _raw_size(path: str) -> tuple[int, int] | None:
    """A RAW photo's own size. Its first picture is usually a small preview, so every picture the file lists
    (IFDs, their sub-IFDs, the EXIF block's stated size) is looked at and the largest taken."""
    best = (0, 0)
    with open(path, "rb") as f:
        head = f.read(8)
        if len(head) < 8 or head[:2] not in (b"II", b"MM"):
            return None
        e = "<" if head[:2] == b"II" else ">"
        magic, first = struct.unpack(e + "HI", head[2:8])
        if magic not in _TIFF_MAGICS:
            return None
        f.seek(0, 2)
        end = f.tell()
        todo, seen = [first], set()
        while todo and len(seen) < 48:
            at = todo.pop(0)
            if at in seen or at < 8 or at + 2 > end:
                continue
            seen.add(at)
            f.seek(at)
            count = struct.unpack(e + "H", f.read(2))[0]
            raw = f.read(count * 12 + 4)
            if len(raw) < count * 12:
                continue
            got: dict[int, int] = {}
            for i in range(count):
                tag, kind, n = struct.unpack(e + "HHI", raw[i * 12:i * 12 + 8])
                field = raw[i * 12 + 8:i * 12 + 12]
                if tag in (256, 257, 2, 3, 40962, 40963) and n == 1 and kind in (3, 4):
                    got[tag] = struct.unpack(e + ("H" if kind == 3 else "I"), field[:2 if kind == 3 else 4])[0]
                elif tag in (330, 34665) and kind in (4, 13) and 0 < n <= 16:
                    if n == 1:
                        todo.append(struct.unpack(e + "I", field)[0])
                    else:
                        where = struct.unpack(e + "I", field)[0]
                        if 8 <= where and where + 4 * n <= end:
                            back = f.tell()
                            f.seek(where)
                            todo.extend(struct.unpack(e + f"{n}I", f.read(4 * n)))
                            f.seek(back)
            for w, h in ((256, 257), (2, 3), (40962, 40963)):          # a picture's, a Panasonic sensor's, EXIF's
                if got.get(w) and got.get(h) and got[w] * got[h] > best[0] * best[1] and got[w] < 100000 > got[h]:
                    best = (got[w], got[h])
            if len(raw) >= count * 12 + 4:
                todo.append(struct.unpack(e + "I", raw[count * 12:count * 12 + 4])[0])
    return best if best[0] and best[1] else None


def _image_size(path: str) -> tuple[int, int] | None:
    ext = os.path.splitext(path)[1].lower()
    if ext in RAW_EXTS:
        try:
            raw = _raw_size(path)
        except (OSError, struct.error):
            raw = None
        if raw:
            return raw
    if ext == ".cr3":                                 # Canon's newer RAW is a movie-style file: its picture track
        try:
            info = _read_video(path)
        except (OSError, struct.error, IndexError):
            info = {}
        if info.get("width") and info.get("height"):
            return int(info["width"]), int(info["height"])
        return None
    from PIL import Image
    try:
        import batch_crop                             # registers HEIC with Pillow, when it can
    except ImportError:
        pass
    try:
        with Image.open(path) as im:                  # the header only: nothing is decoded
            return im.size
    except Image.DecompressionBombError as err:       # too big for Pillow to open — which says how big
        import re
        m = re.search(r"\((\d+) pixels\)", str(err))
        if m:
            side = int(int(m.group(1)) ** 0.5)
            return side, int(m.group(1)) // max(1, side)
        return None
    except Exception:  # noqa: BLE001 — not a picture Pillow can read
        return None


def _probed_video(path: str) -> tuple[int, int, bool] | None:
    """A video this module can't read itself (WebM, MKV, AVI, …), asked of ffprobe when it's installed."""
    try:
        import video_tools
        doc = video_tools._ffprobe(path, "-select_streams", "v:0", "-show_entries",
                                   "stream=width,height,color_transfer")
        st = doc["streams"][0]
        return int(st["width"]), int(st["height"]), str(st.get("color_transfer") or "") in ("smpte2084", "arib-std-b67")
    except Exception:  # noqa: BLE001 — no ffprobe, or nothing it could say
        return None


def spec(path: str, kind: str) -> tuple[int, int, bool] | None:
    """(long side, pixels, HDR) of a photo (`kind` "image") or a video ("video") — the iPhone's `MediaSpec` —
    read from the file's header; None when it can't be told (so it's asked again another time, never guessed).
    Turning a picture doesn't change either number, so its orientation isn't read. Safe on worker threads; not
    cached here (the caller keeps it — `photo_browser.specs`)."""
    if kind == "video":
        info = video_info(path)
        if info.get("width") and info.get("height"):
            w, h, hdr = int(info["width"]), int(info["height"]), bool(info.get("hdr"))
        else:
            got = _probed_video(path)
            if got is None:
                return None
            w, h, hdr = got
    elif kind == "image":
        size = _image_size(path)
        if not size:
            return None
        w, h = size
        hdr = image_hdr(path)
    else:
        return None
    if w <= 0 or h <= 0:
        return None
    return max(w, h), w * h, hdr
