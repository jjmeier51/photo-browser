"""Safe Finder — reading Fanfix (app.fanfix.io) for its downloader (fanfix_downloader.py is the window; social.py
downloads). No Qt here, so it's testable on its own.

For the creators the person subscribes to or bought posts from: what their own logged-in account can see on
Fanfix, saved into the creator's folder on the drive. Personal archive of content they've paid for — nothing
is shared or posted anywhere. Fanfix publishes no API, and its web app sits behind a Cloudflare check that
nothing but a real browser answers, so instead of calling Fanfix this *watches* Fanfix: the window is a real
Chromium logged in as the person, and a small script put into every Fanfix page before the page's own scripts
(`HOOK_JS`) keeps a copy of each JSON answer the page itself receives — the creator's feed, their posts,
messages with bought media — plus any JSON the page carries inline (`__NEXT_DATA__`). The window scrolls the
page to its end so the page loads everything, takes the copies (`DRAIN_JS`), and `extract` picks out the
photos and videos in them. Nothing depends on Fanfix's request shapes or names staying as they are today.

**Picking media out of unknown JSON** (`extract`): a walk over every answer, keeping the post it's inside (id,
date, caption, creator, locked or not) as context. A media object is a dict with a media address (by its
extension — jpg/png/webp/heic/gif/avif, mp4/mov/m4v/webm, an HLS .m3u8 or DASH .mpd), or a dict whose type
says image/video and holds addresses in its variants. Of its addresses the best is taken: a video's own file
before a stream, a stream before nothing; the "original"/"full"/"large" variant before "thumb"/"preview"/
"blur", then the widest. Left out: anything in a post or media object marked locked (`isLocked`, `hasAccess:
false`, `blurred`…), a blurred or preview address when nothing better is there (those are the teasers for posts
not bought), and the creator's avatar, banner and the like (addresses on a user object, or under keys such as
"avatar", "banner", "cover"). Each media object is one file named by its id (else by its address, minus the
signature — the same picture keeps the same name).

**Streams** (`fetch_any`): a video given only as HLS or DASH is fetched with yt-dlp (ffmpeg for HLS when yt-dlp
isn't there). A stream protected by DRM (FairPlay, Widevine, PlayReady — `drm_in`) is not downloaded: it's
noted and skipped. Unprotected streams only; nothing here works round DRM.

**Cookies** go only to Fanfix's own hosts (*.fanfix.io): media served from another company's servers comes
from signed addresses that need no login, and the person's session isn't sent there.

The record (`.fanfix.json` in the creator's folder, `social.Record`): the media ids downloaded and the creator's
handle — the next run takes only what's new, and nothing deleted from the folder comes back.
"""
from __future__ import annotations

import datetime
import hashlib
import importlib.util
import json
import math
import os
import re
import shutil
import subprocess
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path
from urllib.parse import urlsplit, urlunsplit

import simpcity as sc
import social

TAG = "fanfix"
KEYWORD = "Fanfix"
RECORD = ".fanfix.json"
FORMAT = "photobrowser-fanfix"
HOME = "https://app.fanfix.io/"
LOGIN = "https://app.fanfix.io/login"
DOMAIN = "fanfix.io"
REFERER = "https://app.fanfix.io/"
FALLBACK_FOLDER = "Fanfix"                   # media whose creator couldn't be told

IMAGE_EXT = {"jpg", "jpeg", "png", "webp", "heic", "heif", "gif", "avif"}
VIDEO_EXT = {"mp4", "mov", "m4v", "webm"}
STREAM_EXT = {"m3u8", "mpd"}

# First segments of app.fanfix.io paths that aren't a creator's handle.
_NOT_HANDLES = {
    "", "login", "signup", "sign-up", "register", "home", "feed", "explore", "discover", "search", "messages",
    "message", "chat", "chats", "inbox", "notifications", "settings", "account", "wallet", "billing", "payments",
    "purchases", "purchased", "unlocked", "subscriptions", "subscribed", "following", "bookmarks", "saved",
    "lists", "collections", "onboarding", "privacy-policy", "general-terms-of-service", "content-guidelines",
    "terms", "privacy", "help", "support", "faq", "post", "posts", "p", "creator", "creators", "profile",
    "user", "users", "u", "live", "vault", "media", "auth", "logout", "forgot-password", "reset-password",
}


