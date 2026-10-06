#!/usr/bin/env python3
"""PornPics star downloader — every gallery of one pornstar in one go (standard library only).

    python3 pornpics_star_downloader.py https://www.pornpics.com/pornstars/lucie-wilde/ [DEST]

creates `DEST/Lucie Wilde/` (DEST defaults to ~/Pictures/PornPics) and inside it one folder per
gallery, named exactly like `pornpics_downloader.py` names them ("Beautiful Woman Posing"), so
the two tools share folders and a re-run only fetches what's missing.

What it does beyond the single-gallery tool:

* **Finds every gallery, not just the first page.** The star page only carries the first ~20; the
  rest load as you scroll. It walks the scroll endpoint `<star page>?limit=20&offset=N` (JSON or
  HTML) and, if that doesn't reach the total the page advertises, numbered pages (`<star>/2/`,
  `?page=2`), scanning each for `/galleries/<slug>-<id>/` links until two pages in a row add
  nothing. If that still falls short of the site's count, it opens the star page in a real browser
  engine (QtWebEngine, from PySide6) and scrolls it until no more galleries load — the site's own
  JavaScript does the paging, so this works whatever its endpoint is. `--browser always|never`. Galleries whose
  model list doesn't include the star (e.g. "related" thumbnails) are skipped.
* **Most recent first.** Gallery ids grow over time, so galleries are downloaded newest-first and
  each gallery folder's modification date is set so that sorting by Date Modified (Finder, the
  iOS app) lists them newest-first — the folder dates are nudged where needed to keep that order.
* **Highest quality the site serves:** the full-size `rel-link` file of each photo (the /1280/
  rendition — pornpics doesn't publish anything larger), saved byte-for-byte, so any EXIF the
  file carries is kept untouched.
* **Dates and EXIF.** The gallery date is the page's published date when it has one, otherwise the
  CDN's Last-Modified for its photos. Every photo's file date is set to it, and JPEGs that arrive
  *without* EXIF get a minimal EXIF block written in: DateTimeOriginal/DateTimeDigitized/DateTime,
  ImageDescription = gallery title (the iOS app shows it as the caption) and Artist = the models.
  Files that already have EXIF are never rewritten. `--no-exif` turns the writing off.
* **Gallery data.** Each gallery folder gets a `gallery.json` (url, id, title, date, models,
  channel, categories, tags, photo list); the star folder gets `pornstar.json` listing every
  gallery newest-first.

Two galleries with the same name get the id appended to the second folder ("Name (12345678)").
"""

from __future__ import annotations

import argparse
import html
import json
import os
import re
import struct
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from pornpics_downloader import (  # noqa: E402 — shared parsing lives next door
    SMALL_WORDS,
    USER_AGENT,
    gallery_name_from_url,
    page_title,
    photo_urls,
    safe_folder_name,
)

ROOT = "https://www.pornpics.com"
STAR_RE = re.compile(r"^https?://(?:www\.)?pornpics\.com/(?:[a-z]{2}/)?pornstars/([a-z0-9-]+)/?(?:[?#].*)?$", re.I)
GALLERY_LINK_RE = re.compile(r"(?:https?://(?:www\.)?pornpics\.com)?/(?:[a-z]{2}/)?galleries/([a-z0-9-]+?)-(\d+)/", re.I)
DATE_KEYS_RE = re.compile(
    r"""(?:"(?:datePublished|uploadDate|dateCreated)"\s*:\s*"|"""
    r"""(?:article:published_time|og:updated_time|datePublished)["']\s+content=["'])"""
    r"""(\d{4}-\d{2}-\d{2}(?:[T ]\d{2}:\d{2}(?::\d{2})?(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?)?)""", re.I)
PAGE_LIMIT = 20
MAX_PAGES = 500
IMAGE_EXTS = (".jpg", ".jpeg", ".png", ".webp", ".gif")

print_lock = threading.Lock()


def log(msg: str = "") -> None:
    with print_lock:
        print(msg, flush=True)


# ----------------------------------------------------------------------------- network


