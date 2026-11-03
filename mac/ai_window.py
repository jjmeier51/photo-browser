"""Edit with AI, Create with AI and the Astria.ai Browser in Safe Finder — the iPhone app's screens
(`AIEditView`, `AICreateView`, `AIResultsView`, `AstriaBrowserView`) on the Mac; astria.py does the talking.

- **Edit with AI** (right-click a photo) / **Create with AI** (right-click a folder): the prompt (with an
  optional negative prompt, the prompting reminder, the two reusable prompts, and the prompt history with
  hearts), the model and up to ten of your own tunes (only the ones that can run on that model), reference
  photos (up to the model's limit — any photos on the Mac or the drive), resolution (1K/2K/4K; Seedream 5.0
  Pro is 2K), dimensions (Original keeps the photo's shape) and how many. Everything is remembered for next
  time, per flow. Generate closes the form and opens the job's window.
- **A job's window** shows where it's at ("2 of 4 ready…"), then the results: each one kept unless clicked
  (a click marks it to throw away), double-click to see it full size. **Save** puts the kept ones in the
  "AI" folder beside the photo (an edit: with its EXIF, place and date, and its tags) or in the folder's
  "AI" folder (a creation). Closing with results unsaved asks first; **Run Again** opens the form as it was.
  A job cut short by quitting is finished the next time Safe Finder's AI is used (its images go straight
  to the folder).
- **The Astria.ai Browser** (right-click a folder): every generation on the account, newest first, a card
  per prompt with its model, date and text; a search field (every word must appear in the prompt or the
  model's name). Click images to pick them (or Select All on a prompt), then **Save to “<last folder>”** or
  **Save to Folder…**; a ✓ marks what's already been saved. Double-click for the full image, its prompt
  (Copy Prompt) and the same saves.

Without an API key every window says so and takes one (kept in the Mac's Keychain); **Astria Settings…**
changes the key, the default model and the models' tune ids.
"""
from __future__ import annotations

import hashlib
import io
import os
import tempfile
import threading
import time
import uuid
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

from PySide6.QtCore import QObject, QPoint, QRect, QRectF, QSettings, QSize, Qt, QTimer, QUrl, Signal
from PySide6.QtGui import (QColor, QDesktopServices, QFont, QFontMetrics, QGuiApplication, QImage, QPainter,
                           QPainterPath, QPen, QPixmap)
from PySide6.QtWidgets import (QButtonGroup, QCheckBox, QComboBox, QDialog, QFileDialog, QFormLayout, QFrame,
                               QHBoxLayout, QLabel, QLineEdit, QListWidget, QListWidgetItem, QMenu, QMessageBox,
                               QPlainTextEdit, QProgressBar, QPushButton, QScrollArea, QSpinBox, QToolButton,
                               QVBoxLayout, QWidget)

import astria as A
from duplicates_window import FlowLayout

CLIENT: Callable[[], A.Client] = lambda: A.Client()          # tests hand in a client on a fake Astria


@dataclass
class AIHooks:
    tags_of: Callable[[str], list[str]] | None = None
    carry_tags: Callable[[list[tuple[str, str]]], None] | None = None   # [(original, new)]
    reveal: Callable[[str], None] | None = None
    view: Callable[[list[str], str], None] | None = None
    keep_open: Callable[[QWidget], None] | None = None                  # Safe Finder holds the window


def _seg(parent: QWidget, options: list[str], current: str) -> tuple[QWidget, QButtonGroup]:
    box = QWidget(parent)
    h = QHBoxLayout(box)
    h.setContentsMargins(0, 0, 0, 0)
    h.setSpacing(4)
    group = QButtonGroup(box)
    for i, o in enumerate(options):
        b = QToolButton()
        b.setObjectName("AISeg")
        b.setText(o)
        b.setCheckable(True)
        b.setChecked(o == current)
        group.addButton(b, i)
        h.addWidget(b)
    h.addStretch(1)
    if group.checkedButton() is None and group.buttons():
        group.buttons()[0].setChecked(True)
    return box, group


def _checked(group: QButtonGroup) -> str:
    b = group.checkedButton()
    return b.text() if b else ""


def _small(text: str, wrap: bool = True) -> QLabel:
    lab = QLabel(text)
    lab.setObjectName("SheetSub")
    lab.setWordWrap(wrap)
    return lab


def _thumb_of(data: bytes, side: int) -> QPixmap | None:
    img = QImage.fromData(data)
    if img.isNull():
        return None
    return QPixmap.fromImage(img.scaled(side, side, Qt.AspectRatioMode.KeepAspectRatio,
                                        Qt.TransformationMode.SmoothTransformation))


def _style(theme) -> str:
    t = theme
    return f"""
        QToolButton#AISeg {{ border: 1px solid {t.button_border}; border-radius: 11px; padding: 3px 11px;
                             background: {t.button}; }}
        QToolButton#AISeg:checked {{ background: {t.accent}; color: white; border-color: {t.accent}; }}
        QToolButton#AISeg:disabled {{ color: {t.tertiary}; }}
        QPlainTextEdit#AIPrompt {{ font-family: -apple-system, "Helvetica Neue", sans-serif; font-size: 13px;
                                   color: {t.text}; background: {t.content}; border: 1px solid {t.button_border};
                                   border-radius: 7px; padding: 4px; }}
        QFrame#AICard {{ background: {t.panel}; border: 1px solid {t.border}; border-radius: 10px; }}
        QScrollArea#AIScroll, QWidget#AIBody {{ background: {t.content}; border: none; }}
        #AIBar {{ background: {t.header}; border-top: 1px solid {t.border}; }}
        QLabel#AIHead {{ font-weight: 600; margin-top: 6px; }}
    """


# ----------------------------------------------------------------------------- the key

class KeyRow(QFrame):
    """The API key, asked for in place when there isn't one."""
    saved = Signal()

    def __init__(self, parent=None) -> None:
        super().__init__(parent)
        self.setObjectName("AICard")
        v = QVBoxLayout(self)
        v.setContentsMargins(12, 10, 12, 10)
        v.addWidget(QLabel("Astria isn't set up on this Mac yet."))
        v.addWidget(_small("Paste your astria.ai API key (Account ▸ API). It's kept in the Mac's Keychain, and "
                           "nothing goes to Astria until you press Generate or open the browser."))
        row = QHBoxLayout()
        self.field = QLineEdit()
        self.field.setEchoMode(QLineEdit.EchoMode.Password)
        self.field.setPlaceholderText("API key")
        row.addWidget(self.field, 1)
        go = QPushButton("Save Key")
        go.setObjectName("Primary")
        go.clicked.connect(self._save)
        row.addWidget(go)
        link = QPushButton("Get a Key…")
        link.clicked.connect(lambda: QDesktopServices.openUrl(QUrl("https://www.astria.ai/users/edit#api")))
        row.addWidget(link)
        v.addLayout(row)

    def _save(self) -> None:
        if self.field.text().strip():
            A.set_key(self.field.text())
            self.saved.emit()


