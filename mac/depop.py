"""Depop shops: what a shop's page says about its listings and their photos, and each photo's largest version.

Photo Browser for Mac ▸ right-click a folder ▸ Download ▸ **Download from Depop…** opens the shop in a browser the
person can see (depop_downloader.py); the photos it finds are laid out to pick from, and the ones picked are
downloaded at the highest quality the shop has of them. This file is the part with no window in it.

How a shop is read — **nothing here asks Depop anything**. The window's browser loads the shop's own page, and a
script put into the page keeps a copy of every data answer the page itself receives (fanfix.HOOK_JS — the same
watcher the Fanfix downloader uses: JSON, Next.js data written into the page, React Server Component streams).
`Shop.read_text` looks through those copies for things shaped like a listing — an object with a `slug` and
pictures — rather than expecting one particular answer from one particular address, so it goes on working when
Depop moves its private API about (which it does). What the page *shows* is read too (`DOM_JS` → `read_shown`):
a picture inside a link to `/products/<slug>/` is that listing's. A listing's page, fetched by the page itself,
fills in the photos its tile didn't have (`read_page`).

A photo's versions. Depop keeps each photo at several sizes under one address:

    https://media-photos.depop.com/b1/<seller id>/<photo id>_<hash>/P0.jpg      P1.jpg  P2.jpg … P8.jpg

and the data names some of them by width ({"150": …/P2.jpg, …, "1280": …/P8.jpg}, or [{"width": 1280, "url": …}]).
`P0` is the photo as Depop keeps it; the others are made from it. Which is biggest isn't taken on trust:
`fetch_best` downloads P0, **measures it**, and fetches the widest version the data named only if that one claims
to be wider — then keeps whichever has more pixels. A photo known only from the page (no widths) is tried as P0,
then P8, then as shown. Sellers' own pictures (`…/U0.jpg`) are never taken for a listing's photo.

Files are named `<listing slug>_<n>.jpg` (the photo's place in its listing), into `<folder>/Depop/<shop>`, tagged
"depop"; the folder's `.depop.json` (social.Record) remembers which photos are in, so they're marked in the window
next time and not fetched twice.

Depop's terms don't allow automated collecting of its pages. This reads only what the person's own browser was
shown as they look through a shop, at a person's pace, and downloads only the photos they pick; it answers no
bot check itself (the person does, in the page) and takes nothing that isn't publicly on the listing.
"""
from __future__ import annotations

import html as _html
import json
import os
import re
from dataclasses import dataclass, field
from pathlib import Path
from urllib.parse import unquote, urlsplit

import fanfix
import social

TAG = "depop"
SOLD_TAG = "sold"                            # a sold listing's photos get this too
KEYWORD = "Depop"
RECORD = ".depop.json"
FORMAT = "photobrowser-depop"
SITE = "https://www.depop.com/"
DOMAIN = "depop.com"
FOLDER = "Depop"

# A stand-in site for the tests (PHOTO_BROWSER_DEPOP_TEST=http://127.0.0.1:<port>): its pages and pictures are
# read as Depop's would be. Never set in use.
_TEST = os.environ.get("PHOTO_BROWSER_DEPOP_TEST", "").rstrip("/")
if _TEST:
    SITE = _TEST + "/"
    DOMAIN = urlsplit(_TEST).netloc
_HOST = r"[a-z0-9.-]+\.depop\.com" + ("|" + re.escape(DOMAIN) if _TEST else "")

# A listing's photo: …/<photo>/P<n>.<ext> on one of Depop's hosts. (U<n> is a seller's own picture.)
_PHOTO = re.compile(r"^(https?)://(" + _HOST + r")/(.+)/P(\d{1,2})\.(jpe?g|png|webp)(?:\?.*)?$", re.I)
_PHOTO_ANYWHERE = re.compile(r"https?:(?:\\?/){2}(?:" + _HOST + r")(?:\\?/[^\"'\\\s<>)]+)+\\?/P\d{1,2}\.(?:jpe?g|png|webp)", re.I)
_SLUG = re.compile(r"^[a-z0-9][a-z0-9_\-]{2,200}$", re.I)
_NOT_SHOPS = {"products", "product", "search", "explore", "category", "brands", "theme", "login", "signup", "sell",
              "about", "help", "blog", "cart", "bag", "messages", "notifications", "settings", "legal", "safety",
              "sitemap", "api", "static", "_next", "favicon.ico", "robots.txt", "news", "careers", "press", "pay"}
