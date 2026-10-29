"""Batch crop for Safe Finder — the Mac twin of the iPhone app's Crop screen (PhotoBrowser/BatchCrop.swift).

One crop, drawn on a photo, goes on every selected photo: the same quarter turn, then the same rectangle
as fractions of the photo, so it lands on the same spot of photos of another size. A fixed-ratio crop
(1:1, 4:5…) also keeps its own shape on photos shaped differently from the one it was drawn on —
`CropSpec.rect_for` is the same arithmetic as `CropSpec.rect(forWidth:height:)` in Swift, and the box
geometry (`resized`, `side_moved`, `moved`) is the iPhone crop box's. Every photo that comes out cropped
gets the "cropped" tag (the window adds it through the shared tag store).

Each photo is rewritten in place with Pillow (pillow-heif for HEIC): turned upright (its EXIF orientation
baked in and set back to 1), turned and cropped, and saved in its own format with its EXIF (pixel
dimensions updated), ICC profile and XMP. The new bytes are made and decoded again in memory first, so a
photo that can't be read or encoded is left exactly as it was. Then, on APFS/HFS, they go to a hidden
temp file beside it that gets the original's extended attributes (its Photo Browser tags, "where from"…)
and is renamed over it; on exFAT they're written into the original file in place — the Mac tools never
rename on exFAT (CLAUDE.md #12). Its modified and created dates are put back, as the iPhone app does, so
it keeps its place by date.

What Pillow can't carry: an HDR gain map (an HDR HEIC or JPEG comes out standard range here — the iPhone
app keeps HDR) and a JPEG's extra pictures (MPF). GIFs (they'd lose their animation) and RAW files (no
RAW writer) are left out. No Qt here (crop_window.py is the window), so it's testable on its own.
"""
from __future__ import annotations

import io
import json
import math
import os
import re
import stat
import uuid
from dataclasses import asdict, dataclass

import shared_tags
import spare_folders

try:
    from PIL import Image, ImageOps, JpegImagePlugin, PngImagePlugin
    try:
        import pillow_heif  # type: ignore
        pillow_heif.register_heif_opener()
        HEIF_OK = True
    except Exception:  # noqa: BLE001 - optional
        HEIF_OK = False
    PIL_OK = True
except Exception:  # noqa: BLE001 - optional
    PIL_OK = HEIF_OK = False

CROPPED_TAG = "cropped"
FULL = (0.0, 0.0, 1.0, 1.0)
EDGE = 0.004                    # a side trimmed by less than this is untouched (rounding, not a crop)
MIN_SIDE = 0.08                 # the smallest box side, as a fraction of the photo (as on the iPhone)
CROPPABLE = {".jpg", ".jpeg", ".png", ".heic", ".heif", ".tif", ".tiff", ".webp", ".bmp"}
HEIF_EXT = {".heic", ".heif"}
ASPECTS = [("Freeform", None), ("Original", None), ("1:1", 1.0), ("4:5", 4 / 5), ("3:2", 3 / 2),
           ("16:9", 16 / 9)]      # the iPhone's EditAspect chips, in order; the number is width / height
_ORIENTATION, _EXIF_IFD, _PIXEL_X, _PIXEL_Y = 0x0112, 0x8769, 0xA002, 0xA003
_SKIP_XATTRS = {"com.apple.quarantine"}
_TIFF_KEPT = (270, 271, 272, 305, 306, 315, 33432)   # description, make, model, software, date, artist, copyright

Rect = tuple[float, float, float, float]          # x, y, w, h — normalized, top-left origin


class CropError(Exception):
    """Why a photo wasn't cropped (it is left as it was)."""


# ---------------------------------------------------------------------------- the crop

def is_trim(r: Rect) -> bool:
    x, y, w, h = r
    return not (x <= EDGE and y <= EDGE and x + w >= 1 - EDGE and y + h >= 1 - EDGE)


def clamp(r: Rect) -> Rect:
    """`r` inside the photo (the unit square); the whole photo when nothing of it is left."""
    x0, y0 = max(r[0], 0.0), max(r[1], 0.0)
    x1, y1 = min(r[0] + r[2], 1.0), min(r[1] + r[3], 1.0)
    return (x0, y0, x1 - x0, y1 - y0) if x1 > x0 and y1 > y0 else FULL


def turned(r: Rect, step: int) -> Rect:
    """`r` turned with its photo: a quarter clockwise (`step` 1) or counter-clockwise (−1)."""
    x, y, w, h = r
    return (1 - (y + h), x, h, w) if step > 0 else (y, 1 - (x + w), h, w)


