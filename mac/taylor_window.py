"""The taylorpictures.net window in Safe Finder (taylor.py does the reading, matching and downloading) — the
iPhone app's gallery browser on the Mac, plus what you already have in your Taylor Swift folder.

- **Sections and albums**: one list, sections first (double-click to go in; ‹ Back or ⌘[ to come out),
  albums with their cover, a **Here** column and a photo count. Here says ✓ All here, "87 of 120", "Folder
  here" or nothing yet; **Check Albums Here** reads every album of the section and fills it in (by name —
  quick); an album's own page also checks by picture. The search field filters by title or id.
- **An album** (double-click it): its photos as a grid, a green ✓ on each one you already have — in the
  album's folder, elsewhere under another folder by name, or saved under another name (found by its
  picture). All / Missing / Here filters it. **Download N Missing** fetches just those; **Download All**
  everything not already in the album's folder. Double-click a photo you have to see it in the viewer;
  one you don't opens on the site.
- **Downloads** queue up — from an album, from the list (Download Selected, or Download All Not Here for
  the section) — and come down one album after another, eight photos at a time, into `<Taylor
  folder>/<album title>`, with the album's date when a photo has none. The bar at the bottom shows the
  album and its progress; Stop ends it (what's done stays, and running it again finishes it). **Skip
  photos already in Taylor Swift** (on by default) leaves out the ones found elsewhere in the folder.

What's here is worked out from `<Taylor folder>/.taylorpictures.json` (albums downloaded into it, by either
app), the folder's photos by name (at once) and by picture (a background pass, cached), and per-album checks
kept in `~/Library/Caches/PhotoBrowser/taylor/checks.json`.
"""
from __future__ import annotations

import json
import os
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from typing import Callable

from PySide6.QtCore import QObject, QSettings, QSize, Qt, QTimer, QUrl, Signal
from PySide6.QtGui import QColor, QDesktopServices, QFont, QIcon, QImage, QPainter, QPainterPath, QPen, QPixmap
from PySide6.QtWidgets import (QAbstractItemView, QButtonGroup, QCheckBox, QFrame, QHBoxLayout, QHeaderView, QLabel,
                               QLineEdit, QListView, QListWidget, QListWidgetItem, QProgressBar, QPushButton,
                               QStackedWidget, QToolButton, QTreeWidget, QTreeWidgetItem, QVBoxLayout, QWidget)

import taylor as T

THUMB = 132
ROLE_KIND, ROLE_ID = Qt.ItemDataRole.UserRole, Qt.ItemDataRole.UserRole + 1


@dataclass
class TaylorHooks:
    view: Callable[[list[str], str], None] | None = None     # (your photos, the one to start at)
    reveal: Callable[[str], None] | None = None
    changed: Callable[[str], None] | None = None             # a folder got new files


class Checks:
    """Per-album "how many are here" from Check Albums Here, kept between launches."""

    def __init__(self) -> None:
        self.path = T.CACHE_DIR / "checks.json"
        try:
            with open(self.path, encoding="utf-8") as f:
                self.data: dict[str, dict] = json.load(f)
        except (OSError, ValueError):
            self.data = {}

    def get(self, root: str, album: int) -> dict | None:
        return self.data.get(f"{root}|{album}")

    def put(self, root: str, album: int, total: int, have: int) -> None:
        self.data[f"{root}|{album}"] = {"total": total, "have": have, "checked": time.time()}

    def save(self) -> None:
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            tmp = self.path.with_suffix(".saving")
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(self.data, f)
            os.replace(tmp, self.path)
        except OSError:
            pass


class _Bridge(QObject):
    section = Signal(int, object, object, str)      # token, categories, albums, note
    images = Signal(int, object)                    # album id, a page of images
    images_done = Signal(int, object)               # album id, all images
    thumb = Signal(str, bytes)                      # url, bytes
    hashes = Signal(int, object)                    # album id, {full: hash}
    index = Signal(str, int, int)                   # stage ("names" | "pictures"), done, total
    checked = Signal(int, int, int)                 # album id, total, have
    check_done = Signal()
    dl_progress = Signal(int, int, int)             # album id, done, total
    dl_done = Signal(int, object)                   # album id, Outcome


