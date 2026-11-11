#!/usr/bin/env python3
"""Renaming on the drive without losing what's attached to the names — Safe Finder's Rename, Rename Files…
(many at once, by a pattern) and "Remove Leading Spaces from Names…" (no Qt here).

    python3 mac/rename_tools.py "/Volumes/SSD/Some Folder"            # dry run: what would be renamed
    python3 mac/rename_tools.py "/Volumes/SSD/Some Folder" --apply

**Leading spaces.** A name that starts with a space (or a tab, a no-break space, a zero-width space…) sorts
before everything else and is easy to mistype; downloads and exports leave them behind. `leading_space_plan`
finds every file and folder under a folder whose name starts with one and plans the name without it —
never onto a name that's taken (" a.jpg" beside "a.jpg" becomes "a 2.jpg"), never to a hidden name (" .x"
is left alone) and never to an empty one. Folders are renamed too, deepest items first.

**Many at once** (`bulk_plan`, `apply_bulk`). A pattern makes each name — `{n}` a number, `{name}` the name it
has, `{date}` `{time}` (and `{year}` `{month}` `{day}` …) the capture date, `{folder}`, `{camera}`, `{width}`
`{height}` — with the items numbered in an order: by **capture date** (a photo's EXIF, a video's own creation
date; the file's date when there's none), name, file dates, size, or as they're given. So "the photos in the order
they were taken, called 1, 2, 3…" is the pattern `{n}` ordered by capture date. Find/replace works on `{name}`.
Extensions are kept; two that come out the same are told apart (" 2"); a name taken by something outside the batch
stops the whole thing before it starts. Names may trade places within a batch — `apply_bulk` goes through passing
names when they do, and puts back any item whose new name it couldn't have.

**What follows a rename** (`apply`):
- the tags, Favorites and To AI in the shared tag file (`TagStore.renamed` — a folder's contents too);
- everything the iPhone app keeps by path on the phone — captions, covers, birthdays, hidden items, the
  downloaders' folder records, TikTok likes — through the **rename journal**: each rename is noted in the
  drive's `.Photo Browser Metadata/renames.json` (original path → final path, drive-relative), and the app
  applies the ones it hasn't yet the next time it opens the drive (`RenameJournal.swift` → `itemsMoved`).
  Without it a rename on the Mac would orphan them, exactly as a rename in Finder does.
The journal keeps the last 20,000 renames from the last 180 days.
"""
from __future__ import annotations

import json
import os
import sys
import time
import unicodedata
import uuid
from dataclasses import dataclass
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import spare_folders  # noqa: E402

METADATA = ".Photo Browser Metadata"
JOURNAL = "renames.json"
FORMAT = "photobrowser-renames"
KEEP, KEEP_DAYS = 20_000, 180
INVISIBLE = "​‌‍⁠﻿"          # zero-width characters: not "space" to Python, a space to the eye


@dataclass
class Rename:
    old: str                  # the full path now
    new: str                  # the full path it gets (its parent as it is *now* — parents are renamed after)
    is_dir: bool
    final: str = ""           # where it ends up once the folders above it are renamed too


@dataclass
class Result:
    done: list[Rename]
    failed: list[tuple[Rename, str]]
    skipped: list[tuple[str, str]]          # (path, why) — from the plan


# ----------------------------------------------------------------------------- names

def without_leading_space(name: str) -> str:
    i = 0
    while i < len(name) and (name[i].isspace() or name[i] in INVISIBLE):
        i += 1
    return name[i:]


def free_name(folder: str, name: str, taken: set[str]) -> str:
    """`name`, or "stem 2.ext", "stem 3.ext"… — the first that's neither in `folder` nor in `taken` (compared
    without case: the drive may not tell "A.jpg" from "a.jpg")."""
    def busy(n: str) -> bool:
        return n.casefold() in taken or os.path.lexists(os.path.join(folder, n))
    if not busy(name):
        return name
    stem, ext = os.path.splitext(name)
    n = 2
    while busy(f"{stem} {n}{ext}"):
        n += 1
    return f"{stem} {n}{ext}"


