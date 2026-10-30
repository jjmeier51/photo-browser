"""Safe Finder's AI Upscale windows: the question first (replace the photos, or save the upscales as new
photos beside them), the progress of a run (ai_upscale.py does the work, on a worker thread, one photo at a
time), and the note shown when there's no Real-ESRGAN engine on this Mac yet (Get Upscayl / Choose Engine…).

The bar is the real thing: each photo moves it through reading, the network's pass — by the percentages
the engine prints as it works through its tiles — and saving, with the time left once there's enough to go
on. An engine that prints nothing still moves it, by how long the photos before took (or ~30 s for the
first). Stop kills the engine at once; the photo in hand is left as it was.
"""
from __future__ import annotations

import os
import threading
import time
from typing import Callable

from PySide6.QtCore import QObject, Qt, QTimer, QUrl, Signal
from PySide6.QtGui import QDesktopServices
from PySide6.QtWidgets import (QDialog, QFileDialog, QHBoxLayout, QLabel, QMessageBox, QProgressBar, QPushButton,
                               QVBoxLayout, QWidget)

import ai_upscale as au


FIRST_GUESS = 30.0              # seconds for a network pass, until one has been timed


def ask_how(parent: QWidget | None, photos: list[str], engine: au.Engine, default: str) -> str | None:
    """Before a run: "replace" (rewrite the photos in place), "new" (save the upscales as new photos beside
    them) or None (cancelled). `default` is the answer last time."""
    n = len(photos)
    what = f"“{os.path.basename(photos[0])}”" if n == 1 else f"these {n:,} photos"
    box = QMessageBox(parent)
    box.setIcon(QMessageBox.Icon.Question)
    box.setWindowTitle("AI Upscale")
    box.setText(f"Upscale {what} 2× with AI?")
    box.setInformativeText(
        f"Save as New puts the upscale beside {'it' if n == 1 else 'each'} as “… ({au.NEW_LABEL})” and leaves "
        f"the original as it is; Replace rewrites {'it' if n == 1 else 'them'} in place. Either way the format, "
        f"capture date, location and the rest of the metadata, the file dates and the tags are kept, and the "
        f"result is tagged “{au.UPSCALED_TAG}”.\n\nUses {engine.describe()} on this Mac — nothing is uploaded. "
        "Photos over 12 MP are left as they are.")
    new = box.addButton("Save as New" if n == 1 else "Save as New Photos", QMessageBox.ButtonRole.AcceptRole)
    replace = box.addButton("Replace Original" if n == 1 else "Replace Originals", QMessageBox.ButtonRole.ActionRole)
    box.addButton(QMessageBox.StandardButton.Cancel)
    box.setDefaultButton(replace if default == "replace" else new)
    box.exec()
    clicked = box.clickedButton()
    return "new" if clicked is new else "replace" if clicked is replace else None


def _left(secs: float) -> str:
    if secs >= 90:
        return f"about {secs / 60:.0f} min left"
    return f"about {max(5, round(secs / 5) * 5):.0f} s left"


class _Signals(QObject):
    step = Signal(int, str, float)              # index, stage, how much of that photo is done (0–1)
    progress = Signal(int, str, str, str, str)  # index, path, outcome ("done"/"skipped"/"failed"/"stopped"), detail, result
    done = Signal()


