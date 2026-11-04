"""Make a PDF easier to read — on the iPhone (`IPHONE`) or in Safe Finder's own viewer on the Mac (`MAC`) — as a
new PDF beside the original ("<name> (for iPhone).pdf", "<name> (for Safe Finder).pdf"); the original is never
touched. Nothing is retyped or reflowed: every page's own drawing is reused, cut and placed, so pictures, fonts and
layout stay as they were (and, through the Swift composer, the text stays text — sharp and searchable).

**For iPhone** (iPhone 17 Pro Max: 1320 × 2868 pixels, 440 × 956 points): the new pages are the shape of the
phone's screen, so one page fills it and the next is a swipe away. Each page's margins are trimmed (to the same box
on every page, so the text doesn't change size page to page); a two-column page is split into its columns — read
down the left, then the right — so its text comes out nearly twice as large; and the content flows from page to
page, cut only in the white space between lines. A picture taller than the screen is shrunk to fit it rather than
cut, unless it's very tall (a long scan with no gaps), which is cut into screen-high slices.

**For Safe Finder**: the pages stay whole and in order, but trimmed to their content (the same box on every page,
left and right pages separately, as a book's margins alternate) and blank pages left out — so the page, not its
margins, fills Safe Finder's viewer, and the text comes out larger in it.

How: each page is rendered small (QtPdf, `RENDER` pixels a point) and read for ink — the content's box, a column
gutter (a white band in the middle that runs down a tall stretch of the page with text on both sides), and the
white rows between lines. That gives a plan: which part of which page goes where on which new page. The plan is
drawn by `pdf_helper.swift` (Core Graphics: the source pages drawn clipped and scaled — vectors) or, without it
(no Xcode tools, or it didn't build: `pdf_helper.log`), by Qt, from pictures of the pages at the iPhone's 3
pixels a point — sharp on the phone, but the text is no longer selectable.

Everything here runs on a worker thread; `optimize` reports progress through a callback and stops when asked.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

IPHONE, MAC = "iphone", "mac"
IPHONE_SIZE = (440.0, 956.0)        # the iPhone 17 Pro Max's screen in points (1320 × 2868 px at 3×)
SIDE = 12.0                         # room at the sides (the screen's rounded corners)
TOP = 18.0                          # and at the top and bottom (the Dynamic Island, the home bar)
MAX_SCALE = 2.4                     # a narrow column or a lone short line isn't blown up past this
BLOCK_GAP = 10.0                    # between a page's regions on the new page (points)
PAGE_GAP = 18.0                     # between one original page and the next
MAC_PAD = 14.0                      # white kept round the content for Safe Finder
RENDER = 2.0                        # pixels a point when reading a page
NAMES = {IPHONE: "for iPhone", MAC: "for Safe Finder"}


class Stopped(Exception):
    pass


# ----------------------------------------------------------------------------- reading a page

@dataclass
class Block:
    """A part of a page read as one piece: the whole width (`kind` "full") or one column ("col"), with the
    stretches of ink in it from top to bottom (`atoms`, points, y down) — the white between them is where it
    can be cut."""
    kind: str
    x0: float
    x1: float
    atoms: list[tuple[float, float]]
    side: str = ""                              # "left" / "right" for a column


@dataclass
class PageInfo:
    index: int
    width: float
    height: float
    box: tuple[float, float, float, float] | None      # the ink's box (x0, y0, x1, y1), None for a blank page
    blocks: list[Block] = field(default_factory=list)
    gutter: tuple[float, float] | None = None


def _runs(mask) -> list[tuple[int, int]]:
    """[start, end) of each run of True in a 1-D bool array."""
    import numpy as np
    if not len(mask):
        return []
    m = np.concatenate(([False], mask, [False]))
    edges = np.flatnonzero(m[1:] != m[:-1])
    return list(zip(edges[::2].tolist(), edges[1::2].tolist()))


def _atoms(rows, y_off: int, min_gap_px: int) -> list[tuple[int, int]]:
    """The stretches of ink rows (pixels), runs closer than `min_gap_px` joined."""
    out: list[list[int]] = []
    for a, b in _runs(rows):
        if out and a - out[-1][1] < min_gap_px:
            out[-1][1] = b
        else:
            out.append([a, b])
    return [(a + y_off, b + y_off) for a, b in out]


def read_page(gray, index: int, width: float, height: float, scale: float = RENDER) -> PageInfo:
    """What's on a page, from its picture (`gray`: a 2-D uint8 array, `scale` pixels a point)."""
    import numpy as np
    h_px, w_px = gray.shape
    edge = np.concatenate([gray[:3].ravel(), gray[-3:].ravel(), gray[:, :3].ravel(), gray[:, -3:].ravel()])
    lo, hi = np.percentile(edge, [10, 90])
    # The paper's colour from the edges — unless the edges are a picture (a photo to the edge): then nothing on
    # the page is paper, and it's kept whole.
    bg = 255.0 if hi - lo > 40 else float(np.median(edge))
    ink = np.abs(gray.astype(np.int16) - bg) > 48
    rows, cols = ink.sum(1), ink.sum(0)
    ry = np.flatnonzero(rows >= max(1, int(w_px * 0.0015)))
    cx = np.flatnonzero(cols >= max(1, int(h_px * 0.0015)))
    info = PageInfo(index, width, height, None)
    if not len(ry) or not len(cx):
        return info
    y0, y1, x0, x1 = int(ry[0]), int(ry[-1]) + 1, int(cx[0]), int(cx[-1]) + 1
    info.box = (x0 / scale, y0 / scale, x1 / scale, y1 / scale)
    gap_px = max(1, int(round(1.0 * scale)))          # ink closer than a point is one piece (a letter's accent)

    def block(kind: str, bx0: int, bx1: int, ya: int, yb: int, side: str = "") -> Block | None:
        area = ink[ya:yb, bx0:bx1]
        atoms = _atoms(area.any(1), ya, gap_px)
        if not atoms:
            return None
        xs = np.flatnonzero(area.any(0))                 # the ink's own sides (a column's edge at the gutter)
        return Block(kind, (bx0 + xs[0]) / scale, (bx0 + xs[-1] + 1) / scale,
                     [(a / scale, b / scale) for a, b in atoms], side)

    # A column gutter: in the middle quarter of the content, a band at least 8 points wide that the fewest rows
    # have ink in — counted per 8-point window, wider than a word space, so a line across the whole width touches
    # every window alike and its word gaps can't pass for a gutter. The middle only: a table's narrow label column
    # isn't a page's column. Two columns are only believed where that band is white over a tall stretch (40
    # points) with ink on both sides.
    gutter = None
    bw, bh = x1 - x0, y1 - y0
    win = max(2, int(8 * scale))
    if bw >= 220 * scale and bh >= 120 * scale:
        za, zb = x0 + int(bw * 0.38), x0 + int(bw * 0.62)
        sub = ink[y0:y1, za:zb + win]
        cs = np.concatenate([np.zeros((sub.shape[0], 1), np.int32), np.cumsum(sub, axis=1, dtype=np.int32)], axis=1)
        score = ((cs[:, win:] - cs[:, :-win]) > 0).sum(0)[: zb - za]
        floor = int(score.min())
        best = max(_runs(score <= floor + max(2, int(bh * 0.01))), key=lambda r: r[1] - r[0], default=None)
        if best:
            gutter = (za + best[0], za + best[1] - 1 + win)
    regions: list[tuple[str, int, int]] = []          # ("full" | "two", row from, row to)
    if gutter:
        # Whether a row crosses is told by the gutter's middle 4 points only: a ragged-right column's longer lines
        # reach into its edge without crossing it. The columns are split at that middle, so those ends stay theirs.
        mid = (gutter[0] + gutter[1]) // 2
        half = max(1, int(2 * scale))
        gx0, gx1 = mid - half, mid + half
        g = ink[y0:y1, gx0:gx1].any(1)
        left = ink[y0:y1, x0:gx0].any(1)
        right = ink[y0:y1, gx1:x1].any(1)
        anything = left | right
        for a, b in _runs(~g):
            # A short band at the top or bottom set off by white (a heading whose big word gap sits on the gutter)
            # is read across, not cut in two. Only at the ends: white across both columns in the middle (paragraph
            # breaks that happen to line up) mustn't change the order the columns are read in.
            gaps = [(a + ga, a + gb) for ga, gb in _runs(~anything[a:b]) if gb - ga >= 6 * scale]
            while gaps and gaps[0][0] - a < 40 * scale:
                a = gaps.pop(0)[1]
            while gaps and b - gaps[-1][1] < 40 * scale:
                b = gaps.pop()[0]
            l, r = left[a:b], right[a:b]
            used = (l | r).sum()
            if b - a >= 40 * scale and used and l.sum() >= 0.25 * used and r.sum() >= 0.25 * used:
                regions.append(("two", y0 + a, y0 + b))
        if not regions:
            gutter = None
    # Everything not in a two-column stretch is read across the whole width.
    blocks: list[Block] = []
    at = y0
    for kind, a, b in regions + [("end", y1, y1)]:
        if a > at:
            full = block("full", x0, x1, at, a)
            if full:
                blocks.append(full)
        if kind == "two":
            mid = (gutter[0] + gutter[1]) // 2
            for part in (block("col", x0, mid, a, b, "left"), block("col", mid, x1, a, b, "right")):
                if part:
                    blocks.append(part)
        at = max(at, b)
    info.blocks = blocks
    if gutter:
        info.gutter = (gutter[0] / scale, gutter[1] / scale)
    return info


