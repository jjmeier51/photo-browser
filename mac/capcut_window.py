"""Safe Finder ▸ Send to CapCut / Import from CapCut — the windows (capcut.py has the logic).

**The tray** (`CapCutTray`): opened by "Send to CapCut" beside CapCut (which it opens). It floats over CapCut —
a small always-on-top panel that stays up while CapCut is the app in front — with the clips in timeline order
(Date taken / Name / As selected) and one big tile: **drag it into CapCut** (onto the media panel or straight
onto the timeline) and every clip goes in, in that order; or drag single rows. Copy puts the files on the
clipboard, Show in Finder reveals them, and "Copy to this Mac first" copies them into ~/Movies first (numbered)
for a project that has to work with the drive unplugged. Its lower half is the way back: it watches where CapCut
saves (capcut.candidate_folders) and every video CapCut exports after the send shows up there ("exporting…"
until CapCut has finished writing it) with **Import into “<the clips' folder>”** — moved (or copied) onto the
drive with the clips' tags and "capcut", dated like the earliest clip if wanted.

**The import window** (`CapCutImportDialog`): Import from CapCut… on a folder — every video in CapCut's export
folder (or all the usual places), newest first, the ones already brought in greyed; tick, choose where they go
(that folder, or each back to where its clips came from), Import.

Safe Finder hands in what it owns through `CapCutHooks` (thumbnails, the tag store, settings, a callback when
files arrive); the copying runs on a worker thread and reports back through a signal.
"""
from __future__ import annotations

import os
import subprocess
import threading
import time
from dataclasses import dataclass
from typing import Callable

from PySide6.QtCore import QMimeData, QObject, QPoint, QSize, Qt, QTimer, QUrl, Signal
from PySide6.QtGui import QColor, QDrag, QFont, QGuiApplication, QPainter, QPixmap
from PySide6.QtWidgets import (QAbstractItemView, QApplication, QButtonGroup, QCheckBox, QComboBox, QDialog,
                               QFileDialog, QFrame, QHBoxLayout, QLabel, QListWidget, QListWidgetItem,
                               QProgressBar, QPushButton, QRadioButton, QTreeWidget, QTreeWidgetItem, QVBoxLayout,
                               QWidget)

import capcut

PATH_ROLE = Qt.ItemDataRole.UserRole + 1
KEY_ROLE = Qt.ItemDataRole.UserRole + 2
ICON = 56


@dataclass
class CapCutHooks:
    thumb: Callable[[str], QPixmap | None] = lambda _p: None      # a thumbnail, or None while it's being made
    thumbs_ready: object | None = None                             # a Qt signal: thumbnails arrived
    store: object | None = None                                    # the tag store (tags, add)
    settings: object | None = None                                 # QSettings
    imported: Callable[[list[str]], None] | None = None            # files brought onto the drive


class _Bridge(QObject):
    call = Signal(object, object)      # (callback, value) from a worker thread → back on the GUI thread


def _setting(hooks: CapCutHooks, key: str, default: bool) -> bool:
    if hooks.settings is None:
        return default
    return str(hooks.settings.value(f"capcut/{key}", "true" if default else "false")) == "true"


def _remember(hooks: CapCutHooks, key: str, value) -> None:
    if hooks.settings is not None:
        hooks.settings.setValue(f"capcut/{key}", "true" if value is True else "false" if value is False else value)


def human(n: float) -> str:
    for unit in ("bytes", "KB", "MB", "GB"):
        if n < 1024 or unit == "GB":
            return f"{int(n)} bytes" if unit == "bytes" else f"{n:.1f} {unit}"
        n /= 1024
    return "?"


def length(path: str) -> str:
    try:
        import media_info
        return media_info.clock(media_info.video_duration(path))
    except Exception:  # noqa: BLE001
        return ""


def file_urls(paths: list[str]) -> QMimeData:
    md = QMimeData()
    md.setUrls([QUrl.fromLocalFile(p) for p in paths])
    return md


