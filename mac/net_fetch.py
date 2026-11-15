"""Getting a file from the web properly — one place for what every downloader here needs and each had only part of.

A review of the downloaders (Nov 2026) found that a download cut short passed for a finished one: `urllib`'s
`read(n)` returns what arrived and says nothing when the server hangs up early, so a 5 KB piece of a 1 MB video
was saved, recorded as downloaded and never fetched again. Fixed here, with the rest of what good downloaders do
(gallery-dl, yt-dlp, cyberdrop-dl):

- **A download is whole or it failed.** The bytes written are compared with `Content-Length`; a dropped
  connection (`IncompleteRead`, a reset) is an error, not an ending.
- **It picks up where it stopped.** A cut-off transfer is asked for again from the byte it reached (`Range`, with
  `If-Range` and the answer's strong ETag or Last-Modified, so a file that changed starts over) — a video
  two-thirds down isn't fetched from the start.
- **It tries again politely.** Timeouts, resets, a truncated answer, and — when asked to (`busy=True`) — 429 and
  5xx are retried up to `attempts` times, waiting longer each time by a random amount (exponential backoff with
  full jitter, so parallel lanes don't all return at once) and obeying `Retry-After` when the server says how long.
- **A page isn't a photo.** An HTML or JSON error body saved under a media name is refused (`looks_like_page`).
- **Cookies stay with their site.** A redirect to another host is followed *without* the `Cookie` and
  `Authorization` headers (urllib would send them on).
- **Stop means stop**: `stop()` is asked between chunks and during every wait.

Also here because every downloader needs them: `put` (a finished file onto the drive — the partial removed if the
copy fails, the size checked, exFAT's no-rename rule kept), `load_json` / `save_json` (a record that keeps a
`.bak` of its last good self, so a save cut off by a pulled cable doesn't cost what was downloaded), `safe_name`
and `RunLog` (every failure with why, for the person and for a Retry Failed).

Standard library only; nothing here knows about any site.
"""
from __future__ import annotations

import http.client
import json
import os
import random
import shutil
import ssl
import time
import unicodedata
import urllib.error
import urllib.request
from pathlib import Path
from typing import Callable
from urllib.parse import urlsplit

CHUNK = 1 << 20
BUSY = (429, 500, 502, 503, 504)
MAX_WAIT = 120.0


class Stopped(Exception):
    """The person pressed Stop."""


def backoff(attempt: int, base: float = 2.0, cap: float = MAX_WAIT, retry_after: float | None = None) -> float:
    """Seconds to wait before try number `attempt` + 1 (attempt counts from 1): the server's `Retry-After`
    when it gave one (capped), else a random time up to base·2^(attempt−1) — "full jitter"."""
    if retry_after is not None and retry_after >= 0:
        return min(cap, retry_after)
    return random.uniform(0.3, min(cap, base * (2 ** max(0, attempt - 1))))


def retry_after_of(headers) -> float | None:
    """`Retry-After` as seconds: a number, or an HTTP date."""
    value = (headers.get("Retry-After") or "").strip() if headers is not None else ""
    if not value:
        return None
    if value.isdigit():
        return float(value)
    try:
        from email.utils import parsedate_to_datetime
        return max(0.0, parsedate_to_datetime(value).timestamp() - time.time())
    except (TypeError, ValueError, OverflowError):
        return None


def wait(seconds: float, stop: Callable[[], bool] | None = None) -> None:
    """Sleeps in short steps so Stop is noticed. Raises `Stopped`."""
    end = time.monotonic() + max(0.0, seconds)
    while True:
        if stop is not None and stop():
            raise Stopped()
        left = end - time.monotonic()
        if left <= 0:
            return
        time.sleep(min(0.25, left))


