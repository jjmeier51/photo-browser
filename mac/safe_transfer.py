"""The transfer engine behind Safe Finder — copies or moves files and folders onto the exFAT SSD
without the habits that damaged it when Finder did the copying. No GUI code here (it runs on a
worker thread and reports through callbacks), so it can be tested on its own.

What it does differently from Finder:

* **Nothing half-written ever appears in a destination folder.** Each file is written to a temp
  file in one hidden staging folder at the top of the drive, flushed all the way to the disk
  (F_FULLFSYNC), verified, and only then moved into its folder under its final name. A
  destination folder only ever gains complete files with their real names — no temp names
  renamed in place, no leftovers after a crash (they stay in the staging folder and are cleared
  on the next run).
* **Every copy is checked** — re-read from the drive bypassing the Mac's cache and compared
  with a checksum of the original (on by default).
* **No macOS junk**: `._*` AppleDouble files and `.DS_Store` are never copied, and if macOS
  attaches one to a temp file it is deleted before the file is placed.
* **iOS-safe names**: characters exFAT/iOS can't store are replaced, accents are stored the way
  iOS expects, over-long names are shortened — each change is listed before you start.
* **Never overwrites**: an identical file already there is skipped (re-running is safe); a
  different file with the same name gets " (1)".
* **Move = copy, verify, then Trash**: an original goes to the Trash only after its copy (for a
  folder: every file in it) verified. On the same drive a move is a plain rename.
* **One file at a time**, folders and the staging folder flushed after each change, and the run
  stops cleanly if the drive disappears.
"""

from __future__ import annotations

import hashlib
import os
import shutil
import subprocess
import sys
import threading
import time
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

from safe_copy_to_ssd import (CHUNK, IOS_FOLDER_LIMIT, full_sync, hash_file, human, is_junk,
                              rename_note, safe_name, sync_dir)

STAGING_NAME = ".Safe Finder Staging"


def volume_root(path: Path) -> Path:
    p = Path(os.path.abspath(path))
    while not os.path.ismount(p) and p.parent != p:
        p = p.parent
    return p


def same_device(a: Path, b: Path) -> bool:
    try:
        return os.stat(a).st_dev == os.stat(b).st_dev
    except OSError:
        return False


def free_space(path: Path) -> int:
    try:
        return shutil.disk_usage(path).free
    except OSError:
        return 0


# ----------------------------------------------------------------------------- plan


@dataclass
class Top:
    """One thing the user picked (a file or a folder)."""
    src: Path
    dst: Path
    is_dir: bool
    same_drive: bool
    files: int = 0
    bytes: int = 0
    dirs: list[Path] = field(default_factory=list)         # folders to create for it, parents first


@dataclass
class Copy:
    src: Path
    dst: Path
    size: int
    top: int


@dataclass
class Plan:
    dest: Path
    tops: list[Top] = field(default_factory=list)
    copies: list[Copy] = field(default_factory=list)
    junk: int = 0
    renames: list[tuple[str, str]] = field(default_factory=list)
    big_folders: list[tuple[Path, int]] = field(default_factory=list)
    errors: list[str] = field(default_factory=list)         # blocking
    notes: list[str] = field(default_factory=list)          # informational
    free_bytes: int = 0

    @property
    def total_files(self) -> int:
        return sum(t.files for t in self.tops)

    @property
    def total_bytes(self) -> int:
        return sum(t.bytes for t in self.tops)

    def bytes_to_copy(self, move: bool) -> int:
        """What actually gets written: a move on the same drive is a rename, not a copy."""
        return sum(t.bytes for t in self.tops if not (move and t.same_drive))


