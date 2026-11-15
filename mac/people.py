"""People — the faces in your photos, grouped into people you name. Photos' People, for the library on the drive.

`faces.py` finds the faces in a photo and turns each into a list of numbers (an *embedding*) that is close to the
embeddings of the same person's other faces and far from everyone else's. This module keeps them (`Store`, one
SQLite file on this Mac) and does everything else, with numpy only and no Qt:

- **Grouping** (`Store.cluster`). New faces first join the person they're clearly closest to; what's left is
  grouped among itself: faces that have at least two close neighbours pull their neighbours into a group, **each
  group is then tested for being two people** (`_split`: cut in two the best way it can be; if the halves are
  much less like each other than like themselves, they're two — one borderline pair of look-alikes otherwise
  chains two people into one), and a group of `MIN_GROUP` or more becomes a new, unnamed person. Faces that are
  small, blurred or turned away can *join* a person but never start one; faces close to nobody stay ungrouped.
  It's incremental — a later scan adds to the people there are — and it never undoes anything the person did.
- **"How like this person is this face"** is the face's *average* similarity to the person's faces (the face ·
  the mean of theirs) — not its similarity to their normalised centre, which flatters: against a person whose
  faces average 0.5 with each other, a stranger at 0.36 scores 0.50 on the centre. Two groups are one person
  when they're as like each other as they are like themselves (`merge_ratio`).
- **What the person says stands.** Naming, merging, "this is not her", "yes, that's him" are kept as facts:
  a *confirmed* face is never moved by grouping, a *rejected* (face, person) pair is never proposed again, and a
  merge is for good. Renaming someone to a name another person has merges the two. Grouping runs on its own
  thread while the window stays in use, so everything it writes is written **only if it's still true** (the face
  is still nobody's, the person still there, the pair not rejected since); a photo looked at again hands each
  face's person, rejects and key-photo choice to the face found in the same spot; and the app merges two unnamed
  groups only when no reject or "different people" stands between them and at most one of them holds anything
  the person confirmed.
- **Memory is bounded** (`BLOCK_BYTES`): every faces × people or faces × faces table is worked out a block of
  rows at a time and reduced to what's needed (the best and the runner-up; who's near whom) before the next —
  a whole table for 90,000 faces and 1,500 people took 2.2 GB.
- **Suggestions** (`suggestions`, `merge_candidates`): faces — or whole unnamed people — that are probably this
  person but not surely enough to add without asking: Photos' "Review" / "Is this the same person?".
- **Albums**: `photos_of(person)` is every photo with one of their faces; `people_in(path)` the people in a photo.

Nothing here leaves the Mac. Face data is biometric: it lives only in
`~/Library/Application Support/Photo Browser for Mac/People/`, the app never uploads it and never names anyone
itself — and `forget_all()` (People ▸ Forget All Face Data…) deletes every bit of it.

The numbers (`TUNING`) are for the embedder `faces.py` uses (SFace: 128 numbers, cosine similarity; its makers'
"same person" line is 0.363). Grouping is stricter than that line on purpose: a missed face shows up as a
suggestion, a wrong one spoils an album.
"""
from __future__ import annotations

import os
import sqlite3
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Iterable

import numpy as np

import app_identity

DIM = 128
TUNING = {
    "assign": 0.42,        # a new face joins the person whose faces it's this like on average…
    "margin": 0.05,        # …and that much more than the runner-up's
    "link": 0.50,          # two ungrouped faces are neighbours
    "core": 2,             # a face with this many neighbours pulls them into a group
    "keep": 0.34,          # a group's member must be this like the rest of the group, on average
    "split_ratio": 0.75,   # a group's two halves this much less like each other than like themselves: two people
    "merge_ratio": 0.85,   # two unnamed groups this nearly as like each other as like themselves: one person
    "ask": 0.33,           # two people this alike: "Same Person?"
    "suggest": 0.30,       # a face this like a person: worth asking about
    "weak": 0.45,          # a face's quality below this can join, not start, a person
}
MIN_GROUP = 3              # faces before an unnamed group is shown as a person
BLOCK_BYTES = 48 << 20     # the most one table of likenesses takes while grouping (it's worked out in blocks)
RETRY_FAILED = 24 * 3600   # a photo that couldn't be read as a picture is tried again after this long (seconds)
SCHEMA = 1


def folder() -> Path:
    return app_identity.support() / "People"


@dataclass
class Face:
    """One face in one photo. `box` is (x, y, w, h) as fractions of the upright picture."""
    id: int
    path: str
    box: tuple[float, float, float, float]
    score: float                 # how sure the detector was
    quality: float               # 0…1: big, sharp, facing the camera
    person: int | None
    confirmed: bool


@dataclass
class Person:
    id: int
    name: str                    # "" until named
    key_face: int | None
    favorite: bool
    hidden: bool
    faces: int = 0
    photos: int = 0

    @property
    def label(self) -> str:
        return self.name or "Unnamed"


def quality_of(score: float, face_px: float, sharpness: float, frontal: float) -> float:
    """One number for how good a face is to go by: the detector's certainty, its size (full marks from 110 px
    — the size the embedder looks at), how sharp, how nearly facing the camera."""
    size = min(1.0, max(0.0, (face_px - 24.0) / 86.0))
    sharp = min(1.0, sharpness / 120.0)
    return float(max(0.0, min(1.0, score)) * (0.45 * size + 0.25 * sharp + 0.30 * max(0.0, min(1.0, frontal))))


def unit(m: np.ndarray) -> np.ndarray:
    m = np.asarray(m, dtype=np.float32)
    n = np.linalg.norm(m, axis=-1, keepdims=True)
    return m / np.maximum(n, 1e-9)


