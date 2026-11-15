"""Getting a file from the web properly — one place for what every downloader here needs and each had only part of.

A review of the downloaders (Nov 2026) found that a download cut short passed for a finished one: `urllib`'s
`read(n)` returns what arrived and says nothing when the server hangs up early, so a 5 KB piece of a 1 MB video
was saved, recorded as downloaded and never fetched again. Fixed here, with the rest of what good downloaders do
(gallery-dl, yt-dlp, cyberdrop-dl):

- **A download is whole or it failed.** The bytes written are compared with `Content-Length`; a dropped
  connection (`IncompleteRead`, a reset) is an error, not an ending. While it's coming down the file is
  `<path>.part`; `path` appears only when all of it is there.
- **It picks up where it stopped — in the same call or a later one.** A cut-off transfer is asked for again from
  the byte it reached (`Range`, with `If-Range` and the answer's strong ETag or Last-Modified). What it was a
  piece of is remembered beside it (`<path>.part.json`: the address, that validator, the size), so a call that
  gave up, was stopped, or died with the app leaves something the next call for the same `path` goes on from.
  **A piece is only added to when the server shows it's the same file**: the 206 must carry the validator the
  piece came with and a `Content-Range` that starts at the byte had — a server that honours `Range` but not
  `If-Range` otherwise gives the head of one file and the tail of another, the right length and wrong. Anything
  else starts again from zero.
- **It tries again politely.** Timeouts, resets, a truncated answer, and — when asked to (`busy=True`) — 429 and
  5xx are retried up to `attempts` times, waiting longer each time by a random amount (exponential backoff with
  full jitter, so parallel lanes don't all return at once) and obeying `Retry-After` when the server says how long.
- **Slow is told from stuck.** The body is read in small pieces, so the rules below are looked at several times
  a second rather than once a megabyte. A transfer that brings under `TRICKLE` bytes a second for `stall` seconds
  has stalled: that try fails and the next resumes it. `limit` no longer ends a transfer that is getting there
  (it used to, and a long video on a slow link started from zero on every run): past it, one whose size is
  known goes on for as long as it keeps `SLOW` bytes a second; one whose size isn't known, or that has dropped
  under that, ends — keeping what it has.
- **A page isn't a photo.** An HTML or JSON error body saved under a media name is refused (`looks_like_page`).
- **The file is saved as the file.** `Accept-Encoding: identity` is asked for; a body that comes gzip- or
  deflate-encoded all the same is unpacked as it's written (it was saved compressed under the media name),
  any other encoding is refused.
- **Cookies stay with their site.** A redirect to another host, port or scheme is followed *without* the
  `Cookie` and `Authorization` headers (urllib would send them on).
- **Stop means stop**: `stop()` is asked between pieces and during every wait.

Also here because every downloader needs them: `put` (a finished file onto the drive — the partial removed if the
copy fails, the size checked, exFAT's no-rename rule kept), `load_json` / `keep_backup` (a record read back from
the `.bak` of its last good self when it's damaged, and that `.bak` made before each save — the saving itself is
the record's own; so a save cut off by a pulled cable doesn't cost what was downloaded), `safe_name` and `RunLog`
(every failure with why, for the person and for a Retry Failed).

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
import zlib
from pathlib import Path
from typing import Callable
from urllib.parse import urlsplit

CHUNK = 1 << 20
PIECE = 1 << 16                 # one read of a body: small, so Stop, a stall and the limit are noticed between them
BUSY = (429, 500, 502, 503, 504)
MAX_WAIT = 120.0
TRICKLE = 1024                  # bytes a second: under this for `stall` seconds, the transfer has stalled
SLOW = 32 * 1024                # bytes a second a transfer must keep to go on past its `limit`
PART = ".part"                  # the file while it's coming down …
NOTE = ".part.json"             # … and what it's a piece of, so a later call can go on with it


class Stopped(Exception):
    """The person pressed Stop."""


class _Stalled(TimeoutError):
    """Bytes are arriving too slowly to count as a download (`TRICKLE`)."""


class _StartOver(Exception):
    """The answer to a `Range` request isn't the rest of the piece on disk."""


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


