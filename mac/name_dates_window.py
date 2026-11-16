"""Set Dates from File Names… / Restore Capture Dates… — the window (name_dates.py does the work).

Right-click photos, videos or folders ▸ Set Dates from File Names… (Photos menu too). The window lists every
photo and video — inside the folders as well — with the date found for it and where it came from, before anything
is changed; Apply sets them. The list is read on a worker thread (ExifTool reads the dates inside, when it's
installed), and so is the setting; the window says how far it has got, and Stop is honoured between files.
"""
from __future__ import annotations

import os
import threading
import time
from datetime import datetime
from typing import Callable

from PySide6.QtCore import QObject, Qt, QTimer, Signal
from PySide6.QtWidgets import (QAbstractItemView, QButtonGroup, QComboBox, QDialog, QHBoxLayout, QLabel, QLineEdit,
                               QProgressBar, QPushButton, QRadioButton, QTreeWidget, QTreeWidgetItem, QVBoxLayout)

import name_dates as nd
import simpcity as sc

SHOWN = 2000                                    # rows listed at most (the rest are counted)
EMBEDS = [("never", "Only the file's own dates (created and modified)"),
          ("missing", "Also as the capture date inside — where there isn't one"),
          ("always", "Also as the capture date inside — always")]


class _Sig(QObject):
    found = Signal(object, int)                 # (list of Found, generation)
    progress = Signal(str)
    done = Signal(object)                       # name_dates.Done


def _when(d: datetime | None) -> str:
    return d.strftime("%-d %b %Y, %H:%M:%S") if d else "—"


