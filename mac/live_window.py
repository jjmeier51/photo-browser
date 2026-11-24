"""Find Live Photos — a folder's photo + video pairs that share a name, looked at side by side and made into Live
Photos together (live_photo.py does the work; this is the window).

Right-click a folder ▸ **Find Live Photos…** (or the Photos menu). The window lists every photo and video in the
folder that share a name — `IMG_1234.jpeg` + `IMG_1234.mov` — and aren't a Live Photo yet, **each pair as two
pictures side by side**: the photo, and the video's first frame with its length. Whether they're the same moment is
for the eye to say; the window helps: pairs that look right (a short video, the two files dated together) come
ticked; ones that don't (a long video, dates days apart — a downloaded gallery's `001.jpg` + `001.mp4`) come unticked
with the reason under them. Double-click either picture to open it in the viewer.

**Make N Live Photos** makes the ticked ones, one after another (Stop between any two): each video becomes its
photo's movie; the video as it was goes into the hidden `.Live Photo Originals` folder beside it — nothing is
deleted. Pairs that are Live Photos already are counted at the top, not listed.

The list is painted, not built of widgets: a folder with thousands of pairs opens at once, and pictures are asked
for only as rows come into view (the app's own thumbnails, through `LiveHooks.thumb`).
"""
from __future__ import annotations

import os
import threading
from dataclasses import dataclass
from typing import Callable

from PySide6.QtCore import QModelIndex, QObject, QRect, QSize, Qt, Signal
from PySide6.QtGui import QColor, QFontMetrics, QPainter, QPen, QPixmap
from PySide6.QtWidgets import (QAbstractItemView, QCheckBox, QHBoxLayout, QLabel, QListWidget, QListWidgetItem,
                               QMessageBox, QProgressBar, QPushButton, QStyle, QStyledItemDelegate, QVBoxLayout,
                               QWidget)

import live_photo

ROW = 118
THUMB = 100
PAIR = Qt.ItemDataRole.UserRole


@dataclass
class LiveHooks:
    thumb: Callable[[str], QPixmap | None] | None = None      # the app's thumbnail of a file (None: not ready yet)
    thumbs_ready: object = None                                # a signal: thumbnails came in — repaint
    write_image: Callable[[str, bytes], None] | None = None   # the app's undoable in-place writer
    batched: Callable[[Callable], Callable] = lambda fn: fn   # wraps a run over many photos (one undo step)
    made: Callable[[list], None] | None = None                # (what was made) — tags follow, the pane looks again
    view: Callable[[list[str], str], None] | None = None      # open these in the viewer, starting at one


def clock(seconds: float) -> str:
    return f"{seconds:.1f} s" if seconds < 10 else f"{int(seconds // 60)}:{int(seconds % 60):02d}"


class _Bridge(QObject):
    found = Signal(int, object)          # which scan, [Candidate]
    looking = Signal(int, str)
    progress = Signal(int, int, str)     # done, of, the name on now
    finished = Signal(object, object, bool)    # [Made], [(Candidate, why)], stopped


