"""Live Photos for Photo Browser for Mac — recognising them, making them, taking them apart. No Qt.

**What a Live Photo is, on the drive** (Apple's own arrangement, and the iPhone app's — `FileActions.makeLivePhoto`,
`ZoomableImageView.findLivePair`): a still and a QuickTime movie **side by side with the same name** (`IMG_1234.HEIC`
+ `IMG_1234.MOV`), each carrying the **same identifier** — the still in its Apple maker note (tag 0x0011, ImageIO's
`{MakerApple}` "17"), the movie as `com.apple.quicktime.content.identifier` in its metadata. A movie Apple's Photos
takes for one also has a little timed-metadata track, `com.apple.quicktime.still-image-time`. Two files that merely
share a name are *not* a Live Photo (downloaded galleries are full of `001.jpg` + `001.mp4`): the identifiers
decide (`motion_for`).

**Reading** (`image_id`, `video_id`) opens only what holds the answer — a JPEG's Exif segment, an HEIC's Exif item
(found through its `iloc`), a movie's `moov` — so a folder of thousands is read through quickly (`pairs_in`, kept by
`Index`).

**Making** (`make`) — a photo and a video become a Live Photo:

- the movie is written as `<photo's name>.mov` beside the photo: **every byte of the video as it was**, plus the
  identifier and the still-image-time track. Nothing is re-encoded and nothing is moved inside the file: the old
  `moov` is left where it is (relabelled `free`) and the new one — with the extra track — goes at the end, with the
  track's one tiny sample before it (`write_video`). Pure Python, the same on every drive.
- the photo gets the identifier: the one it already has is used when it has one (an iPhone photo taken with Live
  on); else it's written into its maker note — by ImageIO through `live_helper.swift` on a Mac (as the iPhone app
  does), by a lossless splice for a JPEG (`jpeg_with_id`: the Exif block grows by one entry, the picture's bytes
  aren't touched), by ExifTool where that can — and where none of those can (a PNG, an HEIC on a Mac without the
  helper) the identifier is kept in an extended attribute on the photo (`XATTR`), which this app reads as well.
- **nothing is deleted**: the video as it was is put in a hidden folder beside the photo, `.Live Photo Originals`
  (with a note of where it came from, `kept.json`) — `separate` puts it back. The photo isn't copied: it's the same
  picture with one line of metadata added, which the app's Undo takes back.

The Live Photo is then one item in the app: the still, with a LIVE mark; its movie isn't listed separately
(`Index.is_motion`). Find Live Photos (`candidates`) lists the photo + video pairs of a folder that share a name and
aren't Live Photos yet, with what speaks for and against each.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import struct
import subprocess
import sys
import threading
import time
import unicodedata
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

IS_MAC = sys.platform == "darwin"
IMAGE_EXTS = (".heic", ".heif", ".jpg", ".jpeg", ".png", ".tif", ".tiff", ".webp", ".dng")
VIDEO_EXTS = (".mov", ".mp4", ".m4v")                     # what can be a Live Photo's movie (QuickTime / MP4 files)
ORIGINALS = ".Live Photo Originals"
XATTR = "com.photobrowser.live-photo"                     # the identifier, on a photo whose maker note can't hold it
ID_KEY = b"com.apple.quicktime.content.identifier"
STILL_KEY = b"com.apple.quicktime.still-image-time"
APPLE = b"Apple iOS\x00\x00\x01MM"                        # how an Apple maker note begins
_UUID = re.compile(rb"[0-9A-Fa-f]{8}-(?:[0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}")
LONG_FOR_LIVE = 6.0                                       # a real Live Photo's movie is about 3 s: longer is said


class LiveError(Exception):
    """Why a Live Photo couldn't be made or taken apart — in words for the person."""


# ============================================================================ atoms (QuickTime / MP4 / HEIF)

def _box(kind: bytes, *parts: bytes) -> bytes:
    body = b"".join(parts)
    return struct.pack(">I4s", 8 + len(body), kind) + body


def _children(data: bytes, start: int = 0, end: int | None = None):
    """(type, offset, header length, whole length) of each atom in data[start:end]."""
    end = len(data) if end is None else end
    at = start
    while at + 8 <= end:
        size, kind = struct.unpack_from(">I4s", data, at)
        head = 8
        if size == 1:
            if at + 16 > end:
                return
            size, head = struct.unpack_from(">Q", data, at + 8)[0], 16
        elif size == 0:
            size = end - at
        if size < head or at + size > end:
            return
        yield kind, at, head, size
        at += size


def _top(f) -> list[tuple[bytes, int, int, int]]:
    """A file's top-level atoms — (type, offset, header length, whole length) — reading only their headers."""
    out = []
    f.seek(0, os.SEEK_END)
    end = f.tell()
    at = 0
    while at + 8 <= end:
        f.seek(at)
        head_bytes = f.read(16)
        if len(head_bytes) < 8:
            break
        size, kind = struct.unpack_from(">I4s", head_bytes, 0)
        head = 8
        if size == 1 and len(head_bytes) >= 16:
            size, head = struct.unpack_from(">Q", head_bytes, 8)[0], 16
        elif size == 0:
            size = end - at
        if size < head or at + size > end:
            break
        out.append((kind, at, head, size))
        at += size
    return out


def _moov(path: str) -> tuple[bytes, int, int] | None:
    """(the movie's `moov` atom, where it is, the file's length) — None when the file isn't a QuickTime/MP4 movie."""
    try:
        with open(path, "rb") as f:
            tops = _top(f)
            for kind, at, _head, size in tops:
                if kind == b"moov" and size <= 256 * 1024 * 1024:
                    f.seek(at)
                    data = f.read(size)
                    f.seek(0, os.SEEK_END)
                    return data, at, f.tell()
    except OSError:
        return None
    return None


def _meta_parts(data: bytes, at: int, head: int, size: int) -> tuple[bool, list[tuple[bytes, int, int, int]]]:
    """A `meta` atom's children, and whether it has the 4 version bytes in front of them (ISO files do; QuickTime's
    own, as AVFoundation writes it, doesn't)."""
    start, end = at + head, at + size
    plain = list(_children(data, start, end))
    if plain and plain[0][0] in (b"hdlr", b"keys", b"ilst"):
        return False, plain
    return True, list(_children(data, start + 4, end))


