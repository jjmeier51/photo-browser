"""Photo Browser tags, shared between the Mac (Safe Finder) and the Photo Browser app on the iPhone.

Where they live
  On a drive: `<drive>/.Photo Browser Metadata/shared-tags.json` — the hidden folder the iPhone app
  already keeps its metadata backups in — keyed by each file's path inside the drive
  ("Trips/2024/IMG_0001.jpg"), so a file has the same key on the Mac (/Volumes/SSD/…) and on the
  iPhone (…/SSD/…). The drive is the folder the app browses; if the app's folder is one inside the
  drive, the nearest folder holding `.Photo Browser Metadata` is used instead.
  On the Mac's own disk: ~/Library/Application Support/Safe Finder/tags.json, keyed by full path.
  Those files aren't on the iPhone; their tags travel with them when Safe Finder moves or copies
  them onto a drive (`TagStore.carry`).

How the two stay in step
  The drive is plugged into one device at a time, so each side simply works on the file while it has
  the drive. Safe Finder edits the drive's file directly — while the drive is on the Mac it is the copy
  of record. The iPhone app keeps its own copy and, whenever the drive is connected, merges the two
  three ways against what they agreed on last time: a tag added or removed on either side wins over one
  left alone, and additions from both sides are kept (`Library.syncDriveTags`). The file's `id` tells
  the app when the file is new or was started afresh (no shared history) — then nothing is taken as
  removed, the two are just combined, so a lost or damaged file can never wipe tags.

Format (JSON, UTF-8):
  {"format": "Photo Browser shared tags", "version": 1, "id": "<uuid>", "updated": <epoch seconds>,
   "by": "Safe Finder" | "Photo Browser", "files": {"<path in the drive>": ["tag", …], …}}
A tag is stored as the app stores it (Library.normalizedTag: trimmed, no leading "#", inner spaces
collapsed) and compared ignoring case. Paths are NFC. Hidden items (any part starting with ".") are
never in it.

Writing: on APFS through a temp file and a rename (atomic); on the exFAT SSD in place — the Mac tools
never rename or fsync on exFAT (CLAUDE.md #12). A torn file reads as damaged, is started afresh (a new
`id`) on the next change, and the app's merge fills it back in. Before the first change of a day the
previous file is kept in ~/Library/Application Support/Safe Finder/Tag Backups/ (the last 14).

Tags that travel with the file
  The tables are keyed by path, so on their own a file moved or copied by anything else — Finder, the
  Files app, `cp` — would leave its tags behind. So each file also *carries* its tags, in a private
  extended attribute, `com.photobrowser.tags` (JSON {"path": key, "tags": [...]}: where the file was, and
  what it carried, when Safe Finder or the app last wrote it). Never on exFAT, where macOS would scatter
  `._` files. Finder, the Files app, cp/mv and ditto keep it through a copy or move; Finder doesn't show
  it, and Finder's own tags are left entirely alone — they are not Photo Browser tags. (Cloud folders such
  as iCloud Drive may drop a private attribute; the tags then stay behind, as they would without it.)
  Every change writes it. When a folder is looked at (`read_folder` + `apply_carried`), each file is
  checked against the tables: a marker naming another path means the file arrived from elsewhere — its
  tags are adopted here, and if the old path is gone (a move, not a copy) its old entry is dropped; a
  marker for this very path on a file the tables have nothing for means it came back (Put Back from the
  Trash, which dropped its tags) — they're restored; otherwise the tables are the record and the marker
  is brought in line with them (written for a tagged file that has none, changed with every edit — so a
  removal clears it at once). The app does the same for files that turn
  up in its index (`SharedTags.adoptCarried`).
  For a few hours on Oct 26, 2026 the tags were also written as Finder tags. Those are taken off again
  wherever they are exactly what was written (the marker's tags, none coloured — `ours_in_finder`);
  Finder tags anyone else put on are never touched.

No Qt here: Safe Finder drives it from the UI thread; it's also usable from scripts.
"""

from __future__ import annotations

import ctypes
import ctypes.util
import json
import os
import plistlib
import re
import shutil
import sys
import time
import unicodedata
import uuid
from pathlib import Path
from typing import Callable, Iterable

import safe_transfer as engine
import spare_folders

