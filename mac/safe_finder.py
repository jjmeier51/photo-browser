#!/usr/bin/env python3
"""Safe Finder — a Finder-style window for moving photos and videos onto the exFAT SSD safely.

Two Finder panes side by side — "From" (your Mac) and "To" (the SSD) — with a Finder sidebar
(Favorites, Locations with eject buttons), icon view with photo/video thumbnails or list view,
back/forward, a path bar, a Sort menu (name, kind, date modified / created / added, size), a search
field, and sliders for the thumbnail size and the space between tiles. Search looks through the
current folder or the whole Mac (Spotlight when it can, walking the folders otherwise) for names,
extensions or kinds and shows the results in the same icon or list view, where they can be opened,
revealed in their folder ("Show in Safe Finder") or moved to the SSD. "All Videos" in the sidebar
is the same thing for every video in your home folder. Select files or folders on the left and press
Move / Copy, or drag them anywhere onto the right pane (or onto a folder in it). Drops from the
real Finder work too.

Every transfer goes through `safe_transfer.Transfer` (one file at a time into a hidden staging
folder, flushed to the disk, verified by re-reading, only then put in place; no `._` files;
iOS-safe names; never overwrites; originals go to the Trash only after their copies verified)
and is confirmed first in a sheet that lists exactly what will happen. The Mac is kept awake while
it runs, and "Eject" flushes and unmounts the SSD properly.

Tags are the Photo Browser app's own (see shared_tags.py): select files or folders and press ⌘T (or
right-click ▸ Tags, or drop them on a tag in the sidebar). A folder gets the tag itself, and you're asked
whether the files inside it get it too. Tags on a
drive are saved on the drive, where the iPhone app syncs with them; a tag added in the app shows up
here. The sidebar's Tags list opens every file carrying a tag; tags go along when files are moved or
copied.

Crop: select photos, right-click ▸ Crop… — one crop, drawn on the first, goes on all of them in place
and each is tagged "cropped" (crop_window.py / batch_crop.py, the iPhone app's Crop screen on the Mac).
AI Upscale 2×: right-click ▸ AI Upscale 2×… — Real-ESRGAN on this Mac (Upscayl's engine), in place, tagged
"upscaled" (ai_upscale.py / upscale_window.py).

Run:  double-click "Safe Finder.command" next to this file, or
      mac/.venv/bin/python mac/safe_finder.py [--from FOLDER] [--to FOLDER]
      — or build it into /Applications with "sh mac/build_safe_finder_app.sh" (see mac/README.md).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import stat
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unicodedata
import zlib
from collections import OrderedDict, deque
from pathlib import Path
from typing import NamedTuple

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

try:
    from PySide6.QtCore import (QDateTime, QDir, QFileInfo, QFileSystemWatcher, QLocale, QMimeData, QModelIndex,
                                QObject, QPoint, QRect, QRectF, QRunnable, QSettings, QSize, QSortFilterProxyModel,
                                QStringListModel, Qt, QThreadPool, QTimer, QUrl, Signal)
    from PySide6.QtGui import (QAction, QActionGroup, QColor, QDesktopServices, QFont, QFontMetrics, QIcon, QImage,
                               QImageReader, QKeySequence, QPainter, QPainterPath, QPalette, QPen, QPixmap,
                               QShortcut, QStandardItem, QStandardItemModel)
    from PySide6.QtWidgets import (QAbstractItemView, QApplication, QButtonGroup, QCheckBox, QComboBox, QDialog,
                                   QCompleter, QFileIconProvider, QFileSystemModel, QFrame, QHBoxLayout,
                                   QHeaderView, QInputDialog, QLabel, QLayout, QLineEdit, QListView, QMainWindow,
                                   QMenu, QMessageBox, QPlainTextEdit, QProgressBar, QPushButton, QScrollArea,
                                   QSizePolicy,
                                   QSlider, QSplitter, QStackedWidget, QStyle, QStyledItemDelegate,
                                   QStyleOptionViewItem, QToolButton, QTreeView, QTreeWidget,
                                   QTreeWidgetItem, QVBoxLayout, QWidget)
except ModuleNotFoundError:
    venv_python = HERE / ".venv" / "bin" / "python"
    if venv_python.exists() and Path(sys.executable).resolve() != venv_python.resolve():
        os.execv(str(venv_python), [str(venv_python), *sys.argv])
    sys.exit("Safe Finder needs PySide6. Double-click “Safe Finder.command” (it sets everything up), or run:\n"
             "  python3 -m venv mac/.venv && mac/.venv/bin/pip install -r mac/requirements.txt")

import airdrop_to_iphone as airdrop
import batch_crop
import safe_transfer as engine
import shared_tags
import spare_folders
from safe_copy_to_ssd import human, safe_name

try:
    from PIL import Image, ImageOps
    try:
        import pillow_heif  # type: ignore
        pillow_heif.register_heif_opener()
    except Exception:  # noqa: BLE001 - optional
        pass
    PIL_OK = True
except Exception:  # noqa: BLE001 - optional
    PIL_OK = False

IS_MAC = sys.platform == "darwin"
VOLUMES = Path(os.environ.get("SAFE_FINDER_VOLUMES", "/Volumes"))
IMAGE_EXT = {".jpg", ".jpeg", ".png", ".heic", ".heif", ".gif", ".tif", ".tiff", ".bmp", ".webp", ".avif",
             ".dng", ".cr2", ".cr3", ".nef", ".arw", ".raf", ".orf", ".rw2"}
VIDEO_EXT = {".mov", ".mp4", ".m4v", ".avi", ".mkv", ".webm", ".3gp", ".mts", ".m2ts", ".wmv"}
RAW_EXT = {".dng", ".cr2", ".cr3", ".nef", ".arw", ".raf", ".orf", ".rw2"}


# ============================================================================ theme


class Theme:
    """Finder's light and dark looks. Colours are read by the painted parts (tiles, glyphs) and
    turned into one stylesheet for the widgets."""

    def __init__(self, dark: bool) -> None:
        self.dark = dark
        if dark:
            self.window, self.content, self.header = "#1E1E1E", "#1E1E1E", "#2B2B2D"
            self.sidebar, self.panel = "#27272A", "#262628"
            self.border, self.hairline = "#3A3A3C", "rgba(255,255,255,0.07)"
            self.text, self.secondary, self.tertiary = "#EBEBF0", "#98989F", "#6C6C70"
            self.accent, self.accent_pill = "#0A84FF", "#0A6CDB"
            self.select_bg, self.select_inactive = "rgba(255,255,255,0.11)", "#4A4A4E"
            self.zebra, self.hover = "#242426", "rgba(255,255,255,0.06)"
            self.button, self.button_border = "#3A3A3D", "rgba(255,255,255,0.10)"
            self.green, self.orange, self.red = "#32D74B", "#FF9F0A", "#FF453A"
        else:
            self.window, self.content, self.header = "#FFFFFF", "#FFFFFF", "#F6F6F6"
            self.sidebar, self.panel = "#EEEEF1", "#FAFAFA"
            self.border, self.hairline = "#DADADC", "rgba(0,0,0,0.07)"
            self.text, self.secondary, self.tertiary = "#1D1D1F", "#6E6E73", "#A1A1A6"
            self.accent, self.accent_pill = "#007AFF", "#0064E1"
            self.select_bg, self.select_inactive = "rgba(0,0,0,0.075)", "#D4D4D8"
            self.zebra, self.hover = "#F4F5F5", "rgba(0,0,0,0.045)"
            self.button, self.button_border = "#FFFFFF", "rgba(0,0,0,0.14)"
            self.green, self.orange, self.red = "#28A745", "#E8890C", "#E5372B"

    def palette(self) -> QPalette:
        p = QPalette()
        for role, c in ((QPalette.ColorRole.Window, self.window), (QPalette.ColorRole.Base, self.content),
                        (QPalette.ColorRole.AlternateBase, self.zebra), (QPalette.ColorRole.Text, self.text),
                        (QPalette.ColorRole.WindowText, self.text), (QPalette.ColorRole.ButtonText, self.text),
                        (QPalette.ColorRole.Button, self.button), (QPalette.ColorRole.Highlight, self.accent_pill),
                        (QPalette.ColorRole.HighlightedText, "#FFFFFF"), (QPalette.ColorRole.ToolTipBase, self.panel),
                        (QPalette.ColorRole.ToolTipText, self.text), (QPalette.ColorRole.PlaceholderText, self.tertiary)):
            p.setColor(role, QColor(c))
        return p

    def stylesheet(self) -> str:
        t = self
        return f"""
        QMainWindow, QDialog {{ background: {t.window}; }}
        QWidget {{ color: {t.text}; }}
        QToolTip {{ background: {t.panel}; color: {t.text}; border: 1px solid {t.border}; padding: 4px 6px; }}
        #Sidebar {{ background: {t.sidebar}; border: none; border-right: 1px solid {t.border}; }}
        QTreeWidget#SidebarTree {{ background: transparent; border: none; outline: 0; padding: 0 8px; }}
        QTreeWidget#SidebarTree::item, QTreeWidget#SidebarTree::item:selected,
        QTreeWidget#SidebarTree::item:hover {{ background: transparent; border: none; }}
        #PaneHeader {{ background: {t.header}; border-bottom: 1px solid {t.border}; }}
        #PaneTitle {{ font-size: 14px; font-weight: 600; }}
        #RoleChip {{ font-size: 10px; font-weight: 700; letter-spacing: 0.6px; padding: 2px 7px;
                     border-radius: 8px; color: {t.secondary}; border: 1px solid {t.button_border}; }}
        #RoleChip[active="true"] {{ color: white; background: {t.accent}; border-color: {t.accent}; }}
        #PathBar, #StatusBar {{ background: {t.header}; border-top: 1px solid {t.border}; }}
        #StatusBar QLabel, #PathBar QLabel {{ color: {t.secondary}; font-size: 11px; }}
        #FsChip {{ font-size: 10px; font-weight: 600; color: {t.secondary}; border: 1px solid {t.button_border};
                   border-radius: 7px; padding: 1px 6px; }}
        QToolButton#Crumb {{ border: none; padding: 1px 3px; border-radius: 4px; color: {t.secondary}; font-size: 11px; }}
        QToolButton#Crumb:hover {{ background: {t.hover}; color: {t.text}; }}
        QToolButton#Nav, QToolButton#Seg {{ border: none; border-radius: 6px; padding: 3px; }}
        QToolButton#Nav:hover, QToolButton#Seg:hover {{ background: {t.hover}; }}
        QToolButton#Seg:checked {{ background: {t.select_bg}; }}
        QToolButton#Nav:disabled {{ background: transparent; }}
        QLineEdit#Search {{ background: {t.content}; border: 1px solid {t.button_border}; border-radius: 7px;
                            padding: 2px 6px; font-size: 12px; }}
        QLineEdit#Search:focus {{ border-color: {t.accent}; }}
        #ScopeBar {{ background: {t.header}; border-bottom: 1px solid {t.border}; }}
        #ScopeBar QLabel {{ color: {t.secondary}; font-size: 11px; }}
        QToolButton#Scope {{ border: 1px solid transparent; border-radius: 9px; padding: 1px 9px; font-size: 11px;
                             color: {t.text}; }}
        QToolButton#Scope:hover {{ background: {t.hover}; }}
        QToolButton#Scope:checked {{ background: {t.accent_pill}; color: white; }}
        #ScopeBar QComboBox {{ font-size: 11px; padding: 1px 6px; min-height: 18px; }}
        QListView, QTreeView {{ background: {t.content}; border: none; outline: 0; }}
        QAbstractItemView[dropActive="true"] {{ border: 2px solid {t.accent}; border-radius: 4px; }}
        QTreeView::item {{ height: 24px; border: none; }}
        QTreeView::item:selected {{ background: {t.accent_pill}; color: white; }}
        QTreeView::item:selected:!active {{ background: {t.select_inactive}; color: {t.text}; }}
        QHeaderView::section {{ background: {t.content}; color: {t.secondary}; border: none;
                                border-bottom: 1px solid {t.border}; border-right: 1px solid {t.hairline};
                                padding: 4px 8px; font-size: 11px; }}
        QScrollBar:vertical {{ background: transparent; width: 10px; margin: 2px; }}
        QScrollBar:horizontal {{ background: transparent; height: 10px; margin: 2px; }}
        QScrollBar::handle {{ background: {"rgba(255,255,255,0.28)" if t.dark else "rgba(0,0,0,0.28)"};
                              border-radius: 3px; min-height: 30px; min-width: 30px; }}
        QScrollBar::add-line, QScrollBar::sub-line {{ width: 0; height: 0; }}
        QScrollBar::add-page, QScrollBar::sub-page {{ background: transparent; }}
        QSlider::groove:horizontal {{ height: 3px; background: {t.border}; border-radius: 1px; }}
        QSlider::sub-page:horizontal {{ background: {t.secondary}; border-radius: 1px; }}
        QSlider::handle:horizontal {{ background: {"#D0D0D4" if t.dark else "#FFFFFF"}; border: 1px solid {t.button_border};
                                      width: 12px; height: 12px; margin: -5px 0; border-radius: 6px; }}
        #ActionBar {{ background: {t.header}; border-top: 1px solid {t.border}; }}
        #ActionBar QLabel#Summary {{ color: {t.secondary}; }}
        QPushButton {{ background: {t.button}; border: 1px solid {t.button_border}; border-radius: 6px;
                       padding: 5px 14px; min-height: 18px; }}
        QPushButton:hover {{ background: {t.hover}; }}
        QPushButton:disabled {{ color: {t.tertiary}; }}
        QPushButton#Primary {{ background: {t.accent}; color: white; border: 1px solid {t.accent}; font-weight: 600; }}
        QPushButton#Primary:hover {{ background: {t.accent_pill}; }}
        QPushButton#Primary:disabled {{ background: {t.select_inactive}; border-color: {t.select_inactive};
                                        color: {"#8E8E93" if t.dark else "#FFFFFF"}; }}
        QPushButton#Danger {{ color: {t.red}; }}
        QPushButton#SegLeft, QPushButton#SegRight {{ padding: 4px 18px; }}
        QPushButton#SegLeft {{ border-top-right-radius: 0; border-bottom-right-radius: 0; }}
        QPushButton#SegRight {{ border-top-left-radius: 0; border-bottom-left-radius: 0; border-left: none; }}
        QPushButton#SegLeft:checked, QPushButton#SegRight:checked {{ background: {t.accent}; color: white;
                                                                     border-color: {t.accent}; }}
        #TransferPanel {{ background: {t.panel}; border-top: 1px solid {t.border}; }}
        #TransferTitle {{ font-weight: 600; }}
        #TransferDetail {{ color: {t.secondary}; font-size: 11px; }}
        QProgressBar {{ background: {t.border}; border: none; border-radius: 3px; max-height: 6px; min-height: 6px; }}
        QProgressBar::chunk {{ background: {t.accent}; border-radius: 3px; }}
        QPlainTextEdit {{ background: {t.content}; border: 1px solid {t.border}; border-radius: 6px;
                          font-family: Menlo, "SF Mono", monospace; font-size: 11px; color: {t.secondary}; }}
        #SheetTitle {{ font-size: 15px; font-weight: 700; }}
        #SheetSub {{ color: {t.secondary}; }}
        #SheetRow {{ background: {t.panel}; border: 1px solid {t.border}; border-radius: 8px; }}
        QCheckBox {{ spacing: 6px; }}
        QMenu {{ background: {t.panel}; border: 1px solid {t.border}; border-radius: 8px; padding: 4px; }}
        QMenu::item {{ padding: 4px 18px; border-radius: 4px; }}
        QMenu::item:selected {{ background: {t.accent}; color: white; }}
        QMenu::separator {{ height: 1px; background: {t.border}; margin: 4px 6px; }}
        QToolButton#TagChip {{ border: 1px solid {t.button_border}; border-radius: 11px; padding: 3px 10px 3px 7px;
                               background: {t.button}; font-size: 12px; }}
        QToolButton#TagChip:hover {{ background: {t.hover}; }}
        QToolButton#TagChip[state="on"] {{ background: {t.accent}; border-color: {t.accent}; color: white; }}
        QToolButton#TagChip[state="part"] {{ border: 1px solid {t.accent}; color: {t.accent}; }}
        QLineEdit#TagField {{ background: {t.content}; border: 1px solid {t.button_border}; border-radius: 7px;
                              padding: 5px 8px; font-size: 13px; }}
        QLineEdit#TagField:focus {{ border-color: {t.accent}; }}
        #TagHint {{ color: {t.secondary}; font-size: 11px; }}
        QScrollArea#TagScroll, QWidget#TagBox {{ background: transparent; border: none; }}
        """


THEME = Theme(False)


def qc(css: str) -> QColor:
    """QColor from a theme colour, including the CSS `rgba(r,g,b,a)` form QColor can't parse."""
    m = re.match(r"rgba\((\d+),\s*(\d+),\s*(\d+),\s*([\d.]+)\)", css)
    if m:
        r, g, b, a = m.groups()
        return QColor(int(r), int(g), int(b), round(float(a) * 255))
    return QColor(css)


def glyph(name: str, color: str | None = None, size: int = 16) -> QIcon:
    """Small crisp line icons drawn with QPainter, so they match on every Mac and in both themes."""
    dpr = 3
    pm = QPixmap(size * dpr, size * dpr)
    pm.fill(Qt.GlobalColor.transparent)
    pm.setDevicePixelRatio(dpr)
    p = QPainter(pm)
    p.setRenderHint(QPainter.RenderHint.Antialiasing)
    c = QColor(color or THEME.text)
    pen = QPen(c, 1.6, Qt.PenStyle.SolidLine, Qt.PenCapStyle.RoundCap, Qt.PenJoinStyle.RoundJoin)
    p.setPen(pen)
    s = float(size)
    if name in ("back", "forward"):
        x0, x1 = (s * 0.62, s * 0.38) if name == "back" else (s * 0.38, s * 0.62)
        p.drawPolyline([QPoint(int(x0), int(s * 0.22)), QPoint(int(x1), int(s * 0.5)), QPoint(int(x0), int(s * 0.78))])
    elif name == "grid":
        p.setPen(Qt.PenStyle.NoPen)
        p.setBrush(c)
        for gx in (0.15, 0.55):
            for gy in (0.15, 0.55):
                p.drawRoundedRect(QRectF(s * gx, s * gy, s * 0.3, s * 0.3), 1.5, 1.5)
    elif name == "list":
        for i, gy in enumerate((0.25, 0.5, 0.75)):
            p.drawPoint(QPoint(int(s * 0.18), int(s * gy)))
            p.drawLine(QPoint(int(s * 0.34), int(s * gy)), QPoint(int(s * 0.85), int(s * gy)))
    elif name == "eject":
        p.setPen(Qt.PenStyle.NoPen)
        p.setBrush(c)
        path = QPainterPath()
        path.moveTo(s * 0.5, s * 0.18)
        path.lineTo(s * 0.82, s * 0.56)
        path.lineTo(s * 0.18, s * 0.56)
        path.closeSubpath()
        p.drawPath(path)
        p.drawRoundedRect(QRectF(s * 0.18, s * 0.68, s * 0.64, s * 0.12), 1, 1)
    elif name == "plus":
        p.drawLine(QPoint(int(s * 0.5), int(s * 0.2)), QPoint(int(s * 0.5), int(s * 0.8)))
        p.drawLine(QPoint(int(s * 0.2), int(s * 0.5)), QPoint(int(s * 0.8), int(s * 0.5)))
    elif name == "pause":
        p.drawLine(QPoint(int(s * 0.38), int(s * 0.25)), QPoint(int(s * 0.38), int(s * 0.75)))
        p.drawLine(QPoint(int(s * 0.62), int(s * 0.25)), QPoint(int(s * 0.62), int(s * 0.75)))
    elif name == "play":
        p.setPen(Qt.PenStyle.NoPen)
        p.setBrush(c)
        path = QPainterPath()
        path.moveTo(s * 0.32, s * 0.22)
        path.lineTo(s * 0.78, s * 0.5)
        path.lineTo(s * 0.32, s * 0.78)
        path.closeSubpath()
        p.drawPath(path)
    elif name == "stop":
        p.drawEllipse(QRectF(s * 0.1, s * 0.1, s * 0.8, s * 0.8))
        p.drawLine(QPoint(int(s * 0.36), int(s * 0.36)), QPoint(int(s * 0.64), int(s * 0.64)))
        p.drawLine(QPoint(int(s * 0.64), int(s * 0.36)), QPoint(int(s * 0.36), int(s * 0.64)))
    elif name in ("ok", "info", "warn", "error"):
        col = QColor({"ok": THEME.green, "info": THEME.accent, "warn": THEME.orange, "error": THEME.red}[name])
        p.setPen(Qt.PenStyle.NoPen)
        p.setBrush(col)
        if name == "warn":
            path = QPainterPath()
            path.moveTo(s * 0.5, s * 0.08)
            path.lineTo(s * 0.95, s * 0.88)
            path.lineTo(s * 0.05, s * 0.88)
            path.closeSubpath()
            p.drawPath(path)
        else:
            p.drawEllipse(QRectF(s * 0.06, s * 0.06, s * 0.88, s * 0.88))
        p.setPen(QPen(QColor("white"), 1.8, Qt.PenStyle.SolidLine, Qt.PenCapStyle.RoundCap, Qt.PenJoinStyle.RoundJoin))
        if name == "ok":
            p.drawPolyline([QPoint(int(s * 0.3), int(s * 0.52)), QPoint(int(s * 0.45), int(s * 0.66)),
                            QPoint(int(s * 0.7), int(s * 0.36))])
        elif name == "info":
            p.drawLine(QPoint(int(s * 0.5), int(s * 0.46)), QPoint(int(s * 0.5), int(s * 0.7)))
            p.drawPoint(QPoint(int(s * 0.5), int(s * 0.3)))
        elif name == "warn":
            p.drawLine(QPoint(int(s * 0.5), int(s * 0.38)), QPoint(int(s * 0.5), int(s * 0.6)))
            p.drawPoint(QPoint(int(s * 0.5), int(s * 0.74)))
        else:
            p.drawLine(QPoint(int(s * 0.36), int(s * 0.36)), QPoint(int(s * 0.64), int(s * 0.64)))
            p.drawLine(QPoint(int(s * 0.64), int(s * 0.36)), QPoint(int(s * 0.36), int(s * 0.64)))
    elif name == "size":                                   # a small and a large square: icon size
        p.setPen(Qt.PenStyle.NoPen)
        p.setBrush(c)
        p.drawRoundedRect(QRectF(s * 0.08, s * 0.58, s * 0.28, s * 0.28), 1.5, 1.5)
        p.drawRoundedRect(QRectF(s * 0.44, s * 0.14, s * 0.48, s * 0.72), 2, 2)
    elif name == "spacing":                                # two squares and the gap between them
        p.setPen(Qt.PenStyle.NoPen)
        p.setBrush(c)
        p.drawRoundedRect(QRectF(s * 0.08, s * 0.28, s * 0.3, s * 0.44), 1.5, 1.5)
        p.drawRoundedRect(QRectF(s * 0.62, s * 0.28, s * 0.3, s * 0.44), 1.5, 1.5)
        p.setPen(QPen(c, 1.2, Qt.PenStyle.SolidLine, Qt.PenCapStyle.RoundCap, Qt.PenJoinStyle.RoundJoin))
        p.drawLine(QPoint(int(s * 0.42), int(s * 0.5)), QPoint(int(s * 0.58), int(s * 0.5)))
    elif name == "sort":                                   # three lines, shortest at the bottom
        for gy, w in ((0.25, 0.7), (0.5, 0.5), (0.75, 0.3)):
            p.drawLine(QPoint(int(s * 0.15), int(s * gy)), QPoint(int(s * (0.15 + w)), int(s * gy)))
    elif name == "search":                                 # a magnifier
        p.drawEllipse(QRectF(s * 0.12, s * 0.12, s * 0.52, s * 0.52))
        p.drawLine(QPoint(int(s * 0.58), int(s * 0.58)), QPoint(int(s * 0.88), int(s * 0.88)))
    elif name == "film":
        p.setPen(QPen(c, 1.5, Qt.PenStyle.SolidLine, Qt.PenCapStyle.RoundCap, Qt.PenJoinStyle.RoundJoin))
        p.drawRoundedRect(QRectF(s * 0.1, s * 0.2, s * 0.8, s * 0.6), 2, 2)
        p.setPen(Qt.PenStyle.NoPen)
        p.setBrush(c)
        for gy in (0.28, 0.46, 0.64):                      # the strip's sprocket holes
            p.drawRect(QRectF(s * 0.16, s * gy, s * 0.09, s * 0.09))
            p.drawRect(QRectF(s * 0.75, s * gy, s * 0.09, s * 0.09))
        path = QPainterPath()
        path.moveTo(s * 0.42, s * 0.36)
        path.lineTo(s * 0.62, s * 0.5)
        path.lineTo(s * 0.42, s * 0.64)
        path.closeSubpath()
        p.drawPath(path)
    elif name == "funnel":                                 # a filter
        path = QPainterPath()
        path.moveTo(s * 0.12, s * 0.18)
        path.lineTo(s * 0.88, s * 0.18)
        path.lineTo(s * 0.58, s * 0.52)
        path.lineTo(s * 0.58, s * 0.82)
        path.lineTo(s * 0.42, s * 0.74)
        path.lineTo(s * 0.42, s * 0.52)
        path.closeSubpath()
        p.drawPath(path)
    elif name == "trash":                                  # a bin with its lid
        p.drawLine(QPoint(int(s * 0.14), int(s * 0.26)), QPoint(int(s * 0.86), int(s * 0.26)))
        p.drawLine(QPoint(int(s * 0.38), int(s * 0.26)), QPoint(int(s * 0.38), int(s * 0.16)))
        p.drawLine(QPoint(int(s * 0.38), int(s * 0.16)), QPoint(int(s * 0.62), int(s * 0.16)))
        p.drawLine(QPoint(int(s * 0.62), int(s * 0.16)), QPoint(int(s * 0.62), int(s * 0.26)))
        p.drawPolyline([QPoint(int(s * 0.22), int(s * 0.26)), QPoint(int(s * 0.28), int(s * 0.86)),
                        QPoint(int(s * 0.72), int(s * 0.86)), QPoint(int(s * 0.78), int(s * 0.26))])
        p.drawLine(QPoint(int(s * 0.42), int(s * 0.4)), QPoint(int(s * 0.44), int(s * 0.72)))
        p.drawLine(QPoint(int(s * 0.58), int(s * 0.4)), QPoint(int(s * 0.56), int(s * 0.72)))
    elif name == "tag":                                    # a luggage tag, pointing left, with its hole
        path = QPainterPath()
        path.moveTo(s * 0.08, s * 0.5)
        path.lineTo(s * 0.36, s * 0.2)
        path.lineTo(s * 0.88, s * 0.2)
        path.lineTo(s * 0.88, s * 0.8)
        path.lineTo(s * 0.36, s * 0.8)
        path.closeSubpath()
        p.drawPath(path)
        p.drawEllipse(QRectF(s * 0.33, s * 0.43, s * 0.14, s * 0.14))
    elif name == "arrow":
        p.setPen(QPen(c, 2.2, Qt.PenStyle.SolidLine, Qt.PenCapStyle.RoundCap, Qt.PenJoinStyle.RoundJoin))
        p.drawLine(QPoint(int(s * 0.15), int(s * 0.5)), QPoint(int(s * 0.82), int(s * 0.5)))
        p.drawPolyline([QPoint(int(s * 0.58), int(s * 0.26)), QPoint(int(s * 0.84), int(s * 0.5)),
                        QPoint(int(s * 0.58), int(s * 0.74))])
    p.end()
    return QIcon(pm)


# ============================================================================ helpers


