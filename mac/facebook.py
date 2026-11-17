"""Facebook profiles for Photo Browser for Mac — what to download and where it goes; no Qt (social_downloader.py is
the window, social.py the downloading). A port of the iPhone app's `FacebookService`, so both apps download
the same things under the same names and neither fetches what the other has.

**How it reads Facebook.** Facebook's pages embed the JSON its own app runs on; a run reads that, the way
maintained scrapers do since the old `mbasic` site went. Coverage is the profile's real albums (Timeline
and Mobile Uploads, Profile Pictures, Cover Photos, the rest — found on its albums tab), the uploads set
(`pb.`, which alone stops around 100 photos), **every photo it's tagged in** (`t.` — always, whoever posted
it) and its videos tab. A set is walked photo by photo: each photo's page holds the full-size file's
address, when it was uploaded, its caption, who posted it — and the id of the next photo, so no GraphQL ids
go stale. A page Facebook answers empty (a rate-limit shell) is read again after a pause, not taken for the
end of the set.

**Nothing missed.** A walk of the uploads or tagged set may stop early — after 12 photos in a row already
done (they're newest first) — only once that set has been walked to its end with every photo of it
downloaded; the record keeps that (`walked`: set → when). A walk cut short (Stop, a login wall, a page that
stays empty) or one whose photos didn't all download clears it, so the next run walks the whole set again;
`Options.full` ("Check every photo again") always does. An album walked to its end with everything
downloaded is remembered by its first and last photo (`albums`: token → {head, tail}); the next run reads
from its front until it meets the old first photo (new ones at the front), then carries on from the old last
photo (new ones at the end) — an unchanged album is two reads instead of one per photo. A last photo that's
gone means the whole album is read again.

**Pacing** (`_Reader`): the gap between reads adapts — it eases while Facebook answers quickly and whole,
grows when pages slow down, doubles at a 429/5xx or an empty rate-limit shell — under a ceiling of reads in any
minute that starts at `PER_MINUTE`, rises a step after every `EASED_AFTER` quick answers in a row (to
`FAST_PER_MINUTE`) and falls at any trouble (to `SLOW_PER_MINUTE`). Speed comes mostly from reading less.

**Upload dates.** A photo's time is the one in its own node on its page (`created`: the `created_time` /
`creation_time` / `publish_time` nearest its id — a page also holds comments' and other posts' times); a
page without one is read in its other form for it.

**Through the logged-in browser.** Every page is a `fetch()` from a page on www.facebook.com (`PAGE_JS`):
the browser's own cookies, so it's what Facebook's site gets. The run is a generator: it yields
`("page", url)` and gets back `(status, html, final_url)`; `("visit", url, scroll, press, find)` opens a page in
the window's browser (the Subscriber Hub); `("sleep", s)` spaces the reads; `("emit", items)` hands found items to
the downloads while the walks go on; `("note", text)` is a line for the log. The generator runs on a thread of its
own (social_downloader's `_Runner`), so none of its reading holds the window up.

**Exclusive (subscriber-only) content** (`_hub`; Nov 17): read **first** in every run — so a run cut short has it,
and the sweep after it never takes those again untagged — and alone with `Options.exclusive_only` ("Only
exclusive"). Found as the person finds it: the profile opened in the window's browser and its tab for subscribers
looked for by its words or address (`tab_links`: "Subscriptions", "Exclusive", "Subscriber hub"…; under "More" too);
only without one are the iPhone's addresses tried (`hub_urls`), and a guess counts only if it stays on a subscriber
address and its data says subscribers. The hub is opened in the browser and scrolled to its end (`("visit", url,
True)` — its posts are drawn by the page's own scripts, which the watcher copies; a plain read of the address holds
next to nothing), and every set, photo, video and reel in what it loaded is read (`hub_media`): sets walked whole,
the rest one by one (`_single`). The profile and cover pictures (`header_ids`) and its public albums are left out.
Nothing found: what Facebook showed is saved to ~/Library/Logs/<app>/facebook-hub-*.json for the next fix.
Elsewhere a photo or video whose page says it's for subscribers (`social.exclusive_in_text`, near its own id) counts
too. All of it is tagged "exclusive" — and files downloaded before are tagged when a run meets them again
(`("tag", paths, tags)`).

**Names** (the dedup contract with the iPhone): `FB_<media id>.<ext>`, the extension the file has (jpg,
png, webp, gif; mp4). The profile lives in `<person>/<its name>` (or wherever its record says, or the
folder itself when that is it). What's done = the record's ids (`.facebook.json`, shared with the iPhone —
social.py) + every `FB_<id>` in the folder.
"""
from __future__ import annotations

import html as htmllib
import json
import os
import random
import re
import time
from dataclasses import dataclass, field
from pathlib import Path
from urllib.parse import parse_qs, urlsplit, urlunsplit

import social

TAG = "facebook"
RECORD = ".facebook.json"
FORMAT = "photobrowser-facebook"
HOST = "https://www.facebook.com/"
ROBOTS = "https://www.facebook.com/robots.txt"       # the page the reads are made from: same origin, no scripts
KNOWN_RUN = 12                    # photos in a row already done before a newest-first walk stops
MAX_ITEMS = 10_000
GAP, JITTER = 0.35, 0.4           # seconds between page reads, to begin with (it adapts — `_Reader`)
MIN_GAP, MAX_GAP = 0.25, 8.0      # the most and the least it adapts to
PER_MINUTE = 50                   # page reads in any 60 seconds to begin with…
FAST_PER_MINUTE = 75              # …raised a step after every EASED_AFTER quick, whole answers in a row, up to this
SLOW_PER_MINUTE = 30              # …and cut at any sign of trouble, down to this
EASED_AFTER = 120
SLOW_READ = 3.0                   # seconds: a page taking longer than this is Facebook getting slower
BACKOFF = (5, 15, 45)
_RESERVED = {"profile.php", "photo.php", "photo", "story.php", "share", "people", "pages", "watch", "media", "login", ""}