def _keys_and_values(data: bytes, parts) -> tuple[list[bytes], dict[int, bytes]]:
    """A QuickTime metadata atom's key names (in order) and its values' raw item bodies, by key number (from 1)."""
    names: list[bytes] = []
    values: dict[int, bytes] = {}
    for kind, at, head, size in parts:
        if kind == b"keys":
            count = struct.unpack_from(">I", data, at + head + 4)[0]
            p = at + head + 8
            for _ in range(count):
                if p + 8 > at + size:
                    break
                ksize = struct.unpack_from(">I", data, p)[0]
                if ksize < 8:
                    break
                names.append(data[p + 8:p + ksize])
                p += ksize
        elif kind == b"ilst":
            for _k, iat, ihead, isize in _children(data, at + head, at + size):
                values[struct.unpack_from(">I", data, iat + 4)[0]] = data[iat + ihead:iat + isize]
    return names, values


def _metas(moov: bytes):
    """The movie's metadata atoms: `moov/meta` (QuickTime's) and `moov/udta/meta`."""
    for kind, at, head, size in _children(moov, 8 if moov[4:8] == b"moov" else 0):
        if kind == b"meta":
            yield at, head, size
        elif kind == b"udta":
            for k2, a2, h2, s2 in _children(moov, at + head, at + size):
                if k2 == b"meta":
                    yield a2, h2, s2


def video_id(path: str) -> str:
    """The movie's content identifier ("" when it has none, or isn't a QuickTime/MP4 file)."""
    got = _moov(path)
    if got is None:
        return ""
    moov = got[0]
    for at, head, size in _metas(moov):
        _full, parts = _meta_parts(moov, at, head, size)
        names, values = _keys_and_values(moov, parts)
        for n, name in enumerate(names, 1):
            if name == ID_KEY and n in values:
                item = values[n]
                for kind, dat, dhead, dsize in _children(item):
                    if kind == b"data" and dsize >= dhead + 8:
                        return item[dat + dhead + 8:dat + dsize].decode("utf-8", "replace").strip("\x00 ").upper()
    return ""


def has_still_time(path: str) -> bool:
    """Whether the movie has the still-image-time track Apple's Photos looks for."""
    got = _moov(path)
    return got is not None and STILL_KEY in got[0]


def _movie_facts(moov: bytes) -> tuple[int, int, int]:
    """(timescale, duration in it, the highest track number) of the movie."""
    scale, duration, top_id = 600, 0, 0
    for kind, at, head, size in _children(moov, 8):
        body = at + head
        if kind == b"mvhd":
            if moov[body] == 1:
                scale, duration = struct.unpack_from(">IQ", moov, body + 20)
            else:
                scale, duration = struct.unpack_from(">II", moov, body + 12)
        elif kind == b"trak":
            for k2, a2, h2, _s2 in _children(moov, body, at + size):
                if k2 == b"tkhd":
                    b2 = a2 + h2
                    top_id = max(top_id, struct.unpack_from(">I", moov, b2 + (20 if moov[b2] == 1 else 12))[0])
    return scale or 600, duration, top_id


def video_seconds(path: str) -> float:
    got = _moov(path)
    if got is None:
        return 0.0
    scale, duration, _top_id = _movie_facts(got[0])
    return duration / scale if scale else 0.0


def _meta_with_id(moov: bytes, ident: str) -> tuple[bytes, tuple[int, int] | None]:
    """The movie's QuickTime metadata atom with the identifier in it, and where the atom it replaces is in `moov`
    (None: there was none)."""
    value = _box(b"data", struct.pack(">II", 1, 0), ident.encode("ascii"))      # type 1: UTF-8
    for at, head, size in _metas(moov):
        full, parts = _meta_parts(moov, at, head, size)
        if not any(k == b"keys" for k, *_rest in parts):
            continue                                       # (an iTunes-style atom under udta: not this one)
        names, values = _keys_and_values(moov, parts)
        if ID_KEY in names:
            values[names.index(ID_KEY) + 1] = value
        else:
            names.append(ID_KEY)
            values[len(names)] = value
        hdlr = next((moov[a:a + s] for k, a, _h, s in parts if k == b"hdlr"), _mdta_hdlr())
        rest = b"".join(moov[a:a + s] for k, a, _h, s in parts if k not in (b"hdlr", b"keys", b"ilst"))
        return _box(b"meta", (b"\x00" * 4 if full else b""), hdlr, _keys_box(names), _ilst_box(values), rest), (at, size)
    return _box(b"meta", _mdta_hdlr(), _keys_box([ID_KEY]), _ilst_box({1: value})), None


def _mdta_hdlr() -> bytes:
    return _box(b"hdlr", b"\x00" * 8, b"mdta", b"\x00" * 12, b"\x00")


def _keys_box(names: list[bytes]) -> bytes:
    return _box(b"keys", struct.pack(">II", 0, len(names)),
                *(struct.pack(">I4s", 8 + len(n), b"mdta") + n for n in names))


def _ilst_box(values: dict[int, bytes]) -> bytes:
    return _box(b"ilst", *(struct.pack(">II", 8 + len(v), n) + v for n, v in sorted(values.items())))