# ----------------------------------------------------------------------------- what runs in the page

# Put into every Fanfix page before the page's own scripts: a copy of each JSON answer the page receives (fetch
# and XMLHttpRequest), and of JSON the page carries inline. Kept in `window.__pbCaptured` until taken.
HOOK_JS = r"""
(function () {
  if (window.__pbHooked) return;
  window.__pbHooked = true;
  var box = window.__pbCaptured = [];
  var MAX = 6000, LONGEST = 12000000;
  function keep(url, text) {
    try {
      if (!text || typeof text !== 'string' || text.length > LONGEST) return;
      var c = text.replace(/^\s+/, '').charAt(0);
      if (c !== '{' && c !== '[') return;
      box.push({u: String(url || location.href), t: text});
      if (box.length > MAX) box.splice(0, box.length - MAX);
    } catch (e) {}
  }
  window.__pbKeep = keep;
  var realFetch = window.fetch;
  if (realFetch) {
    window.fetch = function () {
      return realFetch.apply(this, arguments).then(function (r) {
        try {
          var ct = (r.headers && r.headers.get('content-type')) || '';
          if (ct.indexOf('json') >= 0) r.clone().text().then(function (t) { keep(r.url, t); }, function () {});
        } catch (e) {}
        return r;
      });
    };
  }
  var open = XMLHttpRequest.prototype.open, send = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open = function (m, u) { this.__pbUrl = u; return open.apply(this, arguments); };
  XMLHttpRequest.prototype.send = function () {
    this.addEventListener('load', function () {
      try {
        var ct = this.getResponseHeader('content-type') || '';
        if (ct.indexOf('json') < 0) return;
        if (this.responseType === '' || this.responseType === 'text') keep(this.responseURL || this.__pbUrl, this.responseText);
        else if (this.responseType === 'json' && this.response) keep(this.responseURL || this.__pbUrl, JSON.stringify(this.response));
      } catch (e) {}
    });
    return send.apply(this, arguments);
  };
  function inline() {
    var nodes = document.querySelectorAll('script#__NEXT_DATA__, script[type="application/json"], script[type="application/ld+json"]');
    for (var i = 0; i < nodes.length; i++) keep(location.href, nodes[i].textContent);
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', inline); else inline();
})();
"""

# The copies so far, taken (so each is read once).
DRAIN_JS = "JSON.stringify((window.__pbCaptured || []).splice(0, 60))"

# One step down the page: the scrolling part of the page (the biggest scrollable box, else the page) moved on
# by most of a screen. Returns where it is, so the window can tell the end (no further, and nothing new).
SCROLL_JS = r"""
(function () {
  var best = document.scrollingElement || document.documentElement;
  var room = best.scrollHeight - best.clientHeight;
  var els = document.querySelectorAll('div, main, section, ul');
  for (var i = 0; i < els.length; i++) {
    var el = els[i];
    if (el.clientHeight < 200) continue;
    var r = el.scrollHeight - el.clientHeight;
    if (r <= room + 50) continue;
    var oy = getComputedStyle(el).overflowY;
    if (oy === 'auto' || oy === 'scroll' || oy === 'overlay') { best = el; room = r; }
  }
  var before = best.scrollTop;
  best.scrollTop = before + Math.max(400, best.clientHeight * 0.85);
  if (best !== document.scrollingElement) window.scrollBy(0, Math.max(400, window.innerHeight * 0.85));
  return JSON.stringify({top: best.scrollTop, height: best.scrollHeight, client: best.clientHeight,
                         moved: best.scrollTop !== before, url: location.href,
                         captured: (window.__pbCaptured || []).length, hooked: !!window.__pbHooked});
})()
"""