# ----------------------------------------------------------------------------- the plan

@dataclass
class Piece:
    page: int                                   # the original page
    src: tuple[float, float, float, float]      # x, y, w, h on it (points, from its top left, as shown)
    dst: tuple[float, float, float, float]      # x, y, w, h on the new page


@dataclass
class OutPage:
    width: float
    height: float
    pieces: list[Piece] = field(default_factory=list)


def _common_boxes(pages: list[PageInfo]) -> dict[tuple[int, int, int], tuple[float, float, float, float]]:
    """The usual content box for each page size and side (odd/even): the median of the pages' boxes — so every
    page is trimmed alike and its text keeps one size."""
    import statistics
    groups: dict[tuple[int, int, int], list[tuple[float, float, float, float]]] = {}
    for p in pages:
        if p.box:
            groups.setdefault((round(p.width), round(p.height), p.index % 2), []).append(p.box)
    return {k: tuple(statistics.median(b[i] for b in boxes) for i in range(4)) for k, boxes in groups.items()}


def _page_box(p: PageInfo, common: dict) -> tuple[float, float, float, float]:
    """The page's trim box: the usual box for its kind of page, grown to take in anything of its own outside it."""
    c = common.get((round(p.width), round(p.height), p.index % 2), p.box)
    b = p.box
    return (min(c[0], b[0]), min(c[1], b[1]), max(c[2], b[2]), max(c[3], b[3]))


