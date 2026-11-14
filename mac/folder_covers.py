"""Folder covers — the picture a folder shows in place of a plain folder icon — shared with the iPhone app.

Where a cover lives:
- **On the drive**, for a folder on a drive the iPhone app has opened (one with `.Photo Browser Metadata`):
  the picture in `<drive>/.Photo Browser Metadata/covers/<name>` (the folder the app's backups already keep
  its covers in — names are random, so the two never collide) and the choice in
  `<drive>/.Photo Browser Metadata/folder-covers.json`:

      {"format": "photobrowser-folder-covers", "version": 1,
       "covers": {"<folder, drive-relative>": {"file": "<name in covers/>", "at": stamp}}}

  The iPhone app reads and writes the same file (`FolderCovers.swift`), so a cover chosen here is the folder's
  cover there, and the other way round.
- **On this Mac**, for any other folder: the picture in `~/Library/Application Support/Safe Finder/Folder Covers`
  and the choice in Safe Finder's settings, by full path.

`at` is when the cover was chosen (Unix time). **The later choice wins** when the two apps disagree (`merged`).
Two special cases: `"file": ""` means the cover was *removed* at that time (so the other app doesn't put its
older one back), and `"at": 0` marks a cover nobody chose — the iPhone app picks a random photo for every
folder that has none — which any chosen cover replaces.

Until the iPhone app has written that file, its covers are still found: every backup holds them
(`metadata.json` → `folderCovers`), and `cover` falls back to that.

A folder with no cover of either kind shows the first photo or video in it (`first_media`), looking into its
subfolders when it holds only folders — as the iPhone's does.

Renames: `renamed(pairs)` moves a folder's entry, and those of the folders inside it (`rename_tools.apply`).
"""
from __future__ import annotations

import json
import os
import re
import threading
import time
import unicodedata
import uuid
from pathlib import Path

METADATA = ".Photo Browser Metadata"
FILE_NAME = "folder-covers.json"
COVERS_DIR = "covers"
BACKUP_NAME = "metadata.json"
FORMAT = "photobrowser-folder-covers"
SETTINGS_KEY = "folderCovers/local"
COVER_PX = 800                       # long side of a cover made here (the iPhone's are 480)
RECHECK = 3.0                        # seconds between looks at the drive's file

Entry = tuple[str, float]            # (file name in covers/ — "" = removed, when)


def merged(a: dict[str, Entry], b: dict[str, Entry]) -> dict[str, Entry]:
    """For each folder, the later choice. On a tie `a`'s stands."""
    out = dict(a)
    for k, v in b.items():
        if k not in out or v[1] > out[k][1]:
            out[k] = v
    return out


def drive_base(path: str) -> str | None:
    """The folder above (or at) `path` that holds the app's metadata folder — the root the iPhone app browses."""
    p = os.path.abspath(path)
    for _ in range(40):
        if os.path.isdir(os.path.join(p, METADATA)):
            return p
        parent = os.path.dirname(p)
        if parent == p:
            return None
        p = parent
    return None


def _rel(base: str, folder: str) -> str:
    rel = os.path.relpath(os.path.abspath(folder), base)
    return "" if rel == "." else unicodedata.normalize("NFC", rel)


def local_dir() -> Path:
    return Path.home() / "Library" / "Application Support" / "Safe Finder" / "Folder Covers"


_SAFE_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,120}$")


def _parse(raw) -> dict[str, Entry]:
    out: dict[str, Entry] = {}
    if not isinstance(raw, dict):
        return out
    for k, v in raw.items():
        if not isinstance(v, dict):
            continue
        name, at = v.get("file"), v.get("at")
        if not isinstance(name, str) or isinstance(at, bool) or not isinstance(at, (int, float)):
            continue
        if name and not _SAFE_NAME.match(name):          # a name, never a path out of covers/
            continue
        out[str(k)] = (name, float(at))
    return out


