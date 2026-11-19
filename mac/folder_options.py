"""Per-folder choices shared with the iPhone app: **Videos at the Top** (`videos_first` — a folder's videos listed
before its photos and other files; folders still first), **album highlight** (`highlight` — the folder shown as a
bubble in its parent) and **Reviews folder** (`reviews` — every folder inside it shown as a large bubble); the last
two are highlights.py's.

Where a choice lives:
- **On the drive**, for a folder on a drive the iPhone app has opened (one with `.Photo Browser Metadata`):
  `<drive>/.Photo Browser Metadata/folder-options.json` — `{"videos_first": {"<folder, drive-relative>": stamp},
  "highlight": {…}, "reviews": {…}}`.
  The iPhone app reads and writes the same file (`FolderOptions.swift`), so a folder set here is shown that way
  there, and the other way round.
- **In Photo Browser for Mac's settings**, for any other folder (on the Mac, or a drive the app has never opened), by its
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
import app_identity

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


OPTIONS = ("videos_first", "highlight", "reviews")       # the keys in the file (each: {folder: stamp})


class FolderOptions:
    """`settings`: a QSettings (or anything with value/setValue) for folders that aren't on such a drive."""

    def __init__(self, settings=None) -> None:
        self.settings = settings
        # base → (stamp of the file, {option: {folder: stamp}})
        self._files: dict[str, tuple[tuple[int, int] | None, dict[str, dict[str, float]]]] = {}
        self._unreadable: set[str] = set()             # bases whose shared file was there but couldn't be read
        self._extra: dict[str, dict] = {}              # base → keys in the file this version doesn't know (kept on writing)
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

    def _read(self, base: str) -> dict[str, dict[str, float]]:
        """The drive's entries, by option — read again only when the file has changed."""
        file = self._path(base)
        try:
            st = os.stat(file)
            stamp = (st.st_mtime_ns, st.st_size)
        except OSError:
            stamp = None
        hit = self._files.get(base)
        if hit and hit[0] == stamp:
            return hit[1]
        entries: dict[str, dict[str, float]] = {o: {} for o in OPTIONS}
        if stamp is not None:
            import net_fetch
            doc, how = net_fetch.load_json(file)            # a torn file is read from its .bak, never taken for "nothing set"
            if how == "corrupt":
                self._unreadable.add(base)
            if doc.get("format") == FORMAT:
                for o in OPTIONS:
                    raw = doc.get(o)
                    if isinstance(raw, dict):
                        entries[o] = {unicodedata.normalize("NFC", str(k)): float(v) for k, v in raw.items()
                                      if isinstance(v, (int, float)) and not isinstance(v, bool)}
            self._extra[base] = {k: v for k, v in doc.items()
                                 if k not in ("format", "version", "updated", "by", *OPTIONS)}
        self._files[base] = (stamp, entries)
        return entries

    def _write(self, base: str, entries: dict[str, dict[str, float]]) -> None:
        import spare_folders
        file = self._path(base)
        doc = {**self._extra.get(base, {}),                 # (what a later version of either app put there stays)
               "format": FORMAT, "version": 1, "updated": round(time.time(), 3), "by": app_identity.APP_NAME}
        for o in OPTIONS:
            if entries.get(o) or o == "videos_first":
                doc[o] = {k: entries[o][k] for k in sorted(entries.get(o, {}))}
        data = json.dumps(doc, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        try:                                                # what's there now: kept as .bak (or .damaged) first
            import net_fetch
            if base in self._unreadable:
                file.with_name(file.name + ".damaged").write_bytes(file.read_bytes())
                self._unreadable.discard(base)
            else:
                net_fetch.keep_backup(file)
        except OSError:
            pass
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
        self._files[base] = ((st.st_mtime_ns, st.st_size), {o: dict(entries.get(o, {})) for o in OPTIONS})

    @staticmethod
    def _key(option: str) -> str:
        return SETTINGS_KEY if option == "videos_first" else f"folderOptions/{option}"

    def _local(self, option: str = "videos_first") -> dict[str, float]:
        if self.settings is None:
            return {}
        try:
            raw = json.loads(str(self.settings.value(self._key(option), "") or "{}"))
            return {str(k): float(v) for k, v in raw.items() if isinstance(v, (int, float))} if isinstance(raw, dict) else {}
        except ValueError:
            return {}

    def _save_local(self, entries: dict[str, float], option: str = "videos_first") -> None:
        if self.settings is not None:
            if len(entries) > 5000:                    # the oldest choices go first
                entries = dict(sorted(entries.items(), key=lambda kv: abs(kv[1]))[-4000:])
            self.settings.setValue(self._key(option), json.dumps(entries))

    # -- a choice
    def stamp(self, option: str, folder: str) -> float:
        """When the choice was last made for `folder` — positive on, negative off, 0 never."""
        if not folder or not os.path.isabs(folder):
            return 0.0
        base = self._base(folder)
        if base is not None:
            return self._read(base)[option].get(_rel(base, folder), 0.0)
        return self._local(option).get(os.path.abspath(folder), 0.0)

    def marks(self, option: str, folder: str) -> tuple[str | None, dict[str, float]]:
        """(the drive's root or None, every choice of `option` there — by drive-relative folder, or by full path
        for a folder that's on no such drive): one read for a whole listing."""
        base = self._base(folder) if folder and os.path.isabs(folder) else None
        return (base, self._read(base)[option]) if base is not None else (None, self._local(option))

    def set(self, option: str, folder: str, on: bool) -> None:
        """Raises OSError when the drive's file can't be written (read-only, gone)."""
        stamp = time.time() if on else -time.time()
        base = self._base(folder)
        if base is None:
            entries = self._local(option)
            entries[os.path.abspath(folder)] = stamp
            self._save_local(entries, option)
            return
        self._files.pop(base, None)                    # what's on the drive now, not what was read a while ago
        entries = {o: dict(v) for o, v in self._read(base).items()}
        entries[option][_rel(base, folder)] = stamp
        self._write(base, entries)

    def videos_first(self, folder: str) -> bool:
        return self.stamp("videos_first", folder) > 0

    def set_videos_first(self, folder: str, on: bool) -> None:
        self.set("videos_first", folder, on)

    def renamed(self, pairs) -> int:
        """Folders renamed where they are: their entries (and those of folders inside) follow. Best effort."""
        moved = 0
        by_base: dict[str, list[tuple[str, str]]] = {}
        local_pairs = []
        for old, new in pairs:
            base = self._base(os.path.dirname(new))
            if base is None:
                local_pairs.append((old, new))
            else:
                by_base.setdefault(base, []).append((_rel(base, old), _rel(base, new)))
        for o in OPTIONS if local_pairs else ():
            local, n = self._local(o), 0
            for old, new in local_pairs:
                for k in [k for k in local if k == old or k.startswith(old.rstrip("/") + "/")]:
                    local[new + k[len(old):]] = local.pop(k)
                    n += 1
            if n:
                self._save_local(local, o)
                moved += n
        for base, moves in by_base.items():
            self._files.pop(base, None)
            entries = {o: dict(v) for o, v in self._read(base).items()}
            n = 0
            for o in OPTIONS:
                for ko, kn in moves:
                    for k in [k for k in entries[o] if k == ko or k.startswith(ko + "/")]:
                        entries[o][kn + k[len(ko):]] = entries[o].pop(k)
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
    """One for the whole app (Photo Browser for Mac hands in its settings the first time)."""
    global _DEFAULT
    if _DEFAULT is None:
        _DEFAULT = FolderOptions(settings)
    elif settings is not None and _DEFAULT.settings is None:
        _DEFAULT.settings = settings
    return _DEFAULT