_PICTURE_KEYS = ("pictures", "pictures_data", "picturesData", "images", "photos", "preview", "previews", "image", "picture")
_TEXT_KEYS = ("description", "title", "name")
_SOLD_KEYS = ("sold_at", "soldAt", "date_sold", "dateSold", "sold_date", "soldDate", "sold_time", "soldTime")
_DATE_KEYS = ("date_updated", "dateUpdated", "date_created", "dateCreated", "created_date", "createdDate",
              "pub_date", "published_at", "publishedAt", "listed_at", "created_at", "createdAt")


# ----------------------------------------------------------------------------- names and addresses

def clean_shop(text: str) -> str:
    """A shop's name from what was typed or pasted: "jane", "@jane", "depop.com/jane", a link to the shop (with or
    without "/selling") — "" for anything else, a listing's link included (see `slug_of`)."""
    s = (text or "").strip()
    if not s:
        return ""
    if DOMAIN in s.lower() or "depop.com" in s.lower():
        if "://" not in s:
            s = "https://" + s
        parts = [p for p in urlsplit(s).path.split("/") if p]
        s = parts[0] if parts else ""
    s = unquote(s).lstrip("@").strip().strip("/").lower()
    if not re.fullmatch(r"[a-z0-9_.]{2,40}", s) or s in _NOT_SHOPS:
        return ""
    return s


def slug_of(text: str) -> str:
    """A listing's slug from its link (…/products/<slug>/), else ""."""
    m = re.search(r"/products?/([^/?#\s]+)", text or "")
    return unquote(m.group(1)).lower() if m and _SLUG.match(unquote(m.group(1))) else ""


def shop_url(shop: str) -> str:
    return f"{SITE}{shop}/"


def product_url(slug: str) -> str:
    return f"{SITE}products/{slug}/"


def split_photo(url: str) -> tuple[str, int, str] | None:
    """A photo's address as (what all its versions share, which version, its extension) — None when `url` isn't
    a listing's photo."""
    m = _PHOTO.match((url or "").replace("\\/", "/").strip())
    if not m:
        return None
    scheme = m.group(1).lower() if _TEST else "https"
    return f"{scheme}://{m.group(2).lower()}/{m.group(3)}", int(m.group(4)), m.group(5).lower()


def version_url(base: str, n: int, ext: str) -> str:
    return f"{base}/P{n}.{ext}"


def photo_id(base: str) -> str:
    """What the record knows a photo by: the end of its address ("<seller id>/<photo id>_<hash>")."""
    return "/".join(base.split("/")[-2:])


# ----------------------------------------------------------------------------- what's found

@dataclass
class Photo:
    base: str                                   # the address without "/P<n>.<ext>"
    ext: str = "jpg"
    widths: dict[int, int] = field(default_factory=dict)    # version → the width the data gave it (0: not said)
    slug: str = ""                              # the listing it's a photo of ("" when the page didn't say)
    place: int = 0                              # which of the listing's photos (0 first)

    @property
    def key(self) -> str:
        return photo_id(self.base)

    def url(self, n: int) -> str:
        return version_url(self.base, n, self.ext)

    def thumb(self) -> str:
        """A small version to show: the narrowest that's still 300 wide, else the widest below that, else as seen."""
        sized = sorted((w, n) for n, w in self.widths.items() if w)
        for w, n in sized:
            if w >= 300:
                return self.url(n)
        if sized:
            return self.url(sized[-1][1])
        return self.url(min(self.widths) if self.widths else 0)

    def claimed(self) -> tuple[int, int]:
        """(the widest width the data names, its version) — (0, -1) when it names none."""
        best = max(((w, n) for n, w in self.widths.items() if w), default=(0, -1))
        return best

    def candidates(self) -> list[str]:
        """Addresses to try for the full photo, best first: P0 (the photo as kept), the widest named, P8, then
        whatever was seen, largest version number last."""
        out = [self.url(0)]
        width, n = self.claimed()
        if n >= 0:
            out.append(self.url(n))
        out.append(self.url(8))
        out.extend(self.url(v) for v in sorted(self.widths))
        return list(dict.fromkeys(out))


@dataclass
class Listing:
    slug: str
    title: str = ""
    date: float = 0
    sold: bool = False
    photos: list[str] = field(default_factory=list)       # photo bases, in the listing's order
    complete: bool = False                                # its whole list of photos was given (not just a tile's)