def plan_mac(pages: list[PageInfo]) -> list[OutPage]:
    common = _common_boxes(pages)
    out = []
    for p in pages:
        if not p.box:
            continue                                     # a blank page
        x0, y0, x1, y1 = _page_box(p, common)
        x0, y0 = max(0.0, x0 - MAC_PAD), max(0.0, y0 - MAC_PAD)
        x1, y1 = min(p.width, x1 + MAC_PAD), min(p.height, y1 + MAC_PAD)
        w, h = x1 - x0, y1 - y0
        out.append(OutPage(w, h, [Piece(p.index, (x0, y0, w, h), (0.0, 0.0, w, h))]))
    return out


def plan_iphone(pages: list[PageInfo], size: tuple[float, float] = IPHONE_SIZE) -> list[OutPage]:
    """The pages' blocks flowed onto phone-shaped pages (module notes)."""
    W, H = size
    cw, ch = W - 2 * SIDE, H - 2 * TOP
    common = _common_boxes(pages)
    out: list[OutPage] = []
    state = {"cursor": ch, "piece": None}                # a fresh page is started by the first thing placed

    def new_page() -> None:
        out.append(OutPage(W, H))
        state["cursor"], state["piece"] = 0.0, None

    def place(page: int, x0: float, y0: float, y1: float, w: float, s: float, at: float, dx: float) -> Piece:
        piece = Piece(page, (x0, y0, w, y1 - y0), (dx, TOP + at, w * s, (y1 - y0) * s))
        out[-1].pieces.append(piece)
        return piece

    for p in pages:
        if not p.box:
            continue
        bx0, _by0, bx1, _by1 = _page_box(p, common)
        first_block = True
        for block in p.blocks:
            if block.kind == "full":                     # the whole width keeps the page's trim, for one text size
                x0, x1 = min(bx0, block.x0), max(bx1, block.x1)
            elif block.side == "left":                   # a column keeps the page's trim on its outer side
                x0, x1 = min(bx0, block.x0), block.x1
            else:
                x0, x1 = block.x0, max(bx1, block.x1)
            x0, x1 = max(0.0, x0 - 1), min(p.width, x1 + 1)
            w = x1 - x0
            s = min(cw / w, MAX_SCALE)
            dx = SIDE + (cw - w * s) / 2
            lead = PAGE_GAP if first_block else BLOCK_GAP
            first_block = False
            state["piece"] = None                        # a new block never extends the last one's piece
            atoms = block.atoms
            for i, (a0, a1) in enumerate(atoms):
                # a hair of white round each stretch (no more than half the gap to the next)
                above = (a0 - atoms[i - 1][1]) / 2 if i else 1.0
                below = (atoms[i + 1][0] - a1) / 2 if i + 1 < len(atoms) else 1.0
                a0, a1 = max(0.0, a0 - min(1.0, above)), min(p.height, a1 + min(1.0, below))
                h = (a1 - a0) * s
                piece: Piece | None = state["piece"]
                if piece is not None:                    # the same block, on the same new page: grow its piece
                    grown = (a1 - piece.src[1]) * s
                    if piece.dst[1] - TOP + grown <= ch:
                        piece.src = (piece.src[0], piece.src[1], piece.src[2], a1 - piece.src[1])
                        piece.dst = (piece.dst[0], piece.dst[1], piece.dst[2], grown)
                        state["cursor"] = piece.dst[1] - TOP + grown
                        continue
                gap = lead if state["piece"] is None and state["cursor"] > 0 else 0.0
                lead = 0.0
                if state["cursor"] + gap + h <= ch and out:
                    state["piece"] = place(p.index, x0, a0, a1, w, s, state["cursor"] + gap, dx)
                    state["cursor"] += gap + h
                elif h <= ch:
                    new_page()
                    state["piece"] = place(p.index, x0, a0, a1, w, s, 0.0, dx)
                    state["cursor"] = h
                elif h <= 1.5 * ch:                      # a tall picture: alone on a page, shrunk to fit
                    new_page()
                    s2 = ch / (a1 - a0)
                    place(p.index, x0, a0, a1, w, s2, 0.0, SIDE + (cw - w * s2) / 2)
                    state["cursor"], state["piece"] = ch, None
                else:                                    # a very tall one with no white to cut at: slices
                    step = ch / s
                    y = a0
                    while y < a1 - 0.5:
                        new_page()
                        y2 = min(a1, y + step)
                        place(p.index, x0, y, y2, w, s, 0.0, dx)
                        y = y2
                    state["cursor"], state["piece"] = ch, None
    return out


