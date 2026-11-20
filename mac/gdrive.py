"""Google Drive for Photo Browser for Mac — signing in, listing, and downloading files and whole folders with their
dates. No Qt here (gdrive_window.py is the window).

**Why not the iPhone's way.** The iPhone signs in to Google inside an in-app browser that says it is Safari, and
downloads with that browser's cookies. Google refuses sign-in in embedded browsers, and getting past that means
making the app's browser claim to be something it isn't — not done here. The Mac uses what Google provides for
desktop programs instead, which is also the only way to get a file's real dates:

- **Sign in with Google** — OAuth 2.0 for desktop apps (developers.google.com/identity/protocols/oauth2/native-app):
  the consent page opens in **the Mac's own browser**, and Google sends the answer to a one-shot listener on
  `127.0.0.1` (PKCE; the refresh token is kept in the Keychain). Read-only scope (`drive.readonly`). It needs an
  OAuth client of the person's own (a Client ID and "secret" from their Google Cloud project — `SETUP_STEPS`);
  nothing is shared with anyone else's project.
- **An API key** (optional) — for files and folders shared "anyone with the link", without signing in.
- **Neither** — a single file shared "anyone with the link" still comes (Drive's public download address, the
  iPhone's `uc?export=download` route without cookies); its dates can't be read that way, and a folder can't be
  listed.

**What comes down** (`Client.plan` → `Client.download`): the files picked and everything inside the folders picked,
the folder tree rebuilt under the destination. Each file is Drive's own bytes (`alt=media` — nothing re-encoded, so
EXIF, GPS, colour profile and every other bit of metadata inside it are exactly as uploaded), fetched through
`net_fetch` (length-checked, resumed, retried), then **checked against Drive's size and MD5** before it's put on the
drive (`net_fetch.put`: whole or not there). A file already there with the same size (and date, or checksum) is
skipped; one with the same name but different contents is kept beside it ("name 2.jpg") — nothing is overwritten.

**Dates**: the file's modified date is Drive's `modifiedTime` (the file's own date as it was uploaded) and its
creation date the earlier of that and Drive's `createdTime` (a photo taken in 2019 and uploaded in 2023 was not
created in 2023) — set together (`clone_drive.set_dates`), as everything here sets dates. Folders get their Drive
dates once their contents are in.

Google's own documents (Docs, Sheets, Slides…) aren't files and are left, counted. A shortcut is followed to what
it points at. Nothing is ever uploaded, changed or deleted on Drive: the scope is read-only.

Not run against Google from where this was written — against a stand-in for the API only (see feature-notes §7.4i).
"""
from __future__ import annotations

import base64
import hashlib
import http.server
import json
import os
import re
import secrets
import ssl
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable

import app_identity
import net_fetch

API = "https://www.googleapis.com/drive/v3"
AUTH = "https://accounts.google.com/o/oauth2/v2/auth"
TOKEN = "https://oauth2.googleapis.com/token"
REVOKE = "https://oauth2.googleapis.com/revoke"
PUBLIC = "https://drive.usercontent.google.com/download"
SCOPE = "https://www.googleapis.com/auth/drive.readonly"
CONSOLE = "https://console.cloud.google.com/apis/credentials"
AUDIENCE = "https://console.cloud.google.com/auth/audience"            # where a project's Test users are listed
# Google's "Access blocked: <project> has not completed the Google verification process … Error 403:
# access_denied" is shown in the browser only — nothing comes back to the app, which would just go on waiting. It
# means the address signing in isn't one of the project's Test users (the owner's isn't, until it's added).
BLOCKED_HELP = ("If Google's page says “Access blocked … has not completed the Google verification process” "
                "(Error 403: access_denied), your Google address isn't on your project's Test users list yet — "
                "even the project's owner has to be added. In the Google Cloud Console open OAuth consent screen ▸ "
                "Audience, press Add users under Test users, enter the address you sign in with, and save. Then "
                "sign in again. After that Google shows “Google hasn't verified this app” — that's expected for a "
                "project of your own: choose Continue.")
UA = "PhotoBrowser/1.0 (macOS; Photo Browser for Mac Google Drive)"
FOLDER = "application/vnd.google-apps.folder"
SHORTCUT = "application/vnd.google-apps.shortcut"
FIELDS = "id,name,mimeType,size,modifiedTime,createdTime,md5Checksum,trashed,shortcutDetails(targetId,targetMimeType)"
LANES = 4                              # files downloading at once
SIGN_IN_WAIT = 300                     # seconds the listener waits for the browser to come back
KEYCHAIN = app_identity.keychain_services("Google Drive")[0]

