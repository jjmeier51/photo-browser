"""The three bulk editors. Each one previews every change in a table before anything is written,
and returns a plan the window executes on a worker thread:

* `RenameDialog` — pattern with tokens ({name} {n} {date} {folder} {ext}…), find & replace (plain
  or regex), prefix/suffix, sequence numbering; conflicts are flagged and never applied.
* `DatesDialog` — set an exact date (optionally stepping N seconds per file so order survives),
  shift by ±days/hours/minutes, or read the date out of the filename with a strptime pattern.
* `MetadataDialog` — per-field "apply" toggles for captions, title, keywords (replace/append),
  creator, copyright, rating, camera, GPS; only ticked fields are written.
"""

from __future__ import annotations

import os
import re
from datetime import datetime, timedelta

from PySide6.QtCore import QDateTime, Qt
from PySide6.QtGui import QColor
from PySide6.QtWidgets import (QCheckBox, QComboBox, QDateTimeEdit, QDialog, QDialogButtonBox, QDoubleSpinBox,
                               QFormLayout, QHBoxLayout, QLabel, QLineEdit, QRadioButton, QSpinBox, QStackedWidget,
                               QTableWidget, QTableWidgetItem, QTextEdit, QVBoxLayout, QWidget, QHeaderView, QGroupBox)

from ..exiftool import FIELDS, capture_date, field_value, format_date
from ..library import Entry
from ..theme import P


def _q_to_dt(q: QDateTime) -> datetime:
    return datetime(q.date().year(), q.date().month(), q.date().day(), q.time().hour(), q.time().minute(), q.time().second())


def _preview_table(headers: list[str]) -> QTableWidget:
    t = QTableWidget(0, len(headers))
    t.setHorizontalHeaderLabels(headers)
    t.horizontalHeader().setSectionResizeMode(QHeaderView.Stretch)
    t.verticalHeader().setVisible(False)
    t.setEditTriggers(QTableWidget.NoEditTriggers)
    t.setSelectionMode(QTableWidget.NoSelection)
    t.setAlternatingRowColors(True)
    t.setMinimumHeight(220)
    return t


def _fill(table: QTableWidget, rows: list[tuple[str, ...]], bad: set[int] = frozenset()):
    table.setRowCount(len(rows))
    for r, row in enumerate(rows):
        for c, text in enumerate(row):
            it = QTableWidgetItem(text)
            if r in bad:
                it.setForeground(QColor(P.red))
            table.setItem(r, c, it)


class _BulkDialog(QDialog):
    def __init__(self, title: str, entries: list[Entry], meta: dict[str, dict], parent=None):
        super().__init__(parent)
        self.setWindowTitle(title)
        self.setMinimumSize(780, 600)
        self.entries = [e for e in entries if not e.is_dir]
        self.meta = meta
        self.plan = None
        self.buttons = QDialogButtonBox(QDialogButtonBox.Cancel)
        self.apply_btn = self.buttons.addButton("Apply", QDialogButtonBox.AcceptRole)
        self.apply_btn.setObjectName("Primary")
        self.buttons.accepted.connect(self.accept)
        self.buttons.rejected.connect(self.reject)
        self.summary = QLabel(""); self.summary.setObjectName("Secondary")


# ---- Rename -------------------------------------------------------------------------------------

