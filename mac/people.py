"""People — the faces in your photos, grouped into people you name. Photos' People, for the library on the drive.

`faces.py` finds the faces in a photo and turns each into a list of numbers (an *embedding*) that is close to the
embeddings of the same person's other faces and far from everyone else's. This module keeps them (`Store`, one
SQLite file on this Mac) and does everything else, with numpy only and no Qt:

- **Grouping** (`Store.cluster`). New faces first join the person they're clearly closest to (the person's
  *centre* — the mean of their faces); what's left is grouped among itself: faces that have at least two close
  neighbours pull their neighbours into a group (so two look-alikes don't chain two crowds together), and a group
  of `MIN_GROUP` or more becomes a new, unnamed person. Faces that are small, blurred or turned away can *join* a
  person but never start one; faces close to nobody stay ungrouped. It's incremental — a later scan adds to the
  people there are — and it never undoes anything the person did.
- **What the person says stands.** Naming, merging, "this is not her", "yes, that's him" are kept as facts:
  a *confirmed* face is never moved by grouping, a *rejected* (face, person) pair is never proposed again, and a
  merge is for good. Renaming someone to a name another person has merges the two.
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
    "assign": 0.46,        # a new face joins the person whose centre it's this close to…
    "margin": 0.05,        # …and that much closer than to the runner-up
    "link": 0.50,          # two ungrouped faces are neighbours
    "core": 2,             # a face with this many neighbours pulls them into a group
    "keep": 0.40,          # a group's member must be this close to the group's centre
    "merge": 0.62,         # two unnamed groups this close are one
    "suggest": 0.34,       # worth asking about
    "weak": 0.45,          # a face's quality below this can join, not start, a person
}
MIN_GROUP = 3              # faces before an unnamed group is shown as a person
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
        self.db = sqlite3.connect(str(self.path), check_same_thread=False)
        self.db.execute("PRAGMA journal_mode=WAL")
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
            CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
        """)
        self.db.execute("INSERT OR IGNORE INTO meta VALUES ('schema', ?)", (str(SCHEMA),))
        self.db.commit()
        self._cache: tuple[np.ndarray, np.ndarray] | None = None     # (face ids, embeddings) — dropped on change
        self.changed: Callable[[], None] = lambda: None              # the window listens

    # ------------------------------------------------------------------ files and faces
    def scanned(self, path: str, mtime: float, size: int, model: str = "") -> bool:
        """Whether this file — as it is now — has been looked at (with this model)."""
        with self.lock:
            row = self.db.execute("SELECT mtime, size, model FROM files WHERE path = ?", (path,)).fetchone()
        return row is not None and row[0] == int(mtime) and row[1] == int(size) and (not model or row[2] == model)

    def add_file(self, path: str, mtime: float, size: int, found: list[dict], model: str = "") -> list[int]:
        """Records a looked-at photo and its faces (`found`: dicts with box, score, quality, emb). A photo looked
        at before is replaced — except that faces the person confirmed or named keep their place when the new
        look finds a face in the same spot."""
        with self.lock:
            old = self.db.execute("SELECT id, x, y, w, h, person, confirmed FROM faces WHERE path = ?", (path,)).fetchall()
            kept: dict[int, tuple] = {}
            for i, f in enumerate(found):
                bx = f["box"]
                for row in old:
                    if row[5] is not None and _overlap(bx, row[1:5]) > 0.5:
                        kept[i] = (row[5], row[6])
                        break
            self.db.execute("DELETE FROM faces WHERE path = ?", (path,))
            ids = []
            for i, f in enumerate(found):
                person, confirmed = kept.get(i, (None, 0))
                emb = unit(np.asarray(f["emb"], dtype=np.float32)).astype(np.float16).tobytes()
                x, y, w, h = (float(v) for v in f["box"])
                cur = self.db.execute("INSERT INTO faces (path, x, y, w, h, score, quality, emb, person, confirmed) "
                                      "VALUES (?,?,?,?,?,?,?,?,?,?)",
                                      (path, x, y, w, h, float(f["score"]), float(f["quality"]), emb, person, confirmed))
                ids.append(cur.lastrowid)
            self.db.execute("INSERT OR REPLACE INTO files VALUES (?,?,?,?,?,?)",
                            (path, int(mtime), int(size), len(found), model, time.time()))
            self.db.commit()
            self._cache = None
        return ids

    def counts(self) -> dict[str, int]:
        with self.lock:
            q = self.db.execute
            return {"photos": q("SELECT COUNT(*) FROM files").fetchone()[0],
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
                self.db.execute("UPDATE OR IGNORE rejects SET person = ? WHERE person = ?", (into, other))
                self.db.execute("DELETE FROM rejects WHERE person = ?", (other,))
                self.db.execute("DELETE FROM people WHERE id = ?", (other,))
            self.db.execute("UPDATE faces SET confirmed = 1 WHERE person = ?", (into,))
            # a face can't be both theirs and "not theirs"
            self.db.execute("DELETE FROM rejects WHERE person = ? AND face IN (SELECT id FROM faces WHERE person = ?)",
                            (into, into))
            self.db.commit()
        self.changed()
        return into

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
        """Files (or folders) that were renamed or moved by the app: their faces follow."""
        with self.lock:
            for old, new in pairs:
                self.db.execute("UPDATE OR REPLACE files SET path = ? WHERE path = ?", (new, old))
                self.db.execute("UPDATE faces SET path = ? WHERE path = ?", (new, old))
                like = old.rstrip("/").replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_") + "/%"
                n = len(old.rstrip("/"))
                self.db.execute("UPDATE OR REPLACE files SET path = ? || substr(path, ?) WHERE path LIKE ? ESCAPE '\\'",
                                (new.rstrip("/"), n + 1, like))
                self.db.execute("UPDATE faces SET path = ? || substr(path, ?) WHERE path LIKE ? ESCAPE '\\'",
                                (new.rstrip("/"), n + 1, like))
            self.db.commit()

    def forget_files(self, paths: Iterable[str]) -> None:
        """Photos that are gone (to the Trash): their faces with them."""
        with self.lock:
            for p in paths:
                self.db.execute("DELETE FROM faces WHERE path = ?", (p,))
                self.db.execute("DELETE FROM files WHERE path = ?", (p,))
            self.db.commit()
            self._cache = None
        self.changed()

    def forget_all(self) -> None:
        """Every face, every person, every name: gone. (The photos are untouched.)"""
        with self.lock:
            for table in ("faces", "people", "rejects", "files"):
                self.db.execute(f"DELETE FROM {table}")
            self.db.commit()
            self.db.execute("VACUUM")
            self._cache = None
        self.changed()

    # ------------------------------------------------------------------ grouping
    def _centres(self) -> tuple[list[int], np.ndarray]:
        """Each person's centre: the mean of their faces (confirmed ones counted twice), as a unit vector."""
        ids, m = self._matrix()
        with self.lock:
            rows = self.db.execute("SELECT id, person, confirmed FROM faces WHERE person IS NOT NULL").fetchall()
        if not rows:
            return [], np.zeros((0, DIM), dtype=np.float32)
        where = {int(f): i for i, f in enumerate(ids)}
        sums: dict[int, np.ndarray] = {}
        for fid, person, confirmed in rows:
            i = where.get(fid)
            if i is not None:
                sums[person] = sums.get(person, 0) + m[i] * (2.0 if confirmed else 1.0)
        people = sorted(sums)
        return people, unit(np.stack([sums[p] for p in people])) if people else np.zeros((0, DIM), dtype=np.float32)

    def cluster(self, progress: Callable[[str], None] = lambda _t: None,
                stop: Callable[[], bool] = lambda: False) -> dict[str, int]:
        """Groups what isn't grouped yet (module notes). Returns {"joined", "new_people", "merged"}."""
        t = TUNING
        out = {"joined": 0, "new_people": 0, "merged": 0}
        ids, m = self._matrix()
        if not len(ids):
            return out
        with self.lock:
            rows = self.db.execute("SELECT id, quality FROM faces WHERE person IS NULL").fetchall()
            rejected: dict[int, set[int]] = {}
            for face, person in self.db.execute("SELECT face, person FROM rejects"):
                rejected.setdefault(face, set()).add(person)
        where = {int(f): i for i, f in enumerate(ids)}
        free = [(fid, q) for fid, q in rows if fid in where]
        if not free:
            return out
        progress("Grouping faces…")

        # 1. join the people there are
        people, centres = self._centres()
        assign: dict[int, int] = {}
        if people:
            idx = np.array([where[f] for f, _q in free])
            sims = m[idx] @ centres.T                                 # (free faces) × (people)
            order = np.argsort(-sims, axis=1)
            for row, (fid, _q) in enumerate(free):
                no = rejected.get(fid, set())
                ranked = [(float(sims[row, c]), people[c]) for c in order[row, :4] if people[c] not in no]
                if not ranked:
                    continue
                best, who = ranked[0]
                runner = ranked[1][0] if len(ranked) > 1 else -1.0
                if best >= t["assign"] and best - runner >= t["margin"]:
                    assign[fid] = who
        if assign:
            with self.lock:
                self.db.executemany("UPDATE faces SET person = ? WHERE id = ? AND person IS NULL",
                                    [(p, f) for f, p in assign.items()])
                self.db.commit()
            out["joined"] = len(assign)
        if stop():
            return out

        # 2. group the rest among themselves: neighbours of "core" faces (those with enough neighbours)
        rest = [(fid, q) for fid, q in free if fid not in assign]
        strong = [fid for fid, q in rest if q >= t["weak"]]
        if len(strong) >= MIN_GROUP:
            idx = np.array([where[f] for f in strong])
            sub = m[idx]
            n = len(strong)
            parent = list(range(n))

            def find(x: int) -> int:
                while parent[x] != x:
                    parent[x] = parent[parent[x]]
                    x = parent[x]
                return x

            neighbours: list[np.ndarray] = []
            step = 2048
            for a in range(0, n, step):                               # in blocks: never an n × n table at once
                if stop():
                    return out
                block = sub[a:a + step] @ sub.T
                for r in range(block.shape[0]):
                    near = np.nonzero(block[r] >= t["link"])[0]
                    neighbours.append(near[near != a + r])
                if n > step:
                    progress(f"Grouping faces… {min(a + step, n):,} of {n:,}")
            core = [len(nb) >= t["core"] for nb in neighbours]
            for i in range(n):
                if core[i]:
                    for j in neighbours[i]:
                        parent[find(int(j))] = find(i)
            groups: dict[int, list[int]] = {}
            for i in range(n):
                if core[i] or any(core[int(j)] for j in neighbours[i]):
                    groups.setdefault(find(i), []).append(i)
            made: list[tuple[int, list[int]]] = []
            with self.lock:
                for members in groups.values():
                    if len(members) < MIN_GROUP:
                        continue
                    centre = unit(sub[members].mean(axis=0))
                    members = [i for i in members if float(sub[i] @ centre) >= t["keep"]]
                    if len(members) < MIN_GROUP:
                        continue
                    pid = self._new_person()
                    self.db.executemany("UPDATE faces SET person = ? WHERE id = ?", [(pid, strong[i]) for i in members])
                    made.append((pid, members))
                self.db.commit()
            out["new_people"] = len(made)
            # 3. the weak faces left over may join the people just made (never start one)
            if made and not stop():
                more = self._join_only([fid for fid, q in rest if q < t["weak"]], where, m, rejected)
                out["joined"] += more
        # 4. unnamed groups that turned out to be one person
        out["merged"] = self._merge_unnamed()
        self.changed()
        return out

    def _join_only(self, face_ids: list[int], where: dict[int, int], m: np.ndarray,
                   rejected: dict[int, set[int]]) -> int:
        if not face_ids:
            return 0
        people, centres = self._centres()
        if not people:
            return 0
        idx = np.array([where[f] for f in face_ids])
        sims = m[idx] @ centres.T
        got = []
        for row, fid in enumerate(face_ids):
            c = int(np.argmax(sims[row]))
            if float(sims[row, c]) >= TUNING["assign"] + 0.04 and people[c] not in rejected.get(fid, set()):
                got.append((people[c], fid))
        if got:
            with self.lock:
                self.db.executemany("UPDATE faces SET person = ? WHERE id = ? AND person IS NULL", got)
                self.db.commit()
        return len(got)

    def _merge_unnamed(self) -> int:
        """Two groups nobody has named whose centres are very close are one person. Named people are never
        merged by the app — only offered (`merge_candidates`)."""
        merged = 0
        for _ in range(50):
            people, centres = self._centres()
            with self.lock:
                named = {r[0] for r in self.db.execute("SELECT id FROM people WHERE name != ''")}
            free = [i for i, p in enumerate(people) if p not in named]
            if len(free) < 2:
                break
            sub = centres[free]
            sims = sub @ sub.T
            np.fill_diagonal(sims, -1.0)
            a, b = np.unravel_index(int(np.argmax(sims)), sims.shape)
            if float(sims[a, b]) < TUNING["merge"]:
                break
            pa, pb = people[free[a]], people[free[b]]
            with self.lock:
                self.db.execute("UPDATE faces SET person = ? WHERE person = ?", (pa, pb))
                self.db.execute("DELETE FROM people WHERE id = ?", (pb,))
                self.db.commit()
            merged += 1
        return merged

    # ------------------------------------------------------------------ suggestions
    def suggestions(self, person: int, limit: int = 60) -> list[tuple[Face, float]]:
        """Faces that are probably this person's — ungrouped ones, and faces in small unnamed groups — nearest
        first, each with how close (0…1). Never one the person said isn't theirs."""
        ids, m = self._matrix()
        people, centres = self._centres()
        if person not in people or not len(ids):
            return []
        centre = centres[people.index(person)]
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
        people, centres = self._centres()
        shown = {p.id: p for p in self.people()}
        idx = [i for i, p in enumerate(people) if p in shown]
        if len(idx) < 2:
            return []
        sub = centres[idx]
        sims = np.triu(sub @ sub.T, k=1)
        pairs = np.argwhere(sims >= TUNING["suggest"] + 0.08)
        out = sorted(((shown[people[idx[a]]], shown[people[idx[b]]], float(sims[a, b])) for a, b in pairs),
                     key=lambda x: -x[2])
        out = [(a, b, s) for a, b, s in out if not (a.name and b.name)]        # two named people: the person knows
        return out[:limit]

    def close(self) -> None:
        with self.lock:
            self.db.close()


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