# ----------------------------------------------------------------------------- doing it

def out_name(path: str, target: str) -> str:
    stem = Path(path).stem
    for tag in NAMES.values():                           # "X (for iPhone)" made again from itself: not doubled
        if stem.endswith(f" ({tag})"):
            stem = stem[: -len(tag) - 3]
    return f"{stem} ({NAMES[target]}).pdf"


def _qt():
    from PySide6.QtCore import QSize
    from PySide6.QtGui import QColor, QImage, QPainter
    from PySide6.QtPdf import QPdfDocument
    return QSize, QColor, QImage, QPainter, QPdfDocument


def open_document(path: str, password: str = ""):
    """A QPdfDocument for `path` (any thread), or raises ValueError with why it can't be read."""
    _QSize, _QColor, _QImage, _QPainter, QPdfDocument = _qt()
    doc = QPdfDocument()
    if password:
        doc.setPassword(password)
    err = doc.load(path)
    if err != QPdfDocument.Error.None_:
        why = {QPdfDocument.Error.IncorrectPassword: "it's protected by a password",
               QPdfDocument.Error.FileNotFound: "the file isn't there",
               QPdfDocument.Error.InvalidFileFormat: "it isn't a PDF that can be read",
               QPdfDocument.Error.UnsupportedSecurityScheme: "its protection isn't supported"}.get(err, "it can't be read")
        raise ValueError(why)
    return doc