def _origin(url: str) -> tuple[str, str, int | None]:
    """(scheme, host, port) — the port the scheme implies when none is written."""
    parts = urlsplit(url)
    scheme = (parts.scheme or "").lower()
    try:
        port = parts.port
    except ValueError:
        port = -1                           # a port that isn't one: the same as nothing else
    return scheme, (parts.hostname or "").lower(), port or {"http": 80, "https": 443}.get(scheme)


def _same_site(old: str, new: str) -> bool:
    """Whether a redirect from `old` to `new` stays with the server the cookies were meant for: the same scheme,
    host and port (another port is another program, and https → http would send them in the clear). One step is
    let through — http → https on the same host, both on their usual ports: the everyday upgrade, to the same
    site, and the cookies have already crossed the network in the open."""
    a, b = _origin(old), _origin(new)
    return a == b or (a[1] == b[1] and a[0] == "http" and a[2] == 80 and b[0] == "https" and b[2] == 443)


class _KeepCookiesHome(urllib.request.HTTPRedirectHandler):
    """A redirect to another host — or another port or scheme of the same one — is followed without the headers
    that say who you are."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        new = super().redirect_request(req, fp, code, msg, headers, newurl)
        if new is not None and not _same_site(req.full_url, newurl):
            for held in (new.headers, new.unredirected_hdrs):
                for name in [n for n in held if n.lower() in ("cookie", "authorization", "proxy-authorization")]:
                    del held[name]
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


def _validator(headers) -> str:
    """What says "the same bytes" in an answer: its strong ETag, else its Last-Modified, else nothing."""
    etag = (headers.get("ETag") or "").strip()
    return etag if _strong(etag) else (headers.get("Last-Modified") or "").strip()


def _carries(headers, validator: str) -> bool:
    """Whether an answer is of the file `validator` came from."""
    etag = (headers.get("ETag") or "").strip()
    return bool(validator) and validator in (etag if _strong(etag) else "", (headers.get("Last-Modified") or "").strip())


def _content_range(value: str | None) -> tuple[int | None, int | None]:
    """`Content-Range: bytes 100-999/1000` → (100, 1000); the size None for `/*`; (None, None) when unreadable."""
    try:
        unit, _, rest = (value or "").strip().partition(" ")
        span, _, size = rest.partition("/")
        if unit.lower() != "bytes":
            return None, None
        return int(span.split("-")[0]), (int(size) if size.strip().isdigit() else None)
    except ValueError:
        return None, None


def _headers(headers: dict[str, str]) -> dict[str, str]:
    """The caller's headers, asking for the file as it is: a compressed transfer can't be resumed by byte, and a
    body saved still compressed isn't the photo."""
    h = {k: v for k, v in headers.items() if k.lower() != "accept-encoding"}
    h["Accept-Encoding"] = "identity"
    return h


class _Unpack:
    """A body that arrives `Content-Encoding: gzip` or `deflate` although the file as it is was asked for, undone
    as it's written. ("deflate" is zlib-wrapped by the standard and bare from some servers: the second is tried
    when the first can't start.) Raises `ValueError` for bytes that aren't what the header said."""

    def __init__(self, coding: str) -> None:
        self.gzip = "gzip" in coding
        self.z = zlib.decompressobj(16 + zlib.MAX_WBITS if self.gzip else zlib.MAX_WBITS)
        self.started = False

    def feed(self, raw: bytes) -> bytes:
        out = []
        try:
            while raw:
                if self.z.eof:
                    if not self.gzip:
                        break                                   # (bytes after the end: not the file's)
                    self.z = zlib.decompressobj(16 + zlib.MAX_WBITS)    # gzip may be several members end to end
                try:
                    out.append(self.z.decompress(raw))
                except zlib.error:
                    if self.gzip or self.started:
                        raise
                    self.z = zlib.decompressobj(-zlib.MAX_WBITS)
                    out.append(self.z.decompress(raw))
                self.started = True
                raw = self.z.unused_data
        except zlib.error as e:
            raise ValueError(f"the server sent the file compressed, and it wouldn't unpack ({e})") from None
        return b"".join(out)

    def done(self) -> bool:
        return self.z.eof


