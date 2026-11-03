"""Safe Finder's bulk metadata editor — the work (metadata_window.py is the window).

Many photos and videos at once — or every one in a folder and its subfolders: the capture date (set, stepping a
few seconds a file so their order holds; shifted, for a camera clock or time zone that was off; read from the
file name; taken from the file's own date; or copied out to the file's own dates), the location, the caption,
title, keywords (replace / add / remove), creator, copyright, rating, the camera, any other tag by its ExifTool
name, and "remove everything else".

**Written the way the iPhone app reads them** — the same tags the downloaders write (`social.write_meta`,
`simpcity.apply_date`): a photo's date in EXIF DateTimeOriginal / CreateDate / ModifyDate with its OffsetTime*;
a video's in the QuickTime dates (kept in UTC, as the format says — ExifTool converts with `QuickTimeUTC`) and
`Keys:CreationDate` with its time zone, which is what AVFoundation calls the creation date. A photo's place in
the EXIF GPS tags, a video's in `Keys:GPSCoordinates` (ISO 6709). A photo's caption in IPTC Caption-Abstract
(the iPhone's first choice), EXIF ImageDescription and XMP dc:description; a video's in `Keys:Description`.

**Time zones.** A date keeps the zone the file already has (OffsetTimeOriginal, or the one on its QuickTime
creation date); a file without one gets this Mac's zone for that day. The QuickTime dates are given to ExifTool
as this Mac's wall-clock time for the same moment, so they and the creation date always agree.

**ExifTool does the writing** — one kept running for the whole edit (`simpcity.ExifSession`) — with
`-overwrite_original_in_place`, so each file keeps its inode and with it its extended attributes: its Photo
Browser tags (shared_tags' marker) and where it was downloaded from. `-P` leaves the file's own dates alone
unless the date edit asks for them to follow. A caption goes through a file (`-TAG<=file`): the session hands
ExifTool one argument per line, and captions have line breaks. A big video is given all the time it needs —
an in-place write cut off half way would damage it.

Nothing is written for the part a file can't take (no date to shift, no date in its name, a video has no lens):
the preview says why, per file.
"""
from __future__ import annotations

import json
import math
import os
import re
import sys
import tempfile
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from typing import Callable, Iterable

PHOTO_EXTS = {".jpg", ".jpeg", ".jpe", ".heic", ".heif", ".hif", ".avif", ".png", ".tif", ".tiff", ".webp",
              ".dng", ".cr2", ".cr3", ".crw", ".nef", ".nrw", ".arw", ".orf", ".rw2", ".raf", ".pef", ".srw"}
VIDEO_EXTS = {".mov", ".mp4", ".m4v", ".3gp", ".3g2"}
# What a folder may hold that can't carry these tags (ExifTool reads but doesn't write them) — counted, not edited.
CANT_WRITE = {".gif", ".bmp", ".webm", ".mkv", ".avi", ".wmv", ".flv", ".mts", ".m2ts", ".mpg", ".mpeg", ".ts"}
# Formats "Remove everything else" leaves alone: stripping a RAW (or a TIFF) can make it unreadable.
NO_STRIP = {".dng", ".cr2", ".cr3", ".crw", ".nef", ".nrw", ".arw", ".orf", ".rw2", ".raf", ".pef", ".srw",
            ".tif", ".tiff"}
SKIP_BUNDLES = (".app", ".photoslibrary", ".fcpbundle", ".imovielibrary", ".tvlibrary", ".musiclibrary")

FMT = "%Y:%m:%d %H:%M:%S"                       # ExifTool's date format
WALK_LIMIT = 200_000                            # files looked at in folders, at most


def ext_of(path: str) -> str:
    return os.path.splitext(path)[1].lower()


def can_edit(path: str) -> bool:
    return ext_of(path) in PHOTO_EXTS or ext_of(path) in VIDEO_EXTS


def is_video(path: str) -> bool:
    return ext_of(path) in VIDEO_EXTS


def media_in(paths: Iterable[str], stop: Callable[[], bool] = lambda: False,
             found: Callable[[int], None] | None = None) -> tuple[list[str], int]:
    """The photos and videos among `paths` and inside any folders among them (every subfolder; hidden items,
    `._` files and app/library bundles skipped), in order, each once — and how many files were passed over
    because their format can't hold these tags (GIF, WebM, AVI…)."""
    out: list[str] = []
    seen: set[str] = set()
    skipped = 0
    looked = 0

    def take(p: str, chosen: bool) -> None:
        nonlocal skipped
        if p in seen:
            return
        if can_edit(p):
            seen.add(p)
            out.append(p)
            if found and len(out) % 200 == 0:
                found(len(out))
        elif chosen or ext_of(p) in CANT_WRITE:
            skipped += 1

    for path in paths:
        if stop():
            break
        if os.path.isdir(path) and not path.endswith(SKIP_BUNDLES):
            for root, dirs, files in os.walk(path):
                dirs[:] = sorted((d for d in dirs if not d.startswith(".") and not d.endswith(SKIP_BUNDLES)),
                                 key=str.lower)
                for name in sorted(files, key=str.lower):
                    if name.startswith("."):
                        continue
                    looked += 1
                    take(os.path.join(root, name), False)
                if stop() or looked >= WALK_LIMIT:
                    break
        elif os.path.isfile(path):
            take(path, True)
    if found:
        found(len(out))
    return out, skipped


