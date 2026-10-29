"""Safe Finder's Crop window: draw one crop on a photo and put it on every selected photo.

Right-click photos ▸ "Crop…" (or "Crop N Photos…"). The window shows one of them with a crop box — drag
inside it to move it, a corner to resize, a side (Freeform) to trim just that side — the iPhone's ratios
(Freeform, Original, 1:1, 4:5, 3:2, 16:9), quarter turns, and "Last Crop" (the crop saved last, here).
‹ › (or the arrow keys) step through the selection to check the same crop on each photo. "Crop" writes
them all in place (batch_crop.py — the rules and what's kept are there) on a worker thread, one at a time;
Stop ends it after the photo in hand. Safe Finder then tags every cropped photo "cropped".
"""
from __future__ import annotations

import os
import threading
from typing import Callable

from PySide6.QtCore import QObject, QPointF, QRectF, QSettings, Qt, Signal
from PySide6.QtGui import QColor, QImage, QKeySequence, QPainter, QPainterPath, QPen, QShortcut, QTransform
from PySide6.QtWidgets import (QButtonGroup, QDialog, QHBoxLayout, QLabel, QMessageBox, QProgressBar,
                               QPushButton, QToolButton, QVBoxLayout, QWidget)

import batch_crop as bc

PREVIEW_PX = 1600
LAST_KEY = "crop/last"          # the last crop, as CropSpec JSON, in Safe Finder's settings
GRAB = 12                       # how close (points) the pointer must be to grab a corner or a side


def load_preview(path: str) -> tuple[QImage, int, int]:
    """The photo upright, at most PREVIEW_PX on a side, and its full upright pixel size. Raises CropError."""
    w, h = bc.upright_size(path)
    try:
        with bc.Image.open(path) as im:
            im.draft("RGB", (PREVIEW_PX, PREVIEW_PX))          # JPEG: decode at a fraction of the size
            up = bc.ImageOps.exif_transpose(im) or im
            up.thumbnail((PREVIEW_PX, PREVIEW_PX))
            rgba = up.convert("RGBA")
            data = rgba.tobytes("raw", "RGBA")
            img = QImage(data, rgba.width, rgba.height, rgba.width * 4, QImage.Format.Format_RGBA8888).copy()
    except Exception as e:  # noqa: BLE001 — any decoder error
        raise bc.CropError(f"can't read it ({e})") from e
    return img, w, h


class _Signals(QObject):
    loaded = Signal(int, QImage, int, int)       # token, preview, full width, full height
    failed = Signal(int, str)
    progress = Signal(int, str, str)              # index, path, error ("" when cropped)
    done = Signal()


