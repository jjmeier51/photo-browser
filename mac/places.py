"""Where photos and videos were taken, for Photo Browser for Mac's Location filter — the iPhone app's place index
(`MetadataLoader.PlaceIndex`, the Location filter in `FolderView`), shared.

Two layers, as on the iPhone. Each photo's or video's GPS reduces to a ~1 km **bin** ("40.82|-73.20": two
decimals), and each bin is **named** once ("Hauppauge, NY") — the geocoder is rate-limited, and a thousand photos
from one afternoon are one name. A file's bin "" means it has no location (the filter's "No Location"); a bin
named "" is a spot the geocoder had no name for ("Unnamed place"). A file whose bin isn't named yet has no label
and is left out, as on the iPhone.

Files are keyed exactly as the iPhone keys them — "<path inside the drive>|<modified, whole seconds>|<size>" —
so its index works here as it is:

- **The drive's** `.Photo Browser Metadata/places.json` — the iPhone's index, which every metadata backup to the
  drive carries: months of geocoding, read (never written) by Photo Browser for Mac. The nearest folder above holding
  `.Photo Browser Metadata` is used, as for shared tags.
- **Photo Browser for Mac's own**, `~/Library/Application Support/Photo Browser for Mac/places.json` (the same shape): what Photo Browser for
  Mac read and named itself — GPS from the files (`media_info`: EXIF for photos, QuickTime's ISO 6709 for
  videos) and names from Apple's geocoder through `geocode_helper.swift` (CLGeocoder, the iPhone's labels, one
  request every 1.2 s, at most `NAME_LIMIT` a pass — a well-travelled folder names the rest next time). The
  helper is built once with `swiftc` like Photo Browser for Mac's others; a failed build leaves `geocode_helper.log`.

Lookups (`label`) never touch the disk — they're made while painting and filtering; `locate` (a worker thread)
does the reading and naming, and loads a drive's index the first time it's needed.

**A third layer, offline** (`geo_names.py`, Nov 2026): every bin has a name the moment its GPS is read — the
nearest town from the table that ships with the app — so nothing waits on the geocoder's one-a-second queue and,
with "Refine Place Names with Apple" off, nothing leaves the Mac at all. A label is the iPhone's (the drive's
index) when it has one, else Apple's from this Mac, else the offline one. The offline place also says which
**country and region** a bin is in (`where`), whatever its label — that's what the Location menu's Country ▸
State ▸ City and the search's `country:` / `state:` go by — and `text` is everything a search may match
("passy, paris, île-de-france, france"). The offline names live in memory only: written into the index they'd
pass for refined ones and never be bettered.

**Everything with a location** (`everything`, `summary`): the two indexes list every file whose GPS has been read
— months of the iPhone's work for the drive — which is what the Places collection, the map and `place:` searches
are made from, without reading a single photo again. `scan` reads the ones not read yet.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import threading
import unicodedata
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Callable

import media_info
import app_identity
import geo_names

META_FOLDER = ".Photo Browser Metadata"
FILE_NAME = "places.json"
NAME_LIMIT = 60                         # bins named per pass (the iPhone's geocodeLimit)
UNNAMED = "Unnamed place"
IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".heic", ".heif", ".gif", ".tif", ".tiff", ".bmp", ".webp", ".avif",
              ".dng", ".cr2", ".cr3", ".nef", ".arw", ".raf", ".orf", ".rw2"}
VIDEO_EXTS = {".mov", ".mp4", ".m4v", ".3gp", ".qt"}          # what media_info can read a place from
MEDIA_EXTS = IMAGE_EXTS | VIDEO_EXTS | {".avi", ".mkv", ".webm", ".mts", ".m2ts", ".wmv"}


def own_file() -> Path:
    return app_identity.support() / FILE_NAME


def bin_of(lat: float, lng: float) -> str:
    """The iPhone's `binString`: two decimals, "" for no (or a meaningless) place."""
    if not (abs(lat) <= 90 and abs(lng) <= 180) or (lat == 0 and lng == 0) or lat != lat or lng != lng:
        return ""
    return f"{lat:.2f}|{lng:.2f}"


