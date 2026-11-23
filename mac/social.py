"""What Photo Browser for Mac's Instagram and Facebook downloaders share — no Qt here (social_downloader.py is the
window; instagram.py and facebook.py read the two sites).

**The shared record.** Each profile folder holds a hidden record — `.instagram.json` / `.facebook.json` —
listing every post id downloaded into it, the profile's handle (or name) and numeric id, and when it was
last brought up to date. The iPhone app reads and writes the same file (`SocialRecord.swift`), so a post
either app downloaded is never fetched again by the other — and neither is one deleted from the folder
afterwards, which the files alone couldn't say. Both apps also take the file names in the folder as done
(the names are the post ids, the same on both sides), so a folder with no record still dedups. A save
re-reads the file and merges (ids are added up, never dropped; the photo/video counts get this run's
additions), and fields the other app writes are kept.

**A download, start to finish** (`settle`, on a worker thread): the file is fetched into the Mac's temp
folder (a plain request, logged out first and with the session's cookies if that's refused — public media
is served to anyone, a private profile's isn't); an Instagram DASH video is fetched as its two halves and
put together (`video_tools.mux`); a photo Instagram serves as WebP/HEIC becomes the JPEG its name says;
the upscales asked for are done (photos 2× — Real-ESRGAN when chosen and installed, else Lanczos with a
light sharpen, like the iPhone's; videos to 1080p); the post's date, place, caption and poster go into the
file (ExifTool, when it's installed — the file dates are set either way); then it's placed in the profile's
folder, never over a file that's there.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import tempfile
import time
from dataclasses import dataclass, field
from pathlib import Path

import simpcity as sc

UPSCALED_TAG = "upscaled"
EXCLUSIVE_TAG = "exclusive"           # subscriber-only ("Exclusive") posts, stories and photos — both sites
UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) "
      "Chrome/122.0.0.0 Safari/537.36")
MIN_BYTES = 512                       # anything smaller is an error page, not a photo or a video
MIN_DATE = 1_072_915_200              # 2004-01-01: no post is older; a time below this is a misread
_DATE = "%Y:%m:%d %H:%M:%S"


@dataclass
class Item:
    """One photo or video to download."""
    key: str                          # the post's id: what the record and the file name are made of
    folder: Path                      # where it goes on the drive
    name: str                         # the file name, without the extension
    video: bool
    url: str
    ext: str = ""                     # the extension ("" → jpg / mp4)
    audio: str | None = None          # a DASH video's audio half, put together with `url`
    fallback: str | None = None       # the one-file video, if putting the halves together fails
    date: float = 0                   # when it was posted (unix time)
    lat: float | None = None
    lng: float | None = None
    caption: str = ""
    poster: str = ""                  # who posted it ("@handle" for Instagram, a name for Facebook)
    keyword: str = ""                 # an IPTC keyword ("Instagram"), as the iPhone writes
    exclusive: bool = False           # subscriber-only content: tagged "exclusive" as well

    @property
    def filename(self) -> str:
        return f"{self.name}.{self.ext or ('mp4' if self.video else 'jpg')}"


@dataclass
class Options:
    photos_2x: bool = False           # upscale photos 2×
    ai: bool = False                  # …with Real-ESRGAN (ai_upscale.py) rather than Lanczos
    videos_1080: bool = False         # upscale videos below 1080p to 1080p
    tagged: bool = True               # Instagram: posts the profile is tagged in (Facebook always takes them)
    stories: bool = True              # Instagram: current stories and highlights
    upscale_under: int = 0            # photos smaller than this (bytes) are upscaled 2× whatever photos_2x says
    full: bool = False                # Facebook: walk every set to its end, even one read before
    exclusive_only: bool = False      # Facebook: only the subscriber-only (Exclusive) content — the Subscriber Hub
    exclusive: bool = True            # Facebook: look for subscriber-only content at all (off: straight to the photos)
    method: str = ""                  # how photos are enlarged (upscale_methods: "ai:<model>", "clean", "sharp", "soft");
    factor: int = 2                   #   "" = as before (the AI's default model, else Sharp); how many times larger;
    texture: float = 0.0              #   and, for an AI method, how much of the plain enlargement is kept


@dataclass
class Settled:
    item: Item
    path: str = ""                    # where it landed ("" when it didn't)
    upscaled: bool = False
    why: str = ""                     # why it didn't
    present: bool = False             # a file of that name was already there: done, not fetched again
    small: bool = False               # upscaled because it was under `Options.upscale_under`


# ----------------------------------------------------------------------------- the shared record

@dataclass
class Record:
    """A profile folder's `.instagram.json` / `.facebook.json` — see the module notes."""
    folder: Path
    name: str                         # ".instagram.json"
    form: str                         # "photobrowser-instagram"
    fields: dict = field(default_factory=dict)
    downloaded: set[str] = field(default_factory=set)

    @property
    def file(self) -> Path:
        return self.folder / self.name

    @classmethod
    def load(cls, folder: str | Path, name: str, form: str) -> "Record":
        rec = cls(Path(folder), name, form)
        rec.state = "missing"
        doc = rec._read()
        rec.fields = {k: v for k, v in doc.items() if k != "downloaded"}
        rec.downloaded = {str(x) for x in doc.get("downloaded") or [] if isinstance(x, (str, int))}
        return rec

    def _read(self) -> dict:
        """The record on the drive — from the copy kept before its last save when it can't be read (`state`)."""
        import net_fetch
        doc, self.state = net_fetch.load_json(self.file)
        return doc if doc.get("format") == self.form else {}

    @property
    def exists(self) -> bool:
        return bool(self.fields)

    def get(self, key: str, default=None):
        return self.fields.get(key, default)

    def save(self, done: set[str], photos: int = 0, videos: int = 0, **info) -> None:
        """Adds `done` to the downloaded ids and this run's counts, sets `info` (handle, ids…) — merged
        into whatever the file says now, which the other app may have changed since it was read."""
        doc = self._read()
        ids = {str(x) for x in doc.get("downloaded") or [] if isinstance(x, (str, int))} | self.downloaded | set(done)
        out = {**{k: v for k, v in doc.items() if k != "downloaded"}, **{k: v for k, v in info.items() if v not in (None, "")}}
        out["format"] = self.form
        out["version"] = max(1, int(out.get("version") or 1))
        out["last_updated"] = max(float(doc.get("last_updated") or 0), time.time())
        out["photos"] = int(doc.get("photos") or 0) + photos
        out["videos"] = int(doc.get("videos") or 0) + videos
        out["downloaded"] = sorted(ids)
        self.folder.mkdir(parents=True, exist_ok=True)
        import net_fetch
        net_fetch.keep_backup(self.file)               # the last good record, should this save be cut off
        sc.write_file(self.file, json.dumps(out, ensure_ascii=False, indent=1).encode("utf-8"))
        self.fields = {k: v for k, v in out.items() if k != "downloaded"}
        self.downloaded = ids


