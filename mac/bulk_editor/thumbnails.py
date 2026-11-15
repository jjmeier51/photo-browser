"""Thumbnail engine — the Mac twin of the iOS `Thumbnailer`.

Memory cache (dict, bounded) + disk cache (~/Library/Caches/PhotoBrowserMac/thumbs), keyed by the
SHA-256 of `path|mtime|size` so an in-place edit misses the old entry and regenerates. Generation
runs on a thread pool: Pillow (with pillow-heif for HEIC when installed, EXIF orientation applied)
for images; for video, macOS's own QuickLook (`qlmanage`) or ffmpeg when present, else a placeholder.
"""

from __future__ import annotations

import hashlib
import os
import shutil
import subprocess
import sys
import tempfile
from collections import OrderedDict

from PySide6.QtCore import QObject, QRunnable, QThreadPool, Signal, Qt
from PySide6.QtGui import QImage, QPixmap

from .library import Entry, cache_dir

THUMB_PX = 384

try:
    from PIL import Image, ImageOps
    try:
        import pillow_heif  # type: ignore
        pillow_heif.register_heif_opener()
        HEIF_OK = True
    except Exception:  # pragma: no cover - optional
        HEIF_OK = False
    PIL_OK = True
except Exception:  # pragma: no cover - optional
    PIL_OK = False
    HEIF_OK = False


def _thumb_dir() -> str:
    d = cache_dir() / "thumbs"
    d.mkdir(parents=True, exist_ok=True)
    return str(d)


def _key(entry: Entry) -> str:
    return hashlib.sha256(entry.cache_key.encode("utf-8")).hexdigest()


def _disk_path(entry: Entry) -> str:
    return os.path.join(_thumb_dir(), _key(entry) + ".jpg")


def _generate_image(path: str, out: str) -> bool:
    if not PIL_OK:
        return False
    try:
        with Image.open(path) as im:
            im.draft("RGB", (THUMB_PX * 2, THUMB_PX * 2))     # cheap JPEG downscale on decode
            im = ImageOps.exif_transpose(im)
            im.thumbnail((THUMB_PX, THUMB_PX), Image.Resampling.LANCZOS)
            if im.mode not in ("RGB", "L"):
                im = im.convert("RGB")
            im.save(out, "JPEG", quality=85, optimize=True)
        return True
    except Exception:
        return False


def _generate_video(path: str, out: str) -> bool:
    # macOS: QuickLook renders any movie frame the system can play (HEVC, HDR, ProRes…).
    if sys.platform == "darwin" and shutil.which("qlmanage"):
        with tempfile.TemporaryDirectory() as td:
            try:
                subprocess.run(["qlmanage", "-t", "-s", str(THUMB_PX), "-o", td, path],
                               capture_output=True, timeout=60)
            except (OSError, subprocess.SubprocessError):
                return False
            made = [f for f in os.listdir(td) if f.endswith(".png")]
            if made and PIL_OK:
                try:
                    with Image.open(os.path.join(td, made[0])) as im:
                        im.convert("RGB").save(out, "JPEG", quality=85)
                    return True
                except Exception:
                    return False
    ff = shutil.which("ffmpeg")
    if ff:
        try:
            subprocess.run([ff, "-y", "-loglevel", "error", "-ss", "1", "-i", path, "-frames:v", "1",
                            "-vf", f"scale={THUMB_PX}:-2", out], capture_output=True, timeout=60)
            return os.path.exists(out) and os.path.getsize(out) > 0
        except (OSError, subprocess.SubprocessError):
            return False
    return False


def generate(entry: Entry) -> QImage | None:
    """Blocking: returns the thumbnail (from disk if cached, else generated + cached)."""
    dp = _disk_path(entry)
    if os.path.exists(dp):
        img = QImage(dp)
        if not img.isNull():
            return img
    ok = _generate_video(entry.path, dp) if entry.kind == "video" else _generate_image(entry.path, dp)
    if not ok:
        return None
    img = QImage(dp)
    return None if img.isNull() else img


class _Emitter(QObject):
    ready = Signal(str, QImage)     # entry.path, image (null on failure)


class _Job(QRunnable):
    def __init__(self, entry: Entry, emitter: _Emitter):
        super().__init__()
        self.entry = entry
        self.emitter = emitter
        self.setAutoDelete(True)

    def run(self):
        img = generate(self.entry)
        self.emitter.ready.emit(self.entry.path, img if img is not None else QImage())


class Thumbnailer(QObject):
    """Async front door: `request(entry)` → later `ready(path, pixmap)`; `cached(entry)` for a hit."""
    ready = Signal(str, QPixmap)

    def __init__(self, parent: QObject | None = None, max_memory: int = 1500):
        super().__init__(parent)
        self._memory: OrderedDict[str, QPixmap] = OrderedDict()
        self._max = max_memory
        self._inflight: set[str] = set()
        self._pool = QThreadPool(self)
        self._pool.setMaxThreadCount(max(2, min(6, os.cpu_count() or 4)))
        self._emitter = _Emitter()
        self._emitter.ready.connect(self._on_ready, Qt.QueuedConnection)
        self._keys: dict[str, str] = {}

    def cached(self, entry: Entry) -> QPixmap | None:
        pm = self._memory.get(entry.cache_key)
        if pm is not None:
            self._memory.move_to_end(entry.cache_key)
        return pm

    def request(self, entry: Entry):
        if entry.cache_key in self._memory or entry.cache_key in self._inflight:
            return
        self._inflight.add(entry.cache_key)
        self._keys[entry.path] = entry.cache_key
        self._pool.start(_Job(entry, self._emitter))

    def _on_ready(self, path: str, img: QImage):
        key = self._keys.pop(path, None)
        if key:
            self._inflight.discard(key)
        pm = QPixmap.fromImage(img) if not img.isNull() else QPixmap()
        if key and not pm.isNull():
            self._memory[key] = pm
            while len(self._memory) > self._max:
                self._memory.popitem(last=False)
        self.ready.emit(path, pm)

    def clear_memory(self):
        self._memory.clear()

    def pending(self) -> int:
        return len(self._inflight)