def render(doc, index: int, scale: float):
    """Page `index` on white at `scale` pixels a point. (A whole page: QPdfDocument's clip option doesn't place
    the part where it says, so parts are cut from this.)"""
    QSize, QColor, QImage, QPainter, _QPdfDocument = _qt()
    from PySide6.QtPdf import QPdfDocumentRenderOptions
    size = doc.pagePointSize(index)
    full = QSize(max(1, round(size.width() * scale)), max(1, round(size.height() * scale)))
    opts = QPdfDocumentRenderOptions()
    opts.setRenderFlags(QPdfDocumentRenderOptions.RenderFlag.Annotations)
    img = doc.render(index, full, opts)
    canvas = QImage(img.size(), QImage.Format.Format_RGB32)
    canvas.fill(QColor("white"))
    p = QPainter(canvas)
    p.drawImage(0, 0, img)
    p.end()
    return canvas


def _gray_array(img):
    import numpy as np
    from PySide6.QtGui import QImage
    g = img.convertToFormat(QImage.Format.Format_Grayscale8)
    buf = np.frombuffer(g.constBits(), dtype=np.uint8, count=g.sizeInBytes())
    return buf.reshape(g.height(), g.bytesPerLine())[:, : g.width()].copy()


def read_document(doc, progress: Callable[[str], None], stop: threading.Event | None) -> list[PageInfo]:
    pages = []
    n = doc.pageCount()
    for i in range(n):
        if stop is not None and stop.is_set():
            raise Stopped()
        if i % 5 == 0:
            progress(f"Reading page {i + 1:,} of {n:,}…")
        size = doc.pagePointSize(i)
        pages.append(read_page(_gray_array(render(doc, i, RENDER)), i, size.width(), size.height()))
    return pages


# -- composing: the Swift helper (vectors), else Qt (pictures)

_helper: list[str] | None | bool = False
_helper_lock = threading.Lock()
helper_problem = ""


def _helper_source() -> Path | None:
    here = Path(__file__).resolve().parent
    candidates = [here / "pdf_helper.swift"]
    if getattr(sys, "frozen", False):
        contents = Path(sys.executable).resolve().parent.parent
        candidates += [contents / "Resources" / "pdf_helper.swift",
                       Path(getattr(sys, "_MEIPASS", here)) / "pdf_helper.swift"]
    return next((c for c in candidates if c.is_file()), None)