# ----------------------------------------------------------------------------- reading what's there

READ_TAGS = ["-DateTimeOriginal", "-CreateDate", "-ModifyDate", "-CreationDate", "-MediaCreateDate", "-DateCreated",
             "-OffsetTimeOriginal", "-OffsetTime",
             "-GPSPosition#", "-GPSLatitude#", "-GPSLatitudeRef", "-GPSLongitude#", "-GPSLongitudeRef",
             "-GPSCoordinates#",
             "-Caption-Abstract", "-ImageDescription", "-UserComment", "-Description",
             "-Title", "-ObjectName", "-Keywords", "-Subject",
             "-Artist", "-By-line", "-Creator", "-Copyright", "-CopyrightNotice", "-Rights",
             "-Rating#", "-Make", "-Model", "-LensModel", "-Software"]
READ_OPTS = ["-j", "-q", "-m", "-api", "largefilesupport=1", "-api", "QuickTimeUTC", "-charset", "filename=utf8"]
READ_CHUNK = 100


@dataclass
class Info:
    """What one file holds now. `date` is the wall-clock time as written; `offset` its zone ("+02:00"), if any."""
    path: str
    video: bool
    date: datetime | None = None
    offset: str = ""
    place: tuple[float, float] | None = None
    caption: str = ""
    title: str = ""
    keywords: list[str] = field(default_factory=list)
    creator: str = ""
    copyright: str = ""
    rating: int = 0
    make: str = ""
    model: str = ""
    lens: str = ""
    software: str = ""
    read: bool = False                          # ExifTool answered for it
    mtime: float = 0.0                          # the file's modified date when read

    def text(self, key: str) -> str:
        if key == "keywords":
            return ", ".join(self.keywords)
        if key == "rating":
            return str(self.rating) if self.rating else ""
        return str(getattr(self, key, "") or "")


_DATE_RX = re.compile(r"^\s*(\d{4}):(\d{2}):(\d{2})[ T](\d{2}):(\d{2})(?::(\d{2}))?(?:\.\d+)?\s*(Z|[+-]\d{2}:?\d{2})?")


def parse_date(v) -> tuple[datetime | None, str]:
    """An ExifTool date ("2024:06:13 10:15:30", maybe with ".123" and "+02:00"/"Z") → (wall-clock time, zone).
    Unset dates (0000:00:00, QuickTime's 1904-01-01, the 1970-01-01 a misread time leaves) are no date."""
    if not isinstance(v, str):
        return None, ""
    m = _DATE_RX.match(v)
    if not m:
        return None, ""
    try:
        d = datetime(int(m[1]), int(m[2]), int(m[3]), int(m[4]), int(m[5]), int(m[6] or 0))
    except ValueError:
        return None, ""
    if d.year < 1800 or (d.year, d.month, d.day) in ((1904, 1, 1), (1970, 1, 1), (1969, 12, 31)):
        return None, ""
    z = m[7] or ""
    if z == "Z":
        z = "+00:00"
    elif z and ":" not in z:
        z = f"{z[:3]}:{z[3:]}"
    return d, z


def _get(meta: dict, key: str):
    v = meta.get(key)
    return meta.get(key + "#") if v is None else v


def _num(v) -> float | None:
    try:
        f = float(v)
    except (TypeError, ValueError):
        return None
    return f if math.isfinite(f) else None


def valid_place(lat: float | None, lon: float | None) -> bool:
    return (lat is not None and lon is not None and math.isfinite(lat) and math.isfinite(lon)
            and -90 <= lat <= 90 and -180 <= lon <= 180 and not (lat == 0 and lon == 0))