def _coding(headers) -> str:
    """The body's `Content-Encoding`, "" for none."""
    coding = (headers.get("Content-Encoding") or "").strip().lower()
    return "" if coding == "identity" else coding


def _unpacker(coding: str) -> _Unpack | None:
    """Raises `ValueError` for an encoding that can't be undone here (br, zstd)."""
    if not coding:
        return None
    if coding in ("gzip", "x-gzip", "deflate"):
        return _Unpack(coding)
    raise ValueError(f"the server sent the file compressed ({coding}), which can't be undone here")


def _forget(part: str, note: str) -> None:
    """The note first: a piece with no note is never added to, a note beside the wrong piece would be."""
    _remove(note)
    _remove(part)


def _same_address(url: str, was: str, validator: str) -> bool:
    """Whether a piece fetched from `was` may be continued from `url`: the same address — or one that differs only
    after the `?` (a signed link is new every run) when the piece has a strong ETag, which names its bytes."""
    if url == was:
        return True
    a, b = urlsplit(url), urlsplit(was or "")
    return validator.startswith('"') and (a.scheme, a.netloc, a.path) == (b.scheme, b.netloc, b.path)


def _partial(url: str, part: str, note: str) -> tuple[int, str, int | None]:
    """What an earlier call left of this download: (bytes had, their validator, the whole size or None). A piece
    with no note, a note that isn't about this address, or a piece as long as the file or longer is removed —
    (0, "", None)."""
    try:
        with open(note, encoding="utf-8") as f:
            doc = json.load(f)
        size = os.path.getsize(part)
        validator, total = doc.get("validator") or "", doc.get("total")
        if (isinstance(validator, str) and validator and size > 0 and _same_address(url, doc.get("url") or "", validator)
                and (total is None or (isinstance(total, int) and not isinstance(total, bool) and size < total))):
            return size, validator, total
    except (OSError, ValueError, AttributeError):
        pass
    _forget(part, note)
    return 0, "", None


def _note(note: str, url: str, validator: str, total: int | None) -> None:
    try:
        with open(note, "w", encoding="utf-8") as f:
            json.dump({"url": url, "validator": validator, "total": total, "at": int(time.time())}, f)
    except OSError:
        _remove(note)                       # (no note: the piece just isn't resumed by a later call)


