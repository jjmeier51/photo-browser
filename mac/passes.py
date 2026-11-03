"""Safe Finder — Passes.com helpers (no Qt).

Provides: token exchange, gallery and message pagination, per-post item building,
and the shared-record type (.passes.json on the drive).  Same pattern as
instagram.py / facebook.py; passes_downloader.py is the Qt window.

A message's content is nested: `contents[0]` is another message-shaped object
with its own `contents`, so item building walks down rather than reading one
level.

Passes support (Case PS-48213, 2026-11-03) confirms purchased content may be
kept locally for personal use.  Personal archive only, no redistribution.
"""
from __future__ import annotations

import datetime
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Callable, Iterator

import social

# ── constants ────────────────────────────────────────────────────────────────

TAG      = "passes"
RECORD   = ".passes.json"
FORMAT   = "photobrowser-passes"
HOME     = "https://www.passes.com/"
LOGIN    = "https://www.passes.com/login"
# patterns whose URL signals a successful login so we can read the token
SUCCESS_RE = re.compile(r"passes\.com/(auth/success|home|feed|gallery)", re.I)

API = "https://www.passes.com/api"

KEYCHAIN_SERVICE = "Safe Finder Passes"
KEYCHAIN_ACCOUNT = "refresh-token"
SETTINGS_KEY     = "passes/refresh_token"   # QSettings fallback
DEVICE_SETTING   = "passes/device"          # path to a .wvd

KEYWORD = "Passes"
GAP     = 0.3    # seconds between listing pages

_UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
       "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36")

# contentIds whose `original` variant is an encrypted DASH manifest, mapped to its URL.
# Populated by items_from_post(); consumed by passes_decrypt.grab_original().
ENCRYPTED: dict[str, str] = {}

# contentIds whose chosen URL is a manifest, mapped to a plain one-file URL when the
# API offers one.  Used as the fallback when a manifest download fails.
PLAIN: dict[str, str] = {}

# contentIds with no `original` variant, mapped to their signedContent key list.
# Diagnostic only — these are the ones that carry Passes' watermark.
MISSING: dict[str, str] = {}

# ── shape recorder (diagnostic) ───────────────────────────────────────────────

_SHAPE_FILE = Path.home() / "Library" / "Caches" / "PhotoBrowser" / "passes-shapes.txt"
_shapes_left = 14


def _shape(line: str) -> None:
    """Appends one line about a message shape, for the first few of a run."""
    global _shapes_left
    if _shapes_left <= 0:
        return
    _shapes_left -= 1
    try:
        _SHAPE_FILE.parent.mkdir(parents=True, exist_ok=True)
        with _SHAPE_FILE.open("a", encoding="utf-8") as f:
            f.write(line + "\n")
    except OSError:
        pass


# ── secret storage ────────────────────────────────────────────────────────────

def get_refresh_token() -> str:
    """Reads the stored refresh token (Keychain on Mac, QSettings fallback).

    Passes keeps the token JSON-encoded in localStorage, so a stored value can
    arrive wrapped in quotes — those are stripped here.
    """
    if sys.platform == "darwin":
        try:
            r = subprocess.run(
                ["security", "find-generic-password",
                 "-s", KEYCHAIN_SERVICE, "-a", KEYCHAIN_ACCOUNT, "-w"],
                capture_output=True, text=True, timeout=10)
            if r.returncode == 0:
                return r.stdout.strip().strip('"')
        except (OSError, subprocess.SubprocessError):
            pass
    from PySide6.QtCore import QSettings
    return str(QSettings("PhotoBrowser", "SafeFinder").value(SETTINGS_KEY, "")
               or "").strip().strip('"')


def set_refresh_token(token: str) -> None:
    """Stores the refresh token in the Keychain (or QSettings fallback)."""
    token = token.strip().strip('"')
    if sys.platform == "darwin":
        try:
            if not token:
                subprocess.run(["security", "delete-generic-password",
                                "-s", KEYCHAIN_SERVICE, "-a", KEYCHAIN_ACCOUNT],
                               capture_output=True, timeout=10)
            else:
                subprocess.run(["security", "add-generic-password", "-U",
                                "-s", KEYCHAIN_SERVICE, "-a", KEYCHAIN_ACCOUNT,
                                "-w", token],
                               capture_output=True, timeout=10)
            return
        except (OSError, subprocess.SubprocessError):
            pass
    from PySide6.QtCore import QSettings
    s = QSettings("PhotoBrowser", "SafeFinder")
    if token:
        s.setValue(SETTINGS_KEY, token)
    else:
        s.remove(SETTINGS_KEY)


