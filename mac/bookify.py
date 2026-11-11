#!/usr/bin/env python3
"""
bookify.py — typeset a plain-text or RTF file as a PDF that looks and reads like a printed book.

    python3 bookify.py story.txt
    python3 bookify.py story.txt -o Story.pdf --title "The Long Road" --author "J. Smith"
    python3 bookify.py story.txt --size 5x8 --paper flat --recto
    python3 bookify.py story.txt --size iphone          # pages the shape of an iPhone 17 Pro Max screen
    python3 bookify.py story.txt --picture "map.jpg@front" --picture "storm.jpg@chapter 4,wide,The storm"

Safe Finder runs it too: right-click a .txt / .md / .rtf file ▸ Make Book PDF… (book_window.py), which calls
`make_book` — the same book, with progress and Stop, placed beside the original.

What it does
  * Cream, lightly textured paper (or flat cream, or plain white for printing)
  * EB Garamond (downloaded once and cached), justified and hyphenated
  * Title page, contents page, chapters that open part-way down the page
    with a drop cap, small-caps lead-in and a fleuron
  * Running heads (book title on the left, chapter on the right) and folios
  * A contents page you can click: every entry — its title and its page number — jumps to the chapter,
    and the chapters are the PDF's outline too (the sidebar in Preview, Books and Safe Finder's viewer)
  * Pictures (--picture, or `pictures=` to make_book): a page of its own, across the text or half
    width, with an optional caption — at the front, at the start or end of a chapter, on a page, or
    at the end of the book
  * Mirrored inside/outside margins like a bound book
  * --size iphone: pages the shape of the iPhone 17 Pro Max's screen (1320 × 2868), equal narrow margins and
    10 pt text that reads at about 15 on the phone — one page per screen in Books, Files or Photo Browser
  * Smart quotes, em dashes, ellipses, *italics* / _italics_, scene breaks

Text conventions it understands
  * Optional "Title: ..." and "Author: ..." lines at the top
  * Chapter lines: "Chapter 1", "CHAPTER IV. The Storm", "Part Two", "Prologue",
    "# Heading" (markdown), or a bare roman numeral. A short line right after a
    chapter line is used as the chapter title.
  * "## Heading" makes a section heading inside a chapter
  * "* * *", "***", "#", "~~~" on their own line make a scene break
  * Paragraphs separated by blank lines (hard-wrapped lines are re-joined),
    or one paragraph per line
  * Project Gutenberg headers/footers are stripped automatically
  * RTF files (TextEdit, Word, Pages exports) are read directly; their
    italics and bold carry over
  * "- item" / "1. item" lines become bulleted or numbered lists
  * A lone "# Heading" at the top becomes the book title, and "## Headings"
    become chapters when there are no other chapter headings

Requirements:  pip install reportlab pyphen pillow numpy
               (pyphen, pillow and numpy are optional; they add hyphenation
               and paper texture)
"""

import argparse
import re
import sys
import tempfile
import urllib.request
from pathlib import Path
from types import SimpleNamespace

try:
    from reportlab.lib.colors import HexColor
    from reportlab.lib.enums import TA_CENTER, TA_JUSTIFY
    from reportlab.lib.styles import ParagraphStyle
    from reportlab.lib.units import inch
    from reportlab.pdfbase import pdfmetrics
    from reportlab.pdfbase.pdfmetrics import registerFontFamily, stringWidth
    from reportlab.pdfbase.ttfonts import TTFont
    from reportlab.platypus import (BaseDocTemplate, CondPageBreak, Flowable, Frame,
                                    PageBreak, PageTemplate, Paragraph, Spacer)
    from reportlab.platypus.flowables import ParagraphAndImage
    from reportlab.platypus.tableofcontents import TableOfContents
except ImportError:
    if __name__ == "__main__":
        sys.exit("bookify needs ReportLab:  pip install reportlab pyphen pillow numpy")
    raise                                           # imported (Safe Finder): the caller says what's missing

try:
    import pyphen  # noqa: F401  (ReportLab uses it for hyphenation)
    HAVE_PYPHEN = True
except ImportError:
    HAVE_PYPHEN = False


# ───────────────────────────── settings ──────────────────────────────

PAGE_SIZES = {               # trim size in inches
    "6x9": (6.0, 9.0),
    "5.5x8.5": (5.5, 8.5),
    "5x8": (5.0, 8.0),
    "a5": (5.83, 8.27),
    "letter": (8.5, 11.0),
    "iphone": (4.0, 4.0 * 2868 / 1320),   # the iPhone 17 Pro Max screen's shape; 4 in wide → 10 pt type
}
SCREEN_SIZES = {"iphone"}    # read on a screen, not bound: equal margins, narrower all round

PAPER = "#F5EDD9"            # cream
INK = "#2A2420"              # warm near-black
ACCENT = "#7A2E22"           # oxblood, for drop caps and ornaments
GREY_INK = "#6B6058"         # running heads and folios

FONT_URL = "https://raw.githubusercontent.com/octaviopardo/EBGaramond12/master/fonts/ttf/{}.ttf"
FONT_FILES = {
    "regular": "EBGaramond-Regular",
    "italic": "EBGaramond-Italic",
    "bold": "EBGaramond-SemiBold",
    "bolditalic": "EBGaramond-SemiBoldItalic",
}
CACHE_DIR = Path.home() / ".cache" / "bookify" / "fonts"


# ───────────────────────────── fonts ─────────────────────────────────

def _font_paths_in(folder):
    folder = Path(folder)
    if not folder.is_dir():
        return None
    found = {}
    files = sorted(folder.glob("*.[ot]tf"))
    for key, base in FONT_FILES.items():           # exact EB Garamond names first
        p = folder / f"{base}.ttf"
        if p.exists():
            found[key] = p
    if "regular" not in found:                     # any family: match by suffix
        def pick(*words, exclude=()):
            for f in files:
                n = f.stem.lower()
                if all(w in n for w in words) and not any(x in n for x in exclude):
                    return f
        found = {k: v for k, v in {
            "regular": pick("regular") or pick("roman") or pick("book"),
            "italic": pick("italic", exclude=("bold", "semi", "medium", "light")),
            "bold": pick("semibold", exclude=("italic",)) or pick("bold", exclude=("italic",)),
            "bolditalic": pick("bold", "italic"),
        }.items() if v}
    return found if {"regular", "italic"} <= found.keys() else None


def locate_fonts(user_dir=None, note=None):
    """Find book fonts: --fonts dir, ./fonts beside the script, the cache, or download. `note` hears what's
    happening (the download)."""
    for d in ([user_dir] if user_dir else []) + [Path(__file__).resolve().parent / "fonts", CACHE_DIR]:
        found = _font_paths_in(d)
        if found:
            return found
    if user_dir:
        print(f"  ! no usable Regular/Italic fonts in {user_dir}", file=sys.stderr)
    try:
        CACHE_DIR.mkdir(parents=True, exist_ok=True)
        print("  downloading EB Garamond (first run only)…", file=sys.stderr)
        if note:
            note("Downloading the EB Garamond fonts (the first time only)…")
        for base in FONT_FILES.values():
            dest = CACHE_DIR / f"{base}.ttf"
            if not dest.exists():
                try:
                    urllib.request.urlretrieve(FONT_URL.format(base), dest)
                except Exception:
                    if dest.exists():
                        dest.unlink()
        return _font_paths_in(CACHE_DIR)
    except Exception as e:
        print(f"  ! couldn't download fonts ({e}); falling back to Times", file=sys.stderr)
        return None