class Index:
    """One place index: fileBins (key → bin), binPlaces (bin → search text), binLabels (bin → label)."""

    def __init__(self, data: dict | None = None) -> None:
        data = data or {}
        self.file_bins: dict[str, str] = dict(data.get("fileBins") or {})
        self.bin_places: dict[str, str] = dict(data.get("binPlaces") or {})
        self.bin_labels: dict[str, str] = dict(data.get("binLabels") or {})

    @classmethod
    def read(cls, path: Path) -> "Index":
        try:
            return cls(json.loads(path.read_text(encoding="utf-8")))
        except (OSError, ValueError, AttributeError):
            return cls()

    def to_json(self) -> dict:
        return {"version": 2, "fileBins": self.file_bins, "binPlaces": self.bin_places, "binLabels": self.bin_labels}


class Places:
    def __init__(self, own: Path | None = None, read_gps: Callable[[str], tuple[float, float] | None] | None = None,
                 geocode: Callable[[list[str], Callable[[int, int], None], threading.Event | None], dict] | None = None
                 ) -> None:
        self.own_path = own or own_file()
        self.own = Index.read(self.own_path)
        self._lock = threading.Lock()
        self._drives: dict[str, Index] = {}            # places.json path → the iPhone's index there
        self._drive_mtime: dict[str, float] = {}
        self._volumes: dict[str, str] = {}             # folder → its volume's root
        self._indexes: dict[str, str] = {}             # folder → the places.json that covers it ("" none)
        self._dirty = False
        self.read_gps = read_gps or gps_of
        self.geocode = geocode or geocode_bins
        self.problem = ""                              # why places couldn't be named, when they couldn't
        self._offline: dict[str, geo_names.Place | None] = {}   # bin → the nearest town (memory only)
        self._texts: dict[str, str] = {}               # bin → what a search may match
        self.refine = str(app_identity.settings_value("places/refine", "true")) != "false"   # ask Apple for names too

    # -- keys
    def _volume(self, folder: str) -> str:
        v = self._volumes.get(folder)
        if v is None:
            p = folder
            while not os.path.ismount(p) and os.path.dirname(p) != p:
                p = os.path.dirname(p)
            v = self._volumes[folder] = p
        return v

    def key(self, path: str, mtime: int, size: int) -> str:
        """The iPhone's key: the path inside the drive (the whole path on the Mac's own disk), the modified time
        in whole seconds, the size."""
        path = os.path.abspath(path)
        root = self._volume(os.path.dirname(path))
        rel = os.path.relpath(path, root) if root != os.sep else path
        return f"{rel}|{int(mtime)}|{int(size)}"

    # -- the drive's index
    def _index_file(self, folder: str) -> str:
        """The places.json covering `folder`: in the nearest `.Photo Browser Metadata` up to the volume ("" none)."""
        hit = self._indexes.get(folder)
        if hit is not None:
            return hit
        root, d, found = self._volume(folder), folder, ""
        while True:
            f = os.path.join(d, META_FOLDER, FILE_NAME)
            if os.path.isfile(f):
                found = f
                break
            if d == root or os.path.dirname(d) == d:
                break
            d = os.path.dirname(d)
        self._indexes[folder] = found
        return found

    def load_drive(self, folder: str) -> None:
        """Reads (or re-reads, if the iPhone wrote a newer backup) the drive's index for `folder`. Worker thread."""
        f = self._index_file(os.path.abspath(folder))
        if not f:
            return
        try:
            mtime = os.path.getmtime(f)
        except OSError:
            return
        if self._drive_mtime.get(f) == mtime:
            return
        idx = Index.read(Path(f))
        with self._lock:
            self._drives[f] = idx
            self._drive_mtime[f] = mtime

    def _drive_for(self, folder: str) -> Index | None:
        f = self._indexes.get(folder)
        return self._drives.get(f) if f else None

    # -- lookups (no disk)
    def bin(self, path: str, mtime: int, size: int) -> str | None:
        key = self.key(path, mtime, size)
        with self._lock:
            b = self.own.file_bins.get(key)
            if b is None:
                drive = self._drive_for(os.path.dirname(os.path.abspath(path)))
                if drive is not None:
                    b = drive.file_bins.get(key)
                    if b is None and not key.isascii():      # an accented name the iPhone saw composed otherwise
                        for form in ("NFC", "NFD"):
                            b = drive.file_bins.get(unicodedata.normalize(form, key))
                            if b is not None:
                                break
        return b

    def _refined(self, b: str, folder: str = "") -> str | None:
        """The bin's name from a geocoder — the iPhone's on the drive, or Apple's asked from this Mac."""
        with self._lock:
            label = self.own.bin_labels.get(b)
            if label is None:
                for idx in ([self._drive_for(folder)] if folder else []) + list(self._drives.values()):
                    if idx is not None and b in idx.bin_labels:
                        label = idx.bin_labels[b]
                        break
        return label

    def place_of(self, b: str) -> "geo_names.Place | None":
        """The nearest town to the bin, from the table that ships with the app (kept in memory)."""
        if b in self._offline:
            return self._offline[b]
        centre = geo_names.bin_centre(b) if b else None
        place = None
        if centre is not None and geo_names.available():
            try:
                place = geo_names.nearest(*centre)
            except Exception:  # noqa: BLE001 — a missing or damaged table: no offline names
                place = None
        self._offline[b] = place
        return place

    def bin_label(self, b: str, folder: str = "") -> str | None:
        """The bin's label: a geocoder's when there is one, else the nearest town's ("" = a spot with no name)."""
        label = self._refined(b, folder)
        if label is None and b:
            label = geo_names.label(self.place_of(b)) if geo_names.available() else None
        return label

    def where(self, b: str) -> tuple[str, str, str, str]:
        """(country code, country, region key "US.NY", region name) of a bin — ("", "", "", "") when unknown."""
        p = self.place_of(b) if b else None
        if p is None or p.km > geo_names.FAR_KM * 3:
            return "", "", "", ""
        return p.cc, p.country, f"{p.cc}.{p.region_code}", p.region

    def text(self, b: str, folder: str = "") -> str:
        """Everything a search may match for the bin, folded: the label, the geocoder's own search text, and the
        nearest town's district, city, region and country."""
        if not b:
            return ""
        hit = self._texts.get(b)
        if hit is None:
            parts = [self.bin_label(b, folder) or ""]
            with self._lock:
                parts.append(self.own.bin_places.get(b, ""))
                parts += [idx.bin_places.get(b, "") for idx in self._drives.values()]
            parts.append(geo_names.search_text(self.place_of(b)) if geo_names.available() else "")
            hit = self._texts[b] = geo_names.fold(", ".join(x for x in parts if x))
        return hit

    def label(self, path: str, mtime: int, size: int) -> str | None:
        """"Hauppauge, NY"; "" for no location; None while it isn't known (not read, or its place not named yet)."""
        b = self.bin(path, mtime, size)
        if b is None:
            return None
        if b == "":
            return ""
        label = self.bin_label(b, os.path.dirname(os.path.abspath(path)))
        if label is None:
            return None
        return label or UNNAMED

    # -- reading and naming (a worker thread)
    def locate(self, files: list[tuple[str, int, int]], progress: Callable[[str], None] | None = None,
               stop: threading.Event | None = None) -> None:
        """Reads the GPS of each of `files` (path, mtime, size) not yet known, then names the places that have
        no name yet (`NAME_LIMIT` at most). `progress` gets a short line now and then."""
        say = progress or (lambda _t: None)
        self.problem = ""
        for folder in {os.path.dirname(os.path.abspath(p)) for p, _m, _s in files}:
            self.load_drive(folder)
        todo = [(p, m, s) for p, m, s in files if self.bin(p, m, s) is None]
        done = 0
        if todo:
            say(f"Reading locations… 0 of {len(todo):,}")

            def one(item: tuple[str, int, int]) -> tuple[str, str]:
                path, mtime, size = item
                place = self.read_gps(path) if os.path.splitext(path)[1].lower() in IMAGE_EXTS | VIDEO_EXTS else None
                return self.key(path, mtime, size), bin_of(*place) if place else ""

            with ThreadPoolExecutor(max_workers=8) as pool:            # bounded, like the iPhone's 12
                for key, b in pool.map(one, todo):
                    with self._lock:
                        self.own.file_bins[key] = b
                        self._dirty = True
                    done += 1
                    if done % 50 == 0:
                        say(f"Reading locations… {done:,} of {len(todo):,}")
                    if stop is not None and stop.is_set():
                        break
        if geo_names.available():                       # every place named at once, from the table
            fresh = sorted({b for p, m, s in files if (b := self.bin(p, m, s)) and b not in self._offline})
            centres = [(b, geo_names.bin_centre(b)) for b in fresh]
            centres = [(b, c) for b, c in centres if c is not None]
            if centres:
                try:
                    found = geo_names.nearest_many([c[0] for _b, c in centres], [c[1] for _b, c in centres])
                    self._offline.update({b: place for (b, _c), place in zip(centres, found)})
                except Exception:  # noqa: BLE001
                    pass
        unnamed = sorted({b for p, m, s in files if (b := self.bin(p, m, s))
                          and self._refined(b, os.path.dirname(os.path.abspath(p))) is None}) if self.refine else []
        if unnamed and not (stop is not None and stop.is_set()):
            say("Naming places…")
            names = self.geocode(unnamed[:NAME_LIMIT], lambda d, t: say(f"Naming places… {d} of {t}"), stop)
            with self._lock:
                for b, (label, search) in names.items():
                    self.own.bin_labels[b] = label
                    self.own.bin_places[b] = search
                    self._texts.pop(b, None)
                    self._dirty = True
            if not names and getattr(self.geocode, "problem", ""):
                self.problem = self.geocode.problem
        self.save()

    # -- one file, now (a search by place: a worker thread)
    def bin_now(self, path: str, mtime: int, size: int) -> str:
        """The file's bin, reading its GPS if that hasn't been done ("" = no location). Kept for next time —
        `save()` when the run is over."""
        b = self.bin(path, mtime, size)
        if b is None:
            if os.path.splitext(path)[1].lower() in IMAGE_EXTS | VIDEO_EXTS:
                try:
                    place = self.read_gps(path)
                except Exception:  # noqa: BLE001 — a damaged file has no place
                    place = None
                b = bin_of(*place) if place else ""
            else:
                b = ""
            with self._lock:
                self.own.file_bins[self.key(path, mtime, size)] = b
                self._dirty = True
        return b

    # -- everything with a location
    def everything(self, roots: list[str]) -> list[tuple[str, str]]:
        """(path, bin) of every file known to have a location, on the Mac's own disk and the drives in `roots`
        — from the indexes alone. The paths are as recorded: a file moved since is simply not there any more
        (whoever lists them checks)."""
        for root in roots:
            self.load_drive(root)
        out: dict[str, str] = {}
        with self._lock:
            own = [(k, b) for k, b in self.own.file_bins.items() if b]
            drives = [(os.path.dirname(os.path.dirname(f)), [(k, b) for k, b in idx.file_bins.items() if b])
                      for f, idx in self._drives.items()]
        for base, items in drives:                       # the iPhone's: paths inside its drive
            for key, b in items:
                out[os.path.join(base, key.rsplit("|", 2)[0])] = b
        for key, b in own:                               # this Mac's: whole paths, or paths inside a drive
            rel = key.rsplit("|", 2)[0]
            if rel.startswith(os.sep):
                out[rel] = b
            else:
                for root in roots:
                    out.setdefault(os.path.join(root, rel), b)
        return list(out.items())

    def summary(self, roots: list[str]) -> list[dict]:
        """Every place with photos, most photos first: {label, bins, count, lat, lng, cc, country, region_key,
        region} — what the Places list and the map show."""
        by_bin: dict[str, int] = {}
        for _path, b in self.everything(roots):
            by_bin[b] = by_bin.get(b, 0) + 1
        if geo_names.available():                        # name them all in one go
            fresh = [b for b in by_bin if b not in self._offline]
            centres = [(b, geo_names.bin_centre(b)) for b in fresh]
            centres = [(b, c) for b, c in centres if c is not None]
            if centres:
                found = geo_names.nearest_many([c[0] for _b, c in centres], [c[1] for _b, c in centres])
                self._offline.update({b: place for (b, _c), place in zip(centres, found)})
        places: dict[str, dict] = {}
        for b, n in by_bin.items():
            centre = geo_names.bin_centre(b)
            if centre is None:
                continue
            label = self.bin_label(b) or UNNAMED
            cc, country, region_key, region = self.where(b)
            p = places.setdefault(label, {"label": label, "bins": [], "count": 0, "lat": 0.0, "lng": 0.0, "cc": cc,
                                          "country": country, "region_key": region_key, "region": region})
            p["bins"].append(b)
            p["count"] += n
            p["lat"] += centre[0] * n
            p["lng"] += centre[1] * n
        for p in places.values():
            p["lat"] /= p["count"]
            p["lng"] /= p["count"]
        return sorted(places.values(), key=lambda p: (-p["count"], p["label"].casefold()))

    def files_at(self, roots: list[str], bins: set[str]) -> list[str]:
        return sorted(path for path, b in self.everything(roots) if b in bins)

    def scan(self, folder: str, progress: Callable[[str], None] | None = None,
             stop: threading.Event | None = None) -> int:
        """Reads the location of every photo and video under `folder` that hasn't been read (a worker thread).
        Returns how many were read."""
        todo: list[tuple[str, int, int]] = []
        for root, dirs, files in os.walk(folder):
            if stop is not None and stop.is_set():
                break
            dirs[:] = [d for d in dirs if not d.startswith(".")]
            self.load_drive(root)
            for name in files:
                if name.startswith(".") or os.path.splitext(name)[1].lower() not in IMAGE_EXTS | VIDEO_EXTS:
                    continue
                path = os.path.join(root, name)
                try:
                    st = os.stat(path)
                except OSError:
                    continue
                if self.bin(path, int(st.st_mtime), st.st_size) is None:
                    todo.append((path, int(st.st_mtime), st.st_size))
            if progress and len(todo) % 500 < 20:
                progress(f"Looking for photos to read… {len(todo):,}")
        for a in range(0, len(todo), 2000):              # in batches: kept as it goes, Stop loses little
            if stop is not None and stop.is_set():
                break
            self.locate(todo[a:a + 2000], lambda t, a=a: progress(f"{t}  ({a:,} of {len(todo):,} done)") if progress
                        else None, stop)
        return len(todo)

    def save(self) -> None:
        with self._lock:
            if not self._dirty:
                return
            data = json.dumps(self.own.to_json(), ensure_ascii=False)
            self._dirty = False
        try:
            self.own_path.parent.mkdir(parents=True, exist_ok=True)
            tmp = self.own_path.with_name(f".{self.own_path.name}.{os.getpid()}.tmp")
            tmp.write_text(data, encoding="utf-8")
            os.replace(tmp, self.own_path)                      # the Mac's own disk: a rename is safe here
        except OSError:
            pass


