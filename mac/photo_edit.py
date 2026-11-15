"""Photo Browser for Mac's photo editor — the arithmetic (no Qt here; photo_editor_window.py is the window).

What the phone editors do — Hypic, Facetune, Snapseed, Lightroom — on the Mac, to the photo where it lives:

- **Adjust** (`apply_adjust`): exposure, brightness, contrast, highlights, shadows, whites, blacks; saturation,
  vibrance, temperature, tint; sharpen, clarity, texture, dehaze, noise reduction; fade, grain, vignette, glow;
  split toning; eight hue bands of hue / saturation / lightness; black-and-white with a channel mix; duotone.
- **Filters** (`LOOKS`, `apply_look`): fifty looks, each a recipe of those same adjustments — so a filter is
  never a mystery, its strength is a slider, and the adjustments go on top of it.
- **Crop & turn** (`Geometry`): quarter turns, flips, straightening (the photo zoomed to stay full, as in
  Photos), a crop box.
- **Retouch** (`Stroke`, `apply_stroke`): brushes painted where they're wanted — Smooth, Heal (inpaint.py's
  fill), Whiten, Details, Blur, Lighten, Darken, Red Eye, and Reshape (a push warp).
- **Face** (`apply_face`): skin smoothing by skin colour (no model needed); with the People feature's face
  finder (faces.py) also brighter eyes, whiter teeth, larger eyes, a slimmer face, a narrower nose, a smile —
  worked out from the finder's five points, so they are gentle by design.
- **Blur** (`apply_focus`): a round or a band of sharpness with the rest blurred (portrait / tilt-shift).
- **Frame** (`apply_frame`): border, Polaroid, rounded corners, cinema bars, fit to a shape on colour or on
  the photo blurred.

**One description, two sizes.** An `Edit` holds everything as fractions of the photo and −100…100 amounts; the
window renders it on a small copy as sliders move and `render` runs the same code on every pixel at save. Radii
are fractions of the photo's long side, so both look the same (sharpening and grain are finer than a preview
can show; they're honest at 100%).

**Order** (fixed, so undoing one thing never disturbs another): retouch strokes and face → turn / straighten /
crop → filter → adjustments → blur → frame → text (drawn by the window, photo_text.py).

Pixels are float32 RGB, 0…1, in the photo's own colour space (its profile is kept on saving — batch_crop's
`encode_like` — so a Display P3 HEIC stays one). numpy and Pillow only.
"""
from __future__ import annotations

import math
from dataclasses import asdict, dataclass, field
from typing import Callable

import numpy as np
from PIL import Image, ImageDraw

EDITED_TAG = "edited"
NEW_LABEL = "edited"
LUMA = np.array([0.2126, 0.7152, 0.0722], dtype=np.float32)
FULL = (0.0, 0.0, 1.0, 1.0)
F32 = np.float32


# ----------------------------------------------------------------------------- small tools

def to_float(im: "Image.Image") -> tuple[np.ndarray, np.ndarray | None]:
    """A Pillow picture as (rgb float32 0…1, alpha float32 or None)."""
    alpha = None
    if im.mode in ("RGBA", "LA", "PA") or (im.mode == "P" and "transparency" in im.info):
        rgba = np.asarray(im.convert("RGBA"), dtype=F32) / 255.0
        return np.ascontiguousarray(rgba[..., :3]), np.ascontiguousarray(rgba[..., 3])
    if im.mode in ("I;16", "I;16L", "I;16B", "I"):
        a = np.asarray(im, dtype=F32) / 65535.0
        return np.repeat(a[..., None], 3, axis=2), alpha
    return np.asarray(im.convert("RGB"), dtype=F32) / 255.0, alpha


def to_image(rgb: np.ndarray, alpha: np.ndarray | None = None) -> "Image.Image":
    a = np.clip(rgb * 255.0 + 0.5, 0, 255).astype(np.uint8)
    if alpha is None:
        return Image.fromarray(a, "RGB")
    al = np.clip(alpha * 255.0 + 0.5, 0, 255).astype(np.uint8)
    return Image.fromarray(np.dstack([a, al]), "RGBA")


def luma(img: np.ndarray) -> np.ndarray:
    return img @ LUMA


