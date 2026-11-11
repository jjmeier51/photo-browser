#!/usr/bin/env python3
"""Move the whole library to a new SSD without losing anything — Safe Finder's "Clone Drive to a New SSD…"
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
doesn't need (`.Spare Folders`, `.Safe Finder Staging`). The run counts them.

**How each file is copied**: read once (its checksum taken as it's read), written under a temporary name,
flushed to the drive, **read back from the drive itself** (not the Mac's memory) and its checksum compared;
then its attributes, permissions and dates are put on and only then is it renamed to its real name — so a
file under its real name on the new drive is always whole and checked. A run that's stopped, or cut off by
a cable, is simply run again: what's there and the same is skipped, the temporary file is cleared.
**Nothing of yours on the new drive is overwritten**: a different file already at a path is reported and
left — except an earlier copy this made that the old drive's file has since outdated (the app's metadata backup
after "Back Up Metadata Now", a download record): that one is brought up to date, the newer replacing the older.

**Then the two drives are compared** (`compare`): every item present, the same kind and size, its dates and
attributes equal. `--deep` also reads every byte of both again. The report (also saved in
`~/Library/Logs/Safe Finder/`) lists anything that differs; "0 problems" means the new drive has everything.

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
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import shared_tags  # noqa: E402 — its xattr calls (libc on macOS)
from safe_copy_to_ssd import CHUNK, hash_file, human  # noqa: E402

SKIP_AT_ROOT = {".Spotlight-V100", ".fseventsd", ".Trashes", ".TemporaryItems", ".DocumentRevisions-V100",
                ".apdisk", ".com.apple.timemachine.donotpresent", "$RECYCLE.BIN", "System Volume Information",
                ".Spare Folders", ".Safe Finder Staging", ".PKInstallSandboxManager",
                ".PKInstallSandboxManager-SystemSoftware", ".HFS+ Private Directory Data\r", ".journal",
                ".journal_info_block", "lost+found"}
SKIP_ANYWHERE = {".DS_Store", ".localized"}
TEMP_SUFFIX = ".cloning"
# Attributes macOS puts on (or guards) itself: they can't be written by a program, and mean nothing copied.
UNCOPYABLE_XATTRS = ("com.apple.provenance", "com.apple.macl", "com.apple.rootless", "com.apple.lastuseddate#PS",
                     "com.apple.quarantine")
TIME_SLACK_NS = 2_000                # dates are compared to within 2 µs (APFS keeps nanoseconds; Python floats don't)
LOGS = Path.home() / "Library" / "Logs" / "Safe Finder"
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
    folders: int = 0
    links: int = 0
    problems: list[Problem] = field(default_factory=list)
    stopped: bool = False
    seconds: float = 0


class Stopped(Exception):
    pass


def preflight(src: str, dst: str, plan: Scan | None = None, allow_exfat: bool = False) -> list[str]:
    """What stands in the way, as sentences ([] = go)."""
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
        r.seconds = time.monotonic() - started
        self._tick("", "done", force=True)
        return r

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
        """True: the file's there and the same (left). False: copy it — it's missing, or the old drive's is
        newer than the copy here. None: something else is there (reported, never overwritten)."""
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
            return True
        if dt.st_size == st.st_size and hash_file(Path(d)) == hash_file(Path(s)):
            missed = copy_meta(s, d, st, self.perms)             # the same file, its dates not yet put on
            if missed:
                self._problem(rel, "there already, but couldn't keep " + ", ".join(missed))
            return True
        if st.st_mtime_ns > dt.st_mtime_ns + TIME_SLACK_NS:
            self.result.updated += 1          # changed on the old drive since it was copied (the app's backup, a
            return False                      # record): the newer one replaces our earlier copy
        self._problem(rel, "a different file is already there under this name, as new or newer than the old "
                           "drive's (left as it is — not overwritten)")
        return None

    def _file(self, rel: str, s: str, d: str, st: os.stat_result) -> None:
        name = os.path.basename(rel)
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
    stopped: bool = False
    deep: bool = False

    @property
    def problems(self) -> int:
        return len(self.missing) + len(self.different) + len(self.metadata)


def compare(src: str, dst: str, plan: Scan, deep: bool = False,
            progress: Callable[[int, int, str], None] = lambda done, total, name: None,
            stop: Callable[[], bool] = lambda: False) -> Comparison:
    """Every item in `plan` looked for on the new drive: there, the same kind and size, the same dates and
    attributes — and with `deep`, the same bytes (both drives read from the drive, not from memory)."""
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
                    if hash_file(Path(s), no_cache=True) != hash_file(Path(d), no_cache=True):
                        out.different.append((it.rel, "the contents differ"))
                        continue
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
    if not out.stopped:
        out.extra = count_extra(dst, known, stop)
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


def count_extra(dst: str, known: set[str], stop: Callable[[], bool] = lambda: False) -> int:
    n = 0
    for root, dirs, files in os.walk(dst):
        if stop():
            break
        rel_root = os.path.relpath(root, dst)
        rel_root = "" if rel_root == "." else rel_root
        dirs[:] = [x for x in dirs if not skipped_name(x, not rel_root)]
        for name in dirs + files:
            if skipped_name(name, not rel_root):
                continue
            if (os.path.join(rel_root, name) if rel_root else name) not in known:
                n += 1
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
    names the drive — Safe Finder's own records on this Mac, and the iPhone app's keys when the drive's name is
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
        for p in result.problems[:200]:
            lines.append(f"PROBLEM: {p.rel} — {p.what}")
        if len(result.problems) > 200:
            lines.append(f"… and {len(result.problems) - 200:,} more problems")
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
            lines.append(f"   ({n(cmp.extra, 'item')} on the new drive that the old one doesn't have — left alone.)")
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
    ap.add_argument("old")
    ap.add_argument("new")
    ap.add_argument("--apply", action="store_true", help="copy (default: only say what would be copied)")
    ap.add_argument("--verify", action="store_true", help="only compare the two drives")
    ap.add_argument("--deep", action="store_true", help="with --verify (or after --apply): read every byte of both again")
    ap.add_argument("--repair", action="store_true", help="with --verify --deep: copy again the files whose contents differ")
    ap.add_argument("--match-dates", action="store_true",
                    help="with --verify: give items whose dates or attributes differ the old drive's (contents untouched)")
    ap.add_argument("--allow-exfat", action="store_true", help="let the new drive be exFAT (dates/attributes will suffer)")
    a = ap.parse_args()
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
    cmp = compare(a.old, a.new, plan, deep=a.deep)
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