def gps_of(path: str) -> tuple[float, float] | None:
    """A photo's EXIF GPS or a video's QuickTime location (media_info, cached)."""
    ext = os.path.splitext(path)[1].lower()
    info = media_info.video_info(path) if ext in VIDEO_EXTS else media_info.image_info(path)
    place = info.get("place")
    return (float(place[0]), float(place[1])) if place else None


_helper: list[str] | None | bool = False      # False = not looked for yet
_helper_lock = threading.Lock()
_helper_problem = ""


def _helper_source() -> Path | None:
    here = Path(__file__).resolve().parent
    candidates = [here / "geocode_helper.swift"]
    if getattr(sys, "frozen", False):
        contents = Path(sys.executable).resolve().parent.parent
        candidates += [contents / "Resources" / "geocode_helper.swift",
                       Path(getattr(sys, "_MEIPASS", here)) / "geocode_helper.swift"]
    return next((c for c in candidates if c.is_file()), None)


def helper() -> list[str] | None:
    """The geocoder's command, building it the first time (or when its source is newer). None without swiftc.
    PHOTO_BROWSER_GEOCODE_HELPER names a stand-in (tests)."""
    global _helper, _helper_problem
    with _helper_lock:
        if _helper is not False:
            return _helper
        env = os.environ.get("PHOTO_BROWSER_GEOCODE_HELPER")
        if env:
            _helper = env.split("\x1f")
            return _helper
        _helper = None
        src = _helper_source()
        if sys.platform != "darwin" or src is None:
            _helper_problem = "naming places needs the Mac's geocoder"
            return None
        out = Path.home() / "Library" / "Caches" / "PhotoBrowser" / "geocode_helper"
        log = out.with_name("geocode_helper.log")
        if out.is_file() and out.stat().st_mtime >= src.stat().st_mtime:
            _helper = [str(out)]
            return _helper
        if subprocess.run(["xcode-select", "-p"], capture_output=True).returncode != 0:
            _helper_problem = "naming places needs Xcode's Command Line Tools (xcode-select --install)"
            return None
        out.parent.mkdir(parents=True, exist_ok=True)
        try:
            r = subprocess.run(["xcrun", "swiftc", "-O", "-parse-as-library", "-swift-version", "5", "-o", str(out),
                                str(src)], capture_output=True, text=True, timeout=600)
        except (OSError, subprocess.SubprocessError) as e:
            _helper_problem = f"the place namer couldn't be built ({e})"
            return None
        if r.returncode == 0 and out.is_file():
            _helper = [str(out)]
            try:
                log.unlink()
            except OSError:
                pass
        else:
            _helper_problem = f"the place namer didn't build — see {log}"
            try:
                log.write_text(f"swiftc failed ({r.returncode}) building {src}\n\n{r.stderr or ''}{r.stdout or ''}")
            except OSError:
                pass
        return _helper


