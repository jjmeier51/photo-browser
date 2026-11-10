"""Safe Finder's "Upscale Video…" window (video_tools.upscale does the work): the size to upscale to (1080p or
4K), the frame rate (the video's own, 30 or 60 — as the iPhone app's upscale offers), and whether each result
replaces its video or is saved as a new one beside it; then the run, one video at a time, with a bar that
follows the encoder and a Stop that leaves the video in hand exactly as it was.

A video already that size or larger is left alone (nothing is ever scaled down). A WebM/MKV can't be replaced
in place — what comes out is an MP4 — so it's always saved as a new video.
"""
from __future__ import annotations

import os
import threading
import time
from typing import Callable

from PySide6.QtCore import QObject, Signal
from PySide6.QtWidgets import (QButtonGroup, QDialog, QFormLayout, QHBoxLayout, QLabel, QProgressBar, QPushButton,
                               QRadioButton, QVBoxLayout, QWidget)

import video_tools as vt

IN_PLACE_EXT = {".mp4", ".mov", ".m4v"}


class _Bridge(QObject):
    sized = Signal(object)                  # {path: (w, h) | None}
    progress = Signal(int, float)           # (index, fraction of that video)
    one = Signal(int, str, str)             # (index, outcome, result path)
    finished = Signal()


def _row(*buttons: QRadioButton) -> QWidget:
    w = QWidget()
    lay = QHBoxLayout(w)
    lay.setContentsMargins(0, 0, 0, 0)
    for b in buttons:
        lay.addWidget(b)
    lay.addStretch(1)
    return w


