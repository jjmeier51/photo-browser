"""Safe Finder — reading Fanfix (app.fanfix.io) for its downloader (fanfix_downloader.py is the window; social.py
downloads). No Qt here, so it's testable on its own.

For the creators the person subscribes to or bought posts from: what their own logged-in account can open on
Fanfix, saved into the creator's folder on the drive — a personal archive of what they paid for. Like the
browser-extension downloaders that work on Fanfix (fanripper's documented model — its code is closed and its
licence forbids taking it apart, so nothing here comes from it), **everything goes through the person's own
logged-in browser**. Fanfix publishes no API and sits behind Cloudflare, whose check only a real browser passes:
a request made outside that browser gets the check page ("Just a moment…"), not the file. So the window is a
real Chromium logged in as the person, and three things come from it:

- **What's there** — from what the page itself loads. A script put into every Fanfix page before the page's own
  (`HOOK_JS`) keeps a copy of every data answer the page receives (fetch and XMLHttpRequest): JSON, and the React
  Server Components stream a Next.js page is drawn from (`text/x-component`), plus the same stream written into
  the page itself (`self.__next_f.push([1,"…"])` scripts, read by `inline()`). The window scrolls the page to its
  end so the page loads everything. `documents` finds the JSON in each answer — the whole answer, or row by row
  in a stream, or several in a row — Firestore's typed values are made plain (`plain`), and `extract` picks the
  photos and videos out.
- **What's shown** — backs that up. Every scroll step `DOM_JS` notes the full-size pictures and the videos on
  screen (not blurred, not avatars or banners; with the post's creator and time when its card shows them), so
  media the data didn't name — or named in a shape `extract` doesn't know — is still saved (`from_page`). What
  the data already named, by address or by the media id in its address, isn't taken twice (`Haul.knows`).
- **The files** — downloaded by that same browser: the window hands each address to Chromium's own download
  manager (the person's session, Cloudflare's clearance, the browser's own connection), and only when that fails
  is a plain request tried (`fetcher`). A download that turns out to be a web page (a login or Cloudflare page,
  an error) isn't kept (`sniff`).

**Fanfix's own media objects come first** (`_fanfix_walk`, `_take_asset` — learned from a real chat, Nov 8): data
arrives inline and from Next.js server actions (`{"ok":true,"data":{"hasMore":…,"messages":[…]}}`), and every
photo or video is an asset `{id, type, mimeType, sourceUrl, thumbnailUrl, manifests…}` in a message's
`messageAssets`. A free one's `sourceUrl` is the original — taken. A bought pay-per-view's assets, photos too, have
no `sourceUrl`, only FairPlay/Widevine manifests — DRM, counted and left (`Haul.drm`). Not bought: `showAsset:
false` and a blurred picture. People's own pictures (`static.fanfix.io/Public/…`, the Messages list's `imageUrl`,
pictures inside `/@` links) and thumbnails are never media. A chat's older messages load at its top
(`Haul.older`), and the Messages list names every chat (`Haul.channels`). Only where an answer holds no asset
objects does the shape-guessing below run.

**Picking media out of unknown JSON** (`extract`): a walk over every answer, keeping the post it's inside (id,
date, caption, creator, open or locked) as context. A media object is a dict with a media address (by its
extension — jpg/png/webp/heic/gif/avif, mp4/mov/m4v/webm, an HLS .m3u8 or DASH .mpd — or, in a dict whose type
says image/video, any address under a url/src-like key), or a dict whose type says image/video and holds
addresses in its variants. Of its addresses the best is taken: a video's own file before a stream, a stream
before nothing; the "original"/"full"/"large" variant before "thumb"/"preview"/"blur", then the widest.
Resizing addresses (`/_next/image?url=…`, `/cdn-cgi/image/…/<address>`) are read for the picture behind them.

**Locked or open** (`_access`): what the post or media says about this account — bought, unlocked or viewable
beats locked (a pay-per-view post often stays `isLocked` after it's bought, with `isPurchased: true`); locked,
blurred, no access, or not bought with a price on it leaves it out; saying nothing takes the post's word. "Not
purchased" alone means nothing — every subscription post says it. A media object with only a blurred or preview address is a teaser for a post
not bought: counted, not downloaded. A video named with only its poster is counted as "not given" (its address
comes later, when it plays) — the window says how many, and the page harvest may still catch it.

**Streams** (`fetch_stream`): a video given only as HLS or DASH is fetched with yt-dlp (ffmpeg for HLS when yt-dlp
isn't there). **DRM is never worked round**: a stream protected by FairPlay, Widevine or PlayReady (`drm_in`), or
an MP4 whose tracks are encrypted (`mp4_protected` — Common Encryption's `encv`/`enca` entries or a `pssh` box),
is noted and not kept.

**Cookies** go only to Fanfix's own hosts (*.fanfix.io) on a plain request: media served from another company's
servers comes from signed addresses that need no login, and the person's session isn't sent there.

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
import struct
import subprocess
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path
from urllib.parse import parse_qs, urljoin, urlsplit, urlunsplit

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

# Fanfix's own pages the window offers besides a creator's: (button, path, what it is).
PAGES = (("Home Feed", "home", "the posts of everyone you subscribe to"),
         ("Purchases", "gallery", "everything you've bought (your Gallery)"),
         ("Messages", "messages", "your chats — Download here reads every chat; or open one"))

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
    "gallery", "validate", "verify-email", "login-link", "oauth", "agency-login", "native-payments", "api",
    "email-verification-required", "revert-email", "application-submitted", "_next",
}


# ----------------------------------------------------------------------------- what runs in the page

# Put into every Fanfix page before the page's own scripts: a copy of each data answer the page receives (fetch
# and XMLHttpRequest — JSON, React Server Components streams, plain text), and of the data the page carries in
# itself (`inline`, run again at each drain: a streamed page keeps adding scripts). Kept in `window.__pbCaptured`
# until taken. Pictures, videos, scripts, styles and pages aren't copied.
HOOK_JS = r"""
(function () {
  if (window.__pbHooked) return;
  window.__pbHooked = true;
  window.__pbCaptured = [];
  var MAX = 6000, LONGEST = 15000000;
  var NOT_DATA = /^(image|video|audio|font)\/|text\/(css|html|javascript)|javascript|ecmascript|wasm|octet-stream|mpegurl|dash\+xml|protobuf|grpc/i;
  function keep(url, text, how, req) {
    try {
      if (!text || typeof text !== 'string' || text.length < 2 || text.length > LONGEST) return;
      var box = window.__pbCaptured, e = {u: String(url || location.href), t: text, k: how || ''};
      if (req) { e.m = req.m; e.b = req.b; e.a = req.a; if (req.a) e.k = 'action'; }
      box.push(e);
      if (box.length > MAX) box.splice(0, box.length - MAX);
    } catch (e) {}
  }
  function asked(input, init) {
    // what the page asked for — the method, the body (a Next.js server action's arguments) and the action id
    var req = {m: 'GET', b: '', a: ''};
    try {
      req.m = String((init && init.method) || (input && input.method) || 'GET').toUpperCase();
      if (init && typeof init.body === 'string') req.b = init.body.slice(0, 4000);
      var h = (init && init.headers) || (input && input.headers);
      if (h) req.a = String((typeof h.get === 'function' ? h.get('Next-Action') : (h['Next-Action'] || h['next-action'])) || '');
    } catch (e) {}
    return req;
  }
  function wanted(ct, text) {
    ct = String(ct || '');
    if (NOT_DATA.test(ct)) return false;
    if (/json|x-component|text\/plain/i.test(ct)) return true;
    var c = String(text || '').replace(/^\s+/, '').charAt(0);
    return c === '{' || c === '[' || /[0-9a-f]/i.test(c);
  }
  window.__pbKeep = keep;
  var realFetch = window.fetch;
  if (realFetch) {
    window.fetch = function (input, init) {
      var req = asked(input, init);
      return realFetch.apply(this, arguments).then(function (r) {
        try {
          var ct = (r.headers && r.headers.get('content-type')) || '';
          if (!NOT_DATA.test(ct)) r.clone().text().then(function (t) { if (wanted(ct, t)) keep(r.url, t, 'fetch', req); }, function () {});
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
        var ct = this.getResponseHeader('content-type') || '', url = this.responseURL || this.__pbUrl;
        if (this.responseType === '' || this.responseType === 'text') { if (wanted(ct, this.responseText)) keep(url, this.responseText, 'xhr'); }
        else if (this.responseType === 'json' && this.response) keep(url, JSON.stringify(this.response), 'xhr');
      } catch (e) {}
    });
    return send.apply(this, arguments);
  };
  function inline() {
    try {
      var nodes = document.querySelectorAll('script:not([src])'), rsc = [];
      for (var i = 0; i < nodes.length; i++) {
        var s = nodes[i];
        if (s.__pbRead) continue;
        s.__pbRead = true;
        var t = s.textContent || '';
        if (s.id === '__NEXT_DATA__' || /json/i.test(s.type || '')) { keep(location.href, t, 'inline'); continue; }
        var m = t.match(/__next_f\.push\(\s*(\[[\s\S]*\])\s*\)\s*;?\s*$/);
        if (m) { try { var a = JSON.parse(m[1]); if (a[0] === 1 && typeof a[1] === 'string') rsc.push(a[1]); } catch (e) {} }
      }
      if (rsc.length) keep(location.href, rsc.join(''), 'inline-rsc');
    } catch (e) {}
  }
  window.__pbInline = inline;
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', inline); else inline();
})();
"""

# The copies so far, taken (so each is read once) — after a look for data the page has written into itself since.
DRAIN_JS = "(window.__pbInline && window.__pbInline(), JSON.stringify((window.__pbCaptured || []).splice(0, 60)))"

# One step along the page: the scrolling part of the page (the biggest scrollable box, else the page) moved on by
# most of a screen — down (a feed, a gallery), or up (a chat: its older messages load at the top; `scroll_js(-1)`;
# "up" is also right for a chat drawn bottom-up, where scrollTop runs negative). Returns where it is, so the
# window can tell the end (no further, and nothing new) — and what page it's on (a Cloudflare check, the login).
_SCROLL = r"""
(function () {
  var dir = __DIR__;
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
  best.scrollTop = before + dir * Math.max(400, best.clientHeight * 0.85);
  if (best !== document.scrollingElement) window.scrollBy(0, dir * Math.max(400, window.innerHeight * 0.85));
  return JSON.stringify({top: best.scrollTop, height: best.scrollHeight, client: best.clientHeight,
                         moved: best.scrollTop !== before, url: location.href, title: document.title,
                         captured: (window.__pbCaptured || []).length, hooked: !!window.__pbHooked});
})()
"""


def scroll_js(direction: int = 1) -> str:
    return _SCROLL.replace("__DIR__", "-1" if direction < 0 else "1")


SCROLL_JS = scroll_js(1)

# What the page shows now: full-size pictures that aren't blurred (nor avatars, banners, logos — small, very wide,
# in the page's header, or named so), and videos — with the creator and time of the post card around each. A
# video playing from a stream (a blob: address) is only counted: its address isn't on the page.
DOM_JS = r"""
(function () {
  var out = [], streamed = 0;
  function abs(u) { try { return new URL(u, location.href).href; } catch (e) { return ''; } }
  function blurred(el) {
    for (var n = el, i = 0; n && n.nodeType === 1 && i < 7; n = n.parentElement, i++) {
      var cs = getComputedStyle(n);
      if (String(cs.filter || '').indexOf('blur') >= 0 || String(cs.backdropFilter || '').indexOf('blur') >= 0) return true;
    }
    return false;
  }
  function words(el) {
    var s = '';
    for (var n = el, i = 0; n && n.nodeType === 1 && i < 3; n = n.parentElement, i++) {
      var c = n.getAttribute('class') || '';
      s += ' ' + c + ' ' + (n.id || '') + ' ' + (n.getAttribute('alt') || '') + ' ' + (n.getAttribute('aria-label') || '');
    }
    return s.toLowerCase();
  }
  function card(el) {
    var creator = '', date = '';
    for (var n = el.parentElement, i = 0; n && i < 12; n = n.parentElement, i++) {
      if (!creator) { var a = n.querySelector('a[href^="/@"], a[href*="fanfix.io/@"]'); if (a) creator = abs(a.getAttribute('href')); }
      if (!date) { var t = n.querySelector('time[datetime]'); if (t) date = t.getAttribute('datetime'); }
      if (creator && date) break;
    }
    return {creator: creator, date: date};
  }
  function largest(im) {
    var best = im.currentSrc || im.src || '', bw = 0;
    String(im.getAttribute('srcset') || '').split(',').forEach(function (part) {
      var bits = part.trim().split(/\s+/);
      if (bits.length >= 2 && /w$/.test(bits[1])) { var w = parseInt(bits[1], 10); if (w > bw) { bw = w; best = bits[0]; } }
    });
    return abs(best);
  }
  var NOT = /avatar|profile-pic|profilepic|banner|cover|logo|icon|emoji|sticker|badge|header/;
  // thumbnails, blurred teasers, and Fanfix's people's own pictures (static.fanfix.io/Public/<user>/…)
  var NOT_SRC = /[_\-.](thumbnail|thumb|blurred|blur|preview|poster)\.[a-z0-9]+(\?|$)|\/\/static\.fanfix\.io\/Public\//i;
  var imgs = document.querySelectorAll('img');
  for (var i = 0; i < imgs.length; i++) {
    var im = imgs[i], src = largest(im), w = im.naturalWidth, h = im.naturalHeight;
    if (!/^https?:/.test(src) || w < 320 || h < 320 || w > h * 2.5 || NOT_SRC.test(src)) continue;
    if (im.closest('header, nav, footer, a[href^="/@"], a[href*="fanfix.io/@"]') || NOT.test(words(im))) continue;
    var c = card(im);
    out.push({src: src, w: w, h: h, video: false, blurred: blurred(im), creator: c.creator, date: c.date});
  }
  var vids = document.querySelectorAll('video');
  for (var j = 0; j < vids.length; j++) {
    var v = vids[j], s = v.currentSrc || v.src || '';
    if (!s) { var so = v.querySelector('source[src]'); if (so) s = so.src; }
    if (/^blob:/.test(s)) { streamed++; continue; }
    if (!/^https?:/.test(s)) continue;
    var cv = card(v);
    out.push({src: abs(s), w: v.videoWidth || 0, h: v.videoHeight || 0, video: true, blurred: blurred(v),
              creator: cv.creator, date: cv.date});
  }
  return JSON.stringify({media: out, streamed: streamed});
})()
"""


# ----------------------------------------------------------------------------- the JSON in an answer

_FS_TYPES = {"stringValue", "integerValue", "doubleValue", "booleanValue", "timestampValue", "nullValue",
             "mapValue", "arrayValue", "referenceValue", "geoPointValue", "bytesValue"}


def plain(node, depth: int = 0):
    """Firestore's typed values made plain ({"stringValue": "x"} → "x", {"mapValue": {"fields": …}} → a dict…),
    and a stored document made a dict of its fields with its id and creation time."""
    if depth > 80:
        return node
    if isinstance(node, list):
        return [plain(x, depth + 1) for x in node]
    if not isinstance(node, dict):
        return node
    if len(node) == 1:
        (k, v), = node.items()
        if k in _FS_TYPES:
            if k == "mapValue":
                return plain(v.get("fields", {}) if isinstance(v, dict) else {}, depth + 1)
            if k == "arrayValue":
                return [plain(x, depth + 1) for x in (v.get("values", []) if isinstance(v, dict) else [])]
            if k == "integerValue":
                try:
                    return int(v)
                except (TypeError, ValueError):
                    return v
            return None if k == "nullValue" else v
    if isinstance(node.get("fields"), dict) and isinstance(node.get("name"), str) and "/documents/" in node["name"]:
        doc = plain(node["fields"], depth + 1)
        if isinstance(doc, dict):
            doc.setdefault("id", node["name"].rsplit("/", 1)[-1])
            if node.get("createTime"):
                doc.setdefault("createdAt", node["createTime"])
        return doc
    return {k: plain(v, depth + 1) for k, v in node.items()}


# Where a JSON value can start in an answer that isn't one: a line's start, after a React Server Components row id
# ("4:", "1:I", "2:HL").
_ROW = re.compile(r"(?m)^(?:[0-9a-fA-F]{1,8}:[A-Z]{0,2})?(?=[\[{])")


def documents(text: str) -> list:
    """The JSON in one answer: the answer itself when it's JSON, else each JSON value in it — the rows of a React
    Server Components stream ("4:["$","div",…]", "0:{…}"), length-prefixed chunks, one value per line. Firestore's
    typed values come back plain."""
    s = (text or "").lstrip()
    if s.startswith(")]}'"):
        s = s.split("\n", 1)[1] if "\n" in s else ""
    out: list = []
    try:
        out = [json.loads(s)]
    except (ValueError, RecursionError):
        dec, end, tries = json.JSONDecoder(), 0, 0
        for m in _ROW.finditer(s):
            if m.end() < end:
                continue
            tries += 1
            if tries > 20000:
                break
            try:
                value, end = dec.raw_decode(s, m.end())
            except (ValueError, RecursionError):
                continue
            if isinstance(value, (dict, list)):
                out.append(value)
    if "stringValue" in s or "mapValue" in s:
        out = [plain(d) for d in out]
    return out


# ----------------------------------------------------------------------------- picking media out of JSON

@dataclass
class Found:
    """One photo or video to save."""
    key: str                         # what the file is named by (the media id, else the address)
    url: str
    video: bool
    ext: str                         # "jpg", "mp4", "m3u8"…
    post: str = ""
    date: float = 0
    caption: str = ""
    creator: str = ""
    score: float = 0                 # how good this address is (a better one for the same key replaces it)
    shown: bool = False              # taken from what the page showed, not from its data

    @property
    def stream(self) -> bool:
        return self.ext in STREAM_EXT


_IDLIKE = re.compile(r"^(?:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|[0-9a-f]{16,}|\d{8,}|"
                     r"[A-Za-z0-9_-]{20,})$", re.I)
_UUID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", re.I)
_NOT_CONTENT = re.compile(r"(?:^|[_\-.])(thumbnail|thumb|blurred|blur|preview|poster)(?:$|[_\-.])", re.I)
DRM_SYSTEMS = {"fairplay", "widevine", "playready"}


def is_profile_picture(url: str) -> bool:
    """Fanfix keeps people's own pictures (avatars, banners) under static.fanfix.io/Public/<user id>/…; what they
    post is on images.fanfix.io."""
    p = urlsplit(url or "")
    return (p.hostname or "").lower() == f"static.{DOMAIN}" and p.path.startswith("/Public/")


def not_content(url: str) -> bool:
    """A thumbnail, blurred teaser or poster, by its file name ("…_thumbnail.jpg", "…_blurred.jpg")."""
    stem = urlsplit(unwrap(url) or "").path.rsplit("/", 1)[-1].rsplit(".", 1)[0]
    return bool(_NOT_CONTENT.search(stem))


def clean_text(text: str) -> str:
    """A caption as plain text: Fanfix's messages are HTML ("<p><strong>…</strong></p>")."""
    import html
    t = re.sub(r"<\s*br\s*/?>|</p>\s*<p[^>]*>", "\n", text or "", flags=re.I)
    t = html.unescape(re.sub(r"<[^>]+>", "", t))
    return re.sub(r"[ \t]+", " ", t).strip()[:2000]


@dataclass
class Haul:
    """What `extract` (and `from_page`) found, and what they left out."""
    found: dict[str, Found] = field(default_factory=dict)
    locked: int = 0                  # media of posts not bought (teasers, blurred previews)
    profile: int = 0                 # avatars, banners and the like
    unresolved: set[str] = field(default_factory=set)        # videos named with only a poster
    creators: dict[str, int] = field(default_factory=dict)   # handles seen on posts, how often
    seen: set[str] = field(default_factory=set)              # every media address the data named (`tokens`)
    assets: int = 0                  # Fanfix asset objects read (`_take_asset`)
    drm: set[str] = field(default_factory=set)               # bought, but given only as a DRM-protected stream
    removed: int = 0                 # taken down by Fanfix's moderation
    own: int = 0                     # sent by this account itself (a fan's own uploads in a chat)
    other: int = 0                   # audio (voice notes) and thumbnails-only — not photos or videos
    channels: dict[str, str] = field(default_factory=dict)   # the chats in the Messages list: id → creator
    older: bool | None = None        # a chat: more history above what's loaded (None: not said)
    avatar_keys: set[str] = field(default_factory=set)       # names an earlier version gave people's pictures

    def add(self, f: Found) -> bool:
        """Keeps `f` (or the better of it and one already kept under its key). True when it's new."""
        self.seen |= tokens(f.url) | ({f.key.lower()} if _IDLIKE.match(f.key) else set())
        old = self.found.get(f.key)
        if old is None:
            self.found[f.key] = f
            self.unresolved.discard(f.key)
            return True
        if f.score > old.score:
            for k in ("post", "date", "caption", "creator"):
                if not getattr(f, k) and getattr(old, k):
                    setattr(f, k, getattr(old, k))
            self.found[f.key] = f
        return False

    def note(self, url: str) -> None:
        self.seen |= tokens(url)

    def knows(self, url: str) -> bool:
        """Whether the data already named this picture — by its address, or by the media id in it."""
        return bool(tokens(url) & self.seen)


_ID_KEYS = ("id", "uuid", "mediaId", "media_id", "mediaUuid", "_id", "fileId", "assetId", "contentId", "postId")
_DATE_KEYS = ("createdAt", "created_at", "publishedAt", "published_at", "postedAt", "posted_at", "sentAt", "sent_at",
              "releasedAt", "scheduledAt", "date", "timestamp", "created", "time", "createTime")
_TEXT_KEYS = ("caption", "text", "body", "description", "content", "message", "title")
_HANDLE_KEYS = ("username", "handle", "userName", "user_name", "creatorUsername", "creator_username", "slug",
                "screenName", "screen_name", "vanity")
_PERSON_KEYS = ("creator", "user", "author", "owner", "sender", "account", "profile", "createdBy", "postedBy", "from")
_TYPE_KEYS = ("type", "mediaType", "media_type", "kind", "mimeType", "mime_type", "contentType", "content_type",
              "fileType", "file_type", "format", "mimetype")
# What a post or media object says about this account's access (`_access`).
_LOCK_FLAGS = ("isLocked", "locked", "is_locked", "isBlurred", "blurred", "is_blurred", "isPaywalled", "paywalled",
               "needsPurchase", "requiresPurchase", "requires_purchase", "isTeaser", "teaser")
_NO_ACCESS = ("hasAccess", "has_access", "canView", "can_view", "canAccess", "can_access", "isAccessible",
              "accessible", "viewable", "isViewable", "canViewMedia", "can_view_media")
_BOUGHT = ("isPurchased", "is_purchased", "purchased", "isUnlocked", "is_unlocked", "unlocked", "isBought", "bought",
           "hasPurchased", "has_purchased", "isOpened", "is_opened")
_OPEN = _NO_ACCESS + _BOUGHT
_PRICE_KEYS = ("unlockPriceInCents", "price", "priceInCents", "price_in_cents", "priceCents", "price_cents",
               "unlockPrice", "ppvPrice", "amount", "cost")
_UNLOCKED_AT = ("unlockedAt", "unlocked_at", "purchasedAt", "purchased_at")   # Fanfix: set once it's bought
_MEDIA_LISTS = ("media", "medias", "attachments", "assets", "images", "videos", "photos", "items", "contents",
                "mediaItems", "media_items", "files")

_GOOD = {"original", "orig", "source", "full", "fullsize", "hd", "raw", "master", "max", "download", "large", "big",
         "high", "highres", "uhd", "fhd"}
_OK = {"url", "src", "file", "path", "location", "video", "image", "photo", "picture", "media", "link", "href",
       "hls", "stream", "playback", "mp4", "signed", "public"}
_BAD = {"thumb", "thumbnail", "thumbnails", "small", "preview", "poster", "blur", "blurred", "low", "lowres",
        "medium", "sm", "md", "xs", "tiny", "mini", "placeholder", "teaser", "sample", "snapshot", "still", "frame",
        "sprite", "lqip", "watermark", "watermarked", "gif"}
_TEASER = {"blur", "blurred", "teaser", "placeholder", "preview", "lqip"}
_PROFILE = {"avatar", "avatars", "banner", "header", "background", "icon", "logo", "emoji", "sticker", "badge",
            "flag", "favicon", "og", "cover", "headshot"}
_URLISH = {"url", "src", "href", "file", "path", "location", "uri", "link", "signed", "download", "source",
           "original", "full", "playback", "hls", "dash", "stream", "mp4"}
_PAGE_EXT = {"html", "htm", "php", "aspx", "js", "css", "json"}


def _words(key) -> list[str]:
    """A key's words: "thumbnailUrl" → ["thumbnail", "url"], "signed_url_lg" → ["signed", "url", "lg"]."""
    return [w.lower() for w in re.findall(r"[A-Z]?[a-z]+|[A-Z]+(?![a-z])|\d+", str(key))]


def ext_of(url: str) -> str:
    path = urlsplit(url).path
    last = path.rsplit("/", 1)[-1]
    return last.rsplit(".", 1)[-1].lower() if "." in last else ""


def unwrap(url: str) -> str:
    """The picture behind a resizing address: Next.js's /_next/image?url=…&w=…, Cloudflare's
    /cdn-cgi/image/<options>/<address>. Any other address as it is."""
    if not isinstance(url, str) or "/_next/image" not in url and "/cdn-cgi/image/" not in url:
        return url
    p = urlsplit(url)
    base = f"{p.scheme}://{p.netloc}/"
    if p.path.endswith("/_next/image"):
        inner = parse_qs(p.query).get("url", [""])[0]
        return urljoin(base, inner) if inner else url
    i = p.path.find("/cdn-cgi/image/")
    if i >= 0:
        rest = p.path[i + len("/cdn-cgi/image/"):].split("/", 1)
        if len(rest) == 2 and rest[1]:
            inner = re.sub(r"^(https?):/+", r"\1://", rest[1])
            return urljoin(base, inner) + (f"?{p.query}" if p.query else "")
    return url


def is_media_url(s) -> bool:
    if not isinstance(s, str) or not s.startswith(("http://", "https://")) or len(s) > 4000:
        return False
    return ext_of(unwrap(s)) in IMAGE_EXT | VIDEO_EXT | STREAM_EXT


def _bare_address(k: str, v) -> bool:
    """An address with no media extension that's still the media's — under a url/src-like key of a dict whose
    type says image or video (Cloudflare Images, signed storage links…)."""
    return (isinstance(v, str) and v.startswith(("http://", "https://")) and len(v) <= 4000
            and bool(set(_words(k)) & _URLISH) and ext_of(v) not in _PAGE_EXT)


def stable_key(url: str) -> str:
    """A name for media with no id: its address without the query (where the signature and expiry live)."""
    p = urlsplit(unwrap(url))
    return "u" + hashlib.sha1(urlunsplit((p.scheme, p.netloc, p.path, "", "")).encode("utf-8")).hexdigest()[:16]


def tokens(url: str) -> set[str]:
    """What tells one picture from another in its address: the address without its query, and its media id — the
    last UUID in its path ("…/1f0c…-…_thumbnail.jpg" and "…/1f0c…-…_original.heic" are the same picture), else the
    last id-like part of the path ("/m/1f0c…/1080.jpg" → "1f0c…") — so another size of the same picture is known."""
    p = urlsplit(unwrap(url) or "")
    out = {urlunsplit((p.scheme, p.netloc.lower(), p.path, "", ""))}
    ids = _UUID.findall(p.path)
    if ids:
        out.add(ids[-1].lower())
        return out
    for seg in reversed([x for x in p.path.split("/") if x]):
        stem = seg.rsplit(".", 1)[0]
        if _IDLIKE.match(stem):
            out.add(stem.lower())
            break
    return out


def _as_id(v) -> str:
    if isinstance(v, bool) or v is None:
        return ""
    if isinstance(v, (int, float)) and math.isfinite(v):
        return str(int(v))
    if isinstance(v, str) and 0 < len(v) <= 80 and not v.startswith(("http://", "https://")):
        return re.sub(r"[^A-Za-z0-9_-]", "", v)[:64]
    return ""


def when(v) -> float:
    """A date as unix time: ISO 8601 text, seconds / milliseconds since 1970, or a {seconds: …} timestamp. 0 when
    it isn't one."""
    t = 0.0
    if isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v):
        t = float(v) / 1000 if v > 1e12 else float(v)
    elif isinstance(v, dict) and isinstance(v.get("seconds", v.get("_seconds")), (int, float)):
        t = float(v.get("seconds", v.get("_seconds")))
    elif isinstance(v, str) and len(v) >= 8:
        s = v.strip()
        if s.isdigit():
            return when(int(s))
        try:
            d = datetime.datetime.fromisoformat(re.sub(r"(\.\d{6})\d+", r"\1", s.replace("Z", "+00:00")))
            if d.tzinfo is None:
                d = d.replace(tzinfo=datetime.timezone.utc)
            t = d.timestamp()
        except ValueError:
            return 0.0
    return t if social.MIN_DATE <= t <= 4_102_444_800 else 0.0