def _still_track(track_id: int, scale: int, duration: int, sample_at: int, now: int) -> bytes:
    """A timed-metadata track holding one `still-image-time` value (an int8, 0) for the whole movie — what
    AVAssetWriter's metadata adaptor writes for the iPhone app, atom for atom."""
    matrix = struct.pack(">9I", 0x10000, 0, 0, 0, 0x10000, 0, 0, 0, 0x40000000)
    tkhd = _box(b"tkhd", struct.pack(">IIIIII", 0x00000003, now, now, track_id, 0, min(duration, 0xFFFFFFFF)),
                b"\x00" * 8, struct.pack(">hhhh", 0, 0, 0, 0), matrix, struct.pack(">II", 0, 0))
    mdhd = _box(b"mdhd", struct.pack(">IIIIIHH", 0, now, now, scale, min(duration, 0xFFFFFFFF), 0x55C4, 0))

    def handler(kind: bytes, sub: bytes, name: bytes) -> bytes:
        return _box(b"hdlr", b"\x00" * 4, kind, sub, b"appl", b"\x00" * 8, bytes([len(name)]) + name)
    key = _box(struct.pack(">I", 1),                                   # the key's number in this track: 1
               _box(b"keyd", b"mdta", STILL_KEY),
               _box(b"dtyp", struct.pack(">II", 0, 65)))               # a well-known type: 65, a signed 8-bit number
    mebx = _box(b"mebx", b"\x00" * 6, struct.pack(">H", 1), _box(b"keys", key))
    big = sample_at > 0xFFFFFFFF
    stbl = _box(b"stbl",
                _box(b"stsd", struct.pack(">II", 0, 1), mebx),
                _box(b"stts", struct.pack(">IIII", 0, 1, 1, min(duration, 0xFFFFFFFF))),
                _box(b"stsc", struct.pack(">IIIII", 0, 1, 1, 1, 1)),
                _box(b"stsz", struct.pack(">III", 0, 9, 1)),
                _box(b"co64" if big else b"stco", struct.pack(">IIQ" if big else ">III", 0, 1, sample_at)))
    minf = _box(b"minf",
                _box(b"gmhd", _box(b"gmin", struct.pack(">IHHHHHH", 0, 0x40, 0x8000, 0x8000, 0x8000, 0, 0))),
                handler(b"dhlr", b"alis", b"Core Media Data Handler"),
                _box(b"dinf", _box(b"dref", struct.pack(">II", 0, 1), _box(b"alis", struct.pack(">I", 1)))),
                stbl)
    return _box(b"trak", tkhd, _box(b"mdia", mdhd, handler(b"mhlr", b"meta", b"Core Media Metadata"), minf))


STILL_SAMPLE = struct.pack(">II", 9, 1) + b"\x00"         # the track's one sample: [length][key 1][0]


def write_video(src: str, dst: str, ident: str) -> None:
    """`src` as a Live Photo's movie at `dst` (which mustn't exist): the same bytes, with the content identifier
    and — if it hasn't one — the still-image-time track. Raises LiveError when `src` isn't a QuickTime/MP4 movie."""
    got = _moov(src)
    if got is None:
        raise LiveError(f"“{os.path.basename(src)}” isn't a QuickTime or MP4 movie — convert it to MP4 first.")
    moov, moov_at, length = got
    scale, duration, top_id = _movie_facts(moov)
    if not duration:
        raise LiveError(f"“{os.path.basename(src)}” has no length — it can't be a Live Photo's movie.")
    head = 16 if struct.unpack_from(">I", moov, 0)[0] == 1 else 8
    meta, replaced = _meta_with_id(moov, ident)
    need_track = STILL_KEY not in moov
    sample_at = length + 8                                  # after everything there is, inside a new little mdat
    now = int(time.time()) + 2082844800                     # QuickTime counts seconds from 1904
    parts: list[bytes] = []
    for kind, at, khead, size in _children(moov, head):
        atom = moov[at:at + size]
        if replaced is not None and at == replaced[0]:
            atom = meta
        elif kind == b"mvhd" and need_track:
            atom = atom[:-4] + struct.pack(">I", max(top_id + 2, struct.unpack_from(">I", atom, len(atom) - 4)[0] + 1))
        elif kind == b"udta" and replaced is not None and at < replaced[0] < at + size:
            a = replaced[0] - at                             # the metadata atom is inside this one
            inner = atom[khead:a] + meta + atom[a + replaced[1]:]
            atom = struct.pack(">I4s", 8 + len(inner), b"udta") + inner
        parts.append(atom)
    if need_track:
        parts.append(_still_track(top_id + 1, scale, duration, sample_at, now))
    if replaced is None:
        parts.append(meta)
    new_moov = _box(b"moov", *parts)
    tmp = dst + ".part"
    try:
        clone(src, tmp)
        with open(tmp, "r+b") as f:
            f.seek(moov_at + 4)
            f.write(b"free")                                 # the old index stays where it is, out of use
            f.seek(0, os.SEEK_END)
            if f.tell() != length:
                raise LiveError(f"“{os.path.basename(src)}” changed while it was being read.")
            if need_track:
                f.write(_box(b"mdat", STILL_SAMPLE))
            f.write(new_moov)
            f.flush()
            os.fsync(f.fileno())
        if video_id(tmp) != ident.upper():
            raise LiveError(f"“{os.path.basename(src)}” couldn't be given the Live Photo's identifier.")
        if os.path.lexists(dst):
            raise LiveError(f"“{os.path.basename(dst)}” is already there.")
        os.replace(tmp, dst)
    finally:
        try:
            if os.path.lexists(tmp):
                os.remove(tmp)
        except OSError:
            pass
    copy_dates(src, dst)


# ============================================================================ the photo's identifier

def _exif_of(path: str) -> bytes:
    """The photo's Exif block (the TIFF data), read from where it is — b"" when there's none to be found."""
    ext = os.path.splitext(path)[1].lower()
    try:
        with open(path, "rb") as f:
            start = f.read(16)
            if start[:2] == b"\xff\xd8":
                return _jpeg_exif(f)
            if start[4:8] == b"ftyp":
                return _heif_exif(f)
            if start[:4] in (b"II*\x00", b"MM\x00*"):          # a TIFF (or DNG): the file is the block
                f.seek(0)
                return f.read(2 * 1024 * 1024)
            if ext == ".png" or start[:8] == b"\x89PNG\r\n\x1a\n":
                return _png_exif(f)
    except (OSError, struct.error):
        pass
    return b""


