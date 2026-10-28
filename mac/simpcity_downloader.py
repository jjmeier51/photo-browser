#!/usr/bin/env python3
"""Safe Finder ▸ "Download from SimpCity…" — the window (the rest is simpcity.py).

    python3 mac/simpcity_downloader.py "/Volumes/SSD/Helen Owen" [thread-url]

Opens a browser window on the thread. Both sites check that a real browser is asking (DDoS-Guard on
simpcity.cr, Cloudflare on goonbox.cr), and SimpCity shows links only to members — so the window is a
real Chromium (Qt WebEngine) with its own persistent profile: log in to SimpCity there once, and if a
site asks "are you human?", answer it there; the download carries on by itself.

A run reads every page of the thread (or, for a thread read before, from the last page it reached),
collects each goonbox.cr image and turbo.cr video with the date of the post it came from, skips what the
shared record (`<person>/simpcity/.simpcity.json`, also used by the iPhone app) says is done, then
resolves each one to its full-size file (goonbox's own API, `simpcity.GOONBOX_API_START_JS`; for turbo
the file its player loads) and downloads it with Chromium itself — three at a time, each in
its own hidden page. A download lands in the Mac's temp folder, gets its date (its own capture date if it
has one, else the post's — see `simpcity.apply_date`), then moves into `<person>/simpcity` as
`<id>.<ext>` and is tagged "simpcity" in the shared tag store. The record is saved as it goes, so a
stopped run resumes where it was.

Qt calls back rather than blocking, so each run is a generator: it yields a request ("read this page",
"resolve this link", "download this", "do this on a thread") and `_Runner` resumes it with the answer.
"""
from __future__ import annotations

import os
import shutil
import sys
import tempfile
import threading
import time
import urllib.request
from collections import deque
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from PySide6.QtCore import QObject, Qt, QTimer, QUrl, Signal  # noqa: E402
from PySide6.QtWidgets import (QApplication, QCheckBox, QHBoxLayout, QLabel, QLineEdit, QMainWindow,  # noqa: E402
                               QMessageBox, QPlainTextEdit, QProgressBar, QPushButton, QVBoxLayout, QWidget)
from PySide6.QtWebEngineCore import (QWebEngineDownloadRequest, QWebEnginePage, QWebEngineProfile,  # noqa: E402
                                     QWebEngineSettings)
from PySide6.QtWebEngineWidgets import QWebEngineView  # noqa: E402

import simpcity as sc  # noqa: E402

LANES = 3                 # files resolved + downloaded at once
HOME = "https://simpcity.cr/"
LOGIN = "https://simpcity.cr/login/"

_PROFILE: QWebEngineProfile | None = None


def profile() -> QWebEngineProfile:
    """One persistent browser profile: the SimpCity login and the sites' "you're human" cookies
    survive restarts. Parented to the app so it outlives every page."""
    global _PROFILE
    if _PROFILE is None:
        _PROFILE = QWebEngineProfile("simpcity", QApplication.instance())
        _PROFILE.setPersistentCookiesPolicy(QWebEngineProfile.PersistentCookiesPolicy.ForcePersistentCookies)
    return _PROFILE


class _Bridge(QObject):
    done = Signal(object, object)      # (callback, result) from a worker thread → back on the GUI thread


class _Runner:
    """Drives one generator: each request it yields is carried out by `window.handle`, which calls back
    with the answer; `on_end(error, returned)` runs when the generator finishes (or raises)."""

    def __init__(self, window: "SimpCityWindow", gen, on_end) -> None:
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