def _handle_of(d: dict) -> str:
    for k in _HANDLE_KEYS:
        v = d.get(k)
        if isinstance(v, str) and 0 < len(v) <= 60 and re.fullmatch(r"@?[A-Za-z0-9_.\-]+", v):
            return v.lstrip("@")
    return ""


def _user_like(d: dict) -> bool:
    """A creator's or fan's own object (a handle, no media of a post)."""
    return bool(_handle_of(d)) and not any(k in d for k in _MEDIA_LISTS) and not any(k in d for k in ("caption", "postId"))


def _access(d: dict) -> bool | None:
    """What a dict says about this account's access: True (bought, unlocked, viewable), False (locked, blurred,
    no access, or not bought with a price on it), None (nothing). Bought beats locked — a pay-per-view post can
    stay "locked" once it's bought. "Not bought" with no price means nothing: every subscription post says it."""
    if any(d.get(k) is True for k in _OPEN) or any(isinstance(d.get(k), str) and d[k] for k in _UNLOCKED_AT):
        return True
    if any(d.get(k) is True for k in _LOCK_FLAGS) or any(d.get(k) is False for k in _NO_ACCESS) \
            or d.get("showAsset") is False:
        return False
    priced = any(isinstance(d.get(k), (int, float)) and not isinstance(d.get(k), bool) and d[k] > 0 for k in _PRICE_KEYS)
    if priced and (any(d.get(k) is False for k in _BOUGHT) or any(k in d and not d[k] for k in _UNLOCKED_AT)):
        return False                         # a price on it, and not bought (Fanfix: unlockedAt still null)
    return None


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
    profile: bool = False            # inside a user object's avatar / banner, or a link to someone's profile
    viewer: str = ""                 # this account's user id (a chat's props say it)
    sender: str = ""                 # who sent the message the media is in
    element: bool = False            # inside a React element's props (layout: only objects with an id or type count)


