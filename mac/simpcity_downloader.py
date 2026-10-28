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
the file its player loads) and downloads it — a plain request first, else Chromium itself — six at a
time, each in its own hidden page. A download lands in the Mac's temp folder, gets its date (its own
capture date if it has one, else the post's — see `simpcity.apply_date`), then moves into
`<person>/simpcity` as `<id>.<ext>` and is tagged "simpcity" in the shared tag store. The record is
saved as it goes, so a stopped run resumes where it was.

With "Download videos" on, the posts' pixeldrain / gofile / cyberdrop / bunkr / filester / fileditch
links are listed first (`filehosts.py` — their APIs on worker threads, a lane's page for the hosts that
need a browser), and their videos join the downloads as `<host>-<id>.<ext>`. A video posted on several
hosts is downloaded once (`simpcity.Dedup`: the hosts' sizes up front, the server's size as a download
starts, the SHA-256 once it's in); the other copies are recorded as the same video. Off, turbo and the
hosts are left for a later run.

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
from collections import deque
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from PySide6.QtCore import QDateTime, QObject, QSettings, Qt, QTimer, QUrl, Signal  # noqa: E402
from PySide6.QtWidgets import (QApplication, QCheckBox, QHBoxLayout, QLabel, QLineEdit, QMainWindow,  # noqa: E402
                               QMessageBox, QPlainTextEdit, QProgressBar, QPushButton, QVBoxLayout, QWidget)
from PySide6.QtWebEngineCore import (QWebEngineDownloadRequest, QWebEnginePage, QWebEngineProfile,  # noqa: E402
                                     QWebEngineSettings, QWebEngineUrlRequestInterceptor)
from PySide6.QtWebEngineWidgets import QWebEngineView  # noqa: E402

import filehosts as fh  # noqa: E402
import simpcity as sc  # noqa: E402

LANES = 6                 # files resolved + downloaded at once
HOME = "https://simpcity.cr/"
LOGIN = "https://simpcity.cr/login/"

_PROFILE: QWebEngineProfile | None = None


class _Referer(QWebEngineUrlRequestInterceptor):
    """Gives the image servers' requests goonbox's Referer (they refuse requests without one — see
    `simpcity.REFERER`), and a file-host download the page it came from (`by_url`, set just before it
    starts); Chromium's own downloads otherwise send none. Called on Chromium's network thread — a plain
    dict lookup is all it does."""

    def __init__(self, parent=None) -> None:
        super().__init__(parent)
        self.by_url: dict[str, str] = {}

    def interceptRequest(self, info) -> None:  # noqa: N802 — Qt override
        url = info.requestUrl()
        ref = self.by_url.get(url.toString())
        if ref:
            info.setHttpHeader(b"Referer", ref.encode())
        elif url.host().endswith(sc.REFERER_HOSTS):
            info.setHttpHeader(b"Referer", sc.REFERER.encode())


def profile() -> QWebEngineProfile:
    """One persistent browser profile: the SimpCity login and the sites' "you're human" cookies
    survive restarts. Parented to the app so it outlives every page."""
    global _PROFILE
    if _PROFILE is None:
        _PROFILE = QWebEngineProfile("simpcity", QApplication.instance())
        _PROFILE.setPersistentCookiesPolicy(QWebEngineProfile.PersistentCookiesPolicy.ForcePersistentCookies)
        _PROFILE._referer = _Referer(_PROFILE)       # kept alive with the profile
        _PROFILE.setUrlRequestInterceptor(_PROFILE._referer)
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
        self.exif: sc.ExifSession | None = None
        self.running = False
        self.stopping = False
        self.pending: dict[str, object] = {}        # browser download file name → callbacks
        self.pending_urls: dict[str, str] = {}      # browser download address → its file name
        self.fail_hosts: dict[str, int] = {}        # server → failed downloads this run
        self.fail_why: dict[str, str] = {}          # server → the last reason
        self.shown = self.direct_noted = 0          # resolved addresses / direct failures logged so far
        self.exif_noted = False
        self.dedup = sc.Dedup()
        self.click_wait: dict[int, object] = {}     # lane page (id) → takes a download its button started
        self.cookies: dict[str, dict[str, str]] = {}
        self.bridge = _Bridge()
        self.bridge.done.connect(lambda cb, result: cb(result))
        self.tmp = Path(tempfile.mkdtemp(prefix="simpcity-"))
        self.setWindowTitle(f"SimpCity — {self.person.name}")
        self.resize(1180, 900)

        prof = profile()
        self.ua = prof.httpUserAgent()               # read here: Qt objects can't be asked from a worker thread
        self.referer = prof._referer
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
        self.settings = QSettings("Photo Browser", "SimpCity")
        self.videos = QCheckBox("Download videos")
        self.videos.setToolTip("turbo.cr videos and the videos the posts link on pixeldrain, gofile, cyberdrop, bunkr, "
                               "filester and fileditch. Off: photos only — the videos are kept for a later run.")
        self.videos.setChecked(str(self.settings.value("videos", "true")).lower() != "false")
        self.videos.toggled.connect(lambda on: self.settings.setValue("videos", "true" if on else "false"))
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
        row2.addWidget(self.videos)
        row2.addWidget(self.full)
        row2.addStretch(1)
        row2.addWidget(back)
        row2.addWidget(login)
        self.status = QLabel(f"Saves into “{self.person.name}/{sc.FOLDER}”. Log in to SimpCity below if you haven't; "
                             "if a site asks whether you're human, answer it below — the download carries on by itself.")
        self.status.setWordWrap(True)
        self.bar = QProgressBar()
        self.bar.setVisible(False)
        self.bar.setFixedWidth(260)
        self.bar.setFormat("%v of %m")
        self.bar.setTextVisible(True)
        self.log = QPlainTextEdit()
        self.log.setReadOnly(True)
        self.log.setMaximumHeight(170)
        self.log.setMaximumBlockCount(5000)

        box = QWidget()
        lay = QVBoxLayout(box)
        lay.addLayout(top)
        lay.addLayout(row2)
        progress = QHBoxLayout()                     # status and bar side by side: neither can squeeze the other
        progress.addWidget(self.status, 1)
        progress.addWidget(self.bar, 0, Qt.AlignmentFlag.AlignVCenter)
        lay.addLayout(progress)
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
        self.want_videos = self.videos.isChecked()
        self.go_btn.setEnabled(False)
        self.stop_btn.setEnabled(True)
        self.videos.setEnabled(False)
        self.bar.setVisible(True)
        self.bar.setRange(0, 0)
        self.written: list[str] = []
        self.untagged: list[str] = []
        self.upscaled: list[str] = []          # tagged "upscaled" too, like the app's own upscales
        self.renamed: list[tuple[str, str]] = []
        self.failed = self.processed = 0
        self.kept = self.post_dated = 0
        self.fixed = self.converted = self.enlarged = 0
        self.fail_hosts, self.fail_why = {}, {}
        self.shown = self.direct_noted = 0
        self.exif_noted = False
        self.dedup = sc.Dedup()
        self.click_wait = {}
        self.queue: deque = deque()
        self.from_hosts = self.same = self.not_video = 0
        self.links_failed: list[str] = []
        self.stand_ins: dict[str, list[sc.Item]] = {}   # mirror key → the copies that failed before it was tried
        self.exif = sc.ExifSession(self.exiftool) if self.exiftool else None
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
        first = 1 if full else self.record.start_page(base, self.want_videos)
        had_hosts = int(self.record.threads.get(base, {}).get("hosts") or 0) >= sc.HOSTS_READ
        items: dict[str, sc.Item] = {}
        links: dict[str, fh.Link] = {}
        n, last, title = first, first, ""
        asked_login = False
        while n <= last and not self.stopping:
            self._say(f"Reading page {n}{f' of {last}' if last > n else ''}… {len(items) + len(links):,} files and links found so far.")
            page = yield ("read", sc.page_url(base, n), n)
            if not page:
                raise RuntimeError(f"Couldn't read page {n} of the thread: {sc.describe_page(self.last_page)}. "
                                   "Check the address and that you're logged in, then try again.")
            found = sum(1 for p in page.get("posts") or [] for u in p.get("urls") or [] if sc.is_link(str(u)))
            if n == first and not found and not page.get("loggedIn") and not asked_login:
                asked_login = True
                yield ("login",)
                continue                                   # read the page again, logged in
            sc.collect(page.get("posts") or [], items, links)
            last = max(last, int(page.get("last") or 1))
            title = title or str(page.get("title") or "")
            n += 1
        # Every page up to the end read (from page 1, or on top of a full read before): every file-host
        # link in the thread is in the record now — done, still to do, or kept for later.
        self.record.note_thread(base, title, min(last, max(n - 1, 1)), hosts=(first == 1 or had_hosts) and not self.stopping)
        fixes = self.record.fixes(items, self.dest)
        self.record.redate(items, read_all=first == 1 and not self.stopping)
        left, adopted = sc.todo(items, self.record, self.dest, self.want_videos)
        to_list = self.record.links_todo(links, self.want_videos, again=full)
        self.dedup.seed(self.record, self.dest)
        self.record.save()
        if adopted:
            self._log(f"{adopted:,} file(s) were already in the folder — counted as done.")
        self._log(f"“{title}”: {len(items):,} files and {len(links):,} file-host links in pages {first}–{last}; "
                  f"{len(left):,} to download" + (f", {len(to_list):,} links to list." if to_list else "."))
        if not self.want_videos:
            later = sum(1 for v in self.record.failed.values() if v.get("skipped")) + \
                sum(1 for v in self.record.links.values() if v.get("skipped"))
            if later:
                self._log(f"Download videos is off: {later:,} video(s)/link(s) are kept for a run with it on.")
        if fixes:
            self._log(f"Bringing {len(fixes):,} earlier download(s) up to date (dates, WebP → JPEG, small photos 2×).")
        return left, fixes, to_list

    def _crawled(self, error, result) -> None:
        if error:
            self._end(str(error))
            return
        left, fixes, to_list = result
        if to_list and not self.stopping:
            self._list_links(left, fixes, to_list)
            return
        self._start_downloads(left, fixes)

    # -- file-host links: what's in them, before any download

    def _list_links(self, left: list[sc.Item], fixes, to_list: list[fh.Link]) -> None:
        hosts: dict[str, int] = {}
        for lk in to_list:
            hosts[lk.host] = hosts.get(lk.host, 0) + 1
        self._log("Listing the videos in " + ", ".join(f"{h} ×{c}" for h, c in sorted(hosts.items(), key=lambda kv: -kv[1])) + "…")
        self.link_queue = deque(to_list)
        self.links_total, self.links_done = len(to_list), 0
        self.listed: list[tuple[fh.Link, list[fh.Remote]]] = []
        self.bar.setRange(0, self.links_total)
        self.bar.setValue(0)
        self.active = 0

        def lister_done(error, _r) -> None:
            if error:
                self._log(f"Stopped listing links: {error}")
            self.active -= 1
            if self.active <= 0:
                self._listed(left, fixes)
        for lane in self.lanes[:min(LANES, len(to_list))]:
            self.active += 1
            _Runner(self, self._lister(lane), lister_done).start()

    def _lister(self, page: QWebEnginePage):
        """Takes links off the queue: the host's API on a worker thread, else (a check page, no API, a
        failure) the link's page in this lane — a folder's page lists its files' pages."""
        while self.link_queue and not self.stopping:
            lk = self.link_queue.popleft()
            self._say(f"Listing the videos in {self.links_total:,} file-host link{'s' if self.links_total != 1 else ''} — "
                      f"{self.links_done:,} done…")
            res = yield ("thread", lambda lk=lk: fh.expand(lk, self.ua), f"{lk.url} (listing its videos)")
            remotes: list[fh.Remote] = res if isinstance(res, list) else []
            gone = isinstance(res, fh.Gone)
            why = "" if isinstance(res, list) else str(res)
            if isinstance(res, fh.NeedsBrowser) and lk.kind == "file":
                # One file behind a check page: its page is read when its turn comes.
                remotes, why = [fh.Remote(lk.host, fh.safe_id(lk.ident), page=lk.url, referer=lk.url)], ""
            if not isinstance(res, list) and not gone and lk.kind == "folder":
                if not isinstance(res, fh.NeedsBrowser):
                    self._log(f"{lk.url}: {why} — reading its page instead.")
                shown = yield ("hostpage", page, lk.url)
                if shown and not shown.get("gone"):
                    remotes = fh.from_page(lk, shown)
                    # A page that listed files, none of them videos, is done; one that listed nothing
                    # (still building, or a layout the script doesn't know) is tried again next run.
                    why = "" if remotes or shown.get("files") or shown.get("pages") else (why or "its page listed nothing")
                elif shown:
                    gone, why = True, "the page says it's gone"
                else:
                    why = f"{why}; its page didn't load" if why else "its page didn't load"
            if gone:
                self._log(f"{lk.url}: gone ({why or 'not found'}).")
            elif why:
                self.links_failed.append(lk.host)
                self._log(f"{lk.url}: couldn't list its videos — {why}")
            elif not remotes:
                self._log(f"{lk.url}: no videos in it.")
            self.record.note_link(lk, [r.key for r in remotes], why="" if gone else why, gone=gone)
            if remotes:
                self.listed.append((lk, remotes))
            self.links_done += 1
            self.bar.setValue(min(self.links_total, self.links_done))

    def _listed(self, left: list[sc.Item], fixes) -> None:
        host, adopted, same = sc.host_items(self.listed, self.record, self.dest, self.dedup)
        self.same += same
        found = sum(len(r) for _lk, r in self.listed)
        self._log(f"{found:,} video(s) in the links; {len(host):,} to download"
                  + (f", {same:,} the same as one downloaded before" if same else "")
                  + (f", {adopted:,} already in the folder" if adopted else "") + ".")
        try:
            self.record.save()
        except OSError as e:
            self._log(f"Couldn't save the download record: {e}")
        if self.stopping:
            self._finish()
            return
        self._start_downloads(sorted(left + host, key=lambda i: (i.posted or 0, i.key)), fixes)

    # -- downloads

    def _start_downloads(self, left: list[sc.Item], fixes) -> None:
        if (not left and not fixes) or self.stopping:
            self._finish()
            return
        self.queue = deque(left)
        self.total = len(left) + len(fixes)
        self.bar.setRange(0, self.total)
        self.bar.setValue(0)
        self._say(f"Downloading {len(left):,} file{'s' if len(left) != 1 else ''}"
                  + (f" and bringing {len(fixes):,} earlier one{'s' if len(fixes) != 1 else ''} up to date…" if fixes else "…"))
        self.active = 0
        if fixes:
            self.active += 1
            _Runner(self, self._fixer(fixes), self._lane_done).start()
        for lane in self.lanes[:min(LANES, len(left))]:
            self.active += 1
            _Runner(self, self._lane(lane), self._lane_done).start()

    def _fixer(self, fixes: list[tuple[sc.Item, str]]):
        """Earlier downloads brought up to the current rules, on a worker thread one at a time (alongside
        the new downloads): the date their post really has, WebP → JPEG, small photos 2×."""
        for item, name in fixes:
            if self.stopping:
                break
            r = yield ("thread", lambda it=item, n=name: sc.fix_file(self.dest, it, n, self.exif, self.tmp))
            if isinstance(r, Exception):
                self._log(f"{name}: couldn't bring it up to date — {r}")
            else:
                new_name, outcome, upscaled = r
                if new_name != name:
                    self.renamed.append((str(self.dest / name), str(self.dest / new_name)))
                    self.converted += 1
                if upscaled:
                    self.upscaled.append(str(self.dest / new_name))
                    self.enlarged += 1
                if outcome == "post":
                    self.fixed += 1
                self.record.add(item, new_name, upscaled=upscaled)
            self.processed += 1
            self.bar.setValue(min(self.total, self.processed))

    def _lane(self, page: QWebEnginePage):
        """Takes files off the queue one by one: resolve → download → date → into the folder."""
        while self.queue and not self.stopping:
            item = self.queue.popleft()
            if item.remote:
                url = yield from self._host_url(page, item)
            else:
                url = yield ("resolve", page, item)
                if not url:
                    self._log(f"{item.link}: couldn't find the full-size file.")
            if url and self.shown < 3:                 # what the first files resolve to, for the log
                self.shown += 1
                self._log(f"{item.stem} → {url[:140]}")
            if not url:
                self._lost(item)
            else:
                ext = sc.extension(url, item.kind, item.remote.name if item.remote else "")
                if item.remote:
                    self._log(f"↓ {item.stem}" + (f" “{item.remote.name}”" if item.remote.name else "")
                              + (f", {item.remote.size / 1048576:,.0f} MB" if item.remote.size else "") + f" from {item.kind}…")
                path = yield ("download", page, url, item, ext)
                if isinstance(path, sc.Skip):
                    self._skipped(item, path)
                elif not path:
                    self._lost(item)
                else:
                    done = yield ("thread", lambda p=path, it=item: self._settle(p, it),
                                  f"{item.stem} (dating it and saving it into the folder)")
                    if self.exif and self.exif.note and not self.exif_noted:
                        self.exif_noted = True
                        self._log(self.exif.note)
                    if isinstance(done, sc.Skip):
                        self._skipped(item, done)
                    elif isinstance(done, Exception):
                        self._log(f"{item.link}: couldn't save it into the folder — {done}")
                        self._lost(item)
                    else:
                        final, upscaled, outcome, size, sha = done
                        self._log(f"✓ {final.name} — {sc.human_size(final)}"
                                  + {"kept": ", its own date", "post": ", the post's date"}.get(outcome, "")
                                  + (", upscaled 2×" if upscaled else ""))
                        self.record.add(item, final.name, upscaled=upscaled, size=size, sha256=sha)
                        if item.remote:
                            self.from_hosts += 1
                        stood_in = self.stand_ins.pop(item.key, [])
                        self.failed -= len(stood_in)          # a copy that failed first is done: it's this
                        for twin in self.dedup.settle(item.key, ok=True) + stood_in:
                            self.record.add_same(twin, item.key)
                            self.same += 1
                        self.written.append(str(final))
                        self.untagged.append(str(final))
                        if upscaled:
                            self.upscaled.append(str(final))
                        if len(self.written) % 20 == 0:
                            self._save_and_tag()
            self.processed += 1
            self.bar.setValue(min(self.total, self.processed))
            self._say(f"Downloading — {len(self.written):,} saved, {self.failed:,} failed, "
                      f"{len(self.queue):,} waiting.")

    def _host_url(self, page: QWebEnginePage, item: sc.Item):
        """A file-host video's address: from its host's API just before the download (cyberdrop's and
        bunkr's don't last), else what its page plays or links — pressing its download button if it
        shows nothing until then."""
        r = item.remote
        res = yield ("thread", lambda: fh.direct_url(r, self.ua), f"{item.stem} (asking {item.kind} for the file)")
        if isinstance(res, str) and res:
            return res
        if isinstance(res, Exception) and not isinstance(res, fh.NeedsBrowser):
            self._log(f"{item.stem}: {item.kind} didn't give the file ({res})" + (" — trying its page." if r.page else "."))
        if not r.page:
            return None
        got = yield ("hostfile", page, item)
        if not got:
            self._log(f"{item.stem}: couldn't find the video on {r.page}")
            return None
        url, name = got
        if name and not r.name:
            r.name = name
        if not r.referer:
            r.referer = r.page
        return url

    def _lost(self, item: sc.Item) -> None:
        """A file that didn't download: tried again next run — and the copies of a video that waited on
        it are tried now instead."""
        self.failed += 1
        self.record.note_failed(item)
        if item.video:
            twins = self.dedup.settle(item.key, ok=False)
            if twins:
                self._log(f"{item.stem}: trying the same video on {', '.join(sorted({t.kind for t in twins}))} instead.")
                for t in twins:
                    self.stand_ins.setdefault(t.key, []).append(item)
                self.queue.extendleft(reversed(twins))
                self.total += len(twins)
                self.bar.setRange(0, self.total)

    def _skipped(self, item: sc.Item, why: sc.Skip) -> None:
        """A download not kept: a video already downloaded (or on its way) — recorded as that one — or a
        file-host link that isn't a video."""
        if isinstance(why, sc.Duplicate):
            if self.record.has(why.other):
                self.record.add_same(item, why.other)
                self.same += 1
                self._log(f"= {item.stem} is the same video as {self.record.file_of(why.other) or why.other} — not saved twice.")
            elif not self.dedup.wait(why.other, item):
                self.queue.appendleft(item)                # the one it matched failed meanwhile: try it
                self.total += 1
                self.bar.setRange(0, self.total)
        else:
            self.not_video += 1
            self.record.add_skipped(item, str(why))
            self._log(f"{item.stem}: not a video ({why}) — left alone.")

    def _settle(self, path: str, item: sc.Item):
        """On a worker thread: for a video, its size and SHA-256 as downloaded (the same video from
        another host is dropped here); WebP → JPEG and the small-photo upscale, the date rule, then into
        the drive folder. Returns (where it landed, upscaled, date outcome, size, sha256)."""
        try:
            size, sha = 0, ""
            if item.video or sc.is_video(path):
                size = os.path.getsize(path)
                sha = sc.file_sha256(path)
                other = self.dedup.match_hash(item.key, sha)
                if other:
                    os.remove(path)
                    return sc.Duplicate(other)
                self.dedup.note_size(item.key, size)
            path, upscaled = sc.prepare_image(path)
            outcome = sc.apply_date(path, item.posted, self.exif)
            if outcome == "kept":
                self.kept += 1
            elif outcome == "post":
                self.post_dated += 1
            final = sc.place(path, self.dest, f"{item.stem}{os.path.splitext(path)[1].lower()}")
            return final, upscaled, outcome, size, sha
        except OSError as e:
            return e

    def _save_and_tag(self) -> None:
        """The record and the new files' tag, every 20 files and at the end (on the GUI thread: the
        record is only ever touched here)."""
        try:
            self.record.save()
        except OSError as e:
            self._log(f"Couldn't save the download record: {e}")
        if self.tags is None:
            return
        try:
            if self.renamed:                       # a converted file takes its tags to its new name
                self.tags.carry(self.renamed)
                self.tags.forget([old for old, _new in self.renamed])
                self.renamed = []
            if self.untagged:
                self.tags.add(self.untagged, [sc.TAG])
                self.untagged = []
            if self.upscaled:
                self.tags.add(self.upscaled, [sc.UPSCALED_TAG])
                self.upscaled = []
        except OSError as e:
            self._log(f"Couldn't tag the files: {e}")

    def _lane_done(self, error, _returned) -> None:
        if error:
            self._log(f"Stopped a download lane: {error}")
        self.active -= 1
        if self.active <= 0:
            self._finish()

    def _finish(self) -> None:
        """The run's end: what a stop left in the queue (and copies still waiting on another) is kept for
        the next run, each file-host link is marked done if everything in it is, then the record and tags."""
        for item in list(self.queue) + self.dedup.left_waiting():
            if not self.record.has(item.key):
                self.record.note_failed(item)
        self.queue.clear()
        self.record.settle_links()
        self._save_and_tag()
        self._end()

    def _end(self, problem: str | None = None) -> None:
        self.running = False
        if self.exif:
            self.exif.close()
        self.go_btn.setEnabled(True)
        self.go_btn.setText("Get New")
        self.stop_btn.setEnabled(False)
        self.bar.setVisible(False)
        n = len(getattr(self, "written", []))
        self.videos.setEnabled(True)
        if problem:
            msg = problem
        elif n == 0 and not self.failed:
            msg = "Nothing new in the thread."
        else:
            msg = f"Saved {n:,} file{'s' if n != 1 else ''} into “{self.person.name}/{sc.FOLDER}”"
            if self.failed:
                msg += f"; {self.failed:,} failed (they'll be tried again next time)"
                if self.fail_hosts:
                    msg += " — " + ", ".join(f"{h} ×{n} ({self.fail_why.get(h, '')})"
                                             for h, n in sorted(self.fail_hosts.items(), key=lambda kv: -kv[1])[:3])
            msg += "."
            if n:
                msg += f" {self.kept:,} kept their own date; {self.post_dated:,} got the post's date."
        if not problem and (self.from_hosts or self.same or self.not_video or self.links_failed):
            parts = []
            if self.from_hosts:
                parts.append(f"{self.from_hosts:,} video{'s' if self.from_hosts != 1 else ''} came from file hosts")
            if self.same:
                parts.append(f"{self.same:,} were the same video on another host or link (downloaded once)")
            if self.not_video:
                parts.append(f"{self.not_video:,} host link(s) weren't videos")
            if self.links_failed:
                parts.append(f"{len(self.links_failed):,} link(s) couldn't be listed ("
                             + ", ".join(sorted(set(self.links_failed))) + " — tried again next time)")
            msg += " " + "; ".join(parts)[:1].upper() + "; ".join(parts)[1:] + "."
        if not problem and (self.fixed or self.converted or self.enlarged):
            msg += (f" Earlier downloads: {self.fixed:,} got their post's real date, {self.converted:,} WebP → JPEG, "
                    f"{self.enlarged:,} small photos upscaled 2×.")
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
        elif kind == "hostpage":
            self._host_page(req[1], req[2], cb)
        elif kind == "hostfile":
            self._host_file(req[1], req[2], cb)
        elif kind == "thread":
            fn = req[1]
            label = req[2] if len(req) > 2 else ""
            state = {"done": False}
            if label:
                # A step that takes this long is worth a line — a stuck one used to leave the log silent.
                QTimer.singleShot(60000, lambda: None if state["done"] else self._log(f"still working on {label}…"))
            def answered(result, cb=cb) -> None:
                state["done"] = True
                cb(result)

            def work() -> None:
                try:
                    result = fn()
                except Exception as e:  # noqa: BLE001
                    result = e
                self.bridge.done.emit(answered, result)
            threading.Thread(target=work, daemon=True).start()
        else:
            raise ValueError(kind)

    def _poll(self, page: QWebEnginePage, js: str, accept, cb, timeout: float, on_challenge=None,
              every: int = 250) -> None:
        """Runs `js` on `page` every `every` ms until `accept(result)` is true (→ cb(result)) or `timeout`
        seconds pass (→ cb(None)). While the page shows a "you're human?" check the clock waits (up to
        15 minutes): the person is answering it."""
        started = time.monotonic()
        deadline = [started + timeout]
        challenged = [False]
        script = sc.json_call(js)

        def tick() -> None:
            page.runJavaScript(script, 0, got)

        def got(raw) -> None:
            result = sc.parse_result(raw)
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
            QTimer.singleShot(every if not challenged[0] else 1000, tick)

        QTimer.singleShot(min(every, 150), tick)

    def _read(self, url: str, n: int, cb) -> None:
        """Page `n` of the thread in the visible view, read once it's that page and its posts are there
        (until then the view can still hold the page before). SimpCity's tracking scripts can keep a
        page from ever finishing loading, so one still loading after a while is read as it stands."""
        self.view.load(QUrl(url))
        self.last_page: dict = {}
        t0 = time.monotonic()

        def accept(r: dict) -> bool:
            self.last_page = r
            if r.get("error") or int(r.get("page") or 1) != n:
                return False
            return bool(r.get("posts")) or r.get("ready") == "complete" or \
                (r.get("ready") == "interactive" and time.monotonic() - t0 > 12)

        def checking() -> None:
            self.last_page = {"challenge": True}
            self._say("SimpCity is checking that a person is asking — answer it in the window below; the download "
                      "carries on by itself.")

        self._poll(self.view.page(), sc.EXTRACT_POSTS_JS, accept, cb, 90, on_challenge=checking)

    def _ask_login(self, cb) -> None:
        """No links on the first page and not logged in: SimpCity shows links to members only."""
        self.view.load(QUrl(LOGIN))
        self._say("SimpCity shows its links only to members. Log in below — the download starts again by itself.")
        self._log("Waiting for you to log in to SimpCity…")

        saw_login = [False]

        def check() -> None:
            self.view.page().runJavaScript(sc.LOGGED_IN_JS.strip(), 0, answer)

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
            page.runJavaScript(start.strip(), 0,
                               lambda _r: self._poll(page, read, lambda r: "status" in r, answered, 25, every=80))

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

    # -- file-host pages

    def _host_page(self, page: QWebEnginePage, url: str, cb) -> None:
        """A file host's folder page, read once its script has listed the files (`filehosts.HOST_PAGE_JS`):
        → its answer, or None when it never loaded."""
        page.load(QUrl(url))
        t0 = time.monotonic()
        path = QUrl(url).path().rstrip("/")

        def accept(r: dict) -> bool:
            if QUrl(str(r.get("href") or "")).path().rstrip("/") != path:
                return False                               # still the page before (another folder, maybe)
            listed = bool(r.get("files") or r.get("pages") or r.get("gone"))
            return (listed and time.monotonic() - t0 > 3) or (r.get("ready") == "complete" and time.monotonic() - t0 > 12)
        self._poll(page, fh.HOST_PAGE_JS, accept, cb, 60, on_challenge=lambda: self._show_check(url))

    def _host_file(self, page: QWebEnginePage, item: sc.Item, cb) -> None:
        """The video a file's page plays or links (→ (address, name)) — and when it shows none, its
        download button pressed: the page then plays it, links it, or starts a download, whose address
        is taken (`_download_requested`) and fetched like any other."""
        r = item.remote
        page.load(QUrl(r.page))
        t0 = [time.monotonic()]
        state = {"clicked": False, "done": False}

        def finish(got) -> None:
            if state["done"]:
                return
            state["done"] = True
            self.click_wait.pop(id(page), None)
            cb(got)

        def accept(x: dict) -> bool:
            # Only this file's own page counts (the lane can still show the file before it, on the same
            # host); once its button is pressed, wherever it went.
            if not state["clicked"] and r.fid.lower()[:8] not in str(x.get("href") or "").lower():
                return False
            return bool(x.get("files")) or bool(x.get("gone")) or \
                (x.get("ready") == "complete" and time.monotonic() - t0[0] > (8 if not state["clicked"] else 15))

        def shown(x) -> None:
            if state["done"]:
                return
            best = fh.best_file(x or {})
            if best:
                finish((best[0], best[1] or str((x or {}).get("name") or "")))
            elif x and not x.get("gone") and not state["clicked"]:
                state["clicked"] = True
                t0[0] = time.monotonic()
                self.click_wait[id(page)] = lambda url, name: finish((url, name or str(x.get("name") or "")))
                page.runJavaScript(sc.json_call(fh.CLICK_DOWNLOAD_JS), 0,
                                   lambda raw: self._poll(page, fh.HOST_PAGE_JS, accept, shown, 30)
                                   if sc.parse_result(raw).get("clicked") else finish(None))
            else:
                finish(None)
        self._poll(page, fh.HOST_PAGE_JS, accept, shown, 45, on_challenge=lambda: self._show_check(r.page))

    def _download(self, page: QWebEnginePage, url: str, item: sc.Item, ext: str, cb) -> None:
        """Into the Mac's temp folder: fetched directly first — the image server answers plain requests,
        and this is quick — then, if that's refused, by Chromium itself. A failure is logged with why
        and where (`_failed`), so a host that won't serve is visible. A video's size is checked as it
        starts (`simpcity.Dedup`): one already downloaded, or on its way from another host, is dropped
        there (→ `simpcity.Duplicate`), and a file-host link that answers with a photo or an archive is
        no video (→ `simpcity.NotVideo`)."""
        name = f"{item.stem}-{int(time.time() * 1000)}.{ext}"
        host = QUrl(url).host()
        r = item.remote
        # Qt objects belong to this (GUI) thread: everything the worker needs is read here.
        referer = sc.REFERER if host.endswith(sc.REFERER_HOSTS) else ((r.referer if r else "") or item.link)
        headers = {"User-Agent": self.ua, "Referer": referer,
                   "Accept": "image/avif,image/webp,image/*,video/*;q=0.9,*/*;q=0.8",
                   "Accept-Language": "en-US,en;q=0.9"}
        cookie = self._cookie_header(host)
        if r and r.headers.get("Cookie"):
            cookie = "; ".join(c for c in (cookie, r.headers["Cookie"]) if c)
        if r:
            headers.update({k: v for k, v in r.headers.items() if k != "Cookie"})
        if cookie:
            headers["Cookie"] = cookie
        check = self._checker(item)

        def direct_done(result) -> None:
            if isinstance(result, sc.Skip):
                cb(result)
                return
            path, why = result if isinstance(result, tuple) else (None, str(result))
            if path:
                cb(path)
                return
            if self.direct_noted < 3:
                self.direct_noted += 1
                self._log(f"{item.stem}: a plain download didn't work ({why}) — trying the browser.")
            self._browser_download(url, item, name, why, referer, check, cb)

        limit = 4 * 3600 if item.video else 600
        self.handle(("thread", lambda: sc.fetch(url, headers, os.path.join(str(self.tmp), name), limit=limit, check=check),
                     f"{item.stem} (downloading {url[:90]})"), direct_done)

    def _checker(self, item: sc.Item):
        """What a download's first answer is checked against (on a worker thread, or here for Chromium's)."""
        dedup = self.dedup

        def check(size: int | None, ctype: str) -> None:
            ctype = (ctype or "").lower()
            if item.remote and (ctype.startswith(("image/", "audio/", "text/")) or ctype in (
                    "application/zip", "application/x-zip-compressed", "application/x-rar-compressed",
                    "application/vnd.rar", "application/x-7z-compressed", "application/pdf")):
                raise sc.NotVideo(f"the host sent {ctype}")
            if item.video:
                other = dedup.claim(item.key, size)
                if other:
                    raise sc.Duplicate(other)
        return check

    def _browser_download(self, url: str, item: sc.Item, name: str, direct_why: str, referer: str, check, cb) -> None:
        """Chromium fetches it (for a server that turns plain requests away), started from the window's
        page and matched back by its address as well as its name. It's given up when it never starts, or
        when it stops moving for two minutes (a photo: two minutes in all)."""
        state = {"started": False, "done": False, "req": None, "got": -1}
        video = item.video or sc.is_video(name)

        def finish(path, why: str = "") -> None:
            if state["done"]:
                return
            state["done"] = True
            if not path and state["req"] is not None:
                try:
                    state["req"].cancel()
                except RuntimeError:
                    pass
            self.pending.pop(name, None)
            self.pending_urls.pop(url, None)
            self.referer.by_url.pop(url, None)
            if isinstance(path, sc.Skip):
                cb(path)
                return
            if not path:
                self._failed(item, url, f"{direct_why}; in the browser: {why or 'failed'}")
            cb(path)

        def requested(req) -> None:
            state["started"] = True
            state["req"] = req

        self.pending[name] = (finish, requested, check)
        self.pending_urls[url] = name
        if referer:
            self.referer.by_url[url] = referer
        if item.remote and item.remote.cookies:
            self._set_cookies(url, item.remote.cookies)
        self.view.page().download(QUrl(url), name)

        def watchdog() -> None:
            if not state["started"]:
                finish(None, "it never started")

        def moving() -> None:
            if state["done"]:
                return
            req = state["req"]
            got = req.receivedBytes() if req is not None else 0
            if not video or got <= state["got"]:
                finish(None, "it stopped" if video else "it took too long")
                return
            state["got"] = got
            QTimer.singleShot(120000, moving)
        QTimer.singleShot(20000, watchdog)
        QTimer.singleShot(120000, moving)

    def _set_cookies(self, url: str, cookies: dict[str, str]) -> None:
        """A host's cookies (gofile's guest account) into the browser, for its own download."""
        try:
            from PySide6.QtNetwork import QNetworkCookie
        except ImportError:
            return
        host = QUrl(url).host()
        domain = "." + ".".join(host.split(".")[-2:])
        store = profile().cookieStore()
        for k, v in cookies.items():
            c = QNetworkCookie(k.encode(), v.encode())
            c.setDomain(domain)
            c.setPath("/")
            c.setExpirationDate(QDateTime.currentDateTime().addDays(1))
            store.setCookie(c, QUrl(f"https://{host}/"))

    def _failed(self, item: sc.Item, url: str, why: str) -> None:
        host = QUrl(url).host() or "?"
        self.fail_hosts[host] = self.fail_hosts.get(host, 0) + 1
        self.fail_why[host] = why
        if self.fail_hosts[host] <= 3:                 # the first few per server; the summary counts the rest
            self._log(f"{item.stem}: couldn't download {url[:120]} — {why}")

    def _download_requested(self, req: QWebEngineDownloadRequest) -> None:
        page = req.page() if hasattr(req, "page") else None
        take = self.click_wait.pop(id(page), None) if page is not None else None
        if take is not None:
            # A file page's download button started this: its address is what the lane wanted.
            url, file = req.url().toString(), req.suggestedFileName() or req.downloadFileName()
            req.cancel()
            take(url, file)
            return
        name = self.pending_urls.get(req.url().toString())
        entry = self.pending.get(req.downloadFileName()) or self.pending.get(req.suggestedFileName()) \
            or (self.pending.get(name) if name else None)
        if entry is None:
            return                                   # someone's own download in the window — leave it alone
        finish, requested, check = entry
        requested(req)
        if check is not None:
            try:
                total = req.totalBytes()
                check(total if total and total > 0 else None, req.mimeType() or "")
            except sc.Skip as skip:
                finish(skip)
                return
        file = name or req.suggestedFileName() or req.downloadFileName()
        req.setDownloadDirectory(str(self.tmp))
        req.setDownloadFileName(file)
        path = os.path.join(str(self.tmp), req.downloadFileName())

        def changed(*_args) -> None:
            # An interrupted download can stay "resumable" and never count as finished (a 403 did): an
            # interruption or cancel ends it here too.
            states = QWebEngineDownloadRequest.DownloadState
            stopped = req.state() in (states.DownloadInterrupted, states.DownloadCancelled)
            if not req.isFinished() and not stopped:
                return
            ok = req.state() == states.DownloadCompleted
            html = (req.mimeType() or "").startswith("text/")
            if ok and not html and os.path.exists(path) and os.path.getsize(path) > 0:
                finish(path)
                return
            if ok:
                try:
                    os.remove(path)
                except OSError:
                    pass
            finish(None, "it sent a page, not the file" if html else (req.interruptReasonString() or "interrupted"))

        req.isFinishedChanged.connect(changed)
        req.stateChanged.connect(changed)
        req.accept()


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