class _KeepCookiesHome(urllib.request.HTTPRedirectHandler):
    """A redirect to another host is followed without the headers that say who you are."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        new = super().redirect_request(req, fp, code, msg, headers, newurl)
        if new is not None and urlsplit(newurl).hostname != urlsplit(req.full_url).hostname:
            for name in ("Cookie", "Authorization"):
                new.headers.pop(name, None)
                new.unredirected_hdrs.pop(name, None)
        return new


_openers: dict[int, urllib.request.OpenerDirector] = {}


def opener(context: ssl.SSLContext | None = None) -> urllib.request.OpenerDirector:
    key = id(context)
    if key not in _openers:
        handlers: list = [_KeepCookiesHome()]
        if context is not None:
            handlers.append(urllib.request.HTTPSHandler(context=context))
        _openers[key] = urllib.request.build_opener(*handlers)
    return _openers[key]


def looks_like_page(path: str | os.PathLike) -> bool:
    """Whether the file is a web page or a JSON error where a photo or video should be."""
    try:
        with open(path, "rb") as f:
            head = f.read(512).lstrip(b"\xef\xbb\xbf \t\r\n").lower()
        size = os.path.getsize(path)
    except OSError:
        return False
    if head.startswith((b"<!doctype html", b"<html", b"<head", b"<body", b"<script")):
        return True
    return size < 4096 and head.startswith((b"{", b"[")) and (b'"error' in head or b'"message' in head or b'"status' in head)


def _strong(etag: str) -> bool:
    return bool(etag) and not etag.startswith("W/")


def fetch_to_file(url: str, headers: dict[str, str], path: str, *, connect_timeout: float = 20,
                  limit: float = 600, check: Callable | None = None, attempts: int = 3, busy: bool = True,
                  resume: bool = True, stop: Callable[[], bool] | None = None, min_bytes: int = 64,
                  context: ssl.SSLContext | None = None,
                  progress: Callable[[int, int | None], None] | None = None) -> tuple[str | None, str]:
    """`url` into `path` (module notes). Returns (path, "") or (None, why) — why is "HTTP 404", "the server sent a
    page…", "couldn't connect (…)", "cut off after …", "stopped". `connect_timeout` bounds the wait for an answer
    and each read, `limit` the whole transfer. `check(size, type)` sees the answer before any of it is read and
    may raise (the exception is passed on — a video already downloaded is skipped that way). `busy`: also retry
    429 and 5xx (callers with their own, tuned waits for a busy server pass False)."""
    started = time.monotonic()
    have = 0                               # bytes of the file already on disk from an earlier, cut-off try
    validator = ""                         # the ETag or Last-Modified those bytes came with
    why = "no answer"
    checked = False
    for attempt in range(1, max(1, attempts) + 1):
        retry_after = None
        retryable = False
        try:
            if stop is not None and stop():
                raise Stopped()
            h = dict(headers)
            if have and validator and resume:
                h["Range"] = f"bytes={have}-"
                h["If-Range"] = validator
            else:
                have = 0
            req = urllib.request.Request(url, headers=h)
            with opener(context).open(req, timeout=connect_timeout) as resp:
                status = getattr(resp, "status", 200)
                ctype = (resp.headers.get("Content-Type") or "").split(";")[0].strip()
                if ctype.startswith("text/"):
                    _remove(path)
                    return None, f"the server sent a page ({ctype}), not the file"
                length = resp.headers.get("Content-Length")
                body = int(length) if length and length.isdigit() else None
                if status == 206 and have:
                    total = have + body if body is not None else None
                    mode = "ab"
                else:                                   # the whole file (a 200 to a Range request: it changed)
                    have, total, mode = 0, body, "wb"
                if check and not checked:
                    checked = True                      # once: a retry is the same file
                    check(total, ctype)
                etag = resp.headers.get("ETag") or ""
                validator = etag if _strong(etag) else (resp.headers.get("Last-Modified") or "")
                with open(path, mode) as f:
                    while True:
                        if stop is not None and stop():
                            raise Stopped()
                        chunk = resp.read(CHUNK)
                        if not chunk:
                            break
                        f.write(chunk)
                        have += len(chunk)
                        if progress:
                            progress(have, total)
                        if time.monotonic() - started > limit:
                            raise TimeoutError(f"still downloading after {int(limit)} s")
                if total is not None and have < total:
                    raise http.client.IncompleteRead(b"", total - have)
            if os.path.getsize(path) < min_bytes:
                _remove(path)
                return None, "an empty file"
            if looks_like_page(path):
                _remove(path)
                return None, "the server sent a page, not the file"
            return path, ""
        except Stopped:
            _remove(path)
            return None, "stopped"
        except urllib.error.HTTPError as e:
            why = f"HTTP {e.code}"
            retryable = busy and e.code in BUSY
            retry_after = retry_after_of(e.headers)
            if e.code == 416:                           # our Range no longer fits: start over
                have, validator, retryable = 0, "", True
        except http.client.IncompleteRead:
            why = f"cut off after {have:,} bytes"
            retryable = True
        except urllib.error.URLError as e:
            why = f"couldn't connect ({e.reason})"
            retryable = True
        except TimeoutError as e:
            why = str(e) or "timed out"
            retryable = "still downloading" not in why
        except (http.client.HTTPException, ConnectionError, ssl.SSLError) as e:
            why = f"the connection dropped ({type(e).__name__})"
            retryable = True
        except (OSError, ValueError) as e:
            why = str(e) or type(e).__name__
            retryable = isinstance(e, OSError) and not isinstance(e, (FileNotFoundError, PermissionError)) \
                and getattr(e, "errno", None) not in (28,)      # (28: the disk is full — trying again won't help)
        if not retryable or attempt >= attempts:
            break
        if not (validator and resume):
            have = 0
        try:
            wait(backoff(attempt, retry_after=retry_after), stop)
        except Stopped:
            why = "stopped"
            break
    _remove(path)
    return None, why


def fetch_bytes(url: str, headers: dict[str, str], *, max_bytes: int = 8 << 20, timeout: float = 30,
                attempts: int = 2, busy: bool = False, stop: Callable[[], bool] | None = None,
                context: ssl.SSLContext | None = None) -> tuple[bytes | None, str, str]:
    """A small answer (a page, JSON) whole in memory: (body, content type, "") or (None, "", why). A dropped
    connection is retried; the body is checked against `Content-Length` like a file's."""
    why = "no answer"
    for attempt in range(1, max(1, attempts) + 1):
        retry_after, retryable = None, False
        try:
            with opener(context).open(urllib.request.Request(url, headers=dict(headers)), timeout=timeout) as resp:
                ctype = (resp.headers.get("Content-Type") or "").split(";")[0].strip()
                data = resp.read(max_bytes + 1)
                length = resp.headers.get("Content-Length")
                if length and length.isdigit() and len(data) < min(int(length), max_bytes):
                    raise http.client.IncompleteRead(data)
                return data[:max_bytes], ctype, ""
        except urllib.error.HTTPError as e:
            why, retryable, retry_after = f"HTTP {e.code}", busy and e.code in BUSY, retry_after_of(e.headers)
        except urllib.error.URLError as e:
            why, retryable = f"couldn't connect ({e.reason})", True
        except (http.client.HTTPException, ConnectionError, TimeoutError, ssl.SSLError, OSError, ValueError) as e:
            why, retryable = f"the connection dropped ({type(e).__name__})", not isinstance(e, ValueError)
        if not retryable or attempt >= attempts:
            break
        try:
            wait(backoff(attempt, retry_after=retry_after), stop)
        except Stopped:
            return None, "", "stopped"
    return None, "", why


