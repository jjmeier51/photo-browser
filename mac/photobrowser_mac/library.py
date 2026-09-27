"""Volumes and folder listings — the "drive" side of the app.

`list_volumes()` finds mounted drives (macOS `/Volumes`, plus the Linux mount points so the app
also runs there), `scan()` lists one folder non-recursively, classifying entries by extension the
same way the iOS app's `classify(url:)` does. Nothing here touches metadata; that's `exiftool.py`.
"""

from __future__ import annotations

import os
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

IMAGE_EXT = {".jpg", ".jpeg", ".png", ".heic", ".heif", ".gif", ".tif", ".tiff", ".webp", ".bmp",
             ".dng", ".cr2", ".cr3", ".nef", ".arw", ".raf", ".rw2", ".orf", ".avif"}
VIDEO_EXT = {".mov", ".mp4", ".m4v", ".avi", ".mkv", ".webm", ".3gp", ".mts", ".m2ts"}
HIDDEN_PREFIXES = (".", "._")


@dataclass(frozen=True)
class Entry:
    path: str
    name: str
    is_dir: bool
    size: int
    mtime: float

    @property
    def ext(self) -> str:
        return os.path.splitext(self.name)[1].lower()

    @property
    def kind(self) -> str:
        if self.is_dir:
            return "folder"
        if self.ext in IMAGE_EXT:
            return "image"
        if self.ext in VIDEO_EXT:
            return "video"
        return "other"

    @property
    def is_media(self) -> bool:
        return self.kind in ("image", "video")

    @property
    def cache_key(self) -> str:
        """Same scheme as the iOS thumbnail cache: an in-place edit changes mtime/size → new key."""
        return f"{self.path}|{int(self.mtime)}|{self.size}"


@dataclass(frozen=True)
class Volume:
    name: str
    path: str
    removable: bool


def list_volumes() -> list[Volume]:
    """Mounted drives the user can browse. On macOS every entry of /Volumes (the boot volume
    included, so an internal folder works too); on Linux the usual media mount points."""
    out: list[Volume] = []
    roots: Iterable[str]
    if sys.platform == "darwin":
        roots = ["/Volumes"]
    else:
        user = os.environ.get("USER", "")
        roots = [f"/media/{user}", "/media", "/mnt", "/run/media/" + user]
    seen = set()
    for root in roots:
        try:
            names = sorted(os.listdir(root), key=str.lower)
        except OSError:
            continue
        for n in names:
            p = os.path.join(root, n)
            if n.startswith(".") or not os.path.isdir(p):
                continue
            real = os.path.realpath(p)
            if real in seen:
                continue
            seen.add(real)
            removable = real != "/" and not real.startswith("/System")
            out.append(Volume(name=n, path=p, removable=removable))
    return out


def scan(folder: str) -> list[Entry]:
    """Immediate contents of `folder`: subfolders first (A–Z), then media files. Hidden files and
    macOS AppleDouble `._` sidecars (which exFAT drives written from a Mac are full of) are skipped."""
    entries: list[Entry] = []
    try:
        with os.scandir(folder) as it:
            for de in it:
                name = de.name
                if name.startswith(HIDDEN_PREFIXES):
                    continue
                try:
                    st = de.stat(follow_symlinks=False)
                    is_dir = de.is_dir(follow_symlinks=True)
                except OSError:
                    continue
                e = Entry(path=de.path, name=name, is_dir=is_dir,
                          size=0 if is_dir else st.st_size, mtime=st.st_mtime)
                if is_dir or e.is_media:
                    entries.append(e)
    except OSError:
        return []
    entries.sort(key=lambda e: (not e.is_dir, e.name.lower()))
    return entries


def human_size(n: int) -> str:
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or unit == "TB":
            return f"{n:.0f} {unit}" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.1f} TB"


def unique_path(folder: str, name: str, taken: set[str] | None = None) -> str:
    """`name` in `folder`, or `name 1`, `name 2`… if it exists (or is already claimed in `taken`)."""
    base, ext = os.path.splitext(name)
    candidate = name
    n = 1
    taken = taken or set()
    while os.path.exists(os.path.join(folder, candidate)) or candidate.lower() in taken:
        candidate = f"{base} {n}{ext}"
        n += 1
    return candidate


def config_dir() -> Path:
    if sys.platform == "darwin":
        d = Path.home() / "Library" / "Application Support" / "PhotoBrowserMac"
    else:
        d = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "PhotoBrowserMac"
    d.mkdir(parents=True, exist_ok=True)
    return d


def cache_dir() -> Path:
    if sys.platform == "darwin":
        d = Path.home() / "Library" / "Caches" / "PhotoBrowserMac"
    else:
        d = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "PhotoBrowserMac"
    d.mkdir(parents=True, exist_ok=True)
    return d