# ----------------------------------------------------------------------------- subscriber-only ("Exclusive") content

# What Instagram and Facebook call a post only subscribers may see isn't documented, and changes. So no one key is
# trusted: a key on the post's *own* object (never on a nested person — "is_subscribed" there says whether the
# viewer subscribes, which is true of every post by that creator) whose name says the content is for subscribers,
# set to true or to a value naming them. Keys that describe the viewer or a button are not such a name.
_EXCLUSIVE_KEY = re.compile(r"(subscribers?_?only|subscriber_?content|subscription_?(?:only|content|post|media)|"
                            r"exclusive|fan_?club_?(?:only|content|post|media)|for_?subscribers|supporters?_?only|"
                            r"paid_?content|is_?subscriber_?post)", re.I)
_VIEWER_KEY = re.compile(r"(^|_)(viewer|can_|has_|is_subscribed|subscribe_|cta|button|eligib|upsell|count|status$)", re.I)
_AUDIENCE_KEY = re.compile(r"^(audience|visibility|privacy|privacy_?scope|access|content_?access)$", re.I)
_AUDIENCE_VALUE = re.compile(r"^(subscribers?(?:[ _-]?only)?|exclusive|fan_?club|supporters?(?:[ _-]?only)?|"
                             r"subscription|paid)$", re.I)
_LOCK_KEY = re.compile(r"^(is_?locked|locked|is_?blurred|is_?paywalled|requires_?subscription|is_?gated|gated|"
                       r"needs_?subscription)$", re.I)
_CAN_SEE_KEY = re.compile(r"^(can_?viewer_?see|viewer_?can_?see|can_?view|has_?access|is_?accessible|"
                          r"viewer_?has_?access|is_?unlocked)$", re.I)
_PERSON_KEYS = {"user", "owner", "author", "creator", "caption", "usertags", "coauthor_producers", "invited_coauthor_producers",
                "location", "music_metadata", "clips_metadata", "comments", "preview_comments", "likers", "facepile_top_likers"}


