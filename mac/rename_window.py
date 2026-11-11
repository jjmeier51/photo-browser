"""Safe Finder's renaming windows (rename_tools.py does the work).

**Rename Files…** (`BulkRenameDialog`): many items renamed by a pattern — a ready-made one or your own, from
`{n}` (a number), `{name}`, `{date}` `{time}` (the capture date), `{folder}`, `{camera}`… — numbered in an order
you choose (capture date, name, file dates, size, or as they're shown), with Find/Replace on the name. Every
`now → becomes` is listed, and re-listed as you type; anything that would go wrong (a name taken by a file that
isn't being renamed) is said in red and Rename stays off. The capture dates are read once, in the background.

**Remove Leading Spaces from Names…** (`LeadingSpacesDialog`): the names that would change, listed before
anything is touched — with whether to go into subfolders.

Either way tags, Favorites and the iPhone app's own metadata follow each rename.
"""
from __future__ import annotations

import os
import threading
from typing import Callable

import time

from PySide6.QtCore import QObject, Qt, QTimer, Signal
from PySide6.QtGui import QColor
from PySide6.QtWidgets import (QCheckBox, QComboBox, QDialog, QFormLayout, QHBoxLayout, QHeaderView, QLabel, QLineEdit,
                               QPlainTextEdit, QProgressBar, QPushButton, QSpinBox, QTreeWidget, QTreeWidgetItem,
                               QVBoxLayout, QWidget)

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


class _BulkBridge(QObject):
    read = Signal(int, int)                 # capture dates read so far, of how many
    ready = Signal(object)                  # [Facts]
    progress = Signal(int, int)
    finished = Signal(object)


DIGITS = [(0, "1, 2, 3 …"), (2, "01, 02, 03 …"), (3, "001, 002 …"), (4, "0001, 0002 …"), (-1, "As many digits as it takes")]


