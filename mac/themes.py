"""Safe Finder's looks — the iPhone app's themes (`AppTheme.swift`: Everyday, Halloween, Thanksgiving, Christmas
and Holiday sets, or a custom background, accent colour, typeface and light/dark chrome), plus "Match macOS", the
Finder look that follows the Mac's light or dark appearance.

A `Look` is what's chosen: the background behind the files (one colour, or a gradient of two or three), the
accent (selection, buttons, the active chips), the typeface, and whether the chrome is light. Everything else on
screen — sidebar, headers, borders, buttons — is worked out from those (`derive`), so any background reads as one
window rather than a wallpaper behind grey panels. `safe_finder.Theme` turns the result into its stylesheet and
palette; `theme_window.py` is the chooser.

Kept in Safe Finder's settings as JSON (`theme`); empty = Match macOS. The preset names and colours are the
iPhone app's — keep the two lists in step.

Two things are the Mac's own: **My Themes** (custom looks saved under a name — `looks_from_json`, `with_saved`;
setting `my_themes`) and **Follow the Seasons** (`seasonal`: through the holidays the window wears that season's
themes, a different one each day, and goes back to the chosen theme afterwards; setting `theme_seasonal`).
"""
from __future__ import annotations

import json
from dataclasses import dataclass, field

DIRECTIONS = {"down": "Top to bottom", "diagonal": "Diagonal", "across": "Left to right"}

# iPhone typeface → (title, font families to try on the Mac, first found wins)
TYPEFACES: dict[str, tuple[str, list[str]]] = {
    "system": ("System", []),
    "rounded": ("Rounded", [".AppleSystemUIFontRounded", "SF Pro Rounded", "Arial Rounded MT Bold"]),
    "serif": ("Serif", [".AppleSystemUIFontSerif", "New York", "Georgia"]),
    "mono": ("Monospaced", [".AppleSystemUIFontMonospaced", "SF Mono", "Menlo"]),
    "avenir": ("Avenir Next", ["Avenir Next"]),
    "georgia": ("Georgia", ["Georgia"]),
    "futura": ("Futura", ["Futura"]),
    "chalkboard": ("Chalkboard", ["Chalkboard SE", "Chalkboard"]),
    "markerFelt": ("Marker Felt", ["Marker Felt"]),
    "noteworthy": ("Noteworthy", ["Noteworthy"]),
    "copperplate": ("Copperplate", ["Copperplate"]),
    "bradleyHand": ("Bradley Hand", ["Bradley Hand"]),
    "snellRoundhand": ("Snell Roundhand", ["Snell Roundhand"]),
}


def rgb(css: str) -> tuple[int, int, int]:
    css = css.lstrip("#")
    return int(css[0:2], 16), int(css[2:4], 16), int(css[4:6], 16)


def css(c: tuple[float, float, float]) -> str:
    return "#%02X%02X%02X" % tuple(max(0, min(255, int(round(v)))) for v in c)


def mix(a: str, b: str, t: float) -> str:
    """`a` moved the fraction `t` of the way to `b`."""
    x, y = rgb(a), rgb(b)
    return css(tuple(x[i] + (y[i] - x[i]) * t for i in range(3)))


