"""TikTok profiles for Safe Finder — the iPhone app's `TikTokService` on the Mac (no Qt here;
tiktok_downloader.py is the window, social.py downloads).

**How a profile is read** — exactly as the iPhone does: through the public **tikwm.com** resolver (no login,
no request signing; only the public handle is sent, nothing is uploaded). `user/posts` pages the profile's
whole video list, 35 at a time, about one request a second (its free limit); each post carries its id, post
date, caption, like count (`digg_count`) and either a watermark-free HD video (`hdplay`), a standard one
(`play`) or — for a slideshow — its `images`. A video the listing gives no HD address for is resolved one at
a time through the single-video endpoint with `hd=1`. Requests go out as tikwm's own pages send them
(Referer, Origin, X-Requested-With); a throttled answer (`code != 0`) is retried with a growing pause and the
two hosts taken in turn; a Cloudflare block page ends the plain requests and hands the call to a real
browser (`Resolver.browser` — the window's Chromium, where the person can answer a check), whose clearance
cookie and User-Agent the plain requests then reuse.

**The same names as the iPhone**: videos are `<post id>.mp4`, a slideshow's photos `<post id>_<n>.jpg`, in an
`@handle` folder inside the folder the download was started from. So either app sees what the other has by
the names alone.

**The same profile, found again.** A folder is a TikTok profile's when (first that applies):
1. it holds the shared record, `.tiktok.json` (below);
2. the iPhone app's metadata backup on the drive (`.Photo Browser Metadata/metadata.json` → `tiktokFolders`)
   lists it — that carries the handle, every id downloaded and the likes the iPhone noted;
3. it's named `@something` and holds files named like TikTok post ids (15–20 digits) — the iPhone's own
   rule for reconnecting a folder (`ProfileReconnect.classifyTikTok`).
A download from the person's folder goes into the child that is that handle's (any of the three), else a new
`@handle`; from inside the profile's folder, into it. Never a second folder for a profile that's here.

**The shared record** — `<profile folder>/.tiktok.json`, read and written by both apps (`SocialRecord.swift`,
kind `.tiktok`): `handle`, `author_id`, `nickname`, every post id `downloaded` (ids are only ever added), the
profile's video count at the last full listing, and **`likes`** — post id → like count — with
`likes_updated`. "Already downloaded" is the record's ids, the iPhone backup's ids and the ids in the
folder's file names, together.

**Likes are recalculated on every run.** The iPhone stops paging at a long run of posts it already has; here
every run lists the whole profile, so each video's like count is read again and the record's `likes` is
brought up to date (a post that's gone from TikTok keeps its last count). Safe Finder sorts by it
("Reactions / Likes") and shows it in the viewer's Info; the iPhone takes the record's counts on its next run.

Each file gets the post's date (in the file and as its dates), its caption and `@handle` (`social.write_meta`),
and the "tiktok" tag.
"""
from __future__ import annotations

import json
import os
import re
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

import simpcity as sc
import social

TAG = "tiktok"
RECORD = ".tiktok.json"
FORMAT = "photobrowser-tiktok"
API_BASE = "https://www.tikwm.com"
API_HOSTS = ["https://www.tikwm.com", "https://tikwm.com"]
UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) "
      "Version/17.0 Safari/605.1.15")
PAGE = 35                           # posts a page (what the iPhone asks for)
GAP = 1.1                           # seconds between resolver calls (its free limit is about one a second)
MAX_PAGES = 400                     # a safety cap: 14,000 posts
BACKUP_DIR = ".Photo Browser Metadata"
BACKUP_JSON = "metadata.json"
MEDIA_EXT = {"jpg", "jpeg", "png", "webp", "heic", "mp4", "mov", "m4v", "webm"}
VIDEO_EXT = {"mp4", "mov", "m4v", "webm"}


# ----------------------------------------------------------------------------- names and ids

def clean_handle(text: str) -> str:
    """"@jane", "jane" or a profile link → "jane" (the iPhone's `sanitizeHandle`)."""
    h = (text or "").strip()
    if "tiktok.com/@" in h:
        h = h.split("tiktok.com/@", 1)[1]
    h = h.split("/")[0].split("?")[0]
    return h.replace("@", "").strip()