def fetch_to_file(url: str, headers: dict[str, str], path: str, *, connect_timeout: float = 20,
                  limit: float = 600, check: Callable | None = None, attempts: int = 3, busy: bool = True,
                  resume: bool = True, stop: Callable[[], bool] | None = None, min_bytes: int = 64,
                  context: ssl.SSLContext | None = None,
                  progress: Callable[[int, int | None], None] | None = None,
                  stall: float = 60) -> tuple[str | None, str]:
    """`url` into `path` (module notes). Returns (path, "") or (None, why) — why is "HTTP 404", "the server sent a
    page…", "couldn't connect (…)", "cut off after …", "stalled (…)", "still downloading after …", "stopped".
    `connect_timeout` bounds the wait for an answer and each read (so Stop, too, waits at most that long on a
    server that has gone silent). `limit` is how long the call may take before the transfer has to show it's
    worth going on with: past it, one of unknown size ends, and one of known size ends the first time it's found
    under `SLOW` bytes a second over `stall` seconds. Under `TRICKLE` for `stall` seconds at any time is a stall —
    that try fails and is retried. `check(size, type)` sees the answer before any of it is read and may raise
    (the exception is passed on — a video already downloaded is skipped that way). `busy`: also retry 429 and 5xx
    (callers with their own, tuned waits for a busy server pass False).

    The bytes go to `<path>.part` and are renamed to `path` when whole — so `path` should be on the Mac (a temp
    folder), not the exFAT drive, as it is for every caller. A call that fails or is stopped part-way through a
    file it could resume (`resume`, and the server gave an ETag or Last-Modified) leaves `<path>.part` and
    `<path>.part.json`; the next call for the same `path` and address goes on from there. With no such validator,
    or `resume=False`, nothing is left behind."""
    path = os.fspath(path)
    part, note = path + PART, path + NOTE
    started = time.monotonic()
    # bytes of the file already on disk from an earlier, cut-off try (of this call or one before), the ETag or
    # Last-Modified they came with, and the size of the whole file when the server has said
    have, validator, total = _partial(url, part, note) if resume else (0, "", None)
    if not have:
        _forget(part, note)
    why = "no answer"
    checked = False
    restarted = False
    attempt = 0
    while True:
        attempt += 1
        retry_after = None
        retryable = False
        try:
            if stop is not None and stop():
                raise Stopped()
            h = _headers(headers)
            asked = bool(have and validator and resume)
            if asked:
                h = {k: v for k, v in h.items() if k.lower() not in ("range", "if-range")}
                h["Range"] = f"bytes={have}-"
                h["If-Range"] = validator
            else:
                have, total = 0, None
            req = urllib.request.Request(url, headers=h)
            with opener(context).open(req, timeout=connect_timeout) as resp:
                status = getattr(resp, "status", 200)
                ctype = (resp.headers.get("Content-Type") or "").split(";")[0].strip()
                if ctype.startswith("text/"):           # (a piece from before stays: this answer says nothing of it)
                    _remove(path)
                    return None, f"the server sent a page ({ctype}), not the file"
                unpack = _unpacker(_coding(resp.headers))
                length = resp.headers.get("Content-Length")
                body = int(length) if length and length.isdigit() else None
                if status == 206:
                    first, size = _content_range(resp.headers.get("Content-Range"))
                    if asked:
                        # The rest of *this* piece, or nothing: the same file by its validator (a server may
                        # honour Range and ignore If-Range), from the byte we have, of the size we were told.
                        if (unpack is not None or first != have or not _carries(resp.headers, validator)
                                or (total is not None and size is not None and size != total)):
                            raise _StartOver()
                        if total is None:
                            total = size if size is not None else (have + body if body is not None else None)
                        mode = "ab"
                    elif first in (None, 0) and unpack is None:     # unasked, but from the start: the rest is asked for next
                        have, total, mode = 0, (size if size is not None else body), "wb"
                    else:
                        raise ValueError("the server sent a piece of the file that wasn't asked for")
                else:                                   # the whole file (a 200 to a Range request: it changed)
                    have, total, mode = 0, (body if unpack is None else None), "wb"
                if check and not checked:
                    checked = True                      # once: a retry is the same file
                    check(total, ctype)
                if mode == "wb":
                    _remove(note)                       # before the old piece is written over, never after
                    validator = _validator(resp.headers) if unpack is None else ""
                got = 0                                 # bytes of this answer's body, as they came
                with open(part, mode) as f:
                    if mode == "wb" and validator and resume:
                        _note(note, url, validator, total)
                    elif mode == "ab" and f.tell() != have:     # the piece isn't what it was when it was measured
                        raise _StartOver()
                    # read1: what has arrived, up to a piece — read(n) waits until all n are there, which at
                    # 100 KB/s made Stop and the limit wait 10 s for each megabyte
                    read = getattr(resp, "read1", None) or resp.read
                    mark, mark_got = time.monotonic(), 0
                    while True:
                        if stop is not None and stop():
                            raise Stopped()
                        raw = read(PIECE)
                        if not raw:
                            break
                        got += len(raw)
                        chunk = unpack.feed(raw) if unpack is not None else raw
                        if chunk:
                            f.write(chunk)
                            have += len(chunk)
                            if progress:
                                progress(have, total)
                        now = time.monotonic()
                        late = now - started > limit
                        if late and total is None:      # nothing says this ever ends
                            raise TimeoutError(f"still downloading after {int(limit)} s")
                        if now - mark >= stall:
                            rate = (got - mark_got) / (now - mark)
                            if rate < TRICKLE:
                                raise _Stalled(f"stalled ({int(rate):,} bytes a second for {int(now - mark)} s)")
                            if late and rate < SLOW:
                                raise TimeoutError(f"still downloading after {int(now - started)} s, "
                                                   f"at {int(rate / 1024)} KB a second")
                            mark, mark_got = now, got
                if body is not None and got < body:
                    raise http.client.IncompleteRead(b"", body - got)
                if unpack is not None and not unpack.done():
                    raise http.client.IncompleteRead(b"")
                if total is not None and have < total:  # (a 206 that ended before the file did)
                    raise http.client.IncompleteRead(b"", total - have)
            if os.path.getsize(part) < min_bytes:
                _forget(part, note)
                _remove(path)
                return None, "an empty file"
            if looks_like_page(part):
                _forget(part, note)
                _remove(path)
                return None, "the server sent a page, not the file"
            os.replace(part, path)
            _remove(note)
            return path, ""
        except Stopped:
            why = "stopped"
        except _StartOver:
            _forget(part, note)
            have, validator, total = 0, "", None
            if not restarted:                           # once, at once, and not as one of the tries: nothing failed
                restarted = True
                attempt -= 1
                continue
            resume = False                              # a server that does it twice isn't asked for pieces again
            why, retryable = "the server's pieces of the file didn't belong together", True
        except urllib.error.HTTPError as e:
            why = f"HTTP {e.code}"
            retryable = busy and e.code in BUSY
            retry_after = retry_after_of(e.headers)
            if e.code == 416:                           # our Range no longer fits: start over
                have, validator, total, retryable = 0, "", None, True
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
            if getattr(e, "errno", None) == 28:
                validator = ""                          # … and a piece kept for next time is the last thing it needs
        # What's on disk now is what there is to go on from (a write may have stopped short of what was counted).
        try:
            have = os.path.getsize(part) if (validator and resume) else 0
        except OSError:
            have = 0
        if not have:
            _forget(part, note)
            validator, total = "", None
        if why == "stopped" or not retryable or attempt >= attempts:
            break
        try:
            wait(backoff(attempt, retry_after=retry_after), stop)
        except Stopped:
            why = "stopped"
            break
    _remove(path)                           # (as ever: after a failure there's no file under the name itself)
    return None, why


