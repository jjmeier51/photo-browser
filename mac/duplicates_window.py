"""The Find Duplicates window — the iPhone app's screen (`DuplicatesView`) on the Mac: groups of likely
duplicates (duplicates.py finds them), each copy a tile; click the copies you don't want and Move them to the
Trash together. Nothing goes without that button and its confirmation.

- **Groups** come strongest first — Exact (green), Visually similar (blue), Similar name (orange) — each with
  how many copies, the size, the dimensions and the file types. An exact group whose copies turn out byte for
  byte the same (read through in the background) says **Identical**.
- **Tiles**: the picture, its name, and its size — or, when the copies' dates differ, the day and time to the
  millisecond, with the **Oldest** and **Newest** marked (as on the iPhone). A click ticks a copy for the
  Trash (red ring); a double-click opens the group in the viewer, at that copy, to look closely and flip
  between them. With subfolders included, each tile says which folder its copy is in.
- **Per group**: View, Not Duplicates (never listed again), and a menu — Select All But One, Select All
  Copies, Deselect, Show in Photo Browser. Right-click a copy: Keep Only This One, View, Show in Photo Browser.
- **Which copy is kept** is a rule, chosen in the bar (`duplicates.KEEP_RULES`: the best copy, the largest file,
  the highest resolution, the oldest, the newest) with an optional **preferred folder** — copies in it are kept
  over copies elsewhere. The copy the rule would keep wears a green **Keep** mark in every group, so the rule
  is seen before anything is ticked.
- **For the lot**: **Select Extra Copies** ticks every copy but the kept one — in the *identical* groups (the
  safe bulk pick: those copies are the same file), in all exact groups, or in every group shown — and the bar
  shows how many are ticked and how much space they'd free. **Move to Trash** asks first, warns when a group
  would lose every copy, and (unless unticked) gives each kept copy the tags, Favorite and To AI of the copies
  that go, so nothing said about a photo is lost with its duplicate.
- **What's looked at**: **Include subfolders**, **Leave out “Frame” files** (video-frame screenshots: hundreds
  of alike images that are never duplicates), **Other files too** (documents, archives — by their bytes) and how
  strict **Look-alikes** are; several folders can be looked at as one (select them, Find Duplicates). All
  remembered; Rescan looks again (fast — the photos' fingerprints are kept). Groups sort by space, name, number
  of copies or folder.

Photo Browser for Mac hands the window what it needs (`DupHooks`): thumbnails, the trash, tags, the viewer and
revealing a file — the window itself never deletes anything.
"""
from __future__ import annotations

import os
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from typing import Callable

from PySide6.QtCore import QObject, QPoint, QRect, QRectF, QSettings, QSize, Qt, QTimer, Signal
from PySide6.QtGui import QColor, QFont, QFontMetrics, QPainter, QPainterPath, QPen, QPixmap
from PySide6.QtWidgets import (QButtonGroup, QCheckBox, QComboBox, QFileDialog, QFrame, QHBoxLayout, QLabel, QLayout,
                               QMenu, QMessageBox, QProgressBar, QPushButton, QScrollArea, QSizePolicy, QToolButton,
                               QVBoxLayout, QWidget, QWidgetItem)

import duplicates as D
import app_identity

PAGE = 60                                          # groups shown at a time ("Show More" for the next)
TILE_W, PIC = 150, 150
KIND_COLOR = {"exact": "#30D158", "similar": "#0A84FF", "name": "#FF9F0A"}
SORTS = {"space": "Most space first", "copies": "Most copies first", "name": "By name", "folder": "By folder"}
SCOPES = {"identical": "In Identical Groups", "exact": "In All Exact Groups", "shown": "In Every Group Shown"}


@dataclass
class DupHooks:
    thumb: Callable[[str], QPixmap | None]                   # a thumbnail, or None while it's being made
    thumbs_ready: object | None = None                       # a Qt signal: thumbnails arrived
    trash: Callable[[list[str]], list[str]] | None = None    # → the paths actually moved to the Trash
    tags_of: Callable[[str], list[str]] | None = None
    view: Callable[[list[str], str], None] | None = None     # (the group's files, the one to start at)
    reveal: Callable[[str], None] | None = None
    changed: Callable[[], None] | None = None                # files went: the panes look again
    inherit: Callable[[str, list[str]], None] | None = None  # (kept copy, copies going): tags and labels move over


def human(n: float) -> str:
    for unit in ("bytes", "KB", "MB", "GB"):
        if n < 1024 or unit == "GB":
            return f"{int(n)} bytes" if unit == "bytes" else f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.1f} TB"