def register_fonts(paths):
    """Returns a namespace of font names plus cap-height/ascent ratios."""
    if paths:
        names = {"regular": "Book", "italic": "Book-Italic", "bold": "Book-Bold", "bolditalic": "Book-BoldItalic"}
        for key, name in names.items():
            src = paths.get(key) or paths.get("italic" if "italic" in key else "regular")
            pdfmetrics.registerFont(TTFont(name, str(src)))
        registerFontFamily("Book", normal="Book", bold="Book-Bold",
                           italic="Book-Italic", boldItalic="Book-BoldItalic")
        f = SimpleNamespace(**names)
    else:
        f = SimpleNamespace(regular="Times-Roman", italic="Times-Italic",
                            bold="Times-Bold", bolditalic="Times-BoldItalic")
    face = pdfmetrics.getFont(f.regular).face
    f.cap = (getattr(face, "capHeight", 0) or 660) / 1000.0
    f.ascent = (getattr(face, "ascent", 0) or 800) / 1000.0
    f.has = (lambda ch: ord(ch) in pdfmetrics.getFont(f.regular).face.charToGlyph) if paths else (lambda ch: False)
    return f


# ───────────────────────────── text → structure ──────────────────────

NUMBER_WORDS = ("zero one two three four five six seven eight nine ten eleven twelve thirteen "
                "fourteen fifteen sixteen seventeen eighteen nineteen").split()
TENS_WORDS = "twenty thirty forty fifty sixty seventy eighty ninety".split()
NUMWORD_RE = r"(?:(?:%s)(?:[- ](?:%s))?|%s)" % ("|".join(TENS_WORDS), "|".join(NUMBER_WORDS[1:10]),
                                                "|".join(NUMBER_WORDS[1:]))
ROMAN_RE = r"(?=[MDCLXVI])M{0,4}(?:CM|CD|D?C{0,3})(?:XC|XL|L?X{0,3})(?:IX|IV|V?I{0,3})"

CHAPTER_RE = re.compile(
    rf"^(chapter|book|part|volume)\s+(\d{{1,3}}|{ROMAN_RE}|{NUMWORD_RE})\b\.?\s*(?:[:.\-—–]+\s*)?(.*)$", re.I)
SPECIAL_RE = re.compile(
    r"^(prologue|epilogue|preface|foreword|introduction|afterword|interlude|coda|"
    r"acknowledge?ments|author'?s note|appendix(?:\s+\w+)?)\s*(?:[:.\-—–]+\s*(.*))?$", re.I)
BARE_NUM_RE = re.compile(rf"^({ROMAN_RE}|\d{{1,3}})\.?$")
MD_H1_RE = re.compile(r"^#\s+(.+?)\s*#*$")
MD_H2_RE = re.compile(r"^#{2,6}\s+(.+?)\s*#*$")
LIST_RE = re.compile(r"^\s*([-*+•–]|\d{1,3}[.)])\s+(\S.*)$")
SCENE_RE = re.compile(r"^\s*(?:[*#~=•·◆❦❧]\s*){1,5}$|^\s*-{3,}\s*$|^\s*_{3,}\s*$")
GUT_START = re.compile(r"\*{3}\s*START OF (?:THE|THIS) PROJECT GUTENBERG[^\n]*", re.I)
GUT_END = re.compile(r"\*{3}\s*END OF (?:THE|THIS) PROJECT GUTENBERG", re.I)
SMALL_WORDS = set("a an and as at but by en for if in of on or the to v via vs with from into nor".split())


def number_to_words(n):
    if n < 20:
        return NUMBER_WORDS[n]
    if n < 100:
        t, o = divmod(n, 10)
        return TENS_WORDS[t - 2] + ("-" + NUMBER_WORDS[o] if o else "")
    return str(n)


def title_case(s):
    words = s.lower().split()
    out = []
    for i, w in enumerate(words):
        if 0 < i < len(words) - 1 and w in SMALL_WORDS:
            out.append(w)
        else:
            out.append(re.sub(r"^([^\w]*)(\w)", lambda m: m.group(1) + m.group(2).upper(), w))
    return " ".join(out)


def tidy_title(s):
    s = s.strip().strip(".:-—– ")
    s = re.sub(r"^[*_]+|[*_]+$", "", s)
    letters = [c for c in s if c.isalpha()]
    if letters and all(c.isupper() for c in letters) and len(letters) > 3:
        s = title_case(s)
    return s


# ── RTF (TextEdit, Word, Pages exports) → text with *italic* / **bold** markers ──

RTF_TOKEN = re.compile(rb"\\([a-zA-Z]+)(-?\d+)? ?|\\'([0-9a-fA-F]{2})|\\([^a-zA-Z])|([{}])|[\r\n]+|([^\\{}\r\n]+)")
RTF_SKIP = {b"fonttbl", b"colortbl", b"stylesheet", b"info", b"pict", b"header", b"footer", b"headerl",
            b"headerr", b"headerf", b"footerl", b"footerr", b"footerf", b"listtable", b"listoverridetable",
            b"themedata", b"colorschememapping", b"latentstyles", b"datastore", b"xmlnstbl", b"rsidtbl",
            b"generator", b"fldinst", b"object", b"nonshppict", b"revtbl", b"filetbl", b"footnote",
            b"expandedcolortbl", b"pgdsctbl", b"bkmkstart", b"bkmkend"}
RTF_CHARS = {b"emdash": "—", b"endash": "–", b"lquote": "‘", b"rquote": "’", b"ldblquote": "“",
             b"rdblquote": "”", b"bullet": "•", b"tab": " ", b"emspace": " ", b"enspace": " ",
             b"qmspace": " "}
RTF_SYMBOLS = {b"\\": "\\", b"{": "{", b"}": "}", b"~": "\u00a0", b"_": "-", b"-": "", b"\n": "\n\n", b"\r": "\n\n"}


def rtf_to_text(raw):
    """A small RTF reader: keeps paragraphs, special characters, italics and bold."""
    codepage = "cp1252"
    m = re.search(rb"\\ansicpg(\d+)", raw[:400])
    if m:
        codepage = f"cp{int(m.group(1))}"
    runs = []                                       # (text, italic, bold)
    st = {"skip": False, "i": False, "b": False, "uc": 1}
    stack, pending_skip = [], 0

    def emit(s):
        if not st["skip"] and s:
            runs.append((s, st["i"], st["b"]))

    for tok in RTF_TOKEN.finditer(raw):
        word, num, hexch, sym, brace, text = tok.groups()
        if brace == b"{":
            stack.append(dict(st))
            continue
        if brace == b"}":
            if stack:
                st = stack.pop()
            pending_skip = 0
            continue
        if text is not None or hexch is not None:
            if hexch is not None:
                if pending_skip:
                    pending_skip -= 1
                    continue
                try:
                    emit(bytes([int(hexch, 16)]).decode(codepage))
                except (UnicodeDecodeError, LookupError):
                    emit(bytes([int(hexch, 16)]).decode("cp1252", "replace"))
            else:
                if pending_skip:
                    drop = min(pending_skip, len(text))
                    text, pending_skip = text[drop:], pending_skip - drop
                emit(text.decode(codepage, "replace"))
            continue
        if sym is not None:
            if sym == b"*":
                st["skip"] = True                     # {\* ...} destinations are never body text
            else:
                emit(RTF_SYMBOLS.get(sym, ""))
            continue
        if word is None:
            continue                                  # bare newline in the RTF source
        n = int(num) if num else None
        if word in RTF_SKIP:
            st["skip"] = True
        elif word in (b"par", b"sect", b"page"):
            emit("\n\n")
        elif word in (b"line", b"softline"):
            emit("\n")
        elif word in RTF_CHARS:
            emit(RTF_CHARS[word])
        elif word == b"u" and n is not None:
            emit(chr(n + 65536 if n < 0 else n))
            pending_skip = st["uc"]
        elif word == b"uc" and n is not None:
            st["uc"] = n
        elif word == b"i":
            st["i"] = n != 0
        elif word == b"b":
            st["b"] = n != 0
        elif word == b"plain":
            st["i"] = st["b"] = False

    # merge runs and turn styled runs into *markers*, never across line breaks
    merged = []
    for s, i, b in runs:
        if merged and merged[-1][1:] == (i, b):
            merged[-1] = (merged[-1][0] + s, i, b)
        else:
            merged.append((s, i, b))
    out = []
    for s, i, b in merged:
        mark = ("**" if b else "") + ("*" if i else "")
        if not mark:
            out.append(s)
            continue
        for seg in re.split(r"(\n+)", s):
            core = seg.strip()
            if not core or seg.startswith("\n"):
                out.append(seg)
            else:
                lead, trail = seg[:len(seg) - len(seg.lstrip())], seg[len(seg.rstrip()):]
                out.append(f"{lead}{mark}{core}{mark[::-1]}{trail}")
    text = "".join(out).replace("\u00a0", " ").replace("\uf0b7", "•").replace("\uf0a7", "•")
    text = re.sub(r"[ \t]+\n", "\n", text)
    return re.sub(r"\n{3,}", "\n\n", text).strip() + "\n"


