"""Make Book PDF — Safe Finder's window for `bookify.py`: a plain-text, Markdown or RTF file typeset as a PDF that
looks and reads like a printed book (EB Garamond, justified and hyphenated, a title page, contents, chapter
openings with drop caps, running heads, cream paper). Right-click a .txt / .md / .rtf file ▸ Make Book PDF… (or
several: a book of each), or File ▸ Make Book PDF….

Every bookify option is here — title and author (found in the file when left empty: the window shows what it
found), page size (5 × 8 … US Letter, and **iPhone**: pages the shape of the iPhone 17 Pro Max's screen, one per
screen, no blank pages), text size, paper, the accent colour, hyphenation language, contents, drop caps, chapters on
right-hand pages, equal margins, your own fonts — and remembered for next time. The book goes beside the text as
"<name>.pdf" ("<name> (for iPhone).pdf" for the iPhone size; never over a file), carries the text's tags, and opens
in Safe Finder's PDF viewer from here.

bookify needs ReportLab (and pyphen for hyphenation; both in requirements.txt). When this copy of Safe Finder
hasn't got them, the window says so and offers to install them into its own Python (`pip`); the built app has
them inside. The first book downloads the EB Garamond fonts once (bookify caches them).

It doesn't touch files itself: `BookHooks` place the PDF (Safe Finder's drive-safe `simpcity.place`), carry the
tags, reveal and open it.
"""
from __future__ import annotations

import importlib
import os
import shutil
import subprocess
import sys
import tempfile
import threading
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

from PySide6.QtCore import QObject, QSettings, Qt, Signal
from PySide6.QtGui import QColor
from PySide6.QtWidgets import (QCheckBox, QColorDialog, QComboBox, QDoubleSpinBox, QFileDialog, QFormLayout,
                               QHBoxLayout, QLabel, QLineEdit, QProgressBar, QPushButton, QVBoxLayout, QWidget)

TEXT_EXTS = {".txt", ".text", ".md", ".markdown", ".rtf"}
SIZES = [("6x9", "6 × 9 in — a trade paperback"), ("5.5x8.5", "5.5 × 8.5 in"), ("5x8", "5 × 8 in — a pocket novel"),
         ("a5", "A5"), ("letter", "US Letter"), ("iphone", "iPhone 17 Pro Max — a page per screen")]
PAPERS = [("texture", "Cream, with a paper texture"), ("flat", "Flat cream"), ("white", "White — for printing")]
LANGS = [("en_US", "English (US)"), ("en_GB", "English (UK)"), ("de_DE", "German"), ("fr_FR", "French"),
         ("es_ES", "Spanish"), ("it_IT", "Italian"), ("nl_NL", "Dutch"), ("pt_PT", "Portuguese"),
         ("", "Don't hyphenate")]
DEFAULT_ACCENT = "#7A2E22"


def is_text(path: str) -> bool:
    return os.path.splitext(path)[1].lower() in TEXT_EXTS and os.path.isfile(path)


def book_name(src: str, size: str) -> str:
    stem = Path(src).stem
    return f"{stem} (for iPhone).pdf" if size == "iphone" else f"{stem}.pdf"


def _bookify():
    """bookify, imported when wanted (a plain import, so the app build takes it in; it raises ImportError
    without ReportLab)."""
    import bookify
    return bookify


def missing() -> str:
    """"" when bookify can run here, else what's missing."""
    try:
        import reportlab  # noqa: F401
    except ImportError:
        return "ReportLab"
    return ""


def install_command() -> list[str] | None:
    """The pip that installs ReportLab and pyphen into this Safe Finder's own Python (None in the built app)."""
    if getattr(sys, "frozen", False):
        return None
    return [sys.executable, "-m", "pip", "install", "--quiet", "reportlab>=4.0", "pyphen>=0.14"]


@dataclass
class BookHooks:
    place: Callable[[str, str, str], str] | None = None          # (temp file, folder, name) → where it went
    carry_tags: Callable[[list[tuple[str, str]]], None] | None = None
    reveal: Callable[[str], None] | None = None
    open_pdf: Callable[[str], None] | None = None
    made: Callable[[list[str]], None] | None = None


class _Bridge(QObject):
    progress = Signal(str)
    finished = Signal(object, str)               # [(source, book, summary)], why ("" — fine; "stopped")
    previewed = Signal(str, str, int, str)       # title, author, chapters, why
    installed = Signal(bool, str)


