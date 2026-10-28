#!/usr/bin/env python3
"""The file hosts a SimpCity post links videos on — pixeldrain, gofile, cyberdrop, bunkr, filester and
fileditch — for the SimpCity downloader (simpcity.py / simpcity_downloader.py). No window here.

A post's link to one of these hosts is a **`Link`**: one file (`pixeldrain.com/u/…`, `bunkr.cr/f/…`,
`filester.me/d/…`, a fileditch file) or a folder (`gofile.io/d/…`, `pixeldrain.com/l/…`,
`cyberdrop.cr/a/…`, `bunkr.cr/a/…`, `filester.me/f/…`). `expand` turns it into the **videos** in it
(`Remote`s — photos, archives and the rest are left alone), each with what the host says about it up front:
its name, and for most hosts its exact size (pixeldrain also its SHA-256) — which is how the downloader
knows two links are the same video before fetching either. The file's own address comes just before its
download (`direct_url`): cyberdrop's and bunkr's are short-lived.

How each host is read (plain requests on a worker thread unless said otherwise):
- **pixeldrain** — its public API: `/api/file/<id>/info`, `/api/list/<id>`; the file is `/api/file/<id>`.
  A file pixeldrain has marked as hotlinked (`availability: file_rate_limited_captcha_required` — it
  answers 403 to a plain download) is `locked`: another host's copy is fetched instead when there is
  one, else the person presses Download on its page in the window and answers pixeldrain's captcha.
- **gofile** — **only through its own site, in the browser.** Its API wants a website token made by the
  site's script with a secret gofile rotates, and a request signed with a retired secret gets the IP
  banned on the spot (the site's own `core/wt.js` says so) — so nothing here signs a request. The folder
  page is loaded in a lane, `CAPTURE_JS` (injected before the page's own scripts) keeps the
  `/contents/` answers the site fetches for itself, and `HOST_PAGE_JS` lists the videos in them. One
  folder at a time, and a rate-limit answer stops gofile for the run.
- **cyberdrop** — the album page's `/f/<id>` links, `api.<host>/api/file/info/<id>`, then its `auth_url`.
- **bunkr** — the album page's `albumFiles` list (or its `/f/` links) / a file page's `data-file-id`,
  then `apidl.bunkr.ru` for the file's address (base64, XOR'd with an hourly key).
- **filester** and **fileditch** have no public API (filester's needs an account key; fileditch is behind
  Cloudflare), so their pages are read in the downloader's browser: `HOST_PAGE_JS` finds the video a page
  plays or links, or — in a folder — the pages of the files in it. A host whose API answer is a "you're
  human?" check (`NeedsBrowser`), or that fails, goes the same way.

Nothing here answers a check or a captcha: the person does, in the window.

The page scripts are kept identical to the Swift copies in PhotoBrowser/SimpCityHosts.swift.
"""
from __future__ import annotations

import base64
import concurrent.futures
import hashlib
import json
import re
from dataclasses import dataclass, field
from urllib.parse import parse_qs, urlsplit

HOSTS = ("pixeldrain", "gofile", "cyberdrop", "bunkr", "filester", "fileditch")
# Which copy is fetched when the same video is on several hosts (lower first): the quick, plain APIs
# before the hosts read through a browser.
PREFERENCE = {"pixeldrain": 0, "gofile": 1, "cyberdrop": 2, "turbo": 3, "filester": 4, "fileditch": 5, "bunkr": 6}
VIDEO_EXTS = ("mp4", "mov", "m4v", "webm", "mkv")
_VIDEO = re.compile(r"\.(?:mp4|mov|m4v|webm|mkv)(?:[?#]|$)", re.I)
_NOT_VIDEO = re.compile(r"\.(?:jpe?g|png|gif|webp|heic|avif|bmp|tiff?|zip|rar|7z|pdf|txt|mp3|m4a|wav)(?:[?#]|$)", re.I)
WORKERS = 6               # file-info requests at once inside one folder

BUNKR_API = "https://apidl.bunkr.ru/api/_001_v2"
LOCKED = "file_rate_limited_captcha_required"     # pixeldrain's hotlink lock


class HostError(Exception):
    """A host couldn't be read (the reason is the message)."""


