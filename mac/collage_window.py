"""Photo Browser for Mac's collage window (collage.py does the arithmetic).

Select two to nine photos ▸ right-click ▸ Make Collage… (or Photos ▸ Make Collage…). The collage on the left:
**drag a photo onto another to swap them, drag inside its own cell to slide it, scroll over it to zoom**
(double-click puts it back). On the right: every layout for that many photos, drawn small; the shape — square,
portrait and landscape ratios, stories, banners, print sizes, screens; the size in pixels; spacing, margin and
rounded corners; the background colour (or the first photo, blurred); JPEG, HEIC or PNG. Photos can be added
(up to nine) and removed (right-click one).

**Save** writes "Collage <date>.jpg" beside the first photo; **Save and Edit…** then opens it in the photo
editor (text, filters, frames). The collage takes the oldest photo's date and place (collage.py) and — through
`on_done(written, sources, edit)` — every photo's tags, plus "collage".

The preview is drawn on a worker thread from copies of the photos at 1,600 px; saving reads them again at
full size.
"""
from __future__ import annotations

import os
import random
import threading
from typing import Callable

from PIL import Image
from PySide6.QtCore import QObject, QPointF, QRectF, QSize, Qt, Signal
from PySide6.QtGui import QColor, QCursor, QIcon, QImage, QPainter, QPen, QPixmap
from PySide6.QtWidgets import (QButtonGroup, QCheckBox, QComboBox, QDialog, QFileDialog, QGridLayout, QHBoxLayout,
                               QLabel, QMenu, QMessageBox, QProgressBar, QPushButton, QToolButton, QVBoxLayout, QWidget)

import collage
from photo_editor_window import SliderRow, Swatches, _head, _plain, _scrolling, _seg
from photo_text import SWATCHES

PREVIEW = 1100
LOADED = 1600
ICON = 58


def _qimage(im: Image.Image) -> QImage:
    rgb = im.convert("RGB")
    data = rgb.tobytes()
    return QImage(data, rgb.width, rgb.height, rgb.width * 3, QImage.Format.Format_RGB888).copy()


def layout_icon(layout: collage.Layout, ratio: float, colour: QColor) -> QIcon:
    w, h = (ICON, max(8, round(ICON / ratio))) if ratio >= 1 else (max(8, round(ICON * ratio)), ICON)
    pix = QPixmap(ICON * 2, ICON * 2)
    pix.setDevicePixelRatio(2.0)
    pix.fill(Qt.GlobalColor.transparent)
    p = QPainter(pix)
    p.setRenderHint(QPainter.RenderHint.Antialiasing)
    p.setPen(Qt.PenStyle.NoPen)
    p.setBrush(colour)
    ox, oy = (ICON - w) / 2, (ICON - h) / 2
    for x, y, cw, ch in layout.cells:
        p.drawRoundedRect(QRectF(ox + x * w + 1, oy + y * h + 1, cw * w - 2, ch * h - 2), 1.5, 1.5)
    p.end()
    return QIcon(pix)


class _Signals(QObject):
    loaded = Signal(int, object, str)           # index, small photo or None, why
    drawn = Signal(int, object)                 # generation, QImage
    progress = Signal(float)
    saved = Signal(str, str)


