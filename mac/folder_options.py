"""Per-folder choices shared with the iPhone app — so far one: **Videos at the Top** (a folder's videos listed
before its photos and other files; folders still first).

Where a choice lives:
- **On the drive**, for a folder on a drive the iPhone app has opened (one with `.Photo Browser Metadata`):
  `<drive>/.Photo Browser Metadata/folder-options.json` — `{"videos_first": {"<folder, drive-relative>": stamp}}`.
  The iPhone app reads and writes the same file (`FolderOptions.swift`), so a folder set here is shown that way
  there, and the other way round.
- **In Safe Finder's settings**, for any other folder (on the Mac, or a drive the app has never opened), by its
  full path.

A stamp is when the choice was last made, as Unix time: **positive = on, negative = off**. Each app keeps what
it knows and, on reading the file, takes whichever stamp is later for each folder (`merged`) — so a choice
turned off on one side isn't turned back on by the other's older "on", without either needing to know what the
file said last time. A save re-reads the file and merges before writing.

Renames: `renamed(pairs)` moves a folder's entry (and those of the folders inside it) to its new name —
`rename_tools.apply` calls it; the iPhone app re-keys its own copy when it applies the rename journal.
"""
from __future__ import annotations

import json
import os
import time
import unicodedata
from pathlib import Path

METADATA = ".Photo Browser Metadata"
FILE_NAME = "folder-options.json"
FORMAT = "photobrowser-folder-options"
SETTINGS_KEY = "folderOptions/videosFirst"


def merged(a: dict[str, float], b: dict[str, float]) -> dict[str, float]:
    """For each folder, the later of the two stamps (by size, whichever its sign)."""
    out = dict(a)
    for k, v in b.items():
        if k not in out or abs(v) > abs(out[k]):
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


class FolderOptions:
    """`settings`: a QSettings (or anything with value/setValue) for folders that aren't on such a drive."""

    def __init__(self, settings=None) -> None:
        self.settings = settings
        self._files: dict[str, tuple[tuple[int, int] | None, dict[str, float]]] = {}     # base → (stamp of the file, entries)
        self._bases: dict[str, tuple[float, str | None]] = {}

    # -- where
    def _base(self, folder: str) -> str | None:
        hit = self._bases.get(folder)
        now = time.monotonic()
        if hit and now - hit[0] < 30:
            return hit[1]
        base = drive_base(folder)
        if len(self._bases) > 2000:
            self._bases.clear()
        self._bases[folder] = (now, base)
        return base

    @staticmethod
    def _path(base: str) -> Path:
        return Path(base) / METADATA / FILE_NAME

    def _read(self, base: str) -> dict[str, float]:
        """The drive's entries — read again only when the file has changed."""
        file = self._path(base)
        try:
            st = os.stat(file)
            stamp = (st.st_mtime_ns, st.st_size)
        except OSError:
            stamp = None
        hit = self._files.get(base)
        if hit and hit[0] == stamp:
            return hit[1]
        entries: dict[str, float] = {}
        if stamp is not None:
            try:
                doc = json.loads(file.read_bytes().decode("utf-8"))
                raw = doc.get("videos_first") if isinstance(doc, dict) and doc.get("format") == FORMAT else None
                if isinstance(raw, dict):
                    entries = {str(k): float(v) for k, v in raw.items() if isinstance(v, (int, float)) and not isinstance(v, bool)}
            except (OSError, ValueError):
                entries = {}
        self._files[base] = (stamp, entries)
        return entries

    def _write(self, base: str, entries: dict[str, float]) -> None:
        import spare_folders
        file = self._path(base)
        doc = {"format": FORMAT, "version": 1, "updated": round(time.time(), 3), "by": "Safe Finder",
               "videos_first": {k: entries[k] for k in sorted(entries)}}
        data = json.dumps(doc, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        if spare_folders.on_exfat(str(file.parent)):
            with open(file, "wb") as f:                # exFAT: in place — no rename, no fsync (CLAUDE.md #12)
                f.write(data)
        else:
            tmp = file.parent / f".{FILE_NAME}.saving"
            with open(tmp, "wb") as f:
                f.write(data)
                f.flush()
                os.fsync(f.fileno())
            os.replace(tmp, file)
        st = os.stat(file)
        self._files[base] = ((st.st_mtime_ns, st.st_size), dict(entries))

    def _local(self) -> dict[str, float]:
        if self.settings is None:
            return {}
        try:
            raw = json.loads(str(self.settings.value(SETTINGS_KEY, "") or "{}"))
            return {str(k): float(v) for k, v in raw.items() if isinstance(v, (int, float))} if isinstance(raw, dict) else {}
        except ValueError:
            return {}

    def _save_local(self, entries: dict[str, float]) -> None:
        if self.settings is not None:
            if len(entries) > 5000:                    # the oldest choices go first
                entries = dict(sorted(entries.items(), key=lambda kv: abs(kv[1]))[-4000:])
            self.settings.setValue(SETTINGS_KEY, json.dumps(entries))

    # -- the choice
    def videos_first(self, folder: str) -> bool:
        if not folder or not os.path.isabs(folder):
            return False
        base = self._base(folder)
        if base is not None:
            return self._read(base).get(_rel(base, folder), 0) > 0
        return self._local().get(os.path.abspath(folder), 0) > 0

    def set_videos_first(self, folder: str, on: bool) -> None:
        """Raises OSError when the drive's file can't be written (read-only, gone)."""
        stamp = time.time() if on else -time.time()
        base = self._base(folder)
        if base is None:
            entries = self._local()
            entries[os.path.abspath(folder)] = stamp
            self._save_local(entries)
            return
        self._files.pop(base, None)                    # what's on the drive now, not what was read a while ago
        entries = dict(self._read(base))
        entries[_rel(base, folder)] = stamp
        self._write(base, entries)

    def renamed(self, pairs) -> int:
        """Folders renamed where they are: their entries (and those of folders inside) follow. Best effort."""
        moved = 0
        local = None
        by_base: dict[str, list[tuple[str, str]]] = {}
        for old, new in pairs:
            base = self._base(os.path.dirname(new))
            if base is None:
                local = self._local() if local is None else local
                for k in [k for k in local if k == old or k.startswith(old.rstrip("/") + "/")]:
                    local[new + k[len(old):]] = local.pop(k)
                    moved += 1
            else:
                by_base.setdefault(base, []).append((_rel(base, old), _rel(base, new)))
        if local is not None and moved:
            self._save_local(local)
        for base, moves in by_base.items():
            self._files.pop(base, None)
            entries = dict(self._read(base))
            n = 0
            for ko, kn in moves:
                for k in [k for k in entries if k == ko or k.startswith(ko + "/")]:
                    entries[kn + k[len(ko):]] = entries.pop(k)
                    n += 1
            if n:
                try:
                    self._write(base, entries)
                    moved += n
                except OSError:
                    pass
        return moved


_DEFAULT: FolderOptions | None = None


def default(settings=None) -> FolderOptions:
    """One for the whole app (Safe Finder hands in its settings the first time)."""
    global _DEFAULT
    if _DEFAULT is None:
        _DEFAULT = FolderOptions(settings)
    elif settings is not None and _DEFAULT.settings is None:
        _DEFAULT.settings = settings
    return _DEFAULT
