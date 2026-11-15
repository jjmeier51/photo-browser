"""Receive from iPhone — photos and videos AirDropped to this Mac, moved into the drive's "From iPhone" folder
(airdrop_window.py is the window; photo_browser.py watches for arrivals).

macOS puts whatever is AirDropped to a Mac in **~/Downloads** — there is no setting for it, and no hook an app
is called through. What an AirDropped file does carry is its quarantine note: `com.apple.quarantine` names the
program that received it, and for AirDrop that is **sharingd**. So:

- `find()` lists the photos and videos in Downloads that sharingd received (newest first) — or, asked to, every
  photo and video there (for a Mac where the note isn't kept). A Live Photo's two halves (HEIC + MOV of the
  same name) both count. Files still arriving (a size that's changing, a browser's `.download`) are left.
- `find_destination()` finds the drive's existing **"From iPhone"** folder — the one remembered, else a folder
  of that name at the top of the drive, else one or two levels down — without ever making one (the window
  offers that).
- `receive()` copies each file onto the drive the careful way (`net_fetch.put`: whole or not there, CLAUDE.md
  #12), **reads the copy back and compares its SHA-256** with the original, gives it the original's dates, and
  only then moves the original to the Mac's Trash (or leaves it, as chosen). A file that's already there —
  same name, same content — is skipped; a different file under the same name is kept as "name 2". Nothing on
  the drive is ever replaced.

Reading ~/Downloads is something macOS asks about the first time ("… would like to access files in your
Downloads folder"). No Qt here.
"""
from __future__ import annotations

import hashlib
import os
import plistlib
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

AGENT = "sharingd"                           # the program AirDrop arrives through
FOLDER_NAME = "From iPhone"
PHOTO_EXT = {".jpg", ".jpeg", ".heic", ".heif", ".png", ".gif", ".webp", ".tif", ".tiff", ".bmp", ".dng", ".raw",
             ".cr2", ".cr3", ".nef", ".arw", ".raf", ".avif", ".jxl"}
VIDEO_EXT = {".mov", ".mp4", ".m4v", ".avi", ".mkv", ".webm", ".3gp", ".mts", ".m2ts"}
PARTIAL = (".download", ".part", ".crdownload", ".partial", ".tmp")
SETTLE = 2.0                                 # seconds a file's size must hold still to count as arrived


def downloads() -> Path:
    env = os.environ.get("PHOTO_BROWSER_DOWNLOADS")
    return Path(env) if env else Path.home() / "Downloads"


def _xattr(path: str, name: str) -> bytes | None:
    try:
        import shared_tags
        return shared_tags.xattr_get(path, name)
    except Exception:  # noqa: BLE001 — no extended attributes here
        return None


def agent_of(path: str) -> str:
    """The program that received the file, from its quarantine note ("" when it has none)."""
    raw = _xattr(path, "com.apple.quarantine")
    if not raw:
        return ""
    parts = raw.decode("utf-8", "replace").split(";")            # flags;time;agent;uuid
    return parts[2].strip() if len(parts) >= 3 else ""


def sender_of(path: str) -> str:
    """Who sent it, when macOS noted that ("Jamie's iPhone")."""
    raw = _xattr(path, "com.apple.metadata:kMDItemWhereFroms")
    if not raw:
        return ""
    try:
        got = plistlib.loads(raw)
    except Exception:  # noqa: BLE001
        return ""
    for v in got if isinstance(got, list) else [got]:
        if isinstance(v, str) and v.strip() and "://" not in v:
            return v.strip()
    return ""


def kind_of(name: str) -> str:
    ext = os.path.splitext(name)[1].lower()
    return "photo" if ext in PHOTO_EXT else "video" if ext in VIDEO_EXT else ""


@dataclass
class Arrival:
    path: str
    name: str
    kind: str                                 # "photo" | "video"
    size: int
    when: float                               # when it arrived (the file's change time)
    airdrop: bool
    sender: str = ""