def _badge(pm: QPixmap) -> QPixmap:
    """The ✓ for a photo you have, drawn on its thumbnail."""
    out = QPixmap(pm)
    p = QPainter(out)
    p.setRenderHint(QPainter.RenderHint.Antialiasing)
    d = max(18, min(26, out.width() // 5))
    r = out.rect().adjusted(out.width() - d - 5, out.height() - d - 5, -5, -5)
    p.setPen(QPen(QColor("white"), 1.6))
    p.setBrush(QColor("#30D158"))
    p.drawEllipse(r)
    p.setPen(QPen(QColor("white"), max(2.0, d / 9), Qt.PenStyle.SolidLine, Qt.PenCapStyle.RoundCap,
                  Qt.PenJoinStyle.RoundJoin))
    path = QPainterPath()
    path.moveTo(r.left() + d * 0.28, r.top() + d * 0.53)
    path.lineTo(r.left() + d * 0.44, r.top() + d * 0.69)
    path.lineTo(r.left() + d * 0.74, r.top() + d * 0.34)
    p.drawPath(path)
    p.end()
    return out


def _square(data: bytes, side: int) -> QPixmap | None:
    img = QImage.fromData(data)
    if img.isNull():
        return None
    img = img.scaled(side, side, Qt.AspectRatioMode.KeepAspectRatioByExpanding,
                     Qt.TransformationMode.SmoothTransformation)
    x, y = (img.width() - side) // 2, (img.height() - side) // 2
    return QPixmap.fromImage(img.copy(x, y, side, side))


class TaylorWindow(QWidget):
    def __init__(self, root: str, hooks: TaylorHooks, theme, parent=None,
                 gallery: T.Gallery | None = None) -> None:
        super().__init__(parent, Qt.WindowType.Window)
        self.setAttribute(Qt.WidgetAttribute.WA_DeleteOnClose)
        self.root = root
        self.hooks = hooks
        self.theme = theme
        self.gallery = gallery or T.Gallery()
        self.settings = QSettings("PhotoBrowser", "SafeFinder")
        self.record = T.Record(root)
        self.index = T.LocalIndex(root)
        self.checks = Checks()
        self.stop = threading.Event()                  # closing the window
        self.dl_stop = threading.Event()               # the download queue's Stop
        self.bridge = _Bridge()
        self.pool = ThreadPoolExecutor(max_workers=8)
        self.thumbs: dict[str, QPixmap] = {}
        self.thumb_wanted: set[str] = set()
        self.trail: list[tuple[int | None, str, int | None]] = []   # (section id, title, year)
        self.cats: list[T.Category] = []
        self.albums: list[T.Album] = []
        self.token = 0
        self.album: T.Album | None = None
        self.album_year: int | None = None
        self.images: list[T.Image] = []
        self.thumb_hashes: dict[str, int] = {}
        self.matches: dict[str, T.Match] = {}
        self.queue: list[tuple[T.Album, int | None, bool]] = []
        self.downloading: T.Album | None = None
        self.checking = False
        self.bridge.section.connect(self._section_loaded)
        self.bridge.images.connect(self._images_page)
        self.bridge.images_done.connect(self._images_done)
        self.bridge.thumb.connect(self._thumb_loaded)
        self.bridge.hashes.connect(self._hashes_ready)
        self.bridge.index.connect(self._index_progress)
        self.bridge.checked.connect(self._checked)
        self.bridge.check_done.connect(self._check_done)
        self.bridge.dl_progress.connect(self._dl_progress)
        self.bridge.dl_done.connect(self._dl_done)
        self.setWindowTitle("taylorpictures.net")
        self.resize(1080, 780)
        self._build()
        self._build_index()
        self.open_section(None, "taylorpictures.net", None)

    # ------------------------------------------------------------------ layout
    def _build(self) -> None:
        t = self.theme
        self.setStyleSheet(f"""
            #TayTop, #TayBar {{ background: {t.header}; }}
            #TayTop {{ border-bottom: 1px solid {t.border}; }}
            #TayBar {{ border-top: 1px solid {t.border}; }}
            QToolButton#TayFilter {{ border: 1px solid {t.button_border}; border-radius: 12px; padding: 3px 11px;
                                     background: {t.button}; }}
            QToolButton#TayFilter:checked {{ background: {t.accent}; color: white; border-color: {t.accent}; }}
            QToolButton#TayBack {{ border: 1px solid {t.button_border}; border-radius: 6px; padding: 3px 10px;
                                   background: {t.button}; font-size: 15px; }}
            QListWidget#TayGrid {{ background: {t.content}; border: none; }}
            QTreeWidget#TayList::item {{ height: 52px; }}
        """)
        v = QVBoxLayout(self)
        v.setContentsMargins(0, 0, 0, 0)
        v.setSpacing(0)
        top = QFrame()
        top.setObjectName("TayTop")
        tv = QVBoxLayout(top)
        tv.setContentsMargins(16, 12, 16, 10)
        tv.setSpacing(8)
        row = QHBoxLayout()
        self.back_btn = QToolButton()
        self.back_btn.setObjectName("TayBack")
        self.back_btn.setText("‹")
        self.back_btn.setToolTip("Back (⌘[)")
        self.back_btn.setShortcut("Ctrl+[")
        self.back_btn.clicked.connect(self.back)
        row.addWidget(self.back_btn)
        self.title = QLabel("taylorpictures.net")
        self.title.setObjectName("SheetTitle")
        row.addWidget(self.title, 1)
        self.search = QLineEdit()
        self.search.setObjectName("Search")
        self.search.setPlaceholderText("Find an album")
        self.search.setClearButtonEnabled(True)
        self.search.setFixedWidth(220)
        self.search.textChanged.connect(self._filter_list)
        row.addWidget(self.search)
        tv.addLayout(row)
        row2 = QHBoxLayout()
        self.where = QLabel(f"Your Taylor Swift folder: {self.root}")
        self.where.setObjectName("SheetSub")
        row2.addWidget(self.where, 1)
        self.skip_box = QCheckBox("Skip photos already in Taylor Swift")
        self.skip_box.setToolTip("Leave out photos found elsewhere in the folder (by name or by picture)")
        self.skip_box.setChecked(str(self.settings.value("taylor/skip_have", "true")) == "true")
        self.skip_box.toggled.connect(lambda on: self.settings.setValue("taylor/skip_have", "true" if on else "false"))
        row2.addWidget(self.skip_box)
        tv.addLayout(row2)
        self.status = QLabel("")
        self.status.setObjectName("SheetSub")
        tv.addWidget(self.status)
        v.addWidget(top)
        self.stack = QStackedWidget()
        v.addWidget(self.stack, 1)
        # -- a section
        sec = QWidget()
        sv = QVBoxLayout(sec)
        sv.setContentsMargins(0, 0, 0, 0)
        sv.setSpacing(0)
        self.tree = QTreeWidget()
        self.tree.setObjectName("TayList")
        self.tree.setColumnCount(3)
        self.tree.setHeaderLabels(["Album", "Here", "Photos"])
        self.tree.setRootIsDecorated(False)
        self.tree.setUniformRowHeights(True)
        self.tree.setIconSize(QSize(44, 44))
        self.tree.setSelectionMode(QAbstractItemView.SelectionMode.ExtendedSelection)
        self.tree.header().setSectionResizeMode(0, QHeaderView.ResizeMode.Stretch)
        self.tree.header().setSectionResizeMode(1, QHeaderView.ResizeMode.ResizeToContents)
        self.tree.header().setSectionResizeMode(2, QHeaderView.ResizeMode.ResizeToContents)
        self.tree.itemActivated.connect(self._activated)
        self.tree.itemSelectionChanged.connect(self._update_buttons)
        self.tree.verticalScrollBar().valueChanged.connect(lambda _v: self._want_visible_covers())
        sv.addWidget(self.tree, 1)
        self.stack.addWidget(sec)
        # -- an album
        alb = QWidget()
        av = QVBoxLayout(alb)
        av.setContentsMargins(16, 10, 16, 0)
        av.setSpacing(8)
        self.album_facts = QLabel("")
        self.album_facts.setObjectName("SheetSub")
        self.album_facts.setWordWrap(True)
        av.addWidget(self.album_facts)
        frow = QHBoxLayout()
        self.filters = QButtonGroup(self)
        self.filter_btns: dict[str, QToolButton] = {}
        for key, label in (("all", "All"), ("missing", "Missing"), ("have", "Here")):
            b = QToolButton()
            b.setObjectName("TayFilter")
            b.setText(label)
            b.setCheckable(True)
            b.setChecked(key == "all")
            b.clicked.connect(lambda _=False, k=key: self._apply_grid_filter(k))
            self.filters.addButton(b)
            self.filter_btns[key] = b
            frow.addWidget(b)
        frow.addStretch(1)
        self.folder_btn = QPushButton("Show Folder")
        self.folder_btn.clicked.connect(self._show_album_folder)
        frow.addWidget(self.folder_btn)
        self.all_btn = QPushButton("Download All")
        self.all_btn.clicked.connect(lambda: self.enqueue([self.album], skip_have=False) if self.album else None)
        frow.addWidget(self.all_btn)
        self.missing_btn = QPushButton("Download Missing")
        self.missing_btn.setObjectName("Primary")
        self.missing_btn.clicked.connect(lambda: self.enqueue([self.album], skip_have=True) if self.album else None)
        frow.addWidget(self.missing_btn)
        av.addLayout(frow)
        self.grid = QListWidget()
        self.grid.setObjectName("TayGrid")
        self.grid.setViewMode(QListView.ViewMode.IconMode)
        self.grid.setIconSize(QSize(THUMB, THUMB))
        self.grid.setGridSize(QSize(THUMB + 16, THUMB + 40))
        self.grid.setResizeMode(QListView.ResizeMode.Adjust)
        self.grid.setMovement(QListView.Movement.Static)
        self.grid.setUniformItemSizes(True)
        self.grid.setWordWrap(False)
        self.grid.setSelectionMode(QAbstractItemView.SelectionMode.ExtendedSelection)
        self.grid.itemActivated.connect(self._photo_activated)
        av.addWidget(self.grid, 1)
        self.stack.addWidget(alb)
        # -- the bottom bar: list actions, then the download queue
        bar = self.bar = QFrame()
        bar.setObjectName("TayBar")
        bv = QVBoxLayout(bar)
        bv.setContentsMargins(16, 8, 16, 10)
        bv.setSpacing(6)
        brow = QHBoxLayout()
        self.check_btn = QPushButton("Check Albums Here")
        self.check_btn.setToolTip("Read every album in this section and count the photos already in your folder")
        self.check_btn.clicked.connect(self.check_albums)
        brow.addWidget(self.check_btn)
        brow.addStretch(1)
        self.sel_btn = QPushButton("Download Selected")
        self.sel_btn.clicked.connect(self._download_selected)
        brow.addWidget(self.sel_btn)
        self.notyet_btn = QPushButton("Download All Not Here")
        self.notyet_btn.setObjectName("Primary")
        self.notyet_btn.clicked.connect(self._download_not_here)
        brow.addWidget(self.notyet_btn)
        bv.addLayout(brow)
        qrow = QHBoxLayout()
        self.dl_label = QLabel("")
        self.dl_label.setObjectName("SheetSub")
        qrow.addWidget(self.dl_label, 1)
        self.dl_bar = QProgressBar()
        self.dl_bar.setFixedWidth(260)
        qrow.addWidget(self.dl_bar)
        self.dl_stop_btn = QPushButton("Stop")
        self.dl_stop_btn.clicked.connect(self.stop_downloads)
        qrow.addWidget(self.dl_stop_btn)
        self.dl_row = QWidget()
        self.dl_row.setLayout(qrow)
        self.dl_row.setVisible(False)
        bv.addWidget(self.dl_row)
        v.addWidget(bar)
        self.list_buttons = (self.check_btn, self.sel_btn, self.notyet_btn)

    # ------------------------------------------------------------------ your folder
    def _build_index(self) -> None:
        stop, bridge, index = self.stop, self.bridge, self.index

        def work() -> None:
            index.build_names(stop)
            if stop.is_set():
                return
            bridge.index.emit("names", index.photos, index.photos)
            index.build_pictures(lambda i, n: bridge.index.emit("pictures", i, n), stop)
        threading.Thread(target=work, daemon=True).start()
        self.where.setText(f"Your Taylor Swift folder: {self.root} — looking through it…")

    def _index_progress(self, stage: str, done: int, total: int) -> None:
        base = f"Your Taylor Swift folder: {self.root} — {self.index.photos:,} photos"
        if stage == "pictures" and done < total:
            self.where.setText(f"{base}; matching by picture {done * 100 // max(total, 1)}%…")
        elif stage == "pictures":
            self.where.setText(f"{base}, matched by name and by picture.")
        elif not self.index.pictures_ready:
            self.where.setText(f"{base}; matching by picture…")
        if stage == "names" or (stage == "pictures" and done >= total):
            self._refresh_here()
            if self.album is not None:
                self._rematch()

    # ------------------------------------------------------------------ sections
    def open_section(self, cat: int | None, title: str, year: int | None, push: bool = True) -> None:
        if push:
            self.trail.append((cat, title, year))
        self.album = None
        self.stack.setCurrentIndex(0)
        self.title.setText(" › ".join(t for _c, t, _y in self.trail[-3:]))
        self.back_btn.setEnabled(len(self.trail) > 1)
        self.search.setPlaceholderText("Find an album")
        self.tree.clear()
        self.cats, self.albums = [], []
        self.status.setText("Loading…")
        self.token += 1
        token, bridge, gallery = self.token, self.bridge, self.gallery

        def work() -> None:
            cats, albums, note = gallery.browse(cat)
            bridge.section.emit(token, cats, albums, note)
        self.pool.submit(work)
        self._update_buttons()

    def back(self) -> None:
        if self.stack.currentIndex() == 1:
            cat, title, year = self.trail[-1]
            self.open_section(cat, title, year, push=False)
            return
        if len(self.trail) > 1:
            self.trail.pop()
            cat, title, year = self.trail[-1]
            self.open_section(cat, title, year, push=False)

    def _section_loaded(self, token: int, cats, albums, note: str) -> None:
        if token != self.token:
            return
        self.cats, self.albums = cats, albums
        year = self.trail[-1][2]
        bold = QFont(self.tree.font())
        bold.setWeight(QFont.Weight.DemiBold)
        for c in cats:
            it = QTreeWidgetItem([c.title, "", ""])
            it.setData(0, ROLE_KIND, "section")
            it.setData(0, ROLE_ID, c.id)
            it.setFont(0, bold)
            it.setIcon(0, self.style().standardIcon(self.style().StandardPixmap.SP_DirIcon))
            self.tree.addTopLevelItem(it)
        for a in albums:
            it = QTreeWidgetItem([a.title or f"Album {a.id}", "", ""])
            it.setData(0, ROLE_KIND, "album")
            it.setData(0, ROLE_ID, a.id)
            it.setToolTip(0, a.title)
            it.setIcon(0, self._placeholder())          # the cover replaces it as it comes
            self.tree.addTopLevelItem(it)
        n = len(albums)
        self.status.setText(note or (f"{len(cats):,} section{'s' if len(cats) != 1 else ''}, " if cats else "") +
                            (f"{n:,} album{'s' if n != 1 else ''}." if n or not cats else "") +
                            (f"  Albums here are dated {year}." if year and n else ""))
        self._refresh_here()
        self._filter_list(self.search.text())
        QTimer.singleShot(0, self._want_visible_covers)

    def _placeholder(self) -> QIcon:
        if not hasattr(self, "_blank"):
            pm = QPixmap(44, 44)
            pm.fill(Qt.GlobalColor.transparent)
            p = QPainter(pm)
            p.setRenderHint(QPainter.RenderHint.Antialiasing)
            p.setPen(Qt.PenStyle.NoPen)
            p.setBrush(QColor("#3A3A3C") if self.theme.dark else QColor("#E5E5EA"))
            p.drawRoundedRect(0, 0, 44, 44, 6, 6)
            p.end()
            self._blank = QIcon(pm)
        return self._blank

    def _album_by_id(self, aid: int) -> T.Album | None:
        return next((a for a in self.albums if a.id == aid), None)

    def _here_text(self, a: T.Album) -> tuple[str, str]:
        """(Here column, Photos column) for an album."""
        entry = self.record.albums.get(str(a.id))
        chk = self.checks.get(self.root, a.id)
        if entry and self.record.is_complete(a.id):
            return "✓ All here", str(entry.get("total") or "")
        if chk:
            total, have = int(chk["total"]), int(chk["have"])
            if total and have >= total:
                return "✓ All here", str(total)
            return (f"{have:,} of {total:,}" if have else "None here"), str(total)
        if entry:
            return f"{len(entry.get('files') or []):,} of {entry.get('total') or '?'}", str(entry.get("total") or "")
        if self.index.names_ready and self.index.album_folders(a, self.record):
            return "Folder here", ""
        return "", ""

    def _refresh_here(self) -> None:
        green = QColor(self.theme.green)
        for i in range(self.tree.topLevelItemCount()):
            it = self.tree.topLevelItem(i)
            if it.data(0, ROLE_KIND) != "album":
                continue
            a = self._album_by_id(it.data(0, ROLE_ID))
            if a is None:
                continue
            here, count = self._here_text(a)
            if self.downloading is not None and self.downloading.id == a.id:
                here = "Downloading…"
            elif any(q[0].id == a.id for q in self.queue):
                here = "Queued"
            it.setText(1, here)
            it.setText(2, count)
            it.setForeground(1, green if here.startswith("✓") else QColor(self.theme.secondary))
        self._update_buttons()

    def _filter_list(self, text: str) -> None:
        q = text.strip().lower()
        if self.stack.currentIndex() == 1:
            for i in range(self.grid.count()):
                it = self.grid.item(i)
                it.setHidden(bool(q) and q not in it.text().lower() or self._grid_hidden(it))
            return
        for i in range(self.tree.topLevelItemCount()):
            it = self.tree.topLevelItem(i)
            it.setHidden(bool(q) and q not in it.text(0).lower() and q != str(it.data(0, ROLE_ID)))
        QTimer.singleShot(0, self._want_visible_covers)

    def _want_visible_covers(self) -> None:
        if self.stack.currentIndex() != 0:
            return
        vp = self.tree.viewport().rect()
        for i in range(self.tree.topLevelItemCount()):
            it = self.tree.topLevelItem(i)
            if it.isHidden() or it.data(0, ROLE_KIND) != "album":
                continue
            if not self.tree.visualItemRect(it).intersects(vp):
                continue
            a = self._album_by_id(it.data(0, ROLE_ID))
            if a and a.thumb:
                if a.thumb in self.thumbs:
                    it.setIcon(0, QIcon(self.thumbs[a.thumb]))
                else:
                    self._want_thumb(a.thumb)

    def _activated(self, it: QTreeWidgetItem, _col: int) -> None:
        kind, ident = it.data(0, ROLE_KIND), it.data(0, ROLE_ID)
        year = self.trail[-1][2]
        if kind == "section":
            self.search.clear()
            self.open_section(ident, it.text(0), T.year_of(it.text(0), year))
        elif (a := self._album_by_id(ident)) is not None:
            self.open_album(a, year)

    def _selected_albums(self) -> list[T.Album]:
        out = []
        for it in self.tree.selectedItems():
            if it.data(0, ROLE_KIND) == "album" and (a := self._album_by_id(it.data(0, ROLE_ID))):
                out.append(a)
        return out

    def _not_here(self) -> list[T.Album]:
        out = []
        for i in range(self.tree.topLevelItemCount()):
            it = self.tree.topLevelItem(i)
            if it.isHidden() or it.data(0, ROLE_KIND) != "album":
                continue
            if not it.text(1).startswith("✓") and it.text(1) not in ("Queued", "Downloading…"):
                a = self._album_by_id(it.data(0, ROLE_ID))
                if a:
                    out.append(a)
        return out

    def _update_buttons(self) -> None:
        on_list = self.stack.currentIndex() == 0
        for b in self.list_buttons:
            b.setVisible(on_list)
        self.bar.setVisible(on_list or self.downloading is not None or bool(self.queue))
        sel = self._selected_albums()
        self.sel_btn.setText(f"Download {len(sel)} Selected" if sel else "Download Selected")
        self.sel_btn.setEnabled(bool(sel))
        rest = self._not_here() if on_list else []
        self.notyet_btn.setText(f"Download {len(rest)} Not Here" if rest else "Everything here is downloaded"
                                if self.albums else "Download All Not Here")
        self.notyet_btn.setEnabled(bool(rest))
        self.check_btn.setEnabled(bool(self.albums) and not self.checking)

    def _download_selected(self) -> None:
        self.enqueue(self._selected_albums(), skip_have=True)

    def _download_not_here(self) -> None:
        self.enqueue(self._not_here(), skip_have=True)

    # ------------------------------------------------------------------ Check Albums Here
    def check_albums(self) -> None:
        albums = [a for a in self.albums]
        if not albums or self.checking:
            return
        self.checking = True
        self._update_buttons()
        self.status.setText(f"Checking {len(albums):,} albums against your folder…")
        stop, bridge, gallery, index, record = self.stop, self.bridge, self.gallery, self.index, self.record

        def one(a: T.Album) -> None:
            if stop.is_set():
                return
            imgs = gallery.images(a.id)
            if imgs and index.names_ready:
                m = T.match(a, imgs, index, record)
                bridge.checked.emit(a.id, len(imgs), sum(1 for x in m.values() if x.have))

        def work() -> None:
            with ThreadPoolExecutor(max_workers=4) as pool:
                list(pool.map(one, albums))
            bridge.check_done.emit()
        threading.Thread(target=work, daemon=True).start()

    def _checked(self, aid: int, total: int, have: int) -> None:
        self.checks.put(self.root, aid, total, have)
        self._refresh_here()

    def _check_done(self) -> None:
        self.checking = False
        self.checks.save()
        done = sum(1 for a in self.albums if self.checks.get(self.root, a.id))
        full = sum(1 for a in self.albums if (c := self.checks.get(self.root, a.id)) and c["have"] >= c["total"])
        self.status.setText(f"Checked {done:,} albums: {full:,} all here, {done - full:,} with photos to get "
                            "(by name — an album's own page also checks by picture).")
        self._update_buttons()

    # ------------------------------------------------------------------ an album
    def open_album(self, album: T.Album, year: int | None) -> None:
        self.album, self.album_year = album, year
        self.images, self.thumb_hashes, self.matches = [], {}, {}
        self.grid.clear()
        self.stack.setCurrentIndex(1)
        self.back_btn.setEnabled(True)
        self.title.setText(album.title or f"Album {album.id}")
        self.search.clear()
        self.search.setPlaceholderText("Find a photo")
        for k, b in self.filter_btns.items():
            b.setChecked(k == "all")
        when = T.album_date(album.title, year)
        place = T.album_place(album.title)
        self._facts_base = " · ".join(x for x in (when.strftime("%B %-d, %Y") if when and (when.month, when.day) != (1, 1)
                                                  else (str(when.year) if when else ""), place or "") if x)
        self.album_facts.setText((self._facts_base + " · " if self._facts_base else "") + "Listing…")
        self.status.setText("")
        self._update_buttons()
        bridge, gallery, aid = self.bridge, self.gallery, album.id

        def work() -> None:
            imgs = gallery.images(aid, on_page=lambda batch: bridge.images.emit(aid, batch))
            bridge.images_done.emit(aid, imgs)
        self.pool.submit(work)

    def _images_page(self, aid: int, batch) -> None:
        if self.album is None or aid != self.album.id:
            return
        for img in batch:
            it = QListWidgetItem(img.filename)
            it.setData(ROLE_ID, img.full)
            it.setToolTip(img.filename)
            it.setSizeHint(QSize(THUMB + 16, THUMB + 40))
            self.grid.addItem(it)
            self._want_thumb(img.thumb)
        self.images.extend(batch)

    def _images_done(self, aid: int, imgs) -> None:
        if self.album is None or aid != self.album.id:
            return
        if not imgs:
            self.album_facts.setText("No photos found in this album (or the site didn't answer).")
            return
        if len(self.images) != len(imgs):                 # came from memory in one go
            self.grid.clear()
            self.images = []
            self._images_page(aid, imgs)
        self._rematch()
        if self.index.pictures_ready:
            self._hash_thumbs()

    def _hash_thumbs(self) -> None:
        """The album's thumbnails' fingerprints (from the cached bytes), for finding renamed copies."""
        album, gallery, bridge, imgs = self.album, self.gallery, self.bridge, list(self.images)

        def work() -> None:
            out = {}
            for img in imgs:
                h = T.thumb_hash(gallery.thumb(img.thumb))
                if h is not None:
                    out[img.full] = h
            bridge.hashes.emit(album.id, out)
        self.pool.submit(work)

    def _hashes_ready(self, aid: int, hashes) -> None:
        if self.album is not None and aid == self.album.id:
            self.thumb_hashes = hashes
            self._rematch()

    def _rematch(self) -> None:
        if self.album is None or not self.images or not self.index.names_ready:
            return
        if self.index.pictures_ready and not self.thumb_hashes:
            self._hash_thumbs()
        self.matches = T.match(self.album, self.images, self.index, self.record, self.thumb_hashes)
        have = sum(1 for m in self.matches.values() if m.have)
        total = len(self.images)
        self.checks.put(self.root, self.album.id, total, have)
        self.checks.save()
        by_pic = sum(1 for m in self.matches.values() if m.how == "picture")
        text = f"{total:,} photos — {have:,} already in Taylor Swift" if have else f"{total:,} photos — none here yet"
        if by_pic:
            text += f" ({by_pic:,} saved under another name)"
        if not self.index.pictures_ready:
            text += " · still matching by picture…"
        self.album_facts.setText((self._facts_base + " · " if self._facts_base else "") + text)
        missing = total - have
        self.missing_btn.setText(f"Download {missing:,} Missing" if missing else "All Here")
        self.missing_btn.setEnabled(missing > 0 and not self._queued(self.album))
        self.all_btn.setEnabled(not self._queued(self.album))
        self.folder_btn.setEnabled(bool(self.index.album_folders(self.album, self.record)) and self.hooks.reveal is not None)
        self.filter_btns["missing"].setText(f"Missing ({missing:,})")
        self.filter_btns["have"].setText(f"Here ({have:,})")
        for i in range(self.grid.count()):
            it = self.grid.item(i)
            m = self.matches.get(it.data(ROLE_ID))
            if m and m.have:
                rel = os.path.relpath(m.path, self.root)
                how = {"folder": "in the album's folder", "name": "by name",
                       "picture": "by picture, under another name"}[m.how]
                it.setToolTip(f"{it.text()}\nAlready in Taylor Swift ({how}): {rel}")
            self._paint_item(it)
        self._apply_grid_filter(next(k for k, b in self.filter_btns.items() if b.isChecked()))
        self._refresh_here()

    def _queued(self, album: T.Album | None) -> bool:
        return album is not None and ((self.downloading is not None and self.downloading.id == album.id)
                                      or any(q[0].id == album.id for q in self.queue))

    def _paint_item(self, it: QListWidgetItem) -> None:
        img = next((i for i in self.images if i.full == it.data(ROLE_ID)), None)
        if img is None or img.thumb not in self.thumbs:
            return
        pm = self.thumbs[img.thumb]
        m = self.matches.get(img.full)
        it.setIcon(QIcon(_badge(pm) if m and m.have else pm))

    def _grid_hidden(self, it: QListWidgetItem) -> bool:
        mode = next(k for k, b in self.filter_btns.items() if b.isChecked())
        have = bool((m := self.matches.get(it.data(ROLE_ID))) and m.have)
        return (mode == "missing" and have) or (mode == "have" and not have)

    def _apply_grid_filter(self, _key: str) -> None:
        q = self.search.text().strip().lower()
        for i in range(self.grid.count()):
            it = self.grid.item(i)
            it.setHidden(self._grid_hidden(it) or (bool(q) and q not in it.text().lower()))

    def _photo_activated(self, it: QListWidgetItem) -> None:
        m = self.matches.get(it.data(ROLE_ID))
        if m and m.have and self.hooks.view is not None:
            mine = [x.path for x in self.matches.values() if x.have and x.path]
            self.hooks.view(mine, m.path)
        else:
            QDesktopServices.openUrl(QUrl(it.data(ROLE_ID)))

    def _show_album_folder(self) -> None:
        if self.album is not None and self.hooks.reveal is not None:
            folders = self.index.album_folders(self.album, self.record)
            if folders:
                self.hooks.reveal(folders[0])

    # ------------------------------------------------------------------ thumbnails
    def _want_thumb(self, url: str) -> None:
        if not url or url in self.thumbs or url in self.thumb_wanted:
            return
        self.thumb_wanted.add(url)
        gallery, bridge, stop = self.gallery, self.bridge, self.stop

        def work() -> None:
            if stop.is_set():
                return
            data = gallery.thumb(url)
            if data:
                bridge.thumb.emit(url, data)
        self.pool.submit(work)

    def _thumb_loaded(self, url: str, data: bytes) -> None:
        pm = _square(data, THUMB)
        if pm is None:
            return
        self.thumbs[url] = pm
        if self.stack.currentIndex() == 1:
            for i in range(self.grid.count()):
                it = self.grid.item(i)
                img = next((x for x in self.images if x.thumb == url and x.full == it.data(ROLE_ID)), None)
                if img is not None:
                    self._paint_item(it)
        else:
            for i in range(self.tree.topLevelItemCount()):
                it = self.tree.topLevelItem(i)
                a = self._album_by_id(it.data(0, ROLE_ID)) if it.data(0, ROLE_KIND) == "album" else None
                if a and a.thumb == url:
                    it.setIcon(0, QIcon(pm))

    # ------------------------------------------------------------------ downloading
    def enqueue(self, albums: list[T.Album], skip_have: bool = True) -> None:
        year = self.album_year if self.stack.currentIndex() == 1 else self.trail[-1][2]
        added = 0
        for a in albums:
            if a is None or self._queued(a):
                continue
            self.queue.append((a, year, skip_have and self.skip_box.isChecked()))
            added += 1
        if added:
            self.status.setText(f"Queued {added:,} album{'s' if added != 1 else ''}.")
        self._refresh_here()
        if self.album is not None:
            self._rematch()
        self._next_download()

    def _next_download(self) -> None:
        if self.downloading is not None or not self.queue:
            if not self.queue and self.downloading is None:
                self.dl_row.setVisible(False)
            return
        album, year, skip = self.queue.pop(0)
        self.downloading = album
        self.dl_stop.clear()
        self.dl_row.setVisible(True)
        self.bar.setVisible(True)
        self.dl_bar.setRange(0, 0)
        self._dl_label(album, 0, 0)
        gallery, root, record, index, stop, bridge = self.gallery, self.root, self.record, self.index, \
            self.dl_stop, self.bridge
        import simpcity as sc
        tool_path = sc.find_exiftool()

        def work() -> None:
            tool = sc.ExifSession(tool_path) if tool_path else None
            try:
                out = T.download_album(gallery, album, root, year, record, index, skip_have=skip,
                                       progress=lambda d, n, _name: bridge.dl_progress.emit(album.id, d, n), stop=stop,
                                       tool=tool)
            finally:
                if tool is not None:
                    tool.close()
            bridge.dl_done.emit(album.id, out)
        threading.Thread(target=work, daemon=True).start()
        self._refresh_here()

    def _dl_label(self, album: T.Album, done: int, total: int) -> None:
        more = len(self.queue)
        self.dl_label.setText(f"Downloading “{album.title or album.id}” — " +
                              (f"{done:,} of {total:,}" if total else "listing…") +
                              (f" · {more} more album{'s' if more != 1 else ''} queued" if more else ""))

    def _dl_progress(self, aid: int, done: int, total: int) -> None:
        if self.downloading is None or self.downloading.id != aid:
            return
        self.dl_bar.setRange(0, total)
        self.dl_bar.setValue(done)
        self._dl_label(self.downloading, done, total)

    def _dl_done(self, aid: int, out) -> None:
        album = self.downloading
        self.downloading = None
        bits = []
        if out.downloaded:
            bits.append(f"downloaded {out.downloaded:,}")
        if out.already:
            bits.append(f"{out.already:,} already in its folder")
        if out.elsewhere:
            bits.append(f"{out.elsewhere:,} skipped — already elsewhere in Taylor Swift")
        if out.failed:
            bits.append(f"{out.failed:,} couldn't be downloaded")
        title = album.title if album else str(aid)
        msg = (f"“{title}”: " + ", ".join(bits) + "." if bits else f"“{title}”: {out.note or 'nothing to do.'}")
        if out.stopped:
            msg = f"Stopped “{title}” — {out.downloaded:,} downloaded. Download it again to finish."
        self.status.setText(msg)
        self.record.load()
        if out.files:
            # the new files count by name once the folder's been looked through again (off the main thread —
            # a big folder on the SSD takes a moment); their fingerprints come with the next full look
            index, stop, bridge = self.index, self.stop, self.bridge

            def relist() -> None:
                index.build_names(stop)
                bridge.index.emit("names", index.photos, index.photos)
            self.pool.submit(relist)
            if self.hooks.changed is not None and out.folder:
                self.hooks.changed(out.folder)
        if album is not None:
            if out.total and not out.stopped:          # everything it has is now in the folder, one way or another
                got = out.downloaded + out.already + out.elsewhere
                self.checks.put(self.root, album.id, out.total, got)
            else:
                self.checks.data.pop(f"{self.root}|{album.id}", None)
            self.checks.save()
        self._refresh_here()
        if self.album is not None:
            self._rematch()
        if out.stopped:
            self.queue.clear()
            self.dl_row.setVisible(False)
            return
        self._next_download()

    def stop_downloads(self) -> None:
        self.queue.clear()
        self.dl_stop.set()
        self.dl_label.setText("Stopping…")

    def closeEvent(self, event) -> None:  # noqa: N802
        self.stop.set()
        self.dl_stop.set()
        self.queue.clear()
        self.checks.save()
        self.pool.shutdown(wait=False, cancel_futures=True)
        super().closeEvent(event)