# ----------------------------------------------------------------------------- reading a page

def first(s: str, pattern: str) -> str | None:
    m = re.search(pattern, s, re.I | re.S)
    return m.group(1) if m and m.groups() and m.group(1) is not None else None


def every(s: str, pattern: str) -> list[str]:
    return [m.group(1) for m in re.finditer(pattern, s, re.I | re.S)]


def unescape_json(s: str) -> str:
    try:
        return json.loads(f'"{s}"')
    except ValueError:
        return decode(s)


def decode(s: str) -> str:
    return htmllib.unescape(s).replace("\\/", "/").strip()


def json_string(s: str, prefix: str) -> str | None:
    """The JSON string value after `prefix` (a pattern like `"image":\\{[^{}]*?"uri":`), unescaped."""
    v = first(s, prefix + r'"((?:[^"\\]|\\.)+)"')
    return unescape_json(v) if v is not None else None


def meta(s: str, prop: str) -> str | None:
    return first(s, rf'<meta[^>]+property="{re.escape(prop)}"[^>]+content="([^"]+)"') or \
        first(s, rf'<meta[^>]+content="([^"]+)"[^>]+property="{re.escape(prop)}"')


def looks_like_login(s: str, final_url: str) -> bool:
    if "/login" in final_url or "login_via" in final_url or "/checkpoint" in final_url:
        return True
    return 'id="login_form"' in s or ('name="login"' in s and 'name="pass"' in s)


def first_media_id(s: str) -> str | None:
    """The first photo or video on a set page (a set can open on a video)."""
    return first(s, r'\{"__typename":"(?:Photo|Video)","id":"(\d+)"') or \
        first(s, r'"__isMedia":"(?:Photo|Video)"[^{}]*?"id":"(\d+)"') or first(s, r"fbid=(\d{6,})")


def next_media_id(s: str) -> str | None:
    """The next photo's id — the pointer each photo page carries (photos and videos alike)."""
    return first(s, r'"nextMediaAfterNodeId":\{"__typename":"(?:Photo|Video)","id":"(\d+)"') or \
        first(s, r'"nextMedia":\{"edges":\[\{"node":\{"__typename":"(?:Photo|Video)","id":"(\d+)"') or \
        first(s, r'"nextMediaAfterNodeId":\{[^{}]*?"id":"(\d+)"')


def image_url(s: str) -> str | None:
    return json_string(s, r'"image":\{[^{}]*?"uri":')


def video_url(s: str) -> str | None:
    for key in ("browser_native_hd_url", "playable_url_quality_hd", "browser_native_sd_url", "playable_url"):
        v = json_string(s, f'"{key}":')
        if v:
            return v
    return None


def complete(s: str) -> bool:
    """A photo page with nothing on it is a rate-limit or error shell to read again, not the end."""
    return next_media_id(s) is not None or image_url(s) is not None or video_url(s) is not None


def owner(s: str) -> str:
    return (json_string(s, r'"owner":\{(?:[^{}]|\{[^{}]*\})*?"name":') or "").strip()


def caption(s: str) -> str:
    raw = first(s, r'"message":\{[^{}]*?"text":"((?:[^"\\]|\\.)*)"')
    if raw is None:
        return ""
    text = unescape_json(raw)
    return text[:800]


_TIME = re.compile(r'"(?:created_time|creation_time|publish_time)":(\d{9,11})')
NEAR = 4000                       # how far (characters) from the media's own id its time may sit


def created(s: str, media_id: str | None = None) -> float:
    """When the photo or video was uploaded (unix time), 0 when the page doesn't say. With `media_id`, the
    time nearest one of its `"id":"<id>"` — inside its own node — wins: the page also carries the times of
    its comments and of other posts, and the first one on the page isn't necessarily the photo's."""
    now = time.time() + 86_400
    times = [(m.start(), int(m.group(1))) for m in _TIME.finditer(s) if social.MIN_DATE <= int(m.group(1)) <= now]
    if not times:
        return 0.0
    if media_id:
        best: tuple[int, int] | None = None
        for a in re.finditer(rf'"id":"{re.escape(media_id)}"', s):
            for pos, t in times:
                d = abs(pos - a.start())
                if d <= NEAR and (best is None or d < best[0]):
                    best = (d, t)
        if best is not None:
            return float(best[1])
    return float(times[0][1])


def image_ext(url: str) -> str:
    path = urlsplit(url).path.lower()
    for ext in ("jpg", "jpeg", "png", "webp", "gif", "heic"):
        if path.endswith("." + ext):
            return "jpg" if ext == "jpeg" else ext
    return "jpg"


def js_redirect(s: str) -> str | None:
    """www answers some requests with a tiny page that sends the browser on (`window.location.replace`)."""
    if len(s) >= 4096:
        return None
    v = first(s, r'window\.location\.replace\("((?:[^"\\]|\\.)+)"\)')
    return unescape_json(v) if v else None


# ----------------------------------------------------------------------------- the profile

@dataclass
class Profile:
    id: str
    vanity: str | None
    name: str
    url: str
    pic: str = ""


def vanity_name(url: str) -> str | None:
    parts = urlsplit(url)
    if "facebook.com" not in (parts.hostname or ""):
        return None
    head = parts.path.strip("/").split("/")[0] if parts.path.strip("/") else ""
    return None if head in _RESERVED else head


def clean_name(s: str) -> str:
    for junk in (" | Facebook", "| Facebook", "Facebook"):
        s = s.replace(junk, "")
    return re.sub(r"^\(\d+\)\s*", "", s).strip()


