"""Places — where the library's photos and videos were taken: a list by country, region and town, and a map.

Photos' Places, for the drive. The window is made from the place indexes alone (`places.Places.summary`: the
iPhone's on the drive and this Mac's own), so it opens at once however big the library is; **Read Locations…**
reads the photos whose GPS hasn't been read yet, with a count and a Stop.

- **The list** (left): Country ▸ State or region ▸ Town, each with how many photos, most first; the field above
  narrows it as you type. Select one and the map goes there; double-click it (or **Show Photos**) and the main
  window shows those photos — a collection like a tag's, so the viewer, tags, the Trash all work on it.
- **The map** (right) is drawn here, from country outlines that ship with the app (Natural Earth) — no map
  service, no network, nothing about where your photos were taken leaves the Mac. Scroll or pinch to zoom, drag
  to move; photos gather into numbered circles that split as you zoom in; click a circle to select what's under
  it, double-click to zoom into it. Towns are named as you get closer (GeoNames).
- **Refine Place Names with Apple**: off, every name is the nearest town from the app's own table. On (as the
  iPhone does), Apple's geocoder is asked for the names it knows better — neighbourhoods, parks — a place at a
  time; only coordinates are sent.

Web Mercator: x = (λ + 180) / 360, y = (1 − asinh(tan φ) / π) / 2, both 0…1; a screen point is
(x − cx) · 256 · 2^zoom + w / 2. The world repeats sideways, so panning across the date line just works.
"""
from __future__ import annotations

import gzip
import json
import math
import threading
from dataclasses import dataclass
from typing import Callable

from PySide6.QtCore import QObject, QPointF, QRectF, Qt, QTimer, Signal
from PySide6.QtGui import QColor, QFont, QPainter, QPainterPath, QPen
from PySide6.QtWidgets import (QCheckBox, QHBoxLayout, QLabel, QLineEdit, QProgressBar, QPushButton, QSplitter,
                               QToolTip, QTreeWidget, QTreeWidgetItem, QVBoxLayout, QWidget)

import app_identity
import geo_names
import places

MAX_LAT = 85.0511
ARG = Qt.ItemDataRole.UserRole           # a tree item's collection argument ("Paris, France", "@cc:FR", "@region:US.NY")
SPOT = Qt.ItemDataRole.UserRole + 1      # …and (lat, lng, span in degrees) to show it on the map


MOST_BINS = 600                          # spots a circle may gather and still be shown as itself (else: its biggest place)


@dataclass
class PlaceHooks:
    show: Callable[[str], None]                          # open the place (a collection argument) in the main window
    roots: Callable[[], list[str]]                       # the drives connected now
    scan_folder: Callable[[], str] | None = None         # what Read Locations reads (the drive, or the folder shown)


def project(lat: float, lng: float) -> tuple[float, float]:
    lat = max(-MAX_LAT, min(MAX_LAT, lat))
    return (lng + 180.0) / 360.0, (1.0 - math.asinh(math.tan(math.radians(lat))) / math.pi) / 2.0


def unproject(x: float, y: float) -> tuple[float, float]:
    return math.degrees(math.atan(math.sinh(math.pi * (1.0 - 2.0 * y)))), x * 360.0 - 180.0


_world: dict | None = None


def world() -> dict:
    """{"110": [...], "50": [...]} — each country {cc, name, rings} — read once."""
    global _world
    if _world is None:
        try:
            with gzip.open(geo_names.data_folder() / "world.json.gz", "rb") as f:
                _world = json.loads(f.read().decode("utf-8"))
        except (OSError, ValueError):
            _world = {"110": [], "50": []}
    return _world