def _says_subscribers(key: str, value) -> bool:
    if value is True:
        return bool(_EXCLUSIVE_KEY.search(key)) and not _VIEWER_KEY.search(key)
    if isinstance(value, str) and value.strip():
        v = value.strip()
        if _AUDIENCE_KEY.match(key):
            return bool(_AUDIENCE_VALUE.match(v))
        if _EXCLUSIVE_KEY.search(key) and not _VIEWER_KEY.search(key):
            return v.lower() not in ("false", "0", "none", "public", "everyone", "all", "null")
    if isinstance(value, dict) and _AUDIENCE_KEY.match(key):              # {"privacy_scope": {"label": "Subscribers"}}
        return any(isinstance(x, str) and _AUDIENCE_VALUE.match(x.strip()) for x in value.values())
    return False


def is_exclusive(post: dict, depth: int = 0) -> bool:
    """Whether a post object (Instagram media, or any site's) is subscriber-only — by its own keys, its
    carousel's items' keys, never a nested person's."""
    if not isinstance(post, dict) or depth > 2:
        return False
    for k, v in post.items():
        if not isinstance(k, str) or k in _PERSON_KEYS:
            continue
        if _says_subscribers(k, v):
            return True
    for child in post.get("carousel_media") or []:
        if isinstance(child, dict) and is_exclusive(child, depth + 1):
            return True
    return False


def is_locked(post: dict) -> bool:
    """Whether the viewer may *not* see it: what comes is a blurred or cropped preview, never to be downloaded as
    the post (the person isn't subscribed)."""
    if not isinstance(post, dict):
        return False
    for k, v in post.items():
        if not isinstance(k, str) or k in _PERSON_KEYS:
            continue
        if _LOCK_KEY.match(k) and v is True:
            return True
        if _CAN_SEE_KEY.match(k) and v is False:
            return True
    return False


_TEXT_FLAG = re.compile(r'"([A-Za-z_]{4,60})"\s*:\s*(true|"[^"]{1,40}")')
_TEXT_LABEL = re.compile(r'"(?:label|text|title|description|audience_?label|privacy_?label)"\s*:\s*'
                         r'"(Subscribers?(?: only)?|Subscriber[- ]only|Exclusive|Exclusive for subscribers|'
                         r'For subscribers(?: only)?|Supporters(?: only)?)"', re.I)


def exclusive_in_text(page: str, media_id: str | None = None, near: int = 6000) -> bool:
    """A page's data (Facebook's photo pages embed their JSON in the HTML) says the media is subscriber-only — a
    flag as `is_exclusive` reads them, or a privacy label "Subscribers" — within `near` characters of the media's
    own id when one is given (a page also holds other posts)."""
    if not page:
        return False
    spans = []
    if media_id:
        for m in re.finditer(re.escape(media_id), page):
            spans.append((max(0, m.start() - near), m.end() + near))
            if len(spans) >= 12:
                break
        if not spans:
            return False
    else:
        spans = [(0, len(page))]
    for a, b in spans:
        part = page[a:b]
        for m in _TEXT_FLAG.finditer(part):
            key, raw = m.group(1), m.group(2)
            value = True if raw == "true" else raw.strip('"')
            if _says_subscribers(key, value):
                return True
        if _TEXT_LABEL.search(part):
            return True
    return False


# ----------------------------------------------------------------------------- fetching

def headers(referer: str, cookie: str = "", ua: str = UA) -> dict[str, str]:
    h = {"User-Agent": ua, "Referer": referer, "Accept": "*/*", "Accept-Language": "en-US,en;q=0.9"}
    if cookie:
        h["Cookie"] = cookie
    return h


def fetch(url: str, path: str, tries: list[dict[str, str]]) -> tuple[str | None, str]:
    """`url` into `path`, with each set of headers in turn (logged out, then with the session)."""
    why = "no address"
    for h in tries:
        got, why = sc.fetch(url, h, path, connect_timeout=30, limit=1800)
        if got and os.path.getsize(got) >= MIN_BYTES:
            return got, ""
        if got:
            why = "an empty file"
            os.remove(got)
    return None, why