class RenameDialog(_BulkDialog):
    TOKENS = "{name} original name · {n} number · {n:3} zero-padded · {date} yyyy-mm-dd · {date:%Y%m%d_%H%M%S} custom · {folder} · {ext}"

    def __init__(self, entries, meta, parent=None):
        super().__init__("Bulk Rename", entries, meta, parent)
        lay = QVBoxLayout(self); lay.setSpacing(10)
        lay.addWidget(QLabel(f"Rename {len(self.entries)} file{'s' if len(self.entries) != 1 else ''}. Extensions are kept unless the pattern sets one."))

        self.mode = QComboBox(); self.mode.addItems(["Pattern", "Find & Replace", "Add Prefix / Suffix"])
        self.stack = QStackedWidget()

        # pattern
        p = QWidget(); pf = QFormLayout(p)
        self.pattern = QLineEdit("{date} {name}"); self.pattern.setPlaceholderText("e.g. {date:%Y-%m-%d} {folder} {n:3}")
        self.start = QSpinBox(); self.start.setRange(0, 999999); self.start.setValue(1)
        pf.addRow("Pattern", self.pattern)
        pf.addRow("Numbering starts at", self.start)
        hint = QLabel(self.TOKENS); hint.setObjectName("Tertiary"); hint.setWordWrap(True)
        pf.addRow("", hint)
        self.stack.addWidget(p)

        # find/replace
        fr = QWidget(); ff = QFormLayout(fr)
        self.find = QLineEdit(); self.replace = QLineEdit()
        self.regex = QCheckBox("Regular expression"); self.case = QCheckBox("Match case")
        ff.addRow("Find", self.find); ff.addRow("Replace with", self.replace)
        opts = QHBoxLayout(); opts.addWidget(self.regex); opts.addWidget(self.case); opts.addStretch(1)
        ff.addRow("", opts)
        self.stack.addWidget(fr)

        # prefix/suffix
        ps = QWidget(); pf2 = QFormLayout(ps)
        self.prefix = QLineEdit(); self.suffix = QLineEdit()
        pf2.addRow("Prefix", self.prefix); pf2.addRow("Suffix (before extension)", self.suffix)
        self.stack.addWidget(ps)

        self.mode.currentIndexChanged.connect(self.stack.setCurrentIndex)
        lay.addWidget(self.mode); lay.addWidget(self.stack)

        self.table = _preview_table(["Current name", "New name"])
        lay.addWidget(self.table, 1)
        lay.addWidget(self.summary)
        lay.addWidget(self.buttons)

        for w in (self.pattern, self.find, self.replace, self.prefix, self.suffix):
            w.textChanged.connect(self.refresh)
        for w in (self.regex, self.case):
            w.toggled.connect(self.refresh)
        self.start.valueChanged.connect(self.refresh)
        self.mode.currentIndexChanged.connect(self.refresh)
        self.refresh()

    def _new_name(self, e: Entry, i: int) -> str | None:
        base, ext = os.path.splitext(e.name)
        mode = self.mode.currentIndex()
        if mode == 0:
            tpl = self.pattern.text()
            if not tpl.strip():
                return None
            d = capture_date(self.meta.get(e.path, {})) or datetime.fromtimestamp(e.mtime)
            n = self.start.value() + i

            def sub(m: re.Match) -> str:
                tok, arg = m.group(1), m.group(2)
                if tok == "name":
                    return base
                if tok == "ext":
                    return ext.lstrip(".")
                if tok == "folder":
                    return os.path.basename(os.path.dirname(e.path))
                if tok == "n":
                    return str(n).zfill(int(arg)) if arg and arg.isdigit() else str(n)
                if tok == "date":
                    try:
                        return d.strftime(arg) if arg else d.strftime("%Y-%m-%d")
                    except ValueError:
                        return d.strftime("%Y-%m-%d")
                return m.group(0)
            out = re.sub(r"\{(\w+)(?::([^}]*))?\}", sub, tpl).strip()
            if not out:
                return None
            if not os.path.splitext(out)[1]:
                out += ext
            return out
        if mode == 1:
            f = self.find.text()
            if not f:
                return None
            flags = 0 if self.case.isChecked() else re.IGNORECASE
            try:
                pat = re.compile(f if self.regex.isChecked() else re.escape(f), flags)
            except re.error:
                return None
            nb = pat.sub(self.replace.text(), base)
            return (nb + ext) if nb and nb != base else None
        pre, suf = self.prefix.text(), self.suffix.text()
        if not pre and not suf:
            return None
        return f"{pre}{base}{suf}{ext}"

    def refresh(self):
        rows: list[tuple[str, str]] = []
        bad: set[int] = set()
        plan: list[tuple[str, str]] = []            # (old path, new name)
        claimed: dict[str, set[str]] = {}
        for i, e in enumerate(self.entries):
            new = self._new_name(e, i)
            if not new or new == e.name:
                rows.append((e.name, "—"))
                continue
            folder = os.path.dirname(e.path)
            taken = claimed.setdefault(folder, set())
            bad_name = ("/" in new or new.startswith(".") or new.lower() in taken
                        or (os.path.exists(os.path.join(folder, new)) and new.lower() != e.name.lower()))
            rows.append((e.name, new + ("   (conflict)" if bad_name else "")))
            if bad_name:
                bad.add(i)
            else:
                taken.add(new.lower())
                plan.append((e.path, new))
        _fill(self.table, rows, bad)
        self.plan = plan
        self.apply_btn.setEnabled(bool(plan))
        self.summary.setText(f"{len(plan)} file{'s' if len(plan) != 1 else ''} will be renamed"
                             + (f" · {len(bad)} skipped for conflicts" if bad else ""))