class FlowLayout(QLayout):
    """Tiles left to right, wrapping to the width (Qt's own flow-layout example, trimmed)."""

    def __init__(self, parent=None, spacing: int = 10) -> None:
        super().__init__(parent)
        self.items: list[QWidgetItem] = []
        self.gap = spacing

    def addItem(self, item) -> None:  # noqa: N802
        self.items.append(item)

    def count(self) -> int:
        return len(self.items)

    def itemAt(self, i: int):  # noqa: N802
        return self.items[i] if 0 <= i < len(self.items) else None

    def takeAt(self, i: int):  # noqa: N802
        return self.items.pop(i) if 0 <= i < len(self.items) else None

    def expandingDirections(self):  # noqa: N802
        return Qt.Orientation(0)

    def hasHeightForWidth(self) -> bool:  # noqa: N802
        return True

    def heightForWidth(self, width: int) -> int:  # noqa: N802
        return self._lay(QRect(0, 0, width, 0), True)

    def setGeometry(self, rect: QRect) -> None:  # noqa: N802
        super().setGeometry(rect)
        self._lay(rect, False)

    def sizeHint(self) -> QSize:  # noqa: N802
        return self.minimumSize()

    def minimumSize(self) -> QSize:  # noqa: N802
        s = QSize()
        for it in self.items:
            s = s.expandedTo(it.minimumSize())
        m = self.contentsMargins()
        return s + QSize(m.left() + m.right(), m.top() + m.bottom())

    def _lay(self, rect: QRect, test: bool) -> int:
        m = self.contentsMargins()
        r = rect.adjusted(m.left(), m.top(), -m.right(), -m.bottom())
        x, y, line = r.x(), r.y(), 0
        for it in self.items:
            hint = it.sizeHint()
            if x + hint.width() > r.right() + 1 and line > 0:
                x, y, line = r.x(), y + line + self.gap, 0
            if not test:
                it.setGeometry(QRect(QPoint(x, y), hint))
            x += hint.width() + self.gap
            line = max(line, hint.height())
        return y + line - rect.y() + m.bottom()


class Tile(QWidget):
    """One copy: picture, tick, Oldest/Newest, name, size or time, folder."""
    toggled = Signal(str)
    opened = Signal(str)
    restored = Signal(str, bool)                    # a double-click: the tick back as it was before its clicks
    only = Signal(str)                              # Keep Only This One

    def __init__(self, path: str, card: "Card") -> None:
        super().__init__(card)
        self.path = path
        self.card = card
        self.selected = False
        self.before_press = False
        self.marker = ""                            # "oldest" | "newest"
        self.when: float | None = None
        self.keep = False                           # the copy the keep rule would keep
        self.pixels: tuple[int, int] = (0, 0)
        self.folder_note = ""
        try:
            self.size = os.path.getsize(path)
        except OSError:
            self.size = 0
        self.setFixedSize(TILE_W, PIC + 52)
        self.setCursor(Qt.CursorShape.PointingHandCursor)
        self.setToolTip(path)

    def mousePressEvent(self, e) -> None:  # noqa: N802
        if e.button() == Qt.MouseButton.LeftButton:
            self.before_press = self.selected
            self.toggled.emit(self.path)

    def mouseDoubleClickEvent(self, e) -> None:  # noqa: N802
        # a double-click only opens: the tick goes back to how it was before the first of its clicks
        self.restored.emit(self.path, self.before_press)
        self.opened.emit(self.path)

    def contextMenuEvent(self, e) -> None:  # noqa: N802
        menu = QMenu(self)
        menu.addAction("Keep Only This One", lambda: self.only.emit(self.path))
        menu.addAction("View", lambda: self.opened.emit(self.path))
        reveal = self.card.win.hooks.reveal
        if reveal is not None:
            menu.addAction("Show in Photo Browser", lambda: reveal(self.path))
        menu.exec(e.globalPos())
        menu.deleteLater()

    def paintEvent(self, _e) -> None:  # noqa: N802
        theme = self.card.win.theme
        p = QPainter(self)
        p.setRenderHint(QPainter.RenderHint.Antialiasing)
        p.setRenderHint(QPainter.RenderHint.SmoothPixmapTransform)
        pic = QRectF(0, 0, TILE_W, PIC)
        path = QPainterPath()
        path.addRoundedRect(pic, 8, 8)
        p.fillPath(path, QColor("#2C2C2E") if theme.dark else QColor("#ECECEF"))
        pm = self.card.win.hooks.thumb(self.path)
        if pm is not None and not pm.isNull():
            s = min(pic.width() / pm.width(), pic.height() / pm.height())
            w, h = pm.width() * s, pm.height() * s
            p.save()
            p.setClipPath(path)
            p.drawPixmap(QRectF((pic.width() - w) / 2, (pic.height() - h) / 2, w, h), pm, QRectF(pm.rect()))
            p.restore()
        else:
            p.setPen(QColor(theme.tertiary))
            p.drawText(pic, Qt.AlignmentFlag.AlignCenter, os.path.splitext(self.path)[1].upper().lstrip(".") or "…")
        if D.kind_of(self.path) == "video":
            d = 22
            badge = QRectF(6, PIC - d - 6, d, d)
            p.setPen(Qt.PenStyle.NoPen)
            p.setBrush(QColor(0, 0, 0, 130))
            p.drawEllipse(badge)
            tri = QPainterPath()
            tri.moveTo(badge.left() + d * 0.4, badge.top() + d * 0.28)
            tri.lineTo(badge.left() + d * 0.74, badge.top() + d * 0.5)
            tri.lineTo(badge.left() + d * 0.4, badge.top() + d * 0.72)
            tri.closeSubpath()
            p.setBrush(QColor("white"))
            p.drawPath(tri)
        small = QFont(self.font())
        small.setPointSizeF(max(8.0, small.pointSizeF() - 2))
        small.setWeight(QFont.Weight.DemiBold)
        if self.marker:
            p.setFont(small)
            fm = QFontMetrics(small)
            text = "Oldest" if self.marker == "oldest" else "Newest"
            pill = QRectF(6, 6, fm.horizontalAdvance(text) + 12, fm.height() + 4)
            p.setPen(Qt.PenStyle.NoPen)
            p.setBrush(QColor("#FF9F0A") if self.marker == "oldest" else QColor("#32ADE6"))
            p.drawRoundedRect(pill, pill.height() / 2, pill.height() / 2)
            p.setPen(QColor("white"))
            p.drawText(pill, Qt.AlignmentFlag.AlignCenter, text)
        if self.keep and not self.selected:         # what the keep rule would keep, said before anything is ticked
            p.setFont(small)
            fm = QFontMetrics(small)
            pill = QRectF(0, 0, fm.horizontalAdvance("Keep") + 12, fm.height() + 4)
            pill.moveBottomRight(pic.bottomRight() - QPoint(6, 6))
            p.setPen(Qt.PenStyle.NoPen)
            p.setBrush(QColor("#30D158"))
            p.drawRoundedRect(pill, pill.height() / 2, pill.height() / 2)
            p.setPen(QColor("white"))
            p.drawText(pill, Qt.AlignmentFlag.AlignCenter, "Keep")
        # the tick
        d = 24
        ring = QRectF(TILE_W - d - 6, 6, d, d)
        if self.selected:
            p.setPen(QPen(QColor(theme.red), 3))
            p.setBrush(Qt.BrushStyle.NoBrush)
            p.drawRoundedRect(pic.adjusted(1.5, 1.5, -1.5, -1.5), 7, 7)
            p.setPen(QPen(QColor("white"), 1.5))
            p.setBrush(QColor(theme.red))
            p.drawEllipse(ring)
            p.setPen(QPen(QColor("white"), 2.2, Qt.PenStyle.SolidLine, Qt.PenCapStyle.RoundCap))
            c = ring.center()
            p.drawLine(QPoint(int(c.x() - 5), int(c.y() - 5)), QPoint(int(c.x() + 5), int(c.y() + 5)))
            p.drawLine(QPoint(int(c.x() + 5), int(c.y() - 5)), QPoint(int(c.x() - 5), int(c.y() + 5)))
        else:
            p.setPen(QPen(QColor("white"), 1.6))
            p.setBrush(QColor(0, 0, 0, 70))
            p.drawEllipse(ring)
        # name and detail
        name_font = QFont(self.font())
        name_font.setPointSizeF(max(8.0, name_font.pointSizeF() - 1))
        fm = QFontMetrics(name_font)
        p.setFont(name_font)
        p.setPen(QColor(theme.text))
        p.drawText(QRect(2, PIC + 4, TILE_W - 4, fm.height()), Qt.AlignmentFlag.AlignLeft,
                   fm.elidedText(os.path.basename(self.path), Qt.TextElideMode.ElideMiddle, TILE_W - 4))
        sfm = QFontMetrics(small)
        p.setFont(small)
        p.setPen(QColor(theme.secondary))
        if self.marker and self.when:
            lt = time.localtime(self.when)
            detail = time.strftime("%b %d, %Y %H:%M:%S", lt) + f".{int((self.when % 1) * 1000):03d}"
        elif self.pixels[0]:
            detail = f"{self.pixels[0]:,} × {self.pixels[1]:,} · {human(self.size)}"
        else:
            detail = human(self.size)
        p.drawText(QRect(2, PIC + 6 + fm.height(), TILE_W - 4, sfm.height()), Qt.AlignmentFlag.AlignLeft,
                   sfm.elidedText(detail, Qt.TextElideMode.ElideRight, TILE_W - 4))
        if self.folder_note:
            p.setPen(QColor(theme.tertiary))
            p.drawText(QRect(2, PIC + 8 + fm.height() + sfm.height(), TILE_W - 4, sfm.height()),
                       Qt.AlignmentFlag.AlignLeft,
                       sfm.elidedText(self.folder_note, Qt.TextElideMode.ElideMiddle, TILE_W - 4))
        p.end()


