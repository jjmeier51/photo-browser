"""The Pictures window of Make Book — where each picture goes in the book, shown on the page as it will be.

The book has just been made. This window puts pictures into it, anywhere:

- **Beside the text** — at the left or the right, with the paragraph it's put at (and the ones after it, as many
  as fit) flowing round it;
- **Between two paragraphs** — any width, at the left, centre or right;
- **A page of its own** — after any paragraph, at the front, at the start or end of a chapter, or at the end.

On the right is **the page as it will be**, set again (by `bookify.Draft`, a fraction of a second) after every
change — not a sketch: the same type, the same line breaks. The page is also how the picture is handled:

- **click a paragraph** — the picture goes there;
- **drag the picture** onto another paragraph — it moves (dropped on the left or right half, it takes that side);
- **drag a corner** — it's made larger or smaller, to any size (the slider does the same in numbers);
- ◀ ▶ and the page number go through the book; **Find** jumps to the paragraph with some words in it.

A picture is tied to its *paragraph*, not to a page number, so it stays with its text however the pages move
when other pictures go in. What's chosen is handed back as `bookify.make_book(pictures=…)` entries
(`placements()`), and remembered per text by the Make Book window.

The preview page starts at the paragraph that begins that page of the book as made; with pictures in, what no
longer fits simply runs on to the next page, as it will in the book.
"""
from __future__ import annotations

import os
import threading
from typing import Callable

from PySide6.QtCore import QObject, QPointF, QRectF, QSize, Qt, QTimer, Signal
from PySide6.QtGui import QColor, QImage, QImageReader, QPainter, QPen, QPixmap
from PySide6.QtWidgets import (QCheckBox, QComboBox, QDialog, QFileDialog, QFormLayout, QHBoxLayout, QLabel,
                               QLineEdit, QListWidget, QListWidgetItem, QPushButton, QSlider, QSpinBox, QSplitter,
                               QVBoxLayout, QWidget)

PICTURE_EXTS = {".jpg", ".jpeg", ".png", ".heic", ".heif", ".webp", ".tif", ".tiff", ".bmp", ".gif"}
KINDS = [("beside", "Beside the text — the text flows round it"),
         ("between", "Between two paragraphs"),
         ("page", "A page of its own, after a paragraph"),
         ("front", "At the front — after the title page"),
         ("chapter_start", "At the start of a chapter"),
         ("chapter_end", "At the end of a chapter"),
         ("end", "At the end of the book")]
AT_PARAGRAPH = ("beside", "between", "page")
FLOAT_MOST = 0.7                 # (bookify's: beside the text a picture takes at most this much of the width)
ACCENT = QColor("#0A84FF")


def picture_thumb(path: str, side: int = 56) -> QPixmap:
    """A small picture of the picture (grey when Qt can't read it — an HEIC; the book still can)."""
    reader = QImageReader(path)
    reader.setAutoTransform(True)
    size = reader.size()
    if size.isValid() and max(size.width(), size.height()) > side * 2:
        reader.setScaledSize(size.scaled(QSize(side * 2, side * 2), Qt.AspectRatioMode.KeepAspectRatio))
    img = reader.read()
    if img.isNull():
        pm = QPixmap(side, side)
        pm.fill(QColor("#8E8E93"))
        return pm
    pm = QPixmap.fromImage(img).scaled(side * 2, side * 2, Qt.AspectRatioMode.KeepAspectRatio,
                                       Qt.TransformationMode.SmoothTransformation)
    pm.setDevicePixelRatio(2)
    return pm


def snippet(text: str, n: int = 46) -> str:
    text = " ".join((text or "").replace("<br/>", " ").split())
    return text if len(text) <= n else text[:n].rsplit(" ", 1)[0] + "…"