def helper() -> list[str] | None:
    """The composer's command, built the first time (or when its source is newer). SAFE_FINDER_PDF_HELPER names
    a stand-in (tests); "" turns it off."""
    global _helper, helper_problem
    with _helper_lock:
        if _helper is not False:
            return _helper
        env = os.environ.get("SAFE_FINDER_PDF_HELPER")
        if env is not None:
            _helper = env.split("\x1f") if env else None
            return _helper
        _helper = None
        src = _helper_source()
        if sys.platform != "darwin" or src is None:
            helper_problem = "the Mac's PDF tools aren't here"
            return None
        out = Path.home() / "Library" / "Caches" / "PhotoBrowser" / "pdf_helper"
        log = out.with_name("pdf_helper.log")
        if out.is_file() and out.stat().st_mtime >= src.stat().st_mtime:
            _helper = [str(out)]
            return _helper
        if subprocess.run(["xcode-select", "-p"], capture_output=True).returncode != 0:
            helper_problem = "Xcode's Command Line Tools aren't installed (xcode-select --install)"
            return None
        out.parent.mkdir(parents=True, exist_ok=True)
        try:
            r = subprocess.run(["xcrun", "swiftc", "-O", "-parse-as-library", "-swift-version", "5", "-o", str(out),
                                str(src)], capture_output=True, text=True, timeout=600)
        except (OSError, subprocess.SubprocessError) as e:
            helper_problem = f"the PDF tools couldn't be built ({e})"
            return None
        if r.returncode == 0 and out.is_file():
            _helper = [str(out)]
            try:
                log.unlink()
            except OSError:
                pass
        else:
            helper_problem = f"the PDF tools didn't build — see {log}"
            try:
                log.write_text(f"swiftc failed ({r.returncode}) building {src}\n\n{r.stderr or ''}{r.stdout or ''}")
            except OSError:
                pass
        return _helper


def plan_json(plan: list[OutPage], title: str) -> dict:
    return {"title": title, "creator": "Safe Finder",
            "pages": [{"size": [round(o.width, 3), round(o.height, 3)],
                       "pieces": [{"page": pc.page, "src": [round(v, 3) for v in pc.src],
                                   "dst": [round(v, 3) for v in pc.dst]} for pc in o.pieces]} for o in plan]}


def compose_with_helper(cmd: list[str], src: str, plan: list[OutPage], title: str, out: str, password: str,
                        progress: Callable[[str], None], stop: threading.Event | None) -> str:
    """"" when the helper wrote `out`, else why not."""
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
        json.dump(plan_json(plan, title), f)
        plan_file = f.name
    env = dict(os.environ)
    if password:
        env["PDF_PASSWORD"] = password
    try:
        proc = subprocess.Popen([*cmd, "compose", src, plan_file, out], stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, text=True, env=env)
    except OSError as e:
        os.unlink(plan_file)
        return str(e)
    why = ""
    try:
        for line in proc.stdout or []:
            if stop is not None and stop.is_set():
                proc.terminate()
                break
            if line.startswith("page "):
                parts = line.split()
                if len(parts) == 3:
                    progress(f"Writing page {parts[1]} of {parts[2]}…")
            elif line.startswith("error "):
                why = line[6:].strip()
        proc.wait()
    finally:
        os.unlink(plan_file)
    if stop is not None and stop.is_set():
        raise Stopped()
    if proc.returncode != 0 and not why:
        why = (proc.stderr.read() if proc.stderr else "").strip().splitlines()[-1:] or ["the PDF tools failed"]
        why = why[0]
    return "" if proc.returncode == 0 and os.path.isfile(out) and os.path.getsize(out) > 0 else (why or "failed")