def mounts() -> dict[str, str]:
    """mount point → filesystem type (exfat, apfs, msdos…)."""
    out: dict[str, str] = {}
    try:
        if IS_MAC:
            text = subprocess.run(["mount"], capture_output=True, text=True, timeout=5).stdout
            for line in text.splitlines():
                m = re.match(r"^.+? on (.+) \(([^,)]+)", line)
                if m:
                    out[m.group(1)] = m.group(2)
        else:
            with open("/proc/mounts", encoding="utf-8") as f:
                for line in f:
                    parts = line.split()
                    if len(parts) >= 3:
                        out[parts[1].replace("\\040", " ")] = parts[2]
    except Exception:  # noqa: BLE001
        pass
    return out


FS_NAMES = {"exfat": "exFAT", "msdos": "FAT32", "vfat": "FAT32", "apfs": "APFS", "hfs": "Mac OS Extended",
            "ntfs": "NTFS", "tmpfs": "tmpfs", "ext4": "ext4", "smbfs": "SMB"}


def volume_name(path: Path) -> str:
    root = engine.volume_root(path)
    if str(root) == "/":
        return boot_volume_name()
    return root.name


def boot_volume_name() -> str:
    try:
        for name in os.listdir(VOLUMES):
            if os.path.realpath(VOLUMES / name) == "/":
                return name
    except OSError:
        pass
    return "Macintosh HD" if IS_MAC else "Computer"


def external_volumes() -> list[Path]:
    out = []
    try:
        for name in sorted(os.listdir(VOLUMES), key=str.lower):
            p = VOLUMES / name
            if name.startswith(".") or os.path.realpath(p) == "/" or not p.is_dir():
                continue
            if name.startswith("com.apple.") or name == "Recovery":
                continue
            out.append(p)
    except OSError:
        pass
    return out


def is_external(path: Path) -> bool:
    root = engine.volume_root(path)
    return str(root) != "/" and str(root).startswith(str(VOLUMES) + os.sep)