class BulkRenameDialog(QDialog):
    """`done(result)` is called with the rename_tools.Result once the renames are made."""

    def __init__(self, parent, paths: list[str], tags, done: Callable[[rt.Result], None], settings=None) -> None:
        super().__init__(parent)
        self.paths, self.tags, self.done_cb, self.settings = list(paths), tags, done, settings
        self.items: list[rt.Facts] = []
        self.plan: rt.BulkPlan | None = None
        self.working = self.stopping = False
        self.bridge = _BulkBridge()
        self.bridge.read.connect(lambda d, t: self.status.setText(f"Reading the capture dates… {d:,} of {t:,}"))
        self.bridge.ready.connect(self._ready)
        self.bridge.progress.connect(self._progress)
        self.bridge.finished.connect(self._finished)
        n = len(self.paths)
        self.setWindowTitle(f"Rename {n:,} Items")
        self.resize(820, 640)

        def saved(key: str, default: str) -> str:
            return str(settings.value(f"bulkRename/{key}", default)) if settings is not None else default

        self.preset = QComboBox()
        for label, pattern in rt.PRESETS:
            self.preset.addItem(label, pattern)
        self.preset.addItem("My own pattern", "")
        self.pattern = QLineEdit(saved("pattern", "{n}"))
        self.pattern.setPlaceholderText("{n}")
        help_ = QLabel(rt.TOKEN_HELP)
        help_.setWordWrap(True)
        help_.setStyleSheet("color: gray; font-size: 11px;")
        self.order = QComboBox()
        for value, label in rt.ORDERS:
            self.order.addItem(label, value)
        self.order.setCurrentIndex(max(0, self.order.findData(saved("order", "capture"))))
        self.reverse = QCheckBox("Last first")
        self.reverse.setToolTip("Number them the other way round: the newest (or last, or largest) is the first")
        self.reverse.setChecked(saved("reverse", "false") == "true")
        self.start = QSpinBox()
        self.start.setRange(0, 9_999_999)
        self.start.setValue(int(saved("start", "1") or 1))
        self.digits = QComboBox()
        for value, label in DIGITS:
            self.digits.addItem(label, value)
        self.digits.setCurrentIndex(max(0, self.digits.findData(int(saved("digits", "0") or 0))))
        self.find = QLineEdit()
        self.find.setPlaceholderText("Find in the name")
        self.replace = QLineEdit()
        self.replace.setPlaceholderText("Replace with")
        order_row = QWidget()
        oh = QHBoxLayout(order_row)
        oh.setContentsMargins(0, 0, 0, 0)
        oh.addWidget(self.order, 1)
        oh.addWidget(self.reverse)
        num_row = QWidget()
        nh = QHBoxLayout(num_row)
        nh.setContentsMargins(0, 0, 0, 0)
        nh.addWidget(QLabel("start at"))
        nh.addWidget(self.start)
        nh.addWidget(self.digits, 1)
        find_row = QWidget()
        fh = QHBoxLayout(find_row)
        fh.setContentsMargins(0, 0, 0, 0)
        fh.addWidget(self.find, 1)
        fh.addWidget(QLabel("→"))
        fh.addWidget(self.replace, 1)
        form = QFormLayout()
        form.addRow("Name them:", self.preset)
        form.addRow("Pattern:", self.pattern)
        form.addRow("", help_)
        form.addRow("In the order of:", order_row)
        form.addRow("Numbers:", num_row)
        form.addRow("{name}:", find_row)
        self.table = QTreeWidget()
        self.table.setColumnCount(3)
        self.table.setHeaderLabels(["Now", "Becomes", "Capture date"])
        self.table.setRootIsDecorated(False)
        self.table.setUniformRowHeights(True)
        self.table.header().setSectionResizeMode(0, QHeaderView.ResizeMode.Stretch)
        self.table.header().setSectionResizeMode(1, QHeaderView.ResizeMode.Stretch)
        self.table.header().setSectionResizeMode(2, QHeaderView.ResizeMode.ResizeToContents)
        self.status = QLabel("Reading the capture dates…")
        self.status.setWordWrap(True)
        self.bar = QProgressBar()
        self.bar.setVisible(False)
        self.go = QPushButton("Rename")
        self.go.setDefault(True)
        self.go.setEnabled(False)
        self.go.clicked.connect(self._apply)
        self.cancel = QPushButton("Cancel")
        self.cancel.clicked.connect(self._cancel)
        buttons = QHBoxLayout()
        buttons.addWidget(self.bar)
        buttons.addStretch(1)
        buttons.addWidget(self.cancel)
        buttons.addWidget(self.go)
        lay = QVBoxLayout(self)
        lay.addLayout(form)
        lay.addWidget(self.table, 1)
        lay.addWidget(self.status)
        lay.addLayout(buttons)
        self._sync_preset()
        self._later = QTimer(self)
        self._later.setSingleShot(True)
        self._later.setInterval(120)
        self._later.timeout.connect(self._replan)
        self.preset.activated.connect(self._preset_picked)
        self.pattern.textChanged.connect(lambda _t: (self._sync_preset(), self._later.start()))
        for w in (self.find, self.replace):
            w.textChanged.connect(lambda _t: self._later.start())
        self.order.currentIndexChanged.connect(lambda _i: self._replan())
        self.digits.currentIndexChanged.connect(lambda _i: self._replan())
        self.reverse.toggled.connect(lambda _on: self._replan())
        self.start.valueChanged.connect(lambda _v: self._replan())
        threading.Thread(target=self._read, daemon=True, name="rename-read").start()

    # -- the items
    def _read(self) -> None:
        out: list[rt.Facts] = []
        last = 0.0
        for i, p in enumerate(self.paths):
            if self.stopping:
                return
            try:
                out.append(rt.facts(p))
            except OSError:
                continue                                   # gone since it was selected
            if time.monotonic() - last > 0.2:
                last = time.monotonic()
                self.bridge.read.emit(i + 1, len(self.paths))
        self.bridge.ready.emit(out)

    def _ready(self, items: list) -> None:
        self.items = items
        self._replan()

    # -- the pattern
    def _preset_picked(self, index: int) -> None:
        pattern = self.preset.itemData(index)
        if pattern:
            self.pattern.setText(pattern)
        else:
            self.pattern.setFocus()
            self.pattern.selectAll()

    def _sync_preset(self) -> None:
        i = self.preset.findData(self.pattern.text())
        self.preset.setCurrentIndex(i if i >= 0 and self.pattern.text() else self.preset.count() - 1)

    def _digits(self) -> int:
        d = int(self.digits.currentData() or 0)
        if d < 0:                                          # as many as the last number needs
            return len(str(self.start.value() + max(0, len(self.items) - 1)))
        return d

    def _replan(self) -> None:
        if self.working or not self.items:
            return
        self.plan = rt.bulk_plan(self.items, self.pattern.text(), self.order.currentData(), self.reverse.isChecked(),
                                 self.start.value(), self._digits(), self.find.text(), self.replace.text())
        plan = self.plan
        self.table.setUpdatesEnabled(False)
        self.table.clear()
        red, grey = QColor("#D70015"), QColor("#8E8E93")
        for f, new, wrong in plan.rows[:3000]:
            old = os.path.basename(f.path)
            when = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(f.when)) + ("" if f.has_capture or f.is_dir else "  (file date)")
            item = QTreeWidgetItem([old, new if not wrong else f"{new} — {wrong}", when])
            if wrong:
                item.setForeground(1, red)
            elif new == old:
                item.setForeground(1, grey)
            self.table.addTopLevelItem(item)
        if len(plan.rows) > 3000:
            self.table.addTopLevelItem(QTreeWidgetItem([f"… and {len(plan.rows) - 3000:,} more", "", ""]))
        self.table.setUpdatesEnabled(True)
        n = len(plan.renames)
        lines = list(plan.problems)
        if not lines:
            same = len(plan.rows) - n
            lines.append(f"{n:,} name{'s' if n != 1 else ''} will change" + (f"; {same:,} already "
                         f"{'has its' if same == 1 else 'have their'} new name" if same else "") + "." if n
                         else "Every item already has that name.")
        if plan.no_capture:
            k = plan.no_capture
            lines.append(f"{k:,} {'has' if k == 1 else 'have'} no capture date inside — {'its' if k == 1 else 'their'} "
                         "file's date is used instead.")
        self.status.setText("  ".join(lines))
        self.status.setStyleSheet("color: #D70015;" if plan.problems else "")
        self.go.setText(f"Rename {n:,}" if n else "Rename")
        self.go.setEnabled(bool(n) and not plan.problems)

    # -- doing it
    def _apply(self) -> None:
        if self.working or self.plan is None or self.plan.problems or not self.plan.renames:
            return
        if self.settings is not None:
            for key, value in (("pattern", self.pattern.text()), ("order", self.order.currentData()),
                               ("reverse", "true" if self.reverse.isChecked() else "false"),
                               ("start", self.start.value()), ("digits", int(self.digits.currentData() or 0))):
                self.settings.setValue(f"bulkRename/{key}", value)
        self.working = True
        self.go.setEnabled(False)
        self.cancel.setText("Stop")
        self.bar.setVisible(True)
        self.bar.setRange(0, len(self.plan.renames))
        renames = list(self.plan.renames)

        def work() -> None:
            res = rt.apply_bulk(renames, self.tags, progress=lambda d, t: self.bridge.progress.emit(d, t),
                                stop=lambda: self.stopping)
            self.bridge.finished.emit(res)
        threading.Thread(target=work, daemon=True, name="bulk-rename").start()

    def _progress(self, done: int, total: int) -> None:
        self.bar.setRange(0, total)
        self.bar.setValue(done)

    def _finished(self, res: rt.Result) -> None:
        self.working = False
        self.done_cb(res)
        self.accept()

    def _cancel(self) -> None:
        self.stopping = True
        if self.working:
            self.cancel.setEnabled(False)
        else:
            self.reject()

    def reject(self) -> None:
        if self.working:
            self.stopping = True
            return
        self.stopping = True
        super().reject()
