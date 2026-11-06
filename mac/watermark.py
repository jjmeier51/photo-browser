"""Take one's own see-through watermark off photos in bulk, for Safe Finder's Remove Watermark window
(watermark_window.py). No Qt here, so it's testable on its own.

Made for art signed with a see-through mark, at different places, sizes and turns on every piece, often
repeated across it, and with words that change from piece to piece — "John Meier artwork", "John Meier's
Work", even "2025 n498rfhd" and "34987h34rtf98", sharing no word at all. Erase Area (retouch.py) erases
what stands out inside boxes; on art that also takes the stars, sparks and highlights under the boxes.
Here the mark itself is learned, every copy of it is found wherever it is, and each copy is *taken back
out* rather than painted over, so what was under it comes back.

**By its look** (`detect`, `by_look` — what lets one box do for a whole batch): what the person's marks share
isn't words but look — one ink, one see-through strength, one letter size and slant. A see-through mark
lightens what it covers towards its ink by its opacity, so (pixel − art)/(ink − art) reads as that opacity on
its strokes, the same in every colour channel for a white mark. Every pixel is read against a median
background; strokes reading as the kept marks' opacity are grouped into lines; a line counts only with the
mark's letter height, stroke width, slant, letters (four or more, letter-sized) and length (five letters'
height or more) and channels that agree. Lines in the art crossing the text are taken out first
(`_straight`); a tangle of copies joined by them is split into bands at the mark's angle (`_bands`); each
line gathers what lies along it (`_extend`) and is read per channel against a fill under it
(`_line_alpha`). One copy or many, any words. When a piece repeats its words three times or more, the
clearest line becomes a box for the template method below, which is more exact with many copies.

**From a box** (`from_box`) — and for the same words seen before (`auto`):
- *A first template*: one copy boxed by the person — what's lighter (or darker) than a coarse median
  background inside the box, specks such as stars and lines in the art dropped — or a mark already
  learned.
- *Finding copies* (`_coarse`, `refine_all`): normalized cross-correlation of the photo's fine detail with
  the template's over a grid of sizes and turns at a coarse scale — masked NCC (Padfield 2012), so a copy
  running off the edge still counts — then each hit refined at full scale by a pattern search over
  position, size and turn, and fitted (`_fit`). Copies on one piece were seen 12 % apart in size and 2°
  apart in turn, so nothing assumes a grid.
- *Learning it from the copies* (`_relearn`): each copy read as what the mark's opacity would have to be —
  (pixel − background) / (ink − background), the background a smooth fill under the strokes — mapped into
  the template's frame, and combined by a per-pixel median: the art is different under every copy and
  drops out, the mark is the same in all of them and stays. The frame is given room each round, so a
  template found by one word grows to the whole line of text that photo carries; then it's cropped to the
  block of strokes joined to where it started (a neighbouring copy caught in the frame goes).
- *Taking each copy out* (`matte`, `remove`): a one-colour mark at opacity α left (1 − α)·art + α·ink, so
  the art is (pixel − α·ink) / (1 − α). One template never fits every copy to the pixel (letters set a
  little differently at each size; one row of copies was a warmer white than the others), so each copy's
  opacity is read from the copy itself, per colour channel, and held near the template's — free by a pixel
  at the edges, close inside the strokes, so a star under a stroke isn't read as more mark. A hit whose
  strength reads low isn't the mark and is left alone, so a shape in the art is never "removed" into a
  dark ghost.

**Across photos** (`Library`): every mark learned from a box is kept in `~/Library/Application Support/Safe
Finder/Watermarks`, with its look (`style_of`). A new photo is tried against the last few kept marks (the
same words again: taken out as they are), then by the look of all of them; only a photo with a mark of a look
never seen needs a box.

What it can't do: a mark that isn't one colour (white text with a black shadow — the shadow stays), an
opaque mark (nothing under it to bring back — Remove Objects fills those), a copy over art as light as its
ink (white on white: nothing to read), and very short marks found by look (under four letters). A copy found
by look is read against a smooth fill under its strokes, which loses fine detail there that the template
method would keep. Saving is the crop's (batch_crop): format, metadata, tags and dates kept — in place, or
beside it as "name (no watermark).ext".
"""
from __future__ import annotations

import json
import math
import os
import time
import uuid
from dataclasses import dataclass, field, replace
from pathlib import Path
from typing import Callable

import numpy as np
from PIL import Image, ImageFilter

import batch_crop
import retouch

TAG = retouch.ERASED_TAG                    # "retouched", as Erase Area and Remove Objects
NEW_LABEL = "no watermark"
LIBRARY = Path.home() / "Library" / "Application Support" / "Safe Finder" / "Watermarks"
LIBRARY_MAX = 40                            # marks kept; the least recently used go first
LUMA = np.array([0.299, 0.587, 0.114], np.float32)
WORK_SIDE = 3000                            # bigger photos are searched at this size
COARSE_PX = 110                             # the template's long side when searching at a coarse scale…
COARSE_PHOTO = 560                          # …but the photo no longer than this there (a word is small)
REFINE_PX = 700                             # copies longer than this are refined on a smaller photo first
SCALE_STEP = 1.08                           # the size grid of the coarse search
ANGLE_STEP = 2.0                            # its turn grid, degrees
MIN_OVERLAP = 0.35                          # a copy may run off the edge, but this much must be inside
MAX_ALPHA = 0.92                            # past this, dividing by 1 − α only amplifies noise
MIN_GAIN = 0.45                             # a hit read weaker than this isn't the mark…
MIN_SCORE = 0.2                             # …nor one matching worse than this (or a quarter of the best)
SAME = 0.5                                  # a kept mark matching this well is the same words

Progress = Callable[[float, str], None]
Cancelled = Callable[[], bool]


class NoWatermark(batch_crop.CropError):
    """No copy of the watermark was found on the photo."""


class Stopped(Exception):
    """The work was cancelled."""


@dataclass
class Copy:
    """One copy of the mark on a photo: where the template's centre lands (pixels, continuous — a pixel's
    centre is +0.5), its size against the template, its turn (degrees, counter-clockwise on screen), how
    well it matched, and how it's taken out: its strength (overall and per colour channel), how much
    crisper or softer its edges are than the template's, and how far each word of it sits from where the
    template puts it (`bends`: photo pixels, one per part between the template's `cuts` — a copy set at
    another size isn't the template scaled: its word spacing differs, by 15 px on one piece)."""
    cx: float
    cy: float
    scale: float = 1.0
    angle: float = 0.0
    score: float = 0.0
    gain: float = 1.0
    gains: tuple[float, float, float] | None = None
    sharp: float = 0.0
    bends: tuple[tuple[float, float], ...] | None = None


@dataclass
class Watermark:
    alpha: np.ndarray                       # (h, w) opacity, 0–1, at size 1
    colour: np.ndarray                      # (3,) the ink, RGB 0–255
    side: int                               # the short side of the photo where size 1 was seen
    scales: tuple[float, float] = (1.0, 1.0)    # the sizes its copies were seen at
    angles: tuple[float, float] = (0.0, 0.0)    # their turns
    copies: int = 0                         # how many copies it was learned from
    focus: np.ndarray | None = None         # where it started in its frame (the boxed copy, the word)
    key: str = ""                           # its name in the library
    axis: tuple[float, float] = (1.0, 0.0)  # the line of text, in the template (unit vector)
    cuts: tuple[float, ...] = ()            # where its words (parts) meet, as positions along `axis`
    _cache: dict = field(default_factory=dict, repr=False, compare=False)

    @property
    def sign(self) -> float:
        """1 for a light mark (it brightens what it covers), −1 for a dark one."""
        return 1.0 if float(self.colour @ LUMA) >= 128 else -1.0

    def blurred(self, scale: float) -> np.ndarray:
        """The template, softened for drawing at a smaller size (so its strokes don't alias)."""
        r = int(round(0.5 / scale - 0.5)) if scale < 1 else 0
        if r <= 0:
            return self.alpha
        if ("blur", r) not in self._cache:
            self._cache[("blur", r)] = _blur(self.alpha, r)
        return self._cache[("blur", r)]

    def padded(self, m: int) -> "Watermark":
        """Room round the template (the frame grows evenly, so copies' centres don't move)."""
        return replace(self, alpha=np.pad(self.alpha, m), _cache={},
                       focus=None if self.focus is None else np.pad(self.focus, m))


@dataclass
class Line:
    """One line of watermark text found by its look (`detect`), words unknown: where it is on the photo,
    its opacity per colour channel there (y0, x0, alpha (h, w, 3)), its ink, and its shape."""
    y0: int
    x0: int
    alpha: np.ndarray
    colour: np.ndarray
    cx: float
    cy: float
    length: float
    height: float
    angle: float
    opacity: float


@dataclass
class Style:
    """How a learned mark looks, words aside — its ink, how see-through its solid strokes are, how thick its
    strokes and how tall its letters, and the line's angle — for finding marks whose words are new on every
    piece ("2025 n498rfhd", "34987h34rtf98")."""
    colour: np.ndarray
    opacity: float
    stroke: float                           # px, on a photo whose short side is `side`
    height: float                           # the band holding 80 % of the strokes, px
    angle: float                            # the line on screen, degrees, rising positive, in (−90, 90]
    side: int


@dataclass
class Result:
    """What was found on one photo, and how ("box" — learned from the person's box; "same" — a kept mark as
    it is; "grown" — learned from a kept mark or word; "style" — lines found by the look of the marks learned
    so far, `lines`, sometimes with a mark learned from them too). `wm` is None when only lines were found."""
    wm: Watermark | None
    copies: list[Copy]
    how: str
    lines: list[Line] = field(default_factory=list)
    styles: list[Style] = field(default_factory=list)


# -- small tools ---------------------------------------------------------------------------------------

def _blur(a: np.ndarray, r: int) -> np.ndarray:
    """A (2r+1)² box blur of a 2-D array, edges extended."""
    if r <= 0:
        return a
    return retouch._box_blur(a[..., None], r)[..., 0]


def _highpass(a: np.ndarray, r: int) -> np.ndarray:
    """Fine detail: the array less a smooth (twice box-blurred) version of itself."""
    return a - _blur(_blur(a, r), r)


def _fill(a: np.ndarray, hole: np.ndarray) -> np.ndarray:
    """`a` (h, w, channels) with its `hole` filled by the average of the known pixels nearby (a box twice as
    wide each pass until every hole pixel has enough) — a quick background under thin strokes; `matte`, whose
    fill shows in the result, uses the smoother membrane."""
    out = a.copy()
    todo = hole.copy()
    known = (~hole).astype(np.float32)[..., None]
    r = 2
    while todo.any() and r <= 128:
        num, den = retouch._box_blur(a * known, r), retouch._box_blur(known, r)
        ok = todo & (den[..., 0] > 0.15)
        out[ok] = num[ok] / den[ok]
        todo &= ~ok
        r *= 2
    if todo.any():
        out[todo] = a[~hole].mean(axis=0) if (~hole).any() else 0.0
    return out


def _extreme(a: np.ndarray, r: int, fn) -> np.ndarray:
    """The max (fn=np.maximum) or min (np.minimum) over each (2r+1)² neighbourhood, edges extended."""
    if r <= 0:
        return a
    h, w = a.shape
    p = np.pad(a, r, mode="edge")
    out = a.copy()
    for dy in range(-r, r + 1):
        for dx in range(-r, r + 1):
            out = fn(out, p[r + dy:r + dy + h, r + dx:r + dx + w])
    return out


def _grow_along(mask: np.ndarray, axis: tuple[float, float], along: int, across: int) -> np.ndarray:
    """The mask grown `along` pixels each way along a direction and `across` pixels round — joins words on
    one line of text without joining lines (or copies) above and below it."""
    h, w = mask.shape
    out = mask.copy()
    for (dy, dx) in {(int(round(t * axis[1])), int(round(t * axis[0]))) for t in range(-along, along + 1)}:
        if dy == 0 and dx == 0:
            continue
        ys, yd = (slice(0, h - dy), slice(dy, h)) if dy >= 0 else (slice(-dy, h), slice(0, h + dy))
        xs, xd = (slice(0, w - dx), slice(dx, w)) if dx >= 0 else (slice(-dx, w), slice(0, w + dx))
        out[yd, xd] |= mask[ys, xs]
    return retouch._grow(out, across)


def _resize(a: np.ndarray, h: int, w: int) -> np.ndarray:
    """A 2-D float array resized (box filter down, bilinear up)."""
    h, w = max(1, int(h)), max(1, int(w))
    if (h, w) == a.shape:
        return a
    method = Image.Resampling.BOX if h <= a.shape[0] else Image.Resampling.BILINEAR
    return np.asarray(Image.fromarray(a.astype(np.float32), "F").resize((w, h), method), dtype=np.float32)