class Shop:
    """Everything read about one shop so far. `shop` ("" until known) keeps other sellers' listings out — a shop's
    page also shows what it liked, and a listing's page shows similar things: a listing's slug starts with its
    seller's name."""

    def __init__(self, shop: str = "") -> None:
        self.shop = shop
        self.listings: dict[str, Listing] = {}
        self.photos: dict[str, Photo] = {}                # by base
        self.loose: list[str] = []                        # photo bases seen with no listing named
        self.others = 0                                   # listings left out as someone else's
        # The shop's Sold tab is open: a listing first met now is a sold one, whatever its data says (the sold list
        # doesn't always carry a status). Set by the window from what the page shows (`DOM_JS` → `sold_tab`).
        self.sold_view = False

    # -- the page's data
    def read_text(self, text: str) -> int:
        """One answer the page received (JSON, or a stream of it). Returns how many photos it added."""
        before = len(self.photos)
        if DOMAIN not in text:
            return 0
        for doc in fanfix.documents(text):
            self.read(doc)
        return len(self.photos) - before

    def read(self, doc) -> None:
        stack = [doc]
        seen = 0
        while stack:
            node = stack.pop()
            seen += 1
            if seen > 400_000:
                return
            if isinstance(node, dict):
                if self._listing(node):
                    # (still looked into: a listing's page nests "more from this seller" under the listing)
                    stack.extend(v for k, v in node.items() if k not in _PICTURE_KEYS and isinstance(v, (dict, list)))
                else:
                    stack.extend(v for v in node.values() if isinstance(v, (dict, list)))
            elif isinstance(node, list):
                stack.extend(v for v in reversed(node) if isinstance(v, (dict, list)))

    def _listing(self, d: dict) -> bool:
        slug = d.get("slug")
        if not isinstance(slug, str) or not _SLUG.match(slug):
            return False
        found: list[tuple[str, int, str, int]] = []
        whole = False
        for key in _PICTURE_KEYS:
            if key in d:
                got = _pictures(d[key])
                if got and key not in ("preview", "previews", "image", "picture"):
                    whole = True
                found.extend(got)
        if not found:
            return False
        slug = slug.lower()
        if not self._ours(slug):
            self.others += 1
            return True
        it = self._listing_for(slug)
        if not it.title:
            for key in _TEXT_KEYS:
                if isinstance(d.get(key), str) and d[key].strip():
                    it.title = " ".join(d[key].split())[:300]
                    break
        if not it.date:
            it.date = next((t for t in (_when(d.get(k)) for k in _DATE_KEYS) if t), 0)
        status = str(d.get("status") or d.get("state") or d.get("listing_status") or d.get("listingStatus") or "").lower()
        if d.get("sold") is True or d.get("isSold") is True or d.get("is_sold") is True \
                or status in ("sold", "s", "purchased", "sold_out", "soldout") \
                or any(d.get(k) for k in _SOLD_KEYS):
            it.sold = True
        self._add(it, found, whole)
        return True

    def _listing_for(self, slug: str) -> "Listing":
        """The listing of that slug — made now when it's new, and then sold if the Sold tab is what's open."""
        it = self.listings.get(slug)
        if it is None:
            it = self.listings[slug] = Listing(slug, sold=self.sold_view)
        return it

    def counts(self) -> tuple[int, int]:
        """(listings for sale, listings sold)."""
        sold = sum(1 for it in self.listings.values() if it.sold)
        return len(self.listings) - sold, sold

    def _ours(self, slug: str) -> bool:
        return not self.shop or slug.startswith(self.shop.lower() + "-") or slug == self.shop.lower()

    def _add(self, it: Listing, found: list[tuple[str, int, str, int]], whole: bool) -> None:
        order: list[str] = []
        for base, n, ext, width in found:
            p = self.photos.get(base)
            if p is None:
                p = self.photos[base] = Photo(base, ext)
            p.widths[n] = max(p.widths.get(n, 0), width)
            if base in self.loose:
                self.loose.remove(base)
            if base not in order:
                order.append(base)
        if whole and (not it.complete or len(order) >= len(it.photos)):
            it.photos = order + [b for b in it.photos if b not in order]      # the listing's own order
            it.complete = True
        else:
            it.photos.extend(b for b in order if b not in it.photos)
        for i, base in enumerate(it.photos):
            self.photos[base].slug, self.photos[base].place = it.slug, i

    # -- a listing's own page (HTML the page fetched)
    def read_page(self, page: str, slug: str = "") -> int:
        """A page's HTML: the data written into it, read like any answer; and — for the listing the page is about —
        its photos as the page's own picture tags give them, when the data didn't."""
        before = len(self.photos)
        for m in re.finditer(r"<script\b([^>]*)>(.*?)</script>", page, re.S | re.I):
            attrs, body = m.group(1), m.group(2)
            if "src=" in attrs or DOMAIN not in body:
                continue
            if "__NEXT_DATA__" in attrs or "json" in attrs.lower():
                self.read_text(_html.unescape(body) if "&quot;" in body else body)
                continue
            for push in re.finditer(r"__next_f\.push\(\s*(\[.*?\])\s*\)", body, re.S):
                try:
                    row = json.loads(push.group(1))
                except ValueError:
                    continue
                if isinstance(row, list) and len(row) > 1 and isinstance(row[1], str):
                    self.read_text(row[1])
        slug = slug.lower()
        if slug and self._ours(slug):
            it = self.listings.get(slug)
            if it is None or not it.complete:
                found = _pictures(_main_pictures(page))
                if found:
                    it = self.listings.setdefault(slug, Listing(slug))
                    self._add(it, found, True)
            if slug in self.listings:
                self.listings[slug].complete = True          # read: not asked for again, whatever it held
        return len(self.photos) - before

    # -- what the page shows
    def read_shown(self, shown: list) -> int:
        """Pictures on the page now (`DOM_JS`): {"src", "all" (its other sizes), "href" (the link it's in), "alt"}."""
        before = len(self.photos)
        for s in shown if isinstance(shown, list) else []:
            if not isinstance(s, dict):
                continue
            found = _pictures([s.get("src"), s.get("all")])
            if not found:
                continue
            slug = slug_of(str(s.get("href") or ""))
            if slug and self._ours(slug):
                it = self._listing_for(slug)
                if not it.title and isinstance(s.get("alt"), str):
                    it.title = " ".join(s["alt"].split())[:300]
                if s.get("sold") is True:                   # the tile wears Depop's "Sold" badge
                    it.sold = True
                self._add(it, found, False)
            elif not slug:
                for base, n, ext, width in found:
                    if base not in self.photos:
                        self.photos[base] = Photo(base, ext)
                        self.loose.append(base)
                    self.photos[base].widths.setdefault(n, width)
            else:
                self.others += 1
        return len(self.photos) - before

    # -- in order
    def ordered(self) -> list[Photo]:
        """Every photo: listing by listing as they were found, each listing's photos in its order; then the ones
        no listing was named for."""
        out = [self.photos[b] for it in self.listings.values() for b in it.photos if b in self.photos]
        out.extend(self.photos[b] for b in self.loose if b in self.photos)
        return out

    def incomplete(self) -> list[str]:
        """Listings whose other photos aren't known yet (only what their tile showed)."""
        return [it.slug for it in self.listings.values() if not it.complete]


