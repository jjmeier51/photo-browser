"""Safe Finder's Edit Metadata window — many photos and videos at once (metadata_edit.py does the work).

It opens at once and reads in the background: first the photos and videos among what was picked (every one
inside a picked folder and its subfolders), then what each holds now (ExifTool, a hundred files a call). Each
field is ticked to be changed — everything unticked stays exactly as it is — and shows what the files hold now
(the one value they share, "mixed", or nothing); ticking a field the files agree on fills it in to edit. The
table below is the plan file by file — the capture date now and after, and anything a file can't take — and
it's what Write does, nothing more. Writing asks first (it can't be undone), runs a file at a time with Stop
between files, and says at the end which files weren't changed and why.

Without ExifTool on this Mac it says so (brew install exiftool), with Choose ExifTool… for one elsewhere.
"""
from __future__ import annotations

import os
import threading
from datetime import datetime, timedelta
from typing import Callable

from PySide6.QtCore import QDateTime, QObject, QSettings, Qt, QTimer, Signal
from PySide6.QtWidgets import (QButtonGroup, QCheckBox, QComboBox, QDateTimeEdit, QDialog, QFileDialog, QFrame,
                               QGridLayout, QHBoxLayout, QHeaderView, QLabel, QLineEdit, QMessageBox,
                               QPlainTextEdit, QProgressBar, QPushButton, QRadioButton, QScrollArea, QSpinBox,
                               QStackedWidget, QTreeWidget, QTreeWidgetItem, QVBoxLayout, QWidget)

import metadata_edit as md
import simpcity as sc

TOOL_KEY = "metadata/exiftool"
SHOWN_ROWS = 1500                       # the preview lists this many files; the summary counts them all
DATE_MODES = [("set", "Set to"), ("shift", "Shift by"), ("name", "From the file name"),
              ("file", "From the file's own date"), ("to_file", "Copy to the files' own dates")]
KEYWORD_MODES = [("replace", "Replace with"), ("add", "Add"), ("remove", "Remove")]
RED = "#FF453A"


def find_tool(settings: QSettings | None) -> str | None:
    chosen = str(settings.value(TOOL_KEY) or "") if settings is not None else ""
    if chosen and os.access(chosen, os.X_OK):
        return chosen
    return sc.find_exiftool()


class _Signals(QObject):
    found = Signal(int)                  # photos and videos found so far
    listed = Signal(list, int)           # the media, how many files can't hold metadata
    reading = Signal(int)                # files read so far
    loaded = Signal(dict)                # path → md.Info
    progress = Signal(int, str, str, str)  # index, path, outcome, why
    done = Signal()


def _elide(s: str, n: int = 60) -> str:
    s = " ".join(s.split())
    return s if len(s) <= n else s[:n - 1] + "…"


