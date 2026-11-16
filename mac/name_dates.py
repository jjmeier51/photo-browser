"""Set Dates from File Names — and the iPhone app's Restore Capture Dates — for Photo Browser for Mac. No Qt here
(name_dates_window.py is the window).

Many downloaded files carry their date only in their name — `johnmeier_2026_11_16_4398yr.mp4`,
`something_2025_12_16_4389348934_3498349834.jpeg` (a name, the date, then an id), as well as the usual camera and
app names (`IMG_20240613_101530`, `PXL_…`, `VID-20240613-WA0001`, "Screenshot 2024-06-13 at 10.15.30", a Unix
time). `date_in_name` reads it (metadata_edit.date_from_name — the one parser the Mac app has; a date with no
time is taken as noon, so no time zone moves its day; digits after the date that aren't a real time are an id,
not a time). The file then gets that date as its **own dates** — created and modified, together, so macOS
doesn't pull the creation date back (clone_drive.set_dates) — which is what Finder, the iPhone app's date sort and
its "Age" go by when a file has no date inside it.

Two ways to use it (`find(…, restore=…)`):
- **Dates from file names** — only files whose name holds a date.
- **Restore capture dates** — the iPhone app's (FileActions.restoreCaptureDates), for files a copy or an import
  stamped with "now": the date in the name first (it survives an export that rewrote the date inside), else the
  capture date inside the photo or video (ExifTool: DateTimeOriginal, CreateDate, the QuickTime dates…). Only
  files whose date differs are changed; the summary says how many came from the name, how many had no date.

**Into the file too** (`embed`): "never" (only the file's own dates — the default for Restore, as on the
iPhone), "missing" (also write it as the capture date of a photo or video that has none — the default for
names: the iPhone's year filter, Age and the viewer's Info read the date inside first), or "always". Written by
metadata_edit (ExifTool in place: the inode, its extended attributes and Photo Browser tags stay; the iPhone's
tags; a video's QuickTime dates in UTC). Formats ExifTool can't write (WebM, GIF, MKV…) get their file dates
only.

**Undo** (`undo`): every file's dates before are kept (`Done.before`) and put back; a capture date written into
a file isn't taken out again (the summary says so). Folders are walked (`walk`): every photo and video inside,
hidden items and app bundles skipped.
"""
from __future__ import annotations

import os
from dataclasses import dataclass, field
from datetime import datetime
from typing import Callable, Iterable

import metadata_edit as me

MEDIA_EXTS = me.PHOTO_EXTS | me.VIDEO_EXTS | me.CANT_WRITE | {".gif", ".bmp", ".heics", ".jxl"}
SKIP_BUNDLES = me.SKIP_BUNDLES
SAME = 1.0                                   # seconds: a file date this close to the one found is already right


def is_media(path: str) -> bool:
    return os.path.splitext(path)[1].lower() in MEDIA_EXTS


def walk(paths: Iterable[str], stop: Callable[[], bool] = lambda: False) -> list[str]:
    """The photos and videos among `paths` and inside any folders among them, each once, in order."""
    out: list[str] = []
    seen: set[str] = set()
    for path in paths:
        if stop():
            break
        if os.path.isdir(path) and not path.endswith(SKIP_BUNDLES):
            for root, dirs, files in os.walk(path):
                dirs[:] = sorted((d for d in dirs if not d.startswith(".") and not d.endswith(SKIP_BUNDLES)),
                                 key=str.lower)
                for name in sorted(files, key=str.lower):
                    p = os.path.join(root, name)
                    if not name.startswith(".") and is_media(p) and p not in seen:
                        seen.add(p)
                        out.append(p)
                if stop() or len(out) >= me.WALK_LIMIT:
                    break
        elif os.path.isfile(path) and is_media(path) and path not in seen:
            seen.add(path)
            out.append(path)
    return out


def date_in_name(path: str, pattern: str = "", now: datetime | None = None) -> datetime | None:
    """The date (and time, when there is one) in the file's name — see the module notes."""
    return me.date_from_name(os.path.basename(path), pattern, now)


@dataclass
class Found:
    path: str
    when: datetime | None = None             # the date to give it (wall-clock, this Mac's time)
    source: str = ""                         # "name" | "inside" | ""
    file_date: float = 0.0                   # its modified date now
    capture: datetime | None = None          # the capture date inside it now (when it was read)
    offset: str = ""                         # that date's zone
    video: bool = False
    writable: bool = False                   # ExifTool can write its capture date
    embed: bool = False                      # the capture date will be written too

    @property
    def changes(self) -> bool:
        return self.when is not None and (abs(self.file_date - self.when.timestamp()) >= SAME or self.embed)

    @property
    def why(self) -> str:
        if self.when is None:
            return "no date in its name" if self.source == "" else ""
        return ""