def leading_space_plan(folder: str, recursive: bool = True, stop=lambda: False) -> tuple[list[Rename], list[tuple[str, str]]]:
    """→ (renames, skipped). The renames are in the order to make them: each folder's own items first, deeper
    folders before the ones above them. `final` is each item's path once every folder above it is renamed."""
    plan: list[Rename] = []
    skipped: list[tuple[str, str]] = []

    def walk(d: str, final_d: str) -> None:
        if stop():
            return
        try:
            with os.scandir(d) as it:
                entries = sorted(it, key=lambda e: e.name)
        except OSError as e:
            skipped.append((d, f"couldn't be read ({e.strerror or e})"))
            return
        taken: set[str] = set()
        here: list[Rename] = []
        subdirs: list[tuple[str, str]] = []
        for e in entries:
            if e.name.startswith(".") or e.name == "Icon\r":
                continue
            try:
                is_dir = e.is_dir(follow_symlinks=False)
            except OSError:
                continue
            fixed = without_leading_space(e.name)
            target_name = e.name
            if fixed != e.name:
                if not fixed:
                    skipped.append((e.path, "its name is nothing but spaces"))
                elif fixed.startswith("."):
                    skipped.append((e.path, "it would become a hidden item"))
                else:
                    target_name = free_name(d, fixed, taken)
                    taken.add(target_name.casefold())
                    here.append(Rename(e.path, os.path.join(d, target_name), is_dir,
                                       os.path.join(final_d, target_name)))
            if is_dir and recursive and not e.is_symlink():
                subdirs.append((e.path, os.path.join(final_d, target_name)))
        for sub, final_sub in subdirs:                       # the inside first: its paths are still the old ones
            walk(sub, final_sub)
        plan.extend(here)

    walk(os.path.abspath(folder), os.path.abspath(folder))
    return plan, skipped


def single(path: str, new_name: str) -> Rename:
    """One item renamed by hand. Raises ValueError with a sentence when the name can't be used."""
    new_name = unicodedata.normalize("NFC", new_name.strip("\n\r"))
    folder = os.path.dirname(os.path.abspath(path))
    if not new_name or new_name in (".", ".."):
        raise ValueError("Type a name.")
    if "/" in new_name or ":" in new_name:
        raise ValueError("A name can't contain “/” or “:”.")
    if spare_folders.on_exfat(folder) and any(c in new_name for c in '\\*?"<>|'):
        raise ValueError('On this drive a name can\'t contain  \\ * ? " < > |')
    if len(new_name.encode("utf-8")) > 255:
        raise ValueError("That name is too long.")
    target = os.path.join(folder, new_name)
    same_file = os.path.basename(path).casefold() == new_name.casefold()      # only its capitals change
    if os.path.lexists(target) and not same_file:
        raise ValueError(f"“{new_name}” is already taken in this folder.")
    return Rename(os.path.abspath(path), target, os.path.isdir(path), target)


# ----------------------------------------------------------------------------- many names at once

ORDERS = [("capture", "Capture date"), ("name", "Name"), ("modified", "Date modified"), ("created", "Date created"),
          ("size", "Size"), ("given", "The order they're in now")]
PRESETS = [("1, 2, 3 …", "{n}"), ("Photo 1, Photo 2 …", "Photo {n}"),
           ("The capture date and time — 2024-03-15 14.30.05", "{date} {time}"),
           ("The capture date, then a number — 2024-03-15 1", "{date} {n}"),
           ("The capture date, then the name it has", "{date} {name}"),
           ("The folder's name and a number — Paris 1", "{folder} {n}"),
           ("The name it has (for Find and Replace)", "{name}")]
TOKENS = ("n", "name", "date", "time", "year", "month", "day", "hour", "minute", "second", "folder", "camera",
          "width", "height")
TOKEN_HELP = ("{n} a number · {name} the name now · {date} {time} the capture date · {year} {month} {day} · "
              "{folder} · {camera} · {width} {height}")


@dataclass
class Facts:
    """What a name can be made from."""
    path: str
    stem: str
    ext: str                  # with its dot, as it is
    is_dir: bool
    folder: str               # the name of the folder it's in
    when: float               # the capture date — or the file's own date when it has none
    has_capture: bool
    modified: float
    created: float
    size: int
    width: int = 0
    height: int = 0
    camera: str = ""