@dataclass
class CropSpec:
    quarters: int = 0               # clockwise quarter turns, done before the crop
    rect: Rect = FULL               # within the turned photo
    ref_w: float = 1.0              # the photo it was drawn on, after the turn — only its shape matters
    ref_h: float = 1.0
    keeps_shape: bool = False       # a fixed ratio was chosen: keep the crop's own ratio on other shapes
    source: str | None = None       # that photo's name, for the "Last Crop" label

    @property
    def trims(self) -> bool:
        return is_trim(self.rect)

    @property
    def changes(self) -> bool:
        return self.trims or self.quarters % 4 != 0

    def rect_for(self, w: float, h: float) -> Rect:
        """The crop for a photo of w×h (after the turn): the same fractions of each side — or, when
        `keeps_shape` and the photo isn't shaped like the reference, a rect of the crop's own pixel
        ratio, centered on the same spot, as tall (or as wide) as the fractions allow, kept inside."""
        r = clamp(self.rect)
        if not (self.keeps_shape and w > 0 and h > 0 and self.ref_w > 0 and self.ref_h > 0):
            return r
        ref = self.ref_w / self.ref_h
        if abs(w / h - ref) / ref < 0.01:
            return r
        rx, ry, rw, rh = r
        want = (rw * self.ref_w) / (rh * self.ref_h)          # the crop's pixel w/h
        pw, ph = rw * w, rh * h
        if pw / ph > want:
            pw = ph * want
        else:
            ph = pw / want
        if pw > w:
            pw, ph = w, w / want
        if ph > h:
            ph, pw = h, h * want
        x = min(max((rx + rw / 2) * w - pw / 2, 0), w - pw)
        y = min(max((ry + rh / 2) * h - ph / 2, 0), h - ph)
        return (x / w, y / h, pw / w, ph / h)

    def to_json(self) -> str:
        return json.dumps(asdict(self))

    @classmethod
    def from_json(cls, text: str | None) -> "CropSpec | None":
        try:
            d = json.loads(text or "")
            r = tuple(float(v) for v in d["rect"])
            if len(r) != 4:
                return None
            return cls(int(d.get("quarters", 0)), r, float(d.get("ref_w", 1)), float(d.get("ref_h", 1)),
                       bool(d.get("keeps_shape", False)), d.get("source"))
        except (ValueError, TypeError, KeyError):
            return None


def pixel_box(r: Rect, w: int, h: int) -> tuple[int, int, int, int]:
    """The crop in pixels (left, top, right, bottom) — rounded outward like CGRect.integral, inside the photo."""
    x, y, rw, rh = r
    left, top = max(0, math.floor(x * w + 1e-9)), max(0, math.floor(y * h + 1e-9))
    right, bottom = min(w, math.ceil((x + rw) * w - 1e-9)), min(h, math.ceil((y + rh) * h - 1e-9))
    return left, top, max(right, left + 1), max(bottom, top + 1)


def box_constraint(aspect: str, ratio: float | None, w: float, h: float) -> float | None:
    """The normalized w/h the box keeps on a w×h photo: None for Freeform, 1 (the photo's own ratio)
    for Original, else the chosen pixel ratio over the photo's."""
    if aspect == "Freeform" or w <= 0 or h <= 0:
        return None
    if aspect == "Original" or ratio is None:
        return 1.0
    return ratio / (w / h)


def centered_box(ratio: float, w: float, h: float) -> Rect:
    """The largest centered box of pixel ratio `ratio` on a w×h photo."""
    nr = ratio / (w / h)
    return (0.0, (1 - 1 / nr) / 2, 1.0, 1 / nr) if nr >= 1 else ((1 - nr) / 2, 0.0, nr, 1.0)


# ---------------------------------------------------------------------------- the box, dragged

def moved(s: Rect, dx: float, dy: float) -> Rect:
    x, y, w, h = s
    return (min(max(x + dx, 0), 1 - w), min(max(y + dy, 0), 1 - h), w, h)


def side_moved(side: str, s: Rect, dx: float, dy: float) -> Rect:
    """One side of a free box moved ("top", "bottom", "left", "right"); the opposite side stays."""
    x, y, w, h = s
    if side == "top":
        ny = min(max(y + dy, 0), y + h - MIN_SIDE)
        return (x, ny, w, y + h - ny)
    if side == "bottom":
        nb = max(min(y + h + dy, 1), y + MIN_SIDE)
        return (x, y, w, nb - y)
    if side == "left":
        nx = min(max(x + dx, 0), x + w - MIN_SIDE)
        return (nx, y, x + w - nx, h)
    nr = max(min(x + w + dx, 1), x + MIN_SIDE)
    return (x, y, nr - x, h)


