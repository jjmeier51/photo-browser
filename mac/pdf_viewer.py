"""Safe Finder's PDF viewer — a PDF opens here (double-click, Return) instead of in Preview, in the photo viewer's
dark look: the pages scrolling one after another, fitted to the width, with search, zoom and page thumbnails.

**The window** opens over Safe Finder's window, on its display, as tall as the display (like the photo viewer),
and as wide as the first page's shape at that height allows.

- **Reading**: scroll, ←/→ (or Page Up / Page Down) a page at a time, the page box at the bottom to jump; zoom with
  −/+ (or ⌘-scroll, pinch), the zoom menu for Fit Width / Fit Page / sizes; ⌘F searches — every match marked,
  Return for the next (⇧Return the one before); ☰ shows the pages as thumbnails. Esc closes.
- **Optimize for Safe Finder** — a new PDF beside the original, trimmed to its content (the same box on every
  page) with blank pages left out, so the page — not its margins — fills this viewer. **Optimize for iPhone** — a
  new PDF made for the iPhone 17 Pro Max: pages the shape of its screen, margins trimmed, two-column pages read a
  column at a time (larger), content flowing from page to page and cut only between lines (`pdf_optimize`). The
  new PDF opens here when it's made (Back to Original returns); the iPhone one can go straight to the iPhone
  (AirDrop to iPhone — Photo Browser there takes it), or travels on the drive beside the original.
- **⋯**: Open With Default App (Preview), Show in Folder, AirDrop to iPhone.

It doesn't touch files itself: Safe Finder's `PdfHooks` put the new PDF on the drive (safely: `simpcity.place`),
give it the original's tags, show a file in its pane and AirDrop.
"""
from __future__ import annotations

import os
import threading
from dataclasses import dataclass
from typing import Callable

from PySide6.QtCore import QModelIndex, QPointF, QRect, QSize, Qt, QTimer, QUrl, Signal
from PySide6.QtGui import QColor, QDesktopServices, QIcon, QKeySequence, QPalette, QPixmap, QShortcut
from PySide6.QtWidgets import (QApplication, QFrame, QHBoxLayout, QInputDialog, QLabel, QLineEdit, QListWidget,
                               QListWidgetItem, QMenu, QPushButton, QSizePolicy, QToolButton, QVBoxLayout, QWidget)

import media_viewer as mv
import pdf_optimize


def available() -> bool:
    """Whether this PySide6 has Qt's PDF modules (the viewer needs them; without, PDFs open in Preview)."""
    try:
        from PySide6.QtPdf import QPdfDocument  # noqa: F401
        from PySide6.QtPdfWidgets import QPdfView  # noqa: F401
        return True
    except ImportError:
        return False


def is_pdf(path: str) -> bool:
    return path.lower().endswith(".pdf")


@dataclass
class PdfHooks:
    """What the viewer asks of Safe Finder (each may be None)."""
    place: Callable[[str, str, str], str] | None = None          # (temp file, folder, name) → where it went
    carry_tags: Callable[[list[tuple[str, str]]], None] | None = None   # [(original, new)]
    reveal: Callable[[str], None] | None = None
    airdrop: Callable[[list[str], Callable[[str], None]], None] | None = None   # (files, note)
    made: Callable[[str], None] | None = None                    # a new PDF was made (refresh the listing)


PDF_STYLE = mv.VIEWER_STYLE + """
QPushButton#Optimize { color: #F2F2F7; background: rgba(255,255,255,0.10); border: 1px solid rgba(255,255,255,0.16);
                       border-radius: 7px; padding: 4px 10px; font-size: 12px; font-weight: 600; }
QPushButton#Optimize:hover { background: rgba(255,255,255,0.18); }
QPushButton#Optimize:disabled { color: #636366; }
QPushButton#ResultButton { color: #0A84FF; background: transparent; border: none; padding: 2px 6px; font-size: 12px; }
QPushButton#ResultButton:hover { text-decoration: underline; }
QLineEdit#PdfSearch, QLineEdit#PdfPage { color: #F2F2F7; background: rgba(255,255,255,0.10);
                       border: 1px solid rgba(255,255,255,0.14); border-radius: 6px; padding: 3px 7px; font-size: 12px; }
QListWidget#PdfThumbs { background: #1C1C1E; border: none; border-right: 1px solid #2C2C2E; color: #C7C7CC; }
QListWidget#PdfThumbs::item:selected { background: rgba(10,132,255,0.35); border-radius: 6px; }
"""
ZOOMS = (0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0, 4.0)


