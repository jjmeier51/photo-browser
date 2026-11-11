"""Make Book PDF — Safe Finder's window for `bookify.py`: a plain-text, Markdown or RTF file typeset as a PDF that
looks and reads like a printed book (EB Garamond, justified and hyphenated, a title page, contents, chapter
openings with drop caps, running heads, cream paper). Right-click a .txt / .md / .rtf file ▸ Make Book PDF… (or
several: a book of each), or File ▸ Make Book PDF….

Every bookify option is here — title and author (found in the file when left empty: the window shows what it
found), page size (5 × 8 … US Letter, and **iPhone**: pages the shape of the iPhone 17 Pro Max's screen, one per
screen, no blank pages), text size, paper, the accent colour, hyphenation language, contents, drop caps, chapters on
right-hand pages, equal margins, your own fonts — and remembered for next time. **Save in**: beside the text (the
default) or a folder you choose (remembered too, and always shown, so a book never lands somewhere unexpected; a
folder that's gone — its drive unplugged — is said before anything is made). The book is "<name>.pdf" ("<name> (for
iPhone).pdf" for the iPhone size; never over a file), carries the text's tags, and opens in Safe Finder's PDF viewer
from here.

**Pictures.** Make Book first asks whether the book should have pictures. The book is made either way; with a
yes, the **Pictures** window (`PicturesDialog`) then opens over the finished book: add the pictures (any on the Mac
or the drive), and say for each one **where** — at the front, at the start or end of a chapter (the book's own
chapters, with their pages), on a page (a number of the book just made — Open the Book is there to look), or at
the end — and **how** — a page of its own, across the text, or half its width — with an optional caption. **Add to
the Book** sets the book again with the pictures in and puts it in place of the one just made (`BookHooks.replace`).
"On a page" is turned into "after the paragraph that falls there" from where the paragraphs landed
(`bookify.element_for_page`), so a picture stays with its text however the pages move. The choices are remembered
per text (`book/pictures/<id>` in the settings) and offered again the next time that text is made into a book;
**Pictures…** on the finished line reopens the window to change them. With several texts the window opens for
each book in turn.

bookify needs ReportLab (and pyphen for hyphenation; both in requirements.txt). When this copy of Safe Finder
hasn't got them, the window's main button becomes **Install ReportLab** (never a dead Make Book): run from the
source it pip-installs them into its own Python; the built app — which has them inside when it was built from a
.venv that had them (build_safe_finder_app.sh now makes sure) — installs them into its own folder,
~/Library/Application Support/Safe Finder/python (`PRIVATE`, read at import), with any Python 3 on the Mac. They're
pure Python (py3-none-any wheels), so pip fetches exactly those for the app's Python version, whatever Python runs
pip. The first book downloads the EB Garamond fonts once (bookify caches them).

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

from PySide6.QtCore import QObject, QSettings, QSize, Qt, Signal
from PySide6.QtGui import QColor, QImageReader, QPixmap
from PySide6.QtWidgets import (QCheckBox, QColorDialog, QComboBox, QDialog, QDoubleSpinBox, QFileDialog, QFormLayout,
                               QFrame, QHBoxLayout, QLabel, QLineEdit, QMessageBox, QProgressBar, QPushButton,
                               QScrollArea, QSpinBox, QVBoxLayout, QWidget)

TEXT_EXTS = {".txt", ".text", ".md", ".markdown", ".rtf"}
SIZES = [("6x9", "6 × 9 in — a trade paperback"), ("5.5x8.5", "5.5 × 8.5 in"), ("5x8", "5 × 8 in — a pocket novel"),
         ("a5", "A5"), ("letter", "US Letter"), ("iphone", "iPhone 17 Pro Max — a page per screen")]
PAPERS = [("texture", "Cream, with a paper texture"), ("flat", "Flat cream"), ("white", "White — for printing")]
LANGS = [("en_US", "English (US)"), ("en_GB", "English (UK)"), ("de_DE", "German"), ("fr_FR", "French"),
         ("es_ES", "Spanish"), ("it_IT", "Italian"), ("nl_NL", "Dutch"), ("pt_PT", "Portuguese"),
         ("", "Don't hyphenate")]
DEFAULT_ACCENT = "#7A2E22"
# Where the built app keeps ReportLab and pyphen when it was built without them (module notes).
PRIVATE = Path.home() / "Library" / "Application Support" / "Safe Finder" / "python"
PURE = ["reportlab>=4.0", "pyphen>=0.14", "charset-normalizer"]      # ReportLab's own needs, less Pillow (inside)


def _use_private() -> None:
    p = str(PRIVATE)
    if PRIVATE.is_dir() and p not in sys.path:
        sys.path.append(p)                       # after the app's own modules: it only adds what's missing


_use_private()


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


def _system_python() -> str | None:
    """A Python 3 on this Mac that has pip (for the built app, which can't run pip itself)."""
    candidates = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3",
                  "/Library/Frameworks/Python.framework/Versions/Current/bin/python3"]
    # Apple's /usr/bin/python3 is a stub that offers to install the Command Line Tools when they're missing.
    if subprocess.run(["xcode-select", "-p"], capture_output=True).returncode == 0:
        candidates.append("/usr/bin/python3")
    for py in candidates:
        if os.path.exists(py):
            try:
                if subprocess.run([py, "-m", "pip", "--version"], capture_output=True, timeout=30).returncode == 0:
                    return py
            except (OSError, subprocess.SubprocessError):
                continue
    return None


