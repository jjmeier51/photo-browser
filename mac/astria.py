"""Astria (astria.ai) for Safe Finder — the iPhone app's cloud AI client (`AIExtend.swift`) on the Mac:
**Edit with AI** (a photo + a prompt → new versions of it), **Create with AI** (a prompt → new images) and
the **Astria.ai Browser** (every past generation on the account). Opt-in and key-gated: with no API key
nothing here touches the network. Nothing is uploaded but what the person sends: the photo being edited and
any reference photos they pick.

The requests are the iPhone's, field for field (feature-notes §1), so the two apps behave the same:
- **A generation** is a multipart `POST /tunes/{tune}/prompts` (`prompt[text]`, `prompt[num_images]`,
  `prompt[aspect_ratio]` — always a concrete ratio, the nearest supported one to the photo for "Original" —
  `prompt[resolution]` 1K/2K/4K except on Flux, `prompt[input_image]` for an edit). The POST retries
  transient failures (429/5xx, a connection never made) with backoff, and after an *ambiguous* failure
  (the upload may have landed) it looks for the prompt among the tune's newest before posting again, so a
  billed prompt is never made twice.
- **Polling** is counted in polls (2 s → 4 s → 6 s, at most 320): Astria fills `images` one at a time, so
  each image is fetched the moment its address appears, the count waited for, and fewer accepted only once
  the list stopped growing for 20 polls; a second sweep re-reads the addresses (they're signed and expire)
  for any that failed. Every download is checked to be a picture before it counts.
- **Models**: Seedream 5.0 Pro / 5.0 Lite / 4.5, Nano Banana Pro / 2.1 / 2, Flux — the same gallery tune ids
  (overridable), the same reference limits (14; 10 for 5.0 Pro; none on Flux), 5.0 Pro pinned to 2K.
  **Tunes** (the account's own) combine as the iPhone does: one tune runs on its own base (or as a
  `<lora:id:1>` on Flux, with its "<token> <class>" trigger phrase); several stack as `<lora:…>` (Flux) or
  `<faceid:…>` (partner models).
- **References** become instant faceid tunes on the generating model (`<faceid:ID:1> image` at the start of
  the prompt), made once per photo per model and remembered; one that can't be made is left out with a note.
- **Saving**: an edit's results go into an "AI" folder beside the photo as "<name> AI.jpg", with the photo's
  EXIF and GPS, its capture date, upright, and the model and prompt in the EXIF (Software, UserComment);
  a creation into the folder's "AI" folder (the browser: straight into the chosen folder), named from the
  prompt. Written the drive's way (exFAT: in place, no rename) and never over a file.
- **A job cut short** (Safe Finder quit mid-generation) is noted the moment Astria accepts it, and finished
  the next time Safe Finder's AI is used (within 2 hours, at most 4 tries): its images go to its folder.

The API key lives in the Mac's Keychain (`security`, service "Safe Finder Astria"); everything else —
model overrides, last settings, prompt history with hearts, reference tunes, saved images, unfinished
jobs — in `~/Library/Application Support/Safe Finder/astria.json`.

All of it runs on worker threads; nothing touches Qt.
"""
from __future__ import annotations

import io
import json
import os
import random
import re
import subprocess
import sys
import threading
import time
import uuid
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable

BASE = "https://api.astria.ai"
UA = "PhotoBrowser/1.0 (macOS; Safe Finder Astria client)"
SUPPORT = Path.home() / "Library" / "Application Support" / "Safe Finder"
THUMB_CACHE = Path.home() / "Library" / "Caches" / "PhotoBrowser" / "astria"
KEYCHAIN_SERVICE = "Safe Finder Astria"
LOGS = Path.home() / "Library" / "Logs" / "Safe Finder"
DEFAULT_FLUX_TUNE = 1504944
MAX_TUNES = 10
REFERENCE_TITLE = "Photo Browser reference · "
REFERENCE_CLASS = "image"
MAX_JOB_AGE = 2 * 3600
MAX_RECOVERY_ATTEMPTS = 4

# name, gallery tune id, max reference images, pinned resolution
MODELS: dict[str, tuple[int, int, str | None]] = {
    "Seedream 5.0 Pro": (5236038, 10, "2K"),
    "Seedream 5.0 Lite": (4160332, 14, None),
    "Seedream 4.5": (3691308, 14, None),
    # Nano Banana Pro: the id is read off Astria's gallery page by position (the same reading gives the other
    # five ids here correctly); Settings can override it, as for every model.
    "Nano Banana Pro": (3618064, 14, None),
    "Nano Banana 2.1": (4180298, 14, None),
    "Nano Banana 2": (5850983, 14, None),
    "Flux": (DEFAULT_FLUX_TUNE, 0, None),
}
PARTNER_MODELS = [m for m in MODELS if m != "Flux"]
RESOLUTIONS = ("1K", "2K", "4K")
ASPECTS = {"Original": None, "1:1": "1:1", "4:5": "4:5", "9:16": "9:16"}
COUNTS = (1, 2, 3, 4, 8)
REUSABLE_PROMPTS = [
    "A full-body portrait of a 5'5\" woman with an elegant 8-heads-tall artistic structure and long legs. She has "
    "high-waisted proportions, with her legs making up the majority of her height. Low-angle shot looking up. Her "
    "body has a completely smooth, seamless silhouette with soft skin texture and no visible muscle or bone "
    "definition. Soft, flat diffuse lighting eliminates all harsh shadows on her body.",
    "long hair with a soft center part, brushed back off the face and tucked fully behind both ears, natural volume "
    "at the crown, gathered into a three-strand braid draped over the right shoulder, forehead and temples clear, "
    "matte natural texture.",
]
PROMPTING_REMINDER = ("Order: subject → wardrobe → scene → framing (crop and camera position) → camera details "
                      "(natural sensor noise, slight handheld imperfections, subtle HDR). Add imperfection keywords; "
                      "ban beauty filters for realistic, non-plasticky skin.")


