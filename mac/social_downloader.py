#!/usr/bin/env python3
"""Safe Finder ▸ "Download Instagram Profile…" / "Download Facebook Profile…" — the window (instagram.py and
facebook.py read the sites, social.py downloads).

    python3 mac/social_downloader.py instagram "/Volumes/SSD/Jane" [handle]
    python3 mac/social_downloader.py facebook "/Volumes/SSD/Jane" [profile link]

The window is a real Chromium (Qt WebEngine) with its own lasting profile: log in to Instagram or Facebook
there once (and answer "is this you?" there if it asks). A run then reads the site *from inside that
logged-in browser* — every API call or page is a `fetch()` from a hidden page on the site's own origin,
exactly what the site's own pages send — so it sees what the person sees, private profiles they follow
included. It never fills in a login or answers a check itself.

What the run finds goes straight to the downloads (four at a time, on worker threads — `social.settle`:
fetched, upscaled when asked, the post's date/place/caption written in, placed in the profile's folder
under the iPhone app's names). Each file is tagged "instagram" or "facebook" in the shared tag store (and
"upscaled" when it was), and the profile's shared record (`.instagram.json` / `.facebook.json`) gets the
post ids as they're done — so the iPhone app never downloads them again, and this window doesn't download
what the iPhone already has (its ids in the record, and the post ids in the folder's file names).

Qt calls back rather than blocking, so a run is a generator (instagram.run / facebook.run): it yields a
request — an API call or page, a pause, items for the downloads — and `_Runner` resumes it with the answer.
"""
from __future__ import annotations

import concurrent.futures
import itertools
import os
import shutil
import sys
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from PySide6.QtCore import QObject, QSettings, Qt, QTimer, QUrl, Signal  # noqa: E402
from PySide6.QtWidgets import (QApplication, QCheckBox, QHBoxLayout, QLabel, QLineEdit, QMainWindow,  # noqa: E402
                               QMessageBox, QPlainTextEdit, QProgressBar, QPushButton, QVBoxLayout, QWidget)
from PySide6.QtWebEngineCore import QWebEnginePage, QWebEngineProfile  # noqa: E402
from PySide6.QtWebEngineWidgets import QWebEngineView  # noqa: E402

import facebook as fb  # noqa: E402
import instagram as ig  # noqa: E402
import simpcity as sc  # noqa: E402
import social  # noqa: E402

LANES = 4                     # files downloaded at once
SAVE_EVERY = 25               # the record is saved (and the files tagged) after this many files
CALL_TIMEOUT = 75.0           # seconds an API call / page read may take in the browser
SMALL_PHOTO = 200 * 1024      # Facebook: photos under this are always upscaled 2×

KINDS = {
    "instagram": dict(module=ig, name="Instagram", home=ig.HOME, robots=ig.ROBOTS, login_cookie="sessionid",
                      domain="instagram.com", referer="https://www.instagram.com/", field="@handle or profile link",
                      login="https://www.instagram.com/accounts/login/"),
    "facebook": dict(module=fb, name="Facebook", home=fb.HOST, robots=fb.ROBOTS, login_cookie="c_user",
                     domain="facebook.com", referer="https://www.facebook.com/", field="profile link",
                     login="https://www.facebook.com/login/"),
}

_PROFILE: QWebEngineProfile | None = None


def profile() -> QWebEngineProfile:
    """One lasting browser profile for both sites: the logins survive restarts."""
    global _PROFILE
    if _PROFILE is None:
        _PROFILE = QWebEngineProfile("social", QApplication.instance())
        _PROFILE.setPersistentCookiesPolicy(QWebEngineProfile.PersistentCookiesPolicy.ForcePersistentCookies)
    return _PROFILE


class _Bridge(QObject):
    call = Signal(object, object)      # (callback, value) from a worker thread → back on the GUI thread


class _Runner:
    """Drives one generator: each request it yields is carried out by `window.handle`, which calls back
    with the answer; `on_end(error, returned)` runs when the generator finishes (or raises)."""

    def __init__(self, window: "SocialWindow", gen, on_end) -> None:
        self.w, self.gen, self.on_end = window, gen, on_end

    def start(self) -> None:
        self.step(None)

    def step(self, value) -> None:
        try:
            req = self.gen.send(value)
        except StopIteration as stop:
            self.on_end(None, stop.value)
            return
        except Exception as e:  # noqa: BLE001 — a bug or a drive error must end the run, not hang it
            self.on_end(e, None)
            return
        self.w.handle(req, self.step)