def reveal(paths: list[str]) -> None:
    """Shows the files in Finder (selected, when they share a folder)."""
    if not paths or not capcut.IS_MAC:
        return
    if len({os.path.dirname(p) for p in paths}) == 1 and len(paths) > 1:
        quoted = ", ".join('"' + p.replace("\\", "\\\\").replace('"', '\\"') + '"' for p in paths)
        lines = ["set found to {}", f"repeat with p in {{{quoted}}}",
                 "set end of found to ((POSIX file (p as text)) as alias)", "end repeat",
                 'tell application "Finder"', "activate", "reveal found", "end tell"]
        args = ["osascript"]
        for line in lines:
            args += ["-e", line]
        try:
            if subprocess.run(args, capture_output=True, timeout=15).returncode == 0:
                return
        except (OSError, subprocess.TimeoutExpired):
            pass
    subprocess.Popen(["open", "-R", paths[0]])


class _Importer:
    """Brings exports onto the drive on a worker thread (copying a long video takes a while); each result comes
    back on the GUI thread, where the tags and the record are written."""

    def __init__(self, bridge: _Bridge, hooks: CapCutHooks, record: capcut.Record) -> None:
        self.bridge, self.hooks, self.record = bridge, hooks, record
        self.running = False

    def run(self, jobs: list[tuple[capcut.Export, str, capcut.Session | None]], move: bool, dated: bool,
            tagged: bool, each, done) -> None:
        self.running = True

        def work() -> None:
            import simpcity as sc
            exiftool = sc.find_exiftool() if dated else None
            tool = sc.ExifSession(exiftool) if exiftool else None
            results = []
            try:
                for i, (export, folder, session) in enumerate(jobs, 1):
                    date = capcut.earliest_taken(session.clips) if dated and session else None
                    try:
                        dest, why = capcut.bring_in(export, folder, move, date, tool), ""
                    except OSError as e:
                        dest, why = "", str(e) or type(e).__name__
                    results.append((export, dest, session, why))
                    self.bridge.call.emit(each, (i, len(jobs), export, dest, why))
            finally:
                if tool is not None:
                    try:
                        tool.close()
                    except Exception:  # noqa: BLE001
                        pass
                self.bridge.call.emit(self._finished, (results, tagged, done))

        threading.Thread(target=work, daemon=True, name="capcut-import").start()

    def _finished(self, value) -> None:
        results, tagged, done = value
        self.running = False
        written = []
        for export, dest, session, _why in results:
            if not dest:
                continue
            written.append(dest)
            self.record.note_imported(export, dest)
            tags = [capcut.TAG] + (capcut.clip_tags(self.hooks.store, session.clips) if tagged and session else [])
            if self.hooks.store is not None:
                try:
                    self.hooks.store.add([dest], tags)
                except OSError:
                    pass
        try:
            self.record.save()
        except OSError:
            pass
        if written and self.hooks.imported:
            self.hooks.imported(written)
        done(results)


class ClipList(QListWidget):
    """The clips, draggable out (one, some, or all) as files — in list order, which is timeline order."""

    def __init__(self, parent=None) -> None:
        super().__init__(parent)
        self.setSelectionMode(QAbstractItemView.SelectionMode.ExtendedSelection)
        self.setDragEnabled(True)
        self.setDragDropMode(QAbstractItemView.DragDropMode.DragOnly)
        self.setDefaultDropAction(Qt.DropAction.CopyAction)
        self.setIconSize(QSize(ICON, ICON))
        self.setUniformItemSizes(True)

    def mimeTypes(self) -> list[str]:  # noqa: N802 — Qt override
        return ["text/uri-list"]

    def mimeData(self, items) -> QMimeData:  # noqa: N802 — Qt override
        rows = sorted(items, key=self.row)
        return file_urls([it.data(PATH_ROLE) for it in rows])

    def supportedDropActions(self) -> Qt.DropAction:  # noqa: N802 — Qt override
        return Qt.DropAction.CopyAction


