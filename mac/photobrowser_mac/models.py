"""Qt models for the grid: a list model over `Entry` rows that asks the `Thumbnailer` for tiles
lazily (only rows the view actually paints), plus the sort/filter/search proxy behind the toolbar."""

from __future__ import annotations

from PySide6.QtCore import QAbstractListModel, QModelIndex, QSortFilterProxyModel, Qt

from .library import Entry
from .thumbnails import Thumbnailer

EntryRole = Qt.UserRole + 1
KindRole = Qt.UserRole + 2


class FileGridModel(QAbstractListModel):
    def __init__(self, thumbs: Thumbnailer, parent=None):
        super().__init__(parent)
        self.entries: list[Entry] = []
        self.thumbs = thumbs
        self.meta: dict[str, dict] = {}         # path → exiftool dict (filled by the window)
        self._row_by_path: dict[str, int] = {}
        thumbs.ready.connect(self._thumb_ready)

    # -- population
    def set_entries(self, entries: list[Entry]):
        self.beginResetModel()
        self.entries = list(entries)
        self._row_by_path = {e.path: i for i, e in enumerate(self.entries)}
        self.endResetModel()

    def replace_entry(self, old_path: str, new: Entry):
        row = self._row_by_path.pop(old_path, None)
        if row is None:
            return
        self.entries[row] = new
        self._row_by_path[new.path] = row
        if old_path in self.meta:
            self.meta[new.path] = self.meta.pop(old_path)
        idx = self.index(row)
        self.dataChanged.emit(idx, idx)

    def entry_at(self, row: int) -> Entry | None:
        return self.entries[row] if 0 <= row < len(self.entries) else None

    # -- QAbstractListModel
    def rowCount(self, parent=QModelIndex()):
        return 0 if parent.isValid() else len(self.entries)

    def data(self, index, role=Qt.DisplayRole):
        if not index.isValid():
            return None
        e = self.entries[index.row()]
        if role == Qt.DisplayRole:
            return e.name
        if role == EntryRole:
            return e
        if role == KindRole:
            return e.kind
        if role == Qt.DecorationRole:
            if e.is_dir:
                return None
            pm = self.thumbs.cached(e)
            if pm is None:
                self.thumbs.request(e)
            return pm
        if role == Qt.ToolTipRole:
            return e.path
        return None

    def flags(self, index):
        return Qt.ItemIsEnabled | Qt.ItemIsSelectable

    def _thumb_ready(self, path: str, _pm):
        row = self._row_by_path.get(path)
        if row is not None:
            idx = self.index(row)
            self.dataChanged.emit(idx, idx, [Qt.DecorationRole])


class GridProxy(QSortFilterProxyModel):
    """Search (name contains), kind filter (all / photos / videos), and sort by name / date / size.
    Folders always sort first, like the iOS grid."""

    SORT_NAME, SORT_DATE, SORT_SIZE = range(3)

    def __init__(self, parent=None):
        super().__init__(parent)
        self.search = ""
        self.kind = "all"
        self.sort_key = self.SORT_NAME
        self.descending = False
        self.setDynamicSortFilter(False)

    def apply(self, *, search=None, kind=None, sort_key=None, descending=None):
        if search is not None:
            self.search = search.strip().lower()
        if kind is not None:
            self.kind = kind
        if sort_key is not None:
            self.sort_key = sort_key
        if descending is not None:
            self.descending = descending
        self.invalidate()
        self.sort(0)

    def filterAcceptsRow(self, row, parent):
        e: Entry = self.sourceModel().entries[row]
        if self.search and self.search not in e.name.lower():
            return False
        if self.kind == "photos" and not (e.is_dir or e.kind == "image"):
            return False
        if self.kind == "videos" and not (e.is_dir or e.kind == "video"):
            return False
        return True

    def lessThan(self, left, right):
        a: Entry = self.sourceModel().entries[left.row()]
        b: Entry = self.sourceModel().entries[right.row()]
        if a.is_dir != b.is_dir:
            return a.is_dir                      # folders first, regardless of direction
        if self.sort_key == self.SORT_DATE:
            ka, kb = a.mtime, b.mtime
        elif self.sort_key == self.SORT_SIZE:
            ka, kb = a.size, b.size
        else:
            ka, kb = a.name.lower(), b.name.lower()
        if ka == kb:
            ka, kb = a.name.lower(), b.name.lower()
        return (ka > kb) if self.descending else (ka < kb)
