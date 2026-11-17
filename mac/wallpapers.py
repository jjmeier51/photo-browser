#!/usr/bin/env python3
"""Theme wallpapers — patterns of little drawings (Santa, snowflakes, candy canes, Christmas trees, ornaments,
presents, holly, gingerbread men, stars) laid over a theme's background, behind the files. No Qt at the top.

**One drawing for both apps.** Each pattern is a square tile of plain shapes — filled polygons, filled circles,
and strokes (optionally dashed, for a candy cane's stripes) — worked out here once, in the tile's own unit square.
Photo Browser for Mac paints them with Qt (`paint_tile`, `tile_pixmap`); the iPhone app draws the very same shapes
from `PhotoBrowser/Wallpapers.swift`, which this file writes (`python3 mac/wallpapers.py --swift`) — so the two
can't drift. Change a drawing here, then write the Swift file again.

A motif is drawn in its own box (−1…1 each way, centred), then placed in the tile at a position, size and angle;
one that crosses an edge of the tile is placed again on the other side, so the tiles meet without a seam. The
whole pattern is drawn at the pattern's `opacity`, so it stays a texture and the file names stay readable —
themes.derive also counts the pattern's colours among the grounds text has to read on (`grounds`).
"""
from __future__ import annotations

import json
import math
import random
import sys
from dataclasses import dataclass

# ----------------------------------------------------------------------------- shapes

# ("poly", color, [x, y, x, y, …]) · ("circle", color, [cx, cy, r]) · ("stroke", color, [x, y, …], width, dash)
Shape = tuple


def poly(color: str, pts: list[tuple[float, float]]) -> Shape:
    return ("poly", color, [v for p in pts for v in p])


def circle(color: str, cx: float, cy: float, r: float) -> Shape:
    return ("circle", color, [cx, cy, r])


def stroke(color: str, pts: list[tuple[float, float]], width: float, dash: float = 0.0) -> Shape:
    return ("stroke", color, [v for p in pts for v in p], width, dash)


def ellipse_pts(cx: float, cy: float, rx: float, ry: float, angle: float = 0.0, n: int = 24) -> list[tuple[float, float]]:
    ca, sa = math.cos(angle), math.sin(angle)
    out = []
    for i in range(n):
        t = 2 * math.pi * i / n
        x, y = rx * math.cos(t), ry * math.sin(t)
        out.append((cx + x * ca - y * sa, cy + x * sa + y * ca))
    return out


def rect_pts(x0: float, y0: float, x1: float, y1: float, r: float = 0.0) -> list[tuple[float, float]]:
    if r <= 0:
        return [(x0, y0), (x1, y0), (x1, y1), (x0, y1)]
    out = []
    for cx, cy, a0 in ((x1 - r, y0 + r, -math.pi / 2), (x1 - r, y1 - r, 0.0), (x0 + r, y1 - r, math.pi / 2),
                       (x0 + r, y0 + r, math.pi)):
        for k in range(5):
            a = a0 + (math.pi / 2) * k / 4
            out.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    return out


def star_pts(cx: float, cy: float, outer: float, inner: float, points: int = 5, angle: float = -math.pi / 2):
    out = []
    for i in range(points * 2):
        r = outer if i % 2 == 0 else inner
        a = angle + math.pi * i / points
        out.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    return out


def arc_pts(cx: float, cy: float, r: float, a0: float, a1: float, n: int = 12) -> list[tuple[float, float]]:
    return [(cx + r * math.cos(a0 + (a1 - a0) * i / n), cy + r * math.sin(a0 + (a1 - a0) * i / n)) for i in range(n + 1)]


# ----------------------------------------------------------------------------- the motifs (each in −1…1)

def snowflake(c: str) -> list[Shape]:
    out: list[Shape] = []
    for k in range(6):
        a = k * math.pi / 3
        d = (math.cos(a), math.sin(a))
        out.append(stroke(c, [(0, 0), (d[0], d[1])], 0.1))
        for t, length in ((0.45, 0.34), (0.74, 0.22)):
            base = (d[0] * t, d[1] * t)
            for side in (1, -1):
                b = a + side * math.pi / 4
                out.append(stroke(c, [base, (base[0] + length * math.cos(b), base[1] + length * math.sin(b))], 0.08))
    out.append(circle(c, 0, 0, 0.14))
    return out


