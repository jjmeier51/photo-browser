"""Astria (astria.ai) for Photo Browser for Mac — the iPhone app's cloud AI client (`AIExtend.swift`) on the Mac:
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
- **Models**: Seedream 5.5 (the default since Nov 20) / 5.0 Pro / 5.0 Lite / 4.5, Nano Banana Pro / 2.1 / 2,
  Flux — the same gallery tune ids (overridable), the same reference limits (14; 10 for 5.5 and 5.0 Pro; none on
  Flux), 5.5 and 5.0 Pro pinned to 2K (`resolutions`, `fit_resolution`).
- **Upscale results 2×** (the form's option, Mac only): each result enlarged with Lanczos as it comes back
  (`upscale_2x`) — so what's shown, kept and saved is the larger picture; saved files get the "upscaled" tag.
- **Two ways to Astria** (`AutoTransport`, Nov 20): Python's networking, and — when the front door answers that
  with its browser check — the same request through the Mac's own curl; `check_connection` asks both and says.
  **Tunes** (the account's own) combine as the iPhone does: one tune runs on its own base (or as a
  `<lora:id:1>` on Flux, with its "<token> <class>" trigger phrase); several stack as `<lora:…>` (Flux) or
  `<faceid:…>` (partner models).
- **References** become instant faceid tunes on the generating model (`<faceid:ID:1> image` at the start of
  the prompt), made once per photo per model and remembered; one that can't be made is left out with a note.
- **Saving**: an edit's results go into an "AI" folder beside the photo as "<name> AI.jpg", with the photo's
  EXIF and GPS, its capture date, upright, and the model and prompt in the EXIF (Software, UserComment);
  a creation into the folder's "AI" folder (the browser: straight into the chosen folder), named from the
  prompt. Written the drive's way (exFAT: in place, no rename) and never over a file.
- **A job cut short** (Photo Browser for Mac quit mid-generation) is noted the moment Astria accepts it, and finished
  the next time Photo Browser for Mac's AI is used (within 2 hours, at most 4 tries): its images go to its folder.

The API key lives in the Mac's Keychain (`security`, service "Photo Browser for Mac Astria"); everything else —
model overrides, last settings, prompt history with hearts, reference tunes, saved images, unfinished
jobs — in `~/Library/Application Support/Photo Browser for Mac/astria.json`.

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
import shutil
import time
import uuid
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable
import app_identity

BASE = "https://api.astria.ai"
UA = "PhotoBrowser/1.0 (macOS; Photo Browser for Mac Astria client)"
SUPPORT = app_identity.support()
THUMB_CACHE = Path.home() / "Library" / "Caches" / "PhotoBrowser" / "astria"
KEYCHAIN_SERVICE, OLD_KEYCHAIN_SERVICE = app_identity.keychain_services("Astria")
LOGS = app_identity.logs()
DEFAULT_FLUX_TUNE = 1504944
MAX_TUNES = 10
REFERENCE_TITLE = "Photo Browser reference · "
REFERENCE_CLASS = "image"
MAX_JOB_AGE = 2 * 3600
MAX_RECOVERY_ATTEMPTS = 4

# name, gallery tune id, max reference images, pinned resolution
MODELS: dict[str, tuple[int, int, str | None]] = {
    # Seedream 5.5 (Nov 20): id 6000082 from Astria's public gallery listing (astria.ai/gallery/tunes.json?title=
    # seedream — "Seedream 5.5", partner-1, added Oct 30 2026). Astria's docs don't describe it yet: the reference
    # limit is taken as 5.0 Pro's (10). It makes 2K only (the person's word, correcting "up to 3K") — pinned, as
    # 5.0 Pro is; for larger, the form's "Upscale results 2×" enlarges what comes back on the Mac.
    "Seedream 5.5": (6000082, 10, "2K"),
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
DEFAULT_MODEL = "Seedream 5.5"
RESOLUTIONS = ("1K", "2K", "4K")                          # every size tier there is, smallest first
USUAL_RESOLUTIONS = RESOLUTIONS
MODEL_RESOLUTIONS: dict[str, tuple[str, ...]] = {}        # a model whose tiers aren't the usual three (none now)


def resolutions(model: str) -> tuple[str, ...]:
    """The size tiers `model` offers: its pinned one alone, none for Flux, else its own list or the usual three."""
    if model == "Flux" or model not in MODELS:
        return ()
    pinned = MODELS[model][2]
    return (pinned,) if pinned else MODEL_RESOLUTIONS.get(model, USUAL_RESOLUTIONS)


def fit_resolution(model: str, wanted: str | None) -> str | None:
    """The tier to send for `model` when the person asked for `wanted`: that one when the model has it, else the
    largest it has that isn't larger (4K on a model pinned at 2K → 2K), else its smallest."""
    have = resolutions(model)
    if not have:
        return None
    if wanted in have:
        return wanted
    rank = RESOLUTIONS.index(wanted) if wanted in RESOLUTIONS else RESOLUTIONS.index("2K")
    below = [t for t in have if RESOLUTIONS.index(t) <= rank]
    return below[-1] if below else have[0]

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
        if self.kind == "network" and self.message:          # what exactly went wrong, then what happens next
            return (self.message + " They're kept on Astria: Photo Browser for Mac will fetch them next time its AI is "
                    "used, and they're in the Astria.ai Browser.")
        return {"not_configured": "Astria isn't set up yet — add your API key.",
                "bad_image": "The photo couldn't be read.",
                "network": "Couldn't reach Astria. If a generation was started it may still finish — Photo Browser for Mac "
                           "will pick it up next time, and it's in the Astria.ai Browser.",
                "bad_result": "Astria answered with something unexpected.",
                "timed_out": "Astria is still working on it. The images will be saved to the folder when they're "
                             "ready (next time Photo Browser for Mac's AI is used), and they're in the Astria.ai Browser.",
                }.get(self.kind, self.message or "Astria refused the request.")


# ----------------------------------------------------------------------------- settings + key

class Store:
    """astria.json — read once, saved on every change (small)."""

    def __init__(self, path: Path | None = None) -> None:
        self.path = path or SUPPORT / "astria.json"
        self.lock = threading.RLock()
        import net_fetch
        # History, the saved map and jobs still out (paid for) live here: a torn file is read from its .bak and
        # set aside as .damaged — never taken for "nothing yet" and written over.
        self.data: dict
        self.data, how = net_fetch.load_json(self.path)
        if how == "corrupt":
            try:
                self.path.with_name(self.path.name + ".damaged").write_bytes(self.path.read_bytes())
            except OSError:
                pass

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
            if time.monotonic() - getattr(self, "_backed_at", -1e9) > 300 and self.path.is_file():
                self._backed_at = time.monotonic()      # the last good one, kept beside it (every few minutes at most)
                try:
                    shutil.copyfile(self.path, self.path.with_name(self.path.name + ".bak"))
                except OSError:
                    pass
            os.replace(tmp, self.path)
        except OSError:
            pass


