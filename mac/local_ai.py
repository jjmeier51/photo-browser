"""Pictures made on this Mac — no account, nothing uploaded: FLUX.2 [klein] 4B run by **mflux** (MIT; Apple's MLX).

**Why this engine and model** (the research is in `docs/feature-notes.md` §6ai): mflux is the one maintained tool
that generates natively on Apple Silicon from the command line; klein 4B is Apache-2.0, needs no Hugging Face
account, draws a picture in 4 steps, and takes **reference photos** (`mflux-generate-flux2-edit --image-paths`) —
which is how a model (`ai_models.py`) is drawn on a Mac that can't train one.

**What this Mac can do** (`plan`): by its unified memory.
- under 16 GB: not offered;
- 16 GB (an M1 mini): generate with the 4-bit model in low-memory mode, up to 2 reference photos, 768 px by
  default (1024 offered). **Training isn't possible** — the only guidance for training klein puts it at 32 GB;
- 24 GB: the same with the 8-bit model and up to 3 references;
- 32 GB and up: 8-bit, up to 4 references, 1024 px. (Training would fit from here; it isn't built yet.)

**How it's installed** (`install`, on first use, with the person's go-ahead): mflux can't live inside Safe
Finder.app (a frozen app has no Python to run it with, and its MLX/torch pins are tight), so it gets its own
environment — `~/Library/Application Support/Safe Finder/AI/env`, made by **uv** (which also fetches the Python
it needs) with mflux pinned to `MFLUX_VERSION`. Then `prepare` runs `mflux-save` once: the model comes down from
Hugging Face (about 16 GB) and a quantised copy (about 4 GB at 4-bit) is kept in `…/AI/engines`; generating
loads that copy, with `HF_HUB_OFFLINE=1` — after the first download nothing here touches the network.

**How a picture is made** (`generate`): one child process per batch (`mflux-generate-flux2`, or `-edit` with
reference photos), several seeds in one run so the model loads once; progress is read off its step counter; the
Mac is kept awake; Stop terminates it. The host app never imports MLX — if the engine runs out of memory, it's the
child that dies. Every flag used here is from mflux 0.24.0's own argument parser; the version is pinned because
its options change between releases.

Pictures are marked as AI-made in their metadata (IPTC Digital Source Type "trainedAlgorithmicMedia") when
ExifTool is there — on top of the prompt and settings mflux writes itself.

SAFE_FINDER_AI_ENGINE names a folder of stand-in commands (tests).
"""
from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

MFLUX_VERSION = "0.24.0"
PYTHON_VERSION = "3.12"
MODEL = "flux2-klein-4b"                       # mflux's name for FLUX.2 [klein] 4B, the distilled (4-step) one
STEPS = 4
DOWNLOAD_GB = 17                               # the model as it comes down (transformer + text encoder + VAE)
SIZES = [("Square 768", 768, 768), ("Square 1024", 1024, 1024), ("Portrait 768 × 1024", 768, 1024),
         ("Landscape 1024 × 768", 1024, 768), ("Portrait 832 × 1216", 832, 1216), ("Landscape 1216 × 832", 1216, 832)]
AI_SOURCE = "http://cv.iptc.org/newscodes/digitalsourcetype/trainedAlgorithmicMedia"
IS_MAC = sys.platform == "darwin"


def ai_dir() -> Path:
    return Path.home() / "Library" / "Application Support" / "Safe Finder" / "AI"


def env_dir() -> Path:
    return ai_dir() / "env"


def engines_dir() -> Path:
    return ai_dir() / "engines"


# ----------------------------------------------------------------------------- what this Mac can do

def memory_gb() -> float:
    """The Mac's unified memory, in GB (0 when it can't be read)."""
    over = os.environ.get("SAFE_FINDER_AI_MEMORY_GB")
    if over:
        try:
            return float(over)
        except ValueError:
            pass
    try:
        if IS_MAC:
            return int(subprocess.run(["sysctl", "-n", "hw.memsize"], capture_output=True, text=True,
                                      timeout=5).stdout.strip()) / 2 ** 30
        return os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES") / 2 ** 30
    except (OSError, ValueError, subprocess.SubprocessError):
        return 0.0


def apple_silicon() -> bool:
    if os.environ.get("SAFE_FINDER_AI_ENGINE"):
        return True
    if not IS_MAC:
        return False
    try:
        return subprocess.run(["sysctl", "-n", "hw.optional.arm64"], capture_output=True, text=True,
                              timeout=5).stdout.strip() == "1"
    except (OSError, subprocess.SubprocessError):
        return False


@dataclass
class Plan:
    ok: bool                       # can this Mac generate at all
    why: str                       # when it can't — or what to expect when it can
    quantize: int = 4              # bits the model is kept at
    low_ram: bool = True
    max_refs: int = 2
    size: int = 768                # the default long side
    can_train: bool = False