def request(url: str, referer: str | None = None, xhr: bool = False, timeout: int = 30) -> tuple[bytes, dict]:
    """GET with browser-like headers and 3 tries; returns (body, headers)."""
    headers = {"User-Agent": USER_AGENT, "Accept-Language": "en-US,en;q=0.9",
               "Accept": "application/json, text/javascript, */*; q=0.01" if xhr else "*/*"}
    if xhr:
        headers["X-Requested-With"] = "XMLHttpRequest"
        headers["Content-Type"] = "application/x-www-form-urlencoded; charset=UTF-8"
    if referer:
        headers["Referer"] = referer
    for attempt in range(3):
        try:
            req = urllib.request.Request(url, headers=headers)
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                return resp.read(), dict(resp.headers.items())
        except urllib.error.HTTPError as e:
            if e.code in (403, 404, 410) or attempt == 2:
                raise
        except (urllib.error.URLError, TimeoutError, OSError):
            if attempt == 2:
                raise
        time.sleep(1.5 * (attempt + 1))
    raise RuntimeError("unreachable")


def text(url: str, **kw) -> str:
    return request(url, **kw)[0].decode("utf-8", errors="replace")


def last_modified(headers: dict) -> datetime | None:
    value = next((v for k, v in headers.items() if k.lower() == "last-modified"), None)
    try:
        return parsedate_to_datetime(value) if value else None
    except (TypeError, ValueError):
        return None


# ----------------------------------------------------------------------------- star page


def star_slug(url: str) -> str | None:
    m = STAR_RE.match(url.strip())
    return m.group(1).lower() if m else None


def title_case(slug: str) -> str:
    words = [w for w in slug.split("-") if w]
    return " ".join(w if (i and w in SMALL_WORDS) else w.capitalize() for i, w in enumerate(words))


def gallery_links(blob: str) -> list[tuple[int, str]]:
    """(id, canonical url) for every gallery link in an HTML page or JSON (escaped slashes too)."""
    blob = blob.replace("\\/", "/")
    out: dict[int, str] = {}
    for slug, gid in GALLERY_LINK_RE.findall(blob):
        out.setdefault(int(gid), f"{ROOT}/galleries/{slug.lower()}-{gid}/")
    return list(out.items())


def advertised_count(page: str) -> int | None:
    """The "123 galleries" figure a star page shows, when it shows one."""
    m = re.search(r"([\d][\d,.]*)\s*(?:<[^>]+>\s*)*(?:photo\s+)?galleries\b", page, re.I)
    try:
        return int(re.sub(r"[,.]", "", m.group(1))) if m else None
    except ValueError:
        return None


def _paginate(found: dict[int, str], label: str, urls, xhr: bool, referer: str) -> int:
    """Fetch pages from `urls` (an iterator of (url, batch_size_hint)) until they stop adding
    galleries. A page that adds nothing is tolerated once — the first "more" page usually repeats
    what the star page already showed — but two in a row (or an empty/missing page) ends it."""
    added = misses = 0
    gen = urls()
    url = next(gen)
    for _ in range(MAX_PAGES):
        try:
            body, headers = request(url, referer=referer, xhr=xhr)
        except urllib.error.HTTPError as e:
            log(f"  {label}: {url} → HTTP {e.code}")
            break
        except (urllib.error.URLError, TimeoutError, OSError) as e:
            log(f"  {label}: {url} → {e}")
            break
        batch = gallery_links(body.decode("utf-8", errors="replace"))
        if not batch:
            ctype = next((v for k, v in headers.items() if k.lower() == "content-type"), "?")
            log(f"  {label}: {url} → no galleries ({ctype}, {len(body)} bytes)")
            break
        new = [(gid, u) for gid, u in batch if gid not in found]
        found.update(new)
        added += len(new)
        if new:
            misses = 0
            log(f"  {label}: +{len(new)} (total {len(found)})")
        else:
            misses += 1
            if misses >= 2:
                break
        url = gen.send(len(batch))
    return added