def _post_ctx(d: dict, ctx: _Ctx) -> _Ctx:
    """The context below a dict: a post's id, date, caption and creator taken over; open or locked as it says."""
    a = _access(d)
    out = _Ctx(ctx.post, ctx.date, ctx.caption, ctx.creator, ctx.locked if a is None else not a, ctx.profile,
               ctx.viewer, ctx.sender, ctx.element)
    href = d.get("href")
    if isinstance(href, str) and (href.startswith("/@") or "fanfix.io/@" in href):
        out.profile = True                               # a link to someone's profile: its picture is theirs
    if isinstance(d.get("viewerUserId"), str):
        out.viewer = d["viewerUserId"]
    partner = d.get("partnerUsername")                   # a Fanfix chat: whose it is
    if isinstance(partner, str) and re.fullmatch(r"@?[A-Za-z0-9_.\-]{1,60}", partner):
        out.creator = partner.lstrip("@")
    date = next((when(d[k]) for k in _DATE_KEYS if k in d and when(d[k])), 0.0)
    text = next((d[k] for k in _TEXT_KEYS if isinstance(d.get(k), str) and d[k].strip()
                 and not d[k].startswith(("http://", "https://", "$"))), "")
    posty = bool(date or text or any(isinstance(d.get(k), list) for k in _MEDIA_LISTS)
                 or isinstance(d.get("messageAssets"), list))
    if posty and not _user_like(d):
        pid = next((_as_id(d[k]) for k in ("postId", "post_id", "id", "uuid", "_id") if _as_id(d.get(k))), "")
        if pid:
            out.post = pid
        if date:
            out.date = date
        out.caption = clean_text(text) if text else ("" if pid else out.caption)
        if isinstance(d.get("senderUserId"), str):
            out.sender = d["senderUserId"]
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