class AIError(Exception):
    """kind: "not_configured" | "bad_image" | "network" | "bad_result" | "timed_out" | "failed" | "server".
    "network" and "timed_out" mean Astria may still deliver (the job is kept for later); the rest are final."""

    def __init__(self, kind: str, message: str = "") -> None:
        super().__init__(message or kind)
        self.kind = kind
        self.message = message

    @property
    def recoverable(self) -> bool:
        return self.kind in ("network", "timed_out")

    def describe(self) -> str:
        return {"not_configured": "Astria isn't set up yet — add your API key.",
                "bad_image": "The photo couldn't be read.",
                "network": "Couldn't reach Astria. If a generation was started it may still finish — Safe Finder "
                           "will pick it up next time, and it's in the Astria.ai Browser.",
                "bad_result": "Astria answered with something unexpected.",
                "timed_out": "Astria is still working on it. The images will be saved to the folder when they're "
                             "ready (next time Safe Finder's AI is used), and they're in the Astria.ai Browser.",
                }.get(self.kind, self.message or "Astria refused the request.")


# ----------------------------------------------------------------------------- settings + key

class Store:
    """astria.json — read once, saved on every change (small)."""

    def __init__(self, path: Path | None = None) -> None:
        self.path = path or SUPPORT / "astria.json"
        self.lock = threading.RLock()
        try:
            with open(self.path, encoding="utf-8") as f:
                self.data: dict = json.load(f)
        except (OSError, ValueError):
            self.data = {}

    def get(self, key: str, default=None):
        with self.lock:
            v = self.data.get(key, default)
            return json.loads(json.dumps(v)) if isinstance(v, (dict, list)) else v

    def set(self, key: str, value) -> None:
        with self.lock:
            self.data[key] = value
            self._save()

    def update(self, key: str, fn: Callable) -> None:
        """Read-modify-write one key under the lock."""
        with self.lock:
            self.data[key] = fn(self.data.get(key))
            self._save()

    def _save(self) -> None:
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            tmp = self.path.with_suffix(".saving")
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(self.data, f, indent=1)
            os.replace(tmp, self.path)
        except OSError:
            pass


_STORE: Store | None = None


def store() -> Store:
    global _STORE
    if _STORE is None:
        _STORE = Store()
    return _STORE


def get_key() -> str:
    env = os.environ.get("ASTRIA_API_KEY", "").strip()
    if env:
        return env
    if sys.platform == "darwin":
        try:
            r = subprocess.run(["security", "find-generic-password", "-s", KEYCHAIN_SERVICE, "-a", "api-key", "-w"],
                               capture_output=True, text=True, timeout=10)
            if r.returncode == 0:
                return r.stdout.strip()
        except (OSError, subprocess.SubprocessError):
            pass
    return str(store().get("api_key_fallback", "") or "")


def set_key(key: str) -> str:
    """Stores the key (the Keychain on a Mac). Returns where it went."""
    key = key.strip()
    if sys.platform == "darwin":
        try:
            if not key:
                subprocess.run(["security", "delete-generic-password", "-s", KEYCHAIN_SERVICE, "-a", "api-key"],
                               capture_output=True, timeout=10)
                return "keychain"
            r = subprocess.run(["security", "add-generic-password", "-U", "-s", KEYCHAIN_SERVICE, "-a", "api-key",
                                "-w", key], capture_output=True, timeout=10)
            if r.returncode == 0:
                return "keychain"
        except (OSError, subprocess.SubprocessError):
            pass
    store().set("api_key_fallback", key)                # not a Mac (or no Keychain): a private file
    try:
        os.chmod(store().path, 0o600)
    except OSError:
        pass
    return "file"


def tune_id(model: str) -> int:
    if model == "Flux":
        return int(store().get("flux_tune", 0) or 0) or DEFAULT_FLUX_TUNE
    over = int((store().get("tunes", {}) or {}).get(model, 0) or 0)
    if model == "Nano Banana 2" and over == MODELS["Nano Banana 2.1"][0]:
        over = 0                                          # Astria moved 2.0 to its own id (Oct 2026)
    return over or MODELS[model][0]


def set_tune_id(model: str, tid: int) -> None:
    if model == "Flux":
        store().set("flux_tune", tid if tid > 0 else DEFAULT_FLUX_TUNE)
    else:
        store().update("tunes", lambda d: {**(d or {}), model: tid if tid > 0 else MODELS[model][0]})


def default_model() -> str:
    m = store().get("default_model", "Seedream 5.0 Pro")
    return m if m in MODELS else "Seedream 5.0 Pro"


def compose_prompt(prompt: str, negative: str | None) -> str:
    n = (negative or "").strip()
    return prompt.strip() + "\n\nNegative Prompt: " + n if n else prompt


def aspect_ratio(w: int, h: int) -> str:
    supported = [("1:1", 1.0), ("4:5", 0.8), ("5:4", 1.25), ("3:4", 0.75), ("4:3", 1 / 0.75), ("2:3", 2 / 3),
                 ("3:2", 1.5), ("9:16", 9 / 16), ("16:9", 16 / 9)]
    target = max(w, 1) / max(h, 1)
    return min(supported, key=lambda s: abs(s[1] - target))[0]


# ----------------------------------------------------------------------------- tunes + generations