class _Rows(QStyledItemDelegate):
    """One pair a row: a tick, the photo, the video's picture with its length, and what's known about them."""

    def __init__(self, window: "LiveFindWindow") -> None:
        super().__init__(window)
        self.w = window

    def sizeHint(self, _option, _index) -> QSize:  # noqa: N802
        return QSize(520, ROW)

    def rects(self, r: QRect) -> tuple[QRect, QRect, QRect, QRect]:
        top = r.y() + (ROW - THUMB) // 2
        tick = QRect(r.x() + 12, r.y() + ROW // 2 - 10, 20, 20)
        photo = QRect(r.x() + 46, top, THUMB, THUMB)
        video = QRect(photo.right() + 34, top, THUMB, THUMB)
        text = QRect(video.right() + 18, r.y() + 10, max(40, r.right() - video.right() - 30), ROW - 20)
        return tick, photo, video, text

    def paint(self, p: QPainter, option, index: QModelIndex) -> None:
        c = index.data(PAIR)
        if c is None:
            return
        p.save()
        p.setRenderHint(QPainter.RenderHint.Antialiasing)
        p.setRenderHint(QPainter.RenderHint.SmoothPixmapTransform)
        r = option.rect
        pal = option.palette
        if option.state & QStyle.StateFlag.State_Selected:
            p.fillRect(r, pal.highlight().color().lighter(165) if pal.window().color().lightness() > 128
                       else pal.highlight().color().darker(220))
        tick, photo, video, text = self.rects(r)
        item = self.w.list.item(index.row())
        on = item is not None and item.checkState() == Qt.CheckState.Checked
        accent = pal.highlight().color()
        p.setPen(QPen(accent if on else pal.mid().color(), 1.6))
        p.setBrush(accent if on else Qt.BrushStyle.NoBrush)
        p.drawRoundedRect(tick.adjusted(1, 1, -1, -1), 5, 5)
        if on:
            p.setPen(QPen(QColor("white"), 2.2))
            p.drawLine(tick.x() + 5, tick.y() + 10, tick.x() + 9, tick.y() + 14)
            p.drawLine(tick.x() + 9, tick.y() + 14, tick.x() + 15, tick.y() + 6)
        for box, path in ((photo, c.image), (video, c.video)):
            p.setPen(Qt.PenStyle.NoPen)
            p.setBrush(QColor(0, 0, 0, 40))
            p.drawRoundedRect(box, 6, 6)
            pm = self.w.hooks.thumb(path) if self.w.hooks.thumb is not None else None
            if pm is not None and not pm.isNull():
                fit = pm.size().scaled(box.size(), Qt.AspectRatioMode.KeepAspectRatio)
                p.drawPixmap(QRect(box.x() + (box.width() - fit.width()) // 2,
                                   box.y() + (box.height() - fit.height()) // 2, fit.width(), fit.height()), pm)
        # the video's length, and a play mark on its picture
        p.setBrush(QColor(0, 0, 0, 150))
        p.setPen(Qt.PenStyle.NoPen)
        label = clock(c.seconds) if c.seconds > 0 else "?"
        fm = QFontMetrics(option.font)
        pill = QRect(video.x() + 4, video.bottom() - fm.height() - 5, fm.horizontalAdvance(label) + 10, fm.height() + 2)
        p.drawRoundedRect(pill, 5, 5)
        p.setPen(QColor("white"))
        p.drawText(pill, Qt.AlignmentFlag.AlignCenter, label)
        p.setPen(pal.mid().color())
        p.drawText(QRect(photo.right() + 1, photo.y(), video.x() - photo.right() - 1, THUMB),
                   Qt.AlignmentFlag.AlignCenter, "+")
        # what they are
        p.setPen(pal.text().color())
        bold = option.font
        bold.setBold(True)
        p.setFont(bold)
        lh = fm.height() + 3
        p.drawText(QRect(text.x(), text.y(), text.width(), lh), Qt.AlignmentFlag.AlignLeft | Qt.AlignmentFlag.AlignVCenter,
                   fm.elidedText(f"{os.path.basename(c.image)}  +  {os.path.basename(c.video)}",
                                 Qt.TextElideMode.ElideMiddle, text.width()))
        bold.setBold(False)
        p.setFont(bold)
        p.setPen(pal.placeholderText().color())
        apart = "" if c.apart is None else ("dated together" if c.apart < 5 else f"dated {live_photo._span(c.apart)} apart"
                                             if c.apart >= 60 else f"dated {c.apart:.0f} s apart")
        line = " · ".join(x for x in (f"video {label}", apart, self.w.where(c)) if x)
        p.drawText(QRect(text.x(), text.y() + lh, text.width(), lh), Qt.AlignmentFlag.AlignLeft | Qt.AlignmentFlag.AlignVCenter,
                   fm.elidedText(line, Qt.TextElideMode.ElideRight, text.width()))
        state = self.w.state.get(c.image)
        if state:
            p.setPen(QColor("#30D158") if state[0] else QColor("#FF9F0A"))
            note = state[1]
        elif c.notes:
            p.setPen(QColor("#FF9F0A"))
            note = "Not ticked: " + "; ".join(c.notes)
        else:
            p.setPen(pal.placeholderText().color())
            note = "Looks like a pair — check the two pictures"
        p.drawText(QRect(text.x(), text.y() + 2 * lh, text.width(), ROW - 20 - 2 * lh),
                   Qt.AlignmentFlag.AlignLeft | Qt.AlignmentFlag.AlignTop | Qt.TextFlag.TextWordWrap, note)
        p.setPen(QPen(pal.mid().color(), 0.5))
        p.drawLine(r.x() + 12, r.bottom(), r.right() - 12, r.bottom())
        p.restore()


class LiveFindWindow(QWidget):
    finished = Signal(list)              # the Live Photos made (live_photo.Made)

    def __init__(self, folder: str, hooks: LiveHooks | None = None, parent=None) -> None:
        super().__init__(parent, Qt.WindowType.Window)
        self.folder, self.hooks = folder, hooks or LiveHooks()
        self.setWindowTitle("Find Live Photos")
        self.resize(820, 680)
        self.running = False               # making them (Quit asks — MainWindow.busy_windows)
        self.scanning = False
        self.stop = threading.Event()
        self.pairs: list = []
        self.state: dict[str, tuple[bool, str]] = {}       # photo → (made, what happened)
        self.already = 0
        self._scan = 0
        self.bridge = _Bridge()
        self.bridge.found.connect(self._found)
        self.bridge.looking.connect(self._looking)
        self.bridge.progress.connect(self._progress)
        self.bridge.finished.connect(self._made)

        v = QVBoxLayout(self)
        name = os.path.basename(folder.rstrip(os.sep)) or folder
        head = QLabel(f"Photos and videos in “{name}” that share a name")
        head.setObjectName("SheetTitle")
        v.addWidget(head)
        self.sub = QLabel("Looking…")
        self.sub.setWordWrap(True)
        self.sub.setObjectName("SheetSub")
        v.addWidget(self.sub)
        row = QHBoxLayout()
        self.deep = QCheckBox("Look in the folders inside it too")
        self.deep.toggled.connect(lambda _on: self.look())
        row.addWidget(self.deep)
        row.addStretch(1)
        for text, fn in (("Tick the Likely Ones", lambda: self._tick(lambda c: c.likely)),
                         ("Tick All", lambda: self._tick(lambda c: True)),
                         ("Untick All", lambda: self._tick(lambda c: False))):
            b = QPushButton(text)
            b.clicked.connect(fn)
            row.addWidget(b)
        v.addLayout(row)
        self.list = QListWidget()
        self.list.setItemDelegate(_Rows(self))
        self.list.setUniformItemSizes(True)
        self.list.setSelectionMode(QAbstractItemView.SelectionMode.SingleSelection)
        self.list.setVerticalScrollMode(QAbstractItemView.ScrollMode.ScrollPerPixel)
        self.list.setAccessibleName("Photo and video pairs")
        self.list.itemClicked.connect(self._clicked)
        self.list.itemDoubleClicked.connect(self._opened)
        self.list.itemChanged.connect(lambda _it: self._update())
        v.addWidget(self.list, 1)
        if getattr(self.hooks, "thumbs_ready", None) is not None:
            self.hooks.thumbs_ready.connect(self.list.viewport().update)
        self.bar = QProgressBar()
        self.bar.setVisible(False)
        v.addWidget(self.bar)
        bottom = QHBoxLayout()
        self.status = QLabel("")
        self.status.setWordWrap(True)
        self.status.setObjectName("SheetSub")
        self.stop_btn = QPushButton("Stop")
        self.stop_btn.clicked.connect(self._stop)
        self.stop_btn.setEnabled(False)
        self.go = QPushButton("Make Live Photos")
        self.go.setObjectName("Primary")
        self.go.clicked.connect(self.make)
        bottom.addWidget(self.status, 1)
        bottom.addWidget(self.stop_btn)
        bottom.addWidget(self.go)
        v.addLayout(bottom)
        self._update()
        self.look()

    # ------------------------------------------------------------------ finding them
    def where(self, c) -> str:
        """The pair's folder, when the list spans several."""
        folder = os.path.dirname(c.image)
        return "" if folder == self.folder.rstrip(os.sep) else "in " + os.path.relpath(folder, self.folder)

    def look(self) -> None:
        if self.running:
            return
        self._scan += 1
        scan, folder, deep, bridge = self._scan, self.folder, self.deep.isChecked(), self.bridge
        self.scanning = True
        self.list.clear()
        self.pairs = []
        self.sub.setText("Looking…")
        self._update()

        def work() -> None:
            try:
                found = live_photo.candidates(folder, deep, stop=lambda: scan != self._scan,
                                              note=lambda where: bridge.looking.emit(scan, where))
            except Exception:  # noqa: BLE001 — a folder that can't be read lists nothing
                found = []
            try:
                bridge.found.emit(scan, found)
            except RuntimeError:
                pass
        threading.Thread(target=work, name="live-find", daemon=True).start()

    def _looking(self, scan: int, where: str) -> None:
        if scan == self._scan and self.scanning:
            self.sub.setText(f"Looking in “{os.path.basename(where) or where}”…")

    def _found(self, scan: int, found) -> None:
        if scan != self._scan:
            return
        self.scanning = False
        self.already = sum(1 for c in found if c.live)
        self.pairs = [c for c in found if not c.live]
        self.list.blockSignals(True)
        for c in self.pairs:
            it = QListWidgetItem()
            it.setData(PAIR, c)
            it.setFlags(Qt.ItemFlag.ItemIsEnabled | Qt.ItemFlag.ItemIsSelectable | Qt.ItemFlag.ItemIsUserCheckable)
            it.setCheckState(Qt.CheckState.Checked if c.likely else Qt.CheckState.Unchecked)
            it.setToolTip(f"{c.image}\n{c.video}")
            self.list.addItem(it)
        self.list.blockSignals(False)
        bits = []
        if self.pairs:
            n = len(self.pairs)
            bits.append(f"{n:,} pair{'s' if n != 1 else ''} could be made into Live Photos. Look at the two pictures "
                        "of each: tick the ones that are the same moment.")
        else:
            bits.append("No photo and video here share a name without being a Live Photo already.")
        if self.already:
            bits.append(f"{self.already:,} {'is a Live Photo' if self.already == 1 else 'are Live Photos'} already "
                        "(not listed).")
        self.sub.setText(" ".join(bits))
        self._update()

    # ------------------------------------------------------------------ the list
    def _items(self) -> list[QListWidgetItem]:
        return [self.list.item(i) for i in range(self.list.count())]

    def ticked(self) -> list:
        return [it.data(PAIR) for it in self._items() if it.checkState() == Qt.CheckState.Checked
                and it.data(PAIR).image not in self.state]

    def _tick(self, want) -> None:
        if self.running:
            return
        self.list.blockSignals(True)
        for it in self._items():
            c = it.data(PAIR)
            if c.image not in self.state:
                it.setCheckState(Qt.CheckState.Checked if want(c) else Qt.CheckState.Unchecked)
        self.list.blockSignals(False)
        self.list.viewport().update()
        self._update()

    def _clicked(self, it: QListWidgetItem) -> None:
        """A click anywhere on the row but its pictures ticks or unticks it."""
        if self.running or it.data(PAIR).image in self.state:
            return
        pos = self.list.viewport().mapFromGlobal(self.cursor().pos())
        _tick, photo, video, _text = self.list.itemDelegate().rects(self.list.visualItemRect(it))
        if photo.contains(pos) or video.contains(pos):
            return
        it.setCheckState(Qt.CheckState.Unchecked if it.checkState() == Qt.CheckState.Checked else Qt.CheckState.Checked)

    def _opened(self, it: QListWidgetItem) -> None:
        """A double-click on a picture opens it in the viewer (the pair: the photo, then the video)."""
        c = it.data(PAIR)
        if self.hooks.view is None:
            return
        pos = self.list.viewport().mapFromGlobal(self.cursor().pos())
        _tick, _photo, video, _text = self.list.itemDelegate().rects(self.list.visualItemRect(it))
        self.hooks.view([c.image, c.video], c.video if video.contains(pos) else c.image)

    def _update(self) -> None:
        n = len(self.ticked())
        self.go.setText(f"Make {n:,} Live Photo{'s' if n != 1 else ''}" if n else "Make Live Photos")
        self.go.setEnabled(bool(n) and not self.running and not self.scanning)
        self.deep.setEnabled(not self.running)
        if not self.running and not self.status.text().startswith(("Made", "Stopped", "Nothing")):
            self.status.setText("The video as it is now is kept, hidden, beside each Live Photo — nothing is deleted."
                                if n else "")

    # ------------------------------------------------------------------ making them
    def _stop(self) -> None:
        self.stop.set()
        self.status.setText("Stopping after this one…")

    def make(self) -> None:
        todo = self.ticked()
        if self.running or not todo:
            return
        self.running = True
        self.stop.clear()
        self.go.setEnabled(False)
        self.stop_btn.setEnabled(True)
        self.bar.setVisible(True)
        self.bar.setRange(0, len(todo))
        self.bar.setValue(0)
        bridge, stop, write = self.bridge, self.stop, self.hooks.write_image

        def work() -> None:
            made, failed = [], []
            for i, c in enumerate(todo):
                if stop.is_set():
                    break
                bridge.progress.emit(i, len(todo), os.path.basename(c.image))
                try:
                    made.append(live_photo.make(c.image, c.video, write_image=write))
                except live_photo.LiveError as e:
                    failed.append((c, str(e)))
                except Exception as e:  # noqa: BLE001 — one pair's trouble isn't the others'
                    failed.append((c, f"{type(e).__name__}: {e}"))
            try:
                bridge.finished.emit(made, failed, stop.is_set())
            except RuntimeError:
                pass
        threading.Thread(target=self.hooks.batched(work), name="live-make", daemon=True).start()

    def _progress(self, done: int, total: int, name: str) -> None:
        self.bar.setValue(done)
        self.status.setText(f"{done + 1:,} of {total:,} — {name}")

    def _made(self, made, failed, stopped: bool) -> None:
        self.running = False
        if getattr(self, "_closed", False):               # closed while it ran: the pane still hears what was made
            if made and self.hooks.made is not None:
                self.hooks.made(list(made))
            return
        self.stop_btn.setEnabled(False)
        self.bar.setVisible(False)
        for m in made:
            self.state[m.image] = (True, "Made — it's a Live Photo now")
        for c, why in failed:
            self.state[c.image] = (False, why)
        self.list.blockSignals(True)
        for it in self._items():
            if it.data(PAIR).image in self.state:
                it.setCheckState(Qt.CheckState.Unchecked)
        self.list.blockSignals(False)
        self.list.viewport().update()
        n = len(made)
        text = (f"Made {n:,} Live Photo{'s' if n != 1 else ''}." if n else "Nothing was made.") \
            + (f" {len(failed):,} couldn't be made — the reason is under each." if failed else "") \
            + (" Stopped." if stopped else "")
        if n:
            text += " The videos as they were are in the hidden “.Live Photo Originals” folder beside them."
        self.status.setText(text)
        self._update()
        if made and self.hooks.made is not None:
            self.hooks.made(list(made))
        self.finished.emit(list(made))

    def closeEvent(self, event) -> None:  # noqa: N802
        if self.running and QMessageBox.question(
                self, "Find Live Photos", "Live Photos are being made. Stop after the one under way and close?") \
                != QMessageBox.StandardButton.Yes:
            event.ignore()
            return
        self.stop.set()
        self._scan += 1
        self._closed = True
        super().closeEvent(event)