_FB_HOST = re.compile(r"^(?:[a-z0-9-]+\.)?(?:facebook\.com|fb\.com)$", re.I)
_SCHEME = re.compile(r"^[a-z][a-z0-9+.-]*://", re.I)


def start_url(link: str) -> str:
    """The profile's address on www.facebook.com, however it was typed or pasted: "facebook.com/name",
    "https://m.facebook.com/name?mibextid=…", "fb.com/name", "www.facebook.com/profile.php?id=…", "name",
    "@name", a bare id. It has to be www: the pages are read from a page there, and a read of any other host
    (even facebook.com without www) is one the browser refuses — and "facebook.com/name" mustn't become
    www.facebook.com/facebook.com/name. Tracking parameters are dropped (`?id=` of profile.php is kept)."""
    s = link.strip().strip("<>\"'").strip()
    s = s[1:] if s.startswith("@") else s
    if not s:
        return HOST
    if re.fullmatch(r"\d{5,}", s):
        return f"{HOST}profile.php?id={s}"
    if not _SCHEME.match(s):
        head = s.split("/", 1)[0].split("?", 1)[0].split(":", 1)[0]
        if not _FB_HOST.match(head):
            return HOST + s.lstrip("/")                # a bare name or path
        s = "https://" + s
    parts = urlsplit(s)
    if not _FB_HOST.match(parts.hostname or "") or (parts.hostname or "").lower().startswith("l."):
        return s                                       # not a Facebook page: read as it is, and fail saying so
    path = parts.path or "/"
    query = ""
    if path.rstrip("/").endswith("profile.php"):
        pid = parse_qs(parts.query).get("id", [""])[0]
        query = f"id={pid}" if pid else ""
    return urlunsplit(("https", "www.facebook.com", path, query, ""))


def profile_from(page: str, final_url: str) -> Profile | None:
    """The profile's id, vanity name, display name and picture, from its page."""
    pid = first(page, r"fb://profile/(\d+)") or first(page, r"fb://page/\?id=(\d+)") or \
        first(page, r'"delegate_page":\{"id":"(\d+)"') or \
        first(page, r'"owner":\{"__typename":"(?:User|Page)","id":"(\d+)"') or \
        first(page, r'"profile_id":"?(\d{6,})') or first(final_url, r"[?&]id=(\d{6,})")
    vanity = vanity_name(final_url)
    if not pid and not vanity:
        return None
    anchored = json_string(page, rf'"owner":\{{(?:[^{{}}]|\{{[^{{}}]*\}})*?"id":"{pid}"[^{{}}]*?"name":') if pid else None
    names = [clean_name(decode(meta(page, "og:title") or "")), anchored or "",
             clean_name(decode(first(page, r"<title>([^<]+)</title>") or "")), owner(page)]
    name = next((n for n in names if n), None) or vanity or "Facebook Profile"
    return Profile(pid or vanity or "", vanity, name, final_url, decode(meta(page, "og:image") or ""))


def tab(profile: Profile, name: str) -> str:
    return HOST + (f"{profile.vanity}/{name}" if profile.vanity else f"profile.php?id={profile.id}&sk={name}")


# ----------------------------------------------------------------------------- on the drive

def ids_on_disk(folder: str | Path) -> set[str]:
    """The media ids saved in the folder: `FB_<id>.<ext>` (an old `FB_<id> 2.jpg` twin counts too)."""
    out = set()
    try:
        names = os.listdir(folder)
    except OSError:
        return out
    for n in names:
        if not n.startswith("FB_"):
            continue
        stem = n.rpartition(".")[0] if "." in n else n
        stem = stem[3:]
        head, sp, tail = stem.rpartition(" ")
        if sp and tail.isdigit():
            stem = head
        if stem:
            out.add(stem)
    return out


def done_files(folder: str | Path, media_id: str) -> list[str]:
    """The files already downloaded for a photo or video (`FB_<id>.<ext>`)."""
    try:
        return [str(p) for p in Path(folder).glob(f"FB_{media_id}.*") if p.is_file()]
    except OSError:
        return []


def media_markers(s: str) -> bool:
    """A page with photos, sets or videos on it — a real feed, not an empty shell or a wrong address's redirect."""
    return bool(first_media_id(s) or re.search(r"set=[a-z]+\.[0-9A-Za-z]", s) or re.search(r"watch/\?v=\d", s)
                or re.search(r'"video_?id":"\d', s))


def hub_urls(profile: "Profile") -> list[str]:
    """Where a creator's subscriber-only posts may be when the profile shows no tab for them (`tab_links` finds the
    tab itself first) — Facebook publishes no address; the iPhone app's forms, and the tab names it has used."""
    out = []
    if profile.vanity:
        out += [f"{HOST}{profile.vanity}/subscriber_hub", f"{HOST}{profile.vanity}?sk=subscriber_hub",
                f"{HOST}{profile.vanity}/subscriptions", f"{HOST}{profile.vanity}?sk=exclusive_content"]
    if profile.id.isdigit():
        out += [f"{HOST}profile.php?id={profile.id}&sk=subscriber_hub", f"{HOST}subscriber_hub/?creator_id={profile.id}",
                f"{HOST}profile.php?id={profile.id}&sk=exclusive_content"]
    return out


# The profile's tab for subscribers, as the page names it ("Subscriptions", "Exclusive", "Subscriber hub",
# "Supporters"…) or as its address does. A "Subscribe" button (the sign-up) is not it.
TAB_TEXT = re.compile(r"^\s*(subscriptions?|subscriber(s|[- ]only)?(\s+(hub|content|posts?|only))?|exclusive"
                      r"(\s+(content|posts?|for subscribers))?|supporters?(\s+only)?|fan subscriptions?)\s*$", re.I)
