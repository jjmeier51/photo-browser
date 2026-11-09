"""Safe Finder's photo and video viewer — the iPhone app's viewer on the Mac: one item at a time on black,
the listing's order, a top and a bottom bar that a click hides or shows (the iPhone's tap), and an Info panel.

**The window fits the picture, as tall as the display.** It opens over Safe Finder's window (`box`), on its
display, the full height of that display (below the menu bar, above the Dock), and takes each item's shape at
that height — a portrait video or photo has no black bars beside it; only an item too wide for the display at
full height (a panorama) is as wide as the display instead. Moving to the next item re-fits it around the same
centre. Resizing the window by hand makes that the new size to fit within.
The bars sit above and below the picture, never over it (they used to be translucent overlays, which hid the
top and bottom of every photo — and Qt draws a video above any widget laid over it, so a video's controls were
never seen at all). A click still hides them (the iPhone's tap), and the window re-fits.

**HDR as QuickTime Player and Preview show it** (`viewer_surface`): Qt Multimedia decodes with FFmpeg and maps HDR
to standard range with its own shaders (an HDR video came out brighter and harsher than in QuickTime), and Qt
reads only an HDR photo's standard-range picture. So on a Mac, macOS draws the picture itself into a native view
(`_NativeStage`): videos through AVFoundation — QuickTime's own player — and HDR photos through Core Image (gain
map applied) and AppKit, in HDR on a display with the headroom. Qt still says where the picture goes (fit, zoom,
pan) and gets every click. Qt's player stays for what AVFoundation can't open (MKV, WebM, AVI…) or turns down,
and for everything while the Swift library is being built or can't be (no Xcode tools).

- **Photos** (`_ImageStage`): fitted to the window; the mouse wheel (toward you zooms in, away zooms out), pinch, ⌘-scroll, +/− or the zoom buttons, a double-click
  toggles fit / actual size at the point clicked, drag to pan. Read with Qt (its HEIC plug-in on the Mac) or,
  failing that, Pillow (pillow-heif), off the main thread, the neighbours read ahead so ←/→ is instant. An HDR
  photo shows Qt's picture first, then macOS's HDR one in its place (`_NativeStage`, the same zoom and pan).
- **Videos** (`_VideoStage`): AVFoundation on the Mac (Qt Multimedia otherwise) — play/pause, a scrubber you
  click or drag anywhere along (the video pauses while you drag; hovering shows the time there), looping like the
  iPhone's, ±15 s (J/L), a frame step (, and .), slow motion (½×, ¼×, ⅛×, as the iPhone's Slo-Mo), mute and a volume slider (remembered; squared to
  sound even, `loudness`),
  **zoom** (the same buttons and keys, the mouse wheel, pinch, double-click; under Qt's player, zoomed in, the video is drawn by
  a `QGraphicsVideoItem` that can be scaled and dragged — fitted, by the faster `QVideoWidget`), and **Save
  Frame** (the camera — a standard-range PNG in a "Screenshots" folder beside the video,
  `frame_export.save_frame`) and **Export All Frames…**. With neither player it shows the video's picture and
  offers Open With… (QuickTime Player).
- **Top right**: the resolution, quietly — 4K, 1080p, 720p, 8K… for a video (the iPhone app's long-side rule),
  megapixels for a photo — and HDR when it is (`media_info`: an HLG/PQ/Dolby Vision track; a gain map or HLG/PQ
  photo). Beside it, ♡ (Favorite) and ✦ (To AI) — the iPhone app's labels, which Safe Finder shares with it.
- **Moving around**: ←/→ (or a two-finger swipe when not zoomed), Esc or ↓ closes, I (or ↑) the Info panel,
  F full screen, S a slideshow (3 s a photo; a video plays out first), ⇧⌘F / ⇧⌘A Favorite / To AI, ⌘⌫ Move to
  Trash; the ⋯ menu has the rest.
- **Info panel**: name, when it was taken or recorded (`media_info`), size and dimensions, length, camera,
  place (with a link to Maps), caption, folder, tags (and Edit Tags…).

The viewer doesn't touch files itself: Safe Finder hands it what to do for the trash, tags, labels, revealing a
file and exporting frames (`hooks`), so it works the same from a folder, a search or a collection.
"""
from __future__ import annotations

import os
import subprocess
import sys
import threading
import time
from collections import OrderedDict
from dataclasses import dataclass, field
from typing import Callable

from PySide6.QtCore import QEvent, QObject, QPoint, QPointF, QRect, QRectF, QSize, QSizeF, Qt, QTimer, QUrl, Signal
from PySide6.QtGui import (QAction, QColor, QDesktopServices, QFont, QFontMetrics, QIcon, QImage, QImageReader,
                           QKeySequence, QPainter, QPainterPath, QPen, QPixmap, QShortcut)
from PySide6.QtWidgets import (QApplication, QFrame, QGraphicsPixmapItem, QGraphicsScene, QGraphicsView, QHBoxLayout,
                               QLabel, QMenu, QPushButton, QScrollArea, QSizePolicy, QSlider, QStackedLayout,
                               QStackedWidget, QStyle, QStyleOptionSlider, QToolButton, QToolTip, QVBoxLayout,
                               QWidget)

import media_info
import viewer_surface

IS_MAC = sys.platform == "darwin"
IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".heic", ".heif", ".webp", ".gif", ".tif", ".tiff", ".bmp", ".avif",
              ".dng", ".cr2", ".cr3", ".nef", ".arw", ".raf", ".orf", ".rw2"}
VIDEO_EXTS = {".mp4", ".mov", ".m4v", ".avi", ".mkv", ".webm", ".3gp", ".mts", ".m2ts", ".ts", ".wmv", ".flv"}
SLIDE_SECONDS = 3.0
CHROME_BG = "rgba(20,20,22,0.78)"


def is_media(path: str) -> bool:
    ext = os.path.splitext(path)[1].lower()
    return ext in IMAGE_EXTS or ext in VIDEO_EXTS


def is_video(path: str) -> bool:
    return os.path.splitext(path)[1].lower() in VIDEO_EXTS


def human(n: float) -> str:
    for unit in ("bytes", "KB", "MB", "GB", "TB"):
        if n < 1000 or unit == "TB":
            return f"{n:,.0f} {unit}" if unit == "bytes" else f"{n:,.1f} {unit}"
        n /= 1000
    return f"{n:.1f} TB"


@dataclass
class Hooks:
    """What the viewer asks of Safe Finder (each may be None: the button is left out)."""
    trash: Callable[[list[str]], bool] | None = None          # → True when moved to the Trash
    tags_of: Callable[[str], list[str]] | None = None
    edit_tags: Callable[[str], None] | None = None
    reveal: Callable[[str], None] | None = None               # show the file in its pane
    export_frames: Callable[[str], None] | None = None
    save_frame: Callable[[str, float], str | None] | None = None   # (video, seconds) → saved file
    labels_of: Callable[[str], list[str]] | None = None       # "favorite", "ai" — the iPhone app's labels
    remove_objects: Callable[[str], None] | None = None       # the photo → Remove Objects (remove_window.py)
    set_label: Callable[[str, str, bool], None] | None = None  # (path, label, on)
    extra: dict = field(default_factory=dict)


# ----------------------------------------------------------------------------- reading photos

def read_image(path: str, max_side: int = 0) -> QImage:
    """The photo upright (EXIF orientation applied): Qt first, then Pillow (HEIC, odd TIFFs). `max_side`
    > 0 scales a very large one down while reading."""
    reader = QImageReader(path)
    reader.setAutoTransform(True)
    if max_side and reader.size().isValid():
        sz = reader.size()
        longest = max(sz.width(), sz.height())
        if longest > max_side:
            reader.setScaledSize(sz.scaled(max_side, max_side, Qt.AspectRatioMode.KeepAspectRatio))
    img = reader.read()
    if not img.isNull():
        return img
    try:
        import batch_crop
        src = batch_crop.open_upright(path)
        im = src.image.convert("RGBA")
        if max_side and max(im.size) > max_side:
            im.thumbnail((max_side, max_side))
        data = im.tobytes()
        return QImage(data, im.width, im.height, im.width * 4, QImage.Format.Format_RGBA8888).copy()
    except Exception:  # noqa: BLE001 — a file nothing can read shows as such
        return QImage()


class _Loaded(QObject):
    done = Signal(str, QImage)


class _ImageLoader:
    """Photos read on worker threads, kept for a while (the current one and its neighbours)."""

    KEEP = 8

    def __init__(self) -> None:
        self.signals = _Loaded()
        self.cache: OrderedDict[str, QImage] = OrderedDict()
        self.pending: set[str] = set()
        self.signals.done.connect(self._store, Qt.ConnectionType.QueuedConnection)

    def get(self, path: str) -> QImage | None:
        if path in self.cache:
            self.cache.move_to_end(path)
            return self.cache[path]
        self.request(path)
        return None

    def request(self, path: str) -> None:
        if path in self.cache or path in self.pending:
            return
        self.pending.add(path)
        threading.Thread(target=lambda: self.signals.done.emit(path, read_image(path, 12000)), daemon=True).start()

    def _store(self, path: str, img: QImage) -> None:
        self.pending.discard(path)
        self.cache[path] = img
        while len(self.cache) > self.KEEP:
            self.cache.popitem(last=False)


# ----------------------------------------------------------------------------- the photo stage

