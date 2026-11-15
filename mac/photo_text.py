"""Text on a photo — the photo editor's layers (photo_editor_window.py) and the collage's captions.

A layer is a plain dict (so it sits in an undo step and in settings as it is): the words, a font, a size as a
fraction of the picture's short side, where its centre is (fractions of the picture), an angle, a colour — and
the styling the phone editors offer: a second colour for a gradient, outline, shadow, glow, a background (box,
rounded, pill, a bar across the picture), letter and line spacing, bold / italic / underline / capitals,
alignment, opacity. `STYLES` are ready-made combinations ("Neon", "Label", "Subtitle"…), `SWATCHES` the colour
row, `fonts()` the Mac's fonts worth offering, by kind.

`paint(painter, layer, w, h)` draws one layer on a w×h picture — the same call for the editor's preview and for
the photo at full size, so what is seen is what is saved. The fill is drawn as text (not as outlines), so emoji
keep their colours: an emoji layer is a sticker. Qt, because the fonts are the Mac's.
"""
from __future__ import annotations

import math

import numpy as np
from PySide6.QtCore import QPointF, QRectF, Qt
from PySide6.QtGui import (QBrush, QColor, QFont, QFontDatabase, QFontMetricsF, QImage, QLinearGradient, QPainter,
                           QPainterPath, QPen, QPolygonF, QTransform)

DEFAULT = {
    "text": "Text", "font": "", "size": 0.09, "x": 0.5, "y": 0.5, "angle": 0.0,
    "colour": "#ffffff", "colour2": "", "opacity": 100,
    "bold": True, "italic": False, "underline": False, "caps": False, "align": "center",
    "spacing": 0, "leading": 100,
    "stroke": 0, "stroke_colour": "#000000",
    "shadow": 0, "shadow_colour": "#000000",
    "glow": 0, "glow_colour": "#ff2d95",
    "back": "", "back_colour": "#000000", "back_opacity": 60,
}

STYLES: list[tuple[str, dict]] = [
    ("Plain", {}),
    ("Outline", {"stroke": 10, "stroke_colour": "#000000"}),
    ("Shadow", {"shadow": 70}),
    ("Neon", {"colour": "#ffffff", "glow": 90, "glow_colour": "#ff2d95", "bold": False}),
    ("Label", {"back": "box", "back_colour": "#000000", "back_opacity": 100}),
    ("Pill", {"back": "pill", "back_colour": "#ffffff", "back_opacity": 100, "colour": "#111111"}),
    ("Subtitle", {"back": "round", "back_colour": "#000000", "back_opacity": 55, "bold": False, "size": 0.05,
                  "y": 0.88}),
    ("Banner", {"back": "bar", "back_colour": "#000000", "back_opacity": 50, "caps": True, "spacing": 12}),
    ("Poster", {"caps": True, "spacing": 6, "stroke": 6, "stroke_colour": "#111111", "shadow": 40, "size": 0.14}),
    ("Sunset", {"colour": "#ffd166", "colour2": "#ef476f", "shadow": 35}),
    ("Ocean", {"colour": "#8ef6e4", "colour2": "#3a86ff", "shadow": 35}),
    ("Comic", {"colour": "#ffe14d", "stroke": 14, "stroke_colour": "#111111", "caps": True, "angle": -6.0}),
    ("Typewriter", {"font": "@mono", "bold": False, "colour": "#111111", "back": "box", "back_colour": "#f5f0e1",
                    "back_opacity": 100}),
    ("Script", {"font": "@script", "bold": False, "shadow": 45, "size": 0.12}),
    ("Stamp", {"caps": True, "colour": "#d62828", "stroke": 0, "spacing": 10, "angle": -12.0, "back": "round",
               "back_colour": "#ffffff", "back_opacity": 85}),
    ("Ghost", {"opacity": 45, "caps": True, "spacing": 20, "bold": False}),
    ("Glow", {"glow": 60, "glow_colour": "#ffffff"}),
    ("Emboss", {"colour": "#f2f2f2", "shadow": 55, "shadow_colour": "#000000", "stroke": 3, "stroke_colour": "#8a8a8a"}),
]

SWATCHES = ["#ffffff", "#000000", "#8e8e93", "#d1d1d6", "#ff3b30", "#ff9500", "#ffcc00", "#34c759", "#00c7be",
            "#30b0c7", "#007aff", "#5856d6", "#af52de", "#ff2d55", "#a2845e", "#ffd6e0", "#ffe5b4", "#fff3b0",
            "#caffbf", "#bde0fe", "#cdb4db", "#f5f0e1", "#6b4f3a", "#1d3557", "#2a9d8f", "#e76f51", "#d62828",
            "#ffd166"]

