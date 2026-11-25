"""Clean Up — the iPhone app's "Randomized Clean Up", for Photo Browser for Mac: the arithmetic (no windows here).

On the iPhone it's a stack of cards: a folder's photos and videos one at a time, in shuffled order, each swiped
away as **delete**, **keep** or **favorite**, with what's been looked at remembered per folder so the next run
picks up where this one stopped.

The Mac's keeps the three answers and the memory, and changes one thing: **a "delete" is a mark, not a deletion.**
Nothing leaves the folder while you're going through it — so any answer can be taken back (Undo, or step back and
choose again), and at the end one screen shows exactly what's marked, to untick anything, before a single press
moves it all to the Trash (`cleanup_window.py`). Marks you don't act on are kept with the folder for next time.

`Session` is one run: the queue (what hasn't been looked at, shuffled or in order), an answer per item, and an
undo list. `Store` is what's remembered between runs — on this Mac (`cleanup.json` beside the app's other data),
by folder: the items already looked at and the ones still marked. A favorite is the app's own Favorite label
(shared with the iPhone); the session sets it through `set_favorite` and takes it off again only if it was the one
that put it on.
"""
from __future__ import annotations

import json
import os
import random
import threading
import time
import unicodedata
from pathlib import Path
from typing import Callable

KEEP, FAVORITE, DELETE = "keep", "favorite", "delete"
ANSWERS = (DELETE, KEEP, FAVORITE)
KEPT_FOLDERS = 400                # the store forgets the folders gone longest without a clean-up past this many


def _key(path: str) -> str:
    return unicodedata.normalize("NFC", os.path.abspath(path).rstrip(os.sep) or os.sep)


class Store:
    """What Clean Up remembers between runs, by folder: {"reviewed": [...], "delete": [...], "at": when}."""

    def __init__(self, file: str | Path) -> None:
        self.file = Path(file)
        self._lock = threading.Lock()
        self._data: dict | None = None

    def _load(self) -> dict:
        if self._data is None:
            try:
                doc = json.loads(self.file.read_text(encoding="utf-8"))
                self._data = doc if isinstance(doc, dict) and isinstance(doc.get("folders"), dict) else {"folders": {}}
            except (OSError, ValueError):
                self._data = {"folders": {}}
        return self._data

    def get(self, folder: str) -> tuple[set[str], list[str]]:
        """(the items already looked at, the items still marked for deletion) — both as full paths."""
        with self._lock:
            rec = self._load()["folders"].get(_key(folder)) or {}
            return {str(p) for p in rec.get("reviewed") or []}, [str(p) for p in rec.get("delete") or []]

    def put(self, folder: str, reviewed, delete) -> None:
        with self._lock:
            folders = self._load()["folders"]
            reviewed, delete = sorted(set(reviewed)), list(dict.fromkeys(delete))
            if reviewed or delete:
                folders[_key(folder)] = {"reviewed": reviewed, "delete": delete, "at": time.time()}
            else:
                folders.pop(_key(folder), None)
            if len(folders) > KEPT_FOLDERS:
                for old in sorted(folders, key=lambda k: folders[k].get("at", 0))[:len(folders) - KEPT_FOLDERS]:
                    del folders[old]
            self._save()

    def _save(self) -> None:
        try:
            self.file.parent.mkdir(parents=True, exist_ok=True)
            tmp = self.file.with_name(self.file.name + ".tmp")
            tmp.write_text(json.dumps(self._data, ensure_ascii=False), encoding="utf-8")
            os.replace(tmp, self.file)
        except OSError:
            pass                                       # progress that couldn't be kept is only looked at again


_STORE: Store | None = None


def store() -> Store:
    global _STORE
    if _STORE is None:
        import app_identity
        _STORE = Store(Path(app_identity.support()) / "cleanup.json")
    return _STORE


def gather(folder: str, deep: bool, is_media: Callable[[str], bool], skip: Callable[[str], bool] | None = None,
           stop: threading.Event | None = None) -> list[str]:
    """The photos and videos in `folder` — its own, or with everything under it (`deep`) — in name order, hidden
    items left out. `skip(path)`: files that aren't items of their own (a Live Photo's movie)."""
    out: list[str] = []

    def take(directory: str, names: list[str]) -> None:
        for name in sorted(names, key=str.casefold):
            if name.startswith("."):
                continue
            path = os.path.join(directory, name)
            if is_media(path) and not (skip is not None and skip(path)):
                out.append(path)

    if not deep:
        try:
            with os.scandir(folder) as it:
                take(folder, [e.name for e in it if e.is_file(follow_symlinks=False)])
        except OSError:
            pass
        return out
    for directory, dirs, files in os.walk(folder):
        if stop is not None and stop.is_set():
            break
        dirs[:] = sorted((d for d in dirs if not d.startswith(".")), key=str.casefold)
        take(directory, files)
    return out


