"""AI upscaling for Safe Finder: 2× with Real-ESRGAN, the open-source super-resolution network, run on the
Mac's own GPU (Vulkan, through MoltenVK). Nothing is uploaded — the photo goes to a temporary file on the
Mac, the engine writes its result beside it, and the photo is rewritten in place.

Real-ESRGAN isn't part of macOS, so the engine comes from one of:
  - the free Upscayl app (upscayl.org, or `brew install --cask upscayl`), which bundles it (`upscayl-bin`,
    a build of realesrgan-ncnn-vulkan) with photo models — looked for inside the app wherever it keeps
    them, in /Applications or ~/Applications;
  - a realesrgan-ncnn-vulkan release unzipped into ~/Library/Application Support/Safe Finder/Real-ESRGAN
    (its `models` folder beside it), or on the PATH;
  - either of those picked by hand (Choose Engine… — an app or the engine itself), remembered by Safe Finder.
The models are 4× networks: the photo is upscaled 4× by the network and brought to exactly 2× with Lanczos
— the usual way to get 2× out of them, and sharper than running the network on a halved photo. The best
general-photo model found is used (`PREFERRED`); anime and digital-art models are passed over.

Each photo is saved like a crop (batch_crop.encode_like): its format, EXIF (pixel size updated), ICC
profile, XMP, tags and dates kept — in place (write_in_place), or as a new photo beside it, "name
(upscaled).ext" (write_beside: the same metadata, extended attributes and created/modified dates; its tags
are the caller's to carry over). GIFs and RAW files are left out, as for crops; HDR comes out standard range.

Large photos: a photo over ~12 MP (`MAX_PIXELS`) is "already large" — left alone unless the caller says
`allow_large` (the window asks, with a warning of how big the results will be: `estimate`). Those go through
the network in tiles (`TILE_CORE` px of the photo each, with `TILE_PAD` px of the photo around them for
context, only each tile's core kept), so its 4× pass never holds more than a 12 MP photo's would and the
size of the photo doesn't matter to memory beyond the result itself. A result over `MAX_RESULT_PIXELS`
(400 MP — a 100 MP photo) or wider than its format can hold (JPEG 65,500 px a side, WebP 16,383) isn't
attempted (`too_large`). Pillow's decompression-bomb guard is raised to match: the engine's 4× pass of even
a 12 MP photo (~195 MP) was over its 179 MP limit, so its result didn't open.

Progress: the engine prints how far its pass is, a percentage per tile ("42.50%"), as Upscayl's own app
reads it; `upscale` reports each photo in stages — reading, the network's pass (most of the time), saving —
so a window can show a real bar. Stop kills the engine mid-pass and leaves the photo as it was.

Texture: these networks are trained to clean noise away, so grain and fine texture go with it. `texture`
blends that much of a plain Lanczos enlargement of the original back into the result — the original's grain
at that strength, most of the network's sharpness kept. The model can be chosen too (`photo_models`): they
differ a lot in how much they smooth.

Speed: the network runs on the GPU; around it, a 12 MP photo's 4× pass is a 192 MP image, and handing that
over as PNG (written by the engine, read back here) took about as long as the pass itself. So it comes
back as a quality-100 JPEG (4:4:4) unless the photo has transparency, decoded straight at half size by the
JPEG decoder, which is the 2× wanted. Macs with plenty of memory use bigger tiles than the engine picks
(fewer, larger GPU jobs), with a retry at the engine's own size if that fails; a window runs two photos
at once where there's memory for it (`lanes`).
No Qt here (upscale_window.py is the window), so it's testable on its own.
"""
from __future__ import annotations

import glob
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Callable, NamedTuple

import batch_crop

# Our own photos and the engine's own results, not files off the internet: room for the 4× pass of a large
# tile and a 400 MP result (Pillow refuses at twice this).
batch_crop.Image.MAX_IMAGE_PIXELS = max(batch_crop.Image.MAX_IMAGE_PIXELS or 0, 600_000_000)

