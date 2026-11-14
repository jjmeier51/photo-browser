"""View ▸ Theme… — Safe Finder's look, chosen the way the iPhone app's Settings ▸ Appearance chooses its own:
"Match macOS" (the Finder look, light or dark with the Mac), the ready-made themes (Everyday, Halloween,
Christmas — the iPhone's, `themes.PRESETS`), or a custom background (one colour or a gradient), accent colour,
typeface and light/dark chrome.

A click shows the theme at once in every Safe Finder window; Revert puts back the one that was on when the
window opened. `apply(look)` is Safe Finder's `set_look` (None = Match macOS).
"""
from __future__ import annotations

from typing import Callable

from PySide6.QtCore import QPointF, QRectF, QSize, Qt, Signal
from PySide6.QtGui import QColor, QFont, QLinearGradient, QPainter, QPainterPath, QPen
from PySide6.QtWidgets import (QAbstractButton, QCheckBox, QColorDialog, QComboBox, QDialog, QGridLayout, QHBoxLayout,
                               QLabel, QPushButton, QVBoxLayout, QWidget)

import themes


def paint_background(p: QPainter, rect: QRectF, colors: list[str], direction: str) -> None:
    if len(colors) == 1:
        p.fillRect(rect, QColor(colors[0]))
        return
    end = {"down": rect.bottomLeft(), "diagonal": rect.bottomRight(), "across": rect.topRight()}.get(direction, rect.bottomLeft())
    g = QLinearGradient(rect.topLeft(), end)
    for i, c in enumerate(colors):
        g.setColorAt(i / (len(colors) - 1), QColor(c))
    p.fillRect(rect, g)


class Swatch(QAbstractButton):
    """One theme: its background, a few tiles in its accent, its name — ticked when it's the one on."""

    def __init__(self, look: themes.Look | None, name: str) -> None:
        super().__init__()
        self.look, self.name = look, name
        self.setCheckable(True)
        self.setCursor(Qt.CursorShape.PointingHandCursor)
        self.setToolTip(name)

    def sizeHint(self) -> QSize:  # noqa: N802
        return QSize(112, 84)

    def paintEvent(self, _event) -> None:  # noqa: N802
        p = QPainter(self)
        p.setRenderHint(QPainter.RenderHint.Antialiasing)
        box = QRectF(self.rect()).adjusted(2, 2, -2, -22)
        clip = QPainterPath()
        clip.addRoundedRect(box, 9, 9)
        p.save()
        p.setClipPath(clip)
        if self.look is None:                              # Match macOS: half light, half dark
            p.fillRect(box, QColor("#F6F6F6"))
            dark = QPainterPath()
            dark.moveTo(box.topRight())
            dark.lineTo(box.bottomRight())
            dark.lineTo(box.bottomLeft())
            dark.closeSubpath()
            p.fillPath(dark, QColor("#1E1E1E"))
            accent, light = "#0A84FF", False
        else:
            paint_background(p, box, self.look.colors, self.look.direction)
            accent, light = self.look.accent, self.look.light
        side = (box.width() - 4 * 7) / 3
        for i in range(3):                                 # a row of "pictures", one of them selected
            tile = QRectF(box.x() + 7 + i * (side + 7), box.y() + 9, side, side * 0.72)
            p.setPen(Qt.PenStyle.NoPen)
            p.setBrush(QColor(0, 0, 0, 38) if light else QColor(255, 255, 255, 40))
            p.drawRoundedRect(tile, 3, 3)
            if i == 1:
                p.setPen(QPen(QColor(accent), 2))
                p.setBrush(Qt.BrushStyle.NoBrush)
                p.drawRoundedRect(tile.adjusted(1, 1, -1, -1), 3, 3)
        pill = QRectF(box.x() + 7, box.bottom() - 15, box.width() * 0.46, 8)
        p.setPen(Qt.PenStyle.NoPen)
        p.setBrush(QColor(accent))
        p.drawRoundedRect(pill, 4, 4)
        p.restore()
        p.setPen(QPen(QColor(accent) if self.isChecked() else QColor(128, 128, 128, 90), 2.2 if self.isChecked() else 1))
        p.setBrush(Qt.BrushStyle.NoBrush)
        p.drawRoundedRect(box, 9, 9)
        if self.isChecked():
            d = 16.0
            ring = QRectF(box.right() - d - 5, box.y() + 5, d, d)
            p.setPen(Qt.PenStyle.NoPen)
            p.setBrush(QColor(accent))
            p.drawEllipse(ring)
            p.setPen(QPen(QColor("#000000" if themes.luminance(accent) > 0.6 else "#FFFFFF"), 1.8, Qt.PenStyle.SolidLine,
                          Qt.PenCapStyle.RoundCap, Qt.PenJoinStyle.RoundJoin))
            p.drawPolyline([QPointF(ring.left() + d * 0.28, ring.top() + d * 0.52),
                            QPointF(ring.left() + d * 0.44, ring.top() + d * 0.68),
                            QPointF(ring.left() + d * 0.74, ring.top() + d * 0.34)])
        f = QFont(self.font())
        f.setPointSizeF(max(8.0, f.pointSizeF() - 1.5))
        p.setFont(f)
        p.setPen(self.palette().color(self.foregroundRole()))
        p.drawText(QRectF(0, self.height() - 20, self.width(), 18), Qt.AlignmentFlag.AlignCenter,
                   p.fontMetrics().elidedText(self.name, Qt.TextElideMode.ElideRight, self.width() - 4))
        p.end()


