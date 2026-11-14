"""The Astria.ai Browser — everything your Astria account has made, to look through, search and download.

The iPhone app's browser (`AstriaBrowserView`): newest first, grouped by prompt, each group headed by its model,
date and prompt, its pictures in a tight grid. A ✓ marks what's already been downloaded. Made for a Mac:

- **Fast with thousands of pictures.** The grid is one painted, scrolling surface (`BrowserView`) that draws only
  what's on screen; thumbnails are fetched as they come into view, a few at a time, and kept on disk, so a second
  visit is instant. The listing itself is kept too: the window opens on what it showed last time and brings it up
  to date in the background, a page at a time.
- **Finding things.** The search field takes words and "phrases" from the prompt, the model or the date, `-word`
  to leave out, and `date:2026-10`, `before:`, `after:` (the search language of Safe Finder's own search —
  `search_query.py`). Beside it: one model, only what's new / only what's downloaded, newest or oldest first.
- **Picking.** Click selects; ⌘-click adds or removes one; ⇧-click takes the run between; the circle on a tile
  ticks it without touching the rest; a group's "Select All"; ⌘A for everything shown. Double-click or Space
  opens the viewer.
- **The viewer** (`ViewerWindow`): the picture as large as the window, ← → through everything shown, its model,
  date, size and whole prompt beside it; Download, Copy Prompt, Use Prompt (Create with AI, filled in), Copy Image.
- **Downloading** — one, the selection, or everything new: four at a time, with progress, Stop, and Retry for
  any that failed. **Where to** is a choice that's remembered (`Destination`): the folder Safe Finder is in, that
  folder's "AI" folder, any folder you choose, or one of the last few.
- **What a download is** (`astria.save_download`): the file exactly as Astria made it — nothing re-compressed,
  all of its own metadata kept — with the prompt, model, date and "AI-made" label added to its metadata, and the
  **AI** tag in Safe Finder (shared with the iPhone app).

Read-only on Astria's side: it lists and downloads. Nothing is uploaded and nothing there is changed.
"""
from __future__ import annotations

import bisect
import hashlib
import io
import json
import os
import threading
import time
from collections import OrderedDict
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from PySide6.QtCore import QObject, QPoint, QRect, QRectF, Qt, QTimer, Signal
from PySide6.QtGui import (QColor, QFont, QFontMetrics, QGuiApplication, QImage, QKeySequence, QPainter,
                           QPainterPath, QPen, QPixmap, QShortcut)
from PySide6.QtWidgets import (QAbstractScrollArea, QComboBox, QFileDialog, QFrame, QHBoxLayout, QLabel, QLineEdit,
                               QMenu, QPlainTextEdit, QProgressBar, QPushButton, QSlider, QVBoxLayout, QWidget)

import astria as A
import search_query
from ai_window import CLIENT, AIHooks, KeyRow, SettingsDialog, _small, _style

AI_TAG = "AI"
PAGE = 50                              # prompts asked for at a time
MAX_PAGES = 60                         # …and how many pages are read before "Load Older" is offered
GAP = 3


def _key(url: str) -> str:
    """A picture's identity: its address without the signature Astria's links carry."""
    return url.split("?")[0]


def _cache_file(url: str) -> Path:
    return A.THUMB_CACHE / (hashlib.sha256(_key(url).encode()).hexdigest() + ".jpg")


def _listing_file() -> Path:
    return A.THUMB_CACHE.parent / "astria-listing.json"


class Item:
    """One picture of one prompt — what's selected, viewed and downloaded."""
    __slots__ = ("prompt", "index", "url", "key", "sec", "n")

    def __init__(self, prompt: A.Prompt, index: int) -> None:
        self.prompt, self.index = prompt, index
        self.url = prompt.images[index]
        self.key = _key(self.url)
        self.sec = self.n = 0                              # which group it's drawn in, and where in it


# ============================================================================ where downloads go

class Destination:
    """The remembered choice of where downloads go: "current" (the folder Safe Finder is showing), "ai" (that
    folder's AI folder) or "fixed" (a folder that was chosen) — and the last few folders chosen."""

    def __init__(self, current) -> None:
        self._current = current                            # () → the folder Safe Finder is in

    def mode(self) -> str:
        d = A.store().get("browser_dest", {}) or {}
        m = d.get("mode")
        if m == "fixed" and not os.path.isdir(str(d.get("path") or "")):
            return "current"                               # the chosen folder is gone (a drive unplugged)
        return m if m in ("current", "ai", "fixed") else "current"

    def current_folder(self) -> str:
        return self._current()

    def folder(self) -> str:
        """Where a download goes now (for "ai", the folder is made when something is saved — `resolve`)."""
        m = self.mode()
        if m == "fixed":
            return str((A.store().get("browser_dest", {}) or {}).get("path"))
        cur = self.current_folder()
        return os.path.join(cur, "AI") if m == "ai" and os.path.basename(cur) != "AI" else cur

    def resolve(self) -> str:
        if self.mode() == "ai":
            return str(A.ai_folder(Path(self.current_folder())))
        return self.folder()

    def label(self) -> str:
        f = self.folder()
        name = os.path.basename(f.rstrip("/")) or f
        if self.mode() == "ai":
            return f"{os.path.basename(os.path.dirname(f)) or ''}/AI".lstrip("/")
        return name

    def choose(self, mode: str, path: str = "") -> None:
        A.store().set("browser_dest", {"mode": mode, "path": path})
        if mode == "fixed" and path:
            A.store().update("browser_recent", lambda r: ([path] + [x for x in (r or []) if x != path])[:6])
            A.store().set("last_folder", path)             # Create / Edit with AI's "last folder" follows

    def recent(self) -> list[str]:
        return [p for p in (A.store().get("browser_recent", []) or []) if isinstance(p, str) and os.path.isdir(p)]


# ============================================================================ the grid