UPSCALED_TAG = "upscaled"                    # the iPhone app's tag for its upscales too
FACTOR = 2
MAX_PIXELS = 12_300_000                      # "already large" above this (a 12 MP iPhone photo is 4032×3024)
MAX_RESULT_PIXELS = 400_000_000              # the most a result may be (a 100 MP photo, 2×): memory for it, twice
MAX_SIDE = {"JPEG": 65_500, "WEBP": 16_383}  # what a format can hold a side; the rest: 65,500 too, to be safe
TILE_CORE = 3000                             # px of a large photo per network pass (its 4× pass ≈ a 9 MP photo's)
TILE_PAD = 48                                # px of the photo around each tile, for context; cut away after
BYTES_PER_PIXEL = {"JPEG": 0.9, "HEIF": 0.35, "WEBP": 0.6, "PNG": 2.4, "TIFF": 3.0, "BMP": 3.0}   # rough, for `estimate`
TIMEOUT = 20 * 60                            # seconds for one photo — a slow GPU on a 12 MP photo, with room
UPSCAYL_URL = "https://upscayl.org"
ENGINE_NAMES = ("upscayl-bin", "realesrgan-ncnn-vulkan")
PREFERRED = ("upscayl-standard-4x", "realesrgan-x4plus", "high-fidelity-4x", "upscayl-lite-4x",
             "ultrasharp-4x", "4x-ultrasharp", "remacri-4x", "4x_nmkd-siax_200k", "ultramix-balanced-4x",
             "realesr-general-x4v3", "realesrnet-x4plus")
AVOID = ("anime", "digital-art", "digital_art", "cartoon")
MODEL_NOTES = {                               # what the known photo models are like, for the model menu
    "upscayl-standard-4x": "Upscayl Standard — clean and smooth",
    "upscayl-lite-4x": "Upscayl Lite — faster, a little softer",
    "high-fidelity-4x": "High Fidelity — keeps more fine detail",
    "remacri-4x": "Remacri — natural texture, less smoothing",
    "ultramix-balanced-4x": "Ultramix Balanced — between smooth and sharp",
    "ultrasharp-4x": "UltraSharp — very crisp, cleans noise away",
    "4x-ultrasharp": "UltraSharp — very crisp, cleans noise away",
    "realesrgan-x4plus": "Real-ESRGAN x4plus — the original, smooth",
    "realesr-general-x4v3": "Real-ESRGAN General v3 — fast",
}
APP_DIRS = [Path("/Applications"), Path.home() / "Applications"]
NEW_LABEL = "upscaled"                       # a new photo is "name (upscaled).ext"
READ_DONE, ENGINE_DONE = 0.04, 0.92          # of one photo: reading it, then the network's pass, then saving
_PERCENT = re.compile(r"(\d+(?:\.\d+)?)\s*%")
SUPPORT_DIR = Path.home() / "Library" / "Application Support" / "Safe Finder" / "Real-ESRGAN"


class UpscaleError(Exception):
    """Why a photo wasn't upscaled (it is left as it was)."""


class Skipped(UpscaleError):
    """A photo that doesn't need it (already large)."""


class Stopped(UpscaleError):
    """Stopped during the network's pass: the photo is left as it was."""


class Upscaled(NamedTuple):
    path: str                   # the photo itself, or the new one beside it
    width: int
    height: int


Progress = Callable[[str, float], None]     # stage ("read", "engine", "save"), how much of this photo is done


@dataclass(frozen=True)
class Engine:
    binary: str
    models: str                 # the folder holding <model>.param / <model>.bin
    model: str
    scale: int                  # the network's own factor (4 for the usual photo models)
    label: str                  # "Upscayl" / "Real-ESRGAN", for the confirmation

    def describe(self) -> str:
        return f"{self.model} ({self.label})"


# ---------------------------------------------------------------------------- finding the engine

def models_in(folder: str) -> list[str]:
    """The models in a folder: names with both a .param and a .bin file."""
    try:
        names = os.listdir(folder)
    except OSError:
        return []
    params = {n[:-6] for n in names if n.endswith(".param")}
    return sorted(m for m in params if f"{m}.bin" in names)


