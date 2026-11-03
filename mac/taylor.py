"""taylorpictures.net for Safe Finder — the iPhone app's gallery browser (`TaylorGallery.swift`,
`TaylorBrowserView.swift`) on the Mac, plus a record of what's already in your Taylor Swift folder.

**The site** is a standard Coppermine gallery, read the way the iPhone reads it (the same patterns): a
section (`index.php?cat=N`, paged) lists sub-sections and albums (`thumbnails.php?album=ID`, the anchor
text the title, its `thumb_…` the cover); an album's pages list `thumb_<file>` images, and the full-size
image is the same path without `thumb_`. The first page's pager says how many pages there are; the rest are
fetched six at a time. Pages and album listings are kept in memory, thumbnails on disk
(`~/Library/Caches/PhotoBrowser/taylor/`). Only reads — nothing is ever sent to the site.

**Downloading an album** (`download_album`): into `<Taylor folder>/<album title>` (the folder the record says
it went to before, if any), eight images at a time, never over a file that's there, photos already in the
Taylor folder skipped when asked. A photo without its own date gets the album's — parsed from the title
(`2023-03-17`, or `3/17` with the year from a "2023" section), as the iPhone does — written by ExifTool when
it's installed; the file's own dates follow either way.

**What you already have** (`Record`, `LocalIndex`, `match`):
- `<Taylor folder>/.taylorpictures.json` — the albums downloaded into this folder, from either Mac (and the
  iPhone app, which reads it too, in time): each album's id, title, folder and file names. Merged on save.
- `LocalIndex` walks the Taylor folder once (in the background): every photo's name, and — a second pass —
  its picture fingerprint (`duplicates.dhash`, cached on disk), so a photo saved under another name is
  still found.
- `match` says, for each photo of an album, whether it's here: in the album's own folder by name; elsewhere
  by name when the name is distinctive (or the picture agrees); or anywhere by picture (the thumbnail's
  fingerprint within 5 bits of one of yours). Generic names (`001.jpg`) alone never count.

**The whole site against the whole folder** (`SiteIndex`, `cross_reference`): every section walked, every
album's photo list read (and, when asked, every thumbnail fingerprinted), kept in
`~/Library/Caches/PhotoBrowser/taylor/site.json` so a pass resumes and a later one reads only new albums; then
every album matched against the folder — how many of your photos are on the site, and which albums you have
all, some or none of (`Summary`, saved per folder).

Everything here runs on worker threads; nothing touches Qt.
"""
from __future__ import annotations

import io
import json
import os
import re
import tempfile
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Callable

import duplicates as D

HOST = "https://taylorpictures.net/"
# The iPhone app's (mobile Safari's) agent: the site varies its pages on it, and the parsers are the iPhone's.
UA = ("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) "
      "Version/17.0 Mobile/15E148 Safari/604.1")
RECORD = ".taylorpictures.json"
CACHE_DIR = Path.home() / "Library" / "Caches" / "PhotoBrowser" / "taylor"
PICTURE_BITS = 5                                     # a thumbnail within 5 bits of one of yours: the same photo
NAME_PICTURE_BITS = 10                               # same name elsewhere: the picture must roughly agree


@dataclass(frozen=True)
class Category:
    id: int
    title: str


@dataclass(frozen=True)
class Album:
    id: int
    title: str
    thumb: str = ""


@dataclass(frozen=True)
class Image:
    n: int
    full: str
    thumb: str
    filename: str


# ----------------------------------------------------------------------------- parsing (the iPhone's patterns)

def _findall(html: str, pattern: str) -> list[tuple]:
    return [m.groups() for m in re.finditer(pattern, html, re.I | re.S)]


def decode(s: str) -> str:
    """The iPhone's `decode` — the same few entities, so both apps name an album (and its folder) alike."""
    for a, b in (("&amp;", "&"), ("&#039;", "'"), ("&#39;", "'"), ("&quot;", '"'), ("&nbsp;", " ")):
        s = s.replace(a, b)
    return s.strip()


def strip_tags(s: str) -> str:
    return re.sub(r"<[^>]+>", " ", s).strip()


def absolute(path: str) -> str:
    return path if path.startswith("http") else HOST + path.strip("/")