SETUP_STEPS = (
    "Google lets a desktop app into your Drive only through a project of your own — a one-time setup, about five "
    "minutes, free:\n\n"
    "1.  Open console.cloud.google.com and create a project (any name).\n"
    "2.  APIs & Services ▸ Library ▸ search “Google Drive API” ▸ Enable.\n"
    "3.  APIs & Services ▸ OAuth consent screen (Google also calls it “Google Auth Platform”): choose External, "
    "give it a name and your email.\n"
    "    IMPORTANT — under Audience ▸ Test users press Add users and add the Google address you'll sign in with "
    "(your own too). Without it Google answers “Access blocked … has not completed the Google verification "
    "process”. (Left in Testing, Google asks you to sign in again every 7 days. Publishing it removes that.)\n"
    "4.  APIs & Services ▸ Credentials (or Google Auth Platform ▸ Clients) ▸ Create ▸ OAuth client ID ▸ Application "
    "type: Desktop app. Copy the Client ID and the Client secret into the two boxes here.\n"
    "5.  Optional — for links shared with “anyone with the link”, without signing in: Create Credentials ▸ API key, "
    "and paste it in the third box.\n\n"
    "Then press Sign In with Google: your browser opens Google's own page (“Google hasn't verified this app” is "
    "expected for a project of your own — choose Continue), you approve read-only access, and the window carries "
    "on. The app can only read your Drive — it can't change or delete anything there."
)


class DriveError(Exception):
    """Something Drive (or the connection) refused, in words for the person."""


class NeedsSignIn(DriveError):
    pass


class Stopped(Exception):
    pass


# ----------------------------------------------------------------------------- settings and secrets

def _settings_file() -> Path:
    return app_identity.support() / "gdrive.json"


