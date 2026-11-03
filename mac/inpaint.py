"""Remove an object from a photo — Safe Finder's Remove Objects (remove_window.py): the area drawn around it
is filled with the photo itself, as TouchRetouch does. No Qt here, so it's testable on its own.

**How.** Exemplar-based completion — the method behind Photoshop's Content-Aware Fill (Wexler, Shechtman &
Irani 2007, with Barnes et al.'s PatchMatch, 2009, for the search). Every 7×7 patch that touches the hole is
matched to the most alike patch elsewhere in the photo (wholly outside the hole); each hole pixel is then the
weighted vote of all the matched patches that cover it, the votes weighted by how good each match is. Matching
and voting alternate until they settle, coarse to fine through an image pyramid: the coarse levels decide what
goes where (a horizon, a wall, sky), the fine ones bring the texture. What fills the hole is real texture and
grain from the photo — not a smooth smear — and it lines up with what's around it.

- **The search** (PatchMatch, run for all patches at once with numpy): random first guesses, then each patch
  tries what its neighbours found (1, 2, 4 and 8 pixels away — matches come in coherent runs, so a good one
  spreads), then random tries around its own best in shrinking circles. A level starts from the coarser
  level's matches, scaled up.
- **Distance** is the summed squared difference of the patches' colours (at fine levels on every other pixel
  of the patch — the votes still use all 49). Votes are weighted exp(−d / 2σ²), σ² from this round's distances.
- **Big holes** are worked at a smaller size — the hole's long side at most `HOLE_MAX` pixels — and brought
  back to full size by following the matches: each pixel is copied from where its match points, in the
  original photo, averaged over its 3×3 neighbours' matches (so seams between matches blend); the low
  frequencies come from the worked result (so the copy can't drift in brightness). The detail is the photo's
  own, at full resolution.
- **The edges.** What's drawn is grown by a couple of pixels (an object's soft edge and halo go with it), and
  the fill is blended into the photo over a 2-pixel ramp.
- Only the area around the hole is worked on (a margin of 1½× its size, more for small holes), so a 48 MP
  photo costs what its surroundings cost.

`remove()` takes an RGB array and a boolean mask and returns the RGB array with the masked area replaced.
Typical objects (a person, a sign, a bin) take a few seconds; `progress(fraction)` is called as it goes and
`cancelled()` is checked between rounds.
"""
from __future__ import annotations

from typing import Callable

import numpy as np

import retouch

RADIUS = 3                       # 7×7 patches
HOLE_MAX = 280                   # the hole's long side at the finest level worked on (bigger holes: worked smaller)
COARSEST = 20                    # the pyramid goes down until the hole's long side is about this
CONFIDENCE = 0.8                 # a vote counts this much less per pixel its patch sits deeper in the hole
CHUNK = 24576                    # patches compared at a time (memory)
FULL_PATCHES = 12000             # up to this many patches every pixel of each is compared; above, every other
_RNG_SEED = 7


def _grow(mask: np.ndarray, r: int) -> np.ndarray:
    return retouch._grow(mask, r) if r > 0 else mask.copy()