def full_image_path(thumb: str) -> str:
    head, _, file = thumb.rpartition("/")
    if file.startswith("thumb_"):
        file = file[len("thumb_"):]
    return f"{head}/{file}" if head else file


def parse_categories(html: str, excluding: int | None) -> list[Category]:
    out, seen = [], set()
    for cid, inner in _findall(html, r"""<a[^>]+href=["']?index\.php\?cat=(\d+)[^>]*>(.*?)</a>"""):
        n = int(cid)
        title = decode(strip_tags(inner))
        if n == excluding or n in seen or not title:
            continue
        seen.add(n)
        out.append(Category(n, title))
    return out


def parse_albums(html: str) -> list[Album]:
    titles: dict[int, str] = {}
    covers: dict[int, str] = {}
    order: list[int] = []
    for aid, inner in _findall(html, r"""<a[^>]+href=["']?thumbnails\.php\?album=(\d+)[^>]*>(.*?)</a>"""):
        n = int(aid)
        title = decode(strip_tags(inner))
        if n not in titles:
            order.append(n)
            titles[n] = ""
        if not titles[n] and title:
            titles[n] = title
        if n not in covers:
            m = re.search(r'<img[^>]+src="([^"]+thumb_[^"]+)"', inner, re.I)
            if m:
                covers[n] = absolute(decode(m.group(1)))
    return [Album(n, titles[n], covers.get(n, "")) for n in order]


def parse_images(html: str) -> list[Image]:
    out, seen = [], set()
    for (thumb,) in _findall(html, r'<img[^>]+src="([^"]*thumb_[^"]+\.(?:jpe?g|png|gif))"'):
        thumb = decode(thumb)
        full = absolute(full_image_path(thumb))
        if full in seen:
            continue
        seen.add(full)
        out.append(Image(len(out), full, absolute(thumb), full.rsplit("/", 1)[-1]))
    return out


def page_count(html: str, pattern: str) -> int:
    return max((int(g[0]) for g in _findall(html, pattern)), default=0)


def sanitize(name: str) -> str:
    cleaned = re.sub(r'[/\\:?%*|"<>]', "-", name).strip()
    return cleaned[:120] if cleaned else "Untitled"


# ----------------------------------------------------------------------------- dates and places from titles

def _build(y, mo, d, h=12, mi=0, s=0) -> datetime | None:
    try:
        when = datetime(int(y), int(mo), int(d), int(h), int(mi), int(s))
    except (TypeError, ValueError):
        return None
    return when if 1990 <= when.year <= datetime.now().year + 1 else None


def date_from_name(name: str) -> datetime | None:
    """The iPhone's `MetadataLoader.dateFromFilename`: "… 2023-01-15 at 12.05.30", then yyyy-MM-dd
    [HH mm ss] with the usual separators, then a bare unix time."""
    base = os.path.splitext(name)[0]
    m = re.search(r"((?:19|20)\d{2})-(\d{2})-(\d{2}) at (\d{2})\.(\d{2})\.(\d{2})", base)
    if m and (d := _build(*m.groups())):
        return d
    for m in re.finditer(r"(?<![0-9])((?:19|20)\d{2})[-_.:]?(\d{2})[-_.:]?(\d{2})"
                         r"(?:[ _tT-](\d{2})[-_.:]?(\d{2})[-_.:]?(\d{2})?)?", base):
        y, mo, d, h, mi, s = m.groups()
        if (when := _build(y, mo, d, h or 12, mi or 0, s or 0)):
            return when
    m = re.search(r"(?<![0-9])(1\d{9}(?:\d{3})?)(?![0-9])", base)
    if m:
        v = float(m.group(1))
        when = datetime.fromtimestamp(v / 1000 if len(m.group(1)) >= 13 else v)
        if 1990 <= when.year <= datetime.now().year + 1:
            return when
    return None


def album_date(title: str, year: int | None) -> datetime | None:
    """The iPhone's `parseAlbumDate`: a full date in the title; else "M-D"/"M/D" with the section's year;
    else the section's year (1 January)."""
    if (d := date_from_name(title)):
        return d
    if year:
        m = re.search(r"(?:^|[^0-9])(\d{1,2})[-/](\d{1,2})(?:[^0-9]|$)", title)
        if m and (d := _build(year, m.group(1), m.group(2))):
            return d
        return _build(year, 1, 1)
    return None