def star(c: str) -> list[Shape]:
    return [poly(c, star_pts(0, 0, 1.0, 0.42))]


def sparkle(c: str) -> list[Shape]:
    return [poly(c, star_pts(0, 0, 1.0, 0.22, 4, 0.0))]


def tree() -> list[Shape]:
    return [
        poly("#6B4226", rect_pts(-0.13, 0.62, 0.13, 0.95, 0.03)),
        poly("#1F7A4A", [(-0.78, 0.7), (0.78, 0.7), (0, 0.02)]),
        poly("#27935A", [(-0.62, 0.32), (0.62, 0.32), (0, -0.38)]),
        poly("#30AD6A", [(-0.46, -0.08), (0.46, -0.08), (0, -0.74)]),
        stroke("#F6E7A8", [(-0.5, 0.52), (0.5, 0.38)], 0.05),
        stroke("#F6E7A8", [(-0.36, 0.12), (0.36, 0.0)], 0.05),
        circle("#E63946", -0.32, 0.55, 0.07), circle("#FFD166", 0.28, 0.5, 0.07),
        circle("#4FC3F7", -0.12, 0.2, 0.065), circle("#E63946", 0.2, 0.08, 0.06),
        circle("#FFD166", -0.08, -0.25, 0.06),
        poly("#FFD700", star_pts(0, -0.8, 0.22, 0.09)),
    ]


def candy_cane() -> list[Shape]:
    path = [(0.22, 0.95), (0.22, -0.3)] + arc_pts(-0.14, -0.3, 0.36, 0.0, -math.pi, 14)[1:] + [(-0.5, -0.12)]
    return [stroke("#FFFFFF", path, 0.28), stroke("#D62839", path, 0.28, 0.13)]


def ornament(c: str) -> list[Shape]:
    return [
        stroke("#C9A227", [(0, -0.72), (0.09, -0.86), (0, -0.98), (-0.09, -0.86), (0, -0.74)], 0.05),
        poly("#D4AF37", rect_pts(-0.19, -0.8, 0.19, -0.6, 0.04)),
        circle(c, 0, 0.02, 0.66),
        stroke("#FFFFFF59", [(-0.62, 0.02), (0.62, 0.02)], 0.1),
        stroke("#FFFFFF40", [(-0.5, 0.26), (-0.25, 0.16), (0, 0.26), (0.25, 0.16), (0.5, 0.26)], 0.06),
        circle("#FFFFFF73", -0.24, -0.22, 0.14),
    ]


def present(box: str, ribbon: str) -> list[Shape]:
    return [
        poly(box, rect_pts(-0.68, -0.32, 0.68, 0.86, 0.04)),
        poly(box, rect_pts(-0.78, -0.5, 0.78, -0.24, 0.04)),
        poly("#00000026", rect_pts(-0.68, -0.24, 0.68, -0.17)),
        poly(ribbon, rect_pts(-0.1, -0.5, 0.1, 0.86)),
        poly(ribbon, rect_pts(-0.68, 0.14, 0.68, 0.32)),
        poly(ribbon, ellipse_pts(-0.25, -0.64, 0.26, 0.14, -0.45)),
        poly(ribbon, ellipse_pts(0.25, -0.64, 0.26, 0.14, 0.45)),
        circle(ribbon, 0, -0.56, 0.11),
    ]


def _leaf(cx: float, cy: float, length: float, width: float, angle: float, c: str) -> list[Shape]:
    n = 9
    top, bottom = [], []
    for i in range(n):
        x = -1 + 2 * i / (n - 1)
        h = width * max(0.0, 1 - x * x) ** 0.6 * (1.35 if i % 2 else 1.0)
        top.append((x, -h))
        bottom.append((x, h))
    pts = top + bottom[::-1][1:-1]
    ca, sa = math.cos(angle), math.sin(angle)

    def at(p):
        return (cx + length * (p[0] * ca - p[1] * sa), cy + length * (p[0] * sa + p[1] * ca))
    return [poly(c, [at(p) for p in pts]), stroke("#0B4A2A", [at((-0.9, 0)), at((0.9, 0))], 0.04)]