class _Board(QWidget):
    """The collage, and the mouse on it."""

    def __init__(self, win: "CollageWindow") -> None:
        super().__init__()
        self.win = win
        self.pix: QPixmap | None = None
        self.down: tuple[int, QPointF, collage.View] | None = None
        self.over = -1
        self.setMinimumSize(420, 360)
        self.setMouseTracking(True)

    def target(self) -> QRectF:
        ratio = self.win.design.ratio
        m = 20.0
        w = min(self.width() - 2 * m, (self.height() - 2 * m) * ratio)
        h = w / ratio
        return QRectF((self.width() - w) / 2, (self.height() - h) / 2, w, h)

    def boxes(self) -> list[QRectF]:
        t = self.target()
        d = self.win.design
        return [QRectF(t.x() + l, t.y() + tp, r - l, b - tp) for l, tp, r, b in
                collage.cell_boxes(d.layout, max(1, int(t.width())), max(1, int(t.height())), d.margin, d.spacing)]

    def cell_at(self, pos: QPointF) -> int:
        for i, r in enumerate(self.boxes()):
            if r.contains(pos) and i < len(self.win.paths):
                return i
        return -1

    def mousePressEvent(self, e) -> None:  # noqa: N802
        if self.win.saving:
            return
        i = self.cell_at(e.position())
        if e.button() == Qt.MouseButton.RightButton and i >= 0:
            menu = QMenu(self)
            menu.addAction("Remove from the Collage", lambda: self.win.remove(i)).setEnabled(
                len(self.win.paths) > collage.MIN_PHOTOS)
            menu.addAction("Reset Position", lambda: self.win.reset_view(i))
            menu.exec(e.globalPosition().toPoint())
        elif e.button() == Qt.MouseButton.LeftButton and i >= 0:
            v = self.win.design.views[i]
            self.down = (i, e.position(), collage.View(v.zoom, v.x, v.y))
            self.setCursor(QCursor(Qt.CursorShape.ClosedHandCursor))

    def mouseMoveEvent(self, e) -> None:  # noqa: N802
        if self.down is None:
            self.over = self.cell_at(e.position())
            self.setCursor(QCursor(Qt.CursorShape.OpenHandCursor if self.over >= 0 else Qt.CursorShape.ArrowCursor))
            return
        i, start, was = self.down
        self.over = self.cell_at(e.position())
        if self.over == i:                                  # sliding the photo inside its own cell
            self.win.slide(i, was, e.position() - start, self.boxes()[i])
        self.update()

    def mouseReleaseEvent(self, e) -> None:  # noqa: N802
        if self.down is not None:
            i, _start, was = self.down
            j = self.cell_at(e.position())
            self.down = None
            if j >= 0 and j != i:
                self.win.design.views[i] = was              # the slide on the way there doesn't count
                self.win.swap(i, j)
            self.setCursor(QCursor(Qt.CursorShape.OpenHandCursor))
            self.update()

    def mouseDoubleClickEvent(self, e) -> None:  # noqa: N802
        i = self.cell_at(e.position())
        if i >= 0 and not self.win.saving:
            self.win.reset_view(i)

    def wheelEvent(self, e) -> None:  # noqa: N802
        i = self.cell_at(e.position())
        if i >= 0 and not self.win.saving:
            self.win.zoom(i, 1.0 + e.angleDelta().y() / 900.0)

    def paintEvent(self, _e) -> None:  # noqa: N802
        p = QPainter(self)
        p.fillRect(self.rect(), QColor(20, 20, 22))
        t = self.target()
        if self.pix is None:
            p.setPen(QColor(150, 150, 155))
            p.drawText(self.rect(), Qt.AlignmentFlag.AlignCenter, "Reading the photos…")
            return
        p.setRenderHint(QPainter.RenderHint.SmoothPixmapTransform)
        p.drawPixmap(t, self.pix, QRectF(self.pix.rect()))
        if self.down is not None and self.over >= 0 and self.over != self.down[0]:
            p.setPen(QPen(QColor(10, 132, 255), 3))
            p.setBrush(QColor(10, 132, 255, 50))
            p.drawRect(self.boxes()[self.over])