def install_command() -> list[str] | None:
    """The pip that installs ReportLab and pyphen: into this Safe Finder's own Python when it runs from the
    source; for the built app, into `PRIVATE` by a Python on the Mac — pure-Python wheels for the app's own
    Python version. None when there's no way (the built app, and no Python with pip on the Mac)."""
    if not getattr(sys, "frozen", False):
        return [sys.executable, "-m", "pip", "install", "--quiet", "reportlab>=4.0", "pyphen>=0.14"]
    py = _system_python()
    if py is None:
        return None
    return [py, "-m", "pip", "install", "--quiet", "--upgrade", "--target", str(PRIVATE), "--no-deps",
            "--only-binary=:all:", "--implementation", "py",
            "--python-version", f"{sys.version_info[0]}.{sys.version_info[1]}", *PURE]


PICTURE_EXTS = {".jpg", ".jpeg", ".png", ".heic", ".heif", ".webp", ".tif", ".tiff", ".bmp", ".gif"}
WHERES = [("front", "At the front — after the title page"), ("chapter_start", "At the start of a chapter"),
          ("chapter_end", "At the end of a chapter"), ("page", "On a page"), ("end", "At the end of the book")]
PIC_SIZES = [("page", "A page of its own"), ("wide", "Across the text"), ("half", "Half the width")]


@dataclass
class BookHooks:
    place: Callable[[str, str, str], str] | None = None          # (temp file, folder, name) → where it went
    replace: Callable[[str, str], None] | None = None            # (temp file, the book made a moment ago) — over it
    carry_tags: Callable[[list[tuple[str, str]]], None] | None = None
    reveal: Callable[[str], None] | None = None
    open_pdf: Callable[[str], None] | None = None
    made: Callable[[list[str]], None] | None = None


class _Bridge(QObject):
    progress = Signal(str)
    finished = Signal(object, str)               # [(source, book, summary)], why ("" — fine; "stopped")
    previewed = Signal(str, str, int, str)       # title, author, chapters, why
    installed = Signal(bool, str)
    pictured = Signal(int, object, str)          # which book, its new summary (None: it couldn't be), why


