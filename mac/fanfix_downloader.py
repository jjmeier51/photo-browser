#!/usr/bin/env python3
"""Safe Finder ▸ "Download from Fanfix…" — the window (fanfix.py reads what Fanfix's page loads and shows,
social.py places the files).

    python3 mac/fanfix_downloader.py "/Volumes/SSD/Jane" [creator]

For creators the person subscribes to or bought from: their own purchased content, saved to the drive for a
personal archive. The window is a real Chromium (Qt WebEngine) with its own lasting profile: log in to Fanfix
there once (and answer Cloudflare's check there when it asks) — it never fills in a login or answers a check
itself. Open a creator's page (app.fanfix.io/@name), or Home Feed (everyone you subscribe to), Purchases (your
Gallery) or a chat in Messages, and press Download: the page is loaded afresh and scrolled to its end so it loads
everything, and every photo and video this account can open there — named by the page's data, or shown on the
page — is downloaded into the creator's folder (`<folder>/<creator>`, or the folder itself when it's the
creator's), named by Fanfix's media id, dated from the post, captioned, tagged "fanfix" in the shared tag store.
Locked posts are left out (counted), and so are videos protected by DRM. The creator's folder's `.fanfix.json`
keeps the ids, so the next run takes only what's new.

**The files come down through this same browser** (fanripper's model): each address goes to Chromium's own
download manager (`_begin_download` on the GUI thread; a worker waits for it, `_browser_fetch`), so the person's
session and Cloudflare's clearance go with it — a plain request outside the browser gets Cloudflare's check page,
not the file. A plain request is only the fallback. Four at a time, on worker threads (`social.settle`), as the
page goes, so links that expire are used while they're fresh.

The page scrolls in front of the person — what it reads is what they see. "Save Troubleshooting File" writes the
last run (what the page loaded, what it showed, what was found, what failed and why) to ~/Library/Logs/Safe Finder.
"""
from __future__ import annotations

import concurrent.futures
import json
import os
import sys
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from PySide6.QtCore import QFile, QObject, QSettings, Qt, QTimer, QUrl, Signal  # noqa: E402
from PySide6.QtWidgets import (QApplication, QCheckBox, QHBoxLayout, QLabel, QLineEdit, QMainWindow,  # noqa: E402
                               QMessageBox, QPlainTextEdit, QProgressBar, QPushButton, QVBoxLayout, QWidget)
from PySide6.QtWebEngineCore import (QWebEngineDownloadRequest, QWebEnginePage, QWebEngineProfile,  # noqa: E402
                                     QWebEngineScript)
from PySide6.QtWebEngineWidgets import QWebEngineView  # noqa: E402

import fanfix  # noqa: E402
import simpcity as sc  # noqa: E402
import social  # noqa: E402

LANES = 4                     # files downloaded at once (paced like a person browsing)
SAVE_EVERY = 25               # the records are saved (and the files tagged) after this many files
TICK_MS = 1200                # one scroll step (and one look at what the page loaded and shows) every this often
IDLE_TICKS = 7                # this many steps with no new height and nothing new loaded: the end of the page
CHECK_MINUTES = 3             # how long a Cloudflare check on the page is waited for
MAX_MINUTES = 90              # a page that never ends is left after this
KEEP_CHARS = 60_000_000       # what the page loaded, kept for a troubleshooting file (the last run's)
NO_START_S = 40               # a browser download that hasn't started after this is given up
STALL_S = 120                 # …and one that has received nothing for this long

_PROFILE: QWebEngineProfile | None = None


@dataclass
class _Job:
    """One file the browser is asked to download (made on a worker thread, run on the GUI thread)."""
    url: str
    folder: str
    name: str
    owner: object = None
    done: threading.Event = field(default_factory=threading.Event)
    path: str = ""
    why: str = ""
    started: bool = False
    moved: float = field(default_factory=time.monotonic)
    request: object = None


_JOBS: dict[str, list[_Job]] = {}     # waiting for Chromium's downloadRequested, by address (GUI thread only)


def _key(url: QUrl) -> str:
    return bytes(url.toEncoded()).decode("ascii", "replace")


def _on_download(req: QWebEngineDownloadRequest) -> None:
    """Chromium is about to download something: one of ours goes into its job's folder under its name; anything
    else (a link clicked in the page) is left alone."""
    key = _key(req.url())
    if key not in _JOBS:
        bare = key.split("?", 1)[0]
        key = next((k for k in _JOBS if k.split("?", 1)[0] == bare), "")
    jobs = _JOBS.get(key)
    if not jobs:
        return
    job = jobs.pop(0)
    if not jobs:
        _JOBS.pop(key, None)
    job.request, job.started, job.moved = req, True, time.monotonic()
    req.setDownloadDirectory(job.folder)
    req.setDownloadFileName(job.name)
    req.receivedBytesChanged.connect(lambda: setattr(job, "moved", time.monotonic()))
    req.isFinishedChanged.connect(lambda: _download_finished(job))
    req.accept()