# What the page shows, for when its JSON held no media (a page drawn on the server): big pictures that aren't
# blurred, and videos with a real address.
DOM_JS = r"""
(function () {
  var out = [];
  var imgs = document.querySelectorAll('img');
  for (var i = 0; i < imgs.length; i++) {
    var im = imgs[i], src = im.currentSrc || im.src || '';
    if (!/^https?:/.test(src) || im.naturalWidth < 400 || im.naturalHeight < 300) continue;
    var f = getComputedStyle(im).filter || '';
    if (f.indexOf('blur') >= 0) continue;
    out.push({src: src, w: im.naturalWidth, h: im.naturalHeight, video: false});
  }
  var vids = document.querySelectorAll('video, video source');
  for (var j = 0; j < vids.length; j++) {
    var v = vids[j], s = v.currentSrc || v.src || '';
    if (/^https?:/.test(s)) out.push({src: s, w: v.videoWidth || 0, h: v.videoHeight || 0, video: true});
  }
  return JSON.stringify(out);
})()
"""


# ----------------------------------------------------------------------------- picking media out of JSON

@dataclass
class Found:
    """One photo or video the page's data names."""
    key: str                         # what the file is named by (the media id, else the address)
    url: str
    video: bool
    ext: str                         # "jpg", "mp4", "m3u8"…
    post: str = ""
    date: float = 0
    caption: str = ""
    creator: str = ""
    score: float = 0                 # how good this address is (a better one for the same key replaces it)

    @property
    def stream(self) -> bool:
        return self.ext in STREAM_EXT


@dataclass
class Haul:
    """What `extract` found in some answers, and what it left out."""
    found: dict[str, Found] = field(default_factory=dict)
    locked: int = 0                  # media of posts not unlocked (teasers, blurred previews)
    profile: int = 0                 # avatars, banners and the like
    creators: dict[str, int] = field(default_factory=dict)   # handles seen on posts, how often

    def add(self, f: Found) -> bool:
        """Keeps `f` (or the better of it and one already kept under its key). True when it's new."""
        old = self.found.get(f.key)
        if old is None:
            self.found[f.key] = f
            return True
        if f.score > old.score:
            for k in ("post", "date", "caption", "creator"):
                if not getattr(f, k) and getattr(old, k):
                    setattr(f, k, getattr(old, k))
            self.found[f.key] = f
        return False


_ID_KEYS = ("id", "uuid", "mediaId", "media_id", "mediaUuid", "_id", "fileId", "assetId", "contentId", "postId")
_DATE_KEYS = ("createdAt", "created_at", "publishedAt", "published_at", "postedAt", "posted_at", "sentAt", "sent_at",
              "releasedAt", "scheduledAt", "date", "timestamp", "created", "time")
_TEXT_KEYS = ("caption", "text", "body", "description", "content", "message", "title")
_HANDLE_KEYS = ("username", "handle", "userName", "user_name", "creatorUsername", "creator_username", "slug",
                "screenName", "screen_name", "vanity")
_PERSON_KEYS = ("creator", "user", "author", "owner", "sender", "account", "profile", "createdBy", "postedBy", "from")
_TYPE_KEYS = ("type", "mediaType", "media_type", "kind", "mimeType", "mime_type", "contentType", "content_type",
              "fileType", "file_type", "format")
_LOCKED_TRUE = ("isLocked", "locked", "is_locked", "isBlurred", "blurred", "is_blurred", "isPaywalled", "paywalled",
                "needsPurchase", "requiresPurchase", "requires_purchase", "isTeaser", "teaser")
_LOCKED_FALSE = ("hasAccess", "has_access", "canView", "can_view", "isPurchased", "is_purchased", "purchased",
                 "isUnlocked", "is_unlocked", "unlocked", "canAccess", "can_access", "isAccessible", "accessible",
                 "viewable", "isViewable")