TAB_HREF = re.compile(r"(?:[?&]sk=|/)(subscriber_?hub|subscriptions|exclusive\w*|supporters?\w*|fan_?subscriptions?)"
                      r"(?:[/?&#]|$)", re.I)
TAB_FIND = r"subscri|exclusive|supporter"             # what the window's page script looks for, loosely


def tab_links(seen: dict | None, html: str = "") -> list[str]:
    """The profile's subscriber tab: links the visited page drew (`seen["links"]`: {text, href}) whose words or
    address name it, and any such address written in `html` — on www.facebook.com, in the order found."""
    out: list[str] = []

    def take(href: str) -> None:
        href = decode(href or "")
        if href.startswith("/"):
            href = HOST + href.lstrip("/")
        host = (urlsplit(href).hostname or "").lower()
        if host != "www.facebook.com":
            return
        if href not in out:
            out.append(href)
    for link in (seen or {}).get("links") or []:
        if not isinstance(link, dict):
            continue
        text, href = str(link.get("text") or ""), str(link.get("href") or "")
        if TAB_TEXT.match(text) or TAB_HREF.search(href):
            take(href)
    for m in re.finditer(r'href="([^"]+)"', html or ""):
        if TAB_HREF.search(m.group(1)):
            take(m.group(1))
    return out


_HEADER = re.compile(r'"(?:profile_?photo|profilePhoto|profile_?picture\w*|profilePic\w*|cover_?photo|coverPhoto)"'
                     r'\s*:\s*\{(?:[^{}]|\{[^{}]*\}){0,800}?"id"\s*:\s*"(\d+)"')


def header_ids(page: str) -> set[str]:
    """The profile picture's and cover photo's ids — on every one of its pages, the hub's too; never exclusive."""
    return {m.group(1) for m in _HEADER.finditer(page or "")}


def hub_media(texts: list[str]) -> tuple[list[str], list[str], list[str]]:
    """The sets (media-set tokens), photos and videos named in what the Subscriber Hub loaded, in order, once."""
    tokens: list[str] = []
    photos: list[str] = []
    videos: list[str] = []

    def add(into: list[str], v: str) -> None:
        if v not in into:
            into.append(v)
    for text in texts:
        for t in every(text, r"set=([a-z]+\.[0-9A-Za-z%.\-]+)"):
            add(tokens, decode(t))
        for pattern in (r"fbid=(\d{6,})", r'"__typename"\s*:\s*"Photo"\s*,\s*"id"\s*:\s*"(\d{6,})"'):
            for pid in every(text, pattern):
                add(photos, pid)
        for pattern in (r'"video_?id"\s*:\s*"(\d{8,})"', r"watch/\?v=(\d{8,})", r"/reel/(\d{8,})",
                        r'"__typename"\s*:\s*"Video"\s*,\s*"id"\s*:\s*"(\d{8,})"', r"videos\\?/(\d{8,})"):
            for v in every(text, pattern):
                add(videos, v)
    photos = [p for p in photos if p not in videos]
    return tokens, photos, videos


def record(folder: str | Path) -> social.Record:
    return social.Record.load(folder, RECORD, FORMAT)


def folder_for(name: str) -> str:
    return social.sanitize(name, "Facebook Profile", 80)


def destination(person: str | Path, profile: Profile) -> Path:
    """Where the profile goes from `person` (the folder right-clicked): the folder itself when its record
    is this profile's, a subfolder whose record is, else `<person>/<its name>` — the iPhone's choice."""
    person = Path(person)

    def mine(p) -> bool:
        r = record(p)
        return bool(r.exists) and (str(r.get("profile_id") or "") == profile.id or
                                   (profile.vanity and str(r.get("profile_url") or "").rstrip("/").endswith(profile.vanity)))
    if mine(person):
        return person
    try:
        for e in sorted(os.scandir(person), key=lambda e: e.name):
            if e.is_dir() and not e.name.startswith(".") and mine(e.path):
                return Path(e.path)
    except OSError:
        pass
    return person / folder_for(profile.name)


# ----------------------------------------------------------------------------- reading pages (from the page)

PAGE_JS = r"""(function () {
  window.__pbfb = window.__pbfb || {};
  const id = __ID__, url = __URL__;
  window.__pbfb[id] = null;
  (async () => {
    const ctl = new AbortController();
    const timer = setTimeout(() => ctl.abort(), 45000);
    try {
      const r = await fetch(url, { credentials: 'include', signal: ctl.signal,
                                   headers: { 'Accept': 'text/html,application/xhtml+xml' } });
      window.__pbfb[id] = { status: r.status, body: await r.text(), url: r.url };
    } catch (e) {
      window.__pbfb[id] = { status: 0, body: String(e), url: url };
    } finally { clearTimeout(timer); }
  })();
  return true;
})()"""

RESULT_JS = r"""(function () {
  const r = (window.__pbfb || {})[__ID__];
  if (!r) return null;
  delete window.__pbfb[__ID__];
  return JSON.stringify(r);
})()"""


def page_js(ident: str, url: str) -> tuple[str, str]:
    q = json.dumps
    return PAGE_JS.replace("__ID__", q(ident)).replace("__URL__", q(url)), RESULT_JS.replace("__ID__", q(ident))


def album_ends(old, walked: dict | None, done_keys: set[str]) -> dict:
    """The record's `albums` after a run: each album walked to its end this run with every new photo of it
    downloaded (`done_keys`) gets its new first and last photo; one with a photo that didn't download is
    forgotten (read whole next time); albums this run didn't finish keep what they had."""
    ends = dict(old) if isinstance(old, dict) else {}
    for token, (keys, where) in (walked or {}).items():
        if keys <= done_keys:
            ends[token] = {"head": where["head"], "tail": where["tail"], "when": int(time.time())}
        else:
            ends.pop(token, None)
    return ends