def _good(n: int) -> int:
    """The next size ≥ n with only 2, 3 and 5 as factors (fast for the FFT)."""
    while True:
        m = n
        for p in (2, 3, 5):
            while m % p == 0:
                m //= p
        if m == 1:
            return n
        n += 1


def _components(mask: np.ndarray) -> tuple[np.ndarray, int]:
    """8-connected components of a boolean mask: labels (0 = background, 1…n) and n. Runs of each row are
    joined with the touching runs of the row above (union–find), so it's quick for any shape."""
    h, w = mask.shape
    parent: list[int] = [0]
    runs: list[tuple[int, int, int, int]] = []
    prev: list[tuple[int, int, int]] = []

    def root(i: int) -> int:
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    padded = np.zeros((h, w + 2), dtype=np.int8)
    padded[:, 1:-1] = mask
    edges = np.diff(padded, axis=1)
    for y in range(h):
        starts = np.flatnonzero(edges[y] == 1)
        ends = np.flatnonzero(edges[y] == -1)
        row: list[tuple[int, int, int]] = []
        k = 0
        for s, e in zip(starts.tolist(), ends.tolist()):
            label = 0
            while k < len(prev) and prev[k][1] < s:      # runs above ending before this one's reach
                k += 1
            j = k
            while j < len(prev) and prev[j][0] <= e:     # touching, diagonals included
                other = root(prev[j][2])
                if label == 0:
                    label = other
                elif other != label:
                    parent[max(other, label)] = min(other, label)
                    label = min(other, label)
                j += 1
            if label == 0:
                label = len(parent)
                parent.append(label)
            row.append((s, e, label))
            runs.append((y, s, e, label))
        prev = row
    out = np.zeros((h, w), dtype=np.int32)
    remap: dict[int, int] = {}
    for y, s, e, label in runs:
        out[y, s:e] = remap.setdefault(root(label), len(remap) + 1)
    return out, len(remap)


def _rot(angle: float) -> tuple[float, float]:
    t = math.radians(angle)
    return math.cos(t), math.sin(t)


def _bilinear(a: np.ndarray, x: np.ndarray, y: np.ndarray) -> np.ndarray:
    """`a` sampled at continuous pixel coordinates (a pixel's centre is +0.5); 0 outside."""
    h, w = a.shape
    x, y = x - 0.5, y - 0.5
    x0, y0 = np.floor(x).astype(np.int64), np.floor(y).astype(np.int64)
    fx, fy = (x - x0).astype(np.float32), (y - y0).astype(np.float32)
    x0c, x1c = np.clip(x0, 0, w - 1), np.clip(x0 + 1, 0, w - 1)      # the edge row repeats for the last
    y0c, y1c = np.clip(y0, 0, h - 1), np.clip(y0 + 1, 0, h - 1)      # half pixel; templates' edges are 0
    out = ((a[y0c, x0c] * (1 - fx) + a[y0c, x1c] * fx) * (1 - fy) +
           (a[y1c, x0c] * (1 - fx) + a[y1c, x1c] * fx) * fy)
    return np.where((x > -1) & (x < w) & (y > -1) & (y < h), out, 0).astype(np.float32)


def _along(wm: Watermark, u: np.ndarray, v: np.ndarray) -> np.ndarray:
    """Template points' position along the line of text (from the template's centre)."""
    h, w = wm.alpha.shape
    return wm.axis[0] * (u - w / 2) + wm.axis[1] * (v - h / 2)


def _bend_at(wm: Watermark, c: Copy, t: np.ndarray) -> tuple[np.ndarray, np.ndarray] | None:
    """A copy's bend (photo pixels) at positions `t` along the line: its part's."""
    if not c.bends or len(c.bends) != len(wm.cuts) + 1:
        return None
    b = np.asarray(c.bends)[np.searchsorted(np.asarray(wm.cuts), t)]
    return b[..., 0], b[..., 1]