class FolderCovers:
    """`settings`: a QSettings (or anything with value/setValue) for folders that aren't on such a drive."""

    def __init__(self, settings=None) -> None:
        self.settings = settings
        self._lock = threading.RLock()
        self._files: dict[str, tuple[float, tuple | None, dict[str, Entry]]] = {}     # base → (looked, stamp, entries)
        self._backups: dict[str, tuple[tuple | None, dict[str, str]]] = {}            # base → (stamp, rel → name)
        self._bases: dict[str, tuple[float, str | None]] = {}
        self._answers: dict[str, tuple[float, tuple[str, float] | None, bool]] = {}   # folder → (when, cover, removed)
        self._local_cache: dict[str, Entry] | None = None

    # -- where
    def _base(self, folder: str) -> str | None:
        hit = self._bases.get(folder)
        now = time.monotonic()
        if hit and now - hit[0] < 30:
            return hit[1]
        base = drive_base(folder)
        if len(self._bases) > 4000:
            self._bases.clear()
        self._bases[folder] = (now, base)
        return base

    @staticmethod
    def _file(base: str) -> Path:
        return Path(base) / METADATA / FILE_NAME

    @staticmethod
    def covers_dir(base: str) -> Path:
        return Path(base) / METADATA / COVERS_DIR

    @staticmethod
    def _stamp(path: Path) -> tuple | None:
        try:
            st = os.stat(path)
            return st.st_mtime_ns, st.st_size
        except OSError:
            return None

    def _read(self, base: str, fresh: bool = False) -> dict[str, Entry]:
        """The drive's choices — looked at again at most every RECHECK seconds, read again only when changed."""
        now = time.monotonic()
        hit = self._files.get(base)
        if hit and not fresh and now - hit[0] < RECHECK:
            return hit[2]
        file = self._file(base)
        stamp = self._stamp(file)
        if hit and hit[1] == stamp:
            self._files[base] = (now, stamp, hit[2])
            return hit[2]
        entries: dict[str, Entry] = {}
        if stamp is not None:
            try:
                doc = json.loads(file.read_bytes().decode("utf-8"))
                if isinstance(doc, dict) and doc.get("format") == FORMAT:
                    entries = _parse(doc.get("covers"))
            except (OSError, ValueError):
                entries = {}
        self._files[base] = (now, stamp, entries)
        self._answers.clear()
        return entries

    def _backup(self, base: str) -> dict[str, str]:
        """The iPhone app's covers as of its last backup: folder (drive-relative) → file name in covers/."""
        file = Path(base) / METADATA / BACKUP_NAME
        stamp = self._stamp(file)
        hit = self._backups.get(base)
        if hit and hit[0] == stamp:
            return hit[1]
        found: dict[str, str] = {}
        if stamp is not None:
            try:
                doc = json.loads(file.read_bytes().decode("utf-8"))
                raw = doc.get("folderCovers") if isinstance(doc, dict) else None
                if isinstance(raw, dict):
                    found = {unicodedata.normalize("NFC", str(k)): v for k, v in raw.items()
                             if isinstance(v, str) and _SAFE_NAME.match(v)}
            except (OSError, ValueError):
                found = {}
        self._backups[base] = (stamp, found)
        self._answers.clear()
        return found

    def _write(self, base: str, entries: dict[str, Entry]) -> None:
        import spare_folders
        file = self._file(base)
        doc = {"format": FORMAT, "version": 1, "updated": round(time.time(), 3), "by": "Safe Finder",
               "covers": {k: {"file": entries[k][0], "at": entries[k][1]} for k in sorted(entries)}}
        data = json.dumps(doc, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        _put(file, data, spare_folders.on_exfat(str(file.parent)))
        self._files[base] = (time.monotonic(), self._stamp(file), dict(entries))
        self._answers.clear()

    def _local(self) -> dict[str, Entry]:
        if self._local_cache is None:
            raw = {}
            if self.settings is not None:
                try:
                    raw = json.loads(str(self.settings.value(SETTINGS_KEY, "") or "{}"))
                except ValueError:
                    raw = {}
            self._local_cache = _parse(raw)
        return self._local_cache

    def _save_local(self, entries: dict[str, Entry]) -> None:
        self._local_cache = dict(entries)
        self._answers.clear()
        if self.settings is not None:
            self.settings.setValue(SETTINGS_KEY, json.dumps({k: {"file": v[0], "at": v[1]} for k, v in entries.items()}))

    # -- asking
    def _look(self, folder: str) -> tuple[tuple[str, float] | None, bool]:
        """((picture path, its modified time) or None, whether a cover was removed on purpose)."""
        folder = os.path.abspath(folder)
        now = time.monotonic()
        hit = self._answers.get(folder)
        if hit and now - hit[0] < RECHECK:
            return hit[1], hit[2]
        with self._lock:
            base = self._base(folder)
            if base is None:
                entry, where = self._local().get(folder), local_dir()
            else:
                rel = _rel(base, folder)
                entry, where = self._read(base).get(rel), self.covers_dir(base)
                if entry is None:
                    name = self._backup(base).get(rel)
                    entry = (name, 0.0) if name else None
            answer: tuple[str, float] | None = None
            removed = bool(entry) and not entry[0]
            if entry and entry[0]:
                path = os.path.join(where, entry[0])
                try:
                    answer = (path, os.stat(path).st_mtime)
                except OSError:
                    answer = None
            if len(self._answers) > 20000:
                self._answers.clear()
            self._answers[folder] = (now, answer, removed)
            return answer, removed

    def cover(self, folder: str) -> tuple[str, float] | None:
        """The folder's cover — (picture path, its modified time) — or None when it has none."""
        return self._look(folder)[0]

    def chosen(self, folder: str) -> bool:
        """Whether the folder has a cover someone picked (here or on the iPhone), not just a picture shown for it."""
        folder = os.path.abspath(folder)
        with self._lock:
            base = self._base(folder)
            entry = self._local().get(folder) if base is None else self._read(base).get(_rel(base, folder))
        return bool(entry and entry[0] and entry[1] > 0) and self.cover(folder) is not None

    # -- changing
    def set(self, folder: str, picture) -> str:
        """Makes `picture` (a Pillow image) the folder's cover. Returns the cover file's path."""
        import spare_folders
        folder = os.path.abspath(folder)
        name = uuid.uuid4().hex.upper() + ".jpg"
        with self._lock:
            base = self._base(folder)
            where = local_dir() if base is None else self.covers_dir(base)
            if not where.is_dir():
                if base is None:
                    where.mkdir(parents=True, exist_ok=True)
                else:
                    spare_folders.make_dir(str(where))     # on the drive: from a spare where the drive needs that
            dest = where / name
            _put(dest, _jpeg(picture), base is not None and spare_folders.on_exfat(str(where)))
            now = time.time()
            if base is None:
                entries = dict(self._local())
                old = entries.get(folder)
                entries[folder] = (name, now)
                self._save_local(entries)
                if old and old[0]:                         # this Mac's own store: nothing else points at the old one
                    try:
                        os.remove(where / old[0])
                    except OSError:
                        pass
            else:
                entries = dict(self._read(base, fresh=True))
                entries[_rel(base, folder)] = (name, now)
                self._write(base, entries)                 # the old picture stays: the iPhone's backup may name it
        return str(dest)

    def clear(self, folder: str) -> None:
        """The folder has no cover (and the iPhone app is told so, rather than putting its own back)."""
        folder = os.path.abspath(folder)
        with self._lock:
            base = self._base(folder)
            now = time.time()
            if base is None:
                entries = dict(self._local())
                old = entries.pop(folder, None)
                self._save_local(entries)
                if old and old[0]:
                    try:
                        os.remove(local_dir() / old[0])
                    except OSError:
                        pass
            else:
                entries = dict(self._read(base, fresh=True))
                entries[_rel(base, folder)] = ("", now)
                self._write(base, entries)

    def renamed(self, pairs: list[tuple[str, str]]) -> None:
        """Folders renamed or moved (old path, new path): their covers, and those of the folders inside, follow."""
        with self._lock:
            by_base: dict[str | None, list[tuple[str, str]]] = {}
            for old, new in pairs:
                old, new = os.path.abspath(old), os.path.abspath(new)
                base = self._base(os.path.dirname(new)) or self._base(os.path.dirname(old))
                by_base.setdefault(base, []).append((old, new))
            for base, moves in by_base.items():
                if base is None:
                    entries, key = dict(self._local()), (lambda p: p)
                else:
                    entries, key = dict(self._read(base, fresh=True)), (lambda p, base=base: _rel(base, p))
                    for rel, name in self._backup(base).items():       # the iPhone's, not yet in the shared file
                        entries.setdefault(rel, (name, 0.0))
                changed = False
                for old, new in moves:
                    ko, kn = key(old), key(new)
                    for k in [k for k in entries if k == ko or k.startswith(ko + os.sep)]:
                        entries[kn + k[len(ko):]] = entries.pop(k)
                        changed = True
                if changed:
                    self._save_local(entries) if base is None else self._write(base, entries)
            self._bases.clear()
            self._answers.clear()


def _jpeg(picture) -> bytes:
    """`picture` (a Pillow image) as a cover: at most COVER_PX on its long side, sRGB, JPEG."""
    import io
    from PIL import Image
    im = picture
    if max(im.size) > COVER_PX:
        im = im.copy()
        im.thumbnail((COVER_PX, COVER_PX), Image.Resampling.LANCZOS)
    if im.mode in ("RGBA", "LA", "P"):
        rgba = im.convert("RGBA")
        flat = Image.new("RGB", rgba.size, (255, 255, 255))
        flat.paste(rgba, mask=rgba.getchannel("A"))
        im = flat
    elif im.mode != "RGB":
        im = im.convert("RGB")
    out = io.BytesIO()
    im.save(out, "JPEG", quality=90)
    return out.getvalue()


def _put(file: Path, data: bytes, exfat: bool) -> None:
    if exfat:
        with open(file, "wb") as f:                        # exFAT: in place — no rename, no fsync (CLAUDE.md #12)
            f.write(data)
        return
    tmp = file.parent / f".{file.name}.saving"
    with open(tmp, "wb") as f:
        f.write(data)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, file)