def load_settings() -> dict:
    try:
        return json.loads(_settings_file().read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def save_settings(values: dict) -> None:
    path = _settings_file()
    path.parent.mkdir(parents=True, exist_ok=True)
    kept = load_settings()
    kept.update(values)
    tmp = path.with_suffix(".part")
    tmp.write_text(json.dumps(kept, indent=1), encoding="utf-8")
    try:
        os.chmod(tmp, 0o600)
    except OSError:
        pass
    os.replace(tmp, path)


def _keychain(*args: str) -> subprocess.CompletedProcess | None:
    try:
        return subprocess.run(["security", *args], capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return None


def secret(name: str) -> str:
    """A secret by name ("client-secret", "refresh-token"): the Keychain on a Mac, a private file elsewhere."""
    if sys.platform == "darwin":
        r = _keychain("find-generic-password", "-s", KEYCHAIN, "-a", name, "-w")
        if r is not None and r.returncode == 0:
            return r.stdout.strip()
    return str((load_settings().get("secrets") or {}).get(name, ""))


def set_secret(name: str, value: str) -> None:
    value = value.strip()
    if sys.platform == "darwin":
        if not value:
            _keychain("delete-generic-password", "-s", KEYCHAIN, "-a", name)
            return
        r = _keychain("add-generic-password", "-U", "-s", KEYCHAIN, "-a", name, "-w", value)
        if r is not None and r.returncode == 0:
            return
    held = dict(load_settings().get("secrets") or {})
    if value:
        held[name] = value
    else:
        held.pop(name, None)
    save_settings({"secrets": held})


# ----------------------------------------------------------------------------- small HTTP (JSON answers)

def _context() -> ssl.SSLContext | None:
    try:
        import simpcity
        return simpcity.ssl_context()
    except Exception:  # noqa: BLE001
        return None


def _ask(method: str, url: str, headers: dict | None = None, data: bytes | None = None,
         timeout: float = 40) -> tuple[int, bytes, dict]:
    """One request → (status, body, headers); status 0 with the reason as the body when there was no answer."""
    req = urllib.request.Request(url, data=data, method=method, headers={"User-Agent": UA, **(headers or {})})
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=_context()) as resp:
            return resp.status, resp.read(), dict(resp.headers)
    except urllib.error.HTTPError as e:
        return e.code, e.read() or b"", dict(e.headers or {})
    except (urllib.error.URLError, OSError, ValueError) as e:
        return 0, str(getattr(e, "reason", e)).encode("utf-8", "replace"), {}


def _reason(body: bytes) -> tuple[str, str]:
    """(Drive's reason word, its message) from an error answer — ("", "") when it isn't Drive's JSON."""
    try:
        err = json.loads(body).get("error")
    except (ValueError, AttributeError):
        return "", ""
    if isinstance(err, str):                               # the token endpoint's shape
        try:
            return err, str(json.loads(body).get("error_description") or err)
        except ValueError:
            return err, err
    if not isinstance(err, dict):
        return "", ""
    first = (err.get("errors") or [{}])[0] if isinstance(err.get("errors"), list) else {}
    return str(first.get("reason") or err.get("status") or ""), str(err.get("message") or "")


REASONS = {
    "downloadQuotaExceeded": "Drive has stopped downloads of this file for now — too many people have fetched it "
                             "lately. Try again tomorrow.",
    "cannotDownloadAbusiveFile": "Drive has flagged this file as possibly harmful and won't hand it to an app. "
                                 "Download it in your browser if you trust it.",
    "fileNotDownloadable": "This is one of Google's own documents, not a file — export it from Drive instead.",
    "insufficientFilePermissions": "This account may look at this file but not download it (its owner turned "
                                   "downloading off).",
    "notFound": "Drive has no such item, or it isn't shared with this account.",
    "appNotAuthorizedToFile": "This account hasn't given the app access to that file.",
    "dailyLimitExceededUnreg": "Drive wants a sign-in or an API key for this — open Set Up.",
    "accessNotConfigured": "The Google Drive API isn't switched on in your Google Cloud project — step 2 in Set Up.",
    "keyInvalid": "Google doesn't accept the API key — check it in Set Up.",
    "API_KEY_INVALID": "Google doesn't accept the API key — check it in Set Up.",
}


def explain(status: int, body: bytes) -> str:
    reason, message = _reason(body)
    if reason in REASONS:
        return REASONS[reason]
    if status == 0:
        return f"Couldn't reach Google ({body.decode('utf-8', 'replace')[:120]})."
    if status == 401:
        return "Google asked for a new sign-in."
    if reason in ("rateLimitExceeded", "userRateLimitExceeded") or status == 429:
        return "Google asked to slow down — try again in a minute."
    return (message or f"Google answered HTTP {status}.") + (f" ({reason})" if reason and reason not in message else "")


# ----------------------------------------------------------------------------- signing in

def _b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


DONE_PAGE = ("<!doctype html><meta charset=utf-8><title>{app}</title><body style='font: 17px -apple-system, sans-serif; "
             "margin: 12vh auto; max-width: 30em; text-align: center'><h2>{head}</h2><p>{text}</p></body>")


class Auth:
    """Who the app is to Drive: signed in (a refresh token), an API key, or nobody."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._token = ""
        self._until = 0.0

    # -- what's set up
    @property
    def client_id(self) -> str:
        return str(load_settings().get("client_id") or "").strip()

    @property
    def api_key(self) -> str:
        return str(load_settings().get("api_key") or "").strip()

    @property
    def email(self) -> str:
        return str(load_settings().get("email") or "")

    def signed_in(self) -> bool:
        return bool(self.client_id and secret("refresh-token"))

    def can_sign_in(self) -> bool:
        return bool(self.client_id and secret("client-secret"))

    def save_setup(self, client_id: str, client_secret: str, api_key: str) -> None:
        changed = client_id.strip() != self.client_id
        save_settings({"client_id": client_id.strip(), "api_key": api_key.strip()})
        set_secret("client-secret", client_secret)
        if changed:                                        # another project: the old sign-in isn't its
            self.forget()

    # -- the browser round trip
    def sign_in(self, open_url: Callable[[str], None], stop: Callable[[], bool] | None = None) -> str:
        """Opens Google's consent page (in the Mac's browser, through `open_url`) and waits for it to come back to
        a listener on 127.0.0.1. → the account's email. Raises DriveError (said to the person) or Stopped."""
        if not self.can_sign_in():
            raise DriveError("Add your Google Cloud Client ID and Client secret first — Set Up.")
        verifier = _b64(secrets.token_bytes(48))
        challenge = _b64(hashlib.sha256(verifier.encode("ascii")).digest())
        state = _b64(secrets.token_bytes(18))
        got: dict[str, str] = {}

        class Back(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args) -> None:       # nothing to the terminal
                pass

            def do_GET(self) -> None:  # noqa: N802
                q = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
                if "state" not in q and "code" not in q and "error" not in q:
                    self.send_response(404)
                    self.end_headers()
                    return
                fine = q.get("state", [""])[0] == state and "code" in q
                got.update(code=q.get("code", [""])[0] if fine else "",
                           error=q.get("error", [""])[0] or ("" if fine else "the answer didn't match the request"))
                page = DONE_PAGE.format(app=app_identity.APP_NAME,
                                        head="Signed in" if fine else "That didn't work",
                                        text=f"You can close this tab and go back to {app_identity.APP_NAME}."
                                        if fine else f"Go back to {app_identity.APP_NAME} and try again.").encode()
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(page)))
                self.end_headers()
                self.wfile.write(page)

        server = http.server.HTTPServer(("127.0.0.1", 0), Back)
        server.timeout = 0.5
        redirect = f"http://127.0.0.1:{server.server_address[1]}"
        try:
            open_url(AUTH + "?" + urllib.parse.urlencode({
                "client_id": self.client_id, "redirect_uri": redirect, "response_type": "code", "scope": SCOPE,
                "code_challenge": challenge, "code_challenge_method": "S256", "state": state,
                "access_type": "offline", "prompt": "consent"}))
            deadline = time.monotonic() + SIGN_IN_WAIT
            while not got and time.monotonic() < deadline:
                if stop is not None and stop():
                    raise Stopped()
                server.handle_request()
        finally:
            server.server_close()
        if not got:
            raise DriveError("Google's page never came back — the sign-in wasn't finished in the browser.\n\n"
                             + BLOCKED_HELP)
        if not got.get("code"):
            why = got.get("error") or "no code"
            raise DriveError("You didn't allow access, so nothing was signed in." if why == "access_denied"
                             else f"Google didn't sign you in ({why}).")
        status, body, _h = _ask("POST", TOKEN, {"Content-Type": "application/x-www-form-urlencoded"},
                                urllib.parse.urlencode({
                                    "code": got["code"], "client_id": self.client_id,
                                    "client_secret": secret("client-secret"), "redirect_uri": redirect,
                                    "grant_type": "authorization_code", "code_verifier": verifier}).encode())
        try:
            doc = json.loads(body) if status == 200 else {}
        except ValueError:
            doc = {}
        if not doc.get("access_token"):
            reason, message = _reason(body)
            raise DriveError({"invalid_client": "Google doesn't know that Client ID and secret — check them in Set Up "
                                                "(the client must be of type “Desktop app”)."}.get(
                reason, f"Google didn't finish the sign-in ({message or reason or f'HTTP {status}'})."))
        if not doc.get("refresh_token"):
            raise DriveError("Google signed you in but gave no lasting permission — try again and tick the Drive box "
                             "on its page.")
        set_secret("refresh-token", str(doc["refresh_token"]))
        with self._lock:
            self._token = str(doc["access_token"])
            self._until = time.monotonic() + float(doc.get("expires_in") or 3000) - 90
        email = ""
        status, body, _h = _ask("GET", f"{API}/about?fields=user(emailAddress,displayName)", self.headers())
        if status == 200:
            try:
                user = json.loads(body).get("user") or {}
                email = str(user.get("emailAddress") or user.get("displayName") or "")
            except ValueError:
                email = ""
        save_settings({"email": email})
        return email

    def access_token(self) -> str:
        """A token good for at least a minute — asked for afresh with the refresh token when the last one is old."""
        with self._lock:
            if self._token and time.monotonic() < self._until:
                return self._token
            refresh = secret("refresh-token")
            if not (refresh and self.client_id):
                raise NeedsSignIn("Sign in with Google first.")
            status, body, _h = _ask("POST", TOKEN, {"Content-Type": "application/x-www-form-urlencoded"},
                                    urllib.parse.urlencode({
                                        "client_id": self.client_id, "client_secret": secret("client-secret"),
                                        "refresh_token": refresh, "grant_type": "refresh_token"}).encode())
            try:
                doc = json.loads(body) if status == 200 else {}
            except ValueError:
                doc = {}
            if not doc.get("access_token"):
                reason, _message = _reason(body)
                if reason in ("invalid_grant", "invalid_client", "unauthorized_client"):
                    # (a project left in Testing: Google ends the sign-in after 7 days)
                    set_secret("refresh-token", "")
                    raise NeedsSignIn("Google has ended the sign-in — sign in again. (A project left in “Testing” is "
                                      "signed out every 7 days.)")
                raise DriveError(explain(status, body))
            self._token = str(doc["access_token"])
            self._until = time.monotonic() + float(doc.get("expires_in") or 3000) - 90
            return self._token

    def headers(self) -> dict[str, str]:
        """The headers a request to Drive carries: the signed-in account's token, or none (the key goes in the
        address — `Client._url`)."""
        if self.signed_in() or self._token:
            return {"Authorization": f"Bearer {self.access_token()}", "User-Agent": UA}
        return {"User-Agent": UA}

    def forget(self) -> None:
        with self._lock:
            self._token, self._until = "", 0.0
        set_secret("refresh-token", "")
        save_settings({"email": ""})

    def sign_out(self) -> None:
        """Tells Google the permission is over, and forgets it here."""
        refresh = secret("refresh-token")
        if refresh:
            _ask("POST", REVOKE, {"Content-Type": "application/x-www-form-urlencoded"},
                 urllib.parse.urlencode({"token": refresh}).encode(), timeout=15)
        self.forget()