def _place(meta: dict) -> tuple[float, float] | None:
    pos = _get(meta, "GPSPosition")
    if isinstance(pos, str):
        parts = pos.replace(",", " ").split()
        if len(parts) >= 2:
            lat, lon = _num(parts[0]), _num(parts[1])
            if valid_place(lat, lon):
                return round(lat, 6), round(lon, 6)
    lat, lon = _num(_get(meta, "GPSLatitude")), _num(_get(meta, "GPSLongitude"))
    if lat is not None and lon is not None:
        if lat > 0 and str(meta.get("GPSLatitudeRef", "")).strip().upper().startswith("S"):
            lat = -lat
        if lon > 0 and str(meta.get("GPSLongitudeRef", "")).strip().upper().startswith("W"):
            lon = -lon
        if valid_place(lat, lon):
            return round(lat, 6), round(lon, 6)
    coords = _get(meta, "GPSCoordinates")
    if isinstance(coords, str):
        parts = coords.replace(",", " ").split()
        if len(parts) >= 2:
            lat, lon = _num(parts[0]), _num(parts[1])
            if valid_place(lat, lon):
                return round(lat, 6), round(lon, 6)
    return None


def _text(meta: dict, *keys: str) -> str:
    for k in keys:
        v = meta.get(k)
        if v in (None, ""):
            continue
        if isinstance(v, list):
            v = ", ".join(str(x) for x in v if str(x).strip())
        s = str(v).strip()
        if s.lower().startswith("charset="):               # an EXIF UserComment's "charset=Ascii …"
            s = s.split(" ", 1)[1].strip() if " " in s else ""
        if s:
            return s
    return ""


def _words(v, split: bool) -> list[str]:
    if v in (None, ""):
        return []
    if isinstance(v, list):
        return [str(x).strip() for x in v if str(x).strip()]
    s = str(v).strip()
    # ExifTool answers one keyword as a plain string — and one keyword may hold a comma ("Paris, France").
    # Only a video's single keywords string (written joined here) is split.
    return [w.strip() for w in s.split(",") if w.strip()] if split else ([s] if s else [])


def info_from(path: str, meta: dict) -> Info:
    video = is_video(path)
    info = Info(path, video, read=bool(meta))
    order = ("CreationDate", "CreateDate", "MediaCreateDate", "DateTimeOriginal") if video else \
        ("DateTimeOriginal", "CreateDate", "DateCreated", "ModifyDate")
    for k in order:
        d, z = parse_date(meta.get(k))
        if d:
            info.date, info.offset = d, z
            break
    if info.date and not info.offset and not video:
        for k in ("OffsetTimeOriginal", "OffsetTime"):
            z = str(meta.get(k) or "").strip()
            if re.fullmatch(r"[+-]\d{2}:\d{2}", z):
                info.offset = z
                break
    info.place = _place(meta)
    info.caption = _text(meta, "Description") if video else \
        _text(meta, "Caption-Abstract", "ImageDescription", "UserComment", "Description")
    info.title = _text(meta, "Title", "ObjectName")
    info.keywords = _words(meta.get("Keywords"), video) or _words(meta.get("Subject"), False)
    info.creator = _text(meta, "Artist", "By-line", "Creator")
    info.copyright = _text(meta, "Copyright", "CopyrightNotice", "Rights")
    r = _num(_get(meta, "Rating"))
    info.rating = int(r) if r is not None and 0 <= r <= 5 else 0
    info.make = _text(meta, "Make")
    info.model = _text(meta, "Model")
    info.lens = _text(meta, "LensModel")
    info.software = _text(meta, "Software")
    return info


def read(paths: list[str], tool, stop: Callable[[], bool] = lambda: False,
         progress: Callable[[int], None] | None = None) -> dict[str, Info]:
    """What each file holds now — ExifTool, a hundred files a call. A file ExifTool can't read comes back
    empty (`read` False) rather than missing."""
    out: dict[str, Info] = {}
    for i in range(0, len(paths), READ_CHUNK):
        if stop():
            break
        batch = [p for p in paths[i:i + READ_CHUNK] if "\n" not in p and "\r" not in p]
        metas: dict[str, dict] = {}
        if batch and tool is not None:
            text = tool.run(*READ_OPTS, *READ_TAGS, *batch, timeout=120 + 2 * len(batch))
            start = text.find("[")
            try:
                items = json.loads(text[start:]) if start >= 0 else []
            except ValueError:
                items = []
            for item in items if isinstance(items, list) else []:
                src = item.get("SourceFile") if isinstance(item, dict) else None
                if src:
                    metas[os.path.normpath(src)] = item
        for p in paths[i:i + READ_CHUNK]:
            info = out[p] = info_from(p, metas.get(os.path.normpath(p), {}))
            try:
                info.mtime = os.stat(p).st_mtime
            except OSError:
                pass
        if progress:
            progress(min(len(paths), i + READ_CHUNK))
    return out


# ----------------------------------------------------------------------------- what to change

TEXT_FIELDS = ("caption", "title", "creator", "copyright", "make", "model", "lens", "software")
LABELS = {"caption": "Caption", "title": "Title", "keywords": "Keywords", "creator": "Creator",
          "copyright": "Copyright", "rating": "Rating", "make": "Camera Make", "model": "Camera Model",
          "lens": "Lens", "software": "Software"}

