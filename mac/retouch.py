"""Erase part of a photo — a watermark, a date stamp, a blemish — by filling it in from what's around it,
for Safe Finder's Erase window (erase_window.py). No Qt here, so it's testable on its own.

What goes: the boxes drawn on the photo (as fractions of it, so one set of boxes fits every selected photo,
as a crop does). In each box either all of it is replaced ("whole box"), or — the default — just the mark
in it: the pixels that stand out from the background around them. The background is a median taken at a
coarser scale (a window several times a watermark's stroke width — a median keeps the photo's own broad
shapes and drops thin strokes), and only the dominant direction counts: a white watermark is lighter than
what's under it, while one of the photo's own edges strays both ways, so most of it is left alone.
`sensitivity` sets how faint a stroke still counts; the mark is grown a couple of pixels to take its soft
edges.

A see-through mark is taken back out rather than filled over: a watermark of one colour at one opacity
(white or black text, a grey logo) turned each pixel under its strokes into (1 − α)·photo + α·colour, so
with α — the median of what the stroke centres say, against the background around them — the photo comes
back: (pixel − α·colour) / (1 − α), its own detail and all. That's kept only where it checks out (α
plausible, the result like its surroundings); the strokes' soft edges, an opaque or coloured mark, and
whole boxes are filled instead.

How it's filled: a membrane fill — each erased pixel the average of its neighbours, solved coarse to fine
(the coarser level's answer is where the finer one starts, then a few dozen relaxation passes) — which meets
the surroundings without a seam. A smooth fill looks plastic in a photo with grain, so the photo's own grain
is laid over it: its fine detail from just beside the area (above or below, else to a side), clipped so no
real edge comes along. The work is done on the area around the boxes only, not the whole photo.

Saving is the crop's (batch_crop): the format, metadata, tags and dates kept — in place, or as a new photo
beside it, "name (retouched).ext".
"""
from __future__ import annotations

import json
from dataclasses import asdict, dataclass

import numpy as np
from PIL import Image, ImageFilter

import batch_crop

ERASED_TAG = "retouched"
NEW_LABEL = "retouched"
Box = tuple[float, float, float, float]          # x, y, w, h — fractions of the upright photo


class NothingToErase(batch_crop.CropError):
    """The boxes held no mark to erase (just-the-mark found nothing)."""


@dataclass(frozen=True)
class EraseSpec:
    boxes: tuple[Box, ...]
    only_mark: bool = True                       # just what stands out in each box, else all of it
    sensitivity: float = 0.35                    # 0–1: how faint a stroke still counts

    def to_json(self) -> str:
        return json.dumps(asdict(self))

    @staticmethod
    def from_json(text: str) -> "EraseSpec | None":
        try:
            d = json.loads(text)
            boxes = tuple(tuple(float(v) for v in b) for b in d["boxes"] if len(b) == 4)
            return EraseSpec(boxes, bool(d.get("only_mark", True)), float(d.get("sensitivity", 0.35)))
        except (ValueError, TypeError, KeyError):
            return None


def pixel_boxes(boxes, w: int, h: int) -> list[tuple[int, int, int, int]]:
    """The boxes in pixels of a w×h photo, (x0, y0, x1, y1), clamped; empty ones left out."""
    out = []
    for x, y, bw, bh in boxes:
        x0, y0 = max(0, int(x * w)), max(0, int(y * h))
        x1, y1 = min(w, int(round((x + bw) * w))), min(h, int(round((y + bh) * h)))
        if x1 > x0 and y1 > y0:
            out.append((x0, y0, x1, y1))
    return out


