"""Instagram profiles for Safe Finder — what to download and where it goes; no Qt (social_downloader.py is
the window, social.py the downloading). A port of the iPhone app's `InstagramService`, so both apps
download the same things under the same names and neither fetches what the other has.

**What a run takes** (`run`): the profile's posts (`feed/user/<id>/`), the posts it's tagged in (only the
carousel items it's tagged in — `usertags/<id>/feed/`), its reels (`clips/user/`, which the feed can leave
out), its current stories (every reel source, so subscriber-only stories come too) into `Stories/`, and its
highlights, one folder each. Newest first; a crawl stops after 15 posts in a row that are already done and
older than two weeks before the last run, as the iPhone's does — so a pinned post above newer ones, or a
post a run left behind, isn't missed.

**Names** (the dedup contract with the iPhone): `<shortcode>.jpg` / `.mp4`, a carousel's items
`<shortcode>_1`, `_2`…; a story or highlight item is keyed by its pk. The profile lives in `<person>/<handle>`
(or wherever its record says, or the folder itself when that is it). What's done = the record's ids
(`.instagram.json`, shared with the iPhone — social.py) + every post id named in the folder and its
subfolders (`ids_on_disk`, the iPhone's `postIDsOnDisk`).

**How it asks Instagram.** Through the logged-in browser: every API call is a `fetch()` from a page on
www.instagram.com (`API_JS`, the iPhone's `InstagramWebFetcher`) — the browser's own cookies and headers,
so it's exactly what Instagram's site sends. The run is a generator: it yields `("api", url, form,
app_id)` and gets back `(status, text)`; `("sleep", s)` spaces the calls out (and backs off when Instagram
says to slow down); `("emit", items)` hands found items to the downloads while the crawl goes on; and
`("note", text)` is a line for the log.

**Media.** The best progressive video, or — when the post's DASH manifest has a taller H.264/HEVC
rendition — that one with its audio (put together on the Mac, `video_tools.mux`); the largest image
candidate. The post's time, place, caption and poster go into each file, plus the "Instagram" keyword, as
the iPhone writes them.
"""
from __future__ import annotations

import html as htmllib
import json
import os
import random
import re
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import quote

import social

TAG = "instagram"
RECORD = ".instagram.json"
FORMAT = "photobrowser-instagram"
HOME = "https://www.instagram.com/"
API = "https://www.instagram.com/api/v1/"
ROBOTS = "https://www.instagram.com/robots.txt"       # the page the calls are made from: same origin, no scripts
APP_ID = "936619743392459"
WEB_APP_IDS = {"936619743392459", "1217981644879628"}
ASBD_ID = "359341"
STORIES = "Stories"
KEYWORD = "Instagram"
SEEN_RUN = 15                    # posts in a row already done before a crawl may stop…
FLOOR = 14 * 86_400              # …once they're older than this before the last run
GAP, JITTER = 0.6, 0.25          # seconds between API calls
BACKOFF = (5, 15, 45)            # seconds to wait after "slow down" (429) or a server error, then again

MEDIA_EXTS = {"jpg", "jpeg", "png", "webp", "heic", "mp4", "mov", "m4v", "webm"}


def clean_handle(text: str) -> str:
    """"@name", "instagram.com/name/?hl=en", " name " → "name"."""
    h = text.strip()
    if "instagram.com/" in h:
        h = h.split("instagram.com/", 1)[1]
    h = h.split("/")[0].split("?")[0]
    return h.replace("@", "").strip()


def id_string(v) -> str | None:
    if isinstance(v, bool) or v is None:
        return None
    if isinstance(v, (int, float)):
        return str(int(v))
    return str(v) if isinstance(v, str) and v else None


# ----------------------------------------------------------------------------- the profile

@dataclass
class Profile:
    user_id: str
    handle: str
    full_name: str = ""
    pic: str = ""
    posts: int = 0
    private: bool = True             # unknown → private: the session's cookies go with the media


def profile_from_info(doc: dict, handle: str) -> Profile | None:
    """From `users/web_profile_info/`."""
    user = (doc.get("data") or {}).get("user") if isinstance(doc, dict) else None
    if not isinstance(user, dict):
        return None
    uid = id_string(user.get("id")) or id_string(user.get("pk"))
    if not uid:
        return None
    media = user.get("edge_owner_to_timeline_media") or {}
    return Profile(uid, user.get("username") or handle, user.get("full_name") or "",
                   user.get("profile_pic_url_hd") or user.get("profile_pic_url") or "",
                   int(media.get("count") or 0), user.get("is_private", True) is not False)