def _jpeg_exif(f) -> bytes:
    f.seek(2)
    for _ in range(64):
        marker = f.read(4)
        if len(marker) < 4 or marker[0] != 0xFF or marker[1] in (0xDA, 0xD9):
            return b""
        size = struct.unpack(">H", marker[2:])[0]
        if marker[1] == 0xE1:
            body = f.read(size - 2)
            if body[:6] == b"Exif\x00\x00":
                return body[6:]
        else:
            f.seek(size - 2, os.SEEK_CUR)
    return b""


def _png_exif(f) -> bytes:
    f.seek(8)
    for _ in range(4096):
        head = f.read(8)
        if len(head) < 8:
            return b""
        size, kind = struct.unpack(">I4s", head)
        if kind == b"eXIf":
            return f.read(size)
        if kind in (b"IDAT", b"IEND"):
            return b""
        f.seek(size + 4, os.SEEK_CUR)
    return b""


def _heif_exif(f) -> bytes:
    """An HEIC's Exif item, by its place in the file (`meta` → `iinf` says which item it is, `iloc` where)."""
    for kind, at, head, size in _top(f):
        if kind != b"meta" or size > 16 * 1024 * 1024:
            continue
        f.seek(at)
        meta = f.read(size)
        exif_id, where = None, {}
        for k, a, h, s in _children(meta, head + 4):
            if k == b"iinf":
                version = meta[a + h]
                p = a + h + (6 if version == 0 else 8)
                for k2, a2, h2, _s2 in _children(meta, p, a + s):
                    if k2 != b"infe":
                        continue
                    v2 = meta[a2 + h2]
                    b2 = a2 + h2 + 4
                    if v2 >= 2:
                        item_id, b2 = (struct.unpack_from(">H", meta, b2)[0], b2 + 2) if v2 == 2 else \
                            (struct.unpack_from(">I", meta, b2)[0], b2 + 4)
                        if meta[b2 + 2:b2 + 6] == b"Exif":
                            exif_id = item_id
            elif k == b"iloc":
                version = meta[a + h]
                b = a + h + 4
                sizes = struct.unpack_from(">H", meta, b)[0]
                off_n, len_n, base_n, idx_n = sizes >> 12, (sizes >> 8) & 15, (sizes >> 4) & 15, sizes & 15
                b += 2
                count, b = (struct.unpack_from(">H", meta, b)[0], b + 2) if version < 2 else \
                    (struct.unpack_from(">I", meta, b)[0], b + 4)

                def num(n: int, p: int) -> int:
                    return int.from_bytes(meta[p:p + n], "big") if n else 0
                for _ in range(count):
                    item_id, b = (struct.unpack_from(">H", meta, b)[0], b + 2) if version < 2 else \
                        (struct.unpack_from(">I", meta, b)[0], b + 4)
                    method = 0
                    if version in (1, 2):
                        method = struct.unpack_from(">H", meta, b)[0] & 15
                        b += 2
                    b += 2                                    # data reference index
                    base = num(base_n, b)
                    b += base_n
                    extents = struct.unpack_from(">H", meta, b)[0]
                    b += 2
                    first = None
                    for _e in range(extents):
                        if version in (1, 2) and idx_n:
                            b += idx_n
                        off, ln = num(off_n, b), num(len_n, b + off_n)
                        b += off_n + len_n
                        if first is None:
                            first = (base + off, ln)
                    if first is not None and method == 0:
                        where[item_id] = first
        if exif_id is None or exif_id not in where:
            return b""
        off, ln = where[exif_id]
        if not 0 < ln <= 8 * 1024 * 1024:
            return b""
        f.seek(off)
        block = f.read(ln)
        skip = struct.unpack_from(">I", block, 0)[0] if len(block) >= 4 else 0     # bytes before the TIFF header
        return block[4 + skip:] if 4 + skip < len(block) else b""
    return b""


def _apple_id(block: bytes) -> str:
    """The identifier in an Apple maker note inside `block` (an Exif block, or any bytes that hold one)."""
    at = block.find(APPLE)
    while at >= 0:
        try:
            ifd = at + len(APPLE)
            for i in range(struct.unpack_from(">H", block, ifd)[0]):
                tag, kind, count, value = struct.unpack_from(">HHII", block, ifd + 2 + 12 * i)
                if tag == 0x0011 and kind == 2 and 8 < count <= 64:
                    text = block[at + value:at + value + count].split(b"\x00")[0]
                    if _UUID.fullmatch(text):
                        return text.decode("ascii").upper()
        except struct.error:
            pass
        at = block.find(APPLE, at + 1)
    return ""


def image_id(path: str) -> str:
    """The photo's Live Photo identifier ("" when it has none): its Apple maker note's, else the one this app
    keeps in an extended attribute for photos whose maker note couldn't be written."""
    found = _apple_id(_exif_of(path))
    if found:
        return found
    raw = _xattr_get(path)
    return raw.upper() if raw and _UUID.fullmatch(raw.encode("ascii", "ignore")) else ""


def _xattr_get(path: str) -> str:
    try:
        import shared_tags
        got = shared_tags.xattr_get(path, XATTR)
        return got.decode("ascii", "ignore").strip() if got else ""
    except Exception:  # noqa: BLE001 — no attribute support here: none kept
        return ""


def _xattr_set(path: str, value: str) -> bool:
    try:
        import shared_tags
        import spare_folders
        if value and spare_folders.on_exfat(path):          # (macOS would keep it in a "._" file beside the photo)
            return False
        if value:
            shared_tags.xattr_set(path, XATTR, value.encode("ascii"))
        else:
            shared_tags.xattr_remove(path, XATTR)
        return not value or _xattr_get(path).upper() == value.upper()
    except Exception:  # noqa: BLE001
        return False


def _maker_note(ident: str) -> bytes:
    """An Apple maker note holding just the identifier (offsets in it count from its own start)."""
    text = ident.encode("ascii") + b"\x00"
    return APPLE + struct.pack(">H", 1) + struct.pack(">HHII", 0x0011, 2, len(text), len(APPLE) + 2 + 12 + 4) \
        + b"\x00" * 4 + text