class DragTile(QFrame):
    """The big "drag all of them into CapCut" tile."""

    def __init__(self, paths: Callable[[], list[str]], thumb: Callable[[str], QPixmap | None], parent=None) -> None:
        super().__init__(parent)
        self.paths, self.thumb = paths, thumb
        self.press: QPoint | None = None
        self.setMinimumHeight(86)
        self.setCursor(Qt.CursorShape.OpenHandCursor)
        self.setToolTip("Drag this onto CapCut's media panel or its timeline: every clip goes in, in this order")

    def paintEvent(self, _e) -> None:  # noqa: N802 — Qt override
        p = QPainter(self)
        p.setRenderHint(QPainter.RenderHint.Antialiasing)
        r = self.rect().adjusted(2, 2, -2, -2)
        pal = self.palette()
        p.setPen(QColor(pal.highlight().color()))
        p.setBrush(QColor(pal.highlight().color().red(), pal.highlight().color().green(),
                          pal.highlight().color().blue(), 36))
        p.drawRoundedRect(r, 12, 12)
        paths = self.paths()
        x = r.left() + 14
        for path in paths[:4]:
            pm = self.thumb(path)
            box = QPixmap(48, 48)
            box.fill(QColor(60, 60, 64))
            if pm is not None and not pm.isNull():
                box = pm.scaled(48, 48, Qt.AspectRatioMode.KeepAspectRatioByExpanding,
                                Qt.TransformationMode.SmoothTransformation).copy(0, 0, 48, 48)
            p.drawPixmap(x, r.center().y() - 24, box)
            x += 18
        p.setPen(pal.text().color())
        f = QFont(self.font())
        f.setPointSizeF(f.pointSizeF() + 2)
        f.setBold(True)
        p.setFont(f)
        n = len(paths)
        text = f"Drag {'all ' + str(n) + ' clips' if n != 1 else 'the clip'} into CapCut"
        p.drawText(r.adjusted(x - r.left() + 48, 0, -10, -14), Qt.AlignmentFlag.AlignVCenter, text)
        f.setBold(False)
        f.setPointSizeF(f.pointSizeF() - 3)
        p.setFont(f)
        p.setPen(pal.placeholderText().color())
        p.drawText(r.adjusted(x - r.left() + 48, 22, -10, 0), Qt.AlignmentFlag.AlignVCenter,
                   "onto the media panel or the timeline — in this order")

    def mousePressEvent(self, e) -> None:  # noqa: N802 — Qt override
        if e.button() == Qt.MouseButton.LeftButton:
            self.press = e.position().toPoint()

    def mouseMoveEvent(self, e) -> None:  # noqa: N802 — Qt override
        if self.press is None or (e.position().toPoint() - self.press).manhattanLength() \
                < QApplication.startDragDistance():
            return
        self.press = None
        paths = self.paths()
        if not paths:
            return
        drag = QDrag(self)
        drag.setMimeData(file_urls(paths))
        pm = self.thumb(paths[0])
        if pm is not None and not pm.isNull():
            drag.setPixmap(pm.scaled(72, 72, Qt.AspectRatioMode.KeepAspectRatio,
                                     Qt.TransformationMode.SmoothTransformation))
        drag.exec(Qt.DropAction.CopyAction)

    def mouseReleaseEvent(self, _e) -> None:  # noqa: N802 — Qt override
        self.press = None