class SocialWindow(QMainWindow):
    """The downloader for one kind ("instagram" / "facebook") from one folder (the one right-clicked)."""

    finished = Signal(str, list)       # (the profile's folder, files written) — Safe Finder refreshes + tags

    def __init__(self, kind: str, folder: str, start: str = "", tags=None, parent=None) -> None:
        super().__init__(parent)
        self.kind = kind
        self.k = KINDS[kind]
        self.mod = self.k["module"]
        self.person = Path(folder)
        self.tags = tags
        self.running = self.stopping = False
        self.cookies: dict[str, dict[str, str]] = {}
        self.calls = itertools.count(1)
        self.bridge = _Bridge()
        self.bridge.call.connect(lambda cb, value: cb(value))
        self.settings = QSettings("PhotoBrowser", "SafeFinder")
        self.exiftool = sc.find_exiftool()
        self.setWindowTitle(f"{self.k['name']} — {self.person.name}")
        self.resize(1100, 860)

        prof = profile()
        self.ua = prof.httpUserAgent() or social.UA
        store = prof.cookieStore()
        store.cookieAdded.connect(self._cookie_added)
        store.loadAllCookies()
        self.view = QWebEngineView()
        self.view.setPage(QWebEnginePage(prof, self.view))
        self.api = QWebEnginePage(prof, self)          # hidden: the reads are made from it
        self.api_ready = False

        rec = self.mod.record(self.person)
        prefill = start or (rec.get("handle") if kind == "instagram" else rec.get("profile_url")) or \
            str(self.settings.value(f"{kind}/last/{self.person}", "") or "")
        self.field = QLineEdit(prefill)
        self.field.setPlaceholderText(self.k["field"])
        self.go_btn = QPushButton("Get New Posts" if rec.exists else "Download")
        self.go_btn.setDefault(True)
        self.go_btn.clicked.connect(self.start)
        self.stop_btn = QPushButton("Stop")
        self.stop_btn.setEnabled(False)
        self.stop_btn.clicked.connect(self.stop)

        def option(text: str, key: str, default: bool, tip: str) -> QCheckBox:
            box = QCheckBox(text)
            box.setToolTip(tip)
            box.setChecked(str(self.settings.value(f"{kind}/{key}", "true" if default else "false")) == "true")
            box.toggled.connect(lambda on: self.settings.setValue(f"{kind}/{key}", "true" if on else "false"))
            return box
        self.tagged = option("Tagged posts", "tagged", True, "Photos and videos the profile is tagged in")
        self.stories = option("Stories and highlights", "stories", True, "Current stories into “Stories”, each "
                              "highlight into its own folder")
        self.stories.setVisible(kind == "instagram")
        self.tagged.setVisible(kind == "instagram")     # Facebook: every tagged photo, always
        self.full = QCheckBox("Check every photo again")
        self.full.setToolTip("Read every uploaded and tagged photo, even where an earlier run already got to the "
                             "end — finds an old photo tagged since. Slower.")
        self.full.setVisible(kind == "facebook")
        self.photos_2x = option("Upscale photos 2×", "photos2x", False,
                                "Each photo twice the size, in place" +
                                (" (photos under 200 KB always are)" if kind == "facebook" else ""))
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
        self.ai.setEnabled(self._ai_usable())
        self.photos_2x.toggled.connect(lambda _on: self.ai.setEnabled(self._ai_usable()))
        login = QPushButton(f"Log In to {self.k['name']}")
        login.clicked.connect(lambda: self.view.load(QUrl(self.k["login"])))

        top = QHBoxLayout()
        top.addWidget(QLabel("Profile:"))
        top.addWidget(self.field, 1)
        top.addWidget(self.go_btn)
        top.addWidget(self.stop_btn)
        row2 = QHBoxLayout()
        for w in (self.tagged, self.stories, self.full, self.photos_2x, self.ai, self.videos_1080):
            row2.addWidget(w)
        row2.addStretch(1)
        row2.addWidget(login)
        self.status = QLabel(f"Log in to {self.k['name']} below if you haven't. Downloads go into a folder for the "
                             f"profile inside “{self.person.name}” (or into this folder, when it is the profile's), "
                             f"tagged “{self.mod.TAG}”.")
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
        self.view.load(QUrl(self.k["home"]))
        self.api.loadFinished.connect(self._api_loaded)
        self.api.load(QUrl(self.k["robots"]))
        if not self.exiftool:
            self._log("ExifTool isn't installed, so the post's date only goes on the file's dates, and no caption or "
                      "place goes into the files (install it with: brew install exiftool).")

    # ------------------------------------------------------------------ small helpers
    def _log(self, line: str) -> None:
        if line == getattr(self, "_last_line", None):
            return                                   # the same line twice in a row (a problem, then the summary)
        self._last_line = line
        self.log.appendPlainText(time.strftime("%H:%M:%S ") + line)

    def _say(self, line: str) -> None:
        self.status.setText(line)

    def _api_loaded(self, ok: bool) -> None:
        """The hidden page is ready once it's on the site itself — reads made from anywhere else are ones the
        browser refuses. A load that failed (the network) is tried again a few times."""
        self.api_ready = bool(ok) and self.api.url().host() == QUrl(self.k["robots"]).host()
        if not self.api_ready:
            self._api_tries = getattr(self, "_api_tries", 0) + 1
            if self._api_tries <= 5:
                QTimer.singleShot(3000, lambda: self.api.load(QUrl(self.k["robots"])))
            elif self._api_tries == 6:
                self._log(f"Couldn't open {self.k['robots']} — check the Mac's internet connection, then press "
                          "Download again.")

    def _cookie_added(self, cookie) -> None:
        domain = cookie.domain().lstrip(".")
        self.cookies.setdefault(domain, {})[cookie.name().data().decode("latin-1")] = \
            cookie.value().data().decode("latin-1")

    def cookie_header(self) -> str:
        pairs: dict[str, str] = {}
        for domain, jar in self.cookies.items():
            if domain == self.k["domain"] or domain.endswith("." + self.k["domain"]):
                pairs.update(jar)
        return "; ".join(f"{k}={v}" for k, v in pairs.items())

    def logged_in(self) -> bool:
        return any(jar.get(self.k["login_cookie"]) for d, jar in self.cookies.items()
                   if d == self.k["domain"] or d.endswith("." + self.k["domain"]))

    # ------------------------------------------------------------------ run / stop
    def start(self) -> None:
        if self.running:
            return
        text = self.field.text().strip()
        if self.kind == "instagram":
            text = ig.clean_handle(text)
        elif text:
            text = fb.start_url(text)                   # shown as it's read: https://www.facebook.com/…
        if not text:
            QMessageBox.information(self, self.k["name"], f"Type the {self.k['field']} to download.")
            return
        self.field.setText(text)
        self.settings.setValue(f"{self.kind}/last/{self.person}", text)
        self.running, self.stopping = True, False
        fbk = self.kind == "facebook"
        self.opts = social.Options(photos_2x=self.photos_2x.isChecked(),
                                   ai=self.ai.isChecked() and self.engine is not None and self._ai_usable(),
                                   videos_1080=self.videos_1080.isChecked(), tagged=self.tagged.isChecked() or fbk,
                                   stories=self.stories.isChecked(), upscale_under=SMALL_PHOTO if fbk else 0,
                                   full=fbk and self.full.isChecked())
        for w in (self.go_btn, self.tagged, self.stories, self.full, self.photos_2x, self.ai, self.videos_1080, self.field):
            w.setEnabled(False)
        self.stop_btn.setEnabled(True)
        self.bar.setVisible(True)
        self.bar.setRange(0, 0)
        self.queued = self.settled_n = self.failed = self.present = 0
        self.small_n = self.undated = 0
        self.photos = self.videos = 0
        self.written: list[str] = []
        self.to_tag: list[str] = []
        self.to_upscale_tag: list[str] = []
        self.done_keys: set[str] = set()
        self.failed_keys: set[str] = set()
        self.key_left: dict[str, int] = {}            # a post's files still downloading (a carousel has several)
        self.futures: list[concurrent.futures.Future] = []
        self._saved_counts = (0, 0)
        self.dest: Path | None = None
        self.record: social.Record | None = None
        self.info: dict = {}
        self.crawl_done = False
        self.exif = sc.ExifSession(self.exiftool) if self.exiftool else None
        self.heavy = threading.Lock()
        self.pool = concurrent.futures.ThreadPoolExecutor(max_workers=LANES, thread_name_prefix=f"{self.kind}-dl")
        if self.opts.videos_1080 or self.kind == "instagram":
            import video_tools
            threading.Thread(target=lambda: (video_tools.available(), self.bridge.call.emit(self._video_note, None)),
                             daemon=True).start()
        if self.kind == "instagram":
            self.dest = ig.destination(self.person, text)
            self.record = ig.record(self.dest)
            already = self.record.downloaded | ig.ids_on_disk(self.dest)
            since = float(self.record.get("last_updated") or 0)
            self._log(f"@{text} → “{self._shown(self.dest)}” — {len(already)} post(s) already here")
            gen = ig.run(text, self.dest, already, self.opts, since, str(self.record.get("user_id") or ""))
        else:
            gen = fb.run(text, self.person, self._fb_already, self.opts)
        self._say(f"Reading {self.k['name']}…")
        self._when_ready(lambda: _Runner(self, gen, self._crawled).start())

    def _ai_usable(self) -> bool:
        """Real-ESRGAN applies when photos are upscaled: all of them (the box), or — on Facebook — always the
        small ones."""
        return self.kind == "facebook" or self.photos_2x.isChecked()

    def _walked(self, outcome) -> dict:
        """The record's `walked` after this run (facebook.py notes): a set walked to its end with every one
        of its photos in is marked; one cut short, or with a photo that didn't download, is cleared — the
        next run reads that whole set again. A run that never got going clears both."""
        old = self.record.get("walked") if self.record is not None else None
        walked = dict(old) if isinstance(old, dict) else {}
        if outcome is None:
            return {}
        for name, (finished, keys) in (getattr(outcome, "sets", None) or {}).items():
            if finished and keys <= self.done_keys:
                walked[name] = int(time.time())
            else:
                walked.pop(name, None)
        return walked

    def _video_note(self, _v) -> None:
        import video_tools
        if video_tools.note:
            self._log(video_tools.note)

    def _fb_already(self, folder: Path) -> set[str]:
        self.dest = folder
        self.record = fb.record(folder)
        ids = self.record.downloaded | fb.ids_on_disk(folder)
        self._log(f"→ “{self._shown(folder)}” — {len(ids)} photo(s)/video(s) already here")
        return ids

    def _shown(self, p: Path) -> str:
        try:
            return str(p.relative_to(self.person.parent))
        except ValueError:
            return str(p)

    def _when_ready(self, go) -> None:
        """Once the hidden page is on the site and there's a login (else the person is asked for one)."""
        waited = [0.0]
        asked = [False]

        def tick() -> None:
            if self.stopping:
                self._finish("Stopped.")
                return
            if self.api_ready and self.logged_in():
                if asked[0]:
                    self._log("Logged in — starting.")
                go()
                return
            if not asked[0] and waited[0] >= 3:
                asked[0] = True
                self.view.load(QUrl(self.k["login"]))
                self._say(f"Log in to {self.k['name']} in the window below — the download starts by itself once you have.")
                self._log(f"Waiting for a login to {self.k['name']}…")
            if waited[0] > 900:
                self._finish(f"No {self.k['name']} login after 15 minutes — press Download again once you've logged in.")
                return
            waited[0] += 0.5
            QTimer.singleShot(500, tick)
        tick()

    def stop(self) -> None:
        if self.running:
            self.stopping = True
            for f in getattr(self, "futures", []):
                f.cancel()                                 # not started yet: left for the next run
            self._say("Stopping after the files in hand…")

    def closeEvent(self, event) -> None:  # noqa: N802 — Qt override
        if self.running:
            if QMessageBox.question(self, self.k["name"], "A download is running. Stop it and close?") \
                    != QMessageBox.StandardButton.Yes:
                event.ignore()
                return
            self.stopping = True
        super().closeEvent(event)

    # ------------------------------------------------------------------ requests from the run
    def handle(self, req: tuple, cb) -> None:
        kind = req[0]
        if self.stopping and kind in ("api", "page", "emit"):
            self.crawl_done = True                     # Stop: no more reading; what's downloading finishes
            self._after_crawl()
            return
        if kind == "api":
            url, form, app_id = req[1], req[2], req[3]
            start, result = ig.api_js(f"c{next(self.calls)}", url, form, app_id)
            self._call(start, result, lambda r: cb((int(r.get("status") or 0), r.get("body") or "")))
        elif kind == "page":
            start, result = fb.page_js(f"p{next(self.calls)}", req[1])
            self._call(start, result, lambda r: cb((int(r.get("status") or 0), r.get("body") or "",
                                                    r.get("url") or req[1])))
        elif kind == "sleep":
            QTimer.singleShot(int(max(0.0, float(req[1])) * 1000), lambda: cb(None))
        elif kind == "note":
            self._log(req[1])
            cb(None)
        elif kind == "emit":
            for item in req[1]:
                self._queue(item)
            cb(None)
        elif kind == "profile":
            self._profile(req[1])
            cb(None)
        else:
            raise ValueError(kind)

    def _call(self, start_js: str, result_js: str, done) -> None:
        """Runs `start_js` (a fetch) on the hidden page and polls `result_js` until it answers."""
        began = time.monotonic()

        def poll() -> None:
            self.api.runJavaScript(result_js, 0, got)

        def got(raw) -> None:
            if raw:
                import json
                try:
                    r = json.loads(raw) if isinstance(raw, str) else {}
                except ValueError:
                    r = {}
                done(r if isinstance(r, dict) else {})
                return
            if time.monotonic() - began > CALL_TIMEOUT:
                done({"status": 0, "body": "no answer"})
                return
            QTimer.singleShot(150, poll)

        self.api.runJavaScript(start_js, 0, lambda _ok: QTimer.singleShot(100, poll))

    def _profile(self, value) -> None:
        if self.kind == "instagram":
            p: ig.Profile = value
            self.info = dict(handle=p.handle, user_id=p.user_id, full_name=p.full_name)
            self.private = p.private
            self._log(f"@{p.handle} — {p.full_name or 'no name'}, {p.posts or '?'} posts"
                      + (" (private)" if p.private else ""))
        else:
            p, folder = value
            self.info = dict(profile_name=p.name, profile_id=p.id, profile_url=p.url)
            self.private = True
            self._log(f"{p.name} (id {p.id})")
        self.setWindowTitle(f"{self.k['name']} — {self.info.get('handle') or self.info.get('profile_name')}")

    # ------------------------------------------------------------------ downloads
    def _tries(self) -> list[dict[str, str]]:
        anon = social.headers(self.k["referer"], ua=self.ua)
        cookie = self.cookie_header()
        return [anon, social.headers(self.k["referer"], cookie, self.ua)] if cookie else [anon]

    def _queue(self, item: social.Item) -> None:
        self.queued += 1
        self.key_left[item.key] = self.key_left.get(item.key, 0) + 1
        self.bar.setRange(0, self.queued)
        fut = self.pool.submit(social.settle, item, self._tries(), self.opts, self.exif, self.engine, self.heavy)
        self.futures.append(fut)
        fut.add_done_callback(lambda f: self.bridge.call.emit(self._settled, f))

    def _settled(self, fut) -> None:
        s: social.Settled | None = None
        if not fut.cancelled():                        # a cancelled one is left for the next run (Stop)
            try:
                s = fut.result()
            except Exception as e:  # noqa: BLE001
                self.failed += 1
                self._log(f"   FAILED: {type(e).__name__}: {e}")
        if s is not None:
            self.key_left[s.item.key] = self.key_left.get(s.item.key, 1) - 1
            if s.path:
                if s.present:
                    self.present += 1
                else:
                    self.written.append(s.path)
                    if s.item.video:
                        self.videos += 1
                    else:
                        self.photos += 1
                    if s.upscaled:
                        self.to_upscale_tag.append(s.path)
                    if s.small:
                        self.small_n += 1
                    if not s.item.date:
                        self.undated += 1
                self.to_tag.append(s.path)
                self.done_keys.add(s.item.key)
            else:
                self.failed += 1
                self.failed_keys.add(s.item.key)
                self._log(f"   couldn't download {s.item.filename}: {s.why}")
        self.settled_n += 1
        self.bar.setValue(self.settled_n)
        self._say(f"Downloaded {len(self.written)} of {self.queued} found" +
                  (f" · {self.failed} failed" if self.failed else "") +
                  ("" if self.crawl_done else " · still looking…"))
        if len(self.to_tag) >= SAVE_EVERY:
            self._save()
        if self.crawl_done and self.settled_n >= self.queued:
            self._finish()

    def _save(self) -> None:
        """The record and the tags, so far."""
        if self.tags is not None and self.to_tag:
            try:
                self.tags.add(self.to_tag, [self.mod.TAG])
                if self.to_upscale_tag:
                    self.tags.add(self.to_upscale_tag, [social.UPSCALED_TAG])
            except OSError as e:
                self._log(f"Couldn't save the tags: {e}")
        self.to_tag, self.to_upscale_tag = [], []
        if self.record is not None and (self.done_keys or self.info):
            # A post is done once every file of it is in (a carousel's last item may still be downloading).
            done = {k for k in self.done_keys if self.key_left.get(k, 0) <= 0} - self.failed_keys
            try:
                self.record.save(done, self.photos - self._saved_counts[0],
                                 self.videos - self._saved_counts[1], **self.info)
                self._saved_counts = (self.photos, self.videos)
            except OSError as e:
                self._log(f"Couldn't save the record: {e}")

    def _crawled(self, error, outcome) -> None:
        self.crawl_done = True
        if error is not None:
            self._log(f"Stopped: {type(error).__name__}: {error}")
        self.outcome = outcome
        if outcome is not None and outcome.problem:
            self._log(outcome.problem)
        self._after_crawl()

    def _after_crawl(self) -> None:
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
        outcome = getattr(self, "outcome", None)
        if self.kind == "facebook" and self.record is not None:
            self.info["walked"] = self._walked(outcome)
        self._save()
        if self.exif is not None:
            self.exif.close()
        name = self.info.get("handle") and f"@{self.info['handle']}" or self.info.get("profile_name") or self.field.text()
        if problem:
            line = problem
        elif outcome is not None and outcome.profile is None:
            line = outcome.problem or f"Couldn’t open {name}."
        elif not self.written:
            line = (outcome.problem if outcome is not None and outcome.problem else f"{name}: nothing new.")
        else:
            line = f"{name}: downloaded {self.photos} photo{'s' if self.photos != 1 else ''} and {self.videos} " \
                   f"video{'s' if self.videos != 1 else ''}" + (f" · {self.failed} couldn't be" if self.failed else "") + "."
            if self.small_n:
                line += f" {self.small_n} small photo{'s' if self.small_n != 1 else ''} (under 200 KB) upscaled 2×."
            if self.undated:
                line += (f" {self.undated} had no upload date on {self.k['name']}'s page — "
                         f"{'they keep' if self.undated != 1 else 'it keeps'} the download date.")
        self._log(line)
        self._say(line)
        for w in (self.go_btn, self.tagged, self.stories, self.full, self.photos_2x, self.videos_1080, self.field):
            w.setEnabled(True)
        self.ai.setEnabled(self._ai_usable())
        self.stop_btn.setEnabled(False)
        self.bar.setVisible(False)
        if self.record is not None and self.record.exists:
            self.go_btn.setText("Get New Posts")
        self.finished.emit(str(self.dest or self.person), list(self.written))


def main() -> None:
    if len(sys.argv) < 3 or sys.argv[1] not in KINDS:
        sys.exit("usage: social_downloader.py instagram|facebook <folder> [handle or link]")
    app = QApplication(sys.argv[:1])
    win = SocialWindow(sys.argv[1], sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else "")
    win.show()
    sys.exit(app.exec())


if __name__ == "__main__":
    main()
