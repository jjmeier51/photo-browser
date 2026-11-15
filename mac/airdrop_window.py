"""Photo Browser for Mac's Receive from iPhone window, and the watcher that notices AirDrops
(airdrop_receive.py does the finding and the moving).

File ▸ Receive from iPhone… (⇧⌘I): the photos and videos AirDropped to this Mac — they land in Downloads —
listed newest first, all ticked; **Move to “From iPhone”** copies them onto the drive, checks each copy
against its original, and puts the originals in the Mac's Trash (or leaves them, as chosen). The folder is
the drive's existing "From iPhone" (found by name, remembered; Change… picks another; when the drive has none
the window offers to make it).

**Watch for AirDrops** (ticked by default): while the app is open, `Watcher` notices new arrivals and says so
in a toast with a **Move to “From iPhone”** button — or, with **Move them without asking**, just moves them and
says what it did.
"""
from __future__ import annotations

import os
import threading
import time
from typing import Callable

from PySide6.QtCore import QFileSystemWatcher, QObject, Qt, QTimer, Signal
from PySide6.QtWidgets import (QCheckBox, QDialog, QFileDialog, QHBoxLayout, QLabel, QListWidget, QListWidgetItem,
                               QMessageBox, QProgressBar, QPushButton, QRadioButton, QVBoxLayout, QWidget)

import airdrop_receive as ar

WATCH_KEY, AUTO_KEY, DEST_KEY, AFTER_KEY = "airdrop/watch", "airdrop/auto", "airdrop/dest", "airdrop/after"


def _on(settings, key: str, default: bool) -> bool:
    return str(settings.value(key, "true" if default else "false")).lower() == "true"


def _size(n: int) -> str:
    return f"{n / 1e9:.2f} GB" if n >= 1e9 else f"{n / 1e6:.1f} MB" if n >= 1e6 else f"{max(1, n // 1000)} KB"


class Hooks:
    """What the window needs from the app."""

    def __init__(self, drive: Callable[[], str], trash: Callable[[str], bool], make_folder: Callable[[str], None],
                 done: Callable[[ar.Result, str], None], here: Callable[[], str] = lambda: "") -> None:
        self.drive, self.trash, self.make_folder, self.done, self.here = drive, trash, make_folder, done, here


def destination(settings, drive: str, near: str = "") -> str | None:
    """The "From iPhone" folder to use (remembered, else found near here or on the drive), remembered once found."""
    found = ar.find_destination(drive, str(settings.value(DEST_KEY, "") or ""), near=near)
    if found:
        settings.setValue(DEST_KEY, found)
    return found


class _Signals(QObject):
    progress = Signal(int, int, str)
    done = Signal(object)
    found = Signal(object)


def run_receive(paths: list[str], dest: str, settings, hooks: Hooks, sig: _Signals, stop: threading.Event) -> None:
    after = "keep" if str(settings.value(AFTER_KEY, "trash")) == "keep" else "trash"

    def work() -> None:
        res = ar.receive(paths, dest, after=after, trash=hooks.trash, progress=sig.progress.emit, stop=stop.is_set)
        sig.done.emit(res)
    threading.Thread(target=work, daemon=True).start()