class SettingsDialog(QDialog):
    """Astria Settings…: the key, the default model, each model's tune id."""

    def __init__(self, parent=None) -> None:
        super().__init__(parent)
        self.setWindowTitle("Astria Settings")
        v = QVBoxLayout(self)
        form = QFormLayout()
        self.key = QLineEdit(A.get_key())
        self.key.setEchoMode(QLineEdit.EchoMode.Password)
        form.addRow("API key", self.key)
        self.model = QComboBox()
        self.model.addItems(A.PARTNER_MODELS)
        self.model.setCurrentText(A.default_model())
        form.addRow("Default model", self.model)
        self.ids: dict[str, QSpinBox] = {}
        for m in A.MODELS:
            sb = QSpinBox()
            sb.setRange(1, 99_999_999)
            sb.setValue(A.tune_id(m))
            self.ids[m] = sb
            form.addRow(f"{m} tune" if m != "Flux" else "Flux (base) tune", sb)
        v.addLayout(form)
        v.addWidget(_small("Tune ids are Astria's gallery models; change one only if Astria moves a model."))
        row = QHBoxLayout()
        row.addStretch(1)
        cancel = QPushButton("Cancel")
        cancel.clicked.connect(self.reject)
        ok = QPushButton("Save")
        ok.setObjectName("Primary")
        ok.clicked.connect(self._save)
        row.addWidget(cancel)
        row.addWidget(ok)
        v.addLayout(row)

    def _save(self) -> None:
        if self.key.text().strip() != A.get_key():
            A.set_key(self.key.text())
        A.store().set("default_model", self.model.currentText())
        for m, sb in self.ids.items():
            A.set_tune_id(m, sb.value())
        self.accept()


# ----------------------------------------------------------------------------- jobs

@dataclass
class Job:
    id: str
    mode: str                                      # "edit" | "create"
    prompt: str                                    # as sent (negative included)
    model_label: str
    gen: A.Generation
    count: int
    aspect: str | None
    resolution: str | None
    source: str = ""                               # an edit's photo
    folder: str = ""                               # a creation's folder
    references: list[str] = field(default_factory=list)
    settings: dict = field(default_factory=dict)   # the form, for Run Again
    images: list[bytes] = field(default_factory=list)
    error: A.AIError | None = None
    note: str = ""
    done: bool = False


class Jobs(QObject):
    """Every AI job of this run (one thread each), and the jobs a quit cut short."""
    progress = Signal(str, str)                    # job id, what's happening
    finished = Signal(str)                         # job id
    recovered = Signal(str)                        # a sentence: what was finished from last time

    def __init__(self) -> None:
        super().__init__()
        self.jobs: dict[str, Job] = {}
        self.resumed = False

    def start(self, job: Job) -> None:
        self.jobs[job.id] = job
        threading.Thread(target=self._run, args=(job,), daemon=True).start()
        self.resume()

    def _run(self, job: Job) -> None:
        client = CLIENT()
        try:
            image, w, h = None, None, None
            if job.mode == "edit":
                self.progress.emit(job.id, "Preparing the photo…")
                up = 1024 if job.resolution == "1K" else 2048
                image, w, h = A.upload_jpeg(job.source, up)
            refs = []
            if job.references:
                self.progress.emit(job.id, f"Preparing {len(job.references)} reference photo"
                                   f"{'s' if len(job.references) != 1 else ''} on Astria…")
                for p in job.references:
                    try:
                        refs.append(A.reference(p))
                    except (OSError, A.AIError):
                        pass
            self.progress.emit(job.id, "Sending to Astria…")

            def on_prompt(pid: int) -> None:
                A.note_pending({"job": job.id, "prompt_id": pid, "tune": job.gen.tune_id, "count": job.count,
                                "source": job.source, "folder": job.folder, "model": job.model_label,
                                "prompt": job.prompt, "started": time.time()})

            def beat(ready: int, want: int | None) -> None:
                self.progress.emit(job.id, f"Astria is working on it — {ready} of {want or job.count} ready…"
                                   if ready else "Astria is working on it…")

            def note(text: str) -> None:
                job.note = text
            job.images = client.generate(job.gen.tune_id, job.prompt, image, job.count, w, h, job.aspect,
                                         job.resolution, job.gen.token, refs, on_prompt, beat, note)
            if len(job.images) < job.count:
                job.note = (job.note + " " if job.note else "") + \
                    f"Astria returned {len(job.images)} of {job.count} images."
        except A.AIError as e:
            job.error = e
            if not e.recoverable:
                A.drop_pending(job.id)
        except Exception as e:  # noqa: BLE001 — anything else reads as a refusal, never a crash
            job.error = A.AIError("server", str(e))
            A.drop_pending(job.id)
        job.done = True
        self.finished.emit(job.id)

    def resume(self) -> None:
        """Once a run: finish what a quit cut short (quietly; only saves are reported)."""
        if self.resumed:
            return
        self.resumed = True
        busy = set(self.jobs)

        def work() -> None:
            try:
                done = A.resume_pending(CLIENT(), busy)
            except Exception:  # noqa: BLE001
                return
            saved = sum(len(s) for _j, s in done)
            if saved:
                self.recovered.emit(f"Saved {saved} AI image{'s' if saved != 1 else ''} from a generation that "
                                    "was still running when Safe Finder last closed.")
        threading.Thread(target=work, daemon=True).start()


_JOBS: Jobs | None = None


def jobs() -> Jobs:
    global _JOBS
    if _JOBS is None:
        _JOBS = Jobs()
    return _JOBS


# ----------------------------------------------------------------------------- the form

class _TunesLoader(QObject):
    loaded = Signal(object)


