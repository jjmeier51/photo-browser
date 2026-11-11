"""A thumbnail in the colours the photo is meant to have — for Safe Finder's tiles (safe_finder._ThumbJob).

Pillow hands back a file's numbers as they're stored. Shown as they are, that's right only for a plain sRGB
photo. Two kinds were wrong in the grid:

- **HDR photos stored with an HDR curve** — PQ (HDR10 / Dolby Vision) or HLG: the 10-bit HEICs the iPhone app's
  Save Frame and Export All Frames make from HDR video, HDR AVIFs, PNGs with a `cICP` chunk. (Found by the main
  picture's own colour box, its ICC profile's `cicp` tag or name, or the PNG chunk — `curve_of`.) Their numbers
  aren't brightness the way a screen's are, so the tile came out flat, grey and dull. `tone_mapped` turns them
  into what a standard screen should show: the curve undone to light (PQ's EOTF; HLG's inverse OETF and its
  1.2 system gamma), measured against standard white (203 nits), the highlights above white eased in under it
  (a shoulder — what's below ¾ of white is left exactly as it is), BT.2020 or P3 colours brought into sRGB,
  and sRGB's own curve put on.
- **Wide-colour photos** (Display P3 — every iPhone photo, including the standard-range base of an HDR one with
  a gain map): their colours read as sRGB look washed. `standard` converts by the embedded profile.

An HDR photo with a *gain map* (the iPhone's own HDR photos, Ultra HDR JPEGs) needs nothing more than that:
its main image is a standard-range picture, which is what a tile should show (as Finder's does); the viewer
shows the HDR.

Only the thumbnail-sized picture is touched (a few hundred pixels a side), so it costs milliseconds.
"""
from __future__ import annotations

import io
import struct

HDR_WHITE = 203.0                 # nits of standard (SDR) white in an HDR signal — ITU-R BT.2408
PQ, HLG = 16, 18                  # transfer characteristics, as files number them (ITU-T H.273)
BT2020, P3 = 9, 12                # colour primaries


def _curve(transfer: int, primaries: int) -> tuple[int, int] | None:
    return (transfer, primaries) if transfer in (PQ, HLG) else None


def icc_curve(icc: bytes | None) -> tuple[int, int] | None:
    """(transfer, primaries) when an ICC profile is a PQ or HLG one: by its `cicp` tag, else by its name
    ("ITU-R BT.2100 HLG", "Display P3; PQ" — how macOS names the ones it writes)."""
    if not icc or len(icc) < 132:
        return None
    try:
        count = struct.unpack(">I", icc[128:132])[0]
        tags = {}
        for i in range(min(count, 200)):
            sig, off, size = struct.unpack(">4sII", icc[132 + 12 * i:144 + 12 * i])
            tags[sig] = icc[off:off + size]
        c = tags.get(b"cicp")                     # 'cicp', 4 reserved bytes, primaries, transfer, matrix, range
        if c and len(c) >= 10 and c[:4] == b"cicp":
            found = _curve(c[9], c[8])
            if found:
                return found
        d = tags.get(b"desc") or b""
        if d[:4] == b"desc" and len(d) >= 12:     # ICC v2: an ASCII string
            n = struct.unpack(">I", d[8:12])[0]
            name = d[12:12 + n].decode("ascii", "replace")
        elif d[:4] == b"mluc" and len(d) >= 28:   # ICC v4: UTF-16 strings, the first one will do
            length, off = struct.unpack(">II", d[20:28])
            name = d[off:off + length].decode("utf-16-be", "replace")
        else:
            return None
        words = set("".join(ch if ch.isalnum() else " " for ch in name.lower()).split())
        transfer = PQ if words & {"pq", "2084", "st2084"} else HLG if "hlg" in words else 0
        return _curve(transfer, P3 if "p3" in words else BT2020)
    except (struct.error, ValueError):
        return None


def _boxes(data: bytes, start: int = 0, end: int | None = None):
    """(type, payload start, payload end) of each ISO box in data[start:end]."""
    end = len(data) if end is None else min(end, len(data))
    at = start
    while at + 8 <= end:
        size, kind = struct.unpack(">I4s", data[at:at + 8])
        head = 8
        if size == 1 and at + 16 <= end:
            size, head = struct.unpack(">Q", data[at + 8:at + 16])[0], 16
        elif size == 0:
            size = end - at
        if size < head:
            return
        yield kind, at + head, min(at + size, end)
        at += size