def profile_from_search(doc: dict, handle: str) -> Profile | None:
    """From `web/search/topsearch/` — when `web_profile_info` won't answer: the exact handle's entry."""
    want = handle.lower()
    for entry in (doc.get("users") or []) if isinstance(doc, dict) else []:
        u = (entry or {}).get("user") or {}
        if (u.get("username") or "").lower() != want:
            continue
        uid = id_string(u.get("pk")) or id_string(u.get("id"))
        if uid:
            return Profile(uid, u.get("username") or handle, u.get("full_name") or "",
                           u.get("profile_pic_url") or "", 0, u.get("is_private", True) is not False)
    return None


def refusal(status: int, text: str) -> str:
    """Instagram's "no", in words for the person — with what to do."""
    body = text[:4000].lower()
    if "checkpoint" in body or "challenge" in body:
        return "Instagram wants to check it's you — finish that in the window above, then press Download again."
    if status in (401, 403) or "login_required" in body or "require_login" in body or "<html" in body[:200]:
        return "Instagram asked for a login — log in in the window above, then press Download again."
    if status == 429 or "wait a few minutes" in body:
        return "Instagram is limiting requests right now — wait a few minutes and try again."
    try:
        msg = json.loads(text).get("message")
        if msg:
            return f"Instagram said: “{msg}” (HTTP {status})."
    except (ValueError, AttributeError):
        pass
    return f"Instagram answered HTTP {status}."


# ----------------------------------------------------------------------------- media

@dataclass
class Media:
    video: bool
    url: str
    audio: str | None = None
    fallback: str | None = None
    quality: str = ""


def _area(d: dict) -> int:
    return int(d.get("width") or 0) * int(d.get("height") or 0)


def best_url(cands: list[dict]) -> str | None:
    cands = [c for c in cands or [] if isinstance(c, dict) and c.get("url")]
    return max(cands, key=_area)["url"] if cands else None


def _attr(attrs: str, name: str) -> str:
    m = re.search(rf'\b{name}="([^"]*)"', attrs, re.I)
    return m.group(1) if m else ""


def dash_streams(mpd: str) -> tuple[list[tuple[str, int, str]], str | None]:
    """The video representations (url, height, codec) and the first audio stream of a DASH manifest."""
    videos: list[tuple[str, int, str]] = []
    audio = None
    for m in re.finditer(r"<Representation([^>]*)>([\s\S]*?)</Representation>", mpd, re.I):
        attrs, body = m.group(1), m.group(2)
        b = re.search(r"<BaseURL>([\s\S]*?)</BaseURL>", body, re.I)
        if not b:
            continue
        url = htmllib.unescape(b.group(1).strip())
        codec = _attr(attrs, "codecs").lower()
        try:
            h = int(_attr(attrs, "height") or 0)
        except ValueError:
            h = 0
        if codec.startswith("mp4a") or (_attr(attrs, "audioSamplingRate") and h == 0):
            audio = audio or url
        else:
            videos.append((url, h, codec))
    return videos, audio


def _compatible(codec: str) -> bool:
    """What AVFoundation puts together without re-encoding: H.264 and HEVC."""
    return codec.startswith(("avc", "hvc", "hev"))


def media(item: dict) -> list[Media]:
    """The best of what a post (or a carousel's items) offers — see the module notes."""
    kind = item.get("media_type") or 1
    if kind == 8 and isinstance(item.get("carousel_media"), list):
        return [m for c in item["carousel_media"] if isinstance(c, dict) for m in media(c)]
    if kind == 2:
        vv = [v for v in item.get("video_versions") or [] if isinstance(v, dict)]
        prog = max(vv, key=_area) if vv else None
        prog_url = prog.get("url") if prog else None
        prog_h = int(prog.get("height") or 0) if prog else 0
        mpd = item.get("video_dash_manifest")
        if isinstance(mpd, str) and mpd:
            videos, audio = dash_streams(htmllib.unescape(mpd))
            best = max((v for v in videos if _compatible(v[2])), key=lambda v: v[1], default=None)
            if best and audio and best[1] > prog_h:
                return [Media(True, best[0], audio, prog_url, f"{best[2]} {best[1]}p (DASH)")]
        if prog_url:
            return [Media(True, prog_url, quality=f"progressive {prog_h}p")]
    url = best_url((item.get("image_versions2") or {}).get("candidates") or [])
    return [Media(False, url, quality="image")] if url else []


