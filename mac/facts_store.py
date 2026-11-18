"""Small facts about files kept between launches — which picture a folder shows (its first photo or video, found by
scanning it, up to three levels down) and how long a video is. No Qt.

Both used to be kept only for the session (`photo_browser._Facts`), so every launch scanned every folder on screen
again and asked every video its length again — on an external drive, folder by folder. Now what was found is kept in
a small SQLite file in the app's support folder (`facts.sqlite`, not in Caches, which macOS empties when space runs
low) and read back the next time.

**Safe to keep because every key carries a modified time**: a folder's cover is kept under (folder, the folder's
modified time), a video's length under (file, its modified time) — a folder whose items change, or a video rewritten,
asks again by itself. A cover is still checked when it's handed out (`valid`): a picture deep in a subfolder can go
without its folder's time changing, and then it's looked for again.

Reads are answered from memory once seen, else from the file (a lookup on a local disk: microseconds — so a folder's
picture is there on the first paint, not a moment after). Writes are gathered and written together (`flush`, from a
timer and at quit). The file is trimmed to `MOST` rows, oldest first.
"""
from __future__ import annotations

import json
import os
import sqlite3
import threading
import time
from pathlib import Path

MOST = 400_000                       # rows kept, all kinds together (each ~150 bytes: ~60 MB at most)
_MISSING = object()


class FactsStore:
    def __init__(self, file: str | Path) -> None:
        self.file = Path(file)
        self._lock = threading.Lock()
        self._db: sqlite3.Connection | None = None
        self._pending: dict[tuple[str, str], str] = {}
        self._broken = False

    def _conn(self) -> sqlite3.Connection | None:
        if self._db is None and not self._broken:
            try:
                self.file.parent.mkdir(parents=True, exist_ok=True)
                db = sqlite3.connect(str(self.file), check_same_thread=False, timeout=5)
                db.execute("PRAGMA journal_mode=WAL")
                db.execute("PRAGMA synchronous=NORMAL")
                db.execute("CREATE TABLE IF NOT EXISTS facts (kind TEXT NOT NULL, key TEXT NOT NULL, value TEXT, "
                           "at REAL NOT NULL, PRIMARY KEY (kind, key))")
                self._db = db
            except sqlite3.Error:
                self._broken = True                  # an unreadable file: the facts are simply found again
                self._db = None
        return self._db

    @staticmethod
    def _key(key) -> str:
        return json.dumps(list(key) if isinstance(key, tuple) else key, ensure_ascii=False)

    def get(self, kind: str, key):
        """The value kept for `key`, or `_MISSING` (use `known`) when there is none."""
        k = self._key(key)
        with self._lock:
            if (kind, k) in self._pending:
                return json.loads(self._pending[(kind, k)])
            db = self._conn()
            if db is None:
                return _MISSING
            try:
                row = db.execute("SELECT value FROM facts WHERE kind=? AND key=?", (kind, k)).fetchone()
            except sqlite3.Error:
                return _MISSING
        if row is None:
            return _MISSING
        try:
            return json.loads(row[0])
        except (TypeError, ValueError):
            return _MISSING

    @staticmethod
    def known(value) -> bool:
        return value is not _MISSING

    def put(self, kind: str, key, value) -> None:
        with self._lock:
            self._pending[(kind, self._key(key))] = json.dumps(value, ensure_ascii=False)

    def flush(self) -> int:
        """What was found since the last flush, written in one go. Returns how many."""
        with self._lock:
            if not self._pending:
                return 0
            rows, self._pending = self._pending, {}
            db = self._conn()
            if db is None:
                return 0
            now = time.time()
            try:
                with db:
                    db.executemany("INSERT OR REPLACE INTO facts (kind, key, value, at) VALUES (?, ?, ?, ?)",
                                   [(kind, key, value, now) for (kind, key), value in rows.items()])
                    count = db.execute("SELECT COUNT(*) FROM facts").fetchone()[0]
                    if count > MOST:              # the oldest go: facts about folders not looked at in a long time
                        db.execute("DELETE FROM facts WHERE rowid IN (SELECT rowid FROM facts ORDER BY at LIMIT ?)",
                                   (count - int(MOST * 0.9),))
            except sqlite3.Error:
                return 0
            return len(rows)

    def close(self) -> None:
        self.flush()
        with self._lock:
            if self._db is not None:
                try:
                    self._db.close()
                except sqlite3.Error:
                    pass
                self._db = None


def valid(kind: str, value) -> bool:
    """Whether a kept fact still holds: a folder's cover picture is still there with the same modified time."""
    if kind != "cover" or value is None:
        return True
    try:
        path, mtime = value
        return int(os.stat(path).st_mtime) == int(mtime)
    except (OSError, TypeError, ValueError):
        return False


_default: FactsStore | None = None


def default() -> FactsStore:
    global _default
    if _default is None:
        env = os.environ.get("PHOTO_BROWSER_FACTS")
        if env:
            _default = FactsStore(env)
        else:
            import app_identity
            _default = FactsStore(app_identity.support() / "facts.sqlite")
    return _default