def _tiff_with_note(tiff: bytes, note: bytes) -> bytes | None:
    """`tiff` (an Exif block) with `note` as its maker note — added at the end, the directories that point to it
    written again there, everything else left exactly where it is. None when it already has a maker note (another
    camera's: not replaced) or can't be read."""
    if tiff[:2] == b"II":
        e = "<"
    elif tiff[:2] == b"MM":
        e = ">"
    else:
        return None
    try:
        def entries(at: int) -> tuple[list[tuple[int, int, int, bytes]], int]:
            n = struct.unpack_from(e + "H", tiff, at)[0]
            out = []
            for i in range(n):
                tag, kind, count = struct.unpack_from(e + "HHI", tiff, at + 2 + 12 * i)
                out.append((tag, kind, count, tiff[at + 10 + 12 * i:at + 14 + 12 * i]))
            return out, struct.unpack_from(e + "I", tiff, at + 2 + 12 * n)[0]

        def directory(items, nxt: int) -> bytes:
            items = sorted(items, key=lambda x: x[0])
            return struct.pack(e + "H", len(items)) + b"".join(
                struct.pack(e + "HHI", t, k, c) + v for t, k, c, v in items) + struct.pack(e + "I", nxt)
        ifd0_at = struct.unpack_from(e + "I", tiff, 4)[0]
        ifd0, next0 = entries(ifd0_at)
        exif_ptr = next((struct.unpack(e + "I", v)[0] for t, _k, _c, v in ifd0 if t == 0x8769), None)
        sub, sub_next = entries(exif_ptr) if exif_ptr else ([], 0)
        if any(t == 0x927C for t, *_r in sub):
            return None
        out = bytearray(tiff)
        if len(out) % 2:
            out.append(0)
        note_at = len(out)
        out += note + (b"\x00" if len(note) % 2 else b"")
        sub_at = len(out)
        out += directory(sub + [(0x927C, 7, len(note), struct.pack(e + "I", note_at))], sub_next)
        ifd0 = [x for x in ifd0 if x[0] != 0x8769] + [(0x8769, 4, 1, struct.pack(e + "I", sub_at))]
        new0_at = len(out)
        out += directory(ifd0, next0)
        struct.pack_into(e + "I", out, 4, new0_at)
        return bytes(out)
    except (struct.error, IndexError):
        return None


def jpeg_with_id(data: bytes, ident: str) -> bytes | None:
    """A JPEG's bytes with the identifier in its Exif block's Apple maker note — the picture's own bytes untouched.
    None when it can't be done this way (another camera's maker note is there, or the block would be too big)."""
    if data[:2] != b"\xff\xd8":
        return None
    note = _maker_note(ident)
    at, exif_at, exif_len, insert_at = 2, None, 0, 2
    while at + 4 <= len(data) and data[at] == 0xFF and data[at + 1] not in (0xDA, 0xD9):
        size = struct.unpack_from(">H", data, at + 2)[0]
        if data[at + 1] == 0xE1 and data[at + 4:at + 10] == b"Exif\x00\x00" and exif_at is None:
            exif_at, exif_len = at, size + 2
        if data[at + 1] == 0xE0:
            insert_at = at + size + 2                       # after the JFIF header, where a new block goes
        at += size + 2
    if exif_at is not None:
        tiff = _tiff_with_note(data[exif_at + 10:exif_at + exif_len], note)
    else:
        # no Exif at all: the smallest block that holds a maker note
        tiff = _tiff_with_note(b"MM\x00\x2a" + struct.pack(">I", 8) + struct.pack(">H", 0) + struct.pack(">I", 0), note)
    if tiff is None or len(tiff) + 8 > 0xFFFF:
        return None
    segment = b"\xff\xe1" + struct.pack(">H", len(tiff) + 8) + b"Exif\x00\x00" + tiff
    if exif_at is not None:
        out = data[:exif_at] + segment + data[exif_at + exif_len:]
    else:
        out = data[:insert_at] + segment + data[insert_at:]
    return out if _apple_id(tiff) == ident.upper() else None


_helper: list[str] | None | bool = False
_helper_lock = threading.Lock()


def helper() -> list[str] | None:
    """The command that runs live_helper (ImageIO writing the maker note, as the iPhone app does) — built the
    first time, on a Mac with Xcode's Command Line Tools; None elsewhere."""
    global _helper
    with _helper_lock:
        if _helper is not False:
            return _helper  # type: ignore[return-value]
        _helper = None
        env = os.environ.get("PHOTO_BROWSER_LIVE_HELPER")
        if env:
            _helper = env.split("\x1f")
            return _helper
        src = Path(__file__).with_name("live_helper.swift")
        if not IS_MAC or not src.is_file():
            return None
        out = Path.home() / "Library" / "Caches" / "PhotoBrowser" / "live_helper"
        try:
            if out.is_file() and out.stat().st_mtime >= src.stat().st_mtime:
                _helper = [str(out)]
                return _helper
            if subprocess.run(["xcode-select", "-p"], capture_output=True).returncode != 0:
                return None
            out.parent.mkdir(parents=True, exist_ok=True)
            r = subprocess.run(["xcrun", "swiftc", "-O", "-parse-as-library", "-swift-version", "5", "-o", str(out),
                                str(src)], capture_output=True, text=True, timeout=900)
            if r.returncode == 0 and out.is_file():
                _helper = [str(out)]
            else:
                out.with_name("live_helper.log").write_text(f"swiftc failed ({r.returncode})\n\n{r.stderr}{r.stdout}")
        except (OSError, subprocess.SubprocessError):
            _helper = None
        return _helper  # type: ignore[return-value]


