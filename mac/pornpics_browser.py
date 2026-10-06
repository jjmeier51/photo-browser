#!/usr/bin/env python3
"""PornPics Browser — the gallery downloader with a built-in web browser (PySide6 / QtWebEngine).

Browse pornpics.com normally; whenever the page you're on is a gallery
(`https://www.pornpics.com/galleries/<name>-<id>/`) the **Download Gallery** button lights up
with the photo count. One click queues it — keep browsing while it downloads. You can also
right-click any gallery link and choose "Download Linked Gallery" without opening it.

Downloading reuses `pornpics_downloader.py` (same folder naming, skip-existing, .part files,
retries), so both tools fill the same folders and a re-download only fetches what's missing.
The gallery's own HTML is taken from the browser's live page when you click on an open
gallery, so whatever the browser can see (cookie/age gates already passed) is what's parsed.

Galleries are processed one at a time on a background thread; the page stays responsive.
Cookies and history live in a persistent profile, so the age/consent prompts only show once.

Run:  python3 pornpics_browser.py [START_URL]
      (needs PySide6 — `mac/run.sh` creates mac/.venv with it, then
       `mac/.venv/bin/python mac/pornpics_browser.py`)
"""

from __future__ import annotations

import os
import queue
import subprocess
import sys
import threading
import urllib.parse
from dataclasses import dataclass, field
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from pornpics_downloader import (  # noqa: E402 — the shared download logic lives next door
    GALLERY_RE,
    download_gallery,
    gallery_id_from_url,
    gallery_name_from_url,
    photo_urls,
    safe_folder_name,
)

try:
    from PySide6.QtCore import QObject, QSettings, Qt, QUrl, Signal
    from PySide6.QtGui import QAction, QKeySequence
    from PySide6.QtWebEngineCore import QWebEnginePage, QWebEngineProfile
    from PySide6.QtWebEngineWidgets import QWebEngineView
    from PySide6.QtWidgets import (
        QApplication, QFileDialog, QHBoxLayout, QLabel, QLineEdit, QMainWindow, QPlainTextEdit,
        QPushButton, QSplitter, QToolBar, QTreeWidget, QTreeWidgetItem, QVBoxLayout, QWidget,
    )
except ModuleNotFoundError as e:  # pragma: no cover
    sys.exit(f"{e}\nThe built-in browser needs PySide6 (with QtWebEngine): pip install PySide6\n"
             "or run mac/run.sh once and use mac/.venv/bin/python.")

HOME_URL = "https://www.pornpics.com/"
DEFAULT_DEST = Path.home() / "Pictures" / "PornPics"
IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".webp", ".gif"}


def normalized_gallery_url(url: str) -> str | None:
    """Gallery URL without query/fragment, or None if `url` isn't a gallery."""
    if not GALLERY_RE.match(url.strip()):
        return None
    parts = urllib.parse.urlsplit(url.strip())
    path = parts.path if parts.path.endswith("/") else parts.path + "/"
    return urllib.parse.urlunsplit((parts.scheme, parts.netloc, path, "", ""))


def files_present(folder: Path) -> int:
    try:
        return sum(1 for p in folder.iterdir() if p.suffix.lower() in IMAGE_EXTS and p.stat().st_size > 0)
    except OSError:
        return 0


# ----------------------------------------------------------------------------- download queue


@dataclass
class Job:
    url: str
    gallery_id: str
    name: str
    dest: Path
    page: str | None = None  # live DOM HTML when the gallery was open in the browser
    item: QTreeWidgetItem | None = field(default=None, repr=False)