class NeedsBrowser(HostError):
    """The answer was a "you're human?" check, or the host has no plain way in — read it in the browser."""


class Gone(HostError):
    """The link is dead (not found / removed): nothing to download, nothing to try again."""


# ----------------------------------------------------------------------------- links in posts


@dataclass
class Link:
    host: str
    kind: str              # "file" | "folder"
    ident: str             # the id in the address: file id, folder id, slug — or fileditch's path
    url: str               # the address to open
    post: str = ""         # forum post it came from (the earliest)
    posted: float = 0

    @property
    def key(self) -> str:
        return f"{self.host}:{self.kind}:{self.ident}"


_ID = r"([A-Za-z0-9_-]{4,})"
_PIXELDRAIN = re.compile(r"^https?://(?:www\.)?pixeldra(?:in)?\.[a-z]+/(u|l|api/file)/([A-Za-z0-9]{4,})", re.I)
_GOFILE = re.compile(r"^https?://(?:www\.)?gofile\.io/(?:d|w)/([A-Za-z0-9-]{4,})", re.I)
_CYBERDROP = re.compile(r"^https?://(?:www\.)?(cyberdrop\.[a-z]+)/(a|f|e)/" + _ID, re.I)
_BUNKR = re.compile(r"^https?://(?:www\.)?((?:[a-z0-9-]+\.)?bunkrr?\.[a-z]+)/(a|f|v|i|d)/" + _ID, re.I)
_FILESTER = re.compile(r"^https?://(?:www\.)?(filester\.[a-z]+)/(d|f)/" + _ID, re.I)
_FILEDITCH = re.compile(r"^https?://(?:[a-z0-9-]+\.)?(fileditch[a-z]*\.[a-z]+)(/[^#]*)$", re.I)


def safe_id(s: str, limit: int = 80) -> str:
    """An id fit for a file name: letters, digits, `_` and `-`."""
    return re.sub(r"[^A-Za-z0-9_-]", "", s or "")[:limit]


def classify(url: str) -> Link | None:
    """The host link a post's address is, or None when it isn't one."""
    u = (url or "").strip()
    if m := _PIXELDRAIN.match(u):
        return Link("pixeldrain", "folder" if m.group(1).lower() == "l" else "file", m.group(2),
                    f"https://pixeldrain.com/{'l' if m.group(1).lower() == 'l' else 'u'}/{m.group(2)}")
    if m := _GOFILE.match(u):
        return Link("gofile", "folder", m.group(1), f"https://gofile.io/d/{m.group(1)}")
    if m := _CYBERDROP.match(u):
        host, kind = m.group(1).lower(), m.group(2).lower()
        return Link("cyberdrop", "folder" if kind == "a" else "file", m.group(3),
                    f"https://{host}/{'a' if kind == 'a' else 'f'}/{m.group(3)}")
    if m := _BUNKR.match(u):
        host, kind = m.group(1).lower(), m.group(2).lower()
        if host.split(".")[0] not in ("bunkr", "bunkrr"):          # a CDN or the download hub, not a page
            return None
        return Link("bunkr", "folder" if kind == "a" else "file", m.group(3), f"https://{host}/{kind}/{m.group(3)}")
    if m := _FILESTER.match(u):
        host, kind = m.group(1).lower(), m.group(2).lower()
        return Link("filester", "folder" if kind == "f" else "file", m.group(3), f"https://{host}/{kind}/{m.group(3)}")
    if m := _FILEDITCH.match(u):
        parts = urlsplit(u)
        path = (parse_qs(parts.query).get("f") or [""])[0] or parts.path
        name = path.rstrip("/").rsplit("/", 1)[-1]
        if not name or name.lower() in ("file.php", "index.php", "upload.php") or _NOT_VIDEO.search(name):
            return None
        return Link("fileditch", "file", path.strip("/"), u)
    return None


# ----------------------------------------------------------------------------- the videos behind a link