# ----------------------------------------------------------------------------- Fanfix's own media objects

def _is_asset(d) -> bool:
    """Fanfix's media object — `{id, type, mimeType, name, sourceUrl, thumbnailUrl, durationInSeconds,
    removedByModeration, manifests: {fairplay: {url}, widevine: {url}}}` — wrapped in a message's or post's list
    as `{id, order, showAsset, asset}`."""
    return (isinstance(d, dict) and isinstance(d.get("type"), str)
            and ("sourceUrl" in d or "manifests" in d) and ("mimeType" in d or "thumbnailUrl" in d))


def _ext_for(mime, video: bool) -> str:
    m = str(mime or "").lower()
    for key, ext in (("heic", "heic"), ("heif", "heic"), ("png", "png"), ("gif", "gif"), ("webp", "webp"),
                     ("quicktime", "mov"), ("mp4", "mp4"), ("jpeg", "jpg"), ("jpg", "jpg")):
        if key in m:
            return ext
    return "mp4" if video else "jpg"


def _take_asset(asset: dict, wrapper: dict | None, ctx: _Ctx, haul: Haul) -> None:
    """One Fanfix asset, by Fanfix's rules (checked on a real chat, Nov 8):
    - a free message's or post's photo carries its original in `sourceUrl` ("…_original.heic"/".jpg") — taken;
    - a bought pay-per-view's photos *and* videos come with an empty `sourceUrl` and only FairPlay/Widevine
      manifests — DRM-protected: counted (`drm`), never downloaded;
    - not bought: `showAsset: false` and a "…_blurred.jpg" — counted as locked;
    - taken down by moderation, the account's own uploads, and audio — left out."""
    haul.assets += 1
    aid = _as_id(asset.get("id")) or _as_id((wrapper or {}).get("id"))
    src = asset.get("sourceUrl") if isinstance(asset.get("sourceUrl"), str) else ""
    thumb = asset.get("thumbnailUrl") if isinstance(asset.get("thumbnailUrl"), str) else ""
    for u in (src, thumb):
        if u.startswith(("http://", "https://")):
            haul.note(u)
    if asset.get("removedByModeration"):
        haul.removed += 1
        return
    if ctx.viewer and ctx.sender and ctx.sender == ctx.viewer:
        haul.own += 1
        return
    a = _access(wrapper) if wrapper else None
    if (ctx.locked if a is None else not a) or (src and "blur" in src.lower()):
        haul.locked += 1
        return
    kind = asset.get("type", "").lower()
    if kind.startswith("audio"):
        haul.other += 1
        return
    video = kind.startswith("video")
    if not src.startswith(("http://", "https://")):
        manifests = asset.get("manifests") if isinstance(asset.get("manifests"), dict) else {}
        plain = [m.get("url") for k, m in manifests.items() if str(k).lower() not in DRM_SYSTEMS
                 and isinstance(m, dict) and isinstance(m.get("url"), str) and m["url"].startswith("http")]
        if plain and video:
            src = plain[0]                                    # an unprotected stream (checked again when fetched)
        elif manifests:
            haul.drm.add(aid or thumb)
            return
        else:
            if video:
                haul.unresolved.add(aid)
            else:
                haul.locked += 1
            return
    if not_content(src):
        haul.other += 1
        return
    ext = ext_of(src) if ext_of(src) in IMAGE_EXT | VIDEO_EXT | STREAM_EXT else _ext_for(asset.get("mimeType"), video)
    date = when(asset.get("createdAt") or "") or ctx.date
    haul.add(Found(aid or stable_key(src), src, video, ext, ctx.post, date, ctx.caption, ctx.creator, 10.0))
    if ctx.creator:
        haul.creators[ctx.creator] = haul.creators.get(ctx.creator, 0) + 1


