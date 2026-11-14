"""AI ▸ Models… and Make AI Model… — Safe Finder's windows for `ai_models.py` (a person, pet, object or style kept
as its best photos) and the engines that draw from one:

- **On this Mac** (`local_ai.py` — FLUX.2 klein 4B through mflux): private, free, nothing uploaded. Set up on
  first use (after saying what it downloads), then a prompt, a size and a count; the model's first photos go in as
  references. What it can do follows the Mac's memory (`local_ai.plan`).
- **Seedream / Nano Banana** (Astria): opens Create with AI with the model's photos already attached as
  references — the same window, history, results and recovery as any other creation.
- **A trained model** (Astria): "Train on Astria…" uploads the set and trains a Flux LoRA there (the iPhone's
  `createTune`); once ready it's one of the engines here and a tune in Create / Edit with AI everywhere.

`MakeModelDialog` is where a model starts: the photos are looked through (`ai_models.curate`), what was kept and
why the rest wasn't is shown, and — for a person — the maker confirms it's themselves or someone who has agreed.
"""
from __future__ import annotations

import os
import threading
import time
from dataclasses import dataclass
from typing import Callable

from PySide6.QtCore import QObject, QSize, Qt, QTimer, Signal
from PySide6.QtGui import QIcon, QPixmap
from PySide6.QtWidgets import (QCheckBox, QComboBox, QDialog, QFormLayout, QHBoxLayout, QLabel, QLineEdit,
                               QListWidget, QListWidgetItem, QMessageBox, QPlainTextEdit, QProgressBar, QPushButton,
                               QSpinBox, QVBoxLayout, QWidget)

import ai_models
import local_ai


@dataclass
class ModelHooks:
    folder: Callable[[], str]                              # where pictures made now should go (its "AI" folder)
    create_with_ai: Callable[[str, dict], None]            # (folder, settings): open Create with AI prefilled
    view: Callable[[list[str], str], None] | None = None   # open pictures in the viewer
    reveal: Callable[[str], None] | None = None            # show a file or folder in Safe Finder
    trash: Callable[[str], bool] | None = None             # a folder to the Trash


class _Bridge(QObject):
    progress = Signal(int, int, str)
    line = Signal(str)
    done = Signal(object)
    failed = Signal(str)


