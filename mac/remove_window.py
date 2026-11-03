"""Safe Finder's Remove Objects window — TouchRetouch on the Mac: draw a lasso around something (or paint over
it) and it's gone, filled in from the photo itself (inpaint.py — the same kind of fill as Photoshop's
Content-Aware Fill). Right-click a photo ▸ Remove Objects…, Photos ▸ Remove Objects…, or ⋯ in the viewer.

- **Lasso** (L): draw round what should go; let go and it's removed (with "Remove as I draw", the default —
  else mark several things and press Remove). **Brush** (B) paints over it instead; **Eraser** (E) takes back
  part of a mark. [ and ] change the brush size.
- **Undo** (⌘Z) / **Redo** (⇧⌘Z), one removal at a time; **Compare** — press and hold the button, or hold
  Space — shows the original; ⌘-scroll or pinch zooms (or − / Fit / +), scrolling pans.
- **Save as New** puts the result beside the photo as "name (retouched).ext"; **Replace Original** writes it
  in place. Either way the format, metadata, dates and tags are kept (batch_crop's saving), and the result is
  tagged "retouched" (Safe Finder's `on_done`). Closing with changes asks first.

The work happens on a worker thread, a bar showing how far it's got; Esc stops it. The mark is kept as a
picture at up to 4096 px (a 48 MP photo's mask at full size would cost 50 MB a stroke) and scaled up for the
removal, which grows it by a couple of pixels anyway. Undo steps hold only the region each removal changed.
"""
from __future__ import annotations

import os
import threading
from typing import Callable

import numpy as np
from PySide6.QtCore import QObject, QPointF, QRectF, QSettings, Qt, QTimer, Signal
from PySide6.QtGui import (QBrush, QColor, QCursor, QImage, QKeySequence, QPainter, QPainterPath, QPen, QPixmap,
                           QShortcut)
from PySide6.QtWidgets import (QButtonGroup, QCheckBox, QDialog, QFrame, QGraphicsEllipseItem, QGraphicsPathItem,
                               QGraphicsPixmapItem, QGraphicsScene, QGraphicsView, QHBoxLayout, QLabel, QMessageBox,
                               QProgressBar, QPushButton, QSlider, QToolButton, QVBoxLayout, QWidget)

import batch_crop
import inpaint
import retouch

MARK = QColor(255, 59, 48, 120)          # the mark: TouchRetouch's red, see-through
OVERLAY_MAX = 4096                       # the mark is kept at up to this many pixels on its long side
SIZE_KEY = "remove/brush"
AUTO_KEY = "remove/auto"


def qimage_rgb(arr: np.ndarray) -> QImage:
    """An (h, w, 3) uint8 array as a QImage (copied)."""
    a = np.ascontiguousarray(arr)
    h, w = a.shape[:2]
    return QImage(a.data, w, h, 3 * w, QImage.Format.Format_RGB888).copy()


class _Signals(QObject):
    loaded = Signal(object, str)          # (source, rgb, alpha) or None, why
    progress = Signal(float)
    removed = Signal(object)              # (y0, x0, patch) or None
    saved = Signal(str, str)              # path written ("" when it failed), why


