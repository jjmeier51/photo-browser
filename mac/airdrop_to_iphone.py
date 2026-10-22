#!/usr/bin/env python3
"""AirDrop folders from the Mac straight into the Photo Browser app on the iPhone (standard library only).

    python3 airdrop_to_iphone.py "~/Pictures/PornPics/Lucie Wilde/Beautiful Woman Posing" [MORE FOLDERS…]
    python3 airdrop_to_iphone.py --one "Lucie Wilde" gallery1 gallery2      # several folders, one archive

Each folder becomes one `.pbgallery` archive — a zip under a name that only Photo Browser claims — and
the Mac's AirDrop window opens with the archives. On the iPhone, accepting the AirDrop shows "Open
with Photo Browser"; one tap opens the app's **Received** sheet, where you pick the drive folder they
go in. Each archive unpacks into its own folder there, named after the folder you sent, with its
`gallery.json` / `pornstar.json` sidecars beside the photos (the Categories filter keeps working).
Send a whole star folder and it lands as `<destination>/<Star>/<galleries…>`.

Why an archive: AirDrop can't hand a folder to an iOS app, and a plain `.zip` is claimed by Files and
every other zip-capable app as well, so the phone would ask which one each time. Photos and videos are
stored uncompressed (they're already compressed; AirDrop's speed is the limit anyway) and only the
small sidecars are deflated. File dates are kept. Skipped: `.DS_Store`, AppleDouble `._*` files,
`__MACOSX`, and `.part` downloads still in progress.

How the AirDrop window opens: macOS has no command for it, so a tiny Swift program
(`airdrop_helper.swift`, next to this file) is built once with `swiftc` (Xcode or its Command Line
Tools) into ~/Library/Caches/PhotoBrowser/ and asked to share the archives. Without swiftc the
archives are revealed in Finder instead: right-click ▸ Share ▸ AirDrop.

Archives are written to ~/Library/Caches/PhotoBrowser/AirDrop/ (`--out DIR` to choose) and left
there so a failed send can be retried; `--clean` first deletes archives older than a day.

Options:
    --one NAME     put everything given into a single archive NAME.pbgallery (one folder on the phone)
    --out DIR      where to write the archives
    --reveal       don't open AirDrop, just show the archives in Finder
    --no-send      only build the archives (prints their paths)
    --clean        delete archives older than a day from the output folder first
"""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
import time
import zipfile
from pathlib import Path

ARCHIVE_EXT = ".pbgallery"

# Already-compressed media: stored as-is (deflating them wastes minutes and saves nothing).
STORED_EXT = {
    ".jpg", ".jpeg", ".png", ".gif", ".webp", ".heic", ".heif", ".avif", ".bmp", ".tif", ".tiff",
    ".mp4", ".m4v", ".mov", ".webm", ".mkv", ".avi", ".m4a", ".mp3", ".aac", ".zip", ".pdf",
}
SKIP_NAMES = {".DS_Store", "__MACOSX", "Thumbs.db"}
SKIP_SUFFIXES = (".part", ".crdownload", ".download")


def default_out_dir() -> Path:
    return Path.home() / "Library" / "Caches" / "PhotoBrowser" / "AirDrop"


def wanted(path: Path) -> bool:
    """False for Finder junk, AppleDouble shadows and downloads still in flight."""
    name = path.name
    if name in SKIP_NAMES or name.startswith("._") or name.endswith(SKIP_SUFFIXES):
        return False
    return True


def archive_name(name: str) -> str:
    """The archive's file name: the folder's name, kept as it is (it becomes the folder on the phone),
    minus characters iOS can't take in a file name."""
    clean = "".join("-" if c in '/:\\' else c for c in name).strip().rstrip(".")
    return (clean or "Folder") + ARCHIVE_EXT


def _add(zf: zipfile.ZipFile, path: Path, arcname: str) -> int:
    kind = zipfile.ZIP_STORED if path.suffix.lower() in STORED_EXT else zipfile.ZIP_DEFLATED
    zf.write(path, arcname, compress_type=kind)
    return path.stat().st_size