@dataclass
class Remote:
    """One video on a host."""
    host: str
    fid: str                           # the host's id for the file (safe for a file name)
    name: str = ""                     # its name there
    size: int = 0                      # bytes, when the host says (0: unknown)
    sha256: str = ""                   # when the host says (pixeldrain)
    url: str = ""                      # the file itself, when known up front
    page: str = ""                     # its page — read in the browser when there's no url
    referer: str = ""
    headers: dict = field(default_factory=dict)
    cookies: dict = field(default_factory=dict)     # set in the browser too, for its download
    extra: dict = field(default_factory=dict)       # bunkr: numeric id + hub; cyberdrop: auth address;
                                                    # pixeldrain: "locked" (its hotlink captcha)

    @property
    def key(self) -> str:
        return f"{self.host}:{self.fid}"

    @property
    def locked(self) -> bool:
        """Only a person can fetch it (pixeldrain's captcha): another host's copy is preferred."""
        return bool(self.extra.get("locked"))


def is_video_name(name: str) -> bool:
    return bool(_VIDEO.search(name or ""))


def maybe_video(name: str) -> bool:
    """Not known to be something else (a name without an extension may still be a video)."""
    return not _NOT_VIDEO.search(name or "")


def expand(link: Link, ua: str) -> list[Remote]:
    """The videos behind `link` (on a worker thread). Raises `Gone` for a dead link, `NeedsBrowser` when
    the host must be read in the browser (`from_page`), `HostError` for anything else."""
    if link.host == "pixeldrain":
        return _pixeldrain(link, ua)
    if link.host == "gofile":
        raise NeedsBrowser("gofile is read through its own site")
    if link.host == "cyberdrop":
        return _cyberdrop(link, ua)
    if link.host == "bunkr":
        return _bunkr(link, ua)
    if link.host == "filester":
        if link.kind == "file":
            return [Remote("filester", safe_id(link.ident), page=link.url, referer=link.url)]
        raise NeedsBrowser("filester folders are read in the browser")
    if link.host == "fileditch":
        name = link.ident.rsplit("/", 1)[-1]
        fid = safe_id(name.rsplit(".", 1)[0]) or safe_id(link.ident)
        direct = urlsplit(link.url).path.lower().endswith(tuple("." + e for e in VIDEO_EXTS))
        return [Remote("fileditch", fid, name=name, url=link.url if direct else "",
                       page="" if direct else link.url, referer=link.url if not direct else "")]
    raise HostError(f"{link.host} isn't a host the downloader reads")


def direct_url(remote: Remote, ua: str) -> str:
    """The file's address, asked just before its download (cyberdrop's and bunkr's don't last). Raises
    `NeedsBrowser` when only its page can say (then `HOST_PAGE_JS` on `remote.page`), `Gone`/`HostError`."""
    if remote.url:
        return remote.url
    if remote.host == "cyberdrop" and remote.extra.get("auth"):
        j = _json(remote.extra["auth"], ua)
        url = str(j.get("url") or "")
        if url.startswith("http"):
            return url
        raise HostError("cyberdrop didn't give the file's address")
    if remote.host == "bunkr" and remote.extra.get("id"):
        return bunkr_file_url(str(remote.extra["id"]), str(remote.extra.get("hub") or "https://dl.bunkr.cr"), ua)
    raise NeedsBrowser(f"{remote.host} shows the file only on its page")


# ----------------------------------------------------------------------------- plain requests


def _open(url: str, ua: str, method: str = "GET", body: bytes | None = None, headers: dict | None = None,
          timeout: float = 25) -> tuple[int, str, bytes]:
    """(status, content type, body) — an HTTP error is an answer too (its status and page)."""
    import urllib.error
    import urllib.request
    from simpcity import ssl_context
    h = {"User-Agent": ua, "Accept": "application/json, text/html;q=0.9, */*;q=0.8", "Accept-Language": "en-US,en;q=0.9"}
    h.update(headers or {})
    req = urllib.request.Request(url, data=body, headers=h, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=ssl_context()) as resp:
            return resp.status, resp.headers.get("Content-Type") or "", resp.read(20 << 20)
    except urllib.error.HTTPError as e:
        try:
            data = e.read(1 << 20)
        except OSError:
            data = b""
        return e.code, e.headers.get("Content-Type") or "" if e.headers else "", data
    except (urllib.error.URLError, OSError, ValueError) as e:
        raise HostError(f"couldn't connect to {urlsplit(url).hostname} ({getattr(e, 'reason', e)})") from e


