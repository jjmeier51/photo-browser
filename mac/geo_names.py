"""Place names without the network: the nearest town to a point, from a table that ships with the app.

`geo/places.npz` (made by `make_geo_data.py` from GeoNames, CC BY 4.0) holds every place on Earth with over 1,000
people — 170,000 of them. `nearest(lat, lng)` finds the one a photo was taken at in under a millisecond, so every
photo with a location has a place the moment its GPS is read: no geocoder, no one-request-a-second queue, nothing
sent anywhere. (Apple's geocoder, through `geocode_helper.swift`, still refines names when asked — it knows
neighbourhoods and landmarks this table doesn't — and the iPhone's own names on the drive come first.)

- `nearest` / `nearest_many` → `Place(city, district, region, region_code, cc, country, km)`. `city` is the town —
  or, for a row that's a neighbourhood or suburb of a big city ("Paris 16 Passy", "Trastevere"), the city it's part
  of, with the row kept as `district`. `km` is how far the point is from it: a point 100 km from anywhere (open
  sea, a pole) has no town, only — at best — a country.
- `label(place)` writes it as the iPhone app does: "Hauppauge, NY" in the US, "London, UK", "Dubai, UAE",
  otherwise "Paris, France". `search_text(place)` is everything a search may match: "passy, paris,
  île-de-france, france".
- `find(text)` → the places called that, biggest first — where `near:"lake tahoe"` and the map's search look.
- `country_code("france" | "fr" | "usa")` for `country:`.

How: every place as a unit vector on the sphere; a point's nearest are the largest dot products (one matrix
product for a whole batch), and the top few are then measured properly in double precision — single-precision dot
products can't tell two places 2 km apart, which first put Passy's photos in the wrong arrondissement.

numpy only. The table is loaded on first use (about 80 ms).
"""
from __future__ import annotations

import math
import sys
import threading
import unicodedata
from pathlib import Path
from typing import NamedTuple

import numpy as np

FAR_KM = 100.0                    # farther than this from any place: there's no town to name
ATTRIBUTION = "Place names: GeoNames (geonames.org), CC BY 4.0. Map: Natural Earth."
_ALIASES = {"usa": "US", "us": "US", "america": "US", "united states of america": "US", "uk": "GB",
            "britain": "GB", "great britain": "GB", "england": "GB", "scotland": "GB", "wales": "GB",
            "uae": "AE", "emirates": "AE", "holland": "NL", "czech republic": "CZ", "korea": "KR",
            "south korea": "KR", "russia": "RU", "turkey": "TR", "türkiye": "TR", "ivory coast": "CI"}


class Place(NamedTuple):
    city: str
    district: str                 # the neighbourhood or suburb row, when `city` is the city it's part of
    region: str                   # the state or region's name ("New York", "Île-de-France")
    region_code: str              # GeoNames' code for it — the postal abbreviation in the US ("NY")
    cc: str                       # ISO country code
    country: str
    km: float


def data_folder() -> Path:
    here = Path(__file__).resolve().parent
    for base in (Path(getattr(sys, "_MEIPASS", here)), here):
        if (base / "geo" / "places.npz").is_file():
            return base / "geo"
    return here / "geo"


class _Table:
    def __init__(self) -> None:
        z = np.load(data_folder() / "places.npz")

        def unpacked(key: str) -> list[str]:
            return bytes(z[key]).decode("utf-8").split("\n")

        self.lat = z["lat"].astype(np.float64)
        self.lng = z["lng"].astype(np.float64)
        self.pop = z["pop"]
        self.region = z["region"]
        self.parent = z["parent"]
        self.names = unpacked("names")
        self.regions = unpacked("regions")                 # "US.NY"
        self.region_names = unpacked("region_names")
        self.countries: dict[str, str] = {}
        self.continents: dict[str, str] = {}
        for line in unpacked("countries"):
            cc, name, continent = (line.split("\t") + ["", ""])[:3]
            self.countries[cc] = name
            self.continents[cc] = continent
        la, lo = np.radians(self.lat), np.radians(self.lng)
        self.xyz = np.stack([np.cos(la) * np.cos(lo), np.cos(la) * np.sin(lo), np.sin(la)], axis=1).astype(np.float32)
        self._by_name: dict[str, list[int]] | None = None

    def place(self, i: int, km: float) -> Place:
        key = self.regions[int(self.region[i])]
        cc, _, code = key.partition(".")
        parent = int(self.parent[i])
        city = self.names[parent] if parent >= 0 else self.names[i]
        return Place(city, self.names[i] if parent >= 0 else "", self.region_names[int(self.region[i])], code, cc,
                     self.countries.get(cc, ""), km)

    def by_name(self) -> dict[str, list[int]]:
        if self._by_name is None:
            index: dict[str, list[int]] = {}
            for i, name in enumerate(self.names):
                index.setdefault(fold(name), []).append(i)
            self._by_name = index
        return self._by_name


_table: _Table | None = None
_lock = threading.Lock()


def table() -> _Table:
    global _table
    with _lock:
        if _table is None:
            _table = _Table()
        return _table


def available() -> bool:
    return (data_folder() / "places.npz").is_file()


def fold(text: str) -> str:
    """Lower case, accents off — how names are compared."""
    text = unicodedata.normalize("NFKD", text.casefold())
    return "".join(c for c in text if not unicodedata.combining(c)).strip()


def valid(lat: float, lng: float) -> bool:
    return (lat == lat and lng == lng and abs(lat) <= 90 and abs(lng) <= 180 and not (lat == 0 and lng == 0))