def _when(v) -> float:
    """A date in the data as unix time (0 when it isn't one): seconds, milliseconds, or ISO text."""
    if isinstance(v, bool):
        return 0
    if isinstance(v, (int, float)):
        t = float(v) / (1000.0 if v > 1e11 else 1.0)
        return t if social.MIN_DATE < t < 4e9 else 0
    if isinstance(v, str) and len(v) >= 10:
        from datetime import datetime, timezone
        try:
            d = datetime.fromisoformat(v.strip().replace("Z", "+00:00"))
        except ValueError:
            return 0
        if d.tzinfo is None:
            d = d.replace(tzinfo=timezone.utc)
        t = d.timestamp()
        return t if social.MIN_DATE < t < 4e9 else 0
    return 0


def _pictures(node) -> list[tuple[str, int, str, int]]:
    """Every photo version under `node`, in the order written: (base, version, extension, width or 0). Widths come
    from the data's own words: a "width" beside a "url", or a size for a key ({"1280": url})."""
    out: list[tuple[str, int, str, int]] = []

    def take(url, width: int = 0) -> None:
        got = split_photo(url) if isinstance(url, str) else None
        if got is not None:
            out.append((got[0], got[1], got[2], int(width) if 0 < width < 20000 else 0))

    def walk(n, depth: int = 0) -> None:
        if depth > 8:
            return
        if isinstance(n, str):
            if n.count("://") > 1 or " " in n.strip():                   # a srcset: "url 320w, url 640w"
                for part in n.split(","):
                    bits = part.split()
                    if bits:
                        w = bits[1][:-1] if len(bits) > 1 and bits[1].endswith("w") else ""
                        take(bits[0], int(w) if w.isdigit() else 0)
            else:
                take(n)
        elif isinstance(n, dict):
            own = n.get("width") if isinstance(n.get("width"), (int, float)) and not isinstance(n.get("width"), bool) else 0
            for k, v in n.items():
                if isinstance(v, str) and split_photo(v) is not None:
                    take(v, int(k) if isinstance(k, str) and k.isdigit() else int(own or 0))
                else:
                    walk(v, depth + 1)
        elif isinstance(n, list):
            for v in n:
                walk(v, depth + 1)
    walk(node)
    return out


