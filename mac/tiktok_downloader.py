#!/usr/bin/env python3
"""Safe Finder ▸ Download ▸ "Download TikTok Profile…" / "Get New TikTok Videos" — the window (tiktok.py reads
the profile, social.py downloads).

    python3 mac/tiktok_downloader.py "/Volumes/SSD/Jane" [handle]

Type a handle (or a profile link) and press Download: the profile's own videos come down watermark-free at
the highest quality offered, as `<post id>.mp4` (a slideshow's photos as `<post id>_<n>.jpg`) into the
`@handle` folder — the iPhone app's names and folder, so a profile the iPhone downloaded is carried on here
and only what's missing is fetched (tiktok.py says how such a folder is recognised). No login: only the
public handle goes out.

Every run lists the whole profile, so **every video's like count is read again** and saved in the folder's
record (`.tiktok.json`, shared with the iPhone app); sort the folder by "Reactions / Likes" to see them.

The listing runs on a worker thread (plain requests, about one a second — the resolver's limit); what it
finds goes straight to the downloads, four at a time. If the resolver's Cloudflare check stops the plain
requests, the same request is made in the small browser at the bottom of the window — it usually passes by
itself; if it shows a box to tick, tick it and the run carries on (its clearance is reused from then on).
Each file gets the post's date, caption and @handle, and the "tiktok" tag.
"""
from __future__ import annotations

import concurrent.futures
import json
import os
import sys
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from PySide6.QtCore import QObject, QSettings, Qt, QTimer, QUrl, Signal  # noqa: E402
from PySide6.QtWidgets import (QApplication, QHBoxLayout, QLabel, QLineEdit, QMainWindow, QMessageBox,  # noqa: E402
                               QPlainTextEdit, QProgressBar, QPushButton, QVBoxLayout, QWidget)

import simpcity as sc  # noqa: E402
import social  # noqa: E402
import tiktok as tt  # noqa: E402

try:                                                    # the browser is only for the resolver's bot check
    from PySide6.QtWebEngineCore import QWebEnginePage, QWebEngineProfile
    from PySide6.QtWebEngineWidgets import QWebEngineView
except ImportError:                                     # no Qt WebEngine: plain requests only
    QWebEngineView = None

LANES = 4                     # files downloaded at once
SAVE_EVERY = 20               # the record is saved (and the files tagged) after this many files
CHECK_AFTER = 8.0             # seconds of no answer in the browser before it's shown (a check to answer)
CHECK_LIMIT = 300.0           # …and how long the person has
QUIET_LIMIT = 45.0            # a browser read that isn't a check gives up after this

_PROFILE = None


def profile():
    """A lasting browser profile for tikwm.com, so its clearance survives restarts."""
    global _PROFILE
    if _PROFILE is None:
        _PROFILE = QWebEngineProfile("tiktok", QApplication.instance())
        _PROFILE.setPersistentCookiesPolicy(QWebEngineProfile.PersistentCookiesPolicy.ForcePersistentCookies)
    return _PROFILE


class _Bridge(QObject):
    call = Signal(object, object)      # (callback, value) from a worker thread → back on the GUI thread


