"""Safe Finder's Remove Watermark window: take one's own see-through watermark off many photos at once
(watermark.py does the work).

Right-click photos (or folders) ▸ "Remove Watermark…". The window shows one photo at a time. If the
watermark is one it has learned before — the same words, or new words round familiar ones ("Meier
dfs8437he9" after "John Meier artwork") — it finds every copy by itself and shows the photo with them
taken out. If not, drag a box round one whole copy: it learns the watermark from that copy and the others
like it on the photo, and remembers it for the next photos (and next time). A box drawn on a photo that
already has a result teaches it again from that copy, for when the result isn't right. "Original" shows the
photo as it is, with what will go in red; ‹ › (or the arrow keys) step through the photos, which are
looked through ahead of time in the background so stepping is quick. Save as New writes each result beside
its photo ("name (no watermark).ext"), Replace rewrites the photo; photos where no watermark was found are
left alone. Safe Finder tags the results "retouched".

Threads: one worker does all the pixel work — the photo on screen first (a box drawn on it before
anything), then the others in order — and talks to the window only through signals. The library of learned
watermarks is touched only by the worker.
"""
from __future__ import annotations

import os
import threading
from typing import Callable

import numpy as np
from PySide6.QtCore import QObject, QPointF, QRectF, QSettings, Qt, Signal
from PySide6.QtGui import QColor, QImage, QKeySequence, QPainter, QPen, QShortcut
from PySide6.QtWidgets import (QButtonGroup, QDialog, QHBoxLayout, QLabel, QMessageBox, QProgressBar, QPushButton,
                               QToolButton, QVBoxLayout, QWidget)

import batch_crop as bc
import watermark as wmk
from batch_crop import Image
from erase_window import mask_image, to_qimage

PREVIEW_PX = 1600
SAVE_KEY = "watermark/save"     # "new" / "replace", the last answer
MIN_BOX = 0.01                  # a click is not a box


def _preview(rgb: np.ndarray) -> "Image.Image":
    im = Image.fromarray(np.clip(np.rint(rgb[..., :3]), 0, 255).astype(np.uint8), "RGB")
    im.thumbnail((PREVIEW_PX, PREVIEW_PX), Image.Resampling.LANCZOS)
    return im


def _mask_preview(mask: np.ndarray, size: tuple[int, int]) -> QImage:
    small = Image.fromarray(mask.astype(np.uint8) * 255).resize(size, Image.Resampling.BILINEAR)
    return mask_image(np.asarray(small) > 60)


class _Signals(QObject):
    loaded = Signal(int, int, QImage)                 # token, index, the photo as it is
    shown = Signal(int, int, QImage, QImage, str)     # token, index, result, what goes (red), what was found
    state = Signal(int, str)                          # index, its state ("found" / "none" / "failed")
    working = Signal(str)                             # what the worker is doing
    library = Signal(int)                             # how many watermarks it knows
    saved = Signal(int, str, str)                     # index, "done" / "none" / "failed", the result or why
    finished = Signal()


