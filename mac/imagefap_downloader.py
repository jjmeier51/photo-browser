#!/usr/bin/env python3
"""ImageFap gallery downloader — every full-size photo of one or more galleries (standard library only).

    python3 imagefap_downloader.py "https://www.imagefap.com/pictures/11350651/Gabrielle%20Santini%20NEW%20PICS" [MORE…]
    python3 imagefap_downloader.py 11350651 --dest ~/Pictures/ImageFap --airdrop

Each gallery becomes `DEST/<Gallery Title>/` (DEST defaults to ~/Pictures/ImageFap) holding its
photos in gallery order — named `001_<image id>.jpg`, so sorting by name keeps that order — plus a
`gallery.json` sidecar (url, id, title, uploader, date, categories, tags, photo list) in the shape the
pornpics tools write, so the iOS app's Categories filter works on these folders too. A re-run only
fetches what's missing; `--limit N` takes the first N photos. `--airdrop` then sends the galleries
that got new photos to the Photo Browser app on the iPhone (one archive each; see airdrop_to_iphone.py).

How it finds the photos. A gallery page lists its thumbnails 24 to a page (`?gid=…&page=N&view=0`)
or 100 with `view=2`; each links to `/photo/<image id>/`. The full-size file sits behind a signed CDN
URL (`cdnc.imagefap.com/images/full/…?secure=…`) that only photo pages hand out. The site's own strip
endpoint, `/photo/<id>/?gid=…&idx=N&partial=true`, returns the 24 photos from position N with their
full-size links (the regular photo page carries that strip only for a gallery's first pages), so one
request per 24 photos resolves a whole gallery. The signatures expire after about a day; they're
fetched and used within the run. A photo page's "Date Added" is the gallery's date: every file gets it
(plus its position, in seconds, so Date sorting keeps the order too), and JPEGs that arrive without
EXIF get it written in, with the gallery title as the caption and the uploader as the artist (the iOS
app shows the caption; `--no-exif` skips this). Files that already have EXIF are never rewritten.

The site rate-limits: 3 downloads at a time by default (`--workers`), a 429 waits and retries, and the
page requests are paced. `--dry-run` resolves a gallery and lists what it would download.
"""

from __future__ import annotations

import argparse
import html
import json
import os
import re
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from pornpics_downloader import USER_AGENT, safe_folder_name  # noqa: E402
from pornpics_star_downloader import add_exif_if_missing, choose_folder, set_mtime  # noqa: E402

ROOT = "https://www.imagefap.com"
GALLERY_RE = re.compile(r"^https?://(?:www\.)?imagefap\.com/(?:pictures|gallery)/(\d+)(?:/[^?#]*)?(?:[?#].*)?$", re.I)
GALLERY_PHP_RE = re.compile(r"^https?://(?:www\.)?imagefap\.com/gallery\.php\?(?:.*&)?gid=(\d+)", re.I)
PHOTO_ID_RE = re.compile(r'href="/photo/(\d+)/')
STRIP_RE = re.compile(r'<ul class="thumbs">(.*?)</ul>', re.S)
STRIP_LINK_RE = re.compile(r'<a href="(https://cdn[a-z]*\.imagefap\.com/images/full/[^"]+)"[^>]*imageid="(\d+)"')
FULL_RE = re.compile(r'https://cdn[a-z]*\.imagefap\.com/images/full/\d+/\d+/(\d+)\.[a-z0-9]+\?secure=[^"\'\\ <]+', re.I)
PAGE_SIZE = 24          # photos per gallery page, and per photo-page strip
ALL_VIEW_SIZE = 100     # photos per page with view=2
PACE = 0.4              # seconds between page requests

print_lock = threading.Lock()


def log(msg: str = "") -> None:
    with print_lock:
        print(msg, flush=True)


# ----------------------------------------------------------------------------- network


def request(url: str, referer: str | None = None, timeout: int = 60) -> tuple[bytes, dict]:
    """GET with browser-like headers; retries network errors and 429/5xx with a growing wait."""
    headers = {"User-Agent": USER_AGENT, "Accept-Language": "en-US,en;q=0.9", "Accept": "*/*"}
    if referer:
        headers["Referer"] = referer
    for attempt in range(5):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=timeout) as resp:
                return resp.read(), dict(resp.headers.items())
        except urllib.error.HTTPError as e:
            if e.code == 429 or e.code >= 500:
                if attempt == 4:
                    raise
                wait = 8.0 * (attempt + 1) if e.code == 429 else 2.0 * (attempt + 1)
                log(f"    HTTP {e.code} — waiting {wait:.0f}s")
                time.sleep(wait)
                continue
            raise
        except (urllib.error.URLError, TimeoutError, OSError):
            if attempt == 4:
                raise
            time.sleep(1.5 * (attempt + 1))
    raise RuntimeError("unreachable")