class _ImageStage(QGraphicsView):
    """A photo, fitted; zoom by the mouse wheel (about the pointer, out no further than the fit), pinch, ⌘-scroll,
    +/− or double-click; pan by dragging (or a two-finger scroll when zoomed). A two-finger swipe
    sideways while fitted asks for the next or previous item (`swiped`); a click `tapped`."""
    swiped = Signal(int)
    tapped = Signal()
    zoom_changed = Signal()

    def __init__(self, parent=None) -> None:
        super().__init__(parent)
        self.setScene(QGraphicsScene(self))
        self.item = QGraphicsPixmapItem()
        self.item.setTransformationMode(Qt.TransformationMode.SmoothTransformation)
        self.scene().addItem(self.item)
        self.setBackgroundBrush(QColor("black"))
        self.setFrameShape(QFrame.Shape.NoFrame)
        self.setRenderHints(QPainter.RenderHint.Antialiasing | QPainter.RenderHint.SmoothPixmapTransform)
        self.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        self.setVerticalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        self.setTransformationAnchor(QGraphicsView.ViewportAnchor.AnchorUnderMouse)
        self.setDragMode(QGraphicsView.DragMode.ScrollHandDrag)
        self.fitted = True
        self._swipe = 0.0
        self._swipe_at = 0.0
        self._press: QPoint | None = None
        self._tap = QTimer(self)
        self._tap.setSingleShot(True)
        self._tap.setInterval(_double_click_ms())
        self._tap.timeout.connect(self.tapped.emit)
        self.message = ""

    def show_image(self, img: QImage | None, message: str = "") -> None:
        self.message = message
        self.item.setPixmap(QPixmap.fromImage(img) if img is not None and not img.isNull() else QPixmap())
        self.scene().setSceneRect(QRectF(self.item.pixmap().rect()))
        self.fit()
        self.viewport().update()

    def _fit_scale(self) -> float:
        pm = self.item.pixmap()
        r = self.viewport().rect()
        scale = min(r.width() / max(pm.width(), 1), r.height() / max(pm.height(), 1))
        # Filled to the window, which has the photo's shape — a small photo is enlarged rather than left
        # in a black frame (only a tiny one is held back).
        return min(scale, 8.0 if max(pm.width(), pm.height()) >= 200 else 3.0)

    def fit(self) -> None:
        self.resetTransform()
        pm = self.item.pixmap()
        if not pm.isNull():
            scale = self._fit_scale()
            self.scale(scale, scale)
            self.centerOn(self.item)
        self.fitted = True
        self.zoom_changed.emit()

    def scale_now(self) -> float:
        return self.transform().m11()

    def zoom(self, factor: float, at: QPoint | None = None) -> None:
        if self.item.pixmap().isNull():
            return
        current = self.transform().m11()
        target = max(0.05, min(current * factor, 16.0))
        self.setTransformationAnchor(QGraphicsView.ViewportAnchor.AnchorUnderMouse if at is not None
                                     else QGraphicsView.ViewportAnchor.AnchorViewCenter)
        self.scale(target / current, target / current)
        self.setTransformationAnchor(QGraphicsView.ViewportAnchor.AnchorUnderMouse)
        self.fitted = False
        self.zoom_changed.emit()

    def actual_size(self, at: QPoint) -> None:
        scene_pt = self.mapToScene(at)
        self.resetTransform()
        self.centerOn(scene_pt)
        self.fitted = False
        self.zoom_changed.emit()

    def resizeEvent(self, event) -> None:  # noqa: N802
        super().resizeEvent(event)
        if self.fitted:
            self.fit()

    def drawForeground(self, painter: QPainter, rect: QRectF) -> None:  # noqa: N802
        if self.message and self.item.pixmap().isNull():
            painter.save()
            painter.resetTransform()
            painter.setPen(QColor(200, 200, 205))
            painter.drawText(self.viewport().rect(), Qt.AlignmentFlag.AlignCenter, self.message)
            painter.restore()

    def wheel_zoom(self, factor: float, at: QPoint) -> None:
        """The wheel's zoom, about the pointer: in as far as zoom goes, out no further than the fit."""
        if self.item.pixmap().isNull():
            return
        if factor < 1 and (self.fitted or self.scale_now() * factor <= self._fit_scale() * 1.001):
            if not self.fitted:
                self.fit()
            return
        self.zoom(factor, at)

    def wheelEvent(self, event) -> None:  # noqa: N802
        if wheel_zooms(event):
            self.wheel_zoom(wheel_factor(event), event.position().toPoint())
            event.accept()
            return
        dx, dy = event.pixelDelta().x() or event.angleDelta().x() / 4, event.pixelDelta().y() or event.angleDelta().y() / 4
        if self.fitted and abs(dx) > abs(dy):
            now = time.monotonic()
            if now - self._swipe_at > 0.6:             # a new swipe: count afresh
                self._swipe = 0.0
            self._swipe += dx
            if abs(self._swipe) > 120 and now - self._swipe_at > 0.6:
                self._swipe_at = now
                self.swiped.emit(-1 if self._swipe > 0 else 1)
                self._swipe = 0.0
            return
        if not self.fitted:
            super().wheelEvent(event)

    def event(self, event) -> bool:
        if event.type() == event.Type.NativeGesture:
            kind = event.gestureType()
            if kind == Qt.NativeGestureType.ZoomNativeGesture:
                self.zoom(1.0 + event.value(), event.position().toPoint())
                return True
            if kind == Qt.NativeGestureType.SmartZoomNativeGesture:
                self.fit() if not self.fitted else self.actual_size(event.position().toPoint())
                return True
        return super().event(event)

    def mousePressEvent(self, event) -> None:  # noqa: N802
        self._press = event.position().toPoint()
        super().mousePressEvent(event)

    def mouseReleaseEvent(self, event) -> None:  # noqa: N802
        super().mouseReleaseEvent(event)
        if self._press is not None and (event.position().toPoint() - self._press).manhattanLength() < 4:
            self._tap.start()                           # a click — unless a double-click follows
        self._press = None

    def mouseDoubleClickEvent(self, event) -> None:  # noqa: N802
        self._tap.stop()
        if self.fitted:
            self.actual_size(event.position().toPoint())
        else:
            self.fit()


WHEEL_STEP = 1.0015                          # zoom per eighth of a degree: one wheel notch (120) ≈ 1.2×


def wheel_zooms(event) -> bool:
    """Whether a scroll zooms: a mouse's scroll wheel does (its events come without a scroll phase), and so does
    ⌘- or Ctrl-scroll. A trackpad's or Magic Mouse's two-finger scroll (phased) keeps swiping to the next item
    and panning a zoomed picture — pinching zooms there."""
    if event.modifiers() & (Qt.KeyboardModifier.ControlModifier | Qt.KeyboardModifier.MetaModifier):
        return True
    return event.phase() == Qt.ScrollPhase.NoScrollPhase and not event.angleDelta().isNull()


def wheel_factor(event) -> float:
    """Wheel toward you (down) zooms in, away from you (up) zooms out — the way the person asked for it (Nov 9;
    it was the other way round)."""
    steps = event.angleDelta().y() or event.angleDelta().x()     # ⇧-scroll turns a wheel's notches sideways
    return WHEEL_STEP ** -steps


def _double_click_ms() -> int:
    from PySide6.QtWidgets import QApplication
    return QApplication.doubleClickInterval() if QApplication.instance() else 300


# ----------------------------------------------------------------------------- icons

def _heart(r: QRectF) -> QPainterPath:
    x, y, w, h = r.x(), r.y(), r.width(), r.height()
    path = QPainterPath()
    path.moveTo(x + w * 0.5, y + h)
    path.cubicTo(x + w * 0.08, y + h * 0.66, x - w * 0.02, y + h * 0.32, x + w * 0.2, y + h * 0.1)
    path.cubicTo(x + w * 0.34, y - h * 0.02, x + w * 0.48, y + h * 0.06, x + w * 0.5, y + h * 0.2)
    path.cubicTo(x + w * 0.52, y + h * 0.06, x + w * 0.66, y - h * 0.02, x + w * 0.8, y + h * 0.1)
    path.cubicTo(x + w * 1.02, y + h * 0.32, x + w * 0.92, y + h * 0.66, x + w * 0.5, y + h)
    path.closeSubpath()
    return path


def _star(c: QPointF, r: float) -> QPainterPath:
    path = QPainterPath()
    k = r * 0.22
    path.moveTo(c.x(), c.y() - r)
    path.quadTo(c.x() + k, c.y() - k, c.x() + r, c.y())
    path.quadTo(c.x() + k, c.y() + k, c.x(), c.y() + r)
    path.quadTo(c.x() - k, c.y() + k, c.x() - r, c.y())
    path.quadTo(c.x() - k, c.y() - k, c.x(), c.y() - r)
    path.closeSubpath()
    return path


def icon(name: str, color: str = "#F2F2F7", size: int = 18) -> QIcon:
    """The viewer's line icons, drawn so they match on every Mac (no emoji fallbacks)."""
    dpr = 3
    pm = QPixmap(size * dpr, size * dpr)
    pm.fill(Qt.GlobalColor.transparent)
    pm.setDevicePixelRatio(dpr)
    p = QPainter(pm)
    p.setRenderHint(QPainter.RenderHint.Antialiasing)
    c = QColor(color)
    p.setPen(QPen(c, 1.7, Qt.PenStyle.SolidLine, Qt.PenCapStyle.RoundCap, Qt.PenJoinStyle.RoundJoin))
    s = float(size)
    if name == "close":
        p.drawLine(QPointF(s * 0.28, s * 0.28), QPointF(s * 0.72, s * 0.72))
        p.drawLine(QPointF(s * 0.72, s * 0.28), QPointF(s * 0.28, s * 0.72))
    elif name in ("heart", "heart.fill"):
        if name == "heart.fill":
            p.setBrush(c)
        p.drawPath(_heart(QRectF(s * 0.14, s * 0.2, s * 0.72, s * 0.64)))
    elif name == "sparkles":
        p.setPen(Qt.PenStyle.NoPen)
        p.setBrush(c)
        p.drawPath(_star(QPointF(s * 0.42, s * 0.58), s * 0.32))
        p.drawPath(_star(QPointF(s * 0.76, s * 0.24), s * 0.16))
    elif name == "camera":
        p.drawRoundedRect(QRectF(s * 0.12, s * 0.3, s * 0.76, s * 0.5), 2.5, 2.5)
        p.drawLine(QPointF(s * 0.36, s * 0.3), QPointF(s * 0.42, s * 0.2))
        p.drawLine(QPointF(s * 0.42, s * 0.2), QPointF(s * 0.58, s * 0.2))
        p.drawLine(QPointF(s * 0.58, s * 0.2), QPointF(s * 0.64, s * 0.3))
        p.drawEllipse(QPointF(s * 0.5, s * 0.55), s * 0.14, s * 0.14)
    elif name == "frames":                                    # a strip of film
        p.drawRoundedRect(QRectF(s * 0.16, s * 0.18, s * 0.68, s * 0.64), 2, 2)
        p.drawLine(QPointF(s * 0.32, s * 0.18), QPointF(s * 0.32, s * 0.82))
        p.drawLine(QPointF(s * 0.68, s * 0.18), QPointF(s * 0.68, s * 0.82))
    elif name == "info":
        p.drawEllipse(QPointF(s * 0.5, s * 0.5), s * 0.36, s * 0.36)
        p.drawLine(QPointF(s * 0.5, s * 0.46), QPointF(s * 0.5, s * 0.68))
        p.setBrush(c)
        p.drawEllipse(QPointF(s * 0.5, s * 0.33), s * 0.03, s * 0.03)
    elif name == "more":
        p.setPen(Qt.PenStyle.NoPen)
        p.setBrush(c)
        for x in (0.26, 0.5, 0.74):
            p.drawEllipse(QPointF(s * x, s * 0.5), s * 0.07, s * 0.07)
    elif name == "play":
        p.setPen(Qt.PenStyle.NoPen)
        p.setBrush(c)
        path = QPainterPath()
        path.moveTo(s * 0.3, s * 0.2)
        path.lineTo(s * 0.8, s * 0.5)
        path.lineTo(s * 0.3, s * 0.8)
        path.closeSubpath()
        p.drawPath(path)
    elif name == "pause":
        p.setPen(Qt.PenStyle.NoPen)
        p.setBrush(c)
        p.drawRoundedRect(QRectF(s * 0.26, s * 0.2, s * 0.16, s * 0.6), 1.5, 1.5)
        p.drawRoundedRect(QRectF(s * 0.58, s * 0.2, s * 0.16, s * 0.6), 1.5, 1.5)
    elif name in ("speaker", "speaker.off"):
        path = QPainterPath()
        path.moveTo(s * 0.14, s * 0.4)
        path.lineTo(s * 0.3, s * 0.4)
        path.lineTo(s * 0.5, s * 0.22)
        path.lineTo(s * 0.5, s * 0.78)
        path.lineTo(s * 0.3, s * 0.6)
        path.lineTo(s * 0.14, s * 0.6)
        path.closeSubpath()
        p.drawPath(path)
        if name == "speaker":
            p.drawArc(QRectF(s * 0.46, s * 0.3, s * 0.28, s * 0.4), -50 * 16, 100 * 16)
            p.drawArc(QRectF(s * 0.46, s * 0.18, s * 0.42, s * 0.64), -50 * 16, 100 * 16)
        else:
            p.drawLine(QPointF(s * 0.62, s * 0.38), QPointF(s * 0.86, s * 0.62))
            p.drawLine(QPointF(s * 0.86, s * 0.38), QPointF(s * 0.62, s * 0.62))
    elif name in ("prev", "next"):
        x0, x1 = (s * 0.62, s * 0.36) if name == "prev" else (s * 0.38, s * 0.64)
        p.drawPolyline([QPointF(x0, s * 0.2), QPointF(x1, s * 0.5), QPointF(x0, s * 0.8)])
    elif name in ("minus", "plus"):
        p.drawLine(QPointF(s * 0.24, s * 0.5), QPointF(s * 0.76, s * 0.5))
        if name == "plus":
            p.drawLine(QPointF(s * 0.5, s * 0.24), QPointF(s * 0.5, s * 0.76))
    p.end()
    return QIcon(pm)