def _grow(mask: np.ndarray, r: int) -> np.ndarray:
    """The mask grown by r pixels (a square neighbourhood)."""
    if r <= 0 or not mask.any():
        return mask
    out = mask.copy()
    h, w = mask.shape
    for dy in range(-r, r + 1):
        for dx in range(-r, r + 1):
            if dy == 0 and dx == 0:
                continue
            ys, yd = (slice(0, h - dy), slice(dy, h)) if dy >= 0 else (slice(-dy, h), slice(0, h + dy))
            xs, xd = (slice(0, w - dx), slice(dx, w)) if dx >= 0 else (slice(-dx, w), slice(0, w + dx))
            out[yd, xd] |= mask[ys, xs]
    return out


Mark = tuple[int, int, np.ndarray, float]       # y, x of a box, its stroke centres there, lighter (1) / darker (-1)


def mark_mask(im: "Image.Image", spec: EraseSpec) -> np.ndarray:
    """What goes, as a boolean mask the size of `im`."""
    return _find(im, spec)[0]


def _scale(side: int) -> int:
    return max(2, side // 300)                  # the background is judged this much coarser


def _find(im: "Image.Image", spec: EraseSpec) -> tuple[np.ndarray, list[Mark]]:
    """What goes, and for each box the mark's stroke centres (where it can be taken back out)."""
    w, h = im.size
    mask = np.zeros((h, w), dtype=bool)
    marks: list[Mark] = []
    grey = im.convert("L")
    side = min(w, h)
    scale = _scale(side)
    window = 9                                                  # over 9 coarse pixels: ~36 px on a 1200 px photo
    threshold = 40 - 32 * max(0.0, min(1.0, spec.sensitivity))  # luminance levels off the background
    grow = max(2, side // 400)
    for x0, y0, x1, y1 in pixel_boxes(spec.boxes, w, h):
        if not spec.only_mark:
            mask[y0:y1, x0:x1] = True
            continue
        pad = scale * window                                    # the median sees past the box's edge
        cx0, cy0, cx1, cy1 = max(0, x0 - pad), max(0, y0 - pad), min(w, x1 + pad), min(h, y1 + pad)
        crop = grey.crop((cx0, cy0, cx1, cy1))
        small = crop.resize((max(1, crop.width // scale), max(1, crop.height // scale)), Image.Resampling.BOX)
        bg = small.filter(ImageFilter.MedianFilter(window)).resize(crop.size, Image.Resampling.BILINEAR)
        lum = np.asarray(crop, dtype=np.float32)
        off = lum - np.asarray(bg, dtype=np.float32)
        inside = (slice(y0 - cy0, y1 - cy0), slice(x0 - cx0, x1 - cx0))
        lighter, darker = off > threshold, off < -threshold
        sign = 1.0 if (off[inside] * lighter[inside]).sum() >= -(off[inside] * darker[inside]).sum() else -1.0
        found = lighter if sign > 0 else darker
        for _ in range(4):                       # dense text fools a median: the background again, from what
            if not found.any():                  # isn't the mark, filled across it — until the mark stops growing
                break
            bg2 = _box_blur(_membrane(lum[..., None], _grow(found, grow)), max(3, scale * 2))[..., 0]
            more = found | (sign * (lum - bg2) > threshold)
            if more.sum() == found.sum():
                break
            found = more
        mask[y0:y1, x0:x1] |= _grow(found, grow)[inside]
        centres = (found & ~_grow(~found, 1))[inside]           # not the soft edges, which are only partly mark
        marks.append((y0, x0, centres, sign))
    return mask, marks


def _relax(a: np.ndarray, hole: np.ndarray, passes: int) -> None:
    """Each hole pixel becomes the average of its four neighbours, `passes` times, in place."""
    ys, xs = np.nonzero(hole)
    if not len(ys):
        return
    y0, y1 = max(ys.min() - 1, 0), min(ys.max() + 2, hole.shape[0])
    x0, x1 = max(xs.min() - 1, 0), min(xs.max() + 2, hole.shape[1])
    sub, m = a[y0:y1, x0:x1], hole[y0:y1, x0:x1]
    for _ in range(passes):
        p = np.pad(sub, ((1, 1), (1, 1), (0, 0)), mode="edge")
        avg = (p[:-2, 1:-1] + p[2:, 1:-1] + p[1:-1, :-2] + p[1:-1, 2:]) * 0.25
        sub[m] = avg[m]


def _membrane(a: np.ndarray, hole: np.ndarray) -> np.ndarray:
    """`a` (h, w, channels, float32) with its `hole` filled smoothly from around it, coarse to fine."""
    h, w = hole.shape
    out = a.copy()
    if not hole.any():
        return out
    known = ~hole
    if min(h, w) <= 8 or not known.any():
        out[hole] = a[known].mean(axis=0) if known.any() else 0.0
        _relax(out, hole, 60)
        return out
    ph, pw = h + h % 2, w + w % 2                               # 2×2 averages of the known pixels
    k = np.pad(known.astype(np.float32), ((0, ph - h), (0, pw - w)))[..., None]
    v = np.pad(a, ((0, ph - h), (0, pw - w), (0, 0)), mode="edge") * k
    s = v[0::2, 0::2] + v[1::2, 0::2] + v[0::2, 1::2] + v[1::2, 1::2]
    c = k[0::2, 0::2] + k[1::2, 0::2] + k[0::2, 1::2] + k[1::2, 1::2]
    small = s / np.maximum(c, 1e-6)
    coarse = _membrane(small, c[..., 0] == 0)
    up = np.repeat(np.repeat(coarse, 2, axis=0), 2, axis=1)[:h, :w]
    out[hole] = up[hole]
    _relax(out, hole, 30)
    return out


def _box_blur(a: np.ndarray, r: int) -> np.ndarray:
    """A (2r+1)² box blur, by running sums."""
    p = np.pad(a, ((r + 1, r), (r + 1, r), (0, 0)), mode="edge").cumsum(0).cumsum(1)
    n = 2 * r + 1
    return (p[n:, n:] - p[:-n, n:] - p[n:, :-n] + p[:-n, :-n]) / (n * n)


def _grain(a: np.ndarray, hole: np.ndarray, rng: np.random.Generator) -> np.ndarray:
    """The photo's own grain for the hole: its fine detail from just beside the hole — above or below,
    else to a side, wherever that stays clear of it — clipped to the grain's strength, so no edge comes."""
    detail = a - _box_blur(_box_blur(a, 2), 2)
    ring = _grow(hole, 6) & ~hole
    if not ring.any():
        return np.zeros_like(a)
    d = detail[ring]
    spread = 1.4826 * np.median(np.abs(d - np.median(d, axis=0)), axis=0)       # robust: edges don't count
    ys, xs = np.nonzero(hole)
    hh, ww = ys.max() - ys.min() + 3, xs.max() - xs.min() + 3
    h, w = hole.shape
    out = np.zeros_like(a)
    for dy, dx in ((-hh, 0), (hh, 0), (0, -ww), (0, ww), (-hh, -ww), (hh, ww)):
        sy, sx = ys + dy, xs + dx
        if sy.min() >= 0 and sy.max() < h and sx.min() >= 0 and sx.max() < w and not hole[sy, sx].any():
            out[ys, xs] = detail[sy, sx]
            return np.clip(out, -2.5 * spread, 2.5 * spread)
    shared = rng.standard_normal(a.shape[:2] + (1,)).astype(np.float32)        # no clear room: like-strength noise
    return np.clip(_box_blur(shared, 0) * spread, -2.5 * spread, 2.5 * spread)


def _take_out(colour: np.ndarray, hole: np.ndarray, marks: list[Mark], origin: tuple[int, int],
              radius: int) -> np.ndarray:
    """Takes see-through marks back out of `colour` (in place) where that checks out; returns the pixels
    recovered that way, which then needn't be filled."""
    recovered = np.zeros_like(hole)
    if not marks:
        return recovered
    bg = _box_blur(_membrane(colour, hole), radius)            # the background around the strokes, without them
    for y, x, centres, sign in marks:
        y, x = y - origin[0], x - origin[1]
        cb = np.zeros_like(hole)
        cb[y:y + centres.shape[0], x:x + centres.shape[1]] = centres
        cb &= hole
        if cb.sum() < 50:
            continue
        ink = 255.0 if sign > 0 else 0.0
        px, b = colour[cb], bg[cb]
        room = ink - b
        ok = np.abs(room) > 25
        if ok.sum() < 50:
            continue
        alpha = float(np.median((px - b)[ok] / room[ok]))
        if not 0.06 < alpha < 0.85:
            continue                                            # opaque, or not one colour: filled instead
        back = (px - alpha * ink) / (1 - alpha)
        if np.abs(back - b).mean() < 0.75 * np.abs(px - b).mean():
            colour[cb] = np.clip(back, 0, 255)
            recovered |= cb
    return recovered


def fill(im: "Image.Image", mask: np.ndarray, seed: int = 7, marks: list[Mark] | None = None) -> "Image.Image":
    """`im` (RGB, RGBA or L) with the `mask` pixels filled in from around them — see-through `marks` taken
    back out first where they can be."""
    if not mask.any():
        return im.copy()
    a_full = np.asarray(im, dtype=np.float32)
    grey = a_full.ndim == 2
    if grey:
        a_full = a_full[..., None]
    ys, xs = np.nonzero(mask)
    side = max(ys.max() - ys.min(), xs.max() - xs.min()) + 1
    m = max(16, side // 2)                                      # the area around the marks is all that's worked on
    y0, y1 = max(0, ys.min() - m), min(mask.shape[0], ys.max() + m + 1)
    x0, x1 = max(0, xs.min() - m), min(mask.shape[1], xs.max() + m + 1)
    a, hole = a_full[y0:y1, x0:x1].copy(), mask[y0:y1, x0:x1]
    colour = a[..., :3] if a.shape[2] == 4 else a                # alpha is filled smooth, without grain
    radius = max(3, 2 * _scale(min(mask.shape)))
    gone = hole
    hole = hole & ~_take_out(colour, hole, marks or [], (y0, x0), radius)
    filled = _membrane(a, hole)
    noise = _grain(colour, hole, np.random.default_rng(seed))
    filled[..., :colour.shape[2]][hole] += noise[hole]
    out = a_full.copy()
    out[y0:y1, x0:x1][gone] = np.clip(filled[gone], 0, 255)
    arr = np.rint(out).astype(np.uint8)
    return Image.fromarray(arr[..., 0] if grey else arr, im.mode)


def erase_image(im: "Image.Image", spec: EraseSpec) -> tuple["Image.Image", np.ndarray]:
    """The photo with the spec's marks erased, and the mask of what went."""
    mask, marks = _find(im, spec)
    return fill(im, mask, marks=marks), mask


def can_erase(path: str) -> bool:
    return batch_crop.can_crop(path)


def erase(spec: EraseSpec, path: str, *, as_new: bool = False) -> str:
    """Erases the spec's marks from one photo — in place, or into a new photo beside it. Returns where it
    went. Raises NothingToErase, CropError or OSError, and leaves the photo as it was then."""
    src = batch_crop.open_upright(path)
    mode = src.image.mode
    alpha = mode in ("RGBA", "LA", "PA") or (mode == "P" and "transparency" in src.image.info)
    work = src.image.convert("L" if mode in ("L", "1", "I;16", "I") and not alpha else "RGBA" if alpha else "RGB")
    out, mask = erase_image(work, spec)
    if not mask.any():
        raise NothingToErase("no mark found in the boxes — draw them over it, or turn the sensitivity up")
    if mode == "LA":
        out = out.convert("LA")
    data = batch_crop.encode_like(src, out)
    if as_new:
        return batch_crop.write_beside(path, data, NEW_LABEL)
    batch_crop.write_in_place(path, data)
    return path
