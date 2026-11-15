"""People — the window. Photos' People for the library on the drive: the faces in your photos, found and grouped on
this Mac (`faces.py`, `people.py`), shown as people you can name.

- **The grid**: a circle for each person — their key face — with their name (or "Add Name") and how many
  photos. Favourites first, then the people you've named (A–Z), then the unnamed by how many photos. The field
  at the top finds a name.
- **A click** selects (⌘- or ⇧-click for several); **a double-click** shows that person's photos in the main
  window — a collection like a tag's, so the viewer, tags and everything else work on it. **Click a name** to
  name or rename; a name someone else has merges the two (it asks first).
- **Right-click**: Show Photos, Add Name / Rename, Merge with the others selected, Review Suggestions…, Choose
  Key Photo…, Favorite, Hide, Tag Their Photos (the name as a tag — which the iPhone app then shows too),
  Not a Person (the group is taken apart).
- **Review Suggestions…**: faces that are probably this person but not surely enough to add unasked — each a
  tile: ✓ it's them, ✗ it isn't (never suggested for them again), or left for later.
- **Same Person?**: pairs of people who may be one — Same Person merges them, Different People never asks again.
- **Find People…** looks at the photos not looked at yet — on the drive, or in the folder the main window
  shows — a few at a time in the background, with a count and a Stop that loses nothing; then groups what it
  found. The first time, it says what's about to happen and downloads the two models it needs (39 MB, from
  OpenCV, checked).
- **⋯ ▸ Forget All Face Data…** deletes every face, group and name (the photos aren't touched).

Everything stays on this Mac. The app never puts a name to a face itself.
"""
from __future__ import annotations

import os
import threading
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from typing import Callable

from PySide6.QtCore import QObject, QRectF, QSize, Qt, QTimer, Signal
from PySide6.QtGui import QColor, QFont, QFontMetrics, QImage, QPainter, QPainterPath, QPen, QPixmap
from PySide6.QtWidgets import (QDialog, QFrame, QHBoxLayout, QInputDialog, QLabel, QLineEdit, QMenu, QMessageBox,
                               QProgressBar, QPushButton, QScrollArea, QToolButton, QVBoxLayout, QWidget)

import faces
import people
from duplicates_window import FlowLayout

FACE = 112                      # a person's circle
TILE_W, TILE_H = 136, 172


@dataclass
class PeopleHooks:
    show: Callable[[int], None]                               # a person's photos in the main window
    folder: Callable[[], str]                                 # the folder the main window shows ("" when none)
    drives: Callable[[], list[str]]                           # the drives connected now
    tag: Callable[[list[str], str], None] | None = None       # tag these photos with a name
    note: Callable[[str], None] | None = None                 # a line on the main window


class _Bridge(QObject):
    face = Signal(int, object)              # a face's picture is ready (face id, QImage)
    progress = Signal(str)
    scanned = Signal(object, str)           # the scan's totals (or None), and why it ended early ("" when it didn't)
    ready = Signal(bool, str)               # the models are there (or why not)
    changed = Signal()                      # the store changed (told from whichever thread changed it)


class FaceCache:
    """Each face's square picture, cut from its photo on a worker thread and kept (memory, and a small file in
    the People folder so the window opens at once next time)."""

    def __init__(self, bridge: _Bridge) -> None:
        self.bridge = bridge
        self.images: dict[int, QPixmap] = {}
        self.asked: set[int] = set()
        self.pool = ThreadPoolExecutor(max_workers=3)
        self.folder = people.folder() / "thumbs"
        bridge.face.connect(self._ready)

    def get(self, face: people.Face | None) -> QPixmap | None:
        if face is None:
            return None
        pm = self.images.get(face.id)
        if pm is None and face.id not in self.asked:
            self.asked.add(face.id)
            self.pool.submit(self._load, face)
        return pm

    def _load(self, face: people.Face) -> None:
        cached = self.folder / f"{face.id}.jpg"
        img = QImage(str(cached)) if cached.is_file() else QImage()
        if img.isNull():
            try:
                pil = faces.crop(face.path, face.box, 224)
                self.folder.mkdir(parents=True, exist_ok=True)
                pil.save(cached, "JPEG", quality=88)
                img = QImage(str(cached))
            except Exception:  # noqa: BLE001 — the photo is gone, or the drive is away: no picture
                img = QImage()
        try:
            self.bridge.face.emit(face.id, img)
        except RuntimeError:
            pass

    def _ready(self, face_id: int, img: QImage) -> None:
        self.images[face_id] = QPixmap.fromImage(img) if not img.isNull() else QPixmap()

    def forget(self) -> None:
        self.images.clear()
        self.asked.clear()
        try:
            for f in self.folder.iterdir():
                f.unlink()
        except OSError:
            pass