# ---- Dates ----------------------------------------------------------------------------------------

class DatesDialog(_BulkDialog):
    def __init__(self, entries, meta, parent=None):
        super().__init__("Bulk Dates", entries, meta, parent)
        lay = QVBoxLayout(self); lay.setSpacing(10)
        lay.addWidget(QLabel(f"Change the capture date of {len(self.entries)} file{'s' if len(self.entries) != 1 else ''} "
                             "(EXIF DateTimeOriginal / CreateDate / ModifyDate, plus the QuickTime dates for video)."))

        self.mode = QComboBox(); self.mode.addItems(["Set to a date", "Shift by an amount", "From the filename"])
        self.stack = QStackedWidget()

        s = QWidget(); sf = QFormLayout(s)
        self.when = QDateTimeEdit(QDateTime.currentDateTime()); self.when.setDisplayFormat("yyyy-MM-dd  HH:mm:ss"); self.when.setCalendarPopup(True)
        self.step = QSpinBox(); self.step.setRange(0, 3600); self.step.setValue(1); self.step.setSuffix(" s")
        sf.addRow("Date & time", self.when)
        sf.addRow("Step between files", self.step)
        h = QLabel("Files keep their current order: each one is stamped this many seconds after the previous."); h.setObjectName("Tertiary"); h.setWordWrap(True)
        sf.addRow("", h)
        self.stack.addWidget(s)

        sh = QWidget(); shf = QFormLayout(sh)
        self.days = QSpinBox(); self.days.setRange(-36500, 36500)
        self.hours = QSpinBox(); self.hours.setRange(-8760, 8760)
        self.minutes = QSpinBox(); self.minutes.setRange(-525600, 525600)
        row = QHBoxLayout()
        for w, lbl in ((self.days, "days"), (self.hours, "hours"), (self.minutes, "minutes")):
            row.addWidget(w); row.addWidget(QLabel(lbl))
        row.addStretch(1)
        shf.addRow("Shift by", row)
        h2 = QLabel("Use this to fix a camera clock or a time zone; negative values move dates earlier."); h2.setObjectName("Tertiary"); h2.setWordWrap(True)
        shf.addRow("", h2)
        self.stack.addWidget(sh)

        fn = QWidget(); fnf = QFormLayout(fn)
        self.fn_pattern = QLineEdit("%Y%m%d_%H%M%S")
        fnf.addRow("Date pattern in filename", self.fn_pattern)
        h3 = QLabel("strptime tokens: %Y year, %m month, %d day, %H %M %S time. The pattern is searched anywhere in the name — "
                    "e.g. IMG_20240613_101530.jpg matches %Y%m%d_%H%M%S; 2024-06-13 12.30.00.mov matches %Y-%m-%d %H.%M.%S."); h3.setObjectName("Tertiary"); h3.setWordWrap(True)
        fnf.addRow("", h3)
        self.stack.addWidget(fn)

        self.mode.currentIndexChanged.connect(self.stack.setCurrentIndex)
        lay.addWidget(self.mode); lay.addWidget(self.stack)
        self.file_dates = QCheckBox("Also set the file's created / modified dates to match"); self.file_dates.setChecked(True)
        lay.addWidget(self.file_dates)

        self.table = _preview_table(["File", "Current", "New"])
        lay.addWidget(self.table, 1)
        lay.addWidget(self.summary)
        lay.addWidget(self.buttons)

        self.when.dateTimeChanged.connect(self.refresh)
        for w in (self.step, self.days, self.hours, self.minutes):
            w.valueChanged.connect(self.refresh)
        self.fn_pattern.textChanged.connect(self.refresh)
        self.mode.currentIndexChanged.connect(self.refresh)
        self.refresh()

    @staticmethod
    def _from_filename(name: str, pattern: str) -> datetime | None:
        """Find a substring of `name` that parses with `pattern` (strptime)."""
        base = os.path.splitext(name)[0]
        # Turn the strptime pattern into a regex to locate the candidate substring.
        rx = re.escape(pattern)
        for tok, r in (("%Y", r"\d{4}"), ("%m", r"\d{2}"), ("%d", r"\d{2}"), ("%H", r"\d{2}"), ("%M", r"\d{2}"), ("%S", r"\d{2}"), ("%y", r"\d{2}")):
            rx = rx.replace(re.escape(tok), r)
        try:
            m = re.search(rx, base)
        except re.error:
            return None
        if not m:
            return None
        try:
            return datetime.strptime(m.group(0), pattern)
        except ValueError:
            return None

    def refresh(self):
        rows, bad, plan = [], set(), {}
        mode = self.mode.currentIndex()
        base_when = _q_to_dt(self.when.dateTime())
        delta = timedelta(days=self.days.value(), hours=self.hours.value(), minutes=self.minutes.value())
        for i, e in enumerate(self.entries):
            m = self.meta.get(e.path, {})
            cur = capture_date(m)
            new: datetime | None
            if mode == 0:
                new = base_when + timedelta(seconds=self.step.value() * i)
            elif mode == 1:
                new = (cur + delta) if cur else None
            else:
                new = self._from_filename(e.name, self.fn_pattern.text())
            cur_s = cur.strftime("%Y-%m-%d %H:%M:%S") if cur else "—"
            if new is None or (cur and format_date(cur) == format_date(new)):
                rows.append((e.name, cur_s, "—" if new is None else "unchanged"))
                if new is None:
                    bad.add(i)
                continue
            rows.append((e.name, cur_s, new.strftime("%Y-%m-%d %H:%M:%S")))
            plan[e.path] = new
        _fill(self.table, rows, bad)
        self.plan = {"dates": plan, "file_dates": self.file_dates.isChecked()}
        self.apply_btn.setEnabled(bool(plan))
        self.summary.setText(f"{len(plan)} file{'s' if len(plan) != 1 else ''} will be updated"
                             + (f" · {len(bad)} have no date to work from" if bad else ""))


