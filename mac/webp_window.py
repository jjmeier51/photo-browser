"""Safe Finder ▸ Convert WebP to JPEG… — the window (webp_convert.py does the converting).

Counts the WebP photos first (on a worker thread — a folder's subfolders can be many), offers "Include subfolders"
and "Move the WebP originals to the Trash when their JPEG is saved" (both remembered), then converts with a
progress bar and Stop. Safe Finder's `done(result, moved)` moves the tags and Favorites / To AI over to the JPEGs.
"""
from __future__ import annotations

import os
import threading

from PySide6.QtCore import QObject, Qt, Signal
from PySide6.QtWidgets import (QCheckBox, QDialog, QHBoxLayout, QLabel, QProgressBar, QPushButton, QVBoxLayout)

import webp_convert as wc


class _Bridge(QObject):
    call = Signal(object, object)      # (callback, value) from a worker thread → back on the GUI thread


class WebPDialog(QDialog):
    def __init__(self, parent, paths: list[str], settings, trash, done) -> None:
        super().__init__(parent)
        self.setAttribute(Qt.WidgetAttribute.WA_DeleteOnClose)
        self.paths, self.settings, self.trash, self.done = paths, settings, trash, done
        self.bridge = _Bridge()
        self.bridge.call.connect(lambda cb, value: cb(value))
        self.found: dict[bool, list[str]] = {}
        self.running = self.stopping = False
        folders = [p for p in paths if os.path.isdir(p)]
        self.setWindowTitle("Convert WebP to JPEG")
        self.setMinimumWidth(520)

        self.head = QLabel("Looking for WebP photos…")
        self.head.setWordWrap(True)
        self.deep = QCheckBox("Include subfolders")
        self.deep.setVisible(bool(folders))
        self.deep.setChecked(bool(folders) and self._get("recursive", False))
        self.deep.toggled.connect(lambda on: (self._set("recursive", on), self._count_label()))
        self.to_trash = QCheckBox("Move the WebP originals to the Trash when their JPEG is saved")
        self.to_trash.setToolTip("Each original goes only once its JPEG has been written and checked; the Trash "
                                 "keeps it (Put Back works). Off: the WebP stays beside its JPEG.")
        self.to_trash.setChecked(self._get("trash", True))
        self.to_trash.toggled.connect(lambda on: self._set("trash", on))
        how = QLabel("Full resolution · JPEG quality 95 with full colour detail (4:4:4) · colour profile, EXIF and the "
                     "file's dates kept · transparency onto white · animated WebPs left as they are. Tags and "
                     "Favorites go with each photo.")
        how.setWordWrap(True)
        how.setStyleSheet("color: gray")
        self.bar = QProgressBar()
        self.bar.setVisible(False)
        self.status = QLabel("")
        self.status.setWordWrap(True)
        self.go = QPushButton("Convert")
        self.go.setDefault(True)
        self.go.setEnabled(False)
        self.go.clicked.connect(self.start)
        self.cancel = QPushButton("Cancel")
        self.cancel.clicked.connect(self._cancel)

        lay = QVBoxLayout(self)
        lay.addWidget(self.head)
        lay.addWidget(self.deep)
        lay.addWidget(self.to_trash)
        lay.addWidget(how)
        lay.addWidget(self.bar)
        lay.addWidget(self.status)
        row = QHBoxLayout()
        row.addStretch(1)
        row.addWidget(self.cancel)
        row.addWidget(self.go)
        lay.addLayout(row)
        threading.Thread(target=self._count, daemon=True).start()

    def _get(self, key: str, default: bool) -> bool:
        if self.settings is None:
            return default
        return str(self.settings.value(f"webp/{key}", "true" if default else "false")) == "true"

    def _set(self, key: str, on: bool) -> None:
        if self.settings is not None:
            self.settings.setValue(f"webp/{key}", "true" if on else "false")

    def _count(self) -> None:
        here = wc.webps_in(self.paths, recursive=False)
        self.bridge.call.emit(self._counted, (False, here))
        if any(os.path.isdir(p) for p in self.paths):
            self.bridge.call.emit(self._counted, (True, wc.webps_in(self.paths, recursive=True)))

    def _counted(self, value) -> None:
        deep, found = value
        self.found[deep] = found
        self._count_label()

    def webps(self) -> list[str]:
        return self.found.get(self.deep.isChecked() and self.deep.isVisible(), [])

    def _count_label(self) -> None:
        if self.running:
            return
        folders = [p for p in self.paths if os.path.isdir(p)]
        where = f"“{os.path.basename(folders[0].rstrip('/'))}”" if len(folders) == 1 and len(self.paths) == 1 else \
            "the selection"
        here = self.found.get(False)
        if here is None:
            return
        deep = self.found.get(True)
        n = len(here)
        text = f"{n:,} WebP photo{'s' if n != 1 else ''} in {where}"
        if folders:
            text += (" — looking in its subfolders…" if deep is None else
                     f", and {len(deep) - n:,} more in its subfolders." if len(deep) > n else
                     " (none in its subfolders).")
        self.head.setText(text)
        self.go.setEnabled(bool(self.webps()))
        if not self.webps():
            self.status.setText("Nothing to convert" + (" — tick Include subfolders?" if deep and len(deep) > n and
                                                        not self.deep.isChecked() else "."))
        else:
            self.status.setText("")

    def start(self) -> None:
        webps = self.webps()
        if not webps or self.running:
            return
        self.running = True
        moved = self.to_trash.isChecked()
        for w in (self.go, self.deep, self.to_trash):
            w.setEnabled(False)
        self.cancel.setText("Stop")
        self.bar.setVisible(True)
        self.bar.setRange(0, len(webps))
        self.bar.setValue(0)

        def work() -> None:
            result = wc.convert(webps, trash=self.trash if moved else None,
                                progress=lambda i, n, p: self.bridge.call.emit(self._progress, (i, n, p)),
                                cancelled=lambda: self.stopping)
            self.bridge.call.emit(self._finished, (result, moved))
        threading.Thread(target=work, daemon=True, name="webp-convert").start()

    def _progress(self, value) -> None:
        i, n, path = value
        self.bar.setValue(i)
        self.status.setText(f"{i:,} of {n:,} — {os.path.basename(path)}")

    def _finished(self, value) -> None:
        result, moved = value
        self.running = False
        self.bar.setVisible(False)
        self.cancel.setText("Close")
        self.done(result, moved)
        n = len(result.converted)
        text = f"Made {n:,} JPEG{'s' if n != 1 else ''}"
        if moved and result.trashed:
            text += f"; {len(result.trashed):,} WebP original{'s' if len(result.trashed) != 1 else ''} in the Trash"
        if result.untrashed:
            text += (f"; {len(result.untrashed):,} original{'s' if len(result.untrashed) != 1 else ''} couldn't go to "
                     "the Trash and stay beside their JPEGs")
        if result.animated:
            text += f"; {len(result.animated):,} animated left as they are"
        if result.failed:
            text += f"; {len(result.failed):,} couldn't be ({result.failed[0][1]})"
        if result.stopped:
            text += " — stopped"
        self.status.setText(text + ".")

    def _cancel(self) -> None:
        if self.running:
            self.stopping = True
            self.status.setText("Stopping after the photos in hand…")
        else:
            self.close()