# ----------------------------------------------------------------------------- a run

@dataclass
class Outcome:
    profile: Profile | None = None
    folder: Path | None = None
    found: int = 0
    problem: str = ""
    login_wall: bool = False
    # The uploads / tagged sets walked this run: name → (walked to its end, the media ids handed to the
    # downloads) — what the window turns into the record's `walked` once it knows they all downloaded.
    sets: dict = field(default_factory=dict)
    # Albums walked to their end this run: token → (the media ids handed to the downloads, {"head", "tail"})
    # — the record's `albums`, so the next run carries on from where each ended (once they all downloaded).
    albums: dict = field(default_factory=dict)
    reads: int = 0                    # pages read this run


class _Reader:
    """Page reads with spacing, retries, and one JavaScript redirect followed (a generator helper).

    **The spacing adapts to how Facebook is answering.** It starts at `GAP` (± jitter, so reads don't land
    in lockstep); each page that comes back quickly and whole eases it by 10 % down to `MIN_GAP`; a slow page
    (over `SLOW_READ` s) lengthens it by half; trouble — HTTP 429/5xx, an empty rate-limit shell (`trouble()`,
    from the walk) — doubles it (to `MAX_GAP`) on top of the existing waits. Whatever the gap, no more than
    `ceiling` reads go in any 60 seconds — `PER_MINUTE` to begin with, a step more after every `EASED_AFTER` quick,
    whole answers in a row (up to `FAST_PER_MINUTE`), less at any trouble (down to `SLOW_PER_MINUTE`, earned back
    the same way). So a run goes as fast as Facebook comfortably answers and backs off at the first sign it
    wouldn't — it never pushes through a slow-down."""

    def __init__(self, clock=time.monotonic) -> None:
        self.penalty = 0.0
        self.wall = False
        self.gap = GAP
        self.clock = clock
        self.recent: list[float] = []          # when the reads of the last minute went
        self.reads = 0
        self.ceiling = PER_MINUTE              # reads allowed in any 60 seconds now
        self.good = 0                          # quick, whole answers since the last trouble or raise

    def trouble(self) -> None:
        """Facebook's answer said slow down (a 429/5xx, or an empty shell): twice the gap, and a lower ceiling
        that has to be earned back."""
        self.gap = min(MAX_GAP, self.gap * 2 + 0.5)
        self.ceiling = max(SLOW_PER_MINUTE, min(self.ceiling, PER_MINUTE) - 10)
        self.good = 0

    def _eased(self, took: float) -> None:
        if took > SLOW_READ:
            self.gap = min(MAX_GAP, self.gap * 1.5)
            self.good = 0
            return
        self.gap = max(MIN_GAP, self.gap * 0.9)
        self.good += 1
        if self.good >= EASED_AFTER and self.ceiling < FAST_PER_MINUTE:
            self.ceiling = min(FAST_PER_MINUTE, self.ceiling + 5)
            self.good = 0

    def _wait(self) -> float:
        """Seconds to wait before the next read: the gap (jittered), the penalty, and the per-minute cap."""
        wait = self.gap * (1 + random.uniform(-JITTER, JITTER)) + self.penalty
        now = self.clock()
        self.recent = [t for t in self.recent if now - t < 60]
        if len(self.recent) >= self.ceiling:
            wait = max(wait, self.recent[-self.ceiling] + 60 - now)
        return wait

    def read(self, url: str, hops: int = 1):
        """yield from: (html, final_url), or (None, why)."""
        for attempt in range(len(BACKOFF) + 1):
            yield ("sleep", self._wait())
            self.penalty = max(0.0, self.penalty - GAP)
            began = self.clock()
            self.recent.append(began)
            self.reads += 1
            status, html, final = yield ("page", url)
            took = self.clock() - began
            if status == 0:
                # The request never got an answer: the network, or a read the browser refused (another host).
                why = (html or "no answer").strip()[:160]
                if attempt == 0:
                    yield ("note", f"   couldn't reach {url} ({why}) — trying again in 5 s")
                    yield ("sleep", 5)
                    continue
                return None, f"couldn't reach it: {why}"
            if status == 429 or status >= 500:
                self.trouble()
                if attempt < len(BACKOFF):
                    self.penalty = min(self.penalty + 2.0, 10.0)
                    yield ("note", f"   Facebook asked to slow down (HTTP {status}) — waiting {BACKOFF[attempt]} s")
                    yield ("sleep", BACKOFF[attempt])
                    continue
                return None, f"HTTP {status}"
            if status >= 400:
                return None, f"HTTP {status}"
            self._eased(took)
            hop = js_redirect(html) if hops > 0 else None
            if hop and hop.startswith("https://") and hop != final:
                return (yield from self.read(hop, hops - 1))
            if looks_like_login(html, final):
                self.wall = True
            return html, final
        return None, "no answer"


