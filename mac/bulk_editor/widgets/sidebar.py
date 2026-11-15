"""Left panel: the connected drive (a volume picker over /Volumes, or any folder) and its folder
tree. Selecting a folder in the tree is what drives the grid."""

from __future__ import annotations

import os

from PySide6.QtCore import QDir, Qt, Signal, QModelIndex
from PySide6.QtWidgets import (QComboBox, QFileDialog, QHBoxLayout, QLabel, QPushButton, QTreeView,
                               QVBoxLayout, QWidget, QToolButton, QFileSystemModel, QHeaderView)

from ..library import list_volumes


class Sidebar(QWidget):
    folder_selected = Signal(str)
    root_changed = Signal(str)

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setObjectName("Sidebar")
        self.setMinimumWidth(220)
        self.root: str | None = None

        title = QLabel("Photo Browser"); title.setObjectName("Title")
        sub = QLabel("Metadata editor for your drive"); sub.setObjectName("Tertiary")

        self.volume = QComboBox()
        self.volume.setToolTip("Mounted drives")
        self.volume.activated.connect(self._pick_volume)
        refresh = QToolButton(); refresh.setText("↻"); refresh.setToolTip("Rescan drives")
        refresh.clicked.connect(self.refresh_volumes)
        browse = QPushButton("Folder…"); browse.setToolTip("Browse any folder")
        browse.clicked.connect(self._browse)

        row = QHBoxLayout(); row.setSpacing(6)
        row.addWidget(self.volume, 1); row.addWidget(refresh); row.addWidget(browse)

        heading = QLabel("FOLDERS"); heading.setObjectName("Heading")

        self.fs = QFileSystemModel(self)
        self.fs.setFilter(QDir.Dirs | QDir.NoDotAndDotDot)
        self.fs.setReadOnly(True)
        self.tree = QTreeView()
        self.tree.setModel(self.fs)
        for c in (1, 2, 3):
            self.tree.hideColumn(c)
        self.tree.setHeaderHidden(True)
        self.tree.setAnimated(True)
        self.tree.setIndentation(14)
        self.tree.setUniformRowHeights(True)
        self.tree.header().setSectionResizeMode(0, QHeaderView.Stretch)
        self.tree.selectionModel().currentChanged.connect(self._current_changed)

        self.status = QLabel(""); self.status.setObjectName("Tertiary"); self.status.setWordWrap(True)

        lay = QVBoxLayout(self)
        lay.setContentsMargins(14, 14, 14, 14); lay.setSpacing(8)
        lay.addWidget(title); lay.addWidget(sub)
        lay.addSpacing(6)
        lay.addLayout(row)
        lay.addSpacing(8)
        lay.addWidget(heading)
        lay.addWidget(self.tree, 1)
        lay.addWidget(self.status)
        self.refresh_volumes()

    # -- volumes
    def refresh_volumes(self):
        current = self.volume.currentData()
        self.volume.blockSignals(True)
        self.volume.clear()
        self.volume.addItem("Choose a drive…", None)
        for v in list_volumes():
            self.volume.addItem(("⏏ " if v.removable else "") + v.name, v.path)
        if current:
            i = self.volume.findData(current)
            if i >= 0:
                self.volume.setCurrentIndex(i)
        self.volume.blockSignals(False)

    def _pick_volume(self, _i):
        path = self.volume.currentData()
        if path:
            self.set_root(path)

    def _browse(self):
        start = self.root or os.path.expanduser("~")
        d = QFileDialog.getExistingDirectory(self, "Choose a folder to browse", start)
        if d:
            self.set_root(d)

    def set_root(self, path: str):
        self.root = path
        idx = self.fs.setRootPath(path)
        self.tree.setRootIndex(idx)
        i = self.volume.findData(path)
        if i < 0:
            self.volume.addItem(os.path.basename(path.rstrip("/")) or path, path)
            i = self.volume.count() - 1
        self.volume.blockSignals(True); self.volume.setCurrentIndex(i); self.volume.blockSignals(False)
        self.status.setText(path)
        self.root_changed.emit(path)
        self.folder_selected.emit(path)

    # -- tree
    def _current_changed(self, current: QModelIndex, _prev):
        if current.isValid():
            self.folder_selected.emit(self.fs.filePath(current))

    def select_folder(self, path: str):
        """Select `path` in the tree (expanding to it) without re-emitting if it's already current."""
        idx = self.fs.index(path)
        if idx.isValid():
            self.tree.setExpanded(idx, True)
            if self.tree.currentIndex() != idx:
                self.tree.setCurrentIndex(idx)
            self.tree.scrollTo(idx)
