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

Each photo is saved like a crop (batch_crop.encode_like / write_in_place): its format, EXIF (pixel size
updated), ICC profile, XMP, tags and dates kept. Photos over ~12 MP are left alone (2× would be ~50 MP and
the network's pass ~200 MP). GIFs and RAW files are left out, as for crops; HDR comes out standard range.
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
from dataclasses import dataclass
from pathlib import Path

import batch_crop

UPSCALED_TAG = "upscaled"                    # the iPhone app's tag for its upscales too
FACTOR = 2
MAX_PIXELS = 12_300_000                      # a 12 MP iPhone photo (4032×3024) still goes; bigger ones don't
TIMEOUT = 20 * 60                            # seconds for one photo — a slow GPU on a 12 MP photo, with room
UPSCAYL_URL = "https://upscayl.org"
ENGINE_NAMES = ("upscayl-bin", "realesrgan-ncnn-vulkan")
PREFERRED = ("upscayl-standard-4x", "realesrgan-x4plus", "high-fidelity-4x", "upscayl-lite-4x",
             "ultrasharp-4x", "4x-ultrasharp", "remacri-4x", "4x_nmkd-siax_200k", "ultramix-balanced-4x",
             "realesr-general-x4v3", "realesrnet-x4plus")
AVOID = ("anime", "digital-art", "digital_art", "cartoon")
APP_DIRS = [Path("/Applications"), Path.home() / "Applications"]
SUPPORT_DIR = Path.home() / "Library" / "Application Support" / "Safe Finder" / "Real-ESRGAN"


class UpscaleError(Exception):
    """Why a photo wasn't upscaled (it is left as it was)."""


class Skipped(UpscaleError):
    """A photo that doesn't need it (already large)."""


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


# ---------------------------------------------------------------------------- upscaling

def can_upscale(path: str) -> bool:
    return batch_crop.can_crop(path)


def run_engine(engine: Engine, src_png: str, out_png: str) -> None:
    """One pass of the network. Raises UpscaleError with what the engine said when it fails."""
    cmd = [engine.binary, "-i", src_png, "-o", out_png, "-s", str(engine.scale), "-m", engine.models,
           "-n", engine.model, "-f", "png"]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=TIMEOUT,
                           cwd=os.path.dirname(engine.binary) or None)
    except subprocess.TimeoutExpired as e:
        raise UpscaleError(f"the engine took over {TIMEOUT // 60} minutes") from e
    except OSError as e:
        raise UpscaleError(f"the engine wouldn't start ({e})") from e
    if r.returncode != 0 or not os.path.isfile(out_png):
        said = [line.strip() for line in (r.stderr + "\n" + r.stdout).splitlines() if line.strip()]
        raise UpscaleError("the engine failed" + (f": {said[-1]}" if said else f" (exit {r.returncode})"))


def upscale(engine: Engine, path: str, factor: int = FACTOR) -> tuple[int, int]:
    """Upscales one photo `factor`× in place. Returns its new size. Raises Skipped (already large),
    UpscaleError or OSError, and leaves the photo as it was then."""
    try:
        src = batch_crop.open_upright(path)
    except batch_crop.CropError as e:
        raise UpscaleError(str(e)) from e
    w, h = src.image.size
    if w * h > MAX_PIXELS:
        raise Skipped(f"already {w}×{h}")
    target = (w * factor, h * factor)
    mode = src.image.mode
    alpha = mode in ("RGBA", "LA", "PA") or (mode == "P" and "transparency" in src.image.info)
    with tempfile.TemporaryDirectory(prefix="safe-finder-upscale-") as td:
        inp, out = os.path.join(td, "in.png"), os.path.join(td, "out.png")
        src.image.convert("RGBA" if alpha else "RGB").save(inp)
        run_engine(engine, inp, out)
        try:
            with batch_crop.Image.open(out) as made:
                made.load()
                big = made.copy()
        except Exception as e:  # noqa: BLE001
            raise UpscaleError(f"the engine's result doesn't open ({e})") from e
    if big.size != target:
        big = big.resize(target, batch_crop.Image.Resampling.LANCZOS)
    if mode in ("L", "LA") and big.mode not in ("L", "LA"):
        big = big.convert("LA" if alpha else "L")              # a greyscale photo stays greyscale
    try:
        data = batch_crop.encode_like(src, big)
    except batch_crop.CropError as e:
        raise UpscaleError(str(e)) from e
    batch_crop.write_in_place(path, data)
    return target


if __name__ == "__main__":                   # python3 mac/ai_upscale.py photo.jpg … — upscale from the shell
    e = find_engine()
    if e is None:
        sys.exit(f"No Real-ESRGAN engine found — install Upscayl ({UPSCAYL_URL}) and try again.")
    for p in sys.argv[1:]:
        try:
            print(p, "→", "×".join(map(str, upscale(e, p))), "with", e.describe())
        except UpscaleError as err:
            print(p, "— left as it was:", err)