def holly() -> list[Shape]:
    return (_leaf(-0.42, 0.1, 0.55, 0.42, 0.45, "#1E8449") + _leaf(0.42, 0.1, 0.55, 0.42, -0.45, "#239B56")
            + _leaf(0.0, 0.48, 0.5, 0.4, math.pi / 2, "#1A7A43")
            + [circle("#D7263D", -0.14, -0.08, 0.15), circle("#C81D33", 0.15, -0.06, 0.15),
               circle("#E03145", 0.0, -0.3, 0.15), circle("#FFFFFF80", -0.18, -0.13, 0.04),
               circle("#FFFFFF80", 0.11, -0.11, 0.04), circle("#FFFFFF80", -0.04, -0.35, 0.04)])


def gingerbread() -> list[Shape]:
    body, icing = "#C27C3E", "#FFFFFF"
    return [
        poly(body, ellipse_pts(-0.46, -0.1, 0.3, 0.13, -0.35)),
        poly(body, ellipse_pts(0.46, -0.1, 0.3, 0.13, 0.35)),
        poly(body, ellipse_pts(-0.22, 0.6, 0.14, 0.33, 0.35)),
        poly(body, ellipse_pts(0.22, 0.6, 0.14, 0.33, -0.35)),
        poly(body, ellipse_pts(0, 0.1, 0.36, 0.45)),
        circle(body, 0, -0.58, 0.31),
        circle(icing, -0.11, -0.64, 0.045), circle(icing, 0.11, -0.64, 0.045),
        stroke(icing, arc_pts(0, -0.6, 0.14, 0.4, math.pi - 0.4, 8), 0.04),
        circle("#E63946", 0, -0.08, 0.06), circle("#2E9E5B", 0, 0.12, 0.06), circle("#E63946", 0, 0.32, 0.06),
        stroke(icing, [(-0.66, -0.22), (-0.62, -0.06), (-0.58, -0.2), (-0.54, -0.04)], 0.035),
        stroke(icing, [(0.66, -0.22), (0.62, -0.06), (0.58, -0.2), (0.54, -0.04)], 0.035),
        stroke(icing, [(-0.36, 0.84), (-0.3, 0.74), (-0.22, 0.84)], 0.035),
        stroke(icing, [(0.36, 0.84), (0.3, 0.74), (0.22, 0.84)], 0.035),
    ]


def santa() -> list[Shape]:
    white = "#F8F8F8"
    return [
        poly(white, ellipse_pts(0, 0.3, 0.56, 0.52)),
        circle("#F6CBA5", 0, 0.0, 0.38),
        circle("#F28B8299", -0.2, 0.09, 0.09), circle("#F28B8299", 0.2, 0.09, 0.09),
        circle("#2B2B2B", -0.13, -0.05, 0.045), circle("#2B2B2B", 0.13, -0.05, 0.045),
        circle("#E88A7A", 0, 0.08, 0.08),
        poly(white, ellipse_pts(-0.14, 0.2, 0.17, 0.08, 0.25)),
        poly(white, ellipse_pts(0.14, 0.2, 0.17, 0.08, -0.25)),
        poly("#D62828", [(-0.48, -0.22), (-0.32, -0.62), (0.02, -0.9), (0.42, -0.86), (0.7, -0.56), (0.5, -0.46),
                         (0.42, -0.22)]),
        poly(white, rect_pts(-0.56, -0.36, 0.56, -0.14, 0.1)),
        circle(white, 0.7, -0.52, 0.14),
    ]


# ----------------------------------------------------------------------------- the patterns

@dataclass
class Pattern:
    key: str
    title: str
    size: float                       # the tile's side, in points
    opacity: float                    # how strongly the whole pattern shows
    shapes: list[Shape]               # in the tile's unit square (a little past its edges: the wrapped copies)