def picture_thumb(path: str, side: int = 56) -> QPixmap:
    """A small picture of the picture (blank when Qt can't read it — an HEIC; the book still can)."""
    reader = QImageReader(path)
    reader.setAutoTransform(True)
    size = reader.size()
    if size.isValid() and max(size.width(), size.height()) > side * 2:
        reader.setScaledSize(size.scaled(QSize(side * 2, side * 2), Qt.AspectRatioMode.KeepAspectRatio))
    img = reader.read()
    if img.isNull():
        pm = QPixmap(side, side)
        pm.fill(QColor("#8E8E93"))
        return pm
    pm = QPixmap.fromImage(img).scaled(side * 2, side * 2, Qt.AspectRatioMode.KeepAspectRatio,
                                       Qt.TransformationMode.SmoothTransformation)
    pm.setDevicePixelRatio(2)
    return pm


class _PictureRow(QFrame):
    """One picture and its choices."""

    def __init__(self, dialog: "PicturesDialog", placement: dict) -> None:
        super().__init__()
        self.dialog, self.path = dialog, placement["path"]
        self.anchor = placement if placement.get("where") == "after" else None     # a place kept from last time
        self.setFrameShape(QFrame.Shape.StyledPanel)
        s = dialog.summary
        thumb = QLabel()
        thumb.setPixmap(picture_thumb(self.path))
        thumb.setFixedSize(60, 60)
        thumb.setAlignment(Qt.AlignmentFlag.AlignCenter)
        name = QLabel(os.path.basename(self.path))
        name.setToolTip(self.path)
        name.setMinimumWidth(120)
        self.where = QComboBox()
        for value, label in WHERES:
            if value.startswith("chapter") and not dialog.chapters:
                continue
            self.where.addItem(label, value)
        self.chapter = QComboBox()
        for i, (title, page) in dialog.chapters:
            self.chapter.addItem(f"{title} — page {page}", i)
        self.page = QSpinBox()
        self.page.setRange(1, max(1, s.pages))
        self.page.setPrefix("page ")
        self.page.setToolTip("A page of the book as it is now. The picture goes with the text on that page, so it "
                             "lands there or just after; the pages after it move on.")
        self.size = QComboBox()
        for value, label in PIC_SIZES:
            self.size.addItem(label, value)
        self.caption = QLineEdit(placement.get("caption", ""))
        self.caption.setPlaceholderText("Caption (optional)")
        remove = QPushButton("Remove")
        remove.clicked.connect(lambda: dialog.remove_row(self))
        top = QHBoxLayout()
        top.addWidget(name, 1)
        top.addWidget(remove)
        mid = QHBoxLayout()
        mid.addWidget(self.where, 2)
        mid.addWidget(self.chapter, 2)
        mid.addWidget(self.page)
        mid.addWidget(self.size, 1)
        col = QVBoxLayout()
        col.setSpacing(4)
        col.addLayout(top)
        col.addLayout(mid)
        col.addWidget(self.caption)
        row = QHBoxLayout(self)
        row.setContentsMargins(8, 8, 8, 8)
        row.addWidget(thumb)
        row.addLayout(col, 1)
        # what it was last time (or the usual: its own page at the end)
        where, index = placement.get("where", "end"), int(placement.get("index", 0) or 0)
        if where == "after":
            first_last = s.el_pages.get(index)
            own = placement.get("size", "page") == "page"
            self.page.setValue(min(s.pages, (first_last[1] + (1 if own else 0)) if first_last else 1))
            where = "page"
        elif where == "page":
            self.page.setValue(max(1, min(s.pages, index)))
        i = self.where.findData(where)
        self.where.setCurrentIndex(i if i >= 0 else self.where.findData("end"))
        if where.startswith("chapter"):
            self.chapter.setCurrentIndex(max(0, self.chapter.findData(index)))
        self.size.setCurrentIndex(max(0, self.size.findData(placement.get("size", "page"))))
        self._kept_page = self.page.value()
        self.where.currentIndexChanged.connect(self._where_changed)
        self._where_changed()

    def _where_changed(self, *_a) -> None:
        where = self.where.currentData()
        self.chapter.setVisible(where in ("chapter_start", "chapter_end"))
        self.page.setVisible(where == "page")
        self.size.setEnabled(where not in ("front",))
        if where == "front":
            self.size.setCurrentIndex(self.size.findData("page"))

    def placement(self) -> dict:
        """What bookify is told: "on a page" as "after the paragraph that's there"."""
        import_bookify = _bookify()
        where, size = self.where.currentData(), self.size.currentData()
        out = {"path": self.path, "where": where, "index": 0, "size": size, "caption": self.caption.text().strip()}
        if where in ("chapter_start", "chapter_end"):
            out["index"] = int(self.chapter.currentData() or 0)
        elif where == "page":
            keep = self.anchor is not None and self.page.value() == self._kept_page and self.anchor.get("size") == size
            if keep:                                            # untouched since last time: the same paragraph
                out.update(where="after", index=int(self.anchor["index"]))
            else:
                el = import_bookify.element_for_page(self.dialog.summary.el_pages, self.page.value(), size == "page")
                out.update(where="front", index=0) if el is None else out.update(where="after", index=int(el))
        return out