def text(url: str, referer: str | None = None) -> str:
    return request(url, referer=referer)[0].decode("utf-8", errors="replace")


# ----------------------------------------------------------------------------- gallery


def gallery_id(arg: str) -> int | None:
    """The gallery id of a gallery URL (either form), or of a bare id."""
    arg = arg.strip()
    if arg.isdigit():
        return int(arg)
    m = GALLERY_RE.match(arg) or GALLERY_PHP_RE.match(arg)
    return int(m.group(1)) if m else None


def gallery_url(gid: int, page: int = 0, view: int = 2) -> str:
    return f"{ROOT}/pictures/{gid}/?" + urllib.parse.urlencode({"gid": gid, "page": page, "view": view})


def gallery_info(page: str, gid: int) -> dict:
    """Title, uploader, categories and tags from a gallery page."""
    title = html.unescape((re.search(r"<title>\s*(.*?)\s*</title>", page, re.S) or [None, ""])[1]).strip()
    title = re.sub(r"\s*(?:\|\s*)?(?:Porn Pics|ImageFap).*$", "", title).strip() or f"Gallery {gid}"
    m = re.search(r"Uploaded by\s*(?:<[^>]+>\s*)*([^<\n]+)", page)
    uploader = html.unescape(m.group(1)).strip() if m else ""

    def links(block_id: str) -> list[str]:
        block = re.search(rf'<div id="{block_id}">(.*?)</div>', page, re.S)
        return [html.unescape(t).strip() for t in re.findall(r"<a [^>]*>([^<]+)</a>", block.group(1))] if block else []

    return {"title": title, "uploader": uploader, "categories": links("cnt_cats"), "tags": links("cnt_tags")}


def photo_ids(gid: int) -> list[int]:
    """Every photo id of the gallery, in gallery order — the `view=2` pages (100 each) until one adds
    nothing."""
    ids: dict[int, None] = {}
    for page in range(0, 1000):
        body = text(gallery_url(gid, page, 2))
        batch = [int(i) for i in PHOTO_ID_RE.findall(body)]
        new = [i for i in dict.fromkeys(batch) if i not in ids]
        if not new:
            break
        for i in new:
            ids[i] = None
        if len(batch) < ALL_VIEW_SIZE:
            break
        time.sleep(PACE)
    return list(ids)


def strip_links(body: str) -> list[tuple[int, str]]:
    """(image id, full-size url) pairs of the thumbnail strip in a photo page or partial response."""
    strip = STRIP_RE.search(body)
    return [(int(i), html.unescape(u)) for u, i in STRIP_LINK_RE.findall(strip.group(1))] if strip else []


def gallery_date(gid: int, pid: int) -> datetime | None:
    """The gallery's date: "Date Added" on a photo's page (the partial strip doesn't carry it)."""
    body = text(f"{ROOT}/photo/{pid}/?" + urllib.parse.urlencode({"pgid": "", "gid": gid, "page": 0}),
                referer=gallery_url(gid, 0, 0))
    m = re.search(r'id="img_added"[^>]*>\s*([\d/]+)', body)
    try:
        return datetime.strptime(m.group(1), "%m/%d/%Y").replace(tzinfo=timezone.utc) if m else None
    except ValueError:
        return None


