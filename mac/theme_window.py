"""View ▸ Theme… — Photo Browser for Mac's look, chosen the way the iPhone app's Settings ▸ Appearance chooses its own:
"Match macOS" (the Finder look, light or dark with the Mac), the ready-made themes (Everyday, Halloween,
Thanksgiving, Christmas, Holiday — the iPhone's, `themes.PRESETS`), or a custom background (one colour or a
gradient), accent colour, typeface and light/dark chrome.

A click shows the theme at once in every Photo Browser for Mac window; Revert puts back what was on when the window
opened. `apply(look)` is Photo Browser for Mac's `set_look` (None = Match macOS).

The Mac's own extras (`Extras`, all optional so the window still stands alone): **My Themes** — "Save as My
Theme…" keeps the custom look under a name (right-click one to rename or remove it); **Follow the Seasons** —
the holidays' themes by date (`themes.seasonal`), with what December wears; **Surprise Me**.
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Callable

from PySide6.QtCore import QPointF, QRectF, QSize, Qt, Signal
from PySide6.QtGui import QColor, QFont, QLinearGradient, QPainter, QPainterPath, QPen
from PySide6.QtWidgets import (QAbstractButton, QCheckBox, QColorDialog, QComboBox, QDialog, QFrame, QGridLayout,
                               QHBoxLayout, QInputDialog, QLabel, QMenu, QPushButton, QScrollArea, QVBoxLayout,
                               QWidget)

import themes
import wallpapers


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
            if self.look.wallpaper:                        # its pattern, smaller, so a few motifs show
                p.save()
                p.translate(box.topLeft())
                wallpapers.paint(p, QRectF(0, 0, box.width(), box.height()), self.look.wallpaper, 0.42)
                p.restore()
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


@dataclass
class Extras:
    """What Photo Browser for Mac lends the chooser beyond applying a look (see the module doc)."""
    mine: Callable[[], list] | None = None                       # the saved themes
    save: Callable[[str, themes.Look], None] | None = None
    remove: Callable[[str], None] | None = None
    seasonal: Callable[[], bool] | None = None                   # is Follow the Seasons on
    december: Callable[[], str] | None = None
    set_seasonal: Callable[[bool, str | None], None] | None = None
    surprise: Callable[[], themes.Look] | None = None
    chosen: Callable[[], themes.Look | None] | None = None       # the theme chosen by hand (under the season's)
    today: Callable[[], object] | None = None


PER_ROW = 6


class ThemeDialog(QDialog):
    def __init__(self, parent, current: themes.Look | None, apply: Callable[[themes.Look | None], None],
                 extras: Extras | None = None) -> None:
        super().__init__(parent)
        self.setWindowTitle("Theme")
        self.apply, self.extras = apply, extras or Extras()
        self.current = current
        self.opened_with = self.extras.chosen() if self.extras.chosen else current
        self.opened_seasonal = bool(self.extras.seasonal()) if self.extras.seasonal else False
        self.swatches: list[Swatch] = []
        lay = QVBoxLayout(self)
        lay.setContentsMargins(18, 16, 18, 14)
        lay.setSpacing(8)

        # Follow the Seasons
        self.seasons = QCheckBox("Follow the Seasons")
        self.seasons.setToolTip("Through the holidays — Halloween, Thanksgiving, Christmas and the New Year — the "
                                "window wears that season's themes, a different one each day. The rest of the year "
                                "it shows the theme chosen here.")
        self.december = QComboBox()
        for key, title in themes.DECEMBER.items():
            self.december.addItem(title, key)
        self.december.setToolTip("What the weeks from Thanksgiving to Christmas Day wear")
        self.season_note = QLabel("", objectName="SheetSub")
        if self.extras.set_seasonal is not None:
            row = QHBoxLayout()
            row.setSpacing(8)
            self.seasons.setChecked(self.opened_seasonal)
            self.december.setCurrentIndex(max(0, self.december.findData(self.extras.december() if self.extras.december
                                                                         else "both")))
            row.addWidget(self.seasons)
            row.addWidget(QLabel("In December:"))
            row.addWidget(self.december)
            row.addWidget(self.season_note, 1)
            lay.addLayout(row)
            self.seasons.toggled.connect(lambda _on: self._seasonal_changed())
            self.december.activated.connect(lambda _i: self._seasonal_changed())

        # The themes, in a list that scrolls (five sets and one's own are more than a window's height).
        self.scroll = QScrollArea()
        self.scroll.setWidgetResizable(True)
        self.scroll.setFrameShape(QFrame.Shape.NoFrame)
        self.scroll.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        self.scroll.setMinimumSize(PER_ROW * 120 + 26, 380)
        lay.addWidget(self.scroll, 1)

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
        self.wallpaper = QComboBox()
        for key, title in wallpapers.choices():
            self.wallpaper.addItem(title, key)
        self.wallpaper.setCurrentIndex(max(0, self.wallpaper.findData(base.wallpaper)))
        self.wallpaper.setToolTip("A pattern over the background, behind the files — the iPhone app has the same ones")
        for w in (QLabel("Background"), self.c1, self.gradient, self.c2, self.direction, QLabel("Accent"), self.accent):
            row.addWidget(w)
        row.addStretch(1)
        lay.addLayout(row)
        row = QHBoxLayout()
        row.setSpacing(8)
        for w in (QLabel("Typeface"), self.typeface, QLabel("Wallpaper"), self.wallpaper, self.light):
            row.addWidget(w)
        row.addStretch(1)
        lay.addLayout(row)
        for signal in (self.c1.changed, self.c2.changed, self.accent.changed):
            signal.connect(lambda _c: self._custom())
        self.gradient.toggled.connect(lambda _on: self._custom())
        self.light.toggled.connect(lambda _on: self._custom())
        self.direction.activated.connect(lambda _i: self._custom())
        self.typeface.activated.connect(lambda _i: self._custom())
        self.wallpaper.activated.connect(lambda _i: self._custom())

        buttons = QHBoxLayout()
        revert = QPushButton("Revert")
        revert.setToolTip("Back to what was on when this window opened")
        revert.clicked.connect(self._revert)
        buttons.addWidget(revert)
        if self.extras.surprise is not None:
            surprise = QPushButton("Surprise Me")
            surprise.setToolTip("A ready-made theme, picked for you")
            surprise.clicked.connect(lambda: self._choose(self.extras.surprise(), show=True))
            buttons.addWidget(surprise)
        self.keep = QPushButton("Save as My Theme…")
        self.keep.setToolTip("Keeps the look that's on now under a name, in My Themes")
        self.keep.clicked.connect(self._save_mine)
        self.keep.setVisible(self.extras.save is not None)
        buttons.addWidget(self.keep)
        buttons.addStretch(1)
        done = QPushButton("Done", objectName="Primary")
        done.setDefault(True)
        done.clicked.connect(self.accept)
        buttons.addWidget(done)
        lay.addSpacing(6)
        lay.addLayout(buttons)
        self._fill()
        self._mark(current)
        self._season_text()

    # ------------------------------------------------------------------------- the swatches

    def _in_season(self) -> list[str]:
        if self.extras.today is None:
            return []
        return themes.season(self.extras.today(), self.december.currentData() or "both")

    def _fill(self) -> None:
        """Every swatch, by set — made again when My Themes changes."""
        self.swatches = []
        body = QWidget()
        col = QVBoxLayout(body)
        col.setContentsMargins(0, 0, 8, 0)
        col.setSpacing(8)
        in_season = self._in_season()

        def section(title: str, looks: list[tuple[themes.Look | None, str]], mine: bool = False) -> None:
            col.addWidget(QLabel(title, objectName="SheetSub"))
            grid = QGridLayout()
            grid.setSpacing(8)
            for i, (look, name) in enumerate(looks):
                sw = Swatch(look, name)
                sw.clicked.connect(lambda _=False, sw=sw: self._choose(sw.look))
                if mine:
                    sw.setContextMenuPolicy(Qt.ContextMenuPolicy.CustomContextMenu)
                    sw.customContextMenuRequested.connect(lambda pos, sw=sw: self._mine_menu(sw, pos))
                    sw.setToolTip(f"{name} — right-click to rename or remove")
                self.swatches.append(sw)
                grid.addWidget(sw, i // PER_ROW, i % PER_ROW)
            grid.setColumnStretch(PER_ROW, 1)
            col.addLayout(grid)

        section("Finder", [(None, "Match macOS")])
        mine = self.extras.mine() if self.extras.mine else []
        if mine:
            section(themes.MINE, [(look, look.name) for look in mine], mine=True)
        for name, looks in themes.groups():
            section(f"{name} — in season" if name in in_season else name, [(look, look.name) for look in looks])
        col.addStretch(1)
        self.scroll.setWidget(body)

    def _mine_menu(self, sw: Swatch, pos) -> None:
        menu = QMenu(self)
        rename = menu.addAction("Rename…")
        remove = menu.addAction(f"Remove “{sw.name}”")
        chosen = menu.exec(sw.mapToGlobal(pos))
        if chosen is rename and self.extras.save is not None and self.extras.remove is not None:
            name, ok = QInputDialog.getText(self, "Rename Theme", "Name:", text=sw.name)
            name = " ".join(name.split())
            if ok and name and name != sw.name:
                self.extras.remove(sw.name)
                self.extras.save(name, sw.look)
        elif chosen is remove and self.extras.remove is not None:
            self.extras.remove(sw.name)                    # the look stays on; only its place in the list goes
        else:
            return
        self._fill()
        self._mark(self.current)

    def _save_mine(self) -> None:
        look = self.current or self._from_controls()
        taken = {m.name for m in (self.extras.mine() if self.extras.mine else [])}
        suggestion = look.name if look.name not in ("Custom", "") and themes.preset(look.name) is None else "My Theme"
        n = 2
        base = suggestion
        while suggestion in taken:
            suggestion = f"{base} {n}"
            n += 1
        name, ok = QInputDialog.getText(self, "Save as My Theme", "Name for this theme:", text=suggestion)
        name = " ".join(name.split())
        if not ok or not name:
            return
        self.extras.save(name, look)                       # a name already there is replaced
        self._fill()
        self._mark(self.current)

    def _mark(self, look: themes.Look | None) -> None:
        self.current = look
        first = None
        for sw in self.swatches:
            on = ((sw.look is None and look is None)
                  or (sw.look is not None and look is not None and sw.look.same_looks(look)))
            sw.setChecked(on)
            first = first or (sw if on else None)
        self.c2.setEnabled(self.gradient.isChecked())
        self.direction.setEnabled(self.gradient.isChecked())
        self.keep.setEnabled(look is not None)
        return first

    def _show_in_controls(self, look: themes.Look) -> None:
        for w in (self.gradient, self.light, self.direction, self.typeface, self.wallpaper):
            w.blockSignals(True)
        self.c1.set(look.colors[0])
        self.gradient.setChecked(len(look.colors) > 1)
        if len(look.colors) > 1:
            self.c2.set(look.colors[-1])
        self.direction.setCurrentIndex(max(0, self.direction.findData(look.direction)))
        self.accent.set(look.accent)
        self.typeface.setCurrentIndex(max(0, self.typeface.findData(look.typeface)))
        self.light.setChecked(look.light)
        self.wallpaper.setCurrentIndex(max(0, self.wallpaper.findData(look.wallpaper)))
        for w in (self.gradient, self.light, self.direction, self.typeface, self.wallpaper):
            w.blockSignals(False)

    def _choose(self, look: themes.Look | None, show: bool = False) -> None:
        """A theme chosen by hand: it goes on, and Follow the Seasons goes off (`set_look` does the same)."""
        if look is not None:
            self._show_in_controls(look)
        self.apply(look)
        self.seasons.blockSignals(True)
        self.seasons.setChecked(False)
        self.seasons.blockSignals(False)
        on = self._mark(look)
        if show and on is not None:
            self.scroll.ensureWidgetVisible(on)
        self._season_text()

    def _from_controls(self) -> themes.Look:
        colors = [self.c1.color] + ([self.c2.color] if self.gradient.isChecked() else [])
        return themes.Look("Custom", colors, self.accent.color, self.typeface.currentData(), self.light.isChecked(),
                           self.direction.currentData(), wallpaper=self.wallpaper.currentData() or "")

    def _custom(self) -> None:
        look = self._from_controls()
        known = themes.PRESETS + (self.extras.mine() if self.extras.mine else [])
        match = next((p for p in known if p.same_looks(look)), None)
        self.apply(match or look)
        self.seasons.blockSignals(True)
        self.seasons.setChecked(False)
        self.seasons.blockSignals(False)
        self._mark(match or look)
        self._season_text()

    # ------------------------------------------------------------------------- the seasons

    def _seasonal_look(self) -> themes.Look | None:
        if self.extras.today is None:
            return None
        return themes.seasonal(self.extras.today(), self.december.currentData() or "both")

    def _season_text(self) -> None:
        names = self._in_season()
        if not names:
            self.season_note.setText("No holiday is in season now — the chosen theme shows.")
        elif self.seasons.isChecked():
            look = self._seasonal_look()
            self.season_note.setText(f"Today: {look.name}." if look is not None else "")
        else:
            self.season_note.setText(f"In season now: {' and '.join(names)}.")

    def _seasonal_changed(self) -> None:
        on = self.seasons.isChecked()
        self.extras.set_seasonal(on, self.december.currentData())
        chosen = self.extras.chosen() if self.extras.chosen else self.current
        look = (self._seasonal_look() if on else None) or chosen
        self._fill()                                       # "in season" follows what December wears
        shown = self._mark(look)
        if shown is not None:
            self.scroll.ensureWidgetVisible(shown)
        self._season_text()

    def _revert(self) -> None:
        self._choose(self.opened_with)
        if self.opened_seasonal and self.extras.set_seasonal is not None:
            self.seasons.setChecked(True)                  # → `_seasonal_changed`