def fetch_bytes(url: str, headers: dict[str, str], *, max_bytes: int = 8 << 20, timeout: float = 30,
                attempts: int = 2, busy: bool = False, stop: Callable[[], bool] | None = None,
                context: ssl.SSLContext | None = None) -> tuple[bytes | None, str, str]:
    """A small answer (a page, JSON) whole in memory: (body, content type, "") or (None, "", why). A dropped
    connection is retried; the body is checked against `Content-Length` like a file's, and unpacked if it comes
    gzip- or deflate-encoded (it isn't asked for)."""
    why = "no answer"
    for attempt in range(1, max(1, attempts) + 1):
        retry_after, retryable = None, False
        try:
            with opener(context).open(urllib.request.Request(url, headers=_headers(headers)), timeout=timeout) as resp:
                ctype = (resp.headers.get("Content-Type") or "").split(";")[0].strip()
                unpack = _unpacker(_coding(resp.headers))
                data = resp.read(max_bytes + 1)
                length = resp.headers.get("Content-Length")
                if length and length.isdigit() and len(data) < min(int(length), max_bytes):
                    raise http.client.IncompleteRead(data)
                if unpack is not None:
                    whole = len(data) <= max_bytes
                    data = unpack.feed(data)
                    if whole and not unpack.done():
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