def album_place(title: str) -> str | None:
    i = title.lower().rfind(" in ")
    if i < 0:
        return None
    place = title[i + 4:].strip()
    return place if 3 <= len(place) <= 60 else None


def year_of(title: str, inherited: int | None) -> int | None:
    """A section titled with a year ("2023") sets the year for the albums under it."""
    t = title.strip()
    return int(t) if t.isdigit() and 1990 <= int(t) <= 2100 else inherited


# ----------------------------------------------------------------------------- the site

class Gallery:
    """Reads the site (thread-safe). `get(url, referer) -> bytes | None` is the one network call — tests
    hand in a fake."""

    def __init__(self, get: Callable[[str, str], bytes | None] | None = None, cache_dir: Path | None = None):
        self.get = get or _http_get
        self.cache_dir = cache_dir or CACHE_DIR
        self.lock = threading.Lock()
        self.sections: dict[int, tuple[list[Category], list[Album]]] = {}
        self.albums: dict[int, list[Image]] = {}
        self.album_order: list[int] = []

    def html(self, path: str) -> str | None:
        for _ in range(2):                             # one retry: a blip shouldn't read as "couldn't reach"
            data = self.get(HOST + path, HOST)
            if data is not None:
                try:
                    return data.decode("utf-8")
                except UnicodeDecodeError:
                    return data.decode("latin-1")
        return None

    def _pages(self, numbers: range, path: Callable[[int], str]) -> list[str]:
        with ThreadPoolExecutor(max_workers=6) as pool:
            return [h for h in pool.map(lambda n: self.html(path(n)), numbers) if h]

    def browse(self, cat: int | None) -> tuple[list[Category], list[Album], str]:
        """Sub-sections and albums of a section (None: the front page), every page of them."""
        key = cat if cat is not None else -1
        with self.lock:
            if key in self.sections:
                return (*self.sections[key], "")

        def path(p: int) -> str:
            return f"index.php?cat={cat}&page={p}" if cat is not None else f"index.php?page={p}"
        first = self.html(path(1))
        if first is None:
            return [], [], "Couldn't reach taylorpictures.net."
        cats = parse_categories(first, cat)
        albums: dict[int, Album] = {}

        def add(html: str) -> int:
            n = 0
            for a in parse_albums(html):
                if a.id not in albums:
                    albums[a.id] = a
                    n += 1
            return n
        add(first)
        pattern = (rf"index\.php\?cat={cat}&(?:amp;)?page=(\d+)" if cat is not None else r"index\.php\?page=(\d+)")
        pages = page_count(first, pattern)
        if pages > 1:
            for h in self._pages(range(2, pages + 1), path):
                add(h)
        else:
            for p in range(2, 501):                       # no pager: keep paging until a page adds nothing
                h = self.html(path(p))
                if h is None or add(h) == 0:
                    break
        result = (cats, list(albums.values()))
        if cats or albums:
            with self.lock:
                self.sections[key] = result
        return (*result, "" if (cats or albums) else "Nothing here.")

    def images(self, album: int, on_page: Callable[[list[Image]], None] | None = None) -> list[Image]:
        """Every image of an album, in the site's order; `on_page` gets each page's new ones as they come."""
        with self.lock:
            hit = self.albums.get(album)
        if hit is not None:
            if on_page:
                on_page(hit)
            return hit
        out: list[Image] = []
        seen: set[str] = set()

        def add(html: str) -> list[Image]:
            fresh = []
            for img in parse_images(html):
                if img.full not in seen:
                    seen.add(img.full)
                    fresh.append(Image(len(out) + len(fresh), img.full, img.thumb, img.filename))
            out.extend(fresh)
            if fresh and on_page:
                on_page(fresh)
            return fresh

        def path(p: int) -> str:
            return f"thumbnails.php?album={album}&page={p}"
        first = self.html(path(1))
        if first is None:
            return []
        add(first)
        pages = page_count(first, rf"thumbnails\.php\?album={album}&(?:amp;)?page=(\d+)")
        if pages > 1:
            for h in self._pages(range(2, pages + 1), path):
                add(h)
        else:
            for p in range(2, 501):
                h = self.html(path(p))
                if h is None or not add(h):
                    break
        if out:
            with self.lock:
                self.albums[album] = out
                self.album_order.append(album)
                while len(self.album_order) > 200:
                    self.albums.pop(self.album_order.pop(0), None)
        return out

    def thumb(self, url: str) -> bytes | None:
        """A thumbnail's bytes, kept on disk (the site's thumbnails don't change)."""
        name = re.sub(r"[^A-Za-z0-9._-]", "_", url.split("://", 1)[-1])[-180:]
        path = self.cache_dir / name
        try:
            return path.read_bytes()
        except OSError:
            pass
        data = self.get(url, HOST)
        if data:
            try:
                path.parent.mkdir(parents=True, exist_ok=True)
                tmp = path.with_suffix(path.suffix + ".part")
                tmp.write_bytes(data)
                os.replace(tmp, path)
            except OSError:
                pass
        return data