def _main_pictures(page: str) -> list[str]:
    """A listing page's own photos by its picture tags: the ones before the page turns to other listings (the
    first link to another listing after the first photo ends them). Used only when the page's data named none."""
    first = _PHOTO_ANYWHERE.search(page)
    if not first:
        return []
    rest = page[first.start():]
    other = re.search(r"href=[\"'](?:https?://[^/\"']+)?/products/", rest)
    part = rest[:other.start()] if other else rest[:200_000]
    return [m.group(0).replace("\\/", "/") for m in _PHOTO_ANYWHERE.finditer(part)]


# What the page shows now: each listing photo on it, with every size its tag names and the link it sits in.
DOM_JS = r"""
(function () {
  var out = [], seen = {}, imgs = document.querySelectorAll('img, source');
  var re = /\/P\d{1,2}\.(jpe?g|png|webp)(\?|$|\s)/i;
  for (var i = 0; i < imgs.length && out.length < 4000; i++) {
    var el = imgs[i], src = el.currentSrc || el.src || '', all = el.getAttribute('srcset') || el.getAttribute('data-srcset') || '';
    if (!re.test(src) && !re.test(all)) continue;
    var a = el.closest ? el.closest('a[href*="/products/"]') : null;
    var key = src + '|' + (a ? a.getAttribute('href') : '');
    if (seen[key]) continue;
    seen[key] = 1;
    // a "Sold" badge on the tile (Depop lays one over a sold listing's photo) — its own text, not the title's
    var sold = false;
    if (a) {
      var marks = a.querySelectorAll('*');
      for (var j = 0; j < marks.length && !sold; j++) {
        var m = marks[j];
        if (m.children.length === 0 && /^\s*sold\s*$/i.test(m.textContent || '')) sold = true;
      }
      if (!sold && /sold/i.test(a.getAttribute('aria-label') || '')) sold = true;
    }
    out.push({src: src, all: all, href: a ? a.href : '', alt: el.alt || '', sold: sold});
  }
  // the shop's Sold tab: there, and is it the one open?
  var tab = null, tabs = document.querySelectorAll('a, button, [role="tab"]');
  for (var k = 0; k < tabs.length; k++) {
    var t = (tabs[k].innerText || tabs[k].textContent || '').replace(/\s+/g, ' ').trim();
    if (/^sold( items)?( \(?[\d.,]+k?\)?)?$/i.test(t)) { tab = tabs[k]; break; }
  }
  var open = !!tab && (tab.getAttribute('aria-selected') === 'true' || tab.getAttribute('aria-current') === 'page' ||
                       /(^|[\s_-])(active|selected|current)([\s_-]|$)/i.test(tab.className || '') ||
                       /[\/?&#=]sold([\/?&#]|$)/i.test(location.href));
  return JSON.stringify({shown: out, url: location.href, title: document.title, hooked: !!window.__pbHooked,
                         height: (document.scrollingElement || document.documentElement).scrollHeight,
                         sold_tab: !!tab, sold_open: open});
})()
"""


# Opens the shop's Sold tab the way the person would: the page's own "Sold" / "Sold items" tab, link or button,
# clicked — nothing is guessed about Depop's addresses. Returns whether there was one.
SOLD_TAB_JS = r"""
(function () {
  var tabs = document.querySelectorAll('a, button, [role="tab"]');
  for (var k = 0; k < tabs.length; k++) {
    var t = (tabs[k].innerText || tabs[k].textContent || '').replace(/\s+/g, ' ').trim();
    if (/^sold( items)?( \(?[\d.,]+k?\)?)?$/i.test(t)) {
      tabs[k].scrollIntoView({block: 'center'});
      tabs[k].click();
      return JSON.stringify({found: true, text: t});
    }
  }
  return JSON.stringify({found: false});
})()
"""


