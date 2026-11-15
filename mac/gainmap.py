"""HDR gain maps, kept through an edit — so an iPhone photo is still HDR after Photo Browser for Mac rewrites it.

An iPhone photo is two pictures in one file: the ordinary one every screen can show, and a small grey **gain
map** saying how much brighter each part should be on an HDR screen (with a "headroom" number in the
metadata). Pillow reads and writes only the first, so until now every edit here — the photo editor, Crop,
Rotate, Erase Area, Remove Objects, Remove Watermark, AI Upscale — saved a standard-range photo.

macOS's own image library reads and writes the map, so that's what is used: `gainmap_helper.swift` (ImageIO,
built the first time like the other helpers). The Python side:

- `sniff(path)` — does this photo have a gain map? Read from the file's own boxes (HEIC) or markers (JPEG);
  no helper needed, so it's free to ask.
- `read(path)` → `GainMap`: the map as numbers, **turned upright** like `batch_crop.open_upright` turns the
  photo, so the same crop and turns can be done to both. Read in Python (pillow-heif reads an HEIC's; a JPEG's
  is the file's second picture) — the helper only when that fails.
- carried through an edit by whoever does the edit: `turned` / `cropped` here for Crop and Rotate,
  `photo_edit.gain_through` for the photo editor (its reshaping, turning, straightening, cropping and frames),
  `filled` where something was removed from the photo (so its glow doesn't stay behind on an HDR screen).
- `encode(src, im, gain)` — the edited picture and its map written as one photo of the original's kind (HEIC
  or JPEG) with the original's metadata, by the helper. `batch_crop.encode_like(…, gain=…)` calls it and
  falls back to the plain, standard-range save when it can't be done (not a Mac, no Command Line Tools, a
  kind of map the helper doesn't know) — a photo is never lost to this, it's only less bright.

What an edit can't keep: the map only says *how much brighter*; a filter that changes colours is seen through
it, as on the iPhone. Collages are standard range (their photos have different headrooms).

`PHOTO_BROWSER_GAINMAP_HELPER` names another program to use (tests). No Qt here.
"""
from __future__ import annotations

import json
import os
import subprocess
import tempfile
import threading
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

APPLE_URN = b"urn:com:apple:photo:2020:aux:hdrgainmap"
HEIF_EXT = {".heic", ".heif"}
JPEG_EXT = {".jpg", ".jpeg"}
IS_MAC = os.uname().sysname == "Darwin" if hasattr(os, "uname") else False
problem = ""                                  # why the helper isn't there, in a sentence
_lock = threading.Lock()
_helper: list[str] | None | bool = False


# ----------------------------------------------------------------------------- is there one?

def sniff(path: str) -> str:
    """"apple" (Apple's gain map), "iso" (an ISO 21496-1 one) or "" — read from the file itself, cheaply."""
    ext = os.path.splitext(path)[1].lower()
    try:
        if ext in HEIF_EXT:
            import thumb_color
            meta = thumb_color._meta_box(path) or b""
            if APPLE_URN in meta:
                return "apple"
            return "iso" if b"tmap" in meta else ""
        if ext in JPEG_EXT:
            with open(path, "rb") as f:
                head = f.read(1 << 18)
                if b"MPF\x00" not in head:                 # a gain map rides as a second picture (MPF)
                    return ""
                rest = f.read()
            both = head + rest
            if b"HDRGainMapVersion" in both or b"hdrgainmap" in both:
                return "apple"
            return "iso" if b"urn:iso:std:iso:ts:21496" in both else ""
    except OSError:
        pass
    return ""


# ----------------------------------------------------------------------------- the helper

def helper() -> list[str] | None:
    """The command that runs gainmap_helper, built the first time (or when its source is newer)."""
    global _helper, problem
    with _lock:
        if _helper is not False:
            return _helper  # type: ignore[return-value]
        _helper = None
        env = os.environ.get("PHOTO_BROWSER_GAINMAP_HELPER")
        if env:
            _helper = env.split("\x1f")
            return _helper
        src = Path(__file__).with_name("gainmap_helper.swift")
        if not IS_MAC or not src.is_file():
            problem = "HDR gain maps are kept on a Mac only"
            return None
        out = Path.home() / "Library" / "Caches" / "PhotoBrowser" / "gainmap_helper"
        log = out.with_name("gainmap_helper.log")
        if out.is_file() and out.stat().st_mtime >= src.stat().st_mtime:
            _helper = [str(out)]
            return _helper
        try:
            if subprocess.run(["xcode-select", "-p"], capture_output=True).returncode != 0:
                problem = "keeping HDR needs Xcode's Command Line Tools (xcode-select --install)"
                return None
            out.parent.mkdir(parents=True, exist_ok=True)
            r = subprocess.run(["xcrun", "swiftc", "-O", "-parse-as-library", "-swift-version", "5", "-o", str(out),
                                str(src)], capture_output=True, text=True, timeout=900)
        except (OSError, subprocess.SubprocessError) as e:
            problem = f"the HDR helper couldn't be built ({e})"
            return None
        if r.returncode == 0 and out.is_file():
            _helper = [str(out)]
            try:
                log.unlink()
            except OSError:
                pass
        else:
            problem = f"the HDR helper didn't build — see {log}"
            try:
                log.write_text(f"swiftc failed ({r.returncode}) building {src}\n\n{r.stderr or ''}{r.stdout or ''}")
            except OSError:
                pass
        return _helper  # type: ignore[return-value]