def _http_get(url: str, referer: str) -> bytes | None:
    import urllib.error
    import urllib.request
    import simpcity as sc
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Referer": referer,
                                               "Accept-Language": "en-US,en;q=0.9"})
    try:
        with urllib.request.urlopen(req, timeout=30, context=sc.ssl_context()) as resp:
            return resp.read()
    except (urllib.error.URLError, OSError, ValueError):
        return None


# ----------------------------------------------------------------------------- the record on the drive

class Record:
    """`<Taylor folder>/.taylorpictures.json`: the albums downloaded into this folder. Read fresh and merged
    on every save, so two Macs (or the iPhone) adding albums don't lose each other's."""

    def __init__(self, root: str) -> None:
        self.root = Path(root)
        self.path = self.root / RECORD
        self.albums: dict[str, dict] = {}
        self.load()

    def load(self) -> None:
        try:
            with open(self.path, encoding="utf-8") as f:
                data = json.load(f)
            self.albums = {str(k): v for k, v in (data.get("albums") or {}).items() if isinstance(v, dict)}
        except (OSError, ValueError, AttributeError):
            self.albums = {}

    def folder_of(self, album: int) -> Path | None:
        entry = self.albums.get(str(album))
        if entry and entry.get("folder"):
            p = self.root / entry["folder"]
            if p.is_dir():
                return p
        return None

    def note(self, album: Album, folder: Path, files: list[str], total: int) -> None:
        on_disk = Record(str(self.root))
        merged = dict(on_disk.albums)
        for k, v in self.albums.items():
            merged.setdefault(k, v)
        old = merged.get(str(album.id), {})
        names = sorted(set(old.get("files") or []) | set(files))
        merged[str(album.id)] = {"title": album.title, "folder": os.path.relpath(folder, self.root),
                                 "files": names, "total": max(total, int(old.get("total") or 0)),
                                 "downloaded": time.time()}
        self.albums = merged
        import simpcity as sc
        sc.write_file(self.path, json.dumps({"version": 1, "albums": merged}, indent=1, sort_keys=True).encode())

    def is_complete(self, album: int) -> bool:
        e = self.albums.get(str(album))
        return bool(e) and len(e.get("files") or []) >= int(e.get("total") or 1)


# ----------------------------------------------------------------------------- what's already here

_GENERIC = re.compile(r"^(?:img|image|dsc|photo|pic|picture|untitled|thumb|p)?[_ -]?\d{1,5}$", re.I)


def distinctive(filename: str) -> bool:
    """A name worth trusting on its own: not "001.jpg", "image12.jpg", "DSC_0042.jpg"-short and generic."""
    stem = os.path.splitext(filename)[0]
    return len(stem) >= 6 and not _GENERIC.match(stem)