def browser_galleries(star_url: str, expected: int | None, timeout: float = 900) -> dict[int, str]:
    """Load the star page in a real browser engine (QtWebEngine) and keep scrolling — and clicking
    any "load more" button — until no new gallery links appear, then return every one.

    This is the reliable path: the site's own JavaScript does the paging, whatever endpoint or
    parameters it uses today. Needs PySide6 (mac/.venv has it); returns {} without it.
    """
    try:
        from PySide6.QtCore import QTimer, QUrl
        from PySide6.QtWebEngineWidgets import QWebEngineView
        from PySide6.QtWidgets import QApplication
    except ModuleNotFoundError:
        log("  (PySide6 isn't installed in this Python, so the page can't be scrolled in a browser.\n"
            "   Run mac/run.sh once, then use mac/.venv/bin/python to run this script.)")
        return {}

    js = r"""(() => {
        // Only in-page "load more" controls — never a link that would navigate away from the star.
        const more = [...document.querySelectorAll('button, [role=button], a[href="#"], a[href^="javascript"], a:not([href])')]
            .find(e => e.offsetParent && /^\s*(load|show|view|see)\s+more|more\s+galleries/i.test(e.textContent || ''));
        if (more) more.click();
        window.scrollTo(0, document.documentElement.scrollHeight || document.body.scrollHeight);
        return [...document.querySelectorAll('a[href*="/galleries/"]')].map(a => a.href).join('\n');
    })()"""
    app = QApplication.instance() or QApplication([sys.argv[0]])
    view = QWebEngineView()
    view.setWindowTitle("Collecting galleries… (this window closes by itself)")
    view.resize(1100, 850)
    view.show()
    found: dict[int, str] = {}
    state = {"last": -1, "idle": 0, "started": time.time(), "ticking": False}

    def done() -> None:
        view.close()
        app.quit()

    def on_result(result) -> None:
        for gid, u in gallery_links(result or ""):
            found.setdefault(gid, u)
        n = len(found)
        if n != state["last"]:
            if n > max(state["last"], 0):
                log(f"  browser: {n} galleries" + (f" of {expected}" if expected else ""))
            state["last"], state["idle"] = n, 0
        else:
            state["idle"] += 1
        # Done when the site's count is reached, nothing new has appeared for ~12 s, or time is up.
        if (expected and n >= expected and state["idle"] >= 1) or state["idle"] >= 8 \
                or time.time() - state["started"] > timeout:
            done()
        else:
            QTimer.singleShot(1500, tick)

    def tick() -> None:
        view.page().runJavaScript(js, 0, on_result)

    def loaded(_ok: bool) -> None:
        if not state["ticking"]:
            state["ticking"] = True
            QTimer.singleShot(2000, tick)

    view.loadFinished.connect(loaded)
    view.load(QUrl(star_url))
    app.exec()
    return found


def star_galleries(star_url: str, use_browser: str = "auto") -> dict[int, str]:
    """Every gallery id → url for a star. The page itself only carries the first ~20; the rest
    load on scroll. Tried in order, each until it stops adding galleries:
      1. the infinite-scroll endpoint  <star>/?limit=20&offset=N  (JSON, XHR headers)
      2. numbered HTML pages           <star>/N/  and  <star>/?page=N
    """
    base = star_url.split("?")[0].split("#")[0]
    base = base if base.endswith("/") else base + "/"
    first = text(base)
    found: dict[int, str] = dict(gallery_links(first))
    expected = advertised_count(first)
    log(f"Star page: {len(found)} galleries" + (f" (site says {expected})" if expected else ""))

    def offsets():
        offset = 0
        while True:
            got = yield f"{base}?{urllib.parse.urlencode({'limit': PAGE_LIMIT, 'offset': offset})}"
            offset += max(got or 0, 1)

    def numbered(fmt: str):
        def pages():
            n = 2
            while True:
                yield fmt.format(n=n)
                n += 1
        return pages

    _paginate(found, "scroll", offsets, xhr=True, referer=base)
    if not expected or len(found) < expected:
        for fmt in (base + "{n}/", base + "?page={n}"):
            if _paginate(found, "page", numbered(fmt), xhr=False, referer=base):
                break
    if use_browser == "always" or (use_browser == "auto" and (not expected or len(found) < expected)):
        log("Scrolling the star page in a browser to load the rest…")
        before = len(found)
        found.update({gid: u for gid, u in browser_galleries(base, expected).items() if gid not in found})
        if len(found) > before:
            log(f"  browser: +{len(found) - before} (total {len(found)})")
    if expected and len(found) < expected:
        log(f"  warning: found {len(found)} of the {expected} galleries the site lists")
    return found


# ----------------------------------------------------------------------------- gallery page


