"""Clean Up — the iPhone's "Randomized Clean Up", in Photo Browser for Mac: what runs it, and its finish screen.

`cleanup.py` holds the idea and the arithmetic. Here:

- **`CleanupRun`** is one Clean Up of a folder. It gathers the folder's photos and videos off the window's thread,
  opens the viewer on them in shuffled order with its Clean Up bar (`media_viewer.Triage`: Delete · Keep ·
  Favorite, Back, Undo, how far along), keeps the answers (`cleanup.Session`), and offers the options in the bar's
  ⋯ — Include Subfolders, Random Order, Start Over.
- **`Finish`** is the one screen where anything is actually deleted: every item marked, as thumbnails, each
  ticked — untick any to keep it — and **Move N to Trash**. Or Keep Reviewing; or Not Now, which keeps the marks
  with the folder for next time.

Photo Browser hands in what it knows through `CleanupHooks`: which files are photos and videos, the viewer, the
Trash (its own, with Undo), Favorites, thumbnails, and where to say what happened.
"""
from __future__ import annotations

import os
import threading
from dataclasses import dataclass
from typing import Callable

from PySide6.QtCore import QObject, QSize, Qt, Signal
from PySide6.QtGui import QColor, QIcon, QPixmap
from PySide6.QtWidgets import (QDialog, QHBoxLayout, QLabel, QListView, QListWidget, QListWidgetItem, QMenu,
                               QPushButton, QVBoxLayout, QWidget)

import app_identity
import cleanup as C

TILE = 132


@dataclass
class CleanupHooks:
    is_media: Callable[[str], bool]
    view: Callable[[list[str], str, object], object]         # (items, start, media_viewer.Triage) → the viewer
    trash: Callable[[list[str]], list[str]]                  # → the ones that went (said, with Undo, by the app)
    is_favorite: Callable[[str], bool]
    set_favorite: Callable[[str, bool], None]
    thumb: Callable[[str], QPixmap | None] | None = None
    thumbs_ready: object | None = None                       # a signal: thumbnails arrived (repaint)
    skip: Callable[[str], bool] | None = None                # not an item of its own (a Live Photo's movie)
    note: Callable[[str], None] | None = None                # a line for the main window
    parent: QWidget | None = None


def _s(n: int, one: str, many: str | None = None) -> str:
    return f"{n:,} {one if n == 1 else (many or one + 's')}"


class _Gather(QObject):
    done = Signal(list)

    def __init__(self, folder: str, deep: bool, hooks: CleanupHooks) -> None:
        super().__init__()
        self.stop = threading.Event()
        self.args = (folder, deep, hooks.is_media, hooks.skip, self.stop)

    def start(self) -> None:
        def work() -> None:
            try:
                found = C.gather(*self.args)
            except Exception:  # noqa: BLE001 — a folder that can't be read has nothing to clean up
                found = []
            if not self.stop.is_set():
                try:
                    self.done.emit(found)
                except RuntimeError:                      # the app closed meanwhile
                    pass
        threading.Thread(target=work, name="cleanup-gather", daemon=True).start()


