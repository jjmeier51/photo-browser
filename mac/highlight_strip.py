"""The highlight bubbles above a folder's files in Photo Browser for Mac — the iPhone app's round highlights
(highlights.py says which folders they are).

`HighlightStrip` is a row of circles — each a folder's cover inside a ring in its kind's colours (Instagram's warm
gradient for album highlights and Instagram's own, blue for Facebook, cyan→red for TikTok, as on the iPhone), its
name underneath. A click opens the folder; a right-click asks the pane for its menu. The row wraps: one line when
they fit, two at most (it scrolls for more) so the files stay on screen. In a **Reviews folder** the bubbles are
large and take the whole pane — that's all such a folder shows on the iPhone — with "Show Files" to see the
ordinary listing instead.

Painted, not built of widgets: a folder with hundreds of highlights costs what's on screen. The pictures come
from the pane (`picture(path, mtime)` — the folder's cover, from the thumbnail cache; None while it's being made).
"""
from __future__ import annotations

import math
import os
from typing import Callable

from PySide6.QtCore import QEvent, QPoint, QPointF, QRect, QRectF, QSize, Qt, Signal
from PySide6.QtGui import QBrush, QColor, QConicalGradient, QFont, QFontMetrics, QLinearGradient, QPainter, QPainterPath, QPen
from PySide6.QtWidgets import (QAbstractItemView, QHBoxLayout, QLabel, QListView, QListWidget, QListWidgetItem,
                               QPushButton, QStyle, QStyledItemDelegate, QVBoxLayout, QWidget)

SMALL, LARGE = 64, 108                 # a bubble's diameter: above the files, and in a Reviews folder
RINGS = {                              # the iPhone's `bubbleRing`
    "facebook": ["#1A75E8", "#4D9EFC"],
    "tiktok": ["#25F4EE", "#FE2C55"],
    "of": ["#00AFF0", "#00D4FF"],
}
WARM = ["#FC991C", "#F2456B", "#8F3BD4"]   # Instagram's, and every album highlight's

PATH, KIND, LABEL, MTIME = (Qt.ItemDataRole.UserRole + i for i in range(4))


class _Delegate(QStyledItemDelegate):
    def __init__(self, strip: "HighlightStrip") -> None:
        super().__init__(strip)
        self.strip = strip

    def sizeHint(self, option, index) -> QSize:  # noqa: N802
        return self.strip.cell()

    def paint(self, p: QPainter, option, index) -> None:
        strip = self.strip
        theme = strip.theme()
        d = strip.diameter
        r = option.rect
        circle = QRectF(r.x() + (r.width() - d) / 2, r.y() + 6, d, d)
        p.save()
        p.setRenderHint(QPainter.RenderHint.Antialiasing)
        p.setRenderHint(QPainter.RenderHint.SmoothPixmapTransform)
        hovered = bool(option.state & QStyle.StateFlag.State_MouseOver)
        focused = bool(option.state & QStyle.StateFlag.State_HasFocus)
        colours = RINGS.get(index.data(KIND), WARM)
        g = QLinearGradient(circle.topLeft(), circle.bottomRight())
        for i, c in enumerate(colours):
            g.setColorAt(i / (len(colours) - 1), QColor(c))
        p.setPen(QPen(QBrush(g), 3.4 if (hovered or focused) else 2.6))
        p.setBrush(Qt.BrushStyle.NoBrush)
        p.drawEllipse(circle.adjusted(1.5, 1.5, -1.5, -1.5))
        inner = circle.adjusted(5, 5, -5, -5)
        clip = QPainterPath()
        clip.addEllipse(inner)
        p.setClipPath(clip)
        p.fillRect(inner, QColor(255, 255, 255, 30) if theme.dark else QColor(0, 0, 0, 22))
        pm = strip.picture(index.data(PATH), index.data(MTIME) or 0)
        if pm is not None and not pm.isNull():
            scale = max(inner.width() / max(pm.width(), 1), inner.height() / max(pm.height(), 1))
            sw, sh = inner.width() / scale, inner.height() / scale
            p.drawPixmap(inner, pm, QRectF((pm.width() - sw) / 2, (pm.height() - sh) / 2, sw, sh))
        else:                                              # no cover yet: the folder's first letter
            f = QFont(option.font)
            f.setPointSizeF(max(11.0, d * 0.3))
            f.setWeight(QFont.Weight.DemiBold)
            p.setFont(f)
            p.setPen(QColor(theme.secondary))
            label = str(index.data(LABEL) or "").lstrip("@ ")
            p.drawText(inner, Qt.AlignmentFlag.AlignCenter, label[:1].upper())
        p.setClipping(False)
        f = QFont(option.font)
        f.setPointSizeF(max(8.5, f.pointSizeF() - (1.5 if d < LARGE else 0.5)))
        p.setFont(f)
        p.setPen(QColor(theme.text))
        fm = QFontMetrics(f)
        text = QRectF(r.x() + 2, circle.bottom() + 4, r.width() - 4, fm.height() + 2)
        p.drawText(text, Qt.AlignmentFlag.AlignHCenter | Qt.AlignmentFlag.AlignTop,
                   fm.elidedText(str(index.data(LABEL) or ""), Qt.TextElideMode.ElideRight, int(text.width())))
        p.restore()