def _note_fanfix(d: dict, haul: Haul, ctx: _Ctx) -> None:
    """What a Fanfix dict says beside its media: the chats in the Messages list, whether a chat has older messages
    to load, and people's pictures (whose names an earlier version saved them under — `avatar_keys`)."""
    chans = d.get("messageChannels")
    if isinstance(chans, list):
        for ch in chans:
            if isinstance(ch, dict) and _as_id(ch.get("id")):
                name = ch.get("name") if isinstance(ch.get("name"), str) else ""
                haul.channels.setdefault(ch["id"], name.lstrip("@"))
                haul.avatar_keys.add(_as_id(ch["id"]))
    if isinstance(d.get("initialHasMoreOlder"), bool):
        haul.older = d["initialHasMoreOlder"]
    if isinstance(d.get("messages"), list) and d["messages"] and isinstance(d.get("hasMore"), bool):
        haul.older = d["hasMore"]                            # a page of older messages: more above it or not
    for k, v in d.items():
        if isinstance(v, str) and v.startswith(("http://", "https://")) and is_media_url(v) and (
                ctx.profile or is_profile_picture(v) or "avatar" in k.lower()
                or (k == "imageUrl" and ("ownerId" in d or "lastMessage" in d))):
            haul.avatar_keys.add(stable_key(v))
            haul.profile += 1