def item_id(item: dict) -> str | None:
    """A post's key: its shortcode, else (a subscriber-only post has none) its pk."""
    return item.get("code") or id_string(item.get("pk")) or id_string(item.get("id"))


def _tagged(m: dict, user: tuple[str, str]) -> bool:
    for t in ((m.get("usertags") or {}).get("in") or []):
        u = (t or {}).get("user") or {}
        if id_string(u.get("pk")) == user[0] or u.get("username") == user[1]:
            return True
    return False


def items_for(item: dict, key: str, folder: Path, poster: str, tagged: tuple[str, str] | None = None) -> list[social.Item]:
    """A post's photos/videos as downloads: `<key>`, or `<key>_1`, `_2`… for several."""
    when = float(item.get("taken_at") or 0)
    caption = ((item.get("caption") or {}).get("text") or "") if isinstance(item.get("caption"), dict) else ""
    loc = item.get("location") if isinstance(item.get("location"), dict) else {}
    lat, lng = loc.get("lat"), loc.get("lng")
    who = ((item.get("user") or {}).get("username") or poster) if isinstance(item.get("user"), dict) else poster
    if tagged and item.get("media_type") == 8 and isinstance(item.get("carousel_media"), list):
        carousel = [c for c in item["carousel_media"] if isinstance(c, dict)]
        has_tags = any((c.get("usertags") or {}).get("in") is not None for c in carousel)
        refs = [m for c in (carousel if not has_tags else [c for c in carousel if _tagged(c, tagged)]) for m in media(c)]
    else:
        refs = media(item)
    out = []
    for i, m in enumerate(refs):
        out.append(social.Item(key, folder, f"{key}_{i + 1}" if len(refs) > 1 else key, m.video, m.url,
                               audio=m.audio, fallback=m.fallback, date=when,
                               lat=lat if isinstance(lat, (int, float)) else None,
                               lng=lng if isinstance(lng, (int, float)) else None,
                               caption=caption, poster=f"@{who}" if who else "", keyword=KEYWORD))
    return out


def reel_items(doc: dict, key: str | None = None, every: bool = False) -> list[dict]:
    """A story/highlight answer's items — every reel in it (`every`), or the one keyed `key`."""
    if not isinstance(doc, dict):
        return []
    out: list[dict] = []
    if isinstance(doc.get("items"), list):
        out += doc["items"]
    reel = doc.get("reel")
    if isinstance(reel, dict) and isinstance(reel.get("items"), list):
        out += reel["items"]
    reels = doc.get("reels")
    if isinstance(reels, dict):
        if every:
            for r in reels.values():
                if isinstance(r, dict) and isinstance(r.get("items"), list):
                    out += r["items"]
        else:
            r = reels.get(key) if key else None
            r = r if isinstance(r, dict) else next((v for v in reels.values() if isinstance(v, dict)), None)
            if r and isinstance(r.get("items"), list):
                out += r["items"]
    if isinstance(doc.get("reels_media"), list):
        for r in doc["reels_media"] if every else doc["reels_media"][:1]:
            if isinstance(r, dict) and isinstance(r.get("items"), list):
                out += r["items"]
    return [x for x in out if isinstance(x, dict)]


def highlights(doc: dict) -> list[tuple[str, str]]:
    """(reel id "highlight:<n>", title) for each highlight in a highlights tray."""
    out = []
    for node in (doc.get("tray") or []) if isinstance(doc, dict) else []:
        hid = id_string((node or {}).get("id"))
        if hid:
            out.append((hid if hid.startswith("highlight:") else f"highlight:{hid}", node.get("title") or "Highlight"))
    return out


def subscriber_reels(doc: dict, user_id: str) -> list[str]:
    """A creator's other story reels in the viewer's tray (subscriber-only "Exclusive" stories)."""
    out = []
    for node in (doc.get("tray") or []) if isinstance(doc, dict) else []:
        owner = (node or {}).get("user") or {}
        rid = id_string(node.get("id"))
        if (id_string(owner.get("pk")) or id_string(owner.get("id"))) == user_id and rid and rid != user_id \
                and rid not in out:
            out.append(rid)
    return out


def reel_downloads(items: list[dict], folder: Path, already: set[str], poster: str) -> list[social.Item]:
    out = []
    for it in items:
        key = item_id(it)
        if key and key not in already:
            out += items_for(it, key, folder, poster)
    return out


def folder_name(title: str) -> str:
    return social.sanitize(title, "Highlight", 60)