def archive_folder(folder: Path, out_dir: Path, name: str | None = None, only: set[str] | None = None,
                   progress=None) -> Path:
    """Zip `folder` into `out_dir/<name>.pbgallery` with the folder itself at the archive's top level
    (`<name>/…`), which is what the app expects. `only` limits the top-level *subfolders* taken to those
    names; files directly in `folder` (pornstar.json, a cover) always come along. Returns the archive."""
    folder = Path(folder).expanduser().resolve()
    if not folder.is_dir():
        raise FileNotFoundError(f"{folder} isn't a folder")
    top = (name or folder.name).strip() or folder.name
    out_dir = Path(out_dir).expanduser()
    out_dir.mkdir(parents=True, exist_ok=True)
    dest = out_dir / archive_name(top)
    tmp = dest.with_name(dest.name + ".part")
    total = 0
    count = 0
    with zipfile.ZipFile(tmp, "w", allowZip64=True, strict_timestamps=False) as zf:
        for root, dirs, files in os.walk(folder):
            rootp = Path(root)
            dirs[:] = sorted(d for d in dirs if wanted(rootp / d)
                             and (only is None or rootp != folder or d in only))
            for f in sorted(files):
                p = rootp / f
                if not wanted(p) or not p.is_file():
                    continue
                rel = p.relative_to(folder).as_posix()
                total += _add(zf, p, f"{top}/{rel}")
                count += 1
                if progress:
                    progress(count, total)
    if count == 0:
        tmp.unlink(missing_ok=True)
        raise ValueError(f"{folder} has no files to send")
    os.replace(tmp, dest)
    return dest


def archive_items(items: list[Path], out_dir: Path, one: str | None = None, progress=None) -> list[Path]:
    """One archive per folder; loose files are gathered into one archive named after their folder.
    With `one`, everything goes into a single archive whose top-level folder is `one`."""
    items = [Path(i).expanduser().resolve() for i in items]
    missing = [str(i) for i in items if not i.exists()]
    if missing:
        raise FileNotFoundError("not found: " + ", ".join(missing))
    out_dir = Path(out_dir).expanduser()
    out_dir.mkdir(parents=True, exist_ok=True)
    if one:
        return [_archive_mixed(items, out_dir, one, progress)]
    archives: list[Path] = []
    for folder in (i for i in items if i.is_dir()):
        archives.append(archive_folder(folder, out_dir, progress=progress))
    files = [i for i in items if i.is_file()]
    if files:
        parents = {f.parent for f in files}
        top = files[0].parent.name if len(parents) == 1 and files[0].parent.name else "Photos"
        archives.append(_archive_mixed(files, out_dir, top, progress))
    return archives


def _archive_mixed(items: list[Path], out_dir: Path, top: str, progress=None) -> Path:
    """Folders and files side by side under one top-level folder `top`."""
    dest = out_dir / archive_name(top)
    tmp = dest.with_name(dest.name + ".part")
    total = count = 0
    with zipfile.ZipFile(tmp, "w", allowZip64=True, strict_timestamps=False) as zf:
        for item in items:
            if item.is_file():
                if wanted(item):
                    total += _add(zf, item, f"{top}/{item.name}")
                    count += 1
                continue
            for root, dirs, files in os.walk(item):
                rootp = Path(root)
                dirs[:] = sorted(d for d in dirs if wanted(rootp / d))
                for f in sorted(files):
                    p = rootp / f
                    if not wanted(p) or not p.is_file():
                        continue
                    rel = p.relative_to(item.parent).as_posix()
                    total += _add(zf, p, f"{top}/{rel}")
                    count += 1
                    if progress:
                        progress(count, total)
    if count == 0:
        tmp.unlink(missing_ok=True)
        raise ValueError("nothing to send")
    os.replace(tmp, dest)
    return dest


# ----------------------------------------------------------------------------- sending


def helper_source() -> Path | None:
    """airdrop_helper.swift: next to this file, or inside Safe Finder.app's Resources when frozen."""
    here = Path(__file__).resolve().parent
    candidates = [here / "airdrop_helper.swift"]
    if getattr(sys, "frozen", False):
        contents = Path(sys.executable).resolve().parent.parent
        candidates += [contents / "Resources" / "airdrop_helper.swift",
                       Path(getattr(sys, "_MEIPASS", here)) / "airdrop_helper.swift"]
    return next((c for c in candidates if c.is_file()), None)