_MEDIA_LISTS = ("media", "medias", "attachments", "assets", "images", "videos", "photos", "items", "contents",
                "mediaItems", "media_items", "files")

_GOOD = {"original", "orig", "source", "full", "fullsize", "hd", "raw", "master", "max", "download", "large", "big",
         "high", "highres", "uhd", "fhd"}
_OK = {"url", "src", "file", "path", "location", "video", "image", "photo", "picture", "media", "link", "href",
       "hls", "stream", "playback", "mp4", "signed", "public"}
_BAD = {"thumb", "thumbnail", "thumbnails", "small", "preview", "poster", "blur", "blurred", "low", "lowres",
        "medium", "sm", "md", "xs", "tiny", "mini", "placeholder", "teaser", "sample", "snapshot", "still", "frame",
        "sprite", "lqip", "watermark", "watermarked", "gif"}
_PROFILE = {"avatar", "avatars", "banner", "header", "background", "icon", "logo", "emoji", "sticker", "badge",
            "flag", "favicon", "og", "cover", "headshot"}


def _words(key) -> list[str]:
    """A key's words: "thumbnailUrl" → ["thumbnail", "url"], "signed_url_lg" → ["signed", "url", "lg"]."""
    return [w.lower() for w in re.findall(r"[A-Z]?[a-z]+|[A-Z]+(?![a-z])|\d+", str(key))]


def ext_of(url: str) -> str:
    path = urlsplit(url).path
    last = path.rsplit("/", 1)[-1]
    return last.rsplit(".", 1)[-1].lower() if "." in last else ""


def is_media_url(s) -> bool:
    if not isinstance(s, str) or not s.startswith(("http://", "https://")) or len(s) > 4000:
        return False
    return ext_of(s) in IMAGE_EXT | VIDEO_EXT | STREAM_EXT


def stable_key(url: str) -> str:
    """A name for media with no id: its address without the query (where the signature and expiry live)."""
    p = urlsplit(url)
    return "u" + hashlib.sha1(urlunsplit((p.scheme, p.netloc, p.path, "", "")).encode("utf-8")).hexdigest()[:16]


def _as_id(v) -> str:
    if isinstance(v, bool) or v is None:
        return ""
    if isinstance(v, (int, float)) and math.isfinite(v):
        return str(int(v))
    if isinstance(v, str) and 0 < len(v) <= 80 and not v.startswith(("http://", "https://")):
        return re.sub(r"[^A-Za-z0-9_-]", "", v)[:64]
    return ""


def when(v) -> float:
    """A date as unix time: ISO 8601 text, or seconds / milliseconds since 1970. 0 when it isn't one."""
    t = 0.0
    if isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v):
        t = float(v) / 1000 if v > 1e12 else float(v)
    elif isinstance(v, str) and len(v) >= 8:
        s = v.strip()
        if s.isdigit():
            return when(int(s))
        try:
            d = datetime.datetime.fromisoformat(s.replace("Z", "+00:00"))
            if d.tzinfo is None:
                d = d.replace(tzinfo=datetime.timezone.utc)
            t = d.timestamp()
        except ValueError:
            return 0.0
    return t if social.MIN_DATE <= t <= 4_102_444_800 else 0.0


def _handle_of(d: dict) -> str:
    for k in _HANDLE_KEYS:
        v = d.get(k)
        if isinstance(v, str) and 0 < len(v) <= 60 and re.fullmatch(r"[A-Za-z0-9_.\-]+", v):
            return v.lstrip("@")
    return ""


def _user_like(d: dict) -> bool:
    """A creator's or fan's own object (a handle, no media of a post)."""
    return bool(_handle_of(d)) and not any(k in d for k in _MEDIA_LISTS) and not any(k in d for k in ("caption", "postId"))


def _locked(d: dict) -> bool:
    return any(d.get(k) is True for k in _LOCKED_TRUE) or any(d.get(k) is False for k in _LOCKED_FALSE)