def is_tiktok_id(s: str) -> bool:
    return 15 <= len(s) <= 20 and s.isascii() and s.isdigit()


def post_id(name: str) -> str | None:
    """`<id>.<ext>` or `<id>_<n>.<ext>` → the post id, for a media file named like a TikTok post."""
    stem, dot, ext = name.rpartition(".")
    if not dot or ext.lower() not in MEDIA_EXT:
        return None
    head, us, tail = stem.rpartition("_")
    if us and head and tail.isascii() and tail.isdigit():
        stem = head
    return stem if is_tiktok_id(stem) else None


def ids_on_disk(folder: str | Path) -> set[str]:
    """The post ids in the folder's file names (and its subfolders', three deep — not another profile's
    `@folder`): the iPhone's `postIDsOnDisk(in:tiktok:)`."""
    ids: set[str] = set()
    queue: list[tuple[str, int]] = [(str(folder), 0)]
    seen = 0
    while queue and seen < 2000:
        d, depth = queue.pop(0)
        seen += 1
        try:
            with os.scandir(d) as it:
                for e in it:
                    if e.name.startswith("."):
                        continue
                    try:
                        is_dir = e.is_dir(follow_symlinks=False)
                    except OSError:
                        continue
                    if is_dir:
                        if depth < 3 and not e.name.startswith("@"):
                            queue.append((e.path, depth + 1))
                    elif (pid := post_id(e.name)) is not None:
                        ids.add(pid)
        except OSError:
            continue
    return ids


# ----------------------------------------------------------------------------- the record, and the iPhone's

def record(folder: str | Path) -> social.Record:
    return social.Record.load(folder, RECORD, FORMAT)


@dataclass
class PhoneBackup:
    """What the iPhone app's metadata backup on the drive says about TikTok, by absolute path."""
    folders: dict[str, dict] = field(default_factory=dict)       # profile folder → TTFolderInfo
    likes: dict[str, int] = field(default_factory=dict)          # video file → likes
    last: dict[str, str] = field(default_factory=dict)           # person's folder → the handle last used there


_BACKUPS: dict[str, tuple[float, PhoneBackup]] = {}


_ROOTS: dict[str, tuple[float, str | None]] = {}


def drive_root(path: str | Path) -> str | None:
    """The folder above `path` that holds the iPhone app's metadata backup (the drive's root, as the app
    browses it). Remembered for a minute per folder (a sort by likes asks once per file)."""
    start = os.path.abspath(str(path))
    hit = _ROOTS.get(start)
    now = time.monotonic()
    if hit and now - hit[0] < (60 if hit[1] else 5):       # "no backup" is asked again sooner (a drive just plugged in)
        return hit[1]
    p, found = start, None
    for _ in range(40):
        if os.path.isfile(os.path.join(p, BACKUP_DIR, BACKUP_JSON)):
            found = p
            break
        parent = os.path.dirname(p)
        if parent == p:
            break
        p = parent
    if len(_ROOTS) > 2000:
        _ROOTS.clear()
    _ROOTS[start] = (now, found)
    return found


def phone_backup(path: str | Path) -> PhoneBackup:
    """The backup covering `path` (read once, again when the file changes). Empty when there is none."""
    root = drive_root(path)
    if root is None:
        return PhoneBackup()
    file = os.path.join(root, BACKUP_DIR, BACKUP_JSON)
    try:
        mtime = os.stat(file).st_mtime
    except OSError:
        return PhoneBackup()
    hit = _BACKUPS.get(root)
    if hit and hit[0] == mtime:
        return hit[1]
    out = PhoneBackup()
    try:
        with open(file, "rb") as f:
            doc = json.loads(f.read().decode("utf-8"))
    except (OSError, ValueError):
        doc = {}

    def absolute(rel: str) -> str:
        return os.path.join(root, rel) if rel else root
    if isinstance(doc, dict):
        for rel, info in (doc.get("tiktokFolders") or {}).items():
            if isinstance(info, dict) and isinstance(info.get("handle"), str):
                out.folders[absolute(rel)] = info
        for rel, n in (doc.get("tiktokLikes") or {}).items():
            if isinstance(n, (int, float)) and n > 0:
                out.likes[absolute(rel)] = int(n)
        for rel, h in (doc.get("lastTikTokHandleByFolder") or {}).items():
            if isinstance(h, str) and h:
                out.last[absolute(rel)] = h
    _BACKUPS[root] = (mtime, out)
    return out