class RequestWindow(QWidget):
    """Edit with AI (a photo) or Create with AI (a folder)."""

    def __init__(self, mode: str, target: str, hooks: AIHooks, theme, parent=None,
                 settings: dict | None = None) -> None:
        super().__init__(parent, Qt.WindowType.Window)
        self.setAttribute(Qt.WidgetAttribute.WA_DeleteOnClose)
        self.mode, self.target, self.hooks, self.theme = mode, target, hooks, theme
        self.all_tunes: list[A.Tune] = []
        self.picked_tunes: list[int] = []
        self.refs: list[str] = []
        self.setWindowTitle("Edit with AI" if mode == "edit" else "Create with AI")
        self.setStyleSheet(_style(theme))
        self.resize(640, 860)
        s = settings or A.store().get(f"run_{mode}", {}) or {}
        self._build(s)
        self._load_tunes()

    # -- layout
    def _build(self, s: dict) -> None:
        outer = QVBoxLayout(self)
        outer.setContentsMargins(0, 0, 0, 0)
        outer.setSpacing(0)
        scroll = QScrollArea()
        scroll.setObjectName("AIScroll")
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.Shape.NoFrame)
        body = QWidget()
        body.setObjectName("AIBody")
        v = QVBoxLayout(body)
        v.setContentsMargins(18, 16, 18, 16)
        v.setSpacing(8)
        head = QHBoxLayout()
        title = QLabel("Edit with AI" if self.mode == "edit" else "Create with AI")
        title.setObjectName("SheetTitle")
        head.addWidget(title, 1)
        gear = QPushButton("Astria Settings…")
        gear.clicked.connect(self._settings)
        head.addWidget(gear)
        v.addLayout(head)
        if self.mode == "edit":
            row = QHBoxLayout()
            self.preview = QLabel()
            self.preview.setFixedSize(96, 96)
            self.preview.setAlignment(Qt.AlignmentFlag.AlignCenter)
            row.addWidget(self.preview)
            row.addWidget(_small(f"“{os.path.basename(self.target)}” — the results go into an “AI” folder beside "
                                 "it, with its date, place and tags."), 1)
            v.addLayout(row)
            QTimer.singleShot(0, self._load_preview)
        else:
            v.addWidget(_small(f"Into an “AI” folder in “{os.path.basename(self.target) or self.target}”."))
        self.key_row = KeyRow()
        self.key_row.saved.connect(self._key_saved)
        self.key_row.setVisible(not A.get_key())
        v.addWidget(self.key_row)
        v.addWidget(self._head("What would you like to change?" if self.mode == "edit" else "Describe the image"))
        self.prompt = QPlainTextEdit(s.get("prompt", ""))
        self.prompt.setObjectName("AIPrompt")
        self.prompt.setPlaceholderText("e.g. make the sky a sunset, remove the sign…" if self.mode == "edit"
                                       else "e.g. a woman on a balcony in Positano at golden hour, film photo…")
        self.prompt.setFixedHeight(96)
        self.prompt.textChanged.connect(self._update)
        v.addWidget(self.prompt)
        neg = QHBoxLayout()
        self.neg_on = QCheckBox("Negative prompt")
        self.neg_on.setChecked(bool(s.get("negative_on")))
        self.neg = QLineEdit(s.get("negative", ""))
        self.neg.setPlaceholderText("what to leave out — sent as “Negative Prompt: …” in the text")
        self.neg.setEnabled(self.neg_on.isChecked())
        self.neg_on.toggled.connect(self.neg.setEnabled)
        neg.addWidget(self.neg_on)
        neg.addWidget(self.neg, 1)
        v.addLayout(neg)
        v.addWidget(_small("💡 " + A.PROMPTING_REMINDER))
        v.addWidget(self._head("Reusable prompts"))
        for p in A.REUSABLE_PROMPTS:
            row = QHBoxLayout()
            lab = _small(p[:110] + ("…" if len(p) > 110 else ""), wrap=True)
            lab.setToolTip(p)
            row.addWidget(lab, 1)
            use = QPushButton("Use")
            use.clicked.connect(lambda _=False, p=p: self.prompt.setPlainText(p))
            copy = QPushButton("Copy")
            copy.clicked.connect(lambda _=False, p=p: QGuiApplication.clipboard().setText(p))
            row.addWidget(use)
            row.addWidget(copy)
            v.addLayout(row)
        hist_head = QHBoxLayout()
        self.hist_title = self._head("Recent prompts")
        hist_head.addWidget(self.hist_title, 1)
        self.hist_mode, self.hist_group = _seg(self, ["All", "♥ Favorites"], "All")
        self.hist_group.idClicked.connect(lambda _i: self._fill_history())
        hist_head.addWidget(self.hist_mode)
        v.addLayout(hist_head)
        self.history = QListWidget()
        self.history.setFixedHeight(120)
        self.history.itemDoubleClicked.connect(lambda it: self.prompt.setPlainText(it.data(Qt.ItemDataRole.UserRole)))
        self.history.setContextMenuPolicy(Qt.ContextMenuPolicy.CustomContextMenu)
        self.history.customContextMenuRequested.connect(self._history_menu)
        v.addWidget(self.history)
        self.hist_hint = _small("Double-click a prompt to use it; right-click to ♥ it (hearted prompts are kept).")
        v.addWidget(self.hist_hint)
        self._fill_history()
        v.addWidget(self._head("Model & tunes"))
        mrow = QHBoxLayout()
        self.model = QComboBox()
        self.model.addItems(list(A.MODELS))
        self.model.setCurrentText(s.get("model") if s.get("model") in A.MODELS else A.default_model())
        self.model.currentTextChanged.connect(self._model_changed)
        mrow.addWidget(self.model)
        mrow.addStretch(1)
        v.addLayout(mrow)
        self.tunes = QListWidget()
        self.tunes.setFixedHeight(110)
        self.tunes.itemChanged.connect(self._tune_toggled)
        v.addWidget(self.tunes)
        self.combo_note = _small("")
        v.addWidget(self.combo_note)
        self.picked_tunes = [int(x) for x in s.get("tunes", []) if str(x).isdigit()]
        v.addWidget(self._head("References"))
        rrow = QHBoxLayout()
        self.ref_btn = QPushButton("Add Reference Photos…")
        self.ref_btn.clicked.connect(self._add_refs)
        rrow.addWidget(self.ref_btn)
        self.ref_count = _small("", wrap=False)
        rrow.addWidget(self.ref_count, 1)
        v.addLayout(rrow)
        self.ref_strip = QHBoxLayout()
        self.ref_strip.setSpacing(6)
        strip = QWidget()
        strip.setLayout(self.ref_strip)
        v.addWidget(strip)
        self.refs = [p for p in s.get("references", []) if os.path.exists(p) and p != self.target]
        v.addWidget(self._head("Output"))
        form = QFormLayout()
        self.res_box, self.res = _seg(self, list(A.RESOLUTIONS), s.get("resolution", "2K"))
        form.addRow("Resolution", self.res_box)
        aspects = list(A.ASPECTS) if self.mode == "edit" else [a for a in A.ASPECTS if a != "Original"]
        self.asp_box, self.asp = _seg(self, aspects, s.get("aspect", "Original" if self.mode == "edit" else "1:1"))
        form.addRow("Dimensions", self.asp_box)
        self.cnt_box, self.cnt = _seg(self, [str(c) for c in A.COUNTS], str(s.get("count", 1)))
        form.addRow("How many", self.cnt_box)
        v.addLayout(form)
        v.addStretch(1)
        scroll.setWidget(body)
        outer.addWidget(scroll, 1)
        bar = QFrame()
        bar.setObjectName("AIBar")
        bh = QHBoxLayout(bar)
        bh.setContentsMargins(16, 10, 16, 10)
        self.status = _small("", wrap=False)
        bh.addWidget(self.status, 1)
        cancel = QPushButton("Cancel")
        cancel.clicked.connect(self.close)
        self.go = QPushButton("Generate")
        self.go.setObjectName("Primary")
        self.go.setDefault(True)
        self.go.clicked.connect(self.generate)
        bh.addWidget(cancel)
        bh.addWidget(self.go)
        outer.addWidget(bar)
        self._refs_changed()
        self._model_changed(self.model.currentText())

    def _head(self, text: str) -> QLabel:
        lab = QLabel(text)
        lab.setObjectName("AIHead")
        return lab

    def _load_preview(self) -> None:
        try:
            data, _w, _h = A.upload_jpeg(self.target, 256)
        except A.AIError:
            return
        pm = _thumb_of(data, 96)
        if pm is not None:
            self.preview.setPixmap(pm)

    def _settings(self) -> None:
        if SettingsDialog(self).exec():
            self.key_row.setVisible(not A.get_key())
            self._load_tunes()
            self._update()

    def _key_saved(self) -> None:
        self.key_row.setVisible(False)
        self._load_tunes()
        self._update()

    # -- history
    def _fill_history(self) -> None:
        favs = set(A.store().get("favorites", []) or [])
        only_favs = _checked(self.hist_group).startswith("♥")
        self.history.clear()
        for p in A.store().get("history", []) or []:
            if only_favs and p not in favs:
                continue
            it = QListWidgetItem(("♥ " if p in favs else "") + p.replace("\n", " ")[:160])
            it.setData(Qt.ItemDataRole.UserRole, p)
            it.setToolTip(p)
            self.history.addItem(it)
        has = bool(A.store().get("history"))              # no history yet: no section (as on the iPhone)
        for w in (self.hist_title, self.hist_mode, self.history, self.hist_hint):
            w.setVisible(has)

    def _history_menu(self, pos) -> None:
        it = self.history.itemAt(pos)
        if it is None:
            return
        p = it.data(Qt.ItemDataRole.UserRole)
        favs = set(A.store().get("favorites", []) or [])
        menu = QMenu(self)
        menu.addAction("Use", lambda: self.prompt.setPlainText(p))
        menu.addAction("Unfavorite" if p in favs else "♥ Favorite", lambda: (A.toggle_favorite(p), self._fill_history()))
        menu.addAction("Copy", lambda: QGuiApplication.clipboard().setText(p))
        menu.addAction("Remove from History", lambda: (
            A.store().update("history", lambda h: [x for x in (h or []) if x != p]),
            A.store().update("favorites", lambda f: [x for x in (f or []) if x != p]), self._fill_history()))
        menu.exec(self.history.viewport().mapToGlobal(pos))

    # -- tunes and model
    def _load_tunes(self) -> None:
        if not A.get_key():
            self._fill_tunes()
            return
        loader = self._loader = _TunesLoader()
        loader.loaded.connect(self._tunes_loaded)
        self.tunes.clear()
        self.tunes.addItem("Loading your tunes…")

        def work() -> None:
            try:
                loader.loaded.emit(CLIENT().list_tunes())
            except Exception:  # noqa: BLE001
                loader.loaded.emit([])
        threading.Thread(target=work, daemon=True).start()

    def _tunes_loaded(self, tunes) -> None:
        self.all_tunes = list(tunes)
        self._fill_tunes()

    def _fill_tunes(self) -> None:
        self.tunes.blockSignals(True)
        self.tunes.clear()
        usable = A.compatible(self.all_tunes, self.model.currentText())
        ids = {t.id for t in usable}
        self.picked_tunes = [i for i in self.picked_tunes if i in ids] if self.all_tunes else self.picked_tunes
        if not usable:
            it = QListWidgetItem("No tunes of yours run on this model — it runs on its own."
                                 if self.all_tunes or not A.get_key() else "No tunes on your account.")
            it.setFlags(Qt.ItemFlag.NoItemFlags)
            self.tunes.addItem(it)
        for t in usable:
            it = QListWidgetItem(t.label + ("" if t.ready else " (still training)") +
                                 (f" — “{t.trigger}”" if t.trigger else ""))
            it.setFlags(Qt.ItemFlag.ItemIsUserCheckable | Qt.ItemFlag.ItemIsEnabled)
            it.setCheckState(Qt.CheckState.Checked if t.id in self.picked_tunes else Qt.CheckState.Unchecked)
            it.setData(Qt.ItemDataRole.UserRole, t.id)
            self.tunes.addItem(it)
        self.tunes.blockSignals(False)
        self._update()

    def _tune_toggled(self, it: QListWidgetItem) -> None:
        tid = it.data(Qt.ItemDataRole.UserRole)
        if tid is None:
            return
        if it.checkState() == Qt.CheckState.Checked:
            if tid not in self.picked_tunes:
                if len(self.picked_tunes) >= A.MAX_TUNES:
                    self.tunes.blockSignals(True)
                    it.setCheckState(Qt.CheckState.Unchecked)
                    self.tunes.blockSignals(False)
                    self.status.setText(f"At most {A.MAX_TUNES} tunes at once.")
                    return
                self.picked_tunes.append(tid)
        elif tid in self.picked_tunes:
            self.picked_tunes.remove(tid)
        self._update()

    def _model_changed(self, model: str) -> None:
        self._fill_tunes()
        limit = A.MODELS[model][1]
        if len(self.refs) > limit:
            self.refs = self.refs[:limit]
            self._refs_changed()
        self._update()

    def _selected(self) -> list[A.Tune]:
        by = {t.id: t for t in self.all_tunes}
        return [by[i] for i in self.picked_tunes if i in by]

    def _update(self) -> None:
        model = self.model.currentText()
        gen = A.resolve_generation(model, self._selected())
        pinned = A.MODELS[model][2]
        for b in self.res.buttons():
            b.setEnabled(gen.supports_resolution and pinned is None)
            if pinned is not None:
                b.setChecked(b.text() == pinned)
        if not gen.supports_resolution:
            note = f"{gen.label} — Flux takes no resolution choice."
        elif pinned:
            note = f"{gen.label} — always {pinned} on Astria."
        else:
            note = f"Runs on {gen.label}."
        tunes = self._selected()
        if len(tunes) > 1:
            note += " The tunes are combined in one image, in the order picked."
        self.combo_note.setText(note)
        limit = A.MODELS[model][1]
        self.ref_btn.setEnabled(limit > 0 and len(self.refs) < limit)
        self.ref_count.setText(f"{len(self.refs)} of {limit}" if limit else "Flux takes no reference photos.")
        ready = bool(A.get_key()) and bool(self.prompt.toPlainText().strip())
        self.go.setEnabled(ready)
        if not A.get_key():
            self.status.setText("Add your Astria API key first.")
        elif not self.prompt.toPlainText().strip():
            self.status.setText("Write a prompt.")
        else:
            self.status.setText("")

    # -- references
    def _add_refs(self) -> None:
        limit = A.MODELS[self.model.currentText()][1]
        start = os.path.dirname(self.refs[-1]) if self.refs else (os.path.dirname(self.target)
                                                                   if self.mode == "edit" else self.target)
        files, _f = QFileDialog.getOpenFileNames(self, "Reference Photos", start,
                                                 "Photos (*.jpg *.jpeg *.png *.heic *.heif *.webp *.tif *.tiff)")
        for f in files:
            if f != self.target and f not in self.refs and len(self.refs) < limit:
                self.refs.append(f)
        self._refs_changed()

    def _refs_changed(self) -> None:
        while self.ref_strip.count():
            it = self.ref_strip.takeAt(0)
            w = it.widget()
            if w is not None:              # keep a hold until it's gone
                w.setParent(None)
                w.deleteLater()
        for i, p in enumerate(self.refs):
            b = QToolButton()
            b.setToolTip(f"{i + 1}. {os.path.basename(p)} — click to remove")
            b.setText(f"{i + 1} ✕")
            b.setFixedSize(64, 64)
            try:
                data, _w, _h = A.upload_jpeg(p, 128)
                pm = _thumb_of(data, 60)
                if pm is not None:
                    b.setIcon(pm)
                    b.setIconSize(QSize(56, 56))
                    b.setText("")
            except A.AIError:
                pass
            b.clicked.connect(lambda _=False, p=p: (self.refs.remove(p), self._refs_changed()))
            self.ref_strip.addWidget(b)
        self.ref_strip.addStretch(1)
        self._update()

    # -- go
    def form(self) -> dict:
        return {"prompt": self.prompt.toPlainText(), "negative_on": self.neg_on.isChecked(), "negative": self.neg.text(),
                "model": self.model.currentText(), "tunes": list(self.picked_tunes), "references": list(self.refs),
                "resolution": _checked(self.res), "aspect": _checked(self.asp), "count": int(_checked(self.cnt) or 1)}

    def generate(self) -> Job | None:
        s = self.form()
        if not A.get_key() or not s["prompt"].strip():
            return None
        A.store().set(f"run_{self.mode}", s)
        A.record_prompt(s["prompt"])
        model = s["model"]
        gen = A.resolve_generation(model, self._selected())
        pinned = A.MODELS[model][2]
        resolution = (pinned or s["resolution"]) if gen.supports_resolution else None
        text = gen.prefix + A.compose_prompt(s["prompt"], s["negative"] if s["negative_on"] else None)
        aspect = A.ASPECTS.get(s["aspect"]) if self.mode == "edit" else (A.ASPECTS.get(s["aspect"]) or "1:1")
        job = Job(uuid.uuid4().hex, self.mode, text, gen.label, gen, s["count"], aspect, resolution,
                  source=self.target if self.mode == "edit" else "",
                  folder=self.target if self.mode == "create" else "",
                  references=list(s["references"]) if A.MODELS[model][1] else [], settings=s)
        win = ResultsWindow(job, self.hooks, self.theme, self.parentWidget())
        if self.hooks.keep_open:
            self.hooks.keep_open(win)
        win.show()
        jobs().start(job)
        self.close()
        return job