class Downloader(QObject):
    """One background thread draining a queue of galleries; reports back through Qt signals,
    which Qt delivers on the GUI thread (queued connection) because the receivers live there."""

    log = Signal(str)
    started = Signal(object)                    # Job
    progress = Signal(object, int, int, str)    # Job, done, total, filename
    finished = Signal(object, object, str)      # Job, (saved, skipped, failed, stopped) | None, error

    def __init__(self) -> None:
        super().__init__()
        self.jobs: queue.Queue[Job] = queue.Queue()
        self.stop = threading.Event()
        self.active: set[str] = set()  # gallery ids queued or running
        self._lock = threading.Lock()
        threading.Thread(target=self._run, daemon=True).start()

    def enqueue(self, job: Job) -> bool:
        with self._lock:
            if job.gallery_id in self.active:
                return False
            self.active.add(job.gallery_id)
        self.jobs.put(job)
        return True

    def is_active(self, gallery_id: str | None) -> bool:
        with self._lock:
            return gallery_id in self.active

    def cancel_all(self) -> list[Job]:
        """Stop the running gallery and drop everything still waiting; returns the dropped jobs."""
        dropped: list[Job] = []
        while True:
            try:
                dropped.append(self.jobs.get_nowait())
            except queue.Empty:
                break
        with self._lock:
            for j in dropped:
                self.active.discard(j.gallery_id)
        self.stop.set()
        return dropped

    def _run(self) -> None:
        while True:
            job = self.jobs.get()
            self.stop.clear()
            self.started.emit(job)
            result, error = None, ""
            try:
                result = download_gallery(
                    job.url, job.dest, job.name,
                    log=lambda s, j=job: self.log.emit(f"[{j.name}] {s.strip()}"),
                    progress=lambda d, t, n, j=job: self.progress.emit(j, d, t, n),
                    stop=self.stop, page=job.page) + (self.stop.is_set(),)
            except Exception as e:  # noqa: BLE001 — surfaced in the job row and log
                error = str(e) or e.__class__.__name__
            job.page = None
            with self._lock:
                self.active.discard(job.gallery_id)
            self.finished.emit(job, result, error)


# ----------------------------------------------------------------------------- browser


class BrowserView(QWebEngineView):
    """Keeps target=_blank links in this view and adds "Download Linked Gallery" to the context menu."""

    download_link = Signal(str)

    def createWindow(self, _type):  # noqa: N802 — Qt override
        return self

    def contextMenuEvent(self, event):  # noqa: N802 — Qt override
        menu = self.createStandardContextMenu()
        link = self.lastContextMenuRequest().linkUrl().toString()
        if normalized_gallery_url(link):
            act = QAction("Download Linked Gallery", menu)
            act.triggered.connect(lambda: self.download_link.emit(link))
            first = menu.actions()[0] if menu.actions() else None
            menu.insertAction(first, act)
            if first:
                menu.insertSeparator(first)
        menu.setAttribute(Qt.WidgetAttribute.WA_DeleteOnClose)
        menu.popup(event.globalPos())