def draw_circle(p: QPainter, rect: QRectF, pm: QPixmap | None, theme, ring: QColor | None = None) -> None:
    """A face in a circle (a soft grey disc with a head-and-shoulders mark while there's no picture)."""
    clip = QPainterPath()
    clip.addEllipse(rect)
    p.save()
    p.setClipPath(clip)
    p.fillRect(rect, QColor(theme.panel if not theme.dark else "#2C2C2E"))
    if pm is not None and not pm.isNull():
        p.drawPixmap(rect, pm, QRectF(pm.rect()))
    else:
        p.setPen(Qt.PenStyle.NoPen)
        p.setBrush(QColor(theme.tertiary))
        c, r = rect.center(), rect.width()
        p.drawEllipse(c + type(c)(0, -r * 0.10), r * 0.17, r * 0.17)
        p.drawEllipse(QRectF(c.x() - r * 0.30, c.y() + r * 0.14, r * 0.60, r * 0.60))
    p.restore()
    p.setBrush(Qt.BrushStyle.NoBrush)
    p.setPen(QPen(ring, 3) if ring is not None else QPen(QColor(128, 128, 128, 70), 1))
    p.drawEllipse(rect.adjusted(1.5, 1.5, -1.5, -1.5) if ring is not None else rect)


class PersonTile(QWidget):
    clicked = Signal(object, object)        # (tile, the mouse event's modifiers)
    opened = Signal(object)
    named = Signal(object)
    menu = Signal(object, object)

    def __init__(self, person: people.Person, win: "PeopleWindow") -> None:
        super().__init__()
        self.person, self.win = person, win
        self.selected = False
        self.setFixedSize(TILE_W, TILE_H)
        self.setCursor(Qt.CursorShape.PointingHandCursor)
        self.setAccessibleName(person.label)
        self.setToolTip(f"{person.label} — {person.photos:,} photo{'s' if person.photos != 1 else ''}\n"
                        "Double-click to see them; click the name to change it")

    def _name_rect(self) -> QRectF:
        return QRectF(2, FACE + 16, TILE_W - 4, 22)

    def paintEvent(self, _e) -> None:  # noqa: N802
        t = self.win.theme
        p = QPainter(self)
        p.setRenderHint(QPainter.RenderHint.Antialiasing)
        p.setRenderHint(QPainter.RenderHint.SmoothPixmapTransform)
        circle = QRectF((TILE_W - FACE) / 2, 8, FACE, FACE)
        pm = self.win.cache.get(self.win.store.key_face(self.person.id))
        draw_circle(p, circle, pm, t, QColor(t.accent) if self.selected else None)
        if self.person.favorite:
            p.setPen(Qt.PenStyle.NoPen)
            p.setBrush(QColor("#FF375F"))
            p.drawEllipse(QRectF(circle.right() - 26, circle.bottom() - 26, 22, 22))
            p.setPen(QColor("white"))
            f = QFont(self.font())
            f.setPointSizeF(max(8.0, f.pointSizeF() - 1))
            p.setFont(f)
            p.drawText(QRectF(circle.right() - 26, circle.bottom() - 26, 22, 22), Qt.AlignmentFlag.AlignCenter, "♥")
        name = QFont(self.font())
        name.setWeight(QFont.Weight.DemiBold if self.person.name else QFont.Weight.Normal)
        p.setFont(name)
        p.setPen(QColor(t.text if self.person.name else t.accent))
        fm = QFontMetrics(name)
        p.drawText(self._name_rect(), Qt.AlignmentFlag.AlignCenter,
                   fm.elidedText(self.person.name or "Add Name", Qt.TextElideMode.ElideRight, TILE_W - 8))
        small = QFont(self.font())
        small.setPointSizeF(max(8.0, small.pointSizeF() - 2))
        p.setFont(small)
        p.setPen(QColor(t.secondary))
        p.drawText(QRectF(2, FACE + 38, TILE_W - 4, 18), Qt.AlignmentFlag.AlignCenter,
                   f"{self.person.photos:,}" + ("  · hidden" if self.person.hidden else ""))
        p.end()

    def mousePressEvent(self, e) -> None:  # noqa: N802
        if e.button() == Qt.MouseButton.LeftButton:
            if self._name_rect().contains(e.position()) and not (e.modifiers() & (Qt.KeyboardModifier.ControlModifier
                                                                                  | Qt.KeyboardModifier.ShiftModifier)):
                self.named.emit(self)
            else:
                self.clicked.emit(self, e.modifiers())

    def mouseDoubleClickEvent(self, e) -> None:  # noqa: N802
        if not self._name_rect().contains(e.position()):
            self.opened.emit(self)

    def contextMenuEvent(self, e) -> None:  # noqa: N802
        self.menu.emit(self, e.globalPos())


