"""Collages for Photo Browser for Mac — two to nine photos on one picture (collage_window.py is the window).

- **Layouts** (`layouts(n)`): for each number of photos, every sensible arrangement in rows and in columns —
  even grids, strips, and "one large, the rest small" — a few dozen each, most balanced first. A layout is a
  list of cells, each (x, y, w, h) in a unit square, so it fits any shape.
- **Shapes** (`SHAPES`): square, the portrait and landscape ratios, stories, banners, print sizes (4×6, 5×7,
  8×10, A4, Letter) and the usual screens — and `SIZES`, the long side in pixels.
- **`render`**: each photo fills its cell (cropped, never stretched), where it's been slid and zoomed (`View`);
  spacing between, a margin round, rounded corners; on a colour or on one of the photos, blurred.
- **`save`**: JPEG, HEIC or PNG, standard colours (each photo converted from its own profile; an HDR one
  tone-mapped — thumb_color.py). The collage takes **the oldest photo's capture date** (in its metadata and as
  the file's dates) and that photo's place; the window gives it every photo's tags.

No Qt here.
"""
from __future__ import annotations

import io
import os
import tempfile
import time
from dataclasses import dataclass, field
from datetime import datetime

from PIL import Image, ImageDraw, ImageFilter, ImageOps

import app_identity

try:
    import pillow_heif  # type: ignore
    pillow_heif.register_heif_opener()
    HEIC = True
except Exception:  # noqa: BLE001 — without it there's no HEIC, in or out
    HEIC = False

COLLAGE_TAG = "collage"
MIN_PHOTOS, MAX_PHOTOS = 2, 9
MOST_LAYOUTS = 40                        # per number of photos: the most balanced of the hundreds there are
Rect = tuple[float, float, float, float]

SHAPES: list[tuple[str, str, float]] = [                 # group, name, width / height
    ("Square", "1:1 Square", 1.0),
    ("Portrait", "4:5 Portrait", 4 / 5), ("Portrait", "3:4", 3 / 4), ("Portrait", "2:3", 2 / 3),
    ("Portrait", "9:16 Story", 9 / 16), ("Portrait", "1:2 Tall", 1 / 2), ("Portrait", "1:3 Strip", 1 / 3),
    ("Landscape", "5:4", 5 / 4), ("Landscape", "4:3", 4 / 3), ("Landscape", "3:2", 3 / 2),
    ("Landscape", "16:9 Widescreen", 16 / 9), ("Landscape", "2:1 Wide", 2.0), ("Landscape", "21:9 Cinema", 21 / 9),
    ("Landscape", "3:1 Banner", 3.0),
    ("Print", "4 × 6 in", 6 / 4), ("Print", "6 × 4 in (upright)", 4 / 6), ("Print", "5 × 7 in", 7 / 5),
    ("Print", "7 × 5 in (upright)", 5 / 7), ("Print", "8 × 10 in", 10 / 8), ("Print", "10 × 8 in (upright)", 8 / 10),
    ("Print", "A4 upright", 210 / 297), ("Print", "A4 sideways", 297 / 210), ("Print", "Letter upright", 8.5 / 11),
    ("Print", "Letter sideways", 11 / 8.5),
    ("Screens", "Instagram post (4:5)", 1080 / 1350), ("Screens", "Instagram story", 1080 / 1920),
    ("Screens", "Facebook cover", 851 / 315), ("Screens", "X header", 1500 / 500),
    ("Screens", "YouTube thumbnail", 1280 / 720), ("Screens", "Pinterest pin", 1000 / 1500),
    ("Screens", "Mac desktop (16:10)", 16 / 10), ("Screens", "iPhone wallpaper", 1290 / 2796),
]
SIZES = [1080, 1600, 2048, 3000, 4096, 6000, 8192]         # the long side, in pixels
FORMATS = [("JPEG", ".jpg"), ("HEIC", ".heic"), ("PNG", ".png")]