class MetadataDialog(QDialog):
    """`on_done(changed, redraw)` runs on the UI thread after a write: the files that were changed, and whether
    their pictures may look different (orientation or everything else removed — thumbnails to redo)."""

    def __init__(self, parent: QWidget | None, paths: list[str], settings: QSettings,
                 on_done: Callable[[list[str], bool], None], tool_path: str | None = None) -> None:
        super().__init__(parent)
        self.paths, self.settings, self.on_done = list(paths), settings, on_done
        self.tool_path = tool_path or find_tool(settings)
        self.tool: sc.ExifSession | None = None
        self.media: list[str] = []
        self.skipped = 0
        self.infos: dict[str, md.Info] = {}
        self.loaded = False
        self.running = False
        self.changes: list[md.Change] = []
        self.edit = md.Edit()
        self.error = ""
        self._stop = threading.Event()
        self._busy = 0                    # worker threads alive
        self._closing = False
        self._updated: list[str] = []
        self._unchanged = 0
        self._failed: list[tuple[str, str]] = []
        self._redraw = False
        self._sig = _Signals()            # unparented: a worker may still emit after the window has gone
        self._sig.found.connect(self._found)
        self._sig.listed.connect(self._listed)
        self._sig.reading.connect(self._reading)
        self._sig.loaded.connect(self._loaded)
        self._sig.progress.connect(self._progress)
        self._sig.done.connect(self._finished)
        self._soon = QTimer(self)
        self._soon.setSingleShot(True)
        self._soon.setInterval(120)
        self._soon.timeout.connect(self.refresh)

        self.setWindowTitle("Edit Metadata")
        self.resize(860, 900)
        lay = QVBoxLayout(self)
        lay.setContentsMargins(20, 16, 20, 14)
        lay.setSpacing(10)
        self.title = QLabel("Looking for photos and videos…", objectName="SheetTitle")
        self.title.setWordWrap(True)
        lay.addWidget(self.title)
        self.sub = QLabel("Tick what to change — everything else stays exactly as it is. A ticked field left empty "
                          "is removed from the files.", objectName="SheetSub")
        self.sub.setWordWrap(True)
        lay.addWidget(self.sub)

        self.no_tool = QFrame(objectName="SheetRow")
        nt = QHBoxLayout(self.no_tool)
        nt.setContentsMargins(12, 8, 12, 8)
        msg = QLabel("Editing metadata needs ExifTool, which isn't on this Mac yet. Install it with Homebrew — "
                     "<b>brew install exiftool</b> — or from exiftool.org, then open this again.")
        msg.setWordWrap(True)
        nt.addWidget(msg, 1)
        pick = QPushButton("Choose ExifTool…")
        pick.clicked.connect(self.choose_tool)
        nt.addWidget(pick)
        lay.addWidget(self.no_tool)
        self.no_tool.setVisible(not self.tool_path)

        self.form = QWidget()
        form = QVBoxLayout(self.form)
        form.setContentsMargins(0, 0, 4, 0)
        form.setSpacing(10)
        form.addWidget(self._date_section())
        form.addWidget(self._place_section())
        form.addWidget(self._text_section("Description", ("caption", "title", "keywords", "creator", "copyright",
                                                          "rating")))
        form.addWidget(self._text_section("Camera", ("make", "model", "lens", "software")))
        form.addWidget(self._custom_section())
        form.addWidget(self._strip_section())
        form.addStretch(1)
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.Shape.NoFrame)
        scroll.setWidget(self.form)
        lay.addWidget(scroll, 5)

        self.table = QTreeWidget()
        self.table.setRootIsDecorated(False)
        self.table.setUniformRowHeights(True)
        self.table.setHeaderLabels(["File", "Capture date now", "After", "Notes"])
        self.table.header().setSectionResizeMode(0, QHeaderView.ResizeMode.Stretch)
        for col in (1, 2):
            self.table.header().setSectionResizeMode(col, QHeaderView.ResizeMode.ResizeToContents)
        self.table.header().setSectionResizeMode(3, QHeaderView.ResizeMode.Stretch)
        self.table.setMinimumHeight(140)
        lay.addWidget(self.table, 2)

        self.summary = QLabel("", objectName="SheetSub")
        self.summary.setWordWrap(True)
        lay.addWidget(self.summary)
        self.bar = QProgressBar()
        self.bar.setTextVisible(False)
        self.bar.hide()
        lay.addWidget(self.bar)
        buttons = QHBoxLayout()
        buttons.addStretch(1)
        self.cancel_btn = QPushButton("Cancel")
        self.cancel_btn.setAutoDefault(False)
        self.cancel_btn.clicked.connect(self.reject)
        buttons.addWidget(self.cancel_btn)
        self.write_btn = QPushButton("Write", objectName="Primary")
        self.write_btn.setAutoDefault(False)         # Return in a field never writes
        self.write_btn.clicked.connect(self.write)
        buttons.addWidget(self.write_btn)
        lay.addLayout(buttons)

        self.form.setEnabled(False)
        self.write_btn.setEnabled(False)
        self._start_reading()

    # ------------------------------------------------------------------ sections
    def _section(self, title: str, check: bool = True) -> tuple[QFrame, QVBoxLayout, QCheckBox | None]:
        box = QFrame(objectName="SheetRow")
        v = QVBoxLayout(box)
        v.setContentsMargins(12, 10, 12, 10)
        v.setSpacing(7)
        head = QHBoxLayout()
        cb = None
        if check:
            cb = QCheckBox(title)
            f = cb.font()
            f.setBold(True)
            cb.setFont(f)
            cb.toggled.connect(self._changed)
            head.addWidget(cb)
        else:
            lbl = QLabel(f"<b>{title}</b>")
            head.addWidget(lbl)
        head.addStretch(1)
        v.addLayout(head)
        return box, v, cb

    def _now_label(self) -> QLabel:
        lbl = QLabel("", objectName="SheetSub")
        lbl.setWordWrap(True)
        lbl.setTextInteractionFlags(Qt.TextInteractionFlag.TextSelectableByMouse)
        return lbl

    def _date_section(self) -> QFrame:
        box, v, self.date_check = self._section("Capture Date")
        self.date_now = self._now_label()
        v.addWidget(self.date_now)
        row = QHBoxLayout()
        self.date_mode = QComboBox()
        for key, label in DATE_MODES:
            self.date_mode.addItem(label, key)
        row.addWidget(self.date_mode)
        self.date_stack = QStackedWidget()
        # set
        w = QWidget()
        h = QHBoxLayout(w)
        h.setContentsMargins(0, 0, 0, 0)
        self.when = QDateTimeEdit(QDateTime.currentDateTime())
        self.when.setDisplayFormat("yyyy-MM-dd  HH:mm:ss")
        self.when.setCalendarPopup(True)
        h.addWidget(self.when)
        h.addWidget(QLabel("then"))
        self.step = QSpinBox()
        self.step.setRange(0, 86400)
        self.step.setValue(1)
        self.step.setSuffix(" s")
        self.step.setToolTip("Each file after the first is this many seconds later, in the order they're listed "
                             "below — so they stay in that order wherever they're sorted by date")
        h.addWidget(self.step)
        h.addWidget(QLabel("later for each next file"))
        h.addStretch(1)
        self.date_stack.addWidget(w)
        # shift
        w = QWidget()
        h = QHBoxLayout(w)
        h.setContentsMargins(0, 0, 0, 0)
        self.shift: dict[str, QSpinBox] = {}
        for unit, top in (("days", 36500), ("hours", 100000), ("minutes", 1000000), ("seconds", 10000000)):
            s = QSpinBox()
            s.setRange(-top, top)
            s.valueChanged.connect(self._changed)
            self.shift[unit] = s
            h.addWidget(s)
            h.addWidget(QLabel(unit))
        h.addStretch(1)
        self.date_stack.addWidget(w)
        # name
        w = QWidget()
        h = QHBoxLayout(w)
        h.setContentsMargins(0, 0, 0, 0)
        self.pattern = QLineEdit()
        self.pattern.setPlaceholderText("found by itself — or a pattern, e.g. %Y%m%d_%H%M%S")
        self.pattern.setToolTip("Left empty, it finds the usual ones: IMG_20240613_101530, PXL_…, 2024-06-13 "
                                "10.15.30, Screenshot 2024-06-13 at 10.15.30, VID-20240613-WA0001 (noon), Unix "
                                "times. A pattern uses %Y %m %d %H %M %S %y.")
        self.pattern.textChanged.connect(self._changed)
        h.addWidget(self.pattern, 1)
        self.date_stack.addWidget(w)
        # file
        w = QWidget()
        h = QHBoxLayout(w)
        h.setContentsMargins(0, 0, 0, 0)
        self.source = QComboBox()
        self.source.addItem("Date modified", "modified")
        self.source.addItem("Date created", "created")
        self.source.currentIndexChanged.connect(self._changed)
        h.addWidget(self.source)
        h.addStretch(1)
        self.date_stack.addWidget(w)
        # to_file
        w = QLabel("The capture date stays; each file's created and modified dates become it — so Finder sorts "
                   "them by when they were taken.", objectName="SheetSub")
        w.setWordWrap(True)
        self.date_stack.addWidget(w)
        row.addWidget(self.date_stack, 1)
        v.addLayout(row)
        self.only_missing = QCheckBox("Only files that have no capture date yet")
        self.file_dates = QCheckBox("The files' own created and modified dates follow")
        self.file_dates.setChecked(str(self.settings.value("metadata/file_dates", "true")) == "true")
        for w2 in (self.only_missing, self.file_dates):
            w2.toggled.connect(self._changed)
            v.addWidget(w2)
        self.date_mode.currentIndexChanged.connect(self._date_mode_changed)
        self.when.dateTimeChanged.connect(self._changed)
        self.step.valueChanged.connect(self._changed)
        self._date_mode_changed()
        self.date_controls = [self.date_mode, self.date_stack, self.only_missing, self.file_dates]
        return box

    def _date_mode_changed(self) -> None:
        mode = self.date_mode.currentData()
        self.date_stack.setCurrentIndex(self.date_mode.currentIndex())
        self.only_missing.setVisible(mode in ("set", "name", "file"))
        self.file_dates.setVisible(mode != "to_file")
        self._changed()

    def _place_section(self) -> QFrame:
        box, v, self.place_check = self._section("Location")
        self.place_now = self._now_label()
        v.addWidget(self.place_now)
        row = QHBoxLayout()
        self.place_set = QRadioButton("Set to")
        self.place_clear = QRadioButton("Remove it")
        grp = QButtonGroup(box)
        grp.addButton(self.place_set)
        grp.addButton(self.place_clear)
        self.place_set.setChecked(True)
        self.place_text = QLineEdit()
        self.place_text.setPlaceholderText("37.7749, -122.4194 — or paste a Google or Apple Maps link")
        row.addWidget(self.place_set)
        row.addWidget(self.place_text, 1)
        row.addSpacing(10)
        row.addWidget(self.place_clear)
        v.addLayout(row)
        self.place_note = QLabel("", objectName="SheetSub")
        v.addWidget(self.place_note)
        for w in (self.place_set, self.place_clear):
            w.toggled.connect(self._changed)
        self.place_text.textChanged.connect(self._changed)
        self.place_controls = [self.place_set, self.place_clear, self.place_text]
        return box

    def _text_section(self, title: str, keys: tuple[str, ...]) -> QFrame:
        box, v, _ = self._section(title, check=False)
        grid = QGridLayout()
        grid.setHorizontalSpacing(10)
        grid.setVerticalSpacing(6)
        grid.setColumnStretch(1, 1)
        if not hasattr(self, "text_checks"):
            self.text_checks: dict[str, QCheckBox] = {}
            self.text_edits: dict[str, QWidget] = {}
            self.text_nows: dict[str, QLabel] = {}
        for r, key in enumerate(keys):
            cb = QCheckBox(md.LABELS[key])
            cb.toggled.connect(lambda on, key=key: self._ticked(key, on))
            if key == "caption":
                ed: QWidget = QPlainTextEdit()
                ed.setFixedHeight(64)
                ed.textChanged.connect(self._changed)
            elif key == "rating":
                ed = QComboBox()
                for n, label in enumerate(("None", "★", "★★", "★★★", "★★★★", "★★★★★")):
                    ed.addItem(label, n)
                ed.currentIndexChanged.connect(self._changed)
            elif key == "keywords":
                ed = QWidget()
                h = QHBoxLayout(ed)
                h.setContentsMargins(0, 0, 0, 0)
                self.keyword_mode = QComboBox()
                for k, label in KEYWORD_MODES:
                    self.keyword_mode.addItem(label, k)
                self.keyword_mode.currentIndexChanged.connect(self._changed)
                self.keyword_text = QLineEdit()
                self.keyword_text.setPlaceholderText("separated by commas")
                self.keyword_text.textChanged.connect(self._changed)
                h.addWidget(self.keyword_mode)
                h.addWidget(self.keyword_text, 1)
            else:
                ed = QLineEdit()
                ed.textChanged.connect(self._changed)
            ed.setEnabled(False)
            now = self._now_label()
            grid.addWidget(cb, r * 2, 0, Qt.AlignmentFlag.AlignTop)
            grid.addWidget(ed, r * 2, 1)
            grid.addWidget(now, r * 2 + 1, 1)
            self.text_checks[key], self.text_edits[key], self.text_nows[key] = cb, ed, now
        v.addLayout(grid)
        if title == "Camera":
            hint = QLabel("Videos take a make, model and software, not a lens.", objectName="SheetSub")
            v.addWidget(hint)
        return box

    def _custom_section(self) -> QFrame:
        box, v, self.custom_check = self._section("Other Tags")
        hint = QLabel("Any tag by its ExifTool name, one per line: <i>EXIF:ISO=200</i>, <i>XMP:Label=Red</i>, "
                      "<i>IPTC:City=Paris</i>. <i>Tag=</i> with nothing after removes it. Every file gets the same "
                      "value.", objectName="SheetSub")
        hint.setWordWrap(True)
        v.addWidget(hint)
        self.custom_text = QPlainTextEdit()
        self.custom_text.setFixedHeight(70)
        self.custom_text.setPlaceholderText("EXIF:ISO=200")
        self.custom_text.textChanged.connect(self._changed)
        self.custom_text.setEnabled(False)
        v.addWidget(self.custom_text)
        self.custom_note = QLabel("", objectName="SheetSub")
        self.custom_note.setWordWrap(True)
        v.addWidget(self.custom_note)
        self.custom_check.toggled.connect(self.custom_text.setEnabled)
        return box

    def _strip_section(self) -> QFrame:
        box, v, self.strip_check = self._section("Remove Everything Else")
        hint = QLabel("Every other tag is taken out first — camera, lens, serial numbers, software, location, "
                      "captions, keywords — keeping only the capture date, how the photo is turned and its "
                      "colour profile. Then the ticked fields above are written. RAW and TIFF files are left as "
                      "they are.", objectName="SheetSub")
        hint.setWordWrap(True)
        v.addWidget(hint)
        return box

    # ------------------------------------------------------------------ ExifTool
    def choose_tool(self) -> None:
        path, _ = QFileDialog.getOpenFileName(self, "Choose ExifTool", "/opt/homebrew/bin")
        if not path:
            return
        if not os.access(path, os.X_OK):
            QMessageBox.warning(self, "Edit Metadata", "That file can't be run — choose the “exiftool” program.")
            return
        self.settings.setValue(TOOL_KEY, path)
        self.tool_path = path
        self.no_tool.hide()
        if not self.running and self._busy == 0:
            self.loaded = False
            self._start_reading()

    # ------------------------------------------------------------------ reading
    def _start_reading(self) -> None:
        paths, tool_path, sig, stop = list(self.paths), self.tool_path, self._sig, self._stop
        known = list(self.media) if self.media else None
        self._busy += 1

        def work() -> None:
            # Its own ExifTool, without error lines: an error printed mid-answer would break the JSON.
            reader = sc.ExifSession(tool_path) if tool_path else None
            try:
                if known is None:
                    media, skipped = md.media_in(paths, stop.is_set, sig.found.emit)
                    sig.listed.emit(media, skipped)
                else:
                    media = known
                infos = md.read(media, reader, stop.is_set, sig.reading.emit) if reader else \
                    {p: md.Info(p, md.is_video(p)) for p in media}
                sig.loaded.emit(infos)
            except Exception as e:  # noqa: BLE001 — shown, never a crash
                sig.loaded.emit({"": str(e)})
            finally:
                if reader is not None:
                    reader.close()
                self._worker_ended()
        threading.Thread(target=work, daemon=True).start()

    def _worker_ended(self) -> None:
        self._busy -= 1
        if self._closing and self._busy == 0 and self.tool is not None:
            self.tool.close()

    def _found(self, n: int) -> None:
        self.title.setText(f"Looking for photos and videos… {n:,}")

    def _listed(self, media: list, skipped: int) -> None:
        self.media, self.skipped = media, skipped
        self._title()
        if media and self.tool_path:
            self.summary.setText(f"Reading what {len(media):,} file{'s' if len(media) != 1 else ''} hold now…")
            self.bar.setRange(0, len(media))
            self.bar.setValue(0)
            self.bar.show()

    def _title(self) -> None:
        photos = sum(1 for p in self.media if not md.is_video(p))
        videos = len(self.media) - photos
        bits = []
        if photos:
            bits.append(f"{photos:,} photo{'s' if photos != 1 else ''}")
        if videos:
            bits.append(f"{videos:,} video{'s' if videos != 1 else ''}")
        if len(self.media) == 1:
            what = f"“{os.path.basename(self.media[0])}”"
        else:
            what = " and ".join(bits) if bits else "no photos or videos"
        self.title.setText(f"Edit the metadata of {what}")
        self.setWindowTitle("Edit Metadata" if len(self.media) <= 1 else f"Edit Metadata of {len(self.media):,} Items")
        if self.skipped:
            self.sub.setText(self.sub.text().split("  ·  ")[0] + f"  ·  {self.skipped:,} file"
                             f"{'s' if self.skipped != 1 else ''} in a format that can't hold these (GIF, WebM, "
                             "AVI…) left out.")

    def _reading(self, n: int) -> None:
        self.bar.setValue(n)
        self.summary.setText(f"Reading what the files hold now… {n:,} of {len(self.media):,}")

    def _loaded(self, infos: dict) -> None:
        self.bar.hide()
        if "" in infos:
            self.summary.setText(f"Couldn't read the files: {infos['']}")
            return
        if self._stop.is_set():
            return
        self.infos = infos
        self.loaded = True
        if not self.media:
            self.summary.setText("There are no photos or videos here that can hold metadata (JPEG, HEIC, PNG, "
                                 "WebP, TIFF, RAW, MOV, MP4).")
            return
        self.form.setEnabled(bool(self.tool_path))
        self._fill_now()
        self.refresh()

    def _ordered(self) -> list[md.Info]:
        return [self.infos.get(p) or md.Info(p, md.is_video(p)) for p in self.media]

    def _fill_now(self) -> None:
        if not self.tool_path:                    # nothing could be read: say nothing rather than "none"
            for lbl in (self.date_now, self.place_now, *self.text_nows.values()):
                lbl.setText("")
            return
        infos = self._ordered()
        dates = [i.date for i in infos if i.date]
        none = len(infos) - len(dates)
        some = f" — {none:,} {'has' if none == 1 else 'have'} none" if none else ""
        if not dates:
            self.date_now.setText("Now: none of them has a capture date.")
        elif len(set(dates)) == 1:
            d = infos[0].date or dates[0]
            self.date_now.setText(f"Now: {md.fmt_date(dates[0])}" + ("" if len(infos) == 1 or none else " on all")
                                  + some)
            self.when.setDateTime(QDateTime(d.year, d.month, d.day, d.hour, d.minute, d.second))
        else:
            first, last = min(dates), max(dates)
            self.date_now.setText(f"Now: {md.fmt_date(first)} to {md.fmt_date(last)}" + some)
            self.when.setDateTime(QDateTime(first.year, first.month, first.day, first.hour, first.minute,
                                            first.second))
        places = [md.fmt_place(i.place) for i in infos]
        value, n = md.common(places)
        self.place_now.setText(self._now_text(value, n, len(infos)))
        if value:
            self.place_text.setText(value)
        for key, lbl in self.text_nows.items():
            if key in ("lens",) and all(i.video for i in infos):
                lbl.setText("Videos have no lens.")
                continue
            vals = [i.text(key) for i in infos if not (key == "lens" and i.video)]
            value, n = md.common(vals)
            if key == "rating" and value:
                value = "★" * int(value)
            lbl.setText(self._now_text(value, n, len(vals)))

    @staticmethod
    def _now_text(value: str, distinct: int, total: int) -> str:
        if value:
            return f"Now: {_elide(value)}" + ("" if total == 1 else " — on all")
        if distinct > 1:
            return f"Now: {distinct:,} different" if distinct < total else "Now: different on each"
        return "Now: none"

    # ------------------------------------------------------------------ the edit
    def _ticked(self, key: str, on: bool) -> None:
        ed = self.text_edits[key]
        ed.setEnabled(on)
        if on and self.loaded:
            vals = [i.text(key) for i in self._ordered() if not (key == "lens" and i.video)]
            value, _n = md.common(vals)
            if key == "rating":
                pass
            elif key == "keywords":
                if value and not self.keyword_text.text():
                    self.keyword_text.setText(value)
            elif value and isinstance(ed, QPlainTextEdit) and not ed.toPlainText():
                ed.setPlainText(value)
            elif value and isinstance(ed, QLineEdit) and not ed.text():
                ed.setText(value)
            ed.setFocus()
        self._changed()

    def _changed(self, *_a) -> None:
        if self.date_check is not None:
            for w in getattr(self, "date_controls", []):
                w.setEnabled(self.date_check.isChecked())
            for w in getattr(self, "place_controls", []):
                w.setEnabled(self.place_check.isChecked())
            if hasattr(self, "place_text"):
                self.place_text.setEnabled(self.place_check.isChecked() and self.place_set.isChecked())
        if not self.running:
            self._soon.start()

    def build_edit(self) -> tuple[md.Edit, str]:
        """The edit the form describes, and what's wrong with it ("" when nothing)."""
        e = md.Edit()
        problems: list[str] = []
        if self.date_check.isChecked():
            mode = self.date_mode.currentData()
            q = self.when.dateTime()
            when = datetime(q.date().year(), q.date().month(), q.date().day(), q.time().hour(), q.time().minute(),
                            q.time().second())
            e.date = md.DateEdit(mode, when=when, step=self.step.value(),
                                 shift=timedelta(days=self.shift["days"].value(), hours=self.shift["hours"].value(),
                                                 minutes=self.shift["minutes"].value(),
                                                 seconds=self.shift["seconds"].value()),
                                 pattern=self.pattern.text().strip(), source=self.source.currentData(),
                                 only_missing=self.only_missing.isChecked(),
                                 file_dates=self.file_dates.isChecked() or mode == "to_file")
            if mode == "shift" and not e.date.shift:
                problems.append("Capture date: shift by how much?")
        self.place_note.setText("")
        if self.place_check.isChecked():
            if self.place_clear.isChecked():
                e.clear_place = True
            else:
                place = md.parse_place(self.place_text.text())
                if place is None:
                    problems.append("Location: that isn't a place")
                    self.place_note.setText("<span style='color:%s'>That isn't a place — try 37.7749, -122.4194, "
                                            "or paste a Maps link.</span>" % RED)
                else:
                    e.place = place
                    self.place_note.setText(f"{place[0]:.6f}, {place[1]:.6f}")
        for key, cb in self.text_checks.items():
            if not cb.isChecked():
                continue
            ed = self.text_edits[key]
            if key == "rating":
                e.rating = int(ed.currentData())
            elif key == "keywords":
                words = [w.strip() for w in self.keyword_text.text().split(",") if w.strip()]
                how = self.keyword_mode.currentData()
                if how != "replace" and not words:
                    problems.append(f"Keywords: which to {how}?")
                else:
                    e.keywords = (how, words)
            elif isinstance(ed, QPlainTextEdit):
                e.texts[key] = ed.toPlainText().strip()
            else:
                e.texts[key] = ed.text().strip()
        self.custom_note.setText("")
        if self.custom_check.isChecked():
            try:
                e.custom = md.parse_custom(self.custom_text.toPlainText())
            except md.TagError as err:
                problems.append("Other tags: " + str(err))
                self.custom_note.setText(f"<span style='color:{RED}'>{err}</span>")
        e.strip = self.strip_check.isChecked()
        return e, "; ".join(problems)

    def refresh(self) -> None:
        if not self.loaded or self.running:
            return
        self.edit, self.error = self.build_edit()
        self.changes = md.plan(self._ordered(), self.edit)
        self.table.setUpdatesEnabled(False)
        self.table.clear()
        rows = []
        for ch in self.changes[:SHOWN_ROWS]:
            if ch.after:
                after = md.fmt_date(ch.after, ch.offset)
            elif ch.file_when:
                after = "same · the file's dates set to it"
            else:
                after = ""
            notes = list(ch.notes)                # what it can't take first, then what it gets
            if ch.keywords is not None:
                notes.append("keywords: " + (", ".join(ch.keywords) or "none"))
            if not ch.writes and not ch.notes and not self.edit.empty():
                notes.append("nothing to change")
            it = QTreeWidgetItem([os.path.basename(ch.path), md.fmt_date(ch.before), after, "; ".join(notes)])
            it.setToolTip(0, ch.path)
            it.setToolTip(3, "\n".join(notes))
            if ch.notes:
                it.setForeground(3, Qt.GlobalColor.red)
            rows.append(it)
        self.table.addTopLevelItems(rows)
        self.table.setUpdatesEnabled(True)
        writing = sum(1 for ch in self.changes if ch.writes)
        short = sum(1 for ch in self.changes if ch.notes)
        if self.edit.empty():
            text = "Tick what to change."
        elif self.error:
            text = f"<span style='color:{RED}'>{self.error}</span>"
        else:
            text = (f"{writing:,} of {len(self.changes):,} file{'s' if len(self.changes) != 1 else ''} will be "
                    "changed" if writing else "Nothing to change — the files already hold that.")
            if short:
                text += f" · {short:,} can't take all of it (see Notes)"
            if len(self.changes) > SHOWN_ROWS:
                text += f" · the first {SHOWN_ROWS:,} are listed"
        self.summary.setText(text)
        self.write_btn.setEnabled(bool(writing) and not self.error and bool(self.tool_path))

    # ------------------------------------------------------------------ writing
    def write(self) -> None:
        if self.running or not self.loaded:
            return
        self.refresh()
        todo = [ch for ch in self.changes if ch.writes]
        if not todo or self.error or not self.tool_path:
            return
        n = len(todo)
        if not self.ask_to_write(n, self.edit.strip):
            return
        if self.edit.date:
            self.settings.setValue("metadata/file_dates", "true" if self.file_dates.isChecked() else "false")
        self.running = True
        self._stop.clear()
        self._updated, self._unchanged, self._failed = [], 0, []
        self._redraw = self.edit.strip or any("orientation" in t.lower() for t, _v in self.edit.custom)
        self.form.setEnabled(False)
        self.write_btn.setEnabled(False)
        self.cancel_btn.setText("Stop")
        self.bar.setRange(0, n)
        self.bar.setValue(0)
        self.bar.show()
        self.summary.setText(f"Writing 1 of {n:,}…")
        if self.tool is None:                     # ExifTool's error lines kept: they say why a file failed
            self.tool = sc.ExifSession(self.tool_path, errors=True)
        tool, sig, stop = self.tool, self._sig, self._stop
        caption = next((ch.caption for ch in todo if ch.caption), "")
        self._busy += 1

        def work() -> None:
            cap = md.caption_file(caption) if caption else ""
            try:
                for i, ch in enumerate(todo):
                    if stop.is_set():
                        break
                    try:
                        res, why = md.write(ch, tool, cap)
                    except Exception as e:  # noqa: BLE001 — one bad file never stops the rest
                        res, why = "failed", f"{type(e).__name__}: {e}"
                    sig.progress.emit(i, ch.path, res, why)
            finally:
                if cap:
                    try:
                        os.remove(cap)
                    except OSError:
                        pass
                sig.done.emit()
                self._worker_ended()
        threading.Thread(target=work, daemon=True).start()

    def ask_to_write(self, n: int, strip: bool) -> bool:
        box = QMessageBox(self)
        box.setIcon(QMessageBox.Icon.Warning if strip else QMessageBox.Icon.Question)
        box.setWindowTitle("Edit Metadata")
        box.setText(f"Write these changes into {n:,} file{'s' if n != 1 else ''}?")
        detail = "They're written into the files themselves and can't be undone."
        if strip:
            detail = ("Everything but the capture date, orientation and colour profile is removed from them "
                      "first. " + detail)
        box.setInformativeText(detail)
        go = box.addButton("Write", QMessageBox.ButtonRole.AcceptRole)
        box.addButton(QMessageBox.StandardButton.Cancel)
        box.setDefaultButton(go)
        box.exec()
        return box.clickedButton() is go

    def report(self, changed: int, failed: list[tuple[str, str]], stopped: bool) -> None:
        """The end of a write, when it didn't all go: which files weren't changed and why."""
        n = changed
        if failed:
            lines = "\n".join(f"• {os.path.basename(p)} — {why}" for p, why in failed[:12])
            more = f"\n…and {len(failed) - 12:,} more" if len(failed) > 12 else ""
            QMessageBox.warning(self, "Some Files Weren't Changed",
                                f"Changed {n:,} file{'s' if n != 1 else ''}. These were left as they were:"
                                f"\n\n{lines}{more}")
        elif stopped:
            QMessageBox.information(self, "Edit Metadata", f"Stopped — {n:,} file{'s' if n != 1 else ''} "
                                    "had been changed; the rest are as they were.")

    def _progress(self, i: int, path: str, res: str, why: str) -> None:
        if res == "updated":
            self._updated.append(path)
        elif res == "unchanged":
            self._unchanged += 1
        else:
            self._failed.append((path, why))
        self.bar.setValue(i + 1)
        total = self.bar.maximum()
        if not self._stop.is_set():
            self.summary.setText(f"Writing {min(i + 2, total):,} of {total:,}…")

    def _finished(self) -> None:
        self.running = False
        self.on_done(list(self._updated), self._redraw)
        if self._failed or self._stop.is_set():
            self.report(len(self._updated), list(self._failed), self._stop.is_set())
        self.accept()

    # ------------------------------------------------------------------ closing
    def reject(self) -> None:
        if self.running:                          # Stop: finish the file in hand, then wrap up
            self._stop.set()
            self.cancel_btn.setEnabled(False)
            self.summary.setText("Stopping after this file…")
            return
        self._shut()
        super().reject()

    def accept(self) -> None:
        self._shut()
        super().accept()

    def closeEvent(self, event) -> None:  # noqa: N802
        if self.running:
            self.reject()
            event.ignore()
            return
        self._shut()
        super().closeEvent(event)

    def _shut(self) -> None:
        self._stop.set()
        self._closing = True
        if self._busy == 0 and self.tool is not None:
            self.tool.close()