class CleanupRun(QObject):
    """One Clean Up of `folder` (module notes). Keep a reference while `alive`."""
    ended = Signal()

    def __init__(self, folder: str, hooks: CleanupHooks) -> None:
        super().__init__()
        self.folder, self.hooks = folder, hooks
        s = app_identity.settings()
        self.deep = str(s.value("cleanup/subfolders", "false")) == "true"
        self.shuffled = str(s.value("cleanup/random", "true")) != "false"
        self.session: C.Session | None = None
        self.viewer = None
        self.alive = True
        self._gather: _Gather | None = None
        self._asking = False

    # -- starting (and starting again with other options)
    def start(self) -> None:
        if self._gather is not None:
            self._gather.stop.set()
        if self.hooks.note is not None and self.deep:
            self.hooks.note(f"Clean Up: looking through “{os.path.basename(self.folder) or self.folder}”…")
        self._gather = _Gather(self.folder, self.deep, self.hooks)
        self._gather.done.connect(self._gathered, Qt.ConnectionType.QueuedConnection)
        self._gather.start()

    def _gathered(self, items: list) -> None:
        self._gather = None
        name = os.path.basename(self.folder) or self.folder
        self.session = C.Session(self.folder, list(items), C.store(), shuffled=self.shuffled,
                                 set_favorite=self.hooks.set_favorite, is_favorite=self.hooks.is_favorite)
        n = self.session.counts()
        if not items:
            if not self.deep and self._has_folders():
                self._offer_deep(name)
                return
            self._say(f"Clean Up: no photos or videos in “{name}”.")
            self._end()
            return
        if not self.session.queue:                        # all looked at on earlier runs (some may still be marked)
            self._finish(all_done=True)
            return
        if self.hooks.note is not None and (n["before"] or n["carried"]):
            self.hooks.note(f"Clean Up picks up where it stopped: {_s(n['total'], 'item')} to go in “{name}”"
                            + (f", {n['carried']:,} still marked for the Trash." if n["carried"] else "."))
        self._open(self.session.queue[0])

    def _has_folders(self) -> bool:
        try:
            with os.scandir(self.folder) as it:
                return any(e.is_dir(follow_symlinks=False) and not e.name.startswith(".") for e in it)
        except OSError:
            return False

    def _offer_deep(self, name: str) -> None:
        """A folder with nothing of its own but folders inside: what's in them is almost certainly what was meant
        (for this run — the remembered choice isn't changed)."""
        self.deep = True
        self.start()

    def _open(self, start: str) -> None:
        import media_viewer
        tri = media_viewer.Triage(state=self._state, decide=self._decide, undo=self._undo, counts=self._counts,
                                  done=self.done, menu=self._menu, title="Clean Up")
        self.viewer = self.hooks.view(list(self.session.queue), start, tri)
        if self.viewer is None:
            self._end()
            return
        self.viewer.setWindowTitle("Clean Up")
        self.viewer.removed.connect(self._removed)

    # -- what the viewer asks
    def _state(self, path: str) -> str:
        return self.session.answer(path) if self.session is not None else ""

    def _decide(self, path: str, what: str) -> None:
        self.session.decide(path, what)

    def _undo(self) -> str:
        return self.session.undo()

    def _counts(self) -> dict:
        n = self.session.counts()
        n["can_undo"] = self.session.can_undo()
        return n

    def _removed(self, paths: list) -> None:
        """Moved to the Trash from the viewer itself (⌘⌫): gone from the queue too."""
        if self.session is not None:
            self.session.gone(paths)

    def _menu(self, menu: QMenu) -> None:
        a = menu.addAction("Include Subfolders", lambda: self._set_option("subfolders", not self.deep))
        a.setCheckable(True)
        a.setChecked(self.deep)
        a.setToolTip("Everything under this folder, not just what's in it")
        a = menu.addAction("Random Order", lambda: self._set_option("random", not self.shuffled))
        a.setCheckable(True)
        a.setChecked(self.shuffled)
        a.setToolTip("Shuffled — off: in the folder's own order, by name")
        menu.addSeparator()
        menu.addAction("Start Over…", self._start_over).setToolTip(
            "Forget what's been looked at and what's marked here: the whole folder comes round again")

    def _set_option(self, which: str, on: bool) -> None:
        app_identity.settings().setValue(f"cleanup/{which}", "true" if on else "false")
        if which == "subfolders":
            self.deep = on
        else:
            self.shuffled = on
        self._reopen()

    def _start_over(self) -> None:
        if self.session is not None:
            self.session.start_over()
        self._reopen()

    def _reopen(self) -> None:
        """The same folder gathered again (other options, or from the start); answers so far are kept with it."""
        self._close_viewer()
        self.start()

    def _close_viewer(self) -> None:
        v, self.viewer = self.viewer, None
        if v is not None:
            try:
                v.end_triage()
            except RuntimeError:
                pass

    # -- finishing
    def done(self) -> None:
        """Done, the window's close, or the last item answered."""
        if self._asking or self.session is None:
            return
        n = self.session.counts()
        if not n[C.DELETE] and n["left"]:                 # nothing to act on: just stop here for now
            self._say(f"Clean Up paused — {_s(n['decided'], 'item')} looked at, {n['left']:,} to go. "
                      "It picks up here next time.")
            self._close_viewer()
            self._end()
            return
        self._finish(all_done=not n["left"])

    def _finish(self, all_done: bool) -> None:
        self._asking = True
        try:
            box = Finish(self.session, self.hooks, all_done, self.viewer or self.hooks.parent)
            box.exec()
            choice, chosen = box.choice, box.chosen()
        finally:
            self._asking = False
        name = os.path.basename(self.folder) or self.folder
        if choice == "trash":
            marked = self.session.marked()
            for p in marked:                                  # unticked on the finish screen: kept after all
                if p not in chosen:
                    self.session.decide(p, C.KEEP, remember=False)
            went = self.hooks.trash(list(chosen)) if chosen else []
            self.session.gone(went)
            stuck = len(chosen) - len(went)
            if stuck:
                self._say(f"Clean Up: {_s(stuck, 'item')} couldn't be moved to the Trash — still marked.")
            self._close_viewer()                              # (what's left to look at is there next time)
            self._end()
        elif choice == "again":
            self.session.start_over()
            self._reopen()
        elif choice == "continue" and self.viewer is not None:
            j = self.session.next_open(self.viewer.index)
            if j >= 0 and self.session.queue[j] in self.viewer.paths:
                self.viewer.index = self.viewer.paths.index(self.session.queue[j])
            self.viewer.show_current()
        else:                                             # Not Now / Done / closed: marks stay with the folder
            n = self.session.counts()
            if n[C.DELETE]:
                self._say(f"Clean Up: {_s(n[C.DELETE], 'item')} in “{name}” still marked for the Trash — "
                          "they're there next time. Nothing was deleted.")
            self._close_viewer()
            self._end()

    def _say(self, text: str) -> None:
        if self.hooks.note is not None:
            self.hooks.note(text)

    def _end(self) -> None:
        if self.alive:
            self.alive = False
            self.ended.emit()


