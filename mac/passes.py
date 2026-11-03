"""Safe Finder — Passes.com helpers (no Qt).

Provides: token exchange, gallery pagination, per-post item building, and the
shared-record type (.passes.json on the drive).  Same pattern as instagram.py /
facebook.py; passes_downloader.py is the Qt window.

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
from typing import Iterator

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
GAP     = 0.3    # seconds between gallery pages

_UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
       "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36")

# contentIds whose `original` variant is an encrypted DASH manifest, mapped to its URL.
# Populated by items_from_post(); consumed by passes_decrypt.grab_original().
ENCRYPTED: dict[str, str] = {}

# ── secret storage ────────────────────────────────────────────────────────────

def get_refresh_token() -> str:
    """Reads the stored refresh token (Keychain on Mac, QSettings fallback)."""
    if sys.platform == "darwin":
        try:
            r = subprocess.run(
                ["security", "find-generic-password",
                 "-s", KEYCHAIN_SERVICE, "-a", KEYCHAIN_ACCOUNT, "-w"],
                capture_output=True, text=True, timeout=10)
            if r.returncode == 0:
                return r.stdout.strip()
        except (OSError, subprocess.SubprocessError):
            pass
    from PySide6.QtCore import QSettings
    return str(QSettings("PhotoBrowser", "SafeFinder").value(SETTINGS_KEY, "") or "")


def set_refresh_token(token: str) -> None:
    """Stores the refresh token in the Keychain (or QSettings fallback)."""
    token = token.strip()
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
            "Authorization": f"Bearer {refresh_token}",
            "Content-Type":  "application/json",
            "User-Agent":    _UA,
        })
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.loads(r.read())["accessToken"]


def creator_username(user_id: str, access_token: str) -> str:
    """Folder-safe display name for a userId.  Falls back to userId."""
    try:
        doc  = _post("/profile/get", {"creatorId": user_id}, access_token)
        name = (doc.get("username") or doc.get("displayName") or "").strip()
        return name or user_id
    except Exception:           # noqa: BLE001
        return user_id


# ── gallery pagination ────────────────────────────────────────────────────────

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
        if not doc.get("hasMore"):
            break
        body["createdAt"] = doc["createdAt"]
        body["lastId"]    = doc["lastId"]
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


def items_from_post(post: dict, folder: Path,
                    already: set[str]) -> list[social.Item]:
    """Build social.Item entries for all contents in a post not yet in `already`."""
    date   = _ts(post.get("createdAt") or post.get("sentAt"))
    poster = post.get("username") or post.get("userId", "")

    contents = post.get("contents") or []
    if not contents:
        contents = [post]          # post IS the single content item

    items: list[social.Item] = []
    for c in contents:
        cid = c.get("contentId") or c.get("postId", "")
        if not cid or cid in already:
            continue
        ct  = (c.get("contentType") or "").lower()
        ext = (c.get("extension") or "").lstrip(".")
        sc  = c.get("signedContent") or {}

        # the original variant is an encrypted DASH manifest; register it and let
        # passes_decrypt.grab_original() handle the item instead of social.settle()
        orig = sc.get("original") or ""
        if orig:
            ENCRYPTED[cid] = orig

        # fall back to the plain variants, then to the original if nothing else exists
        url = sc.get("large") or sc.get("signedUrl") or ""
        if not url:
            if orig:
                url = orig
            else:
                continue

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