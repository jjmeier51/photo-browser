#!/usr/bin/env python3
"""Builds the two data files Places works from — `geo/places.npz` and `geo/world.json.gz` — out of public data.

    python3 mac/make_geo_data.py [folder with the downloads]

Without a folder the sources are downloaded (about 15 MB) into a temporary one:

- **GeoNames** (geonames.org, CC BY 4.0): `cities1000.zip` — every place with over 1,000 people, 170,000 of them
  — with `admin1CodesASCII.txt` (states and regions) and `countryInfo.txt`. Reduced to what naming a photo's
  place needs: position, name, population, region, country — 2.4 MB.
- **Natural Earth** (naturalearthdata.com, public domain): country outlines at 1:110m (the whole world at a
  glance) and 1:50m (zoomed in), reduced to ISO code, name and coordinates to two decimals — 0.5 MB.

Both outputs are committed, so the app needs neither the network nor this script; it is here so the files can be
made again (newer data, a different cut). numpy only.

`parent`: a neighbourhood or suburb row ("Paris 16 Passy", "Trastevere", "Universal City") points at the city
it's part of — the most populous place in the same region, at least five times its size, with 300,000 people or
more, within a distance that grows with the city's size (0.008·√population km: Paris 12 km, London 24 km). The
row itself is kept as the *district*.
"""
from __future__ import annotations

import gzip
import io
import json
import sys
import tempfile
import urllib.request
import zipfile
from pathlib import Path

import numpy as np

GEONAMES = "https://download.geonames.org/export/dump/"
NATURAL_EARTH = "https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson/"
HERE = Path(__file__).resolve().parent
OUT = HERE / "geo"


def source(folder: Path, name: str, base: str) -> Path:
    for sub in ("", "geonames", "ne"):
        p = folder / sub / name
        if p.is_file():
            return p
    p = folder / name
    print("downloading", name)
    with urllib.request.urlopen(base + name, timeout=120) as r:
        p.write_bytes(r.read())
    return p


def build_places(folder: Path) -> None:
    with zipfile.ZipFile(source(folder, "cities1000.zip", GEONAMES)) as z:
        text = z.read("cities1000.txt").decode("utf-8")
    admin1 = {}
    for line in source(folder, "admin1CodesASCII.txt", GEONAMES).read_text(encoding="utf-8").splitlines():
        parts = line.split("\t")
        if len(parts) >= 2:
            admin1[parts[0]] = parts[1]
    countries = []
    for line in source(folder, "countryInfo.txt", GEONAMES).read_text(encoding="utf-8").splitlines():
        if line and not line.startswith("#"):
            p = line.split("\t")
            countries.append(f"{p[0]}\t{p[4]}\t{p[8]}")          # ISO code, name, continent
    names, lats, lngs, pops, keys = [], [], [], [], []
    for line in text.splitlines():
        p = line.split("\t")
        if len(p) < 15:
            continue
        names.append(p[1])
        lats.append(float(p[4]))
        lngs.append(float(p[5]))
        pops.append(int(p[14] or 0))
        keys.append(f"{p[8]}.{p[10]}")                          # country.admin1
    regions = sorted(set(keys))
    where = {k: i for i, k in enumerate(regions)}
    region = np.array([where[k] for k in keys], dtype=np.uint16)
    lat = np.array(lats, dtype=np.float32)
    lng = np.array(lngs, dtype=np.float32)
    pop = np.array(pops, dtype=np.int32)

    # neighbourhoods and suburbs → the city they belong to (module notes)
    parent = np.full(len(names), -1, dtype=np.int32)
    la, lo = np.radians(lat.astype(np.float64)), np.radians(lng.astype(np.float64))
    for b in np.argsort(-pop):
        if pop[b] < 300_000:
            break
        if parent[b] != -1:
            continue
        same = np.nonzero((region == region[b]) & (pop * 5 <= pop[b]) & (parent == -1))[0]
        if not len(same):
            continue
        d = 2 * 6371.0 * np.arcsin(np.sqrt(np.sin((la[same] - la[b]) / 2) ** 2
                                           + np.cos(la[same]) * np.cos(la[b]) * np.sin((lo[same] - lo[b]) / 2) ** 2))
        parent[same[d <= 0.008 * np.sqrt(float(pop[b]))]] = b

    def packed(items: list[str]) -> np.ndarray:
        return np.frombuffer("\n".join(items).encode("utf-8"), dtype=np.uint8)

    OUT.mkdir(exist_ok=True)
    np.savez_compressed(OUT / "places.npz", lat=lat, lng=lng, pop=pop, region=region, parent=parent,
                        names=packed(names), regions=packed(regions),
                        region_names=packed([admin1.get(k, "") for k in regions]), countries=packed(countries))
    print(f"places.npz: {len(names):,} places, {int((parent >= 0).sum()):,} rolled up into a city, "
          f"{(OUT / 'places.npz').stat().st_size / 1e6:.2f} MB")


def build_world(folder: Path) -> None:
    out = {}
    for key, name in (("110", "ne_110m_admin_0_countries.geojson"), ("50", "ne_50m_admin_0_countries.geojson")):
        doc = json.loads(source(folder, name, NATURAL_EARTH).read_text(encoding="utf-8"))
        shapes = []
        for f in doc["features"]:
            props, geom = f["properties"], f["geometry"]
            code = props.get("ISO_A2_EH") or props.get("ISO_A2") or ""
            polys = geom["coordinates"] if geom["type"] == "MultiPolygon" else [geom["coordinates"]]
            rings = []
            for poly in polys:
                ring = [[round(x, 2), round(y, 2)] for x, y in poly[0]]       # the outer ring; lakes inside don't matter here
                if len(ring) >= 4:
                    rings.append(ring)
            shapes.append({"cc": code if len(code) == 2 and code != "-9" else "", "name": props.get("NAME") or "",
                           "rings": rings})
        out[key] = shapes
    data = json.dumps(out, separators=(",", ":")).encode("utf-8")
    buf = io.BytesIO()
    with gzip.GzipFile(fileobj=buf, mode="wb", mtime=0) as g:
        g.write(data)
    (OUT / "world.json.gz").write_bytes(buf.getvalue())
    print(f"world.json.gz: {len(out['110'])} + {len(out['50'])} countries, {len(buf.getvalue()) / 1e6:.2f} MB")


if __name__ == "__main__":
    folder = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(tempfile.mkdtemp(prefix="geo-"))
    build_places(folder)
    build_world(folder)