def _image_bytes_with_id(path: str, ident: str) -> bytes | None:
    """The photo's bytes with the identifier in its maker note, by whichever way can do it — None when none can."""
    tmp_dir = None
    try:
        cmd = helper()
        if cmd:
            import tempfile
            tmp_dir = tempfile.mkdtemp(prefix="pb-live-")
            out = os.path.join(tmp_dir, "out" + os.path.splitext(path)[1])
            r = subprocess.run([*cmd, "image-id", path, out, ident], capture_output=True, text=True, timeout=120)
            if r.returncode == 0 and os.path.isfile(out) and image_id(out) == ident.upper():
                with open(out, "rb") as f:
                    return f.read()
        with open(path, "rb") as f:
            data = f.read()
        if data[:2] == b"\xff\xd8":
            spliced = jpeg_with_id(data, ident)
            if spliced is not None:
                return spliced
        exiftool = shutil.which("exiftool")
        if exiftool:                                        # (it can add to a maker note that's there; not make one)
            import tempfile
            tmp_dir = tmp_dir or tempfile.mkdtemp(prefix="pb-live-")
            out = os.path.join(tmp_dir, "x" + os.path.splitext(path)[1])
            shutil.copyfile(path, out)
            subprocess.run([exiftool, "-q", "-q", "-overwrite_original", f"-Apple:ContentIdentifier={ident}", out],
                           capture_output=True, timeout=120)
            if _apple_id(_exif_of(out)) == ident.upper():
                with open(out, "rb") as f:
                    return f.read()
    except (OSError, subprocess.SubprocessError):
        return None
    finally:
        if tmp_dir:
            shutil.rmtree(tmp_dir, ignore_errors=True)
    return None


# ============================================================================ files: copies, dates, the hidden folder

def clone(src: str, dst: str) -> None:
    """A copy of `src` at `dst` — on APFS one that takes no space until it's changed (`cp -c`)."""
    if IS_MAC:
        try:
            if subprocess.run(["/bin/cp", "-c", src, dst], capture_output=True, timeout=3600).returncode == 0:
                return
        except (OSError, subprocess.SubprocessError):
            pass
    shutil.copyfile(src, dst)


def copy_dates(src: str, dst: str) -> None:
    """`dst` dated as `src` is (created and modified), and given its extended attributes."""
    try:
        st = os.stat(src)
        created = getattr(st, "st_birthtime", st.st_mtime)
        try:
            import clone_drive
            clone_drive.set_dates(dst, created, st.st_mtime)
        except Exception:  # noqa: BLE001 — at least the modified date
            os.utime(dst, (st.st_atime, st.st_mtime))
    except OSError:
        pass
    try:
        import batch_crop
        batch_crop.copy_xattrs(src, dst)
    except Exception:  # noqa: BLE001
        pass


def originals_dir(folder: str) -> str:
    return os.path.join(folder, ORIGINALS)


def _keep_original(path: str, beside: str) -> str:
    """The video as it is now, moved into the hidden folder in `beside` (the photo's folder). Returns where."""
    folder = originals_dir(beside)
    os.makedirs(folder, exist_ok=True)
    stem, ext = os.path.splitext(os.path.basename(path))
    kept, n = os.path.join(folder, stem + ext), 1
    while os.path.lexists(kept):
        n += 1
        kept = os.path.join(folder, f"{stem} {n}{ext}")
    shutil.move(path, kept)                                 # (a rename on the same drive)
    return kept


def _ledger(folder: str) -> dict:
    """What the hidden folder in `folder` holds: {a Live Photo's movie's name: {"kept": the file kept for it,
    "was": where that video was}}."""
    try:
        with open(os.path.join(originals_dir(folder), "kept.json"), encoding="utf-8") as f:
            doc = json.load(f)
        return doc if isinstance(doc, dict) else {}
    except (OSError, ValueError):
        return {}


def _ledger_save(folder: str, doc: dict) -> None:
    where = originals_dir(folder)
    try:
        if not doc:
            if os.path.isfile(os.path.join(where, "kept.json")):
                os.remove(os.path.join(where, "kept.json"))
            return
        os.makedirs(where, exist_ok=True)
        tmp = os.path.join(where, "kept.json.part")
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(doc, f, ensure_ascii=False, indent=1)
        os.replace(tmp, os.path.join(where, "kept.json"))
    except OSError:
        pass


# ============================================================================ pairs

def is_image(path: str) -> bool:
    return os.path.splitext(path)[1].lower() in IMAGE_EXTS


def is_movie(path: str) -> bool:
    return os.path.splitext(path)[1].lower() in VIDEO_EXTS


def sibling_movies(image: str, names: list[str] | None = None) -> list[str]:
    """The movies beside the photo that share its name (`IMG_1.HEIC` → `IMG_1.MOV`), .mov first."""
    folder, name = os.path.split(image)
    stem = os.path.splitext(name)[0].casefold()
    if names is None:
        try:
            names = os.listdir(folder)
        except OSError:
            return []
    found = [n for n in names if os.path.splitext(n)[0].casefold() == stem and is_movie(n) and not n.startswith(".")]
    return [os.path.join(folder, n) for n in sorted(found, key=lambda n: (not n.lower().endswith(".mov"), n))]


def motion_for(image: str, names: list[str] | None = None) -> str:
    """The Live Photo's movie for this photo — a same-named movie beside it with the photo's identifier — or ""."""
    if not is_image(image):
        return ""
    movies = sibling_movies(image, names)
    if not movies:
        return ""
    ident = image_id(image)
    if not ident:
        return ""
    return next((m for m in movies if video_id(m) == ident), "")


@dataclass
class Candidate:
    """A photo and a video that share a name, for Find Live Photos."""
    image: str
    video: str
    live: bool = False                 # already a Live Photo (their identifiers agree)
    seconds: float = 0.0               # the video's length
    apart: float | None = None         # seconds between the two files' dates (None: unknown)
    notes: list[str] = field(default_factory=list)       # what speaks against the pair
    likely: bool = True                # ticked to begin with


def _when(path: str) -> float:
    try:
        st = os.stat(path)
        return min(st.st_mtime, getattr(st, "st_birthtime", st.st_mtime))
    except OSError:
        return 0.0


