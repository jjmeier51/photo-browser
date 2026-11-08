"""Safe Finder ▸ Convert WebP to JPEG — every .webp photo in a folder (or the selected ones) made a full-resolution,
high-quality JPEG beside it. No Qt here (webp_window.py is the window), so it's testable on its own.

**The JPEG** (`to_jpeg`): the same pixels at the same size — never scaled — saved at quality 95 with full colour
detail (4:4:4: no chroma subsampling, which is what makes a JPEG's colour edges smear), the photo's colour profile
(ICC), EXIF (capture date, camera, GPS, orientation) and XMP kept, and the file's own dates copied over (so it
sorts where the WebP did). Transparency, which JPEG can't hold, goes onto white. An **animated** WebP is left
alone — a JPEG can't move, and keeping one frame would lose the rest. A JPEG of that name already beside it is
never overwritten: the new one is "name 2.jpg". Each JPEG is read back to check it before anything else happens.

**Onto the drive** by the drive's rules (`simpcity.write_file`: temp → fsync → rename; straight in on exFAT,
CLAUDE.md #12). **The originals** go to the Trash only when asked (`convert(trash=…)`) and only once their JPEG
checked out; Safe Finder then moves their tags and Favorites / To AI to the JPEG (`webp_window`), as for a move.
Kept originals give their JPEG their tags, as a copy does.

Pillow does the work (its WebP support reads lossy, lossless and alpha WebP); photos are converted four at a time
— Pillow lets go of Python's lock while it decodes and encodes, so the four really run at once.
"""
from __future__ import annotations

import concurrent.futures
import io
import os
import re
from dataclasses import dataclass, field
from pathlib import Path

QUALITY = 95                  # "high quality": visually lossless; 100 only makes files much bigger
SUBSAMPLING = 0               # 4:4:4 — full colour resolution
LANES = 4
SKIP_DIRS = {".Photo Browser Metadata", ".Spare Folders", ".Safe Finder Staging", ".Trashes", ".fseventsd",
             ".Spotlight-V100", ".TemporaryItems", ".DocumentRevisions-V100"}


def is_webp(path: str) -> bool:
    name = os.path.basename(path)
    return name.lower().endswith(".webp") and not name.startswith(".")


def natural(name: str) -> list:
    return [int(t) if t.isdigit() else t.lower() for t in re.split(r"(\d+)", name)]


def webps_in(paths: list[str], recursive: bool = False) -> list[str]:
    """The .webp files among `paths`, and inside the folders among them (their subfolders too when
    `recursive`; hidden folders never), each once, in name order folder by folder."""
    out: list[str] = []
    seen: set[str] = set()

    def put(p: str) -> None:
        if p not in seen:
            seen.add(p)
            out.append(p)

    for p in paths:
        if os.path.isdir(p):
            if recursive:
                for root, dirs, files in os.walk(p):
                    dirs[:] = sorted((d for d in dirs if not d.startswith(".") and d not in SKIP_DIRS), key=natural)
                    for f in sorted(files, key=natural):
                        if is_webp(f):
                            put(os.path.join(root, f))
            else:
                try:
                    names = sorted((e.name for e in os.scandir(p) if e.is_file()), key=natural)
                except OSError:
                    names = []
                for f in names:
                    if is_webp(f):
                        put(os.path.join(p, f))
        elif is_webp(p) and os.path.isfile(p):
            put(p)
    return out


def target(src: str) -> Path:
    """Where its JPEG goes: beside it, "name.jpg" — or "name 2.jpg"… when that's taken."""
    folder, name = os.path.split(src)
    stem = name[: -len(".webp")]
    dest = Path(folder) / f"{stem}.jpg"
    n = 2
    while os.path.lexists(dest):
        dest = Path(folder) / f"{stem} {n}.jpg"
        n += 1
    return dest


def _flattened(im):
    """The picture as RGB (or greyscale) — transparency onto white, as JPEG has none."""
    from PIL import Image
    if im.mode in ("RGB", "L"):
        return im
    if im.mode in ("RGBA", "LA") or (im.mode == "P" and "transparency" in im.info):
        rgba = im.convert("RGBA")
        flat = Image.new("RGB", rgba.size, (255, 255, 255))
        flat.paste(rgba, mask=rgba.getchannel("A"))
        return flat
    return im.convert("RGB")