class CapCutTray(QWidget):
    """Send to CapCut: the clips, ready to drag in — and CapCut's exports, ready to bring back."""

    def __init__(self, clips: list[str], hooks: CapCutHooks, parent=None) -> None:
        super().__init__(parent, Qt.WindowType.Tool | Qt.WindowType.WindowStaysOnTopHint)
        self.setAttribute(Qt.WidgetAttribute.WA_MacAlwaysShowToolWindow, True)
        self.hooks = hooks
        self.bridge = _Bridge()
        self.bridge.call.connect(lambda cb, value: cb(value))
        self.record = capcut.Record()
        self.session = capcut.Session.new(clips)
        self.record.add(self.session)
        self.selected = list(clips)              # as selected (the order "As selected" keeps)
        self.ordered: list[str] = list(clips)
        self.copies: list[str] = []
        self.importer = _Importer(self.bridge, hooks, self.record)
        self.shown: dict[str, QListWidgetItem] = {}     # exports listed, by key
        self.closing = False
        self.warning = ""
        self.setWindowTitle("CapCut")
        self.resize(400, 640)

        title = QLabel(f"<b>{len(clips)} clip{'s' if len(clips) != 1 else ''} for CapCut</b>")
        sub = QLabel(f"from “{os.path.basename(self.session.folder) or self.session.folder}”")
        sub.setStyleSheet("color: gray")
        self.order_box = QComboBox()
        for key, label in capcut.ORDERS:
            self.order_box.addItem(label, key)
        saved = hooks.settings.value("capcut/order", "taken") if hooks.settings is not None else "taken"
        self.order_box.setCurrentIndex(max(0, self.order_box.findData(saved)))
        self.order_box.currentIndexChanged.connect(self._reorder)
        self.tile = DragTile(lambda: self.copies or self.ordered, hooks.thumb)
        self.clips = ClipList()
        self.copy_first = QCheckBox("Copy to this Mac first")
        self.copy_first.setToolTip("Copies the clips into ~/Movies/Safe Finder for CapCut (numbered in this order) — "
                                   "for a CapCut project that has to work with the drive unplugged")
        self.copy_first.toggled.connect(self._copy_first)
        self.bar = QProgressBar()
        self.bar.setVisible(False)
        open_btn = QPushButton("Open CapCut")
        open_btn.clicked.connect(self._open)
        copy_btn = QPushButton("Copy")
        copy_btn.setToolTip("The clips on the clipboard, as files")
        copy_btn.clicked.connect(lambda: QGuiApplication.clipboard().setMimeData(file_urls(self.copies or self.ordered)))
        show_btn = QPushButton("Show in Finder")
        show_btn.clicked.connect(lambda: reveal(self.copies or self.ordered))

        back_title = QLabel("<b>Back from CapCut</b>")
        self.back_hint = QLabel("Export in CapCut and the video shows up here.")
        self.back_hint.setWordWrap(True)
        self.back_hint.setStyleSheet("color: gray")
        self.back = QListWidget()
        self.back.setIconSize(QSize(ICON, ICON))
        self.back.setSelectionMode(QAbstractItemView.SelectionMode.ExtendedSelection)
        self.back.setMaximumHeight(170)
        self.dest = self.session.folder
        self.import_btn = QPushButton()
        self.import_btn.setDefault(True)
        self.import_btn.clicked.connect(self._import)
        change = QPushButton("Change…")
        change.clicked.connect(self._change_dest)
        self.move_box = QCheckBox("Take it off the Mac (move)")
        self.move_box.setChecked(_setting(hooks, "move", True))
        self.move_box.toggled.connect(lambda on: _remember(hooks, "move", on))
        self.date_box = QCheckBox("Date it like its clips")
        self.date_box.setToolTip("Gives the video the date the earliest clip was taken (ExifTool), so it sorts with "
                                 "them by year on the iPhone")
        self.date_box.setChecked(_setting(hooks, "dated", True))
        self.date_box.toggled.connect(lambda on: _remember(hooks, "dated", on))
        all_btn = QPushButton("All CapCut Exports…")
        all_btn.clicked.connect(lambda: CapCutImportDialog(self.dest, self.hooks, self).open())
        self.status = QLabel("")
        self.status.setWordWrap(True)

        lay = QVBoxLayout(self)
        head = QHBoxLayout()
        words = QVBoxLayout()
        words.addWidget(title)
        words.addWidget(sub)
        head.addLayout(words, 1)
        head.addWidget(self.order_box)
        lay.addLayout(head)
        lay.addWidget(self.tile)
        lay.addWidget(self.clips, 1)
        lay.addWidget(self.copy_first)
        lay.addWidget(self.bar)
        row = QHBoxLayout()
        for b in (open_btn, copy_btn, show_btn):
            row.addWidget(b)
        lay.addLayout(row)
        line = QFrame()
        line.setFrameShape(QFrame.Shape.HLine)
        lay.addWidget(line)
        lay.addWidget(back_title)
        lay.addWidget(self.back_hint)
        lay.addWidget(self.back)
        dest_row = QHBoxLayout()
        dest_row.addWidget(self.import_btn, 1)
        dest_row.addWidget(change)
        lay.addLayout(dest_row)
        opts = QHBoxLayout()
        opts.addWidget(self.move_box)
        opts.addWidget(self.date_box)
        lay.addLayout(opts)
        lay.addWidget(all_btn)
        lay.addWidget(self.status)
        self._dest_label()
        self._fill(self.ordered)
        self._reorder()
        if hooks.thumbs_ready is not None:
            hooks.thumbs_ready.connect(self._thumbs)
        self.watch = QTimer(self)
        self.watch.setInterval(2000)
        self.watch.timeout.connect(self._look)
        self.watch.start()
        QTimer.singleShot(300, self._look)

    # ------------------------------------------------------------------ the clips
    def note(self, text: str) -> None:
        self.status.setText(text or self.warning)

    def warn(self, text: str) -> None:
        """A note that stays until something replaces it (CapCut isn't installed, say)."""
        self.warning = text
        self.note(text)

    def _fill(self, clips: list[str]) -> None:
        self.clips.clear()
        for path in clips:
            it = QListWidgetItem(os.path.basename(path))
            it.setData(PATH_ROLE, path)
            it.setToolTip(path)
            pm = self.hooks.thumb(path)
            if pm is not None and not pm.isNull():
                it.setIcon(pm)
            self.clips.addItem(it)
        self.tile.update()
        threading.Thread(target=self._lengths, args=(list(clips),), daemon=True).start()

    def _lengths(self, clips: list[str]) -> None:
        got = {p: length(p) for p in clips if os.path.splitext(p)[1].lower() in capcut.VIDEO_EXT}
        self.bridge.call.emit(self._show_lengths, got)

    def _show_lengths(self, got: dict[str, str]) -> None:
        if self.closing:
            return
        for i in range(self.clips.count()):
            it = self.clips.item(i)
            d = got.get(it.data(PATH_ROLE))
            if d:
                it.setText(f"{os.path.basename(it.data(PATH_ROLE))}  —  {d}")

    def _thumbs(self) -> None:
        if self.closing:
            return
        for lst in (self.clips, self.back):
            for i in range(lst.count()):
                it = lst.item(i)
                if it.icon().isNull():
                    pm = self.hooks.thumb(it.data(PATH_ROLE))
                    if pm is not None and not pm.isNull():
                        it.setIcon(pm)
        self.tile.update()

    def _reorder(self) -> None:
        how = self.order_box.currentData()
        if self.hooks.settings is not None:
            self.hooks.settings.setValue("capcut/order", how)
        self.note("Putting the clips in order…" if how == "taken" else "")

        def work() -> None:
            done = capcut.order(self.selected, how)
            self.bridge.call.emit(self._ordered, (how, done))
        threading.Thread(target=work, daemon=True).start()

    def _ordered(self, value) -> None:
        how, done = value
        if self.closing or how != self.order_box.currentData():
            return
        self.ordered = done
        self.session.clips = done
        self._fill(done)
        self.note("")
        if self.copy_first.isChecked():
            self._copy_first(True)

    def _copy_first(self, on: bool) -> None:
        if not on:                              # (not remembered: it would copy gigabytes on the next send)
            self.copies = []
            self.tile.update()
            return
        clips = list(self.ordered)
        self.bar.setVisible(True)
        self.bar.setRange(0, len(clips))
        self.bar.setValue(0)
        self.note("Copying the clips to this Mac…")

        def work() -> None:
            try:
                got = capcut.stage(self.session, clips, progress=lambda i, n: self.bridge.call.emit(self.bar.setValue, i),
                                   cancelled=lambda: self.closing)
                self.bridge.call.emit(self._staged, (clips, got, ""))
            except OSError as e:
                self.bridge.call.emit(self._staged, (clips, [], str(e)))
        threading.Thread(target=work, daemon=True).start()

    def _staged(self, value) -> None:
        clips, got, why = value
        if self.closing:
            return
        self.bar.setVisible(False)
        if why:
            self.copy_first.setChecked(False)
            self.note(f"Couldn't copy the clips: {why}")
            return
        if clips == self.ordered and self.copy_first.isChecked():
            self.copies = got
            self.record.save()
            self.tile.update()
            self.note(f"Copied to ~/Movies/{capcut.STAGING} — drag them in from here as before.")

    def _open(self) -> None:
        self.warn(capcut.open_app())

    # ------------------------------------------------------------------ back from CapCut
    def _dest_label(self) -> None:
        name = os.path.basename(self.dest) or self.dest
        self.import_btn.setText(f"Import into “{name}”")
        self.import_btn.setToolTip(self.dest)
        self.import_btn.setEnabled(self.back.count() > 0 and not self.importer.running)

    def _change_dest(self) -> None:
        got = QFileDialog.getExistingDirectory(self, "Import CapCut's videos into", self.dest)
        if got:
            self.dest = got
            self._dest_label()

    def _look(self) -> None:
        """CapCut's exports since the send: new ones listed, finished ones made importable."""
        if self.closing:
            return
        found = capcut.exports(capcut.candidate_folders(self.record), since=self.session.started - 5)
        now = time.time()
        keys = set()
        for e in found:
            if self.record.was_imported(e):
                continue
            keys.add(e.key)
            it = self.shown.get(e.key)
            if it is None:
                old = next((k for k, v in self.shown.items() if v.data(PATH_ROLE) == e.path), None)
                if old is not None:                         # the same file, grown: CapCut still writing it
                    it = self.shown.pop(old)
                else:
                    it = QListWidgetItem()
                    it.setData(PATH_ROLE, e.path)
                    self.back.insertItem(0, it)
                self.shown[e.key] = it
            it.setData(KEY_ROLE, e.key)
            busy = e.busy(now)
            it.setText(f"{e.name}\n" + ("exporting…" if busy else f"{human(e.size)}  ·  {length(e.path) or 'video'}"
                                         f"  ·  in {os.path.basename(os.path.dirname(e.path))}"))
            flags = it.flags()
            it.setFlags(flags & ~Qt.ItemFlag.ItemIsEnabled if busy else flags | Qt.ItemFlag.ItemIsEnabled)
            if not busy and it.icon().isNull():
                pm = self.hooks.thumb(e.path)
                if pm is not None and not pm.isNull():
                    it.setIcon(pm)
        for key in [k for k in self.shown if k not in keys]:
            it = self.shown.pop(key)
            if not it.text().endswith("— imported"):
                self.back.takeItem(self.back.row(it))
        ready = [it for it in self.shown.values() if it.flags() & Qt.ItemFlag.ItemIsEnabled]
        self.back_hint.setText("Export in CapCut and the video shows up here." if not self.shown else
                               f"{len(ready)} ready to bring onto the drive." if ready else "CapCut is exporting…")
        self._dest_label()
        self.import_btn.setEnabled(bool(ready) and not self.importer.running)

    def _import(self) -> None:
        picked = [it for it in self.back.selectedItems() if it.flags() & Qt.ItemFlag.ItemIsEnabled] or \
                 [it for it in self.shown.values() if it.flags() & Qt.ItemFlag.ItemIsEnabled]
        jobs = []
        for it in picked:
            key = it.data(KEY_ROLE)
            path = it.data(PATH_ROLE)
            try:
                st = os.stat(path)
            except OSError:
                continue
            e = capcut.Export(path, st.st_size, st.st_mtime)
            if e.key != key or e.busy():
                continue
            jobs.append((e, self.dest, self.session))
        if not jobs:
            return
        self.import_btn.setEnabled(False)
        self.watch.stop()
        self.note(f"Bringing {len(jobs)} video{'s' if len(jobs) != 1 else ''} onto the drive…")
        self.importer.run(jobs, self.move_box.isChecked(), self.date_box.isChecked(), True, self._one, self._done)

    def _one(self, value) -> None:
        i, n, export, dest, why = value
        if self.closing:
            return
        it = self.shown.get(export.key)
        if it is not None:
            it.setText(f"{export.name}\n" + (f"→ {os.path.basename(os.path.dirname(dest))}/{os.path.basename(dest)}"
                                             f"  — imported" if dest else f"couldn't: {why}"))
            it.setFlags(it.flags() & ~Qt.ItemFlag.ItemIsEnabled)
        self.note(f"Bringing them onto the drive… {i} of {n}")

    def _done(self, results) -> None:
        if self.closing:
            return
        ok = [r for r in results if r[1]]
        bad = [r for r in results if not r[1]]
        for export, dest, _s, _w in ok:
            self.shown.pop(export.key, None)
        text = f"Brought {len(ok)} video{'s' if len(ok) != 1 else ''} into “{os.path.basename(self.dest)}”, tagged " \
               f"“{capcut.TAG}”" + (" with the clips' tags" if ok else "") + "."
        if bad:
            text += f" {len(bad)} couldn't be: {bad[0][3]}"
        self.note(text if ok or bad else "")
        self.watch.start()
        self._look()

    def closeEvent(self, e) -> None:  # noqa: N802 — Qt override
        self.closing = True
        self.watch.stop()
        super().closeEvent(e)


