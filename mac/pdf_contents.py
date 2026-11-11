"""A PDF's table of contents, for Safe Finder's PDF viewer: where its chapters are, and what a click on a
contents page means.

Two sources, best first:

1. **The PDF's own outline** (its bookmarks — what Preview shows in its sidebar). Books made by bookify have
   one; so do most published PDFs.
2. **The contents page itself, read as text.** Many PDFs — scans with a text layer, exports from a word
   processor — have a contents page whose numbers aren't links and no outline at all. `entries` reads a page's
   lines for the shape "a title … a number" (dot leaders, or just a gap; the number may sit on a line of its
   own at the same height) and keeps where each line is on the page, so the viewer can tell which entry was
   clicked. A page counts as a contents page when it has several such lines whose numbers go up.

**Which page a printed number means** (`Reader.resolve`): the number in a contents page is the one *printed*
on the page, which in most books isn't the PDF's own count (a cover, a title page and the contents come
first). So: the PDF's page labels when it has real ones; else the offset between printed and real numbers,
found by reading the folios on a spread of pages (`offset` — the first or last line of a page when it's just
a number; the commonest difference wins); then the pages around that are looked at for the entry's own title
near the top — the earliest one that has it is the chapter's opening — which corrects an offset that's a page
or two out. Roman numerals go by the labels alone.

Everything here runs on the GUI thread (Qt's PDF document isn't to be shared across threads) and is lazy and
cached: a page's text is read when it's first needed.
"""
from __future__ import annotations

import re
from dataclasses import dataclass

from PySide6.QtCore import QModelIndex, QPointF, QRectF

LEADER = r"[\s.·•…_‥⋯\-–—]"
LINE = re.compile(rf"^(?P<title>.*?\w.*?)(?P<gap>{LEADER}{{2,}}|\s+)(?P<num>\d{{1,4}}|[ivxlcdm]{{1,8}})\s*$", re.I)
ONLY_NUMBER = re.compile(r"^\s*(\d{1,4}|[ivxlcdm]{1,8})\s*$", re.I)
ROMAN = re.compile(r"^(?=[ivxlcdm]+$)m{0,3}(cm|cd|d?c{0,3})(xc|xl|l?x{0,3})(ix|iv|v?i{0,3})$", re.I)
MIN_ENTRIES = 3                  # this many numbered lines, rising, make a contents page
SCAN_PAGES = 40                  # how far into a PDF a contents page is looked for
FOLIO_SAMPLES = 48               # pages read for their printed numbers


@dataclass
class Entry:
    title: str
    number: str                  # as printed: "12", "xii"
    rect: QRectF                 # the whole line, in the page's points (origin top-left)
    number_rect: QRectF
    leaders: bool                # the line has dot leaders (a contents line for sure)


@dataclass
class Chapter:
    title: str
    page: int                    # the PDF's own page, from 0
    level: int = 0


def roman_value(s: str) -> int | None:
    if not ROMAN.match(s or ""):
        return None
    vals = dict(i=1, v=5, x=10, l=50, c=100, d=500, m=1000)
    total, prev = 0, 0
    for ch in reversed(s.lower()):
        v = vals[ch]
        total += v if v >= prev else -v
        prev = max(prev, v)
    return total


def _norm(s: str) -> str:
    return re.sub(r"[^a-z0-9]+", "", s.lower())


def _units(s: str) -> int:
    """Length as the PDF library counts it (UTF-16 units)."""
    return len(s.encode("utf-16-le")) // 2


