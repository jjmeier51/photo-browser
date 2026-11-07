#!/usr/bin/env python3
"""Safe Finder ▸ "Download from Fanfix…" — the window (fanfix.py reads what Fanfix's page loads, social.py
downloads).

    python3 mac/fanfix_downloader.py "/Volumes/SSD/Jane" [creator]

For creators the person subscribes to or bought from: their own purchased content, saved to the drive for a
personal archive. The window is a real Chromium (Qt WebEngine) with its own lasting profile: log in to Fanfix
there once (and answer Cloudflare's check there when it asks) — it never fills in a login or answers a check
itself. Open a creator's page (or Messages, or your purchases) and press Download: the page is loaded afresh,
scrolled to its end so it loads everything, and every photo and video in what it loaded that this account can
see is downloaded into the creator's folder (`<folder>/<creator>`, or the folder itself when it's the
creator's), named by Fanfix's media id, dated from the post, captioned, tagged "fanfix" in the shared tag store.
Locked posts' teasers are left out, and so are videos protected by DRM. The creator's folder's `.fanfix.json`
keeps the ids, so the next run takes only what's new.

The page scrolls in front of the person — what it reads is what they see. Downloads run as the page goes
(six at a time, on worker threads: `social.settle`), so links that expire are used while they're fresh.
"""
from __future__ import annotations

import concurrent.futures
import json
import sys
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from PySide6.QtCore import QObject, QSettings, Qt, QTimer, QUrl, Signal  # noqa: E402
from PySide6.QtWidgets import (QApplication, QCheckBox, QHBoxLayout, QLabel, QLineEdit, QMainWindow,  # noqa: E402
                               QMessageBox, QPlainTextEdit, QProgressBar, QPushButton, QVBoxLayout, QWidget)
from PySide6.QtWebEngineCore import QWebEnginePage, QWebEngineProfile, QWebEngineScript  # noqa: E402
from PySide6.QtWebEngineWidgets import QWebEngineView  # noqa: E402

import fanfix  # noqa: E402
import simpcity as sc  # noqa: E402
import social  # noqa: E402

LANES = 6                     # files downloaded at once
SAVE_EVERY = 25               # the records are saved (and the files tagged) after this many files
TICK_MS = 1200                # one scroll step (and one look at what the page loaded) every this often
IDLE_TICKS = 7                # this many steps with no new height and nothing new loaded: the end of the page
MAX_MINUTES = 90              # a page that never ends is left after this
KEEP_CHARS = 60_000_000       # what the page loaded, kept for a troubleshooting file (the last run's)

_PROFILE: QWebEngineProfile | None = None