def pick_model(models: list[str]) -> str | None:
    """The best general-photo model of those there: the first of PREFERRED found, else any that isn't an
    anime or digital-art model."""
    by_fold = {m.casefold(): m for m in models}
    for want in PREFERRED:
        if want in by_fold:
            return by_fold[want]
    usable = [m for m in models if not any(a in m.casefold() for a in AVOID)]
    return usable[0] if usable else None


def model_scale(model: str) -> int:
    """The network's factor from its name ("…-4x", "x4plus", "4x_…"); 4 when the name doesn't say."""
    m = re.search(r"(?<![0-9])([234])x(?![0-9])|x([234])(?![0-9])", model.casefold())
    return int(m.group(1) or m.group(2)) if m else 4


def _app_of(path: str) -> str | None:
    p = Path(path).resolve()
    for parent in [p, *p.parents]:
        if parent.suffix == ".app":
            return str(parent)
    return None


def engine_from(path: str, label: str | None = None) -> Engine | None:
    """The engine at `path` — the engine binary itself, or an app bundle that holds one — with its models
    found beside it (models/, ../models, …) or anywhere inside its app. None when there isn't a usable one."""
    path = os.path.expanduser(path)
    if path.endswith(".app") and os.path.isdir(path):
        app = path
        binaries = [b for name in ENGINE_NAMES
                    for b in glob.glob(os.path.join(app, "Contents", "**", name), recursive=True)]
    else:
        app = _app_of(path)
        binaries = [path] if os.path.isfile(path) else []
    for binary in binaries:
        if not os.access(binary, os.X_OK):
            continue
        here = os.path.dirname(binary)
        folders = [os.path.join(here, "models"), os.path.join(here, "..", "models"),
                   os.path.join(here, "..", "Resources", "models"), os.path.join(here, "..", "..", "models")]
        if app:
            folders += sorted({os.path.dirname(p) for p in
                               glob.glob(os.path.join(app, "Contents", "**", "*.param"), recursive=True)})
        for folder in folders:
            model = pick_model(models_in(folder))
            if model:
                name = label or ("Upscayl" if (app and "upscayl" in os.path.basename(app).casefold())
                                 or "upscayl" in os.path.basename(binary) else "Real-ESRGAN")
                return Engine(binary, os.path.normpath(folder), model, model_scale(model), name)
    return None


def find_engine(chosen: str | None = None) -> Engine | None:
    """The engine to use: the one picked by hand (`chosen`), else Upscayl's, else a Real-ESRGAN release in
    Safe Finder's folder or on the PATH. SAFE_FINDER_UPSCALER names one outright (tests)."""
    override = os.environ.get("SAFE_FINDER_UPSCALER")
    if override:
        return engine_from(override)
    if chosen:
        e = engine_from(chosen)
        if e:
            return e
    for folder in APP_DIRS:
        for app in sorted(glob.glob(str(folder / "Upscayl*.app"))):
            e = engine_from(app, "Upscayl")
            if e:
                return e
    for name in ("realesrgan-ncnn-vulkan", "upscayl-bin"):
        for b in sorted(glob.glob(str(SUPPORT_DIR / "**" / name), recursive=True)) + \
                 ([shutil.which(name)] if shutil.which(name) else []):
            e = engine_from(b)
            if e:
                return e
    return None


def photo_models(engine: Engine) -> list[str]:
    """The photo models beside the engine — the preferred ones first, anime and digital-art left out."""
    found = [m for m in models_in(engine.models) if not any(a in m.casefold() for a in AVOID)]
    order = {m: i for i, m in enumerate(PREFERRED)}
    return sorted(found, key=lambda m: (order.get(m.casefold(), len(order)), m.casefold()))


def with_model(engine: Engine, model: str | None) -> Engine:
    """The engine with another of its models, when it has that one."""
    if model and model != engine.model and model in models_in(engine.models):
        return replace(engine, model=model, scale=model_scale(model))
    return engine


def model_label(model: str) -> str:
    return MODEL_NOTES.get(model.casefold(), model)


def _memory_gb() -> float:
    try:
        return os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES") / 1024 ** 3
    except (ValueError, OSError, AttributeError):
        return 0.0


