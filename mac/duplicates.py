"""Find Duplicates for Safe Finder — the iPhone app's (`DuplicatesView.swift`, `PerceptualHash.swift`), with the
same three kinds of group, kept apart (never chained into one another, which once made nonsense groups):

- **Exact** — the same size in bytes *and* the same pixel dimensions. Video-frame screenshots ("Frame 2.png")
  only when the name matches too: frames of one video share its dimensions and often a size.
- **Visually similar** — a 64-bit dHash (9×8 greys, a bit per "brighter than its right neighbour") within 6
  bits of another, clustered (union-find). Photos only. Tight on purpose: at 10 a photoshoot of similar poses
  chained into one "791 visually similar" group on the iPhone.
- **Similar name** — names that come to the same stem once a copy suffix is gone (" (1)", " copy 2", "-1",
  "_1", " 2", the extension): `0123.jpg`, `0123 (1).jpg`, `0123 2.jpeg`. Photos with photos and videos with
  videos — `IMG_0001.HEIC` and `IMG_0001.MOV` are a Live Photo's two halves, not copies.

A set already found as a stronger kind isn't listed again as a weaker one — nor is one that's wholly inside a
group already listed (the iPhone lists "IMG_1 / IMG_1 (1)" as a name group beside the exact group holding
both); a set whose every pair was marked **Not Duplicates** isn't listed at all (`NotDuplicates`, this Mac's).

Beyond the iPhone: **Include subfolders** (the iPhone looks at one folder), and an **Identical** check — the
files of an exact group are read through (SHA-256) in the background, so a group whose copies are byte for
byte the same says so, and only those offer **Select Extra Copies** (`keeper`: the copy kept is the one with
the most tags, then a plain name — not "(1)" or "copy" — then the oldest, then the shortest path). Nothing is
ever deleted without the person pressing Move to Trash.

Pairing near-identical hashes doesn't compare every pair: by the pigeonhole principle two hashes within 6 bits
agree exactly on at least one of 7 bands of the 64 bits, so only hashes sharing a band are compared. dHashes
are cached on disk by path, modified date and size, so a rescan only reads new or changed photos.

Everything here is plain Python + Pillow and runs on worker threads.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Iterable

import media_info

IMAGE_EXT = {".jpg", ".jpeg", ".png", ".heic", ".heif", ".gif", ".tif", ".tiff", ".bmp", ".webp", ".avif",
             ".dng", ".cr2", ".cr3", ".nef", ".arw", ".raf", ".orf", ".rw2"}
VIDEO_EXT = {".mov", ".mp4", ".m4v", ".avi", ".mkv", ".webm", ".3gp", ".mts", ".m2ts", ".wmv"}
HASHABLE = {".jpg", ".jpeg", ".png", ".heic", ".heif", ".gif", ".tif", ".tiff", ".bmp", ".webp", ".avif"}
THRESHOLD = 6                                      # bits; the iPhone's
BANDS = (10, 9, 9, 9, 9, 9, 9)                     # 7 bands over 64 bits (pigeonhole for THRESHOLD = 6)
KINDS = ("exact", "similar", "name")
KIND_LABEL = {"exact": "Exact match", "similar": "Visually similar", "name": "Similar name"}
SUPPORT = Path.home() / "Library" / "Application Support" / "Safe Finder"
CACHE = Path.home() / "Library" / "Caches" / "PhotoBrowser" / "dhash.json"


def kind_of(path: str) -> str:
    ext = os.path.splitext(path)[1].lower()
    return "image" if ext in IMAGE_EXT else "video" if ext in VIDEO_EXT else "other"


def is_frame_file(path: str) -> bool:
    return "frame" in os.path.basename(path).lower()


_COPY_SUFFIXES = [re.compile(p) for p in (r"\s*\(\d+\)$", r"\s+copy(\s+\d+)?$", r"[-_]\d{1,2}$", r"\s+\d{1,2}$")]


def normalized_base_name(filename: str) -> str:
    """The iPhone's `normalizedBaseName`: extension gone, lower case, copy suffixes stripped until none is left."""
    base = os.path.splitext(filename)[0].lower().strip()
    changed = True
    while changed:
        changed = False
        for rx in _COPY_SUFFIXES:
            new = rx.sub("", base).strip()
            if new != base:
                base, changed = new, True
    return base


def _bits(x: int) -> int:
    return bin(x).count("1")


def distance(a: int, b: int) -> int:
    return _bits(a ^ b)


# ----------------------------------------------------------------------------- the dHash