# ---- Metadata & captions ------------------------------------------------------------------------

class MetadataDialog(_BulkDialog):
    def __init__(self, entries, meta, parent=None):
        super().__init__("Bulk Metadata & Captions", entries, meta, parent)
        self.setMinimumSize(820, 800)
        lay = QVBoxLayout(self); lay.setSpacing(10)
        lay.addWidget(QLabel(f"Write the ticked fields to {len(self.entries)} file{'s' if len(self.entries) != 1 else ''}. "
                             "Unticked fields are left exactly as they are. Leave a ticked field empty to clear it."))
        self.checks: dict[str, QCheckBox] = {}
        self.edits: dict[str, QLineEdit | QTextEdit] = {}
        form = QFormLayout(); form.setSpacing(8)
        for f in FIELDS:
            cb = QCheckBox(f.label)
            if f.multiline:
                w = QTextEdit(); w.setFixedHeight(64); w.setAcceptRichText(False)
            else:
                w = QLineEdit()
            common = {field_value(self.meta.get(e.path, {}), f) for e in self.entries}
            w.setPlaceholderText(next(iter(common)) if len(common) == 1 and next(iter(common)) else ("Mixed" if len(common) > 1 else "—"))
            cb.toggled.connect(w.setEnabled); w.setEnabled(False)
            cb.toggled.connect(self.refresh)
            if isinstance(w, QTextEdit):
                w.textChanged.connect(self.refresh)
            else:
                w.textChanged.connect(self.refresh)
            self.checks[f.key] = cb; self.edits[f.key] = w
            form.addRow(cb, w)
        self.keywords_append = QCheckBox("Append keywords instead of replacing")
        form.addRow("", self.keywords_append)
        self.keywords_append.toggled.connect(self.refresh)

        gps_box = QGroupBox("Location")
        gl = QHBoxLayout(gps_box)
        self.gps_check = QCheckBox("Set GPS")
        self.lat = QDoubleSpinBox(); self.lat.setRange(-90, 90); self.lat.setDecimals(6); self.lat.setPrefix("lat ")
        self.lon = QDoubleSpinBox(); self.lon.setRange(-180, 180); self.lon.setDecimals(6); self.lon.setPrefix("lon ")
        self.gps_clear = QCheckBox("Clear GPS")
        for w in (self.gps_check, self.lat, self.lon, self.gps_clear):
            gl.addWidget(w)
        self.gps_check.toggled.connect(self.refresh); self.gps_clear.toggled.connect(self.refresh)
        self.lat.valueChanged.connect(self.refresh); self.lon.valueChanged.connect(self.refresh)
        lay.addLayout(form); lay.addWidget(gps_box)

        self.table = _preview_table(["Tag", "Value"])
        self.table.setMinimumHeight(120); self.table.setMaximumHeight(200)
        lay.addWidget(self.table, 1)
        lay.addWidget(self.summary)
        lay.addWidget(self.buttons)
        self.refresh()

    def refresh(self):
        from ..exiftool import gps_tags
        tags: dict[str, str | None] = {}
        per_file: dict[str, dict[str, str | None]] = {}
        for f in FIELDS:
            if not self.checks[f.key].isChecked():
                continue
            w = self.edits[f.key]
            v = (w.toPlainText() if isinstance(w, QTextEdit) else w.text()).strip()
            if f.key == "keywords" and self.keywords_append.isChecked() and v:
                for e in self.entries:
                    cur = field_value(self.meta.get(e.path, {}), f)
                    merged = [k.strip() for k in (cur.split(",") if cur else []) if k.strip()]
                    for k in v.split(","):
                        if k.strip() and k.strip().lower() not in {m.lower() for m in merged}:
                            merged.append(k.strip())
                    per_file.setdefault(e.path, {})[f.write[0]] = ", ".join(merged)
                continue
            for t in f.write:
                tags[t] = v if v else None
        if self.gps_clear.isChecked():
            tags.update(gps_tags(None, None))
        elif self.gps_check.isChecked():
            tags.update(gps_tags(self.lat.value(), self.lon.value()))
        rows = [(t, v if v else "(cleared)") for t, v in tags.items()]
        if per_file:
            rows.append(("MWG:Keywords", "(appended per file)"))
        _fill(self.table, rows)
        self.plan = {"tags": tags, "per_file": per_file}
        ok = bool(tags or per_file)
        self.apply_btn.setEnabled(ok)
        self.summary.setText(f"{len(tags) + (1 if per_file else 0)} tag{'s' if (len(tags) + (1 if per_file else 0)) != 1 else ''} → {len(self.entries)} file{'s' if len(self.entries) != 1 else ''}" if ok else "Tick a field to change it.")