# The tags a field is written to — photos as the iPhone and other apps read them; videos in QuickTime's Keys
# (what the iPhone writes and AVFoundation reads). "Clear" also empties the older places it may sit in.
PHOTO_TAGS = {"caption": ["IPTC:Caption-Abstract", "EXIF:ImageDescription", "XMP-dc:Description"],
              "title": ["XMP-dc:Title", "IPTC:ObjectName"],
              "creator": ["EXIF:Artist", "IPTC:By-line", "XMP-dc:Creator"],
              "copyright": ["EXIF:Copyright", "IPTC:CopyrightNotice", "XMP-dc:Rights"],
              "make": ["EXIF:Make"], "model": ["EXIF:Model"], "lens": ["EXIF:LensModel"],
              "software": ["EXIF:Software"]}
PHOTO_CLEAR = {"caption": ["EXIF:UserComment"]}
VIDEO_TAGS = {"caption": ["Keys:Description"], "title": ["Keys:Title"], "creator": ["Keys:Artist"],
              "copyright": ["Keys:Copyright"], "make": ["Keys:Make"], "model": ["Keys:Model"],
              "software": ["Keys:Software"]}
VIDEO_CLEAR = {"caption": ["UserData:Description", "ItemList:Description"],
               "title": ["UserData:Title", "ItemList:Title"],
               "creator": ["UserData:Artist", "ItemList:Artist"],
               "copyright": ["UserData:Copyright", "ItemList:Copyright"],
               "make": ["UserData:Make"], "model": ["UserData:Model"], "software": ["UserData:Software"]}

# "Other tags": any tag by name, except the ones that move, rename or link the file (or delete everything —
# that's "Remove everything else", which keeps what has to stay).
_TAG_RX = re.compile(r"^(?:[A-Za-z][A-Za-z0-9-]*:)?[A-Za-z][A-Za-z0-9_-]*$")
BLOCKED = {"filename", "directory", "filepath", "testname", "hardlink", "symlink", "all", "geotag", "geosync",
           "geotime", "filepermissions", "fileuserid", "filegroupid", "fileattributes", "filecreatedate",
           "filemodifydate"}
# ExifTool's own option names — never a bare tag here, so nothing typed can read as one.
OPTIONS = {"tagsfromfile", "execute", "stay_open", "srcfile", "o", "out", "w", "textout", "p", "printformat", "api",
           "charset", "config", "common_args", "overwrite_original", "overwrite_original_in_place",
           "delete_original", "restore_original", "if", "ext", "extension", "r", "recurse", "use", "userparam",
           "globaltimeshift", "d", "dateformat", "csv", "j", "json", "x", "exclude", "efile", "list", "k", "pause",
           "fileorder", "i", "ignore", "progress", "z", "zip", "m", "ignoreminorerrors", "f", "forceprint", "a",
           "duplicates", "e", "g", "groupnames", "n", "printconv", "s", "short", "t", "tab", "u", "unknown", "v",
           "verbose", "q", "quiet", "h", "htmlformat", "b", "binary", "l", "long", "c", "coordformat", "sep",
           "separator", "fast", "fast2", "fast3", "fast4", "fast5", "echo", "echo1", "echo2", "echo3", "echo4"}


class TagError(ValueError):
    pass


def parse_custom(text: str) -> list[tuple[str, str]]:
    """'Tag=value' per line ("Tag=" removes it; '#' lines are notes) → [(tag, value)]. Raises TagError naming
    the first line that isn't one."""
    out: list[tuple[str, str]] = []
    for n, line in enumerate(text.splitlines(), 1):
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        if "=" not in s:
            raise TagError(f"Line {n}: write it as Tag=value (or Tag= to remove the tag).")
        tag, value = s.split("=", 1)
        tag, value = tag.strip(), value.strip()
        if tag.startswith("-"):
            tag = tag[1:]
        if not _TAG_RX.match(tag):
            raise TagError(f"Line {n}: “{tag}” isn't a tag name — letters and digits, with a group before a "
                           "colon if you like (EXIF:ISO, XMP-dc:Title).")
        if tag.split(":")[-1].lower() in BLOCKED or (":" not in tag and tag.lower() in OPTIONS):
            raise TagError(f"Line {n}: {tag} can't be set here — it would rename, move or link the file, or "
                           "remove everything (use “Remove everything else” for that).")
        if len(value) > 2000:
            raise TagError(f"Line {n}: that value is too long.")
        out.append((tag, value))
    return out