# ----------------------------------------------------------------------------- the scrubber

class _Scrubber(QSlider):
    """The video's timeline: a click anywhere along it jumps there (a plain slider would only page a step), then
    drags on; hovering shows the time under the pointer."""

    def __init__(self) -> None:
        super().__init__(Qt.Orientation.Horizontal)
        self.setObjectName("Scrubber")
        self.setMouseTracking(True)
        self.setRange(0, 0)
        self.setCursor(Qt.CursorShape.PointingHandCursor)

    def _value_at(self, x: float) -> int:
        opt = QStyleOptionSlider()
        self.initStyleOption(opt)
        groove = self.style().subControlRect(QStyle.ComplexControl.CC_Slider, opt,
                                             QStyle.SubControl.SC_SliderGroove, self)
        handle = self.style().subControlRect(QStyle.ComplexControl.CC_Slider, opt,
                                             QStyle.SubControl.SC_SliderHandle, self)
        span = max(1, groove.width() - handle.width())
        return QStyle.sliderValueFromPosition(self.minimum(), self.maximum(),
                                              int(x - groove.x() - handle.width() / 2), span)

    def mousePressEvent(self, event) -> None:  # noqa: N802
        if event.button() == Qt.MouseButton.LeftButton and self.maximum() > 0:
            opt = QStyleOptionSlider()
            self.initStyleOption(opt)
            handle = self.style().subControlRect(QStyle.ComplexControl.CC_Slider, opt,
                                                 QStyle.SubControl.SC_SliderHandle, self)
            if not handle.contains(event.position().toPoint()):
                v = self._value_at(event.position().x())
                self.setValue(v)
                self.sliderMoved.emit(v)
        super().mousePressEvent(event)

    def mouseMoveEvent(self, event) -> None:  # noqa: N802
        super().mouseMoveEvent(event)
        if self.maximum() > 0:
            ms = self._value_at(event.position().x())
            QToolTip.showText(event.globalPosition().toPoint(), media_info.clock(ms / 1000), self)


# ----------------------------------------------------------------------------- the stage macOS draws

MAX_HDR_PIXELS = 24_000_000      # an HDR photo is held as 16-bit floats (8 bytes a pixel): bigger is shown smaller


class _NativeStage(QWidget):
    """Where macOS draws the picture itself (`viewer_surface`): a video by AVFoundation — QuickTime Player's own
    player, so HDR looks as it does there — or an HDR photo in HDR. The widget has its own native view for the
    surface to live in; Qt keeps where the picture goes (`picture_rect`: fitted, zoomed about a point, dragged —
    as `_ImageStage` does for photos) and gets every click, which the surface lets through. `tapped`, `swiped`
    and `zoom_changed` as `_ImageStage`; `picture_done(ok)` once a photo has been read, or couldn't be."""
    tapped = Signal()
    swiped = Signal(int)
    zoom_changed = Signal()
    picture_done = Signal(bool)

    def __init__(self, parent=None) -> None:
        super().__init__(parent)
        self.setAttribute(Qt.WidgetAttribute.WA_DontCreateNativeAncestors)   # only this widget goes native
        self.setAutoFillBackground(True)
        pal = self.palette()
        pal.setColor(self.backgroundRole(), QColor("black"))
        self.setPalette(pal)
        self.surface: viewer_surface.Surface | None = None
        self.path = ""
        self.content = QSize()            # the picture's size in pixels, upright
        self.fitted = True
        self._scale = 1.0                 # points per pixel of the picture
        self._origin = QPointF()          # the picture's top left in this widget
        self._press: QPointF | None = None
        self._origin_at_press = QPointF()
        self._swipe = 0.0
        self._swipe_at = 0.0
        self._tap = QTimer(self)
        self._tap.setSingleShot(True)
        self._tap.setInterval(_double_click_ms())
        self._tap.timeout.connect(self.tapped.emit)
        self._watch = QTimer(self)        # a photo being read
        self._watch.setInterval(40)
        self._watch.timeout.connect(self._check_picture)

    def attach(self) -> bool:
        """The surface, made the first time it's wanted (False while the library is being built, or without it)."""
        if self.surface is not None:
            return True
        lib = viewer_surface.library()
        if lib is None:
            return False
        try:
            self.surface = viewer_surface.Surface(lib, int(self.winId()))
        except (OSError, TypeError, ValueError):
            return False
        self.surface.layout()
        self._apply()
        return True

    def release(self) -> None:
        self._watch.stop()
        if self.surface is not None:
            self.surface.destroy()
            self.surface = None

    # -- what's shown
    def show_video(self, path: str, size: QSize) -> bool:
        if not self.attach():
            return False
        self._watch.stop()
        self.path, self.content = path, QSize(size)
        self.surface.open_video(path)
        self.fit()
        return True

    def show_picture(self, path: str, size: QSize) -> bool:
        """Starts reading an HDR photo; `picture_done` says when it's there to be shown."""
        if not self.attach():
            return False
        self.path, self.content = path, QSize(size)
        self.surface.open_image(path, MAX_HDR_PIXELS)
        self.fit()
        self._watch.start()
        return True

    def clear(self) -> None:
        self._watch.stop()
        self.path, self.content = "", QSize()
        if self.surface is not None:
            self.surface.clear()

    def adopt_size(self) -> None:
        """The picture's size from macOS, when the file's header didn't give one."""
        if self.content.isEmpty() and self.surface is not None:
            w, h = self.surface.content_size()
            if w >= 1 and h >= 1:
                self.content = QSize(round(w), round(h))
                self.fit()

    def _check_picture(self) -> None:
        state = self.surface.state() if self.surface is not None else viewer_surface.FAILED
        if state == viewer_surface.LOADING:
            return
        self._watch.stop()
        if state == viewer_surface.READY:
            self.adopt_size()
        self.picture_done.emit(state == viewer_surface.READY)

    # -- where the picture goes
    def _fit_scale(self) -> float:
        w, h = self.content.width(), self.content.height()
        if w <= 0 or h <= 0 or self.width() <= 0 or self.height() <= 0:
            return 1.0
        return min(self.width() / w, self.height() / h)

    def picture_rect(self) -> QRectF:
        """Where the picture is drawn: centred along a side it doesn't fill, never pulled in from an edge it
        overflows (so a drag can't lose it)."""
        if self.content.isEmpty():
            return QRectF(0, 0, self.width(), self.height())
        w, h = self.content.width() * self._scale, self.content.height() * self._scale
        x = (self.width() - w) / 2 if w <= self.width() else min(0.0, max(self.width() - w, self._origin.x()))
        y = (self.height() - h) / 2 if h <= self.height() else min(0.0, max(self.height() - h, self._origin.y()))
        self._origin = QPointF(x, y)
        return QRectF(x, y, w, h)

    def _apply(self) -> None:
        r = self.picture_rect()
        if self.surface is not None:
            self.surface.set_rect(r.x(), r.y(), r.width(), r.height())
        if self.fitted:
            self.unsetCursor()
        elif self._press is None:
            self.setCursor(Qt.CursorShape.OpenHandCursor)

    def scale_now(self) -> float:
        return self._scale

    def fit(self) -> None:
        self._scale = self._fit_scale()
        self._origin = QPointF()
        self.fitted = True
        self._apply()
        self.zoom_changed.emit()

    def _zoom_to(self, target: float, at: QPointF | QPoint | None) -> None:
        p = QPointF(at) if at is not None else QPointF(self.width() / 2, self.height() / 2)
        k = target / max(self._scale, 1e-9)
        self._origin = p - (p - self._origin) * k
        self._scale = target
        self.fitted = False
        self._apply()
        self.zoom_changed.emit()

    def zoom(self, factor: float, at: QPointF | QPoint | None = None) -> None:
        """In or out about `at` (the middle when None); back out past the fit, it fits."""
        if self.content.isEmpty():
            return
        target = min(self._scale * factor, 16.0)
        if target <= self._fit_scale() * 1.001:
            if not self.fitted:
                self.fit()
            return
        self._zoom_to(target, at)

    def actual_size(self, at: QPointF | QPoint | None = None) -> None:
        """100 %: one pixel of the picture to one point."""
        if self.content.isEmpty():
            return
        if abs(self._fit_scale() - 1.0) < 1e-3:
            self.fit()
        else:
            self._zoom_to(1.0, at)

    # -- Qt's events (the surface passes them all through)
    def resizeEvent(self, event) -> None:  # noqa: N802
        super().resizeEvent(event)
        if self.surface is not None:
            self.surface.layout()
        if self.fitted:
            self.fit()
        else:
            old = event.oldSize()
            if old.isValid():
                self._origin += QPointF((self.width() - old.width()) / 2, (self.height() - old.height()) / 2)
            self._apply()

    def showEvent(self, event) -> None:  # noqa: N802
        super().showEvent(event)
        if self.surface is not None:
            self.surface.layout()
            self._apply()

    def mousePressEvent(self, event) -> None:  # noqa: N802
        if event.button() == Qt.MouseButton.LeftButton:
            self._press = event.position()
            self._origin_at_press = QPointF(self._origin)
            if not self.fitted:
                self.setCursor(Qt.CursorShape.ClosedHandCursor)
        event.accept()                    # not on to the video stage, which would count it as a tap too

    def mouseMoveEvent(self, event) -> None:  # noqa: N802
        if self._press is not None and not self.fitted:
            self._origin = self._origin_at_press + (event.position() - self._press)
            self._apply()
        event.accept()

    def mouseReleaseEvent(self, event) -> None:  # noqa: N802
        if self._press is not None and (event.position() - self._press).manhattanLength() < 4:
            self._tap.start()             # a click — unless a double-click follows
        self._press = None
        self._apply()
        event.accept()

    def mouseDoubleClickEvent(self, event) -> None:  # noqa: N802
        self._tap.stop()
        if self.fitted:
            self.actual_size(event.position())
        else:
            self.fit()
        event.accept()

    def wheelEvent(self, event) -> None:  # noqa: N802
        event.accept()
        if wheel_zooms(event):                        # zoom() stops at the fit going out
            self.zoom(wheel_factor(event), event.position())
            return
        dx = event.pixelDelta().x() or event.angleDelta().x() / 4
        dy = event.pixelDelta().y() or event.angleDelta().y() / 4
        if not self.fitted:
            self._origin += QPointF(dx, dy)           # scrolling pans a zoomed picture
            self._apply()
            return
        if abs(dx) > abs(dy):
            now = time.monotonic()
            if now - self._swipe_at > 0.6:            # a new swipe: count afresh
                self._swipe = 0.0
            self._swipe += dx
            if abs(self._swipe) > 120 and now - self._swipe_at > 0.6:
                self._swipe_at = now
                self.swiped.emit(-1 if self._swipe > 0 else 1)
                self._swipe = 0.0

    def event(self, event) -> bool:
        if event.type() == event.Type.NativeGesture:
            kind = event.gestureType()
            if kind == Qt.NativeGestureType.ZoomNativeGesture:
                self.zoom(1.0 + event.value(), event.position())
                return True
            if kind == Qt.NativeGestureType.SmartZoomNativeGesture:
                self.fit() if not self.fitted else self.actual_size(event.position())
                return True
        return super().event(event)


