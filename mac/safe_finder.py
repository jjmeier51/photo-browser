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

Run:  double-click "Safe Finder.command" next to this file, or
      mac/.venv/bin/python mac/safe_finder.py [--from FOLDER] [--to FOLDER]
      — or build it into /Applications with "sh mac/build_safe_finder_app.sh" (see mac/README.md).
"""

from __future__ import annotations

import argparse
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
from collections import OrderedDict
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

try:
    from PySide6.QtCore import (QDateTime, QDir, QFileInfo, QFileSystemWatcher, QLocale, QMimeData, QModelIndex,
                                QObject, QPoint, QRect, QRectF, QRunnable, QSettings, QSize, QSortFilterProxyModel,
                                Qt, QThreadPool, QTimer, QUrl, Signal)
    from PySide6.QtGui import (QAction, QActionGroup, QColor, QDesktopServices, QFont, QFontMetrics, QIcon, QImage,
                               QImageReader, QKeySequence, QPainter, QPainterPath, QPalette, QPen, QPixmap,
                               QShortcut, QStandardItem, QStandardItemModel)
    from PySide6.QtWidgets import (QAbstractItemView, QApplication, QButtonGroup, QCheckBox, QComboBox, QDialog,
                                   QFileIconProvider, QFileSystemModel, QFrame, QHBoxLayout, QHeaderView,
                                   QInputDialog, QLabel, QLineEdit, QListView, QMainWindow, QMenu, QMessageBox,
                                   QPlainTextEdit, QProgressBar, QPushButton, QSizePolicy,
                                   QSlider, QSplitter, QStackedWidget, QStyle, QStyledItemDelegate,
                                   QStyleOptionViewItem, QToolButton, QTreeView, QTreeWidget,
                                   QTreeWidgetItem, QVBoxLayout, QWidget)
except ModuleNotFoundError:
    venv_python = HERE / ".venv" / "bin" / "python"
    if venv_python.exists() and Path(sys.executable).resolve() != venv_python.resolve():
        os.execv(str(venv_python), [str(venv_python), *sys.argv])
    sys.exit("Safe Finder needs PySide6. Double-click “Safe Finder.command” (it sets everything up), or run:\n"
             "  python3 -m venv mac/.venv && mac/.venv/bin/pip install -r mac/requirements.txt")

import safe_transfer as engine
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


# ============================================================================ thumbnails


class _ThumbSignals(QObject):
    done = Signal(str, QImage)


class _ThumbJob(QRunnable):
    def __init__(self, key: str, path: str, px: int, signals: _ThumbSignals) -> None:
        super().__init__()
        self.key, self.path, self.px, self.signals = key, path, px, signals
        self.setAutoDelete(True)

    def run(self) -> None:
        img = QImage()
        try:
            img = self._load()
        except Exception:  # noqa: BLE001 — a bad file just keeps its icon
            pass
        self.signals.done.emit(self.key, img)

    def _load(self) -> QImage:
        kind = kind_of(self.path)
        ext = os.path.splitext(self.path)[1].lower()
        if kind == "image" and ext not in RAW_EXT:
            if PIL_OK:
                try:
                    with Image.open(self.path) as im:
                        im.draft("RGB", (self.px * 2, self.px * 2))
                        im = ImageOps.exif_transpose(im)
                        im.thumbnail((self.px, self.px))
                        im = im.convert("RGBA")
                        data = im.tobytes("raw", "RGBA")
                        return QImage(data, im.width, im.height, im.width * 4, QImage.Format.Format_RGBA8888).copy()
                except Exception:  # noqa: BLE001
                    pass
            reader = QImageReader(self.path)
            reader.setAutoTransform(True)
            size = reader.size()
            if size.isValid():
                reader.setScaledSize(size.scaled(self.px, self.px, Qt.AspectRatioMode.KeepAspectRatio))
            img = reader.read()
            if not img.isNull():
                return img
        if IS_MAC and kind in ("image", "video") and shutil.which("qlmanage"):
            with tempfile.TemporaryDirectory() as td:
                subprocess.run(["qlmanage", "-t", "-s", str(self.px), "-o", td, self.path],
                               capture_output=True, timeout=30)
                made = [f for f in os.listdir(td) if f.endswith(".png")]
                if made:
                    return QImage(os.path.join(td, made[0]))
        return QImage()


class Thumbnails(QObject):
    """Async thumbnail cache (memory only). `get` returns a pixmap or None and requests it."""
    ready = Signal()

    def __init__(self) -> None:
        super().__init__()
        self._cache: OrderedDict[str, QPixmap | None] = OrderedDict()
        self._bytes = 0                                    # what the cached pixmaps hold, roughly
        self._pending: set[str] = set()
        self._pool = QThreadPool(self)
        self._pool.setMaxThreadCount(4)
        self._signals = _ThumbSignals()
        self._signals.done.connect(self._done, Qt.ConnectionType.QueuedConnection)
        self._tick = QTimer(self)
        self._tick.setSingleShot(True)
        self._tick.setInterval(60)
        self._tick.timeout.connect(self.ready.emit)

    def get(self, path: str, mtime: float, px: int) -> QPixmap | None:
        bucket = 128 if px <= 128 else 256 if px <= 256 else 384      # rendered at 2× for Retina
        key = f"{path}|{mtime}|{bucket}"
        if key in self._cache:
            self._cache.move_to_end(key)
            return self._cache[key]
        if key not in self._pending:
            self._pending.add(key)
            self._pool.start(_ThumbJob(key, path, bucket * 2, self._signals))
        return None

    def _done(self, key: str, img: QImage) -> None:
        self._pending.discard(key)
        pm = None if img.isNull() else QPixmap.fromImage(img)
        self._cache[key] = pm
        self._bytes += self._size(pm)
        while self._cache and (len(self._cache) > 3000 or self._bytes > 600 * 1024 * 1024):
            _k, old = self._cache.popitem(last=False)
            self._bytes -= self._size(old)
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
            self._draw_thumb(p, thumb, icon_rect, kind_of(path) == "video")
        else:
            icon = model.fileIcon(index)
            icon.paint(p, icon_rect.adjusted(2, 2, -2, -2))
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
    def _draw_thumb(p: QPainter, pm: QPixmap, rect: QRect, video: bool) -> None:
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
        super().paint(p, option, index)


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


def mac_roots() -> list[Path]:
    """What "This Mac" means to a search and to All Videos: the home folder, where files live (the
    system, apps and ~/Library hold nothing you'd move to the SSD). SAFE_FINDER_SEARCH_ROOTS=a:b
    overrides it (tests)."""
    env = os.environ.get("SAFE_FINDER_SEARCH_ROOTS")
    return [Path(p) for p in env.split(":") if p] if env else [Path.home()]


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
    "*.mov", "ext:mp4,mov") and a kind ("kind:video", or the Kind menu). All of it must match."""

    def __init__(self, text: str = "", kind: str = "") -> None:
        self.text = text.strip()
        self.words: list[str] = []
        self.exts: set[str] = set()
        self.menu_kind = kind if kind in KIND_EXT else ""      # the Kind menu's choice, as such
        self.kind = self.menu_kind                              # …which "kind:" in the text overrides
        for tok in self.text.split():
            low = tok.lower()
            if low.startswith("kind:"):
                if low[5:] in KIND_EXT:
                    self.kind = low[5:]
            elif low.startswith("ext:"):
                self.exts |= {"." + e.strip(". ") for e in low[4:].split(",") if e.strip(". ")}
            elif low.startswith("*.") and len(low) > 2:
                self.exts.add(low[1:])
            elif low.startswith(".") and len(low) > 1 and "." not in low[1:]:
                self.exts.add(low)
            else:
                self.words.append(low)

    def empty(self) -> bool:
        return not (self.words or self.exts or self.kind)

    def wants_folders(self) -> bool:
        """A search by name finds folders too; one by extension or kind is about files."""
        return bool(self.words) and not self.exts and not self.kind

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
        return " · ".join(bits)

    def spotlight(self) -> str:
        """The same search as a Spotlight (mdfind) query; what comes back is checked with `matches` too."""
        def quote(s: str) -> str:
            return s.replace("\\", "\\\\").replace('"', '\\"').replace("*", "\\*").replace("?", "\\?")
        parts = [f'kMDItemFSName == "*{quote(w)}*"cd' for w in self.words]
        exts = self.exts & KIND_EXT[self.kind] if (self.exts and self.kind) else self.exts or (KIND_EXT[self.kind] if self.kind else set())
        if exts:
            parts.append("(" + " || ".join(f'kMDItemFSName == "*{e}"c' for e in sorted(exts)) + ")")
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
        gone = [r for r in range(self.rowCount()) if not os.path.lexists(self.item(r).data(_R_PATH))]
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
        self.setDynamicSortFilter(True)

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
            return (group, 0 if is_dir else src.size(idx), nat)
        if key == "modified":
            return (group, src.lastModified(idx).toMSecsSinceEpoch(), nat)
        if key in ("created", "added"):
            created, added = file_times(src.filePath(idx))
            return (group, added if key == "added" else created, nat)
        return (group, nat)


# ============================================================================ pane


class Pane(QWidget):
    """One Finder window's worth: header (back/forward, title, sort, search, view toggle), the
    views, path bar and status bar. Besides folders it shows two kinds of collection in the same
    views: All Videos, and a search's results (`searches` remembers each run so back/forward can
    bring it up again)."""

    dropped = Signal(list, str)          # paths, target folder
    activated = Signal(object)           # this pane got focus/clicked
    location_changed = Signal(str)
    selection_changed = Signal()

    def __init__(self, role: str, settings: QSettings) -> None:
        super().__init__()
        self.role = role                 # "From" | "To"
        self.settings = settings
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
        self.scanner: FileScanner | None = None

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
        self.sort_btn = self._tool("sort", "Sort by", None, "Nav")
        self.sort_btn.setMenu(self._sort_menu())
        self.sort_btn.setPopupMode(QToolButton.ToolButtonPopupMode.InstantPopup)
        h.addWidget(self.sort_btn)
        self.new_folder_btn = self._tool("plus", "New Folder (⇧⌘N)", self.new_folder, "Nav")
        h.addWidget(self.new_folder_btn)
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
        self.grid.selectionModel().selectionChanged.connect(lambda *_: self.selection_changed.emit())
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
        return menu

    def restyle(self) -> None:
        for b in (self.back_btn, self.fwd_btn, self.sort_btn, self.new_folder_btn, self.grid_btn, self.list_btn):
            b.setIcon(glyph(b.property("glyph"), THEME.secondary if b.objectName() == "Nav" else THEME.text, 16))
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
                           ("Ctrl+2", lambda: self.set_mode("list")), ("Ctrl+Shift+N", self.new_folder)):
            sc = QShortcut(QKeySequence(keys), self)
            sc.setContext(ctx)
            sc.activated.connect(slot)

    def eventFilter(self, obj, event) -> bool:  # noqa: N802
        if obj is self.search and event.type() == event.Type.KeyPress and event.key() == Qt.Key.Key_Escape:
            self.search.clear()                      # and, if a search is up, back to the folder
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
        """A collection (All Videos, search results) rather than a folder."""
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

    def set_mode(self, mode: str) -> None:
        self.stack.setCurrentIndex(0 if mode == "grid" else 1)
        self.grid_btn.setChecked(mode == "grid")
        self.list_btn.setChecked(mode != "grid")
        for w in self.view_controls:
            w.setVisible(mode == "grid")
        self.settings.setValue(f"{self.role}/mode", mode)

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
        if path == VIDEOS:
            self._show_results(VIDEOS, record)
            return
        if path.startswith(SEARCH):
            if path in self.searches:
                self._show_results(path, record)
            return
        path = os.path.abspath(path)
        if not os.path.isdir(path):
            return
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
        idx = self.model.mapFromSource(self.fs.setRootPath(path))
        self.grid.setRootIndex(idx)
        self.list.setRootIndex(idx)
        self.grid.clearSelection()
        self.grid.scrollToTop()
        self.list.scrollToTop()
        name = os.path.basename(path.rstrip(os.sep))
        if engine.volume_root(Path(path)) == Path(path):
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
        self.grid.clearSelection()
        self.grid.scrollToTop()
        self.list.scrollToTop()
        self.new_folder_btn.setEnabled(False)
        if loc == VIDEOS:
            self.title.setText("All Videos")
            self.title.setToolTip("Every video in your home folder")
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
        """Search for what the field says, in the chosen scope, and show the results here."""
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
            videos = self.location == VIDEOS
            b.setText("All Videos" if videos else "Search results")
            b.setToolButtonStyle(Qt.ToolButtonStyle.ToolButtonTextBesideIcon)
            b.setIcon(glyph("film" if videos else "search", THEME.accent, 14))
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
        if not self.location:
            return
        if self.is_virtual:
            n = self.results.rowCount()
            sel = len(self.selected_paths())
            what = "video" if self.location == VIDEOS else "result"
            text = f"{sel} of {n} selected" if sel else f"{n} {what}{'s' if n != 1 else ''}"
            if self.scanner is not None:
                text += " so far — still looking…"
            self.status.setText(text)
            self.fs_chip.setVisible(False)
            return
        n = self.fs.rowCount(self.fs.index(self.location))
        free = engine.free_space(Path(self.location))
        sel = len(self.selected_paths())
        text = f"{sel} of {n} selected" if sel else f"{n} item{'s' if n != 1 else ''}"
        self.status.setText(f"{text}, {human(free)} available")
        fs = MOUNTS.get(str(engine.volume_root(Path(self.location))), "")
        self.fs_chip.setText(FS_NAMES.get(fs, fs))
        self.fs_chip.setVisible(bool(fs))

    # -- selection / actions
    def selected_paths(self) -> list[str]:
        rows = self.grid.selectionModel().selectedIndexes()
        seen, out = set(), []
        for idx in rows:
            path = self.model.filePath(idx.siblingAtColumn(0))
            if path not in seen:
                seen.add(path)
                out.append(path)
        return out

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
            menu.addSeparator()
            win = self.window()
            if isinstance(win, MainWindow) and self is win.src:
                menu.addAction(win.copy_btn.text(), lambda: win.transfer_selection(False))
                menu.addAction(win.move_btn.text(), lambda: win.transfer_selection(True))
        if self.location == VIDEOS:
            menu.addAction("Look for Videos Again", lambda: self.go(VIDEOS))
        elif self.is_search:
            menu.addAction("Search Again", lambda: self.go(self.location))
        else:
            menu.addAction("New Folder", self.new_folder)
        menu.exec(view.viewport().mapToGlobal(pos))


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
        if option.state & QStyle.StateFlag.State_Selected:
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
        width = r.width() - 36 - (28 if eject else 6)
        p.setPen(QColor(THEME.text))
        text = QFontMetrics(option.font).elidedText(index.data(Qt.ItemDataRole.DisplayRole), Qt.TextElideMode.ElideRight, width)
        p.drawText(QRect(r.x() + 34, r.y(), width, r.height()), Qt.AlignmentFlag.AlignVCenter, text)
        if eject:
            glyph("eject", THEME.secondary, 14).paint(p, QRect(r.right() - 24, r.center().y() - 7, 14, 14))
        p.restore()