def dhash(path) -> int | None:
    """The iPhone's `PerceptualHash.dHash`: upright, tiny, grey, 9×8 — a bit per pixel brighter than its right
    neighbour, row by row. `path` is a file or a file-like object (a downloaded thumbnail's bytes). None when
    the picture can't be read."""
    from PIL import Image, ImageOps
    try:
        import batch_crop                          # registers HEIC with Pillow, when it can
    except ImportError:
        pass
    try:
        with Image.open(path) as im:
            try:
                im.draft("L", (64, 64))            # JPEG: decoded small to begin with
            except Exception:  # noqa: BLE001 — draft is only a speed-up
                pass
            im = ImageOps.exif_transpose(im)
            im = im.convert("L")
            im.thumbnail((32, 32), Image.Resampling.BILINEAR)
            px = list(im.resize((9, 8), Image.Resampling.BILINEAR).getdata())
    except Exception:  # noqa: BLE001 — a damaged or unknown file just isn't hashed
        return None
    h, bit = 0, 0
    for row in range(8):
        for col in range(8):
            if px[row * 9 + col] > px[row * 9 + col + 1]:
                h |= 1 << bit
            bit += 1
    return h


class HashCache:
    """dHashes on disk by "path|mtime_ns|size" — a rescan reads only new or changed photos."""

    def __init__(self, path: Path | None = None) -> None:
        self.path = path or CACHE
        self.lock = threading.Lock()
        self.data: dict[str, int] = {}
        self.dirty = False
        try:
            with open(self.path, encoding="utf-8") as f:
                raw = json.load(f)
            self.data = {k: int(v) for k, v in raw.items()} if isinstance(raw, dict) else {}
        except (OSError, ValueError):
            self.data = {}

    @staticmethod
    def key(path: str) -> str | None:
        try:
            st = os.stat(path)
        except OSError:
            return None
        return f"{path}|{st.st_mtime_ns}|{st.st_size}"

    def get(self, path: str) -> int | None:
        k = self.key(path)
        if k is None:
            return None
        with self.lock:
            if k in self.data:
                v = self.data[k]
                return None if v < 0 else v
        h = dhash(path)
        with self.lock:
            self.data[k] = -1 if h is None else h
            self.dirty = True
        return h

    def save(self) -> None:
        with self.lock:
            if not self.dirty:
                return
            if len(self.data) > 300000:            # an old cache full of files long gone: start afresh
                self.data = dict(list(self.data.items())[-100000:])
            data = dict(self.data)
            self.dirty = False
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            tmp = self.path.with_suffix(".saving")
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(data, f)
            os.replace(tmp, self.path)
        except OSError:
            pass


# ----------------------------------------------------------------------------- Not Duplicates

class NotDuplicates:
    """Pairs the person said aren't duplicates ("a\\nb", sorted), on this Mac. Moving or renaming a file in
    Safe Finder doesn't follow it here — as on the iPhone, a moved pair can come up again."""

    def __init__(self, path: Path | None = None) -> None:
        self.path = path or SUPPORT / "not-duplicates.json"
        try:
            with open(self.path, encoding="utf-8") as f:
                self.pairs: set[str] = set(json.load(f))
        except (OSError, ValueError, TypeError):
            self.pairs = set()

    @staticmethod
    def _pair(a: str, b: str) -> str:
        return "\n".join(sorted((a, b)))

    def mark(self, paths: Iterable[str]) -> None:
        paths = list(paths)
        for i, a in enumerate(paths):
            for b in paths[i + 1:]:
                self.pairs.add(self._pair(a, b))
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            tmp = self.path.with_suffix(".saving")
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(sorted(self.pairs), f)
            os.replace(tmp, self.path)
        except OSError:
            pass

    def all_dismissed(self, paths: list[str]) -> bool:
        return all(self._pair(a, b) in self.pairs for i, a in enumerate(paths) for b in paths[i + 1:])


# ----------------------------------------------------------------------------- the scan

@dataclass
class Group:
    kind: str                                      # "exact" | "similar" | "name"
    paths: list[str]
    size: int = 0                                  # the largest copy's
    width: int = 0
    height: int = 0
    identical: bool | None = None                  # exact groups: byte for byte the same (None until checked)
    hashes: dict[str, str] = field(default_factory=dict)

    @property
    def rank(self) -> int:
        return KINDS.index(self.kind)

    @property
    def types(self) -> str:
        exts = []
        for p in self.paths:
            e = os.path.splitext(p)[1].lstrip(".").upper() or "?"
            if e == "JPEG":
                e = "JPG"
            if e not in exts:
                exts.append(e)
        return "/".join(exts)

    @property
    def dims(self) -> str:
        return f"{self.width:,} × {self.height:,}" if self.width else ""

    def without(self, gone: set[str]) -> "Group | None":
        left = [p for p in self.paths if p not in gone]
        if len(left) < 2:
            return None
        return Group(self.kind, left, self.size, self.width, self.height, self.identical,
                     {p: h for p, h in self.hashes.items() if p in left})


