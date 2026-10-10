#!/usr/bin/env python3
"""Rebuild folders that iOS shows as EMPTY even though the Mac shows their contents.

The SSD is exFAT. Folders created or filled from macOS Finder sometimes end up with directory
entries the iOS exFAT driver can't read: the folder appears on the iPhone/iPad (Files app and
Photo Browser alike) but opens empty. Nothing in an iOS app can read past that — the fix is to
rewrite the directory on the Mac. Copying a folder to a brand-new folder writes fresh, clean
directory entries; swapping the copy in under the original name fixes it for iOS, and because the
name and place are unchanged, Photo Browser's Favorites, captions, covers etc. stay attached.

For each folder (default, "copy" mode):
  1. copy everything into a hidden sibling `.<name>.rebuilding` (file dates preserved;
     dot-files such as macOS `._*` AppleDouble and `.DS_Store` are skipped),
  2. verify every file arrived with the same size,
  3. move the original to the Trash (via Finder, so it's recoverable until you empty it;
     if Finder can't, it's parked as hidden `.<name>.original` next to it),
  4. rename the copy to the original name and give it the original's dates.
Any failure before step 3 removes the copy and leaves the original exactly as it was.
Needs free space for a second copy of the folder.

`--low-space` (also `--move`) is the same fresh copy for folders too big to copy whole (the
Kardashians folders: 46k photos): every file is copied fresh into a hidden `.<name>.fresh` sibling
and its original deleted as soon as the copy checks out (in batches, after the drive has been
synced), so it needs free space for only about one batch. The whole folder, subfolders included, is
rebuilt; when every file is across, the emptied original goes to the Trash and the fresh folder
takes its name. Interrupted runs resume (run the same command again). It never moves or renames a
file — an earlier version did, and moving files out of a broken folder carried the breakage into
the new one (Oct 10). Leftovers of interrupted atomic saves (`<name>.sb-xxxxxxxx-XXXXXX`) are
listed; `--drop-leftovers` deletes the ones whose finished file is there and at least as large.

Nothing here flushes a folder (fsync on a directory) — the volume is synced with `sync()`.

Usage (DRY RUN unless --apply):
  python3 rebuild_exfat_folders.py "/Volumes/SSD/Porn/Briana Banks"            # one folder (+ everything in it)
  python3 rebuild_exfat_folders.py /Volumes/SSD --since 7                         # folders created in the last 7 days
  python3 rebuild_exfat_folders.py /Volumes/SSD --since 7 --apply
  python3 rebuild_exfat_folders.py "/Volumes/SSD/Kardashians/Kylie Jenner" --low-space --apply

Then eject the SSD from Finder before unplugging it.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

JUNK = {".DS_Store", ".localized"}
# Foundation's atomic-write temp: "<final name>.sb-<8 hex>-<6 chars>", left behind when the write
# was interrupted before its rename.
SB_LEFTOVER = re.compile(r"^(?P<base>.+)\.sb-[0-9a-fA-F]{8}-[A-Za-z0-9]{6}$")


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
        print(f"  skipped: needs {human(total)} free for the copy, only {human(free)} available"
              " — add --move to rebuild it without copying")
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


def moving_temp(folder: Path) -> Path:
    """Where the old rename-based --move parked items (its contents are originals)."""
    return folder.parent / f".{folder.name}.moving"


def fresh_temp(folder: Path) -> Path:
    return folder.parent / f".{folder.name}.fresh"


def is_sidecar(name: str) -> bool:
    """macOS bookkeeping that is never copied (it only holds Finder/xattr data)."""
    return name.startswith("._") or name == ".DS_Store"


def file_hash(p: Path) -> str:
    h = hashlib.blake2b(digest_size=20)
    with open(p, "rb") as f:
        while chunk := f.read(8 * 1024 * 1024):
            h.update(chunk)
    return h.hexdigest()


def flush_to_disk(probe: Path) -> None:
    """Sync the whole volume, then make the drive commit its own cache (F_FULLFSYNC on a small
    regular file) — before any original is deleted. Never fsyncs a folder."""
    os.sync()
    try:
        import fcntl
        fd = os.open(probe, os.O_RDONLY)
        try:
            fcntl.fcntl(fd, getattr(fcntl, "F_FULLFSYNC", 51))
        finally:
            os.close(fd)
    except (OSError, ImportError):
        pass


def rebuild_low_space(folder: Path, apply: bool, drop_leftovers: bool) -> bool:
    """The copy rebuild, deleting each original as soon as its fresh copy checks out — see the module
    doc. Resumable: the journal names the file being copied, so a cut-off copy is redone, not trusted."""
    folder = Path(os.path.abspath(folder))
    temp = fresh_temp(folder)
    old_moving = moving_temp(folder)
    journal = temp / ".rebuild-in-progress"
    if not folder.is_dir():
        if not temp.is_dir() or old_moving.is_dir():
            print(f"  not found: {folder}")
            return False
        # Stopped between trashing the emptied original and renaming the fresh folder.
        if not apply:
            print(f"  would finish an interrupted rebuild of {folder}")
            return True
        if journal.exists():
            journal.unlink()
        os.sync()
        temp.rename(folder)
        os.sync()
        print(f"Finished the interrupted rebuild of {folder}")
        return True
    if os.path.ismount(folder):
        print(f"  skipped: {folder} is a whole drive — rebuild the folders inside it instead")
        return False

    sources = [folder] + ([old_moving] if old_moving.is_dir() else [])
    files: list[tuple[Path, Path]] = []                  # (original, path relative to the folder)
    for base in sources:
        for root, dirnames, filenames in os.walk(base):
            dirnames[:] = sorted(d for d in dirnames if not d.startswith("."))
            for n in sorted(filenames, key=str.lower):
                if not is_junk(n):
                    p = Path(root) / n
                    files.append((p, p.relative_to(base)))
    dirs = sorted({rel.parent for _, rel in files} | {Path(r).relative_to(folder) for r, d, _ in os.walk(folder)
                                                      if not any(part.startswith(".") for part in Path(r).relative_to(folder).parts)})
    present = {str(p) for p, _ in files}
    droppable: set[str] = set()
    leftovers = 0
    for p, rel in files:
        m = SB_LEFTOVER.match(p.name)
        if not m:
            continue
        leftovers += 1
        for final in (p.with_name(m["base"]), (temp / rel).with_name(m["base"])):
            try:
                if (str(final) in present or final.is_file()) and final.stat().st_size >= p.stat().st_size:
                    droppable.add(str(p))
                    break
            except OSError:
                pass
    sizes = {str(p): p.stat().st_size for p, _ in files}
    total, largest = sum(sizes.values()), max(sizes.values(), default=0)
    label = (f"{folder}  ({len(files):,} files, {human(total)}"
             + (f"; {leftovers} leftover .sb- temp files, {len(droppable)} with their finished file present"
                if leftovers else "") + ")")
    if not apply:
        print(f"  would rebuild with fresh copies (low space) {label}"
              + ("  [resumes an interrupted run]" if temp.is_dir() else ""))
        if leftovers and not drop_leftovers:
            print("    (add --drop-leftovers to delete the .sb- temps whose finished file is there)")
        return True

    batch_bytes = max(largest, 2 * 1024 ** 3)
    free = shutil.disk_usage(folder.parent).free
    if free < min(batch_bytes, total) + 200 * 1024 * 1024:
        print(f"  skipped: needs about {human(min(batch_bytes, total))} free for a batch of copies, "
              f"only {human(free)} available")
        return False
    print(f"Rebuilding with fresh copies {label}" + ("  — resuming" if temp.is_dir() else ""))
    os.makedirs(temp, exist_ok=True)
    if journal.is_file():                                # a copy that was cut off: redo it
        cut = journal.read_text("utf-8").strip()
        if cut and (temp / cut).is_file():
            (temp / cut).unlink()
    journal.write_text("", "utf-8")

    pending: list[Path] = []                             # originals whose copies are done, not yet deleted
    pending_bytes = 0
    copied = skipped = dropped = 0
    problems: list[str] = []

    def release() -> None:
        nonlocal pending_bytes
        flush_to_disk(journal)
        for orig in pending:
            for victim in (orig, orig.with_name("._" + orig.name)):
                try:
                    os.remove(victim)
                except FileNotFoundError:
                    pass
                except OSError as e:
                    problems.append(f"{victim.name}: couldn't delete the original: {e}")
        pending.clear()
        pending_bytes = 0
        os.sync()

    for i, (src, rel) in enumerate(files, 1):
        try:
            if drop_leftovers and str(src) in droppable:
                pending.append(src)
                dropped += 1
                continue
            dst = temp / rel
            os.makedirs(dst.parent, exist_ok=True)
            if os.path.lexists(dst):
                if dst.is_file() and dst.stat().st_size == sizes[str(src)] and file_hash(dst) == file_hash(src):
                    skipped += 1                         # copied by an earlier, interrupted run
                    pending.append(src)
                    continue
                stem, ext = dst.stem, dst.suffix        # same name from the old .moving folder
                n = 1
                while os.path.lexists(dst):
                    dst = dst.with_name(f"{stem} ({n}){ext}")
                    n += 1
            journal.write_text(str(dst.relative_to(temp)), "utf-8")
            shutil.copy2(src, dst)                       # a fresh file, data + dates — like the copy rebuild
            if dst.stat().st_size != sizes[str(src)] or file_hash(dst) != file_hash(src):
                os.remove(dst)
                raise IOError("the copy doesn't match the original")
            journal.write_text("", "utf-8")
            copied += 1
            pending.append(src)
            pending_bytes += sizes[str(src)]
        except OSError as e:
            problems.append(f"{rel}: {e}")
        if pending_bytes >= batch_bytes or len(pending) >= 500:
            release()
        if i % 1000 == 0:
            print(f"  {i:,}/{len(files):,}…", flush=True)
    for d in dirs:                                        # empty subfolders too
        os.makedirs(temp / d, exist_ok=True)
    release()

    if problems:
        for p in problems[:20]:
            print(f"  ! {p}")
        if len(problems) > 20:
            print(f"  … and {len(problems) - 20} more")
        print(f"  STOPPED: {len(problems)} problem(s). Everything copied so far is in the hidden “{temp.name}” "
              "next to the folder; originals of files that weren't copied are untouched. Fix the above, then "
              "run the same command again to finish.")
        return False

    st = folder.stat()
    journal.unlink()
    os.sync()
    for leftover_src in sources:                          # now only folders, junk and hidden items
        if not to_trash(leftover_src):
            parked = leftover_src.parent / f".{leftover_src.name}.original"
            n = 1
            while parked.exists():
                parked = leftover_src.parent / f".{leftover_src.name}.original {n}"
                n += 1
            leftover_src.rename(parked)
    temp.rename(folder)
    try:
        os.utime(folder, (st.st_atime, st.st_mtime))
    except OSError:
        pass
    os.sync()
    print(f"  done — {copied:,} files copied fresh"
          + (f", {skipped:,} already copied by an earlier run" if skipped else "")
          + (f", {dropped} leftover .sb- temps deleted" if dropped else ""))
    return True


def from_list(list_file: Path, root: Path) -> list[Path]:
    """Folders from Drive Health's exported list (one drive-relative path per line), under `root`.
    Shallowest first; a folder inside one already listed is dropped — rebuilding the parent rewrites
    it too."""
    rels = [line.strip().strip("/") for line in list_file.read_text("utf-8").splitlines() if line.strip()]
    rels.sort(key=lambda r: (r.count("/"), r))
    chosen: list[str] = []
    for r in rels:
        if r in chosen or any(r.startswith(c + "/") for c in chosen):
            continue
        chosen.append(r)
    out = []
    for r in chosen:
        p = root / r
        if p.is_dir() or fresh_temp(p).is_dir():
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
    ap.add_argument("--low-space", "--move", dest="low_space", action="store_true",
                    help="for folders too big to copy whole: copy every file fresh and delete each original as "
                         "soon as its copy checks out (needs room for about one 2 GB batch)")
    ap.add_argument("--drop-leftovers", action="store_true",
                    help="with --low-space: delete leftover '<name>.sb-…' atomic-save temps whose finished file is present")
    ap.add_argument("--apply", action="store_true", help="actually rebuild (default: dry run, just list)")
    args = ap.parse_args()

    targets: list[Path] = []
    if args.list:
        if not args.root or not args.root.is_dir():
            sys.exit("--list needs --root \"/Volumes/<SSD name>\"")
        targets += from_list(args.list, args.root)
    for p in args.paths:
        if not p.is_dir() and not (args.low_space and fresh_temp(Path(os.path.abspath(p))).is_dir()):
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
    if args.low_space:
        ok = sum(rebuild_low_space(t, args.apply, args.drop_leftovers) for t in targets)
    else:
        ok = sum(rebuild(t, args.apply) for t in targets)
    if args.apply:
        print(f"\n{ok}/{len(targets)} rebuilt. Eject the SSD in Finder before unplugging it, "
              "then open the folders on the iPhone/iPad.")


if __name__ == "__main__":
    main()
