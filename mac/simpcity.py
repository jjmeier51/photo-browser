#!/usr/bin/env python3
"""SimpCity thread downloader — the parts with no window (Safe Finder's window is simpcity_downloader.py).

From a person's folder, a simpcity.cr thread is read page by page; every goonbox.cr image is resolved
to its full-size file and every turbo.cr video to its file, and they are saved into a "simpcity"
folder inside the person's folder, tagged "simpcity". A photo or video that carries its own capture
date keeps it; one that doesn't gets the date of the forum post it came from.

**One record, both apps.** What was downloaded is kept on the drive, in the folder itself —
`<person>/simpcity/.simpcity.json` — so the iPhone app (`SimpCityService.swift`) and Safe Finder read
and write the same list: a thread downloaded on the Mac is never fetched again on the iPhone, and the
other way round. Keys are `goonbox:<id>` / `turbo:<id>`; files are named `<id>.<ext>`, so a file
already in the folder counts as done even if the record was lost. Something deleted from the folder
stays deleted: the record, not the folder, says what's done. A file that failed is listed too
("failed"), so the next run tries it again even when it doesn't re-read that page. Each save re-reads
the file and merges,
so neither app drops what the other added. The record also keeps each thread's address and the last
page read, so "Get New" starts where the thread had got to.

Both sites check that a real browser is asking (DDoS-Guard on simpcity.cr, Cloudflare on goonbox.cr),
so the pages are read in a real browser the person can see and answer — Qt WebEngine here, WebKit on
the iPhone. The JavaScript that reads a page (`EXTRACT_POSTS_JS`, `RESOLVE_JS`) is kept identical to
the Swift copy in `SimpCityService.swift`.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import threading
import time
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from urllib.parse import urlsplit

FOLDER = "simpcity"
RECORD = ".simpcity.json"
FORMAT = "photobrowser-simpcity"
VERSION = 1
TAG = "simpcity"

IMAGE_EXTS = {"jpg", "jpeg", "png", "webp", "gif", "heic", "avif"}
VIDEO_EXTS = {"mp4", "mov", "m4v", "webm", "mkv"}

MIN_POST = 946_684_800       # 2000-01-01: no post is older — a time below this is a misread, not a date
UPSCALE_UNDER = 250 * 1024   # a photo smaller than this is upscaled 2× (Lanczos)
UPSCALED_TAG = "upscaled"    # what the app's own upscales are tagged too
MADE = 2                     # record marker: the file went through the current rules (WebP → JPEG, the
                             # upscale, the post date read right); older entries are brought up to it once


# ----------------------------------------------------------------------------- addresses

_THREAD = re.compile(r"^(https?://[^/]*simpcity\.[a-z]+/threads/[^/?#]+?\.(\d+))(?:/.*)?$", re.I)


def thread_base(url: str) -> str | None:
    """The thread's first-page address, whatever page/post/query the pasted link points at:
    `https://simpcity.cr/threads/helen-owen-ig-helenowen.64622/page-3#post-9` →
    `https://simpcity.cr/threads/helen-owen-ig-helenowen.64622/`. None when it isn't a thread link."""
    u = (url or "").strip()
    if u and "://" not in u:
        u = "https://" + u
    m = _THREAD.match(u.split("#", 1)[0].split("?", 1)[0])
    return m.group(1).rstrip("/") + "/" if m else None


def thread_id(base: str) -> str:
    m = _THREAD.match(base)
    return m.group(2) if m else ""


def page_url(base: str, n: int) -> str:
    return base if n <= 1 else f"{base}page-{n}"


_GOONBOX = re.compile(r"^https?://(?:www\.)?goonbox\.[a-z]+/(?:img|i|image|v|f)/([A-Za-z0-9_-]{4,})", re.I)
_TURBO = re.compile(r"^https?://(?:www\.)?turbo\.[a-z]+/(?:v|d|e|embed|f)/([A-Za-z0-9_-]{4,})", re.I)


def media_key(url: str) -> tuple[str, str] | None:
    """(kind, id) for a link the downloader takes: a goonbox.cr image page or a turbo.cr video."""
    u = (url or "").strip()
    if m := _GOONBOX.match(u):
        return ("goonbox", m.group(1))
    if m := _TURBO.match(u):
        return ("turbo", m.group(1))
    return None


def page_link(kind: str, ident: str) -> str:
    """goonbox's image page for an id (its API takes the same id). turbo links are kept as posted."""
    return f"https://goonbox.cr/img/{ident}" if kind == "goonbox" else f"https://turbo.cr/embed/{ident}"


def extension(url: str, kind: str) -> str:
    """The file extension for a resolved full-size URL (its path, not the query)."""
    path = urlsplit(url).path
    ext = path.rsplit(".", 1)[-1].lower() if "." in path.rsplit("/", 1)[-1] else ""
    if ext == "jpeg":
        ext = "jpg"
    if ext in IMAGE_EXTS or ext in VIDEO_EXTS:
        return ext
    return "mp4" if kind == "turbo" else "jpg"


# ----------------------------------------------------------------------------- what a thread holds