def _type_of(d: dict) -> str:
    for k in _TYPE_KEYS:
        v = d.get(k)
        if isinstance(v, str):
            s = v.lower()
            if "video" in s or "mpegurl" in s or "dash" in s:
                return "video"
            if any(w in s for w in ("image", "photo", "picture", "jpeg", "png", "webp")):
                return "image"
    return ""


@dataclass
class _Ctx:
    post: str = ""
    date: float = 0
    caption: str = ""
    creator: str = ""
    locked: bool = False
    profile: bool = False            # inside a user object's avatar / banner


def _post_ctx(d: dict, ctx: _Ctx) -> _Ctx:
    """The context below a dict: a post's id, date, caption and creator taken over; locked if it says so."""
    out = _Ctx(ctx.post, ctx.date, ctx.caption, ctx.creator, ctx.locked or _locked(d), ctx.profile)
    date = next((when(d[k]) for k in _DATE_KEYS if k in d and when(d[k])), 0.0)
    text = next((d[k] for k in _TEXT_KEYS if isinstance(d.get(k), str) and d[k].strip()
                 and not d[k].startswith(("http://", "https://"))), "")
    posty = bool(date or text or any(isinstance(d.get(k), list) for k in _MEDIA_LISTS))
    if posty and not _user_like(d):
        pid = next((_as_id(d[k]) for k in ("postId", "post_id", "id", "uuid", "_id") if _as_id(d.get(k))), "")
        if pid:
            out.post = pid
        if date:
            out.date = date
        if text:
            out.caption = text.strip()[:2000]
        for k in _PERSON_KEYS:
            if isinstance(d.get(k), dict) and _handle_of(d[k]):
                out.creator = _handle_of(d[k])
                break
        else:
            for k in ("creatorUsername", "creator_username", "username", "handle"):
                if isinstance(d.get(k), str) and _handle_of({k: d[k]}):
                    out.creator = _handle_of({k: d[k]})
                    break
    return out


def _addresses(d: dict, depth: int = 0, via: tuple = ()) -> list[tuple[tuple, str, int]]:
    """Media addresses in a dict and its variants (dicts and lists of dicts, two levels down): (the keys on the
    way, the address, its width or 0)."""
    out = []
    width = 0
    for k in ("width", "w", "originalWidth"):
        if isinstance(d.get(k), (int, float)) and not isinstance(d.get(k), bool):
            width = int(d[k])
            break
    label = next((str(d[k]) for k in ("size", "quality", "label", "name", "variant", "resolution")
                  if isinstance(d.get(k), (str, int)) and not isinstance(d.get(k), bool)), "")
    for k, v in d.items():
        if is_media_url(v):
            out.append((via + (k, label), v, width))
        elif depth < 2 and isinstance(v, dict):
            out += _addresses(v, depth + 1, via + (k,))
        elif depth < 2 and isinstance(v, list):
            for x in v[:40]:
                if isinstance(x, dict):
                    out += _addresses(x, depth + 1, via + (k,))
                elif is_media_url(x):
                    out.append((via + (k,), x, 0))
    return out


def _score(keys: tuple, url: str, width: int, video: bool) -> float:
    words = set()
    for k in keys:
        words.update(_words(k))
    s = 0.0
    s += 3 * len(words & _GOOD) + 1 * min(1, len(words & _OK)) - 4 * len(words & _BAD)
    e = ext_of(url)
    if video:
        s += 20 if e in VIDEO_EXT else 10 if e == "m3u8" else 5 if e == "mpd" else -50
    elif e not in IMAGE_EXT:
        s -= 50
    if "blur" in url.lower():
        s -= 8
    return s + min(width, 8000) / 1000