@dataclass
class Known:
    """A folder that is a TikTok profile's."""
    folder: str
    handle: str
    ids: set[str]
    source: str                         # "record" / "iphone" / "names"
    count: int | None = None            # the profile's video count at the last full listing, when known


def profile_of(folder: str | Path, on_disk: bool = True) -> Known | None:
    """The profile `folder` belongs to, by the three rules in the module notes — None when it isn't one.
    `on_disk=False` skips reading the folder's names when a record already answers (the menu's quick look)."""
    folder = str(folder)
    rec = record(folder)
    phone = phone_backup(folder).folders.get(folder)
    name = os.path.basename(folder.rstrip("/"))
    if rec.exists and rec.get("handle"):
        ids = set(rec.downloaded)
        if phone:
            ids |= {str(x) for x in phone.get("downloaded") or []}
        if on_disk:
            ids |= ids_on_disk(folder)
        return Known(folder, str(rec.get("handle")), ids, "record", _int(rec.get("profile_video_count")))
    if phone:
        ids = {str(x) for x in phone.get("downloaded") or []}
        if on_disk:
            ids |= ids_on_disk(folder)
        return Known(folder, str(phone["handle"]), ids, "iphone", _int(phone.get("profileVideoCount")))
    if name.startswith("@") and len(name) > 1:
        ids = ids_on_disk(folder)
        remembered = (phone_backup(folder).last.get(os.path.dirname(folder)) or "").lower() == name[1:].lower()
        if ids or remembered:
            return Known(folder, name[1:], ids, "names")
    return None


def _children(folder: str) -> list[str]:
    try:
        with os.scandir(folder) as it:
            return sorted(e.path for e in it if not e.name.startswith(".") and e.is_dir(follow_symlinks=False))
    except OSError:
        return []


def profiles_in(folder: str | Path) -> list[Known]:
    """The TikTok profile folders directly inside `folder`."""
    out = []
    for child in _children(str(folder)):
        k = profile_of(child, on_disk=False) if not os.path.basename(child).startswith("@") else profile_of(child)
        if k is not None:
            out.append(k)
    return out


def destination(folder: str | Path, handle: str) -> Path:
    """Where `handle`'s videos go from `folder`: the folder itself when it's that profile's; else the child
    that is (whatever its name or case); else a new `@handle` (the iPhone's `tiktokDestination`)."""
    folder = str(folder)
    own = profile_of(folder, on_disk=False)
    if own is not None and own.handle.lower() == handle.lower():
        return Path(folder)
    for k in profiles_in(folder):
        if k.handle.lower() == handle.lower():
            return Path(k.folder)
    for child in _children(folder):                       # an empty @handle folder is still that profile's
        if os.path.basename(child).lower() == f"@{handle}".lower():
            return Path(child)
    return Path(folder) / f"@{handle}"


def default_handle(folder: str | Path) -> str:
    """The handle to offer: the folder's own profile, the one profile inside it, or the one the iPhone last
    used here."""
    folder = str(folder)
    own = profile_of(folder, on_disk=False)
    if own is not None:
        return own.handle
    inside = profiles_in(folder)
    if len(inside) == 1:
        return inside[0].handle
    return phone_backup(folder).last.get(folder, "")


def menu_label(folder: str | Path) -> str:
    """"Get New TikTok Videos" on a profile's folder (or a folder holding one), else "Download TikTok Profile…"."""
    folder = str(folder)
    if os.path.isfile(os.path.join(folder, RECORD)) or folder in phone_backup(folder).folders:
        return "Get New TikTok Videos"
    for child in _children(folder):
        if os.path.isfile(os.path.join(child, RECORD)) or os.path.basename(child).startswith("@"):
            return "Get New TikTok Videos"
    name = os.path.basename(folder.rstrip("/"))
    return "Get New TikTok Videos" if name.startswith("@") and len(name) > 1 else "Download TikTok Profile…"