class PagePreview(QWidget):
    """A page of the book with what's on it to take hold of: paragraphs (click), pictures (click, drag, resize).
    Boxes are in points from the page's bottom left, as bookify gives them."""
    picked = Signal(int)                 # a paragraph was clicked
    chose = Signal(int)                  # a picture was clicked
    resized = Signal(float)              # the selected picture's new width, as a part of the text's width
    moved = Signal(int, str)             # the selected picture dropped on a paragraph, at this side

    def __init__(self) -> None:
        super().__init__()
        self.image: QImage | None = None
        self.page_size = (432.0, 648.0)
        self.frame = (0.0, 0.0, 1.0, 1.0)
        self.el_boxes: dict[int, list] = {}
        self.pic_boxes: dict[int, tuple] = {}
        self.selected = -1
        self.can_pick = False            # the selected picture is one that goes at a paragraph
        self.found: int | None = None    # a paragraph Find landed on
        self.message = ""
        self._hover: int | None = None
        self._drag: tuple | None = None  # ("resize", corner) | ("grab",) | ("move",)
        self._press: QPointF | None = None
        self._at: QPointF | None = None
        self.setMouseTracking(True)
        self.setMinimumSize(340, 460)
        self.setAccessibleName("The page as it will be")

    # ------------------------------------------------------------------ what's shown
    def show_page(self, image: QImage, page_size, frame, el_boxes: dict, pic_boxes: dict) -> None:
        self.image, self.page_size, self.frame = image, tuple(page_size), tuple(frame)
        self.el_boxes, self.pic_boxes = el_boxes, pic_boxes
        self.message = ""
        self._hover, self._drag = None, None
        self.update()

    def say(self, text: str) -> None:
        self.message = text
        self.update()

    # ------------------------------------------------------------------ page ↔ widget
    def _fit(self) -> tuple[float, float, float]:
        w, h = self.page_size
        room = self.rect().adjusted(14, 14, -14, -14)
        scale = max(0.05, min(room.width() / w, room.height() / h))
        return room.x() + (room.width() - w * scale) / 2, room.y() + (room.height() - h * scale) / 2, scale

    def _rect(self, box) -> QRectF:
        ox, oy, s = self._fit()
        x, y, w, h = box
        return QRectF(ox + x * s, oy + (self.page_size[1] - y - h) * s, w * s, h * s)

    def _page_point(self, pos: QPointF) -> tuple[float, float]:
        ox, oy, s = self._fit()
        return (pos.x() - ox) / s, self.page_size[1] - (pos.y() - oy) / s

    def el_at(self, pos: QPointF, nearest: bool = False) -> int | None:
        best, best_d = None, 1e9
        for el, boxes in self.el_boxes.items():
            for box in boxes:
                r = self._rect(box)
                if r.contains(pos):
                    return el
                if nearest:
                    d = abs(r.center().y() - pos.y())
                    if d < best_d:
                        best, best_d = el, d
        return best if nearest else None

    def pic_at(self, pos: QPointF) -> int | None:
        for n, box in self.pic_boxes.items():
            if self._rect(box).contains(pos):
                return n
        return None

    def _corners(self) -> list[QPointF]:
        if self.selected not in self.pic_boxes:
            return []
        r = self._rect(self.pic_boxes[self.selected])
        return [r.topLeft(), r.topRight(), r.bottomLeft(), r.bottomRight()]

    def corner_at(self, pos: QPointF) -> int | None:
        for i, c in enumerate(self._corners()):
            if abs(c.x() - pos.x()) <= 10 and abs(c.y() - pos.y()) <= 10:
                return i
        return None

    def width_for(self, corner: int, pos: QPointF) -> float:
        """The selected picture's width (a part of the text's width) with `corner` dragged to `pos`: the corner
        opposite stays, the shape is kept, and the greater of the two pulls — across or up and down — counts."""
        x, y, w, h = self.pic_boxes[self.selected]
        mx, my = self._page_point(pos)
        left, top = corner in (0, 2), corner in (0, 1)
        across = abs(mx - (x + w if left else x))
        down = abs(my - (y if top else y + h)) * (w / h if h else 1)
        new_w = across if abs(across - w) >= abs(down - w) else down
        return min(1.0, max(0.08, new_w / max(1.0, self.frame[2])))

    # ------------------------------------------------------------------ painting
    def paintEvent(self, _event) -> None:  # noqa: N802
        p = QPainter(self)
        p.setRenderHint(QPainter.RenderHint.Antialiasing)
        p.setRenderHint(QPainter.RenderHint.SmoothPixmapTransform)
        p.fillRect(self.rect(), self.palette().window().color().darker(112))
        ox, oy, s = self._fit()
        page = QRectF(ox, oy, self.page_size[0] * s, self.page_size[1] * s)
        if self.image is not None and not self.image.isNull():
            p.fillRect(page.translated(0, 3), QColor(0, 0, 0, 50))
            p.drawImage(page, self.image)
        else:
            p.fillRect(page, QColor("#F5EDD9"))
        if self.message:
            p.setPen(QColor("#6B6058"))
            p.drawText(page.adjusted(24, 24, -24, -24), Qt.AlignmentFlag.AlignCenter | Qt.TextFlag.TextWordWrap,
                       self.message)
            p.end()
            return
        moving = self._drag is not None and self._drag[0] == "move" and self._at is not None
        target = self.el_at(self._at, nearest=True) if moving else None
        tint = QColor(ACCENT)
        for el in (target, self._hover if self.can_pick and not moving else None):
            if el is not None:
                tint.setAlpha(48 if el == target else 28)
                for box in self.el_boxes.get(el, ()):
                    p.fillRect(self._rect(box).adjusted(-3, -1, 3, 1), tint)
        if self.found is not None and self.found in self.el_boxes:
            p.setPen(QPen(ACCENT, 1.4, Qt.PenStyle.DashLine))
            p.setBrush(Qt.BrushStyle.NoBrush)
            for box in self.el_boxes[self.found]:
                p.drawRect(self._rect(box).adjusted(-3, -1, 3, 1))
        for n, box in self.pic_boxes.items():
            r = self._rect(box)
            if n == self.selected:
                p.setPen(QPen(ACCENT, 2))
                p.setBrush(Qt.BrushStyle.NoBrush)
                p.drawRect(r)
                p.setBrush(QColor("white"))
                for c in self._corners():
                    p.drawRect(QRectF(c.x() - 4.5, c.y() - 4.5, 9, 9))
            else:
                p.setPen(QPen(QColor(120, 120, 120, 150), 1, Qt.PenStyle.DotLine))
                p.setBrush(Qt.BrushStyle.NoBrush)
                p.drawRect(r)
        if self._drag is not None and self._at is not None and self.selected in self.pic_boxes:
            x, y, w, h = self.pic_boxes[self.selected]
            p.setPen(QPen(ACCENT, 1.5, Qt.PenStyle.DashLine))
            ghost = QColor(ACCENT)
            ghost.setAlpha(40)
            p.setBrush(ghost)
            if self._drag[0] == "resize":
                corner = self._drag[1]
                new_w = self.width_for(corner, self._at) * self.frame[2]
                new_h = new_w * h / w if w else h
                nx = x + w - new_w if corner in (0, 2) else x
                ny = y if corner in (0, 1) else y + h - new_h
                p.drawRect(self._rect((nx, ny, new_w, new_h)))
                p.setPen(QColor("white"))
                r = self._rect((nx, ny, new_w, new_h))
                p.drawText(r, Qt.AlignmentFlag.AlignCenter, f"{round(100 * new_w / max(1.0, self.frame[2]))} %")
            elif moving:
                r = self._rect((x, y, w, h))
                r.moveCenter(self._at)
                p.drawRect(r)
        p.end()

    # ------------------------------------------------------------------ the mouse
    def mousePressEvent(self, event) -> None:  # noqa: N802
        if event.button() != Qt.MouseButton.LeftButton or self.message:
            return
        pos = event.position()
        self._press = self._at = pos
        corner = self.corner_at(pos)
        if corner is not None:
            self._drag = ("resize", corner)
        elif self.selected >= 0 and self.pic_at(pos) == self.selected:
            self._drag = ("grab",)
        else:
            self._drag = None

    def mouseMoveEvent(self, event) -> None:  # noqa: N802
        pos = event.position()
        if self._drag is not None and self._press is not None:
            self._at = pos
            if self._drag[0] == "grab" and (pos - self._press).manhattanLength() > 6:
                self._drag = ("move",)
            self.update()
            return
        corner = self.corner_at(pos)
        over_pic = self.pic_at(pos)
        hover = self.el_at(pos) if self.can_pick and over_pic is None and corner is None else None
        if corner is not None:
            self.setCursor(Qt.CursorShape.SizeFDiagCursor if corner in (0, 3) else Qt.CursorShape.SizeBDiagCursor)
        elif over_pic is not None:
            self.setCursor(Qt.CursorShape.OpenHandCursor if over_pic == self.selected else Qt.CursorShape.PointingHandCursor)
        elif hover is not None:
            self.setCursor(Qt.CursorShape.PointingHandCursor)
        else:
            self.unsetCursor()
        if hover != self._hover:
            self._hover = hover
            self.update()

    def mouseReleaseEvent(self, event) -> None:  # noqa: N802
        if event.button() != Qt.MouseButton.LeftButton or self._press is None:
            return
        pos, drag = event.position(), self._drag
        self._drag = self._press = None
        if drag is not None and drag[0] == "resize":
            if self.selected in self.pic_boxes:
                self.resized.emit(self.width_for(drag[1], pos))
        elif drag is not None and drag[0] == "move":
            el = self.el_at(pos, nearest=True)
            if el is not None:
                mx, _my = self._page_point(pos)
                self.moved.emit(el, "left" if mx < self.frame[0] + self.frame[2] / 2 else "right")
        else:
            n = self.pic_at(pos)
            if n is not None:
                self.chose.emit(n)
            elif self.can_pick:
                el = self.el_at(pos)
                if el is not None:
                    self.picked.emit(el)
        self._at = None
        self.update()

    def leaveEvent(self, _event) -> None:  # noqa: N802
        if self._hover is not None:
            self._hover = None
            self.update()