@dataclass(frozen=True)
class Tune:
    id: int
    title: str = ""
    name: str = ""
    branch: str = ""
    model_type: str = ""
    token: str = ""
    ready: bool = False
    base_tune_id: int | None = None

    @property
    def label(self) -> str:
        t = self.title.strip() or self.name.strip()
        return t or f"Tune {self.id}"

    @property
    def is_flux_lora(self) -> bool:
        return self.branch == "flux1"

    @property
    def trigger(self) -> str | None:
        tok = self.token.strip()
        if not tok:
            return None
        cls = self.name.strip()
        return f"{tok} {cls}" if cls else tok


@dataclass(frozen=True)
class Generation:
    tune_id: int
    prefix: str
    token: str | None
    label: str
    supports_resolution: bool


def compatible(tunes: list[Tune], model: str) -> list[Tune]:
    if model == "Flux":
        return [t for t in tunes if t.is_flux_lora]
    partner = tune_id(model)
    return [t for t in tunes if not t.is_flux_lora and (t.base_tune_id is None or t.base_tune_id == partner)]


def resolve_generation(model: str, tunes: list[Tune]) -> Generation:
    picked = list(tunes)[:MAX_TUNES]
    if not picked:
        return Generation(tune_id(model), "", None, model, model != "Flux")
    if len(picked) == 1:
        t = picked[0]
        if model == "Flux":
            return Generation(tune_id(model), f"<lora:{t.id}:1> ", t.trigger, f"{model} + {t.label}", False)
        return Generation(t.id, "", t.trigger, t.label, not t.is_flux_lora)
    if model == "Flux":
        tags = "".join(f"<lora:{t.id}:1>" for t in picked)
        triggers = ", ".join(t.trigger for t in picked if t.trigger)
        return Generation(tune_id(model), f"{tags} {triggers}, " if triggers else f"{tags} ", None,
                          f"{model} + {len(picked)} tunes", False)
    tags = "".join(f"<faceid:{t.id}:1>" for t in picked)
    return Generation(tune_id(model), f"{tags} ", None, f"{model} + {len(picked)} tunes", True)


@dataclass
class Prompt:
    id: int
    text: str = ""
    tune_id: int | None = None
    created: float | None = None
    images: list[str] = field(default_factory=list)
    num_images: int | None = None


def parse_iso(s) -> float | None:
    if not isinstance(s, str) or not s:
        return None
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def _int(v) -> int | None:
    try:
        return int(v)
    except (TypeError, ValueError):
        return None


# Astria's API documents no failure field for a prompt (docs.astria.ai, prompt object: id, text, images…).
# `error` is the one it has been seen to fill — the iPhone reads only that. A prompt its moderation stopped shows
# "moderated" in Astria's own pages; where that sits in the JSON isn't documented, so any value that says so
# (outside the prompt's own words) counts, as does a true flag whose name does.
_PROSE_KEYS = {"text", "negative_prompt", "prompt", "url", "callback", "title", "name", "images", "input_image",
               "orig_images", "video_prompt"}
_FLAG_WORDS = ("moderat", "nsfw", "flagged", "censor", "blocked")


def prompt_failure(j: dict) -> str | None:
    """What stopped a prompt, or None while nothing has."""
    for k in ("error", "error_message", "failure_reason"):
        v = j.get(k)
        if isinstance(v, str) and v.strip():
            return v.strip()

    def look(d: dict, depth: int) -> str | None:
        for k, v in d.items():
            key = str(k).lower()
            if key in _PROSE_KEYS:
                continue
            if v is True and any(w in key for w in _FLAG_WORDS):
                return f"Astria's moderation stopped it ({k})"
            if isinstance(v, str) and any(w in v.lower() for w in _FLAG_WORDS):
                return f"Astria's moderation stopped it ({k}: {v.strip()[:120]})"
            if isinstance(v, dict) and depth < 2:
                hit = look(v, depth + 1)
                if hit:
                    return hit
        return None
    return look(j, 0)


def _images_of(p: dict) -> list[str]:
    imgs = p.get("images")
    if isinstance(imgs, list):
        return [x if isinstance(x, str) else (x or {}).get("url", "") for x in imgs if x]
    return []


def model_name(tid: int | None, tunes: list[Tune]) -> str:
    if tid is None:
        return "Astria"
    for m in MODELS:
        if tune_id(m) == tid:
            return m
    for t in tunes:
        if t.id == tid:
            return t.label
    return f"Tune {tid}"


# ----------------------------------------------------------------------------- HTTP

@dataclass
class Response:
    status: int
    body: bytes
    headers: dict


class Transport:
    """One request at a time through urllib. `send(method, url, headers, body, timeout) -> Response`, raising
    `PreSend` when the connection was never made (safe to retry) and `Ambiguous` when it broke after sending
    (the request may have landed). Tests replace it."""

    class PreSend(Exception):
        pass

    class Ambiguous(Exception):
        pass

    def send(self, method: str, url: str, headers: dict, body: bytes | None, timeout: float) -> Response:
        import socket
        import ssl
        import urllib.error
        import urllib.request
        try:
            import simpcity as sc
            ctx = sc.ssl_context()
        except Exception:  # noqa: BLE001
            ctx = None
        req = urllib.request.Request(url, data=body, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=timeout, context=ctx) as resp:
                return Response(resp.status, resp.read(), dict(resp.headers))
        except urllib.error.HTTPError as e:
            return Response(e.code, e.read() or b"", dict(e.headers or {}))
        except urllib.error.URLError as e:
            reason = e.reason
            if isinstance(reason, (socket.gaierror, ConnectionRefusedError, ssl.SSLError)) or \
                    "Name or service not known" in str(reason) or "nodename nor servname" in str(reason):
                raise Transport.PreSend(str(reason)) from e
            raise Transport.Ambiguous(str(reason)) from e
        except (TimeoutError, ConnectionError, OSError) as e:
            raise Transport.Ambiguous(str(e)) from e