class Finish(QDialog):
    """The finish screen (module notes). `choice`: "trash", "continue", "again" or "" (Not Now / Done)."""

    def __init__(self, session: C.Session, hooks: CleanupHooks, all_done: bool, parent=None) -> None:
        super().__init__(parent)
        self.session, self.hooks = session, hooks
        self.choice = ""
        name = os.path.basename(session.folder) or session.folder
        self.setWindowTitle("Clean Up")
        self.setModal(True)
        n = session.counts()
        marked = session.marked()
        v = QVBoxLayout(self)
        v.setContentsMargins(20, 18, 20, 16)
        v.setSpacing(10)
        title = QLabel(("All cleaned up — " if all_done else "Clean Up — ") + f"“{name}”")
        title.setObjectName("SheetTitle")
        v.addWidget(title)
        bits = [f"{n[C.KEEP] + n['before']:,} kept"]              # (this run's, and the ones kept on earlier runs)
        if n[C.FAVORITE]:
            bits.append(_s(n[C.FAVORITE], "favorite"))
        bits.append(f"{n[C.DELETE]:,} marked for the Trash")
        if n["left"]:
            bits.append(f"{n['left']:,} still to look at")
        self.summary = QLabel(" · ".join(bits) + (f"  ({n['carried']:,} marked last time)" if n["carried"] else ""))
        self.summary.setObjectName("SheetSub")
        self.summary.setWordWrap(True)
        v.addWidget(self.summary)

        self.grid = QListWidget()
        self.grid.setViewMode(QListView.ViewMode.IconMode)
        self.grid.setResizeMode(QListView.ResizeMode.Adjust)
        self.grid.setMovement(QListView.Movement.Static)
        self.grid.setIconSize(QSize(TILE, TILE))
        self.grid.setGridSize(QSize(TILE + 18, TILE + 44))
        self.grid.setWordWrap(True)
        self.grid.setUniformItemSizes(True)
        self.grid.setSelectionMode(QListView.SelectionMode.NoSelection)
        self.grid.setMinimumSize(640, 330)
        self._rows: dict[str, QListWidgetItem] = {}
        for p in marked:
            it = QListWidgetItem(self._icon(p), os.path.basename(p))
            it.setToolTip(p)
            it.setFlags(Qt.ItemFlag.ItemIsEnabled)             # (ticked by a click anywhere on the tile — `_clicked`)
            it.setCheckState(Qt.CheckState.Checked)
            it.setData(Qt.ItemDataRole.UserRole, p)
            self.grid.addItem(it)
            self._rows[p] = it
        self.grid.itemClicked.connect(self._clicked)
        self.hint = QLabel("These go to the Trash. Click any to keep it instead — nothing here has been deleted yet, "
                           "and the Trash can put them back.")
        self.hint.setObjectName("SheetSub")
        self.hint.setWordWrap(True)
        self.none = QLabel("Nothing is marked for the Trash.")
        self.none.setObjectName("SheetSub")
        v.addWidget(self.grid, 1)
        v.addWidget(self.hint)
        v.addWidget(self.none)
        self.grid.setVisible(bool(marked))
        self.hint.setVisible(bool(marked))
        self.none.setVisible(not marked)

        row = QHBoxLayout()
        self.later = QPushButton("Not Now" if marked else "Done")
        self.later.setToolTip("Close; what's marked stays marked for next time" if marked else "Close")
        self.later.clicked.connect(lambda: self._choose(""))
        row.addWidget(self.later)
        self.again = QPushButton("Review Again")
        self.again.setToolTip("Forget what's been looked at and marked here, and go through the folder afresh")
        self.again.clicked.connect(lambda: self._choose("again"))
        self.again.setVisible(all_done)
        row.addWidget(self.again)
        row.addStretch(1)
        self.go_on = QPushButton("Keep Reviewing")
        self.go_on.setToolTip(f"Back to the {n['left']:,} still to look at")
        self.go_on.clicked.connect(lambda: self._choose("continue"))
        self.go_on.setVisible(bool(n["left"]) and not all_done)
        row.addWidget(self.go_on)
        self.trash = QPushButton()
        self.trash.setObjectName("Primary")
        self.trash.clicked.connect(lambda: self._choose("trash"))
        row.addWidget(self.trash)
        v.addLayout(row)
        for b in (self.later, self.again, self.go_on):
            b.setAutoDefault(False)
        self.trash.setDefault(bool(marked))
        if hooks.thumbs_ready is not None:
            try:
                hooks.thumbs_ready.connect(self._thumbs_in)
            except (RuntimeError, TypeError):
                pass
        self._update()

    def _icon(self, path: str) -> QIcon:
        pm = None
        if self.hooks.thumb is not None:
            try:
                pm = self.hooks.thumb(path)
            except Exception:  # noqa: BLE001
                pm = None
        if pm is None or pm.isNull():
            pm = QPixmap(TILE, TILE)
            pm.fill(QColor("#2C2C2E"))
        else:
            pm = pm.scaled(TILE, TILE, Qt.AspectRatioMode.KeepAspectRatio, Qt.TransformationMode.SmoothTransformation)
        return QIcon(pm)

    def _thumbs_in(self) -> None:
        for p, it in self._rows.items():
            it.setIcon(self._icon(p))

    def _clicked(self, item: QListWidgetItem) -> None:
        """A click anywhere on a tile: to the Trash ⇄ kept."""
        item.setCheckState(Qt.CheckState.Unchecked if item.checkState() == Qt.CheckState.Checked
                           else Qt.CheckState.Checked)
        self._update()

    def chosen(self) -> list[str]:
        return [p for p, it in self._rows.items() if it.checkState() == Qt.CheckState.Checked]

    def _update(self) -> None:
        n = len(self.chosen())
        self.trash.setText(f"Move {n:,} to Trash" if n else "Move to Trash")
        self.trash.setEnabled(n > 0)
        self.trash.setVisible(bool(self._rows))
        kept = len(self._rows) - n
        if self._rows:
            self.hint.setText((f"{_s(n, 'item')} will go to the Trash" + (f"; {kept:,} unticked will be kept" if kept else "")
                               + ". Click any to change your mind — nothing here has been deleted yet, and the "
                                 "Trash can put them back."))

    def _choose(self, what: str) -> None:
        self.choice = what
        self.accept()

    def closeEvent(self, event) -> None:  # noqa: N802
        if self.hooks.thumbs_ready is not None:
            try:
                self.hooks.thumbs_ready.disconnect(self._thumbs_in)
            except (RuntimeError, TypeError):
                pass
        super().closeEvent(event)