class VideoUpscaleDialog(QDialog):
    """`done(upscaled, skipped, failed, as_new)`: upscaled is [(original, result)] — the same path twice when
    it was replaced."""

    def __init__(self, parent, videos: list[str], settings, done: Callable) -> None:
        super().__init__(parent)
        self.videos, self.settings, self.done_cb = list(videos), settings, done
        self.sizes: dict[str, tuple[int, int] | None] = {}
        self.running = self.stopping = False
        self.upscaled: list[tuple[str, str]] = []
        self.skipped: list[str] = []
        self.failed: list[str] = []
        self.bridge = _Bridge()
        self.bridge.sized.connect(self._sized)
        self.bridge.progress.connect(self._progress)
        self.bridge.one.connect(self._one)
        self.bridge.finished.connect(self._finished)
        n = len(self.videos)
        self.setWindowTitle("Upscale Video" if n == 1 else f"Upscale {n} Videos")
        self.resize(520, 300)

        def radios(key: str, default: str, options: list[tuple[str, str]]) -> tuple[QButtonGroup, QWidget]:
            group = QButtonGroup(self)
            saved = str(settings.value(f"videoUpscale/{key}", default)) if settings is not None else default
            made = []
            for value, text in options:
                b = QRadioButton(text)
                b.setProperty("value", value)
                b.setChecked(value == saved)
                group.addButton(b)
                made.append(b)
            if group.checkedButton() is None:
                made[0].setChecked(True)
            group.buttonToggled.connect(lambda *_a: self._describe())
            return group, _row(*made)

        self.size_group, size_row = radios("size", "1080p", [("1080p", "1080p"), ("4K", "4K")])
        self.fps_group, fps_row = radios("fps", "source", [("source", "Same as the video"), ("30", "30 fps"), ("60", "60 fps")])
        self.save_group, save_row = radios("save", "new", [("new", "As a new video beside it"), ("replace", "Replace the video")])
        form = QFormLayout()
        form.addRow("Upscale to:", size_row)
        form.addRow("Frame rate:", fps_row)
        form.addRow("Save:", save_row)
        self.options = QWidget()
        self.options.setLayout(form)
        self.info = QLabel("Reading the videos…")
        self.info.setWordWrap(True)
        self.bar = QProgressBar()
        self.bar.setRange(0, 1000)
        self.bar.setVisible(False)
        self.go = QPushButton("Upscale")
        self.go.setDefault(True)
        self.go.setEnabled(False)
        self.go.clicked.connect(self._start)
        self.cancel = QPushButton("Cancel")
        self.cancel.clicked.connect(self._cancel)
        buttons = QHBoxLayout()
        buttons.addStretch(1)
        buttons.addWidget(self.cancel)
        buttons.addWidget(self.go)
        lay = QVBoxLayout(self)
        lay.addWidget(self.options)
        lay.addWidget(self.info, 1)
        lay.addWidget(self.bar)
        lay.addLayout(buttons)
        threading.Thread(target=self._read_sizes, daemon=True, name="video-sizes").start()

    # -- options
    def _value(self, group: QButtonGroup) -> str:
        b = group.checkedButton()
        return str(b.property("value")) if b is not None else ""

    def _read_sizes(self) -> None:
        tool = vt.available()
        sizes = {p: (vt.size(p) if tool else None) for p in self.videos}
        self.bridge.sized.emit(sizes)

    def _sized(self, sizes: dict) -> None:
        self.sizes = sizes
        self._describe()

    def _todo(self) -> list[str]:
        target = vt.TARGETS[self._value(self.size_group) or "1080p"]
        return [p for p in self.videos if not (self.sizes.get(p) and min(self.sizes[p]) >= target)]

    def _describe(self) -> None:
        if self.running or not self.sizes:
            return
        if not vt.available():
            self.info.setText(vt.note or "Videos can't be upscaled on this Mac yet.")
            self.go.setEnabled(False)
            return
        label = self._value(self.size_group) or "1080p"
        todo = self._todo()
        big = len(self.videos) - len(todo)
        lines = []
        if len(self.videos) == 1 and self.sizes.get(self.videos[0]):
            w, h = self.sizes[self.videos[0]]
            lines.append(f"“{os.path.basename(self.videos[0])}” is {w} × {h}.")
        if big:
            lines.append(f"{big:,} {'is' if big == 1 else 'are'} already {label} or larger and will be left "
                         f"as {'it is' if big == 1 else 'they are'}.")
        forced = [p for p in todo if os.path.splitext(p)[1].lower() not in IN_PLACE_EXT]
        if forced and self._value(self.save_group) == "replace":
            lines.append(f"{len(forced):,} WebM/MKV video{'s' if len(forced) != 1 else ''} can't be replaced in place "
                         "— saved as new MP4s instead.")
        if label == "4K":
            lines.append("4K takes a while and makes large files — several minutes a minute of video on most Macs.")
        if self._value(self.fps_group) != "source":
            lines.append("A different frame rate repeats or drops frames; nothing is invented between them.")
        lines.append("The capture date, metadata and tags are kept; each result is tagged “upscaled”."
                     + (" Nothing is scaled down." if not big else ""))
        self.info.setText("\n".join(lines))
        self.go.setText("Upscale" if len(todo) == len(self.videos) or not todo else f"Upscale {len(todo):,}")
        self.go.setEnabled(bool(todo))

    # -- the run
    def _start(self) -> None:
        if self.running:
            return
        label, fps, save = self._value(self.size_group), self._value(self.fps_group), self._value(self.save_group)
        if self.settings is not None:
            for key, value in (("size", label), ("fps", fps), ("save", save)):
                self.settings.setValue(f"videoUpscale/{key}", value)
        self.todo = self._todo()
        self.skipped = [p for p in self.videos if p not in self.todo]
        self.as_new = save == "new"
        self.running = True
        self.options.setEnabled(False)
        self.go.setEnabled(False)
        self.cancel.setText("Stop")
        self.bar.setVisible(True)
        self.started = time.monotonic()
        target = vt.TARGETS[label]
        rate = None if fps == "source" else float(fps)
        todo, as_new = list(self.todo), self.as_new

        def work() -> None:
            for i, path in enumerate(todo):
                if self.stopping:
                    break
                new = as_new or os.path.splitext(path)[1].lower() not in IN_PLACE_EXT
                out = vt.new_name(path, label) if new else None
                outcome = vt.upscale(path, target, rate, out, progress=lambda f, i=i: self.bridge.progress.emit(i, f),
                                     stop=lambda: self.stopping)
                self.bridge.one.emit(i, outcome, out or path)
            self.bridge.finished.emit()
        threading.Thread(target=work, daemon=True, name="video-upscale").start()
        self._progress(0, 0.0)

    def _progress(self, index: int, fraction: float) -> None:
        if not self.running:
            return
        total = len(self.todo)
        self.bar.setValue(int(1000 * (index + fraction) / max(total, 1)))
        name = os.path.basename(self.todo[index]) if index < total else ""
        line = f"Upscaling {index + 1:,} of {total:,} — {name}" if total > 1 else f"Upscaling {name}"
        done = index + fraction
        secs = time.monotonic() - self.started
        if done > 0.05 and secs > 8:
            left = secs / done * (total - done)
            line += f"  ·  about {left / 60:.0f} min left" if left >= 90 else f"  ·  about {max(left, 1):.0f} s left"
        self.info.setText(line)

    def _one(self, index: int, outcome: str, result: str) -> None:
        path = self.todo[index]
        if outcome == "upscaled":
            self.upscaled.append((path, result))
        elif outcome == "skipped":
            self.skipped.append(path)
        elif outcome != "stopped":
            self.failed.append(path)

    def _finished(self) -> None:
        self.running = False
        self.done_cb(self.upscaled, self.skipped, self.failed, self.as_new)
        self.accept()

    def _cancel(self) -> None:
        if self.running:
            self.stopping = True
            self.cancel.setEnabled(False)
            self.info.setText("Stopping — the video in hand is left as it was…")
        else:
            self.reject()

    def reject(self) -> None:
        if self.running:
            self._cancel()
            return
        super().reject()