# ----------------------------------------------------------------------------- likes

_LIKES: dict[str, tuple[tuple[float, float], dict[str, int]]] = {}


def folder_likes(folder: str | Path) -> dict[str, int]:
    """Post id → likes for a profile folder: the record's `likes`, under them what the iPhone's backup noted
    for the folder's files. Cached until either file changes."""
    folder = str(folder)
    rec_file = os.path.join(folder, RECORD)
    root = drive_root(folder)
    backup_file = os.path.join(root, BACKUP_DIR, BACKUP_JSON) if root else ""

    def mtime(p: str) -> float:
        try:
            return os.stat(p).st_mtime if p else 0.0
        except OSError:
            return 0.0
    stamp = (mtime(rec_file), mtime(backup_file))
    hit = _LIKES.get(folder)
    if hit and hit[0] == stamp:
        return hit[1]
    out: dict[str, int] = {}
    if stamp[1]:
        prefix = folder.rstrip("/") + "/"
        for path, n in phone_backup(folder).likes.items():
            if path.startswith(prefix) and "/" not in path[len(prefix):]:
                pid = post_id(os.path.basename(path))
                if pid:
                    out[pid] = n
    if stamp[0]:
        likes = record(folder).get("likes")
        if isinstance(likes, dict):
            for k, v in likes.items():
                if isinstance(v, (int, float)) and v > 0:
                    out[str(k)] = int(v)
    if len(_LIKES) > 400:
        _LIKES.clear()
    _LIKES[folder] = (stamp, out)
    return out


def likes_of(path: str) -> int | None:
    """A downloaded TikTok video's like count, or None for anything else."""
    pid = post_id(os.path.basename(path))
    if pid is None:
        return None
    return folder_likes(os.path.dirname(path)).get(pid)


def forget_likes(folder: str | Path | None = None) -> None:
    if folder is None:
        _LIKES.clear()
    else:
        _LIKES.pop(str(folder), None)


# ----------------------------------------------------------------------------- the resolver

@dataclass
class Post:
    id: str
    hd: str
    sd: str
    images: list[str]
    date: float
    caption: str
    likes: int


def absolute(u: str) -> str:
    """tikwm sometimes gives site-relative media paths."""
    return u if u.startswith("http") else API_BASE + (u if u.startswith("/") else "/" + u)


def _int(v) -> int | None:
    if isinstance(v, bool):
        return None
    if isinstance(v, (int, float)):
        return int(v)
    if isinstance(v, str):
        try:
            return int(v)
        except ValueError:
            return None
    return None


def _id(v) -> str | None:
    if isinstance(v, str):
        return v or None
    if isinstance(v, (int, float)) and not isinstance(v, bool):
        return str(int(v))
    return None


def is_block_page(body: bytes) -> bool:
    head = body[:300].decode("utf-8", "replace").lower()
    return any(w in head for w in ("<html", "<!doctype", "cloudflare", "captcha", "attention required"))


def plain_get(url: str, headers: dict[str, str], timeout: float = 30) -> tuple[int, bytes]:
    """(status, body) — status 0 with the reason as the body when there was no answer."""
    try:
        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req, timeout=timeout, context=sc.ssl_context()) as r:
            return r.status, r.read(20_000_000)
    except urllib.error.HTTPError as e:
        try:
            return e.code, e.read(2_000_000)
        except OSError:
            return e.code, b""
    except TimeoutError:
        return 0, b"the resolver timed out"
    except urllib.error.URLError as e:
        reason = str(getattr(e, "reason", e))
        return 0, (b"the resolver timed out" if "timed out" in reason else
                   f"couldn't reach the resolver ({reason})".encode())
    except OSError as e:
        return 0, f"network error ({e})".encode()