def build_plan(sources: list[Path], dest: Path) -> Plan:
    """Walks the sources (can take a while for big folders — call off the UI thread)."""
    dest = Path(os.path.abspath(dest))
    plan = Plan(dest=dest, free_bytes=free_space(dest))
    if not dest.is_dir():
        plan.errors.append(f"The destination “{dest}” isn't a folder that exists.")
        return plan
    incoming_here = 0
    seen: set[str] = set()
    for src in sources:
        src = Path(os.path.abspath(src))
        if str(src) in seen or not os.path.lexists(src):
            continue
        seen.add(str(src))
        if src.is_symlink():
            plan.notes.append(f"“{src.name}” is an alias/link — skipped.")
            continue
        if src.is_dir() and (dest == src or str(dest).startswith(str(src) + os.sep)):
            plan.errors.append(f"“{src.name}” can't go inside itself.")
            continue
        if src.parent == dest:
            plan.notes.append(f"“{src.name}” is already in this folder — skipped.")
            continue
        name = safe_name(src.name)
        if name != src.name:
            plan.renames.append((src.name, name))
        top = Top(src=src, dst=dest / name, is_dir=src.is_dir(), same_drive=same_device(src, dest))
        index = len(plan.tops)
        if not top.is_dir:
            top.files, top.bytes = 1, src.stat().st_size
            plan.copies.append(Copy(src, top.dst, top.bytes, index))
            incoming_here += 1
        else:
            incoming_here += 1
            for root, dirnames, filenames in os.walk(src):
                dirnames[:] = sorted(d for d in dirnames if not is_junk(d) and not d.startswith("."))
                rel = Path(root).relative_to(src)
                parts = [safe_name(p) for p in rel.parts]
                for p, s in zip(rel.parts, parts):
                    if p != s and (p, s) not in plan.renames:
                        plan.renames.append((p, s))
                out_dir = top.dst.joinpath(*parts)
                top.dirs.append(out_dir)
                real = [f for f in sorted(filenames) if not is_junk(f) and not f.startswith(".")]
                plan.junk += len(filenames) - len(real)
                existing = len(os.listdir(out_dir)) if out_dir.is_dir() else 0
                if existing + len(real) + len(dirnames) > IOS_FOLDER_LIMIT:
                    plan.big_folders.append((out_dir, existing + len(real) + len(dirnames)))
                for f in real:
                    p = Path(root) / f
                    if p.is_symlink() or not p.is_file():
                        continue
                    fname = safe_name(f)
                    if fname != f:
                        plan.renames.append((f, fname))
                    size = p.stat().st_size
                    plan.copies.append(Copy(p, out_dir / fname, size, index))
                    top.files += 1
                    top.bytes += size
        plan.tops.append(top)
    existing = len(os.listdir(dest))
    if existing + incoming_here > IOS_FOLDER_LIMIT:
        plan.big_folders.insert(0, (dest, existing + incoming_here))
    return plan


def describe(plan: Plan, move: bool) -> list[tuple[str, str]]:
    """(kind, text) lines for the confirmation sheet / CLI: kind is ok | info | warn | error."""
    out: list[tuple[str, str]] = []
    to_copy = plan.bytes_to_copy(move)
    out.append(("ok", f"{plan.total_files:,} file{'s' if plan.total_files != 1 else ''} · {human(plan.total_bytes)}"
                      f" — {human(plan.free_bytes)} free on the destination"))
    if move and any(t.same_drive for t in plan.tops):
        out.append(("info", "Items already on this drive are moved instantly (renamed), not copied."))
    if plan.renames:
        sample = ", ".join(rename_note(a, b) for a, b in plan.renames[:3])
        more = f" and {len(plan.renames) - 3} more" if len(plan.renames) > 3 else ""
        out.append(("info", f"{len(plan.renames)} name{'s' if len(plan.renames) != 1 else ''} adjusted so iOS can "
                            f"read {'them' if len(plan.renames) != 1 else 'it'}: {sample}{more}"))
    if plan.junk:
        out.append(("info", f"{plan.junk:,} hidden macOS files (._*, .DS_Store) are left behind."))
    for path, n in plan.big_folders[:3]:
        out.append(("warn", f"“{path.name}” would hold {n:,} items. Folders that large are slow for the "
                            "iPhone to open — consider splitting it."))
    for note in plan.notes[:5]:
        out.append(("info", note))
    if to_copy > plan.free_bytes:
        out.append(("error", f"Not enough space: needs {human(to_copy)}, only {human(plan.free_bytes)} free."))
    for e in plan.errors:
        out.append(("error", e))
    return out


def blocking(plan: Plan, move: bool) -> bool:
    return bool(plan.errors) or plan.bytes_to_copy(move) > plan.free_bytes or not plan.tops


# ----------------------------------------------------------------------------- engine


class DriveGone(Exception):
    pass


def trash_with_finder(path: Path) -> bool:
    """Fallback trash (the GUI passes Qt's, which uses the system API directly)."""
    if sys.platform == "darwin":
        script = f'tell application "Finder" to delete (POSIX file "{path}" as alias)'
        r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
        return r.returncode == 0 and not os.path.lexists(path)
    return False