def is_check_page(text: str) -> bool:
    return bool(re.search(r"Just a moment|DDoS-Guard|Checking your browser|Attention Required|challenge-platform|cf-turnstile",
                          text[:20000]))


def _text(url: str, ua: str, headers: dict | None = None) -> str:
    status, _ctype, data = _open(url, ua, headers=headers)
    text = data.decode("utf-8", "replace")
    if is_check_page(text) or status in (403, 429, 503) and "<html" in text[:2000].lower():
        raise NeedsBrowser(f"{urlsplit(url).hostname} answered with a check page")
    if status == 404 or status == 410:
        removed = re.search(r"removed by the original uploader|has been removed|been deleted", text, re.I)
        raise Gone(f"{'deleted' if removed else 'not found'} on {urlsplit(url).hostname} ({status})")
    if status >= 400:
        raise HostError(f"HTTP {status} from {urlsplit(url).hostname}")
    return text


def _json(url: str, ua: str, method: str = "GET", body: bytes | None = None, headers: dict | None = None) -> dict:
    status, _ctype, data = _open(url, ua, method=method, body=body, headers=headers)
    try:
        doc = json.loads(data.decode("utf-8", "replace"))
    except ValueError:
        doc = None
    if not isinstance(doc, dict):
        if is_check_page(data.decode("utf-8", "replace")):
            raise NeedsBrowser(f"{urlsplit(url).hostname} answered with a check page")
        if status in (404, 410):
            raise Gone(f"{url} isn't there any more")
        raise HostError(f"HTTP {status} from {urlsplit(url).hostname}, not the expected answer")
    if status in (404, 410):
        raise Gone(str(doc.get("message") or doc.get("value") or doc.get("status") or "not found"))
    if status >= 400:
        raise HostError(f"HTTP {status} from {urlsplit(url).hostname}: {doc.get('message') or doc.get('value') or doc.get('status') or ''}")
    return doc


def _pool(fn, args: list) -> list:
    """`fn` over `args`, a few at a time; failures (HostError) left out."""
    out = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=WORKERS) as ex:
        for r in ex.map(lambda a: _quiet(fn, a), args):
            if r is not None:
                out.append(r)
    return out


def _quiet(fn, a):
    try:
        return fn(a)
    except HostError:
        return None


# ----------------------------------------------------------------------------- pixeldrain


def _pixeldrain_remote(f: dict) -> Remote | None:
    fid = safe_id(str(f.get("id") or ""))
    name = str(f.get("name") or fid)
    mime = str(f.get("mime_type") or "")
    if not fid or not (mime.startswith("video/") or is_video_name(name)):
        return None
    locked = str(f.get("availability") or "")
    return Remote("pixeldrain", fid, name=name, size=int(f.get("size") or 0), sha256=str(f.get("hash_sha256") or "").lower(),
                  url=f"https://pixeldrain.com/api/file/{fid}?download", page=f"https://pixeldrain.com/u/{fid}",
                  referer=f"https://pixeldrain.com/u/{fid}", extra={"locked": locked} if locked else {})


def _pixeldrain(link: Link, ua: str) -> list[Remote]:
    if link.kind == "folder":
        j = _json(f"https://pixeldrain.com/api/list/{link.ident}", ua)
        return [r for f in j.get("files") or [] if isinstance(f, dict) and (r := _pixeldrain_remote(f))]
    j = _json(f"https://pixeldrain.com/api/file/{link.ident}/info", ua)
    r = _pixeldrain_remote({**j, "id": j.get("id") or link.ident})
    return [r] if r else []


# ----------------------------------------------------------------------------- cyberdrop