class MapView(QWidget):
    """The map: outlines, towns, and the photos as numbered circles. `picked(bins)` when a circle is clicked."""
    picked = Signal(list)

    def __init__(self, theme) -> None:
        super().__init__()
        self.theme = theme
        self.cx, self.cy, self.zoom = 0.5, 0.42, 1.2
        self.points: list[tuple[float, float, int, str, str]] = []      # (x, y, photos, label, bin)
        self.selected: set[str] = set()
        self._paths: dict[str, QPainterPath] = {}
        self._clusters: list[dict] = []
        self._drag: QPointF | None = None
        self._moved = False
        self.setMinimumSize(360, 300)
        self.setMouseTracking(True)
        self.setCursor(Qt.CursorShape.OpenHandCursor)
        self.setAccessibleName("Map")

    # -- data
    def set_points(self, summary: list[dict]) -> None:
        pts = []
        for p in summary:
            for b in p["bins"]:
                c = geo_names.bin_centre(b)
                if c is not None:
                    x, y = project(*c)
                    pts.append((x, y, p["per_bin"].get(b, 1), p["label"], b))
        self.points = pts
        self.update()

    def show_all(self) -> None:
        if not self.points:
            self.cx, self.cy, self.zoom = 0.5, 0.42, 1.2
        else:
            self.fit([(x, y) for x, y, *_ in self.points])
        self.update()

    def fit(self, xy: list[tuple[float, float]]) -> None:
        xs, ys = sorted(x for x, _y in xy), [y for _x, y in xy]
        # the smallest span of longitude holding them all: the complement of the biggest gap (the date line)
        gaps = [(xs[i + 1] - xs[i], i) for i in range(len(xs) - 1)] + [(xs[0] + 1 - xs[-1], len(xs) - 1)]
        gap, at = max(gaps)
        left = xs[(at + 1) % len(xs)]
        width = 1.0 - gap
        self.cx = (left + width / 2) % 1.0
        self.cy = (min(ys) + max(ys)) / 2
        span = max(width, (max(ys) - min(ys)) * self.width() / max(1, self.height()), 1e-4)
        self.zoom = max(0.8, min(13.0, math.log2(self.width() * 0.8 / (256 * span))))

    def go(self, lat: float, lng: float, span_degrees: float) -> None:
        self.cx, self.cy = project(lat, lng)
        self.zoom = max(1.0, min(12.0, math.log2(self.width() * 0.8 / (256 * max(span_degrees, 0.02) / 360.0))))
        self.update()

    # -- drawing
    def _scale(self) -> float:
        return 256.0 * (2.0 ** self.zoom)

    def _screen(self, x: float, y: float) -> QPointF:
        dx = (x - self.cx + 0.5) % 1.0 - 0.5            # the nearest copy of the world
        return QPointF(dx * self._scale() + self.width() / 2, (y - self.cy) * self._scale() + self.height() / 2)

    def _outline(self, key: str) -> QPainterPath:
        path = self._paths.get(key)
        if path is None:
            path = QPainterPath()
            for country in world().get(key, []):
                for ring in country["rings"]:
                    first = True
                    prev_x = 0.0
                    for lng, lat in ring:
                        x, y = project(lat, lng)
                        if not first and abs(x - prev_x) > 0.5:      # a shape across the date line: don't draw the jump
                            first = True
                        if first:
                            path.moveTo(x, y)
                            first = False
                        else:
                            path.lineTo(x, y)
                        prev_x = x
                    path.closeSubpath()
            self._paths[key] = path
        return path

    def paintEvent(self, _event) -> None:  # noqa: N802
        t = self.theme
        p = QPainter(self)
        p.setRenderHint(QPainter.RenderHint.Antialiasing)
        dark = t.dark
        water = QColor("#16212B" if dark else "#DCE9F2")
        land = QColor("#2E3A33" if dark else "#F4F1E8")
        line = QColor(255, 255, 255, 46) if dark else QColor(0, 0, 0, 46)
        p.fillRect(self.rect(), water)
        s = self._scale()
        outline = self._outline("110" if self.zoom < 3.2 else "50")
        for copy in (-1, 0, 1):                                    # the world, and its neighbours either side
            p.save()
            p.translate(self.width() / 2 + (copy - self.cx) * s, self.height() / 2 - self.cy * s)
            p.scale(s, s)
            p.setPen(QPen(line, 0))
            p.setBrush(land)
            p.drawPath(outline)
            p.restore()
        self._towns(p)
        self._bubbles(p)
        p.end()

    def _towns(self, p: QPainter) -> None:
        if self.zoom < 2.6 or not geo_names.available():
            return
        min_pop = 3_000_000 if self.zoom < 3.5 else 800_000 if self.zoom < 5 else 150_000 if self.zoom < 6.5 \
            else 30_000 if self.zoom < 8 else 5_000 if self.zoom < 9.5 else 1_000
        import numpy as np
        lats, lngs, names, pops = geo_names.towns(min_pop)
        scale = self._scale()
        lat1, _ = unproject(0.0, self.cy - self.height() / 2 / scale)
        lat0, _ = unproject(0.0, self.cy + self.height() / 2 / scale)
        mid = self.cx * 360.0 - 180.0
        half = min(180.0, self.width() / 2 / scale * 360.0)
        off = (np.asarray(lngs) - mid + 180.0) % 360.0 - 180.0          # degrees east of the middle — across the date line too
        seen = np.nonzero((np.asarray(lats) >= lat0) & (np.asarray(lats) <= lat1) & (np.abs(off) <= half))[0]
        seen = seen[np.argsort(-np.asarray(pops)[seen], kind="stable")][:400]     # the biggest first: they get the room
        f = QFont(self.font())
        f.setPointSizeF(max(8.0, f.pointSizeF() - 2))
        p.setFont(f)
        fm = p.fontMetrics()
        ink = QColor(255, 255, 255, 150) if self.theme.dark else QColor(0, 0, 0, 150)
        taken: list[QRectF] = []
        for i in seen:
            i = int(i)
            pt = self._screen(*project(float(lats[i]), float(lngs[i])))
            if not self.rect().contains(pt.toPoint()):
                continue
            box = QRectF(pt.x() - 3, pt.y() - fm.ascent() + 4, fm.horizontalAdvance(names[i]) + 10, fm.height())
            if any(box.intersects(t) for t in taken):                    # a smaller town under a bigger one's name: left out
                continue
            taken.append(box)
            p.setPen(Qt.PenStyle.NoPen)
            p.setBrush(ink)
            p.drawEllipse(pt, 1.6, 1.6)
            p.setPen(ink)
            p.drawText(pt + QPointF(5, 4), names[i])
            if len(taken) >= 90:
                break

    def _bubbles(self, p: QPainter) -> None:
        """The photos, gathered: points within a circle's width of each other share a circle."""
        cell = 54.0
        groups: dict[tuple[int, int], dict] = {}
        for x, y, n, label, b in self.points:
            pt = self._screen(x, y)
            if not (-cell <= pt.x() <= self.width() + cell and -cell <= pt.y() <= self.height() + cell):
                continue
            g = groups.setdefault((int(pt.x() // cell), int(pt.y() // cell)),
                                  {"x": 0.0, "y": 0.0, "n": 0, "labels": {}, "bins": []})
            g["x"] += pt.x() * n
            g["y"] += pt.y() * n
            g["n"] += n
            g["labels"][label] = g["labels"].get(label, 0) + n
            g["bins"].append(b)
        self._clusters = []
        f = QFont(self.font())
        f.setBold(True)
        f.setPointSizeF(max(8.0, f.pointSizeF() - 1.5))
        p.setFont(f)
        accent = QColor(self.theme.accent)
        for g in groups.values():
            c = QPointF(g["x"] / g["n"], g["y"] / g["n"])
            r = 9.0 + min(15.0, 3.2 * math.log10(g["n"] + 1) * 2)
            picked = bool(self.selected & set(g["bins"]))
            p.setPen(QPen(QColor("white"), 2.4 if picked else 1.5))
            fill = QColor(accent)
            fill.setAlpha(255 if picked else 215)
            p.setBrush(fill)
            p.drawEllipse(c, r, r)
            p.setPen(QColor(self.theme.on_accent))
            text = f"{g['n']:,}" if g["n"] < 10000 else f"{g['n'] // 1000}k"
            p.drawText(QRectF(c.x() - r, c.y() - r, 2 * r, 2 * r), Qt.AlignmentFlag.AlignCenter, text)
            self._clusters.append({"c": c, "r": r, **g})

    # -- the mouse
    def _at(self, pos) -> dict | None:
        for g in sorted(self._clusters, key=lambda g: g["r"]):
            if (g["c"].x() - pos.x()) ** 2 + (g["c"].y() - pos.y()) ** 2 <= (g["r"] + 2) ** 2:
                return g
        return None

    def wheelEvent(self, event) -> None:  # noqa: N802
        steps = event.angleDelta().y() / 120.0 or event.pixelDelta().y() / 60.0
        if not steps:
            return
        pos = event.position()
        before = self._scale()
        ux = self.cx + (pos.x() - self.width() / 2) / before        # the point under the mouse stays under it
        uy = self.cy + (pos.y() - self.height() / 2) / before
        self.zoom = max(0.8, min(14.0, self.zoom + steps * 0.35))
        after = self._scale()
        self.cx = (ux - (pos.x() - self.width() / 2) / after) % 1.0
        self.cy = min(1.0, max(0.0, uy - (pos.y() - self.height() / 2) / after))
        self.update()

    def mousePressEvent(self, event) -> None:  # noqa: N802
        if event.button() == Qt.MouseButton.LeftButton:
            self._drag, self._moved = event.position(), False
            self.setCursor(Qt.CursorShape.ClosedHandCursor)

    def mouseMoveEvent(self, event) -> None:  # noqa: N802
        if self._drag is not None:
            d = event.position() - self._drag
            if abs(d.x()) + abs(d.y()) > 2:
                self._moved = True
            self._drag = event.position()
            self.cx = (self.cx - d.x() / self._scale()) % 1.0
            self.cy = min(1.0, max(0.0, self.cy - d.y() / self._scale()))
            self.update()
            return
        g = self._at(event.position())
        if g is not None:
            top = sorted(g["labels"].items(), key=lambda kv: -kv[1])
            lines = [f"{label} — {n:,}" for label, n in top[:6]] + ([f"… and {len(top) - 6} more places"] if len(top) > 6 else [])
            QToolTip.showText(event.globalPosition().toPoint(), "\n".join(lines), self)
        else:
            QToolTip.hideText()

    def mouseReleaseEvent(self, event) -> None:  # noqa: N802
        self.setCursor(Qt.CursorShape.OpenHandCursor)
        moved, self._drag = self._moved, None
        if event.button() == Qt.MouseButton.LeftButton and not moved:
            g = self._at(event.position())
            self.selected = set(g["bins"]) if g is not None else set()
            self.picked.emit(sorted(self.selected))
            self.update()

    def mouseDoubleClickEvent(self, event) -> None:  # noqa: N802
        g = self._at(event.position())
        pos = event.position()
        s = self._scale()
        self.cx = (self.cx + (pos.x() - self.width() / 2) / s) % 1.0
        self.cy = min(1.0, max(0.0, self.cy + (pos.y() - self.height() / 2) / s))
        self.zoom = min(14.0, self.zoom + (1.6 if g is not None else 1.0))
        self.update()


class _Bridge(QObject):
    summary = Signal(object)
    progress = Signal(str)
    scanned = Signal(int)


class PlacesWindow(QWidget):
    def __init__(self, hooks: PlaceHooks, theme, parent=None) -> None:
        super().__init__(parent, Qt.WindowType.Window)
        self.setAttribute(Qt.WidgetAttribute.WA_DeleteOnClose)
        self.setWindowTitle("Places")
        self.hooks, self.theme = hooks, theme
        self.summary: list[dict] = []
        self.stop = threading.Event()
        self.scanning = False
        self.bridge = _Bridge()
        self.bridge.summary.connect(self._loaded)
        self.bridge.progress.connect(lambda line: self.status.setText(line))
        self.bridge.scanned.connect(self._scanned)
        self.resize(1080, 700)
        v = QVBoxLayout(self)
        v.setContentsMargins(0, 0, 0, 0)
        v.setSpacing(0)
        split = QSplitter(Qt.Orientation.Horizontal)
        left = QWidget()
        lv = QVBoxLayout(left)
        lv.setContentsMargins(12, 12, 8, 8)
        lv.setSpacing(8)
        self.find = QLineEdit()
        self.find.setPlaceholderText("Find a place")
        self.find.setClearButtonEnabled(True)
        self.find.setAccessibleName("Find a place")
        self.find.textChanged.connect(self._filter)
        lv.addWidget(self.find)
        self.tree = QTreeWidget()
        self.tree.setHeaderHidden(True)
        self.tree.setAccessibleName("Places")
        self.tree.itemSelectionChanged.connect(self._selected)
        self.tree.itemDoubleClicked.connect(lambda item, _c: self._show(item))
        lv.addWidget(self.tree, 1)
        split.addWidget(left)
        self.map = MapView(theme)
        self.map.picked.connect(self._map_picked)
        split.addWidget(self.map)
        split.setStretchFactor(0, 0)
        split.setStretchFactor(1, 1)
        split.setSizes([320, 760])
        v.addWidget(split, 1)
        bar = QWidget()
        bar.setObjectName("ActionBar")
        bh = QHBoxLayout(bar)
        bh.setContentsMargins(14, 8, 14, 8)
        self.status = QLabel("Reading the place index…")
        self.status.setObjectName("Summary")
        bh.addWidget(self.status, 1)
        self.busy = QProgressBar()
        self.busy.setRange(0, 0)
        self.busy.setFixedWidth(110)
        self.busy.setVisible(False)
        bh.addWidget(self.busy)
        self.refine = QCheckBox("Refine Place Names with Apple")
        self.refine.setToolTip("Off: every name is the nearest town, from the app's own table — nothing leaves the "
                               "Mac. On: Apple's geocoder is asked for better names (neighbourhoods, parks), a "
                               "place at a time; only coordinates are sent.")
        self.refine.setChecked(places.shared().refine)
        self.refine.toggled.connect(self._refine)
        bh.addWidget(self.refine)
        self.read_btn = QPushButton("Read Locations…")
        self.read_btn.setToolTip("Reads where every photo and video on the drive was taken — the ones not read yet")
        self.read_btn.clicked.connect(self._read)
        bh.addWidget(self.read_btn)
        self.all_btn = QPushButton("Whole Map")
        self.all_btn.clicked.connect(self.map.show_all)
        bh.addWidget(self.all_btn)
        self.show_btn = QPushButton("Show Photos")
        self.show_btn.setObjectName("Primary")
        self.show_btn.setEnabled(False)
        self.show_btn.clicked.connect(lambda: self._show(self.tree.currentItem()))
        bh.addWidget(self.show_btn)
        v.addWidget(bar)
        credit = QLabel(geo_names.ATTRIBUTION)
        credit.setObjectName("SheetSub")
        credit.setContentsMargins(14, 0, 14, 6)
        credit.setStyleSheet("font-size: 10px;")
        v.addWidget(credit)
        self._picked_bins: list[str] = []
        self.reload()

    # -- loading
    def reload(self) -> None:
        roots, bridge = self.hooks.roots(), self.bridge

        def work() -> None:
            lookup = places.shared()
            summary = lookup.summary(roots)
            per_bin: dict[str, int] = {}
            for _path, b in lookup.everything(roots):
                per_bin[b] = per_bin.get(b, 0) + 1
            for p in summary:
                p["per_bin"] = {b: per_bin.get(b, 1) for b in p["bins"]}
            try:
                bridge.summary.emit(summary)
            except RuntimeError:
                pass
        threading.Thread(target=work, name="places-summary", daemon=True).start()

    def _loaded(self, summary: list[dict]) -> None:
        first = not self.summary
        self.summary = summary
        self.map.set_points(summary)
        if first:
            self.map.show_all()
        self._fill()
        photos = sum(p["count"] for p in summary)
        if not self.scanning:
            self.status.setText(f"{photos:,} photo{'s' if photos != 1 else ''} and videos in {len(summary):,} "
                                f"place{'s' if len(summary) != 1 else ''}." if summary else
                                "No locations read yet — Read Locations… looks through the drive's photos.")

    def _fill(self) -> None:
        want = geo_names.fold(self.find.text())
        self.tree.clear()
        countries: dict[str, dict] = {}
        for p in self.summary:
            hay = geo_names.fold(f"{p['label']} {p['region']} {p['country']}")
            if want and not all(w in hay for w in want.split()):
                continue
            c = countries.setdefault(p["cc"], {"name": p["country"] or "Elsewhere", "count": 0, "regions": {}, "places": []})
            c["count"] += p["count"]
            c["places"].append(p)
            r = c["regions"].setdefault(p["region_key"], {"name": p["region"] or p["country"] or "Elsewhere", "count": 0,
                                                          "places": []})
            r["count"] += p["count"]
            r["places"].append(p)

        def spot(found: list[dict]) -> tuple[float, float, float]:
            n = sum(p["count"] for p in found)
            lat = sum(p["lat"] * p["count"] for p in found) / n
            lng = sum(p["lng"] * p["count"] for p in found) / n
            span = max([abs(p["lat"] - lat) for p in found] + [abs(p["lng"] - lng) for p in found] + [0.03]) * 2.6
            return lat, lng, span

        def leaf(parent, p: dict) -> None:
            it = QTreeWidgetItem(parent, [f"{p['label']}   {p['count']:,}"])
            it.setData(0, ARG, p["label"])
            it.setData(0, SPOT, (p["lat"], p["lng"], 0.12))

        for cc, c in sorted(countries.items(), key=lambda kv: (-kv[1]["count"], kv[1]["name"])):
            top = QTreeWidgetItem(self.tree, [f"{c['name']}   {c['count']:,}"])
            top.setData(0, ARG, f"@cc:{cc}" if cc else "")
            top.setData(0, SPOT, spot(c["places"]))
            f = top.font(0)
            f.setBold(True)
            top.setFont(0, f)
            if len(c["regions"]) > 1:
                for key, r in sorted(c["regions"].items(), key=lambda kv: (-kv[1]["count"], kv[1]["name"])):
                    mid = QTreeWidgetItem(top, [f"{r['name']}   {r['count']:,}"])
                    mid.setData(0, ARG, f"@region:{key}")
                    mid.setData(0, SPOT, spot(r["places"]))
                    for p in r["places"]:
                        leaf(mid, p)
            else:
                for p in c["places"]:
                    leaf(top, p)
            top.setExpanded(bool(want) or len(countries) <= 3)
        if want:
            self.tree.expandAll()

    def _filter(self, _text: str) -> None:
        self._fill()

    # -- choosing
    def _selected(self) -> None:
        self._picked_bins = []                          # the list was used: Show Photos means the place chosen there
        item = self.tree.currentItem()
        self.show_btn.setEnabled(item is not None and bool(item.data(0, ARG)))
        spot = item.data(0, SPOT) if item is not None else None
        if spot:
            self.map.go(*spot)

    def _show(self, item) -> None:
        arg = item.data(0, ARG) if item is not None else ""
        bins = self._picked_bins
        if bins and len(bins) <= MOST_BINS:
            # A circle on the map was clicked: exactly its photos — unless it's one whole place, which has a name.
            whole = next((p for p in self.summary if set(p["bins"]) == set(bins)), None)
            arg = whole["label"] if whole is not None and whole.get("label") else "@bins:" + ";".join(bins)
        if arg:
            self.hooks.show(arg)

    def _map_picked(self, bins: list[str]) -> None:
        """A circle on the map: Show Photos shows that circle's photos; its biggest place is selected in the list
        (so it's clear where that is)."""
        self._picked_bins = bins
        if not bins:
            return
        self.show_btn.setEnabled(True)
        best = max((p for p in self.summary if set(p["bins"]) & set(bins)), key=lambda p: p["count"], default=None)
        if best is None:
            return

        def walk(item):
            for i in range(item.childCount()):
                child = item.child(i)
                if child.data(0, ARG) == best["label"]:
                    return child
                hit = walk(child)
                if hit is not None:
                    return hit
            return None
        hit = walk(self.tree.invisibleRootItem())
        if hit is not None:
            self.tree.blockSignals(True)
            self.tree.setCurrentItem(hit)
            self.tree.scrollToItem(hit)
            self.tree.blockSignals(False)
            self.show_btn.setEnabled(True)

    # -- reading and naming
    def _refine(self, on: bool) -> None:
        places.shared().refine = bool(on)
        app_identity.settings().setValue("places/refine", "true" if on else "false")

    def _read(self) -> None:
        if self.scanning:
            self.stop.set()
            return
        folder = self.hooks.scan_folder() if self.hooks.scan_folder else ""
        if not folder:
            self.status.setText("Connect the drive (or open a folder) first.")
            return
        self.scanning = True
        self.stop = threading.Event()
        self.read_btn.setText("Stop")
        self.busy.setVisible(True)
        stop, bridge = self.stop, self.bridge

        def work() -> None:
            try:
                n = places.shared().scan(folder, lambda line: bridge.progress.emit(line), stop)
            except Exception:  # noqa: BLE001 — a damaged file mustn't end the window
                n = -1
            try:
                bridge.scanned.emit(n)
            except RuntimeError:
                pass
        threading.Thread(target=work, name="places-scan", daemon=True).start()

    def _scanned(self, n: int) -> None:
        self.scanning = False
        self.read_btn.setText("Read Locations…")
        self.busy.setVisible(False)
        self.status.setText("Couldn't finish reading the locations." if n < 0 else
                            "Every photo's location was already read." if n == 0 else
                            f"Read the location of {n:,} more photo{'s' if n != 1 else ''} and videos.")
        QTimer.singleShot(1800, self.reload)
        self.reload()

    def closeEvent(self, event) -> None:  # noqa: N802
        self.stop.set()
        super().closeEvent(event)