# ----------------------------------------------------------------------------- layouts

@dataclass(frozen=True)
class Layout:
    name: str
    cells: tuple[Rect, ...]


def _compositions(n: int, parts: int, most: int):
    """Every way to write n as `parts` numbers from 1 to `most`, in order."""
    if parts == 1:
        if 1 <= n <= most:
            yield (n,)
        return
    for first in range(1, min(most, n - parts + 1) + 1):
        for rest in _compositions(n - first, parts - 1, most):
            yield (first,) + rest


def _bands(counts: tuple[int, ...], weights: tuple[float, ...], rows: bool) -> tuple[Rect, ...]:
    total = sum(weights)
    cells: list[Rect] = []
    at = 0.0
    for count, weight in zip(counts, weights):
        size = weight / total
        for i in range(count):
            cells.append((i / count, at, 1 / count, size) if rows else (at, i / count, size, 1 / count))
        at += size
    return tuple(cells)


_made: dict[int, list[Layout]] = {}


def layouts(n: int) -> list[Layout]:
    """The layouts for `n` photos (2…9), most balanced first."""
    if n in _made:
        return _made[n]
    seen: set[tuple] = set()
    ranked: list[tuple[float, Layout]] = []

    def add(name: str, cells: tuple[Rect, ...], rank: float) -> None:
        key = tuple(sorted(tuple(round(v, 4) for v in c) for c in cells))
        if key not in seen:
            seen.add(key)
            ranked.append((rank, Layout(name, cells)))

    for parts in range(1, min(n, 4) + 1):
        for counts in _compositions(n, parts, 5 if parts == 1 and n <= 5 else 4):
            uneven = max(counts) - min(counts)
            for rows in (True, False):
                word = "rows" if rows else "columns"
                label = " + ".join(str(c) for c in counts)
                if parts == 1:
                    add(f"{n} across" if rows else f"{n} down", _bands(counts, (1.0,), rows), 0.0 if n <= 3 else 1.5)
                    continue
                add(f"{label} in {word}", _bands(counts, (1.0,) * parts, rows), parts * 0.1 + uneven)
                if max(counts) == 1 and parts <= 3:           # a strip split unevenly: one photo twice the others
                    for big in (0, parts - 1):
                        weights = tuple(2.0 if i == big else 1.0 for i in range(parts))
                        add(f"{label} in {word}, {'first' if big == 0 else 'last'} large",
                            _bands(counts, weights, rows), 0.5 + 0.1 * big)
                if 1 in counts and max(counts) > 1:           # the lone photo, large
                    weights = tuple(1.0 if c > 1 else 1.9 for c in counts)
                    add(f"{label} in {word}, large", _bands(counts, weights, rows), parts * 0.1 + uneven + 0.4)
                elif uneven:                                  # the emptier band taller, so its photos aren't slivers
                    weights = tuple(1.0 + 0.35 * (max(counts) - c) for c in counts)
                    add(f"{label} in {word}, evened", _bands(counts, weights, rows), parts * 0.1 + uneven + 0.2)
    if n >= 6:                                                # strips of six and more: for the long shapes
        add(f"{n} across", _bands((n,), (1.0,), True), 1.6)
        add(f"{n} down", _bands((n,), (1.0,), False), 1.6)
    if n in (6, 8):                                           # one large photo, the rest along two of its sides
        k = n // 2
        t = 1 / k
        big = (k - 1) * t
        cells = [(0.0, 0.0, big, big)] + [(big, i * t, t, t) for i in range(k)] + [(i * t, big, t, t) for i in range(k - 1)]
        add(f"One large, {n - 1} round it", tuple(cells), 0.6)
    ranked.sort(key=lambda r: r[0])
    _made[n] = [layout for _rank, layout in ranked][:MOST_LAYOUTS]
    return _made[n]


# ----------------------------------------------------------------------------- photos