STICKERS = "❤️ 🔥 ✨ ⭐️ 🌈 ☀️ 🌙 ☁️ 🌸 🌹 🍀 🎉 🎂 🎈 🎁 👑 💎 💋 😍 😂 😎 🥳 😇 🤍 💛 💙 💜 🖤 👍 👏 🙌 ✌️ 📍 ✈️ 🏖 🏔 🎄 🎃 ❄️ 🐾".split()

_KINDS: list[tuple[str, list[str]]] = [
    ("Sans", ["Helvetica Neue", "SF Pro Display", "Avenir Next", "Futura", "Gill Sans", "Optima", "Verdana",
              "Arial", "DejaVu Sans"]),
    ("Serif", ["New York", "Times New Roman", "Georgia", "Baskerville", "Didot", "Bodoni 72", "Palatino", "Hoefler Text",
               "Charter", "DejaVu Serif"]),
    ("Display", ["Impact", "Arial Black", "Avenir Next Condensed", "DIN Condensed", "Copperplate", "Rockwell",
                 "Phosphate", "Bodoni 72 Smallcaps", "Arial Rounded MT Bold"]),
    ("Script", ["Snell Roundhand", "Savoye LET", "Brush Script MT", "Apple Chancery", "Zapfino", "Bradley Hand",
                "Noteworthy", "Marker Felt", "Chalkboard SE", "Party LET", "Comic Sans MS"]),
    ("Mono", ["American Typewriter", "Courier New", "Menlo", "SF Mono", "Monaco", "Andale Mono", "DejaVu Sans Mono"]),
    ("Retro", ["Chalkduster", "Papyrus", "Herculanum", "Trattatello", "Luminari", "SignPainter", "Silom",
               "Bauhaus 93", "Stencil"]),
]
_fonts: list[tuple[str, list[str]]] | None = None


def fonts() -> list[tuple[str, list[str]]]:
    """[(kind, [family…])] — the families above that this Mac has, then "All Fonts" with every one."""
    global _fonts
    if _fonts is None:
        have = {f.casefold(): f for f in QFontDatabase.families()}
        out = []
        for kind, names in _KINDS:
            here = [have[n.casefold()] for n in names if n.casefold() in have]
            if here:
                out.append((kind, here))
        out.append(("All Fonts", sorted(f for f in have.values() if not f.startswith("."))))
        _fonts = out
    return _fonts


def family_for(name: str) -> str:
    """A layer's font as a real family: "" is the first sans, "@script" / "@mono" the first of that kind."""
    kinds = dict(fonts())
    if name.startswith("@"):
        pick = kinds.get({"@script": "Script", "@mono": "Mono", "@serif": "Serif", "@display": "Display"}.get(name, ""))
        return pick[0] if pick else family_for("")
    if name:
        return name
    sans = kinds.get("Sans")
    return sans[0] if sans else QFont().defaultFamily()


def new_layer(**changes) -> dict:
    return {**DEFAULT, **changes}


def styled(layer: dict, style: dict) -> dict:
    """The layer with a ready-made style: everything about looks reset, its words, place and size kept
    (unless the style sets them)."""
    keep = {k: layer[k] for k in ("text", "x", "y", "size", "font", "angle") if k in layer}
    return {**DEFAULT, **keep, **style}


def _font(layer: dict, px: float) -> QFont:
    f = QFont(family_for(str(layer.get("font") or "")))
    f.setPixelSize(max(1, int(round(px))))
    f.setBold(bool(layer.get("bold")))
    f.setItalic(bool(layer.get("italic")))
    f.setUnderline(bool(layer.get("underline")))
    if layer.get("spacing"):
        f.setLetterSpacing(QFont.SpacingType.AbsoluteSpacing, float(layer["spacing"]) / 100.0 * px)
    return f