_STORE: Store | None = None


def store() -> Store:
    global _STORE
    if _STORE is None:
        _STORE = Store()
    return _STORE


def _keychain(*args: str) -> subprocess.CompletedProcess | None:
    try:
        return subprocess.run(["security", *args], capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return None


def get_key() -> str:
    env = os.environ.get("ASTRIA_API_KEY", "").strip()
    if env:
        return env
    if sys.platform == "darwin":
        r = _keychain("find-generic-password", "-s", KEYCHAIN_SERVICE, "-a", "api-key", "-w")
        if r is not None and r.returncode == 0:
            return r.stdout.strip()
        # Saved before the app's rename: read from where it is, and kept under the new name from now on.
        r = _keychain("find-generic-password", "-s", OLD_KEYCHAIN_SERVICE, "-a", "api-key", "-w")
        if r is not None and r.returncode == 0 and r.stdout.strip():
            key = r.stdout.strip()
            moved = _keychain("add-generic-password", "-U", "-s", KEYCHAIN_SERVICE, "-a", "api-key", "-w", key)
            if moved is not None and moved.returncode == 0:
                _keychain("delete-generic-password", "-s", OLD_KEYCHAIN_SERVICE, "-a", "api-key")
            return key
    return str(store().get("api_key_fallback", "") or "")


def set_key(key: str) -> str:
    """Stores the key (the Keychain on a Mac). Returns where it went."""
    key = key.strip()
    if sys.platform == "darwin":
        _keychain("delete-generic-password", "-s", OLD_KEYCHAIN_SERVICE, "-a", "api-key")   # never two of them
        if not key:
            _keychain("delete-generic-password", "-s", KEYCHAIN_SERVICE, "-a", "api-key")
            return "keychain"
        r = _keychain("add-generic-password", "-U", "-s", KEYCHAIN_SERVICE, "-a", "api-key", "-w", key)
        if r is not None and r.returncode == 0:
            return "keychain"
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
    """The model new windows start on. Once (Nov 20): Seedream 5.5 becomes it — and the model the Edit / Create
    windows remember from last time, which otherwise keeps winning — as the iPhone's `defaultModel` does. After
    that the choice is the person's again (Astria Settings, and whatever a window was last left on)."""
    st = store()
    if not st.get("default_is_55"):
        st.set("default_is_55", True)
        st.set("default_model", DEFAULT_MODEL)
        for run in ("run_edit", "run_create"):
            kept = st.get(run)
            if isinstance(kept, dict) and kept.get("model") in MODELS and kept.get("model") != "Flux":
                st.set(run, {**kept, "model": DEFAULT_MODEL})
    m = st.get("default_model", DEFAULT_MODEL)
    return m if m in MODELS else DEFAULT_MODEL


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
    route: str = ""                  # which way it went: "python", "curl" — "python+curl" when both were checked


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


class CurlTransport(Transport):
    """The same request through the Mac's own `curl` (/usr/bin/curl — part of macOS; Astria's documentation's own
    examples are curl commands): the same address, the same headers, the same User-Agent naming this app — only
    the networking underneath is the system's instead of Python's. The key never appears on the command line
    (`ps` would show it): the whole request is a config handed to curl on its standard input, the body a file in
    a private temp folder."""

    NEVER_SENT = {5, 6, 7, 35, 60, 77}          # no proxy/host found, no connection, TLS never made, certificates

    def __init__(self, curl: str | None = None) -> None:
        self.curl = curl or self.find()

    @staticmethod
    def find() -> str | None:
        for path in ("/usr/bin/curl", shutil.which("curl")):
            if path and os.access(path, os.X_OK):
                return path
        return None

    @staticmethod
    def _quoted(value: str) -> str:
        return '"' + value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ").replace("\r", " ") + '"'

    def send(self, method: str, url: str, headers: dict, body: bytes | None, timeout: float) -> Response:
        import tempfile
        import children
        if not self.curl:
            raise Transport.PreSend("curl isn't on this Mac")
        tmp = tempfile.mkdtemp(prefix="pb-astria-")
        try:
            out, heads = os.path.join(tmp, "body"), os.path.join(tmp, "headers")
            q = self._quoted
            cfg = [f"url = {q(url)}", f"request = {q(method)}", f"output = {q(out)}", f"dump-header = {q(heads)}",
                   f"max-time = {int(max(5, timeout))}", "connect-timeout = 20", "silent", "show-error",
                   'write-out = "%{http_code}"', 'header = "Expect:"']
            for k, v in headers.items():
                cfg.append(f"header = {q(f'{k}: {v}')}")
            if body is not None:
                sent = os.path.join(tmp, "sent")
                with open(sent, "wb") as f:
                    f.write(body)
                cfg.append(f"data-binary = {q('@' + sent)}")
            try:
                # -q first: the person's own ~/.curlrc must not change what's sent
                proc = subprocess.Popen([self.curl, "-q", "--config", "-"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE, **children.OWN_GROUP)
            except OSError as e:
                raise Transport.PreSend(str(e)) from e
            with children.tracked(proc):
                try:
                    so, se = proc.communicate("\n".join(cfg).encode("utf-8"), timeout=timeout + 30)
                except subprocess.TimeoutExpired as e:
                    children.stop(proc)
                    raise Transport.Ambiguous("curl took too long") from e
            if proc.returncode != 0:
                why = (se or b"").decode("utf-8", "replace").strip()[:300] or f"curl stopped with {proc.returncode}"
                raise (Transport.PreSend if proc.returncode in self.NEVER_SENT else Transport.Ambiguous)(why)
            try:
                status = int((so or b"0").decode("ascii", "replace").strip()[-3:])
            except ValueError:
                status = 0
            data = b""
            if os.path.exists(out):
                with open(out, "rb") as f:
                    data = f.read()
            got: dict[str, str] = {}
            if os.path.exists(heads):
                with open(heads, "rb") as f:
                    blocks = [b for b in re.split(r"\r?\n\r?\n", f.read().decode("latin-1")) if b.strip()]
                for line in (blocks[-1].splitlines()[1:] if blocks else []):     # the last answer's (not a proxy's)
                    name, sep, value = line.partition(":")
                    if sep:
                        got[name.strip()] = value.strip()
            if not status:
                raise Transport.Ambiguous("curl gave no answer")
            return Response(status, data, got, "curl")
        finally:
            shutil.rmtree(tmp, ignore_errors=True)


ROUTE_DAYS = 7                       # how long "curl gets through where Python's networking doesn't" is believed


class AutoTransport(Transport):
    """What the app's clients use: Python's networking — and, **when Astria's front door answers that with its
    browser check**, the same request once more through the Mac's own curl (`CurlTransport`). A request the front
    door turned away never reached Astria, so sending it again makes nothing twice. Whichever got through is used
    from then on (remembered `ROUTE_DAYS` days in astria.json → `route`, then Python's is tried again).

    Why (Nov 20): from two networks the app's requests — same headers, same uploads, a made-up key — reached Astria
    every time, while on the person's Mac they were met with "Just a moment…" for days. What differs is the
    connection underneath: the Mac's Python and its TLS library, which Cloudflare can tell from other clients'.
    The request itself stays honest either way: this app's name as User-Agent, the person's own key, Astria's
    documented API. When both ways are checked (`route` "python+curl"), it's the network that's being checked,
    and the message says so."""

    def __init__(self, first: Transport | None = None, second: Transport | None = None, remember: bool = True,
                 browser: Transport | None = None) -> None:
        self.python = first or Transport()
        self.curl = second if second is not None else CurlTransport()
        # The third way (Nov 20): a browser window on this Mac in which **the person** answers Cloudflare's check,
        # the requests then made by that browser (astria_door.py — set with `set_browser_route` once Qt is up).
        # For when both direct ways are checked: the address itself is, and only a person can answer that.
        self.browser = browser
        self.remember = remember
        self.lock = threading.Lock()
        self.use = "python"
        # Other hosts (the result pictures are on mp.astria.ai — the same front door, its own check): which of
        # them go by the browser window, for this run. Found out per host, the first time a picture is checked.
        self.hosts: dict[str, str] = {}
        if remember:
            kept = store().get("route", {}) or {}
            fresh = time.time() - float(kept.get("at", 0)) < ROUTE_DAYS * 86400
            if kept.get("use") == "curl" and fresh and getattr(self.curl, "curl", True):
                self.use = "curl"
            elif kept.get("use") == "browser" and fresh:
                self.use = "browser"                         # (used once the window's route is there)

    def _by_browser(self, method: str, url: str, headers: dict, body: bytes | None, timeout: float) -> Response | None:
        """The request through the browser window → its answer, or None when that way isn't there (no window
        system) — the caller goes on without it. Astria's API by `fetch` from the window's page; a file on another
        host (a result picture) by the browser's own download, GET only."""
        if self.browser is None or (not url.startswith(BASE) and method != "GET"):
            return None
        try:
            r = self.browser.send(method, url, headers, body, timeout)
        except Transport.PreSend:
            return None
        r.route = "browser"
        return r

    def _prefer(self, use: str) -> None:
        with self.lock:
            if self.use == use:
                return
            self.use = use
        _route_note(f"switched to {use}")
        if self.remember:
            store().set("route", {"use": use, "at": time.time()})

    def send(self, method: str, url: str, headers: dict, body: bytes | None, timeout: float) -> Response:
        api = url.startswith(BASE)
        host = "" if api else _host(url)
        asked_browser = False
        if (self.use == "browser") if api else (self.hosts.get(host) == "browser"):
            asked_browser = True
            r = self._by_browser(method, url, headers, body, timeout)
            if r is not None and (200 <= r.status < 300 or explain(r).kind != "challenge"):
                return r                                     # (else: the direct ways, in case the address is clear again)
        order = [("curl", self.curl), ("python", self.python)] if self.use == "curl" else \
            [("python", self.python), ("curl", self.curl)]
        name, way = order[0]
        try:
            r = way.send(method, url, headers, body, timeout)
        except Transport.PreSend:
            if name != "curl":
                raise
            self._prefer("python")                           # curl is gone or can't connect: Python's way, as before
            r = self.python.send(method, url, headers, body, timeout)
            r.route = "python"
            return r
        r.route = r.route or name
        if 200 <= r.status < 300 or explain(r).kind != "challenge":
            return r
        other, second = order[1]                             # the browser check: once more, the other way
        try:
            r2 = second.send(method, url, headers, body, timeout)
        except Transport.PreSend:
            return r
        r2.route = other
        if 200 <= r2.status < 300 or explain(r2).kind != "challenge":
            _route_note(f"{method} {url.replace(BASE, '')}: {name} was met with the browser check, {other} got "
                        f"HTTP {r2.status}")
            self._prefer(other)
            return r2
        r.route = "python+curl"
        if not asked_browser:                                # both checked: it's the address — the person's turn
            r3 = self._by_browser(method, url, headers, body, timeout)
            if r3 is not None and (200 <= r3.status < 300 or explain(r3).kind != "challenge"):
                _route_note(f"{method} {url.replace(BASE, '') if api else host}: python and curl were met with the "
                            f"browser check; the browser window got HTTP {r3.status}")
                if api:
                    self._prefer("browser")
                else:
                    self.hosts[host] = "browser"
                return r3
            if r3 is not None:
                r.route = "python+curl+browser"
        elif self.browser is not None:
            r.route = "python+curl+browser"
        return r


def _host(url: str) -> str:
    from urllib.parse import urlsplit
    try:
        return urlsplit(url).netloc.lower()
    except ValueError:
        return ""


def _route_note(text: str) -> None:
    try:
        LOGS.mkdir(parents=True, exist_ok=True)
        with open(LOGS / "astria-requests.log", "a", encoding="utf-8") as f:
            f.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} route: {text}\n")
    except OSError:
        pass


_AUTO: AutoTransport | None = None
_BROWSER_ROUTE: Transport | None = None


def default_transport() -> Transport:
    """The app's one transport (it remembers which way gets through)."""
    global _AUTO
    if _AUTO is None:
        _AUTO = AutoTransport(browser=_BROWSER_ROUTE)
    return _AUTO


def set_browser_route(route: Transport | None) -> None:
    """The window side (astria_door.py) hands over the browser way once Qt is running; this module stays Qt-free."""
    global _BROWSER_ROUTE
    _BROWSER_ROUTE = route
    if _AUTO is not None:
        _AUTO.browser = route


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


def _advice(ref: Refusal, tried: int = 1) -> str:
    """A refusal's message with what to do about it, for the person."""
    again = f" Tried {tried} times, waiting in between." if tried > 1 else ""
    log = " Details: " + str(LOGS / "astria-requests.log").replace(str(Path.home()), "~") + "."
    if ref.kind == "challenge":
        if ref.route == "python+curl+browser":
            return (ref.message + again + " Cloudflare is checking this network's address, and the check in the "
                    "“Astria — Cloudflare's check” window wasn't completed. Open Astria Settings ▸ Check Connection "
                    "and answer the check in the window that opens — or use another network (a phone hotspot)." + log)
        if ref.route == "python+curl":
            return (ref.message + again + " It came back the same through the Mac's own networking, so it's this "
                    "network or address Cloudflare is checking, not the app or the API key: turn off a VPN if one "
                    "is on, or try another network (a phone hotspot); if it stays, send Astria the Ray number." + log)
        return (ref.message + again + " It's the network or the number of requests, not the API key — wait 10–15 "
                "minutes, and turn off a VPN if one is on." + log)
    if ref.kind == "limited":
        return ref.message + again + " Wait a few minutes, then send fewer at once." + log
    if ref.kind == "blocked":
        return ref.message + " Try another network, or turn a VPN off." + log
    if ref.kind == "gateway":
        return ref.message + again + " Try again in a few minutes." + log
    if ref.kind == "html":
        return ref.message + log
    return ref.message


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


@dataclass
class Refusal:
    """What a non-2xx answer was. `kind`:
    "challenge" — Cloudflare (Astria's front door) asked for a browser check; the request never reached Astria;
    "limited"   — too many requests (429, Cloudflare 1015); never reached Astria;
    "blocked"   — Cloudflare refused it outright (its 10xx errors); never reached Astria;
    "too_large" — the upload is bigger than the front door takes (413);
    "gateway"   — Astria's own servers didn't answer through it (502/503/504/52x, Heroku's error page) — the
                  request **may** have been taken;
    "html"      — some other web page where a result belongs;
    "api"       — Astria's own JSON answer (a validation message, a wrong key…)."""
    kind: str
    message: str
    status: int = 0
    ray: str = ""
    retry_after: float | None = None
    route: str = ""                  # Response.route: "python+curl" = checked both ways

    @property
    def wait(self) -> bool:
        """Waiting and asking again is the right answer (and safe: Astria never saw the request)."""
        return self.kind in ("challenge", "limited")


def _header(headers: dict | None, name: str) -> str:
    for k, v in (headers or {}).items():
        if str(k).lower() == name:
            return str(v)
    return ""


_CF_CODE = re.compile(r"error(?:\s+code)?:?\s*(1\d{3})\b")
_CF_BLOCKS = {"1006", "1007", "1008", "1009", "1010", "1012", "1020"}


def explain(r: Response, sent: int = 0) -> Refusal:
    """Says what a refused request's answer was (`Refusal`), in words for the person. Until Nov 19 every web page
    that came back — an upload-too-large page, a gateway timeout, Astria's hosting error page — was reported as
    "blocked at its Cloudflare check", so the one message covered five different problems with five different
    answers. Decided from the status, the front door's own headers (`cf-mitigated`, `cf-ray`) and the page."""
    ref = _explain(r, sent)
    ref.route = getattr(r, "route", "") or ""
    return ref


def _explain(r: Response, sent: int = 0) -> Refusal:
    status = int(r.status or 0)
    ray = _header(r.headers, "cf-ray")
    after = None
    try:
        after = float(_header(r.headers, "retry-after")) or None
    except ValueError:
        after = None
    where = f" [HTTP {status}" + (f", Cloudflare Ray {ray}" if ray else "") + "]"
    body = r.body or b""
    try:
        j = json.loads(body)
    except ValueError:
        j = None
    if isinstance(j, dict):
        msg = next((j[k] for k in ("message", "error") if isinstance(j.get(k), str) and j[k].strip()), None)
        if msg is None and isinstance(j.get("errors"), list) and j["errors"]:
            msg = str(j["errors"][0])
        if status == 429:
            return Refusal("limited", "Astria says this account is sending requests too fast" +
                           (f" (“{msg}”)" if msg else "") + "." + where, status, ray, after)
        if status in (401, 403) and not msg:
            msg = "Astria didn't accept the API key — check it in the AI settings."
        return Refusal("api", (msg or json.dumps(j)[:300]) + ("" if msg and status < 500 else where), status, ray, after)
    text = body[:8000].decode("utf-8", "replace").lower()
    if status == 401 and not text.lstrip().startswith(("<!doctype", "<html")):
        # Astria's answer to a key it doesn't know is plain text ("HTTP Token: Access denied.")
        return Refusal("api", "Astria didn't accept the API key — check it in Astria Settings (it's on astria.ai "
                              "under your account's API page).", status, ray, after)
    code = (_CF_CODE.search(text) or [None, ""])[1]
    if status == 429 or code == "1015":
        return Refusal("limited", "Astria's front door (Cloudflare) says this Mac is sending requests too fast." + where,
                       status, ray, after)
    if _header(r.headers, "cf-mitigated").lower() == "challenge" or \
            any(m in text for m in ("just a moment", "cf-browser-verification", "challenge-platform", "cf-chl",
                                    "attention required")):
        return Refusal("challenge", "Astria's front door (Cloudflare) sent its “Just a moment…” browser check, so the "
                                    "request never reached Astria." + where, status, ray, after)
    if code in _CF_BLOCKS:
        return Refusal("blocked", f"Astria's front door (Cloudflare) refused the request outright (its error {code}) "
                                  "— it is blocking this network or this kind of request, not the API key." + where,
                       status, ray, after)
    if status == 413:
        size = f" ({sent / 1_048_576:.0f} MB)" if sent else ""
        return Refusal("too_large", f"The upload{size} is larger than Astria's front door accepts — use fewer or "
                                    "smaller photos." + where, status, ray, after)
    if status in (502, 503, 504) or 520 <= status <= 527 or "application error" in text:
        return Refusal("gateway", "Astria's servers didn't answer (the problem is on Astria's side, not this Mac or "
                                  "the API key)." + where, status, ray, after)
    if text.lstrip().startswith(("<!doctype", "<html")) or "cloudflare" in text:
        return Refusal("html", "Astria answered with a web page instead of a result." + where, status, ray, after)
    return Refusal("api", (body[:300].decode("utf-8", "replace").strip() or "Astria refused the request.") + where,
                   status, ray, after)


def _note_refusal(method: str, url: str, r: Response, ref: Refusal, sent: int) -> None:
    """A refused request, for ~/Library/Logs/<app>/astria-requests.log — what was asked (never the key: it's a
    header), the status, the front door's headers and the start of what came back. So a problem that keeps
    happening can be read afterwards instead of guessed at."""
    try:
        LOGS.mkdir(parents=True, exist_ok=True)
        path = LOGS / "astria-requests.log"
        if path.exists() and path.stat().st_size > 1_000_000:
            path.replace(path.with_suffix(".old.log"))
        heads = {k: _header(r.headers, k) for k in ("server", "cf-ray", "cf-mitigated", "retry-after", "content-type")}
        start = re.sub(r"\s+", " ", re.sub(r"<(script|style)[\s\S]*?</\1>|<[^>]+>", " ",
                                           (r.body or b"")[:3000].decode("utf-8", "replace"))).strip()[:400]
        with open(path, "a", encoding="utf-8") as f:
            f.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} {method} {url.replace(BASE, '')} → HTTP {r.status} "
                    f"({ref.kind}{', via ' + ref.route if ref.route else ''}); sent {sent:,} bytes; " + ", ".join(f"{k}: {v}" for k, v in heads.items() if v)
                    + f"; body: {start}\n")
    except OSError:
        pass


