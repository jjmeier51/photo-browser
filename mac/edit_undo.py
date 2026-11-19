"""Undo for photos changed in place — a crop, a batch crop, a rotate, Overwrite Original in the photo editor, Paste
Edits, Erase Area / Remove Objects / Remove Watermark with Replace, AI Upscale in place. No Qt here.

Every one of those ends in `batch_crop.write_in_place(path, data, label=…)`, and that's where this hooks in:
**before the photo's bytes are replaced, the bytes it had are kept** (`before_write`) in a folder on this Mac
(`~/Library/Application Support/<app>/Undo` — never on the drive), together with what the new bytes are
(`after_write`: their SHA-1). The writes of one go — one thread, one label, with no long gap between them — are an
`Operation` (a loop over many photos says so with `batch()`, so slow ones — an AI upscale — stay one step); the main
window collects finished ones (`drain`) and puts each on its undo stack as one step: Edit ▸ Undo (⌘Z) and the
toast's Undo button.

**Undoing** (`restore`) puts each photo's kept bytes back the way an edit is written (same name, attributes and
dates) — but only where the photo is still what the edit left (its SHA-1): one edited again since, or by something
else, is left alone and counted, never overwritten with something older than the person expects. Dates never
changed (an in-place edit keeps them), so the photo is byte for byte what it was.

**What's kept, and for how long**: originals up to `ONE_MOST` each and `STORE_MOST` together (the oldest steps'
go first — their Undo then says the original is no longer kept); everything goes when the app starts, since the
undo stack itself doesn't outlive the app.

Not here: videos (a rotate is undone by turning it back; an upscale that replaces isn't kept — the files are
gigabytes) and metadata edits (ExifTool's own).
"""
from __future__ import annotations

import hashlib
import os
import shutil
import tempfile
import threading
import time
import uuid
from dataclasses import dataclass, field
from pathlib import Path

ONE_MOST = 400 * 1024 * 1024          # a photo larger than this isn't kept (none is; a guard)
STORE_MOST = 6 * 1024 ** 3            # the originals kept, all steps together
QUIET = 8.0                           # seconds without another write before a step counts as finished
OP_TAGS = ("cropped", "edited", "retouched", "upscaled")     # the tags these edits add (taken off again on undo)

# Files being worked on in the Mac's temp folder (a downloader upscaling what it just fetched) aren't the person's
# photos yet: nothing is kept for them.
SKIP_UNDER = sorted({os.path.join(os.path.realpath(t), "") for t in (tempfile.gettempdir(), "/tmp", "/private/tmp")})

_local = threading.local()
_lock = threading.Lock()
_open: dict[tuple, "Operation"] = {}
_done: list["Operation"] = []
_all: list["Operation"] = []                                 # every step still holding originals, oldest first
tags_before = None                                           # the app's: path → the tags it has now (a list), or None


@dataclass
class Kept:
    path: str
    backup: str                       # the original's bytes ("" when they couldn't be kept)
    after_sha: str = ""               # what the edit wrote
    tags: list[str] | None = None     # the photo's tags before the edit (None: not known)
    size: int = 0


@dataclass
class Operation:
    label: str
    folder: str
    entries: list[Kept] = field(default_factory=list)
    last: float = 0.0
    closed: bool = False
    held: bool = False                # made inside `batch()`: finished when the batch is, however long a photo takes

    @property
    def paths(self) -> list[str]:
        return [e.path for e in self.entries]

    def title(self) -> str:
        n = len(self.entries)
        return self.label if n == 1 else f"{self.label} of {n:,} Photos"


def store() -> Path:
    env = os.environ.get("PHOTO_BROWSER_UNDO")
    if env:
        return Path(env)
    import app_identity
    return app_identity.support() / "Undo"


def clear() -> None:
    """At launch: last session's originals go (its undo steps went with it)."""
    shutil.rmtree(store(), ignore_errors=True)
    with _lock:
        _open.clear()
        _done.clear()
        _all.clear()


def _sha(data: bytes) -> str:
    return hashlib.sha1(data).hexdigest()


def _file_sha(path: str) -> str:
    h = hashlib.sha1()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def _make_room(need: int) -> None:
    """Under the lock: the oldest steps' originals go until `need` more bytes fit."""
    total = sum(e.size for op in _all for e in op.entries if e.backup)
    while _all and total + need > STORE_MOST:
        old = _all[0]
        if not old.closed and old in _open.values():
            break                                    # the step being made now: nothing older is left
        _all.pop(0)
        total -= sum(e.size for e in old.entries if e.backup)
        shutil.rmtree(old.folder, ignore_errors=True)
        for e in old.entries:
            e.backup = ""


def before_write(path: str, label: str = "Edit") -> Kept | None:
    """Keeps the photo's bytes as they are now. None when undo is off for this thread (a restore under way) or
    they couldn't be kept — the edit goes ahead either way."""
    if getattr(_local, "restoring", False):
        return None
    full = os.path.realpath(path)
    if any(full.startswith(t) for t in SKIP_UNDER):          # a download being finished in the temp folder: not an edit
        return None
    try:
        size = os.path.getsize(path)
    except OSError:
        return None
    key = (_owner(), label)
    now = time.monotonic()
    with _lock:
        op = _open.get(key)
        held = getattr(_local, "batch", 0) > 0
        if op is None or op.closed or (now - op.last > QUIET and not (held and op.held)):
            if op is not None and not op.closed:
                op.closed = True
                _done.append(op)
            op = Operation(label, str(store() / uuid.uuid4().hex[:12]), held=held)
            _open[key] = op
            _all.append(op)
        op.last = now
        if size <= ONE_MOST:
            _make_room(size)
    kept = Kept(path, "", size=size)
    if size <= ONE_MOST:
        try:
            os.makedirs(op.folder, exist_ok=True)
            backup = os.path.join(op.folder, f"{len(op.entries):05d}{os.path.splitext(path)[1].lower()}")
            shutil.copyfile(path, backup)
            kept.backup = backup
        except OSError:
            kept.backup = ""
    if tags_before is not None:
        try:
            kept.tags = list(tags_before(path))
        except Exception:  # noqa: BLE001 — tags are a nicety here
            kept.tags = None
    kept._op = op                                     # type: ignore[attr-defined]
    return kept