def device_path() -> Path:
    """Where the Widevine .wvd lives. Swappable; nothing is committed to the repo."""
    from PySide6.QtCore import QSettings
    p = str(QSettings("PhotoBrowser", "SafeFinder").value(DEVICE_SETTING, "") or "")
    if p:
        return Path(p).expanduser()
    return Path.home() / "Library/Application Support/SafeFinder/device.wvd"


# ── API helpers ───────────────────────────────────────────────────────────────

def _post(path: str, body: dict, access_token: str) -> dict:
    """One authenticated POST to the Passes API."""
    data = json.dumps(body).encode()
    req  = urllib.request.Request(
        f"{API}{path}", data=data,
        headers={
            "Authorization": f"Bearer {access_token}",
            "Content-Type":  "application/json",
            "User-Agent":    _UA,
            "Origin":        "https://www.passes.com",
            "Referer":       "https://www.passes.com/",
        })
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read())


def exchange_token(refresh_token: str) -> str:
    """Refresh token → short-lived access token via /api/auth/refresh."""
    req = urllib.request.Request(
        f"{API}/auth/refresh",
        data=b"{}",
        headers={
            "Authorization": f"Bearer {refresh_token.strip().strip('\"')}",
            "Content-Type":  "application/json",
            "User-Agent":    _UA,
        })
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.loads(r.read())["accessToken"]


def creator_username(user_id: str, access_token: str) -> str:
    """Folder-safe display name for a userId.  Falls back to userId."""
    try:
        doc  = _post("/profile/get", {"creatorId": user_id}, access_token)
        user = doc.get("user") or {}
        name = (user.get("username") or user.get("displayName")
                or doc.get("username") or "").strip()
        return name or user_id
    except Exception:           # noqa: BLE001
        return user_id


# ── listing ───────────────────────────────────────────────────────────────────

def _more(doc: dict) -> bool:
    """True when the API says there is another page."""
    return bool(doc.get("hasMore") or doc.get("hasNextPage"))


def gallery_pages(access_token: str,
                  creator_id: str | None = None) -> Iterator[list[dict]]:
    """Yields successive pages of post dicts from the purchased-content gallery."""
    body: dict = {"search": "", "order": "desc"}
    if creator_id:
        body["creatorId"] = creator_id
    while True:
        try:
            doc = _post("/content/purchased/content", body, access_token)
        except urllib.error.HTTPError as e:
            raise RuntimeError(f"Passes API error {e.code}: {e.reason}") from e
        data = doc.get("data") or []
        if data:
            yield data
        if not _more(doc):
            break
        body["createdAt"] = doc.get("createdAt")
        body["lastId"]    = doc.get("lastId")
        time.sleep(GAP)


def channel_id(access_token: str, username: str) -> str | None:
    """The message channel id with `username`, or None."""
    body: dict = {"orderType": "recent", "order": "desc"}
    while True:
        doc = _post("/channel/channels", body, access_token)
        for ch in doc.get("data") or []:
            other = ch.get("otherUser") or {}
            if other.get("username") == username:
                return ch.get("channelId")
        if not _more(doc):
            return None
        body["recentAt"] = doc.get("recentAt")
        body["lastId"]   = doc.get("lastId")
        time.sleep(GAP)


def messages_pages(access_token: str, username: str,
                   log: Callable[[str], None] | None = None) -> Iterator[list[dict]]:
    """Yields successive pages of message dicts from the channel with `username`."""
    cid = channel_id(access_token, username)
    if not cid:
        raise RuntimeError(f'no message channel with "{username}"')
    body: dict = {"channelId": cid, "contentOnly": False, "pending": False}
    last_id = None
    page = 0
    while True:
        page += 1
        doc = _post("/messages/messages", body, access_token)
        data = doc.get("data") or []
        if log:
            log(f"page {page}: {len(data)} message(s), "
                f"hasNextPage={doc.get('hasNextPage')!r} hasMore={doc.get('hasMore')!r} "
                f"lastId={'yes' if doc.get('lastId') else 'no'} "
                f"lastSentAt={'yes' if doc.get('lastSentAt') else 'no'}")
        if data:
            yield data
        if not _more(doc):
            break
        nid = doc.get("lastId")
        if nid is not None and nid == last_id:      # cursor stopped moving
            if log:
                log("cursor did not advance — stopping")
            break
        last_id = nid
        body["lastSentAt"] = doc.get("lastSentAt")
        body["lastId"]     = nid
        time.sleep(GAP)