def resized(corner: str, s: Rect, dx: float, dy: float, ratio: float | None) -> Rect:
    """`corner` ("tl", "tr", "bl", "br") moved while the opposite one stays; keeps the normalized
    `ratio` when set. The iPhone crop box's `resized(corner:start:dx:dy:)`."""
    x, y, w, h = s
    fx, fy, sx, sy, mx0, my0 = {
        "tl": (x + w, y + h, -1, -1, x, y), "tr": (x, y + h, 1, -1, x + w, y),
        "bl": (x + w, y, -1, 1, x, y + h), "br": (x, y, 1, 1, x + w, y + h)}[corner]
    mx, my = min(max(mx0 + dx, 0), 1), min(max(my0 + dy, 0), 1)
    room_x = 1 - fx if sx > 0 else fx
    room_y = 1 - fy if sy > 0 else fy
    nw = min(max(abs(mx - fx), MIN_SIDE), room_x)
    nh = min(max(abs(my - fy), MIN_SIDE), room_y)
    if ratio:
        if nw / nh > ratio:
            nw = nh * ratio
        else:
            nh = nw / ratio
        if nw > room_x:
            nw, nh = room_x, room_x / ratio
        if nh > room_y:
            nh, nw = room_y, room_y * ratio
        nw, nh = max(nw, MIN_SIDE), max(nh, MIN_SIDE)
    nmx, nmy = fx + sx * nw, fy + sy * nh
    return (min(fx, nmx), min(fy, nmy), nw, nh)


# ---------------------------------------------------------------------------- the photos

def can_crop(path: str) -> bool:
    ext = os.path.splitext(path)[1].lower()
    return PIL_OK and ext in CROPPABLE and (ext not in HEIF_EXT or HEIF_OK) and os.path.isfile(path)


def upright_size(path: str) -> tuple[int, int]:
    """The photo's pixel size as it displays (EXIF orientation applied). Raises CropError."""
    try:
        with Image.open(path) as im:
            w, h = im.size
            o = im.getexif().get(_ORIENTATION, 1)
    except Exception as e:  # noqa: BLE001 - any decoder error
        raise CropError(f"can't read it ({e})") from e
    return (h, w) if o in (5, 6, 7, 8) else (w, h)


_TURNS = {1: "ROTATE_270", 2: "ROTATE_180", 3: "ROTATE_90"}    # PIL's ROTATE_n is counter-clockwise


def render(spec: CropSpec, path: str) -> bytes:
    """The cropped photo, encoded like the original, checked by decoding it again. Raises CropError."""
    try:
        src = Image.open(path)
        src.load()
    except Exception as e:  # noqa: BLE001
        raise CropError(f"can't read it ({e})") from e
    fmt = src.format
    if not fmt:
        raise CropError("unknown image format")
    info = dict(src.info)
    exif = src.getexif()
    sampling = JpegImagePlugin.get_sampling(src) if fmt == "JPEG" else -1
    text = {k: v for k, v in info.items() if isinstance(v, str)} if fmt == "PNG" else {}

    im = ImageOps.exif_transpose(src) or src
    q = spec.quarters % 4
    if q:
        im = im.transpose(getattr(Image.Transpose, _TURNS[q]))
    w, h = im.size
    box = pixel_box(spec.rect_for(w, h), w, h)
    if box != (0, 0, w, h):
        im = im.crop(box)
    w, h = im.size

    if _ORIENTATION in exif:
        exif[_ORIENTATION] = 1
    sub = exif.get_ifd(_EXIF_IFD)
    if _PIXEL_X in sub:
        sub[_PIXEL_X] = w
    if _PIXEL_Y in sub:
        sub[_PIXEL_Y] = h
    params: dict = {}
    if fmt == "TIFF":                              # its metadata is its own tag directory: the descriptive tags
        tags = getattr(src, "tag_v2", {})
        params["tiffinfo"] = {t: tags[t] for t in _TIFF_KEPT if t in tags}
    elif len(exif):
        params["exif"] = exif.tobytes()
    if info.get("icc_profile"):
        params["icc_profile"] = info["icc_profile"]
    xmp = info.get("xmp") or info.get("XML:com.adobe.xmp")
    if isinstance(xmp, str):
        xmp = xmp.encode("utf-8")
    if xmp and fmt in ("JPEG", "WEBP", "HEIF"):
        params["xmp"] = _fixed_xmp(xmp, w, h)

    if fmt == "JPEG":
        if im.mode not in ("RGB", "L", "CMYK"):
            im = im.convert("RGB")
        params.update(quality=95, subsampling=sampling if sampling >= 0 else 0,
                      progressive=bool(info.get("progressive")))
        if info.get("dpi"):
            params["dpi"] = info["dpi"]
    elif fmt == "HEIF":
        params["quality"] = 92
    elif fmt == "WEBP":
        params.update(quality=95, method=4)
    elif fmt == "PNG":
        if text:
            meta = PngImagePlugin.PngInfo()
            for k, v in text.items():
                if k != "XML:com.adobe.xmp":
                    meta.add_text(k, v)
            if xmp:
                meta.add_itxt("XML:com.adobe.xmp", _fixed_xmp(xmp, w, h).decode("utf-8", "replace"))
            params["pnginfo"] = meta
        if info.get("dpi"):
            params["dpi"] = info["dpi"]
    elif fmt == "TIFF":
        if info.get("compression") and info["compression"] != "raw":
            params["compression"] = info["compression"]
        if info.get("dpi"):
            params["dpi"] = info["dpi"]

    out = io.BytesIO()
    try:
        im.save(out, format=fmt, **params)
    except Exception:  # noqa: BLE001 — a format option this Pillow doesn't take: once more, plainer
        out = io.BytesIO()
        plain = {k: v for k, v in params.items() if k in ("exif", "icc_profile", "quality", "tiffinfo")}
        try:
            im.save(out, format=fmt, **plain)
        except Exception as e:  # noqa: BLE001
            raise CropError(f"can't save it as {fmt} ({e})") from e
    data = out.getvalue()
    try:
        with Image.open(io.BytesIO(data)) as check:
            check.load()
            if check.size != (w, h):
                raise CropError("the saved photo came out the wrong size")
    except CropError:
        raise
    except Exception as e:  # noqa: BLE001
        raise CropError(f"the saved photo doesn't open ({e})") from e
    return data