def _place(motif: list[Shape], x: float, y: float, s: float, a: float) -> list[Shape]:
    ca, sa = math.cos(a), math.sin(a)

    def at(px, py):
        return (x + s * (px * ca - py * sa), y + s * (px * sa + py * ca))
    out: list[Shape] = []
    for sh in motif:
        kind, color, v = sh[0], sh[1], sh[2]
        if kind == "circle":
            cx, cy = at(v[0], v[1])
            out.append(("circle", color, [cx, cy, v[2] * s]))
        else:
            pts = [at(v[i], v[i + 1]) for i in range(0, len(v), 2)]
            flat = [c for p in pts for c in p]
            out.append(("poly", color, flat) if kind == "poly" else ("stroke", color, flat, sh[3] * s, sh[4] * s))
    return out


def _wrapped(motif: list[Shape], x: float, y: float, s: float, a: float) -> list[Shape]:
    """The motif placed, and again across each edge it crosses (so the tiles meet without a seam)."""
    reach = s * 1.15
    xs = [0.0] + ([1.0] if x - reach < 0 else []) + ([-1.0] if x + reach > 1 else [])
    ys = [0.0] + ([1.0] if y - reach < 0 else []) + ([-1.0] if y + reach > 1 else [])
    out: list[Shape] = []
    for dx in xs:
        for dy in ys:
            out += _place(motif, x + dx, y + dy, s, a)
    return out


