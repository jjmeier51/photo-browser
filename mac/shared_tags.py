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
`id`) on the next change, and the app's merge fills it back in.

No Qt here: Safe Finder drives it from the UI thread; it's also usable from scripts.
"""

from __future__ import annotations

import json
import os
import re
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
    def save(self) -> None:
        """Write the whole table back. Raises OSError (drive gone, read-only, full)."""
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


def mac_store_file() -> Path:
    return Path.home() / "Library" / "Application Support" / "Safe Finder" / "tags.json"


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
    def _edit(self, paths: Iterable[str], change: Callable[[list[str]], list[str]]) -> int:
        touched: dict[int, TagFile] = {}
        dirty: dict[int, TagFile] = {}
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
            changed += 1
        for t in dirty.values():
            t.save()
        if dirty:
            self.version += 1
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