def _walk(reader: _Reader, token: str, first_id: str | None, skip: set[str], seen: set[str], folder: Path,
          poster_from_page: bool, early_stop: bool, label: str, name: str, keys: set[str] | None = None,
          resume: dict | None = None, ends: dict | None = None, all_exclusive: bool = False):
    """yield from: one media set, photo by photo (module notes); emits what's new (their ids into `keys`).
    Returns (how many, whether the walk got to the end of the set — or caught up, when `early_stop`).

    `resume` — an album this run has walked to its end before: {"head": its first photo then, "tail": its
    last}. Rather than every photo again, the walk reads from the front only until it meets the old first
    photo (new ones added at the front), then jumps to the old last photo and carries on from there (new
    ones added at the end) — an unchanged album costs two reads, not one per photo. A last photo that won't
    load (deleted) falls back to the whole walk. `ends`, when given, gets {"head", "tail"} of this walk."""
    nid = first_id
    if nid is None:
        page, final = yield from reader.read(f"{HOST}media/set/?set={token}")
        if page is None or reader.wall:
            return 0, False
        nid = first_media_id(page)
    if not nid:
        # No first photo: an empty set — or a page Facebook didn't fill. Not counted as read to the end, so
        # a set with photos is never marked done by a bad answer (an empty one costs two reads next time).
        yield ("note", f"   {label}: no photos found")
        return 0, False
    head = nid
    old_head = (resume or {}).get("head")
    old_tail = (resume or {}).get("tail")
    jumped = False
    last = None
    visited: set[str] = set()
    known = emitted = 0
    finished = False
    if old_tail and old_head == head:              # nothing new at the front: straight to where it ended
        nid, jumped = old_tail, True
    while not reader.wall:
        if not nid or nid in visited:
            finished = True                    # no next photo, or back round to one already read: the end
            break
        if jumped and nid == head and visited:
            finished = True                    # on from where it ended, round to the front again: the end
            break
        if len(visited) >= MAX_ITEMS:
            break
        visited.add(nid)
        forms = (f"photo/?fbid={nid}&set={token}", f"photo.php?fbid={nid}&set={token}")
        page, used = None, None
        for attempt in range(len(BACKOFF) + 1):
            for form in forms:
                got, _final = yield from reader.read(HOST + form)
                if got is None:
                    continue
                page, used = got, form
                if complete(got) or reader.wall:
                    break
            if page is None or reader.wall or complete(page):
                break
            if attempt < len(BACKOFF):         # an empty shell (rate limit): not the end of the set
                reader.trouble()
                yield ("note", f"   {label}: photo {nid} came back empty — reading it again in {BACKOFF[attempt]} s")
                yield ("sleep", BACKOFF[attempt])
        if jumped and nid == old_tail and not reader.wall and (page is None or not complete(page)):
            yield ("note", f"   {label}: the photo it ended at last time is gone — reading the whole album")
            visited.clear()
            nid, jumped, old_tail = head, False, None   # (and no jumping again this walk)
            continue
        if page is None or reader.wall:
            break
        if not complete(page):
            yield ("note", f"   {label}: stopped at photo {nid} — Facebook kept answering with an empty page "
                           "(the next run reads the whole set again)")
            break
        last = nid
        excl = all_exclusive or social.exclusive_in_text(page, nid)
        if excl and (nid in skip) and nid not in seen:
            retag = done_files(folder, nid)               # downloaded before, untagged: tagged now
            if retag:
                yield ("tag", retag, [social.EXCLUSIVE_TAG])
        if nid in skip or nid in seen:
            known += 1
            if early_stop and known >= KNOWN_RUN:
                yield ("note", f"   {label}: caught up ({KNOWN_RUN} already downloaded in a row)")
                finished = True
                break
        else:
            known = 0
            seen.add(nid)
            who = (owner(page) if poster_from_page else "") or name     # the profile's own, else who posted it
            img = image_url(page)
            vid = None if img else video_url(page)
            if img or vid:
                when = created(page, nid)
                if not when:                   # the other form of the page may carry it
                    other = forms[1] if used == forms[0] else forms[0]
                    alt, _f = yield from reader.read(HOST + other)
                    if alt and not reader.wall:
                        when = created(alt, nid)
                item = social.Item(nid, folder, f"FB_{nid}", bool(vid), img or vid,
                                   ext="mp4" if vid else image_ext(img), date=when,
                                   caption=caption(page), poster=who, exclusive=excl)
                yield ("emit", [item])
                emitted += 1
                if keys is not None:
                    keys.add(nid)
        nid = next_media_id(page)
        if not jumped and old_tail and old_head and nid == old_head and old_head != head:
            nid, jumped = old_tail, True        # caught up with the old front: on from where it ended
    if ends is not None and finished and last:
        ends.update(head=head, tail=last)
    yield ("note", f"   {label}: {len(visited)} page(s) read, {emitted} new" + ("" if finished else " (not to the end)")
           + (" — carried on from where it ended last time" if jumped else ""))
    return emitted, finished


def _counting(gen, count: list[int]):
    """yield from: `gen`, its emitted items added up in `count[0]`."""
    try:
        req = next(gen)
        while True:
            if req[0] == "emit":
                count[0] += len(req[1])
            req = gen.send((yield req))
    except StopIteration as stop:
        return stop.value


def _single(reader: _Reader, mid: str, video: bool, folder: Path, skip: set[str], seen: set[str], count: list[int],
            poster: str, exclusive: bool):
    """yield from: one photo (its page) or video (its watch page) found outside a set — downloaded unless it's
    here already (then, being exclusive, tagged so)."""
    if mid in seen or reader.wall:
        return
    if mid in skip:                                    # here already: only tagged, when it's exclusive
        if exclusive:
            retag = done_files(folder, mid)
            if retag:
                yield ("tag", retag, [social.EXCLUSIVE_TAG])
        return
    page = None
    forms = (f"watch/?v={mid}", f"reel/{mid}") if video else (f"photo/?fbid={mid}", f"photo.php?fbid={mid}")
    for form in forms:
        got, _f = yield from reader.read(HOST + form)
        if got:
            page = got
            if complete(got) or reader.wall:
                break
    if not page or reader.wall:
        return
    img = None if video else image_url(page)
    vid = video_url(page) if video or not img else None
    if not (img or vid):
        return
    exclusive = exclusive or social.exclusive_in_text(page, mid)
    seen.add(mid)
    count[0] += 1
    yield ("emit", [social.Item(mid, folder, f"FB_{mid}", bool(vid), img or vid, ext="mp4" if vid else image_ext(img),
                                date=created(page, mid), caption=caption(page),
                                poster=(owner(page) if not video else "") or poster, exclusive=exclusive)])