def load_text(path):
    raw = Path(path).read_bytes()
    if raw.lstrip()[:5] == b"{\\rtf":
        text = rtf_to_text(raw)
    else:
        for enc in ("utf-8-sig", "cp1252", "latin-1"):
            try:
                text = raw.decode(enc)
                break
            except UnicodeDecodeError:
                continue
    text = text.replace("\r\n", "\n").replace("\r", "\n").replace("\t", "    ")
    meta = {}
    m = GUT_START.search(text)
    if m:   # Project Gutenberg: grab metadata from the header, then strip it
        header = text[:m.start()]
        for key in ("Title", "Author"):
            mm = re.search(rf"^{key}:\s*(.+)$", header, re.M)
            if mm:
                meta[key.lower()] = mm.group(1).strip()
        text = text[m.end():]
        e = GUT_END.search(text)
        if e:
            text = text[:e.start()]
    # "Title:" / "Author:" lines at the very top of the file
    lines = text.lstrip("\n").split("\n")
    while lines and re.match(r"^(title|author|by):\s*", lines[0], re.I):
        k, v = lines.pop(0).split(":", 1)
        meta["author" if k.lower() in ("author", "by") else "title"] = v.strip()
    return "\n".join(lines), meta


def is_heading_line(s):
    s = s.strip()
    return bool(len(s) <= 90 and (MD_H1_RE.match(s) or CHAPTER_RE.match(s) or SPECIAL_RE.match(s)
                                  or BARE_NUM_RE.match(s)))


def join_lines(lines):
    out = lines[0].strip()
    for line in lines[1:]:
        line = line.strip()
        out += line if out.endswith(("—", "--")) else " " + line
    return out


def text_units(text):
    """Yield (paragraph_text, was_single_line) from raw text."""
    for block in re.split(r"\n\s*\n", text):
        lines = [l.rstrip() for l in block.split("\n") if l.strip()]
        while lines and len(lines) > 1 and (is_heading_line(lines[0]) or SCENE_RE.match(lines[0])):
            yield lines.pop(0).strip(), True
        if not lines:
            continue
        if len(lines) == 1:
            yield lines[0].strip(), True
            continue
        if LIST_RE.match(lines[0]) and not SCENE_RE.match(lines[0]):    # bulleted / numbered list
            items = []
            for l in lines:
                if LIST_RE.match(l) or not items:
                    items.append([l])
                else:
                    items[-1].append(l)
            for it in items:
                yield join_lines(it), True
            continue
        body = lines[:-1]
        if max(len(l) for l in body) > 100:                       # one paragraph per line
            for l in lines:
                yield l.strip(), True
            continue
        indented = [i for i, l in enumerate(lines) if i and re.match(r"^\s{2,}\S", l)]
        if indented and not re.match(r"^\s{2,}\S", lines[1] if len(lines) > 1 else ""):
            starts = [0] + indented                                # indented paragraph starts
            for a, b in zip(starts, starts[1:] + [len(lines)]):
                yield join_lines(lines[a:b]), False
            continue
        if all(len(l.strip()) < 45 for l in lines) and len(lines) <= 12:   # verse / address / list
            yield "<br/>".join(l.strip() for l in lines), False
            continue
        yield join_lines(lines), False


def parse_heading(s):
    """Return (label, title) for a chapter-level heading line, else None."""
    s = s.strip()
    if len(s) > 90:
        return None
    m = MD_H1_RE.match(s)
    if m:
        return None, tidy_title(m.group(1))
    m = CHAPTER_RE.match(s)
    if m:
        kind, num, rest = m.group(1).title(), m.group(2), m.group(3)
        if rest and (len(rest.split()) > 12 or rest.rstrip().endswith(("?", "!", ","))):
            return None
        if num.isdigit():
            num = title_case(number_to_words(int(num)))
        elif re.fullmatch(ROMAN_RE, num.upper()) and num.lower() not in NUMBER_WORDS:
            num = num.upper()
        else:
            num = title_case(num)
        return f"{kind} {num}", tidy_title(rest) if rest else None
    m = SPECIAL_RE.match(s)
    if m:
        return None, tidy_title(m.group(1) + (": " + m.group(2) if m.group(2) else ""))
    m = BARE_NUM_RE.match(s)
    if m:
        n = m.group(1)
        return (title_case(number_to_words(int(n))) if n.isdigit() else n.upper()), None
    return None


def looks_like_title(s):
    s = s.strip()
    return (0 < len(s) <= 70 and len(s.split()) <= 10 and not s.endswith((".", ",", ";", "?", "!", '"', "”", "'", "’"))
            and not s.startswith(('"', "“", "'", "‘", "—", "-")))


def build_elements(text):
    """Turn text into a list of elements: chapter / section / break / para."""
    els = []
    for t, single in text_units(text):
        if single:
            plain = re.sub(r"^(\*{1,2}|_)(.+)\1$", r"\2", t.strip())     # "**Chapter 1**" counts too
            h = parse_heading(plain)
            if h:
                els.append({"kind": "chapter", "label": h[0], "title": h[1], "md": bool(MD_H1_RE.match(plain))})
                continue
            if SCENE_RE.match(t):
                els.append({"kind": "break"})
                continue
            m = LIST_RE.match(t)
            if m:
                marker = m.group(1)
                els.append({"kind": "item", "text": m.group(2),
                            "bullet": marker if marker[0].isdigit() else "•"})
                continue
            m = MD_H2_RE.match(plain)
            if m:
                els.append({"kind": "section", "title": tidy_title(m.group(1))})
                continue
            if els and els[-1]["kind"] == "chapter" and not els[-1]["title"] and looks_like_title(t):
                els[-1]["title"] = tidy_title(t)
                continue
        els.append({"kind": "para", "text": t})
    return els


# ───────────────────────────── typography ────────────────────────────

