"""Facebook profiles for Safe Finder — what to download and where it goes; no Qt (social_downloader.py is
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

**Nothing missed.** A walk of the uploads or tagged set may stop early — after 30 photos in a row already
done (they're newest first) — only once that set has been walked to its end with every photo of it
downloaded; the record keeps that (`walked`: set → when). A walk cut short (Stop, a login wall, a page that
stays empty) or one whose photos didn't all download clears it, so the next run walks the whole set again;
`Options.full` ("Check every photo again") always does. Albums are walked to the end every time (they can be
oldest first).

**Upload dates.** A photo's time is the one in its own node on its page (`created`: the `created_time` /
`creation_time` / `publish_time` nearest its id — a page also holds comments' and other posts' times); a
page without one is read in its other form for it.

**Through the logged-in browser.** Every page is a `fetch()` from a page on www.facebook.com (`PAGE_JS`):
the browser's own cookies, so it's what Facebook's site gets. The run is a generator: it yields
`("page", url)` and gets back `(status, html, final_url)`; `("sleep", s)` spaces the reads; `("emit",
items)` hands found items to the downloads while the walks go on; `("note", text)` is a line for the log.

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
KNOWN_RUN = 30                    # photos in a row already done before a newest-first walk stops
MAX_ITEMS = 10_000
GAP, JITTER = 0.35, 0.4           # seconds between page reads
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


class _Reader:
    """Page reads with spacing, retries, and one JavaScript redirect followed (a generator helper)."""

    def __init__(self) -> None:
        self.penalty = 0.0
        self.wall = False

    def read(self, url: str, hops: int = 1):
        """yield from: (html, final_url), or (None, why)."""
        for attempt in range(len(BACKOFF) + 1):
            yield ("sleep", GAP * (1 + random.uniform(-JITTER, JITTER)) + self.penalty)
            self.penalty = max(0.0, self.penalty - GAP)
            status, html, final = yield ("page", url)
            if status == 0:
                # The request never got an answer: the network, or a read the browser refused (another host).
                why = (html or "no answer").strip()[:160]
                if attempt == 0:
                    yield ("note", f"   couldn't reach {url} ({why}) — trying again in 5 s")
                    yield ("sleep", 5)
                    continue
                return None, f"couldn't reach it: {why}"
            if status == 429 or status >= 500:
                if attempt < len(BACKOFF):
                    self.penalty = min(self.penalty + 2.0, 10.0)
                    yield ("note", f"   Facebook asked to slow down (HTTP {status}) — waiting {BACKOFF[attempt]} s")
                    yield ("sleep", BACKOFF[attempt])
                    continue
                return None, f"HTTP {status}"
            if status >= 400:
                return None, f"HTTP {status}"
            hop = js_redirect(html) if hops > 0 else None
            if hop and hop.startswith("https://") and hop != final:
                return (yield from self.read(hop, hops - 1))
            if looks_like_login(html, final):
                self.wall = True
            return html, final
        return None, "no answer"


def _walk(reader: _Reader, token: str, first_id: str | None, skip: set[str], seen: set[str], folder: Path,
          poster_from_page: bool, early_stop: bool, label: str, name: str, keys: set[str] | None = None):
    """yield from: one media set, photo by photo (module notes); emits what's new (their ids into `keys`).
    Returns (how many, whether the walk got to the end of the set — or caught up, when `early_stop`)."""
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
    visited: set[str] = set()
    known = emitted = 0
    finished = False
    while not reader.wall:
        if not nid or nid in visited:
            finished = True                    # no next photo, or back round to one already read: the end
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
                yield ("note", f"   {label}: photo {nid} came back empty — reading it again in {BACKOFF[attempt]} s")
                yield ("sleep", BACKOFF[attempt])
        if page is None or reader.wall:
            break
        if not complete(page):
            yield ("note", f"   {label}: stopped at photo {nid} — Facebook kept answering with an empty page "
                           "(the next run reads the whole set again)")
            break
        if nid in skip or nid in seen:
            known += 1
            if early_stop and known >= KNOWN_RUN:
                yield ("note", f"   {label}: caught up (30 already downloaded in a row)")
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
                                   caption=caption(page), poster=who)
                yield ("emit", [item])
                emitted += 1
                if keys is not None:
                    keys.add(nid)
        nid = next_media_id(page)
    yield ("note", f"   {label}: {len(visited)} page(s) read, {emitted} new" + ("" if finished else " (not to the end)"))
    return emitted, finished


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
        try:
            req = next(gen)
            while True:
                if req[0] == "emit":
                    count[0] += len(req[1])
                req = gen.send((yield req))
        except StopIteration as stop:
            return stop.value

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
    for token in tokens:
        yield from counting(_walk(reader, token, None, skip, seen, folder, False, False, f"album {token}",
                                  profile.name))
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
            if vid in skip or vid in seen or reader.wall:
                continue
            watch, _f = yield from reader.read(f"{HOST}watch/?v={vid}")
            if not watch or reader.wall:
                continue
            url = video_url(watch)
            if url:
                seen.add(vid)
                count[0] += 1
                yield ("emit", [social.Item(vid, folder, f"FB_{vid}", True, url, ext="mp4", date=created(watch, vid),
                                            caption=caption(watch), poster=profile.name)])
    out.found = count[0]
    out.login_wall = reader.wall
    if reader.wall:
        out.problem = "Facebook asked for a fresh login — log in in the window above, then press Download again."
    return out