class Gate:
    """Every API call to Astria from this app goes through one of these (`GATE`), whichever thread makes it — four
    jobs polling, reference photos being prepared, the Astria.ai Browser listing: calls are spaced `SPACING` apart,
    and once Astria's front door has challenged or rate-limited one (`blocked`), **all** of them hold until the
    pause it asked for (its Retry-After, else `COOL`, longer each time it happens again) is over. Before this each
    thread found out for itself and kept asking — polls every 2 s from every job — which is how a pause is turned
    into a longer one. A quick call (a poll, a listing) doesn't wait out a long pause: it isn't sent and its
    caller is told "not now" (`wait` → False), as when Astria can't be reached."""

    SPACING = 0.3
    COOL = (15.0, 30.0, 60.0, 120.0)
    QUICK = 8.0                          # the longest a quick call waits for its turn

    def __init__(self, sleep: Callable[[float], None] = time.sleep, clock: Callable[[], float] = time.monotonic) -> None:
        self.sleep, self.clock = sleep, clock
        self.lock = threading.Lock()
        self.next_free = 0.0
        self.cool_until = 0.0
        self.strikes = 0
        self.struck_at = -1.0
        self.why = ""

    def cooling(self) -> float:
        """Seconds left of a pause Astria asked for (0 when there's none)."""
        with self.lock:
            return max(0.0, self.cool_until - self.clock())

    def wait(self, patient: bool) -> float | None:
        """Waits for this call's turn. → when it may go (the clock), or None: a pause is on that a quick call
        (`patient` False) shouldn't sit through — don't send it."""
        with self.lock:
            now = self.clock()
            if not patient and self.cool_until - now > self.QUICK:
                return None
            at = max(now, self.next_free, self.cool_until)
            self.next_free = at + self.SPACING
        if at > now:
            self.sleep(at - now)
        return at

    def blocked(self, started: float, retry_after: float | None, why: str) -> float:
        """A call that started at `started` was challenged / rate-limited. → the seconds everything now waits.
        Calls already on their way when the pause began don't make it longer (four jobs meet the same check)."""
        with self.lock:
            now = self.clock()
            if started > self.struck_at:
                self.strikes += 1
                self.struck_at = now
                secs = min(retry_after, 300.0) if retry_after else self.COOL[min(self.strikes, len(self.COOL)) - 1]
                self.cool_until = max(self.cool_until, now + secs)
                self.why = why
            return max(0.0, self.cool_until - now)

    def passed(self) -> None:
        """A call got through: the strikes are forgotten, and so is any pause still running (a request that
        reached Astria — by the browser window, say — means there's nothing left to wait out)."""
        with self.lock:
            self.strikes = 0
            self.cool_until = 0.0