class SidebarTree(QTreeWidget):
    eject = Signal(str)

    def mousePressEvent(self, event) -> None:  # noqa: N802
        idx = self.indexAt(event.position().toPoint())
        if idx.isValid() and idx.data(EJECT_ROLE) and event.position().x() >= self.visualRect(idx).right() - 30:
            self.eject.emit(idx.data(PATH_ROLE))
            event.accept()
            return
        super().mousePressEvent(event)


class Sidebar(QWidget):
    navigate = Signal(str)
    eject = Signal(str)

    def __init__(self) -> None:
        super().__init__(objectName="Sidebar")
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
        self.tree.expandAll()
        if selected:
            self.select_path(selected[0])

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
        if path:
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
        self.sidebar.eject.connect(self.eject)
        self.src = Pane("From", self.settings)
        self.dst = Pane("To", self.settings)
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
        self.bridge.log.connect(self.panel.log.appendPlainText)
        self.bridge.progress.connect(self._progress)
        self.bridge.finished.connect(self._finished)
        THUMBS.ready.connect(lambda: (self.src.grid.viewport().update(), self.dst.grid.viewport().update()))

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
        if path == VIDEOS:                     # a collection of the Mac's videos — always the From side
            self.set_active(self.src)
            self.src.go(VIDEOS)
        else:
            self.active_pane.go(path)

    def set_active(self, pane: Pane) -> None:
        for p in (self.src, self.dst):
            p.set_active(p is pane)
        self.sidebar.select_path(pane.location)

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
        paths = self.src.selected_paths()
        enabled = bool(paths) and bool(dest)
        self.copy_btn.setEnabled(enabled)
        self.move_btn.setEnabled(enabled)
        if not paths:
            self.summary.setText("Select files or folders on the left, then Move or Copy — or drag them onto the right.")
            return
        if not dest:
            self.summary.setText("Open a folder on the right to move or copy into — the right pane is showing search results.")
            return
        files = [p for p in paths if os.path.isfile(p)]
        folders = len(paths) - len(files)
        size = sum(os.path.getsize(p) for p in files)
        bits = [f"{len(paths)} item{'s' if len(paths) != 1 else ''} selected"]
        if files:
            bits.append(f"{len(files)} file{'s' if len(files) != 1 else ''} · {human(size)}")
        if folders:
            bits.append(f"{folders} folder{'s' if folders != 1 else ''}")
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
            if self.current is None:
                self._start_next()
            else:
                self.panel.running(self.panel.title.text().split("   ·   ")[0], len(self.queue))

        sheet.accepted.connect(accepted)
        sheet.open()

    def _start_next(self) -> None:
        if not self.queue:
            return
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

    def _progress(self, d: dict) -> None:
        now = time.time()
        t_last, b_last = self._last
        if now - t_last >= 0.5:
            inst = (d["done_bytes"] - b_last) / max(now - t_last, 1e-3)
            self._speed = inst if self._speed == 0 else 0.7 * self._speed + 0.3 * inst
            self._last = (now, d["done_bytes"])
        self.panel.progress(d["done_bytes"], d.get("total_bytes", 0), d["done_files"], d.get("total_files", 0),
                            d.get("name", ""), d.get("phase", ""), self._speed)

    def _finished(self, st: dict) -> None:
        self.current = None
        self.src.refresh_results()
        self.dst.refresh_results()
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
        if len(self._batch) > 1:
            bad = sum(1 for r in self._batch if not r[0])
            ok = bad == 0
            title = (f"All {len(self._batch)} transfers finished" if ok
                     else f"{len(self._batch)} transfers finished — {bad} need{'s' if bad == 1 else ''} a look")
            detail = "   ·   ".join(r[1] for r in self._batch)
        self.panel.finished(ok, title, detail, eject)
        if not ok:
            self.panel.details_btn.setChecked(True)

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