@dataclass
class Item:
    kind: str           # "goonbox" | "turbo"
    ident: str
    link: str           # the page the forum linked (resolved to the file at download time)
    post: str = ""      # forum post id it came from (the earliest, when posted more than once)
    posted: float = 0   # that post's time (unix)

    @property
    def key(self) -> str:
        return f"{self.kind}:{self.ident}"


def collect(posts: list[dict], into: dict[str, Item] | None = None) -> dict[str, Item]:
    """Items from the posts a page read returned (`[{id, time, urls}]`), one per key, keeping the
    earliest post a file appeared in."""
    out = into if into is not None else {}
    for p in posts or []:
        when = float(p.get("time") or 0)
        if when < MIN_POST:
            when = 0
        for u in p.get("urls") or []:
            k = media_key(str(u))
            if not k:
                continue
            link = page_link(*k) if k[0] == "goonbox" else str(u)
            item = Item(k[0], k[1], link, str(p.get("id") or ""), when)
            have = out.get(item.key)
            if have is None or (when and (not have.posted or when < have.posted)):
                out[item.key] = item
    return out


# ----------------------------------------------------------------------------- the shared record


@dataclass
class Record:
    """`<person>/simpcity/.simpcity.json` — see the module notes. Shared with the iPhone app."""
    folder: Path
    items: dict[str, dict] = field(default_factory=dict)
    threads: dict[str, dict] = field(default_factory=dict)
    failed: dict[str, dict] = field(default_factory=dict)    # not downloaded yet: tried again by the next run

    @property
    def file(self) -> Path:
        return self.folder / RECORD

    @classmethod
    def load(cls, folder: str | Path) -> "Record":
        rec = cls(Path(folder))
        rec._merge(rec._read())
        return rec

    def _read(self) -> dict:
        try:
            doc = json.loads(self.file.read_bytes().decode("utf-8"))
            return doc if isinstance(doc, dict) and doc.get("format") == FORMAT else {}
        except (OSError, ValueError):
            return {}

    def _merge(self, doc: dict) -> None:
        for k, v in (doc.get("items") or {}).items():
            if isinstance(v, dict) and k not in self.items:
                self.items[k] = v
        for k, v in (doc.get("failed") or {}).items():
            if isinstance(v, dict) and k not in self.failed:
                self.failed[k] = v
        for k in [k for k in self.failed if k in self.items]:
            del self.failed[k]
        for k, v in (doc.get("threads") or {}).items():
            if not isinstance(v, dict):
                continue
            mine = self.threads.get(k)
            if mine is None or float(v.get("checked") or 0) > float(mine.get("checked") or 0):
                self.threads[k] = {**(mine or {}), **v,
                                   "pages": max(int(v.get("pages") or 0), int((mine or {}).get("pages") or 0))}

    def has(self, key: str) -> bool:
        return key in self.items

    def add(self, item: Item, file: str, upscaled: bool = False) -> None:
        entry = {"file": file, "post": item.post, "posted": int(item.posted or 0), "at": int(time.time()), "made": MADE}
        if upscaled or self.items.get(item.key, {}).get("upscaled"):
            entry["upscaled"] = True
        self.items[item.key] = entry
        self.failed.pop(item.key, None)

    def misdated(self) -> bool:
        """Entries written while post times were misread (Oct 28: XenForo's `data-time` holds "12:34 PM",
        read as 12 seconds after 1970) — a full read of the thread recovers their dates."""
        return any(0 < float(v.get("posted") or 0) < MIN_POST for v in self.items.values())

    def redate(self, items: dict[str, Item], read_all: bool) -> None:
        """After reading the thread: a misread post time is replaced by the real one; when every page
        was read, one still unknown (its post is gone) becomes 0 — no date — so the thread isn't read
        from page 1 again for it."""
        for k, v in self.items.items():
            if 0 < float(v.get("posted") or 0) < MIN_POST:
                fresh = items.get(k)
                if fresh and fresh.posted >= MIN_POST:
                    v["posted"] = int(fresh.posted)
                elif read_all:
                    v["posted"] = 0

    def fixes(self, items: dict[str, Item], folder: str | Path) -> list[tuple[Item, str]]:
        """Downloaded files still in the folder that predate the current rules (`made`): each with the
        best post date known — the one just read from the thread, else the recorded one if it's real."""
        try:
            present = set(os.listdir(folder))
        except OSError:
            return []
        out: list[tuple[Item, str]] = []
        for key, entry in sorted(self.items.items()):
            name = str(entry.get("file") or "")
            if not name or name not in present or int(entry.get("made") or 0) >= MADE:
                continue
            kind, _, ident = key.partition(":")
            fresh = items.get(key)
            recorded = float(entry.get("posted") or 0)
            posted = fresh.posted if fresh and fresh.posted >= MIN_POST else (recorded if recorded >= MIN_POST else 0)
            out.append((Item(kind, ident, fresh.link if fresh else page_link(kind, ident),
                             fresh.post if fresh else str(entry.get("post") or ""), posted), name))
        return out

    def note_failed(self, item: Item) -> None:
        """Remembered so a later run tries it again even when it doesn't re-read the page it was on."""
        self.failed[item.key] = {"link": item.link, "post": item.post, "posted": int(item.posted or 0)}

    def retry_items(self) -> dict[str, Item]:
        out: dict[str, Item] = {}
        for k, v in self.failed.items():
            kind, _, ident = k.partition(":")
            if kind in ("goonbox", "turbo") and ident and k not in self.items:
                out[k] = Item(kind, ident, str(v.get("link") or page_link(kind, ident)), str(v.get("post") or ""),
                              float(v.get("posted") or 0))
        return out

    def note_thread(self, base: str, title: str, pages: int) -> None:
        t = self.threads.get(base, {})
        self.threads[base] = {"title": title or t.get("title", ""), "pages": max(pages, int(t.get("pages") or 0)),
                              "checked": int(time.time())}

    def start_page(self, base: str) -> int:
        """Where a run picks the thread up: the last page read (it may have grown since), else 1 — and 1
        while any entry's date was misread, to read it again."""
        if self.misdated():
            return 1
        return max(1, int(self.threads.get(base, {}).get("pages") or 1))

    def last_thread(self) -> str | None:
        if not self.threads:
            return None
        return max(self.threads.items(), key=lambda kv: float(kv[1].get("checked") or 0))[0]

    def save(self) -> None:
        """Writes the record, merged with whatever is on the drive now (the other app may have added
        to it). Raises OSError when the drive can't be written."""
        self._merge(self._read())
        doc = {"format": FORMAT, "version": VERSION, "updated": int(time.time()), "by": "Safe Finder",
               "threads": dict(sorted(self.threads.items())), "items": dict(sorted(self.items.items())),
               "failed": dict(sorted(self.failed.items()))}
        write_file(self.file, json.dumps(doc, ensure_ascii=False, indent=1).encode("utf-8"))