FORMAT = "Photo Browser shared tags"
VERSION = 1
FOLDER = ".Photo Browser Metadata"
FILE_NAME = "shared-tags.json"
SIDECARS = {"gallery.json", "pornstar.json", "search.json"}     # gallery sidecars the app hides — never tagged
_RECHECK = 2.0                                                    # seconds between "did the file change?" checks
MARKER = "com.photobrowser.tags"                                  # {"path": key when written, "tags": [...]}
FINDER_TAGS = "com.apple.metadata:_kMDItemUserTags"              # read only to take off what an earlier build wrote
BACKUPS_KEPT = 14


def normalized(raw: str) -> str:
    """A tag as stored — the app's `Library.normalizedTag`: trimmed, no leading "#", inner whitespace
    collapsed to single spaces."""
    t = raw.strip()
    while t.startswith("#"):
        t = t[1:]
    return " ".join(t.split())


def fold(tag: str) -> str:
    """Case-blind identity of a tag ("Beach" and "beach" are one tag, shown as first written)."""
    return tag.casefold()


def split_tags(text: str) -> list[str]:
    """The tags typed into one field — commas or new lines separate them."""
    out: list[str] = []
    seen: set[str] = set()
    for part in re.split(r"[,\n]", text):
        t = normalized(part)
        if t and fold(t) not in seen:
            seen.add(fold(t))
            out.append(t)
    return out


def clean(tags: Iterable) -> list[str]:
    """Normalized, empty ones dropped, each once whatever its case — in the order given."""
    out: list[str] = []
    seen: set[str] = set()
    for raw in tags:
        if not isinstance(raw, str):
            continue
        t = normalized(raw)
        if t and fold(t) not in seen:
            seen.add(fold(t))
            out.append(t)
    return out


def taggable(path: str) -> bool:
    """A file Safe Finder tags: not hidden, not a gallery sidecar."""
    name = os.path.basename(path)
    return bool(name) and not name.startswith(".") and name not in SIDECARS


def _nfc(s: str) -> str:
    return unicodedata.normalize("NFC", s)


# ---------------------------------------------------------------------------- extended attributes
# macOS has no os.getxattr — libc through ctypes (path, name, value, size, position, options). On Linux
# (the tests) the user namespace stands in.

if sys.platform == "darwin":
    _libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
    _libc.getxattr.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t,
                               ctypes.c_uint32, ctypes.c_int]
    _libc.getxattr.restype = ctypes.c_ssize_t
    _libc.setxattr.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t,
                               ctypes.c_uint32, ctypes.c_int]
    _libc.setxattr.restype = ctypes.c_int
    _libc.removexattr.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_int]
    _libc.removexattr.restype = ctypes.c_int
    _NOFOLLOW, _ENOATTR = 0x0001, 93

    def xattr_get(path: str, name: str) -> bytes | None:
        p, n = os.fsencode(path), name.encode()
        size = _libc.getxattr(p, n, None, 0, 0, _NOFOLLOW)
        if size < 0:
            return None
        buf = ctypes.create_string_buffer(max(size, 1))
        size = _libc.getxattr(p, n, buf, size, 0, _NOFOLLOW)
        return buf.raw[:size] if size >= 0 else None

    def xattr_set(path: str, name: str, value: bytes) -> None:
        if _libc.setxattr(os.fsencode(path), name.encode(), value, len(value), 0, _NOFOLLOW) != 0:
            e = ctypes.get_errno()
            raise OSError(e, os.strerror(e), path)

    def xattr_remove(path: str, name: str) -> None:
        if _libc.removexattr(os.fsencode(path), name.encode(), _NOFOLLOW) != 0:
            e = ctypes.get_errno()
            if e != _ENOATTR:
                raise OSError(e, os.strerror(e), path)
else:
    def xattr_get(path: str, name: str) -> bytes | None:
        try:
            return os.getxattr(path, "user." + name, follow_symlinks=False)
        except OSError:
            return None

    def xattr_set(path: str, name: str, value: bytes) -> None:
        os.setxattr(path, "user." + name, value, follow_symlinks=False)

    def xattr_remove(path: str, name: str) -> None:
        try:
            os.removexattr(path, "user." + name, follow_symlinks=False)
        except OSError as e:
            if e.errno not in (61, 95):                   # ENODATA, EOPNOTSUPP
                raise


def finder_names(raw: list[str]) -> list[str]:
    """Finder's "Name\nColour" entries → the names."""
    return clean(entry.split("\n", 1)[0] for entry in raw if isinstance(entry, str))