def smarten(s):
    s = s.replace("---", "—").replace("--", "—")
    s = re.sub(r"\s*—\s*", "—", s)                       # closed-up em dashes
    s = re.sub(r"\s+-\s+", " – ", s)              # spaced hyphen → en dash
    s = re.sub(r"\.\s?\.\s?\.", "…", s)
    s = re.sub(r'(^|[\s(\[{>])"', r"\1“", s)
    s = re.sub(r'([—–])"(?=[\w‘\'])', r"\1“", s)
    s = s.replace('"', "”")
    s = re.sub(r"(^|[\s(\[{“>])'(?=[\w“])", r"\1‘", s)
    s = re.sub(r"([—–])'(?=\w)", r"\1‘", s)
    s = s.replace("'", "’")
    s = re.sub(r"‘(?=(?:\d0s|tis|twas|em|cause|til|n)\b)", "’", s, flags=re.I)
    return s


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def inline_markup(s):
    """Raw (already smartened) text → ReportLab paragraph markup."""
    br = "\x00"
    s = esc(s.replace("<br/>", br)).replace(br, "<br/>")
    s = re.sub(r"(?<![\w*])\*\*(?!\s)(.+?)(?<!\s)\*\*(?![\w*])", r"<b>\1</b>", s)
    s = re.sub(r"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])", r"<i>\1</i>", s)
    s = re.sub(r"(?<!\w)_(?!\s)(.+?)(?<!\s)_(?!\w)", r"<i>\1</i>", s)
    return s


def small_caps(raw, size):
    raw = re.sub(r"[*_]", "", raw)
    out = []
    for run in re.findall(r"[a-zß]+|[^a-zß]+", raw):
        out.append(f'<font size="{size * 0.78:.2f}">{esc(run.upper())}</font>' if run.islower() else esc(run))
    return "".join(out)


def split_leadin(raw, min_chars=14, max_words=4):
    """Split text after its first few words for a small-caps lead-in."""
    m = re.match(r"^(\S*(?:\s+\S+){0,%d})" % (max_words - 1), raw)
    words = re.findall(r"\S+\s*", raw)
    lead = ""
    for w in words:
        lead += w
        if len(lead.strip()) >= min_chars or len(lead.split()) >= max_words:
            break
    lead = lead.rstrip()
    return lead, raw[len(lead):] if m else ""


# ───────────────────────────── flowables ─────────────────────────────

class Mark(Flowable):
    """Invisible marker: records page roles for running heads / folios / TOC."""
    def __init__(self, kind, value=None):
        super().__init__()
        self.kind, self.value = kind, value
        self.width = self.height = 0

    def wrap(self, *_):
        return 0, 0

    def draw(self):
        doc = self.canv._doctemplate
        page = self.canv.getPageNumber()
        if self.kind == "blank":
            doc.state.blank.add(page)
        elif self.kind == "chapter":
            doc.state.openers.add(page)
            doc.state.chapter = self.value[0]
            key = self.value[2] if len(self.value) > 2 else None
            if key:                                  # somewhere for the contents page and the outline to point
                # The top of the page, zoom left as it is (a bare "Fit" has no place on the page, and some
                # viewers — Qt's among them — then complain the link has nowhere exact to go).
                self.canv.bookmarkPage(key, fit="XYZ", left=0, top=doc.cfg.page[1], zoom=0)
                title = self.value[1] or self.value[0]
                if title and self.value[1]:
                    self.canv.addOutlineEntry(re.sub(r"<[^>]+>", "", title), key, 0, 0)
                doc.state.chapters.append((re.sub(r"<[^>]+>", "", title or ""), page))


class NewPage(Flowable):
    """Start a fresh page; with recto=True, a fresh right-hand (odd) page."""
    def __init__(self, recto=False):
        super().__init__()
        self.recto = recto

    def wrap(self, *_):
        return 0, 0

    def draw(self):
        pass


class TrackedLine(Flowable):
    """A centered, letter-spaced line (small-cap style labels)."""
    def __init__(self, text, font, size, color, tracking=0.16, pad_after=0):
        super().__init__()
        self.text, self.font, self.size, self.color = text, font, size, HexColor(color)
        self.tracking, self.pad_after = tracking, pad_after

    def wrap(self, aw, ah):
        self.aw = aw
        return aw, self.size * 1.25 + self.pad_after

    def draw(self):
        cs = self.size * self.tracking
        w = stringWidth(self.text, self.font, self.size) + cs * (len(self.text) - 1)
        t = self.canv.beginText((self.aw - w) / 2, self.pad_after + self.size * 0.3)
        t.setFont(self.font, self.size)
        t.setCharSpace(cs)
        t.setFillColor(self.color)
        t.textOut(self.text)
        self.canv.drawText(t)


class Ornament(Flowable):
    """A centered fleuron flanked by hairlines, or a three-point scene break."""
    def __init__(self, fonts, size, color, style="fleuron", space=0):
        super().__init__()
        self.fonts, self.size, self.color, self.style, self.space = fonts, size, HexColor(color), style, space

    def wrap(self, aw, ah):
        self.aw = aw
        return aw, self.size * 1.4 + 2 * self.space

    def draw(self):
        c, cx, cy = self.canv, self.aw / 2, self.space + self.size * 0.55
        c.setFillColor(self.color)
        c.setStrokeColor(self.color)
        if self.style == "fleuron":
            glyph = "❦" if self.fonts.has("❦") else "◆" if self.fonts.has("◆") else "*"
            c.setFont(self.fonts.regular, self.size)
            c.drawCentredString(cx, cy - self.size * 0.33, glyph)
            c.setLineWidth(0.4)
            gap, ln = self.size * 0.95, self.size * 2.2
            c.line(cx - gap - ln, cy, cx - gap, cy)
            c.line(cx + gap, cy, cx + gap + ln, cy)
        else:   # scene break: three small diamonds
            s, step = self.size * 0.16, self.size * 1.1
            for dx in (-step, 0, step):
                p = c.beginPath()
                p.moveTo(cx + dx, cy + s)
                p.lineTo(cx + dx + s * 0.75, cy)
                p.lineTo(cx + dx, cy - s)
                p.lineTo(cx + dx - s * 0.75, cy)
                p.close()
                c.drawPath(p, stroke=0, fill=1)


class DropCap(Flowable):
    def __init__(self, text, font, size, color, height):
        super().__init__()
        self.text, self.font, self.size, self.color = text, font, size, HexColor(color)
        self.width = stringWidth(text, font, size)
        self.height = height

    def wrap(self, *_):
        return self.width, self.height

    def draw(self):
        self.canv.setFont(self.font, self.size)
        self.canv.setFillColor(self.color)
        self.canv.drawString(0, 0, self.text)   # baseline sits on the 3rd text line


# ───────────────────────────── paper ─────────────────────────────────

class BookPara(Paragraph):
    """A paragraph that remembers which element of the text it is — through page breaks too — so the book
    can say which page each paragraph landed on (pictures are placed "on page N" by it)."""
    _book_el = None

    def split(self, aw, ah):
        parts = super().split(aw, ah)
        for part in parts:
            part._book_el = self._book_el
        return parts


class Picture(Flowable):
    """A picture in the book, kept in proportion, with an optional caption under it.
    `full`: a page of its own (as large as the page's text area allows, centred); else `frac` of the text
    width, no taller than `max_h`."""
    def __init__(self, path, iw, ih, caption, style, full=False, frac=1.0, max_h=None, pad=0):
        super().__init__()
        self.path, self.iw, self.ih = path, max(iw, 1), max(ih, 1)
        self.cap = Paragraph(caption, style) if caption else None
        self.full, self.frac, self.max_h, self.pad = full, frac, max_h, pad

    def wrap(self, aw, ah):
        self.aw = aw
        cap_h = self.cap.wrap(aw, ah)[1] + self.pad * 0.5 if self.cap else 0
        room = (ah if self.full else min(self.max_h or ah, ah)) - cap_h - (0 if self.full else 2 * self.pad)
        w = aw * (1.0 if self.full else self.frac)
        h = w * self.ih / self.iw
        if h > room > 0:
            h = room
            w = h * self.iw / self.ih
        self.w, self.h, self.cap_h = w, h, cap_h
        self.height = ah if self.full else h + cap_h + 2 * self.pad
        self.width = aw
        return aw, self.height

    def draw(self):
        c = self.canv
        block = self.h + self.cap_h
        top = self.height - (self.height - block) / 2 if self.full else self.height - self.pad
        x = (self.aw - self.w) / 2
        c.drawImage(self.path, x, top - self.h, self.w, self.h, preserveAspectRatio=True, mask="auto")
        if self.cap:
            self.cap.drawOn(c, 0, top - self.h - self.cap_h)