def tile_size() -> int:
    """The tile the network works in. The engine picks at most 200 px however much memory there is; on a
    Mac's shared memory bigger tiles mean fewer, larger GPU jobs and less overlap computed twice. 0 = the
    engine's own pick. SAFE_FINDER_UPSCALE_TILE overrides it."""
    env = os.environ.get("SAFE_FINDER_UPSCALE_TILE")
    if env is not None:
        return int(env)
    gb = _memory_gb()
    return 512 if gb >= 30 else 400 if gb >= 15 else 256 if gb >= 7.5 else 0


def lanes(photos: int) -> int:
    """How many photos to upscale at once: two keep the GPU busy while the other one is read or saved,
    where there's memory for two (a 12 MP photo's pass holds a couple of GB)."""
    return 2 if photos > 1 and _memory_gb() >= 15 else 1


_tile_failed = False                         # a big tile failed once: the engine's own pick from then on


# ---------------------------------------------------------------------------- upscaling

def can_upscale(path: str) -> bool:
    return batch_crop.can_crop(path)


class Size(NamedTuple):
    width: int                  # as shown (turned by its EXIF orientation)
    height: int
    fmt: str
    bytes: int

    @property
    def pixels(self) -> int:
        return self.width * self.height

    @property
    def large(self) -> bool:
        return self.pixels > MAX_PIXELS


def size_of(path: str) -> Size | None:
    """A photo's size from its header (cheap), turned as it shows; None when it can't be read."""
    try:
        with batch_crop.Image.open(path) as im:
            w, h = im.size
            if im.getexif().get(0x0112) in (5, 6, 7, 8):
                w, h = h, w
            return Size(w, h, im.format or "", os.path.getsize(path))
    except Exception:  # noqa: BLE001
        return None


def too_large(w: int, h: int, fmt: str, factor: int = FACTOR) -> str:
    """Why a w×h photo can't be upscaled at all ("" when it can)."""
    tw, th = w * factor, h * factor
    side = MAX_SIDE.get(fmt, 65_500)
    if max(tw, th) > side:
        return f"it would be {tw:,}×{th:,} — wider than {fmt or 'its format'} can hold ({side:,} px)"
    if tw * th > MAX_RESULT_PIXELS:
        return f"it would be {tw * th / 1e6:,.0f} MP — over the {MAX_RESULT_PIXELS // 1_000_000} MP Safe Finder makes"
    return ""


def estimate(size: Size, factor: int = FACTOR) -> int:
    """About how many bytes the upscale will be: its pixels at what its format typically takes at the
    quality it's saved at — and never less than twice the original."""
    px = size.pixels * factor * factor
    return int(max(px * BYTES_PER_PIXEL.get(size.fmt, 1.0), size.bytes * 2))


def run_engine(engine: Engine, src_png: str, out_path: str, on_percent: Callable[[float], None] | None = None,
               stop: threading.Event | None = None, tile: int = 0, fmt: str = "png") -> None:
    """One pass of the network, its result written to `out_path` as `fmt` (png / jpg). Its percentages (a
    line per tile) go to `on_percent`, 0–1, as they come; `stop` kills it (Stopped). Raises UpscaleError
    with what the engine said when it fails."""
    cmd = [engine.binary, "-i", src_png, "-o", out_path, "-s", str(engine.scale), "-m", engine.models,
           "-n", engine.model, "-f", fmt] + (["-t", str(tile)] if tile else [])
    try:
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors="replace",
                                cwd=os.path.dirname(engine.binary) or None)
    except OSError as e:
        raise UpscaleError(f"the engine wouldn't start ({e})") from e
    said: list[str] = []

    def read() -> None:
        assert proc.stdout is not None
        for line in proc.stdout:                   # "\r"-updated lines split too (universal newlines)
            line = line.strip()
            m = _PERCENT.fullmatch(line)
            if m:
                if on_percent is not None:
                    on_percent(min(1.0, float(m.group(1)) / 100))
            elif line:
                said.append(line)
                del said[:-20]

    reader = threading.Thread(target=read, name="esrgan-output", daemon=True)
    reader.start()
    deadline = time.monotonic() + TIMEOUT
    try:
        while reader.is_alive():
            reader.join(0.1)
            if stop is not None and stop.is_set():
                raise Stopped("stopped")
            if time.monotonic() > deadline:
                raise UpscaleError(f"the engine took over {TIMEOUT // 60} minutes")
        code = proc.wait()
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait()
    if code != 0 or not os.path.isfile(out_path):
        raise UpscaleError("the engine failed" + (f": {said[-1]}" if said else f" (exit {code})"))