# ----------------------------------------------------------------------------- a job's results

class _Result(QWidget):
    """One result: kept unless clicked (then a red ✕); double-click to see it full size."""
    toggled = Signal()
    opened = Signal(int)

    def __init__(self, i: int, data: bytes, side: int, parent=None) -> None:
        super().__init__(parent)
        self.i, self.data, self.keep = i, data, True
        self.pm = _thumb_of(data, side)
        self.setFixedSize(side, side)
        self.setCursor(Qt.CursorShape.PointingHandCursor)
        self.setToolTip("Click to throw this one away (click again to keep it); double-click to see it full size")

    def mousePressEvent(self, e) -> None:  # noqa: N802
        if e.button() == Qt.MouseButton.LeftButton:
            self.keep = not self.keep
            self.update()
            self.toggled.emit()

    def mouseDoubleClickEvent(self, e) -> None:  # noqa: N802
        self.keep = not self.keep                       # the double-click's first click doesn't count
        self.update()
        self.toggled.emit()
        self.opened.emit(self.i)

    def paintEvent(self, _e) -> None:  # noqa: N802
        p = QPainter(self)
        p.setRenderHint(QPainter.RenderHint.Antialiasing)
        r = QRectF(self.rect())
        path = QPainterPath()
        path.addRoundedRect(r, 8, 8)
        p.fillPath(path, QColor("#2C2C2E"))
        if self.pm is not None:
            x = (self.width() - self.pm.width()) / 2
            y = (self.height() - self.pm.height()) / 2
            p.save()
            p.setClipPath(path)
            p.drawPixmap(int(x), int(y), self.pm)
            if not self.keep:
                p.fillRect(r, QColor(0, 0, 0, 120))
            p.restore()
        d = 30
        ring = QRectF(self.width() - d - 8, 8, d, d)
        p.setPen(QPen(QColor("white"), 2))
        p.setBrush(QColor("#30D158") if self.keep else QColor("#FF453A"))
        p.drawEllipse(ring)
        p.setPen(QPen(QColor("white"), 2.6, Qt.PenStyle.SolidLine, Qt.PenCapStyle.RoundCap))
        c = ring.center()
        if self.keep:
            path2 = QPainterPath()
            path2.moveTo(ring.left() + d * 0.28, ring.top() + d * 0.53)
            path2.lineTo(ring.left() + d * 0.44, ring.top() + d * 0.69)
            path2.lineTo(ring.left() + d * 0.74, ring.top() + d * 0.34)
            p.setBrush(Qt.BrushStyle.NoBrush)
            p.drawPath(path2)
        else:
            p.drawLine(QPoint(int(c.x() - 6), int(c.y() - 6)), QPoint(int(c.x() + 6), int(c.y() + 6)))
            p.drawLine(QPoint(int(c.x() + 6), int(c.y() - 6)), QPoint(int(c.x() - 6), int(c.y() + 6)))
        if not self.keep:
            p.setPen(QColor("white"))
            f = QFont(self.font())
            f.setWeight(QFont.Weight.DemiBold)
            p.setFont(f)
            p.drawText(r, Qt.AlignmentFlag.AlignCenter, "Won't be saved")
        p.end()