# ----------------------------------------------------------------------------- items

def _when(text) -> float:
    """RFC 3339 ("2023-05-01T12:34:56.789Z") → seconds since 1970 (0.0 when it isn't one)."""
    if not isinstance(text, str) or not text:
        return 0.0
    try:
        return datetime.fromisoformat(text.replace("Z", "+00:00")).astimezone(timezone.utc).timestamp()
    except ValueError:
        return 0.0


@dataclass
class Item:
    id: str
    name: str
    mime: str = ""
    size: int = 0
    modified: float = 0.0
    created: float = 0.0
    md5: str = ""
    target: str = ""                   # a shortcut: what it points at
    target_mime: str = ""

    @property
    def is_folder(self) -> bool:
        return self.mime == FOLDER or (self.mime == SHORTCUT and self.target_mime == FOLDER)

    @property
    def is_doc(self) -> bool:
        """One of Google's own documents (Docs, Sheets…): there are no bytes to download."""
        mime = self.target_mime if self.mime == SHORTCUT else self.mime
        return mime.startswith("application/vnd.google-apps.") and mime != FOLDER

    @property
    def real_id(self) -> str:
        return self.target or self.id

    @staticmethod
    def of(doc: dict) -> "Item | None":
        if not isinstance(doc, dict) or not doc.get("id") or doc.get("trashed") is True:
            return None
        sc = doc.get("shortcutDetails") if isinstance(doc.get("shortcutDetails"), dict) else {}
        try:
            size = int(doc.get("size") or 0)
        except (TypeError, ValueError):
            size = 0
        return Item(str(doc["id"]), str(doc.get("name") or doc["id"]), str(doc.get("mimeType") or ""), size,
                    _when(doc.get("modifiedTime")), _when(doc.get("createdTime")), str(doc.get("md5Checksum") or ""),
                    str(sc.get("targetId") or ""), str(sc.get("targetMimeType") or ""))