class UpscaleRun(QDialog):
    """`on_done(upscaled, skipped, failed)` runs on the UI thread at the end: (photo, where its upscale went
    — itself, or the new photo) for each one done, and (path, why) for the ones left alone."""

    def __init__(self, parent: QWidget | None, photos: list[str], engine: au.Engine,
                 on_done: Callable[[list[tuple[str, str]], list[tuple[str, str]], list[tuple[str, str]]], None],
                 as_new: bool = False) -> None:
        super().__init__(parent)
        self.photos, self.engine, self.on_done, self.as_new = photos, engine, on_done, as_new
        self.running = True
        self._stop = threading.Event()
        self._done: list[tuple[str, str]] = []
        self._skipped: list[tuple[str, str]] = []
        self._failed: list[tuple[str, str]] = []
        self._i, self._stage, self._frac = 0, "read", 0.0     # the photo in hand, and how far it is
        self._real = False                                    # the engine has said how far it is, this photo
        self._engine_at = 0.0                                 # when this photo's network pass began
        self._passes: list[float] = []                        # how long the finished passes took
        self._started = time.monotonic()
        self._sig = _Signals()
        self._sig.step.connect(self._step)
        self._sig.progress.connect(self._progress)
        self._sig.done.connect(self._finished)
        self.setWindowTitle("AI Upscale")
        self.setMinimumWidth(460)
        lay = QVBoxLayout(self)
        lay.setContentsMargins(20, 18, 20, 16)
        lay.setSpacing(10)
        self.title = QLabel(objectName="SheetTitle")
        self.title.setWordWrap(True)
        lay.addWidget(self.title)
        where = "saved as new photos" if as_new else "in place"
        self.sub = QLabel(f"2× with {engine.describe()}, {where}, on this Mac — nothing is uploaded.",
                          objectName="SheetSub")
        self.sub.setWordWrap(True)
        lay.addWidget(self.sub)
        self.bar = QProgressBar()
        self.bar.setRange(0, 1000)
        self.bar.setTextVisible(False)
        lay.addWidget(self.bar)
        self.detail = QLabel("Starting…", objectName="SheetSub")
        lay.addWidget(self.detail)
        row = QHBoxLayout()
        row.addStretch(1)
        self.stop_btn = QPushButton("Stop")
        self.stop_btn.clicked.connect(self.reject)
        row.addWidget(self.stop_btn)
        lay.addLayout(row)
        self._name(0)
        self._tick = QTimer(self)                             # moves an estimated bar between engine lines
        self._tick.setInterval(250)
        self._tick.timeout.connect(self._estimate)
        self._tick.start()
        threading.Thread(target=self._work, name="ai-upscale", daemon=True).start()

    def _name(self, i: int) -> None:
        n = len(self.photos)
        name = os.path.basename(self.photos[min(i, n - 1)])
        self.title.setText(f"Upscaling “{name}”…" if n == 1 else f"Upscaling {min(i + 1, n)} of {n} — “{name}”…")

    def _work(self) -> None:
        for i, path in enumerate(self.photos):
            if self._stop.is_set():
                break
            try:
                r = au.upscale(self.engine, path, as_new=self.as_new, stop=self._stop,
                               progress=lambda stage, done, i=i: self._sig.step.emit(i, stage, done))
                self._sig.progress.emit(i, path, "done", f"{r.width}×{r.height}", r.path)
            except au.Stopped:
                self._sig.progress.emit(i, path, "stopped", "", "")
                break
            except au.Skipped as e:
                self._sig.progress.emit(i, path, "skipped", str(e), "")
            except (au.UpscaleError, OSError) as e:
                self._sig.progress.emit(i, path, "failed", str(e), "")
            except Exception as e:  # noqa: BLE001 — one bad photo never stops the rest
                self._sig.progress.emit(i, path, "failed", f"{type(e).__name__}: {e}", "")
        self._sig.done.emit()

    def _step(self, i: int, stage: str, done: float) -> None:
        now = time.monotonic()
        if i != self._i:
            self._i, self._frac, self._real = i, 0.0, False
            self._name(i)
        if stage == "engine" and done <= au.READ_DONE:
            self._engine_at, self._real = now, False           # the network's pass begins
        elif stage == "engine":
            self._real = True
        elif stage == "save" and self._stage == "engine":
            self._passes.append(now - self._engine_at)
        self._stage = stage
        self._frac = max(self._frac, done)                      # never backwards within a photo
        self._show()

    def _estimate(self) -> None:
        """No percentage from the engine (yet): move the bar by how long a pass has taken so far."""
        if self._stage != "engine" or self._real or not self.running:
            return
        expected = sum(self._passes) / len(self._passes) if self._passes else FIRST_GUESS
        guess = au.READ_DONE + (au.ENGINE_DONE - au.READ_DONE) * min(0.95, (time.monotonic() - self._engine_at) / expected)
        if guess > self._frac:
            self._frac = guess
            self._show()

    def _show(self) -> None:
        n = len(self.photos)
        overall = min(1.0, (self._i + self._frac) / n)
        self.bar.setValue(round(1000 * overall))
        text = f"{overall * 100:.0f}%"
        elapsed = time.monotonic() - self._started
        if 0.03 < overall < 1 and elapsed > 3:
            text += "  ·  " + _left(elapsed * (1 - overall) / overall)
        if not self._stop.is_set():
            self.detail.setText(text)

    def _progress(self, i: int, path: str, outcome: str, detail: str, result: str) -> None:
        if outcome == "done":
            self._done.append((path, result))
        elif outcome == "skipped":
            self._skipped.append((path, detail))
        elif outcome == "failed":
            self._failed.append((path, detail))
        if outcome == "stopped":
            return
        self._i, self._stage, self._frac, self._real = i + 1, "read", 0.0, False
        self._show()
        if not self._stop.is_set() and i + 1 < len(self.photos):
            self._name(i + 1)

    def _finished(self) -> None:
        self.running = False
        self._tick.stop()
        self.on_done(list(self._done), list(self._skipped), list(self._failed))
        if self._failed:
            lines = "\n".join(f"• {os.path.basename(p)} — {why}" for p, why in self._failed[:12])
            more = f"\n…and {len(self._failed) - 12} more" if len(self._failed) > 12 else ""
            QMessageBox.warning(self, "Some Photos Weren't Upscaled",
                                f"Upscaled {len(self._done)} of {len(self.photos)}. These were left as they "
                                f"were:\n\n{lines}{more}")
        self.accept()

    def reject(self) -> None:
        if self.running:                          # Stop: the engine is ended; the photo in hand stays as it was
            self._stop.set()
            self.stop_btn.setEnabled(False)
            self.title.setText("Stopping…")
            self.detail.setText("The photo in hand is left as it was.")
            return
        super().reject()

    def closeEvent(self, event) -> None:  # noqa: N802
        if self.running:
            self.reject()
            event.ignore()
            return
        super().closeEvent(event)