class SimpCityWindow(QMainWindow):
    """The downloader window for one person folder."""

    finished = Signal(str, list)       # (simpcity folder, files written) — Safe Finder refreshes + tags

    def __init__(self, person: str, thread: str | None = None, tags=None, parent=None) -> None:
        super().__init__(parent)
        self.person = Path(person)
        self.dest = self.person / sc.FOLDER
        self.tags = tags
        self.exiftool = sc.find_exiftool()
        self.running = False
        self.stopping = False
        self.pending: dict[str, object] = {}        # download file name → callback
        self.cookies: dict[str, dict[str, str]] = {}
        self.bridge = _Bridge()
        self.bridge.done.connect(lambda cb, result: cb(result))
        self.tmp = Path(tempfile.mkdtemp(prefix="simpcity-"))
        self.setWindowTitle(f"SimpCity — {self.person.name}")
        self.resize(1180, 900)

        prof = profile()
        prof.downloadRequested.connect(self._download_requested)
        store = prof.cookieStore()
        store.cookieAdded.connect(self._cookie_added)
        store.loadAllCookies()

        self.view = QWebEngineView()
        self.view.setPage(QWebEnginePage(prof, self.view))
        # The download lanes: their own hidden pages, so a check shown in the window never swaps a page
        # under one. turbo's player loads its video only once it plays (muted), so autoplay is allowed.
        self.lanes = [QWebEnginePage(prof, self) for _ in range(LANES)]
        for lane in self.lanes:
            lane.settings().setAttribute(QWebEngineSettings.WebAttribute.PlaybackRequiresUserGesture, False)

        rec = sc.Record.load(self.dest) if self.dest.is_dir() else None
        self.address = QLineEdit(thread or (rec.last_thread() if rec else "") or "")
        self.address.setPlaceholderText("https://simpcity.cr/threads/…")
        self.go_btn = QPushButton("Get New" if rec and rec.threads else "Download")
        self.go_btn.setDefault(True)
        self.go_btn.clicked.connect(self.start)
        self.stop_btn = QPushButton("Stop")
        self.stop_btn.setEnabled(False)
        self.stop_btn.clicked.connect(self.stop)
        self.full = QCheckBox("Read every page again")
        self.full.setToolTip("Normally a thread read before is picked up from the last page it reached.")
        login = QPushButton("Log In to SimpCity")
        login.clicked.connect(lambda: self.view.load(QUrl(LOGIN)))
        back = QPushButton("Back")
        back.clicked.connect(self.view.back)

        top = QHBoxLayout()
        top.addWidget(QLabel("Thread:"))
        top.addWidget(self.address, 1)
        top.addWidget(self.go_btn)
        top.addWidget(self.stop_btn)
        row2 = QHBoxLayout()
        row2.addWidget(self.full)
        row2.addStretch(1)
        row2.addWidget(back)
        row2.addWidget(login)
        self.status = QLabel(f"Saves into “{self.person.name}/{sc.FOLDER}”. Log in to SimpCity below if you haven't; "
                             "if a site asks whether you're human, answer it below — the download carries on by itself.")
        self.status.setWordWrap(True)
        self.bar = QProgressBar()
        self.bar.setVisible(False)
        self.log = QPlainTextEdit()
        self.log.setReadOnly(True)
        self.log.setMaximumHeight(130)

        box = QWidget()
        lay = QVBoxLayout(box)
        lay.addLayout(top)
        lay.addLayout(row2)
        lay.addWidget(self.status)
        lay.addWidget(self.bar)
        lay.addWidget(self.view, 1)
        lay.addWidget(self.log)
        self.setCentralWidget(box)
        self.view.load(QUrl(sc.thread_base(self.address.text()) or HOME))
        if not self.exiftool:
            self._log("ExifTool isn't installed, so a file without its own date only gets the post's date as its "
                      "file date (install it with: brew install exiftool).")

    # ------------------------------------------------------------------ small helpers
    def _log(self, line: str) -> None:
        self.log.appendPlainText(time.strftime("%H:%M:%S ") + line)

    def _say(self, line: str) -> None:
        self.status.setText(line)

    def _cookie_added(self, cookie) -> None:
        domain = cookie.domain().lstrip(".")
        self.cookies.setdefault(domain, {})[cookie.name().data().decode("latin-1")] = cookie.value().data().decode("latin-1")

    def _cookie_header(self, host: str) -> str:
        pairs: dict[str, str] = {}
        for domain, jar in self.cookies.items():
            if host == domain or host.endswith("." + domain):
                pairs.update(jar)
        return "; ".join(f"{k}={v}" for k, v in pairs.items())

    # ------------------------------------------------------------------ run / stop
    def start(self) -> None:
        if self.running:
            return
        base = sc.thread_base(self.address.text())
        if not base:
            QMessageBox.information(self, "SimpCity", "Paste a SimpCity thread address, like\n"
                                    "https://simpcity.cr/threads/helen-owen-ig-helenowen.64622/")
            return
        self.address.setText(base)
        self.running, self.stopping = True, False
        self.go_btn.setEnabled(False)
        self.stop_btn.setEnabled(True)
        self.bar.setVisible(True)
        self.bar.setRange(0, 0)
        self.written: list[str] = []
        self.untagged: list[str] = []
        self.failed = self.processed = 0
        self.kept = self.post_dated = 0
        _Runner(self, self._crawl(base, self.full.isChecked()), self._crawled).start()

    def stop(self) -> None:
        if self.running:
            self.stopping = True
            self._say("Stopping after the files in hand…")

    def closeEvent(self, event) -> None:  # noqa: N802 — Qt override
        if self.running:
            if QMessageBox.question(self, "SimpCity", "A download is running. Stop it and close?") \
                    != QMessageBox.StandardButton.Yes:
                event.ignore()
                return
            self.stopping = True
        else:
            shutil.rmtree(self.tmp, ignore_errors=True)
        super().closeEvent(event)

    # ------------------------------------------------------------------ the run
    def _crawl(self, base: str, full: bool):
        """Reads the thread's pages, then works out what's left to download."""
        sc.make_folder(self.dest)
        self.record = sc.Record.load(self.dest)
        first = 1 if full else self.record.start_page(base)
        items: dict[str, sc.Item] = {}
        n, last, title = first, first, ""
        asked_login = False
        while n <= last and not self.stopping:
            self._say(f"Reading page {n}{f' of {last}' if last > n else ''}… {len(items):,} files found so far.")
            page = yield ("read", sc.page_url(base, n), n)
            if not page:
                raise RuntimeError(f"Couldn't read page {n} of the thread — check the address, then try again.")
            found = sum(1 for p in page.get("posts") or [] for u in p.get("urls") or [] if sc.media_key(str(u)))
            if n == first and not found and not page.get("loggedIn") and not asked_login:
                asked_login = True
                yield ("login",)
                continue                                   # read the page again, logged in
            sc.collect(page.get("posts") or [], items)
            last = max(last, int(page.get("last") or 1))
            title = title or str(page.get("title") or "")
            n += 1
        self.record.note_thread(base, title, min(last, max(n - 1, 1)))
        left, adopted = sc.todo(items, self.record, self.dest)
        self.record.save()
        if adopted:
            self._log(f"{adopted:,} file(s) were already in the folder — counted as done.")
        self._log(f"“{title}”: {len(items):,} files in pages {first}–{last}; {len(left):,} to download.")
        return left

    def _crawled(self, error, left) -> None:
        if error:
            self._end(str(error))
            return
        if not left or self.stopping:
            self._end()
            return
        self.queue = deque(left)
        self.total = len(left)
        self.bar.setRange(0, self.total)
        self.bar.setValue(0)
        self.active = 0
        for lane in self.lanes[:min(LANES, len(left))]:
            self.active += 1
            _Runner(self, self._lane(lane), self._lane_done).start()

    def _lane(self, page: QWebEnginePage):
        """Takes files off the queue one by one: resolve → download → date → into the folder."""
        while self.queue and not self.stopping:
            item = self.queue.popleft()
            url = yield ("resolve", page, item)
            if not url:
                self.failed += 1
                self.record.note_failed(item)
                self._log(f"{item.link}: couldn't find the full-size file.")
            else:
                ext = sc.extension(url, item.kind)
                path = yield ("download", page, url, item, ext)
                if not path:
                    self.failed += 1
                    self.record.note_failed(item)
                    self._log(f"{item.link}: the download failed.")
                else:
                    final = yield ("thread", lambda p=path, it=item, e=ext: self._settle(p, it, e))
                    if isinstance(final, Exception):
                        self.failed += 1
                        self.record.note_failed(item)
                        self._log(f"{item.link}: couldn't save it into the folder — {final}")
                    else:
                        self.record.add(item, final.name)
                        self.written.append(str(final))
                        self.untagged.append(str(final))
                        if len(self.written) % 20 == 0:
                            self._save_and_tag()
            self.processed += 1
            self.bar.setValue(min(self.total, self.processed))
            self._say(f"Downloading — {len(self.written):,} saved, {self.failed:,} failed, "
                      f"{len(self.queue):,} waiting.")

    def _settle(self, path: str, item: sc.Item, ext: str):
        """On a worker thread: the date rule, then into the drive folder."""
        try:
            outcome = sc.apply_date(path, item.posted, self.exiftool)
            if outcome == "kept":
                self.kept += 1
            elif outcome == "post":
                self.post_dated += 1
            return sc.place(path, self.dest, f"{item.ident}.{ext}")
        except OSError as e:
            return e

    def _save_and_tag(self) -> None:
        """The record and the new files' tag, every 20 files and at the end (on the GUI thread: the
        record is only ever touched here)."""
        try:
            self.record.save()
        except OSError as e:
            self._log(f"Couldn't save the download record: {e}")
        if self.tags is not None and self.untagged:
            try:
                self.tags.add(self.untagged, [sc.TAG])
                self.untagged = []
            except OSError as e:
                self._log(f"Couldn't tag the files: {e}")

    def _lane_done(self, error, _returned) -> None:
        if error:
            self._log(f"Stopped a download lane: {error}")
        self.active -= 1
        if self.active <= 0:
            self._save_and_tag()
            self._end()

    def _end(self, problem: str | None = None) -> None:
        self.running = False
        self.go_btn.setEnabled(True)
        self.go_btn.setText("Get New")
        self.stop_btn.setEnabled(False)
        self.bar.setVisible(False)
        n = len(getattr(self, "written", []))
        if problem:
            msg = problem
        elif n == 0 and not self.failed:
            msg = "Nothing new in the thread."
        else:
            msg = f"Saved {n:,} file{'s' if n != 1 else ''} into “{self.person.name}/{sc.FOLDER}”"
            if self.failed:
                msg += f"; {self.failed:,} failed (they'll be tried again next time)"
            msg += "."
            if n:
                msg += f" {self.kept:,} kept their own date; {self.post_dated:,} got the post's date."
        self._say(msg)
        self._log(msg)
        self.finished.emit(str(self.dest), list(getattr(self, "written", [])))

    # ------------------------------------------------------------------ carrying out requests
    def handle(self, req: tuple, cb) -> None:
        kind = req[0]
        if kind == "read":
            self._read(req[1], req[2], cb)
        elif kind == "login":
            self._ask_login(cb)
        elif kind == "resolve":
            self._resolve(req[1], req[2], cb)
        elif kind == "download":
            self._download(*req[1:], cb=cb)
        elif kind == "thread":
            fn = req[1]

            def work() -> None:
                try:
                    result = fn()
                except Exception as e:  # noqa: BLE001
                    result = e
                self.bridge.done.emit(cb, result)
            threading.Thread(target=work, daemon=True).start()
        else:
            raise ValueError(kind)

    def _poll(self, page: QWebEnginePage, js: str, accept, cb, timeout: float, on_challenge=None) -> None:
        """Runs `js` on `page` every 0.8 s until `accept(result)` is true (→ cb(result)) or `timeout`
        seconds pass (→ cb(None)). While the page shows a "you're human?" check the clock waits (up to
        15 minutes): the person is answering it."""
        started = time.monotonic()
        deadline = [started + timeout]
        challenged = [False]

        def tick() -> None:
            page.runJavaScript(js, 0, got)

        def got(result) -> None:
            result = result if isinstance(result, dict) else {}
            now = time.monotonic()
            if result.get("challenge"):
                if not challenged[0]:
                    challenged[0] = True
                    if on_challenge:
                        on_challenge()
                deadline[0] = max(deadline[0], min(now + 20, started + 900))
            elif accept(result):
                cb(result)
                return
            if now > deadline[0] or (self.stopping and now - started > 5):
                cb(None)
                return
            QTimer.singleShot(800, tick)

        QTimer.singleShot(600, tick)

    def _read(self, url: str, n: int, cb) -> None:
        """Page `n` of the thread in the visible view, read once it's that page and its posts are there
        (until then the view can still hold the page before)."""
        self.view.load(QUrl(url))
        self._poll(self.view.page(), sc.EXTRACT_POSTS_JS,
                   lambda r: int(r.get("page") or 1) == n and (r.get("ready") == "complete" or bool(r.get("posts"))),
                   cb, 60,
                   on_challenge=lambda: self._say("SimpCity is checking that a person is asking — answer it in the "
                                                  "window below; the download carries on by itself."))

    def _ask_login(self, cb) -> None:
        """No links on the first page and not logged in: SimpCity shows links to members only."""
        self.view.load(QUrl(LOGIN))
        self._say("SimpCity shows its links only to members. Log in below — the download starts again by itself.")
        self._log("Waiting for you to log in to SimpCity…")

        saw_login = [False]

        def check() -> None:
            self.view.page().runJavaScript(sc.LOGGED_IN_JS, 0, answer)

        def answer(v) -> None:
            if v == "login-page":
                saw_login[0] = True
            if self.stopping:
                cb(None)
            elif v == "yes" or (v == "left-login" and saw_login[0]):
                self._log("Logged in.")
                cb(None)
            else:
                QTimer.singleShot(1500, check)

        QTimer.singleShot(1500, check)

    def _resolve(self, page: QWebEnginePage, item: sc.Item, cb) -> None:
        """The full-size file behind a goonbox/turbo link, worked out in this lane's hidden page:
        goonbox's own API first (`original_url`), else what the page shows once its script has built it."""
        if item.kind == "goonbox":
            self._goonbox_api(page, item, lambda url: cb(url) if url else self._resolve_page(page, item, cb))
        else:
            self._resolve_page(page, item, cb)

    def _show_check(self, url: str) -> None:
        """A check a hidden page can't pass, shown in the window for the person (the cookie it leaves
        lets every lane through)."""
        self.view.load(QUrl(url))
        self._say(f"{QUrl(url).host()} is checking that a person is asking — answer it in the window below; "
                  "the download carries on by itself.")

    def _goonbox_api(self, page: QWebEnginePage, item: sc.Item, cb) -> None:
        """`/api/images/<id>` asked from a goonbox page — the lane stays on goonbox, so after the first
        file each one is a single quick request."""
        start, read = sc.goonbox_api_js(item.ident)

        def answered(r) -> None:
            ok = r and int(r.get("status") or 0) == 200 and r.get("url")
            cb(r["url"] if ok else None)

        def ask(_ready=None) -> None:
            if _ready is False:
                cb(None)
                return
            page.runJavaScript(start, 0, lambda _r: self._poll(page, read, lambda r: "status" in r, answered, 25))

        if page.url().host().endswith("goonbox.cr"):
            ask()
            return
        page.load(QUrl(item.link))
        self._poll(page, sc.resolve_js("goonbox"),
                   lambda r: r.get("ready") == "complete" and "goonbox" in str(r.get("href") or ""),
                   lambda r: ask(bool(r)), 30, on_challenge=lambda: self._show_check(item.link))

    def _resolve_page(self, page: QWebEnginePage, item: sc.Item, cb) -> None:
        """What the goonbox/turbo page shows (its video, download link, or full-size picture)."""
        page.load(QUrl(item.link))
        t0 = time.monotonic()

        def mine(r) -> bool:
            """Only an answer from this file's own page counts (not the page before it)."""
            return item.ident in str(r.get("href") or "")

        def done(r) -> None:
            if r is None and not self.stopping:
                page.load(QUrl(item.link))            # one fresh try (a cleared check, a slow page)
                self._poll(page, sc.resolve_js(item.kind),
                           lambda x: mine(x) and (bool(x.get("url")) or bool(x.get("gone"))),
                           lambda x: cb((x or {}).get("url") or None), 30)
                return
            cb((r or {}).get("url") or None)

        self._poll(page, sc.resolve_js(item.kind),
                   lambda r: mine(r) and (bool(r.get("url")) or bool(r.get("gone")) or
                                          (r.get("ready") == "complete" and time.monotonic() - t0 > 12)), done, 45,
                   on_challenge=lambda: self._show_check(item.link))

    def _download(self, page: QWebEnginePage, url: str, item: sc.Item, ext: str, cb) -> None:
        """Chromium downloads it (the CDNs turn non-browser clients away) into the temp folder."""
        name = f"{item.ident}-{int(time.time() * 1000)}.{ext}"
        state = {"started": False, "done": False}

        def finish(path) -> None:
            if not state["done"]:
                state["done"] = True
                self.pending.pop(name, None)
                cb(path)

        def requested() -> None:
            state["started"] = True

        self.pending[name] = (finish, requested)
        page.download(QUrl(url), name)

        def watchdog() -> None:
            if not state["started"] and not state["done"]:
                self._log(f"{item.ident}: the browser didn't start the download — trying directly.")
                self.pending.pop(name, None)
                self.handle(("thread", lambda: self._direct(url, item, name)), finish)
        QTimer.singleShot(30000, watchdog)

    def _download_requested(self, req: QWebEngineDownloadRequest) -> None:
        entry = self.pending.get(req.downloadFileName()) or self.pending.get(req.suggestedFileName())
        if entry is None:
            return                                   # someone's own download in the window — leave it alone
        finish, requested = entry
        requested()
        req.setDownloadDirectory(str(self.tmp))
        req.setDownloadFileName(req.suggestedFileName() or req.downloadFileName())
        path = os.path.join(str(self.tmp), req.downloadFileName())

        def changed() -> None:
            if not req.isFinished():
                return
            ok = req.state() == QWebEngineDownloadRequest.DownloadState.DownloadCompleted
            html = (req.mimeType() or "").startswith("text/")
            if ok and not html and os.path.getsize(path) > 0:
                finish(path)
            else:
                if ok:
                    try:
                        os.remove(path)
                    except OSError:
                        pass
                finish(None)

        req.isFinishedChanged.connect(changed)
        req.accept()

    def _direct(self, url: str, item: sc.Item, name: str) -> str | None:
        """Fallback on a worker thread: the same request outside the browser, with its cookies and
        User-Agent and the page as Referer."""
        host = QUrl(url).host()
        headers = {"User-Agent": profile().httpUserAgent(), "Referer": item.link, "Accept": "*/*"}
        cookie = self._cookie_header(host)
        if cookie:
            headers["Cookie"] = cookie
        path = os.path.join(str(self.tmp), name)
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=120) as resp, \
                    open(path, "wb") as f:
                if (resp.headers.get("Content-Type") or "").startswith("text/"):
                    raise OSError("the server sent a page, not the file")
                while chunk := resp.read(1 << 20):
                    f.write(chunk)
            return path if os.path.getsize(path) > 0 else None
        except (OSError, ValueError):
            try:
                os.remove(path)
            except OSError:
                pass
            return None


def main() -> None:
    if len(sys.argv) < 2 or not os.path.isdir(sys.argv[1]):
        sys.exit('usage: simpcity_downloader.py "<person folder>" [thread-url]')
    QApplication.setAttribute(Qt.ApplicationAttribute.AA_ShareOpenGLContexts)
    app = QApplication(sys.argv[:1])
    import shared_tags
    win = SimpCityWindow(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else None, tags=shared_tags.default_store())
    win.show()
    sys.exit(app.exec())


if __name__ == "__main__":
    main()