def files_by_id(folder: str | Path) -> dict[str, str]:
    """`<id>` → file name for what's already in the folder (its downloads are named `<id>.<ext>`)."""
    out: dict[str, str] = {}
    try:
        names = os.listdir(folder)
    except OSError:
        return out
    for n in names:
        if n.startswith(".") or "." not in n:
            continue
        stem, ext = n.rsplit(".", 1)
        if ext.lower() in IMAGE_EXTS or ext.lower() in VIDEO_EXTS:
            out.setdefault(stem, n)
    return out


def todo(items: dict[str, Item], record: Record, folder: str | Path) -> tuple[list[Item], int]:
    """The items still to download — what the pages read hold plus what failed last time — and how many
    the folder already had without the record knowing (those are added to the record — they're done)."""
    for k, it in record.retry_items().items():
        items.setdefault(k, it)
    on_disk = files_by_id(folder)
    left: list[Item] = []
    adopted = 0
    for item in items.values():
        if record.has(item.key):
            continue
        if item.ident in on_disk:
            record.add(item, on_disk[item.ident])
            adopted += 1
            continue
        left.append(item)
    left.sort(key=lambda i: (i.posted or 0, i.key))
    return left, adopted


# ----------------------------------------------------------------------------- writing to the drive


def _on_exfat(path: str) -> bool:
    try:
        import spare_folders
        return spare_folders.on_exfat(path)
    except Exception:
        return False


def make_folder(path: str | Path) -> None:
    """The simpcity folder — from a spare on an exFAT drive (CLAUDE.md #12), a plain mkdir otherwise."""
    p = Path(path)
    if p.is_dir():
        return
    try:
        import spare_folders
        if spare_folders.make_dir(str(p)):
            return
    except Exception:
        pass
    p.mkdir(parents=True, exist_ok=True)


def write_file(dest: Path, data: bytes) -> None:
    """Small file onto the drive: in place on exFAT (no rename, no fsync), temp → fsync → rename elsewhere."""
    if _on_exfat(str(dest.parent)):
        with open(dest, "wb") as f:
            f.write(data)
        return
    tmp = dest.parent / f".{dest.name}.saving"
    with open(tmp, "wb") as f:
        f.write(data)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, dest)


def human_size(path: str | Path) -> str:
    try:
        n = float(os.path.getsize(path))
    except OSError:
        return "?"
    for unit in ("bytes", "KB", "MB", "GB"):
        if n < 1024 or unit == "GB":
            return f"{int(n)} bytes" if unit == "bytes" else f"{n:.1f} {unit}"
        n /= 1024
    return "?"


def place(src: str | Path, folder: str | Path, name: str) -> Path:
    """Moves a finished download from the Mac's temp folder into the drive folder under `name`
    (never over an existing file). Copy-then-delete: the temp folder is on another volume."""
    folder = Path(folder)
    dest = folder / name
    if dest.exists():
        stem, ext = os.path.splitext(name)
        n = 2
        while (folder / f"{stem} {n}{ext}").exists():
            n += 1
        dest = folder / f"{stem} {n}{ext}"
    if _on_exfat(str(folder)):
        shutil.copyfile(src, dest)
    else:
        part = folder / f".{dest.name}.part"
        shutil.copyfile(src, part)
        with open(part, "rb+") as f:
            os.fsync(f.fileno())
        os.replace(part, dest)
    st = os.stat(src)
    os.utime(dest, (st.st_atime, st.st_mtime))
    try:
        os.remove(src)
    except OSError:
        pass
    return dest


# ----------------------------------------------------------------------------- fetching a file