def download(item: Item, tmp: str, tries: list[dict[str, str]]) -> tuple[str | None, str]:
    """The item in the temp folder: the file, or a DASH video's two halves put together (else the
    one-file version). Returns (path, "") or (None, why)."""
    out = os.path.join(tmp, item.filename)
    if item.video and item.audio:
        import video_tools
        from concurrent.futures import ThreadPoolExecutor
        # the picture and the sound at the same time (the CDN's files, not the API): they used to come one after
        # the other
        with ThreadPoolExecutor(max_workers=1) as side:
            sound = side.submit(fetch, item.audio, out + ".audio", tries)
            v, why = fetch(item.url, out + ".video", tries)
            a, why_a = sound.result()
        if not v and a:
            os.remove(a)
            a, why_a = None, why
        if v and a and video_tools.mux(v, a, out, item.date, item.lat, item.lng):
            for p in (v, a):
                os.remove(p)
            return out, ""
        for p in (v, a):
            if p and os.path.exists(p):
                os.remove(p)
        if not item.fallback:
            return None, why_a or why or "the two halves wouldn't go together"
        return fetch(item.fallback, out, tries)
    return fetch(item.url, out, tries)


# ----------------------------------------------------------------------------- photos

def as_jpeg(path: str) -> str:
    """A photo that came as WebP, HEIC or PNG (Instagram's CDN serves them under a .jpg address) made
    the JPEG its name says, colour profile kept; transparency goes onto white. Anything Pillow can't
    read is left as it is."""
    try:
        from PIL import Image
        import batch_crop                                      # registers HEIC with Pillow, when it can
    except ImportError:
        return path
    try:
        with Image.open(path) as im:
            if im.format == "JPEG":
                return path
            im.load()
            icc = im.info.get("icc_profile")
            out = im
            if out.mode not in ("RGB", "L"):
                rgba = out.convert("RGBA")
                flat = Image.new("RGB", rgba.size, (255, 255, 255))
                flat.paste(rgba, mask=rgba.split()[3])
                out = flat
            part = path + ".part"
            out.save(part, "JPEG", quality=95, subsampling=0, **({"icc_profile": icc} if icc else {}))
        os.replace(part, path)
    except (OSError, ValueError):
        pass
    return path


def upscale_photo(path: str, engine=None) -> bool:
    """2×, in place: Real-ESRGAN with `engine` (ai_upscale.py), else Lanczos with a light sharpen (the
    iPhone's "AI Upscale" for downloads is the same idea). Photos already over 12 MP are left alone."""
    if engine is not None:
        import ai_upscale
        try:
            ai_upscale.upscale(engine, path)
            return True
        except ai_upscale.Skipped:
            return False
        except (ai_upscale.UpscaleError, OSError):
            pass                                               # the engine failed: Lanczos instead
    try:
        from PIL import Image, ImageFilter
        import batch_crop
        src = batch_crop.open_upright(path)
        w, h = src.image.size
        if w * h > 12_300_000:
            return False
        big = src.image.resize((w * 2, h * 2), Image.Resampling.LANCZOS)
        big = big.filter(ImageFilter.UnsharpMask(radius=1.2, percent=60, threshold=2))
        data = batch_crop.encode_like(src, big)
        with open(path, "wb") as f:
            f.write(data)
        return True
    except Exception:  # noqa: BLE001 — a photo that can't be upscaled is kept as it came
        return False


# ----------------------------------------------------------------------------- what goes into the file

def write_meta(path: str, item: Item, tool) -> None:
    """The post's date (and place, caption, poster) into the file — EXIF (with its time zone)/IPTC for a
    photo, QuickTime for a video, as the iPhone app writes them — and the file's own dates set to the
    post's (an earlier modification date moves a Mac file's creation date back with it). A caption goes
    through a file (ExifTool takes one argument per line, and captions have line breaks)."""
    when = item.date if item.date and item.date >= MIN_DATE else 0
    args: list[str] = []
    caption_file = ""
    if tool is not None:
        if item.caption:
            fd, caption_file = tempfile.mkstemp(prefix="caption-", suffix=".txt")
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                f.write(item.caption[:1800])
        if item.video:
            if when:
                s = time.strftime(_DATE, time.localtime(when))
                tz = time.strftime("%z", time.localtime(when))
                args += ["-api", "QuickTimeUTC", f"-QuickTime:CreateDate={s}", f"-QuickTime:ModifyDate={s}",
                         f"-QuickTime:TrackCreateDate={s}", f"-QuickTime:MediaCreateDate={s}",
                         f"-Keys:CreationDate={s}{tz[:3]}:{tz[3:]}"]
            if valid_place(item.lat, item.lng):
                args.append(f"-Keys:GPSCoordinates={item.lat}, {item.lng}, 0")
            if caption_file:
                args.append(f"-Keys:Description<={caption_file}")
        else:
            if when:
                s = time.strftime(_DATE, time.localtime(when))
                z = time.strftime("%z", time.localtime(when))
                z = f"{z[:3]}:{z[3:]}"
                args += [f"-EXIF:DateTimeOriginal={s}", f"-EXIF:CreateDate={s}", f"-EXIF:ModifyDate={s}",
                         f"-EXIF:OffsetTimeOriginal={z}", f"-EXIF:OffsetTimeDigitized={z}", f"-EXIF:OffsetTime={z}"]
            if valid_place(item.lat, item.lng):
                args += [f"-GPSLatitude={abs(item.lat)}", f"-GPSLatitudeRef={'N' if item.lat >= 0 else 'S'}",
                         f"-GPSLongitude={abs(item.lng)}", f"-GPSLongitudeRef={'E' if item.lng >= 0 else 'W'}"]
            if item.poster:
                args += [f"-EXIF:Artist={item.poster}", f"-IPTC:By-line={item.poster}"]
            if caption_file:
                args.append(f"-IPTC:Caption-Abstract<={caption_file}")
            if item.keyword:
                args.append(f"-IPTC:Keywords={item.keyword}")
            if args:
                args = ["-IPTC:CodedCharacterSet=UTF8", *args]
        try:
            if args:
                tool.run("-m", "-overwrite_original_in_place", "-charset", "iptc=UTF8", "-api", "largefilesupport=1",
                         *args, path)
        finally:
            if caption_file:
                try:
                    os.remove(caption_file)
                except OSError:
                    pass
    if when:
        try:
            os.utime(path, (when, when))
        except OSError:
            pass


