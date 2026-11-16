"""Folder birthdays — the iPhone app's "Age" — shared with it through the drive. No Qt here.

A folder (a person's folder, usually) has a birthday; every photo and video inside it, and inside its subfolders,
then shows an **Age**: whole years from the birthday to when it was taken (the nearest birthday above a file wins,
as on the iPhone — `Library.birthdayForFile`, `ageBetween`).

Where a birthday lives:
- **On the drive**, for a folder on a drive the iPhone app has opened (one with `.Photo Browser Metadata`):
  `<drive>/.Photo Browser Metadata/birthdays.json` —
  `{"birthdays": {"<folder, drive-relative>": {"date": <Unix time | null>, "at": <when it was set>}}}`. The iPhone
  app reads and writes the same file (`SharedBirthdays.swift`), so a birthday set here is there the next time the
  drive is opened on the phone (or the app comes back to the front), and the other way round. `"date": null` is a
  birthday that was **removed** — kept, with its time, so the other app's older copy doesn't bring it back.
- **Before the iPhone app has written that file**, the birthdays in its metadata backup on the drive
  (`metadata.json` → `folderBirthdays`) are read too, as if set at time 0 — so the phone's existing birthdays show
  here at once, and anything set here wins over them.
- **In Photo Browser for Mac's settings**, for any other folder, by its full path.

Merging (`merged`): for each folder, whichever entry was set later; a tie keeps the first. A save re-reads the
file and merges before writing, so neither app needs to know what the file said before.

The birthday is a moment (Unix time), as the iPhone keeps it; a birthday chosen here is noon of that day, so no
time zone moves it to the day before. Renames: `renamed(pairs)` moves a folder's birthday (and those of folders
inside it) — `rename_tools` calls it; the iPhone re-keys its own when it applies the rename journal.
"""
from __future__ import annotations

import json
import os
import time
import unicodedata
from datetime import date, datetime
from pathlib import Path

import app_identity

METADATA = ".Photo Browser Metadata"
FILE_NAME = "birthdays.json"
FORMAT = "photobrowser-birthdays"
BACKUP = "metadata.json"                     # the iPhone app's metadata backup on the drive
SETTINGS_KEY = "birthdays/local"

Entry = tuple  # (date: float | None, at: float)


def merged(a: dict[str, Entry], b: dict[str, Entry]) -> dict[str, Entry]:
    """For each folder, the entry set later; a tie keeps `a`'s."""
    out = dict(a)
    for k, v in b.items():
        if k not in out or v[1] > out[k][1]:
            out[k] = v
    return out


def drive_base(path: str) -> str | None:
    """The folder above (or at) `path` holding the app's metadata folder — the root the iPhone app browses."""
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


def _entry(v) -> Entry | None:
    if not isinstance(v, dict):
        return None
    d, at = v.get("date"), v.get("at")
    if not isinstance(at, (int, float)) or isinstance(at, bool):
        return None
    if d is not None and (not isinstance(d, (int, float)) or isinstance(d, bool)):
        return None
    return (float(d) if d is not None else None, float(at))


def noon(day: date) -> float:
    """A birthday chosen as a day: noon of it, on this Mac's clock."""
    return datetime(day.year, day.month, day.day, 12, 0, 0).timestamp()


def years_between(birth: float, taken: float) -> int | None:
    """Whole years from `birth` to `taken` (both Unix times), as a calendar counts them; None before birth."""
    b, t = datetime.fromtimestamp(birth), datetime.fromtimestamp(taken)
    years = t.year - b.year - ((t.month, t.day, t.hour, t.minute, t.second) < (b.month, b.day, b.hour, b.minute, b.second))
    return years if years >= 0 else None