@dataclass
class DateEdit:
    mode: str                                   # "set" | "shift" | "name" | "file" | "to_file"
    when: datetime | None = None                # set: the first file's date
    step: int = 0                               # set: seconds added for each file after the first
    shift: timedelta = timedelta(0)             # shift
    pattern: str = ""                           # name: a strptime pattern — "" finds the usual ones
    source: str = "modified"                    # file: "modified" | "created"
    only_missing: bool = False                  # set / name / file: only files that have no date yet
    file_dates: bool = True                     # the file's own created/modified dates follow


@dataclass
class Edit:
    date: DateEdit | None = None
    place: tuple[float, float] | None = None
    clear_place: bool = False
    texts: dict[str, str] = field(default_factory=dict)       # ticked fields → their new value ("" removes)
    keywords: tuple[str, list[str]] | None = None             # ("replace" | "add" | "remove", the words)
    rating: int | None = None                                 # 0 removes
    custom: list[tuple[str, str]] = field(default_factory=list)
    strip: bool = False                                       # remove everything else first

    def empty(self) -> bool:
        return not (self.date or self.place or self.clear_place or self.texts or self.keywords
                    or self.rating is not None or self.custom or self.strip)


@dataclass
class Change:
    """What will be written to one file. `args` are ExifTool tag assignments; a caption goes in at write time
    through a file (`caption`/`caption_tags`); `file_when` is the moment the file's own dates are set to."""
    path: str
    video: bool
    before: datetime | None
    after: datetime | None = None               # the new capture date, when it changes
    offset: str = ""
    args: list[str] = field(default_factory=list)
    caption: str | None = None
    caption_tags: list[str] = field(default_factory=list)
    file_when: datetime | None = None           # aware
    strip: bool = False
    iptc: bool = False
    notes: list[str] = field(default_factory=list)      # what was asked for that this file can't take
    keywords: list[str] | None = None           # the keywords after, when they change

    @property
    def writes(self) -> bool:
        return bool(self.args or self.caption_tags or self.strip or self.file_when)


def local_offset(when: datetime) -> str:
    z = when.astimezone().strftime("%z")       # a naive datetime is taken as this Mac's local time
    return f"{z[:3]}:{z[3:]}" if len(z) == 5 else "+00:00"


def _tz(offset: str) -> timezone:
    sign = -1 if offset.startswith("-") else 1
    h, m = offset[1:].split(":")
    return timezone(sign * timedelta(hours=int(h), minutes=int(m)))


def aware(when: datetime, offset: str) -> datetime:
    return when.replace(tzinfo=_tz(offset or local_offset(when)))


def date_args(video: bool, when: datetime, offset: str) -> list[str]:
    """The capture date as the iPhone app reads it (the downloaders' tags). `offset` is the zone it's in."""
    z = offset or local_offset(when)
    s = when.strftime(FMT)
    if video:
        # QuickTime keeps UTC; ExifTool (with QuickTimeUTC) takes this Mac's local time and converts — so the
        # same moment is handed over as this Mac's wall-clock time.
        here = aware(when, z).astimezone().replace(tzinfo=None).strftime(FMT)
        return [f"-QuickTime:CreateDate={here}", f"-QuickTime:ModifyDate={here}",
                f"-QuickTime:TrackCreateDate={here}", f"-QuickTime:TrackModifyDate={here}",
                f"-QuickTime:MediaCreateDate={here}", f"-QuickTime:MediaModifyDate={here}",
                f"-Keys:CreationDate={s}{z}"]
    return [f"-EXIF:DateTimeOriginal={s}", f"-EXIF:CreateDate={s}", f"-EXIF:ModifyDate={s}",
            f"-EXIF:OffsetTimeOriginal={z}", f"-EXIF:OffsetTimeDigitized={z}", f"-EXIF:OffsetTime={z}"]


def place_args(video: bool, place: tuple[float, float] | None) -> list[str]:
    """Where it was taken (None clears it)."""
    if video:
        if place is None:
            return ["-Keys:GPSCoordinates=", "-UserData:GPSCoordinates="]
        lat, lon = place
        return [f"-Keys:GPSCoordinates={lat:.6f}, {lon:.6f}, 0", f"-UserData:GPSCoordinates={lat:.6f}, {lon:.6f}, 0"]
    if place is None:
        return ["-GPS:all=", "-XMP-exif:GPSLatitude=", "-XMP-exif:GPSLongitude="]
    lat, lon = place
    return [f"-GPSLatitude={abs(lat):.6f}", f"-GPSLatitudeRef={'N' if lat >= 0 else 'S'}",
            f"-GPSLongitude={abs(lon):.6f}", f"-GPSLongitudeRef={'E' if lon >= 0 else 'W'}"]