def _fanfix_walk(node, ctx: _Ctx, haul: Haul, depth: int = 0) -> None:
    if depth > 120:
        return
    if isinstance(node, dict):
        if _is_asset(node):
            _take_asset(node, None, ctx, haul)
            return
        here = _post_ctx(node, ctx)
        _note_fanfix(node, haul, here)
        if _is_asset(node.get("asset")):
            _take_asset(node["asset"], node, here, haul)
            return
        for v in node.values():
            if isinstance(v, (dict, list)):
                _fanfix_walk(v, here, haul, depth + 1)
    elif isinstance(node, list):
        for x in node:
            if isinstance(x, (dict, list)):
                _fanfix_walk(x, ctx, haul, depth + 1)


# ----------------------------------------------------------------------------- any other shape

def _addresses(d: dict, typed: bool = False, depth: int = 0, via: tuple = ()) -> list[tuple[tuple, str, int]]:
    """Media addresses in a dict and its variants (dicts and lists of dicts, two levels down): (the keys on the
    way, the address, its width or 0). `typed`: the dict's type says image/video, so an address with no media
    extension under a url-like key counts too."""
    out = []
    width = 0
    for k in ("width", "w", "originalWidth"):
        if isinstance(d.get(k), (int, float)) and not isinstance(d.get(k), bool):
            width = int(d[k])
            break
    label = next((str(d[k]) for k in ("size", "quality", "label", "name", "variant", "resolution")
                  if isinstance(d.get(k), (str, int)) and not isinstance(d.get(k), bool)), "")
    for k, v in d.items():
        if is_media_url(v) or (typed and _bare_address(k, v)):
            out.append((via + (k, label), unwrap(v), width))
        elif depth < 2 and isinstance(v, dict):
            out += _addresses(v, typed, depth + 1, via + (k,))
        elif depth < 2 and isinstance(v, list):
            for x in v[:40]:
                if isinstance(x, dict):
                    out += _addresses(x, typed, depth + 1, via + (k,))
                elif is_media_url(x):
                    out.append((via + (k,), unwrap(x), 0))
    return out


def _score(keys: tuple, url: str, width: int, video: bool) -> float:
    words = set()
    for k in keys:
        words.update(_words(k))
    s = 0.0
    s += 3 * len(words & _GOOD) + 1 * min(1, len(words & _OK)) - 4 * len(words & _BAD)
    e = ext_of(url)
    if video:
        if e in VIDEO_EXT:
            s += 20
        elif e in STREAM_EXT:
            s += 10 if e == "m3u8" else 5
        elif not e and words & {"video", "playback", "mp4", "hls", "stream", "src", "url", "file"}:
            s += 8                           # no extension, under a video-ish key: the server says what it is
        else:
            s -= 50                          # a picture: the video's poster
    elif e and e not in IMAGE_EXT:
        s -= 50
    if "blur" in url.lower() or not_content(url):
        s -= 8
    return s + min(width, 8000) / 1000


_VARIANT_LISTS = {"variants", "sources", "sizes", "renditions", "versions", "formats", "qualities", "resolutions"}


def _container(d: dict) -> bool:
    """A dict that holds a list of other objects (a page of posts, a chat's messages, a React element's children)
    is never itself one photo, whatever picture sits on it (a chat's partnerAvatarUrl hid every message once)."""
    return any(isinstance(v, list) and any(isinstance(x, (dict, list)) for x in v[:8]) and k not in _VARIANT_LISTS
               for k, v in d.items()) or "children" in d


def _media(d: dict, ctx: _Ctx, haul: Haul) -> bool:
    """`d` as one media object, when it is one: added to the haul (or counted as left out). True when `d`
    was taken as media — its variants aren't then looked at again as media of their own."""
    direct = [k for k, v in d.items() if is_media_url(v)]
    kind = _type_of(d)
    if ctx.element and not kind and not any(_as_id(d.get(k)) for k in _ID_KEYS[:9]):
        return False                         # a layout prop ({"src": …} of an avatar, an icon): not a post's media
    if _container(d):
        for k in direct:                                  # its pictures are someone's avatar, at most
            haul.note(d[k])
        return False
    if not direct and not kind:
        # an id with variants under it that carry no ids of their own: one media object in several sizes
        if not any(_as_id(d.get(k)) for k in _ID_KEYS[:9]):
            return False
        subs = [v for v in d.values() if isinstance(v, (dict, list))]
        if not subs or any(isinstance(x, dict) and any(_as_id(x.get(k)) for k in _ID_KEYS[:9])
                           for v in subs for x in (v if isinstance(v, list) else [v])):
            return False
    found = _addresses(d, typed=bool(kind))
    if not found:
        return False
    for _k, u, _w in found:
        haul.note(u)
    video = kind == "video" or (kind != "image" and any(ext_of(u) in VIDEO_EXT | STREAM_EXT for _k, u, _w in found))
    channel = "imageUrl" in d and ("ownerId" in d or "lastMessage" in d)        # a chat in the Messages list
    if ctx.profile or _user_like(d) or channel or (any(set(_words(k)) & _PROFILE for k in direct) and not video) \
            or all(is_profile_picture(u) for _k, u, _w in found):
        haul.profile += 1
        for _k, u, _w in found:
            haul.avatar_keys.add(stable_key(u))
        return True
    a = _access(d)
    if ctx.locked if a is None else not a:
        haul.locked += 1
        return True
    best = max(found, key=lambda f: _score(f[0], f[1], f[2], video))
    keys, url, width = best
    score = _score(keys, url, width, video)
    mid = next((_as_id(d[k]) for k in _ID_KEYS[:9] if _as_id(d.get(k))), "")
    if score < -20:
        # a video named with only its poster: its address comes when it's played (the page may still show it)
        if video:
            haul.unresolved.add(mid or stable_key(url))
        return True
    words = set()
    for k in keys:
        words.update(_words(k))
    if words & _TEASER or "blur" in url.lower():
        haul.locked += 1                     # only a teaser is there: a post not bought
        return True
    if not_content(url) or is_profile_picture(url):
        haul.other += 1                      # only a thumbnail is there: not the photo itself
        return True
    key = mid or stable_key(url)
    date = next((when(d[k]) for k in _DATE_KEYS if k in d and when(d[k])), 0.0) or ctx.date
    ext = ext_of(url) or ("mp4" if video else "jpg")
    haul.add(Found(key, url, video, ext, ctx.post, date, ctx.caption, ctx.creator, score))
    if ctx.creator:
        haul.creators[ctx.creator] = haul.creators.get(ctx.creator, 0) + 1
    return True