def labeled_links(page: str, labels: tuple[str, ...]) -> list[str] | None:
    """Link texts in a "Label: <a>…</a> <a>…</a>" block, or None if no such block exists.
    The colon is required so the site's navigation menus ("Categories ▾") never match."""
    for label in labels:
        m = re.search(rf">\s*{label}\s*:\s*<(.*?)</(?:div|ul|p|section)>", page, re.I | re.S)
        if m:
            names = [re.sub(r"<[^>]+>|\s+", " ", t).strip() for t in re.findall(r"<a\b[^>]*>(.*?)</a>", m.group(1), re.S)]
            return [html.unescape(n).strip() for n in names if n]
    return None


def gallery_metadata(page: str, url: str, gid: int) -> dict:
    star_links = sorted({s.lower() for s in re.findall(r"/pornstars/([a-z0-9-]+)/", page, re.I)})
    date = None
    m = DATE_KEYS_RE.search(page)
    if m:
        try:
            date = datetime.fromisoformat(m.group(1).replace("Z", "+00:00").replace(" ", "T"))
            if date.tzinfo is None:
                date = date.replace(tzinfo=timezone.utc)
        except ValueError:
            date = None
    return {
        "url": url,
        "id": gid,
        "title": page_title(page) or gallery_name_from_url(url),
        "date": date,
        "models": labeled_links(page, ("Models", "Pornstars", "Pornstar")),
        "channel": labeled_links(page, ("Channel", "Channels", "Site", "Paysite")),
        "categories": labeled_links(page, ("Categories", "Category")),
        "tags": labeled_links(page, ("Tags List", "Tags")),
        "pornstar_links": star_links,
    }


def belongs_to(meta: dict, slug: str, star_name: str) -> bool:
    """False only when the page clearly lists models and the star isn't among them."""
    if slug in meta["pornstar_links"]:
        return True
    models = meta["models"]
    if models:
        return any(m.lower() == star_name.lower() for m in models)
    return not meta["pornstar_links"]  # no model info at all → keep it


# ----------------------------------------------------------------------------- EXIF


def _ifd(entries: list[tuple[int, int, bytes, int]], start: int) -> bytes:
    """One big-endian TIFF IFD at offset `start` (entries: tag, type, value bytes, count)."""
    entries = sorted(entries)
    head = struct.pack(">H", len(entries))
    data = b""
    data_at = start + 2 + 12 * len(entries) + 4
    for tag, typ, value, count in entries:
        if len(value) <= 4:
            head += struct.pack(">HHI", tag, typ, count) + value.ljust(4, b"\0")
        else:
            head += struct.pack(">HHII", tag, typ, count, data_at + len(data))
            data += value + (b"\0" if len(value) % 2 else b"")
    return head + struct.pack(">I", 0) + data


def exif_block(when: datetime, description: str, artist: str) -> bytes:
    """APP1 Exif segment with dates, description and artist."""
    def ascii_(s: str) -> tuple[bytes, int]:
        b = s.encode("utf-8") + b"\0"
        return b, len(b)
    local = when.astimezone(timezone.utc)
    stamp, n = ascii_(local.strftime("%Y:%m:%d %H:%M:%S"))
    ifd0 = [(0x0132, 2, stamp, n)]
    if description:
        b, c = ascii_(description[:1000])
        ifd0.append((0x010E, 2, b, c))
    if artist:
        b, c = ascii_(artist[:500])
        ifd0.append((0x013B, 2, b, c))
    tz, tzn = ascii_("+00:00")
    exif = [(0x9000, 7, b"0232", 4), (0x9003, 2, stamp, n), (0x9004, 2, stamp, n), (0x9011, 2, tz, tzn)]
    placeholder = _ifd(ifd0 + [(0x8769, 4, struct.pack(">I", 0), 1)], 8)
    exif_at = 8 + len(placeholder)
    tiff = b"MM\0*" + struct.pack(">I", 8) + _ifd(ifd0 + [(0x8769, 4, struct.pack(">I", exif_at), 1)], 8) + _ifd(exif, exif_at)
    payload = b"Exif\0\0" + tiff
    return b"\xff\xe1" + struct.pack(">H", len(payload) + 2) + payload