# ----------------------------------------------------------------------------- on the drive

def post_id(name: str) -> str | None:
    """`<id>.<ext>` or `<id>_<n>.<ext>` → the id (media files only) — the iPhone's `postID(of:)`."""
    stem, dot, ext = name.rpartition(".")
    if not dot or ext.lower() not in MEDIA_EXTS:
        return None
    us = stem.rfind("_")
    if us > 0 and stem[us + 1:].isdigit() and stem[us + 1:].isascii():
        stem = stem[:us]
    return stem or None


def ids_on_disk(folder: str | Path) -> set[str]:
    """Every post id named in the folder and its subfolders (3 deep; hidden folders and another
    profile's "@" folder skipped) — both the id and the whole stem, as the iPhone takes them."""
    ids: set[str] = set()
    queue = [(Path(folder), 0)]
    while queue and len(queue) < 2000:
        d, depth = queue.pop(0)
        try:
            entries = list(os.scandir(d))
        except OSError:
            continue
        for e in entries:
            if e.name.startswith("."):
                continue
            try:
                is_dir = e.is_dir(follow_symlinks=False)
            except OSError:
                continue
            if is_dir:
                if depth < 3 and not e.name.startswith("@"):
                    queue.append((Path(e.path), depth + 1))
                continue
            pid = post_id(e.name)
            if pid:
                ids.add(pid)
                ids.add(e.name.rpartition(".")[0])
    return ids


def record(folder: str | Path) -> social.Record:
    return social.Record.load(folder, RECORD, FORMAT)


def is_post_id(s: str) -> bool:
    """A post shortcode (10–12 of A–Z a–z 0–9 - _) or a story/highlight pk (15–22 digits) — the iPhone's
    `isInstagramID`."""
    if 15 <= len(s) <= 22 and s.isdigit() and s.isascii():
        return True
    return 10 <= len(s) <= 12 and s.isascii() and all(c.isalnum() or c in "-_" for c in s)


def holds_posts(folder: str | Path) -> bool:
    """Whether the folder itself holds downloaded posts (`<shortcode>.jpg` and the like)."""
    try:
        return any((pid := post_id(n)) and is_post_id(pid) for n in os.listdir(folder))
    except OSError:
        return False


def destination(person: str | Path, handle: str) -> Path:
    """Where @handle goes from `person` (the folder that was right-clicked): the folder itself when it's
    the profile's (its record says so — or, from before records, it's named for the handle and holds
    posts), a subfolder that is, else `<person>/<handle>` — the same folder the iPhone picks. A person's
    folder that merely shares the handle's name ("Jane" for @jane) is not the profile's."""
    person = Path(person)
    want = handle.lower()
    if (record(person).get("handle") or "").lower() == want or (person.name.lower() == want and holds_posts(person)):
        return person
    try:
        subs = sorted((e for e in os.scandir(person) if e.is_dir() and not e.name.startswith(".")), key=lambda e: e.name)
    except OSError:
        subs = []
    for e in subs:
        if (record(e.path).get("handle") or "").lower() == want:
            return Path(e.path)
    for e in subs:
        if e.name.lower() == want:
            return Path(e.path)
    return person / handle


# ----------------------------------------------------------------------------- talking to Instagram (from the page)

API_JS = r"""(function () {
  window.__pbig = window.__pbig || {};
  const id = __ID__, url = __URL__, form = __FORM__, appID = __APP__, asbd = __ASBD__;
  window.__pbig[id] = null;
  (async () => {
    const m = document.cookie.match(/(?:^|;\s*)csrftoken=([^;]+)/);
    const headers = {
      'Accept': '*/*', 'X-IG-App-ID': appID, 'X-ASBD-ID': asbd, 'X-Requested-With': 'XMLHttpRequest',
      'X-IG-WWW-Claim': (() => { try { return sessionStorage.getItem('www-claim-v2') || '0'; } catch (e) { return '0'; } })()
    };
    if (m) headers['X-CSRFToken'] = m[1];
    const init = { method: form === null ? 'GET' : 'POST', headers, credentials: 'include' };
    if (form !== null) { headers['Content-Type'] = 'application/x-www-form-urlencoded'; init.body = form; }
    const ctl = new AbortController();
    const timer = setTimeout(() => ctl.abort(), 45000);
    init.signal = ctl.signal;
    try {
      const r = await fetch(url, init);
      const text = await r.text();
      const claim = r.headers.get('x-ig-set-www-claim');
      if (claim) { try { sessionStorage.setItem('www-claim-v2', claim); } catch (e) {} }
      window.__pbig[id] = { status: r.status, body: text, url: r.url };
    } catch (e) {
      window.__pbig[id] = { status: 0, body: String(e), url: url };
    } finally { clearTimeout(timer); }
  })();
  return true;
})()"""