def profile() -> QWebEngineProfile:
    """Fanfix's own lasting browser profile (its login survives restarts), with the watching script put into
    every page before the page's own (`fanfix.HOOK_JS`)."""
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
        self.running = self.stopping = False
        self.cookies: dict[str, dict[str, str]] = {}
        self.bridge = _Bridge()
        self.bridge.call.connect(lambda cb, value: cb(value))
        self.settings = QSettings("PhotoBrowser", "SafeFinder")
        self.exiftool = sc.find_exiftool()
        self.captured: list[dict] = []
        self.setWindowTitle(f"Fanfix — {self.person.name}")
        self.resize(1100, 880)

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
        self._typed = bool(start)
        self.go_btn = QPushButton("Download from This Page")
        self.go_btn.setDefault(True)
        self.go_btn.setToolTip("Loads the page afresh, scrolls it to the end, and downloads every photo and video on "
                               "it that your account can see")
        self.go_btn.clicked.connect(self.start)
        self.stop_btn = QPushButton("Stop")
        self.stop_btn.setEnabled(False)
        self.stop_btn.clicked.connect(self.stop)
        open_btn = QPushButton("Open Creator")
        open_btn.setToolTip("Opens the creator's page on Fanfix")
        open_btn.clicked.connect(self.open_creator)

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
        self.trouble_btn.setToolTip("Writes what the page loaded in the last run to a file in ~/Library/Logs/Safe "
                                    "Finder — for when something you can see wasn't downloaded")
        self.trouble_btn.clicked.connect(self.save_troubleshooting)
        self.trouble_btn.setEnabled(False)

        top = QHBoxLayout()
        top.addWidget(QLabel("Creator:"))
        top.addWidget(self.field, 1)
        top.addWidget(open_btn)
        top.addWidget(self.go_btn)
        top.addWidget(self.stop_btn)
        row2 = QHBoxLayout()
        for w in (self.photos_2x, self.ai, self.videos_1080):
            row2.addWidget(w)
        row2.addStretch(1)
        row2.addWidget(self.trouble_btn)
        row2.addWidget(login)
        self.status = QLabel("Log in to Fanfix below if you haven't, open a creator's page (or Messages, or your "
                             f"purchases) and press Download. Files go into a folder for the creator inside "
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
        self.view.load(QUrl(fanfix.HOME + handle if handle else fanfix.HOME))
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
        """The person's Fanfix cookies — sent only to Fanfix's own hosts (fanfix.tries_for)."""
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
            self.view.load(QUrl(fanfix.HOME + handle))

    def _shown(self, p: Path) -> str:
        try:
            return str(p.relative_to(self.person.parent))
        except ValueError:
            return str(p)

    # ------------------------------------------------------------------ run / stop
    def start(self) -> None:
        if self.running:
            return
        url = self.view.url().toString()
        if not fanfix.fanfix_host(url) or url.rstrip("/").endswith("/login"):
            QMessageBox.information(self, "Fanfix", "Open a creator's page on Fanfix first (log in if you haven't) — "
                                    "or Messages, or your purchases.")
            return
        self.hint = fanfix.clean_handle(self.field.text()) or fanfix.creator_from_url(url)
        if self.hint:
            self.field.setText(self.hint)
        self.running, self.stopping = True, False
        self.started = time.monotonic()
        self.opts = social.Options(photos_2x=self.photos_2x.isChecked(),
                                   ai=self.ai.isChecked() and self.engine is not None and self.photos_2x.isChecked(),
                                   videos_1080=self.videos_1080.isChecked())
        for w in (self.go_btn, self.photos_2x, self.ai, self.videos_1080, self.field, self.trouble_btn):
            w.setEnabled(False)
        self.stop_btn.setEnabled(True)
        self.bar.setVisible(True)
        self.bar.setRange(0, 0)
        self.haul = fanfix.Haul()
        self.queued = self.settled_n = self.failed = self.present = self.drm = 0
        self.photos = self.videos = 0
        self.undated = 0
        self.written: list[str] = []
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
        self.kept_chars = 0
        self.responses = 0
        self.idle = 0
        self.last_state: dict = {}
        self.crawl_done = False
        self.exif = sc.ExifSession(self.exiftool) if self.exiftool else None
        self.heavy = threading.Lock()
        self.pool = concurrent.futures.ThreadPoolExecutor(max_workers=LANES, thread_name_prefix="fanfix-dl")
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
        """One step: what the page loaded since the last step taken and read, then the page scrolled on."""
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
        if (time.monotonic() - self.started) / 60 > MAX_MINUTES:
            self._log(f"Still going after {MAX_MINUTES} minutes — stopping here.")
            self._crawl_end()
            return
        self.view.page().runJavaScript(fanfix.SCROLL_JS, 0, lambda r: self._scrolled(r, got))

    def _read_answers(self, raw) -> int:
        """Reads the answers the page received (fanfix.extract) and queues what's new. Returns how many."""
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
            if self.kept_chars + len(a["t"]) <= KEEP_CHARS:
                self.captured.append({"url": a.get("u", ""), "body": a["t"]})
                self.kept_chars += len(a["t"])
            before = set(self.haul.found)
            fanfix.extract_text(a["t"], self.haul)
            for key in set(self.haul.found) - before:
                self._queue(self.haul.found[key])
        return len(answers)

    def _scrolled(self, raw, got: int) -> None:
        if not self.running:
            return
        try:
            state = json.loads(raw) if isinstance(raw, str) else {}
        except ValueError:
            state = {}
        grew = state.get("height") != self.last_state.get("height") or bool(state.get("moved"))
        self.last_state = state
        self.idle = 0 if (grew or got) else self.idle + 1
        if state and not state.get("hooked"):
            self._log("The page wasn't being watched — loading it again.")
            self.view.loadFinished.connect(self._reloaded)
            self.view.reload()
            return
        self._say(f"Scrolling… {self.responses} answer(s) read · {len(self.haul.found)} photo(s)/video(s) found · "
                  f"{len(self.written)} downloaded")
        if self.idle >= IDLE_TICKS:
            # the end: one last look at what came in, then the page itself if its data named nothing
            self.view.page().runJavaScript(fanfix.DRAIN_JS, 0, lambda r: (self._read_answers(r), self._last_look()))
            return
        QTimer.singleShot(TICK_MS, self._tick)

    def _last_look(self) -> None:
        if self.haul.found or not self.running:
            self._crawl_end()
            return
        self.view.page().runJavaScript(fanfix.DOM_JS, 0, self._dom)

    def _dom(self, raw) -> None:
        try:
            shown = json.loads(raw) if isinstance(raw, str) else []
        except ValueError:
            shown = []
        if isinstance(shown, list) and shown:
            before = set(self.haul.found)
            fanfix.from_page([m for m in shown if isinstance(m, dict)], self.haul)
            new = set(self.haul.found) - before
            if new:
                self._log(f"The page's data named no media — taking the {len(new)} picture(s)/video(s) it shows.")
            for key in new:
                self._queue(self.haul.found[key])
        self._crawl_end()

    def stop(self) -> None:
        if self.running:
            self.stopping = True
            for f in getattr(self, "futures", []):
                f.cancel()                                 # not started yet: left for the next run
            self._say("Stopping after the files in hand…")

    def closeEvent(self, event) -> None:  # noqa: N802 — Qt override
        if self.running:
            if QMessageBox.question(self, "Fanfix", "A download is running. Stop it and close?") \
                    != QMessageBox.StandardButton.Yes:
                event.ignore()
                return
            self.stopping = True
            self._finish("Stopped.")
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
        fut = self.pool.submit(social.settle, item, [], self.opts, self.exif, self.engine, self.heavy,
                               fanfix.fetcher(self.ua, self.cookie_header()))
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
            else:
                self.failed += 1
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
        self._save()
        if self.exif is not None:
            self.exif.close()
        who = self.hint or "Fanfix"
        h = self.haul
        if problem:
            line = problem
        elif not self.responses:
            line = ("The page loaded no data to read — is it a creator's page, and are you logged in? If you can see "
                    "posts there, press Save Troubleshooting File and send it over.")
        elif not h.found:
            line = (f"{who}: nothing to download on this page" +
                    (f" — {h.locked} locked post item(s) need buying first." if h.locked else
                     ". If you can see posts here, press Save Troubleshooting File and send it over."))
        elif not self.written:
            line = f"{who}: nothing new" + (f" ({self.present} already here)" if self.present else "") + "."
        else:
            line = (f"{who}: downloaded {self.photos} photo{'s' if self.photos != 1 else ''} and {self.videos} "
                    f"video{'s' if self.videos != 1 else ''}" + (f" · {self.failed} couldn't be" if self.failed else "")
                    + ".")
            if self.undated:
                line += (f" {self.undated} had no date on Fanfix — {'they keep' if self.undated != 1 else 'it keeps'} "
                         "the download date.")
        if self.drm:
            line += f" {self.drm} video{'s' if self.drm != 1 else ''} protected by DRM left out."
        if h.locked and h.found:
            line += f" {h.locked} locked item{'s' if h.locked != 1 else ''} (not bought) left out."
        self._log(line)
        self._say(line)
        for w in (self.go_btn, self.photos_2x, self.videos_1080, self.field):
            w.setEnabled(True)
        self.ai.setEnabled(self.photos_2x.isChecked())
        self.trouble_btn.setEnabled(bool(self.captured))
        self.stop_btn.setEnabled(False)
        self.bar.setVisible(False)
        self.finished.emit(str(self.person), list(self.written))

    # ------------------------------------------------------------------ troubleshooting
    def save_troubleshooting(self) -> None:
        """What the page loaded in the last run, to ~/Library/Logs/Safe Finder — stays on this Mac."""
        if not self.captured:
            return
        folder = Path.home() / "Library" / "Logs" / "Safe Finder"
        try:
            folder.mkdir(parents=True, exist_ok=True)
            path = folder / f"fanfix-{time.strftime('%Y%m%d-%H%M%S')}.json"
            h = getattr(self, "haul", fanfix.Haul())
            doc = {"page": self.view.url().toString(), "found": len(h.found), "locked": h.locked,
                   "profile_pictures": h.profile, "answers": self.captured}
            path.write_text(json.dumps(doc, ensure_ascii=False), encoding="utf-8")
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