class Transfer:
    """Runs one plan on a worker thread. Callbacks are called from that thread:
    log(str), progress(dict), finished(dict)."""

    def __init__(self, plan: Plan, move: bool, verify: bool,
                 log: Callable[[str], None], progress: Callable[[dict], None], finished: Callable[[dict], None],
                 trash: Callable[[Path], bool] = trash_with_finder) -> None:
        self.plan, self.move, self.verify = plan, move, verify
        self.log, self.progress, self.finished, self.trash = log, progress, finished, trash
        self.stop = threading.Event()
        self.unpaused = threading.Event()
        self.unpaused.set()
        self.volume = volume_root(plan.dest)
        self.staging: Path | None = None
        self._last_tick = 0.0
        self.total_bytes = plan.bytes_to_copy(move)
        self.total_files = plan.total_files
        self.done_bytes = 0
        self.done_files = 0

    # -- control
    def start(self) -> threading.Thread:
        t = threading.Thread(target=self._run, name="SafeTransfer", daemon=True)
        t.start()
        return t

    def pause(self, paused: bool) -> None:
        (self.unpaused.clear if paused else self.unpaused.set)()

    def cancel(self) -> None:
        self.stop.set()
        self.unpaused.set()

    # -- run
    def _run(self) -> None:
        st = {"copied": 0, "skipped": 0, "failed": 0, "moved": 0, "trashed": 0, "kept": 0,
              "files": self.plan.total_files, "bytes": self.plan.bytes_to_copy(self.move),
              "stopped": False, "error": None, "seconds": 0.0}
        t0 = time.time()
        try:
            if any(not (self.move and t.same_drive) for t in self.plan.tops):
                self._prepare_staging()
            for index, top in enumerate(self.plan.tops):
                if self.stop.is_set():
                    break
                if self.move and top.same_drive:
                    self._rename_top(top, st)
                    continue
                verb = "Moving" if self.move else "Copying"
                self.log(f"{verb} “{top.src.name}” → {top.dst.parent}")
                failed_here = 0
                for d in top.dirs:                       # the whole folder structure first, each flushed
                    self._check_drive()
                    self._make_dirs(d)
                for c in (c for c in self.plan.copies if c.top == index):
                    self.unpaused.wait()
                    if self.stop.is_set():
                        break
                    self._check_drive()
                    try:
                        self._make_dirs(c.dst.parent)
                        result = self._copy_one(c)
                        st[result] += 1
                        if result == "skipped":
                            self.log(f"   already there, identical: {c.dst.name}")
                    except InterruptedError:
                        self.log(f"   stopped during {c.src.name} — its partial copy was removed")
                        break
                    except DriveGone:
                        raise
                    except Exception as e:  # noqa: BLE001 — one bad file must not stop the rest
                        st["failed"] += 1
                        failed_here += 1
                        self.log(f"   FAILED {c.src.name}: {e}")
                        if not self.volume.exists() or (self.volume != Path("/") and not os.path.ismount(self.volume)):
                            raise DriveGone() from e
                    self.done_bytes += c.size
                    self.done_files += 1
                    self._tick(c.src.name, "Copying", force=True)
                if top.is_dir and top.dst.is_dir():
                    sync_dir(top.dst)
                if self.move and not self.stop.is_set():
                    if failed_here:
                        st["kept"] += 1
                        self.log(f"   kept the original “{top.src.name}” — {failed_here} file(s) failed")
                    elif self.trash(top.src):
                        st["trashed"] += 1
                        self.log(f"   original “{top.src.name}” moved to the Trash")
                    else:
                        st["kept"] += 1
                        self.log(f"   couldn't move the original “{top.src.name}” to the Trash — it's still there")
        except DriveGone:
            st["error"] = (f"The drive “{self.volume.name}” disappeared. Reconnect it and run the same transfer "
                           "again — finished files are skipped, nothing is duplicated.")
            self.log("STOPPED: " + st["error"])
        except Exception as e:  # noqa: BLE001
            st["error"] = str(e)
            self.log(f"STOPPED: {e}")
        finally:
            if self.staging is not None:
                sync_dir(self.staging)
            try:
                os.sync()
            except OSError:
                pass
        st["stopped"] = self.stop.is_set()
        st["seconds"] = time.time() - t0
        self._tick("", "Done", force=True)
        self.finished(st)

    # -- pieces
    def _prepare_staging(self) -> None:
        """Hidden staging folder at the top of the drive (or, where that isn't writable, of the destination)."""
        for base in (self.volume, self.plan.dest):
            staging = base / STAGING_NAME
            try:
                if not staging.is_dir():
                    os.mkdir(staging)
                    sync_dir(base)
                probe = staging / f"{uuid.uuid4().hex}.probe"
                fd = os.open(probe, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
                os.close(fd)
                os.remove(probe)
            except OSError:
                continue
            for leftover in os.listdir(staging):                 # from a run that was cut off
                try:
                    os.remove(staging / leftover)
                except OSError:
                    pass
            self.staging = staging
            return
        raise OSError(f"Can't write to “{self.plan.dest}” — is the drive read-only or full?")

    def _check_drive(self) -> None:
        if self.volume == Path("/"):
            return
        if not os.path.ismount(self.volume) or not self.plan.dest.exists():
            raise DriveGone()

    def _make_dirs(self, d: Path) -> None:
        """Create `d` level by level, flushing each new folder and its parent."""
        missing = []
        p = d
        while not p.exists():
            missing.append(p)
            p = p.parent
        for level in reversed(missing):
            os.mkdir(level)
            sync_dir(level)
            sync_dir(level.parent)

    def _tick(self, name: str, phase: str, force: bool = False, extra: int = 0) -> None:
        now = time.time()
        if force or now - self._last_tick > 0.15:
            self._last_tick = now
            self.progress({"done_bytes": self.done_bytes + extra, "done_files": self.done_files,
                           "total_bytes": self.total_bytes, "total_files": self.total_files,
                           "name": name, "phase": phase})

    @staticmethod
    def _free_name(dst: Path, is_dir: bool = False) -> Path:
        stem, ext = (dst.name, "") if is_dir else (dst.stem, dst.suffix)
        i = 1
        cand = dst
        while os.path.lexists(cand):
            cand = dst.with_name(f"{stem} ({i}){ext}")
            i += 1
        return cand

    def _copy_one(self, c: Copy) -> str:
        """'copied' | 'skipped' (an identical file is already there). Raises on failure."""
        dst = c.dst
        if os.path.lexists(dst):
            src_hash = hash_file(c.src)
            stem, ext = dst.stem, dst.suffix
            i, cand = 0, dst
            while os.path.lexists(cand):
                if cand.is_file() and cand.stat().st_size == c.size and hash_file(cand) == src_hash:
                    return "skipped"
                i += 1
                cand = dst.with_name(f"{stem} ({i}){ext}")
            self.log(f"   a different “{dst.name}” is already there — saving this one as “{cand.name}”")
            dst = cand
        assert self.staging is not None
        tmp = self.staging / f"{uuid.uuid4().hex}.part"
        h = hashlib.blake2b(digest_size=20)
        st = c.src.stat()
        written = 0
        try:
            with open(c.src, "rb") as fin, open(tmp, "wb") as fout:
                while chunk := fin.read(CHUNK):
                    h.update(chunk)
                    fout.write(chunk)
                    written += len(chunk)
                    self._tick(c.src.name, "Copying", extra=written // 2 if self.verify else written)
                    if self.stop.is_set():
                        raise InterruptedError("stopped")
                    if not self.unpaused.is_set():
                        self.unpaused.wait()
                fout.flush()
                full_sync(fout.fileno())
            if tmp.stat().st_size != c.size:
                raise IOError(f"size mismatch after copying ({tmp.stat().st_size:,} vs {c.size:,} bytes)")
            if self.verify:
                self._tick(c.src.name, "Verifying", force=True, extra=written // 2)
                if hash_file(tmp, no_cache=True) != h.hexdigest():
                    raise IOError("verification failed — the drive returned different bytes")
            sidecar = tmp.with_name("._" + tmp.name)              # macOS's xattr stand-in on exFAT
            if os.path.lexists(sidecar):
                os.remove(sidecar)
            os.utime(tmp, ns=(st.st_atime_ns, st.st_mtime_ns))
            if os.path.lexists(dst):                              # appeared meanwhile — never overwrite
                dst = self._free_name(dst)
            os.rename(tmp, dst)                                   # same drive: places the finished file
            sync_dir(dst.parent)
            return "copied"
        except BaseException:
            try:
                os.remove(tmp)
            except OSError:
                pass
            raise

    def _rename_top(self, top: Top, st: dict) -> None:
        dst = top.dst
        if os.path.lexists(dst):
            dst = self._free_name(dst, top.is_dir)
            self.log(f"   “{top.dst.name}” is already there — moving as “{dst.name}”")
        try:
            os.rename(top.src, dst)
            sync_dir(dst.parent)
            sync_dir(top.src.parent)
            st["moved"] += 1
            self.done_files += top.files
            self.log(f"Moved “{top.src.name}” → {dst.parent} (same drive, renamed)")
        except OSError as e:
            st["failed"] += 1
            self.log(f"   FAILED to move “{top.src.name}”: {e}")