def _cyberdrop(link: Link, ua: str) -> list[Remote]:
    host = urlsplit(link.url).hostname or "cyberdrop.cr"
    api = f"https://api.{host}"
    if link.kind == "folder":
        html = _text(link.url, ua)
        ids = list(dict.fromkeys(re.findall(r'href="/f/([A-Za-z0-9_-]+)"', html)))
        if not ids:
            raise NeedsBrowser("no files listed on the album page")
    else:
        ids = [link.ident]

    def info(fid: str) -> Remote | None:
        j = _json(f"{api}/api/file/info/{fid}", ua)
        name = str(j.get("name") or j.get("filename") or fid)
        kind = str(j.get("type") or "")
        if not (kind.startswith("video/") or is_video_name(name) or (link.kind == "file" and maybe_video(name))):
            return None
        return Remote("cyberdrop", safe_id(fid), name=name, size=int(j.get("size") or 0), page=f"https://{host}/f/{fid}",
                      referer=f"https://{host}/", extra={"auth": str(j.get("auth_url") or f"{api}/api/file/auth/{fid}")})

    if link.kind == "file":
        r = info(ids[0])
        return [r] if r else []
    return _pool(info, ids)


# ----------------------------------------------------------------------------- bunkr


def balanced_array(html: str, marker: str) -> str | None:
    """The `[ … ]` assigned to `marker` (`window.albumFiles = [ … ]`), strings and escapes respected."""
    m = re.search(re.escape(marker) + r"\s*=\s*\[", html)
    if not m:
        return None
    depth, in_str, esc, quote_ch = 0, False, False, ""
    for i in range(m.end() - 1, len(html)):
        c = html[i]
        if esc:
            esc = False
        elif c == "\\":
            esc = True
        elif in_str:
            if c == quote_ch:
                in_str = False
        elif c in "\"'":
            in_str, quote_ch = True, c
        elif c == "[":
            depth += 1
        elif c == "]":
            depth -= 1
            if depth == 0:
                return html[m.end() - 1:i + 1]
    return None


def _unescape(s: str) -> str:
    import html as _html
    try:
        s = json.loads(f'"{s}"') if "\\" in s else s
    except ValueError:
        pass
    return _html.unescape(s).strip()


def bunkr_album_files(html: str) -> list[dict]:
    """`albumFiles` on a bunkr album page: [{id, name, slug, size, type}] (its keys are unquoted JS)."""
    arr = balanced_array(html, "albumFiles")
    if not arr:
        return []
    out = []
    for obj in re.findall(r"\{[^{}]*\}", arr):
        fid = re.search(r"""[,{\s]["']?id["']?\s*:\s*["']?(\d+)""", obj)
        if not fid:
            continue

        def s(key: str) -> str:
            m = re.search(r"""[,{\s]["']?""" + key + r"""["']?\s*:\s*(["'])((?:(?!\1)[^\\]|\\.)*)\1""", obj)
            return _unescape(m.group(2)) if m else ""
        size = re.search(r"""[,{\s]["']?size["']?\s*:\s*["']?(\d+)""", obj)
        out.append({"id": fid.group(1), "name": s("original") or s("name"), "slug": s("slug"),
                    "size": int(size.group(1)) if size else 0, "type": s("type")})
    return out


def bunkr_decrypt(b64: str, timestamp: int) -> str:
    """bunkr's file address: base64, XOR'd with `SECRET_KEY_<timestamp / 3600>`."""
    data = base64.b64decode(b64 + "=" * (-len(b64) % 4))
    key = f"SECRET_KEY_{int(timestamp) // 3600}".encode()
    return bytes(b ^ key[i % len(key)] for i, b in enumerate(data)).decode("utf-8", "replace")


def bunkr_file_url(fid: str, hub: str, ua: str) -> str:
    """The file's CDN address from bunkr's download API (armed for a short while — asked just before)."""
    j = _json(BUNKR_API, ua, method="POST", body=json.dumps({"id": fid}).encode(),
              headers={"Content-Type": "application/json", "Referer": f"{hub}/file/{fid}", "Origin": hub})
    url = str(j.get("url") or "")
    if j.get("encrypted") and url:
        url = bunkr_decrypt(url, int(j.get("timestamp") or 0))
    if not url.startswith("http"):
        raise HostError("bunkr didn't give the file's address")
    if url.endswith(("/maint.mp4", "/maintenance-vid.mp4")):
        raise HostError("bunkr shows its maintenance clip for this file (its server is down) — try again later")
    return url


