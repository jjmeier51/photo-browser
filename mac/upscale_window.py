"""Safe Finder's AI Upscale windows: the options first (the model, how much of the original's texture to
keep, and whether to replace the photos or save the upscales as new photos beside them), the progress of a
run (ai_upscale.py does the work on worker threads — two photos at once where the Mac has the memory), and
the note shown when there's no Real-ESRGAN engine on this Mac yet (Get Upscayl / Choose Engine…).

The bar is the real thing: each photo moves it through reading, the network's pass — by the percentages
the engine prints as it works through its tiles — and saving, with the time left once there's enough to go
on. An engine that prints nothing still moves it, by how long the passes before took (or ~30 s for the
first). Stop kills the engines at once; the photos in hand are left as they were.
"""
from __future__ import annotations

import os
import threading
import time
from typing import Callable, NamedTuple

from PySide6.QtCore import QObject, Qt, QTimer, QUrl, Signal
from PySide6.QtGui import QDesktopServices
from PySide6.QtWidgets import (QComboBox, QDialog, QFileDialog, QFormLayout, QHBoxLayout, QLabel, QMessageBox,
                               QProgressBar, QPushButton, QSlider, QVBoxLayout, QWidget)

import ai_upscale as au


FIRST_GUESS = 30.0              # seconds for a network pass, until one has been timed
TEXTURE = 0.25                  # how much of the original's texture to keep, until chosen


class Choice(NamedTuple):
    how: str                    # "new" (save beside the original) / "replace" (in place)
    model: str
    texture: float              # 0–1


class UpscaleOptions(QDialog):
    """Before a run: the model (the photo models beside the engine, each with what it's like), Keep texture
    (0–100 %: how much of a plain enlargement of the original goes back in — its grain and fine texture,
    which the networks clean away), and Save as New / Replace. `choice()` is what was picked, or None."""

    def __init__(self, parent: QWidget | None, photos: list[str], engine: au.Engine, how: str = "new",
                 model: str | None = None, texture: float = TEXTURE) -> None:
        super().__init__(parent)
        self._picked: str | None = None
        n = len(photos)
        self.setWindowTitle("AI Upscale")
        self.setMinimumWidth(500)
        lay = QVBoxLayout(self)
        lay.setContentsMargins(20, 18, 20, 16)
        lay.setSpacing(12)
        what = f"“{os.path.basename(photos[0])}”" if n == 1 else f"these {n:,} photos"
        self.title = QLabel(f"Upscale {what} 2× with AI?", objectName="SheetTitle")
        self.title.setWordWrap(True)
        lay.addWidget(self.title)
        form = QFormLayout()
        form.setSpacing(8)
        self.model = QComboBox()
        for m in au.photo_models(engine) or [engine.model]:
            self.model.addItem(au.model_label(m), m)
        at = self.model.findData(model if model else engine.model)
        self.model.setCurrentIndex(at if at >= 0 else max(0, self.model.findData(engine.model)))
        form.addRow("Model", self.model)
        row = QHBoxLayout()
        self.texture = QSlider(Qt.Orientation.Horizontal)
        self.texture.setRange(0, 20)                          # 5 % steps
        self.texture.setValue(round(max(0.0, min(1.0, texture)) * 20))
        self.texture_label = QLabel()
        self.texture_label.setMinimumWidth(40)
        self.texture.valueChanged.connect(lambda v: self.texture_label.setText(f"{v * 5}%"))
        self.texture_label.setText(f"{self.texture.value() * 5}%")
        row.addWidget(self.texture, 1)
        row.addWidget(self.texture_label)
        form.addRow("Keep texture", row)
        lay.addLayout(form)
        hint = QLabel("Keep texture brings back that much of the original's grain and fine detail, which the "
                      "network cleans away — 0% is the network alone; 20–40% looks natural on most photos.",
                      objectName="SheetSub")
        hint.setWordWrap(True)
        lay.addWidget(hint)
        info = QLabel(
            f"Save as New puts the upscale beside {'it' if n == 1 else 'each'} as “… ({au.NEW_LABEL})” and leaves "
            f"the original as it is; Replace rewrites {'it' if n == 1 else 'them'} in place. Either way the format, "
            f"capture date, location and the rest of the metadata, the file dates and the tags are kept, and the "
            f"result is tagged “{au.UPSCALED_TAG}”. Uses {engine.label} on this Mac — nothing is uploaded. "
            "Photos over 12 MP are left as they are.", objectName="SheetSub")
        info.setWordWrap(True)
        lay.addWidget(info)
        buttons = QHBoxLayout()
        buttons.addStretch(1)
        cancel = QPushButton("Cancel")
        cancel.clicked.connect(self.reject)
        self.replace_btn = QPushButton("Replace Original" if n == 1 else "Replace Originals")
        self.replace_btn.clicked.connect(lambda: self._pick("replace"))
        self.new_btn = QPushButton("Save as New" if n == 1 else "Save as New Photos")
        self.new_btn.clicked.connect(lambda: self._pick("new"))
        for b in (cancel, self.replace_btn, self.new_btn):
            b.setAutoDefault(False)
            buttons.addWidget(b)
        (self.replace_btn if how == "replace" else self.new_btn).setDefault(True)
        lay.addLayout(buttons)

    def _pick(self, how: str) -> None:
        self._picked = how
        self.accept()

    def choice(self) -> Choice | None:
        if self._picked is None:
            return None
        return Choice(self._picked, self.model.currentData(), self.texture.value() / 20)


