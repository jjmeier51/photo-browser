"""Highlight folders for Photo Browser for Mac — which folders show as **bubbles** (the iPhone app's round highlights
above a folder's grid) and what a **Reviews folder** is. No Qt here; `highlight_strip.py` draws them.

**What the iPhone shows as a bubble** (`FolderView.isBubbleFolder`), and how the Mac knows each:

| kind | the iPhone keeps it in | the Mac knows it from |
|---|---|---|
| a profile folder (Instagram, Facebook, TikTok, OF) | its per-folder records | the shared record in the folder (`.instagram.json`, `.facebook.json`, `.tiktok.json`), else the iPhone's backup on the drive |
| an Instagram **highlight** ("Stories", one folder per highlight) | `instagramHighlights` | the backup; and any folder directly inside an Instagram profile folder (what the iPhone's reconnect does too) |
| an **album highlight** — any folder the person turned into one | `albumHighlights` | the drive's `folder-options.json` → `highlight` (written by both apps), else the backup |
| every folder inside a **Reviews folder** | `reviewsFolders` (the parent) | `folder-options.json` → `reviews`, else the backup |

The backup is `<drive>/.Photo Browser Metadata/metadata.json` — everything the phone knew at its last backup, by
drive-relative path — so highlights made on the iPhone show here without a new iPhone build; a choice in
`folder-options.json` (a stamp: positive on, negative off — folder_options.py) is newer than the backup and wins,
which is how "Remove from Highlights" on the Mac sticks.

**Order** (`bubbleRank`): a profile's "Stories" first, then the Instagram, Facebook, TikTok and OF profiles, then
the rest in the order dragged on the iPhone (the backup's `bubbleOrders`), else A–Z. At the drive's top, and in a
Reviews folder, plain A–Z, as on the iPhone.

**Labels**: `@handle` for Instagram / TikTok / OF, the profile's name for Facebook, else the folder's name.
A bubble's picture is the folder's cover (folder_covers.py — shared with the iPhone already).
"""
from __future__ import annotations

import json
import os
import re
import threading
import unicodedata
from dataclasses import dataclass

import folder_options

METADATA = folder_options.METADATA
BACKUP = "metadata.json"
RECORDS = (("instagram", ".instagram.json"), ("facebook", ".facebook.json"), ("tiktok", ".tiktok.json"))
RANK = {"stories": -1, "instagram": 0, "facebook": 1, "tiktok": 2, "of": 3}
NOT_HIGHLIGHTS = {"duplicates", "ai", "screenshots"}      # folders in a profile folder that the apps make themselves


@dataclass
class Bubble:
    path: str
    kind: str                # stories · instagram · facebook · tiktok · of · ig-highlight · album
    label: str

    @property
    def removable(self) -> bool:
        """An album highlight can be turned back into a plain folder; a profile or its highlights can't."""
        return self.kind == "album"


@dataclass
class Listing:
    bubbles: list[Bubble]
    reviews: bool = False            # the folder is a Reviews folder: its bubbles are large and are all it shows


def _nfc(s: str) -> str:
    return unicodedata.normalize("NFC", s)


class _Backup:
    """What the iPhone's backup says about folder roles, by drive-relative path."""

    def __init__(self, doc: dict | None = None) -> None:
        doc = doc if isinstance(doc, dict) else {}

        def names(key: str) -> set[str]:
            v = doc.get(key)
            return {_nfc(str(x)) for x in v} if isinstance(v, list) else set()

        def table(key: str) -> dict[str, dict]:
            v = doc.get(key)
            return {_nfc(str(k)): x for k, x in v.items() if isinstance(x, dict)} if isinstance(v, dict) else {}
        self.ig_highlights = names("instagramHighlights")
        self.album = names("albumHighlights")
        self.reviews = names("reviewsFolders")
        self.profiles = {"instagram": table("instagramFolders"), "facebook": table("facebookFolders"),
                         "tiktok": table("tiktokFolders"), "of": table("ofFolders")}
        orders = doc.get("bubbleOrders")
        self.orders = {_nfc(str(k)): [_nfc(str(x)) for x in v] for k, v in orders.items()
                       if isinstance(v, list)} if isinstance(orders, dict) else {}