PICTURE_PLACES = ("front", "chapter_start", "chapter_end", "after", "page", "end")
PICTURE_SIZES = ("page", "wide", "half")


def prepare_picture(path, workdir, n, max_pt):
    """The picture as ReportLab should embed it: upright, RGB, no larger than the page needs (220 dpi at
    `max_pt` points on its long side), a JPEG in `workdir`. Without Pillow it's used as it is (JPEGs only).
    Returns (file, width, height) in pixels. Raises ValueError when it can't be read."""
    try:
        from PIL import Image, ImageOps
    except ImportError:
        from reportlab.lib.utils import ImageReader
        try:
            w, h = ImageReader(str(path)).getSize()
        except Exception as e:                         # noqa: BLE001 — whatever ReportLab can't read
            raise ValueError(f"{Path(path).name} can't be read as a picture ({e})")
        return str(path), w, h
    try:
        try:
            import pillow_heif                         # iPhone photos, when the Mac has it
            pillow_heif.register_heif_opener()
        except ImportError:
            pass
        with Image.open(path) as im:
            im = ImageOps.exif_transpose(im)
            if im.mode in ("RGBA", "LA", "PA") or (im.mode == "P" and "transparency" in im.info):
                rgba = im.convert("RGBA")
                flat = Image.new("RGB", rgba.size, (255, 255, 255))
                flat.paste(rgba, mask=rgba.getchannel("A"))
                im = flat
            elif im.mode != "RGB":
                im = im.convert("RGB")
            limit = int(max_pt / 72 * 220)
            if max(im.size) > limit:
                im.thumbnail((limit, limit), Image.Resampling.LANCZOS)
            out = Path(workdir) / f"picture-{n}.jpg"
            im.save(out, "JPEG", quality=90)
            return str(out), im.width, im.height
    except (OSError, ValueError) as e:
        raise ValueError(f"{Path(path).name} can't be read as a picture ({e})")