def _element(node) -> bool:
    """A React element in a Server Components stream: ["$", type, key, props]. Its props are mostly layout —
    avatars in profile links, icons — so inside them the shape-guessing walk takes only objects with an id or a
    media type (`_Ctx.element`); Fanfix's own media objects are found by `_fanfix_walk` either way."""
    return isinstance(node, list) and len(node) >= 3 and node[0] == "$" and isinstance(node[1], str)


def _walk(node, ctx: _Ctx, haul: Haul, key: str = "", depth: int = 0) -> None:
    if depth > 60:
        return
    if isinstance(node, dict):
        here = _post_ctx(node, ctx)
        if _user_like(node):                 # a user object's own pictures are its avatar, banner…
            for k, v in node.items():         # …and posts under a creator's object are that creator's
                if isinstance(v, (dict, list)):
                    sub = _Ctx(here.post, here.date, here.caption, here.creator or _handle_of(node), here.locked,
                               here.profile or bool(set(_words(k)) & (_PROFILE | {"profile", "picture", "photo", "image"})),
                               here.viewer, here.sender, here.element)
                    _walk(v, sub, haul, k, depth + 1)
                elif is_media_url(v):
                    haul.profile += 1
                    haul.note(v)
                    haul.avatar_keys.add(stable_key(v))
            return
        if set(_words(key)) & _PROFILE:
            here.profile = True
        if _media(node, here, haul):
            return
        for k, v in node.items():
            if isinstance(v, (dict, list)):
                _walk(v, here, haul, k, depth + 1)
    elif isinstance(node, list):
        if _element(node) and not ctx.element:
            ctx = _Ctx(ctx.post, ctx.date, ctx.caption, ctx.creator, ctx.locked, ctx.profile, ctx.viewer, ctx.sender,
                       True)
        for x in node:
            if isinstance(x, (dict, list)):
                _walk(x, ctx, haul, key, depth + 1)


def extract(doc, haul: Haul | None = None) -> Haul:
    """The photos and videos named in one JSON value (parsed), added to `haul`: by Fanfix's own media objects
    (`_fanfix_walk`) — and, only where there are none, by guessing from the shape (`_walk`)."""
    haul = haul if haul is not None else Haul()
    before = haul.assets
    _fanfix_walk(doc, _Ctx(), haul)
    if haul.assets == before:
        _walk(doc, _Ctx(), haul)
    return haul


def extract_text(text: str, haul: Haul | None = None) -> Haul:
    """The photos and videos named in one answer the page received, whatever its shape (`documents`)."""
    haul = haul if haul is not None else Haul()
    for doc in documents(text):
        extract(doc, haul)
    return haul


def from_page(shown: list[dict], haul: Haul, hint: str = "") -> list[Found]:
    """What the page showed (`DOM_JS`) that its data didn't name — not blurred, not a thumbnail or anyone's own
    picture, not known to the haul by address or media id — added to the haul under its address. Returns the new
    ones."""
    out = []
    for m in shown:
        url = unwrap(m.get("src") or "")
        if not url.startswith(("http://", "https://")) or m.get("blurred") or "blur" in url.lower():
            continue
        if haul.knows(url) or not_content(url) or is_profile_picture(url):
            continue
        video = bool(m.get("video"))
        ext = ext_of(url)
        if ext and ext not in (VIDEO_EXT | STREAM_EXT if video else IMAGE_EXT):
            continue
        creator = creator_from_url(m.get("creator") or "") or hint
        f = Found(stable_key(url), url, video, ext or ("mp4" if video else "jpg"), date=when(m.get("date") or ""),
                  creator=creator, score=int(m.get("w") or 0) / 1000, shown=True)
        if haul.add(f):
            out.append(f)
    return out


# ----------------------------------------------------------------------------- creators and folders

def creator_from_url(url: str) -> str:
    """The creator a Fanfix page is for: app.fanfix.io/@<handle>[/…] (or /<handle>); "" for any other page."""
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
    """"@jane", "app.fanfix.io/@jane", "https://fanfix.io/jane?x=1" → "jane"."""
    t = (text or "").strip()
    if "fanfix.io" in t or t.startswith(HOME):
        return creator_from_url(t if "://" in t else "https://" + t)
    return t.lstrip("@").split("/")[0].split("?")[0].strip()


def profile_url(handle: str) -> str:
    """A creator's page: app.fanfix.io/@<handle>."""
    return HOME + "@" + handle.lstrip("@")


def chat_id(url: str) -> str:
    """The chat a page is (app.fanfix.io/messages/<id>), else "" — its gallery and the list aren't."""
    p = urlsplit(url or "")
    parts = [x for x in p.path.split("/") if x]
    return parts[1] if len(parts) == 2 and parts[0] == "messages" and fanfix_host(url) else ""


def chats_page(url: str) -> bool:
    """The Messages list itself (app.fanfix.io/messages): Download goes through every chat in it."""
    p = urlsplit(url or "")
    return fanfix_host(url) and p.path.rstrip("/") == "/messages"


def chat_url(chat: str) -> str:
    return HOME + "messages/" + chat


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


# ----------------------------------------------------------------------------- what came down

def sniff(path: str) -> str:
    """What a downloaded file really is, by its first bytes: "jpeg", "png", "gif", "webp", "heic", "avif", "mp4",
    "webm", "m3u8", "mpd", "page" (HTML, JSON or other text — a login, a check or an error, not the file), or ""
    (something else)."""
    try:
        with open(path, "rb") as f:
            head = f.read(512)
    except OSError:
        return ""
    if head[:3] == b"\xff\xd8\xff":
        return "jpeg"
    if head[:8] == b"\x89PNG\r\n\x1a\n":
        return "png"
    if head[:4] == b"GIF8":
        return "gif"
    if head[:4] == b"RIFF" and head[8:12] == b"WEBP":
        return "webp"
    if head[4:8] == b"ftyp":
        brand = head[8:12]
        if brand in (b"heic", b"heix", b"mif1", b"msf1", b"heim", b"heis"):
            return "heic"
        return "avif" if brand in (b"avif", b"avis") else "mp4"
    if head[4:8] in (b"moov", b"mdat", b"free", b"wide", b"skip"):
        return "mp4"
    if head[:4] == b"\x1a\x45\xdf\xa3":
        return "webm"
    text = head.lstrip(b"\xef\xbb\xbf \t\r\n").lower()
    if text.startswith(b"#extm3u"):
        return "m3u8"
    if text.startswith(b"<mpd") or (text.startswith(b"<?xml") and b"<mpd" in text):
        return "mpd"
    if text[:1] in (b"<", b"{", b"[") or (head and all(32 <= c < 127 or c in (9, 10, 13) for c in head[:200])):
        return "page"
    return ""


