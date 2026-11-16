#!/usr/bin/env python3
"""Photo Browser for Mac ▸ Download ▸ "Download from Depop…" — the window (depop.py reads the shop, social.py
downloads).

    python3 mac/depop_downloader.py "/Volumes/SSD/Clothes" [shop]

Type a shop's name (or paste its link) and press Open — or find the shop in the page on the left. Every photo of
its listings appears on the right as you look through the shop (Load Whole Shop scrolls to its end for you).
**Click the photos you want** — ⌘-click and ⇧-click for several, drag across them, double-click for a whole
listing, Select All — and press Download: each comes down in **the largest version the shop has of it**
(depop.fetch_best: measured, not assumed) as `<listing>_<n>.jpg` into `<folder>/Depop/<shop>`, with the listing's
words and date and the "depop" tag. **Upscale every photo 2×** does that to each as it arrives — Real-ESRGAN when
an upscaler is installed (the one AI Upscale uses), else a plain enlargement.

The page on the left is a real browser with its own lasting profile: Depop's bot check, when it shows one, is
answered there by the person, and nothing is asked of Depop but what that page asks itself, plus — at a slow,
steady pace, and only if the box is ticked — each listing's own page for the photos its tile didn't show.
Photos already downloaded (the folder's `.depop.json`) are ticked and aren't fetched again.

Pictures are fetched with plain requests; if the picture server turns those away (a 403, a page), the same
address is downloaded by the window's browser instead, and from then on everything is.
"""
from __future__ import annotations

import concurrent.futures
import hashlib
import json
import os
import shutil
import sys
import tempfile
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from PySide6.QtCore import QObject, QRectF, QSize, Qt, QTimer, QUrl, Signal  # noqa: E402
from PySide6.QtGui import QColor, QIcon, QPainter, QPen, QPixmap  # noqa: E402
from PySide6.QtWidgets import (QAbstractItemView, QApplication, QCheckBox, QComboBox, QHBoxLayout, QLabel, QLineEdit,  # noqa: E402
                               QListView, QListWidget, QListWidgetItem, QMainWindow, QPlainTextEdit, QProgressBar,
                               QPushButton, QSplitter, QVBoxLayout, QWidget)
from PySide6.QtWebEngineCore import QWebEnginePage, QWebEngineProfile, QWebEngineScript  # noqa: E402
from PySide6.QtWebEngineWidgets import QWebEngineView  # noqa: E402

import app_identity  # noqa: E402
import depop  # noqa: E402
import fanfix  # noqa: E402
import fanfix_downloader as fx  # noqa: E402 — its browser-download jobs (`_Job`, `_on_download`) are reused as they are
import simpcity as sc  # noqa: E402
import social  # noqa: E402

LANES = 3                     # photos downloaded at once
THUMB_LANES = 4
TICK_MS = 1500                # how often what the page loaded and shows is read (and, when asked, the page scrolled)
PAGE_GAP = 1.6                # seconds between listing pages asked for (their other photos)
IDLE_TICKS = 6                # scrolling with nothing new this many times is the end of the shop
SAVE_EVERY = 12
TILE = 150
BASE = Qt.ItemDataRole.UserRole

_PROFILE: QWebEngineProfile | None = None


def profile() -> QWebEngineProfile:
    """Depop's own lasting browser profile (an answered check and a login survive restarts), with the watching
    script put into every page before the page's own, and its downloads handed to their jobs."""
    global _PROFILE
    if _PROFILE is None:
        _PROFILE = QWebEngineProfile("depop", QApplication.instance())
        _PROFILE.setPersistentCookiesPolicy(QWebEngineProfile.PersistentCookiesPolicy.ForcePersistentCookies)
        script = QWebEngineScript()
        script.setName("photobrowser-watch")
        script.setSourceCode(fanfix.HOOK_JS)
        script.setInjectionPoint(QWebEngineScript.InjectionPoint.DocumentCreation)
        script.setWorldId(QWebEngineScript.ScriptWorldId.MainWorld)
        script.setRunsOnSubFrames(False)
        _PROFILE.scripts().insert(script)
        _PROFILE.downloadRequested.connect(fx._on_download)
    return _PROFILE


class _Bridge(QObject):
    call = Signal(object, object)             # (function, argument) — run on the window's thread