def facts(path: str) -> Facts:
    """Reads one item: its capture date from the file itself (a photo's EXIF, a video's own creation date —
    media_info), else the file's modification date."""
    path = os.path.abspath(path)
    st = os.stat(path)
    is_dir = os.path.isdir(path)
    name = os.path.basename(path)
    stem, ext = (name, "") if is_dir else os.path.splitext(name)
    info: dict = {}
    if not is_dir:
        try:
            import media_info
            info = media_info.video_info(path) or media_info.image_info(path)
        except Exception:  # noqa: BLE001 — a file that can't be read as a photo or video has only its dates
            info = {}
    taken = info.get("taken") or info.get("created")
    created = getattr(st, "st_birthtime", None) or st.st_mtime
    return Facts(path, stem, ext, is_dir, os.path.basename(os.path.dirname(path)),
                 float(taken) if taken else st.st_mtime, bool(taken), st.st_mtime, created, st.st_size,
                 int(info.get("width") or 0), int(info.get("height") or 0), str(info.get("camera") or ""))


def natural_key(name: str):
    """"IMG_9" before "IMG_10"."""
    import re
    return [int(x) if x.isdigit() else x.casefold() for x in re.split(r"(\d+)", name)]


def ordered(items: list[Facts], order: str, descending: bool = False) -> list[Facts]:
    """`items` in the order they're numbered by; ties go by name (so two shots in one second stay in order)."""
    if order == "given":
        out = list(items)
    else:
        key = {"capture": lambda f: f.when, "modified": lambda f: f.modified, "created": lambda f: f.created,
               "size": lambda f: f.size, "name": lambda f: 0}[order]
        out = sorted(items, key=lambda f: (key(f), natural_key(f.stem), f.ext.casefold()))
    return out[::-1] if descending else out


def clean_name(name: str, exfat: bool) -> str:
    """What a pattern made, as a name a folder can hold: no "/" or ":" (nor exFAT's others), no leading or
    trailing spaces or trailing dots."""
    bad = '/:' + ('\\*?"<>|' if exfat else "")
    out = "".join("-" if c in bad or ord(c) < 32 else c for c in unicodedata.normalize("NFC", name))
    return out.strip().rstrip(". ").lstrip()


def render(pattern: str, f: Facts, n: int, digits: int = 0, find: str = "", replace: str = "",
           match_case: bool = False) -> str:
    """The new name (without its extension) for `f`, the n-th item."""
    import re
    stem = f.stem
    if find:
        stem = stem.replace(find, replace) if match_case else re.sub(re.escape(find), lambda _m: replace, stem, flags=re.I)
    t = time.localtime(f.when)
    values = {"n": str(n).zfill(digits) if digits else str(n), "name": stem,
              "date": time.strftime("%Y-%m-%d", t), "time": time.strftime("%H.%M.%S", t),
              "year": time.strftime("%Y", t), "month": time.strftime("%m", t), "day": time.strftime("%d", t),
              "hour": time.strftime("%H", t), "minute": time.strftime("%M", t), "second": time.strftime("%S", t),
              "folder": f.folder, "camera": f.camera, "width": str(f.width or ""), "height": str(f.height or "")}
    return re.sub(r"\{(\w+)\}", lambda m: values.get(m.group(1).lower(), m.group(0)), pattern)


@dataclass
class BulkPlan:
    renames: list[Rename]                     # what changes, in order
    rows: list[tuple[Facts, str, str]]        # every item in order: (it, its new name, "" or what's wrong)
    problems: list[str]                       # sentences; any of them means nothing should be renamed
    no_capture: int = 0                       # items whose file date stood in for a capture date