def plan(memory: float | None = None) -> Plan:
    gb = memory_gb() if memory is None else memory
    if not apple_silicon():
        return Plan(False, "Making pictures on the Mac needs an Apple Silicon Mac (M1 or later).")
    if gb and gb < 15:
        return Plan(False, f"This Mac has {gb:.0f} GB of memory; making pictures on it needs 16 GB.")
    if gb < 23:
        return Plan(True, "16 GB: the compact (4-bit) model, up to 2 reference photos. Expect a few minutes a "
                          "picture, and close other apps first — it uses most of the Mac's memory while it runs.",
                    4, True, 2, 768, False)
    if gb < 31:
        return Plan(True, "24 GB: the 8-bit model, up to 3 reference photos.", 8, True, 3, 1024, False)
    return Plan(True, f"{gb:.0f} GB: the 8-bit model, up to 4 reference photos.", 8, False, 4, 1024, True)


# ----------------------------------------------------------------------------- the engine's programs

def _stand_in() -> Path | None:
    d = os.environ.get("SAFE_FINDER_AI_ENGINE")
    return Path(d) if d else None


def tool(name: str) -> str:
    """The path of one of mflux's commands in the AI environment."""
    return str((_stand_in() or env_dir() / "bin") / name)


def find_uv() -> str | None:
    found = shutil.which("uv")
    if found:
        return found
    for p in (Path.home() / ".local/bin/uv", Path.home() / ".cargo/bin/uv", Path("/opt/homebrew/bin/uv"),
              Path("/usr/local/bin/uv")):
        if p.is_file():
            return str(p)
    return None


UV_INSTALL = "curl -LsSf https://astral.sh/uv/install.sh | sh"


def installed() -> bool:
    return os.path.isfile(tool("mflux-generate-flux2")) and os.path.isfile(tool("mflux-save"))


def engine_folder(quantize: int) -> Path:
    """Where the quantised copy of the model is kept (mflux's own naming: <repo>-mflux-q<N>)."""
    return engines_dir() / f"FLUX.2-klein-4B-mflux-q{quantize}"


def saved(quantize: int) -> bool:
    """Whether this Mac's quantised copy of the model has been made."""
    f = engine_folder(quantize)
    return (f / "mflux_model.json").is_file() or (f.is_dir() and any(f.rglob("*.safetensors")))


# When the copy can't be made (a 16 GB Mac may not have the room to load the whole model at once, which
# `mflux-save` does), pictures are made "on the fly" instead: the model is quantised as each batch starts, with
# mflux's small text encoder (`--small-text-encoder`: Qwen3-0.6B + an adapter in place of the 7.5 GB one — the
# loaded model drops from 4.3 to 3.3 GB at 4-bit). Slower to start each time, and fine prompt details can drift,
# but it fits. This file says that's how this Mac does it, and whether everything it needs has been fetched.
def _fly_file() -> Path:
    return engines_dir() / "on-the-fly.json"


def fly_mode(quantize: int) -> bool:
    return not saved(quantize) and _fly_file().is_file()


def _fly_fetched() -> bool:
    try:
        import json
        return bool(json.loads(_fly_file().read_text()).get("fetched"))
    except (OSError, ValueError):
        return False


def _set_fly(fetched: bool) -> None:
    import json
    engines_dir().mkdir(parents=True, exist_ok=True)
    _fly_file().write_text(json.dumps({"fetched": fetched, "since": round(time.time())}))


def prepared(quantize: int) -> bool:
    return saved(quantize) or fly_mode(quantize)


def free_gb(path: Path | None = None) -> float:
    p = path or ai_dir()
    while not p.exists() and p.parent != p:
        p = p.parent
    try:
        return shutil.disk_usage(p).free / 2 ** 30
    except OSError:
        return 0.0


def _env(offline: bool) -> dict[str, str]:
    env = dict(os.environ)
    env.pop("PYTHONPATH", None)                       # a frozen app's own paths mean nothing to this Python
    env.pop("PYTHONHOME", None)
    env["PYTHONUNBUFFERED"] = "1"
    env["HF_HUB_DISABLE_TELEMETRY"] = "1"
    if offline:
        env["HF_HUB_OFFLINE"] = "1"                   # the model's on this Mac: nothing to ask the network
    return env


class Stopped(Exception):
    pass