class Card(QFrame):
    """One group: its badge and facts, its actions, its copies."""

    def __init__(self, group: D.Group, win: "DuplicatesWindow") -> None:
        super().__init__()
        self.group = group
        self.win = win
        self.setObjectName("DupCard")
        v = QVBoxLayout(self)
        v.setContentsMargins(14, 10, 14, 12)
        v.setSpacing(8)
        head = QHBoxLayout()
        head.setSpacing(8)
        self.badge = QLabel()
        self.badge.setObjectName("DupBadge")
        head.addWidget(self.badge)
        self.facts = QLabel()
        self.facts.setObjectName("SheetSub")
        head.addWidget(self.facts, 1)
        view = QPushButton("View")
        view.setToolTip("See these copies full size in the viewer and flip between them")
        view.clicked.connect(lambda: self.win.view(self.group.paths, self.group.paths[0]))
        head.addWidget(view)
        nd = QPushButton("Not Duplicates")
        nd.setToolTip("These aren't copies of each other — don't list them again")
        nd.clicked.connect(lambda: self.win.not_duplicates(self))
        head.addWidget(nd)
        more = QToolButton()
        more.setText("•••")
        more.setObjectName("DupMore")
        more.setPopupMode(QToolButton.ToolButtonPopupMode.InstantPopup)
        menu = QMenu(more)
        menu.addAction("Select All But One", lambda: self.win.all_but_one(self))
        menu.addAction("Select All Copies", lambda: self.win.set_selected(self.group.paths, True))
        menu.addAction("Deselect", lambda: self.win.set_selected(self.group.paths, False))
        if self.win.hooks.reveal is not None:
            menu.addSeparator()
            menu.addAction("Show in Photo Browser", lambda: self.win.hooks.reveal(self.group.paths[0]))
        more.setMenu(menu)
        head.addWidget(more)
        v.addLayout(head)
        holder = QWidget()
        self.flow = FlowLayout(holder, 10)
        self.flow.setContentsMargins(0, 0, 0, 0)
        self.tiles: dict[str, Tile] = {}
        base = self.win.folder
        for path in group.paths:
            t = Tile(path, self)
            if self.win.recursive:
                rel = os.path.relpath(os.path.dirname(path), base)
                t.folder_note = "in this folder" if rel == "." else f"in {rel}"
            t.selected = path in self.win.selected
            t.toggled.connect(self.win.toggle)
            t.restored.connect(lambda p, on: self.win.set_selected([p], on))
            t.opened.connect(lambda p: self.win.view(self.group.paths, p))
            t.only.connect(lambda p: self.win.keep_only(self, p))
            self.flow.addWidget(t)
            self.tiles[path] = t
        v.addWidget(holder)
        self.refresh()

    def refresh(self) -> None:
        g = self.group
        color = KIND_COLOR[g.kind]
        label = D.KIND_LABEL[g.kind] + ("  ✓ Identical" if g.identical else "")
        self.badge.setText(label)
        self.badge.setStyleSheet(f"#DupBadge {{ color: white; background: {color}; border-radius: 9px; "
                                 f"padding: 2px 9px; font-size: 11px; font-weight: 700; }}")
        bits = [f"{len(g.paths)} copies", human(g.size)]
        if g.dims:
            bits.append(g.dims)
        bits.append(g.types)
        if g.kind == "exact" and g.identical is False:
            bits.append("same size, different bytes")
        if g.alike:
            bits.append(g.alike)
        self.facts.setText(" · ".join(b for b in bits if b))
        dates = self.win.dates
        marks = D.ages(g.paths, dates)
        keep = self.win.keeper(g.paths)
        for p, t in self.tiles.items():
            t.marker = marks.get(p, "")
            t.when = dates.get(p)
            t.pixels = self.win.pixels.get(p, (0, 0))
            t.keep = p == keep
            t.selected = p in self.win.selected
            t.update()