class BookWindow(QWidget):
    def __init__(self, sources: list[str], hooks: BookHooks | None = None, parent=None) -> None:
        super().__init__(parent, Qt.WindowType.Window)
        self.setAttribute(Qt.WidgetAttribute.WA_DeleteOnClose)
        self.sources = [s for s in sources if is_text(s)]
        self.hooks = hooks or BookHooks()
        self.settings = QSettings("PhotoBrowser", "SafeFinder")
        self.stop = threading.Event()
        self.running = False
        self.books: list[str] = []
        self.fonts_dir = str(self.settings.value("book/fonts", "") or "")
        self.accent = str(self.settings.value("book/accent", DEFAULT_ACCENT) or DEFAULT_ACCENT)
        self.bridge = _Bridge()
        self.bridge.progress.connect(self._progress)
        self.bridge.finished.connect(self._finished)
        self.bridge.previewed.connect(self._previewed)
        self.bridge.installed.connect(self._installed)
        one = len(self.sources) == 1
        self.setWindowTitle("Make Book PDF" + ("" if one else f" — {len(self.sources)} files"))

        v = QVBoxLayout(self)
        v.setContentsMargins(18, 16, 18, 16)
        v.setSpacing(10)
        title = QLabel("Make Book PDF", objectName="SheetTitle")
        v.addWidget(title)
        sub = QLabel((f"“{os.path.basename(self.sources[0])}” typeset like a printed book — a new PDF beside it."
                      if one else f"Each of these {len(self.sources)} files typeset like a printed book — a PDF "
                      "beside each."), objectName="SheetSub")
        sub.setWordWrap(True)
        v.addWidget(sub)
        self.found = QLabel("", objectName="SheetSub")
        self.found.setWordWrap(True)
        v.addWidget(self.found)

        form = QFormLayout()
        form.setHorizontalSpacing(12)
        form.setVerticalSpacing(8)
        self.title_edit = QLineEdit()
        self.author_edit = QLineEdit()
        if one:
            form.addRow("Title", self.title_edit)
            form.addRow("Author", self.author_edit)
        self.size = self._combo(SIZES, "book/size", "6x9")
        self.size.currentIndexChanged.connect(self._size_changed)
        form.addRow("Page size", self.size)
        self.font_size = QDoubleSpinBox()
        self.font_size.setRange(0, 16)
        self.font_size.setSingleStep(0.5)
        self.font_size.setDecimals(1)
        self.font_size.setSuffix(" pt")
        self.font_size.setSpecialValueText("Automatic — suits the page size")
        self.font_size.setValue(float(self.settings.value("book/font_size", 0) or 0))
        form.addRow("Text size", self.font_size)
        self.paper = self._combo(PAPERS, "book/paper", "texture")
        form.addRow("Paper", self.paper)
        self.lang = self._combo(LANGS, "book/lang", "en_US")
        form.addRow("Hyphenation", self.lang)
        accent_row = QHBoxLayout()
        self.accent_btn = QPushButton()
        self.accent_btn.setFixedWidth(44)
        self.accent_btn.clicked.connect(self._pick_accent)
        accent_reset = QPushButton("Oxblood")
        accent_reset.setToolTip("bookify's own: the deep red of the drop caps and ornaments")
        accent_reset.clicked.connect(lambda: self._set_accent(DEFAULT_ACCENT))
        accent_row.addWidget(self.accent_btn)
        accent_row.addWidget(accent_reset)
        accent_row.addStretch(1)
        form.addRow("Drop caps and ornaments", accent_row)
        fonts_row = QHBoxLayout()
        self.fonts_label = QLabel()
        self.fonts_label.setObjectName("SheetSub")
        fonts_pick = QPushButton("Use My Own Fonts…")
        fonts_pick.setToolTip("A folder of .ttf / .otf files with at least a Regular and an Italic")
        fonts_pick.clicked.connect(self._pick_fonts)
        self.fonts_reset = QPushButton("EB Garamond")
        self.fonts_reset.clicked.connect(lambda: self._set_fonts(""))
        fonts_row.addWidget(self.fonts_label, 1)
        fonts_row.addWidget(fonts_pick)
        fonts_row.addWidget(self.fonts_reset)
        form.addRow("Fonts", fonts_row)
        v.addLayout(form)

        self.toc = self._check("Contents page", "book/toc", True,
                               "A page listing the chapters, when there are two or more")
        self.toc_labels = self._check("“Chapter One: The Storm” in the contents", "book/toc_labels", False)
        self.dropcaps = self._check("Drop caps on chapter openings", "book/dropcaps", True)
        self.recto = self._check("Chapters start on a right-hand page, like print", "book/recto", False,
                                 "Adds a blank page before a chapter when needed")
        self.symmetric = self._check("Equal left and right margins — nicer on a screen", "book/symmetric", False,
                                     "Off: the inside margins are wider, like a bound book")
        for c in (self.toc, self.toc_labels, self.dropcaps, self.recto, self.symmetric):
            v.addWidget(c)
        self.size_hint = QLabel("", objectName="SheetSub")
        self.size_hint.setWordWrap(True)
        v.addWidget(self.size_hint)

        v.addStretch(1)
        self.bar = QProgressBar()
        self.bar.setRange(0, 0)
        self.bar.setVisible(False)
        v.addWidget(self.bar)
        self.status = QLabel("", objectName="SheetSub")
        self.status.setWordWrap(True)
        v.addWidget(self.status)
        buttons = QHBoxLayout()
        self.open_btn = QPushButton("Open")
        self.open_btn.clicked.connect(self._open_book)
        self.reveal_btn = QPushButton("Show in Folder")
        self.reveal_btn.clicked.connect(lambda: self.hooks.reveal(self.books[-1]) if self.books and self.hooks.reveal
                                        else None)
        self.install_btn = QPushButton("Install ReportLab")
        self.install_btn.clicked.connect(self._install)
        for b in (self.open_btn, self.reveal_btn, self.install_btn):
            b.setVisible(False)
            buttons.addWidget(b)
        buttons.addStretch(1)
        self.cancel = QPushButton("Close")
        self.cancel.clicked.connect(self._cancel)
        self.go = QPushButton("Make Book")
        self.go.setObjectName("Primary")
        self.go.setDefault(True)
        self.go.clicked.connect(self.start)
        buttons.addWidget(self.cancel)
        buttons.addWidget(self.go)
        v.addLayout(buttons)

        self._set_accent(self.accent)
        self._set_fonts(self.fonts_dir)
        self._size_changed()
        self.resize(600, max(560, v.totalHeightForWidth(600) + 40))
        if not self.sources:
            self.status.setText("Nothing here can be made into a book — .txt, .md and .rtf files can.")
            self.go.setEnabled(False)
        elif missing():
            self._need_install()
        elif one:
            self._preview()

    # ------------------------------------------------------------------ the form
    def _combo(self, choices: list[tuple[str, str]], key: str, default: str) -> QComboBox:
        box = QComboBox()
        for value, label in choices:
            box.addItem(label, value)
        saved = str(self.settings.value(key, default))
        i = box.findData(saved)
        box.setCurrentIndex(i if i >= 0 else box.findData(default))
        return box

    def _check(self, text: str, key: str, default: bool, tip: str = "") -> QCheckBox:
        c = QCheckBox(text)
        c.setChecked(str(self.settings.value(key, "true" if default else "false")) == "true")
        if tip:
            c.setToolTip(tip)
        return c

    def _size_changed(self, *_a) -> None:
        phone = self.size.currentData() == "iphone"
        # A screen has no spine: equal margins, and no blank pages to put chapters on the right — shown so (ticked
        # / unticked, greyed), and the person's own choices back when another size is picked.
        if phone and self.symmetric.isEnabled():
            self._own = (self.symmetric.isChecked(), self.recto.isChecked())
        if phone:
            self.symmetric.setChecked(True)
            self.recto.setChecked(False)
        elif not self.symmetric.isEnabled() and getattr(self, "_own", None):
            self.symmetric.setChecked(self._own[0])
            self.recto.setChecked(self._own[1])
        self.symmetric.setEnabled(not phone)
        self.recto.setEnabled(not phone)
        self.size_hint.setText(
            "iPhone: pages the shape of the iPhone 17 Pro Max's screen, so each fills it — 10-point type reads at "
            "about 15 on the phone; equal narrow margins, and chapters start on the next page (no blank ones). "
            "Saved as “<name> (for iPhone).pdf” — AirDrop it, or open it from the drive in Photo Browser."
            if phone else "")
        self.size_hint.setVisible(phone)

    def _set_accent(self, colour: str) -> None:
        self.accent = QColor(colour).name() if QColor(colour).isValid() else DEFAULT_ACCENT
        self.accent_btn.setStyleSheet(f"background: {self.accent}; border: 1px solid rgba(0,0,0,0.25); "
                                      "border-radius: 5px; min-height: 18px;")
        self.accent_btn.setToolTip(self.accent)

    def _pick_accent(self) -> None:
        c = QColorDialog.getColor(QColor(self.accent), self, "Drop caps and ornaments")
        if c.isValid():
            self._set_accent(c.name())

    def _set_fonts(self, folder: str) -> None:
        self.fonts_dir = folder
        self.fonts_label.setText(f"From “{os.path.basename(folder.rstrip(os.sep))}”" if folder
                                 else "EB Garamond — downloaded once, the first time")
        self.fonts_reset.setVisible(bool(folder))

    def _pick_fonts(self) -> None:
        d = QFileDialog.getExistingDirectory(self, "A folder of fonts (a Regular and an Italic at least)",
                                             self.fonts_dir or str(Path.home()))
        if d:
            self._set_fonts(d)

    def _remember(self) -> None:
        s = self.settings
        own = getattr(self, "_own", None) if not self.symmetric.isEnabled() else None
        s.setValue("book/size", self.size.currentData())
        s.setValue("book/paper", self.paper.currentData())
        s.setValue("book/lang", self.lang.currentData())
        s.setValue("book/font_size", self.font_size.value())
        s.setValue("book/accent", self.accent)
        s.setValue("book/fonts", self.fonts_dir)
        for c, key in ((self.toc, "toc"), (self.toc_labels, "toc_labels"), (self.dropcaps, "dropcaps"),
                       (self.recto, "recto"), (self.symmetric, "symmetric")):
            on = c.isChecked()
            if own is not None and key in ("symmetric", "recto"):       # the iPhone's forced ones aren't choices
                on = own[0] if key == "symmetric" else own[1]
            s.setValue(f"book/{key}", "true" if on else "false")

    # ------------------------------------------------------------------ what's in the file
    def _preview(self) -> None:
        src, bridge = self.sources[0], self.bridge

        def work() -> None:
            try:
                bookify = _bookify()
                title, author, chapters = bookify.preview(src)
                _emit(bridge.previewed, title or "", author or "", chapters, "")
            except Exception as e:  # noqa: BLE001 — a file it can't read is said when the book is made
                _emit(bridge.previewed, "", "", 0, str(e))
        threading.Thread(target=work, name="book-preview", daemon=True).start()

    def _previewed(self, title: str, author: str, chapters: int, why: str) -> None:
        if why:
            self.found.setText(f"This file couldn't be read: {why}")
            return
        self.title_edit.setPlaceholderText(title)
        self.author_edit.setPlaceholderText(author or "None found — leave empty for none")
        parts = [f"“{title}”" + (f" by {author}" if author else "")]
        parts.append(f"{chapters} chapter{'s' if chapters != 1 else ''}" if chapters else
                     "no chapter headings — one long chapter")
        self.found.setText("Found: " + " · ".join(parts) + ". Type a title or author to use another.")

    # ------------------------------------------------------------------ ReportLab
    def _need_install(self) -> None:
        self.go.setEnabled(False)
        if install_command() is None:
            self.status.setText("This copy of Safe Finder was built without ReportLab, which makes the books — "
                                "build it again with build_safe_finder_app.sh.")
            return
        self.status.setText("Making books needs ReportLab (and pyphen, for hyphenation) — they aren't installed in "
                            "Safe Finder's Python yet. Install them now? (A minute, once.)")
        self.install_btn.setVisible(True)

    def _install(self) -> None:
        cmd, bridge = install_command(), self.bridge
        if not cmd:
            return
        self.install_btn.setEnabled(False)
        self.bar.setVisible(True)
        self.status.setText("Installing ReportLab and pyphen…")

        def work() -> None:
            try:
                r = subprocess.run(cmd, capture_output=True, text=True, timeout=900)
                ok = r.returncode == 0
                why = "" if ok else ((r.stderr or r.stdout).strip().splitlines() or ["pip failed"])[-1]
            except (OSError, subprocess.SubprocessError) as e:
                ok, why = False, str(e)
            _emit(bridge.installed, ok, why)
        threading.Thread(target=work, name="book-install", daemon=True).start()

    def _installed(self, ok: bool, why: str) -> None:
        self.bar.setVisible(False)
        importlib.invalidate_caches()
        if ok and not missing():
            self.install_btn.setVisible(False)
            self.go.setEnabled(True)
            self.status.setText("Installed — ready to make the book.")
            if len(self.sources) == 1:
                self._preview()
        else:
            self.install_btn.setEnabled(True)
            self.status.setText(f"Couldn't install them: {why or 'unknown error'}. In Terminal: "
                                f"“{sys.executable} -m pip install reportlab pyphen”.")

    # ------------------------------------------------------------------ making the books
    def options(self) -> dict:
        phone = self.size.currentData() == "iphone"
        return dict(title=self.title_edit.text().strip() or None if len(self.sources) == 1 else None,
                    author=self.author_edit.text().strip() or None if len(self.sources) == 1 else None,
                    size=self.size.currentData(), font_size=self.font_size.value() or None,
                    paper=self.paper.currentData(), recto=self.recto.isChecked() and not phone,
                    symmetric=self.symmetric.isChecked() or phone, toc=self.toc.isChecked(),
                    toc_labels=self.toc_labels.isChecked(), dropcaps=self.dropcaps.isChecked(), accent=self.accent,
                    fonts=self.fonts_dir or None, lang=self.lang.currentData())

    def start(self) -> None:
        if self.running or not self.sources:
            return
        self._remember()
        self.running = True
        self.stop.clear()
        self.go.setEnabled(False)
        self.open_btn.setVisible(False)
        self.reveal_btn.setVisible(False)
        self.cancel.setText("Stop")
        self.bar.setVisible(True)
        self.status.setText("Starting…")
        sources, opts, stop, bridge, place = list(self.sources), self.options(), self.stop, self.bridge, self.hooks.place

        def work() -> None:
            done: list[tuple[str, str, object]] = []
            why = ""
            try:
                bookify = _bookify()
            except ImportError as e:
                _emit(bridge.finished, done, f"bookify can't run here ({e}).")
                return
            for n, src in enumerate(sources):
                pre = f"{os.path.basename(src)}: " if len(sources) > 1 else ""
                name = book_name(src, opts["size"])
                tmpdir = Path(tempfile.mkdtemp(prefix="safe-finder-book-"))
                try:
                    summary = bookify.make_book(src, tmpdir / name, progress=lambda t: _emit(bridge.progress, pre + t),
                                                stop=stop, **opts)
                    _emit(bridge.progress, pre + "Putting it beside the text…")
                    dest = place(str(tmpdir / name), str(Path(src).parent), name) if place else \
                        str(Path(src).with_name(name))
                    if not place:
                        os.replace(tmpdir / name, dest)
                    done.append((src, str(dest), summary))
                except bookify.Stopped:
                    why = "stopped"
                    break
                except (OSError, ValueError) as e:
                    why = f"{os.path.basename(src)}: {e}"
                except Exception as e:  # noqa: BLE001 — a text bookify chokes on is said, the others go on
                    why = f"{os.path.basename(src)} couldn't be typeset ({type(e).__name__}: {e})"
                finally:
                    shutil.rmtree(tmpdir, ignore_errors=True)
            _emit(bridge.finished, done, why)
        threading.Thread(target=work, name="book", daemon=True).start()

    def _progress(self, text: str) -> None:
        self.status.setText(text)

    def _finished(self, done: list, why: str) -> None:
        self.running = False
        self.bar.setVisible(False)
        self.go.setEnabled(True)
        self.go.setText("Make Again")
        self.cancel.setText("Close")
        made = [dest for _src, dest, _s in done]
        self.books = made
        if done and self.hooks.carry_tags is not None:
            self.hooks.carry_tags([(src, dest) for src, dest, _s in done])
        if done and self.hooks.made is not None:
            self.hooks.made(made)
        lines = []
        for _src, dest, s in done:
            size = "iPhone-screen pages" if s.size == "iphone" else dict(SIZES)[s.size].split(" — ")[0]
            chapters = f"{s.chapters} chapter{'s' if s.chapters != 1 else ''}" if s.chapters else "no chapters"
            lines.append(f"Made “{os.path.basename(dest)}” — {s.pages} pages, {chapters}, {size}, "
                         f"{s.font_size:g} pt {s.font}.")
        if why == "stopped":
            lines.append("Stopped.")
        elif why:
            lines.append(f"Couldn't make one: {why}")
        self.status.setText("\n".join(lines[-6:]) or "Nothing was made.")
        self.open_btn.setVisible(bool(made) and self.hooks.open_pdf is not None)
        self.reveal_btn.setVisible(bool(made) and self.hooks.reveal is not None)

    def _open_book(self) -> None:
        if self.books and self.hooks.open_pdf is not None:
            self.hooks.open_pdf(self.books[-1])

    def _cancel(self) -> None:
        if self.running:
            self.stop.set()
            self.status.setText("Stopping…")
        else:
            self.close()

    def closeEvent(self, event) -> None:  # noqa: N802
        self.stop.set()
        self._remember()
        super().closeEvent(event)


def _emit(signal, *args) -> None:
    try:
        signal.emit(*args)
    except RuntimeError:                          # the window closed meanwhile
        pass