_LINK_IDS = (r"/folders/([A-Za-z0-9_-]{10,})", r"/file/d/([A-Za-z0-9_-]{10,})", r"/d/([A-Za-z0-9_-]{10,})",
             r"[?&]id=([A-Za-z0-9_-]{10,})")


def ids_in(text: str) -> list[str]:
    """Every Drive file / folder id in what was pasted — links (any of Drive's shapes) or bare ids, one or many."""
    out: list[str] = []
    for word in re.split(r"[\s,;<>\"']+", text or ""):
        if not word:
            continue
        found = next((m.group(1) for p in _LINK_IDS if (m := re.search(p, word))), None)
        if found is None and "/" not in word and re.fullmatch(r"[A-Za-z0-9_-]{20,}", word):
            found = word
        if found and found not in out:
            out.append(found)
    return out


def natural(name: str):
    return [int(t) if t.isdigit() else t.casefold() for t in re.split(r"(\d+)", name)]


# ----------------------------------------------------------------------------- the plan and its jobs

@dataclass
class Job:
    item: Item
    folder: str                        # where it goes on the drive (made when the run starts)
    name: str


@dataclass
class Plan:
    jobs: list[Job] = field(default_factory=list)
    folders: list[tuple[str, Item]] = field(default_factory=list)      # made first; dated when all is in
    docs: int = 0                      # Google's own documents, left
    here: int = 0                      # files already on the drive, left
    unread: list[str] = field(default_factory=list)                    # folders Drive wouldn't list

    @property
    def bytes(self) -> int:
        return sum(j.item.size for j in self.jobs)


@dataclass
class Done:
    job: Job
    path: str = ""                     # where it is now ("" when it failed)
    why: str = ""                      # why it failed
    dated: bool = True                 # its Drive dates are on it


def md5_of(path: str, stop: Callable[[], bool] | None = None) -> str:
    h = hashlib.md5()                  # noqa: S324 — Drive's own checksum, compared, not a secret
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            if stop is not None and stop():
                raise Stopped()
            h.update(chunk)
    return h.hexdigest()


def put_dates(path: str, created: float, modified: float) -> bool:
    """Drive's dates onto a file or folder: modified = Drive's modified time; created = the earlier of Drive's
    created time and that (module notes). Both in one call on a Mac. → whether the modified date took."""
    if modified <= 0:
        return False
    birth = min(created, modified) if created > 0 else modified
    m_ns, b_ns = int(modified * 1e9), int(birth * 1e9)
    done = False
    try:
        import clone_drive
        done = bool(clone_drive.set_dates(path, b_ns, m_ns, m_ns))
    except Exception:  # noqa: BLE001 — not a Mac, or the call isn't there: the modified date alone
        done = False
    if not done:
        try:
            os.utime(path, ns=(m_ns, m_ns))
        except OSError:
            return False
    try:
        return abs(os.stat(path).st_mtime - modified) < 2
    except OSError:
        return False


def already_here(item: Item, path: str) -> bool:
    """Whether `path` is this Drive file already: the same size, and the same date or (when the dates differ)
    the same checksum. A cut-off earlier download (another size) isn't."""
    try:
        st = os.stat(path)
    except OSError:
        return False
    if not os.path.isfile(path):
        return False
    if item.size and st.st_size != item.size:
        return False
    if item.modified and abs(st.st_mtime - item.modified) < 2:
        return True
    if item.md5:
        try:
            return md5_of(path) == item.md5
        except OSError:
            return False
    return bool(item.size)


def here_as(item: Item, folder: str, name: str, claimed: set[str]) -> bool:
    """Whether this Drive file is in `folder` already — as `name`, or as the "name 2", "name 3"… an earlier run
    gave it because Drive had several files of that name in one folder. A file on the drive answers for one Drive
    file only (`claimed`), so two of a name that happen to match in size and date both still come."""
    stem, ext = os.path.splitext(name)
    n, candidate = 1, name
    while n <= 500 and os.path.lexists(os.path.join(folder, candidate)):
        path = os.path.join(folder, candidate)
        if path.casefold() not in claimed and already_here(item, path):
            claimed.add(path.casefold())
            return True
        n += 1
        candidate = f"{stem} {n}{ext}"
    return False