class ResultsWindow(QWidget):
    def __init__(self, job: Job, hooks: AIHooks, theme, parent=None) -> None:
        super().__init__(parent, Qt.WindowType.Window)
        self.setAttribute(Qt.WidgetAttribute.WA_DeleteOnClose)
        self.job, self.hooks, self.theme = job, hooks, theme
        self.saved: list[str] = []
        self.tiles: list[_Result] = []
        self.setWindowTitle(("Edit with AI — " + os.path.basename(job.source)) if job.mode == "edit"
                            else "Create with AI")
        self.setStyleSheet(_style(theme))
        self.resize(900, 720)
        v = QVBoxLayout(self)
        v.setContentsMargins(0, 0, 0, 0)
        v.setSpacing(0)
        top = QFrame()
        tv = QVBoxLayout(top)
        tv.setContentsMargins(18, 14, 18, 10)
        self.title = QLabel(job.model_label)
        self.title.setObjectName("SheetTitle")
        tv.addWidget(self.title)
        shown = job.settings.get("prompt", job.prompt)
        pl = _small(shown if len(shown) < 400 else shown[:400] + "…")
        pl.setToolTip(job.prompt)
        tv.addWidget(pl)
        self.state = _small("Starting…")
        tv.addWidget(self.state)
        self.bar = QProgressBar()
        self.bar.setRange(0, 0)
        tv.addWidget(self.bar)
        v.addWidget(top)
        scroll = QScrollArea()
        scroll.setObjectName("AIScroll")
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.Shape.NoFrame)
        self.body = QWidget()
        self.body.setObjectName("AIBody")
        self.flow = FlowLayout(self.body, 12)
        self.flow.setContentsMargins(18, 14, 18, 14)
        scroll.setWidget(self.body)
        v.addWidget(scroll, 1)
        bar = QFrame()
        bar.setObjectName("AIBar")
        bh = QHBoxLayout(bar)
        bh.setContentsMargins(16, 10, 16, 10)
        self.summary = _small("", wrap=False)
        bh.addWidget(self.summary, 1)
        self.again = QPushButton("Run Again")
        self.again.clicked.connect(self.run_again)
        self.show_btn = QPushButton("Show in Safe Finder")
        self.show_btn.setVisible(False)
        self.show_btn.clicked.connect(lambda: self.hooks.reveal(self.saved[0]) if self.saved and self.hooks.reveal else None)
        self.save_btn = QPushButton("Save")
        self.save_btn.setObjectName("Primary")
        self.save_btn.setEnabled(False)
        self.save_btn.clicked.connect(self.save)
        for b in (self.again, self.show_btn, self.save_btn):
            bh.addWidget(b)
        v.addWidget(bar)
        jobs().progress.connect(self._progress)
        jobs().finished.connect(self._finished)
        if job.done:
            QTimer.singleShot(0, lambda: self._finished(job.id))

    def _progress(self, jid: str, text: str) -> None:
        if jid == self.job.id:
            self.state.setText(text)

    def _finished(self, jid: str) -> None:
        if jid != self.job.id:
            return
        self.bar.setVisible(False)
        job = self.job
        if job.error is not None and not job.images:
            self.state.setText(job.error.describe() + (f" ({job.error.message})" if job.error.kind == "server"
                                                         and job.error.message not in job.error.describe() else ""))
            self.summary.setText("")
            return
        self.state.setText(job.note or f"{len(job.images)} result{'s' if len(job.images) != 1 else ''} — "
                           "click one to leave it out, double-click to see it full size.")
        side = 260
        for i, data in enumerate(job.images):
            t = _Result(i, data, side, self.body)
            t.toggled.connect(self._update)
            t.opened.connect(self._open)
            self.flow.addWidget(t)
            self.tiles.append(t)
        self._update()

    def _update(self) -> None:
        keep = sum(1 for t in self.tiles if t.keep)
        if self.saved:
            return
        self.save_btn.setText(f"Save {keep}" if keep else "Save")
        self.save_btn.setEnabled(keep > 0)
        where = "the “AI” folder beside the photo" if self.job.mode == "edit" else \
            f"“{os.path.basename(self.job.folder)}/AI”"
        self.summary.setText(f"{keep} of {len(self.tiles)} kept — saved into {where}." if self.tiles else "")

    def _open(self, i: int) -> None:
        """Full size: through the viewer, from a temporary copy."""
        tmp = Path(tempfile.gettempdir()) / "SafeFinderAI" / self.job.id
        tmp.mkdir(parents=True, exist_ok=True)
        paths = []
        for k, t in enumerate(self.tiles):
            p = tmp / f"Result {k + 1}.jpg"
            if not p.exists():
                p.write_bytes(t.data)
            paths.append(str(p))
        if self.hooks.view is not None:
            self.hooks.view(paths, paths[i])
        else:
            QDesktopServices.openUrl(QUrl.fromLocalFile(paths[i]))

    def save(self) -> list[str]:
        kept = [t.data for t in self.tiles if t.keep]
        out, failed = [], 0
        for data in kept:
            try:
                if self.job.mode == "edit":
                    out.append(A.save_edit(data, self.job.source, self.job.model_label, self.job.settings.get("prompt", "")))
                else:
                    out.append(A.save_created(data, self.job.folder, self.job.model_label,
                                              self.job.settings.get("prompt", "")))
            except (OSError, ValueError) as e:
                failed += 1
                self.state.setText(f"Couldn't save one: {e}")
        if out and self.job.mode == "edit" and self.hooks.carry_tags is not None:
            self.hooks.carry_tags([(self.job.source, p) for p in out])
        A.drop_pending(self.job.id)
        self.saved = out
        self.save_btn.setEnabled(False)
        self.save_btn.setText("Saved")
        self.show_btn.setVisible(bool(out) and self.hooks.reveal is not None)
        folder = os.path.dirname(out[0]) if out else ""
        self.summary.setText(f"Saved {len(out)} into “{os.path.basename(folder)}”." +
                             (f" {failed} couldn't be saved." if failed else ""))
        return out

    def run_again(self) -> None:
        win = RequestWindow(self.job.mode, self.job.source or self.job.folder, self.hooks, self.theme,
                            self.parentWidget(), settings=self.job.settings)
        if self.hooks.keep_open:
            self.hooks.keep_open(win)
        win.show()

    def closeEvent(self, event) -> None:  # noqa: N802
        unsaved = [t for t in self.tiles if t.keep] if not self.saved else []
        if unsaved:
            box = QMessageBox(self)
            box.setWindowTitle("Unsaved results")
            box.setText(f"Save the {len(unsaved)} kept result{'s' if len(unsaved) != 1 else ''} before closing?")
            save = box.addButton("Save", QMessageBox.ButtonRole.AcceptRole)
            discard = box.addButton("Don't Save", QMessageBox.ButtonRole.DestructiveRole)
            box.addButton(QMessageBox.StandardButton.Cancel)
            box.setDefaultButton(save)
            box.exec()
            if box.clickedButton() is save:
                self.save()
            elif box.clickedButton() is discard:
                A.drop_pending(self.job.id)
            else:
                event.ignore()
                return
        elif not self.job.done:
            pass                                          # still running: the job finishes and is kept for later
        try:
            jobs().progress.disconnect(self._progress)
            jobs().finished.disconnect(self._finished)
        except (RuntimeError, TypeError):
            pass
        super().closeEvent(event)