def ours_in_finder(finder: list[str] | None, marker: dict | None) -> bool:
    """Finder tags an earlier build wrote: exactly the marker's tags, none of them coloured."""
    return bool(finder) and marker is not None and finder_names(finder) == clean(marker["tags"]) \
        and all(e.endswith("\n0") for e in finder)


def read_carried(path: str) -> tuple[list[str] | None, dict | None]:
    """What a file carries: Finder's tag entries as stored ("Name\nColour"; None when it has none — read
    only to take off what an earlier build wrote) and the marker (None when absent or unreadable).
    Blocking — call off the UI thread for many files."""
    raw = xattr_get(path, FINDER_TAGS)
    finder = None
    if raw:
        try:
            value = plistlib.loads(raw)
            finder = [x for x in value if isinstance(x, str)] if isinstance(value, list) else None
        except Exception:  # noqa: BLE001 — a malformed attribute counts as none
            finder = None
    marker = None
    data = xattr_get(path, MARKER)
    if data:
        try:
            m = json.loads(data.decode("utf-8"))
            if isinstance(m, dict) and isinstance(m.get("path"), str) and isinstance(m.get("tags"), list):
                marker = m
        except (ValueError, UnicodeDecodeError):
            marker = None
    return finder, marker


def write_carried(path: str, key: str, tags: list[str]) -> None:
    """Puts `tags` on the file (the marker, at `key`), or takes it off when there are none. Raises OSError."""
    if not tags:
        xattr_remove(path, MARKER)
        return
    xattr_set(path, MARKER, json.dumps({"path": key, "tags": tags}, ensure_ascii=False).encode("utf-8"))