def _multipart(fields: dict[str, str], files: list[tuple[str, str, str, bytes]]) -> tuple[bytes, str]:
    boundary = f"PB-{uuid.uuid4()}"
    out = io.BytesIO()
    for k, v in fields.items():
        out.write(f'--{boundary}\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n{v}\r\n'.encode())
    for name, filename, mime, data in files:
        out.write(f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"; filename="{filename}"\r\n'.encode())
        out.write(f"Content-Type: {mime}\r\n\r\n".encode())
        out.write(data)
        out.write(b"\r\n")
    out.write(f"--{boundary}--\r\n".encode())
    return out.getvalue(), boundary


def _message(body: bytes) -> str:
    try:
        j = json.loads(body)
        if isinstance(j, dict):
            for k in ("message", "error"):
                if isinstance(j.get(k), str):
                    return j[k]
            if isinstance(j.get("errors"), list) and j["errors"]:
                return str(j["errors"][0])
            return json.dumps(j)[:300]
    except ValueError:
        pass
    text = body[:4000].decode("utf-8", "replace").lower()
    if any(s in text for s in ("just a moment", "cf-browser-verification", "/cdn-cgi/", "cloudflare")) or \
            text.startswith(("<!doctype", "<html")):
        return ("Astria's service blocked the request at its Cloudflare check (a \"Just a moment…\" page came back "
                "instead of a result). Usually temporary — wait a minute and try again; if it keeps happening, check "
                "the API key.")
    return body[:300].decode("utf-8", "replace") or "Astria refused the request."


def is_picture(data: bytes | None) -> bool:
    if not data or len(data) < 64:
        return False
    try:
        from PIL import Image
        with Image.open(io.BytesIO(data)) as im:
            im.verify()
        return True
    except Exception:  # noqa: BLE001
        return False


# ----------------------------------------------------------------------------- the client

_REF_LOCK = threading.Lock()


class Client:
    def __init__(self, key: str | None = None, transport: Transport | None = None,
                 sleep: Callable[[float], None] = time.sleep) -> None:
        self.key = get_key() if key is None else key
        self.t = transport or Transport()
        self.sleep = sleep

    @property
    def configured(self) -> bool:
        return bool(self.key)

    def _headers(self, extra: dict | None = None) -> dict:
        h = {"Authorization": f"Bearer {self.key}", "Accept": "application/json", "User-Agent": UA}
        h.update(extra or {})
        return h

    def _get_json(self, path: str, timeout: float = 30):
        try:
            r = self.t.send("GET", BASE + path, self._headers(), None, timeout)
        except (Transport.PreSend, Transport.Ambiguous):
            return None
        if not 200 <= r.status < 300:
            return None
        try:
            return json.loads(r.body)
        except ValueError:
            return None

    @staticmethod
    def _transient(code: int) -> bool:
        return code in (408, 425, 429) or 500 <= code <= 599

    def _backoff(self, attempt: int, retry_after: str | None = None) -> None:
        secs = min(2.0 ** attempt, 30) * random.uniform(0.75, 1.25)
        try:
            if retry_after and float(retry_after) > 0:
                secs = min(float(retry_after), 60)
        except ValueError:
            pass
        self.sleep(secs)

    # -- creating a prompt
    def create_prompt(self, tune: int, fields: dict[str, str], files: list) -> int:
        body, boundary = _multipart(fields, files)
        text = fields.get("prompt[text]", "")
        for attempt in range(1, 5):
            started = time.time()
            try:
                r = self.t.send("POST", f"{BASE}/tunes/{tune}/prompts",
                                self._headers({"Content-Type": f"multipart/form-data; boundary={boundary}"}), body, 180)
            except Transport.PreSend:
                if attempt == 4:
                    raise AIError("network")
                self._backoff(attempt)
                continue
            except Transport.Ambiguous:
                found = self.find_recent_prompt(tune, text, started - 30)
                if isinstance(found, int):
                    return found
                if found == "unavailable" or attempt == 4:
                    raise AIError("network")
                self._backoff(attempt)
                continue
            if 200 <= r.status < 300:
                try:
                    pid = _int(json.loads(r.body).get("id"))
                except (ValueError, AttributeError):
                    pid = None
                if pid is None:
                    raise AIError("bad_result")
                return pid
            if self._transient(r.status) and attempt < 4:
                self._backoff(attempt, (r.headers or {}).get("Retry-After"))
                continue
            raise AIError("server", _message(r.body))
        raise AIError("network")

    def find_recent_prompt(self, tune: int, text: str, since: float):
        arr = self._get_json(f"/tunes/{tune}/prompts?limit=20")
        if not isinstance(arr, list):
            return "unavailable"
        want = text.strip()
        for p in arr:
            if not isinstance(p, dict):
                continue
            pid = _int(p.get("id"))
            if pid is None or str(p.get("text", "")).strip() != want:
                continue
            created = parse_iso(p.get("created_at"))
            if created is not None and created < since:
                continue
            return pid
        return "not_found"

    # -- polling + downloading
    def prompt_state(self, tune: int, pid: int) -> tuple[list[str], int | None, str | None] | None:
        j = self._get_json(f"/tunes/{tune}/prompts/{pid}", timeout=25)
        if not isinstance(j, dict):
            return None
        self.last_prompt = j
        return _images_of(j), _int(j.get("num_images")), prompt_failure(j)

    def keep_prompt(self, tune: int, pid: int) -> str:
        """The prompt as Astria last described it, saved for a look when a job brought nothing back (the API
        documents no failure field, so this is how a new kind of refusal gets seen). → the file, or ""."""
        j = getattr(self, "last_prompt", None)
        if not (isinstance(j, dict) and _int(j.get("id")) == pid):
            j = self._get_json(f"/tunes/{tune}/prompts/{pid}", timeout=25)
        if not isinstance(j, dict):
            return ""
        try:
            LOGS.mkdir(parents=True, exist_ok=True)
            path = LOGS / f"astria-prompt-{pid}-{time.strftime('%Y%m%d-%H%M%S')}.json"
            path.write_text(json.dumps(j, indent=1, ensure_ascii=False), encoding="utf-8")
            return str(path)
        except OSError:
            return ""

    def download(self, url: str, attempts: int = 3) -> bytes | None:
        for attempt in range(max(1, attempts)):
            if attempt:
                self.sleep(1.5 * 2 ** (attempt - 1))
            try:
                r = self.t.send("GET", url, {"User-Agent": UA}, None, 120)
            except (Transport.PreSend, Transport.Ambiguous):
                continue
            if self._transient(r.status):
                continue
            if not 200 <= r.status < 300:
                return None
            if is_picture(r.body):
                return r.body
        return None

    def poll_images(self, tune: int, pid: int, expected: int | None, max_ticks: int = 320,
                    heartbeat: Callable[[int, int | None], None] | None = None,
                    stop: threading.Event | None = None) -> list[bytes]:
        known: list[str] = []
        want = expected
        failed_msg = None
        results: dict[int, bytes | None] = {}
        futures = {}
        with ThreadPoolExecutor(max_workers=4) as pool:
            tick = last_growth = 0
            while tick < max_ticks and not (stop is not None and stop.is_set()):
                self.sleep(2 if tick < 15 else 4 if tick < 60 else 6)
                tick += 1
                if heartbeat:
                    heartbeat(sum(1 for f in futures.values() if f.done() and f.result()), want)
                state = self.prompt_state(tune, pid)
                if state is None:
                    continue
                urls, num, err = state
                if want is None and num:
                    want = num
                if len(urls) > len(known):
                    for i in range(len(known), len(urls)):
                        futures[i] = pool.submit(self.download, urls[i])
                    known = urls
                    last_growth = tick
                if want is not None and len(known) >= want:
                    break
                if known and tick - last_growth >= 20:
                    break
                if not known and err:
                    failed_msg = err
                    break
            if not known and failed_msg is None and self.last_prompt_failure(pid):
                failed_msg = self.last_prompt_failure(pid)
            for i, f in futures.items():
                results[i] = f.result()
            missing = [i for i in range(len(known)) if not results.get(i)]
            if missing and not (stop is not None and stop.is_set()):
                fresh = (self.prompt_state(tune, pid) or ([], None, None))[0]
                urls = fresh if len(fresh) >= len(known) else known
                for i in missing:
                    results[i] = self.download(urls[i], attempts=2)
        got = [results[i] for i in sorted(results) if results[i]]
        if not got and not (stop is not None and stop.is_set()):
            kept = self.keep_prompt(tune, pid)
            if failed_msg:
                raise AIError("failed", failed_msg + (f" (what Astria said is saved in {kept})" if kept else ""))
            raise AIError("timed_out" if not known else "network")
        return got

    def last_prompt_failure(self, pid: int) -> str | None:
        j = getattr(self, "last_prompt", None)
        return prompt_failure(j) if isinstance(j, dict) and _int(j.get("id")) == pid else None

    # -- references
    def reference_mentions(self, refs: list[tuple[bytes, str, str]], base_tune: int) -> tuple[list[str], list[str], int, str | None]:
        """refs: (jpeg, key, title). → (mentions, cache keys reused, failed, last error). One at a time across
        threads: a batch of photos sent together shares its reference photos, and the first job's reference
        tunes are the ones the others then find remembered (not made again by each)."""
        with _REF_LOCK:
            return self._reference_mentions(refs, base_tune)

    def _reference_mentions(self, refs: list[tuple[bytes, str, str]], base_tune: int) -> tuple[list[str], list[str], int, str | None]:
        mentions, reused, failed, last = [], [], 0, None
        cache = store().get("reference_tunes", {}) or {}
        for data, key, title in refs:
            ck = f"{base_tune}|{key}"
            hit = cache.get(ck)
            if hit and "|" in hit:
                tid, name = hit.split("|", 1)
                mentions.append(f"<faceid:{tid}:1> {name}")
                reused.append(ck)
                continue
            try:
                tid, name = self.create_reference_tune(data, title, base_tune)
                mentions.append(f"<faceid:{tid}:1> {name}")
                store().update("reference_tunes", lambda d, ck=ck, v=f"{tid}|{name}": {**(d or {}), ck: v})
            except AIError as e:
                failed += 1
                last = e.message or last
        return mentions, reused, failed, last

    def create_tune(self, title: str, name: str, token: str, images: list[bytes], branch: str | None = "flux1",
                    base_tune: int | None = None, model_type: str = "lora") -> int:
        """Starts training a model of the person's own from `images` (upload JPEGs) — the iPhone's `createTune`,
        field for field: `title` is its name in the list, `name` the class ("woman", "dog", "style"), `token` the
        made-up word prompts know the subject by. A Flux LoRA (`branch` "flux1", `model_type` "lora") is the kind
        that can be put on a prompt afterwards. Returns the new tune's id at once; training runs on Astria
        (`tune_ready`). Astria charges for a tune."""
        if not self.configured:
            raise AIError("not_configured")
        if not images:
            raise AIError("bad_image")
        fields = {"tune[title]": title, "tune[name]": name, "tune[model_type]": model_type}
        if branch:
            fields["tune[branch]"] = branch
        if base_tune:
            fields["tune[base_tune_id]"] = str(base_tune)
        if model_type != "faceid" and token:               # FaceID tunes reject a token
            fields["tune[token]"] = token
        body, boundary = _multipart(fields, [("tune[images][]", f"img{i}.jpg", "image/jpeg", d)
                                             for i, d in enumerate(images)])
        try:
            r = self.t.send("POST", f"{BASE}/tunes",
                            self._headers({"Content-Type": f"multipart/form-data; boundary={boundary}"}), body, 600)
        except Transport.PreSend:
            raise AIError("network")
        except Transport.Ambiguous:
            # The upload may have landed. Don't send it again (a second tune is a second charge): say so.
            raise AIError("server", "the connection dropped while the photos were going up — look on astria.ai "
                                    "before trying again, the model may already be training")
        if not 200 <= r.status < 300:
            raise AIError("server", _message(r.body))
        try:
            tid = _int(json.loads(r.body).get("id"))
        except (ValueError, AttributeError):
            tid = None
        if tid is None:
            raise AIError("bad_result")
        return tid

    def tune_ready(self, tid: int) -> bool | None:
        """Whether the tune has finished training — None when Astria can't be asked just now."""
        t = self._get_json(f"/tunes/{tid}", timeout=25)
        return bool(t.get("trained_at")) if isinstance(t, dict) else None

    def create_reference_tune(self, data: bytes, title: str, base_tune: int) -> tuple[int, str]:
        fields = {"tune[title]": REFERENCE_TITLE + title, "tune[name]": REFERENCE_CLASS,
                  "tune[model_type]": "faceid", "tune[base_tune_id]": str(base_tune)}
        body, boundary = _multipart(fields, [("tune[images][]", "reference.jpg", "image/jpeg", data)])
        try:
            r = self.t.send("POST", f"{BASE}/tunes",
                            self._headers({"Content-Type": f"multipart/form-data; boundary={boundary}"}), body, 120)
        except (Transport.PreSend, Transport.Ambiguous):
            raise AIError("network")
        if not 200 <= r.status < 300:
            raise AIError("server", _message(r.body))
        try:
            j = json.loads(r.body)
        except ValueError:
            raise AIError("bad_result")
        tid = _int(j.get("id"))
        if tid is None:
            raise AIError("bad_result")
        name = j.get("name") or REFERENCE_CLASS
        if not j.get("trained_at"):
            for _ in range(30):
                self.sleep(4)
                t = self._get_json(f"/tunes/{tid}")
                if isinstance(t, dict) and t.get("trained_at"):
                    break
            else:
                raise AIError("server", f"reference {tid} is still being prepared")
        return tid, name

    # -- the whole generation
    def generate(self, tune: int, prompt: str, image: bytes | None, count: int, width: int | None = None,
                 height: int | None = None, aspect: str | None = None, resolution: str | None = None,
                 token: str | None = None, references: list[tuple[bytes, str, str]] | None = None,
                 on_prompt: Callable[[int], None] | None = None,
                 heartbeat: Callable[[int, int | None], None] | None = None,
                 note: Callable[[str], None] | None = None, stop: threading.Event | None = None) -> list[bytes]:
        if not self.configured:
            raise AIError("not_configured")
        text = prompt.strip()
        if token:
            first = token.split(" ")[0]
            if first.lower() not in text.lower():
                text = f"{token} {text}"
        reused: list[str] = []
        if references:
            mentions, reused, failed, err = self.reference_mentions(references, tune)
            if mentions:
                text = " ".join(mentions) + " " + text
            if failed and note:
                note(f"{failed} reference image{'s' if failed != 1 else ''} couldn't be prepared on Astria and "
                     f"{'were' if failed != 1 else 'was'} left out" + (f" ({err})." if err else "."))
        expected = min(max(count, 1), 8)
        fields = {"prompt[text]": text, "prompt[num_images]": str(expected)}
        if aspect:
            fields["prompt[aspect_ratio]"] = aspect
        elif width and height:
            fields["prompt[aspect_ratio]"] = aspect_ratio(width, height)
        if resolution:
            fields["prompt[resolution]"] = resolution
        files = [("prompt[input_image]", "input.jpg", "image/jpeg", image)] if image else []
        try:
            pid = self.create_prompt(tune, fields, files)
        except AIError as e:
            if e.kind == "server" and reused:               # a remembered reference tune may be gone on Astria
                store().update("reference_tunes", lambda d: {k: v for k, v in (d or {}).items() if k not in reused})
            raise
        if on_prompt:
            on_prompt(pid)
        return self.poll_images(tune, pid, expected, heartbeat=heartbeat, stop=stop)

    # -- the account
    def list_tunes(self, limit: int = 100, max_pages: int = 4) -> list[Tune]:
        if not self.configured:
            return []
        out: list[Tune] = []
        before = None
        for _ in range(max_pages):
            arr = self._get_json(f"/tunes?limit={limit}" + (f"&before_id={before}" if before else ""))
            if not isinstance(arr, list) or not arr:
                break
            for t in arr:
                if isinstance(t, dict) and (tid := _int(t.get("id"))) is not None:
                    out.append(Tune(tid, str(t.get("title") or ""), str(t.get("name") or ""),
                                    str(t.get("branch") or ""), str(t.get("model_type") or ""),
                                    str(t.get("token") or ""), bool(t.get("trained_at")), _int(t.get("base_tune_id"))))
            if len(arr) < limit:
                break
            before = out[-1].id
        return [t for t in out if not t.title.startswith(REFERENCE_TITLE)]

    def _prompt_pages(self, path: str, max_pages: int, size: int) -> list[Prompt] | None:
        out: list[Prompt] = []
        seen: set[int] = set()
        for page in range(max_pages):
            sep = "&" if "?" in path else "?"
            arr = self._get_json(f"{path}{sep}limit={size}&offset={len(out)}", timeout=40)
            if not isinstance(arr, list):
                return None if page == 0 else out
            fresh = []
            for p in arr:
                if isinstance(p, dict) and (pid := _int(p.get("id"))) is not None and pid not in seen:
                    seen.add(pid)
                    fresh.append(Prompt(pid, str(p.get("text") or ""), _int(p.get("tune_id")),
                                        parse_iso(p.get("created_at")), _images_of(p), _int(p.get("num_images"))))
            if not fresh:
                break
            out += fresh
            if len(arr) < size:
                break
        return out

    def list_prompts(self, max_pages: int = 12, size: int = 50) -> list[Prompt]:
        """Every prompt on the account, newest first: the cross-tune listing, else assembled per tune."""
        if not self.configured:
            return []
        out = self._prompt_pages("/prompts", max_pages, size)
        if out is None:
            ids = {tune_id(m) for m in MODELS} | {t.id for t in self.list_tunes()}
            out = []
            for tid in ids:
                out += self._prompt_pages(f"/tunes/{tid}/prompts", 4, size) or []
        seen: set[int] = set()
        unique = [p for p in out if not (p.id in seen or seen.add(p.id))]
        return sorted(unique, key=lambda p: (p.created or 0, p.id), reverse=True)


# ----------------------------------------------------------------------------- photos in and out

def upload_jpeg(path: str, max_px: int = 2048) -> tuple[bytes, int, int]:
    """The photo as Astria should see it — the iPhone's `uploadJPEG`: upright, standard range (a HEIC's base
    image), **converted to sRGB from the photo's own colour profile** and tagged sRGB (the iPhone's Core Image
    encode does both; Pillow alone sends Display P3 / Adobe RGB numbers unlabelled, read as sRGB), transparency onto white, long side ≤ `max_px`, JPEG 92, no metadata."""
    from PIL import Image, ImageOps
    try:
        import batch_crop  # noqa: F401 — registers HEIC with Pillow
    except ImportError:
        pass
    try:
        with Image.open(path) as im:
            im = ImageOps.exif_transpose(im)
            im = _to_srgb(im)
            if max(im.size) > max_px:
                im.thumbnail((max_px, max_px), Image.Resampling.LANCZOS)
            out = io.BytesIO()
            im.save(out, "JPEG", quality=92, icc_profile=_srgb_icc())
            return out.getvalue(), im.width, im.height
    except Exception as e:  # noqa: BLE001
        raise AIError("bad_image", str(e))


def _srgb_icc() -> bytes | None:
    try:
        from PIL import ImageCms
        return ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes()
    except Exception:  # noqa: BLE001 — no LittleCMS: untagged, which reads as sRGB anyway
        return None


def _to_srgb(im):
    """8-bit RGB in sRGB. The photo's embedded profile drives the conversion (perceptual); without one it's
    taken as sRGB already. Alpha is laid on white; 16-bit and float modes are brought to 8 bits first."""
    from PIL import Image
    icc = im.info.get("icc_profile")
    if im.mode in ("I;16", "I;16B", "I;16L", "I"):
        im = im.point(lambda v: v * (1 / 256)).convert("L")
    elif im.mode == "F":
        im = im.convert("L")
    if im.mode in ("RGBA", "LA", "PA") or (im.mode == "P" and "transparency" in im.info):
        rgba = im.convert("RGBA")
        flat = Image.new("RGB", rgba.size, (255, 255, 255))
        flat.paste(rgba, mask=rgba.getchannel("A"))
        im = flat
    if icc:
        try:
            from PIL import ImageCms
            src = ImageCms.ImageCmsProfile(io.BytesIO(icc))
            if im.mode not in ("RGB", "CMYK", "L"):
                im = im.convert("RGB")
            out = ImageCms.profileToProfile(im, src, ImageCms.createProfile("sRGB"),
                                            renderingIntent=ImageCms.Intent.PERCEPTUAL, outputMode="RGB")
            if out is not None:
                return out
        except Exception:  # noqa: BLE001 — an unreadable profile: the numbers as they are
            pass
    return im.convert("RGB") if im.mode != "RGB" else im


def reference(path: str) -> tuple[bytes, str, str]:
    """(jpeg, identity key "path|mtime|size", title) for a reference photo."""
    st = os.stat(path)
    data, _w, _h = upload_jpeg(path, 2048)
    return data, f"{path}|{int(st.st_mtime)}|{st.st_size}", os.path.basename(path)


def _exif_date(exif) -> datetime | None:
    for v in (exif.get_ifd(0x8769).get(36867), exif.get_ifd(0x8769).get(36868), exif.get(306)):
        if isinstance(v, str):
            try:
                return datetime.strptime(v.strip()[:19], "%Y:%m:%d %H:%M:%S")
            except ValueError:
                continue
    return None


def _user_comment(text: str) -> bytes:
    try:
        return b"ASCII\0\0\0" + text.encode("ascii")
    except UnicodeEncodeError:
        return b"UNICODE\0" + text.encode("utf-16-be")


def ai_folder(folder: Path) -> Path:
    """The "AI" folder of `folder` to save into — beside itself when it already is one."""
    import frame_export
    if folder.name == "AI" or re.fullmatch(r"AI \d+", folder.name):
        return folder
    return frame_export.usable_folder(folder, "AI")


def _encode(result: bytes, base_exif=None, when: datetime | None = None, model: str = "", prompt: str = "") -> bytes:
    from PIL import Image, ImageOps
    with Image.open(io.BytesIO(result)) as im:
        im = ImageOps.exif_transpose(im)                 # Astria may hand back a rotated JPEG with a flag
        if im.mode != "RGB":
            im = im.convert("RGB")
        exif = Image.Exif()
        if base_exif is not None:
            for k, v in base_exif.items():
                if k not in (0x8769, 0x8825, 0x0112, 0x0100, 0x0101):
                    exif[k] = v
            gps = base_exif.get_ifd(0x8825)
            if gps:
                exif[0x8825] = dict(gps)
        exif_ifd = dict(base_exif.get_ifd(0x8769)) if base_exif is not None else {}
        for k in (0xA002, 0xA003, 0x927C):               # pixel sizes and maker notes don't carry over
            exif_ifd.pop(k, None)
        if when is not None:
            stamp = when.strftime("%Y:%m:%d %H:%M:%S")
            exif_ifd[36867] = stamp
            exif_ifd[36868] = stamp
            exif[306] = stamp
        p = prompt.strip()
        exif_ifd[37510] = _user_comment(f"AI-generated · Prompt: {p}" if p else "AI-generated")
        exif[0x8769] = exif_ifd
        # UTF-8 bytes, as the iPhone's ImageIO writes them (a str would be squeezed to ASCII: "AI ? model")
        exif[305] = (f"PhotoBrowser AI — {model}" if model else "PhotoBrowser AI").encode("utf-8")
        exif[0x0112] = 1
        out = io.BytesIO()
        im.save(out, "JPEG", quality=95, exif=exif.tobytes(), icc_profile=im.info.get("icc_profile"))
        return out.getvalue()


def _place(data: bytes, folder: Path, name: str, when: datetime | None) -> str:
    """Into `folder` as `name` (or "name 2"…), never over a file; the drive's way of writing."""
    import simpcity as sc
    stem, ext = os.path.splitext(name)
    dest = folder / name
    n = 2
    while os.path.lexists(dest):
        dest = folder / f"{stem} {n}{ext}"
        n += 1
    sc.write_file(dest, data)
    if when is not None:
        ts = when.timestamp()
        os.utime(dest, (ts, ts))
    return str(dest)


def save_edit(result: bytes, original: str, model: str = "", prompt: str = "") -> str:
    """An edit's result into the "AI" folder beside `original` (module notes). Returns the new file."""
    from PIL import Image
    base_exif, when = None, None
    try:
        with Image.open(original) as src:
            base_exif = src.getexif()
            when = _exif_date(base_exif)
    except Exception:  # noqa: BLE001 — a source Pillow can't read: no EXIF to carry
        pass
    if when is None:
        try:
            when = datetime.fromtimestamp(os.stat(original).st_mtime)
        except OSError:
            when = None
    data = _encode(result, base_exif, when, model, prompt)
    folder = ai_folder(Path(original).parent)
    return _place(data, folder, f"{Path(original).stem[:200]} AI.jpg", when)


def _safe_name(s: str) -> str:
    cleaned = re.sub(r'[/\\:?%*|"<>\x00-\x1f]', " ", s).strip()
    return cleaned or "AI Creation"


def save_created(result: bytes, folder: str, model: str = "", prompt: str = "", when: float | None = None,
                 into_ai: bool = True) -> str:
    """A creation (or a browser save) into `folder`'s "AI" folder — or `folder` itself."""
    stamp = datetime.fromtimestamp(when) if when else datetime.now()
    data = _encode(result, None, stamp, model, prompt)
    target = ai_folder(Path(folder)) if into_ai else Path(folder)
    import simpcity as sc
    sc.make_folder(target)
    base = prompt.strip()[:40] or "AI Creation"
    return _place(data, target, f"{_safe_name(base)}.jpg", stamp)


# ----------------------------------------------------------------------------- history, jobs cut short

def record_prompt(prompt: str) -> None:
    p = prompt.strip()
    if not p:
        return
    favs = set(store().get("favorites", []) or [])

    def upd(hist):
        hist = [h for h in (hist or []) if h.lower() != p.lower()]
        hist.insert(0, p)
        while len(hist) > 50:
            for i in range(len(hist) - 1, -1, -1):
                if hist[i] not in favs:
                    del hist[i]
                    break
            else:
                break
        return hist
    store().update("history", upd)


def toggle_favorite(prompt: str) -> bool:
    on = [False]

    def upd(favs):
        favs = list(favs or [])
        if prompt in favs:
            favs.remove(prompt)
        else:
            favs.append(prompt)
            on[0] = True
        return favs
    store().update("favorites", upd)
    return on[0]


def note_pending(job: dict) -> None:
    store().update("pending", lambda lst: [j for j in (lst or []) if j.get("job") != job["job"]] + [job])


def drop_pending(job_id: str) -> None:
    store().update("pending", lambda lst: [j for j in (lst or []) if j.get("job") != job_id])


def resume_pending(client: Client, busy: set[str] | None = None, max_ticks: int = 30) -> list[tuple[dict, list[str]]]:
    """Finishes jobs a quit cut short (module notes) — quietly: only what got saved is reported."""
    busy = busy or set()
    now = time.time()
    done = []
    for job in list(store().get("pending", []) or []):
        jid = job.get("job", "")
        if jid in busy:
            continue
        if now - float(job.get("started", 0)) > MAX_JOB_AGE or int(job.get("attempts", 0)) >= MAX_RECOVERY_ATTEMPTS:
            drop_pending(jid)
            continue
        target = job.get("source") or job.get("folder") or ""
        if not target or not os.path.exists(target):
            continue                                        # the drive's away: try another time
        job["attempts"] = int(job.get("attempts", 0)) + 1
        note_pending(job)
        try:
            images = client.poll_images(int(job["tune"]), int(job["prompt_id"]), job.get("count"), max_ticks=max_ticks)
        except AIError as e:
            if not e.recoverable:
                drop_pending(jid)
            continue
        saved = []
        for data in images:
            try:
                if job.get("source"):
                    saved.append(save_edit(data, job["source"], job.get("model", ""), job.get("prompt", "")))
                else:
                    saved.append(save_created(data, job["folder"], job.get("model", ""), job.get("prompt", "")))
            except OSError:
                pass
        drop_pending(jid)
        done.append((job, saved))
    return done