class HighlightStrip(QWidget):
    opened = Signal(str)                   # a bubble was clicked: go there
    menu_wanted = Signal(str, QPoint)      # right-click: (folder, where on screen)
    files_toggled = Signal(bool)           # Reviews folder: show the ordinary listing instead / as well

    def __init__(self, picture: Callable[[str, int], object], theme: Callable[[], object], parent=None) -> None:
        super().__init__(parent)
        self.picture, self.theme = picture, theme
        self.diameter = SMALL
        self.reviews = False
        self.setObjectName("HighlightStrip")
        lay = QVBoxLayout(self)
        lay.setContentsMargins(0, 0, 0, 0)
        lay.setSpacing(0)
        self.head = QWidget()
        hl = QHBoxLayout(self.head)
        hl.setContentsMargins(12, 6, 10, 0)
        self.title = QLabel("")
        self.title.setObjectName("SheetSub")
        self.files_btn = QPushButton("Show Files")
        self.files_btn.setCheckable(True)
        self.files_btn.setToolTip("A Reviews folder shows only its highlight folders — this shows its ordinary listing too")
        self.files_btn.toggled.connect(self._files)
        hl.addWidget(self.title, 1)
        hl.addWidget(self.files_btn)
        lay.addWidget(self.head)
        self.list = QListWidget()
        self.list.setViewMode(QListView.ViewMode.IconMode)
        self.list.setFlow(QListView.Flow.LeftToRight)
        self.list.setWrapping(True)
        self.list.setResizeMode(QListView.ResizeMode.Adjust)
        self.list.setMovement(QListView.Movement.Static)
        self.list.setUniformItemSizes(True)
        self.list.setSelectionMode(QAbstractItemView.SelectionMode.NoSelection)
        self.list.setVerticalScrollMode(QAbstractItemView.ScrollMode.ScrollPerPixel)
        self.list.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        self.list.setMouseTracking(True)
        self.list.setItemDelegate(_Delegate(self))
        self.list.setContextMenuPolicy(Qt.ContextMenuPolicy.CustomContextMenu)
        self.list.customContextMenuRequested.connect(self._menu)
        self.list.itemClicked.connect(lambda it: self.opened.emit(it.data(PATH)))
        self.list.itemActivated.connect(lambda it: self.opened.emit(it.data(PATH)))
        self.list.setAccessibleName("Highlights")
        lay.addWidget(self.list, 1)
        self.empty = QLabel("No highlight folders yet — every folder made in a Reviews folder becomes one.")
        self.empty.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.empty.setObjectName("SheetSub")
        self.empty.setWordWrap(True)
        lay.addWidget(self.empty, 1)
        self.empty.hide()

    def cell(self) -> QSize:
        d = self.diameter
        return QSize(d + (22 if d < LARGE else 34), d + 30)

    def paths(self) -> list[str]:
        return [self.list.item(i).data(PATH) for i in range(self.list.count())]

    def set_listing(self, bubbles, reviews: bool, mtimes: dict[str, int], files_shown: bool = False) -> None:
        """`bubbles`: highlights.Bubble list, in order. `reviews`: large, and the head row with Show Files."""
        self.reviews = reviews
        self.diameter = LARGE if reviews else SMALL
        self.list.clear()
        self.list.setGridSize(self.cell())
        for b in bubbles:
            it = QListWidgetItem()
            it.setData(PATH, b.path)
            it.setData(KIND, b.kind)
            it.setData(LABEL, b.label)
            it.setData(MTIME, int(mtimes.get(b.path, 0)))
            it.setToolTip(b.label if b.label == os.path.basename(b.path) else f"{b.label} — {os.path.basename(b.path)}")
            it.setSizeHint(self.cell())
            self.list.addItem(it)
        self.head.setVisible(reviews)
        self.title.setText(f"Reviews folder — {len(bubbles)} highlight{'s' if len(bubbles) != 1 else ''}")
        self.files_btn.blockSignals(True)
        self.files_btn.setChecked(files_shown)
        self.files_btn.setText("Hide Files" if files_shown else "Show Files")
        self.files_btn.blockSignals(False)
        self.empty.setVisible(reviews and not bubbles)
        self.list.setVisible(bool(bubbles))
        self._fit()

    def _files(self, on: bool) -> None:
        self.files_btn.setText("Hide Files" if on else "Show Files")
        self.files_toggled.emit(on)
        self._fit()

    def _fit(self) -> None:
        """One line of bubbles when they fit, two at most; a Reviews folder's take what room there is (half of it
        while its files are shown too)."""
        n = self.list.count()
        cell = self.cell()
        cols = max(1, (max(self.width(), cell.width()) - 8) // cell.width())
        rows = max(1, math.ceil(n / cols))
        if self.reviews and not self.files_btn.isChecked():
            self.setMinimumHeight(0)
            self.setMaximumHeight(16777215)
            return
        shown = min(rows, 2)
        h = shown * cell.height() + 10 + (self.head.sizeHint().height() if self.reviews else 0)
        self.setFixedHeight(h)

    def resizeEvent(self, event) -> None:  # noqa: N802
        super().resizeEvent(event)
        self._fit()

    def _menu(self, pos: QPoint) -> None:
        it = self.list.itemAt(pos)
        if it is not None:
            self.menu_wanted.emit(it.data(PATH), self.list.viewport().mapToGlobal(pos))

    def refresh(self) -> None:
        self.list.viewport().update()