class CollageWindow(QDialog):
    """`on_done(written, sources, edit)` on the UI thread after a save: the collage's path, the photos in it,
    and whether the photo editor was asked for."""

    def __init__(self, parent: QWidget | None, paths: list[str], settings,
                 on_done: Callable[[str, list[str], bool], None]) -> None:
        super().__init__(parent)
        self.paths = [p for p in paths if collage.can_use(p)][:collage.MAX_PHOTOS]
        self.settings, self.on_done = settings, on_done
        self.photos: list[Image.Image | None] = [None] * len(self.paths)
        self.gen = 0
        self.saving = False
        self._job = None
        self._cv = threading.Condition()
        self._alive = True
        self._sig = _Signals()
        self._sig.loaded.connect(self._loaded)
        self._sig.drawn.connect(self._drawn)
        self._sig.progress.connect(lambda f: self.bar.setValue(int(f * 100)))
        self._sig.saved.connect(self._saved)
        ratio = self._setting_float("collage/ratio", 1.0)
        self.design = collage.Design(collage.layouts(len(self.paths))[0], ratio,
                                     self._setting_float("collage/margin", 2.0), self._setting_float("collage/spacing", 1.5),
                                     self._setting_float("collage/corner", 0.0),
                                     tuple(QColor(str(settings.value("collage/colour", "#ffffff"))).getRgb()[:3]),
                                     str(settings.value("collage/blur", "false")) == "true",
                                     [collage.View() for _ in self.paths])
        self.setWindowTitle("Make Collage")
        self.setWindowFlag(Qt.WindowType.WindowMaximizeButtonHint, True)
        self.resize(1240, 820)
        self._build()
        threading.Thread(target=self._draw_loop, daemon=True).start()
        self._load(range(len(self.paths)))

    def _setting_float(self, key: str, default: float) -> float:
        try:
            return float(self.settings.value(key, default))
        except (TypeError, ValueError):
            return default

    # ------------------------------------------------------------------ building
    def _build(self) -> None:
        root = QHBoxLayout(self)
        root.setContentsMargins(0, 0, 0, 0)
        root.setSpacing(0)
        left = QVBoxLayout()
        self.board = _Board(self)
        left.addWidget(self.board, 1)
        row = QHBoxLayout()
        row.setContentsMargins(12, 8, 12, 10)
        self.shuffle_btn = _plain("Shuffle", self.shuffle, "The photos in another order")
        self.add_btn = _plain("Add Photos…", self.add_photos, "Up to nine")
        row.addWidget(self.shuffle_btn)
        row.addWidget(self.add_btn)
        self.note = QLabel("Drag a photo onto another to swap them; drag inside its cell to slide it; scroll to zoom.",
                           objectName="SheetSub")
        row.addWidget(self.note, 1)
        self.bar = QProgressBar()
        self.bar.setRange(0, 100)
        self.bar.setFixedWidth(160)
        self.bar.setTextVisible(False)
        self.bar.hide()
        row.addWidget(self.bar)
        left.addLayout(row)
        root.addLayout(left, 1)

        side = self.side = QWidget()
        side.setFixedWidth(400)
        s = QVBoxLayout(side)
        s.setContentsMargins(12, 12, 12, 12)
        inner = QWidget()
        lay = QVBoxLayout(inner)
        lay.setContentsMargins(0, 0, 8, 0)
        self.count = QLabel("", objectName="SheetTitle")
        lay.addWidget(self.count)
        lay.addWidget(_head("Shape"))
        self.shape = QComboBox()
        self.shape.setMaxVisibleItems(30)
        group = None
        for g, name, ratio in collage.SHAPES:
            if g != group:
                group = g
                self.shape.addItem(f"— {g} —", None)
                self.shape.model().item(self.shape.count() - 1).setEnabled(False)
            self.shape.addItem(name, ratio)
        best = min(range(self.shape.count()), key=lambda i: abs((self.shape.itemData(i) or 99) - self.design.ratio))
        self.shape.setCurrentIndex(best)
        self.shape.activated.connect(self._shape_changed)
        lay.addWidget(self.shape)
        lay.addWidget(_head("Layout"))
        self.layout_holder = QWidget()
        self.layout_grid = QGridLayout(self.layout_holder)
        self.layout_grid.setContentsMargins(0, 0, 0, 0)
        self.layout_grid.setSpacing(3)
        self.layout_group = QButtonGroup(self)
        lay.addWidget(self.layout_holder)
        self.spacing = SliderRow("Spacing", 0, 80)
        self.margin = SliderRow("Margin", 0, 120)
        self.corner = SliderRow("Rounded Corners", 0, 120)
        for r, key in ((self.spacing, "spacing"), (self.margin, "margin"), (self.corner, "corner")):
            r.set(getattr(self.design, key) * 10)
            r._show = lambda r=r: r.number.setText(f"{r.slider.value() / 10:.1f}%")
            r._show()
            r.moved.connect(lambda v, _resting, key=key: self._set(key, v / 10.0))
            lay.addWidget(r)
        lay.addWidget(_head("Background"))
        self.colour = Swatches(SWATCHES)
        self.colour.show_current(QColor(*self.design.colour).name())
        self.colour.picked.connect(lambda c: (self.blur.setChecked(False), self._set("colour", tuple(QColor(c).getRgb()[:3]))))
        lay.addWidget(self.colour)
        self.blur = QCheckBox("The first photo, blurred")
        self.blur.setChecked(self.design.blur_back)
        self.blur.toggled.connect(lambda on: self._set("blur_back", bool(on)))
        lay.addWidget(self.blur)
        lay.addWidget(_head("Size"))
        self.size = QComboBox()
        self.size.addItem("As large as stays sharp", 0)
        for px in collage.SIZES:
            self.size.addItem(f"{px:,} px on the long side", px)
        self.size.setCurrentIndex(max(0, self.size.findData(int(self._setting_float("collage/size", 0)))))
        self.size.activated.connect(lambda _i: self._show_size())
        lay.addWidget(self.size)
        self.size_note = QLabel("", objectName="SheetSub")
        lay.addWidget(self.size_note)
        lay.addWidget(_head("Format"))
        row = QHBoxLayout()
        self.format_group = QButtonGroup(self)
        was = str(self.settings.value("collage/format", "JPEG"))
        for name, _ext in collage.FORMATS:
            b = _seg(name, self.format_group, key=name)
            b.setEnabled(name != "HEIC" or collage.HEIC)
            b.setChecked(name == was and b.isEnabled())
            row.addWidget(b)
        if self.format_group.checkedButton() is None:
            self.format_group.buttons()[0].setChecked(True)
        row.addStretch(1)
        lay.addLayout(row)
        lay.addStretch(1)
        s.addWidget(_scrolling(inner), 1)
        row = QHBoxLayout()
        self.close_btn = _plain("Close", self.close)
        self.edit_btn = _plain("Save and Edit…", lambda: self.save(True), "Saves the collage, then opens it in the photo "
                               "editor — for text, filters and frames")
        self.save_btn = QPushButton("Save", objectName="Primary")
        self.save_btn.setAutoDefault(False)
        self.save_btn.clicked.connect(lambda: self.save(False))
        for b in (self.close_btn, self.edit_btn, self.save_btn):
            row.addWidget(b)
        s.addLayout(row)
        root.addWidget(side)
        self._fill_layouts()

    def _fill_layouts(self) -> None:
        for b in self.layout_group.buttons():
            self.layout_group.removeButton(b)
            b.deleteLater()
        ink = self.palette().color(self.foregroundRole())
        ink.setAlpha(190)
        options = collage.layouts(len(self.paths))
        if self.design.layout not in options:
            self.design.layout = options[0]
        for i, layout in enumerate(options):
            b = QToolButton()
            b.setCheckable(True)
            b.setAutoRaise(True)
            b.setIcon(layout_icon(layout, self.design.ratio, ink))
            b.setIconSize(QSize(ICON, ICON))
            b.setFixedSize(ICON + 10, ICON + 10)
            b.setToolTip(layout.name)
            b.setStyleSheet("QToolButton { border: 2px solid transparent; border-radius: 7px; }"
                            "QToolButton:checked { border-color: #0a84ff; }")
            b.setChecked(layout == self.design.layout)
            b.clicked.connect(lambda _=False, layout=layout: self._set("layout", layout))
            self.layout_group.addButton(b)
            self.layout_grid.addWidget(b, i // 5, i % 5)
        n = len(self.paths)
        self.count.setText(f"{n} photos · {len(options)} layouts")
        self._show_size()

    # ------------------------------------------------------------------ changes
    def _set(self, key: str, value) -> None:
        setattr(self.design, key, value)
        if key in ("margin", "spacing", "corner"):
            self.settings.setValue(f"collage/{key}", value)
        elif key == "colour":
            self.settings.setValue("collage/colour", QColor(*value).name())
        elif key == "blur_back":
            self.settings.setValue("collage/blur", "true" if value else "false")
        self._show_size()
        self.draw()

    def _shape_changed(self, _i: int) -> None:
        ratio = self.shape.currentData()
        if ratio:
            self.design.ratio = float(ratio)
            self.settings.setValue("collage/ratio", float(ratio))
            self._fill_layouts()
            self.board.update()
            self.draw()

    def long_side(self) -> int:
        px = int(self.size.currentData() or 0)
        if px:
            return px
        sizes = [im.size for im in self.photos if im is not None]
        full = getattr(self, "_full_sizes", None) or sizes
        return collage.sharpest_size(full, self.design) if full else 2048

    def _show_size(self) -> None:
        self.settings.setValue("collage/size", int(self.size.currentData() or 0))
        w, h = collage.canvas_size(self.design.ratio, self.long_side())
        self.size_note.setText(f"{w:,} × {h:,} pixels")

    def swap(self, i: int, j: int) -> None:
        for seq in (self.paths, self.photos, self.design.views):
            seq[i], seq[j] = seq[j], seq[i]
        if getattr(self, "_full_sizes", None):
            self._full_sizes[i], self._full_sizes[j] = self._full_sizes[j], self._full_sizes[i]
        self.draw()

    def shuffle(self) -> None:
        order = list(range(len(self.paths)))
        random.shuffle(order)
        for name in ("paths", "photos"):
            seq = getattr(self, name)
            setattr(self, name, [seq[k] for k in order])
        self.design.views = [self.design.views[k] for k in order]
        if getattr(self, "_full_sizes", None):
            self._full_sizes = [self._full_sizes[k] for k in order]
        self.draw()

    def slide(self, i: int, was: collage.View, moved: QPointF, cell: QRectF) -> None:
        im = self.photos[i]
        if im is None:
            return
        l, t, r, b = collage.crop_box(im.size, (max(1, int(cell.width())), max(1, int(cell.height()))), was)
        size = (max(1, int(cell.width())), max(1, int(cell.height())))
        self.design.views[i] = collage.clamped(collage.View(was.zoom, was.x - moved.x() / cell.width() * (r - l) / im.width,
                                                            was.y - moved.y() / cell.height() * (b - t) / im.height),
                                               im.size, size)
        self.draw()

    def zoom(self, i: int, factor: float) -> None:
        v = self.design.views[i]
        v.zoom = min(6.0, max(1.0, v.zoom * factor))
        self._show_size()
        self.draw()

    def reset_view(self, i: int) -> None:
        self.design.views[i] = collage.View()
        self._show_size()
        self.draw()

    def remove(self, i: int) -> None:
        if len(self.paths) <= collage.MIN_PHOTOS:
            return
        for seq in (self.paths, self.photos, self.design.views):
            del seq[i]
        if getattr(self, "_full_sizes", None):
            del self._full_sizes[i]
        self._fill_layouts()
        self.draw()

    def add_photos(self) -> None:
        room = collage.MAX_PHOTOS - len(self.paths)
        if room <= 0:
            QMessageBox.information(self, "Make Collage", "A collage holds nine photos at most.")
            return
        start = os.path.dirname(self.paths[0]) if self.paths else ""
        picked, _ = QFileDialog.getOpenFileNames(self, "Add Photos", start, "Photos (*.jpg *.jpeg *.heic *.heif *.png *.webp *.tif *.tiff *.bmp)")
        fresh = [p for p in picked if collage.can_use(p) and p not in self.paths][:room]
        if not fresh:
            return
        first = len(self.paths)
        self.paths += fresh
        self.photos += [None] * len(fresh)
        self.design.views += [collage.View() for _ in fresh]
        if getattr(self, "_full_sizes", None):
            self._full_sizes += [(0, 0)] * len(fresh)
        self._fill_layouts()
        self._load(range(first, len(self.paths)))

    # ------------------------------------------------------------------ reading and drawing
    def _load(self, indexes) -> None:
        jobs = [(i, self.paths[i]) for i in indexes]
        sig = self._sig

        def work() -> None:
            for i, path in jobs:
                try:
                    with Image.open(path) as probe:
                        full = probe.size if (probe.getexif().get(0x0112, 1) or 1) < 5 else probe.size[::-1]
                    sig.loaded.emit(i, (collage.open_photo(path, LOADED), full, path), "")
                except Exception as e:  # noqa: BLE001
                    sig.loaded.emit(i, (None, (0, 0), path), str(e))
        threading.Thread(target=work, daemon=True).start()

    def _loaded(self, i: int, got, why: str) -> None:
        im, full, path = got
        if path not in self.paths:
            return
        i = self.paths.index(path)
        if im is None:
            QMessageBox.warning(self, "Make Collage", f"Couldn't read “{os.path.basename(path)}”: {why}")
            if len(self.paths) > collage.MIN_PHOTOS:
                self.remove(i)
            return
        self.photos[i] = im
        sizes = getattr(self, "_full_sizes", None) or [(0, 0)] * len(self.paths)
        sizes += [(0, 0)] * (len(self.paths) - len(sizes))
        sizes[i] = full
        self._full_sizes = sizes
        self._show_size()
        self.draw()

    def ready(self) -> bool:
        return bool(self.paths) and all(im is not None for im in self.photos)

    def _snapshot(self) -> collage.Design:
        d = self.design
        return collage.Design(d.layout, d.ratio, d.margin, d.spacing, d.corner, d.colour, d.blur_back,
                              [collage.View(v.zoom, v.x, v.y) for v in d.views])

    def draw(self) -> None:
        self.save_btn.setEnabled(self.ready() and not self.saving)
        self.edit_btn.setEnabled(self.ready() and not self.saving)
        self.side.setEnabled(not self.saving)
        self.shuffle_btn.setEnabled(not self.saving)
        self.add_btn.setEnabled(not self.saving)
        if not self.ready():
            return
        self.gen += 1
        snap = self._snapshot()
        with self._cv:
            self._job = (self.gen, list(self.photos), snap)
            self._cv.notify()

    def _draw_loop(self) -> None:
        while True:
            with self._cv:
                while self._job is None and self._alive:
                    self._cv.wait()
                if not self._alive:
                    return
                gen, photos, design = self._job
                self._job = None
            try:
                self._sig.drawn.emit(gen, _qimage(collage.render(photos, design, PREVIEW)))
            except Exception:  # noqa: BLE001 — the next change draws again
                pass

    def _drawn(self, gen: int, image: QImage) -> None:
        self.board.pix = QPixmap.fromImage(image)
        self.board.update()

    # ------------------------------------------------------------------ saving
    def save(self, edit: bool) -> None:
        if not self.ready() or self.saving:
            return
        self.saving = True
        self._edit_after = edit
        b = self.format_group.checkedButton()
        fmt = str(b.property("key")) if b is not None else "JPEG"
        self.settings.setValue("collage/format", fmt)
        self.bar.setValue(0)
        self.bar.show()
        self.note.setText("Saving…")
        self.draw()
        d, paths, long_side, sig = self._snapshot(), list(self.paths), self.long_side(), self._sig
        folder = os.path.dirname(paths[0])                 # (a snapshot: the window can't change what's being saved)
        need = collage.needed_side(d, long_side)

        def work() -> None:
            try:
                photos = []
                for k, p in enumerate(paths):
                    photos.append(collage.open_photo(p, need))
                    sig.progress.emit(0.6 * (k + 1) / len(paths))
                im = collage.render(photos, d, long_side)
                sig.progress.emit(0.85)
                sig.saved.emit(collage.save(im, folder, fmt, collage.oldest(paths)), "")
            except Exception as e:  # noqa: BLE001
                sig.saved.emit("", str(e))
        threading.Thread(target=work, daemon=True).start()

    def _saved(self, written: str, why: str) -> None:
        self.saving = False
        self.bar.hide()
        if not written:
            self.note.setText("")
            self.draw()
            QMessageBox.warning(self, "Make Collage", f"Couldn't save the collage: {why}")
            return
        try:
            self.on_done(written, list(self.paths), bool(getattr(self, "_edit_after", False)))
        finally:
            self.accept()

    def closeEvent(self, event) -> None:  # noqa: N802
        if self.saving:
            event.ignore()
            return
        with self._cv:
            self._alive = False
            self._cv.notify()
        event.accept()

    def done(self, r: int) -> None:
        with self._cv:
            self._alive = False
            self._cv.notify()
        super().done(r)