class FaceTile(QWidget):
    """One face in a review: ✓ (theirs), ✗ (not theirs), or neither. A click goes round the three."""
    changed = Signal()

    def __init__(self, face: people.Face, how_close: float, win) -> None:
        super().__init__()
        self.face, self.win = face, win
        self.answer = ""                     # "" | "yes" | "no"
        self.setFixedSize(108, 128)
        self.setCursor(Qt.CursorShape.PointingHandCursor)
        self.setToolTip(f"{os.path.basename(face.path)}\n{round(how_close * 100)}% alike — click: yes, no, later")

    def mousePressEvent(self, e) -> None:  # noqa: N802
        if e.button() == Qt.MouseButton.LeftButton:
            self.answer = {"": "yes", "yes": "no", "no": ""}[self.answer]
        elif e.button() == Qt.MouseButton.RightButton:
            self.answer = "no" if self.answer != "no" else ""
        self.update()
        self.changed.emit()

    def paintEvent(self, _e) -> None:  # noqa: N802
        t = self.win.theme
        p = QPainter(self)
        p.setRenderHint(QPainter.RenderHint.Antialiasing)
        p.setRenderHint(QPainter.RenderHint.SmoothPixmapTransform)
        ring = {"yes": QColor(t.green), "no": QColor(t.red)}.get(self.answer)
        circle = QRectF(6, 4, 96, 96)
        draw_circle(p, circle, self.win.cache.get(self.face), t, ring)
        if self.answer:
            p.setPen(Qt.PenStyle.NoPen)
            p.setBrush(ring)
            mark = QRectF(circle.right() - 24, circle.top(), 24, 24)
            p.drawEllipse(mark)
            p.setPen(QColor("white"))
            p.drawText(mark, Qt.AlignmentFlag.AlignCenter, "✓" if self.answer == "yes" else "✕")
        small = QFont(self.font())
        small.setPointSizeF(max(8.0, small.pointSizeF() - 2))
        p.setFont(small)
        p.setPen(QColor(t.secondary))
        p.drawText(QRectF(0, 104, 108, 18), Qt.AlignmentFlag.AlignCenter,
                   {"yes": "Yes", "no": "Not them", "": ""}[self.answer])
        p.end()


class ReviewDialog(QDialog):
    """"Is this <name>?" — the suggestions for one person, answered a tile at a time."""

    def __init__(self, win: "PeopleWindow", person: people.Person, found: list[tuple[people.Face, float]]) -> None:
        super().__init__(win)
        self.win, self.person = win, person
        self.theme, self.cache = win.theme, win.cache
        self.setWindowTitle(f"Review — {person.label}")
        self.resize(720, 560)
        v = QVBoxLayout(self)
        v.setContentsMargins(18, 16, 18, 14)
        head = QHBoxLayout()
        title = QLabel(f"Is this {person.name or 'the same person'}?")
        title.setObjectName("SheetTitle")
        head.addWidget(title)
        head.addStretch(1)
        v.addLayout(head)
        hint = QLabel("Click a face once for Yes, again for Not them, again to leave it for later. What you answer "
                      "stands: a Yes joins them for good, a Not them is never suggested for them again.")
        hint.setObjectName("SheetSub")
        hint.setWordWrap(True)
        v.addWidget(hint)
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.Shape.NoFrame)
        body = QWidget()
        flow = FlowLayout(body, 8)
        self.tiles = [FaceTile(f, s, self) for f, s in found]
        for t in self.tiles:
            t.changed.connect(self._count)
            flow.addWidget(t)
        scroll.setWidget(body)
        v.addWidget(scroll, 1)
        bar = QHBoxLayout()
        self.count = QLabel("")
        self.count.setObjectName("SheetSub")
        bar.addWidget(self.count, 1)
        all_yes = QPushButton("Yes to All")
        all_yes.clicked.connect(lambda: self._all("yes"))
        none = QPushButton("Clear")
        none.clicked.connect(lambda: self._all(""))
        cancel = QPushButton("Cancel")
        cancel.clicked.connect(self.reject)
        done = QPushButton("Done")
        done.setDefault(True)
        done.clicked.connect(self._done)
        for b in (all_yes, none, cancel, done):
            bar.addWidget(b)
        v.addLayout(bar)
        win.bridge.face.connect(lambda _id, _img: self.update())
        self._count()

    def _all(self, answer: str) -> None:
        for t in self.tiles:
            t.answer = answer
            t.update()
        self._count()

    def _count(self) -> None:
        yes = sum(1 for t in self.tiles if t.answer == "yes")
        no = sum(1 for t in self.tiles if t.answer == "no")
        self.count.setText(f"{yes:,} yes · {no:,} not them · {len(self.tiles) - yes - no:,} for later")

    def _done(self) -> None:
        yes = [t.face.id for t in self.tiles if t.answer == "yes"]
        no = [t.face.id for t in self.tiles if t.answer == "no"]
        if yes:
            self.win.store.confirm(yes, self.person.id)
        if no:
            self.win.store.reject(no, self.person.id)
        self.accept()