def valid_place(lat, lng) -> bool:
    try:
        return lat is not None and lng is not None and not (lat == 0 and lng == 0) and \
            -90 <= float(lat) <= 90 and -180 <= float(lng) <= 180
    except (TypeError, ValueError):
        return False


# ----------------------------------------------------------------------------- onto the drive

def place(src: str, folder: Path, name: str) -> str | None:
    """The finished file into the profile's folder under `name` — never over a file that's there (that
    one is the post, already downloaded: None). Copy, flush, rename; on exFAT straight in (CLAUDE.md #12)."""
    sc.make_folder(folder)
    dest = folder / name
    if os.path.lexists(dest):
        return None
    st = os.stat(src)
    import net_fetch
    net_fetch.put(src, dest, sc._on_exfat(str(folder)))   # whole or not there: a failed copy leaves no partial
    os.utime(dest, (st.st_atime, st.st_mtime))
    try:
        os.remove(src)
    except OSError:
        pass
    return str(dest)


def settle(item: Item, tries: list[dict[str, str]], opts: Options, tool=None, engine=None,
           heavy=None, fetcher=None) -> Settled:
    """One item, from the web to its folder (see the module notes). `heavy` (a lock) keeps the upscales
    to one at a time — they hold whole photos and videos in memory. `fetcher(item, tmp, tries)` replaces
    `download` (Fanfix's streamed videos). Runs on a worker thread."""
    if os.path.lexists(item.folder / item.filename):
        return Settled(item, str(item.folder / item.filename), present=True)
    tmp = tempfile.mkdtemp(prefix="photo-browser-social-")
    try:
        path, why = (fetcher or download)(item, tmp, tries)
        if not path:
            return Settled(item, why=why)
        upscaled = small = False
        if not item.video:
            if (item.ext or "jpg") == "jpg":
                path = as_jpeg(path)
            small = bool(opts.upscale_under) and os.path.getsize(path) < opts.upscale_under
            if opts.photos_2x or small:
                with heavy or _NoLock():
                    if opts.method:
                        import upscale_methods
                        upscaled = upscale_methods.upscale_file(path, opts.method, opts.factor, opts.texture, engine)
                    else:
                        upscaled = upscale_photo(path, engine if opts.ai else None)
        elif opts.videos_1080:
            import video_tools
            with heavy or _NoLock():
                upscaled = video_tools.upscale_1080(path) == "upscaled"
        write_meta(path, item, tool)
        dest = place(path, item.folder, item.filename)
        if dest is None:
            return Settled(item, str(item.folder / item.filename), present=True)
        return Settled(item, dest, upscaled, small=small and upscaled)
    except OSError as e:
        return Settled(item, why=str(e))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


class _NoLock:
    def __enter__(self):
        return self

    def __exit__(self, *exc) -> bool:
        return False


def sanitize(name: str, fallback: str, limit: int) -> str:
    """A folder name from a title: the characters a path can't hold become "-" (as the iPhone does)."""
    out = "".join("-" if c in '/\\:?%*|"<>' else c for c in name).strip()
    return out[:limit] if out else fallback