class ReceiveWindow(QDialog):
    def __init__(self, parent: QWidget | None, settings, hooks: Hooks) -> None:
        super().__init__(parent)
        self.settings, self.hooks = settings, hooks
        self.running = False
        self._stop = threading.Event()
        self._sig = _Signals()
        self._sig.progress.connect(self._progress)
        self._sig.done.connect(self._done)
        self.setWindowTitle("Receive from iPhone")
        self.setMinimumSize(640, 540)
        lay = QVBoxLayout(self)
        lay.setContentsMargins(20, 18, 20, 16)
        lay.setSpacing(9)
        lay.addWidget(QLabel("Receive from iPhone", objectName="SheetTitle"))
        sub = QLabel("AirDrop photos and videos from the iPhone to this Mac — they arrive in Downloads — then move "
                     "them onto the drive from here. Each copy is checked against its original before the original goes.",
                     objectName="SheetSub")
        sub.setWordWrap(True)
        lay.addWidget(sub)
        row = QHBoxLayout()
        self.dest_label = QLabel("")
        self.dest_label.setWordWrap(True)
        row.addWidget(self.dest_label, 1)
        self.make_btn = self._button("Make “From iPhone”", self._make)
        row.addWidget(self.make_btn)
        row.addWidget(self._button("Change…", self._choose))
        lay.addLayout(row)
        self.list = QListWidget()
        self.list.setAlternatingRowColors(True)
        self.list.itemChanged.connect(lambda _i: self._buttons())
        lay.addWidget(self.list, 1)
        row = QHBoxLayout()
        self.everything = QCheckBox("Show every photo and video in Downloads, not only AirDrops")
        self.everything.toggled.connect(lambda _on: self.refresh())
        row.addWidget(self.everything, 1)
        row.addWidget(self._button("All", lambda: self._tick(True)))
        row.addWidget(self._button("None", lambda: self._tick(False)))
        row.addWidget(self._button("Refresh", self.refresh))
        lay.addLayout(row)
        self.trash_after = QRadioButton("Afterwards, move the originals to the Trash")
        self.keep_after = QRadioButton("Leave the originals in Downloads")
        (self.keep_after if str(settings.value(AFTER_KEY, "trash")) == "keep" else self.trash_after).setChecked(True)
        self.trash_after.toggled.connect(lambda on: settings.setValue(AFTER_KEY, "trash" if on else "keep"))
        lay.addWidget(self.trash_after)
        lay.addWidget(self.keep_after)
        self.watch = QCheckBox("Watch for AirDrops while the app is open, and offer to move them")
        self.watch.setChecked(_on(settings, WATCH_KEY, True))
        self.watch.toggled.connect(lambda on: (settings.setValue(WATCH_KEY, "true" if on else "false"), self._buttons()))
        self.auto = QCheckBox("Move them without asking")
        self.auto.setChecked(_on(settings, AUTO_KEY, False))
        self.auto.toggled.connect(lambda on: settings.setValue(AUTO_KEY, "true" if on else "false"))
        lay.addWidget(self.watch)
        lay.addWidget(self.auto)
        self.note = QLabel("", objectName="SheetSub")
        self.note.setWordWrap(True)
        lay.addWidget(self.note)
        self.bar = QProgressBar()
        self.bar.setTextVisible(False)
        self.bar.hide()
        lay.addWidget(self.bar)
        row = QHBoxLayout()
        row.addStretch(1)
        self.close_btn = self._button("Close", self.reject)
        self.go = QPushButton("Move", objectName="Primary")
        self.go.setAutoDefault(False)
        self.go.clicked.connect(self.start)
        row.addWidget(self.close_btn)
        row.addWidget(self.go)
        lay.addLayout(row)
        self.dest: str | None = destination(settings, hooks.drive(), hooks.here())
        self.refresh()

    def _button(self, text: str, slot) -> QPushButton:
        b = QPushButton(text)
        b.setAutoDefault(False)
        b.clicked.connect(slot)
        return b

    # ------------------------------------------------------------------ the folder
    def _show_dest(self) -> None:
        drive = self.hooks.drive()
        if self.dest:
            self.dest_label.setText(f"Into  <b>{os.path.basename(self.dest.rstrip(os.sep))}</b>  —  {self.dest}")
        elif drive:
            self.dest_label.setText(f"There's no “{ar.FOLDER_NAME}” folder on {os.path.basename(drive.rstrip(os.sep)) or drive} yet.")
        else:
            self.dest_label.setText("No drive is open. Choose the folder to receive into.")
        self.make_btn.setVisible(not self.dest and bool(drive))

    def _choose(self) -> None:
        start = self.dest or self.hooks.drive() or ""
        picked = QFileDialog.getExistingDirectory(self, "Receive Into", start)
        if picked:
            self.dest = picked
            self.settings.setValue(DEST_KEY, picked)
            self._buttons()

    def _make(self) -> None:
        drive = self.hooks.drive()
        if not drive:
            return
        target = os.path.join(drive, ar.FOLDER_NAME)
        try:
            if not os.path.isdir(target):
                self.hooks.make_folder(target)
        except OSError as e:
            QMessageBox.warning(self, "Receive from iPhone", f"Couldn't make the folder: {e}")
            return
        self.dest = target
        self.settings.setValue(DEST_KEY, target)
        self._buttons()

    # ------------------------------------------------------------------ the list
    def refresh(self) -> None:
        if self.running:
            return
        found = ar.find(only_airdrop=not self.everything.isChecked())
        self.list.blockSignals(True)
        self.list.clear()
        for a in found:
            when = time.strftime("%-d %b, %H:%M", time.localtime(a.when))
            bits = [a.kind.capitalize(), _size(a.size), when] + ([f"from {a.sender}"] if a.sender else []) \
                + ([] if a.airdrop else ["not an AirDrop"])
            item = QListWidgetItem(f"{a.name}\n" + "  ·  ".join(bits))
            item.setData(Qt.ItemDataRole.UserRole, a.path)
            item.setFlags(item.flags() | Qt.ItemFlag.ItemIsUserCheckable)
            item.setCheckState(Qt.CheckState.Checked if a.airdrop or not self.everything.isChecked() else Qt.CheckState.Unchecked)
            self.list.addItem(item)
        self.list.blockSignals(False)
        if not found:
            where = str(ar.downloads())
            self.note.setText(("No AirDropped photos or videos are waiting in Downloads. On the iPhone: select them in "
                               "Photos ▸ Share ▸ AirDrop ▸ this Mac. " if not self.everything.isChecked() else
                               "There are no photos or videos in Downloads. ") +
                              (f"(If macOS asked whether this app may read Downloads and the answer was no, allow it in "
                               f"System Settings ▸ Privacy & Security ▸ Files and Folders.)" if os.path.isdir(where) else ""))
        else:
            self.note.setText("")
        self._buttons()

    def checked(self) -> list[str]:
        return [self.list.item(i).data(Qt.ItemDataRole.UserRole) for i in range(self.list.count())
                if self.list.item(i).checkState() == Qt.CheckState.Checked]

    def _tick(self, on: bool) -> None:
        self.list.blockSignals(True)
        for i in range(self.list.count()):
            self.list.item(i).setCheckState(Qt.CheckState.Checked if on else Qt.CheckState.Unchecked)
        self.list.blockSignals(False)
        self._buttons()

    def _buttons(self) -> None:
        n = len(self.checked())
        idle = not self.running
        self._show_dest()
        name = os.path.basename((self.dest or ar.FOLDER_NAME).rstrip(os.sep))
        self.go.setText(f"Move {n:,} to “{name}”" if n else f"Move to “{name}”")
        self.go.setEnabled(idle and n > 0 and bool(self.dest))
        self.auto.setEnabled(self.watch.isChecked())
        self.close_btn.setText("Close" if idle else "Stop")
        for w in (self.list, self.everything, self.trash_after, self.keep_after):
            w.setEnabled(idle)

    # ------------------------------------------------------------------ the run
    def start(self) -> None:
        paths = self.checked()
        if not paths or not self.dest or self.running:
            return
        if not os.path.isdir(self.dest):
            QMessageBox.warning(self, "Receive from iPhone", f"“{self.dest}” isn't there — is the drive connected?")
            return
        self.running = True
        self._stop.clear()
        self.bar.setRange(0, len(paths))
        self.bar.setValue(0)
        self.bar.show()
        self._buttons()
        run_receive(paths, self.dest, self.settings, self.hooks, self._sig, self._stop)

    def _progress(self, i: int, n: int, name: str) -> None:
        self.bar.setValue(i)
        if name:
            self.note.setText(f"Moving {i + 1:,} of {n:,} — {name}")

    def _done(self, res: ar.Result) -> None:
        self.running = False
        self.bar.hide()
        dest = self.dest or ""
        self.hooks.done(res, dest)
        failed = res.of("failed")
        if failed:
            QMessageBox.warning(self, "Receive from iPhone", "These couldn't be moved (they're still in Downloads):\n\n" +
                                "\n".join(f"{os.path.basename(m.src)} — {m.why}" for m in failed[:12]))
            self.refresh()
            return
        if res.of("stopped"):
            self.refresh()
            return
        self.accept()

    def reject(self) -> None:
        if self.running:
            self._stop.set()
            self.note.setText("Stopping after this file…")
            return
        super().reject()

    def closeEvent(self, event) -> None:  # noqa: N802
        if self.running:
            self._stop.set()
            event.ignore()
            return
        event.accept()


