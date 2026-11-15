"""Photo Browser for Mac's Stitch Videos window (video_stitch.py does the work).

The selected clips in a list: **drag them into the order they should play** (or Oldest First / Newest First /
By Name; ↑ ↓; Remove). Under it, what will happen — joined as they are when the clips are alike, re-encoded
onto one canvas when they aren't (then the size and frame rate can be chosen) — and what the new video
inherits: the oldest clip's date, the place, every clip's tags. **Stitch** shows how far along it is; Stop
leaves nothing behind. `on_done(written, sources, notes)` then runs on the UI thread.
"""
from __future__ import annotations

import os
import threading
import time
from typing import Callable

from PySide6.QtCore import QObject, Qt, Signal
from PySide6.QtWidgets import (QAbstractItemView, QCheckBox, QComboBox, QDialog, QHBoxLayout, QLabel, QListWidget,
                               QListWidgetItem, QMessageBox, QProgressBar, QPushButton, QVBoxLayout, QWidget)

import video_stitch as vs


def _clock(seconds: float) -> str:
    s = int(round(seconds))
    return f"{s // 3600}:{s % 3600 // 60:02d}:{s % 60:02d}" if s >= 3600 else f"{s // 60}:{s % 60:02d}"


class _Signals(QObject):
    probed = Signal(object, object)             # [Clip], [why…]
    progress = Signal(float)
    done = Signal(str, object, str)             # path, notes, why