class PdfViewer(QWidget):
    closed = Signal()
    _progress = Signal(str)
    _finished = Signal(object, str, str)          # Result or None, why, target
    _note = Signal(str)

    def __init__(self, path: str, hooks: PdfHooks | None = None, parent=None, box: QRect | None = None) -> None:
        super().__init__(parent, Qt.WindowType.Window)
        from PySide6.QtPdf import QPdfDocument, QPdfSearchModel
        from PySide6.QtPdfWidgets import QPdfView
        self.setAttribute(Qt.WidgetAttribute.WA_DeleteOnClose)
        self.hooks = hooks or PdfHooks()
        self.path = ""
        self.original = ""                        # what an optimised copy was made from (Back to Original)
        self.password = ""
        self.anchor = box.center() if box is not None and box.isValid() else None
        self._stop = threading.Event()
        self._running = False
        self.setStyleSheet(PDF_STYLE)
        self.setMinimumSize(420, 320)
        pal = self.palette()
        pal.setColor(self.backgroundRole(), QColor("#1C1C1E"))
        self.setPalette(pal)
        self.setAutoFillBackground(True)
        if self.anchor is not None:
            screen = QApplication.screenAt(self.anchor)
            if screen is not None and hasattr(self, "setScreen"):
                self.setScreen(screen)

        self.doc = QPdfDocument(self)
        self.view = QPdfView(self)
        self.view.setDocument(self.doc)
        self.view.setPageMode(QPdfView.PageMode.MultiPage)
        self.view.setZoomMode(QPdfView.ZoomMode.FitToWidth)
        self.view.setPageSpacing(10)
        vpal = self.view.palette()
        vpal.setColor(QPalette.ColorRole.Dark, QColor("#1C1C1E"))
        self.view.setPalette(vpal)
        self.view.setFrameShape(QFrame.Shape.NoFrame)
        self.nav = self.view.pageNavigator()
        self.nav.currentPageChanged.connect(self._page_changed)
        self.search_model = QPdfSearchModel(self)
        self.search_model.setDocument(self.doc)
        if hasattr(self.view, "setSearchModel"):
            self.view.setSearchModel(self.search_model)
        # The search runs through the pages a few at a time: the first match is shown as soon as it's found.
        self.search_model.rowsInserted.connect(
            lambda *_: self.next_hit(1) if self._hit < 0 and self.search.text() else None)
        self._searched = QTimer(self)
        self._searched.setSingleShot(True)
        self._searched.timeout.connect(self._search_done)
        self._hit = -1

        self.thumbs = QListWidget(objectName="PdfThumbs")
        self.thumbs.setViewMode(QListWidget.ViewMode.IconMode)
        self.thumbs.setIconSize(QSize(110, 140))
        self.thumbs.setMovement(QListWidget.Movement.Static)
        self.thumbs.setResizeMode(QListWidget.ResizeMode.Adjust)
        self.thumbs.setFlow(QListWidget.Flow.TopToBottom)
        self.thumbs.setWrapping(False)
        self.thumbs.setFixedWidth(150)
        self.thumbs.setSpacing(6)
        self.thumbs.setVisible(False)
        self.thumbs.currentRowChanged.connect(lambda r: self.go_to(r) if r >= 0 and self.thumbs.isVisible() else None)
        self._thumb_next = 0
        self._thumb_timer = QTimer(self)
        self._thumb_timer.setInterval(15)
        self._thumb_timer.timeout.connect(self._render_thumbs)

        self.top = self._top_bar()
        self.bottom = self._bottom_bar()
        middle = QHBoxLayout()
        middle.setContentsMargins(0, 0, 0, 0)
        middle.setSpacing(0)
        middle.addWidget(self.thumbs)
        middle.addWidget(self.view, 1)
        col = QVBoxLayout(self)
        col.setContentsMargins(0, 0, 0, 0)
        col.setSpacing(0)
        col.addWidget(self.top)
        col.addLayout(middle, 1)
        col.addWidget(self.bottom)

        self._progress.connect(self.say_busy)
        self._finished.connect(self._optimized)
        self._note.connect(self.say)
        self._note_timer = QTimer(self)
        self._note_timer.setSingleShot(True)
        self._note_timer.timeout.connect(self._end_note)
        self._shortcuts()
        if not self.open(path):
            QTimer.singleShot(0, self.close)
            return
        self._fit_window()

    # ------------------------------------------------------------------ bars
    def _top_bar(self) -> QWidget:
        bar = QFrame(self, objectName="ViewerTop")
        h = QHBoxLayout(bar)
        h.setContentsMargins(8, 5, 10, 5)
        h.setSpacing(4)
        h.addWidget(mv._bar_button("", "Close (Esc)", self.close, "close"))
        self.thumbs_btn = mv._bar_button("☰", "Page thumbnails", self.toggle_thumbs)
        self.thumbs_btn.setCheckable(True)
        h.addWidget(self.thumbs_btn)
        titles = QVBoxLayout()
        titles.setSpacing(0)
        self.title = QLabel(objectName="ViewerTitle")
        self.sub = QLabel(objectName="ViewerCount")
        for lbl in (self.title, self.sub):
            lbl.setSizePolicy(QSizePolicy.Policy.Ignored, QSizePolicy.Policy.Preferred)
            lbl.setMinimumWidth(40)
        titles.addWidget(self.title)
        titles.addWidget(self.sub)
        h.addSpacing(4)
        h.addLayout(titles, 1)
        self.search = QLineEdit(objectName="PdfSearch")
        self.search.setPlaceholderText("Search")
        self.search.setClearButtonEnabled(True)
        self.search.setFixedWidth(150)
        self.search.textChanged.connect(self._search_changed)
        self.search.returnPressed.connect(lambda: self.next_hit(1))
        h.addWidget(self.search)
        more = mv._bar_button("", "More", None, "more")
        more.setPopupMode(QToolButton.ToolButtonPopupMode.InstantPopup)
        menu = QMenu(more)
        menu.addAction("Open With Default App", self.open_external)
        self.reveal_act = menu.addAction("Show in Folder", lambda: self.reveal(self.path))
        self.reveal_act.setVisible(self.hooks.reveal is not None)
        self.airdrop_act = menu.addAction("AirDrop to iPhone…", lambda: self.airdrop(self.path))
        self.airdrop_act.setVisible(self.hooks.airdrop is not None)
        more.setMenu(menu)
        h.addWidget(more)
        return bar

    def _bottom_bar(self) -> QWidget:
        bar = QFrame(self, objectName="ViewerBottom")
        col = QVBoxLayout(bar)
        col.setContentsMargins(10, 4, 10, 5)
        col.setSpacing(2)
        # what the last Optimize made, with what can be done with it
        self.result_row = QWidget()
        rr = QHBoxLayout(self.result_row)
        rr.setContentsMargins(0, 0, 0, 0)
        rr.setSpacing(4)
        self.result_text = QLabel()
        self.result_text.setWordWrap(True)
        self.result_text.setStyleSheet("color: #C7C7CC; font-size: 12px;")
        rr.addWidget(self.result_text, 1)
        self.res_airdrop = QPushButton("AirDrop to iPhone…", objectName="ResultButton")
        self.res_airdrop.clicked.connect(lambda: self.airdrop(self.path))
        self.res_reveal = QPushButton("Show in Folder", objectName="ResultButton")
        self.res_reveal.clicked.connect(lambda: self.reveal(self.path))
        self.res_back = QPushButton("Back to Original", objectName="ResultButton")
        self.res_back.clicked.connect(self.back_to_original)
        for b in (self.res_airdrop, self.res_reveal, self.res_back):
            b.setCursor(Qt.CursorShape.PointingHandCursor)
            rr.addWidget(b)
        self.result_row.setVisible(False)
        col.addWidget(self.result_row)
        row = QHBoxLayout()
        row.setContentsMargins(0, 0, 0, 0)
        row.setSpacing(2)
        row.addWidget(mv._bar_button("", "Previous page (←)", lambda: self.step(-1), "prev"))
        self.page_box = QLineEdit(objectName="PdfPage")
        self.page_box.setFixedWidth(54)
        self.page_box.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.page_box.returnPressed.connect(self._page_typed)
        row.addWidget(self.page_box)
        self.page_total = QLabel()
        self.page_total.setObjectName("ViewerTime")
        row.addWidget(self.page_total)
        row.addWidget(mv._bar_button("", "Next page (→)", lambda: self.step(1), "next"))
        row.addStretch(1)
        # The two Optimize buttons, in the middle of the bottom bar (the top one holds the name and the search).
        self.mac_btn = QPushButton("Optimize for Safe Finder", objectName="Optimize")
        self.mac_btn.setToolTip("A new PDF beside this one, trimmed to its content with blank pages left out — so "
                                "the page, not its margins, fills this viewer")
        self.mac_btn.clicked.connect(lambda: self.optimize(pdf_optimize.MAC))
        self.phone_btn = QPushButton("Optimize for iPhone", objectName="Optimize")
        self.phone_btn.setToolTip("A new PDF beside this one made for the iPhone 17 Pro Max: pages the shape of its "
                                  "screen, margins trimmed, two-column pages read a column at a time, cut only "
                                  "between lines")
        self.phone_btn.clicked.connect(lambda: self.optimize(pdf_optimize.IPHONE))
        for b in (self.mac_btn, self.phone_btn):
            b.setCursor(Qt.CursorShape.PointingHandCursor)
            b.setFocusPolicy(Qt.FocusPolicy.NoFocus)
            row.addWidget(b)
        row.addStretch(1)
        row.addWidget(mv._bar_button("", "Zoom Out (−)", lambda: self.zoom(1 / 1.25), "minus"))
        self.zoom_btn = QToolButton(objectName="ZoomLabel")
        self.zoom_btn.setText("Fit Width")
        self.zoom_btn.setFocusPolicy(Qt.FocusPolicy.NoFocus)
        self.zoom_btn.setPopupMode(QToolButton.ToolButtonPopupMode.InstantPopup)
        zmenu = QMenu(self.zoom_btn)
        zmenu.addAction("Fit Width (0)", self.fit_width)
        zmenu.addAction("Fit Page", self.fit_page)
        zmenu.addSeparator()
        for z in ZOOMS:
            zmenu.addAction(f"{round(z * 100)}%", lambda z=z: self.set_zoom(z))
        self.zoom_btn.setMenu(zmenu)
        row.addWidget(self.zoom_btn)
        row.addWidget(mv._bar_button("", "Zoom In (+)", lambda: self.zoom(1.25), "plus"))
        col.addLayout(row)
        return bar

    def _shortcuts(self) -> None:
        for keys, slot in (("Escape", self.close), ("Left", lambda: self.step(-1)), ("Right", lambda: self.step(1)),
                           ("PgUp", lambda: self.step(-1)), ("PgDown", lambda: self.step(1)),
                           ("Ctrl+F", self._focus_search), ("+", lambda: self.zoom(1.25)),
                           ("=", lambda: self.zoom(1.25)), ("-", lambda: self.zoom(1 / 1.25)), ("0", self.fit_width),
                           ("Shift+Return", lambda: self.next_hit(-1)), ("Ctrl+W", self.close)):
            QShortcut(QKeySequence(keys), self).activated.connect(slot)

    # ------------------------------------------------------------------ the document
    def open(self, path: str) -> bool:
        """Shows `path` (asking for its password when it has one). False when it can't be opened."""
        from PySide6.QtPdf import QPdfDocument
        self.doc.close()
        self.doc.setPassword(self.password)
        err = self.doc.load(path)
        while err == QPdfDocument.Error.IncorrectPassword:
            text, ok = QInputDialog.getText(self, "Password", f"“{os.path.basename(path)}” is protected. Password:",
                                            QLineEdit.EchoMode.Password)
            if not ok:
                return False
            self.password = text
            self.doc.setPassword(text)
            err = self.doc.load(path)
        if err != QPdfDocument.Error.None_ or self.doc.pageCount() < 1:
            self.say(f"“{os.path.basename(path)}” can't be read as a PDF.")
            return False
        self.path = path
        self.title.setText(os.path.basename(path))
        self.title.setToolTip(path)
        self.setWindowTitle(os.path.basename(path))
        self.page_total.setText(f"of {self.doc.pageCount():,}")
        self._hit = -1
        if self.search.text():
            self.search_model.setSearchString(self.search.text())
        self.fit_width()
        self.go_to(0)
        self._page_changed(0)
        self._reset_thumbs()
        return True

    def go_to(self, page: int) -> None:
        if 0 <= page < self.doc.pageCount():
            self.nav.jump(page, QPointF(), self.nav.currentZoom())

    def step(self, d: int) -> None:
        self.go_to(self.nav.currentPage() + d)

    def _page_changed(self, page: int) -> None:
        n = self.doc.pageCount()
        self.page_box.setText(str(page + 1))
        if not self._note_timer.isActive() and not self._running:
            label = self.doc.pageLabel(page) if hasattr(self.doc, "pageLabel") else ""
            extra = f" (“{label}”)" if label and label != str(page + 1) else ""
            self.sub.setText(f"Page {page + 1:,} of {n:,}{extra}")
        if self.thumbs.isVisible() and self.thumbs.currentRow() != page:
            self.thumbs.blockSignals(True)
            self.thumbs.setCurrentRow(page)
            self.thumbs.blockSignals(False)

    def _page_typed(self) -> None:
        try:
            self.go_to(int(self.page_box.text()) - 1)
        except ValueError:
            pass
        self.view.setFocus()

    # -- zoom
    def _screen_res(self) -> float:
        screen = self.screen() or QApplication.primaryScreen()
        return (screen.logicalDotsPerInch() / 72.0) if screen is not None else 1.0

    def _current_zoom(self) -> float:
        """The zoom now — worked out from the window when it's fitting the width or the page."""
        from PySide6.QtPdfWidgets import QPdfView
        if self.view.zoomMode() == QPdfView.ZoomMode.Custom:
            return self.view.zoomFactor()
        page = self.doc.pagePointSize(max(0, self.nav.currentPage()))
        vp = self.view.viewport().size()
        res = self._screen_res()
        w = max(1.0, page.width() * res)
        if self.view.zoomMode() == QPdfView.ZoomMode.FitToWidth:
            return max(0.05, (vp.width() - 12) / w)
        return max(0.05, min((vp.width() - 12) / w, (vp.height() - 12) / max(1.0, page.height() * res)))

    def set_zoom(self, z: float) -> None:
        from PySide6.QtPdfWidgets import QPdfView
        z = max(0.1, min(z, 8.0))
        self.view.setZoomMode(QPdfView.ZoomMode.Custom)
        self.view.setZoomFactor(z)
        self.zoom_btn.setText(f"{round(z * 100)}%")

    def zoom(self, factor: float) -> None:
        self.set_zoom(self._current_zoom() * factor)

    def fit_width(self) -> None:
        from PySide6.QtPdfWidgets import QPdfView
        self.view.setZoomMode(QPdfView.ZoomMode.FitToWidth)
        self.zoom_btn.setText("Fit Width")

    def fit_page(self) -> None:
        from PySide6.QtPdfWidgets import QPdfView
        self.view.setZoomMode(QPdfView.ZoomMode.FitInView)
        self.zoom_btn.setText("Fit Page")

    # -- search
    def _focus_search(self) -> None:
        self.search.setFocus()
        self.search.selectAll()

    def _search_changed(self, text: str) -> None:
        self._hit = -1
        self.search_model.setSearchString(text)
        if text:
            self.say_busy(f"Searching for “{text}”…")
            self._searched.start(max(1500, self.doc.pageCount() * 15))
        else:
            self._searched.stop()
            self._end_note()

    def _search_done(self) -> None:
        if self.search.text() and self.search_model.rowCount(QModelIndex()) == 0:
            self.say(f"No “{self.search.text()}” in this PDF.")
        elif self._hit < 0:
            self._end_note()

    def next_hit(self, d: int) -> None:
        n = self.search_model.rowCount(QModelIndex())
        if not self.search.text() or n == 0:
            return
        self._hit = (self._hit + d) % n if self._hit >= 0 else (0 if d > 0 else n - 1)
        link = self.search_model.resultAtIndex(self._hit)
        if hasattr(self.view, "setCurrentSearchResultIndex"):
            self.view.setCurrentSearchResultIndex(self._hit)
        self.nav.jump(link.page(), link.location(), self.nav.currentZoom())
        self.say(f"“{self.search.text()}”: {self._hit + 1:,} of {n:,} — Return for the next, ⇧Return the one before.")

    # -- thumbnails
    def toggle_thumbs(self) -> None:
        on = not self.thumbs.isVisible()
        self.thumbs.setVisible(on)
        self.thumbs_btn.setChecked(on)
        if on:
            self._thumb_timer.start()
            self.thumbs.setCurrentRow(self.nav.currentPage())

    def _reset_thumbs(self) -> None:
        self.thumbs.clear()
        blank = QPixmap(110, 140)
        blank.fill(QColor("#2C2C2E"))
        for i in range(self.doc.pageCount()):
            item = QListWidgetItem(QIcon(blank), self.doc.pageLabel(i) if hasattr(self.doc, "pageLabel") and
                                   self.doc.pageLabel(i) else str(i + 1))
            item.setTextAlignment(Qt.AlignmentFlag.AlignHCenter)
            self.thumbs.addItem(item)
        self._thumb_next = 0
        if self.thumbs.isVisible():
            self._thumb_timer.start()

    def _render_thumbs(self) -> None:
        """A few page thumbnails at a time, on this thread (the PDF library isn't to be shared across threads)."""
        n = self.doc.pageCount()
        for _ in range(3):
            i = self._thumb_next
            if i >= n:
                self._thumb_timer.stop()
                return
            size = self.doc.pagePointSize(i)
            scale = min(110 / max(1.0, size.width()), 140 / max(1.0, size.height())) * 2
            img = pdf_optimize.render(self.doc, i, scale)
            pm = QPixmap.fromImage(img)
            pm.setDevicePixelRatio(2)
            self.thumbs.item(i).setIcon(QIcon(pm))
            self._thumb_next += 1

    # ------------------------------------------------------------------ Optimize
    def optimize(self, target: str) -> None:
        if self._running or not self.path:
            return
        self._running = True
        self._stop.clear()
        for b in (self.mac_btn, self.phone_btn):
            b.setEnabled(False)
        self.result_row.setVisible(False)
        what = "for the iPhone" if target == pdf_optimize.IPHONE else "for Safe Finder"
        self.say_busy(f"Optimizing {what}…")
        src, password, stop = self.path, self.password, self._stop
        place, progress, finished = self.hooks.place, self._progress, self._finished

        def work() -> None:
            result, why = None, ""
            try:
                result = pdf_optimize.optimize(src, target, password, lambda t: _emit(progress, t), stop, place)
            except pdf_optimize.Stopped:
                why = "stopped"
            except ValueError as e:
                why = f"Couldn't optimize it: {e}."
            except Exception as e:  # noqa: BLE001 — anything else is said, not raised into a worker
                why = f"Couldn't optimize it ({e})."
            _emit(finished, result, why, target)
        threading.Thread(target=work, name="pdf-optimize", daemon=True).start()

    def _optimized(self, result, why: str, target: str) -> None:
        self._running = False
        for b in (self.mac_btn, self.phone_btn):
            b.setEnabled(True)
        if result is None:
            self._note_timer.stop()
            if why != "stopped":
                self.say(why, 8000)
            return
        original = self.path
        if self.hooks.carry_tags is not None:
            self.hooks.carry_tags([(original, result.path)])
        if self.hooks.made is not None:
            self.hooks.made(result.path)
        name = os.path.basename(result.path)
        if target == pdf_optimize.IPHONE:
            text = (f"Made “{name}” beside the original: {result.pages_in:,} page{'s' if result.pages_in != 1 else ''} "
                    f"became {result.pages_out:,} iPhone-shaped page{'s' if result.pages_out != 1 else ''}")
            if result.columns:
                text += f", {result.columns:,} two-column page{'s' if result.columns != 1 else ''} read a column at a time"
        else:
            text = f"Made “{name}” beside the original, trimmed to its content"
        if result.blank:
            text += f" ({result.blank:,} blank page{'s' if result.blank != 1 else ''} left out)"
        text += "."
        if not result.vector:
            text += (" Its pages are pictures (sharp, but the text can't be searched or selected) — "
                     f"{result.note}.")
        self.original = self.original or original
        self.open(result.path)
        self._note_timer.stop()
        self._end_note()
        self.result_text.setText(text)
        self.res_airdrop.setVisible(target == pdf_optimize.IPHONE and self.hooks.airdrop is not None)
        self.res_reveal.setVisible(self.hooks.reveal is not None)
        self.res_back.setVisible(True)
        self.result_row.setVisible(True)

    def back_to_original(self) -> None:
        if self.original and os.path.isfile(self.original):
            path, self.original = self.original, ""
            self.result_row.setVisible(False)
            self.open(path)

    # ------------------------------------------------------------------ actions
    def open_external(self) -> None:
        if self.path:
            QDesktopServices.openUrl(QUrl.fromLocalFile(self.path))

    def reveal(self, path: str) -> None:
        if self.hooks.reveal is not None and path:
            self.hooks.reveal(path)

    def airdrop(self, path: str) -> None:
        if self.hooks.airdrop is not None and path:
            self.say("Opening AirDrop…")
            self.hooks.airdrop([path], lambda t: _emit(self._note, t))

    # ------------------------------------------------------------------ notes, size
    def say(self, text: str, ms: int = 4500) -> None:
        """A passing note in the line under the name (as the photo viewer's)."""
        self.sub.setText(text)
        self.sub.setToolTip(text)
        self.sub.setStyleSheet("color: #F2F2F7; font-weight: 600;")
        self._note_timer.start(ms)

    def say_busy(self, text: str) -> None:
        self.sub.setText(text)
        self.sub.setToolTip(text)
        self.sub.setStyleSheet("color: #F2F2F7; font-weight: 600;")
        self._note_timer.stop()

    def _end_note(self) -> None:
        if self._running:
            return
        self.sub.setStyleSheet("")
        self.sub.setToolTip("")
        self._page_changed(max(0, self.nav.currentPage()))

    def _fit_window(self) -> None:
        """As tall as the display (under the menu bar, above the Dock), as wide as the first page allows at that
        height — over Safe Finder's window."""
        avail = mv.available_geometry(self)
        if avail is None:
            self.resize(900, 1000)
            return
        h = avail.height() - mv.TITLE_BAR
        chrome = self.top.sizeHint().height() + self.bottom.sizeHint().height()
        page = self.doc.pagePointSize(0)
        aspect = page.width() / max(1.0, page.height())
        w = int(min(avail.width(), max(self.minimumWidth(), (h - chrome - 20) * aspect + 40)))
        self.resize(w, h)
        center = self.anchor or avail.center()
        x = max(avail.left(), min(center.x() - w // 2, avail.right() - w + 1))
        self.move(x, avail.top())

    def closeEvent(self, event) -> None:  # noqa: N802
        self._stop.set()
        self._thumb_timer.stop()
        self.doc.close()
        self.closed.emit()
        super().closeEvent(event)


def _emit(signal, *args) -> None:
    try:
        signal.emit(*args)
    except RuntimeError:                          # the window closed meanwhile
        pass