class MainWindow(QMainWindow):
    def __init__(self, start_url: str) -> None:
        super().__init__()
        self.setWindowTitle("PornPics Browser")
        self.resize(1280, 900)
        self.settings = QSettings("PhotoBrowser", "PornPicsBrowser")
        self.dest = Path(str(self.settings.value("dest", str(DEFAULT_DEST))))
        self.photo_count: dict[str, int] = {}  # gallery url → photos found in the open page

        self.downloader = Downloader()
        self.downloader.log.connect(self._log)
        self.downloader.started.connect(self._job_started)
        self.downloader.progress.connect(self._job_progress)
        self.downloader.finished.connect(self._job_finished)

        # Persistent named profile: cookies (age gate, consent) survive restarts. Parented to the
        # app, not the window, so it outlives the page (Qt warns if a profile dies first).
        self.profile = QWebEngineProfile("pornpics", QApplication.instance())
        self.profile.setPersistentCookiesPolicy(QWebEngineProfile.PersistentCookiesPolicy.ForcePersistentCookies)
        self.view = BrowserView()
        self.view.setPage(QWebEnginePage(self.profile, self.view))
        self.view.download_link.connect(self._download_link)
        self.view.urlChanged.connect(self._url_changed)
        self.view.loadFinished.connect(self._load_finished)
        self.view.titleChanged.connect(lambda t: self.setWindowTitle(f"{t} — PornPics Browser" if t else "PornPics Browser"))

        self._build_toolbar()
        self._build_panel()
        self.view.load(QUrl(start_url))

    # -- layout
    def _build_toolbar(self) -> None:
        tb = QToolBar("Navigation")
        tb.setMovable(False)
        self.addToolBar(tb)
        page = self.view.page()
        for action, shortcut in ((QWebEnginePage.WebAction.Back, QKeySequence.StandardKey.Back),
                                 (QWebEnginePage.WebAction.Forward, QKeySequence.StandardKey.Forward),
                                 (QWebEnginePage.WebAction.Reload, QKeySequence.StandardKey.Refresh)):
            a = page.action(action)
            a.setShortcut(QKeySequence(shortcut))
            tb.addAction(a)
        home = QAction("Home", self)
        home.triggered.connect(lambda: self.view.load(QUrl(HOME_URL)))
        tb.addAction(home)

        self.address = QLineEdit()
        self.address.setPlaceholderText("Address or search")
        self.address.returnPressed.connect(self._go)
        tb.addWidget(self.address)
        focus = QAction(self)
        focus.setShortcut(QKeySequence("Ctrl+L"))
        focus.triggered.connect(lambda: (self.address.setFocus(), self.address.selectAll()))
        self.addAction(focus)

        self.dl_btn = QPushButton("Download Gallery")
        self.dl_btn.setShortcut(QKeySequence("Ctrl+D"))
        self.dl_btn.setToolTip("Queue the gallery you're viewing (⌘D / Ctrl+D)")
        self.dl_btn.setEnabled(False)
        self.dl_btn.setMinimumWidth(230)
        self.dl_btn.clicked.connect(self._download_current)
        tb.addWidget(self.dl_btn)

    def _build_panel(self) -> None:
        panel = QWidget()
        lay = QVBoxLayout(panel)
        lay.setContentsMargins(8, 6, 8, 6)

        row = QHBoxLayout()
        row.addWidget(QLabel("Save into:"))
        self.dest_label = QLabel(str(self.dest))
        self.dest_label.setTextInteractionFlags(Qt.TextInteractionFlag.TextSelectableByMouse)
        row.addWidget(self.dest_label, 1)
        for text, slot in (("Choose…", self._choose_dest), ("Open Folder", self._open_dest),
                           ("Stop All", self._stop_all), ("Clear Finished", self._clear_finished)):
            b = QPushButton(text)
            b.clicked.connect(slot)
            row.addWidget(b)
        lay.addLayout(row)

        self.jobs = QTreeWidget()
        self.jobs.setHeaderLabels(["Gallery", "Status"])
        self.jobs.setRootIsDecorated(False)
        self.jobs.setColumnWidth(0, 520)
        self.jobs.itemDoubleClicked.connect(self._open_job_folder)
        self.log = QPlainTextEdit()
        self.log.setReadOnly(True)
        self.log.setMaximumBlockCount(2000)
        split = QSplitter(Qt.Orientation.Horizontal)
        split.addWidget(self.jobs)
        split.addWidget(self.log)
        split.setSizes([700, 500])
        lay.addWidget(split, 1)

        main = QSplitter(Qt.Orientation.Vertical)
        main.addWidget(self.view)
        main.addWidget(panel)
        main.setStretchFactor(0, 4)
        main.setStretchFactor(1, 1)
        main.setSizes([680, 220])
        self.setCentralWidget(main)
        self.statusBar().showMessage("Browse to a gallery, then click Download Gallery.")

    # -- navigation
    def _go(self) -> None:
        text = self.address.text().strip()
        if not text:
            return
        if " " in text or "." not in text:
            url = HOME_URL + "?q=" + urllib.parse.quote_plus(text)
        elif "://" not in text:
            url = "https://" + text
        else:
            url = text
        self.view.load(QUrl(url))
        self.view.setFocus()

    def _url_changed(self, url: QUrl) -> None:
        self.address.setText(url.toString())
        self._refresh_button()

    def _load_finished(self, ok: bool) -> None:
        gallery = normalized_gallery_url(self.view.url().toString())
        if ok and gallery:
            def counted(html: str, g=gallery) -> None:
                self.photo_count[g] = len(photo_urls(html or ""))
                self._refresh_button()
            self.view.page().toHtml(counted)
        self._refresh_button()

    def _refresh_button(self) -> None:
        gallery = normalized_gallery_url(self.view.url().toString())
        if not gallery:
            self.dl_btn.setEnabled(False)
            self.dl_btn.setText("Download Gallery")
            return
        gid = gallery_id_from_url(gallery)
        if self.downloader.is_active(gid):
            self.dl_btn.setEnabled(False)
            self.dl_btn.setText("Queued / Downloading…")
            return
        count = self.photo_count.get(gallery)
        have = files_present(self.dest / safe_folder_name(gallery_name_from_url(gallery) or "Gallery"))
        self.dl_btn.setEnabled(True)
        if count and have >= count:
            self.dl_btn.setText(f"Downloaded ✓ ({have}) — Again")
        elif count:
            self.dl_btn.setText(f"Download Gallery ({count} photos)" + (f" — {have} saved" if have else ""))
        else:
            self.dl_btn.setText("Download Gallery")

    # -- queueing
    def _download_current(self) -> None:
        gallery = normalized_gallery_url(self.view.url().toString())
        if not gallery:
            return
        self.dl_btn.setEnabled(False)
        self.view.page().toHtml(lambda html, g=gallery: self._queue(g, html))

    def _download_link(self, link: str) -> None:
        gallery = normalized_gallery_url(link)
        if gallery:
            self._queue(gallery, None)

    def _queue(self, gallery: str, html: str | None) -> None:
        gid = gallery_id_from_url(gallery) or gallery
        name = gallery_name_from_url(gallery) or f"Gallery {gid}"
        job = Job(url=gallery, gallery_id=gid, name=name, dest=self.dest, page=html or None)
        if not self.downloader.enqueue(job):
            self.statusBar().showMessage(f"“{name}” is already in the queue.", 4000)
            self._refresh_button()
            return
        job.item = QTreeWidgetItem([name, "Queued"])
        job.item.setToolTip(0, gallery)
        job.item.setData(0, Qt.ItemDataRole.UserRole, str(self.dest / safe_folder_name(name)))
        self.jobs.addTopLevelItem(job.item)
        self.jobs.scrollToItem(job.item)
        self.statusBar().showMessage(f"Queued “{name}”.", 4000)
        self._refresh_button()

    # -- downloader signals (GUI thread)
    def _log(self, line: str) -> None:
        self.log.appendPlainText(line)

    def _job_started(self, job: Job) -> None:
        if job.item:
            job.item.setText(1, "Starting…")

    def _job_progress(self, job: Job, done: int, total: int, _name: str) -> None:
        if job.item:
            job.item.setText(1, f"{done}/{total}")

    def _job_finished(self, job: Job, result, error: str) -> None:
        if error:
            status = f"Failed: {error}"
            self._log(f"[{job.name}] Error: {error}")
        else:
            saved, skipped, failed, stopped = result
            status = ("Stopped — " if stopped else "Done — ") + f"{saved} saved, {skipped} already had" + \
                (f", {failed} failed" if failed else "")
            self._log(f"[{job.name}] {status}")
        if job.item:
            job.item.setText(1, status)
            job.item.setData(1, Qt.ItemDataRole.UserRole, "finished")
        self._refresh_button()

    # -- panel actions
    def _choose_dest(self) -> None:
        d = QFileDialog.getExistingDirectory(self, "Save galleries into", str(self.dest))
        if d:
            self.dest = Path(d)
            self.dest_label.setText(d)
            self.settings.setValue("dest", d)
            self._refresh_button()

    def _open_dest(self) -> None:
        self.dest.mkdir(parents=True, exist_ok=True)
        reveal(self.dest)

    def _open_job_folder(self, item: QTreeWidgetItem, _col: int) -> None:
        path = Path(str(item.data(0, Qt.ItemDataRole.UserRole)))
        reveal(path if path.exists() else self.dest)

    def _stop_all(self) -> None:
        dropped = self.downloader.cancel_all()
        for job in dropped:
            if job.item:
                job.item.setText(1, "Cancelled")
                job.item.setData(1, Qt.ItemDataRole.UserRole, "finished")
        self.statusBar().showMessage("Stopping…", 3000)
        self._refresh_button()

    def _clear_finished(self) -> None:
        for i in reversed(range(self.jobs.topLevelItemCount())):
            if self.jobs.topLevelItem(i).data(1, Qt.ItemDataRole.UserRole) == "finished":
                self.jobs.takeTopLevelItem(i)


def reveal(path: Path) -> None:
    if sys.platform == "darwin":
        subprocess.Popen(["open", str(path)])
    elif os.name == "nt":
        os.startfile(str(path))  # type: ignore[attr-defined]
    else:
        subprocess.Popen(["xdg-open", str(path)])


def main() -> None:
    args = sys.argv[1:]
    if args and args[0] in ("-h", "--help"):
        print(__doc__)
        return
    app = QApplication(sys.argv[:1])
    app.setApplicationName("PornPics Browser")
    win = MainWindow(args[0] if args else HOME_URL)
    win.show()
    rc = app.exec()
    del win  # tear down the page while its profile (owned by the app) still exists
    sys.exit(rc)


if __name__ == "__main__":
    main()