class KeyPhotoDialog(QDialog):
    """Choose Key Photo…: the person's faces; a click makes one the face that stands for them."""

    def __init__(self, win: "PeopleWindow", person: people.Person) -> None:
        super().__init__(win)
        self.win, self.theme, self.cache = win, win.theme, win.cache
        self.setWindowTitle(f"Key Photo — {person.label}")
        self.resize(680, 500)
        v = QVBoxLayout(self)
        v.setContentsMargins(18, 16, 18, 14)
        hint = QLabel("Click the face that should stand for them.")
        hint.setObjectName("SheetSub")
        v.addWidget(hint)
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.Shape.NoFrame)
        body = QWidget()
        flow = FlowLayout(body, 8)
        for f in win.store.faces_of(person.id)[:120]:
            t = FaceTile(f, 1.0, self)
            t.setToolTip(os.path.basename(f.path))
            t.mousePressEvent = lambda _e, f=f: (win.store.set_key(person.id, f.id), self.accept())   # type: ignore[method-assign]
            flow.addWidget(t)
        scroll.setWidget(body)
        v.addWidget(scroll, 1)
        win.bridge.face.connect(lambda _id, _img: self.update())


class SameDialog(QDialog):
    """"Same Person?" — pairs that may be one, a pair at a time."""

    def __init__(self, win: "PeopleWindow", pairs: list) -> None:
        super().__init__(win)
        self.win, self.theme, self.cache = win, win.theme, win.cache
        self.pairs = pairs
        self.at = 0
        self.setWindowTitle("Same Person?")
        self.setFixedSize(460, 330)
        v = QVBoxLayout(self)
        v.setContentsMargins(22, 18, 22, 16)
        self.title = QLabel("Are these the same person?")
        self.title.setObjectName("SheetTitle")
        v.addWidget(self.title, 0, Qt.AlignmentFlag.AlignHCenter)
        self.picture = QLabel()
        self.picture.setFixedSize(400, 170)
        v.addWidget(self.picture, 0, Qt.AlignmentFlag.AlignHCenter)
        self.names = QLabel("")
        self.names.setObjectName("SheetSub")
        v.addWidget(self.names, 0, Qt.AlignmentFlag.AlignHCenter)
        bar = QHBoxLayout()
        later = QPushButton("Not Sure")
        later.clicked.connect(self._next)
        different = QPushButton("Different People")
        different.clicked.connect(self._different)
        same = QPushButton("Same Person")
        same.setDefault(True)
        same.clicked.connect(self._same)
        bar.addWidget(later)
        bar.addStretch(1)
        bar.addWidget(different)
        bar.addWidget(same)
        v.addLayout(bar)
        win.bridge.face.connect(lambda _id, _img: self._draw())
        self._draw()

    def _draw(self) -> None:
        if self.at >= len(self.pairs):
            self.accept()
            return
        a, b, how = self.pairs[self.at]
        pm = QPixmap(400, 170)
        pm.fill(Qt.GlobalColor.transparent)
        p = QPainter(pm)
        p.setRenderHint(QPainter.RenderHint.Antialiasing)
        p.setRenderHint(QPainter.RenderHint.SmoothPixmapTransform)
        for i, person in enumerate((a, b)):
            draw_circle(p, QRectF(40 + i * 180, 14, 140, 140), self.cache.get(self.win.store.key_face(person.id)), self.theme)
        p.end()
        self.picture.setPixmap(pm)
        self.names.setText(f"{a.label} ({a.photos:,})   ·   {b.label} ({b.photos:,})   ·   {round(how * 100)}% alike   "
                           f"·   {self.at + 1} of {len(self.pairs)}")

    def _next(self) -> None:
        self.at += 1
        self._draw()

    def _same(self) -> None:
        a, b, _how = self.pairs[self.at]
        keep, other = (a, b) if (a.name or not b.name) else (b, a)
        self.win.store.merge(keep.id, [other.id])
        gone = other.id
        self.pairs = [x for i, x in enumerate(self.pairs) if i <= self.at or gone not in (x[0].id, x[1].id)]
        self._next()

    def _different(self) -> None:
        a, b, _how = self.pairs[self.at]
        self.win.store.keep_apart(a.id, b.id)
        self._next()