def _fixed_xmp(xmp: bytes, w: int, h: int) -> bytes:
    """XMP that agrees with the new pixels: orientation 1, the new pixel size."""
    def put(names: str, value: int, data: bytes) -> bytes:
        data = re.sub(rb"((?:" + names.encode() + rb')\s*=\s*")\d+(")', rb"\g<1>" + str(value).encode() + rb"\2", data)
        return re.sub(rb"(<(" + names.encode() + rb")>)\s*\d+\s*(</\2>)", rb"\g<1>" + str(value).encode() + rb"\3", data)
    xmp = put("tiff:Orientation", 1, xmp)
    xmp = put("exif:PixelXDimension|tiff:ImageWidth", w, xmp)
    return put("exif:PixelYDimension|tiff:ImageLength", h, xmp)


def write_in_place(path: str, data: bytes) -> None:
    """Puts `data` in place of the photo's bytes, keeping its name, extended attributes and dates."""
    st = os.stat(path)
    if spare_folders.on_exfat(path):
        with open(path, "r+b") as f:              # in place: no temp file, no rename on exFAT
            f.write(data)
            f.truncate()
            f.flush()
    else:
        folder, name = os.path.split(path)
        tmp = os.path.join(folder, f".{name}.crop-{uuid.uuid4().hex[:8]}")
        try:
            with open(tmp, "wb") as f:
                f.write(data)
                f.flush()
                os.fsync(f.fileno())
            copy_xattrs(path, tmp)
            os.chmod(tmp, stat.S_IMODE(st.st_mode))
            os.replace(tmp, path)
        except BaseException:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise
    restore_dates(path, st)


def copy_xattrs(src: str, dst: str) -> None:
    for name in shared_tags.xattr_names(src):
        if name in _SKIP_XATTRS:
            continue
        value = shared_tags.xattr_get(src, name)
        if value is not None:
            try:
                shared_tags.xattr_set(dst, name, value)
            except OSError:
                pass                                       # best effort, like the tags themselves


def restore_dates(path: str, st: os.stat_result) -> None:
    """The modified date back, and the created date: setting a modified date earlier than the created
    one pulls the created date back with it (macOS), so the created date goes first."""
    try:
        birth = getattr(st, "st_birthtime", None)
        if birth is not None and birth < st.st_mtime:
            os.utime(path, (st.st_atime, birth))
        os.utime(path, ns=(st.st_atime_ns, st.st_mtime_ns))
    except OSError:
        pass


def apply(spec: CropSpec, path: str) -> None:
    """Turns and crops one photo in place. Raises CropError (or OSError) and leaves it as it was when the
    new photo can't be made; an OSError from the write itself is passed on."""
    write_in_place(path, render(spec, path))
