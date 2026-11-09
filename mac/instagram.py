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

**Finding the account** (`look_up`, Nov 9): `web_profile_info` answers 404 or `"user": null` for accounts that
plainly exist when it's throttling, and `web/search/topsearch/` is gone from the site — so the old "no account named
@…" came for real, public, correctly spelled handles. Now four ways in turn: `web_profile_info` (the declared web
app id, then the standard one — another app's id on the home page, Threads' say, is never used); the profile page
itself, whose ids are each confirmed by `users/<id>/info/` (the page names the viewer too); then the site's searches
(`fbsearch/web/top_serp/`, topsearch, `users/search/`) — an exact username match only. "No such account" is said
only when the profile page itself says it; otherwise the problem line lists what each step answered.
A lookup step told to slow down (429) isn't waited out — the next way is tried at once (each endpoint has its own
limit; the profile page, what a browser loads anyway, goes first, and an id written beside the handle there is
taken even when `users/<id>/info/` is throttled). Every way throttled: one 60 s pause and one retry, then "Instagram
is limiting requests from this account — wait 10–15 minutes". The crawl's own 429 backoff is 15/45/120 s.

**When Instagram refuses its internal reads** (Nov 9, a real log: every `/api/v1/` read 404, `users/search` 400, for
an account the person was looking at): the window opens the real pages, as the person does — `("visit", url,
scroll, press)` loads it in the window's browser, whose watcher (fanfix.HOOK_JS, put into Instagram's pages) keeps
every data answer the page receives, and hands them back with the page's HTML (`page_docs` reads the answers and
the `<script type="application/json">` blobs, layers of ScheduledServerJS/__bbox/Relay deep). The account comes from
its profile page (`profile_from_page`: the object with the exact username and an id), and from then on the API is
asked from that real page (`api_page`) rather than a bare one. A tab whose feed is refused — posts, tagged, reels —
is read from its page scrolled to the end (`_watch`, `posts_in`: post objects carry the API's shapes; another
account's suggested posts left out); stories from instagram.com/stories/<handle>/ and each highlight from its own
page, the desktop site's "View story" pressed (`reel_items_in`); highlight names from the profile page's data
(`highlights_in`).

**How it asks Instagram — the iPhone's way (Nov 9).** As `InstagramService.apiData` does: each call straight from
here (`SocialWindow._direct`) with the login's cookies and the headers Instagram's own site sends — the profile page
as Referer (`_Calls.referer`), the same-origin Sec-Fetch trio, X-IG-App-ID / X-ASBD-ID / X-CSRFToken / X-IG-WWW-Claim;
only when Instagram refuses that (`is_refusal`: 400/401/403, a login page) is the call asked again from the logged-in
page, which then takes over (`via_browser`). Paced as the iPhone paces (`_Calls.call`: 0.17 s ± half, a rare 0.5–1.5 s
pause, +2.5 s per "slow down" up to 12 s easing off per call, retries after 2 s and 4 s). The lookup runs in the
iPhone's order (`look_up`), and reading the pages themselves is only the last resort. Before this every call was a
`fetch()` from a bare robots.txt page, which Instagram answered 404 for everything.

**The in-page route.** Every API call made in the page is a `fetch()` from a page on
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
GAP, JITTER = 0.17, 0.5          # seconds between API calls, ± half — the iPhone's InstagramService.Pacer
RARE_PAUSE = (0.05, 0.5, 1.5)    # 1 call in 20 waits 0.5–1.5 s more: a person stops now and then
PENALTY_STEP, PENALTY_MAX = 2.5, 12.0   # each "slow down" widens the gap this much (up to this), easing off per call
BACKOFF = (2, 4)                 # seconds before retrying a throttled / failed call (the iPhone's 2 s × attempt)
LOOKUP_PAUSE = 60                # every way into the profile throttled: one pause, then one quiet retry

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


def profile_from_user(user: dict, handle: str) -> Profile | None:
    """From a full user object (`users/<id>/info/`'s "user") — only when it's the handle asked for."""
    if not isinstance(user, dict) or (user.get("username") or "").lower() != handle.lower():
        return None
    uid = id_string(user.get("pk")) or id_string(user.get("pk_id")) or id_string(user.get("id"))
    if not uid:
        return None
    hd = user.get("hd_profile_pic_url_info") if isinstance(user.get("hd_profile_pic_url_info"), dict) else {}
    return Profile(uid, user.get("username") or handle, user.get("full_name") or "",
                   hd.get("url") or user.get("profile_pic_url") or "", int(user.get("media_count") or 0),
                   user.get("is_private", True) is not False)


_USER_ID_KEYS = ("pk", "pk_id", "id", "strong_id__", "user_id", "fbid_v2")


def profile_in(doc, handle: str, depth: int = 0) -> Profile | None:
    """Any answer (a search of whichever kind Instagram serves this year, or what a page loaded): the first object
    whose username is the handle and that has an id. Deep: a page's data sits inside layers of
    ScheduledServerJS / __bbox / Relay wrappers."""
    if depth > 120:
        return None
    if isinstance(doc, dict):
        uid = next((id_string(doc.get(k)) for k in _USER_ID_KEYS if id_string(doc.get(k))), None)
        if (doc.get("username") or "").lower() == handle.lower() and uid and uid.isdigit():
            edge = doc.get("edge_owner_to_timeline_media") if isinstance(doc.get("edge_owner_to_timeline_media"), dict) else {}
            try:
                posts = int(doc.get("media_count") or edge.get("count") or 0)
            except (TypeError, ValueError):
                posts = 0
            return Profile(uid, doc.get("username"), doc.get("full_name") or "", doc.get("profile_pic_url") or "", posts,
                           doc.get("is_private", True) is not False)
        for v in doc.values():
            if isinstance(v, (dict, list)) and (p := profile_in(v, handle, depth + 1)):
                return p
    elif isinstance(doc, list):
        for v in doc:
            if isinstance(v, (dict, list)) and (p := profile_in(v, handle, depth + 1)):
                return p
    return None


_PAGE_IDS = (r'"profilePage_(\d+)"', r'"profile_id"\s*:\s*"(\d+)"', r'"target_id"\s*:\s*"(\d+)"',
             r'"page_id"\s*:\s*"profilePage_(\d+)"', r'"owner_id"\s*:\s*"(\d+)"', r'"user_id"\s*:\s*"(\d+)"')


def ids_beside(html: str, handle: str) -> list[str]:
    """Ids a page writes right beside the handle itself ("id":"…","username":"<handle>" or the other way round) —
    the account's own, not the viewer's or a suggestion's."""
    out: list[str] = []
    h = re.escape(handle)
    for pat in (rf'"(?:pk|id|pk_id)"\s*:\s*"?(\d+)"?\s*,\s*"username"\s*:\s*"{h}"',
                rf'"username"\s*:\s*"{h}"[^{{}}]{{0,600}}?"(?:pk|id|pk_id)"\s*:\s*"?(\d+)'):
        for m in re.finditer(pat, html or "", re.I):
            if m.group(1) not in out:
                out.append(m.group(1))
    return out


def ids_in_page(html: str, handle: str = "") -> list[str]:
    """The account ids a profile page names, surest first (`ids_beside` the handle, then `profilePage_<id>`,
    `profile_id`…) — each is checked against the handle before it's used (`users/<id>/info/`): the page also
    names the logged-in viewer and people it suggests."""
    out = ids_beside(html, handle) if handle else []
    for pat in _PAGE_IDS:
        for m in re.finditer(pat, html or ""):
            if m.group(1) not in out:
                out.append(m.group(1))
    return out


def page_missing(status: int, html: str) -> bool:
    """The profile page's own title saying there's no such page — read from <title> only: every Instagram page
    carries "Sorry, this page isn't available" and "httpErrorPage" in its built-in strings and scripts, existing
    accounts' included (believing those said "no account" for real ones, Nov 9). A 404 counts too. Even then it's
    only one witness: `look_up` says "no account" only when `web_profile_info` agrees."""
    if status == 404:
        return True
    m = re.search(r"<title[^>]*>([^<]{0,300})</title>", html or "", re.I)
    return bool(m) and "page not found" in m.group(1).lower()


def page_docs(seen: dict) -> list:
    """The JSON in what a visited page loaded (`("visit", …)`'s answer: its own fetch/XHR answers and the data
    written into it) — whole answers, React/Relay streams row by row, `<script type="application/json">` blobs."""
    import fanfix                                          # its parser takes any of those shapes
    docs: list = []
    for text in (seen or {}).get("answers") or []:
        if isinstance(text, str):
            docs += fanfix.documents(text)
    html = (seen or {}).get("html") or ""
    for m in re.finditer(r"<script[^>]*type=\"application/json\"[^>]*>([\s\S]*?)</script>", html):
        docs += fanfix.documents(m.group(1))
    return docs


def page_names(seen: dict, handle: str) -> bool:
    """Whether the page is the account's own profile, by what it shows: its title ("savannah (@savmaritheia) •
    Instagram photos and videos") or its app link (instagram://user?username=…)."""
    html = (seen or {}).get("html") or ""
    m = re.search(r"<title[^>]*>([^<]{0,400})</title>", html, re.I)
    h = re.escape(handle)
    return bool(m and re.search(rf"\(@{h}\)", m.group(1), re.I)) or \
        bool(re.search(rf"instagram://user\?username={h}[\"&]", html, re.I))


def profile_from_page(seen: dict, handle: str) -> Profile | None:
    """The account as the profile page itself has it: the object with the exact username and an id, in what the
    page loaded to draw the profile — else an id written beside the handle in the page, or in its
    `instapp:owner_user_id` meta — else, when the page plainly is the account's (`page_names`), the account with
    no id: everything is then read from the pages, which need only the handle."""
    for doc in page_docs(seen):
        p = profile_in(doc, handle)
        if p is not None:
            return p
    html = (seen or {}).get("html") or ""
    beside = ids_beside(html, handle)
    if beside:
        return Profile(beside[0], handle)
    if page_names(seen, handle):
        m = re.search(r'instapp:owner_user_id"\s+content="(\d+)"', html) or \
            re.search(r'content="(\d+)"\s+property="instapp:owner_user_id"', html)
        return Profile(m.group(1) if m else "", handle)
    return None


def dump_visit(seen: dict, handle: str) -> str:
    """What a visited page loaded, saved to ~/Library/Logs/Safe Finder/instagram-<handle>-<time>.json — for when its
    data didn't name the account, so the next fix is made from Instagram's real answers. Stays on this Mac."""
    import time as _time
    folder = Path.home() / "Library" / "Logs" / "Safe Finder"
    try:
        folder.mkdir(parents=True, exist_ok=True)
        path = folder / f"instagram-{handle}-{_time.strftime('%Y%m%d-%H%M%S')}.json"
        doc = {"url": (seen or {}).get("url"), "status": (seen or {}).get("status"),
               "answers": [a[:3_000_000] for a in (seen or {}).get("answers") or [] if isinstance(a, str)][:400],
               "html": ((seen or {}).get("html") or "")[:8_000_000]}
        path.write_text(json.dumps(doc, ensure_ascii=False), encoding="utf-8")
        return str(path)
    except OSError:
        return ""


def posts_in(doc, out: list | None = None, depth: int = 0) -> list[dict]:
    """Every post object in what a page loaded: a dict with a shortcode and Instagram's media fields — the web's
    GraphQL answers carry the same shapes as the API's feed (`image_versions2`, `carousel_media`,
    `video_versions`, `taken_at`, `caption`, `user`), so `items_for` reads them alike."""
    out = [] if out is None else out
    if depth > 120:
        return out
    if isinstance(doc, dict):
        if isinstance(doc.get("code"), str) and any(k in doc for k in ("image_versions2", "carousel_media",
                                                                       "video_versions")):
            out.append(doc)
            return out
        for v in doc.values():
            if isinstance(v, (dict, list)):
                posts_in(v, out, depth + 1)
    elif isinstance(doc, list):
        for v in doc:
            if isinstance(v, (dict, list)):
                posts_in(v, out, depth + 1)
    return out


def _theirs(u, profile_id: str, handle: str) -> bool:
    """A story item's owner is the account: by username, else by number (when either is known)."""
    if not isinstance(u, dict):
        return True
    name = (u.get("username") or "").lower()
    if name and handle:
        return name == handle.lower()
    uid = id_string(u.get("pk")) or id_string(u.get("id"))
    return not profile_id or not uid or uid == profile_id


def reel_items_in(doc, profile_id: str, out: list | None = None, depth: int = 0, handle: str = "") -> list[dict]:
    """Every story item in what a story or highlight page loaded: a dict with a pk, Instagram's media fields and a
    time, not a carousel's child — the account's own (a viewer's tray holds other people's too)."""
    out = [] if out is None else out
    if depth > 120:
        return out
    if isinstance(doc, dict):
        if (id_string(doc.get("pk")) or id_string(doc.get("id"))) and doc.get("taken_at") and \
                any(k in doc for k in ("image_versions2", "video_versions")):
            if _theirs(doc.get("user") if isinstance(doc.get("user"), dict) else doc.get("owner"), profile_id, handle):
                out.append(doc)
            return out
        for v in doc.values():
            if isinstance(v, (dict, list)):
                reel_items_in(v, profile_id, out, depth + 1, handle)
    elif isinstance(doc, list):
        for v in doc:
            if isinstance(v, (dict, list)):
                reel_items_in(v, profile_id, out, depth + 1, handle)
    return out


def highlights_in(doc, out: list | None = None, depth: int = 0) -> list[tuple[str, str]]:
    """(reel id "highlight:<n>", title) for every highlight a page's data names (the profile page lists them)."""
    out = [] if out is None else out
    if depth > 120:
        return out
    if isinstance(doc, dict):
        hid = id_string(doc.get("id"))
        if hid and hid.startswith("highlight:") and isinstance(doc.get("title"), str):
            if hid not in [h for h, _t in out]:
                out.append((hid, doc["title"] or "Highlight"))
        for v in doc.values():
            if isinstance(v, (dict, list)):
                highlights_in(v, out, depth + 1)
    elif isinstance(doc, list):
        for v in doc:
            if isinstance(v, (dict, list)):
                highlights_in(v, out, depth + 1)
    return out


VIEW_STORY = r"^\s*view story\s*$"           # the desktop site's button in front of someone's stories


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
  const id = __ID__, url = __URL__, form = __FORM__, appID = __APP__, asbd = __ASBD__, ref = __REF__;
  window.__pbig[id] = null;
  (async () => {
    const m = document.cookie.match(/(?:^|;\s*)csrftoken=([^;]+)/);
    const headers = {
      'Accept': '*/*', 'X-IG-App-ID': appID, 'X-ASBD-ID': asbd, 'X-Requested-With': 'XMLHttpRequest',
      'X-IG-WWW-Claim': (() => { try { return sessionStorage.getItem('www-claim-v2') || '0'; } catch (e) { return '0'; } })()
    };
    if (m) headers['X-CSRFToken'] = m[1];
    if (!appID) {                                   // a page, read as the browser reads one: no API headers
      for (const k of Object.keys(headers)) delete headers[k];
      headers['Accept'] = 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8';
    }
    const init = { method: form === null ? 'GET' : 'POST', headers, credentials: 'include' };
    if (ref) init.referrer = ref;                   // the profile page, as Instagram's own site asks from
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


def api_js(ident: str, url: str, form: str | None, app_id: str, referer: str = "") -> tuple[str, str]:
    """The start and result scripts for one call (`fetch` resolves later; the result is polled)."""
    q = json.dumps
    start = (API_JS.replace("__ID__", q(ident)).replace("__URL__", q(url)).replace("__FORM__", q(form))
             .replace("__APP__", q(app_id)).replace("__ASBD__", q(ASBD_ID)).replace("__REF__", q(referer)))
    return start, RESULT_JS.replace("__ID__", q(ident))


def app_id_from(home_html: str) -> str:
    """The app id the home page Instagram serves this browser declares."""
    for pat in (r'"X-IG-App-ID":"(\d{6,})"', r'"appId":"(\d{6,})"', r'"app_id":"(\d{6,})"'):
        for m in re.finditer(pat, home_html or ""):
            if m.group(1) in WEB_APP_IDS:                  # another app's id (Threads, ads…) answers nothing here
                return m.group(1)
    return APP_ID


# ----------------------------------------------------------------------------- a run

@dataclass
class Outcome:
    profile: Profile | None = None
    found: int = 0                   # new items found (emitted)
    problem: str = ""                # why the profile couldn't be read, or a crawl failed


def is_refusal(status: int, text: str) -> bool:
    """Whether Instagram turned a call away for who/what was asking (rather than "slow down" or "no such thing"):
    400/401/403, a login or checkpoint flag, or a page where JSON belongs — the iPhone's `isRefusal`. A refused
    call is asked again from the logged-in page (the window's route)."""
    if status in (400, 401, 403):
        return True
    try:
        j = json.loads(text)
    except (ValueError, TypeError):
        return 200 <= status < 300
    if not isinstance(j, dict):
        return False
    msg = str(j.get("message") or "")
    return j.get("require_login") is True or "checkpoint_url" in j or \
        msg in ("checkpoint_required", "challenge_required", "login_required", "useragent mismatch")


class _Calls:
    """API calls with the iPhone's pacing (a generator helper): a gap of GAP ± JITTER, a rare longer pause, and a
    penalty that widens the gap after each "slow down" and eases off call by call. Every call says which page it's
    asked from (`referer`, the profile page once the handle is known) — what Instagram's own site sends."""

    def __init__(self, app_id: str = APP_ID) -> None:
        self.app_id = app_id
        self.penalty = 0.0
        self.referer = HOME

    def call(self, url: str, form: str | None = None, retries: int | None = None, page: bool = False):
        """yield from: (status, parsed JSON or None, raw text). A throttled (429), failed (5xx) or unanswered call is
        tried again `retries` times (both of BACKOFF by default) — then it's the caller's to move on."""
        status, text = 0, ""
        backoff = BACKOFF if retries is None else BACKOFF[:retries]
        for attempt in range(len(backoff) + 1):
            gap = GAP * (1 + random.uniform(-JITTER, JITTER)) + self.penalty
            if random.random() < RARE_PAUSE[0]:
                gap += random.uniform(RARE_PAUSE[1], RARE_PAUSE[2])
            yield ("sleep", gap)
            self.penalty = max(0.0, self.penalty - GAP)
            status, text = yield ("api", url, form, "" if page else self.app_id, self.referer)
            if status == 429 or status >= 500 or status == 0:
                if status == 429:
                    self.penalty = min(self.penalty + PENALTY_STEP, PENALTY_MAX)
                if attempt < len(backoff):
                    yield ("note", f"   Instagram asked to slow down (HTTP {status}) — trying again in {backoff[attempt]} s")
                    yield ("sleep", backoff[attempt])
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


def _said(name: str, status: int, doc) -> str:
    """One lookup step's answer, for the log and the problem line."""
    if not status:
        return f"{name}: no answer"
    if 200 <= status < 300:
        return f"{name}: HTTP {status}, " + ("not this account" if doc is not None else "not JSON")
    return f"{name}: HTTP {status}"


def look_up(calls: _Calls, handle: str):
    """yield from: (Profile | None, missing, what each step said). The iPhone's order (`lookupProfile`), then the
    page as a last resort:
    1. `users/web_profile_info/` — retried through "slow down" (BACKOFF), with the declared web app id, then the
       standard one;
    2. the site's searches — `web/search/topsearch/`, `fbsearch/web/top_serp/`, `users/search/` (an exact
       username match only);
    3. the profile page's HTML: the ids it names, each confirmed by `users/<id>/info/`;
    4. the profile page opened in the window (`profile_from_page`) — what it loads to draw the profile, or plainly
       its title "(@handle)": found by handle, everything then read from the pages.
    "No such account" only when the page says it and `web_profile_info` agrees. Once a step has been told to slow
    down, the rest are asked once each (no retries piling up the wait)."""
    q = quote(handle, safe="")
    tried: list[str] = []
    throttled = 0
    info_gone = False

    def note(name: str, status: int, doc=None, text: str = "") -> None:
        nonlocal throttled
        if status == 429:
            throttled += 1
            tried.append(f"{name}: slowed down (HTTP 429)")
        elif status in (401, 403):
            tried.append(refusal(status, text))
        else:
            tried.append(_said(name, status, doc))

    apps = [calls.app_id] + ([APP_ID] if calls.app_id != APP_ID else [])
    for app in apps:
        calls.app_id = app
        status, doc, text = yield from calls.call(f"{API}users/web_profile_info/?username={q}")
        profile = profile_from_info(doc, handle) if doc is not None else None
        if profile is not None:
            return profile, False, tried
        info_gone = info_gone or status == 404
        note("profile info" + ("" if app == apps[0] else " (web app id)"), status, doc, text)
        if status == 429:
            break
    calls.app_id = apps[0]
    for name, path in (("top search", f"web/search/topsearch/?context=blended&query={quote(handle.lower(), safe='')}"),
                       ("search", f"fbsearch/web/top_serp/?enable_metadata=true&query={q}"),
                       ("user search", f"users/search/?q={q}&count=30")):
        status, doc, text = yield from calls.call(API + path, retries=0 if throttled else 1)
        profile = profile_in(doc, handle) if doc is not None else None
        if profile is not None:
            return profile, False, tried
        note(name, status, doc, text)
    status, _doc, html = yield from calls.call(f"{HOME}{q}/", retries=0 if throttled else 1, page=True)
    html = html if isinstance(html, str) else ""
    page_gone = bool(status) and status != 429 and page_missing(status, html)
    if 200 <= status < 300 and not page_gone:
        beside = ids_beside(html, handle)
        for uid in ids_in_page(html, handle)[:4]:
            s2, d2, _t2 = yield from calls.call(f"{API}users/{uid}/info/", retries=0 if throttled else 1)
            profile = profile_from_user((d2 or {}).get("user") if isinstance(d2, dict) else None, handle)
            if profile is not None:
                return profile, False, tried
            if beside and uid == beside[0] and s2 in (0, 429):
                return Profile(uid, handle), False, tried
    tried.append("profile page: " + ("says not found" if page_gone else f"HTTP {status}" if status else "no answer"))
    for line in tried:
        yield ("note", f"   {line}")
    # 4. the page itself, as the person sees it
    seen = yield ("visit", f"{HOME}{q}/", False)
    profile = profile_from_page(seen or {}, handle)
    if profile is not None:
        saved = "" if profile.user_id and profile.posts else dump_visit(seen or {}, handle)
        yield ("note", f"   found @{profile.handle} on its profile page" +
                       (f" (account {profile.user_id})" if profile.user_id else
                        " — Instagram didn't give its number, so everything is read from the pages") +
                       (f"; what the page loaded is saved in {saved}" if saved else ""))
        return profile, False, tried
    page_gone = page_gone or page_missing(int((seen or {}).get("status") or 200), (seen or {}).get("html") or "")
    if (seen or {}).get("answers"):
        saved = dump_visit(seen or {}, handle)
        if saved:
            yield ("note", f"   what the profile page loaded is saved in {saved} — send it over")
    if throttled and throttled >= len(tried) - 1:
        tried = ["Instagram is limiting requests from this account right now (HTTP 429). Wait 10–15 minutes before "
                 "pressing Download again — trying again and again keeps the limit going"]
    return None, page_gone and info_gone, tried


WATCH_PATHS = {"feed": "", "tagged": "tagged/", "clips": "reels/"}


def _owned(item: dict, profile: Profile) -> bool:
    """A post the profile itself posted (the page also shows suggested accounts' posts)."""
    u = item.get("user") if isinstance(item.get("user"), dict) else item.get("owner")
    if not isinstance(u, dict):
        return True
    uid, name = id_string(u.get("pk")) or id_string(u.get("id")), (u.get("username") or "").lower()
    if name:
        return name == profile.handle.lower()
    return not profile.user_id or uid == profile.user_id      # no name to go by: its number, when known


def _watch(kind: str, profile: Profile, folder: Path, already: set[str], seen_keys: set[str]):
    """yield from: the posts of one tab of the profile (posts / tagged / reels) read from the page itself — opened
    in the window and scrolled to its end, every post object the page loaded taken (`posts_in`). For when
    Instagram refuses its own feed endpoints to these reads. Returns how many answers the page loaded."""
    tagged = (profile.user_id, profile.handle) if kind == "tagged" else None
    seen = yield ("visit", f"{HOME}{quote(profile.handle, safe='')}/{WATCH_PATHS[kind]}", True)
    batch: list[social.Item] = []
    for doc in page_docs(seen or {}):
        for item in posts_in(doc):
            u = item.get("user") if isinstance(item.get("user"), dict) else {}
            if not profile.user_id and (u.get("username") or "").lower() == profile.handle.lower():
                profile.user_id = id_string(u.get("pk")) or id_string(u.get("id")) or ""   # learnt from its own posts
            key = item_id(item)
            if not key or key in already or key in seen_keys or (kind != "tagged" and not _owned(item, profile)):
                continue
            seen_keys.add(key)
            batch += items_for(item, key, folder, profile.handle, tagged)
    if batch:
        yield ("emit", batch)
    return len((seen or {}).get("answers") or [])


def run(handle: str, folder: Path, already: set[str], opts: social.Options, since: float = 0,
        known_user_id: str = ""):
    """One profile into `folder` (see the module notes). A generator: yields requests, returns an Outcome."""
    out = Outcome()
    calls = _Calls()
    home_status, home_html = yield ("api", HOME, None, "")
    if 200 <= home_status < 300:
        calls.app_id = app_id_from(home_html)

    calls.referer = f"{HOME}{quote(handle, safe='')}/"
    yield ("note", f"Looking up @{handle}…")
    profile, missing, tried = yield from look_up(calls, handle)
    if profile is None and known_user_id:
        profile = Profile(known_user_id, handle)
        yield ("note", f"   using @{handle}'s id from the folder's record ({known_user_id})")
    if profile is None:
        login = next((t for t in tried if t.startswith(("Instagram asked for a login", "Instagram wants to check"))), "")
        if login:
            tried = [login.rstrip(". ")]                     # one thing to do, said once
        limited = len(tried) == 1 and tried[0].startswith(("Instagram is limiting", "Instagram asked for a login",
                                                           "Instagram wants to check"))
        out.problem = (f"Instagram has no account named @{handle} — check the spelling." if missing else
                       f"Couldn’t open @{handle} — {tried[0]}." if limited else
                       f"Couldn’t open @{handle} — " + "; ".join(t.rstrip(". ") for t in tried) + ". Check that you’re logged in in the "
                       "window above and that the profile is public or one you follow.")
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

    def tab(kind: str, label: str):
        """yield from: one tab through the API, else read from the page itself. Returns the failure, if both."""
        yield ("note", f"Finding {label}…")
        before = found[0]
        if profile.user_id:
            failure = yield from counting(_crawl(calls, kind, profile, folder, already, since, seen_keys))
            if not failure:
                return ""
            yield ("note", f"   Instagram's {label} feed didn't answer ({failure.rstrip('.')}) — reading them from the "
                           "profile page instead")
        else:
            failure = "Instagram didn't give the account's number"
        loaded = yield from counting(_watch(kind, profile, folder, already, seen_keys))
        yield ("note", f"   {found[0] - before} new from the page" + ("" if loaded else " (it loaded nothing)"))
        return "" if loaded else failure

    feed_failure = yield from tab("feed", "posts")
    if opts.tagged:
        yield from tab("tagged", "tagged posts")
    yield from tab("clips", "reels")
    if opts.stories:
        yield ("note", "Finding stories…")
        stories: dict[str, dict] = {}
        refused = [] if profile.user_id else ["no account number", "no account number"]
        for path in ((f"feed/reels_media/?reel_ids={profile.user_id}", f"feed/user/{profile.user_id}/reel_media/")
                     if profile.user_id else ()):
            st, doc, _t = yield from calls.call(API + path)
            if doc is None:
                refused.append(f"HTTP {st}" if st else "no answer")
            for it in reel_items(doc or {}, every=True):
                stories.setdefault(id_string(it.get("pk")) or id_string(it.get("id")) or str(len(stories)), it)
        tray = None
        if profile.user_id:
            _s, tray, _t = yield from calls.call(API + "feed/reels_tray/")
        for rid in subscriber_reels(tray or {}, profile.user_id):
            _s, doc, _t = yield from calls.call(f"{API}feed/reels_media/?reel_ids={rid.replace(':', '%3A')}")
            for it in reel_items(doc or {}, every=True):
                stories.setdefault(id_string(it.get("pk")) or id_string(it.get("id")) or str(len(stories)), it)
        if len(refused) == 2:
            yield ("note", "   opening the stories page" if not profile.user_id else
                   f"   Instagram didn't answer for the stories ({', '.join(refused)}) — opening them on the page instead")
            seen = yield ("visit", f"{HOME}stories/{quote(profile.handle, safe='')}/", False, VIEW_STORY)
            for doc in page_docs(seen or {}):
                for it in reel_items_in(doc, profile.user_id, handle=profile.handle):
                    stories.setdefault(id_string(it.get("pk")) or id_string(it.get("id")) or str(len(stories)), it)
        batch = reel_downloads(list(stories.values()), folder / STORIES, already | seen_keys, profile.handle)
        if batch:
            found[0] += len(batch)
            yield ("emit", batch)
        yield ("note", "Finding highlights…")
        st, tray = 0, None
        if profile.user_id:
            st, tray, _t = yield from calls.call(f"{API}highlights/{profile.user_id}/highlights_tray/")
        listed = highlights(tray or {})
        if tray is None:
            yield ("note", f"   Instagram didn't answer for the highlights ({f'HTTP {st}' if st else 'no answer'}) — "
                           "reading them from the profile page instead")
            seen = yield ("visit", f"{HOME}{quote(profile.handle, safe='')}/", False)
            listed = []
            for doc in page_docs(seen or {}):
                highlights_in(doc, listed)
        for rid, title in listed:
            doc = None
            if profile.user_id:
                _s, doc, _t = yield from calls.call(f"{API}feed/reels_media/?reel_ids={rid.replace(':', '%3A')}")
            items = reel_items(doc or {}, key=rid)
            if doc is None:                                  # the highlight's own page, as the person opens it
                seen = yield ("visit", f"{HOME}stories/highlights/{rid.split(':', 1)[-1]}/", False, VIEW_STORY)
                items = [it for d in page_docs(seen or {}) for it in reel_items_in(d, profile.user_id, handle=profile.handle)]
            batch = reel_downloads(items, folder / folder_name(title), already | seen_keys, profile.handle)
            if batch:
                found[0] += len(batch)
                yield ("emit", batch)
    out.found = found[0]
    if feed_failure:
        out.problem = f"Couldn’t check for new posts — {feed_failure}"
    return out