class BoxCanvas(QWidget):
    """The photo (or the result), with a box dragged on it to teach the watermark."""
    boxed = Signal(tuple)                             # (x0, y0, x1, y1), fractions of the photo
    MARGIN = 16

    def __init__(self, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.image: QImage | None = None
        self.overlay: QImage | None = None
        self.message = "Loading…"
        self.hint = ""
        self._start: QPointF | None = None
        self._end: QPointF | None = None
        self.setMinimumSize(460, 360)
        self.setCursor(Qt.CursorShape.CrossCursor)

    def frame(self) -> QRectF:
        area = QRectF(self.rect()).adjusted(self.MARGIN, self.MARGIN, -self.MARGIN, -self.MARGIN)
        if self.image is None or self.image.width() <= 0 or self.image.height() <= 0:
            return area
        s = min(area.width() / self.image.width(), area.height() / self.image.height())
        w, h = self.image.width() * s, self.image.height() * s
        return QRectF(area.x() + (area.width() - w) / 2, area.y() + (area.height() - h) / 2, w, h)

    def paintEvent(self, _event) -> None:  # noqa: N802
        p = QPainter(self)
        p.setRenderHint(QPainter.RenderHint.Antialiasing)
        p.fillRect(self.rect(), QColor("#161618"))
        if self.image is None:
            p.setPen(QColor("#9a9aa0"))
            p.drawText(self.rect(), Qt.AlignmentFlag.AlignCenter | Qt.TextFlag.TextWordWrap, self.message)
            return
        f = self.frame()
        p.setRenderHint(QPainter.RenderHint.SmoothPixmapTransform)
        p.drawImage(f, self.image)
        if self.overlay is not None:
            p.drawImage(f, self.overlay)
        if self._start is not None and self._end is not None:
            r = QRectF(self._start, self._end).normalized()
            p.setPen(QPen(QColor(0, 0, 0, 150), 3))
            p.drawRect(r)
            p.setPen(QPen(QColor("#0A84FF"), 1.5))
            p.drawRect(r)
        elif self.hint:
            p.setPen(QColor(255, 255, 255, 225))
            p.drawText(f.adjusted(8, 0, -8, -12), Qt.AlignmentFlag.AlignHCenter | Qt.AlignmentFlag.AlignBottom
                       | Qt.TextFlag.TextWordWrap, self.hint)

    def _norm(self, pos: QPointF) -> tuple[float, float]:
        f = self.frame()
        return (min(1.0, max(0.0, (pos.x() - f.x()) / max(f.width(), 1))),
                min(1.0, max(0.0, (pos.y() - f.y()) / max(f.height(), 1))))

    def mousePressEvent(self, event) -> None:  # noqa: N802
        if self.image is None or not self.isEnabled() or event.button() != Qt.MouseButton.LeftButton:
            return
        self._start = self._end = event.position()
        self.update()

    def mouseMoveEvent(self, event) -> None:  # noqa: N802
        if self._start is not None:
            self._end = event.position()
            self.update()

    def mouseReleaseEvent(self, _event) -> None:  # noqa: N802
        if self._start is None or self._end is None:
            return
        (x0, y0), (x1, y1) = self._norm(self._start), self._norm(self._end)
        self._start = self._end = None
        self.update()
        if abs(x1 - x0) >= MIN_BOX and abs(y1 - y0) >= MIN_BOX:
            self.boxed.emit((min(x0, x1), min(y0, y1), max(x0, x1), max(y0, y1)))


class WatermarkDialog(QDialog):
    """`on_done(written, as_new, untouched, failed)` runs on the UI thread at the end: (photo, result) for each
    one saved, whether the results are new photos, how many had no watermark found, how many failed."""

    def __init__(self, parent: QWidget | None, photos: list[str], settings: QSettings,
                 on_done: Callable[[list[tuple[str, str]], bool, int, int], None]) -> None:
        super().__init__(parent)
        self.photos, self.settings, self.on_done = photos, settings, on_done
        self.current = 0
        self.token = 0
        self.original: QImage | None = None
        self.result: QImage | None = None
        self.mark: QImage | None = None
        self.states: dict[int, str] = {}
        self.saving = False
        self.as_new = True
        self._written: list[tuple[str, str]] = []
        self._none = 0
        self._failed: list[tuple[str, str]] = []
        self._known = 0

        # Shared with the worker, under self._lock.
        self._lock = threading.Condition()
        self._results: dict[int, tuple[wmk.Result, float]] = {}
        self._tried: set[int] = set()            # looked through with the library, nothing found
        self._show: tuple[int, int] | None = None   # (token, index) the window wants on screen
        self._box: tuple[int, int, tuple] | None = None
        self._again: int | None = None
        self._save: tuple[bool, int] | None = None  # as_new, the next index to save
        self._forget = False
        self._closing = False
        self._preempt = threading.Event()
        self._stop_saving = threading.Event()

        self._sig = _Signals()
        self._sig.loaded.connect(self._loaded)
        self._sig.shown.connect(self._shown)
        self._sig.state.connect(self._state)
        self._sig.working.connect(self._working)
        self._sig.library.connect(self._library)
        self._sig.saved.connect(self._saved)
        self._sig.finished.connect(self._finished)

        n = len(photos)
        self.setWindowTitle("Remove Watermark" if n == 1 else f"Remove Watermark from {n} Photos")
        self.resize(1000, 860)

        tools = QHBoxLayout()
        self.views = QButtonGroup(self)
        self.result_btn = self._seg("Result", "The photo as it will be", self.views)
        self.orig_btn = self._seg("Original", "The photo as it is, with what will go in red", self.views)
        self.result_btn.setChecked(True)
        for b in (self.result_btn, self.orig_btn):
            b.clicked.connect(self._paint)
        tools.addWidget(self.result_btn)
        tools.addWidget(self.orig_btn)
        tools.addSpacing(12)
        self.again_btn = self._tool("Look Again", self.look_again, "Forget this photo's result and look for the "
                                    "watermark again with what's been learned")
        tools.addWidget(self.again_btn)
        tools.addStretch(1)
        self.known = QLabel()
        self.known.setStyleSheet("color: #9a9aa0")
        tools.addWidget(self.known)
        self.forget_btn = self._tool("Forget", self.forget, "Forget every watermark learned so far")
        tools.addWidget(self.forget_btn)

        self.canvas = BoxCanvas()
        self.canvas.boxed.connect(self.teach)

        self.status = QLabel()
        self.status.setWordWrap(True)

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
        lay.addWidget(self.status)
        lay.addWidget(nav_row)
        nav_row.setVisible(n > 1)
        lay.addWidget(self.bar)
        lay.addLayout(buttons)

        QShortcut(QKeySequence(Qt.Key.Key_Left), self, activated=lambda: self.step(-1))
        QShortcut(QKeySequence(Qt.Key.Key_Right), self, activated=lambda: self.step(1))
        self._worker = threading.Thread(target=self._work, daemon=True)
        self._worker.start()
        self._go(0)

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

    # -- the photo on screen
    def step(self, delta: int) -> None:
        i = self.current + delta
        if not self.saving and 0 <= i < len(self.photos) and i != self.current:
            self._go(i)

    def _go(self, i: int) -> None:
        self.current = i
        self.token += 1
        self.original = self.result = self.mark = None
        self.canvas.image = self.canvas.overlay = None
        self.canvas.message = "Loading…"
        self.canvas.hint = ""
        self.canvas.update()
        self.status.setText("")
        self._refresh()
        with self._lock:
            self._show = (self.token, i)
            self._preempt.set()                  # whatever the worker is on in the background can wait
            self._lock.notify_all()

    def teach(self, box: tuple) -> None:
        """A box dragged round one copy: learn the watermark from it, on this photo."""
        if self.saving or self.original is None:
            return
        self.status.setText("Learning the watermark from the copy you boxed…")
        with self._lock:
            self._box = (self.token, self.current, box)
            self._preempt.set()
            self._lock.notify_all()

    def look_again(self) -> None:
        if self.saving:
            return
        with self._lock:
            self._again = self.current
            self._preempt.set()
            self._lock.notify_all()

    def forget(self) -> None:
        if self.saving or not self._known:
            return
        if QMessageBox.question(self, "Forget Learned Watermarks",
                                f"Forget the {self._known} watermark{'s' if self._known != 1 else ''} learned so "
                                "far? Photos will need a box again until it learns them anew.") \
                != QMessageBox.StandardButton.Yes:
            return
        with self._lock:
            self._forget = True
            self._lock.notify_all()

    def _loaded(self, token: int, _i: int, original: QImage) -> None:
        if token != self.token:
            return
        self.original = original
        self._paint()
        self._refresh()

    def _shown(self, token: int, i: int, result: QImage, mark: QImage, text: str) -> None:
        if token != self.token or i != self.current:
            return
        self.result = None if result.isNull() else result
        self.mark = None if mark.isNull() else mark
        self.status.setText(text)
        self._paint()
        self._refresh()

    def _paint(self) -> None:
        if self.original is None:
            return
        if self.orig_btn.isChecked():
            self.canvas.image, self.canvas.overlay = self.original, self.mark
        else:
            self.canvas.image, self.canvas.overlay = (self.result or self.original), None
        self.canvas.hint = ("Not right? Drag a box round one whole copy of the watermark to teach it again"
                            if self.result is not None else "Drag a box round one whole copy of the watermark")
        self.canvas.update()

    def _state(self, i: int, state: str) -> None:
        self.states[i] = state
        self._refresh()

    def _working(self, text: str) -> None:
        if not self.saving:
            self.note.setText(text)

    def _library(self, n: int) -> None:
        self._known = n
        self.known.setText(f"Knows {n} watermark{'s' if n != 1 else ''}" if n else "Knows no watermark yet")
        self._refresh()

    def _refresh(self) -> None:
        n = len(self.photos)
        found = sum(1 for s in self.states.values() if s == "found")
        none = sum(1 for s in self.states.values() if s == "none")
        name = os.path.basename(self.photos[self.current])
        here = {"found": "watermark found", "none": "no watermark found", "failed": "couldn't be read"}.get(
            self.states.get(self.current, ""), "looking…")
        self.where.setText(f"{self.current + 1} of {n}  ·  {name}  ·  {here}")
        for b in (self.replace_btn, self.new_btn):
            b.setEnabled(not self.saving and (found > 0 or len(self.states) < n))
        self.again_btn.setEnabled(not self.saving and self.current in self.states)
        self.forget_btn.setEnabled(not self.saving and self._known > 0)
        self.prev_btn.setEnabled(not self.saving and self.current > 0)
        self.next_btn.setEnabled(not self.saving and self.current < n - 1)
        for b in (self.result_btn, self.orig_btn):
            b.setEnabled(not self.saving)
        self.canvas.setEnabled(not self.saving)
        if not self.saving and n > 1:
            left = n - len(self.states)
            self.note.setText(f"Found on {found} · none on {none}" + (f" · {left} still to look through" if left else "")
                              + ". Save as New keeps the originals; the metadata, dates and tags are kept either way.")

    # -- the worker
    def _work(self) -> None:
        """Everything with pixels, one thing at a time, most wanted first."""
        try:
            library = wmk.Library()
        except Exception:  # noqa: BLE001 — an unreadable library is an empty one
            library = wmk.Library(wmk.LIBRARY / ".unreadable")
        self._sig.library.emit(len(library.items))
        held: tuple[int, np.ndarray, float] | None = None       # the photo last read, at work size

        def read(i: int) -> tuple[np.ndarray, float]:
            nonlocal held
            if held is None or held[0] != i:
                rgb, factor = wmk.open_photo(self.photos[i])
                held = (i, rgb, factor)
            return held[1], held[2]

        def stopped() -> bool:
            return self._preempt.is_set() or self._closing

        def learned(result: wmk.Result) -> None:
            if result.how == "same":
                library.touch(result.wm)
            else:
                result.wm = library.add(result.wm)
                with self._lock:
                    self._tried.clear()          # what found nothing before may know it now
                self._sig.library.emit(len(library.items))

        def look(i: int, say) -> wmk.Result | None:
            rgb, factor = read(i)
            result = wmk.auto(rgb, library, progress=say, cancelled=stopped)
            with self._lock:
                if result is not None:
                    self._results[i] = (result, factor)
                    learned(result)
                else:
                    self._tried.add(i)
            self._sig.state.emit(i, "found" if result is not None else "none")
            return result

        def show(token: int, i: int, rgb: np.ndarray, result: wmk.Result | None, text: str) -> None:
            if result is None:
                self._sig.shown.emit(token, i, QImage(), QImage(), text)
                return
            out, changed = wmk.remove(rgb, result.wm, result.copies)
            pv = _preview(out)
            self._sig.shown.emit(token, i, to_qimage(pv), _mask_preview(changed, pv.size), text)

        def found_text(result: wmk.Result) -> str:
            n = len(result.copies)
            copies = f"{n} cop{'y' if n == 1 else 'ies'}"
            return {"box": f"Learned the watermark from your box — {copies} taken out.",
                    "same": f"Your watermark — {copies} taken out.",
                    "grown": f"Your watermark, with words not seen before — learned here; {copies} taken out."}[result.how]

        while True:
            with self._lock:
                while not self._closing and not self._has_job():
                    self._lock.wait()
                if self._closing:
                    return
                self._preempt.clear()
                job = self._next_job()
            kind, *args = job
            try:
                if kind == "forget":
                    library.clear()
                    with self._lock:
                        self._tried.clear()
                    self._sig.library.emit(0)
                elif kind == "box":
                    token, i, (x0, y0, x1, y1) = args
                    rgb, factor = read(i)
                    h, w = rgb.shape[:2]
                    self._sig.working.emit("Learning the watermark…")
                    result = wmk.from_box(rgb, (int(x0 * w), int(y0 * h), int(round(x1 * w)), int(round(y1 * h))),
                                          progress=lambda f, t: self._sig.working.emit(t), cancelled=stopped)
                    with self._lock:
                        self._results[i] = (result, factor)
                        self._tried.discard(i)
                        learned(result)
                    self._sig.state.emit(i, "found")
                    show(token, i, rgb, result, found_text(result))
                elif kind == "show":
                    token, i = args
                    rgb, _factor = read(i)
                    self._sig.loaded.emit(token, i, to_qimage(_preview(rgb)))
                    with self._lock:
                        have = self._results.get(i)
                        tried = i in self._tried
                    result = have[0] if have else None
                    if result is None and not tried:
                        self._sig.working.emit("Looking for your watermark…")
                        result = look(i, lambda f, t: self._sig.working.emit(t))
                    if result is None:
                        show(token, i, rgb, None, "No watermark found that it knows — drag a box round one whole "
                             "copy of it to teach it." if library.items else
                             "Drag a box round one whole copy of the watermark — it learns it from that copy and "
                             "the others like it, and remembers it for the next photos.")
                    else:
                        show(token, i, rgb, result, found_text(result))
                    with self._lock:
                        if self._show == (token, i):
                            self._show = None
                elif kind == "ahead":
                    (i,) = args
                    self._sig.working.emit(f"Looking through photo {i + 1} of {len(self.photos)} ahead of time…")
                    look(i, None)
                elif kind == "save":
                    as_new, i = args
                    path = self.photos[i]
                    with self._lock:
                        have = self._results.get(i)
                        tried = i in self._tried
                    try:
                        if have is None and not tried:
                            look(i, None)
                            with self._lock:
                                have = self._results.get(i)
                        if have is None:
                            self._sig.saved.emit(i, "none", "")
                        else:
                            result, factor = have
                            self._sig.saved.emit(i, "done", wmk.clean(path, result, factor, as_new=as_new))
                    except (bc.CropError, OSError) as e:
                        self._sig.saved.emit(i, "failed", str(e))
                    with self._lock:
                        if self._save is not None:
                            nxt = i + 1
                            self._save = (as_new, nxt) if nxt < len(self.photos) and not self._stop_saving.is_set() else None
                            if self._save is None:
                                self._sig.finished.emit()
            except wmk.Stopped:
                continue                         # something more wanted came up; it's picked up again later
            except wmk.NoWatermark as e:
                if kind == "box":
                    self._sig.shown.emit(args[0], args[1], QImage(), QImage(),
                                         f"Couldn't learn it from that box: {e}.")
            except (bc.CropError, OSError) as e:
                if kind == "forget":
                    continue
                i = args[1] if kind in ("box", "show") else args[0]
                self._sig.state.emit(i, "failed")
                if kind in ("box", "show"):
                    self._sig.shown.emit(args[0], i, QImage(), QImage(), f"Couldn't read this photo: {e}")
                with self._lock:
                    self._tried.add(i)
            except Exception as e:  # noqa: BLE001 — one bad photo never stops the window
                if kind == "save":
                    self._sig.saved.emit(args[1], "failed", f"{type(e).__name__}: {e}")
                    with self._lock:
                        self._save = None
                    self._sig.finished.emit()
                elif kind in ("box", "show"):
                    self._sig.shown.emit(args[0], args[1], QImage(), QImage(),
                                         f"Something went wrong: {type(e).__name__}: {e}")

    def _has_job(self) -> bool:
        return self._forget or self._box is not None or self._again is not None or self._save is not None \
            or self._show is not None or self._ahead() is not None

    def _ahead(self) -> int | None:
        """The next photo not looked through yet, from the one on screen on."""
        n = len(self.photos)
        for k in range(n):
            i = (self.current + k) % n
            if i not in self._results and i not in self._tried:      # (photos that can't be read are "tried")
                return i
        return None

    def _next_job(self) -> tuple:
        if self._forget:
            self._forget = False
            return ("forget",)
        if self._box is not None:
            job, self._box = ("box", *self._box), None
            self._show = None
            return job
        if self._again is not None:
            i, self._again = self._again, None
            self._results.pop(i, None)
            self._tried.discard(i)
            self._show = (self.token, i)
        if self._save is not None:
            return ("save", *self._save)
        if self._show is not None:
            return ("show", *self._show)
        return ("ahead", self._ahead())

    # -- writing them
    def run(self, as_new: bool) -> None:
        if self.saving:
            return
        self.as_new = as_new
        self.saving = True
        self.settings.setValue(SAVE_KEY, "new" if as_new else "replace")
        self._written, self._none, self._failed = [], 0, []
        self._stop_saving.clear()
        self.bar.setValue(0)
        self.bar.show()
        self.cancel_btn.setText("Stop")
        self.note.setText("Saving…")
        self._refresh()
        with self._lock:
            self._save = (as_new, 0)
            self._preempt.set()
            self._lock.notify_all()

    def _saved(self, i: int, outcome: str, detail: str) -> None:
        if outcome == "done":
            self._written.append((self.photos[i], detail))
        elif outcome == "none":
            self._none += 1
        else:
            self._failed.append((self.photos[i], detail))
        self.bar.setValue(i + 1)
        self.note.setText(f"Saving {min(i + 2, len(self.photos))} of {len(self.photos)}…")

    def _finished(self) -> None:
        if not self.saving:
            return
        self.saving = False
        self.on_done(list(self._written), self.as_new, self._none, len(self._failed))
        if self._failed:
            lines = "\n".join(f"• {os.path.basename(p)} — {why}" for p, why in self._failed[:12])
            more = f"\n…and {len(self._failed) - 12} more" if len(self._failed) > 12 else ""
            QMessageBox.warning(self, "Some Photos Weren't Changed",
                                f"Saved {len(self._written)} of {len(self.photos)}. These were left as they "
                                f"were:\n\n{lines}{more}")
        self._close_worker()
        self.accept()

    def reject(self) -> None:
        if self.saving:                          # Stop: finish the photo in hand, then wrap up
            self._stop_saving.set()
            self.cancel_btn.setEnabled(False)
            self.note.setText("Stopping after this photo…")
            return
        self._close_worker()
        super().reject()

    def closeEvent(self, event) -> None:  # noqa: N802
        if self.saving:
            self.reject()
            event.ignore()
            return
        self._close_worker()
        super().closeEvent(event)

    def _close_worker(self) -> None:
        with self._lock:
            self._closing = True
            self._preempt.set()
            self._lock.notify_all()