def _download_finished(job: _Job) -> None:
    req = job.request
    if req is None or job.done.is_set() or not req.isFinished():
        return
    if req.state() == QWebEngineDownloadRequest.DownloadState.DownloadCompleted:
        job.path = os.path.join(req.downloadDirectory(), req.downloadFileName())
    else:
        job.why = req.interruptReasonString() or "the download was stopped"
    job.done.set()


def _trash(path: str) -> bool:
    """To the system Trash (Put Back works)."""
    try:
        r = QFile.moveToTrash(path)
    except Exception:  # noqa: BLE001
        return False
    ok = r[0] if isinstance(r, tuple) else bool(r)
    return bool(ok) and not os.path.lexists(path)


def profile() -> QWebEngineProfile:
    """Fanfix's own lasting browser profile (its login survives restarts), with the watching script put into
    every page before the page's own (`fanfix.HOOK_JS`), and its downloads sorted to their jobs."""
    global _PROFILE
    if _PROFILE is None:
        _PROFILE = QWebEngineProfile("fanfix", QApplication.instance())
        _PROFILE.setPersistentCookiesPolicy(QWebEngineProfile.PersistentCookiesPolicy.ForcePersistentCookies)
        script = QWebEngineScript()
        script.setName("photobrowser-watch")
        script.setSourceCode(fanfix.HOOK_JS)
        script.setInjectionPoint(QWebEngineScript.InjectionPoint.DocumentCreation)
        script.setWorldId(QWebEngineScript.ScriptWorldId.MainWorld)
        script.setRunsOnSubFrames(False)
        _PROFILE.scripts().insert(script)
        _PROFILE.downloadRequested.connect(_on_download)
    return _PROFILE


class _Bridge(QObject):
    call = Signal(object, object)      # (callback, value) from a worker thread → back on the GUI thread