class _Bridge(QObject):
    progress = Signal(str, int, int)
    scanned = Signal(object)                        # the groups
    identical = Signal(object)                      # a group whose Identical check finished
    dated = Signal(object)                          # ({path: date}, {path: (width, height)})


class DuplicatesWindow(QWidget):
    def __init__(self, folder: str | list[str], hooks: DupHooks, theme, parent=None) -> None:
        super().__init__(parent, Qt.WindowType.Window)
        self.setAttribute(Qt.WidgetAttribute.WA_DeleteOnClose)
        self.folders = [folder] if isinstance(folder, str) else list(folder)
        # what tiles' "in <folder>" notes are told from: the folder, or what several have in common
        self.folder = self.folders[0] if len(self.folders) == 1 else os.path.commonpath(self.folders)
        self.hooks = hooks
        self.theme = theme
        self.settings = app_identity.settings()
        self.recursive = str(self.settings.value("duplicates/subfolders", "false")) == "true"
        self.exclude_frames = str(self.settings.value("duplicates/exclude_frames", "false")) == "true"
        self.all_files = str(self.settings.value("duplicates/all_files", "false")) == "true"
        self.strictness = str(self.settings.value("duplicates/strictness", "normal"))
        if self.strictness not in D.STRICTNESS:
            self.strictness = "normal"
        self.sort = str(self.settings.value("duplicates/sort", "space"))
        if self.sort not in SORTS:
            self.sort = "space"
        self.keep_rule = str(self.settings.value("duplicates/keep", "best"))
        if self.keep_rule not in D.KEEP_RULES:
            self.keep_rule = "best"
        self.prefer: str | None = None              # a folder whose copies are kept over copies elsewhere
        self.pixels: dict[str, tuple[int, int]] = {}
        self.not_dupes = D.NotDuplicates()
        self.groups: list[D.Group] = []
        self.selected: set[str] = set()
        self.dates: dict[str, float] = {}
        self.filter = "all"
        self.shown = PAGE
        self.cards: list[Card] = []
        self.stop = threading.Event()
        self.scanning = False
        self.scanned_at = 0.0
        self.bridge = _Bridge()
        self.bridge.progress.connect(self._progress)
        self.bridge.scanned.connect(self._scanned)
        self.bridge.identical.connect(self._identical)
        self.bridge.dated.connect(self._dated)
        if hooks.thumbs_ready is not None:
            self._repaint = QTimer(self)
            self._repaint.setSingleShot(True)
            self._repaint.setInterval(120)
            self._repaint.timeout.connect(self._repaint_tiles)
            hooks.thumbs_ready.connect(self._repaint.start)
        self.setWindowTitle(f"Find Duplicates — {os.path.basename(self.folder) or self.folder}" if len(self.folders) == 1
                            else f"Find Duplicates — {len(self.folders)} folders")
        self.resize(980, 760)
        self._build()
        QTimer.singleShot(0, self.rescan)

    # ------------------------------------------------------------------ layout
    def _build(self) -> None:
        t = self.theme
        self.setStyleSheet(f"""
            #DupCard {{ background: {t.panel}; border: 1px solid {t.border}; border-radius: 10px; }}
            QToolButton#DupMore {{ border: 1px solid {t.button_border}; border-radius: 6px; padding: 3px 8px;
                                   background: {t.button}; }}
            QToolButton#DupMore::menu-indicator {{ image: none; width: 0; }}
            QToolButton#DupFilter {{ border: 1px solid {t.button_border}; border-radius: 12px; padding: 3px 11px;
                                     background: {t.button}; }}
            QToolButton#DupFilter:checked {{ background: {t.accent}; color: {getattr(t, "on_accent", "white")};
                                             border-color: {t.accent}; }}
            QScrollArea#DupScroll, QWidget#DupBody {{ background: {t.content}; border: none; }}
            #DupBar {{ background: {t.header}; border-top: 1px solid {t.border}; }}
            #DupTop {{ background: {t.header}; border-bottom: 1px solid {t.border}; }}
        """)
        v = QVBoxLayout(self)
        v.setContentsMargins(0, 0, 0, 0)
        v.setSpacing(0)
        top = QFrame()
        top.setObjectName("DupTop")
        tv = QVBoxLayout(top)
        tv.setContentsMargins(18, 14, 18, 12)
        tv.setSpacing(8)
        row = QHBoxLayout()
        title = QLabel("Find Duplicates")
        title.setObjectName("SheetTitle")
        row.addWidget(title)
        self.where = QLabel(self.folder if len(self.folders) == 1 else
                            ", ".join(os.path.basename(f) or f for f in self.folders))
        self.where.setToolTip("\n".join(self.folders))
        self.where.setObjectName("SheetSub")
        row.addWidget(self.where, 1)
        self.rescan_btn = QPushButton("Rescan")
        self.rescan_btn.clicked.connect(self.rescan)
        row.addWidget(self.rescan_btn)
        tv.addLayout(row)
        opts = QHBoxLayout()
        self.sub_box = QCheckBox("Include subfolders")
        self.sub_box.setChecked(self.recursive)
        self.sub_box.toggled.connect(self._options)
        self.frames_box = QCheckBox("Leave out “Frame” files")
        self.frames_box.setToolTip("Video-frame screenshots — hundreds of alike images that are never duplicates")
        self.frames_box.setChecked(self.exclude_frames)
        self.frames_box.toggled.connect(self._options)
        self.all_box = QCheckBox("Other files too")
        self.all_box.setToolTip("Documents, archives and everything else, not only photos and videos — matched by "
                                "their bytes")
        self.all_box.setChecked(self.all_files)
        self.all_box.toggled.connect(self._options)
        self.strict_box = QComboBox()
        for key, label in D.STRICTNESS_LABEL.items():
            self.strict_box.addItem(label, key)
        self.strict_box.setCurrentIndex(max(0, self.strict_box.findData(self.strictness)))
        self.strict_box.setToolTip("How alike two photos must look to be listed as visually similar.\n"
                                   "Strict: all but identical. Loose: also catches heavier edits and crops — and "
                                   "more photos that only resemble each other.")
        self.strict_box.activated.connect(lambda _i: self._options())
        self.sort_box = QComboBox()
        for key, label in SORTS.items():
            self.sort_box.addItem(label, key)
        self.sort_box.setCurrentIndex(max(0, self.sort_box.findData(self.sort)))
        self.sort_box.setToolTip("The order of the groups")
        self.sort_box.activated.connect(lambda _i: self._set_sort())
        opts.addWidget(self.sub_box)
        opts.addWidget(self.frames_box)
        opts.addWidget(self.all_box)
        opts.addSpacing(6)
        opts.addWidget(QLabel("Look-alikes:"))
        opts.addWidget(self.strict_box)
        opts.addStretch(1)
        opts.addWidget(self.sort_box)
        tv.addLayout(opts)
        prog = QHBoxLayout()
        self.filters = QButtonGroup(self)
        self.filter_btns: dict[str, QToolButton] = {}
        for key in ("all", *D.KINDS):
            b = QToolButton()
            b.setObjectName("DupFilter")
            b.setCheckable(True)
            b.setChecked(key == "all")
            b.clicked.connect(lambda _=False, k=key: self._set_filter(k))
            self.filters.addButton(b)
            self.filter_btns[key] = b
            prog.addWidget(b)
        prog.addSpacing(8)
        self.bar = QProgressBar()
        self.bar.setVisible(False)
        self.status = QLabel("")
        self.status.setObjectName("SheetSub")
        self.stop_btn = QPushButton("Stop")
        self.stop_btn.setVisible(False)
        self.stop_btn.clicked.connect(lambda: self.stop.set())   # whichever look is running
        prog.addWidget(self.status, 1)
        prog.addWidget(self.bar, 1)
        prog.addWidget(self.stop_btn)
        tv.addLayout(prog)
        v.addWidget(top)
        self.scroll = QScrollArea()
        self.scroll.setObjectName("DupScroll")
        self.scroll.setWidgetResizable(True)
        self.scroll.setFrameShape(QFrame.Shape.NoFrame)
        self.body = QWidget()
        self.body.setObjectName("DupBody")
        self.list = QVBoxLayout(self.body)
        self.list.setContentsMargins(16, 14, 16, 14)
        self.list.setSpacing(12)
        self.list.addStretch(1)
        self.scroll.setWidget(self.body)
        v.addWidget(self.scroll, 1)
        bar = QFrame()
        bar.setObjectName("DupBar")
        bh = QHBoxLayout(bar)
        bh.setContentsMargins(16, 10, 16, 10)
        self.summary = QLabel("")
        self.summary.setObjectName("SheetSub")
        bh.addWidget(self.summary, 1)
        bh.addWidget(QLabel("Keep:"))
        self.keep_box = QComboBox()
        self._fill_keep()
        self.keep_box.activated.connect(lambda _i: self._keep_chosen())
        bh.addWidget(self.keep_box)
        self.extra_btn = QToolButton()
        self.extra_btn.setObjectName("DupMore")
        self.extra_btn.setText("Select Extra Copies ▾")
        self.extra_btn.setPopupMode(QToolButton.ToolButtonPopupMode.InstantPopup)
        self.extra_btn.setToolTip("Tick every copy but the one to keep (marked Keep), a group at a time")
        self.extra_menu = QMenu(self.extra_btn)
        self.extra_menu.setToolTipsVisible(True)
        self.extra_acts = {}
        for key, tip in (("identical", "The safe pick: these copies are the same file, byte for byte"),
                         ("exact", "Same size and dimensions — almost always the same file"),
                         ("shown", "Look-alikes and similar names too: check them before the Trash")):
            a = self.extra_menu.addAction(SCOPES[key], lambda k=key: self.select_extra(k))
            a.setToolTip(tip)
            self.extra_acts[key] = a
        self.extra_btn.setMenu(self.extra_menu)
        self.clear_btn = QPushButton("Deselect All")
        self.clear_btn.clicked.connect(lambda: self.set_selected(list(self.selected), False))
        self.trash_btn = QPushButton("Move to Trash")
        self.trash_btn.setObjectName("Primary")
        self.trash_btn.clicked.connect(self.trash)
        for b in (self.extra_btn, self.clear_btn, self.trash_btn):
            bh.addWidget(b)
        v.addWidget(bar)
        self._update_counts()
        self._update_bar()

    # ------------------------------------------------------------------ scanning
    def _options(self) -> None:
        self.recursive = self.sub_box.isChecked()
        self.exclude_frames = self.frames_box.isChecked()
        self.all_files = self.all_box.isChecked()
        self.strictness = self.strict_box.currentData() or "normal"
        self.settings.setValue("duplicates/subfolders", "true" if self.recursive else "false")
        self.settings.setValue("duplicates/exclude_frames", "true" if self.exclude_frames else "false")
        self.settings.setValue("duplicates/all_files", "true" if self.all_files else "false")
        self.settings.setValue("duplicates/strictness", self.strictness)
        self.rescan()

    def _set_sort(self) -> None:
        self.sort = self.sort_box.currentData() or "space"
        self.settings.setValue("duplicates/sort", self.sort)
        self.shown = PAGE
        self._render()

    # ------------------------------------------------------------------ which copy is kept
    def _fill_keep(self) -> None:
        self.keep_box.blockSignals(True)
        self.keep_box.clear()
        for i, (key, label) in enumerate(D.KEEP_RULES.items()):
            self.keep_box.addItem(label, key)
            self.keep_box.setItemData(i, D.KEEP_TIP[key], Qt.ItemDataRole.ToolTipRole)
        self.keep_box.insertSeparator(self.keep_box.count())
        if self.prefer:
            self.keep_box.addItem(f"Preferring “{os.path.basename(self.prefer) or self.prefer}” — Change…", "prefer")
            self.keep_box.addItem("No Preferred Folder", "noprefer")
        else:
            self.keep_box.addItem("Prefer Copies in a Folder…", "prefer")
        self.keep_box.setCurrentIndex(max(0, self.keep_box.findData(self.keep_rule)))
        self.keep_box.setToolTip(D.KEEP_TIP[self.keep_rule] + (f"\nCopies in “{self.prefer}” are kept over copies "
                                                                "elsewhere." if self.prefer else ""))
        self.keep_box.blockSignals(False)

    def _keep_chosen(self) -> None:
        key = self.keep_box.currentData()
        if key == "prefer":
            folder = QFileDialog.getExistingDirectory(self, "Keep the Copies in This Folder", self.prefer or self.folder)
            if folder:
                self.prefer = folder
        elif key == "noprefer":
            self.prefer = None
        elif key in D.KEEP_RULES:
            self.keep_rule = key
            self.settings.setValue("duplicates/keep", key)
        self._fill_keep()
        for c in self.cards:
            c.refresh()

    def keeper(self, paths: list[str]) -> str:
        return D.keeper(paths, self.hooks.tags_of, self.keep_rule, self.pixels, self.dates, self.prefer)

    def rescan(self) -> None:
        if self.scanning:
            self.stop.set()
            QTimer.singleShot(150, self.rescan)
            return
        self.stop = threading.Event()
        self.scanning = True
        self.rescan_btn.setEnabled(False)
        self.stop_btn.setVisible(True)
        self.bar.setVisible(True)
        self.bar.setRange(0, 0)
        self.status.setText("Looking…")
        folder, recursive, frames, stop, nd = self.folders, self.recursive, self.exclude_frames, self.stop, \
            self.not_dupes
        threshold, all_files = D.STRICTNESS[self.strictness], self.all_files

        def work() -> None:
            groups = D.scan(folder, recursive, frames, nd, progress=self.bridge.progress.emit, stop=stop,
                            threshold=threshold, all_files=all_files)
            self.bridge.scanned.emit(None if stop.is_set() else groups)
        threading.Thread(target=work, daemon=True).start()

    def _progress(self, stage: str, done: int, total: int) -> None:
        if total:
            self.bar.setRange(0, total)
            self.bar.setValue(done)
            self.status.setText(f"{stage}… {done:,} of {total:,}")
        else:
            self.bar.setRange(0, 0)
            self.status.setText(f"{stage}…")

    def _scanned(self, groups) -> None:
        self.scanning = False
        self.rescan_btn.setEnabled(True)
        self.stop_btn.setVisible(False)
        self.bar.setVisible(False)
        if groups is None:
            self.status.setText("Stopped." + (" Showing the last look." if self.groups else ""))
            return
        self.groups = groups
        self.scanned_at = time.time()
        files = {p for g in groups for p in g.paths}
        self.selected &= files
        self.shown = PAGE
        self._render()
        n = len(groups)
        extra = sum(len(g.paths) - 1 for g in groups)
        self.status.setText(f"{n:,} group{'s' if n != 1 else ''} · {extra:,} extra cop{'ies' if extra != 1 else 'y'} · "
                            f"up to {human(sum(g.extra_bytes for g in groups))} to free." if n else
                            "No duplicates here — nothing shares a size and dimensions, looks alike, or has a "
                            "copy-style name." + (" (Turn on Include subfolders to look further.)"
                                                  if not self.recursive else ""))
        self._background(groups)

    def _background(self, groups: list[D.Group]) -> None:
        """Identical checks for exact groups, then the copies' dates — both off the main thread."""
        stop = self.stop
        bridge = self.bridge

        def work() -> None:
            for g in groups:
                if stop.is_set():
                    return
                if g.kind == "exact" and g.identical is None:
                    if D.check_identical(g, stop) is not None:
                        bridge.identical.emit(g)
            paths = list(dict.fromkeys(p for g in groups for p in g.paths))
            out: dict[str, float] = {}
            px: dict[str, tuple[int, int]] = {}

            def facts(p: str):                      # noqa: ANN202
                return (D.precise_date(p) if D.kind_of(p) != "other" else None), D.pixels_of(p)
            with ThreadPoolExecutor(max_workers=6) as pool:
                for i, (p, (d, wh)) in enumerate(zip(paths, pool.map(facts, paths))):
                    if stop.is_set():
                        return
                    if d is not None:
                        out[p] = d
                    if wh[0]:
                        px[p] = wh
                    if i % 400 == 399:              # a big library: the first cards fill in as it goes
                        bridge.dated.emit((dict(out), dict(px)))
            bridge.dated.emit((out, px))
        threading.Thread(target=work, daemon=True).start()

    def _identical(self, group: D.Group) -> None:
        for c in self.cards:
            if c.group is group:
                c.refresh()
        self._update_bar()

    def _dated(self, found) -> None:
        dates, pixels = found
        self.dates.update(dates)
        self.pixels.update(pixels)
        for c in self.cards:
            c.refresh()

    # ------------------------------------------------------------------ showing
    def _visible_groups(self) -> list[D.Group]:
        groups = self.groups if self.filter == "all" else [g for g in self.groups if g.kind == self.filter]
        if self.sort == "copies":
            return sorted(groups, key=lambda g: (-len(g.paths), g.rank, -g.extra_bytes))
        if self.sort == "name":
            return sorted(groups, key=lambda g: D._natural(os.path.basename(g.paths[0])))
        if self.sort == "folder":
            return sorted(groups, key=lambda g: (os.path.dirname(g.paths[0]).lower(),
                                                 D._natural(os.path.basename(g.paths[0]))))
        return groups                               # as scanned: strongest kind first, biggest payoff first

    def _set_filter(self, key: str) -> None:
        self.filter = key
        self.shown = PAGE
        self._render()

    def _render(self) -> None:
        for c in self.cards:
            c.setParent(None)
            c.deleteLater()
        self.cards = []
        while self.list.count():
            it = self.list.takeAt(0)
            w = it.widget()
            if w is not None:              # keep a hold until it's gone
                w.setParent(None)
                w.deleteLater()
        groups = self._visible_groups()
        for g in groups[:self.shown]:
            card = Card(g, self)
            self.cards.append(card)
            self.list.addWidget(card)
        if len(groups) > self.shown:
            more = QPushButton(f"Show {min(PAGE, len(groups) - self.shown)} More (of {len(groups) - self.shown:,})")
            more.clicked.connect(self._more)
            self.list.addWidget(more, 0, Qt.AlignmentFlag.AlignHCenter)
        if not groups and self.groups:
            empty = QLabel("None of this kind.")
            empty.setObjectName("SheetSub")
            self.list.addWidget(empty, 0, Qt.AlignmentFlag.AlignHCenter)
        self.list.addStretch(1)
        self._update_counts()
        self._update_bar()

    def _more(self) -> None:
        self.shown += PAGE
        top = self.scroll.verticalScrollBar().value()
        self._render()
        self.scroll.verticalScrollBar().setValue(top)

    def _update_counts(self) -> None:
        counts = {k: sum(1 for g in self.groups if g.kind == k) for k in D.KINDS}
        self.filter_btns["all"].setText(f"All ({len(self.groups):,})")
        for k in D.KINDS:
            self.filter_btns[k].setText(f"{D.KIND_LABEL[k]} ({counts[k]:,})")
            self.filter_btns[k].setVisible(counts[k] > 0 or self.filter == k)

    def _update_bar(self) -> None:
        n = len(self.selected)
        size = 0
        for p in self.selected:
            try:
                size += os.path.getsize(p)
            except OSError:
                pass
        self.summary.setText(f"{n:,} selected · {human(size)} would be freed" if n else
                             "Click the copies you don't want, then Move to Trash. Double-click to look closely.")
        self.trash_btn.setText(f"Move {n:,} to Trash" if n else "Move to Trash")
        self.trash_btn.setEnabled(n > 0 and self.hooks.trash is not None)
        self.clear_btn.setEnabled(n > 0)
        self.extra_acts["identical"].setEnabled(any(g.identical for g in self.groups))
        self.extra_acts["exact"].setEnabled(any(g.kind == "exact" for g in self.groups))
        self.extra_btn.setEnabled(bool(self.groups))

    def _repaint_tiles(self) -> None:
        for c in self.cards:
            for t in c.tiles.values():
                t.update()

    # ------------------------------------------------------------------ picking
    def toggle(self, path: str) -> None:
        self.set_selected([path], path not in self.selected)

    def set_selected(self, paths: list[str], on: bool) -> None:
        if on:
            self.selected.update(paths)
        else:
            self.selected.difference_update(paths)
        for c in self.cards:
            for p in paths:
                t = c.tiles.get(p)
                if t is not None:
                    t.selected = on
                    t.update()
        self._update_bar()

    def all_but_one(self, card: Card) -> None:
        keep, extra = self.keeper(card.group.paths), []
        extra = [p for p in card.group.paths if p != keep]
        self.set_selected(extra, True)
        self.set_selected([keep], False)

    def keep_only(self, card: Card, path: str) -> None:
        """A copy's right-click ▸ Keep Only This One: every other copy in its group is ticked."""
        self.set_selected([p for p in card.group.paths if p != path], True)
        self.set_selected([path], False)

    def select_extra(self, scope: str = "identical") -> None:
        """Every copy but the kept one (`keeper`) in each identical group — or each exact group, or each group
        shown under the current filter."""
        if scope == "identical":
            groups = [g for g in self.groups if g.identical]
        elif scope == "exact":
            groups = [g for g in self.groups if g.kind == "exact"]
        else:
            groups = self._visible_groups()
        ticked, kept = 0, set()
        for g in groups:
            keep = self.keeper(g.paths)
            kept.add(keep)
            extra = [p for p in g.paths if p != keep and p not in kept]
            self.set_selected(extra, True)
            ticked += len(extra)
        self.set_selected(list(kept), False)                # a copy kept by one group isn't trashed by another
        what = {"identical": "the identical groups", "exact": "the exact groups", "shown": "the groups shown"}[scope]
        self.status.setText(f"Ticked {ticked:,} extra cop{'ies' if ticked != 1 else 'y'} in {what} — one copy of each "
                            "kept (marked Keep). " + ("Check them, then Move to Trash." if scope != "shown" else
                                                      "Look-alikes aren't always copies: check them before the Trash."))

    def view(self, paths: list[str], start: str) -> None:
        if self.hooks.view is not None:
            self.hooks.view([p for p in paths if os.path.exists(p)] or paths, start)

    def not_duplicates(self, card: Card) -> None:
        self.not_dupes.mark(card.group.paths)
        self.set_selected(card.group.paths, False)
        self.groups = [g for g in self.groups if g is not card.group]
        self._render()
        self.status.setText("Marked as not duplicates — they won't be listed together again.")

    # ------------------------------------------------------------------ the trash
    def trash(self) -> None:
        if not self.selected or self.hooks.trash is None:
            return
        paths = sorted(self.selected)
        lost = [g for g in self.groups if set(g.paths) <= self.selected]
        box = QMessageBox(self)
        box.setIcon(QMessageBox.Icon.Warning)
        box.setWindowTitle("Move to Trash")
        box.setText(f"Move {len(paths):,} cop{'ies' if len(paths) != 1 else 'y'} to the Trash?")
        info = "They can be put back from the Trash."
        if lost:
            info = (f"Every copy in {len(lost):,} group{'s' if len(lost) != 1 else ''} is ticked — "
                    f"{'those photos' if len(lost) != 1 else 'that photo'} would be gone from here entirely. " + info)
        box.setInformativeText(info)
        # What's said about a copy that goes — its tags, Favorite, To AI — passes to the copy that stays.
        heirs: list[tuple[str, list[str]]] = []
        if self.hooks.inherit is not None:
            for g in self.groups:
                going = [p for p in g.paths if p in self.selected]
                staying = [p for p in g.paths if p not in self.selected]
                if going and staying:
                    heirs.append((self.keeper(staying), going))
        carry = QCheckBox("Give the kept copies the tags, Favorite and To AI of the copies that go")
        carry.setChecked(str(self.settings.value("duplicates/inherit", "true")) == "true")
        if heirs:
            box.setCheckBox(carry)
        go = box.addButton("Move to Trash", QMessageBox.ButtonRole.DestructiveRole)
        box.addButton(QMessageBox.StandardButton.Cancel)
        box.setDefaultButton(go)
        box.exec()
        if box.clickedButton() is not go:
            return
        if heirs:
            self.settings.setValue("duplicates/inherit", "true" if carry.isChecked() else "false")
            if carry.isChecked():
                for keep, going in heirs:
                    try:
                        self.hooks.inherit(keep, going)
                    except OSError:
                        pass
        moved = set(self.hooks.trash(paths))
        self.selected -= moved
        self.groups = [g2 for g in self.groups if (g2 := g.without(moved)) is not None]
        self._render()
        failed = len(paths) - len(moved)
        self.status.setText(f"Moved {len(moved):,} to the Trash." +
                            (f" {failed:,} couldn't be moved." if failed else ""))
        if self.hooks.changed is not None:
            self.hooks.changed()

    def remove_paths(self, gone: list[str]) -> None:
        """Files that left elsewhere (the viewer's Trash): out of the groups."""
        gone_set = set(gone)
        if not gone_set & {p for g in self.groups for p in g.paths}:
            return
        self.selected -= gone_set
        self.groups = [g2 for g in self.groups if (g2 := g.without(gone_set)) is not None]
        self._render()

    def closeEvent(self, event) -> None:  # noqa: N802
        self.stop.set()
        super().closeEvent(event)