@dataclass
class View:
    """How a photo sits in its cell: zoomed in by `zoom` (1 = just filling it) around (x, y) of the photo."""
    zoom: float = 1.0
    x: float = 0.5
    y: float = 0.5


def open_photo(path: str, longest: int = 0) -> Image.Image:
    """The photo upright, in standard colours, RGB — at most `longest` on its long side (0: all of it)."""
    im = Image.open(path)
    if longest and im.format == "JPEG":
        im.draft("RGB", (longest, longest))                   # a JPEG can be decoded small: much faster
    im.load()
    icc = im.info.get("icc_profile")
    im = ImageOps.exif_transpose(im) or im
    if icc:
        im.info["icc_profile"] = icc
    if longest and max(im.size) > longest:
        s = longest / max(im.size)
        im = im.resize((max(1, round(im.width * s)), max(1, round(im.height * s))), Image.Resampling.LANCZOS,
                       reducing_gap=2.0)
        if icc:
            im.info["icc_profile"] = icc
    try:
        import thumb_color
        im = thumb_color.standard(im, path)
    except Exception:  # noqa: BLE001 — colours as they came
        pass
    if im.mode in ("RGBA", "LA", "PA") or (im.mode == "P" and "transparency" in im.info):
        flat = Image.new("RGB", im.size, (255, 255, 255))
        flat.paste(im.convert("RGBA"), mask=im.convert("RGBA").getchannel("A"))
        return flat
    return im.convert("RGB")


def can_use(path: str) -> bool:
    ext = os.path.splitext(path)[1].lower()
    return ext in {".jpg", ".jpeg", ".png", ".tif", ".tiff", ".webp", ".bmp", ".gif"} or (HEIC and ext in {".heic", ".heif"})


def canvas_size(ratio: float, long_side: int) -> tuple[int, int]:
    return (long_side, max(1, round(long_side / ratio))) if ratio >= 1 else (max(1, round(long_side * ratio)), long_side)


def cell_boxes(layout: Layout, w: int, h: int, margin: float, spacing: float) -> list[tuple[int, int, int, int]]:
    """Each cell in pixels (left, top, right, bottom). `margin` and `spacing` are % of the short side."""
    short = min(w, h)
    m, s = margin / 100.0 * short, spacing / 100.0 * short
    ax, ay, aw, ah = m - s / 2, m - s / 2, w - 2 * m + s, h - 2 * m + s
    out = []
    for x, y, cw, ch in layout.cells:
        left, top = ax + x * aw + s / 2, ay + y * ah + s / 2
        right, bottom = ax + (x + cw) * aw - s / 2, ay + (y + ch) * ah - s / 2
        out.append((round(left), round(top), max(round(left) + 1, round(right)), max(round(top) + 1, round(bottom))))
    return out


def crop_box(photo: tuple[int, int], cell: tuple[int, int], view: View) -> tuple[float, float, float, float]:
    """The part of a photo (left, top, right, bottom, in its pixels) that fills a cell of that size."""
    pw, ph = photo
    cw, ch = cell
    aspect = cw / ch
    bw = min(pw, ph * aspect) / max(1.0, view.zoom)
    bh = bw / aspect
    cx = min(max(view.x * pw, bw / 2), pw - bw / 2)
    cy = min(max(view.y * ph, bh / 2), ph - bh / 2)
    left, top = max(0.0, cx - bw / 2), max(0.0, cy - bh / 2)         # (rounding mustn't put it a hair outside)
    return left, top, min(float(pw), left + bw), min(float(ph), top + bh)


@dataclass
class Design:
    layout: Layout
    ratio: float = 1.0
    margin: float = 2.0                     # % of the short side
    spacing: float = 1.5
    corner: float = 0.0                     # % of the short side
    colour: tuple[int, int, int] = (255, 255, 255)
    blur_back: bool = False                 # the first photo, blurred, instead of the colour
    views: list[View] = field(default_factory=list)