def _down(img: np.ndarray, hole: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """Half size: each 2×2 block the average of its known pixels; unknown when any of the four is (so the
    coarse hole always covers the fine one)."""
    h, w = hole.shape
    ph, pw = h + h % 2, w + w % 2
    k = np.pad((~hole).astype(np.float32), ((0, ph - h), (0, pw - w)))
    v = np.pad(img, ((0, ph - h), (0, pw - w), (0, 0)), mode="edge") * k[..., None]
    s = v[0::2, 0::2] + v[1::2, 0::2] + v[0::2, 1::2] + v[1::2, 1::2]
    c = k[0::2, 0::2] + k[1::2, 0::2] + k[0::2, 1::2] + k[1::2, 1::2]
    hp = np.pad(hole, ((0, ph - h), (0, pw - w)), constant_values=False)
    small_hole = hp[0::2, 0::2] | hp[1::2, 0::2] | hp[0::2, 1::2] | hp[1::2, 1::2]
    small = s / np.maximum(c, 1e-6)[..., None]
    return small.astype(np.float32), small_hole


def _resize(img: np.ndarray, h: int, w: int) -> np.ndarray:
    """Bilinear resize of an (h, w, c) float array (no Pillow round trip — keeps float precision)."""
    H, W = img.shape[:2]
    if (H, W) == (h, w):
        return img.copy()
    ys = (np.arange(h, dtype=np.float32) + 0.5) * (H / h) - 0.5
    xs = (np.arange(w, dtype=np.float32) + 0.5) * (W / w) - 0.5
    y0 = np.clip(np.floor(ys).astype(np.int64), 0, H - 1)
    x0 = np.clip(np.floor(xs).astype(np.int64), 0, W - 1)
    y1, x1 = np.minimum(y0 + 1, H - 1), np.minimum(x0 + 1, W - 1)
    fy = np.clip(ys - y0, 0, 1)[:, None, None]
    fx = np.clip(xs - x0, 0, 1)[None, :, None]
    a = img[y0][:, x0] * (1 - fx) + img[y0][:, x1] * fx
    b = img[y1][:, x0] * (1 - fx) + img[y1][:, x1] * fx
    return (a * (1 - fy) + b * fy).astype(np.float32)


def _shrink_mask(mask: np.ndarray, h: int, w: int) -> np.ndarray:
    """A mask at a smaller size, covering everything the big one covers."""
    H, W = mask.shape
    ys, xs = np.nonzero(mask)
    out = np.zeros((h, w), bool)
    if len(ys):
        out[(ys * h) // H, (xs * w) // W] = True
    return out


class _Level:
    """One pyramid level's matching: target patch centres (every patch touching the hole), where sources may
    sit (patches wholly outside it), and the current matches."""

    def __init__(self, img: np.ndarray, hole: np.ndarray, rng: np.random.Generator) -> None:
        self.img, self.hole, self.rng = img, hole, rng
        self.h, self.w = hole.shape
        r = RADIUS
        self.ty, self.tx = np.nonzero(_grow(hole, r))
        self.n = len(self.ty)
        src = ~_grow(hole, r)
        src[:r], src[-r:], src[:, :r], src[:, -r:] = False, False, False, False
        self.src = src
        self.vy, self.vx = np.nonzero(src)
        self.grid = np.full((self.h, self.w), -1, np.int64)
        self.grid[self.ty, self.tx] = np.arange(self.n)
        # How deep each patch centre sits in the hole: what's next to the photo is surer than the middle, so the
        # edges lead (a line or a horizon carries in from where it meets the hole, rather than drifting).
        depth = np.zeros((self.h, self.w), np.float32)
        layer, d = hole.copy(), 0
        while layer.any() and d < 64:
            d += 1
            depth[layer] = d
            layer = layer & ~_grow(~layer, 1)
        self.conf = (CONFIDENCE ** depth[self.ty, self.tx]).astype(np.float64)
        self.wp = self.w + 2 * r
        offs = [(dy, dx) for dy in range(-r, r + 1) for dx in range(-r, r + 1)]
        self.vote_offs = np.array(offs, np.int64)
        sparse = [(dy, dx) for dy, dx in offs if (dy % 2 == 1 and dx % 2 == 1) or (dy, dx) == (0, 0)]
        self.dist_offs = np.array(offs if self.n < FULL_PATCHES else sparse, np.int64)
        self.flat_offs = self.dist_offs[:, 0] * self.wp + self.dist_offs[:, 1]
        self.sy = self.sx = self.d = None

    @property
    def usable(self) -> bool:
        return self.n > 0 and len(self.vy) > 0

    # -- the matches
    def random_init(self) -> None:
        pick = self.rng.integers(0, len(self.vy), self.n)
        self.sy, self.sx = self.vy[pick].copy(), self.vx[pick].copy()

    def init_from(self, coarse: "_Level", sy_c: np.ndarray, sx_c: np.ndarray) -> None:
        """Start from the coarser level's matches, scaled up (each fine patch takes its coarse parent's, shifted
        by where it sits in the parent); an invalid one gets a random source."""
        cy = np.minimum(self.ty // 2, coarse.h - 1)
        cx = np.minimum(self.tx // 2, coarse.w - 1)
        j = coarse.grid[cy, cx]
        sy = np.where(j >= 0, 2 * sy_c[np.maximum(j, 0)] + (self.ty % 2), -1)
        sx = np.where(j >= 0, 2 * sx_c[np.maximum(j, 0)] + (self.tx % 2), -1)
        ok = (sy >= 0) & (sy < self.h) & (sx >= 0) & (sx < self.w)
        ok[ok] = self.src[sy[ok], sx[ok]]
        pick = self.rng.integers(0, len(self.vy), self.n)
        self.sy = np.where(ok, sy, self.vy[pick])
        self.sx = np.where(ok, sx, self.vx[pick])

    def _padded(self) -> np.ndarray:
        r = RADIUS
        return np.pad(self.img, ((r, r), (r, r), (0, 0)), mode="edge").reshape(-1, self.img.shape[2])

    def _dist(self, flat: np.ndarray, tvec: np.ndarray, idx: np.ndarray, sy: np.ndarray, sx: np.ndarray) -> np.ndarray:
        """Distances between target patches `idx` (their vectors in `tvec`) and sources (sy, sx)."""
        r = RADIUS
        out = np.empty(len(idx), np.float32)
        for a in range(0, len(idx), CHUNK):
            b = min(a + CHUNK, len(idx))
            base = (sy[a:b] + r) * self.wp + (sx[a:b] + r)
            sv = flat[base[:, None] + self.flat_offs[None, :]]
            diff = sv - tvec[idx[a:b]]
            out[a:b] = np.einsum("nkc,nkc->n", diff, diff)
        return out

    def _try(self, flat, tvec, idx, sy, sx) -> None:
        """Takes the candidates (sy, sx) for targets `idx` where they're better than the current match."""
        if not len(idx):
            return
        d = self._dist(flat, tvec, idx, sy, sx)
        better = d < self.d[idx]
        i = idx[better]
        self.sy[i], self.sx[i], self.d[i] = sy[better], sx[better], d[better]

    def search(self, rounds: int, jumps=(8, 4, 2, 1)) -> None:
        r = RADIUS
        flat = self._padded()
        base_t = (self.ty + r) * self.wp + (self.tx + r)
        tvec = np.empty((self.n, len(self.flat_offs), flat.shape[1]), np.float32)
        for a in range(0, self.n, CHUNK):
            b = min(a + CHUNK, self.n)
            tvec[a:b] = flat[base_t[a:b, None] + self.flat_offs[None, :]]
        everyone = np.arange(self.n)
        self.d = self._dist(flat, tvec, everyone, self.sy, self.sx)
        for _ in range(rounds):
            for step in jumps:                                  # propagation: what a neighbour found, shifted
                for dy, dx in ((0, step), (0, -step), (step, 0), (-step, 0)):
                    ny, nx = self.ty + dy, self.tx + dx
                    inside = (ny >= 0) & (ny < self.h) & (nx >= 0) & (nx < self.w)
                    j = np.full(self.n, -1, np.int64)
                    j[inside] = self.grid[ny[inside], nx[inside]]
                    has = j >= 0
                    cy = np.where(has, self.sy[np.maximum(j, 0)] - dy, -1)
                    cx = np.where(has, self.sx[np.maximum(j, 0)] - dx, -1)
                    ok = has & (cy >= 0) & (cy < self.h) & (cx >= 0) & (cx < self.w)
                    ok[ok] = self.src[cy[ok], cx[ok]]
                    idx = everyone[ok]
                    self._try(flat, tvec, idx, cy[ok], cx[ok])
            radius = max(self.h, self.w)
            while radius >= 1:                                  # random search, in shrinking circles
                cy = self.sy + self.rng.integers(-radius, radius + 1, self.n)
                cx = self.sx + self.rng.integers(-radius, radius + 1, self.n)
                cy, cx = np.clip(cy, 0, self.h - 1), np.clip(cx, 0, self.w - 1)
                ok = self.src[cy, cx]
                self._try(flat, tvec, everyone[ok], cy[ok], cx[ok])
                radius //= 2

    def copy_centres(self) -> None:
        """The last word, at full detail: each hole pixel copied from its own match's centre — a real pixel of
        the photo, its grain and all (averaging the votes softens grain). Coherent runs of matches copy
        whole stretches of the photo intact."""
        inside = self.hole[self.ty, self.tx]
        out = self.img.copy()
        out[self.ty[inside], self.tx[inside]] = self.img[self.sy[inside], self.sx[inside]]
        self.img = out

    def vote(self) -> None:
        """Each hole pixel: the weighted average of what every matched patch covering it says."""
        h, w, c = self.img.shape
        hole_idx = np.full(h * w, -1, np.int64)
        hy, hx = np.nonzero(self.hole)
        hole_idx[hy * w + hx] = np.arange(len(hy))
        k = len(self.flat_offs)
        sigma2 = max(float(np.percentile(self.d, 70)) / max(k, 1), 1.0)
        weight = np.exp(-(self.d / max(k, 1)) / (2 * sigma2)).astype(np.float64) * self.conf + 1e-12
        acc = np.zeros((len(hy), c), np.float64)
        wsum = np.zeros(len(hy), np.float64)
        flat = self.img.reshape(-1, c)
        for dy, dx in self.vote_offs:
            qy, qx = self.ty + dy, self.tx + dx
            inside = (qy >= 0) & (qy < h) & (qx >= 0) & (qx < w)
            q = np.full(self.n, -1, np.int64)
            q[inside] = hole_idx[qy[inside] * w + qx[inside]]
            m = q >= 0
            if not m.any():
                continue
            src = (self.sy[m] + dy) * w + (self.sx[m] + dx)
            wm = weight[m]
            wsum += np.bincount(q[m], weights=wm, minlength=len(hy))
            vals = flat[src]
            for ch in range(c):
                acc[:, ch] += np.bincount(q[m], weights=wm * vals[:, ch], minlength=len(hy))
        filled = wsum > 0
        out = self.img.copy()
        sel = (hy[filled], hx[filled])
        out[sel] = (acc[filled] / wsum[filled, None]).astype(np.float32)
        self.img = out


def _complete(img: np.ndarray, hole: np.ndarray, progress: Callable[[float], None] | None,
              cancelled: Callable[[], bool] | None, rng: np.random.Generator) -> tuple[np.ndarray, "_Level | None"]:
    """`img` with `hole` filled by multi-scale patch completion. Returns the result and the finest level (its
    matches lead the way back up to full size)."""
    levels = [(img, hole)]
    while True:
        a, m = levels[-1]
        ys, xs = np.nonzero(m)
        side = max(ys.max() - ys.min(), xs.max() - xs.min()) + 1 if len(ys) else 0
        if side <= COARSEST or min(a.shape[:2]) < 4 * (2 * RADIUS + 1):
            break
        levels.append(_down(a, m))
    work_total = sum(4.0 ** -i for i in range(len(levels)))     # finer levels cost more
    done = 0.0
    coarse_level: _Level | None = None
    current = None
    for depth in range(len(levels) - 1, -1, -1):
        a, m = levels[depth]
        if current is None:
            start = retouch._membrane(a, m)                      # the coarsest: a smooth first guess
        else:
            up = _resize(current, *m.shape)
            start = a.copy()
            start[m] = up[m]
        level = _Level(start, m, rng)
        if not level.usable:
            current = start
            coarse_level = None
            continue
        if coarse_level is not None and coarse_level.sy is not None:
            level.init_from(coarse_level, coarse_level.sy, coarse_level.sx)
            # The finer level starts from its own pixels, copied along the coarse matches scaled up — not from
            # the coarse picture enlarged: matched against that blur, a thin line or an edge comes out a row off,
            # and the next level doubles it.
            level.d = np.zeros(level.n, np.float32)
            level.vote()
        else:
            level.random_init()
        steps = 3 if depth == 0 else (8 if depth == len(levels) - 1 else 5)
        for step in range(steps):
            if cancelled is not None and cancelled():
                return level.img, level
            level.search(rounds=2 if step == 0 else 1, jumps=(8, 4, 2, 1) if step == 0 else (2, 1))
            level.vote()
            if depth == 0 and step == steps - 1:
                level.search(rounds=1, jumps=(2, 1))         # matched against the settled fill…
                level.copy_centres()                         # …then real pixels, not averages
            if progress is not None:
                progress(min(0.97, (done + (4.0 ** -depth) * (step + 1) / steps) / work_total))
        done += 4.0 ** -depth
        current = level.img
        coarse_level = level
    return current, coarse_level


def _box(a: np.ndarray, r: int) -> np.ndarray:
    return retouch._box_blur(a, r) if r > 0 else a


def _to_full(orig: np.ndarray, hole: np.ndarray, worked: np.ndarray, level: "_Level", scale: float) -> np.ndarray:
    """A hole worked at `scale` (< 1) brought back to full size: each pixel copied from where its match points
    in the original, averaged over its 3×3 neighbours' matches; the low frequencies from the worked result."""
    h, w = hole.shape
    out = orig.copy()
    hy, hx = np.nonzero(hole)
    if not len(hy):
        return out
    wh, ww = level.hole.shape
    off_y = np.zeros((wh, ww), np.float32)
    off_x = np.zeros((wh, ww), np.float32)
    have = np.zeros((wh, ww), bool)
    off_y[level.ty, level.tx] = level.sy - level.ty
    off_x[level.ty, level.tx] = level.sx - level.tx
    have[level.ty, level.tx] = True
    acc = np.zeros((len(hy), orig.shape[2]), np.float64)
    n = np.zeros(len(hy), np.float64)
    for ddy in (-1, 0, 1):
        for ddx in (-1, 0, 1):
            wy = np.clip(np.floor((hy + ddy / scale) * scale).astype(np.int64), 0, wh - 1)
            wx = np.clip(np.floor((hx + ddx / scale) * scale).astype(np.int64), 0, ww - 1)
            ok = have[wy, wx]
            sy = np.rint(hy + off_y[wy, wx] / scale).astype(np.int64)
            sx = np.rint(hx + off_x[wy, wx] / scale).astype(np.int64)
            ok &= (sy >= 0) & (sy < h) & (sx >= 0) & (sx < w)
            ok[ok] = ~hole[sy[ok], sx[ok]]
            acc[ok] += orig[sy[ok], sx[ok]]
            n[ok] += 1
    copied = out.copy()
    big = _resize(worked, h, w)
    got = n > 0
    copied[hy[got], hx[got]] = (acc[got] / n[got, None]).astype(np.float32)
    copied[hy[~got], hx[~got]] = big[hy[~got], hx[~got]]
    # Keep the worked result's low frequencies (brightness, colour, shapes) and the copies' detail.
    r = max(2, int(round(6 / scale)))                      # wide: only brightness and colour drift, not detail
    low_fix = _box(big, r) - _box(copied, r)
    out[hole] = copied[hole] + low_fix[hole]
    return out


def remove_region(rgb: np.ndarray, mask: np.ndarray, progress: Callable[[float], None] | None = None,
                  cancelled: Callable[[], bool] | None = None, grow: int | None = None,
                  seed: int = _RNG_SEED) -> tuple[int, int, np.ndarray] | None:
    """What `mask` covers in `rgb` (h, w, 3, uint8) removed — as (y0, x0, the changed region, uint8): only the
    area around the hole is worked on (and returned), so a 48 MP photo costs what its surroundings cost and an
    undo step is that region alone. None when the mask is empty. `grow`: pixels the mask is grown by first
    (default: a little, for the object's soft edge and halo)."""
    mask = np.asarray(mask, bool)
    if not mask.any():
        return None
    h, w = mask.shape
    g = grow if grow is not None else max(2, int(round(min(h, w) * 0.0025)))
    ys, xs = np.nonzero(mask)
    side = max(ys.max() - ys.min(), xs.max() - xs.min()) + 1 + 2 * g
    margin = int(max(64, 1.5 * side)) + g
    y0, y1 = max(0, ys.min() - margin), min(h, ys.max() + margin + 1)
    x0, x1 = max(0, xs.min() - margin), min(w, xs.max() + margin + 1)
    roi = np.asarray(rgb[y0:y1, x0:x1], dtype=np.float32)
    if roi.ndim == 2:
        roi = roi[..., None]
    hole = _grow(mask[y0:y1, x0:x1], g)
    rng = np.random.default_rng(seed)
    scale = min(1.0, HOLE_MAX / side)
    if scale < 1.0:
        sh, sw = max(8, int(round(roi.shape[0] * scale))), max(8, int(round(roi.shape[1] * scale)))
        small = _resize(roi, sh, sw)
        small_hole = _grow(_shrink_mask(hole, sh, sw), 1)
        worked, level = _complete(small, small_hole, progress, cancelled, rng)
        if level is None:
            filled = roi.copy()
            filled[hole] = _resize(worked, *hole.shape)[hole]
        else:
            filled = _to_full(roi, hole, worked, level, sh / roi.shape[0])
    else:
        filled, _level = _complete(roi, hole, progress, cancelled, rng)
    if cancelled is not None and cancelled():
        return None
    # Blend the last two pixels inside the hole's edge (grown past the object: they're background anyway).
    inner = hole & ~_grow(~hole, 2)
    alpha = np.where(hole, np.where(inner, 1.0, 0.6), 0.0).astype(np.float32)[..., None]
    out = roi * (1 - alpha) + filled * alpha
    if progress is not None:
        progress(1.0)
    patch = np.clip(np.rint(out), 0, 255).astype(np.uint8)
    return y0, x0, (patch[..., 0] if np.asarray(rgb).ndim == 2 else patch)


def remove(rgb: np.ndarray, mask: np.ndarray, progress: Callable[[float], None] | None = None,
           cancelled: Callable[[], bool] | None = None, grow: int | None = None, seed: int = _RNG_SEED) -> np.ndarray:
    """`rgb` (h, w, 3) with what `mask` covers removed — filled with the photo itself. Returns uint8."""
    out = np.array(rgb, dtype=np.uint8, copy=True)
    region = remove_region(out, mask, progress, cancelled, grow, seed)
    if region is not None:
        y0, x0, patch = region
        out[y0:y0 + patch.shape[0], x0:x0 + patch.shape[1]] = patch
    return out