class CapCutImportDialog(QDialog):
    """Import from CapCut…: CapCut's finished videos, newest first — tick, choose where, Import."""

    def __init__(self, folder: str, hooks: CapCutHooks, parent=None) -> None:
        super().__init__(parent)
        self.setAttribute(Qt.WidgetAttribute.WA_DeleteOnClose)
        self.hooks = hooks
        self.folder = folder
        self.bridge = _Bridge()
        self.bridge.call.connect(lambda cb, value: cb(value))
        self.record = capcut.Record()
        self.importer = _Importer(self.bridge, hooks, self.record)
        self.setWindowTitle("Import from CapCut")
        self.resize(760, 560)

        self.where = QComboBox()
        self.where.addItem("All the usual places", "")
        for f in capcut.candidate_folders(self.record):
            self.where.addItem(f.replace(os.path.expanduser("~"), "~", 1), f)
        self.where.addItem("Choose Folder…", "?")
        start = self.where.findData(self.record.exports) if self.record.exports else 0
        self.where.setCurrentIndex(max(0, start))
        self.where.activated.connect(self._where)
        self.since = QCheckBox("Only videos made since you last sent clips to CapCut")
        latest = self.record.latest()
        self.since.setEnabled(latest is not None)
        self.since.setChecked(latest is not None and not self.record.exports)
        self.since.toggled.connect(self._fill)
        self.list = QTreeWidget()
        self.list.setHeaderLabels(["Video", "Length", "Size", "Made", "Its clips are in"])
        self.list.setRootIsDecorated(False)
        self.list.setIconSize(QSize(ICON, ICON))
        self.list.setColumnWidth(0, 300)
        self.into_clips = QRadioButton("Back where its clips came from")
        self.into_folder = QRadioButton()
        group = QButtonGroup(self)
        group.addButton(self.into_clips)
        group.addButton(self.into_folder)
        self.into_folder.setChecked(bool(folder))
        self.into_clips.setChecked(not folder)
        choose = QPushButton("Choose…")
        choose.clicked.connect(self._choose)
        self.move_box = QCheckBox("Take them off the Mac (move)")
        self.move_box.setChecked(_setting(hooks, "move", True))
        self.move_box.toggled.connect(lambda on: _remember(hooks, "move", on))
        self.tags_box = QCheckBox("Give them their clips' tags")
        self.tags_box.setChecked(_setting(hooks, "tagged", True))
        self.tags_box.toggled.connect(lambda on: _remember(hooks, "tagged", on))
        self.date_box = QCheckBox("Date them like their clips")
        self.date_box.setChecked(_setting(hooks, "dated", True))
        self.date_box.toggled.connect(lambda on: _remember(hooks, "dated", on))
        self.status = QLabel("")
        self.status.setWordWrap(True)
        self.go = QPushButton("Import")
        self.go.setDefault(True)
        self.go.clicked.connect(self._import)
        close = QPushButton("Close")
        close.clicked.connect(self.close)

        lay = QVBoxLayout(self)
        top = QHBoxLayout()
        top.addWidget(QLabel("CapCut saves its exports in:"))
        top.addWidget(self.where, 1)
        lay.addLayout(top)
        lay.addWidget(self.since)
        lay.addWidget(self.list, 1)
        into = QHBoxLayout()
        into.addWidget(QLabel("Into:"))
        into.addWidget(self.into_clips)
        into.addWidget(self.into_folder)
        into.addWidget(choose)
        into.addStretch(1)
        lay.addLayout(into)
        opts = QHBoxLayout()
        for w in (self.move_box, self.tags_box, self.date_box):
            opts.addWidget(w)
        opts.addStretch(1)
        lay.addLayout(opts)
        bottom = QHBoxLayout()
        bottom.addWidget(self.status, 1)
        bottom.addWidget(close)
        bottom.addWidget(self.go)
        lay.addLayout(bottom)
        self._folder_label()
        if hooks.thumbs_ready is not None:
            hooks.thumbs_ready.connect(self._thumbs)
        self._fill()

    def _folder_label(self) -> None:
        self.into_folder.setText(f"“{os.path.basename(self.folder)}”" if self.folder else "a folder (choose one)")
        self.into_folder.setEnabled(bool(self.folder))
        self.into_folder.setToolTip(self.folder)

    def _choose(self) -> None:
        got = QFileDialog.getExistingDirectory(self, "Import CapCut's videos into", self.folder or os.path.expanduser("~"))
        if got:
            self.folder = got
            self._folder_label()
            self.into_folder.setChecked(True)

    def _where(self) -> None:
        if self.where.currentData() == "?":
            got = QFileDialog.getExistingDirectory(self, "Where CapCut saves its exports", os.path.expanduser("~/Movies"))
            if not got:
                self.where.setCurrentIndex(0)
            else:
                self.record.exports = got
                try:
                    self.record.save()
                except OSError:
                    pass
                self.where.insertItem(1, got.replace(os.path.expanduser("~"), "~", 1), got)
                self.where.setCurrentIndex(1)
        self._fill()

    def folders(self) -> list[str]:
        chosen = self.where.currentData()
        return [chosen] if chosen and chosen != "?" else capcut.candidate_folders(self.record)

    def _fill(self) -> None:
        self.list.clear()
        latest = self.record.latest()
        since = latest.started - 5 if self.since.isChecked() and latest is not None else 0.0
        found = capcut.exports(self.folders(), since=since)[:400]
        now = time.time()
        for n, e in enumerate(found):
            session = self.record.session_for(e.mtime)
            done = self.record.was_imported(e)
            shown_length = length(e.path) if n < 80 and not e.busy(now) else ""   # (each read opens the file)
            it = QTreeWidgetItem([e.name, shown_length, human(e.size),
                                  time.strftime("%b %d, %H:%M", time.localtime(e.mtime)),
                                  os.path.basename(session.folder) if session else "—"])
            it.setData(0, PATH_ROLE, e.path)
            it.setData(0, KEY_ROLE, e.key)
            it.setToolTip(0, e.path)
            it.setFlags(it.flags() | Qt.ItemFlag.ItemIsUserCheckable)
            it.setCheckState(0, Qt.CheckState.Unchecked)
            if done or e.busy(now):
                it.setDisabled(True)
                it.setText(1, "brought in" if done else "exporting…")
            pm = self.hooks.thumb(e.path)
            if pm is not None and not pm.isNull():
                it.setIcon(0, pm)
            self.list.addTopLevelItem(it)
        self.status.setText("No videos there yet — export from CapCut, or pick the folder its Export panel saves "
                            "into above." if not found else
                            f"{len(found)} video{'s' if len(found) != 1 else ''} — tick the ones to bring onto the drive.")

    def _thumbs(self) -> None:
        for i in range(self.list.topLevelItemCount()):
            it = self.list.topLevelItem(i)
            if it.icon(0).isNull():
                pm = self.hooks.thumb(it.data(0, PATH_ROLE))
                if pm is not None and not pm.isNull():
                    it.setIcon(0, pm)

    def _import(self) -> None:
        jobs, skipped = [], 0
        for i in range(self.list.topLevelItemCount()):
            it = self.list.topLevelItem(i)
            if it.checkState(0) != Qt.CheckState.Checked or it.isDisabled():
                continue
            path = it.data(0, PATH_ROLE)
            try:
                st = os.stat(path)
            except OSError:
                continue
            e = capcut.Export(path, st.st_size, st.st_mtime)
            session = self.record.session_for(e.mtime)
            dest = session.folder if self.into_clips.isChecked() and session else self.folder
            if not dest or not os.path.isdir(dest):
                skipped += 1
                continue
            jobs.append((e, dest, session))
        if not jobs:
            self.status.setText("Tick the videos to bring in" + (" — and choose a folder for the ones with no clips "
                                                                 "sent from Safe Finder." if skipped else "."))
            return
        self.go.setEnabled(False)
        self.status.setText(f"Bringing {len(jobs)} video{'s' if len(jobs) != 1 else ''} onto the drive…")
        self.importer.run(jobs, self.move_box.isChecked(), self.date_box.isChecked(), self.tags_box.isChecked(),
                          lambda v: self.status.setText(f"Bringing them onto the drive… {v[0]} of {v[1]}"),
                          lambda results: self._done(results, skipped))

    def _done(self, results, skipped: int) -> None:
        ok = [r for r in results if r[1]]
        bad = [r for r in results if not r[1]]
        self.go.setEnabled(True)
        self._fill()
        text = f"Brought {len(ok)} video{'s' if len(ok) != 1 else ''} onto the drive, tagged “{capcut.TAG}”."
        if bad:
            text += f" {len(bad)} couldn't be: {bad[0][3]}"
        if skipped:
            text += f" {skipped} had no folder to go to."
        self.status.setText(text)