def media_files(folder: str, recursive: bool, exclude_frames: bool, stop: threading.Event | None = None) -> list[str]:
    """Photos and videos in `folder` (and below, when `recursive`), hidden files and folders left out."""
    out: list[str] = []
    if recursive:
        for root, dirs, files in os.walk(folder):
            if stop is not None and stop.is_set():
                break
            dirs[:] = sorted(d for d in dirs if not d.startswith(".") and not d.endswith((".app", ".photoslibrary")))
            for n in sorted(files):
                if not n.startswith(".") and kind_of(n) != "other" and not (exclude_frames and is_frame_file(n)):
                    out.append(os.path.join(root, n))
    else:
        try:
            names = sorted(os.listdir(folder))
        except OSError:
            return []
        for n in names:
            p = os.path.join(folder, n)
            if not n.startswith(".") and kind_of(n) != "other" and not (exclude_frames and is_frame_file(n)) \
                    and os.path.isfile(p):
                out.append(p)
    return out


def _dims(path: str) -> tuple[int, int]:
    info = media_info.video_info(path) if kind_of(path) == "video" else media_info.image_info(path)
    return int(info.get("width") or 0), int(info.get("height") or 0)


def similar_clusters(hashes: dict[str, int], threshold: int = THRESHOLD) -> list[list[str]]:
    """Union-find over the pairs within `threshold` bits, compared only where a band agrees."""
    paths = list(hashes)
    parent = list(range(len(paths)))

    def find(x: int) -> int:
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    buckets: dict[tuple[int, int], list[int]] = {}
    for i, p in enumerate(paths):
        h, shift = hashes[p], 0
        for b, width in enumerate(BANDS):
            buckets.setdefault((b, (h >> shift) & ((1 << width) - 1)), []).append(i)
            shift += width
    checked: set[tuple[int, int]] = set()
    for members in buckets.values():
        if len(members) < 2 or len(members) > 5000:   # a band of solid colour: every flat photo shares it
            continue
        for x, i in enumerate(members):
            for j in members[x + 1:]:
                if (i, j) in checked:
                    continue
                checked.add((i, j))
                if distance(hashes[paths[i]], hashes[paths[j]]) <= threshold:
                    parent[find(i)] = find(j)
    clusters: dict[int, list[str]] = {}
    for i, p in enumerate(paths):
        clusters.setdefault(find(i), []).append(p)
    return [c for c in clusters.values() if len(c) > 1]


def scan(folder: str, recursive: bool = False, exclude_frames: bool = False,
         not_dupes: NotDuplicates | None = None, cache: HashCache | None = None,
         progress: Callable[[str, int, int], None] | None = None,
         stop: threading.Event | None = None) -> list[Group]:
    """The groups in `folder` — exact, then visually similar, then similar name; within a kind the biggest
    payoff first. `progress(stage, done, total)` from this (worker) thread."""
    stop = stop or threading.Event()
    say = progress or (lambda *_a: None)
    say("Listing", 0, 0)
    files = media_files(folder, recursive, exclude_frames, stop)
    sizes: dict[str, int] = {}
    for p in files:
        try:
            sizes[p] = os.path.getsize(p)
        except OSError:
            pass
    files = [p for p in files if p in sizes]
    # size + dimensions — only files sharing a size can be exact, so only those are opened for dimensions
    by_size: dict[int, list[str]] = {}
    for p in files:
        by_size.setdefault(sizes[p], []).append(p)
    need_dims = [p for ps in by_size.values() if len(ps) > 1 for p in ps]
    dims: dict[str, tuple[int, int]] = {}
    with ThreadPoolExecutor(max_workers=8) as pool:
        for i, (p, d) in enumerate(zip(need_dims, pool.map(_dims, need_dims))):
            dims[p] = d
            if i % 20 == 0:
                say("Reading sizes", i, len(need_dims))
            if stop.is_set():
                return []
    exact: dict[str, list[str]] = {}
    by_name: dict[str, list[str]] = {}
    for p in files:
        name = os.path.basename(p)
        frame = is_frame_file(name)
        w, h = dims.get(p, (0, 0))
        if w * h > 0:
            key = f"{sizes[p]}|{max(w, h)}|{w * h}"
            exact.setdefault(f"{key}|{name.lower()}" if frame else key, []).append(p)
        if not frame:
            stem = normalized_base_name(name)
            if stem:
                # with subfolders, a name is only a copy of one in the same folder ("IMG_0001" is in every
                # one); a photo and a video of one name are a Live Photo's two halves, not copies
                where = os.path.dirname(p) if recursive else ""
                by_name.setdefault(f"{where}\n{kind_of(p)}\n{stem}", []).append(p)
    # visually similar: dHash every photo
    photos = [p for p in files if os.path.splitext(p)[1].lower() in HASHABLE]
    cache = cache or HashCache()
    hashes: dict[str, int] = {}
    with ThreadPoolExecutor(max_workers=max(4, min(8, os.cpu_count() or 4))) as pool:
        for i, (p, h) in enumerate(zip(photos, pool.map(cache.get, photos))):
            if h is not None:
                hashes[p] = h
            if i % 10 == 0:
                say("Comparing photos", i, len(photos))
            if stop.is_set():
                cache.save()
                return []
    cache.save()
    say("Grouping", 0, 0)
    groups: list[Group] = []
    seen: set[frozenset[str]] = set()

    def add(paths: list[str], kind: str) -> None:
        if len(paths) < 2:
            return
        paths = sorted(paths, key=lambda p: (os.path.dirname(p).lower(), _natural(os.path.basename(p))))
        if not_dupes is not None and not_dupes.all_dismissed(paths):
            return
        key = frozenset(paths)
        if any(key <= have for have in seen):     # already shown whole, as a stronger kind (or the same set)
            return
        seen.add(key)
        rep = max(paths, key=lambda p: sizes.get(p, 0))
        w, h = dims.get(rep) or _dims(rep)
        groups.append(Group(kind, paths, sizes.get(rep, 0), w, h))

    for ps in exact.values():
        add(ps, "exact")
    for ps in similar_clusters(hashes):
        add(ps, "similar")
    for ps in by_name.values():
        add(ps, "name")
    groups.sort(key=lambda g: (g.rank, -g.size * (len(g.paths) - 1)))
    return groups