_CONTAINERS = {b"moov", b"trak", b"mdia", b"minf", b"stbl", b"mvex", b"edts", b"dinf"}


def _boxes(data: bytes, start: int, end: int):
    """The MP4 boxes in data[start:end]: (type, body start, body end)."""
    pos = start
    while pos + 8 <= end:
        size, kind = struct.unpack(">I4s", data[pos:pos + 8])
        head = 8
        if size == 1 and pos + 16 <= end:
            size, head = struct.unpack(">Q", data[pos + 8:pos + 16])[0], 16
        elif size == 0:
            size = end - pos
        if size < head or pos + size > end:
            return
        yield kind, pos + head, pos + size
        pos += size


def _encrypted(data: bytes, start: int, end: int, depth: int = 0) -> bool:
    for kind, a, b in _boxes(data, start, end):
        if kind == b"pssh":
            return True
        if kind == b"stsd" and b - a >= 8:               # full box: version/flags, entry count, then the entries
            if any(entry in (b"encv", b"enca", b"encs", b"enct") for entry, _x, _y in _boxes(data, a + 8, b)):
                return True
        elif kind in _CONTAINERS and depth < 8 and _encrypted(data, a, b, depth + 1):
            return True
    return False


def mp4_protected(path: str) -> bool:
    """Whether an MP4/MOV file's tracks are encrypted (Common Encryption — Widevine, PlayReady, FairPlay): an
    `encv`/`enca` sample entry or a `pssh` box in its `moov`. Such a file plays only with a licence: not kept."""
    try:
        with open(path, "rb") as f:
            size = os.fstat(f.fileno()).st_size
            pos = 0
            for _ in range(256):
                if pos + 8 > size:
                    break
                f.seek(pos)
                head = f.read(16)
                n, kind = struct.unpack(">I4s", head[:8])
                hdr = 8
                if n == 1 and len(head) >= 16:
                    n, hdr = struct.unpack(">Q", head[8:16])[0], 16
                elif n == 0:
                    n = size - pos
                if n < hdr:
                    break
                if kind == b"moov":
                    f.seek(pos + hdr)
                    body = f.read(min(n - hdr, 200_000_000))
                    return _encrypted(body, 0, len(body))
                if kind == b"pssh":
                    return True
                pos += n
    except (OSError, struct.error):
        pass
    return False


def unwanted(path: str, video: bool) -> str:
    """Why a downloaded file isn't the photo or video (a web page, a DRM-protected video), or ""."""
    what = sniff(path)
    if what == "page":
        return "the server sent a web page, not the file (a login or Cloudflare page?)"
    if video and what == "mp4" and mp4_protected(path):
        return "protected by DRM — not downloaded"
    if not video and what in ("mp4", "webm", "m3u8", "mpd"):
        return "a video where a photo was expected"
    return ""


# ----------------------------------------------------------------------------- fetching

def fanfix_host(url: str) -> bool:
    host = (urlsplit(url).hostname or "").lower()
    return host == DOMAIN or host.endswith("." + DOMAIN)


def tries_for(url: str, ua: str, cookie: str) -> list[dict[str, str]]:
    """Headers to try: plainly first; with the person's Fanfix session only for Fanfix's own hosts."""
    plain_h = social.headers(REFERER, ua=ua)
    return [plain_h, social.headers(REFERER, cookie, ua)] if cookie and fanfix_host(url) else [plain_h]


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


def _is_manifest(text: str) -> bool:
    t = text.lstrip("﻿ \t\r\n")[:2000].upper()
    return t.startswith("#EXTM3U") or t.startswith("<MPD") or (t.startswith("<?XML") and "<MPD" in t)


def fetch_stream(item: social.Item, tmp: str, tries: list[dict[str, str]], manifest: str = "",
                 browser=None) -> tuple[str | None, str]:
    """An HLS or DASH video into the temp folder as one MP4 — unless it's DRM-protected (not downloaded). The
    playlist is read through the browser when there is one (`manifest` when it's already in hand)."""
    why, h = "no answer", tries[0]
    if not manifest and browser is not None:
        got, why = browser(item.url, tmp, "playlist.txt")
        if got:
            with open(got, "rb") as f:
                text = f.read(4_000_000).decode("utf-8", "replace")
            os.remove(got)
            manifest = text if _is_manifest(text) else ""
    if not manifest:
        for h in tries:
            try:
                text = _get_text(item.url, h)
            except Exception as e:  # noqa: BLE001 — any refusal: the next headers, else the reason
                why = str(e) or type(e).__name__
                continue
            if _is_manifest(text):
                manifest = text
                break
            why = "the server sent a web page, not the stream"
    if not manifest:
        return None, f"couldn't read the stream ({why})"
    if drm_in(manifest):
        return None, "protected by DRM — not downloaded"
    out = os.path.join(tmp, item.filename)
    if importlib.util.find_spec("yt_dlp") is not None:
        return _yt_dlp(item.url, h, tmp, out)
    if "<MPD" not in manifest[:2000].upper():
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


def _checked(path: str | None, why: str, item: social.Item) -> tuple[str | None, str]:
    """A download kept only when it's the photo or video (not a page, not DRM-protected)."""
    if not path:
        return None, why
    bad = unwanted(path, item.video)
    if bad:
        try:
            os.remove(path)
        except OSError:
            pass
        return None, bad
    return path, ""


def fetcher(ua: str, cookie: str, browser=None):
    """`social.settle`'s fetcher for Fanfix. `browser(url, folder, name) -> (path | None, why)` downloads through
    the window's own Chromium (the person's session and Cloudflare clearance); a plain request — with the session
    only for Fanfix's hosts (`tries_for`) — is the fallback. Streams go through `fetch_stream`; a file that turns
    out to be a playlist is read as one."""
    def fetch(item: social.Item, tmp: str, _tries: list[dict[str, str]]) -> tuple[str | None, str]:
        tries = tries_for(item.url, ua, cookie)
        if ext_of(item.url) in STREAM_EXT:
            return fetch_stream(item, tmp, tries, browser=browser)
        whys = []
        if browser is not None:
            path, why = browser(item.url, tmp, item.filename)
            if path and item.video and sniff(path) in ("m3u8", "mpd"):
                with open(path, "rb") as f:
                    manifest = f.read(4_000_000).decode("utf-8", "replace")
                os.remove(path)
                return fetch_stream(item, tmp, tries, manifest=manifest)
            path, why = _checked(path, why, item)
            if path or "DRM" in why:
                return path, why
            whys.append(f"in the browser: {why}")
        path, why = _checked(*social.download(item, tmp, tries), item)
        if path or "DRM" in why:
            return path, why
        whys.append(f"directly: {why}" if whys else why)
        return None, "; ".join(whys)
    return fetch
