"""Ways to enlarge a downloaded photo — the choice a downloader offers (Depop's first). No Qt here.

One upscale doesn't suit every photo: Real-ESRGAN's default model smooths skin and fabric to plastic, a
sharpened plain enlargement makes a compressed JPEG's blocks and halos louder. So the person picks, and can
try the pick on one of their own photos first (depop_downloader's Preview):

- **AI models** (`ai:<model>`) — Real-ESRGAN through the upscaler AI Upscale 2× uses (ai_upscale.py, Upscayl's
  engine), each of its photo models by name (Standard, High Fidelity, Remacri, UltraSharp…), with **texture** — a
  share of the plain enlargement blended back in so grain survives (ai_upscale's own `texture`).
- **Clean** (no AI) — for compressed photos: enlarged (Lanczos), then an edge-keeping smoothing of the brightness
  (photo_edit's guided filter) that takes out JPEG blocks and ringing without blurring edges, then a gentle sharpen.
- **Sharp** (no AI) — Lanczos and a light sharpen: what downloads always got without an AI upscaler.
- **Soft** (no AI) — plain bicubic, nothing added: never crunchy, never invented.

`upscale_file` writes in place through batch_crop (the photo's format, profile, EXIF and dates kept).
"""
from __future__ import annotations

from typing import Callable

TEXTURE = 0.25                                  # the AI's default share of the plain enlargement kept
MAX_PIXELS = 12_300_000                         # photos already this large are left alone (as before)

PLAIN = [("clean", "Clean — smooths JPEG blocks, then enlarges (no AI)"),
         ("sharp", "Sharp — enlarges and sharpens (no AI)"),
         ("soft", "Soft — plain enlargement, nothing added (no AI)")]


def methods(engine=None) -> list[tuple[str, str]]:
    """(key, label) for every way on offer: the AI's photo models first when there's an upscaler, then the plain ones."""
    out: list[tuple[str, str]] = []
    if engine is not None:
        import ai_upscale
        for m in ai_upscale.photo_models(engine):
            out.append((f"ai:{m}", f"AI — {ai_upscale.model_label(m)}"))
    return out + PLAIN


def default(engine=None) -> str:
    """The AI's preferred model when there is one, else Clean."""
    if engine is not None:
        import ai_upscale
        m = ai_upscale.pick_model(ai_upscale.photo_models(engine))
        if m:
            return f"ai:{m}"
    return "clean"


def is_ai(method: str) -> bool:
    return method.startswith("ai:")


def label(method: str, engine=None) -> str:
    return next((t for k, t in methods(engine) if k == method), method)


def enlarge(im, method: str, factor: int):
    """A Pillow picture enlarged `factor`× by one of the plain methods (`PLAIN`)."""
    from PIL import Image, ImageFilter
    w, h = im.size
    size = (w * factor, h * factor)
    if method == "soft":
        return im.resize(size, Image.Resampling.BICUBIC)
    if method == "sharp":
        big = im.resize(size, Image.Resampling.LANCZOS)
        return big.filter(ImageFilter.UnsharpMask(radius=1.2, percent=60, threshold=2))
    # clean: smooth the blocks and halos in the brightness, keep edges and colour, then a light sharpen
    import numpy as np
    import photo_edit as pe
    mode = im.mode
    alpha = im.getchannel("A") if mode in ("RGBA", "LA") else None
    rgb = im.convert("RGB").resize(size, Image.Resampling.LANCZOS)
    a = np.asarray(rgb, dtype=np.float32) / 255.0
    y = pe.luma(a)
    smooth = pe.guided(y, y, max(1.0, 0.75 * factor), 0.0009)
    a = np.clip(a + (smooth - y)[..., None] * 0.85, 0.0, 1.0)
    out = Image.fromarray(np.clip(a * 255.0 + 0.5, 0, 255).astype(np.uint8), "RGB")
    out = out.filter(ImageFilter.UnsharpMask(radius=1.0, percent=35, threshold=3))
    if alpha is not None:
        out.putalpha(alpha.resize(size, Image.Resampling.LANCZOS))
    return out


def upscale_file(path: str, method: str, factor: int = 2, texture: float = TEXTURE, engine=None,
                 stop: Callable[[], bool] | None = None) -> bool:
    """`path` enlarged `factor`× in place by `method`. False when it was left as it was (already large, or it
    couldn't be read); an AI method whose upscaler fails falls back to Clean."""
    import batch_crop
    if is_ai(method) and engine is not None:
        import ai_upscale
        try:
            ai_upscale.upscale(ai_upscale.with_model(engine, method[3:]), path, factor, texture=texture)
            return True
        except ai_upscale.Skipped:
            return False
        except (ai_upscale.UpscaleError, OSError):
            method = "clean"                      # the upscaler failed: the best of the plain ones instead
    elif is_ai(method):
        method = "clean"
    try:
        src = batch_crop.open_upright(path)
        w, h = src.image.size
        if w * h > MAX_PIXELS:
            return False
        big = enlarge(src.image, method, factor)
        data = batch_crop.encode_like(src, big)
        with open(path, "wb") as f:
            f.write(data)
        return True
    except Exception:  # noqa: BLE001 — a photo that can't be upscaled is kept as it came
        return False