def _bunkr(link: Link, ua: str) -> list[Remote]:
    host = urlsplit(link.url).hostname or "bunkr.cr"
    origin, hub = f"https://{host}", f"https://dl.{host}"

    def remote(fid: str, slug: str, name: str, size: int) -> Remote:
        return Remote("bunkr", safe_id(slug or fid), name=name, size=size, page=f"{origin}/f/{slug}" if slug else link.url,
                      referer=f"{hub}/file/{fid}" if fid else link.url,
                      extra={"id": fid, "hub": hub} if fid else {})

    def file_page(slug: str) -> Remote | None:
        html = _text(f"{origin}/f/{slug}", ua)
        fid = re.search(r'data-file-id="(\d+)"', html) or re.search(r'"id"\s*:\s*"?(\d{4,})', html)
        h1 = re.search(r"<h1[^>]*>\s*([^<]+?)\s*</h1>", html)
        name = _unescape(h1.group(1)) if h1 else slug
        if not maybe_video(name):
            return None
        return remote(fid.group(1) if fid else "", slug, name, 0)

    if link.kind == "file":
        try:
            r = file_page(link.ident)
        except NeedsBrowser:
            return [Remote("bunkr", safe_id(link.ident), page=link.url, referer=link.url)]
        return [r] if r else []
    sep = "&" if "?" in link.url else "?"
    html = _text(link.url + f"{sep}advanced=1", ua)
    files = bunkr_album_files(html)
    if files:
        return [remote(f["id"], f["slug"], f["name"] or f["slug"] or f["id"], f["size"]) for f in files
                if f["type"].startswith("video/") or is_video_name(f["name"])]
    slugs = list(dict.fromkeys(re.findall(r'href="(?:https?://[^"/]+)?/[fv]/([A-Za-z0-9_-]{4,})"', html)))
    if not slugs:
        raise NeedsBrowser("no file list on the album page")
    return _pool(file_page, slugs)


# ----------------------------------------------------------------------------- read in the browser


def file_id_from_url(host: str, url: str) -> str:
    """A file's id from its address, when only that is known (a file a page plays or links)."""
    if host == "gofile" and (m := re.search(r"/download/(?:web/)?([0-9a-f-]{20,})/", url, re.I)):
        return safe_id(m.group(1))
    if host == "pixeldrain" and (m := re.search(r"/api/file/([A-Za-z0-9]{4,})", url)):
        return m.group(1)
    name = urlsplit(url).path.rstrip("/").rsplit("/", 1)[-1]
    return safe_id(name.rsplit(".", 1)[0] if "." in name else name) or hashlib.sha1(url.encode()).hexdigest()[:16]


def from_page(link: Link, page: dict) -> list[Remote]:
    """The videos a folder's page showed (`HOST_PAGE_JS`): the files it plays or links, and the pages of
    the files in it (each read in the browser when its turn comes). Pages named as something other than a
    video (a photo, an archive) are left out."""
    out: dict[str, Remote] = {}
    for f in page.get("files") or []:
        url, name = str(f.get("url") or ""), str(f.get("name") or "")
        if not url.startswith("http"):
            continue
        r = Remote(link.host, safe_id(str(f.get("id") or "")) or file_id_from_url(link.host, url),
                   name=name or url.rsplit("/", 1)[-1].split("?")[0], size=int(f.get("size") or 0),
                   url=url, page=str(page.get("href") or link.url), referer=str(page.get("href") or link.url))
        out.setdefault(r.key, r)
    for p in page.get("pages") or []:
        sub = classify(str(p.get("url") or ""))
        name = str(p.get("name") or "")
        if not sub or sub.kind != "file" or sub.host != link.host or not maybe_video(name):
            continue
        if sub.host == "fileditch":
            out.update({r.key: r for r in expand(sub, "") if r.key not in out})
            continue
        r = Remote(sub.host, safe_id(sub.ident), name=name if is_video_name(name) else "", page=sub.url, referer=sub.url)
        out.setdefault(r.key, r)
    return list(out.values())