class _Block:
    """A layer laid out for a w×h picture: its lines and the box they take, centred on the origin."""

    def __init__(self, layer: dict, w: float, h: float) -> None:
        self.px = max(2.0, float(layer.get("size", 0.09)) * min(w, h))
        self.font = _font(layer, self.px)
        fm = QFontMetricsF(self.font)
        text = str(layer.get("text") or "")
        if layer.get("caps"):
            text = text.upper()
        self.lines = text.split("\n") or [""]
        self.widths = [fm.horizontalAdvance(line) for line in self.lines]
        self.ascent, self.height = fm.ascent(), fm.height()
        self.step = self.height * float(layer.get("leading", 100)) / 100.0
        self.w = max(self.widths + [self.px * 0.3])
        self.h = self.step * (len(self.lines) - 1) + self.height
        self.pad_x, self.pad_y = self.px * 0.38, self.px * 0.16
        self.align = str(layer.get("align") or "center")

    def origin(self, i: int) -> QPointF:
        """Where line `i`'s baseline starts."""
        x = {"left": -self.w / 2, "right": self.w / 2 - self.widths[i]}.get(self.align, -self.widths[i] / 2)
        return QPointF(x, -self.h / 2 + i * self.step + self.ascent)

    def path(self) -> QPainterPath:
        p = QPainterPath()
        for i, line in enumerate(self.lines):
            p.addText(self.origin(i), self.font, line)
        return p

    def box(self) -> QRectF:
        return QRectF(-self.w / 2 - self.pad_x, -self.h / 2 - self.pad_y, self.w + 2 * self.pad_x, self.h + 2 * self.pad_y)


def _transform(layer: dict, w: float, h: float) -> QTransform:
    t = QTransform()
    t.translate(float(layer.get("x", 0.5)) * w, float(layer.get("y", 0.5)) * h)
    t.rotate(float(layer.get("angle", 0.0)))
    return t


def outline(layer: dict, w: float, h: float) -> QPolygonF:
    """The layer's box on a w×h picture, turned as it is — for the selection frame and for clicks."""
    return _transform(layer, w, h).map(QPolygonF(_Block(layer, w, h).box()))


def hit(layer: dict, w: float, h: float, x: float, y: float) -> bool:
    return outline(layer, w, h).containsPoint(QPointF(x, y), Qt.FillRule.OddEvenFill)


def _soft(path: QPainterPath, blur: float, colour: QColor, extra: float = 0.0) -> tuple[QImage, QPointF] | None:
    """`path` (grown by `extra`) as a blurred, coloured picture, and where its corner goes."""
    import photo_edit
    r = path.boundingRect()
    if r.isEmpty():
        return None
    m = blur * 3.0 + extra + 2.0
    scale = min(1.0, 900.0 / max(r.width() + 2 * m, r.height() + 2 * m, 1.0))      # a blur needs no more
    iw, ih = max(2, int((r.width() + 2 * m) * scale)), max(2, int((r.height() + 2 * m) * scale))
    mask = QImage(iw, ih, QImage.Format.Format_Grayscale8)
    mask.fill(0)
    p = QPainter(mask)
    p.setRenderHint(QPainter.RenderHint.Antialiasing)
    p.scale(scale, scale)
    p.translate(-r.x() + m, -r.y() + m)
    if extra > 0:
        p.strokePath(path, QPen(QColor(255, 255, 255), extra * 2, Qt.PenStyle.SolidLine, Qt.PenCapStyle.RoundCap,
                                Qt.PenJoinStyle.RoundJoin))
    p.fillPath(path, QColor(255, 255, 255))
    p.end()
    a = np.frombuffer(mask.constBits(), dtype=np.uint8).reshape(ih, mask.bytesPerLine())[:, :iw].astype(np.float32) / 255.0
    a = photo_edit.gauss(a, max(0.3, blur * scale))
    rgba = np.empty((ih, iw, 4), dtype=np.uint8)
    al = np.clip(a * colour.alphaF(), 0.0, 1.0)
    rgba[..., 0] = (colour.blue() * al).astype(np.uint8)            # premultiplied BGRA
    rgba[..., 1] = (colour.green() * al).astype(np.uint8)
    rgba[..., 2] = (colour.red() * al).astype(np.uint8)
    rgba[..., 3] = (al * 255.0).astype(np.uint8)
    img = QImage(rgba.data, iw, ih, iw * 4, QImage.Format.Format_ARGB32_Premultiplied).copy()
    if scale < 1.0:
        img = img.scaled(int(iw / scale), int(ih / scale), Qt.AspectRatioMode.IgnoreAspectRatio,
                         Qt.TransformationMode.SmoothTransformation)
    return img, QPointF(r.x() - m, r.y() - m)


