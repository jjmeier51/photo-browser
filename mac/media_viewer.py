"""Safe Finder's photo and video viewer — the iPhone app's viewer on the Mac: one item at a time on black,
the listing's order, a top and a bottom bar that a click hides or shows (the iPhone's tap), and an Info panel.

- **Photos** (`_ImageStage`): fitted to the window; pinch, ⌘-scroll or +/− to zoom, a double-click toggles
  fit / actual size at the point clicked, drag to pan. Read with Qt (its HEIC plug-in on the Mac) or, failing
  that, Pillow (pillow-heif), off the main thread, the neighbours read ahead so ←/→ is instant.
- **Videos** (`_VideoStage`): Qt Multimedia (AVFoundation on the Mac) — looping like the iPhone's, a
  millisecond scrubber, ±15 s (J/L), a frame step (, and .), slow motion (½×, ¼×, ⅛×, as the iPhone's
  press-and-hold Slo-Mo), mute, and **Save Frame** (the camera button — a standard-range PNG in a
  "Screenshots" folder beside the video, `frame_export.save_frame`) and **Export All Frames…**. Without
  Qt Multimedia it shows the video's picture and offers Open With… (QuickTime Player).
- **Moving around**: ←/→ (or a two-finger swipe when not zoomed), Esc or ↓ closes, I (or ↑) the Info panel,
  F full screen, S a slideshow (3 s a photo; a video plays out first), ⌘⌫ Move to Trash.
- **Info panel**: name, when it was taken or recorded (`media_info`), size and dimensions, length, camera,
  place (with a link to Maps), caption, folder, tags (and Edit Tags…).

The viewer doesn't touch files itself: Safe Finder hands it what to do for the trash, tags, revealing a file
and exporting frames (`hooks`), so it works the same from a folder, a search or a collection.
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

from PySide6.QtCore import QObject, QPoint, QPointF, QRectF, QSize, Qt, QTimer, QUrl, Signal
from PySide6.QtGui import (QColor, QDesktopServices, QFont, QImage, QImageReader, QKeySequence, QPainter, QPixmap,
                           QShortcut)
from PySide6.QtWidgets import (QFrame, QGraphicsPixmapItem, QGraphicsScene, QGraphicsView, QHBoxLayout, QLabel,
                               QMenu, QPushButton, QScrollArea, QSizePolicy, QSlider, QStackedWidget, QToolButton,
                               QVBoxLayout, QWidget)

import media_info

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
    """A photo, fitted; zoom by pinch, ⌘-scroll, +/− or double-click; pan by dragging. A two-finger swipe
    sideways while fitted asks for the next or previous item (`swiped`); a click `tapped`."""
    swiped = Signal(int)
    tapped = Signal()

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

    def fit(self) -> None:
        self.resetTransform()
        pm = self.item.pixmap()
        if not pm.isNull():
            r = self.viewport().rect()
            scale = min(r.width() / max(pm.width(), 1), r.height() / max(pm.height(), 1))
            scale = min(scale, 1.0 if max(pm.width(), pm.height()) >= 400 else 3.0)
            self.scale(scale, scale)
            self.centerOn(self.item)
        self.fitted = True

    def zoom(self, factor: float, at: QPoint | None = None) -> None:
        if self.item.pixmap().isNull():
            return
        current = self.transform().m11()
        target = max(0.05, min(current * factor, 16.0))
        if at is not None:
            self.setTransformationAnchor(QGraphicsView.ViewportAnchor.AnchorUnderMouse)
        self.scale(target / current, target / current)
        self.fitted = False

    def actual_size(self, at: QPoint) -> None:
        scene_pt = self.mapToScene(at)
        self.resetTransform()
        self.centerOn(scene_pt)
        self.fitted = False

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

    def wheelEvent(self, event) -> None:  # noqa: N802
        mods = event.modifiers()
        if mods & (Qt.KeyboardModifier.ControlModifier | Qt.KeyboardModifier.MetaModifier):
            self.zoom(1.0015 ** event.angleDelta().y(), event.position().toPoint())
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


def _double_click_ms() -> int:
    from PySide6.QtWidgets import QApplication
    return QApplication.doubleClickInterval() if QApplication.instance() else 300


# ----------------------------------------------------------------------------- the video stage

def multimedia():
    """Qt Multimedia's classes, or None when this PySide6 hasn't got them."""
    try:
        from PySide6.QtMultimedia import QAudioOutput, QMediaPlayer
        from PySide6.QtMultimediaWidgets import QVideoWidget
        return QMediaPlayer, QAudioOutput, QVideoWidget
    except ImportError:
        return None


class _VideoStage(QWidget):
    """A video: Qt Multimedia's player, or — without it — the video's picture and QuickTime Player."""
    tapped = Signal()
    ended = Signal()
    position_changed = Signal(int, int)        # ms, duration ms
    playing_changed = Signal(bool)

    def __init__(self, parent=None) -> None:
        super().__init__(parent)
        self.setAutoFillBackground(True)
        pal = self.palette()
        pal.setColor(self.backgroundRole(), QColor("black"))
        self.setPalette(pal)
        lay = QVBoxLayout(self)
        lay.setContentsMargins(0, 0, 0, 0)
        mm = multimedia()
        self.path = ""
        self.loop = True
        self.fps = 30.0
        self.player = self.audio = self.video = None
        self.poster = QLabel()
        self.poster.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.poster.setStyleSheet("color: #C8C8CD; background: black;")
        if mm is not None:
            QMediaPlayer, QAudioOutput, QVideoWidget = mm
            self.video = QVideoWidget(self)
            self.video.setStyleSheet("background: black;")
            self.player = QMediaPlayer(self)
            self.audio = QAudioOutput(self)
            self.player.setAudioOutput(self.audio)
            self.player.setVideoOutput(self.video)
            self.player.positionChanged.connect(lambda ms: self.position_changed.emit(ms, self.player.duration()))
            self.player.durationChanged.connect(lambda d: self.position_changed.emit(self.player.position(), d))
            self.player.playbackStateChanged.connect(
                lambda st: self.playing_changed.emit(st == QMediaPlayer.PlaybackState.PlayingState))
            self.player.mediaStatusChanged.connect(self._status)
            lay.addWidget(self.video)
        else:
            lay.addWidget(self.poster)

    @property
    def available(self) -> bool:
        return self.player is not None

    def show_video(self, path: str, poster: QImage | None = None, autoplay: bool = True) -> None:
        self.path = path
        info = media_info.video_info(path)
        self.fps = 30.0
        if self.player is None:
            if poster is not None and not poster.isNull():
                self.poster.setPixmap(QPixmap.fromImage(poster).scaled(
                    self.size() * 0.9, Qt.AspectRatioMode.KeepAspectRatio, Qt.TransformationMode.SmoothTransformation))
            else:
                self.poster.setText("This Mac's Qt can't play videos here — use Open With… to play it in QuickTime Player.")
            self.position_changed.emit(0, int((info.get("duration") or 0) * 1000))
            return
        self.player.setSource(QUrl.fromLocalFile(path))
        self.player.setPlaybackRate(1.0)
        if autoplay:
            self.player.play()

    def stop(self) -> None:
        if self.player is not None:
            self.player.stop()
            self.player.setSource(QUrl())

    def toggle(self) -> None:
        if self.player is None:
            return
        from PySide6.QtMultimedia import QMediaPlayer
        if self.player.playbackState() == QMediaPlayer.PlaybackState.PlayingState:
            self.player.pause()
        else:
            self.player.play()

    def is_playing(self) -> bool:
        if self.player is None:
            return False
        from PySide6.QtMultimedia import QMediaPlayer
        return self.player.playbackState() == QMediaPlayer.PlaybackState.PlayingState

    def seek(self, ms: int) -> None:
        if self.player is not None:
            self.player.setPosition(max(0, min(int(ms), self.player.duration() or int(ms))))

    def skip(self, seconds: float) -> None:
        if self.player is not None:
            self.seek(self.player.position() + int(seconds * 1000))

    def step(self, frames: int) -> None:
        """One frame back or on (paused first — the iPhone's frame step)."""
        if self.player is None:
            return
        self.player.pause()
        self.seek(self.player.position() + int(round(frames * 1000 / max(self.fps, 1))))

    def set_rate(self, rate: float) -> None:
        if self.player is not None:
            self.player.setPlaybackRate(rate)

    def set_muted(self, muted: bool) -> None:
        if self.audio is not None:
            self.audio.setMuted(muted)

    def position_s(self) -> float:
        return (self.player.position() / 1000) if self.player is not None else 0.0

    def _status(self, status) -> None:
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
        self.tapped.emit()
        super().mouseReleaseEvent(event)


# ----------------------------------------------------------------------------- the window

def _bar_button(text: str, tip: str, slot) -> QToolButton:
    b = QToolButton()
    b.setText(text)
    b.setToolTip(tip)
    b.setObjectName("ViewerButton")
    b.setCursor(Qt.CursorShape.PointingHandCursor)
    if slot is not None:
        b.clicked.connect(slot)
    return b


VIEWER_STYLE = f"""
#ViewerTop, #ViewerBottom {{ background: {CHROME_BG}; }}
#ViewerTop QLabel, #ViewerBottom QLabel {{ color: #F2F2F7; }}
#ViewerTitle {{ font-size: 14px; font-weight: 600; }}
#ViewerCount {{ color: #A1A1A6; font-size: 12px; }}
QToolButton#ViewerButton {{ color: #F2F2F7; background: transparent; border: none; border-radius: 7px;
                            padding: 5px 9px; font-size: 13px; }}
QToolButton#ViewerButton:hover {{ background: rgba(255,255,255,0.12); }}
QToolButton#ViewerButton:checked {{ background: rgba(10,132,255,0.85); }}
QToolButton#ViewerButton:disabled {{ color: #636366; }}
#ViewerInfo {{ background: #1C1C1E; border-left: 1px solid #2C2C2E; }}
#ViewerInfo QLabel {{ color: #EBEBF0; }}
#InfoHead {{ color: #8E8E93; font-size: 11px; font-weight: 600; letter-spacing: 0.5px; }}
#InfoValue {{ font-size: 13px; }}
#InfoTag {{ background: #2C2C2E; border-radius: 9px; padding: 2px 9px; font-size: 12px; }}
#ViewerInfo QPushButton {{ color: #F2F2F7; background: #2C2C2E; border: 1px solid #3A3A3C; border-radius: 7px;
                          padding: 5px 12px; font-size: 13px; }}
#ViewerInfo QPushButton:hover {{ background: #3A3A3C; }}
QSlider#Scrubber::groove:horizontal {{ height: 4px; background: rgba(255,255,255,0.25); border-radius: 2px; }}
QSlider#Scrubber::sub-page:horizontal {{ background: #F2F2F7; border-radius: 2px; }}
QSlider#Scrubber::handle:horizontal {{ background: #FFFFFF; width: 12px; height: 12px; margin: -4px 0; border-radius: 6px; }}
#ViewerToast {{ background: rgba(44,44,46,0.92); color: #F2F2F7; border-radius: 10px; padding: 8px 14px; }}
"""


class MediaViewer(QWidget):
    """One window: the items of a listing, one at a time (module notes)."""
    closed = Signal()
    removed = Signal(list)                 # paths moved to the Trash from here
    _frame_saved = Signal(str)             # a saved frame's file ("" when it failed), from a worker thread

    def __init__(self, paths: list[str], start: int = 0, hooks: Hooks | None = None, poster=None, parent=None) -> None:
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
        self.setWindowTitle("Viewer")
        self.setStyleSheet(VIEWER_STYLE)
        self.setMinimumSize(640, 420)
        pal = self.palette()
        pal.setColor(self.backgroundRole(), QColor("black"))
        self.setPalette(pal)
        self.setAutoFillBackground(True)

        self.stack = QStackedWidget(self)
        self.image = _ImageStage()
        self.video = _VideoStage()
        self.stack.addWidget(self.image)
        self.stack.addWidget(self.video)
        self.image.swiped.connect(self.go)
        self.image.tapped.connect(self.toggle_chrome)
        self.video.tapped.connect(self.toggle_chrome)
        self.video.ended.connect(lambda: self.go(1) if self.slideshow else None)
        self.video.position_changed.connect(self._position)
        self.video.playing_changed.connect(lambda on: self.play_btn.setText("⏸" if on else "▶"))

        self.info = self._info_panel()
        self.info.setVisible(False)
        body = QHBoxLayout(self)
        body.setContentsMargins(0, 0, 0, 0)
        body.setSpacing(0)
        body.addWidget(self.stack, 1)
        body.addWidget(self.info)

        self.top = self._top_bar()
        self.bottom = self._bottom_bar()
        self.toast = QLabel(self)
        self.toast.setObjectName("ViewerToast")
        self.toast.setVisible(False)
        self._toast_timer = QTimer(self)
        self._toast_timer.setSingleShot(True)
        self._toast_timer.timeout.connect(lambda: self.toast.setVisible(False))
        self._slide = QTimer(self)
        self._slide.setSingleShot(True)
        self._slide.timeout.connect(self._slide_next)
        self._frame_saved.connect(lambda out: self.say(
            f"Saved “{os.path.basename(out)}” in “{os.path.basename(os.path.dirname(out))}”." if out
            else "Couldn't save the frame."))
        self._shortcuts()
        self.resize(1180, 820)
        self.show_current()

    # ------------------------------------------------------------------ bars
    def _top_bar(self) -> QWidget:
        bar = QFrame(self)
        bar.setObjectName("ViewerTop")
        h = QHBoxLayout(bar)
        h.setContentsMargins(10, 6, 10, 6)
        h.addWidget(_bar_button("✕", "Close (Esc)", self.close))
        titles = QVBoxLayout()
        titles.setSpacing(0)
        self.title = QLabel()
        self.title.setObjectName("ViewerTitle")
        self.count = QLabel()
        self.count.setObjectName("ViewerCount")
        titles.addWidget(self.title)
        titles.addWidget(self.count)
        h.addSpacing(6)
        h.addLayout(titles, 1)
        self.slide_btn = _bar_button("Slideshow", "Slideshow (S)", self.toggle_slideshow)
        self.slide_btn.setCheckable(True)
        self.info_btn = _bar_button("Info", "Info (I)", self.toggle_info)
        self.info_btn.setCheckable(True)
        h.addWidget(self.slide_btn)
        h.addWidget(self.info_btn)
        h.addWidget(_bar_button("⤢", "Full Screen (F)", self.toggle_full))
        return bar

    def _bottom_bar(self) -> QWidget:
        bar = QFrame(self)
        bar.setObjectName("ViewerBottom")
        v = QVBoxLayout(bar)
        v.setContentsMargins(12, 6, 12, 8)
        v.setSpacing(4)
        # the video row: play, time, scrubber, length, speed, mute, frames
        self.video_row = QWidget()
        vr = QHBoxLayout(self.video_row)
        vr.setContentsMargins(0, 0, 0, 0)
        self.play_btn = _bar_button("⏸", "Play / Pause (Space)", lambda: self.video.toggle())
        vr.addWidget(_bar_button("↺15", "Back 15 s (J)", lambda: self.video.skip(-15)))
        vr.addWidget(self.play_btn)
        vr.addWidget(_bar_button("15↻", "On 15 s (L)", lambda: self.video.skip(15)))
        self.time_now = QLabel("0:00")
        self.scrub = QSlider(Qt.Orientation.Horizontal)
        self.scrub.setObjectName("Scrubber")
        self.scrub.setRange(0, 0)
        self.scrub.sliderMoved.connect(lambda ms: self.video.seek(ms))
        self.time_all = QLabel("0:00")
        vr.addWidget(self.time_now)
        vr.addWidget(self.scrub, 1)
        vr.addWidget(self.time_all)
        self.speed_btn = _bar_button("1×", "Speed — slow motion like the iPhone's Slo-Mo", None)
        menu = QMenu(self.speed_btn)
        for label, rate in (("1×", 1.0), ("½×", 0.5), ("¼× (Slo-Mo)", 0.25), ("⅛× (Slo-Mo)", 0.125), ("2×", 2.0)):
            menu.addAction(label, lambda r=rate, t=label.split()[0]: (self.video.set_rate(r), self.speed_btn.setText(t)))
        self.speed_btn.setMenu(menu)
        self.speed_btn.setPopupMode(QToolButton.ToolButtonPopupMode.InstantPopup)
        vr.addWidget(self.speed_btn)
        self.loop_btn = _bar_button("Loop", "Play it over and over (as the iPhone does)", self._toggle_loop)
        self.loop_btn.setCheckable(True)
        self.loop_btn.setChecked(True)
        vr.addWidget(self.loop_btn)
        self.mute_btn = _bar_button("🔈", "Mute (M)", self._toggle_mute)
        self.mute_btn.setCheckable(True)
        vr.addWidget(self.mute_btn)
        v.addWidget(self.video_row)
        # the item row: previous / next, and what can be done with it
        row = QHBoxLayout()
        row.setSpacing(2)
        self.prev_btn = _bar_button("‹", "Previous (←)", lambda: self.go(-1))
        self.next_btn = _bar_button("›", "Next (→)", lambda: self.go(1))
        for b in (self.prev_btn, self.next_btn):
            b.setFont(QFont(b.font().family(), 20))
        row.addWidget(self.prev_btn)
        row.addWidget(self.next_btn)
        row.addStretch(1)
        self.frame_btn = _bar_button("Save Frame", "Save this frame as a standard-range PNG in a “Screenshots” "
                                                     "folder beside the video", self.save_frame)
        self.frames_btn = _bar_button("All Frames…", "Export All Frames — every frame (or every other, every "
                                                     "fourth) into a folder beside the video", self.export_frames)
        self.tags_btn = _bar_button("Tags…", "Edit this file's tags (⌘T)", self.edit_tags)
        self.reveal_btn = _bar_button("Show in Folder", "Close the viewer and select it in Safe Finder", self.reveal)
        self.open_btn = _bar_button("Open With…", "Open it in the Mac's app for it (Preview, QuickTime Player)",
                                    self.open_external)
        self.trash_btn = _bar_button("Trash", "Move to Trash (⌘⌫)", self.trash)
        for b in (self.frame_btn, self.frames_btn, self.tags_btn, self.reveal_btn, self.open_btn, self.trash_btn):
            b.setMinimumWidth(b.sizeHint().width())   # never squeezed into "Sa…rame": the window grows instead
            row.addWidget(b)
        self.frame_btn.setVisible(self.hooks.save_frame is not None)
        self.frames_btn.setVisible(self.hooks.export_frames is not None)
        self.tags_btn.setVisible(self.hooks.edit_tags is not None)
        self.reveal_btn.setVisible(self.hooks.reveal is not None)
        self.trash_btn.setVisible(self.hooks.trash is not None)
        v.addLayout(row)
        return bar

    def _info_panel(self) -> QWidget:
        panel = QFrame()
        panel.setObjectName("ViewerInfo")
        panel.setFixedWidth(300)
        outer = QVBoxLayout(panel)
        outer.setContentsMargins(0, 54, 0, 0)
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
                           ("Ctrl+T", self.edit_tags), ("+", lambda: self.image.zoom(1.25)),
                           ("=", lambda: self.image.zoom(1.25)), ("-", lambda: self.image.zoom(0.8)),
                           ("0", self.image.fit)):
            sc = QShortcut(QKeySequence(keys), self)
            sc.activated.connect(slot)

    # ------------------------------------------------------------------ showing an item
    @property
    def current(self) -> str:
        return self.paths[self.index] if self.paths else ""

    def show_current(self) -> None:
        self._slide.stop()
        if not self.paths:
            self.close()
            return
        path = self.current
        self.title.setText(os.path.basename(path))
        self.count.setText(f"{self.index + 1:,} of {len(self.paths):,}")
        self.setWindowTitle(os.path.basename(path))
        self.prev_btn.setEnabled(self.index > 0)
        self.next_btn.setEnabled(self.index < len(self.paths) - 1)
        video = is_video(path)
        self.video_row.setVisible(video)
        self.frame_btn.setEnabled(video)
        self.frames_btn.setEnabled(video)
        self.frame_btn.setVisible(video and self.hooks.save_frame is not None)
        self.frames_btn.setVisible(video and self.hooks.export_frames is not None)
        if video:
            self.stack.setCurrentWidget(self.video)
            poster = self.poster(path) if self.poster else None
            self.video.show_video(path, poster)
            self.video.loop = self.loop_btn.isChecked() and not self.slideshow
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
        for d in (1, -1, 2):                                    # read ahead
            j = self.index + d
            if 0 <= j < len(self.paths) and not is_video(self.paths[j]):
                self.loader.request(self.paths[j])
        if self.info.isVisible():
            self.fill_info()
        self._place_overlays()

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
            self.showNormal()
        else:
            self.close()

    def _position(self, ms: int, duration: int) -> None:
        if not self.scrub.isSliderDown():
            self.scrub.setRange(0, max(0, duration))
            self.scrub.setValue(ms)
        self.time_now.setText(media_info.clock(ms / 1000))
        self.time_all.setText(media_info.clock(duration / 1000) if duration else "")

    def _toggle_loop(self) -> None:
        self.video.loop = self.loop_btn.isChecked()

    def _toggle_mute(self) -> None:
        on = self.mute_btn.isChecked()
        self.video.set_muted(on)
        self.mute_btn.setText("🔇" if on else "🔈")

    # ------------------------------------------------------------------ chrome, info, slideshow
    def toggle_chrome(self) -> None:
        self.chrome = not self.chrome
        self._place_overlays()

    def toggle_info(self) -> None:
        on = not self.info.isVisible()
        self.info.setVisible(on)
        self.info_btn.setChecked(on)
        if on:
            self.fill_info()
        QTimer.singleShot(0, self._place_overlays)

    def toggle_full(self) -> None:
        self.showNormal() if self.isFullScreen() else self.showFullScreen()

    def toggle_slideshow(self) -> None:
        self.slideshow = not self.slideshow
        self.slide_btn.setChecked(self.slideshow)
        self.video.loop = self.loop_btn.isChecked() and not self.slideshow
        if self.slideshow:
            self.chrome = False
            self._place_overlays()
            if not is_video(self.current):
                self._slide.start(int(SLIDE_SECONDS * 1000))
        else:
            self._slide.stop()

    def _slide_next(self) -> None:
        if self.slideshow:
            if self.index >= len(self.paths) - 1:
                self.toggle_slideshow()
            else:
                self.go(1)

    def say(self, text: str) -> None:
        self.toast.setText(text)
        self.toast.adjustSize()
        self.toast.setVisible(True)
        self._place_overlays()
        self._toast_timer.start(3500)

    def resizeEvent(self, event) -> None:  # noqa: N802
        super().resizeEvent(event)
        self._place_overlays()

    def _place_overlays(self) -> None:
        w = self.stack.width()
        self.top.setVisible(self.chrome)
        self.bottom.setVisible(self.chrome)
        self.top.setGeometry(0, 0, w, self.top.sizeHint().height())
        bh = self.bottom.sizeHint().height()
        self.bottom.setGeometry(0, self.height() - bh, w, bh)
        self.top.raise_()
        self.bottom.raise_()
        if self.toast.isVisible():
            self.toast.move((w - self.toast.width()) // 2, self.height() - bh - self.toast.height() - 16)
            self.toast.raise_()

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

        def work() -> None:
            out = self.hooks.save_frame(path, at)
            self._frame_saved.emit(out or "")
        threading.Thread(target=work, daemon=True).start()

    def export_frames(self) -> None:
        if self.hooks.export_frames is not None and is_video(self.current):
            if self.video.is_playing():
                self.video.toggle()
            self.hooks.export_frames(self.current)

    def showEvent(self, event) -> None:  # noqa: N802
        super().showEvent(event)
        self._place_overlays()

    def closeEvent(self, event) -> None:  # noqa: N802
        self._slide.stop()
        self.video.stop()
        self.closed.emit()
        super().closeEvent(event)
