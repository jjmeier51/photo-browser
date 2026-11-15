"""Small pieces of the main window that make it easier to use — each asked for by a look at the app as a new
user would meet it (Nov 2026):

- `Toast` — what just happened ("Moved 3 items to the Trash", "Renamed 14 files"), said in a pill over the files
  for a few seconds, with one button when there's something to do about it (**Undo**, **Show**). Before, the
  only sign was the small status line changing for a moment.
- `EmptyNote` — a folder with nothing in it, a search that found nothing, an empty Favorites: said in the middle
  of the pane with what to do next, instead of a blank view that looks broken.
- `UndoStack` — the last things done that can be taken back (renames, tags, Favorites / To AI): Edit ▸ Undo (⌘Z).
- `CommandPalette` — every command in the menu bar in one searchable list (⇧⌘P), with its menu and shortcut:
  the app has well over a hundred commands, and a name is easier to remember than where it lives.
- `HelpWindow` — the app's guide (the README's section on it) and every keyboard shortcut, in a window with a
  search field, instead of opening a Markdown file in another app.
- `WelcomeDialog` — once, on the first launch: what the app is, in three lines, and the two ways in.

Nothing here knows about files; `photo_browser.py` and `menubar.py` hand each piece what it shows.
"""
from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

from PySide6.QtCore import QEvent, QPoint, Qt, QTimer, Signal
from PySide6.QtGui import QAction, QColor, QKeySequence, QTextCursor, QTextDocument
from PySide6.QtWidgets import (QDialog, QFrame, QHBoxLayout, QLabel, QLineEdit, QListWidget, QListWidgetItem,
                               QPushButton, QTabWidget, QTextBrowser, QTreeWidget, QTreeWidgetItem, QVBoxLayout,
                               QWidget)

import app_identity


# ----------------------------------------------------------------------------- toast