GATE = Gate()


def check_connection(key: str | None = None) -> list[str]:
    """Astria Settings ▸ Check Connection: asks Astria for the account's first tune both ways the app can — Python's
    networking and the Mac's own curl — and says in plain lines what each got, which the app is using, and what
    that means. Nothing is created (one small GET each). The key is never in the lines."""
    import platform
    import ssl
    key = get_key() if key is None else key
    lines = [f"{app_identity.APP_NAME} · Python {platform.python_version()} · {ssl.OPENSSL_VERSION} · "
             f"macOS {platform.mac_ver()[0] or '—'}"]
    if not key:
        return lines + ["No API key is saved — add it above (astria.ai ▸ your account ▸ API)."]
    lines.append(f"API key: saved ({len(key)} characters)")
    auto = default_transport()
    ways = [("Python's networking", getattr(auto, "python", None) or Transport()),
            ("the Mac's curl", getattr(auto, "curl", None) or CurlTransport())]
    heads = {"Authorization": f"Bearer {key}", "Accept": "application/json", "User-Agent": UA}
    kinds = []
    for name, way in ways:
        try:
            r = way.send("GET", BASE + "/tunes?limit=1", heads, None, 30)
        except (Transport.PreSend, Transport.Ambiguous) as e:
            lines.append(f"Through {name}: no answer ({e})")
            kinds.append("none")
            continue
        if 200 <= r.status < 300:
            lines.append(f"Through {name}: Astria answered (HTTP {r.status}) — this way works.")
            kinds.append("ok")
        else:
            ref = explain(r)
            lines.append(f"Through {name}: {ref.message}")
            kinds.append(ref.kind)
    door = getattr(auto, "browser", None)
    by_door = ""
    if door is not None and kinds and all(k == "challenge" for k in kinds):
        # Both direct ways are checked: the browser window, where the person answers the check themselves.
        lines.append("Both direct ways are being checked — opening the “Astria — Cloudflare's check” window: answer "
                     "the check there (it closes by itself).")
        try:
            if hasattr(door, "insist"):
                door.insist()                                # asked for outright: an earlier "Not Now" doesn't hold
            r = door.send("GET", BASE + "/tunes?limit=1", heads, None, 30)
            if 200 <= r.status < 300:
                by_door = "ok"
                lines.append(f"Through the browser window: Astria answered (HTTP {r.status}) — this way works.")
            else:
                ref = explain(r)
                by_door = ref.kind
                lines.append(f"Through the browser window: {ref.message}")
        except (Transport.PreSend, Transport.Ambiguous) as e:
            by_door = "none"
            lines.append(f"Through the browser window: no answer ({e})")
    using = getattr(auto, "use", "python")
    if by_door in ("ok", "api") and isinstance(auto, AutoTransport):
        auto._prefer("browser")
        GATE.passed()
        using = "browser"
    lines.append("The app is sending through: " + {"curl": "the Mac’s curl", "browser": "the browser window"}.get(using, "Python’s networking")
                 + (f" · paused another {round(GATE.cooling())} s" if GATE.cooling() > 0 else ""))
    if by_door == "ok":
        lines.append("→ Cloudflare is checking this network's address, and you've answered its check: the app now "
                     "sends through the browser window (it will ask again when the check runs out). Try Generate again.")
    elif by_door == "api":
        lines.append("→ The check is answered and Astria is reachable through the browser window, but it refused the "
                     "request itself — see its words above (usually the key).")
    elif by_door in ("challenge", "none"):
        lines.append("→ Cloudflare is checking this network's address and the check in the window wasn't completed. "
                     "Press Check Connection again and answer it, or try another network (a phone hotspot). If it "
                     "can't be passed there either, send Astria these lines.")
    elif "ok" in kinds:
        if kinds[0] != "ok" and isinstance(auto, AutoTransport):
            auto._prefer("curl")
            lines.append("→ Python's networking is being turned away but the Mac's own gets through: the app uses "
                         "that from now on. Try Generate again.")
        else:
            lines.append("→ Astria is reachable and the key is accepted. If a generation still fails, the reason is "
                         "in its message (and in the log below).")
    elif all(k == "challenge" for k in kinds):
        lines.append("→ Both ways are met with Cloudflare's browser check: it's this network or address being "
                     "checked. Turn off a VPN if one is on, or try another network (a phone hotspot). If it stays, "
                     "send Astria these lines.")
    elif "api" in kinds:
        lines.append("→ Astria is reachable but refused the request itself — see its words above (usually the key).")
    elif all(k == "none" for k in kinds):
        lines.append("→ Astria couldn't be reached at all — check the internet connection.")
    else:
        lines.append("→ Astria's side isn't answering properly right now — try again in a few minutes.")
    lines.append("Log: " + str(LOGS / "astria-requests.log").replace(str(Path.home()), "~"))
    return lines