# ----------------------------------------------------------------------------- the video stage

def saved_volume() -> float:
    """The viewer's volume, 0…1, as last set (full at first)."""
    from PySide6.QtCore import QSettings
    try:
        return max(0.0, min(1.0, float(QSettings("PhotoBrowser", "SafeFinder").value("viewer/volume", 1.0))))
    except (TypeError, ValueError):
        return 1.0


def remember_volume(volume: float) -> None:
    from PySide6.QtCore import QSettings
    QSettings("PhotoBrowser", "SafeFinder").setValue("viewer/volume", round(volume, 3))


def loudness(volume: float) -> float:
    """The slider's 0…1 to the players' gain. Both take a straight amplitude, which makes the top half of a
    linear slider sound all the same; squared, each part of the slider changes the sound about evenly."""
    return max(0.0, min(1.0, volume)) ** 2


def multimedia():
    """Qt Multimedia's classes, or None when this PySide6 hasn't got them."""
    try:
        from PySide6.QtMultimedia import QAudioOutput, QMediaPlayer
        from PySide6.QtMultimediaWidgets import QVideoWidget
        return QMediaPlayer, QAudioOutput, QVideoWidget
    except ImportError:
        return None


# What AVFoundation can't open: Qt's player (FFmpeg) plays these. Anything else it turns down falls back too.
QT_ONLY = {".mkv", ".webm", ".avi", ".wmv", ".flv"}


class _VideoStage(QWidget):
    """A video. On a Mac macOS plays it (`_NativeStage`: AVFoundation, as QuickTime Player — HDR shown as HDR);
    what AVFoundation can't open (MKV, WebM, AVI…), or everything while the native surface isn't there, Qt
    Multimedia plays — fitted, into a `QVideoWidget` (the fast path); zoomed in, into a `QGraphicsVideoItem` in a
    view that can be scaled and dragged like a photo, and back to the widget when fitted again. Without either:
    the video's picture and QuickTime Player."""
    tapped = Signal()
    swiped = Signal(int)
    ended = Signal()
    position_changed = Signal(int, int)        # ms, duration ms
    playing_changed = Signal(bool)
    zoom_changed = Signal()

    def __init__(self, parent=None) -> None:
        super().__init__(parent)
        self.setAutoFillBackground(True)
        pal = self.palette()
        pal.setColor(self.backgroundRole(), QColor("black"))
        self.setPalette(pal)
        self.pages = QStackedLayout(self)
        self.pages.setContentsMargins(0, 0, 0, 0)
        mm = multimedia()
        self.path = ""
        self.backend = ""                      # "native", "qt", or "" (nothing playing)
        self._loop = True
        self._muted = False
        self._volume = saved_volume()
        self._autoplay = True
        self._length_ms = 0
        self._poster_image: QImage | None = None
        self._reported: tuple | None = None    # what the native player last told the bars
        self.fps = 30.0
        self._qt_fitted = True
        self.size_shown = QSize()
        self.player = self.audio = self.video = None
        self.zoom_view: QGraphicsView | None = None
        self.zoom_item = None
        self._fit_scale = 1.0
        self.poster = QLabel()
        self.poster.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.poster.setStyleSheet("color: #C8C8CD; background: black;")
        if mm is not None:
            QMediaPlayer, QAudioOutput, QVideoWidget = mm
            self.video = QVideoWidget(self)
            self.video.setStyleSheet("background: black;")
            self.player = QMediaPlayer(self)
            self.audio = QAudioOutput(self)
            self.audio.setVolume(loudness(self._volume))
            self.player.setAudioOutput(self.audio)
            self.player.setVideoOutput(self.video)
            # Only while Qt is the one playing: a late "stopped" from the last video mustn't reach the bars
            # while macOS plays this one.
            self.player.positionChanged.connect(
                lambda ms: self.position_changed.emit(ms, self.player.duration()) if self.backend == "qt" else None)
            self.player.durationChanged.connect(
                lambda d: self.position_changed.emit(self.player.position(), d) if self.backend == "qt" else None)
            self.player.playbackStateChanged.connect(
                lambda st: self.playing_changed.emit(st == QMediaPlayer.PlaybackState.PlayingState)
                if self.backend == "qt" else None)
            self.player.mediaStatusChanged.connect(self._status)
            self.pages.addWidget(self.video)
        self.pages.addWidget(self.poster)
        self.native = _NativeStage() if viewer_surface.wanted() else None
        if self.native is not None:
            self.native.tapped.connect(self.tapped)
            self.native.swiped.connect(self.swiped)
            self.native.zoom_changed.connect(self.zoom_changed)
            self.pages.addWidget(self.native)
        self._ticker = QTimer(self)            # the native player's progress, for the bars
        self._ticker.setInterval(50)
        self._ticker.timeout.connect(self._tick)

    @property
    def available(self) -> bool:
        return self.player is not None or self.native is not None

    @property
    def loop(self) -> bool:
        return self._loop

    @loop.setter
    def loop(self, on: bool) -> None:
        self._loop = bool(on)
        if self.native is not None and self.native.surface is not None:
            self.native.surface.set_loop(self._loop)

    @property
    def fitted(self) -> bool:
        return self.native.fitted if self.backend == "native" else self._qt_fitted

    def _surface(self) -> viewer_surface.Surface | None:
        return self.native.surface if self.backend == "native" and self.native is not None else None

    def show_video(self, path: str, poster: QImage | None = None, autoplay: bool = True) -> None:
        self.stop()
        self.path = path
        info = media_info.video_info(path)
        self.size_shown = QSize(int(info.get("width") or 0), int(info.get("height") or 0))
        self.fps = float(info.get("fps") or 30.0)
        self._length_ms = int((info.get("duration") or 0) * 1000)
        self._poster_image, self._autoplay = poster, autoplay
        native = self.native
        if native is not None and os.path.splitext(path)[1].lower() not in QT_ONLY \
                and native.show_video(path, self.size_shown):
            self.backend = "native"
            s = native.surface
            s.set_loop(self._loop)
            s.set_muted(self._muted)
            s.set_volume(loudness(self._volume))
            s.set_rate(1.0)
            if autoplay:
                s.play()
            self.pages.setCurrentWidget(native)
            self._reported = None
            self.position_changed.emit(0, self._length_ms)
            self._ticker.start()
            return
        self._show_with_qt()

    def _show_with_qt(self) -> None:
        self._qt_fit()
        if self.player is None:
            self.backend = ""
            poster = self._poster_image
            if poster is not None and not poster.isNull():
                self.poster.setText("")
                self.poster.setPixmap(QPixmap.fromImage(poster).scaled(
                    self.size() * 0.98, Qt.AspectRatioMode.KeepAspectRatio, Qt.TransformationMode.SmoothTransformation))
            else:
                self.poster.setPixmap(QPixmap())
                self.poster.setText("This Mac's Qt can't play videos here — use Open With… to play it in QuickTime Player.")
            self.pages.setCurrentWidget(self.poster)
            self.position_changed.emit(0, self._length_ms)
            return
        self.backend = "qt"
        self.pages.setCurrentWidget(self.video)
        self.player.setSource(QUrl.fromLocalFile(self.path))
        self.player.setPlaybackRate(1.0)
        if self._autoplay:
            self.player.play()

    def _tick(self) -> None:
        """The native player's progress to the bars; a video macOS turned down goes to Qt's player."""
        s = self._surface()
        if s is None:
            self._ticker.stop()
            return
        state = s.state()
        if state == viewer_surface.FAILED:
            self._ticker.stop()
            self.native.clear()
            self._show_with_qt()
            return
        if state == viewer_surface.READY:
            self.native.adopt_size()
        length = int(s.duration() * 1000) or self._length_ms
        playing = s.is_playing()
        now = (int(s.position() * 1000), length, playing)
        if now != self._reported:
            if self._reported is None or now[:2] != self._reported[:2]:
                self.position_changed.emit(now[0], length)
            if self._reported is None or playing != self._reported[2]:
                self.playing_changed.emit(playing)
            self._reported = now
        if s.take_ended():
            self.ended.emit()

    def stop(self) -> None:
        self._ticker.stop()
        if self.native is not None:
            self.native.clear()
        if self.player is not None:
            self._qt_fit()
            self.player.stop()
            self.player.setSource(QUrl())
        self.backend = ""

    def release(self) -> None:
        """The window is closing: the native player goes too."""
        self.stop()
        if self.native is not None:
            self.native.release()

    def toggle(self) -> None:
        if self.is_playing():
            self.pause()
        else:
            self.play()

    def play(self) -> None:
        s = self._surface()
        if s is not None:
            s.play()
        elif self.backend == "qt":
            self.player.play()

    def pause(self) -> None:
        s = self._surface()
        if s is not None:
            s.pause()
        elif self.backend == "qt":
            self.player.pause()

    def is_playing(self) -> bool:
        s = self._surface()
        if s is not None:
            return s.is_playing()
        if self.backend != "qt":
            return False
        from PySide6.QtMultimedia import QMediaPlayer
        return self.player.playbackState() == QMediaPlayer.PlaybackState.PlayingState

    def duration_ms(self) -> int:
        s = self._surface()
        if s is not None:
            return int(s.duration() * 1000) or self._length_ms
        return self.player.duration() if self.backend == "qt" else self._length_ms

    def seek(self, ms: int) -> None:
        length = self.duration_ms()
        ms = max(0, min(int(ms), length or int(ms)))
        s = self._surface()
        if s is not None:
            s.seek(ms / 1000)
        elif self.backend == "qt":
            self.player.setPosition(ms)

    def skip(self, seconds: float) -> None:
        self.seek(int(self.position_s() * 1000) + int(seconds * 1000))

    def step(self, frames: int) -> None:
        """One frame back or on (paused first — the iPhone's frame step)."""
        s = self._surface()
        if s is not None:
            s.step(frames)
        elif self.backend == "qt":
            self.player.pause()
            self.seek(self.player.position() + int(round(frames * 1000 / max(self.fps, 1))))

    def set_rate(self, rate: float) -> None:
        s = self._surface()
        if s is not None:
            s.set_rate(rate)
        elif self.player is not None:
            self.player.setPlaybackRate(rate)

    def set_muted(self, muted: bool) -> None:
        self._muted = muted
        if self.native is not None and self.native.surface is not None:
            self.native.surface.set_muted(muted)
        if self.audio is not None:
            self.audio.setMuted(muted)

    def set_volume(self, volume: float) -> None:
        """0…1 as the slider shows it; the players get `loudness` of it."""
        self._volume = max(0.0, min(1.0, volume))
        gain = loudness(self._volume)
        if self.native is not None and self.native.surface is not None:
            self.native.surface.set_volume(gain)
        if self.audio is not None:
            self.audio.setVolume(gain)

    def position_s(self) -> float:
        s = self._surface()
        if s is not None:
            return s.position()
        return (self.player.position() / 1000) if self.backend == "qt" else 0.0

    # -- zoom
    def _zoomer(self) -> bool:
        """The zoomable view, made the first time it's wanted (False when this Qt can't draw video into one)."""
        if self.zoom_view is not None:
            return True
        if self.player is None:
            return False
        try:
            from PySide6.QtMultimediaWidgets import QGraphicsVideoItem
        except ImportError:
            return False
        view = QGraphicsView()
        view.setScene(QGraphicsScene(view))
        view.setBackgroundBrush(QColor("black"))
        view.setFrameShape(QFrame.Shape.NoFrame)
        view.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        view.setVerticalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        view.setTransformationAnchor(QGraphicsView.ViewportAnchor.AnchorUnderMouse)
        view.setDragMode(QGraphicsView.DragMode.ScrollHandDrag)
        item = QGraphicsVideoItem()
        view.scene().addItem(item)
        view.viewport().installEventFilter(self)      # its wheel zooms too, rather than scrolling the view
        self.zoom_view, self.zoom_item = view, item
        self.pages.addWidget(view)
        return True

    def scale_now(self) -> float:
        if self.backend == "native":
            return self.native.scale_now()
        if self._qt_fitted or self.zoom_view is None:
            return self._fit_scale
        return self.zoom_view.transform().m11()

    def zoom(self, factor: float, at: QPoint | None = None) -> None:
        if self.backend == "native":
            self.native.zoom(factor, at)
            return
        if self.backend != "qt":
            return
        if self._qt_fitted:
            if factor <= 1.0 or not self._zoomer():
                return
            w, h = self.size_shown.width(), self.size_shown.height()
            if w <= 0 or h <= 0:
                w, h = max(self.width(), 1), max(self.height(), 1)
            self.zoom_item.setSize(QSizeF(w, h))
            self.zoom_view.scene().setSceneRect(QRectF(0, 0, w, h))
            self._fit_scale = min(self.width() / w, self.height() / h)
            self.player.setVideoOutput(self.zoom_item)
            self.pages.setCurrentWidget(self.zoom_view)
            self.zoom_view.resetTransform()
            target = self._fit_scale * factor
            self.zoom_view.scale(target, target)
            self.zoom_view.centerOn(self.zoom_item)
            self._qt_fitted = False
        else:
            current = self.zoom_view.transform().m11()
            target = max(0.05, min(current * factor, 16.0))
            if target <= self._fit_scale * 1.001:
                self.fit()
                return
            self.zoom_view.setTransformationAnchor(QGraphicsView.ViewportAnchor.AnchorUnderMouse if at is not None
                                                   else QGraphicsView.ViewportAnchor.AnchorViewCenter)
            self.zoom_view.scale(target / current, target / current)
        self.zoom_changed.emit()

    def actual_size(self, at: QPoint | None = None) -> None:
        """100 %: one pixel of the video to one point."""
        if self.backend == "native":
            self.native.actual_size(at)
            return
        if self.backend != "qt":
            return
        if self._qt_fitted:
            self.zoom(max(1.01, 1.0 / max(self._fit_scale_for_size(), 1e-6)), at)
        if not self._qt_fitted:
            current = self.zoom_view.transform().m11()
            self.zoom_view.scale(1.0 / current, 1.0 / current)
            self.zoom_changed.emit()

    def _fit_scale_for_size(self) -> float:
        w, h = self.size_shown.width(), self.size_shown.height()
        if w <= 0 or h <= 0:
            return 1.0
        return min(self.width() / w, self.height() / h)

    def fit(self) -> None:
        if self.backend == "native":
            self.native.fit()
        else:
            self._qt_fit()

    def _qt_fit(self) -> None:
        if not self._qt_fitted and self.player is not None and self.video is not None:
            self.player.setVideoOutput(self.video)
            self.pages.setCurrentWidget(self.video)
        self._qt_fitted = True
        self._fit_scale = self._fit_scale_for_size()
        self.zoom_changed.emit()

    def resizeEvent(self, event) -> None:  # noqa: N802
        super().resizeEvent(event)
        if self._qt_fitted:
            self._fit_scale = self._fit_scale_for_size()

    def _status(self, status) -> None:
        if self.backend != "qt":
            return
        from PySide6.QtMultimedia import QMediaPlayer
        if status == QMediaPlayer.MediaStatus.EndOfMedia:
            if self.loop:
                self.player.setPosition(0)
                self.player.play()
            else:
                self.ended.emit()
        elif status == QMediaPlayer.MediaStatus.LoadedMedia:
            try:
                from PySide6.QtMultimedia import QMediaMetaData
                rate = self.player.metaData().value(QMediaMetaData.Key.VideoFrameRate)
                if rate:
                    self.fps = float(rate)
            except Exception:  # noqa: BLE001 — a frame rate is a nicety
                pass

    def mouseReleaseEvent(self, event) -> None:  # noqa: N802
        self.tapped.emit()                     # Qt's video, or the picture (the native stage takes its own)
        super().mouseReleaseEvent(event)

    def _wheel(self, event) -> bool:
        """The mouse wheel zooms Qt's video too (the native stage handles its own)."""
        if self.backend != "qt" or not wheel_zooms(event):
            return False
        self.zoom(wheel_factor(event), event.position().toPoint())
        event.accept()
        return True

    def wheelEvent(self, event) -> None:  # noqa: N802
        if not self._wheel(event):
            super().wheelEvent(event)

    def eventFilter(self, obj, event) -> bool:  # noqa: N802
        if self.zoom_view is not None and obj is self.zoom_view.viewport() and event.type() == QEvent.Type.Wheel:
            if self._wheel(event):
                return True
        return super().eventFilter(obj, event)