class Session:
    """One run of Clean Up over `items` (the folder's photos and videos, as `gather` found them).

    - `queue`: what's shown, in the order shown — the items not looked at before, shuffled (or in order).
    - `answer(path)`: "" (not decided), "keep", "favorite" or "delete".
    - `decide(path, what)` / `undo()`: an answer set, changed or cleared; the last change taken back.
    - `marked()`: everything marked for deletion — this run's, and what an earlier run left marked.
    """

    def __init__(self, folder: str, items: list[str], kept: Store | None = None, shuffled: bool = True,
                 set_favorite: Callable[[str, bool], None] | None = None,
                 is_favorite: Callable[[str], bool] | None = None, seed=None) -> None:
        self.folder = folder
        self.store = kept
        self.set_favorite, self.is_favorite = set_favorite, is_favorite
        here = set(items)
        before, marked = kept.get(folder) if kept is not None else (set(), [])
        self.reviewed_before = before & here                 # (what's gone from the folder is forgotten)
        self.carried = [p for p in marked if p in here]      # marked on an earlier run, not acted on
        skip = self.reviewed_before | set(self.carried)
        self.queue = [p for p in items if p not in skip]
        if shuffled:
            random.Random(seed).shuffle(self.queue)
        self.total_here = len(items)
        self.answers: dict[str, str] = {p: DELETE for p in self.carried}
        self._ours: set[str] = set()                         # favorites this session put on (taken off if undone)
        self._undo: list[tuple[str, str]] = []               # (path, the answer it had)

    # -- answers
    def answer(self, path: str) -> str:
        return self.answers.get(path, "")

    def decide(self, path: str, what: str, remember: bool = True) -> None:
        """Set `path`'s answer ("" clears it). A favorite gets the Favorite label; moving off it takes the label
        back off — when this session put it there."""
        if what not in ANSWERS and what != "":
            raise ValueError(what)
        was = self.answers.get(path, "")
        if was == what:
            return
        if remember:
            self._undo.append((path, was))
        if what:
            self.answers[path] = what
        else:
            self.answers.pop(path, None)
        if what == FAVORITE:
            if self.set_favorite is not None and not (self.is_favorite is not None and self.is_favorite(path)):
                self.set_favorite(path, True)
                self._ours.add(path)
        elif was == FAVORITE and path in self._ours:
            self._ours.discard(path)
            if self.set_favorite is not None:
                self.set_favorite(path, False)
        self.save()

    def undo(self) -> str:
        """The last answer taken back → the item it was about ("" when there's nothing to undo)."""
        if not self._undo:
            return ""
        path, was = self._undo.pop()
        self.decide(path, was, remember=False)
        return path

    def can_undo(self) -> bool:
        return bool(self._undo)

    # -- where things stand
    def marked(self) -> list[str]:
        """Everything marked for deletion, earlier runs' first."""
        return [p for p, a in self.answers.items() if a == DELETE]

    def next_open(self, after: int) -> int:
        """The index in the queue of the next item with no answer, looking on from `after` and then from the
        start; -1 when every one has one."""
        n = len(self.queue)
        for step in range(1, n + 1):
            j = (after + step) % n
            if not self.answer(self.queue[j]):
                return j
        return -1

    def counts(self) -> dict:
        mine = [self.answers.get(p, "") for p in self.queue]
        return {"total": len(self.queue), "decided": sum(1 for a in mine if a),
                "left": sum(1 for a in mine if not a),
                KEEP: mine.count(KEEP), FAVORITE: mine.count(FAVORITE), DELETE: len(self.marked()),
                "carried": len(self.carried), "before": len(self.reviewed_before), "here": self.total_here}

    # -- what's kept between runs
    def save(self) -> None:
        if self.store is None:
            return
        looked = self.reviewed_before | {p for p, a in self.answers.items() if a in (KEEP, FAVORITE)}
        self.store.put(self.folder, looked, self.marked())

    def gone(self, paths) -> None:
        """These left the folder (moved to the Trash — here or from the viewer): nothing more is kept of them."""
        gone = set(paths)
        for p in gone:
            self.answers.pop(p, None)
            self._ours.discard(p)
        self.queue = [p for p in self.queue if p not in gone]
        self.carried = [p for p in self.carried if p not in gone]
        self.reviewed_before -= gone
        self._undo = [(p, was) for p, was in self._undo if p not in gone]
        self.save()

    def start_over(self) -> None:
        """Forget what was looked at and what's marked (favorites given stay): the whole folder comes round again."""
        self.answers.clear()
        self._undo.clear()
        self._ours.clear()
        self.reviewed_before = set()
        self.carried = []
        if self.store is not None:
            self.store.put(self.folder, [], [])