class TikTokWindow(QMainWindow):
    """The downloader from one folder (the one right-clicked)."""

    finished = Signal(str, list)       # (the profile's folder, files written) — Safe Finder refreshes + tags

    def __init__(self, folder: str, start: str = "", tags=None, parent=None) -> None:
        super().__init__(parent)
        self.person = Path(folder)
        self.tags = tags
        self.running = self.stopping = False
        self.bridge = _Bridge()
        self.bridge.call.connect(lambda cb, value: cb(value))
        self.settings = QSettings("PhotoBrowser", "SafeFinder")
        self.exiftool = sc.find_exiftool()
        self.cookies: dict[str, str] = {}
        self.setWindowTitle(f"TikTok — {self.person.name}")
        self.resize(760, 560)

        known = tt.profile_of(self.person, on_disk=False)
        prefill = start or tt.default_handle(self.person) or \
            str(self.settings.value(f"tiktok/last/{self.person}", "") or "")
        self.field = QLineEdit(prefill)
        self.field.setPlaceholderText("tiktok handle (e.g. zachking) or profile link")
        self.field.returnPressed.connect(self.start)
        self.go_btn = QPushButton("Get New Videos" if known or tt.profiles_in(self.person) else "Download")
        self.go_btn.setDefault(True)
        self.go_btn.clicked.connect(self.start)
        self.stop_btn = QPushButton("Stop")
        self.stop_btn.setEnabled(False)
        self.stop_btn.clicked.connect(self.stop)
        top = QHBoxLayout()
        top.addWidget(QLabel("Profile:  @"))
        top.addWidget(self.field, 1)
        top.addWidget(self.go_btn)
        top.addWidget(self.stop_btn)
        where = "this folder" if known else f"an “@handle” folder inside “{self.person.name}”"
        self.status = QLabel(f"Downloads this profile's own videos into {where} — only the ones that aren't there "
                             "yet — watermark-free at the highest quality offered, tagged “tiktok”. Every run "
                             "reads each video's like count again. Only the public handle is sent out.")
        self.status.setWordWrap(True)
        self.bar = QProgressBar()
        self.bar.setVisible(False)
        self.bar.setFixedWidth(220)
        self.bar.setFormat("%v of %m")
        self.log = QPlainTextEdit()
        self.log.setReadOnly(True)
        self.log.setMaximumBlockCount(5000)
        box = QWidget()
        lay = QVBoxLayout(box)
        lay.addLayout(top)
        progress = QHBoxLayout()
        progress.addWidget(self.status, 1)
        progress.addWidget(self.bar, 0, Qt.AlignmentFlag.AlignVCenter)
        lay.addLayout(progress)
        lay.addWidget(self.log, 1)
        self.view = None
        self.agent = ""
        if QWebEngineView is not None:
            prof = profile()
            self.agent = prof.httpUserAgent()
            prof.cookieStore().cookieAdded.connect(self._cookie_added)
            prof.cookieStore().loadAllCookies()
            self.view = QWebEngineView()
            self.view.setPage(QWebEnginePage(prof, self.view))
            self.view.setMinimumHeight(320)
            self.view.setVisible(False)                 # shown only when the resolver wants a check answered
            lay.addWidget(self.view, 2)
        self.setCentralWidget(box)
        if not self.exiftool:
            self._log("ExifTool isn't installed, so the post's date only goes on the file's dates and no caption "
                      "goes into the files (install it with: brew install exiftool).")
        if known is not None:
            how = {"record": "its record", "iphone": "the iPhone app's backup on the drive",
                   "names": "its name and the videos in it"}[known.source]
            self._log(f"This is @{known.handle}'s TikTok folder (known from {how}).")

    # ------------------------------------------------------------------ small things
    def _log(self, line: str) -> None:
        if line == getattr(self, "_last_line", None):
            return
        self._last_line = line
        self.log.appendPlainText(time.strftime("%H:%M:%S ") + line)

    def _say(self, line: str) -> None:
        self.status.setText(line)

    def _cookie_added(self, cookie) -> None:
        if cookie.domain().lstrip(".").endswith("tikwm.com"):
            self.cookies[cookie.name().data().decode("latin-1")] = cookie.value().data().decode("latin-1")

    def _shown(self, p: Path) -> str:
        try:
            return str(p.relative_to(self.person.parent))
        except ValueError:
            return str(p)

    # ------------------------------------------------------------------ the browser, for the resolver's check
    def _browser(self, url: str) -> tuple[dict | None, str, str]:
        """Called on the worker thread: the same request made in the window's browser. Blocks until it has
        the answer, the person stops, or it gives up. → (JSON or None, the cookies for tikwm.com, the agent)."""
        done = threading.Event()
        holder: dict = {}
        self.bridge.call.emit(lambda _v: self._browse(url, holder, done), None)
        while not done.wait(0.25):
            if self.stopping:
                self.bridge.call.emit(lambda _v: self._browse_end(holder, done, None), None)
                done.wait(5)
                break
        cookie = "; ".join(f"{k}={v}" for k, v in self.cookies.items())
        return holder.get("json"), cookie, self.agent

    def _browse(self, url: str, holder: dict, done: threading.Event) -> None:
        started = time.monotonic()
        holder["shown"] = False
        self.view.load(QUrl(url))

        def poll() -> None:
            if done.is_set():
                return
            waited = time.monotonic() - started
            if waited > (CHECK_LIMIT if holder["shown"] else QUIET_LIMIT + CHECK_AFTER):
                self._browse_end(holder, done, None)
                return

            def got(text) -> None:
                if done.is_set():
                    return
                obj = None
                if isinstance(text, str) and text.lstrip().startswith("{"):
                    try:
                        obj = json.loads(text)
                    except ValueError:
                        obj = None
                if isinstance(obj, dict):
                    self._browse_end(holder, done, obj)
                    return
                looks_checked = isinstance(text, str) and any(w in text.lower() for w in (
                    "verify", "human", "checking", "just a moment", "cloudflare", "captcha"))
                if not holder["shown"] and (waited > CHECK_AFTER and looks_checked):
                    holder["shown"] = True
                    self.resolver.waiting_for_person = True
                    self.view.setVisible(True)
                    self.resize(max(self.width(), 900), max(self.height(), 860))
                    self._say("tikwm.com — the service that lists a profile's videos — wants a quick check that "
                              "a person is here. Answer it in the page below; the download then carries on by itself.")
                    self._log("   the resolver is asking for a check — answer it in the page below")
                    self.raise_()
                QTimer.singleShot(700, poll)
            self.view.page().runJavaScript("document.body ? document.body.innerText : ''", 0, got)
        QTimer.singleShot(900, poll)

    def _browse_end(self, holder: dict, done: threading.Event, obj) -> None:
        if done.is_set():
            return
        holder["json"] = obj
        if holder.get("shown"):
            self.view.setVisible(False)
            if obj is not None:
                self._log("   the check was passed")
                self.resolver.waiting_for_person = False
        done.set()

    # ------------------------------------------------------------------ run / stop
    def start(self) -> None:
        if self.running:
            return
        handle = tt.clean_handle(self.field.text())
        if not handle:
            QMessageBox.information(self, "TikTok", "Type the TikTok handle to download.")
            return
        self.field.setText(handle)
        self.settings.setValue(f"tiktok/last/{self.person}", handle)
        self.handle = handle
        self.running, self.stopping = True, False
        self.go_btn.setEnabled(False)
        self.field.setEnabled(False)
        self.stop_btn.setEnabled(True)
        self.bar.setVisible(True)
        self.bar.setRange(0, 0)
        self.queued = self.settled_n = self.failed = self.present = 0
        self.photos = self.videos = 0
        self.written: list[str] = []
        self.to_tag: list[str] = []
        self.done_keys: set[str] = set()
        self.failed_keys: set[str] = set()
        self.key_left: dict[str, int] = {}
        self.futures: list[concurrent.futures.Future] = []
        self._saved_counts = (0, 0)
        self.outcome: tt.Outcome | None = None
        self.listed = False
        self.dest = tt.destination(self.person, handle)
        self.record = tt.record(self.dest)
        self.on_disk = tt.ids_on_disk(self.dest)
        known = tt.profile_of(self.dest, on_disk=False)
        self.already = (known.ids if known is not None else set()) | set(self.record.downloaded) | self.on_disk
        self._log(f"@{handle} → “{self._shown(self.dest)}” — {len(self.already)} video(s) already here")
        self.exif = sc.ExifSession(self.exiftool) if self.exiftool else None
        self.pool = concurrent.futures.ThreadPoolExecutor(max_workers=LANES, thread_name_prefix="tiktok-dl")
        self.opts = social.Options()
        self.resolver = tt.Resolver(browser=self._browser if self.view is not None else None,
                                    stop=lambda: self.stopping)
        if self.cookies.get("cf_clearance"):             # a clearance from an earlier run: the plain requests' too
            self.resolver.cookie = "; ".join(f"{k}={v}" for k, v in self.cookies.items())
            self.resolver.agent = self.agent
        self._say(f"Finding @{handle}'s videos…")
        threading.Thread(target=self._list, daemon=True, name="tiktok-list").start()

    def _list(self) -> None:
        try:
            outcome = tt.run(self.resolver, self.handle, self.dest, self.already,
                             emit=lambda items: self.bridge.call.emit(self._queue_all, items),
                             progress=lambda s: self.bridge.call.emit(self._progress, s))
            self.bridge.call.emit(self._listed, outcome)
        except Exception as e:  # noqa: BLE001 — a bug or a drive error must end the run, not hang it
            self.bridge.call.emit(self._listed, e)

    def _progress(self, line: str) -> None:
        if not self.queued:
            self._say(line)

    def _queue_all(self, items: list[social.Item]) -> None:
        if self.stopping:
            return
        for item in items:
            self.queued += 1
            self.key_left[item.key] = self.key_left.get(item.key, 0) + 1
            fut = self.pool.submit(social.settle, item, self.resolver.media_headers(), self.opts, self.exif,
                                   None, None, tt.fetcher)
            self.futures.append(fut)
            fut.add_done_callback(lambda f: self.bridge.call.emit(self._settled, f))
        self.bar.setRange(0, self.queued)

    def _settled(self, fut) -> None:
        s: social.Settled | None = None
        if not fut.cancelled():
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
                self.to_tag.append(s.path)
                self.done_keys.add(s.item.key)
            else:
                self.failed += 1
                self.failed_keys.add(s.item.key)
                self._log(f"   couldn't download {s.item.filename}: {s.why}")
        self.settled_n += 1
        self.bar.setValue(self.settled_n)
        self._say(f"Downloaded {len(self.written)} of {self.queued} found" +
                  (f" · {self.failed} failed" if self.failed else "") + ("" if self.listed else " · still looking…"))
        if len(self.to_tag) >= SAVE_EVERY:
            self._save()
        if self.listed and self.settled_n >= self.queued:
            self._finish()

    def _save(self, final: bool = False) -> tuple[int, int]:
        """The tags and the record, so far (the likes go in once the listing is done)."""
        if self.tags is not None and self.to_tag:
            try:
                self.tags.add(self.to_tag, [tt.TAG])
            except OSError as e:
                self._log(f"Couldn't save the tags: {e}")
        self.to_tag = []
        done = {k for k in self.done_keys if self.key_left.get(k, 0) <= 0} - self.failed_keys
        found = final and self.outcome is not None and not self.outcome.failed and self.outcome.total > 0
        if not (done or self.on_disk or self.record.exists or found):
            return 0, 0                                  # nothing here and nothing found: no record for a typo
        try:
            got = tt.save_record(self.record, done | self.on_disk, self.photos - self._saved_counts[0],
                                 self.videos - self._saved_counts[1], self.outcome if final else None, self.handle)
            self._saved_counts = (self.photos, self.videos)
            return got
        except OSError as e:
            self._log(f"Couldn't save the record: {e}")
            return 0, 0

    def _listed(self, outcome) -> None:
        self.listed = True
        if isinstance(outcome, Exception):
            self._log(f"Stopped: {type(outcome).__name__}: {outcome}")
        else:
            self.outcome = outcome
            if outcome.nickname:
                self._log(f"@{self.handle} — {outcome.nickname}, {outcome.total} video(s) on the profile"
                          + ("" if outcome.complete else " (so far)"))
            if outcome.note and (outcome.queued == 0 or not outcome.complete):
                self._log(outcome.note)
        if self.settled_n >= self.queued:
            self._finish()
        else:
            self._say(f"Found everything — {self.queued - self.settled_n} file(s) still downloading…")

    def stop(self) -> None:
        if self.running:
            self.stopping = True
            for f in getattr(self, "futures", []):
                f.cancel()
            self._say("Stopping after the files in hand…")
            QTimer.singleShot(400, self._stop_check)

    def _stop_check(self) -> None:
        if self.running and self.listed and all(f.done() for f in self.futures):
            self._finish()
        elif self.running:
            QTimer.singleShot(400, self._stop_check)

    def closeEvent(self, event) -> None:  # noqa: N802 — Qt override
        if self.running:
            if QMessageBox.question(self, "TikTok", "A download is running. Stop it and close?") \
                    != QMessageBox.StandardButton.Yes:
                event.ignore()
                return
            self.stopping = True
        super().closeEvent(event)

    def _finish(self) -> None:
        if not self.running:
            return
        self.running = False
        self.pool.shutdown(wait=False, cancel_futures=True)
        known, changed = self._save(final=True)
        if self.exif is not None:
            self.exif.close()
        o = self.outcome
        name = f"@{self.handle}"
        if o is None or o.failed:
            line = (o.note if o is not None and o.note else f"Couldn't read {name}.")
        elif self.stopping:
            line = f"{name}: stopped — {len(self.written)} downloaded."
        elif not self.written:
            line = f"{name}: " + ((o.note or "nothing new.") if not self.failed else
                                  f"{self.failed} file(s) couldn't be downloaded — run it again.")
        else:
            line = (f"{name}: downloaded {self.videos} video{'s' if self.videos != 1 else ''}"
                    + (f" and {self.photos} photo{'s' if self.photos != 1 else ''}" if self.photos else "")
                    + (f" · {self.failed} couldn't be" if self.failed else "") + ".")
        if o is not None and o.stats:
            line += (f" Likes read again for {len(o.stats):,} video{'s' if len(o.stats) != 1 else ''}"
                     f" ({changed:,} changed).")
        self._log(line)
        self._say(line)
        self.go_btn.setEnabled(True)
        self.field.setEnabled(True)
        self.stop_btn.setEnabled(False)
        self.bar.setVisible(False)
        if self.record.exists:
            self.go_btn.setText("Get New Videos")
        self.finished.emit(str(self.dest), list(self.written))


def main() -> None:
    if len(sys.argv) < 2:
        sys.exit("usage: tiktok_downloader.py <folder> [handle]")
    app = QApplication(sys.argv[:1])
    win = TikTokWindow(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else "")
    win.show()
    sys.exit(app.exec())


if __name__ == "__main__":
    main()
