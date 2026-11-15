"""Photo Browser for Mac's photo editor — the window (photo_edit.py is the arithmetic, photo_text.py the text).

Right-click a photo ▸ Edit Photo…, Photos ▸ Edit Photo… (⌘E), or ⋯ in the viewer. The photo on the left, seven
tabs on the right:

- **Filters** — fifty looks as thumbnails of this photo, with a strength slider.
- **Adjust** — Auto, then light, colour, detail, effects, split toning, eight colour bands, black & white.
  Double-click a slider's name to put it back.
- **Crop** — a box with the usual shapes, turn left / right, flip, straighten.
- **Retouch** — brushes painted on the photo (Smooth, Heal, Whiten, Details, Blur, Lighten, Darken, Red Eye,
  Reshape), and a background blur placed by dragging.
- **Face** — smooth skin; with the People feature's face finder also eyes, teeth and gentle reshaping.
- **Text** — any number of text layers (and emoji as stickers): drag to move, the corner handle to size and
  turn, ready-made styles, the Mac's fonts, colours, outline, shadow, glow, backgrounds.
- **Frame** — border, Polaroid, rounded corners, cinema bars, fit to a shape.

Everything is one `photo_edit.Edit`; every change is an undo step (⌘Z / ⇧⌘Z); **Compare** (hold the button, or
Space) shows the photo before. The picture on screen is a small copy rendered on a worker thread — a quick
rough one while a slider moves, the proper one when it rests — so the window never waits.

**Saving** renders the same edit on every pixel and writes it with batch_crop's saving, so the format (HEIC
stays HEIC, with its colour profile), EXIF, GPS, XMP, file dates and extended attributes are the original's:

- **Save as New** — "name (edited).ext" beside the photo; the original untouched.
- **Overwrite Original** — in place.
- **Save and Upscale…** — either of those, then Real-ESRGAN (Upscayl's engine, ai_upscale.py) on the result:
  the model, 2× / 3× / 4× and how much of the original's texture to keep are asked first.

`on_done(written, as_new, tags)` then lets the app carry the original's tags over and add "edited" (and
"cropped" / "upscaled"). An HDR (PQ / HLG) photo is edited and saved in standard range, and says so.
"""
from __future__ import annotations

import json
import os
import threading
from typing import Callable

import numpy as np
from PIL import Image
from PySide6.QtCore import QObject, QPointF, QRectF, QSize, Qt, QTimer, Signal
from PySide6.QtGui import (QColor, QCursor, QIcon, QImage, QKeySequence, QPainter, QPainterPath, QPen, QPixmap,
                           QPolygonF, QShortcut)
from PySide6.QtWidgets import (QButtonGroup, QCheckBox, QColorDialog, QComboBox, QDialog, QFrame, QGridLayout,
                               QHBoxLayout, QLabel, QListWidget, QMenu, QMessageBox,
                               QPlainTextEdit, QProgressBar, QPushButton, QRadioButton, QScrollArea, QSlider,
                               QStackedWidget, QToolButton, QVBoxLayout, QWidget)

import batch_crop
import photo_edit as pe
import photo_text

PREVIEW = 1280                           # the long side of the picture on screen
DRAFT = 520                              # …and of the rough one shown while a slider moves
THUMB = 220                              # a filter's thumbnail is rendered at this (its long side)
LOOK_ICON = 96                           # …and shown as a square this size
SNAPSHOTS = 12                           # retouch states kept per size, so undoing a stroke is instant
ACCENT = QColor(10, 132, 255)
ASPECTS = [("Freeform", None), ("Original", None), ("1:1", 1.0), ("4:5", 4 / 5), ("5:4", 5 / 4), ("3:4", 3 / 4),
           ("4:3", 4 / 3), ("2:3", 2 / 3), ("3:2", 3 / 2), ("9:16", 9 / 16), ("16:9", 16 / 9), ("2:1", 2.0)]
TABS = ["Filters", "Adjust", "Crop", "Retouch", "Face", "Text", "Frame"]


def qimage_rgb(arr: np.ndarray) -> QImage:
    a = np.ascontiguousarray(arr)
    h, w = a.shape[:2]
    return QImage(a.data, w, h, 3 * w, QImage.Format.Format_RGB888).copy()


def to_u8(arr: np.ndarray) -> np.ndarray:
    return np.clip(arr * 255.0 + 0.5, 0, 255).astype(np.uint8)


class _Signals(QObject):
    loaded = Signal(object, str)
    preview = Signal(int, object, str, bool)        # generation, uint8 rgb, stage, rough?
    thumbs = Signal(int, object)                    # generation, {name: uint8 rgb}
    faces = Signal(object, str)                     # [FaceBox] or None, why
    progress = Signal(float)
    rendered = Signal(object, str)                  # (rgb, alpha) or None, why
    saved = Signal(str, str)                        # path ("" when it failed), why
    failed = Signal(str)


# ----------------------------------------------------------------------------- the worker

class _Renderer:
    """Renders previews on its own thread. Only the newest request matters: one that's overtaken is dropped
    between stages. Each stage's result is kept, so moving a slider re-does only what comes after it."""

    def __init__(self, sig: _Signals) -> None:
        self.sig = sig
        self.cv = threading.Condition()
        self.job: tuple | None = None
        self.alive = True
        self.base: dict[str, np.ndarray] = {}
        self.snaps: dict[str, list[tuple[list, np.ndarray]]] = {"rough": [], "fine": []}
        self.kept: dict[str, dict] = {"rough": {}, "fine": {}}
        self.found: list[pe.FaceBox] = []
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.thread.start()

    def set_photo(self, im: Image.Image) -> None:
        for name, side in (("fine", PREVIEW), ("rough", DRAFT)):
            s = min(1.0, side / max(im.size))
            small = im if s >= 1 else im.resize((max(1, round(im.width * s)), max(1, round(im.height * s))),
                                                Image.Resampling.LANCZOS, reducing_gap=2.0)
            self.base[name] = pe.to_float(small)[0]
            self.snaps[name] = [([], self.base[name])]
            self.kept[name] = {}

    def ask(self, gen: int, edit: pe.Edit, stage: str, rough_first: bool) -> None:
        with self.cv:
            self.job = (gen, edit, stage, rough_first)
            self.cv.notify()

    def stop(self) -> None:
        with self.cv:
            self.alive = False
            self.cv.notify()

    def _waiting(self) -> bool:
        return self.job is not None or not self.alive

    def _run(self) -> None:
        while True:
            with self.cv:
                while self.job is None and self.alive:
                    self.cv.wait()
                if not self.alive:
                    return
                gen, edit, stage, rough_first = self.job
                self.job = None
            try:
                if rough_first:
                    self.sig.preview.emit(gen, self.render("rough", edit, stage), stage, True)
                    if self._waiting():
                        continue
                self.sig.preview.emit(gen, self.render("fine", edit, stage), stage, False)
            except Exception as e:  # noqa: BLE001 — a preview that can't be made is said, never a crash
                self.sig.failed.emit(f"{type(e).__name__}: {e}")

    def _retouched(self, size: str, e: pe.Edit) -> np.ndarray:
        snaps = self.snaps[size]
        best = max((s for s in snaps if s[0] == e.strokes[:len(s[0])]), key=lambda s: len(s[0]))
        arr, done = best[1], len(best[0])
        for i in range(done, len(e.strokes)):
            arr = arr.copy()
            pe.apply_stroke(arr, e.strokes[i])
            snaps.append((list(e.strokes[:i + 1]), arr))
        if len(snaps) > SNAPSHOTS:
            del snaps[1:len(snaps) - SNAPSHOTS + 1]
        face = tuple(sorted((k, v) for k, v in e.face.items() if v))
        if not face:
            return arr
        kept = self.kept[size].get("face")
        if kept is not None and kept[0] is arr and kept[1] == face and kept[2] == len(self.found):
            return kept[3]
        out = arr.copy()
        pe.apply_face(out, self.found, e.face)
        self.kept[size]["face"] = (arr, face, len(self.found), out)
        return out

    def render(self, size: str, e: pe.Edit, stage: str) -> np.ndarray:
        """`stage`: "final"; "nocrop" (the Crop tab: the whole photo under the box, no frame); "noframe"
        (the brushes: what they paint on); "before" (Compare: turned and cropped, nothing else)."""
        kept = self.kept[size]
        if stage == "before":
            return to_u8(pe.apply_geometry(self.base[size], e.geometry))
        a = self._retouched(size, e)
        cropped = stage != "nocrop"
        gkey = (json.dumps(pe.asdict(e.geometry)), cropped)
        k = kept.get("geo")
        if k is not None and k[0] is a and k[1] == gkey:
            g = k[2]
        else:
            g = a if (e.geometry.plain() or (not cropped and not (e.geometry.quarters % 4 or e.geometry.flip_h
                      or e.geometry.flip_v or abs(e.geometry.straighten) > 0.01))) \
                else pe.apply_geometry(a, e.geometry, cropped)
            kept["geo"] = (a, gkey, g)
        tkey = json.dumps([e.look, e.look_amount, e.adjust, pe.asdict(e.focus), e.seed], sort_keys=True)
        k = kept.get("tone")
        if k is not None and k[0] is g and k[1] == tkey:
            t = k[2]
        else:
            t = pe.toned(g, e)
            kept["tone"] = (g, tkey, t)
        if stage == "final" and e.frame.kind:
            t = pe.apply_frame(t, e.frame)
        return to_u8(t)

    def thumbs(self, gen: int, e: pe.Edit) -> None:
        """Every look on a small copy of the photo as it is turned and cropped — on a thread of its own."""
        base = self.base.get("rough")
        if base is None:
            return

        def work() -> None:
            try:
                g = pe.apply_geometry(base, e.geometry)
                s = THUMB / max(g.shape[:2])
                small = pe.resize(g, max(1, round(g.shape[1] * s)), max(1, round(g.shape[0] * s)), Image.Resampling.BOX)
                out = {"": to_u8(small)}
                for look in pe.LOOKS:
                    out[look.name] = to_u8(pe.apply_look(small, look.name))
                self.sig.thumbs.emit(gen, out)
            except Exception:  # noqa: BLE001 — thumbnails are a nicety
                pass
        threading.Thread(target=work, daemon=True).start()


# ----------------------------------------------------------------------------- small widgets

class SliderRow(QWidget):
    """A named slider with its number. `moved(value, resting)`: resting is False while it's being dragged.
    Double-click the name to put it back to its resting value."""
    moved = Signal(int, bool)
    grabbed = Signal()

    def __init__(self, name: str, lo: int, hi: int, rest: int = 0, suffix: str = "") -> None:
        super().__init__()
        self.rest, self.suffix = rest, suffix
        lay = QGridLayout(self)
        lay.setContentsMargins(0, 0, 0, 0)
        lay.setVerticalSpacing(0)
        self.name = QLabel(name)
        self.name.setToolTip("Double-click to reset")
        self.number = QLabel(objectName="SheetSub")
        self.number.setAlignment(Qt.AlignmentFlag.AlignRight | Qt.AlignmentFlag.AlignVCenter)
        self.slider = QSlider(Qt.Orientation.Horizontal)
        self.slider.setRange(lo, hi)
        self.slider.setValue(rest)
        self.slider.setFocusPolicy(Qt.FocusPolicy.NoFocus)
        lay.addWidget(self.name, 0, 0)
        lay.addWidget(self.number, 0, 1)
        lay.addWidget(self.slider, 1, 0, 1, 2)
        self.slider.sliderPressed.connect(self.grabbed)
        self.slider.valueChanged.connect(self._changed)
        self.slider.sliderReleased.connect(lambda: self.moved.emit(self.slider.value(), True))
        self.name.mouseDoubleClickEvent = lambda _e: self.reset()
        self._show()

    def _show(self) -> None:
        v = self.slider.value()
        self.number.setText(f"{v:+d}{self.suffix}" if self.slider.minimum() < 0 else f"{v}{self.suffix}")
        self.name.setStyleSheet("" if v == self.rest else "font-weight: 600;")

    def _changed(self, v: int) -> None:
        self._show()
        if not self.signalsBlocked():
            if not self.slider.isSliderDown():
                self.grabbed.emit()
            self.moved.emit(v, not self.slider.isSliderDown())

    def reset(self) -> None:
        if self.slider.value() != self.rest:
            self.slider.setValue(self.rest)

    def value(self) -> int:
        return self.slider.value()

    def set(self, v: float) -> None:
        """Shows a value without announcing it (the edit changed by other means — undo, a reset)."""
        self.blockSignals(True)
        self.slider.blockSignals(True)
        self.slider.setValue(int(round(v)))
        self.slider.blockSignals(False)
        self.blockSignals(False)
        self._show()