# ----------------------------------------------------------------------------- the window

def _bar_button(text: str, tip: str, slot, glyph: str = "") -> QToolButton:
    b = QToolButton()
    if glyph:
        b.setIcon(icon(glyph))
        b.setIconSize(QSize(18, 18))
    else:
        b.setText(text)
    b.setToolTip(tip)
    b.setObjectName("ViewerButton")
    b.setCursor(Qt.CursorShape.PointingHandCursor)
    b.setFocusPolicy(Qt.FocusPolicy.NoFocus)          # the keys belong to the viewer, not a button
    if slot is not None:
        b.clicked.connect(slot)
    return b


VIEWER_STYLE = f"""
#ViewerTop, #ViewerBottom {{ background: {CHROME_BG}; }}
#ViewerTop {{ border-bottom: 1px solid #2C2C2E; }}
#ViewerBottom {{ border-top: 1px solid #2C2C2E; }}
#ViewerTop QLabel, #ViewerBottom QLabel {{ color: #F2F2F7; }}
#ViewerTitle {{ font-size: 14px; font-weight: 600; }}
#ViewerCount {{ color: #A1A1A6; font-size: 12px; }}
#ViewerBottom QLabel#ViewerTime {{ color: #C7C7CC; font-size: 12px; }}
QLabel#ViewerRes {{ color: #A1A1A6; font-size: 11px; font-weight: 600; border: 1px solid rgba(255,255,255,0.22);
                    border-radius: 4px; padding: 1px 5px; }}
QLabel#ViewerHDR {{ color: #E8C46A; font-size: 11px; font-weight: 700; border: 1px solid rgba(232,196,106,0.45);
                    border-radius: 4px; padding: 1px 5px; }}
QToolButton#ViewerButton {{ color: #F2F2F7; background: transparent; border: none; border-radius: 7px;
                            padding: 4px 7px; font-size: 13px; }}
QToolButton#ViewerButton:hover {{ background: rgba(255,255,255,0.12); }}
QToolButton#ViewerButton:checked {{ background: rgba(255,255,255,0.14); }}
QToolButton#ViewerButton:disabled {{ color: #636366; }}
QToolButton#ViewerButton::menu-indicator {{ image: none; width: 0; }}
QToolButton#ZoomLabel {{ color: #C7C7CC; background: transparent; border: none; border-radius: 6px;
                         padding: 3px 6px; font-size: 12px; min-width: 38px; }}
QToolButton#ZoomLabel:hover {{ background: rgba(255,255,255,0.12); }}
#ViewerInfo {{ background: #1C1C1E; border-left: 1px solid #2C2C2E; }}
#ViewerInfo QLabel {{ color: #EBEBF0; }}
#InfoHead {{ color: #8E8E93; font-size: 11px; font-weight: 600; letter-spacing: 0.5px; }}
#InfoValue {{ font-size: 13px; }}
#InfoTag {{ background: #2C2C2E; border-radius: 9px; padding: 2px 9px; font-size: 12px; }}
#ViewerInfo QPushButton {{ color: #F2F2F7; background: #2C2C2E; border: 1px solid #3A3A3C; border-radius: 7px;
                          padding: 5px 12px; font-size: 13px; }}
#ViewerInfo QPushButton:hover {{ background: #3A3A3C; }}
QSlider#Scrubber {{ min-height: 18px; }}
QSlider#Scrubber::groove:horizontal {{ height: 4px; background: rgba(255,255,255,0.25); border-radius: 2px; }}
QSlider#Scrubber::sub-page:horizontal {{ background: #F2F2F7; border-radius: 2px; }}
QSlider#Scrubber::handle:horizontal {{ background: #FFFFFF; width: 13px; height: 13px; margin: -5px 0; border-radius: 6px; }}
QSlider#Volume {{ min-height: 18px; }}
QSlider#Volume::groove:horizontal {{ height: 3px; background: rgba(255,255,255,0.25); border-radius: 1px; }}
QSlider#Volume::sub-page:horizontal {{ background: #F2F2F7; border-radius: 1px; }}
QSlider#Volume::handle:horizontal {{ background: #FFFFFF; width: 11px; height: 11px; margin: -4px 0; border-radius: 5px; }}
#ViewerToast {{ background: rgba(44,44,46,0.95); color: #F2F2F7; border-radius: 10px; padding: 6px 14px; }}
"""
FAVORITE_RED = "#FF375F"


def available_geometry(widget: QWidget) -> QRect | None:
    """The usable part of the screen the window is on — below the menu bar, above the Dock (the bound it's
    fitted and kept within)."""
    screen = widget.screen() or QApplication.primaryScreen()
    return screen.availableGeometry() if screen is not None else None


AI_PURPLE = "#BF5AF2"
INFO_WIDTH = 300
TITLE_BAR = 28 if IS_MAC else 32          # the title bar's height until the window is up and can say