def make_paper(page_w, page_h, workdir, gutter_shadow=True):
    """Two textured paper images (recto/verso, with a soft gutter shadow on the spine side — none for a screen,
    which has no spine)."""
    try:
        import numpy as np
        from PIL import Image
    except ImportError:
        return None
    dpi = 110
    w, h = int(page_w / 72 * dpi), int(page_h / 72 * dpi)
    rng = np.random.default_rng(1729)
    base = np.array(HexColor(PAPER).rgb()) * 255
    grain = rng.normal(0, 1.6, (h, w))
    low = Image.fromarray(rng.normal(128, 40, (h // 45 + 2, w // 45 + 2)).clip(0, 255).astype("uint8"))
    mottle = (np.asarray(low.resize((w, h), Image.BICUBIC), float) - 128) / 40 * 1.6
    yy, xx = np.mgrid[0:h, 0:w]
    r = np.hypot((xx - w / 2) / (w / 2), (yy - h / 2) / (h / 2))
    vignette = 1 - 0.035 * r ** 2.2
    paths = {}
    for side in ("recto", "verso"):
        dist = xx / w if side == "recto" else (w - 1 - xx) / w      # spine is left on a recto
        gutter = 1 - 0.07 * np.exp(-dist / 0.035) - 0.02 * np.exp(-dist / 0.15) if gutter_shadow else 1.0
        img = base[None, None, :] * (vignette * gutter)[..., None] + (grain + mottle)[..., None]
        p = Path(workdir) / f"paper_{side}.jpg"
        Image.fromarray(img.clip(0, 255).astype("uint8")).save(p, quality=82, optimize=True)
        paths[side] = str(p)
    return paths


# ───────────────────────────── document ──────────────────────────────

class BookDoc(BaseDocTemplate):
    def __init__(self, filename, cfg):
        self.cfg = cfg
        W, H = cfg.page
        super().__init__(filename, pagesize=cfg.page, title=cfg.title, author=cfg.author or "",
                         creator="bookify.py", leftMargin=cfg.inner, rightMargin=cfg.outer,
                         topMargin=cfg.top, bottomMargin=cfg.bottom)
        fw, fh = W - cfg.inner - cfg.outer, H - cfg.top - cfg.bottom
        pad = dict(leftPadding=0, rightPadding=0, topPadding=0, bottomPadding=0)
        recto = Frame(cfg.inner, cfg.bottom, fw, fh, id="recto", **pad)
        verso = Frame(cfg.outer, cfg.bottom, fw, fh, id="verso", **pad)
        self.addPageTemplates([
            PageTemplate("recto", [recto], onPage=self.draw_paper, onPageEnd=self.draw_furniture,
                         autoNextPageTemplate="verso"),
            PageTemplate("verso", [verso], onPage=self.draw_paper, onPageEnd=self.draw_furniture,
                         autoNextPageTemplate="recto"),
        ])
        self.frame_h = fh

    def beforeDocument(self):
        self.state = SimpleNamespace(blank=set(), openers=set(), chapter=None, chapters=[], el_pages={})

    def afterFlowable(self, f):
        if isinstance(f, Mark) and f.kind == "chapter" and f.value[1]:
            key = f.value[2] if len(f.value) > 2 else None
            self.notify("TOCEntry", (0, f.value[1], self.page, key))     # with a key the entry is a link
        el = getattr(f, "_book_el", None)
        if el is None:
            el = getattr(getattr(f, "P", None), "_book_el", None)        # a drop-cap opening wraps its paragraph
        if el is not None:                                               # which pages each paragraph is on
            first, last = self.state.el_pages.get(el, (self.page, self.page))
            self.state.el_pages[el] = (min(first, self.page), max(last, self.page))

    def handle_flowable(self, flowables):
        f = flowables[0]
        if isinstance(f, NewPage):
            flowables.pop(0)
            empty = self._curPageFlowableCount == 0
            landing = self.canv.getPageNumber() + (0 if empty else 1)
            insert = [] if empty else [PageBreak()]
            if f.recto and landing % 2 == 0:
                insert += [Mark("blank"), PageBreak()]
            flowables[0:0] = insert
            return
        super().handle_flowable(flowables)

    # page furniture
    def draw_paper(self, canv, doc):
        cfg, page = self.cfg, canv.getPageNumber()
        if cfg.paper_images:
            canv.drawImage(cfg.paper_images["recto" if page % 2 else "verso"], 0, 0, *cfg.page)
        elif cfg.paper != "white":
            canv.setFillColor(HexColor(PAPER))
            canv.rect(0, 0, *cfg.page, stroke=0, fill=1)

    def draw_furniture(self, canv, doc):
        cfg, st, page = self.cfg, self.state, canv.getPageNumber()
        if page in st.blank:
            return
        W, H = cfg.page
        recto = page % 2 == 1
        left = cfg.inner if recto else cfg.outer
        mid = left + (W - cfg.inner - cfg.outer) / 2
        size = cfg.font_size * 0.74
        canv.setFillColor(HexColor(GREY_INK))
        if page not in st.openers:
            text = (st.chapter or cfg.title) if recto else cfg.title
            text = text.upper()
            cs = size * 0.18
            maxw = (W - cfg.inner - cfg.outer) * 0.9
            while len(text) > 4 and stringWidth(text, cfg.fonts.regular, size) + cs * len(text) > maxw:
                text = text[:-2].rstrip() + "…"
            w = stringWidth(text, cfg.fonts.regular, size) + cs * (len(text) - 1)
            t = canv.beginText(mid - w / 2, H - cfg.top + cfg.font_size * 1.9)
            t.setFont(cfg.fonts.regular, size)
            t.setCharSpace(cs)
            t.textOut(text)
            canv.drawText(t)
        canv.setFont(cfg.fonts.regular, cfg.font_size * 0.86)
        canv.drawCentredString(mid, cfg.bottom - cfg.font_size * 2.6, str(page))


# ───────────────────────────── story ─────────────────────────────────

def make_styles(cfg):
    fs, lead, f = cfg.font_size, cfg.leading, cfg.fonts
    hyph = {"hyphenationLang": cfg.lang} if HAVE_PYPHEN and cfg.lang else {}
    body = ParagraphStyle("body", fontName=f.regular, fontSize=fs, leading=lead, alignment=TA_JUSTIFY,
                          firstLineIndent=fs * 1.4, textColor=HexColor(INK),
                          allowWidows=0, allowOrphans=0, **hyph)
    body.hyphenationMinWordLength = 7          # don't break short words like "is-land"
    return SimpleNamespace(
        body=body,
        first=ParagraphStyle("first", parent=body, firstLineIndent=0),
        title=ParagraphStyle("title", fontName=f.regular, fontSize=fs * 2.5, leading=fs * 2.9,
                             alignment=TA_CENTER, textColor=HexColor(INK)),
        chapter_title=ParagraphStyle("ctitle", fontName=f.italic, fontSize=fs * 1.75, leading=fs * 2.15,
                                     alignment=TA_CENTER, textColor=HexColor(INK)),
        toc=ParagraphStyle("toc", fontName=f.regular, fontSize=fs, leading=fs * 1.9,
                           textColor=HexColor(INK), leftIndent=0, firstLineIndent=0),
        caption=ParagraphStyle("caption", fontName=f.italic, fontSize=fs * 0.88, leading=fs * 1.2,
                               alignment=TA_CENTER, textColor=HexColor(GREY_INK)),
        item=ParagraphStyle("item", parent=body, alignment=0, firstLineIndent=0, leftIndent=fs * 1.8,
                            bulletIndent=fs * 0.5, bulletFontName=f.regular, bulletFontSize=fs,
                            spaceBefore=lead * 0.15),
    )


def balanced(text, style, width):
    """Break a display title into evenly sized lines instead of leaving one word alone."""
    words = text.split()
    sw = lambda t: stringWidth(t, style.fontName, style.fontSize)
    if "*" in text or "_" in text or sw(text) <= width or len(words) < 3:
        return inline_markup(text)
    n = int(sw(text) // (width * 0.98)) + 1                # lines needed
    target, lines, cur = sw(text) / n, [], []
    for w in words:
        if cur and sw(" ".join(cur + [w])) > target * 1.08 and len(lines) < n - 1:
            lines.append(" ".join(cur)); cur = []
        cur.append(w)
    lines.append(" ".join(cur))
    if any(sw(l) > width for l in lines):
        return inline_markup(text)
    return "<br/>".join(esc(l) for l in lines)


def opening_paragraph(raw, cfg, st):
    """First paragraph of a chapter: drop cap + small-caps lead-in."""
    raw = smarten(raw)
    fs, lead, f = cfg.font_size, cfg.leading, cfg.fonts
    m = re.match(r"^([“‘(]*)([^\W_])", re.sub(r"^[*_]+", "", raw))
    if not cfg.dropcaps or not m or raw.startswith("<br/>") or len(raw) < 80:
        lead_in, rest = split_leadin(raw)
        return BookPara(small_caps(lead_in, fs) + inline_markup(rest), st.first)
    raw = re.sub(r"^[*_]+", "", raw)
    cap, rest = m.group(1) + m.group(2), raw[m.end():]
    lead_in, rest = split_leadin(rest, min_chars=12)
    para = BookPara(small_caps(lead_in, fs) + inline_markup(rest), st.first)
    lines = 3
    cap_size = ((lines - 1) * lead + f.cap * fs) / f.cap        # cap spans exactly 3 lines
    drop = DropCap(cap, f.regular, cap_size, cfg.accent, height=(lines - 1) * lead + f.ascent * fs)
    return ParagraphAndImage(para, drop, xpad=fs * 0.35, ypad=0, side="left")


def picture_flowables(doc, cfg, st, pic, inline_only=False):
    """What goes in the story for one prepared picture. A page of its own: a fresh page with nothing else on it
    (no running head or folio); else the picture across the text (or half its width), kept clear of the lines
    around it."""
    cap = inline_markup(smarten(pic["caption"])) if pic.get("caption") else None
    lead = cfg.leading
    if pic["size"] == "page" and not inline_only:
        return [NewPage(), Mark("blank"),
                Picture(pic["file"], pic["w"], pic["h"], cap, st.caption, full=True, pad=lead), NewPage()]
    frac = 0.5 if pic["size"] == "half" else 1.0
    return [CondPageBreak(lead * 6),
            Picture(pic["file"], pic["w"], pic["h"], cap, st.caption, frac=frac, max_h=doc.frame_h * 0.62, pad=lead)]


def build_story(doc, cfg, elements, pictures=()):
    st, fs, lead = make_styles(cfg), cfg.font_size, cfg.leading
    f = cfg.fonts
    story = []
    at = {"front": [], "end": [], "chapter_start": {}, "chapter_end": {}, "after": {}}
    for pic in pictures:
        if pic["where"] in ("front", "end"):
            at[pic["where"]].append(pic)
        else:
            at[pic["where"]].setdefault(pic["index"], []).append(pic)

    # title page
    story += [Mark("blank"), Spacer(1, doc.frame_h * 0.24),
              Paragraph(balanced(smarten(cfg.title), st.title, doc.width), st.title), Spacer(1, fs * 1.4),
              Ornament(f, fs * 1.3, cfg.accent)]
    if cfg.author:
        story += [Spacer(1, fs * 1.6), TrackedLine(smarten(cfg.author).upper(), f.regular, fs * 1.0, INK, 0.2)]
    for pic in at["front"]:                                  # a frontispiece: after the title page
        story += picture_flowables(doc, cfg, st, dict(pic, size="page"))

    chapters = [e for e in elements if e["kind"] == "chapter"]
    if cfg.toc and len(chapters) >= 2:
        toc = TableOfContents(dotsMinLevel=0)
        toc.levelStyles = [st.toc]
        story += [NewPage(recto=not cfg.screen), Mark("blank"), Spacer(1, doc.frame_h * 0.12),
                  TrackedLine("CONTENTS", f.regular, fs * 0.95, INK, 0.22),
                  Ornament(f, fs, cfg.accent, space=fs * 0.6), Spacer(1, fs), toc]

    def para(text, style, el, **kw):
        p = BookPara(text, style, **kw)
        p._book_el = el
        return p

    first_chapter, next_is_opening, after_break = True, False, False
    chapter = -1
    for i, el in enumerate(elements):
        k = el["kind"]
        if k == "chapter":
            if chapter >= 0:                                 # what closes the chapter before this one
                for pic in at["chapter_end"].get(chapter, ()):
                    story += picture_flowables(doc, cfg, st, pic)
            chapter += 1
            starts = at["chapter_start"].get(chapter, ())
            for pic in starts:                               # a plate facing the chapter's opening
                if pic["size"] == "page":
                    story += picture_flowables(doc, cfg, st, pic)
            story.append(NewPage(recto=(first_chapter or cfg.recto) and not cfg.screen))   # no blank pages on a screen
            first_chapter = False
            head = el["title"] or el["label"] or cfg.title
            toc_text = (f"{el['label']}: {el['title']}" if cfg.toc_labels and el["label"] and el["title"]
                        else el["title"] or el["label"])
            story += [Mark("chapter", (smarten(head), smarten(toc_text) if toc_text else None, f"chapter-{chapter}")),
                      Spacer(1, doc.frame_h * 0.17)]
            if el["label"]:
                story.append(TrackedLine(el["label"].upper(), f.regular, fs * 0.92, cfg.accent, 0.24,
                                         pad_after=fs * 0.5))
            if el["title"]:
                story.append(Paragraph(inline_markup(smarten(el["title"])), st.chapter_title))
            if el["label"] or el["title"]:
                story += [Ornament(f, fs * 1.05, cfg.accent, space=fs * 0.7), Spacer(1, lead * 1.6)]
            for pic in starts:                               # in the text: under the chapter's heading
                if pic["size"] != "page":
                    story += picture_flowables(doc, cfg, st, pic, inline_only=True)
            next_is_opening = True
        elif k == "section":
            story += [CondPageBreak(lead * 5), Spacer(1, lead),
                      TrackedLine(smarten(el["title"]).upper(), f.regular, fs * 0.85, INK, 0.18,
                                  pad_after=lead * 0.6)]
            after_break = True
        elif k == "break":
            story += [CondPageBreak(lead * 4), Ornament(f, fs, cfg.accent, style="scene", space=lead * 0.45)]
            after_break = True
        elif k == "item":
            story.append(para(inline_markup(smarten(el["text"])), st.item, i, bulletText=el["bullet"]))
            next_is_opening, after_break = False, True
        else:
            if next_is_opening:
                opening = opening_paragraph(el["text"], cfg, st)
                (opening.P if isinstance(opening, ParagraphAndImage) else opening)._book_el = i
                opening._book_el = i
                story.append(opening)
            else:
                style = st.first if after_break else st.body
                story.append(para(inline_markup(smarten(el["text"])), style, i))
            next_is_opening = after_break = False
        for pic in at["after"].get(i, ()):                   # after this very paragraph
            story += picture_flowables(doc, cfg, st, pic)
            after_break = after_break or pic["size"] != "page"     # the line after a picture isn't indented
    if chapter >= 0:
        for pic in at["chapter_end"].get(chapter, ()):
            story += picture_flowables(doc, cfg, st, pic)
    for pic in at["end"]:
        story += picture_flowables(doc, cfg, st, dict(pic, size="page") if pic["size"] == "page" else pic)
    return story


# ───────────────────────────── main ──────────────────────────────────

class Stopped(Exception):
    """make_book was asked to stop."""


def detect_title(elements, meta, src, title=None, author=None):
    """Title and author: given > metadata > a short first line (+ "by ..." line) > a lone "# Heading" > the file
    name. Takes what it uses out of `elements`."""
    title, author = title or meta.get("title"), author or meta.get("author")
    if not title and elements and elements[0]["kind"] == "para" and looks_like_title(elements[0]["text"]):
        title = tidy_title(elements.pop(0)["text"])
        if elements and elements[0]["kind"] == "para" and re.match(r"^by\s+\S", elements[0]["text"], re.I) \
                and len(elements[0]["text"]) < 60:
            author = author or elements.pop(0)["text"][3:].strip()
    h1s = [e for e in elements if e["kind"] == "chapter" and e.get("md")]
    if not title and elements and elements[0] in h1s and len(h1s) == 1 and elements[0]["title"]:
        title = elements.pop(0)["title"]           # a lone "# Heading" at the top is the book title
        if elements and elements[0]["kind"] == "para" and re.match(r"^by\s+\S", elements[0]["text"], re.I) \
                and len(elements[0]["text"]) < 60:
            author = author or elements.pop(0)["text"][3:].strip()
    title = title or title_case(re.sub(r"[_\-]+", " ", Path(src).stem))
    if not any(e["kind"] == "chapter" for e in elements) and \
            sum(e["kind"] == "section" for e in elements) >= 2:   # "## sections" become the chapters
        for e in elements:
            if e["kind"] == "section":
                e.update(kind="chapter", label=None)
    return title, author


def preview(src):
    """What a book of `src` would be, without making it: (title, author, chapters)."""
    text, meta = load_text(src)
    elements = build_elements(text)
    title, author = detect_title(elements, meta, src)
    return title, author, sum(1 for e in elements if e["kind"] == "chapter")


def with_opening(elements):
    """The elements as the book is built from them: an untitled chapter in front when the text doesn't open
    with one. Their positions in this list are what "after paragraph N" and the page map count by."""
    if not elements or elements[0]["kind"] != "chapter":
        return [{"kind": "chapter", "label": None, "title": None}] + elements
    return elements


def element_for_page(el_pages, page, own_page):
    """Which paragraph a picture asked for "on page N" goes after, from where the paragraphs landed in a
    book already made (`el_pages`: element → (first page, last page)). A page of its own goes after the last
    paragraph that ends before page N — so the picture becomes about page N; one in the text goes after the
    first paragraph that ends on page N or later. None: before any paragraph (it goes to the front)."""
    if own_page:
        before = [i for i, (_a, b) in el_pages.items() if b < page]
        return max(before) if before else None
    onward = [i for i, (_a, b) in el_pages.items() if b >= page]
    return min(onward) if onward else (max(el_pages) if el_pages else None)


def _check_pictures(pictures, chapters):
    out = []
    for n, pic in enumerate(pictures or ()):
        pic = dict(pic)
        where, size = pic.get("where", "end"), pic.get("size", "page")
        if where not in PICTURE_PLACES:
            raise ValueError(f"picture {n + 1}: unknown place {where!r}")
        if size not in PICTURE_SIZES:
            raise ValueError(f"picture {n + 1}: unknown size {size!r}")
        if not Path(pic.get("path", "")).is_file():
            raise FileNotFoundError(f"No such picture: {pic.get('path')}")
        if where in ("chapter_start", "chapter_end"):
            if not 0 <= int(pic.get("index", -1)) < chapters:
                raise ValueError(f"picture {n + 1}: the book has {chapters} chapter{'s' if chapters != 1 else ''}")
        pic.update(where=where, size=size, index=int(pic.get("index", 0) or 0), caption=pic.get("caption") or "")
        out.append(pic)
    return out


def make_book(src, out=None, *, title=None, author=None, size="6x9", font_size=None, paper="texture",
              recto=False, symmetric=False, toc=True, toc_labels=False, dropcaps=True, accent=ACCENT,
              fonts=None, lang="en_US", pictures=None, progress=None, stop=None):
    """Typesets `src` as a book PDF at `out` (default: beside it, .pdf). `progress(text)` hears how it's going;
    `stop` (a threading.Event) stops it (raises Stopped).

    `pictures`: a list of dicts — `path`; `where`: "front" (after the title page), "chapter_start" /
    "chapter_end" (`index`: the chapter, counting from 0), "after" (`index`: the paragraph, as `el_pages`
    numbers them), "page" (`index`: a page number of the book *without* these page-placed pictures — it's made
    once without them to see where the paragraphs fall) or "end"; `size`: "page" (a page of its own), "wide"
    (across the text) or "half"; `caption` (optional).

    Returns a summary: out, pages, title, author, chapters, size, font_size, font, and — for placing pictures —
    `chapter_list` [(title, page)], `el_pages` {paragraph: (first page, last page)} and `pictures` (how many
    went in). Raises FileNotFoundError / ValueError when it can't."""
    say = progress or (lambda _t: None)
    src = Path(src)
    if not src.exists():
        raise FileNotFoundError(f"No such file: {src}")
    if size not in PAGE_SIZES:
        raise ValueError(f"unknown size {size!r}")
    out = Path(out) if out else src.with_suffix(".pdf")
    out.parent.mkdir(parents=True, exist_ok=True)

    say("Reading the text…")
    text, meta = load_text(src)
    elements = build_elements(text)
    title, author = detect_title(elements, meta, src, title, author)
    found_chapters = sum(1 for e in elements if e["kind"] == "chapter")      # the headings in the text
    elements = with_opening(elements)
    n_chapters = sum(1 for e in elements if e["kind"] == "chapter")
    pictures = _check_pictures(pictures, n_chapters)

    w_in, h_in = PAGE_SIZES[size]
    fs = font_size or round(10.5 + (w_in - 5) * 0.5, 1)
    screen = size in SCREEN_SIZES
    sym = symmetric or screen
    side = 0.075 if screen else 0.125                  # a screen needs no gutter for a binding
    cfg = SimpleNamespace(
        title=title, author=author, page=(w_in * inch, h_in * inch), font_size=fs, leading=fs * 1.34,
        inner=w_in * inch * (side if sym else 0.14), outer=w_in * inch * (side if sym else 0.11),
        top=h_in * inch * (0.07 if screen else 0.095), bottom=h_in * inch * (0.08 if screen else 0.105),
        paper=paper, recto=recto and not screen, toc=toc, toc_labels=toc_labels, screen=screen,
        dropcaps=dropcaps, accent=accent, lang=lang,
        fonts=register_fonts(locate_fonts(fonts, say)),
    )
    if not HAVE_PYPHEN and lang:
        print("  (tip: pip install pyphen for hyphenation)", file=sys.stderr)

    def on_progress(kind, value):
        if stop is not None and stop.is_set():
            raise Stopped()
        if kind == "PAGE":
            say(f"Setting page {value}…")

    with tempfile.TemporaryDirectory() as tmp:
        say("Making the paper…" if paper == "texture" else "Setting the pages…")
        cfg.paper_images = make_paper(*cfg.page, tmp, gutter_shadow=not screen) if paper == "texture" else None
        if paper == "texture" and not cfg.paper_images:
            print("  (tip: pip install pillow numpy for paper texture; using flat cream)", file=sys.stderr)
        for n, pic in enumerate(pictures):
            say(f"Reading picture {n + 1} of {len(pictures)}…")
            pic["file"], pic["w"], pic["h"] = prepare_picture(pic["path"], tmp, n, max(cfg.page))

        def build(target, pics):
            doc = BookDoc(str(target), cfg)
            doc.setProgressCallBack(on_progress)
            doc.multiBuild(build_story(doc, cfg, elements, pics))
            return doc

        by_page = [p for p in pictures if p["where"] == "page"]
        if by_page:                                    # where do the paragraphs fall without them?
            say("Finding the pages…")
            base = build(Path(tmp) / "without-pictures.pdf", [p for p in pictures if p["where"] != "page"])
            for pic in by_page:
                el = element_for_page(base.state.el_pages, pic["index"], pic["size"] == "page")
                pic.update(where="front", index=0) if el is None else pic.update(where="after", index=el)
            if pictures:
                say("Setting the pages with the pictures…")
        doc = build(out, pictures)

    return SimpleNamespace(out=out, pages=doc.page, title=title, author=author,
                           chapters=found_chapters,
                           size=size, font_size=fs,
                           font="EB Garamond" if cfg.fonts.regular == "Book" else cfg.fonts.regular,
                           chapter_list=list(doc.state.chapters), el_pages=dict(doc.state.el_pages),
                           pictures=len(pictures))


def parse_picture(spec):
    """"photo.jpg@chapter 3", "…@after chapter 3", "…@page 12", "…@front", "…@end" — then ",wide" / ",half"
    (default: a page of its own) and ",a caption". → a `pictures` entry for make_book."""
    path, _, rest = spec.rpartition("@")
    if not path:
        path, rest = spec, "end"
    parts = [x.strip() for x in rest.split(",")]
    where = parts[0].lower()
    pic = {"path": path, "size": "page", "caption": ""}
    m = re.fullmatch(r"(after\s+)?chapter\s+(\d+)", where)
    if m:
        pic.update(where="chapter_end" if m.group(1) else "chapter_start", index=int(m.group(2)) - 1)
    elif (m := re.fullmatch(r"page\s+(\d+)", where)):
        pic.update(where="page", index=int(m.group(1)))
    elif where in ("front", "end"):
        pic.update(where=where)
    else:
        raise ValueError(f"--picture: where is {parts[0]!r}? Use front, end, chapter N, after chapter N or page N")
    rest = parts[1:]
    if rest and rest[0].lower() in PICTURE_SIZES:
        pic["size"] = rest.pop(0).lower()
    pic["caption"] = ", ".join(rest)
    return pic


def main(argv=None):
    ap = argparse.ArgumentParser(description="Turn a .txt file into a book-like PDF.")
    ap.add_argument("input", help="plain-text (.txt/.md) or .rtf file")
    ap.add_argument("-o", "--output", help="output PDF (default: input name with .pdf)")
    ap.add_argument("--title", help="book title (default: 'Title:' line, first line, or file name)")
    ap.add_argument("--author", help="author name")
    ap.add_argument("--size", default="6x9", choices=PAGE_SIZES,
                    help="trim size (default 6x9; 'iphone' = the iPhone 17 Pro Max screen's shape)")
    ap.add_argument("--font-size", type=float, help="body text size in points (default suits the trim size)")
    ap.add_argument("--paper", default="texture", choices=["texture", "flat", "white"],
                    help="cream paper with texture, flat cream, or white for printing")
    ap.add_argument("--recto", action="store_true", help="start every chapter on a right-hand page, like print")
    ap.add_argument("--symmetric", action="store_true", help="equal left/right margins (nicer on screen)")
    ap.add_argument("--no-toc", action="store_true", help="skip the contents page")
    ap.add_argument("--toc-labels", action="store_true", help="show 'Chapter One: Title' in the contents")
    ap.add_argument("--no-dropcaps", action="store_true", help="no drop caps on chapter openings")
    ap.add_argument("--accent", default=ACCENT, help=f"hex colour for drop caps and ornaments (default {ACCENT})")
    ap.add_argument("--fonts", help="folder of .ttf files to use instead of EB Garamond (needs Regular and Italic)")
    ap.add_argument("--lang", default="en_US", help="hyphenation language, e.g. en_GB, de_DE ('' to disable)")
    ap.add_argument("--picture", action="append", default=[], metavar="FILE@WHERE[,SIZE][,CAPTION]",
                    help="add a picture: WHERE is front, end, 'chapter 3', 'after chapter 3' or 'page 12'; SIZE is "
                         "page (its own page, the default), wide or half. Repeat for more pictures")
    a = ap.parse_args(argv)
    try:
        r = make_book(a.input, a.output, title=a.title, author=a.author, size=a.size, font_size=a.font_size,
                      paper=a.paper, recto=a.recto, symmetric=a.symmetric, toc=not a.no_toc,
                      toc_labels=a.toc_labels, dropcaps=not a.no_dropcaps, accent=a.accent, fonts=a.fonts,
                      lang=a.lang, pictures=[parse_picture(p) for p in a.picture])
    except (FileNotFoundError, ValueError) as e:
        sys.exit(str(e))
    chap = f"{r.chapters} chapter{'s' if r.chapters != 1 else ''}" if r.chapters else "no chapter headings found"
    size = "iPhone-screen pages" if r.size in SCREEN_SIZES else f"{r.size} in"
    print(f"✓ {r.out}  —  {r.pages} pages, {chap}, {size}, {r.font_size:g} pt {r.font}")


if __name__ == "__main__":
    main()
