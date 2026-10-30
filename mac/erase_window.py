"""Safe Finder's Erase window: take a watermark (a date stamp, a blemish) off photos — drawn once, put on every
selected photo.

Right-click photos ▸ "Erase Area…". The window shows one of them: drag over what should go to put a box
on it (several boxes are fine; drag a box to move it, a corner to resize it, click one and press Delete —
or right-click it — to take it away). "Just the Mark" erases only what stands out inside the boxes — the
letters or the logo, with the photo between and under them kept — and "Sensitivity" sets how faint a mark
still counts; "Whole Box" replaces everything inside them. The result shows as soon as the boxes are drawn;
"Original" shows the photo with what will go in red. ‹ › (or the arrow keys) step through the selection to
check the same boxes on each photo (they're fractions of each photo, as a crop is). "Last Area" brings back
the boxes used last. Save as New writes each result beside its photo, Replace rewrites the photo
(retouch.py does the work, on a worker thread, one photo at a time; Stop ends it after the photo in hand);
Safe Finder tags the results "retouched".
"""
from __future__ import annotations

import os
import threading
from typing import Callable

import numpy as np
from PySide6.QtCore import QObject, QPointF, QRectF, QSettings, Qt, QTimer, Signal
from PySide6.QtGui import QColor, QImage, QKeySequence, QPainter, QPen, QShortcut
from PySide6.QtWidgets import (QButtonGroup, QDialog, QHBoxLayout, QLabel, QMessageBox, QProgressBar, QPushButton,
                               QSlider, QToolButton, QVBoxLayout, QWidget)

import batch_crop as bc
import retouch as rt
from batch_crop import Image, ImageOps

PREVIEW_PX = 1600
LAST_KEY = "erase/last"         # the last boxes and settings, as EraseSpec JSON
SAVE_KEY = "erase/save"         # "new" / "replace", the last answer
GRAB = 10                       # how close (points) the pointer must be to grab a corner
MIN_BOX = 0.006                 # a click is not a box


def load_preview(path: str) -> tuple["Image.Image", int, int]:
    """The photo upright as RGB, at most PREVIEW_PX on a side, and its full upright size. Raises CropError."""
    w, h = bc.upright_size(path)
    try:
        with Image.open(path) as im:
            im.draft("RGB", (PREVIEW_PX, PREVIEW_PX))
            up = ImageOps.exif_transpose(im) or im
            up.thumbnail((PREVIEW_PX, PREVIEW_PX))
            return up.convert("RGB"), w, h
    except Exception as e:  # noqa: BLE001 — any decoder error
        raise bc.CropError(f"can't read it ({e})") from e


def to_qimage(im: "Image.Image") -> QImage:
    rgba = im.convert("RGBA")
    return QImage(rgba.tobytes("raw", "RGBA"), rgba.width, rgba.height, rgba.width * 4,
                  QImage.Format.Format_RGBA8888).copy()


def mask_image(mask: np.ndarray) -> QImage:
    """What will go, in translucent red."""
    rgba = np.zeros(mask.shape + (4,), dtype=np.uint8)
    rgba[mask] = (255, 59, 48, 170)
    h, w = mask.shape
    return QImage(rgba.tobytes(), w, h, w * 4, QImage.Format.Format_RGBA8888).copy()


class _Signals(QObject):
    loaded = Signal(int, object, int, int)       # token, preview (PIL), full width, full height
    failed = Signal(int, str)
    previewed = Signal(int, QImage, QImage, int)  # token, result, mark overlay, pixels marked
    progress = Signal(int, str, str, str)         # index, path, outcome ("done"/"none"/"failed"), result or why
    done = Signal()