def ask_options(parent: QWidget | None, photos: list[str], engine: au.Engine, how: str = "new",
                model: str | None = None, texture: float = TEXTURE) -> Choice | None:
    """The options before a run (UpscaleOptions); None when cancelled. The arguments are last time's."""
    dlg = UpscaleOptions(parent, photos, engine, how, model, texture)
    dlg.exec()
    return dlg.choice()


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
    — itself, or the new photo) for each one done, and (path, why) for the ones left alone. `lanes` photos
    are worked on at once."""

    def __init__(self, parent: QWidget | None, photos: list[str], engine: au.Engine,
                 on_done: Callable[[list[tuple[str, str]], list[tuple[str, str]], list[tuple[str, str]]], None],
                 as_new: bool = False, texture: float = 0.0, lanes: int = 1) -> None:
        super().__init__(parent)
        self.photos, self.engine, self.on_done, self.as_new = photos, engine, on_done, as_new
        self.texture = texture
        self.running = True
        self._stop = threading.Event()
        self._done: list[tuple[str, str]] = []
        self._skipped: list[tuple[str, str]] = []
        self._failed: list[tuple[str, str]] = []
        self._finished_n = 0                                  # photos finished, whatever the outcome
        self._frac: dict[int, float] = {}                     # photos in hand: how far each is
        self._stage: dict[int, str] = {}
        self._real: dict[int, bool] = {}                      # the engine has said how far it is
        self._engine_at: dict[int, float] = {}                # when each one's network pass began
        self._passes: list[float] = []                        # how long the finished passes took
        self._started = time.monotonic()
        self._queue = list(range(len(photos)))
        self._qlock = threading.Lock()
        self._lanes = max(1, min(lanes, len(photos)))
        self._lanes_left = self._lanes
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
        bits = [f"2× with {engine.describe()}", "saved as new photos" if as_new else "in place"]
        if texture > 0:
            bits.append(f"{texture * 100:.0f}% texture kept")
        if self._lanes > 1:
            bits.append(f"{self._lanes} at a time")
        self.sub = QLabel(", ".join(bits) + ", on this Mac — nothing is uploaded.", objectName="SheetSub")
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
        self._title()
        self._tick = QTimer(self)                             # moves an estimated bar between engine lines
        self._tick.setInterval(250)
        self._tick.timeout.connect(self._estimate)
        self._tick.start()
        for k in range(self._lanes):
            threading.Thread(target=self._lane, name=f"ai-upscale-{k + 1}", daemon=True).start()

    def _title(self) -> None:
        n = len(self.photos)
        if n == 1:
            self.title.setText(f"Upscaling “{os.path.basename(self.photos[0])}”…")
            return
        busy = sorted(self._frac) or [min(self._finished_n, n - 1)]
        which = " and ".join(str(i + 1) for i in busy)
        self.title.setText(f"Upscaling {which} of {n} — “{os.path.basename(self.photos[busy[0]])}”…")

    def _next(self) -> int | None:
        with self._qlock:
            if self._stop.is_set() or not self._queue:
                return None
            return self._queue.pop(0)

    def _lane(self) -> None:
        while (i := self._next()) is not None:
            path = self.photos[i]
            try:
                r = au.upscale(self.engine, path, as_new=self.as_new, texture=self.texture, stop=self._stop,
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
        with self._qlock:
            self._lanes_left -= 1
            last = self._lanes_left == 0
        if last:
            self._sig.done.emit()

    def _step(self, i: int, stage: str, done: float) -> None:
        now = time.monotonic()
        if i not in self._frac:
            self._frac[i], self._real[i] = 0.0, False
            self._title()
        if stage == "engine" and done <= au.READ_DONE:
            self._engine_at[i], self._real[i] = now, False     # the network's pass begins
        elif stage == "engine":
            self._real[i] = True
        elif stage == "save" and self._stage.get(i) == "engine":
            self._passes.append(now - self._engine_at.get(i, now))
        self._stage[i] = stage
        self._frac[i] = max(self._frac[i], done)               # never backwards within a photo
        self._show()

    def _estimate(self) -> None:
        """No percentage from the engine (yet): move the bar by how long a pass has taken so far."""
        if not self.running:
            return
        expected = sum(self._passes) / len(self._passes) if self._passes else FIRST_GUESS
        moved = False
        for i, stage in self._stage.items():
            if stage != "engine" or self._real.get(i) or i not in self._frac:
                continue
            took = time.monotonic() - self._engine_at.get(i, time.monotonic())
            guess = au.READ_DONE + (au.ENGINE_DONE - au.READ_DONE) * min(0.95, took / expected)
            if guess > self._frac[i]:
                self._frac[i] = guess
                moved = True
        if moved:
            self._show()

    def _show(self) -> None:
        n = len(self.photos)
        overall = min(1.0, (self._finished_n + sum(self._frac.values())) / n)
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
        for d in (self._frac, self._stage, self._real, self._engine_at):
            d.pop(i, None)
        if outcome == "stopped":
            return
        self._finished_n += 1
        self._show()
        if not self._stop.is_set():
            self._title()

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
        if self.running:                          # Stop: the engines are ended; the photos in hand stay as they were
            self._stop.set()
            self.stop_btn.setEnabled(False)
            self.title.setText("Stopping…")
            self.detail.setText("The photos in hand are left as they were.")
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