def jpeg_bytes(src: str) -> tuple[bytes | None, str]:
    """The WebP at `src` as JPEG bytes (see the module notes), or (None, why not)."""
    from PIL import Image
    try:
        with Image.open(src) as im:
            if (im.format or "").upper() == "JPEG":         # a JPEG only named .webp: its own bytes, not re-encoded
                with open(src, "rb") as f:
                    return f.read(), ""
            if getattr(im, "n_frames", 1) > 1:
                return None, "animated — a JPEG can't move, so it's left as it is"
            im.load()
            icc = im.info.get("icc_profile")
            xmp = im.info.get("xmp")
            exif = im.getexif()
            out = _flattened(im)
            kw: dict = {"quality": QUALITY, "subsampling": SUBSAMPLING, "optimize": True}
            if icc:
                kw["icc_profile"] = icc
            if len(exif):
                kw["exif"] = exif.tobytes()
            if xmp:
                kw["xmp"] = xmp if isinstance(xmp, bytes) else str(xmp).encode("utf-8")
            buf = io.BytesIO()
            out.save(buf, "JPEG", **kw)
            return buf.getvalue(), ""
    except (OSError, ValueError, SyntaxError) as e:   # Pillow's errors for a file it can't read
        return None, f"couldn't be read as a WebP photo ({e})"


def to_jpeg(src: str) -> tuple[str | None, str]:
    """One WebP made a JPEG beside it. Returns (the JPEG's path, "") or (None, why not)."""
    import simpcity as sc
    from PIL import Image
    data, why = jpeg_bytes(src)
    if data is None:
        return None, why
    dest = target(src)
    try:
        sc.write_file(dest, data)
        with Image.open(dest) as check, Image.open(src) as orig:
            check.verify()
            if check.size != orig.size:
                raise OSError("the JPEG came out a different size")
        st = os.stat(src)
        os.utime(dest, (st.st_atime, st.st_mtime))
    except OSError as e:
        try:
            if dest.exists() and os.path.getsize(dest) == len(data):
                dest.unlink()
        except OSError:
            pass
        return None, f"couldn't be saved ({e})"
    return str(dest), ""


@dataclass
class Done:
    converted: list[tuple[str, str]] = field(default_factory=list)    # (the WebP, its JPEG)
    animated: list[str] = field(default_factory=list)                 # left as they are
    failed: list[tuple[str, str]] = field(default_factory=list)       # (the WebP, why)
    trashed: list[str] = field(default_factory=list)                  # originals moved to the Trash
    untrashed: list[str] = field(default_factory=list)                # asked to go, but the Trash refused: still there
    stopped: bool = False


def convert(webps: list[str], trash=None, progress=None, cancelled=None) -> Done:
    """Every WebP in `webps` made a JPEG (four at a time). `trash(path) -> bool`, when given, moves each original
    to the Trash once its JPEG has checked out; `progress(done, total, path)` after each; `cancelled()` stops
    before the next. Runs on a worker thread."""
    done = Done()
    total = len(webps)
    count = 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=LANES, thread_name_prefix="webp") as pool:
        pending: dict[concurrent.futures.Future, str] = {}
        queue = list(webps)
        while queue or pending:
            while queue and len(pending) < LANES * 2 and not (cancelled and cancelled()):
                src = queue.pop(0)
                pending[pool.submit(to_jpeg, src)] = src
            if cancelled and cancelled():
                queue.clear()
                done.stopped = True
            if not pending:
                break
            fin, _ = concurrent.futures.wait(pending, return_when=concurrent.futures.FIRST_COMPLETED)
            for fut in fin:
                src = pending.pop(fut)
                dest, why = fut.result()
                if dest:
                    done.converted.append((src, dest))
                    if trash is not None:
                        (done.trashed if trash(src) else done.untrashed).append(src)
                elif why.startswith("animated"):
                    done.animated.append(src)
                else:
                    done.failed.append((src, why))
                count += 1
                if progress:
                    progress(count, total, src)
    return done