def _scatter(seed: int, cells: int, picks: list[tuple[list[Shape], float]], tilt: float,
             fill: list[tuple[list[Shape], float]] | None = None) -> list[Shape]:
    """Motifs on a jittered grid (`cells` × `cells`), each cell's from `picks` in turn at about its size, turned up
    to `tilt`; `fill` — small ones (snowflakes, sparkles) in the gaps between."""
    rnd = random.Random(seed)
    out: list[Shape] = []
    step = 1.0 / cells
    k = 0
    for row in range(cells):
        for col in range(cells):
            motif, size = picks[k % len(picks)]
            k += 1
            x = (col + 0.5 + (0.5 if row % 2 else 0.0)) * step + rnd.uniform(-0.12, 0.12) * step
            y = (row + 0.5) * step + rnd.uniform(-0.12, 0.12) * step
            out += _wrapped(motif, x % 1.0, y, size * rnd.uniform(0.88, 1.1), rnd.uniform(-tilt, tilt))
    for i, (motif, size) in enumerate(fill or []):
        x = ((i % cells) + 0.05 + rnd.uniform(0, 0.2)) * step
        y = ((i // cells) % cells + 0.02 + rnd.uniform(0, 0.15)) * step
        out += _wrapped(motif, x, y, size * rnd.uniform(0.8, 1.15), rnd.uniform(-0.6, 0.6))
    return out


def _r(v: float) -> float:
    return round(v, 4)


def patterns() -> list[Pattern]:
    flakes = lambda c, n, s: [(snowflake(c), s)] * n                                  # noqa: E731
    out = [
        Pattern("snowflakes", "Snowflakes", 230, 0.30,
                _scatter(11, 3, [(snowflake("#FFFFFF"), 0.09), (snowflake("#DDEEFF"), 0.06), (snowflake("#FFFFFF"), 0.075)],
                         0.5, flakes("#FFFFFF", 6, 0.03))),
        Pattern("snowflakesBlue", "Blue Snowflakes", 230, 0.42,
                _scatter(12, 3, [(snowflake("#5B8DD6"), 0.09), (snowflake("#8DB4EA"), 0.06), (snowflake("#5B8DD6"), 0.075)],
                         0.5, flakes("#8DB4EA", 6, 0.03))),
        Pattern("santa", "Santa", 280, 0.34,
                _scatter(21, 2, [(santa(), 0.17), (santa(), 0.15)], 0.25, flakes("#FFFFFF", 4, 0.035))),
        Pattern("candyCanes", "Candy Canes", 220, 0.42,
                _scatter(31, 3, [(candy_cane(), 0.11)], 0.6)),
        Pattern("trees", "Christmas Trees", 240, 0.34,
                _scatter(41, 3, [(tree(), 0.12), (tree(), 0.1)], 0.1, [(sparkle("#FFE08A"), 0.03)] * 6)),
        Pattern("ornaments", "Ornaments", 230, 0.32,
                _scatter(51, 3, [(ornament("#D62828"), 0.085), (ornament("#E9B949"), 0.08), (ornament("#2A9D8F"), 0.08),
                                 (ornament("#4361EE"), 0.08)], 0.35)),
        Pattern("presents", "Presents", 240, 0.32,
                _scatter(61, 3, [(present("#D62828", "#FFD166"), 0.09), (present("#2A9D8F", "#F1FAEE"), 0.085),
                                 (present("#5E60CE", "#FFB3C6"), 0.08), (present("#E9B949", "#D62828"), 0.085)], 0.3)),
        Pattern("holly", "Holly", 220, 0.36,
                _scatter(71, 3, [(holly(), 0.1)], 0.8)),
        Pattern("gingerbread", "Gingerbread", 240, 0.36,
                _scatter(81, 3, [(gingerbread(), 0.1)], 0.3, flakes("#FFFFFF", 4, 0.03))),
        Pattern("stars", "Stars", 220, 0.34,
                _scatter(91, 3, [(star("#FFE08A"), 0.05), (star("#FFFFFF"), 0.035), (sparkle("#FFE08A"), 0.04)], 0.6,
                         [(sparkle("#FFFFFF"), 0.02)] * 6)),
    ]
    for p in out:
        p.shapes = [tuple([sh[0], sh[1], [_r(v) for v in sh[2]]] + [_r(x) for x in sh[3:]]) for sh in p.shapes]
    return out


_CACHE: dict[str, Pattern] = {}


def pattern(key: str) -> Pattern | None:
    if not _CACHE:
        for p in patterns():
            _CACHE[p.key] = p
    return _CACHE.get(key or "")


def choices() -> list[tuple[str, str]]:
    """(key, title) of every wallpaper, for a menu — "" is none."""
    return [("", "None")] + [(p.key, p.title) for p in patterns()]


def colors(key: str) -> list[str]:
    """The pattern's colours (#RRGGBB, alpha dropped), most used first."""
    p = pattern(key)
    if p is None:
        return []
    count: dict[str, int] = {}
    for sh in p.shapes:
        c = sh[1][:7].upper()
        count[c] = count.get(c, 0) + 1
    return sorted(count, key=lambda c: -count[c])


def grounds(key: str, under: str) -> list[str]:
    """What text may find under it where the pattern is: each of its colours over `under` (a background colour),
    at the pattern's strength — the motifs are small and sparse, so at 60 % of it."""
    import themes
    p = pattern(key)
    return [themes.mix(under, c, p.opacity * 0.6) for c in colors(key)] if p else []


# ----------------------------------------------------------------------------- drawing it with Qt

def _qcolor(c: str):
    from PySide6.QtGui import QColor
    q = QColor(c[:7])
    if len(c) == 9:
        q.setAlpha(int(c[7:9], 16))
    return q


def paint_tile(painter, key: str, side: float) -> None:
    """The pattern's shapes onto `painter`, in a `side`×`side` square from its origin (full strength — the caller
    sets the opacity)."""
    from PySide6.QtCore import QPointF, Qt
    from PySide6.QtGui import QBrush, QPainterPath, QPen, QPolygonF
    p = pattern(key)
    if p is None:
        return
    painter.save()
    painter.setRenderHint(painter.RenderHint.Antialiasing)
    painter.scale(side, side)
    for sh in p.shapes:
        kind, color, v = sh[0], sh[1], sh[2]
        q = _qcolor(color)
        if kind == "circle":
            painter.setPen(Qt.PenStyle.NoPen)
            painter.setBrush(QBrush(q))
            painter.drawEllipse(QPointF(v[0], v[1]), v[2], v[2])
        elif kind == "poly":
            painter.setPen(Qt.PenStyle.NoPen)
            painter.setBrush(QBrush(q))
            painter.drawPolygon(QPolygonF([QPointF(v[i], v[i + 1]) for i in range(0, len(v), 2)]))
        else:
            width, dash = sh[3], sh[4]
            pen = QPen(q, width)
            pen.setJoinStyle(Qt.PenJoinStyle.RoundJoin)
            pen.setCapStyle(Qt.PenCapStyle.FlatCap if dash else Qt.PenCapStyle.RoundCap)
            if dash:
                pen.setDashPattern([dash / width, dash / width])      # Qt counts dashes in pen widths
            painter.setPen(pen)
            painter.setBrush(Qt.BrushStyle.NoBrush)
            path = QPainterPath(QPointF(v[0], v[1]))
            for i in range(2, len(v), 2):
                path.lineTo(QPointF(v[i], v[i + 1]))
            painter.drawPath(path)
    painter.restore()


_PIXMAPS: dict[tuple[str, float], object] = {}


def tile_pixmap(key: str, dpr: float = 1.0, scale: float = 1.0):
    """The tile as a pixmap at the screen's pixel ratio, already at the pattern's strength (None: no pattern)."""
    from PySide6.QtCore import Qt
    from PySide6.QtGui import QPainter, QPixmap
    p = pattern(key)
    if p is None:
        return None
    k = (key, round(dpr, 2), round(scale, 3))
    if k not in _PIXMAPS:
        side = p.size * scale
        n = max(1, int(round(side * dpr)))
        whole = QPixmap(n, n)                      # drawn at full strength first, then faded as one layer — faded
        whole.setDevicePixelRatio(dpr)             # shape by shape, Santa's beard would show through his face
        whole.fill(Qt.GlobalColor.transparent)
        painter = QPainter(whole)
        paint_tile(painter, key, side)
        painter.end()
        px = QPixmap(n, n)
        px.setDevicePixelRatio(dpr)
        px.fill(Qt.GlobalColor.transparent)
        painter = QPainter(px)
        painter.setOpacity(p.opacity)
        painter.drawPixmap(0, 0, whole)
        painter.end()
        _PIXMAPS[k] = px
    return _PIXMAPS[k]


def paint(painter, rect, key: str, scale: float = 1.0) -> None:
    """`rect` tiled with the pattern (fixed to `rect`'s corner)."""
    from PySide6.QtCore import QPointF
    px = tile_pixmap(key, painter.device().devicePixelRatioF() if painter.device() else 1.0, scale)
    if px is not None:
        painter.drawTiledPixmap(rect, px, QPointF(0, 0))


# ----------------------------------------------------------------------------- the iPhone's copy

SWIFT = "PhotoBrowser/Wallpapers.swift"


def swift_source() -> str:
    data = [{"key": p.key, "title": p.title, "size": p.size, "opacity": p.opacity,
             "shapes": [[{"poly": 0, "circle": 1, "stroke": 2}[sh[0]], sh[1], sh[2]] + list(sh[3:]) for sh in p.shapes]}
            for p in patterns()]
    blob = json.dumps(data, separators=(",", ":"))
    return f'''import SwiftUI

/// Theme wallpapers — the patterns a theme can lay over its background (`AppTheme.wallpaper`): Santa, snowflakes,
/// candy canes, Christmas trees, ornaments, presents, holly, gingerbread men, stars.
///
/// **Generated by `python3 mac/wallpapers.py --swift` — don't edit by hand.** The drawings are made once, in
/// `mac/wallpapers.py`, and Photo Browser for Mac paints the same shapes, so the two apps' wallpapers match. Each
/// pattern is a square tile of shapes in its own unit square — kind 0 a filled polygon `[x, y, …]`, 1 a filled
/// circle `[cx, cy, r]`, 2 a stroke `[x, y, …]` with a width and a dash (0: solid, round caps) — drawn tile after
/// tile across the screen at the pattern's opacity (`WallpaperView`). Kept as JSON text, read once: a literal of
/// thousands of numbers would cost the compiler minutes.
nonisolated enum Wallpapers {{
    struct Shape: Sendable {{
        let kind: Int
        let color: Color
        let values: [Double]
        let width: Double
        let dash: Double
    }}

    struct Tile: Sendable {{
        let key: String
        let title: String
        let size: Double
        let opacity: Double
        let shapes: [Shape]
    }}

    /// Every pattern, in the order the pickers list them.
    static let all: [Tile] = parse()

    static func tile(_ key: String?) -> Tile? {{
        guard let key, !key.isEmpty else {{ return nil }}
        return all.first {{ $0.key == key }}
    }}

    private static func color(_ hex: String) -> Color {{
        var s = hex
        if s.hasPrefix("#") {{ s.removeFirst() }}
        let v = UInt64(s, radix: 16) ?? 0
        let alpha = s.count == 8 ? Double(v & 0xFF) / 255 : 1
        let rgb = s.count == 8 ? v >> 8 : v
        return Color(.sRGB, red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255,
                     blue: Double(rgb & 0xFF) / 255, opacity: alpha)
    }}

    private static func parse() -> [Tile] {{
        guard let data = json.data(using: .utf8),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {{ return [] }}
        return list.compactMap {{ item in
            guard let key = item["key"] as? String, let title = item["title"] as? String,
                  let size = (item["size"] as? NSNumber)?.doubleValue,
                  let opacity = (item["opacity"] as? NSNumber)?.doubleValue,
                  let raw = item["shapes"] as? [[Any]] else {{ return nil }}
            let shapes: [Shape] = raw.compactMap {{ s in
                guard s.count >= 3, let kind = (s[0] as? NSNumber)?.intValue, let hex = s[1] as? String,
                      let values = (s[2] as? [NSNumber])?.map(\\.doubleValue) else {{ return nil }}
                let width = s.count > 3 ? (s[3] as? NSNumber)?.doubleValue ?? 0 : 0
                let dash = s.count > 4 ? (s[4] as? NSNumber)?.doubleValue ?? 0 : 0
                return Shape(kind: kind, color: color(hex), values: values, width: width, dash: dash)
            }}
            return Tile(key: key, title: title, size: size, opacity: opacity, shapes: shapes)
        }}
    }}

    /// One tile's shapes into `context`, already moved and scaled to the tile's square.
    static func draw(_ tile: Tile, in context: inout GraphicsContext) {{
        for s in tile.shapes {{
            let v = s.values
            switch s.kind {{
            case 1 where v.count >= 3:
                context.fill(Path(ellipseIn: CGRect(x: v[0] - v[2], y: v[1] - v[2], width: v[2] * 2, height: v[2] * 2)),
                             with: .color(s.color))
            case 0, 2:
                var path = Path()
                guard v.count >= 4 else {{ continue }}
                path.move(to: CGPoint(x: v[0], y: v[1]))
                var i = 2
                while i + 1 < v.count {{
                    path.addLine(to: CGPoint(x: v[i], y: v[i + 1]))
                    i += 2
                }}
                if s.kind == 0 {{
                    path.closeSubpath()
                    context.fill(path, with: .color(s.color))
                }} else {{
                    let style = StrokeStyle(lineWidth: s.width, lineCap: s.dash > 0 ? .butt : .round, lineJoin: .round,
                                            dash: s.dash > 0 ? [s.dash, s.dash] : [])
                    context.stroke(path, with: .color(s.color), style: style)
                }}
            default:
                continue
            }}
        }}
    }}

    private static let json = ##"{blob}"##     // (## — the JSON's colours hold "#)
}}

/// A wallpaper laid across the space it's given, tile after tile from the top left, behind everything (it takes no
/// touches). The whole pattern fades together (`.opacity` on the layer, not on each shape).
struct WallpaperView: View {{
    let key: String

    var body: some View {{
        if let tile = Wallpapers.tile(key) {{
            Canvas {{ context, size in
                let side = tile.size
                var y = 0.0
                while y < size.height {{
                    var x = 0.0
                    while x < size.width {{
                        var c = context
                        c.clip(to: Path(CGRect(x: x, y: y, width: side, height: side)))
                        c.translateBy(x: x, y: y)
                        c.scaleBy(x: side, y: side)
                        Wallpapers.draw(tile, in: &c)
                        x += side
                    }}
                    y += side
                }}
            }}
            .opacity(tile.opacity)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }}
    }}
}}
'''


def main() -> None:
    if "--swift" in sys.argv:
        import os
        root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        path = os.path.join(root, SWIFT)
        with open(path, "w", encoding="utf-8") as f:
            f.write(swift_source())
        print(f"wrote {path}")
        return
    for p in patterns():
        print(f"{p.key:16s} {p.title:18s} {len(p.shapes):4d} shapes")


if __name__ == "__main__":
    main()