class LocalIndex:
    """The photos under the Taylor folder: by name (fast, first) and by picture (a second pass, cached)."""

    def __init__(self, root: str, cache: D.HashCache | None = None) -> None:
        self.root = root
        self.cache = cache
        self.by_name: dict[str, list[str]] = {}
        self.by_folder: dict[str, list[str]] = {}     # folder name (lower case) → folders with that name
        self.hashes: dict[str, int] = {}
        self._bands: dict[tuple[int, int], list[str]] = {}
        self.photos = 0
        self.names_ready = False
        self.pictures_ready = False
        self.lock = threading.Lock()

    def build_names(self, stop: threading.Event | None = None) -> None:
        by_name: dict[str, list[str]] = {}
        by_folder: dict[str, list[str]] = {}
        n = 0
        for dirpath, dirs, files in os.walk(self.root):
            if stop is not None and stop.is_set():
                return
            dirs[:] = [d for d in dirs if not d.startswith(".")]
            for d in dirs:
                by_folder.setdefault(d.lower(), []).append(os.path.join(dirpath, d))
            for f in files:
                if not f.startswith(".") and D.kind_of(f) == "image":
                    by_name.setdefault(f.lower(), []).append(os.path.join(dirpath, f))
                    n += 1
        with self.lock:
            self.by_name, self.by_folder, self.photos, self.names_ready = by_name, by_folder, n, True

    def build_pictures(self, progress: Callable[[int, int], None] | None = None,
                       stop: threading.Event | None = None) -> None:
        cache = self.cache or D.HashCache()
        paths = [p for ps in self.by_name.values() for p in ps
                 if os.path.splitext(p)[1].lower() in D.HASHABLE]
        hashes: dict[str, int] = {}
        with ThreadPoolExecutor(max_workers=max(4, min(8, os.cpu_count() or 4))) as pool:
            for i, (p, h) in enumerate(zip(paths, pool.map(cache.get, paths))):
                if stop is not None and stop.is_set():
                    cache.save()
                    return
                if h is not None:
                    hashes[p] = h
                if progress and i % 50 == 0:
                    progress(i, len(paths))
        cache.save()
        bands: dict[tuple[int, int], list[str]] = {}
        for p, h in hashes.items():
            shift = 0
            for b, width in enumerate(D.BANDS):
                bands.setdefault((b, (h >> shift) & ((1 << width) - 1)), []).append(p)
                shift += width
        with self.lock:
            self.hashes, self._bands, self.pictures_ready = hashes, bands, True
        if progress:
            progress(len(paths), len(paths))

    def by_picture(self, h: int, bits: int = PICTURE_BITS) -> str | None:
        """One of yours within `bits` of `h` (the closest), found through the bands (bits ≤ 6)."""
        best, best_d = None, bits + 1
        shift = 0
        with self.lock:
            for b, width in enumerate(D.BANDS):
                for p in self._bands.get((b, (h >> shift) & ((1 << width) - 1)), ()):
                    d = D.distance(h, self.hashes[p])
                    if d < best_d:
                        best, best_d = p, d
                shift += width
        return best

    def album_folders(self, album: Album, record: Record | None) -> list[str]:
        out = []
        if record is not None and (f := record.folder_of(album.id)) is not None:
            out.append(str(f))
        for f in self.by_folder.get(sanitize(album.title or f"Album {album.id}").lower(), []):
            if f not in out:
                out.append(f)
        return out


@dataclass
class Match:
    path: str | None = None                          # the copy of yours, when there is one
    how: str = ""                                    # "folder" | "name" | "picture" | ""

    @property
    def have(self) -> bool:
        return self.path is not None


def match(album: Album, images: list[Image], index: LocalIndex, record: Record | None = None,
          thumb_hashes: dict[str, int] | None = None) -> dict[str, Match]:
    """{image.full: Match} — which of the album's photos you already have (module notes)."""
    thumb_hashes = thumb_hashes or {}
    folders = [os.path.normcase(f) for f in index.album_folders(album, record)]
    out: dict[str, Match] = {}
    for img in images:
        name = img.filename.lower()
        h = thumb_hashes.get(img.full)
        found = Match()
        for p in index.by_name.get(name, []):
            if os.path.normcase(os.path.dirname(p)) in folders:
                found = Match(p, "folder")
                break
        if not found.have and name in index.by_name:
            for p in index.by_name[name]:
                lh = index.hashes.get(p)
                if h is not None and lh is not None:
                    if D.distance(h, lh) <= NAME_PICTURE_BITS:
                        found = Match(p, "name")
                        break
                elif distinctive(img.filename) and len(index.by_name[name]) == 1:
                    found = Match(p, "name")
                    break
        if not found.have and h is not None and index.pictures_ready:
            p = index.by_picture(h)
            if p is not None:
                found = Match(p, "picture")
        out[img.full] = found
    return out


def thumb_hash(data: bytes | None) -> int | None:
    return D.dhash(io.BytesIO(data)) if data else None


# ----------------------------------------------------------------------------- downloading an album