def paint(p: QPainter, layer: dict, w: float, h: float) -> None:
    """Draws the layer on a w×h picture whose top-left is the painter's origin."""
    b = _Block(layer, w, h)
    if not any(line.strip() for line in b.lines):
        return
    p.save()
    p.setRenderHint(QPainter.RenderHint.Antialiasing)
    p.setRenderHint(QPainter.RenderHint.TextAntialiasing)
    p.setRenderHint(QPainter.RenderHint.SmoothPixmapTransform)
    p.setTransform(_transform(layer, w, h), True)
    p.setOpacity(p.opacity() * max(0.0, min(1.0, float(layer.get("opacity", 100)) / 100.0)))

    back = str(layer.get("back") or "")
    if back:
        col = QColor(str(layer.get("back_colour") or "#000000"))
        col.setAlphaF(max(0.0, min(1.0, float(layer.get("back_opacity", 60)) / 100.0)))
        box = b.box()
        p.setPen(Qt.PenStyle.NoPen)
        p.setBrush(col)
        if back == "bar":
            far = 2.0 * max(w, h)
            p.drawRect(QRectF(-far, box.y() - b.pad_y, 2 * far, box.height() + 2 * b.pad_y))
        elif back == "box":
            p.drawRect(box)
        else:
            r = box.height() / 2 if back == "pill" else b.px * 0.22
            p.drawRoundedRect(box.adjusted(-b.px * 0.1, 0, b.px * 0.1, 0) if back == "pill" else box, r, r)

    path = None
    stroke = float(layer.get("stroke", 0) or 0) / 100.0 * b.px
    glow, shadow = float(layer.get("glow", 0) or 0) / 100.0, float(layer.get("shadow", 0) or 0) / 100.0
    if stroke or glow or shadow:
        path = b.path()
    if glow > 0:
        col = QColor(str(layer.get("glow_colour") or "#ffffff"))
        for blur, strength in ((b.px * 0.22, 0.9), (b.px * 0.08, 1.0)):
            col.setAlphaF(min(1.0, glow * strength))
            got = _soft(path, blur, col, stroke + b.px * 0.02)
            if got:
                p.drawImage(got[1], got[0])
    if shadow > 0:
        col = QColor(str(layer.get("shadow_colour") or "#000000"))
        col.setAlphaF(min(1.0, 0.35 + 0.65 * shadow))
        got = _soft(path, b.px * 0.07 * (0.4 + shadow), col, stroke)
        if got:
            off = b.px * 0.05 * (0.5 + shadow)
            back_t = QTransform().rotate(-float(layer.get("angle", 0.0)))          # the shadow falls down the page
            d = back_t.map(QPointF(off * 0.7, off))
            p.drawImage(got[1] + d, got[0])
    if stroke > 0:
        p.strokePath(path, QPen(QColor(str(layer.get("stroke_colour") or "#000000")), stroke * 2,
                                Qt.PenStyle.SolidLine, Qt.PenCapStyle.RoundCap, Qt.PenJoinStyle.RoundJoin))

    c1 = QColor(str(layer.get("colour") or "#ffffff"))
    if layer.get("colour2"):
        grad = QLinearGradient(0, -b.h / 2, 0, b.h / 2)
        grad.setColorAt(0.0, c1)
        grad.setColorAt(1.0, QColor(str(layer["colour2"])))
        p.setPen(QPen(QBrush(grad), 1))
    else:
        p.setPen(c1)
    p.setFont(b.font)
    for i, line in enumerate(b.lines):
        p.drawText(b.origin(i), line)
    p.restore()


def paint_all(image: QImage, layers: list[dict]) -> None:
    """Every layer onto `image`, in order (the last on top)."""
    if not layers:
        return
    p = QPainter(image)
    for layer in layers:
        paint(p, layer, image.width(), image.height())
    p.end()


def onto_array(rgb: np.ndarray, layers: list[dict]) -> np.ndarray:
    """`rgb` (h, w, 3 float32, 0…1) with the layers drawn on it — for saving. Call on the main thread."""
    if not layers:
        return rgb
    h, w = rgb.shape[:2]
    a = np.clip(rgb * 255.0 + 0.5, 0, 255).astype(np.uint8)
    rgba = np.dstack([a, np.full((h, w), 255, dtype=np.uint8)])
    img = QImage(rgba.data, w, h, w * 4, QImage.Format.Format_RGBA8888)
    paint_all(img, layers)
    out = np.frombuffer(img.constBits(), dtype=np.uint8).reshape(h, img.bytesPerLine())[:, :w * 4].reshape(h, w, 4)
    return out[..., :3].astype(np.float32) / 255.0


def angle_to(layer: dict, w: float, h: float, x: float, y: float) -> float:
    """The angle (degrees) from the layer's centre to a point — for the turn handle."""
    return math.degrees(math.atan2(y - float(layer.get("y", 0.5)) * h, x - float(layer.get("x", 0.5)) * w))