def dump_visits(visits: list[dict], name: str) -> str:
    """What the Subscriber Hub's pages loaded, saved to ~/Library/Logs/<app>/facebook-hub-<name>-<time>.json — for
    when nothing was found there, so the next fix is made from Facebook's real answers. Stays on this Mac."""
    import app_identity
    try:
        folder = app_identity.logs()
        folder.mkdir(parents=True, exist_ok=True)
        path = folder / f"facebook-hub-{social.sanitize(name, 'profile', 40)}-{time.strftime('%Y%m%d-%H%M%S')}.json"
        doc = [{"url": v.get("url"), "asked": v.get("asked"), "status": v.get("status"), "links": v.get("links"),
                "answers": [a[:3_000_000] for a in v.get("answers") or [] if isinstance(a, str)][:300],
                "html": (v.get("html") or "")[:8_000_000]} for v in visits if isinstance(v, dict)]
        path.write_text(json.dumps(doc, ensure_ascii=False), encoding="utf-8")
        return str(path)
    except OSError:
        return ""


def _short(url: str) -> str:
    return url.replace(HOST, "") or url


def _hub(reader: _Reader, profile: "Profile", profile_page: str, skip: set[str], seen: set[str], folder: Path,
         count: list[int]):
    """yield from: the creator's subscriber-only content (module notes), tagged "exclusive". Returns how many new.

    Found as the person finds it: the profile opened in the window's browser and its tab for subscribers looked
    for ("Subscriptions", "Exclusive"… — `tab_links`), under "More" too; only when there's none are the iPhone's
    addresses tried (`hub_urls`), and one of those counts only if it stays on a subscriber address and its data
    says subscribers. The hub is opened in the browser and scrolled to its end — its posts are drawn by the page's
    own scripts, so a plain read of its address holds next to nothing — and every set, photo and video in what it
    loaded is read: sets walked whole, photos and videos one by one. The profile and cover pictures (on every page
    of the profile) and its public albums are left out."""
    yield ("note", "Looking for subscriber-only (Exclusive) content…")
    keep_out = header_ids(profile_page) | {profile.id}
    front = yield ("visit", profile.url, False, "", TAB_FIND)
    front = front if isinstance(front, dict) else {}
    front["asked"] = profile.url
    links = tab_links(front, profile_page)
    visits = [front]
    if not links:
        more = yield ("visit", profile.url, False, r"^\s*More\s*$", TAB_FIND)
        more = more if isinstance(more, dict) else {}
        more["asked"] = profile.url + " (More)"
        visits.append(more)
        links = tab_links(more)
    public_html = profile_page + (front.get("html") or "")
    keep_out |= header_ids(front.get("html") or "")
    public_albums = {t for t in hub_media([public_html])[0] if t.startswith("a.")}
    if links:
        yield ("note", f"   the profile's subscriber tab: {_short(links[0])}")
    else:
        yield ("note", "   the profile shows no tab for subscribers — trying the addresses Facebook has used")
    tried = [(u, True) for u in links[:3]] + [(u, False) for u in hub_urls(profile) if u not in links]
    tokens: list[str] = []
    photos: list[str] = []
    videos: list[str] = []
    used = ""
    for url, from_tab in tried:
        if reader.wall:
            break
        extra: list[str] = []
        if not from_tab:                                   # a guess: a quick read first, opened only if it's there
            got, final = yield from reader.read(url)
            if reader.wall:
                reader.wall = False                        # a wrong address can send to the login page: not a wall
                yield ("note", f"   {_short(url)}: asked for a login — not this one")
                continue
            if got is None:
                yield ("note", f"   {_short(url)}: {final}")
                continue
            if not TAB_HREF.search(final or ""):
                yield ("note", f"   {_short(url)}: went to {_short(final)} instead")
                continue
            extra = [got]
        seen_h = yield ("visit", url, True)
        seen_h = seen_h if isinstance(seen_h, dict) else {}
        seen_h["asked"] = url
        visits.append(seen_h)
        html, final = seen_h.get("html") or "", seen_h.get("url") or url
        if seen_h.get("status") == 404 or looks_like_login(html, final):
            yield ("note", f"   {_short(url)}: " + ("no such page" if seen_h.get("status") == 404 else "asked for a login"))
            continue
        if not from_tab and not TAB_HREF.search(final):
            yield ("note", f"   {_short(url)}: went to {_short(final)} instead")
            continue
        texts = [a for a in seen_h.get("answers") or [] if isinstance(a, str)] + [html] + extra
        t, p, v = hub_media(texts)
        t = [x for x in t if x not in public_albums]
        p = [x for x in p if x not in keep_out]
        yield ("note", f"   {_short(url)}: {len(seen_h.get('answers') or [])} answer(s) — {len(t)} set(s), "
                       f"{len(p)} photo(s), {len(v)} video(s)")
        if not (t or p or v):
            continue
        if not from_tab and not any(social.exclusive_in_text(x) for x in texts):
            yield ("note", f"   {_short(url)}: nothing on it says subscribers — not taken for the hub")
            continue
        tokens, photos, videos, used = t, p, v, url
        break
    if not used:
        saved = dump_visits(visits, profile.vanity or profile.id)
        yield ("note", "   no subscriber-only content found — you may not be subscribed, or this profile has no "
                       "Subscriptions" + (f" (what Facebook showed is saved in {saved})" if saved else ""))
        return 0
    before = count[0]
    for token in tokens:
        if reader.wall:
            break
        yield from _counting(_walk(reader, token, None, skip, seen, folder, False, False, f"exclusive {token}",
                                   profile.name, all_exclusive=True), count)
    for mid in photos[:MAX_ITEMS]:
        yield from _single(reader, mid, False, folder, skip, seen, count, profile.name, True)
    for mid in videos[:MAX_ITEMS]:
        yield from _single(reader, mid, True, folder, skip, seen, count, profile.name, True)
    yield ("note", f"   {count[0] - before} new subscriber-only photo(s)/video(s)")
    return count[0] - before