def _run(cmd: list[str], on_line: Callable[[str], None], stop: Callable[[], bool], offline: bool = False,
         cwd: str | None = None) -> int:
    """Runs a command, handing over what it prints a line at a time (a progress bar's carriage returns count
    as line ends). Stop terminates it and raises Stopped."""
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=_env(offline), cwd=cwd,
                            stdin=subprocess.DEVNULL)
    assert proc.stdout is not None
    buf = b""
    try:
        while True:
            chunk = proc.stdout.read1(4096) if hasattr(proc.stdout, "read1") else proc.stdout.read(4096)
            if not chunk:
                break
            buf += chunk
            parts = re.split(rb"[\r\n]", buf)
            buf = parts.pop()
            for part in parts:
                text = part.decode("utf-8", "replace").strip()
                if text:
                    on_line(text)
            if stop():
                raise Stopped()
        if buf.strip():
            on_line(buf.decode("utf-8", "replace").strip())
        return proc.wait()
    except Stopped:
        proc.terminate()
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
        raise
    finally:
        if proc.poll() is None:
            proc.kill()


def install(on_line: Callable[[str], None], stop: Callable[[], bool] = lambda: False) -> None:
    """Makes the AI environment and puts mflux in it. Raises RuntimeError with what to tell the person."""
    uv = find_uv()
    if uv is None:
        raise RuntimeError("uv isn't installed. It's the small tool that sets up the AI engine's own Python:\n\n"
                           f"    {UV_INSTALL}\n\nRun that in Terminal (or `brew install uv`), then try again.")
    env = env_dir()
    env.parent.mkdir(parents=True, exist_ok=True)
    python = env / "bin" / "python"
    if not python.is_file():
        on_line("Making the AI engine's Python environment…")
        if _run([uv, "venv", "--python", PYTHON_VERSION, str(env)], on_line, stop) != 0:
            raise RuntimeError("The AI engine's Python environment couldn't be made — the lines above say why.")
    on_line(f"Installing mflux {MFLUX_VERSION} (about 1 GB)…")
    if _run([uv, "pip", "install", "--python", str(python), f"mflux=={MFLUX_VERSION}"], on_line, stop) != 0:
        raise RuntimeError("mflux couldn't be installed — the lines above say why.")
    if not installed():
        raise RuntimeError("mflux was installed but its commands aren't where they should be.")


def prepare(quantize: int, on_line: Callable[[str], None], stop: Callable[[], bool] = lambda: False) -> None:
    """Downloads FLUX.2 klein 4B and keeps a quantised copy for this Mac (once). Raises RuntimeError."""
    dest = engine_folder(quantize)
    if prepared(quantize):
        return
    small = memory_gb() < 23
    need = DOWNLOAD_GB + 6
    have = free_gb()
    if have and have < need:
        raise RuntimeError(f"The model needs about {need} GB free to set up ({DOWNLOAD_GB} GB to download, "
                           f"the rest for the copy this Mac uses); {have:.0f} GB is free.")
    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.exists():
        shutil.rmtree(dest, ignore_errors=True)       # a half-made copy from a run that was stopped
    on_line(f"Downloading FLUX.2 klein 4B (about {DOWNLOAD_GB} GB) and making this Mac's copy — this is the long "
            "part, and only happens once…")
    code = _run([tool("mflux-save"), "--model", MODEL, "--quantize", str(quantize), "--path", str(dest)],
                on_line, stop)
    if code != 0 or not saved(quantize):
        shutil.rmtree(dest, ignore_errors=True)
        if small:
            on_line("This Mac's copy of the model couldn't be made (most likely not enough memory to load it whole). "
                    "Pictures will be made the lighter way instead: a little slower to start, with the small text "
                    "encoder.")
            _set_fly(False)
            return
        raise RuntimeError("The model couldn't be set up — the lines above say why. (If the Mac ran out of memory, "
                           "close other apps and try again: this step needs the most.)")


# ----------------------------------------------------------------------------- making pictures

_STEP = re.compile(r"(\d+)\s*/\s*(\d+)\s*\[")          # tqdm's "2/4 [00:41<00:41, 20.5s/it]"


ENGINE_NAME = "FLUX.2 klein 4B (on this Mac)"


def command(prompt: str, seeds: list[int], width: int, height: int, output: str, quantize: int, low_ram: bool,
            references: list[str]) -> list[str]:
    """The mflux command for one batch (every flag is from mflux 0.24.0's parser)."""
    cmd = [tool("mflux-generate-flux2-edit" if references else "mflux-generate-flux2")]
    if saved(quantize):
        cmd += ["--model", str(engine_folder(quantize)), "--base-model", MODEL]
    else:                                              # on the fly (see `fly_mode`)
        cmd += ["--model", MODEL, "--quantize", str(quantize), "--small-text-encoder"]
    cmd += ["--prompt", prompt, "--steps", str(STEPS), "--seed", *[str(s) for s in seeds],
           "--width", str(width), "--height", str(height), "--output", output]
    if low_ram:
        cmd.append("--low-ram")
    if references:
        cmd += ["--image-paths", *references]
    return cmd


