#!/usr/bin/env python3
"""Move the whole library to a new SSD without losing anything — Photo Browser for Mac's "Clone Drive to a New SSD…"
(no Qt here; clone_window.py is the window).

    python3 mac/clone_drive.py "/Volumes/Old SSD" "/Volumes/New SSD"             # dry run: what would be copied
    python3 mac/clone_drive.py "/Volumes/Old SSD" "/Volumes/New SSD" --apply     # copy, checking every file
    python3 mac/clone_drive.py "/Volumes/Old SSD" "/Volumes/New SSD" --verify    # compare the two drives again
    python3 mac/clone_drive.py "/Volumes/Old SSD" "/Volumes/New SSD" --verify --deep   # …reading every byte of both
    python3 mac/clone_drive.py "/Volumes/Old SSD" "/Volumes/New SSD" --verify --deep --repair   # …and copying
                                                                       # again any file whose contents differ

The old drive is only ever read. Nothing on it is changed, moved or deleted.

**What is copied** — everything, at the same place and under exactly the same name:
- every file and folder, empty folders included;
- the hidden things the apps keep on the drive: `.Photo Browser Metadata` (the iPhone app's metadata backup —
  Favorites, captions, covers, birthdays, profile records, places — and `shared-tags.json`, `renames.json`),
  each download folder's record (`.instagram.json`, `.facebook.json`, `.tiktok.json`, `.simpcity.json`,
  `.fanfix.json`, `.taylorpictures.json`…), the app's Recently Deleted (`.Trash`), and any other dot-file;
- each item's **dates** — modified, and created (the app falls back on them for a photo's date, and sorts by
  them) — for folders too;
- each item's **extended attributes** — the tags a file carries (`com.photobrowser.tags`), Finder's tags and
  comments, "where from" (the app's "Saved from"), resource forks. On an exFAT source macOS keeps these in
  `._name` companion files and hands them over as attributes; here they're read as attributes and written as
  real ones;
- permissions and the hidden / locked flags (from a drive that has them — exFAT doesn't).

**What isn't**: macOS's own bookkeeping, which means nothing on another drive (`.Spotlight-V100`,
`.fseventsd`, `.Trashes`, `.TemporaryItems`, `.DocumentRevisions-V100`, `.DS_Store`, the `._name` companions
themselves), Windows' (`$RECYCLE.BIN`, `System Volume Information`), and the exFAT workarounds an APFS drive
doesn't need (`.Spare Folders`, `.Photo Browser Staging`). The run counts them.

**How each file is copied**: read once (its checksum taken as it's read), written under a temporary name,
flushed to the drive, **read back from the drive itself** (not the Mac's memory) and its checksum compared;
then its attributes, permissions and dates are put on and only then is it renamed to its real name — so a
file under its real name on the new drive is always whole and checked. A run that's stopped, or cut off by
a cable, is simply run again: what's there and the same is skipped, the temporary file is cleared.
**Nothing of yours on the new drive is overwritten**: a different file already at a path is reported and
left — except an earlier copy this made that the old drive's file has since outdated (the app's metadata backup
after "Back Up Metadata Now", a download record): that one is brought up to date, the newer replacing the older.
"A copy this made" is not a guess from the dates: the drive's checksum record has to say the clone wrote that
file (or a byte-for-byte comparison found it equal to the old drive's) and it has to be unchanged since — the
recorded size and date, and its contents read again against the recorded checksum. Anything else that differs
is a conflict: reported, left alone.

**The checksums of what was written** are kept on the new drive as the run goes (every few hundred files or
half a minute — a quit, a crash or a pulled cable loses at most that), and a run carried on reads again and
records the files it finds copied but not yet recorded (see "the drive's checksums" below).

**Then the two drives are compared** (`compare`): every item present, the same kind and size, its dates and
attributes equal. `--deep` also reads every byte of both again. The report (also saved in
`~/Library/Logs/Photo Browser for Mac/`) lists anything that differs; "0 problems" means the new drive has everything.

**The iPhone app afterwards** (the report says this too). What the app keeps *on the phone* is keyed by each
item's path, so it has to follow the library to the new drive:
- before cloning, open the old drive in the app and tap Drive Health ▸ Back Up Metadata Now — the drive then
  carries, by drive-relative path, everything the phone knows (`.Photo Browser Metadata`), and the clone copies it;
- give the new drive the old drive's name (`swap_names` — the window's button): when the app is pointed at a
  drive whose path matches the one it knew but for the mount id, it re-keys everything itself
  (`rekeyRootIfRemounted`);
- whatever the path turns out to be, Drive Health ▸ Restore from the Drive's Backup merges the copied backup
  under the new drive — it only adds what's missing — and tags, Favorites and To AI come from `shared-tags.json`
  on the drive by themselves.

The destination should be APFS (or Mac OS Extended). exFAT can't hold attributes or creation dates the same
way and has the folder problems in CLAUDE.md #12 — the run says so and asks for `--allow-exfat`.
"""
from __future__ import annotations

import ctypes
import ctypes.util
import hashlib
import os
import re
import shutil
import stat as statmod
import subprocess
import sys
import threading
import time
import unicodedata
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Iterable

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import shared_tags  # noqa: E402 — its xattr calls (libc on macOS)
from safe_copy_to_ssd import CHUNK, hash_file, human  # noqa: E402
import app_identity

SKIP_AT_ROOT = {".Spotlight-V100", ".fseventsd", ".Trashes", ".TemporaryItems", ".DocumentRevisions-V100",
                ".apdisk", ".com.apple.timemachine.donotpresent", "$RECYCLE.BIN", "System Volume Information",
                ".Spare Folders", *app_identity.HIDDEN_ON_DRIVE, ".PKInstallSandboxManager",
                ".PKInstallSandboxManager-SystemSoftware", ".HFS+ Private Directory Data\r", ".journal",
                ".journal_info_block", "lost+found"}
SKIP_ANYWHERE = {".DS_Store", ".localized"}
TEMP_SUFFIX = ".cloning"
# Attributes macOS puts on (or guards) itself: they can't be written by a program, and mean nothing copied.
UNCOPYABLE_XATTRS = ("com.apple.provenance", "com.apple.macl", "com.apple.rootless", "com.apple.lastuseddate#PS",
                     "com.apple.quarantine")
TIME_SLACK_NS = 2_000                # dates are compared to within 2 µs (APFS keeps nanoseconds; Python floats don't)
LOGS = app_identity.logs()
IS_MAC = sys.platform == "darwin"


def skipped_name(name: str, at_root: bool) -> bool:
    return (name in SKIP_ANYWHERE or name.startswith("._") or name.endswith(TEMP_SUFFIX) and name.startswith(".")
            or (at_root and name in SKIP_AT_ROOT))


# ----------------------------------------------------------------------------- the filesystem's own things

def fs_type(path: str) -> str:
    """"apfs", "exfat", "hfs", "msdos"… for the volume `path` is on ("" when it can't be told)."""
    p = os.path.abspath(path)
    while not os.path.ismount(p) and os.path.dirname(p) != p:
        p = os.path.dirname(p)
    try:
        out = subprocess.run(["mount"], capture_output=True, text=True).stdout
    except OSError:
        return ""
    for line in out.splitlines():
        m = re.match(r".+? on (.+) \(([^,)]+)", line) or re.match(r".+? on (.+) type (\S+)", line)
        if m and m.group(1) == p:
            return m.group(2).lower()
    return ""


def birth_ns(st: os.stat_result) -> int | None:
    """When the item was created, in nanoseconds — None where the system doesn't say (Linux)."""
    ns = getattr(st, "st_birthtime_ns", None)
    if ns is not None:
        return int(ns)
    b = getattr(st, "st_birthtime", None)
    return int(b * 1e9) if b is not None else None