@dataclass
class Outcome:
    folder: str = ""
    downloaded: int = 0
    already: int = 0                                  # in the album's folder from before
    elsewhere: int = 0                                # in the Taylor folder already, so skipped
    failed: int = 0
    total: int = 0
    stopped: bool = False
    note: str = ""
    files: list[str] = field(default_factory=list)


def download_album(gallery: Gallery, album: Album, root: str, year: int | None = None,
                   record: Record | None = None, index: LocalIndex | None = None, skip_have: bool = True,
                   progress: Callable[[int, int, str], None] | None = None, stop: threading.Event | None = None,
                   tool=None, workers: int = 8) -> Outcome:
    """An album into `root` (module notes). `progress(done, total, name)` from worker threads."""
    import simpcity as sc
    import social
    stop = stop or threading.Event()
    out = Outcome()
    images = gallery.images(album.id)
    out.total = len(images)
    if not images:
        out.note = "No images found in this album (or the site didn't answer)."
        return out
    record = record or Record(root)
    folder = record.folder_of(album.id) or Path(root) / sanitize(album.title or f"Album {album.id}")
    out.folder = str(folder)
    have: dict[str, Match] = {}
    if skip_have and index is not None and index.names_ready:
        hashes = {}
        if index.pictures_ready:
            with ThreadPoolExecutor(max_workers=8) as pool:
                for img, h in zip(images, pool.map(lambda i: thumb_hash(gallery.thumb(i.thumb)), images)):
                    if h is not None:
                        hashes[img.full] = h
        have = match(album, images, index, record, hashes)
    when = album_date(album.title, year)
    lock = threading.Lock()
    done = [0]
    tmpdir = tempfile.mkdtemp(prefix="taylor-")

    def one(img: Image) -> None:
        if stop.is_set():
            return
        name = sanitize(img.filename)
        dest = folder / name
        kind = "skip"
        try:
            if dest.exists() and dest.stat().st_size > 0:
                kind = "already"
            elif (m := have.get(img.full)) is not None and m.have and \
                    os.path.normcase(os.path.dirname(m.path)) != os.path.normcase(str(folder)):
                kind = "elsewhere"
            else:
                tmp = os.path.join(tmpdir, f"{img.n}-{name}")
                data = gallery.get(img.full, HOST)
                if not data or len(data) < 256 or data.lstrip()[:1] == b"<":    # nothing, or a page not a photo
                    kind = "failed"
                else:
                    with open(tmp, "wb") as f:
                        f.write(data)
                    sc.apply_date(tmp, when.timestamp() if when else 0, tool)
                    kind = "downloaded" if social.place(tmp, folder, name) else "already"
        except OSError:
            kind = "failed"
        with lock:
            if kind == "downloaded":
                out.downloaded += 1
            elif kind == "already":
                out.already += 1
            elif kind == "elsewhere":
                out.elsewhere += 1
            elif kind == "failed":
                out.failed += 1
            if kind in ("downloaded", "already"):
                out.files.append(name)
            done[0] += 1
            n = done[0]
        if progress:
            progress(n, len(images), img.filename)

    need_folder = any(not (have.get(i.full) and have[i.full].have) for i in images) or not skip_have
    if need_folder:
        sc.make_folder(folder)
    with ThreadPoolExecutor(max_workers=workers) as pool:
        list(pool.map(one, images))
    try:
        os.rmdir(tmpdir)
    except OSError:
        pass
    out.stopped = stop.is_set()
    if out.files:
        try:
            record.note(album, folder, out.files, len(images))
        except OSError as e:
            out.note = f"Couldn't save the record: {e}"
    elif need_folder:
        try:
            folder.rmdir()                               # nothing landed: no empty folder left behind
        except OSError:
            pass
    return out


# ----------------------------------------------------------------------------- the whole site against the whole folder