def pause_note() -> str:
    """Words for a window when Astria has asked this Mac to wait ("" when it hasn't)."""
    left = GATE.cooling()
    return f"Astria asked this Mac to slow down — asking again in {max(1, round(left))} s." if left > 0 else ""


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
                 sleep: Callable[[float], None] = time.sleep, gate: Gate | None = None) -> None:
        self.key = get_key() if key is None else key
        self.t = transport or default_transport()
        self.sleep = sleep
        if gate is None and (transport is not None or sleep is not time.sleep):
            # A client with its own transport or sleep (tests): its own gate, on a clock that moves only when
            # it sleeps — so a pause is "waited" at once and nothing leaks between clients.
            t = [0.0]

            def slept(secs: float) -> None:
                t[0] += max(0.0, secs)
                sleep(secs)
            self.sleep = slept
            gate = Gate(slept, lambda: t[0])
        self.gate = gate or GATE
        self.last_refusal: Refusal | None = None
        self.download_problem = ""                           # why the last picture couldn't be fetched (for the message)

    def _send(self, method: str, url: str, headers: dict, body: bytes | None, timeout: float,
              patient: bool = False) -> Response | None:
        """One API request through the gate. None: not sent — Astria asked for a pause and this call (`patient`
        False) isn't worth holding for it. A refusal is explained (`last_refusal`), logged, and — when it's the
        front door saying wait — makes every other call wait too. Raises the transport's PreSend / Ambiguous."""
        started = self.gate.wait(patient)
        if started is None:
            return None
        r = self.t.send(method, url, headers, body, timeout)
        if 200 <= r.status < 300:
            self.gate.passed()
            self.last_refusal = None
            return r
        ref = self.last_refusal = explain(r, len(body or b""))
        if ref.wait:
            self.gate.blocked(started, ref.retry_after, ref.message)
        if not (r.status == 404 and method == "GET"):          # (a prompt asked for the moment it's made)
            _note_refusal(method, url, r, ref, len(body or b""))
        return r

    @property
    def configured(self) -> bool:
        return bool(self.key)

    def _headers(self, extra: dict | None = None) -> dict:
        h = {"Authorization": f"Bearer {self.key}", "Accept": "application/json", "User-Agent": UA}
        h.update(extra or {})
        return h

    def _get_json(self, path: str, timeout: float = 30):
        try:
            r = self._send("GET", BASE + path, self._headers(), None, timeout)
        except (Transport.PreSend, Transport.Ambiguous):
            return None
        if r is None or not 200 <= r.status < 300:
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
    def create_prompt(self, tune: int, fields: dict[str, str], files: list,
                      wait: Callable[[str], None] | None = None) -> int:
        """Creates the prompt → its id. Survives (the iPhone's `createPrompt`, plus, Nov 19):
        * the front door saying wait (a Cloudflare check, "too many requests") — Astria never saw the request, so
          it's sent again once the pause is over (`Gate`), up to four times, `wait` told each time;
        * Astria's servers not answering (502/503/504/52x) — the request **may** have been taken, so the tune's
          newest prompts are looked through before anything is sent again: a job is never made (and paid for) twice."""
        body, boundary = _multipart(fields, files)
        text = fields.get("prompt[text]", "")
        for attempt in range(1, 5):
            started = time.time()
            left = self.gate.cooling()
            if left > 1 and wait:
                wait(f"Astria asked this Mac to wait — sending in {round(left)} s (try {attempt} of 4)…")
            try:
                r = self._send("POST", f"{BASE}/tunes/{tune}/prompts",
                               self._headers({"Content-Type": f"multipart/form-data; boundary={boundary}"}), body, 180,
                               patient=True)
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
            ref = self.last_refusal or explain(r, len(body))
            if ref.wait:
                if ref.route.endswith("+browser"):           # the person was asked and didn't answer the check:
                    raise AIError("server", _advice(ref))    # waiting and asking again would only ask them again
                if attempt < 4:
                    continue                                 # the gate holds the next try until the pause is over
                raise AIError("server", _advice(ref, tried=4))
            if ref.kind == "gateway":
                found = self.find_recent_prompt(tune, text, started - 30)
                if isinstance(found, int):
                    return found                             # it was taken after all
                if attempt == 4:
                    raise AIError("server", _advice(ref, tried=4))
                self._backoff(attempt, _header(r.headers, "retry-after"))
                if found == "unavailable":                   # can't tell yet: look once more before sending again
                    found = self.find_recent_prompt(tune, text, started - 30)
                    if isinstance(found, int):
                        return found
                    if found == "unavailable":
                        raise AIError("network")             # don't risk a second job
                continue
            if self._transient(r.status) and attempt < 4:
                self._backoff(attempt, _header(r.headers, "retry-after"))
                continue
            raise AIError("server", _advice(ref))
        raise AIError("network")

    def _post_tune(self, body: bytes, boundary: str, timeout: float) -> Response:
        """POST /tunes, sent again (up to three times) only when the front door said wait — a request it turned
        away never reached Astria, so nothing is made twice. Raises the transport's errors."""
        r = None
        for _attempt in range(3):
            r = self._send("POST", f"{BASE}/tunes",
                           self._headers({"Content-Type": f"multipart/form-data; boundary={boundary}"}), body, timeout,
                           patient=True)
            if 200 <= r.status < 300 or not (self.last_refusal and self.last_refusal.wait):
                break
        return r

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
            except (Transport.PreSend, Transport.Ambiguous) as e:
                self.download_problem = f"no answer from {_host(url)} ({e})"
                continue
            if self._transient(r.status):
                self.download_problem = f"{_host(url)} answered HTTP {r.status}"
                continue
            if not 200 <= r.status < 300:
                # Until Nov 20 this was silent — and it was the whole story of "the pictures were made but never
                # came": they're on mp.astria.ai, behind the same Cloudflare check as the API.
                ref = explain(r)
                self.download_problem = f"{_host(url)}: {ref.message}"
                _note_refusal("GET", f"picture on {_host(url)}", r, ref, 0)
                if ref.kind == "challenge" and not ref.route.endswith("+browser"):
                    continue                                 # (a check the window wasn't asked about yet: once more)
                return None
            if is_picture(r.body):
                self.download_problem = ""
                return r.body
            self.download_problem = f"{_host(url)} sent something that isn't a picture"
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
                self.sleep(3 if tick < 15 else 4 if tick < 60 else 6)
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
            if known:                                        # made, but not one of them could be fetched: say so
                why = getattr(self, "download_problem", "")
                raise AIError("network", f"Astria made {len(known)} picture{'s' if len(known) != 1 else ''} but "
                                         f"{'they' if len(known) != 1 else 'it'} couldn't be downloaded"
                                         + (f" — {why}" if why else "") + ".")
            raise AIError("timed_out")
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
            r = self._post_tune(body, boundary, 600)
        except Transport.PreSend:
            raise AIError("network")
        except Transport.Ambiguous:
            # The upload may have landed. Don't send it again (a second tune is a second charge): say so.
            raise AIError("server", "the connection dropped while the photos were going up — look on astria.ai "
                                    "before trying again, the model may already be training")
        if not 200 <= r.status < 300:
            ref = self.last_refusal or explain(r, len(body))
            raise AIError("server", _advice(ref) + (" Look on astria.ai before trying again — the model may already "
                                                    "be training." if ref.kind == "gateway" else ""))
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
            r = self._post_tune(body, boundary, 120)
        except (Transport.PreSend, Transport.Ambiguous):
            raise AIError("network")
        if not 200 <= r.status < 300:
            raise AIError("server", _advice(self.last_refusal or explain(r, len(body))))
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
                 note: Callable[[str], None] | None = None, stop: threading.Event | None = None,
                 wait: Callable[[str], None] | None = None) -> list[bytes]:
        """`wait`: told (a line for the job's status) when Astria has asked this Mac to pause before sending."""
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
            pid = self.create_prompt(tune, fields, files, wait)
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

    def prompt_page(self, offset: int, size: int = 50) -> list[Prompt] | None:
        """One page of the account's prompts, newest first, starting `offset` in — for a listing shown as it
        loads (the Astria.ai Browser). None when Astria can't be asked this way just now; [] past the end."""
        if not self.configured:
            return []
        arr = self._get_json(f"/prompts?limit={size}&offset={offset}", timeout=40)
        if not isinstance(arr, list):
            return None
        out: list[Prompt] = []
        for p in arr:
            if isinstance(p, dict) and (pid := _int(p.get("id"))) is not None:
                out.append(Prompt(pid, str(p.get("text") or ""), _int(p.get("tune_id")),
                                  parse_iso(p.get("created_at")), _images_of(p), _int(p.get("num_images"))))
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


