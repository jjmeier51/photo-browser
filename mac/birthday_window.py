"""Folder birthdays in Photo Browser for Mac — the windows (birthdays.py keeps them, shared with the iPhone).

- `BirthdayDialog`: right-click a folder ▸ Set Birthday… — a calendar (with the year and month to jump with),
  Save, and Remove Birthday when there is one. The iPhone app's Folder Birthday screen.
- `BirthdaysWindow`: Go ▸ Folder Birthdays… — every folder with a birthday on the connected drives (and this
  Mac), its birthday and its age today; change one, remove one, or show the folder. The iPhone app's Folder
  Birthdays list.
"""
from __future__ import annotations

import os
from datetime import date, datetime
from typing import Callable

from PySide6.QtCore import QDate, Qt
from PySide6.QtWidgets import (QAbstractItemView, QCalendarWidget, QDialog, QDialogButtonBox, QHBoxLayout, QLabel,
                               QPushButton, QTreeWidget, QTreeWidgetItem, QVBoxLayout)

import birthdays as bd


def pretty(ts: float) -> str:
    return datetime.fromtimestamp(ts).strftime("%-d %B %Y")


def age_now(ts: float) -> str:
    years = bd.years_between(ts, datetime.now().timestamp())
    return "" if years is None else f"{years}"


class BirthdayDialog(QDialog):
    """`on_save(folder, birthday | None)` — None removes it."""

    def __init__(self, parent, folder: str, current: float | None, on_save: Callable[[str, float | None], None]) -> None:
        super().__init__(parent)
        self.folder, self.on_save = folder, on_save
        name = os.path.basename(folder.rstrip("/")) or folder
        self.setWindowTitle("Folder Birthday")
        lay = QVBoxLayout(self)
        head = QLabel(f"<b>{name}</b>")
        lay.addWidget(head)
        self.cal = QCalendarWidget()
        self.cal.setGridVisible(False)
        self.cal.setMaximumDate(QDate.currentDate())
        self.cal.setMinimumDate(QDate(1900, 1, 1))
        start = datetime.fromtimestamp(current).date() if current else date(date.today().year - 25, 1, 1)
        self.cal.setSelectedDate(QDate(start.year, start.month, start.day))
        lay.addWidget(self.cal)
        note = QLabel(f"Photos and videos in “{name}” and its folders show an Age from this date and when each was "
                      "taken — here and in the iPhone app (it's kept on the drive).")
        note.setWordWrap(True)
        note.setObjectName("SheetSub")
        lay.addWidget(note)
        buttons = QDialogButtonBox(QDialogButtonBox.StandardButton.Save | QDialogButtonBox.StandardButton.Cancel)
        if current:
            remove = buttons.addButton("Remove Birthday", QDialogButtonBox.ButtonRole.DestructiveRole)
            remove.clicked.connect(self._remove)
        buttons.accepted.connect(self._save)
        buttons.rejected.connect(self.reject)
        lay.addWidget(buttons)

    def chosen(self) -> date:
        d = self.cal.selectedDate()
        return date(d.year(), d.month(), d.day())

    def _save(self) -> None:
        self.on_save(self.folder, bd.noon(self.chosen()))
        self.accept()

    def _remove(self) -> None:
        self.on_save(self.folder, None)
        self.accept()


class BirthdaysWindow(QDialog):
    """`roots()` → the folders to look in (the drives connected); `change(folder)` opens BirthdayDialog;
    `remove(folder)`; `show(folder)` goes there in the main window."""

    def __init__(self, parent, store: bd.Birthdays, roots: Callable[[], list[str]], change: Callable[[str], None],
                 remove: Callable[[str], None], show: Callable[[str], None]) -> None:
        super().__init__(parent)
        self.store, self.roots, self.change, self.remove, self.show_folder = store, roots, change, remove, show
        self.setWindowTitle("Folder Birthdays")
        self.resize(720, 460)
        lay = QVBoxLayout(self)
        intro = QLabel("Folders with a birthday — their photos and videos show an Age. Shared with the iPhone app "
                       "through the drive. Right-click a folder ▸ Set Birthday… to add one.")
        intro.setWordWrap(True)
        lay.addWidget(intro)
        self.list = QTreeWidget()
        self.list.setHeaderLabels(["Folder", "Birthday", "Age today"])
        self.list.setRootIsDecorated(False)
        self.list.setSelectionMode(QAbstractItemView.SelectionMode.SingleSelection)
        self.list.setColumnWidth(0, 380)
        self.list.setColumnWidth(1, 170)
        self.list.itemDoubleClicked.connect(lambda it, _c: self._go(it))
        self.list.itemSelectionChanged.connect(self._selected)
        lay.addWidget(self.list, 1)
        self.empty = QLabel("No folder has a birthday yet.")
        self.empty.setAlignment(Qt.AlignmentFlag.AlignCenter)
        lay.addWidget(self.empty)
        row = QHBoxLayout()
        self.show_btn = QPushButton("Show Folder")
        self.show_btn.clicked.connect(lambda: self._go(self.list.currentItem()))
        self.change_btn = QPushButton("Change…")
        self.change_btn.clicked.connect(lambda: self._act(self.change))
        self.remove_btn = QPushButton("Remove")
        self.remove_btn.clicked.connect(lambda: self._act(self.remove))
        done = QPushButton("Done")
        done.setDefault(True)
        done.clicked.connect(self.accept)
        for w in (self.show_btn, self.change_btn, self.remove_btn):
            row.addWidget(w)
        row.addStretch(1)
        row.addWidget(done)
        lay.addLayout(row)
        self.reload()

    def reload(self) -> None:
        self.list.clear()
        found = self.store.every(self.roots())
        for folder, ts in found:
            it = QTreeWidgetItem([folder, pretty(ts), age_now(ts)])
            it.setData(0, Qt.ItemDataRole.UserRole, folder)
            it.setToolTip(0, folder)
            self.list.addTopLevelItem(it)
        self.empty.setVisible(not found)
        self.list.setVisible(bool(found))
        self._selected()

    def _selected(self) -> None:
        on = self.list.currentItem() is not None
        for b in (self.show_btn, self.change_btn, self.remove_btn):
            b.setEnabled(on)

    def _act(self, fn: Callable[[str], None]) -> None:
        it = self.list.currentItem()
        if it is not None:
            fn(it.data(0, Qt.ItemDataRole.UserRole))
            self.reload()

    def _go(self, it) -> None:
        if it is not None:
            self.show_folder(it.data(0, Qt.ItemDataRole.UserRole))