def compose_with_qt(doc, plan: list[OutPage], title: str, out: str, dpp: float,
                    progress: Callable[[str], None], stop: threading.Event | None) -> None:
    """Qt's way: each new page a picture at `dpp` pixels a point, made of pictures of the original's parts."""
    from PySide6.QtCore import QMarginsF, QRectF, QSizeF
    from PySide6.QtGui import QColor, QImage, QPageLayout, QPageSize, QPainter, QPdfWriter
    writer = QPdfWriter(out)
    writer.setTitle(title)
    writer.setCreator("Safe Finder")
    writer.setResolution(int(round(72 * dpp)))
    painter = None
    cached: list = [None, None]                          # (page, scale) → its picture
    try:
        for n, page in enumerate(plan):
            if stop is not None and stop.is_set():
                raise Stopped()
            if n % 5 == 0:
                progress(f"Writing page {n + 1:,} of {len(plan):,}…")
            layout = QPageLayout(QPageSize(QSizeF(page.width, page.height), QPageSize.Unit.Point, "",
                                           QPageSize.SizeMatchPolicy.ExactMatch),
                                 QPageLayout.Orientation.Portrait, QMarginsF(0, 0, 0, 0))
            if painter is None:
                writer.setPageLayout(layout)
                painter = QPainter(writer)
            else:
                writer.setPageLayout(layout)
                writer.newPage()
            canvas = QImage(max(1, round(page.width * dpp)), max(1, round(page.height * dpp)),
                            QImage.Format.Format_RGB32)
            canvas.fill(QColor("white"))
            cp = QPainter(canvas)
            cp.setRenderHint(QPainter.RenderHint.SmoothPixmapTransform)
            for pc in page.pieces:
                sx, sy, sw, sh = pc.src
                dx, dy, dw, dh = pc.dst
                size = doc.pagePointSize(pc.page)
                k = dw / sw * dpp                        # pixels a point to render the original at
                k = min(k, (60e6 / max(1.0, size.width() * size.height())) ** 0.5)   # ≤ 60 MP a render
                key = (pc.page, round(k, 3))
                if cached[0] != key:                     # one page's parts usually come one after another
                    cached[0], cached[1] = key, render(doc, pc.page, k)
                cp.drawImage(QRectF(dx * dpp, dy * dpp, dw * dpp, dh * dpp), cached[1],
                             QRectF(sx * k, sy * k, sw * k, sh * k))
            cp.end()
            painter.drawImage(QRectF(0, 0, canvas.width(), canvas.height()), canvas)
    finally:
        if painter is not None:
            painter.end()


@dataclass
class Result:
    path: str                     # the new PDF
    pages_in: int
    pages_out: int
    blank: int                    # blank pages left out
    columns: int                  # pages read as two columns (iPhone)
    vector: bool                  # drawn by the Mac's PDF tools (text kept as text)
    note: str = ""                # why it was drawn as pictures, when it was


def optimize(path: str, target: str, password: str = "", progress: Callable[[str], None] | None = None,
             stop: threading.Event | None = None, place: Callable[[str, str, str], str] | None = None) -> Result:
    """Makes the new PDF beside `path` (module notes). `place(temp file, folder, name)` puts it there (Safe
    Finder's drive-safe `simpcity.place`, which never writes over a file); returns where it went. Raises
    ValueError with why when it can't be done, Stopped when stopped."""
    say = progress or (lambda _t: None)
    doc = open_document(path, password)
    if doc.pageCount() < 1:
        raise ValueError("it has no pages")
    from PySide6.QtPdf import QPdfDocument
    title = doc.metaData(QPdfDocument.MetaDataField.Title) or Path(path).stem
    pages = read_document(doc, say, stop)
    say("Laying out the pages…")
    plan = plan_iphone(pages) if target == IPHONE else plan_mac(pages)
    if not plan:
        raise ValueError("every page is blank")
    tmpdir = Path(tempfile.mkdtemp(prefix="safe-finder-pdf-"))
    name = out_name(path, target)
    tmp = tmpdir / name
    try:
        vector, note = False, ""
        cmd = helper()
        if cmd:
            why = compose_with_helper(cmd, path, plan, str(title), str(tmp), password, say, stop)
            vector = not why
            note = why and f"the Mac's PDF tools failed ({why})"
        else:
            note = helper_problem or "the Mac's PDF tools aren't here"
        if not vector:
            compose_with_qt(doc, plan, str(title), str(tmp), 3.0 if target == IPHONE else 2.0, say, stop)
        if not tmp.is_file() or tmp.stat().st_size == 0:
            raise ValueError("the new PDF couldn't be written")
        if place is not None:
            dest = place(str(tmp), str(Path(path).parent), name)
        else:
            dest = str(_unique(Path(path).parent / name))
            shutil.copyfile(tmp, dest)
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)
    columns = sum(1 for p in pages if p.gutter) if target == IPHONE else 0
    return Result(str(dest), len(pages), len(plan), sum(1 for p in pages if not p.box), columns, vector,
                  "" if vector else note)


def _unique(dest: Path) -> Path:
    if not dest.exists():
        return dest
    n = 2
    while (dest.parent / f"{dest.stem} {n}{dest.suffix}").exists():
        n += 1
    return dest.parent / f"{dest.stem} {n}{dest.suffix}"