def upscale_2x(data: bytes) -> bytes:
    """A result picture enlarged 2× with **Lanczos** resampling — nothing else (no sharpening, no AI): the form's
    "Upscale results 2×". PNG stays PNG (lossless); anything else comes back a JPEG at quality 98, 4:4:4, so the
    save's own JPEG step (`_encode`, quality 95) is the only real loss. Colour profile and EXIF kept; a rotated
    JPEG is turned upright first. Raises ValueError / OSError when it isn't a picture Pillow can read."""
    from PIL import Image, ImageOps
    with Image.open(io.BytesIO(data)) as im:
        fmt = (im.format or "").upper()
        icc = im.info.get("icc_profile")
        try:
            exif = im.getexif()
        except Exception:  # noqa: BLE001 — EXIF Pillow can't parse: none is carried
            exif = None
        im = ImageOps.exif_transpose(im)
        if im.mode not in ("RGB", "RGBA", "L"):
            im = im.convert("RGBA" if "A" in im.getbands() else "RGB")
        big = im.resize((im.width * 2, im.height * 2), Image.Resampling.LANCZOS)
        out = io.BytesIO()
        if fmt == "PNG":
            big.save(out, "PNG", icc_profile=icc)
        else:
            if big.mode != "RGB":
                big = big.convert("RGB")
            extra = {}
            if exif is not None and len(exif):
                exif[0x0112] = 1                             # upright now
                extra["exif"] = exif.tobytes()
            big.save(out, "JPEG", quality=98, subsampling=0, icc_profile=icc, **extra)
        return out.getvalue()


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