def resolve_full(gid: int, ids: list[int]) -> dict[int, str]:
    """Full-size URL per photo id. The site's own strip endpoint
    (`/photo/<id>/?gid=…&idx=N&partial=true`) returns the 24 photos from (about) position N with
    their signed full-size links — the regular photo page only carries that strip for the first
    pages of a gallery — so the gallery is walked 24 at a time; a position the strip somehow skips
    falls back to that photo's own page."""
    full: dict[int, str] = {}
    pos = 0
    while pos < len(ids):
        body = text(f"{ROOT}/photo/{ids[pos]}/?" + urllib.parse.urlencode({"gid": gid, "idx": pos, "partial": "true"}),
                    referer=gallery_url(gid, pos // PAGE_SIZE, 0))
        for image_id, url in strip_links(body):
            full.setdefault(image_id, url)
        if ids[pos] not in full:
            page = text(f"{ROOT}/photo/{ids[pos]}/?" + urllib.parse.urlencode({"pgid": "", "gid": gid, "page": pos // PAGE_SIZE}),
                        referer=gallery_url(gid, pos // PAGE_SIZE, 0))
            for image_id, url in strip_links(page):
                full.setdefault(image_id, url)
            m = next((m for m in FULL_RE.finditer(page) if int(m.group(1)) == ids[pos]), None)
            if m:
                full.setdefault(ids[pos], html.unescape(m.group(0)))
            else:
                log(f"    no full-size link for photo {ids[pos]}")
                full.setdefault(ids[pos], "")          # don't ask again
        while pos < len(ids) and ids[pos] in full:
            pos += 1
        time.sleep(PACE)
    return {i: u for i, u in full.items() if u}


# ----------------------------------------------------------------------------- download


def file_name(index: int, pid: int, url: str, width: int) -> str:
    ext = os.path.splitext(urllib.parse.urlsplit(url).path)[1].lower() or ".jpg"
    return f"{index:0{width}d}_{pid}{ext}"


def download_one(url: str, target: Path, referer: str, when: datetime | None, meta: dict, write_exif: bool) -> str:
    """Fetch one photo to `target` via a .part file; returns "saved", "skipped" (already there)."""
    if target.exists() and target.stat().st_size > 0:
        if when:
            set_mtime(target, when)
        return "skipped"
    data, _ = request(url, referer=referer)
    if not data:
        raise ValueError("empty response")
    if write_exif and when and target.suffix.lower() in (".jpg", ".jpeg"):
        data = add_exif_if_missing(data, when, meta["title"], meta["uploader"])
    part = target.with_name(target.name + ".part")
    part.write_bytes(data)
    os.replace(part, target)
    if when:
        set_mtime(target, when)
    return "saved"


def download_gallery(gid: int, dest: Path, workers: int, write_exif: bool, dry_run: bool = False,
                     limit: int = 0) -> dict | None:
    """One gallery into `dest/<title>/`; returns its record (with `_saved`, `_folder`) or None."""
    page = text(gallery_url(gid, 0, 0))
    meta = gallery_info(page, gid)
    log(f"{meta['title']} ({gid})" + (f" — by {meta['uploader']}" if meta["uploader"] else ""))
    if meta["categories"]:
        log(f"  categories: {', '.join(meta['categories'])}")
    ids = photo_ids(gid)
    if not ids:
        log("  no photos found")
        return None
    total = len(ids)
    if limit:
        ids = ids[:limit]
    log(f"  {len(ids)} photos; resolving full-size links…" if len(ids) == total else
        f"  {len(ids)} of {total} photos; resolving full-size links…")
    when = gallery_date(gid, ids[0])
    full = resolve_full(gid, ids)
    missing = [i for i in ids if i not in full]
    if missing:
        log(f"  {len(missing)} photo{'s' if len(missing) != 1 else ''} without a full-size link — skipped")
    width = max(3, len(str(len(ids))))
    photos = [{"index": n, "id": pid, "file": file_name(n, pid, full[pid], width), "url": full[pid]}
              for n, pid in enumerate(ids, 1) if pid in full]
    if dry_run:
        log(f"  date: {when:%Y-%m-%d}" if when else "  date: unknown")
        for p in photos[:5]:
            log(f"  {p['file']}  ←  {p['url'][:90]}…")
        if len(photos) > 5:
            log(f"  … and {len(photos) - 5} more")
        return None

    folder = choose_folder(dest, meta["title"], gid)
    folder.mkdir(parents=True, exist_ok=True)
    counts = {"saved": 0, "skipped": 0, "failed": 0}
    lock = threading.Lock()
    referer = gallery_url(gid, 0, 0)

    def work(p: dict) -> None:
        # Each file's date is the gallery date plus its position, so sorting by date keeps the order.
        file_when = (when + timedelta(seconds=p["index"])) if when else None
        try:
            status = download_one(p["url"], folder / p["file"], referer, file_when, meta, write_exif)
            with lock:
                counts[status] += 1
        except Exception as e:  # noqa: BLE001 — one bad photo must not stop the gallery
            with lock:
                counts["failed"] += 1
            log(f"    failed {p['file']}: {e}")
            try:
                (folder / (p["file"] + ".part")).unlink()
            except OSError:
                pass

    with ThreadPoolExecutor(max_workers=max(1, workers)) as pool:
        list(pool.map(work, photos))

    record = {
        "site": "imagefap",
        "url": f"{ROOT}/pictures/{gid}/{urllib.parse.quote(meta['title'])}",
        "id": gid,
        "title": meta["title"],
        "uploader": meta["uploader"],
        "models": [],
        "date": when.isoformat() if when else None,
        "categories": meta["categories"],
        "tags": meta["tags"],
        "folder": folder.name,
        "photo_count": total,
        "photos": [{"index": p["index"], "id": p["id"], "file": p["file"]} for p in photos],
        "downloaded_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
    }
    tmp = folder / "gallery.json.part"
    tmp.write_text(json.dumps(record, indent=2, ensure_ascii=False), "utf-8")
    os.replace(tmp, folder / "gallery.json")
    if when:
        set_mtime(folder / "gallery.json", when)
        set_mtime(folder, when)
    log(f"  {folder.name}: {counts['saved']} saved, {counts['skipped']} already had"
        + (f", {counts['failed']} failed" if counts["failed"] else ""))
    record["_folder"] = folder
    record["_saved"] = counts["saved"]
    record["_failed"] = counts["failed"]
    return record


def main() -> None:
    ap = argparse.ArgumentParser(description="Download ImageFap galleries, full size, in order.")
    ap.add_argument("galleries", nargs="+", help="gallery URLs (https://www.imagefap.com/pictures/<id>/<name>) or ids")
    ap.add_argument("--dest", default=str(Path.home() / "Pictures" / "ImageFap"),
                    help="folder the gallery folders are created in (default ~/Pictures/ImageFap)")
    ap.add_argument("--workers", type=int, default=3, help="photos downloaded in parallel (default 3; the site rate-limits)")
    ap.add_argument("--no-exif", action="store_true", help="don't write EXIF into JPEGs that have none")
    ap.add_argument("--limit", type=int, default=0, help="only the first N photos of each gallery")
    ap.add_argument("--dry-run", action="store_true", help="resolve the galleries and list what would be downloaded")
    ap.add_argument("--airdrop", action="store_true",
                    help="afterwards AirDrop the galleries that got new photos to the Photo Browser app on the iPhone")
    args = ap.parse_args()

    gids: list[int] = []
    for arg in args.galleries:
        gid = gallery_id(arg)
        if gid is None:
            sys.exit(f"Not an ImageFap gallery: {arg} (expected https://www.imagefap.com/pictures/<id>/<name>)")
        if gid not in gids:
            gids.append(gid)
    dest = Path(args.dest).expanduser()
    if not args.dry_run:
        dest.mkdir(parents=True, exist_ok=True)

    records: list[dict] = []
    failed = 0
    try:
        for i, gid in enumerate(gids, 1):
            if len(gids) > 1:
                log(f"[{i}/{len(gids)}]")
            try:
                rec = download_gallery(gid, dest, args.workers, not args.no_exif, args.dry_run, args.limit)
                if rec:
                    records.append(rec)
            except Exception as e:  # noqa: BLE001 — keep going with the next gallery
                failed += 1
                log(f"  failed: {e}")
    except KeyboardInterrupt:
        log("\nStopped — run again to continue where it left off.")
    if args.dry_run:
        return
    photos_failed = sum(r["_failed"] for r in records)
    log(f"\nDone: {len(records)} galler{'y' if len(records) == 1 else 'ies'} in {dest}"
        + (f", {failed} failed" if failed else "")
        + (f", {photos_failed} photos failed (run again to retry)" if photos_failed else ""))
    if args.airdrop:
        import airdrop_to_iphone as airdrop
        folders = [r["_folder"] for r in records if r["_saved"]]
        if not folders:
            log("Nothing new to AirDrop — every photo was already here.")
            return
        try:
            archives = airdrop.archive_items(folders, airdrop.default_out_dir())
            for a in archives:
                log(f"AirDrop: {a.name} ({airdrop.human(a.stat().st_size)})")
            airdrop.send(archives, log=log)
        except (OSError, ValueError) as e:
            log(f"AirDrop failed: {e}")


if __name__ == "__main__":
    main()