def ask_for_engine(parent: QWidget | None) -> tuple[au.Engine, str] | None:
    """No engine found: says what's needed, opens upscayl.org, or lets one be picked (an app, or the engine
    itself). Returns the engine picked and the path to remember, or None."""
    while True:
        box = QMessageBox(parent)
        box.setIcon(QMessageBox.Icon.Information)
        box.setWindowTitle("AI Upscale")
        box.setText("AI upscaling needs Real-ESRGAN on this Mac.")
        box.setInformativeText(
            "It runs on your Mac's graphics chip — nothing is uploaded. The easiest way to get it is the free "
            "Upscayl app (upscayl.org, or “brew install --cask upscayl”): install it, then choose AI Upscale "
            "again — Safe Finder finds it on its own. A realesrgan-ncnn-vulkan release works too: unzip it into "
            "~/Library/Application Support/Safe Finder/Real-ESRGAN, or pick it with Choose Engine….")
        get = box.addButton("Get Upscayl", QMessageBox.ButtonRole.AcceptRole)
        choose = box.addButton("Choose Engine…", QMessageBox.ButtonRole.ActionRole)
        box.addButton(QMessageBox.StandardButton.Cancel)
        box.setDefaultButton(get)
        box.exec()
        clicked = box.clickedButton()
        if clicked is get:
            QDesktopServices.openUrl(QUrl(au.UPSCAYL_URL))
            return None
        if clicked is not choose:
            return None
        path, _ = QFileDialog.getOpenFileName(parent, "Choose the Upscayl app or a Real-ESRGAN engine",
                                              "/Applications")
        if not path:
            return None
        engine = au.engine_from(path)
        if engine is not None:
            return engine, path
        QMessageBox.warning(parent, "AI Upscale",
                            f"“{os.path.basename(path)}” isn't a Real-ESRGAN engine with its models beside it.")