class _Canvas(QGraphicsView):
    """The photo with the mark over it. Strokes: a lasso (filled when it closes), a brush or an eraser —
    `begin_stroke` / `extend_stroke` / `end_stroke` (in the photo's pixels), which the mouse drives."""
    stroke_done = Signal()

    def __init__(self, parent=None) -> None:
        super().__init__(parent)
        self.setScene(QGraphicsScene(self))
        self.setBackgroundBrush(QColor(28, 28, 30))
        self.setFrameShape(QFrame.Shape.NoFrame)
        self.setRenderHints(QPainter.RenderHint.Antialiasing | QPainter.RenderHint.SmoothPixmapTransform)
        self.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        self.setVerticalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        self.setTransformationAnchor(QGraphicsView.ViewportAnchor.AnchorUnderMouse)
        self.setMouseTracking(True)
        self.photo = QGraphicsPixmapItem()
        self.photo.setTransformationMode(Qt.TransformationMode.SmoothTransformation)
        self.overlay = QGraphicsPixmapItem()
        self.overlay.setZValue(1)
        self.path_item = QGraphicsPathItem()
        self.path_item.setZValue(2)
        pen = QPen(QColor(255, 255, 255), 0)
        pen.setCosmetic(True)
        pen.setWidthF(1.5)
        pen.setStyle(Qt.PenStyle.DashLine)
        self.path_item.setPen(pen)
        self.path_item.setBrush(QBrush(QColor(255, 59, 48, 60)))
        self.ring = QGraphicsEllipseItem()
        self.ring.setZValue(3)
        rp = QPen(QColor(255, 255, 255, 220), 0)
        rp.setCosmetic(True)
        self.ring.setPen(rp)
        self.ring.setVisible(False)
        for it in (self.photo, self.overlay, self.path_item, self.ring):
            self.scene().addItem(it)
        self.tool = "lasso"
        self.brush = 40.0                     # screen points
        self.mask_img: QImage | None = None
        self.mask_scale = 1.0
        self.size_px = (0, 0)
        self.fitted = True
        self.busy = False
        self._points: list[QPointF] = []
        self._last: QPointF | None = None
        self._drawing = False

    # -- the photo and its mark
    def set_photo(self, pm: QPixmap) -> None:
        self.photo.setPixmap(pm)
        w, h = pm.width(), pm.height()
        self.size_px = (w, h)
        self.scene().setSceneRect(QRectF(0, 0, w, h))
        self.mask_scale = min(1.0, OVERLAY_MAX / max(w, h, 1))
        mw, mh = max(1, int(round(w * self.mask_scale))), max(1, int(round(h * self.mask_scale)))
        self.mask_img = QImage(mw, mh, QImage.Format.Format_ARGB32_Premultiplied)
        self.mask_img.fill(Qt.GlobalColor.transparent)
        self.overlay.setScale(1.0 / self.mask_scale)
        self._show_mask()
        self.fit()

    def _show_mask(self) -> None:
        self.overlay.setPixmap(QPixmap.fromImage(self.mask_img) if self.mask_img is not None else QPixmap())

    def clear_mask(self) -> None:
        if self.mask_img is not None:
            self.mask_img.fill(Qt.GlobalColor.transparent)
            self._show_mask()

    def _alpha(self) -> np.ndarray:
        """The mark at its own (overlay) size, bool."""
        m = self.mask_img
        mw, mh = m.width(), m.height()
        arr = np.frombuffer(m.constBits(), np.uint8, count=m.bytesPerLine() * mh).reshape(mh, m.bytesPerLine())
        return arr[:, 3:mw * 4:4] > 0                      # ARGB32 is BGRA in memory on little-endian

    def has_mark(self) -> bool:
        return self.mask_img is not None and bool(self._alpha().any())

    def mask(self) -> np.ndarray:
        """The mark at the photo's own size (bool)."""
        m = self.mask_img
        if m is None:
            return np.zeros((0, 0), bool)
        mw, mh = m.width(), m.height()
        alpha = self._alpha()
        w, h = self.size_px
        if (mw, mh) == (w, h):
            return alpha.copy()
        ys = np.minimum((np.arange(h) * mh) // h, mh - 1)
        xs = np.minimum((np.arange(w) * mw) // w, mw - 1)
        return alpha[ys][:, xs]

    # -- strokes (photo pixels)
    def brush_px(self) -> float:
        return self.brush / max(self.transform().m11(), 1e-6)

    def _painter(self) -> QPainter:
        p = QPainter(self.mask_img)
        p.setRenderHint(QPainter.RenderHint.Antialiasing)
        p.scale(self.mask_scale, self.mask_scale)
        return p

    def begin_stroke(self, pt: QPointF) -> None:
        self._points = [pt]
        self._last = pt
        self._drawing = True
        if self.tool != "lasso":
            self._dab(pt, pt)

    def extend_stroke(self, pt: QPointF) -> None:
        if not self._drawing:
            return
        if self.tool == "lasso":
            self._points.append(pt)
            path = QPainterPath(self._points[0])
            for q in self._points[1:]:
                path.lineTo(q)
            self.path_item.setPath(path)
        else:
            self._dab(self._last or pt, pt)
        self._last = pt

    def _dab(self, a: QPointF, b: QPointF) -> None:
        p = self._painter()
        if self.tool == "erase":
            p.setCompositionMode(QPainter.CompositionMode.CompositionMode_Clear)
        else:
            p.setCompositionMode(QPainter.CompositionMode.CompositionMode_Source)
        pen = QPen(MARK, self.brush_px(), Qt.PenStyle.SolidLine, Qt.PenCapStyle.RoundCap, Qt.PenJoinStyle.RoundJoin)
        p.setPen(pen)
        p.drawLine(a, b)
        p.end()
        self._show_mask()

    def end_stroke(self) -> None:
        if not self._drawing:
            return
        self._drawing = False
        if self.tool == "lasso":
            if len(self._points) >= 3:
                path = QPainterPath(self._points[0])
                for q in self._points[1:]:
                    path.lineTo(q)
                path.closeSubpath()
                p = self._painter()
                p.setCompositionMode(QPainter.CompositionMode.CompositionMode_Source)
                p.setPen(Qt.PenStyle.NoPen)
                p.setBrush(MARK)
                p.drawPath(path)
                p.end()
                self._show_mask()
            self.path_item.setPath(QPainterPath())
        self._points = []
        self.stroke_done.emit()

    # -- zoom
    def fit(self) -> None:
        self.resetTransform()
        w, h = self.size_px
        if w and h:
            r = self.viewport().rect()
            s = min(r.width() / w, r.height() / h)
            self.scale(s, s)
            self.centerOn(self.photo)
        self.fitted = True

    def zoom(self, factor: float) -> None:
        cur = self.transform().m11()
        target = max(0.02, min(cur * factor, 16.0))
        self.scale(target / cur, target / cur)
        self.fitted = False

    def resizeEvent(self, event) -> None:  # noqa: N802
        super().resizeEvent(event)
        if self.fitted:
            self.fit()

    # -- the mouse
    def mousePressEvent(self, event) -> None:  # noqa: N802
        if event.button() == Qt.MouseButton.LeftButton and not self.busy and self.mask_img is not None:
            self.begin_stroke(self.mapToScene(event.position().toPoint()))
            return
        super().mousePressEvent(event)

    def mouseMoveEvent(self, event) -> None:  # noqa: N802
        pt = self.mapToScene(event.position().toPoint())
        if self.tool in ("brush", "erase") and self.mask_img is not None:
            d = self.brush_px()
            self.ring.setRect(QRectF(pt.x() - d / 2, pt.y() - d / 2, d, d))
            self.ring.setVisible(True)
        else:
            self.ring.setVisible(False)
        if self._drawing:
            self.extend_stroke(pt)
            return
        super().mouseMoveEvent(event)

    def mouseReleaseEvent(self, event) -> None:  # noqa: N802
        if self._drawing and event.button() == Qt.MouseButton.LeftButton:
            self.end_stroke()
            return
        super().mouseReleaseEvent(event)

    def leaveEvent(self, event) -> None:  # noqa: N802
        self.ring.setVisible(False)
        super().leaveEvent(event)

    def wheelEvent(self, event) -> None:  # noqa: N802
        if event.modifiers() & (Qt.KeyboardModifier.ControlModifier | Qt.KeyboardModifier.MetaModifier):
            self.zoom(1.0015 ** event.angleDelta().y())
            return
        super().wheelEvent(event)

    def event(self, event) -> bool:
        if event.type() == event.Type.NativeGesture and event.gestureType() == Qt.NativeGestureType.ZoomNativeGesture:
            self.zoom(1.0 + event.value())
            return True
        return super().event(event)


class RemoveWindow(QDialog):
    """`on_done(written, as_new)` runs on the UI thread after a save: the file written, and whether it's a new
    photo beside the original."""

    def __init__(self, parent: QWidget | None, path: str, settings: QSettings,
                 on_done: Callable[[str, bool], None]) -> None:
        super().__init__(parent)
        self.path, self.settings, self.on_done = path, settings, on_done
        self.src = None
        self.rgb: np.ndarray | None = None
        self.alpha: np.ndarray | None = None
        self.original: QPixmap | None = None
        self.current: QPixmap | None = None
        self.undo_stack: list[tuple[int, int, np.ndarray, np.ndarray]] = []
        self.redo_stack: list[tuple[int, int, np.ndarray, np.ndarray]] = []
        self.saved_depth = 0
        self.running = False
        self.saving = False
        self._cancel = threading.Event()
        self._sig = _Signals()
        self._sig.loaded.connect(self._loaded)
        self._sig.progress.connect(self._progress)
        self._sig.removed.connect(self._removed)
        self._sig.saved.connect(self._saved)
        self.setWindowTitle(f"Remove Objects — {os.path.basename(path)}")
        self.resize(1180, 840)
        lay = QVBoxLayout(self)
        lay.setContentsMargins(12, 10, 12, 10)
        lay.setSpacing(8)

        tools = QHBoxLayout()
        self.tool_group = QButtonGroup(self)
        self.lasso_btn = self._seg("Lasso", "Draw round what should go (L)", "lasso")
        self.brush_btn = self._seg("Brush", "Paint over what should go (B)", "brush")
        self.erase_btn = self._seg("Eraser", "Take back part of the mark (E)", "erase")
        self.lasso_btn.setChecked(True)
        for b in (self.lasso_btn, self.brush_btn, self.erase_btn):
            tools.addWidget(b)
        tools.addSpacing(10)
        self.size_label = QLabel("Size")
        tools.addWidget(self.size_label)
        self.size = QSlider(Qt.Orientation.Horizontal)
        self.size.setRange(6, 160)
        try:
            self.size.setValue(int(self.settings.value(SIZE_KEY, 40)))
        except (TypeError, ValueError):
            self.size.setValue(40)
        self.size.setFixedWidth(140)
        self.size.setToolTip("Brush size ([ and ])")
        tools.addWidget(self.size)
        tools.addSpacing(10)
        self.auto = QCheckBox("Remove as I draw")
        self.auto.setChecked(str(self.settings.value(AUTO_KEY, "true")) == "true")
        self.auto.setToolTip("Each mark goes as soon as you let go — off, mark several things and press Remove")
        tools.addWidget(self.auto)
        self.remove_btn = QPushButton("Remove", objectName="Primary")
        self.remove_btn.setAutoDefault(False)
        self.remove_btn.clicked.connect(self.remove_now)
        tools.addWidget(self.remove_btn)
        tools.addStretch(1)
        self.undo_btn = self._tool("Undo", "Undo the last removal (⌘Z)", self.undo)
        self.redo_btn = self._tool("Redo", "Redo (⇧⌘Z)", self.redo)
        self.compare_btn = self._tool("Compare", "Press and hold to see the original (or hold Space)", None)
        self.compare_btn.pressed.connect(lambda: self.compare(True))
        self.compare_btn.released.connect(lambda: self.compare(False))
        for b in (self.undo_btn, self.redo_btn, self.compare_btn):
            tools.addWidget(b)
        tools.addSpacing(10)
        tools.addWidget(self._tool("−", "Zoom out (⌘−)", lambda: self.canvas.zoom(0.8)))
        tools.addWidget(self._tool("Fit", "Fit (⌘0)", lambda: self.canvas.fit()))
        tools.addWidget(self._tool("+", "Zoom in (⌘+)", lambda: self.canvas.zoom(1.25)))
        lay.addLayout(tools)

        self.canvas = _Canvas()
        self.canvas.stroke_done.connect(self._stroke_done)
        lay.addWidget(self.canvas, 1)

        bottom = QHBoxLayout()
        self.note = QLabel("Reading the photo…", objectName="SheetSub")
        bottom.addWidget(self.note, 1)
        self.bar = QProgressBar()
        self.bar.setRange(0, 100)
        self.bar.setFixedWidth(220)
        self.bar.setTextVisible(False)
        self.bar.hide()
        bottom.addWidget(self.bar)
        self.cancel_btn = QPushButton("Close")
        self.cancel_btn.setAutoDefault(False)
        self.cancel_btn.clicked.connect(self.close)
        self.new_btn = QPushButton("Save as New")
        self.new_btn.setAutoDefault(False)
        self.new_btn.setToolTip("Beside the photo, as “… (retouched)” — the original is left as it is")
        self.new_btn.clicked.connect(lambda: self.save(True))
        self.replace_btn = QPushButton("Replace Original", objectName="Primary")
        self.replace_btn.setAutoDefault(False)
        self.replace_btn.clicked.connect(lambda: self.save(False))
        for b in (self.cancel_btn, self.new_btn, self.replace_btn):
            bottom.addWidget(b)
        lay.addLayout(bottom)

        self.size.valueChanged.connect(self._size_changed)
        self.auto.toggled.connect(lambda on: (self.settings.setValue(AUTO_KEY, "true" if on else "false"),
                                              self._refresh()))
        self.tool_group.buttonToggled.connect(lambda *_: self._tool_changed())
        for keys, slot in (("L", lambda: self.lasso_btn.setChecked(True)), ("B", lambda: self.brush_btn.setChecked(True)),
                           ("E", lambda: self.erase_btn.setChecked(True)), ("[", lambda: self.size.setValue(self.size.value() - 6)),
                           ("]", lambda: self.size.setValue(self.size.value() + 6)), ("Ctrl+Z", self.undo),
                           ("Ctrl+Shift+Z", self.redo), ("Ctrl+0", lambda: self.canvas.fit()),
                           ("Ctrl+=", lambda: self.canvas.zoom(1.25)), ("Ctrl+-", lambda: self.canvas.zoom(0.8)),
                           ("Escape", self._escape), ("Return", self.remove_now)):
            QShortcut(QKeySequence(keys), self).activated.connect(slot)
        self._size_changed()
        self._tool_changed()
        self._refresh()
        self._load()

    # ------------------------------------------------------------------ bits
    def _seg(self, text: str, tip: str, tool: str) -> QToolButton:
        b = QToolButton(objectName="Scope")
        b.setText(text)
        b.setToolTip(tip)
        b.setCheckable(True)
        b.setProperty("tool", tool)
        self.tool_group.addButton(b)
        return b

    def _tool(self, text: str, tip: str, slot) -> QPushButton:
        b = QPushButton(text)
        b.setToolTip(tip)
        b.setAutoDefault(False)
        b.setFocusPolicy(Qt.FocusPolicy.NoFocus)
        if slot is not None:
            b.clicked.connect(slot)
        return b

    def _size_changed(self) -> None:
        self.canvas.brush = float(self.size.value())
        self.settings.setValue(SIZE_KEY, self.size.value())

    def _tool_changed(self) -> None:
        b = self.tool_group.checkedButton()
        self.canvas.tool = b.property("tool") if b is not None else "lasso"
        brushy = self.canvas.tool in ("brush", "erase")
        self.size.setEnabled(brushy)
        self.size_label.setEnabled(brushy)
        self.canvas.setCursor(QCursor(Qt.CursorShape.CrossCursor))
        self._refresh()

    @property
    def changed(self) -> bool:
        return len(self.undo_stack) != self.saved_depth

    def _refresh(self) -> None:
        ready = self.rgb is not None and not self.running and not self.saving
        self.canvas.busy = not ready
        self.undo_btn.setEnabled(ready and bool(self.undo_stack))
        self.redo_btn.setEnabled(ready and bool(self.redo_stack))
        self.compare_btn.setEnabled(ready and bool(self.undo_stack))
        self.remove_btn.setVisible(not self.auto.isChecked())
        self.remove_btn.setEnabled(ready and self.canvas.has_mark())
        self.new_btn.setEnabled(ready and bool(self.undo_stack))
        self.replace_btn.setEnabled(ready and bool(self.undo_stack))
        if ready and not self.bar.isVisible():
            hint = {"lasso": "Draw round what should go", "brush": "Paint over what should go",
                    "erase": "Paint over part of the mark to take it back"}[self.canvas.tool]
            self.note.setText(hint + (" — it's removed when you let go." if self.auto.isChecked() and
                                      self.canvas.tool != "erase" else "."))

    # ------------------------------------------------------------------ loading
    def _load(self) -> None:
        sig, path = self._sig, self.path

        def work() -> None:
            try:
                src = batch_crop.open_upright(path)
                im = src.image
                alpha = None
                if im.mode in ("RGBA", "LA", "PA") or (im.mode == "P" and "transparency" in im.info):
                    rgba = np.asarray(im.convert("RGBA"))
                    alpha = rgba[..., 3].copy()
                    rgb = rgba[..., :3].copy()
                else:
                    rgb = np.asarray(im.convert("RGB")).copy()
                sig.loaded.emit((src, rgb, alpha), "")
            except Exception as e:  # noqa: BLE001 — shown, never a crash
                sig.loaded.emit(None, str(e))
        threading.Thread(target=work, daemon=True).start()

    def _loaded(self, got, why: str) -> None:
        if got is None:
            QMessageBox.warning(self, "Remove Objects", f"Couldn't read “{os.path.basename(self.path)}”: {why}")
            self.reject()
            return
        self.src, self.rgb, self.alpha = got
        self.original = QPixmap.fromImage(qimage_rgb(self.rgb))
        self.current = QPixmap(self.original)
        self.canvas.set_photo(self.current)
        self._refresh()

    # ------------------------------------------------------------------ removing
    def _stroke_done(self) -> None:
        if self.auto.isChecked() and self.canvas.tool != "erase":
            self.remove_now()
        else:
            self._refresh()

    def remove_now(self) -> None:
        if self.running or self.rgb is None:
            return
        mask = self.canvas.mask()
        if not mask.any():
            return
        self.running = True
        self._cancel.clear()
        self.bar.setValue(0)
        self.bar.show()
        self.note.setText("Removing…")
        self._refresh()
        rgb, sig, cancel = self.rgb, self._sig, self._cancel

        def work() -> None:
            try:
                region = inpaint.remove_region(rgb, mask, progress=lambda f: sig.progress.emit(f),
                                               cancelled=cancel.is_set)
            except Exception as e:  # noqa: BLE001 — shown, never a crash
                region = ("failed", str(e))
            try:
                sig.removed.emit(region)
            except RuntimeError:                 # the window was closed meanwhile
                pass
        threading.Thread(target=work, daemon=True).start()

    def _progress(self, f: float) -> None:
        self.bar.setValue(int(f * 100))

    def _removed(self, region) -> None:
        self.running = False
        self.bar.hide()
        if isinstance(region, tuple) and region and region[0] == "failed":
            QMessageBox.warning(self, "Remove Objects", f"Couldn't remove it: {region[1]}")
            self._refresh()
            return
        if region is None:                       # stopped
            self.note.setText("Stopped — the photo is as it was.")
            self._refresh()
            return
        y0, x0, patch = region
        before = self.rgb[y0:y0 + patch.shape[0], x0:x0 + patch.shape[1]].copy()
        self._apply(y0, x0, patch)
        self.undo_stack.append((y0, x0, before, patch))
        self.redo_stack.clear()
        self.canvas.clear_mask()
        self._refresh()

    def _apply(self, y0: int, x0: int, patch: np.ndarray) -> None:
        self.rgb[y0:y0 + patch.shape[0], x0:x0 + patch.shape[1]] = patch
        p = QPainter(self.current)
        p.drawImage(x0, y0, qimage_rgb(patch))
        p.end()
        self.canvas.photo.setPixmap(self.current)

    def undo(self) -> None:
        if self.running or not self.undo_stack:
            return
        y0, x0, before, after = self.undo_stack.pop()
        self._apply(y0, x0, before)
        self.redo_stack.append((y0, x0, before, after))
        self._refresh()

    def redo(self) -> None:
        if self.running or not self.redo_stack:
            return
        y0, x0, before, after = self.redo_stack.pop()
        self._apply(y0, x0, after)
        self.undo_stack.append((y0, x0, before, after))
        self._refresh()

    def compare(self, on: bool) -> None:
        if self.original is None:
            return
        self.canvas.photo.setPixmap(self.original if on else self.current)
        self.canvas.overlay.setVisible(not on)

    def keyPressEvent(self, event) -> None:  # noqa: N802
        if event.key() == Qt.Key.Key_Space and not event.isAutoRepeat():
            self.compare(True)
            return
        super().keyPressEvent(event)

    def keyReleaseEvent(self, event) -> None:  # noqa: N802
        if event.key() == Qt.Key.Key_Space and not event.isAutoRepeat():
            self.compare(False)
            return
        super().keyReleaseEvent(event)

    # ------------------------------------------------------------------ saving
    def save(self, as_new: bool) -> None:
        if self.rgb is None or self.running or self.saving or not self.undo_stack:
            return
        self.saving = True
        self.note.setText("Saving…")
        self._refresh()
        src, path, sig = self.src, self.path, self._sig
        rgb, alpha = self.rgb.copy(), self.alpha
        from PIL import Image

        def work() -> None:
            try:
                im = Image.fromarray(rgb, "RGB")
                if alpha is not None:
                    im = Image.fromarray(np.dstack([rgb, alpha]), "RGBA")
                mode = src.image.mode
                if mode in ("L", "1", "I;16", "I") and alpha is None:
                    im = im.convert("L")
                elif mode == "LA":
                    im = im.convert("LA")
                data = batch_crop.encode_like(src, im)
                if as_new:
                    out = batch_crop.write_beside(path, data, retouch.NEW_LABEL)
                else:
                    batch_crop.write_in_place(path, data)
                    out = path
                sig.saved.emit(out, "new" if as_new else "replace")
            except Exception as e:  # noqa: BLE001 — shown, never a crash
                sig.saved.emit("", str(e))
        threading.Thread(target=work, daemon=True).start()

    def _saved(self, out: str, how: str) -> None:
        self.saving = False
        if not out:
            QMessageBox.warning(self, "Remove Objects", f"Couldn't save it: {how}")
            self._refresh()
            return
        self.saved_depth = len(self.undo_stack)
        self.on_done(out, how == "new")
        self.accept()

    # ------------------------------------------------------------------ closing
    def _escape(self) -> None:
        if self.running:
            self._cancel.set()
            self.note.setText("Stopping…")
        elif self.canvas.has_mark():
            self.canvas.clear_mask()
            self._refresh()
        else:
            self.close()

    def ask_to_keep(self) -> str:
        """Closing with changes: "new", "replace", "discard" or "" (stay)."""
        box = QMessageBox(self)
        box.setIcon(QMessageBox.Icon.Question)
        box.setWindowTitle("Remove Objects")
        box.setText("Keep what you removed?")
        box.setInformativeText("Save it as a new photo beside the original, or replace the original.")
        new = box.addButton("Save as New", QMessageBox.ButtonRole.AcceptRole)
        rep = box.addButton("Replace Original", QMessageBox.ButtonRole.AcceptRole)
        discard = box.addButton("Don't Save", QMessageBox.ButtonRole.DestructiveRole)
        box.addButton(QMessageBox.StandardButton.Cancel)
        box.setDefaultButton(new)
        box.exec()
        return {new: "new", rep: "replace", discard: "discard"}.get(box.clickedButton(), "")

    def reject(self) -> None:
        if self.running:
            self._cancel.set()
            return
        if self.saving:
            return
        if self.changed:
            answer = self.ask_to_keep()
            if answer in ("new", "replace"):
                self.save(answer == "new")
                return
            if answer != "discard":
                return
            self.saved_depth = len(self.undo_stack)    # let go of it
        super().reject()

    def closeEvent(self, event) -> None:  # noqa: N802
        if self.running or self.saving or self.changed:
            event.ignore()
            self.reject()
            return
        super().closeEvent(event)