# The image servers (simp*.cuckcapital.cr) refuse a request without a Referer — 403 {"message": "not
# allowed"} — and serve the original to one with goonbox's (checked Oct 28: no signature needed).
REFERER = "https://goonbox.cr/"
REFERER_HOSTS = ("cuckcapital.cr",)

_SSL = None


def ssl_context():
    """HTTPS checks against the usual certificates — and, for a Python with none of its own (the
    python.org installer before "Install Certificates"), the Mac's (`/etc/ssl/cert.pem`)."""
    global _SSL
    if _SSL is None:
        import ssl
        ctx = ssl.create_default_context()
        if not ctx.cert_store_stats().get("x509_ca"):
            for bundle in ("/etc/ssl/cert.pem", "/usr/local/etc/openssl/cert.pem", "/opt/homebrew/etc/openssl@3/cert.pem"):
                if os.path.exists(bundle):
                    ctx.load_verify_locations(bundle)
                    break
            else:
                try:
                    import certifi
                    ctx.load_verify_locations(certifi.where())
                except ImportError:
                    pass
        _SSL = ctx
    return _SSL


def fetch(url: str, headers: dict[str, str], path: str, connect_timeout: float = 20,
          limit: float = 600) -> tuple[str | None, str]:
    """Downloads `url` to `path` with a plain request (on a worker thread). Returns (path, "") or
    (None, why): an HTTP status, a page where a file belongs, no connection, too slow. `connect_timeout`
    bounds the wait for an answer and each read; `limit` the whole transfer."""
    import urllib.error
    import urllib.request
    started = time.monotonic()
    try:
        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req, timeout=connect_timeout, context=ssl_context()) as resp:
            ctype = (resp.headers.get("Content-Type") or "").split(";")[0].strip()
            if ctype.startswith("text/"):
                return None, f"the server sent a page ({ctype}), not the file"
            with open(path, "wb") as f:
                while chunk := resp.read(1 << 20):
                    f.write(chunk)
                    if time.monotonic() - started > limit:
                        raise TimeoutError(f"still downloading after {int(limit)} s")
        if os.path.getsize(path) < 64:
            raise ValueError("an empty file")
        return path, ""
    except urllib.error.HTTPError as e:
        why = f"HTTP {e.code}"
    except urllib.error.URLError as e:
        why = f"couldn't connect ({e.reason})"
    except (OSError, ValueError, TimeoutError) as e:
        why = str(e) or type(e).__name__
    try:
        os.remove(path)
    except OSError:
        pass
    return None, why


# ----------------------------------------------------------------------------- dates

_DATE_FMT = "%Y:%m:%d %H:%M:%S"


def find_exiftool() -> str | None:
    p = shutil.which("exiftool")
    if p:
        return p
    for cand in ("/opt/homebrew/bin/exiftool", "/usr/local/bin/exiftool"):
        if os.path.exists(cand):
            return cand
    return None


_READY = re.compile(rb"\{ready\d*\}\r?\n")