def find(paths: list[str], restore: bool = False, embed: str = "missing", pattern: str = "", tool=None,
         stop: Callable[[], bool] = lambda: False, progress: Callable[[int, int], None] | None = None,
         now: datetime | None = None) -> list[Found]:
    """Each file and the date it would get. `tool` (an ExifTool session, or None) reads the capture dates inside —
    needed for Restore's second source and for `embed` "missing"."""
    files = walk(paths, stop)
    infos: dict[str, me.Info] = {}
    want_inside = tool is not None and (restore or embed != "never")
    if want_inside:
        readable = [p for p in files if me.can_edit(p)]
        infos = me.read(readable, tool, stop, (lambda n: progress(n, len(files))) if progress else None)
    out: list[Found] = []
    for i, p in enumerate(files):
        if stop():
            break
        try:
            mtime = os.stat(p).st_mtime
        except OSError:
            continue
        info = infos.get(p)
        f = Found(p, file_date=mtime, capture=info.date if info else None, offset=info.offset if info else "",
                  video=me.is_video(p), writable=tool is not None and me.can_edit(p))
        d = date_in_name(p, pattern, now)
        if d is not None:
            f.when, f.source = d, "name"
        elif restore and f.capture is not None:
            f.when, f.source = f.capture, "inside"
        if f.when is not None and f.source == "name" and f.writable:
            f.embed = embed == "always" and (f.capture is None or abs((f.capture - d).total_seconds()) >= SAME) \
                or (embed == "missing" and f.capture is None and info is not None and info.read)
        out.append(f)
        if progress and i % 200 == 0:
            progress(i, len(files))
    return out


@dataclass
class Done:
    changed: list[str] = field(default_factory=list)
    embedded: list[str] = field(default_factory=list)     # a capture date was written inside
    from_name: int = 0
    from_inside: int = 0
    unchanged: int = 0
    no_date: int = 0
    failed: list[tuple[str, str]] = field(default_factory=list)
    before: dict[str, tuple[int, int, int | None]] = field(default_factory=dict)   # path → (atime, mtime, birth) ns


def _stamp(path: str) -> tuple[int, int, int | None]:
    import clone_drive
    st = os.stat(path)
    return st.st_atime_ns, st.st_mtime_ns, clone_drive.birth_ns(st) if clone_drive.IS_MAC else None


def set_file_dates(path: str, when_ns: int, keep_atime: int | None = None) -> None:
    """Creation and modification date to `when_ns` (together, where the system has creation dates). Raises
    OSError."""
    import clone_drive
    atime = keep_atime if keep_atime is not None else os.stat(path).st_atime_ns
    if clone_drive.IS_MAC and clone_drive.set_dates(path, when_ns, when_ns, atime):
        return
    os.utime(path, ns=(atime, when_ns))
    if clone_drive.IS_MAC:
        clone_drive.set_birth(path, when_ns)


def apply(found: list[Found], tool=None, stop: Callable[[], bool] = lambda: False,
          progress: Callable[[int, int], None] | None = None) -> Done:
    """Gives each file its date (see the module notes). Returns what was done — with every changed file's dates
    before, for `undo`."""
    done = Done()
    todo = [f for f in found if f.when is not None]
    done.no_date = len(found) - len(todo)
    for i, f in enumerate(todo):
        if stop():
            break
        if progress and i % 20 == 0:
            progress(i, len(todo))
        if not f.changes:
            done.unchanged += 1
            continue
        try:
            before = _stamp(f.path)
        except OSError as e:
            done.failed.append((f.path, e.strerror or str(e)))
            continue
        try:
            if f.embed and tool is not None:
                z = f.offset or me.local_offset(f.when)
                ch = me.Change(f.path, f.video, f.capture, after=f.when, offset=z,
                               args=me.date_args(f.video, f.when, z), file_when=me.aware(f.when, z))
                result, why = me.write(ch, tool)
                if result == "failed":
                    raise OSError(why or "ExifTool couldn't write it")
                done.embedded.append(f.path)
            set_file_dates(f.path, int(f.when.timestamp() * 1_000_000_000), before[0])
        except OSError as e:
            done.failed.append((f.path, e.strerror or str(e)))
            continue
        done.before[f.path] = before
        done.changed.append(f.path)
        if f.source == "name":
            done.from_name += 1
        else:
            done.from_inside += 1
        try:
            import clone_drive                       # the drive's checksum record mustn't take this for damage
            clone_drive.forget_checksum(f.path)
        except Exception:  # noqa: BLE001
            pass
    if progress:
        progress(len(todo), len(todo))
    return done


def undo(done: Done) -> int:
    """The changed files' own dates put back as they were. Returns how many."""
    import clone_drive
    n = 0
    for path, (atime, mtime, birth) in done.before.items():
        try:
            if clone_drive.IS_MAC and birth is not None and clone_drive.set_dates(path, birth, mtime, atime):
                n += 1
                continue
            os.utime(path, ns=(atime, mtime))
            if clone_drive.IS_MAC and birth is not None:
                clone_drive.set_birth(path, birth)
            n += 1
        except OSError:
            pass
    return n


def summary(done: Done, restore: bool) -> str:
    """The iPhone's words for Restore Capture Dates, and the same shape for names."""
    n = len(done.changed)
    what = "to their capture date" if restore else "to the date in their name"
    line = f"Set {n:,} item{'s' if n != 1 else ''} {what}."
    if restore and done.from_name:
        line += f" {done.from_name:,} from the file name."
    if done.embedded:
        line += f" {len(done.embedded):,} also got it as their capture date inside."
    if done.unchanged:
        line += f" {done.unchanged:,} already had it."
    if done.no_date:
        line += f" {done.no_date:,} had no date{' in their name' if not restore else ''}."
    if done.failed:
        line += f" {len(done.failed):,} couldn't be changed."
    return line
