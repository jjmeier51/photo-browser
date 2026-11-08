"""Safe Finder ↔ CapCut (the desktop video editor): clips out to CapCut, finished videos back onto the drive.
capcut_window.py is the tray and the import window; this is the part with no Qt, testable on its own.

**Why not write CapCut projects.** CapCut keeps its projects as drafts (`~/Movies/CapCut/User Data/Projects/
com.lveditor.draft/…/draft_content.json`), but recent versions encrypt that file and reject drafts built from
another version's template, and nothing about it is documented — a project written from here would break with
the next CapCut update, or worse, damage the person's drafts. So the hand-off uses only what every CapCut takes:

- **Out** (`Session`, `order`, `stage`): the clips in timeline order — by date taken (default), by name, or as
  selected — handed to CapCut the way a person would, by dragging them from the tray into CapCut's media panel or
  timeline (the files themselves, where they are on the drive; CapCut refers to them there). "Copy to this Mac
  first" copies them into `~/Movies/Safe Finder for CapCut/<session>/` (numbered, so name order = timeline order)
  for a project that must work with the drive unplugged. Each send is a session in the record.
- **Back** (`exports`, `bring_in`): CapCut's finished videos are wherever its Export panel saved them — it
  remembers the last folder, and there's no documented default — so the usual places are looked in
  (`candidate_folders`: ~/Movies/CapCut and the folders beside it, ~/Movies, Desktop, Downloads, Documents, and the
  same inside the Mac App Store version's container), and once a video is brought in from one, that folder is
  remembered. A video made after a session is matched to it (`session_for`): it goes back into the folder the
  clips came from, with the clips' tags, dated like the earliest clip if wanted, and tagged "capcut".

**Onto the drive** (`bring_in`): a unique name ("name 2.mp4" beside an existing one), copied by the drive's rules
(temp → fsync → rename; straight in on exFAT, CLAUDE.md #12), checked for size, then — for Move — the export
removed from the Mac (a rename when it's the same disk). The date goes in with ExifTool when it's there
(`social.write_meta`, the downloaders' QuickTime tags, which the iPhone reads).

**The record** (`~/Library/Application Support/Safe Finder/capcut.json`): the last sessions, which exports were
brought in (by path, size and time — an export copied rather than moved isn't offered again), and the export
folder.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import time
from collections import Counter
from dataclasses import asdict, dataclass, field
from pathlib import Path

BUNDLE_ID = "com.lemon.lvoverseas"          # CapCut for Mac (the App Store and capcut.com builds alike)
APP_NAME = "CapCut"
TAG = "capcut"
STAGING = "Safe Finder for CapCut"          # ~/Movies/<this>/<session>: clips copied to the Mac first
CLIP_EXT = {".mp4", ".mov", ".m4v", ".avi", ".mkv", ".webm", ".3gp", ".mts", ".m2ts",
            ".jpg", ".jpeg", ".png", ".heic", ".heif", ".gif", ".webp", ".tif", ".tiff", ".bmp"}
VIDEO_EXT = {".mp4", ".mov", ".m4v", ".avi", ".mkv", ".webm", ".3gp", ".mts", ".m2ts"}
EXPORT_EXT = {".mp4", ".mov", ".m4v"}       # what CapCut's Export panel writes
SETTLE_S = 4.0                              # an export written to in the last few seconds is still being written
MATCH_DAYS = 14                             # an export this long after a session isn't its edit any more
KEEP_SESSIONS = 60
KEEP_IMPORTED = 5000
IS_MAC = sys.platform == "darwin"
ORDERS = (("taken", "Date taken"), ("name", "Name"), ("selected", "As selected"))


def support_dir() -> Path:
    return Path.home() / "Library" / "Application Support" / "Safe Finder"


def record_file() -> Path:
    return support_dir() / "capcut.json"


# ----------------------------------------------------------------------------- CapCut itself

def find_app() -> str | None:
    """Where CapCut.app is, or None."""
    for p in (Path("/Applications") / f"{APP_NAME}.app", Path.home() / "Applications" / f"{APP_NAME}.app"):
        if p.is_dir():
            return str(p)
    if IS_MAC and shutil.which("mdfind"):
        try:
            r = subprocess.run(["mdfind", f"kMDItemCFBundleIdentifier == '{BUNDLE_ID}'"], capture_output=True,
                               text=True, timeout=5)
            for line in r.stdout.splitlines():
                if line.endswith(".app") and os.path.isdir(line):
                    return line
        except (OSError, subprocess.TimeoutExpired):
            pass
    return None


def open_app() -> str:
    """Opens (or brings forward) CapCut. Returns "" when it did, else why not."""
    if not IS_MAC:
        return "CapCut's desktop app runs on the Mac."
    for cmd in (["open", "-b", BUNDLE_ID], ["open", "-a", APP_NAME]):
        try:
            if subprocess.run(cmd, capture_output=True, timeout=15).returncode == 0:
                return ""
        except (OSError, subprocess.TimeoutExpired):
            continue
    app = find_app()
    if app:
        try:
            if subprocess.run(["open", app], capture_output=True, timeout=15).returncode == 0:
                return ""
        except (OSError, subprocess.TimeoutExpired):
            pass
    return "CapCut isn't installed on this Mac — get it from capcut.com or the Mac App Store."


# ----------------------------------------------------------------------------- clips out

def is_clip(path: str) -> bool:
    return os.path.splitext(path)[1].lower() in CLIP_EXT and not os.path.basename(path).startswith(".")


def clips_in(paths: list[str]) -> list[str]:
    """The photos and videos to send: the files selected, and those directly inside selected folders (in name
    order), each once."""
    out, seen = [], set()
    for p in paths:
        if os.path.isdir(p):
            try:
                inside = sorted((e.path for e in os.scandir(p) if e.is_file() and is_clip(e.path)),
                                key=lambda q: natural(os.path.basename(q)))
            except OSError:
                inside = []
        else:
            inside = [p] if is_clip(p) else []
        for q in inside:
            if q not in seen:
                seen.add(q)
                out.append(q)
    return out


def natural(name: str) -> list:
    return [int(t) if t.isdigit() else t.lower() for t in re.split(r"(\d+)", name)]


def taken(path: str) -> float | None:
    """When a photo or video was taken (its own metadata), else None."""
    try:
        import media_info
        if os.path.splitext(path)[1].lower() in VIDEO_EXT:
            t = media_info.video_info(path).get("created")
        else:
            t = media_info.image_info(path).get("taken")
        return float(t) if t else None
    except Exception:  # noqa: BLE001 — a file whose metadata can't be read just has no date here
        return None


def order(clips: list[str], how: str) -> list[str]:
    """The clips in timeline order: "taken" (date taken, else the file's date — oldest first), "name", or
    "selected" (as given)."""
    if how == "name":
        return sorted(clips, key=lambda p: natural(os.path.basename(p)))
    if how == "taken":
        def when(p: str) -> float:
            t = taken(p)
            if t is None:
                try:
                    t = os.path.getmtime(p)
                except OSError:
                    t = 0.0
            return t
        return sorted(clips, key=lambda p: (when(p), natural(os.path.basename(p))))
    return list(clips)


def home_folder(clips: list[str]) -> str:
    """The folder most of the clips are in."""
    if not clips:
        return ""
    return Counter(os.path.dirname(p) for p in clips).most_common(1)[0][0]


@dataclass
class Session:
    """One send to CapCut."""
    id: str
    name: str
    started: float
    clips: list[str]
    folder: str                            # where most clips came from: where its edit goes back to
    copies: list[str] = field(default_factory=list)      # the clips copied to the Mac first, when they were

    @classmethod
    def new(cls, clips: list[str]) -> "Session":
        folder = home_folder(clips)
        now = time.time()
        stamp = time.strftime("%b %d, %H.%M", time.localtime(now))
        return cls(str(int(now * 1000)), f"{os.path.basename(folder) or 'Clips'} — {stamp}", now, list(clips), folder)


def staging_dir(session: Session) -> Path:
    safe = re.sub(r'[/:\\]+', "-", session.name).strip() or session.id
    return Path.home() / "Movies" / STAGING / safe


def stage(session: Session, clips: list[str], progress=None, cancelled=None) -> list[str]:
    """The clips copied to the Mac (`staging_dir`), numbered in timeline order — "01 name.mp4" — so CapCut's
    Import (and Finder's name order) keep the order. Returns the copies, in order."""
    folder = staging_dir(session)
    folder.mkdir(parents=True, exist_ok=True)
    width = max(2, len(str(len(clips))))
    out = []
    for i, src in enumerate(clips, 1):
        if cancelled and cancelled():
            break
        dest = folder / f"{i:0{width}d} {os.path.basename(src)}"
        if not (dest.exists() and dest.stat().st_size == os.path.getsize(src)):
            part = dest.with_name(f".{dest.name}.part")
            shutil.copyfile(src, part)
            os.replace(part, dest)
            st = os.stat(src)
            os.utime(dest, (st.st_atime, st.st_mtime))
        out.append(str(dest))
        if progress:
            progress(i, len(clips))
    session.copies = out
    return out


# ----------------------------------------------------------------------------- the record

class Record:
    """capcut.json — the sessions, what's been brought in, and where CapCut saves its exports."""

    def __init__(self, path: Path | None = None) -> None:
        self.path = path or record_file()
        self.sessions: list[Session] = []
        self.imported: dict[str, str] = {}               # export key → where it went
        self.exports = ""                                # the folder CapCut saves into (once known)
        self.load()

    def load(self) -> None:
        try:
            doc = json.loads(self.path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return
        if not isinstance(doc, dict):
            return
        for s in doc.get("sessions") or []:
            try:
                self.sessions.append(Session(**{k: s[k] for k in ("id", "name", "started", "clips", "folder")},
                                             copies=list(s.get("copies") or [])))
            except (KeyError, TypeError):
                continue
        self.imported = {str(k): str(v) for k, v in (doc.get("imported") or {}).items()}
        self.exports = str(doc.get("exports") or "")

    def save(self) -> None:
        self.sessions = self.sessions[-KEEP_SESSIONS:]
        if len(self.imported) > KEEP_IMPORTED:
            self.imported = dict(list(self.imported.items())[-KEEP_IMPORTED:])
        doc = {"format": "safefinder-capcut", "sessions": [asdict(s) for s in self.sessions],
               "imported": self.imported, "exports": self.exports}
        self.path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.path.with_name(self.path.name + ".saving")
        tmp.write_text(json.dumps(doc, ensure_ascii=False, indent=1), encoding="utf-8")
        os.replace(tmp, self.path)

    def add(self, session: Session) -> None:
        self.sessions.append(session)
        self.save()

    def latest(self) -> Session | None:
        return self.sessions[-1] if self.sessions else None

    def session_for(self, made: float) -> Session | None:
        """The send an export made at `made` (unix time) came from: the latest one started before it, within
        MATCH_DAYS."""
        for s in reversed(self.sessions):
            if s.started <= made + 60:
                return s if made - s.started <= MATCH_DAYS * 86400 else None
        return None

    def was_imported(self, e: "Export") -> bool:
        return e.key in self.imported

    def note_imported(self, e: "Export", dest: str) -> None:
        self.imported[e.key] = dest
        folder = os.path.dirname(e.path)
        if not self.exports and folder != str(Path.home() / "Movies" / STAGING):
            self.exports = folder


# ----------------------------------------------------------------------------- videos back

@dataclass
class Export:
    """A finished video CapCut saved."""
    path: str
    size: int
    mtime: float

    @property
    def key(self) -> str:
        return f"{self.path}|{self.size}|{int(self.mtime)}"

    @property
    def name(self) -> str:
        return os.path.basename(self.path)

    def busy(self, now: float | None = None) -> bool:
        """Still being written (CapCut writes the file as it exports)."""
        return (now or time.time()) - self.mtime < SETTLE_S


def candidate_folders(record: Record | None = None, home: Path | None = None) -> list[str]:
    """Where CapCut's exports may be: the remembered folder first, then ~/Movies/CapCut (and folders inside it,
    not its "User Data"), ~/Movies, Desktop, Downloads, Documents — and the same inside the App Store version's
    container. Only folders that exist; never the clips' own staging folder."""
    home = home or Path.home()
    container = home / "Library" / "Containers" / BUNDLE_ID / "Data"
    out: list[str] = []

    def put(p: Path) -> None:
        s = str(p)
        if p.is_dir() and s not in out and STAGING not in p.parts:
            out.append(s)

    if record is not None and record.exports:
        put(Path(record.exports))
    for base in (home, container):
        capcut = base / "Movies" / APP_NAME
        put(capcut)
        try:
            for e in sorted(os.scandir(capcut), key=lambda e: e.name):
                if e.is_dir() and not e.name.startswith(".") and e.name != "User Data":
                    put(Path(e.path))
        except OSError:
            pass
        for sub in ("Movies", "Desktop", "Downloads", "Documents"):
            put(base / sub)
    return out


def exports(folders: list[str], since: float = 0.0) -> list[Export]:
    """The videos in `folders` (not inside their subfolders) made at `since` or later, newest first."""
    out: list[Export] = []
    seen: set[str] = set()
    for folder in folders:
        try:
            entries = list(os.scandir(folder))
        except OSError:
            continue
        for e in entries:
            if e.name.startswith(".") or os.path.splitext(e.name)[1].lower() not in EXPORT_EXT:
                continue
            try:
                st = e.stat()
            except OSError:
                continue
            if not e.is_file() or st.st_size <= 0 or st.st_mtime < since or e.path in seen:
                continue
            seen.add(e.path)
            out.append(Export(e.path, st.st_size, st.st_mtime))
    out.sort(key=lambda x: x.mtime, reverse=True)
    return out


def earliest_taken(clips: list[str]) -> float | None:
    """The date the earliest clip was taken — what an edit made of them is dated, when wanted."""
    dates = [t for t in (taken(c) for c in clips if os.path.exists(c)) if t]
    return min(dates) if dates else None


def clip_tags(store, clips: list[str]) -> list[str]:
    """Every tag any of the clips carries (a new file made from them gets them — CLAUDE.md's copyTags rule)."""
    tags: set[str] = set()
    if store is None:
        return []
    for c in clips:
        try:
            tags.update(store.tags(c))
        except Exception:  # noqa: BLE001 — a clip whose tags can't be read adds none
            continue
    return sorted(tags, key=str.lower)


def unique(folder: Path, name: str) -> Path:
    dest = folder / name
    if not os.path.lexists(dest):
        return dest
    stem, ext = os.path.splitext(name)
    n = 2
    while os.path.lexists(folder / f"{stem} {n}{ext}"):
        n += 1
    return folder / f"{stem} {n}{ext}"


def _same_disk(a: str, b: str) -> bool:
    try:
        return os.stat(a).st_dev == os.stat(b).st_dev
    except OSError:
        return False


def bring_in(export: Export, folder: str, move: bool, date: float | None = None, tool=None) -> str:
    """One CapCut export into a drive folder (see the module notes). Returns where it landed."""
    import simpcity as sc
    dest_dir = Path(folder)
    sc.make_folder(dest_dir)
    dest = unique(dest_dir, export.name)
    src = export.path
    st = os.stat(src)
    if move and _same_disk(src, str(dest_dir)) and not sc._on_exfat(str(dest_dir)):
        os.rename(src, dest)
    else:
        if sc._on_exfat(str(dest_dir)):
            shutil.copyfile(src, dest)
        else:
            part = dest_dir / f".{dest.name}.part"
            shutil.copyfile(src, part)
            with open(part, "rb+") as f:
                os.fsync(f.fileno())
            os.replace(part, dest)
        if os.path.getsize(dest) != st.st_size:
            try:
                os.remove(dest)
            except OSError:
                pass
            raise OSError(f"the copy of “{export.name}” came out a different size")
        os.utime(dest, (st.st_atime, st.st_mtime))
        if move:
            os.remove(src)
    if date:
        import social
        item = social.Item(export.key, dest_dir, dest.stem, True, "", ext=dest.suffix.lstrip("."), date=date,
                           keyword="CapCut")
        social.write_meta(str(dest), item, tool)
    return str(dest)