class EraseCanvas(QWidget):
    """The photo with the boxes over it. `boxes` are normalized (x, y, w, h, top-left)."""
    changed = Signal()
    MARGIN = 16

    def __init__(self, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.image: QImage | None = None
        self.overlay: QImage | None = None
        self.boxes: list[rt.Box] = []
        self.selected: int | None = None
        self.message = "Loading…"
        self._drag: tuple[str, int, rt.Box, QPointF] | None = None
        self.setMouseTracking(True)
        self.setMinimumSize(460, 340)
        self.setFocusPolicy(Qt.FocusPolicy.StrongFocus)

    def frame(self) -> QRectF:
        area = QRectF(self.rect()).adjusted(self.MARGIN, self.MARGIN, -self.MARGIN, -self.MARGIN)
        if self.image is None or self.image.width() <= 0 or self.image.height() <= 0:
            return area
        s = min(area.width() / self.image.width(), area.height() / self.image.height())
        w, h = self.image.width() * s, self.image.height() * s
        return QRectF(area.x() + (area.width() - w) / 2, area.y() + (area.height() - h) / 2, w, h)

    def box_rect(self, b: rt.Box, f: QRectF | None = None) -> QRectF:
        f = f or self.frame()
        x, y, w, h = b
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
        if self.overlay is not None:
            p.drawImage(f, self.overlay)
        for i, b in enumerate(self.boxes):
            r = self.box_rect(b, f)
            chosen = i == self.selected
            p.setBrush(Qt.BrushStyle.NoBrush)
            p.setPen(QPen(QColor(0, 0, 0, 150), 3))
            p.drawRect(r)
            pen = QPen(QColor("#0A84FF") if chosen else QColor("white"), 1.5)
            if not chosen:
                pen.setStyle(Qt.PenStyle.DashLine)
            p.setPen(pen)
            p.drawRect(r)
            if chosen:
                p.setPen(Qt.PenStyle.NoPen)
                p.setBrush(QColor("#0A84FF"))
                for c in (r.topLeft(), r.topRight(), r.bottomLeft(), r.bottomRight()):
                    p.drawRect(QRectF(c.x() - 4, c.y() - 4, 8, 8))
        if not self.boxes:
            p.setPen(QColor(255, 255, 255, 220))
            p.drawText(f.adjusted(0, 0, 0, -12), Qt.AlignmentFlag.AlignHCenter | Qt.AlignmentFlag.AlignBottom,
                       "Drag over the watermark to erase it")

    def _hit(self, pos: QPointF) -> tuple[str, int] | None:
        order = ([self.selected] if self.selected is not None else []) + \
                [i for i in reversed(range(len(self.boxes))) if i != self.selected]
        for i in order:
            r = self.box_rect(self.boxes[i])
            for name, c in (("tl", r.topLeft()), ("tr", r.topRight()), ("bl", r.bottomLeft()), ("br", r.bottomRight())):
                if abs(pos.x() - c.x()) <= GRAB and abs(pos.y() - c.y()) <= GRAB:
                    return name, i
        for i in order:
            if self.box_rect(self.boxes[i]).contains(pos):
                return "move", i
        return None

    def _norm(self, pos: QPointF) -> tuple[float, float]:
        f = self.frame()
        return (min(1.0, max(0.0, (pos.x() - f.x()) / max(f.width(), 1))),
                min(1.0, max(0.0, (pos.y() - f.y()) / max(f.height(), 1))))

    def mousePressEvent(self, event) -> None:  # noqa: N802
        if self.image is None or not self.isEnabled():
            return
        pos = event.position()
        hit = self._hit(pos)
        if event.button() == Qt.MouseButton.RightButton:
            if hit is not None:
                self.remove(hit[1])
            return
        if hit is not None:
            self.selected = hit[1]
            self._drag = (hit[0], hit[1], self.boxes[hit[1]], pos)
        else:
            x, y = self._norm(pos)
            self.boxes.append((x, y, 0.0, 0.0))
            self.selected = len(self.boxes) - 1
            self._drag = ("new", self.selected, (x, y, 0.0, 0.0), pos)
        self.update()

    def mouseMoveEvent(self, event) -> None:  # noqa: N802
        pos = event.position()
        if self._drag is None:
            hit = self._hit(pos)
            shape = Qt.CursorShape.CrossCursor
            if hit and hit[0] in ("tl", "br"):
                shape = Qt.CursorShape.SizeFDiagCursor
            elif hit and hit[0] in ("tr", "bl"):
                shape = Qt.CursorShape.SizeBDiagCursor
            elif hit:
                shape = Qt.CursorShape.SizeAllCursor
            self.setCursor(shape)
            return
        kind, i, start, origin = self._drag
        f = self.frame()
        dx, dy = (pos.x() - origin.x()) / max(f.width(), 1), (pos.y() - origin.y()) / max(f.height(), 1)
        x, y, w, h = start
        if kind == "move":
            x, y = min(max(0.0, x + dx), 1 - w), min(max(0.0, y + dy), 1 - h)
            self.boxes[i] = (x, y, w, h)
        else:
            if kind == "new":
                ax, ay = x, y                                  # the press point stays put
                bx, by = self._norm(pos)
            else:
                left, top, right, bottom = x, y, x + w, y + h
                if "l" in kind:
                    left = min(max(0.0, left + dx), right - MIN_BOX)
                if "r" in kind:
                    right = max(min(1.0, right + dx), left + MIN_BOX)
                if "t" in kind:
                    top = min(max(0.0, top + dy), bottom - MIN_BOX)
                if "b" in kind:
                    bottom = max(min(1.0, bottom + dy), top + MIN_BOX)
                ax, ay, bx, by = left, top, right, bottom
            self.boxes[i] = (min(ax, bx), min(ay, by), abs(bx - ax), abs(by - ay))
        self.update()

    def mouseReleaseEvent(self, _event) -> None:  # noqa: N802
        if self._drag is None:
            return
        kind, i, _start, _origin = self._drag
        self._drag = None
        if kind == "new" and (self.boxes[i][2] < MIN_BOX or self.boxes[i][3] < MIN_BOX):
            del self.boxes[i]                                  # a click, not a box
            self.selected = None
        self.update()
        self.changed.emit()

    def keyPressEvent(self, event) -> None:  # noqa: N802
        if event.key() in (Qt.Key.Key_Delete, Qt.Key.Key_Backspace) and self.selected is not None:
            self.remove(self.selected)
            return
        super().keyPressEvent(event)

    def remove(self, i: int) -> None:
        if 0 <= i < len(self.boxes):
            del self.boxes[i]
            self.selected = None
            self.update()
            self.changed.emit()


class EraseDialog(QDialog):
    """`on_done(erased, as_new, untouched, failed)` runs on the UI thread at the end: (photo, result) for each
    one erased, whether the results are new photos, how many had no mark in their boxes, how many failed."""

    def __init__(self, parent: QWidget | None, photos: list[str], settings: QSettings,
                 on_done: Callable[[list[tuple[str, str]], bool, int, int], None]) -> None:
        super().__init__(parent)
        self.photos, self.settings, self.on_done = photos, settings, on_done
        self.current = 0
        self.preview: Image.Image | None = None
        self.original: QImage | None = None
        self.result: QImage | None = None
        self.mark: QImage | None = None
        self.running = False
        self.as_new = True
        self._token = 0
        self._pending = 0
        self._ptoken = 0
        self._stop = threading.Event()
        self._erased: list[tuple[str, str]] = []
        self._none = 0
        self._failed: list[tuple[str, str]] = []
        self._sig = _Signals()
        self._sig.loaded.connect(self._loaded)
        self._sig.failed.connect(self._load_failed)
        self._sig.previewed.connect(self._previewed)
        self._sig.progress.connect(self._progress)
        self._sig.done.connect(self._finished)
        self._soon = QTimer(self)
        self._soon.setSingleShot(True)
        self._soon.setInterval(200)
        self._soon.timeout.connect(self._make_preview)

        n = len(photos)
        self.setWindowTitle("Erase Area" if n == 1 else f"Erase Area on {n} Photos")
        self.resize(1000, 800)

        tools = QHBoxLayout()
        self.modes = QButtonGroup(self)
        self.mark_btn = self._seg("Just the Mark", "Erase only what stands out inside the boxes — the letters or "
                                  "the logo — and keep the photo between and under them", self.modes)
        self.box_btn = self._seg("Whole Box", "Replace everything inside the boxes", self.modes)
        self.mark_btn.setChecked(True)
        tools.addWidget(self.mark_btn)
        tools.addWidget(self.box_btn)
        self.sens_label = QLabel("Sensitivity")
        tools.addSpacing(12)
        tools.addWidget(self.sens_label)
        self.sensitivity = QSlider(Qt.Orientation.Horizontal)
        self.sensitivity.setRange(0, 20)
        self.sensitivity.setValue(round(rt.EraseSpec(()).sensitivity * 20))
        self.sensitivity.setFixedWidth(150)
        self.sensitivity.setToolTip("Higher finds fainter marks — and more of the photo; the red in "
                                    "“Original” shows what will go")
        tools.addWidget(self.sensitivity)
        tools.addStretch(1)
        self.views = QButtonGroup(self)
        self.result_btn = self._seg("Result", "The photo as it will be", self.views)
        self.orig_btn = self._seg("Original", "The photo as it is, with what will go in red", self.views)
        self.result_btn.setChecked(True)
        tools.addWidget(self.result_btn)
        tools.addWidget(self.orig_btn)
        tools.addSpacing(12)
        self.last_btn = self._tool("Last Area", self.use_last, "The boxes used last")
        self.clear_btn = self._tool("Clear", self.clear, "Take every box away")
        tools.addWidget(self.last_btn)
        tools.addWidget(self.clear_btn)
        for b in (self.mark_btn, self.box_btn):
            b.clicked.connect(self._spec_changed)
        self.sensitivity.valueChanged.connect(self._spec_changed)
        for b in (self.result_btn, self.orig_btn):
            b.clicked.connect(self._show)

        self.canvas = EraseCanvas()
        self.canvas.changed.connect(self._spec_changed)

        nav_row = QWidget()
        nav = QHBoxLayout(nav_row)
        nav.setContentsMargins(0, 0, 0, 0)
        self.prev_btn = self._tool("‹", lambda: self.step(-1), "Previous photo (←)")
        self.next_btn = self._tool("›", lambda: self.step(1), "Next photo (→)")
        self.where = QLabel()
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
        self.replace_btn = QPushButton("Replace Original" if n == 1 else "Replace Originals")
        self.replace_btn.clicked.connect(lambda: self.run(False))
        self.new_btn = QPushButton("Save as New" if n == 1 else "Save as New Photos")
        self.new_btn.clicked.connect(lambda: self.run(True))
        for b in (self.cancel_btn, self.replace_btn, self.new_btn):
            b.setAutoDefault(False)
            buttons.addWidget(b)
        (self.replace_btn if settings.value(SAVE_KEY, "new") == "replace" else self.new_btn).setDefault(True)

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

    def _seg(self, text: str, tip: str, group: QButtonGroup) -> QToolButton:
        b = QToolButton(objectName="Scope")
        b.setText(text)
        b.setToolTip(tip)
        b.setCheckable(True)
        group.addButton(b)
        return b

    def _tool(self, text: str, slot, tip: str) -> QToolButton:
        b = QToolButton(objectName="Scope")
        b.setText(text)
        b.setToolTip(tip)
        b.clicked.connect(slot)
        return b

    # -- what's drawn
    def spec(self) -> rt.EraseSpec:
        return rt.EraseSpec(tuple(self.canvas.boxes), self.mark_btn.isChecked(), self.sensitivity.value() / 20)

    def last(self) -> rt.EraseSpec | None:
        text = self.settings.value(LAST_KEY)
        return rt.EraseSpec.from_json(str(text)) if text else None

    def use_last(self) -> None:
        spec = self.last()
        if spec is None:
            return
        self.canvas.boxes = list(spec.boxes)
        self.canvas.selected = None
        (self.mark_btn if spec.only_mark else self.box_btn).setChecked(True)
        self.sensitivity.blockSignals(True)
        self.sensitivity.setValue(round(spec.sensitivity * 20))
        self.sensitivity.blockSignals(False)
        self.canvas.update()
        self._spec_changed()

    def clear(self) -> None:
        self.canvas.boxes = []
        self.canvas.selected = None
        self.canvas.update()
        self._spec_changed()

    def _spec_changed(self) -> None:
        self._refresh()
        self.result = self.mark = None
        self._show()
        if self.canvas.boxes and self.preview is not None:
            self._soon.start()

    # -- the preview
    def _make_preview(self) -> None:
        if self.preview is None or not self.canvas.boxes:
            return
        self._ptoken += 1
        token, im, spec = self._ptoken, self.preview, self.spec()

        def work() -> None:
            try:
                out, mask = rt.erase_image(im, spec)
                self._sig.previewed.emit(token, to_qimage(out), mask_image(mask), int(mask.sum()))
            except Exception:  # noqa: BLE001 — a preview that can't be made just isn't shown
                pass
        threading.Thread(target=work, daemon=True).start()

    def _previewed(self, token: int, result: QImage, mark: QImage, marked: int) -> None:
        if token != self._ptoken:
            return
        self.result, self.mark = result, mark
        if not marked and not self.running:
            self.note.setText("No mark found in the boxes — draw them over it, turn Sensitivity up, or use Whole Box.")
        self._show()

    def _show(self) -> None:
        if self.original is None:
            return
        if self.orig_btn.isChecked():
            self.canvas.image, self.canvas.overlay = self.original, self.mark
        else:
            self.canvas.image, self.canvas.overlay = (self.result or self.original), None
        self.canvas.update()

    # -- the photos
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
                im, w, h = load_preview(path)
                self._sig.loaded.emit(token, im, w, h)
            except Exception as e:  # noqa: BLE001
                self._sig.failed.emit(token, str(e))
        threading.Thread(target=work, daemon=True).start()

    def _loaded(self, token: int, im: "Image.Image", _w: int, _h: int) -> None:
        if token != self._token:
            return
        self.current = self._pending
        self.preview = im
        self.original = to_qimage(im)
        self.canvas.image = self.original
        self._spec_changed()

    def _load_failed(self, token: int, why: str) -> None:
        if token != self._token:
            return
        name = os.path.basename(self.photos[self._pending])
        if self.preview is None:
            self.canvas.message = f"Couldn't open {name}: {why}"
            self.canvas.update()
        else:
            self.where.setText(f"{self._pending + 1} of {len(self.photos)}  ·  couldn't open {name} — {why}")

    def _refresh(self) -> None:
        n = len(self.photos)
        ready = self.preview is not None and not self.running
        has = bool(self.canvas.boxes)
        for b in (self.replace_btn, self.new_btn):
            b.setEnabled(ready and has)
        self.sensitivity.setEnabled(not self.running and self.mark_btn.isChecked())
        self.sens_label.setEnabled(self.sensitivity.isEnabled())
        for b in (self.mark_btn, self.box_btn, self.result_btn, self.orig_btn, self.clear_btn):
            b.setEnabled(not self.running)
        self.last_btn.setEnabled(ready and self.last() is not None)
        self.canvas.setEnabled(not self.running)
        self.prev_btn.setEnabled(not self.running and self.current > 0)
        self.next_btn.setEnabled(not self.running and self.current < n - 1)
        if not self.running:
            self.note.setText(
                ("The same boxes go on every photo — ‹ › to check each. " if n > 1 else "")
                + "Save as New keeps the original; either way the metadata, dates and tags are kept, and the "
                  "result is tagged “retouched”.")

    # -- writing them
    def run(self, as_new: bool) -> None:
        if self.running or self.preview is None or not self.canvas.boxes:
            return
        spec = self.spec()
        self.as_new = as_new
        self.settings.setValue(SAVE_KEY, "new" if as_new else "replace")
        self.settings.setValue(LAST_KEY, spec.to_json())
        self.running = True
        self._stop.clear()
        self._erased, self._none, self._failed = [], 0, []
        self.bar.setValue(0)
        self.bar.show()
        self.cancel_btn.setText("Stop")
        self._refresh()
        self.note.setText("Erasing…")
        photos = list(self.photos)

        def work() -> None:
            for i, path in enumerate(photos):
                if self._stop.is_set():
                    break
                try:
                    self._sig.progress.emit(i, path, "done", rt.erase(spec, path, as_new=as_new))
                except rt.NothingToErase as e:
                    self._sig.progress.emit(i, path, "none", str(e))
                except (bc.CropError, OSError) as e:
                    self._sig.progress.emit(i, path, "failed", str(e))
                except Exception as e:  # noqa: BLE001 — one bad photo never stops the rest
                    self._sig.progress.emit(i, path, "failed", f"{type(e).__name__}: {e}")
            self._sig.done.emit()
        threading.Thread(target=work, daemon=True).start()

    def _progress(self, i: int, path: str, outcome: str, detail: str) -> None:
        if outcome == "done":
            self._erased.append((path, detail))
        elif outcome == "none":
            self._none += 1
        else:
            self._failed.append((path, detail))
        self.bar.setValue(i + 1)
        self.note.setText(f"Erasing {min(i + 2, len(self.photos))} of {len(self.photos)}…")

    def _finished(self) -> None:
        self.running = False
        self.on_done(list(self._erased), self.as_new, self._none, len(self._failed))
        if self._failed:
            lines = "\n".join(f"• {os.path.basename(p)} — {why}" for p, why in self._failed[:12])
            more = f"\n…and {len(self._failed) - 12} more" if len(self._failed) > 12 else ""
            QMessageBox.warning(self, "Some Photos Weren't Changed",
                                f"Erased {len(self._erased)} of {len(self.photos)}. These were left as they "
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