def two_lines(fm: QFontMetrics, text: str, width: int) -> list[str]:
    """Finder-style name: up to two lines, broken at a natural spot, the rest elided in the middle."""
    if fm.horizontalAdvance(text) <= width:
        return [text]
    lo, hi = 1, len(text)
    while lo < hi:
        mid = (lo + hi + 1) // 2
        if fm.horizontalAdvance(text[:mid]) <= width:
            lo = mid
        else:
            hi = mid - 1
    cut = lo
    for i in range(lo, max(lo // 2, 1), -1):
        if text[i - 1] in " _-.":
            cut = i
            break
    first, rest = text[:cut], text[cut:]
    return [first.rstrip(), fm.elidedText(rest, Qt.TextElideMode.ElideMiddle, width)]


def kind_of(path: str) -> str:
    ext = os.path.splitext(path)[1].lower()
    return "image" if ext in IMAGE_EXT else "video" if ext in VIDEO_EXT else "other"


# ============================================================================ tags


TAG_COLORS = ["#FF453A", "#FF9F0A", "#FFCC00", "#32D74B", "#0A84FF", "#BF5AF2", "#FF6482", "#64D2FF", "#AC8E68"]
_TAG_DOTS: dict[str, QIcon] = {}


def tag_color(name: str) -> str:
    """A tag's colour — the same every time for the same tag (any case), like Finder's."""
    return TAG_COLORS[zlib.crc32(shared_tags.fold(name).encode("utf-8")) % len(TAG_COLORS)]


def tag_dot(name: str, size: int = 12) -> QIcon:
    color = tag_color(name)
    key = f"{color}/{size}"
    if key not in _TAG_DOTS:
        dpr = 3
        pm = QPixmap(size * dpr, size * dpr)
        pm.fill(Qt.GlobalColor.transparent)
        pm.setDevicePixelRatio(dpr)
        p = QPainter(pm)
        p.setRenderHint(QPainter.RenderHint.Antialiasing)
        p.setPen(Qt.PenStyle.NoPen)
        p.setBrush(QColor(color))
        p.drawEllipse(QRectF(size * 0.12, size * 0.12, size * 0.76, size * 0.76))
        p.end()
        _TAG_DOTS[key] = QIcon(pm)
    return _TAG_DOTS[key]


class _TagEvents(QObject):
    changed = Signal()              # a tag was added or removed somewhere: views repaint, the sidebar recounts


_TAGS: shared_tags.TagStore | None = None
_TAG_EVENTS: _TagEvents | None = None


def tag_store() -> shared_tags.TagStore:
    """The tags on this Mac and every connected drive (one store for the whole app)."""
    global _TAGS
    if _TAGS is None:
        _TAGS = shared_tags.TagStore(is_drive=lambda p: is_external(Path(p)), volumes=external_volumes)
    return _TAGS


def tag_events() -> _TagEvents:
    global _TAG_EVENTS
    if _TAG_EVENTS is None:
        _TAG_EVENTS = _TagEvents()
    return _TAG_EVENTS


def tags_changed() -> None:
    tag_events().changed.emit()


_SIMPCITY_WINDOWS: list = []


def open_simpcity(folder: str, parent: QWidget | None = None) -> None:
    """Right-click a person's folder ▸ "Download from SimpCity…": the downloader window
    (simpcity_downloader.py). From inside the person's "simpcity" folder, the person is the folder above."""
    try:
        import simpcity_downloader
    except ModuleNotFoundError:
        QMessageBox.information(parent, "SimpCity", "The SimpCity downloader needs Qt WebEngine (part of PySide6).\n"
                                "Run mac/run.sh once to set it up, then try again.")
        return
    import simpcity
    person = os.path.dirname(folder) if os.path.basename(folder).lower() == simpcity.FOLDER else folder
    win = simpcity_downloader.SimpCityWindow(person, tags=tag_store())
    win.setAttribute(Qt.WidgetAttribute.WA_DeleteOnClose)
    win.finished.connect(lambda _folder, files: files and tags_changed())
    win.destroyed.connect(lambda _=None, w=win: _SIMPCITY_WINDOWS.remove(w) if w in _SIMPCITY_WINDOWS else None)
    _SIMPCITY_WINDOWS.append(win)
    win.show()


def has_tag(path: str, tag: str) -> bool:
    f = shared_tags.fold(tag)
    return any(shared_tags.fold(t) == f for t in tag_store().tags(path, fresh=False))


def tag_counts(files: list[str]) -> dict[str, tuple[str, int]]:
    """fold(tag) → (the tag as first written, how many of `files` carry it) — one pass over the files."""
    out: dict[str, tuple[str, int]] = {}
    for f in files:
        for t in tag_store().tags(f, fresh=False):
            k = shared_tags.fold(t)
            name, n = out.get(k, (t, 0))
            out[k] = (name, n + 1)
    return out


class _Expanded(QObject):
    done = Signal(object, int)      # the files, how many folders they came from


_EXPANDING: set[_Expanded] = set()


def expand_files(paths: list[str], then) -> None:
    """The files a selection tags: its files as they are, and for each folder everything inside it
    (hidden items, app bundles and gallery sidecars left out). Folders are walked on a thread; `then(files,
    folder_count)` is called on the UI thread either way."""
    folders = [p for p in paths if os.path.isdir(p)]
    files = [p for p in paths if p not in folders and shared_tags.taggable(p)]
    if not folders:
        then(files, 0)
        return
    sig = _Expanded()
    _EXPANDING.add(sig)

    def finish(out: list, n: int) -> None:
        _EXPANDING.discard(sig)
        then(out, n)

    sig.done.connect(finish, Qt.ConnectionType.QueuedConnection)

    def work() -> None:
        out = list(files)
        for folder in folders:
            for dirpath, dirnames, filenames in os.walk(folder):
                dirnames[:] = sorted(d for d in dirnames
                                     if not d.startswith(".") and os.path.splitext(d)[1].lower() not in _BUNDLE_EXT)
                out.extend(os.path.join(dirpath, n) for n in sorted(filenames, key=natural_key)
                           if shared_tags.taggable(n))
        sig.done.emit(out, len(folders))

    threading.Thread(target=work, name="tag-expand", daemon=True).start()


class _Carried(QObject):
    done = Signal(object)           # what the folder's files carry (shared_tags.TagStore.read_folder)


_CARRYING: set[_Carried] = set()
_CARRIED_AT: dict[str, float] = {}
TRANSFERRING = False                # a move or copy is running: folders are re-checked once it's done


def check_carried(folder: str) -> None:
    """A folder was opened: files moved or copied into it by Finder (or the Files app, cp, AirDrop…)
    bring their tags in the file itself, and tags changed in Finder show up — read on a thread, squared
    with the tables here (see shared_tags.py, "Tags that travel with the file"). Not while a transfer
    runs — its folders change by the second, and the transfer carries its own files' tags at the end."""
    if TRANSFERRING:
        return
    now = time.monotonic()
    if now - _CARRIED_AT.get(folder, 0.0) < 3:
        return
    _CARRIED_AT[folder] = now
    store = tag_store()
    sig = _Carried()
    _CARRYING.add(sig)

    def finish(found: list) -> None:
        _CARRYING.discard(sig)
        if found and store.apply_carried(found):
            tags_changed()

    sig.done.connect(finish, Qt.ConnectionType.QueuedConnection)

    def work() -> None:
        try:
            with os.scandir(folder) as it:
                files = [e.path for e in it if e.is_file(follow_symlinks=False) or e.is_dir(follow_symlinks=False)]
        except OSError:
            files = []
        sig.done.emit(store.read_folder(files))

    threading.Thread(target=work, name="tags-carried", daemon=True).start()


def describe_items(items: list[str], inside: int = 0) -> str:
    """“Kelsey” · 3 folders and 12 files · “Kelsey” and the 1,284 files inside."""
    folders = sum(1 for p in items if os.path.isdir(p))
    files = len(items) - folders
    if len(items) == 1:
        text = f"“{os.path.basename(items[0].rstrip(os.sep))}”"
    else:
        parts = ([f"{folders:,} folder{'s' if folders != 1 else ''}"] if folders else []) + \
                ([f"{files:,} file{'s' if files != 1 else ''}"] if files else [])
        text = " and ".join(parts)
    if inside:
        text += f" and the {inside:,} file{'s' if inside != 1 else ''} inside"
    return text


def ask_inside(parent: QWidget | None, folders: list[str], inside: int, question: str, title: str) -> bool | None:
    """Folders are being tagged: do the files inside them go too? True (folder and files), False (the
    folder only) or None (cancelled)."""
    one = len(folders) == 1
    box = QMessageBox(parent)
    box.setIcon(QMessageBox.Icon.Question)
    box.setWindowTitle(title)
    box.setText(question)
    box.setInformativeText(f"{'It holds' if one else 'They hold'} {inside:,} file{'s' if inside != 1 else ''} "
                           "(in subfolders too).")
    both = box.addButton("Folder and Files Inside" if one else "Folders and Files Inside",
                         QMessageBox.ButtonRole.YesRole)
    only = box.addButton("Folder Only" if one else "Folders Only", QMessageBox.ButtonRole.NoRole)
    box.addButton(QMessageBox.StandardButton.Cancel)
    box.setDefaultButton(both)
    box.exec()
    clicked = box.clickedButton()
    return True if clicked is both else False if clicked is only else None


# ============================================================================ thumbnails


THUMB_PX = 512          # one master thumbnail per file; icons of every size are drawn from it
_QL_BATCH = 4           # files per qlmanage run: few, so results come in as they're made, not all at the end


def thumb_cache_dir() -> Path:
    """Where thumbnails persist between launches: ~/Library/Caches on a Mac (the system may clear it
    under pressure — nothing is lost but a re-render). SAFE_FINDER_THUMB_CACHE overrides it (tests)."""
    env = os.environ.get("SAFE_FINDER_THUMB_CACHE")
    if env:
        return Path(env)
    if IS_MAC:
        return Path.home() / "Library" / "Caches" / "PhotoBrowser" / "SafeFinderThumbs"
    return Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache") / "PhotoBrowser" / "SafeFinderThumbs"


def thumb_key(path: str, mtime: float) -> str:
    return f"{path}|{int(mtime)}"


def thumb_file(key: str) -> Path:
    h = hashlib.sha1(key.encode("utf-8", "surrogateescape")).hexdigest()
    return thumb_cache_dir() / h[:2] / (h + ".jpg")


def _save_thumb(img: QImage, f: Path) -> None:
    """Into the disk cache as a JPEG (transparency flattened onto dark grey), written whole then renamed."""
    try:
        f.parent.mkdir(parents=True, exist_ok=True)
        if img.hasAlphaChannel():
            flat = QImage(img.size(), QImage.Format.Format_RGB32)
            flat.fill(QColor(44, 44, 46))
            painter = QPainter(flat)
            painter.drawImage(0, 0, img)
            painter.end()
            img = flat
        tmp = f.with_name(f.name + ".part")
        if img.save(str(tmp), "JPG", 88):
            os.replace(tmp, f)
    except OSError:
        pass


class _ThumbSignals(QObject):
    done = Signal(str, QImage)
    skipped = Signal(str)        # a prefetch from a listing that's gone — forget it was asked for


class _QuickLookRunner:
    """Thumbnails qlmanage makes (videos, and images Qt/PIL can't read): one qlmanage run per batch
    of files on its own thread, so a folder of videos costs a few process launches rather than one
    per file. Each result goes to the disk cache and comes back through `done`."""

    def __init__(self, signals: _ThumbSignals) -> None:
        self.signals = signals
        self._queue: list[tuple[str, str]] = []
        self._lock = threading.Lock()
        self._wake = threading.Event()
        threading.Thread(target=self._run, name="quicklook-thumbs", daemon=True).start()

    def enqueue(self, key: str, path: str) -> None:
        with self._lock:
            self._queue.append((key, path))
        self._wake.set()

    def _run(self) -> None:
        while True:
            self._wake.wait()
            with self._lock:
                if not self._queue:
                    self._wake.clear()
                    continue
                batch, self._queue = self._queue[:_QL_BATCH], self._queue[_QL_BATCH:]
            self._render(batch)

    def _render(self, batch: list[tuple[str, str]]) -> None:
        # qlmanage names each output "<file name>.png", so a batch holds one file of each name;
        # the rest wait for the next run.
        by_name: dict[str, tuple[str, str]] = {}
        later: list[tuple[str, str]] = []
        for key, path in batch:
            name = os.path.basename(path)
            if name in by_name:
                later.append((key, path))
            else:
                by_name[name] = (key, path)
        if later:
            with self._lock:
                self._queue = later + self._queue
            self._wake.set()
        with tempfile.TemporaryDirectory() as td:
            try:
                subprocess.run(["qlmanage", "-t", "-s", str(THUMB_PX), "-o", td, *(p for _k, p in by_name.values())],
                               capture_output=True, timeout=180)
            except (OSError, subprocess.SubprocessError):
                pass
            for name, (key, _path) in by_name.items():
                out = os.path.join(td, name + ".png")
                img = QImage(out) if os.path.exists(out) else QImage()
                if not img.isNull():
                    _save_thumb(img, thumb_file(key))
                self.signals.done.emit(key, img)


def thumb_helper_source() -> Path | None:
    """thumb_helper.swift: next to this file, or inside Safe Finder.app's Resources when frozen."""
    candidates = [HERE / "thumb_helper.swift"]
    if getattr(sys, "frozen", False):
        contents = Path(sys.executable).resolve().parent.parent
        candidates += [contents / "Resources" / "thumb_helper.swift",
                       Path(getattr(sys, "_MEIPASS", HERE)) / "thumb_helper.swift"]
    return next((c for c in candidates if c.is_file()), None)


def build_thumb_helper() -> list[str] | None:
    """The command that runs the thumbnail helper, building it (once, into ~/Library/Caches/PhotoBrowser)
    when it's missing or older than its source. None without Xcode's tools — Quick Look does it all then.
    SAFE_FINDER_THUMB_HELPER names a stand-in command (tests)."""
    env = os.environ.get("SAFE_FINDER_THUMB_HELPER")
    if env:
        return env.split("\x1f") if "\x1f" in env else [env]
    src = thumb_helper_source()
    if not IS_MAC or src is None:
        return None
    out = Path.home() / "Library" / "Caches" / "PhotoBrowser" / "thumb_helper"
    if out.is_file() and out.stat().st_mtime >= src.stat().st_mtime:
        return [str(out)]
    # Don't call swiftc when the Command Line Tools aren't installed: the stub would pop an installer.
    if subprocess.run(["xcode-select", "-p"], capture_output=True).returncode != 0:
        return None
    out.parent.mkdir(parents=True, exist_ok=True)
    try:
        r = subprocess.run(["xcrun", "swiftc", "-O", "-swift-version", "5", "-o", str(out), str(src)],
                           capture_output=True, text=True, timeout=600)
    except (OSError, subprocess.SubprocessError):
        return None
    return [str(out)] if r.returncode == 0 and out.is_file() else None


class _FrameRunner:
    """Video frames, and previews of images Qt and Pillow can't read (RAW mostly), from
    thumb_helper.swift: AVFoundation/ImageIO in one long-running helper process, a few at a time
    (IN_FLIGHT), each shown the moment it's made. The tiles on screen go first, the newest of them
    first (where the user is looking now); prefetches follow, and those for a listing that's been left
    are dropped. A prefetch waits a moment (HOLD) first, so the first paint of a listing gets its tiles
    in ahead of a prefetch that arrived before it. Anything the helper can't do, or takes too long over,
    goes on to Quick Look — and everything does when the helper can't be built (no Xcode tools). When
    the helper dies, what it had in hand is tried again one at a time ("suspects"), so only the file
    that brought it down goes without."""
    IN_FLIGHT = 4
    HOLD = 0.2                  # seconds a prefetch waits, for the visible tiles of a fresh listing
    TIMEOUT = 30.0              # seconds before a file that's stuck is handed to Quick Look
    RESTARTS = 10               # helper deaths before giving up on it for this run

    def __init__(self, signals: _ThumbSignals, ql: "_QuickLookRunner | None", owner: "Thumbnails") -> None:
        self.signals, self.ql, self.owner = signals, ql, owner
        self._now: list[tuple[str, str]] = []                      # on screen; taken from the end
        self._later: deque[tuple[str, str, int, float]] = deque() # prefetches (+ gen, queued at), oldest first
        self._urgent: set[str] = set()                             # keys wanted on screen
        self._suspects: list[tuple[str, str]] = []                 # in flight when a helper died: alone next
        self._suspected: set[str] = set()
        self._busy: dict[str, tuple[str, str, float, subprocess.Popen]] = {}   # id → key, path, started, helper
        self._lock = threading.Lock()
        self._wake = threading.Event()
        self._proc: subprocess.Popen | None = None
        self._cmd: list[str] | None = None
        self._ready = False                      # built (or found) — until then Quick Look stands in
        self._deaths = 0
        self._dead = False
        self._ids = 0
        threading.Thread(target=self._build, name="thumb-helper-build", daemon=True).start()
        threading.Thread(target=self._run, name="thumb-helper", daemon=True).start()

    def _build(self) -> None:
        cmd = build_thumb_helper()                 # seconds the first time (swiftc), instant after
        with self._lock:
            self._cmd, self._dead, self._ready = cmd, cmd is None, True
        self._wake.set()

    def enqueue(self, key: str, path: str, gen: int | None) -> None:
        with self._lock:
            if gen is None or key in self._urgent:
                self._now.append((key, path))
            else:
                self._later.append((key, path, gen, time.monotonic()))
        self._wake.set()

    def promote(self, key: str) -> None:
        """A tile asked for again (it's on screen): if its prefetch is still waiting, it moves to the
        front; if it hasn't reached the queue yet, it'll go to the front when it does."""
        with self._lock:
            if key in self._urgent:
                return
            self._urgent.add(key)
            for item in self._later:
                if item[0] == key:
                    self._later.remove(item)
                    self._now.append((key, item[1]))
                    break
        self._wake.set()

    def _next(self) -> tuple[str, str] | float | None:
        """Under the lock: what to send next — suspects alone, then on-screen (newest first), then
        prefetches still wanted. A number means: nothing yet, look again in that many seconds."""
        if self._suspects:
            return self._suspects.pop(0) if not self._busy else None
        if self._now:
            return self._now.pop()
        while self._later:
            key, path, gen, at = self._later[0]
            if gen != self.owner.generation:
                self._later.popleft()
                self.signals.skipped.emit(key)                     # a listing that's been left
                continue
            wait = at + self.HOLD - time.monotonic()
            if wait > 0:
                return wait
            self._later.popleft()
            return key, path
        return None

    def _fallback(self, key: str, path: str) -> None:
        if self.ql is not None:
            self.ql.enqueue(key, path)
        else:
            self.signals.done.emit(key, QImage())

    def _run(self) -> None:
        pause = 1.0
        while True:
            self._wake.wait(timeout=pause)
            self._wake.clear()
            self._expire()
            pause = 1.0
            while True:
                with self._lock:
                    helper = self._ready and not self._dead
                    alone = any(job[0] in self._suspected for job in self._busy.values())
                    if helper and (len(self._busy) >= self.IN_FLIGHT or alone):
                        break
                    item = self._next()
                    if item is None:
                        break
                    if isinstance(item, float):
                        pause = min(pause, item)
                        break
                if not helper or not self._send(self._cmd, *item):
                    self._fallback(*item)

    def _send(self, cmd: list[str] | None, key: str, path: str) -> bool:
        if cmd is None:
            return False
        if self._proc is None or self._proc.poll() is not None:
            try:
                self._proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                              stderr=subprocess.DEVNULL, text=True, bufsize=1)
            except OSError:
                self._dead = True
                return False
            threading.Thread(target=self._read, args=(self._proc,), name="thumb-helper-out", daemon=True).start()
        self._ids += 1
        rid = str(self._ids)
        with self._lock:
            self._busy[rid] = (key, path, time.monotonic(), self._proc)
        line = json.dumps({"id": rid, "path": path, "out": str(thumb_file(key)), "px": THUMB_PX,
                           "video": kind_of(path) == "video"}, ensure_ascii=False)
        try:
            self._proc.stdin.write(line + "\n")
            self._proc.stdin.flush()
        except (OSError, ValueError):
            with self._lock:
                self._busy.pop(rid, None)
            return False
        return True

    def _read(self, proc: subprocess.Popen) -> None:
        for line in proc.stdout:
            try:
                answer = json.loads(line)
            except ValueError:
                continue
            with self._lock:
                job = self._busy.pop(str(answer.get("id")), None)
            if job is None:
                continue                                           # timed out and handed on already
            key, path = job[0], job[1]
            with self._lock:
                self._urgent.discard(key)
                self._suspected.discard(key)
            img = QImage(str(thumb_file(key))) if answer.get("ok") else QImage()
            if img.isNull():
                self._fallback(key, path)
            else:
                self.signals.done.emit(key, img)
            self._wake.set()
        # The helper ended (crashed, or was killed). What it had in hand is tried again, each alone, with
        # a new one; a file that takes it down on its own goes on to Quick Look.
        with self._lock:
            mine = [(rid, job) for rid, job in self._busy.items() if job[3] is proc]
            for rid, _job in mine:
                del self._busy[rid]
            self._deaths += 1
            if self._deaths >= self.RESTARTS:
                self._dead = True
            give_up = []
            for _rid, job in mine:
                if job[0] in self._suspected or self._dead:
                    self._suspected.discard(job[0])
                    give_up.append(job)
                else:
                    self._suspected.add(job[0])
                    self._suspects.append((job[0], job[1]))
        for job in give_up:
            self._fallback(job[0], job[1])
        self._wake.set()

    def _expire(self) -> None:
        now = time.monotonic()
        with self._lock:
            stuck = [(rid, job) for rid, job in self._busy.items() if now - job[2] > self.TIMEOUT]
            for rid, job in stuck:
                del self._busy[rid]
                self._suspected.discard(job[0])
        for _rid, job in stuck:
            self._fallback(job[0], job[1])


class _ThumbJob(QRunnable):
    """One thumbnail: the disk cache first, else rendered from the file (PIL, then Qt), else handed
    to Quick Look's batch runner. A prefetch job from a listing the user has left is skipped."""

    def __init__(self, key: str, path: str, signals: _ThumbSignals, ql: "_QuickLookRunner | None",
                 owner: "Thumbnails", gen: int | None, frames: "_FrameRunner | None" = None) -> None:
        super().__init__()
        self.key, self.path, self.signals, self.ql, self.owner, self.gen = key, path, signals, ql, owner, gen
        self.frames = frames
        self.setAutoDelete(True)

    def run(self) -> None:
        if self.gen is not None and self.gen != self.owner.generation:
            self.signals.skipped.emit(self.key)
            return
        img = QImage()
        try:
            f = thumb_file(self.key)
            if f.is_file():
                img = QImage(str(f))
            if img.isNull():
                img = self._load()
                if img.isNull() and kind_of(self.path) in ("image", "video"):
                    if self.frames is not None:
                        self.frames.enqueue(self.key, self.path, self.gen)   # the helper answers later
                        return
                    if self.ql is not None:
                        self.ql.enqueue(self.key, self.path)                  # Quick Look answers later
                        return
                if not img.isNull():
                    _save_thumb(img, f)
        except Exception:  # noqa: BLE001 — a bad file just keeps its icon
            img = QImage()
        self.signals.done.emit(self.key, img)

    def _load(self) -> QImage:
        kind = kind_of(self.path)
        ext = os.path.splitext(self.path)[1].lower()
        if kind != "image" or ext in RAW_EXT:
            return QImage()
        if PIL_OK:
            try:
                with Image.open(self.path) as im:
                    im.draft("RGB", (THUMB_PX * 2, THUMB_PX * 2))
                    im = ImageOps.exif_transpose(im)
                    im.thumbnail((THUMB_PX, THUMB_PX))
                    im = im.convert("RGBA")
                    data = im.tobytes("raw", "RGBA")
                    return QImage(data, im.width, im.height, im.width * 4, QImage.Format.Format_RGBA8888).copy()
            except Exception:  # noqa: BLE001
                pass
        reader = QImageReader(self.path)
        reader.setAutoTransform(True)
        size = reader.size()
        if size.isValid():
            reader.setScaledSize(size.scaled(THUMB_PX, THUMB_PX, Qt.AspectRatioMode.KeepAspectRatio))
        return reader.read()


class Thumbnails(QObject):
    """Async thumbnail cache: memory (LRU, byte budget) over a disk cache that persists between
    launches. One master thumbnail (THUMB_PX) per file serves every icon size — the delegate scales
    it — so changing the thumbnail size redraws at once instead of re-rendering everything. `get`
    returns the pixmap, or None and requests it (visible tiles first); `prefetch` queues the rest of
    a listing behind them, so scrolling finds its thumbnails ready; `new_listing` drops a left
    listing's prefetch."""
    ready = Signal()

    def __init__(self) -> None:
        super().__init__()
        self._cache: OrderedDict[str, QPixmap | None] = OrderedDict()
        self._bytes = 0                                    # what the cached pixmaps hold, roughly
        self._pending: set[str] = set()
        self.generation = 0
        self._pool = QThreadPool(self)
        self._pool.setMaxThreadCount(max(4, min(8, os.cpu_count() or 4)))
        self._signals = _ThumbSignals()
        self._signals.done.connect(self._done, Qt.ConnectionType.QueuedConnection)
        self._signals.skipped.connect(self._pending.discard, Qt.ConnectionType.QueuedConnection)
        self._ql = _QuickLookRunner(self._signals) if IS_MAC and shutil.which("qlmanage") else None
        self._frames = _FrameRunner(self._signals, self._ql, self) \
            if IS_MAC or os.environ.get("SAFE_FINDER_THUMB_HELPER") else None
        self._tick = QTimer(self)
        self._tick.setSingleShot(True)
        self._tick.setInterval(60)
        self._tick.timeout.connect(self.ready.emit)

    def get(self, path: str, mtime: float, px: int = 0) -> QPixmap | None:
        key = thumb_key(path, mtime)
        if key in self._cache:
            self._cache.move_to_end(key)
            return self._cache[key]
        self._request(key, path, gen=None, priority=1)
        return None

    def prefetch(self, items: list[tuple[str, float]]) -> None:
        for path, mtime in items:
            key = thumb_key(path, mtime)
            if key not in self._cache:
                self._request(key, path, gen=self.generation, priority=0)

    def new_listing(self) -> None:
        """The pane moved on: prefetches still queued for the old listing are skipped as they come up."""
        self.generation += 1

    def _request(self, key: str, path: str, gen: int | None, priority: int) -> None:
        if key in self._pending:
            if gen is None and self._frames is not None:
                self._frames.promote(key)                  # on screen now: ahead of the prefetches
            return
        self._pending.add(key)
        self._pool.start(_ThumbJob(key, path, self._signals, self._ql, self, gen, self._frames), priority)

    def _done(self, key: str, img: QImage) -> None:
        self._pending.discard(key)
        pm = None if img.isNull() else QPixmap.fromImage(img)
        self._cache[key] = pm
        self._bytes += self._size(pm)
        while self._cache and (len(self._cache) > 3000 or self._bytes > 600 * 1024 * 1024):
            _k, old = self._cache.popitem(last=False)
            self._bytes -= self._size(old)
        self._tick.start()

    def forget(self, paths: list[str]) -> None:
        """Files rewritten in place keeping their modified date (a crop): their thumbnails, in memory and
        on disk, go, so they're made again from the new pixels."""
        for path in paths:
            try:
                key = thumb_key(path, os.stat(path).st_mtime)
            except OSError:
                continue
            self._bytes -= self._size(self._cache.pop(key, None))
            try:
                thumb_file(key).unlink()
            except OSError:
                pass
        self._tick.start()

    @staticmethod
    def _size(pm: QPixmap | None) -> int:
        return pm.width() * pm.height() * 4 if pm is not None else 0


THUMBS: Thumbnails | None = None


# ============================================================================ views


class GridDelegate(QStyledItemDelegate):
    """Finder icon view: thumbnail or icon on a rounded backdrop when selected, two-line name with
    a blue pill when selected."""

    def __init__(self, pane: "Pane") -> None:
        super().__init__(pane)
        self.pane = pane

    def sizeHint(self, option, index) -> QSize:  # noqa: N802
        return self.pane.cell_size()

    def paint(self, p: QPainter, option: QStyleOptionViewItem, index: QModelIndex) -> None:
        model: QFileSystemModel = self.pane.model
        path = model.filePath(index)
        is_dir = model.isDir(index)
        r = option.rect
        s = self.pane.icon_px
        pad, inset = self.pane.tile_pad(), self.pane.tile_inset()
        icon_rect = QRect(r.x() + (r.width() - s) // 2, r.y() + pad, s, s)
        selected = bool(option.state & QStyle.StateFlag.State_Selected)
        focused = self.pane.view_has_focus()
        p.save()
        p.setClipRect(r)                                   # tight grids: never paint over the neighbours
        p.setRenderHint(QPainter.RenderHint.Antialiasing)
        p.setRenderHint(QPainter.RenderHint.SmoothPixmapTransform)
        if selected:
            p.setPen(Qt.PenStyle.NoPen)
            p.setBrush(qc(THEME.select_bg))
            p.drawRoundedRect(QRectF(icon_rect.adjusted(-inset, -inset, inset, inset)), 7, 7)
        if self.pane.drop_target == path:
            p.setPen(QPen(QColor(THEME.accent), 2))
            p.setBrush(QColor(THEME.accent).lighter(170) if not THEME.dark else QColor(10, 132, 255, 50))
            p.drawRoundedRect(QRectF(icon_rect.adjusted(-inset, -inset, inset, inset)), 7, 7)
        thumb = None
        if not is_dir and kind_of(path) != "other" and THUMBS is not None:
            thumb = THUMBS.get(path, model.lastModified(index).toSecsSinceEpoch(), s)
        if thumb is not None:
            shown = self._draw_thumb(p, thumb, icon_rect, kind_of(path) == "video")
        else:
            shown = icon_rect.adjusted(2, 2, -2, -2)
            model.fileIcon(index).paint(p, shown)
        tags = tag_store().tags(path, fresh=False)
        if tags:
            self._draw_tags(p, tags, shown, option.font, not is_dir and kind_of(path) == "video" and thumb is not None)
        # name
        fm = QFontMetrics(option.font)
        width = r.width() - 2 * inset
        lines = two_lines(fm, model.fileName(index), width)
        lh = fm.height()
        top = icon_rect.bottom() + 6
        if selected:
            w = max(fm.horizontalAdvance(line) for line in lines) + 10
            pill = QRectF(r.x() + (r.width() - w) / 2, top - 1, w, lh * len(lines) + 2)
            p.setPen(Qt.PenStyle.NoPen)
            p.setBrush(QColor(THEME.accent_pill if focused else THEME.select_inactive))
            p.drawRoundedRect(pill, 5, 5)
        p.setPen(QColor("white") if (selected and focused) else QColor(THEME.text))
        for i, line in enumerate(lines):
            p.drawText(QRect(r.x() + inset, top + i * lh, width, lh), Qt.AlignmentFlag.AlignHCenter | Qt.AlignmentFlag.AlignTop, line)
        p.restore()

    @staticmethod
    def _draw_tags(p: QPainter, tags: list[str], rect: QRect, font: QFont, video: bool) -> None:
        """The file's tags on its tile, bottom left: a dark pill with a coloured dot per tag (up to three,
        overlapping like Finder's) and, when the tile is big enough, the first tag's name and "+N"."""
        f = QFont(font)
        f.setPointSizeF(max(7.0, f.pointSizeF() - 2.5))
        f.setWeight(QFont.Weight.DemiBold)
        fm = QFontMetrics(f)
        h = fm.height() + 4
        d = max(6, h - 8)
        dots = tags[:3]
        step = max(3, int(d * 0.6))
        dots_w = d + (len(dots) - 1) * step
        avail = rect.width() - 8 - (26 if video else 0) - dots_w - 15
        text = tags[0] + (f" +{len(tags) - 1}" if len(tags) > 1 else "")
        label = fm.elidedText(text, Qt.TextElideMode.ElideRight, avail) if rect.width() >= 64 and avail > 24 else ""
        if label == "…":
            label = ""
        w = 6 + dots_w + (5 + fm.horizontalAdvance(label) if label else 0) + 6
        x0, y0 = rect.x() + 4, rect.bottom() - h - 3
        p.save()
        p.setPen(Qt.PenStyle.NoPen)
        p.setBrush(QColor(0, 0, 0, 170))
        p.drawRoundedRect(QRectF(x0, y0, w, h), h / 2, h / 2)
        for i in reversed(range(len(dots))):
            p.setPen(QPen(QColor(0, 0, 0, 170), 1))
            p.setBrush(QColor(tag_color(dots[i])))
            p.drawEllipse(QRectF(x0 + 6 + i * step, y0 + (h - d) / 2, d, d))
        if label:
            p.setFont(f)
            p.setPen(QColor("white"))
            p.drawText(QRectF(x0 + 6 + dots_w + 5, y0, fm.horizontalAdvance(label) + 2, h),
                       Qt.AlignmentFlag.AlignVCenter | Qt.AlignmentFlag.AlignLeft, label)
        p.restore()

    @staticmethod
    def _draw_thumb(p: QPainter, pm: QPixmap, rect: QRect, video: bool) -> QRect:
        size = pm.size().scaled(rect.size() - QSize(6, 6), Qt.AspectRatioMode.KeepAspectRatio)
        target = QRect(rect.x() + (rect.width() - size.width()) // 2, rect.y() + (rect.height() - size.height()) // 2,
                       size.width(), size.height())
        p.setPen(Qt.PenStyle.NoPen)
        p.setBrush(QColor(0, 0, 0, 40))
        p.drawRoundedRect(QRectF(target.adjusted(-1, 0, 1, 2)), 3, 3)
        clip = QPainterPath()
        clip.addRoundedRect(QRectF(target), 2.5, 2.5)
        p.save()
        p.setClipPath(clip)
        p.drawPixmap(target, pm)
        p.restore()
        p.setPen(QPen(QColor(255, 255, 255, 60 if THEME.dark else 200), 1))
        p.setBrush(Qt.BrushStyle.NoBrush)
        p.drawRoundedRect(QRectF(target).adjusted(0.5, 0.5, -0.5, -0.5), 2.5, 2.5)
        if video:
            d = max(14, min(22, target.width() // 4))
            badge = QRectF(target.right() - d - 4, target.bottom() - d - 4, d, d)
            p.setPen(Qt.PenStyle.NoPen)
            p.setBrush(QColor(0, 0, 0, 140))
            p.drawEllipse(badge)
            tri = QPainterPath()
            tri.moveTo(badge.left() + d * 0.38, badge.top() + d * 0.28)
            tri.lineTo(badge.left() + d * 0.74, badge.top() + d * 0.5)
            tri.lineTo(badge.left() + d * 0.38, badge.top() + d * 0.72)
            tri.closeSubpath()
            p.setBrush(QColor("white"))
            p.drawPath(tri)
        return target


class ListDelegate(QStyledItemDelegate):
    def __init__(self, pane: "Pane") -> None:
        super().__init__(pane)
        self.pane = pane

    def paint(self, p: QPainter, option: QStyleOptionViewItem, index: QModelIndex) -> None:
        if self.pane.drop_target and self.pane.model.filePath(index.siblingAtColumn(0)) == self.pane.drop_target:
            p.save()
            p.setPen(Qt.PenStyle.NoPen)
            p.setBrush(QColor(THEME.accent))
            p.drawRect(option.rect)
            p.restore()
            option.palette.setColor(QPalette.ColorRole.Text, QColor("white"))
        tags = []
        if index.column() == 0:
            tags = tag_store().tags(self.pane.model.filePath(index), fresh=False)
        if not tags:
            super().paint(p, option, index)
            return
        self._paint_with_tags(p, option, index, tags)

    def _paint_with_tags(self, p: QPainter, option: QStyleOptionViewItem, index: QModelIndex, tags: list[str]) -> None:
        """The name column with the file's tags as small chips at its right end (as many as fit in half
        the column, then "+N"); the name is elided before them."""
        f = QFont(option.font)
        f.setPointSizeF(max(7.0, f.pointSizeF() - 1.5))
        fm = QFontMetrics(f)
        room = option.rect.width() // 2
        chips: list[tuple[str, int, str | None]] = []
        total = 0
        for i, t in enumerate(tags):
            w = fm.horizontalAdvance(t) + 22
            if total + w > room and chips:
                more = f"+{len(tags) - i}"
                chips.append((more, fm.horizontalAdvance(more) + 12, None))
                total += chips[-1][1] + 4
                break
            chips.append((t, w, t))
            total += w + 4
        full = QStyleOptionViewItem(option)
        self.initStyleOption(full, index)
        full.text = ""
        full.icon = QIcon()
        style = option.widget.style() if option.widget is not None else QApplication.style()
        style.drawControl(QStyle.ControlElement.CE_ItemViewItem, full, p, option.widget)   # the row behind the chips
        name = QStyleOptionViewItem(option)
        name.rect = option.rect.adjusted(0, 0, -(total + 6), 0)
        super().paint(p, name, index)
        selected = bool(option.state & QStyle.StateFlag.State_Selected)
        h = fm.height() + 4
        x = option.rect.right() - total - 2
        y = option.rect.center().y() - h / 2 + 1
        p.save()
        p.setRenderHint(QPainter.RenderHint.Antialiasing)
        p.setFont(f)
        for text, w, tag in chips:
            r = QRectF(x, y, w, h)
            p.setPen(Qt.PenStyle.NoPen)
            p.setBrush(QColor(255, 255, 255, 50) if selected else qc(THEME.select_bg))
            p.drawRoundedRect(r, h / 2, h / 2)
            tx = x + 6
            if tag is not None:
                d = h - 9
                p.setBrush(QColor(tag_color(tag)))
                p.drawEllipse(QRectF(x + 6, y + (h - d) / 2, d, d))
                tx = x + 6 + d + 4
            p.setPen(QColor("white") if selected else QColor(THEME.text))
            p.drawText(QRectF(tx, y, w - (tx - x), h), Qt.AlignmentFlag.AlignVCenter | Qt.AlignmentFlag.AlignLeft, text)
            x += w + 4
        p.restore()


class DropMixin:
    """Accept file drops: onto a folder under the cursor, else into the pane's own folder."""

    pane: "Pane"

    def _target(self, event) -> str:
        idx = self.indexAt(event.position().toPoint())  # type: ignore[attr-defined]
        if idx.isValid() and self.pane.model.isDir(idx):
            path = self.pane.model.filePath(idx.siblingAtColumn(0))
            dragged = {u.toLocalFile() for u in event.mimeData().urls()}
            if path not in dragged:
                return path
        return self.pane.location

    def dragEnterEvent(self, event) -> None:  # noqa: N802
        if event.mimeData().hasUrls() and not self.pane.is_virtual:
            event.setDropAction(Qt.DropAction.CopyAction)
            event.accept()
            self.pane.set_drop_highlight(True)
        else:
            event.ignore()

    def dragMoveEvent(self, event) -> None:  # noqa: N802
        if not event.mimeData().hasUrls() or self.pane.is_virtual:
            event.ignore()
            return
        super().dragMoveEvent(event)  # type: ignore[misc]   # keeps auto-scroll
        target = self._target(event)
        self.pane.set_drop_target(None if target == self.pane.location else target)
        event.setDropAction(Qt.DropAction.CopyAction)
        event.accept()

    def dragLeaveEvent(self, event) -> None:  # noqa: N802
        self.pane.set_drop_target(None)
        self.pane.set_drop_highlight(False)
        event.accept()

    def dropEvent(self, event) -> None:  # noqa: N802
        if self.pane.is_virtual:
            event.ignore()
            return
        target = self._target(event)
        paths = [u.toLocalFile() for u in event.mimeData().urls() if u.isLocalFile()]
        self.pane.set_drop_target(None)
        self.pane.set_drop_highlight(False)
        event.setDropAction(Qt.DropAction.CopyAction)     # never let the source view "remove" anything
        event.accept()
        if paths and not all(os.path.dirname(p) == target for p in paths):
            QTimer.singleShot(0, lambda: self.pane.dropped.emit(paths, target))


class GridView(DropMixin, QListView):
    def __init__(self, pane: "Pane") -> None:
        super().__init__(pane)
        self.pane = pane
        self.setViewMode(QListView.ViewMode.IconMode)
        self.setMovement(QListView.Movement.Static)
        self.setResizeMode(QListView.ResizeMode.Adjust)
        self.setWrapping(True)
        self.setUniformItemSizes(True)
        self.setSpacing(0)
        self.setSelectionMode(QAbstractItemView.SelectionMode.ExtendedSelection)
        self.setSelectionRectVisible(True)
        self.setDragEnabled(True)
        self.setAcceptDrops(True)
        self.viewport().setAcceptDrops(True)
        self.setDragDropMode(QAbstractItemView.DragDropMode.DragDrop)
        self.setDefaultDropAction(Qt.DropAction.CopyAction)
        self.setVerticalScrollMode(QAbstractItemView.ScrollMode.ScrollPerPixel)
        self.setContextMenuPolicy(Qt.ContextMenuPolicy.CustomContextMenu)


class ListView(DropMixin, QTreeView):
    def __init__(self, pane: "Pane") -> None:
        super().__init__(pane)
        self.pane = pane
        self.setRootIsDecorated(False)
        self.setItemsExpandable(False)
        self.setUniformRowHeights(True)
        self.setAlternatingRowColors(True)
        self.setSortingEnabled(False)              # the pane sorts (its header click → Pane._header_sort)
        self.setSelectionMode(QAbstractItemView.SelectionMode.ExtendedSelection)
        self.setDragEnabled(True)
        self.setAcceptDrops(True)
        self.viewport().setAcceptDrops(True)
        self.setDragDropMode(QAbstractItemView.DragDropMode.DragDrop)
        self.setDefaultDropAction(Qt.DropAction.CopyAction)
        self.setIconSize(QSize(18, 18))
        self.setContextMenuPolicy(Qt.ContextMenuPolicy.CustomContextMenu)


# ============================================================================ search & collections


VIDEOS = "safe-finder://videos"                 # the "All Videos" collection
SEARCH = "safe-finder://search/"                # + a number: one search's results (see Pane.searches)
EMPTY = "safe-finder://empty"                   # the "Empty Folders" collection (see empty_roots)
TAG = "safe-finder://tag/"                      # + a tag: every file carrying it (see TagScanner)
_R_PATH, _R_MTIME, _R_SIZE, _R_ISDIR = 258, 259, 260, 261    # roles on a results row (256/257: the sidebar's)
KIND_EXT = {
    "image": IMAGE_EXT, "video": VIDEO_EXT, "raw": RAW_EXT, "pdf": {".pdf"},
    "audio": {".mp3", ".m4a", ".aac", ".wav", ".flac", ".aiff", ".aif", ".ogg", ".opus"},
    "document": {".txt", ".rtf", ".md", ".doc", ".docx", ".pages", ".numbers", ".key", ".xls", ".xlsx",
                 ".ppt", ".pptx", ".csv"},
    "archive": {".zip", ".rar", ".7z", ".tar", ".gz", ".bz2", ".xz", ".dmg", ".iso"},
}
KIND_LABELS = [("", "Any kind"), ("image", "Images"), ("video", "Videos"), ("raw", "RAW photos"), ("pdf", "PDFs"),
               ("audio", "Audio"), ("document", "Documents"), ("archive", "Archives")]
KIND_NAMES = {".mov": "QuickTime movie", ".mp4": "MPEG-4 movie", ".m4v": "MPEG-4 movie", ".avi": "AVI movie",
              ".mkv": "Matroska video", ".webm": "WebM video", ".3gp": "3GPP movie", ".mts": "AVCHD video",
              ".m2ts": "AVCHD video", ".wmv": "Windows Media video", ".jpg": "JPEG image", ".jpeg": "JPEG image",
              ".png": "PNG image", ".heic": "HEIC image", ".heif": "HEIF image", ".gif": "GIF image",
              ".tif": "TIFF image", ".tiff": "TIFF image", ".webp": "WebP image", ".avif": "AVIF image",
              ".bmp": "Bitmap image", ".dng": "DNG raw image", ".cr2": "Canon raw image", ".cr3": "Canon raw image",
              ".nef": "Nikon raw image", ".arw": "Sony raw image", ".raf": "Fujifilm raw image",
              ".orf": "Olympus raw image", ".rw2": "Panasonic raw image", ".pdf": "PDF document",
              ".zip": "ZIP archive", ".mp3": "MP3 audio", ".m4a": "AAC audio", ".wav": "WAV audio"}
_SKIP_TOP = {"Library"}                           # directly under the home folder: caches, Mail, app data…
_SKIP_ANYWHERE = {"node_modules"}
_BUNDLE_EXT = {".app", ".photoslibrary", ".imovielibrary", ".fcpbundle", ".fcpcache", ".tvlibrary",
               ".musiclibrary", ".bundle", ".framework", ".xcarchive", ".playground", ".pkg", ".lrlibrary"}
SORT_KEYS = [("name", "Name"), ("kind", "Kind"), ("modified", "Date Modified"), ("created", "Date Created"),
             ("added", "Date Added"), ("size", "Size")]
DATE_KEYS = {"modified", "created", "added"}
_COLUMN_KEY = {0: "name", 1: "size", 2: "kind", 3: "modified"}      # the list view's columns
_KEY_COLUMN = {v: k for k, v in _COLUMN_KEY.items()}
SIZE_FILTERS = [("", "Any size"), ("empty", "Empty (0 KB)"), ("<1m", "Under 1 MB"), (">=1m", "1 MB or more"),
                (">=10m", "10 MB or more"), (">=100m", "100 MB or more"), (">=1g", "1 GB or more")]
_UNITS = {"b": 1, "k": 1024, "kb": 1024, "m": 1024 ** 2, "mb": 1024 ** 2, "g": 1024 ** 3, "gb": 1024 ** 3,
          "t": 1024 ** 4, "tb": 1024 ** 4}


def parse_size(text: str) -> int | None:
    """"100mb", "1.5 GB", "0", "empty" → bytes; None when it isn't a size."""
    t = text.strip().lower().replace(" ", "")
    if t in ("0", "empty", "zero"):
        return 0
    m = re.fullmatch(r"(\d+(?:\.\d+)?)([kmgt]?b?)", t)
    if not m:
        return None
    return int(float(m.group(1)) * _UNITS.get(m.group(2) or "b", 1))


def size_bounds(spec: str) -> tuple[int | None, int | None] | None:
    """A size spec ("empty", "<1m", ">=10m", ">100mb", "<=2gb") → (min, max) in bytes, inclusive;
    None when it means any size."""
    t = spec.strip().lower().replace(" ", "")
    if not t:
        return None
    if t in ("empty", "0", "zero"):
        return (0, 0)
    m = re.fullmatch(r"(>=|<=|>|<|=)?(.+)", t)
    op, n = (m.group(1) or "="), parse_size(m.group(2)) if m else None
    if n is None:
        return None
    if op == ">":
        return (n + 1, None)
    if op == ">=":
        return (n, None)
    if op == "<":
        return (None, max(n - 1, 0))
    if op == "<=":
        return (None, n)
    return (n, n)


def size_label(bounds: tuple[int | None, int | None] | None) -> str:
    if bounds is None:
        return ""
    lo, hi = bounds
    if lo == 0 and hi == 0:
        return "empty"
    if lo is not None and hi is None:
        return f"{human(lo)} or more"
    if lo is None and hi is not None:
        return f"under {human(hi + 1)}"
    return f"{human(lo or 0)}–{human(hi or 0)}"


def mac_roots() -> list[Path]:
    """What "This Mac" means to a search and to All Videos: the home folder, where files live (the
    system, apps and ~/Library hold nothing you'd move to the SSD). SAFE_FINDER_SEARCH_ROOTS=a:b
    overrides it (tests)."""
    env = os.environ.get("SAFE_FINDER_SEARCH_ROOTS")
    return [Path(p) for p in env.split(":") if p] if env else [Path.home()]


def empty_roots() -> list[Path]:
    """Where the sidebar looks for empty folders: Documents, Pictures, Movies and Downloads — the
    places downloads and exports pile up and leave husks behind. SAFE_FINDER_EMPTY_ROOTS=a:b
    overrides it (tests)."""
    env = os.environ.get("SAFE_FINDER_EMPTY_ROOTS")
    if env:
        return [Path(p) for p in env.split(":") if p]
    home = Path.home()
    return [home / n for n in ("Documents", "Pictures", "Movies", "Downloads") if (home / n).is_dir()]


def kind_name(path: str, is_dir: bool) -> str:
    if is_dir:
        return "Folder"
    ext = os.path.splitext(path)[1].lower()
    return KIND_NAMES.get(ext, f"{ext[1:].upper()} file" if ext else "File")


def natural_key(name: str) -> list:
    """Finder's order: IMG_2 before IMG_10, case ignored."""
    return [int(t) if i % 2 else t.lower() for i, t in enumerate(re.split(r"(\d+)", name))]


_libc = None


def added_time(path: str) -> float | None:
    """When the file arrived in its folder (Finder's "Date Added"), which macOS keeps per file
    (ATTR_CMN_ADDEDTIME); None where it isn't kept — other systems, exFAT drives."""
    global _libc
    if not IS_MAC:
        return None
    try:
        import ctypes
        import ctypes.util
        if _libc is None:
            _libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)

        class AttrList(ctypes.Structure):
            _fields_ = [("bitmapcount", ctypes.c_ushort), ("reserved", ctypes.c_uint16),
                        ("commonattr", ctypes.c_uint32), ("volattr", ctypes.c_uint32), ("dirattr", ctypes.c_uint32),
                        ("fileattr", ctypes.c_uint32), ("forkattr", ctypes.c_uint32)]

        attrs = AttrList(5, 0, 0x10000000, 0, 0, 0, 0)           # ATTR_BIT_MAP_COUNT, ATTR_CMN_ADDEDTIME
        buf = ctypes.create_string_buffer(20)                     # u_int32 length + struct timespec
        if _libc.getattrlist(path.encode("utf-8"), ctypes.byref(attrs), buf, 20, 1) != 0:   # FSOPT_NOFOLLOW
            return None
        length, sec, nsec = struct.unpack("<Iqq", buf.raw)
        return sec + nsec / 1e9 if length >= 20 and sec > 0 else None
    except Exception:  # noqa: BLE001 — any trouble just means "not known"
        return None


def file_times(path: str) -> tuple[float, float]:
    """(created, added): when the file was made, and when it came into this folder. Where a system
    or drive doesn't keep one, the other stands in (then the modification date)."""
    try:
        st = os.stat(path)
    except OSError:
        return (0.0, 0.0)
    created = getattr(st, "st_birthtime", None) or st.st_mtime
    added = added_time(path)
    return (created, added or created)


class Query:
    """What a search looks for: words that must all appear in the name, extensions (".heic",
    "*.mov", "ext:mp4,mov"), a kind ("kind:video", or the Kind menu) and a size ("size:>100mb",
    "size:<1gb", "size:0"). All of it must match."""

    def __init__(self, text: str = "", kind: str = "") -> None:
        self.text = text.strip()
        self.words: list[str] = []
        self.exts: set[str] = set()
        self.size: tuple[int | None, int | None] | None = None   # (min, max) bytes, files only
        self.menu_kind = kind if kind in KIND_EXT else ""      # the Kind menu's choice, as such
        self.kind = self.menu_kind                              # …which "kind:" in the text overrides
        for tok in self.text.split():
            low = tok.lower()
            if low.startswith("kind:"):
                if low[5:] in KIND_EXT:
                    self.kind = low[5:]
            elif low.startswith("size:"):
                self.size = size_bounds(low[5:])
            elif low.startswith("ext:"):
                self.exts |= {"." + e.strip(". ") for e in low[4:].split(",") if e.strip(". ")}
            elif low.startswith("*.") and len(low) > 2:
                self.exts.add(low[1:])
            elif low.startswith(".") and len(low) > 1 and "." not in low[1:]:
                self.exts.add(low)
            else:
                self.words.append(low)

    def empty(self) -> bool:
        return not (self.words or self.exts or self.kind or self.size)

    def wants_folders(self) -> bool:
        """A search by name finds folders too; one by extension, kind or size is about files."""
        return bool(self.words) and not self.exts and not self.kind and not self.size

    def matches_size(self, size: int) -> bool:
        if self.size is None:
            return True
        lo, hi = self.size
        return (lo is None or size >= lo) and (hi is None or size <= hi)

    def matches(self, name: str) -> bool:
        low = name.lower()
        ext = os.path.splitext(low)[1]
        if self.exts and ext not in self.exts:
            return False
        if self.kind and ext not in KIND_EXT[self.kind]:
            return False
        return all(w in low for w in self.words)

    def label(self) -> str:
        bits = [self.text] if self.text else []
        if self.kind and f"kind:{self.kind}" not in self.text.lower():
            bits.append(dict(KIND_LABELS)[self.kind])
        if self.size and "size:" not in self.text.lower():
            bits.append(size_label(self.size))
        return " · ".join(bits)

    def spotlight(self) -> str:
        """The same search as a Spotlight (mdfind) query; what comes back is checked with `matches` too."""
        def quote(s: str) -> str:
            return s.replace("\\", "\\\\").replace('"', '\\"').replace("*", "\\*").replace("?", "\\?")
        parts = [f'kMDItemFSName == "*{quote(w)}*"cd' for w in self.words]
        exts = self.exts & KIND_EXT[self.kind] if (self.exts and self.kind) else self.exts or (KIND_EXT[self.kind] if self.kind else set())
        if exts:
            parts.append("(" + " || ".join(f'kMDItemFSName == "*{e}"c' for e in sorted(exts)) + ")")
        if self.size:
            lo, hi = self.size
            if lo is not None:
                parts.append(f"kMDItemFSSize >= {lo}")
            if hi is not None:
                parts.append(f"kMDItemFSSize <= {hi}")
        return " && ".join(parts) or 'kMDItemFSName == "*"'


class SearchRun:
    """One search as it was run — so back/forward brings up the same one, from the same folder."""

    def __init__(self, query: Query, folder: str, scope: str, roots: list[Path], spotlight: bool, where: str) -> None:
        self.query, self.folder, self.scope, self.roots, self.spotlight, self.where = \
            query, folder, scope, roots, spotlight, where


class _ScanSignals(QObject):
    found = Signal(list)          # a batch of (path, size, mtime, is_dir)
    done = Signal(bool)           # True when it got to the end, False when cancelled


class FileScanner:
    """Finds the files under `roots` that `query` matches, on a background thread, streaming them
    in batches. Walks the folders itself — skipping hidden items, ~/Library (caches, Mail, app
    data), node_modules, app and library bundles (Photos, iMovie, Final Cut…), symlinks and
    anything mounted inside the tree, and a folder it may not read (macOS asks for
    Desktop/Documents/Downloads access the first time) — or, for the whole Mac, asks Spotlight
    (mdfind), which answers at once, and walks only if Spotlight has nothing."""

    def __init__(self, roots: list[Path], query: Query, folders: bool, spotlight: bool = False) -> None:
        self.roots = roots
        self.query = query
        self.folders = folders
        self.spotlight = spotlight
        self.signals = _ScanSignals()
        self._stop = threading.Event()
        self._proc: subprocess.Popen | None = None

    def start(self) -> None:
        threading.Thread(target=self._run, name="file-scan", daemon=True).start()

    def cancel(self) -> None:
        self._stop.set()
        if self._proc is not None:
            try:
                self._proc.terminate()
            except OSError:
                pass

    def _run(self) -> None:
        found = self._spotlight() if self.spotlight else 0
        if not found and not self._stop.is_set():
            self._walk()
        self.signals.done.emit(not self._stop.is_set())

    @staticmethod
    def _skip_dir(name: str, top: bool) -> bool:
        return (top and name in _SKIP_TOP) or name in _SKIP_ANYWHERE \
            or os.path.splitext(name)[1].lower() in _BUNDLE_EXT

    def _walk(self) -> int:
        batch: list[tuple[str, int, float, bool]] = []
        flushed = time.monotonic()
        total = 0
        stack: list[tuple[str, int, bool]] = []            # folder, its volume, is it a root
        for root in self.roots:
            try:
                stack.append((str(root), os.stat(root).st_dev, True))
            except OSError:
                continue
        while stack and not self._stop.is_set():
            folder, dev, top = stack.pop()
            try:
                with os.scandir(folder) as it:
                    entries = list(it)
            except OSError:
                continue
            for e in entries:
                name = e.name
                if name.startswith("."):
                    continue
                try:
                    if e.is_dir(follow_symlinks=False):
                        if self._skip_dir(name, top):
                            continue
                        st = e.stat(follow_symlinks=False)
                        if st.st_dev != dev:                           # another volume mounted here
                            continue
                        if self.folders and self.query.matches(name):
                            batch.append((e.path, 0, st.st_mtime, True))
                        stack.append((e.path, dev, False))
                    elif e.is_file(follow_symlinks=False) and self.query.matches(name):
                        st = e.stat(follow_symlinks=False)
                        if not self.query.matches_size(st.st_size):
                            continue
                        batch.append((e.path, st.st_size, st.st_mtime, False))
                except OSError:
                    continue
            if batch and (len(batch) >= 250 or time.monotonic() - flushed > 0.4):
                total += len(batch)
                self.signals.found.emit(batch)
                batch, flushed = [], time.monotonic()
        if batch and not self._stop.is_set():
            total += len(batch)
            self.signals.found.emit(batch)
        return total

    def _skip_path(self, path: str, root: str) -> bool:
        parts = path[len(root):].strip("/").split("/")
        return any(p.startswith(".") or p in _SKIP_ANYWHERE or os.path.splitext(p)[1].lower() in _BUNDLE_EXT
                   for p in parts) or (parts and parts[0] in _SKIP_TOP)

    def _spotlight(self) -> int:
        exe = os.environ.get("SAFE_FINDER_MDFIND") or shutil.which("mdfind")
        if not exe:
            return 0
        batch: list[tuple[str, int, float, bool]] = []
        flushed = time.monotonic()
        total = 0
        for root in self.roots:
            try:
                self._proc = subprocess.Popen([exe, "-onlyin", str(root), self.query.spotlight()],
                                              stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
            except OSError:
                return total
            assert self._proc.stdout is not None
            for line in self._proc.stdout:
                if self._stop.is_set():
                    break
                path = line.rstrip("\n")
                if not path or self._skip_path(path, str(root)):
                    continue
                name = os.path.basename(path)
                if not self.query.matches(name):
                    continue
                try:
                    st = os.lstat(path)
                except OSError:
                    continue
                if stat.S_ISLNK(st.st_mode):
                    continue
                is_dir = stat.S_ISDIR(st.st_mode)
                if is_dir and not self.folders:
                    continue
                if not is_dir and not self.query.matches_size(st.st_size):
                    continue
                batch.append((path, 0 if is_dir else st.st_size, st.st_mtime, is_dir))
                if len(batch) >= 250 or time.monotonic() - flushed > 0.4:
                    total += len(batch)
                    self.signals.found.emit(batch)
                    batch, flushed = [], time.monotonic()
            self._proc.wait()
            self._proc = None
        if batch and not self._stop.is_set():
            total += len(batch)
            self.signals.found.emit(batch)
        return total


def dir_size(folder: str, stop: threading.Event | None = None) -> int:
    """Bytes of every file under `folder` — dot items skipped, symlinks not followed, nothing on a
    volume mounted inside it. What Finder's "Calculate all sizes" shows, minus the .DS_Store noise."""
    total = 0
    try:
        dev = os.stat(folder).st_dev
    except OSError:
        return 0
    stack = [folder]
    while stack and not (stop is not None and stop.is_set()):
        try:
            with os.scandir(stack.pop()) as it:
                for e in it:
                    if e.name.startswith("."):
                        continue
                    try:
                        if e.is_dir(follow_symlinks=False):
                            if e.stat(follow_symlinks=False).st_dev == dev:
                                stack.append(e.path)
                        elif e.is_file(follow_symlinks=False):
                            total += e.stat(follow_symlinks=False).st_size
                    except OSError:
                        continue
        except OSError:
            continue
    return total


class FolderSizer(QObject):
    """Recursive folder sizes on a background thread, cached for the session. A pane asks for the
    folders it shows (`request`); each size comes back through `ready` and goes into the list's Size
    column, the size sort, the size filter and the status line. The cache is dropped after a
    transfer or a delete (`clear`), since sizes up the tree changed."""

    ready = Signal(str)

    def __init__(self) -> None:
        super().__init__()
        self.sizes: dict[str, int] = {}
        self._queue: list[str] = []
        self._lock = threading.Lock()
        self._wake = threading.Event()
        threading.Thread(target=self._run, name="folder-sizes", daemon=True).start()

    def get(self, path: str) -> int | None:
        return self.sizes.get(path)

    def request(self, paths: list[str]) -> None:
        with self._lock:
            queued = set(self._queue)
            wanted = [p for p in paths if p not in self.sizes and p not in queued]
            self._queue = wanted + self._queue              # what's on screen now goes first
        if wanted:
            self._wake.set()

    def clear(self) -> None:
        with self._lock:
            self.sizes.clear()
            self._queue.clear()

    def _run(self) -> None:
        while True:
            self._wake.wait()
            with self._lock:
                if not self._queue:
                    self._wake.clear()
                    continue
                path = self._queue.pop(0)
            size = dir_size(path)
            self.sizes[path] = size
            self.ready.emit(path)


_SIZER: FolderSizer | None = None


def sizer() -> FolderSizer:
    """The one folder-size worker (made on first use, from the GUI thread)."""
    global _SIZER
    if _SIZER is None:
        _SIZER = FolderSizer()
    return _SIZER


def folder_size(path: str) -> int | None:
    return _SIZER.sizes.get(path) if _SIZER is not None else None


class EmptyFolderScanner:
    """Finds the empty folders under `roots` — every folder whose files add up to 0 bytes (dot items
    ignored), reported at its topmost level: a folder holding only empty folders is listed once, as
    itself. The same signals as FileScanner, so a pane shows the result like a search."""

    def __init__(self, roots: list[Path]) -> None:
        self.roots = roots
        self.signals = _ScanSignals()
        self._stop = threading.Event()

    def start(self) -> None:
        threading.Thread(target=self._run, name="empty-scan", daemon=True).start()

    def cancel(self) -> None:
        self._stop.set()

    def _run(self) -> None:
        batch: list[tuple[str, int, float, bool]] = []
        for root in self.roots:
            try:
                dev = os.stat(root).st_dev
            except OSError:
                continue
            for path, mtime in self._walk(str(root), dev, top=True)[1]:
                batch.append((path, 0, mtime, True))
                if len(batch) >= 100:
                    self.signals.found.emit(batch)
                    batch = []
        if batch and not self._stop.is_set():
            self.signals.found.emit(batch)
        self.signals.done.emit(not self._stop.is_set())

    def _walk(self, folder: str, dev: int, top: bool) -> tuple[int, list[tuple[str, float]]]:
        """(bytes under `folder`, the topmost empty folders under it)."""
        if self._stop.is_set():
            return 1, []
        total = 0
        empties: list[tuple[str, float]] = []
        try:
            with os.scandir(folder) as it:
                entries = list(it)
        except OSError:
            return 1, []                                     # unreadable: not something to call empty
        for e in entries:
            if e.name.startswith("."):
                continue
            try:
                if e.is_dir(follow_symlinks=False):
                    if FileScanner._skip_dir(e.name, top):
                        total += 1                            # a bundle counts as content
                        continue
                    st = e.stat(follow_symlinks=False)
                    if st.st_dev != dev:
                        total += 1
                        continue
                    sub, below = self._walk(e.path, dev, False)
                    total += sub
                    if sub == 0:
                        empties.append((e.path, st.st_mtime))  # this folder, not what's inside it
                    else:
                        empties.extend(below)
                elif e.is_file(follow_symlinks=False):
                    total += e.stat(follow_symlinks=False).st_size
                else:
                    total += 1                                # a symlink or device is content
            except OSError:
                continue
        return total, empties


class TagScanner:
    """The files carrying one tag — on this Mac and the connected drives — each checked to still be
    there (a file moved or deleted outside Safe Finder keeps its entry until it's tagged again). The same
    signals as FileScanner, so a pane shows them like a search."""

    def __init__(self, tag: str) -> None:
        self.tag = tag
        self.signals = _ScanSignals()
        self._stop = threading.Event()

    def start(self) -> None:
        paths = tag_store().files_with(self.tag)            # read here, on the UI thread, with the tables
        threading.Thread(target=self._run, args=(paths,), name="tag-scan", daemon=True).start()

    def cancel(self) -> None:
        self._stop.set()

    def _run(self, paths: list[str]) -> None:
        batch: list[tuple[str, int, float, bool]] = []
        for path in paths:
            if self._stop.is_set():
                break
            try:
                st = os.stat(path)
            except OSError:
                try:                                         # the drive may spell the name decomposed
                    path = unicodedata.normalize("NFD", path)
                    st = os.stat(path)
                except OSError:
                    continue
            is_dir = stat.S_ISDIR(st.st_mode)
            batch.append((path, 0 if is_dir else st.st_size, st.st_mtime, is_dir))
            if len(batch) >= 200:
                self.signals.found.emit(batch)
                batch = []
        if batch and not self._stop.is_set():
            self.signals.found.emit(batch)
        self.signals.done.emit(not self._stop.is_set())


class ResultsModel(QStandardItemModel):
    """A search's results (or All Videos): a row per file the scanner found, in QFileSystemModel's
    four columns (Name, Size, Kind, Date Modified) and answering its `filePath` / `isDir` /
    `fileIcon` / `fileName` / `size` / `lastModified`, so the pane's views, delegates and
    drag-and-drop treat it like any folder listing. Rows drag as file URLs; nothing can be dropped
    on it."""

    def __init__(self, parent: QObject, icons: QFileIconProvider) -> None:
        super().__init__(0, 4, parent)
        self.setHorizontalHeaderLabels(["Name", "Size", "Kind", "Date Modified"])
        self._icons = icons
        self._icon_cache: dict[str, QIcon] = {}
        self._paths: set[str] = set()

    # -- what the pane expects of QFileSystemModel
    def iconProvider(self) -> QFileIconProvider:  # noqa: N802
        return self._icons

    def filePath(self, index: QModelIndex) -> str:  # noqa: N802
        return (self.data(index.siblingAtColumn(0), _R_PATH) or "") if index.isValid() else ""

    def isDir(self, index: QModelIndex) -> bool:  # noqa: N802
        return bool(self.data(index.siblingAtColumn(0), _R_ISDIR)) if index.isValid() else False

    def fileName(self, index: QModelIndex) -> str:  # noqa: N802
        return os.path.basename(self.filePath(index))

    def fileIcon(self, index: QModelIndex) -> QIcon:  # noqa: N802
        return self._icon_for(self.filePath(index), self.isDir(index))

    def size(self, index: QModelIndex) -> int:
        return int(self.data(index.siblingAtColumn(0), _R_SIZE) or 0) if index.isValid() else 0

    def lastModified(self, index: QModelIndex) -> QDateTime:  # noqa: N802
        mtime = self.data(index.siblingAtColumn(0), _R_MTIME) if index.isValid() else None
        return QDateTime.fromSecsSinceEpoch(int(mtime or 0))

    def index_for(self, path: str) -> QModelIndex:
        for r in range(self.rowCount()):
            if self.item(r).data(_R_PATH) == path:
                return self.index(r, 0)
        return QModelIndex()

    def _icon_for(self, path: str, is_dir: bool) -> QIcon:
        ext = "/" if is_dir else os.path.splitext(path)[1].lower()   # one native icon per kind — per file is slow
        icon = self._icon_cache.get(ext)
        if icon is None:
            icon = self._icon_cache[ext] = self._icons.icon(QFileInfo(path))
        return icon

    def data(self, index: QModelIndex, role: int = Qt.ItemDataRole.DisplayRole):
        if role == Qt.ItemDataRole.DecorationRole and index.column() == 0:
            return self._icon_for(self.filePath(index), self.isDir(index))
        return super().data(index, role)

    def flags(self, index: QModelIndex) -> Qt.ItemFlag:
        f = super().flags(index) & ~Qt.ItemFlag.ItemIsEditable & ~Qt.ItemFlag.ItemIsDropEnabled
        return (f | Qt.ItemFlag.ItemIsDragEnabled) if index.isValid() else f

    def supportedDragActions(self) -> Qt.DropAction:  # noqa: N802
        return Qt.DropAction.CopyAction

    def supportedDropActions(self) -> Qt.DropAction:  # noqa: N802
        return Qt.DropAction.IgnoreAction

    def mimeTypes(self) -> list[str]:  # noqa: N802
        return ["text/uri-list"]

    def mimeData(self, indexes) -> QMimeData:  # noqa: N802
        md = QMimeData()
        seen: set[str] = set()
        urls = []
        for idx in indexes:
            path = self.filePath(idx)
            if path and path not in seen:
                seen.add(path)
                urls.append(QUrl.fromLocalFile(path))
        md.setUrls(urls)
        return md

    # -- filling
    def clear_all(self) -> None:
        self.removeRows(0, self.rowCount())
        self._paths.clear()

    def add(self, found: list[tuple[str, int, float, bool]]) -> None:
        right = Qt.AlignmentFlag.AlignRight | Qt.AlignmentFlag.AlignVCenter
        for path, size, mtime, is_dir in found:
            if path in self._paths:
                continue
            self._paths.add(path)
            name = os.path.basename(path)
            n = QStandardItem(name)
            n.setData(path, _R_PATH)
            n.setData(float(mtime), _R_MTIME)
            n.setData(int(size), _R_SIZE)
            n.setData(bool(is_dir), _R_ISDIR)
            n.setToolTip(path)
            s = QStandardItem("--" if is_dir else human(size))
            s.setTextAlignment(right)
            k = QStandardItem(kind_name(path, is_dir))
            when = QDateTime.fromSecsSinceEpoch(int(mtime))
            d = QStandardItem(QLocale.system().toString(when, QLocale.FormatType.ShortFormat))
            self.appendRow([n, s, k, d])

    def remove_missing(self) -> int:
        """Drop the rows whose file is gone (moved to the SSD, deleted); how many."""
        return self.remove_where(lambda path: not os.path.lexists(path))

    def remove_where(self, gone_if) -> int:
        """Drop the rows whose path `gone_if` says no longer belong; how many."""
        gone = [r for r in range(self.rowCount()) if gone_if(self.item(r).data(_R_PATH))]
        for r in reversed(gone):
            self._paths.discard(self.item(r).data(_R_PATH))
            self.removeRow(r)
        return len(gone)


class PaneModel(QSortFilterProxyModel):
    """What a pane's views show: the folder listing (QFileSystemModel) or a results list, sorted the
    way the Sort menu says — by the dates QFileSystemModel has no column for too (created, added)
    — with folders first and names in natural order (IMG_2 before IMG_10). Passes through the
    file-model calls the delegates and drag-and-drop make (`filePath`, `isDir`, …)."""

    def __init__(self, parent: QObject) -> None:
        super().__init__(parent)
        self.key = "name"
        self._is_fs = True
        self._keys: dict[int, tuple] = {}            # node (fs) or row (results) → sort key, for `key`
        self.show_sizes = True                       # folder sizes in the Size column (and the size sort)
        self.size_filter: tuple[int | None, int | None] | None = None
        self.root_path = ""                          # the folder listed — only its own rows are filtered
        self.setDynamicSortFilter(True)
        # Sizes come in one folder at a time: the order (by size) and the size filter catch up a few
        # times a second, not once per folder — a full re-sort per folder was quadratic in a big listing.
        self._resort = QTimer(self)
        self._resort.setSingleShot(True)
        self._resort.setInterval(200)
        self._resort.timeout.connect(self.invalidate)

    def set_size_filter(self, bounds: tuple[int | None, int | None] | None) -> None:
        self.size_filter = bounds
        self.invalidateFilter()

    def filterAcceptsRow(self, row: int, parent: QModelIndex) -> bool:  # noqa: N802
        if self.size_filter is None:
            return True
        src = self.sourceModel()
        if self._is_fs and (not parent.isValid() or src.filePath(parent) != self.root_path):
            return True                              # never the listed folder's own ancestors
        idx = src.index(row, 0, parent)
        lo, hi = self.size_filter
        if src.isDir(idx):
            size = folder_size(src.filePath(idx))
            if size is None:                         # not calculated yet: shown, except by "Empty" until known
                return not (lo == 0 and hi == 0)
        else:
            size = src.size(idx)
        return (lo is None or size >= lo) and (hi is None or size <= hi)

    def data(self, index: QModelIndex, role: int = Qt.ItemDataRole.DisplayRole):
        if self._is_fs and self.show_sizes and index.isValid() and self.isDir(index):
            if index.column() == 1:
                if role == Qt.ItemDataRole.DisplayRole:
                    size = folder_size(self.filePath(index))
                    return "—" if size is None else human(size)
                if role == Qt.ItemDataRole.TextAlignmentRole:
                    return Qt.AlignmentFlag.AlignRight | Qt.AlignmentFlag.AlignVCenter
            elif index.column() == 0 and role == Qt.ItemDataRole.ToolTipRole:
                size = folder_size(self.filePath(index))
                return self.filePath(index) + ("" if size is None else f"\n{human(size)}")
        return super().data(index, role)

    def size_known(self, path: str) -> None:
        """A folder's size came in: its row shows it; the order and the filter follow when they
        depend on sizes."""
        if not self._is_fs:
            return
        src_idx = self.sourceModel().index(path)
        if not src_idx.isValid():
            return
        self._keys.pop(src_idx.internalId(), None)
        if (self.key == "size" or self.size_filter is not None) and not self._resort.isActive():
            self._resort.start()
        idx = self.mapFromSource(src_idx)
        if idx.isValid():
            cell = idx.siblingAtColumn(1)
            self.dataChanged.emit(cell, cell, [Qt.ItemDataRole.DisplayRole])

    def set_source(self, model: "QFileSystemModel | ResultsModel") -> None:
        self._is_fs = isinstance(model, QFileSystemModel)
        self._keys.clear()
        self.setSourceModel(model)

    def set_sort(self, key: str, order: Qt.SortOrder) -> None:
        self.key = key
        self._keys.clear()
        self.sort(-1)                                  # a new key with the same column is still a new order
        self.sort(_KEY_COLUMN.get(key, 0), order)

    def forget_keys(self) -> None:
        self._keys.clear()

    # -- QFileSystemModel's face
    def filePath(self, index: QModelIndex) -> str:  # noqa: N802
        return self.sourceModel().filePath(self.mapToSource(index)) if index.isValid() else ""

    def isDir(self, index: QModelIndex) -> bool:  # noqa: N802
        return self.sourceModel().isDir(self.mapToSource(index)) if index.isValid() else False

    def fileIcon(self, index: QModelIndex) -> QIcon:  # noqa: N802
        return self.sourceModel().fileIcon(self.mapToSource(index))

    def fileName(self, index: QModelIndex) -> str:  # noqa: N802
        return self.sourceModel().fileName(self.mapToSource(index))

    def lastModified(self, index: QModelIndex) -> QDateTime:  # noqa: N802
        return self.sourceModel().lastModified(self.mapToSource(index))

    def iconProvider(self) -> QFileIconProvider:  # noqa: N802
        return self.sourceModel().iconProvider()

    def index_for(self, path: str) -> QModelIndex:
        src = self.sourceModel()
        return self.mapFromSource(src.index(path) if self._is_fs else src.index_for(path))

    # -- order
    def lessThan(self, left: QModelIndex, right: QModelIndex) -> bool:  # noqa: N802
        kl, kr = self._sort_key(left), self._sort_key(right)
        if kl[0] != kr[0]:                             # folders stay first whichever way the order runs
            less = kl[0] < kr[0]
            return less if self.sortOrder() == Qt.SortOrder.AscendingOrder else not less
        return kl[1:] < kr[1:]

    def _sort_key(self, idx: QModelIndex) -> tuple:
        cid = idx.internalId() if self._is_fs else idx.row()
        k = self._keys.get(cid)
        if k is None:
            k = self._keys[cid] = self._make_key(idx)
        return k

    def _make_key(self, idx: QModelIndex) -> tuple:
        src = self.sourceModel()
        is_dir = src.isDir(idx)
        name = src.fileName(idx)
        group, nat = (0 if is_dir else 1), natural_key(name)
        key = self.key
        if key == "kind":
            return (group, "" if is_dir else os.path.splitext(name)[1].lower(), nat)
        if key == "size":
            return (group, (folder_size(src.filePath(idx)) or 0) if is_dir else src.size(idx), nat)
        if key == "modified":
            return (group, src.lastModified(idx).toMSecsSinceEpoch(), nat)
        if key in ("created", "added"):
            created, added = file_times(src.filePath(idx))
            return (group, added if key == "added" else created, nat)
        return (group, nat)


# ============================================================================ pane


class Selection(NamedTuple):
    """What's selected in a pane, read from the listing in one pass (no disk access)."""
    paths: list[str]
    files: int
    file_bytes: int                  # the files' sizes, as the listing has them
    folders: list[str]


class FolderViews:
    """How each place was last shown — as icons or as a list, and sorted how — so Back, Forward or
    opening it again (after a relaunch too) shows it that way again, as Finder does: a folder of folders
    left as a list by name is still a list by name after a look inside one of them as icons. A place
    never shown before takes the view on screen. Shared by both panes; the most recent LIMIT places are
    kept in the settings (a search's results only for the session)."""

    LIMIT = 1000

    def __init__(self, settings: QSettings) -> None:
        self.settings = settings
        self.views: OrderedDict[str, tuple[str, str, str]] = OrderedDict()
        try:
            raw = json.loads(str(settings.value("views", "") or "{}"))
        except ValueError:
            raw = {}
        for loc, v in (raw.items() if isinstance(raw, dict) else ()):
            if isinstance(v, list) and len(v) == 3 and v[0] in ("grid", "list") and v[1] in dict(SORT_KEYS) \
                    and v[2] in ("asc", "desc"):
                self.views[loc] = (v[0], v[1], v[2])

    def get(self, loc: str) -> tuple[str, str, Qt.SortOrder] | None:
        v = self.views.get(loc)
        if v is None:
            return None
        return v[0], v[1], Qt.SortOrder.DescendingOrder if v[2] == "desc" else Qt.SortOrder.AscendingOrder

    def put(self, loc: str, mode: str, key: str, order: Qt.SortOrder) -> None:
        v = (mode, key, "desc" if order == Qt.SortOrder.DescendingOrder else "asc")
        if self.views.get(loc) == v and next(reversed(self.views)) == loc:
            return
        self.views.pop(loc, None)
        self.views[loc] = v
        while len(self.views) > self.LIMIT:
            self.views.popitem(last=False)
        self.settings.setValue("views", json.dumps({k: list(x) for k, x in self.views.items()
                                                    if not k.startswith(SEARCH)}))


class Pane(QWidget):
    """One Finder window's worth: header (back/forward, title, sort, search, view toggle), the
    views, path bar and status bar. Besides folders it shows two kinds of collection in the same
    views: All Videos, and a search's results (`searches` remembers each run so back/forward can
    bring it up again)."""

    dropped = Signal(list, str)          # paths, target folder
    activated = Signal(object)           # this pane got focus/clicked
    location_changed = Signal(str)
    selection_changed = Signal()
    airdrop_note = Signal(str)           # lines from the AirDrop thread → the status line

    def __init__(self, role: str, settings: QSettings, views: FolderViews | None = None) -> None:
        super().__init__()
        self.role = role                 # "From" | "To"
        self.settings = settings
        self.views = views or FolderViews(settings)     # each place's own list/icons and sort
        self._volume = ""                # the location's volume (a folder's)
        self._free = ("", 0.0, 0)        # (volume, when, bytes): its free space, read now and then
        self.location = ""
        self.folder = ""                 # the last real folder: where a search starts, and returns to
        self.history: list[str] = []
        self.future: list[str] = []
        self.drop_target: str | None = None
        self.icon_px = int(settings.value(f"{role}/icon", 84))
        self.gap = int(settings.value(f"{role}/gap", 34))      # room around each tile; 2 packs them edge to edge
        self.active = False
        self.searches: dict[str, SearchRun] = {}               # location → what was searched, and where
        self._search_n = 0
        self._pending_reveal: str | None = None
        self._note_at = 0.0              # when a transient note (AirDrop, Trash) took the status line
        self.folder_sort = (str(settings.value(f"{role}/sort", "name")), self._order(settings.value(f"{role}/order", "asc")))
        if self.folder_sort[0] not in dict(SORT_KEYS):
            self.folder_sort = ("name", Qt.SortOrder.AscendingOrder)
        self.results_sort = ("modified", Qt.SortOrder.DescendingOrder)   # newest first, like All Videos

        self.fs = QFileSystemModel(self)
        self._icons = QFileIconProvider()          # native Finder icons on macOS; kept alive with the pane
        self.fs.setIconProvider(self._icons)
        self.fs.setReadOnly(True)
        self.fs.setFilter(QDir.Filter.AllDirs | QDir.Filter.Files | QDir.Filter.NoDotAndDotDot)
        # The status line is refreshed a moment after rows come or go, never from inside the model's
        # own signal: asking the model for anything mid-insertion, with the sorting proxy still
        # catching up, is a crash.
        self._status_soon = QTimer(self)
        self._status_soon.setSingleShot(True)
        self._status_soon.setInterval(80)
        self._status_soon.timeout.connect(self.update_status)
        self.fs.directoryLoaded.connect(lambda _p: (self._status_soon.start(), self._try_reveal()))
        self.fs.rowsInserted.connect(lambda *_: self._status_soon.start())
        self.fs.rowsRemoved.connect(lambda *_: self._status_soon.start())
        # Results (searches, All Videos): the same views over a model the scanner fills in batches.
        self.results = ResultsModel(self, self._icons)
        self.results.rowsInserted.connect(lambda *_: self._status_soon.start())
        self.results.rowsRemoved.connect(lambda *_: self._status_soon.start())
        self.model = PaneModel(self)               # what the views show: fs or results, in the chosen order
        self.model.set_source(self.fs)
        self.model.show_sizes = settings.value(f"{role}/sizes", "true") == "true"
        self.size_filter_key = ""
        self.scanner: FileScanner | EmptyFolderScanner | TagScanner | None = None
        # Folder sizes arrive from the worker thread; the listing asks for its folders' as it loads.
        sizer().ready.connect(self._size_ready, Qt.ConnectionType.QueuedConnection)
        # A folder files are pouring into is re-listed (directoryLoaded) many times a second: its sizes and
        # thumbnails are asked for at most a few times a second — once a second while a transfer runs —
        # not on every one.
        self._listing_soon = QTimer(self)
        self._listing_soon.setSingleShot(True)
        self._listing_soon.timeout.connect(lambda: (self._request_sizes(), self._prefetch_thumbs()))
        self.fs.directoryLoaded.connect(lambda _p: None if self._listing_soon.isActive()
                                        else self._listing_soon.start(1000 if TRANSFERRING else 150))
        self.fs.directoryLoaded.connect(lambda p: check_carried(p) if p == self.location else None)

        root = QVBoxLayout(self)
        root.setContentsMargins(0, 0, 0, 0)
        root.setSpacing(0)

        # header
        header = QWidget(objectName="PaneHeader")
        h = QHBoxLayout(header)
        h.setContentsMargins(10, 8, 10, 8)
        h.setSpacing(4)
        self.back_btn = self._tool("back", "Back (⌘[)", self.go_back, "Nav")
        self.fwd_btn = self._tool("forward", "Forward (⌘])", self.go_forward, "Nav")
        h.addWidget(self.back_btn)
        h.addWidget(self.fwd_btn)
        h.addSpacing(6)
        self.chip = QLabel(role.upper(), objectName="RoleChip")
        h.addWidget(self.chip)
        h.addSpacing(4)
        self.title = QLabel(objectName="PaneTitle")
        self.title.setSizePolicy(QSizePolicy.Policy.Ignored, QSizePolicy.Policy.Preferred)
        h.addWidget(self.title, 1)
        self.search = QLineEdit(objectName="Search")
        self.search.setPlaceholderText("Search")
        self.search.setToolTip("Words in the name, an extension (.heic, *.mov) or a kind (kind:video) — "
                               "press Return. ⌘F from anywhere.")
        self.search.setClearButtonEnabled(True)
        self.search.setFixedWidth(150)
        self.search.returnPressed.connect(self.run_search)
        self.search.textChanged.connect(self._search_text_changed)
        self.search.installEventFilter(self)
        h.addWidget(self.search)
        h.addSpacing(2)
        self.filter_btn = self._tool("funnel", "Filter by size", None, "Nav")
        self.filter_btn.setMenu(self._size_menu())
        self.filter_btn.setPopupMode(QToolButton.ToolButtonPopupMode.InstantPopup)
        h.addWidget(self.filter_btn)
        self.sort_btn = self._tool("sort", "Sort by", None, "Nav")
        self.sort_btn.setMenu(self._sort_menu())
        self.sort_btn.setPopupMode(QToolButton.ToolButtonPopupMode.InstantPopup)
        h.addWidget(self.sort_btn)
        self.new_folder_btn = self._tool("plus", "New Folder (⇧⌘N)", self.new_folder, "Nav")
        h.addWidget(self.new_folder_btn)
        self.tags_btn = self._tool("tag", "Tags (⌘T) — for the selected files, or everything inside the selected "
                                   "folders. They show up in Photo Browser on the iPhone.", self.edit_tags, "Nav")
        h.addWidget(self.tags_btn)
        h.addSpacing(6)
        self.grid_btn = self._tool("grid", "as Icons (⌘1)", lambda: self.set_mode("grid"), "Seg")
        self.list_btn = self._tool("list", "as List (⌘2)", lambda: self.set_mode("list"), "Seg")
        for b in (self.grid_btn, self.list_btn):
            b.setCheckable(True)
        group = QButtonGroup(self)
        group.setExclusive(True)
        group.addButton(self.grid_btn)
        group.addButton(self.list_btn)
        h.addWidget(self.grid_btn)
        h.addWidget(self.list_btn)
        root.addWidget(header)

        # scope bar — Finder's "Search: This Mac | “Downloads”", shown while a search is up
        self.scopebar = QWidget(objectName="ScopeBar")
        sb = QHBoxLayout(self.scopebar)
        sb.setContentsMargins(10, 4, 10, 4)
        sb.setSpacing(6)
        sb.addWidget(QLabel("Search:"))
        self.scope_volume = QToolButton(objectName="Scope")
        self.scope_folder = QToolButton(objectName="Scope")
        for b in (self.scope_volume, self.scope_folder):
            b.setCheckable(True)
            b.setAutoRaise(True)
            b.clicked.connect(self._scope_clicked)
            sb.addWidget(b)
        scopes = QButtonGroup(self)
        scopes.setExclusive(True)
        scopes.addButton(self.scope_volume)
        scopes.addButton(self.scope_folder)
        (self.scope_volume if settings.value(f"{role}/scope", "folder") == "volume" else self.scope_folder).setChecked(True)
        sb.addStretch(1)
        sb.addWidget(QLabel("Kind:"))
        self.kind_box = QComboBox()
        for key, label in KIND_LABELS:
            self.kind_box.addItem(label, key)
        self.kind_box.currentIndexChanged.connect(lambda _i: self.run_search(if_active=True))
        sb.addWidget(self.kind_box)
        self.scopebar.hide()
        root.addWidget(self.scopebar)

        # views
        self.grid = GridView(self)
        self.grid.setItemDelegate(GridDelegate(self))
        self.list = ListView(self)
        self.list.setItemDelegate(ListDelegate(self))
        self.grid.setModel(self.model)
        self.list.setModel(self.model)
        self.list.setSelectionModel(self.grid.selectionModel())
        # Told once per burst, not per change: when a move takes selected originals away one by one,
        # each removal changes the selection, and re-reading a selection of thousands that often froze
        # the window.
        self._sel_soon = QTimer(self)
        self._sel_soon.setSingleShot(True)
        self._sel_soon.setInterval(60)
        self._sel_soon.timeout.connect(self.selection_changed.emit)
        self.grid.selectionModel().selectionChanged.connect(
            lambda *_: None if self._sel_soon.isActive() else self._sel_soon.start())
        hdr = self.list.header()
        hdr.setSectionsClickable(True)
        hdr.setSortIndicatorShown(True)
        hdr.sortIndicatorChanged.connect(self._header_sort)
        self._layout_header()
        self.stack = QStackedWidget()
        self.stack.addWidget(self.grid)
        self.stack.addWidget(self.list)
        root.addWidget(self.stack, 1)
        for v in (self.grid, self.list):
            v.doubleClicked.connect(self.open_index)
            v.customContextMenuRequested.connect(lambda pos, v=v: self.context_menu(v, pos))
            v.installEventFilter(self)
            v.viewport().installEventFilter(self)

        # path bar
        self.pathbar = QWidget(objectName="PathBar")
        self.path_layout = QHBoxLayout(self.pathbar)
        self.path_layout.setContentsMargins(8, 3, 8, 3)
        self.path_layout.setSpacing(1)
        root.addWidget(self.pathbar)

        # status bar
        status = QWidget(objectName="StatusBar")
        sl = QHBoxLayout(status)
        sl.setContentsMargins(10, 3, 10, 3)
        sl.setSpacing(8)
        self.status = QLabel()
        self.airdrop_note.connect(self._airdrop_noted)
        self.fs_chip = QLabel(objectName="FsChip")
        # Finder's View Options, inline: how big the tiles are, and how much room is around them.
        self.gap_icon = QLabel()
        self.gap_slider = QSlider(Qt.Orientation.Horizontal)
        self.gap_slider.setRange(2, 48)
        self.gap_slider.setValue(self.gap)
        self.gap_slider.setFixedWidth(64)
        self.gap_slider.setToolTip("Space between thumbnails")
        self.gap_slider.valueChanged.connect(self.set_gap)
        self.size_icon = QLabel()
        self.slider = QSlider(Qt.Orientation.Horizontal)
        self.slider.setRange(48, 320)
        self.slider.setValue(self.icon_px)
        self.slider.setFixedWidth(90)
        self.slider.setToolTip("Thumbnail size")
        self.slider.valueChanged.connect(self.set_icon_size)
        self.view_controls = [self.gap_icon, self.gap_slider, self.size_icon, self.slider]
        sl.addStretch(1)
        sl.addWidget(self.status)
        sl.addWidget(self.fs_chip)
        sl.addStretch(1)
        sl.addWidget(self.gap_icon)
        sl.addWidget(self.gap_slider)
        sl.addSpacing(6)
        sl.addWidget(self.size_icon)
        sl.addWidget(self.slider)
        self._slider_icons()
        root.addWidget(status)

        self._shortcuts()
        self.set_icon_size(self.icon_px)
        self.set_mode(settings.value(f"{role}/mode", "grid"))
        self._apply_sort(*self.folder_sort)

    # -- building blocks
    @staticmethod
    def _order(value) -> Qt.SortOrder:
        return Qt.SortOrder.DescendingOrder if str(value) == "desc" else Qt.SortOrder.AscendingOrder

    def _layout_header(self) -> None:
        hdr = self.list.header()
        if hdr.visualIndex(3) != 1:
            hdr.moveSection(hdr.visualIndex(3), 1)          # Name, Date Modified, Size, Kind — Finder's order
        hdr.setSectionResizeMode(0, QHeaderView.ResizeMode.Stretch)
        hdr.setStretchLastSection(False)
        hdr.resizeSection(1, 90)
        hdr.resizeSection(2, 120)
        hdr.resizeSection(3, 150)

    def _tool(self, icon: str, tip: str, slot, name: str) -> QToolButton:
        b = QToolButton(objectName=name)
        b.setIcon(glyph(icon, THEME.secondary if name == "Nav" else THEME.text, 16))
        b.setIconSize(QSize(16, 16))
        b.setToolTip(tip)
        b.setAutoRaise(True)
        if slot is not None:
            b.clicked.connect(slot)
        b.setProperty("glyph", icon)
        return b

    def _sort_menu(self) -> QMenu:
        menu = QMenu(self)
        keys = QActionGroup(menu)
        keys.setExclusive(True)
        self.sort_actions: dict[str, QAction] = {}
        for key, label in SORT_KEYS:
            a = menu.addAction(label)
            a.setCheckable(True)
            keys.addAction(a)
            a.triggered.connect(lambda _=False, k=key: self.choose_sort(k))
            self.sort_actions[key] = a
        menu.addSeparator()
        orders = QActionGroup(menu)
        orders.setExclusive(True)
        self.asc_action = menu.addAction("Ascending")
        self.desc_action = menu.addAction("Descending")
        for a, order in ((self.asc_action, Qt.SortOrder.AscendingOrder), (self.desc_action, Qt.SortOrder.DescendingOrder)):
            a.setCheckable(True)
            orders.addAction(a)
            a.triggered.connect(lambda _=False, o=order: self.set_sort(self.current_sort()[0], o))
        menu.addSeparator()
        self.sizes_action = menu.addAction("Calculate Folder Sizes")
        self.sizes_action.setCheckable(True)
        self.sizes_action.setChecked(self.model.show_sizes)
        self.sizes_action.setToolTip("Add up what each folder holds (in the background) — shown in the Size column, "
                                     "used by the size sort and the size filter")
        self.sizes_action.toggled.connect(self.set_show_sizes)
        return menu

    def _size_menu(self) -> QMenu:
        """The size filter: what the listing (or the results) shows, by size. Folders count by what
        they hold, once calculated."""
        menu = QMenu(self)
        group = QActionGroup(menu)
        group.setExclusive(True)
        self.size_actions: dict[str, QAction] = {}
        for key, label in SIZE_FILTERS:
            a = menu.addAction(label)
            a.setCheckable(True)
            a.setChecked(key == "")
            group.addAction(a)
            a.triggered.connect(lambda _=False, k=key: self.set_size_filter(k))
            self.size_actions[key] = a
            if key == "":
                menu.addSeparator()
        return menu

    def set_size_filter(self, key: str) -> None:
        self.size_filter_key = key if key in dict(SIZE_FILTERS) else ""
        self.model.set_size_filter(size_bounds(self.size_filter_key))
        self.size_actions[self.size_filter_key].setChecked(True)
        label = dict(SIZE_FILTERS)[self.size_filter_key]
        self.filter_btn.setToolTip("Filter by size" if not self.size_filter_key else f"Showing: {label} — click to change")
        self.filter_btn.setIcon(glyph("funnel", THEME.accent if self.size_filter_key else THEME.secondary, 16))
        if self.size_filter_key:
            self._request_sizes()
        self._status_soon.start()

    def set_show_sizes(self, on: bool) -> None:
        self.model.show_sizes = on
        self.settings.setValue(f"{self.role}/sizes", "true" if on else "false")
        self.model.forget_keys()
        self.model.invalidate()
        if on:
            self._request_sizes()
        self._status_soon.start()

    def _request_sizes(self) -> None:
        """Ask for the sizes of the folders in this listing (what's on screen is queued first)."""
        if self.is_virtual or not self.location or not (self.model.show_sizes or self.size_filter_key):
            return
        root = self.fs.index(self.location)
        paths = []
        for r in range(self.fs.rowCount(root)):
            idx = self.fs.index(r, 0, root)
            if self.fs.isDir(idx):
                paths.append(self.fs.filePath(idx))
        if paths:
            sizer().request(paths)

    def _prefetch_thumbs(self) -> None:
        """Queue the listing's photo and video thumbnails behind the visible ones, so scrolling finds
        them ready (the first 2000; a bigger folder renders the rest as it scrolls)."""
        if THUMBS is None or self.is_virtual or not self.location:
            return
        root = self.fs.index(self.location)
        items: list[tuple[str, float]] = []
        for r in range(min(self.fs.rowCount(root), 2000)):
            idx = self.fs.index(r, 0, root)
            if not self.fs.isDir(idx):
                path = self.fs.filePath(idx)
                if kind_of(path) != "other":
                    items.append((path, self.fs.lastModified(idx).toSecsSinceEpoch()))
        THUMBS.prefetch(items)

    def _size_ready(self, path: str) -> None:
        if not self.is_virtual and os.path.dirname(path.rstrip(os.sep)) == self.location:
            self.model.size_known(path)
            self._status_soon.start()

    def restyle(self) -> None:
        for b in (self.back_btn, self.fwd_btn, self.sort_btn, self.new_folder_btn, self.tags_btn, self.grid_btn,
                  self.list_btn):
            b.setIcon(glyph(b.property("glyph"), THEME.secondary if b.objectName() == "Nav" else THEME.text, 16))
        self.filter_btn.setIcon(glyph("funnel", THEME.accent if self.size_filter_key else THEME.secondary, 16))
        self._slider_icons()
        self.update_pathbar()
        self.grid.viewport().update()

    def _slider_icons(self) -> None:
        dpr = self.devicePixelRatioF() or 1.0
        for label, name in ((self.gap_icon, "spacing"), (self.size_icon, "size")):
            label.setPixmap(glyph(name, THEME.tertiary, 14).pixmap(QSize(14, 14), dpr))
            label.setToolTip("Space between thumbnails" if name == "spacing" else "Thumbnail size")

    def _shortcuts(self) -> None:
        ctx = Qt.ShortcutContext.WidgetWithChildrenShortcut
        for keys, slot in (("Ctrl+[", self.go_back), ("Ctrl+]", self.go_forward), ("Ctrl+Up", self.go_up),
                           ("Ctrl+Down", self.open_selected), ("Return", self.open_selected),
                           ("Space", self.quick_look), ("Ctrl+1", lambda: self.set_mode("grid")),
                           ("Ctrl+2", lambda: self.set_mode("list")), ("Ctrl+Shift+N", self.new_folder),
                           ("Ctrl+Backspace", self.delete_selection), ("Ctrl+T", self.edit_tags)):
            sc = QShortcut(QKeySequence(keys), self)
            sc.setContext(ctx)
            sc.activated.connect(slot)

    def eventFilter(self, obj, event) -> bool:  # noqa: N802
        if obj is self.search:
            if event.type() == event.Type.ShortcutOverride and event.key() in (Qt.Key.Key_Return, Qt.Key.Key_Enter):
                event.accept()                       # Return is the field's (run the search), not the pane's Open shortcut
                return True
            if event.type() == event.Type.KeyPress and event.key() == Qt.Key.Key_Escape:
                self.search.clear()                  # and, if a search is up, back to the folder
                self.view().setFocus()
                return True
        if event.type() in (event.Type.FocusIn, event.Type.MouseButtonPress):
            self.activated.emit(self)
        return False

    def view(self) -> QAbstractItemView:
        return self.grid if self.stack.currentIndex() == 0 else self.list

    def view_has_focus(self) -> bool:
        return self.active

    def set_active(self, active: bool) -> None:
        self.active = active
        self.chip.setProperty("active", "true" if active else "false")
        self.chip.style().unpolish(self.chip)
        self.chip.style().polish(self.chip)
        self.grid.viewport().update()

    @property
    def is_virtual(self) -> bool:
        """A collection (All Videos, search results, a tag's files) rather than a folder."""
        return self.location.startswith("safe-finder://")

    @property
    def is_search(self) -> bool:
        return self.location.startswith(SEARCH)

    def index_for(self, path: str) -> QModelIndex:
        return self.model.index_for(path)

    # Tile geometry, all from `gap`: the room around a tile. At the default (34) it's Finder's icon
    # view; at 2 the thumbnails sit edge to edge, Photos-style, and a row holds as many as fit.
    def tile_pad(self) -> int:
        """Above the thumbnail and below the name."""
        return max(2, self.gap // 4)

    def tile_inset(self) -> int:
        """How far the selection backdrop reaches past the thumbnail, and the name's side margin."""
        return max(1, min(5, self.gap // 4))

    def cell_size(self) -> QSize:
        lh = QFontMetrics(self.grid.font()).height()
        return QSize(max(self.icon_px + self.gap, 56), self.tile_pad() * 2 + self.icon_px + 6 + lh * 2)

    def _relayout(self) -> None:
        self.grid.setGridSize(self.cell_size())
        self.grid.setIconSize(QSize(self.icon_px, self.icon_px))
        self.grid.doItemsLayout()

    def set_icon_size(self, px: int) -> None:
        self.icon_px = px
        self.settings.setValue(f"{self.role}/icon", px)
        self._relayout()

    def set_gap(self, px: int) -> None:
        self.gap = px
        self.settings.setValue(f"{self.role}/gap", px)
        self._relayout()

    def mode(self) -> str:
        return "grid" if self.stack.currentIndex() == 0 else "list"

    def set_mode(self, mode: str) -> None:
        self.stack.setCurrentIndex(0 if mode == "grid" else 1)
        self.grid_btn.setChecked(mode == "grid")
        self.list_btn.setChecked(mode != "grid")
        for w in self.view_controls:
            w.setVisible(mode == "grid")
        self.settings.setValue(f"{self.role}/mode", mode)
        self._remember_view()

    def _remember_view(self) -> None:
        """This place is shown this way: keep it for when it's shown again (FolderViews)."""
        if self.location:
            self.views.put(self.location, self.mode(), *self.current_sort())

    def _restore_view(self) -> None:
        """Arrived somewhere shown before: back to the way it was shown then."""
        saved = self.views.get(self.location)
        if saved is None:
            return
        mode, key, order = saved
        if mode != self.mode():
            self.set_mode(mode)
        if (key, order) != self.current_sort():
            self.set_sort(key, order)

    # -- sorting
    def current_sort(self) -> tuple[str, Qt.SortOrder]:
        return self.results_sort if self.is_virtual else self.folder_sort

    def choose_sort(self, key: str) -> None:
        """From the menu: a date reads newest first, everything else A to Z / smallest first."""
        self.set_sort(key, Qt.SortOrder.DescendingOrder if key in DATE_KEYS else Qt.SortOrder.AscendingOrder)

    def set_sort(self, key: str, order: Qt.SortOrder) -> None:
        if self.is_virtual:
            self.results_sort = (key, order)
        else:
            self.folder_sort = (key, order)
            self.settings.setValue(f"{self.role}/sort", key)
            self.settings.setValue(f"{self.role}/order", "desc" if order == Qt.SortOrder.DescendingOrder else "asc")
        self._apply_sort(key, order)
        self._remember_view()

    def _apply_sort(self, key: str, order: Qt.SortOrder) -> None:
        self.model.set_sort(key, order)
        self.sort_actions[key].setChecked(True)
        (self.desc_action if order == Qt.SortOrder.DescendingOrder else self.asc_action).setChecked(True)
        hdr = self.list.header()
        hdr.blockSignals(True)
        if key in _KEY_COLUMN:
            hdr.setSortIndicator(_KEY_COLUMN[key], order)
            hdr.setSortIndicatorShown(True)
        else:
            hdr.setSortIndicatorShown(False)             # no column for created / added
        hdr.blockSignals(False)
        self.sort_btn.setToolTip(f"Sort by {dict(SORT_KEYS)[key]} — click to change")

    def _header_sort(self, column: int, order: Qt.SortOrder) -> None:
        if column in _COLUMN_KEY:
            self.set_sort(_COLUMN_KEY[column], order)

    # -- navigation
    def go(self, path: str, record: bool = True) -> None:
        if path in (VIDEOS, EMPTY) or path.startswith(TAG):
            self._show_results(path, record)
            return
        if path.startswith(SEARCH):
            if path in self.searches:
                self._show_results(path, record)
            return
        path = os.path.abspath(path)
        if not os.path.isdir(path):
            return
        if self.location and self.location != path:
            self._remember_view()
        if record and self.location and self.location != path:
            self.history.append(self.location)
            self.future.clear()
        if self.is_virtual:                                # back from a collection
            self._stop_scan()
            self.model.set_source(self.fs)
            self._layout_header()
            self._apply_sort(*self.folder_sort)
            self.new_folder_btn.setEnabled(True)
            self.scopebar.hide()
            self.search.blockSignals(True)
            self.search.clear()
            self.search.blockSignals(False)
        self.location = self.folder = path
        self.model.root_path = path
        self._restore_view()
        if THUMBS is not None:
            THUMBS.new_listing()
        idx = self.model.mapFromSource(self.fs.setRootPath(path))
        self.grid.setRootIndex(idx)
        self.list.setRootIndex(idx)
        self.grid.clearSelection()
        self.grid.scrollToTop()
        self.list.scrollToTop()
        name = os.path.basename(path.rstrip(os.sep))
        self._volume = str(engine.volume_root(Path(path)))
        if self._volume == path:
            name = volume_name(Path(path))
        self.title.setText(name or path)
        self.title.setToolTip(path)
        self.back_btn.setEnabled(bool(self.history))
        self.fwd_btn.setEnabled(bool(self.future))
        self.update_pathbar()
        self.update_status()
        self._update_scopes()
        self.settings.setValue(f"{self.role}/location", path)
        self.location_changed.emit(path)
        self._try_reveal()

    def go_back(self) -> None:
        if self.history:
            self.future.append(self.location)
            self.go(self.history.pop(), record=False)

    def go_forward(self) -> None:
        if self.future:
            self.history.append(self.location)
            self.go(self.future.pop(), record=False)

    def go_up(self) -> None:
        if self.is_virtual:
            return
        parent = os.path.dirname(self.location.rstrip(os.sep))
        if parent and parent != self.location:
            self.go(parent)

    def reveal(self, path: str) -> None:
        """Show `path` in its folder, selected — "Show in Safe Finder" from a search or All Videos."""
        self._pending_reveal = path
        self.go(os.path.dirname(path.rstrip(os.sep)) or "/")

    def _try_reveal(self) -> None:
        path = self._pending_reveal
        if not path or self.is_virtual or os.path.dirname(path.rstrip(os.sep)) != self.location:
            return
        idx = self.index_for(path)
        if not idx.isValid():
            return
        self._pending_reveal = None
        sel = self.grid.selectionModel()
        sel.setCurrentIndex(idx, sel.SelectionFlag.ClearAndSelect | sel.SelectionFlag.Rows)
        self.view().scrollTo(idx)

    # -- collections: All Videos, search results
    def _show_results(self, loc: str, record: bool) -> None:
        if self.location == loc:
            self._rescan()                                   # opening it again looks afresh
            return
        if self.location:
            self._remember_view()
        if record and self.location:
            self.history.append(self.location)
            self.future.clear()
        self.location = loc
        self._stop_scan()
        self.results.clear_all()
        if self.model.sourceModel() is not self.results:
            self.model.set_source(self.results)
            self._layout_header()
        self.grid.setRootIndex(QModelIndex())
        self.list.setRootIndex(QModelIndex())
        self._apply_sort(*self.results_sort)
        self._restore_view()
        self.grid.clearSelection()
        self.grid.scrollToTop()
        self.list.scrollToTop()
        self.new_folder_btn.setEnabled(False)
        if loc in (VIDEOS, EMPTY):
            self.title.setText("All Videos" if loc == VIDEOS else "Empty Folders")
            self.title.setToolTip("Every video in your home folder" if loc == VIDEOS else
                                  "Folders in Documents, Pictures, Movies and Downloads with nothing in them (0 KB) — "
                                  "select some and press ⌘⌫ to move them to the Trash")
            self.scopebar.hide()
        elif loc.startswith(TAG):
            tag = loc[len(TAG):]
            self.title.setText(f"#{tag}")
            self.title.setToolTip(f"Every file tagged “{tag}” on this Mac and the connected drives — ⌘T changes "
                                  "the selected files' tags")
            self.scopebar.hide()
        else:
            run = self.searches[loc]
            self.folder = run.folder                           # where it was started — and returns to
            self.title.setText(f"“{run.query.label()}” — {run.where}")
            self.title.setToolTip(f"Searching for {run.query.label()} in {run.where}")
            self.search.blockSignals(True)
            self.search.setText(run.query.text)
            self.search.blockSignals(False)
            self.kind_box.blockSignals(True)
            self.kind_box.setCurrentIndex(max(0, self.kind_box.findData(run.query.menu_kind)))
            self.kind_box.blockSignals(False)
            (self.scope_volume if run.scope == "volume" else self.scope_folder).setChecked(True)
            self._update_scopes()
            self.scopebar.show()
        self.back_btn.setEnabled(bool(self.history))
        self.fwd_btn.setEnabled(bool(self.future))
        self.update_pathbar()
        self.location_changed.emit(loc)
        self._rescan()

    def _rescan(self) -> None:
        self._stop_scan()
        self.results.clear_all()
        self.model.forget_keys()
        if self.location == VIDEOS:
            scanner = FileScanner(mac_roots(), Query(kind="video"), folders=False)
        elif self.location == EMPTY:
            scanner = EmptyFolderScanner(empty_roots())
        elif self.location.startswith(TAG):
            scanner = TagScanner(self.location[len(TAG):])
        else:
            run = self.searches[self.location]
            scanner = FileScanner(run.roots, run.query, folders=run.query.wants_folders(), spotlight=run.spotlight)
        self.scanner = scanner
        queued = Qt.ConnectionType.QueuedConnection
        scanner.signals.found.connect(lambda batch, s=scanner: self._found(s, batch), queued)
        scanner.signals.done.connect(lambda _ok, s=scanner: self._scan_done(s), queued)
        scanner.start()
        self.update_status()

    def _stop_scan(self) -> None:
        if self.scanner is not None:
            self.scanner.cancel()
            self.scanner = None

    def _found(self, scanner: FileScanner, batch: list) -> None:
        if scanner is self.scanner:                          # not a batch from a scan that was cancelled
            self.results.add(batch)

    def _scan_done(self, scanner: FileScanner) -> None:
        if scanner is self.scanner:
            self.scanner = None
            self.update_status()

    def refresh_results(self) -> None:
        """After a transfer: drop the results that are no longer there."""
        if self.is_virtual and self.results.remove_missing():
            self.model.forget_keys()
            self.update_status()

    # -- search
    def _scope_roots(self) -> tuple[list[Path], bool]:
        """Where the chosen scope looks, and whether Spotlight can answer for it (the whole Mac)."""
        base = Path(self.folder or Path.home())
        vol = engine.volume_root(base)
        if self.scope_volume.isChecked():
            if str(vol) == "/":
                return mac_roots(), "SAFE_FINDER_SEARCH_ROOTS" not in os.environ
            return [vol], False
        return [base], False

    def _scope_names(self) -> tuple[str, str]:
        base = Path(self.folder or Path.home())
        vol = engine.volume_root(base)
        volume = "This Mac" if str(vol) == "/" else volume_name(base)
        folder = base.name or volume_name(base)
        return volume, folder

    def _update_scopes(self) -> None:
        volume, folder = self._scope_names()
        self.scope_volume.setText(volume)
        self.scope_volume.setToolTip("Your home folder — everything that is yours" if volume == "This Mac"
                                     else f"The whole of “{volume}”")
        self.scope_folder.setText(f"“{folder}”")
        self.scope_folder.setToolTip("This folder and everything inside it")
        base = Path(self.folder or Path.home())
        same = str(engine.volume_root(base)) != "/" and engine.volume_root(base) == base   # at a drive's top: one scope
        self.scope_folder.setVisible(not same)
        if same:
            self.scope_volume.setChecked(True)

    def _scope_clicked(self) -> None:
        self.settings.setValue(f"{self.role}/scope", "volume" if self.scope_volume.isChecked() else "folder")
        self.run_search(if_active=True)

    def run_search(self, if_active: bool = False) -> None:
        """Search for what the field says, in the chosen scope, and show the results here. "tag:beach" (or
        "#beach") opens the files tagged beach instead."""
        text = self.search.text().strip()
        m = re.match(r"^(?:tag:\s*|#)(.+)$", text, re.IGNORECASE)
        if m and not if_active and shared_tags.normalized(m.group(1)):
            self.go(TAG + shared_tags.normalized(m.group(1)))
            return
        query = Query(self.search.text(), self.kind_box.currentData() or "")
        if query.empty():
            if self.is_search:
                self.go(self.folder)
            return
        if if_active and not self.is_search and not self.search.text().strip():
            return
        volume, folder = self._scope_names()
        scope = "volume" if self.scope_volume.isChecked() else "folder"
        roots, spotlight = self._scope_roots()
        self._search_n += 1
        loc = f"{SEARCH}{self._search_n}"
        self.searches[loc] = SearchRun(query, self.folder, scope, roots, spotlight,
                                       volume if scope == "volume" else f"“{folder}”")
        self._show_results(loc, record=True)

    def _search_text_changed(self, text: str) -> None:
        if not text.strip() and self.is_search:
            self.go(self.folder)

    # -- bars
    def update_pathbar(self) -> None:
        while self.path_layout.count():
            item = self.path_layout.takeAt(0)
            if item.widget():
                item.widget().hide()                        # gone now, not when the event loop gets to it
                item.widget().deleteLater()
        if not self.location:
            return
        if self.is_virtual:
            b = QToolButton(objectName="Crumb")
            text, icon = {VIDEOS: ("All Videos", "film"), EMPTY: ("Empty Folders", "trash")}.get(
                self.location, ("Search results", "search"))
            if self.location.startswith(TAG):
                text, icon = f"Tag “{self.location[len(TAG):]}”", "tag"
            b.setText(text)
            b.setToolButtonStyle(Qt.ToolButtonStyle.ToolButtonTextBesideIcon)
            b.setIcon(glyph(icon, THEME.accent, 14))
            b.setIconSize(QSize(14, 14))
            b.setToolTip("Click to look again")
            b.clicked.connect(lambda _=False, loc=self.location: self.go(loc))
            self.path_layout.addWidget(b)
            self.path_layout.addStretch(1)
            return
        p = Path(self.location)
        root = engine.volume_root(p)
        parts: list[tuple[str, Path]] = [(volume_name(p), root)]
        for comp in p.relative_to(root).parts:
            parts.append((comp, parts[-1][1] / comp))
        if len(parts) > 6:
            parts = parts[:1] + [("…", parts[-5][1])] + parts[-4:]
        provider = self.model.iconProvider()
        for i, (label, target) in enumerate(parts):
            if i:
                sep = QLabel("›")
                self.path_layout.addWidget(sep)
            b = QToolButton(objectName="Crumb")
            b.setText(label)
            b.setToolButtonStyle(Qt.ToolButtonStyle.ToolButtonTextBesideIcon)
            if provider is not None and label != "…":
                b.setIcon(provider.icon(QFileInfo(str(target))))
                b.setIconSize(QSize(14, 14))
            b.clicked.connect(lambda _=False, t=str(target): self.go(t))
            self.path_layout.addWidget(b)
        self.path_layout.addStretch(1)

    def update_status(self) -> None:
        if not self.location or time.monotonic() - self._note_at < 1.5:
            return
        picked = self.selection()
        selected = picked.paths
        sel = len(selected)
        chosen = picked.file_bytes + sum(folder_size(p) or 0 for p in picked.folders)
        size_note = f" · {human(chosen)}" if chosen else ""
        tag_note = ""
        if sel == 1:
            tags = tag_store().tags(selected[0], fresh=False)
            if tags:
                tag_note = "  ·  " + ", ".join(f"#{t}" for t in tags[:4]) + (f" +{len(tags) - 4}" if len(tags) > 4 else "")
        if self.is_virtual:
            n = self.results.rowCount()
            shown = self.model.rowCount()
            what = {VIDEOS: "video", EMPTY: "empty folder"}.get(self.location, "result")
            text = f"{sel} of {n} selected{size_note}" if sel else f"{n} {what}{'s' if n != 1 else ''}"
            if self.location.startswith(TAG) and not sel:
                text = f"{n} item{'s' if n != 1 else ''} tagged “{self.location[len(TAG):]}”"
            if shown != n:
                text += f" ({shown} shown)"
            if self.scanner is not None:
                text += " so far — still looking…"
            self.status.setText(text + tag_note)
            self.fs_chip.setVisible(False)
            return
        root = self.fs.index(self.location)
        n = self.fs.rowCount(root)
        shown = self.model.rowCount(self.model.mapFromSource(root))
        free = self._free_space()
        text = f"{sel} of {n} selected{size_note}" if sel else f"{n} item{'s' if n != 1 else ''}"
        if self.size_filter_key and shown != n:
            text += f" ({shown} shown — {dict(SIZE_FILTERS)[self.size_filter_key].lower()})"
        self.status.setText(f"{text}, {human(free)} available{tag_note}")
        fs = MOUNTS.get(self._volume, "")
        self.fs_chip.setText(FS_NAMES.get(fs, fs))
        self.fs_chip.setVisible(bool(fs))

    def _free_space(self) -> int:
        """The volume's free space, read again every few seconds at most: while files pour in, the status
        line is redrawn many times a second, and a busy drive needn't be asked each time."""
        now = time.monotonic()
        vol, when, free = self._free
        if vol != self._volume or now - when > 3:
            free = engine.free_space(Path(self._volume or self.location))
            self._free = (self._volume, now, free)
        return free

    # -- selection / actions
    @staticmethod
    def _selection_bytes(paths: list[str]) -> int:
        """Files by their size, folders by their calculated size where it's known."""
        total = 0
        for p in paths:
            if os.path.isdir(p):
                total += folder_size(p) or 0
            else:
                try:
                    total += os.path.getsize(p)
                except OSError:
                    pass
        return total

    def selected_paths(self) -> list[str]:
        return self.selection().paths

    def selection(self) -> Selection:
        """The selected items in one pass over the selection's row ranges, kinds and sizes from the
        listing itself — a selection of thousands is read in milliseconds, without touching the disk."""
        src = self.model.sourceModel()
        seen: set[str] = set()
        paths: list[str] = []
        folders: list[str] = []
        files = nbytes = 0
        for rng in self.grid.selectionModel().selection():
            parent = rng.parent()
            for row in range(rng.top(), rng.bottom() + 1):
                idx = self.model.mapToSource(self.model.index(row, 0, parent))
                path = src.filePath(idx)
                if not path or path in seen:
                    continue
                seen.add(path)
                paths.append(path)
                if src.isDir(idx):
                    folders.append(path)
                else:
                    files += 1
                    nbytes += src.size(idx)
        return Selection(paths, files, nbytes, folders)

    def open_index(self, idx: QModelIndex) -> None:
        path = self.model.filePath(idx.siblingAtColumn(0))
        if self.model.isDir(idx):
            self.go(path)
        else:
            QDesktopServices.openUrl(QUrl.fromLocalFile(path))

    def open_selected(self) -> None:
        paths = self.selected_paths()
        if len(paths) == 1 and os.path.isdir(paths[0]):
            self.go(paths[0])
        else:
            for p in paths:
                QDesktopServices.openUrl(QUrl.fromLocalFile(p))

    def quick_look(self) -> None:
        paths = self.selected_paths()
        if paths and IS_MAC:
            subprocess.Popen(["qlmanage", "-p", *paths], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def airdrop(self, paths: list[str]) -> None:
        """Pack the selection into .pbgallery archives (one per folder; loose files together) and open
        the Mac's AirDrop window — the Photo Browser app on the iPhone unpacks them into a drive folder
        of your choosing (see airdrop_to_iphone.py). Packing and the send run on a thread; progress and
        the outcome show on the status line."""
        if not paths:
            return
        self._airdrop_noted(f"Packing {len(paths)} item{'s' if len(paths) != 1 else ''} for AirDrop…")

        def work() -> None:
            try:
                archives = airdrop.archive_items([Path(p) for p in paths], airdrop.default_out_dir())
            except (OSError, ValueError) as e:
                self.airdrop_note.emit(f"AirDrop: {e}")
                return
            airdrop.send(archives, log=self.airdrop_note.emit)

        threading.Thread(target=work, daemon=True).start()

    def _airdrop_noted(self, line: str) -> None:
        """A transient note on the status line (an AirDrop step, a Trash result): it holds against
        the automatic refreshes for a moment, then the status comes back on its own."""
        self.status.setText(line)
        self._note_at = time.monotonic()
        QTimer.singleShot(15000, self.update_status)

    def _confirm(self, title: str, text: str, detail: str) -> bool:
        box = QMessageBox(self.window())
        box.setIcon(QMessageBox.Icon.Warning)
        box.setWindowTitle(title)
        box.setText(text)
        box.setInformativeText(detail)
        go = box.addButton("Move to Trash", QMessageBox.ButtonRole.DestructiveRole)
        box.addButton(QMessageBox.StandardButton.Cancel)
        box.setDefaultButton(go)
        box.exec()
        return box.clickedButton() is go

    def delete_selection(self) -> None:
        """Move the selected files and folders to the Trash (recoverable), after a confirmation —
        in a folder listing, search results, All Videos or Empty Folders alike."""
        paths = self.selected_paths()
        if not paths:
            return
        names = [os.path.basename(p.rstrip(os.sep)) for p in paths]
        detail = "\n".join("• " + n for n in names[:8]) + (f"\n… and {len(names) - 8} more" if len(names) > 8 else "")
        total = self._selection_bytes(paths)
        what = f"“{names[0]}”" if len(paths) == 1 else f"these {len(paths)} items"
        size = f" ({human(total)})" if total else ""
        if not self._confirm("Move to Trash", f"Move {what} to the Trash?{size}",
                             detail + "\n\nThey can be put back from the Trash."):
            return
        failed = [p for p in paths if not MainWindow.trash_item(Path(p))]
        moved = len(paths) - len(failed)
        try:
            if tag_store().forget([p for p in paths if p not in failed]):
                tags_changed()
        except OSError:
            pass                                          # the tags of a trashed file are only orphaned
        sizer().clear()                                   # sizes up the tree changed
        self.view().clearSelection()
        self.refresh_results()
        win = self.window()
        if isinstance(win, MainWindow):
            win.update_actions()
            win.sidebar.refresh_empty()
        if failed:
            QMessageBox.warning(self.window(), "Move to Trash",
                                f"{len(failed)} of {len(paths)} couldn't be moved to the Trash:\n"
                                + "\n".join("• " + os.path.basename(f) for f in failed[:8]))
        self._airdrop_noted(f"Moved {moved} item{'s' if moved != 1 else ''} to the Trash.")

    def new_folder(self) -> None:
        if not self.location or self.is_virtual:
            return
        name, ok = QInputDialog.getText(self, "New Folder", "Name of the new folder:", text="untitled folder")
        if not ok or not name.strip():
            return
        target = Path(self.location) / safe_name(name.strip())
        if target.exists():
            QMessageBox.information(self, "New Folder", f"“{target.name}” already exists here.")
            return
        try:
            # From a spare folder when the drive has one, so it opens on the iPhone (see spare_folders.py).
            from_spare = spare_folders.make_dir(str(target))
        except OSError as e:
            QMessageBox.warning(self, "New Folder", f"Couldn't create the folder: {e}")
            return
        if not from_spare and spare_folders.on_exfat(str(target)):
            QMessageBox.information(
                self, "New Folder",
                spare_folders.miss_message(spare_folders.last_miss, f"“{target.name}” was")
                + ", so it may not open on the iPhone. In Terminal:\n\n"
                + engine.spares_command(engine.volume_root(target)))

    def set_drop_target(self, path: str | None) -> None:
        if path != self.drop_target:
            self.drop_target = path
            self.view().viewport().update()

    def set_drop_highlight(self, on: bool) -> None:
        v = self.view()
        v.setProperty("dropActive", "true" if on else "false")
        v.style().unpolish(v)
        v.style().polish(v)

    def context_menu(self, view: QAbstractItemView, pos) -> None:
        idx = view.indexAt(pos)
        if idx.isValid() and not view.selectionModel().isSelected(idx):
            view.selectionModel().select(idx, view.selectionModel().SelectionFlag.ClearAndSelect
                                         | view.selectionModel().SelectionFlag.Rows)
        paths = self.selected_paths() if idx.isValid() else []
        menu = QMenu(self)
        if paths:
            menu.addAction("Open", self.open_selected)
            if IS_MAC:
                menu.addAction("Quick Look", self.quick_look)
                menu.addAction("Show in Finder", lambda: subprocess.Popen(["open", "-R", paths[0]]))
            menu.addAction("Show in Safe Finder", lambda: self.reveal(paths[0]))
            if IS_MAC:
                menu.addAction("AirDrop to iPhone…", lambda: self.airdrop(paths))
            if len(paths) == 1 and os.path.isdir(paths[0]):
                menu.addAction("Download from SimpCity…", lambda: open_simpcity(paths[0], self.window()))
            menu.addSeparator()
            win = self.window()
            if isinstance(win, MainWindow) and self is win.src:
                menu.addAction(win.copy_btn.text(), lambda: win.transfer_selection(False))
                menu.addAction(win.move_btn.text(), lambda: win.transfer_selection(True))
            self._tags_menu(menu, paths)
            photos = [p for p in paths if os.path.splitext(p)[1].lower() in batch_crop.CROPPABLE]
            if photos:
                menu.addAction("Crop…" if len(photos) == 1 else f"Crop {len(photos)} Photos…",
                               lambda: self.crop_photos(photos))
                menu.addAction("AI Upscale 2×…" if len(photos) == 1 else f"AI Upscale {len(photos)} Photos 2×…",
                               lambda: self.ai_upscale(photos))
            menu.addAction("Move to Trash", self.delete_selection).setShortcut(QKeySequence("Ctrl+Backspace"))
            menu.addSeparator()
        if self.location == VIDEOS:
            menu.addAction("Look for Videos Again", lambda: self.go(VIDEOS))
        elif self.location == EMPTY:
            menu.addAction("Look for Empty Folders Again", lambda: self.go(EMPTY))
        elif self.is_search:
            menu.addAction("Search Again", lambda: self.go(self.location))
        elif self.location.startswith(TAG):
            menu.addAction("Look Again", lambda: self.go(self.location))
        else:
            menu.addAction("New Folder", self.new_folder)
            if not paths and os.path.isdir(self.location):
                menu.addAction("Download from SimpCity…", lambda: open_simpcity(self.location, self.window()))
        menu.exec(view.viewport().mapToGlobal(pos))

    # -- crop (crop_window.py / batch_crop.py — the iPhone app's Crop screen, on the Mac)
    def crop_photos(self, paths: list[str]) -> None:
        """Right-click ▸ Crop…: one crop, drawn on the first photo, put on all of them in place; each
        cropped photo gets the "cropped" tag."""
        photos = [p for p in paths if batch_crop.can_crop(p)]
        if not photos:
            QMessageBox.information(self.window(), "Crop", "None of these can be cropped here — JPEG, HEIC, PNG, "
                                    "WebP, TIFF and BMP photos can (HEIC needs pillow-heif; run mac/run.sh once).")
            return
        import crop_window

        def done(cropped: list[str], trimmed: bool, failed: int) -> None:
            if cropped and trimmed:
                try:
                    tag_store().add(cropped, [batch_crop.CROPPED_TAG])
                except OSError as e:
                    QMessageBox.warning(self.window(), "Crop", f"Couldn't save the “cropped” tag: {e}")
                tags_changed()
            if THUMBS is not None:
                THUMBS.forget(cropped)
            self.grid.viewport().update()
            self.list.viewport().update()
            n = len(cropped)
            note = f"{'Cropped' if trimmed else 'Turned'} {n:,} photo{'s' if n != 1 else ''}"
            self._airdrop_noted(note + (f"; {failed:,} couldn't be." if failed else "."))

        dlg = crop_window.CropDialog(self.window(), photos, self.settings, done)
        dlg.setAttribute(Qt.WidgetAttribute.WA_DeleteOnClose)
        dlg.open()

    # -- AI upscale (ai_upscale.py / upscale_window.py — Real-ESRGAN on this Mac)
    def ai_upscale(self, paths: list[str]) -> None:
        """Right-click ▸ AI Upscale 2×: each photo upscaled 2× by Real-ESRGAN, in place, tagged "upscaled".
        Without an engine on this Mac yet, says how to get one (or lets one be picked)."""
        import ai_upscale
        import upscale_window
        photos = [p for p in paths if ai_upscale.can_upscale(p)]
        if not photos:
            QMessageBox.information(self.window(), "AI Upscale", "None of these can be upscaled here — JPEG, HEIC, "
                                    "PNG, WebP, TIFF and BMP photos can (HEIC needs pillow-heif; run mac/run.sh once).")
            return
        engine = ai_upscale.find_engine(self.settings.value("upscale/engine") or None)
        if engine is None:
            picked = upscale_window.ask_for_engine(self.window())
            if picked is None:
                return
            engine, chosen = picked
            self.settings.setValue("upscale/engine", chosen)
        n = len(photos)
        what = f"“{os.path.basename(photos[0])}”" if n == 1 else f"these {n:,} photos"
        if QMessageBox.question(
                self.window(), "AI Upscale",
                f"Upscale {what} 2× with AI?\n\n{'It is' if n == 1 else 'They are'} replaced in place — format, "
                f"capture date, location, tags and dates kept — and tagged “{ai_upscale.UPSCALED_TAG}”. Uses "
                f"{engine.describe()} on this Mac; nothing is uploaded. Photos over 12 MP are left as they are.") \
                != QMessageBox.StandardButton.Yes:
            return

        def done(upscaled: list[str], skipped: list[tuple[str, str]], failed: list[tuple[str, str]]) -> None:
            if upscaled:
                try:
                    tag_store().add(upscaled, [ai_upscale.UPSCALED_TAG])
                except OSError as e:
                    QMessageBox.warning(self.window(), "AI Upscale", f"Couldn't save the “upscaled” tag: {e}")
                tags_changed()
            if THUMBS is not None:
                THUMBS.forget(upscaled)
            self.grid.viewport().update()
            self.list.viewport().update()
            note = f"Upscaled {len(upscaled):,} photo{'s' if len(upscaled) != 1 else ''} 2×"
            if skipped:
                note += f"; {len(skipped):,} already large"
            if failed:
                note += f"; {len(failed):,} couldn't be"
            self._airdrop_noted(note + ".")

        run = upscale_window.UpscaleRun(self.window(), photos, engine, done)
        run.setAttribute(Qt.WidgetAttribute.WA_DeleteOnClose)
        run.open()

    # -- tags (shared with the Photo Browser app — see shared_tags.py)
    def _tags_menu(self, menu: QMenu, paths: list[str]) -> None:
        """Right-click ▸ Tags: "Add Tags…", then every tag — ticked when every selected item has it; choosing
        one puts it on all of them, or takes it off when they all have it. A folder gets the tag itself,
        and is asked whether the files inside go too."""
        sub = menu.addMenu(glyph("tag", THEME.secondary, 16), "Tags")
        sub.addAction("Add Tags…", self.edit_tags).setShortcut(QKeySequence("Ctrl+T"))
        items = [p for p in paths if shared_tags.taggable(p)]
        have = tag_counts(items)
        names = tag_store().names()
        if names:
            sub.addSeparator()
            for name in names[:80]:
                n = have.get(shared_tags.fold(name), (name, 0))[1]
                label = name + (f"  ({n} of {len(items)})" if 0 < n < len(items) else "")
                act = sub.addAction(tag_dot(name), label)
                act.setCheckable(True)
                act.setChecked(bool(items) and n == len(items))
                act.triggered.connect(lambda _=False, name=name: self.tag_items(paths, name))
            if len(names) > 80:
                sub.addAction(f"… {len(names) - 80} more — Add Tags…", self.edit_tags)
        if have or any(os.path.isdir(p) for p in items):
            sub.addSeparator()
            sub.addAction("Remove All Tags…", lambda: self.clear_tags(paths))

    def _with_inside(self, paths: list[str], then, ask) -> None:
        """Folders among `paths`: find the files inside them (on a thread), let `ask(folders, inside)` put
        the question — it returns the files that go too, or None to cancel — then `then(items, inside)`.
        No folders: straight to `then(items, [])`."""
        items = [p for p in paths if shared_tags.taggable(p)]
        folders = [p for p in items if os.path.isdir(p)]
        if not folders:
            then(items, [])
            return
        self._airdrop_noted(f"Finding the files in {describe_items(folders)}…")

        def found(inside: list[str], _n: int) -> None:
            self.update_status()
            chosen = ask(folders, inside)
            if chosen is not None:
                then(items, chosen)
        expand_files(folders, found)

    def edit_tags(self) -> None:
        """⌘T: the Tags window for the selection. Folders get tags themselves — and, if wanted, so do the
        files inside them (asked first)."""
        paths = self.selected_paths()
        if not paths:
            self._airdrop_noted("Select files or folders to tag, then press ⌘T.")
            return

        def ask(folders: list[str], inside: list[str]) -> list[str] | None:
            if not inside:
                return []
            what = describe_items(folders)
            yes = ask_inside(self.window(), folders, len(inside),
                             f"Tag {what} only, or {'it' if len(folders) == 1 else 'them'} and the files inside?",
                             "Tags")
            return None if yes is None else inside if yes else []
        self._with_inside(paths, self._open_tags, ask)

    def _open_tags(self, items: list[str], inside: list[str]) -> None:
        if not items:
            QMessageBox.information(self.window(), "Tags", "There's nothing to tag in what's selected.")
            return
        TagDialog(self.window(), items + inside, describe_items(items, len(inside))).open()
        self.update_status()

    def tag_items(self, paths: list[str], name: str, remove: bool | None = None) -> None:
        """Puts `name` on every selected item — folders themselves included — or takes it off when they all
        have it (`remove` None), or as told. For folders, asks whether the files inside go too."""
        items = [p for p in paths if shared_tags.taggable(p)]
        if remove is None:
            remove = bool(items) and all(has_tag(p, name) for p in items)

        def ask(folders: list[str], inside: list[str]) -> list[str] | None:
            inside = [f for f in inside if has_tag(f, name) == remove]      # the ones it would change
            if not inside:
                return []
            what = describe_items(folders)
            q = (f"Also take “{name}” off the files inside {what} that have it?" if remove else
                 f"Also tag the files inside {what} “{name}”?")
            yes = ask_inside(self.window(), folders, len(inside), q, "Remove Tag" if remove else "Tag")
            return None if yes is None else inside if yes else []

        def apply(items: list[str], inside: list[str]) -> None:
            targets = items + inside
            if not targets:
                return
            try:
                n = tag_store().remove(targets, [name]) if remove else tag_store().add(targets, [name])
            except OSError as e:
                QMessageBox.warning(self.window(), "Tags", f"Couldn't save the tags: {e}")
                return
            tags_changed()
            what = f"{n:,} item{'s' if n != 1 else ''}"
            self._airdrop_noted((f"Removed “{name}” from {what}." if remove else f"Tagged {what} “{name}”.") if n else
                                (f"None of those have “{name}”." if remove else f"Those already have “{name}”."))
        self._with_inside(paths, apply, ask)

    def toggle_tag(self, paths: list[str], name: str) -> None:
        self.tag_items(paths, name)

    def clear_tags(self, paths: list[str]) -> None:
        """Every tag off the selected items; for folders, asked whether the files inside lose theirs too."""
        asked = []

        def ask(folders: list[str], inside: list[str]) -> list[str] | None:
            inside = [f for f in inside if tag_store().tags(f, fresh=False)]
            if not inside:
                return []
            asked.append(True)
            yes = ask_inside(self.window(), folders, len(inside),
                             f"Also take every tag off the files inside {describe_items(folders)}?", "Remove All Tags")
            return None if yes is None else inside if yes else []

        def apply(items: list[str], inside: list[str]) -> None:
            tagged = [p for p in items if tag_store().tags(p, fresh=False)] + inside
            if not tagged:
                self._airdrop_noted("None of these has tags.")
                return
            if len(tagged) > 1 and not asked and QMessageBox.question(
                    self.window(), "Remove All Tags",
                    f"Take every tag off these {len(tagged):,} items?") != QMessageBox.StandardButton.Yes:
                return
            try:
                n = tag_store().clear(tagged)
            except OSError as e:
                QMessageBox.warning(self.window(), "Tags", f"Couldn't save the tags: {e}")
                return
            tags_changed()
            self._airdrop_noted(f"Removed the tags from {n:,} item{'s' if n != 1 else ''}.")
        self._with_inside(paths, apply, ask)

    def on_tags_changed(self) -> None:
        """Tags changed (here, in the other pane, the sidebar or a transfer): repaint; a tag's collection
        drops the files that no longer carry it."""
        self.grid.viewport().update()
        self.list.viewport().update()
        if self.location.startswith(TAG):
            tag = self.location[len(TAG):]
            if self.results.remove_where(lambda path: not has_tag(path, tag)):
                self.model.forget_keys()
        self.update_status()


# ============================================================================ tags window


class FlowLayout(QLayout):
    """Lays its widgets out left to right, wrapping onto new lines — the tag chips."""

    def __init__(self, parent: QWidget | None = None, spacing: int = 6) -> None:
        super().__init__(parent)
        self._items = []
        self._gap = spacing
        self.setContentsMargins(0, 0, 0, 0)

    def addItem(self, item) -> None:  # noqa: N802
        self._items.append(item)

    def count(self) -> int:
        return len(self._items)

    def itemAt(self, i: int):  # noqa: N802
        return self._items[i] if 0 <= i < len(self._items) else None

    def takeAt(self, i: int):  # noqa: N802
        return self._items.pop(i) if 0 <= i < len(self._items) else None

    def hasHeightForWidth(self) -> bool:  # noqa: N802
        return True

    def heightForWidth(self, width: int) -> int:  # noqa: N802
        return self._place(QRect(0, 0, width, 0), move=False)

    def setGeometry(self, rect: QRect) -> None:  # noqa: N802
        super().setGeometry(rect)
        self._place(rect, move=True)

    def sizeHint(self) -> QSize:  # noqa: N802
        return self.minimumSize()

    def minimumSize(self) -> QSize:  # noqa: N802
        size = QSize()
        for it in self._items:
            size = size.expandedTo(it.minimumSize())
        return size

    def _place(self, rect: QRect, move: bool) -> int:
        x, y, line = rect.x(), rect.y(), 0
        for it in self._items:
            hint = it.sizeHint()
            if x + hint.width() > rect.right() + 1 and line > 0:
                x, y, line = rect.x(), y + line + self._gap, 0
            if move:
                it.setGeometry(QRect(QPoint(x, y), hint))
            x += hint.width() + self._gap
            line = max(line, hint.height())
        return y + line - rect.y()


class _TagCompleter(QCompleter):
    """Suggests a known tag for the part after the last comma, and keeps what's before it."""

    def splitPath(self, path: str) -> list[str]:  # noqa: N802
        return [path.split(",")[-1].strip()]

    def pathFromIndex(self, index) -> str:  # noqa: N802
        before = self.widget().text().rsplit(",", 1)
        return (before[0] + ", " if len(before) == 2 else "") + super().pathFromIndex(index)


class TagDialog(QDialog):
    """The tags of a set of files and folders (⌘T). Type new ones — several at once with commas,
    suggestions as you type — and press Return; or click any tag below to put it on every item, and click
    it again to take it off (a tag only some of them have shows "3/12" and goes on all of them). Every
    change is saved at once: on a drive to its tag file, which Photo Browser on the iPhone syncs with."""

    def __init__(self, parent: QWidget, files: list[str], what: str) -> None:
        super().__init__(parent)
        self.files = files                                 # files and folders — each gets the tags itself
        self.noun = "item" if any(os.path.isdir(f) for f in files) else "file"
        self._have: dict[str, tuple[str, int]] | None = None
        self.setWindowTitle("Tags")
        self.setMinimumWidth(480)
        lay = QVBoxLayout(self)
        lay.setContentsMargins(20, 18, 20, 16)
        lay.setSpacing(10)
        top = QHBoxLayout()
        icon = QLabel()
        icon.setPixmap(glyph("tag", THEME.accent, 22).pixmap(22, 22))
        top.addWidget(icon)
        title = QLabel(f"Tags for {what}", objectName="SheetTitle")
        title.setWordWrap(True)
        top.addWidget(title, 1)
        lay.addLayout(top)
        self.field = QLineEdit(objectName="TagField")
        self.field.setPlaceholderText("Add tags — separate several with commas, then press Return")
        self.completer = _TagCompleter(tag_store().names(), self)
        self.completer.setCaseSensitivity(Qt.CaseSensitivity.CaseInsensitive)
        self.completer.setFilterMode(Qt.MatchFlag.MatchContains)
        self.field.setCompleter(self.completer)
        self.field.returnPressed.connect(self._return)
        self.field.textChanged.connect(lambda _t: self._fill())
        lay.addWidget(self.field)
        self.hint = QLabel(objectName="TagHint")
        lay.addWidget(self.hint)
        self.box = QWidget(objectName="TagBox")
        self.flow = FlowLayout(self.box, 6)
        scroll = QScrollArea(objectName="TagScroll")
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.Shape.NoFrame)
        scroll.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        scroll.setWidget(self.box)
        scroll.setMinimumHeight(110)
        scroll.setMaximumHeight(260)
        lay.addWidget(scroll, 1)
        where = QLabel(self._where(), objectName="SheetSub")
        where.setWordWrap(True)
        lay.addWidget(where)
        buttons = QHBoxLayout()
        self.clear_btn = QPushButton("Remove All Tags", objectName="Danger")
        self.clear_btn.setAutoDefault(False)              # Return belongs to the field (add, or Done when empty)
        self.clear_btn.clicked.connect(self._clear)
        buttons.addWidget(self.clear_btn)
        buttons.addStretch(1)
        done = QPushButton("Done", objectName="Primary")
        done.setAutoDefault(False)
        done.clicked.connect(self.accept)
        buttons.addWidget(done)
        lay.addLayout(buttons)
        self._fill()
        self.field.setFocus()

    def _where(self) -> str:
        folders = {os.path.dirname(f) for f in self.files}
        drives = sorted({volume_name(Path(d)) for d in folders if is_external(Path(d))})
        if drives:
            return (f"Saved on “{'”, “'.join(drives)}” — Photo Browser on the iPhone picks them up the next time "
                    "it opens the drive, and tags added there show up here.")
        return (f"These {self.noun}s are on this Mac: their tags go along when Safe Finder moves or copies them onto "
                "the drive, and from there to the iPhone.")

    def _fill(self) -> None:
        while self.flow.count():
            item = self.flow.takeAt(0)
            if item.widget() is not None:
                item.widget().hide()                       # gone now, not when the event loop gets to it
                item.widget().deleteLater()
        total = len(self.files)
        if self._have is None:                             # counted once per change, not per keystroke
            self._have = tag_counts(self.files)
        have = self._have
        typed = shared_tags.fold(self.field.text().split(",")[-1].strip())
        on = sorted(have.values(), key=lambda x: (-x[1], x[0].casefold()))
        others = [n for n in tag_store().names() if shared_tags.fold(n) not in have]
        shown = 0
        for name, n in [(name, n) for name, n in on] + [(name, 0) for name in others]:
            if typed and typed not in shared_tags.fold(name):
                continue
            b = QToolButton(objectName="TagChip")
            b.setIcon(tag_dot(name))
            b.setToolButtonStyle(Qt.ToolButtonStyle.ToolButtonTextBesideIcon)
            b.setCursor(Qt.CursorShape.PointingHandCursor)
            if n == total:
                b.setText(f"{name}  ✕")
                b.setProperty("state", "on")
                b.setToolTip(f"Remove “{name}”" + ("" if total == 1 else f" from all {total:,} {self.noun}s"))
            elif n:
                b.setText(f"{name}  {n}/{total}")
                b.setProperty("state", "part")
                b.setToolTip(f"{n:,} of the {total:,} {self.noun}s have “{name}” — click to put it on all of them")
            else:
                b.setText(name)
                b.setProperty("state", "off")
                b.setToolTip(f"Add “{name}”" + ("" if total == 1 else f" to all {total:,} {self.noun}s"))
            b.clicked.connect(lambda _=False, name=name, all_on=(n == total): self._toggle(name, all_on))
            self.flow.addWidget(b)
            shown += 1
        if not shown:
            empty = QLabel("No tags yet — type one above and press Return." if not typed else
                           "No tag like that yet — press Return to add it.", objectName="TagHint")
            self.flow.addWidget(empty)
        self.hint.setText(f"Click a tag to put it on every {self.noun} — ✕ takes it off:" if have else
                          "Click a tag to add it:" if others else "")
        self.hint.setVisible(bool(have or others))
        self.clear_btn.setEnabled(bool(have))
        self.box.updateGeometry()

    def _apply(self, change) -> None:
        try:
            change()
        except OSError as e:
            QMessageBox.warning(self, "Tags", f"Couldn't save the tags: {e}")
            return
        tags_changed()
        self._have = None
        model = self.completer.model()
        if isinstance(model, QStringListModel):
            model.setStringList(tag_store().names())
        self._fill()

    def _toggle(self, name: str, all_on: bool) -> None:
        if all_on:
            self._apply(lambda: tag_store().remove(self.files, [name]))
        else:
            self._apply(lambda: tag_store().add(self.files, [name]))

    def _return(self) -> None:
        if self.completer.popup().isVisible():
            return                                         # Return picked a suggestion — press it again to add
        tags = shared_tags.split_tags(self.field.text())
        if not tags:
            self.accept()                                  # an empty field: Return is Done
            return
        self.field.clear()
        self._apply(lambda: tag_store().add(self.files, tags))

    def _clear(self) -> None:
        if len(self.files) > 1 and QMessageBox.question(
                self, "Remove All Tags", f"Take every tag off these {len(self.files):,} {self.noun}s?") \
                != QMessageBox.StandardButton.Yes:
            return
        self._apply(lambda: tag_store().clear(self.files))


# ============================================================================ sidebar


PATH_ROLE, EJECT_ROLE = 256, 257          # Qt.UserRole, Qt.UserRole + 1


class SidebarDelegate(QStyledItemDelegate):
    """Finder sidebar rows: full-width rounded highlight, icon, name, and an eject button for drives."""

    def sizeHint(self, option, index) -> QSize:  # noqa: N802
        return QSize(0, 30 if index.data(PATH_ROLE) is None else 28)

    def paint(self, p: QPainter, option: QStyleOptionViewItem, index: QModelIndex) -> None:
        r = option.rect
        p.save()
        p.setRenderHint(QPainter.RenderHint.Antialiasing)
        if index.data(PATH_ROLE) is None:                       # section heading
            f = QFont(option.font)
            f.setBold(True)
            f.setPointSizeF(max(8.0, f.pointSizeF() - 2))
            p.setFont(f)
            p.setPen(QColor(THEME.secondary))
            p.drawText(r.adjusted(10, 0, -4, -4), Qt.AlignmentFlag.AlignLeft | Qt.AlignmentFlag.AlignBottom,
                       index.data(Qt.ItemDataRole.DisplayRole))
            p.restore()
            return
        row = QRectF(r).adjusted(0, 1, 0, -1)
        tree = self.parent()
        if isinstance(tree, SidebarTree) and tree.drop_path and index.data(PATH_ROLE) == tree.drop_path:
            p.setPen(QPen(QColor(THEME.accent), 1.5))           # a tag files are being dragged onto
            p.setBrush(QColor(THEME.accent).lighter(170) if not THEME.dark else QColor(10, 132, 255, 60))
            p.drawRoundedRect(row.adjusted(1, 0, -1, 0), 6, 6)
        elif option.state & QStyle.StateFlag.State_Selected:
            p.setPen(Qt.PenStyle.NoPen)
            p.setBrush(qc(THEME.select_bg))
            p.drawRoundedRect(row, 6, 6)
        elif option.state & QStyle.StateFlag.State_MouseOver:
            p.setPen(Qt.PenStyle.NoPen)
            p.setBrush(qc(THEME.hover))
            p.drawRoundedRect(row, 6, 6)
        icon = index.data(Qt.ItemDataRole.DecorationRole)
        if isinstance(icon, QIcon):
            icon.paint(p, QRect(r.x() + 8, r.center().y() - 9, 18, 18))
        eject = bool(index.data(EJECT_ROLE))
        count = index.data(COUNT_ROLE)
        count_text = f"{count:,}" if isinstance(count, int) else ""
        count_w = QFontMetrics(option.font).horizontalAdvance(count_text) + 10 if count_text else 0
        width = r.width() - 36 - (28 if eject else 6) - count_w
        p.setPen(QColor(THEME.text) if index.flags() & Qt.ItemFlag.ItemIsSelectable else QColor(THEME.secondary))
        text = QFontMetrics(option.font).elidedText(index.data(Qt.ItemDataRole.DisplayRole), Qt.TextElideMode.ElideRight, width)
        p.drawText(QRect(r.x() + 34, r.y(), width, r.height()), Qt.AlignmentFlag.AlignVCenter, text)
        if count_text:
            p.setPen(QColor(THEME.secondary))
            p.drawText(QRect(r.right() - count_w - 4, r.y(), count_w, r.height()),
                       Qt.AlignmentFlag.AlignVCenter | Qt.AlignmentFlag.AlignRight, count_text)
        if eject:
            glyph("eject", THEME.secondary, 14).paint(p, QRect(r.right() - 24, r.center().y() - 7, 14, 14))
        p.restore()


class SidebarTree(QTreeWidget):
    """The sidebar's rows. Files dragged onto a tag (from either pane or the Finder) get that tag."""

    eject = Signal(str)
    tag_drop = Signal(str, list)          # tag, the paths dropped on it
    drop_path: str | None = None

    def mousePressEvent(self, event) -> None:  # noqa: N802
        idx = self.indexAt(event.position().toPoint())
        if idx.isValid() and idx.data(EJECT_ROLE) and event.position().x() >= self.visualRect(idx).right() - 30:
            self.eject.emit(idx.data(PATH_ROLE))
            event.accept()
            return
        super().mousePressEvent(event)

    def _tag_at(self, event) -> str | None:
        idx = self.indexAt(event.position().toPoint())
        path = idx.data(PATH_ROLE) if idx.isValid() else None
        return path if isinstance(path, str) and path.startswith(TAG) else None

    def _set_drop(self, path: str | None) -> None:
        if path != self.drop_path:
            self.drop_path = path
            self.viewport().update()

    def dragEnterEvent(self, event) -> None:  # noqa: N802
        if event.mimeData().hasUrls():
            event.setDropAction(Qt.DropAction.CopyAction)
            event.accept()
        else:
            event.ignore()

    def dragMoveEvent(self, event) -> None:  # noqa: N802
        tag = self._tag_at(event) if event.mimeData().hasUrls() else None
        self._set_drop(tag)
        if tag:
            event.setDropAction(Qt.DropAction.CopyAction)     # never let the source "move" anything
            event.accept()
        else:
            event.ignore()

    def dragLeaveEvent(self, event) -> None:  # noqa: N802
        self._set_drop(None)
        event.accept()

    def dropEvent(self, event) -> None:  # noqa: N802
        tag = self._tag_at(event)
        self._set_drop(None)
        paths = [u.toLocalFile() for u in event.mimeData().urls() if u.isLocalFile()]
        if not tag or not paths:
            event.ignore()
            return
        event.setDropAction(Qt.DropAction.CopyAction)
        event.accept()
        QTimer.singleShot(0, lambda: self.tag_drop.emit(tag[len(TAG):], paths))


REVEAL_ROLE = 258                         # a sidebar row that reveals its folder (selects it in its parent)
COUNT_ROLE = 259                          # a number shown at the row's right end (a tag's files)


class Sidebar(QWidget):
    navigate = Signal(str)
    eject = Signal(str)
    reveal = Signal(str)
    tag_drop = Signal(str, list)          # tag, paths dropped on it
    tag_renamed = Signal(str, str)        # old, new

    def __init__(self) -> None:
        super().__init__(objectName="Sidebar")
        self.empty: list[str] = []              # the empty folders found under empty_roots()
        self._empty_scan: EmptyFolderScanner | None = None
        self._empty_found: list[str] = []
        lay = QVBoxLayout(self)
        lay.setContentsMargins(0, 4, 0, 8)
        self.tree = SidebarTree(objectName="SidebarTree")
        self.tree.setHeaderHidden(True)
        self.tree.setColumnCount(1)
        self.tree.setIndentation(0)
        self.tree.setRootIsDecorated(False)
        self.tree.setItemDelegate(SidebarDelegate(self.tree))
        self.tree.setFocusPolicy(Qt.FocusPolicy.NoFocus)
        self.tree.setMouseTracking(True)
        self.tree.viewport().setAttribute(Qt.WidgetAttribute.WA_Hover)
        self.tree.itemClicked.connect(self._clicked)
        self.tree.eject.connect(self.eject.emit)
        self.tree.setAcceptDrops(True)
        self.tree.viewport().setAcceptDrops(True)
        self.tree.setDragDropMode(QAbstractItemView.DragDropMode.DropOnly)
        self.tree.tag_drop.connect(self.tag_drop.emit)
        self.tree.setContextMenuPolicy(Qt.ContextMenuPolicy.CustomContextMenu)
        self.tree.customContextMenuRequested.connect(self._context_menu)
        self._tags_section: QTreeWidgetItem | None = None
        lay.addWidget(self.tree)
        self.provider = QFileIconProvider()
        self.watcher = QFileSystemWatcher(self)
        if VOLUMES.is_dir():
            self.watcher.addPath(str(VOLUMES))
        self._debounce = QTimer(self)
        self._debounce.setSingleShot(True)
        self._debounce.setInterval(600)
        self._debounce.timeout.connect(self.rebuild)
        self.watcher.directoryChanged.connect(lambda _p: self._debounce.start())
        self.rebuild()
        QTimer.singleShot(1200, self.refresh_empty)      # once the window is up: look for empty folders

    def refresh_empty(self) -> None:
        """Look for empty folders under Documents, Pictures, Movies and Downloads (background); the
        section rebuilds when the scan is done."""
        if self._empty_scan is not None:
            self._empty_scan.cancel()
        scan = EmptyFolderScanner(empty_roots())
        self._empty_scan, self._empty_found = scan, []
        queued = Qt.ConnectionType.QueuedConnection
        scan.signals.found.connect(lambda batch, s=scan: self._empty_batch(s, batch), queued)
        scan.signals.done.connect(lambda ok, s=scan: self._empty_done(s, ok), queued)
        scan.start()

    def _empty_batch(self, scan: EmptyFolderScanner, batch: list) -> None:
        if scan is self._empty_scan:
            self._empty_found.extend(path for path, _size, _mtime, _is_dir in batch)

    def _empty_done(self, scan: EmptyFolderScanner, ok: bool) -> None:
        if scan is not self._empty_scan:
            return
        self._empty_scan = None
        if ok:
            self.empty = sorted(self._empty_found, key=lambda p: natural_key(p))
            self.rebuild()

    def _section(self, title: str) -> QTreeWidgetItem:
        it = QTreeWidgetItem([title])
        it.setFlags(Qt.ItemFlag.ItemIsEnabled)          # not selectable — but enabled, or its children are disabled too
        self.tree.addTopLevelItem(it)
        return it

    def _entry(self, parent: QTreeWidgetItem, label: str, path: Path, ejectable: bool = False) -> None:
        it = QTreeWidgetItem([label])
        it.setData(0, PATH_ROLE, str(path))
        it.setData(0, EJECT_ROLE, ejectable)
        it.setIcon(0, self.provider.icon(QFileInfo(str(path))))
        it.setToolTip(0, str(path) + (" — click ⏏ to eject" if ejectable else ""))
        parent.addChild(it)

    def _collection(self, parent: QTreeWidgetItem, label: str, key: str, icon: QIcon, tip: str) -> None:
        it = QTreeWidgetItem([label])
        it.setData(0, PATH_ROLE, key)
        it.setData(0, EJECT_ROLE, False)
        it.setIcon(0, icon)
        it.setToolTip(0, tip)
        parent.addChild(it)

    def rebuild(self) -> None:
        global MOUNTS
        MOUNTS = mounts()
        tag_store().forget_volumes()                   # a drive came or went: its tags with it
        selected = [i.data(0, PATH_ROLE) for i in self.tree.selectedItems()]
        self.tree.clear()
        fav = self._section("Favorites")
        self._collection(fav, "All Videos", VIDEOS, glyph("film", THEME.accent, 16),
                         "Every video in your home folder, newest first — shown on the From side")
        home = Path.home()
        for label, p in (("Desktop", home / "Desktop"), ("Downloads", home / "Downloads"),
                         ("Documents", home / "Documents"), ("Pictures", home / "Pictures"),
                         ("Movies", home / "Movies"), (home.name, home)):
            if p.is_dir():
                self._entry(fav, label, p)
        loc = self._section("Locations")
        self._entry(loc, boot_volume_name(), Path("/"))
        for v in external_volumes():
            self._entry(loc, v.name, v, ejectable=True)
        self._tags_section = self._section("Tags")
        self._fill_tags()
        # Empty folders (0 KB) under Documents, Pictures, Movies and Downloads: the collection
        # first (all of them, for a bulk Move to Trash), then each one — a click shows it in its
        # folder, selected, so ⌘⌫ is one keystroke away.
        n = len(self.empty)
        sec = self._section("Empty Folders" + (f" ({n})" if n else ""))
        self._collection(sec, "All Empty Folders" if n else ("Looking…" if self._empty_scan else "None found"),
                         EMPTY, glyph("trash", THEME.accent, 16),
                         "Folders with nothing in them under Documents, Pictures, Movies and Downloads — "
                         "shown on the From side; select some and press ⌘⌫")
        cap = 40
        for path in self.empty[:cap]:
            it = QTreeWidgetItem([os.path.basename(path.rstrip(os.sep))])
            it.setData(0, PATH_ROLE, path)
            it.setData(0, EJECT_ROLE, False)
            it.setData(0, REVEAL_ROLE, True)
            it.setIcon(0, self.provider.icon(QFileInfo(path)))
            it.setToolTip(0, path + " — empty; click to show it in its folder")
            sec.addChild(it)
        if n > cap:
            self._collection(sec, f"… and {n - cap} more", EMPTY, glyph("trash", THEME.secondary, 16),
                             "Open All Empty Folders to see every one")
        self.tree.expandAll()
        if selected:
            self.select_path(selected[0])

    def _fill_tags(self) -> None:
        """The Tags section: every tag on this Mac and the connected drives, A to Z, with how many files
        carry it. A click shows those files; files dropped on one get it."""
        sec = self._tags_section
        if sec is None:
            return
        for child in sec.takeChildren():
            del child
        counts = sorted(tag_store().counts(), key=lambda x: x[0].casefold())
        if not counts:
            it = QTreeWidgetItem(["Select files and press ⌘T"])
            it.setData(0, PATH_ROLE, "")
            it.setFlags(Qt.ItemFlag.ItemIsEnabled)
            it.setIcon(0, glyph("tag", THEME.tertiary, 16))
            it.setToolTip(0, "Tag files here and they show up in Photo Browser on the iPhone — and tags added "
                             "there show up here")
            sec.addChild(it)
            return
        for name, n in counts:
            it = QTreeWidgetItem([name])
            it.setData(0, PATH_ROLE, TAG + name)
            it.setData(0, EJECT_ROLE, False)
            it.setData(0, COUNT_ROLE, n)
            it.setIcon(0, tag_dot(name, 14))
            it.setToolTip(0, f"{n:,} file{'s' if n != 1 else ''} tagged “{name}” — click to see them, drop files "
                             "here to tag them, right-click to rename")
            sec.addChild(it)

    def refresh_tags(self) -> None:
        selected = [i.data(0, PATH_ROLE) for i in self.tree.selectedItems()]
        self._fill_tags()
        if self._tags_section is not None:
            self._tags_section.setExpanded(True)
        if selected:
            self.select_path(selected[0])

    def _context_menu(self, pos) -> None:
        item = self.tree.itemAt(pos)
        path = item.data(0, PATH_ROLE) if item is not None else None
        if not isinstance(path, str) or not path.startswith(TAG):
            return
        name = path[len(TAG):]
        menu = QMenu(self)
        menu.addAction(f"Show Files Tagged “{name}”", lambda: self.navigate.emit(path))
        menu.addAction("Rename Tag…", lambda: self._rename_tag(name))
        menu.addSeparator()
        menu.addAction(f"Remove “{name}” from Every File…", lambda: self._remove_tag(name))
        menu.exec(self.tree.viewport().mapToGlobal(pos))

    def _rename_tag(self, name: str) -> None:
        new, ok = QInputDialog.getText(self.window(), "Rename Tag",
                                       f"New name for “{name}”, on every file that has it (on this Mac and the "
                                       "connected drives — the iPhone follows when it next opens the drive):",
                                       text=name)
        new = shared_tags.normalized(new) if ok else ""
        if not new or new == name:
            return
        try:
            tag_store().rename(name, new)
        except OSError as e:
            QMessageBox.warning(self.window(), "Rename Tag", f"Couldn't save the tags: {e}")
            return
        tags_changed()
        self.tag_renamed.emit(name, new)

    def _remove_tag(self, name: str) -> None:
        files = tag_store().files_with(name)
        if QMessageBox.question(
                self.window(), "Remove Tag",
                f"Take “{name}” off all {len(files):,} file{'s' if len(files) != 1 else ''} that have it, on this Mac "
                "and the connected drives? The iPhone follows when it next opens the drive.") \
                != QMessageBox.StandardButton.Yes:
            return
        try:
            tag_store().remove(files, [name])
        except OSError as e:
            QMessageBox.warning(self.window(), "Remove Tag", f"Couldn't save the tags: {e}")
            return
        tags_changed()

    def select_path(self, path: str) -> None:
        self.tree.clearSelection()
        for i in range(self.tree.topLevelItemCount()):
            sec = self.tree.topLevelItem(i)
            for j in range(sec.childCount()):
                it = sec.child(j)
                if it.data(0, PATH_ROLE) == path:
                    it.setSelected(True)

    def _clicked(self, item: QTreeWidgetItem, _col: int) -> None:
        path = item.data(0, PATH_ROLE)
        if not path:
            return
        if item.data(0, REVEAL_ROLE):
            self.reveal.emit(path)
        else:
            self.navigate.emit(path)


MOUNTS: dict[str, str] = {}


# ============================================================================ confirmation sheet


class _Planned(QObject):
    done = Signal(object)


class ConfirmSheet(QDialog):
    """Lists exactly what a transfer will do before anything is touched."""

    def __init__(self, parent: QWidget, sources: list[str], dest: str, move: bool, verify: bool) -> None:
        super().__init__(parent, Qt.WindowType.Sheet if IS_MAC else Qt.WindowType.Dialog)
        self.setWindowModality(Qt.WindowModality.WindowModal)
        self.setWindowTitle("Safe Finder")
        self.sources, self.dest = [Path(s) for s in sources], Path(dest)
        self.plan: engine.Plan | None = None
        self.setMinimumWidth(520)
        lay = QVBoxLayout(self)
        lay.setContentsMargins(22, 20, 22, 18)
        lay.setSpacing(12)

        head = QHBoxLayout()
        head.setSpacing(14)
        icon = QLabel()
        first = self.sources[0]
        thumb = None
        if first.is_file() and kind_of(str(first)) != "other" and THUMBS is not None:
            thumb = THUMBS.get(str(first), int(first.stat().st_mtime), 84)
        icon.setPixmap(thumb.scaled(52, 52, Qt.AspectRatioMode.KeepAspectRatio,
                                    Qt.TransformationMode.SmoothTransformation) if thumb is not None
                       else QFileIconProvider().icon(QFileInfo(str(first))).pixmap(48, 48))
        head.addWidget(icon, 0, Qt.AlignmentFlag.AlignTop)
        texts = QVBoxLayout()
        texts.setSpacing(2)
        self.title = QLabel(objectName="SheetTitle")
        self.title.setWordWrap(True)
        drive = volume_name(self.dest)
        fs = FS_NAMES.get(MOUNTS.get(str(engine.volume_root(self.dest)), ""), "")
        where = (f"onto “{drive}”" if engine.volume_root(self.dest) == self.dest
                 else f"into “{self.dest.name}” on {drive}")
        sub = QLabel(where + (f" · {fs}" if fs else ""), objectName="SheetSub")
        sub.setWordWrap(True)
        texts.addWidget(self.title)
        texts.addWidget(sub)
        head.addLayout(texts, 1)
        lay.addLayout(head)

        self.rows_box = QVBoxLayout()
        self.rows_box.setSpacing(6)
        self.checking = QLabel("Checking what's in the selection…", objectName="SheetSub")
        self.rows_box.addWidget(self.checking)
        lay.addLayout(self.rows_box)

        opts = QHBoxLayout()
        self.copy_seg = QPushButton("Copy", objectName="SegLeft")
        self.move_seg = QPushButton("Move", objectName="SegRight")
        for b in (self.copy_seg, self.move_seg):
            b.setCheckable(True)
        seg = QButtonGroup(self)
        seg.setExclusive(True)
        seg.addButton(self.copy_seg)
        seg.addButton(self.move_seg)
        (self.move_seg if move else self.copy_seg).setChecked(True)
        self.copy_seg.toggled.connect(self._refresh)
        opts.addWidget(self.copy_seg)
        opts.addWidget(self.move_seg)
        opts.addSpacing(16)
        self.verify = QCheckBox("Verify every file after copying")
        self.verify.setChecked(verify)
        self.verify.setToolTip("Re-reads each copy from the SSD and compares it with the original. Recommended.")
        opts.addWidget(self.verify)
        opts.addStretch(1)
        lay.addLayout(opts)
        self.mode_note = QLabel(objectName="SheetSub")
        self.mode_note.setWordWrap(True)
        lay.addWidget(self.mode_note)

        buttons = QHBoxLayout()
        buttons.addStretch(1)
        cancel = QPushButton("Cancel")
        cancel.clicked.connect(self.reject)
        self.go_btn = QPushButton(objectName="Primary")
        self.go_btn.setDefault(True)
        self.go_btn.setEnabled(False)
        self.go_btn.clicked.connect(self.accept)
        buttons.addWidget(cancel)
        buttons.addWidget(self.go_btn)
        lay.addLayout(buttons)
        self._refresh()

        self._planned = _Planned()
        self._planned.done.connect(self._show_plan)
        threading.Thread(target=lambda: self._planned.done.emit(engine.build_plan(self.sources, self.dest)),
                         daemon=True).start()

    @property
    def move(self) -> bool:
        return self.move_seg.isChecked()

    def _refresh(self, *_args) -> None:
        verb = "Move" if self.move else "Copy"
        n = len(self.sources)
        what = f"“{self.sources[0].name}”" if n == 1 else f"{n} items"
        self.title.setText(f"{verb} {what}?")
        self.go_btn.setText(verb)
        self.mode_note.setText(
            "Move: each original goes to the Trash only after its copy has been checked. Items already on this "
            "drive are simply moved." if self.move else
            "Copy: the originals stay where they are.")
        if self.plan is not None:
            self._show_plan(self.plan)

    def _show_plan(self, plan: engine.Plan) -> None:
        self.plan = plan
        while self.rows_box.count():
            w = self.rows_box.takeAt(0).widget()
            if w:
                w.deleteLater()
        for kind, text in engine.describe(plan, self.move):
            row = QFrame(objectName="SheetRow")
            rl = QHBoxLayout(row)
            rl.setContentsMargins(10, 7, 10, 7)
            rl.setSpacing(10)
            ic = QLabel()
            ic.setPixmap(glyph(kind, None, 16).pixmap(16, 16))
            rl.addWidget(ic, 0, Qt.AlignmentFlag.AlignTop)
            lab = QLabel(text)
            lab.setWordWrap(True)
            lab.setTextInteractionFlags(Qt.TextInteractionFlag.TextSelectableByMouse)
            rl.addWidget(lab, 1)
            self.rows_box.addWidget(row)
        QTimer.singleShot(0, self.adjustSize)
        self.go_btn.setEnabled(not engine.blocking(plan, self.move))


# ============================================================================ transfer panel


class _Bridge(QObject):
    log = Signal(str)
    progress = Signal(object)
    finished = Signal(object)


class TransferPanel(QFrame):
    """Finder's copy-progress window, docked at the bottom."""

    pause_toggled = Signal(bool)
    stop_requested = Signal()
    eject_requested = Signal(str)

    def __init__(self) -> None:
        super().__init__(objectName="TransferPanel")
        lay = QVBoxLayout(self)
        lay.setContentsMargins(16, 10, 16, 12)
        lay.setSpacing(6)
        top = QHBoxLayout()
        top.setSpacing(10)
        self.icon = QLabel()
        top.addWidget(self.icon)
        self.title = QLabel(objectName="TransferTitle")
        top.addWidget(self.title, 1)
        self.details_btn = QPushButton("Details")
        self.details_btn.setCheckable(True)
        self.details_btn.toggled.connect(lambda on: self.log.setVisible(on))
        self.eject_btn = QPushButton()
        self.eject_btn.setIcon(glyph("eject", THEME.text, 14))
        self.eject_btn.clicked.connect(lambda: self.eject_requested.emit(self.eject_path))
        self.pause_btn = QToolButton(objectName="Nav")
        self.pause_btn.setCheckable(True)
        self.pause_btn.setToolTip("Pause after the current file")
        self.pause_btn.toggled.connect(self._pause)
        self.stop_btn = QToolButton(objectName="Nav")
        self.stop_btn.setToolTip("Stop — the file being copied is cleaned up, finished files stay")
        self.stop_btn.clicked.connect(self.stop_requested.emit)
        self.close_btn = QToolButton(objectName="Nav")
        self.close_btn.setToolTip("Hide")
        self.close_btn.clicked.connect(self.hide)
        for w in (self.details_btn, self.eject_btn, self.pause_btn, self.stop_btn, self.close_btn):
            top.addWidget(w)
        lay.addLayout(top)
        self.bar = QProgressBar()
        self.bar.setRange(0, 1000)
        self.bar.setTextVisible(False)
        lay.addWidget(self.bar)
        self.detail = QLabel(objectName="TransferDetail")
        lay.addWidget(self.detail)
        self.log = QPlainTextEdit()
        self.log.setReadOnly(True)
        self.log.setMaximumBlockCount(5000)
        self.log.setFixedHeight(140)
        self.log.hide()
        lay.addWidget(self.log)
        self.eject_path = ""
        self.restyle()
        self.hide()

    def restyle(self) -> None:
        self.pause_btn.setIcon(glyph("play" if self.pause_btn.isChecked() else "pause", THEME.text, 16))
        self.stop_btn.setIcon(glyph("stop", THEME.secondary, 16))
        self.close_btn.setIcon(glyph("stop", THEME.tertiary, 14))
        self.eject_btn.setIcon(glyph("eject", THEME.text, 14))

    def _pause(self, on: bool) -> None:
        self.restyle()
        self.pause_toggled.emit(on)

    def running(self, title: str, queued: int) -> None:
        self.show()
        self.icon.setPixmap(glyph("arrow", THEME.accent, 22).pixmap(22, 22))
        self.title.setText(title + (f"   ·   {queued} more waiting" if queued else ""))
        self.pause_btn.setChecked(False)
        for w in (self.pause_btn, self.stop_btn, self.bar):
            w.setVisible(True)
        self.eject_btn.hide()
        self.close_btn.hide()
        self.bar.setValue(0)
        self.detail.setText("Starting…")

    def progress(self, done: int, total: int, files_done: int, files_total: int, name: str, phase: str,
                 speed: float) -> None:
        self.bar.setValue(int(1000 * done / total) if total else (1000 if phase == "Done" else 0))
        parts = [f"{human(done)} of {human(total)}", f"{files_done:,} of {files_total:,} files"]
        if speed > 0:
            parts.append(f"{human(speed)}/s")
            left = (total - done) / speed
            if left > 1:
                parts.append("about " + (f"{left / 60:.0f} min" if left >= 90 else f"{left:.0f} s") + " left")
        if self.pause_btn.isChecked():
            parts.append("paused")
        elif name:
            parts.append(f"{phase} {name}")
        self.detail.setText("  ·  ".join(parts))

    def finished(self, ok: bool, title: str, detail: str, eject_path: str) -> None:
        self.show()
        kind = "ok" if ok else "warn"
        self.icon.setPixmap(glyph(kind, None, 22).pixmap(22, 22))
        self.title.setText(title)
        self.detail.setText(detail)
        for w in (self.pause_btn, self.stop_btn, self.bar):
            w.setVisible(False)
        self.close_btn.show()
        self.eject_path = eject_path
        self.eject_btn.setText(f"Eject “{os.path.basename(eject_path)}”")
        self.eject_btn.setVisible(bool(eject_path))


# ============================================================================ window


class MainWindow(QMainWindow):
    def __init__(self, start_from: str | None, start_to: str | None) -> None:
        super().__init__()
        self.setWindowTitle("Safe Finder")
        self.settings = QSettings("PhotoBrowser", "SafeFinder")
        self.resize(1320, 820)
        self.setMinimumSize(980, 600)
        self.queue: list[tuple[engine.Plan, bool, bool, str]] = []
        self.current: engine.Transfer | None = None
        self.caffeinate: subprocess.Popen | None = None
        self._speed = 0.0
        self._last = (0.0, 0)

        self.sidebar = Sidebar()
        self.sidebar.setMinimumWidth(170)
        self.sidebar.navigate.connect(self._navigate)
        self.sidebar.reveal.connect(lambda path: self.active_pane.reveal(path))
        self.sidebar.eject.connect(self.eject)
        self.sidebar.tag_drop.connect(self._tag_dropped)
        self.sidebar.tag_renamed.connect(self._tag_renamed)
        self.src = Pane("From", self.settings)
        self.dst = Pane("To", self.settings, self.src.views)
        for pane in (self.src, self.dst):
            pane.activated.connect(self.set_active)
            pane.dropped.connect(lambda paths, dest: self.confirm_transfer(
                paths, dest, self.settings.value("move", "true") == "true"))
            pane.location_changed.connect(lambda _p, pane=pane: self._location_changed(pane))
            pane.selection_changed.connect(self.update_actions)
            pane.selection_changed.connect(pane.update_status)

        panes = QSplitter(Qt.Orientation.Horizontal)
        panes.setHandleWidth(1)
        panes.addWidget(self.src)
        panes.addWidget(self.dst)
        panes.setChildrenCollapsible(False)
        split = QSplitter(Qt.Orientation.Horizontal)
        split.setHandleWidth(1)
        split.addWidget(self.sidebar)
        split.addWidget(panes)
        split.setStretchFactor(1, 1)
        split.setSizes([200, 1120])
        split.setChildrenCollapsible(False)

        action = QWidget(objectName="ActionBar")
        al = QHBoxLayout(action)
        al.setContentsMargins(16, 9, 16, 9)
        al.setSpacing(10)
        self.summary = QLabel(objectName="Summary")
        al.addWidget(self.summary, 1)
        self.copy_btn = QPushButton()
        self.copy_btn.clicked.connect(lambda: self.transfer_selection(False))
        self.move_btn = QPushButton(objectName="Primary")
        self.move_btn.setIcon(glyph("arrow", "#FFFFFF", 14))
        self.move_btn.clicked.connect(lambda: self.transfer_selection(True))
        al.addWidget(self.copy_btn)
        al.addWidget(self.move_btn)

        self.panel = TransferPanel()
        self.panel.pause_toggled.connect(lambda on: self.current and self.current.pause(on))
        self.panel.stop_requested.connect(self.stop_transfer)
        self.panel.eject_requested.connect(self.eject)

        central = QWidget()
        cl = QVBoxLayout(central)
        cl.setContentsMargins(0, 0, 0, 0)
        cl.setSpacing(0)
        cl.addWidget(split, 1)
        cl.addWidget(action)
        cl.addWidget(self.panel)
        self.setCentralWidget(central)

        self.bridge = _Bridge()
        self.bridge.log.connect(self._log)
        self.bridge.progress.connect(self._progress)
        self.bridge.finished.connect(self._finished)
        # The transfer reports every file (twice, when verifying); the panel shows the latest a few
        # times a second and the log takes its lines in batches, so a run of thousands of small files
        # never queues more work for the window than it can do.
        self._log_lines: list[str] = []
        self._latest: dict | None = None
        self._panel_soon = QTimer(self)
        self._panel_soon.setSingleShot(True)
        self._panel_soon.setInterval(200)
        self._panel_soon.timeout.connect(self._show_progress)
        THUMBS.ready.connect(lambda: (self.src.grid.viewport().update(), self.dst.grid.viewport().update()))
        tag_events().changed.connect(self._tags_changed)

        home = str(Path.home())
        start_src = start_from or self.settings.value("From/location") or str(Path.home() / "Downloads")
        self.src.go(start_src if os.path.isdir(start_src) else home)
        ext = external_volumes()
        start_dst = start_to or self.settings.value("To/location") or (str(ext[0]) if ext else home)
        self.dst.go(start_dst if os.path.isdir(start_dst) else (str(ext[0]) if ext else home))
        self.set_active(self.src)
        geo = self.settings.value("geometry")
        if geo is not None:
            self.restoreGeometry(geo)
        QShortcut(QKeySequence("Ctrl+Shift+M"), self, activated=lambda: self.transfer_selection(True))
        QShortcut(QKeySequence("Ctrl+Shift+C"), self, activated=lambda: self.transfer_selection(False))
        QShortcut(QKeySequence("Ctrl+F"), self, activated=lambda: (self.active_pane.search.setFocus(),
                                                                  self.active_pane.search.selectAll()))
        self.update_actions()

    # -- panes
    @property
    def active_pane(self) -> Pane:
        return self.src if self.src.active else self.dst

    def _navigate(self, path: str) -> None:
        if path in (VIDEOS, EMPTY):            # a collection of the Mac's own — always the From side
            self.set_active(self.src)
            self.src.go(path)
            if path == EMPTY:
                self.sidebar.refresh_empty()   # the sidebar's list looks again too
        else:
            self.active_pane.go(path)

    def set_active(self, pane: Pane) -> None:
        for p in (self.src, self.dst):
            p.set_active(p is pane)
        self.sidebar.select_path(pane.location)

    # -- tags
    def _tags_changed(self) -> None:
        self.sidebar.refresh_tags()
        for pane in (self.src, self.dst):
            pane.on_tags_changed()

    def _tag_dropped(self, tag: str, paths: list[str]) -> None:
        """Files and folders dropped on a tag in the sidebar get it (a folder: asked whether the files
        inside it do too)."""
        self.active_pane.tag_items(paths, tag, remove=False)

    def _tag_renamed(self, old: str, new: str) -> None:
        for pane in (self.src, self.dst):
            if pane.location == TAG + old:
                pane.go(TAG + new, record=False)

    def _location_changed(self, pane: Pane) -> None:
        if pane.active:
            self.sidebar.select_path(pane.location)
        self.update_actions()

    def restyle(self) -> None:
        self.src.restyle()
        self.dst.restyle()
        self.panel.restyle()
        self.move_btn.setIcon(glyph("arrow", "#FFFFFF", 14))
        self.sidebar.rebuild()
        self.sidebar.select_path(self.active_pane.location)

    @property
    def dest(self) -> str:
        """Where Move/Copy put things: the To pane's folder — none while it shows search results."""
        return "" if self.dst.is_virtual else self.dst.location

    def update_actions(self) -> None:
        dest = self.dest
        if dest:
            dest_name = os.path.basename(dest.rstrip(os.sep)) or volume_name(Path(dest))
            if engine.volume_root(Path(dest)) == Path(dest):
                dest_name = volume_name(Path(dest))
            self.copy_btn.setText(f"Copy to “{dest_name}”")
            self.move_btn.setText(f"Move to “{dest_name}”")
        else:
            self.copy_btn.setText("Copy")
            self.move_btn.setText("Move")
        picked = self.src.selection()
        paths, folders = picked.paths, picked.folders
        enabled = bool(paths) and bool(dest)
        self.copy_btn.setEnabled(enabled)
        self.move_btn.setEnabled(enabled)
        if not paths:
            self.summary.setText("Select files or folders on the left, then Move or Copy — or drag them onto the right.")
            return
        if not dest:
            self.summary.setText("Open a folder on the right to move or copy into — the right pane is showing search results.")
            return
        known = [folder_size(p) for p in folders]
        bits = [f"{len(paths)} item{'s' if len(paths) != 1 else ''} selected"]
        if picked.files:
            bits.append(f"{picked.files} file{'s' if picked.files != 1 else ''} · {human(picked.file_bytes)}")
        if folders:
            folder_bytes = sum(k for k in known if k is not None)
            note = f" · {human(folder_bytes)}" if all(k is not None for k in known) else (f" · {human(folder_bytes)}+" if folder_bytes else "")
            bits.append(f"{len(folders)} folder{'s' if len(folders) != 1 else ''}{note}")
        self.summary.setText("   ·   ".join(bits))

    # -- transfers
    def transfer_selection(self, move: bool) -> None:
        paths = self.src.selected_paths()
        if paths and self.dest:
            self.confirm_transfer(paths, self.dest, move)

    def confirm_transfer(self, paths: list[str], dest: str, move: bool = True) -> None:
        verify = self.settings.value("verify", "true") == "true"
        sheet = ConfirmSheet(self, paths, dest, move, verify)

        def accepted() -> None:
            if sheet.plan is None:
                return
            self.settings.setValue("verify", "true" if sheet.verify.isChecked() else "false")
            self.settings.setValue("move", "true" if sheet.move else "false")
            n = len(sheet.plan.tops)
            what = f"“{sheet.plan.tops[0].src.name}”" if n == 1 else f"{n} items"
            verb = "Moving" if sheet.move else "Copying"
            title = f"{verb} {what} to “{Path(dest).name or volume_name(Path(dest))}”"
            self.queue.append((sheet.plan, sheet.move, sheet.verify.isChecked(), title))
            if sheet.move:
                self._deselect(paths)
            if self.current is None:
                self._start_next()
            else:
                self.panel.running(self.panel.title.text().split("   ·   ")[0], len(self.queue))

        sheet.accepted.connect(accepted)
        sheet.open()

    def _deselect(self, paths: list[str]) -> None:
        """A move is starting: its originals leave the selection now, at once, rather than one by one
        as each goes to the Trash."""
        going = set(paths)
        for pane in (self.src, self.dst):
            if going.intersection(pane.selected_paths()):
                pane.grid.clearSelection()

    def _start_next(self) -> None:
        global TRANSFERRING
        if not self.queue:
            return
        TRANSFERRING = True
        if self.current is None and not getattr(self, "_in_batch", False):
            self._batch: list[tuple[bool, str, str]] = []
            self._in_batch = True
        plan, move, verify, title = self.queue.pop(0)
        self.panel.running(title, len(self.queue))
        self.panel.log.appendPlainText(f"— {time.strftime('%H:%M:%S')}  {title}")
        self._title = title
        self._dest = plan.dest
        self._verify = verify
        self._started = time.time()
        self._speed, self._last = 0.0, (time.time(), 0)

        self.current = engine.Transfer(plan, move, verify, self.bridge.log.emit, self.bridge.progress.emit,
                                       self.bridge.finished.emit, trash=self.trash_item)
        if IS_MAC and self.caffeinate is None and shutil.which("caffeinate"):
            self.caffeinate = subprocess.Popen(["caffeinate", "-ims"])     # no sleep mid-copy
        self.current.start()

    @staticmethod
    def trash_item(p: Path) -> bool:
        """The system Trash (recoverable). Called from the transfer thread."""
        from PySide6.QtCore import QFile
        return bool(QFile.moveToTrash(str(p))) or engine.trash_with_finder(p)

    def _log(self, line: str) -> None:
        self._log_lines.append(line)
        if not self._panel_soon.isActive():
            self._panel_soon.start()

    def _flush_log(self) -> None:
        if self._log_lines:
            self.panel.log.appendPlainText("\n".join(self._log_lines))
            self._log_lines.clear()

    def _progress(self, d: dict) -> None:
        self._latest = d
        if not self._panel_soon.isActive():
            self._panel_soon.start()

    def _show_progress(self) -> None:
        self._flush_log()
        d, self._latest = self._latest, None
        if d is None or self.current is None:
            return
        now = time.time()
        t_last, b_last = self._last
        if now - t_last >= 0.5:
            inst = (d["done_bytes"] - b_last) / max(now - t_last, 1e-3)
            self._speed = inst if self._speed == 0 else 0.7 * self._speed + 0.3 * inst
            self._last = (now, d["done_bytes"])
        self.panel.progress(d["done_bytes"], d.get("total_bytes", 0), d["done_files"], d.get("total_files", 0),
                            d.get("name", ""), d.get("phase", ""), self._speed)

    def _finished(self, st: dict) -> None:
        global TRANSFERRING
        self._panel_soon.stop()
        self._flush_log()
        self._latest = None
        self.current = None
        self._carry_tags(st)
        sizer().clear()                                   # folder sizes on both sides changed
        self.src.refresh_results()
        self.dst.refresh_results()
        self.sidebar.refresh_empty()
        verb = "Moved" if "Moving" in self._title else "Copied"
        n_ok = st["copied"] + st["skipped"]
        secs = st["seconds"]
        if st["error"]:
            ok, title, detail = False, "Stopped — the drive went away", st["error"]
        elif st["stopped"]:
            ok, title = False, "Stopped"
            n = st["copied"]
            detail = (f"{n:,} file{' was' if n == 1 else 's were'} copied before you stopped. Run the same "
                      "transfer again to finish — what's already there is skipped. Nothing was moved to the Trash.")
        elif st["failed"]:
            ok = False
            title = f"{verb} {n_ok:,} of {st['files']:,} files — {st['failed']} failed"
            detail = "The originals of anything that failed were kept. See Details for which ones and why."
        elif st["kept"]:
            ok = False
            title = (f"Copied {st['files']:,} files — {st['kept']} original{'s' if st['kept'] != 1 else ''} "
                     "couldn't go to the Trash")
            detail = ("The copies are on the drive and verified; those originals are still where they were. "
                      "Delete them yourself once you've checked the copies.")
        else:
            ok = True
            what = f"{st['files']:,} file{'s' if st['files'] != 1 else ''}"
            title = f"{verb} {what} to “{self._dest.name or volume_name(self._dest)}”"
            bits = []
            if st["copied"]:
                bits.append(f"{st['copied']:,} copied" + (" and verified" if self._verify else ""))
            if st["skipped"]:
                bits.append(f"{st['skipped']:,} already there (identical)")
            if st["moved"]:
                bits.append(f"{st['moved']} moved within the drive")
            if st["trashed"]:
                bits.append(f"{st['trashed']} original{'s' if st['trashed'] != 1 else ''} moved to the Trash")
            if st.get("spare_dirs"):
                bits.append(f"{st['spare_dirs']} new folder{'s' if st['spare_dirs'] != 1 else ''} made from spares")
            bits.append(f"{secs:.0f} s")
            detail = "  ·  ".join(bits)
            if st.get("plain_dirs"):
                ok = False
                n = st["plain_dirs"]
                detail += ("\n" + spare_folders.miss_message(
                               st.get("spare_miss", ""), f"{n} new folder{'s were' if n != 1 else ' was'}")
                           + f", so {'they' if n != 1 else 'it'} may not open on the iPhone. In Terminal: "
                           + engine.spares_command(engine.volume_root(self._dest)))
        self.panel.log.appendPlainText(f"— {title}. {detail}")
        eject = str(engine.volume_root(self._dest)) if is_external(self._dest) else ""
        self._batch.append((ok, title, detail))
        if self.queue:
            self._start_next()
            return
        if self.caffeinate is not None:
            self.caffeinate.terminate()
            self.caffeinate = None
        self._in_batch = False
        TRANSFERRING = False
        for pane in (self.src, self.dst):                 # what check_carried passed over meanwhile
            if not pane.is_virtual and pane.location:
                _CARRIED_AT.pop(pane.location, None)
                check_carried(pane.location)
        if len(self._batch) > 1:
            bad = sum(1 for r in self._batch if not r[0])
            ok = bad == 0
            title = (f"All {len(self._batch)} transfers finished" if ok
                     else f"{len(self._batch)} transfers finished — {bad} need{'s' if bad == 1 else ''} a look")
            detail = "   ·   ".join(r[1] for r in self._batch)
        self.panel.finished(ok, title, detail, eject)
        if not ok:
            self.panel.details_btn.setChecked(True)

    def _carry_tags(self, st: dict) -> None:
        """Each copy gets its original's tags; an original that went to the Trash loses its own."""
        placed, gone = st.get("placed") or [], st.get("trashed_paths") or []
        if not placed and not gone:
            return
        try:
            n = tag_store().carry(placed)
            tag_store().forget(gone)
        except OSError as e:
            self.panel.log.appendPlainText(f"   couldn't carry the tags over: {e}")
            return
        if n:
            self.panel.log.appendPlainText(f"   tags went along with {n:,} item{'s' if n != 1 else ''}")
        tags_changed()

    def stop_transfer(self) -> None:
        if self.current is None:
            return
        self.queue.clear()
        self.current.cancel()
        self.panel.detail.setText("Stopping after cleaning up the file in progress…")

    # -- eject
    def eject(self, path: str) -> None:
        if self.current is not None and str(engine.volume_root(self._dest)) == str(engine.volume_root(Path(path))):
            QMessageBox.information(self, "Eject", "Wait for the transfer to finish (or stop it) before ejecting.")
            return
        vol = str(engine.volume_root(Path(path)))
        for pane in (self.src, self.dst):
            if pane.location.startswith(vol) or (pane.is_virtual and pane.folder.startswith(vol)):
                pane.go(str(Path.home()))                   # also stops a search still reading the drive
        self.panel.show()
        self.panel.icon.setPixmap(glyph("eject", THEME.secondary, 22).pixmap(22, 22))
        self.panel.title.setText(f"Ejecting “{os.path.basename(vol)}”…")
        self.panel.detail.setText("Flushing everything to the drive first.")

        def work() -> None:
            os.sync()
            r = subprocess.run(["diskutil", "eject", vol] if IS_MAC else ["umount", vol],
                               capture_output=True, text=True)
            self.bridge.log.emit((r.stdout + r.stderr).strip())
            QTimer.singleShot(0, lambda: self._ejected(vol, r.returncode == 0, (r.stderr or r.stdout).strip()))

        threading.Thread(target=work, daemon=True).start()

    def _ejected(self, vol: str, ok: bool, msg: str) -> None:
        name = os.path.basename(vol)
        if ok:
            self.panel.finished(True, f"“{name}” was ejected", "It's safe to unplug the drive.", "")
        else:
            self.panel.finished(False, f"“{name}” couldn't be ejected",
                                (msg or "Something is still using it.") + " Close anything that has files open "
                                "on it and try again.", vol)
        self.sidebar.rebuild()

    # -- lifecycle
    def closeEvent(self, event) -> None:  # noqa: N802
        if self.current is not None:
            r = QMessageBox.question(self, "Safe Finder",
                                     "A transfer is still running. Stop it and quit? The file in progress is "
                                     "cleaned up; finished files stay on the drive.")
            if r != QMessageBox.StandardButton.Yes:
                event.ignore()
                return
            self.queue.clear()
            self.current.cancel()
            deadline = time.time() + 15
            while self.current is not None and time.time() < deadline:
                QApplication.processEvents()
                time.sleep(0.05)
        if self.caffeinate is not None:
            self.caffeinate.terminate()
        self.settings.setValue("geometry", self.saveGeometry())
        event.accept()


# ============================================================================ main


def apply_theme(app: QApplication, window: MainWindow | None = None) -> None:
    global THEME
    scheme = app.styleHints().colorScheme()
    dark = scheme == Qt.ColorScheme.Dark if scheme != Qt.ColorScheme.Unknown else \
        app.palette().color(QPalette.ColorRole.Window).lightness() < 128
    if os.environ.get("SAFE_FINDER_THEME") in ("dark", "light"):
        dark = os.environ["SAFE_FINDER_THEME"] == "dark"
    THEME = Theme(dark)
    app.setPalette(THEME.palette())
    app.setStyleSheet(THEME.stylesheet())
    if window is not None:
        window.restyle()


def main() -> None:
    ap = argparse.ArgumentParser(description="Safe Finder — move files onto the SSD safely.")
    ap.add_argument("--from", dest="src", help="folder to show on the left")
    ap.add_argument("--to", dest="dst", help="folder to show on the right (the SSD)")
    args, _ = ap.parse_known_args()        # launched as an app, Finder may add its own arguments

    # The SimpCity window's browser (Qt WebEngine) needs this set before the app exists.
    QApplication.setAttribute(Qt.ApplicationAttribute.AA_ShareOpenGLContexts)
    app = QApplication(sys.argv[:1])
    app.setApplicationName("Safe Finder")
    app.setApplicationDisplayName("Safe Finder")
    app.setStyle("Fusion")
    if not IS_MAC:
        f = app.font()
        f.setFamily("Inter")
        f.setPointSizeF(10)
        app.setFont(f)
    global THUMBS
    THUMBS = Thumbnails()
    apply_theme(app)
    win = MainWindow(args.src, args.dst)
    app.styleHints().colorSchemeChanged.connect(lambda _s: apply_theme(app, win))
    win.show()
    sys.exit(app.exec())


if __name__ == "__main__":
    main()