# ----------------------------------------------------------------------------- the Astria.ai Browser

class _BrowserBridge(QObject):
    listed = Signal(object, object)                # prompts, tunes
    thumb = Signal(str, bytes)
    saved = Signal(int, int, str)                  # done, total, last file ("" on failure)
    save_done = Signal(int, int, str)              # saved, failed, folder


def _cache_name(url: str) -> Path:
    return A.THUMB_CACHE / (hashlib.sha256(url.split("?")[0].encode()).hexdigest() + ".jpg")


class _Tile(QWidget):
    toggled = Signal(str)
    opened = Signal(str)

    def __init__(self, url: str, browser: "BrowserWindow") -> None:
        super().__init__()
        self.url, self.browser = url, browser
        self.setFixedSize(150, 150)
        self.setCursor(Qt.CursorShape.PointingHandCursor)

    def mousePressEvent(self, e) -> None:  # noqa: N802
        if e.button() == Qt.MouseButton.LeftButton:
            self.toggled.emit(self.url)

    def mouseDoubleClickEvent(self, e) -> None:  # noqa: N802
        self.toggled.emit(self.url)
        self.opened.emit(self.url)

    def paintEvent(self, _e) -> None:  # noqa: N802
        b = self.browser
        p = QPainter(self)
        p.setRenderHint(QPainter.RenderHint.Antialiasing)
        r = QRectF(self.rect())
        path = QPainterPath()
        path.addRoundedRect(r, 8, 8)
        p.fillPath(path, QColor("#2C2C2E") if b.theme.dark else QColor("#E5E5EA"))
        pm = b.thumbs.get(self.url)
        if pm is not None:
            p.save()
            p.setClipPath(path)
            s = max(r.width() / pm.width(), r.height() / pm.height())
            sw, sh = r.width() / s, r.height() / s
            p.drawPixmap(r, pm, QRectF((pm.width() - sw) / 2, (pm.height() - sh) / 2, sw, sh))
            p.restore()
        else:
            b.want(self.url)
        if self.url in b.selected:
            p.setPen(QPen(QColor(b.theme.accent), 4))
            p.setBrush(Qt.BrushStyle.NoBrush)
            p.drawRoundedRect(r.adjusted(2, 2, -2, -2), 7, 7)
        if b.is_saved(self.url):
            d = 24
            ring = QRectF(self.width() - d - 6, self.height() - d - 6, d, d)
            p.setPen(QPen(QColor("white"), 1.5))
            p.setBrush(QColor("#30D158"))
            p.drawEllipse(ring)
            p.setPen(QPen(QColor("white"), 2.2, Qt.PenStyle.SolidLine, Qt.PenCapStyle.RoundCap))
            path2 = QPainterPath()
            path2.moveTo(ring.left() + d * 0.28, ring.top() + d * 0.53)
            path2.lineTo(ring.left() + d * 0.44, ring.top() + d * 0.69)
            path2.lineTo(ring.left() + d * 0.74, ring.top() + d * 0.34)
            p.setBrush(Qt.BrushStyle.NoBrush)
            p.drawPath(path2)
        p.end()