class Reader:
    """One open document's contents knowledge."""

    def __init__(self, doc) -> None:
        self.doc = doc
        self._text: dict[int, str] = {}
        self._entries: dict[int, list[Entry]] = {}
        self._offset: int | None = None
        self._labels: bool | None = None
        self._chapters: list[Chapter] | None = None

    # -- text
    def text(self, page: int) -> str:
        if page not in self._text:
            try:
                self._text[page] = self.doc.getAllText(page).text()
            except Exception:  # noqa: BLE001 — a page the library can't read has no text
                self._text[page] = ""
            if len(self._text) > 400:
                for k in list(self._text)[:200]:
                    self._text.pop(k, None)
        return self._text[page]

    def _rect(self, page: int, start: int, length: int) -> QRectF:
        try:
            return self.doc.getSelectionAtIndex(page, start, length).boundingRectangle()
        except Exception:  # noqa: BLE001
            return QRectF()

    # -- a contents page's lines
    def entries(self, page: int) -> list[Entry]:
        """The "title … number" lines on `page` — [] unless it reads as a contents page."""
        if page in self._entries:
            return self._entries[page]
        text = self.text(page)
        found: list[Entry] = []
        lines: list[tuple[str, int]] = []            # (line, index of its first character in UTF-16 units)
        pos = 0
        for raw in re.split(r"(\r\n|\n|\r)", text):
            if raw in ("\r\n", "\n", "\r"):
                pos += _units(raw)
                continue
            lines.append((raw, pos))
            pos += _units(raw)
        pending: tuple[str, int] | None = None       # a titled line with no number yet (its number may follow)
        for line, start in lines:
            stripped = line.strip()
            if not stripped:
                continue
            only = ONLY_NUMBER.match(line)
            if only and pending is not None:
                title, tstart = pending
                trect = self._rect(page, tstart, _units(title))
                nrect = self._rect(page, start + _units(line[:only.start(1)]), _units(only.group(1)))
                same_row = trect.isValid() and nrect.isValid() and \
                    abs(trect.center().y() - nrect.center().y()) <= max(trect.height(), nrect.height()) * 0.7
                if same_row and self._number_ok(only.group(1)):
                    found.append(Entry(self._tidy(title), only.group(1), trect.united(nrect), nrect, False))
                pending = None
                continue
            m = LINE.match(line)
            leaders = bool(m) and len(re.sub(r"\s", "", m.group("gap"))) >= 2
            if m and self._number_ok(m.group("num"), leaders) and len(re.findall(r"[^\W\d_]", m.group("title"))) >= 2:
                nstart = start + _units(line[:m.start("num")])
                nrect = self._rect(page, nstart, _units(m.group("num")))
                lrect = self._rect(page, start, _units(line.rstrip()))
                if nrect.isValid() and lrect.isValid():
                    found.append(Entry(self._tidy(m.group("title")), m.group("num"), lrect.united(nrect), nrect, leaders))
                pending = None
                continue
            pending = (line, start) if re.search(r"[^\W\d_]{2}", line) and len(stripped) <= 120 else None
        if not self._is_contents(found):
            found = []
        self._entries[page] = found
        return found

    @staticmethod
    def _tidy(title: str) -> str:
        return re.sub(rf"{LEADER}+$", "", re.sub(r"\s+", " ", title)).strip()

    @staticmethod
    def _number_ok(num: str, leaders: bool = False) -> bool:
        """A page number: digits — or a roman numeral, but only after dot leaders (else "…said I" would count)."""
        if num.isdigit():
            return 0 < int(num) < 10000
        return leaders and roman_value(num) is not None

    @staticmethod
    def _is_contents(found: list[Entry]) -> bool:
        """Several numbered lines, the numbers (mostly) going up — or a couple with dot leaders."""
        nums = [int(e.number) for e in found if e.number.isdigit()]
        if len(found) < 2 or (len(found) < MIN_ENTRIES and not all(e.leaders for e in found)):
            return False
        if len(nums) >= 2:
            rising = sum(1 for a, b in zip(nums, nums[1:]) if b >= a)
            if rising < (len(nums) - 1) * 0.7:
                return False
        return sum(e.leaders for e in found) >= 2 or len(found) >= MIN_ENTRIES + 1 or \
            (len(nums) >= MIN_ENTRIES and len(set(nums)) == len(nums))

    def entry_at(self, page: int, point: QPointF) -> Entry | None:
        """The contents entry under `point` (the page's points) — anywhere along its line."""
        for e in self.entries(page):
            r = e.rect
            pad = max(2.0, r.height() * 0.35)
            if r.adjusted(-4, -pad, 4, pad).contains(point):
                return e
        return None

    # -- printed number → the PDF's page
    def has_labels(self) -> bool:
        """Whether the PDF names its pages itself, differently from just counting them."""
        if self._labels is None:
            n = self.doc.pageCount()
            try:
                self._labels = any((self.doc.pageLabel(i) or str(i + 1)) != str(i + 1)
                                   for i in {0, min(n - 1, 5), min(n - 1, 20), n // 2, n - 1})
            except Exception:  # noqa: BLE001
                self._labels = False
        return self._labels

    def folio(self, page: int) -> int | None:
        """The number printed on `page` — its first or last line, when that's nothing but a number."""
        lines = [x.strip() for x in re.split(r"[\r\n]+", self.text(page)) if x.strip()]
        for line in ([lines[-1], lines[0]] if lines else []):
            if line.isdigit() and 0 < int(line) < 10000:
                return int(line)
        return None

    def offset(self) -> int:
        """Real page number minus printed page number (0 when they're the same, or nothing says)."""
        if self._offset is None:
            n = self.doc.pageCount()
            step = max(1, n // FOLIO_SAMPLES)
            votes: dict[int, int] = {}
            for page in range(0, n, step):
                f = self.folio(page)
                if f is not None:
                    votes[page + 1 - f] = votes.get(page + 1 - f, 0) + 1
            best = max(votes.items(), key=lambda kv: kv[1], default=(0, 0))
            self._offset = best[0] if best[1] >= 2 and best[1] >= sum(votes.values()) * 0.4 else 0
        return self._offset

    def _has_title(self, page: int, key: str) -> bool:
        if not key or self.entries(page):                  # a contents page names every chapter: never the answer
            return False
        return key in _norm(self.text(page)[:700])

    def resolve(self, title: str, number: str) -> int | None:
        """The PDF's page (from 0) for a contents entry — None when the number leads nowhere."""
        n = self.doc.pageCount()
        base: int | None = None
        if self.has_labels():
            try:
                i = self.doc.pageIndexForLabel(number)
                if i < 0 and not number.isdigit():
                    i = self.doc.pageIndexForLabel(number.lower())
                base = i if 0 <= i < n else None
            except Exception:  # noqa: BLE001
                base = None
        if base is None:
            if not number.isdigit():
                return None                                    # a roman numeral with no labels to look it up in
            base = int(number) - 1 + self.offset()
        # The entry's own words near the top of a page around there: the whole title, else without a leading
        # "Chapter 3" / "Part II" / "3." (a contents line often has both; the page may show only the name).
        bare = re.sub(r"^\s*(?:(?:chapter|part|book|section)\s+\S+|\d+)[\s.:—–-]*", "", title, flags=re.I)
        window = [p for p in range(base - 3, base + 4) if 0 <= p < n]
        for key in dict.fromkeys((_norm(title)[:40], _norm(bare)[:40])):
            if len(key) < 4:
                continue
            hits = [p for p in window if self._has_title(p, key)]
            if hits:
                return min(hits)                               # the opening, not a later page's running head
        return base if 0 <= base < n else None

    # -- the chapters
    def chapters(self) -> list[Chapter]:
        """The PDF's outline; else the entries of its contents pages, each resolved to a page."""
        if self._chapters is None:
            self._chapters = self._outline() or self._from_pages()
        return self._chapters

    def _outline(self) -> list[Chapter]:
        try:
            from PySide6.QtPdf import QPdfBookmarkModel
            model = QPdfBookmarkModel(self.doc)
            model.setDocument(self.doc)
        except Exception:  # noqa: BLE001
            return []
        out: list[Chapter] = []
        n = self.doc.pageCount()

        def walk(parent: QModelIndex, level: int) -> None:
            for row in range(model.rowCount(parent)):
                idx = model.index(row, 0, parent)
                title = str(model.data(idx, int(QPdfBookmarkModel.Role.Title)) or "").strip()
                page = model.data(idx, int(QPdfBookmarkModel.Role.Page))
                if title and isinstance(page, int) and 0 <= page < n:
                    out.append(Chapter(title, page, level))
                if level < 4 and len(out) < 2000:
                    walk(idx, level + 1)
        walk(QModelIndex(), 0)
        return out

    def contents_pages(self) -> list[int]:
        return [p for p in range(min(SCAN_PAGES, self.doc.pageCount())) if self.entries(p)]

    def _from_pages(self) -> list[Chapter]:
        out: list[Chapter] = []
        seen: set[tuple[str, int]] = set()
        for page in self.contents_pages():
            for e in self.entries(page):
                target = self.resolve(e.title, e.number)
                if target is None or (e.title, target) in seen:
                    continue
                seen.add((e.title, target))
                out.append(Chapter(e.title, target))
        return out if len(out) >= MIN_ENTRIES else []

    def chapter_at(self, page: int) -> int:
        """Which chapter `page` is in: the last one that starts on or before it (−1: before the first)."""
        best = -1
        for i, c in enumerate(self.chapters()):
            if c.page <= page and (best < 0 or c.page >= self.chapters()[best].page):
                best = i
        return best