class BrowserView(QAbstractScrollArea):
    """The prompts and their pictures as one scrolling surface, painted as it's scrolled."""
    opened = Signal(object)                    # Item
    menu_asked = Signal(object, object)        # Item, global QPoint
    changed = Signal()                         # the selection
    link = Signal(str, object)                 # "all" | "copy" | "use", Prompt

    MARGIN = 14

    def __init__(self, browser: "BrowserWindow") -> None:
        super().__init__()
        self.b = browser
        self.side_wanted = 170
        self.sections: list[dict] = []         # {"prompt", "items", "y", "head", "rows", "lines"}
        self.ys: list[int] = []
        self.flat: list[Item] = []
        self.pos: dict[str, int] = {}
        self.cols, self.side = 1, 170
        self.total = 0
        self.focus_i = -1
        self.anchor = -1
        self.hover: str | None = None
        self.grouped = True                    # a heading per prompt — or every picture in one grid
        self.setMouseTracking(True)
        self.viewport().setMouseTracking(True)
        self.setFocusPolicy(Qt.FocusPolicy.StrongFocus)
        self.setFrameShape(QFrame.Shape.NoFrame)
        self.verticalScrollBar().setSingleStep(40)
        self.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        self.setVerticalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOn)

    # -- layout
    def set_prompts(self, prompts: list[A.Prompt], keep_scroll: bool = True) -> None:
        y = self.verticalScrollBar().value()
        if self.grouped:
            self.sections = [{"prompt": p, "items": [Item(p, i) for i in range(len(p.images))]}
                             for p in prompts if p.images]
        else:                                              # All Pictures: one unbroken grid, no headings
            everything = [Item(p, i) for p in prompts for i in range(len(p.images))]
            self.sections = [{"prompt": None, "items": everything}] if everything else []
        self.flat = [it for s in self.sections for it in s["items"]]
        for si, s in enumerate(self.sections):
            for n, it in enumerate(s["items"]):
                it.sec, it.n = si, n
        self.pos = {it.key: i for i, it in enumerate(self.flat)}
        self.focus_i = min(self.focus_i, len(self.flat) - 1)
        self.relayout()
        self.verticalScrollBar().setValue(y if keep_scroll else 0)

    def relayout(self) -> None:
        w = max(200, self.viewport().width() - 2 * self.MARGIN)
        self.cols = max(1, (w + GAP) // (self.side_wanted + GAP))
        self.side = (w - (self.cols - 1) * GAP) // self.cols
        fm = QFontMetrics(self.font())
        y = 8
        self.ys = []
        for s in self.sections:
            if s["prompt"] is None:
                s["lines"], s["head"] = 0, 0
            else:
                text = " ".join(s["prompt"].text.split())
                lines = 0 if not text else (1 if fm.horizontalAdvance(text) <= w else 2)
                s["lines"] = lines
                s["head"] = fm.height() + 8 + lines * fm.height() + 6
            s["rows"] = -(-len(s["items"]) // self.cols)
            s["y"] = y
            self.ys.append(y)
            y += s["head"] + s["rows"] * (self.side + GAP) + 16
        self.total = y
        bar = self.verticalScrollBar()
        bar.setPageStep(self.viewport().height())
        bar.setRange(0, max(0, self.total - self.viewport().height()))
        self.viewport().update()

    def resizeEvent(self, event) -> None:  # noqa: N802
        super().resizeEvent(event)
        self.relayout()

    def scrollContentsBy(self, dx: int, dy: int) -> None:  # noqa: N802
        self.viewport().update()

    def _tile_rect(self, s: dict, i: int) -> QRect:
        r, c = divmod(i, self.cols)
        return QRect(self.MARGIN + c * (self.side + GAP), s["y"] + s["head"] + r * (self.side + GAP), self.side, self.side)

    def _links(self, s: dict) -> list[tuple[str, QRect]]:
        """The header's "Select All · Copy Prompt · Use Prompt", right-aligned, in content coordinates."""
        if s["prompt"] is None:
            return []
        fm = QFontMetrics(self.font())
        all_on = all(it.key in self.b.selected for it in s["items"])
        out = []
        x = self.viewport().width() - self.MARGIN
        for key, text in (("use", "Use Prompt"), ("copy", "Copy Prompt"), ("all", "Deselect" if all_on else "Select All")):
            tw = fm.horizontalAdvance(text) + 14
            x -= tw
            out.append((key, QRect(x, s["y"] + 2, tw, fm.height() + 4)))
            x -= 4
        return out

    def _hit(self, pos: QPoint) -> tuple[dict | None, int, str | None]:
        """(section, tile index or -1, header link or None) at a viewport point."""
        y = pos.y() + self.verticalScrollBar().value()
        i = bisect.bisect_right(self.ys, y) - 1
        if i < 0 or i >= len(self.sections):
            return None, -1, None
        s = self.sections[i]
        if y < s["y"] + s["head"]:
            for key, rect in self._links(s):
                if rect.contains(pos.x(), y):
                    return s, -1, key
            return s, -1, None
        row = (y - s["y"] - s["head"]) // (self.side + GAP)
        col = (pos.x() - self.MARGIN) // (self.side + GAP)
        if pos.x() < self.MARGIN or col >= self.cols or (pos.x() - self.MARGIN) % (self.side + GAP) >= self.side:
            return s, -1, None
        n = row * self.cols + col
        return (s, n, None) if 0 <= n < len(s["items"]) else (s, -1, None)

    def item_rect(self, item: Item) -> QRect | None:
        if 0 <= item.sec < len(self.sections) and item.n < len(self.sections[item.sec]["items"]):
            return self._tile_rect(self.sections[item.sec], item.n)
        return None

    def viewportEvent(self, event) -> bool:  # noqa: N802
        if event.type() == event.Type.ToolTip:             # the prompt, over any picture
            from PySide6.QtWidgets import QToolTip
            s, i, _link = self._hit(event.pos())
            if s is not None and i >= 0:
                p = s["items"][i].prompt
                text = " ".join(p.text.split())
                QToolTip.showText(event.globalPos(), f"{self.b.model_of(p)} · {self.b.when_text(p)}\n"
                                  + (text[:600] + "…" if len(text) > 600 else text), self.viewport())
            else:
                QToolTip.hideText()
            return True
        return super().viewportEvent(event)

    def reveal(self, item: Item) -> None:
        r = self.item_rect(item)
        if r is None:
            return
        bar = self.verticalScrollBar()
        top, h = bar.value(), self.viewport().height()
        if r.top() - 60 < top:
            bar.setValue(max(0, r.top() - 60))
        elif r.bottom() + 20 > top + h:
            bar.setValue(r.bottom() + 20 - h)

    # -- painting
    def paintEvent(self, _event) -> None:  # noqa: N802
        p = QPainter(self.viewport())
        p.setRenderHint(QPainter.RenderHint.Antialiasing)
        p.setRenderHint(QPainter.RenderHint.SmoothPixmapTransform)
        th = self.b.theme
        top = self.verticalScrollBar().value()
        h = self.viewport().height()
        p.translate(0, -top)
        fm = QFontMetrics(self.font())
        bold = QFont(self.font())
        bold.setWeight(QFont.Weight.DemiBold)
        first = max(0, bisect.bisect_right(self.ys, top) - 1)
        width = self.viewport().width() - 2 * self.MARGIN
        if not self.sections:
            p.setPen(QColor(th.secondary))
            p.drawText(QRect(0, top, self.viewport().width(), h), Qt.AlignmentFlag.AlignCenter, self.b.empty_text())
        for s in self.sections[first:]:
            if s["y"] > top + h:
                break
            pr = s["prompt"]
            if pr is None:                                 # All Pictures: tiles only
                r0 = max(0, (top - s["y"]) // (self.side + GAP))
                r1 = min(s["rows"], (top + h - s["y"]) // (self.side + GAP) + 1)
                for i in range(r0 * self.cols, min(len(s["items"]), r1 * self.cols)):
                    self._paint_tile(p, s["items"][i], self._tile_rect(s, i))
                continue
            # header
            links = self._links(s)
            left_room = (links[-1][1].left() if links else self.viewport().width()) - self.MARGIN - 10
            p.setFont(bold)
            p.setPen(QColor(th.text))
            model = self.b.model_of(pr)
            mw = QFontMetrics(bold).horizontalAdvance(model)
            p.drawText(QRect(self.MARGIN, s["y"] + 2, left_room, fm.height() + 4), Qt.AlignmentFlag.AlignVCenter, model)
            p.setFont(self.font())
            p.setPen(QColor(th.secondary))
            saved = sum(1 for it in s["items"] if self.b.is_saved(it.key))
            bits = [self.b.when_text(pr), f"{len(s['items'])} image{'s' if len(s['items']) != 1 else ''}"]
            if saved:
                bits.append("all downloaded" if saved == len(s["items"]) else f"{saved} downloaded")
            p.drawText(QRect(self.MARGIN + mw + 10, s["y"] + 2, max(0, left_room - mw - 10), fm.height() + 4),
                       Qt.AlignmentFlag.AlignVCenter, fm.elidedText("  ·  ".join(b for b in bits if b),
                                                                    Qt.TextElideMode.ElideRight, max(0, left_room - mw - 10)))
            for key, rect in links:
                p.setPen(QColor(th.accent))
                p.drawText(rect, Qt.AlignmentFlag.AlignCenter, {"use": "Use Prompt", "copy": "Copy Prompt"}.get(
                    key, "Deselect" if all(it.key in self.b.selected for it in s["items"]) else "Select All"))
            if s["lines"]:
                p.setPen(QColor(th.secondary))
                text = " ".join(pr.text.split())
                rect = QRect(self.MARGIN, s["y"] + fm.height() + 8, width, s["lines"] * fm.height())
                if s["lines"] == 1:
                    p.drawText(rect, Qt.AlignmentFlag.AlignLeft | Qt.AlignmentFlag.AlignTop, text)
                else:
                    cut = self._wrap_two(fm, text, width)
                    p.drawText(rect, Qt.AlignmentFlag.AlignLeft | Qt.AlignmentFlag.AlignTop, cut)
            # tiles
            r0 = max(0, (top - s["y"] - s["head"]) // (self.side + GAP))
            r1 = min(s["rows"], (top + h - s["y"] - s["head"]) // (self.side + GAP) + 1)
            for i in range(r0 * self.cols, min(len(s["items"]), r1 * self.cols)):
                self._paint_tile(p, s["items"][i], self._tile_rect(s, i))
        p.end()

    @staticmethod
    def _wrap_two(fm: QFontMetrics, text: str, width: int) -> str:
        words = text.split(" ")
        line = ""
        for n, w in enumerate(words):
            trial = (line + " " + w).strip()
            if fm.horizontalAdvance(trial) > width and line:
                rest = " ".join(words[n:])
                return line + "\n" + fm.elidedText(rest, Qt.TextElideMode.ElideRight, width)
            line = trial
        return line

    def _paint_tile(self, p: QPainter, item: Item, rect: QRect) -> None:
        th = self.b.theme
        r = QRectF(rect)
        p.fillRect(r, QColor("#2C2C2E") if th.dark else QColor("#E5E5EA"))
        pm = self.b.thumb(item)
        if pm is not None:
            s = max(r.width() / pm.width(), r.height() / pm.height())
            sw, sh = r.width() / s, r.height() / s
            p.drawPixmap(r, pm, QRectF((pm.width() - sw) / 2, (pm.height() - sh) / 2, sw, sh))
        selected = item.key in self.b.selected
        if selected:
            p.fillRect(r, QColor(255, 255, 255, 50))
            p.setPen(QPen(QColor(th.accent), 3))
            p.setBrush(Qt.BrushStyle.NoBrush)
            p.drawRect(r.adjusted(1.5, 1.5, -1.5, -1.5))
        if self.focus_i >= 0 and self.flat[self.focus_i] is item and self.hasFocus() and not selected:
            p.setPen(QPen(QColor(th.accent), 1.5, Qt.PenStyle.DashLine))
            p.setBrush(Qt.BrushStyle.NoBrush)
            p.drawRect(r.adjusted(1, 1, -1, -1))
        d = 22.0
        if selected or self.hover == item.key:              # the circle that ticks one without touching the rest
            ring = QRectF(r.left() + 7, r.top() + 7, d, d)
            p.setPen(QPen(QColor("white"), 1.6))
            p.setBrush(QColor(th.accent) if selected else QColor(0, 0, 0, 90))
            p.drawEllipse(ring)
            if selected:
                self._tick(p, ring, QColor(getattr(th, "on_accent", "#FFFFFF")))
        if self.b.is_saved(item.key):
            ring = QRectF(r.right() - d - 6, r.bottom() - d - 6, d, d)
            p.setPen(QPen(QColor("white"), 1.4))
            p.setBrush(QColor("#30D158"))
            p.drawEllipse(ring)
            self._tick(p, ring, QColor("white"))

    @staticmethod
    def _tick(p: QPainter, ring: QRectF, color: QColor) -> None:
        d = ring.width()
        path = QPainterPath()
        path.moveTo(ring.left() + d * 0.28, ring.top() + d * 0.53)
        path.lineTo(ring.left() + d * 0.44, ring.top() + d * 0.69)
        path.lineTo(ring.left() + d * 0.74, ring.top() + d * 0.34)
        p.setPen(QPen(color, 2.1, Qt.PenStyle.SolidLine, Qt.PenCapStyle.RoundCap, Qt.PenJoinStyle.RoundJoin))
        p.setBrush(Qt.BrushStyle.NoBrush)
        p.drawPath(path)

    # -- mouse and keys
    def _in_circle(self, s: dict, i: int, pos: QPoint) -> bool:
        r = self._tile_rect(s, i)
        y = pos.y() + self.verticalScrollBar().value()
        return QRect(r.left() + 3, r.top() + 3, 32, 32).contains(pos.x(), y)

    def mouseMoveEvent(self, event) -> None:  # noqa: N802
        s, i, link = self._hit(event.position().toPoint())
        key = s["items"][i].key if s is not None and i >= 0 else None
        if key != self.hover:
            self.hover = key
            self.viewport().update()
        self.viewport().setCursor(Qt.CursorShape.PointingHandCursor if (link or key) else Qt.CursorShape.ArrowCursor)

    def leaveEvent(self, event) -> None:  # noqa: N802
        self.hover = None
        self.viewport().update()

    def mousePressEvent(self, event) -> None:  # noqa: N802
        self.setFocus()
        pos = event.position().toPoint()
        s, i, link = self._hit(pos)
        if s is None:
            return
        if link:
            if event.button() == Qt.MouseButton.LeftButton:
                self.link.emit(link, s["prompt"])
            return
        if i < 0:
            if event.button() == Qt.MouseButton.LeftButton and not event.modifiers():
                self.b.select_only([])
            return
        item = s["items"][i]
        n = self.pos[item.key]
        mods = event.modifiers()
        if event.button() == Qt.MouseButton.RightButton:
            if item.key not in self.b.selected:
                self.b.select_only([item])
            self.focus_i = n
            self.menu_asked.emit(item, event.globalPosition().toPoint())
            return
        if event.button() != Qt.MouseButton.LeftButton:
            return
        if mods & Qt.KeyboardModifier.ShiftModifier and self.anchor >= 0:
            lo, hi = sorted((self.anchor, n))
            self.b.select_add(self.flat[lo:hi + 1])
        elif mods & (Qt.KeyboardModifier.ControlModifier | Qt.KeyboardModifier.MetaModifier) or self._in_circle(s, i, pos):
            self.b.toggle(item)
            self.anchor = n
        else:
            self.b.select_only([item])
            self.anchor = n
        self.focus_i = n

    def mouseDoubleClickEvent(self, event) -> None:  # noqa: N802
        s, i, link = self._hit(event.position().toPoint())
        if s is not None and i >= 0 and not link and event.button() == Qt.MouseButton.LeftButton:
            self.opened.emit(s["items"][i])

    def keyPressEvent(self, event) -> None:  # noqa: N802
        key = event.key()
        if not self.flat:
            return super().keyPressEvent(event)
        step = {Qt.Key.Key_Left: -1, Qt.Key.Key_Right: 1, Qt.Key.Key_Up: -self.cols, Qt.Key.Key_Down: self.cols}.get(key)
        if step is not None:
            n = max(0, min(len(self.flat) - 1, (self.focus_i if self.focus_i >= 0 else 0) + step))
            self.focus_i = n
            if event.modifiers() & Qt.KeyboardModifier.ShiftModifier and self.anchor >= 0:
                lo, hi = sorted((self.anchor, n))
                self.b.select_only(self.flat[lo:hi + 1])
            else:
                self.b.select_only([self.flat[n]])
                self.anchor = n
            self.reveal(self.flat[n])
        elif key in (Qt.Key.Key_Space, Qt.Key.Key_Return, Qt.Key.Key_Enter) and self.focus_i >= 0:
            self.opened.emit(self.flat[self.focus_i])
        elif key == Qt.Key.Key_Escape:
            self.b.select_only([])
        else:
            super().keyPressEvent(event)


# ============================================================================ the window

class _Bridge(QObject):
    tunes = Signal(object)
    page = Signal(object, int, bool)           # prompts, the offset they start at, was that the last page
    listing_failed = Signal(str)
    thumb = Signal(str, bytes)
    full = Signal(str, bytes)
    saved = Signal(object, str, str)           # Item, the new file ("" = failed), how
    batch_done = Signal()


class BrowserWindow(QWidget):
    def __init__(self, folder: str, hooks: AIHooks, theme, parent=None) -> None:
        super().__init__(parent, Qt.WindowType.Window)
        self.setAttribute(Qt.WidgetAttribute.WA_DeleteOnClose)
        self.folder, self.hooks, self.theme = folder, hooks, theme
        self.dest = Destination(lambda: (hooks.current_folder() if hooks.current_folder else "") or self.folder)
        self.prompts: dict[int, A.Prompt] = {}
        self.tunes: list[A.Tune] = []
        self.selected: set[str] = set()
        self.thumbs: OrderedDict[str, QPixmap] = OrderedDict()
        self.wanted: set[str] = set()
        self.saved_map: dict[str, str] = dict(A.store().get("saved", {}) or {})
        self._saved_ok: dict[str, tuple[float, bool]] = {}
        self.loading = False
        self.exhausted = False
        self.next_offset = 0
        self.load_note = ""
        self.pool = ThreadPoolExecutor(max_workers=6)
        self.savers = ThreadPoolExecutor(max_workers=4)
        self.stop = threading.Event()
        self.stop_batch = threading.Event()
        self.batch_total = self.batch_done = 0
        self.batch_saved: list[str] = []
        self.batch_failed: list[Item] = []
        self.batch_kept = 0
        self.viewer: ViewerWindow | None = None
        self.bridge = _Bridge()
        self.bridge.tunes.connect(self._got_tunes)
        self.bridge.page.connect(self._got_page)
        self.bridge.listing_failed.connect(self._listing_failed)
        self.bridge.thumb.connect(self._got_thumb)
        self.bridge.saved.connect(self._one_saved)
        self.setWindowTitle("Astria.ai Browser")
        self.setStyleSheet(_style(theme))
        self.resize(1120, 820)

        v = QVBoxLayout(self)
        v.setContentsMargins(0, 0, 0, 0)
        v.setSpacing(0)
        top = QFrame()
        tv = QVBoxLayout(top)
        tv.setContentsMargins(16, 12, 16, 8)
        tv.setSpacing(8)
        row = QHBoxLayout()
        row.setSpacing(8)
        title = QLabel("Astria.ai Browser")
        title.setObjectName("SheetTitle")
        row.addWidget(title)
        row.addStretch(1)
        self.search = QLineEdit()
        self.search.setObjectName("Search")
        self.search.setPlaceholderText("Search prompts, models, dates")
        self.search.setClearButtonEnabled(True)
        self.search.setMinimumWidth(280)
        self.search.setToolTip("Words from the prompt, the model or the date — all must match.\n"
                               "“golden hour” together · -blurry not this · date:2026-10 · before:2026 · after:2026-06")
        row.addWidget(self.search)
        self.model_box = QComboBox()
        self.model_box.addItem("All Models", "")
        self.show_box = QComboBox()
        for label, key in (("Everything", ""), ("Not Downloaded", "new"), ("Downloaded", "saved")):
            self.show_box.addItem(label, key)
        self.sort_box = QComboBox()
        for label, key in (("Newest First", "new"), ("Oldest First", "old")):
            self.sort_box.addItem(label, key)
        self.layout_box = QComboBox()
        for label, key in (("By Prompt", "prompt"), ("All Pictures", "grid")):
            self.layout_box.addItem(label, key)
        self.layout_box.setToolTip("A heading for each prompt — or every picture in one grid")
        self.layout_box.setCurrentIndex(max(0, self.layout_box.findData(A.store().get("browser_layout", "prompt"))))
        for box in (self.model_box, self.show_box, self.sort_box, self.layout_box):
            box.currentIndexChanged.connect(lambda _i: self.refilter(reset=True))
            row.addWidget(box)
        tv.addLayout(row)
        row2 = QHBoxLayout()
        row2.setSpacing(8)
        self.status = _small("", wrap=False)
        row2.addWidget(self.status, 1)
        row2.addWidget(_small("Size", wrap=False))
        self.size = QSlider(Qt.Orientation.Horizontal)
        self.size.setRange(90, 360)
        self.size.setValue(int(A.store().get("browser_size", 170) or 170))
        self.size.setFixedWidth(110)
        self.size.valueChanged.connect(self._size_changed)
        row2.addWidget(self.size)
        self.older_btn = QPushButton("Load Older")
        self.older_btn.setToolTip("Read further back in your account's history")
        self.older_btn.clicked.connect(lambda: self.load(more=True))
        self.older_btn.setVisible(False)
        reload_btn = QPushButton("Reload")
        reload_btn.clicked.connect(lambda: self.load())
        gear = QPushButton("Astria Settings…")
        gear.clicked.connect(self._settings)
        for b in (self.older_btn, reload_btn, gear):
            row2.addWidget(b)
        tv.addLayout(row2)
        self.key_row = KeyRow()
        self.key_row.saved.connect(lambda: (self.key_row.setVisible(False), self.load()))
        self.key_row.setVisible(not A.get_key())
        tv.addWidget(self.key_row)
        v.addWidget(top)

        self.view = BrowserView(self)
        self.view.side_wanted = self.size.value()
        self.view.opened.connect(self.open_viewer)
        self.view.menu_asked.connect(self._menu)
        self.view.link.connect(self._header_link)
        v.addWidget(self.view, 1)

        bar = QFrame()
        bar.setObjectName("AIBar")
        bv = QVBoxLayout(bar)
        bv.setContentsMargins(16, 8, 16, 10)
        bv.setSpacing(6)
        self.progress = QProgressBar()
        self.progress.setTextVisible(False)
        self.progress.setVisible(False)
        bv.addWidget(self.progress)
        bh = QHBoxLayout()
        bh.setSpacing(8)
        self.summary = _small("", wrap=False)
        bh.addWidget(self.summary, 1)
        self.show_btn = QPushButton("Show in Safe Finder")
        self.show_btn.setVisible(False)
        self.show_btn.clicked.connect(self._show_last)
        self.retry_btn = QPushButton("")
        self.retry_btn.setVisible(False)
        self.retry_btn.clicked.connect(lambda: self.download(list(self.batch_failed)))
        self.stop_btn = QPushButton("Stop")
        self.stop_btn.setVisible(False)
        self.stop_btn.clicked.connect(self.stop_batch.set)
        self.clear_btn = QPushButton("Deselect")
        self.clear_btn.clicked.connect(lambda: self.select_only([]))
        self.dest_btn = QPushButton()
        self.dest_btn.setToolTip("Where downloads go — remembered")
        dest_menu = QMenu(self.dest_btn)
        dest_menu.aboutToShow.connect(lambda m=dest_menu: self._fill_dest_menu(m))
        self.dest_btn.setMenu(dest_menu)
        self.go_btn = QPushButton("Download")
        self.go_btn.setObjectName("Primary")
        self.go_btn.clicked.connect(self._download_clicked)
        for b in (self.show_btn, self.retry_btn, self.stop_btn, self.clear_btn, self.dest_btn, self.go_btn):
            bh.addWidget(b)
        bv.addLayout(bh)
        v.addWidget(bar)

        self._search_soon = QTimer(self)
        self._search_soon.setSingleShot(True)
        self._search_soon.setInterval(180)
        self._search_soon.timeout.connect(lambda: self.refilter(reset=True))
        self.search.textChanged.connect(lambda _t: self._search_soon.start())
        for keys, slot in (("Ctrl+A", self.select_all), ("Ctrl+F", lambda: (self.search.setFocus(), self.search.selectAll())),
                           ("Ctrl+R", lambda: self.load()), ("Ctrl+D", self._download_clicked)):
            QShortcut(QKeySequence(keys), self).activated.connect(slot)
        self._load_cache()
        self.refilter(reset=True)
        self.load()

    # -- what's shown
    def model_of(self, p: A.Prompt) -> str:
        return A.model_name(p.tune_id, self.tunes)

    @staticmethod
    def when_text(p: A.Prompt) -> str:
        return time.strftime("%b %-d, %Y %H:%M", time.localtime(p.created)) if p.created else ""

    def empty_text(self) -> str:
        if not A.get_key():
            return "Add your Astria API key above to see what your account has made."
        if self.loading and not self.prompts:
            return "Loading your generations…"
        if self.prompts:
            return "Nothing matches — clear the search or the filters."
        return self.load_note or "No generations on this account yet."

    def is_saved(self, key: str) -> bool:
        path = self.saved_map.get(key)
        if not path:
            return False
        hit = self._saved_ok.get(key)
        now = time.monotonic()
        if hit and now - hit[0] < 20:
            return hit[1]
        ok = os.path.exists(path)
        self._saved_ok[key] = (now, ok)
        return ok

    def _matches(self, p: A.Prompt, terms, without, span, model: str, show: str) -> bool:
        if not p.images:
            return False
        name = self.model_of(p)
        if model and name != model:
            return False
        if span is not None and not (p.created and (span[0] is None or p.created >= span[0])
                                     and (span[1] is None or p.created < span[1])):
            return False
        if terms or without:
            when = time.strftime("%Y-%m-%d %B %b %A", time.localtime(p.created)) if p.created else ""
            hay = search_query.forms(f"{p.text} {name} {when} {p.id}")
            if not all(search_query.has(t, hay) for t in terms) or any(search_query.has(t, hay) for t in without):
                return False
        if show:
            saved = [self.is_saved(_key(u)) for u in p.images]
            if show == "new" and all(saved):
                return False
            if show == "saved" and not any(saved):
                return False
        return True

    def refilter(self, reset: bool = False) -> None:
        terms, without = [], []
        span: tuple | None = None
        for key, value, neg in search_query.tokens(self.search.text()):
            if key in ("date", "before", "after"):
                r = search_query.date_range(value.lower())
                if r is not None:
                    lo, hi = span or (None, None)
                    span = (lo, r[0]) if key == "before" else (r[1], hi) if key == "after" else r
                continue
            text = search_query.fold(f"{key}:{value}" if key else value)
            (without if neg else terms).append(text)
        model, show = self.model_box.currentData() or "", self.show_box.currentData() or ""
        prompts = sorted(self.prompts.values(), key=lambda p: (p.created or 0, p.id),
                         reverse=self.sort_box.currentData() != "old")
        grouped = self.layout_box.currentData() != "grid"
        if grouped != self.view.grouped:
            self.view.grouped = grouped
            A.store().set("browser_layout", "prompt" if grouped else "grid")
        shown = [p for p in prompts if self._matches(p, terms, without, span, model, show)]
        self.view.set_prompts(shown, keep_scroll=not reset)
        live = {it.key for it in self.view.flat}
        if self.selected - live:
            self.selected &= live
        self._update_status()
        self._update_bar()
        if self.viewer is not None:
            self.viewer.relist()

    def _update_status(self) -> None:
        n_prompts, n_images = len({it.prompt.id for it in self.view.flat}), len(self.view.flat)
        saved = sum(1 for it in self.view.flat if self.is_saved(it.key))
        text = f"{n_prompts:,} prompt{'s' if n_prompts != 1 else ''} · {n_images:,} image{'s' if n_images != 1 else ''}"
        if saved:
            text += f" · {saved:,} downloaded"
        if len(self.prompts) != n_prompts:
            text += f"   (of {len(self.prompts):,} prompts)"
        if self.loading:
            text += "   ·   updating…"
        elif self.load_note:
            text += "   ·   " + self.load_note
        self.status.setText(text)
        self.older_btn.setVisible(not self.loading and not self.exhausted and bool(self.prompts))

    def _size_changed(self, px: int) -> None:
        A.store().set("browser_size", px)
        self.view.side_wanted = px
        self.view.relayout()

    # -- the listing
    def _load_cache(self) -> None:
        try:
            doc = json.loads(_listing_file().read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return
        for d in doc.get("prompts") or []:
            try:
                p = A.Prompt(int(d["id"]), str(d.get("text") or ""), d.get("tune"), d.get("created"),
                             [str(u) for u in d.get("images") or []], d.get("n"))
            except (KeyError, TypeError, ValueError):
                continue
            self.prompts[p.id] = p
        self.tunes = [A.Tune(int(t["id"]), str(t.get("title") or ""), str(t.get("name") or ""), str(t.get("branch") or ""),
                             str(t.get("model_type") or ""), str(t.get("token") or ""), True, t.get("base"))
                      for t in doc.get("tunes") or [] if isinstance(t, dict) and "id" in t]
        self._fill_models()

    def _save_cache(self) -> None:
        doc = {"prompts": [{"id": p.id, "text": p.text, "tune": p.tune_id, "created": p.created, "images": p.images,
                            "n": p.num_images} for p in self.prompts.values()],
               "tunes": [{"id": t.id, "title": t.title, "name": t.name, "branch": t.branch, "model_type": t.model_type,
                          "token": t.token, "base": t.base_tune_id} for t in self.tunes]}
        try:
            f = _listing_file()
            f.parent.mkdir(parents=True, exist_ok=True)
            tmp = f.with_suffix(".saving")
            tmp.write_text(json.dumps(doc), encoding="utf-8")
            os.replace(tmp, f)
        except OSError:
            pass

    def load(self, more: bool = False) -> None:
        """Reads the account's prompts a page at a time, showing them as they come. `more`: carry on further back
        from where the last read stopped."""
        if self.loading:
            return
        if not A.get_key():
            self.view.viewport().update()
            return
        self.loading = True
        self.load_note = ""
        start = self.next_offset if more else 0
        if not more:
            self._seen: set[int] = set()
            self._from_top = True                          # a read from the newest on: at its end, what wasn't seen is gone
        self._update_status()
        bridge, stop = self.bridge, self.stop

        def work() -> None:
            c = CLIENT()
            try:
                if not more:
                    bridge.tunes.emit(c.list_tunes())
                offset = start
                for _ in range(MAX_PAGES):
                    if stop.is_set():
                        return
                    page = c.prompt_page(offset, PAGE)
                    if page is None:
                        if offset == 0:                    # the account-wide listing isn't there: the long way round
                            everything = c.list_prompts()
                            bridge.page.emit(everything, 0, False)
                            bridge.page.emit([], len(everything), False)
                        else:
                            bridge.listing_failed.emit("Astria stopped answering part-way — Reload to carry on.")
                        return
                    last = len(page) < PAGE
                    bridge.page.emit(page, offset, last)
                    if last:
                        return
                    offset += len(page)
                bridge.page.emit([], offset, False)
            except Exception as e:  # noqa: BLE001 — whatever went wrong, the window says so
                bridge.listing_failed.emit(f"Astria couldn't be read ({e}).")
        self.pool.submit(work)

    def _got_tunes(self, tunes) -> None:
        self.tunes = list(tunes)
        self._fill_models()

    def _fill_models(self) -> None:
        was = self.model_box.currentData() or ""
        names = sorted({self.model_of(p) for p in self.prompts.values() if p.images}, key=str.casefold)
        self.model_box.blockSignals(True)
        self.model_box.clear()
        self.model_box.addItem("All Models", "")
        for n in names:
            self.model_box.addItem(n, n)
        self.model_box.setCurrentIndex(max(0, self.model_box.findData(was)))
        self.model_box.blockSignals(False)

    def _got_page(self, page, offset: int, last: bool) -> None:
        for p in page:
            self.prompts[p.id] = p                         # fresh links replace the kept ones
            self._seen.add(p.id)
        self.next_offset = offset + len(page)
        done = last or not page
        if last and getattr(self, "_from_top", False):
            # Read from the newest to the very end: what wasn't seen is gone from the account.
            for pid in [pid for pid in self.prompts if pid not in self._seen]:
                del self.prompts[pid]
        if done:
            self.loading = False
            self.exhausted = last
            self._save_cache()
        self._fill_models()
        self.refilter()

    def _listing_failed(self, why: str) -> None:
        self.loading = False
        self._from_top = False
        self.load_note = why
        self._update_status()
        self.view.viewport().update()

    def _settings(self) -> None:
        if SettingsDialog(self).exec():
            self.key_row.setVisible(not A.get_key())
            self.load()

    # -- thumbnails
    def thumb(self, item: Item) -> QPixmap | None:
        pm = self.thumbs.get(item.key)
        if pm is not None:
            self.thumbs.move_to_end(item.key)
            return pm
        if item.key not in self.wanted:
            self.wanted.add(item.key)
            url, key, bridge, stop = item.url, item.key, self.bridge, self.stop

            def work() -> None:
                if stop.is_set():
                    return
                path = _cache_file(url)
                try:
                    data = path.read_bytes()
                except OSError:
                    data = CLIENT().download(url, attempts=2)
                    if not data:
                        bridge.thumb.emit(key, b"")
                        return
                    try:
                        from PIL import Image, ImageOps
                        with Image.open(io.BytesIO(data)) as im:
                            im = ImageOps.exif_transpose(im).convert("RGB")
                            im.thumbnail((480, 480))
                            buf = io.BytesIO()
                            im.save(buf, "JPEG", quality=85)
                            data = buf.getvalue()
                        path.parent.mkdir(parents=True, exist_ok=True)
                        path.write_bytes(data)
                    except Exception:  # noqa: BLE001 — shown from the full download this time
                        pass
                bridge.thumb.emit(key, data)
            self.pool.submit(work)
        return None

    def _got_thumb(self, key: str, data: bytes) -> None:
        if not data:
            self.wanted.discard(key)                       # asked again the next time it's on screen
            return
        img = QImage.fromData(data)
        if img.isNull():
            return
        self.thumbs[key] = QPixmap.fromImage(img)
        while len(self.thumbs) > 1500:
            old, _pm = self.thumbs.popitem(last=False)
            self.wanted.discard(old)
        self.view.viewport().update()

    # -- selection
    def select_only(self, items: list[Item]) -> None:
        self.selected = {it.key for it in items}
        self._selection_changed()

    def select_add(self, items: list[Item]) -> None:
        self.selected |= {it.key for it in items}
        self._selection_changed()

    def toggle(self, item: Item) -> None:
        self.selected ^= {item.key}
        self._selection_changed()

    def select_all(self) -> None:
        self.select_only(self.view.flat)

    def _selection_changed(self) -> None:
        self.view.viewport().update()
        self._update_bar()
        if self.viewer is not None:
            self.viewer.refresh_buttons()

    def chosen(self) -> list[Item]:
        return [it for it in self.view.flat if it.key in self.selected]

    def new_items(self) -> list[Item]:
        return [it for it in self.view.flat if not self.is_saved(it.key)]

    def _update_bar(self) -> None:
        n = len(self.selected)
        busy = self.batch_total > self.batch_done
        self.dest_btn.setText(f"Download to: “{self.dest.label()}”")
        if n:
            self.go_btn.setText(f"Download {n:,} Selected")
        else:
            fresh = len(self.new_items())
            self.go_btn.setText(f"Download All {fresh:,} New" if fresh else "Everything Is Downloaded")
        self.go_btn.setEnabled(not busy and (n > 0 or bool(self.new_items())))
        self.clear_btn.setVisible(n > 0)
        if not busy and not self.batch_saved and not self.batch_failed:
            self.summary.setText(f"{n:,} selected" if n else "Click to select · double-click or Space to view")

    def _header_link(self, what: str, prompt: A.Prompt) -> None:
        items = [it for it in self.view.flat if it.prompt.id == prompt.id]
        if what == "all":
            if all(it.key in self.selected for it in items):
                self.selected -= {it.key for it in items}
                self._selection_changed()
            else:
                self.select_add(items)
        elif what == "copy":
            QGuiApplication.clipboard().setText(prompt.text)
            self.summary.setText("Prompt copied.")
        elif what == "use":
            self.use_prompt(prompt)

    def use_prompt(self, prompt: A.Prompt) -> None:
        if self.hooks.create is None:
            return
        settings = dict(A.store().get("run_create", {}) or {})
        settings["prompt"] = prompt.text
        name = self.model_of(prompt)
        if name in A.MODELS:
            settings["model"] = name
        self.hooks.create(settings)

    # -- where downloads go
    def _fill_dest_menu(self, menu: QMenu) -> None:
        menu.clear()
        self._update_bar()
        mode, here = self.dest.mode(), self.dest.current_folder()
        name = os.path.basename(here.rstrip("/")) or here

        def add(label: str, checked: bool, slot) -> None:
            a = menu.addAction(label, slot)
            a.setCheckable(True)
            a.setChecked(checked)
        add(f"This Folder — “{name}”", mode == "current", lambda: self._set_dest("current"))
        if os.path.basename(here) != "AI":
            add(f"Its AI Folder — “{name}/AI”", mode == "ai", lambda: self._set_dest("ai"))
        fixed = self.dest.folder() if mode == "fixed" else ""
        recent = self.dest.recent()
        if recent:
            menu.addSeparator()
            for path in recent:
                add(f"“{os.path.basename(path.rstrip('/')) or path}”   {os.path.dirname(path)}", path == fixed,
                    lambda path=path: self._set_dest("fixed", path))
        menu.addSeparator()
        menu.addAction("Choose Folder…", self._choose_dest)
        note = menu.addAction("The choice is remembered. “This Folder” follows the folder Safe Finder is showing.")
        note.setEnabled(False)

    def _set_dest(self, mode: str, path: str = "") -> None:
        self.dest.choose(mode, path)
        self._update_bar()
        if self.viewer is not None:
            self.viewer.refresh_buttons()

    def _choose_dest(self) -> bool:
        start = self.dest.folder() if os.path.isdir(self.dest.folder()) else self.dest.current_folder()
        folder = QFileDialog.getExistingDirectory(self, "Download To", start)
        if not folder:
            return False
        self._set_dest("fixed", folder)
        return True

    # -- downloading
    ASK_ABOVE = 50                             # a batch this big is asked about first

    def _download_clicked(self) -> None:
        items = self.chosen() or self.new_items()
        if not items:
            return
        if len(items) > self.ASK_ABOVE:
            from PySide6.QtWidgets import QMessageBox
            if QMessageBox.question(self, "Astria.ai Browser", f"Download {len(items):,} pictures to "
                                    f"“{self.dest.label()}”?\n\nThey come down four at a time; Stop ends it, and "
                                    "what's already down is skipped next time.") != QMessageBox.StandardButton.Yes:
                return
        self.download(items)

    def download(self, items: list[Item], data: dict[str, bytes] | None = None) -> None:
        """Takes `items` down into the remembered place. `data`: pictures already in hand (the viewer's), by key."""
        if not items:
            return
        try:
            folder = self.dest.resolve()
        except OSError as e:
            self.summary.setText(f"The folder couldn't be made ({e}).")
            return
        if self.batch_total <= self.batch_done:            # a new batch (else: added to the one running)
            self.batch_total = self.batch_done = self.batch_kept = 0
            self.batch_saved, self.batch_failed = [], []
            self.stop_batch.clear()
        self.batch_total += len(items)
        self.batch_folder = folder
        self.progress.setVisible(True)
        self.progress.setRange(0, self.batch_total)
        self.stop_btn.setVisible(True)
        self.show_btn.setVisible(False)
        self.retry_btn.setVisible(False)
        self._update_bar()
        self.summary.setText(f"Downloading {self.batch_total:,} to “{os.path.basename(folder) or folder}”…")
        bridge, stop, halt = self.bridge, self.stop, self.stop_batch
        tunes = list(self.tunes)
        have = data or {}

        def one(item: Item) -> None:
            path = how = ""
            if not (stop.is_set() or halt.is_set()):
                try:
                    blob = have.get(item.key) or CLIENT().download(item.url)
                    if blob:
                        path, how = A.save_download(blob, folder, A.model_name(item.prompt.tune_id, tunes),
                                                    item.prompt.text, item.prompt.created)
                except Exception:  # noqa: BLE001 — a file that couldn't be written counts as failed
                    path = ""
            bridge.saved.emit(item, path, how if path else ("stopped" if halt.is_set() else ""))
        for it in items:
            self.savers.submit(one, it)

    def _one_saved(self, item: Item, path: str, how: str) -> None:
        self.batch_done += 1
        if path:
            self.batch_saved.append(path)
            self.saved_map[item.key] = path
            self._saved_ok[item.key] = (time.monotonic(), True)
            if how == "kept":
                self.batch_kept += 1
        elif how != "stopped":
            self.batch_failed.append(item)
        self.progress.setValue(self.batch_done)
        if self.batch_done < self.batch_total:
            self.summary.setText(f"Downloading {self.batch_done:,} of {self.batch_total:,}…")
            if len(self.batch_saved) % 20 == 0:
                self.view.viewport().update()
            return
        # the batch is in: remember it, tag it, say so
        saved = list(self.batch_saved)
        if saved:
            A.store().update("saved", lambda d: {**(d or {}), **{k: v for k, v in self.saved_map.items()}})
            if self.hooks.add_tags is not None:
                try:
                    self.hooks.add_tags(saved, [AI_TAG])
                except Exception:  # noqa: BLE001 — the files are down; a tag can be added by hand
                    pass
        folder = getattr(self, "batch_folder", "")
        text = f"{len(saved):,} downloaded to “{os.path.basename(folder) or folder}”, tagged {AI_TAG}." if saved else \
            "Nothing was downloaded."
        if self.batch_failed:
            text += f" {len(self.batch_failed):,} couldn't be downloaded."
            self.retry_btn.setText(f"Retry {len(self.batch_failed):,}")
        if self.stop_batch.is_set():
            text += " Stopped."
        if self.batch_kept:
            text += f" ({self.batch_kept} kept as they came — install ExifTool to write the prompt into that format.)"
        self.summary.setText(text)
        self.progress.setVisible(False)
        self.stop_btn.setVisible(False)
        self.retry_btn.setVisible(bool(self.batch_failed))
        self.show_btn.setVisible(bool(saved) and self.hooks.reveal is not None)
        self.selected -= {k for k, v in self.saved_map.items() if v in set(saved)}
        self.refilter()
        if self.viewer is not None:
            self.viewer.refresh_buttons()

    def _show_last(self) -> None:
        if self.batch_saved and self.hooks.reveal is not None:
            self.hooks.reveal(self.batch_saved[-1])

    # -- the menu on a picture, and the viewer
    def _menu(self, item: Item, where: QPoint) -> None:
        items = self.chosen() if item.key in self.selected else [item]
        many = len(items) > 1
        menu = QMenu(self)
        menu.addAction("Open", lambda: self.open_viewer(item))
        menu.addSeparator()
        menu.addAction(f"Download {len(items)} to “{self.dest.label()}”" if many else f"Download to “{self.dest.label()}”",
                       lambda: self.download(items))
        menu.addAction("Download To…", lambda: self._choose_dest() and self.download(items))
        menu.addSeparator()
        menu.addAction("Copy Prompt", lambda: QGuiApplication.clipboard().setText(item.prompt.text))
        if self.hooks.create is not None:
            menu.addAction("Use Prompt in Create with AI…", lambda: self.use_prompt(item.prompt))
        menu.addAction("Select All from This Prompt",
                       lambda: self.select_add([it for it in self.view.flat if it.prompt.id == item.prompt.id]))
        saved = self.saved_map.get(item.key)
        if saved and os.path.exists(saved) and self.hooks.reveal is not None:
            menu.addSeparator()
            menu.addAction("Show in Safe Finder", lambda: self.hooks.reveal(saved))
        menu.exec(where)
        menu.deleteLater()

    def open_viewer(self, item: Item) -> None:
        if self.viewer is None:
            self.viewer = ViewerWindow(self)
            self.viewer.destroyed.connect(lambda _=None: setattr(self, "viewer", None))
        self.viewer.show_item(item)
        self.viewer.show()
        self.viewer.raise_()
        self.viewer.activateWindow()

    def event(self, event) -> bool:  # noqa: N802
        if event.type() == event.Type.WindowActivate:      # back from Safe Finder: "this folder" may be another now
            self._update_bar()
            if self.viewer is not None:
                self.viewer.refresh_buttons()
        return super().event(event)

    def closeEvent(self, event) -> None:  # noqa: N802
        self.stop.set()
        self.stop_batch.set()
        if self.viewer is not None:
            self.viewer.close()
        self.pool.shutdown(wait=False, cancel_futures=True)
        self.savers.shutdown(wait=False, cancel_futures=True)
        super().closeEvent(event)


# ============================================================================ the viewer

class _Picture(QWidget):
    """A picture as large as the space it has."""

    def __init__(self) -> None:
        super().__init__()
        self.pm: QPixmap | None = None
        self.note = "Loading…"
        self.setMinimumSize(420, 420)

    def show_pixmap(self, pm: QPixmap | None, note: str = "") -> None:
        self.pm, self.note = pm, note
        self.update()

    def paintEvent(self, _event) -> None:  # noqa: N802
        p = QPainter(self)
        p.setRenderHint(QPainter.RenderHint.SmoothPixmapTransform)
        p.fillRect(self.rect(), QColor("#000000"))
        if self.pm is None or self.pm.isNull():
            p.setPen(QColor("#98989F"))
            p.drawText(self.rect(), Qt.AlignmentFlag.AlignCenter, self.note)
        else:
            size = self.pm.size().scaled(self.size(), Qt.AspectRatioMode.KeepAspectRatio)
            p.drawPixmap(QRect((self.width() - size.width()) // 2, (self.height() - size.height()) // 2,
                               size.width(), size.height()), self.pm)
        p.end()


class ViewerWindow(QWidget):
    """One picture full size, with its prompt — and ← → through everything the browser is showing."""

    def __init__(self, browser: BrowserWindow) -> None:
        super().__init__(browser, Qt.WindowType.Window)
        self.setAttribute(Qt.WidgetAttribute.WA_DeleteOnClose)
        self.b = browser
        self.item: Item | None = None
        self.full: OrderedDict[str, bytes] = OrderedDict()     # the last few pictures, as downloaded
        self.asked: set[str] = set()
        self.setStyleSheet(_style(browser.theme))
        self.resize(1180, 820)
        self.bridge = _Bridge()
        self.bridge.full.connect(self._got_full)
        h = QHBoxLayout(self)
        h.setContentsMargins(0, 0, 0, 0)
        h.setSpacing(0)
        self.picture = _Picture()
        h.addWidget(self.picture, 1)
        side = QFrame()
        side.setFixedWidth(320)
        v = QVBoxLayout(side)
        v.setContentsMargins(14, 14, 14, 12)
        v.setSpacing(8)
        self.model = QLabel("")
        self.model.setObjectName("SheetTitle")
        self.model.setWordWrap(True)
        self.meta = _small("")
        v.addWidget(self.model)
        v.addWidget(self.meta)
        self.prompt = QPlainTextEdit()
        self.prompt.setReadOnly(True)
        self.prompt.setObjectName("AIPrompt")
        v.addWidget(self.prompt, 1)
        self.state = _small("")
        v.addWidget(self.state)
        self.dl_btn = QPushButton("Download")
        self.dl_btn.setObjectName("Primary")
        self.dl_btn.clicked.connect(self._download)
        self.dl_to = QPushButton("Download To…")
        self.dl_to.clicked.connect(lambda: self.b._choose_dest() and self._download())
        self.sel_btn = QPushButton("Select")
        self.sel_btn.clicked.connect(lambda: self.item is not None and self.b.toggle(self.item))
        copy = QPushButton("Copy Prompt")
        copy.clicked.connect(lambda: self.item is not None and QGuiApplication.clipboard().setText(self.item.prompt.text))
        use = QPushButton("Use Prompt in Create with AI…")
        use.clicked.connect(lambda: self.item is not None and self.b.use_prompt(self.item.prompt))
        use.setVisible(browser.hooks.create is not None)
        copy_img = QPushButton("Copy Image")
        copy_img.clicked.connect(self._copy_image)
        self.reveal_btn = QPushButton("Show in Safe Finder")
        self.reveal_btn.clicked.connect(self._reveal)
        for b in (self.dl_btn, self.dl_to, self.sel_btn, copy, use, copy_img, self.reveal_btn):
            v.addWidget(b)
        nav = QHBoxLayout()
        self.prev_btn = QPushButton("‹")
        self.next_btn = QPushButton("›")
        self.prev_btn.clicked.connect(lambda: self.step(-1))
        self.next_btn.clicked.connect(lambda: self.step(1))
        self.count = _small("", wrap=False)
        self.count.setAlignment(Qt.AlignmentFlag.AlignCenter)
        nav.addWidget(self.prev_btn)
        nav.addWidget(self.count, 1)
        nav.addWidget(self.next_btn)
        v.addLayout(nav)
        h.addWidget(side)
        for keys, slot in (("Left", lambda: self.step(-1)), ("Right", lambda: self.step(1)), ("Escape", self.close),
                           ("Space", lambda: self.item is not None and self.b.toggle(self.item)),
                           ("Ctrl+D", self._download), ("Ctrl+C", self._copy_image)):
            QShortcut(QKeySequence(keys), self).activated.connect(slot)

    def _index(self) -> int:
        return self.b.view.pos.get(self.item.key, -1) if self.item is not None else -1

    def relist(self) -> None:
        """The browser's list changed (a search, a reload): stay on this picture if it's still shown."""
        if self.item is not None:
            i = self._index()
            if i >= 0:
                self.item = self.b.view.flat[i]
            self.refresh_buttons()

    def step(self, by: int) -> None:
        flat = self.b.view.flat
        if not flat:
            return
        i = self._index()
        n = max(0, min(len(flat) - 1, (i if i >= 0 else 0) + by))
        if flat[n] is not self.item:
            self.show_item(flat[n])
            self.b.view.focus_i = n
            self.b.view.reveal(flat[n])

    def show_item(self, item: Item) -> None:
        self.item = item
        p = item.prompt
        self.setWindowTitle(" ".join(p.text.split())[:80] or "Astria image")
        self.model.setText(self.b.model_of(p))
        self.prompt.setPlainText(p.text)
        self._meta()
        self.refresh_buttons()
        data = self.full.get(item.key)
        if data:
            self._show(data)
        else:
            thumb = self.b.thumbs.get(item.key)
            self.picture.show_pixmap(thumb, "Loading…")       # the small one while the real one comes
            self._ask(item)
        flat = self.b.view.flat                                # the neighbours, so ← → is instant
        i = self._index()
        for j in (i + 1, i - 1):
            if 0 <= j < len(flat) and flat[j].key not in self.full:
                self._ask(flat[j])

    def _ask(self, item: Item) -> None:
        if item.key in self.asked:
            return
        self.asked.add(item.key)
        url, key, bridge = item.url, item.key, self.bridge

        def work() -> None:
            bridge.full.emit(key, CLIENT().download(url) or b"")
        self.b.pool.submit(work)

    def _got_full(self, key: str, data: bytes) -> None:
        self.asked.discard(key)
        if data:
            self.full[key] = data
            while len(self.full) > 8:
                self.full.popitem(last=False)
        if self.item is not None and key == self.item.key:
            if data:
                self._show(data)
            else:
                self.picture.show_pixmap(None, "The picture couldn't be loaded.")

    def _show(self, data: bytes) -> None:
        img = QImage.fromData(data)
        if img.isNull():
            self.picture.show_pixmap(None, "The picture couldn't be shown.")
            return
        self._meta(img.width(), img.height(), len(data))
        self.picture.show_pixmap(QPixmap.fromImage(img))

    def _meta(self, w: int = 0, h: int = 0, size: int = 0) -> None:
        if self.item is None:
            return
        p = self.item.prompt
        bits = [self.b.when_text(p)]
        if w and h:
            bits.append(f"{w} × {h}")
        if size:
            bits.append(f"{size / 1_000_000:.1f} MB" if size >= 1_000_000 else f"{size / 1000:.0f} KB")
        if len(p.images) > 1:
            bits.append(f"{self.item.index + 1} of {len(p.images)} from this prompt")
        self.meta.setText("  ·  ".join(b for b in bits if b))

    def refresh_buttons(self) -> None:
        if self.item is None:
            return
        flat = self.b.view.flat
        i = self._index()
        self.count.setText(f"{i + 1:,} of {len(flat):,}" if i >= 0 else "")
        self.prev_btn.setEnabled(i > 0)
        self.next_btn.setEnabled(0 <= i < len(flat) - 1)
        self.dl_btn.setText(f"Download to “{self.b.dest.label()}”")
        saved = self.b.saved_map.get(self.item.key)
        there = bool(saved) and os.path.exists(saved)
        self.state.setText(f"Downloaded: {os.path.basename(saved)}" if there else "")
        self.reveal_btn.setVisible(there and self.b.hooks.reveal is not None)
        self.sel_btn.setText("Deselect" if self.item.key in self.b.selected else "Select")

    def _download(self) -> None:
        if self.item is not None:
            data = self.full.get(self.item.key)
            self.b.download([self.item], {self.item.key: data} if data else None)

    def _copy_image(self) -> None:
        if self.item is not None and self.item.key in self.full:
            img = QImage.fromData(self.full[self.item.key])
            if not img.isNull():
                QGuiApplication.clipboard().setImage(img)

    def _reveal(self) -> None:
        if self.item is not None:
            saved = self.b.saved_map.get(self.item.key)
            if saved and self.b.hooks.reveal is not None:
                self.b.hooks.reveal(saved)