class Toast(QFrame):
    """A pill near the bottom of its parent: a line of text and, sometimes, one button. It goes by itself; a new
    one replaces it. Clicks elsewhere pass straight through to the files underneath."""

    def __init__(self, parent: QWidget) -> None:
        super().__init__(parent)
        self.setObjectName("Toast")
        self._action: Callable[[], None] | None = None
        h = QHBoxLayout(self)
        h.setContentsMargins(14, 7, 8, 7)
        h.setSpacing(10)
        self.label = QLabel()
        self.label.setObjectName("ToastText")
        h.addWidget(self.label)
        self.button = QPushButton()
        self.button.setObjectName("ToastButton")
        self.button.setCursor(Qt.CursorShape.PointingHandCursor)
        self.button.setFocusPolicy(Qt.FocusPolicy.NoFocus)
        self.button.clicked.connect(self._act)
        h.addWidget(self.button)
        self._timer = QTimer(self)
        self._timer.setSingleShot(True)
        self._timer.timeout.connect(self.hide)
        self.hide()
        parent.installEventFilter(self)

    def restyle(self, theme) -> None:
        # the reverse of the window: light on dark chrome, dark on light — it has to stand off the pictures
        bg, fg = ("#F2F2F7", "#1D1D1F") if theme.dark else ("#2C2C2E", "#FFFFFF")
        self.setStyleSheet(
            f"#Toast {{ background: {bg}; border-radius: 16px; border: 1px solid rgba(128,128,128,0.35); }}"
            f"#ToastText {{ color: {fg}; font-size: 12px; background: transparent; }}"
            f"QPushButton#ToastButton {{ background: {theme.accent}; color: {theme.on_accent}; border: none; "
            "border-radius: 10px; padding: 3px 12px; min-height: 0; font-size: 12px; font-weight: 600; }")

    def show_message(self, text: str, action_label: str = "", action: Callable[[], None] | None = None,
                     seconds: float | None = None) -> None:
        self._action = action
        self.label.setText(text)
        self.button.setText(action_label)
        self.button.setVisible(bool(action_label and action))
        self.layout().setContentsMargins(14, 7, 8 if self.button.isVisible() else 14, 7)
        self.adjustSize()
        self.place()
        self.show()
        self.raise_()
        if seconds is None:                               # long enough to read, longer when there's a choice
            seconds = (6.0 if action else 3.0) + min(4.0, len(text) / 40)
        self._timer.start(int(seconds * 1000))

    def place(self) -> None:
        p = self.parentWidget()
        if p is None:
            return
        width = min(self.sizeHint().width(), max(120, p.width() - 32))
        self.resize(width, self.sizeHint().height())
        self.move((p.width() - width) // 2, max(8, p.height() - self.height() - 18))

    def _act(self) -> None:
        action, self._action = self._action, None
        self.hide()
        if action is not None:
            action()

    def eventFilter(self, obj, event) -> bool:  # noqa: N802
        if obj is self.parentWidget() and event.type() == QEvent.Type.Resize and self.isVisible():
            self.place()
        return False


# ----------------------------------------------------------------------------- empty state

class EmptyNote(QLabel):
    """A title and a line of help in the middle of an empty view. Never in the way: the mouse goes through it
    (a drop or a right-click lands on the view underneath)."""

    def __init__(self, parent: QWidget) -> None:
        super().__init__(parent)
        self.setObjectName("EmptyNote")
        self.setAttribute(Qt.WidgetAttribute.WA_TransparentForMouseEvents)
        self.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.setWordWrap(True)
        self.setTextFormat(Qt.TextFormat.RichText)
        self._shown: tuple[str, str] = ("", "")
        self.hide()
        parent.installEventFilter(self)

    def say(self, title: str, detail: str, theme) -> None:
        """Shows the note — or, with an empty title, takes it away."""
        if not title:
            self._shown = ("", "")
            self.hide()
            return
        if (title, detail) != self._shown or not self.isVisible():
            self._shown = (title, detail)
            self.setText(f'<div style="font-size:17px; font-weight:600; color:{theme.secondary};">{_esc(title)}</div>'
                         f'<div style="font-size:12px; color:{theme.secondary}; margin-top:6px;">{_esc(detail)}</div>')
            self.place()
            self.show()
            self.raise_()

    def place(self) -> None:
        p = self.parentWidget()
        if p is not None:
            w = min(460, max(160, p.width() - 40))
            self.setFixedWidth(w)
            self.adjustSize()
            self.move((p.width() - w) // 2, max(10, (p.height() - self.height()) // 2 - 10))

    def eventFilter(self, obj, event) -> bool:  # noqa: N802
        if obj is self.parentWidget() and event.type() == QEvent.Type.Resize and self.isVisible():
            self.place()
        return False


def _esc(text: str) -> str:
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\n", "<br>")


# ----------------------------------------------------------------------------- undo

@dataclass
class Undoable:
    title: str                              # as the menu says it: "Rename of 14 Items"
    undo: Callable[[], str | None]          # takes it back; returns what to say ("Put 14 names back."), or None


class UndoStack:
    """The last things done that can be taken back, newest last. Not a history of everything — only what the
    app can truly reverse (a rename, a tag, a label); a move to the Trash is put back from the Trash."""

    LIMIT = 30

    def __init__(self) -> None:
        self.items: list[Undoable] = []
        self.changed: Callable[[], None] = lambda: None

    def push(self, title: str, undo: Callable[[], str | None]) -> None:
        self.items.append(Undoable(title, undo))
        del self.items[:-self.LIMIT]
        self.changed()

    def title(self) -> str:
        return self.items[-1].title if self.items else ""

    def pop_and_undo(self) -> str | None:
        """Takes the newest back. Returns what to say — None when there was nothing to undo."""
        if not self.items:
            return None
        item = self.items.pop()
        self.changed()
        try:
            return item.undo() or f"Undid {item.title}."
        except Exception as e:  # noqa: BLE001 — whatever went wrong, the person is told rather than left guessing
            return f"Couldn't undo {item.title}: {e}"


# ----------------------------------------------------------------------------- command palette

def menu_commands(menubar) -> list[tuple[str, QAction]]:
    """Every command in the menu bar as ("File ▸ Rename…", action), submenus followed. Menus are asked to bring
    themselves up to date first (their `aboutToShow`), so what's greyed out and what's ticked is as it would be
    on opening them."""
    out: list[tuple[str, QAction]] = []

    def walk(menu, trail: list[str]) -> None:
        menu.aboutToShow.emit()
        for a in menu.actions():
            if a.isSeparator() or not a.isVisible():
                continue
            text = a.text().replace("&", "")
            if a.menu() is not None:
                walk(a.menu(), trail + [text])
            elif text:
                out.append((" ▸ ".join(trail + [text]), a))

    for top in menubar.actions():
        if top.menu() is not None:
            walk(top.menu(), [top.text().replace("&", "")])
    return out


def _matches(words: list[str], text: str) -> int | None:
    """How well `text` answers the typed `words` (lower is better), or None when a word isn't in it."""
    low = text.lower()
    name = low.rsplit(" ▸ ", 1)[-1]
    score = 0
    for w in words:
        at = name.find(w)
        if at >= 0:
            score += 0 if at == 0 or name[at - 1] in " -(" else 2
        elif w in low:
            score += 5
        else:
            return None
    return score + len(name) // 12


class CommandPalette(QDialog):
    """⇧⌘P: type a few letters of any command; Return runs it. Greyed-out commands are listed (so it's clear the
    command exists) but can't be run — they say what they need in their tip where the menu does."""

    def __init__(self, parent, commands: list[tuple[str, QAction]], theme) -> None:
        super().__init__(parent, Qt.WindowType.Popup | Qt.WindowType.FramelessWindowHint)
        self.commands = commands
        self.setObjectName("Palette")
        self.setStyleSheet(
            f"#Palette {{ background: {theme.panel}; border: 1px solid {theme.border}; border-radius: 10px; }}"
            f"QLineEdit {{ background: {theme.content}; border: 1px solid {theme.button_border}; border-radius: 7px; "
            f"padding: 7px 10px; font-size: 15px; }} QLineEdit:focus {{ border-color: {theme.accent}; }}"
            f"QListWidget {{ background: transparent; border: none; outline: 0; font-size: 13px; }}"
            f"QListWidget::item {{ padding: 5px 8px; border-radius: 5px; }}"
            f"QListWidget::item:selected {{ background: {theme.accent}; color: {theme.on_accent}; }}"
            f"#PaletteHint {{ color: {theme.secondary}; font-size: 11px; }}")
        v = QVBoxLayout(self)
        v.setContentsMargins(10, 10, 10, 8)
        v.setSpacing(6)
        self.field = QLineEdit()
        self.field.setPlaceholderText("Type a command — “rename”, “duplicates”, “theme”…")
        self.field.setAccessibleName("Command")
        self.field.textChanged.connect(self._fill)
        self.field.installEventFilter(self)
        v.addWidget(self.field)
        self.list = QListWidget()
        self.list.setAccessibleName("Commands")
        self.list.setFocusPolicy(Qt.FocusPolicy.NoFocus)
        self.list.itemActivated.connect(lambda _i: self._run())
        self.list.itemClicked.connect(lambda _i: self._run())
        v.addWidget(self.list, 1)
        hint = QLabel("↑ ↓ to choose · Return to run · Esc to close")
        hint.setObjectName("PaletteHint")
        v.addWidget(hint)
        self.theme = theme
        self.resize(620, 420)
        self._fill("")

    def _fill(self, text: str) -> None:
        words = text.lower().split()
        ranked = []
        for i, (label, action) in enumerate(self.commands):
            score = _matches(words, label)
            if score is not None:
                ranked.append((0 if action.isEnabled() else 50, score, i, label, action))
        ranked.sort(key=lambda r: r[:3])
        self.list.clear()
        for _off, _score, _i, label, action in ranked[:200]:
            keys = action.shortcut().toString(QKeySequence.SequenceFormat.NativeText)
            item = QListWidgetItem(label + (f"      {keys}" if keys else ""))
            item.setData(Qt.ItemDataRole.UserRole, action)
            item.setToolTip(action.toolTip() if action.toolTip() != action.text() else "")
            if not action.isEnabled():
                item.setFlags(item.flags() & ~Qt.ItemFlag.ItemIsEnabled)
                item.setForeground(QColor(self.theme.tertiary))
            elif action.isCheckable() and action.isChecked():
                item.setText("✓ " + item.text())
            self.list.addItem(item)
        for row in range(self.list.count()):                 # the first one that can be run
            if self.list.item(row).flags() & Qt.ItemFlag.ItemIsEnabled:
                self.list.setCurrentRow(row)
                break

    def _step(self, by: int) -> None:
        row = self.list.currentRow()
        for _ in range(self.list.count()):
            row = (row + by) % max(1, self.list.count())
            if self.list.item(row).flags() & Qt.ItemFlag.ItemIsEnabled:
                self.list.setCurrentRow(row)
                return

    def _run(self) -> None:
        item = self.list.currentItem()
        action = item.data(Qt.ItemDataRole.UserRole) if item is not None else None
        if action is None or not action.isEnabled():
            return
        self.accept()
        QTimer.singleShot(0, action.trigger)                # once this window has gone

    def eventFilter(self, obj, event) -> bool:  # noqa: N802
        if obj is self.field and event.type() == QEvent.Type.KeyPress:
            if event.key() in (Qt.Key.Key_Down, Qt.Key.Key_Up):
                self._step(1 if event.key() == Qt.Key.Key_Down else -1)
                return True
            if event.key() in (Qt.Key.Key_Return, Qt.Key.Key_Enter):
                self._run()
                return True
        return False

    def open_over(self, window: QWidget) -> None:
        top = window.mapToGlobal(QPoint(0, 0))
        self.move(top.x() + (window.width() - self.width()) // 2, top.y() + max(40, window.height() // 7))
        self.show()
        self.field.setFocus()


# ----------------------------------------------------------------------------- help

def guide_markdown(readme: Path) -> str:
    """The README's part about the app itself (from "## The app" to the next top-level section), or all of it."""
    try:
        text = readme.read_text(encoding="utf-8")
    except OSError:
        return ""
    m = re.search(r"^## The app.*$", text, re.M)
    if m is None:
        return text
    rest = text[m.start():]
    end = re.search(r"^## (?!The app)", rest[3:], re.M)
    return rest[: end.start() + 3] if end else rest


class HelpWindow(QWidget):
    """Help ▸ Photo Browser for Mac Help: the guide, and the keyboard shortcuts — both searchable."""

    def __init__(self, parent, readme: Path, commands: list[tuple[str, QAction]], theme, extra_keys: list[tuple[str, str]]):
        super().__init__(parent, Qt.WindowType.Window)
        self.setAttribute(Qt.WidgetAttribute.WA_DeleteOnClose)
        self.setWindowTitle(f"{app_identity.APP_NAME} Help")
        self.resize(820, 680)
        v = QVBoxLayout(self)
        v.setContentsMargins(12, 10, 12, 12)
        v.setSpacing(8)
        top = QHBoxLayout()
        self.find = QLineEdit()
        self.find.setPlaceholderText("Find in Help")
        self.find.setClearButtonEnabled(True)
        self.find.setAccessibleName("Find in Help")
        self.find.returnPressed.connect(self._find_next)
        self.find.textChanged.connect(self._filter_keys)
        top.addWidget(self.find, 1)
        again = QPushButton("Find Next")
        again.clicked.connect(self._find_next)
        top.addWidget(again)
        v.addLayout(top)
        self.tabs = QTabWidget()
        self.tabs.setDocumentMode(True)
        v.addWidget(self.tabs, 1)

        self.guide = QTextBrowser()
        self.guide.setOpenExternalLinks(True)
        doc = guide_markdown(readme)
        if doc:
            # No raw HTML: the guide writes "<name>" and "<drive>" as plain words, which HTML would swallow.
            features = QTextDocument.MarkdownFeature.MarkdownDialectGitHub | QTextDocument.MarkdownFeature.MarkdownNoHTML
            self.guide.document().setMarkdown(doc, features)
        else:
            self.guide.setPlainText("The guide (mac/README.md) isn't beside this copy of the app.")
        self.guide.setStyleSheet(f"QTextBrowser {{ background: {theme.content}; border: 1px solid {theme.border}; "
                                 "border-radius: 6px; padding: 8px; font-size: 13px; }")
        self.tabs.addTab(self.guide, "Guide")

        self.keys = QTreeWidget()
        self.keys.setColumnCount(2)
        self.keys.setHeaderLabels(["Command", "Shortcut"])
        self.keys.setRootIsDecorated(False)
        self.keys.setAlternatingRowColors(True)
        self.keys.setStyleSheet(f"QTreeWidget {{ background: {theme.content}; border: 1px solid {theme.border}; "
                                "border-radius: 6px; }")
        for label, action in commands:
            keys = action.shortcut().toString(QKeySequence.SequenceFormat.NativeText)
            if keys:
                QTreeWidgetItem(self.keys, [label, keys])
        for label, keys in extra_keys:
            QTreeWidgetItem(self.keys, [label, keys])
        self.keys.resizeColumnToContents(0)
        self.keys.setColumnWidth(0, min(560, max(320, self.keys.columnWidth(0) + 20)))
        self.tabs.addTab(self.keys, "Keyboard Shortcuts")

    def _find_next(self) -> None:
        text = self.find.text().strip()
        if not text or self.tabs.currentWidget() is not self.guide:
            return
        if not self.guide.find(text):                          # from the top again
            self.guide.moveCursor(QTextCursor.MoveOperation.Start)
            self.guide.find(text, QTextDocument.FindFlag(0))

    def _filter_keys(self, text: str) -> None:
        words = text.lower().split()
        for i in range(self.keys.topLevelItemCount()):
            item = self.keys.topLevelItem(i)
            hay = (item.text(0) + " " + item.text(1)).lower()
            item.setHidden(not all(w in hay for w in words))


# ----------------------------------------------------------------------------- welcome

class WelcomeDialog(QDialog):
    """The first launch: what this is, and where to start. Never shown again once closed."""
    chosen = Signal(str)                    # "drive" | "split" | ""

    def __init__(self, parent, theme, drive_name: str = "") -> None:
        super().__init__(parent)
        self.setWindowTitle(f"Welcome to {app_identity.APP_NAME}")
        self.setModal(True)
        v = QVBoxLayout(self)
        v.setContentsMargins(26, 22, 26, 18)
        v.setSpacing(10)
        title = QLabel(f"Welcome to {app_identity.APP_NAME}")
        title.setStyleSheet("font-size: 20px; font-weight: 700;")
        v.addWidget(title)
        sub = QLabel("The Mac side of Photo Browser on your iPhone: the same drive, the same folders, tags, "
                     "Favorites and covers.")
        sub.setWordWrap(True)
        sub.setStyleSheet(f"color: {theme.secondary}; font-size: 13px;")
        v.addWidget(sub)
        v.addSpacing(4)
        for head, body in (
                ("Browse", "Open the drive in the sidebar. ⌘1 icons, ⌘2 list, ⌘3 the iPhone's photo grid; "
                           "double-click a photo or video to view it; Space is Quick Look."),
                ("Move files onto the drive safely", "Split View (⌘\\) shows a second pane. Select on the left, "
                                                     "then Move or Copy — every file is checked after it's written."),
                ("Everything else", "Right-click anything for its tools, or press ⇧⌘P and type what you want — "
                                    "“rename”, “duplicates”, “tags”, “theme”. Help has the full guide.")):
            row = QLabel(f"<b>{_esc(head)}</b><br><span style='color:{theme.secondary};'>{_esc(body)}</span>")
            row.setTextFormat(Qt.TextFormat.RichText)
            row.setWordWrap(True)
            row.setStyleSheet("font-size: 13px;")
            v.addWidget(row)
        v.addSpacing(8)
        buttons = QHBoxLayout()
        buttons.addStretch(1)
        split = QPushButton("Open Split View")
        split.clicked.connect(lambda: self._done("split"))
        buttons.addWidget(split)
        if drive_name:
            drive = QPushButton(f"Open “{drive_name}”")
            drive.clicked.connect(lambda: self._done("drive"))
            buttons.addWidget(drive)
        go = QPushButton("Get Started")
        go.setDefault(True)
        go.clicked.connect(lambda: self._done(""))
        buttons.addWidget(go)
        v.addLayout(buttons)
        self.setFixedWidth(520)

    def _done(self, what: str) -> None:
        self.chosen.emit(what)
        self.accept()