def free_name(folder: str, name: str, taken: set[str]) -> str:
    """`name`, or "name 2.ext"… — one nothing in `folder` (or this run, `taken`) has."""
    stem, ext = os.path.splitext(name)
    n, candidate = 1, name
    while os.path.lexists(os.path.join(folder, candidate)) or os.path.join(folder, candidate).casefold() in taken:
        n += 1
        candidate = f"{stem} {n}{ext}"
    taken.add(os.path.join(folder, candidate).casefold())
    return candidate


class Client:
    def __init__(self, auth: Auth | None = None) -> None:
        self.auth = auth or Auth()

    # -- asking Drive
    def _url(self, path: str, params: dict | None = None) -> str:
        q = dict(params or {})
        if not self.auth.signed_in() and self.auth.api_key:
            q["key"] = self.auth.api_key
        return f"{API}/{path}" + ("?" + urllib.parse.urlencode(q) if q else "")

    def _json(self, path: str, params: dict | None = None, stop: Callable[[], bool] | None = None) -> dict:
        """GET → the JSON answer. A busy answer (429, 5xx, a rate-limit 403) is waited out and asked again; a 401
        gets one fresh token. Raises DriveError / NeedsSignIn / Stopped."""
        if not self.auth.signed_in() and not self.auth.api_key:
            raise NeedsSignIn("Sign in with Google (or add an API key in Set Up) to look inside Drive.")
        fresh = False
        for attempt in range(1, 6):
            if stop is not None and stop():
                raise Stopped()
            status, body, headers = _ask("GET", self._url(path, params), self.auth.headers())
            if status == 200:
                try:
                    return json.loads(body)
                except ValueError:
                    raise DriveError("Google sent something that isn't an answer.") from None
            reason, _m = _reason(body)
            if status == 401 and self.auth.signed_in() and not fresh:
                fresh = True
                with self.auth._lock:
                    self.auth._token, self.auth._until = "", 0.0
                continue
            busy = status in (0, 429, 500, 502, 503, 504) or reason in ("rateLimitExceeded", "userRateLimitExceeded")
            if busy and attempt < 5:
                net_fetch.wait(net_fetch.backoff(attempt, retry_after=net_fetch.retry_after_of(headers)), stop)
                continue
            if status == 401:
                raise NeedsSignIn("Google asked for a new sign-in.")
            raise DriveError(explain(status, body))
        raise DriveError("Google kept asking to slow down.")

    def info(self, file_id: str, stop=None) -> Item:
        item = Item.of(self._json(f"files/{urllib.parse.quote(file_id, safe='')}",
                                  {"fields": FIELDS, "supportsAllDrives": "true"}, stop))
        if item is None:
            raise DriveError("That item is in Drive's bin, or isn't there.")
        return item

    def _list(self, query: str, stop=None, corpora: dict | None = None) -> list[Item]:
        out: list[Item] = []
        token = ""
        while True:
            params = {"q": query, "fields": f"nextPageToken,files({FIELDS})", "pageSize": "1000",
                      "supportsAllDrives": "true", "includeItemsFromAllDrives": "true", **(corpora or {})}
            if token:
                params["pageToken"] = token
            doc = self._json("files", params, stop)
            out += [it for f in doc.get("files") or [] if (it := Item.of(f)) is not None]
            token = str(doc.get("nextPageToken") or "")
            if not token:
                break
        out.sort(key=lambda it: (not it.is_folder, natural(it.name)))
        return out

    def children(self, folder_id: str, stop=None) -> list[Item]:
        safe = folder_id.replace("\\", "\\\\").replace("'", "\\'")
        return self._list(f"'{safe}' in parents and trashed = false", stop)

    def place(self, which: str, stop=None) -> list[Item]:
        """A starting place: "root" (My Drive), "shared" (Shared with me), "starred", or "drives" (shared drives,
        each as a folder)."""
        if which == "root":
            return self.children("root", stop)
        if which == "shared":
            return self._list("sharedWithMe = true and trashed = false", stop)
        if which == "starred":
            return self._list("starred = true and trashed = false", stop)
        if which == "drives":
            out, token = [], ""
            while True:
                doc = self._json("drives", {"pageSize": "100", **({"pageToken": token} if token else {})}, stop)
                out += [Item(str(d["id"]), str(d.get("name") or d["id"]), FOLDER) for d in doc.get("drives") or []
                        if isinstance(d, dict) and d.get("id")]
                token = str(doc.get("nextPageToken") or "")
                if not token:
                    return sorted(out, key=lambda it: natural(it.name))
        raise DriveError("No such place.")

    def search(self, words: str, stop=None) -> list[Item]:
        safe = words.replace("\\", "\\\\").replace("'", "\\'")
        return self._list(f"name contains '{safe}' and trashed = false", stop)

    # -- what a run will do
    def plan(self, items: list[Item], dest: str, stop: Callable[[], bool] | None = None,
             note: Callable[[str], None] | None = None) -> Plan:
        """The files to fetch for `items` (files and folders, the folders read all the way down) into `dest`."""
        plan = Plan()
        taken: set[str] = set()
        claimed: set[str] = set()
        seen: set[str] = set()

        def add_file(item: Item, folder: str) -> None:
            if item.is_doc:
                plan.docs += 1
                return
            name = net_fetch.safe_name(item.name) or f"drive-{item.real_id}"
            if here_as(item, folder, name, claimed):
                plan.here += 1
                return
            plan.jobs.append(Job(item, folder, free_name(folder, name, taken)))

        def walk(item: Item, parent: str) -> None:
            if stop is not None and stop():
                raise Stopped()
            if item.real_id in seen:                           # a shortcut back up the tree: once is enough
                return
            seen.add(item.real_id)
            folder = os.path.join(parent, net_fetch.safe_name(item.name) or f"drive-{item.real_id}")
            plan.folders.append((folder, item))
            if note:
                note(f"Reading “{item.name}”…")
            try:
                kids = self.children(item.real_id, stop)
            except NeedsSignIn:
                raise
            except DriveError as e:
                plan.unread.append(f"{item.name}: {e}")
                return
            for kid in kids:
                if kid.is_folder:
                    walk(kid, folder)
                else:
                    add_file(self._through(kid, stop), folder)

        for item in items:
            if item.is_folder:
                walk(item, dest)
            else:
                add_file(self._through(item, stop), dest)
        return plan

    def _through(self, item: Item, stop=None) -> Item:
        """A shortcut to a file → the file itself (its size, dates and checksum are the target's)."""
        if item.mime != SHORTCUT or not item.target:
            return item
        try:
            real = self.info(item.target, stop)
        except DriveError:
            return item
        real.name = item.name if os.path.splitext(item.name)[1] else real.name
        return real

    # -- one file
    def download(self, job: Job, tmp_dir: str, stop: Callable[[], bool] | None = None,
                 progress: Callable[[int, int | None], None] | None = None) -> Done:
        """`job`'s file onto the drive: fetched to the Mac's temp folder, checked against Drive's size and MD5,
        put in place whole (never over something), then given Drive's dates."""
        item = job.item
        tmp = os.path.join(tmp_dir, f"{item.real_id}.bin")
        url = self._url(f"files/{urllib.parse.quote(item.real_id, safe='')}", {"alt": "media", "supportsAllDrives": "true"})
        why = ""
        for attempt in range(1, 4):
            try:
                headers = self.auth.headers()
            except DriveError as e:
                return Done(job, why=str(e))
            # any_kind: a person's Drive holds text and web pages too; what arrived is checked against Drive's
            # own size and checksum below, which is the stronger test
            got, why = net_fetch.fetch_to_file(url, headers, tmp, stop=stop, progress=progress, context=_context(),
                                               limit=3600, min_bytes=0, any_kind=True)
            if got:
                break
            if why == "stopped":
                return Done(job, why="stopped")
            if why.startswith("HTTP 4"):                       # Drive's own words for the refusal
                status, body, _h = _ask("GET", url, {**headers, "Range": "bytes=0-0"}, timeout=30)
                reason, _m = _reason(body)
                passing = status in (200, 206) or reason in ("rateLimitExceeded", "userRateLimitExceeded")
                if passing and attempt < 3:                    # "slow down", or it was only for a moment: again
                    net_fetch.wait(net_fetch.backoff(attempt + 1), stop)
                    continue
                return Done(job, why=explain(status, body) if status >= 400 or status == 0 else why)
            if attempt < 3:
                net_fetch.wait(net_fetch.backoff(attempt), stop)
        else:
            return Done(job, why=why or "the download failed")
        try:
            size = os.path.getsize(tmp)
            if item.size and size != item.size:
                raise DriveError(f"only {size:,} of {item.size:,} bytes arrived")
            if item.md5 and md5_of(tmp, stop) != item.md5:
                raise DriveError("it arrived damaged (its checksum isn't Drive's)")
            dest = os.path.join(job.folder, job.name)
            if os.path.lexists(dest):                          # appeared meanwhile: beside it, never over it
                dest = os.path.join(job.folder, free_name(job.folder, job.name, set()))
            import simpcity
            net_fetch.put(tmp, dest, simpcity._on_exfat(job.folder))
        except Stopped:
            return Done(job, why="stopped")
        except (DriveError, OSError) as e:
            return Done(job, why=str(e))
        finally:
            for leftover in (tmp, tmp + net_fetch.PART, tmp + net_fetch.NOTE):
                try:
                    os.remove(leftover)
                except OSError:
                    pass
        return Done(job, path=dest, dated=put_dates(dest, item.created, item.modified) or not item.modified)