# ── post → social.Item list ───────────────────────────────────────────────────

def _ts(s: str | None) -> float:
    """ISO-8601 timestamp string → unix float; 0 on any failure."""
    if not s:
        return 0
    try:
        dt = datetime.datetime.fromisoformat(s.replace("Z", "+00:00"))
        return dt.timestamp()
    except (ValueError, AttributeError):
        return 0


def _is_manifest(url: str) -> bool:
    path = url.split("?")[0].lower()
    return path.endswith((".mpd", ".m3u8"))


def _walk(node, out: list[dict], depth: int = 0) -> None:
    """Collect every content object under `node`, however deeply nested."""
    if depth > 4 or not isinstance(node, dict):
        return
    if node.get("contentId") or node.get("postId"):
        out.append(node)
        return
    for child in node.get("contents") or []:
        _walk(child, out, depth + 1)
    snap = node.get("replyMessageSnapshot")
    if isinstance(snap, dict):
        _walk(snap, out, depth + 1)


def items_from_post(post: dict, folder: Path,
                    already: set[str]) -> list[social.Item]:
    """Build social.Item entries for all contents in a post not yet in `already`."""
    date   = _ts(post.get("createdAt") or post.get("sentAt"))
    poster = post.get("sender") if isinstance(post.get("sender"), str) else ""
    poster = poster or post.get("username") or post.get("userId", "")

    found: list[dict] = []
    _walk(post, found)
    _shape(f"msg keys={sorted(post)} found={len(found)}")

    items: list[social.Item] = []
    for c in found:
        cid = c.get("contentId") or c.get("postId", "")
        sc  = c.get("signedContent") or {}
        if not cid:
            _shape(f"  SKIP no cid — keys={sorted(c)}")
            continue
        if cid in already:
            _shape(f"  skip already — {cid}")
            continue
        ct  = (c.get("contentType") or "").lower()
        ext = (c.get("extension") or "").lstrip(".")

        # the original variant is an encrypted DASH manifest; register it and let
        # passes_decrypt.grab_original() handle the item
        orig = sc.get("original") or ""
        if orig:
            ENCRYPTED[cid] = orig
        else:
            MISSING[cid] = (",".join(sorted(sc)) or "(empty)") + \
                f" wm={c.get('watermarkEnabled')!r}/{c.get('watermarked')!r}"

        url = orig or sc.get("large") or sc.get("signedUrl") or ""
        if not url:
            _shape(f"  SKIP no url — cid={cid} type={ct!r} "
                   f"wm={c.get('watermarkEnabled')!r} keys={sorted(c)} sc={sorted(sc)}")
            continue

        # remember a non-manifest URL to fall back to
        plain = sc.get("signedUrl") or sc.get("large") or ""
        if plain and not _is_manifest(plain):
            PLAIN[cid] = plain

        video = ct == "video"
        if not ext:
            ext = "mp4" if video else "jpg"
        items.append(social.Item(
            key     = cid,
            folder  = folder,
            name    = cid,
            video   = video,
            url     = url,
            ext     = ext,
            date    = date,
            poster  = poster,
            keyword = KEYWORD,
        ))
    return items


# ── record helpers ────────────────────────────────────────────────────────────

def record(folder: str | Path) -> social.Record:
    return social.Record.load(folder, RECORD, FORMAT)


def ids_on_disk(folder: str | Path) -> set[str]:
    """Content ids (file stems) already present in `folder` (one level only)."""
    ids: set[str] = set()
    try:
        for e in os.scandir(folder):
            if not e.name.startswith("."):
                stem = e.name.rpartition(".")[0]
                if stem:
                    ids.add(stem)
    except OSError:
        pass
    return ids