"""ExifTool wrapper — the single place metadata is read from and written to files.

Why ExifTool: it is the only tool that reads *and writes* EXIF/IPTC/XMP consistently across JPEG,
HEIC, PNG, RAW and QuickTime/MP4 video, and it does it in place while preserving everything it
doesn't touch. Reads are batched (one process per few hundred files, JSON out); writes go through
`write()` which builds a single command per file, or one command for a whole batch when every file
gets the same values (the bulk case), with `-overwrite_original` so no `_original` copies litter
the drive.

The `Field` table below is the app's vocabulary: each editable field maps to the ExifTool tag(s)
written and the flat tag names read back. Captions use the MWG (Metadata Working Group) composite
tags so the EXIF ImageDescription, IPTC Caption-Abstract and XMP dc:description all stay in sync —
that's what makes the iOS app (and Photos, Lightroom…) agree on what the caption is.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime
from typing import Iterable

DATE_FMT = "%Y:%m:%d %H:%M:%S"          # ExifTool's canonical date format


@dataclass(frozen=True)
class Field:
    key: str            # app-level id
    label: str
    read: tuple[str, ...]        # flat tag names to look for (first non-empty wins)
    write: tuple[str, ...]       # tags written (each gets the same value)
    multiline: bool = False
    is_list: bool = False        # comma-separated list (keywords)
    numeric: bool = False


FIELDS: list[Field] = [
    Field("caption", "Caption", ("Description", "ImageDescription", "Caption-Abstract"),
          ("MWG:Description",), multiline=True),
    Field("title", "Title", ("Title", "ObjectName"), ("XMP:Title", "IPTC:ObjectName")),
    Field("keywords", "Keywords", ("Subject", "Keywords"), ("MWG:Keywords",), is_list=True),
    Field("artist", "Artist / Creator", ("Creator", "Artist", "By-line"), ("MWG:Creator",)),
    Field("copyright", "Copyright", ("Rights", "Copyright", "CopyrightNotice"), ("MWG:Copyright",)),
    Field("rating", "Rating (0–5)", ("Rating",), ("XMP:Rating",), numeric=True),
    Field("make", "Camera make", ("Make",), ("Make",)),
    Field("model", "Camera model", ("Model",), ("Model",)),
    Field("lens", "Lens", ("LensModel",), ("LensModel",)),
    Field("software", "Software", ("Software",), ("Software",)),
]
FIELD_BY_KEY = {f.key: f for f in FIELDS}

READ_TAGS = [
    "FileName", "Directory", "FileSize", "FileModifyDate", "FileCreateDate", "MIMEType", "FileType",
    "ImageWidth", "ImageHeight", "Duration", "Orientation",
    "DateTimeOriginal", "CreateDate", "ModifyDate", "MediaCreateDate", "TrackCreateDate",
    "GPSLatitude", "GPSLongitude", "GPSAltitude", "GPSPosition",
    "ISO", "FNumber", "ExposureTime", "FocalLength", "LensModel",
] + [t for f in FIELDS for t in f.read]

# Tags that carry the capture date. `AllDates` = DateTimeOriginal + CreateDate + ModifyDate in every
# group (EXIF and QuickTime); the Track/Media ones are video-only and not covered by AllDates.
DATE_WRITE_TAGS = ("AllDates",)
VIDEO_DATE_WRITE_TAGS = ("QuickTime:TrackCreateDate", "QuickTime:TrackModifyDate",
                         "QuickTime:MediaCreateDate", "QuickTime:MediaModifyDate")
FILE_DATE_TAGS = ("FileModifyDate", "FileCreateDate")


def find_exiftool() -> str | None:
    p = shutil.which("exiftool")
    if p:
        return p
    for cand in ("/opt/homebrew/bin/exiftool", "/usr/local/bin/exiftool"):
        if os.path.exists(cand):
            return cand
    return None


class ExifTool:
    def __init__(self, path: str | None = None):
        self.path = path or find_exiftool()

    @property
    def available(self) -> bool:
        return self.path is not None

    def version(self) -> str:
        if not self.path:
            return ""
        try:
            return subprocess.run([self.path, "-ver"], capture_output=True, text=True, timeout=20).stdout.strip()
        except (OSError, subprocess.SubprocessError):
            return ""

    # ---- reading -------------------------------------------------------------------------------

    def read(self, paths: Iterable[str], chunk: int = 250) -> dict[str, dict]:
        """Metadata for each path → flat dict (ExifTool tag name → value). Missing/failed files
        simply aren't in the result. Dates come back as 'YYYY:MM:DD HH:MM:SS' strings; GPS and
        Orientation are numeric (`-n`)."""
        out: dict[str, dict] = {}
        if not self.path:
            return out
        paths = [p for p in paths if p]
        for i in range(0, len(paths), chunk):
            batch = paths[i:i + chunk]
            cmd = [self.path, "-j", "-n", "-q", "-m", "-fast2", "-charset", "filename=utf8",
                   "-api", "largefilesupport=1", "-d", DATE_FMT, "-sep", ", "]
            cmd += [f"-{t}" for t in READ_TAGS]
            cmd += batch
            try:
                res = subprocess.run(cmd, capture_output=True, text=True, timeout=600)
                items = json.loads(res.stdout) if res.stdout.strip() else []
            except (OSError, subprocess.SubprocessError, json.JSONDecodeError):
                continue
            for item in items:
                src = item.get("SourceFile")
                if src:
                    out[os.path.normpath(src)] = item
        return out

    # ---- writing -------------------------------------------------------------------------------

    def write(self, paths: Iterable[str], tags: dict[str, str | None], *, preserve_file_date: bool = False) -> tuple[int, list[str]]:
        """Writes `tags` (tag → value; None or "" deletes the tag) to every path in one ExifTool
        run. Returns (files updated, error lines). Videos get their Track/Media dates too when the
        capture date is among the tags."""
        paths = [p for p in paths if p]
        if not self.path or not paths or not tags:
            return 0, ["ExifTool not available or nothing to write."]
        cmd = [self.path, "-overwrite_original", "-m", "-q", "-use", "MWG", "-charset", "filename=utf8",
               "-api", "largefilesupport=1", "-sep", ", "]
        if preserve_file_date:
            cmd.append("-P")
        for tag, value in tags.items():
            cmd.append(f"-{tag}=" if value in (None, "") else f"-{tag}={value}")
        cmd += paths
        try:
            res = subprocess.run(cmd, capture_output=True, text=True, timeout=1800)
        except (OSError, subprocess.SubprocessError) as e:
            return 0, [str(e)]
        errors = [ln for ln in (res.stderr or "").splitlines() if ln.strip() and not ln.startswith("Warning")]
        updated = _count_updated(res.stdout) if res.stdout else (len(paths) if res.returncode == 0 and not errors else 0)
        return updated, errors

    def write_each(self, per_file: dict[str, dict[str, str | None]], preserve_file_date: bool = False,
                   progress=None) -> tuple[int, list[str]]:
        """Different values per file (renaming-by-preview, per-file dates). Runs one ExifTool
        invocation per file; `progress(done, total)` is called after each."""
        done = 0
        errors: list[str] = []
        total = len(per_file)
        for i, (path, tags) in enumerate(per_file.items(), 1):
            n, errs = self.write([path], tags, preserve_file_date=preserve_file_date)
            done += n
            errors += [f"{os.path.basename(path)}: {e}" for e in errs]
            if progress:
                progress(i, total)
        return done, errors


def _count_updated(stdout: str) -> int:
    # ExifTool prints "    1 image files updated" (quiet mode suppresses it, so fall back to 0 → caller handles)
    for ln in stdout.splitlines():
        parts = ln.strip().split()
        if len(parts) >= 4 and parts[-1] == "updated":
            try:
                return int(parts[0])
            except ValueError:
                pass
    return 0


# ---- helpers shared by the UI -------------------------------------------------------------------

def parse_date(s: str | None) -> datetime | None:
    """ExifTool date string → datetime (ignores a trailing timezone or sub-seconds)."""
    if not s or not isinstance(s, str):
        return None
    core = s.strip()[:19]
    for fmt in (DATE_FMT, "%Y:%m:%d %H:%M", "%Y-%m-%d %H:%M:%S", "%Y:%m:%d"):
        try:
            return datetime.strptime(core, fmt)
        except ValueError:
            continue
    return None


def format_date(d: datetime) -> str:
    return d.strftime(DATE_FMT)


def capture_date(meta: dict) -> datetime | None:
    """The best capture date in a metadata dict — same priority the iOS app uses."""
    for k in ("DateTimeOriginal", "CreateDate", "MediaCreateDate", "TrackCreateDate", "ModifyDate", "FileModifyDate"):
        d = parse_date(meta.get(k))
        if d:
            return d
    return None


def field_value(meta: dict, field: Field) -> str:
    for k in field.read:
        v = meta.get(k)
        if v in (None, ""):
            continue
        if isinstance(v, list):
            return ", ".join(str(x) for x in v)
        return str(v)
    return ""


def is_video(meta: dict | None, path: str) -> bool:
    if meta and str(meta.get("MIMEType", "")).startswith("video/"):
        return True
    return os.path.splitext(path)[1].lower() in {".mov", ".mp4", ".m4v", ".avi", ".mkv", ".webm", ".3gp", ".mts", ".m2ts"}


def date_tags_for(path: str, meta: dict | None, when: datetime, file_dates: bool) -> dict[str, str]:
    """The tag set that moves a file's capture date to `when` (plus file-system dates if asked)."""
    s = format_date(when)
    tags = {t: s for t in DATE_WRITE_TAGS}
    if is_video(meta, path):
        tags.update({t: s for t in VIDEO_DATE_WRITE_TAGS})
    if file_dates:
        tags.update({t: s for t in FILE_DATE_TAGS})
    return tags


def gps_tags(lat: float | None, lon: float | None) -> dict[str, str | None]:
    if lat is None or lon is None:
        return {"GPSLatitude": None, "GPSLatitudeRef": None, "GPSLongitude": None, "GPSLongitudeRef": None}
    return {"GPSLatitude": f"{abs(lat):.6f}", "GPSLatitudeRef": "N" if lat >= 0 else "S",
            "GPSLongitude": f"{abs(lon):.6f}", "GPSLongitudeRef": "E" if lon >= 0 else "W"}


def install_hint() -> str:
    if sys.platform == "darwin":
        return "Install it with Homebrew:  brew install exiftool   (or from exiftool.org), then relaunch."
    return "Install exiftool (e.g. apt install libimage-exiftool-perl), then relaunch."