class MediaViewer(QWidget):
    """One window: the items of a listing, one at a time (module notes). `box`: Safe Finder's window — the
    viewer opens over it, on its display, as tall as that display."""
    closed = Signal()
    removed = Signal(list)                 # paths moved to the Trash from here
    _frame_saved = Signal(str, str)        # a saved frame's file ("" when it failed) and a note, from a worker thread
    _hdr_read = Signal(str, bool)          # a photo's HDR check, from a worker thread

    def __init__(self, paths: list[str], start: int = 0, hooks: Hooks | None = None, poster=None, parent=None,
                 box: QRect | None = None) -> None:
        super().__init__(parent, Qt.WindowType.Window)
        self.setAttribute(Qt.WidgetAttribute.WA_DeleteOnClose)
        self.paths = [p for p in paths if is_media(p)] or list(paths)
        first = paths[start] if 0 <= start < len(paths) else None
        self.index = self.paths.index(first) if first in self.paths else 0
        self.hooks = hooks or Hooks()
        self.poster = poster                       # path → QImage | None (the thumbnail), for a video's picture
        self.loader = _ImageLoader()
        self.loader.signals.done.connect(self._image_ready)
        self.chrome = True
        self.slideshow = False
        # The size each item is fitted within: None — the whole display (its full height) — until the window is
        # resized by hand (`resizeEvent`), then that size.
        self.box: QSize | None = None
        self.anchor = box.center() if box is not None and box.isValid() else None
        screen = QApplication.screenAt(self.anchor) if self.anchor is not None else None
        if screen is not None and hasattr(self, "setScreen"):
            self.setScreen(screen)                 # Safe Finder's display, not just the main one
        self._shown_once = False
        # Until then a resize is the system's (placing the window, leaving full screen), not a hand resize.
        self._settling = time.monotonic() + 1.5
        viewer_surface.prepare()
        self.fit_window = True
        self._fit_target: QSize | None = None
        self._hdr_cache: dict[str, bool] = {}
        self._was_playing = False
        self.setWindowTitle("Viewer")
        self.setStyleSheet(VIEWER_STYLE)
        self.setMinimumSize(380, 260)
        pal = self.palette()
        pal.setColor(self.backgroundRole(), QColor("black"))
        self.setPalette(pal)
        self.setAutoFillBackground(True)

        self.stack = QStackedWidget(self)
        self.image = _ImageStage()
        self.video = _VideoStage()
        self.stack.addWidget(self.image)
        self.stack.addWidget(self.video)
        # An HDR photo is shown by macOS, in HDR (`_show_hdr`): Qt's picture stands in until it's read.
        self.hdr = _NativeStage() if viewer_surface.wanted() else None
        if self.hdr is not None:
            self.stack.addWidget(self.hdr)
            self.hdr.swiped.connect(self.go)
            self.hdr.tapped.connect(self.toggle_chrome)
            self.hdr.zoom_changed.connect(self._zoom_label)
            self.hdr.picture_done.connect(self._hdr_shown)
        self.image.swiped.connect(self.go)
        self.video.swiped.connect(self.go)
        self.image.tapped.connect(self.toggle_chrome)
        self.video.tapped.connect(self.toggle_chrome)
        self.video.ended.connect(lambda: self.go(1) if self.slideshow else None)
        self.video.position_changed.connect(self._position)
        self.video.playing_changed.connect(self._playing)
        self.image.zoom_changed.connect(self._zoom_label)
        self.video.zoom_changed.connect(self._zoom_label)

        self.info = self._info_panel()
        self.info.setVisible(False)
        self.top = self._top_bar()
        self.bottom = self._bottom_bar()
        column = QVBoxLayout()
        column.setContentsMargins(0, 0, 0, 0)
        column.setSpacing(0)
        column.addWidget(self.top)
        column.addWidget(self.stack, 1)
        column.addWidget(self.bottom)
        body = QHBoxLayout(self)
        body.setContentsMargins(0, 0, 0, 0)
        body.setSpacing(0)
        body.addLayout(column, 1)
        body.addWidget(self.info)

        self.toast = QLabel(self)
        self.toast.setObjectName("ViewerToast")
        self.toast.setVisible(False)
        self._toast_timer = QTimer(self)
        self._toast_timer.setSingleShot(True)
        self._toast_timer.timeout.connect(self._end_note)
        self._slide = QTimer(self)
        self._slide.setSingleShot(True)
        self._slide.timeout.connect(self._slide_next)
        self._frame_saved.connect(lambda out, note: self.say(
            (f"Saved “{os.path.basename(out)}” in “{os.path.basename(os.path.dirname(out))}”" +
             (f" — {note}." if note else ".")) if out else "Couldn't save the frame."))
        self._hdr_read.connect(self._hdr_ready)
        self._shortcuts()
        self.resize(self._room(available_geometry(self), TITLE_BAR))   # until the first item says its shape
        self.show_current()

    # ------------------------------------------------------------------ bars
    def _top_bar(self) -> QWidget:
        bar = QFrame(self)
        bar.setObjectName("ViewerTop")
        h = QHBoxLayout(bar)
        h.setContentsMargins(8, 5, 10, 5)
        h.setSpacing(2)
        h.addWidget(_bar_button("", "Close (Esc)", self.close, "close"))
        titles = QVBoxLayout()
        titles.setSpacing(0)
        self.title = QLabel()
        self.title.setObjectName("ViewerTitle")
        self.count = QLabel()
        self.count.setObjectName("ViewerCount")
        for lbl in (self.title, self.count):
            lbl.setSizePolicy(QSizePolicy.Policy.Ignored, QSizePolicy.Policy.Preferred)   # long names give way
            lbl.setMinimumWidth(30)
        titles.addWidget(self.title)
        titles.addWidget(self.count)
        h.addSpacing(4)
        h.addLayout(titles, 1)
        self.fav_btn = _bar_button("", "Favorite (⇧⌘F) — the iPhone app's Favorites", lambda: self.toggle_label("favorite"),
                                   "heart")
        self.ai_btn = _bar_button("", "To AI (⇧⌘A) — the iPhone app's To AI", lambda: self.toggle_label("ai"), "sparkles")
        for b in (self.fav_btn, self.ai_btn):
            b.setCheckable(True)
            b.setVisible(self.hooks.labels_of is not None and self.hooks.set_label is not None)
        self.frame_btn = _bar_button("", "Save Frame — this frame as a standard-range PNG in a “Screenshots” folder "
                                     "beside the video", self.save_frame, "camera")
        self.frames_btn = _bar_button("", "Export All Frames — every frame (or every other, every fourth) into a folder "
                                      "beside the video", self.export_frames, "frames")
        self.info_btn = _bar_button("", "Info (I)", self.toggle_info, "info")
        self.info_btn.setCheckable(True)
        self.more_btn = _bar_button("", "More", None, "more")
        self.more_btn.setPopupMode(QToolButton.ToolButtonPopupMode.InstantPopup)
        self.more_btn.setMenu(self._more_menu())
        for b in (self.fav_btn, self.ai_btn, self.frame_btn, self.info_btn, self.more_btn):
            h.addWidget(b)
        self.frames_btn.setVisible(False)              # Export All Frames is in ⋯ (the bar stays narrow)
        h.addSpacing(6)
        self.res_badge = QLabel()
        self.res_badge.setObjectName("ViewerRes")
        self.hdr_badge = QLabel("HDR")
        self.hdr_badge.setObjectName("ViewerHDR")
        self.hdr_badge.setToolTip("High dynamic range")
        for b in (self.res_badge, self.hdr_badge):
            b.setSizePolicy(QSizePolicy.Policy.Fixed, QSizePolicy.Policy.Fixed)
        h.addWidget(self.res_badge, 0, Qt.AlignmentFlag.AlignVCenter)
        h.addSpacing(3)
        h.addWidget(self.hdr_badge, 0, Qt.AlignmentFlag.AlignVCenter)
        return bar

    def _more_menu(self) -> QMenu:
        menu = QMenu(self)
        self.slide_act = menu.addAction("Slideshow", self.toggle_slideshow)
        self.slide_act.setCheckable(True)
        self.slide_act.setShortcutVisibleInContextMenu(True)
        menu.addAction("Full Screen", self.toggle_full)
        menu.addSeparator()
        self.remove_act = menu.addAction("Remove Objects…", self.remove_objects)
        self.remove_act.setToolTip("Draw round anything in the photo and it's gone")
        self.remove_act.setVisible(self.hooks.remove_objects is not None)
        self.frames_act = menu.addAction("Export All Frames…", self.export_frames)
        self.frames_act.setToolTip("Every frame (or every other, every fourth) into a folder beside the video")
        self.loop_act = menu.addAction("Loop", self._toggle_loop)
        self.loop_act.setCheckable(True)
        self.loop_act.setChecked(True)
        self.loop_act.setToolTip("Play it over and over (as the iPhone does)")
        self.tags_act = menu.addAction("Tags…", self.edit_tags)
        self.reveal_act = menu.addAction("Show in Folder", self.reveal)
        menu.addAction("Open With Default App", self.open_external)
        menu.addSeparator()
        self.trash_act = menu.addAction("Move to Trash", self.trash)
        self.tags_act.setVisible(self.hooks.edit_tags is not None)
        self.reveal_act.setVisible(self.hooks.reveal is not None)
        self.trash_act.setVisible(self.hooks.trash is not None)
        return menu

    def _bottom_bar(self) -> QWidget:
        """Two rows for a video — the scrubber across the whole width (easy to hit with the mouse, and the bar
        stays narrow enough for a portrait video), then the buttons — and just the buttons for a photo."""
        bar = QFrame(self)
        bar.setObjectName("ViewerBottom")
        col = QVBoxLayout(bar)
        col.setContentsMargins(10, 4, 10, 5)
        col.setSpacing(0)
        # the timeline: the time, the scrubber, the length
        self.video_row = QWidget()
        vr = QHBoxLayout(self.video_row)
        vr.setContentsMargins(0, 0, 0, 0)
        vr.setSpacing(8)
        self.time_now = QLabel("0:00")
        self.time_now.setObjectName("ViewerTime")
        self.scrub = _Scrubber()
        self.scrub.sliderMoved.connect(lambda ms: self.video.seek(ms))
        self.scrub.sliderPressed.connect(self._scrub_start)
        self.scrub.sliderReleased.connect(self._scrub_end)
        self.time_all = QLabel("0:00")
        self.time_all.setObjectName("ViewerTime")
        vr.addWidget(self.time_now)
        vr.addWidget(self.scrub, 1)
        vr.addWidget(self.time_all)
        col.addWidget(self.video_row)
        # the buttons: previous / next, play-pause, mute, speed, and zoom (photos and videos alike)
        row = QHBoxLayout()
        row.setContentsMargins(0, 0, 0, 0)
        row.setSpacing(2)
        self.prev_btn = _bar_button("", "Previous (←)", lambda: self.go(-1), "prev")
        self.next_btn = _bar_button("", "Next (→)", lambda: self.go(1), "next")
        row.addWidget(self.prev_btn)
        row.addWidget(self.next_btn)
        row.addStretch(1)
        self.play_btn = _bar_button("", "Play (Space)", lambda: self.video.toggle(), "play")
        self.mute_btn = _bar_button("", "Mute (M)", self._toggle_mute, "speaker")
        self.mute_btn.setCheckable(True)
        self.volume = QSlider(Qt.Orientation.Horizontal)
        self.volume.setObjectName("Volume")
        self.volume.setRange(0, 100)
        self.volume.setValue(round(self.video._volume * 100))
        self.volume.setFixedWidth(96)
        self.volume.setFocusPolicy(Qt.FocusPolicy.NoFocus)
        self.volume.setToolTip("Volume")
        self.volume.valueChanged.connect(self._volume_moved)
        if self.volume.value() == 0:
            self.mute_btn.setIcon(icon("speaker.off"))
        self.speed_btn = _bar_button("1×", "Speed — slow motion like the iPhone's Slo-Mo", None)
        menu = QMenu(self.speed_btn)
        for label, rate in (("1×", 1.0), ("½×", 0.5), ("¼× (Slo-Mo)", 0.25), ("⅛× (Slo-Mo)", 0.125), ("2×", 2.0)):
            menu.addAction(label, lambda r=rate, t=label.split()[0]: (self.video.set_rate(r), self.speed_btn.setText(t)))
        self.speed_btn.setMenu(menu)
        self.speed_btn.setPopupMode(QToolButton.ToolButtonPopupMode.InstantPopup)
        self.play_controls = [self.play_btn, self.mute_btn, self.volume, self.speed_btn]
        for b in self.play_controls:
            row.addWidget(b)
        row.addStretch(1)
        self.zoom_out_btn = _bar_button("", "Zoom Out (−)", lambda: self.zoom(0.8), "minus")
        self.zoom_label = QToolButton()
        self.zoom_label.setObjectName("ZoomLabel")
        self.zoom_label.setText("Fit")
        self.zoom_label.setToolTip("Fit / Actual Size (0)")
        self.zoom_label.setFocusPolicy(Qt.FocusPolicy.NoFocus)
        self.zoom_label.setCursor(Qt.CursorShape.PointingHandCursor)
        self.zoom_label.clicked.connect(self.toggle_actual)
        self.zoom_in_btn = _bar_button("", "Zoom In (+)", lambda: self.zoom(1.25), "plus")
        row.addWidget(self.zoom_out_btn)
        row.addWidget(self.zoom_label)
        row.addWidget(self.zoom_in_btn)
        col.addLayout(row)
        return bar

    def _info_panel(self) -> QWidget:
        panel = QFrame()
        panel.setObjectName("ViewerInfo")
        panel.setFixedWidth(INFO_WIDTH)
        outer = QVBoxLayout(panel)
        outer.setContentsMargins(0, 10, 0, 0)
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.Shape.NoFrame)
        scroll.setStyleSheet("background: transparent;")
        self.info_body = QWidget()
        self.info_lay = QVBoxLayout(self.info_body)
        self.info_lay.setContentsMargins(18, 8, 18, 18)
        self.info_lay.setSpacing(4)
        scroll.setWidget(self.info_body)
        outer.addWidget(scroll)
        return panel

    def _shortcuts(self) -> None:
        for keys, slot in (("Left", lambda: self.go(-1)), ("Right", lambda: self.go(1)), ("Escape", self._escape),
                           ("Down", self.close), ("Up", self.toggle_info), ("I", self.toggle_info),
                           ("F", self.toggle_full), ("S", self.toggle_slideshow), ("Space", self._space),
                           ("J", lambda: self.video.skip(-15)), ("L", lambda: self.video.skip(15)),
                           (",", lambda: self.video.step(-1)), (".", lambda: self.video.step(1)),
                           ("M", lambda: self.mute_btn.click()), ("Ctrl+Backspace", self.trash),
                           ("Ctrl+T", self.edit_tags), ("+", lambda: self.zoom(1.25)),
                           ("=", lambda: self.zoom(1.25)), ("-", lambda: self.zoom(0.8)),
                           ("0", self.fit_current), ("Ctrl+Shift+F", lambda: self.toggle_label("favorite")),
                           ("Ctrl+Shift+A", lambda: self.toggle_label("ai"))):
            sc = QShortcut(QKeySequence(keys), self)
            sc.activated.connect(slot)

    # ------------------------------------------------------------------ showing an item
    @property
    def current(self) -> str:
        return self.paths[self.index] if self.paths else ""

    @property
    def stage(self):
        if is_video(self.current):
            return self.video
        if self.hdr is not None and self.stack.currentWidget() is self.hdr:
            return self.hdr
        return self.image

    def show_current(self) -> None:
        self._slide.stop()
        if not self.paths:
            self.close()
            return
        path = self.current
        self.title.setText(os.path.basename(path))
        self.title.setToolTip(path)
        if not self._toast_timer.isActive():
            self.count.setText(f"{self.index + 1:,} of {len(self.paths):,}")
        self.setWindowTitle(os.path.basename(path))
        self.prev_btn.setEnabled(self.index > 0)
        self.next_btn.setEnabled(self.index < len(self.paths) - 1)
        video = is_video(path)
        self.video_row.setVisible(video)
        for b in self.play_controls:
            b.setVisible(video)
        self.frame_btn.setVisible(video and self.hooks.save_frame is not None)
        self.frames_act.setVisible(video and self.hooks.export_frames is not None)
        self.frame_btn.setEnabled(video)
        self.loop_act.setVisible(video)
        self.remove_act.setVisible(not video and self.hooks.remove_objects is not None)
        self._show_labels()
        self._show_badges(path)
        self._fit_to(path)
        if self.hdr is not None:
            self.hdr.clear()
        if video:
            self.stack.setCurrentWidget(self.video)
            poster = self.poster(path) if self.poster else None
            self.video.show_video(path, poster)
            self.video.loop = self.loop_act.isChecked() and not self.slideshow
            self.speed_btn.setText("1×")                        # each video starts at normal speed
        else:
            self.video.stop()
            self.stack.setCurrentWidget(self.image)
            img = self.loader.get(path)
            if img is None:
                self.image.show_image(None, "")
            else:
                self.image.show_image(img, "" if not img.isNull() else "This photo can't be shown.")
                if self.slideshow:
                    self._slide.start(int(SLIDE_SECONDS * 1000))
            if self._hdr_cache.get(path):
                self._show_hdr(path)
        for d in (1, -1, 2):                                    # read ahead
            j = self.index + d
            if 0 <= j < len(self.paths) and not is_video(self.paths[j]):
                self.loader.request(self.paths[j])
        if self.info.isVisible():
            self.fill_info()
        self._zoom_label()
        self._place_toast()

    def _image_ready(self, path: str, img: QImage) -> None:
        if path == self.current and not is_video(path):
            self.image.show_image(img, "" if not img.isNull() else "This photo can't be shown.")
            if self.slideshow:
                self._slide.start(int(SLIDE_SECONDS * 1000))

    def go(self, step: int) -> None:
        j = self.index + step
        if 0 <= j < len(self.paths):
            self.index = j
            self.show_current()
        elif self.slideshow:
            self.toggle_slideshow()

    def _space(self) -> None:
        if is_video(self.current):
            self.video.toggle()
        else:
            self.go(1)

    def _escape(self) -> None:
        if self.isFullScreen():
            self.toggle_full()
        else:
            self.close()

    # ------------------------------------------------------------------ the window's shape
    def media_size(self, path: str) -> QSize:
        """The item's size as it's shown (turned upright) — read from its header, cheaply."""
        if is_video(path):
            info = media_info.video_info(path)
            return QSize(int(info.get("width") or 0), int(info.get("height") or 0))
        reader = QImageReader(path)
        size = reader.size()
        if size.isValid() and not size.isEmpty():
            try:
                from PySide6.QtGui import QImageIOHandler
                if reader.transformation() & QImageIOHandler.Transformation.TransformationRotate90:
                    size = size.transposed()
            except Exception:  # noqa: BLE001 — an orientation we can't read: as stored
                pass
            return size
        info = media_info.image_info(path)
        return QSize(int(info.get("width") or 0), int(info.get("height") or 0))

    def _chrome_height(self) -> int:
        return (self.top.sizeHint().height() + self.bottom.sizeHint().height()) if self.chrome else 0

    def _title_height(self) -> int:
        """The title bar's height: the window's own once it's up, else the usual one."""
        extra = self.frameGeometry().height() - self.geometry().height()
        return extra if self.isVisible() and extra > 0 else TITLE_BAR

    def _room(self, avail: QRect | None, title: int) -> QSize:
        """The most the window's inside may take: the whole display it's on — its full height, below the menu bar
        and above the Dock, less the title bar — or, once resized by hand, that size (kept on the display)."""
        if avail is None:
            return QSize(self.box) if self.box is not None else QSize(1180, 820)
        whole = QSize(avail.width(), max(200, avail.height() - title))
        return whole if self.box is None else QSize(self.box).boundedTo(whole)

    def _fit_to(self, path: str, first: bool = False) -> None:
        """The window takes the item's shape within `_room` — as tall as the display, unless the item is too
        wide for that (the picture fills it: no bars beside it) — keeping its centre, or, the first time, opening
        over Safe Finder's window."""
        if not self.fit_window or self.isFullScreen() or self.isMaximized():
            return
        ms = self.media_size(path)
        if ms.isEmpty():
            return
        info_w = INFO_WIDTH if self.info.isVisible() else 0
        chrome_h = self._chrome_height()
        avail = available_geometry(self)
        title = self._title_height()
        room = self._room(avail, title)
        room_w, room_h = max(room.width() - info_w, 200), max(room.height() - chrome_h, 150)
        scale = min(room_w / ms.width(), room_h / ms.height())
        w, h = max(1, round(ms.width() * scale)), max(1, round(ms.height() * scale))
        min_w = max(self.minimumWidth(), self.bottom.minimumSizeHint().width() if self.chrome else 0,
                    self.top.minimumSizeHint().width() if self.chrome else 0)
        target = QSize(max(w + info_w, min_w), max(h + chrome_h, self.minimumHeight()))
        if target == self.size() and self.isVisible() and not first:
            return
        center = self.anchor if (first or not self.isVisible()) and self.anchor is not None else \
            self.frameGeometry().center()
        self._fit_target = QSize(target)
        self.resize(target)
        if center is not None:
            # Placed by its outside (title bar and all), which isn't known until the window is up: worked out.
            side = max(0, self.frameGeometry().width() - self.geometry().width()) if self.isVisible() else 0
            geo = QRect(QPoint(0, 0), QSize(target.width() + side, target.height() + title))
            geo.moveCenter(center)
            if avail is not None:
                geo.moveLeft(max(avail.left(), min(geo.left(), avail.right() - geo.width() + 1)))
                geo.moveTop(max(avail.top(), min(geo.top(), avail.bottom() - geo.height() + 1)))
            self.move(geo.topLeft())

    def refit(self) -> None:
        if self.paths:
            self._fit_to(self.current)

    # ------------------------------------------------------------------ zoom
    def zoom(self, factor: float) -> None:
        self.stage.zoom(factor)

    def fit_current(self) -> None:
        self.stage.fit()

    def toggle_actual(self) -> None:
        """Fit ⇄ actual size (one pixel to one point)."""
        stage = self.stage
        if stage.fitted:
            if stage is self.image:
                stage.actual_size(stage.viewport().rect().center())
            else:
                stage.actual_size()
        else:
            stage.fit()

    def _zoom_label(self) -> None:
        if not hasattr(self, "zoom_label"):
            return
        stage = self.stage
        if stage.fitted:
            self.zoom_label.setText("Fit")
        else:
            self.zoom_label.setText(f"{round(stage.scale_now() * 100)}%")
        available = stage is not self.video or self.video.available
        for b in (self.zoom_out_btn, self.zoom_label, self.zoom_in_btn):
            b.setEnabled(available)

    # ------------------------------------------------------------------ video controls
    def _position(self, ms: int, duration: int) -> None:
        if not self.scrub.isSliderDown():
            self.scrub.setRange(0, max(0, duration))
            self.scrub.setValue(ms)
        self.time_now.setText(media_info.clock(ms / 1000))
        self.time_all.setText(media_info.clock(duration / 1000) if duration else "")

    def _playing(self, on: bool) -> None:
        self.play_btn.setIcon(icon("pause" if on else "play"))
        self.play_btn.setToolTip("Pause (Space)" if on else "Play (Space)")

    def _scrub_start(self) -> None:
        self._was_playing = self.video.is_playing()
        self.video.pause()                                   # still while dragging, as the iPhone's
        self.video.seek(self.scrub.value())

    def _scrub_end(self) -> None:
        self.video.seek(self.scrub.value())
        if self._was_playing:
            self.video.play()

    def _toggle_loop(self) -> None:
        self.video.loop = self.loop_act.isChecked()

    def _toggle_mute(self) -> None:
        on = self.mute_btn.isChecked()
        self.video.set_muted(on)
        self.mute_btn.setIcon(icon("speaker.off" if on or self.volume.value() == 0 else "speaker"))

    def _volume_moved(self, value: int) -> None:
        """The volume slider: the player follows, it's remembered for the next video and the next launch, and
        turning it up takes the mute off (as the Mac's own volume does)."""
        self.video.set_volume(value / 100)
        remember_volume(value / 100)
        if value > 0 and self.mute_btn.isChecked():
            self.mute_btn.setChecked(False)
            self.video.set_muted(False)
        self.mute_btn.setIcon(icon("speaker.off" if self.mute_btn.isChecked() or value == 0 else "speaker"))
        self.volume.setToolTip(f"Volume {value}%")

    # ------------------------------------------------------------------ resolution, HDR, labels
    def _show_badges(self, path: str) -> None:
        size = self.media_size(path)
        if is_video(path):
            info = media_info.video_info(path)
            res = media_info.res_label(size.width(), size.height())
            self.res_badge.setToolTip(f"{size.width():,} × {size.height():,}" if not size.isEmpty() else "")
            hdr = bool(info.get("hdr"))
        else:
            mp = size.width() * size.height() / 1e6
            res = (f"{mp:.0f} MP" if mp >= 9.5 else f"{mp:.1f} MP") if mp >= 0.95 else \
                (f"{size.width()}×{size.height()}" if not size.isEmpty() else "")
            self.res_badge.setToolTip(f"{size.width():,} × {size.height():,}" if not size.isEmpty() else "")
            hdr = self._hdr_cache.get(path)
            if hdr is None:
                hdr = False
                sig = self._hdr_read

                def check() -> None:
                    found = media_info.image_hdr(path)
                    try:
                        sig.emit(path, found)
                    except RuntimeError:                 # the viewer was closed meanwhile
                        pass
                threading.Thread(target=check, daemon=True).start()
        self.res_badge.setText(res)
        self.res_badge.setVisible(bool(res))
        self.hdr_badge.setVisible(hdr)

    def _hdr_ready(self, path: str, hdr: bool) -> None:
        self._hdr_cache[path] = hdr
        if path == self.current:
            self.hdr_badge.setVisible(hdr)
            if hdr and not is_video(path):
                self._show_hdr(path)

    def _show_hdr(self, path: str) -> None:
        """An HDR photo, in HDR: macOS reads it (its gain map, or its HLG / PQ curve) while Qt's standard-range
        picture stands in; `_hdr_shown` swaps it in when it's ready."""
        if self.hdr is not None and self.hdr.path != path:
            self.hdr.show_picture(path, self.media_size(path))

    def _hdr_shown(self, ok: bool) -> None:
        if not ok or self.hdr is None or not self.paths or self.hdr.path != self.current:
            return
        if self.stack.currentWidget() is self.image and self.image.fitted:   # not if it's been zoomed meanwhile
            self.stack.setCurrentWidget(self.hdr)
            self._zoom_label()

    def _show_labels(self) -> None:
        if self.hooks.labels_of is None:
            return
        have = self.hooks.labels_of(self.current) if self.paths else []
        fav, ai = "favorite" in have, "ai" in have
        self.fav_btn.setChecked(fav)
        self.fav_btn.setIcon(icon("heart.fill" if fav else "heart", FAVORITE_RED if fav else "#F2F2F7"))
        self.fav_btn.setToolTip("Unfavorite (⇧⌘F)" if fav else "Favorite (⇧⌘F) — the iPhone app's Favorites")
        self.ai_btn.setChecked(ai)
        self.ai_btn.setIcon(icon("sparkles", AI_PURPLE if ai else "#F2F2F7"))
        self.ai_btn.setToolTip("Remove To AI (⇧⌘A)" if ai else "To AI (⇧⌘A) — the iPhone app's To AI")

    def toggle_label(self, label: str) -> None:
        if self.hooks.labels_of is None or self.hooks.set_label is None or not self.paths:
            return
        on = label not in self.hooks.labels_of(self.current)
        self.hooks.set_label(self.current, label, on)
        self._show_labels()
        self.say(("Favorited." if on else "Unfavorited.") if label == "favorite" else
                 ("Added to To AI." if on else "Removed from To AI."))

    # ------------------------------------------------------------------ chrome, info, slideshow
    def toggle_chrome(self) -> None:
        self.chrome = not self.chrome
        self.top.setVisible(self.chrome)
        self.bottom.setVisible(self.chrome)
        QTimer.singleShot(0, self.refit)

    def toggle_info(self) -> None:
        on = not self.info.isVisible()
        self.info.setVisible(on)
        self.info_btn.setChecked(on)
        if on:
            self.fill_info()
        QTimer.singleShot(0, self.refit)

    def toggle_full(self) -> None:
        if self.isFullScreen():
            self._settling = time.monotonic() + 1.0   # coming back from full screen isn't a resize by hand
            self.showNormal()
            QTimer.singleShot(150, self.refit)
        else:
            self.showFullScreen()

    def toggle_slideshow(self) -> None:
        self.slideshow = not self.slideshow
        self.slide_act.setChecked(self.slideshow)
        self.video.loop = self.loop_act.isChecked() and not self.slideshow
        if self.slideshow:
            if self.chrome:
                self.toggle_chrome()
            if not is_video(self.current):
                self._slide.start(int(SLIDE_SECONDS * 1000))
        else:
            self._slide.stop()
            if not self.chrome:
                self.toggle_chrome()

    def _slide_next(self) -> None:
        if self.slideshow:
            if self.index >= len(self.paths) - 1:
                self.toggle_slideshow()
            else:
                self.go(1)

    def say(self, text: str) -> None:
        """A passing note, in the line under the name (in place of "3 of 12") for a few seconds — never over the
        picture (where the Mac would hide it under a video) or the buttons."""
        self.toast.setText(text)
        self.count.setText(text)
        self.count.setStyleSheet("color: #F2F2F7; font-weight: 600;")
        self.count.setToolTip(text)
        self._toast_timer.start(3500)

    def _end_note(self) -> None:
        self.count.setStyleSheet("")
        self.count.setToolTip("")
        if self.paths:
            self.count.setText(f"{self.index + 1:,} of {len(self.paths):,}")

    def _place_toast(self) -> None:
        pass

    def resizeEvent(self, event) -> None:  # noqa: N802
        super().resizeEvent(event)
        if self._fit_target is not None and event.size() == self._fit_target:
            self._fit_target = None                 # our own fit
        elif self.isVisible() and not self.isFullScreen() and not self.isMaximized() \
                and time.monotonic() > self._settling:
            self.box = QSize(event.size())          # resized by hand: fit within this from now on
        self._place_toast()

    def showEvent(self, event) -> None:  # noqa: N802
        super().showEvent(event)
        self._place_toast()
        if not self._shown_once:                    # now the title bar's real height is known: fit again
            self._shown_once = True
            self._settling = time.monotonic() + 0.5
            QTimer.singleShot(80, self.refit)

    def fill_info(self) -> None:
        lay = self.info_lay
        while lay.count():
            it = lay.takeAt(0)
            w = it.widget()
            if w is not None:                        # off the panel now, not when the event loop gets to it
                w.hide()
                w.setParent(None)
                w.deleteLater()
        path = self.current
        try:
            st = os.stat(path)
        except OSError:
            st = None
        video = is_video(path)
        meta = media_info.video_info(path) if video else media_info.image_info(path)

        def row(head: str, value: str, link: str = "") -> None:
            if not value:
                return
            h = QLabel(head.upper())
            h.setObjectName("InfoHead")
            v = QLabel(f'<a href="{link}" style="color:#0A84FF;text-decoration:none">{value}</a>' if link else value)
            v.setObjectName("InfoValue")
            v.setWordWrap(True)
            v.setTextInteractionFlags(Qt.TextInteractionFlag.TextBrowserInteraction)
            if link:
                v.linkActivated.connect(lambda url: QDesktopServices.openUrl(QUrl(url)))
            lay.addWidget(h)
            lay.addWidget(v)
            lay.addSpacing(8)

        row("Name", os.path.basename(path))
        when = meta.get("taken") or meta.get("created")
        if when:
            row("Recorded" if video else "Taken", time.strftime("%A, %B %d, %Y at %H:%M", time.localtime(when)))
        elif st:
            row("Modified", time.strftime("%B %d, %Y at %H:%M", time.localtime(st.st_mtime)))
        dims = f"{meta['width']:,} × {meta['height']:,}" if meta.get("width") else ""
        mp = f" · {meta['width'] * meta['height'] / 1e6:.1f} MP" if meta.get("width") and not video else ""
        row("Size", " · ".join(x for x in (dims + mp, human(st.st_size) if st else "") if x))
        if video and meta.get("duration"):
            row("Length", media_info.clock(meta["duration"]))
        row("Camera", meta.get("camera", ""))
        if meta.get("place"):
            lat, lng = meta["place"]
            row("Place", f"{lat:.5f}, {lng:.5f}", f"https://maps.apple.com/?ll={lat},{lng}&q=Photo")
        row("Caption", meta.get("caption", ""))
        row("Folder", os.path.dirname(path))
        if self.hooks.labels_of is not None:
            have = self.hooks.labels_of(path)
            row("Labels", ", ".join(n for k, n in (("favorite", "Favorite"), ("ai", "To AI")) if k in have))
        tags = self.hooks.tags_of(path) if self.hooks.tags_of else []
        if self.hooks.tags_of is not None:
            h = QLabel("TAGS")
            h.setObjectName("InfoHead")
            lay.addWidget(h)
            box = QWidget()
            flow = QHBoxLayout(box)
            flow.setContentsMargins(0, 2, 0, 2)
            flow.setSpacing(5)
            for t in tags[:12]:
                chip = QLabel(t)
                chip.setObjectName("InfoTag")
                flow.addWidget(chip)
            if not tags:
                none = QLabel("None")
                none.setObjectName("InfoValue")
                flow.addWidget(none)
            flow.addStretch(1)
            lay.addWidget(box)
            if self.hooks.edit_tags is not None:
                b = QPushButton("Edit Tags…")
                b.clicked.connect(self.edit_tags)
                lay.addWidget(b, 0, Qt.AlignmentFlag.AlignLeft)
        lay.addStretch(1)

    # ------------------------------------------------------------------ actions
    def trash(self) -> None:
        if self.hooks.trash is None or not self.paths:
            return
        path = self.current
        if is_video(path):
            self.video.stop()
        if self.hooks.trash([path]):
            self.removed.emit([path])
            del self.paths[self.index]
            if not self.paths:
                self.close()
                return
            self.index = min(self.index, len(self.paths) - 1)
            self.show_current()
            self.say("Moved to the Trash.")

    def edit_tags(self) -> None:
        if self.hooks.edit_tags is not None and self.paths:
            self.hooks.edit_tags(self.current)
            if self.info.isVisible():
                self.fill_info()

    def reveal(self) -> None:
        if self.hooks.reveal is not None and self.paths:
            path = self.current
            self.close()
            self.hooks.reveal(path)

    def open_external(self) -> None:
        if self.paths:
            if is_video(self.current):
                self.video.stop()
            QDesktopServices.openUrl(QUrl.fromLocalFile(self.current))

    def save_frame(self) -> None:
        if self.hooks.save_frame is None or not is_video(self.current):
            return
        path, at = self.current, self.video.position_s()
        self.say("Saving the frame…")

        sig = self._frame_saved
        noted = self.hooks.extra.get("frame_note")         # e.g. "made with ffmpeg …" (frame_export.engine_note)

        def work() -> None:
            out = self.hooks.save_frame(path, at)
            note = ""
            if out and noted is not None:
                try:
                    note = noted() or ""
                except Exception:  # noqa: BLE001 — a note is a nicety
                    note = ""
            try:
                sig.emit(out or "", note)
            except RuntimeError:                         # the viewer was closed meanwhile
                pass
        threading.Thread(target=work, daemon=True).start()

    def reload(self, path: str) -> None:
        """The file was rewritten (Remove Objects, Replace Original): read it afresh."""
        self.loader.cache.pop(path, None)
        self._hdr_cache.pop(path, None)
        if self.paths and path == self.current:
            self.show_current()

    def remove_objects(self) -> None:
        if self.hooks.remove_objects is not None and self.paths and not is_video(self.current):
            self.hooks.remove_objects(self.current)

    def export_frames(self) -> None:
        if self.hooks.export_frames is not None and is_video(self.current):
            if self.video.is_playing():
                self.video.toggle()
            self.hooks.export_frames(self.current)

    def closeEvent(self, event) -> None:  # noqa: N802
        self._slide.stop()
        self.video.release()
        if self.hdr is not None:
            self.hdr.release()
        self.closed.emit()
        super().closeEvent(event)