class PicturesDialog(QDialog):
    """Which pictures go in the book just made, and where. `placements()` is the answer when accepted."""

    def __init__(self, parent, book: str, source: str, summary, hooks: BookHooks, before: list[dict] | None = None) -> None:
        super().__init__(parent)
        self.book, self.source, self.summary, self.hooks = book, source, summary, hooks
        # The chapters a picture can go at: those with a name (an untitled opening isn't one to choose).
        self.chapters = [(i, (title, page)) for i, (title, page) in enumerate(summary.chapter_list) if title]
        self.rows: list[_PictureRow] = []
        self.setWindowTitle(f"Pictures — {os.path.basename(book)}")
        self.resize(720, 560)
        head = QLabel(f"“{summary.title}” is made — {summary.pages} pages. Add the pictures you'd like in it and say "
                      "where each one goes; the book is then set again with them in.")
        head.setWordWrap(True)
        add = QPushButton("Add Pictures…")
        add.clicked.connect(self.choose)
        look = QPushButton("Open the Book")
        look.setToolTip("Look through the book to decide where the pictures go")
        look.clicked.connect(lambda: hooks.open_pdf(book) if hooks.open_pdf else None)
        look.setVisible(hooks.open_pdf is not None)
        tools = QHBoxLayout()
        tools.addWidget(add)
        tools.addWidget(look)
        tools.addStretch(1)
        self.count = QLabel("")
        tools.addWidget(self.count)
        self.list = QVBoxLayout()
        self.list.setSpacing(6)
        self.list.addStretch(1)
        inner = QWidget()
        inner.setLayout(self.list)
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setWidget(inner)
        self.empty = QLabel("No pictures yet — press Add Pictures… and choose one or more.")
        self.empty.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.empty.setObjectName("SheetSub")
        cancel = QPushButton("No Pictures")
        cancel.clicked.connect(self.reject)
        self.ok = QPushButton("Add to the Book")
        self.ok.setObjectName("Primary")
        self.ok.setDefault(True)
        self.ok.clicked.connect(self.accept)
        buttons = QHBoxLayout()
        buttons.addStretch(1)
        buttons.addWidget(cancel)
        buttons.addWidget(self.ok)
        lay = QVBoxLayout(self)
        lay.addWidget(head)
        lay.addLayout(tools)
        lay.addWidget(self.empty)
        lay.addWidget(scroll, 1)
        lay.addLayout(buttons)
        for p in before or []:
            if os.path.isfile(p.get("path", "")):
                self.add_row(p)
        self._refresh()

    def choose(self) -> None:
        start = os.path.dirname(self.rows[-1].path) if self.rows else os.path.dirname(self.source)
        exts = " ".join(f"*{e}" for e in sorted(PICTURE_EXTS))
        files, _ = QFileDialog.getOpenFileNames(self, "Pictures for the book", start, f"Pictures ({exts});;All files (*)")
        self.add_files(files)

    def add_files(self, files: list[str]) -> None:
        for f in files:
            if os.path.splitext(f)[1].lower() in PICTURE_EXTS and os.path.isfile(f):
                self.add_row({"path": f, "where": "end", "size": "page"})
        self._refresh()

    def add_row(self, placement: dict) -> None:
        row = _PictureRow(self, placement)
        self.rows.append(row)
        self.list.insertWidget(self.list.count() - 1, row)

    def remove_row(self, row: _PictureRow) -> None:
        self.rows.remove(row)
        row.setParent(None)
        row.deleteLater()
        self._refresh()

    def _refresh(self) -> None:
        n = len(self.rows)
        self.empty.setVisible(n == 0)
        self.count.setText(f"{n} picture{'s' if n != 1 else ''}" if n else "")
        self.ok.setEnabled(n > 0)
        self.ok.setText(f"Add {n} Picture{'s' if n != 1 else ''} to the Book" if n else "Add to the Book")

    def placements(self) -> list[dict]:
        return [r.placement() for r in self.rows]


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
        self.done: list[tuple[str, str, object]] = []         # (text, book, bookify's summary) of the last run
        self.want_pictures = False
        self.pictures: dict[str, list[dict]] = {}             # text → the pictures chosen for its book
        self._queue: list[int] = []                           # books still to be asked about, in turn
        self.fonts_dir = str(self.settings.value("book/fonts", "") or "")
        self.dest = str(self.settings.value("book/dest", "") or "")      # "" = beside each text
        self.accent = str(self.settings.value("book/accent", DEFAULT_ACCENT) or DEFAULT_ACCENT)
        self.bridge = _Bridge()
        self.bridge.progress.connect(self._progress)
        self.bridge.finished.connect(self._finished)
        self.bridge.previewed.connect(self._previewed)
        self.bridge.installed.connect(self._installed)
        self.bridge.pictured.connect(self._pictured)
        one = len(self.sources) == 1
        self.setWindowTitle("Make Book PDF" + ("" if one else f" — {len(self.sources)} files"))

        v = QVBoxLayout(self)
        v.setContentsMargins(18, 16, 18, 16)
        v.setSpacing(10)
        title = QLabel("Make Book PDF", objectName="SheetTitle")
        v.addWidget(title)
        self.sub = QLabel("", objectName="SheetSub")
        self.sub.setWordWrap(True)
        v.addWidget(self.sub)
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
        dest_row = QHBoxLayout()
        self.dest_label = QLabel()
        self.dest_label.setWordWrap(True)
        dest_pick = QPushButton("Choose Folder…")
        dest_pick.setToolTip("Save the book in another folder — on this Mac or a drive")
        dest_pick.clicked.connect(self._pick_dest)
        self.dest_reset = QPushButton("Beside the Text")
        self.dest_reset.setToolTip("Save the book in the same folder as its text")
        self.dest_reset.clicked.connect(lambda: self._set_dest(""))
        dest_row.addWidget(self.dest_label, 1)
        dest_row.addWidget(dest_pick)
        dest_row.addWidget(self.dest_reset)
        form.addRow("Save in", dest_row)
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
        self.pictures_btn = QPushButton("Pictures…")
        self.pictures_btn.setToolTip("Add pictures to the book just made — or change the ones in it")
        self.pictures_btn.clicked.connect(lambda: self._ask_pictures(len(self.done) - 1) if self.done else None)
        for b in (self.open_btn, self.reveal_btn, self.pictures_btn):
            b.setVisible(False)
            buttons.addWidget(b)
        buttons.addStretch(1)
        self.cancel = QPushButton("Close")
        self.cancel.clicked.connect(self._cancel)
        self.go = QPushButton("Make Book")
        self.go.setObjectName("Primary")
        self.go.setDefault(True)
        self.go.clicked.connect(self.start)
        # Without ReportLab this is the main button instead of Make Book — a way forward, never a dead button.
        self.install_btn = QPushButton("Install ReportLab")
        self.install_btn.setObjectName("Primary")
        self.install_btn.clicked.connect(self._install)
        self.install_btn.setVisible(False)
        buttons.addWidget(self.cancel)
        buttons.addWidget(self.install_btn)
        buttons.addWidget(self.go)
        v.addLayout(buttons)

        self._set_accent(self.accent)
        self._set_fonts(self.fonts_dir)
        self._set_dest(self.dest)
        self._size_changed()
        self.resize(600, max(560, v.totalHeightForWidth(600) + 40))
        if not self.sources:
            self._notice("Nothing here can be made into a book — .txt, .md and .rtf files can.")
            self.go.setEnabled(False)
            self.go.setToolTip("Select a .txt, .md or .rtf file first")
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

    def _set_dest(self, folder: str) -> None:
        """Where the books go: `folder`, or "" — beside each text."""
        self.dest = folder
        one = len(self.sources) == 1
        if folder:
            where = f"“{os.path.basename(folder.rstrip(os.sep)) or folder}”"
            gone = "" if os.path.isdir(folder) else " — not there now (is its drive connected?)"
            self.dest_label.setText(where + gone)
            self.dest_label.setToolTip(folder)
            self.dest_label.setStyleSheet("font-weight: 600;" if gone else "")
        else:
            self.dest_label.setText("Beside the text" if one else "Beside each text")
            self.dest_label.setToolTip(os.path.dirname(self.sources[0]) if one and self.sources else "")
            self.dest_label.setStyleSheet("")
        self.dest_reset.setVisible(bool(folder))
        if not self.sources:
            self.sub.setText("")
        elif one:
            self.sub.setText(f"“{os.path.basename(self.sources[0])}” typeset like a printed book — a new PDF "
                             + (f"in {where}." if folder else "beside it."))
        else:
            self.sub.setText(f"Each of these {len(self.sources)} files typeset like a printed book — "
                             + (f"their PDFs in {where}." if folder else "a PDF beside each."))

    def _pick_dest(self) -> None:
        start = self.dest if self.dest and os.path.isdir(self.dest) else \
            (os.path.dirname(self.sources[0]) if self.sources else str(Path.home()))
        d = QFileDialog.getExistingDirectory(self, "Save the book in", start)
        if d:
            # Picking the text's own folder is the same as "beside the text" (and stays so if the text moves).
            same = len(self.sources) == 1 and os.path.normpath(d) == os.path.normpath(os.path.dirname(self.sources[0]))
            self._set_dest("" if same else d)

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
        s.setValue("book/dest", self.dest)
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
    def _notice(self, text: str) -> None:
        """Something the person has to know (why the book can't be made yet): plain to see, not a grey aside."""
        self.status.setText(text)
        self.status.setStyleSheet("font-weight: 600;")

    def _need_install(self) -> None:
        self.go.setVisible(False)
        self.install_btn.setVisible(True)
        self.install_btn.setDefault(True)
        self._notice("Making books needs ReportLab (and pyphen, for hyphenation), and this Safe Finder hasn't got "
                     "them yet. Install ReportLab adds them — a minute, once — and then Make Book is here.")

    def _install(self) -> None:
        cmd, bridge = install_command(), self.bridge
        if not cmd:
            self._notice("There's no Python with pip on this Mac to fetch ReportLab with. Either install Xcode's "
                         "Command Line Tools (in Terminal: xcode-select --install) and press Install ReportLab "
                         "again, or build Safe Finder again with mac/build_safe_finder_app.sh — it puts ReportLab "
                         "inside the app.")
            return
        self.install_btn.setEnabled(False)
        self.bar.setVisible(True)
        self._notice("Installing ReportLab and pyphen…")

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
        _use_private()
        if ok and not missing():
            self.install_btn.setVisible(False)
            self.go.setVisible(True)
            self.go.setEnabled(True)
            self.go.setDefault(True)
            self.status.setStyleSheet("")
            self.status.setText("Installed — ready to make the book.")
            if len(self.sources) == 1:
                self._preview()
        else:
            self.install_btn.setEnabled(True)
            how = (f"in Terminal: “{sys.executable} -m pip install reportlab pyphen”"
                   if not getattr(sys, "frozen", False) else
                   "or build Safe Finder again with mac/build_safe_finder_app.sh, which puts ReportLab inside the app")
            self._notice(f"Couldn't install them ({why or 'unknown error'}). Try again (are you online?), {how}.")

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
        if self.dest and not os.path.isdir(self.dest):
            self._notice(f"“{self.dest}” isn't there now — is its drive connected? Choose another folder, or save "
                         "beside the text.")
            self._set_dest(self.dest)
            return
        answer = self.ask_about_pictures()
        if answer is None:
            return
        self.want_pictures = answer
        self._remember()
        self.status.setStyleSheet("")
        self.running = True
        self.stop.clear()
        self.go.setEnabled(False)
        self.open_btn.setVisible(False)
        self.reveal_btn.setVisible(False)
        self.pictures_btn.setVisible(False)
        self.cancel.setText("Stop")
        self.bar.setVisible(True)
        self.status.setText("Starting…")
        sources, opts, stop, bridge, place = list(self.sources), self.options(), self.stop, self.bridge, self.hooks.place
        dest = self.dest

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
                    folder = dest or str(Path(src).parent)
                    _emit(bridge.progress, pre + (f"Putting it in “{os.path.basename(folder)}”…" if dest
                                                  else "Putting it beside the text…"))
                    if place:
                        made = place(str(tmpdir / name), folder, name)
                    else:
                        made = str(Path(folder) / name)
                        shutil.copyfile(tmpdir / name, made)
                    done.append((src, str(made), summary))
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
            where = "" if os.path.dirname(dest) == os.path.dirname(_src) else \
                f" in “{os.path.basename(os.path.dirname(dest))}”"
            lines.append(f"Made “{os.path.basename(dest)}”{where} — {s.pages} pages, {chapters}, {size}, "
                         f"{s.font_size:g} pt {s.font}.")
        if why == "stopped":
            lines.append("Stopped.")
        elif why:
            lines.append(f"Couldn't make one: {why}")
        self.status.setText("\n".join(lines[-6:]) or "Nothing was made.")
        self.open_btn.setVisible(bool(made) and self.hooks.open_pdf is not None)
        self.reveal_btn.setVisible(bool(made) and self.hooks.reveal is not None)
        self.pictures_btn.setVisible(bool(made))
        self.done = list(done)
        if done and self.want_pictures and why != "stopped":
            self._queue = list(range(len(done)))
            self._next_pictures()

    # ------------------------------------------------------------------ pictures
    def ask_about_pictures(self) -> bool | None:
        """Before the book is made: pictures or not? None: don't make it after all."""
        one = len(self.sources) == 1
        box = QMessageBox(self)
        box.setWindowTitle("Make Book PDF")
        box.setIcon(QMessageBox.Icon.Question)
        box.setText("Would you like to add pictures to " + ("this book?" if one else "these books?"))
        kept = sum(1 for p in self._remembered(self.sources[0]) if os.path.isfile(p.get("path", ""))) if one else 0
        box.setInformativeText(
            "The book is made first. Then you choose the pictures and where each one goes — at the front, in a "
            "chapter, on a page or at the end — and the book is set again with them in."
            + (f"\n\nThe {kept} picture{'s' if kept != 1 else ''} chosen for this text last time will be offered again."
               if kept else ""))
        yes = box.addButton("Add Pictures", QMessageBox.ButtonRole.YesRole)
        no = box.addButton("No Pictures", QMessageBox.ButtonRole.NoRole)
        box.addButton(QMessageBox.StandardButton.Cancel)
        box.setDefaultButton(no)
        box.exec()
        clicked = box.clickedButton()
        return True if clicked is yes else False if clicked is no else None

    def _key(self, source: str) -> str:
        import hashlib
        return "book/pictures/" + hashlib.sha1(os.path.abspath(source).encode("utf-8")).hexdigest()[:16]

    def _remembered(self, source: str) -> list[dict]:
        import json
        try:
            got = json.loads(str(self.settings.value(self._key(source), "") or "[]"))
            return [p for p in got if isinstance(p, dict) and p.get("path")] if isinstance(got, list) else []
        except ValueError:
            return []

    def _next_pictures(self) -> None:
        if self._queue and not self.running:
            self._ask_pictures(self._queue.pop(0))

    def _ask_pictures(self, n: int) -> None:
        """The Pictures window for the n-th book made, then the book set again with what was chosen."""
        if self.running or not 0 <= n < len(self.done):
            return
        src, book, summary = self.done[n]
        if not os.path.isfile(book):
            self._notice(f"“{os.path.basename(book)}” isn't there any more — make the book again.")
            return
        before = self.pictures.get(src) or self._remembered(src)
        dlg = PicturesDialog(self, book, src, summary, self.hooks, before)
        if dlg.exec() != QDialog.DialogCode.Accepted:
            self._next_pictures()
            return
        chosen = dlg.placements()
        self.pictures[src] = chosen
        import json
        self.settings.setValue(self._key(src), json.dumps(chosen))
        self._add_pictures(n, chosen)

    def _add_pictures(self, n: int, pictures: list[dict]) -> None:
        src, book, _summary = self.done[n]
        self.running = True
        self.stop.clear()
        for b in (self.go, self.pictures_btn):
            b.setEnabled(False)
        self.cancel.setText("Stop")
        self.bar.setVisible(True)
        self.status.setStyleSheet("")
        self.status.setText("Setting the book with its pictures…")
        opts, stop, bridge, replace = self.options(), self.stop, self.bridge, self.hooks.replace

        def work() -> None:
            try:
                bookify = _bookify()
            except ImportError as e:
                _emit(bridge.pictured, n, None, f"bookify can't run here ({e}).")
                return
            tmpdir = Path(tempfile.mkdtemp(prefix="safe-finder-book-"))
            tmp = tmpdir / os.path.basename(book)
            try:
                summary = bookify.make_book(src, tmp, progress=lambda t: _emit(bridge.progress, t), stop=stop,
                                            pictures=pictures, **opts)
                _emit(bridge.progress, "Putting it in place of the book without pictures…")
                if replace:
                    replace(str(tmp), book)
                else:
                    shutil.copyfile(tmp, book)
                _emit(bridge.pictured, n, summary, "")
            except bookify.Stopped:
                _emit(bridge.pictured, n, None, "stopped")
            except (OSError, ValueError) as e:
                _emit(bridge.pictured, n, None, str(e))
            except Exception as e:  # noqa: BLE001
                _emit(bridge.pictured, n, None, f"the book couldn't be set with its pictures ({type(e).__name__}: {e})")
            finally:
                shutil.rmtree(tmpdir, ignore_errors=True)
        threading.Thread(target=work, name="book-pictures", daemon=True).start()

    def _pictured(self, n: int, summary, why: str) -> None:
        self.running = False
        self.bar.setVisible(False)
        for b in (self.go, self.pictures_btn):
            b.setEnabled(True)
        self.cancel.setText("Close")
        src, book, old = self.done[n]
        if summary is not None:
            self.done[n] = (src, book, summary)
            k = summary.pictures
            self.status.setText(f"“{os.path.basename(book)}” now has {k} picture{'s' if k != 1 else ''} — "
                                f"{summary.pages} pages (it had {old.pages}).")
            if self.hooks.made is not None:
                self.hooks.made([book])
        elif why == "stopped":
            self.status.setText(f"Stopped — “{os.path.basename(book)}” is as it was, without the pictures.")
        else:
            self._notice(f"The pictures couldn't be added — {why} “{os.path.basename(book)}” is as it was.")
        self._next_pictures()

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
