"""Safe Finder's AI Upscale windows: the progress of a run (ai_upscale.py does the work, on a worker
thread, one photo at a time — Stop ends it after the photo in hand), and the note shown when there's no
Real-ESRGAN engine on this Mac yet (Get Upscayl / Choose Engine…).
"""
from __future__ import annotations

import os
import threading
from typing import Callable

from PySide6.QtCore import QObject, Qt, QUrl, Signal
from PySide6.QtGui import QDesktopServices
from PySide6.QtWidgets import (QDialog, QFileDialog, QHBoxLayout, QLabel, QMessageBox, QProgressBar, QPushButton,
                               QVBoxLayout, QWidget)

import ai_upscale as au


class _Signals(QObject):
    progress = Signal(int, str, str, str)       # index, path, outcome ("done" / "skipped" / "failed"), detail
    done = Signal()


class UpscaleRun(QDialog):
    """`on_done(upscaled, skipped, failed)` runs on the UI thread at the end: the paths rewritten, and
    (path, why) for the ones left alone."""

    def __init__(self, parent: QWidget | None, photos: list[str], engine: au.Engine,
                 on_done: Callable[[list[str], list[tuple[str, str]], list[tuple[str, str]]], None]) -> None:
        super().__init__(parent)
        self.photos, self.engine, self.on_done = photos, engine, on_done
        self.running = True
        self._stop = threading.Event()
        self._done: list[str] = []
        self._skipped: list[tuple[str, str]] = []
        self._failed: list[tuple[str, str]] = []
        self._sig = _Signals()
        self._sig.progress.connect(self._progress)
        self._sig.done.connect(self._finished)
        n = len(photos)
        self.setWindowTitle("AI Upscale")
        self.setMinimumWidth(460)
        lay = QVBoxLayout(self)
        lay.setContentsMargins(20, 18, 20, 16)
        lay.setSpacing(10)
        self.title = QLabel(objectName="SheetTitle")
        self.title.setWordWrap(True)
        lay.addWidget(self.title)
        self.sub = QLabel(f"2× with {engine.describe()}, on this Mac — nothing is uploaded.", objectName="SheetSub")
        self.sub.setWordWrap(True)
        lay.addWidget(self.sub)
        self.bar = QProgressBar()
        self.bar.setRange(0, n)
        lay.addWidget(self.bar)
        row = QHBoxLayout()
        row.addStretch(1)
        self.stop_btn = QPushButton("Stop")
        self.stop_btn.clicked.connect(self.reject)
        row.addWidget(self.stop_btn)
        lay.addLayout(row)
        self._name(0)
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
                w, h = au.upscale(self.engine, path)
                self._sig.progress.emit(i, path, "done", f"{w}×{h}")
            except au.Skipped as e:
                self._sig.progress.emit(i, path, "skipped", str(e))
            except (au.UpscaleError, OSError) as e:
                self._sig.progress.emit(i, path, "failed", str(e))
            except Exception as e:  # noqa: BLE001 — one bad photo never stops the rest
                self._sig.progress.emit(i, path, "failed", f"{type(e).__name__}: {e}")
        self._sig.done.emit()

    def _progress(self, i: int, path: str, outcome: str, detail: str) -> None:
        if outcome == "done":
            self._done.append(path)
        elif outcome == "skipped":
            self._skipped.append((path, detail))
        else:
            self._failed.append((path, detail))
        self.bar.setValue(i + 1)
        if not self._stop.is_set():
            self._name(i + 1)

    def _finished(self) -> None:
        self.running = False
        self.on_done(list(self._done), list(self._skipped), list(self._failed))
        if self._failed:
            lines = "\n".join(f"• {os.path.basename(p)} — {why}" for p, why in self._failed[:12])
            more = f"\n…and {len(self._failed) - 12} more" if len(self._failed) > 12 else ""
            QMessageBox.warning(self, "Some Photos Weren't Upscaled",
                                f"Upscaled {len(self._done)} of {len(self.photos)}. These were left as they "
                                f"were:\n\n{lines}{more}")
        self.accept()

    def reject(self) -> None:
        if self.running:                          # Stop: finish the photo in hand, then wrap up
            self._stop.set()
            self.stop_btn.setEnabled(False)
            self.title.setText("Stopping after this photo…")
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
