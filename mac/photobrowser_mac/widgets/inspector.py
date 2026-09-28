"""Right panel — the iOS Info panel, editable. One selection shows the preview, filename, capture
date, caption and the other fields inline with a Save; many selected shows counts, the common
value of each field ("Mixed" otherwise) and the bulk buttons. Edits are staged until Save."""

from __future__ import annotations

import os
from datetime import datetime

from PySide6.QtCore import QDateTime, Qt, Signal
from PySide6.QtGui import QPixmap
from PySide6.QtWidgets import (QDateTimeEdit, QFormLayout, QFrame, QHBoxLayout, QLabel, QLineEdit,
                               QPushButton, QScrollArea, QTextEdit, QVBoxLayout, QWidget, QSizePolicy)

from ..exiftool import FIELDS, capture_date, field_value, format_date
from ..library import Entry, human_size


class Inspector(QWidget):
    save_requested = Signal(object)          # dict: {"path", "rename", "date", "fields": {key: value}}
    bulk_rename = Signal()
    bulk_dates = Signal()
    bulk_metadata = Signal()

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setObjectName("Inspector")
        self.entries: list[Entry] = []
        self.meta: dict[str, dict] = {}
        self._loading = False

        self.setMinimumWidth(320)
        outer = QVBoxLayout(self); outer.setContentsMargins(0, 0, 0, 0)
        scroll = QScrollArea(); scroll.setWidgetResizable(True); scroll.setFrameShape(QFrame.NoFrame)
        scroll.setHorizontalScrollBarPolicy(Qt.ScrollBarAlwaysOff)
        scroll.viewport().setAutoFillBackground(False)
        body = QWidget(); body.setAutoFillBackground(False); scroll.setWidget(body); outer.addWidget(scroll)
        lay = QVBoxLayout(body); lay.setContentsMargins(14, 14, 14, 14); lay.setSpacing(10)

        self.preview = QLabel(); self.preview.setAlignment(Qt.AlignCenter)
        self.preview.setMinimumHeight(180); self.preview.setStyleSheet("background: #1C1C1E; border-radius: 12px;")
        self.preview.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Fixed)
        lay.addWidget(self.preview)

        self.headline = QLabel("Nothing selected"); self.headline.setObjectName("Title"); self.headline.setWordWrap(True)
        self.subline = QLabel("Select a photo or video to see and edit its details."); self.subline.setObjectName("Secondary"); self.subline.setWordWrap(True)
        lay.addWidget(self.headline); lay.addWidget(self.subline)

        # -- editable form
        form_head = QLabel("DETAILS"); form_head.setObjectName("Heading"); lay.addWidget(form_head)
        self.form = QFormLayout(); self.form.setLabelAlignment(Qt.AlignLeft); self.form.setSpacing(8)
        self.form.setRowWrapPolicy(QFormLayout.WrapAllRows)
        self.name_edit = QLineEdit(); self.name_edit.setPlaceholderText("Filename")
        self.form.addRow("Filename", self.name_edit)
        self.date_edit = QDateTimeEdit(); self.date_edit.setDisplayFormat("yyyy-MM-dd  HH:mm:ss"); self.date_edit.setCalendarPopup(True)
        self.date_clear = QPushButton("No date"); self.date_clear.setObjectName("Flat"); self.date_clear.setCheckable(True)
        drow = QHBoxLayout(); drow.addWidget(self.date_edit, 1); drow.addWidget(self.date_clear)
        self.form.addRow("Capture date", drow)
        # File-system dates are shown beside the capture date (read-only here; the Dates editor can
        # make them follow the capture date).
        self.modified_lbl = QLineEdit(); self.modified_lbl.setReadOnly(True)
        self.created_lbl = QLineEdit(); self.created_lbl.setReadOnly(True)
        self.form.addRow("Modified date", self.modified_lbl)
        self.form.addRow("Created date", self.created_lbl)
        self.field_edits: dict[str, QLineEdit | QTextEdit] = {}
        for f in FIELDS:
            if f.multiline:
                w = QTextEdit(); w.setFixedHeight(72); w.setAcceptRichText(False)
            else:
                w = QLineEdit()
            w.setPlaceholderText("—")
            self.field_edits[f.key] = w
            self.form.addRow(f.label, w)
        lay.addLayout(self.form)

        self.save_btn = QPushButton("Save Changes"); self.save_btn.setObjectName("Primary")
        self.save_btn.clicked.connect(self._save)
        lay.addWidget(self.save_btn)

        # -- read-only facts
        facts_head = QLabel("FILE"); facts_head.setObjectName("Heading"); lay.addWidget(facts_head)
        self.facts = QLabel(); self.facts.setObjectName("Secondary"); self.facts.setWordWrap(True)
        self.facts.setTextInteractionFlags(Qt.TextSelectableByMouse)
        lay.addWidget(self.facts)

        # -- bulk
        bulk_head = QLabel("BULK EDIT SELECTION"); bulk_head.setObjectName("Heading"); lay.addWidget(bulk_head)
        b1 = QPushButton("Rename…"); b1.clicked.connect(self.bulk_rename)
        b2 = QPushButton("Dates…"); b2.clicked.connect(self.bulk_dates)
        b3 = QPushButton("Metadata & Captions…"); b3.clicked.connect(self.bulk_metadata)
        self.bulk_buttons = [b1, b2, b3]
        brow = QVBoxLayout(); brow.setSpacing(6)
        for b in self.bulk_buttons:
            brow.addWidget(b)
        lay.addLayout(brow)
        lay.addStretch(1)
        self.set_selection([], {})

    # -- population --------------------------------------------------------------------------------

    def set_selection(self, entries: list[Entry], meta: dict[str, dict], preview: QPixmap | None = None):
        self.entries = [e for e in entries if not e.is_dir]
        self.meta = meta
        self._loading = True
        n = len(self.entries)
        single = n == 1
        for w in (self.name_edit, self.date_edit, self.date_clear, self.save_btn):
            w.setEnabled(single)
        for w in self.field_edits.values():
            w.setEnabled(single)
        for b in self.bulk_buttons:
            b.setEnabled(n >= 1)

        if n == 0:
            self.preview.clear(); self.preview.setText("")
            self.headline.setText("Nothing selected")
            self.subline.setText("Select a photo or video to see and edit its details. Select several to bulk edit.")
            self.name_edit.clear(); self._set_date(None)
            self.modified_lbl.clear(); self.created_lbl.clear()
            for w in self.field_edits.values():
                self._set_text(w, "")
            self.facts.setText("")
        elif single:
            e = self.entries[0]
            m = meta.get(e.path, {})
            self._set_preview(preview)
            self.headline.setText(e.name)
            d = capture_date(m)
            self.subline.setText(d.strftime("%A, %d %B %Y · %H:%M") if d else "No capture date")
            self.name_edit.setText(e.name)
            self._set_date(d)
            self.modified_lbl.setText(self._fs_date(e.mtime))
            self.created_lbl.setText(self._fs_date(e.ctime))
            for f in FIELDS:
                self._set_text(self.field_edits[f.key], field_value(m, f))
            self.facts.setText(self._facts(e, m))
        else:
            self.preview.clear(); self.preview.setText(f"{n}")
            self.headline.setText(f"{n} items selected")
            photos = sum(1 for e in self.entries if e.kind == "image")
            videos = n - photos
            total = sum(e.size for e in self.entries)
            self.subline.setText(f"{photos} photo{'s' if photos != 1 else ''}, {videos} video{'s' if videos != 1 else ''} · {human_size(total)}")
            self.name_edit.setText("(varies)")
            dates = {capture_date(meta.get(e.path, {})) for e in self.entries}
            self._set_date(next(iter(dates)) if len(dates) == 1 else None)
            mods = sorted(e.mtime for e in self.entries); crs = sorted(e.ctime for e in self.entries)
            self.modified_lbl.setText(self._fs_range(mods))
            self.created_lbl.setText(self._fs_range(crs))
            for f in FIELDS:
                vals = {field_value(meta.get(e.path, {}), f) for e in self.entries}
                self._set_text(self.field_edits[f.key], next(iter(vals)) if len(vals) == 1 else "Mixed")
            self.facts.setText("Use the bulk editors below to change these files together.")
        self._loading = False

    def _set_preview(self, pm: QPixmap | None):
        if pm is None or pm.isNull():
            self.preview.setText("…"); self.preview.setPixmap(QPixmap())
            return
        w = max(200, self.preview.width() - 4)
        self.preview.setPixmap(pm.scaled(w, 260, Qt.KeepAspectRatio, Qt.SmoothTransformation))

    def set_preview_pixmap(self, path: str, pm: QPixmap):
        if len(self.entries) == 1 and self.entries[0].path == path:
            self._set_preview(pm)

    def _set_date(self, d: datetime | None):
        if d:
            self.date_edit.setDateTime(QDateTime(d.year, d.month, d.day, d.hour, d.minute, d.second))
            self.date_clear.setChecked(False)
        else:
            self.date_edit.setDateTime(QDateTime.currentDateTime())
            self.date_clear.setChecked(True)

    @staticmethod
    def _fs_date(ts: float) -> str:
        if not ts:
            return "—"
        return datetime.fromtimestamp(ts).strftime("%Y-%m-%d  %H:%M:%S")

    def _fs_range(self, ts: list[float]) -> str:
        if not ts:
            return "—"
        lo, hi = datetime.fromtimestamp(ts[0]), datetime.fromtimestamp(ts[-1])
        if lo.date() == hi.date():
            return lo.strftime("%Y-%m-%d") + (f"  {lo:%H:%M} – {hi:%H:%M}" if lo != hi else f"  {lo:%H:%M:%S}")
        return f"{lo:%Y-%m-%d} – {hi:%Y-%m-%d}"

    @staticmethod
    def _set_text(w, text: str):
        if isinstance(w, QTextEdit):
            w.setPlainText(text)
        else:
            w.setText(text)

    @staticmethod
    def _text(w) -> str:
        return w.toPlainText().strip() if isinstance(w, QTextEdit) else w.text().strip()

    def _facts(self, e: Entry, m: dict) -> str:
        bits = []
        w, h = m.get("ImageWidth"), m.get("ImageHeight")
        if w and h:
            bits.append(f"{w} × {h} px")
        bits.append(human_size(e.size))
        if m.get("FileType"):
            bits.append(str(m["FileType"]))
        dur = m.get("Duration")
        if isinstance(dur, (int, float)):
            bits.append(f"{int(dur) // 60}:{int(dur) % 60:02d}")
        line1 = " · ".join(bits)
        cam = " ".join(str(m[k]) for k in ("Make", "Model") if m.get(k))
        exp = []
        if m.get("FNumber"):
            exp.append(f"ƒ/{m['FNumber']}")
        if m.get("ExposureTime"):
            t = float(m["ExposureTime"])
            exp.append(f"1/{round(1 / t)} s" if 0 < t < 1 else f"{t:g} s")
        if m.get("ISO"):
            exp.append(f"ISO {m['ISO']}")
        if m.get("FocalLength"):
            exp.append(f"{m['FocalLength']} mm")
        gps = ""
        if m.get("GPSLatitude") is not None and m.get("GPSLongitude") is not None:
            gps = f"GPS {float(m['GPSLatitude']):.5f}, {float(m['GPSLongitude']):.5f}"
        lines = [line1]
        if cam:
            lines.append(cam)
        if exp:
            lines.append(" · ".join(exp))
        if gps:
            lines.append(gps)
        lines.append(os.path.dirname(e.path))
        return "\n".join(lines)

    # -- saving ------------------------------------------------------------------------------------

    def _save(self):
        if len(self.entries) != 1 or self._loading:
            return
        e = self.entries[0]
        m = self.meta.get(e.path, {})
        out = {"path": e.path, "rename": None, "date": None, "clear_date": False, "fields": {}}
        new_name = self.name_edit.text().strip()
        if new_name and new_name != e.name:
            out["rename"] = new_name
        if self.date_clear.isChecked():
            if capture_date(m) is not None:
                out["clear_date"] = True
        else:
            q = self.date_edit.dateTime()
            d = datetime(q.date().year(), q.date().month(), q.date().day(), q.time().hour(), q.time().minute(), q.time().second())
            cur = capture_date(m)
            if cur is None or format_date(cur) != format_date(d):
                out["date"] = d
        for f in FIELDS:
            v = self._text(self.field_edits[f.key])
            if v != field_value(m, f):
                out["fields"][f.key] = v
        self.save_requested.emit(out)
