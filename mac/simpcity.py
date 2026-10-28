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

    def add(self, item: Item, file: str) -> None:
        self.items[item.key] = {"file": file, "post": item.post, "posted": int(item.posted or 0),
                                "at": int(time.time())}
        self.failed.pop(item.key, None)

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
        """Where a run picks the thread up: the last page read (it may have grown since), else 1."""
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


def _parse(s) -> datetime | None:
    if not isinstance(s, str) or not s.strip():
        return None
    core = s.strip()[:19]
    for fmt in (_DATE_FMT, "%Y-%m-%dT%H:%M:%S", "%Y-%m-%d %H:%M:%S"):
        try:
            d = datetime.strptime(core, fmt)
            return d if d.year > 1904 else None          # QuickTime's "0000:00:00" / 1904 epoch = unset
        except ValueError:
            continue
    return None


def is_video(path: str) -> bool:
    return path.rsplit(".", 1)[-1].lower() in VIDEO_EXTS


def embedded_date(path: str, exiftool: str | None) -> datetime | None:
    """The capture date the file carries itself (what both apps sort by), or None."""
    if not exiftool:
        return None
    tags = ["-Keys:CreationDate", "-QuickTime:CreateDate", "-QuickTime:MediaCreateDate"] if is_video(path) \
        else ["-EXIF:DateTimeOriginal", "-EXIF:CreateDate", "-EXIF:ModifyDate", "-XMP:DateCreated"]
    try:
        res = subprocess.run([exiftool, "-j", "-q", "-m", "-api", "largefilesupport=1", "-d", _DATE_FMT, *tags, path],
                             capture_output=True, text=True, timeout=120)
        meta = (json.loads(res.stdout) or [{}])[0] if res.stdout.strip() else {}
    except (OSError, subprocess.SubprocessError, ValueError):
        return None
    # The same fields, in the same order, the iPhone app reads a capture date from.
    for k in ("CreationDate", "DateTimeOriginal", "CreateDate", "ModifyDate", "MediaCreateDate", "DateCreated"):
        d = _parse(meta.get(k))
        if d:
            return d
    return None


def apply_date(path: str, posted: float, exiftool: str | None) -> str:
    """Keeps a capture date the file already has; otherwise writes the forum post's date into it
    (EXIF for photos; the QuickTime dates Photos/AVFoundation read for videos). The file's own dates
    follow the capture date either way. Returns "kept", "post", or "none" (nothing to go on / no
    ExifTool — then only the file dates are set)."""
    have = embedded_date(path, exiftool)
    if have:
        when = have
        outcome = "kept"
    elif posted:
        when = datetime.fromtimestamp(posted)
        outcome = "none"
        if exiftool:
            s = when.strftime(_DATE_FMT)
            if is_video(path):
                tz = datetime.fromtimestamp(posted).astimezone().strftime("%z")
                tags = ["-api", "QuickTimeUTC", f"-QuickTime:CreateDate={s}", f"-QuickTime:ModifyDate={s}",
                        f"-QuickTime:TrackCreateDate={s}", f"-QuickTime:MediaCreateDate={s}",
                        f"-Keys:CreationDate={s}{tz[:3]}:{tz[3:]}"]
            else:
                tags = [f"-EXIF:DateTimeOriginal={s}", f"-EXIF:CreateDate={s}", f"-EXIF:ModifyDate={s}"]
            try:
                res = subprocess.run([exiftool, "-q", "-m", "-overwrite_original", "-api", "largefilesupport=1",
                                      *tags, path], capture_output=True, text=True, timeout=600)
                if res.returncode == 0:
                    outcome = "post"
            except (OSError, subprocess.SubprocessError):
                pass
    else:
        return "none"
    ts = when.timestamp()
    try:
        os.utime(path, (ts, ts))
    except OSError:
        pass
    if exiftool:
        s = when.strftime(_DATE_FMT)
        try:
            subprocess.run([exiftool, "-q", "-m", "-overwrite_original", f"-FileCreateDate={s}",
                            f"-FileModifyDate={s}", path], capture_output=True, timeout=60)
        except (OSError, subprocess.SubprocessError):
            pass
    return outcome


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
    const t = p.querySelector('.message-attribution time[data-time], time.u-dt[data-time], time[data-time], time[datetime]');
    let time = 0;
    if (t) {
      time = parseInt(t.getAttribute('data-time') || '0', 10)
        || Math.floor(Date.parse((t.getAttribute('datetime') || '').replace(/([+-]\d\d)(\d\d)$/, '$1:$2')) / 1000) || 0;
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
