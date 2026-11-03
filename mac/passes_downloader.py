"""Safe Finder ▸ "Download Passes…" / "Import Passes ZIP…"

    python3 mac/passes_downloader.py <folder> [creator-username]

Downloads purchased posts from passes.com into <folder>/<creator>/<contentId>.<ext>,
or imports the "Export my data" ZIP from Passes Settings into the same layout.

Auth: the user signs in to passes.com in the window's embedded browser (a
persistent QWebEngineProfile).  After the /auth/success navigation the page's
`refresh-token` localStorage key is read and stored in the Mac's Keychain
(service "Safe Finder Passes", account "refresh-token").  It is re-used on
every subsequent run and exchanged for a short-lived access token each time.

Items with an `original` variant are fetched and decrypted via passes_decrypt;
everything else uses `large`, then `signedUrl`.  If the original path fails the
item is retried at `large` and flagged in the log.

Passes support (Case PS-48213, 2026-11-03) confirms purchased content may be
kept locally for personal use.  Personal archive only, no redistribution.
"""
from __future__ import annotations

import concurrent.futures
import json
import os
import shutil
import sys
import tempfile
import threading
import time
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from PySide6.QtCore import QObject, QSettings, Qt, QTimer, QUrl, Signal          # noqa: E402
from PySide6.QtWidgets import (QApplication, QFileDialog, QHBoxLayout, QLabel,   # noqa: E402
                                QLineEdit, QMainWindow, QMessageBox,
                                QPlainTextEdit, QProgressBar, QPushButton,
                                QVBoxLayout, QWidget)
from PySide6.QtWebEngineCore import QWebEnginePage, QWebEngineProfile             # noqa: E402
from PySide6.QtWebEngineWidgets import QWebEngineView                             # noqa: E402

import passes                                                                     # noqa: E402
import passes_decrypt                                                             # noqa: E402
import simpcity as sc                                                             # noqa: E402
import social                                                                     # noqa: E402

LANES      = 4       # parallel download threads
SAVE_EVERY = 20      # flush record + tags after this many settled files

_PROFILE: QWebEngineProfile | None = None


def _browser_profile() -> QWebEngineProfile:
    global _PROFILE
    if _PROFILE is None:
        _PROFILE = QWebEngineProfile("passes", QApplication.instance())
        _PROFILE.setPersistentCookiesPolicy(
            QWebEngineProfile.PersistentCookiesPolicy.ForcePersistentCookies)
    return _PROFILE


class _Bridge(QObject):
    call = Signal(object, object)