# ----------------------------------------------------------------------------- downloads from the browser
#
# A picture taken down from the Astria.ai Browser is kept **exactly as Astria made it** — the same bytes, in its
# own format, with whatever EXIF, XMP and colour profile it came with — and what Photo Browser for Mac knows about it is
# *added* to its metadata in place: the prompt (as the caption every app shows, and in the app's own "AI-generated
# · Prompt: …" comment), the model, the date it was made and the IPTC label that says a picture is AI-made.
# Nothing already in the file is replaced: each field is written only where the file has none.
#
# ExifTool does the writing when it's installed (every format, and it merges into existing XMP properly). Without
# it, JPEG and PNG are still done here, losslessly — the metadata block is spliced into the file, the picture data
# is never decoded or re-compressed; other formats are kept untouched and the caller is told.

AI_SOURCE_TYPE = "http://cv.iptc.org/newscodes/digitalsourcetype/trainedAlgorithmicMedia"
_PLACE_LOCK = threading.Lock()


def image_ext(data: bytes) -> str:
    """The file extension for a downloaded picture, by what it is."""
    if data[:3] == b"\xff\xd8\xff":
        return ".jpg"
    if data[:8] == b"\x89PNG\r\n\x1a\n":
        return ".png"
    if data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return ".webp"
    if data[:6] in (b"GIF87a", b"GIF89a"):
        return ".gif"
    if data[4:8] == b"ftyp":
        return ".avif" if b"avif" in data[8:32] else ".heic"
    return ".jpg"


def find_exiftool() -> str | None:
    import shutil
    return shutil.which("exiftool") or next((x for x in ("/opt/homebrew/bin/exiftool", "/usr/local/bin/exiftool")
                                             if os.path.isfile(x)), None)


def _ai_comment(prompt: str) -> str:
    p = prompt.strip()
    return f"AI-generated · Prompt: {p}" if p else "AI-generated"


def _software(model: str) -> str:
    return f"PhotoBrowser AI — {model}" if model else "PhotoBrowser AI"


def _exiftool_embed(tool: str, path: str, prompt: str, model: str, when: datetime | None) -> bool:
    def only_if_missing(tag: str, value: str) -> list[str]:
        return [f"-{tag}-=", f"-{tag}={value}"]            # ExifTool: "write it only where there is none"
    args = [tool, "-overwrite_original", "-m", "-q", "-charset", "exif=utf8"]
    args += only_if_missing("EXIF:UserComment", _ai_comment(prompt))
    args += only_if_missing("EXIF:Software", _software(model))
    args += only_if_missing("XMP-xmp:CreatorTool", _software(model))
    args += only_if_missing("XMP-iptcExt:DigitalSourceType", AI_SOURCE_TYPE)
    if prompt.strip():
        args += only_if_missing("EXIF:ImageDescription", prompt.strip())
        args += only_if_missing("XMP-dc:Description", prompt.strip())
    if when is not None:
        stamp = when.strftime("%Y:%m:%d %H:%M:%S")
        args += only_if_missing("EXIF:DateTimeOriginal", stamp)
        args += only_if_missing("EXIF:CreateDate", stamp)
    try:
        r = subprocess.run(args + [path], capture_output=True, timeout=120)
    except (OSError, subprocess.SubprocessError):
        return False
    return r.returncode == 0


