#!/usr/bin/env python3
"""Rebuild folders that iOS shows as EMPTY even though the Mac shows their contents.

The SSD is exFAT. Folders created or filled from macOS Finder sometimes end up with directory
entries the iOS exFAT driver can't read: the folder appears on the iPhone/iPad (Files app and
Photo Browser alike) but opens empty. Nothing in an iOS app can read past that — the fix is to
rewrite the directory on the Mac. Copying a folder to a brand-new folder writes fresh, clean
directory entries; swapping the copy in under the original name fixes it for iOS, and because the
name and place are unchanged, Photo Browser's Favorites, captions, covers etc. stay attached.

For each folder:
  1. copy everything into a hidden sibling `.<name>.rebuilding` (file dates preserved;
     dot-files such as macOS `._*` AppleDouble and `.DS_Store` are skipped),
  2. verify every file arrived with the same size,
  3. move the original to the Trash (via Finder, so it's recoverable until you empty it;
     if Finder can't, it's parked as hidden `.<name>.original` next to it),
  4. rename the copy to the original name and give it the original's dates.
Any failure before step 3 removes the copy and leaves the original exactly as it was.

Usage (DRY RUN unless --apply):
  python3 rebuild_exfat_folders.py "/Volumes/SSD/Porn/Briana Banks"            # one folder (+ everything in it)
  python3 rebuild_exfat_folders.py /Volumes/SSD --since 7                         # folders created in the last 7 days
  python3 rebuild_exfat_folders.py /Volumes/SSD --since 7 --apply

Then eject the SSD from Finder before unplugging it.
"""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

JUNK = {".DS_Store", ".localized"}


def is_junk(name: str) -> bool:
    """macOS bookkeeping (`._*` AppleDouble, `.DS_Store`) and other dot-files — not carried over
    (they're invisible on the iPhone anyway, and AppleDouble files are rewritten by macOS as needed)."""
    return name in JUNK or name.startswith(".")


def human(n: float) -> str:
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or unit == "TB":
            return f"{n:.0f} {unit}" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.1f} TB"


def inventory(folder: Path) -> tuple[list[tuple[Path, int]], int]:
    """(relative file path, size) for every real file under `folder`, and the number of subfolders."""
    files: list[tuple[Path, int]] = []
    dirs = 0
    for root, dirnames, filenames in os.walk(folder):
        dirnames[:] = [d for d in dirnames if not d.startswith(".")]
        dirs += len(dirnames)
        for name in filenames:
            if is_junk(name):
                continue
            p = Path(root) / name
            try:
                files.append((p.relative_to(folder), p.stat().st_size))
            except OSError as e:
                raise RuntimeError(f"can't read {p}: {e}") from e
    return files, dirs


def birth_time(p: Path) -> float:
    st = p.stat()
    return getattr(st, "st_birthtime", st.st_mtime)


def recent_folders(root: Path, days: float) -> list[Path]:
    """Top-most folders under `root` created (or, lacking a birth time, modified) within `days`.
    A recent folder's subfolders aren't listed separately — rebuilding it rewrites them too."""
    cutoff = time.time() - days * 86400
    found: list[Path] = []
    for dirpath, dirnames, _ in os.walk(root):
        dirnames[:] = sorted(d for d in dirnames if not d.startswith(".") and d not in (".Trashes", ".Spotlight-V100", ".fseventsd"))
        keep = []
        for d in dirnames:
            p = Path(dirpath) / d
            try:
                if birth_time(p) >= cutoff:
                    found.append(p)
                    continue        # covered by rebuilding p
            except OSError:
                pass
            keep.append(d)
        dirnames[:] = keep
    return found


def to_trash(path: Path) -> bool:
    """Move `path` to the Trash through Finder (recoverable). False if Finder couldn't."""
    if sys.platform != "darwin":
        return False
    script = f'tell application "Finder" to delete (POSIX file "{str(path)}" as alias)'
    r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    return r.returncode == 0 and not path.exists()