def _natural(name: str) -> list:
    return [int(t) if t.isdigit() else t.lower() for t in re.split(r"(\d+)", name)]


# ----------------------------------------------------------------------------- identical copies, dates, keeper

def content_hash(path: str, stop: threading.Event | None = None) -> str | None:
    h = hashlib.sha256()
    try:
        with open(path, "rb") as f:
            while chunk := f.read(4 * 1024 * 1024):
                if stop is not None and stop.is_set():
                    return None
                h.update(chunk)
    except OSError:
        return None
    return h.hexdigest()


def check_identical(group: Group, stop: threading.Event | None = None) -> bool | None:
    """Whether every copy in an exact group is byte for byte the same (None when one couldn't be read)."""
    for p in group.paths:
        if p not in group.hashes:
            h = content_hash(p, stop)
            if h is None:
                return None
            group.hashes[p] = h
    group.identical = len(set(group.hashes[p] for p in group.paths)) == 1
    return group.identical


def precise_date(path: str) -> float | None:
    """When it was taken, to the millisecond where the file says (EXIF DateTimeOriginal + SubSecTimeOriginal;
    a video's own creation date), else the modified time — which carries fractions too. The iPhone's
    `preciseDate`: copies shot or re-saved a few milliseconds apart are told apart."""
    if kind_of(path) == "video":
        when = media_info.video_info(path).get("created")
        if when:
            return float(when)
    else:
        try:
            from PIL import Image
            with Image.open(path) as im:
                exif = im.getexif().get_ifd(0x8769)
                taken = exif.get(36867)
                if isinstance(taken, str):
                    t = time.mktime(time.strptime(taken.strip()[:19], "%Y:%m:%d %H:%M:%S"))
                    sub = str(exif.get(37521) or "").strip()
                    if sub.isdigit():
                        t += float("0." + sub)
                    return t
        except Exception:  # noqa: BLE001 — no EXIF: the file's own date
            pass
    try:
        return os.stat(path).st_mtime
    except OSError:
        return None


def ages(paths: list[str], dates: dict[str, float]) -> dict[str, str]:
    """{path: "oldest" | "newest"} when the copies' dates differ by a millisecond or more."""
    have = [(dates[p], p) for p in paths if dates.get(p) is not None]
    if len(have) < 2:
        return {}
    have.sort()
    if have[-1][0] - have[0][0] < 0.001:
        return {}
    return {have[0][1]: "oldest", have[-1][1]: "newest"}


def keeper(paths: list[str], tags_of: Callable[[str], list[str]] | None = None) -> str:
    """The copy Select Extra Copies keeps: most tags, then a plain name (not "(1)"/"copy"), then the oldest
    (created, else modified), then the shortest path."""
    def birth(p: str) -> float:
        try:
            st = os.stat(p)
        except OSError:
            return float("inf")
        return float(getattr(st, "st_birthtime", st.st_mtime))

    def plain(p: str) -> int:
        stem = os.path.splitext(os.path.basename(p))[0].lower().strip()
        return 0 if normalized_base_name(os.path.basename(p)) == stem else 1

    return min(paths, key=lambda p: (-len(tags_of(p) if tags_of else []), plain(p), birth(p), len(p), p))