def reference_copies(paths: list[str], folder: Path, long_side: int) -> list[str]:
    """Reference photos sized for the engine: every reference adds to what it holds in memory, so on a small Mac
    they go in no bigger than the picture being made."""
    from PIL import Image
    folder.mkdir(parents=True, exist_ok=True)
    out: list[str] = []
    for i, p in enumerate(paths):
        try:
            with Image.open(p) as im:
                im = im.convert("RGB")
                if max(im.size) > long_side:
                    im.thumbnail((long_side, long_side), Image.Resampling.LANCZOS)
                dest = folder / f"ref{i + 1}.jpg"
                im.save(dest, "JPEG", quality=92)
                out.append(str(dest))
        except Exception:  # noqa: BLE001 — a reference that can't be read is left out
            continue
    return out


def mark_ai_made(paths: list[str]) -> None:
    """Says in each picture's own metadata that it was made by AI (the IPTC "Digital Source Type")."""
    exiftool = shutil.which("exiftool") or next((p for p in ("/opt/homebrew/bin/exiftool", "/usr/local/bin/exiftool")
                                                 if os.path.isfile(p)), None)
    if not exiftool or not paths:
        return
    try:
        subprocess.run([exiftool, "-overwrite_original", "-q", f"-XMP-iptcExt:DigitalSourceType={AI_SOURCE}",
                        "-XMP-xmp:CreatorTool=Safe Finder (FLUX.2 klein 4B, mflux)", *paths],
                       capture_output=True, timeout=120)
    except (OSError, subprocess.SubprocessError):
        pass


@dataclass
class Result:
    files: list[str]
    seconds: float
    log: list[str]


def generate(prompt: str, save: Callable[[bytes], str], count: int = 1, width: int = 768, height: int = 768,
             references: list[str] | None = None, seed: int | None = None, the_plan: Plan | None = None,
             progress: Callable[[int, int, int, int], None] = lambda picture, pictures, step, steps: None,
             on_line: Callable[[str], None] = lambda s: None,
             stop: Callable[[], bool] = lambda: False) -> Result:
    """Makes `count` pictures of `prompt`. Each one is handed to `save` (its PNG bytes → where it was put), so
    the caller places it the way the drive wants files written. `references`: photos the picture should take its
    subject from (as many as this Mac's plan allows are used). Raises RuntimeError with what went wrong, Stopped
    when stopped."""
    p = the_plan or plan()
    if not p.ok:
        raise RuntimeError(p.why)
    if not installed() or not prepared(p.quantize):
        raise RuntimeError("The AI engine isn't set up yet.")
    first = int(time.time()) % 1_000_000_000 if seed is None else seed
    seeds = [first + i for i in range(max(1, count))]
    work = ai_dir() / "work" / f"{os.getpid()}-{int(time.time() * 1000)}"
    work.mkdir(parents=True, exist_ok=True)
    refs = reference_copies(list(references or [])[:p.max_refs], work, max(width, height))
    output = str(work / "picture {seed}.png")
    log: list[str] = []
    started = time.monotonic()
    picture = [0]
    last_step = [0]

    def line(text: str) -> None:
        m = _STEP.search(text)
        if m:
            step, steps = int(m.group(1)), int(m.group(2))
            if steps == STEPS:
                if step < last_step[0]:
                    picture[0] += 1                   # the counter started over: the next picture
                last_step[0] = step
                progress(min(picture[0] + 1, len(seeds)), len(seeds), step, steps)
            return
        log.append(text)
        del log[:-200]
        on_line(text)

    awake = None
    try:
        import clone_drive
        awake = clone_drive.keep_awake()
    except Exception:  # noqa: BLE001
        awake = None
    files: list[str] = []
    try:
        offline = saved(p.quantize) or _fly_fetched()    # on the fly, the first run still fetches the small encoder
        code = _run(command(prompt, seeds, width, height, output, p.quantize, p.low_ram, refs), line, stop,
                    offline=offline)
        for s in seeds:
            made = output.format(seed=s)
            if os.path.isfile(made):
                with open(made, "rb") as f:
                    files.append(save(f.read()))
    finally:
        if awake is not None:
            awake.terminate()
        shutil.rmtree(work, ignore_errors=True)
    if not files:
        tail = "\n".join(log[-12:])
        hint = "\n\nIt may have run out of memory — close other apps, or make a smaller picture." \
            if code in (-9, 137) or "memory" in tail.lower() else ""
        raise RuntimeError(f"No picture came back (the engine ended with code {code}).{hint}\n\n{tail}".strip())
    if fly_mode(p.quantize) and not _fly_fetched():
        _set_fly(True)                                # it has everything now: offline from here on
    mark_ai_made(files)
    return Result(files, time.monotonic() - started, log)