class PassesWindow(QMainWindow):
    """Download / import window for Passes purchased content."""

    finished = Signal(str, list)   # (folder, files-written) — Safe Finder refreshes + tags

    def __init__(self, folder: str, start: str = "", tags=None, parent=None) -> None:
        super().__init__(parent)
        self.person   = Path(folder)
        self.tags     = tags
        self.running  = False
        self.stopping = False
        self.bridge   = _Bridge()
        self.bridge.call.connect(lambda cb, v: cb(v))
        self.settings  = QSettings("PhotoBrowser", "SafeFinder")
        self.exiftool  = sc.find_exiftool()
        self._refresh_token: str = passes.get_refresh_token()
        self._access_token:  str = ""
        self.setWindowTitle(f"Passes — {self.person.name}")
        self.resize(1000, 780)

        prof = _browser_profile()
        self.view = QWebEngineView()
        self.view.setPage(QWebEnginePage(prof, self.view))
        self.view.page().urlChanged.connect(self._url_changed)

        prefill = start or str(self.settings.value("passes/last_creator", "") or "")
        self.field    = QLineEdit(prefill)
        self.field.setPlaceholderText("Creator username  (blank = all purchased)")
        self.go_btn   = QPushButton("Download")
        self.go_btn.setDefault(True)
        self.go_btn.clicked.connect(self.start)
        self.stop_btn = QPushButton("Stop")
        self.stop_btn.setEnabled(False)
        self.stop_btn.clicked.connect(self.stop)
        self.zip_btn  = QPushButton("Import ZIP…")
        self.zip_btn.setToolTip(
            'Import the "Export my data" ZIP from Passes Settings → Account → Export my data')
        self.zip_btn.clicked.connect(self._import_zip)
        login_btn = QPushButton("Log In")
        login_btn.clicked.connect(lambda: self.view.load(QUrl(passes.LOGIN)))

        top = QHBoxLayout()
        top.addWidget(QLabel("Creator:"))
        top.addWidget(self.field, 1)
        top.addWidget(self.go_btn)
        top.addWidget(self.stop_btn)
        top.addWidget(self.zip_btn)
        top.addWidget(login_btn)

        self.status = QLabel(
            f'Log in to Passes below.  Downloads go into subfolders of "{self.person.name}".')
        self.status.setWordWrap(True)
        self.bar = QProgressBar()
        self.bar.setVisible(False)
        self.bar.setFixedWidth(240)
        self.bar.setFormat("%v of %m")
        self.log = QPlainTextEdit()
        self.log.setReadOnly(True)
        self.log.setMaximumHeight(155)
        self.log.setMaximumBlockCount(4000)

        box = QWidget()
        lay = QVBoxLayout(box)
        lay.addLayout(top)
        row2 = QHBoxLayout()
        row2.addWidget(self.status, 1)
        row2.addWidget(self.bar, 0, Qt.AlignmentFlag.AlignVCenter)
        lay.addLayout(row2)
        lay.addWidget(self.view, 1)
        lay.addWidget(self.log)
        self.setCentralWidget(box)

        self.view.load(QUrl(passes.HOME))

        if self._refresh_token:
            self._say("Authenticating…")
            threading.Thread(target=self._exchange_in_bg, daemon=True).start()
        else:
            self._say("Log in to Passes in the browser below to start.")

    # ── auth ─────────────────────────────────────────────────────────────────

    def _url_changed(self, url: QUrl) -> None:
        """After a successful login Passes navigates to a success/home URL — read the token."""
        if passes.SUCCESS_RE.search(url.toString()):
            self.view.page().runJavaScript(
                "localStorage.getItem('refresh-token')", 0, self._got_token)

    def _got_token(self, token) -> None:
        if not isinstance(token, str) or not token.strip():
            return
        # Passes stores the token JSON-encoded, so it arrives wrapped in quotes
        token = token.strip().strip('"')
        if not token:
            return
        if token == self._refresh_token:
            if self._access_token:
                return
        else:
            self._refresh_token = token
            passes.set_refresh_token(token)
            self._log("Token saved.")
        threading.Thread(target=self._exchange_in_bg, daemon=True).start()

    def _exchange_in_bg(self) -> None:
        try:
            tok = passes.exchange_token(self._refresh_token)
            self.bridge.call.emit(self._set_access, tok)
        except Exception as e:  # noqa: BLE001
            self.bridge.call.emit(self._log, f"Couldn't authenticate: {e}")

    def _set_access(self, tok: str) -> None:
        self._access_token = tok
        self._say("Authenticated — press Download to start.")

    # ── run ──────────────────────────────────────────────────────────────────

    def start(self) -> None:
        if self.running:
            return
        if not self._refresh_token:
            QMessageBox.information(self, "Passes",
                                    "Log in to Passes in the window below first.")
            self.view.load(QUrl(passes.LOGIN))
            return
        if not self._access_token:
            self._say("Getting access token…")
            def _after() -> None:
                self.bridge.call.emit(lambda _: self._do_start(), None)
            def _bg() -> None:
                try:
                    tok = passes.exchange_token(self._refresh_token)
                    self.bridge.call.emit(self._set_access, tok)
                    _after()
                except Exception as e:  # noqa: BLE001
                    self.bridge.call.emit(self._log, f"Couldn't refresh token: {e}")
            threading.Thread(target=_bg, daemon=True).start()
            return
        self._do_start()

    def _do_start(self) -> None:
        creator = self.field.text().strip()
        if creator:
            self.settings.setValue("passes/last_creator", creator)
        self.running = self.stopping = False
        self.running  = True
        self.queued   = self.settled_n = self.failed = self.present = 0
        self.photos   = self.videos = 0
        self.written:   list[str]             = []
        self.to_tag:    list[str]             = []
        self.done_keys: set[str]              = set()
        self.failed_keys: set[str]            = set()
        self.key_left:  dict[str, int]        = {}
        self.futures:   list[concurrent.futures.Future] = []
        self._records:  dict[str, social.Record] = {}   # creator_folder_str → Record
        self._creator_names: dict[str, str]  = {}       # userId → folder name (resolved in bg)
        self.crawl_done = False
        self.exif  = sc.ExifSession(self.exiftool) if self.exiftool else None
        self.heavy = threading.Lock()
        self.pool  = concurrent.futures.ThreadPoolExecutor(
            max_workers=LANES, thread_name_prefix="passes-dl")
        passes.ENCRYPTED.clear()

        for w in (self.go_btn, self.field, self.zip_btn):
            w.setEnabled(False)
        self.stop_btn.setEnabled(True)
        self.bar.setVisible(True)
        self.bar.setRange(0, 0)
        self._say("Fetching gallery…")
        self._log(f"Starting downloads into: {self.person}")

        access_token = self._access_token
        creator_field = creator
        person        = self.person
        stopping_ref  = [False]
        self._stopping_ref = stopping_ref

        def crawl() -> None:
            creator_names: dict[str, str] = {}

            def resolve(uid: str) -> str:
                if uid not in creator_names:
                    creator_names[uid] = social.sanitize(
                        passes.creator_username(uid, access_token), uid, 80)
                return creator_names[uid]

            try:
                creator_id = None
                if creator_field:
                    try:
                        doc = passes._post("/profile/get",
                                           {"username": creator_field}, access_token)
                        creator_id = doc.get("userId") or doc.get("creatorId")
                        if not creator_id:
                            self.bridge.call.emit(
                                self._log, f'Creator "{creator_field}" not found.')
                            self.bridge.call.emit(self._crawl_done, None)
                            return
                    except Exception as e:  # noqa: BLE001
                        self.bridge.call.emit(
                            self._log, f"Couldn't look up creator: {e}")
                        self.bridge.call.emit(self._crawl_done, None)
                        return

                for page in passes.gallery_pages(access_token, creator_id):
                    if stopping_ref[0]:
                        break
                    # resolve names in background before handing to main thread
                    resolved: list[tuple[dict, Path]] = []
                    for post in page:
                        uid    = post.get("userId", "")
                        folder = person / resolve(uid)
                        resolved.append((post, folder))
                    self.bridge.call.emit(self._enqueue_resolved, resolved)
                    time.sleep(passes.GAP)

            except Exception as e:  # noqa: BLE001
                self.bridge.call.emit(self._log,
                                      f"Gallery error: {type(e).__name__}: {e}")
            self.bridge.call.emit(self._crawl_done, None)

        threading.Thread(target=crawl, daemon=True).start()

    def _enqueue_resolved(self, resolved: list[tuple[dict, Path]]) -> None:
        if self.stopping:
            return
        for post, folder in resolved:
            key = str(folder)
            if key not in self._records:
                self._records[key] = passes.record(folder)
            rec     = self._records[key]
            already = rec.downloaded | passes.ids_on_disk(folder)
            for item in passes.items_from_post(post, folder, already):
                self._queue(item)

    def _queue(self, item: social.Item) -> None:
        self.queued += 1
        self.key_left[item.key] = self.key_left.get(item.key, 0) + 1
        self.bar.setRange(0, self.queued)

        headers = {"User-Agent": social.UA, "Referer": "https://www.passes.com/"}
        if item.key in passes.ENCRYPTED:
            # original variant: decrypt rather than plain-download
            fut = self.pool.submit(
                passes_decrypt.grab_original, item,
                {"Authorization": f"Bearer {self._access_token}", **headers},
                self.exif)
        else:
            fut = self.pool.submit(
                social.settle, item, [headers],
                social.Options(), self.exif, None, self.heavy)

        self.futures.append(fut)
        fut.add_done_callback(
            lambda f: self.bridge.call.emit(self._settled, f))

    def _settled(self, fut) -> None:
        if fut.cancelled():
            return
        s: social.Settled | None = None
        try:
            s = fut.result()
        except Exception as e:  # noqa: BLE001
            self.failed += 1
            self._log(f"   FAILED: {e}")
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
            elif s.why.startswith("original:") and s.item.key in passes.ENCRYPTED:
                # decryption failed — drop back to the plain variant for this item
                passes.ENCRYPTED.pop(s.item.key, None)
                self._log(f"   {s.item.name}.{s.item.ext}: {s.why} — retrying at large")
                self._queue(s.item)
            else:
                self.failed += 1
                self.failed_keys.add(s.item.key)
                self._log(f"   couldn't download {s.item.name}.{s.item.ext}: {s.why}")
        self.settled_n += 1
        self.bar.setValue(self.settled_n)
        self._say(
            f"Downloaded {len(self.written)} of {self.queued}"
            + (f" · {self.failed} failed" if self.failed else "")
            + ("" if self.crawl_done else " · still looking…"))
        if len(self.to_tag) >= SAVE_EVERY:
            self._flush()
        if self.crawl_done and self.settled_n >= self.queued:
            self._finish()

    def _crawl_done(self, _) -> None:
        self.crawl_done = True
        if self.settled_n >= self.queued:
            self._finish()
        else:
            n = self.queued - self.settled_n
            self._say(f"Found everything — {n} file{'s' if n != 1 else ''} still downloading…")

    def _flush(self) -> None:
        """Save tags and records accumulated so far."""
        if self.tags is not None and self.to_tag:
            try:
                self.tags.add(self.to_tag, [passes.TAG])
            except OSError as e:
                self._log(f"Couldn't save tags: {e}")
        self.to_tag = []
        done = {k for k in self.done_keys
                if self.key_left.get(k, 0) <= 0} - self.failed_keys
        if not done:
            return
        for rec in self._records.values():
            try:
                rec.save(done)
            except OSError as e:
                self._log(f"Couldn't save record: {e}")

    def _finish(self, problem: str = "") -> None:
        if not self.running:
            return
        self.running = False
        if self._stopping_ref:
            self._stopping_ref[0] = True
        if getattr(self, "pool", None):
            self.pool.shutdown(wait=False, cancel_futures=True)
        self._flush()
        if self.exif is not None:
            self.exif.close()
        if problem:
            line = problem
        elif not self.written:
            line = "Nothing new." if self.queued else "No purchased posts found."
        else:
            p, v = self.photos, self.videos
            line = (f"Downloaded {p} photo{'s' if p != 1 else ''} "
                    f"and {v} video{'s' if v != 1 else ''}"
                    + (f" · {self.failed} failed" if self.failed else "") + ".")
        self._log(line)
        self._say(line)
        for w in (self.go_btn, self.field, self.zip_btn):
            w.setEnabled(True)
        self.stop_btn.setEnabled(False)
        self.bar.setVisible(False)
        self.finished.emit(str(self.person), list(self.written))

    # ── stop ────────────────────────────────────────────────────────────────

    def stop(self) -> None:
        if self.running:
            self.stopping = True
            if self._stopping_ref:
                self._stopping_ref[0] = True
            for f in getattr(self, "futures", []):
                f.cancel()
            self._say("Stopping after the files in hand…")

    def closeEvent(self, event) -> None:  # noqa: N802
        if self.running:
            if QMessageBox.question(
                    self, "Passes",
                    "A download is running. Stop it and close?") \
                    != QMessageBox.StandardButton.Yes:
                event.ignore()
                return
            self.stopping = True
        super().closeEvent(event)

    # ── ZIP import ───────────────────────────────────────────────────────────

    def _import_zip(self) -> None:
        path, _ = QFileDialog.getOpenFileName(
            self, "Open Passes Export ZIP", str(Path.home()), "ZIP files (*.zip)")
        if not path:
            return
        self._log(f"Importing {Path(path).name}…")
        self.zip_btn.setEnabled(False)
        self.bar.setVisible(True)
        self.bar.setRange(0, 0)
        tags      = self.tags
        person    = self.person
        exiftool  = self.exiftool

        def run() -> None:
            try:
                written_paths, skipped = _import_zip(path, person, exiftool)
                if tags is not None and written_paths:
                    try:
                        tags.add(written_paths, [passes.TAG])
                    except OSError:
                        pass
                msg = (f"Imported {len(written_paths)} "
                       f"file{'s' if len(written_paths) != 1 else ''}"
                       + (f", {skipped} already present" if skipped else "") + ".")
            except Exception as e:  # noqa: BLE001
                msg = f"Import failed: {e}"
                written_paths = []
            self.bridge.call.emit(self._zip_done, (msg, written_paths))

        threading.Thread(target=run, daemon=True).start()

    def _zip_done(self, args) -> None:
        msg, written = args
        self._log(msg)
        self._say(msg)
        self.zip_btn.setEnabled(True)
        self.bar.setVisible(False)
        if written:
            self.finished.emit(str(self.person), list(written))

    # ── helpers ──────────────────────────────────────────────────────────────

    def _log(self, line: str) -> None:
        if line == getattr(self, "_last_line", None):
            return
        self._last_line = line
        self.log.appendPlainText(time.strftime("%H:%M:%S ") + line)

    def _say(self, line: str) -> None:
        self.status.setText(line)