class NameDatesDialog(QDialog):
    """`on_done(done, restore)` runs on the UI thread after Apply (name_dates.Done, which mode)."""

    def __init__(self, parent, paths: list[str], settings, on_done: Callable, restore: bool = False) -> None:
        super().__init__(parent)
        self.paths, self.settings, self.on_done = list(paths), settings, on_done
        self.found: list[nd.Found] = []
        self.working = False
        self.stopping = False
        self.generation = 0
        self.sig = _Sig()
        self.sig.found.connect(self._found)
        self.sig.progress.connect(lambda t: self.status.setText(t))
        self.sig.done.connect(self._applied)
        self.tool_path = sc.find_exiftool()
        self.setWindowTitle("Set Dates from File Names")
        self.resize(900, 620)

        lay = QVBoxLayout(self)
        head = QLabel("Each photo and video gets the date in its name — “johnmeier_2026_11_16_4398yr.mp4” is 16 November "
                      "2026 (noon, when the name has no time) — as its own created and modified date.")
        head.setWordWrap(True)
        lay.addWidget(head)
        modes = QHBoxLayout()
        self.by_name = QRadioButton("Dates from file names")
        self.by_name.setToolTip("Only files whose name holds a date")
        self.restore = QRadioButton("Restore capture dates")
        self.restore.setToolTip("The iPhone app's Restore Capture Dates: the date in the name first, else the date "
                                "inside the photo or video — for files a copy or an import stamped with “now”")
        group = QButtonGroup(self)
        for b in (self.by_name, self.restore):
            group.addButton(b)
            modes.addWidget(b)
        modes.addStretch(1)
        lay.addLayout(modes)
        row = QHBoxLayout()
        row.addWidget(QLabel("Set:"))
        self.embed = QComboBox()
        for key, text in EMBEDS:
            self.embed.addItem(text, key)
        row.addWidget(self.embed, 1)
        lay.addLayout(row)
        prow = QHBoxLayout()
        prow.addWidget(QLabel("Names like:"))
        self.pattern = QLineEdit()
        self.pattern.setPlaceholderText("the usual ones — or a pattern such as  name_%Y_%m_%d  (%Y %m %d %H %M %S)")
        self.pattern.setToolTip("Leave empty for: name_2026_11_16_…, IMG_20240613_101530, PXL_…, VID-20240613-WA0001, "
                                "“Screenshot 2024-06-13 at 10.15.30”, 2024-06-13 10.15.30, a Unix time")
        prow.addWidget(self.pattern, 1)
        lay.addLayout(prow)
        self.no_tool = QLabel("ExifTool isn't installed, so only the date in a name can be used, and only the file's own "
                              "dates set (install it with: brew install exiftool).")
        self.no_tool.setWordWrap(True)
        self.no_tool.setVisible(not self.tool_path)
        lay.addWidget(self.no_tool)

        self.list = QTreeWidget()
        self.list.setHeaderLabels(["Name", "Date found", "From", "File date now"])
        self.list.setRootIsDecorated(False)
        self.list.setUniformRowHeights(True)
        self.list.setSelectionMode(QAbstractItemView.SelectionMode.NoSelection)
        self.list.setColumnWidth(0, 360)
        self.list.setColumnWidth(1, 190)
        self.list.setColumnWidth(2, 120)
        lay.addWidget(self.list, 1)
        self.status = QLabel("Looking…")
        self.status.setWordWrap(True)
        self.bar = QProgressBar()
        self.bar.setRange(0, 0)
        self.bar.setFixedWidth(200)
        bottom = QHBoxLayout()
        bottom.addWidget(self.status, 1)
        bottom.addWidget(self.bar)
        self.cancel = QPushButton("Cancel")
        self.cancel.clicked.connect(self._cancel)
        self.apply_btn = QPushButton("Set Dates")
        self.apply_btn.setObjectName("Primary")
        self.apply_btn.setDefault(True)
        self.apply_btn.setEnabled(False)
        self.apply_btn.clicked.connect(self.apply)
        bottom.addWidget(self.cancel)
        bottom.addWidget(self.apply_btn)
        lay.addLayout(bottom)

        (self.restore if restore else self.by_name).setChecked(True)
        self._mode_defaults()
        self.later = QTimer(self)
        self.later.setSingleShot(True)
        self.later.setInterval(450)
        self.later.timeout.connect(self.look)
        self.by_name.toggled.connect(lambda _on: (self._mode_defaults(), self.look()))
        self.embed.currentIndexChanged.connect(lambda _i: self.look())
        self.pattern.textChanged.connect(lambda _t: self.later.start())
        self.look()

    # ------------------------------------------------------------------ the list
    def _mode_defaults(self) -> None:
        """Restore sets only the file's own dates by default (the iPhone's does); names also give a capture date to a
        file without one. Without ExifTool, file dates are all there is."""
        key = self.settings.value("namedates/embed_restore" if self.restore.isChecked() else "namedates/embed",
                                  "never" if self.restore.isChecked() else "missing")
        if not self.tool_path:
            key = "never"
        self.embed.blockSignals(True)
        self.embed.setCurrentIndex(max(0, [k for k, _t in EMBEDS].index(key) if key in [k for k, _t in EMBEDS] else 0))
        self.embed.setEnabled(bool(self.tool_path))
        self.embed.blockSignals(False)
        self.setWindowTitle("Restore Capture Dates" if self.restore.isChecked() else "Set Dates from File Names")
        self.apply_btn.setText("Restore Dates" if self.restore.isChecked() else "Set Dates")

    def look(self) -> None:
        if self.working:
            return
        self.generation += 1
        gen = self.generation
        restore, embed, pattern = self.restore.isChecked(), self.embed.currentData(), self.pattern.text().strip()
        self.settings.setValue("namedates/embed_restore" if restore else "namedates/embed", embed)
        self.apply_btn.setEnabled(False)
        self.bar.setRange(0, 0)
        self.bar.show()
        self.status.setText("Looking…")
        paths, tool_path, sig = self.paths, self.tool_path, self.sig

        def work() -> None:
            tool = sc.ExifSession(tool_path) if tool_path and (restore or embed != "never") else None
            try:
                found = nd.find(paths, restore, embed, pattern, tool, stop=lambda: gen != self.generation,
                                progress=lambda n, total: sig.progress.emit(f"Reading {n:,} of {total:,}…"))
            except Exception as e:  # noqa: BLE001 — said, never a crash
                found = []
                sig.progress.emit(f"Couldn't read the files: {type(e).__name__}: {e}")
            finally:
                if tool is not None:
                    tool.close()
            sig.found.emit(found, gen)
        threading.Thread(target=work, daemon=True, name="name-dates").start()

    def _found(self, found: list, gen: int) -> None:
        if gen != self.generation or self.working:
            return
        self.found = found
        self.bar.hide()
        self.list.clear()
        rows = []
        for f in found[:SHOWN]:
            it = QTreeWidgetItem([os.path.relpath(f.path, self.paths[0]) if len(self.paths) == 1 and
                                  os.path.isdir(self.paths[0]) else os.path.basename(f.path),
                                  _when(f.when), {"name": "the name", "inside": "inside the file"}.get(f.source, ""),
                                  datetime.fromtimestamp(f.file_date).strftime("%-d %b %Y, %H:%M:%S")])
            it.setToolTip(0, f.path)
            if f.when is None:
                for c in range(4):
                    it.setForeground(c, self.palette().placeholderText())
                it.setText(1, "no date in its name" if not self.restore.isChecked() else "no date found")
            elif not f.changes:
                it.setText(2, it.text(2) + " — already")
            elif f.embed:
                it.setText(2, it.text(2) + " + inside")
            rows.append(it)
        self.list.addTopLevelItems(rows)
        todo = [f for f in found if f.changes]
        dated = [f for f in found if f.when is not None]
        if not found:
            self.status.setText("There are no photos or videos here.")
        else:
            line = f"{len(todo):,} of {len(found):,} will change"
            if len(dated) - len(todo):
                line += f" · {len(dated) - len(todo):,} already have that date"
            if len(found) - len(dated):
                line += f" · {len(found) - len(dated):,} have no date" + ("" if self.restore.isChecked() else " in their name")
            embeds = sum(1 for f in todo if f.embed)
            if embeds:
                line += f" · {embeds:,} also get it as the capture date inside"
            if len(found) > SHOWN:
                line += f" (the first {SHOWN:,} are listed)"
            self.status.setText(line + ".")
        self.apply_btn.setEnabled(bool(todo))

    # ------------------------------------------------------------------ doing it
    def apply(self) -> None:
        todo = [f for f in self.found if f.changes]
        if self.working or not todo:
            return
        self.working, self.stopping = True, False
        self.apply_btn.setEnabled(False)
        for w in (self.by_name, self.restore, self.embed, self.pattern):
            w.setEnabled(False)
        self.cancel.setText("Stop")
        self.bar.setRange(0, 0)
        self.bar.show()
        found, tool_path, sig = list(self.found), self.tool_path, self.sig
        needs_tool = any(f.embed for f in found)
        self.started = time.monotonic()

        def work() -> None:
            tool = sc.ExifSession(tool_path) if tool_path and needs_tool else None
            done = nd.Done()
            try:
                done = nd.apply(found, tool, stop=lambda: self.stopping,
                                progress=lambda n, total: sig.progress.emit(f"Setting dates… {n:,} of {total:,}"))
            except Exception as e:  # noqa: BLE001 — the sheet must hear the end
                done.failed.append(("", f"{type(e).__name__}: {e}"))
            finally:
                if tool is not None:
                    tool.close()
                sig.done.emit(done)
        threading.Thread(target=work, daemon=True, name="name-dates-apply").start()

    def _applied(self, done) -> None:
        self.working = False
        restore = self.restore.isChecked()
        self.on_done(done, restore)
        self.accept()

    def _cancel(self) -> None:
        if self.working:
            self.stopping = True
            self.cancel.setEnabled(False)
            self.status.setText("Stopping after the file in hand…")
        else:
            self.generation += 1
            self.reject()

    def reject(self) -> None:
        if self.working:
            self._cancel()
            return
        self.generation += 1
        super().reject()
