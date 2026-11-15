"""Find Duplicates for Photo Browser for Mac — the iPhone app's (`DuplicatesView.swift`, `PerceptualHash.swift`), with the
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

Beyond the iPhone:

- **Include subfolders** (the iPhone looks at one folder), and **several folders at once** (`scan` takes a
  list — copies of one photo in two folders are found across them).
- An **Identical** check — the files of an exact group are read through (SHA-256) in the background, so a group
  whose copies are byte for byte the same says so.
- **Files whose dimensions can't be read** (a RAW the Mac has no reader for, a damaged video) and — with
  `all_files` — **documents, archives and anything else** are grouped as exact by size and a quick signature of
  their first and last bytes, then proved (or not) by the Identical check like the rest.
- **How strict "visually similar" is** (`STRICTNESS`: 4, 6 or 8 bits), and each similar group says how alike
  its copies are (`Group.alike`).
- **Which copy to keep** (`keeper`, `KEEP_RULES`): the best copy (most tags, a plain name — not "(1)" or "copy" —
  the oldest), the largest file, the most pixels, the oldest, the newest; a preferred folder beats them all.
  `extra_copies` is every copy but that one. Nothing is ever deleted without the person pressing Move to Trash.

Pairing near-identical hashes doesn't compare every pair: by the pigeonhole principle two hashes within t bits
agree exactly on at least one of t + 1 bands of the 64 bits (`bands_for`), so only hashes sharing a band are
compared (with numpy, a band's members at a time). dHashes are cached on disk by path, modified date and size, so
a rescan only reads new or changed photos.

Everything here is plain Python + Pillow (numpy when it's there) and runs on worker threads.
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
import app_identity

IMAGE_EXT = {".jpg", ".jpeg", ".png", ".heic", ".heif", ".gif", ".tif", ".tiff", ".bmp", ".webp", ".avif",
             ".dng", ".cr2", ".cr3", ".nef", ".arw", ".raf", ".orf", ".rw2"}
VIDEO_EXT = {".mov", ".mp4", ".m4v", ".avi", ".mkv", ".webm", ".3gp", ".mts", ".m2ts", ".wmv"}
HASHABLE = {".jpg", ".jpeg", ".png", ".heic", ".heif", ".gif", ".tif", ".tiff", ".bmp", ".webp", ".avif"}
THRESHOLD = 6                                      # bits; the iPhone's
STRICTNESS = {"strict": 4, "normal": THRESHOLD, "loose": 8}
STRICTNESS_LABEL = {"strict": "Strict", "normal": "Normal", "loose": "Loose"}
QUICK = 64 * 1024                                  # bytes read from each end for a file's quick signature
KINDS = ("exact", "similar", "name")
KIND_LABEL = {"exact": "Exact match", "similar": "Visually similar", "name": "Similar name"}
SUPPORT = app_identity.support()
CACHE = Path.home() / "Library" / "Caches" / "PhotoBrowser" / "dhash.json"


def kind_of(path: str) -> str:
    ext = os.path.splitext(path)[1].lower()
    return "image" if ext in IMAGE_EXT else "video" if ext in VIDEO_EXT else "other"


def bands_for(threshold: int) -> tuple[int, ...]:
    """t + 1 bands over the 64 bits: two hashes within t bits agree on one of them whole (7 bands for 6)."""
    n = max(1, threshold) + 1
    base, extra = divmod(64, n)
    return tuple(base + 1 if i < extra else base for i in range(n))


BANDS = bands_for(THRESHOLD)


def quick_signature(path: str) -> str | None:
    """A cheap stand-in for a file's contents: SHA-1 of its first and last 64 KB. Same size + same signature is
    worth a full read; a different one settles it without."""
    h = hashlib.sha1()
    try:
        with open(path, "rb") as f:
            h.update(f.read(QUICK))
            size = os.fstat(f.fileno()).st_size
            if size > QUICK:
                f.seek(max(QUICK, size - QUICK))
                h.update(f.read(QUICK))
    except OSError:
        return None
    return h.hexdigest()


def is_frame_file(path: str) -> bool:
    return "frame" in os.path.basename(path).lower()


_COPY_SUFFIXES = [re.compile(p) for p in (r"\s*\(\d+\)$", r"\s+copy(\s+\d+)?$", r"[-_]\d{1,2}$", r"\s+\d{1,2}$")]
_DATE_PART = _COPY_SUFFIXES[2]
_ONLY_NUMBERS = re.compile(r"[\d\s._-]*$")


def _strip_marks(filename: str) -> tuple[str, str]:
    """→ (the name without its copy marks, the strongest mark it had: "" none, "number" a short number at the
    end, "copy" a "(2)" or "copy")."""
    base = os.path.splitext(filename)[0].lower().strip()
    mark = ""
    changed = True
    while changed:
        changed = False
        for i, rx in enumerate(_COPY_SUFFIXES):
            new = rx.sub("", base).strip()
            if new == base:
                continue
            if rx is _DATE_PART and _ONLY_NUMBERS.fullmatch(new):      # "2024-05-12": a date, not "2024-05"'s copy
                continue
            base, changed = new, True
            mark = "copy" if i < 2 else (mark or "number")
    return base, mark


def normalized_base_name(filename: str) -> str:
    """The iPhone's `normalizedBaseName`: extension gone, lower case, copy suffixes stripped until none is left —
    except that a date ("2024-05-12") keeps its last part."""
    return _strip_marks(filename)[0]


def named_as_copies(names: list[str]) -> bool:
    """Whether files that share a stripped name are named like copies of one another: the plain name is among
    them ("IMG_0001" beside "IMG_0001-1"), or one says so outright ("beach (1)", "beach copy"). Files that only
    count — "beach 1", "beach 2", "beach 3"; "scan 12-30-45", "scan 12-30-46" — are a series, not copies."""
    marks = [_strip_marks(n)[1] for n in names]
    return "" in marks or "copy" in marks


def _bits(x: int) -> int:
    return bin(x).count("1")


def distance(a: int, b: int) -> int:
    return _bits(a ^ b)


# ----------------------------------------------------------------------------- the dHash

def dhash(path) -> int | None:
    """The iPhone's `PerceptualHash.dHash`: upright, tiny, grey, 9×8 — a bit per pixel brighter than its right
    neighbour, row by row. `path` is a file or a file-like object (a downloaded thumbnail's bytes). None when
    the picture can't be read."""
    return _dhash(path)[0]


def _dhash(path) -> tuple[int | None, bool]:
    """→ (the hash or None, whether a None is only for now: the file couldn't be read at all — an I/O error, no
    permission, gone — rather than read and found not to be a picture)."""
    from PIL import Image, ImageOps, UnidentifiedImageError
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
    except UnidentifiedImageError:
        return None, False
    except OSError as e:                           # Pillow's own complaints ("truncated") carry no errno
        return None, e.errno is not None
    except Exception:  # noqa: BLE001 — a damaged or unknown file just isn't hashed
        return None, False
    h, bit = 0, 0
    for row in range(8):
        for col in range(8):
            if px[row * 9 + col] > px[row * 9 + col + 1]:
                h |= 1 << bit
            bit += 1
    return h, False


CACHE_MOST = 1_000_000                             # about 60 MB of JSON; a big library is a few hundred thousand


class HashCache:
    """dHashes on disk by "path|mtime_ns|size" — a rescan reads only new or changed photos."""

    def __init__(self, path: Path | None = None) -> None:
        self.path = path or CACHE
        self.lock = threading.Lock()
        self.data: dict[str, int] = {}
        self.used: set[str] = set()                # what this run asked for — the last to go when it's pruned
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
            self.used.add(k)
            if k in self.data:
                v = self.data[k]
                return None if v < 0 else v
        h, passing = _dhash(path)
        if passing:                                # couldn't be *read* (the drive hiccuped, no permission) isn't
            return None                            # "isn't a picture": only the second is worth remembering
        with self.lock:
            self.data[k] = -1 if h is None else h
            self.dirty = True
        return h

    def save(self) -> None:
        with self.lock:
            if not self.dirty:
                return
            if len(self.data) > CACHE_MOST:        # too many: this run's stay, then the newest of the rest
                rest = [(k, v) for k, v in self.data.items() if k not in self.used]
                room = max(0, CACHE_MOST * 2 // 3 - len(self.used))
                self.data = {**dict(rest[-room:] if room else []), **{k: self.data[k] for k in self.used if k in self.data}}
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
    Photo Browser for Mac doesn't follow it here — as on the iPhone, a moved pair can come up again."""

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
    spread: int | None = None                      # similar groups: the most bits any two copies differ by
    stamps: dict[str, tuple[int, int]] = field(default_factory=dict)   # each copy's (size, mtime) when it was looked at

    def changed(self, path: str) -> bool:
        """Whether the file isn't the one that was compared any more (edited, replaced or gone since the scan)."""
        was = self.stamps.get(path)
        if was is None:
            return False
        try:
            st = os.stat(path)
        except OSError:
            return True
        return (st.st_size, st.st_mtime_ns) != was

    @property
    def bulk(self) -> bool:
        """Whether "Select Extra Copies" may tick this group without the person looking: never one alike only in
        name, nor an exact one the byte-for-byte check has shown to differ."""
        return self.kind != "name" and not (self.kind == "exact" and self.identical is False)

    @property
    def alike(self) -> str:
        """How alike a similar group's copies look: "98% alike"."""
        return "" if self.spread is None else f"{round(100 * (1 - self.spread / 64))}% alike"

    @property
    def extra_bytes(self) -> int:
        """What trashing every copy but one would free, near enough (the largest copy's size, each)."""
        return self.size * (len(self.paths) - 1)

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
                     {p: h for p, h in self.hashes.items() if p in left}, self.spread,
                     {p: v for p, v in self.stamps.items() if p in left})


JUNK = {"thumbs.db", "desktop.ini", "icon\r"}


def media_files(folder: str, recursive: bool, exclude_frames: bool, stop: threading.Event | None = None,
                all_files: bool = False) -> list[str]:
    """Photos and videos in `folder` (and below, when `recursive`), hidden files and folders left out. With
    `all_files`, every other file too — but not the records the apps keep beside the photos (JSON sidecars)."""
    def wanted(n: str) -> bool:
        if n.startswith("."):
            return False
        if kind_of(n) == "other":
            return all_files and n.lower() not in JUNK and not n.lower().endswith(".json")
        return not (exclude_frames and is_frame_file(n))

    out: list[str] = []
    if recursive:
        for root, dirs, files in os.walk(folder):
            if stop is not None and stop.is_set():
                break
            dirs[:] = sorted(d for d in dirs if not d.startswith(".") and not d.endswith((".app", ".photoslibrary")))
            out += [os.path.join(root, n) for n in sorted(files) if wanted(n)]
    else:
        try:
            names = sorted(os.listdir(folder))
        except OSError:
            return []
        for n in names:
            p = os.path.join(folder, n)
            if wanted(n) and os.path.isfile(p):
                out.append(p)
    return out


def _dims(path: str) -> tuple[int, int]:
    try:
        info = media_info.video_info(path) if kind_of(path) == "video" else media_info.image_info(path)
        return int(info.get("width") or 0), int(info.get("height") or 0)
    except Exception:  # noqa: BLE001 — one file that can't be measured mustn't end the whole scan
        return 0, 0


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
        for b, width in enumerate(bands_for(threshold)):
            buckets.setdefault((b, (h >> shift) & ((1 << width) - 1)), []).append(i)
            shift += width
    try:
        import numpy as np
        values = np.array([hashes[p] for p in paths], dtype=np.uint64)
        count = getattr(np, "bitwise_count", None)          # numpy 2
        if count is None:
            table = np.array([bin(i).count("1") for i in range(256)], dtype=np.uint8)

            def count(x):                                   # noqa: ANN001, ANN202
                return table[x.view(np.uint8).reshape(-1, 8)].sum(axis=1)
    except ImportError:
        np = None
    for members in buckets.values():
        if len(members) < 2 or len(members) > 5000:   # a band of solid colour: every flat photo shares it
            continue
        if np is not None and len(members) > 8:
            idx = np.array(members)
            vals = values[idx]
            for x in range(len(members) - 1):
                near = np.nonzero(count(vals[x + 1:] ^ vals[x]) <= threshold)[0]
                for k in near:
                    parent[find(members[x])] = find(members[x + 1 + int(k)])
            continue
        for x, i in enumerate(members):
            for j in members[x + 1:]:
                if distance(hashes[paths[i]], hashes[paths[j]]) <= threshold:
                    parent[find(i)] = find(j)
    clusters: dict[int, list[str]] = {}
    for i, p in enumerate(paths):
        clusters.setdefault(find(i), []).append(p)
    return [c for c in clusters.values() if len(c) > 1]


def spread_of(paths: list[str], hashes: dict[str, int]) -> int | None:
    """The most bits any two of the copies differ by (None when the group is too big to be worth working out)."""
    hs = [hashes[p] for p in paths if p in hashes]
    if len(hs) < 2 or len(hs) > 60:
        return None
    return max(distance(a, b) for i, a in enumerate(hs) for b in hs[i + 1:])


def scan(folder: str | list[str], recursive: bool = False, exclude_frames: bool = False,
         not_dupes: NotDuplicates | None = None, cache: HashCache | None = None,
         progress: Callable[[str, int, int], None] | None = None,
         stop: threading.Event | None = None, threshold: int = THRESHOLD,
         all_files: bool = False) -> list[Group]:
    """The groups in `folder` (or in several folders, looked at as one) — exact, then visually similar, then
    similar name; within a kind the biggest payoff first. `progress(stage, done, total)` from this (worker)
    thread."""
    stop = stop or threading.Event()
    say = progress or (lambda *_a: None)
    say("Listing", 0, 0)
    folders = [folder] if isinstance(folder, str) else list(folder)
    files = list(dict.fromkeys(p for f in folders for p in media_files(f, recursive, exclude_frames, stop, all_files)))
    several = recursive or len(folders) > 1
    sizes: dict[str, int] = {}
    stamps: dict[str, tuple[int, int]] = {}
    for p in files:
        try:
            st = os.stat(p)
        except OSError:
            continue
        sizes[p] = st.st_size
        stamps[p] = (st.st_size, st.st_mtime_ns)
    files = [p for p in files if p in sizes]
    # size + dimensions — only files sharing a size can be exact, so only those are opened for dimensions
    by_size: dict[int, list[str]] = {}
    for p in files:
        by_size.setdefault(sizes[p], []).append(p)
    need_dims = [p for ps in by_size.values() if len(ps) > 1 for p in ps if kind_of(p) != "other"]
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
        elif sizes[p] > 0 and len(by_size[sizes[p]]) > 1:
            # no dimensions to go by (not a picture, or one that can't be read): the same size and the same
            # first and last bytes — the Identical check then reads them through
            sig = quick_signature(p)
            if sig is not None:
                exact.setdefault(f"{sizes[p]}|bytes|{sig}", []).append(p)
        if not frame and kind_of(p) != "other":
            stem = normalized_base_name(name)
            if stem:
                # with subfolders, a name is only a copy of one in the same folder ("IMG_0001" is in every
                # one); a photo and a video of one name are a Live Photo's two halves, not copies
                where = os.path.dirname(p) if several else ""
                by_name.setdefault(f"{where}\n{kind_of(p)}\n{stem}", []).append(p)
    # Same size and the same dimensions is the iPhone's rule — and in a big library two different photos from one
    # camera do share both. So the first and last bytes must agree too (128 KB read, only of files in a group).
    measured = [(k, ps) for k, ps in exact.items() if len(ps) > 1 and "|bytes|" not in k]
    if measured:
        flat = [p for _k, ps in measured for p in ps]
        with ThreadPoolExecutor(max_workers=8) as pool:
            sigs = dict(zip(flat, pool.map(quick_signature, flat)))
        for k, ps in measured:
            del exact[k]
            for p in ps:
                if sigs.get(p) is not None:
                    exact.setdefault(f"{k}|{sigs[p]}", []).append(p)
        if stop.is_set():
            return []
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
    shown_with: dict[str, list[frozenset[str]]] = {}        # a path → the groups it's already in (not every group)

    def add(paths: list[str], kind: str) -> None:
        if len(paths) < 2:
            return
        paths = sorted(paths, key=lambda p: (os.path.dirname(p).lower(), _natural(os.path.basename(p))))
        if not_dupes is not None and not_dupes.all_dismissed(paths):
            return
        key = frozenset(paths)
        if any(key <= have for have in shown_with.get(paths[0], ())):   # already shown whole, as a stronger kind
            return
        for p in paths:
            shown_with.setdefault(p, []).append(key)
        rep = max(paths, key=lambda p: sizes.get(p, 0))
        w, h = dims.get(rep) or ((0, 0) if kind_of(rep) == "other" else _dims(rep))
        groups.append(Group(kind, paths, sizes.get(rep, 0), w, h,
                            spread=spread_of(paths, hashes) if kind == "similar" else None,
                            stamps={p: stamps[p] for p in paths if p in stamps}))

    for ps in exact.values():
        add(ps, "exact")
    for ps in similar_clusters(hashes, threshold):
        add(ps, "similar")
    for ps in by_name.values():
        if named_as_copies([os.path.basename(p) for p in ps]):
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


KEEP_RULES = {"best": "The best copy", "largest": "The largest file", "resolution": "The highest resolution",
              "oldest": "The oldest", "newest": "The newest"}
KEEP_TIP = {"best": "Most tags, then a plain name (not “(1)” or “copy”), then the oldest",
            "largest": "The biggest file — usually the least compressed",
            "resolution": "The most pixels, then the biggest file",
            "oldest": "The earliest taken (the file's own date when it doesn't say)",
            "newest": "The latest taken (the file's own date when it doesn't say)"}


def keeper(paths: list[str], tags_of: Callable[[str], list[str]] | None = None, rule: str = "best",
           pixels: dict[str, tuple[int, int]] | None = None, dates: dict[str, float] | None = None,
           prefer: str | None = None) -> str:
    """The copy to keep. `rule` (KEEP_RULES) decides — "best" is the most pixels, then the largest file; ties
    fall to: most tags, then a plain name (not "(1)"/"copy"), then the oldest (created, else modified), then
    the shortest path. A copy inside the
    `prefer` folder beats one that isn't, whatever the rule."""
    def birth(p: str) -> float:
        try:
            st = os.stat(p)
        except OSError:
            return float("inf")
        return float(getattr(st, "st_birthtime", st.st_mtime))

    def plain(p: str) -> int:
        stem = os.path.splitext(os.path.basename(p))[0].lower().strip()
        return 0 if normalized_base_name(os.path.basename(p)) == stem else 1

    def size(p: str) -> int:
        try:
            return os.path.getsize(p)
        except OSError:
            return 0

    def when(p: str) -> float:
        d = (dates or {}).get(p)
        return d if d is not None else birth(p)

    px = pixels if pixels and all(pixels.get(p) for p in paths) else {}     # known for every copy, or not used

    def first(p: str) -> tuple:
        if rule == "largest":
            return (-size(p),)
        if rule == "resolution":
            w, h = px.get(p) or (0, 0)
            return (-(w * h), -size(p))
        if rule == "oldest":
            return (when(p),)
        if rule == "newest":
            return (-when(p),)
        w, h = px.get(p) or (0, 0)                      # "best": never the smaller picture because its name is
        return (-(w * h), -size(p))                      # plainer — most pixels, then most bytes, then the ties

    def outside(p: str) -> int:
        if not prefer:
            return 0
        return 0 if (p == prefer or p.startswith(prefer.rstrip("/") + "/")) else 1

    return min(paths, key=lambda p: (outside(p), *first(p), -len(tags_of(p) if tags_of else []), plain(p),
                                     birth(p), len(p), p))


def extra_copies(paths: list[str], **how) -> tuple[str, list[str]]:
    """(the copy to keep, the rest) — `how` as for `keeper`."""
    keep = keeper(paths, **how)
    return keep, [p for p in paths if p != keep]


def pixels_of(path: str) -> tuple[int, int]:
    """A photo's or video's dimensions as shown ((0, 0) for anything else or unreadable)."""
    return (0, 0) if kind_of(path) == "other" else _dims(path)