class CropCanvas(QWidget):
    """The photo with the crop box over it. `box` is normalized (x, y, w, h, top-left); `ratio` is the
    normalized w/h it keeps (None = free)."""
    changed = Signal()
    MARGIN = 16

    def __init__(self, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.image: QImage | None = None
        self.box: bc.Rect = bc.FULL
        self.ratio: float | None = None
        self.message = "Loading…"
        self._drag: tuple[str, str, bc.Rect, QPointF] | None = None
        self.setMouseTracking(True)
        self.setMinimumSize(460, 340)

    def frame(self) -> QRectF:
        area = QRectF(self.rect()).adjusted(self.MARGIN, self.MARGIN, -self.MARGIN, -self.MARGIN)
        if self.image is None or self.image.width() <= 0 or self.image.height() <= 0:
            return area
        s = min(area.width() / self.image.width(), area.height() / self.image.height())
        w, h = self.image.width() * s, self.image.height() * s
        return QRectF(area.x() + (area.width() - w) / 2, area.y() + (area.height() - h) / 2, w, h)

    def box_rect(self, f: QRectF | None = None) -> QRectF:
        f = f or self.frame()
        x, y, w, h = self.box
        return QRectF(f.x() + x * f.width(), f.y() + y * f.height(), w * f.width(), h * f.height())

    def paintEvent(self, _event) -> None:  # noqa: N802
        p = QPainter(self)
        p.setRenderHint(QPainter.RenderHint.Antialiasing)
        p.fillRect(self.rect(), QColor("#161618"))
        if self.image is None:
            p.setPen(QColor("#9a9aa0"))
            p.drawText(self.rect(), Qt.AlignmentFlag.AlignCenter, self.message)
            return
        f = self.frame()
        p.setRenderHint(QPainter.RenderHint.SmoothPixmapTransform)
        p.drawImage(f, self.image)
        r = self.box_rect(f)
        shade = QPainterPath()
        shade.setFillRule(Qt.FillRule.OddEvenFill)
        shade.addRect(f)
        shade.addRect(r)
        p.fillPath(shade, QColor(0, 0, 0, 140))
        p.setPen(QPen(QColor(255, 255, 255, 110), 0.7))
        for i in (1, 2):
            x = r.x() + r.width() * i / 3
            y = r.y() + r.height() * i / 3
            p.drawLine(QPointF(x, r.top()), QPointF(x, r.bottom()))
            p.drawLine(QPointF(r.left(), y), QPointF(r.right(), y))
        p.setPen(QPen(QColor("white"), 1.5))
        p.setBrush(Qt.BrushStyle.NoBrush)
        p.drawRect(r)
        p.setPen(Qt.PenStyle.NoPen)
        p.setBrush(QColor("white"))
        for c in (r.topLeft(), r.topRight(), r.bottomLeft(), r.bottomRight()):
            p.drawRect(QRectF(c.x() - 5, c.y() - 5, 10, 10))
        if self.ratio is None:
            for c, across in ((QPointF(r.center().x(), r.top()), True), (QPointF(r.center().x(), r.bottom()), True),
                              (QPointF(r.left(), r.center().y()), False), (QPointF(r.right(), r.center().y()), False)):
                bw, bh = (24, 5) if across else (5, 24)
                p.drawRoundedRect(QRectF(c.x() - bw / 2, c.y() - bh / 2, bw, bh), 2, 2)

    def _hit(self, pos: QPointF) -> tuple[str, str] | None:
        r = self.box_rect()
        corners = {"tl": r.topLeft(), "tr": r.topRight(), "bl": r.bottomLeft(), "br": r.bottomRight()}
        for name, c in corners.items():
            if abs(pos.x() - c.x()) <= GRAB and abs(pos.y() - c.y()) <= GRAB:
                return "corner", name
        if self.ratio is None:
            inside_x = r.left() < pos.x() < r.right()
            inside_y = r.top() < pos.y() < r.bottom()
            if inside_x and abs(pos.y() - r.top()) <= GRAB / 2:
                return "side", "top"
            if inside_x and abs(pos.y() - r.bottom()) <= GRAB / 2:
                return "side", "bottom"
            if inside_y and abs(pos.x() - r.left()) <= GRAB / 2:
                return "side", "left"
            if inside_y and abs(pos.x() - r.right()) <= GRAB / 2:
                return "side", "right"
        if r.contains(pos):
            return "move", ""
        return None

    _CURSORS = {"tl": Qt.CursorShape.SizeFDiagCursor, "br": Qt.CursorShape.SizeFDiagCursor,
                "tr": Qt.CursorShape.SizeBDiagCursor, "bl": Qt.CursorShape.SizeBDiagCursor,
                "top": Qt.CursorShape.SizeVerCursor, "bottom": Qt.CursorShape.SizeVerCursor,
                "left": Qt.CursorShape.SizeHorCursor, "right": Qt.CursorShape.SizeHorCursor}

    def mousePressEvent(self, event) -> None:  # noqa: N802
        if self.image is None or not self.isEnabled() or event.button() != Qt.MouseButton.LeftButton:
            return
        hit = self._hit(event.position())
        if hit:
            self._drag = (hit[0], hit[1], self.box, event.position())
            if hit[0] == "move":
                self.setCursor(Qt.CursorShape.ClosedHandCursor)

    def mouseMoveEvent(self, event) -> None:  # noqa: N802
        if self.image is None:
            return
        if self._drag is None:
            hit = self._hit(event.position())
            if hit is None:
                self.unsetCursor()
            elif hit[0] == "move":
                self.setCursor(Qt.CursorShape.OpenHandCursor)
            else:
                self.setCursor(self._CURSORS[hit[1]])
            return
        kind, name, start, at = self._drag
        f = self.frame()
        if f.width() <= 0 or f.height() <= 0:
            return
        dx = (event.position().x() - at.x()) / f.width()
        dy = (event.position().y() - at.y()) / f.height()
        if kind == "move":
            self.box = bc.moved(start, dx, dy)
        elif kind == "side":
            self.box = bc.side_moved(name, start, dx, dy)
        else:
            self.box = bc.resized(name, start, dx, dy, self.ratio)
        self.update()
        self.changed.emit()

    def mouseReleaseEvent(self, _event) -> None:  # noqa: N802
        if self._drag is not None and self._drag[0] == "move":
            self.setCursor(Qt.CursorShape.OpenHandCursor)
        self._drag = None


class CropDialog(QDialog):
    """`on_done(cropped, trimmed, failed)` runs on the UI thread once the photos are written: the paths
    that were rewritten, whether the crop trims (else it only turned them), and how many failed."""

    def __init__(self, parent: QWidget | None, photos: list[str], settings: QSettings,
                 on_done: Callable[[list[str], bool, int], None]) -> None:
        super().__init__(parent)
        self.photos = photos
        self.settings = settings
        self.on_done = on_done
        self.current = 0
        self.upright: QImage | None = None
        self.full = (1, 1)                       # the shown photo's upright pixel size
        self.quarters = 0
        self.aspect = "Freeform"
        self.keep_shape = False
        self.running = False
        self._token = 0
        self._pending = 0
        self._stop = threading.Event()
        self._cropped: list[str] = []
        self._failed: list[tuple[str, str]] = []
        self._spec: bc.CropSpec | None = None
        self._sig = _Signals()
        self._sig.loaded.connect(self._loaded)
        self._sig.failed.connect(self._load_failed)
        self._sig.progress.connect(self._progress)
        self._sig.done.connect(self._finished)

        n = len(photos)
        self.setWindowTitle("Crop" if n == 1 else f"Crop {n} Photos")
        self.resize(980, 780)

        tools = QHBoxLayout()
        self.left_btn = self._tool("↺  Left", lambda: self.turn(-1), "Turn a quarter to the left")
        self.right_btn = self._tool("↻  Right", lambda: self.turn(1), "Turn a quarter to the right")
        self.last_btn = self._tool("Last Crop", self.use_last, "")
        tools.addWidget(self.left_btn)
        tools.addWidget(self.right_btn)
        tools.addWidget(self.last_btn)
        tools.addStretch(1)
        self.aspects = QButtonGroup(self)
        self.aspects.setExclusive(True)
        for name, _ratio in bc.ASPECTS:
            b = QToolButton(objectName="Scope")
            b.setText(name)
            b.setCheckable(True)
            b.setChecked(name == self.aspect)
            b.clicked.connect(lambda _=False, name=name: self.set_aspect(name))
            self.aspects.addButton(b)
            tools.addWidget(b)

        self.canvas = CropCanvas()
        self.canvas.changed.connect(self._refresh)

        nav_row = QWidget()
        nav = QHBoxLayout(nav_row)
        nav.setContentsMargins(0, 0, 0, 0)
        self.prev_btn = self._tool("‹", lambda: self.step(-1), "Previous photo (←)")
        self.next_btn = self._tool("›", lambda: self.step(1), "Next photo (→)")
        self.where = QLabel()
        self.where.setTextInteractionFlags(Qt.TextInteractionFlag.TextSelectableByMouse)
        nav.addWidget(self.prev_btn)
        nav.addWidget(self.where, 1)
        nav.addWidget(self.next_btn)

        self.note = QLabel()
        self.note.setWordWrap(True)
        self.bar = QProgressBar()
        self.bar.setRange(0, n)
        self.bar.hide()

        buttons = QHBoxLayout()
        buttons.addWidget(self.note, 1)
        self.cancel_btn = QPushButton("Cancel")
        self.cancel_btn.clicked.connect(self.reject)
        self.crop_btn = QPushButton(objectName="Primary")
        self.crop_btn.setDefault(True)
        self.crop_btn.clicked.connect(self.run)
        buttons.addWidget(self.cancel_btn)
        buttons.addWidget(self.crop_btn)

        lay = QVBoxLayout(self)
        lay.addLayout(tools)
        lay.addWidget(self.canvas, 1)
        lay.addWidget(nav_row)
        nav_row.setVisible(n > 1)
        lay.addWidget(self.bar)
        lay.addLayout(buttons)

        QShortcut(QKeySequence(Qt.Key.Key_Left), self, activated=lambda: self.step(-1))
        QShortcut(QKeySequence(Qt.Key.Key_Right), self, activated=lambda: self.step(1))
        self._refresh()
        self._load(0)

    def _tool(self, text: str, slot, tip: str) -> QToolButton:
        b = QToolButton(objectName="Scope")
        b.setText(text)
        b.setToolTip(tip)
        b.clicked.connect(slot)
        return b

    # -- the crop as drawn
    def turned_size(self) -> tuple[int, int]:
        w, h = self.full
        return (h, w) if self.quarters % 2 else (w, h)

    def spec(self) -> bc.CropSpec:
        tw, th = self.turned_size()
        return bc.CropSpec(self.quarters, self.canvas.box, tw, th, self.keep_shape,
                           os.path.basename(self.photos[self.current]))

    def _ratio(self) -> float | None:
        return dict(bc.ASPECTS)[self.aspect]

    def _show_turned(self) -> None:
        if self.upright is None:
            return
        self.canvas.image = self.upright.transformed(QTransform().rotate(90 * self.quarters)) \
            if self.quarters else self.upright
        self.canvas.ratio = bc.box_constraint(self.aspect, self._ratio(), *self.turned_size())
        self.canvas.update()

    def _check(self, name: str) -> None:
        for b in self.aspects.buttons():
            b.setChecked(b.text() == name)

    def turn(self, step: int) -> None:
        if self.upright is None or self.running:
            return
        before = self.canvas.box
        self.quarters = (self.quarters + step) % 4
        self._show_turned()
        if self.aspect == "Freeform":
            self.canvas.box = bc.turned(before, step)
        else:
            self.set_aspect(self.aspect)
        self._refresh()

    def set_aspect(self, name: str) -> None:
        """Original clears the box (and keeps the photo's ratio while dragging); a ratio sets the largest
        centered box of it; Freeform keeps the box and frees every side."""
        self.aspect = name
        ratio = self._ratio()
        self.keep_shape = ratio is not None
        tw, th = self.turned_size()
        if name == "Original":
            self.canvas.box = bc.FULL
        elif ratio is not None:
            self.canvas.box = bc.centered_box(ratio, tw, th)
        self._check(name)
        self._show_turned()
        self._refresh()

    def last(self) -> bc.CropSpec | None:
        return bc.CropSpec.from_json(self.settings.value(LAST_KEY))

    def use_last(self) -> None:
        last = self.last()
        if last is None or self.upright is None or self.running:
            return
        self.quarters = last.quarters % 4
        self.aspect = "Freeform"
        self._check("Freeform")
        self.keep_shape = last.keeps_shape
        self._show_turned()
        self.canvas.box = last.rect_for(*self.turned_size())
        self.canvas.update()
        self._refresh()

    # -- stepping through the photos
    def step(self, delta: int) -> None:
        i = self.current + delta
        if self.running or not 0 <= i < len(self.photos) or i == self.current:
            return
        self._load(i)

    def _load(self, i: int) -> None:
        self._token += 1
        token, path = self._token, self.photos[i]
        self._pending = i
        self.where.setText(f"{i + 1} of {len(self.photos)}  ·  {os.path.basename(path)}")

        def work() -> None:
            try:
                img, w, h = load_preview(path)
                self._sig.loaded.emit(token, img, w, h)
            except Exception as e:  # noqa: BLE001
                self._sig.failed.emit(token, str(e))
        threading.Thread(target=work, daemon=True).start()

    def _loaded(self, token: int, img: QImage, w: int, h: int) -> None:
        if token != self._token:
            return
        before = self.spec() if self.upright is not None else None
        self.current = self._pending
        self.upright = img
        self.full = (w, h)
        self._show_turned()
        if before is not None:
            self.canvas.box = before.rect_for(*self.turned_size())
        self.canvas.update()
        self._refresh()

    def _load_failed(self, token: int, why: str) -> None:
        if token != self._token:
            return
        if self.upright is None:
            self.canvas.message = f"Couldn't open {os.path.basename(self.photos[self._pending])}: {why}"
            self.canvas.update()
        else:
            self.where.setText(f"{self._pending + 1} of {len(self.photos)}  ·  "
                               f"couldn't open {os.path.basename(self.photos[self._pending])} — {why}")

    def _refresh(self) -> None:
        n = len(self.photos)
        ready = self.upright is not None and not self.running
        spec = self.spec() if self.upright is not None else None
        verb = "Crop" if spec is None or spec.trims or not spec.changes else "Turn"
        self.crop_btn.setText(verb if n == 1 else f"{verb} {n} Photos")
        self.crop_btn.setEnabled(ready and spec is not None and spec.changes)
        last = self.last()
        self.last_btn.setEnabled(ready and last is not None)
        self.last_btn.setToolTip(f"The crop saved last, from “{last.source}”" if last and last.source
                                 else "The crop saved last" if last else "No crop saved yet")
        for w in (self.left_btn, self.right_btn, *self.aspects.buttons()):
            w.setEnabled(ready)
        self.canvas.setEnabled(not self.running)
        self.prev_btn.setEnabled(not self.running and self.current > 0)
        self.next_btn.setEnabled(not self.running and self.current < n - 1)
        if not self.running:
            self.note.setText("The same crop goes on every photo — ‹ › to check it on each. "
                              "They're cropped in place, their dates and tags kept, and tagged “cropped”."
                              if n > 1 else "Cropped in place, its dates and tags kept, and tagged “cropped”.")

    # -- writing them
    def run(self) -> None:
        if self.running or self.upright is None:
            return
        spec = self.spec()
        if not spec.changes:
            return
        self._spec = spec
        self.running = True
        self._stop.clear()
        self._cropped, self._failed = [], []
        self.bar.setValue(0)
        self.bar.show()
        self.cancel_btn.setText("Stop")
        self._refresh()
        self.note.setText("Cropping…")
        photos = list(self.photos)

        def work() -> None:
            for i, path in enumerate(photos):
                if self._stop.is_set():
                    break
                try:
                    bc.apply(spec, path)
                    err = ""
                except (bc.CropError, OSError) as e:
                    err = str(e)
                except Exception as e:  # noqa: BLE001 — one bad photo never stops the rest
                    err = f"{type(e).__name__}: {e}"
                self._sig.progress.emit(i, path, err)
            self._sig.done.emit()
        threading.Thread(target=work, daemon=True).start()

    def _progress(self, i: int, path: str, err: str) -> None:
        if err:
            self._failed.append((path, err))
        else:
            self._cropped.append(path)
        self.bar.setValue(i + 1)
        self.note.setText(f"Cropping {min(i + 2, len(self.photos))} of {len(self.photos)}…")

    def _finished(self) -> None:
        self.running = False
        spec = self._spec
        if spec is not None and spec.trims and self._cropped:
            self.settings.setValue(LAST_KEY, spec.to_json())
        self.on_done(list(self._cropped), bool(spec and spec.trims), len(self._failed))
        if self._failed:
            lines = "\n".join(f"• {os.path.basename(p)} — {why}" for p, why in self._failed[:12])
            more = f"\n…and {len(self._failed) - 12} more" if len(self._failed) > 12 else ""
            QMessageBox.warning(self, "Some Photos Weren't Cropped",
                                f"Cropped {len(self._cropped)} of {len(self.photos)}. These were left as they "
                                f"were:\n\n{lines}{more}")
        self.accept()

    def reject(self) -> None:
        if self.running:                         # Stop: finish the photo in hand, then wrap up
            self._stop.set()
            self.cancel_btn.setEnabled(False)
            self.note.setText("Stopping after this photo…")
            return
        super().reject()

    def closeEvent(self, event) -> None:  # noqa: N802
        if self.running:
            self.reject()
            event.ignore()
            return
        super().closeEvent(event)