def add_exif_if_missing(data: bytes, when: datetime, description: str, artist: str) -> bytes:
    """Insert an Exif block into a JPEG that has none; anything else comes back unchanged."""
    if not data.startswith(b"\xff\xd8"):
        return data
    pos, insert_at = 2, 2
    while pos + 4 <= len(data) and data[pos] == 0xFF:
        marker = data[pos + 1]
        if marker in (0xDA, 0xD9):  # start of scan / end: no more header segments
            break
        length = struct.unpack(">H", data[pos + 2:pos + 4])[0]
        if marker == 0xE1 and data[pos + 4:pos + 10] == b"Exif\0\0":
            return data  # already has EXIF — keep it exactly as shot
        if marker == 0xE0:
            insert_at = pos + 2 + length  # after JFIF APP0
        pos += 2 + length
    return data[:insert_at] + exif_block(when, description, artist) + data[insert_at:]


# ----------------------------------------------------------------------------- download


def choose_folder(star_dir: Path, name: str, gid: int) -> Path:
    folder = star_dir / safe_folder_name(name)
    info = folder / "gallery.json"
    if folder.exists() and info.exists():
        try:
            if int(json.loads(info.read_text("utf-8")).get("id", gid)) != gid:
                return star_dir / safe_folder_name(f"{name} ({gid})")
        except (OSError, ValueError, AttributeError):
            pass
    return folder


def set_mtime(path: Path, when: datetime) -> None:
    try:
        ts = when.timestamp()
        os.utime(path, (ts, ts))
    except OSError:
        pass


def download_one(url: str, gallery_url: str, target: Path, meta: dict, write_exif: bool) -> tuple[str, datetime | None]:
    """Fetch one photo into `target` (skipping a complete existing file). Returns (status, Last-Modified)."""
    if target.exists() and target.stat().st_size > 0:
        return "skipped", None
    data, headers = request(url, referer=gallery_url, timeout=60)
    if not data:
        raise RuntimeError("empty response")
    lm = last_modified(headers)
    when = meta["date"] or lm
    if write_exif and when:
        data = add_exif_if_missing(data, when, meta["title"] or "", ", ".join(meta["models"] or []))
    tmp = target.with_name(target.name + ".part")
    tmp.write_bytes(data)
    os.replace(tmp, target)
    return "saved", lm


def download_gallery(gid: int, url: str, star_dir: Path, slug: str, star_name: str,
                     workers: int, write_exif: bool) -> dict | None:
    page = text(url)
    meta = gallery_metadata(page, url, gid)
    if not belongs_to(meta, slug, star_name):
        log(f"  skip {gid}: {star_name} isn't listed as a model")
        return None
    urls = photo_urls(page)
    if not urls:
        log(f"  skip {gid}: no photos found")
        return None
    name = gallery_name_from_url(url) or f"Gallery {gid}"
    folder = choose_folder(star_dir, name, gid)
    folder.mkdir(parents=True, exist_ok=True)

    files = [urllib.parse.unquote(u.rsplit("/", 1)[-1].split("?")[0]) for u in urls]
    counts = {"saved": 0, "skipped": 0, "failed": 0}
    dates: list[datetime] = []
    lock = threading.Lock()

    def work(pair: tuple[str, str]) -> None:
        u, fname = pair
        try:
            status, lm = download_one(u, url, folder / fname, meta, write_exif)
            with lock:
                counts[status] += 1
                if lm:
                    dates.append(lm)
        except Exception as e:  # noqa: BLE001 — one bad photo must not stop the gallery
            with lock:
                counts["failed"] += 1
            log(f"    failed {fname}: {e}")
            try:
                (folder / (fname + ".part")).unlink()
            except OSError:
                pass

    with ThreadPoolExecutor(max_workers=max(1, workers)) as pool:
        list(pool.map(work, zip(urls, files)))

    if meta["date"] is None and dates:
        meta["date"] = min(dates)
    if meta["date"] is None and folder.joinpath("gallery.json").exists():
        try:
            old = json.loads(folder.joinpath("gallery.json").read_text("utf-8")).get("date")
            meta["date"] = datetime.fromisoformat(old) if old else None
        except (OSError, ValueError):
            pass
    if meta["date"]:
        for f in files:
            if (folder / f).exists():
                set_mtime(folder / f, meta["date"])

    record = {k: v for k, v in meta.items() if k not in ("date", "pornstar_links")}
    record.update({
        "date": meta["date"].isoformat() if meta["date"] else None,
        "folder": folder.name,
        "photo_count": len(urls),
        "photos": [{"file": f, "url": u} for f, u in zip(files, urls)],
        "downloaded_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
    })
    tmp = folder / "gallery.json.part"
    tmp.write_text(json.dumps(record, indent=2, ensure_ascii=False), "utf-8")
    os.replace(tmp, folder / "gallery.json")
    if meta["date"]:
        set_mtime(folder / "gallery.json", meta["date"])
    log(f"  {folder.name}: {counts['saved']} saved, {counts['skipped']} already had"
        + (f", {counts['failed']} failed" if counts["failed"] else "")
        + (f"  [{meta['date']:%Y-%m-%d}]" if meta["date"] else ""))
    record["_folder"] = folder
    record["_date"] = meta["date"]
    record["_failed"] = counts["failed"]
    return record