def build_helper(log=print) -> Path | None:
    """The compiled helper, building it when missing or older than its source. None without swiftc."""
    src = helper_source()
    if src is None or sys.platform != "darwin":
        return None
    out = Path.home() / "Library" / "Caches" / "PhotoBrowser" / "airdrop_helper"
    if out.is_file() and out.stat().st_mtime >= src.stat().st_mtime:
        return out
    # Don't call swiftc when the Command Line Tools aren't installed: the stub would pop an installer.
    if subprocess.run(["xcode-select", "-p"], capture_output=True).returncode != 0:
        return None
    out.parent.mkdir(parents=True, exist_ok=True)
    log("Building the AirDrop helper (once) …")
    r = subprocess.run(["xcrun", "swiftc", "-O", "-o", str(out), str(src)], capture_output=True, text=True)
    if r.returncode != 0:
        log(r.stderr.strip() or "swiftc failed")
        return None
    return out


def reveal(paths: list[Path]) -> None:
    if sys.platform == "darwin" and paths:
        subprocess.Popen(["open", "-R", *map(str, paths)])


def send(archives: list[Path], log=print, reveal_only: bool = False) -> int:
    """Open the AirDrop window for `archives`. Returns the helper's exit code (0 sent, 3 cancelled), or
    2 when AirDrop couldn't be opened here — the archives are then shown in Finder for a manual share."""
    if not archives:
        return 2
    helper = None if reveal_only else build_helper(log)
    if helper is None:
        reveal(archives)
        log("Right-click the archive in Finder ▸ Share ▸ AirDrop, and pick your iPhone."
            if reveal_only else
            "Couldn't open AirDrop from here (Xcode's Command Line Tools aren't installed), so the archives "
            "are shown in Finder: right-click ▸ Share ▸ AirDrop, and pick your iPhone.")
        return 2
    log("Opening AirDrop — pick your iPhone, then accept on the phone and choose Photo Browser.")
    r = subprocess.run([str(helper), *map(str, archives)], capture_output=True, text=True)
    if r.returncode == 0:
        log("Sent. On the iPhone, Photo Browser's Received sheet asks where to put the folders.")
    elif r.returncode == 3:
        log("Cancelled.")
    elif r.returncode == 2:
        reveal(archives)
        log("AirDrop isn't available on this Mac; the archives are shown in Finder.")
    else:
        reveal(archives)
        log("AirDrop failed: " + (r.stderr.strip() or f"exit {r.returncode}") + ". The archives are shown in Finder.")
    return r.returncode


def clean(out_dir: Path, older_than: float = 86400) -> int:
    n = 0
    now = time.time()
    for p in Path(out_dir).expanduser().glob(f"*{ARCHIVE_EXT}*"):
        try:
            if now - p.stat().st_mtime > older_than:
                p.unlink()
                n += 1
        except OSError:
            pass
    return n


def human(n: float) -> str:
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or unit == "TB":
            return f"{n:.0f} {unit}" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.1f} TB"


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="AirDrop folders to the Photo Browser app on the iPhone.")
    ap.add_argument("items", nargs="+", help="folders (or files) to send")
    ap.add_argument("--one", metavar="NAME", help="everything into one archive, one folder NAME on the phone")
    ap.add_argument("--out", metavar="DIR", default=str(default_out_dir()), help="where the archives are written")
    ap.add_argument("--reveal", action="store_true", help="show the archives in Finder instead of opening AirDrop")
    ap.add_argument("--no-send", action="store_true", help="only build the archives")
    ap.add_argument("--clean", action="store_true", help="delete archives older than a day first")
    args = ap.parse_args(argv)

    out = Path(args.out).expanduser()
    if args.clean:
        n = clean(out)
        if n:
            print(f"Removed {n} old archive{'s' if n != 1 else ''}.")
    last = {"n": 0}

    def progress(count: int, total: int) -> None:
        if count - last["n"] >= 200:
            last["n"] = count
            print(f"  {count} files, {human(total)} …", flush=True)

    try:
        archives = archive_items([Path(i) for i in args.items], out, one=args.one, progress=progress)
    except (FileNotFoundError, ValueError) as e:
        print(e, file=sys.stderr)
        return 1
    for a in archives:
        print(f"{a.name}  ({human(a.stat().st_size)})")
    if args.no_send:
        print(out)
        return 0
    rc = send(archives, reveal_only=args.reveal)
    return 0 if rc in (0, 2) else rc


if __name__ == "__main__":
    sys.exit(main())