class Highlights:
    def __init__(self, options: folder_options.FolderOptions | None = None) -> None:
        self.options = options or folder_options.default()
        self._backups: dict[str, tuple[tuple | None, _Backup]] = {}
        self._lock = threading.Lock()

    # -- the iPhone's backup
    def _backup(self, base: str | None) -> _Backup:
        if base is None:
            return _Backup()
        file = os.path.join(base, METADATA, BACKUP)
        try:
            st = os.stat(file)
            stamp = (st.st_mtime_ns, st.st_size)
        except OSError:
            stamp = None
        with self._lock:
            hit = self._backups.get(base)
            if hit and hit[0] == stamp:
                return hit[1]
        doc = None
        if stamp is not None:
            try:
                with open(file, "rb") as f:
                    doc = json.loads(f.read().decode("utf-8"))
            except (OSError, ValueError):
                doc = None
        got = _Backup(doc)
        with self._lock:
            self._backups[base] = (stamp, got)
        return got

    @staticmethod
    def _rel(base: str | None, path: str) -> str:
        if base is None:
            return os.path.abspath(path)
        rel = os.path.relpath(os.path.abspath(path), base)
        return "" if rel == "." else _nfc(rel)

    # -- one folder's own marks
    def _marked(self, option: str, marks: dict[str, float], in_backup: set[str], key: str) -> bool:
        stamp = marks.get(key, 0.0)
        return stamp > 0 if stamp else key in in_backup

    def is_album_highlight(self, folder: str) -> bool:
        base, marks = self.options.marks("highlight", folder)
        return self._marked("highlight", marks, self._backup(base).album, self._rel(base, folder))

    def is_reviews(self, folder: str) -> bool:
        base, marks = self.options.marks("reviews", folder)
        return self._marked("reviews", marks, self._backup(base).reviews, self._rel(base, folder))

    def set_album_highlight(self, folder: str, on: bool) -> None:
        """Raises OSError when the drive's file can't be written."""
        self.options.set("highlight", folder, on)

    def set_reviews(self, folder: str, on: bool) -> None:
        self.options.set("reviews", folder, on)

    def profile_kind(self, folder: str) -> str:
        """"instagram" / "facebook" / "tiktok" / "of" when `folder` is a downloaded profile's, else ""."""
        for kind, name in RECORDS:
            if os.path.isfile(os.path.join(folder, name)):
                return kind
        base = self.options.marks("highlight", folder)[0]
        if base is not None:
            rel = self._rel(base, folder)
            for kind, table in self._backup(base).profiles.items():
                if rel in table:
                    return kind
        return ""

    @staticmethod
    def _record_label(folder: str, kind: str) -> str:
        name = dict(RECORDS).get(kind)
        if not name:
            return ""
        try:
            with open(os.path.join(folder, name), "rb") as f:
                head = f.read(4096).decode("utf-8", "replace")       # the name is near the top; the ids aren't read
        except OSError:
            return ""
        key = "profile_name" if kind == "facebook" else "handle"
        m = re.search(rf'"{key}"\s*:\s*"((?:[^"\\]|\\.)*)"', head)
        if not m:
            return ""
        try:
            value = json.loads(f'"{m.group(1)}"')
        except ValueError:
            return ""
        return value if kind == "facebook" else (f"@{value}" if value else "")

    # -- a folder's bubbles
    def listing(self, folder: str) -> Listing:
        """The bubbles to show in `folder` (may read the drive: call it off the window's thread)."""
        folder = os.path.abspath(folder)
        base, marks = self.options.marks("highlight", folder)
        backup = self._backup(base)
        reviews = self.is_reviews(folder)
        in_ig_profile = self.profile_kind(folder) == "instagram"
        out: list[Bubble] = []
        try:
            with os.scandir(folder) as it:
                children = [(e.name, e.path) for e in it if not e.name.startswith(".") and e.is_dir(follow_symlinks=False)]
        except OSError:
            return Listing([], reviews)
        for name, path in children:
            rel = self._rel(base, path)
            kind = ""
            for k, record in RECORDS:
                if os.path.isfile(os.path.join(path, record)):
                    kind = k
                    break
            if not kind and base is not None:
                kind = next((k for k, table in backup.profiles.items() if rel in table), "")
            label = ""
            if kind:
                label = self._record_label(path, kind)
                if not label:
                    info = backup.profiles.get(kind, {}).get(rel, {})
                    raw = info.get("profileName") if kind == "facebook" else (info.get("handle") or info.get("username"))
                    label = (raw if kind == "facebook" else f"@{raw}") if isinstance(raw, str) and raw else ""
            elif rel in backup.ig_highlights or (in_ig_profile and name.casefold() not in NOT_HIGHLIGHTS
                                                  and not name.endswith(" Frames")):
                kind = "stories" if name == "Stories" else "ig-highlight"
            elif self._marked("highlight", marks, backup.album, rel) or reviews:
                kind = "album"
            if kind:
                out.append(Bubble(path, kind, label or name))
        top = base is not None and os.path.abspath(base) == folder
        order = {} if (top or reviews) else {p: i for i, p in enumerate(backup.orders.get(self._rel(base, folder), []))}

        def key(b: Bubble):
            from_phone = order.get(self._rel(base, b.path), 1 << 30)
            return (RANK.get(b.kind, 4), from_phone, _natural(os.path.basename(b.path)))
        out.sort(key=(lambda b: _natural(os.path.basename(b.path))) if (top or reviews) else key)
        return Listing(out, reviews)


def _natural(name: str):
    return [int(t) if t.isdigit() else t.casefold() for t in re.split(r"(\d+)", name)]


_default: Highlights | None = None


def default(settings=None) -> Highlights:
    global _default
    if _default is None:
        _default = Highlights(folder_options.default(settings))
    return _default