def picture_of(path: str):
    """The photo at `path` as a Pillow image ready to be a cover: upright, in the screen's colours."""
    from PIL import Image, ImageOps
    import thumb_color
    with Image.open(path) as im:
        im.draft("RGB", (COVER_PX * 2, COVER_PX * 2))
        im = ImageOps.exif_transpose(im)
        im.thumbnail((COVER_PX, COVER_PX), Image.Resampling.LANCZOS)
        return thumb_color.standard(im, path).copy()


def first_media(folder: str, kind_of, key=None, depth: int = 3, budget: int = 5000) -> str | None:
    """The first photo or video in `folder` by name (hidden items left out) — and when it holds only folders,
    the first one found in them, a few levels down. `budget` bounds how many entries are read in all."""
    key = key or (lambda name: name.lower())
    todo, seen = [(folder, 0)], 0
    while todo:
        here, level = todo.pop(0)
        best, subs = None, []
        try:
            with os.scandir(here) as it:
                for e in it:
                    seen += 1
                    if seen > budget:
                        break
                    if e.name.startswith("."):
                        continue
                    if kind_of(e.name) != "other":
                        if best is None or key(e.name) < key(best):
                            best = e.name
                    elif level < depth and best is None:
                        try:
                            if e.is_dir(follow_symlinks=False):
                                subs.append(e.name)
                        except OSError:
                            pass
        except OSError:
            continue
        if best is not None:
            return os.path.join(here, best)
        if seen > budget:
            return None
        subs.sort(key=key)
        todo += [(os.path.join(here, s), level + 1) for s in subs[:40]]
    return None


_default: FolderCovers | None = None


def default(settings=None) -> FolderCovers:
    global _default
    if _default is None:
        _default = FolderCovers(settings)
    elif settings is not None and _default.settings is None:
        _default.settings = settings
    return _default