def _meta_box(path: str) -> bytes | None:
    """The `meta` box of a HEIF / AVIF file (what's in it, which item is the picture, its properties) — found by
    stepping over the boxes before it, so one that comes after the picture data is found too."""
    with open(path, "rb") as f:
        at = 0
        for _ in range(64):
            f.seek(at)
            head = f.read(16)
            if len(head) < 8:
                return None
            size, kind = struct.unpack(">I4s", head[:8])
            skip = 8
            if size == 1 and len(head) == 16:
                size, skip = struct.unpack(">Q", head[8:16])[0], 16
            if at == 0 and kind != b"ftyp":
                return None
            if kind == b"meta":
                f.seek(at + skip)
                return f.read(min(size - skip if size else 1 << 23, 1 << 23))
            if size < skip:
                return None
            at += size
    return None


def heif_curve(path: str) -> tuple[int, int] | None:
    """(transfer, primaries) when the *main picture* of a HEIF/AVIF file is stored in PQ or HLG.

    Only the main picture's own colour box counts. An iPhone HDR photo also holds a gain map, and (iOS 18+)
    a "tone-mapped" item whose colour box says PQ or HLG — while its main picture is an ordinary standard-range
    one. Taking any PQ in the file for the picture's would turn every one of those tiles dark."""
    meta = _meta_box(path)
    if not meta or len(meta) < 4:
        return None
    primary, ipco, ipma, iref = None, None, None, None
    for kind, a, b in _boxes(meta, 4):                         # a FullBox: 4 bytes of version and flags first
        if kind == b"pitm":
            primary = struct.unpack(">H", meta[a + 4:a + 6])[0] if meta[a] == 0 \
                else struct.unpack(">I", meta[a + 4:a + 8])[0]
        elif kind == b"iref":
            iref = (a, b)
        elif kind == b"iprp":
            for k2, a2, b2 in _boxes(meta, a, b):
                if k2 == b"ipco":
                    ipco = (a2, b2)
                elif k2 == b"ipma":
                    ipma = (a2, b2)
    if primary is None or ipco is None or ipma is None:
        return None
    props = [(k, meta[a:b]) for k, a, b in _boxes(meta, *ipco)]          # numbered from 1

    owned: dict[int, list[int]] = {}                           # item → its properties
    a, b = ipma
    version, flags = meta[a], meta[a + 3]
    at = a + 4
    entries = struct.unpack(">I", meta[at:at + 4])[0]
    at += 4
    for _ in range(entries):
        if at + 5 > b:
            break
        if version < 1:
            item = struct.unpack(">H", meta[at:at + 2])[0]
            at += 2
        else:
            item = struct.unpack(">I", meta[at:at + 4])[0]
            at += 4
        n = meta[at]
        at += 1
        for _ in range(n):
            if flags & 1:
                owned.setdefault(item, []).append(struct.unpack(">H", meta[at:at + 2])[0] & 0x7FFF)
                at += 2
            else:
                owned.setdefault(item, []).append(meta[at] & 0x7F)
                at += 1

    def colours(item: int) -> list[bytes]:
        return [props[i - 1][1] for i in owned.get(item, []) if 0 < i <= len(props) and props[i - 1][0] == b"colr"]

    found = colours(primary)
    if not found and iref is not None:                         # a grid whose tiles carry the colour: the first tile
        a, b = iref
        wide = meta[a] != 0
        for kind, a2, b2 in _boxes(meta, a + 4, b):
            if kind != b"dimg":
                continue
            fmt, step = (">I", 4) if wide else (">H", 2)
            if struct.unpack(fmt, meta[a2:a2 + step])[0] == primary and b2 >= a2 + 2 * step + 2:
                found = colours(struct.unpack(fmt, meta[a2 + step + 2:a2 + 2 * step + 2])[0])
                break
    result = None
    for c in found:
        if c[:4] == b"nclx" and len(c) >= 8:
            prim, tf = struct.unpack(">HH", c[4:8])
            result = result or _curve(tf, prim)
        elif c[:4] in (b"prof", b"rICC"):
            result = result or icc_curve(c[4:])
    return result


def png_curve(path: str) -> tuple[int, int] | None:
    """(transfer, primaries) from a PNG's `cICP` chunk (it comes before the picture data)."""
    with open(path, "rb") as f:
        f.seek(8)
        for _ in range(64):
            head = f.read(8)
            if len(head) < 8:
                return None
            size, kind = struct.unpack(">I4s", head)
            if kind == b"cICP":
                c = f.read(4)
                return _curve(c[1], c[0]) if len(c) == 4 else None
            if kind in (b"IDAT", b"IEND"):
                return None
            f.seek(size + 4, 1)
    return None


def curve_of(path: str, icc: bytes | None = None) -> tuple[int, int] | None:
    """(transfer, primaries) when the photo's own pixels are stored in PQ or HLG — None for everything else,
    a photo that's HDR by a gain map included. `icc` is the embedded profile the decoder reported, if any."""
    try:
        with open(path, "rb") as f:
            start = f.read(12)
        if start[4:8] == b"ftyp":
            found = heif_curve(path)
        elif start[:8] == b"\x89PNG\r\n\x1a\n":
            found = png_curve(path)
        else:
            found = None
    except (OSError, struct.error, IndexError, ValueError):
        found = None
    return found or icc_curve(icc)