class Resolver:
    """tikwm's API, as `TikTokService.apiData` asks it. `get(url, headers) -> (status, body)` is the plain
    request, `browser(url) -> (parsed JSON or None, cookie, user agent)` the real browser a Cloudflare block
    is handed to (None when there isn't one), `sleep` the pauses (tests replace all three)."""

    def __init__(self, get: Callable[[str, dict], tuple[int, bytes]] = plain_get,
                 browser: Callable[[str], tuple[dict | None, str, str]] | None = None,
                 sleep: Callable[[float], None] = time.sleep,
                 stop: Callable[[], bool] = lambda: False) -> None:
        self.get, self.browser, self.sleep, self.stop = get, browser, sleep, stop
        self.cookie = ""                # a Cloudflare clearance the browser earned…
        self.agent = ""                 # …and the User-Agent it was issued to (they only work together)
        self.blocked_with_clearance = 0
        self.waiting_for_person = False

    def headers(self, host: str) -> dict[str, str]:
        h = {"User-Agent": self.agent or UA, "Accept": "application/json, text/plain, */*",
             "Accept-Language": "en-US,en;q=0.9", "Referer": host + "/", "Origin": host,
             "X-Requested-With": "XMLHttpRequest"}
        if self.cookie:
            h["Cookie"] = self.cookie
        return h

    def media_headers(self) -> list[dict[str, str]]:
        """For the files themselves: as the iPhone asks (agent + referer), then with the clearance."""
        tries = [{"User-Agent": UA, "Referer": API_BASE + "/", "Accept": "*/*"}]
        if self.cookie:
            tries.append({"User-Agent": self.agent or UA, "Referer": API_BASE + "/", "Accept": "*/*",
                          "Cookie": self.cookie})
        return tries

    @staticmethod
    def url(path: str, query: dict[str, str], host: str) -> str:
        return host + path + "?" + urllib.parse.urlencode(query)

    def api(self, path: str, query: dict[str, str], retries: int = 4) -> tuple[dict | None, str | None]:
        """→ (the answer's `data`, None) or (None, why)."""
        reason: str | None = None
        blocked = False
        if self.blocked_with_clearance < 2 or self.browser is None:
            for attempt in range(retries + 1):
                if self.stop():
                    return None, "stopped"
                if attempt:
                    self.sleep(min(attempt, 4))
                host = API_HOSTS[attempt % len(API_HOSTS)]
                status, body = self.get(self.url(path, query, host), self.headers(host))
                if status == 0:
                    reason = body.decode("utf-8", "replace") or "no answer"
                    continue
                try:
                    obj = json.loads(body)
                except ValueError:
                    obj = None
                if isinstance(obj, dict):
                    if _int(obj.get("code")) == 0 and isinstance(obj.get("data"), dict):
                        self.blocked_with_clearance = 0
                        return obj["data"], None
                    reason = f"resolver busy ({obj.get('msg') or 'code ' + str(_int(obj.get('code')))})"
                    continue
                page = is_block_page(body)
                reason = f"resolver returned a block page (HTTP {status})" if page else f"resolver answered HTTP {status}"
                if page or status == 403:
                    blocked = True                       # more plain requests won't get past a bot check
                    if self.cookie:
                        self.blocked_with_clearance += 1
                    break
        else:
            blocked = True
        if blocked and self.browser is not None and not self.stop():
            obj, cookie, agent = self.browser(self.url(path, query, API_BASE))
            if cookie:
                self.cookie, self.agent = cookie, agent or self.agent
            if isinstance(obj, dict):
                if _int(obj.get("code")) == 0 and isinstance(obj.get("data"), dict):
                    return obj["data"], None
                reason = f"resolver busy ({obj.get('msg') or 'code ' + str(_int(obj.get('code')))})"
            elif self.waiting_for_person:
                reason = "tikwm.com is asking for a quick check that a person is here"
        return None, reason

    def hd(self, pid: str, username: str) -> str | None:
        """The HD (watermark-free) address of one video, from the single-video endpoint."""
        d, _why = self.api("/api/", {"url": f"https://www.tiktok.com/@{username}/video/{pid}", "hd": "1"})
        if d is None:
            return None
        return (d.get("hdplay") if isinstance(d.get("hdplay"), str) and d.get("hdplay") else None) or \
            (d.get("play") if isinstance(d.get("play"), str) else None)