def api_trouble(page: dict | None) -> str:
    """What the site's own API calls ran into (`HOST_PAGE_JS` → `api`, from `CAPTURE_JS`): "rate" when it
    was rate-limited, the API's status when it was turned down, "" when all is well (or nothing called)."""
    for a in (page or {}).get("api") or []:
        status, said = int(a.get("status") or 0), str(a.get("api") or "")
        if status == 429 or said == "error-rateLimit":
            return "rate"
        if status in (401, 403) or said in ("error-notPremium", "error-token", "error-wrongToken", "error-banned"):
            return said or f"HTTP {status}"
    return ""


def best_file(page: dict) -> tuple[str, str] | None:
    """The file a single file's page plays or links: (address, name)."""
    for f in page.get("files") or []:
        url = str(f.get("url") or "")
        if url.startswith("http"):
            return url, str(f.get("name") or page.get("name") or "")
    return None


# What a host's page holds: the video it plays or links (`files`, best first — a playing <video>, the
# videos it has loaded, links to video files or download links named as one), the pages of the files in a
# folder (`pages`), and its heading (`name`). Kept identical to PhotoBrowser/SimpCityHosts.swift.
HOST_PAGE_JS = r"""
(() => {
  const title = document.title || '';
  const text = ((document.body && document.body.innerText) || '').slice(0, 2000);
  const checking = /Just a moment|DDoS-Guard|Checking your browser|Attention Required|Verify you are human/i.test(title)
    || !!document.querySelector('#challenge-form, #cf-challenge-running, .cf-turnstile, [data-ddg-origin]');
  const abs = (v) => { try { return new URL(v || '', location.href).href; } catch (e) { return ''; } };
  const VIDEO = /\.(mp4|mov|m4v|webm|mkv)(?:[?#]|$)/i;
  const bad = (u) => !/^https?:/i.test(u) || /\/thumbs?\/|[._-](thumb|preview|poster)[._-]|maint(enance)?(-vid)?\.mp4/i.test(u);
  const clean = (s) => (s || '').replace(/\s+/g, ' ').trim().slice(0, 200);
  const files = [];
  const seen = new Set();
  const add = (raw, name, w) => {
    const u = abs(raw);
    const n = clean(name);
    if (!u || bad(u) || seen.has(u)) return;
    if (!(w >= 100 || VIDEO.test(u) || VIDEO.test(n))) return;
    seen.add(u);
    files.push({ url: u, name: n, w: w });
  };
  try { document.querySelectorAll('video').forEach((v) => { if (v.paused && v.play) { v.muted = true; v.play().catch(() => {}); } }); } catch (e) {}
  document.querySelectorAll('video').forEach((v) => add(v.currentSrc || v.getAttribute('src'), '', 100));
  document.querySelectorAll('video source[src]').forEach((s) => add(s.getAttribute('src'), '', 100));
  try { performance.getEntriesByType('resource').forEach((e) => { if (VIDEO.test(e.name)) add(e.name, '', 95); }); } catch (e) {}
  document.querySelectorAll('a[href]').forEach((a) => {
    const h = a.getAttribute('href') || '';
    const n = a.getAttribute('download') || a.getAttribute('title') || a.textContent || '';
    if (VIDEO.test(h) || (VIDEO.test(n) && (a.hasAttribute('download') || /\/(download|dl|files?|get)\b/i.test(h)))) add(h, n, 90);
  });
  document.querySelectorAll('meta[property="og:video"], meta[property="og:video:url"], meta[property="og:video:secure_url"]')
    .forEach((m) => add(m.getAttribute('content'), '', 70));
  // What the site's own API calls answered (CAPTURE_JS — gofile's folder listings): its videos, exactly.
  const api = [];
  (window.__pbCaptured || []).forEach((c) => {
    const j = (c && c.json) || {};
    api.push({ status: c.status || 0, api: j.status || '' });
    const d = j.data;
    if (!d || d.canAccess === false) return;
    const kids = d.type === 'file' ? [d] : Object.values(d.children || {});
    kids.forEach((k) => {
      if (!k || k.type === 'folder' || !k.link || seen.has(k.link)) return;
      if (!(VIDEO.test(k.name || '') || /^video\//i.test(k.mimetype || ''))) return;
      seen.add(k.link);
      files.push({ url: k.link, name: clean(k.name), w: 110, size: k.size || 0, id: k.id || '' });
    });
  });
  files.sort((a, b) => b.w - a.w);
  const here = location.href.split('#')[0];
  const pages = [];
  const seenPages = new Set([here]);
  document.querySelectorAll('a[href]').forEach((a) => {
    const u = abs(a.getAttribute('href')).split('#')[0];
    if (seenPages.has(u)) return;
    if (!/^https?:\/\/(?:[^\/]*\.)?(bunkrr?|cyberdrop|filester|pixeldra(?:in)?|fileditch[a-z]*)\.[a-z]+\/(?:f|v|i|d|u)\/[A-Za-z0-9_-]{4,}|fileditch[a-z]*\.[a-z]+\/file\.php\?/i.test(u)) return;
    seenPages.add(u);
    pages.push({ url: u, name: clean(a.getAttribute('title') || a.getAttribute('download') || a.textContent) });
  });
  const h1 = document.querySelector('h1');
  const og = document.querySelector('meta[property="og:title"]');
  const name = clean((h1 && h1.textContent) || (og && og.getAttribute('content')) || title);
  const gone = files.length === 0 && /not found|404|removed|deleted|does ?n[o']t exist|no longer available|expired/i.test(title + ' ' + text.slice(0, 600));
  return { challenge: checking && files.length === 0, files: files.slice(0, 500), pages: pages.slice(0, 1000), name: name,
           title: title, gone: gone, api: api, ready: document.readyState, href: location.href };
})()
"""