def bulk_plan(items: list[Facts], pattern: str, order: str = "capture", descending: bool = False, start: int = 1,
              digits: int = 0, find: str = "", replace: str = "", match_case: bool = False) -> BulkPlan:
    """New names for `items` from `pattern` (TOKENS), numbered in `order` from `start`. Extensions are kept.
    Two items that would get the same name are told apart with " 2", " 3" (in order). A name that's taken by
    something that isn't being renamed, an empty name, or a hidden one is a problem — the plan says so and
    nothing should be applied."""
    import re
    exfat_cache: dict[str, bool] = {}
    seq = ordered(items, order, descending)
    uses_date = bool(re.search(r"\{(date|time|year|month|day|hour|minute|second)\}", pattern, re.I)) or order == "capture"
    unknown = sorted({m.lower() for m in re.findall(r"\{(\w+)\}", pattern)} - set(TOKENS))
    problems = [f"“{{{u}}}” isn't something a name can be made from." for u in unknown]
    if not pattern.strip():
        problems.append("Type what the names should be.")
    sources = {os.path.join(os.path.dirname(f.path), os.path.basename(f.path)).casefold() for f in items}
    taken: dict[str, int] = {}
    rows: list[tuple[Facts, str, str]] = []
    renames: list[Rename] = []
    clashes = 0
    for i, f in enumerate(seq):
        folder = os.path.dirname(f.path)
        if folder not in exfat_cache:
            exfat_cache[folder] = spare_folders.on_exfat(folder)
        stem = clean_name(render(pattern, f, start + i, digits, find, replace, match_case), exfat_cache[folder])
        wrong = ""
        if not stem:
            wrong = "the name would be empty"
        elif stem.startswith("."):
            wrong = "the name would be hidden"
        name = stem + f.ext
        key = os.path.join(folder, name).casefold()
        if not wrong:
            k = taken.get(key, 0) + 1
            taken[key] = k
            if k > 1:                                      # the same name twice in this batch: numbered apart
                while True:
                    name = f"{stem} {k}{f.ext}"
                    if os.path.join(folder, name).casefold() not in taken:
                        break
                    k += 1
                taken[os.path.join(folder, name).casefold()] = 1
            if len(name.encode("utf-8")) > 255:
                wrong = "the name would be too long"
        target = os.path.join(folder, name)
        if not wrong and target != f.path and target.casefold() not in sources and os.path.lexists(target):
            wrong = "that name is taken by something that isn't being renamed"
            clashes += 1
        rows.append((f, name, wrong))
        if not wrong and target != f.path:
            renames.append(Rename(f.path, target, f.is_dir, target))
    bad = sum(1 for _f, _n, w in rows if w)
    if clashes:
        problems.append(f"{clashes:,} of the new names {'is' if clashes == 1 else 'are'} already taken by other "
                        "items in the folder — change the pattern or where the numbers start.")
    if bad - clashes:
        problems.append(f"{bad - clashes:,} of the new names can't be used (empty, hidden or too long).")
    return BulkPlan(renames, rows, problems,
                    sum(1 for f in items if not f.has_capture and not f.is_dir) if uses_date else 0)


def apply_bulk(plan: list[Rename], tags=None, progress=lambda done, total: None, stop=lambda: False) -> Result:
    """Makes a batch of renames whose names may trade places ("2.jpg" becomes "1.jpg" while "1.jpg" becomes
    "2.jpg"). When no new name is another item's old one, it's `apply`. Otherwise in two steps: every item to
    a passing name ("renaming-<id>-<n>.ext"), then each to its new one — and an item whose new name turns out
    to be held (something failed, or was stopped) goes back to the name it had, so nothing is ever left under a
    passing name or lost. Tags, labels and the journal follow the same two steps (a passing name is a step
    for them too — an exchange can't be told in one)."""
    old_names = {r.old.casefold() for r in plan}
    if not any(r.new.casefold() in old_names and r.new.casefold() != r.old.casefold() for r in plan):
        return apply(plan, tags, progress, stop)
    token = uuid.uuid4().hex[:8]
    staged: list[tuple[Rename, str]] = []
    failed: list[tuple[Rename, str]] = []
    total = len(plan) * 2
    for i, r in enumerate(plan):
        if stop():
            break
        passing = os.path.join(os.path.dirname(r.old), f"renaming-{token}-{i}{os.path.splitext(r.old)[1] if not r.is_dir else ''}")
        try:
            os.rename(r.old, passing)
            staged.append((r, passing))
        except OSError as e:
            failed.append((r, e.strerror or str(e)))
        if i % 50 == 0:
            progress(i + 1, total)
    # Which staged items can't have their new name: it's held by something that didn't move (a file outside the
    # batch, an item that couldn't be staged, or stopped before its turn) — and then, in turn, whoever was to take
    # the name such an item is going back to. Those go back to the names they had; the rest go on.
    back: set[int] = {i for i, (r, _p) in enumerate(staged) if os.path.lexists(r.new)}
    grew = True
    while grew:
        grew = False
        reclaimed = {staged[i][0].old.casefold() for i in back}
        for i, (r, _p) in enumerate(staged):
            if i not in back and r.new.casefold() in reclaimed:
                back.add(i)
                grew = True
    done: list[tuple[Rename, str]] = []
    for i, (r, passing) in enumerate(staged):
        try:
            if i in back:
                os.rename(passing, r.old)
                failed.append((r, "its new name is in use — left as it was"))
            else:
                if os.path.lexists(r.new):
                    raise FileExistsError(17, "its new name is still in use", r.new)
                os.rename(passing, r.new)
                done.append((r, passing))
        except OSError as e:
            failed.append((r, f"it's now “{os.path.basename(passing)}” ({e.strerror or e}) — rename it by hand"))
        if i % 50 == 0:
            progress(len(plan) + i + 1, total)
    progress(total, total)
    if done:
        steps = [Rename(r.old, passing, r.is_dir, passing) for r, passing in done] + \
                [Rename(passing, r.new, r.is_dir, r.new) for r, passing in done]
        if tags is not None:
            try:
                tags.renamed([(x.old, x.new) for x in steps])
            except OSError:
                pass
        _folder_choices([(x.old, x.new) for x in steps if x.is_dir])
        note_renames(steps)
    return Result([r for r, _p in done], failed, [])