class PeopleWindow(QWidget):
    def __init__(self, hooks: PeopleHooks, theme, parent=None, store: people.Store | None = None) -> None:
        super().__init__(parent, Qt.WindowType.Window)
        self.setAttribute(Qt.WidgetAttribute.WA_DeleteOnClose)
        self.setWindowTitle("People")
        self.hooks, self.theme = hooks, theme
        self.store = store or people.shared()
        self.bridge = _Bridge()
        self.cache = FaceCache(self.bridge)
        self.tiles: list[PersonTile] = []
        self.selected: list[int] = []
        self.show_hidden = False
        self.stop = threading.Event()
        self.scanning = False
        self.resize(940, 700)
        self.bridge.face.connect(lambda _id, _img: self._repaint.start())
        self.bridge.progress.connect(lambda line: self.status.setText(line))
        self.bridge.scanned.connect(self._scanned)
        self.bridge.ready.connect(self._models_ready)
        self._repaint = QTimer(self)
        self._repaint.setSingleShot(True)
        self._repaint.setInterval(80)
        self._repaint.timeout.connect(lambda: [t.update() for t in self.tiles])
        self._refill = QTimer(self)
        self._refill.setSingleShot(True)
        self._refill.setInterval(120)
        self._refill.timeout.connect(self.fill)
        self.bridge.changed.connect(self._refill.start)
        self.store.changed = self._store_changed

        v = QVBoxLayout(self)
        v.setContentsMargins(0, 0, 0, 0)
        v.setSpacing(0)
        top = QFrame()
        top.setObjectName("PaneHeader")
        th = QHBoxLayout(top)
        th.setContentsMargins(16, 10, 12, 10)
        title = QLabel("People")
        title.setObjectName("SheetTitle")
        th.addWidget(title)
        th.addSpacing(10)
        self.find = QLineEdit()
        self.find.setObjectName("Search")
        self.find.setPlaceholderText("Find a name")
        self.find.setClearButtonEnabled(True)
        self.find.setAccessibleName("Find a name")
        self.find.setMaximumWidth(240)
        self.find.textChanged.connect(lambda _t: self.fill())
        th.addWidget(self.find)
        th.addStretch(1)
        self.same_btn = QPushButton("Same Person?")
        self.same_btn.setToolTip("People who may be one — say which are, and which aren't")
        self.same_btn.clicked.connect(self.review_same)
        th.addWidget(self.same_btn)
        self.merge_btn = QPushButton("Merge")
        self.merge_btn.setToolTip("The people selected are one person")
        self.merge_btn.clicked.connect(self.merge_selected)
        th.addWidget(self.merge_btn)
        self.find_btn = QToolButton()
        self.find_btn.setText("Find People ▾")
        self.find_btn.setObjectName("DupMore")
        self.find_btn.setPopupMode(QToolButton.ToolButtonPopupMode.InstantPopup)
        self.find_menu = QMenu(self.find_btn)
        self.find_menu.aboutToShow.connect(self._fill_find_menu)
        self.find_btn.setMenu(self.find_menu)
        th.addWidget(self.find_btn)
        more = QToolButton()
        more.setText("•••")
        more.setObjectName("DupMore")
        more.setPopupMode(QToolButton.ToolButtonPopupMode.InstantPopup)
        mm = QMenu(more)
        self.hidden_act = mm.addAction("Show Hidden People", self._toggle_hidden)
        self.hidden_act.setCheckable(True)
        mm.addAction("Group Again", self.regroup).setToolTip("Looks once more for faces that belong together")
        mm.addSeparator()
        mm.addAction("Forget All Face Data…", self.forget_all)
        mm.setToolTipsVisible(True)
        more.setMenu(mm)
        th.addWidget(more)
        v.addWidget(top)
        self.setStyleSheet(f"QToolButton#DupMore {{ border: 1px solid {theme.button_border}; border-radius: 6px; "
                           f"padding: 5px 10px; background: {theme.button}; }}"
                           "QToolButton#DupMore::menu-indicator { image: none; width: 0; }")
        self.scroll = QScrollArea()
        self.scroll.setWidgetResizable(True)
        self.scroll.setFrameShape(QFrame.Shape.NoFrame)
        self.body = QWidget()
        self.flow = FlowLayout(self.body, 6)
        self.flow.setContentsMargins(16, 14, 16, 14)
        self.scroll.setWidget(self.body)
        v.addWidget(self.scroll, 1)
        self.empty = QLabel("")
        self.empty.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.empty.setWordWrap(True)
        self.empty.setTextFormat(Qt.TextFormat.RichText)
        v.addWidget(self.empty, 1)
        bar = QFrame()
        bar.setObjectName("ActionBar")
        bh = QHBoxLayout(bar)
        bh.setContentsMargins(16, 8, 16, 8)
        self.status = QLabel("")
        self.status.setObjectName("Summary")
        bh.addWidget(self.status, 1)
        self.busy = QProgressBar()
        self.busy.setFixedWidth(160)
        self.busy.setVisible(False)
        bh.addWidget(self.busy)
        self.stop_btn = QPushButton("Stop")
        self.stop_btn.setVisible(False)
        self.stop_btn.clicked.connect(lambda: self.stop.set())
        bh.addWidget(self.stop_btn)
        private = QLabel("Found and kept on this Mac only")
        private.setObjectName("SheetSub")
        private.setToolTip("Faces are found on this Mac, and what's known about them stays in the app's own folder "
                           "here — nothing is uploaded, and the app never names anyone itself.")
        bh.addWidget(private)
        v.addWidget(bar)
        self.fill()

    def _store_changed(self) -> None:
        try:
            self.bridge.changed.emit()
        except RuntimeError:                 # the window has gone
            pass

    # ------------------------------------------------------------------ the grid
    def fill(self) -> None:
        want = self.find.text().casefold().strip()
        found = [p for p in self.store.people(hidden=self.show_hidden) if not want or want in p.name.casefold()]
        while self.flow.count():
            item = self.flow.takeAt(0)
            if item.widget() is not None:
                item.widget().setParent(None)
                item.widget().deleteLater()
        self.tiles = []
        alive = {p.id for p in found}
        self.selected = [i for i in self.selected if i in alive]
        for person in found:
            t = PersonTile(person, self)
            t.selected = person.id in self.selected
            t.clicked.connect(self._clicked)
            t.opened.connect(lambda t: self.hooks.show(t.person.id))
            t.named.connect(lambda t: self.rename(t.person))
            t.menu.connect(self._menu)
            self.flow.addWidget(t)
            self.tiles.append(t)
        self.body.updateGeometry()
        counts = self.store.counts()
        nothing = not found
        self.scroll.setVisible(not nothing)
        self.empty.setVisible(nothing)
        if nothing:
            if want:
                title, detail = "No One by That Name", "Names are the ones you've given — click “Add Name” under a face."
            elif counts["photos"] == 0:
                title = "Find the People in Your Photos"
                detail = ("Find People looks at your photos on this Mac, finds the faces, and groups the ones that "
                          "are the same person — like People in Photos. You give them names.<br>Nothing leaves the "
                          "Mac.")
            else:
                title = "No People Yet"
                detail = (f"{counts['photos']:,} photos looked at, {counts['faces']:,} faces found — none of them "
                          f"often enough to be a person yet (it takes {people.MIN_GROUP}). Find People in more photos.")
            c = self.theme.secondary
            self.empty.setText(f'<div style="font-size:18px; font-weight:600; color:{c};">{title}</div>'
                               f'<div style="font-size:13px; color:{c}; margin-top:8px;">{detail}</div>')
        if not self.scanning:
            named = sum(1 for p in found if p.name)
            self.status.setText(f"{len(found):,} {'person' if len(found) == 1 else 'people'} · {named:,} named · "
                                f"{counts['faces']:,} faces in {counts['photos']:,} photos" if counts["photos"] else "")
        self._buttons()

    def _buttons(self) -> None:
        n = len(self.selected)
        self.merge_btn.setVisible(n >= 2)
        self.merge_btn.setText(f"Merge {n} People")
        self.same_btn.setVisible(len(self.store.people()) >= 2)

    def _clicked(self, tile: PersonTile, modifiers) -> None:
        pid = tile.person.id
        if modifiers & (Qt.KeyboardModifier.ControlModifier | Qt.KeyboardModifier.MetaModifier
                        | Qt.KeyboardModifier.ShiftModifier):
            if pid in self.selected:
                self.selected.remove(pid)
            else:
                self.selected.append(pid)
        else:
            self.selected = [pid]
        for t in self.tiles:
            t.selected = t.person.id in self.selected
            t.update()
        self._buttons()

    def _toggle_hidden(self) -> None:
        self.show_hidden = self.hidden_act.isChecked()
        self.fill()

    def _menu(self, tile: PersonTile, pos) -> None:
        person = tile.person
        if person.id not in self.selected:
            self._clicked(tile, Qt.KeyboardModifier.NoModifier)
        menu = QMenu(self)
        menu.addAction("Show Photos", lambda: self.hooks.show(person.id))
        menu.addAction("Rename…" if person.name else "Add Name…", lambda: self.rename(person))
        if len(self.selected) >= 2:
            menu.addAction(f"Merge {len(self.selected)} People", self.merge_selected)
        menu.addSeparator()
        menu.addAction("Review Suggestions…", lambda: self.review(person))
        menu.addAction("Choose Key Photo…", lambda: (KeyPhotoDialog(self, person).exec(), self.cache.asked.clear()))
        menu.addAction("Unfavorite" if person.favorite else "Favorite",
                       lambda: self.store.set_flag(person.id, "favorite", not person.favorite))
        menu.addAction("Unhide" if person.hidden else "Hide",
                       lambda: self.store.set_flag(person.id, "hidden", not person.hidden))
        if person.name and self.hooks.tag is not None:
            menu.addSeparator()
            menu.addAction(f"Tag Their Photos “{person.name}”", lambda: self.tag(person))
        menu.addSeparator()
        menu.addAction("Not a Person", lambda: self.not_a_person(person))
        menu.exec(pos)
        menu.deleteLater()

    # ------------------------------------------------------------------ what the person says
    def rename(self, person: people.Person) -> None:
        name, ok = QInputDialog.getText(self, "Name", "Who is this?", text=person.name)
        name = " ".join(name.split())
        if not ok or name == person.name:
            return
        other = self.store.find(name) if name else None
        if other is not None and other.id != person.id:
            box = QMessageBox(self)
            box.setWindowTitle("Same Person?")
            box.setText(f"There's already a {name}.")
            box.setInformativeText(f"Merge these {person.photos:,} photo{'s' if person.photos != 1 else ''} with "
                                   f"{name}'s {other.photos:,}? They become one person.")
            go = box.addButton("Merge", QMessageBox.ButtonRole.AcceptRole)
            box.addButton(QMessageBox.StandardButton.Cancel)
            box.setDefaultButton(go)
            box.exec()
            if box.clickedButton() is not go:
                return
        self.store.rename(person.id, name)
        self._say(f"Named {name}." if name else "Name removed.")

    def merge_selected(self) -> None:
        chosen = [p for p in self.store.people(hidden=True) if p.id in self.selected]
        if len(chosen) < 2:
            return
        keep = next((p for p in chosen if p.name), max(chosen, key=lambda p: p.photos))
        names = sorted({p.name for p in chosen if p.name})
        box = QMessageBox(self)
        box.setWindowTitle("Merge People")
        box.setText(f"Merge these {len(chosen)} people into one?")
        box.setInformativeText((f"They'll all be {keep.name}. " if keep.name else "") +
                               ("(Two of them have different names — the others' names are dropped.) "
                                if len(names) > 1 else "") + "This can't be undone.")
        go = box.addButton("Merge", QMessageBox.ButtonRole.AcceptRole)
        box.addButton(QMessageBox.StandardButton.Cancel)
        box.setDefaultButton(go)
        box.exec()
        if box.clickedButton() is not go:
            return
        self.store.merge(keep.id, [p.id for p in chosen if p.id != keep.id])
        self.selected = [keep.id]
        self._say(f"Merged {len(chosen)} people.")

    def review(self, person: people.Person) -> None:
        found = self.store.suggestions(person.id)
        if not found:
            self._say(f"Nothing more to suggest for {person.label} just now.")
            return
        ReviewDialog(self, person, found).exec()

    def review_same(self) -> None:
        pairs = self.store.merge_candidates()
        if not pairs:
            self._say("No two people here look like one.")
            return
        SameDialog(self, pairs).exec()
        self.fill()

    def not_a_person(self, person: people.Person) -> None:
        if QMessageBox.question(self, "Not a Person", f"Take this group of {person.faces:,} faces apart? "
                                + (f"The name “{person.name}” goes with it." if person.name else "")) \
                != QMessageBox.StandardButton.Yes:
            return
        self.store.ungroup(person.id)

    def tag(self, person: people.Person) -> None:
        photos = self.store.photos_of(person.id)
        if photos and self.hooks.tag is not None:
            self.hooks.tag(photos, person.name)
            self._say(f"Tagged {len(photos):,} photo{'s' if len(photos) != 1 else ''} “{person.name}”.")

    def regroup(self) -> None:
        out = self.store.cluster()
        self._say(f"{out['joined']:,} faces joined people, {out['new_people']:,} new "
                  f"{'person' if out['new_people'] == 1 else 'people'}.")

    def forget_all(self) -> None:
        counts = self.store.counts()
        box = QMessageBox(self)
        box.setIcon(QMessageBox.Icon.Warning)
        box.setWindowTitle("Forget All Face Data")
        box.setText("Delete everything People knows?")
        box.setInformativeText(f"{counts['faces']:,} faces, {counts['people']:,} people and {counts['named']:,} names "
                               "are deleted from this Mac. Your photos aren't touched. This can't be undone.")
        go = box.addButton("Forget Everything", QMessageBox.ButtonRole.DestructiveRole)
        box.addButton(QMessageBox.StandardButton.Cancel)
        box.exec()
        if box.clickedButton() is go:
            self.stop.set()
            self.store.forget_all()
            self.cache.forget()
            self._say("All face data was deleted.")

    def _say(self, line: str) -> None:
        self.status.setText(line)
        if self.hooks.note is not None:
            self.hooks.note(line)

    # ------------------------------------------------------------------ finding
    def _fill_find_menu(self) -> None:
        m = self.find_menu
        m.clear()
        folder = self.hooks.folder()
        if folder:
            m.addAction(f"In “{os.path.basename(folder.rstrip('/')) or folder}” and Its Folders",
                        lambda: self.find_people([folder]))
        for drive in self.hooks.drives():
            m.addAction(f"On “{os.path.basename(drive.rstrip('/')) or drive}” — the Whole Drive",
                        lambda drive=drive: self.find_people([drive]))
        if m.isEmpty():
            a = m.addAction("Open a folder or connect the drive first")
            a.setEnabled(False)

    def find_people(self, folders: list[str]) -> None:
        if self.scanning:
            return
        if not faces.runtime_ok():
            QMessageBox.warning(self, "Find People", "People needs the onnxruntime package, which isn't in this copy "
                                "of the app.\n\nOpen “Photo Browser for Mac.command” again (it installs it), or run:\n"
                                "mac/.venv/bin/pip install onnxruntime\n\nthen build the app again.")
            return
        if not faces.installed():
            mb = faces.download_size() / 1e6
            box = QMessageBox(self)
            box.setWindowTitle("Find People")
            box.setText("Find the people in your photos?")
            box.setInformativeText(
                "The app looks at your photos on this Mac, finds the faces, and groups the ones that are the same "
                "person. You name them; the app never does.\n\n"
                f"It needs two small models from OpenCV first — a one-time download of {mb:.0f} MB. That download "
                "is the only thing that uses the network: no photo, face or name ever leaves this Mac, and "
                "••• ▸ Forget All Face Data deletes all of it.")
            go = box.addButton("Download and Start", QMessageBox.ButtonRole.AcceptRole)
            box.addButton("Not Now", QMessageBox.ButtonRole.RejectRole)
            box.setDefaultButton(go)
            box.exec()
            if box.clickedButton() is not go:
                return
        self._begin()
        bridge, stop = self.bridge, self.stop
        self._pending = folders

        def fetch() -> None:
            try:
                faces.download(lambda line: bridge.progress.emit(line), stop.is_set)
                ok, why = True, ""
            except OSError as e:
                ok, why = False, str(e)
            try:
                bridge.ready.emit(ok, why)
            except RuntimeError:
                pass
        threading.Thread(target=fetch, name="face-models", daemon=True).start()

    def _begin(self) -> None:
        self.scanning = True
        self.stop = threading.Event()
        self.find_btn.setEnabled(False)
        self.stop_btn.setVisible(True)
        self.busy.setVisible(True)
        self.busy.setRange(0, 0)
        self.status.setText("Getting ready…")

    def _models_ready(self, ok: bool, why: str) -> None:
        if not ok:
            self._scanned(None, why)
            return
        folders, store, bridge, stop = self._pending, self.store, self.bridge, self.stop
        self.status.setText("Looking for photos…")

        def work() -> None:
            out, why = None, ""
            try:
                state = {"shown": 0}

                def progress(done: int, total: int, found: int) -> None:
                    if done - state["shown"] >= 5 or done == total:
                        state["shown"] = done
                        bridge.progress.emit(f"Looking at photos… {done:,} of {total:,} · {found:,} faces")
                out = faces.scan(store, folders, progress, stop.is_set)
                bridge.progress.emit("Grouping faces…")
                out.update(store.cluster(lambda line: bridge.progress.emit(line), stop.is_set))
            except faces.Missing as e:
                why = f"People isn't ready: {e}."
            except Exception as e:  # noqa: BLE001 — whatever went wrong, the window is told
                why = f"Finding people stopped: {e or type(e).__name__}"
            try:
                bridge.scanned.emit(out, why)
            except RuntimeError:
                pass
        threading.Thread(target=work, name="find-people", daemon=True).start()

    def _scanned(self, out, why: str) -> None:
        self.scanning = False
        self.find_btn.setEnabled(True)
        self.stop_btn.setVisible(False)
        self.busy.setVisible(False)
        self.fill()
        if why:
            self.status.setText(why)
        elif out is not None:
            stopped = " (stopped — Find People again carries on)" if self.stop.is_set() else ""
            self._say(f"Looked at {out['photos']:,} photo{'s' if out['photos'] != 1 else ''}: {out['faces']:,} faces, "
                      f"{out.get('new_people', 0):,} new {'person' if out.get('new_people', 0) == 1 else 'people'}, "
                      f"{out.get('joined', 0):,} faces joined people already here{stopped}."
                      if out["photos"] else "Every photo here has been looked at already.")

    def closeEvent(self, event) -> None:  # noqa: N802
        self.stop.set()
        self.store.changed = lambda: None
        super().closeEvent(event)