class TagFile:
    """One set of tags on disk. A drive's (`base` = the drive): keys are paths inside `base`. The Mac's
    own (`base` None): keys are full paths."""

    def __init__(self, file: Path, base: Path | None) -> None:
        self.file = file
        self.base = base
        self.files: dict[str, list[str]] = {}      # key → tags
        self.id = ""
        self.damaged = False                       # it was there but couldn't be read (started afresh on save)
        self._stamp: tuple[int, int] | None = None  # (mtime_ns, size) of what was read
        self._checked = 0.0

    # -- keys
    def key(self, path: str) -> str | None:
        """The key for `path`, or None when it isn't one this file holds (outside the drive, or hidden)."""
        p = _nfc(os.path.abspath(path))
        if self.base is None:
            return p
        base = _nfc(str(self.base)).rstrip("/")
        if not p.startswith(base + "/"):
            return None
        rel = p[len(base) + 1:]
        if not rel or any(part.startswith(".") for part in rel.split("/")):
            return None
        return rel

    def path(self, key: str) -> str:
        return key if self.base is None else os.path.join(str(self.base), key)

    def keys_under(self, path: str) -> list[str]:
        """`path`'s own key and, for a folder, the keys of everything tagged inside it."""
        k = self.key(path)
        if k is None:
            return []
        prefix = k.rstrip("/") + "/"
        return [x for x in self.files if x == k or x.startswith(prefix)]

    # -- reading
    def refresh(self, force: bool = False) -> None:
        """Re-read the file if it changed on disk since it was last read — checked at most every couple
        of seconds unless `force` (before a change, so nothing written elsewhere is lost)."""
        now = time.monotonic()
        if not force and now - self._checked < _RECHECK:
            return
        self._checked = now
        try:
            st = os.stat(self.file)
        except OSError:
            if self._stamp is not None or self.files:
                self.files, self.id, self.damaged = {}, "", False
            self._stamp = None
            return
        stamp = (st.st_mtime_ns, st.st_size)
        if stamp == self._stamp:
            return
        self._stamp = stamp
        try:
            with open(self.file, encoding="utf-8") as f:
                doc = json.load(f)
            raw = doc.get("files") if isinstance(doc, dict) else None
            if not isinstance(raw, dict):
                raise ValueError("no “files” table")
        except (OSError, ValueError, UnicodeDecodeError):
            self.files, self.id, self.damaged = {}, "", True
            return
        files: dict[str, list[str]] = {}
        for k, v in raw.items():
            if not isinstance(k, str) or not isinstance(v, list):
                continue
            key = _nfc(k)
            tags = clean((files.get(key) or []) + v)
            if tags:
                files[key] = tags
        self.files, self.id, self.damaged = files, str(doc.get("id") or ""), False

    # -- writing
    def back_up(self) -> None:
        """Before the first change of a day, keep the current file in Safe Finder's Tag Backups (the last
        BACKUPS_KEPT per table) — a copy off the drive of what the app and Safe Finder agreed on."""
        if not self.file.is_file():
            return
        name = "This Mac" if self.base is None else (self.base.name or "drive")
        folder = backups_dir() / name
        today = time.strftime("%Y-%m-%d")
        try:
            folder.mkdir(parents=True, exist_ok=True)
            if any(n.startswith(f"tags {today}") for n in os.listdir(folder)):
                return
            shutil.copy2(self.file, folder / f"tags {today} {time.strftime('%H%M%S')}.json")
            old = sorted(n for n in os.listdir(folder) if n.startswith("tags ") and n.endswith(".json"))
            for n in old[:-BACKUPS_KEPT]:
                os.remove(folder / n)
        except OSError:
            pass                                       # a backup is a nicety; never stop a change for it

    def save(self) -> None:
        """Write the whole table back. Raises OSError (drive gone, read-only, full)."""
        self.back_up()
        if not self.id:
            self.id = str(uuid.uuid4()).upper()
        doc = {"format": FORMAT, "version": VERSION, "id": self.id, "updated": round(time.time(), 3),
               "by": "Safe Finder", "files": {k: self.files[k] for k in sorted(self.files) if self.files[k]}}
        data = json.dumps(doc, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        folder = self.file.parent
        if not folder.is_dir():
            if self.base is not None:
                spare_folders.make_dir(str(folder))        # a new folder on the drive: from a spare where it matters
            else:
                folder.mkdir(parents=True, exist_ok=True)
        if self.base is not None and spare_folders.on_exfat(str(folder)):
            with open(self.file, "wb") as f:               # exFAT: in place — no rename, no fsync (CLAUDE.md #12)
                f.write(data)
        else:
            tmp = folder / f".{self.file.name}.saving"
            with open(tmp, "wb") as f:
                f.write(data)
                f.flush()
                os.fsync(f.fileno())
            os.replace(tmp, self.file)
        st = os.stat(self.file)
        self._stamp = (st.st_mtime_ns, st.st_size)
        self._checked = time.monotonic()
        self.damaged = False


def default_store() -> "TagStore":
    """A store for scripts without Safe Finder's window (the AirDrop packer): drives are what's mounted
    under /Volumes (or SAFE_FINDER_VOLUMES)."""
    volumes_dir = Path(os.environ.get("SAFE_FINDER_VOLUMES", "/Volumes"))

    def volumes() -> list[Path]:
        try:
            return [volumes_dir / n for n in sorted(os.listdir(volumes_dir))
                    if not n.startswith(".") and os.path.realpath(volumes_dir / n) != "/"]
        except OSError:
            return []

    def is_drive(path: str) -> bool:
        root = str(engine.volume_root(Path(path)))
        return root != "/" and root.startswith(str(volumes_dir) + os.sep)
    return TagStore(is_drive=is_drive, volumes=volumes)


def tags_for_archive(paths: Iterable[str], store: "TagStore | None" = None) -> dict[str, list[str]]:
    """The tags of files about to leave in an archive (AirDrop): the tables' and those the file carries,
    together. Only files that have any."""
    store = store or default_store()
    out: dict[str, list[str]] = {}
    for p in paths:
        marker = read_carried(p)[1] if store.carries(p) else None
        tags = clean(store.tags(p) + (marker["tags"] if marker else []))
        if tags:
            out[p] = tags
    return out


def mac_store_file() -> Path:
    return Path.home() / "Library" / "Application Support" / "Safe Finder" / "tags.json"


def backups_dir() -> Path:
    return Path.home() / "Library" / "Application Support" / "Safe Finder" / "Tag Backups"


class TagStore:
    """Every tag Safe Finder knows: the Mac's own table and each connected drive's. Paths in, paths out —
    which table a file belongs to is worked out here (and remembered per folder)."""

    def __init__(self, is_drive: Callable[[str], bool], volumes: Callable[[], list[Path]],
                 mac_file: Path | None = None) -> None:
        self.is_drive = is_drive                   # is this path on an external drive (vs. the Mac's own disk)
        self.volumes = volumes                     # the drives connected now
        self.mac = TagFile(mac_file or mac_store_file(), None)
        self.version = 0                           # bumped on every change: views re-read
        self._tables: dict[str, TagFile] = {}      # tag-file path → its table
        self._folder_table: dict[str, TagFile] = {}  # folder → the table its files belong to

    def forget_volumes(self) -> None:
        """Drives came or went: work out again which table each folder belongs to."""
        self._folder_table.clear()
        live = {str(Path(v) / FOLDER / FILE_NAME) for v in self.volumes()}
        for k in list(self._tables):
            if k not in live and not os.path.isdir(os.path.dirname(k)):
                del self._tables[k]

    def _table_at(self, base: Path) -> TagFile:
        f = base / FOLDER / FILE_NAME
        t = self._tables.get(str(f))
        if t is None:
            t = self._tables[str(f)] = TagFile(f, base)
        return t

    def table_for(self, path: str) -> TagFile:
        folder = os.path.dirname(os.path.abspath(path))
        t = self._folder_table.get(folder)
        if t is not None:
            return t
        if not self.is_drive(path):
            t = self.mac
        else:
            root = Path(engine.volume_root(Path(folder)))
            base, d = root, Path(folder)
            while True:                            # the nearest folder holding the app's metadata folder
                if (d / FOLDER).is_dir():
                    base = d
                    break
                if d == root or d.parent == d:
                    break
                d = d.parent
            t = self._table_at(base)
        self._folder_table[folder] = t
        return t

    def tables(self) -> list[TagFile]:
        """The Mac's table and every connected drive's (each refreshed if it changed)."""
        out = [self.mac]
        for v in self.volumes():
            out.append(self._table_at(Path(v)))
        for t in list(self._tables.values()):
            if t not in out and t.file.parent.parent.is_dir():
                out.append(t)
        for t in out:
            t.refresh()
        return out

    # -- reading
    def tags(self, path: str, fresh: bool = True) -> list[str]:
        """`path`'s tags. `fresh=False` skips the file check (for painting tiles)."""
        t = self.table_for(path)
        if fresh:
            t.refresh()
        k = t.key(path)
        return list(t.files.get(k, ())) if k else []

    def counts(self) -> list[tuple[str, int]]:
        """Every tag on the Mac and the connected drives with how many files carry it, most used first."""
        counts: dict[str, int] = {}
        shown: dict[str, str] = {}
        for t in self.tables():
            for tags in t.files.values():
                for tag in tags:
                    f = fold(tag)
                    counts[f] = counts.get(f, 0) + 1
                    shown.setdefault(f, tag)
        return sorted(((shown[f], n) for f, n in counts.items()), key=lambda x: (-x[1], x[0].casefold()))

    def names(self) -> list[str]:
        """Every tag, A to Z — for suggestions."""
        return sorted((name for name, _n in self.counts()), key=str.casefold)

    def files_with(self, tag: str) -> list[str]:
        """Full paths of the files carrying `tag` (they may have gone missing since — check)."""
        f = fold(normalized(tag))
        out: list[str] = []
        for t in self.tables():
            out.extend(t.path(k) for k, tags in t.files.items() if any(fold(x) == f for x in tags))
        return out

    def damaged(self) -> list[Path]:
        """Drives whose tag file is there but can't be read."""
        return [t.file for t in self.tables() if t.damaged]

    # -- changing (each saves the tables it touched; OSError if a drive can't be written)
    def carries(self, path: str) -> bool:
        """Whether files here carry their tags themselves (anywhere but exFAT/FAT)."""
        return not spare_folders.on_exfat(path)

    def _carry_out(self, writes: list[tuple[str, str, list[str]]]) -> None:
        for path, key, tags in writes:
            if self.carries(path):
                try:
                    write_carried(path, key, tags)
                except OSError:
                    pass                               # best effort: the tables still have them

    def _edit(self, paths: Iterable[str], change: Callable[[list[str]], list[str]]) -> int:
        touched: dict[int, TagFile] = {}
        dirty: dict[int, TagFile] = {}
        writes: list[tuple[str, str, list[str]]] = []
        changed = 0
        for p in paths:
            t = self.table_for(p)
            if id(t) not in touched:
                t.refresh(force=True)
                touched[id(t)] = t
            k = t.key(p)
            if k is None:
                continue
            before = t.files.get(k, [])
            after = clean(change(list(before)))
            if after == before:
                continue
            if after:
                t.files[k] = after
            else:
                t.files.pop(k, None)
            dirty[id(t)] = t
            writes.append((p, k, after))
            changed += 1
        for t in dirty.values():
            t.save()
        if dirty:
            self.version += 1
        self._carry_out(writes)
        return changed

    def add(self, paths: Iterable[str], tags: list[str]) -> int:
        """Adds each tag to each file (once, whatever its case). Returns how many files gained any."""
        tags = clean(tags)
        if not tags:
            return 0

        def change(cur: list[str]) -> list[str]:
            have = {fold(x) for x in cur}
            return cur + [x for x in tags if fold(x) not in have]
        return self._edit((p for p in paths if taggable(p)), change)

    def remove(self, paths: Iterable[str], tags: list[str]) -> int:
        """Takes the tags off the files. Returns how many files lost any."""
        gone = {fold(normalized(x)) for x in tags}
        return self._edit(paths, lambda cur: [x for x in cur if fold(x) not in gone])

    def clear(self, paths: Iterable[str]) -> int:
        """Every tag off the files."""
        return self._edit(paths, lambda cur: [])

    def rename(self, old: str, new: str) -> int:
        """Renames a tag on every file that carries it (Mac and connected drives); merging into an
        existing tag when the new name is already one. Returns how many files changed."""
        new = normalized(new)
        if not new:
            return 0
        f = fold(normalized(old))

        def change(cur: list[str]) -> list[str]:
            return [new if fold(x) == f else x for x in cur]
        return self._edit(self.files_with(old), change)

    def carry(self, pairs: Iterable[tuple[str, str]]) -> int:
        """After a copy or move: each copy gets its original's tags (added to any it already has)."""
        by_tags: dict[tuple[str, ...], list[str]] = {}
        for src, dst in pairs:
            tags = self.tags(src)
            if tags:
                by_tags.setdefault(tuple(tags), []).append(dst)
        return sum(self.add(dsts, list(tags)) for tags, dsts in by_tags.items())

    def read_folder(self, paths: Iterable[str]) -> list[tuple[str, list[str] | None, dict | None]]:
        """What each file carries — for `apply_carried`. Only reads; safe on a worker thread. Files on
        exFAT, hidden ones and sidecars are skipped."""
        out = []
        for p in paths:
            if taggable(p) and os.path.isfile(p) and self.carries(p):
                finder, marker = read_carried(p)
                out.append((p, finder, marker))
        return out

    def apply_carried(self, found: list[tuple[str, list[str] | None, dict | None]]) -> int:
        """Squares what files carry with the tables (see the module doc) — on the UI thread, with what
        `read_folder` read. Returns how many files' tags changed in the tables."""
        dirty: dict[int, TagFile] = {}
        writes: list[tuple[str, str, list[str]]] = []
        changed = 0
        for path, finder, marker in found:
            t = self.table_for(path)
            k = t.key(path)
            if k is None:
                continue
            if id(t) not in dirty:
                t.refresh()
            have = t.files.get(k, [])
            m_path = _nfc(marker["path"]) if marker else None
            m_tags = clean(marker["tags"]) if marker else []
            if marker is not None and (m_path != k or not have):
                new = clean(have + m_tags)                 # arrived from elsewhere — or back (Put Back)
                old = self.mac if m_path.startswith("/") else t
                if m_path != k and m_path in old.files and not os.path.lexists(old.path(m_path)):
                    old.files.pop(m_path, None)            # moved, not copied: its old place is gone
                    dirty[id(old)] = old
            else:
                new = have                                 # the tables are the record
            if new != have:
                if new:
                    t.files[k] = new
                else:
                    t.files.pop(k, None)
                dirty[id(t)] = t
                changed += 1
            if ((m_path, m_tags) if marker else None) != ((k, new) if new else None):
                writes.append((path, k, new))
            if ours_in_finder(finder, marker):
                try:
                    xattr_remove(path, FINDER_TAGS)
                except OSError:
                    pass
        for t in dirty.values():
            try:
                t.save()
            except OSError:
                pass
        if dirty:
            self.version += 1
        for path, key, tags in writes:
            try:
                write_carried(path, key, tags)
            except OSError:
                pass
        return changed

    def forget(self, paths: Iterable[str]) -> int:
        """Items that are gone (to the Trash, or moved away): their tags — and, for a folder, the tags of
        everything inside it — are dropped."""
        dirty: dict[int, TagFile] = {}
        n = 0
        for p in paths:
            t = self.table_for(p)
            t.refresh(force=True)
            keys = t.keys_under(p)
            for k in keys:
                t.files.pop(k, None)
                n += 1
            if keys:
                dirty[id(t)] = t
        for t in dirty.values():
            t.save()
        if dirty:
            self.version += 1
        return n