def geocode_bins(bins: list[str], progress: Callable[[int, int], None] | None = None,
                 stop: threading.Event | None = None) -> dict[str, tuple[str, str]]:
    """Names for `bins` through `geocode_helper` — {bin: (label, search text)}; "none" answers come back as
    ("", ""), errors (offline, throttled) are left out to be tried again. Sets `geocode_bins.problem` when the
    helper isn't there."""
    geocode_bins.problem = ""
    command = helper()
    if not command:
        geocode_bins.problem = f"places can't be named here — {_helper_problem or 'the place namer is missing'}"
        return {}
    out: dict[str, tuple[str, str]] = {}
    try:
        proc = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL, text=True, bufsize=1)
    except OSError as e:
        geocode_bins.problem = f"places can't be named here — {e}"
        return {}
    try:
        for i, b in enumerate(bins):
            if stop is not None and stop.is_set():
                break
            try:
                lat, lng = (float(x) for x in b.split("|"))
                proc.stdin.write(f"{lat} {lng}\n")
                proc.stdin.flush()
                line = (proc.stdout.readline() or "").rstrip("\n")
            except (OSError, ValueError):
                break
            if line.startswith("ok\t"):
                parts = line.split("\t")
                out[b] = (parts[1] if len(parts) > 1 else "", parts[2] if len(parts) > 2 else "")
            elif line == "none":
                out[b] = ("", "")
            elif not line:                                       # the helper ended
                break
            if progress:
                progress(i + 1, len(bins))
    finally:
        try:
            proc.stdin.close()
        except OSError:
            pass
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
    return out


geocode_bins.problem = ""

_shared: Places | None = None
_shared_lock = threading.Lock()


def shared() -> Places:
    global _shared
    with _shared_lock:
        if _shared is None:
            _shared = Places()
        return _shared