class ExifSession:
    """One ExifTool kept running for a whole run (`-stay_open`): starting a fresh one for every read and
    write cost about a second a file. Each call sends its arguments, one per line, then `-execute`, and
    reads the answer up to ExifTool's `{ready}` — **within `timeout` seconds**: an ExifTool that doesn't
    answer is killed and the call made the old way, one ExifTool for it; after two such failures the run
    stays with one-at-a-time (`broken`, said once in `note`). A kept-open ExifTool that never answered had
    stalled a whole run with nothing logged. Thread-safe (the files are settled on worker threads)."""

    TIMEOUT = 30.0                                       # seconds an answer may take

    def __init__(self, path: str) -> None:
        self.path = path
        self.proc: subprocess.Popen | None = None
        self.lock = threading.Lock()
        self.buf = b""
        self.failures = 0
        self.broken = False
        self.note = ""                                   # set once when it falls back, for the log

    def run(self, *args: str, timeout: float | None = None) -> str:
        if any("\n" in a for a in args):
            return ""
        timeout = timeout or self.TIMEOUT
        with self.lock:
            if not self.broken:
                try:
                    return self._kept_open(args, timeout)
                except (OSError, ValueError, TimeoutError, EOFError) as e:
                    self._kill()
                    self.failures += 1
                    if self.failures >= 2:
                        self.broken = True
                        self.note = (f"ExifTool didn't answer when kept open ({type(e).__name__}) — running it "
                                     "once per file instead.")
            return self._once(args, timeout)

    def _kept_open(self, args: tuple[str, ...], timeout: float) -> str:
        import select
        if self.proc is None or self.proc.poll() is not None:
            self.proc = subprocess.Popen([self.path, "-stay_open", "True", "-@", "-"], stdin=subprocess.PIPE,
                                         stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            self.buf = b""
        if self.proc.stdin is None or self.proc.stdout is None:
            raise OSError("no pipes")
        self.proc.stdin.write(("\n".join([*args, "-execute"]) + "\n").encode("utf-8"))
        self.proc.stdin.flush()
        fd = self.proc.stdout.fileno()
        deadline = time.monotonic() + timeout
        while not (m := _READY.search(self.buf)):
            left = deadline - time.monotonic()
            if left <= 0:
                raise TimeoutError("no answer")
            ready, _, _ = select.select([fd], [], [], left)
            if ready:
                chunk = os.read(fd, 65536)
                if not chunk:
                    raise EOFError("ExifTool quit")
                self.buf += chunk
        out, self.buf = self.buf[:m.start()], self.buf[m.end():]
        return out.decode("utf-8", "replace")

    def _once(self, args: tuple[str, ...], timeout: float) -> str:
        try:
            res = subprocess.run([self.path, *args], capture_output=True, timeout=timeout * 4)
            return res.stdout.decode("utf-8", "replace")
        except (OSError, subprocess.SubprocessError):
            return ""

    def _kill(self) -> None:
        if self.proc is not None:
            try:
                self.proc.kill()
                self.proc.wait(timeout=5)
            except (OSError, subprocess.SubprocessError):
                pass
        self.proc = None
        self.buf = b""

    def close(self) -> None:
        with self.lock:
            if self.proc and self.proc.poll() is None:
                try:
                    self.proc.stdin.write(b"-stay_open\nFalse\n")
                    self.proc.stdin.flush()
                    self.proc.wait(timeout=10)
                except (OSError, ValueError, subprocess.SubprocessError):
                    self._kill()
            self.proc = None


def _parse(s) -> datetime | None:
    if not isinstance(s, str) or not s.strip():
        return None
    core = s.strip()[:19]
    for fmt in (_DATE_FMT, "%Y-%m-%dT%H:%M:%S", "%Y-%m-%d %H:%M:%S"):
        try:
            d = datetime.strptime(core, fmt)
            # Unset dates read as 0000/1904, and the 1969-12-31/1970-01-01 a misread time wrote are no date.
            return d if d.year > 1970 else None
        except ValueError:
            continue
    return None


def is_video(path: str) -> bool:
    return path.rsplit(".", 1)[-1].lower() in VIDEO_EXTS


def embedded_date(path: str, tool: ExifSession | None) -> datetime | None:
    """The capture date the file carries itself (what both apps sort by), or None."""
    if not tool:
        return None
    tags = ["-Keys:CreationDate", "-QuickTime:CreateDate", "-QuickTime:MediaCreateDate"] if is_video(path) \
        else ["-EXIF:DateTimeOriginal", "-EXIF:CreateDate", "-EXIF:ModifyDate", "-XMP:DateCreated"]
    out = tool.run("-j", "-q", "-m", "-api", "largefilesupport=1", "-d", _DATE_FMT, *tags, path)
    try:
        meta = (json.loads(out) or [{}])[0] if out.strip() else {}
    except ValueError:
        return None
    # The same fields, in the same order, the iPhone app reads a capture date from.
    for k in ("CreationDate", "DateTimeOriginal", "CreateDate", "ModifyDate", "MediaCreateDate", "DateCreated"):
        d = _parse(meta.get(k))
        if d:
            return d
    return None


def apply_date(path: str, posted: float, tool: ExifSession | None) -> str:
    """Keeps a capture date the file already has; otherwise writes the forum post's date into it
    (EXIF for photos; the QuickTime dates Photos/AVFoundation read for videos). The file's own dates
    follow the capture date either way. Returns "kept", "post", or "none" (nothing to go on / no
    ExifTool — then only the file dates are set). Writes keep the file itself (its inode, so its
    tag attribute), whether it's a temp download or a file already in the drive folder."""
    have = embedded_date(path, tool)
    if posted and posted < MIN_POST:
        posted = 0
    if have:
        when, outcome = have, "kept"
    elif posted:
        when, outcome = datetime.fromtimestamp(posted), "none"
    else:
        return "none"
    s = when.strftime(_DATE_FMT)
    tags = [f"-FileCreateDate={s}", f"-FileModifyDate={s}"]
    if outcome == "none" and tool:
        if is_video(path):
            tz = when.astimezone().strftime("%z")
            tags += ["-api", "QuickTimeUTC", f"-QuickTime:CreateDate={s}", f"-QuickTime:ModifyDate={s}",
                     f"-QuickTime:TrackCreateDate={s}", f"-QuickTime:MediaCreateDate={s}",
                     f"-Keys:CreationDate={s}{tz[:3]}:{tz[3:]}"]
        else:
            tags += [f"-EXIF:DateTimeOriginal={s}", f"-EXIF:CreateDate={s}", f"-EXIF:ModifyDate={s}"]
    if tool:
        out = tool.run("-m", "-overwrite_original_in_place", "-api", "largefilesupport=1", *tags, path)
        if outcome == "none" and "1 image files updated" in out:
            outcome = "post"
    ts = when.timestamp()
    try:
        os.utime(path, (ts, ts))
    except OSError:
        pass
    return outcome


# ----------------------------------------------------------------------------- photos: WebP → JPEG, small → 2×


def prepare_image(path: str) -> tuple[str, bool]:
    """A downloaded photo made ready: a WebP becomes a JPEG, and one under 250 KB is upscaled 2× with
    Lanczos. EXIF and the colour profile are carried over (the orientation tag too — pixels aren't
    turned). Returns the file now to use (a new `.jpg` beside it for a WebP) and whether it was
    upscaled. Animated WebP/GIF, and anything Pillow can't open, are left as they are."""
    ext = path.rsplit(".", 1)[-1].lower() if "." in os.path.basename(path) else ""
    if ext not in ("jpg", "jpeg", "png", "webp"):
        return path, False
    try:
        small = os.path.getsize(path) < UPSCALE_UNDER
    except OSError:
        return path, False
    if ext != "webp" and not small:
        return path, False
    try:
        from PIL import Image
    except ImportError:
        return path, False
    try:
        with Image.open(path) as img:
            if getattr(img, "n_frames", 1) > 1:
                return path, False
            img.load()
            exif = img.info.get("exif")
            icc = img.info.get("icc_profile")
            out_img = img.resize((img.width * 2, img.height * 2), Image.Resampling.LANCZOS) if small else img.copy()
        as_png = ext == "png"
        if not as_png and out_img.mode not in ("RGB", "L"):
            # JPEG has no transparency: put it on white.
            rgba = out_img.convert("RGBA")
            flat = Image.new("RGB", rgba.size, (255, 255, 255))
            flat.paste(rgba, mask=rgba.split()[3])
            out_img = flat
        dest = path.rsplit(".", 1)[0] + (".png" if as_png else ".jpg")
        part = dest + ".part"
        kw = {"icc_profile": icc} if icc else {}
        if exif:
            kw["exif"] = exif
        if as_png:
            out_img.save(part, "PNG", **kw)
        else:
            out_img.save(part, "JPEG", quality=95, subsampling=0, **kw)
        os.replace(part, dest)
        if dest != path:
            os.remove(path)
        return dest, small
    except (OSError, ValueError, Image.DecompressionBombError):
        try:
            os.remove(path.rsplit(".", 1)[0] + (".png" if ext == "png" else ".jpg") + ".part")
        except OSError:
            pass
        return path, False


def fix_file(folder: str | Path, item: Item, name: str, tool: ExifSession | None, tmp: str | Path) -> tuple[str, str, bool]:
    """Brings a file downloaded before the current rules up to them, where it lies: WebP → JPEG and the
    small-photo upscale (on a copy in `tmp`, then back into the folder), and the post's date when it
    has no real one of its own (the 1969 a misread time wrote doesn't count). Returns (its name now,
    the date outcome, upscaled). A file that changes name (`.webp` → `.jpg`) is a new file beside the
    old, which is removed — the caller moves its tags across."""
    folder = Path(folder)
    path = folder / name
    ext = name.rsplit(".", 1)[-1].lower() if "." in name else ""
    try:
        small = os.path.getsize(path) < UPSCALE_UNDER
    except OSError:
        return name, "none", False
    if ext == "webp" or (small and ext in ("jpg", "jpeg", "png")):
        work = Path(tmp) / f"fix-{item.ident}-{int(time.time() * 1000)}.{ext}"
        shutil.copyfile(path, work)
        made, upscaled = prepare_image(str(work))
        if made != str(work) or upscaled:
            outcome = apply_date(made, item.posted, tool)
            new_ext = made.rsplit(".", 1)[-1]
            if f".{new_ext}" == os.path.splitext(name)[1].lower():
                replace_file(made, path)
                return name, outcome, upscaled
            final = place(made, folder, f"{os.path.splitext(name)[0]}.{new_ext}")
            os.remove(path)
            return final.name, outcome, upscaled
        try:
            os.remove(work)
        except OSError:
            pass
    return name, apply_date(str(path), item.posted, tool), False


def replace_file(src: str | Path, dest: Path) -> None:
    """New contents for a file already in the folder, keeping its tag attribute: written in place on
    exFAT (no rename), else beside it and swapped in with the attribute copied over."""
    if _on_exfat(str(dest.parent)):
        shutil.copyfile(src, dest)
    else:
        part = dest.parent / f".{dest.name}.part"
        shutil.copyfile(src, part)
        with open(part, "rb+") as f:
            os.fsync(f.fileno())
        try:
            import shared_tags
            marker = shared_tags.xattr_get(str(dest), shared_tags.MARKER)
            if marker is not None:
                shared_tags.xattr_set(str(part), shared_tags.MARKER, marker)
        except Exception:
            pass
        os.replace(part, dest)
    st = os.stat(src)
    os.utime(dest, (st.st_atime, st.st_mtime))
    try:
        os.remove(src)
    except OSError:
        pass


# ----------------------------------------------------------------------------- page scripts
# Kept identical to the copies in PhotoBrowser/SimpCityService.swift.

EXTRACT_POSTS_JS = r"""
(() => {
  const title = document.title || '';
  const challenge = (/DDoS-Guard|Just a moment|Checking your browser|Attention Required/i.test(title)
    || !!document.querySelector('#challenge-form, #cf-challenge-running, .ddg-captcha, [data-ddg-origin]'))
    && !document.querySelector('.p-body, article.message');
  const html = document.documentElement;
  const loggedIn = html.getAttribute('data-logged-in') === 'true';
  const inQuote = (e) => !!e.closest('blockquote, .bbCodeBlock--quote, .bbCodeQuote, .message-signature');
  const link = (v) => {
    try {
      const x = new URL(v, location.href);
      const to = /\/redirect\/?$/.test(x.pathname) ? x.searchParams.get('to') : null;
      if (to) {
        if (/^https?:\/\//i.test(to)) return to;
        let b = to.replace(/-/g, '+').replace(/_/g, '/');
        while (b.length % 4) b += '=';
        const d = atob(b);
        if (/^https?:\/\//i.test(d)) return d;
      }
      return x.href;
    } catch (e) { return ''; }
  };
  const posts = [];
  document.querySelectorAll('article.message, .message--post, li.message').forEach((p) => {
    const id = (p.getAttribute('data-content') || p.id || '').replace(/^(js-)?post-/, '');
    const t = p.querySelector('.message-attribution time, time.u-dt, time[data-timestamp], time[datetime], time[data-time]');
    let time = 0;
    if (t) {
      // XenForo 2.2+: data-timestamp is the time, data-time is a label ("12:34 PM"); older: data-time.
      const num = (v) => (/^\d{9,}$/.test(v || '') ? parseInt(v, 10) : 0);
      time = num(t.getAttribute('data-timestamp'))
        || Math.floor(Date.parse((t.getAttribute('datetime') || '').replace(/([+-]\d\d)(\d\d)$/, '$1:$2')) / 1000)
        || num(t.getAttribute('data-time')) || 0;
      if (!(time >= 946684800)) time = 0;
    }
    const body = p.querySelector('.message-userContent') || p.querySelector('.message-body') || p;
    const urls = new Set();
    const add = (e, v) => { if (v && !inQuote(e)) urls.add(link(v)); };
    body.querySelectorAll('a[href]').forEach((a) => add(a, a.getAttribute('href')));
    body.querySelectorAll('[data-url]').forEach((e) => add(e, e.getAttribute('data-url')));
    body.querySelectorAll('img').forEach((i) => ['data-url', 'data-src', 'src'].forEach((k) => add(i, i.getAttribute(k))));
    body.querySelectorAll('iframe, embed, video, video source').forEach((e) => add(e, e.getAttribute('src') || e.getAttribute('data-src') || e.getAttribute('data-url')));
    body.querySelectorAll('[data-s9e-mediaembed-src]').forEach((e) => add(e, e.getAttribute('data-s9e-mediaembed-src')));
    posts.push({ id, time, urls: [...urls].filter(Boolean) });
  });
  let last = 1;
  document.querySelectorAll('.pageNav-main a, .pageNav-page a, a.pageNav-jump, .pageNavSimple a').forEach((a) => {
    const m = (a.getAttribute('href') || '').match(/\/page-(\d+)/); if (m) last = Math.max(last, parseInt(m[1], 10));
    const n = parseInt((a.textContent || '').trim(), 10); if (n) last = Math.max(last, n);
  });
  const cur = (location.pathname.match(/\/page-(\d+)/) || [0, 1])[1];
  const heading = document.querySelector('h1.p-title-value');
  return { title: heading ? heading.textContent.trim() : title, challenge, loggedIn, posts, ready: document.readyState, href: location.href,
           last: Math.max(last, parseInt(cur, 10) || 1), page: parseInt(cur, 10) || 1,
           blocked: !!document.querySelector('.blockMessage--error, .p-body-pageContent .blockMessage') && posts.length === 0 };
})()
"""

# What a goonbox.cr image page or turbo.cr video page holds: the full-size file's address. `__KIND__`
# is replaced with "goonbox" or "turbo" before it runs. Candidates are ranked — the page's own video or
# download link, then direct media links, the og:/twitter: tags, then the largest picture showing —
# and thumbnails (`.md.` / `.th.` / `/thumbs/`) are never taken for the full-size file.
RESOLVE_JS = r"""
(() => {
  const KIND = "__KIND__";
  const title = document.title || '';
  const checking = /Just a moment|DDoS-Guard|Checking your browser|Attention Required|Verify you are human/i.test(title)
    || !!document.querySelector('#challenge-form, #cf-challenge-running, .cf-turnstile, [data-ddg-origin]');
  const abs = (v) => { try { return new URL(v, location.href).href; } catch (e) { return ''; } };
  const thumb = (u) => !u || /^(data|blob):/i.test(u) || /\.(md|th|thumb|sm|small)\.[a-z0-9]+(\?|$)|\/thumbs?\/|favicon|logo|avatar|\.svg(\?|$)/i.test(u);
  const isVideo = (u) => /\.(mp4|mov|m4v|webm|mkv)(\?|$)/i.test(u);
  const isImage = (u) => /\.(jpe?g|png|webp|gif|heic|avif)(\?|$)/i.test(u);
  const cands = [];
  const push = (raw, w) => {
    const u = abs(raw || '');
    if (thumb(u)) return;
    let s = w;
    if (KIND === 'turbo' && isVideo(u)) s += 30;
    if (KIND === 'goonbox' && isImage(u)) s += 30;
    if (/cuckcapital|\/panda\//i.test(u)) s += 20;
    if (/[?&]s=/.test(u)) s += 5;
    cands.push([u, s]);
  };
  try { const v = document.querySelector('video'); if (v && v.paused && v.play) { v.muted = true; v.play().catch(() => {}); } } catch (e) {}
  document.querySelectorAll('video source[src], video[src]').forEach((v) => push(v.currentSrc || v.getAttribute('src'), 100));
  try { performance.getEntriesByType('resource').forEach((e) => { if (isVideo(e.name)) push(e.name, 95); }); } catch (e) {}
  document.querySelectorAll('a[download][href]').forEach((a) => push(a.getAttribute('href'), 90));
  document.querySelectorAll('a[href]').forEach((a) => { const h = a.getAttribute('href') || ''; if (isVideo(h) || isImage(h)) push(h, 80); });
  document.querySelectorAll('meta[property="og:video"], meta[property="og:video:url"], meta[property="og:video:secure_url"]').forEach((m) => push(m.content, 70));
  document.querySelectorAll('meta[property="og:image"], meta[name="twitter:image"]').forEach((m) => push(m.content, 60));
  document.querySelectorAll('link[rel="image_src"]').forEach((l) => push(l.href, 60));
  let best = '', area = 0;
  document.querySelectorAll('img').forEach((i) => {
    const a = (i.naturalWidth || 0) * (i.naturalHeight || 0), src = i.currentSrc || i.src;
    if (a > area && !thumb(src)) { area = a; best = src; }
  });
  if (best && area >= 120000) push(best, 75);
  cands.sort((a, b) => b[1] - a[1]);
  const gone = /not found|404|removed|deleted/i.test(title) && cands.length === 0;
  const challenge = checking && cands.length === 0;
  return { challenge, url: cands.length ? cands[0][0] : '', title, gone, ready: document.readyState, href: location.href };
})()
"""


def resolve_js(kind: str) -> str:
    return RESOLVE_JS.replace("__KIND__", "turbo" if kind == "turbo" else "goonbox")


# goonbox.cr is a script-built viewer over a JSON API: `GET /api/images/<id>` answers
# `{image: {original_url, original_filename, …}, is_deleted, …}` — `original_url` is the full-size file.
# Asked from a goonbox page (so the browser's clearance and cookies go with it). Qt's runJavaScript
# doesn't wait for a promise, so the answer is left in `window.__simpcity[id]` and read by polling.
GOONBOX_API_START_JS = r"""
(() => {
  const id = "__ID__";
  window.__simpcity = window.__simpcity || {};
  delete window.__simpcity[id];
  fetch('/api/images/' + encodeURIComponent(id), { headers: { 'Accept': 'application/json' }, credentials: 'include' })
    .then((r) => r.text().then((t) => {
      let j = {}; try { j = JSON.parse(t); } catch (e) {}
      const im = j.image || {};
      window.__simpcity[id] = { status: r.status, url: im.original_url || '', name: im.original_filename || '',
                                deleted: !!(j.is_deleted || im.deleted_at) };
    }))
    .catch(() => { window.__simpcity[id] = { status: 0, url: '' }; });
  return true;
})()
"""

GOONBOX_API_RESULT_JS = r"""((window.__simpcity || {})["__ID__"] || null)"""


def goonbox_api_js(ident: str) -> tuple[str, str]:
    """(start, read-the-answer) scripts for one goonbox id. Ids are [A-Za-z0-9_-] (see `media_key`)."""
    safe = re.sub(r"[^A-Za-z0-9_-]", "", ident)
    return GOONBOX_API_START_JS.replace("__ID__", safe), GOONBOX_API_RESULT_JS.replace("__ID__", safe)


# Whether the person is logged in to SimpCity: XenForo's own flag, or — once its login page has been
# seen — that page being gone (the login form submitted and the forum shown).
LOGGED_IN_JS = r"""
(() => {
  if (document.documentElement.getAttribute('data-logged-in') === 'true') return 'yes';
  if (document.querySelector('input[type="password"]') || /\/login/.test(location.pathname)) return 'login-page';
  return document.readyState === 'complete' ? 'left-login' : 'loading';
})()
"""


def json_call(expr: str) -> str:
    """A page script made to answer with JSON text — the one form every browser bridge hands back intact
    (an object can arrive as nothing at all) — and to say what went wrong when it throws."""
    return ("(() => { try { return JSON.stringify(" + expr.strip() + "); } "
            "catch (e) { return JSON.stringify({ error: String(e) }); } })()")


def parse_result(raw) -> dict:
    """The answer of a `json_call` script as a dict ({} for nothing / not an object)."""
    if isinstance(raw, dict):
        return raw
    if isinstance(raw, (str, bytes)):
        try:
            v = json.loads(raw)
        except ValueError:
            return {}
        return v if isinstance(v, dict) else {}
    return {}


def describe_page(r: dict | None) -> str:
    """What a thread page showed, for the message when it couldn't be read."""
    if not r:
        return "the page never answered (still loading, or blocked)"
    if r.get("challenge"):
        return "SimpCity kept showing its “checking your browser” page — answer it in the window"
    if r.get("error"):
        return f"reading it failed: {r['error']}"
    posts = len(r.get("posts") or [])
    return (f"it showed “{r.get('title') or 'no title'}” ({r.get('href') or '?'}), {posts} post{'s' if posts != 1 else ''}, "
            f"page {r.get('page') or '?'}, {r.get('ready') or '?'}")