def make_folders(plan: Plan) -> None:
    """Every folder of the plan, parents first (through the drive-safe maker)."""
    import simpcity
    for folder, _item in plan.folders:
        simpcity.make_folder(folder)


def date_folders(plan: Plan) -> None:
    """Drive's dates onto the folders — deepest first, after their contents are in (putting a file into a folder
    changes the folder's date)."""
    for folder, item in sorted(plan.folders, key=lambda fi: -fi[0].count(os.sep)):
        if os.path.isdir(folder):
            put_dates(folder, item.created, item.modified)


# ----------------------------------------------------------------------------- a public file, with nothing set up

def _disposition_name(value: str) -> str:
    m = re.search(r"filename\*\s*=\s*UTF-8''([^;\r\n]+)", value or "", re.I)
    if m:
        return urllib.parse.unquote(m.group(1))
    m = re.search(r'filename\s*=\s*"([^"]+)"', value or "", re.I) or re.search(r"filename\s*=\s*([^;\r\n]+)", value or "", re.I)
    return m.group(1).strip() if m else ""


def _confirm_url(page: str, file_id: str) -> str:
    """Drive's "can't scan this file for viruses" page → the address its Download button goes to."""
    action = (re.search(r"""<form[^>]*action=["']([^"']+)["']""", page, re.I) or [None, PUBLIC])[1].replace("&amp;", "&")
    params = {"id": file_id, "export": "download", "confirm": "t"}
    for m in re.finditer(r"<input[^>]*>", page, re.I):
        name = re.search(r"""name=["']([^"']+)["']""", m.group(0), re.I)
        value = re.search(r"""value=["']([^"']*)["']""", m.group(0), re.I)
        if name and value:
            params[name.group(1)] = value.group(1)
    return action.split("?")[0] + "?" + urllib.parse.urlencode(params)