def luminance(c: str) -> float:
    r, g, b = rgb(c)
    return (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255


def average(colors: list[str]) -> str:
    cs = [rgb(c) for c in colors]
    return css(tuple(sum(c[i] for c in cs) / len(cs) for i in range(3)))


def valid_color(c) -> bool:
    if not isinstance(c, str) or len(c) != 7 or c[0] != "#":
        return False
    try:
        int(c[1:], 16)
        return True
    except ValueError:
        return False


@dataclass
class Look:
    name: str
    colors: list[str]                    # the background: one colour, or a gradient's two or three
    accent: str
    typeface: str = "system"
    light: bool = False
    direction: str = "down"
    group: str = field(default="", compare=False)

    def to_json(self) -> str:
        return json.dumps({"name": self.name, "colors": self.colors, "direction": self.direction,
                           "accent": self.accent, "typeface": self.typeface, "light": self.light})

    @staticmethod
    def from_json(text) -> "Look | None":
        """None for nothing saved, or anything that isn't a look (Match macOS then)."""
        try:
            d = json.loads(str(text or ""))
        except ValueError:
            return None
        if not isinstance(d, dict):
            return None
        colors = d.get("colors")
        if not (isinstance(colors, list) and 1 <= len(colors) <= 3 and all(valid_color(c) for c in colors)):
            return None
        if not valid_color(d.get("accent")):
            return None
        return Look(str(d.get("name") or "Custom")[:60], [c.upper() for c in colors], d["accent"].upper(),
                    d.get("typeface") if d.get("typeface") in TYPEFACES else "system", bool(d.get("light")),
                    d.get("direction") if d.get("direction") in DIRECTIONS else "down")

    def same_looks(self, other: "Look") -> bool:
        return (self.colors, self.accent, self.typeface, self.light, self.direction if len(self.colors) > 1 else "") == \
            (other.colors, other.accent, other.typeface, other.light, other.direction if len(other.colors) > 1 else "")


def _l(group: str, name: str, colors: list[str], accent: str, typeface: str = "system", light: bool = False,
       direction: str = "down") -> Look:
    return Look(name, colors, accent, typeface, light, direction, group)


# The iPhone app's presets (AppTheme.groups), in its order.
PRESETS: list[Look] = [
    _l("Everyday", "Photo Browser", ["#0D1733", "#000000"], "#0A84FF"),
    _l("Everyday", "Graphite", ["#1C1C1E"], "#C7C7CC"),
    _l("Everyday", "Midnight", ["#0B1026", "#1A0B2E"], "#8E7CFF", "rounded", direction="diagonal"),
    _l("Everyday", "Ocean", ["#04263B", "#000814"], "#2EC4B6", "rounded"),
    _l("Everyday", "Rose", ["#2B0A1E", "#0D0208"], "#FF6B9A", "serif"),
    _l("Everyday", "Forest", ["#0B2A1A", "#02110A"], "#7ED957", "rounded"),
    _l("Everyday", "Sunset", ["#2D0A4E", "#7A1F3D", "#C2410C"], "#FFB703", direction="diagonal"),
    _l("Everyday", "Paper", ["#FFFFFF", "#EDEDF2"], "#0A84FF", "serif", light=True),
    _l("Halloween", "Pumpkin Patch", ["#1A0A00", "#3D1A00", "#000000"], "#FF7A00", "chalkboard"),
    _l("Halloween", "Witching Hour", ["#120024", "#2A0A4A"], "#39D353", "chalkboard", direction="diagonal"),
    _l("Halloween", "Haunted House", ["#0E0E10"], "#C41E3A", "markerFelt"),
    _l("Halloween", "Candy Corn", ["#3D1F00", "#7A3E00", "#B37400"], "#FFF3B0", "noteworthy"),
    _l("Halloween", "Ghost Story", ["#1B1F2A", "#0B0D12"], "#B8C7E0", "bradleyHand"),
    _l("Thanksgiving", "Harvest Table", ["#3B1F0B", "#5E3210", "#1F1005"], "#F2A541", "georgia"),
    _l("Thanksgiving", "Autumn Leaves", ["#4A1508", "#7A300C", "#8A4E12"], "#FFE8B0", "serif", direction="diagonal"),
    _l("Thanksgiving", "Pumpkin Pie", ["#4A2508", "#7A4212"], "#FFD9A0", "noteworthy"),
    _l("Thanksgiving", "Cranberry", ["#3A0613", "#6E0F26"], "#FFC7A6", "serif", direction="diagonal"),
    _l("Thanksgiving", "Sage and Squash", ["#27301F", "#141A10"], "#E9B44C", "avenir"),
    _l("Thanksgiving", "Maple", ["#2A1206", "#140A04"], "#F59B4B", "rounded"),
    _l("Thanksgiving", "Cornucopia", ["#FFF6E3", "#F3DDB3"], "#B5521B", "georgia", light=True),
    _l("Christmas", "Candy Cane", ["#7A0000", "#B3001B"], "#FFFFFF", "rounded", direction="diagonal"),
    _l("Christmas", "Evergreen", ["#0B3D20", "#06281A", "#021A10"], "#FFD700", "serif"),
    _l("Christmas", "Winter Night", ["#0A1931", "#185ADB"], "#BFE9FF", "rounded"),
    _l("Christmas", "Cozy Fireplace", ["#2B1105", "#4A1C0C", "#1A0A05"], "#FF9F1C", "georgia"),
    _l("Christmas", "Snow Day", ["#FFFFFF", "#DCEBFF"], "#D7263D", "rounded", light=True),
    _l("Christmas", "Silver Bells", ["#2C2F36", "#0F1115"], "#E6E6EB", "snellRoundhand"),
    _l("Christmas", "Gingerbread", ["#3E2212", "#5C3317", "#2A160B"], "#FFF1DC", "chalkboard"),
    _l("Christmas", "Nutcracker", ["#101B45", "#5E0D1A"], "#FFD24A", "copperplate", direction="diagonal"),
    _l("Christmas", "Mistletoe", ["#10361F", "#0A2415"], "#FF8C94", "noteworthy"),
    _l("Christmas", "Christmas Eve", ["#050B24", "#0E1B4D", "#1B0B33"], "#FFE08A", "serif"),
    _l("Christmas", "Santa's Workshop", ["#5A0A0A", "#2E0505"], "#F4D35E", "markerFelt"),
    _l("Christmas", "North Pole", ["#F4FBFF", "#CFE8F7"], "#C1121F", "rounded", light=True),
    _l("Holiday", "Holiday Lights", ["#0B0F1A", "#141B2D"], "#FFC857", "rounded"),
    _l("Holiday", "Festival of Lights", ["#0A2A66", "#061A40"], "#E8EEF9", "serif"),
    _l("Holiday", "Kwanzaa", ["#0E0E0E", "#3D0A0A", "#0B3317"], "#F2C037", "futura", direction="diagonal"),
    _l("Holiday", "Winter Solstice", ["#0D1B2A", "#1B263B", "#33475F"], "#E0E1DD", "avenir"),
    _l("Holiday", "Sugar Plum", ["#2B0F3A", "#4E2460"], "#FFC2E2", "snellRoundhand", direction="diagonal"),
    _l("Holiday", "Hot Cocoa", ["#3A2418", "#1E120C"], "#F7D9C4", "noteworthy"),
    _l("Holiday", "Midnight Toast", ["#0A0A0F", "#1C1530"], "#F5D76E", "copperplate"),
    _l("Holiday", "First Frost", ["#FFFFFF", "#E3EEF4"], "#2A6FAB", "avenir", light=True),
]


def groups() -> list[tuple[str, list[Look]]]:
    out: list[tuple[str, list[Look]]] = []
    for look in PRESETS:
        if not out or out[-1][0] != look.group:
            out.append((look.group, []))
        out[-1][1].append(look)
    return out


def preset(name: str) -> Look | None:
    return next((p for p in PRESETS if p.name == name), None)


def gradient_css(colors: list[str], direction: str) -> str:
    """The background as a stylesheet value: the colour, or a `qlineargradient`."""
    if len(colors) == 1:
        return colors[0]
    x2, y2 = {"down": (0, 1), "diagonal": (1, 1), "across": (1, 0)}.get(direction, (0, 1))
    stops = ", ".join(f"stop:{i / (len(colors) - 1):.3g} {c}" for i, c in enumerate(colors))
    return f"qlineargradient(x1:0, y1:0, x2:{x2}, y2:{y2}, {stops})"


def derive(look: Look) -> dict[str, str]:
    """Every colour the window needs, from the look's few. Dark chrome is the background lifted towards white a
    step at a time (sidebar sunk a little towards black); light chrome the other way round."""
    top, avg = look.colors[0], average(look.colors)
    white, black = "#FFFFFF", "#000000"
    accent = look.accent
    on_accent = black if luminance(accent) > 0.6 else white
    if look.light:
        out = {
            "window": avg, "content": avg, "header": mix(top, black, 0.035), "sidebar": mix(avg, black, 0.07),
            "panel": mix(avg, black, 0.02), "border": mix(avg, black, 0.15), "hairline": "rgba(0,0,0,0.07)",
            "text": "#1D1D1F", "secondary": "#6E6E73", "tertiary": "#A1A1A6",
            "select_bg": "rgba(0,0,0,0.075)", "select_inactive": mix(avg, black, 0.17),
            "zebra": "rgba(0,0,0,0.03)", "hover": "rgba(0,0,0,0.045)",
            "button": mix(avg, white, 0.6), "button_border": "rgba(0,0,0,0.14)",
            "green": "#28A745", "orange": "#E8890C", "red": "#E5372B",
        }
    else:
        bright = luminance(avg) > 0.16                 # Candy Cane, Winter Night: text needs full white
        out = {
            "window": avg, "content": avg, "header": mix(top, white, 0.07),
            "sidebar": mix(avg, black, 0.30) if luminance(avg) > 0.05 else mix(avg, white, 0.05),
            "panel": mix(avg, white, 0.06), "border": mix(avg, white, 0.17), "hairline": "rgba(255,255,255,0.07)",
            "text": "#FFFFFF" if bright else "#EBEBF0",
            "secondary": mix(avg, white, 0.72) if bright else "#98989F",
            "tertiary": mix(avg, white, 0.5) if bright else "#6C6C70",
            "select_bg": "rgba(255,255,255,0.13)", "select_inactive": mix(avg, white, 0.25),
            "zebra": "rgba(255,255,255,0.035)", "hover": "rgba(255,255,255,0.07)",
            "button": mix(avg, white, 0.13), "button_border": "rgba(255,255,255,0.12)",
            "green": "#32D74B", "orange": "#FF9F0A", "red": "#FF453A",
        }
    out.update(accent=accent, accent_pill=mix(accent, black, 0.14), on_accent=on_accent,
               content_css=gradient_css(look.colors, look.direction))
    return out


# ----------------------------------------------------------------------------- themes of one's own

def looks_from_json(text) -> list[Look]:
    """The saved themes ("My Themes"): a JSON list of looks. Anything unreadable is simply not there."""
    try:
        items = json.loads(str(text or "[]"))
    except ValueError:
        return []
    out: list[Look] = []
    for item in items if isinstance(items, list) else []:
        look = Look.from_json(json.dumps(item))
        if look is not None and all(look.name != o.name for o in out):
            look.group = MINE
            out.append(look)
    return out


def looks_to_json(looks: list[Look]) -> str:
    return json.dumps([json.loads(look.to_json()) for look in looks])


MINE = "My Themes"


def with_saved(looks: list[Look], look: Look, name: str) -> list[Look]:
    """`looks` with `look` kept under `name` — replacing the one of that name, else added at the end."""
    name = " ".join(name.split())[:60] or "My Theme"
    kept = Look(name, list(look.colors), look.accent, look.typeface, look.light, look.direction, MINE)
    out = [kept if o.name == name else o for o in looks]
    return out if any(o.name == name for o in looks) else out + [kept]


# ----------------------------------------------------------------------------- following the seasons

DECEMBER = {"christmas": "Christmas themes", "holiday": "Holiday themes", "both": "Christmas and Holiday themes"}


def thanksgiving(year: int):
    """US Thanksgiving: the fourth Thursday of November."""
    import datetime
    first = datetime.date(year, 11, 1)
    return first + datetime.timedelta(days=(3 - first.weekday()) % 7 + 21)


def season(day, december: str = "both") -> list[str]:
    """The theme groups in season on `day` (a `datetime.date`) — empty outside the holidays.

    October is Halloween; November up to Thanksgiving Day is Thanksgiving; the day after it up to Christmas Day
    is Christmas, Holiday or both (`december`); the days from the 26th to New Year's Day are Holiday."""
    if day.month == 10:
        return ["Halloween"]
    turkey = thanksgiving(day.year)
    if day.month == 11 and day <= turkey:
        return ["Thanksgiving"]
    if (day.month == 11 and day > turkey) or (day.month == 12 and day.day <= 25):
        return {"christmas": ["Christmas"], "holiday": ["Holiday"]}.get(december, ["Christmas", "Holiday"])
    if (day.month == 12 and day.day >= 26) or (day.month == 1 and day.day == 1):
        return ["Holiday"]
    return []


def seasonal(day, december: str = "both") -> Look | None:
    """The theme to wear on `day` when following the seasons: a different one of the season's each day (the same
    one all day), or None outside the holidays — the chosen theme shows then."""
    names = season(day, december)
    pool = [p for p in PRESETS if p.group in names]
    return pool[day.toordinal() % len(pool)] if pool else None