def candidates(folder: str, deep: bool = False, stop: Callable[[], bool] | None = None,
               note: Callable[[str], None] | None = None) -> list[Candidate]:
    """The photo + video pairs in `folder` (and, `deep`, the folders inside it) that share a name: those that are
    Live Photos already (`live`), and those that could be made into one — each with the video's length, how far
    apart the two files are dated, and anything that speaks against the pair (a long video, dates far apart, a
    photo that names another movie). Hidden folders are left out."""
    out: list[Candidate] = []
    for root, dirs, files in os.walk(folder):
        if stop is not None and stop():
            break
        dirs[:] = sorted(d for d in dirs if not d.startswith(".")) if deep else []
        if note:
            note(root)
        names = [n for n in files if not n.startswith(".")]
        movies: dict[str, list[str]] = {}
        for n in names:
            if is_movie(n):
                movies.setdefault(os.path.splitext(n)[0].casefold(), []).append(n)
        if not movies:
            continue
        taken: set[str] = set()
        for n in sorted(names):
            stem, ext = os.path.splitext(n)
            if ext.lower() not in IMAGE_EXTS or stem.casefold() not in movies:
                continue
            image = os.path.join(root, n)
            vids = sorted(movies[stem.casefold()], key=lambda v: (not v.lower().endswith(".mov"), v))
            ident = image_id(image)
            ids = {v: video_id(os.path.join(root, v)) for v in vids}
            match = next((v for v in vids if ident and ids[v] == ident), None)
            v = match or next((x for x in vids if x not in taken), vids[0])
            video = os.path.join(root, v)
            c = Candidate(image, video, live=match is not None, seconds=video_seconds(video))
            if v in taken and not c.live:
                continue                                    # (two photos of one name: the movie goes with the first)
            taken.add(v)
            a, b = _when(image), _when(video)
            c.apart = abs(a - b) if a and b else None
            if not c.live:
                if c.seconds <= 0:
                    c.notes.append("the video can't be read as a QuickTime or MP4 movie")
                    c.likely = False
                elif c.seconds > LONG_FOR_LIVE:
                    c.notes.append(f"the video is {c.seconds:.0f} s long — a Live Photo's is about 3")
                    c.likely = False
                if c.apart is not None and c.apart > 120:
                    c.notes.append("the two files are dated " + _span(c.apart) + " apart")
                    c.likely = False
                if ident and ids[v] and ids[v] != ident:
                    c.notes.append("each already belongs to a different Live Photo")
                    c.likely = False
            out.append(c)
    return out


def _span(seconds: float) -> str:
    if seconds < 3600:
        return f"{seconds / 60:.0f} minutes"
    if seconds < 2 * 86400:
        return f"{seconds / 3600:.0f} hours"
    return f"{seconds / 86400:.0f} days"


# ============================================================================ making one, and taking it apart

@dataclass
class Made:
    image: str
    video: str                         # the Live Photo's movie, beside the photo
    kept: list[str] = field(default_factory=list)        # the video as it was, now in the hidden folder
    how: str = ""                      # where the photo's identifier is: "had", "maker note", "attribute"
    was_video: str = ""                # where the video was before (for putting it back)


def make(image: str, video: str, write_image: Callable[[str, bytes], None] | None = None) -> Made:
    """`image` and `video` as a Live Photo (module notes). `write_image(path, data)` puts new bytes in place of the
    photo's (the app's undoable `batch_crop.write_in_place`); without it the photo is rewritten here. Raises
    LiveError when it can't be done; what was there is then as it was."""
    if not os.path.isfile(image) or not os.path.isfile(video):
        raise LiveError("The photo or the video isn't there any more.")
    if not is_image(image):
        raise LiveError(f"“{os.path.basename(image)}” isn't a photo a Live Photo can be made from.")
    if not is_movie(video):
        raise LiveError(f"“{os.path.basename(video)}” isn't a QuickTime or MP4 movie — convert it to MP4 first.")
    folder = os.path.dirname(image)
    target = os.path.join(folder, os.path.splitext(os.path.basename(image))[0] + ".mov")
    same = os.path.exists(target) and os.path.samefile(target, video)
    if os.path.lexists(target) and not same:
        raise LiveError(f"“{os.path.basename(target)}” is already beside the photo — a Live Photo's movie has the "
                        "photo's name. Rename one of them first.")
    had = image_id(image)
    ident = had or str(uuid.uuid4()).upper()
    out = Made(image, target, was_video=video)
    kept = ""
    try:
        if same:                                            # the movie already has the name: its old self steps aside
            kept = _keep_original(video, folder)
            write_video(kept, target, ident)
        else:
            write_video(video, target, ident)
        if had:
            out.how = "had"
        else:
            data = _image_bytes_with_id(image, ident)
            if data is not None:
                if write_image is not None:
                    write_image(image, data)
                else:
                    tmp = image + ".part"
                    with open(tmp, "wb") as f:
                        f.write(data)
                    copy_dates(image, tmp)
                    os.replace(tmp, image)
                out.how = "maker note"
                _xattr_set(image, ident)                    # …and beside it: the pair holds if the edit is undone
            elif _xattr_set(image, ident):
                out.how = "attribute"
            else:
                raise LiveError(f"“{os.path.basename(image)}” couldn't be given the Live Photo's identifier (this "
                                "kind of photo needs the app's helper, which isn't built on this Mac, and the "
                                "drive doesn't keep extended attributes).")
        if motion_for(image) != target:
            raise LiveError("The photo and the movie didn't come out as a pair.")
        if not same:                                        # the video as it was: hidden, not deleted
            kept = _keep_original(video, folder)
    except (LiveError, OSError) as e:
        # as it was: the new movie gone, the old one back where it was
        try:
            if os.path.lexists(target) and (not same or kept):
                os.remove(target)
            if kept and os.path.lexists(kept) and not os.path.lexists(video):
                shutil.move(kept, video)
            _tidy(originals_dir(folder))
        except OSError:
            pass
        raise e if isinstance(e, LiveError) else LiveError(f"Couldn't make the Live Photo: {e.strerror or e}")
    out.kept.append(kept)
    doc = _ledger(folder)
    doc[os.path.basename(target)] = {"kept": os.path.basename(kept), "was": video}
    _ledger_save(folder, doc)
    return out