def _media(d: dict, ctx: _Ctx, haul: Haul) -> bool:
    """`d` as one media object, when it is one: added to the haul (or counted as left out). True when `d`
    was taken as media — its variants aren't then looked at again as media of their own."""
    direct = [k for k, v in d.items() if is_media_url(v)]
    kind = _type_of(d)
    if not direct and not kind:
        # an id with variants under it that carry no ids of their own: one media object in several sizes
        if not any(_as_id(d.get(k)) for k in _ID_KEYS[:9]):
            return False
        subs = [v for v in d.values() if isinstance(v, (dict, list))]
        if not subs or any(isinstance(x, dict) and any(_as_id(x.get(k)) for k in _ID_KEYS[:9])
                           for v in subs for x in (v if isinstance(v, list) else [v])):
            return False
    found = _addresses(d)
    if not found:
        return False
    video = kind == "video" or (kind != "image" and any(ext_of(u) in VIDEO_EXT | STREAM_EXT for _k, u, _w in found))
    if ctx.profile or _user_like(d) or any(set(_words(k)) & _PROFILE for k in direct) and not video:
        haul.profile += 1
        return True
    if ctx.locked or _locked(d):
        haul.locked += 1
        return True
    best = max(found, key=lambda f: _score(f[0], f[1], f[2], video))
    keys, url, width = best
    score = _score(keys, url, width, video)
    if score < -20:                          # a video's poster with no video, say: nothing to take
        return True
    words = set()
    for k in keys:
        words.update(_words(k))
    if words & {"blur", "blurred", "teaser", "placeholder", "preview"} or "blur" in url.lower():
        haul.locked += 1                     # only a teaser is there: a post not bought
        return True
    mid = next((_as_id(d[k]) for k in _ID_KEYS[:9] if _as_id(d.get(k))), "")
    key = mid or stable_key(url)
    date = next((when(d[k]) for k in _DATE_KEYS if k in d and when(d[k])), 0.0) or ctx.date
    haul.add(Found(key, url, video, ext_of(url) or ("mp4" if video else "jpg"), ctx.post, date, ctx.caption,
                   ctx.creator, score))
    if ctx.creator:
        haul.creators[ctx.creator] = haul.creators.get(ctx.creator, 0) + 1
    return True


def _walk(node, ctx: _Ctx, haul: Haul, key: str = "", depth: int = 0) -> None:
    if depth > 40:
        return
    if isinstance(node, dict):
        here = _post_ctx(node, ctx)
        if _user_like(node):                 # a user object's own pictures are its avatar, banner…
            for k, v in node.items():         # …and posts under a creator's object are that creator's
                if isinstance(v, (dict, list)):
                    sub = _Ctx(here.post, here.date, here.caption, here.creator or _handle_of(node), here.locked,
                               here.profile or bool(set(_words(k)) & (_PROFILE | {"profile", "picture", "photo", "image"})))
                    _walk(v, sub, haul, k, depth + 1)
                elif is_media_url(v):
                    haul.profile += 1
            return
        if set(_words(key)) & _PROFILE:
            here.profile = True
        if _media(node, here, haul):
            return
        for k, v in node.items():
            if isinstance(v, (dict, list)):
                _walk(v, here, haul, k, depth + 1)
    elif isinstance(node, list):
        for x in node:
            if isinstance(x, (dict, list)):
                _walk(x, ctx, haul, key, depth + 1)


def extract(doc, haul: Haul | None = None) -> Haul:
    """The photos and videos named in one JSON answer (parsed), added to `haul`."""
    haul = haul or Haul()
    _walk(doc, _Ctx(), haul)
    return haul


def extract_text(text: str, haul: Haul | None = None) -> Haul:
    try:
        doc = json.loads(text)
    except (ValueError, RecursionError):
        return haul or Haul()
    return extract(doc, haul)


def from_page(shown: list[dict], haul: Haul | None = None) -> Haul:
    """Media the page shows (`DOM_JS`), for when its data held none: named by address."""
    haul = haul or Haul()
    for m in shown:
        url = m.get("src") or ""
        if not is_media_url(url) and not m.get("video"):
            continue
        video = bool(m.get("video"))
        haul.add(Found(stable_key(url), url, video, ext_of(url) or ("mp4" if video else "jpg"),
                       score=int(m.get("w") or 0) / 1000))
    return haul


# ----------------------------------------------------------------------------- creators and folders