class FanfixWindow(QMainWindow):
    """The downloader, from one folder (the one right-clicked)."""

    finished = Signal(str, list)       # (the folder, files written) — Safe Finder refreshes + tags

    def __init__(self, folder: str, start: str = "", tags=None, parent=None) -> None:
        super().__init__(parent)
        self.person = Path(folder)
        self.tags = tags
        self.running = self.stopping = self.closed = False
        self.cookies: dict[str, dict[str, str]] = {}
        self.bridge = _Bridge()
        self.bridge.call.connect(lambda cb, value: cb(value))
        self.settings = QSettings("PhotoBrowser", "SafeFinder")
        self.exiftool = sc.find_exiftool()
        self.captured: list[dict] = []
        self.report: dict = {}
        self.setWindowTitle(f"Fanfix — {self.person.name}")
        self.resize(1100, 900)

        prof = profile()
        self.ua = prof.httpUserAgent() or social.UA
        self.store = prof.cookieStore()
        self.store.cookieAdded.connect(self._cookie_added)
        self.store.loadAllCookies()
        self.view = QWebEngineView()
        self.view.setPage(QWebEnginePage(prof, self.view))
        self.view.urlChanged.connect(self._url_changed)

        rec = fanfix.record(self.person)
        self.field = QLineEdit(start or rec.get("handle") or "")
        self.field.setPlaceholderText("creator (filled in from the page you open)")
        self.field.textEdited.connect(lambda _t: setattr(self, "_typed", True))
        self.field.returnPressed.connect(self.open_creator)
        self._typed = bool(start)
        self.go_btn = QPushButton("Download from This Page")
        self.go_btn.setDefault(True)
        self.go_btn.setToolTip("Loads the page afresh, scrolls it to the end, and downloads every photo and video on "
                               "it that your account can open")
        self.go_btn.clicked.connect(self.start)
        self.stop_btn = QPushButton("Stop")
        self.stop_btn.setEnabled(False)
        self.stop_btn.clicked.connect(self.stop)
        open_btn = QPushButton("Open Creator")
        open_btn.setToolTip("Opens the creator's page on Fanfix (app.fanfix.io/@name)")
        open_btn.clicked.connect(self.open_creator)
        self.page_btns = []
        for label, path, tip in fanfix.PAGES:
            b = QPushButton(label)
            b.setToolTip(f"Opens {tip}")
            b.clicked.connect(lambda _c=False, p=path: self.view.load(QUrl(fanfix.HOME + p)))
            self.page_btns.append(b)

        def option(text: str, key: str, default: bool, tip: str) -> QCheckBox:
            box = QCheckBox(text)
            box.setToolTip(tip)
            box.setChecked(str(self.settings.value(f"fanfix/{key}", "true" if default else "false")) == "true")
            box.toggled.connect(lambda on: self.settings.setValue(f"fanfix/{key}", "true" if on else "false"))
            return box
        self.photos_2x = option("Upscale photos 2×", "photos2x", False, "Each photo twice the size, in place")
        self.ai = option("with Real-ESRGAN (AI)", "ai", False, "Slower, and sharper than Lanczos — needs Upscayl "
                         "(see AI Upscale)")
        self.videos_1080 = option("Upscale videos to 1080p", "video1080", False, "Videos below 1080p made 1080p")
        self.engine = None
        try:
            import ai_upscale
            self.engine = ai_upscale.find_engine(self.settings.value("upscale/engine") or None)
        except Exception:  # noqa: BLE001 — no engine just means no AI option
            self.engine = None
        self.ai.setVisible(self.engine is not None)
        self.ai.setEnabled(self.photos_2x.isChecked())
        self.photos_2x.toggled.connect(self.ai.setEnabled)
        login = QPushButton("Log In to Fanfix")
        login.clicked.connect(lambda: self.view.load(QUrl(fanfix.LOGIN)))
        self.trouble_btn = QPushButton("Save Troubleshooting File")
        self.trouble_btn.setToolTip("Writes the last run — what the page loaded and showed, what was found, what "
                                    "failed and why — to a file in ~/Library/Logs/Safe Finder")
        self.trouble_btn.clicked.connect(self.save_troubleshooting)
        self.trouble_btn.setEnabled(False)

        top = QHBoxLayout()
        top.addWidget(QLabel("Creator:"))
        top.addWidget(self.field, 1)
        top.addWidget(open_btn)
        for b in self.page_btns:
            top.addWidget(b)
        top.addWidget(self.go_btn)
        top.addWidget(self.stop_btn)
        row2 = QHBoxLayout()
        for w in (self.photos_2x, self.ai, self.videos_1080):
            row2.addWidget(w)
        row2.addStretch(1)
        row2.addWidget(self.trouble_btn)
        row2.addWidget(login)
        self.status = QLabel("Log in to Fanfix below if you haven't, open a creator's page — or Home Feed, Purchases, a "
                             "chat (its whole history is read), or Messages itself (every chat, one after another) — "
                             "and press Download. Files go into a folder for each creator inside "
                             f"“{self.person.name}”, tagged “{fanfix.TAG}”.")
        self.status.setWordWrap(True)
        self.bar = QProgressBar()
        self.bar.setVisible(False)
        self.bar.setFixedWidth(240)
        self.bar.setFormat("%v of %m")
        self.log = QPlainTextEdit()
        self.log.setReadOnly(True)
        self.log.setMaximumHeight(170)
        self.log.setMaximumBlockCount(5000)
        box = QWidget()
        lay = QVBoxLayout(box)
        lay.addLayout(top)
        lay.addLayout(row2)
        progress = QHBoxLayout()
        progress.addWidget(self.status, 1)
        progress.addWidget(self.bar, 0, Qt.AlignmentFlag.AlignVCenter)
        lay.addLayout(progress)
        lay.addWidget(self.view, 1)
        lay.addWidget(self.log)
        self.setCentralWidget(box)
        handle = fanfix.clean_handle(self.field.text())
        self.view.load(QUrl(fanfix.profile_url(handle) if handle else fanfix.HOME))
        if not self.exiftool:
            self._log("ExifTool isn't installed, so a post's date only goes on the file's dates, and no caption goes "
                      "into the files (install it with: brew install exiftool).")

    # ------------------------------------------------------------------ small helpers
    def _log(self, line: str) -> None:
        self.log.appendPlainText(time.strftime("%H:%M:%S ") + line)

    def _say(self, line: str) -> None:
        self.status.setText(line)

    def _cookie_added(self, cookie) -> None:
        domain = cookie.domain().lstrip(".")
        self.cookies.setdefault(domain, {})[cookie.name().data().decode("latin-1")] = \
            cookie.value().data().decode("latin-1")

    def cookie_header(self) -> str:
        """The person's Fanfix cookies — sent only to Fanfix's own hosts, on a plain request (fanfix.tries_for)."""
        pairs: dict[str, str] = {}
        for domain, jar in self.cookies.items():
            if domain == fanfix.DOMAIN or domain.endswith("." + fanfix.DOMAIN):
                pairs.update(jar)
        return "; ".join(f"{k}={v}" for k, v in pairs.items())

    def _url_changed(self, url: QUrl) -> None:
        handle = fanfix.creator_from_url(url.toString())
        if handle and not self.running and not self._typed:
            self.field.setText(handle)

    def open_creator(self) -> None:
        handle = fanfix.clean_handle(self.field.text())
        if handle:
            self.field.setText(handle)
            self.view.load(QUrl(fanfix.profile_url(handle)))

    def _shown(self, p: Path) -> str:
        try:
            return str(p.relative_to(self.person.parent))
        except ValueError:
            return str(p)

    # ------------------------------------------------------------------ downloading through the browser
    def _browser_fetch(self, url: str, folder: str, name: str) -> tuple[str | None, str]:
        """`url` downloaded by this window's Chromium into `folder` as `name` (on a worker thread: waits)."""
        if self.closed:
            return None, "the window was closed"
        job = _Job(url, folder, name, owner=self)
        self.bridge.call.emit(self._begin_download, job)
        while not job.done.wait(0.5):
            idle = time.monotonic() - job.moved
            if self.stopping or self.closed or idle > (STALL_S if job.started else NO_START_S):
                self.bridge.call.emit(self._cancel_download, job)
                job.done.wait(10)
                if self.stopping or self.closed:
                    return None, "stopped"
                return None, "the download stalled" if job.started else "the browser didn't start the download"
        return (job.path or None), job.why

    def _begin_download(self, job: _Job) -> None:
        if self.closed:
            job.why = "the window was closed"
            job.done.set()
            return
        _JOBS.setdefault(_key(QUrl(job.url)), []).append(job)
        self.view.page().download(QUrl(job.url), job.name)

    def _cancel_download(self, job: _Job) -> None:
        for key, jobs in list(_JOBS.items()):
            if job in jobs:
                jobs.remove(job)
                if not jobs:
                    _JOBS.pop(key, None)
        if job.request is not None and not job.request.isFinished():
            job.request.cancel()
        if not job.why:
            job.why = "stopped"
        job.done.set()

    def _cancel_all(self) -> None:
        for jobs in list(_JOBS.values()):
            for job in list(jobs):
                if job.owner is self:
                    self._cancel_download(job)

    # ------------------------------------------------------------------ run / stop
    def start(self) -> None:
        if self.running:
            return
        url = self.view.url().toString()
        if not fanfix.fanfix_host(url) or url.rstrip("/").endswith("/login"):
            QMessageBox.information(self, "Fanfix", "Open a creator's page on Fanfix first (log in if you haven't) — "
                                    "or Home Feed, Purchases, or a chat in Messages.")
            return
        on_page = fanfix.creator_from_url(url)
        typed = fanfix.clean_handle(self.field.text()) if self._typed else ""
        self.hint = on_page or typed
        if self.hint:
            self.field.setText(self.hint)
        self.running, self.stopping = True, False
        self.started = self.page_started = time.monotonic()
        self.all_chats = fanfix.chats_page(url)          # the Messages list: every chat in it, one after another
        self.chats_listed = False
        self.pages: list[tuple[str, str]] = []           # (address, creator) still to read after this page
        self.chats_read = 0
        self.direction = -1 if fanfix.chat_id(url) else 1     # a chat's history loads above it
        self.opts = social.Options(photos_2x=self.photos_2x.isChecked(),
                                   ai=self.ai.isChecked() and self.engine is not None and self.photos_2x.isChecked(),
                                   videos_1080=self.videos_1080.isChecked())
        for w in (self.go_btn, self.photos_2x, self.ai, self.videos_1080, self.field, self.trouble_btn, *self.page_btns):
            w.setEnabled(False)
        self.stop_btn.setEnabled(True)
        self.bar.setVisible(True)
        self.bar.setRange(0, 0)
        self.haul = fanfix.Haul()
        self.queued = self.settled_n = self.failed = self.present = self.drm = 0
        self.photos = self.videos = 0
        self.undated = 0
        self.from_page = self.page_videos = 0
        self.written: list[str] = []
        self.failures: list[dict] = []
        self.to_tag: list[str] = []
        self.to_upscale_tag: list[str] = []
        self.futures: list[concurrent.futures.Future] = []
        self.dests: dict[str, Path] = {}             # creator → folder
        self.records: dict[Path, social.Record] = {}
        self.already: dict[Path, set[str]] = {}
        self.done: dict[Path, set[str]] = {}
        self.counts: dict[Path, list[int]] = {}      # photos, videos written there (since the last save)
        self.handles: dict[Path, str] = {}
        self.captured = []
        self.kinds: dict[str, int] = {}              # answers read, by how they came (fetch, xhr, inline-rsc…)
        self.shown: dict[str, dict] = {}             # what the page showed, by address
        self.streamed = 0                            # most videos seen playing from a stream at once
        self.kept_chars = 0
        self.responses = 0
        self.idle = 0
        self.checking = 0
        self.last_state: dict = {}
        self.crawl_done = False
        self.exif = sc.ExifSession(self.exiftool) if self.exiftool else None
        self.heavy = threading.Lock()
        self.pool = concurrent.futures.ThreadPoolExecutor(max_workers=LANES, thread_name_prefix="fanfix-dl")
        self.fetch = fanfix.fetcher(self.ua, self.cookie_header(), self._browser_fetch)
        if self.opts.videos_1080:
            import video_tools
            threading.Thread(target=video_tools.available, daemon=True).start()
        self._log(f"Reading {url}" + (f" — creator {self.hint}" if self.hint else ""))
        self._say("Loading the page afresh…")
        # A fresh page: only what this page loads is read (a page reached inside the app keeps what came before).
        self.view.loadFinished.connect(self._reloaded)
        self.view.reload()

    def _reloaded(self, ok: bool) -> None:
        try:
            self.view.loadFinished.disconnect(self._reloaded)
        except (RuntimeError, TypeError):
            pass
        if not self.running:
            return
        if not ok:
            self._log("The page didn't load — reading what's there anyway.")
        self._say("Scrolling the page to its end and downloading what it shows…")
        QTimer.singleShot(TICK_MS, self._tick)

    def _tick(self) -> None:
        """One step: what the page loaded since the last step taken and read, what it shows noted, then the page
        scrolled on."""
        if not self.running or self.crawl_done:
            return
        self.view.page().runJavaScript(fanfix.DRAIN_JS, 0, self._drained)

    def _drained(self, raw) -> None:
        if not self.running:
            return
        got = self._read_answers(raw)
        if self.stopping:
            self._crawl_end()
            return
        if (time.monotonic() - self.page_started) / 60 > MAX_MINUTES:
            self._log(f"Still going on this page after {MAX_MINUTES} minutes — moving on.")
            self._end_of_page()
            return
        scroll = fanfix.scroll_js(self.direction)
        self.view.page().runJavaScript(fanfix.DOM_JS, 0, lambda r: (
            self._harvest(r), self.view.page().runJavaScript(scroll, 0, lambda s: self._scrolled(s, got))))

    def _read_answers(self, raw) -> int:
        """Reads the answers the page received (fanfix.extract_text) and queues what's new. Returns how many."""
        try:
            answers = json.loads(raw) if isinstance(raw, str) else []
        except ValueError:
            answers = []
        if not isinstance(answers, list):
            return 0
        for a in answers:
            if not isinstance(a, dict) or not isinstance(a.get("t"), str):
                continue
            self.responses += 1
            kind = str(a.get("k") or "?")
            self.kinds[kind] = self.kinds.get(kind, 0) + 1
            if self.kept_chars + len(a["t"]) <= KEEP_CHARS:
                entry = {"url": a.get("u", ""), "how": kind, "body": a["t"]}
                for k, name in (("m", "method"), ("b", "request_body"), ("a", "next_action")):
                    if a.get(k):
                        entry[name] = a[k]
                self.captured.append(entry)
                self.kept_chars += len(a["t"])
            before = set(self.haul.found)
            fanfix.extract_text(a["t"], self.haul)
            for key in set(self.haul.found) - before:
                self._queue(self.haul.found[key])
        return len(answers)

    def _harvest(self, raw) -> None:
        """What the page shows now, noted (taken at the end for what its data didn't name)."""
        try:
            got = json.loads(raw) if isinstance(raw, str) else {}
        except ValueError:
            got = {}
        if not isinstance(got, dict):
            return
        for m in got.get("media") or []:
            if isinstance(m, dict) and isinstance(m.get("src"), str):
                old = self.shown.get(m["src"])
                if old is None or (m.get("creator") and not old.get("creator")):
                    self.shown[m["src"]] = m
        self.streamed = max(self.streamed, int(got.get("streamed") or 0))

    def _scrolled(self, raw, got: int) -> None:
        if not self.running:
            return
        try:
            state = json.loads(raw) if isinstance(raw, str) else {}
        except ValueError:
            state = {}
        title, url = str(state.get("title") or ""), str(state.get("url") or "")
        if title.lower().startswith("just a moment") or "challenges.cloudflare.com" in url:
            self.checking += 1
            if self.checking * TICK_MS / 60000 > CHECK_MINUTES:
                self._finish("Cloudflare's check didn't finish — answer it in the page below, then press Download again.")
                return
            self._say("Cloudflare is checking the browser — answer its check in the page below if it asks; the run "
                      "goes on by itself after.")
            QTimer.singleShot(TICK_MS, self._tick)
            return
        if "/login" in url.split("?", 1)[0] and not self.haul.found:
            self._finish("Fanfix asked to log in — log in in the page below, open the page again, and press Download.")
            return
        grew = state.get("height") != self.last_state.get("height") or bool(state.get("moved"))
        self.last_state = state
        self.idle = 0 if (grew or got) else self.idle + 1
        if state and not state.get("hooked"):
            self._log("The page wasn't being watched — loading it again.")
            self.view.loadFinished.connect(self._reloaded)
            self.view.reload()
            return
        where = "Reading the chat's history (scrolling up)" if self.direction < 0 else "Scrolling"
        self._say(f"{where}… {self.responses} answer(s) read · {len(self.haul.found)} photo(s)/video(s) found · "
                  f"{len(self.written)} downloaded" + (f" · {self.haul.locked} locked" if self.haul.locked else "")
                  + (f" · {len(self.haul.drm)} DRM-protected" if self.haul.drm else "")
                  + (f" · chat {self.chats_read + 1} of {self.chats_read + 1 + len(self.pages)}" if self.chats_listed else ""))
        # the top of a chat's history (Fanfix says there's nothing older) needs only a moment more
        limit = 2 if self.direction < 0 and self.haul.older is False else IDLE_TICKS
        if self.idle >= limit:
            self._end_of_page()
            return
        QTimer.singleShot(TICK_MS, self._tick)

    def _end_of_page(self) -> None:
        """One last look at what came in and what's shown, then on to the next page (or the end)."""
        self.view.page().runJavaScript(fanfix.DRAIN_JS, 0, lambda r: (
            self._read_answers(r),
            self.view.page().runJavaScript(fanfix.DOM_JS, 0, lambda d: (self._harvest(d), self._page_done()))))

    def _page_done(self) -> None:
        if not self.running:
            return
        here = self.view.url().toString()
        if not self.hint and fanfix.chat_id(here):
            self.hint = self.haul.channels.get(fanfix.chat_id(here), "")
        new = fanfix.from_page(list(self.shown.values()), self.haul, self.hint)
        self.from_page += len(new)
        self.page_videos += sum(f.video for f in new)
        before = self.queued
        for f in new:
            self._queue(f)
        if self.queued > before:
            self._log(f"{self.queued - before} photo(s)/video(s) on the page that its data didn't name — taking them "
                      "as shown.")
        self.shown = {}
        if fanfix.chat_id(here):
            self.chats_read += 1
        if self.all_chats and not self.chats_listed:
            self.chats_listed = True
            self.pages = [(fanfix.chat_url(cid), name) for cid, name in self.haul.channels.items()]
            self._log(f"{len(self.pages)} chat(s) in Messages — reading each one's whole history.")
        if self.pages and not self.stopping:
            url, hint = self.pages.pop(0)
            self._open_page(url, hint)
            return
        self._crawl_end()

    def _open_page(self, url: str, hint: str) -> None:
        self.hint = hint
        self.direction = -1 if fanfix.chat_id(url) else 1
        self.haul.older = None
        self.idle = self.checking = 0
        self.last_state = {}
        self.page_started = time.monotonic()
        self._log(f"→ chat with {hint}" if hint and fanfix.chat_id(url) else f"→ {url}")
        self.view.loadFinished.connect(self._reloaded)
        self.view.load(QUrl(url))

    def stop(self) -> None:
        if self.running:
            self.stopping = True
            for f in getattr(self, "futures", []):
                f.cancel()                                 # not started yet: left for the next run
            self._cancel_all()
            self._say("Stopping after the files in hand…")

    def closeEvent(self, event) -> None:  # noqa: N802 — Qt override
        if self.running:
            if QMessageBox.question(self, "Fanfix", "A download is running. Stop it and close?") \
                    != QMessageBox.StandardButton.Yes:
                event.ignore()
                return
            self.stopping = True
            self._finish("Stopped.")
        self.closed = True
        self._cancel_all()
        super().closeEvent(event)

    # ------------------------------------------------------------------ downloads
    def _folder_for(self, creator: str) -> Path:
        if creator not in self.dests:
            dest = fanfix.destination(self.person, creator)
            self.dests[creator] = dest
            if dest not in self.records:
                rec = fanfix.record(dest)
                self.records[dest] = rec
                self.already[dest] = rec.downloaded | fanfix.ids_on_disk(dest)
                self.done[dest] = set()
                self.counts[dest] = [0, 0]
                if creator:
                    self.handles[dest] = creator
                self._log(f"→ “{self._shown(dest)}” — {len(self.already[dest])} already here")
        return self.dests[creator]

    def _queue(self, f: fanfix.Found) -> None:
        if self.stopping:
            return
        dest = self._folder_for(f.creator or self.hint)
        if f.key in self.already[dest]:
            self.present += 1
            return
        self.already[dest].add(f.key)
        item = fanfix.item_for(f, dest)
        self.queued += 1
        self.bar.setRange(0, self.queued)
        fut = self.pool.submit(social.settle, item, [], self.opts, self.exif, self.engine, self.heavy, self.fetch)
        self.futures.append(fut)
        fut.add_done_callback(lambda done: self.bridge.call.emit(self._settled, done))

    def _settled(self, fut) -> None:
        if not self.running:
            return
        s: social.Settled | None = None
        if not fut.cancelled():
            try:
                s = fut.result()
            except Exception as e:  # noqa: BLE001
                self.failed += 1
                self._log(f"   FAILED: {type(e).__name__}: {e}")
        if s is not None:
            dest = s.item.folder
            if s.path:
                if not s.present:
                    self.written.append(s.path)
                    self.counts.setdefault(dest, [0, 0])[1 if s.item.video else 0] += 1
                    if s.item.video:
                        self.videos += 1
                    else:
                        self.photos += 1
                    if s.upscaled:
                        self.to_upscale_tag.append(s.path)
                    if not s.item.date:
                        self.undated += 1
                self.to_tag.append(s.path)
                self.done.setdefault(dest, set()).add(s.item.key)
            elif "DRM" in s.why:
                self.drm += 1
                self._log(f"   {s.item.filename}: {s.why}")
            elif s.why != "stopped":
                self.failed += 1
                self.failures.append({"file": s.item.filename, "url": s.item.url, "why": s.why})
                self._log(f"   couldn't download {s.item.filename}: {s.why}")
        self.settled_n += 1
        self.bar.setValue(self.settled_n)
        if len(self.to_tag) >= SAVE_EVERY:
            self._save()
        if self.crawl_done and self.settled_n >= self.queued:
            self._finish()

    def _save(self) -> None:
        """The records and the tags, so far."""
        if self.tags is not None and self.to_tag:
            try:
                self.tags.add(self.to_tag, [fanfix.TAG])
                if self.to_upscale_tag:
                    self.tags.add(self.to_upscale_tag, [social.UPSCALED_TAG])
            except OSError as e:
                self._log(f"Couldn't save the tags: {e}")
        self.to_tag, self.to_upscale_tag = [], []
        for dest, rec in self.records.items():
            done, (photos, videos) = self.done.get(dest, set()), self.counts.get(dest, [0, 0])
            if not done and not photos and not videos:
                continue
            try:
                rec.save(done, photos, videos, handle=self.handles.get(dest, ""))
                self.done[dest], self.counts[dest] = set(), [0, 0]
            except OSError as e:
                self._log(f"Couldn't save the record in “{dest.name}”: {e}")

    def _crawl_end(self) -> None:
        if self.crawl_done:
            return
        self.crawl_done = True
        if self.settled_n >= self.queued:
            self._finish()
        else:
            self._say(f"Found everything — {self.queued - self.settled_n} file(s) still downloading…")

    def _finish(self, problem: str = "") -> None:
        if not self.running:
            return
        self.running = False
        if getattr(self, "pool", None):
            self.pool.shutdown(wait=False, cancel_futures=True)
        self._cancel_all()
        self._save()
        if self.exif is not None:
            self.exif.close()
        who = f"Your {self.chats_read} chats" if self.chats_read > 1 else (self.hint or "Fanfix")
        h = self.haul
        # videos the data named with only a poster, less the videos the page itself showed and gave
        missing = max(0, len(h.unresolved - set(h.found)) - self.page_videos)
        if problem:
            line = problem
        elif not self.responses and not self.shown:
            line = ("The page loaded nothing to read and showed nothing to save — is it a creator's page, and are you "
                    "logged in? If you can see posts there, press Save Troubleshooting File and send it over.")
        elif not h.found:
            line = (f"{who}: nothing to download on this page" +
                    ("." if h.locked or h.drm else
                     ". If you can see posts here, press Save Troubleshooting File and send it over."))
        elif not self.written:
            line = f"{who}: nothing new" + (f" ({self.present} already here)" if self.present else "") + \
                   (f" · {self.failed} couldn't be downloaded" if self.failed else "") + "."
        else:
            line = (f"{who}: downloaded {self.photos} photo{'s' if self.photos != 1 else ''} and {self.videos} "
                    f"video{'s' if self.videos != 1 else ''}" + (f" · {self.failed} couldn't be" if self.failed else "")
                    + ".")
            if self.undated:
                line += (f" {self.undated} had no date on Fanfix — {'they keep' if self.undated != 1 else 'it keeps'} "
                         "the download date.")
        protected = len(h.drm) + self.drm
        if protected:
            line += (f" {protected} bought photo{'s' if protected != 1 else ''}/video{'s' if protected != 1 else ''} "
                     "Fanfix only delivers protected by DRM (FairPlay/Widevine) — Safe Finder doesn't break DRM, so "
                     f"{'those stay' if protected != 1 else 'that stays'} viewable on Fanfix only.")
        if h.locked:
            line += f" {h.locked} locked item{'s' if h.locked != 1 else ''} (not bought) left out."
        if missing:
            line += (f" {missing} video{'s' if missing != 1 else ''} came with no address (Fanfix gives it when "
                     "it plays) — play one and press Download again to see if it's taken.")
        if self.failed:
            line += " Save Troubleshooting File shows why."
        self._log(line)
        self._say(line)
        self.report = {
            "page": self.view.url().toString(), "creator": self.hint, "answers": self.responses, "by_kind": self.kinds,
            "found": len(h.found), "from_page": self.from_page, "locked": h.locked, "profile_pictures": h.profile,
            "videos_without_address": sorted(h.unresolved - set(h.found)), "streamed_videos_seen": self.streamed,
            "downloaded": len(self.written), "failed": self.failures, "drm_at_download": self.drm,
            "drm_protected": sorted(h.drm), "removed_by_moderation": h.removed, "own_uploads": h.own,
            "other": h.other, "chats": h.channels, "chats_read": self.chats_read, "present": self.present,
            "items": [{"key": f.key, "url": f.url, "video": f.video, "creator": f.creator, "date": f.date,
                       "post": f.post, "from_page": f.shown} for f in h.found.values()],
            "shown": list(self.shown.values()),
        }
        for w in (self.go_btn, self.photos_2x, self.videos_1080, self.field, *self.page_btns):
            w.setEnabled(True)
        self.ai.setEnabled(self.photos_2x.isChecked())
        self.trouble_btn.setEnabled(True)
        self.stop_btn.setEnabled(False)
        self.bar.setVisible(False)
        self.finished.emit(str(self.person), list(self.written))
        if not problem:
            QTimer.singleShot(0, self._offer_cleanup)

    # ------------------------------------------------------------------ an earlier version's mistakes
    def _offer_cleanup(self) -> None:
        """An earlier version saved creators' profile pictures as if they were posts (named by the chat or the
        picture). The ones it recorded as downloads, whose names match a picture seen in this run, are offered for
        the Trash — after asking; folders it made for them alone go too."""
        keys = getattr(self, "haul", fanfix.Haul()).avatar_keys
        if not keys:
            return
        folders = [self.person]
        try:
            folders += [Path(e.path) for e in os.scandir(self.person)
                        if e.is_dir() and (Path(e.path) / fanfix.RECORD).is_file()]
        except OSError:
            pass
        hits: list[str] = []
        for folder in folders:
            rec = fanfix.record(folder)
            if not rec.downloaded:
                continue
            try:
                entries = list(os.scandir(folder))
            except OSError:
                continue
            for e in entries:
                stem = e.name.rsplit(".", 1)[0]
                if e.is_file() and not e.name.startswith(".") and stem in keys and stem in rec.downloaded:
                    hits.append(e.path)
        if not hits:
            return
        empty = []
        for folder in folders[1:]:
            left = [n for n in os.listdir(folder) if not n.startswith(".") and str(folder / n) not in hits]
            if not left:
                empty.append(str(folder))
        names = "\n".join(sorted(self._shown(Path(p)) for p in hits)[:12]) + ("\n…" if len(hits) > 12 else "")
        box = QMessageBox(self)
        box.setWindowTitle("Fanfix")
        box.setIcon(QMessageBox.Icon.Question)
        box.setText(f"{len(hits)} file{'s' if len(hits) != 1 else ''} here {'are' if len(hits) != 1 else 'is'} "
                    "creators' profile pictures that an earlier version downloaded by mistake. Move "
                    f"{'them' if len(hits) != 1 else 'it'} to the Trash?")
        box.setInformativeText(names + (f"\n\nAnd {len(empty)} folder{'s' if len(empty) != 1 else ''} made only for "
                                        f"them: " + ", ".join(Path(f).name for f in empty) if empty else ""))
        go = box.addButton("Move to Trash", QMessageBox.ButtonRole.DestructiveRole)
        box.addButton("Keep Them", QMessageBox.ButtonRole.RejectRole)
        box.exec()
        if box.clickedButton() is not go:
            return
        gone = [p for p in hits + empty if _trash(p)]
        if self.tags is not None and gone:
            try:
                self.tags.forget(gone)
            except (OSError, AttributeError):
                pass
        self._log(f"Moved {len(gone)} mistaken profile picture file(s)/folder(s) to the Trash.")
        if gone:
            self.finished.emit(str(self.person), [])

    # ------------------------------------------------------------------ troubleshooting
    def save_troubleshooting(self) -> None:
        """The last run — what the page loaded and showed, what was found, what failed — to ~/Library/Logs/Safe
        Finder. It holds addresses from the person's own account: it stays on this Mac."""
        folder = Path.home() / "Library" / "Logs" / "Safe Finder"
        try:
            folder.mkdir(parents=True, exist_ok=True)
            path = folder / f"fanfix-{time.strftime('%Y%m%d-%H%M%S')}.json"
            doc = dict(self.report or {"page": self.view.url().toString()})
            doc["log"] = self.log.toPlainText().splitlines()
            doc["answers_received"] = self.captured
            path.write_text(json.dumps(doc, ensure_ascii=False, indent=1), encoding="utf-8")
        except OSError as e:
            QMessageBox.warning(self, "Fanfix", f"Couldn't write the file: {e}")
            return
        self._log(f"Saved {path} — it holds what this page loaded from your account; it stays on this Mac.")


def main() -> None:
    if len(sys.argv) < 2:
        sys.exit("usage: fanfix_downloader.py <folder> [creator]")
    app = QApplication(sys.argv[:1])
    win = FanfixWindow(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else "")
    win.show()
    sys.exit(app.exec())


if __name__ == "__main__":
    main()