def run(link: str, person: Path, already_for, opts: social.Options):
    """The profile at `link`, from the folder `person`. `already_for(folder)` → the ids done there (asked
    once the profile's folder is known). A generator: yields requests, returns an Outcome."""
    out = Outcome()
    reader = _Reader()
    yield ("note", "Opening the profile…")
    page, final = yield from reader.read(start_url(link))
    if page is None or reader.wall:
        out.login_wall = reader.wall
        url = start_url(link)
        out.problem = ("Facebook asked for a login — log in in the window above, then press Download again."
                       if reader.wall else
                       f"Facebook has no page at {url} — check the profile address." if final == "HTTP 404" else
                       f"Couldn’t open {url} ({final}).")
        return out
    profile = profile_from(page, final)
    if profile is None:
        out.problem = "Couldn’t read that profile. Check the link, that you’re logged in, and that you can see it."
        return out
    out.profile = profile
    folder = destination(person, profile)
    out.folder = folder
    yield ("profile", (profile, folder))
    skip = set(already_for(folder))
    walked = record(folder).get("walked")
    walked = walked if isinstance(walked, dict) else {}
    seen: set[str] = set()
    count = [0]

    def counting(gen):
        return _counting(gen, count)

    # Subscriber-only ("Exclusive") content first: the creator's Subscriber Hub (module notes) — a run that's stopped
    # or cut short has it, and everything it finds is `seen`, so the sweep below doesn't take it again untagged.
    yield from _hub(reader, profile, page, skip, seen, folder, count)
    if opts.exclusive_only or reader.wall:
        if opts.exclusive_only:
            yield ("note", "Only the subscriber-only content was asked for — done.")
        out.found = count[0]
        out.reads = reader.reads
        out.login_wall = reader.wall
        if reader.wall:
            out.problem = "Facebook asked for a fresh login — log in in the window above, then press Download again."
        return out

    # Albums: profile and cover pictures, and past the uploads set's ~100-photo ceiling.
    yield ("note", "Finding albums…")
    albums, _f = yield from reader.read(tab(profile, "photos_albums"))
    tokens: list[str] = []
    if albums and not reader.wall:
        for pattern in (r"set=a\.(\d+)", r'"__typename":"Album","id":"(\d+)"', r'"album_?id":"(\d+)"',
                        r"albums\\?/(\d{6,})"):
            for a in every(albums, pattern):
                if f"a.{a}" not in tokens:
                    tokens.append(f"a.{a}")
    resumes = record(folder).get("albums")
    resumes = resumes if isinstance(resumes, dict) and not opts.full else {}
    for token in tokens:
        keys_a: set[str] = set()
        ends: dict = {}
        _n, finished = yield from counting(_walk(reader, token, None, skip, seen, folder, False, False,
                                                 f"album {token}", profile.name, keys_a,
                                                 resume=resumes.get(token), ends=ends))
        if finished and ends:
            out.albums[token] = (keys_a, ends)
    # Uploads, then every photo it's tagged in — credited to whoever posted them. Each stops early only when
    # it was walked to its end before (module notes).
    sets = [("photos_by", f"pb.{profile.id}.-2207520000", ["pb.", "a."], False),
            ("photos_of", f"t.{profile.id}", ["t."], True)]
    for name, fallback, prefixes, from_page in sets:
        if reader.wall:
            break
        yield ("note", "Finding uploads…" if name == "photos_by" else "Finding tagged photos…")
        token, first_id = fallback, None
        tab_page, _f = yield from reader.read(tab(profile, name))
        if tab_page and not reader.wall:
            alt = "|".join(re.escape(p) for p in prefixes)
            t = first(tab_page, rf'"media_?set_?token":"((?:{alt})[^"]+)"') or \
                first(tab_page, rf"set=((?:{alt})[0-9A-Za-z%.\-]+)")
            if t:
                token = decode(t)
            first_id = first_media_id(tab_page)
        early = not opts.full and bool(walked.get(name))
        if not early:
            yield ("note", f"   {'uploads' if name == 'photos_by' else 'tagged photos'}: reading every one "
                           + ("(as asked)" if opts.full else "(the set hasn't been read to its end before)"))
        keys: set[str] = set()
        _n, finished = yield from counting(_walk(reader, token, first_id, skip, seen, folder, from_page, early,
                                                 name, profile.name, keys))
        out.sets[name] = (finished, keys)
    # Videos: the tab lists them; each watch page holds the file's address.
    if not reader.wall:
        yield ("note", "Finding videos…")
        vids, _f = yield from reader.read(tab(profile, "videos"))
        ids: list[str] = []
        if vids and not reader.wall:
            for pattern in (r"videos\\?/(\d{8,})", r'"video_?id":"(\d{8,})"', r"watch/\?v=(\d{8,})"):
                for v in every(vids, pattern):
                    if v not in ids:
                        ids.append(v)
        for vid in ids:
            yield from _single(reader, vid, True, folder, skip, seen, count, profile.name, False)
    out.found = count[0]
    out.reads = reader.reads
    out.login_wall = reader.wall
    if reader.wall:
        out.problem = "Facebook asked for a fresh login — log in in the window above, then press Download again."
    return out