class _Bridge(QObject):
    ready = Signal(object, str)          # the Draft (None: it couldn't be read), why
    set = Signal(int, object, str)       # which request, bookify's answer (None: it couldn't be set), why


class PicturesDialog(QDialog):
    """Which pictures go in the book just made, where, and how big — on the page. `placements()` is the answer
    when accepted. `options`: the book's own (`BookWindow.options()`), so the preview is set as the book is;
    `load_bookify()` gives the bookify module."""

    def __init__(self, parent, book: str, source: str, summary, hooks, before: list[dict] | None = None,
                 options: dict | None = None, load_bookify: Callable | None = None) -> None:
        super().__init__(parent)
        self.book, self.source, self.summary, self.hooks = book, source, summary, hooks
        self.options = dict(options or {})
        self.load_bookify = load_bookify or (lambda: __import__("bookify"))
        self.pics: list[dict] = []
        self.draft = None
        self.texts: list[tuple[int, str, str]] = []          # (element, kind, text) — every element of the text
        self.paras: list[int] = []                           # the elements a picture can be put at
        self.chapter_els: list[int] = []
        self._loading = False                                # the controls are being filled: no echoes
        self._request = 0
        self._busy = False
        self._again = False
        self._pdf = None
        self.chapters = [(i, (title, page)) for i, (title, page) in enumerate(summary.chapter_list) if title]
        # The pages of the book as made, by the paragraph each begins with.
        firsts: dict[int, int] = {}
        for el, (first, last) in sorted(summary.el_pages.items()):
            firsts.setdefault(first, el)
            for page in range(first + 1, last + 1):          # a page a long paragraph runs across: that paragraph
                firsts.setdefault(page, el)
        self.page_tops = firsts
        self.text_pages = sorted(firsts)
        self.view_page = self.text_pages[0] if self.text_pages else 1
        self.bridge = _Bridge()
        self.bridge.ready.connect(self._ready)
        self.bridge.set.connect(self._set)
        self.setWindowTitle(f"Pictures — {os.path.basename(book)}")
        self.resize(1120, 780)

        # ---- left: the pictures and the selected one's choices
        head = QLabel(f"“{summary.title}” is made — {summary.pages} pages. Add pictures and put each one where you "
                      "want it: the page on the right shows it as it will be.")
        head.setWordWrap(True)
        add = QPushButton("Add Pictures…")
        add.clicked.connect(self.choose)
        add.setEnabled(False)                                # (until the text is read: a moment)
        self.add_btn = add
        look = QPushButton("Open the Book")
        look.clicked.connect(lambda: hooks.open_pdf(book) if getattr(hooks, "open_pdf", None) else None)
        look.setVisible(getattr(hooks, "open_pdf", None) is not None)
        tools = QHBoxLayout()
        tools.addWidget(add)
        tools.addWidget(look)
        tools.addStretch(1)
        self.list = QListWidget()
        self.list.setIconSize(QSize(48, 48))
        self.list.setWordWrap(True)
        self.list.setAccessibleName("Pictures in the book")
        self.list.currentRowChanged.connect(self._selected)
        self.empty = QLabel("No pictures yet — go to the page you want (◀ ▶ on the right), then Add Pictures…")
        self.empty.setWordWrap(True)
        self.empty.setObjectName("SheetSub")

        self.kind = QComboBox()
        for value, label in KINDS:
            if value.startswith("chapter") and not self.chapters:
                continue
            self.kind.addItem(label, value)
        self.kind.currentIndexChanged.connect(self._edited)
        self.at = QLabel("")
        self.at.setWordWrap(True)
        self.earlier = QPushButton("◀ Earlier")
        self.earlier.setToolTip("One paragraph earlier")
        self.earlier.clicked.connect(lambda: self._step(-1))
        self.later = QPushButton("Later ▶")
        self.later.setToolTip("One paragraph later")
        self.later.clicked.connect(lambda: self._step(1))
        at_row = QHBoxLayout()
        at_row.addWidget(self.at, 1)
        at_row.addWidget(self.earlier)
        at_row.addWidget(self.later)
        self.at_box = QWidget()
        self.at_box.setLayout(at_row)
        at_row.setContentsMargins(0, 0, 0, 0)
        self.chapter = QComboBox()
        for i, (title, page) in self.chapters:
            self.chapter.addItem(f"{title} — page {page}", i)
        self.chapter.currentIndexChanged.connect(self._edited)
        self.own_page = QCheckBox("On a page of its own")
        self.own_page.toggled.connect(self._edited)
        self.side = QComboBox()
        self.side.addItem("At the right of the text", "right")
        self.side.addItem("At the left of the text", "left")
        self.side.currentIndexChanged.connect(self._edited)
        self.align = QComboBox()
        for value, label in (("center", "In the middle"), ("left", "At the left"), ("right", "At the right")):
            self.align.addItem(label, value)
        self.align.currentIndexChanged.connect(self._edited)
        self.width = QSlider(Qt.Orientation.Horizontal)
        self.width.setRange(8, 100)
        self.width.setAccessibleName("Width of the picture, per cent of the text's width")
        self.width_box = QSpinBox()
        self.width_box.setRange(8, 100)
        self.width_box.setSuffix(" %")
        self.width.valueChanged.connect(self._width_slid)
        self.width_box.valueChanged.connect(self._width_typed)
        width_row = QHBoxLayout()
        width_row.addWidget(self.width, 1)
        width_row.addWidget(self.width_box)
        self.width_row = QWidget()
        self.width_row.setLayout(width_row)
        width_row.setContentsMargins(0, 0, 0, 0)
        self.caption = QLineEdit()
        self.caption.setPlaceholderText("Caption (optional)")
        self.caption.textEdited.connect(self._edited)
        self.remove = QPushButton("Remove This Picture")
        self.remove.clicked.connect(self._remove)
        form = QFormLayout()
        form.addRow("Where", self.kind)
        form.addRow("Paragraph", self.at_box)
        form.addRow("Chapter", self.chapter)
        form.addRow("", self.own_page)
        form.addRow("Side", self.side)
        form.addRow("Place", self.align)
        form.addRow("Width", self.width_row)
        form.addRow("Caption", self.caption)
        self.form = form
        self.controls = QWidget()
        cl = QVBoxLayout(self.controls)
        cl.setContentsMargins(0, 0, 0, 0)
        cl.addLayout(form)
        hint = QLabel("On the page: click a paragraph to put the picture there, drag the picture to move it, drag "
                      "a corner to make it larger or smaller.")
        hint.setWordWrap(True)
        hint.setObjectName("SheetSub")
        cl.addWidget(hint)
        cl.addWidget(self.remove, 0, Qt.AlignmentFlag.AlignLeft)

        cancel = QPushButton("No Pictures")
        cancel.clicked.connect(self.reject)
        self.ok = QPushButton("Add to the Book")
        self.ok.setObjectName("Primary")
        self.ok.clicked.connect(self.accept)
        buttons = QHBoxLayout()
        buttons.addStretch(1)
        buttons.addWidget(cancel)
        buttons.addWidget(self.ok)
        left = QWidget()
        ll = QVBoxLayout(left)
        ll.addWidget(head)
        ll.addLayout(tools)
        ll.addWidget(self.empty)
        ll.addWidget(self.list, 1)
        ll.addWidget(self.controls)
        ll.addLayout(buttons)

        # ---- right: the page
        self.prev_btn = QPushButton("◀")
        self.prev_btn.setToolTip("The page before")
        self.prev_btn.clicked.connect(lambda: self._turn(-1))
        self.next_btn = QPushButton("▶")
        self.next_btn.setToolTip("The next page")
        self.next_btn.clicked.connect(lambda: self._turn(1))
        self.page_box = QSpinBox()
        self.page_box.setRange(1, max(1, summary.pages))
        self.page_box.setPrefix("Page ")
        self.page_box.setKeyboardTracking(False)
        self.page_box.valueChanged.connect(self._page_typed)
        self.find = QLineEdit()
        self.find.setPlaceholderText("Find words in the text…")
        self.find.setClearButtonEnabled(True)
        self.find.returnPressed.connect(self._find)
        self.note = QLabel("")
        self.note.setObjectName("SheetSub")
        bar = QHBoxLayout()
        bar.addWidget(self.prev_btn)
        bar.addWidget(self.page_box)
        bar.addWidget(self.next_btn)
        bar.addSpacing(12)
        bar.addWidget(self.find, 1)
        self.preview = PagePreview()
        self.preview.picked.connect(self._picked)
        self.preview.chose.connect(lambda n: self.list.setCurrentRow(n))
        self.preview.resized.connect(self._resized)
        self.preview.moved.connect(self._moved)
        right = QWidget()
        rl = QVBoxLayout(right)
        rl.addLayout(bar)
        rl.addWidget(self.preview, 1)
        rl.addWidget(self.note)

        split = QSplitter(Qt.Orientation.Horizontal)
        split.addWidget(left)
        split.addWidget(right)
        split.setStretchFactor(0, 0)
        split.setStretchFactor(1, 1)
        split.setSizes([470, 650])
        lay = QVBoxLayout(self)
        lay.addWidget(split)

        for button in self.findChildren(QPushButton):        # Return in Find or the caption presses nothing
            button.setAutoDefault(False)
            button.setDefault(False)
        self._timer = QTimer(self)
        self._timer.setSingleShot(True)
        self._timer.setInterval(70)
        self._timer.timeout.connect(self._typeset)
        self._before = [p for p in (before or []) if os.path.isfile(p.get("path", ""))]
        self._view_quietly(self.view_page)
        self.preview.say("Reading the text…")
        self._show_controls()
        self._refresh_list()
        self.finished.connect(lambda _code: self._close_draft())
        self._open_draft()

    # ------------------------------------------------------------------ the draft (the text, read once)
    def _open_draft(self) -> None:
        source, options, load, bridge = self.source, self.options, self.load_bookify, self.bridge

        def work() -> None:
            try:
                draft = load().Draft(source, **options)
                bridge.ready.emit(draft, "")
            except Exception as e:  # noqa: BLE001 — whatever stops it, the window says so
                try:
                    bridge.ready.emit(None, f"{type(e).__name__}: {e}")
                except RuntimeError:
                    pass
        threading.Thread(target=work, name="book-draft", daemon=True).start()

    def _ready(self, draft, why: str) -> None:
        if draft is None:
            self.preview.say(f"The page can't be shown ({why}). The pictures can still be chosen and placed "
                             "with the choices on the left.")
        self.draft = draft
        self.add_btn.setEnabled(True)
        if draft is not None:
            self.texts = draft.texts()
            self.paras = [i for i, kind, _t in self.texts if kind in ("para", "item")]
            self.chapter_els = [i for i, kind, _t in self.texts if kind == "chapter"]
        for old in self._before:
            self.pics.append(self._from_placement(old))
        self._before = []
        self._refresh_list()
        if self.pics:
            self.list.setCurrentRow(0)
        else:
            self._show_page()

    def _close_draft(self) -> None:
        draft, self.draft = self.draft, None
        if draft is not None and not self._busy:
            draft.close()
        elif draft is not None:
            self._leftover = draft                           # still setting a page: closed when that comes back

    # ------------------------------------------------------------------ pictures ⇄ what bookify is told
    def _from_placement(self, p: dict) -> dict:
        """A remembered (or old-style) choice as this window keeps it."""
        where, size = p.get("where", "end"), p.get("size", "page")
        width = float(p.get("width") or (0.5 if size == "half" else 1.0 if size in ("wide", "page") else 0.4))
        pic = {"path": p["path"], "kind": "end", "el": self.paras[0] if self.paras else 0, "chapter": 0,
               "own_page": size == "page", "side": p.get("side") or "right", "align": p.get("align") or "center",
               "width": min(1.0, max(0.08, width)), "caption": p.get("caption", "")}
        index = int(p.get("index", 0) or 0)
        if where == "page":                                   # an old "on page N": the paragraph that's there
            el = None
            try:
                el = self.load_bookify().element_for_page(self.summary.el_pages, index, size == "page")
            except Exception:  # noqa: BLE001
                pass
            where, index = ("front", 0) if el is None else ("after", el)
        if where == "beside":
            pic.update(kind="beside", el=self._para_near(index), width=min(FLOAT_MOST, pic["width"]))
        elif where == "after":
            pic.update(kind="page" if size == "page" else "between", el=self._para_near(index))
        elif where in ("chapter_start", "chapter_end"):
            pic.update(kind=where, chapter=index)
        elif where == "front":
            pic.update(kind="front", own_page=True)
        return pic

    def _para_near(self, el: int) -> int:
        if not self.paras:
            return el
        return el if el in self.paras else min(self.paras, key=lambda x: abs(x - el))

    def _placement(self, pic: dict) -> dict:
        kind = pic["kind"]
        out = {"path": pic["path"], "caption": pic["caption"].strip(), "index": 0, "size": "free",
               "width": round(pic["width"], 3), "align": pic["align"], "side": pic["side"]}
        if kind == "beside":
            out.update(where="beside", index=int(pic["el"]), width=round(min(FLOAT_MOST, pic["width"]), 3))
        elif kind == "between":
            out.update(where="after", index=int(pic["el"]))
        elif kind == "page":
            out.update(where="after", index=int(pic["el"]), size="page")
        elif kind == "front":
            out.update(where="front", size="page")
        elif kind in ("chapter_start", "chapter_end"):
            out.update(where=kind, index=int(pic["chapter"]), size="page" if pic["own_page"] else "free")
        else:
            out.update(where="end", size="page" if pic["own_page"] else "free")
        return out

    def placements(self) -> list[dict]:
        return [self._placement(p) for p in self.pics]

    # ------------------------------------------------------------------ the list
    def _describe(self, pic: dict) -> str:
        kind, pct = pic["kind"], f"{round(pic['width'] * 100)} %"
        if kind in AT_PARAGRAPH:
            text = next((t for i, _k, t in self.texts if i == pic["el"]), "")
            page = self.summary.el_pages.get(pic["el"], (0, 0))[0]
            where = f"“{snippet(text, 34)}”" + (f" — about page {page}" if page else "")
            if kind == "beside":
                return f"Beside the text, {pic['side']}, {pct}\n{where}"
            if kind == "between":
                return f"Between paragraphs, {pct}\nafter {where}"
            return f"A page of its own\nafter {where}"
        if kind == "front":
            return "At the front\nafter the title page"
        how = "a page of its own" if pic["own_page"] else pct
        if kind in ("chapter_start", "chapter_end"):
            title = next((t for i, (t, _p) in self.chapters if i == pic["chapter"]), "the chapter")
            return f"{'Start' if kind == 'chapter_start' else 'End'} of “{snippet(title, 30)}”\n{how}"
        return f"At the end of the book\n{how}"

    def _refresh_list(self) -> None:
        row = self.list.currentRow()
        self.list.blockSignals(True)
        while self.list.count() > len(self.pics):
            self.list.takeItem(self.list.count() - 1)
        for i, pic in enumerate(self.pics):
            if i >= self.list.count():
                item = QListWidgetItem()
                item.setIcon(picture_thumb(pic["path"], 48))
                self.list.addItem(item)
            item = self.list.item(i)
            item.setText(f"{os.path.basename(pic['path'])}\n{self._describe(pic)}")
            item.setToolTip(pic["path"])
        self.list.blockSignals(False)
        if 0 <= row < len(self.pics):
            self.list.setCurrentRow(row)
        n = len(self.pics)
        self.empty.setVisible(n == 0)
        self.list.setVisible(n > 0)
        self.ok.setEnabled(n > 0)
        self.ok.setText(f"Add {n} Picture{'s' if n != 1 else ''} to the Book" if n else "Add to the Book")

    def current(self) -> dict | None:
        row = self.list.currentRow()
        return self.pics[row] if 0 <= row < len(self.pics) else None

    def choose(self) -> None:
        start = os.path.dirname(self.pics[-1]["path"]) if self.pics else os.path.dirname(self.source)
        exts = " ".join(f"*{e}" for e in sorted(PICTURE_EXTS))
        files, _ = QFileDialog.getOpenFileNames(self, "Pictures for the book", start, f"Pictures ({exts});;All files (*)")
        self.add_files(files)

    def add_files(self, files: list[str]) -> None:
        """New pictures go beside the text on the page in view — one paragraph after another, right then left."""
        first = len(self.pics)
        start = self._para_near(self.page_tops.get(self.view_page, self.paras[0] if self.paras else 0))
        at = self.paras.index(start) if start in self.paras else 0
        for f in files:
            if os.path.splitext(f)[1].lower() not in PICTURE_EXTS or not os.path.isfile(f):
                continue
            k = len(self.pics) - first
            if self.paras:
                el = self.paras[min(len(self.paras) - 1, at + 2 * k)]
                self.pics.append({"path": f, "kind": "beside", "el": el, "chapter": 0, "own_page": True,
                                  "side": "right" if k % 2 == 0 else "left", "align": "center", "width": 0.4,
                                  "caption": ""})
            else:                                             # a text with no paragraphs: only whole pages
                self.pics.append({"path": f, "kind": "end", "el": 0, "chapter": 0, "own_page": True,
                                  "side": "right", "align": "center", "width": 1.0, "caption": ""})
        self._refresh_list()
        if len(self.pics) > first:
            self.list.setCurrentRow(first)

    def _remove(self) -> None:
        row = self.list.currentRow()
        if 0 <= row < len(self.pics):
            del self.pics[row]
            self.list.blockSignals(True)
            self.list.takeItem(row)
            self.list.blockSignals(False)
            self._refresh_list()
            self.list.setCurrentRow(min(row, len(self.pics) - 1))
            if not self.pics:
                self._selected(-1)

    # ------------------------------------------------------------------ the selected picture's choices
    def _selected(self, _row: int) -> None:
        pic = self.current()
        self._show_controls()
        if pic is not None and pic["kind"] in AT_PARAGRAPH:
            self._go_to_el(pic["el"])
        self._show_page()

    def _show_controls(self) -> None:
        pic = self.current()
        self.controls.setEnabled(pic is not None)
        self._loading = True
        if pic is not None:
            self.kind.setCurrentIndex(max(0, self.kind.findData(pic["kind"])))
            self.chapter.setCurrentIndex(max(0, self.chapter.findData(pic["chapter"])))
            self.own_page.setChecked(bool(pic["own_page"]))
            self.side.setCurrentIndex(max(0, self.side.findData(pic["side"])))
            self.align.setCurrentIndex(max(0, self.align.findData(pic["align"])))
            most = int(FLOAT_MOST * 100) if pic["kind"] == "beside" else 100
            self.width.setMaximum(most)
            self.width_box.setMaximum(most)
            self.width.setValue(round(min(pic["width"], most / 100) * 100))
            self.width_box.setValue(self.width.value())
            if self.caption.text() != pic["caption"]:
                self.caption.setText(pic["caption"])
            text = next((t for i, _k, t in self.texts if i == pic["el"]), "")
            self.at.setText(f"“{snippet(text, 60)}”" if text else "—")
        kind = pic["kind"] if pic is not None else ""
        whole = kind in ("front", "page") or (kind in ("chapter_start", "chapter_end", "end") and pic["own_page"])
        rows = {self.at_box: kind in AT_PARAGRAPH, self.chapter: kind in ("chapter_start", "chapter_end"),
                self.own_page: kind in ("chapter_start", "chapter_end", "end"), self.side: kind == "beside",
                self.align: kind not in ("beside", "") and not whole, self.width_row: bool(kind) and not whole}
        for widget, shown in rows.items():
            self.form.setRowVisible(widget, shown)
        self.caption.setEnabled(pic is not None)
        self.preview.selected = self.list.currentRow()
        self.preview.can_pick = kind in AT_PARAGRAPH
        self._loading = False

    def _edited(self, *_a) -> None:
        pic = self.current()
        if self._loading or pic is None:
            return
        was = pic["kind"]
        pic.update(kind=self.kind.currentData(), chapter=int(self.chapter.currentData() or 0),
                   own_page=self.own_page.isChecked(), side=self.side.currentData(),
                   align=self.align.currentData(), caption=self.caption.text())
        if pic["kind"] == "beside":
            pic["width"] = min(FLOAT_MOST, pic["width"])
        if pic["kind"] != was:
            if pic["kind"] in AT_PARAGRAPH and was not in AT_PARAGRAPH:      # it goes where the page in view is
                pic["el"] = self._para_near(self.page_tops.get(self.view_page, pic["el"]))
            self._show_controls()
            if pic["kind"] in AT_PARAGRAPH:
                self._go_to_el(pic["el"])
        self._changed()

    def _changed(self) -> None:
        self._refresh_list()
        self._show_page()

    def _width_slid(self, value: int) -> None:
        if self._loading:
            return
        self._loading = True
        self.width_box.setValue(value)
        self._loading = False
        self._set_width(value / 100)

    def _width_typed(self, value: int) -> None:
        if self._loading:
            return
        self._loading = True
        self.width.setValue(value)
        self._loading = False
        self._set_width(value / 100)

    def _set_width(self, frac: float) -> None:
        pic = self.current()
        if pic is None:
            return
        pic["width"] = min(FLOAT_MOST if pic["kind"] == "beside" else 1.0, max(0.08, frac))
        self._changed()

    def _resized(self, frac: float) -> None:
        pic = self.current()
        if pic is None:
            return
        if pic["kind"] == "page" or (pic["kind"] in ("front",) or (pic["kind"] in ("chapter_start", "chapter_end", "end")
                                                                    and pic["own_page"])):
            self.note.setText("A picture on a page of its own fills the page — choose another place to size it.")
            self._show_page()
            return
        pic["width"] = min(FLOAT_MOST if pic["kind"] == "beside" else 1.0, max(0.08, frac))
        self._show_controls()
        self._changed()

    def _picked(self, el: int) -> None:
        pic = self.current()
        if pic is None or pic["kind"] not in AT_PARAGRAPH or el not in self.paras:
            return
        pic["el"] = el
        self.preview.found = None
        self._show_controls()
        self._changed()

    def _moved(self, el: int, side: str) -> None:
        pic = self.current()
        if pic is None or el not in self.paras:
            return
        if pic["kind"] not in AT_PARAGRAPH:
            pic["kind"] = "beside"
            pic["width"] = min(FLOAT_MOST, pic["width"])
        pic["el"] = el
        if pic["kind"] == "beside":
            pic["side"] = side
        elif pic["kind"] == "between":
            pic["align"] = side if pic["align"] != "center" else "center"
        self._show_controls()
        self._changed()

    def _step(self, by: int) -> None:
        pic = self.current()
        if pic is None or not self.paras:
            return
        at = self.paras.index(self._para_near(pic["el"]))
        pic["el"] = self.paras[max(0, min(len(self.paras) - 1, at + by))]
        self._show_controls()
        self._go_to_el(pic["el"], only_if_off_page=True)
        self._changed()

    # ------------------------------------------------------------------ going through the book
    def _go_to_el(self, el: int, only_if_off_page: bool = False) -> None:
        """The page in view becomes the one `el` is on (in the book as made)."""
        if only_if_off_page and el in self.preview.el_boxes:
            return
        page = self.summary.el_pages.get(el, (None, None))[0]
        if page is None and self.text_pages:                 # (an element the book as made didn't note: the nearest)
            near = min(self.summary.el_pages, key=lambda x: abs(x - el), default=None)
            page = self.summary.el_pages[near][0] if near is not None else self.text_pages[0]
        if page is not None:
            self._view(page)

    def _view(self, page: int) -> None:
        if not self.text_pages:
            return
        page = min(self.text_pages, key=lambda p: (abs(p - page), p))        # a page with text on it
        self.view_page = page
        self.page_box.blockSignals(True)
        self.page_box.setValue(page)
        self.page_box.blockSignals(False)

    def _turn(self, by: int) -> None:
        if not self.text_pages:
            return
        i = self.text_pages.index(self.view_page) if self.view_page in self.text_pages else 0
        self._view(self.text_pages[max(0, min(len(self.text_pages) - 1, i + by))])
        self._browse()

    def _page_typed(self, page: int) -> None:
        self._view(page)
        self._browse()

    def _browse(self) -> None:
        """A page was turned to by hand: it's shown as it is — the selected picture stays where it was put."""
        self._show_page(follow=False)

    def _find(self) -> None:
        words = [w for w in self.find.text().casefold().split() if w]
        if not words or not self.texts:
            return
        start = (self.preview.found if self.preview.found is not None
                 else self.page_tops.get(self.view_page, 0) - 1)
        order = [t for t in self.texts if t[0] > start] + [t for t in self.texts if t[0] <= start]
        for el, kind, text in order:
            low = text.casefold()
            if kind in ("para", "item") and all(w in low for w in words):
                self.preview.found = el
                self._go_to_el(el)
                self.note.setText(f"Found in “{snippet(text, 50)}” — click it to put the picture there.")
                self._show_page(follow=False, el=el)
                return
        self.note.setText("Those words aren't in the text.")

    # ------------------------------------------------------------------ the page, set again
    def _show_page(self, follow: bool = True, el: int | None = None) -> None:
        """The page in view is set again. `follow`: keep the selected picture in sight (it may have been carried
        on to the next page); `el`: keep this paragraph in sight instead."""
        self._follow, self._follow_el = follow, el
        self._timer.start()

    def _typeset(self) -> None:
        if self.draft is None:
            return
        if self._busy:
            self._again = True
            return
        pic = self.current()
        pics = self.placements()
        draft, bridge = self.draft, self.bridge
        self._request += 1
        request = self._request
        out = os.path.join(draft.tmp, f"page-{request % 4}.pdf")
        whole = pic is not None and getattr(self, "_follow", True) and (
            pic["kind"] in ("front", "page") or (pic["kind"] in ("chapter_start", "chapter_end", "end") and pic["own_page"]))
        top, page, head = self._top_for(pic if getattr(self, "_follow", True) else None)
        row = self.list.currentRow()
        follow = row if pic is not None and getattr(self, "_follow", True) and row >= 0 else None
        follow_el = getattr(self, "_follow_el", None)
        self._busy = True

        def work() -> None:
            try:
                if whole:
                    got = draft.plate(pics[row], out)
                    got.pic_boxes = {row: box for _n, box in got.pic_boxes.items()}
                else:
                    got = draft.page(pics, top, out, real_page=page, head=head, follow=follow, follow_el=follow_el)
                why = ""
            except Exception as e:  # noqa: BLE001
                got, why = None, f"{type(e).__name__}: {e}"
            try:
                bridge.set.emit(request, got, why)
            except RuntimeError:                             # the window is gone
                draft.close()
        threading.Thread(target=work, name="book-page", daemon=True).start()

    def _top_for(self, pic: dict | None) -> tuple[int, int, str]:
        """(the element the page starts at, its page number in the book, the running head) for what's in view."""
        page = self.view_page
        if pic is not None and pic["kind"] in ("chapter_start", "chapter_end") and not pic["own_page"] \
                and 0 <= pic["chapter"] < len(self.chapter_els):
            ch = self.chapter_els[pic["chapter"]]
            if pic["kind"] == "chapter_start":
                page = next((p for i, (_t, p) in enumerate(self.summary.chapter_list) if i == pic["chapter"]), page)
                self._view_quietly(page)
                return ch, page, ""
            nxt = self.chapter_els[pic["chapter"] + 1] if pic["chapter"] + 1 < len(self.chapter_els) else len(self.texts)
            last = max((i for i in self.paras if ch < i < nxt), default=None)
            if last is not None and last in self.summary.el_pages:
                page = self.summary.el_pages[last][1]
                self._view_quietly(page)
        top = self.page_tops.get(page, self.paras[0] if self.paras else 0)
        # What stands right before that paragraph on the same page — a chapter's heading (a chapter always starts
        # its page), a section's, a scene break — is part of the page too.
        kinds = {i: kind for i, kind, _t in self.texts}
        while top > 0 and kinds.get(top - 1) in ("chapter", "section", "break") \
                and self.summary.el_pages.get(top, (page, page))[0] == page:
            top -= 1
            if kinds.get(top) == "chapter":
                break
        head = ""
        for title, at in self.summary.chapter_list:
            if at <= page and title:
                head = title
        return top, page, head

    def _view_quietly(self, page: int) -> None:
        self.view_page = page
        self.page_box.blockSignals(True)
        self.page_box.setValue(page)
        self.page_box.blockSignals(False)

    def _set(self, request: int, got, why: str) -> None:
        self._busy = False
        if self.draft is None:                               # closed meanwhile
            leftover = getattr(self, "_leftover", None)
            if leftover is not None:
                leftover.close()
            return
        if self._again or request != self._request:
            self._again = False
            self._timer.start()
            if got is None:
                return
        if got is None:
            self.preview.say(f"This page couldn't be set ({why}).")
            return
        image = self._render(got.out, got.show)
        if image is None:
            self.preview.say("The page preview needs Qt's PDF support (QtPdf), which isn't here — the choices on "
                             "the left still work.")
            return
        self.preview.selected = self.list.currentRow()
        self.preview.show_page(image, got.page_size, got.frame, got.el_boxes, got.pic_boxes)
        pic = self.current()
        pushed = getattr(got, "pushed", 0)
        if pushed and self.note.text().startswith("Found in"):
            pass                                             # (the page the found paragraph is on, as it will be)
        elif pushed:
            self.note.setText(f"There wasn't room for it on page {self.view_page}, so it starts "
                              f"{'the next page' if pushed == 1 else 'a later page'} — that's the page shown. Make "
                              "it smaller, or put it at an earlier paragraph, to keep it there.")
        elif pic is not None and self.list.currentRow() not in got.pic_boxes and getattr(self, "_follow", True) \
                and pic["kind"] in AT_PARAGRAPH + ("chapter_start", "chapter_end"):
            self.note.setText("The picture isn't on this page — its paragraph is further on. ▶ goes there.")
        elif pic is not None and self.list.currentRow() in got.pic_boxes and pic["kind"] in ("beside", "between") \
                and got.pic_boxes[self.list.currentRow()][2] < got.frame[2] * pic["width"] - 3:
            shown = round(100 * got.pic_boxes[self.list.currentRow()][2] / max(1.0, got.frame[2]))
            self.note.setText(f"At {round(pic['width'] * 100)} % this picture would be taller than the page allows — "
                              f"it's shown as large as it can be here ({shown} %).")
        elif not self.note.text().startswith("Found in"):
            self.note.setText("")

    def _render(self, pdf: str, page: int) -> QImage | None:
        try:
            from PySide6.QtPdf import QPdfDocument
        except ImportError:
            return None
        if self._pdf is None:
            self._pdf = QPdfDocument(self)
        self._pdf.close()
        self._pdf.load(pdf)
        if self._pdf.pageCount() <= page:
            return None
        size = self._pdf.pagePointSize(page)
        scale = 2.0 * max(1.0, self.devicePixelRatioF() / 2)
        image = self._pdf.render(page, QSize(int(size.width() * scale), int(size.height() * scale)))
        self._pdf.close()
        return image