def find(folder: str | os.PathLike | None = None, only_airdrop: bool = True, since: float = 0.0,
         now: float | None = None) -> list[Arrival]:
    """The photos and videos in Downloads (not in its subfolders) that have arrived — newest first."""
    folder = str(folder or downloads())
    now = time.time() if now is None else now
    out: list[Arrival] = []
    try:
        entries = list(os.scandir(folder))
    except OSError:
        return out
    for e in entries:
        name = e.name
        if name.startswith(".") or name.lower().endswith(PARTIAL):
            continue
        kind = kind_of(name)
        if not kind:
            continue
        try:
            if not e.is_file(follow_symlinks=False):
                continue
            st = e.stat(follow_symlinks=False)
        except OSError:
            continue
        arrived = st.st_ctime                                   # the change time: when it landed here
        if st.st_size == 0 or arrived < since or now - max(st.st_mtime, st.st_ctime) < SETTLE:
            continue
        air = agent_of(e.path).lower() == AGENT
        if only_airdrop and not air:
            continue
        out.append(Arrival(e.path, name, kind, st.st_size, arrived, air, sender_of(e.path) if air else ""))
    out.sort(key=lambda a: (-a.when, a.name.casefold()))
    return out


def settled(path: str, wait: float = 0.6) -> bool:
    """True when the file's size holds still — it isn't still being written."""
    try:
        a = os.path.getsize(path)
        time.sleep(wait)
        return a == os.path.getsize(path) and a > 0
    except OSError:
        return False


def _fold(name: str) -> str:
    return "".join(ch for ch in name.casefold() if ch.isalnum())


def find_destination(drive: str, remembered: str = "", depth: int = 2, limit: int = 4000, near: str = "") -> str | None:
    """The existing "From iPhone" folder: the remembered one when it's still there; else a folder of that name
    (however it's capitalised or spaced) beside or above where the window is (`near`); else the first one at
    the top of the drive, then up to `depth` levels down. None when there isn't one."""
    if remembered and os.path.isdir(remembered):
        return remembered
    want = _fold(FOLDER_NAME)
    here = os.path.abspath(near) if near and os.path.isdir(near) else ""
    for _ in range(12):                                   # this folder, then each one above it
        if not here:
            break
        if _fold(os.path.basename(here)) == want:
            return here
        try:
            hit = next((n for n in sorted(os.listdir(here), key=str.casefold)
                        if _fold(n) == want and os.path.isdir(os.path.join(here, n))), None)
        except OSError:
            hit = None
        if hit:
            return os.path.join(here, hit)
        parent = os.path.dirname(here)
        if parent == here or os.path.ismount(here):
            break
        here = parent
    if not drive or not os.path.isdir(drive):
        return None
    want = _fold(FOLDER_NAME)
    level = [drive]
    seen = 0
    for _ in range(depth + 1):
        nxt: list[str] = []
        for folder in level:
            try:
                names = sorted(os.listdir(folder), key=str.casefold)
            except OSError:
                continue
            for name in names:
                if name.startswith("."):
                    continue
                full = os.path.join(folder, name)
                seen += 1
                if seen > limit:
                    return None
                if os.path.isdir(full):
                    if _fold(name) == want:
                        return full
                    nxt.append(full)
        level = nxt
    return None


def sha256(path: str, stop: Callable[[], bool] | None = None) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while chunk := f.read(1 << 20):
            if stop and stop():
                raise InterruptedError("stopped")
            h.update(chunk)
    return h.hexdigest()


@dataclass
class Move:
    src: str
    dst: str = ""
    status: str = ""                          # "" to do | "moved" | "already" | "failed" | "stopped"
    why: str = ""
    kind: str = ""
    original: str = ""                        # where the original is now: "trash" | "kept" | "left" (couldn't be trashed)