class SiteIndex:
    """Every album on the site and its photos (`~/Library/Caches/PhotoBrowser/taylor/site.json`): the sections
    walked once (breadth first, each once — every page links back to the others — the year of a "2023"
    section carried down), then each album's photo list, then (when asked) each thumbnail's fingerprint. Saved
    as it goes, so a pass that's stopped or closed carries on where it was; a later "Check Again" walks the
    sections for new albums and reads only those. Photos are kept as their thumbnail paths (the full-size path
    and the file name follow from it)."""

    def __init__(self, path: Path | None = None) -> None:
        self.path = path or CACHE_DIR / "site.json"
        self.lock = threading.RLock()
        self.albums: dict[str, dict] = {}
        self.walked = 0.0                       # when the sections were last walked through
        try:
            with open(self.path, encoding="utf-8") as f:
                data = json.load(f)
            self.albums = data.get("albums") or {}
            self.walked = float(data.get("walked") or 0)
        except (OSError, ValueError, AttributeError):
            pass

    def save(self) -> None:
        with self.lock:
            data = json.dumps({"version": 1, "walked": self.walked, "albums": self.albums})
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            tmp = self.path.with_suffix(".saving")
            tmp.write_text(data, encoding="utf-8")
            os.replace(tmp, self.path)
        except OSError:
            pass

    # -- reading it back
    def album(self, aid: int) -> Album | None:
        a = self.albums.get(str(aid))
        return Album(aid, a.get("title", ""), a.get("thumb", "")) if a else None

    def year(self, aid: int) -> int | None:
        a = self.albums.get(str(aid)) or {}
        return a.get("year")

    def images(self, aid: int) -> list[Image] | None:
        a = self.albums.get(str(aid))
        if not a or a.get("images") is None:
            return None
        out = []
        for i, rel in enumerate(a["images"]):
            full = absolute(full_image_path(rel))
            out.append(Image(i, full, absolute(rel), full.rsplit("/", 1)[-1]))
        return out

    def hashes(self, aid: int) -> dict[str, int]:
        a = self.albums.get(str(aid)) or {}
        return {absolute(full_image_path(rel)): h for rel, h in (a.get("hashes") or {}).items()}

    def counts(self) -> tuple[int, int, int]:
        """(albums known, albums read, photos)."""
        with self.lock:
            read = [a for a in self.albums.values() if a.get("images") is not None]
            return len(self.albums), len(read), sum(len(a["images"]) for a in read)

    # -- filling it in
    def walk_sections(self, gallery: Gallery, progress: Callable[[int, int], None] | None = None,
                      stop: threading.Event | None = None) -> bool:
        """Every section → its albums (new ones added, unread). False when stopped or the site didn't answer."""
        seen_sections: set[int] = set()
        queue: list[tuple[int | None, int | None, str, int]] = [(None, None, "", 0)]
        found = 0
        answered = False
        while queue:
            if stop is not None and stop.is_set():
                return False
            cat, year, path, depth = queue.pop(0)
            if cat is not None:
                if cat in seen_sections:
                    continue
                seen_sections.add(cat)
            if depth > 6:
                continue
            cats, albums, note = gallery.browse(cat)
            if note != "Couldn't reach taylorpictures.net.":
                answered = True
            with self.lock:
                for a in albums:
                    key = str(a.id)
                    if key not in self.albums:
                        self.albums[key] = {"title": a.title, "thumb": a.thumb, "year": year, "section": path}
                        found += 1
                    elif not self.albums[key].get("section") and path:
                        self.albums[key]["section"] = path
            for c in cats:
                if c.id not in seen_sections:
                    queue.append((c.id, year_of(c.title, year), f"{path} › {c.title}" if path else c.title, depth + 1))
            if progress:
                progress(len(self.albums), len(seen_sections))
        if answered:
            self.walked = time.time()
            self.save()
        return answered

    def read_albums(self, gallery: Gallery, progress: Callable[[int, int], None] | None = None,
                    stop: threading.Event | None = None, workers: int = 4) -> None:
        """Every album not read yet → its photos. Saved every 25 albums."""
        todo = [int(k) for k, a in self.albums.items() if a.get("images") is None]
        total = len(self.albums)
        done = [total - len(todo)]
        lock = threading.Lock()

        def one(aid: int) -> None:
            if stop is not None and stop.is_set():
                return
            imgs = gallery.images(aid)
            if not imgs:
                return                                  # the site didn't answer: tried again next pass
            rels = [img.thumb[len(HOST):] if img.thumb.startswith(HOST) else img.thumb for img in imgs]
            with self.lock:
                self.albums[str(aid)]["images"] = rels
            with lock:
                done[0] += 1
                n = done[0]
            if n % 25 == 0:
                self.save()
            if progress:
                progress(n, total)
        with ThreadPoolExecutor(max_workers=workers) as pool:
            list(pool.map(one, todo))
        self.save()

    def hash_thumbs(self, gallery: Gallery, progress: Callable[[int, int], None] | None = None,
                    stop: threading.Event | None = None, workers: int = 6) -> None:
        """Every thumbnail's fingerprint (for photos saved under another name). Saved every 1,000."""
        with self.lock:
            todo = [(k, rel) for k, a in self.albums.items() for rel in (a.get("images") or [])
                    if rel not in (a.get("hashes") or {})]
            total = sum(len(a.get("images") or []) for a in self.albums.values())
        done = [total - len(todo)]
        lock = threading.Lock()

        def one(item: tuple[str, str]) -> None:
            if stop is not None and stop.is_set():
                return
            key, rel = item
            h = thumb_hash(gallery.thumb(absolute(rel)))
            with self.lock:
                self.albums[key].setdefault("hashes", {})[rel] = h if h is not None else -1
            with lock:
                done[0] += 1
                n = done[0]
            if n % 1000 == 0:
                self.save()
            if progress and n % 50 == 0:
                progress(n, total)
        with ThreadPoolExecutor(max_workers=workers) as pool:
            list(pool.map(one, todo))
        self.save()
        if progress:
            progress(total, total)


