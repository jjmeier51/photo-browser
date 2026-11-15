"""The edit behind an edited copy — so it can be opened again with every slider where it was.

The photo editor saves pixels: "name (edited).jpg" is a finished picture, and opening *it* in the editor starts
from those pixels — a filter on top of a filter, a crop that can't be widened again. So when Save as New writes
a copy, the edit that made it (photo_edit's `Edit`, as JSON) is kept here with the two paths, and the editor
offers **Edits ▾ ▸ Edit Again from the Original**: the original is opened with that edit on it, and saving
writes over the edited copy — the original is never touched.

Kept on this Mac (`Application Support/…/Edits`, a small JSON file per edited copy — nothing is added to the
drive or to the photo). A record only counts while both files are the ones it was made from: the copy and the
original each as they were (size and modified date). Change either — crop the copy, overwrite the original —
and the record no longer applies, because "edit again" would then quietly undo that change. A copy that's
renamed or moved loses its record too (it's found by its path); nothing else is lost by that — the copy is a
finished picture either way.

No Qt here.
"""
from __future__ import annotations

import hashlib
import json
import os
import time
import unicodedata
from pathlib import Path

import app_identity

FORMAT = "photobrowser-edit"
MOST = 3000                              # records kept; the oldest go first


def folder() -> Path:
    return app_identity.support() / "Edits"


def _file(result: str) -> Path:
    key = unicodedata.normalize("NFC", os.path.abspath(result))
    return folder() / (hashlib.sha1(key.encode("utf-8", "surrogatepass")).hexdigest() + ".json")


def _stamp(path: str) -> list[int] | None:
    try:
        st = os.stat(path)
    except OSError:
        return None
    return [int(st.st_size), int(st.st_mtime_ns)]


def remember(source: str, result: str, edit: dict) -> bool:
    """`result` was made from `source` by `edit` (photo_edit.to_dict). Best effort: False when it couldn't be
    kept (the save itself has already succeeded)."""
    a, b = _stamp(source), _stamp(result)
    if a is None or b is None or os.path.abspath(source) == os.path.abspath(result):
        return False
    doc = {"format": FORMAT, "version": 1, "source": os.path.abspath(source), "result": os.path.abspath(result),
           "source_stamp": a, "result_stamp": b, "at": round(time.time(), 3), "edit": edit}
    try:
        folder().mkdir(parents=True, exist_ok=True)
        file = _file(result)
        tmp = file.with_suffix(".saving")
        tmp.write_text(json.dumps(doc, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
        os.replace(tmp, file)
        _prune()
        return True
    except (OSError, TypeError, ValueError):
        return False


def find(path: str) -> dict | None:
    """The record for the edited copy at `path` — {"source", "result", "edit", "at"} — while it still applies
    (see the module notes). None otherwise."""
    try:
        doc = json.loads(_file(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    if not isinstance(doc, dict) or doc.get("format") != FORMAT or not isinstance(doc.get("edit"), dict):
        return None
    source, result = str(doc.get("source") or ""), str(doc.get("result") or "")
    if not source or os.path.abspath(path) != result:
        return None
    if _stamp(result) != doc.get("result_stamp") or _stamp(source) != doc.get("source_stamp"):
        return None
    return {"source": source, "result": result, "edit": doc["edit"], "at": float(doc.get("at") or 0)}


def forget(path: str) -> None:
    try:
        _file(path).unlink()
    except OSError:
        pass


def _prune() -> None:
    try:
        files = [p for p in folder().iterdir() if p.suffix == ".json"]
        if len(files) <= MOST:
            return
        files.sort(key=lambda p: p.stat().st_mtime)
        for p in files[:len(files) - MOST]:
            p.unlink()
    except OSError:
        pass