def target_for(src: str, dest: str, taken: set[str]) -> tuple[str, bool]:
    """Where `src` goes in `dest`: its own name, or "name 2.ext" when another file has it. (path, True) when
    the very same file — same size, same SHA-256 — is already there under that name."""
    import net_fetch
    name = net_fetch.safe_name(os.path.basename(src))
    stem, ext = os.path.splitext(name)
    n = 1
    while True:
        cand = os.path.join(dest, name if n == 1 else f"{stem} {n}{ext}")
        key = os.path.normcase(cand).casefold()
        if key not in taken and not os.path.lexists(cand):
            return cand, False
        if key not in taken and os.path.isfile(cand):
            try:
                if os.path.getsize(cand) == os.path.getsize(src) and sha256(cand) == sha256(src):
                    return cand, True
            except OSError:
                pass
        n += 1


@dataclass
class Result:
    moves: list[Move] = field(default_factory=list)

    def of(self, status: str) -> list[Move]:
        return [m for m in self.moves if m.status == status]


def receive(paths: list[str], dest: str, *, after: str = "trash", trash: Callable[[str], bool] | None = None,
            progress: Callable[[int, int, str], None] | None = None, stop: Callable[[], bool] | None = None) -> Result:
    """Moves the files into `dest` (module notes). `after`: "trash" — the original to the Trash once its copy
    has been read back and matches — or "keep". `trash(path)` does the trashing (the app's own)."""
    import net_fetch
    import spare_folders
    res = Result()
    exfat = spare_folders.on_exfat(dest)
    taken: set[str] = set()
    for i, src in enumerate(paths):
        m = Move(src, kind=kind_of(src))
        res.moves.append(m)
        if stop and stop():
            m.status = "stopped"
            continue
        if progress:
            progress(i, len(paths), os.path.basename(src))
        wrote = False
        try:
            if not settled(src, 0.3):
                m.status, m.why = "failed", "it's still arriving — try again in a moment"
                continue
            st = os.stat(src)
            m.dst, same = target_for(src, dest, taken)
            taken.add(os.path.normcase(m.dst).casefold())
            if same:
                m.status = "already"
            else:
                want = sha256(src, stop)
                net_fetch.put(src, m.dst, exfat)
                wrote = True
                if sha256(m.dst, stop) != want:
                    _remove(m.dst)
                    m.status, m.why, m.dst = "failed", "the copy on the drive didn't match the original", ""
                    continue
                try:
                    import clone_drive
                    clone_drive.put_dates(m.dst, st)
                except Exception:  # noqa: BLE001 — the dates in the photo's own metadata are what the apps read
                    try:
                        os.utime(m.dst, ns=(st.st_atime_ns, st.st_mtime_ns))
                    except OSError:
                        pass
                m.status = "moved"
            if after == "trash":
                try:
                    ok = bool(trash(src)) if trash else False
                except Exception:  # noqa: BLE001
                    ok = False
                m.original = "trash" if ok else "left"
            else:
                m.original = "kept"
        except InterruptedError:
            m.status = "stopped"
            if wrote:                                  # a copy that was never checked doesn't stay
                _remove(m.dst)
        except OSError as e:
            m.status, m.why = "failed", str(e)
    if progress:
        progress(len(paths), len(paths), "")
    return res


def _remove(path: str) -> None:
    try:
        os.unlink(path)
    except OSError:
        pass


def summary(res: Result, dest: str) -> str:
    """One line for the toast."""
    moved, already, failed = res.of("moved"), res.of("already"), res.of("failed")
    photos = sum(1 for m in moved if m.kind == "photo")
    videos = len(moved) - photos
    bits = []
    if photos:
        bits.append(f"{photos:,} photo{'s' if photos != 1 else ''}")
    if videos:
        bits.append(f"{videos:,} video{'s' if videos != 1 else ''}")
    line = (f"Moved {' and '.join(bits)} to “{os.path.basename(dest.rstrip(os.sep))}”" if bits else
            "Nothing new to move")
    if already:
        line += f"; {len(already):,} already there"
    if failed:
        line += f"; {len(failed):,} couldn't be moved ({failed[0].why})"
    left = [m for m in res.moves if m.original == "left"]
    if left:
        line += f"; {len(left):,} original{'s' if len(left) != 1 else ''} couldn't go to the Trash and are still in Downloads"
    return line + "."