def _looks_blank(im: "batch_crop.Image.Image", like: "batch_crop.Image.Image") -> bool:
    """A result that came out black where the photo isn't — what an engine short of GPU memory can do."""
    lo, hi = im.convert("L").resize((32, 32)).getextrema()
    return hi < 8 and like.convert("L").resize((32, 32)).getextrema()[1] > 40


def _pass(engine: Engine, inp: str, td: str, fmt: str, target: tuple[int, int], on_engine: Callable[[float], None],
          stop: threading.Event | None, tile: int) -> "batch_crop.Image.Image":
    """The network's pass and its result, at `target`. `on_engine` hears how far the pass is (0–1)."""
    out = os.path.join(td, f"out.{fmt}")
    if os.path.exists(out):
        os.remove(out)
    run_engine(engine, inp, out, on_engine, stop, tile=tile, fmt=fmt)
    try:
        with batch_crop.Image.open(out) as made:
            if made.format == "JPEG":
                made.draft("RGB", target)          # decoded straight at half size by the JPEG decoder
            made.load()
            big = made.copy()
    except Exception as e:  # noqa: BLE001
        raise UpscaleError(f"the engine's result doesn't open ({e})") from e
    if big.size != target:
        big = big.resize(target, batch_crop.Image.Resampling.LANCZOS)
    return big


def _network(engine: Engine, piece: "batch_crop.Image.Image", td: str, fmt: str, factor: int,
             on_engine: Callable[[float], None], stop: threading.Event | None) -> "batch_crop.Image.Image":
    """One picture (a whole photo, or a large one's tile) through the network, at `factor`×: in the tile
    size this Mac takes, once more at the engine's own if that fails or comes out blank."""
    global _tile_failed
    inp = os.path.join(td, "in.png")
    piece.save(inp, compress_level=1)                          # read once by the engine: speed over size
    target = (piece.width * factor, piece.height * factor)
    if max(piece.size) * engine.scale > MAX_SIDE["JPEG"]:
        fmt = "png"                                            # a long panorama's 4× pass: wider than JPEG holds
    tile = 0 if _tile_failed else tile_size()
    try:
        big = _pass(engine, inp, td, fmt, target, on_engine, stop, tile)
        if tile and _looks_blank(big, piece):
            raise UpscaleError("blank result")
    except Stopped:
        raise
    except UpscaleError:
        if not tile:
            raise
        _tile_failed = True                                     # too big a tile for this Mac: the engine's own
        on_engine(0.0)
        big = _pass(engine, inp, td, fmt, target, on_engine, stop, 0)
    return big.convert(piece.mode)


def _tiled(engine: Engine, flat: "batch_crop.Image.Image", td: str, fmt: str, factor: int, texture: float,
           report: Progress, stop: threading.Event | None) -> "batch_crop.Image.Image":
    """A large photo through the network a tile at a time (module notes): each tile with `TILE_PAD` px of
    the photo around it, only its core kept; the texture blended in per tile too, so nothing but the result
    is ever held at full size."""
    w, h = flat.size
    cells = [(x, y) for y in range(0, h, TILE_CORE) for x in range(0, w, TILE_CORE)]
    canvas = batch_crop.Image.new(flat.mode, (w * factor, h * factor))
    span = ENGINE_DONE - READ_DONE
    for k, (x, y) in enumerate(cells):
        if stop is not None and stop.is_set():
            raise Stopped("stopped")
        box = (max(0, x - TILE_PAD), max(0, y - TILE_PAD), min(w, x + TILE_CORE + TILE_PAD),
               min(h, y + TILE_CORE + TILE_PAD))
        piece = flat.crop(box)
        big = _network(engine, piece, td, fmt, factor,
                       lambda p, k=k: report("engine", READ_DONE + span * (k + p) / len(cells)), stop)
        core = ((x - box[0]) * factor, (y - box[1]) * factor,
                (min(w, x + TILE_CORE) - box[0]) * factor, (min(h, y + TILE_CORE) - box[1]) * factor)
        kept = big.crop(core)
        if texture > 0:
            plain = piece.resize(big.size, batch_crop.Image.Resampling.LANCZOS).crop(core)
            kept = batch_crop.Image.blend(kept, plain, min(1.0, texture))
        canvas.paste(kept, (x * factor, y * factor))
        report("engine", READ_DONE + span * (k + 1) / len(cells))
    return canvas