def rebuild(folder: Path, apply: bool) -> bool:
    folder = folder.resolve()
    files, dirs = inventory(folder)
    total = sum(s for _, s in files)
    label = f"{folder}  ({len(files)} files, {dirs} subfolders, {human(total)})"
    if not apply:
        print(f"  would rebuild {label}")
        return True
    print(f"Rebuilding {label}")
    free = shutil.disk_usage(folder.parent).free
    if free < total * 1.05 + 50 * 1024 * 1024:
        print(f"  skipped: needs {human(total)} free for the copy, only {human(free)} available")
        return False

    temp = folder.parent / f".{folder.name}.rebuilding"
    if temp.exists():
        shutil.rmtree(temp)
    try:
        shutil.copytree(folder, temp, copy_function=shutil.copy2,
                        ignore=lambda _d, names: [n for n in names if is_junk(n)])
        for rel, size in files:
            got = (temp / rel).stat().st_size
            if got != size:
                raise RuntimeError(f"{rel}: copied {got} bytes, expected {size}")
        os.sync()
    except Exception as e:  # noqa: BLE001 — leave the original untouched on any failure
        print(f"  FAILED, original left as it was: {e}")
        shutil.rmtree(temp, ignore_errors=True)
        return False

    st = folder.stat()
    if to_trash(folder):
        where = "moved to the Trash"
    else:
        parked = folder.parent / f".{folder.name}.original"
        if parked.exists():
            shutil.rmtree(parked)
        folder.rename(parked)
        where = f"parked as hidden {parked.name} (delete it once you've checked the iPhone)"
    temp.rename(folder)
    try:
        os.utime(folder, (st.st_atime, st.st_mtime))
    except OSError:
        pass
    os.sync()
    print(f"  done — original {where}")
    return True


def from_list(list_file: Path, root: Path) -> list[Path]:
    """Folders from Drive Health's exported list (one drive-relative path per line), under `root`.
    Shallowest first; a folder inside one already listed is dropped — rebuilding the parent rewrites
    it too."""
    rels = [line.strip().strip("/") for line in list_file.read_text("utf-8").splitlines() if line.strip()]
    rels.sort(key=lambda r: (r.count("/"), r))
    chosen: list[str] = []
    for r in rels:
        if any(r == c or r.startswith(c + "/") for c in chosen):
            continue
        chosen.append(r)
    out = []
    for r in chosen:
        p = root / r
        if p.is_dir():
            out.append(p)
        else:
            print(f"  not found on the Mac, skipped: {r}")
    return out


def main() -> None:
    ap = argparse.ArgumentParser(description="Rebuild exFAT folders that iOS shows as empty or can't open.")
    ap.add_argument("paths", nargs="*", type=Path, help="folders to rebuild, or a drive/folder to search with --since")
    ap.add_argument("--since", type=float, metavar="DAYS",
                    help="instead of rebuilding PATHS, rebuild every folder under them created in the last DAYS days")
    ap.add_argument("--list", type=Path, metavar="FILE",
                    help="rebuild the folders in FILE — the list Photo Browser's Drive Health exports "
                         "(Share button; drive-relative paths) — under --root")
    ap.add_argument("--root", type=Path, metavar="DRIVE", help="the SSD for --list, e.g. \"/Volumes/Extreme SSD\"")
    ap.add_argument("--apply", action="store_true", help="actually rebuild (default: dry run, just list)")
    args = ap.parse_args()

    targets: list[Path] = []
    if args.list:
        if not args.root or not args.root.is_dir():
            sys.exit("--list needs --root \"/Volumes/<SSD name>\"")
        targets += from_list(args.list, args.root)
    for p in args.paths:
        if not p.is_dir():
            sys.exit(f"Not a folder: {p}")
        targets += recent_folders(p, args.since) if args.since is not None else [p]
    if not targets:
        print("No folders to rebuild.")
        return
    # A ":" in a name is how macOS stores a "/" typed in Finder; exFAT can't hold either, and iOS can't
    # open such folders whatever their contents. Rename those (in Photo Browser if possible, so its
    # labels follow) — rebuilding keeps the name, so it can't fix them.
    for t in targets:
        if ":" in t.name or "/" in t.name:
            print(f"  NOTE: “{t.name}” has a “/” (shown as “:”) in its name — rename it without one; "
                  "a rebuild alone won't make it readable on iOS.")
    if not args.apply:
        print(f"DRY RUN — {len(targets)} folder(s); add --apply to rebuild:")
    ok = sum(rebuild(t, args.apply) for t in targets)
    if args.apply:
        print(f"\n{ok}/{len(targets)} rebuilt. Eject the SSD in Finder before unplugging it, "
              "then open the folders on the iPhone/iPad.")


if __name__ == "__main__":
    main()