def available() -> bool:
    return helper() is not None


def can_keep(path: str) -> bool:
    """This photo has a gain map and this Mac can write one back."""
    return bool(sniff(path)) and available()


# ----------------------------------------------------------------------------- reading

@dataclass
class GainMap:
    data: np.ndarray                          # (h, w) uint8, upright
    kind: str = "apple"
    info: dict = field(default_factory=dict)  # what the helper said (for writing it back)

    def like(self, data: np.ndarray) -> "GainMap":
        return GainMap(np.ascontiguousarray(np.clip(np.rint(data), 0, 255).astype(np.uint8)), self.kind, self.info)


def upright(a: np.ndarray, orientation: int) -> np.ndarray:
    """An array stored in EXIF orientation `orientation`, turned the way it's meant to be seen."""
    o = int(orientation or 1)
    if o == 2:
        return a[:, ::-1]
    if o == 3:
        return a[::-1, ::-1]
    if o == 4:
        return a[::-1]
    if o == 5:
        return a.swapaxes(0, 1)
    if o == 6:
        return np.rot90(a, k=-1)
    if o == 7:
        return a.swapaxes(0, 1)[::-1, ::-1]
    if o == 8:
        return np.rot90(a, k=1)
    return a


def _read_heif(path: str) -> GainMap | None:
    """An HEIC's Apple gain map through pillow-heif — which hands it over upright, like the picture."""
    try:
        import pillow_heif
        hf = pillow_heif.open_heif(path)
        ids = (hf.info.get("aux") or {}).get(APPLE_URN.decode())
        if not ids:
            return None
        aux = hf.get_aux_image(ids[0])
        if aux.mode != "L":
            return None
        w, h = aux.size
        data = np.frombuffer(bytes(aux.data), dtype=np.uint8)
        stride = int(getattr(aux, "stride", w) or w)
        if data.size < stride * h or w < 2 or h < 2:
            return None
        main = hf.size
        if (w > h) != (main[0] > main[1]) and w != h:        # not the picture's way round: not one to trust
            return None
        return GainMap(np.ascontiguousarray(data[:stride * h].reshape(h, stride)[:, :w]), "apple", {"by": "pillow-heif"})
    except Exception:  # noqa: BLE001 — an older pillow-heif, a map it can't decode: the helper is asked instead
        return None


def _read_jpeg(path: str) -> GainMap | None:
    """A JPEG's gain map: the second picture in the file (MPF), stored the same way round as the first."""
    try:
        from PIL import Image
        with Image.open(path) as im:
            if getattr(im, "n_frames", 1) < 2:
                return None
            orientation = im.getexif().get(0x0112, 1)
            main = im.size
            im.seek(1)
            g = im.convert("L")
            if g.width < 2 or g.height < 2 or g.width > main[0] or abs(g.width / g.height - main[0] / main[1]) > 0.02:
                return None                                   # a second picture that isn't a map of the first
            stored = np.asarray(g, dtype=np.uint8)
        return GainMap(np.ascontiguousarray(upright(stored, int(orientation or 1))), "apple", {"by": "pillow"})
    except Exception:  # noqa: BLE001
        return None


def _read_helper(path: str) -> GainMap | None:
    cmd = helper()
    if not cmd:
        return None
    with tempfile.TemporaryDirectory(prefix="photo-browser-gain-") as td:
        raw = os.path.join(td, "gain.raw")
        try:
            r = subprocess.run([*cmd, "read", path, raw], capture_output=True, text=True, timeout=120)
            if r.returncode != 0:
                return None
            info = json.loads(r.stdout.strip().splitlines()[-1])
            w, h, row = int(info["width"]), int(info["height"]), int(info.get("bytesPerRow") or info["width"])
            if str(info.get("pixelFormat", "L008")) != "L008" or w < 2 or h < 2 or row < w:
                return None                                  # a map of a kind this doesn't carry (10-bit, colour)
            buf = np.fromfile(raw, dtype=np.uint8)
            if buf.size < row * h:
                return None
            stored = buf[:row * h].reshape(h, row)[:, :w]
        except (OSError, subprocess.SubprocessError, ValueError, KeyError, IndexError):
            return None
    return GainMap(np.ascontiguousarray(upright(stored, int(info.get("orientation") or 1))), str(info.get("type") or "apple"), info)


def read(path: str) -> GainMap | None:
    """The photo's gain map, upright — None when it has none or it can't be read here. Read in Python where
    that's possible (pillow-heif for HEIC, the file's second picture for JPEG); the helper otherwise."""
    if not sniff(path):
        return None
    ext = os.path.splitext(path)[1].lower()
    got = _read_heif(path) if ext in HEIF_EXT else _read_jpeg(path) if ext in JPEG_EXT else None
    return got if got is not None else _read_helper(path)