class StitchWindow(QDialog):
    def __init__(self, parent: QWidget | None, paths: list[str], settings,
                 on_done: Callable[[str, list[str], list[str]], None]) -> None:
        super().__init__(parent)
        self.paths, self.settings, self.on_done = list(paths), settings, on_done
        self.clips: dict[str, vs.Clip] = {}
        self.running = False
        self._stop = threading.Event()
        self._sig = _Signals()
        self._sig.probed.connect(self._probed)
        self._sig.progress.connect(lambda f: self.bar.setValue(int(f * 1000)))
        self._sig.done.connect(self._done)
        self.setWindowTitle("Stitch Videos")
        self.setMinimumSize(620, 520)
        lay = QVBoxLayout(self)
        lay.setContentsMargins(20, 18, 20, 16)
        lay.setSpacing(9)
        self.title = QLabel("Stitch Videos", objectName="SheetTitle")
        lay.addWidget(self.title)
        sub = QLabel("Drag the clips into the order they should play. The new video is saved beside the first one.",
                     objectName="SheetSub")
        sub.setWordWrap(True)
        lay.addWidget(sub)
        row = QHBoxLayout()
        self.order_buttons = []
        for key, name in vs.ORDERS[1:]:
            b = self._button(name, lambda _=False, key=key: self.sort(key))
            self.order_buttons.append(b)
            row.addWidget(b)
        row.addStretch(1)
        self.up_btn = self._button("↑", lambda: self.move(-1), "Earlier")
        self.down_btn = self._button("↓", lambda: self.move(1), "Later")
        self.remove_btn = self._button("Remove", self.remove, "Leave this clip out")
        for b in (self.up_btn, self.down_btn, self.remove_btn):
            row.addWidget(b)
        lay.addLayout(row)
        self.list = QListWidget()
        self.list.setDragDropMode(QAbstractItemView.DragDropMode.InternalMove)
        self.list.setDefaultDropAction(Qt.DropAction.MoveAction)
        self.list.setAlternatingRowColors(True)
        self.list.model().rowsMoved.connect(lambda *_: self._changed())
        self.list.currentRowChanged.connect(lambda _r: self._buttons())
        lay.addWidget(self.list, 1)
        self.reencode = QCheckBox("Always re-encode (for clips that won't join cleanly as they are)")
        self.reencode.setChecked(str(settings.value("stitch/reencode", "false")) == "true")
        self.reencode.toggled.connect(lambda on: (settings.setValue("stitch/reencode", "true" if on else "false"), self._changed()))
        lay.addWidget(self.reencode)
        row = QHBoxLayout()
        self.size_label = QLabel("Size")
        self.size = QComboBox()
        for key, name in vs.SIZES:
            self.size.addItem(name, key)
        self.size.setCurrentIndex(max(0, self.size.findData(str(settings.value("stitch/size", "first")))))
        self.size.activated.connect(lambda _i: (settings.setValue("stitch/size", self.size.currentData()), self._changed()))
        self.fps_label = QLabel("Frame rate")
        self.fps = QComboBox()
        self.fps.addItem("The Fastest Clip's", 0.0)
        for f in (24.0, 25.0, 30.0, 50.0, 60.0):
            self.fps.addItem(f"{f:g} fps", f)
        self.fps.activated.connect(lambda _i: self._changed())
        for w in (self.size_label, self.size, self.fps_label, self.fps):
            row.addWidget(w)
        row.addStretch(1)
        lay.addLayout(row)
        self.how = QLabel("Reading the clips…", objectName="SheetSub")
        self.how.setWordWrap(True)
        lay.addWidget(self.how)
        self.inherits = QLabel("", objectName="SheetSub")
        self.inherits.setWordWrap(True)
        lay.addWidget(self.inherits)
        self.bar = QProgressBar()
        self.bar.setRange(0, 1000)
        self.bar.setTextVisible(False)
        self.bar.hide()
        lay.addWidget(self.bar)
        row = QHBoxLayout()
        row.addStretch(1)
        self.close_btn = self._button("Close", self.reject)
        self.go = QPushButton("Stitch", objectName="Primary")
        self.go.setAutoDefault(False)
        self.go.clicked.connect(self.start)
        row.addWidget(self.close_btn)
        row.addWidget(self.go)
        lay.addLayout(row)
        self._buttons()
        self._probe()

    def _button(self, text: str, slot, tip: str = "") -> QPushButton:
        b = QPushButton(text)
        b.setAutoDefault(False)
        b.setToolTip(tip)
        b.clicked.connect(slot)
        return b

    # ------------------------------------------------------------------ the clips
    def _probe(self) -> None:
        paths, sig = list(self.paths), self._sig

        def work() -> None:
            clips, bad = [], []
            for p in paths:
                try:
                    clips.append(vs.probe(p))
                except vs.StitchError as e:
                    bad.append(str(e))
            sig.probed.emit(clips, bad)
        threading.Thread(target=work, daemon=True).start()

    def _probed(self, clips: list, bad: list) -> None:
        self.clips = {c.path: c for c in clips}
        for c in clips:
            self._add_row(c)
        if bad:
            QMessageBox.information(self, "Stitch Videos", "Left out:\n\n" + "\n".join(bad[:12]))
        self._changed()

    def _add_row(self, c: vs.Clip) -> None:
        when = time.strftime("%-d %b %Y, %H:%M", time.localtime(c.created)) if c.created else ""
        bits = [_clock(c.duration), f"{c.width} × {c.height}", f"{c.fps:g} fps" if c.fps else "",
                c.vcodec.upper() + (" HDR" if c.hdr else ""), "no sound" if not c.acodec and c.vcodec else "",
                when + ("" if c.dated else " (file date)")]
        item = QListWidgetItem(f"{os.path.basename(c.path)}\n" + "  ·  ".join(b for b in bits if b))
        item.setData(Qt.ItemDataRole.UserRole, c.path)
        item.setToolTip(c.path)
        self.list.addItem(item)

    def order(self) -> list[vs.Clip]:
        return [self.clips[self.list.item(i).data(Qt.ItemDataRole.UserRole)] for i in range(self.list.count())]

    def sort(self, how: str) -> None:
        clips = vs.ordered(self.order(), how)
        self.list.clear()
        for c in clips:
            self._add_row(c)
        self._changed()

    def move(self, step: int) -> None:
        r = self.list.currentRow()
        j = r + step
        if r < 0 or not 0 <= j < self.list.count():
            return
        item = self.list.takeItem(r)
        self.list.insertItem(j, item)
        self.list.setCurrentRow(j)
        self._changed()

    def remove(self) -> None:
        r = self.list.currentRow()
        if r >= 0 and self.list.count() > 2:
            self.list.takeItem(r)
            self._changed()

    def plan(self) -> vs.Plan:
        return vs.plan(self.order(), self.reencode.isChecked(), str(self.size.currentData()), float(self.fps.currentData() or 0))

    def _changed(self) -> None:
        clips = self.order()
        n = len(clips)
        self.title.setText(f"Stitch {n} Videos" if n else "Stitch Videos")
        if n < 2:
            self.how.setText("Two or more videos are needed.")
            self.inherits.setText("")
            self._buttons()
            return
        p = self.plan()
        tool = vs.can_stitch()
        total = sum(c.duration for c in clips)
        self.how.setText((p.duration_note if tool else vs.NEEDS) + f"  Length: {_clock(total)}.")
        inh = vs.inherit(clips)
        bits = []
        if inh.when and inh.oldest is not None:
            bits.append("Date: " + time.strftime("%-d %B %Y, %H:%M", time.localtime(inh.when)) +
                        f" — the oldest clip's ({os.path.basename(inh.oldest.path)})")
        if inh.place:
            bits.append(f"Place: {inh.place[0]:.4f}, {inh.place[1]:.4f}")
        bits.append(f"Tags: every tag the {n} clips have, and “{vs.STITCHED_TAG}”")
        self.inherits.setText("The new video takes —  " + "  ·  ".join(bits) + f".  Saved as “{os.path.basename(vs.out_path(clips[0].path))}”.")
        for w in (self.size_label, self.size, self.fps_label, self.fps):
            w.setEnabled(not p.copy and not self.running)
        self._buttons()

    def _buttons(self) -> None:
        idle = not self.running
        r, n = self.list.currentRow(), self.list.count()
        self.up_btn.setEnabled(idle and r > 0)
        self.down_btn.setEnabled(idle and 0 <= r < n - 1)
        self.remove_btn.setEnabled(idle and r >= 0 and n > 2)
        for b in self.order_buttons:
            b.setEnabled(idle and n > 1)
        self.list.setEnabled(idle)
        self.reencode.setEnabled(idle)
        self.go.setEnabled(idle and n >= 2 and bool(vs.can_stitch()))
        self.close_btn.setText("Close" if idle else "Stop")

    # ------------------------------------------------------------------ the run
    def start(self) -> None:
        clips = self.order()
        if len(clips) < 2 or self.running:
            return
        p = self.plan()
        self.running = True
        self._stop.clear()
        self.bar.setValue(0)
        self.bar.show()
        self.how.setText(("Joining…" if p.copy else "Re-encoding and joining…") + " Stop leaves nothing behind.")
        self._changed_running()
        sig, stop = self._sig, self._stop

        def work() -> None:
            try:
                out, notes = vs.stitch(clips, p, sig.progress.emit, stop)
                sig.done.emit(out, notes, "")
            except vs.Stopped:
                sig.done.emit("", [], "stopped")
            except Exception as e:  # noqa: BLE001
                sig.done.emit("", [], str(e) or type(e).__name__)
        self._sources = [c.path for c in clips]
        threading.Thread(target=work, daemon=True).start()

    def _changed_running(self) -> None:
        for w in (self.size_label, self.size, self.fps_label, self.fps):
            w.setEnabled(False)
        self._buttons()

    def _done(self, path: str, notes: list, why: str) -> None:
        self.running = False
        self.bar.hide()
        if not path:
            self._changed()
            if why != "stopped":
                QMessageBox.warning(self, "Stitch Videos", f"Couldn't stitch the videos: {why}\n\nNothing was changed.")
            return
        try:
            self.on_done(path, list(self._sources), list(notes))
        finally:
            self.accept()

    def reject(self) -> None:
        if self.running:
            self._stop.set()
            self.how.setText("Stopping…")
            return
        super().reject()

    def closeEvent(self, event) -> None:  # noqa: N802
        if self.running:
            self._stop.set()
            event.ignore()
            return
        event.accept()