def render(photos: list[Image.Image], d: Design, long_side: int) -> Image.Image:
    """The collage, `long_side` pixels on its long side."""
    w, h = canvas_size(d.ratio, long_side)
    if d.blur_back and photos:
        back = ImageOps.fit(photos[0], (max(8, w // 8), max(8, h // 8)), Image.Resampling.BILINEAR)
        back = back.filter(ImageFilter.GaussianBlur(max(2, min(w, h) // 160)))
        canvas = back.resize((w, h), Image.Resampling.BICUBIC).point(lambda v: int(v * 0.8))
    else:
        canvas = Image.new("RGB", (w, h), tuple(d.colour))
    radius = d.corner / 100.0 * min(w, h)
    for i, (box, photo) in enumerate(zip(cell_boxes(d.layout, w, h, d.margin, d.spacing), photos)):
        cw, ch = box[2] - box[0], box[3] - box[1]
        view = d.views[i] if i < len(d.views) else View()
        piece = photo.resize((cw, ch), Image.Resampling.LANCZOS, box=crop_box(photo.size, (cw, ch), view),
                             reducing_gap=2.0)
        if radius >= 1:
            mask = Image.new("L", (cw * 2, ch * 2), 0)
            ImageDraw.Draw(mask).rounded_rectangle((0, 0, cw * 2 - 1, ch * 2 - 1), radius=min(radius * 2, cw, ch), fill=255)
            canvas.paste(piece, box[:2], mask.resize((cw, ch), Image.Resampling.LANCZOS))
        else:
            canvas.paste(piece, box[:2])
    return canvas


def sharpest_size(photos: list[tuple[int, int]], d: Design) -> int:
    """The largest long side at which no photo is enlarged past its own pixels (among SIZES' range)."""
    best = SIZES[-1]
    for trial in (8192, 6000, 4096, 3000, 2048, 1600, 1080):
        w, h = canvas_size(d.ratio, trial)
        ok = True
        for i, (box, size) in enumerate(zip(cell_boxes(d.layout, w, h, d.margin, d.spacing), photos)):
            l, t, r, b = crop_box(size, (box[2] - box[0], box[3] - box[1]), d.views[i] if i < len(d.views) else View())
            if (r - l) < (box[2] - box[0]) * 0.92:
                ok = False
                break
        best = trial
        if ok:
            break
    return best


# ----------------------------------------------------------------------------- saving

@dataclass
class Source:
    """What the collage inherits: the oldest photo's date and place, and its file dates."""
    path: str = ""
    taken: float = 0.0                      # unix: the capture date — 0 when no photo knows its own
    place: tuple[float, float] | None = None
    stat: os.stat_result | None = None
    file_date: float = 0.0                  # the date the file itself gets (the capture date, else the earliest file date)


def oldest(paths: list[str]) -> Source:
    """The photo with the earliest **capture** date — a photo that knows when it was taken always counts before
    one that only has a file date (a download's file date can be older than everything) — and the place of the
    earliest photo that has one. When no photo has a capture date the collage is given none either; its file
    takes the earliest file date."""
    import media_info
    rows = []
    for p in paths:
        try:
            info = media_info.image_info(p)
        except Exception:  # noqa: BLE001
            info = {}
        try:
            st = os.stat(p)
        except OSError:
            continue
        taken = float(info.get("taken") or 0)
        file_date = min(st.st_mtime, getattr(st, "st_birthtime", st.st_mtime))
        rows.append((not taken, taken or file_date, p, st, info.get("place"), taken))
    if not rows:
        return Source()
    rows.sort(key=lambda r: (r[0], r[1]))
    first = rows[0]
    place = next((r[4] for r in rows if r[4]), None)
    return Source(first[2], first[5], tuple(place) if place else None, first[3], first[1])


def _exif(src: Source, w: int, h: int) -> bytes:
    ex = Image.Exif()
    ex[0x0131] = app_identity.APP_NAME                       # Software
    ex[0x0112] = 1
    if src.taken:
        when = datetime.fromtimestamp(src.taken).strftime("%Y:%m:%d %H:%M:%S")
        ex[0x0132] = when
        sub = ex.get_ifd(0x8769)
        sub[0x9003] = when
        sub[0x9004] = when
        sub[0xA002], sub[0xA003] = w, h
    if src.place:
        lat, lon = src.place

        def dms(v: float):
            v = abs(v)
            d = int(v)
            m = int((v - d) * 60)
            return (float(d), float(m), round((v - d - m / 60) * 3600, 4))
        gps = ex.get_ifd(0x8825)
        gps[1], gps[2] = ("N" if lat >= 0 else "S"), dms(lat)
        gps[3], gps[4] = ("E" if lon >= 0 else "W"), dms(lon)
    return ex.tobytes()


def encode(im: Image.Image, fmt: str, src: Source) -> bytes:
    from PIL import ImageCms
    out = io.BytesIO()
    exif = _exif(src, *im.size)
    icc = ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes()
    if fmt == "PNG":
        im.save(out, format="PNG", exif=exif, icc_profile=icc, compress_level=6)
    elif fmt == "HEIC":
        if not HEIC:
            raise OSError("HEIC needs pillow-heif (run mac/run.sh once)")
        im.save(out, format="HEIF", quality=92, exif=exif, icc_profile=icc)
    else:
        im.save(out, format="JPEG", quality=95, subsampling=0, exif=exif, icc_profile=icc)
    data = out.getvalue()
    with Image.open(io.BytesIO(data)) as check:               # what's written opens, at its size
        check.load()
        if check.size != im.size:
            raise OSError("the collage came out the wrong size")
    return data


def new_path(folder: str, src: Source, ext: str) -> str:
    """“Collage 2024-07-04.jpg” in `folder` (the oldest photo's day), never a name that's taken."""
    day = time.strftime("%Y-%m-%d", time.localtime(src.taken or src.file_date or time.time()))
    n = 1
    while True:
        path = os.path.join(folder, f"Collage {day}{'' if n == 1 else f' {n}'}{ext}")
        if not os.path.lexists(path):
            return path
        n += 1


def save(im: Image.Image, folder: str, fmt: str, src: Source) -> str:
    """Writes the collage into `folder`; returns its path. The file's dates are the oldest photo's."""
    import net_fetch
    import spare_folders
    data = encode(im, fmt, src)
    dest = new_path(folder, src, dict(FORMATS)[fmt])
    fd, tmp = tempfile.mkstemp(prefix="collage-", suffix=dict(FORMATS)[fmt])
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
        net_fetch.put(tmp, dest, spare_folders.on_exfat(folder))
    finally:
        try:
            os.unlink(tmp)
        except OSError:
            pass
    when = src.taken or src.file_date
    if when:
        try:
            import clone_drive
            ns = int(when * 1e9)
            if not (clone_drive.IS_MAC and clone_drive.set_dates(dest, ns, ns, ns)):
                os.utime(dest, (when, when))
        except Exception:  # noqa: BLE001 — the date in the metadata is the one that counts
            try:
                os.utime(dest, (when, when))
            except OSError:
                pass
    return dest


def needed_side(design: "Design", long_side: int) -> int:
    """The most pixels any photo needs on its long side for a collage this size (so nine 48 MP photos aren't
    all opened whole for a 1,080 px collage). 0: open it whole."""
    zoom = max([v.zoom for v in design.views] + [1.0])
    need = int(long_side * 1.6 * zoom)                 # a cell can be the whole canvas; a photo can be cropped to half
    return 0 if need >= 12000 else need


def clamped(view: View, photo: tuple[int, int], cell: tuple[int, int]) -> View:
    """The view with its centre where the photo can actually be — so a slide past the edge has no dead travel
    on the way back."""
    l, t, r, b = crop_box(photo, cell, view)
    return View(view.zoom, (l + r) / 2 / photo[0], (t + b) / 2 / photo[1])