def _remove(path: str | os.PathLike) -> None:
    try:
        os.remove(path)
    except OSError:
        pass


# ----------------------------------------------------------------------------- onto the drive

def put(src: str | os.PathLike, dest: str | os.PathLike, exfat: bool) -> None:
    """Copies the finished file `src` to `dest` (which mustn't exist) so that `dest` is either the whole file or
    not there. On exFAT straight in (no rename, no fsync — CLAUDE.md #12); elsewhere as a hidden `.part`, flushed,
    then renamed. A copy that fails or comes up short removes what it wrote and raises `OSError`."""
    src, dest = str(src), str(dest)
    want = os.path.getsize(src)
    target = dest if exfat else os.path.join(os.path.dirname(dest), f".{os.path.basename(dest)}.part")
    try:
        shutil.copyfile(src, target)
        if os.path.getsize(target) != want:
            raise OSError(f"only {os.path.getsize(target):,} of {want:,} bytes reached the drive")
        if not exfat:
            with open(target, "rb+") as f:
                os.fsync(f.fileno())
            os.replace(target, dest)
    except OSError:
        _remove(target)
        raise


def safe_name(name: str, max_bytes: int = 240) -> str:
    """A file name every file system here takes: composed (NFC), no slashes or control characters, and short
    enough *in bytes* (the limit is 255 of them, not 255 characters) — cut from the stem, the extension kept."""
    name = unicodedata.normalize("NFC", name)
    name = "".join(" " if (c in "/\\:\0" or ord(c) < 32) else c for c in name).strip().strip(".") or "file"
    stem, ext = os.path.splitext(name)
    if len(ext.encode("utf-8")) > 20:
        stem, ext = name, ""
    while len((stem + ext).encode("utf-8")) > max_bytes and stem:
        stem = stem[:-1]
    return (stem.rstrip() or "file") + ext