def parse_place(text: str) -> tuple[float, float] | None:
    """"37.7749, -122.4194", "37.7749 N 122.4194 W", 37°46'29.6"N 122°25'09.8"W, or a Google / Apple Maps link
    → (lat, lon); None when it isn't a place."""
    s = (text or "").strip()
    if not s:
        return None
    from urllib.parse import unquote
    s = unquote(s)
    for rx in (r"@(-?\d+(?:\.\d+)?),(-?\d+(?:\.\d+)?)", r"[?&](?:q|ll|sll|query|center|daddr)=(-?\d+(?:\.\d+)?),\s*(-?\d+(?:\.\d+)?)",
               r"!3d(-?\d+(?:\.\d+)?)!4d(-?\d+(?:\.\d+)?)"):
        m = re.search(rx, s)
        if m:
            lat, lon = float(m[1]), float(m[2])
            return (round(lat, 6), round(lon, 6)) if valid_place(lat, lon) else None
    dms = re.findall(r"(\d+(?:\.\d+)?)\s*°\s*(?:(\d+(?:\.\d+)?)\s*['′]\s*)?(?:(\d+(?:\.\d+)?)\s*(?:\"|″|'')\s*)?([NSEW])", s, re.I)
    if len(dms) == 2:
        vals = []
        for deg, mins, secs, hemi in dms:
            v = float(deg) + float(mins or 0) / 60 + float(secs or 0) / 3600
            vals.append((-v if hemi.upper() in "SW" else v, hemi.upper()))
        if vals[0][1] in "EW":
            vals.reverse()
        lat, lon = vals[0][0], vals[1][0]
        return (round(lat, 6), round(lon, 6)) if valid_place(lat, lon) else None
    m = re.fullmatch(r"\s*(-?\d+(?:\.\d+)?)\s*°?\s*([NS])?\s*[,;\s]\s*(-?\d+(?:\.\d+)?)\s*°?\s*([EW])?\s*", s, re.I)
    if m:
        lat, lon = float(m[1]), float(m[3])
        if m[2] and m[2].upper() == "S":
            lat = -abs(lat)
        if m[4] and m[4].upper() == "W":
            lon = -abs(lon)
        return (round(lat, 6), round(lon, 6)) if valid_place(lat, lon) else None
    return None


# --- dates out of file names

_NAME_DT = re.compile(r"(?<!\d)((?:19|20)\d{2})[-_.]?(0[1-9]|1[0-2])[-_.]?(0[1-9]|[12]\d|3[01])"
                      r"(?:[ T_.\-]+|\s*at\s*)?([01]\d|2[0-3])[-_.:h]?([0-5]\d)[-_.:m]?([0-5]\d)(?:\d{1,3})?(?!\d)", re.I)
_NAME_D = re.compile(r"(?<!\d)((?:19|20)\d{2})[-_.]?(0[1-9]|1[0-2])[-_.]?(0[1-9]|[12]\d|3[01])(?!\d)")
_NAME_UNIX = re.compile(r"(?<!\d)(1[0-9]{9})(\d{3})?(?!\d)")


def _plausible(d: datetime, now: datetime) -> bool:
    return datetime(1900, 1, 1) <= d <= now + timedelta(days=1)


def date_from_name(name: str, pattern: str = "", now: datetime | None = None) -> datetime | None:
    """The date in a file name: IMG_20240613_101530, PXL_20240613_101530123, 2024-06-13 10.15.30, "Screenshot
    2024-06-13 at 10.15.30", VID-20240613-WA0001 (a date alone is taken as noon, so no zone moves its day), or a
    Unix time (1718273730, or in milliseconds). `pattern` (strptime: %Y %m %d %H %M %S %y) looks for that
    instead."""
    now = now or datetime.now()
    base = os.path.splitext(os.path.basename(name))[0]
    if pattern:
        rx = re.escape(pattern)
        for tok, r in (("%Y", r"\d{4}"), ("%m", r"\d{2}"), ("%d", r"\d{2}"), ("%H", r"\d{2}"), ("%M", r"\d{2}"),
                       ("%S", r"\d{2}"), ("%y", r"\d{2}")):
            rx = rx.replace(re.escape(tok), r)
        try:
            found = re.finditer(rx, base)
            for m in found:
                try:
                    d = datetime.strptime(m.group(0), pattern)
                except ValueError:
                    continue
                if _plausible(d, now):
                    return d
        except re.error:
            return None
        return None
    for m in _NAME_DT.finditer(base):
        try:
            d = datetime(int(m[1]), int(m[2]), int(m[3]), int(m[4]), int(m[5]), int(m[6]))
        except ValueError:
            continue
        if _plausible(d, now):
            return d
    for m in _NAME_D.finditer(base):
        try:
            d = datetime(int(m[1]), int(m[2]), int(m[3]), 12, 0, 0)
        except ValueError:
            continue
        if _plausible(d, now):
            return d
    for m in _NAME_UNIX.finditer(base):
        d = datetime.fromtimestamp(int(m[1]))
        if datetime(2001, 1, 1) <= d <= now + timedelta(days=1):
            return d
    return None