def public_item(file_id: str) -> tuple[Item | None, str, str]:
    """A file shared "anyone with the link", looked at with nothing set up: (its Item — name, size, and the date
    Drive's download answer gives, if any — the address to fetch it from, "") or (None, "", why)."""
    url = f"{PUBLIC}?" + urllib.parse.urlencode({"id": file_id, "export": "download", "confirm": "t"})
    for _hop in range(2):
        status, body, headers = _ask("GET", url, {"Range": "bytes=0-0"}, timeout=40)
        low = {k.lower(): v for k, v in headers.items()}
        if status in (200, 206) and "text/html" not in low.get("content-type", ""):
            total = 0
            m = re.search(r"/(\d+)\s*$", low.get("content-range", ""))
            if m:
                total = int(m.group(1))
            elif status == 200 and low.get("content-length", "").isdigit():
                total = int(low["content-length"])
            modified = 0.0
            if low.get("last-modified"):
                try:
                    from email.utils import parsedate_to_datetime
                    modified = parsedate_to_datetime(low["last-modified"]).timestamp()
                except (TypeError, ValueError):
                    modified = 0.0
            name = _disposition_name(low.get("content-disposition", "")) or f"drive-{file_id}"
            return Item(file_id, name, low.get("content-type", ""), total, modified), url, ""
        if status in (200, 206):                               # a page: the confirm step, or not public
            page = body.decode("utf-8", "replace")
            if "accounts.google.com" in page or "ServiceLogin" in page:
                return None, "", "it isn't shared with “anyone with the link” — sign in to download it"
            if _hop == 0 and ("<form" in page.lower()):
                url = _confirm_url(page, file_id)
                continue
            return None, "", "Drive answered with a page instead of the file (a folder, or one of Google's documents?)"
        if status == 404:
            return None, "", "Drive has no such file, or it isn't shared with “anyone with the link”"
        return None, "", explain(status, body).rstrip(".")
    return None, "", "Drive kept answering with a page instead of the file"


def public_download(item: Item, url: str, dest_folder: str, tmp_dir: str, stop=None, progress=None) -> Done:
    """Fetches a public file found by `public_item` into `dest_folder` (size-checked; dated when Drive said)."""
    name = net_fetch.safe_name(item.name) or f"drive-{item.id}"
    job = Job(item, dest_folder, name)
    if already_here(item, os.path.join(dest_folder, name)) and item.size:
        return Done(job, path=os.path.join(dest_folder, name), why="already here")
    tmp = os.path.join(tmp_dir, f"{item.id}.bin")
    got, why = net_fetch.fetch_to_file(url, {"User-Agent": UA}, tmp, stop=stop, progress=progress, context=_context(),
                                       limit=3600)
    if not got:
        return Done(job, why=why)
    try:
        if net_fetch.looks_like_page(tmp):
            raise DriveError("Drive sent a page instead of the file")
        if item.size and os.path.getsize(tmp) != item.size:
            raise DriveError(f"only {os.path.getsize(tmp):,} of {item.size:,} bytes arrived")
        import simpcity
        job.name = free_name(dest_folder, name, set())
        dest = os.path.join(dest_folder, job.name)
        net_fetch.put(tmp, dest, simpcity._on_exfat(dest_folder))
    except (DriveError, OSError) as e:
        return Done(job, why=str(e))
    finally:
        for leftover in (tmp, tmp + net_fetch.PART, tmp + net_fetch.NOTE):
            try:
                os.remove(leftover)
            except OSError:
                pass
    return Done(job, path=dest, dated=put_dates(dest, 0.0, item.modified))