def _haversine(lat1, lng1, lat2, lng2):
    la1, lo1, la2, lo2 = (np.radians(v) for v in (lat1, lng1, lat2, lng2))
    a = np.sin((la2 - la1) / 2) ** 2 + np.cos(la1) * np.cos(la2) * np.sin((lo2 - lo1) / 2) ** 2
    return 2 * 6371.0088 * np.arcsin(np.sqrt(np.clip(a, 0, 1)))


def nearest_many(lats, lngs) -> list[Place | None]:
    """The place nearest each point (None for a point that isn't one: NaN, off the globe, exactly 0,0)."""
    t = table()
    lats, lngs = np.asarray(lats, dtype=np.float64), np.asarray(lngs, dtype=np.float64)
    out: list[Place | None] = [None] * len(lats)
    ok = [i for i in range(len(lats)) if valid(float(lats[i]), float(lngs[i]))]
    for a in range(0, len(ok), 32):                    # (32 at a time: 256 made a gigabyte of the table at once)
        idx = ok[a:a + 32]
        la, lo = np.radians(lats[idx]), np.radians(lngs[idx])
        q = np.stack([np.cos(la) * np.cos(lo), np.cos(la) * np.sin(lo), np.sin(la)], axis=1).astype(np.float32)
        sims = q @ t.xyz.T
        top = np.argpartition(-sims, 8, axis=1)[:, :8]          # the eight likeliest, then measured properly
        for row, i in enumerate(idx):
            cand = top[row]
            d = _haversine(lats[i], lngs[i], t.lat[cand], t.lng[cand])
            k = int(np.argmin(d))
            out[i] = t.place(int(cand[k]), float(d[k]))
    return out


def nearest(lat: float, lng: float) -> Place | None:
    return nearest_many([lat], [lng])[0]


def label(p: Place | None) -> str:
    """The place as the iPhone app writes it ("City, ST" / "City, UK" / "City, Country"); "" when the point is
    too far from anywhere to have a town."""
    if p is None or p.km > FAR_KM:
        return ""
    if p.cc == "US":
        region = p.region_code or "USA"
    elif p.cc == "GB":
        region = "UK"
    elif p.cc == "AE":
        region = "UAE"
    else:
        region = p.country
    if not p.city:
        return region
    return p.city if (not region or region == p.city) else f"{p.city}, {region}"


def search_text(p: Place | None) -> str:
    """Everything about the place a search may match, lower case: district, city, region, country."""
    if p is None or p.km > FAR_KM:
        return ""
    parts = [p.district, p.city, p.region, p.region_code if p.cc == "US" else "", p.country]
    seen, out = set(), []
    for part in parts:
        f = part.casefold()
        if f and f not in seen:
            seen.add(f)
            out.append(f)
    return ", ".join(out)


def country_code(text: str) -> str:
    """"fr", "France", "usa" → "FR", "FR", "US" ("" when it's no country)."""
    t = table()
    f = fold(text)
    if len(f) == 2 and f.upper() in t.countries:
        return f.upper()
    if f in _ALIASES:
        return _ALIASES[f]
    return next((cc for cc, name in t.countries.items() if fold(name) == f), "")


def country_name(cc: str) -> str:
    return table().countries.get(cc.upper(), "")


def wide_place(text: str) -> tuple[str, str] | None:
    """`text` as a country or a state/region, when it names one: ("country", "fr") or ("state", "california") —
    in the form the search compares with. None for anything else (a town, or nothing known)."""
    want = fold(text.strip())
    if not want:
        return None
    cc = country_code(want)
    if cc and len(want) > 2:                         # (two letters are too easily a word: "in", "la")
        return "country", cc.lower()
    t = table()
    if any(fold(n) == want for n in t.region_names if n):
        return "state", want
    return None


def find(text: str, limit: int = 8, prefix: bool = True) -> list[tuple[float, float, Place]]:
    """Places called `text` ("lake tahoe", "paris", "paris, tx"), the biggest first: (lat, lng, place). With
    `prefix`, a name nothing has exactly is taken as the start of one ("yosemite" → Yosemite Valley) — right for
    the map's search box, where the result is seen; not for `near:`, which would quietly search somewhere else."""
    t = table()
    name, _, rest = text.partition(",")
    want = fold(name)
    region = fold(rest)
    hits = list(t.by_name().get(want, []))
    if not hits and prefix and len(want) >= 4:                   # the start of a name: "yosemite" → Yosemite Valley
        hits = [i for key, rows in t.by_name().items() if key.startswith(want) for i in rows]
    out = []
    for i in sorted(hits, key=lambda i: -int(t.pop[i])):
        p = t.place(i, 0.0)
        if region and region not in (fold(p.region), fold(p.region_code), fold(p.country), p.cc.lower()) \
                and country_code(region) != p.cc:
            continue
        out.append((float(t.lat[i]), float(t.lng[i]), p))
        if len(out) >= limit:
            break
    return out


def distance_km(lat1: float, lng1: float, lat2: float, lng2: float) -> float:
    return float(_haversine(lat1, lng1, lat2, lng2))


def towns(min_pop: int) -> tuple[np.ndarray, np.ndarray, list[str], np.ndarray]:
    """(lats, lngs, names, populations) of the places with at least `min_pop` people — the map's dots and names."""
    t = table()
    idx = np.nonzero((t.pop >= min_pop) & (t.parent < 0))[0]
    return t.lat[idx], t.lng[idx], [t.names[int(i)] for i in idx], t.pop[idx]


def bin_centre(b: str) -> tuple[float, float] | None:
    """A place index bin ("40.82|-73.20") as a point."""
    try:
        lat, _, lng = b.partition("|")
        lat, lng = float(lat), float(lng)
    except ValueError:
        return None
    return (lat, lng) if valid(lat, lng) and math.isfinite(lat) else None