# Injected into every page before its own scripts (Safe Finder: a profile script at document creation;
# iPhone: a user script at document start). On gofile only, it keeps the answers of the site's own
# `/contents/` API calls — the folder listing, signed by gofile's own script — in `window.__pbCaptured`
# for `HOST_PAGE_JS`. It only watches; it never sends anything. Kept identical to the Swift copy.
CAPTURE_JS = r"""
(() => {
  if (window.__pbCapture || !/(^|\.)gofile\.io$/.test(location.hostname)) return;
  window.__pbCapture = true;
  window.__pbCaptured = [];
  const wanted = (u) => /^https:\/\/api[^\/]*\.gofile\.io\/contents\//.test(String(u || ''));
  const keep = (u, status, text) => {
    let json = null;
    try { json = JSON.parse(text); } catch (e) {}
    window.__pbCaptured.push({ url: String(u), status: status, json: json });
    if (window.__pbCaptured.length > 40) window.__pbCaptured.shift();
  };
  const realFetch = window.fetch;
  if (realFetch) {
    window.fetch = function (input, init) {
      const u = (input && input.url) || input;
      const p = realFetch.apply(this, arguments);
      if (wanted(u)) p.then((r) => r.clone().text().then((t) => keep(u, r.status, t))).catch(() => {});
      return p;
    };
  }
  const open = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = function (m, u) { this.__pbUrl = u; return open.apply(this, arguments); };
  const send = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.send = function () {
    if (wanted(this.__pbUrl)) this.addEventListener('load', () => { try { keep(this.__pbUrl, this.status, this.responseText); } catch (e) {} });
    return send.apply(this, arguments);
  };
})();
"""


# A file page that shows its file only behind a button: press the one that says "download" (not an app,
# premium or sign-up button). The page then plays it, links it, or hands the browser a download.
CLICK_DOWNLOAD_JS = r"""
(() => {
  const label = (e) => ((e.textContent || '') + ' ' + (e.value || '') + ' ' + (e.id || '') + ' '
    + (typeof e.className === 'string' ? e.className : '') + ' ' + (e.getAttribute('aria-label') || '')).toLowerCase();
  const shown = (e) => { const r = e.getBoundingClientRect(); return r.width > 0 && r.height > 0; };
  const hit = Array.from(document.querySelectorAll('a, button, [role="button"], input[type="submit"], input[type="button"]'))
    .find((e) => shown(e) && /download/.test(label(e)) && !/\bapp\b|premium|upgrade|torrent|log ?in|sign ?up|register/.test(label(e)));
  if (!hit) return { clicked: false };
  hit.click();
  return { clicked: true, label: label(hit).replace(/\s+/g, ' ').trim().slice(0, 80) };
})()
"""