# ── ZIP importer (pure Python, no Qt) ────────────────────────────────────────

_MEDIA_EXTS = {"jpg", "jpeg", "png", "webp", "heic",
               "mp4", "mov", "m4v", "gif", "pdf", "aac", "mp3"}


def _import_zip(zip_path: str, dest: Path,
                exiftool=None) -> tuple[list[str], int]:
    """
    Import a Passes "Export my data" ZIP.

    The ZIP is expected to be a flat archive (all files at the top level) with:
      • A JSON file containing post/content metadata (posts/content/data array).
      • Media files named <contentId>.<ext>.

    Returns (list_of_written_paths, skipped_count).
    """
    written: list[str] = []
    skipped = 0

    with zipfile.ZipFile(zip_path) as zf:
        names = zf.namelist()

        # 1. Parse any JSON metadata in the ZIP
        meta: dict[str, dict] = {}    # contentId → {date, poster, uid, video, ext}
        for n in names:
            bn = os.path.basename(n)
            if not bn.endswith(".json"):
                continue
            try:
                doc = json.loads(zf.read(n).decode("utf-8", errors="replace"))
            except (ValueError, OSError):
                continue
            arr: list = []
            if isinstance(doc, list):
                arr = doc
            elif isinstance(doc, dict):
                arr = (doc.get("posts") or doc.get("content")
                       or doc.get("data") or [])
            for post in arr:
                if not isinstance(post, dict):
                    continue
                date   = passes._ts(post.get("createdAt") or post.get("sentAt"))
                poster = post.get("username") or post.get("userId", "")
                uid    = post.get("userId", "")
                for c in (post.get("contents") or [post]):
                    cid = c.get("contentId") or c.get("postId", "")
                    if not cid:
                        continue
                    ct  = (c.get("contentType") or "").lower()
                    ext = (c.get("extension") or "").lstrip(".")
                    meta[cid] = {"date": date, "poster": poster,
                                 "uid": uid, "video": ct == "video", "ext": ext}

        # 2. Process media files
        creator_cache: dict[str, str] = {}   # poster → sanitized folder name
        # per-creator record: collect done ids, save once at end
        folder_done: dict[str, set[str]]    = {}   # folder_str → set of cids
        folder_recs: dict[str, social.Record] = {}

        exif_session = sc.ExifSession(exiftool) if exiftool else None
        try:
            for zn in names:
                bn   = os.path.basename(zn)
                if not bn or "." not in bn:
                    continue
                stem, _, ext = bn.rpartition(".")
                ext = ext.lower()
                if ext not in _MEDIA_EXTS:
                    continue
                cid = stem
                m   = meta.get(cid)
                uid    = m["uid"]    if m else ""
                date   = m["date"]   if m else 0
                poster = m["poster"] if m else ""
                video  = (m["video"] if m else ext in {"mp4", "mov", "m4v"})

                # creator folder — named after the username, matching downloads
                name_key = poster or uid
                if name_key not in creator_cache:
                    creator_cache[name_key] = (
                        social.sanitize(poster, "Passes", 80) if poster else "Passes")
                folder = dest / creator_cache[name_key]
                sc.make_folder(folder)
                fkey   = str(folder)
                if fkey not in folder_recs:
                    folder_recs[fkey]  = passes.record(folder)
                    folder_done[fkey]  = set()
                rec = folder_recs[fkey]

                out_name = f"{cid}.{ext}"
                out_path = folder / out_name
                if out_path.exists() or cid in rec.downloaded:
                    skipped += 1
                    continue

                tmp = tempfile.mktemp(suffix=f".{ext}", prefix="passes-zip-")
                try:
                    with zf.open(zn) as src, open(tmp, "wb") as dst:
                        shutil.copyfileobj(src, dst)
                    if date:
                        os.utime(tmp, (date, date))
                    if exif_session and date:
                        item = social.Item(
                            key=cid, folder=folder, name=cid, video=video,
                            url="", ext=ext, date=date, poster=poster,
                            keyword=passes.KEYWORD)
                        social.write_meta(tmp, item, exif_session)
                    placed = social.place(tmp, folder, out_name)
                    if placed:
                        written.append(placed)
                        folder_done[fkey].add(cid)
                    else:
                        skipped += 1
                except OSError:
                    pass
                finally:
                    if os.path.exists(tmp):
                        try:
                            os.remove(tmp)
                        except OSError:
                            pass
        finally:
            if exif_session is not None:
                exif_session.close()

        # save per-creator records
        for fkey, cids in folder_done.items():
            if cids:
                try:
                    folder_recs[fkey].save(cids)
                except OSError:
                    pass

    return written, skipped


# ── label helper (used by safe_finder.py) ────────────────────────────────────

def passes_label(folder: str) -> str:
    return ("Get New Passes Posts"
            if os.path.isfile(os.path.join(folder, passes.RECORD))
            else "Download Passes…")


# ── standalone entry ─────────────────────────────────────────────────────────

def main() -> None:
    if len(sys.argv) < 2:
        sys.exit("usage: passes_downloader.py <folder> [creator-username]")
    app = QApplication(sys.argv[:1])
    win = PassesWindow(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else "")
    win.show()
    sys.exit(app.exec())


if __name__ == "__main__":
    main()