class Watcher(QObject):
    """Notices photos and videos AirDropped while the app is open. `arrived(paths)` is emitted once they've
    all landed (a few seconds after the last change in Downloads); files seen before aren't announced again."""
    arrived = Signal(object)

    def __init__(self, parent: QObject, settings) -> None:
        super().__init__(parent)
        self.settings = settings
        self.started = time.time() - 5
        self.seen: set[str] = set()
        self._fs = QFileSystemWatcher(self)
        self._fs.directoryChanged.connect(lambda _p: self._soon.start())
        self._soon = QTimer(self)
        self._soon.setSingleShot(True)
        self._soon.setInterval(int((ar.SETTLE + 1.0) * 1000))
        self._soon.timeout.connect(self.check)
        self._tick = QTimer(self)                   # a network home, a watcher that missed one: looked at anyway
        self._tick.setInterval(30_000)
        self._tick.timeout.connect(self.check)
        self.sync()

    def sync(self) -> None:
        """Starts or stops watching, as the setting says."""
        on = _on(self.settings, WATCH_KEY, True)
        folder = str(ar.downloads())
        watching = self._fs.directories()
        if on and os.path.isdir(folder):
            if folder not in watching:
                self._fs.addPath(folder)
            self._tick.start()
        else:
            if watching:
                self._fs.removePaths(watching)
            self._tick.stop()

    def check(self) -> None:
        if not _on(self.settings, WATCH_KEY, True):
            return

        def work() -> None:
            try:
                found = [a.path for a in ar.find(only_airdrop=True, since=self.started)]
            except Exception:  # noqa: BLE001
                found = []
            self._found.found.emit(found)
        if not hasattr(self, "_found"):
            self._found = _Signals()
            self._found.found.connect(self._announce)
        threading.Thread(target=work, daemon=True).start()

    def _announce(self, found: list) -> None:
        fresh = [p for p in found if p not in self.seen]
        if fresh:
            self.seen.update(fresh)
            self.arrived.emit(fresh)