@dataclass
class Summary:
    """How the Taylor folder and the site compare (`cross_reference`)."""
    albums: int = 0                        # albums on the site (read)
    images: int = 0                        # photos on the site
    complete: int = 0                      # albums you have every photo of
    partial: int = 0
    none: int = 0
    local_photos: int = 0                  # photos in the Taylor folder
    matched_local: int = 0                 # …that are on the site
    by_picture: bool = False
    when: float = 0.0
    per_album: dict[str, list[int]] = field(default_factory=dict)    # id → [total, have]
    matched: dict[str, list[int]] = field(default_factory=dict)      # your photo → the albums it's in

    def to_json(self) -> dict:
        return dict(self.__dict__)

    @staticmethod
    def from_json(d: dict) -> "Summary":
        s = Summary()
        for k, v in (d or {}).items():
            if hasattr(s, k):
                setattr(s, k, v)
        return s


def summary_path(root: str) -> Path:
    import hashlib
    return CACHE_DIR / f"xref-{hashlib.sha1(os.path.normcase(os.path.abspath(root)).encode()).hexdigest()[:16]}.json"


def load_summary(root: str) -> Summary | None:
    try:
        with open(summary_path(root), encoding="utf-8") as f:
            return Summary.from_json(json.load(f))
    except (OSError, ValueError):
        return None


def cross_reference(site: SiteIndex, index: LocalIndex, record: Record | None = None,
                    progress: Callable[[int, int], None] | None = None,
                    stop: threading.Event | None = None) -> Summary:
    """Every album the site index has read, matched against the whole Taylor folder (`match`, with the
    thumbnails' fingerprints where the index has them). Saved per folder."""
    out = Summary(local_photos=index.photos, when=time.time())
    keys = [k for k, a in site.albums.items() if a.get("images") is not None]
    any_hashes = False
    for i, key in enumerate(keys):
        if stop is not None and stop.is_set():
            break
        aid = int(key)
        album, imgs = site.album(aid), site.images(aid) or []
        hashes = site.hashes(aid)
        any_hashes = any_hashes or bool(hashes)
        m = match(album, imgs, index, record, {u: h for u, h in hashes.items() if h >= 0})
        have = sum(1 for x in m.values() if x.have)
        out.per_album[key] = [len(imgs), have]
        out.albums += 1
        out.images += len(imgs)
        if imgs and have >= len(imgs):
            out.complete += 1
        elif have:
            out.partial += 1
        else:
            out.none += 1
        for x in m.values():
            if x.have:
                out.matched.setdefault(x.path, [])
                if aid not in out.matched[x.path]:
                    out.matched[x.path].append(aid)
        if progress and i % 50 == 0:
            progress(i, len(keys))
    out.matched_local = len(out.matched)
    out.by_picture = any_hashes and index.pictures_ready
    try:
        p = summary_path(index.root)
        p.parent.mkdir(parents=True, exist_ok=True)
        tmp = p.with_suffix(".saving")
        tmp.write_text(json.dumps(out.to_json()), encoding="utf-8")
        os.replace(tmp, p)
    except OSError:
        pass
    return out