@dataclass
class Listing:
    posts: list[Post] = field(default_factory=list)
    avatar: str = ""
    author_id: str = ""
    nickname: str = ""
    newest: float = 0
    failed: bool = True                 # not one page came back
    complete: bool = False              # paged to the profile's end
    reason: str | None = None


def parse_post(v: dict) -> Post | None:
    pid = _id(v.get("video_id")) or _id(v.get("aweme_id")) or _id(v.get("id"))
    if pid is None:
        return None
    hd = v.get("hdplay") if isinstance(v.get("hdplay"), str) else ""
    sd = next((v[k] for k in ("play", "wmplay") if isinstance(v.get(k), str) and v[k]), "")
    images = [x for x in (v.get("images") or []) if isinstance(x, str) and x] if isinstance(v.get("images"), list) else []
    if not (hd or sd or images):
        return None
    return Post(pid, hd, sd, images, float(_int(v.get("create_time")) or 0),
                v.get("title") if isinstance(v.get("title"), str) else "", _int(v.get("digg_count")) or 0)


def list_posts(resolver: Resolver, username: str, progress: Callable[[str], None] = lambda s: None,
               on_post: Callable[[Post], None] = lambda p: None) -> Listing:
    """Every post on `@username`, newest first, `on_post` called as each is listed. The whole profile is paged
    every time (so every like count is read again) — the iPhone's early stop isn't taken here."""
    out = Listing()
    seen: set[str] = set()
    cursor = "0"
    for page in range(MAX_PAGES):
        if resolver.stop():
            out.reason = "stopped"
            break
        if page:
            resolver.sleep(GAP)
        d, why = resolver.api("/api/user/posts", {"unique_id": username, "count": str(PAGE), "cursor": cursor, "hd": "1"})
        if d is None:
            out.reason = why
            break
        out.failed = False
        for v in d.get("videos") or []:
            if not isinstance(v, dict):
                continue
            author = v.get("author")
            if isinstance(author, dict):
                out.avatar = out.avatar or (author.get("avatar") if isinstance(author.get("avatar"), str) else "")
                out.author_id = out.author_id or (_id(author.get("id")) or "")
                out.nickname = out.nickname or (author.get("nickname") if isinstance(author.get("nickname"), str) else "")
            post = parse_post(v)
            out.newest = max(out.newest, float(_int(v.get("create_time")) or 0))
            if post is None or post.id in seen:
                continue
            seen.add(post.id)
            out.posts.append(post)
            on_post(post)
        progress(f"Found {len(out.posts)} videos…")
        more = d.get("hasMore")
        more = bool(more) if isinstance(more, bool) else _int(more) == 1
        nxt = _id(d.get("cursor")) or ""
        if not more or not nxt or nxt == cursor:
            out.complete = True
            break
        cursor = nxt
    return out


# ----------------------------------------------------------------------------- a run

@dataclass
class Outcome:
    handle: str
    author_id: str = ""
    nickname: str = ""
    avatar: str = ""
    total: int = 0                      # posts listed
    complete: bool = False              # the whole profile was listed
    queued: int = 0                     # files handed to the downloads
    stats: dict[str, int] = field(default_factory=dict)      # post id → likes, every post listed
    newest: float = 0
    note: str | None = None             # why nothing was queued / what went wrong
    failed: bool = False                # the resolver never answered


def items_for(post: Post, url: str, folder: Path, handle: str) -> list[social.Item]:
    """The files of one post: `<id>.mp4`, or `<id>_<n>.jpg` for each photo of a slideshow."""
    common = dict(key=post.id, folder=folder, date=post.date, caption=post.caption, poster=f"@{handle}", keyword="TikTok")
    if post.images:
        return [social.Item(name=f"{post.id}_{n}", video=False, url=absolute(u), ext="jpg", **common)
                for n, u in enumerate(post.images, 1)]
    return [social.Item(name=post.id, video=True, url=absolute(url), ext="mp4", **common)]