def separate(image: str) -> tuple[str, str]:
    """A Live Photo taken apart: the photo stays (its identifier stays in it — harmless), the Live Photo's movie
    goes, and the video as it was comes back from the hidden folder — to where it was when that's free, else beside
    the photo. Returns (the video now, what happened in words). A Live Photo that came whole from an iPhone has
    nothing kept: its movie is renamed "<name> (video).mov", a video of its own again."""
    movie = motion_for(image)
    if not movie:
        raise LiveError(f"“{os.path.basename(image)}” isn't a Live Photo.")
    folder = os.path.dirname(image)
    stem = os.path.splitext(os.path.basename(image))[0]
    doc = _ledger(folder)
    entry = doc.get(os.path.basename(movie)) if isinstance(doc.get(os.path.basename(movie)), dict) else None
    kept = os.path.join(originals_dir(folder), str(entry.get("kept") or "")) if entry else ""
    try:
        if kept and os.path.isfile(kept):
            was = str(entry.get("was") or "")
            back = was if was and os.path.isdir(os.path.dirname(was)) else os.path.join(folder, os.path.basename(kept))
            os.remove(movie)                                # (every byte of it is in the video coming back)
            if os.path.lexists(back):
                back = _free_name(os.path.dirname(back), os.path.basename(back))
            shutil.move(kept, back)
            doc.pop(os.path.basename(movie), None)
            _ledger_save(folder, doc)
            _tidy(originals_dir(folder))
            return back, "The video is back as it was."
        back = _free_name(folder, f"{stem} (video){os.path.splitext(movie)[1]}")
        os.rename(movie, back)
        return back, f"The movie is “{os.path.basename(back)}” now, a video of its own."
    except OSError as e:
        raise LiveError(f"Couldn't take the Live Photo apart: {e.strerror or e}")


def movie_renamed(old: str, new: str) -> None:
    """A Live Photo's movie was renamed with its photo: the note of what's kept for it follows."""
    folder = os.path.dirname(new)
    doc = _ledger(folder)
    if os.path.basename(old) in doc:
        doc[os.path.basename(new)] = doc.pop(os.path.basename(old))
        _ledger_save(folder, doc)


def _free_name(folder: str, name: str) -> str:
    stem, ext = os.path.splitext(name)
    out, n = os.path.join(folder, name), 1
    while os.path.lexists(out):
        n += 1
        out = os.path.join(folder, f"{stem} {n}{ext}")
    return out


def _tidy(folder: str) -> None:
    try:
        if not [n for n in os.listdir(folder) if n != ".DS_Store"]:
            shutil.rmtree(folder, ignore_errors=True)
    except OSError:
        pass


# ============================================================================ what the window asks, kept

def _nfc(path: str) -> str:
    return unicodedata.normalize("NFC", path)


class Index:
    """Which photos in a folder are Live Photos and which movies are their motion — worked out a folder at a time
    (off the window's thread: `scan`), kept while the folder is unchanged (its modified time, and each pair's own
    times). `motion(image)` / `is_motion(video)` answer from what's known and never read the drive themselves."""

    def __init__(self, store=None) -> None:
        self._lock = threading.Lock()
        self._by_image: dict[str, str] = {}
        self._motions: set[str] = set()
        self._folders: dict[str, float] = {}             # folder → its modified time when scanned
        self._store = store                              # facts_store.FactsStore, or None (kept for the session only)

    def known(self, folder: str) -> bool:
        try:
            return self._folders.get(folder) == os.stat(folder).st_mtime
        except OSError:
            return True

    def any(self) -> bool:
        return bool(self._motions)

    def motion(self, image: str) -> str:
        return self._by_image.get(_nfc(image), "")

    def is_motion(self, video: str) -> bool:
        return _nfc(video) in self._motions

    def moved(self, old_image: str, new_image: str, new_movie: str) -> None:
        """A Live Photo renamed (photo and movie): known under its new names at once."""
        with self._lock:
            self._by_image.pop(_nfc(old_image), None)
            self._by_image[_nfc(new_image)] = new_movie
            self._motions = {_nfc(m) for m in self._by_image.values()}

    def forget(self, folder: str) -> None:
        with self._lock:
            self._folders.pop(folder, None)

    def scan(self, folder: str) -> bool:
        """Reads `folder` (its own files) for Live Photos. Returns whether what's known about it changed."""
        try:
            stamp = os.stat(folder).st_mtime
            names = [n for n in os.listdir(folder) if not n.startswith(".")]
        except OSError:
            return False
        stems: dict[str, list[str]] = {}
        for n in names:
            if is_movie(n):
                stems.setdefault(os.path.splitext(n)[0].casefold(), []).append(n)
        found: dict[str, str] = {}
        for n in names:
            stem, ext = os.path.splitext(n)
            if ext.lower() not in IMAGE_EXTS or stem.casefold() not in stems:
                continue
            image = os.path.join(folder, n)
            movie = self._pair(image, [os.path.join(folder, v) for v in stems[stem.casefold()]])
            if movie:
                found[image] = movie
        found = {_nfc(i): m for i, m in found.items()}
        with self._lock:
            before = {i: m for i, m in self._by_image.items() if os.path.dirname(i) == _nfc(folder)}
            for i in before:
                self._by_image.pop(i, None)
            self._by_image.update(found)
            self._motions = {_nfc(m) for m in self._by_image.values()}
            self._folders[folder] = stamp
        return before != found

    def _pair(self, image: str, movies: list[str]) -> str:
        """The photo's movie among `movies` — from what's kept when neither file has changed, else read."""
        try:
            key = [image, os.stat(image).st_mtime_ns] + [x for m in sorted(movies) for x in (m, os.stat(m).st_mtime_ns)]
        except OSError:
            return ""
        if self._store is not None:
            got = self._store.get("live", key)
            if self._store.known(got):
                return got if isinstance(got, str) and (not got or os.path.isfile(got)) else ""
        ident = image_id(image)
        movie = next((m for m in sorted(movies, key=lambda m: (not m.lower().endswith(".mov"), m))
                      if ident and video_id(m) == ident), "") if ident else ""
        if self._store is not None:
            self._store.put("live", key, movie)
        return movie