RESULT_JS = r"""(function () {
  const r = (window.__pbig || {})[__ID__];
  if (!r) return null;
  delete window.__pbig[__ID__];
  return JSON.stringify(r);
})()"""


def api_js(ident: str, url: str, form: str | None, app_id: str) -> tuple[str, str]:
    """The start and result scripts for one call (`fetch` resolves later; the result is polled)."""
    q = json.dumps
    start = (API_JS.replace("__ID__", q(ident)).replace("__URL__", q(url)).replace("__FORM__", q(form))
             .replace("__APP__", q(app_id)).replace("__ASBD__", q(ASBD_ID)))
    return start, RESULT_JS.replace("__ID__", q(ident))


def app_id_from(home_html: str) -> str:
    """The app id the home page Instagram serves this browser declares."""
    m = re.search(r'"X-IG-App-ID":"(\d{6,})"', home_html)
    if m:
        return m.group(1)
    m = re.search(r'"appId":"(\d{6,})"', home_html)
    return m.group(1) if m and m.group(1) in WEB_APP_IDS else APP_ID


# ----------------------------------------------------------------------------- a run

@dataclass
class Outcome:
    profile: Profile | None = None
    found: int = 0                   # new items found (emitted)
    problem: str = ""                # why the profile couldn't be read, or a crawl failed


class _Calls:
    """API calls with the spacing and the backing off (a generator helper)."""

    def __init__(self, app_id: str = APP_ID) -> None:
        self.app_id = app_id
        self.penalty = 0.0

    def call(self, url: str, form: str | None = None):
        """yield from: (status, parsed JSON or None, raw text). Retries "slow down" and server errors."""
        status, text = 0, ""
        for attempt in range(len(BACKOFF) + 1):
            yield ("sleep", GAP * (1 + random.uniform(-JITTER, JITTER)) + self.penalty)
            self.penalty = max(0.0, self.penalty - GAP)
            status, text = yield ("api", url, form, self.app_id)
            if status == 429 or status >= 500 or status == 0:
                if attempt < len(BACKOFF):
                    self.penalty = min(self.penalty + 2.0, 10.0)
                    yield ("note", f"   Instagram asked to slow down (HTTP {status}) — waiting {BACKOFF[attempt]} s")
                    yield ("sleep", BACKOFF[attempt])
                    continue
            break
        doc = None
        if 200 <= status < 300:
            try:
                doc = json.loads(text)
            except ValueError:
                doc = None
        return status, doc, text


def _crawl(calls: _Calls, kind: str, profile: Profile, folder: Path, already: set[str], since: float,
           seen_keys: set[str]):
    """yield from: the new downloads of one feed (posts / tagged / reels), emitted page by page, and
    the failure if it couldn't be read. Newest first, stopping as the iPhone does (module notes)."""
    floor = since - FLOOR if since > 0 else float("inf")
    tagged = (profile.user_id, profile.handle) if kind == "tagged" else None
    max_id = None
    seen = 0
    failure = ""
    for _page in range(400 if kind != "clips" else 200):
        if kind == "clips":
            body = f"target_user_id={profile.user_id}&page_size=12&include_feed_video=true"
            if max_id:
                body += f"&max_id={quote(max_id, safe='')}"
            status, doc, text = yield from calls.call(API + "clips/user/", body)
        else:
            base = f"feed/user/{profile.user_id}/" if kind == "feed" else f"usertags/{profile.user_id}/feed/"
            url = f"{API}{base}?count=33" + (f"&max_id={quote(max_id, safe='')}" if max_id else "")
            status, doc, text = yield from calls.call(url)
        if doc is None:
            failure = refusal(status, text) if status else "the network request failed"
            break
        failure = ""
        batch: list[social.Item] = []
        items = doc.get("items") if isinstance(doc.get("items"), list) else []
        stop = False
        for wrapper in items:
            item = wrapper.get("media") if kind == "clips" and isinstance(wrapper.get("media"), dict) else wrapper
            if not isinstance(item, dict):
                continue
            key = item_id(item)
            if not key:
                continue
            if key in already or key in seen_keys:
                seen += 1
                if seen >= SEEN_RUN and float(item.get("taken_at") or 0) < floor:
                    stop = True
                    break
                continue
            seen = 0
            seen_keys.add(key)
            batch += items_for(item, key, folder, profile.handle, tagged)
        if batch:
            yield ("emit", batch)
        if stop:
            break
        paging = doc.get("paging_info") if isinstance(doc.get("paging_info"), dict) else {}
        more = paging.get("more_available", doc.get("more_available", False))
        max_id = paging.get("max_id") or doc.get("next_max_id")
        if not more or not max_id or not items:
            break
    return failure