def run(resolver: Resolver, username: str, folder: Path, already: set[str],
        emit: Callable[[list[social.Item]], None], progress: Callable[[str], None] = lambda s: None) -> Outcome:
    """Lists `@username` and hands every post not in `already` (and not in the folder by name) to `emit`, as
    it's listed when the listing has its HD address or photos — the rest once each is resolved. Returns what
    was found, with every listed post's likes."""
    out = Outcome(username)
    waiting: list[Post] = []

    def missing(items: list[social.Item]) -> list[social.Item]:
        return [i for i in items if not os.path.lexists(i.folder / i.filename)]

    def on_post(p: Post) -> None:
        if p.likes > 0:
            out.stats[p.id] = p.likes
        if p.id in already:
            return
        if p.images or p.hd:
            items = missing(items_for(p, p.hd, folder, username))
            if items:
                out.queued += len(items)
                emit(items)
        else:
            waiting.append(p)

    progress(f"Finding @{username}'s videos…")
    listing = list_posts(resolver, username, progress, on_post)
    out.author_id, out.nickname, out.avatar = listing.author_id, listing.nickname, listing.avatar
    out.total, out.complete, out.newest, out.failed = len(listing.posts), listing.complete, listing.newest, listing.failed
    if listing.failed:
        out.note = (f"Couldn't read @{username}'s videos — {listing.reason or 'the resolver may be rate-limiting or blocking'}."
                    " Try again in a moment.")
        return out
    if not listing.complete and listing.reason and listing.reason != "stopped":
        out.note = f"The list stopped early ({listing.reason}) — run it again to get the rest."
    for i, p in enumerate(waiting):
        if resolver.stop():
            break
        progress(f"Preparing HD links — {i + 1} of {len(waiting)}…")
        if i:
            resolver.sleep(GAP)
        best = resolver.hd(p.id, username) or p.sd
        if not best:
            continue
        items = missing(items_for(p, best, folder, username))
        if items:
            out.queued += len(items)
            emit(items)
    if not out.queued and out.note is None:
        if not listing.posts:
            out.note = ("Couldn't find any videos — the handle may be wrong, the profile private or empty, or "
                        "the resolver is blocking.")
        else:
            out.note = "No new videos."
    return out


# ----------------------------------------------------------------------------- files

_MAGIC = re.compile(rb"^(?:\xff\xd8\xff|\x89PNG|RIFF....WEBP|GIF8)", re.S)


def looks_like(path: str, video: bool) -> bool:
    """A real video/photo — not a block page or an error body saved under its name."""
    try:
        with open(path, "rb") as f:
            head = f.read(64)
    except OSError:
        return False
    if video:
        return head[4:8] == b"ftyp" or head[:4] == b"\x1a\x45\xdf\xa3"
    return bool(_MAGIC.match(head)) or head[4:8] == b"ftyp"          # ftyp: HEIC/AVIF


def fetcher(item: social.Item, tmp: str, tries: list[dict[str, str]]) -> tuple[str | None, str]:
    """`social.download`, with what came down checked to be the video or photo it's named as."""
    path, why = social.download(item, tmp, tries)
    if path and not looks_like(path, item.video):
        try:
            os.remove(path)
        except OSError:
            pass
        return None, "the resolver sent something that isn't the " + ("video" if item.video else "photo")
    return path, why


def save_record(rec: social.Record, done: set[str], photos: int, videos: int, outcome: Outcome | None,
                handle: str) -> tuple[int, int]:
    """The record after a run: the ids done, the profile's fields, and the likes — every count the listing
    read, over the ones the record (or the iPhone's backup) had. → (likes known, likes that changed)."""
    info: dict = {"handle": handle}
    known = dict(folder_likes(rec.folder))
    old = rec.get("likes")
    if isinstance(old, dict):
        known.update({str(k): int(v) for k, v in old.items() if isinstance(v, (int, float))})
    changed = 0
    if outcome is not None:
        info.update(author_id=outcome.author_id, nickname=outcome.nickname)
        if outcome.complete and outcome.total:
            info["profile_video_count"] = outcome.total
        if outcome.newest:
            info["newest_listed"] = outcome.newest
        for pid, n in outcome.stats.items():
            if known.get(pid) != n:
                changed += 1
            known[pid] = n
        if outcome.stats:
            info["likes_updated"] = time.time()
    if known:
        info["likes"] = known
    rec.save(done, photos, videos, **info)
    forget_likes(rec.folder)
    return len(known), changed