def _exif_with(data: bytes, prompt: str, model: str, when: datetime | None) -> bytes | None:
    """The picture's own EXIF with our fields added where it has none — as an "Exif\\0\\0…" block. None when
    there's nothing to add or it can't be made."""
    from PIL import Image
    try:
        with Image.open(io.BytesIO(data)) as im:
            exif = im.getexif()
            sub = dict(exif.get_ifd(0x8769))
    except Exception:  # noqa: BLE001
        return None
    if 37510 not in sub:
        sub[37510] = _user_comment(_ai_comment(prompt))
    if 305 not in exif:
        exif[305] = _software(model).encode("utf-8")
    if prompt.strip() and 270 not in exif:
        exif[270] = prompt.strip().encode("utf-8")
    if when is not None:
        stamp = when.strftime("%Y:%m:%d %H:%M:%S")
        sub.setdefault(36867, stamp)
        sub.setdefault(36868, stamp)
    exif[0x8769] = sub
    try:
        return exif.tobytes()
    except Exception:  # noqa: BLE001
        return None


def _xmp_packet(prompt: str, model: str) -> bytes:
    from xml.sax.saxutils import escape
    desc = f'<dc:description><rdf:Alt><rdf:li xml:lang="x-default">{escape(prompt.strip())}</rdf:li></rdf:Alt>' \
           f'</dc:description>' if prompt.strip() else ""
    return ('<?xpacket begin="\ufeff" id="W5M0MpCehiHzreSzNTczkc9d"?><x:xmpmeta xmlns:x="adobe:ns:meta/">'
            '<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description rdf:about="" '
            'xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:xmp="http://ns.adobe.com/xap/1.0/" '
            'xmlns:Iptc4xmpExt="http://iptc.org/std/Iptc4xmpExt/2008-02-29/" '
            f'xmp:CreatorTool="{escape(_software(model), {chr(34): "&quot;"})}" '
            f'Iptc4xmpExt:DigitalSourceType="{AI_SOURCE_TYPE}">{desc}</rdf:Description></rdf:RDF></x:xmpmeta>'
            '<?xpacket end="w"?>').encode("utf-8")


def _jpeg_with(data: bytes, prompt: str, model: str, when: datetime | None) -> bytes | None:
    """A JPEG with our metadata spliced in: its segments are walked, the EXIF block replaced by the merged one
    (or added), an XMP packet added when it has none. The compressed picture isn't touched."""
    exif = _exif_with(data, prompt, model, when)
    if exif is None or len(exif) > 65000:
        return None
    segments: list[bytes] = []
    has_xmp = False
    i = 2
    n = len(data)
    while i + 4 <= n and data[i] == 0xFF:
        marker = data[i + 1]
        if marker == 0xDA or marker == 0xD9:               # the picture starts: everything from here is kept whole
            break
        size = int.from_bytes(data[i + 2:i + 4], "big")
        if size < 2 or i + 2 + size > n:
            return None
        seg = data[i:i + 2 + size]
        body = seg[4:]
        if marker == 0xE1 and body[:6] == b"Exif\0\0":
            pass                                           # replaced by the merged one below
        else:
            if marker == 0xE1 and body.startswith(b"http://ns.adobe.com/xap/1.0/\0"):
                has_xmp = True
            segments.append(seg)
        i += 2 + size
    rest = data[i:]
    if not rest:
        return None
    ours = [b"\xff\xe1" + (len(exif) + 2).to_bytes(2, "big") + exif]
    if not has_xmp:
        xmp = b"http://ns.adobe.com/xap/1.0/\0" + _xmp_packet(prompt, model)
        if len(xmp) < 65000:
            ours.append(b"\xff\xe1" + (len(xmp) + 2).to_bytes(2, "big") + xmp)
    head = [s_ for s_ in segments if s_[1] == 0xE0]         # JFIF stays first, as the format wants
    tail = [s_ for s_ in segments if s_[1] != 0xE0]
    return b"\xff\xd8" + b"".join(head) + b"".join(ours) + b"".join(tail) + rest


def _png_with(data: bytes, prompt: str, model: str, when: datetime | None) -> bytes | None:
    """A PNG with an eXIf chunk (merged with its own) and, when it has no XMP, an XMP text chunk — put before
    the picture data, which is copied as it is."""
    import zlib
    exif = _exif_with(data, prompt, model, when)
    if exif is None:
        return None

    def chunk(kind: bytes, body: bytes) -> bytes:
        return len(body).to_bytes(4, "big") + kind + body + zlib.crc32(kind + body).to_bytes(4, "big")
    out = [data[:8]]
    i, n = 8, len(data)
    has_xmp = b"XML:com.adobe.xmp" in data[:min(n, 1 << 20)]
    placed = False
    while i + 12 <= n:
        size = int.from_bytes(data[i:i + 4], "big")
        kind = data[i + 4:i + 8]
        end = i + 12 + size
        if end > n:
            return None
        if kind == b"IDAT" and not placed:
            out.append(chunk(b"eXIf", exif[6:]))
            if not has_xmp:
                out.append(chunk(b"iTXt", b"XML:com.adobe.xmp\0\0\0\0\0" + _xmp_packet(prompt, model)))
            placed = True
        if kind != b"eXIf":                                 # its own EXIF is in the merged one
            out.append(data[i:end])
        i = end
    return b"".join(out) if placed else None


def save_download(data: bytes, folder: str, model: str = "", prompt: str = "", when: float | None = None) -> tuple[str, str]:
    """A picture from the Astria.ai Browser into `folder`: the file as Astria made it, with the prompt, the model,
    its date and the AI-made label added to its metadata (see above). Returns (the new file, how the metadata
    went in: "exiftool", "written" — done here, losslessly — or "kept" when it couldn't be added and the file is
    as it came)."""
    import simpcity as sc
    stamp = datetime.fromtimestamp(when) if when else datetime.now()
    ext = image_ext(data)
    target = Path(folder)
    sc.make_folder(target)
    name = f"{_safe_name(prompt.strip()[:40] or 'AI Creation')}{ext}"
    tool = find_exiftool()
    how = "kept"
    if tool is None:
        made = _jpeg_with(data, prompt, model, stamp) if ext == ".jpg" else \
            _png_with(data, prompt, model, stamp) if ext == ".png" else None
        if made is not None:
            data, how = made, "written"
    with _PLACE_LOCK:                                      # downloads run several at a time: one name at a time
        path = _place(data, target, name, stamp)
    if tool is not None:
        if _exiftool_embed(tool, path, prompt, model, stamp):
            how = "exiftool"
            ts = stamp.timestamp()
            try:
                os.utime(path, (ts, ts))                   # the write moved its date: back to when it was made
            except OSError:
                pass
    return path, how


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
            if job.get("upscale"):                           # the form's "Upscale results 2×", asked before the quit
                try:
                    data = upscale_2x(data)
                except (OSError, ValueError):
                    pass
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