class DepopWindow(QMainWindow):
    finished = Signal(str, list)              # (the shop's folder, the files written) after each download run

    def __init__(self, folder: str, start: str = "", tags=None, parent=None) -> None:
        super().__init__(parent)
        self.person = Path(folder)
        self.tags = tags
        self.running = self.stopping = self.closed = self.scrolling = False
        self.settings = app_identity.settings()
        self.exiftool = sc.find_exiftool()
        self.bridge = _Bridge()
        self.bridge.call.connect(lambda fn, value: fn(value))
        self.shop = depop.Shop("")
        self.record: social.Record | None = None
        self.have: set[str] = set()                       # photos already downloaded (the record's)
        self.tiles: dict[str, QListWidgetItem] = {}       # photo base → its tile
        self.pix: dict[str, QPixmap] = {}
        self.asked: set[str] = set()                      # listings whose page has been asked for
        self.last_page = 0.0
        self.idle = 0
        self.last_height = 0
        self.phase = "selling"                            # Load Whole Shop: the listings for sale, then "sold", then done
        self.sold_url: str | None = None                  # the address the Sold tab was open at
        self.sold_state: dict[str, bool] = {}             # photo base → drawn as sold
        self.by_browser = False
        self.exif = None
        self.dest = self.person
        self.written: list[str] = []
        self.upscaled: list[str] = []
        self.unsaved: set[str] = set()
        self._tagged: set[str] = set()
        self.sold_files: set[str] = set()
        self.sold_keys: set[str] = set()
        self.versions: dict[str, str] = {}
        self.tmp = tempfile.mkdtemp(prefix="photo-browser-depop-")
        self.thumbs = concurrent.futures.ThreadPoolExecutor(THUMB_LANES, thread_name_prefix="depop-thumb")
        self.pool: concurrent.futures.ThreadPoolExecutor | None = None
        self.heavy = threading.Lock()
        self.tries = [social.headers(depop.SITE)]
        self.setWindowTitle(f"Depop — {self.person.name}")
        self.resize(1320, 880)

        self.view = QWebEngineView()
        self.view.setPage(QWebEnginePage(profile(), self.view))
        self.view.urlChanged.connect(self._url_changed)

        self.field = QLineEdit()
        self.field.setPlaceholderText("A shop's name, or its link — or find the shop in the page below")
        self.field.returnPressed.connect(self.open_shop)
        open_btn = QPushButton("Open")
        open_btn.clicked.connect(self.open_shop)
        self.scroll_btn = QPushButton("Load Whole Shop")
        self.scroll_btn.setToolTip("Scrolls the shop's page to its end, so every listing's photos are here to pick from")
        self.scroll_btn.clicked.connect(self.toggle_scroll)
        self.sold_btn = QPushButton("Sold Items")
        self.sold_btn.setToolTip("Opens the shop's Sold tab in the page, so the listings it has sold are read too")
        self.sold_btn.clicked.connect(self.open_sold)
        top = QHBoxLayout()
        top.addWidget(QLabel("Shop"))
        top.addWidget(self.field, 1)
        top.addWidget(open_btn)
        top.addWidget(self.scroll_btn)
        top.addWidget(self.sold_btn)

        self.grid = QListWidget()
        self.grid.setViewMode(QListView.ViewMode.IconMode)
        self.grid.setResizeMode(QListView.ResizeMode.Adjust)
        self.grid.setMovement(QListView.Movement.Static)
        self.grid.setSelectionMode(QAbstractItemView.SelectionMode.ExtendedSelection)
        self.grid.setIconSize(QSize(TILE, TILE))
        self.grid.setGridSize(QSize(TILE + 10, TILE + 10))
        self.grid.setUniformItemSizes(True)
        self.grid.setSpacing(0)
        self.grid.itemSelectionChanged.connect(self._count)
        self.grid.itemDoubleClicked.connect(self._select_listing)
        self.empty = QLabel("Open a shop: its listings' photos appear here.\nClick the ones you want — ⌘-click or "
                            "⇧-click for several, double-click for a whole listing.")
        self.empty.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.empty.setWordWrap(True)
        right = QWidget()
        rl = QVBoxLayout(right)
        rl.setContentsMargins(0, 0, 0, 0)
        rl.addWidget(self.empty)
        rl.addWidget(self.grid, 1)
        pick = QHBoxLayout()
        all_btn = QPushButton("Select All")
        all_btn.clicked.connect(self.select_shown)
        none_btn = QPushButton("Select None")
        none_btn.clicked.connect(self.grid.clearSelection)
        self.counted = QLabel("")
        self.show_box = QComboBox()
        for key, text in (("all", "Everything"), ("selling", "For sale"), ("sold", "Sold")):
            self.show_box.addItem(text, key)
        self.show_box.setToolTip("Which listings' photos are shown — Select All takes only what's shown")
        self.show_box.currentIndexChanged.connect(lambda _i: self._filter())
        pick.addWidget(QLabel("Show:"))
        pick.addWidget(self.show_box)
        pick.addWidget(all_btn)
        pick.addWidget(none_btn)
        pick.addWidget(self.counted, 1)
        rl.addLayout(pick)

        split = QSplitter(Qt.Orientation.Horizontal)
        split.addWidget(self.view)
        split.addWidget(right)
        split.setStretchFactor(0, 4)
        split.setStretchFactor(1, 6)
        split.setSizes([520, 780])

        self.all_box = QCheckBox("Get each listing's other photos too")
        self.all_box.setToolTip("A shop's page shows one photo of each listing. Ticked: each listing's own page is read "
                                "for the rest, one every couple of seconds.")
        self.all_box.setChecked(str(self.settings.value("depop/all_photos", "true")) == "true")
        self.all_box.toggled.connect(lambda on: self.settings.setValue("depop/all_photos", "true" if on else "false"))
        self.sold_box = QCheckBox("Include sold items")
        self.sold_box.setToolTip("Load Whole Shop goes on into the shop's Sold tab once the listings for sale are in, so "
                                 "sold listings' photos are here to pick from too (shown with a SOLD band; downloaded "
                                 "ones are tagged “sold” as well as “depop”)")
        self.sold_box.setChecked(str(self.settings.value("depop/sold", "true")) == "true")
        self.sold_box.toggled.connect(lambda on: self.settings.setValue("depop/sold", "true" if on else "false"))
        self.up_box = QCheckBox("Upscale every photo 2×")
        self.up_box.setChecked(str(self.settings.value("depop/upscale", "false")) == "true")
        self.up_box.toggled.connect(lambda on: self.settings.setValue("depop/upscale", "true" if on else "false"))
        self.engine = self._find_engine()
        self.up_box.setToolTip("Each photo is enlarged to twice its size as it arrives, " + (
            f"with {self.engine.label} — Real-ESRGAN, the one AI Upscale uses." if self.engine is not None else
            "plainly (Lanczos, lightly sharpened) — no AI upscaler is installed; AI Upscale 2× in the main window "
            "says how to add one.") + " Upscaled photos get the “upscaled” tag.")
        self.go = QPushButton("Download")
        self.go.setObjectName("Primary")
        self.go.setDefault(True)
        self.go.clicked.connect(self.download_selected)
        self.stop_btn = QPushButton("Stop")
        self.stop_btn.clicked.connect(self.stop)
        self.stop_btn.setEnabled(False)
        opts = QHBoxLayout()
        opts.addWidget(self.all_box)
        opts.addSpacing(18)
        opts.addWidget(self.sold_box)
        opts.addSpacing(18)
        opts.addWidget(self.up_box)
        opts.addStretch(1)
        opts.addWidget(self.stop_btn)
        opts.addWidget(self.go)

        self.status = QLabel("")
        self.status.setWordWrap(True)
        self.bar = QProgressBar()
        self.bar.setFixedWidth(220)
        self.bar.hide()
        prog = QHBoxLayout()
        prog.addWidget(self.status, 1)
        prog.addWidget(self.bar)
        self.log = QPlainTextEdit()
        self.log.setReadOnly(True)
        self.log.setMaximumBlockCount(2000)
        self.log.setFixedHeight(96)

        box = QWidget()
        lay = QVBoxLayout(box)
        lay.addLayout(top)
        lay.addWidget(split, 1)
        lay.addLayout(opts)
        lay.addLayout(prog)
        lay.addWidget(self.log)
        self.setCentralWidget(box)

        self.timer = QTimer(self)
        self.timer.setInterval(TICK_MS)
        self.timer.timeout.connect(self._tick)
        self.timer.start()
        known = depop.clean_shop(start) or depop.shop_of_folder(self.person)
        if known:
            self.field.setText(known)
            self.open_shop()
        else:
            self.view.load(QUrl(depop.SITE))
            self._say("Type a shop's name above, or find the shop in the page.")
        if not self.exiftool:
            self._log("ExifTool isn't installed, so a listing's date only goes on the file's dates and its words don't go "
                      "into the files (install it with: brew install exiftool).")
        self._count()

    # ------------------------------------------------------------------ small helpers
    def _log(self, line: str) -> None:
        self.log.appendPlainText(time.strftime("%H:%M:%S ") + line)

    def _say(self, line: str) -> None:
        self.status.setText(line)

    def _find_engine(self):
        try:
            import ai_upscale
            return ai_upscale.find_engine(self.settings.value("upscale/engine") or None)
        except Exception:  # noqa: BLE001 — no upscaler: the plain enlargement
            return None

    def _on_site(self) -> bool:
        return self.view.url().host().lower().endswith(depop.DOMAIN.split(":")[0])

    # ------------------------------------------------------------------ the shop
    def open_shop(self) -> None:
        text = self.field.text().strip()
        shop = depop.clean_shop(text)
        if not shop and depop.slug_of(text):
            shop = depop.clean_shop(depop.slug_of(text).split("-")[0])      # a listing's link: its seller's shop
        if not shop:
            self._say("That isn't a shop's name or link — a name looks like “janesvintage”, a link like "
                      "depop.com/janesvintage.")
            return
        self._set_shop(shop)
        self.view.load(QUrl(depop.shop_url(shop)))

    def _url_changed(self, url: QUrl) -> None:
        text = url.toString()
        shop = depop.clean_shop(text) if self._on_site() else ""
        if shop and shop != self.shop.shop and not self.running:
            self._set_shop(shop)

    def _set_shop(self, shop: str) -> None:
        if shop == self.shop.shop:
            return
        self.scrolling = False
        self.scroll_btn.setText("Load Whole Shop")
        self.phase = "selling"
        self.sold_state = {}
        self.shop = depop.Shop(shop)
        self.asked.clear()
        self.tiles.clear()
        self.pix.clear()
        self.grid.clear()
        self.idle = self.last_height = 0
        self.field.setText(shop)
        self.dest = depop.shop_folder(self.person, shop)
        try:
            self.record = depop.record(self.dest)
            self.have = set(self.record.downloaded)
        except OSError:
            self.record, self.have = None, set()
        self.setWindowTitle(f"Depop — {shop}")
        self._say(f"Reading {shop}'s shop…")
        self._count()

    def open_sold(self) -> None:
        """The shop's Sold tab, opened in the page (its own tab clicked); what it loads is read as sold."""
        if not self._on_site():
            return

        def done(raw) -> None:
            try:
                found = bool(json.loads(raw).get("found")) if isinstance(raw, str) else False
            except ValueError:
                found = False
            if found:
                self.shop.sold_view, self.sold_url = True, None
                self.last_height = 0
                self.idle = 0
                self._log("Opened the shop's Sold tab — its listings are read as sold.")
                self._say("Reading the shop's sold items…" + (" scrolling to the end…" if self.scrolling else
                          " (Load Whole Shop scrolls to the end.)"))
            else:
                self._say("This page has no Sold tab to open — open the shop's own page (or its Sold items) in the page "
                          "on the left; what it shows is read.")
                if self.phase == "sold" and self.scrolling:
                    self.phase = "done"
                    self.toggle_scroll()
        self.view.page().runJavaScript(depop.SOLD_TAB_JS, 0, done)

    def toggle_scroll(self) -> None:
        self.scrolling = not self.scrolling
        self.idle = 0
        if self.scrolling:
            self.phase = "sold" if self.shop.sold_view else "selling"
        self.scroll_btn.setText("Stop Scrolling" if self.scrolling else "Load Whole Shop")
        if self.scrolling:
            self._say("Scrolling the shop to its end…")

    # ------------------------------------------------------------------ reading the page, every tick
    def _tick(self) -> None:
        if self.closed or not self._on_site():
            return
        self.view.page().runJavaScript(fanfix.DRAIN_JS, 0, self._drained)

    def _drained(self, raw) -> None:
        if self.closed:
            return
        try:
            answers = json.loads(raw) if isinstance(raw, str) else []
        except ValueError:
            answers = []
        got = 0
        for a in answers if isinstance(answers, list) else []:
            if not isinstance(a, dict) or not isinstance(a.get("t"), str):
                continue
            try:
                if a.get("k") == "page":
                    got += self.shop.read_page(a["t"], depop.slug_of(str(a.get("u") or "")))
                else:
                    got += self.shop.read_text(a["t"])
            except Exception as e:  # noqa: BLE001 — one answer that can't be read isn't the end of the shop
                self._log(f"An answer from the page couldn't be read ({type(e).__name__}).")
        if isinstance(answers, list) and len(answers) >= 60:      # more waiting: taken before going on
            self.view.page().runJavaScript(fanfix.DRAIN_JS, 0, self._drained)
            return
        self.view.page().runJavaScript(depop.DOM_JS, 0, lambda r: self._shown(r, got))

    def _shown(self, raw, got: int) -> None:
        if self.closed:
            return
        try:
            state = json.loads(raw) if isinstance(raw, str) else {}
        except ValueError:
            state = {}
        if not isinstance(state, dict):
            state = {}
        title = str(state.get("title") or "")
        if title.lower().startswith("just a moment") or "challenges.cloudflare.com" in str(state.get("url") or ""):
            self._say("Depop is checking the browser — answer its check in the page on the left; reading goes on by "
                      "itself after.")
            return
        # Is the Sold tab what's open? The page says so when its tab is marked (or the address says "sold"); a tab
        # this window clicked counts as open until the page goes somewhere else.
        url = str(state.get("url") or "")
        if state.get("sold_open"):
            if not self.shop.sold_view:
                self._log("The shop's Sold tab is open — its listings are read as sold.")
            self.shop.sold_view, self.sold_url = True, url
        elif self.shop.sold_view:
            if self.sold_url is None:
                self.sold_url = url
            elif url != self.sold_url:
                self.shop.sold_view, self.sold_url = False, None     # left it
        if self.shop.shop:
            try:
                got += self.shop.read_shown(state.get("shown") or [])
            except Exception:  # noqa: BLE001
                pass
        self._sync_grid()
        self._ask_for_a_page()
        if self.scrolling:
            height = int(state.get("height") or 0)
            self.idle = 0 if (got or height != self.last_height) else self.idle + 1
            self.last_height = height
            waiting = self.all_box.isChecked() and any(s not in self.asked for s in self.shop.incomplete())
            if self.idle >= IDLE_TICKS and not waiting:
                selling, sold = self.shop.counts()
                if self.phase == "selling" and self.sold_box.isChecked() and not self.shop.sold_view:
                    self._log(f"The end of the listings for sale ({selling:,}) — on to the sold items.")
                    self.phase = "sold"
                    self.idle = 0
                    self.open_sold()
                    return
                self.phase = "done"
                self.toggle_scroll()
                self._log(f"The end of the shop: {selling:,} listing(s) for sale, {sold:,} sold, "
                          f"{len(self.shop.photos):,} photo(s).")
            else:
                self.view.page().runJavaScript(fanfix.SCROLL_JS, 0, lambda _r: None)
        if not self.running:
            self._status()

    def _status(self) -> None:
        if not self.shop.shop:
            return
        n, m = len(self.shop.listings), len(self.shop.photos)
        if not m:
            self._say(f"Reading {self.shop.shop}'s shop… nothing found yet — if the page on the left asks something, "
                      "answer it there.")
            return
        left = [s for s in self.shop.incomplete() if s not in self.asked] if self.all_box.isChecked() else []
        selling, sold = self.shop.counts()
        of = f"{selling:,} listing(s) for sale" + (f" and {sold:,} sold" if sold else "")
        self._say(f"{m:,} photo(s) of {of} found" + (" (the Sold tab)" if self.shop.sold_view else "")
                  + (" — scrolling for more…" if self.scrolling else
                  (" — the whole shop." if self.phase == "done" else
                   " so far — scroll the shop (or Load Whole Shop) for more.") if not left else "")
                  + (f" Reading the other photos of {len(left):,} listing(s)…" if left else ""))

    def _ask_for_a_page(self) -> None:
        """One listing's page asked for (by the page itself) for the photos its tile didn't show — paced."""
        if not self.all_box.isChecked() or not self.shop.shop or time.monotonic() - self.last_page < PAGE_GAP:
            return
        slug = next((s for s in self.shop.incomplete() if s not in self.asked), "")
        if not slug:
            return
        self.asked.add(slug)
        self.last_page = time.monotonic()
        self.view.page().runJavaScript(depop.page_fetch_js(slug), 0, lambda _r: None)

    # ------------------------------------------------------------------ the grid
    def _sold(self, p: depop.Photo) -> bool:
        it = self.shop.listings.get(p.slug)
        return bool(it and it.sold)

    def _sync_grid(self) -> None:
        """A tile for each photo not shown yet — beside its listing's others; a tile whose listing turned out to be
        sold gets its band."""
        for base, item in self.tiles.items():
            p = self.shop.photos.get(base)
            if p is not None and self._sold(p) != self.sold_state.get(base):
                self.sold_state[base] = self._sold(p)
                item.setIcon(QIcon(self._tile(self.pix.get(base), p.key in self.have, self.sold_state[base])))
                self._tip(p)
                self._show_or_hide(item, p)
        new = [p for p in self.shop.ordered() if p.base not in self.tiles]
        if not new:
            return
        for p in new:
            item = QListWidgetItem()
            item.setData(BASE, p.base)
            item.setSizeHint(QSize(TILE + 10, TILE + 10))
            self.sold_state[p.base] = self._sold(p)
            item.setIcon(QIcon(self._tile(None, p.key in self.have, self.sold_state[p.base])))
            row = self.grid.count()
            it = self.shop.listings.get(p.slug)
            if it is not None:                             # after the listing's photo before it, when that's shown
                before = [b for b in it.photos[:it.photos.index(p.base)] if b in self.tiles] if p.base in it.photos else []
                if before:
                    row = self.grid.row(self.tiles[before[-1]]) + 1
            self.grid.insertItem(row, item)
            self.tiles[p.base] = item
            self._show_or_hide(item, p)
            self._tip(p)
            self.thumbs.submit(self._thumb, p.base, p.thumb())
        self.empty.setVisible(False)
        self._count()

    def _tip(self, p: depop.Photo) -> None:
        item = self.tiles.get(p.base)
        it = self.shop.listings.get(p.slug)
        if item is None:
            return
        words = (it.title if it and it.title else p.slug.replace("-", " ")) or "a photo on the page"
        many = f" — photo {p.place + 1} of {len(it.photos)}" if it and len(it.photos) > 1 else ""
        item.setToolTip(words[:160] + many + ("\nSold" if it and it.sold else "")
                        + ("\nAlready downloaded" if p.key in self.have else ""))

    def _show_or_hide(self, item: QListWidgetItem, p: depop.Photo) -> None:
        want = self.show_box.currentData()
        item.setHidden(want == "sold" and not self._sold(p) or want == "selling" and self._sold(p))

    def _filter(self) -> None:
        for base, item in self.tiles.items():
            p = self.shop.photos.get(base)
            if p is not None:
                self._show_or_hide(item, p)
                if item.isHidden():
                    item.setSelected(False)
        self._count()

    def select_shown(self) -> None:
        self.grid.blockSignals(True)
        for item in self.tiles.values():
            if not item.isHidden():
                item.setSelected(True)
        self.grid.blockSignals(False)
        self._count()

    def _tile(self, pix: QPixmap | None, have: bool, sold: bool = False) -> QPixmap:
        out = QPixmap(TILE, TILE)
        out.fill(QColor(128, 128, 128, 40))
        p = QPainter(out)
        p.setRenderHint(QPainter.RenderHint.Antialiasing)
        if pix is not None and not pix.isNull():
            scaled = pix.scaled(TILE, TILE, Qt.AspectRatioMode.KeepAspectRatioByExpanding,
                                Qt.TransformationMode.SmoothTransformation)
            p.setOpacity(0.45 if have else 1.0)
            p.drawPixmap((TILE - scaled.width()) // 2, (TILE - scaled.height()) // 2, scaled)
            p.setOpacity(1.0)
        if sold:                                           # Depop's own mark: a band across the top
            p.setPen(Qt.PenStyle.NoPen)
            p.setBrush(QColor(255, 214, 10))
            p.drawRect(0, 0, TILE, 22)
            p.setPen(QColor(0, 0, 0))
            f = p.font()
            f.setBold(True)
            f.setPointSizeF(max(8.0, f.pointSizeF() - 1))
            p.setFont(f)
            p.drawText(QRectF(0, 0, TILE, 22), Qt.AlignmentFlag.AlignCenter, "SOLD")
        if have:                                           # already in the folder: a tick
            p.setPen(Qt.PenStyle.NoPen)
            p.setBrush(QColor(48, 209, 88))
            p.drawEllipse(TILE - 34, TILE - 34, 26, 26)
            p.setPen(QPen(QColor("white"), 3, Qt.PenStyle.SolidLine, Qt.PenCapStyle.RoundCap, Qt.PenJoinStyle.RoundJoin))
            p.drawPolyline([_pt(TILE - 27, TILE - 21), _pt(TILE - 22, TILE - 16), _pt(TILE - 15, TILE - 26)])
        p.end()
        return out

    def _thumb(self, base: str, url: str) -> None:
        """(worker) A small copy of the photo for its tile."""
        if self.closed:
            return
        path = os.path.join(self.tmp, hashlib.sha1(url.encode()).hexdigest()[:20] + ".jpg")
        got, _why = self._get(url, path)
        if not got:
            return
        try:
            from PIL import Image
            with Image.open(got) as im:
                im = im.convert("RGB")
                im.thumbnail((TILE * 2, TILE * 2))
                small = path + ".t.jpg"
                im.save(small, "JPEG", quality=82)
        except Exception:  # noqa: BLE001 — not a picture: the tile stays grey
            return
        if not self.closed:
            self.bridge.call.emit(self._thumb_ready, (base, small))

    def _thumb_ready(self, got) -> None:
        base, path = got
        item = self.tiles.get(base)
        if item is None or self.closed:
            return
        self.pix[base] = QPixmap(path)
        item.setIcon(QIcon(self._tile(self.pix[base], depop.photo_id(base) in self.have, self.sold_state.get(base, False))))

    def _select_listing(self, item: QListWidgetItem) -> None:
        p = self.shop.photos.get(item.data(BASE))
        it = self.shop.listings.get(p.slug) if p else None
        for base in (it.photos if it else []):
            if base in self.tiles and not self.tiles[base].isHidden():
                self.tiles[base].setSelected(True)

    def _picked(self) -> list[depop.Photo]:
        order = {p.base: i for i, p in enumerate(self.shop.ordered())}
        bases = sorted((i.data(BASE) for i in self.grid.selectedItems()), key=lambda b: order.get(b, 1 << 30))
        return [self.shop.photos[b] for b in bases if b in self.shop.photos]

    def _count(self) -> None:
        picked = self._picked()
        fresh = [p for p in picked if p.key not in self.have]
        have = sum(1 for p in self.shop.photos.values() if p.key in self.have)
        self.counted.setText(f"{len(picked):,} selected of {len(self.shop.photos):,}"
                             + (f" · {have:,} already downloaded" if have else ""))
        self.go.setText(f"Download {len(fresh):,} Photo{'s' if len(fresh) != 1 else ''}" if fresh else "Download")
        self.go.setEnabled(bool(fresh) and not self.running)

    # ------------------------------------------------------------------ fetching (worker threads)
    def _get(self, url: str, path: str) -> tuple[str | None, str]:
        """`url` into `path`: a plain request; the window's browser when the picture server turns that away."""
        why = ""
        if not self.by_browser:
            got, why = social.fetch(url, path, self.tries)
            if got or "404" in why or "410" in why or self.closed:
                return got, why
        name = os.path.basename(path)
        got, said = self._browser_fetch(url, os.path.dirname(path), name)
        if got and os.path.getsize(got) >= social.MIN_BYTES:
            if not self.by_browser:
                self.by_browser = True
                self.bridge.call.emit(self._log, "The picture server turned plain requests away — downloading through "
                                                 "the page's browser instead.")
            return got, ""
        return None, why or said or "it couldn't be downloaded"

    def _browser_fetch(self, url: str, folder: str, name: str) -> tuple[str | None, str]:
        if self.closed:
            return None, "the window was closed"
        job = fx._Job(url, folder, name, owner=self)
        self.bridge.call.emit(self._begin_download, job)
        while not job.done.wait(0.5):
            idle = time.monotonic() - job.moved
            if self.closed or idle > (fx.STALL_S if job.started else fx.NO_START_S):
                self.bridge.call.emit(self._cancel_download, job)
                job.done.wait(10)
                return None, "the window was closed" if self.closed else "the browser didn't download it"
        return (job.path or None), job.why

    def _begin_download(self, job) -> None:
        if self.closed:
            job.why = "the window was closed"
            job.done.set()
            return
        fx._JOBS.setdefault(fx._key(QUrl(job.url)), []).append(job)
        self.view.page().download(QUrl(job.url), job.name)

    def _cancel_download(self, job) -> None:
        for key, jobs in list(fx._JOBS.items()):
            if job in jobs:
                jobs.remove(job)
                if not jobs:
                    fx._JOBS.pop(key, None)
        if job.request is not None and not job.request.isFinished():
            job.request.cancel()
        job.why = job.why or "stopped"
        job.done.set()

    def _best(self, photo: depop.Photo, tmp: str) -> tuple[str | None, str]:
        if self.stopping or self.closed:
            return None, "stopped"
        path, why, version = depop.fetch_best(photo, tmp, self._get)
        if path:
            self.versions[photo.key] = version
        return path, why

    # ------------------------------------------------------------------ downloading what's picked
    def download_selected(self) -> None:
        todo = [p for p in self._picked() if p.key not in self.have]
        if self.running or not todo or not self.shop.shop:
            return
        try:
            sc.make_folder(self.dest)
        except OSError as e:
            self._say(f"Couldn't make the folder “{self.dest}”: {e.strerror or e}")
            return
        self.running, self.stopping = True, False
        self.versions: dict[str, str] = {}
        self.written: list[str] = []
        self.upscaled: list[str] = []
        self.sold_files: set[str] = set()
        self.sold_keys = {p.key for p in todo if self._sold(p)}
        self.failed: list[tuple[str, str]] = []
        self.unsaved: set[str] = set()
        self.present = 0
        self.total, self.settled = len(todo), 0
        opts = social.Options(photos_2x=self.up_box.isChecked(), ai=self.engine is not None)
        self.bar.setRange(0, self.total)
        self.bar.setValue(0)
        self.bar.show()
        self.go.setEnabled(False)
        self.stop_btn.setEnabled(True)
        self._say(f"Downloading {self.total:,} photo(s)" + (", upscaling each 2×" if opts.photos_2x else "") + "…")
        self.pool = concurrent.futures.ThreadPoolExecutor(LANES, thread_name_prefix="depop")
        self.exif = sc.ExifSession(self.exiftool) if self.exiftool else None
        for p in todo:
            item = depop.item_for(p, self.shop.listings.get(p.slug), self.dest, self.shop.shop)
            fut = self.pool.submit(social.settle, item, self.tries, opts, self.exif,
                                   self.engine if opts.photos_2x else None, self.heavy,
                                   lambda _item, tmp, _tries, p=p: self._best(p, tmp))
            fut.add_done_callback(lambda f, p=p: self.bridge.call.emit(self._settled, (f, p)))

    def _settled(self, got) -> None:
        fut, photo = got
        if self.closed:
            return
        self.settled += 1
        self.bar.setValue(self.settled)
        try:
            s = fut.result()
        except concurrent.futures.CancelledError:
            s = None
        except Exception as e:  # noqa: BLE001 — one photo that throws is one that failed
            s = social.Settled(None, why=f"{type(e).__name__}: {e}")
        if s is not None and s.path:
            self.have.add(photo.key)
            self.unsaved.add(photo.key)
            if s.present:
                self.present += 1
            else:
                self.written.append(s.path)
                if s.upscaled:
                    self.upscaled.append(s.path)
                if photo.key in self.sold_keys:
                    self.sold_files.add(s.path)
                self._log(f"{os.path.basename(s.path)} — {self.versions.get(photo.key, 'as shown')}"
                          + (", upscaled 2×" if s.upscaled else ""))
            item = self.tiles.get(photo.base)
            if item is not None:
                item.setIcon(QIcon(self._tile(self.pix.get(photo.base), True)))
                item.setSelected(False)
                self._tip(photo)
        elif s is not None and not self.stopping:
            self.failed.append((depop.file_name(photo), s.why or "it couldn't be downloaded"))
            self._log(f"Couldn't get {depop.file_name(photo)}: {s.why or 'no reason given'}")
        if len(self.unsaved) >= SAVE_EVERY:
            self._save()
        if self.settled >= self.total:
            self._finish()
        elif not self.stopping:
            self._say(f"Downloading… {self.settled:,} of {self.total:,}")

    def _save(self) -> None:
        """The record brought up to date, and what's new tagged."""
        done, self.unsaved = self.unsaved, set()
        if done:
            try:
                if self.record is None:
                    self.record = depop.record(self.dest)
                self.record.save(done, photos=len(done), shop=self.shop.shop)
            except OSError as e:
                self._log(f"Couldn't save the folder's record: {e.strerror or e}")
        if self.tags is not None:
            fresh = [p for p in self.written if p not in self._tagged]
            try:
                if fresh:
                    self.tags.add(fresh, [depop.TAG])
                    up = [p for p in fresh if p in self.upscaled]
                    if up:
                        self.tags.add(up, [social.UPSCALED_TAG])
                    sold = [p for p in fresh if p in self.sold_files]
                    if sold:
                        self.tags.add(sold, [depop.SOLD_TAG])
                self._tagged.update(fresh)
            except OSError as e:
                self._log(f"Couldn't save the tags: {e.strerror or e}")

    def _finish(self) -> None:
        self._save()
        pool, self.pool = self.pool, None
        if pool is not None:
            pool.shutdown(wait=False, cancel_futures=True)
        self._close_exif()
        self.running = False
        self.bar.hide()
        self.stop_btn.setEnabled(False)
        n = len(self.written)
        said = (f"Downloaded {n:,} photo{'s' if n != 1 else ''} into “{self.dest.name}”" if n else "Nothing new was downloaded")
        if self.upscaled:
            said += f" ({len(self.upscaled):,} upscaled 2×)"
        if self.present:
            said += f"; {self.present:,} were already there"
        if self.failed:
            said += f"; {len(self.failed):,} couldn't be had (see below)"
        if self.stopping:
            said += " — stopped"
        self._say(said + ".")
        self._log(said + f". Folder: {self.dest}")
        self.stopping = False
        self._count()
        self.finished.emit(str(self.dest), list(self.written))

    def _close_exif(self) -> None:
        exif, self.exif = self.exif, None
        if exif is not None:
            try:
                exif.close()
            except Exception:  # noqa: BLE001
                pass

    def stop(self) -> None:
        if not self.running:
            return
        self.stopping = True
        self.stop_btn.setEnabled(False)
        self._say("Stopping — the photos in hand are finished first…")
        if self.pool is not None:
            self.pool.shutdown(wait=False, cancel_futures=True)

    def closeEvent(self, event) -> None:  # noqa: N802 — Qt override
        self.closed = self.stopping = True
        self.timer.stop()
        for jobs in list(fx._JOBS.values()):
            for job in list(jobs):
                if job.owner is self:
                    self._cancel_download(job)
        for pool in (self.pool, self.thumbs):
            if pool is not None:
                pool.shutdown(wait=False, cancel_futures=True)
        if self.running:
            try:
                self._save()
            except Exception:  # noqa: BLE001
                pass
            self.running = False
            self.finished.emit(str(self.dest), list(self.written))
        self._close_exif()
        shutil.rmtree(self.tmp, ignore_errors=True)
        super().closeEvent(event)


def _pt(x: float, y: float):
    from PySide6.QtCore import QPointF
    return QPointF(x, y)


def main() -> None:
    if len(sys.argv) < 2:
        print(__doc__)
        raise SystemExit(2)
    app = QApplication.instance() or QApplication(sys.argv)
    app.setApplicationName(app_identity.APP_NAME)
    win = DepopWindow(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else "")
    win.show()
    raise SystemExit(app.exec())


if __name__ == "__main__":
    main()