def _to_template(wm: Watermark, c: Copy, x: np.ndarray, y: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """Photo coordinates → the template's (the inverse of where a copy puts it; a bend is undone by the part
    the point would be in unbent — parts meet in the gaps between words, so a few pixels either way don't
    matter)."""
    h, w = wm.alpha.shape
    co, si = _rot(c.angle)
    dx, dy = x - c.cx, y - c.cy
    u, v = (co * dx - si * dy) / c.scale + w / 2, (si * dx + co * dy) / c.scale + h / 2
    bend = _bend_at(wm, c, _along(wm, u, v))
    if bend is None:
        return u, v
    dx, dy = dx - bend[0], dy - bend[1]
    return (co * dx - si * dy) / c.scale + w / 2, (si * dx + co * dy) / c.scale + h / 2


def _to_photo(wm: Watermark, c: Copy, u: np.ndarray, v: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    h, w = wm.alpha.shape
    co, si = _rot(c.angle)
    du, dv = (u - w / 2) * c.scale, (v - h / 2) * c.scale
    x, y = c.cx + co * du + si * dv, c.cy - si * du + co * dv
    bend = _bend_at(wm, c, _along(wm, u, v))
    return (x, y) if bend is None else (x + bend[0], y + bend[1])


def _bounds(wm: Watermark, c: Copy, H: int, W: int, pad: int = 2) -> tuple[int, int, int, int] | None:
    """The photo pixels a copy covers (y0, x0, y1, x1), clipped; None when it's off the photo."""
    h, w = wm.alpha.shape
    xs, ys = _to_photo(wm, c, np.array([0, w, 0, w], np.float64), np.array([0, 0, h, h], np.float64))
    if c.bends:
        pad += int(math.ceil(max(max(abs(dx), abs(dy)) for dx, dy in c.bends)))
    x0, x1 = max(0, int(math.floor(xs.min())) - pad), min(W, int(math.ceil(xs.max())) + pad)
    y0, y1 = max(0, int(math.floor(ys.min())) - pad), min(H, int(math.ceil(ys.max())) + pad)
    return (y0, x0, y1, x1) if y1 > y0 and x1 > x0 else None


def render(wm: Watermark, c: Copy, H: int, W: int, pad: int = 2) -> tuple[int, int, np.ndarray] | None:
    """The template as this copy puts it on the photo's pixels: (y0, x0, patch), None when off the photo."""
    b = _bounds(wm, c, H, W, pad)
    if b is None:
        return None
    y0, x0, y1, x1 = b
    yy, xx = np.mgrid[y0:y1, x0:x1].astype(np.float64)
    u, v = _to_template(wm, c, xx + 0.5, yy + 0.5)
    return y0, x0, _bilinear(wm.blurred(c.scale), u, v)


def opacity(wm: Watermark, c: Copy, H: int, W: int, pad: int = 2) -> tuple[int, int, np.ndarray] | None:
    """The copy's opacity as fitted (strength and sharpness applied), on the photo's pixels."""
    r = render(wm, c, H, W, pad)
    if r is None:
        return None
    y0, x0, a = r
    return y0, x0, np.clip(c.gain * a + c.sharp * c.gain * (a - _blur(a, 1)), 0.0, MAX_ALPHA)


def luminance(rgb: np.ndarray) -> np.ndarray:
    return rgb[..., :3] @ LUMA if rgb.ndim == 3 else rgb.astype(np.float32)


def scaled(copies: list[Copy], f: float) -> list[Copy]:
    """Copies found on a photo shrunk by 1/f, as they lie on the photo itself."""
    return copies if f == 1 else [_at(c, f) for c in copies]


def _shape(alpha: np.ndarray, focus: np.ndarray | None = None) -> tuple[float, float]:
    """The strokes' extent along the line of text (2nd to 98th percentile) and the letters' height across it
    (the narrowest band holding 80 % of the strokes — neighbouring copies caught in the frame sit on other
    lines and don't widen it), in template pixels; from the strokes where the template started (`focus`)
    when there are enough of them."""
    peak = float(alpha.max())
    if peak <= 0:
        side = float(max(alpha.shape))
        return side, side / 4
    strong = alpha > 0.3 * peak
    if focus is not None and (strong & focus).sum() >= 20:
        strong &= focus
    ys, xs = np.nonzero(strong)
    if len(ys) < 20:
        side = float(max(alpha.shape))
        return side, side / 4
    pts = np.stack([xs, ys]).astype(np.float64)
    pts -= pts.mean(axis=1, keepdims=True)
    _ev, vec = np.linalg.eigh(np.cov(pts))
    along, across = np.sort(vec[:, 1] @ pts), np.sort(vec[:, 0] @ pts)
    k = int(math.ceil(0.8 * len(across)))
    band = float(np.min(across[k - 1:] - across[:len(across) - k + 1]))
    return max(float(np.percentile(along, 98) - np.percentile(along, 2)), 2.0), max(band, 2.0)


def _parted(wm: Watermark) -> Watermark:
    """The mark with its line of text and where its parts meet along it: its words (strokes closer than a
    ninth of the letters' height), a word longer than four and a half letters' height cut into even pieces
    of about three — each part may sit a little off on a copy."""
    a = wm.alpha
    peak = float(a.max())
    strong = a > 0.3 * peak if peak > 0 else np.zeros(a.shape, bool)
    if wm.focus is not None and (strong & wm.focus).sum() >= 20:
        strong &= wm.focus
    ys, xs = np.nonzero(strong)
    if len(ys) < 40:
        return replace(wm, axis=(1.0, 0.0), cuts=())
    h, w = a.shape
    pts = np.stack([xs + 0.5 - w / 2, ys + 0.5 - h / 2]).astype(np.float64)
    _ev, vec = np.linalg.eigh(np.cov(pts))
    axis = (float(vec[0, 1]), float(vec[1, 1]))
    _length, height = _shape(a, wm.focus)
    labels, n = _components(retouch._grow(a > 0.15 * peak, max(1, int(round(0.11 * height)))))
    yy, xx = np.nonzero(labels)
    t_all = axis[0] * (xx + 0.5 - w / 2) + axis[1] * (yy + 0.5 - h / 2)
    lab = labels[yy, xx]
    spans = []
    for i in range(1, n + 1):
        t = t_all[lab == i]
        if len(t) >= 15:
            spans.append((float(np.percentile(t, 1)), float(np.percentile(t, 99))))
    spans.sort()
    merged: list[list[float]] = []
    for lo, hi in spans:                    # parts that overlap along the line (an apostrophe) are one
        if merged and lo < merged[-1][1]:
            merged[-1][1] = max(merged[-1][1], hi)
        else:
            merged.append([lo, hi])
    cuts: list[float] = []
    for i, (lo, hi) in enumerate(merged):
        pieces = int(math.ceil((hi - lo) / (3 * height))) if hi - lo > 4.5 * height else 1
        cuts.extend(lo + (hi - lo) * j / pieces for j in range(1, pieces))
        if i + 1 < len(merged):
            cuts.append((hi + merged[i + 1][0]) / 2)
    return replace(wm, axis=axis, cuts=tuple(sorted(cuts)))


def _angle_of(mask: np.ndarray) -> float | None:
    """The main direction of a mask's pixels on screen (rising positive), or None when there are few."""
    ys, xs = np.nonzero(mask)
    if len(ys) < 20:
        return None
    _ev, vec = np.linalg.eigh(np.cov(np.stack([xs, ys]).astype(np.float64)))
    return math.degrees(math.atan2(-vec[1, 1], vec[0, 1]))


def _line(mask: np.ndarray, across: float) -> bool:
    """A straight thin stroke reaching a good way across (`across`: the box's diagonal) — a line in the art
    running through the box (a letter, a word or a logo is never that thin and straight). Left in, it finds
    "copies" all along every line in the picture, and the mark learned becomes the line."""
    ys, xs = np.nonzero(mask)
    if len(ys) < 12:
        return False
    ev = np.linalg.eigvalsh(np.cov(np.stack([xs, ys]).astype(np.float64)))
    length, width = 3.46 * math.sqrt(max(ev[1], 0.0)), math.sqrt(max(ev[0], 0.0))
    return length > 0.1 * across and width < min(2.5, 0.05 * length)


def _shift(a: np.ndarray, oy: int, ox: int) -> np.ndarray:
    """`a` moved by (oy, ox), what comes in from outside empty."""
    h, w = a.shape
    out = np.zeros_like(a)
    if abs(oy) >= h or abs(ox) >= w:
        return out
    out[max(0, oy):h + min(0, oy), max(0, ox):w + min(0, ox)] = a[max(0, -oy):h - max(0, oy), max(0, -ox):w - max(0, ox)]
    return out


def _straight(mask: np.ndarray, length: int, step: float = 3.0, text: float | list[float] | None = None,
              thin: int = 5) -> np.ndarray:
    """The pixels of `mask` on a straight run at least `length` long, at any angle (a morphological opening
    with a line `length` long, every `step` degrees, on the mask thickened by a pixel so a thin line drawn
    at a slant doesn't break into steps). Letters' strokes are never that long; lines in the art are, even
    where they cross letters and are joined to them. Close-set letters thickened make a band with runs of its
    own, along the text and a little either side of it: a run only counts where the strokes don't reach
    `thin` pixels out on both sides across it (a line is thin; a band of letters is a letter tall), and along
    the text itself (`text`: its angle on screen, rising positive, or several, ±8°) not at all."""
    if length < 4 or not mask.any():
        return np.zeros_like(mask)
    thick = retouch._grow(mask, 1)
    h, w = mask.shape
    pad = length + 1
    big = np.zeros((h + 2 * pad, w + 2 * pad), bool)
    big[pad:pad + h, pad:pad + w] = thick
    found = np.zeros_like(big)
    skip = [] if text is None else [text] if isinstance(text, (int, float)) else list(text)
    for deg in np.arange(0.0, 180.0, step):
        if any(abs((deg + t + 90) % 180 - 90) < 8 for t in skip):          # deg runs y-down: screen = −deg
            continue
        dx, dy = math.cos(math.radians(deg)), math.sin(math.radians(deg))

        def moved(a: np.ndarray, t: float) -> np.ndarray:
            return _shift(a, int(round(-t * dy)), int(round(-t * dx)))
        run, span = big, 1                       # every pixel `length` along from here is set — by doubling:
        while 2 * span <= length:                # a run of 2s is a run of s here and a run of s s further on
            run = run & moved(run, span)
            span *= 2
        if span < length:
            run = run & moved(run, length - span)
        if not run.any():
            continue
        seg, span = run, 1                       # …then the whole run is marked, by doubling back
        while 2 * span <= length:
            seg = seg | moved(seg, -span)
            span *= 2
        if span < length:
            seg = seg | moved(seg, -(length - span))
        ny, nx = int(round(thin * dx)), int(round(-thin * dy))
        wide = big & _shift(big, ny, nx) & _shift(big, -ny, -nx)
        found |= seg & ~wide                     # …where it's thin across (a band of letters isn't)
    return found[pad:pad + h, pad:pad + w] & mask


# -- the first template, from one boxed copy --------------------------------------------------------

def rough(rgb: np.ndarray, box: tuple[int, int, int, int]) -> tuple[Watermark, Copy]:
    """A first template from the copy inside `box` (x0, y0, x1, y1 in pixels): what stands out from the
    background there, specks dropped. Returns it and the boxed copy. Raises NoWatermark."""
    H, W = rgb.shape[:2]
    x0, y0, x1, y1 = max(0, box[0]), max(0, box[1]), min(W, box[2]), min(H, box[3])
    if x1 - x0 < 8 or y1 - y0 < 8:
        raise NoWatermark("the box is too small — drag it round one whole copy of the watermark")
    crop = luminance(rgb)[y0:y1, x0:x1]
    scale = max(2, min(crop.shape) // 100)
    small = Image.fromarray(np.clip(crop, 0, 255).astype(np.uint8)).resize(
        (max(1, crop.shape[1] // scale), max(1, crop.shape[0] // scale)), Image.Resampling.BOX)
    bg = np.asarray(small.filter(ImageFilter.MedianFilter(9)).resize(
        (crop.shape[1], crop.shape[0]), Image.Resampling.BILINEAR), dtype=np.float32)
    off = crop - bg
    threshold = 14.0
    lighter, darker = off > threshold, off < -threshold
    sign = 1.0 if (off * lighter).sum() >= -(off * darker).sum() else -1.0
    mark = lighter if sign > 0 else darker
    grow = max(1, min(crop.shape) // 200)
    for _ in range(3):                      # the background again from what isn't the mark
        if not mark.any():
            break
        bg = _blur(retouch._membrane(crop[..., None], retouch._grow(mark, grow + 1))[..., 0], 2 * scale)
        more = mark | (sign * (crop - bg) > threshold)
        if more.sum() == mark.sum():
            break
        mark = more
    mark &= ~retouch._grow(_straight(mark, int(0.3 * math.hypot(*crop.shape)), text=_angle_of(mark)), 1)
    if mark.sum() >= 30:                                     # lines in the art, then shorter bits of them
        _length, tall = _shape(mark.astype(np.float32))
        mark &= ~retouch._grow(_straight(mark, max(8, int(2.6 * tall)), text=_angle_of(mark)), 1)
    labels, n = _components(mark)
    if n:
        sizes = np.bincount(labels.ravel())[1:]
        keep = [i for i in np.flatnonzero(sizes >= max(12, 0.06 * sizes.max())) + 1
                if not _line(labels == i, math.hypot(*crop.shape))]
        mark = np.isin(labels, keep)
    if mark.sum() < 30:
        raise NoWatermark("nothing in the box stands out as a watermark — drag it round one copy of it")
    ink = 255.0 if sign > 0 else 0.0
    room = np.where(np.abs(ink - bg) > 20, ink - bg, 20.0 * sign)
    alpha = np.where(retouch._grow(mark, 1), np.clip((crop - bg) / room, 0, 1), 0).astype(np.float32)
    wm = _parted(Watermark(alpha, np.full(3, ink, np.float32), min(H, W), focus=retouch._grow(mark, 1)))
    m = max(8, int(0.12 * max(alpha.shape)))            # the box may have cut the mark: room to grow
    return wm.padded(m), Copy((x0 + x1) / 2, (y0 + y1) / 2, 1.0, 0.0, 1.0)


# -- finding copies ----------------------------------------------------------------------------------

def _grid(lo: float, hi: float, step: float, log: bool) -> list[float]:
    if log:
        n = max(1, int(math.ceil(math.log(hi / lo) / math.log(step))) + 1)
        return [float(v) for v in np.exp(np.linspace(math.log(lo), math.log(hi), n))] if n > 1 else [math.sqrt(lo * hi)]
    n = max(1, int(math.ceil((hi - lo) / step)) + 1)
    return [float(v) for v in np.linspace(lo, hi, n)] if n > 1 else [(lo + hi) / 2]


def search_space(wm: Watermark, H: int, W: int, wide: bool = False) -> list[tuple[float, float]]:
    """The sizes and turns to look for a kept mark at on an H×W photo: round the sizes it was seen at — at
    the same pixel size, and in proportion to the photo — and its turns; wider when asked."""
    priors = [1.0]
    ratio = min(H, W) / max(1, wm.side)
    if abs(math.log(ratio)) > math.log(1.1):
        priors.append(ratio)
    lo, hi = wm.scales
    alo, ahi = wm.angles
    if wide:
        lo, hi, alo, ahi = lo * 0.6, hi * 1.7, alo - 10, ahi + 10
    else:
        lo, hi, alo, ahi = lo / 1.15, hi * 1.15, alo - 4, ahi + 4
    return [(s, a) for p in priors for s in _grid(lo * p, hi * p, SCALE_STEP, True)
            for a in _grid(alo, ahi, ANGLE_STEP, False)]


def _around(copies: list[Copy]) -> list[tuple[float, float]]:
    """Sizes and turns round copies already found on a photo — its other copies may be bigger or turned."""
    lo, hi = min(c.scale for c in copies), max(c.scale for c in copies)
    alo, ahi = min(c.angle for c in copies), max(c.angle for c in copies)
    return [(s, a) for s in _grid(lo * 0.8, hi * 1.3, SCALE_STEP, True)
            for a in _grid(alo - 8, ahi + 8, ANGLE_STEP, False)]


def _warped(alpha: np.ndarray, scale: float, angle: float) -> tuple[np.ndarray, float, float]:
    """The (small) template drawn at a size and turn on its own grid: the image and where its centre is."""
    h, w = alpha.shape
    co, si = _rot(angle)
    hw, hh = w * scale / 2, h * scale / 2
    ex, ey = abs(co) * hw + abs(si) * hh, abs(si) * hw + abs(co) * hh
    W2, H2 = int(math.ceil(2 * ex)) + 2, int(math.ceil(2 * ey)) + 2
    ox, oy = W2 / 2, H2 / 2
    yy, xx = np.mgrid[0:H2, 0:W2].astype(np.float64)
    dx, dy = xx + 0.5 - ox, yy + 0.5 - oy
    u = (co * dx - si * dy) / scale + w / 2
    v = (si * dx + co * dy) / scale + h / 2
    src = _blur(alpha, int(round(0.5 / scale - 0.5))) if scale < 1 else alpha
    return _bilinear(src, u, v), ox, oy


def _coarse(L: np.ndarray, wm: Watermark, space: list[tuple[float, float]], cancelled: Cancelled | None,
            most: int = 40, rel: float = 0.3) -> list[Copy]:
    """Candidate copies from the masked NCC of the photo's and the template's fine detail at a coarse scale,
    over every size and turn in `space` — best first, overlapping ones dropped, none weaker than `rel` of
    the best."""
    H, W = L.shape
    mid = math.exp(float(np.mean([math.log(s) for s, _a in space])))
    d = max(1.0, max(wm.alpha.shape) * mid / COARSE_PX, max(H, W) / COARSE_PHOTO)
    Hs, Ws = max(8, int(round(H / d))), max(8, int(round(W / d)))
    fy, fx = H / Hs, W / Ws                                  # full-size pixels per coarse pixel
    F = _highpass(_resize(L, Hs, Ws), 2)
    small = _resize(wm.alpha, max(4, round(wm.alpha.shape[0] / d)), max(4, round(wm.alpha.shape[1] / d)))
    k = wm.alpha.shape[0] / small.shape[0]                  # template pixels per small-template pixel
    templates = []
    for s, a in space:
        t, ox, oy = _warped(small, s, a)
        support = retouch._grow(t > 0.04 * max(float(t.max()), 1e-6), 1)
        if support.sum() < 20:
            continue
        templates.append((s, a, _highpass(t, 2) * wm.sign, support.astype(np.float32), ox, oy))
    if not templates:
        return []
    P = max(max(t[2].shape) for t in templates)              # room for centres off the photo
    th = max(t[2].shape[0] for t in templates)
    tw = max(t[2].shape[1] for t in templates)
    shape = (_good(Hs + th - 1), _good(Ws + tw - 1))
    rf = np.fft.rfft2
    f_f, f_ff, f_1 = rf(F, shape), rf(F * F, shape), rf(np.ones_like(F), shape)
    best = np.full((Hs + 2 * P, Ws + 2 * P), -1.0, np.float32)    # by the template centre's pixel
    which = np.zeros(best.shape, np.int32)
    floors = []
    for i, (s, a, T, M, ox, oy) in enumerate(templates):
        if cancelled is not None and cancelled():
            raise Stopped
        h, w = T.shape
        # Correlation with the template flipped: index (y, x) has its top-left at (y − (h−1), x − (w−1)).
        f_m, f_tm, f_ttm = rf(M[::-1, ::-1], shape), rf((T * M)[::-1, ::-1], shape), rf((T * T * M)[::-1, ::-1], shape)

        def back(x: np.ndarray) -> np.ndarray:
            return np.fft.irfft2(x, shape)[:Hs + h - 1, :Ws + w - 1]
        n = back(f_1 * f_m)
        sf, sff, st, stt, sft = back(f_f * f_m), back(f_ff * f_m), back(f_1 * f_tm), back(f_1 * f_ttm), back(f_f * f_tm)
        ns = np.maximum(n, 1.0)
        num = sft - sf * st / ns
        den = np.sqrt(np.maximum((sff - sf * sf / ns) * (stt - st * st / ns), 1e-9))
        enough = n > MIN_OVERLAP * M.sum()
        ncc = np.where(enough, num / den, -1.0).astype(np.float32)
        if enough.any():
            v = ncc[enough]
            floors.append(float(v.mean() + 6.5 * v.std()))
        sy, sx = P - (h - 1) + int(math.floor(oy)), P - (w - 1) + int(math.floor(ox))
        sub = best[sy:sy + ncc.shape[0], sx:sx + ncc.shape[1]]
        better = ncc > sub
        sub[better] = ncc[better]
        which[sy:sy + ncc.shape[0], sx:sx + ncc.shape[1]][better] = i
    floor = max(0.16, float(np.median(floors)) if floors else 0.16)
    rad = max(2, int(min(small.shape) * mid / 3))            # closer than this: the same copy
    out: list[Copy] = []
    while len(out) < most:
        Y, X = np.unravel_index(int(np.argmax(best)), best.shape)
        v = float(best[Y, X])
        if v < floor or (out and v < rel * out[0].score):
            break
        s, a, _T, _M, ox, oy = templates[int(which[Y, X])]
        cx, cy = X - P + (ox - math.floor(ox)), Y - P + (oy - math.floor(oy))
        out.append(Copy(cx * fx, cy * fy, s * (fx + fy) / 2 / k, a, v))
        best[max(0, Y - rad):Y + rad + 1, max(0, X - rad):X + rad + 1] = -1
    return out


class _Scorer:
    """The NCC of one copy against the photo's fine detail, on a fixed set of photo pixels (the copy's
    strokes and a margin round them) — cheap enough to call a hundred times while refining."""

    def __init__(self, F: np.ndarray, wm: Watermark, c: Copy, margin: int, f: float) -> None:
        self.wm, self.f = wm, f               # f: this level's pixels per full-size pixel
        H, W = F.shape
        r = render(wm, _at(c, f), H, W, pad=margin + 2)
        self.ok = r is not None
        if r is None:
            return
        y0, x0, a = r
        support = retouch._grow(a > 0.04 * max(float(a.max()), 1e-6), margin)
        ys, xs = np.nonzero(support)
        self.ok = len(ys) >= 30
        self.x = (xs + x0 + 0.5).astype(np.float64)
        self.y = (ys + y0 + 0.5).astype(np.float64)
        fv = F[ys + y0, xs + x0]
        self.fv = fv - fv.mean() if len(fv) else fv
        self.fn = float(np.sqrt((self.fv ** 2).sum())) or 1.0
        self.detail = _highpass(wm.blurred(c.scale * f), 2) * wm.sign

    def __call__(self, c: Copy) -> float:
        u, v = _to_template(self.wm, _at(c, self.f), self.x, self.y)
        t = _bilinear(self.detail, u, v)
        t = t - t.mean()
        tn = float(np.sqrt((t ** 2).sum()))
        return float((self.fv * t).sum()) / (self.fn * tn) if tn > 1e-9 else -1.0


def _at(c: Copy, f: float) -> Copy:
    """A copy as seen on the photo resized by f — its size against the template, and its bends, with it."""
    if f == 1:
        return c
    bends = None if c.bends is None else tuple((dx * f, dy * f) for dx, dy in c.bends)
    return replace(c, cx=c.cx * f, cy=c.cy * f, scale=c.scale * f, bends=bends)


def _refine(F: np.ndarray, wm: Watermark, c: Copy, f: float, step: float, cancelled: Cancelled | None) -> Copy:
    """A pattern search over position, size and turn for the best NCC; `step` is the first move (pixels of
    this level). Positions and sizes stay in full-size terms."""
    sc = _Scorer(F, wm, c, margin=int(math.ceil(step * 2)) + 2, f=f)
    if not sc.ok:
        return replace(c, score=-1.0)
    best = sc(c)
    steps = np.array([step / f, step / f, 0.015 * step, 0.5 * step])
    for _ in range(120):
        if cancelled is not None and cancelled():
            raise Stopped
        if steps[0] * f < 0.05:
            break
        trial = None
        for i in range(4):
            for sgn in (1, -1):
                d = sgn * steps[i]
                n = replace(c, cx=c.cx + (d if i == 0 else 0), cy=c.cy + (d if i == 1 else 0),
                            scale=c.scale * (math.exp(d) if i == 2 else 1), angle=c.angle + (d if i == 3 else 0))
                s = sc(n)
                if s > best + 1e-5 and (trial is None or s > trial[0]):
                    trial = (s, n)
        if trial is None:
            steps /= 2
        else:
            best, c = trial
    return replace(c, score=best)


def _shifts(F: np.ndarray, wm: Watermark, c: Copy, cancelled: Cancelled | None) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """How far each part of the copy sits from where its position, size and turn put it — searched along
    the line as far as two thirds of the letters' height and across it a sixth, every 1.5 px, then to a
    twentieth of a pixel, for the best NCC with the photo's fine detail (pulled gently towards none, so a
    part over noise stays put). Returns the shifts (n, 2), each part's stroke pixels and its centre along
    the line."""
    n = len(wm.cuts) + 1
    H, W = F.shape
    straight = replace(c, bends=None)
    zero = np.zeros((n, 2)), np.zeros(n), np.zeros(n)
    r = render(wm, straight, H, W, pad=6)
    if r is None:
        return zero
    y0, x0, a = r
    ys, xs = np.nonzero(retouch._grow(a > 0.04 * max(float(a.max()), 1e-6), 3))
    px, py = xs + x0 + 0.5, ys + y0 + 0.5
    u, v = _to_template(wm, straight, px, py)
    t_all = _along(wm, u, v)
    part = np.searchsorted(np.asarray(wm.cuts), t_all)
    fv = F[ys + y0, xs + x0]
    detail = _highpass(wm.blurred(c.scale), 2) * wm.sign
    co, si = _rot(c.angle)
    along = np.array([co * wm.axis[0] + si * wm.axis[1], -si * wm.axis[0] + co * wm.axis[1]])
    across = np.array([along[1], -along[0]])
    _length, height = _shape(wm.alpha, wm.focus)
    reach_a, reach_c = max(6.0, 0.65 * height * c.scale), max(3.0, 0.16 * height * c.scale)
    shifts, sizes, centres = np.zeros((n, 2)), np.zeros(n), np.zeros(n)
    for i in range(n):
        if cancelled is not None and cancelled():
            raise Stopped
        sel = part == i
        sizes[i] = sel.sum()
        if sel.sum() < 40:
            continue
        centres[i] = float(t_all[sel].mean())
        f = fv[sel] - fv[sel].mean()
        fn = float(np.sqrt((f * f).sum())) or 1.0
        sx, sy = px[sel], py[sel]

        def scores(d: np.ndarray) -> np.ndarray:            # d: (m, 2) shifts → (m,) penalized NCCs
            uu, vv = _to_template(wm, straight, sx[None, :] - d[:, :1], sy[None, :] - d[:, 1:])
            t = _bilinear(detail, uu, vv)
            t = t - t.mean(axis=1, keepdims=True)
            tn = np.sqrt((t * t).sum(axis=1))
            ncc = np.where(tn > 1e-9, (t @ f) / (fn * np.maximum(tn, 1e-9)), -1.0)
            return ncc - 0.0005 * (d * d).sum(axis=1)

        def score(d: np.ndarray) -> float:
            return float(scores(d[None, :])[0])
        ka, kc = np.meshgrid(np.arange(-reach_a, reach_a + 0.01, 2.0), np.arange(-reach_c, reach_c + 0.01, 2.0))
        grid = np.concatenate([np.zeros((1, 2)), ka.reshape(-1, 1) * along + kc.reshape(-1, 1) * across])
        full = (f, fn, sx, sy)
        f, sx, sy = f[::2], sx[::2], sy[::2]                 # the wide look on every other pixel
        fn = float(np.sqrt((f * f).sum())) or 1.0
        got = np.concatenate([scores(grid[j:j + 64]) for j in range(0, len(grid), 64)])
        f, fn, sx, sy = full
        at = grid[int(np.argmax(got))]
        best = score(at)
        step = 1.0
        while step >= 0.05:
            moved = False
            for dd in ((step, 0), (-step, 0), (0, step), (0, -step)):
                d = at + np.array(dd)
                sc = score(d)
                if sc > best + 1e-5:
                    best, at, moved = sc, d, True
            if not moved:
                step /= 2
        shifts[i] = at
    return shifts, sizes, centres


def _bend(F: np.ndarray, wm: Watermark, c: Copy, cancelled: Cancelled | None) -> Copy:
    """The copy's bends (`_shifts`). With four parts or more, a steady drift along the line — one end's parts
    off one way, the other end's the other — is its size or turn being off (the position search can settle
    on a size that fits one end), so that goes into its size, turn and position and the parts are measured
    again; what's left are the bends."""
    if not wm.cuts:
        return replace(c, bends=None)
    for _ in range(3):
        shifts, sizes, centres = _shifts(F, wm, c, cancelled)
        used = sizes > 0
        if used.sum() < 4:
            break
        wts = np.sqrt(sizes[used])
        A = np.stack([np.ones(used.sum()), centres[used]], axis=1) * wts[:, None]
        (b0, b1), *_ = np.linalg.lstsq(A, shifts[used] * wts[:, None], rcond=None)
        co, si = _rot(c.angle)
        along = np.array([co * wm.axis[0] + si * wm.axis[1], -si * wm.axis[0] + co * wm.axis[1]])
        across = np.array([along[1], -along[0]])
        span = float(centres[used].max() - centres[used].min())
        if max(abs(b1[0]), abs(b1[1])) * span / 2 < 0.6:
            break
        c = replace(c, cx=c.cx + float(b0[0]), cy=c.cy + float(b0[1]), scale=c.scale + float(b1 @ along),
                    angle=c.angle + math.degrees(float(b1 @ across) / c.scale), bends=None)
    else:
        shifts, _sizes, _centres = _shifts(F, wm, c, cancelled)
    return replace(c, bends=tuple((float(dx), float(dy)) for dx, dy in shifts))


def _fit(rgb: np.ndarray, wm: Watermark, c: Copy, F: np.ndarray | None = None,
         cancelled: Cancelled | None = None) -> Copy:
    """The copy's bends (`_bend`), its edges' sharpness, then its strength. The sharpness is fitted by least
    squares so that what's left where it was has no detail shaped like it: a copy adds α·(ink − art) =
    α·(ink − pixel)/(1 − α) to the art, so the model's parts are the template and its fine detail (α less
    its 3×3 blur — the template is a little softer than any one copy), each times (ink − pixel)/(1 − α),
    fitted on fine detail only so the art's own shading doesn't count. The strength is read directly
    (`_strengths`), which stars and grain can't sway."""
    H, W = rgb.shape[:2]
    if F is None:
        F = _highpass(luminance(rgb), 2)
    c = _bend(F, wm, c, cancelled)
    ink = float(wm.colour @ LUMA)
    r = render(wm, c, H, W, pad=6)
    if r is None:
        return replace(c, gain=0.0)
    y0, x0, a = r
    patch = luminance(rgb[y0:y0 + a.shape[0], x0:x0 + a.shape[1]])
    support = retouch._grow(a > 0.03 * max(float(a.max()), 1e-6), 2)
    if support.sum() < 30:
        return replace(c, gain=0.0)
    k = (ink - patch) / (1 - np.minimum(a, MAX_ALPHA))
    X = np.stack([_highpass(p, 2)[support] for p in (a * k, (a - _blur(a, 1)) * k)], axis=1).astype(np.float64)
    y = _highpass(patch, 2)[support].astype(np.float64)
    xtx = X.T @ X
    pull = 0.02 * np.diag(xtx) + 1e-6
    try:
        g, h = np.linalg.solve(xtx + np.diag(pull), X.T @ y + pull * np.array([1.0, 0.0]))
        if 0.5 <= g <= 2.0:
            c = replace(c, sharp=float(np.clip(h / g, -1.5, 2.5)))
    except np.linalg.LinAlgError:
        pass
    read = _strengths(rgb, wm, c)
    if read is None:
        return replace(c, gain=0.0, gains=None)
    lum, per = read
    return replace(c, gain=lum, gains=per)


def _strengths(rgb: np.ndarray, wm: Watermark, c: Copy) -> tuple[float, tuple[float, float, float]] | None:
    """The copy's strength against the template, read inside its strokes: the median of what the photo says
    the opacity is over what the template says (a star under a stroke is one pixel of many) — in brightness,
    and per colour channel (one row of copies can be a warmer white than another). None when too little of
    it can be read."""
    H, W = rgb.shape[:2]
    r = render(wm, c, H, W, pad=4)
    if r is None:
        return None
    y0, x0, t = r
    peak = float(t.max())
    inner = t > 0.5 * peak
    if inner.sum() < 20:
        return None
    patch = rgb[y0:y0 + t.shape[0], x0:x0 + t.shape[1], :3].astype(np.float32)
    bg = _fill(patch, retouch._grow(t > 0.02 * peak, 2))
    ink = np.asarray(wm.colour, np.float32)

    def read(p: np.ndarray, b: np.ndarray, i: float) -> float | None:
        room = i - b
        ok = inner & (np.abs(room) > 30)
        if ok.sum() < 20:
            return None
        return float(np.clip(np.median((p - b)[ok] / room[ok] / t[ok]), 0.0, 2.5))
    lum = read(patch @ LUMA, bg @ LUMA, float(ink @ LUMA))
    if lum is None:
        return None
    per = tuple(read(patch[..., k], bg[..., k], float(ink[k])) for k in range(3))
    return lum, tuple(lum if v is None else v for v in per)


def refine_all(rgb: np.ndarray, wm: Watermark, cands: list[Copy], *, L: np.ndarray | None = None,
               check: bool = True, fit: bool = True, cancelled: Cancelled | None = None,
               coarse: float = 2.0) -> list[Copy]:
    """`cands` refined (on a smaller photo first when the copies are big), duplicates merged, then fitted
    (`_fit`, unless `fit` is off). With `check`, hits matching worse than MIN_SCORE (or a quarter of the best
    match) are dropped before fitting, and those read weaker than MIN_GAIN after — not the mark."""
    H, W = rgb.shape[:2]
    L = luminance(rgb) if L is None else L
    levels: dict[float, np.ndarray] = {}

    def level(f: float) -> np.ndarray:
        if f not in levels:
            levels[f] = _highpass(L if f == 1 else _resize(L, round(H * f), round(W * f)), 2)
        return levels[f]
    placed: list[Copy] = []
    for c in cands:
        long_side = max(wm.alpha.shape) * c.scale
        f = min(1.0, REFINE_PX / long_side)
        f = 1.0 if f > 0.8 else round(f, 3)
        step = max(1.0, coarse * f)
        c = replace(c, bends=None)
        if f < 1:
            c = _refine(level(f), wm, c, f, step, cancelled)
            step = max(1.0, 1 / f)
        c = _refine(level(1.0), wm, c, 1.0, min(step, 3.0), cancelled)
        if c.score > 0.05:
            placed.append(c)
    if check and placed:
        top = max(c.score for c in placed)
        placed = [c for c in placed if c.score >= max(MIN_SCORE, 0.25 * top)]
    kept: list[Copy] = []                   # two candidates that settled on the same copy: keep the better
    for c in sorted(placed, key=lambda c: -c.score):
        near = max(wm.alpha.shape) * c.scale * 0.15
        if all(math.hypot(c.cx - k.cx, c.cy - k.cy) > near for k in kept):
            kept.append(c)
    if not fit:
        return kept
    out = [_fit(rgb, wm, c, level(1.0), cancelled) for c in kept]
    return [c for c in out if c.gain >= MIN_GAIN] if check else out


# -- learning the mark on one photo ------------------------------------------------------------------

def _readings(rgb: np.ndarray, wm: Watermark, c: Copy) -> tuple[int, int, np.ndarray, np.ndarray] | None:
    """What one copy says the mark's opacity is, pixel by pixel round it: (pixel − background) / (ink −
    background), the background a smooth fill under the strokes (and under anything else that stands out,
    so strokes the template still lacks are read too). Returns (y0, x0, opacity, weight)."""
    H, W = rgb.shape[:2]
    r = render(wm, c, H, W, pad=int(4 + 0.03 * max(wm.alpha.shape) * c.scale))
    if r is None:
        return None
    y0, x0, a = r
    patch = rgb[y0:y0 + a.shape[0], x0:x0 + a.shape[1], :3].astype(np.float32)
    lum = patch @ LUMA
    hole = retouch._grow(a > 0.03 * max(float(a.max()), 1e-6), max(2, int(round(c.scale * 2))))
    hole |= retouch._grow(wm.sign * (lum - _blur(_blur(lum, 6), 6)) > 10, 1)
    if hole.all() or not hole.any():
        return None
    bg = _fill(patch, hole)
    room = np.asarray(wm.colour, np.float32)[None, None, :] - bg
    weight = np.where(np.abs(room) > 25, room * room, 0.0)
    est = (patch - bg) / np.where(np.abs(room) > 1, room, 1.0)
    wsum = weight.sum(-1)
    op = np.where(wsum > 0, (est * weight).sum(-1) / np.maximum(wsum, 1e-9), 0.0).astype(np.float32)
    return y0, x0, op, wsum.astype(np.float32)


def _estimate(rgb: np.ndarray, copies: list[Copy], wm: Watermark) -> np.ndarray:
    """The template from every copy's readings, mapped into its frame, by a per-pixel median."""
    h, w = wm.alpha.shape
    vv, uu = np.mgrid[0:h, 0:w].astype(np.float64) + 0.5
    stack = []
    for c in copies:
        r = _readings(rgb, wm, c)
        if r is None:
            continue
        y0, x0, op, wt = r
        x, y = _to_photo(wm, c, uu, vv)
        val = _bilinear(op, x - x0, y - y0)
        ok = _bilinear((wt > 0).astype(np.float32), x - x0, y - y0) > 0.99
        stack.append(np.where(ok, val, np.nan))
    if not stack:
        return wm.alpha
    stack = np.stack(stack)
    # Where only a copy or two can be seen (the rest run off the photo), what's under those few is as
    # likely as the mark — a net's white strings read as "mark" — so a pixel needs several copies' say.
    seen = np.isfinite(stack).sum(axis=0)
    need = 1 if len(stack) < 2 else max(2, int(math.ceil(0.5 * len(stack))))
    est = np.zeros((h, w), np.float32)
    enough = seen >= need
    if enough.any():
        est[enough] = np.nanmedian(stack[:, enough], axis=0)
    est[est < 0.012] = 0.0
    peak = float(est.max())
    if peak > 0:                            # specks left over (a star seen through half the copies) go
        labels, n = _components(est > 0.1 * peak)
        if n:
            sizes = np.bincount(labels.ravel())
            est[(sizes[labels] < 8) & (labels > 0)] = 0.0
    return np.clip(est, 0.0, 1.0).astype(np.float32)


def _unlined(alpha: np.ndarray, focus: np.ndarray | None) -> np.ndarray:
    """The template without straight runs longer than 2.6 letters' height (the band measure; a tall letter's
    stem is ~1.5 of it, and a shorter limit cut the "J" and "h" of the person's mark) — a line in the art
    that crossed the copies at the same place in each (lined up by the line itself) is not part of the mark."""
    peak = float(alpha.max())
    if peak <= 0:
        return alpha
    mark = alpha > 0.15 * peak
    if mark.sum() < 30:
        return alpha
    _length, height = _shape(alpha, focus)
    along = _angle_of(mark & focus) if focus is not None and (mark & focus).sum() >= 20 else _angle_of(mark)
    lines = _straight(mark, max(10, int(2.6 * height)), text=along)
    if not lines.any():
        return alpha
    return np.where(retouch._grow(lines, 1), 0.0, alpha).astype(np.float32)


def _ink(rgb: np.ndarray, copies: list[Copy], wm: Watermark) -> np.ndarray:
    """The mark's colour: (pixel − (1 − α)·background) / α where the strokes are solid, by median."""
    vals = []
    peak = float(wm.alpha.max())
    H, W = rgb.shape[:2]
    for c in copies:
        r = render(wm, c, H, W, pad=4)
        if r is None:
            continue
        y0, x0, a = r
        patch = rgb[y0:y0 + a.shape[0], x0:x0 + a.shape[1], :3].astype(np.float32)
        bg = _fill(patch, retouch._grow(a > 0.03 * peak, 2))
        solid = a > 0.6 * peak
        if solid.sum() < 10:
            continue
        al = a[solid][:, None]
        vals.append((patch[solid] - (1 - al) * bg[solid]) / np.maximum(al, 1e-3))
    if not vals:
        return wm.colour
    return np.clip(np.median(np.concatenate(vals), axis=0), 0, 255).astype(np.float32)


def _main_block(wm: Watermark, copies: list[Copy], final: bool) -> tuple[Watermark, list[Copy]]:
    """The template cropped to the block of strokes joined to where it started — words on its line joined
    (gaps along the line up to twice the letters' height, across it half that), a neighbouring copy caught in
    the frame dropped — with the copies' centres moved to match. Before the last round it keeps room."""
    a = wm.alpha
    peak = float(a.max())
    mark = a > 0.15 * peak
    if mark.sum() < 30:
        return wm, copies
    _length, height = _shape(a, wm.focus)
    join = max(2, int(round(0.25 * height)))
    labels, n = _components(_grow_along(mark, _parted(wm).axis, max(2, int(round(height))), join))
    if n > 1:
        overlap = np.bincount(labels[wm.focus], minlength=n + 1)[1:] if wm.focus is not None else np.zeros(n)
        if overlap.max() > 0:
            main = int(np.argmax(overlap)) + 1
        else:
            main = int(np.argmax(np.bincount(labels.ravel(), weights=a.ravel().astype(np.float64))[1:])) + 1
        a = np.where(retouch._grow(labels == main, 2), a, 0.0).astype(np.float32)
    ys, xs = np.nonzero(a > 0.02 * peak)
    m = 6 if final else 6 + join
    i0, i1 = max(0, ys.min() - m), min(a.shape[0], ys.max() + m + 1)
    j0, j1 = max(0, xs.min() - m), min(a.shape[1], xs.max() + m + 1)
    focus = None if wm.focus is None else np.ascontiguousarray(wm.focus[i0:i1, j0:j1])
    new = _parted(replace(wm, alpha=np.ascontiguousarray(a[i0:i1, j0:j1]), focus=focus, _cache={}))
    h, w = wm.alpha.shape
    du, dv = (j0 + j1) / 2 - w / 2, (i0 + i1) / 2 - h / 2
    moved = []
    for c in copies:
        co, si = _rot(c.angle)
        moved.append(replace(c, cx=c.cx + c.scale * (co * du + si * dv), cy=c.cy + c.scale * (-si * du + co * dv),
                             bends=None))
    return new, moved


def _relearn(rgb: np.ndarray, wm: Watermark, copies: list[Copy], *, grow: int = 0, rounds: int = 3,
             say: Callable[[float, str], None] | None = None, cancelled: Cancelled | None = None) -> tuple[Watermark, list[Copy]]:
    """The mark as this photo has it, learned from `copies` of a first template (`wm`) found on it: read
    from the copies, the others looked for with it, read again — each round with room round the template
    (`grow` pixels the first time, for a template found by one word to grow to its whole line)."""
    L = luminance(rgb)
    H, W = rgb.shape[:2]
    for rnd in range(rounds):
        m = grow if rnd == 0 else max(6, int(0.08 * max(wm.alpha.shape)))
        if m:
            wm = wm.padded(m)
        if rnd == 1:                        # the others, with a better template
            if say:
                say(rnd / rounds, "Looking for the other copies…")
            cands = copies + _coarse(L, wm, _around(copies), cancelled)
            copies = refine_all(rgb, wm, cands, L=L, cancelled=cancelled,
                                coarse=max(1.0, max(wm.alpha.shape) / COARSE_PX)) or copies
        elif rnd == 2:
            copies = refine_all(rgb, wm, copies, L=L, cancelled=cancelled, coarse=1.0) or copies
        if say:
            n = len(copies)
            say((rnd + 0.7) / rounds, f"Learning the watermark from {n} cop{'y' if n == 1 else 'ies'}…")
        if cancelled is not None and cancelled():
            raise Stopped
        wm = replace(wm, alpha=_unlined(_estimate(rgb, copies, wm), wm.focus), _cache={})
        if float(wm.alpha.max()) <= 0.02:
            raise NoWatermark("the copies didn't agree on a watermark — drag the box round one whole copy")
        wm = replace(wm, colour=_ink(rgb, copies, wm), _cache={})
        wm = replace(wm, alpha=_unlined(_estimate(rgb, copies, wm), wm.focus), _cache={})
        wm, copies = _main_block(wm, copies, final=rnd == rounds - 1)
    copies = refine_all(rgb, wm, copies, L=L, cancelled=cancelled, coarse=1.0)
    if not copies:
        raise NoWatermark("no copy of the watermark could be taken out")
    if _line(wm.alpha > 0.3 * float(wm.alpha.max()), math.hypot(*wm.alpha.shape)):
        raise NoWatermark("what it found is a line in the picture, not a watermark — drag the box round the "
                          "watermark only")
    return _stats(wm, copies, H, W), copies


def _stats(wm: Watermark, copies: list[Copy], H: int, W: int) -> Watermark:
    """The mark with the sizes and turns its copies were seen at, on a photo of this size."""
    return replace(wm, side=min(H, W), copies=len(copies), _cache={},
                   scales=(min(c.scale for c in copies), max(c.scale for c in copies)),
                   angles=(min(c.angle for c in copies), max(c.angle for c in copies)))


def _sayer(progress: Progress | None, cancelled: Cancelled | None, lo: float = 0.0, hi: float = 1.0):
    def say(f: float, text: str) -> None:
        if progress is not None:
            progress(lo + (hi - lo) * f, text)
        if cancelled is not None and cancelled():
            raise Stopped
    return say


def from_box(rgb: np.ndarray, box: tuple[int, int, int, int], progress: Progress | None = None,
             cancelled: Cancelled | None = None) -> Result:
    """The mark learned from the copy boxed on this photo (x0, y0, x1, y1 in its pixels) and every copy of it
    found there. Raises NoWatermark, Stopped."""
    say = _sayer(progress, cancelled)
    say(0.0, "Reading the boxed copy…")
    wm, boxed = rough(rgb, box)
    say(0.05, "Looking for copies…")
    space = [(s, a) for s in _grid(0.7, 1.45, SCALE_STEP, True) for a in _grid(-10, 10, ANGLE_STEP, False)]
    L = luminance(rgb)
    got = refine_all(rgb, wm, [boxed] + _coarse(L, wm, space, cancelled), L=L, check=False, fit=False,
                     cancelled=cancelled, coarse=max(1.0, max(wm.alpha.shape) / COARSE_PX))
    # The boxed copy matches itself best; judge the rest against the next best.
    others = [c for c in got if math.hypot(c.cx - boxed.cx, c.cy - boxed.cy) > 0.25 * max(wm.alpha.shape)]
    bar = max(0.2, 0.5 * max((c.score for c in others), default=0.0))
    seeds = [c for c in got if c not in others or c.score >= bar] or [boxed]
    wm, copies = _relearn(rgb, wm, seeds, say=_sayer(progress, cancelled, 0.25, 1.0), cancelled=cancelled)
    return Result(wm, copies, "box")


def _grown(rgb: np.ndarray, seed: Watermark, seeds: list[Copy], grow: int, say, cancelled: Cancelled | None) -> Result | None:
    """The photo's own mark grown from copies of a kept mark (or word), or None when what grew isn't
    believable: it needs two seeds at least (one copy alone can't tell the mark from the art under it), it
    must keep the seed's own strokes, and its opacity and ink must be the seed's kind (a bright line in the
    art grown into a "mark" is neither)."""
    if len(seeds) < 2:
        return None
    peak = float(seed.alpha.max())
    focus = seed.alpha > 0.15 * peak
    start = float(seed.alpha[focus].mean())
    try:
        grown, copies = _relearn(rgb, replace(seed, focus=focus), seeds, grow=grow, say=say, cancelled=cancelled)
    except NoWatermark:
        return None
    if grown.focus is None or not grown.focus.any() or float(grown.alpha[grown.focus].mean()) < 0.4 * start:
        return None
    if not 0.5 * peak <= float(grown.alpha.max()) <= 2.0 * peak:
        return None
    if float(np.abs(grown.colour - seed.colour).max()) > 45 or len(copies) < 2:
        return None
    return Result(replace(grown, key="", focus=None), copies, "grown")


def auto(rgb: np.ndarray, library: "Library", progress: Progress | None = None,
         cancelled: Cancelled | None = None) -> Result | None:
    """The mark on this photo found from what's been learned, or None. First the last few marks learned, as
    they are — the same words again ("same"; one with more words beside them is learned afresh, "grown");
    then the look of every mark learned (`by_look`): any words, one copy or many, anywhere ("style").
    Raises Stopped."""
    say = _sayer(progress, cancelled)
    H, W = rgb.shape[:2]
    L = luminance(rgb)
    marks = library.items[:4]
    best: tuple[float, Watermark, list[Copy]] | None = None
    for i, wm in enumerate(marks):
        say(0.3 * i / max(1, len(marks)), "Looking for your watermark…")
        cands = _coarse(L, wm, search_space(wm, H, W), cancelled, most=30)
        if cands and (best is None or cands[0].score > best[0]):
            best = (cands[0].score, wm, cands)
        if best is not None and best[0] >= 0.6:
            break
    if best is not None and best[0] >= 0.45:
        _top, wm, cands = best
        got = refine_all(rgb, wm, cands, L=L, check=False, cancelled=cancelled)
        good = [c for c in got if c.gain >= MIN_GAIN and c.score >= MIN_SCORE]
        if len(good) >= 2 and np.mean([c.score for c in good]) >= SAME and len(good) >= 0.6 * len(got):
            # The same words — unless there are more beside them ("John Meier" kept, "John Meier vea4t34fe"
            # here): read again with room round it; if it grows, it's new words, else the kept mark.
            length, height = _shape(wm.alpha)
            found = _grown(rgb, wm, good, int(0.6 * length + height), _sayer(progress, cancelled, 0.3, 0.6), cancelled)
            if found is None:
                return Result(_stats(wm, good, H, W), good, "same")
            before = int((wm.alpha > 0.3 * float(wm.alpha.max())).sum())
            after = int((found.wm.alpha > 0.3 * float(found.wm.alpha.max())).sum())
            if after <= 1.15 * before:
                return Result(replace(found.wm, key=wm.key), found.copies, "same")
            return found
    return by_look(rgb, library.styles(), _sayer(progress, cancelled, 0.4, 1.0), cancelled)


# -- the look of the mark, words aside ----------------------------------------------------------------

def style_of(wm: Watermark) -> Style | None:
    """A learned mark's look: ink, solid strokes' opacity, stroke width (twice the area over the outline),
    letter height (`_shape`) and the line's angle on screen, at the size its copies were seen at."""
    a = wm.alpha
    peak = float(a.max())
    if peak <= 0.02:
        return None
    mask = a > 0.35 * peak
    if mask.sum() < 30:
        return None
    inner = mask.copy()
    inner[1:, :] &= mask[:-1, :]
    inner[:-1, :] &= mask[1:, :]
    inner[:, 1:] &= mask[:, :-1]
    inner[:, :-1] &= mask[:, 1:]
    stroke = 2.0 * float(mask.sum()) / max(1.0, float((mask & ~inner).sum()))
    _length, height = _shape(a, wm.focus)
    size = math.sqrt(max(wm.scales[0], 1e-3) * max(wm.scales[1], 1e-3))
    turn = (wm.angles[0] + wm.angles[1]) / 2
    co, si = _rot(turn)
    ax, ay = wm.axis
    dx, dy = co * ax + si * ay, -si * ax + co * ay
    angle = math.degrees(math.atan2(-dy, dx))
    angle = angle - 180 if angle > 90 else angle + 180 if angle <= -90 else angle
    return Style(np.asarray(wm.colour, np.float32), float(np.percentile(a[a > 0.5 * peak], 75)),
                 stroke * size, height * size, angle, wm.side)


def _median(a: np.ndarray, size: int) -> np.ndarray:
    """A 2-D array's median over size × size (PIL's, on 8 bits — a level is plenty here)."""
    im = Image.fromarray(np.clip(np.rint(a), 0, 255).astype(np.uint8))
    return np.asarray(im.filter(ImageFilter.MedianFilter(size)), dtype=np.float32)


def _turned_off(angle: float, angles: list[float]) -> float:
    """How far a line's angle is from the nearest of `angles`, degrees (lines have no direction)."""
    return min(abs((angle - a + 90) % 180 - 90) for a in angles)


def detect(rgb: np.ndarray, styles: list[Style], cancelled: Cancelled | None = None) -> list[Line]:
    """Lines of watermark text found by their look alone — any words, any number of copies, anywhere.

    A see-through mark lightens what it covers towards its ink by its opacity: (pixel − art)/(ink − art) is
    the opacity, and for a white mark it's the same in every colour channel. So: the art under thin strokes
    is the photo's median over a window a little wider than the strokes; pixels whose reading against it is
    the kept marks' opacity (give or take — copies differ) are stroke centres, and their soft edges join
    them. Those are grouped (strokes closer than a third of the letters' height; a tangle of copies joined by
    a line in the art is split into the dense bands at the mark's angle), each line gathers what lies along
    it, and it's a line of the mark only if it has the mark's shape — letters' height and stroke width in
    range, at least four letter-sized pieces, five times longer than tall, text-like density, at a kept mark's
    angle, lifting the art by 5 levels or more — and its colour channels agree on one opacity read against a
    proper fill under it. A star is too bright and too small, a spark the wrong colour, a line in the art too
    thin and straight (taken out first, `_straight`), a cloud's edge not thin at all, a highlight too short."""
    styles = [st for st in styles if st is not None]
    if not styles:
        return []
    lines: list[Line] = []
    cache: dict = {}
    taken = np.zeros(rgb.shape[:2], bool)
    for look in _looks(styles):                  # each look with its own ranges, newest first
        sign = 1.0 if float(look.colour @ LUMA) >= 128 else -1.0
        lines += _detect(rgb, [look], sign, cancelled, cache, taken)
    return lines


def _looks(styles: list[Style]) -> list[Style]:
    """The kept marks' looks, alike ones merged (same ink, opacity within a third, letters within 30 %, angle
    within 8°) — each is looked for with its own ranges: pooled, a faint big mark and a strong small one
    would let through anything in between."""
    groups: list[list[Style]] = []
    for st in styles:
        for g in groups:
            o = g[0]
            if (float(np.abs(st.colour - o.colour).max()) < 40 and 0.75 < st.opacity / o.opacity < 1.33
                    and 0.77 < st.height / o.height < 1.3 and _turned_off(st.angle, [o.angle]) < 8):
                g.append(st)
                break
        else:
            groups.append([st])
    return [Style(np.median(np.stack([st.colour for st in g]), axis=0).astype(np.float32),
                  float(np.median([st.opacity for st in g])), float(np.median([st.stroke for st in g])),
                  float(np.median([st.height for st in g])), float(np.median([st.angle for st in g])), g[0].side)
            for g in groups]


_WHY: list | None = None                     # a test sets a list here to hear why lines were turned down


def _no(why: str, cx: float, cy: float, n: int) -> None:
    if _WHY is not None:
        _WHY.append((why, cx, cy, n))


def _detect(rgb: np.ndarray, styles: list[Style], sign: float, cancelled: Cancelled | None, cache: dict,
            taken: np.ndarray) -> list[Line]:
    H, W = rgb.shape[:2]
    priors = []
    for st in styles:
        priors.append((st, 1.0))
        ratio = min(H, W) / max(1, st.side)
        if abs(math.log(ratio)) > math.log(1.1):
            priors.append((st, ratio))
    heights = [st.height * p for st, p in priors]
    strokes_w = [st.stroke * p for st, p in priors]
    h_mid = float(np.median(heights))
    h_lo, h_hi = 0.55 * min(heights), 1.8 * max(heights)
    sw_lo, sw_hi = 0.35 * min(strokes_w), 1.8 * max(strokes_w)
    a_lo, a_hi = 0.55 * min(st.opacity for st in styles), 1.9 * max(st.opacity for st in styles)
    angles = [st.angle for st in styles]
    ink = np.median(np.stack([st.colour for st in styles]), axis=0).astype(np.float32)
    ink_l = float(ink @ LUMA)
    if "L" not in cache:
        cache["L"] = luminance(rgb)
    L = cache["L"]
    k = int(np.clip(2 * math.ceil(1.7 * max(strokes_w)) + 3, 5, 21)) | 1
    if ("bg", k) not in cache:
        cache[("bg", k)] = _median(L, k)
    bg = cache[("bg", k)]
    # Anything brighter than a mark can be — a line in the art, a star — would lift the median beside it and
    # make the mark's letters there read too faint: out, and the median again.
    room = ink_l - bg
    glare = retouch._grow(sign * (L - bg) > a_hi * np.abs(room), 1)
    if glare.any():
        key = ("bg2", k, round(a_hi, 3), round(ink_l), sign)
        if key not in cache:
            cache[key] = _median(np.where(glare, bg, L), k)
        bg = cache[key]
    if cancelled is not None and cancelled():
        raise Stopped
    lift = sign * (L - bg)
    room = ink_l - bg
    ok = np.abs(room) > 35                       # nearer the ink than that, texture reads as "mark"
    r = np.where(ok, (L - bg) / np.where(ok, room, 1.0), 0.0)
    core = ok & (r >= a_lo) & (r <= a_hi) & (lift > 3)
    weak = ok & (r >= 0.1 * a_lo) & (lift > 1.5)
    strokes = core | (retouch._grow(core, 2) & weak)

    # Lines in the art (long straight thin runs, not along the marks' own angles), found once for the photo.
    run = int(1.4 * h_hi)
    art_lines = retouch._grow(_straight(strokes, run, text=angles), 1)
    if cancelled is not None and cancelled():
        raise Stopped

    # Candidate lines: each group of strokes that's about the mark's size as it is; a bigger one (copies
    # joined to each other by a line in the art, or by busy texture) split into the dense bands at the
    # mark's angle, a letter tall.
    join = max(2, int(round(0.35 * h_mid)))
    labels, n = _components(retouch._grow(core, join))
    if n == 0:
        return []
    ys, xs = np.nonzero(core)
    lab = labels[ys, xs]
    order = np.argsort(lab, kind="stable")
    ys, xs, lab = ys[order], xs[order], lab[order]
    starts = np.flatnonzero(np.r_[True, lab[1:] != lab[:-1]])
    ends = np.r_[starts[1:], len(lab)]
    cands: list[tuple[float, float, float, float, float, int]] = []    # cx, cy, angle, length, height, pixels
    for s0, s1 in zip(starts, ends):
        if cancelled is not None and cancelled():
            raise Stopped
        if s1 - s0 < 30:
            continue
        gy, gx = ys[s0:s1].astype(np.float64), xs[s0:s1].astype(np.float64)
        rect = _rect_of(gx, gy)
        if rect is not None and rect[4] <= 1.25 * h_hi:
            cands.append(rect + (int(s1 - s0),))
        else:
            cands += _bands(gx, gy, angles, h_mid)

    out: list[Line] = []                         # `taken`: pixels of lines already found, never found twice
    for cx, cy, angle, length, height, _n in sorted(cands, key=lambda c: -c[5]):
        if cancelled is not None and cancelled():
            raise Stopped
        if any(math.hypot(cx - ln.cx, cy - ln.cy) < 0.4 * max(length, ln.length) and
               _turned_off(angle, [ln.angle]) < 10 for ln in out):
            continue                             # a line already taken
        if _turned_off(angle, angles) > 12 or length < max(2.0 * h_lo, 1.5 * height):
            _no(f"angle {angle:.0f} / short", cx, cy, _n)    # a star, a spark, a blob: not worth gathering
            continue
        # Everything along the line — out past gaps of up to a letter's height, so a word set apart from the
        # rest ("2019 q6eqzh") and letters that broke away come with it.
        reach = max(height, h_mid)
        cx, cy, length = _extend(core & ~taken, cx, cy, angle, length, 1.4 * reach, h_mid)
        local, lcore, y0, x0 = _in_rect(strokes, core, cx, cy, angle, length + 2 * reach, 1.6 * reach)
        if local is None:
            continue
        free = ~taken[y0:y0 + local.shape[0], x0:x0 + local.shape[1]]
        local &= free
        lcore &= free
        cut = art_lines[y0:y0 + local.shape[0], x0:x0 + local.shape[1]]     # lines in the art crossing it
        local &= ~cut
        lcore &= ~cut
        cy_, cx_ = np.nonzero(lcore)
        if len(cy_) < 30:
            _no("few core", cx, cy, len(cy_))
            continue
        rect = _rect_of(cx_ + x0 + 0.0, cy_ + y0 + 0.0)
        if rect is None:
            continue
        rcx, rcy, angle, length, height = rect
        if not h_lo <= height <= h_hi or length < 5.0 * max(height, 1.0):
            _no(f"shape h{height:.0f} l{length:.0f}", cx, cy, len(cy_))
            continue
        if _turned_off(angle, angles) > 12:
            _no(f"angle {angle:.0f}", cx, cy, len(cy_))
            continue
        if float(np.median(lift[y0:y0 + local.shape[0], x0:x0 + local.shape[1]][lcore])) < 5:
            _no("too faint", cx, cy, len(cy_))       # a few levels' lift is texture, not a mark
            continue
        inner = local.copy()
        inner[1:, :] &= local[:-1, :]
        inner[:-1, :] &= local[1:, :]
        inner[:, 1:] &= local[:, :-1]
        inner[:, :-1] &= local[:, 1:]
        sw = 2.0 * float(local.sum()) / max(1.0, float((local & ~inner).sum()))
        if not sw_lo <= sw <= sw_hi:
            _no(f"stroke {sw:.1f}", cx, cy, len(cy_))
            continue
        density = float(local.sum()) / max(1.0, length * max(height, 1.0) * 1.6)
        if not 0.08 <= density <= 0.75:
            _no(f"density {density:.2f}", cx, cy, len(cy_))
            continue
        letters, nl = _components(lcore)
        sizes = np.bincount(letters.ravel())[1:]
        letter = 0.07 * h_mid * h_mid            # the look's letters, not this line's (a row of star dots
        big = sizes >= letter                    # measures short, and would pass by its own measure)
        if nl < 4 or int(big.sum()) < 4 or float(np.median(sizes[sizes >= 6])) < letter:
            _no(f"letters {nl}", cx, cy, len(cy_))
            continue
        line = _line_alpha(rgb, local, lcore, y0, x0, ink, a_lo, a_hi)
        if line is None:
            _no("channels/opacity", cx, cy, len(cy_))
            continue
        alpha, opacity = line
        # Taken with a margin, so another look doesn't make a "line" of this one's soft edges.
        taken[y0:y0 + local.shape[0], x0:x0 + local.shape[1]] |= retouch._grow(local, max(2, int(round(0.4 * height))))
        out.append(Line(y0, x0, alpha, ink, rcx, rcy, length, height, angle, opacity))
    return out


def _rect_of(x: np.ndarray, y: np.ndarray) -> tuple[float, float, float, float, float] | None:
    """Stroke pixels' line: centre, angle on screen (rising positive, (−90, 90]), length (2nd–98th
    percentile along it) and height (the narrowest band across holding 80 % of them)."""
    if len(x) < 10:
        return None
    pts = np.stack([x, y]).astype(np.float64)
    mid = pts.mean(axis=1, keepdims=True)
    pts = pts - mid
    _ev, vec = np.linalg.eigh(np.cov(pts))
    along, across = np.sort(vec[:, 1] @ pts), np.sort(vec[:, 0] @ pts)
    kk = int(math.ceil(0.8 * len(across)))
    height = float(np.min(across[kk - 1:] - across[:len(across) - kk + 1]))
    length = float(np.percentile(along, 98) - np.percentile(along, 2))
    angle = math.degrees(math.atan2(-vec[1, 1], vec[0, 1]))
    angle = angle - 180 if angle > 90 else angle + 180 if angle <= -90 else angle
    return float(mid[0, 0]), float(mid[1, 0]), angle, length, height


def _bands(x: np.ndarray, y: np.ndarray, angles: list[float], h: float) -> list[tuple[float, float, float, float, float, int]]:
    """Lines inside a big tangle of stroke pixels: at each of the marks' angles (and 3° and 6° either side),
    the bands a letter and a third tall holding the most pixels, cut where they have a gap of more than a
    letter's height; runs at least two letters long."""
    out = []
    band = max(4, int(round(1.3 * h)))
    for base in angles:
        for d in (-6.0, -3.0, 0.0, 3.0, 6.0):
            t = math.radians(base + d)
            dx, dy = math.cos(t), -math.sin(t)
            u = x * dx + y * dy
            v = -x * dy + y * dx
            v0 = v.min()
            hist = np.bincount(np.floor(v - v0).astype(np.int64))
            win = np.convolve(hist, np.ones(band), mode="same")
            taken = np.zeros_like(win, dtype=bool)
            for peak in np.argsort(-win):
                if win[peak] < 30:
                    break
                if taken[max(0, peak - band):peak + band + 1].any():
                    continue
                taken[peak] = True
                sel = np.abs(v - (v0 + peak + 0.5)) <= band / 2
                us = np.sort(u[sel])
                if len(us) < 30:
                    continue
                cuts = np.flatnonzero(np.diff(us) > h) + 1
                for run in np.split(us, cuts):
                    if len(run) < 30 or run[-1] - run[0] < 2 * h:
                        continue
                    uc, vc = (run[0] + run[-1]) / 2, v0 + peak + 0.5
                    cx, cy = uc * dx - vc * dy, uc * dy + vc * dx
                    out.append((cx, cy, base + d, float(run[-1] - run[0]), float(band), len(run)))
    return out


def _extend(core: np.ndarray, cx: float, cy: float, angle: float, length: float, height: float,
            gap: float) -> tuple[float, float, float]:
    """A found line stretched along its own direction over the core pixels that continue it, across gaps of
    up to `gap`: its new centre and length."""
    H, W = core.shape
    t = math.radians(angle)
    dx, dy = math.cos(t), -math.sin(t)
    far = length / 2 + 6 * gap
    ex, ey = abs(dx) * far + abs(dy) * height / 2, abs(dy) * far + abs(dx) * height / 2
    x0, x1 = max(0, int(cx - ex)), min(W, int(cx + ex) + 1)
    y0, y1 = max(0, int(cy - ey)), min(H, int(cy + ey) + 1)
    ys, xs = np.nonzero(core[y0:y1, x0:x1])
    if len(ys) < 10:
        return cx, cy, length
    u = (xs + x0 - cx) * dx + (ys + y0 - cy) * dy
    v = -(xs + x0 - cx) * dy + (ys + y0 - cy) * dx
    u = np.sort(u[(np.abs(v) <= height / 2) & (np.abs(u) <= far)])
    if len(u) < 10:
        return cx, cy, length
    inside = np.abs(u) <= length / 2
    if not inside.any():
        return cx, cy, length
    lo_i, hi_i = int(np.argmax(inside)), len(u) - 1 - int(np.argmax(inside[::-1]))
    while lo_i > 0 and u[lo_i] - u[lo_i - 1] <= gap:
        lo_i -= 1
    while hi_i < len(u) - 1 and u[hi_i + 1] - u[hi_i] <= gap:
        hi_i += 1
    lo, hi = float(u[lo_i]), float(u[hi_i])
    mid = (lo + hi) / 2
    return cx + mid * dx, cy + mid * dy, max(length, hi - lo)


def _in_rect(strokes: np.ndarray, core: np.ndarray, cx: float, cy: float, angle: float, length: float,
             height: float) -> tuple[np.ndarray | None, np.ndarray, int, int]:
    """The stroke (and core) pixels inside a turned rectangle, on its bounding box: (strokes, core, y0, x0)."""
    H, W = strokes.shape
    t = math.radians(angle)
    dx, dy = math.cos(t), -math.sin(t)
    ex = abs(dx) * length / 2 + abs(dy) * height / 2
    ey = abs(dy) * length / 2 + abs(dx) * height / 2
    x0, x1 = max(0, int(cx - ex) - 2), min(W, int(cx + ex) + 3)
    y0, y1 = max(0, int(cy - ey) - 2), min(H, int(cy + ey) + 3)
    if x1 - x0 < 4 or y1 - y0 < 4:
        return None, core, 0, 0
    yy, xx = np.mgrid[y0:y1, x0:x1].astype(np.float64)
    u = (xx - cx) * dx + (yy - cy) * dy
    v = -(xx - cx) * dy + (yy - cy) * dx
    inside = (np.abs(u) <= length / 2) & (np.abs(v) <= height / 2)
    return strokes[y0:y1, x0:x1] & inside, core[y0:y1, x0:x1] & inside, y0, x0


def _line_alpha(rgb: np.ndarray, strokes: np.ndarray, core: np.ndarray, y0: int, x0: int, ink: np.ndarray,
                a_lo: float, a_hi: float) -> tuple[np.ndarray, float] | None:
    """A found line's opacity per colour channel, read against a smooth fill under its strokes, or None when
    its channels don't agree on one opacity in the mark's range (a coloured spark, a highlight). Inside the
    strokes it's held within ±30 % of the line's own (so a star under a stroke keeps most of itself); at the
    soft edges it follows the photo."""
    h, w = strokes.shape
    patch = rgb[y0:y0 + h, x0:x0 + w, :3].astype(np.float32)
    hole = retouch._grow(strokes, 2)
    bg = retouch._membrane(patch, hole)
    room = ink[None, None, :] - bg
    readable = np.abs(room) > 15
    seen = np.where(readable, (patch - bg) / np.where(readable, room, 1.0), 0.0)
    lum_room = float(ink @ LUMA) - bg @ LUMA
    lum_ok = np.abs(lum_room) > 15
    lum = np.where(lum_ok, (patch @ LUMA - bg @ LUMA) / np.where(lum_ok, lum_room, 1.0), 0.0)
    at = core & lum_ok
    if at.sum() < 20:
        return None
    level = float(np.median(lum[at]))
    if not a_lo <= level <= a_hi:
        return None
    alpha = np.zeros((h, w, 3), np.float32)
    for c in range(3):
        sel = core & readable[..., c]
        lc = float(np.median(seen[..., c][sel])) if sel.sum() >= 20 else level
        if abs(lc - level) > 0.35 * level + 0.02:
            return None                          # the channels disagree: not a mark of this ink
        alpha[..., c] = np.where(core, np.clip(seen[..., c], 0.7 * lc, 1.3 * lc),
                                 np.where(strokes, np.clip(seen[..., c], 0.0, 1.3 * lc), 0.0))
        alpha[..., c] = np.where(readable[..., c], alpha[..., c], np.where(strokes, lc * strokes, 0.0))
    return np.clip(alpha, 0.0, MAX_ALPHA), level


def _covered(line: Line, wm: Watermark, copies: list[Copy], H: int, W: int) -> bool:
    """Whether a found line is one of the copies (its centre inside a copy's box)."""
    for c in copies:
        b = _bounds(wm, c, H, W, pad=0)
        if b is not None and b[0] <= line.cy < b[2] and b[1] <= line.cx < b[3]:
            return True
    return False


def by_look(rgb: np.ndarray, styles: list[Style], progress: Progress | None = None,
            cancelled: Cancelled | None = None) -> Result | None:
    """The mark found by its look (`detect`) — any words, any number of copies — or None. When the piece has
    the same words three times or more (lines of about one length), the clearest is used as a box to learn
    them (`from_box`): with many copies the median template takes each out more exactly than reading each
    line for itself. That's kept only when its copies are most of those lines; lines it doesn't cover are
    taken out by their look."""
    say = _sayer(progress, cancelled)
    say(0.0, "Looking for your watermark by its look…")
    lines = detect(rgb, styles, cancelled)
    if not lines:
        return None
    H, W = rgb.shape[:2]
    best = max(lines, key=lambda ln: ln.opacity * ln.length)
    alike = [ln for ln in lines if 0.8 < ln.length / best.length < 1.25 and 0.8 < ln.height / best.height < 1.25]
    if len(alike) >= 3:
        h, w = best.alpha.shape[:2]
        m = int(0.1 * max(h, w))
        try:
            learned = from_box(rgb, (best.x0 - m, best.y0 - m, best.x0 + w + m, best.y0 + h + m),
                               progress=_sayer(progress, cancelled, 0.3, 1.0), cancelled=cancelled)
        except NoWatermark:
            learned = None
        if learned is not None and len(learned.copies) >= 3:
            covered = [ln for ln in alike if _covered(ln, learned.wm, learned.copies, H, W)]
            if len(covered) >= 0.7 * len(alike):
                rest = [ln for ln in lines if not _covered(ln, learned.wm, learned.copies, H, W)]
                return Result(learned.wm, learned.copies, "style", rest, styles)
    return Result(None, [], "style", lines, styles)


# -- taking it out -----------------------------------------------------------------------------------

def matte(rgb: np.ndarray, wm: Watermark, c: Copy) -> tuple[int, int, np.ndarray] | None:
    """The copy's own opacity per colour channel, read from the photo and held near the template's:
    (y0, x0, α (h, w, 3)). Each channel is read as (pixel − background) / (ink − background), the background
    a smooth fill under the strokes, and kept between the template's 3×3 minimum and maximum (± a fifth):
    free by a pixel at the edges, where copies differ, close inside the strokes, where a star or spark
    under the mark would otherwise read as more mark. Where the background is too near the ink to read (a
    white mark on white), the template is used as it is."""
    H, W = rgb.shape[:2]
    r = opacity(wm, c, H, W, pad=6)
    if r is None:
        return None
    y0, x0, t = r
    peak = float(t.max())
    if peak <= 0.005:
        return None
    patch = rgb[y0:y0 + t.shape[0], x0:x0 + t.shape[1], :3].astype(np.float32)
    slack = 1 if c.scale < 1.6 else 2
    hole = retouch._grow(t > 0.02 * peak, slack + 1)
    bg = retouch._membrane(patch, hole)
    ink = np.asarray(wm.colour, np.float32)
    gains = c.gains or (c.gain, c.gain, c.gain)
    out = np.zeros(t.shape + (3,), np.float32)
    for k in range(3):
        tk = t * (gains[k] / c.gain) if c.gain > 1e-6 else t
        room = ink[k] - bg[..., k]
        readable = np.abs(room) > 12
        seen = np.where(readable, (patch[..., k] - bg[..., k]) / np.where(readable, room, 1.0), 0.0)
        lo = _extreme(tk, slack, np.minimum) * 0.8
        hi = _extreme(tk, slack, np.maximum) * 1.2 + 0.004
        out[..., k] = np.where(hole, np.where(readable, np.clip(seen, lo, hi), tk), 0.0)
    return y0, x0, np.clip(out, 0.0, MAX_ALPHA)


def coverage(rgb: np.ndarray, wm: Watermark, copies: list[Copy]) -> np.ndarray:
    """The copies' combined opacity on the photo, per colour channel (h, w, 3)."""
    H, W = rgb.shape[:2]
    A = np.zeros((H, W, 3), np.float32)
    for c in copies:
        r = matte(rgb, wm, c)
        if r is None:
            continue
        y0, x0, a = r
        sub = A[y0:y0 + a.shape[0], x0:x0 + a.shape[1]]
        sub[...] = 1 - (1 - sub) * (1 - a)
    return np.minimum(A, MAX_ALPHA)


def remove(rgb: np.ndarray, wm: Watermark, copies: list[Copy]) -> tuple[np.ndarray, np.ndarray]:
    """The photo (float RGB or RGBA, 0–255) with the copies taken out, and where it changed."""
    A = coverage(rgb, wm, copies)
    out = np.array(rgb, dtype=np.float32, copy=True)
    out[..., :3] = np.clip((out[..., :3] - A * wm.colour[None, None, :]) / (1 - A), 0, 255)
    return out, A.max(axis=-1) > 0.01


def remove_result(rgb: np.ndarray, result: Result) -> tuple[np.ndarray, np.ndarray]:
    """The photo with everything in `result` taken out — the mark's copies, then the lines found by look —
    and where it changed."""
    out = np.array(rgb, dtype=np.float32, copy=True)
    changed = np.zeros(rgb.shape[:2], bool)
    if result.wm is not None and result.copies:
        out, changed = remove(out, result.wm, result.copies)
    for ln in result.lines:
        h, w = ln.alpha.shape[:2]
        sub = out[ln.y0:ln.y0 + h, ln.x0:ln.x0 + w, :3]
        a = ln.alpha[:sub.shape[0], :sub.shape[1]]
        sub[...] = np.clip((sub - a * ln.colour[None, None, :]) / (1 - a), 0, 255)
        changed[ln.y0:ln.y0 + h, ln.x0:ln.x0 + w] |= a.max(axis=-1) > 0.01
    return out, changed


def can_clean(path: str) -> bool:
    return batch_crop.can_crop(path)


def _made_here(path: str) -> bool:
    """A photo this tool saved as new ("name (no watermark).jpg", "… (no watermark 2).jpg")."""
    stem = os.path.splitext(os.path.basename(path))[0]
    return stem.endswith(f"({NEW_LABEL})") or (stem.endswith(")") and f"({NEW_LABEL} " in stem)


def photos_in(paths: list[str], stop: Callable[[], bool] = lambda: False) -> list[str]:
    """The photos among `paths` and inside any folders among them (every subfolder; hidden items skipped), in
    order, each once — leaving out what this tool already saved as new, so running it again on a folder
    doesn't work on its own results."""
    out: list[str] = []
    seen: set[str] = set()

    def take(p: str) -> None:
        if p not in seen and can_clean(p) and not _made_here(p):
            seen.add(p)
            out.append(p)
    for path in paths:
        if stop():
            break
        if os.path.isdir(path):
            for root, dirs, files in os.walk(path):
                dirs[:] = sorted((d for d in dirs if not d.startswith(".")), key=str.lower)
                for name in sorted(files, key=str.lower):
                    if not name.startswith("."):
                        take(os.path.join(root, name))
                if stop():
                    break
        else:
            take(path)
    return out


def open_photo(path: str, longest: int = WORK_SIDE) -> tuple[np.ndarray, float]:
    """The photo upright as float RGB (0–255), at most `longest` on a side, and how much bigger the photo
    itself is (1 when it wasn't shrunk). Raises CropError."""
    src = batch_crop.open_upright(path)
    im = src.image.convert("RGB")
    full = max(im.size)
    if longest and full > longest:
        im.thumbnail((longest, longest), Image.Resampling.LANCZOS)
    return np.asarray(im, dtype=np.float32), full / max(im.size)


def clean(path: str, result: Result, factor: float = 1.0, *, as_new: bool = False) -> str:
    """Takes the copies in `result` (found on the photo shrunk by 1/`factor`) off the photo — in place, or into
    a new photo beside it. Returns where it went. Raises CropError or OSError and leaves the photo as it was."""
    src = batch_crop.open_upright(path)
    im = src.image
    mode = im.mode
    has_alpha = mode in ("RGBA", "LA", "PA") or (mode == "P" and "transparency" in im.info)
    work = im.convert("RGBA" if has_alpha else "RGB")
    pixels = np.asarray(work, dtype=np.float32)
    lines = result.lines
    if lines and factor != 1:                    # found on a smaller copy: found again at full size, near there
        again = detect(pixels, result.styles)
        lines = [ln for ln in again if any(math.hypot(ln.cx - o.cx * factor, ln.cy - o.cy * factor)
                                           < 0.5 * o.length * factor for o in lines)]
    out, _changed = remove_result(pixels, replace(result, copies=scaled(result.copies, factor), lines=lines))
    picture = Image.fromarray(np.rint(out).astype(np.uint8), work.mode)
    if mode in ("L", "LA", "I;16", "I", "1"):
        picture = picture.convert("LA" if has_alpha else "L")
    data = batch_crop.encode_like(src, picture)
    if as_new:
        return batch_crop.write_beside(path, data, NEW_LABEL)
    batch_crop.write_in_place(path, data)
    return path


# -- the library of marks ----------------------------------------------------------------------------

class Library:
    """The marks learned so far, newest (or most recently used) first, each in its own file."""

    def __init__(self, folder: Path = LIBRARY) -> None:
        self.folder = folder
        self.items: list[Watermark] = []
        self._words: dict = {}                   # per mark: its words, and ("style", key): its look
        self.load()

    def load(self) -> None:
        found = []
        try:
            files = list(self.folder.glob("*.npz"))
        except OSError:
            files = []
        for f in files:
            wm = _read(f)
            if wm is not None:
                try:
                    found.append((f.stat().st_mtime, wm))
                except OSError:
                    continue
        self.items = [wm for _t, wm in sorted(found, key=lambda t: -t[0])]

    def add(self, wm: Watermark) -> Watermark:
        """Keeps a newly learned mark (first in line); the least recently used beyond LIBRARY_MAX go."""
        wm = replace(wm, key=wm.key if wm.key and "#" not in wm.key else f"wm-{uuid.uuid4().hex[:12]}",
                     focus=None, _cache={})
        self.folder.mkdir(parents=True, exist_ok=True)
        _write(wm, self.folder / f"{wm.key}.npz")
        self.items = [wm] + [w for w in self.items if w.key != wm.key]
        for old in self.items[LIBRARY_MAX:]:
            self.forget(old)
        return wm

    def touch(self, wm: Watermark | None) -> None:
        """A kept mark was just used: first in line (and kept longest)."""
        if wm is None:
            return
        for i, w in enumerate(self.items):
            if w.key == wm.key:
                self.items.insert(0, self.items.pop(i))
                try:
                    os.utime(self.folder / f"{wm.key}.npz", (time.time(), time.time()))
                except OSError:
                    pass
                return

    def forget(self, wm: Watermark) -> None:
        self.items = [w for w in self.items if w.key != wm.key]
        self._words.pop(wm.key, None)
        self._words.pop(("style", wm.key), None)
        try:
            (self.folder / f"{wm.key}.npz").unlink()
        except OSError:
            pass

    def clear(self) -> None:
        for wm in list(self.items):
            self.forget(wm)

    def styles(self) -> list[Style]:
        """How the kept marks look (cached), the newest marks' first."""
        out = []
        for wm in self.items[:12]:
            if ("style", wm.key) not in self._words:
                self._words[("style", wm.key)] = [st for st in [style_of(wm)] if st is not None]
            out.extend(self._words[("style", wm.key)])
        return out

def _write(wm: Watermark, path: Path) -> None:
    meta = {"side": wm.side, "copies": wm.copies, "scales": list(wm.scales), "angles": list(wm.angles),
            "colour": [float(v) for v in wm.colour], "key": wm.key, "version": 1}
    tmp = path.with_name(f".{path.stem}.{uuid.uuid4().hex[:8]}.npz")
    try:
        np.savez_compressed(tmp, alpha=wm.alpha.astype(np.float32), meta=np.array(json.dumps(meta)))
        os.replace(tmp, path)
    finally:
        if tmp.exists():
            tmp.unlink()


def _read(path: Path) -> Watermark | None:
    try:
        with np.load(path, allow_pickle=False) as z:
            alpha = np.asarray(z["alpha"], dtype=np.float32)
            meta = json.loads(str(z["meta"]))
        return _parted(Watermark(alpha, np.asarray(meta["colour"], np.float32), int(meta["side"]),
                                  tuple(float(v) for v in meta["scales"]), tuple(float(v) for v in meta["angles"]),
                                  int(meta["copies"]), key=str(meta.get("key") or path.stem)))
    except (OSError, KeyError, ValueError, TypeError):
        return None
