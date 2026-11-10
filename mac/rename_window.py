"""Safe Finder's "Remove Leading Spaces from Names…" window (rename_tools.py does the work): the names that
would change, listed before anything is touched — with whether to go into subfolders — then the renames,
with tags, Favorites and the iPhone app's own metadata following each one.
"""
from __future__ import annotations

import os
import threading
from typing import Callable

from PySide6.QtCore import QObject, Qt, Signal
from PySide6.QtWidgets import (QCheckBox, QDialog, QHBoxLayout, QLabel, QPlainTextEdit, QProgressBar, QPushButton,
                               QVBoxLayout)

import rename_tools as rt

SHOWN = 400                 # names listed (the count says how many there are)


class _Bridge(QObject):
    planned = Signal(object, object, int)       # (plan, skipped, generation)
    progress = Signal(int, int)
    finished = Signal(object)


class LeadingSpacesDialog(QDialog):
    """`done(result)` is called with the rename_tools.Result once the renames are made."""

    def __init__(self, parent, folder: str, tags, done: Callable[[rt.Result], None]) -> None:
        super().__init__(parent)
        self.folder, self.tags, self.done_cb = folder, tags, done
        self.plan: list[rt.Rename] = []
        self.skipped: list[tuple[str, str]] = []
        self.generation = 0
        self.stopping = False
        self.working = False
        self.bridge = _Bridge()
        self.bridge.planned.connect(self._planned)
        self.bridge.progress.connect(self._progress)
        self.bridge.finished.connect(self._finished)
        self.setWindowTitle("Remove Leading Spaces from Names")
        self.resize(720, 520)
        self.head = QLabel(f"Looking through “{os.path.basename(folder.rstrip('/')) or folder}”…")
        self.head.setWordWrap(True)
        self.sub = QCheckBox("Include subfolders")
        self.sub.setChecked(True)
        self.sub.toggled.connect(lambda _on: self._scan())
        self.list = QPlainTextEdit()
        self.list.setReadOnly(True)
        self.list.setLineWrapMode(QPlainTextEdit.LineWrapMode.NoWrap)
        self.note = QLabel("Tags, Favorites and To AI go with each name, and the iPhone app picks the new names up "
                           "for its captions, covers and the rest the next time it opens the drive. A name is never "
                           "put over one that's taken (it gets a number instead).")
        self.note.setWordWrap(True)
        self.note.setStyleSheet("color: gray;")
        self.bar = QProgressBar()
        self.bar.setVisible(False)
        self.go = QPushButton("Rename")
        self.go.setDefault(True)
        self.go.setEnabled(False)
        self.go.clicked.connect(self._apply)
        self.cancel = QPushButton("Cancel")
        self.cancel.clicked.connect(self._cancel)
        row = QHBoxLayout()
        row.addWidget(self.sub)
        row.addStretch(1)
        row.addWidget(self.bar)
        row.addWidget(self.cancel)
        row.addWidget(self.go)
        lay = QVBoxLayout(self)
        lay.addWidget(self.head)
        lay.addWidget(self.list, 1)
        lay.addWidget(self.note)
        lay.addLayout(row)
        self._scan()

    def _scan(self) -> None:
        self.generation += 1
        gen = self.generation
        self.go.setEnabled(False)
        self.list.setPlainText("Looking…")
        recursive = self.sub.isChecked()

        def work() -> None:
            plan, skipped = rt.leading_space_plan(self.folder, recursive, stop=lambda: gen != self.generation)
            self.bridge.planned.emit(plan, skipped, gen)
        threading.Thread(target=work, daemon=True, name="leading-spaces").start()

    def _planned(self, plan, skipped, gen: int) -> None:
        if gen != self.generation or self.working:
            return
        self.plan, self.skipped = plan, skipped
        name = os.path.basename(self.folder.rstrip("/")) or self.folder
        folders = sum(1 for r in plan if r.is_dir)
        files = len(plan) - folders

        def n(count: int, word: str) -> str:
            return f"{count:,} {word}{'' if count == 1 else 's'}"
        if not plan:
            self.head.setText(f"No names in “{name}” start with a space.")
        else:
            parts = [n(files, "file")] if files else []
            if folders:
                parts.append(n(folders, "folder"))
            self.head.setText(f"{' and '.join(parts)} in “{name}” {'has a name' if len(plan) == 1 else 'have names'} "
                              "that start with a space:")
        lines = []
        for r in plan[:SHOWN]:
            where = os.path.relpath(os.path.dirname(r.old), self.folder)
            lines.append(f"“{os.path.basename(r.old)}”  →  “{os.path.basename(r.new)}”"
                         + ("" if where == "." else f"      in {where}") + ("   (folder)" if r.is_dir else ""))
        if len(plan) > SHOWN:
            lines.append(f"… and {len(plan) - SHOWN:,} more")
        for path, why in skipped[:50]:
            lines.append(f"left as it is: “{os.path.basename(path)}” — {why}")
        self.list.setPlainText("\n".join(lines))
        self.go.setText(f"Rename {len(plan):,} Name{'' if len(plan) == 1 else 's'}" if plan else "Rename")
        self.go.setEnabled(bool(plan))

    def _apply(self) -> None:
        if not self.plan or self.working:
            return
        self.working = True
        self.generation += 1                      # a scan still running is dropped
        self.go.setEnabled(False)
        self.sub.setEnabled(False)
        self.cancel.setText("Stop")
        self.bar.setVisible(True)
        self.bar.setRange(0, len(self.plan))
        plan, skipped = self.plan, self.skipped

        def work() -> None:
            res = rt.apply(plan, self.tags, progress=lambda d, t: self.bridge.progress.emit(d, t),
                           stop=lambda: self.stopping, skipped=skipped)
            self.bridge.finished.emit(res)
        threading.Thread(target=work, daemon=True, name="rename").start()

    def _progress(self, done: int, total: int) -> None:
        self.bar.setRange(0, total)
        self.bar.setValue(done)

    def _finished(self, res: rt.Result) -> None:
        self.working = False
        self.done_cb(res)
        self.accept()

    def _cancel(self) -> None:
        if self.working:
            self.stopping = True
            self.cancel.setEnabled(False)
        else:
            self.generation += 1
            self.reject()

    def reject(self) -> None:
        if self.working:
            self.stopping = True
            return
        super().reject()