class Birthdays:
    """`settings`: a QSettings (or anything with value/setValue) for folders that aren't on such a drive."""

    def __init__(self, settings=None) -> None:
        self.settings = settings
        self._files: dict[str, tuple[tuple, dict[str, Entry]]] = {}     # base → (stamp of the files, entries)
        self._extra: dict[str, dict] = {}
        self._unreadable: set[str] = set()
        self._bases: dict[str, tuple[float, str | None]] = {}

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
    def _path(base: str) -> Path:
        return Path(base) / METADATA / FILE_NAME

    @staticmethod
    def _stamp(file: Path):
        try:
            st = os.stat(file)
            return (st.st_mtime_ns, st.st_size)
        except OSError:
            return None

    def _read(self, base: str) -> dict[str, Entry]:
        """The drive's birthdays — the shared file over the iPhone's backup — read again only when either changed."""
        file, backup = self._path(base), Path(base) / METADATA / BACKUP
        stamp = (self._stamp(file), self._stamp(backup))
        hit = self._files.get(base)
        if hit and hit[0] == stamp:
            return hit[1]
        entries: dict[str, Entry] = {}
        if stamp[1] is not None:
            try:
                doc = json.loads(backup.read_bytes().decode("utf-8"))
                raw = doc.get("folderBirthdays") if isinstance(doc, dict) else None
                for k, v in (raw.items() if isinstance(raw, dict) else ()):
                    if isinstance(v, (int, float)) and not isinstance(v, bool):
                        entries[unicodedata.normalize("NFC", str(k))] = (float(v), 0.0)
            except (OSError, ValueError):
                pass
        if stamp[0] is not None:
            import net_fetch
            doc, how = net_fetch.load_json(file)            # a torn file is read from its .bak, never "nothing set"
            if how == "corrupt":
                self._unreadable.add(base)
            raw = doc.get("birthdays") if doc.get("format") == FORMAT else None
            shared: dict[str, Entry] = {}
            for k, v in (raw.items() if isinstance(raw, dict) else ()):
                e = _entry(v)
                if e is not None:
                    shared[unicodedata.normalize("NFC", str(k))] = e
            entries = merged(shared, entries)               # the shared file's word over the backup's
            self._extra[base] = {k: v for k, v in doc.items() if k not in ("format", "version", "updated", "by", "birthdays")}
        self._files[base] = (stamp, entries)
        return entries

    def _write(self, base: str, entries: dict[str, Entry]) -> None:
        import spare_folders
        file = self._path(base)
        file.parent.mkdir(parents=True, exist_ok=True)
        doc = {**self._extra.get(base, {}),
               "format": FORMAT, "version": 1, "updated": round(time.time(), 3), "by": app_identity.APP_NAME,
               "birthdays": {k: {"date": entries[k][0], "at": entries[k][1]} for k in sorted(entries)}}
        data = json.dumps(doc, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        try:
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
        self._files.pop(base, None)

    def _local(self) -> dict[str, Entry]:
        if self.settings is None:
            return {}
        try:
            raw = json.loads(str(self.settings.value(SETTINGS_KEY, "") or "{}"))
        except ValueError:
            return {}
        return {str(k): e for k, v in (raw.items() if isinstance(raw, dict) else ()) if (e := _entry(v)) is not None}

    def _save_local(self, entries: dict[str, Entry]) -> None:
        if self.settings is not None:
            self.settings.setValue(SETTINGS_KEY, json.dumps({k: {"date": v[0], "at": v[1]} for k, v in entries.items()}))

    # -- reading
    def own(self, folder: str) -> float | None:
        """The birthday set on `folder` itself (Unix time), or None."""
        if not folder or not os.path.isabs(folder):
            return None
        base = self._base(folder)
        e = self._read(base).get(_rel(base, folder)) if base is not None else self._local().get(os.path.abspath(folder))
        return e[0] if e else None

    def for_file(self, path: str) -> tuple[float, str] | None:
        """The nearest birthday on the folder holding `path` or any folder above it: (birthday, that folder)."""
        if not path or not os.path.isabs(path):
            return None
        base = self._base(os.path.dirname(path))
        entries = self._read(base) if base is not None else self._local()
        if not entries:
            return None
        folder = os.path.dirname(os.path.abspath(path))
        while True:
            key = _rel(base, folder) if base is not None else folder
            e = entries.get(key)
            if e and e[0] is not None:
                return e[0], folder
            if base is not None and key == "":
                return None
            parent = os.path.dirname(folder)
            if parent == folder:
                return None
            folder = parent

    def age(self, path: str, taken: float | None) -> int | None:
        """The Age of the photo or video at `path`, taken at `taken` (Unix time) — None without a birthday above
        it, without a date, or from before the birthday."""
        if not taken:
            return None
        found = self.for_file(path)
        return years_between(found[0], taken) if found else None

    def every(self, roots: list[str]) -> list[tuple[str, float]]:
        """Every folder with a birthday on the drives under `roots` (and the local ones): (folder, birthday)."""
        out: list[tuple[str, float]] = []
        seen: set[str] = set()
        for root in roots:
            base = drive_base(root) if os.path.isdir(root) else None
            if base is None or base in seen:
                continue
            seen.add(base)
            for rel, (d, _at) in self._read(base).items():
                if d is not None:
                    out.append((os.path.join(base, rel) if rel else base, d))
        out += [(k, v[0]) for k, v in self._local().items() if v[0] is not None]
        return sorted(out, key=lambda kv: kv[0].lower())

    # -- setting
    def set(self, folder: str, birthday: float | None) -> None:
        """Sets (None removes) `folder`'s birthday. Raises OSError when the drive's file can't be written."""
        entry: Entry = (birthday, time.time())
        base = self._base(folder)
        if base is None:
            entries = self._local()
            entries[os.path.abspath(folder)] = entry
            self._save_local(entries)
            return
        self._files.pop(base, None)                    # what's on the drive now
        entries = dict(self._read(base))
        entries[_rel(base, folder)] = entry
        self._write(base, entries)

    def renamed(self, pairs) -> int:
        """Folders renamed where they are: their birthdays (and those of folders inside) follow. Best effort."""
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
        now = time.time()
        for base, moves in by_base.items():
            self._files.pop(base, None)
            entries = dict(self._read(base))
            n = 0
            for ko, kn in moves:
                for k in [k for k in entries if k == ko or k.startswith(ko + "/")]:
                    d, _at = entries[k]
                    entries[kn + k[len(ko):]] = (d, now)
                    entries[k] = (None, now)            # gone from the old name — said, so the phone's copy follows
                    n += 1
            if n:
                try:
                    self._write(base, entries)
                    moved += n
                except OSError:
                    pass
        return moved


_DEFAULT: Birthdays | None = None


def default(settings=None) -> Birthdays:
    """One for the whole app (Photo Browser for Mac hands in its settings the first time)."""
    global _DEFAULT
    if _DEFAULT is None:
        _DEFAULT = Birthdays(settings)
    elif settings is not None and _DEFAULT.settings is None:
        _DEFAULT.settings = settings
    return _DEFAULT