def file_date(path: str, source: str) -> datetime | None:
    try:
        st = os.stat(path)
    except OSError:
        return None
    ts = getattr(st, "st_birthtime", None) if source == "created" else None
    return datetime.fromtimestamp(ts if ts else st.st_mtime).replace(microsecond=0)


def _unless_set(when: datetime, info: Info) -> datetime | None:
    """`when` for the file's own dates — None when its modified date already is that (to the second)."""
    return None if info.mtime and abs(info.mtime - when.timestamp()) < 1 else when


def keywords_after(cur: list[str], how: str, words: list[str]) -> list[str]:
    if how == "replace":
        out: list[str] = []
        for w in words:
            if w.lower() not in {x.lower() for x in out}:
                out.append(w)
        return out
    if how == "add":
        out = list(cur)
        for w in words:
            if w.lower() not in {x.lower() for x in out}:
                out.append(w)
        return out
    gone = {w.lower() for w in words}
    return [w for w in cur if w.lower() not in gone]


def plan(infos: list[Info], edit: Edit, now: datetime | None = None) -> list[Change]:
    """One Change per file, in order — with `notes` saying what it can't take."""
    now = now or datetime.now()
    changes: list[Change] = []
    k = 0                                       # files given a date by "set", for the step
    for info in infos:
        ch = Change(info.path, info.video, info.date, offset=info.offset, strip=edit.strip)
        if ch.strip and ext_of(info.path) in NO_STRIP:
            ch.strip = False
            ch.notes.append("RAW and TIFF files keep their metadata (removing it can make them unreadable)")
        d = edit.date
        if d is not None:
            new: datetime | None = None
            offset = info.offset
            if d.mode == "to_file":
                if info.date:
                    ch.file_when = _unless_set(aware(info.date, info.offset), info)
                else:
                    ch.notes.append("no capture date to give the file")
            elif d.only_missing and info.date and d.mode in ("set", "name", "file"):
                pass                            # has one: left as it is
            elif d.mode == "set" and d.when:
                new = d.when + timedelta(seconds=d.step * k)
                k += 1
            elif d.mode == "shift":
                if info.date:
                    new = info.date + d.shift
                else:
                    ch.notes.append("no capture date to shift")
            elif d.mode == "name":
                new = date_from_name(info.path, d.pattern, now)
                if new is None:
                    ch.notes.append("no date in its name")
            elif d.mode == "file":
                new = file_date(info.path, d.source)
                offset = ""                     # a moment on this Mac's clock
                if new is None:
                    ch.notes.append("its file date couldn't be read")
            if new is not None and not datetime(1800, 1, 1) <= new <= datetime(2200, 1, 1):
                ch.notes.append("that date is out of range")
                new = None
            if new is not None:
                z = offset or local_offset(new)
                if new != info.date or z != info.offset:
                    ch.after, ch.offset = new, z
                    ch.args += date_args(info.video, new, z)
                if d.file_dates:
                    ch.file_when = _unless_set(aware(new, z), info)
        if edit.clear_place and info.place is not None:
            ch.args += place_args(info.video, None)
        elif edit.place is not None and info.place != edit.place:
            ch.args += place_args(info.video, edit.place)
        tags = VIDEO_TAGS if info.video else PHOTO_TAGS
        clear = VIDEO_CLEAR if info.video else PHOTO_CLEAR
        for key, value in edit.texts.items():
            if key not in tags:
                ch.notes.append(f"videos have no {LABELS[key].lower()}")
                continue
            if value == info.text(key):
                continue
            if key == "caption":
                ch.caption = value
                ch.caption_tags = tags[key] + (clear.get(key, []) if not value else [])
            else:
                ch.args += [f"-{t}={value}" for t in tags[key]]
                if not value:
                    ch.args += [f"-{t}=" for t in clear.get(key, [])]
            if not info.video and any(t.startswith("IPTC:") for t in tags[key]):
                ch.iptc = True
        if edit.keywords is not None:
            how, words = edit.keywords
            after = keywords_after(info.keywords, how, words)
            if after != info.keywords:
                ch.keywords = after
                if info.video:
                    ch.args.append(f"-Keys:Keywords={', '.join(after)}")
                elif after:
                    ch.args += [f"-IPTC:Keywords={w}" for w in after] + [f"-XMP-dc:Subject={w}" for w in after]
                    ch.iptc = True
                else:
                    ch.args += ["-IPTC:Keywords=", "-XMP-dc:Subject="]
        if edit.rating is not None and edit.rating != info.rating:
            ch.args.append(f"-XMP-xmp:Rating={edit.rating}" if edit.rating else "-XMP-xmp:Rating=")
        for tag, value in edit.custom:
            ch.args.append(f"-{tag}={value}")
        changes.append(ch)
    return changes