def run(handle: str, folder: Path, already: set[str], opts: social.Options, since: float = 0,
        known_user_id: str = ""):
    """One profile into `folder` (see the module notes). A generator: yields requests, returns an Outcome."""
    out = Outcome()
    calls = _Calls()
    home_status, home_html = yield ("api", HOME, None, APP_ID)
    if 200 <= home_status < 300:
        calls.app_id = app_id_from(home_html)

    yield ("note", f"Looking up @{handle}…")
    profile = None
    problem = ""
    status, doc, text = yield from calls.call(f"{API}users/web_profile_info/?username={quote(handle, safe='')}")
    if doc is not None:
        profile = profile_from_info(doc, handle)
    missing = status == 404
    if profile is None:
        if status and status != 404 and not (200 <= status < 300):
            problem = refusal(status, text)
        s2, doc2, _t2 = yield from calls.call(
            f"{API}web/search/topsearch/?context=blended&query={quote(handle.lower(), safe='')}")
        if doc2 is not None:
            profile = profile_from_search(doc2, handle)
    if profile is None and known_user_id:
        profile = Profile(known_user_id, handle)
    if profile is None:
        out.problem = (f"Instagram has no account named @{handle} — check the spelling." if missing
                       else problem or f"Couldn’t open @{handle}. Check the handle, that you’re logged in, "
                                       "and that the profile is public or one you follow.")
        return out
    out.profile = profile
    yield ("profile", profile)
    seen_keys: set[str] = set()
    found = [0]

    def counting(gen):
        result = None
        try:
            req = next(gen)
            while True:
                if req[0] == "emit":
                    found[0] += len(req[1])
                answer = yield req
                req = gen.send(answer)
        except StopIteration as stop:
            result = stop.value
        return result

    yield ("note", "Finding posts…")
    feed_failure = yield from counting(_crawl(calls, "feed", profile, folder, already, since, seen_keys))
    if opts.tagged:
        yield ("note", "Finding tagged posts…")
        yield from counting(_crawl(calls, "tagged", profile, folder, already, since, seen_keys))
    yield ("note", "Finding reels…")
    yield from counting(_crawl(calls, "clips", profile, folder, already, since, seen_keys))
    if opts.stories:
        yield ("note", "Finding stories…")
        stories: dict[str, dict] = {}
        for path in (f"feed/reels_media/?reel_ids={profile.user_id}", f"feed/user/{profile.user_id}/reel_media/"):
            _s, doc, _t = yield from calls.call(API + path)
            for it in reel_items(doc or {}, every=True):
                stories.setdefault(id_string(it.get("pk")) or id_string(it.get("id")) or str(len(stories)), it)
        _s, tray, _t = yield from calls.call(API + "feed/reels_tray/")
        for rid in subscriber_reels(tray or {}, profile.user_id):
            _s, doc, _t = yield from calls.call(f"{API}feed/reels_media/?reel_ids={rid.replace(':', '%3A')}")
            for it in reel_items(doc or {}, every=True):
                stories.setdefault(id_string(it.get("pk")) or id_string(it.get("id")) or str(len(stories)), it)
        batch = reel_downloads(list(stories.values()), folder / STORIES, already | seen_keys, profile.handle)
        if batch:
            found[0] += len(batch)
            yield ("emit", batch)
        yield ("note", "Finding highlights…")
        _s, tray, _t = yield from calls.call(f"{API}highlights/{profile.user_id}/highlights_tray/")
        for rid, title in highlights(tray or {}):
            _s, doc, _t = yield from calls.call(f"{API}feed/reels_media/?reel_ids={rid.replace(':', '%3A')}")
            batch = reel_downloads(reel_items(doc or {}, key=rid), folder / folder_name(title),
                                   already | seen_keys, profile.handle)
            if batch:
                found[0] += len(batch)
                yield ("emit", batch)
    out.found = found[0]
    if feed_failure:
        out.problem = f"Couldn’t check for new posts — {feed_failure}"
    return out
