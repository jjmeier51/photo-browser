"""The window: sidebar (drive + folder tree) · toolbar + tile grid · inspector, with progress pills
over the grid. Owns the models, the ExifTool wrapper, the metadata cache and every write path
(single-file Save from the inspector, and the three bulk editors), all executed off the main thread.
"""

from __future__ import annotations

import os
import sys
from datetime import datetime

from PySide6.QtCore import QSettings, Qt, QTimer, QItemSelection
from PySide6.QtGui import QAction, QDesktopServices, QKeySequence
from PySide6.QtWidgets import (QApplication, QComboBox, QDialog, QHBoxLayout, QLabel, QLineEdit, QMainWindow, QMessageBox,
                               QPushButton, QSlider, QSplitter, QVBoxLayout, QWidget, QToolButton)
from PySide6.QtCore import QUrl

from . import APP_NAME, __version__
from .exiftool import ExifTool, FIELD_BY_KEY, date_tags_for, install_hint, DATE_WRITE_TAGS, VIDEO_DATE_WRITE_TAGS, is_video
from .library import Entry, scan, unique_path
from .models import FileGridModel, GridProxy, EntryRole
from .theme import STYLESHEET
from .thumbnails import Thumbnailer
from .widgets.bulk_dialogs import DatesDialog, MetadataDialog, RenameDialog
from .widgets.grid import GridView
from .widgets.inspector import Inspector
from .widgets.pills import PillHost
from .widgets.sidebar import Sidebar
from .workers import run_job


class MainWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle(APP_NAME)
        self.resize(1380, 860)
        self.settings = QSettings("PhotoBrowser", "PhotoBrowserMac")
        self.exif = ExifTool()
        self.thumbs = Thumbnailer(self)
        self.model = FileGridModel(self.thumbs, self)
        self.proxy = GridProxy(self); self.proxy.setSourceModel(self.model)
        self.folder: str | None = None
        self._meta_job_token = 0

        # ---- sidebar
        self.sidebar = Sidebar()
        self.sidebar.folder_selected.connect(self.open_folder)
        self.sidebar.root_changed.connect(lambda p: self.settings.setValue("root", p))

        # ---- centre: toolbar + grid
        centre = QWidget(); cl = QVBoxLayout(centre); cl.setContentsMargins(0, 0, 0, 0); cl.setSpacing(8)
        self.grid = GridView()
        self.grid.setModel(self.proxy)
        self.grid.activated_entry.connect(self._activate)
        self.grid.selectionModel().selectionChanged.connect(self._selection_changed)
        self.toolbar = self._build_toolbar()
        cl.addWidget(self.toolbar); cl.addWidget(self.grid, 1)
        self.pills = PillHost(self.grid)

        # ---- inspector
        self.inspector = Inspector()
        self.inspector.save_requested.connect(self._save_single)
        self.inspector.bulk_rename.connect(self.bulk_rename)
        self.inspector.bulk_dates.connect(self.bulk_dates)
        self.inspector.bulk_metadata.connect(self.bulk_metadata)
        self.thumbs.ready.connect(self.inspector.set_preview_pixmap)

        split = QSplitter(Qt.Horizontal)
        split.addWidget(self.sidebar); split.addWidget(centre); split.addWidget(self.inspector)
        split.setStretchFactor(0, 0); split.setStretchFactor(1, 1); split.setStretchFactor(2, 0)
        split.setSizes([250, 780, 350])
        split.setChildrenCollapsible(False)
        root = QWidget(); self.root_layout = QVBoxLayout(root); self.root_layout.setContentsMargins(12, 8, 12, 12); self.root_layout.setSpacing(8)
        self.root_layout.addWidget(split, 1)
        self.setCentralWidget(root)
        self._build_menu()
        self.statusBar().showMessage("Connect a drive to begin")

        if not self.exif.available:
            self._show_banner("ExifTool isn't installed — browsing works, but metadata can't be read or written. " + install_hint())

        last = self.settings.value("root")
        if last and os.path.isdir(str(last)):
            QTimer.singleShot(0, lambda: self.sidebar.set_root(str(last)))

    # ---- chrome ------------------------------------------------------------------------------------

    def _build_toolbar(self) -> QWidget:
        bar = QWidget(); bar.setObjectName("Toolbar")
        lay = QHBoxLayout(bar); lay.setContentsMargins(12, 8, 12, 8); lay.setSpacing(10)
        self.search = QLineEdit(); self.search.setPlaceholderText("Search this folder"); self.search.setClearButtonEnabled(True)
        self.search.setMinimumWidth(170)
        self.search.textChanged.connect(lambda t: self.proxy.apply(search=t))
        self.sort = QComboBox(); self.sort.addItems(["Name", "Date", "Size"])
        self.sort.currentIndexChanged.connect(lambda i: self.proxy.apply(sort_key=i))
        self.desc = QToolButton(); self.desc.setText("↓"); self.desc.setCheckable(True); self.desc.setToolTip("Reverse order")
        self.desc.toggled.connect(lambda b: self.proxy.apply(descending=b))
        self.kind = QComboBox(); self.kind.addItems(["All", "Photos", "Videos"])
        self.kind.currentIndexChanged.connect(lambda i: self.proxy.apply(kind=["all", "photos", "videos"][i]))
        self.size = QSlider(Qt.Horizontal); self.size.setRange(96, 320); self.size.setValue(int(self.settings.value("tile", 160)))
        self.size.setFixedWidth(120); self.size.setToolTip("Thumbnail size")
        self.size.valueChanged.connect(self._tile_size)
        self.count = QLabel(""); self.count.setObjectName("Secondary")
        self.sel_all = QPushButton("Select All"); self.sel_all.clicked.connect(self.grid.selectAll)
        b_rename = QPushButton("Rename…"); b_rename.clicked.connect(self.bulk_rename)
        b_dates = QPushButton("Dates…"); b_dates.clicked.connect(self.bulk_dates)
        b_meta = QPushButton("Metadata…"); b_meta.clicked.connect(self.bulk_metadata)
        self.bulk_buttons = [b_rename, b_dates, b_meta]
        lay.addWidget(self.search, 1)
        lay.addWidget(QLabel("Sort")); lay.addWidget(self.sort); lay.addWidget(self.desc)
        lay.addWidget(self.kind)
        lay.addWidget(self.size)
        lay.addWidget(self.count)
        lay.addWidget(self.sel_all)
        for b in self.bulk_buttons:
            lay.addWidget(b)
        QTimer.singleShot(0, lambda: self._tile_size(self.size.value()))
        return bar

    def _build_menu(self):
        mb = self.menuBar()
        file_m = mb.addMenu("File")
        a = QAction("Choose Drive or Folder…", self); a.setShortcut(QKeySequence.Open); a.triggered.connect(self.sidebar._browse); file_m.addAction(a)
        a = QAction("Refresh", self); a.setShortcut(QKeySequence.Refresh); a.triggered.connect(self.refresh); file_m.addAction(a)
        file_m.addSeparator()
        a = QAction("Reveal in Finder", self); a.setShortcut("Ctrl+Shift+R"); a.triggered.connect(self._reveal); file_m.addAction(a)
        edit_m = mb.addMenu("Edit")
        a = QAction("Select All", self); a.setShortcut(QKeySequence.SelectAll); a.triggered.connect(self.grid.selectAll); edit_m.addAction(a)
        edit_m.addSeparator()
        a = QAction("Bulk Rename…", self); a.setShortcut("Ctrl+Shift+N"); a.triggered.connect(self.bulk_rename); edit_m.addAction(a)
        a = QAction("Bulk Dates…", self); a.setShortcut("Ctrl+Shift+D"); a.triggered.connect(self.bulk_dates); edit_m.addAction(a)
        a = QAction("Bulk Metadata & Captions…", self); a.setShortcut("Ctrl+Shift+M"); a.triggered.connect(self.bulk_metadata); edit_m.addAction(a)
        help_m = mb.addMenu("Help")
        a = QAction("About", self); a.triggered.connect(self._about); help_m.addAction(a)

    def _show_banner(self, text: str):
        banner = QWidget(); banner.setObjectName("Banner")
        l = QHBoxLayout(banner); l.setContentsMargins(12, 8, 12, 8)
        lbl = QLabel(text); lbl.setWordWrap(True); l.addWidget(lbl, 1)
        close = QToolButton(); close.setText("✕"); close.clicked.connect(banner.deleteLater); l.addWidget(close)
        self.root_layout.insertWidget(0, banner)

    def _about(self):
        QMessageBox.about(self, APP_NAME, f"{APP_NAME} for Mac {__version__}\n\nBrowse a drive and bulk-edit EXIF, dates, filenames and captions.\n"
                                         f"ExifTool: {self.exif.version() or 'not found'}")

    def _tile_size(self, px: int):
        self.grid.set_tile_size(px)
        self.settings.setValue("tile", px)

    # ---- folders -----------------------------------------------------------------------------------

    def open_folder(self, path: str):
        if not path or path == self.folder:
            return
        self.folder = path
        self.setWindowTitle(f"{os.path.basename(path.rstrip('/')) or path} — {APP_NAME}")
        self.refresh()
        self.sidebar.select_folder(path)

    def refresh(self):
        if not self.folder:
            return
        folder = self.folder
        self.statusBar().showMessage(f"Reading {folder}…")

        def work(progress):
            return scan(folder)

        def done(entries):
            if folder != self.folder:
                return
            self.model.meta = {}
            self.model.set_entries(entries)
            self.proxy.apply()
            files = [e for e in entries if not e.is_dir]
            folders = len(entries) - len(files)
            self.count.setText(f"{len(files)} items" + (f" · {folders} folders" if folders else ""))
            self.statusBar().showMessage(folder)
            self._selection_changed()
            self._load_metadata([e.path for e in files])

        run_job(work, on_finished=done, on_failed=lambda tb: self.pills.toast("Couldn't read the folder"))

    def _load_metadata(self, paths: list[str]):
        if not self.exif.available or not paths:
            return
        self._meta_job_token += 1
        token = self._meta_job_token
        pill = self.pills.begin("meta", "Reading metadata")
        pill.set_progress(0, len(paths), f"{len(paths)} files")
        exif = self.exif

        def work(progress):
            out = {}
            step = 200
            for i in range(0, len(paths), step):
                out.update(exif.read(paths[i:i + step]))
                progress(min(i + step, len(paths)), len(paths), "")
            return out

        def done(meta):
            self.pills.end("meta")
            if token != self._meta_job_token:
                return
            self.model.meta.update(meta)
            self.grid.viewport().update()
            self._selection_changed()

        run_job(work, on_finished=done, on_failed=lambda tb: self.pills.end("meta"),
                on_progress=lambda d, t, m: self.pills.update("meta", d, t, f"{d} of {t}"))

    def _activate(self, e: Entry):
        if e.is_dir:
            self.open_folder(e.path)
        else:
            QDesktopServices.openUrl(QUrl.fromLocalFile(e.path))

    def _reveal(self):
        sel = self.grid.selected_entries()
        target = sel[0].path if sel else self.folder
        if not target:
            return
        if sys.platform == "darwin":
            import subprocess
            subprocess.Popen(["open", "-R", target])
        else:
            QDesktopServices.openUrl(QUrl.fromLocalFile(os.path.dirname(target)))

    # ---- selection ---------------------------------------------------------------------------------

    def _selection_changed(self, *_):
        sel = self.grid.selected_entries()
        files = [e for e in sel if not e.is_dir]
        pm = self.thumbs.cached(files[0]) if len(files) == 1 else None
        self.inspector.set_selection(files, self.model.meta, pm)
        for b in self.bulk_buttons:
            b.setEnabled(bool(files))
        if files:
            self.statusBar().showMessage(f"{len(files)} selected")
        elif self.folder:
            self.statusBar().showMessage(self.folder)

    def _selected_files(self) -> list[Entry]:
        return [e for e in self.grid.selected_entries() if not e.is_dir]

    # ---- writes ------------------------------------------------------------------------------------

    def _require_exiftool(self) -> bool:
        if self.exif.available:
            return True
        QMessageBox.warning(self, "ExifTool needed", "Editing metadata needs ExifTool.\n\n" + install_hint())
        return False

    def _rename_files(self, plan: list[tuple[str, str]]) -> tuple[int, list[str], list[tuple[str, Entry]]]:
        done, errors, replaced = 0, [], []
        for old, new_name in plan:
            folder = os.path.dirname(old)
            new = os.path.join(folder, new_name)
            try:
                if os.path.exists(new) and os.path.normcase(new) != os.path.normcase(old):
                    raise FileExistsError(new_name)
                os.rename(old, new)
                st = os.stat(new)
                replaced.append((old, Entry(path=new, name=new_name, is_dir=False, size=st.st_size, mtime=st.st_mtime)))
                done += 1
            except OSError as e:
                errors.append(f"{os.path.basename(old)}: {e}")
        return done, errors, replaced

    def _after_write(self, changed_paths: list[str], renamed: list[tuple[str, Entry]] | None = None):
        """Refresh the rows that changed: re-stat (mtime/size → new thumb key) and re-read metadata."""
        renamed = renamed or []
        for old, new in renamed:
            self.model.replace_entry(old, new)
        paths = []
        for p in changed_paths:
            row = self.model._row_by_path.get(p)
            if row is None:
                continue
            e = self.model.entries[row]
            try:
                st = os.stat(p)
            except OSError:
                continue
            self.model.replace_entry(p, Entry(path=p, name=e.name, is_dir=False, size=st.st_size, mtime=st.st_mtime))
            paths.append(p)
        paths += [n.path for _, n in renamed]
        for p in paths:
            self.model.meta.pop(p, None)
        self._load_metadata(paths)
        self.grid.viewport().update()

    def _report(self, what: str, done: int, errors: list[str]):
        if errors:
            QMessageBox.warning(self, what, f"{done} done, {len(errors)} failed:\n\n" + "\n".join(errors[:12]) + ("\n…" if len(errors) > 12 else ""))
        else:
            self.pills.toast(f"{what}: {done} file{'s' if done != 1 else ''} updated")

    def _save_single(self, req: dict):
        path = req["path"]
        tags: dict[str, str | None] = {}
        for key, value in req["fields"].items():
            for t in FIELD_BY_KEY[key].write:
                tags[t] = value or None
        meta = self.model.meta.get(path)
        if req.get("date"):
            tags.update(date_tags_for(path, meta, req["date"], file_dates=True))
        elif req.get("clear_date"):
            tags.update({t: None for t in DATE_WRITE_TAGS})
            if is_video(meta, path):
                tags.update({t: None for t in VIDEO_DATE_WRITE_TAGS})
        if tags and not self._require_exiftool():
            return
        rename = req.get("rename")
        if not tags and not rename:
            self.pills.toast("Nothing changed")
            return
        pill = self.pills.begin("save", "Saving"); pill.set_progress(0, 0, os.path.basename(path))
        exif = self.exif

        def work(progress):
            done, errors = (exif.write([path], tags) if tags else (0, []))
            if tags and done == 0 and not errors:
                done = 1
            renamed = []
            if rename and not errors:
                n, errs, renamed = self._rename_files([(path, rename)])
                errors += errs
            return done, errors, renamed

        def finished(result):
            self.pills.end("save")
            done, errors, renamed = result
            self._after_write([path] if not renamed else [], renamed)
            self._report("Save", 1 if (done or renamed) and not errors else done, errors)

        run_job(work, on_finished=finished, on_failed=lambda tb: (self.pills.end("save"), QMessageBox.critical(self, "Save failed", tb)))

    def bulk_rename(self):
        files = self._selected_files()
        if not files:
            return
        dlg = RenameDialog(files, self.model.meta, self)
        if dlg.exec() != QDialog.Accepted or not dlg.plan:
            return
        plan = dlg.plan
        pill = self.pills.begin("bulk", "Renaming"); pill.set_progress(0, len(plan))

        def work(progress):
            return self._rename_files(plan)

        def finished(result):
            self.pills.end("bulk")
            done, errors, renamed = result
            self._after_write([], renamed)
            self._report("Rename", done, errors)

        run_job(work, on_finished=finished, on_failed=lambda tb: (self.pills.end("bulk"), QMessageBox.critical(self, "Rename failed", tb)))

    def bulk_dates(self):
        files = self._selected_files()
        if not files or not self._require_exiftool():
            return
        dlg = DatesDialog(files, self.model.meta, self)
        if dlg.exec() != QDialog.Accepted or not dlg.plan or not dlg.plan["dates"]:
            return
        dates: dict[str, datetime] = dlg.plan["dates"]
        file_dates = dlg.plan["file_dates"]
        meta = self.model.meta
        per_file = {p: date_tags_for(p, meta.get(p), d, file_dates) for p, d in dates.items()}
        self._run_per_file("Dates", per_file)

    def bulk_metadata(self):
        files = self._selected_files()
        if not files or not self._require_exiftool():
            return
        dlg = MetadataDialog(files, self.model.meta, self)
        if dlg.exec() != QDialog.Accepted or not dlg.plan:
            return
        tags = dlg.plan["tags"]; per_file = dlg.plan["per_file"]
        paths = [e.path for e in files]
        pill = self.pills.begin("bulk", "Writing metadata"); pill.set_progress(0, len(paths))
        exif = self.exif

        def work(progress):
            done, errors = 0, []
            if tags:
                done, errors = exif.write(paths, tags)
                if done == 0 and not errors:
                    done = len(paths)
            if per_file:
                d2, e2 = exif.write_each(per_file, progress=lambda i, t: progress(i, t, ""))
                done = max(done, d2); errors += e2
            return done, errors

        def finished(result):
            self.pills.end("bulk")
            done, errors = result
            self._after_write(paths)
            self._report("Metadata", done, errors)

        run_job(work, on_finished=finished, on_failed=lambda tb: (self.pills.end("bulk"), QMessageBox.critical(self, "Write failed", tb)),
                on_progress=lambda d, t, m: self.pills.update("bulk", d, t, f"{d} of {t}"))

    def _run_per_file(self, what: str, per_file: dict[str, dict[str, str | None]]):
        paths = list(per_file)
        pill = self.pills.begin("bulk", what); pill.set_progress(0, len(paths))
        exif = self.exif

        def work(progress):
            return exif.write_each(per_file, progress=lambda i, t: progress(i, t, ""))

        def finished(result):
            self.pills.end("bulk")
            done, errors = result
            if done == 0 and not errors:
                done = len(paths)
            self._after_write(paths)
            self._report(what, done, errors)

        run_job(work, on_finished=finished, on_failed=lambda tb: (self.pills.end("bulk"), QMessageBox.critical(self, f"{what} failed", tb)),
                on_progress=lambda d, t, m: self.pills.update("bulk", d, t, f"{d} of {t}"))


def main(argv: list[str] | None = None) -> int:
    app = QApplication(argv if argv is not None else sys.argv)
    app.setApplicationName(APP_NAME)
    app.setOrganizationName("PhotoBrowser")
    app.setStyle("Fusion")
    app.setStyleSheet(STYLESHEET)
    win = MainWindow()
    win.show()
    return app.exec()
