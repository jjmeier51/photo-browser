"""The tile grid — square, rounded thumbnails with the name beneath, a folder tile for subfolders,
small kind badges (video duration / HEIC / RAW), and an accent ring for selection. Mirrors the iOS
`ThumbCell`. Painting is the only custom drawing in the app."""

from __future__ import annotations

from PySide6.QtCore import QRect, QSize, Qt, Signal, QModelIndex
from PySide6.QtGui import QColor, QPainter, QPainterPath, QPen, QPixmap, QFont
from PySide6.QtWidgets import QListView, QStyledItemDelegate, QStyle, QAbstractItemView

from ..library import Entry
from ..models import EntryRole
from ..theme import P

RAW_EXT = {".dng", ".cr2", ".cr3", ".nef", ".arw", ".raf", ".rw2", ".orf"}


class TileDelegate(QStyledItemDelegate):
    def __init__(self, parent=None):
        super().__init__(parent)
        self.tile = 160
        self.label_h = 34
        self.gap = 8

    def set_tile(self, px: int):
        self.tile = px

    def sizeHint(self, option, index):
        return QSize(self.tile + self.gap, self.tile + self.label_h + self.gap)

    def paint(self, painter: QPainter, option, index: QModelIndex):
        e: Entry = index.data(EntryRole)
        if e is None:
            return
        painter.save()
        painter.setRenderHint(QPainter.Antialiasing)
        painter.setRenderHint(QPainter.SmoothPixmapTransform)
        r = option.rect.adjusted(self.gap // 2, self.gap // 2, -self.gap // 2, -self.gap // 2)
        tile = QRect(r.x(), r.y(), self.tile, self.tile)
        selected = bool(option.state & QStyle.State_Selected)

        path = QPainterPath()
        path.addRoundedRect(tile, 12, 12)
        painter.setClipPath(path)
        painter.fillRect(tile, QColor(P.tile))
        if e.is_dir:
            self._paint_folder(painter, tile)
        else:
            pm: QPixmap | None = index.data(Qt.DecorationRole)
            if pm is not None and not pm.isNull():
                # scaledToFill + center crop (square tiles, like the phone)
                scaled = pm.scaled(tile.size(), Qt.KeepAspectRatioByExpanding, Qt.SmoothTransformation)
                sx = (scaled.width() - tile.width()) // 2
                sy = (scaled.height() - tile.height()) // 2
                painter.drawPixmap(tile.topLeft(), scaled, QRect(sx, sy, tile.width(), tile.height()))
            else:
                painter.setPen(QColor(P.tertiary))
                painter.drawText(tile, Qt.AlignCenter, "…" if e.kind == "image" else "▶")
        painter.setClipping(False)

        badge = self._badge(e, index)
        if badge:
            f = QFont(); f.setPointSize(10); f.setBold(True)
            painter.setFont(f)
            fm = painter.fontMetrics()
            bw = fm.horizontalAdvance(badge) + 12
            br = QRect(tile.right() - bw - 6, tile.bottom() - 24, bw, 18)
            bp = QPainterPath(); bp.addRoundedRect(br, 9, 9)
            painter.fillPath(bp, QColor(0, 0, 0, 150))
            painter.setPen(QColor("white"))
            painter.drawText(br, Qt.AlignCenter, badge)

        if selected:
            pen = QPen(QColor(P.accent)); pen.setWidth(3)
            painter.setPen(pen); painter.setBrush(Qt.NoBrush)
            painter.drawRoundedRect(tile.adjusted(1, 1, -1, -1), 12, 12)
            painter.fillPath(path, QColor(10, 132, 255, 40))
        elif option.state & QStyle.State_MouseOver:
            pen = QPen(QColor(255, 255, 255, 60)); pen.setWidth(1)
            painter.setPen(pen); painter.setBrush(Qt.NoBrush)
            painter.drawRoundedRect(tile.adjusted(0, 0, -1, -1), 12, 12)

        # name
        painter.setPen(QColor(P.text) if selected else QColor(P.secondary))
        f = QFont(); f.setPointSize(11)
        painter.setFont(f)
        label = QRect(tile.x(), tile.bottom() + 4, tile.width(), self.label_h - 4)
        elided = painter.fontMetrics().elidedText(e.name, Qt.ElideMiddle, label.width())
        painter.drawText(label, Qt.AlignHCenter | Qt.AlignTop, elided)
        painter.restore()

    def _paint_folder(self, painter: QPainter, tile: QRect):
        painter.fillRect(tile, QColor(28, 34, 58))
        w = tile.width() * 0.56
        h = w * 0.72
        x = tile.x() + (tile.width() - w) / 2
        y = tile.y() + (tile.height() - h) / 2 + 4
        body = QPainterPath(); body.addRoundedRect(x, y + h * 0.18, w, h * 0.82, 8, 8)
        tab = QPainterPath(); tab.addRoundedRect(x, y, w * 0.45, h * 0.34, 6, 6)
        painter.fillPath(tab, QColor(90, 160, 255))
        painter.fillPath(body, QColor(64, 140, 255))

    @staticmethod
    def _badge(e: Entry, index: QModelIndex) -> str:
        if e.is_dir:
            return ""
        model = index.model()
        meta = None
        try:
            src = model.mapToSource(index) if hasattr(model, "mapToSource") else index
            meta = src.model().meta.get(e.path)
        except Exception:
            meta = None
        if e.kind == "video":
            d = meta.get("Duration") if meta else None
            if isinstance(d, (int, float)):
                s = int(d)
                return f"{s // 60}:{s % 60:02d}"
            return "VIDEO"
        if e.ext in (".heic", ".heif"):
            return "HEIC"
        if e.ext in RAW_EXT:
            return "RAW"
        return ""


class GridView(QListView):
    """IconMode list with rubber-band multi-select, double-click to open, keyboard navigation."""
    activated_entry = Signal(object)          # Entry double-clicked / Enter

    def __init__(self, parent=None):
        super().__init__(parent)
        self.delegate = TileDelegate(self)
        self.setItemDelegate(self.delegate)
        self.setViewMode(QListView.IconMode)
        self.setResizeMode(QListView.Adjust)
        self.setMovement(QListView.Static)
        self.setFlow(QListView.LeftToRight)
        self.setWrapping(True)
        self.setUniformItemSizes(True)
        self.setSpacing(0)
        self.setSelectionMode(QAbstractItemView.ExtendedSelection)
        self.setSelectionRectVisible(True)
        self.setMouseTracking(True)
        self.setVerticalScrollMode(QAbstractItemView.ScrollPerPixel)
        self.setEditTriggers(QAbstractItemView.NoEditTriggers)
        self.verticalScrollBar().setSingleStep(24)
        self.doubleClicked.connect(self._activate)
        self.activated.connect(self._activate)
        self.set_tile_size(160)

    def set_tile_size(self, px: int):
        self.delegate.set_tile(px)
        self.setGridSize(QSize(px + self.delegate.gap, px + self.delegate.label_h + self.delegate.gap))
        self.setIconSize(QSize(px, px))
        self.doItemsLayout()
        self.viewport().update()

    def _activate(self, index):
        e = index.data(EntryRole)
        if e is not None:
            self.activated_entry.emit(e)

    def selected_entries(self) -> list[Entry]:
        return [i.data(EntryRole) for i in self.selectionModel().selectedIndexes()]