class Store:
    """Everything known about faces and people, in one SQLite file. Safe to use from the scan's thread and the
    window's at once (one connection, one lock)."""

    def __init__(self, path: Path | None = None) -> None:
        self.path = Path(path) if path else folder() / "people.sqlite3"
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.lock = threading.RLock()
        self.thumbs = self.path.parent / "thumbs"      # the window's face pictures, "<face id>.jpg" (FaceCache)
        self.epoch = 0                                 # goes up with forget_all: a scan begun before it adds nothing
        self._grouping = threading.Lock()              # one `cluster` at a time
        self.db = sqlite3.connect(str(self.path), check_same_thread=False)
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("PRAGMA secure_delete=ON")     # a deleted face's numbers are overwritten, not just unlinked
        # files.faces: how many faces the photo had — or -1 for one that couldn't be read as a picture (`note_failed`)
        self.db.executescript("""
            CREATE TABLE IF NOT EXISTS files (path TEXT PRIMARY KEY, mtime INTEGER, size INTEGER, faces INTEGER,
                                              model TEXT, at REAL);
            CREATE TABLE IF NOT EXISTS faces (id INTEGER PRIMARY KEY AUTOINCREMENT, path TEXT NOT NULL,
                                              x REAL, y REAL, w REAL, h REAL, score REAL, quality REAL,
                                              emb BLOB NOT NULL, person INTEGER, confirmed INTEGER DEFAULT 0);
            CREATE INDEX IF NOT EXISTS faces_path ON faces(path);
            CREATE INDEX IF NOT EXISTS faces_person ON faces(person);
            CREATE TABLE IF NOT EXISTS people (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT DEFAULT '',
                                               key_face INTEGER, favorite INTEGER DEFAULT 0, hidden INTEGER DEFAULT 0,
                                               created REAL);
            CREATE TABLE IF NOT EXISTS rejects (face INTEGER, person INTEGER, PRIMARY KEY (face, person));
            CREATE TABLE IF NOT EXISTS apart (a INTEGER, b INTEGER, PRIMARY KEY (a, b));
            CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
        """)
        self.db.execute("INSERT OR IGNORE INTO meta VALUES ('schema', ?)", (str(SCHEMA),))
        self.db.commit()
        self._cache: tuple[np.ndarray, np.ndarray] | None = None     # (face ids, embeddings) — dropped on change
        self.changed: Callable[[], None] = lambda: None              # the window listens

    # ------------------------------------------------------------------ files and faces
    def scanned(self, path: str, mtime: float, size: int, model: str = "") -> bool:
        """Whether this file — as it is now — has been looked at (with this model). One that couldn't be read
        as a picture counts as looked at for `RETRY_FAILED`, then it's tried again."""
        with self.lock:
            row = self.db.execute("SELECT mtime, size, model, faces, at FROM files WHERE path = ?", (path,)).fetchone()
        if row is None or row[0] != int(mtime) or row[1] != int(size) or (model and row[2] != model):
            return False
        return (row[3] or 0) >= 0 or time.time() - (row[4] or 0) < RETRY_FAILED

    def add_file(self, path: str, mtime: float, size: int, found: list[dict], model: str = "",
                 epoch: int | None = None) -> list[int]:
        """Records a looked-at photo and its faces (`found`: dicts with box, score, quality, emb). A photo looked
        at before is replaced — its faces get new ids — but what was known about a face goes to the face now
        found in the same spot: its person (confirmed or not), the people it was said *not* to be, and its
        being someone's key photo. `epoch` (the store's when the look began): after a `forget_all` since then,
        nothing is recorded."""
        with self.lock:
            if epoch is not None and epoch != self.epoch:
                return []
            old = self.db.execute("SELECT id, x, y, w, h, person, confirmed FROM faces WHERE path = ?", (path,)).fetchall()
            same: dict[int, tuple] = {}                # new face → the old one it is (each old face once, best fit first)
            taken: set[int] = set()
            for fit, i, k in sorted(((_overlap(f["box"], row[1:5]), i, k) for i, f in enumerate(found)
                                     for k, row in enumerate(old)), reverse=True):
                if fit <= 0.5:
                    break
                if i not in same and k not in taken:
                    same[i] = old[k]
                    taken.add(k)
            self.db.execute("DELETE FROM faces WHERE path = ?", (path,))
            ids = []
            for i, f in enumerate(found):
                was = same.get(i)
                person, confirmed = (was[5], was[6]) if was is not None and was[5] is not None else (None, 0)
                emb = unit(np.asarray(f["emb"], dtype=np.float32)).astype(np.float16).tobytes()
                x, y, w, h = (float(v) for v in f["box"])
                cur = self.db.execute("INSERT INTO faces (path, x, y, w, h, score, quality, emb, person, confirmed) "
                                      "VALUES (?,?,?,?,?,?,?,?,?,?)",
                                      (path, x, y, w, h, float(f["score"]), float(f["quality"]), emb, person, confirmed))
                ids.append(cur.lastrowid)
                if was is not None:
                    self.db.execute("UPDATE OR IGNORE rejects SET face = ? WHERE face = ?", (cur.lastrowid, was[0]))
                    self.db.execute("UPDATE people SET key_face = ? WHERE key_face = ?", (cur.lastrowid, was[0]))
            gone = [row[0] for row in old]
            self._forget_faces(gone)
            self.db.execute("INSERT OR REPLACE INTO files VALUES (?,?,?,?,?,?)",
                            (path, int(mtime), int(size), len(found), model, time.time()))
            self.db.commit()
            self._cache = None
        self._drop_thumbs(gone)
        return ids

    def note_failed(self, path: str, mtime: float, size: int, model: str = "", epoch: int | None = None) -> None:
        """A photo that couldn't be read as a picture (not one the drive failed to hand over — that's not
        recorded at all). Noted so each scan doesn't try it again — for `RETRY_FAILED`, not for good — and
        **its faces from an earlier look are left as they were**: a half-copied or damaged file says nothing
        about who was in it."""
        with self.lock:
            if epoch is not None and epoch != self.epoch:
                return
            self.db.execute("INSERT OR REPLACE INTO files VALUES (?,?,?,?,?,?)",
                            (path, int(mtime), int(size), -1, model, time.time()))
            self.db.commit()

    def _forget_faces(self, face_ids: list[int]) -> None:
        """(Inside the lock, before the commit.) Faces that are gone: what was said about them goes too."""
        if face_ids:
            gone = [(i,) for i in face_ids]
            self.db.executemany("DELETE FROM rejects WHERE face = ?", gone)
            self.db.executemany("UPDATE people SET key_face = NULL WHERE key_face = ?", gone)

    def _drop_thumbs(self, face_ids: Iterable[int]) -> None:
        """The window's pictures of faces that are gone (a face's picture is face data too)."""
        for i in face_ids:
            try:
                (self.thumbs / f"{i}.jpg").unlink(missing_ok=True)
            except OSError:
                pass

    def counts(self) -> dict[str, int]:
        with self.lock:
            q = self.db.execute
            return {"photos": q("SELECT COUNT(*) FROM files WHERE faces >= 0").fetchone()[0],
                    "faces": q("SELECT COUNT(*) FROM faces").fetchone()[0],
                    "grouped": q("SELECT COUNT(*) FROM faces WHERE person IS NOT NULL").fetchone()[0],
                    "people": q("SELECT COUNT(*) FROM people").fetchone()[0],
                    "named": q("SELECT COUNT(*) FROM people WHERE name != ''").fetchone()[0]}

    def _matrix(self) -> tuple[np.ndarray, np.ndarray]:
        with self.lock:
            if self._cache is None:
                rows = self.db.execute("SELECT id, emb FROM faces ORDER BY id").fetchall()
                ids = np.array([r[0] for r in rows], dtype=np.int64)
                m = np.zeros((len(rows), DIM), dtype=np.float32)
                for i, (_id, blob) in enumerate(rows):
                    m[i] = np.frombuffer(blob, dtype=np.float16, count=DIM)
                self._cache = (ids, unit(m) if len(rows) else m)
            return self._cache

    def _face(self, row) -> Face:
        return Face(row[0], row[1], (row[2], row[3], row[4], row[5]), row[6], row[7], row[8], bool(row[9]))

    _FACE = "id, path, x, y, w, h, score, quality, person, confirmed"

    def face(self, face_id: int) -> Face | None:
        with self.lock:
            row = self.db.execute(f"SELECT {self._FACE} FROM faces WHERE id = ?", (face_id,)).fetchone()
        return self._face(row) if row else None

    def faces_of(self, person: int) -> list[Face]:
        with self.lock:
            rows = self.db.execute(f"SELECT {self._FACE} FROM faces WHERE person = ? ORDER BY quality DESC",
                                   (person,)).fetchall()
        return [self._face(r) for r in rows]

    def faces_in(self, path: str) -> list[Face]:
        with self.lock:
            rows = self.db.execute(f"SELECT {self._FACE} FROM faces WHERE path = ? ORDER BY x", (path,)).fetchall()
        return [self._face(r) for r in rows]

    def ungrouped(self, limit: int = 500) -> list[Face]:
        with self.lock:
            rows = self.db.execute(f"SELECT {self._FACE} FROM faces WHERE person IS NULL ORDER BY quality DESC LIMIT ?",
                                   (limit,)).fetchall()
        return [self._face(r) for r in rows]

    # ------------------------------------------------------------------ people
    def people(self, hidden: bool = False) -> list[Person]:
        """Everyone with at least one face: favourites first, then named (A–Z), then unnamed by size. Unnamed
        groups smaller than MIN_GROUP aren't people yet."""
        with self.lock:
            rows = self.db.execute(
                "SELECT p.id, p.name, p.key_face, p.favorite, p.hidden, COUNT(f.id), COUNT(DISTINCT f.path) "
                "FROM people p JOIN faces f ON f.person = p.id GROUP BY p.id").fetchall()
        out = [Person(r[0], r[1] or "", r[2], bool(r[3]), bool(r[4]), r[5], r[6]) for r in rows]
        out = [p for p in out if (p.name or p.faces >= MIN_GROUP) and (hidden or not p.hidden)]
        out.sort(key=lambda p: (not p.favorite, not p.name, p.name.casefold() if p.name else "", -p.photos, p.id))
        return out

    def person(self, person: int) -> Person | None:
        return next((p for p in self.people(hidden=True) if p.id == person), None) or self._bare(person)

    def _bare(self, person: int) -> Person | None:
        with self.lock:
            r = self.db.execute("SELECT id, name, key_face, favorite, hidden FROM people WHERE id = ?", (person,)).fetchone()
        return Person(r[0], r[1] or "", r[2], bool(r[3]), bool(r[4])) if r else None

    def find(self, name: str) -> Person | None:
        want = " ".join(name.split()).casefold()
        return next((p for p in self.people(hidden=True) if p.name and p.name.casefold() == want), None)

    def photos_of(self, person: int) -> list[str]:
        with self.lock:
            rows = self.db.execute("SELECT DISTINCT path FROM faces WHERE person = ? ORDER BY path", (person,)).fetchall()
        return [r[0] for r in rows]

    def people_in(self, path: str) -> list[Person]:
        ids = {f.person for f in self.faces_in(path) if f.person is not None}
        return [p for p in self.people(hidden=True) if p.id in ids]

    def key_face(self, person: int) -> Face | None:
        """The face that stands for the person: the one chosen, else their best."""
        p = self._bare(person)
        if p is not None and p.key_face:
            f = self.face(p.key_face)
            if f is not None and f.person == person:
                return f
        faces = self.faces_of(person)
        return faces[0] if faces else None

    def _new_person(self, name: str = "") -> int:
        cur = self.db.execute("INSERT INTO people (name, created) VALUES (?, ?)", (name, time.time()))
        return cur.lastrowid

    def rename(self, person: int, name: str) -> int:
        """Names (or renames) a person. A name someone else already has means they're the same: the two are
        merged, and the id that's left is returned."""
        name = " ".join(name.split())[:80]
        other = self.find(name) if name else None
        if other is not None and other.id != person:
            return self.merge(other.id, [person])
        with self.lock:
            self.db.execute("UPDATE people SET name = ? WHERE id = ?", (name, person))
            if name:                                  # naming someone is saying "these are them"
                self.db.execute("UPDATE faces SET confirmed = 1 WHERE person = ?", (person,))
            self.db.commit()
        self.changed()
        return person

    def merge(self, into: int, others: Iterable[int]) -> int:
        """`others` are the same person as `into`: their faces move over, for good."""
        with self.lock:
            target = self._bare(into)
            for other in others:
                if other == into:
                    continue
                o = self._bare(other)
                if o is None:
                    continue
                if target is not None and not target.name and o.name:        # the name survives
                    self.db.execute("UPDATE people SET name = ? WHERE id = ?", (o.name, into))
                    target.name = o.name
                self.db.execute("UPDATE faces SET person = ?, confirmed = 1 WHERE person = ?", (into, other))
                self._absorb(into, other)
            self.db.execute("UPDATE faces SET confirmed = 1 WHERE person = ?", (into,))
            # a face can't be both theirs and "not theirs"
            self.db.execute("DELETE FROM rejects WHERE person = ? AND face IN (SELECT id FROM faces WHERE person = ?)",
                            (into, into))
            self.db.commit()
        self.changed()
        return into

    def _absorb(self, into: int, other: int) -> None:
        """(Inside the lock, before the commit.) `other`'s faces are `into`'s now: what was said about `other`
        is said about `into` — "not them" for a face, "different people" from someone else — and `other` goes."""
        self.db.execute("UPDATE OR IGNORE rejects SET person = ? WHERE person = ?", (into, other))
        self.db.execute("DELETE FROM rejects WHERE person = ?", (other,))
        for a, b in self.db.execute("SELECT a, b FROM apart WHERE a = ? OR b = ?", (other, other)).fetchall():
            third = b if a == other else a
            if third != into:
                self.db.execute("INSERT OR IGNORE INTO apart VALUES (?, ?)", (min(into, third), max(into, third)))
        self.db.execute("DELETE FROM apart WHERE a = ? OR b = ?", (other, other))
        self.db.execute("DELETE FROM people WHERE id = ?", (other,))

    def keep_apart(self, a: int, b: int) -> None:
        """"Different people": the two are never offered as one again."""
        with self.lock:
            self.db.execute("INSERT OR IGNORE INTO apart VALUES (?, ?)", (min(a, b), max(a, b)))
            self.db.commit()
        self.changed()

    def _apart(self) -> set[tuple[int, int]]:
        with self.lock:
            return {(r[0], r[1]) for r in self.db.execute("SELECT a, b FROM apart")}

    def ungroup(self, person: int) -> None:
        """Takes a group apart: its faces go back to being nobody's (to be grouped again, or not)."""
        with self.lock:
            self.db.execute("UPDATE faces SET person = NULL, confirmed = 0 WHERE person = ?", (person,))
            self.db.execute("DELETE FROM people WHERE id = ?", (person,))
            self.db.execute("DELETE FROM rejects WHERE person = ?", (person,))
            self.db.execute("DELETE FROM apart WHERE a = ? OR b = ?", (person, person))
            self.db.commit()
        self.changed()

    def confirm(self, face_ids: Iterable[int], person: int) -> None:
        """"Yes, that's them": the faces are the person's, and stay."""
        with self.lock:
            for fid in face_ids:
                self.db.execute("UPDATE faces SET person = ?, confirmed = 1 WHERE id = ?", (person, fid))
                self.db.execute("DELETE FROM rejects WHERE face = ? AND person = ?", (fid, person))
            self.db.commit()
        self.changed()

    def reject(self, face_ids: Iterable[int], person: int) -> None:
        """"That's not them": out of the person's album, and never suggested for them again."""
        with self.lock:
            for fid in face_ids:
                self.db.execute("INSERT OR IGNORE INTO rejects VALUES (?, ?)", (fid, person))
                self.db.execute("UPDATE faces SET person = NULL, confirmed = 0 WHERE id = ? AND person = ?", (fid, person))
            self.db.execute("UPDATE people SET key_face = NULL WHERE id = ? AND key_face NOT IN "
                            "(SELECT id FROM faces WHERE person = ?)", (person, person))
            self.db.commit()
        self.changed()

    def remove_photos(self, paths: Iterable[str], person: int) -> int:
        """"This is not <name>" on photos: the person's faces in them are rejected."""
        ids = [f.id for p in paths for f in self.faces_in(p) if f.person == person]
        if ids:
            self.reject(ids, person)
        return len(ids)

    def set_key(self, person: int, face_id: int | None) -> None:
        with self.lock:
            self.db.execute("UPDATE people SET key_face = ? WHERE id = ?", (face_id, person))
            self.db.commit()
        self.changed()

    def set_flag(self, person: int, flag: str, on: bool) -> None:
        assert flag in ("favorite", "hidden")
        with self.lock:
            self.db.execute(f"UPDATE people SET {flag} = ? WHERE id = ?", (1 if on else 0, person))
            self.db.commit()
        self.changed()

    def renamed(self, pairs: Iterable[tuple[str, str]]) -> None:
        """Files and folders the app renamed or moved — every (old, new) of one batch: their faces follow.

        The pairs are taken **together**, not one after another: a renumbering (1 → 2, 2 → 3, 3 → 4) or two names
        trading places would otherwise pile every photo's faces onto one file. For each photo known here, its
        own pair applies first, then the pair of the folder it's in, then that folder's folder's — each level
        once, which is also how a batch that renames a file *and* the folder above it arrives (the file's new
        path with the parent as it was, the parent after). Everything is read first and written after, in one
        transaction.

        Nothing here scans a table: a pair finds its photo by the path's index, and what's inside a folder as
        the range `old/` … `old0` ("0" is the character after "/"). So a pair costs a few index look-ups whatever
        it is, the disk isn't asked whether it's a folder, and case matters as it does in the paths."""
        moves: dict[str, str] = {}
        for old, new in pairs:
            old, new = old.rstrip("/"), new.rstrip("/")
            if old and new and old != new:
                moves[old] = new
        if not moves:
            return
        gone: list[int] = []
        with self.lock:
            try:
                known: set[str] = set()
                for old in moves:
                    for table in ("files", "faces"):
                        known.update(r[0] for r in self.db.execute(f"SELECT path FROM {table} WHERE path = ?", (old,)))
                        known.update(r[0] for r in self.db.execute(
                            f"SELECT DISTINCT path FROM {table} WHERE path >= ? AND path < ?", (old + "/", old + "0")))
                final = {path: _moved(path, moves) for path in known}
                final = {path: to for path, to in final.items() if to != path}
                if not final:
                    return
                # a record at a path something is renamed onto, and not itself moving: of a file no longer there
                gone = self._forget_paths({to for to in final.values() if to not in final})
                files, faces = [], []
                for path, to in final.items():
                    row = self.db.execute("SELECT mtime, size, faces, model, at FROM files WHERE path = ?", (path,)).fetchone()
                    if row is not None:
                        files.append((to, *row))
                    faces += [(to, r[0]) for r in self.db.execute("SELECT id FROM faces WHERE path = ?", (path,))]
                self.db.executemany("DELETE FROM files WHERE path = ?", [(path,) for path in final])
                self.db.executemany("INSERT OR REPLACE INTO files VALUES (?,?,?,?,?,?)", files)
                self.db.executemany("UPDATE faces SET path = ? WHERE id = ?", faces)
                self.db.commit()
            except Exception:
                self.db.rollback()
                raise
        self._drop_thumbs(gone)

    def _forget_paths(self, paths: Iterable[str]) -> list[int]:
        """(Inside the lock, before the commit.) Drops what's known about these photos — and, for a folder,
        about every photo inside it. The ids of the faces dropped."""
        gone: list[int] = []
        for p in paths:
            p = p.rstrip("/")
            if not p:
                continue
            inside = (p + "/", p + "0")
            gone += [r[0] for r in self.db.execute("SELECT id FROM faces WHERE path = ?", (p,))]
            gone += [r[0] for r in self.db.execute("SELECT id FROM faces WHERE path >= ? AND path < ?", inside)]
            for table in ("faces", "files"):
                self.db.execute(f"DELETE FROM {table} WHERE path = ?", (p,))
                self.db.execute(f"DELETE FROM {table} WHERE path >= ? AND path < ?", inside)
        self._forget_faces(gone)
        return gone

    def _settle(self) -> None:
        """(Inside the lock, after a commit.) Empties the write-ahead file: what was just deleted is still in
        there, as it was, until SQLite next folds it into the main file."""
        try:
            self.db.execute("PRAGMA wal_checkpoint(TRUNCATE)").fetchall()
        except sqlite3.Error:
            pass

    def note_drive(self, drive_id: str, root: str) -> int:
        """A drive (known by the id in its shared tag file) is at `root` now. Faces are kept by path — so when a
        drive known here comes back somewhere else (renamed in Finder, mounted as "SSD 1", or its clone on a new
        SSD), its photos' faces go to the new paths rather than being lost and found again by a whole new scan.
        Not while the old place is still there too (a clone beside its original: the faces stay with the
        original). Returns how many photos were followed."""
        root = root.rstrip("/")
        if not drive_id or not root:
            return 0
        key = f"drive:{drive_id}"
        with self.lock:
            row = self.db.execute("SELECT value FROM meta WHERE key = ?", (key,)).fetchone()
        was = ((row[0] if row else "") or "").rstrip("/")
        if was == root:
            return 0
        followed = 0
        if was:
            if os.path.isdir(was):
                return 0
            with self.lock:
                followed = self.db.execute("SELECT COUNT(*) FROM files WHERE path >= ? AND path < ?",
                                           (was + "/", was + "0")).fetchone()[0]
            if followed:
                self.renamed([(was, root)])
        with self.lock:
            self.db.execute("INSERT OR REPLACE INTO meta VALUES (?, ?)", (key, root))
            self.db.commit()
        return followed

    def forget_files(self, paths: Iterable[str]) -> None:
        """Photos that are gone (to the Trash) — or whole folders of them: their faces with them, and what was
        said about those faces, and the window's pictures of them."""
        with self.lock:
            gone = self._forget_paths(paths)
            self.db.commit()
            self._settle()
            self._cache = None
        self._drop_thumbs(gone)
        self.changed()

    def forget_all(self) -> None:
        """Every face, every person, every name: gone. (The photos are untouched.) Gone from the file, not
        only from the tables: the file is rebuilt and the write-ahead file emptied, and the window's face
        pictures are deleted. A scan that's still finishing a photo adds nothing afterwards (`epoch`)."""
        with self.lock:
            self.epoch += 1
            for table in ("faces", "people", "rejects", "apart", "files"):
                self.db.execute(f"DELETE FROM {table}")
            self.db.commit()
            self.db.execute("VACUUM")
            self._settle()
            self._cache = None
        try:
            for f in self.thumbs.iterdir():
                f.unlink(missing_ok=True)
        except OSError:
            pass
        self.changed()

    # ------------------------------------------------------------------ grouping
    def _sums(self) -> tuple[list[int], np.ndarray, np.ndarray]:
        """Each person's faces added up (confirmed ones counted twice), and how many that was: (people, sums,
        weights). Kept apart so that two groups becoming one is an addition, not another reading of the store."""
        ids, m = self._matrix()
        with self.lock:
            rows = self.db.execute("SELECT id, person, COALESCE(confirmed, 0) FROM faces WHERE person IS NOT NULL").fetchall()
        none = [], np.zeros((0, DIM), dtype=np.float32), np.zeros(0, dtype=np.float32)
        if not rows or not len(ids):
            return none
        table = np.array(rows, dtype=np.int64)
        at = np.minimum(np.searchsorted(ids, table[:, 0]), len(ids) - 1)       # (ids are in order)
        here = ids[at] == table[:, 0]                                          # (a face added since `m` was read: not yet)
        table, at = table[here], at[here]
        if not len(table):
            return none
        people, col = np.unique(table[:, 1], return_inverse=True)
        order = np.argsort(col, kind="stable")
        starts = np.searchsorted(col[order], np.arange(len(people)))
        w = np.where(table[order, 2] != 0, 2.0, 1.0).astype(np.float32)
        vec = m[at[order]]
        vec *= w[:, None]
        return [int(x) for x in people], np.add.reduceat(vec, starts, axis=0), np.add.reduceat(w, starts)

    def _means(self) -> tuple[list[int], np.ndarray]:
        """Each person's mean face — the plain average of their faces' vectors (confirmed ones counted twice),
        *not* made unit length: a face · a person's mean is the face's average similarity to their faces, and a
        mean · itself is how alike their own faces are."""
        people, sums, weight = self._sums()
        return people, (sums / weight[:, None]).astype(np.float32) if people else sums

    @staticmethod
    def _split(sub: np.ndarray, members: list[int]) -> list[list[int]]:
        """A group that is really two people, as two groups (else as it was). The group is cut in two around its
        two least alike corners (a few rounds of 2-means); if the halves' faces are much less like each other
        than like their own half, the cut is real — and each half is tried again."""
        if len(members) < 2 * MIN_GROUP:
            return [members]
        vec = sub[members]
        centre = unit(vec.mean(axis=0))
        a = int(np.argmin(vec @ centre))                       # the odd one out…
        b = int(np.argmin(vec @ vec[a]))                       # …and the face least like it
        ca, cb = vec[a], vec[b]
        side = None
        for _ in range(6):
            side = (vec @ ca) >= (vec @ cb)
            if side.all() or not side.any():
                return [members]
            ca, cb = unit(vec[side].mean(axis=0)), unit(vec[~side].mean(axis=0))
        ma, mb = vec[side].mean(axis=0), vec[~side].mean(axis=0)
        cross, within = float(ma @ mb), min(float(ma @ ma), float(mb @ mb))
        if cross >= TUNING["split_ratio"] * within or cross >= TUNING["link"]:
            return [members]                                   # one person, seen two ways
        left = [members[i] for i in np.nonzero(side)[0]]
        right = [members[i] for i in np.nonzero(~side)[0]]
        return Store._split(sub, left) + Store._split(sub, right)

    def cluster(self, progress: Callable[[str], None] = lambda _t: None,
                stop: Callable[[], bool] = lambda: False) -> dict[str, int]:
        """Groups what isn't grouped yet (module notes). Returns {"joined", "new_people", "merged"}. Meant for
        a worker thread — it takes seconds with tens of thousands of faces — and only one runs at a time: a
        second call waits for the first, then finds little left to do."""
        with self._grouping:
            out = {"joined": 0, "new_people": 0, "merged": 0}
            try:
                self._cluster(out, progress, stop)
            finally:
                if any(out.values()):
                    self.changed()
            return out

    # A face joins a person only if, at the moment it's written, the face is still nobody's, the person is
    # still there and the pair hasn't been rejected: the person may have said so while this was being worked out.
    _JOIN = ("UPDATE faces SET person = ?1 WHERE id = ?2 AND person IS NULL "
             "AND EXISTS (SELECT 1 FROM people WHERE id = ?1) "
             "AND NOT EXISTS (SELECT 1 FROM rejects WHERE face = ?2 AND person = ?1)")

    def _cluster(self, out: dict[str, int], progress: Callable[[str], None], stop: Callable[[], bool]) -> None:
        t = TUNING
        ids, m = self._matrix()
        if not len(ids):
            return
        with self.lock:
            rows = self.db.execute("SELECT id, quality FROM faces WHERE person IS NULL").fetchall()
            rejected: dict[int, set[int]] = {}
            for face, person in self.db.execute("SELECT face, person FROM rejects"):
                rejected.setdefault(face, set()).add(person)
        where = {int(f): i for i, f in enumerate(ids)}
        free = [(fid, q) for fid, q in rows if fid in where]
        if not free:
            return
        progress("Grouping faces…")

        # 1. join the people there are
        people, means = self._means()
        assign: dict[int, int] = {}
        if people:
            idx = np.array([where[f] for f, _q in free])
            best, who, runner = self._nearest(m, idx, means, self._vetoes([f for f, _q in free], people, rejected), stop)
            for row in np.nonzero((best >= t["assign"]) & (best - runner >= t["margin"]))[0]:
                assign[free[int(row)][0]] = people[int(who[row])]
        if assign:
            with self.lock:
                out["joined"] = self.db.executemany(self._JOIN, [(p, f) for f, p in assign.items()]).rowcount
                self.db.commit()
        if stop():
            return

        # 2. group the rest among themselves: neighbours of "core" faces (those with enough neighbours)
        rest = [(fid, q) for fid, q in free if fid not in assign]
        strong = [fid for fid, q in rest if q >= t["weak"]]
        if len(strong) >= MIN_GROUP:
            sub = m[np.array([where[f] for f in strong])]
            groups = self._neighbour_groups(sub, progress, stop)
            if groups is None:
                return
            parts = [part for members in groups for part in self._split(sub, members)]
            made = 0
            with self.lock:
                # (the faces still nobody's: one the person gave to someone while this ran stays theirs)
                still = {r[0] for r in self.db.execute("SELECT id FROM faces WHERE person IS NULL")}
                for members in parts:
                    members = [i for i in members if strong[i] in still]
                    if len(members) < MIN_GROUP:
                        continue
                    vec = sub[members]
                    members = [members[i] for i in np.nonzero(vec @ vec.mean(axis=0) >= t["keep"])[0]]
                    if len(members) < MIN_GROUP:
                        continue
                    pid = self._new_person()
                    self.db.executemany("UPDATE faces SET person = ? WHERE id = ? AND person IS NULL",
                                        [(pid, strong[i]) for i in members])
                    made += 1
                self.db.commit()
            out["new_people"] = made
            # 3. the weak faces left over may join the people just made (never start one)
            if made and not stop():
                out["joined"] += self._join_only([fid for fid, q in rest if q < t["weak"]], where, m, rejected)
        # 4. unnamed groups that turned out to be one person
        if not stop():
            out["merged"] = self._merge_unnamed()

    @staticmethod
    def _vetoes(face_ids: list[int], people: list[int], rejected: dict[int, set[int]]) -> list[tuple[int, int]]:
        """(row, column) of every face × person the person said no to — rows as in `face_ids`, columns as in
        `people`."""
        if not rejected:
            return []
        col = {p: c for c, p in enumerate(people)}
        return [(row, col[p]) for row, fid in enumerate(face_ids) for p in rejected.get(fid, ()) if p in col]

    @staticmethod
    def _nearest(m: np.ndarray, idx: np.ndarray, means: np.ndarray, vetoes: list[tuple[int, int]] = (),
                 stop: Callable[[], bool] = lambda: False) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
        """For each face (rows `idx` of `m`): how like the person it's most like on average, which person (a
        column of `means`), and how like the runner-up (−1 with nobody else). `vetoes` are never chosen. The
        table of faces × people is made `BLOCK_BYTES` at a time and only these three numbers a face are kept —
        the best by two passes of "largest", not by sorting every row."""
        n, p = len(idx), len(means)
        best = np.full(n, -1.0, dtype=np.float32)
        who = np.zeros(n, dtype=np.int64)
        runner = np.full(n, -1.0, dtype=np.float32)
        veto = np.array(sorted(vetoes), dtype=np.int64).reshape(-1, 2)
        step = max(1, BLOCK_BYTES // (4 * max(p, DIM)))
        for a in range(0, n, step):
            if stop():
                break
            sims = m[idx[a:a + step]] @ means.T
            rows = np.arange(len(sims))
            mine = veto[(veto[:, 0] >= a) & (veto[:, 0] < a + step)]
            sims[mine[:, 0] - a, mine[:, 1]] = -2.0
            top = sims.argmax(axis=1)
            best[a:a + step], who[a:a + step] = sims[rows, top], top
            if p > 1:
                sims[rows, top] = -2.0
                runner[a:a + step] = np.maximum(sims.max(axis=1), -1.0)
        return best, who, runner

    @staticmethod
    def _neighbour_groups(sub: np.ndarray, progress: Callable[[str], None],
                          stop: Callable[[], bool]) -> list[list[int]] | None:
        """The faces (rows of `sub`) gathered round "core" faces — those with at least `core` neighbours at
        `link` or closer: a core face and its neighbours are one group, and groups that share a face are one.
        None when stopped.

        Who is near whom is never kept: a block of rows of the n × n table is made (`BLOCK_BYTES`), each core
        row in it joins its neighbours' groups there and then, and the block is dropped. (The lists of
        neighbours were 200 MB for one person with 5,000 photos.) The groups are a forest in an array —
        `parent[i]`, the smallest face of i's group once followed to its end — joined a whole row at a time."""
        n = len(sub)
        link, core = TUNING["link"], TUNING["core"]
        parent = np.arange(n)
        grouped = np.zeros(n, dtype=bool)                     # a core face, or the neighbour of one
        step = max(1, BLOCK_BYTES // (5 * n))                 # 4 bytes a likeness + 1 for "near enough"
        for a in range(0, n, step):
            if stop():
                return None
            near = sub[a:a + step] @ sub.T >= link
            rows = np.arange(near.shape[0])
            near[rows, a + rows] = False                      # (not its own neighbour)
            for r in np.nonzero(np.count_nonzero(near, axis=1) >= core)[0]:
                group = np.append(np.nonzero(near[r])[0], a + r)
                grouped[group] = True
                roots = parent[group]
                while True:                                   # each one's group, followed to its end
                    up = parent[roots]
                    if np.array_equal(up, roots):
                        break
                    roots = up
                top = roots.min()
                parent[roots] = top
                parent[group] = top
            if n > step * 8:
                progress(f"Grouping faces… {min(a + step, n):,} of {n:,}")
        while True:
            up = parent[parent]
            if np.array_equal(up, parent):
                break
            parent = up
        groups: dict[int, list[int]] = {}
        for i in np.nonzero(grouped)[0]:
            groups.setdefault(int(parent[i]), []).append(int(i))
        return list(groups.values())

    def _join_only(self, face_ids: list[int], where: dict[int, int], m: np.ndarray,
                   rejected: dict[int, set[int]]) -> int:
        if not face_ids:
            return 0
        people, means = self._means()
        if not people:
            return 0
        best, who, _runner = self._nearest(m, np.array([where[f] for f in face_ids]), means)
        got = []
        for row in np.nonzero(best >= TUNING["assign"] + 0.04)[0]:
            person, fid = people[int(who[row])], face_ids[int(row)]
            if person not in rejected.get(fid, ()):
                got.append((person, fid))
        if not got:
            return 0
        with self.lock:
            joined = self.db.executemany(self._JOIN, got).rowcount
            self.db.commit()
        return joined

    def _merge_unnamed(self) -> int:
        """Two groups nobody has named that are as like each other as they are like themselves are one person.
        Named people are never merged by the app — only offered (`merge_candidates`). Nor are two groups the
        person said are different people, two with a "that's not them" between them (a face of one rejected
        for the other), or two that *both* hold something the person did (a confirmed face, a key photo,
        Favorite, Hide) — and when one does, it's the one that stays, so nothing confirmed changes hands."""
        people, sums, weight = self._sums()
        with self.lock:
            named = {r[0] for r in self.db.execute("SELECT id FROM people WHERE name != ''")}
            held = {r[0] for r in self.db.execute("SELECT DISTINCT person FROM faces WHERE confirmed = 1 "
                                                  "AND person IS NOT NULL")}
            held |= {r[0] for r in self.db.execute("SELECT id FROM people WHERE favorite = 1 OR hidden = 1 "
                                                   "OR key_face IS NOT NULL")}
            never = list(self.db.execute("SELECT a, b FROM apart"))
            never += list(self.db.execute("SELECT DISTINCT f.person, r.person FROM rejects r JOIN faces f "
                                          "ON f.id = r.face WHERE f.person IS NOT NULL AND f.person != r.person"))
        who = [p for p in people if p not in named]
        if len(who) < 2:
            return 0
        keep = np.array([i for i, p in enumerate(people) if p not in named])
        sums, weight = sums[keep].astype(np.float64), weight[keep].astype(np.float64)
        at = {p: i for i, p in enumerate(who)}
        alive = np.ones(len(who), dtype=bool)
        fixed = np.array([p in held for p in who])
        barred: dict[int, set[int]] = {}
        for x, y in never:
            if x in at and y in at:
                barred.setdefault(at[x], set()).add(at[y])
                barred.setdefault(at[y], set()).add(at[x])
        merged = 0
        for _ in range(50):
            pair = self._closest_pair((sums / weight[:, None]).astype(np.float32), alive, fixed, barred)
            if pair is None:
                break
            a, b = (pair[1], pair[0]) if fixed[pair[1]] else pair          # the one with something confirmed stays
            with self.lock:
                names = dict(self.db.execute("SELECT id, name FROM people WHERE id IN (?, ?)", (who[a], who[b])))
                if len(names) == 2 and not any(names.values()):            # (neither named, or gone, meanwhile)
                    self.db.execute("UPDATE faces SET person = ? WHERE person = ?", (who[a], who[b]))
                    self._absorb(who[a], who[b])
                    self.db.commit()
                    merged += 1
                else:
                    barred.setdefault(a, set()).add(b)
                    barred.setdefault(b, set()).add(a)
                    continue
            sums[a] += sums[b]
            weight[a] += weight[b]
            alive[b] = False
            fixed[a] = fixed[a] or fixed[b]
            for k in barred.pop(b, set()):                                 # what stood between b and k stands between a and k
                barred[k].discard(b)
                barred[k].add(a)
                barred.setdefault(a, set()).add(k)
        return merged

    @staticmethod
    def _closest_pair(means: np.ndarray, alive: np.ndarray, fixed: np.ndarray,
                      barred: dict[int, set[int]]) -> tuple[int, int] | None:
        """The two groups most nearly one person — likeness to each other over the lesser of their likeness to
        themselves — among the pairs allowed, or None when no pair is near enough (`merge_ratio`, and as like
        as a face must be to join: `assign`). A block of rows of the groups × groups table at a time."""
        n = len(means)
        own = np.einsum("ij,ij->i", means, means)
        best, pair = TUNING["merge_ratio"], None
        step = max(1, BLOCK_BYTES // (8 * max(n, 1)))
        for a in range(0, n, step):
            cross = means[a:a + step] @ means.T
            rows = np.arange(len(cross))
            ratio = cross / np.maximum(np.minimum(own[a:a + step, None], own[None, :]), 1e-6)
            ratio[cross < TUNING["assign"]] = -1.0
            ratio[rows, a + rows] = -1.0
            ratio[~alive[a:a + step], :] = -1.0
            ratio[:, ~alive] = -1.0
            ratio[np.ix_(fixed[a:a + step], fixed)] = -1.0
            for i in range(a, min(a + step, n)):
                if i in barred:
                    ratio[i - a, list(barred[i])] = -1.0
            r, c = np.unravel_index(int(np.argmax(ratio)), ratio.shape)
            if float(ratio[r, c]) >= best:
                best, pair = float(ratio[r, c]), (a + int(r), int(c))
        return pair

    # ------------------------------------------------------------------ suggestions
    def suggestions(self, person: int, limit: int = 60) -> list[tuple[Face, float]]:
        """Faces that are probably this person's — ungrouped ones, and faces in small unnamed groups — nearest
        first, each with how close (0…1). Never one the person said isn't theirs."""
        ids, m = self._matrix()
        people, means = self._means()
        if person not in people or not len(ids):
            return []
        centre = means[people.index(person)]
        with self.lock:
            named = {r[0] for r in self.db.execute("SELECT id FROM people WHERE name != ''")}
            rows = self.db.execute(f"SELECT {self._FACE} FROM faces WHERE person IS NULL OR person != ?", (person,)).fetchall()
            no = {r[0] for r in self.db.execute("SELECT face FROM rejects WHERE person = ?", (person,))}
        where = {int(f): i for i, f in enumerate(ids)}
        cands = [r for r in rows if r[0] in where and r[0] not in no and (r[8] is None or r[8] not in named)
                 and not r[9]]
        if not cands:
            return []
        sims = m[np.array([where[r[0]] for r in cands])] @ centre
        order = np.argsort(-sims)
        out = []
        for i in order[:limit * 2]:
            if float(sims[i]) < TUNING["suggest"]:
                break
            out.append((self._face(cands[int(i)]), float(sims[i])))
            if len(out) >= limit:
                break
        return out

    def merge_candidates(self, limit: int = 20) -> list[tuple[Person, Person, float]]:
        """Pairs of people who may be one — "Is this the same person?" — nearest first."""
        people, means = self._means()
        shown = {p.id: p for p in self.people()}
        idx = [i for i, p in enumerate(people) if p in shown]
        if len(idx) < 2:
            return []
        sub = means[idx]
        sims = np.triu(sub @ sub.T, k=1)
        pairs = np.argwhere(sims >= TUNING["ask"])
        out = sorted(((shown[people[idx[a]]], shown[people[idx[b]]], float(sims[a, b])) for a, b in pairs),
                     key=lambda x: -x[2])
        apart = self._apart()
        out = [(a, b, s) for a, b, s in out if not (a.name and b.name)         # two named people: the person knows
               and (min(a.id, b.id), max(a.id, b.id)) not in apart]
        return out[:limit]

    def close(self) -> None:
        with self.lock:
            self.db.close()


def _moved(path: str, moves: dict[str, str]) -> str:
    """Where `path` is once `moves` (old → new, no trailing slashes) have all been made: its own entry, then
    its folder's, then that folder's folder's — each entry used once, so 1 → 2 doesn't go on through 2 → 3."""
    used: set[str] = set()
    cut = len(path)                              # the end of the part being looked up: all of it, then each folder up
    while cut > 0:
        head = path[:cut]
        new = moves.get(head)
        if new is not None and head not in used:
            used.add(head)
            path = new + path[cut:]
            cut = len(new)
        cut = path.rfind("/", 0, cut)
    return path


def _overlap(a, b) -> float:
    """Intersection over union of two (x, y, w, h) boxes."""
    ax, ay, aw, ah = a
    bx, by, bw, bh = b
    ix = max(0.0, min(ax + aw, bx + bw) - max(ax, bx))
    iy = max(0.0, min(ay + ah, by + bh) - max(ay, by))
    inter = ix * iy
    union = aw * ah + bw * bh - inter
    return inter / union if union > 0 else 0.0


_shared: Store | None = None
_shared_lock = threading.Lock()


def shared() -> Store:
    global _shared
    with _shared_lock:
        if _shared is None:
            _shared = Store()
        return _shared