class Swatches(QWidget):
    """A row of colour dots and a "…" for any other colour. `picked(hex)`."""
    picked = Signal(str)

    def __init__(self, colours: list[str], per_row: int = 14) -> None:
        super().__init__()
        self.current = ""
        lay = QGridLayout(self)
        lay.setContentsMargins(0, 0, 0, 0)
        lay.setSpacing(3)
        self.buttons: list[QToolButton] = []
        for i, c in enumerate(colours):
            b = QToolButton()
            b.setFixedSize(20, 20)
            b.setProperty("colour", c)
            b.setToolTip(c)
            b.clicked.connect(lambda _=False, c=c: self._pick(c))
            self.buttons.append(b)
            lay.addWidget(b, i // per_row, i % per_row)
        more = QToolButton()
        more.setText("…")
        more.setFixedSize(20, 20)
        more.setToolTip("Any colour…")
        more.clicked.connect(self._other)
        lay.addWidget(more, len(colours) // per_row, len(colours) % per_row)
        self.show_current("")

    def show_current(self, colour: str) -> None:
        self.current = (colour or "").lower()
        for b in self.buttons:
            c = b.property("colour")
            ring = "2px solid #0a84ff" if c.lower() == self.current else "1px solid rgba(128,128,128,0.6)"
            b.setStyleSheet(f"QToolButton {{ background: {c}; border: {ring}; border-radius: 10px; }}")

    def _pick(self, colour: str) -> None:
        self.show_current(colour)
        self.picked.emit(colour)

    def _other(self) -> None:
        c = QColorDialog.getColor(QColor(self.current or "#ffffff"), self.window(), "Colour")
        if c.isValid():
            self._pick(c.name())


def _seg(text: str, group: QButtonGroup, tip: str = "", key=None) -> QToolButton:
    b = QToolButton(objectName="Scope")
    b.setText(text)
    b.setCheckable(True)
    b.setToolTip(tip)
    b.setFocusPolicy(Qt.FocusPolicy.NoFocus)
    b.setProperty("key", key if key is not None else text)
    group.addButton(b)
    return b


def _plain(text: str, slot=None, tip: str = "") -> QPushButton:
    b = QPushButton(text)
    b.setAutoDefault(False)
    b.setFocusPolicy(Qt.FocusPolicy.NoFocus)
    b.setToolTip(tip)
    if slot is not None:
        b.clicked.connect(slot)
    return b


def _head(text: str) -> QLabel:
    lab = QLabel(text)
    lab.setStyleSheet("font-weight: 600; margin-top: 8px;")
    return lab


def _scrolling(inner: QWidget) -> QScrollArea:
    area = QScrollArea()
    area.setWidgetResizable(True)
    area.setFrameShape(QFrame.Shape.NoFrame)
    area.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
    area.setWidget(inner)
    return area


# ----------------------------------------------------------------------------- the canvas

class Canvas(QWidget):
    """The photo, and whatever the open tab draws over it: the crop box, the brush, the text layers' frames,
    the blur's ring. Positions are handed to the window as fractions of the picture shown."""

    def __init__(self, win: "EditorWindow") -> None:
        super().__init__()
        self.win = win
        self.pix: QPixmap | None = None
        self.zoomf = 1.0
        self.centre = QPointF(0.5, 0.5)                 # the part of the picture at the middle of the view
        self.mode = "view"
        self.drag: dict | None = None
        self.hover: QPointF | None = None
        self.stroke: list[tuple[float, float]] = []
        self.crop = pe.FULL
        self.setMouseTracking(True)
        self.setFocusPolicy(Qt.FocusPolicy.ClickFocus)
        self.setMinimumSize(360, 300)

    # -- geometry
    def target(self) -> QRectF:
        if self.pix is None or self.pix.isNull():
            return QRectF()
        m = 18.0
        pw, ph = float(self.pix.width()), float(self.pix.height())
        s = min((self.width() - 2 * m) / pw, (self.height() - 2 * m) / ph) * self.zoomf
        w, h = pw * s, ph * s
        return QRectF(self.width() / 2 - self.centre.x() * w, self.height() / 2 - self.centre.y() * h, w, h)

    def frac(self, pos: QPointF) -> tuple[float, float]:
        t = self.target()
        if t.isEmpty():
            return 0.5, 0.5
        return (pos.x() - t.x()) / t.width(), (pos.y() - t.y()) / t.height()

    def fit(self) -> None:
        self.zoomf, self.centre = 1.0, QPointF(0.5, 0.5)
        self.update()

    def zoom(self, factor: float, at: QPointF | None = None) -> None:
        before = self.frac(at) if at is not None else None
        self.zoomf = float(np.clip(self.zoomf * factor, 1.0, 12.0))
        if self.zoomf <= 1.001:
            self.centre = QPointF(0.5, 0.5)
        elif before is not None:
            t = self.target()
            self.centre = QPointF(before[0] - (at.x() - self.width() / 2) / t.width(),
                                  before[1] - (at.y() - self.height() / 2) / t.height())
        self._keep_in()
        self.update()

    def _keep_in(self) -> None:
        half = 0.5 / self.zoomf
        self.centre = QPointF(float(np.clip(self.centre.x(), half, 1 - half)), float(np.clip(self.centre.y(), half, 1 - half)))

    def set_pixmap(self, pix: QPixmap) -> None:
        self.pix = pix
        self.update()

    # -- events
    def wheelEvent(self, e) -> None:  # noqa: N802
        d = e.angleDelta()
        if e.modifiers() & (Qt.KeyboardModifier.ControlModifier | Qt.KeyboardModifier.MetaModifier):
            self.zoom(1.0 + d.y() / 600.0, e.position())
        elif self.zoomf > 1.001:
            t = self.target()
            px = e.pixelDelta() if not e.pixelDelta().isNull() else d / 4
            self.centre = QPointF(self.centre.x() - px.x() / t.width(), self.centre.y() - px.y() / t.height())
            self._keep_in()
            self.update()

    def event(self, e) -> bool:
        if e.type() == e.Type.NativeGesture and e.gestureType() == Qt.NativeGestureType.ZoomNativeGesture:
            self.zoom(1.0 + e.value(), e.position())
            return True
        return super().event(e)

    def mousePressEvent(self, e) -> None:  # noqa: N802
        if self.pix is None or e.button() != Qt.MouseButton.LeftButton:
            return
        u, v = self.frac(e.position())
        self.drag = self.win.press(self.mode, u, v, e.position(), self)
        if self.drag is None and self.zoomf > 1.001:
            self.drag = {"kind": "pan", "at": e.position(), "centre": QPointF(self.centre)}
        self.update()

    def mouseMoveEvent(self, e) -> None:  # noqa: N802
        self.hover = e.position()
        if self.drag is not None:
            if self.drag["kind"] == "pan":
                t = self.target()
                d = e.position() - self.drag["at"]
                self.centre = QPointF(self.drag["centre"].x() - d.x() / t.width(), self.drag["centre"].y() - d.y() / t.height())
                self._keep_in()
            else:
                u, v = self.frac(e.position())
                self.win.drag(self.drag, u, v, self)
        elif self.mode in ("crop", "text"):
            self.setCursor(self.win.cursor_for(self.mode, *self.frac(e.position()), e.position(), self))
        self.update()

    def mouseReleaseEvent(self, e) -> None:  # noqa: N802
        if self.drag is not None and self.drag["kind"] != "pan":
            self.win.release(self.drag, *self.frac(e.position()), self)
        self.drag = None
        self.update()

    def mouseDoubleClickEvent(self, e) -> None:  # noqa: N802
        if self.mode == "text":
            self.win.text_double_click(*self.frac(e.position()))

    def leaveEvent(self, _e) -> None:  # noqa: N802
        self.hover = None
        self.update()

    # -- drawing
    def paintEvent(self, _e) -> None:  # noqa: N802
        p = QPainter(self)
        p.fillRect(self.rect(), QColor(20, 20, 22))
        if self.pix is None or self.pix.isNull():
            p.setPen(QColor(150, 150, 155))
            p.drawText(self.rect(), Qt.AlignmentFlag.AlignCenter, self.win.wait_text)
            return
        t = self.target()
        p.setRenderHint(QPainter.RenderHint.SmoothPixmapTransform)
        p.setRenderHint(QPainter.RenderHint.Antialiasing)
        p.drawPixmap(t, self.pix, QRectF(self.pix.rect()))
        self.win.paint_over(p, t, self)
        p.end()


# ----------------------------------------------------------------------------- Save and Upscale: the options

class UpscaleChoice(QDialog):
    """What "Save and Upscale…" asks: keep or replace the original, the model, how many times larger, and how
    much of the photo's own texture to keep. `result_choice()` is (as_new, model, factor, texture) or None."""

    def __init__(self, parent: QWidget, engine, size: tuple[int, int], settings) -> None:
        super().__init__(parent)
        import ai_upscale as au
        self.au, self.engine, self.size_px, self.settings = au, engine, size, settings
        self._ok = False
        self.setWindowTitle("Save and Upscale")
        self.setMinimumWidth(460)
        lay = QVBoxLayout(self)
        lay.setContentsMargins(20, 18, 20, 16)
        lay.setSpacing(9)
        lay.addWidget(QLabel("Save and Upscale", objectName="SheetTitle"))
        sub = QLabel(f"The edited photo is saved, then enlarged with {engine.describe()} — Upscayl's engine, on "
                     "this Mac; nothing is uploaded.", objectName="SheetSub")
        sub.setWordWrap(True)
        lay.addWidget(sub)
        self.as_new = QRadioButton("Save as a new photo — “name (edited)”, the original left as it is")
        self.replace = QRadioButton("Overwrite the original")
        (self.as_new if str(settings.value("editor/upscale_how", "new")) != "replace" else self.replace).setChecked(True)
        lay.addWidget(self.as_new)
        lay.addWidget(self.replace)
        lay.addWidget(_head("Model"))
        self.model = QComboBox()
        models = au.photo_models(engine)
        last = str(settings.value("upscale/model") or "") or (au.pick_model(models) or "")
        for m in models:
            self.model.addItem(au.model_label(m), m)
        if last in models:
            self.model.setCurrentIndex(models.index(last))
        self.model.setEnabled(len(models) > 1)
        lay.addWidget(self.model)
        lay.addWidget(_head("Size"))
        row = QHBoxLayout()
        self.factors = QButtonGroup(self)
        try:
            was = int(settings.value("editor/upscale_factor", 2))
        except (TypeError, ValueError):
            was = 2
        for f in (2, 3, 4):
            b = _seg(f"{f}×", self.factors, key=f)
            b.setChecked(f == was)
            row.addWidget(b)
        row.addStretch(1)
        lay.addLayout(row)
        self.outcome = QLabel(objectName="SheetSub")
        self.outcome.setWordWrap(True)
        lay.addWidget(self.outcome)
        try:
            tex = float(settings.value("upscale/texture", 0.25))
        except (TypeError, ValueError):
            tex = 0.25
        self.texture = SliderRow("Texture kept from the photo", 0, 60, 0, "%")
        self.texture.set(tex * 100)
        self.texture.setToolTip("Real-ESRGAN smooths as it sharpens. This blends some of the plain enlargement back in, "
                                "so skin and fabric keep their grain.")
        lay.addWidget(self.texture)
        row = QHBoxLayout()
        row.addStretch(1)
        row.addWidget(_plain("Cancel", self.reject))
        self.go = QPushButton("Save and Upscale", objectName="Primary")
        self.go.clicked.connect(self._accept)
        row.addWidget(self.go)
        lay.addLayout(row)
        self.factors.buttonToggled.connect(lambda *_: self._show())
        self._show()

    def factor(self) -> int:
        b = self.factors.checkedButton()
        return int(b.property("key")) if b is not None else 2

    def _show(self) -> None:
        w, h = self.size_px
        f = self.factor()
        why = self.au.too_large(w, h, "JPEG", f)
        text = f"{w:,} × {h:,} becomes {w * f:,} × {h * f:,} ({w * f * h * f / 1e6:.0f} MP)."
        if w * h > self.au.MAX_PIXELS:
            text += " A photo this large goes through in tiles and takes a while."
        if why:
            text = f"Too large at {f}× — {why}."
        self.outcome.setText(text)
        self.go.setEnabled(not why)

    def _accept(self) -> None:
        self._ok = True
        self.settings.setValue("editor/upscale_how", "new" if self.as_new.isChecked() else "replace")
        self.settings.setValue("editor/upscale_factor", self.factor())
        self.settings.setValue("upscale/model", self.model.currentData() or "")
        self.settings.setValue("upscale/texture", self.texture.value() / 100.0)
        self.accept()

    def result_choice(self) -> tuple[bool, str, int, float] | None:
        if not self._ok:
            return None
        return self.as_new.isChecked(), str(self.model.currentData() or ""), self.factor(), self.texture.value() / 100.0


# ----------------------------------------------------------------------------- the window

class EditorWindow(QDialog):
    """`on_done(written, as_new, tags)` runs on the UI thread once the photo is saved (and upscaled, when
    that was asked)."""

    def __init__(self, parent: QWidget | None, path: str, settings,
                 on_done: Callable[[str, bool, list[str]], None]) -> None:
        super().__init__(parent)
        self.path, self.settings, self.on_done = path, settings, on_done
        self.src: batch_crop.Source | None = None
        self.size_px = (0, 0)                       # the original, upright
        self.edit = pe.Edit()
        self._undo: list[dict] = []
        self._redo: list[dict] = []
        self.gen = 0
        self.comparing = False
        self.saving = False
        self.hdr = False
        self.gain = ""                              # "" no gain map | "kept" | why it can't be kept here
        self.said = ""                              # a word for the app's toast after saving ("HDR kept")
        self.sel = -1                               # the selected text layer
        self.wait_text = "Reading the photo…"
        self._typing_at = 0.0
        self._thumb_key = None
        self._faces_asked = False
        self._pending: dict | None = None           # the save under way
        self._cancel = threading.Event()
        self._sig = _Signals()
        self._sig.loaded.connect(self._loaded)
        self._sig.preview.connect(self._preview)
        self._sig.thumbs.connect(self._thumbs)
        self._sig.faces.connect(self._faces)
        self._sig.progress.connect(lambda f: self.bar.setValue(int(f * 100)))
        self._sig.rendered.connect(self._rendered)
        self._sig.saved.connect(self._saved)
        self._sig.failed.connect(lambda why: self.note.setText(f"Couldn't draw the preview: {why}"))
        self.renderer = _Renderer(self._sig)
        self.setWindowTitle(f"Edit Photo — {os.path.basename(path)}")
        self.setWindowFlag(Qt.WindowType.WindowMaximizeButtonHint, True)
        self.resize(1320, 860)
        self._build()
        self._refresh()
        self._load()

    # ------------------------------------------------------------------ building
    def _build(self) -> None:
        root = QHBoxLayout(self)
        root.setContentsMargins(0, 0, 0, 0)
        root.setSpacing(0)
        left = QVBoxLayout()
        left.setContentsMargins(0, 0, 0, 0)
        left.setSpacing(0)
        self.canvas = Canvas(self)
        left.addWidget(self.canvas, 1)
        bar = QHBoxLayout()
        bar.setContentsMargins(12, 8, 12, 10)
        self.undo_btn = _plain("Undo", self.undo, "⌘Z")
        self.redo_btn = _plain("Redo", self.redo, "⇧⌘Z")
        self.reset_btn = _plain("Reset All", self.reset_all, "Back to the photo as it was")
        self.compare_btn = _plain("Compare", None, "Press and hold to see the photo before (or hold Space)")
        self.compare_btn.pressed.connect(lambda: self.compare(True))
        self.compare_btn.released.connect(lambda: self.compare(False))
        for b in (self.undo_btn, self.redo_btn, self.reset_btn, self.compare_btn):
            bar.addWidget(b)
        bar.addSpacing(8)
        self.note = QLabel("", objectName="SheetSub")
        bar.addWidget(self.note, 1)
        self.bar = QProgressBar()
        self.bar.setRange(0, 100)
        self.bar.setFixedWidth(180)
        self.bar.setTextVisible(False)
        self.bar.hide()
        bar.addWidget(self.bar)
        bar.addWidget(_plain("−", lambda: self.canvas.zoom(0.8), "Zoom out (⌘−)"))
        bar.addWidget(_plain("Fit", self.canvas.fit, "Fit (⌘0)"))
        bar.addWidget(_plain("+", lambda: self.canvas.zoom(1.25), "Zoom in (⌘+) — ⌘-scroll or pinch too"))
        left.addLayout(bar)
        root.addLayout(left, 1)

        side = QWidget()
        side.setFixedWidth(420)
        s = QVBoxLayout(side)
        s.setContentsMargins(12, 12, 12, 12)
        s.setSpacing(8)
        tabs = QHBoxLayout()
        tabs.setSpacing(2)
        self.tab_group = QButtonGroup(self)
        for i, name in enumerate(TABS):
            b = _seg(name, self.tab_group, key=i)
            b.setStyleSheet("padding-left: 3px; padding-right: 3px;")       # seven of them in one row
            b.setMinimumWidth(b.fontMetrics().horizontalAdvance(name) + 14)
            tabs.addWidget(b, 1)
        s.addLayout(tabs)
        self.stack = QStackedWidget()
        for make in (self._filters_tab, self._adjust_tab, self._crop_tab, self._retouch_tab, self._face_tab,
                     self._text_tab, self._frame_tab):
            self.stack.addWidget(make())
        s.addWidget(self.stack, 1)
        self.save_note = QLabel("", objectName="SheetSub")
        self.save_note.setWordWrap(True)
        s.addWidget(self.save_note)
        self.new_btn = QPushButton("Save as New", objectName="Primary")
        self.new_btn.setToolTip("Beside the photo, as “… (edited)” — the original is left as it is (⌘S)")
        self.new_btn.clicked.connect(lambda: self.save(True))
        self.over_btn = _plain("Overwrite Original", lambda: self.save(False), "Writes the edit over the photo, in place")
        self.up_btn = _plain("Save and Upscale…", self.save_and_upscale,
                             "Saves the edit, then enlarges it with Real-ESRGAN (Upscayl's engine) — model and size asked first")
        self.close_btn = _plain("Close", self.close)
        row = QHBoxLayout()
        row.addWidget(self.over_btn)
        row.addWidget(self.new_btn)
        s.addLayout(row)
        row = QHBoxLayout()
        row.addWidget(self.close_btn)
        row.addWidget(self.up_btn)
        s.addLayout(row)
        for b in (self.new_btn, self.over_btn, self.up_btn, self.close_btn):
            b.setAutoDefault(False)
        root.addWidget(side)

        self.tab_group.buttonToggled.connect(lambda b, on: on and self._tab_changed(int(b.property("key"))))
        self.tab_group.buttons()[int(self.settings.value("editor/tab", 0) or 0) % len(TABS)].setChecked(True)
        for keys, slot in (("Ctrl+Z", self.undo), ("Ctrl+Shift+Z", self.redo), ("Ctrl+0", self.canvas.fit),
                           ("Ctrl+=", lambda: self.canvas.zoom(1.25)), ("Ctrl+-", lambda: self.canvas.zoom(0.8)),
                           ("Ctrl+S", lambda: self.save(True)),
                           ("[", lambda: self.brush_size.slider.setValue(self.brush_size.value() - 2)),
                           ("]", lambda: self.brush_size.slider.setValue(self.brush_size.value() + 2))):
            QShortcut(QKeySequence(keys), self).activated.connect(slot)

    # -- Filters
    def _filters_tab(self) -> QWidget:
        w = QWidget()
        lay = QVBoxLayout(w)
        lay.setContentsMargins(0, 0, 0, 0)
        self.look_amount = SliderRow("Strength", 0, 100, 100, "%")
        self.look_amount.set(100)
        self.look_amount.grabbed.connect(self.begin)
        self.look_amount.moved.connect(self._look_amount)
        lay.addWidget(self.look_amount)
        self.look_group = QComboBox()
        self.look_group.addItem(f"All {len(pe.LOOKS)} Filters", "")
        for g in pe.LOOK_GROUPS:
            self.look_group.addItem(g, g)
        self.look_group.currentIndexChanged.connect(self._fill_looks)
        lay.addWidget(self.look_group)
        holder = QWidget()
        self.look_grid = QGridLayout(holder)
        self.look_grid.setContentsMargins(0, 0, 8, 0)
        self.look_grid.setSpacing(4)
        self.look_grid.setAlignment(Qt.AlignmentFlag.AlignTop | Qt.AlignmentFlag.AlignLeft)
        self.look_buttons: dict[str, QToolButton] = {}
        self.look_pick = QButtonGroup(self)
        for name in [""] + [look.name for look in pe.LOOKS]:
            b = QToolButton()
            b.setText(name or "Original")
            b.setCheckable(True)
            b.setAutoRaise(True)
            b.setToolButtonStyle(Qt.ToolButtonStyle.ToolButtonTextUnderIcon)
            b.setIconSize(QSize(LOOK_ICON, LOOK_ICON))
            b.setFixedSize(LOOK_ICON + 14, LOOK_ICON + 34)
            b.setFocusPolicy(Qt.FocusPolicy.NoFocus)
            b.setStyleSheet("QToolButton { padding: 3px; border: 2px solid transparent; border-radius: 8px; font-size: 11px; }"
                            "QToolButton:checked { border-color: #0a84ff; }")
            look = pe.look_named(name)
            b.setToolTip(f"{look.group}: {name}" if look else "The photo without a filter")
            b.clicked.connect(lambda _=False, name=name: self._look_clicked(name))
            self.look_pick.addButton(b)
            self.look_buttons[name] = b
        self.look_buttons[""].setChecked(True)
        lay.addWidget(_scrolling(holder), 1)
        self._fill_looks()
        return w

    def _fill_looks(self) -> None:
        group = self.look_group.currentData()
        for b in self.look_buttons.values():
            self.look_grid.removeWidget(b)
            b.hide()
        shown = [""] + [look.name for look in pe.LOOKS if not group or look.group == group]
        for i, name in enumerate(shown):
            self.look_grid.addWidget(self.look_buttons[name], i // 3, i % 3)
            self.look_buttons[name].show()

    def _thumbs(self, gen: int, pics: dict) -> None:
        for name, arr in pics.items():
            b = self.look_buttons.get(name)
            if b is not None:
                h, w = arr.shape[:2]                       # the middle square of it
                side = min(h, w)
                y0, x0 = (h - side) // 2, (w - side) // 2
                b.setIcon(QIcon(QPixmap.fromImage(qimage_rgb(arr[y0:y0 + side, x0:x0 + side]))))

    def _look_clicked(self, name: str) -> None:
        if name == self.edit.look:
            return
        self.begin()
        self.edit.look = name
        self.request()

    def _look_amount(self, v: int, resting: bool) -> None:
        self.edit.look_amount = float(v)
        if self.edit.look:
            self.request(rough=not resting)

    # -- Adjust
    def _adjust_tab(self) -> QWidget:
        inner = QWidget()
        lay = QVBoxLayout(inner)
        lay.setContentsMargins(0, 0, 8, 0)
        lay.setSpacing(4)
        row = QHBoxLayout()
        row.addWidget(_plain("Auto", self._auto, "Levels, mid-tones and colour cast set from the photo itself"))
        row.addWidget(_plain("Reset Adjustments", self._reset_adjust))
        row.addStretch(1)
        lay.addLayout(row)
        self.sliders: dict[str, SliderRow] = {}
        for group, rows in pe.SLIDERS:
            lay.addWidget(_head(group))
            for key, name, lo, hi in rows:
                r = SliderRow(name, lo, hi)
                r.grabbed.connect(self.begin)
                r.moved.connect(lambda v, resting, key=key: self._adjusted(key, v, resting))
                self.sliders[key] = r
                lay.addWidget(r)
        lay.addWidget(_head("Colour Bands"))
        row = QHBoxLayout()
        row.setSpacing(3)
        self.band_group = QButtonGroup(self)
        for name, centre, _w in pe.BANDS:
            b = QToolButton()
            b.setCheckable(True)
            b.setFixedSize(26, 26)
            b.setToolTip(name.capitalize())
            b.setProperty("key", name)
            c = QColor.fromHsvF(centre / 360.0, 0.85, 0.95).name()
            b.setStyleSheet(f"QToolButton {{ background: {c}; border: 1px solid rgba(128,128,128,0.6); border-radius: 13px; }}"
                            "QToolButton:checked { border: 3px solid #0a84ff; }")
            self.band_group.addButton(b)
            row.addWidget(b)
        row.addStretch(1)
        self.band_group.buttons()[0].setChecked(True)
        self.band_group.buttonToggled.connect(lambda *_: self._show_band())
        lay.addLayout(row)
        self.band_rows = []
        for i, name in enumerate(("Hue", "Saturation", "Lightness")):
            r = SliderRow(name, -100, 100)
            r.grabbed.connect(self.begin)
            r.moved.connect(lambda v, resting, i=i: self._band_moved(i, v, resting))
            self.band_rows.append(r)
            lay.addWidget(r)
        lay.addWidget(_head("Black & White"))
        self.mono = QCheckBox("Black and white")
        self.mono.toggled.connect(self._mono)
        lay.addWidget(self.mono)
        lay.addStretch(1)
        return _scrolling(inner)

    def _adjusted(self, key: str, v: int, resting: bool) -> None:
        if v:
            self.edit.adjust[key] = v
        else:
            self.edit.adjust.pop(key, None)
        self.request(rough=not resting)

    def _band(self) -> str:
        b = self.band_group.checkedButton()
        return str(b.property("key")) if b is not None else pe.BAND_NAMES[0]

    def _show_band(self) -> None:
        vals = (self.edit.adjust.get("hsl") or {}).get(self._band()) or (0, 0, 0)
        for r, v in zip(self.band_rows, vals):
            r.set(v)

    def _band_moved(self, i: int, v: int, resting: bool) -> None:
        hsl = self.edit.adjust.setdefault("hsl", {})
        vals = list(hsl.get(self._band()) or (0, 0, 0))
        vals[i] = v
        if any(vals):
            hsl[self._band()] = vals
        else:
            hsl.pop(self._band(), None)
        if not hsl:
            self.edit.adjust.pop("hsl", None)
        self.request(rough=not resting)

    def _mono(self, on: bool) -> None:
        if bool(self.edit.adjust.get("mono")) == on:
            return
        self.begin()
        if on:
            self.edit.adjust["mono"] = 1
        else:
            self.edit.adjust.pop("mono", None)
        self.request()

    def _auto(self) -> None:
        base = self.renderer.base.get("rough")
        if base is None:
            return
        self.begin()
        for key in ("whites", "blacks", "brightness", "temperature", "tint", "vibrance"):
            self.edit.adjust.pop(key, None)
        self.edit.adjust.update(pe.auto_adjust(pe.apply_geometry(base, self.edit.geometry)))
        self._sync()
        self.request()

    def _reset_adjust(self) -> None:
        if not self.edit.adjust:
            return
        self.begin()
        self.edit.adjust = {}
        self._sync()
        self.request()

    # -- Crop
    def _crop_tab(self) -> QWidget:
        w = QWidget()
        lay = QVBoxLayout(w)
        lay.setContentsMargins(0, 0, 0, 0)
        lay.addWidget(_head("Shape"))
        grid = QGridLayout()
        grid.setSpacing(4)
        self.aspect_group = QButtonGroup(self)
        for i, (name, _r) in enumerate(ASPECTS):
            b = _seg(name, self.aspect_group, key=name)
            grid.addWidget(b, i // 4, i % 4)
        self.aspect_group.buttons()[0].setChecked(True)
        self.aspect_group.buttonClicked.connect(lambda b: self._aspect(str(b.property("key"))))
        lay.addLayout(grid)
        lay.addWidget(_head("Turn"))
        row = QHBoxLayout()
        row.addWidget(_plain("⟲ Left", lambda: self._turn(-1)))
        row.addWidget(_plain("⟳ Right", lambda: self._turn(1)))
        row.addWidget(_plain("⇋ Flip", lambda: self._flip(True), "Mirror left to right"))
        row.addWidget(_plain("⇅ Flip", lambda: self._flip(False), "Mirror top to bottom"))
        lay.addLayout(row)
        self.straighten = SliderRow("Straighten", -450, 450)
        self.straighten._show = lambda: self.straighten.number.setText(f"{self.straighten.slider.value() / 10:+.1f}°")
        self.straighten._show()
        self.straighten.grabbed.connect(self.begin)
        self.straighten.moved.connect(self._straightened)
        lay.addWidget(self.straighten)
        lay.addWidget(_plain("Reset Crop", self._reset_crop))
        self.crop_note = QLabel("Drag the box's corners and sides; drag inside it to move it.", objectName="SheetSub")
        self.crop_note.setWordWrap(True)
        lay.addWidget(self.crop_note)
        lay.addStretch(1)
        return w

    def _uncropped(self) -> tuple[int, int]:
        return pe.turned_size(self.edit.geometry, *self.size_px, cropped=False)

    def _ratio(self) -> float | None:
        b = self.aspect_group.checkedButton()
        name = str(b.property("key")) if b is not None else "Freeform"
        return batch_crop.box_constraint(name, dict(ASPECTS).get(name), *self._uncropped())

    def _aspect(self, name: str) -> None:
        w, h = self._uncropped()
        self.begin()
        if name == "Original":
            box = pe.FULL
        elif name == "Freeform":
            box = self.edit.geometry.crop
        else:
            box = batch_crop.centered_box(dict(ASPECTS)[name], w, h)
        self.edit.geometry.crop = self.canvas.crop = tuple(box)
        self._refresh()
        self.canvas.update()

    def _turn(self, step: int) -> None:
        g = self.edit.geometry
        self.begin()
        g.quarters = (g.quarters + step) % 4
        g.crop = self.canvas.crop = tuple(batch_crop.turned(g.crop, step))
        if g.flip_h != g.flip_v:                     # a mirrored photo turns the other way round its mirror
            g.flip_h, g.flip_v = g.flip_v, g.flip_h
        self.request()

    def _flip(self, across: bool) -> None:
        g = self.edit.geometry
        self.begin()
        x, y, w, h = g.crop
        if across:
            g.flip_h = not g.flip_h
            g.crop = (1 - x - w, y, w, h)
        else:
            g.flip_v = not g.flip_v
            g.crop = (x, 1 - y - h, w, h)
        g.straighten = -g.straighten
        self.canvas.crop = g.crop
        self._sync()
        self.request()

    def _straightened(self, v: int, resting: bool) -> None:
        self.edit.geometry.straighten = v / 10.0
        self.request(rough=not resting)

    def _reset_crop(self) -> None:
        if self.edit.geometry.plain():
            return
        self.begin()
        self.edit.geometry = pe.Geometry()
        self.canvas.crop = pe.FULL
        self._sync()
        self.request()

    # -- Retouch
    def _retouch_tab(self) -> QWidget:
        inner = QWidget()
        lay = QVBoxLayout(inner)
        lay.setContentsMargins(0, 0, 8, 0)
        grid = QGridLayout()
        grid.setSpacing(4)
        self.tool_group = QButtonGroup(self)
        for i, (key, name, tip) in enumerate(pe.TOOLS):
            b = _seg(name, self.tool_group, tip, key)
            grid.addWidget(b, i // 3, i % 3)
        was = str(self.settings.value("editor/tool", "smooth"))
        for b in self.tool_group.buttons():
            b.setChecked(b.property("key") == was)
        if self.tool_group.checkedButton() is None:
            self.tool_group.buttons()[0].setChecked(True)
        self.tool_group.buttonClicked.connect(lambda _b: self._tool_changed())
        lay.addLayout(grid)
        self.tool_note = QLabel("", objectName="SheetSub")
        self.tool_note.setWordWrap(True)
        lay.addWidget(self.tool_note)
        self.brush_size = SliderRow("Brush Size", 1, 40, 0, "%")
        self.brush_size.set(float(self.settings.value("editor/brush", 6) or 6))
        self.brush_size.moved.connect(lambda v, _r: (self.settings.setValue("editor/brush", v), self.canvas.update()))
        self.brush_amount = SliderRow("Strength", 5, 100, 0, "%")
        self.brush_amount.set(float(self.settings.value("editor/brush_amount", 60) or 60))
        self.brush_amount.moved.connect(lambda v, _r: self.settings.setValue("editor/brush_amount", v))
        self.brush_soft = SliderRow("Soft Edge", 0, 100, 0, "%")
        self.brush_soft.set(float(self.settings.value("editor/brush_soft", 60) or 60))
        self.brush_soft.moved.connect(lambda v, _r: self.settings.setValue("editor/brush_soft", v))
        for r in (self.brush_size, self.brush_amount, self.brush_soft):
            lay.addWidget(r)
        self.strokes_note = QLabel("", objectName="SheetSub")
        lay.addWidget(self.strokes_note)
        lay.addWidget(_plain("Remove All Retouching", self._clear_strokes))

        lay.addWidget(_head("Background Blur"))
        row = QHBoxLayout()
        self.focus_group = QButtonGroup(self)
        for key, name, tip in (("", "Off", ""), ("round", "Round", "Sharp inside a circle — a portrait"),
                               ("band", "Band", "Sharp along a band — tilt-shift")):
            b = _seg(name, self.focus_group, tip, key)
            b.setChecked(key == "")
            row.addWidget(b)
        row.addStretch(1)
        self.focus_group.buttonClicked.connect(lambda b: self._focus_kind(str(b.property("key"))))
        lay.addLayout(row)
        self.focus_amount = SliderRow("Blur", 0, 100)
        self.focus_size = SliderRow("Sharp Area", 5, 80, 0, "%")
        self.focus_angle = SliderRow("Angle", -90, 90, 0, "°")
        for r, key in ((self.focus_amount, "amount"), (self.focus_size, "size"), (self.focus_angle, "angle")):
            r.grabbed.connect(self.begin)
            r.moved.connect(lambda v, resting, key=key: self._focus_moved(key, v, resting))
            lay.addWidget(r)
        self.focus_note = QLabel("Drag on the photo to place the sharp area.", objectName="SheetSub")
        self.focus_note.setWordWrap(True)
        lay.addWidget(self.focus_note)
        lay.addStretch(1)
        self._tool_changed()
        return _scrolling(inner)

    def tool(self) -> str:
        b = self.tool_group.checkedButton()
        return str(b.property("key")) if b is not None else "smooth"

    def _tool_changed(self) -> None:
        key = self.tool()
        self.settings.setValue("editor/tool", key)
        self.tool_note.setText(next(t[2] for t in pe.TOOLS if t[0] == key))
        self.brush_soft.setEnabled(key not in ("redeye", "reshape", "heal"))
        self.brush_amount.setEnabled(key not in ("heal", "redeye"))
        self._placing_focus = False
        self._set_mode()

    def _clear_strokes(self) -> None:
        if not self.edit.strokes:
            return
        self.begin()
        self.edit.strokes = []
        self._refresh()
        self.request()

    def _focus_kind(self, kind: str) -> None:
        self.begin()
        self.edit.focus.kind = kind
        if kind and self.edit.focus.amount <= 0:
            self.edit.focus.amount = 50.0
        self._placing_focus = bool(kind)
        self._sync()
        self._set_mode()
        self.request()

    def _focus_moved(self, key: str, v: int, resting: bool) -> None:
        setattr(self.edit.focus, key, v / 100.0 if key == "size" else float(v))
        self._placing_focus = bool(self.edit.focus.kind)
        self._set_mode()
        if self.edit.focus.kind:
            self.request(rough=not resting)

    # -- Face
    def _face_tab(self) -> QWidget:
        inner = QWidget()
        lay = QVBoxLayout(inner)
        lay.setContentsMargins(0, 0, 8, 0)
        self.face_note = QLabel("", objectName="SheetSub")
        self.face_note.setWordWrap(True)
        lay.addWidget(self.face_note)
        self.face_get = _plain("Get the Face Finder", self._get_faces)
        self.face_get.hide()
        lay.addWidget(self.face_get)
        self.face_rows: dict[str, SliderRow] = {}
        for key, name, needs in pe.FACE_SLIDERS:
            r = SliderRow(name, 0, 100)
            r.setProperty("needs", needs)
            r.setEnabled(not needs)                    # until the face finder has looked
            r.grabbed.connect(self.begin)
            r.moved.connect(lambda v, resting, key=key: self._face_moved(key, v, resting))
            self.face_rows[key] = r
            lay.addWidget(r)
        lay.addWidget(_plain("Reset Face", self._reset_face))
        tip = QLabel("Smooth Skin works on all skin in the photo. The others are worked out from where the eyes, "
                     "nose and mouth are, so they are gentle — for more, use Reshape in Retouch.", objectName="SheetSub")
        tip.setWordWrap(True)
        lay.addWidget(tip)
        lay.addStretch(1)
        return _scrolling(inner)

    def _face_moved(self, key: str, v: int, resting: bool) -> None:
        if v:
            self.edit.face[key] = v
        else:
            self.edit.face.pop(key, None)
        self.request(rough=not resting)

    def _reset_face(self) -> None:
        if not self.edit.face:
            return
        self.begin()
        self.edit.face = {}
        self._sync()
        self.request()

    def _look_for_faces(self) -> None:
        if self._faces_asked or self.src is None:
            return
        self._faces_asked = True
        self.face_note.setText("Looking for faces…")
        im, sig = self.src.image, self._sig

        def work() -> None:
            try:
                import faces
                try:
                    sig.faces.emit(pe.find_faces(im), "")
                except faces.Missing:
                    sig.faces.emit(None, "missing")
            except Exception as e:  # noqa: BLE001 — onnxruntime not installed, a model that won't load
                sig.faces.emit(None, f"{type(e).__name__}: {e}")
        threading.Thread(target=work, daemon=True).start()

    def _faces(self, found, why: str) -> None:
        if why == "downloaded":                        # the models are here now: look
            self.face_get.hide()
            self._faces_asked = False
            self._look_for_faces()
            return
        self.face_get.setEnabled(True)
        ok = found is not None
        self.face_get.setVisible(why == "missing")
        if ok:
            self.renderer.found = found
            n = len(found)
            self.face_note.setText("No face found in this photo — Smooth Skin still works." if n == 0 else
                                   f"{n} face{'s' if n != 1 else ''} found. Every slider works on "
                                   f"{'it' if n == 1 else 'all of them'}.")
            if any(self.edit.face.values()):
                self.request()
        elif why == "missing":
            try:
                import faces
                mb = faces.download_size() / 1e6
            except Exception:  # noqa: BLE001
                mb = 40.0
            self.face_note.setText("Eyes, teeth and reshaping need the face finder the People feature uses "
                                   f"({mb:.0f} MB, downloaded once, kept on this Mac). Smooth Skin works without it.")
        else:
            self.face_note.setText(f"The face finder couldn't run ({why}). Smooth Skin still works.")
        for r in self.face_rows.values():
            r.setEnabled(not r.property("needs") or (ok and bool(found)))

    def _get_faces(self) -> None:
        self.face_get.setEnabled(False)
        self.face_note.setText("Downloading the face finder…")
        sig = self._sig

        def work() -> None:
            try:
                import faces
                faces.download()
                sig.faces.emit(None, "downloaded")
            except Exception as e:  # noqa: BLE001
                sig.faces.emit(None, str(e) or type(e).__name__)
        threading.Thread(target=work, daemon=True).start()

    # -- Text
    def _text_tab(self) -> QWidget:
        inner = QWidget()
        lay = QVBoxLayout(inner)
        lay.setContentsMargins(0, 0, 8, 0)
        lay.setSpacing(5)
        row = QHBoxLayout()
        add = QPushButton("Add Text", objectName="Primary")
        add.setAutoDefault(False)
        add.clicked.connect(lambda: self.add_text())
        row.addWidget(add)
        self.sticker_btn = _plain("Sticker ▾", None, "Emoji as stickers — move, size and turn them like text")
        menu = QMenu(self.sticker_btn)
        holder = QWidget()
        g = QGridLayout(holder)
        g.setContentsMargins(6, 6, 6, 6)
        g.setSpacing(2)
        for i, emoji in enumerate(photo_text.STICKERS):
            b = QToolButton()
            b.setText(emoji)
            b.setAutoRaise(True)
            b.setStyleSheet("font-size: 20px;")
            b.clicked.connect(lambda _=False, e=emoji, m=menu: (m.close(), self.add_text(e, sticker=True)))
            g.addWidget(b, i // 8, i % 8)
        from PySide6.QtWidgets import QWidgetAction
        act = QWidgetAction(menu)
        act.setDefaultWidget(holder)
        menu.addAction(act)
        self.sticker_btn.setMenu(menu)
        row.addWidget(self.sticker_btn)
        row.addStretch(1)
        lay.addLayout(row)
        self.layer_list = QListWidget()
        self.layer_list.setMaximumHeight(74)
        self.layer_list.currentRowChanged.connect(self._layer_picked)
        lay.addWidget(self.layer_list)
        row = QHBoxLayout()
        self.text_actions = [_plain("Duplicate", self._text_duplicate), _plain("Forward", lambda: self._text_order(1)),
                             _plain("Back", lambda: self._text_order(-1)), _plain("Delete", self._text_delete, "⌫")]
        for b in self.text_actions:
            row.addWidget(b)
        lay.addLayout(row)
        self.text_box = QWidget()
        t = QVBoxLayout(self.text_box)
        t.setContentsMargins(0, 0, 0, 0)
        t.setSpacing(5)
        self.text_edit = QPlainTextEdit()
        self.text_edit.setMaximumHeight(64)
        self.text_edit.setPlaceholderText("What it says")
        self.text_edit.textChanged.connect(self._text_typed)
        t.addWidget(self.text_edit)
        t.addWidget(_head("Style"))
        grid = QGridLayout()
        grid.setSpacing(3)
        for i, (name, style) in enumerate(photo_text.STYLES):
            grid.addWidget(_plain(name, lambda _=False, st=style: self._text_style(st)), i // 4, i % 4)
        t.addLayout(grid)
        t.addWidget(_head("Font"))
        self.font_box = QComboBox()
        self.font_box.setMaxVisibleItems(24)
        for kind, names in photo_text.fonts():
            self.font_box.addItem(f"— {kind} —", None)
            self.font_box.model().item(self.font_box.count() - 1).setEnabled(False)
            for n in names:
                self.font_box.addItem(n, n)
        self.font_box.activated.connect(lambda _i: self._text_set("font", self.font_box.currentData() or ""))
        t.addWidget(self.font_box)
        row = QHBoxLayout()
        self.text_toggles: dict[str, QToolButton] = {}
        for key, label, tip in (("bold", "B", "Bold"), ("italic", "I", "Italic"), ("underline", "U", "Underline"),
                                ("caps", "AA", "All capitals")):
            b = QToolButton(objectName="Scope")
            b.setText(label)
            b.setCheckable(True)
            b.setToolTip(tip)
            b.clicked.connect(lambda on, key=key: self._text_set(key, bool(on)))
            self.text_toggles[key] = b
            row.addWidget(b)
        row.addSpacing(8)
        self.align_group = QButtonGroup(self)
        for key, label in (("left", "⇤"), ("center", "↔"), ("right", "⇥")):
            b = _seg(label, self.align_group, f"Align {key}", key)
            row.addWidget(b)
        self.align_group.buttonClicked.connect(lambda b: self._text_set("align", str(b.property("key"))))
        row.addStretch(1)
        t.addLayout(row)
        self.text_rows: dict[str, SliderRow] = {}

        def slider(key: str, name: str, lo: int, hi: int, suffix: str = "", scale: float = 1.0) -> None:
            r = SliderRow(name, lo, hi, 0, suffix)
            r.setProperty("scale", scale)
            r.grabbed.connect(self.begin)
            r.moved.connect(lambda v, _resting, key=key, scale=scale: self._text_set(key, v / scale, undo=False))
            self.text_rows[key] = r
            t.addWidget(r)

        slider("size", "Size", 1, 60, "%", 100.0)
        slider("angle", "Turn", -180, 180, "°")
        slider("opacity", "Opacity", 5, 100, "%")
        t.addWidget(_head("Colour"))
        self.text_colour = Swatches(photo_text.SWATCHES)
        self.text_colour.picked.connect(lambda c: self._text_set("colour", c))
        t.addWidget(self.text_colour)
        self.gradient = QCheckBox("Fade into a second colour")
        self.gradient.clicked.connect(lambda on: self._text_set("colour2", (self._layer() or {}).get("colour2") or
                                                                "#ff2d55" if on else ""))
        t.addWidget(self.gradient)
        self.text_colour2 = Swatches(photo_text.SWATCHES)
        self.text_colour2.picked.connect(lambda c: self._text_set("colour2", c))
        t.addWidget(self.text_colour2)
        slider("spacing", "Letter Spacing", -10, 60)
        slider("leading", "Line Spacing", 60, 200, "%")
        t.addWidget(_head("Outline"))
        slider("stroke", "Width", 0, 30)
        self.stroke_colour = Swatches(photo_text.SWATCHES[:14])
        self.stroke_colour.picked.connect(lambda c: self._text_set("stroke_colour", c))
        t.addWidget(self.stroke_colour)
        t.addWidget(_head("Shadow & Glow"))
        slider("shadow", "Shadow", 0, 100)
        slider("glow", "Glow", 0, 100)
        self.glow_colour = Swatches(photo_text.SWATCHES[:14])
        self.glow_colour.picked.connect(lambda c: (self._text_set("glow_colour", c), self._text_set("shadow_colour", c)
                                                   if (self._layer() or {}).get("shadow") and not
                                                   (self._layer() or {}).get("glow") else None))
        t.addWidget(self.glow_colour)
        t.addWidget(_head("Background"))
        self.back_box = QComboBox()
        for key, name in (("", "None"), ("box", "Box"), ("round", "Rounded"), ("pill", "Pill"), ("bar", "Bar across the photo")):
            self.back_box.addItem(name, key)
        self.back_box.activated.connect(lambda _i: self._text_set("back", self.back_box.currentData()))
        t.addWidget(self.back_box)
        slider("back_opacity", "Opacity", 0, 100, "%")
        self.back_colour = Swatches(photo_text.SWATCHES[:14])
        self.back_colour.picked.connect(lambda c: self._text_set("back_colour", c))
        t.addWidget(self.back_colour)
        lay.addWidget(self.text_box)
        hint = QLabel("Drag text on the photo to move it; drag its corner dot to size and turn it. Double-click "
                      "the photo to add text there.", objectName="SheetSub")
        hint.setWordWrap(True)
        lay.addWidget(hint)
        lay.addStretch(1)
        return _scrolling(inner)

    def _layer(self) -> dict | None:
        return self.edit.texts[self.sel] if 0 <= self.sel < len(self.edit.texts) else None

    def add_text(self, text: str = "", sticker: bool = False, at: tuple[float, float] | None = None) -> None:
        self.begin()
        n = len(self.edit.texts)
        x, y = at or (0.5, min(0.9, 0.5 + 0.08 * (n % 5)))
        layer = photo_text.new_layer(text=text or "Text", x=x, y=y)
        if sticker:
            layer.update(size=0.16, bold=False)
        else:
            was = self.settings.value("editor/text_font")
            if was:
                layer["font"] = str(was)
        self.edit.texts.append(layer)
        self.sel = n
        self._sync_text()
        self.canvas.update()
        if not sticker:
            self.text_edit.setFocus()
            self.text_edit.selectAll()

    def _layer_picked(self, row: int) -> None:
        if row != self.sel and not self.layer_list.signalsBlocked():
            self.sel = row
            self._sync_text(False)
            self.canvas.update()

    def _text_typed(self) -> None:
        layer = self._layer()
        if layer is None or self.text_edit.signalsBlocked():
            return
        import time
        now = time.monotonic()
        if now - self._typing_at > 1.5:
            self.begin()
        self._typing_at = now
        layer["text"] = self.text_edit.toPlainText()
        item = self.layer_list.item(self.sel)
        if item is not None:
            item.setText(layer["text"].replace("\n", " ") or "(empty)")
        self.canvas.update()
        self._refresh()

    def _text_set(self, key: str, value, undo: bool = True) -> None:
        layer = self._layer()
        if layer is None:
            return
        if undo:
            self.begin()
        layer[key] = value
        if key == "font":
            self.settings.setValue("editor/text_font", value)
        if key in ("colour2", "back", "bold", "italic", "underline", "caps", "align", "colour", "stroke_colour",
                   "glow_colour", "back_colour"):
            self._sync_text(False)
        self.canvas.update()
        self._refresh()

    def _text_style(self, style: dict) -> None:
        layer = self._layer()
        if layer is None:
            return
        self.begin()
        self.edit.texts[self.sel] = photo_text.styled(layer, style)
        self._sync_text(False)
        self.canvas.update()

    def _text_duplicate(self) -> None:
        layer = self._layer()
        if layer is None:
            return
        self.begin()
        self.edit.texts.append({**layer, "x": min(0.95, layer["x"] + 0.04), "y": min(0.95, layer["y"] + 0.04)})
        self.sel = len(self.edit.texts) - 1
        self._sync_text()
        self.canvas.update()

    def _text_order(self, step: int) -> None:
        j = self.sel + step
        if self._layer() is None or not 0 <= j < len(self.edit.texts):
            return
        self.begin()
        t = self.edit.texts
        t[self.sel], t[j] = t[j], t[self.sel]
        self.sel = j
        self._sync_text()
        self.canvas.update()

    def _text_delete(self) -> None:
        if self._layer() is None:
            return
        self.begin()
        del self.edit.texts[self.sel]
        self.sel = min(self.sel, len(self.edit.texts) - 1)
        self._sync_text()
        self.canvas.update()

    def _sync_text(self, rebuild: bool = True) -> None:
        """The Text tab's controls set from the selected layer (`rebuild`: the list of layers too)."""
        if rebuild:
            self.layer_list.blockSignals(True)
            self.layer_list.clear()
            for layer in self.edit.texts:
                self.layer_list.addItem(str(layer.get("text") or "").replace("\n", " ") or "(empty)")
            self.layer_list.setCurrentRow(self.sel)
            self.layer_list.blockSignals(False)
        layer = self._layer()
        self.text_box.setEnabled(layer is not None)
        for b in self.text_actions:
            b.setEnabled(layer is not None)
        if layer is None:
            self._refresh()
            return
        if self.text_edit.toPlainText() != layer.get("text", ""):
            self.text_edit.blockSignals(True)
            self.text_edit.setPlainText(layer.get("text", ""))
            self.text_edit.blockSignals(False)
        i = self.font_box.findData(photo_text.family_for(str(layer.get("font") or "")))
        self.font_box.setCurrentIndex(max(i, 1))
        for key, b in self.text_toggles.items():
            b.setChecked(bool(layer.get(key)))
        for b in self.align_group.buttons():
            b.setChecked(b.property("key") == layer.get("align", "center"))
        for key, r in self.text_rows.items():
            r.set(float(layer.get(key, 0) or 0) * float(r.property("scale") or 1.0))
        self.text_colour.show_current(layer.get("colour", ""))
        self.gradient.setChecked(bool(layer.get("colour2")))
        self.text_colour2.setVisible(bool(layer.get("colour2")))
        self.text_colour2.show_current(layer.get("colour2", ""))
        self.stroke_colour.show_current(layer.get("stroke_colour", ""))
        self.glow_colour.show_current(layer.get("glow_colour", ""))
        self.back_colour.show_current(layer.get("back_colour", ""))
        self.back_box.setCurrentIndex(max(0, self.back_box.findData(layer.get("back", ""))))
        self._refresh()

    def text_double_click(self, u: float, v: float) -> None:
        if not any(photo_text.hit(layer, 1000, 1000 * self._shown_ratio(), u * 1000, v * 1000 * self._shown_ratio())
                   for layer in self.edit.texts):
            self.add_text(at=(float(np.clip(u, 0.05, 0.95)), float(np.clip(v, 0.05, 0.95))))
        else:
            self.text_edit.setFocus()
            self.text_edit.selectAll()

    def _shown_ratio(self) -> float:
        pix = self.canvas.pix
        return pix.height() / pix.width() if pix is not None and pix.width() else 1.0

    # -- Frame
    def _frame_tab(self) -> QWidget:
        w = QWidget()
        lay = QVBoxLayout(w)
        lay.setContentsMargins(0, 0, 0, 0)
        grid = QGridLayout()
        grid.setSpacing(4)
        self.frame_group = QButtonGroup(self)
        for i, (key, name) in enumerate(pe.FRAMES):
            b = _seg(name, self.frame_group, key=key)
            b.setChecked(key == "")
            grid.addWidget(b, i // 3, i % 3)
        self.frame_group.buttonClicked.connect(lambda b: self._frame_set("kind", str(b.property("key"))))
        lay.addLayout(grid)
        self.frame_width = SliderRow("Width", 0, 30, 5, "%")
        self.frame_width.set(5)
        self.frame_width.grabbed.connect(self.begin)
        self.frame_width.moved.connect(lambda v, resting: self._frame_set("width", float(v), undo=False, rough=not resting))
        lay.addWidget(self.frame_width)
        lay.addWidget(_head("Colour"))
        self.frame_colour = Swatches(photo_text.SWATCHES)
        self.frame_colour.picked.connect(lambda c: self._frame_set("colour", QColor(c).getRgb()[:3]))
        lay.addWidget(self.frame_colour)
        lay.addWidget(_head("Fit to Shape"))
        self.fit_shape = QComboBox()
        for name, _r in pe.FIT_SHAPES:
            self.fit_shape.addItem(name, name)
        self.fit_shape.activated.connect(lambda _i: self._frame_set("shape", self.fit_shape.currentData()))
        lay.addWidget(self.fit_shape)
        self.fit_blur = QCheckBox("Fill the space with the photo, blurred")
        self.fit_blur.clicked.connect(lambda on: self._frame_set("blur", bool(on)))
        lay.addWidget(self.fit_blur)
        note = QLabel("Fit to Shape puts the whole photo in a square, a story or any other shape without cropping it.",
                      objectName="SheetSub")
        note.setWordWrap(True)
        lay.addWidget(note)
        lay.addStretch(1)
        return w

    def _frame_set(self, key: str, value, undo: bool = True, rough: bool = False) -> None:
        if undo:
            self.begin()
        setattr(self.edit.frame, key, value)
        self._sync_frame()
        self.request(rough=rough)

    def _sync_frame(self) -> None:
        f = self.edit.frame
        for b in self.frame_group.buttons():
            b.setChecked(b.property("key") == f.kind)
        self.frame_width.set(f.width)
        self.frame_width.setEnabled(f.kind in ("border", "polaroid", "rounded", "fit"))
        self.frame_colour.show_current(QColor(*f.colour).name())
        self.fit_shape.setCurrentIndex(max(0, self.fit_shape.findData(f.shape)))
        self.fit_shape.setEnabled(f.kind == "fit")
        self.fit_blur.setChecked(f.blur)
        self.fit_blur.setEnabled(f.kind == "fit")

    # ------------------------------------------------------------------ state
    def begin(self) -> None:
        """Call before changing the edit: what it is now becomes an undo step."""
        now = pe.to_dict(self.edit)
        if not self._undo or self._undo[-1] != now:
            self._undo.append(now)
            del self._undo[:-80]
        self._redo.clear()
        QTimer.singleShot(0, self._refresh)

    def undo(self) -> None:
        if not self._undo or self.saving:
            return
        now = pe.to_dict(self.edit)
        while self._undo and self._undo[-1] == now:          # a step that changed nothing
            self._undo.pop()
        if not self._undo:
            self._refresh()
            return
        self._redo.append(now)
        self._restore(self._undo.pop())

    def redo(self) -> None:
        if not self._redo or self.saving:
            return
        self._undo.append(pe.to_dict(self.edit))
        self._restore(self._redo.pop())

    def _restore(self, state: dict) -> None:
        self.edit = pe.from_dict(state)
        self.sel = min(self.sel, len(self.edit.texts) - 1)
        self._sync()
        self.request()

    def reset_all(self) -> None:
        if not self.edit.changed():
            return
        self.begin()
        self.edit = pe.Edit()
        self.sel = -1
        self._sync()
        self.request()

    def _sync(self) -> None:
        """Every control set from the edit (after an undo, a reset)."""
        e = self.edit
        for key, r in self.sliders.items():
            r.set(float(e.adjust.get(key, 0) or 0))
        self._show_band()
        self.mono.blockSignals(True)
        self.mono.setChecked(bool(e.adjust.get("mono")))
        self.mono.blockSignals(False)
        self.look_amount.set(e.look_amount)
        (self.look_buttons.get(e.look) or self.look_buttons[""]).setChecked(True)
        self.straighten.set(e.geometry.straighten * 10)
        self.straighten._show()
        self.canvas.crop = tuple(e.geometry.crop)
        for key, r in self.face_rows.items():
            r.set(float(e.face.get(key, 0) or 0))
        for b in self.focus_group.buttons():
            b.setChecked(b.property("key") == e.focus.kind)
        self.focus_amount.set(e.focus.amount)
        self.focus_size.set(e.focus.size * 100)
        self.focus_angle.set(e.focus.angle)
        self._sync_frame()
        self._sync_text()
        self._refresh()
        self.canvas.update()

    def _refresh(self) -> None:
        ready = self.src is not None and not self.saving
        changed = self.edit.changed()
        self.undo_btn.setEnabled(ready and bool(self._undo))
        self.redo_btn.setEnabled(ready and bool(self._redo))
        self.reset_btn.setEnabled(ready and changed)
        self.compare_btn.setEnabled(ready and changed)
        for b in (self.new_btn, self.over_btn, self.up_btn):
            b.setEnabled(ready and changed)
        self.up_btn.setEnabled(ready)                          # upscaling alone is a fair thing to ask for
        self.stack.setEnabled(ready)
        n = len(self.edit.strokes)
        self.strokes_note.setText(f"{n} brush stroke{'s' if n != 1 else ''} on this photo." if n else "")
        for r in (self.focus_amount, self.focus_size, self.focus_angle):
            r.setEnabled(bool(self.edit.focus.kind))
        self.focus_angle.setVisible(self.edit.focus.kind == "band")
        self.focus_note.setVisible(bool(self.edit.focus.kind))
        if ready and self.size_px[0]:
            w, h = pe.turned_size(self.edit.geometry, *self.size_px)
            bits = [f"{w:,} × {h:,}"]
            if self.hdr:
                bits.append("HDR photo — edited and saved in standard range")
            elif self.gain == "kept":
                bits.append("HDR photo — it stays HDR when saved")
            elif self.gain:
                bits.append(f"HDR photo — saved in standard range ({self.gain})")
            self.save_note.setText(" · ".join(bits))

    # ------------------------------------------------------------------ what's on screen
    def _tab(self) -> int:
        b = self.tab_group.checkedButton()
        return int(b.property("key")) if b is not None else 0

    def stage(self) -> str:
        if self.comparing:
            return "before"
        name = TABS[self._tab()]
        return {"Crop": "nocrop", "Retouch": "noframe", "Face": "noframe"}.get(name, "final")

    def _set_mode(self) -> None:
        name = TABS[self._tab()]
        mode = {"Crop": "crop", "Text": "text"}.get(name, "view")
        if name == "Retouch":
            mode = "focus" if getattr(self, "_placing_focus", False) and self.edit.focus.kind else "brush"
        self.canvas.mode = mode
        self.canvas.setCursor(QCursor(Qt.CursorShape.CrossCursor if mode in ("brush", "focus") else Qt.CursorShape.ArrowCursor))
        self.canvas.update()

    def _tab_changed(self, i: int) -> None:
        self.stack.setCurrentIndex(i)
        self.settings.setValue("editor/tab", i)
        self._placing_focus = False
        self._set_mode()
        if TABS[i] == "Face":
            self._look_for_faces()
        if TABS[i] == "Filters":
            self._ask_thumbs()
        self.canvas.crop = tuple(self.edit.geometry.crop)
        self.canvas.fit()
        if self.src is not None:
            self.request()

    def _ask_thumbs(self) -> None:
        key = json.dumps(pe.asdict(self.edit.geometry))
        if self.src is not None and key != self._thumb_key:
            self._thumb_key = key
            self.renderer.thumbs(self.gen, self.edit.copy())

    def request(self, rough: bool = False) -> None:
        if self.src is None:
            return
        self.gen += 1
        self.renderer.ask(self.gen, self.edit.copy(), self.stage(), rough)
        self._refresh()

    def _preview(self, gen: int, arr, stage: str, rough: bool) -> None:
        if stage != self.stage() or (rough and gen < self.gen):
            return                                       # overtaken: the newer one is on its way
        self.canvas.set_pixmap(QPixmap.fromImage(qimage_rgb(arr)))
        if TABS[self._tab()] == "Filters" and not rough:
            self._ask_thumbs()

    def compare(self, on: bool) -> None:
        if self.comparing != on:
            self.comparing = on
            self.request()

    def keyPressEvent(self, e) -> None:  # noqa: N802
        if e.key() == Qt.Key.Key_Space and not e.isAutoRepeat() and not self.text_edit.hasFocus():
            self.compare(True)
        elif e.key() in (Qt.Key.Key_Backspace, Qt.Key.Key_Delete) and TABS[self._tab()] == "Text" \
                and not self.text_edit.hasFocus():
            self._text_delete()
        elif e.key() == Qt.Key.Key_Escape:
            self.close()
        elif e.key() not in (Qt.Key.Key_Return, Qt.Key.Key_Enter):
            super().keyPressEvent(e)

    def keyReleaseEvent(self, e) -> None:  # noqa: N802
        if e.key() == Qt.Key.Key_Space and not e.isAutoRepeat():
            self.compare(False)
        super().keyReleaseEvent(e)

    # ------------------------------------------------------------------ the canvas asks
    def _crop_hit(self, pos: QPointF, c: Canvas) -> str:
        t = c.target()
        x, y, w, h = c.crop
        r = QRectF(t.x() + x * t.width(), t.y() + y * t.height(), w * t.width(), h * t.height())
        near = 12.0
        for name, pt in (("tl", r.topLeft()), ("tr", r.topRight()), ("bl", r.bottomLeft()), ("br", r.bottomRight())):
            if abs(pos.x() - pt.x()) <= near and abs(pos.y() - pt.y()) <= near:
                return name
        if self._ratio() is None:
            if abs(pos.y() - r.top()) <= near and r.left() < pos.x() < r.right():
                return "top"
            if abs(pos.y() - r.bottom()) <= near and r.left() < pos.x() < r.right():
                return "bottom"
            if abs(pos.x() - r.left()) <= near and r.top() < pos.y() < r.bottom():
                return "left"
            if abs(pos.x() - r.right()) <= near and r.top() < pos.y() < r.bottom():
                return "right"
        return "move" if r.contains(pos) else ""

    def _text_handle(self, layer: dict, c: Canvas) -> QPointF:
        t = c.target()
        return photo_text.outline(layer, t.width(), t.height())[2] + t.topLeft()

    def _text_at(self, pos: QPointF, c: Canvas) -> int:
        t = c.target()
        for i in range(len(self.edit.texts) - 1, -1, -1):
            if photo_text.hit(self.edit.texts[i], t.width(), t.height(), pos.x() - t.x(), pos.y() - t.y()):
                return i
        return -1

    def cursor_for(self, mode: str, u: float, v: float, pos: QPointF, c: Canvas) -> QCursor:
        if mode == "crop":
            what = self._crop_hit(pos, c)
            shape = {"tl": Qt.CursorShape.SizeFDiagCursor, "br": Qt.CursorShape.SizeFDiagCursor,
                     "tr": Qt.CursorShape.SizeBDiagCursor, "bl": Qt.CursorShape.SizeBDiagCursor,
                     "top": Qt.CursorShape.SizeVerCursor, "bottom": Qt.CursorShape.SizeVerCursor,
                     "left": Qt.CursorShape.SizeHorCursor, "right": Qt.CursorShape.SizeHorCursor,
                     "move": Qt.CursorShape.SizeAllCursor}.get(what, Qt.CursorShape.ArrowCursor)
            return QCursor(shape)
        layer = self._layer()
        if layer is not None and (pos - self._text_handle(layer, c)).manhattanLength() < 16:
            return QCursor(Qt.CursorShape.SizeFDiagCursor)
        return QCursor(Qt.CursorShape.SizeAllCursor if self._text_at(pos, c) >= 0 else Qt.CursorShape.ArrowCursor)

    def press(self, mode: str, u: float, v: float, pos: QPointF, c: Canvas) -> dict | None:
        if self.src is None or self.saving or self.comparing:
            return None
        if mode == "crop":
            what = self._crop_hit(pos, c)
            return {"kind": "crop", "what": what, "start": c.crop, "u": u, "v": v} if what else None
        if mode == "brush":
            if not (-0.02 <= u <= 1.02 and -0.02 <= v <= 1.02):
                return None
            c.stroke = [(u, v)]
            return {"kind": "brush", "tool": self.tool()}
        if mode == "focus":
            self.begin()
            self.edit.focus.x, self.edit.focus.y = float(np.clip(u, 0, 1)), float(np.clip(v, 0, 1))
            self.request(rough=True)
            return {"kind": "focus"}
        if mode == "text":
            t = c.target()
            layer = self._layer()
            if layer is not None and (pos - self._text_handle(layer, c)).manhattanLength() < 16:
                cx, cy = layer["x"] * t.width() + t.x(), layer["y"] * t.height() + t.y()
                return {"kind": "text-size", "size": layer["size"], "angle": layer.get("angle", 0.0), "begun": False,
                        "dist": max(4.0, float(np.hypot(pos.x() - cx, pos.y() - cy))),
                        "dir": photo_text.angle_to(layer, t.width(), t.height(), pos.x() - t.x(), pos.y() - t.y())}
            i = self._text_at(pos, c)
            if i != self.sel:
                self.sel = i
                self._sync_text()
            if i < 0:
                return None
            layer = self.edit.texts[i]
            return {"kind": "text-move", "du": layer["x"] - u, "dv": layer["y"] - v, "begun": False}
        return None

    def drag(self, d: dict, u: float, v: float, c: Canvas) -> None:
        kind = d["kind"]
        if kind == "crop":
            du, dv = u - d["u"], v - d["v"]
            what, start = d["what"], d["start"]
            if what == "move":
                c.crop = batch_crop.moved(start, du, dv)
            elif what in ("top", "bottom", "left", "right"):
                c.crop = batch_crop.side_moved(what, start, du, dv)
            else:
                c.crop = batch_crop.resized(what, start, du, dv, self._ratio())
        elif kind == "brush":
            if d["tool"] != "redeye":
                c.stroke.append((u, v))
        elif kind == "focus":
            self.edit.focus.x, self.edit.focus.y = float(np.clip(u, 0, 1)), float(np.clip(v, 0, 1))
            self.request(rough=True)
        elif kind in ("text-move", "text-size"):
            layer = self._layer()
            if layer is None:
                return
            if not d["begun"]:
                self.begin()
                d["begun"] = True
            t = c.target()
            if kind == "text-move":
                layer["x"] = float(np.clip(u + d["du"], -0.2, 1.2))
                layer["y"] = float(np.clip(v + d["dv"], -0.2, 1.2))
            else:
                px, py = u * t.width(), v * t.height()
                dist = float(np.hypot(px - layer["x"] * t.width(), py - layer["y"] * t.height()))
                layer["size"] = float(np.clip(d["size"] * dist / d["dist"], 0.01, 0.8))
                turn = photo_text.angle_to(layer, t.width(), t.height(), px, py) - d["dir"]
                layer["angle"] = round(((d["angle"] + turn + 180) % 360) - 180, 1)
                if abs(layer["angle"]) < 2.0:
                    layer["angle"] = 0.0
                for key in ("size", "angle"):
                    r = self.text_rows[key]
                    r.set(layer[key] * float(r.property("scale") or 1.0))

    def release(self, d: dict, u: float, v: float, c: Canvas) -> None:
        kind = d["kind"]
        if kind == "crop":
            if tuple(c.crop) != tuple(self.edit.geometry.crop):
                self.begin()
                box = tuple(float(x) for x in c.crop)
                self.edit.geometry.crop = pe.FULL if not batch_crop.is_trim(box) else box
                c.crop = self.edit.geometry.crop
                self._refresh()
        elif kind == "brush":
            pts, c.stroke = c.stroke, []
            g, (w, h) = self.edit.geometry, self.size_px
            size = self.brush_size.value() / 100.0 * pe.scale_to_original(g, w, h)
            ew, eh = pe.turned_size(g, w, h)
            gap = (self.brush_size.value() / 100.0) * 0.12
            kept = [pts[0]]
            for pt in pts[1:]:
                if np.hypot(pt[0] - kept[-1][0], (pt[1] - kept[-1][1]) * eh / ew) >= gap:
                    kept.append(pt)
            if len(pts) > 1 and kept[-1] != pts[-1]:
                kept.append(pts[-1])
            if d["tool"] == "reshape" and len(kept) < 2:
                return
            self.begin()
            self.edit.strokes.append(pe.Stroke(d["tool"], [pe.to_original(g, a, b, w, h) for a, b in kept], size,
                                               self.brush_amount.value() / 100.0, self.brush_soft.value() / 100.0))
            self.note.setText("Healing…" if d["tool"] == "heal" else "")
            self.request()
        elif kind == "focus":
            self.request()

    def paint_over(self, p: QPainter, t: QRectF, c: Canvas) -> None:
        stage = self.stage()
        if stage == "final" and self.edit.texts:
            p.save()
            p.setClipRect(t)
            p.translate(t.topLeft())
            for layer in self.edit.texts:
                photo_text.paint(p, layer, t.width(), t.height())
            p.restore()
        if self.comparing:
            p.setPen(QColor(255, 255, 255))
            p.drawText(t.adjusted(10, 8, 0, 0), Qt.AlignmentFlag.AlignLeft | Qt.AlignmentFlag.AlignTop, "Before")
            return
        if c.mode == "crop":
            x, y, w, h = c.crop
            r = QRectF(t.x() + x * t.width(), t.y() + y * t.height(), w * t.width(), h * t.height())
            shade = QPainterPath()
            shade.addRect(t)
            shade.addRect(r)
            p.fillPath(shade, QColor(0, 0, 0, 150))
            p.setPen(QPen(QColor(255, 255, 255, 110), 1))
            for i in (1, 2):
                p.drawLine(QPointF(r.x() + r.width() * i / 3, r.y()), QPointF(r.x() + r.width() * i / 3, r.bottom()))
                p.drawLine(QPointF(r.x(), r.y() + r.height() * i / 3), QPointF(r.right(), r.y() + r.height() * i / 3))
            p.setPen(QPen(QColor(255, 255, 255), 1.5))
            p.setBrush(Qt.BrushStyle.NoBrush)
            p.drawRect(r)
            p.setBrush(QColor(255, 255, 255))
            for pt in (r.topLeft(), r.topRight(), r.bottomLeft(), r.bottomRight()):
                p.drawEllipse(pt, 5, 5)
            ew, eh = self._uncropped()
            p.drawText(QPointF(r.x() + 8, r.y() + 18), f"{max(1, round(w * ew)):,} × {max(1, round(h * eh)):,}")
        elif c.mode == "brush":
            radius = self.brush_size.value() / 100.0 * t.width()
            if len(c.stroke) > 0:
                path = QPainterPath(QPointF(t.x() + c.stroke[0][0] * t.width(), t.y() + c.stroke[0][1] * t.height()))
                for u, v in c.stroke[1:]:
                    path.lineTo(t.x() + u * t.width(), t.y() + v * t.height())
                col = QColor(ACCENT)
                col.setAlpha(90)
                thin = self.tool() == "reshape"
                p.setPen(QPen(col, 3 if thin else radius * 2, Qt.PenStyle.SolidLine, Qt.PenCapStyle.RoundCap,
                              Qt.PenJoinStyle.RoundJoin))
                p.setBrush(Qt.BrushStyle.NoBrush)
                if len(c.stroke) == 1:
                    p.drawPoint(path.currentPosition())
                else:
                    p.drawPath(path)
            if c.hover is not None:
                p.setPen(QPen(QColor(255, 255, 255, 230), 1.2))
                p.setBrush(Qt.BrushStyle.NoBrush)
                p.drawEllipse(c.hover, radius, radius)
                p.setPen(QPen(QColor(0, 0, 0, 120), 1))
                p.drawEllipse(c.hover, radius + 1.2, radius + 1.2)
        elif c.mode == "focus" and self.edit.focus.kind:
            f = self.edit.focus
            centre = QPointF(t.x() + f.x * t.width(), t.y() + f.y * t.height())
            r = f.size * min(t.width(), t.height())
            p.setBrush(Qt.BrushStyle.NoBrush)
            p.setClipRect(t)
            for pen in (QPen(QColor(0, 0, 0, 110), 3), QPen(QColor(255, 255, 255, 230), 1.2)):
                p.setPen(pen)
                if f.kind == "round":
                    p.drawEllipse(centre, r, r)
                    p.drawEllipse(centre, r * 1.9, r * 1.9)
                else:
                    p.save()
                    p.translate(centre)
                    p.rotate(f.angle)
                    far = 3 * max(t.width(), t.height())
                    for off in (-r * 1.9, -r, r, r * 1.9):
                        p.drawLine(QPointF(-far, off), QPointF(far, off))
                    p.restore()
            p.setBrush(QColor(255, 255, 255))
            p.drawEllipse(centre, 4, 4)
        elif c.mode == "text":
            layer = self._layer()
            if layer is not None:
                poly = photo_text.outline(layer, t.width(), t.height()).translated(t.topLeft())
                p.setBrush(Qt.BrushStyle.NoBrush)
                p.setPen(QPen(QColor(0, 0, 0, 120), 3))
                p.drawPolygon(poly)
                p.setPen(QPen(QColor(255, 255, 255), 1.2, Qt.PenStyle.DashLine))
                p.drawPolygon(poly)
                p.setPen(QPen(QColor(0, 0, 0, 160), 1))
                p.setBrush(ACCENT)
                p.drawEllipse(poly[2], 7, 7)

    # ------------------------------------------------------------------ loading
    def _load(self) -> None:
        sig, path = self._sig, self.path

        def work() -> None:
            try:
                src = batch_crop.open_upright(path)
                hdr = False
                try:
                    import thumb_color
                    curve = thumb_color.curve_of(path, src.info.get("icc_profile"))
                    if curve is not None:                    # PQ / HLG: brought to standard range, and saved so
                        src.image = thumb_color.tone_mapped(src.image, *curve)
                        src.info.pop("icc_profile", None)
                        hdr = True
                except Exception:  # noqa: BLE001 — colour handling is best effort; the photo still opens
                    pass
                gain = ""
                try:
                    import gainmap
                    if gainmap.sniff(path):                  # an iPhone HDR photo: can its gain map be kept here?
                        gain = "kept" if gainmap.available() else (gainmap.problem or "not kept")
                except Exception:  # noqa: BLE001
                    pass
                sig.loaded.emit((src, hdr, gain), "")
            except Exception as e:  # noqa: BLE001 — shown, never a crash
                sig.loaded.emit(None, str(e))
        threading.Thread(target=work, daemon=True).start()

    def _loaded(self, got, why: str) -> None:
        if got is None:
            QMessageBox.warning(self, "Edit Photo", f"Couldn't read “{os.path.basename(self.path)}”: {why}")
            self.reject()
            return
        self.src, self.hdr, self.gain = got
        self.size_px = self.src.image.size
        self.renderer.set_photo(self.src.image)
        self.wait_text = "Drawing…"
        self._sync()
        self._tab_changed(self._tab())

    # ------------------------------------------------------------------ saving
    def save(self, as_new: bool, upscale: tuple | None = None) -> None:
        if self.src is None or self.saving:
            return
        if not as_new and not upscale:
            if QMessageBox.question(self, "Overwrite Original",
                                    f"Write the edit over “{os.path.basename(self.path)}”?\n\nThe photo as it is now "
                                    "can't be brought back afterwards. (Save as New keeps it.)",
                                    QMessageBox.StandardButton.Save | QMessageBox.StandardButton.Cancel,
                                    QMessageBox.StandardButton.Cancel) != QMessageBox.StandardButton.Save:
                return
        self.saving = True
        self._cancel.clear()
        self._pending = {"as_new": as_new, "upscale": upscale, "edit": self.edit.copy()}
        self.bar.setValue(0)
        self.bar.show()
        self.note.setText("Saving — every pixel this time…")
        self._refresh()
        edit, src, found, sig, cancel = self._pending["edit"], self.src, list(self.renderer.found), self._sig, self._cancel

        def work() -> None:
            try:
                img, alpha = pe.to_float(src.image)
                rgb, alpha = pe.render(img, edit, found, alpha, lambda f: sig.progress.emit(0.8 * f), cancel.is_set)
                sig.rendered.emit((rgb, alpha), "")
            except MemoryError:
                sig.rendered.emit(None, "there isn't enough memory for a photo this large")
            except Exception as e:  # noqa: BLE001
                sig.rendered.emit(None, f"{type(e).__name__}: {e}")
        threading.Thread(target=work, daemon=True).start()

    def _rendered(self, got, why: str) -> None:
        if got is None or self._pending is None or self._cancel.is_set():
            self._save_failed(why or "stopped")
            return
        rgb, alpha = got
        pending, src, path, sig = self._pending, self.src, self.path, self._sig
        try:
            if pending["edit"].texts:                    # text is the Mac's fonts: drawn here, on the main thread
                rgb = photo_text.onto_array(rgb, pending["edit"].texts)
        except Exception as e:  # noqa: BLE001
            self._save_failed(f"the text couldn't be drawn ({e})")
            return
        self.bar.setValue(86)

        def work() -> None:
            try:
                im = pe.to_image(rgb, alpha if alpha is not None and alpha.shape == rgb.shape[:2] else None)
                if src.image.mode in ("L", "LA") and float(np.abs(rgb - rgb.mean(axis=2, keepdims=True)).max()) < 0.01:
                    im = im.convert("LA" if im.mode == "RGBA" else "L")       # a grey photo stays grey
                edit, found = pending["edit"], list(self.renderer.found)
                data = batch_crop.encode_like(src, im, gain=lambda g: pe.gain_through(g, edit, found))
                sig.progress.emit(0.95)
                if pending["as_new"]:
                    written = batch_crop.write_beside(path, data, pe.NEW_LABEL)
                else:
                    batch_crop.write_in_place(path, data)
                    written = path
                sig.saved.emit(written, "")
            except Exception as e:  # noqa: BLE001
                sig.saved.emit("", str(e))
        threading.Thread(target=work, daemon=True).start()

    def _save_failed(self, why: str) -> None:
        self.saving = False
        self._pending = None
        self.bar.hide()
        self.note.setText("")
        self._refresh()
        if why and why != "stopped":
            QMessageBox.warning(self, "Edit Photo", f"Couldn't save the photo: {why}\n\nNothing was changed.")

    def _saved(self, written: str, why: str) -> None:
        if not written:
            self._save_failed(why)
            return
        pending = self._pending or {}
        edit: pe.Edit = pending.get("edit") or self.edit
        tags = ([pe.EDITED_TAG] if edit.changed() else []) + ([batch_crop.CROPPED_TAG] if edit.cropped() else [])
        if self.gain:
            self.said = "It's still an HDR photo." if self.src is not None and self.src.gain_kept else \
                "It was saved in standard range — its HDR brightness couldn't be kept here."
        as_new = bool(pending.get("as_new"))
        upscale = pending.get("upscale")
        self.bar.hide()
        if not upscale:
            self._finish(written, as_new, tags)
            return
        import ai_upscale
        import upscale_window
        engine, factor, texture = upscale
        self.note.setText("Saved. Upscaling…")

        def done(upscaled, skipped, failed) -> None:
            if upscaled:
                tags.append(ai_upscale.UPSCALED_TAG)
            elif skipped or failed:
                why2 = (skipped or failed)[0][1]
                QMessageBox.information(self, "Save and Upscale", f"The edit was saved, but it wasn't upscaled: {why2}.")
            self._finish(written, as_new, tags)

        run = upscale_window.UpscaleRun(self, [written], engine, done, as_new=False, texture=texture, lanes=1,
                                        allow_large=True, factor=factor)
        run.setAttribute(Qt.WidgetAttribute.WA_DeleteOnClose)
        run.open()

    def _finish(self, written: str, as_new: bool, tags: list[str]) -> None:
        self.saving = False
        self._pending = None
        self._undo.clear()
        self.edit = pe.Edit()                          # nothing left unsaved: closing asks nothing
        try:
            self.on_done(written, as_new, tags)
        finally:
            self.accept()

    def save_and_upscale(self) -> None:
        if self.src is None or self.saving:
            return
        import ai_upscale
        import upscale_window
        engine = ai_upscale.find_engine(self.settings.value("upscale/engine") or None)
        if engine is None:
            picked = upscale_window.ask_for_engine(self)
            if picked is None:
                return
            engine, chosen = picked
            self.settings.setValue("upscale/engine", chosen)
        e = self.edit
        w, h = pe.turned_size(e.geometry, *self.size_px)
        if e.frame.kind:
            shape = pe.apply_frame(np.zeros((max(1, h // 8), max(1, w // 8), 3), dtype=np.float32), e.frame).shape
            w, h = shape[1] * 8, shape[0] * 8
        dlg = UpscaleChoice(self, engine, (w, h), self.settings)
        dlg.exec()
        choice = dlg.result_choice()
        if choice is None:
            return
        as_new, model, factor, texture = choice
        self.save(as_new, (ai_upscale.with_model(engine, model or None), factor, texture))

    # ------------------------------------------------------------------ closing
    def reject(self) -> None:
        self.close()

    def closeEvent(self, event) -> None:  # noqa: N802
        if self.saving:
            event.ignore()
            return
        if self.src is not None and self.edit.changed():
            if QMessageBox.question(self, "Edit Photo", "Close without saving the edit?",
                                    QMessageBox.StandardButton.Discard | QMessageBox.StandardButton.Cancel,
                                    QMessageBox.StandardButton.Cancel) != QMessageBox.StandardButton.Discard:
                event.ignore()
                return
        self.renderer.stop()
        event.accept()
        super().reject()


def can_edit(path: str) -> bool:
    return batch_crop.can_crop(path)