if IS_MAC:
    class _AttrList(ctypes.Structure):
        _fields_ = [("bitmapcount", ctypes.c_ushort), ("reserved", ctypes.c_uint16), ("commonattr", ctypes.c_uint32),
                    ("volattr", ctypes.c_uint32), ("dirattr", ctypes.c_uint32), ("fileattr", ctypes.c_uint32),
                    ("forkattr", ctypes.c_uint32)]

    class _Timespec(ctypes.Structure):
        _fields_ = [("tv_sec", ctypes.c_long), ("tv_nsec", ctypes.c_long)]

    _libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
    _libc.setattrlist.argtypes = [ctypes.c_char_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_ulong]
    _libc.setattrlist.restype = ctypes.c_int
    _ATTR_BIT_MAP_COUNT, _ATTR_CMN_CRTIME, _FSOPT_NOFOLLOW = 5, 0x00000200, 0x00000001

    def set_birth(path: str, ns: int) -> bool:
        """Sets the item's creation date (setattrlist — the only call that can)."""
        al = _AttrList(_ATTR_BIT_MAP_COUNT, 0, _ATTR_CMN_CRTIME, 0, 0, 0, 0)
        ts = _Timespec(ns // 1_000_000_000, ns % 1_000_000_000)
        return _libc.setattrlist(os.fsencode(path), ctypes.byref(al), ctypes.byref(ts), ctypes.sizeof(ts),
                                 _FSOPT_NOFOLLOW) == 0

    _libc.copyfile.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_uint32]
    _libc.copyfile.restype = ctypes.c_int
    _COPYFILE_ACL, _COPYFILE_NOFOLLOW = 1 << 0, (1 << 18) | (1 << 19)

    def copy_acl(src: str, dst: str) -> bool:
        """`src`'s access-control list onto `dst` (copyfile(3) with COPYFILE_ACL alone: nothing else of the
        file is touched). An item without one — nearly every file on a photo drive — just has none copied."""
        return _libc.copyfile(os.fsencode(src), os.fsencode(dst), None, _COPYFILE_ACL | _COPYFILE_NOFOLLOW) == 0

    _ATTR_CMN_MODTIME, _ATTR_CMN_ACCTIME = 0x00000400, 0x00001000

    def set_dates(path: str, birth: int, modified: int, accessed: int) -> bool:
        """Creation, modification and access dates in one call. Together matters: macOS pulls an item's creation
        date back to its modification date whenever the modification date *alone* is set to something earlier
        (how `touch` changes creation dates) — so a file created after it was last modified, which is every file
        that was ever downloaded or copied with its date kept, lost its creation date to a later `utime`."""
        al = _AttrList(_ATTR_BIT_MAP_COUNT, 0, _ATTR_CMN_CRTIME | _ATTR_CMN_MODTIME | _ATTR_CMN_ACCTIME, 0, 0, 0, 0)
        ts = (_Timespec * 3)(*(_Timespec(v // 1_000_000_000, v % 1_000_000_000) for v in (birth, modified, accessed)))
        return _libc.setattrlist(os.fsencode(path), ctypes.byref(al), ctypes.byref(ts), ctypes.sizeof(ts),
                                 _FSOPT_NOFOLLOW) == 0
else:
    def copy_acl(src: str, dst: str) -> bool:
        return True

    def set_birth(path: str, ns: int) -> bool:
        return False

    def set_dates(path: str, birth: int, modified: int, accessed: int) -> bool:
        return False


def xattrs_of(path: str) -> dict[str, bytes]:
    out: dict[str, bytes] = {}
    for name in shared_tags.xattr_names(path):
        if name.startswith(UNCOPYABLE_XATTRS):
            continue
        value = shared_tags.xattr_get(path, name)
        if value is not None:
            out[name] = value
    return out


def copy_meta(src: str, dst: str, st: os.stat_result, perms: bool, flags: bool = True) -> list[str]:
    """`src`'s attributes, permissions, dates and (with `flags`) flags onto `dst`. Returns what couldn't be set
    — each a short phrase ("the attribute com.apple.metadata:_kMDItemUserTags")."""
    missed: list[str] = []
    link = statmod.S_ISLNK(st.st_mode)
    if not link:
        for name, value in xattrs_of(src).items():
            try:
                shared_tags.xattr_set(dst, name, value)
            except OSError:
                missed.append(f"the attribute {name}")
        if perms:
            try:
                os.chmod(dst, statmod.S_IMODE(st.st_mode))
            except OSError:
                missed.append("its permissions")
            try:
                copy_acl(src, dst)                      # best effort: a drive that keeps no access lists has none
            except (OSError, AttributeError, ctypes.ArgumentError):
                pass
    missed += put_dates(dst, st, link)
    if flags:
        put_flags(dst, st, missed)
    return missed


def put_dates(dst: str, st: os.stat_result, link: bool = False) -> list[str]:
    """`st`'s modification, access and creation dates onto `dst`, then read back: what the drive now says is
    what counts, not what the calls returned. The creation date goes on last (or in the same call as the
    others — `set_dates`): nothing may set the modification date by itself after it."""
    missed: list[str] = []
    b = birth_ns(st) if IS_MAC else None
    try:
        os.utime(dst, ns=(st.st_atime_ns, st.st_mtime_ns), follow_symlinks=False)
    except (OSError, NotImplementedError):
        pass                                             # the reading back below says whether it matters
    if b is not None and not set_dates(dst, b, st.st_mtime_ns, st.st_atime_ns):
        set_birth(dst, b)
    try:
        now = os.lstat(dst)
    except OSError:
        return [] if link else ["its dates"]
    if abs(now.st_mtime_ns - st.st_mtime_ns) > TIME_SLACK_NS and not link:
        missed.append("its modification date")
    if b is not None:
        nb = birth_ns(now)
        if nb is not None and abs(nb - b) > TIME_SLACK_NS:
            if not set_birth(dst, b) or abs((birth_ns(os.lstat(dst)) or b) - b) > TIME_SLACK_NS:
                missed.append("its creation date")
    return missed


def put_flags(dst: str, st: os.stat_result, missed: list[str] | None = None) -> None:
    """The hidden / locked flags (the user's ones — the system's aren't a program's to set)."""
    f = getattr(st, "st_flags", 0) & 0x0000FFFF
    if f and hasattr(os, "chflags"):
        try:
            os.chflags(dst, f, follow_symlinks=False)
        except (OSError, NotImplementedError):
            if missed is not None:
                missed.append("its hidden/locked flags")


# ----------------------------------------------------------------------------- what's on the old drive

@dataclass
class Item:
    rel: str
    kind: str                         # "file" / "dir" / "link"
    size: int = 0


@dataclass
class Scan:
    items: list[Item] = field(default_factory=list)          # folders before what's in them
    files: int = 0
    folders: int = 0
    links: int = 0
    bytes: int = 0
    left_out: int = 0                                         # macOS/Windows bookkeeping, `._` companions
    left_out_bytes: int = 0
    unreadable: list[tuple[str, str]] = field(default_factory=list)
    special: list[str] = field(default_factory=list)          # sockets, devices: nothing to copy


def scan(src: str, progress: Callable[[int], None] = lambda n: None, stop: Callable[[], bool] = lambda: False) -> Scan:
    out = Scan()
    src = os.path.abspath(src)
    stack = [""]
    while stack and not stop():
        rel_dir = stack.pop()
        full = os.path.join(src, rel_dir) if rel_dir else src
        try:
            with os.scandir(full) as it:
                entries = sorted(it, key=lambda e: e.name)
        except OSError as e:
            out.unreadable.append((rel_dir or ".", e.strerror or str(e)))
            continue
        subdirs = []
        for e in entries:
            rel = os.path.join(rel_dir, e.name) if rel_dir else e.name
            if skipped_name(e.name, not rel_dir):
                out.left_out += 1
                try:
                    if e.is_file(follow_symlinks=False):
                        out.left_out_bytes += e.stat(follow_symlinks=False).st_size
                except OSError:
                    pass
                continue
            try:
                st = e.stat(follow_symlinks=False)
            except OSError as err:
                out.unreadable.append((rel, err.strerror or str(err)))
                continue
            if statmod.S_ISLNK(st.st_mode):
                out.items.append(Item(rel, "link"))
                out.links += 1
            elif statmod.S_ISDIR(st.st_mode):
                out.items.append(Item(rel, "dir"))
                out.folders += 1
                subdirs.append(rel)
            elif statmod.S_ISREG(st.st_mode):
                out.items.append(Item(rel, "file", st.st_size))
                out.files += 1
                out.bytes += st.st_size
            else:
                out.special.append(rel)
        stack.extend(reversed(subdirs))
        progress(out.files + out.folders)
    return out


# ----------------------------------------------------------------------------- the copy

@dataclass
class Problem:
    rel: str
    what: str


@dataclass
class Result:
    copied: int = 0
    copied_bytes: int = 0
    already: int = 0                    # there and the same: left
    updated: int = 0                    # of `copied`: replaced an earlier copy the old drive's file has outdated
    recorded: int = 0                   # of `already`: read again (both drives) and their checksum recorded
    unrecorded: int = 0                 # of `already`: still without a checksum (more than a run reads by itself)
    conflicts: int = 0                  # of `problems`: a different file there that isn't this clone's to replace
    folders: int = 0
    links: int = 0
    problems: list[Problem] = field(default_factory=list)
    stopped: bool = False
    seconds: float = 0


class Stopped(Exception):
    pass


def preflight(src: str, dst: str, plan: Scan | None = None, allow_exfat: bool = False,
              need: int | None = None) -> list[str]:
    """What stands in the way, as sentences ([] = go). `need` is `bytes_missing(src, dst, plan)` when the
    caller has already worked it out (it's a stat for every file on the drive — not something to do twice)."""
    src, dst = os.path.abspath(src), os.path.abspath(dst)
    out: list[str] = []
    if not os.path.isdir(src):
        return [f"“{src}” isn't a folder that can be read."]
    if not os.path.isdir(dst):
        return [f"“{dst}” isn't there — plug the new drive in."]
    rs, rd = os.path.realpath(src), os.path.realpath(dst)
    if rs == rd or rd.startswith(rs + os.sep) or rs.startswith(rd + os.sep):
        return ["The new drive can't be the old one, or a folder inside it."]
    if not os.access(dst, os.W_OK):
        out.append(f"“{os.path.basename(dst) or dst}” can't be written to.")
    kind = fs_type(dst)
    if kind in ("exfat", "msdos") and not allow_exfat:
        out.append(f"“{os.path.basename(dst) or dst}” is {'exFAT' if kind == 'exfat' else 'FAT'}, which can't keep "
                   "creation dates or attributes properly. Erase it as APFS in Disk Utility first.")
    if plan is not None:
        try:
            free = shutil.disk_usage(dst).free
        except OSError:
            free = 0
        if need is None:
            need = bytes_missing(src, dst, plan)
        if need > free:
            out.append(f"Not enough room: {human(need)} to copy, {human(free)} free on the new drive.")
    return out


def bytes_missing(src: str, dst: str, plan: Scan) -> int:
    """How much still has to be written (a run carried on needs less)."""
    need = 0
    for it in plan.items:
        if it.kind != "file":
            continue
        try:
            if os.lstat(os.path.join(dst, it.rel)).st_size == it.size:
                continue
        except OSError:
            pass
        need += it.size
    return need


class Clone:
    """One run. `progress(files done, files, bytes done, bytes, name, phase)` and `log(line)` are called from
    the thread `run` is on; `pause` / `cancel` from any."""

    def __init__(self, src: str, dst: str, plan: Scan,
                 progress: Callable[[int, int, int, int, str, str], None] = lambda *a: None,
                 log: Callable[[str], None] = lambda s: None, verify: bool = True) -> None:
        self.src, self.dst, self.plan = os.path.abspath(src), os.path.abspath(dst), plan
        self.progress, self.log, self.verify = progress, log, verify
        self.cancelled = False
        self.paused = False
        self.result = Result()
        self.done_files = 0
        self.done_bytes = 0
        self._last_tick = 0.0
        self.perms = fs_type(self.src) not in ("exfat", "msdos", "ntfs")       # those have no permissions to carry
        self.sums: Sums = load_sums(self.dst)           # the checksum of every file written (see check_drive)
        self.record_left = RECORD_ALREADY               # bytes of already-copied files this run may read again

    def cancel(self) -> None:
        self.cancelled = True

    def pause(self, on: bool) -> None:
        self.paused = on

    def _breathe(self) -> None:
        while self.paused and not self.cancelled:
            time.sleep(0.2)
        if self.cancelled:
            raise Stopped()
        if not os.path.isdir(self.dst):
            raise Stopped("the new drive is gone")
        if not os.path.isdir(self.src):
            raise Stopped("the old drive is gone")

    def _tick(self, name: str, phase: str, force: bool = False) -> None:
        now = time.monotonic()
        if force or now - self._last_tick > 0.15:
            self._last_tick = now
            self.progress(self.done_files, self.plan.files, self.done_bytes, self.plan.bytes, name, phase)

    def _problem(self, rel: str, what: str) -> None:
        self.result.problems.append(Problem(rel, what))
        self.log(f"   ! {rel}: {what}")

    def run(self) -> Result:
        started = time.monotonic()
        try:
            self._run()
        finally:
            # Whatever ended the run — the end, Stop, a drive pulled, an error nobody foresaw — the checksums of
            # what was written are on the drive (they went there as the run went; this is the last of them).
            self._keep_sums()
            self.result.seconds = time.monotonic() - started
        self._tick("", "done", force=True)
        return self.result

    def _keep_sums(self) -> None:
        if os.path.isdir(self.dst) and self.sums.flush() and self.sums.appended:
            compact_sums(self.dst)

    def _run(self) -> None:
        r = self.result
        dirs: list[tuple[str, os.stat_result]] = []
        try:
            for it in self.plan.items:
                self._breathe()
                s, d = os.path.join(self.src, it.rel), os.path.join(self.dst, it.rel)
                try:
                    st = os.lstat(s)
                except OSError as e:
                    self._problem(it.rel, f"couldn't be read on the old drive ({e.strerror or e})")
                    continue
                if it.kind == "dir":
                    if not self._folder(it.rel, d):
                        continue
                    dirs.append((it.rel, st))
                    r.folders += 1
                elif it.kind == "link":
                    self._link(it.rel, s, d, st)
                else:
                    self._file(it.rel, s, d, st)
            # Folders last, deepest first: putting things in a folder changes its date.
            for rel, st in reversed(dirs):
                self._breathe()
                missed = copy_meta(os.path.join(self.src, rel), os.path.join(self.dst, rel), st, self.perms)
                if missed:
                    self._problem(rel, "copied, but couldn't keep " + ", ".join(missed))
            self._flush()
        except Stopped as e:
            r.stopped = True
            if str(e):
                self._problem(".", str(e))
            elif os.path.isdir(self.dst) and os.path.isdir(self.src):
                # Stopped by hand, both drives still here: the folders reached so far get their dates now
                # (the next run sets them again once their last files are in), so what's on the new drive
                # is dated like the old one even if the clone is never carried on.
                for rel, st in reversed(dirs):
                    try:
                        copy_meta(os.path.join(self.src, rel), os.path.join(self.dst, rel), st, self.perms)
                    except OSError:
                        pass

    def _flush(self) -> None:
        try:
            os.sync()
        except OSError:
            pass

    def _folder(self, rel: str, d: str) -> bool:
        if os.path.isdir(d) and not os.path.islink(d):
            return True
        if os.path.lexists(d):
            self._problem(rel, "a file with this folder's name is already on the new drive — nothing inside was copied")
            return False
        try:
            os.mkdir(d)
            return True
        except OSError as e:
            self._problem(rel, f"the folder couldn't be made ({e.strerror or e})")
            return False

    def _link(self, rel: str, s: str, d: str, st: os.stat_result) -> None:
        try:
            target = os.readlink(s)
            if os.path.islink(d):
                if os.readlink(d) != target:
                    self._problem(rel, "a different link is already there (left as it is)")
                    return
            elif os.path.lexists(d):
                self._problem(rel, "something else with this name is already there (left as it is)")
                return
            else:
                os.symlink(target, d)
            copy_meta(s, d, st, False)
            self.result.links += 1
        except OSError as e:
            self._problem(rel, f"the link couldn't be made ({e.strerror or e})")

    def _same_already(self, rel: str, s: str, d: str, st: os.stat_result) -> bool | None:
        """True: the file's there and the same (left). False: copy it — it's missing, or it's this clone's own
        earlier copy and the old drive's file has changed since. None: something else is there (reported, never
        overwritten)."""
        try:
            dt = os.lstat(d)
        except OSError:
            return False
        if not statmod.S_ISREG(dt.st_mode):
            self._problem(rel, "something that isn't a file has this name on the new drive (left as it is)")
            return None
        if dt.st_size == st.st_size and abs(dt.st_mtime_ns - st.st_mtime_ns) <= TIME_SLACK_NS:
            want, have = xattrs_of(s), xattrs_of(d)
            sb, db = (birth_ns(st), birth_ns(dt)) if IS_MAC else (None, None)
            born = sb is not None and db is not None and abs(sb - db) > TIME_SLACK_NS
            if born or any(have.get(k) != v for k, v in want.items()):   # there, but a date or attribute isn't
                missed = copy_meta(s, d, st, self.perms)
                if missed:
                    self._problem(rel, "there already, but couldn't keep " + ", ".join(missed))
            self._record_already(rel, s, d, st, dt)
            return True
        if dt.st_size == st.st_size:
            digest = hash_file(Path(d))
            if digest == hash_file(Path(s)):
                missed = copy_meta(s, d, st, self.perms)         # the same file, its dates not yet put on
                if missed:
                    self._problem(rel, "there already, but couldn't keep " + ", ".join(missed))
                try:
                    now = os.lstat(d)                            # read on both drives just now: recorded as it is
                    self.sums.note(rel, digest, now.st_size, now.st_mtime_ns)
                except OSError:
                    pass
                return True
        if st.st_mtime_ns > dt.st_mtime_ns + TIME_SLACK_NS:
            why = self._not_ours(rel, d, dt)
            if not why:
                self.result.updated += 1      # changed on the old drive since this clone copied it (the app's
                return False                  # backup, a record): the newer one replaces our earlier copy
            what = f"a different, older file is already there under this name, and {why}"
        else:
            what = "a different file is already there under this name, as new or newer than the old drive's"
        self.result.conflicts += 1
        self._problem(rel, what + " (left as it is — not overwritten)")
        return None

    def _not_ours(self, rel: str, d: str, dt: os.stat_result) -> str:
        """Why the different, older file at `d` isn't this clone's to replace — "" when it is: the checksum
        record says a clone wrote it (or a byte-for-byte comparison found it equal to the old drive's), and it
        is still that file — the recorded size and date, and the recorded contents, read again here. An older
        date alone proves nothing: a file put on the new drive by hand, or edited there, can be older too."""
        self.sums.refresh()                                  # an edit made meanwhile may have dropped its entry
        known = self.sums.get(rel)
        if known is None:
            return "nothing records that this clone wrote it"
        if rel in self.sums.found:
            return "its checksum was recorded for a file found on the new drive, not for one this clone wrote"
        if not self.sums.matches(rel, dt):
            return "it has changed since this clone wrote it"
        try:
            if hash_file(Path(d), no_cache=True) != known[0]:
                return "its contents have changed since this clone wrote it"
        except OSError as e:
            return f"it couldn't be read ({e.strerror or e})"
        return ""

    def _record_already(self, rel: str, s: str, d: str, st: os.stat_result, dt: os.stat_result) -> None:
        """A file that's there at the same size and date but has no checksum recorded — one copied in the last
        moments before a run was cut off, or by a version that kept none — is read again on both drives and
        recorded when they agree (which also makes it one this clone may later bring up to date). Reading costs
        what copying did, so a run does it for `RECORD_ALREADY` bytes; the rest are counted, and the report says
        how they get recorded."""
        if self.sums.matches(rel, dt):
            return
        if st.st_size > self.record_left:
            self.result.unrecorded += 1
            return
        self.record_left -= st.st_size
        self._tick(os.path.basename(rel), "checking", force=True)
        try:
            digest = hash_file(Path(d), no_cache=True)
            same = digest == hash_file(Path(s))
        except OSError as e:
            self._problem(rel, f"there already, but couldn't be read again ({e.strerror or e})")
            return
        if same:
            self.sums.note(rel, digest, dt.st_size, dt.st_mtime_ns)
            self.result.recorded += 1
        else:
            self._problem(rel, "there already at the same size and date, but its contents differ from the old "
                               "drive's (left as it is — a comparison that reads every byte can copy it again)")

    def _file(self, rel: str, s: str, d: str, st: os.stat_result) -> None:
        name = os.path.basename(rel)
        self.sums.flush_if_due()              # also by the clock: one huge file mustn't hold the others' back
        there = self._same_already(rel, s, d, st)
        if there is not False:
            if there:
                self.result.already += 1
            self.done_files += 1
            self.done_bytes += st.st_size
            self._tick(name, "copying")
            return
        folder = os.path.dirname(d)
        tmp_name = f".{name}{TEMP_SUFFIX}"
        if len(tmp_name.encode("utf-8")) > 250:                   # a name already at the limit
            tmp_name = "." + hashlib.blake2b(name.encode("utf-8"), digest_size=12).hexdigest() + TEMP_SUFFIX
        tmp = os.path.join(folder, tmp_name)
        before = self.done_bytes
        for attempt in (1, 2):
            self.done_bytes = before
            try:
                digest = self._write(s, tmp, name)
                if self.verify:
                    self._tick(name, "checking", force=True)
                    if hash_file(Path(tmp), no_cache=True) != digest:
                        raise OSError("what was written doesn't match the original")
                missed = copy_meta(s, tmp, st, self.perms, flags=False)
                os.replace(tmp, d)
                put_flags(d, st, missed)                             # a locked file couldn't have been renamed
                if missed:
                    self._problem(rel, "copied, but couldn't keep " + ", ".join(missed))
                self._note_written(rel, d, digest, st)
                self.result.copied += 1
                self.result.copied_bytes += st.st_size
                break
            except Stopped:
                self._remove(tmp)
                raise
            except OSError as e:
                self._remove(tmp)
                if not os.path.isdir(self.dst) or not os.path.isdir(self.src):
                    raise Stopped("a drive went away mid-copy")
                if attempt == 2:
                    self.done_bytes = before + st.st_size
                    self._problem(rel, f"couldn't be copied ({e.strerror or e})")
        self.done_files += 1
        self._tick(name, "copying")

    def _note_written(self, rel: str, d: str, digest: str, st: os.stat_result) -> None:
        """The checksum of the file just written, under the size and date the drive now gives it (the date the
        record is later held against — the old drive's, unless the new drive couldn't keep it)."""
        try:
            now = os.lstat(d)
            self.sums.note(rel, digest, now.st_size, now.st_mtime_ns)
        except OSError:
            self.sums.note(rel, digest, st.st_size, st.st_mtime_ns)

    def recopy(self, rels: list[str]) -> Result:
        """Files the deep comparison found different on the new drive, copied again over the bad copy — only
        where that copy is ours (the original's size and date; anything else was changed by someone, and is
        left and reported)."""
        started = time.monotonic()
        for rel in rels:
            s, d = os.path.join(self.src, rel), os.path.join(self.dst, rel)
            try:
                st, dt = os.lstat(s), os.lstat(d)
            except OSError as e:
                self._problem(rel, f"couldn't be read ({e.strerror or e})")
                continue
            if not (statmod.S_ISREG(st.st_mode) and statmod.S_ISREG(dt.st_mode)):
                continue
            if dt.st_size != st.st_size or abs(dt.st_mtime_ns - st.st_mtime_ns) > TIME_SLACK_NS:
                self._problem(rel, "the file on the new drive isn't the copy this made (left as it is)")
                continue
            aside = os.path.join(os.path.dirname(d), f".{os.path.basename(d)}.bad-copy{TEMP_SUFFIX}")
            try:
                os.replace(d, aside)                         # out of the way; cleared once the new copy checks out
                before = self.result.copied
                self._file(rel, s, d, st)
                if self.result.copied > before:
                    self._remove(aside)
                elif not os.path.lexists(d):
                    os.replace(aside, d)                     # the copy failed: the old one back, still reported
            except Stopped:
                if not os.path.lexists(d) and os.path.lexists(aside):
                    os.replace(aside, d)
                self.result.stopped = True
                break
            except OSError as e:
                self._problem(rel, f"couldn't be copied again ({e.strerror or e})")
        # Putting a file back changed its folder's date: the folders get theirs again.
        for parent in sorted({os.path.dirname(rel) for rel in rels}, key=len, reverse=True):
            sp, dp = os.path.join(self.src, parent), os.path.join(self.dst, parent)
            try:
                copy_meta(sp, dp, os.lstat(sp), self.perms)
            except OSError:
                pass
        self._flush()
        self._keep_sums()
        self.result.seconds = time.monotonic() - started
        return self.result

    @staticmethod
    def _remove(path: str) -> None:
        try:
            os.remove(path)
        except OSError:
            pass

    def _write(self, s: str, tmp: str, name: str) -> str:
        h = hashlib.blake2b(digest_size=20)
        self._remove(tmp)
        with open(s, "rb", buffering=0) as fi, open(tmp, "wb", buffering=0) as fo:
            while True:
                self._breathe()
                chunk = fi.read(CHUNK)
                if not chunk:
                    break
                h.update(chunk)
                fo.write(chunk)
                self.done_bytes += len(chunk)
                self._tick(name, "copying")
            fo.flush()
            os.fsync(fo.fileno())
        return h.hexdigest()


def clear_leftovers(dst: str) -> int:
    """Temporary files an interrupted run left on the new drive."""
    n = 0
    for root, _dirs, files in os.walk(dst):
        for f in files:
            if f.startswith(".") and f.endswith(TEMP_SUFFIX):
                try:
                    os.remove(os.path.join(root, f))
                    n += 1
                except OSError:
                    pass
    return n


# ----------------------------------------------------------------------------- the drive's checksums
#
# APFS checksums its own records but not what's in the files: a photo that goes bad on the drive reads back
# without complaint, wrong. So the clone keeps the checksum it already worked out for every file it wrote —
# on the new drive, in `.Photo Browser Checksums/checksums.tsv` (digest, size, modified, path) — and `check_drive`
# can later read the drive again and say which files no longer are what was written. A file whose size or
# date has changed was edited, not damaged: it's counted apart, and re-recorded with `update`.
#
# **The file is a journal**: later lines win, and it is only ever added to while a run goes — a few hundred
# files or half a minute at a time, flushed to the drive (`Sums.flush`) — so hours of copying never hang on one
# save at the end. A line cut off mid-write has no line end and isn't a record (the next writer clears it).
# When a run ends the file is written again whole, sorted, under a temporary name and renamed (`compact_sums`).
# Besides the records (the four columns an earlier version wrote, unchanged) there are two notes, both
# comments to that version:
#   `#found<TAB>path`   the record before it is of a file as it was *found* on this drive (Record New Files,
#                       `forget_checksum(renew=True)`), not of one a clone wrote. Only a file a clone wrote —
#                       or a byte-for-byte comparison found equal to the old drive's — is the clone's own to
#                       bring up to date later (`Clone._not_ours`); a record with no note is one of those,
#                       which is also what every record made before the notes existed was.
#   `#forget<TAB>path`  the record is dropped: the file was changed in place (`forget_checksum`).

SUMS_DIR, SUMS_FILE = app_identity.CHECKSUMS, "checksums.tsv"
SUMS_HEAD = "# Photo Browser checksums v1 — blake2b-160\tsize\tmodified (ns)\tpath"
SUMS_FOUND, SUMS_FORGET = "#found\t", "#forget\t"
SAVE_EVERY, SAVE_SECONDS = 200, 30.0          # records held in memory before they're on the drive: at most these
RECORD_ALREADY = 4 * 1024 ** 3                # bytes of already-copied, unrecorded files one clone run reads again
_sums_lock = threading.RLock()                # one writer of a checksum file at a time (within this program)


def sums_folder(drive: str) -> str:
    """The checksums folder on `drive` — the one an earlier version made (under the app's old name) is brought
    to the new name when the drive lets it be, and read where it is when not."""
    old, new = os.path.join(drive, app_identity.OLD_CHECKSUMS), os.path.join(drive, SUMS_DIR)
    if os.path.isdir(old) and not os.path.exists(new):
        try:
            os.rename(old, new)
        except OSError:
            return old
    return new


def sums_path(drive: str) -> str:
    return os.path.join(sums_folder(drive), SUMS_FILE)


def _sums_stamp(drive: str) -> tuple[int, int] | None:
    try:
        st = os.stat(sums_path(drive))
        return st.st_size, st.st_mtime_ns
    except OSError:
        return None


class Sums(dict):
    """A drive's checksums: rel → (digest, size, mtime_ns), with `found` — the paths whose record is of a file
    as found on the drive rather than one a clone wrote (the notes above). Changes go through `note` and
    `forget`, which also queue the line for the drive's file; `flush` adds what's queued to it — by itself
    every `SAVE_EVERY` records, or `SAVE_SECONDS` after the last time when `flush_if_due` is called."""

    def __init__(self, drive: str = "") -> None:
        super().__init__()
        self.drive = drive                    # "" = in memory only
        self.found: set[str] = set()
        self.appended = 0                     # lines this object has added to the drive's file
        self._pending: list[str] = []
        self._flushed = time.monotonic()
        self._stamp: tuple[int, int] | None = None      # the file as this object last read or wrote it

    def matches(self, rel: str, st: os.stat_result) -> bool:
        """Whether `rel` is recorded at the size and date `st` has."""
        known = self.get(rel)
        return known is not None and known[1] == st.st_size and abs(known[2] - st.st_mtime_ns) <= TIME_SLACK_NS

    def note(self, rel: str, digest: str, size: int, mtime_ns: int, found: bool = False) -> None:
        self[rel] = (digest, size, mtime_ns)
        (self.found.add if found else self.found.discard)(rel)
        if "\n" in rel or "\t" in rel:
            return                                       # a name the file's format can't hold: not recorded
        self._pending.append(f"{digest}\t{size}\t{mtime_ns}\t{rel}")
        if found:
            self._pending.append(SUMS_FOUND + rel)
        if len(self._pending) >= SAVE_EVERY:
            self.flush()

    def forget(self, rel: str) -> None:
        self.pop(rel, None)
        self.found.discard(rel)
        if "\n" not in rel and "\t" not in rel:
            self._pending.append(SUMS_FORGET + rel)

    def flush_if_due(self) -> None:
        if self._pending and time.monotonic() - self._flushed >= SAVE_SECONDS:
            self.flush()

    def flush(self) -> bool:
        """What's queued, onto the drive. False when it couldn't be written — it stays queued for the next try."""
        self._flushed = time.monotonic()
        if not self._pending or not self.drive:
            return True
        with _sums_lock:
            ours = _sums_stamp(self.drive) == self._stamp
            if not _append_sums(self.drive, self._pending):
                return False
            self.appended += len(self._pending)
            self._pending = []
            if ours:                                     # nobody else wrote in between: still in step with it
                self._stamp = _sums_stamp(self.drive)
        return True

    def refresh(self) -> None:
        """Takes in what something else has written to the drive's file since (`forget_checksum` after an edit,
        while a clone or a check runs). Costs a stat unless the file did change."""
        if not self.drive or not self.flush() or _sums_stamp(self.drive) == self._stamp:
            return
        fresh = load_sums(self.drive)
        self.clear()
        self.update(fresh)
        self.found, self._stamp = fresh.found, fresh._stamp


def _append_sums(drive: str, lines: list[str]) -> bool:
    """Adds `lines` to the drive's checksum file and flushes them to the drive. A line an earlier writer was
    cut off in the middle of (no line end) is cleared first, so it can't run into these."""
    folder = sums_folder(drive)
    try:
        os.makedirs(folder, exist_ok=True)
        with _sums_lock, open(os.path.join(folder, SUMS_FILE), "ab+") as f:
            end = f.seek(0, os.SEEK_END)
            if end:
                back = min(end, 1 << 16)                 # far more than the longest line there can be
                f.seek(end - back)
                tail = f.read(back)
                if not tail.endswith(b"\n"):
                    end = end - back + tail.rfind(b"\n") + 1
                    f.truncate(end)
                    f.seek(0, os.SEEK_END)
            if not end:
                lines = [SUMS_HEAD, *lines]
            f.write(("\n".join(lines) + "\n").encode("utf-8", "surrogateescape"))
            f.flush()
            os.fsync(f.fileno())
        return True
    except OSError:
        return False


def load_sums(drive: str) -> Sums:
    out = Sums(drive)
    with _sums_lock:
        out._stamp = _sums_stamp(drive)
        try:
            with open(sums_path(drive), encoding="utf-8", errors="surrogateescape", newline="\n") as f:
                for line in f:
                    if not line.endswith("\n"):
                        break                            # cut off mid-write: not a record
                    line = line[:-1]
                    if line.startswith(SUMS_FOUND):
                        if line[len(SUMS_FOUND):] in out:
                            out.found.add(line[len(SUMS_FOUND):])
                        continue
                    if line.startswith(SUMS_FORGET):
                        rel = line[len(SUMS_FORGET):]
                        if rel not in out:               # noted by another spelling of its accents than the record's
                            rel = next((x for x in (unicodedata.normalize(form, rel) for form in ("NFC", "NFD"))
                                        if x in out), rel)
                        dict.pop(out, rel, None)
                        out.found.discard(rel)
                        continue
                    if line.startswith("#"):
                        continue
                    parts = line.split("\t", 3)
                    if len(parts) == 4 and len(parts[0]) == 40:
                        try:
                            out[parts[3]] = (parts[0], int(parts[1]), int(parts[2]))
                        except ValueError:
                            continue
                        out.found.discard(parts[3])
        except OSError:
            pass
    return out


def save_sums(drive: str, sums: Sums | dict) -> bool:
    """`sums` written as the drive's whole checksum file — under a temporary name, flushed, renamed."""
    folder = sums_folder(drive)
    found = getattr(sums, "found", ())
    with _sums_lock:
        try:
            os.makedirs(folder, exist_ok=True)
            tmp = os.path.join(folder, f".{SUMS_FILE}{TEMP_SUFFIX}")
            with open(tmp, "w", encoding="utf-8", errors="surrogateescape", newline="\n") as f:
                f.write(SUMS_HEAD + "\n")
                for rel in sorted(sums):
                    if "\n" in rel or "\t" in rel:
                        continue                         # a name the file's format can't hold: not recorded
                    digest, size, mtime = sums[rel]
                    f.write(f"{digest}\t{size}\t{mtime}\t{rel}\n")
                    if rel in found:
                        f.write(f"{SUMS_FOUND}{rel}\n")
                f.flush()
                os.fsync(f.fileno())
            os.replace(tmp, sums_path(drive))
        except OSError:
            return False
        if isinstance(sums, Sums) and sums.drive == drive:
            sums._pending = []                           # everything it holds is in the file now
            sums._stamp = _sums_stamp(drive)
    return True


def compact_sums(drive: str) -> bool:
    """The drive's checksum file read as it is now — every line anyone added — and written again whole: one
    line a file, sorted. Nothing is lost if this never runs; the file is only longer."""
    with _sums_lock:
        if _sums_stamp(drive) is None:
            return False
        return save_sums(drive, load_sums(drive))


def checksum_drive(path: str) -> str | None:
    """The drive whose checksum file covers `path` (the nearest folder above it that holds one) — None when no
    drive above it keeps checksums. Never makes or renames anything."""
    p = os.path.dirname(os.path.abspath(path))
    while True:
        if any(os.path.isfile(os.path.join(p, d, SUMS_FILE)) for d in (SUMS_DIR, app_identity.OLD_CHECKSUMS)):
            return p
        parent = os.path.dirname(p)
        if parent == p:
            return None
        p = parent


def forget_checksum(paths: str | Iterable[str], renew: bool = False) -> int:
    """For anything that changes a file in place: call this afterwards with the file (or all the files of a
    batch at once). An edit that keeps the file's size and date — ExifTool with -P, a photo edited in place with
    its dates put back — would otherwise look, to Check Files, exactly like a file gone bad on the drive.

    The file's record is dropped (it counts as "no checksum yet" until Record New Files), or with `renew` the
    file is read and recorded as it is now. Dropping costs a look for the drive's checksum file and one line
    added to it — no file is read and the checksums aren't loaded; on a drive that keeps none this does
    nothing at all. Never raises. Returns how many files were noted."""
    if isinstance(paths, (str, os.PathLike)):
        paths = [paths]
    by_drive: dict[str, list[str]] = {}
    folders: dict[str, str | None] = {}
    noted = 0
    try:
        for path in paths:
            path = os.path.abspath(os.fspath(path))
            folder = os.path.dirname(path)
            if folder not in folders:
                folders[folder] = checksum_drive(path)
            drive = folders[folder]
            if drive is None:
                continue
            rel = os.path.relpath(path, drive)
            if "\n" in rel or "\t" in rel or skipped_name(rel.split(os.sep)[0], True):
                continue
            lines = by_drive.setdefault(drive, [])
            if renew:
                try:
                    digest = hash_file(Path(path), no_cache=True)
                    st = os.lstat(path)                  # after the read: the date the record is held against
                    lines += [f"{digest}\t{st.st_size}\t{st.st_mtime_ns}\t{rel}", SUMS_FOUND + rel]
                except OSError:
                    lines.append(SUMS_FORGET + rel)      # can't be read now: better no record than a stale one
            else:
                lines.append(SUMS_FORGET + rel)
            noted += 1
        for drive, lines in by_drive.items():
            if not _append_sums(drive, lines):
                noted -= sum(1 for x in lines if not x.startswith(SUMS_FOUND))
    except (OSError, ValueError):
        pass
    return max(noted, 0)


@dataclass
class Check:
    files: int = 0                    # regular files on the drive
    intact: int = 0                   # read again: what was written
    damaged: list[str] = field(default_factory=list)      # same size and date, different contents: gone bad —
                                                          # or edited by something that kept the date
    missing: list[str] = field(default_factory=list)      # recorded, no longer there
    changed: int = 0                  # size or date differs from the record: edited since
    unrecorded: int = 0               # no checksum yet (new since the clone)
    recorded: int = 0                 # checksums added or renewed by this run (`update`)
    unreadable: list[tuple[str, str]] = field(default_factory=list)
    bytes_read: int = 0
    stopped: bool = False
    seconds: float = 0.0


def check_drive(drive: str, update: bool = False,
                progress: Callable[[int, int, str], None] = lambda done, total, name: None,
                stop: Callable[[], bool] = lambda: False) -> Check:
    """Every file on `drive` read again and held against the checksum recorded for it. With `update`, files
    that have none yet — or were changed since — are read and recorded, so the next check covers them (they go
    onto the drive as the run goes: stopping or a crash keeps what was read). Nothing but the checksum file is
    ever written; no file is changed, moved or removed."""
    drive = os.path.abspath(drive)
    sums = load_sums(drive)
    out = Check()
    started = time.monotonic()
    seen: set[str] = set()
    todo: list[str] = []
    for root, dirs, files in os.walk(drive):
        rel_root = os.path.relpath(root, drive)
        rel_root = "" if rel_root == "." else rel_root
        dirs[:] = sorted(x for x in dirs if not skipped_name(x, not rel_root))
        for name in sorted(files):
            if not skipped_name(name, not rel_root):
                todo.append(os.path.join(rel_root, name) if rel_root else name)
        if stop():
            out.stopped = True
            return out
    try:
        for i, rel in enumerate(todo):
            if stop():
                out.stopped = True
                break
            sums.flush_if_due()
            path = os.path.join(drive, rel)
            try:
                st = os.lstat(path)
            except OSError:
                continue
            if not statmod.S_ISREG(st.st_mode):
                continue
            out.files += 1
            seen.add(rel)
            known = sums.get(rel)
            same = sums.matches(rel, st)
            if not same and not update:
                if known is None:
                    out.unrecorded += 1
                else:
                    out.changed += 1
                continue
            progress(i, len(todo), rel)
            try:
                digest = hash_file(Path(path), no_cache=True)
            except OSError as e:
                out.unreadable.append((rel, e.strerror or str(e)))
                continue
            out.bytes_read += st.st_size
            if same and digest == known[0]:
                out.intact += 1
                continue
            if same:
                # Not what was recorded. Before it's called damaged: was its record dropped or renewed while this
                # check ran (`forget_checksum`, after an edit that kept the date)? Then it's a changed file.
                sums.refresh()
                if sums.get(rel) == known:
                    out.damaged.append(rel)
                    continue
                known, same = sums.get(rel), False
                if known is not None and sums.matches(rel, st) and digest == known[0]:
                    out.intact += 1
                    continue
            if known is None:
                out.unrecorded += 1
            else:
                out.changed += 1
            if update:
                sums.note(rel, digest, st.st_size, st.st_mtime_ns, found=True)
                out.recorded += 1
        if not out.stopped:
            out.missing = sorted(rel for rel in sums if rel not in seen)
            if update:
                for rel in out.missing:
                    sums.forget(rel)
    finally:
        if sums.flush() and sums.appended:
            compact_sums(drive)
    progress(len(todo), len(todo), "")
    out.seconds = time.monotonic() - started
    return out


def check_report(drive: str, c: Check, update: bool) -> str:
    def n(count: int, word: str) -> str:
        return f"{count:,} {word}{'' if count == 1 else 's'}"
    lines = [f"Check of “{drive}” — {time.strftime('%Y-%m-%d %H:%M')}", "",
             f"{n(c.files, 'file')} on the drive; {human(c.bytes_read)} read again"
             + (" — STOPPED before the end." if c.stopped else ".")]
    if c.intact or not (c.damaged or c.recorded):
        lines.append(f"   {c.intact:,} read back exactly as written.")
    for rel in c.damaged[:200]:
        lines.append(f"   DAMAGED OR EDITED: {rel} — the same size and date as when its checksum was recorded, "
                     "but its contents are different")
    if len(c.damaged) > 200:
        lines.append(f"   … and {len(c.damaged) - 200:,} more damaged or edited")
    if c.damaged:
        lines.append("   Either such a file has gone bad on the drive, or it was edited by something that keeps a "
                     "file's date —\n   a metadata edit that preserves dates, a photo edited in place. The check "
                     "can't tell which: look at it.\n   If you edited it, nothing is wrong; to record it as it is "
                     f"now:  clone_drive.py \"{drive}\" --forget FILE…  then Record New Files.\n   If you "
                     "didn't: a damaged file can't be mended from the drive itself — put it back from another "
                     "copy (the old drive, a backup).")
    for rel, why in c.unreadable[:50]:
        lines.append(f"   COULDN'T READ: {rel} — {why}")
    for rel in c.missing[:50]:
        lines.append(f"   GONE since it was recorded: {rel}")
    if len(c.missing) > 50:
        lines.append(f"   … and {len(c.missing) - 50:,} more gone (moved, renamed or deleted)")
    if update:
        if c.recorded:
            lines.append(f"   {n(c.recorded, 'file')} recorded for next time (new, or changed since).")
    else:
        if c.changed:
            lines.append(f"   {n(c.changed, 'file')} changed since recorded (a different size or date — edited, not damaged).")
        if c.unrecorded:
            lines.append(f"   {n(c.unrecorded, 'file')} with no checksum yet (added since). “Record New Files” reads and records them.")
    if not c.files:
        lines.append("   Nothing to check.")
    return "\n".join(lines) + "\n"


def keep_awake() -> "subprocess.Popen | None":
    """Keeps the Mac (and its drives) from sleeping until `.terminate()` — or this program ends. A clone of a
    few terabytes runs for hours; a Mac that dozes off unmounts the drives under it."""
    if not IS_MAC or not shutil.which("caffeinate"):
        return None
    try:
        return subprocess.Popen(["caffeinate", "-i", "-m", "-s", "-w", str(os.getpid())],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except OSError:
        return None


# ----------------------------------------------------------------------------- comparing the two drives

@dataclass
class Comparison:
    checked: int = 0
    bytes_read: int = 0
    missing: list[str] = field(default_factory=list)
    different: list[tuple[str, str]] = field(default_factory=list)       # (rel, what differs) — content, kind, size
    metadata: list[tuple[str, str]] = field(default_factory=list)        # (rel, what differs) — dates, attributes
    folder_dates: int = 0                                                 # of `metadata`: folders, by their own date
    extra: int = 0                                                        # on the new drive only (not a problem)
    extra_names: list[str] = field(default_factory=list)                 # the first of them
    stopped: bool = False
    deep: bool = False

    @property
    def problems(self) -> int:
        return len(self.missing) + len(self.different) + len(self.metadata)


def compare(src: str, dst: str, plan: Scan, deep: bool = False,
            progress: Callable[[int, int, str], None] = lambda done, total, name: None,
            stop: Callable[[], bool] = lambda: False, collect: Sums | None = None) -> Comparison:
    """Every item in `plan` looked for on the new drive: there, the same kind and size, the same dates and
    attributes — and with `deep`, the same bytes (both drives read from the drive, not from memory). `collect`
    (the new drive's `load_sums`) is given the checksum of every file read and found right; a `Sums` puts them
    on the drive as the comparison goes, so one that's stopped after hours has kept what it read."""
    out = Comparison(deep=deep)
    src, dst = os.path.abspath(src), os.path.abspath(dst)
    has_birth = IS_MAC and fs_type(dst) not in ("exfat", "msdos") and fs_type(src) not in ("msdos",)
    total = len(plan.items)
    known = {it.rel for it in plan.items}
    for i, it in enumerate(plan.items):
        if stop():
            out.stopped = True
            break
        if i % 200 == 0:
            progress(i, total, it.rel)
        s, d = os.path.join(src, it.rel), os.path.join(dst, it.rel)
        try:
            ss = os.lstat(s)
        except OSError:
            continue                                               # gone from the old drive since the scan
        try:
            ds = os.lstat(d)
        except OSError:
            out.missing.append(it.rel)
            continue
        out.checked += 1
        if statmod.S_IFMT(ss.st_mode) != statmod.S_IFMT(ds.st_mode):
            out.different.append((it.rel, "a file on one drive, a folder on the other"))
            continue
        if it.kind == "link":
            if os.readlink(s) != os.readlink(d):
                out.different.append((it.rel, "the link points somewhere else"))
            continue
        if it.kind == "file":
            if ss.st_size != ds.st_size:
                out.different.append((it.rel, f"{human(ss.st_size)} on the old drive, {human(ds.st_size)} on the new"))
                continue
            if deep:
                progress(i, total, it.rel)
                try:
                    digest = hash_file(Path(d), no_cache=True)
                    if hash_file(Path(s), no_cache=True) != digest:
                        out.different.append((it.rel, "the contents differ"))
                        continue
                    if isinstance(collect, Sums):        # read and found right: its checksum, for check_drive
                        if not collect.matches(it.rel, ds) or collect[it.rel][0] != digest or it.rel in collect.found:
                            collect.note(it.rel, digest, ds.st_size, ds.st_mtime_ns)
                        collect.flush_if_due()
                    elif collect is not None:
                        collect[it.rel] = (digest, ds.st_size, ds.st_mtime_ns)
                    out.bytes_read += ss.st_size * 2
                except OSError as e:
                    out.different.append((it.rel, f"couldn't be read ({e.strerror or e})"))
                    continue
        what: list[str] = []
        if abs(ss.st_mtime_ns - ds.st_mtime_ns) > TIME_SLACK_NS:
            what.append("modification date")
            if it.kind == "dir":
                out.folder_dates += 1
        sb, db = birth_ns(ss), birth_ns(ds)
        if has_birth and sb is not None and db is not None and abs(sb - db) > TIME_SLACK_NS:
            what.append("creation date")
        sx, dx = xattrs_of(s), xattrs_of(d)
        lost = [k for k, v in sx.items() if dx.get(k) != v]
        if lost:
            what.append("attribute" + ("s " if len(lost) != 1 else " ") + ", ".join(sorted(lost)[:4]))
        if what:
            out.metadata.append((it.rel, ", ".join(what)))
    progress(total, total, "")
    if isinstance(collect, Sums):
        collect.flush()
    if not out.stopped:
        out.extra = count_extra(dst, known, stop, out.extra_names)
    return out


def match_details(src: str, dst: str, rels: list[str], perms: bool | None = None,
                  progress: Callable[[int, int, str], None] = lambda done, total, name: None,
                  stop: Callable[[], bool] = lambda: False) -> tuple[int, list[tuple[str, str]]]:
    """The old drive's dates and attributes put onto items the comparison found there but not the same in those
    (`Comparison.metadata`). No file's contents are touched. A file whose modification date differs is first
    read on both drives: only an identical file gets the old dates — one that was changed on the new drive is
    left as it is and said so. Files first, then folders, deepest first (a folder's own date is the last thing
    that may change in it). Returns (how many were matched, [(rel, why not)])."""
    src, dst = os.path.abspath(src), os.path.abspath(dst)
    if perms is None:
        perms = fs_type(src) not in ("exfat", "msdos")
    done, left = 0, []
    files, folders = [], []
    for rel in rels:
        (folders if os.path.isdir(os.path.join(src, rel)) and not os.path.islink(os.path.join(src, rel)) else files).append(rel)
    folders.sort(key=lambda r: r.count(os.sep), reverse=True)
    order = files + folders
    for i, rel in enumerate(order):
        if stop():
            break
        if i % 50 == 0:
            progress(i, len(order), rel)
        s, d = os.path.join(src, rel), os.path.join(dst, rel)
        try:
            ss, ds = os.lstat(s), os.lstat(d)
        except OSError as e:
            left.append((rel, f"couldn't be read ({e.strerror or e})"))
            continue
        if statmod.S_IFMT(ss.st_mode) != statmod.S_IFMT(ds.st_mode):
            left.append((rel, "a file on one drive, a folder on the other"))
            continue
        if statmod.S_ISREG(ss.st_mode):
            if ss.st_size != ds.st_size:
                left.append((rel, "the file on the new drive is a different size — it was changed there"))
                continue
            if abs(ss.st_mtime_ns - ds.st_mtime_ns) > TIME_SLACK_NS:
                progress(i, len(order), rel)
                try:
                    same = hash_file(Path(s)) == hash_file(Path(d))
                except OSError as e:
                    left.append((rel, f"couldn't be read ({e.strerror or e})"))
                    continue
                if not same:
                    left.append((rel, "the file was changed on the new drive (left as it is)"))
                    continue
        missed = copy_meta(s, d, ss, perms)
        if missed:
            left.append((rel, "couldn't keep " + ", ".join(missed)))
        else:
            done += 1
    progress(len(order), len(order), "")
    return done, left


def count_extra(dst: str, known: set[str], stop: Callable[[], bool] = lambda: False,
                names: list[str] | None = None) -> int:
    """How many items are on the new drive only; the first 40 of them into `names`. (A folder that's only
    there counts once — what's inside it isn't listed too.)"""
    n = 0
    for root, dirs, files in os.walk(dst):
        if stop():
            break
        rel_root = os.path.relpath(root, dst)
        rel_root = "" if rel_root == "." else rel_root
        dirs[:] = sorted(x for x in dirs if not skipped_name(x, not rel_root))
        for name in dirs + sorted(files):
            if skipped_name(name, not rel_root):
                continue
            rel = os.path.join(rel_root, name) if rel_root else name
            if rel not in known:
                n += 1
                if names is not None and len(names) < 40:
                    names.append(rel)
        dirs[:] = [x for x in dirs if (os.path.join(rel_root, x) if rel_root else x) in known]
    return n


# ----------------------------------------------------------------------------- the new drive takes the old name

def old_drive_name(name: str, kind: str) -> str:
    """What the old drive is called once the new one has its name ("SSD" → "SSD (old)"; an exFAT/FAT label
    holds 11 characters: "SSD old")."""
    if kind in ("exfat", "msdos"):
        return (name[:7].rstrip() + " old")[:11]
    return f"{name} (old)"


def swap_names(old: str, new: str) -> tuple[bool, str]:
    """Renames the old drive to "<name> (old)" and gives the new drive the old one's name, so every path that
    names the drive — Photo Browser for Mac's own records on this Mac, and the iPhone app's keys when the drive's name is
    part of them — still points at the library. macOS only (`diskutil rename`). → (worked, what to tell)."""
    if not IS_MAC:
        return False, "Renaming drives is only done on a Mac."
    if not (os.path.ismount(old) and os.path.ismount(new)):
        return False, "Both have to be whole drives (not folders) to be renamed."
    name = os.path.basename(old.rstrip("/"))
    aside = old_drive_name(name, fs_type(old))
    try:
        r = subprocess.run(["diskutil", "rename", old, aside], capture_output=True, text=True, timeout=120)
        if r.returncode != 0:
            return False, f"Couldn't rename “{name}”: {(r.stderr or r.stdout).strip()}"
        r = subprocess.run(["diskutil", "rename", new, name], capture_output=True, text=True, timeout=120)
        if r.returncode != 0:
            return False, (f"“{name}” is now “{aside}”, but the new drive couldn't be renamed: "
                           f"{(r.stderr or r.stdout).strip()} — rename it to “{name}” in Finder.")
    except (OSError, subprocess.SubprocessError) as e:
        return False, f"Couldn't rename the drives: {e}"
    return True, f"The new drive is now “{name}”; the old one is “{aside}”."


# ----------------------------------------------------------------------------- the report

IPHONE_STEPS = """On the iPhone:
  1. BEFORE the old drive is retired: open it in Photo Browser ▸ Drive Health ▸ Back Up Metadata Now, then clone
     once more (only what changed is copied) — so the new drive carries everything the phone knows.
  2. Give the new drive the old drive's name (the window's button does it, or rename both in Finder), plug it
     into the iPhone and choose its top folder in Photo Browser.
  3. Check a few Favorites, captions and covers. If any are missing: Drive Health ▸ Restore from the Drive's
     Backup. It reads the backup copied in step 1 and only adds what's missing — nothing set is overwritten.
     Tags, Favorites and To AI also come back by themselves from shared-tags.json on the drive.
  4. Recently Deleted: restore or delete what's in it before the move if you can — the files come across
     (in .Trash), but where each one came from is remembered only on the phone.
  5. Keep the old drive untouched until you've looked through the new one."""


DETAILS_NOTE = """
   About those {count}: each one IS on the new drive (a file, at the same size) — none of them is missing.
   Only the dates or attributes named are not the old drive's. The usual reasons:
     - a folder's modification date moves whenever something is added to it or removed from it, so any folder
       touched on the new drive since the clone shows here ({folders} of these are folders by their own date);
     - folders are given their dates last, so a clone that was stopped before the end hasn't dated them yet;
     - a file made after it was last modified (anything downloaded or copied with its date kept) could lose
       its creation date in the first version of this tool.
   To give them the old drive's dates and attributes: “Match Dates and Attributes” in the Clone Drive window
   (or `clone_drive.py OLD NEW --verify --match-dates`). No file's contents are touched; a file that was
   really changed on the new drive is left as it is."""


CONFLICT_NOTE = """
   About the {count} "already there under this name": the new drive has a different file where the old drive
   has one, and nothing was overwritten. A clone replaces only what it can show is its own earlier copy — the
   drive's checksum record says a clone wrote it, and it is unchanged since. A file put there by hand, edited
   on the new drive, or copied by a run that kept no record is left for you to decide: if the old drive's is the
   one you want, move the new drive's out of the way (or delete it) and clone again."""


def report(src: str, dst: str, plan: Scan, result: Result | None, cmp: Comparison | None) -> str:
    def n(count: int, word: str) -> str:
        return f"{count:,} {word}{'' if count == 1 else 's'}"
    lines = [f"Clone of “{src}” to “{dst}” — {time.strftime('%Y-%m-%d %H:%M')}", ""]
    lines.append(f"On the old drive: {n(plan.files, 'file')} in {n(plan.folders, 'folder')}, {human(plan.bytes)}"
                 + (f", {n(plan.links, 'link')}" if plan.links else "") + ".")
    if plan.left_out:
        lines.append(f"Left out on purpose: {n(plan.left_out, 'item')} of macOS/Windows bookkeeping "
                     f"(.DS_Store, ._ companions, Spotlight, Trashes…), {human(plan.left_out_bytes)}.")
    for rel, why in plan.unreadable[:50]:
        lines.append(f"COULDN'T READ on the old drive: {rel} — {why}")
    if len(plan.unreadable) > 50:
        lines.append(f"… and {len(plan.unreadable) - 50:,} more that couldn't be read")
    if result is not None:
        lines.append("")
        took = f"{result.seconds / 3600:.1f} h" if result.seconds >= 5400 else f"{result.seconds / 60:.0f} min" \
            if result.seconds >= 90 else f"{result.seconds:.0f} s"
        lines.append(f"Copied {n(result.copied, 'file')} ({human(result.copied_bytes)}) in {took}; "
                     f"{n(result.already, 'file')} already there and the same; {n(result.folders, 'folder')}."
                     + (f" {n(result.updated, 'file')} had changed on the old drive since an earlier run and "
                        f"{'was' if result.updated == 1 else 'were'} brought up to date." if result.updated else "")
                     + (" STOPPED before the end — run it again to carry on." if result.stopped else ""))
        if result.recorded:
            lines.append(f"{n(result.recorded, 'file')} already there had no checksum recorded (copied just before "
                         "an earlier run was cut off, or by a version that kept none): read again on both drives, "
                         "the same, and recorded.")
        if result.unrecorded:
            lines.append(f"{n(result.unrecorded, 'file')} already there still {'has' if result.unrecorded == 1 else 'have'} "
                         "no checksum recorded — more than a run reads again by itself. “Check Files”, then “Record "
                         "New Files”, records them as they are; a comparison that reads every byte (--verify --deep) "
                         "records them once they're found equal to the old drive's.")
        for p in result.problems[:200]:
            lines.append(f"PROBLEM: {p.rel} — {p.what}")
        if len(result.problems) > 200:
            lines.append(f"… and {len(result.problems) - 200:,} more problems")
        if result.conflicts:
            lines.append(CONFLICT_NOTE.format(count=n(result.conflicts, "file")))
    if cmp is not None:
        lines.append("")
        how = "every byte of both drives read again" if cmp.deep else "names, kinds, sizes, dates and attributes"
        lines.append(f"Compared {n(cmp.checked, 'item')} ({how})" + (" — STOPPED before the end" if cmp.stopped else "") + ":")
        if cmp.problems == 0 and not cmp.stopped:
            lines.append("   0 problems — everything on the old drive is on the new one, the same.")
        for rel in cmp.missing[:200]:
            lines.append(f"   MISSING on the new drive: {rel}")
        if len(cmp.missing) > 200:
            lines.append(f"   … and {len(cmp.missing) - 200:,} more missing")
        for rel, what in cmp.different[:200]:
            lines.append(f"   DIFFERENT: {rel} — {what}")
        for rel, what in cmp.metadata[:200]:
            lines.append(f"   COPIED, but not with the same {what}: {rel}")
        if len(cmp.metadata) > 200:
            lines.append(f"   … and {len(cmp.metadata) - 200:,} more copied, but not with the same dates or attributes")
        if cmp.metadata:
            lines.append(DETAILS_NOTE.format(count=n(len(cmp.metadata), "item"),
                                             folders=n(cmp.folder_dates, "folder")))
        if cmp.extra:
            lines.append(f"   ({n(cmp.extra, 'item')} on the new drive that the old one doesn't have — left alone"
                         + (":" if cmp.extra_names else ".)"))
            for rel in cmp.extra_names:
                lines.append(f"      {rel}")
            if cmp.extra_names:
                more = cmp.extra - len(cmp.extra_names)
                lines.append(f"      … and {more:,} more.)" if more > 0 else "   )")
    lines += ["", IPHONE_STEPS, ""]
    return "\n".join(lines)


def save_report(text: str) -> str:
    try:
        LOGS.mkdir(parents=True, exist_ok=True)
        path = LOGS / f"clone-{time.strftime('%Y%m%d-%H%M%S')}.txt"
        path.write_text(text, encoding="utf-8")
        return str(path)
    except OSError:
        return ""


def main() -> None:
    import argparse
    ap = argparse.ArgumentParser(description="Copy a whole drive to a new one, checking every file, and compare them.")
    ap.add_argument("old", help="the old drive — or, with --check, the drive to check")
    ap.add_argument("new", nargs="?")
    ap.add_argument("--check", action="store_true",
                    help="read every file on the one drive given again and compare with its recorded checksum")
    ap.add_argument("--record", action="store_true",
                    help="with --check: also record checksums for files that have none yet or were changed")
    ap.add_argument("--forget", nargs="+", metavar="FILE",
                    help="drop the recorded checksum of files on the drive you edited yourself (a check lists them "
                         "as damaged or edited); --check --record then records them as they are")
    ap.add_argument("--apply", action="store_true", help="copy (default: only say what would be copied)")
    ap.add_argument("--verify", action="store_true", help="only compare the two drives")
    ap.add_argument("--deep", action="store_true", help="with --verify (or after --apply): read every byte of both again")
    ap.add_argument("--repair", action="store_true", help="with --verify --deep: copy again the files whose contents differ")
    ap.add_argument("--match-dates", action="store_true",
                    help="with --verify: give items whose dates or attributes differ the old drive's (contents untouched)")
    ap.add_argument("--allow-exfat", action="store_true", help="let the new drive be exFAT (dates/attributes will suffer)")
    a = ap.parse_args()
    awake = keep_awake()                                  # until this program ends
    if a.forget:
        files = [f if os.path.isabs(f) or os.path.lexists(f) else os.path.join(a.old, f) for f in a.forget]
        print(f"Dropped the checksum record of {forget_checksum(files):,} file(s).")
        if not a.check:
            return
    if a.check:
        print(f"Checking “{a.old}”…" + (" (recording files that have no checksum yet)" if a.record else ""))
        last = [0.0]

        def tick(done: int, total: int, name: str) -> None:
            if time.monotonic() - last[0] > 2:
                last[0] = time.monotonic()
                print(f"\r  {done:,}/{total:,}  {name[-60:]:60}", end="", flush=True)
        c = check_drive(a.old, update=a.record, progress=tick)
        text = check_report(a.old, c, a.record)
        print("\n" + text)
        sys.exit(2 if c.damaged or c.unreadable else 0)
    if not a.new:
        ap.error("the new drive is missing")
    print(f"Reading “{a.old}”…")
    plan = scan(a.old)
    print(f"  {plan.files:,} files in {plan.folders:,} folders, {human(plan.bytes)}; "
          f"{plan.left_out:,} items of system bookkeeping left out.")
    blocks = preflight(a.old, a.new, plan, a.allow_exfat)
    for b in blocks:
        print("  ✗ " + b)
    if blocks:
        sys.exit(1)
    result = None
    if a.apply and not a.verify:
        cleared = clear_leftovers(a.new)
        if cleared:
            print(f"  cleared {cleared:,} temporary file(s) from an earlier run")
        last = [0.0]

        def progress(df, tf, db, tb, name, phase):
            if time.monotonic() - last[0] > 2 or phase == "done":
                last[0] = time.monotonic()
                pct = 100 * db / tb if tb else 100
                print(f"\r  {pct:5.1f}%  {df:,}/{tf:,} files  {human(db)} of {human(tb)}  {name[:40]:40}", end="", flush=True)
        result = Clone(a.old, a.new, plan, progress, lambda s: print("\n" + s)).run()
        print()
    elif not a.verify:
        need = bytes_missing(a.old, a.new, plan)
        print(f"  {human(need)} would be copied. Run again with --apply.")
        return
    print("Comparing the two drives…" + (" (every byte — this takes as long as the copy)" if a.deep else ""))
    sums = load_sums(a.new) if a.deep else None
    cmp = compare(a.old, a.new, plan, deep=a.deep, collect=sums)     # (the checksums go onto the drive as it reads)
    if sums is not None and sums.appended:
        compact_sums(a.new)
    bad = [rel for rel, what in cmp.different if what == "the contents differ"]
    if bad and a.repair:
        print(f"Copying {len(bad):,} file(s) again…")
        result = Clone(a.old, a.new, plan, log=print).recopy(bad)
        cmp = compare(a.old, a.new, plan, deep=a.deep)
    if cmp.metadata and a.match_dates:
        print(f"Matching the dates and attributes of {len(cmp.metadata):,} item(s)…")
        done, left = match_details(a.old, a.new, [rel for rel, _ in cmp.metadata])
        for rel, why in left[:200]:
            print(f"  left: {rel} — {why}")
        print(f"  {done:,} matched, {len(left):,} left as they are.")
        cmp = compare(a.old, a.new, plan, deep=False)
    text = report(a.old, a.new, plan, result, cmp)
    print("\n" + text)
    saved = save_report(text)
    if saved:
        print(f"Report saved: {saved}")
    sys.exit(0 if cmp.problems == 0 and not (result and (result.problems or result.stopped)) else 2)


if __name__ == "__main__":
    main()