def after_write(kept: Kept | None, data: bytes) -> None:
    """The edit is written: noted, with what it wrote."""
    if kept is None:
        return
    kept.after_sha = _sha(data)
    op: Operation = kept._op                          # type: ignore[attr-defined]
    with _lock:
        op.entries.append(kept)
        op.last = time.monotonic()


def failed(kept: Kept | None) -> None:
    """The write didn't happen: the copy kept for it goes."""
    if kept is not None and kept.backup:
        try:
            os.remove(kept.backup)
        except OSError:
            pass


_groups: dict[str, int] = {}                                 # a named batch → how many threads are in it


class batch:
    """`with edit_undo.batch():` round a loop that changes many photos (on the thread doing it): they're one undo
    step however long each takes, finished the moment the loop is. Several threads sharing the work give the same
    `group` name — the step is finished when the last of them is."""

    def __init__(self, group: str = "") -> None:
        self.group = group

    def __enter__(self):
        _local.batch = getattr(_local, "batch", 0) + 1
        if self.group:
            _local.group = self.group
            with _lock:
                _groups[self.group] = _groups.get(self.group, 0) + 1
        return self

    def __exit__(self, *exc) -> bool:
        _local.batch -= 1
        who = _owner()
        last = True
        if self.group:
            with _lock:
                _groups[self.group] = _groups.get(self.group, 1) - 1
                last = _groups[self.group] <= 0
                if last:
                    del _groups[self.group]
            _local.group = ""
        if _local.batch <= 0 and last:
            with _lock:
                for key, op in list(_open.items()):
                    if key[0] == who and not op.closed:
                        op.closed = True
                        _done.append(op)
                        del _open[key]
        return False


def batched(fn, group: str = ""):
    """`fn` to run inside a `batch` — for a thread's target: `Thread(target=edit_undo.batched(work))`."""
    def run(*args, **kwargs):
        with batch(group):
            return fn(*args, **kwargs)
    return run


def _owner():
    """Whose step a write on this thread belongs to: its named batch, else the thread itself."""
    return getattr(_local, "group", "") or threading.get_ident()


def finish(label: str | None = None) -> None:
    """The steps under way (with this label, or all of them) are complete now — don't wait for the quiet."""
    with _lock:
        for key, op in list(_open.items()):
            if (label is None or op.label == label) and not op.closed:
                op.closed = True
                _done.append(op)
                del _open[key]


def drain() -> list[Operation]:
    """The steps that are finished (closed, or quiet for `QUIET` seconds) and hold something — each handed out
    once, for the undo stack."""
    now = time.monotonic()
    with _lock:
        for key, op in list(_open.items()):
            if not op.closed and not op.held and now - op.last > QUIET:
                op.closed = True
                _done.append(op)
                del _open[key]
        out = [op for op in _done if op.entries]
        _done.clear()
    return out


@dataclass
class Restored:
    paths: list[str]                  # put back as they were
    changed: list[str]                # edited again since: left alone
    gone: list[str]                   # the photo isn't there any more
    unkept: list[str]                 # its original wasn't kept (too large, or dropped to make room)
    tags: dict[str, list[str]]        # path → the op tags the edit added (the app takes them off)


def restore(op: Operation) -> Restored:
    """Puts every photo of the step back as it was (module notes). The step's originals are dropped afterwards."""
    import batch_crop
    out = Restored([], [], [], [], {})
    _local.restoring = True
    try:
        for e in op.entries:
            if not os.path.isfile(e.path):
                out.gone.append(e.path)
                continue
            if not e.backup or not os.path.isfile(e.backup):
                out.unkept.append(e.path)
                continue
            try:
                if _file_sha(e.path) != e.after_sha:
                    out.changed.append(e.path)
                    continue
                with open(e.backup, "rb") as f:
                    data = f.read()
                batch_crop.write_in_place(e.path, data)
            except OSError:
                out.changed.append(e.path)
                continue
            out.paths.append(e.path)
            if e.tags is not None:
                had = {t.casefold() for t in e.tags}
                out.tags[e.path] = [t for t in OP_TAGS if t not in had]
    finally:
        _local.restoring = False
    with _lock:
        if op in _all:
            _all.remove(op)
    shutil.rmtree(op.folder, ignore_errors=True)
    return out


def summary(op: Operation, r: Restored) -> str:
    n = len(r.paths)
    parts = [f"Put {n:,} photo{'s' if n != 1 else ''} back as {'they were' if n != 1 else 'it was'}." if n else ""]
    if r.changed:
        parts.append(f"{len(r.changed):,} changed again since and {'were' if len(r.changed) != 1 else 'was'} left alone.")
    if r.unkept:
        parts.append(f"{len(r.unkept):,} original{'s' if len(r.unkept) != 1 else ''} no longer kept.")
    if r.gone:
        parts.append(f"{len(r.gone):,} not there any more.")
    return " ".join(p for p in parts if p) or f"Nothing to undo for {op.title()}."