def _thumb(path: str, side: int) -> QPixmap:
    pm = QPixmap(path)
    if pm.isNull():
        return QPixmap()
    pm = pm.scaled(side, side, Qt.AspectRatioMode.KeepAspectRatioByExpanding, Qt.TransformationMode.SmoothTransformation)
    return pm.copy((pm.width() - side) // 2, (pm.height() - side) // 2, side, side)


def _strip(paths: list[str], side: int = 64, limit: int = 12) -> QWidget:
    box = QWidget()
    row = QHBoxLayout(box)
    row.setContentsMargins(0, 0, 0, 0)
    row.setSpacing(4)
    for p in paths[:limit]:
        lab = QLabel()
        lab.setPixmap(_thumb(p, side))
        lab.setFixedSize(side, side)
        row.addWidget(lab)
    if len(paths) > limit:
        row.addWidget(QLabel(f"+{len(paths) - limit}"))
    row.addStretch(1)
    return box


# ============================================================================ making a model

class MakeModelDialog(QDialog):
    """Photos → a model. `self.model` is set when one was made."""

    def __init__(self, parent, paths: list[str]) -> None:
        super().__init__(parent)
        self.setWindowTitle("Make AI Model")
        self.setMinimumWidth(620)
        self.paths = paths[:ai_models.MAX_PHOTOS]
        self.model: ai_models.Model | None = None
        self.curated: ai_models.Curated | None = None
        self.stop_flag = False
        self.bridge = _Bridge()
        self.bridge.progress.connect(self._progress)
        self.bridge.done.connect(self._looked)
        lay = QVBoxLayout(self)
        lay.setContentsMargins(18, 16, 18, 14)
        lay.setSpacing(10)
        lay.addWidget(QLabel("Make AI Model", objectName="SheetTitle"))
        more = f" (the first {ai_models.MAX_PHOTOS} of {len(paths):,})" if len(paths) > ai_models.MAX_PHOTOS else ""
        intro = QLabel(f"From {len(self.paths):,} photos{more}, the sharpest and most varied are kept — that's what a "
                       "model is: the photos pictures of it are made from. Blurred shots, tiny ones and near-copies "
                       "are left out. Your photos aren't changed, and nothing leaves this Mac.")
        intro.setWordWrap(True)
        intro.setObjectName("SheetSub")
        lay.addWidget(intro)
        form = QFormLayout()
        self.name = QLineEdit()
        self.name.setPlaceholderText("e.g. Keri, Biscuit, The blue mug")
        self.kind = QComboBox()
        for key, title in ai_models.KINDS.items():
            self.kind.addItem(title, key)
        self.word = QLineEdit()
        self.word.setPlaceholderText("woman, man, golden retriever, ceramic mug, watercolour…")
        self.word.setToolTip("What it is, in plain words — how a prompt will refer to it")
        form.addRow("Name", self.name)
        form.addRow("It's a", self.kind)
        form.addRow("Described as", self.word)
        lay.addLayout(form)
        self.consent = QCheckBox("This is me, or someone who has agreed to pictures being made of them.")
        lay.addWidget(self.consent)
        self.status = QLabel("Looking through the photos…")
        self.status.setWordWrap(True)
        lay.addWidget(self.status)
        self.bar = QProgressBar()
        self.bar.setRange(0, max(1, len(self.paths)))
        self.bar.setTextVisible(False)
        lay.addWidget(self.bar)
        self.strip_holder = QVBoxLayout()
        lay.addLayout(self.strip_holder)
        buttons = QHBoxLayout()
        cancel = QPushButton("Cancel")
        cancel.clicked.connect(self.reject)
        self.make = QPushButton("Make Model", objectName="Primary")
        self.make.setDefault(True)
        self.make.setEnabled(False)
        self.make.clicked.connect(self._make)
        buttons.addStretch(1)
        buttons.addWidget(cancel)
        buttons.addWidget(self.make)
        lay.addLayout(buttons)
        self.kind.currentIndexChanged.connect(self._kind_changed)
        self.name.textChanged.connect(lambda _t: self._ready())
        self.consent.toggled.connect(lambda _on: self._ready())
        self._kind_changed()
        self._look()

    def _kind_changed(self) -> None:
        kind = self.kind.currentData()
        self.consent.setVisible(kind == "person")
        if not self.word.text().strip() or self.word.text() in ai_models.DEFAULT_WORDS.values():
            self.word.setText(ai_models.DEFAULT_WORDS.get(kind, ""))
        if self.curated is not None and (kind == "style") != (self._looked_as == "style"):
            self._look()                                   # a style keeps more photos: choose again
        self._ready()

    def _look(self) -> None:
        self.make.setEnabled(False)
        self.curated = None
        self._looked_as = self.kind.currentData()
        self.bar.setVisible(True)
        self.status.setText("Looking through the photos…")
        kind = self._looked_as

        def work() -> None:
            c = ai_models.curate(self.paths, kind, stop=lambda: self.stop_flag,
                                 progress=lambda i, n, name: self.bridge.progress.emit(i, n, name))
            self.bridge.done.emit((kind, c))
        threading.Thread(target=work, daemon=True, name="ai-model-look").start()

    def _progress(self, done: int, total: int, name: str) -> None:
        self.bar.setRange(0, max(1, total))
        self.bar.setValue(done)
        if name:
            self.status.setText(f"Looking through the photos — {done + 1:,} of {total:,}  ·  {name}")

    def _looked(self, result) -> None:
        kind, c = result
        if kind != self.kind.currentData() and (kind == "style") != (self.kind.currentData() == "style"):
            return                                         # an older look; the newer one is on its way
        self.curated = c
        self.bar.setVisible(False)
        reasons: dict[str, int] = {}
        for _path, why in c.dropped:
            key = "near-copies" if why.startswith("nearly") else "more than needed" if why.startswith("more") \
                else "blurred" if why == "blurred" else "too small" if why.startswith("too small") else "unreadable"
            reasons[key] = reasons.get(key, 0) + 1
        left = ", ".join(f"{n:,} {k}" for k, n in reasons.items())
        if len(c.picked) < ai_models.MIN_PHOTOS:
            self.status.setText(f"Only {len(c.picked)} usable photo(s) — a model needs at least {ai_models.MIN_PHOTOS}."
                                + (f" Left out: {left}." if left else ""))
        else:
            self.status.setText(f"{len(c.picked):,} photos kept of {c.seen:,}." + (f" Left out: {left}." if left else ""))
        while self.strip_holder.count():
            w = self.strip_holder.takeAt(0).widget()
            if w is not None:
                w.deleteLater()
        box = QWidget()
        row = QHBoxLayout(box)
        row.setContentsMargins(0, 0, 0, 0)
        row.setSpacing(4)
        for cand in c.picked[:9]:
            pm = QPixmap()
            pm.loadFromData(cand.jpeg)
            lab = QLabel()
            side = 60
            pm = pm.scaled(side, side, Qt.AspectRatioMode.KeepAspectRatioByExpanding, Qt.TransformationMode.SmoothTransformation)
            lab.setPixmap(pm.copy((pm.width() - side) // 2, (pm.height() - side) // 2, side, side))
            row.addWidget(lab)
        if len(c.picked) > 9:
            row.addWidget(QLabel(f"+{len(c.picked) - 9}"))
        row.addStretch(1)
        self.strip_holder.addWidget(box)
        self._ready()

    def _ready(self) -> None:
        ok = self.curated is not None and len(self.curated.picked) >= ai_models.MIN_PHOTOS \
            and bool(self.name.text().strip()) and (self.kind.currentData() != "person" or self.consent.isChecked())
        self.make.setEnabled(ok)

    def _make(self) -> None:
        name = self.name.text().strip()
        if not ai_models.name_free(name):
            QMessageBox.information(self, "Make AI Model", f"There's already a model called “{name}”. Give this one "
                                    "another name.")
            return
        try:
            self.model = ai_models.create(name, self.kind.currentData(), self.word.text().strip(), self.curated,
                                          consent=self.kind.currentData() == "person" and self.consent.isChecked())
        except (OSError, ValueError) as e:
            QMessageBox.warning(self, "Make AI Model", f"The model couldn't be made.\n\n{e}")
            return
        self.accept()

    def reject(self) -> None:
        self.stop_flag = True
        super().reject()


# ============================================================================ the models, and pictures from them

LOCAL = "On this Mac — FLUX.2 klein 4B (private, free)"
TRAINED = "Flux + this model's trained LoRA (Astria)"


class ModelsWindow(QWidget):
    def __init__(self, parent, hooks: ModelHooks, select: str | None = None) -> None:
        super().__init__(parent, Qt.WindowType.Window)
        self.setAttribute(Qt.WidgetAttribute.WA_DeleteOnClose)
        self.setWindowTitle("AI Models")
        self.resize(900, 620)
        self.hooks = hooks
        self.models: list[ai_models.Model] = []
        self.running = False
        self.stop_flag = False
        self.results: list[str] = []
        self.bridge = _Bridge()
        self.bridge.line.connect(self._line)
        self.bridge.progress.connect(self._progress)
        self.bridge.done.connect(self._done)
        self.bridge.failed.connect(self._failed)

        root = QHBoxLayout(self)
        root.setContentsMargins(14, 14, 14, 12)
        root.setSpacing(14)
        left = QVBoxLayout()
        self.list = QListWidget()
        self.list.setIconSize(QSize(56, 56))
        self.list.setFixedWidth(230)
        self.list.currentRowChanged.connect(lambda _r: self._show())
        left.addWidget(self.list, 1)
        hint = QLabel("To make one: select 5 or more photos in Safe Finder and right-click ▸ Make AI Model… — or right-click "
                      "a folder ▸ AI ▸ Make AI Model from Photos Inside…")
        hint.setWordWrap(True)
        hint.setObjectName("SheetSub")
        left.addWidget(hint)
        root.addLayout(left)

        right = QVBoxLayout()
        right.setSpacing(8)
        self.title = QLabel("", objectName="SheetTitle")
        self.about = QLabel("")
        self.about.setObjectName("SheetSub")
        self.about.setWordWrap(True)
        right.addWidget(self.title)
        right.addWidget(self.about)
        self.photos_holder = QVBoxLayout()
        right.addLayout(self.photos_holder)
        right.addWidget(QLabel("Describe the picture"))
        self.prompt = QPlainTextEdit()
        self.prompt.setFixedHeight(84)
        right.addWidget(self.prompt)
        form = QFormLayout()
        self.engine = QComboBox()
        self.engine.currentIndexChanged.connect(lambda _i: self._engine_changed())
        form.addRow("Make it with", self.engine)
        self.size = QComboBox()
        for title, w, h in local_ai.SIZES:
            self.size.addItem(title, (w, h))
        self.count = QSpinBox()
        self.count.setRange(1, 4)
        form.addRow("Size", self.size)
        form.addRow("Pictures", self.count)
        right.addLayout(form)
        self.note = QLabel("")
        self.note.setWordWrap(True)
        self.note.setObjectName("SheetSub")
        right.addWidget(self.note)
        row = QHBoxLayout()
        self.go = QPushButton("Generate", objectName="Primary")
        self.go.clicked.connect(self._generate)
        self.stop = QPushButton("Stop")
        self.stop.setEnabled(False)
        self.stop.clicked.connect(self._stop)
        row.addWidget(self.go)
        row.addWidget(self.stop)
        row.addStretch(1)
        right.addLayout(row)
        self.bar = QProgressBar()
        self.bar.setTextVisible(False)
        self.bar.setVisible(False)
        right.addWidget(self.bar)
        self.status = QLabel("")
        self.status.setWordWrap(True)
        right.addWidget(self.status)
        self.log = QPlainTextEdit()
        self.log.setReadOnly(True)
        self.log.setMaximumBlockCount(400)
        self.log.setVisible(False)
        right.addWidget(self.log, 1)
        self.results_holder = QVBoxLayout()
        right.addLayout(self.results_holder)
        right.addStretch(1)
        tools = QHBoxLayout()
        self.train = QPushButton("Train on Astria…")
        self.train.setToolTip("Uploads this model's photos to Astria and trains a Flux LoRA from them there — a real "
                              "trained model, which this Mac hasn't the memory to train itself. Astria charges for it.")
        self.train.clicked.connect(self._train)
        self.show_photos = QPushButton("Show Photos")
        self.show_photos.clicked.connect(self._reveal)
        self.delete = QPushButton("Delete Model…", objectName="Danger")
        self.delete.clicked.connect(self._delete)
        for b in (self.train, self.show_photos):
            tools.addWidget(b)
        tools.addStretch(1)
        tools.addWidget(self.delete)
        right.addLayout(tools)
        root.addLayout(right, 1)
        self.size.setCurrentIndex(max(0, self.size.findData((local_ai.plan().size, local_ai.plan().size))))
        self._tune_timer = QTimer(self)                    # while a model trains on Astria: is it ready yet?
        self._tune_timer.setInterval(30_000)
        self._tune_timer.timeout.connect(self._check_tune)
        self.reload(select)

    # -- the list
    def current(self) -> ai_models.Model | None:
        i = self.list.currentRow()
        return self.models[i] if 0 <= i < len(self.models) else None

    def reload(self, select: str | None = None) -> None:
        keep = select or (self.current().name if self.current() else None)
        self.models = ai_models.all_models()
        self.list.blockSignals(True)
        self.list.clear()
        for m in self.models:
            item = QListWidgetItem(QIcon(_thumb(m.cover, 112)) if m.cover else QIcon(), f"{m.name}\n{len(m.photos)} photos")
            self.list.addItem(item)
        self.list.blockSignals(False)
        row = next((i for i, m in enumerate(self.models) if m.name == keep), 0 if self.models else -1)
        self.list.setCurrentRow(row)
        self._show()

    def _show(self) -> None:
        m = self.current()
        for w in (self.prompt, self.engine, self.size, self.count, self.go, self.train, self.show_photos, self.delete):
            w.setEnabled(m is not None and not self.running)
        while self.photos_holder.count():
            w = self.photos_holder.takeAt(0).widget()
            if w is not None:
                w.deleteLater()
        if m is None:
            self.title.setText("No models yet")
            self.about.setText("A model is a person, a pet, an object or a style, kept as its best photos — pictures of "
                               "it can then be made on this Mac, or with Seedream and Nano Banana.")
            return
        self.title.setText(m.name)
        made = time.strftime("%b %-d, %Y", time.localtime(m.created)) if m.created else ""
        self.about.setText(f"{ai_models.KINDS.get(m.kind, m.kind)} · “{m.word}” · {len(m.photos)} photos kept of "
                           f"{m.seen or len(m.photos):,}" + (f" · made {made}" if made else ""))
        self.photos_holder.addWidget(_strip(m.photo_paths(), 56, 11))
        self.prompt.setPlaceholderText(f"e.g. {m.subject}, standing on a beach at sunset, golden light" if m.kind != "style"
                                       else "e.g. a lighthouse on a cliff, in the style of the reference pictures")
        self._fill_engines(m)
        self._tune_timer.stop()
        if m.astria_tune and not self._tune_is_ready(m):
            self._tune_timer.start()

    def _tune_is_ready(self, m: ai_models.Model) -> bool:
        return bool(getattr(m, "_ready", False))

    def _fill_engines(self, m: ai_models.Model) -> None:
        import astria
        was = self.engine.currentText()
        self.engine.blockSignals(True)
        self.engine.clear()
        self.engine.addItem(LOCAL, ("local", ""))
        for name in astria.PARTNER_MODELS:
            self.engine.addItem(f"{name} (Astria)", ("astria", name))
        if m.astria_tune:
            self.engine.addItem(TRAINED, ("tune", "Flux"))
        self.engine.setCurrentIndex(max(0, self.engine.findText(was)))
        self.engine.blockSignals(False)
        self._engine_changed()

    def _engine_changed(self) -> None:
        kind, name = self.engine.currentData() or ("local", "")
        local = kind == "local"
        self.size.setEnabled(local and not self.running)
        self.count.setEnabled(local and not self.running)
        m = self.current()
        if local:
            p = local_ai.plan()
            if not p.ok:
                self.note.setText(p.why)
            else:
                state = "" if local_ai.installed() and local_ai.prepared(p.quantize) else \
                    f" Not set up yet: the first Generate downloads the engine and the model (about {local_ai.DOWNLOAD_GB + 1} GB, once)."
                refs = min(p.max_refs, len(m.photos)) if m else p.max_refs
                self.note.setText(f"{p.why} This model's first {refs} photo(s) go in as references.{state}"
                                  + ("" if p.can_train else " (Training a model on the Mac itself needs 32 GB of memory.)"))
            self.go.setText("Generate")
        elif kind == "tune":
            self.note.setText("Opens Create with AI on Flux with this model's trained LoRA selected.")
            self.go.setText("Open in Create with AI…")
        else:
            import astria
            limit = astria.MODELS[name][1]
            n = min(limit, len(m.photos)) if m else limit
            self.note.setText(f"Opens Create with AI on {name} with this model's first {n} photos attached as "
                              "references. They're uploaded to Astria (your account), as with any Create with AI.")
            self.go.setText("Open in Create with AI…")

    # -- making pictures
    def _generate(self) -> None:
        m = self.current()
        if m is None or self.running:
            return
        kind, name = self.engine.currentData() or ("local", "")
        prompt = self.prompt.toPlainText().strip()
        if kind != "local":
            import astria
            settings = dict(astria.store().get("run_create", {}) or {})
            settings.update({"model": name, "prompt": prompt or settings.get("prompt", "")})
            if kind == "tune":
                settings.update({"tunes": [m.astria_tune], "references": []})
            else:
                settings.update({"tunes": [], "references": m.photo_paths(astria.MODELS[name][1])})
            self.hooks.create_with_ai(self.hooks.folder(), settings)
            return
        if not prompt:
            QMessageBox.information(self, "AI Models", "Describe the picture first.")
            return
        p = local_ai.plan()
        if not p.ok:
            QMessageBox.information(self, "AI Models", p.why)
            return
        if not (local_ai.installed() and local_ai.prepared(p.quantize)):
            uv = local_ai.find_uv()
            if uv is None:
                QMessageBox.information(
                    self, "Set Up Pictures on This Mac",
                    "One small tool is needed first: uv, which sets up the AI engine's own Python. In Terminal:\n\n"
                    f"    {local_ai.UV_INSTALL}\n\n(or `brew install uv`). Then press Generate again.")
                return
            if QMessageBox.question(
                    self, "Set Up Pictures on This Mac",
                    "Making pictures on this Mac needs a one-time setup:\n\n"
                    "•  the engine (mflux, about 1 GB)\n"
                    f"•  the model, FLUX.2 klein 4B (about {local_ai.DOWNLOAD_GB} GB to download from Hugging Face; "
                    f"about {4 if p.quantize == 4 else 8} GB is kept in the form this Mac uses)\n\n"
                    f"It goes in “Application Support/Safe Finder/AI”. {local_ai.free_gb():.0f} GB is free. The download "
                    "can take a while, and the last step is heavy on a 16 GB Mac — close other apps. After this, "
                    "nothing here uses the network.\n\nSet it up now?") != QMessageBox.StandardButton.Yes:
                return
        folder = self.hooks.folder()
        w, h = self.size.currentData()
        count = self.count.value()
        refs = m.photo_paths(p.max_refs)
        self._begin(f"Making {count} picture{'s' if count != 1 else ''}…")

        def work() -> None:
            import astria
            try:
                if not local_ai.installed():
                    local_ai.install(self.bridge.line.emit, lambda: self.stop_flag)
                local_ai.prepare(p.quantize, self.bridge.line.emit, lambda: self.stop_flag)
                self.bridge.line.emit("Loading the model…")
                result = local_ai.generate(
                    prompt, lambda data: astria.save_created(data, folder, local_ai.ENGINE_NAME, prompt),
                    count=count, width=w, height=h, references=refs, the_plan=p,
                    progress=lambda pic, pics, step, steps: self.bridge.progress.emit(
                        (pic - 1) * steps + step, pics * steps, f"Picture {pic} of {pics} — step {step} of {steps}"),
                    on_line=self.bridge.line.emit, stop=lambda: self.stop_flag)
                self.bridge.done.emit(("pictures", result))
            except local_ai.Stopped:
                self.bridge.failed.emit("")
            except Exception as e:  # noqa: BLE001 — whatever went wrong, the person is told
                self.bridge.failed.emit(str(e))
        threading.Thread(target=work, daemon=True, name="ai-local").start()

    def _begin(self, text: str) -> None:
        self.running, self.stop_flag = True, False
        self.started = time.monotonic()
        self.bar.setRange(0, 0)
        self.bar.setVisible(True)
        self.log.setVisible(True)
        self.status.setText(text)
        self.stop.setEnabled(True)
        self._show()

    def _end(self) -> None:
        self.running = False
        self.bar.setVisible(False)
        self.stop.setEnabled(False)
        self._show()

    def _stop(self) -> None:
        self.stop_flag = True
        self.status.setText("Stopping…")

    def _line(self, text: str) -> None:
        self.log.appendPlainText(text)

    def _progress(self, done: int, total: int, text: str) -> None:
        self.bar.setRange(0, max(1, total))
        self.bar.setValue(done)
        secs = time.monotonic() - self.started
        self.status.setText(f"{text}  ·  {secs / 60:.0f} min" if secs >= 90 else f"{text}  ·  {secs:.0f} s")

    def _failed(self, why: str) -> None:
        self._end()
        self.status.setText("Stopped." if not why else "It didn't work — see below.")
        if why:
            self.log.appendPlainText("\n" + why)

    def _done(self, payload) -> None:
        what, value = payload
        self._end()
        if what == "pictures":
            files = value.files
            self.results = files + self.results
            per = value.seconds / max(1, len(files))
            self.status.setText(f"{len(files)} picture{'s' if len(files) != 1 else ''} in “AI” — "
                                f"{per / 60:.1f} min each." if per >= 90 else
                                f"{len(files)} picture{'s' if len(files) != 1 else ''} in “AI” — {per:.0f} s each.")
            self.log.setVisible(False)
            while self.results_holder.count():
                w = self.results_holder.takeAt(0).widget()
                if w is not None:
                    w.deleteLater()
            box = QWidget()
            row = QHBoxLayout(box)
            row.setContentsMargins(0, 0, 0, 0)
            row.setSpacing(6)
            for path in self.results[:6]:
                b = QPushButton()
                b.setIcon(QIcon(_thumb(path, 192)))
                b.setIconSize(QSize(96, 96))
                b.setFixedSize(104, 104)
                b.setToolTip(os.path.basename(path))
                b.clicked.connect(lambda _=False, path=path: self.hooks.view(self.results, path) if self.hooks.view else None)
                row.addWidget(b)
            row.addStretch(1)
            self.results_holder.addWidget(box)
        elif what == "tune":
            m, tid = value
            self.status.setText(f"Training “{m.name}” on Astria (tune {tid}). It takes a while; it appears here and "
                                "in Create / Edit with AI when it's ready.")
            self.log.setVisible(False)
            self.reload(m.name)

    # -- a trained model, on Astria
    def _train(self) -> None:
        import astria
        m = self.current()
        if m is None or self.running:
            return
        if not astria.get_key():
            QMessageBox.information(self, "Train on Astria", "Add your Astria API key first (Create with AI asks for it).")
            return
        if m.astria_tune:
            if QMessageBox.question(self, "Train on Astria", f"“{m.name}” already has a trained model on Astria (tune "
                                    f"{m.astria_tune}). Train another?") != QMessageBox.StandardButton.Yes:
                return
        token = ai_models.token_for(m.name)
        if QMessageBox.question(
                self, "Train on Astria",
                f"Upload {len(m.photos)} photos of “{m.name}” to Astria and train a Flux LoRA from them?\n\n"
                "•  The photos go to Astria, on your account.\n"
                "•  Astria charges for training a model (see its pricing).\n"
                "•  It takes a while (often 10–30 minutes); you can close this window meanwhile.\n\n"
                f"In prompts it will be “{token} {m.word}”.") != QMessageBox.StandardButton.Yes:
            return
        self._begin(f"Uploading {len(m.photos)} photos to Astria…")

        def work() -> None:
            try:
                images = [astria.upload_jpeg(p, max_px=1024)[0] for p in m.photo_paths()]
                client = astria.Client(astria.get_key())
                tid = client.create_tune(m.name, m.word, token, images, branch="flux1",
                                         base_tune=astria.tune_id("Flux"), model_type="lora")
                m.astria_tune, m.astria_token = tid, token
                m.save()
                self.bridge.done.emit(("tune", (m, tid)))
            except astria.AIError as e:
                self.bridge.failed.emit(e.message or {"network": "Astria couldn't be reached.",
                                                      "not_configured": "No Astria API key."}.get(e.kind, e.kind))
            except Exception as e:  # noqa: BLE001
                self.bridge.failed.emit(str(e))
        threading.Thread(target=work, daemon=True, name="ai-train").start()

    def _check_tune(self) -> None:
        import astria
        m = self.current()
        if m is None or not m.astria_tune or self.running or not astria.get_key():
            return
        tid = m.astria_tune

        def work() -> None:
            try:
                ready = astria.Client(astria.get_key()).tune_ready(tid)
            except Exception:  # noqa: BLE001
                ready = None
            if ready:
                m._ready = True
                self.bridge.line.emit(f"“{m.name}” has finished training on Astria.")
        threading.Thread(target=work, daemon=True, name="ai-tune-check").start()

    # -- housekeeping
    def _reveal(self) -> None:
        m = self.current()
        if m is not None and self.hooks.reveal:
            self.hooks.reveal(str(m.folder / "photos"))

    def _delete(self) -> None:
        m = self.current()
        if m is None:
            return
        if QMessageBox.question(self, "Delete Model", f"Move the model “{m.name}” to the Trash?\n\nOnly the model (its "
                                f"{len(m.photos)} kept copies) goes — your own photos, and pictures already made, "
                                "stay where they are." + (" A model trained on Astria stays on Astria."
                                                          if m.astria_tune else "")) != QMessageBox.StandardButton.Yes:
            return
        ok = self.hooks.trash(str(m.folder)) if self.hooks.trash else False
        if not ok:
            QMessageBox.warning(self, "Delete Model", "The model couldn't be moved to the Trash.")
        self.reload()

    def closeEvent(self, event) -> None:  # noqa: N802
        if self.running:
            if QMessageBox.question(self, "AI Models", "A picture is being made. Stop it and close?") \
                    != QMessageBox.StandardButton.Yes:
                event.ignore()
                return
            self.stop_flag = True
        super().closeEvent(event)