def smoothstep(lo: float, hi: float, x: np.ndarray) -> np.ndarray:
    t = np.clip((x - lo) / max(hi - lo, 1e-6), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def resize(a: np.ndarray, w: int, h: int, how=Image.Resampling.BILINEAR) -> np.ndarray:
    """A float array (h, w) or (h, w, c) at a new size — Pillow's resampling, a channel at a time."""
    w, h = max(1, int(w)), max(1, int(h))
    if a.shape[1] == w and a.shape[0] == h:
        return a
    if a.ndim == 2:
        return np.asarray(Image.fromarray(np.ascontiguousarray(a, dtype=F32), "F").resize((w, h), how), dtype=F32)
    return np.dstack([resize(a[..., c], w, h, how) for c in range(a.shape[2])])


def _conv(a: np.ndarray, sigma: float) -> np.ndarray:
    r = max(1, int(sigma * 3.0 + 0.5))
    x = np.arange(-r, r + 1, dtype=F32)
    k = np.exp(-(x * x) / (2.0 * sigma * sigma))
    k /= k.sum()
    tail = ((0, 0),) * (a.ndim - 2)
    p = np.pad(a, ((r, r), (0, 0)) + tail, mode="edge")
    out = np.zeros_like(a)
    for i, wgt in enumerate(k):
        out += wgt * p[i:i + a.shape[0]]
    p = np.pad(out, ((0, 0), (r, r)) + tail, mode="edge")
    out = np.zeros_like(a)
    for i, wgt in enumerate(k):
        out += wgt * p[:, i:i + a.shape[1]]
    return out


def gauss(a: np.ndarray, sigma: float) -> np.ndarray:
    """A Gaussian blur of a float array. A wide blur is done on a smaller copy (what's left after one has no
    detail to lose), so the cost doesn't grow with the radius."""
    if sigma < 0.3:
        return a
    k = int(sigma / 1.5)
    if k < 2:
        return _conv(a, sigma)
    h, w = a.shape[:2]
    sw, sh = max(2, w // k), max(2, h // k)
    small = _conv(resize(a, sw, sh, Image.Resampling.BOX), max(0.5, sigma * sw / w))
    return resize(small, w, h, Image.Resampling.BICUBIC)


def guided(guide: np.ndarray, p: np.ndarray, sigma: float, eps: float) -> np.ndarray:
    """Edge-keeping smoothing of `p` (h, w) led by `guide` (h, w): flat where the guide is flat, untouched
    across its edges (a guided filter with Gaussian windows)."""
    m_i, m_p = gauss(guide, sigma), gauss(p, sigma)
    var = gauss(guide * guide, sigma) - m_i * m_i
    cov = gauss(guide * p, sigma) - m_i * m_p
    a = cov / (var + eps)
    b = m_p - a * m_i
    return gauss(a, sigma) * guide + gauss(b, sigma)


def hue_rgb(deg: float) -> np.ndarray:
    """The pure colour at a hue (0 red, 120 green, 240 blue)."""
    h = (deg % 360.0) / 60.0
    x = 1.0 - abs(h % 2.0 - 1.0)
    r, g, b = [(1, x, 0), (x, 1, 0), (0, 1, x), (0, x, 1), (x, 0, 1), (1, 0, x)][int(h) % 6]
    return np.array([r, g, b], dtype=F32)


def max3(img: np.ndarray) -> np.ndarray:
    """The largest of each pixel's three channels (numpy's own reduction over a 3-long axis is ten times slower)."""
    return np.maximum(np.maximum(img[..., 0], img[..., 1]), img[..., 2])


def min3(img: np.ndarray) -> np.ndarray:
    return np.minimum(np.minimum(img[..., 0], img[..., 1]), img[..., 2])


def hue_sat(img: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """(hue in degrees, saturation 0…1) of every pixel."""
    r, g, b = img[..., 0], img[..., 1], img[..., 2]
    hue = np.arctan2(F32(1.7320508) * (g - b), 2.0 * r - g - b) * F32(57.29578)
    hue = np.where(hue < 0, hue + F32(360.0), hue)
    mx = max3(img)
    return hue.astype(F32), ((mx - min3(img)) / np.maximum(mx, 1e-4)).astype(F32)


# ----------------------------------------------------------------------------- adjustments

# name, lowest, highest — every one rests at 0. The window builds its sliders from this.
SLIDERS: list[tuple[str, list[tuple[str, str, int, int]]]] = [
    ("Light", [("exposure", "Exposure", -100, 100), ("brightness", "Brightness", -100, 100),
               ("contrast", "Contrast", -100, 100), ("highlights", "Highlights", -100, 100),
               ("shadows", "Shadows", -100, 100), ("whites", "Whites", -100, 100),
               ("blacks", "Blacks", -100, 100)]),
    ("Colour", [("saturation", "Saturation", -100, 100), ("vibrance", "Vibrance", -100, 100),
                ("temperature", "Warmth", -100, 100), ("tint", "Tint", -100, 100)]),
    ("Detail", [("sharpen", "Sharpen", 0, 100), ("clarity", "Clarity", -100, 100),
                ("texture", "Texture", -100, 100), ("dehaze", "Dehaze", 0, 100), ("denoise", "Noise Reduction", 0, 100)]),
    ("Effects", [("fade", "Fade", 0, 100), ("grain", "Grain", 0, 100), ("vignette", "Vignette", -100, 100),
                 ("glow", "Glow", 0, 100)]),
    ("Split Tone", [("sh_hue", "Shadows Hue", 0, 360), ("sh_amt", "Shadows Amount", 0, 100),
                    ("hi_hue", "Highlights Hue", 0, 360), ("hi_amt", "Highlights Amount", 0, 100)]),
]
BANDS = [("red", 0.0, 30.0), ("orange", 30.0, 28.0), ("yellow", 60.0, 34.0), ("green", 120.0, 62.0),
         ("aqua", 180.0, 50.0), ("blue", 235.0, 50.0), ("purple", 280.0, 40.0), ("magenta", 320.0, 40.0)]
BAND_NAMES = [b[0] for b in BANDS]


def _band_weight(hue: np.ndarray, centre: float, width: float) -> np.ndarray:
    d = np.abs((hue - centre + 180.0) % 360.0 - 180.0)
    return np.clip(1.0 - d / width, 0.0, 1.0)


def auto_adjust(img: np.ndarray) -> dict:
    """What "Auto" sets: the levels stretched to the photo's own darkest and lightest half-percent, the
    mid-tones brought toward the middle, a colour cast eased half-way toward neutral."""
    small = img[::max(1, img.shape[0] // 400), ::max(1, img.shape[1] // 400)]
    y = luma(small)
    lo, mid, hi = (float(v) for v in np.percentile(y, [0.5, 50.0, 99.5]))
    out: dict = {}
    if hi < 0.97:
        out["whites"] = round(min(100.0, (1.0 - hi) / 0.25 * 100.0))
    if lo > 0.03:
        out["blacks"] = -round(min(100.0, lo / 0.12 * 100.0))
    span = max(hi - lo, 0.05)
    rel = (mid - lo) / span
    if abs(rel - 0.46) > 0.04:
        out["brightness"] = int(np.clip(math.log2(math.log(max(rel, 0.02)) / math.log(0.46)) * 100.0, -60, 60))
    flat = small.reshape(-1, 3)
    near_grey = flat[(flat.max(axis=1) - flat.min(axis=1)) < 0.12 * np.maximum(flat.max(axis=1), 0.2)]
    if len(near_grey) > len(flat) * 0.04:                    # a cast shows in what should be grey; a red dress doesn't count
        means = near_grey.mean(axis=0)
        grey = max(float(means.mean()), 0.05)
        out["temperature"] = int(np.clip((means[2] - means[0]) / grey * 120.0, -20, 20))
        out["tint"] = int(np.clip((means[1] - (means[0] + means[2]) / 2.0) / grey * 120.0, -15, 15))
    out["vibrance"] = 12
    return {k: v for k, v in out.items() if v}


def apply_adjust(img: np.ndarray, a: dict, seed: int = 7) -> np.ndarray:
    """`img` with the adjustments in `a` (see SLIDERS; plus the recipe-only keys the looks use: "mono", "mix",
    "duo", "tint_hue"/"tint_amt", "fade_rgb", "chroma", "scan", "flash", "hsl"). Returns a new array."""
    def v(key: str) -> float:
        return float(a.get(key, 0) or 0) / 100.0

    h, w = img.shape[:2]
    long_side = float(max(h, w))
    out = img

    ev, temp, tint = v("exposure") * 2.0, v("temperature"), v("tint")
    if ev or temp or tint:                                        # in linear light
        lin = np.power(np.clip(out, 0.0, 1.0), 2.2)
        gain = np.array([1.0 + 0.30 * temp + 0.10 * tint, 1.0 - 0.22 * tint, 1.0 - 0.30 * temp + 0.10 * tint], dtype=F32)
        if temp or tint:
            gain /= float(gain @ LUMA)                            # a cast, not a brightness change
        lin = lin * (gain * F32(2.0 ** ev))
        if ev > 0 or temp or tint:                                # a soft shoulder instead of a hard clip
            over = lin > 0.8
            lin = np.where(over, 0.8 + 0.2 * np.tanh((lin - 0.8) / 0.2), lin)
        out = np.power(np.clip(lin, 0.0, 1.0), 1.0 / 2.2).astype(F32)

    dehaze = v("dehaze")
    if dehaze > 0:
        air = np.array([np.percentile(out[::8, ::8, c], 99.7) for c in range(3)], dtype=F32).clip(0.5, 1.0)
        t = np.clip(1.0 - 0.7 * dehaze * gauss(min3(out / air), 0.012 * long_side), 0.35, 1.0)
        out = np.clip((out - air) / t[..., None] + air, 0.0, 1.0)
        out = np.power(out, F32(1.0 - 0.22 * dehaze)).astype(F32)       # clearing haze darkens: given back

    bright, contrast, whites, blacks = v("brightness"), v("contrast"), v("whites"), v("blacks")
    if bright or contrast or whites or blacks:
        out = np.clip(out, 0.0, 1.0)
        if whites > 0:
            out = np.minimum(out / (1.0 - 0.25 * whites), 1.0)
        elif whites < 0:
            out = out * (1.0 + 0.25 * whites)
        if blacks < 0:
            bp = 0.12 * -blacks
            out = np.clip((out - bp) / (1.0 - bp), 0.0, 1.0)
        elif blacks > 0:
            out = out + 0.12 * blacks * (1.0 - out) ** 3
        if bright:
            out = np.power(out, F32(2.0 ** -bright))
        if contrast > 0:
            p = F32(1.0 + 1.2 * contrast)
            xp, ip = np.power(out, p), np.power(1.0 - out, p)
            out = xp / (xp + ip + 1e-7)
        elif contrast < 0:
            out = 0.5 + (out - 0.5) * (1.0 + 0.6 * contrast)
        out = out.astype(F32)

    hi, sh = v("highlights"), v("shadows")
    if hi or sh:
        y = np.clip(luma(out), 0.0, 1.0)
        yb = 0.6 * gauss(y, 0.02 * long_side) + 0.4 * y
        y2 = y
        if sh:
            ms = 1.0 - smoothstep(0.0, 0.55, yb)
            y2 = y2 + sh * ms * ((np.sqrt(y) - y) * 0.9 if sh > 0 else (y - y * y) * 0.9)
        if hi:
            mh = smoothstep(0.45, 1.0, yb)
            y2 = y2 * (1.0 + 0.35 * hi * mh) if hi < 0 else y2 + hi * mh * (1.0 - y2) * 0.6
        ratio = np.clip(y2 / np.maximum(y, 1e-3), 0.0, 4.0)
        out = (out * ratio[..., None]).astype(F32)

    clarity, texture, sharpen = v("clarity"), v("texture"), v("sharpen")
    if clarity or texture or sharpen:
        y = luma(out)
        delta = np.zeros_like(y)
        if clarity:
            mid = np.clip(1.0 - (2.0 * y - 1.0) ** 2, 0.0, 1.0)
            delta += clarity * 1.1 * (y - gauss(y, 0.025 * long_side)) * mid
        if texture:
            s = max(1.2, 0.004 * long_side)
            delta += texture * 1.6 * (gauss(y, s / 3.0) - gauss(y, s))
        if sharpen:
            delta += sharpen * 1.8 * (y - gauss(y, float(np.clip(long_side / 2500.0, 0.6, 1.6))))
        out = (out + delta[..., None]).astype(F32)

    denoise = v("denoise")
    if denoise > 0:
        y = luma(out)
        chroma = out - y[..., None]
        chroma = gauss(chroma, (0.6 + 2.4 * denoise) * max(1.0, long_side / 2000.0))
        y = guided(y, y, max(1.0, 0.0015 * long_side), (0.012 + 0.05 * denoise) ** 2)
        out = (y[..., None] + chroma).astype(F32)

    hsl = a.get("hsl") or {}
    vib, sat = v("vibrance"), v("saturation")
    if hsl or vib:
        hue, s = hue_sat(np.clip(out, 0.0, 1.0))
        y = luma(out)
        if hsl:
            turn = np.zeros_like(y)
            more = np.zeros_like(y)
            light = np.zeros_like(y)
            for name, centre, width in BANDS:
                dh, ds, dl = (float(x) / 100.0 for x in (hsl.get(name) or (0, 0, 0)))
                if not (dh or ds or dl):
                    continue
                wgt = _band_weight(hue, centre, width) * np.minimum(s * 4.0, 1.0)
                turn += wgt * dh
                more += wgt * ds
                light += wgt * dl
            if np.any(turn):                                         # hue: the colour part turned (YIQ)
                ang = turn * F32(math.radians(40.0))
                ci = out @ np.array([0.596, -0.274, -0.322], dtype=F32)
                cq = out @ np.array([0.211, -0.523, 0.312], dtype=F32)
                c, sn = np.cos(ang), np.sin(ang)
                ci, cq = ci * c - cq * sn, ci * sn + cq * c
                out = np.stack([y + 0.956 * ci + 0.621 * cq, y - 0.272 * ci - 0.647 * cq,
                                y - 1.106 * ci + 1.703 * cq], axis=2)
            out = y[..., None] + (out - y[..., None]) * np.maximum(1.0 + more, 0.0)[..., None]
            out = (out * (1.0 + 0.6 * light)[..., None]).astype(F32)
        if vib:
            skin = _band_weight(hue, 28.0, 26.0)
            k = vib * (1.0 - s) * (1.0 - 0.5 * skin) if vib > 0 else np.full_like(s, vib * 0.8)
            y = luma(out)
            out = (y[..., None] + (out - y[..., None]) * (1.0 + k)[..., None]).astype(F32)
    if sat:
        y = luma(out)
        out = (y[..., None] + (out - y[..., None]) * max(0.0, 1.0 + sat)).astype(F32)

    mono = float(a.get("mono", 0) or 0)
    if mono > 0:
        mix = np.array(a.get("mix") or LUMA, dtype=F32)
        mix = mix / max(float(mix.sum()), 1e-3)
        grey = np.clip(out @ mix, 0.0, 1.0)[..., None]
        out = (out * (1.0 - mono) + grey * mono).astype(F32)
    duo = a.get("duo")
    if duo:
        c0, c1 = (np.array(c, dtype=F32) / 255.0 for c in duo[:2])
        y = np.clip(luma(out), 0.0, 1.0)[..., None]
        amount = float(a.get("duo_amt", 100)) / 100.0
        out = (out * (1.0 - amount) + (c0 + (c1 - c0) * y) * amount).astype(F32)
    tint_amt = v("tint_amt")
    if tint_amt:
        col = hue_rgb(float(a.get("tint_hue", 35)))
        col = col / float(col @ LUMA)
        y = luma(out)[..., None]
        out = (out * (1.0 - tint_amt) + np.clip(y * col, 0.0, 1.0) * tint_amt).astype(F32)
    sh_amt, hi_amt = v("sh_amt"), v("hi_amt")
    if sh_amt or hi_amt:
        y = np.clip(luma(out), 0.0, 1.0)
        if sh_amt:
            c = hue_rgb(float(a.get("sh_hue", 220)))
            out = out + (sh_amt * 0.28) * ((1.0 - y) ** 2)[..., None] * (c - float(c @ LUMA))
        if hi_amt:
            c = hue_rgb(float(a.get("hi_hue", 40)))
            out = out + (hi_amt * 0.28) * (y ** 2)[..., None] * (c - float(c @ LUMA))
        out = out.astype(F32)

    fade = v("fade")
    if fade > 0:
        lift = np.array(a.get("fade_rgb") or (128, 128, 128), dtype=F32) / 255.0 * (0.6 * fade)
        out = (lift + out * (1.0 - lift - 0.06 * fade)).astype(F32)

    glow = v("glow")
    if glow > 0:
        soft = gauss(np.clip(out, 0.0, 1.0) ** 2, 0.018 * long_side)
        out = (1.0 - (1.0 - np.clip(out, 0.0, 1.0)) * (1.0 - 0.7 * glow * soft)).astype(F32)

    chroma = v("chroma")
    if chroma:
        n = max(1, int(round(abs(chroma) * 0.004 * long_side)))
        out = out.copy()
        out[..., 0] = np.roll(out[..., 0], -n, axis=1)
        out[..., 2] = np.roll(out[..., 2], n, axis=1)
    scan = v("scan")
    if scan:
        period = max(2.0, long_side / 360.0)
        rows = 1.0 - scan * 0.28 * (np.sin(np.arange(h, dtype=F32) * (2.0 * math.pi / period)) * 0.5 + 0.5)
        out = (out * rows[:, None, None]).astype(F32)

    vig, flash = v("vignette"), v("flash")
    if vig or flash:
        yy = (np.arange(h, dtype=F32) - (h - 1) / 2.0) / (h / 2.0)
        xx = (np.arange(w, dtype=F32) - (w - 1) / 2.0) / (w / 2.0)
        r2 = (yy * yy)[:, None] + (xx * xx)[None, :]
        if flash:
            out = out * (1.0 + 0.55 * flash * np.clip(1.0 - r2, 0.0, 1.0) ** 2)[..., None]
        if vig:
            edge = smoothstep(0.25, 1.9, r2)[..., None]
            out = out * (1.0 - 0.8 * vig * edge) if vig > 0 else out + (-vig * 0.7) * edge * (1.0 - out)
        out = out.astype(F32)

    grain = v("grain")
    if grain > 0:
        size = max(1.0, long_side / 1400.0)
        rng = np.random.default_rng(seed)
        noise = rng.standard_normal((max(2, int(h / size)), max(2, int(w / size)))).astype(F32)
        noise = resize(noise, w, h, Image.Resampling.BILINEAR)
        y = np.clip(luma(out), 0.0, 1.0)
        out = (out + (0.16 * grain) * (noise * (1.0 - 0.7 * (2.0 * y - 1.0) ** 2))[..., None]).astype(F32)

    return np.clip(out, 0.0, 1.0) if out is not img else img


# ----------------------------------------------------------------------------- the looks

@dataclass(frozen=True)
class Look:
    name: str
    group: str
    recipe: dict


def _look(name: str, group: str, **recipe) -> Look:
    return Look(name, group, recipe)


NAVY, PEACH, CREAM, TEAL = (22, 34, 76), (255, 205, 170), (250, 240, 215), (16, 92, 100)

LOOKS: list[Look] = [
    # film
    _look("Gold Roll", "Film", temperature=15, saturation=10, contrast=10, fade=10, grain=15,
          sh_hue=185, sh_amt=18, hi_hue=48, hi_amt=22),
    _look("Portra Soft", "Film", contrast=-10, shadows=20, highlights=-20, temperature=8, saturation=-8, fade=12,
          grain=10),
    _look("Green Roll", "Film", tint=-10, temperature=-5, contrast=15, grain=15, hsl={"green": (0, 18, 0)}),
    _look("Slide Chrome", "Film", contrast=25, saturation=20, blacks=-15, vignette=10),
    _look("Expired", "Film", fade=25, tint=12, saturation=-15, grain=30, sh_hue=310, sh_amt=20, hi_hue=55, hi_amt=18),
    _look("Cine 400", "Film", contrast=12, highlights=-15, shadows=10, saturation=-6, grain=22, sh_hue=200, sh_amt=14,
          hi_hue=35, hi_amt=14),
    # portrait
    _look("Clean Skin", "Portrait", exposure=10, contrast=-5, shadows=15, clarity=-15, vibrance=10,
          hsl={"orange": (0, 0, 10)}),
    _look("Soft Glow", "Portrait", glow=30, highlights=-10, clarity=-20, temperature=5),
    _look("Studio", "Portrait", contrast=15, saturation=-5, clarity=10, vignette=15),
    _look("Peach", "Portrait", temperature=10, tint=8, fade=8, hsl={"orange": (0, 10, 0)}),
    _look("Porcelain", "Portrait", exposure=15, saturation=-15, temperature=-5, clarity=-10, fade=5),
    _look("Sunkissed", "Portrait", temperature=14, vibrance=14, shadows=10, glow=12, hsl={"orange": (0, 8, 6)}),
    # black & white
    _look("Classic Mono", "Black & White", mono=1, contrast=15),
    _look("Noir", "Black & White", mono=1, contrast=45, blacks=-25, vignette=30, grain=20),
    _look("Silver", "Black & White", mono=1, contrast=-10, fade=15, shadows=20),
    _look("Red Filter", "Black & White", mono=1, mix=(0.8, 0.2, 0.0), contrast=20),
    _look("Newsprint", "Black & White", mono=1, clarity=40, grain=40),
    _look("Soft Mono", "Black & White", mono=1, mix=(0.45, 0.45, 0.10), contrast=-5, glow=18, fade=8),
    # vivid
    _look("Pop", "Vivid", vibrance=40, contrast=20, clarity=15),
    _look("Tropic", "Vivid", saturation=25, temperature=5, hsl={"aqua": (0, 20, 0), "blue": (0, 20, 0)}),
    _look("HDR", "Vivid", shadows=50, highlights=-50, clarity=40, vibrance=20),
    _look("Candy", "Vivid", saturation=30, exposure=10, fade=5, tint=5),
    _look("Postcard", "Vivid", vibrance=30, dehaze=30, contrast=10, hsl={"blue": (0, 15, -10)}),
    # moody
    _look("Teal & Amber", "Moody", contrast=15, saturation=-10, sh_hue=185, sh_amt=32, hi_hue=32, hi_amt=30),
    _look("Blockbuster", "Moody", contrast=25, blacks=-10, vignette=20, hsl={"blue": (0, -20, 0)}),
    _look("Dark Forest", "Moody", exposure=-15, saturation=-25, shadows=-10, vignette=25, hsl={"green": (-25, 0, -10)}),
    _look("Night City", "Moody", temperature=-15, tint=10, contrast=20, sh_hue=235, sh_amt=26, hi_hue=315, hi_amt=18),
    _look("Bleach", "Moody", saturation=-50, contrast=40, clarity=20),
    _look("Storm", "Moody", exposure=-8, contrast=18, saturation=-22, clarity=22, temperature=-8, vignette=18),
    # warm
    _look("Golden Hour", "Warm", temperature=30, highlights=-15, vibrance=15, hi_hue=32, hi_amt=24),
    _look("Honey", "Warm", temperature=20, tint=5, fade=10, contrast=-5),
    _look("Terracotta", "Warm", temperature=15, hsl={"orange": (0, 20, 0), "red": (0, 20, 0), "blue": (0, -30, 0)}),
    _look("Campfire", "Warm", temperature=35, exposure=-10, contrast=15, vignette=25),
    # cool
    _look("Arctic", "Cool", temperature=-30, saturation=-10, exposure=10),
    _look("Blue Hour", "Cool", temperature=-20, tint=5, shadows=-10, sh_hue=228, sh_amt=30),
    _look("Mint", "Cool", temperature=-10, tint=-12, fade=10),
    _look("Steel", "Cool", temperature=-15, saturation=-30, contrast=20, clarity=15),
    # vintage
    _look("1970", "Vintage", fade=20, temperature=20, saturation=-10, grain=25, vignette=20, sh_hue=8, sh_amt=16),
    _look("Sepia", "Vintage", mono=1, tint_hue=35, tint_amt=45, fade=10, vignette=20),
    _look("Instant", "Vintage", fade=18, contrast=-10, tint=-5, sh_hue=225, sh_amt=20, fade_rgb=(120, 130, 150)),
    _look("Digicam 2005", "Vintage", flash=45, vignette=30, saturation=15, sharpen=40, tint=-6),
    _look("VHS", "Vintage", chroma=60, saturation=10, fade=15, scan=70, grain=18),
    _look("Disposable", "Vintage", flash=30, contrast=12, saturation=12, temperature=8, grain=28, vignette=22),
    # pastel
    _look("Pastel", "Pastel", exposure=15, contrast=-25, saturation=-15, fade=20, shadows=30),
    _look("Milk", "Pastel", fade=30, contrast=-15, temperature=5),
    _look("Lilac", "Pastel", tint=15, temperature=-5, fade=15, sh_hue=270, sh_amt=20, hi_hue=330, hi_amt=16),
    _look("Matte", "Pastel", blacks=45, saturation=-10, contrast=5),
    # duotone
    _look("Navy & Peach", "Duotone", duo=(NAVY, PEACH)),
    _look("Purple & Yellow", "Duotone", duo=((70, 22, 110), (255, 226, 96))),
    _look("Teal & Cream", "Duotone", duo=(TEAL, CREAM)),
    _look("Red & Black", "Duotone", duo=((10, 6, 8), (226, 38, 44)), contrast=15),
    _look("Cyanotype", "Duotone", duo=((8, 30, 66), (232, 242, 250)), contrast=8),
]
LOOK_GROUPS = list(dict.fromkeys(look.group for look in LOOKS))
_LOOK_BY_NAME = {look.name: look for look in LOOKS}


def look_named(name: str) -> Look | None:
    return _LOOK_BY_NAME.get(name)


def apply_look(img: np.ndarray, name: str, amount: float = 1.0, seed: int = 7) -> np.ndarray:
    """The look, mixed with the photo by `amount` (0…1)."""
    look = _LOOK_BY_NAME.get(name)
    if look is None or amount <= 0:
        return img
    done = apply_adjust(img, look.recipe, seed)
    return done if amount >= 0.999 else (img + (done - img) * F32(amount)).astype(F32)


# ----------------------------------------------------------------------------- turning and cropping

@dataclass
class Geometry:
    quarters: int = 0                       # quarter turns clockwise
    flip_h: bool = False
    flip_v: bool = False
    straighten: float = 0.0                 # degrees, −45…45 (clockwise)
    crop: tuple[float, float, float, float] = FULL      # x, y, w, h as fractions of the turned, straightened photo

    def plain(self) -> bool:
        return not (self.quarters % 4 or self.flip_h or self.flip_v or abs(self.straighten) > 0.01 or self.crop != FULL)


def _zoom_for(angle: float, w: int, h: int) -> float:
    """How much a photo turned by `angle` must be enlarged to still fill its own frame."""
    t = math.radians(abs(angle))
    return math.cos(t) + math.sin(t) * max(w / h, h / w)


def turned_size(g: Geometry, w: int, h: int, cropped: bool = True) -> tuple[int, int]:
    """The size `apply_geometry` gives a w×h photo."""
    if g.quarters % 2:
        w, h = h, w
    if abs(g.straighten) > 0.01:
        z = _zoom_for(g.straighten, w, h)
        w, h = max(1, int(w / z)), max(1, int(h / z))
    if cropped and g.crop != FULL:
        w, h = max(1, round(g.crop[2] * w)), max(1, round(g.crop[3] * h))
    return w, h


def apply_geometry(img: np.ndarray, g: Geometry, cropped: bool = True) -> np.ndarray:
    """The photo turned, flipped, straightened and (unless `cropped` is False — the Crop tool wants the whole
    of it under its box) cropped. Works on (h, w) too — a mask or an alpha goes through the same way."""
    out = img
    q = g.quarters % 4
    if q:
        out = np.rot90(out, k=-q)
    if g.flip_h:
        out = out[:, ::-1]
    if g.flip_v:
        out = out[::-1]
    if abs(g.straighten) > 0.01:
        h, w = out.shape[:2]
        z = _zoom_for(g.straighten, w, h)
        chans = [out] if out.ndim == 2 else [out[..., c] for c in range(out.shape[2])]
        turned = [np.asarray(Image.fromarray(np.ascontiguousarray(c, dtype=F32), "F")
                             .rotate(-g.straighten, resample=Image.Resampling.BICUBIC), dtype=F32) for c in chans]
        out = turned[0] if out.ndim == 2 else np.dstack(turned)
        nw, nh = max(1, int(w / z)), max(1, int(h / z))
        x0, y0 = (w - nw) // 2, (h - nh) // 2
        out = out[y0:y0 + nh, x0:x0 + nw]
    if cropped and g.crop != FULL:
        h, w = out.shape[:2]
        x, y, cw, ch = g.crop
        x0, y0 = int(round(x * w)), int(round(y * h))
        x1, y1 = max(x0 + 1, int(round((x + cw) * w))), max(y0 + 1, int(round((y + ch) * h)))
        out = out[max(0, y0):min(h, y1), max(0, x0):min(w, x1)]
    return np.ascontiguousarray(out, dtype=F32)


def to_original(g: Geometry, u: float, v: float, w: int, h: int, cropped: bool = True) -> tuple[float, float]:
    """A point on the edited photo (fractions of what `apply_geometry` shows) → where that is on the original
    (fractions of it). `w`, `h`: the original's size. The retouch brushes are stored this way, so a later crop
    or turn leaves them where they were painted."""
    tw, th = (h, w) if g.quarters % 2 else (w, h)
    if cropped and g.crop != FULL:
        u, v = g.crop[0] + u * g.crop[2], g.crop[1] + v * g.crop[3]
    if abs(g.straighten) > 0.01:
        z = _zoom_for(g.straighten, tw, th)
        nw, nh = max(1, int(tw / z)), max(1, int(th / z))
        px, py = (u - 0.5) * nw, (v - 0.5) * nh
        t = math.radians(g.straighten)
        px, py = px * math.cos(t) + py * math.sin(t), -px * math.sin(t) + py * math.cos(t)
        u, v = px / tw + 0.5, py / th + 0.5
    if g.flip_v:
        v = 1.0 - v
    if g.flip_h:
        u = 1.0 - u
    for _ in range(g.quarters % 4):                       # undo each clockwise quarter turn
        u, v = v, 1.0 - u
    return u, v


def scale_to_original(g: Geometry, w: int, h: int) -> float:
    """A length that is `1` of the edited photo's width, as a fraction of the original's long side."""
    ew, _eh = turned_size(g, w, h)
    return ew / float(max(w, h))


# ----------------------------------------------------------------------------- retouch brushes

TOOLS = [("smooth", "Smooth", "Softens skin and noise under the brush, keeping edges."),
         ("heal", "Heal", "Removes what you paint over — a spot, a wire, a stray hair — filled from the photo."),
         ("whiten", "Whiten", "Takes the yellow out and lifts it: teeth, the whites of eyes."),
         ("details", "Details", "Brings out fine detail: eyes, lashes, hair, jewellery."),
         ("blur", "Blur", "Blurs what you paint over: a background, a number plate."),
         ("lighten", "Lighten", "Dodges: lifts shadows under the brush."),
         ("darken", "Darken", "Burns: deepens what's under the brush."),
         ("redeye", "Red Eye", "Click a red pupil to make it dark again."),
         ("reshape", "Reshape", "Push pixels: drag an edge to where it should be.")]
TOOL_NAMES = {t[0]: t[1] for t in TOOLS}


@dataclass
class Stroke:
    tool: str
    points: list[tuple[float, float]]       # fractions of the original photo (upright)
    size: float                             # brush radius, as a fraction of the original's long side
    amount: float = 0.6                     # 0…1
    soft: float = 0.6                       # 0 hard edge … 1 feathered


def _window(points: np.ndarray, r: float, w: int, h: int, pad: float = 1.6) -> tuple[int, int, int, int] | None:
    m = r * pad + 2
    x0, y0 = int(max(0, math.floor(points[:, 0].min() - m))), int(max(0, math.floor(points[:, 1].min() - m)))
    x1, y1 = int(min(w, math.ceil(points[:, 0].max() + m))), int(min(h, math.ceil(points[:, 1].max() + m)))
    return (x0, y0, x1, y1) if x1 - x0 >= 2 and y1 - y0 >= 2 else None


def stroke_mask(points: np.ndarray, r: float, box: tuple[int, int, int, int], soft: float) -> np.ndarray:
    """The brush's coverage (0…1) inside `box`, for a stroke through `points` (pixels) of radius `r`."""
    x0, y0, x1, y1 = box
    core = max(0.6, r * (1.0 - 0.5 * soft))
    im = Image.new("L", (x1 - x0, y1 - y0), 0)
    d = ImageDraw.Draw(im)
    pts = [(float(x - x0), float(y - y0)) for x, y in points]
    if len(pts) > 1:
        d.line(pts, fill=255, width=max(1, int(round(core * 2))), joint="curve")
    for x, y in (pts[0], pts[-1]):
        d.ellipse((x - core, y - core, x + core, y + core), fill=255)
    m = np.asarray(im, dtype=F32) / 255.0
    return gauss(m, r * soft * 0.45) if soft > 0.02 else m


def _bilinear(src: np.ndarray, mx: np.ndarray, my: np.ndarray) -> np.ndarray:
    """`src` sampled at (mx, my) — pixel coordinates, clamped to the edges."""
    h, w = src.shape[:2]
    mx, my = np.clip(mx, 0.0, w - 1.001), np.clip(my, 0.0, h - 1.001)
    x0, y0 = mx.astype(np.intp), my.astype(np.intp)
    fx, fy = (mx - x0).astype(F32), (my - y0).astype(F32)
    if src.ndim == 3:
        fx, fy = fx[..., None], fy[..., None]
    top = src[y0, x0] * (1 - fx) + src[y0, x0 + 1] * fx
    bot = src[y0 + 1, x0] * (1 - fx) + src[y0 + 1, x0 + 1] * fx
    return (top * (1 - fy) + bot * fy).astype(F32)


class _Warp:
    """A warp over a box of the photo, built from pushes and bulges and applied once (so a long Reshape stroke
    costs one resampling, not a blur per step)."""

    def __init__(self, box: tuple[int, int, int, int]) -> None:
        self.box = box
        x0, y0, x1, y1 = box
        self.gy, self.gx = np.mgrid[0:y1 - y0, 0:x1 - x0].astype(F32)
        self.mx, self.my = self.gx.copy(), self.gy.copy()         # where each pixel takes its colour from

    def _fall(self, cx: float, cy: float, r: float) -> np.ndarray:
        d2 = ((self.gx - (cx - self.box[0])) ** 2 + (self.gy - (cy - self.box[1])) ** 2) / max(r * r, 1.0)
        return np.clip(1.0 - d2, 0.0, 1.0) ** 2

    def push(self, cx: float, cy: float, r: float, dx: float, dy: float) -> None:
        f = self._fall(cx, cy, r)
        sx, sy = self.gx - dx * f, self.gy - dy * f
        self.mx, self.my = _bilinear(self.mx, sx, sy), _bilinear(self.my, sx, sy)

    def bulge(self, cx: float, cy: float, r: float, amount: float) -> None:
        """amount > 0 enlarges what's at the centre, < 0 pinches it."""
        f = self._fall(cx, cy, r) * amount
        lx, ly = cx - self.box[0], cy - self.box[1]
        sx, sy = self.gx - (self.gx - lx) * f, self.gy - (self.gy - ly) * f
        self.mx, self.my = _bilinear(self.mx, sx, sy), _bilinear(self.my, sx, sy)

    def apply(self, img: np.ndarray) -> None:
        x0, y0, x1, y1 = self.box
        img[y0:y1, x0:x1] = _bilinear(img[y0:y1, x0:x1].copy(), self.mx, self.my)


def apply_stroke(img: np.ndarray, s: Stroke, progress: Callable[[float], None] | None = None,
                 cancelled: Callable[[], bool] | None = None) -> None:
    """One brush stroke, done to `img` in place."""
    h, w = img.shape[:2]
    long_side = float(max(h, w))
    if not s.points:
        return
    pts = np.array([(u * w, v * h) for u, v in s.points], dtype=np.float64)
    r = max(1.0, s.size * long_side)
    amount = float(np.clip(s.amount, 0.0, 1.0))

    if s.tool == "reshape":
        box = _window(pts, r, w, h, pad=1.1)
        if box is None or len(pts) < 2:
            return
        warp = _Warp(box)
        step = max(1.0, r / 5.0)
        last = pts[0]
        for p in pts[1:]:
            d = p - last
            dist = float(np.hypot(*d))
            if dist < step and p is not pts[-1]:
                continue
            n = max(1, int(dist / step))
            for i in range(n):
                c = last + d * (i / n)
                warp.push(float(c[0]), float(c[1]), r, float(d[0] / n) * (0.35 + 0.65 * amount),
                          float(d[1] / n) * (0.35 + 0.65 * amount))
            last = p
        warp.apply(img)
        return

    box = _window(pts, r, w, h)
    if box is None:
        return
    x0, y0, x1, y1 = box
    region = img[y0:y1, x0:x1]
    if s.tool == "redeye":
        m = stroke_mask(pts[:1], r, box, 0.5)
        red, other = region[..., 0], np.maximum(region[..., 1], region[..., 2])
        hot = smoothstep(0.08, 0.28, red - other) * (red > 0.25) * m
        hot = gauss(hot, max(0.6, r * 0.06))[..., None]
        dark = np.minimum(region[..., 1], region[..., 2])[..., None] * np.array([0.85, 1.0, 1.0], dtype=F32)
        region[:] = region * (1.0 - hot) + dark * 0.7 * hot
        return
    m = stroke_mask(pts, r, box, s.soft)
    if s.tool == "heal":
        import inpaint
        patch = inpaint.remove_region(np.clip(img * 255.0 + 0.5, 0, 255).astype(np.uint8), _whole(m > 0.35, box, w, h),
                                      progress, cancelled)
        if patch is not None:
            py, px, data = patch
            img[py:py + data.shape[0], px:px + data.shape[1]] = data.astype(F32) / 255.0
        return
    m3 = (m * amount)[..., None]
    if s.tool == "smooth":
        y = luma(region)
        soft = guided(y, y, max(1.5, r * 0.10), 0.0035)
        soft = gauss(soft, max(0.6, r * 0.015))
        new = region + (soft - y)[..., None] * 0.85                  # tone smoothed, a little texture left
        chroma = new - luma(new)[..., None]
        new = luma(new)[..., None] + gauss(chroma, max(1.0, r * 0.05))
        region[:] = region + (new - region) * m3
    elif s.tool == "whiten":
        y = luma(region)[..., None]
        new = y + (region - y) * 0.35
        new = new + (1.0 - new) * 0.16
        region[:] = region + (new - region) * m3
    elif s.tool == "details":
        y = luma(region)
        d = (y - gauss(y, max(0.8, long_side / 2200.0))) * 1.6 + (y - gauss(y, max(2.0, long_side / 300.0))) * 0.5
        region[:] = np.clip(region + d[..., None] * m3, 0.0, 1.0)
    elif s.tool == "blur":
        region[:] = region + (gauss(region, max(1.0, r * 0.25 * (0.3 + amount))) - region) * (m[..., None])
    elif s.tool == "lighten":
        region[:] = region + (np.power(np.clip(region, 0, 1), 0.72) - region) * m3
    elif s.tool == "darken":
        region[:] = region + (np.power(np.clip(region, 0, 1), 1.4) - region) * m3


def _whole(mask: np.ndarray, box: tuple[int, int, int, int], w: int, h: int) -> np.ndarray:
    out = np.zeros((h, w), dtype=bool)
    out[box[1]:box[3], box[0]:box[2]] = mask
    return out


# ----------------------------------------------------------------------------- face

FACE_SLIDERS = [("smooth", "Smooth Skin", False), ("light", "Brighten Face", True), ("eyes", "Brighten Eyes", True),
                ("teeth", "Whiten Teeth", True), ("eye_size", "Larger Eyes", True), ("slim", "Slimmer Face", True),
                ("nose", "Narrower Nose", True), ("smile", "Smile", True)]      # (key, name, needs the face finder)


@dataclass
class FaceBox:
    """A face as faces.py finds it, in fractions of the original photo: its box and five points."""
    x: float
    y: float
    w: float
    h: float
    points: list[tuple[float, float]]       # right eye, left eye, nose tip, mouth right, mouth left (as seen)


def find_faces(im: "Image.Image") -> list[FaceBox]:
    """The faces in the photo (largest first). Raises `faces.Missing` when the face models aren't on this Mac."""
    import faces
    W, H = im.size
    out = []
    for row in faces.detect(im.convert("RGB")):
        x, y, w, h = (float(v) for v in row[:4])
        if w < 24 or h < 24:
            continue
        pts = [(float(row[4 + 2 * i]) / W, float(row[5 + 2 * i]) / H) for i in range(5)]
        out.append(FaceBox(x / W, y / H, w / W, h / H, pts))
    return sorted(out, key=lambda f: -f.w * f.h)


def skin_mask(region: np.ndarray) -> np.ndarray:
    """How skin-coloured each pixel is (0…1): by its red/blue balance, the way skin of every shade sits apart
    from most other things."""
    r, g, b = region[..., 0], region[..., 1], region[..., 2]
    y = luma(region)
    cb, cr = (b - y) * 0.564, (r - y) * 0.713
    m = smoothstep(0.02, 0.07, cr) * (1.0 - smoothstep(0.19, 0.27, cr)) * smoothstep(-0.20, -0.13, cb) \
        * (1.0 - smoothstep(0.0, 0.05, cb)) * smoothstep(0.08, 0.2, y) * (r > g) * (g > b * 0.8)
    return m.astype(F32)


def _smooth_skin(region: np.ndarray, mask: np.ndarray, amount: float, scale: float) -> None:
    y = luma(region)
    soft = guided(y, y, max(2.0, 6.0 * scale), 0.0045)
    soft = gauss(soft, max(0.7, 0.8 * scale))
    keep = 0.22                                                        # of the texture: skin, not plastic
    new_y = soft + (y - soft) * keep
    chroma = region - y[..., None]
    chroma = chroma + (gauss(chroma, max(1.0, 3.0 * scale)) - chroma) * 0.6
    region[:] = region + (new_y[..., None] + chroma - region) * (mask * amount)[..., None]


def _ellipse(shape: tuple[int, int], cx: float, cy: float, rx: float, ry: float, angle: float = 0.0,
             feather: float = 0.35) -> np.ndarray:
    gy, gx = np.mgrid[0:shape[0], 0:shape[1]].astype(F32)
    dx, dy = gx - cx, gy - cy
    c, s = math.cos(angle), math.sin(angle)
    u, v = (dx * c + dy * s) / max(rx, 1.0), (-dx * s + dy * c) / max(ry, 1.0)
    return 1.0 - smoothstep(1.0 - feather, 1.0 + feather, np.sqrt(u * u + v * v))


def apply_face(img: np.ndarray, found: list[FaceBox], tune: dict) -> None:
    """The Face sliders (0…100 each), done to `img` in place. "smooth" works on every skin-coloured part of
    the photo, faces found or not; the rest need `found`."""
    def t(key: str) -> float:
        return float(tune.get(key, 0) or 0) / 100.0

    h, w = img.shape[:2]
    scale = max(h, w) / 1600.0
    if t("smooth") > 0:
        if found:
            for f in found:
                x0, y0 = int(max(0, (f.x - 0.35 * f.w) * w)), int(max(0, (f.y - 0.45 * f.h) * h))
                x1, y1 = int(min(w, (f.x + 1.35 * f.w) * w)), int(min(h, (f.y + 1.6 * f.h) * h))
                if x1 - x0 < 8 or y1 - y0 < 8:
                    continue
                region = img[y0:y1, x0:x1]
                m = gauss(skin_mask(region), max(1.0, 2.0 * scale))
                iod = math.hypot((f.points[0][0] - f.points[1][0]) * w, (f.points[0][1] - f.points[1][1]) * h)
                for px, py in f.points[:2]:                             # the eyes keep every lash
                    m *= 1.0 - _ellipse(m.shape, px * w - x0, py * h - y0, 0.36 * iod, 0.22 * iod)
                mx_, my_ = ((f.points[3][0] + f.points[4][0]) / 2 * w - x0, (f.points[3][1] + f.points[4][1]) / 2 * h - y0)
                m *= 1.0 - _ellipse(m.shape, mx_, my_, 0.48 * iod, 0.24 * iod)
                _smooth_skin(region, m, t("smooth"), max(0.5, iod / 110.0))
        else:
            m = gauss(skin_mask(img), max(1.0, 2.0 * scale))
            _smooth_skin(img, m, t("smooth"), scale)
    for f in found:
        e1 = np.array([f.points[0][0] * w, f.points[0][1] * h])
        e2 = np.array([f.points[1][0] * w, f.points[1][1] * h])
        nose = np.array([f.points[2][0] * w, f.points[2][1] * h])
        m1 = np.array([f.points[3][0] * w, f.points[3][1] * h])
        m2 = np.array([f.points[4][0] * w, f.points[4][1] * h])
        iod = float(np.hypot(*(e2 - e1)))
        if iod < 12:
            continue
        eyes_mid, mouth_mid = (e1 + e2) / 2, (m1 + m2) / 2
        across = (e2 - e1) / iod                                       # along the eyes
        down = mouth_mid - eyes_mid
        down = down / max(float(np.hypot(*down)), 1.0)
        tilt = math.atan2(across[1], across[0])
        x0, y0 = int(max(0, eyes_mid[0] - 2.2 * iod)), int(max(0, eyes_mid[1] - 2.0 * iod))
        x1, y1 = int(min(w, eyes_mid[0] + 2.2 * iod)), int(min(h, eyes_mid[1] + 3.0 * iod))
        if x1 - x0 < 8 or y1 - y0 < 8:
            continue
        box = (x0, y0, x1, y1)
        off = np.array([x0, y0])
        if t("eye_size") or t("slim") or t("nose") or t("smile"):
            warp = _Warp(box)
            if t("eye_size"):
                for e in (e1, e2):
                    warp.bulge(float(e[0]), float(e[1]), 0.46 * iod, 0.30 * t("eye_size"))
            if t("slim"):
                centre = eyes_mid + down * 0.95 * iod
                for side in (-1.0, 1.0):
                    for along, reach in ((0.55, 1.0), (1.05, 0.8), (1.5, 0.55)):
                        c = eyes_mid + down * along * iod + across * side * (1.02 - 0.18 * along) * iod
                        pull = (centre - c) / max(float(np.hypot(*(centre - c))), 1.0) * (0.075 * iod * t("slim") * reach)
                        warp.push(float(c[0]), float(c[1]), 0.75 * iod, float(pull[0]), float(pull[1]))
            if t("nose"):
                for side in (-1.0, 1.0):
                    c = nose + across * side * 0.24 * iod
                    pull = -across * side * (0.05 * iod * t("nose"))
                    warp.push(float(c[0]), float(c[1]), 0.32 * iod, float(pull[0]), float(pull[1]))
            if t("smile"):
                for corner, side in ((m1, -1.0), (m2, 1.0)):
                    pull = (across * side * 0.6 - down) * (0.055 * iod * t("smile"))
                    warp.push(float(corner[0]), float(corner[1]), 0.34 * iod, float(pull[0]), float(pull[1]))
            warp.apply(img)
        region = img[y0:y1, x0:x1]
        if t("light"):
            c = eyes_mid + down * 0.55 * iod - off
            m = _ellipse(region.shape[:2], c[0], c[1], 1.25 * iod, 1.6 * iod, tilt, 0.5) * skin_mask(region) ** 0.5
            region[:] = region + (np.power(np.clip(region, 0, 1), 0.80) - region) * (m * t("light"))[..., None]
        if t("eyes"):
            for e in (e1, e2):
                c = e - off
                m = _ellipse(region.shape[:2], c[0], c[1], 0.30 * iod, 0.17 * iod, tilt, 0.4)
                y = luma(region)
                detail = (y - gauss(y, max(1.0, iod / 24.0))) * 1.5
                hue, sat = hue_sat(np.clip(region, 0, 1))
                white = (1.0 - smoothstep(0.12, 0.35, sat)) * smoothstep(0.35, 0.6, y)
                yy = y[..., None]
                new = region + detail[..., None]
                new = new + (white * 0.5)[..., None] * ((yy + (new - yy) * 0.5) * 1.08 - new)
                new = new + (np.power(np.clip(new, 0, 1), 0.88) - new) * 0.6
                region[:] = region + (np.clip(new, 0, 1) - region) * (m * t("eyes"))[..., None]
        if t("teeth"):
            c = mouth_mid - off
            width = float(np.hypot(*(m2 - m1)))
            m = _ellipse(region.shape[:2], c[0], c[1], 0.56 * width, 0.24 * width, tilt, 0.3)
            hue, sat = hue_sat(np.clip(region, 0, 1))
            y = luma(region)
            lips = smoothstep(0.07, 0.16, region[..., 0] - region[..., 1])       # red well over green: not a tooth
            teeth = (1.0 - smoothstep(0.14, 0.34, sat)) * smoothstep(0.34, 0.55, y) * (1.0 - lips) * m
            teeth = gauss(teeth, max(0.6, iod / 90.0))
            yy = y[..., None]
            new = yy + (region - yy) * 0.30
            new = new + (1.0 - new) * 0.18
            region[:] = region + (new - region) * (teeth * t("teeth"))[..., None]


# ----------------------------------------------------------------------------- blur (portrait / tilt-shift)

@dataclass
class Focus:
    kind: str = ""                          # "" | "round" | "band"
    x: float = 0.5                          # centre, fractions of the edited photo
    y: float = 0.5
    size: float = 0.3                       # the sharp part: radius (round) or half-height (band), of the short side
    angle: float = 0.0                      # band: degrees
    amount: float = 50.0                    # 0…100


def apply_focus(img: np.ndarray, f: Focus) -> np.ndarray:
    if not f.kind or f.amount <= 0:
        return img
    h, w = img.shape[:2]
    short = float(min(h, w))
    gy, gx = np.mgrid[0:h, 0:w].astype(F32)
    dx, dy = gx - f.x * w, gy - f.y * h
    if f.kind == "band":
        t = math.radians(f.angle)
        d = np.abs(-dx * math.sin(t) + dy * math.cos(t))
    else:
        d = np.sqrt(dx * dx + dy * dy)
    r = max(4.0, f.size * short)
    m = smoothstep(r, r * 1.9 + 4.0, d)[..., None]
    sigma = (f.amount / 100.0) * 0.02 * max(h, w)
    near = gauss(img, sigma * 0.45)
    far = gauss(img, sigma)
    blurred = near + (far - near) * smoothstep(r * 1.4, r * 2.6 + 4.0, d)[..., None]
    return (img + (blurred - img) * m).astype(F32)


# ----------------------------------------------------------------------------- frames

FRAMES = [("", "None"), ("border", "Border"), ("polaroid", "Polaroid"), ("rounded", "Rounded Corners"),
          ("cinema", "Cinema Bars"), ("fit", "Fit to Shape")]
FIT_SHAPES = [("1:1", 1.0), ("4:5", 4 / 5), ("5:4", 5 / 4), ("3:4", 3 / 4), ("4:3", 4 / 3), ("2:3", 2 / 3),
              ("3:2", 3 / 2), ("9:16", 9 / 16), ("16:9", 16 / 9), ("1:2", 1 / 2), ("2:1", 2.0)]


@dataclass
class Frame:
    kind: str = ""
    width: float = 5.0                      # border / corner size, % of the short side
    colour: tuple[int, int, int] = (255, 255, 255)
    shape: str = "1:1"                      # fit: the shape to fit into
    blur: bool = False                      # fit: the photo, blurred, behind itself (else the colour)


def apply_frame(img: np.ndarray, f: Frame) -> np.ndarray:
    if not f.kind:
        return img
    h, w = img.shape[:2]
    short = min(h, w)
    col = np.array(f.colour, dtype=F32) / 255.0
    b = max(1, int(round(f.width / 100.0 * short)))
    if f.kind == "border":
        out = np.empty((h + 2 * b, w + 2 * b, 3), dtype=F32)
        out[:] = col
        out[b:b + h, b:b + w] = img
        return out
    if f.kind == "polaroid":
        foot = int(b * 3.4)
        out = np.empty((h + b + foot, w + 2 * b, 3), dtype=F32)
        out[:] = col
        out[b:b + h, b:b + w] = img
        return out
    if f.kind == "rounded":
        r = min(b * 2, short // 2)
        mask = Image.new("L", (w * 2, h * 2), 0)
        ImageDraw.Draw(mask).rounded_rectangle((0, 0, w * 2 - 1, h * 2 - 1), radius=r * 2, fill=255)
        m = (np.asarray(mask.resize((w, h), Image.Resampling.LANCZOS), dtype=F32) / 255.0)[..., None]
        return (img * m + col * (1.0 - m)).astype(F32)
    if f.kind == "cinema":
        want = 2.39
        if w / h >= want:
            return img
        bar = int(round((h - w / want) / 2.0))
        out = img.copy()                                   # the bars are black unless a colour was chosen
        out[:bar] = out[h - bar:] = 0.0 if tuple(f.colour) == (255, 255, 255) else col
        return out
    if f.kind == "fit":
        ratio = dict(FIT_SHAPES).get(f.shape, 1.0)
        if w / h > ratio:
            cw, ch = w, int(round(w / ratio))
        else:
            cw, ch = int(round(h * ratio)), h
        pad = b if f.width > 0 else 0
        cw, ch = cw + 2 * pad, ch + 2 * pad
        if f.blur:
            z = max(cw / w, ch / h)
            back = resize(img, int(math.ceil(w * z)), int(math.ceil(h * z)), Image.Resampling.BILINEAR)
            y0, x0 = (back.shape[0] - ch) // 2, (back.shape[1] - cw) // 2
            back = gauss(back[y0:y0 + ch, x0:x0 + cw], 0.03 * max(cw, ch)) * 0.82
            out = np.ascontiguousarray(back, dtype=F32)
        else:
            out = np.empty((ch, cw, 3), dtype=F32)
            out[:] = col
        y0, x0 = (ch - h) // 2, (cw - w) // 2
        out[y0:y0 + h, x0:x0 + w] = img
        return out
    return img


# ----------------------------------------------------------------------------- the whole edit

@dataclass
class Edit:
    geometry: Geometry = field(default_factory=Geometry)
    look: str = ""
    look_amount: float = 100.0
    adjust: dict = field(default_factory=dict)
    strokes: list[Stroke] = field(default_factory=list)
    face: dict = field(default_factory=dict)
    focus: Focus = field(default_factory=Focus)
    frame: Frame = field(default_factory=Frame)
    texts: list[dict] = field(default_factory=list)      # photo_text.py's layers
    seed: int = 7

    def copy(self) -> "Edit":
        return from_dict(to_dict(self))

    def toned(self) -> bool:
        return bool(self.look) or any(v for k, v in self.adjust.items() if k != "hsl") or \
            any(any(v) for v in (self.adjust.get("hsl") or {}).values())

    def changed(self) -> bool:
        return bool(not self.geometry.plain() or self.toned() or self.strokes or any(self.face.values())
                    or (self.focus.kind and self.focus.amount > 0) or self.frame.kind or self.texts)

    def cropped(self) -> bool:
        return self.geometry.crop != FULL or abs(self.geometry.straighten) > 0.01


def to_dict(e: Edit) -> dict:
    return asdict(e)


def from_dict(d: dict) -> Edit:
    g = dict(d.get("geometry") or {})
    if "crop" in g:
        g["crop"] = tuple(g["crop"])
    fr = dict(d.get("frame") or {})
    if "colour" in fr:
        fr["colour"] = tuple(fr["colour"])
    adjust = {k: (dict(v) if isinstance(v, dict) else v) for k, v in (d.get("adjust") or {}).items()}
    return Edit(geometry=Geometry(**g), look=d.get("look", ""), look_amount=float(d.get("look_amount", 100.0)),
                adjust=adjust,
                strokes=[Stroke(s["tool"], [tuple(p) for p in s["points"]], s["size"], s.get("amount", 0.6),
                                s.get("soft", 0.6)) for s in d.get("strokes") or []],
                face=dict(d.get("face") or {}), focus=Focus(**(d.get("focus") or {})), frame=Frame(**fr),
                texts=[dict(t) for t in d.get("texts") or []], seed=int(d.get("seed", 7)))


def retouched(img: np.ndarray, e: Edit, found: list[FaceBox], progress: Callable[[float], None] | None = None,
              cancelled: Callable[[], bool] | None = None, start: int = 0) -> np.ndarray:
    """Stage one: the strokes from `start` on (the window keeps the earlier ones done), then the face
    sliders. Returns a new array."""
    out = img.copy()
    n = len(e.strokes) - start
    for i, s in enumerate(e.strokes[start:]):
        if cancelled and cancelled():
            break
        apply_stroke(out, s, (lambda p, i=i: progress((i + p) / max(n, 1))) if progress else None, cancelled)
    if any(e.face.values()):
        apply_face(out, found, e.face)
    return out


def toned(img: np.ndarray, e: Edit) -> np.ndarray:
    """Stages three to five: the look, the adjustments, the blur."""
    out = apply_look(img, e.look, e.look_amount / 100.0, e.seed) if e.look else img
    out = apply_adjust(out, e.adjust, e.seed)
    return apply_focus(out, e.focus)


def render(img: np.ndarray, e: Edit, found: list[FaceBox] | None = None, alpha: np.ndarray | None = None,
           progress: Callable[[float], None] | None = None, cancelled: Callable[[], bool] | None = None
           ) -> tuple[np.ndarray, np.ndarray | None]:
    """The whole edit (everything but the text) on `img` — the photo upright, float32. Returns (rgb, alpha):
    the alpha, when the photo has one, turned and cropped with it (a frame makes the photo opaque)."""
    report = progress or (lambda _p: None)
    out = retouched(img, e, found or [], lambda p: report(0.55 * p), cancelled) if (e.strokes or any(e.face.values())) \
        else img
    report(0.55)
    if not e.geometry.plain():
        out = apply_geometry(out, e.geometry)
        if alpha is not None:
            alpha = apply_geometry(alpha, e.geometry)
    report(0.65)
    out = toned(out, e)
    report(0.92)
    if e.frame.kind:
        out = apply_frame(out, e.frame)
        if out.shape[:2] != (alpha.shape if alpha is not None else out.shape[:2]) or e.frame.kind in ("rounded", "cinema"):
            alpha = None
    report(1.0)
    return np.clip(out, 0.0, 1.0), alpha