class BrowserWindow(QWidget):
    PAGE = 25

    def __init__(self, folder: str, hooks: AIHooks, theme, parent=None) -> None:
        super().__init__(parent, Qt.WindowType.Window)
        self.setAttribute(Qt.WidgetAttribute.WA_DeleteOnClose)
        self.folder, self.hooks, self.theme = folder, hooks, theme
        self.prompts: list[A.Prompt] = []
        self.tunes: list[A.Tune] = []
        self.thumbs: dict[str, QPixmap] = {}
        self.wanted: set[str] = set()
        self.selected: set[str] = set()
        self.shown = self.PAGE
        self.tiles: list[_Tile] = []
        self.pool = ThreadPoolExecutor(max_workers=6)
        self.stop = threading.Event()
        self.bridge = _BrowserBridge()
        self.bridge.listed.connect(self._listed)
        self.bridge.thumb.connect(self._thumb)
        self.bridge.saved.connect(self._save_progress)
        self.bridge.save_done.connect(self._save_done)
        self.setWindowTitle("Astria.ai Browser")
        self.setStyleSheet(_style(theme))
        self.resize(1040, 800)
        v = QVBoxLayout(self)
        v.setContentsMargins(0, 0, 0, 0)
        v.setSpacing(0)
        top = QFrame()
        tv = QVBoxLayout(top)
        tv.setContentsMargins(18, 14, 18, 10)
        row = QHBoxLayout()
        title = QLabel("Astria.ai Browser")
        title.setObjectName("SheetTitle")
        row.addWidget(title, 1)
        self.search = QLineEdit()
        self.search.setObjectName("Search")
        self.search.setPlaceholderText("Search prompts")
        self.search.setClearButtonEnabled(True)
        self.search.setFixedWidth(260)
        self.search.textChanged.connect(lambda _t: self._render(reset=True))
        row.addWidget(self.search)
        reload_btn = QPushButton("Reload")
        reload_btn.clicked.connect(self.reload)
        row.addWidget(reload_btn)
        gear = QPushButton("Astria Settings…")
        gear.clicked.connect(self._settings)
        row.addWidget(gear)
        tv.addLayout(row)
        self.key_row = KeyRow()
        self.key_row.saved.connect(lambda: (self.key_row.setVisible(False), self.reload()))
        self.key_row.setVisible(not A.get_key())
        tv.addWidget(self.key_row)
        self.status = _small("")
        tv.addWidget(self.status)
        v.addWidget(top)
        self.scroll = QScrollArea()
        self.scroll.setObjectName("AIScroll")
        self.scroll.setWidgetResizable(True)
        self.scroll.setFrameShape(QFrame.Shape.NoFrame)
        self.body = QWidget()
        self.body.setObjectName("AIBody")
        self.list = QVBoxLayout(self.body)
        self.list.setContentsMargins(16, 12, 16, 12)
        self.list.setSpacing(12)
        self.scroll.setWidget(self.body)
        v.addWidget(self.scroll, 1)
        bar = QFrame()
        bar.setObjectName("AIBar")
        bh = QHBoxLayout(bar)
        bh.setContentsMargins(16, 10, 16, 10)
        self.summary = _small("", wrap=False)
        bh.addWidget(self.summary, 1)
        self.clear_btn = QPushButton("Deselect")
        self.clear_btn.clicked.connect(lambda: self._select(list(self.selected), False))
        self.pick_btn = QPushButton("Save to Folder…")
        self.pick_btn.clicked.connect(self.save_to_picked)
        self.last_btn = QPushButton("Save")
        self.last_btn.setObjectName("Primary")
        self.last_btn.clicked.connect(lambda: self.save_selected(self.last_folder()))
        for b in (self.clear_btn, self.pick_btn, self.last_btn):
            bh.addWidget(b)
        v.addWidget(bar)
        self._update_bar()
        self.reload()

    # -- listing
    def _settings(self) -> None:
        if SettingsDialog(self).exec():
            self.key_row.setVisible(not A.get_key())
            self.reload()

    def reload(self) -> None:
        if not A.get_key():
            self.status.setText("Add your Astria API key to see your generations.")
            return
        self.status.setText("Loading your generations…")
        bridge = self.bridge

        def work() -> None:
            c = CLIENT()
            try:
                tunes = c.list_tunes()
                prompts = c.list_prompts()
            except Exception:  # noqa: BLE001
                tunes, prompts = [], []
            bridge.listed.emit(prompts, tunes)
        self.pool.submit(work)

    def _listed(self, prompts, tunes) -> None:
        self.prompts = [p for p in prompts if p.images]
        self.tunes = list(tunes)
        self._render(reset=True)

    def _matches(self) -> list[A.Prompt]:
        words = [w for w in self.search.text().lower().split() if w]
        if not words:
            return self.prompts
        out = []
        for p in self.prompts:
            hay = (p.text + " " + A.model_name(p.tune_id, self.tunes)).lower()
            if all(w in hay for w in words):
                out.append(p)
        return out

    def _render(self, reset: bool = False) -> None:
        if reset:
            self.shown = self.PAGE
        while self.list.count():
            it = self.list.takeAt(0)
            w = it.widget()
            if w is not None:              # keep a hold until it's gone
                w.setParent(None)
                w.deleteLater()
        self.tiles = []
        shown = self._matches()
        n_img = sum(len(p.images) for p in shown)
        if self.prompts:
            self.status.setText(f"{len(shown):,} prompt{'s' if len(shown) != 1 else ''}, {n_img:,} image"
                                f"{'s' if n_img != 1 else ''}" + ("" if len(shown) == len(self.prompts)
                                                                   else f" (of {len(self.prompts):,} prompts)") +
                                " — click images to pick them; double-click for full size.")
        elif A.get_key():
            self.status.setText("No generations on this account yet (or Astria didn't answer — Reload).")
        for p in shown[:self.shown]:
            self.list.addWidget(self._card(p))
        if len(shown) > self.shown:
            more = QPushButton(f"Show {min(self.PAGE, len(shown) - self.shown)} More")
            more.clicked.connect(self._more)
            self.list.addWidget(more, 0, Qt.AlignmentFlag.AlignHCenter)
        self.list.addStretch(1)
        self._update_bar()

    def _more(self) -> None:
        self.shown += self.PAGE
        y = self.scroll.verticalScrollBar().value()
        self._render()
        self.scroll.verticalScrollBar().setValue(y)

    def _card(self, p: A.Prompt) -> QFrame:
        card = QFrame()
        card.setObjectName("AICard")
        v = QVBoxLayout(card)
        v.setContentsMargins(12, 10, 12, 12)
        head = QHBoxLayout()
        when = time.strftime("%b %-d, %Y %H:%M", time.localtime(p.created)) if p.created else ""
        meta = QLabel(" · ".join(x for x in (A.model_name(p.tune_id, self.tunes), when,
                                             f"{len(p.images)} image{'s' if len(p.images) != 1 else ''}") if x))
        meta.setObjectName("AIHead")
        head.addWidget(meta, 1)
        allb = QPushButton("Select All")
        allb.clicked.connect(lambda _=False, p=p: self._select(p.images, not all(u in self.selected for u in p.images)))
        head.addWidget(allb)
        copy = QPushButton("Copy Prompt")
        copy.clicked.connect(lambda _=False, t=p.text: QGuiApplication.clipboard().setText(t))
        head.addWidget(copy)
        v.addLayout(head)
        text = _small(p.text if len(p.text) < 300 else p.text[:300] + "…")
        text.setToolTip(p.text)
        text.setTextInteractionFlags(Qt.TextInteractionFlag.TextSelectableByMouse)
        v.addWidget(text)
        holder = QWidget()
        flow = FlowLayout(holder, 8)
        flow.setContentsMargins(0, 4, 0, 0)
        for u in p.images:
            t = _Tile(u, self)
            t.toggled.connect(lambda url: self._select([url], url not in self.selected))
            t.opened.connect(self.preview)
            flow.addWidget(t)
            self.tiles.append(t)
        v.addWidget(holder)
        return card

    # -- thumbnails
    def want(self, url: str) -> None:
        if url in self.wanted:
            return
        self.wanted.add(url)
        bridge, stop = self.bridge, self.stop

        def work() -> None:
            if stop.is_set():
                return
            path = _cache_name(url)
            try:
                data = path.read_bytes()
            except OSError:
                data = CLIENT().download(url, attempts=2)
                if not data:
                    return
                try:
                    from PIL import Image, ImageOps
                    with Image.open(io.BytesIO(data)) as im:
                        im = ImageOps.exif_transpose(im).convert("RGB")
                        im.thumbnail((480, 480))
                        buf = io.BytesIO()
                        im.save(buf, "JPEG", quality=85)
                        data = buf.getvalue()
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_bytes(data)
                except Exception:  # noqa: BLE001 — shown from the full download this time
                    pass
            bridge.thumb.emit(url, data)
        self.pool.submit(work)

    def _thumb(self, url: str, data: bytes) -> None:
        img = QImage.fromData(data)
        if img.isNull():
            return
        self.thumbs[url] = QPixmap.fromImage(img)
        for t in self.tiles:
            if t.url == url:
                t.update()

    # -- picking + saving
    def is_saved(self, url: str) -> bool:
        path = (A.store().get("saved", {}) or {}).get(url.split("?")[0])
        return bool(path) and os.path.exists(path)

    def _select(self, urls: list[str], on: bool) -> None:
        if on:
            self.selected.update(urls)
        else:
            self.selected.difference_update(urls)
        for t in self.tiles:
            if t.url in urls:
                t.update()
        self._update_bar()

    def last_folder(self) -> str:
        f = A.store().get("last_folder", "") or ""
        return f if f and os.path.isdir(f) else self.folder

    def _update_bar(self) -> None:
        n = len(self.selected)
        last = self.last_folder()
        self.last_btn.setText(f"Save {n} to “{os.path.basename(last) or last}”" if n else
                              f"Save to “{os.path.basename(last) or last}”")
        for b in (self.last_btn, self.pick_btn, self.clear_btn):
            b.setEnabled(n > 0)
        self.summary.setText(f"{n} selected" if n else "")

    def save_to_picked(self) -> None:
        folder = QFileDialog.getExistingDirectory(self, "Save to Folder", self.last_folder())
        if folder:
            self.save_selected(folder)

    def _prompt_of(self, url: str) -> A.Prompt | None:
        return next((p for p in self.prompts if url in p.images), None)

    def save_selected(self, folder: str, urls: list[str] | None = None) -> None:
        urls = list(urls if urls is not None else sorted(self.selected))
        if not urls or not folder:
            return
        A.store().set("last_folder", folder)
        self.last_btn.setEnabled(False)
        self.pick_btn.setEnabled(False)
        self.summary.setText(f"Saving {len(urls)}…")
        bridge, stop = self.bridge, self.stop
        jobs_ = [(u, self._prompt_of(u)) for u in urls]
        tunes = list(self.tunes)

        def work() -> None:
            c = CLIENT()
            saved = failed = 0
            for i, (u, p) in enumerate(jobs_):
                if stop.is_set():
                    break
                data = c.download(u)
                path = ""
                if data:
                    try:
                        path = A.save_created(data, folder, A.model_name(p.tune_id if p else None, tunes),
                                              p.text if p else "", when=p.created if p else None, into_ai=False)
                        A.store().update("saved", lambda d, u=u, path=path: {**(d or {}), u.split("?")[0]: path})
                        saved += 1
                    except OSError:
                        failed += 1
                else:
                    failed += 1
                bridge.saved.emit(i + 1, len(jobs_), path)
            bridge.save_done.emit(saved, failed, folder)
        threading.Thread(target=work, daemon=True).start()

    def _save_progress(self, done: int, total: int, _path: str) -> None:
        self.summary.setText(f"Saving {done} of {total}…")

    def _save_done(self, saved: int, failed: int, folder: str) -> None:
        self.selected.clear()
        for t in self.tiles:
            t.update()
        self._update_bar()
        self.summary.setText(f"Saved {saved} into “{os.path.basename(folder)}”." +
                             (f" {failed} couldn't be downloaded." if failed else ""))

    def preview(self, url: str) -> None:
        p = self._prompt_of(url)
        dlg = PreviewDialog(url, p, self)
        dlg.show()

    def closeEvent(self, event) -> None:  # noqa: N802
        self.stop.set()
        self.pool.shutdown(wait=False, cancel_futures=True)
        super().closeEvent(event)