def creator_from_url(url: str) -> str:
    """The creator a Fanfix page is for: app.fanfix.io/<handle>[/…] (and /@handle); "" for any other page."""
    p = urlsplit(url or "")
    host = (p.hostname or "").lower()
    if host != DOMAIN and not host.endswith("." + DOMAIN):
        return ""
    parts = [x for x in p.path.split("/") if x]
    if not parts:
        return ""
    first = parts[0].lstrip("@")
    if first.lower() in _NOT_HANDLES or not re.fullmatch(r"[A-Za-z0-9_.\-]{2,60}", first):
        return ""
    return first


def clean_handle(text: str) -> str:
    """"@jane", "app.fanfix.io/jane", "https://fanfix.io/jane?x=1" → "jane"."""
    t = (text or "").strip()
    if "fanfix.io" in t:
        return creator_from_url(t if "://" in t else "https://" + t)
    return t.lstrip("@").split("/")[0].split("?")[0].strip()


def record(folder: str | Path) -> social.Record:
    return social.Record.load(folder, RECORD, FORMAT)


def ids_on_disk(folder: str | Path) -> set[str]:
    """The media named in the folder's files (their names are the media ids)."""
    out: set[str] = set()
    try:
        for e in os.scandir(folder):
            if e.is_file() and not e.name.startswith("."):
                out.add(e.name.rsplit(".", 1)[0])
    except OSError:
        pass
    return out


def destination(person: str | Path, creator: str) -> Path:
    """Where a creator's media go from the folder that was right-clicked: that folder when it's the creator's
    (its record names them, or it's named for them), a subfolder that is, else `<folder>/<creator>`."""
    person = Path(person)
    if not creator:
        return person if record(person).exists else person / FALLBACK_FOLDER
    want = creator.lower()
    if (record(person).get("handle") or "").lower() == want or person.name.lower() == want:
        return person
    try:
        for e in sorted(os.scandir(person), key=lambda e: e.name):
            if e.is_dir() and not e.name.startswith(".") and (
                    e.name.lower() == want or (record(e.path).get("handle") or "").lower() == want):
                return Path(e.path)
    except OSError:
        pass
    return person / social.sanitize(creator, FALLBACK_FOLDER, 80)


def item_for(f: Found, folder: Path) -> social.Item:
    ext = f.ext if f.ext not in STREAM_EXT else "mp4"
    if ext == "jpeg":
        ext = "jpg"
    return social.Item(f.key, folder, f.key, f.video, f.url, ext=ext, date=f.date, caption=f.caption,
                       poster=f.creator and f"@{f.creator}", keyword=KEYWORD)


# ----------------------------------------------------------------------------- fetching

def fanfix_host(url: str) -> bool:
    host = (urlsplit(url).hostname or "").lower()
    return host == DOMAIN or host.endswith("." + DOMAIN)


def tries_for(url: str, ua: str, cookie: str) -> list[dict[str, str]]:
    """Headers to try: plainly first; with the person's Fanfix session only for Fanfix's own hosts."""
    plain = social.headers(REFERER, ua=ua)
    return [plain, social.headers(REFERER, cookie, ua)] if cookie and fanfix_host(url) else [plain]


_DRM = re.compile(r"SAMPLE-AES|com\.apple\.streamingkeydelivery|edef8ba9-79d6-4ace-a3c8-27dcd51d21ed|"
                  r"9a04f079-9840-4286-ab92-e65be0885f95|com\.microsoft\.playready|com\.widevine|ContentProtection|"
                  r"urn:uuid:", re.I)


def drm_in(manifest: str) -> bool:
    """Whether an HLS playlist or DASH manifest is DRM-protected (FairPlay, Widevine, PlayReady). Plain
    AES-128 HLS — what any player decrypts with the stream's own key — isn't DRM."""
    return bool(_DRM.search(manifest or ""))