# ----------------------------------------------------------------------------- carried through an edit

def turned(g: np.ndarray, quarters: int) -> np.ndarray:
    """Quarter turns clockwise."""
    return np.rot90(g, k=-(quarters % 4)) if quarters % 4 else g


def cropped(g: np.ndarray, rect: tuple[float, float, float, float]) -> np.ndarray:
    """The part of the map under a crop given as fractions (x, y, w, h) of the photo."""
    h, w = g.shape[:2]
    x, y, rw, rh = rect
    x0, y0 = int(round(x * w)), int(round(y * h))
    x1, y1 = max(x0 + 1, int(round((x + rw) * w))), max(y0 + 1, int(round((y + rh) * h)))
    return g[max(0, y0):min(h, y1), max(0, x0):min(w, x1)]


def resized(g: np.ndarray, w: int, h: int) -> np.ndarray:
    from PIL import Image
    if g.shape[1] == w and g.shape[0] == h:
        return g
    return np.asarray(Image.fromarray(np.ascontiguousarray(g).astype(np.uint8), "L").resize((max(1, w), max(1, h)),
                                                                                           Image.Resampling.BICUBIC))


def filled(g: np.ndarray, hole: np.ndarray) -> np.ndarray:
    """The map with what's under `hole` (a mask of the same shape, True/1 where the photo was changed) replaced
    by what's around it — so a lamp taken out of the photo doesn't go on glowing where it was."""
    import photo_edit
    hole = np.asarray(hole, dtype=np.float32)
    if hole.shape != g.shape or not hole.any():
        return g
    keep = (np.clip(hole, 0.0, 1.0) < 0.5).astype(np.float32)
    gf = g.astype(np.float32)
    out = gf.copy()
    done = keep > 0.5
    sigma = 2.0
    while not done.all() and sigma < 4.0 * max(g.shape):          # from the hole's rim inwards, wider each time
        weight = photo_edit.gauss(keep, sigma)
        around = photo_edit.gauss(gf * keep, sigma) / np.maximum(weight, 1e-4)
        take = ~done & (weight > 0.08)
        out[take] = around[take]
        done |= take
        sigma *= 2.0
    if not done.all():                                            # nothing left around it at all
        out[~done] = float((gf * keep).sum() / max(float(keep.sum()), 1.0))
    soft = photo_edit.gauss(1.0 - keep, 1.5)
    smooth = photo_edit.gauss(out, 3.0)
    return (out * (1.0 - soft) + smooth * soft).astype(np.float32)


def changed_mask(before, after, shape: tuple[int, int]) -> np.ndarray:
    """Where two same-sized pictures differ a lot (something was removed or painted over), at a map's size."""
    from PIL import Image, ImageChops, ImageFilter
    if before.size != after.size:
        return np.zeros(shape, dtype=np.float32)
    diff = ImageChops.difference(before.convert("RGB"), after.convert("RGB")).convert("L")
    small = diff.resize((shape[1], shape[0]), Image.Resampling.BOX).filter(ImageFilter.MaxFilter(3))
    return (np.asarray(small, dtype=np.float32) > 14.0).astype(np.float32)


# ----------------------------------------------------------------------------- writing

def encode(path: str, im, gain: GainMap, fmt: str, quality: float = 0.92) -> bytes | None:
    """`im` (a Pillow picture, upright) and its gain map as one photo of `fmt` ("HEIF" / "JPEG") with the
    metadata of the photo at `path` — or None when it can't be done (the caller saves it the plain way).
    The map is written at half the picture's size, as the iPhone writes it."""
    cmd = helper()
    if not cmd or fmt not in ("HEIF", "JPEG") or im.mode not in ("RGB", "L"):
        return None
    from PIL import Image
    w, h = im.size
    g = resized(gain.data, max(1, (w + 1) // 2), max(1, (h + 1) // 2))
    with tempfile.TemporaryDirectory(prefix="photo-browser-gain-") as td:
        pixels, raw = os.path.join(td, "pixels.tiff"), os.path.join(td, "gain.raw")
        out = os.path.join(td, "out.heic" if fmt == "HEIF" else "out.jpg")
        try:
            extra = {"icc_profile": im.info["icc_profile"]} if im.info.get("icc_profile") else {}
            im.save(pixels, format="TIFF", **extra)
            np.ascontiguousarray(g, dtype=np.uint8).tofile(raw)
            r = subprocess.run([*cmd, "write", path, pixels, raw, str(g.shape[1]), str(g.shape[0]), out, f"{quality:.2f}"],
                               capture_output=True, text=True, timeout=600)
            if r.returncode != 0 or not os.path.isfile(out) or os.path.getsize(out) < 256:
                return None
            with open(out, "rb") as f:
                data = f.read()
            with Image.open(out) as check:                   # what was written opens, at its size
                check.load()
                if check.size != (w, h):
                    return None
        except Exception:  # noqa: BLE001 — any trouble: the plain save instead
            return None
    return data