# ----------------------------------------------------------------------------- a copy beside the original

def duplicate_name(path: str) -> str:
    """"name copy.ext", then "name copy 2.ext"… — Finder's names for a duplicate."""
    folder, name = os.path.split(os.path.abspath(path))
    stem, ext = os.path.splitext(name) if not os.path.isdir(path) else (name, "")
    out = os.path.join(folder, f"{stem} copy{ext}")
    n = 2
    while os.path.lexists(out):
        out = os.path.join(folder, f"{stem} copy {n}{ext}")
        n += 1
    return out


def duplicate(path: str) -> str:
    """A copy of the file beside it (its dates and attributes too). Written under a temporary name and renamed
    once whole — straight in on exFAT (CLAUDE.md #12). Returns the copy's path. Files only."""
    import shutil
    if not os.path.isfile(path) or os.path.islink(path):
        raise OSError("only files can be duplicated")
    out = duplicate_name(path)
    st = os.stat(path)
    if spare_folders.on_exfat(os.path.dirname(out)):
        shutil.copyfile(path, out)
        target = out
    else:
        target = os.path.join(os.path.dirname(out), f".{os.path.basename(out)}.copying")
        try:
            shutil.copyfile(path, target)
            with open(target, "rb+") as f:
                os.fsync(f.fileno())
        except BaseException:
            if os.path.exists(target):
                os.remove(target)
            raise
    try:
        import shared_tags
        for name in shared_tags.xattr_names(path):
            if name in ("com.apple.quarantine", "com.photobrowser.tags"):     # the tags go through the tag store
                continue
            value = shared_tags.xattr_get(path, name)
            if value is not None:
                try:
                    shared_tags.xattr_set(target, name, value)
                except OSError:
                    pass
    except ImportError:
        pass
    if target != out:
        os.replace(target, out)
    os.utime(out, ns=(st.st_atime_ns, st.st_mtime_ns))
    return out


# ----------------------------------------------------------------------------- the journal

def drive_base(path: str) -> str | None:
    """The folder above `path` holding the app's metadata folder — the root the iPhone app browses."""
    p = os.path.abspath(path)
    for _ in range(40):
        if os.path.isdir(os.path.join(p, METADATA)):
            return p
        parent = os.path.dirname(p)
        if parent == p:
            return None
        p = parent
    return None