class ColorButton(QPushButton):
    """A colour well: shows its colour, a click picks another."""
    changed = Signal(str)

    def __init__(self, color: str, title: str) -> None:
        super().__init__()
        self.title = title
        self.setFixedSize(46, 26)
        self.set(color)
        self.clicked.connect(self._pick)

    def set(self, color: str) -> None:
        self.color = color.upper()
        self.setStyleSheet(f"QPushButton {{ background: {self.color}; border: 1px solid rgba(128,128,128,0.6); "
                           "border-radius: 6px; min-height: 0; padding: 0; }")

    def _pick(self) -> None:
        c = QColorDialog.getColor(QColor(self.color), self, self.title)
        if c.isValid():
            self.set(c.name())
            self.changed.emit(self.color)


class ThemeDialog(QDialog):
    def __init__(self, parent, current: themes.Look | None, apply: Callable[[themes.Look | None], None]) -> None:
        super().__init__(parent)
        self.setWindowTitle("Theme")
        self.apply, self.opened_with = apply, current
        self.swatches: list[Swatch] = []
        lay = QVBoxLayout(self)
        lay.setContentsMargins(18, 16, 18, 14)
        lay.setSpacing(8)

        def section(title: str, looks: list[tuple[themes.Look | None, str]]) -> None:
            lay.addWidget(QLabel(title, objectName="SheetSub"))
            grid = QGridLayout()
            grid.setSpacing(8)
            for i, (look, name) in enumerate(looks):
                sw = Swatch(look, name)
                sw.clicked.connect(lambda _=False, sw=sw: self._choose(sw.look))
                self.swatches.append(sw)
                grid.addWidget(sw, i // 6, i % 6)
            grid.setColumnStretch(6, 1)
            lay.addLayout(grid)

        section("Finder", [(None, "Match macOS")])
        for name, looks in themes.groups():
            section(name, [(look, look.name) for look in looks])

        lay.addSpacing(4)
        lay.addWidget(QLabel("Custom", objectName="SheetSub"))
        base = current or themes.PRESETS[0]
        row = QHBoxLayout()
        row.setSpacing(8)
        self.c1 = ColorButton(base.colors[0], "Background")
        self.gradient = QCheckBox("Gradient to")
        self.gradient.setChecked(len(base.colors) > 1)
        self.c2 = ColorButton(base.colors[-1] if len(base.colors) > 1 else themes.mix(base.colors[0], "#000000", 0.6),
                              "Background, the other end")
        self.direction = QComboBox()
        for key, title in themes.DIRECTIONS.items():
            self.direction.addItem(title, key)
        self.direction.setCurrentIndex(max(0, self.direction.findData(base.direction)))
        self.accent = ColorButton(base.accent, "Accent")
        self.typeface = QComboBox()
        for key, (title, _families) in themes.TYPEFACES.items():
            self.typeface.addItem(title, key)
        self.typeface.setCurrentIndex(max(0, self.typeface.findData(base.typeface)))
        self.light = QCheckBox("Light")
        self.light.setChecked(base.light)
        self.light.setToolTip("Dark text on a light background")
        for w in (QLabel("Background"), self.c1, self.gradient, self.c2, self.direction, QLabel("Accent"), self.accent,
                  QLabel("Typeface"), self.typeface, self.light):
            row.addWidget(w)
        row.addStretch(1)
        lay.addLayout(row)
        for signal in (self.c1.changed, self.c2.changed, self.accent.changed):
            signal.connect(lambda _c: self._custom())
        self.gradient.toggled.connect(lambda _on: self._custom())
        self.light.toggled.connect(lambda _on: self._custom())
        self.direction.activated.connect(lambda _i: self._custom())
        self.typeface.activated.connect(lambda _i: self._custom())

        buttons = QHBoxLayout()
        revert = QPushButton("Revert")
        revert.setToolTip("Back to the theme that was on when this window opened")
        revert.clicked.connect(lambda: self._choose(self.opened_with))
        done = QPushButton("Done", objectName="Primary")
        done.setDefault(True)
        done.clicked.connect(self.accept)
        buttons.addWidget(revert)
        buttons.addStretch(1)
        buttons.addWidget(done)
        lay.addSpacing(6)
        lay.addLayout(buttons)
        self._mark(current)

    def _mark(self, look: themes.Look | None) -> None:
        for sw in self.swatches:
            sw.setChecked((sw.look is None and look is None)
                          or (sw.look is not None and look is not None and sw.look.same_looks(look)))
        self.c2.setEnabled(self.gradient.isChecked())
        self.direction.setEnabled(self.gradient.isChecked())

    def _show_in_controls(self, look: themes.Look) -> None:
        for w in (self.gradient, self.light, self.direction, self.typeface):
            w.blockSignals(True)
        self.c1.set(look.colors[0])
        self.gradient.setChecked(len(look.colors) > 1)
        if len(look.colors) > 1:
            self.c2.set(look.colors[-1])
        self.direction.setCurrentIndex(max(0, self.direction.findData(look.direction)))
        self.accent.set(look.accent)
        self.typeface.setCurrentIndex(max(0, self.typeface.findData(look.typeface)))
        self.light.setChecked(look.light)
        for w in (self.gradient, self.light, self.direction, self.typeface):
            w.blockSignals(False)

    def _choose(self, look: themes.Look | None) -> None:
        if look is not None:
            self._show_in_controls(look)
        self.apply(look)
        self._mark(look)

    def _custom(self) -> None:
        colors = [self.c1.color] + ([self.c2.color] if self.gradient.isChecked() else [])
        look = themes.Look("Custom", colors, self.accent.color, self.typeface.currentData(), self.light.isChecked(),
                           self.direction.currentData())
        match = next((p for p in themes.PRESETS if p.same_looks(look)), None)
        self.apply(match or look)
        self._mark(look)
