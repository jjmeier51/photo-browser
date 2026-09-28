"""Qt models for the grid: a list model over `Entry` rows that asks the `Thumbnailer` for tiles
lazily (only rows the view actually paints), plus the sort/filter/search proxy behind the toolbar."""

from __future__ import annotations

from PySide6.QtCore import QAbstractListModel, QModelIndex, QSortFilterProxyModel, Qt

from .exiftool import capture_date
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
        self._capture_ts: dict[str, float] = {}  # path → capture date as a timestamp (from meta)
        self._row_by_path: dict[str, int] = {}
        thumbs.ready.connect(self._thumb_ready)

    # -- dates
    def capture_ts(self, e: Entry) -> float:
        """The capture date to sort by: EXIF/QuickTime from the metadata read, else the modified
        date — exactly the iOS grid's `captureDates[url] ?? modified`."""
        ts = self._capture_ts.get(e.path)
        if ts is None:
            d = capture_date(self.meta.get(e.path, {})) if e.path in self.meta else None
            ts = d.timestamp() if d else e.mtime
            self._capture_ts[e.path] = ts
        return ts

    def update_meta(self, meta: dict[str, dict]):
        self.meta.update(meta)
        for p in meta:
            self._capture_ts.pop(p, None)

    def forget_meta(self, path: str):
        self.meta.pop(path, None)
        self._capture_ts.pop(path, None)

    # -- population
    def set_entries(self, entries: list[Entry]):
        self.beginResetModel()
        self.entries = list(entries)
        self._row_by_path = {e.path: i for i, e in enumerate(self.entries)}
        self._capture_ts = {}
        self.endResetModel()

    def replace_entry(self, old_path: str, new: Entry):
        row = self._row_by_path.pop(old_path, None)
        if row is None:
            return
        self.entries[row] = new
        self._row_by_path[new.path] = row
        if old_path in self.meta:
            self.meta[new.path] = self.meta.pop(old_path)
        self._capture_ts.pop(old_path, None)
        self._capture_ts.pop(new.path, None)
        idx = self.index(row)
        self.dataChanged.emit(idx, idx)

    def row_for(self, path: str) -> int | None:
        return self._row_by_path.get(path)

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
    """Search (name contains), kind filter (all / photos / videos), and sorting.

    Sort keys mirror the iOS app: the default is its "smart" order — folders A–Z first, then media
    by **capture date** newest-first (EXIF/QuickTime, falling back to the modified date), ties by
    name. Modified / Created / Name / Size are the alternatives; folders always come first."""

    SORT_CAPTURE, SORT_MODIFIED, SORT_CREATED, SORT_NAME, SORT_SIZE = range(5)
    LABELS = ["Capture Date", "Modified Date", "Created Date", "Name", "Size"]
    DATE_KEYS = (SORT_CAPTURE, SORT_MODIFIED, SORT_CREATED)

    def __init__(self, parent=None):
        super().__init__(parent)
        self.search = ""
        self.kind = "all"
        self.sort_key = self.SORT_CAPTURE
        self.descending = True                   # newest first, like iOS
        self.setDynamicSortFilter(False)

    @classmethod
    def default_descending(cls, key: int) -> bool:
        """Dates read newest-first by default; names and sizes ascending."""
        return key in cls.DATE_KEYS

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
        src: FileGridModel = self.sourceModel()
        a: Entry = src.entries[left.row()]
        b: Entry = src.entries[right.row()]
        if a.is_dir != b.is_dir:
            return a.is_dir                      # folders first, regardless of direction
        if a.is_dir and self.sort_key in (self.SORT_CAPTURE, self.SORT_NAME, self.SORT_SIZE):
            # Folders have no capture date or size to speak of — they stay alphabetical (iOS smart).
            na, nb = a.name.lower(), b.name.lower()
            return (na > nb) if (self.descending and self.sort_key == self.SORT_NAME) else (na < nb)
        if self.sort_key == self.SORT_CAPTURE:
            ka, kb = src.capture_ts(a), src.capture_ts(b)
        elif self.sort_key == self.SORT_MODIFIED:
            ka, kb = a.mtime, b.mtime
        elif self.sort_key == self.SORT_CREATED:
            ka, kb = a.ctime, b.ctime
        elif self.sort_key == self.SORT_SIZE:
            ka, kb = a.size, b.size
        else:
            ka, kb = a.name.lower(), b.name.lower()
        if ka == kb:
            # Ties (same second, same size) fall back to name A–Z whichever way the sort runs.
            return a.name.lower() < b.name.lower()
        return (ka > kb) if self.descending else (ka < kb)