def _get_text(url: str, h: dict[str, str]) -> str:
    req = urllib.request.Request(url, headers=h)
    with urllib.request.urlopen(req, timeout=30, context=sc.ssl_context()) as resp:
        return resp.read(4_000_000).decode("utf-8", "replace")


def fetch_stream(item: social.Item, tmp: str, tries: list[dict[str, str]]) -> tuple[str | None, str]:
    """An HLS or DASH video into the temp folder as one MP4 — unless it's DRM-protected (not downloaded)."""
    manifest, why, h = "", "no answer", tries[0]
    for h in tries:
        try:
            manifest = _get_text(item.url, h)
            break
        except Exception as e:  # noqa: BLE001 — any refusal: the next headers, else the reason
            why = str(e) or type(e).__name__
    if not manifest:
        return None, f"couldn't read the stream ({why})"
    if drm_in(manifest):
        return None, "protected by DRM — not downloaded"
    out = os.path.join(tmp, item.filename)
    if importlib.util.find_spec("yt_dlp") is not None:
        return _yt_dlp(item.url, h, tmp, out)
    if ext_of(item.url) == "m3u8":
        return _ffmpeg_hls(item.url, h, out)
    return None, "a DASH video needs yt-dlp (mac/run.sh installs it)"


def _yt_dlp(url: str, h: dict[str, str], tmp: str, out: str) -> tuple[str | None, str]:
    import yt_dlp
    import video_tools
    opts = {
        "outtmpl": os.path.join(tmp, "stream.%(ext)s"), "quiet": True, "no_warnings": True, "noprogress": True,
        "http_headers": h, "format": "bv*+ba/b", "merge_output_format": "mp4", "retries": 3,
        "concurrent_fragment_downloads": 4, "noplaylist": True,
    }
    ff = video_tools.ffmpeg()
    if ff:
        opts["ffmpeg_location"] = ff
    try:
        with yt_dlp.YoutubeDL(opts) as ydl:
            ydl.download([url])
    except Exception as e:  # noqa: BLE001 — yt-dlp refuses DRM itself, and fails on what it can't read
        text = str(e)
        return None, "protected by DRM — not downloaded" if "DRM" in text else f"the stream wouldn't download ({text[:160]})"
    got = [os.path.join(tmp, n) for n in os.listdir(tmp) if n.startswith("stream.") and not n.endswith(".part")]
    if not got:
        return None, "the stream came down empty"
    best = max(got, key=os.path.getsize)
    shutil.move(best, out)
    return out, ""


def _ffmpeg_hls(url: str, h: dict[str, str], out: str) -> tuple[str | None, str]:
    import video_tools
    ff = video_tools.ffmpeg()
    if not ff:
        return None, "an HLS video needs yt-dlp or ffmpeg (brew install ffmpeg)"
    head = "".join(f"{k}: {v}\r\n" for k, v in h.items() if k.lower() != "user-agent")
    cmd = [ff, "-nostdin", "-loglevel", "error", "-y", "-user_agent", h.get("User-Agent", social.UA), "-headers", head,
           "-i", url, "-c", "copy", "-bsf:a", "aac_adtstoasc", "-movflags", "+faststart", out]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=3600)
    except (OSError, subprocess.TimeoutExpired) as e:
        return None, f"ffmpeg: {e}"
    if r.returncode != 0 or not os.path.exists(out) or os.path.getsize(out) < social.MIN_BYTES:
        return None, "ffmpeg: " + (r.stderr.strip().splitlines() or ["couldn't read the stream"])[-1][:160]
    return out, ""


def fetcher(ua: str, cookie: str):
    """`social.settle`'s fetcher for Fanfix: streams through `fetch_stream`, files as usual — each with the
    headers its host gets (`tries_for`)."""
    def fetch(item: social.Item, tmp: str, _tries: list[dict[str, str]]) -> tuple[str | None, str]:
        tries = tries_for(item.url, ua, cookie)
        if ext_of(item.url) in STREAM_EXT:
            return fetch_stream(item, tmp, tries)
        return social.download(item, tmp, tries)
    return fetch