def upscale(engine: Engine, path: str, factor: int = FACTOR, *, as_new: bool = False, texture: float = 0.0,
            progress: Progress | None = None, stop: threading.Event | None = None,
            allow_large: bool = False) -> Upscaled:
    """Upscales one photo `factor`× — in place, or (`as_new`) into a new photo beside it — with `texture`
    (0–1) of a plain enlargement of the original blended back in. Returns where it went and its size.
    `progress` hears how far along it is; `stop` ends the network's pass (Stopped). A photo over
    `MAX_PIXELS` is Skipped ("already large") unless `allow_large` — then it goes through in tiles — and
    one whose result would be too large for its format or for memory is Skipped either way. Raises Skipped,
    UpscaleError or OSError, and leaves the photo as it was then."""
    report = progress or (lambda _stage, _done: None)
    report("read", 0.0)
    try:
        src = batch_crop.open_upright(path)
    except batch_crop.CropError as e:
        raise UpscaleError(str(e)) from e
    w, h = src.image.size
    if (why := too_large(w, h, src.fmt, factor)):
        raise Skipped(f"too large to upscale — {why}")
    large = w * h > MAX_PIXELS
    if large and not allow_large:
        raise Skipped(f"already {w}×{h}")
    target = (w * factor, h * factor)
    mode = src.image.mode
    alpha = mode in ("RGBA", "LA", "PA") or (mode == "P" and "transparency" in src.image.info)
    flat = src.image.convert("RGBA" if alpha else "RGB")
    fmt = "png" if alpha else "jpg"
    with tempfile.TemporaryDirectory(prefix="safe-finder-upscale-") as td:
        report("engine", READ_DONE)
        if large:
            big = _tiled(engine, flat, td, fmt, factor, texture, report, stop)
        else:
            big = _network(engine, flat, td, fmt, factor,
                           lambda p: report("engine", READ_DONE + (ENGINE_DONE - READ_DONE) * p), stop)
        report("save", ENGINE_DONE)
    if texture > 0 and not large:                              # (a large photo's is blended tile by tile)
        plain = flat.resize(target, batch_crop.Image.Resampling.LANCZOS)
        big = batch_crop.Image.blend(big, plain, min(1.0, texture))
    if mode in ("L", "LA") and big.mode not in ("L", "LA"):
        big = big.convert("LA" if alpha else "L")              # a greyscale photo stays greyscale
    try:
        data = batch_crop.encode_like(src, big)
    except batch_crop.CropError as e:
        raise UpscaleError(str(e)) from e
    report("save", (ENGINE_DONE + 1) / 2)
    if as_new:
        made = batch_crop.write_beside(path, data, NEW_LABEL)
    else:
        batch_crop.write_in_place(path, data)
        made = path
    report("save", 1.0)
    return Upscaled(made, *target)


if __name__ == "__main__":                   # python3 mac/ai_upscale.py [--new] [--large] photo.jpg … — from the shell
    e = find_engine()
    if e is None:
        sys.exit(f"No Real-ESRGAN engine found — install Upscayl ({UPSCAYL_URL}) and try again.")
    new = "--new" in sys.argv[1:]
    large = "--large" in sys.argv[1:]                         # photos over 12 MP too
    for p in (a for a in sys.argv[1:] if a not in ("--new", "--large")):
        try:
            r = upscale(e, p, as_new=new, allow_large=large)
            print(p, "→", r.path if new else "", f"{r.width}×{r.height}", "with", e.describe())
        except UpscaleError as err:
            print(p, "— left as it was:", err)