# ----------------------------------------------------------------------------- records

def load_json(path: str | os.PathLike) -> tuple[dict, str]:
    """A record file: (document, "ok" | "missing" | "restored" | "corrupt"). An unreadable record is looked for in
    its `.bak` (the copy kept before the last save); when that's used the damaged file is kept aside as
    `<name>.damaged` rather than written over."""
    path = Path(path)
    bak = path.with_name(path.name + ".bak")
    try:
        raw = path.read_bytes()
    except FileNotFoundError:
        raw = None
    except OSError:
        return {}, "corrupt"
    if raw is not None:
        try:
            doc = json.loads(raw.decode("utf-8"))
            if isinstance(doc, dict):
                return doc, "ok"
        except ValueError:
            pass
    try:
        doc = json.loads(bak.read_bytes().decode("utf-8"))
        if isinstance(doc, dict):
            if raw is not None:
                try:
                    path.with_name(path.name + ".damaged").write_bytes(raw)
                except OSError:
                    pass
            return doc, "restored"
    except (OSError, ValueError):
        pass
    return {}, ("missing" if raw is None else "corrupt")


def keep_backup(path: str | os.PathLike) -> None:
    """Before a record is saved over: its present, readable contents copied to `<name>.bak` (a plain write, so
    it's as safe on exFAT as anywhere). A record that doesn't parse is never copied over a good backup."""
    path = Path(path)
    try:
        raw = path.read_bytes()
        if isinstance(json.loads(raw.decode("utf-8")), dict):
            path.with_name(path.name + ".bak").write_bytes(raw)
    except (OSError, ValueError):
        pass


# ----------------------------------------------------------------------------- what went wrong, kept

class RunLog:
    """One run's failures — what, from where, why — for the window's summary, a Retry Failed, and a file in the
    app's Logs folder the person can read or send."""

    def __init__(self, what: str, folder: Path | None = None) -> None:
        self.what = what
        self.folder = folder
        self.started = time.time()
        self.failures: list[dict] = []
        self.lines: list[str] = []

    def info(self, line: str) -> None:
        self.lines.append(f"{time.strftime('%H:%M:%S')}  {line}")

    def fail(self, name: str, url: str, why: str, tries: int = 1, item=None) -> None:
        self.failures.append({"name": name, "url": url, "why": why, "tries": tries, "item": item})
        self.info(f"FAILED {name}: {why}  <{url[:200]}>")

    def reasons(self) -> list[tuple[str, int]]:
        """(why, how many) — commonest first, for one line of summary."""
        count: dict[str, int] = {}
        for f in self.failures:
            count[f["why"]] = count.get(f["why"], 0) + 1
        return sorted(count.items(), key=lambda kv: -kv[1])

    def summary(self) -> str:
        if not self.failures:
            return ""
        parts = [f"{n:,} × {why}" for why, n in self.reasons()[:3]]
        return f"{len(self.failures):,} failed — " + "; ".join(parts)

    def save(self) -> Path | None:
        """Writes the log (only when something failed). Returns the file."""
        if not self.failures or self.folder is None:
            return None
        try:
            self.folder.mkdir(parents=True, exist_ok=True)
            out = self.folder / f"{self.what}-{time.strftime('%Y%m%d-%H%M%S', time.localtime(self.started))}.log"
            body = [f"{self.what} — {len(self.failures)} failed", ""] + self.lines
            out.write_text("\n".join(body) + "\n", encoding="utf-8")
            return out
        except OSError:
            return None