def order_folder_dates(records: list[dict]) -> None:
    """Folder mtimes newest-first by gallery id; dates are nudged only where they'd break that order."""
    prev: float | None = None
    for rec in sorted(records, key=lambda r: r["id"]):
        own = rec["_date"].timestamp() if rec["_date"] else None
        ts = own if own is not None else (prev + 60 if prev is not None else time.time() - 86400 * 365 * 10)
        if prev is not None and ts <= prev:
            ts = prev + 1
        prev = ts
        try:
            os.utime(rec["_folder"], (ts, ts))
        except OSError:
            pass


def main() -> None:
    ap = argparse.ArgumentParser(description="Download every gallery of a pornpics.com pornstar.")
    ap.add_argument("url", help="e.g. https://www.pornpics.com/pornstars/lucie-wilde/ (or just lucie-wilde)")
    ap.add_argument("dest", nargs="?", default=str(Path.home() / "Pictures" / "PornPics"),
                    help="folder the star's folder is created in (default ~/Pictures/PornPics)")
    ap.add_argument("--workers", type=int, default=4, help="photos downloaded in parallel per gallery (default 4)")
    ap.add_argument("--limit", type=int, default=0, help="only the N most recent galleries")
    ap.add_argument("--no-exif", action="store_true", help="don't write EXIF into JPEGs that have none")
    ap.add_argument("--browser", choices=("auto", "always", "never"), default="auto",
                    help="scroll the star page in a browser window to find every gallery: when the "
                         "plain requests come up short (auto, default), always, or never")
    args = ap.parse_args()

    url = args.url.strip()
    if re.fullmatch(r"[a-z0-9-]+", url, re.I):
        url = f"{ROOT}/pornstars/{url.lower()}/"
    slug = star_slug(url)
    if not slug:
        sys.exit("That doesn't look like a pornstar URL (expected https://www.pornpics.com/pornstars/<name>/).")
    star_name = title_case(slug)
    star_dir = Path(args.dest).expanduser() / safe_folder_name(star_name)
    star_dir.mkdir(parents=True, exist_ok=True)
    log(f"{star_name} → {star_dir}")

    galleries = sorted(star_galleries(url, args.browser).items(), reverse=True)  # newest (highest id) first
    if args.limit:
        galleries = galleries[:args.limit]
    if not galleries:
        sys.exit("No galleries found on that page.")
    log(f"{len(galleries)} galleries, newest first\n")

    records: list[dict] = []
    failed_galleries = 0
    try:
        for i, (gid, gurl) in enumerate(galleries, 1):
            log(f"[{i}/{len(galleries)}] {gallery_name_from_url(gurl)} ({gid})")
            try:
                rec = download_gallery(gid, gurl, star_dir, slug, star_name, args.workers, not args.no_exif)
                if rec:
                    records.append(rec)
            except Exception as e:  # noqa: BLE001 — keep going with the next gallery
                failed_galleries += 1
                log(f"  failed: {e}")
    except KeyboardInterrupt:
        log("\nStopped — run again to continue where it left off.")
    finally:
        if records:
            order_folder_dates(records)
            index = {
                "pornstar": star_name,
                "url": url,
                "updated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
                "galleries": [{k: r[k] for k in ("id", "title", "date", "folder", "photo_count", "url")}
                              for r in sorted(records, key=lambda r: r["id"], reverse=True)],
            }
            (star_dir / "pornstar.json").write_text(json.dumps(index, indent=2, ensure_ascii=False), "utf-8")
    photos_failed = sum(r["_failed"] for r in records)
    log(f"\nDone: {len(records)} galleries in {star_dir}"
        + (f", {failed_galleries} galleries failed" if failed_galleries else "")
        + (f", {photos_failed} photos failed (run again to retry)" if photos_failed else ""))


if __name__ == "__main__":
    main()