class _PreviewBridge(QObject):
    loaded = Signal(bytes)


class PreviewDialog(QDialog):
    """One image full size (≤ 2200 px), its prompt, Copy Prompt and the two saves."""

    def __init__(self, url: str, prompt: A.Prompt | None, browser: BrowserWindow) -> None:
        super().__init__(browser)
        self.setAttribute(Qt.WidgetAttribute.WA_DeleteOnClose)
        self.url, self.prompt, self.browser = url, prompt, browser
        self.setWindowTitle("Astria image")
        self.resize(900, 900)
        v = QVBoxLayout(self)
        self.image = QLabel("Loading…")
        self.image.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.image.setMinimumHeight(500)
        v.addWidget(self.image, 1)
        if prompt is not None:
            meta = _small(" · ".join(x for x in (A.model_name(prompt.tune_id, browser.tunes),
                                                 time.strftime("%B %-d, %Y %H:%M", time.localtime(prompt.created))
                                                 if prompt.created else "") if x))
            v.addWidget(meta)
            t = _small(prompt.text)
            t.setTextInteractionFlags(Qt.TextInteractionFlag.TextSelectableByMouse)
            v.addWidget(t)
        row = QHBoxLayout()
        copy = QPushButton("Copy Prompt")
        copy.clicked.connect(lambda: QGuiApplication.clipboard().setText(prompt.text if prompt else ""))
        row.addWidget(copy)
        row.addStretch(1)
        pick = QPushButton("Save to Folder…")
        pick.clicked.connect(self._pick)
        row.addWidget(pick)
        last = browser.last_folder()
        save = QPushButton(f"Save to “{os.path.basename(last) or last}”")
        save.setObjectName("Primary")
        save.clicked.connect(lambda: (browser.save_selected(browser.last_folder(), [url]), self.close()))
        row.addWidget(save)
        v.addLayout(row)
        self.bridge = _PreviewBridge()
        self.bridge.loaded.connect(self._loaded)
        threading.Thread(target=lambda: self.bridge.loaded.emit(CLIENT().download(url) or b""), daemon=True).start()

    def _loaded(self, data: bytes) -> None:
        img = QImage.fromData(data)
        if img.isNull():
            self.image.setText("Couldn't load the image.")
            return
        if max(img.width(), img.height()) > 2200:
            img = img.scaled(2200, 2200, Qt.AspectRatioMode.KeepAspectRatio, Qt.TransformationMode.SmoothTransformation)
        pm = QPixmap.fromImage(img).scaled(self.image.size(), Qt.AspectRatioMode.KeepAspectRatio,
                                           Qt.TransformationMode.SmoothTransformation)
        self.image.setPixmap(pm)

    def _pick(self) -> None:
        folder = QFileDialog.getExistingDirectory(self, "Save to Folder", self.browser.last_folder())
        if folder:
            self.browser.save_selected(folder, [self.url])
            self.close()
