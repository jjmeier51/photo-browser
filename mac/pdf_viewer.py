"""Safe Finder's PDF viewer — a PDF opens here (double-click, Return) instead of in Preview, in the photo viewer's
dark look: the pages scrolling one after another, fitted to the width, with search, zoom and page thumbnails.

**The window** opens over Safe Finder's window, on its display, as tall as the display (like the photo viewer),
and as wide as the first page's shape at that height allows.

- **Reading**: scroll, ←/→ (or Page Up / Page Down) a page at a time, the page box at the bottom to jump (⌘G puts
  the cursor there; it takes the page's printed label too — "xii"); Home / End for the first and last page; zoom with
  −/+ (or ⌘-scroll, pinch), the zoom menu for Fit Width / Fit Page / sizes; ⌘F searches — every match marked,
  Return for the next (⇧Return the one before); ☰ shows the pages as thumbnails. Esc closes.
- **Contents**: click an entry on the book's contents page — its page number or its title — and the viewer goes
  there. Where the PDF has real links they're followed; where the contents page is only text (no links — scans,
  word-processor exports) the viewer reads the line under the click and works out which page the printed number
  means (`pdf_contents`: page labels, the offset between printed and real numbers, the chapter's own title). A real
  link is followed here too — `follow_link`; QPdfView draws links but a click on one does nothing in this Qt. The
  **Contents** button opens the chapters as a list beside the pages — the PDF's outline, else the entries read from
  its contents pages — with the chapter being read marked; the chapter's name in the bottom bar is a menu of them
  all, [ and ] step a chapter back and on, and **Back** (⌘[) returns to where a jump was made from.
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

from PySide6.QtCore import QEvent, QModelIndex, QPoint, QPointF, QRect, QSize, QSizeF, Qt, QTimer, QUrl, Signal
from PySide6.QtGui import QColor, QDesktopServices, QIcon, QKeySequence, QPalette, QPixmap, QShortcut
from PySide6.QtWidgets import (QApplication, QFrame, QHBoxLayout, QInputDialog, QLabel, QLineEdit, QListWidget,
                               QListWidgetItem, QMenu, QPushButton, QSizePolicy, QToolButton, QTreeWidget,
                               QTreeWidgetItem, QVBoxLayout, QWidget)

import media_viewer as mv
import pdf_contents
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
QTreeWidget#PdfContents { background: #1C1C1E; border: none; border-right: 1px solid #2C2C2E; color: #E5E5EA;
                          font-size: 13px; outline: none; }
QTreeWidget#PdfContents::item { padding: 5px 4px; }
QTreeWidget#PdfContents::item:hover { background: rgba(255,255,255,0.07); }
QTreeWidget#PdfContents::item:selected { background: rgba(10,132,255,0.35); color: #FFFFFF; }
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

        # The chapters, beside the pages (pdf_contents: the PDF's outline, else its contents pages read as text).
        self.reader: pdf_contents.Reader | None = None
        self.contents = QTreeWidget(objectName="PdfContents")
        self.contents.setHeaderHidden(True)
        self.contents.setColumnCount(2)
        self.contents.setRootIsDecorated(False)
        self.contents.setIndentation(14)
        self.contents.setFixedWidth(270)
        self.contents.setVisible(False)
        self.contents.setFocusPolicy(Qt.FocusPolicy.NoFocus)
        self.contents.itemClicked.connect(lambda item, _c: self.go_to(item.data(0, Qt.ItemDataRole.UserRole)))
        self._press: QPoint | None = None
        self._hand = False
        self.view.viewport().setMouseTracking(True)
        self.view.viewport().installEventFilter(self)
        self.nav.backAvailableChanged.connect(lambda on: self.back_btn.setVisible(bool(on)))

        self.top = self._top_bar()
        self.bottom = self._bottom_bar()
        middle = QHBoxLayout()
        middle.setContentsMargins(0, 0, 0, 0)
        middle.setSpacing(0)
        middle.addWidget(self.contents)
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
        self.contents_btn = mv._bar_button("Contents", "The chapters — click one to go there", self.toggle_contents)
        self.contents_btn.setCheckable(True)
        h.addWidget(self.contents_btn)
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
        self.back_btn = mv._bar_button("‹ Back", "Back to where you jumped from (⌘[)", lambda: self.nav.back())
        self.back_btn.setVisible(False)
        row.addWidget(self.back_btn)
        # The chapter being read: a menu of every chapter (filled when the PDF has any).
        self.chapter_btn = QToolButton(objectName="ZoomLabel")
        self.chapter_btn.setFocusPolicy(Qt.FocusPolicy.NoFocus)
        self.chapter_btn.setPopupMode(QToolButton.ToolButtonPopupMode.InstantPopup)
        self.chapter_btn.setToolTip("Chapters — [ and ] step to the one before and the next")
        self.chapter_btn.setMaximumWidth(230)
        self.chapter_menu = QMenu(self.chapter_btn)
        self.chapter_btn.setMenu(self.chapter_menu)
        self.chapter_btn.setVisible(False)
        row.addWidget(self.chapter_btn)
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
                           ("Shift+Return", lambda: self.next_hit(-1)), ("Ctrl+W", self.close),
                           ("Ctrl+G", self._focus_page), ("Home", lambda: self.go_to(0)),
                           ("End", lambda: self.go_to(self.doc.pageCount() - 1)),
                           ("[", lambda: self.step_chapter(-1)), ("]", lambda: self.step_chapter(1)),
                           ("Ctrl+[", lambda: self.nav.back()), ("Ctrl+]", lambda: self.nav.forward())):
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
        self.reader = pdf_contents.Reader(self.doc)
        self._links = None
        self._page_changed(0)
        self._reset_thumbs()
        QTimer.singleShot(0, self._reset_contents)      # after the first paint: reading a contents page takes a moment
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
        self._mark_chapter(page)

    def _page_typed(self) -> None:
        """The page box: a page number — or the label printed on the page ("xii", "A-3") when the PDF has them."""
        text = self.page_box.text().strip()
        page = -1
        if text.isdigit():
            page = int(text) - 1
        elif text and hasattr(self.doc, "pageIndexForLabel"):
            page = self.doc.pageIndexForLabel(text)
        if 0 <= page < self.doc.pageCount():
            self.go_to(page)
            self.view.setFocus()
        else:
            self.say(f"There's no page “{text}” — this PDF has {self.doc.pageCount():,} pages.")
            self.page_box.setText(str(self.nav.currentPage() + 1))

    def _focus_page(self) -> None:
        self.page_box.setFocus()
        self.page_box.selectAll()

    # -- the contents: clicks on a contents page, the chapter list, chapter steps
    def _page_rects(self) -> list[QRect]:
        """Where each page is drawn, in the scrolled document's own coordinates — QPdfView's layout, worked out
        again (it doesn't say): pages one under another, `pageSpacing` apart inside `documentMargins`, each
        centred, sized by the zoom mode."""
        from PySide6.QtPdfWidgets import QPdfView
        v = self.view
        m, spacing, vp = v.documentMargins(), v.pageSpacing(), v.viewport().size()
        res, mode = self._screen_res(), v.zoomMode()
        sizes: list[QSize] = []
        for i in range(self.doc.pageCount()):
            pt = self.doc.pagePointSize(i)
            if mode == QPdfView.ZoomMode.Custom:
                size = QSizeF(pt * res * v.zoomFactor()).toSize()
            else:
                size = QSizeF(pt * res).toSize()
                if mode == QPdfView.ZoomMode.FitToWidth:
                    size = size * ((vp.width() - m.left() - m.right()) / max(1, size.width()))
                else:
                    size = size.scaled(QSize(vp.width() - m.left() - m.right(), vp.height() - spacing),
                                       Qt.AspectRatioMode.KeepAspectRatio)
            sizes.append(size)
        total = max((s.width() for s in sizes), default=0) + m.left() + m.right()
        rects, y = [], m.top()
        for size in sizes:
            rects.append(QRect(QPoint((max(total, vp.width()) - size.width()) // 2, y), size))
            y += size.height() + spacing
        return rects

    def page_point(self, pos: QPoint) -> tuple[int, QPointF] | None:
        """(page, the spot on it in points) under `pos` in the viewport — None between pages."""
        doc_pos = pos + QPoint(self.view.horizontalScrollBar().value(), self.view.verticalScrollBar().value())
        for i, r in enumerate(self._page_rects()):
            if r.contains(doc_pos):
                pt = self.doc.pagePointSize(i)
                return i, QPointF((doc_pos.x() - r.x()) * pt.width() / max(1, r.width()),
                                  (doc_pos.y() - r.y()) * pt.height() / max(1, r.height()))
            if r.top() > doc_pos.y():
                break
        return None

    def viewport_pos(self, page: int, point: QPointF) -> QPoint:
        """Where a spot on a page (points) is in the viewport now — the other way round (the tests click by it)."""
        r = self._page_rects()[page]
        pt = self.doc.pagePointSize(page)
        return QPoint(round(r.x() + point.x() * r.width() / pt.width()) - self.view.horizontalScrollBar().value(),
                      round(r.y() + point.y() * r.height() / pt.height()) - self.view.verticalScrollBar().value())

    def link_at(self, page: int, point: QPointF):
        """The PDF's own link at a spot on a page (a QPdfLink), or None."""
        try:
            from PySide6.QtPdf import QPdfLinkModel
            if self._links is None:
                self._links = QPdfLinkModel(self)
                self._links.setDocument(self.doc)
            if self._links.page() != page:
                self._links.setPage(page)
            link = self._links.linkAt(point)
            return link if link.isValid() else None
        except Exception:  # noqa: BLE001 — an older Qt without linkAt: nothing is taken for a link
            return None

    def _real_link(self, page: int, point: QPointF) -> bool:
        return self.link_at(page, point) is not None

    def follow_link(self, pos: QPoint) -> bool:
        """Follows the PDF's own link under `pos`: to its page (the top of it, at this zoom), or out to the web
        in the browser. (This Qt's page view draws links but doesn't follow a click on one.)"""
        hit = self.page_point(pos)
        link = self.link_at(*hit) if hit is not None else None
        if link is None:
            return False
        if 0 <= link.page() < self.doc.pageCount():
            self.nav.jump(link.page(), link.location(), self.nav.currentZoom())
            return True
        url = link.url()
        if url.isValid() and url.scheme() in ("http", "https", "mailto"):
            QDesktopServices.openUrl(url)
            return True
        return False

    def contents_target(self, pos: QPoint) -> tuple[int, str] | None:
        """The page a click at `pos` asks for when it's on a contents entry that isn't a real link: (page, the
        entry's title)."""
        if self.reader is None:
            return None
        hit = self.page_point(pos)
        if hit is None:
            return None
        page, point = hit
        entry = self.reader.entry_at(page, point)
        if entry is None or self._real_link(page, point):
            return None
        target = self.reader.resolve(entry.title, entry.number)
        return (target, entry.title) if target is not None else None

    def eventFilter(self, obj, event) -> bool:  # noqa: N802
        if obj is self.view.viewport():
            kind = event.type()
            if kind == QEvent.Type.MouseButtonPress and event.button() == Qt.MouseButton.LeftButton:
                self._press = event.position().toPoint()
            elif kind == QEvent.Type.MouseButtonRelease and event.button() == Qt.MouseButton.LeftButton:
                press, self._press = self._press, None
                pos = event.position().toPoint()
                if press is not None and (pos - press).manhattanLength() <= 5:
                    if self.follow_link(pos):
                        return True
                    target = self.contents_target(pos)
                    if target is not None:
                        self.go_to(target[0])
                        self.say(f"“{target[1]}” — page {target[0] + 1:,}.  ‹ Back returns to the contents.", 3500)
                        return True
            elif kind == QEvent.Type.MouseMove and not event.buttons():
                at = event.position().toPoint()
                spot = self.page_point(at)
                hand = (spot is not None and self._real_link(*spot)) or self.contents_target(at) is not None
                if hand != self._hand:
                    self._hand = hand
                    if hand:
                        self.view.viewport().setCursor(Qt.CursorShape.PointingHandCursor)
                    else:
                        self.view.viewport().unsetCursor()
        return super().eventFilter(obj, event)

    def toggle_contents(self) -> None:
        on = not self.contents.isVisible()
        if on and self.contents.topLevelItemCount() == 0:
            self.contents_btn.setChecked(False)
            self.say("This PDF has no list of chapters — ☰ shows its pages instead.")
            return
        self.contents.setVisible(on)
        self.contents_btn.setChecked(on)
        if on:
            self._mark_chapter(self.nav.currentPage())

    def _reset_contents(self) -> None:
        """The chapter list and menu for the document just opened."""
        self.contents.clear()
        self.chapter_menu.clear()
        self._chapter = -2
        if self.reader is None or not self.path:
            return
        try:
            chapters = self.reader.chapters()
        except Exception:  # noqa: BLE001 — a PDF whose text can't be read just has no list
            chapters = []
        parents: dict[int, QTreeWidgetItem] = {}
        for i, c in enumerate(chapters):
            label = self.doc.pageLabel(c.page) if hasattr(self.doc, "pageLabel") else ""
            item = QTreeWidgetItem([c.title, label or str(c.page + 1)])
            item.setData(0, Qt.ItemDataRole.UserRole, c.page)
            item.setToolTip(0, c.title)
            item.setTextAlignment(1, Qt.AlignmentFlag.AlignRight | Qt.AlignmentFlag.AlignVCenter)
            parent = parents.get(c.level - 1) if c.level > 0 else None
            (parent.addChild(item) if parent is not None else self.contents.addTopLevelItem(item))
            parents[c.level] = item
            if c.level == 0 and i < 400:
                self.chapter_menu.addAction(f"{c.title}    {label or c.page + 1}", lambda page=c.page: self.go_to(page))
        self.contents.expandAll()
        self.contents.setRootIsDecorated(any(c.level > 0 for c in chapters))
        self.contents.header().setStretchLastSection(False)
        from PySide6.QtWidgets import QHeaderView
        self.contents.header().setSectionResizeMode(0, QHeaderView.ResizeMode.Stretch)
        self.contents.header().setSectionResizeMode(1, QHeaderView.ResizeMode.ResizeToContents)
        have = bool(chapters)
        self.chapter_btn.setVisible(have)
        self.contents_btn.setToolTip("The chapters — click one to go there" if have else
                                     "This PDF has no list of chapters")
        if not have and self.contents.isVisible():
            self.contents.setVisible(False)
            self.contents_btn.setChecked(False)
        self._mark_chapter(max(0, self.nav.currentPage()))

    def _mark_chapter(self, page: int) -> None:
        """The chapter `page` is in: named in the bottom bar, marked in the list."""
        if self.reader is None or self.reader._chapters is None or not self.reader._chapters:
            return
        i = self.reader.chapter_at(page)
        if i == getattr(self, "_chapter", -2):
            return
        self._chapter = i
        chapters = self.reader.chapters()
        name = chapters[i].title if i >= 0 else "Chapters"
        shown = self.chapter_btn.fontMetrics().elidedText(name, Qt.TextElideMode.ElideRight, 190)
        self.chapter_btn.setText(shown)
        items = self._contents_items()               # in the chapters' own order
        self.contents.blockSignals(True)
        self.contents.setCurrentItem(items[i] if 0 <= i < len(items) else None)
        self.contents.blockSignals(False)

    def _contents_items(self) -> list[QTreeWidgetItem]:
        out: list[QTreeWidgetItem] = []

        def walk(item: QTreeWidgetItem) -> None:
            out.append(item)
            for k in range(item.childCount()):
                walk(item.child(k))
        for k in range(self.contents.topLevelItemCount()):
            walk(self.contents.topLevelItem(k))
        return out

    def step_chapter(self, d: int) -> None:
        """[ and ]: the chapter before (or this one's start, when you're into it) and the next."""
        if self.reader is None or not self.reader.chapters():
            return
        page = self.nav.currentPage()
        starts = sorted({c.page for c in self.reader.chapters()})
        if d > 0:
            nxt = next((p for p in starts if p > page), None)
        else:
            nxt = next((p for p in reversed(starts) if p < page), None)
        if nxt is not None:
            self.go_to(nxt)
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