def _to_light(v, transfer: int):
    """The stored values (0–1) as light, in units of standard white."""
    import numpy as np
    if transfer == PQ:                            # SMPTE ST 2084: the value → nits, up to 10,000
        m1, m2, c1, c2, c3 = 2610 / 16384, 2523 / 4096 * 128, 3424 / 4096, 2413 / 4096 * 32, 2392 / 4096 * 32
        p = np.power(np.clip(v, 0, 1), 1 / m2)
        nits = 10000.0 * np.power(np.maximum(p - c1, 0) / (c2 - c3 * p), 1 / m1)
        return nits / HDR_WHITE
    a, b, c = 0.17883277, 0.28466892, 0.55991073   # HLG (ARIB STD-B67): scene light, then the display's gamma
    v = np.clip(v, 0, 1)
    scene = np.where(v <= 0.5, v * v / 3.0, (np.exp((v - c) / a) + b) / 12.0)
    y = 0.2627 * scene[..., 0] + 0.6780 * scene[..., 1] + 0.0593 * scene[..., 2]
    display = scene * np.power(np.maximum(y, 1e-6), 0.2)[..., None]         # ×Y^(1.2−1), for a 1000-nit display
    return display * (1000.0 / HDR_WHITE)


_TO_SRGB = {                                      # linear RGB in those primaries → linear sRGB
    BT2020: ((1.6605, -0.5876, -0.0728), (-0.1246, 1.1329, -0.0083), (-0.0182, -0.1006, 1.1187)),
    P3: ((1.2249, -0.2247, 0.0), (-0.0420, 1.0419, 0.0), (-0.0197, -0.0786, 1.0979)),
}


def tone_mapped(im, transfer: int, primaries: int = BT2020):
    """`im` (a Pillow image holding PQ or HLG values) as a standard-range sRGB picture of the same size and mode
    (alpha kept)."""
    import numpy as np
    from PIL import Image
    alpha = im.getchannel("A") if im.mode in ("RGBA", "LA") else None
    rgb = np.asarray(im.convert("RGB"), dtype=np.float32) / 255.0
    light = _to_light(rgb, transfer)
    m = _TO_SRGB.get(primaries)
    if m is not None:
        light = np.clip(light @ np.asarray(m, dtype=np.float32).T, 0, None)
    # The shoulder: by the brightest channel (so a colour keeps its hue as it's brought down), nothing changed
    # below the knee, everything above eased towards white without ever passing it.
    knee = 0.75
    peak = light.max(axis=-1)
    over = np.maximum(peak - knee, 0)
    eased = np.where(peak > knee, knee + (1 - knee) * (1 - np.exp(-over / (1 - knee))), peak)
    light = light * (eased / np.maximum(peak, 1e-6))[..., None]
    light = np.clip(light, 0, 1)
    out = np.where(light <= 0.0031308, light * 12.92, 1.055 * np.power(light, 1 / 2.4) - 0.055)
    res = Image.fromarray((np.clip(out, 0, 1) * 255 + 0.5).astype(np.uint8), "RGB")
    if alpha is not None:
        res.putalpha(alpha)
    return res


def from_profile(im):
    """`im` converted from its embedded colour profile to sRGB (as it is when it has none, or it can't be read)."""
    icc = im.info.get("icc_profile")
    if not icc or im.mode not in ("RGB", "RGBA", "L"):
        return im
    try:
        from PIL import ImageCms
        src = ImageCms.ImageCmsProfile(io.BytesIO(icc))
        name = (ImageCms.getProfileDescription(src) or "").strip().lower()
        if "srgb" in name:                                     # already what the screen expects
            return im
        alpha = im.getchannel("A") if im.mode == "RGBA" else None
        out = ImageCms.profileToProfile(im.convert("RGB"), src, ImageCms.createProfile("sRGB"),
                                        renderingIntent=ImageCms.Intent.PERCEPTUAL, outputMode="RGB")
        if out is None:
            return im
        if alpha is not None:
            out.putalpha(alpha)
        return out
    except Exception:  # noqa: BLE001 — a profile LittleCMS can't use: the picture as it came
        return im


def standard(im, path: str):
    """The thumbnail-sized picture `im` of the photo at `path`, as a standard screen should show it."""
    curve = curve_of(path, im.info.get("icc_profile"))
    if curve is not None:
        try:
            return tone_mapped(im, *curve)
        except Exception:  # noqa: BLE001 — no numpy, an odd mode: better the flat tile than none
            return im
    return from_profile(im)