def page_fetch_js(slug: str) -> str:
    """Has the page fetch a listing's page (its own site, as the person's browser) and keep the HTML where the
    watcher's other copies are — it comes back with them, marked "page"."""
    url = json.dumps(product_url(slug))
    return ("(function(){try{fetch(" + url + ",{credentials:'include'}).then(function(r){return r.ok?r.text():''})"
            ".then(function(t){if(t&&window.__pbKeep)window.__pbKeep(" + url + ",t,'page');},function(){});}catch(e){}"
            "return true;})()")


# ----------------------------------------------------------------------------- the largest version

def pixels(path: str) -> int:
    """Width × height of the picture in `path` (0 when it isn't one)."""
    try:
        from PIL import Image
        import batch_crop  # noqa: F401 — registers HEIC with Pillow, when it can
        with Image.open(path) as im:
            return im.width * im.height
    except Exception:  # noqa: BLE001 — a page, a cut-off file
        return 0


def width_of(path: str) -> int:
    try:
        from PIL import Image
        with Image.open(path) as im:
            return im.width
    except Exception:  # noqa: BLE001
        return 0


def fetch_best(photo: Photo, tmp: str, get) -> tuple[str | None, str, str]:
    """The photo's largest version into `tmp`. `get(url, path)` → (path or None, why) does the fetching. Returns
    (path, "", which version) or (None, why, "").

    P0 first; then the widest version the data names, only if it claims more width than P0 turned out to have (or
    P0 couldn't be had); the rest of `candidates` only until one works. The most pixels wins, then the most bytes."""
    got: list[tuple[int, int, str, str]] = []            # (pixels, bytes, path, url)
    why = "no address"
    claimed, version = photo.claimed()
    for i, url in enumerate(photo.candidates()):
        if got:
            widest = max(width_of(p) for _px, _b, p, _u in got)
            named = version >= 0 and url == photo.url(version)
            if not (named and claimed > widest):
                continue                                 # one in hand, and this one doesn't claim to be bigger
        path = os.path.join(tmp, f"try{i}.{photo.ext}")
        done, said = get(url, path)
        if not done:
            why = said or why
            continue
        px = pixels(done)
        if not px:
            why = "what came wasn't a picture"
            try:
                os.remove(done)
            except OSError:
                pass
            continue
        got.append((px, os.path.getsize(done), done, url))
    if not got:
        return None, why, ""
    got.sort(reverse=True)
    best = got[0]
    for _px, _b, path, _u in got[1:]:
        try:
            os.remove(path)
        except OSError:
            pass
    part = split_photo(best[3])
    return best[2], "", f"P{part[1]}" if part else ""


# ----------------------------------------------------------------------------- where it goes

def file_name(photo: Photo) -> str:
    """`<listing slug>_<n>` — or the photo's own id when no listing was named for it."""
    if photo.slug:
        return social.sanitize(f"{photo.slug}_{photo.place + 1}", photo.key.replace("/", "_"), 120)
    return social.sanitize(photo.base.rsplit("/", 1)[-1], "depop", 120)


def record(folder: str | Path) -> social.Record:
    return social.Record.load(folder, RECORD, FORMAT)


def shop_folder(folder: str | Path, shop: str) -> Path:
    """Where a shop's photos go under the folder chosen: the folder itself when it's already that shop's (its
    record says so), else `<folder>/Depop/<shop>`."""
    folder = Path(folder)
    try:
        if str(record(folder).get("shop") or "").lower() == shop.lower() and shop:
            return folder
    except OSError:
        pass
    return folder / FOLDER / (shop or "photos")


def shop_of_folder(folder: str | Path) -> str:
    """The shop a folder was downloaded from (its record), or ""."""
    try:
        return str(record(folder).get("shop") or "")
    except OSError:
        return ""


def item_for(photo: Photo, listing: Listing | None, folder: Path, shop: str) -> social.Item:
    """The download for one photo (a sold listing's photos are also tagged `SOLD_TAG`, by the window)."""
    return social.Item(key=photo.key, folder=folder, name=file_name(photo), video=False, url=photo.url(0),
                       ext="jpg" if photo.ext in ("jpg", "jpeg") else photo.ext,
                       date=listing.date if listing else 0, caption=listing.title if listing else "",
                       poster=f"@{shop}" if shop else "", keyword=KEYWORD)
