"""Ready-made empty folders whose list of contents sits below 2.2 TB on the SSD — for new folders.

The iPhone's exFAT driver misreads a folder whose list of contents (its exFAT directory data) lies more
than 2^32 × 512 bytes = 2.20 TB into the drive, and nearly all of this SSD's free space is past that
point, so a folder made the usual way usually lands there and shows up empty or unreadable on the
iPhone. Neither macOS nor iOS lets a program choose where a new folder's list goes — but renaming or
moving a folder never moves its list. So `relocate_folders.py --spares N` keeps N empty folders in
"<drive>/.Spare Folders" with their lists below the line, and a new folder is made by *moving one of
those into place* under the new name. The iPhone app does the same (SpareFolders.swift). When the pool
is empty a folder is made the usual way, and the caller is told so it can say "top up the spares".
"""

from __future__ import annotations

import os
import re
import subprocess
import time

POOL = ".Spare Folders"
_IGNORABLE = (".DS_Store",)


def volume_root(path: str) -> str:
    p = os.path.abspath(path)
    while not os.path.ismount(p):
        parent = os.path.dirname(p)
        if parent == p:
            break
        p = parent
    return p


def pool_dir(path: str) -> str | None:
    """The spare-folder pool on the volume holding `path`, if it has one."""
    pool = os.path.join(volume_root(path), POOL)
    return pool if os.path.isdir(pool) else None


def _empty(folder: str) -> bool:
    try:
        return all(n in _IGNORABLE or n.startswith("._") for n in os.listdir(folder))
    except OSError:
        return False


def _names(pool: str) -> list[str]:
    try:
        return sorted(n for n in os.listdir(pool) if not n.startswith("."))
    except OSError:
        return []


def _is_spare(pool: str, name: str) -> bool:
    p = os.path.join(pool, name)
    return os.path.isdir(p) and _empty(p)


def spares(pool: str) -> list[str]:
    """The pool's ready spares (empty folders), oldest name first — checks every one (for counting)."""
    return [n for n in _names(pool) if _is_spare(pool, n)]


def count(path: str) -> int:
    pool = pool_dir(path)
    return len(spares(pool)) if pool else 0


def make_dir(path: str) -> bool:
    """Create the folder `path` (its parent must exist) from a spare when the drive has one; True if it
    did. Otherwise — no pool, pool empty, or a different volume — it's made the usual way (False)."""
    path = os.path.abspath(path)
    if os.path.lexists(path):
        raise FileExistsError(path)
    pool = pool_dir(os.path.dirname(path))
    if pool and not (path + "/").startswith(pool + "/"):
        for name in _names(pool):                             # the first usable one — no need to check them all
            if not _is_spare(pool, name):
                continue
            try:
                os.rename(os.path.join(pool, name), path)    # same volume: the list stays where it is
            except FileNotFoundError:
                continue                                      # someone else took it a moment ago
            except OSError:
                break                                         # e.g. another volume — make it normally
            now = time.time()
            try:
                os.utime(path, (now, now))                    # today's date, not the day the spare was made
            except OSError:
                pass
            return True
    os.mkdir(path)
    return False


def make_dirs(path: str) -> tuple[int, list[str]]:
    """`make_dir` for `path` and any missing parents: (how many came from spares, the ones that didn't)."""
    path = os.path.abspath(path)
    missing = []
    p = path
    while not os.path.isdir(p):
        missing.append(p)
        parent = os.path.dirname(p)
        if parent == p:
            break
        p = parent
    plain: list[str] = []
    used = 0
    for p in reversed(missing):
        if os.path.isdir(p):
            continue
        if make_dir(p):
            used += 1
        else:
            plain.append(p)
    return used, plain


def on_exfat(path: str) -> bool:
    """Whether `path` is on an exFAT (or FAT) volume — the only kind this matters for."""
    root = volume_root(path)
    try:
        out = subprocess.run(["mount"], capture_output=True, text=True).stdout
    except OSError:
        return False
    for line in out.splitlines():
        m = re.match(r".+? on (.+) \(([^,)]+)", line)
        if m and m.group(1) == root:
            return m.group(2).lower() in ("exfat", "msdos")
    return False


def make_spares(volume: str, want: int) -> int:
    """Top the pool on `volume` up to `want` empty folders (made the usual way — relocate_folders.py
    then moves their lists below the line). Returns how many were made."""
    pool = os.path.join(volume, POOL)
    os.makedirs(pool, exist_ok=True)
    have = len(spares(pool))
    stamp = time.strftime("%Y%m%d-%H%M%S")
    made = 0
    for k in range(max(0, want - have)):
        os.mkdir(os.path.join(pool, f"spare {stamp}-{k + 1:04d}"))
        made += 1
    os.sync()
    return made