def note_renames(done: list[Rename]) -> int:
    """Adds the renames to their drive's journal (module notes). Items on a drive the app has never opened
    (no metadata folder) have nothing to note. Returns how many were noted."""
    by_base: dict[str, list[dict]] = {}
    now = round(time.time(), 3)
    nfc = lambda s: unicodedata.normalize("NFC", s)                      # noqa: E731 — the app's keys are NFC
    for r in done:
        base = drive_base(os.path.dirname(r.final or r.new))
        if base is None:
            continue
        old_rel, new_rel = os.path.relpath(r.old, base), os.path.relpath(r.final or r.new, base)
        if old_rel.startswith("..") or new_rel.startswith("..") or old_rel == new_rel:
            continue
        by_base.setdefault(base, []).append({"id": uuid.uuid4().hex, "from": nfc(old_rel), "to": nfc(new_rel),
                                             "dir": bool(r.is_dir), "at": now})
    noted = 0
    for base, entries in by_base.items():
        file = Path(base) / METADATA / JOURNAL
        doc: dict = {}
        try:
            doc = json.loads(file.read_bytes().decode("utf-8"))
        except (OSError, ValueError):
            doc = {}
        old = doc.get("renames") if isinstance(doc, dict) and doc.get("format") == FORMAT else []
        floor = now - KEEP_DAYS * 86400
        kept = [e for e in (old if isinstance(old, list) else [])
                if isinstance(e, dict) and float(e.get("at") or 0) >= floor]
        out = {"format": FORMAT, "version": 1, "by": "Safe Finder", "updated": now, "renames": (kept + entries)[-KEEP:]}
        data = json.dumps(out, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        try:
            if spare_folders.on_exfat(str(file.parent)):
                with open(file, "wb") as f:              # exFAT: in place — no rename, no fsync (CLAUDE.md #12)
                    f.write(data)
            else:
                tmp = file.parent / f".{JOURNAL}.saving"
                with open(tmp, "wb") as f:
                    f.write(data)
                    f.flush()
                    os.fsync(f.fileno())
                os.replace(tmp, file)
            noted += len(entries)
        except OSError:
            pass                                         # best effort: the tags have followed either way
    return noted


# ----------------------------------------------------------------------------- doing it

def _rename(old: str, new: str) -> None:
    """os.rename that never lands on another item (a name that differs only in capitals from the item itself
    is the item — a two-step rename gets there on a drive that ignores case)."""
    if os.path.lexists(new):
        try:
            same = os.path.samefile(old, new)
        except OSError:
            same = False
        if not same:
            raise FileExistsError(f"“{os.path.basename(new)}” is already there")
        tmp = os.path.join(os.path.dirname(old), f".renaming-{uuid.uuid4().hex[:8]}")
        os.rename(old, tmp)
        os.rename(tmp, new)
        return
    os.rename(old, new)


def apply(plan: list[Rename], tags=None, progress=lambda done, total: None, stop=lambda: False,
          skipped: list[tuple[str, str]] | None = None) -> Result:
    """Makes the renames in order, then carries the tags/labels (`tags`: the TagStore) and notes the journal
    for what was actually renamed. A rename that fails is reported and the rest go on."""
    done: list[Rename] = []
    failed: list[tuple[Rename, str]] = []
    for i, r in enumerate(plan):
        if stop():
            break
        try:
            _rename(r.old, r.new)
            done.append(r)
        except OSError as e:
            failed.append((r, e.strerror or str(e)))
        if i % 50 == 0:
            progress(i + 1, len(plan))
    progress(len(plan), len(plan))
    if done:
        if failed:                     # a folder that didn't get renamed: what's under it ends up under its old name
            fix_finals(done, failed)
        if tags is not None:
            try:
                tags.renamed([(r.old, r.new) for r in done])
            except OSError:
                pass
        _folder_choices([(r.old, r.new) for r in done if r.is_dir])
        note_renames(done)
    return Result(done, failed, skipped or [])


def _folder_choices(pairs: list[tuple[str, str]]) -> None:
    """A renamed folder keeps its own choices (Videos at the Top — folder_options.py)."""
    if not pairs:
        return
    try:
        import folder_options
        folder_options.default().renamed(pairs)
    except Exception:  # noqa: BLE001 — best effort: a choice lost is set again with a click
        pass


def fix_finals(done: list[Rename], failed: list[tuple[Rename, str]]) -> None:
    for bad, _why in failed:
        if not bad.is_dir:
            continue
        want = (bad.final or bad.new).rstrip("/") + "/"
        got = os.path.join(os.path.dirname(bad.final or bad.new), os.path.basename(bad.old)).rstrip("/") + "/"
        for r in done:
            if (r.final or r.new).startswith(want):
                r.final = got + (r.final or r.new)[len(want):]


def main() -> None:
    import argparse
    ap = argparse.ArgumentParser(description="Take the spaces off the start of every name under a folder.")
    ap.add_argument("folder")
    ap.add_argument("--apply", action="store_true", help="rename (default: only list what would change)")
    ap.add_argument("--top", action="store_true", help="this folder's own items only, not its subfolders'")
    a = ap.parse_args()
    plan, skipped = leading_space_plan(a.folder, recursive=not a.top)
    for r in plan:
        print(f"{'folder' if r.is_dir else 'file  '}  {r.old!r}  →  {os.path.basename(r.new)!r}")
    for path, why in skipped:
        print(f"left    {path!r}: {why}")
    if not plan:
        print("No names here start with a space.")
        return
    if not a.apply:
        print(f"\n{len(plan):,} name(s) would change. Run again with --apply to rename.")
        return
    try:
        import shared_tags
        store = shared_tags.default_store()
    except Exception:  # noqa: BLE001
        store = None
    res = apply(plan, store)
    print(f"\nRenamed {len(res.done):,}" + (f", {len(res.failed):,} couldn't be" if res.failed else "") + ".")
    for r, why in res.failed:
        print(f"  {r.old!r}: {why}")


if __name__ == "__main__":
    main()