# ----------------------------------------------------------------------------- writing

WRITE_OPTS = ["-m", "-overwrite_original_in_place", "-api", "largefilesupport=1", "-charset", "filename=utf8"]


def write_timeout(path: str) -> float:
    """All the time a write could need: an in-place write cut off half way would damage the file. A big video
    is read and written twice over (to a temporary copy, then back into the file)."""
    try:
        size = os.path.getsize(path)
    except OSError:
        size = 0
    return 120.0 + size / 4e6


def outcome(text: str) -> tuple[str, str]:
    """ExifTool's answer for one file → ("updated" | "unchanged" | "failed", why)."""
    errors = [ln.strip() for ln in text.splitlines() if ln.strip().startswith("Error")]
    m = re.search(r"(\d+) image files? updated", text)
    if m and int(m[1]) > 0:
        return "updated", ""
    if errors:
        why = re.sub(r"^Error:\s*", "", errors[0])
        why = re.sub(r"\s+-\s+/.*$", "", why)               # "… - /Volumes/…/IMG_1.JPG"
        return "failed", why
    if re.search(r"(\d+) image files? unchanged", text):
        return "unchanged", ""
    return "failed", "ExifTool didn't say it was written" if text.strip() else "ExifTool didn't answer"


def caption_file(text: str) -> str:
    """A caption in a temporary file, for `-TAG<=file` (the caller removes it)."""
    fd, path = tempfile.mkstemp(prefix="caption-", suffix=".txt")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(text)
    return path


def write(ch: Change, tool, caption_path: str = "") -> tuple[str, str]:
    """Writes one file's change. Returns ("updated" | "unchanged" | "failed", why)."""
    if "\n" in ch.path or "\r" in ch.path:
        return "failed", "its name has a line break, which can't be handed to ExifTool"
    if not os.path.isfile(ch.path):
        return "failed", "it isn't there any more"
    timeout = write_timeout(ch.path)
    done = False
    if ch.strip:
        keep = ["-Keys:CreationDate"] if ch.video else \
            ["-EXIF:DateTimeOriginal", "-EXIF:CreateDate", "-EXIF:OffsetTimeOriginal"]
        res, why = outcome(tool.run(*WRITE_OPTS, "-P", "-all=", "-tagsFromFile", "@", "-ColorSpaceTags",
                                    "-Orientation", *keep, ch.path, timeout=timeout))
        if res == "failed":
            return res, why
        done = res == "updated"
    args = list(ch.args)
    if ch.caption is not None:
        for t in ch.caption_tags:
            args.append(f"-{t}<={caption_path}" if ch.caption and caption_path else f"-{t}=")
    opts = list(WRITE_OPTS)
    if ch.video:
        opts += ["-api", "QuickTimeUTC"]
    if ch.iptc:
        opts += ["-charset", "iptc=UTF8"]
        args.insert(0, "-IPTC:CodedCharacterSet=UTF8")
    if ch.file_when is not None:
        here = ch.file_when.astimezone().replace(tzinfo=None).strftime(FMT)
        args.append(f"-FileModifyDate={here}")
        if sys.platform == "darwin":
            args.append(f"-FileCreateDate={here}")
    else:
        opts.append("-P")                       # the file's own dates stay as they are
    if args:
        res, why = outcome(tool.run(*opts, *args, ch.path, timeout=timeout))
        if res == "failed":
            return res, why
        done = done or res == "updated"
    if ch.file_when is not None:
        ts = ch.file_when.timestamp()
        try:
            os.utime(ch.path, (ts, ts))         # (an earlier date also moves a Mac file's creation date back)
            done = True
        except OSError as e:
            return "failed", f"its file dates couldn't be set ({e.strerror or e})"
    return ("updated" if done else "unchanged"), ""


# ----------------------------------------------------------------------------- for the window

def common(values: list[str]) -> tuple[str, int]:
    """(the value every file shares, else "", how many different values there are)."""
    distinct = set(values)
    return (values[0] if len(distinct) == 1 and values else ""), len(distinct)


def fmt_date(d: datetime | None, offset: str = "") -> str:
    return d.strftime("%Y-%m-%d %H:%M:%S") + (f" {offset}" if offset else "") if d else "—"


def fmt_place(p: tuple[float, float] | None) -> str:
    return f"{p[0]:.6f}, {p[1]:.6f}" if p else ""
