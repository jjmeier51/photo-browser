"""The viewer's picture drawn by macOS itself (`viewer_surface.swift`), for `media_viewer`.

Qt Multimedia decodes video with FFmpeg (Qt 6.5+) and maps HDR to standard range with its own shaders, so an HDR
video looked brighter and harsher in Safe Finder than in QuickTime Player; and Qt reads only an HDR photo's
standard-range picture. The surface shows a video with AVFoundation — QuickTime's own player, real HDR on a
display that has the headroom — and an HDR photo through Core Image onto a layer that asks for HDR (EDR).

It's a small Swift library built once with `swiftc -emit-library` (Xcode or its Command Line Tools) into
~/Library/Caches/PhotoBrowser/, then loaded with ctypes. The build runs in the background (`prepare()`, at
Safe Finder's launch); until it's done, without the tools, or if it fails, `library()` is None and the viewer
draws with Qt as before. A failed build leaves its compiler output in `viewer_surface.log` beside it and isn't
tried again until the source changes. SAFE_FINDER_NATIVE_VIEWER=0 turns it off.

Every call is made on Qt's thread — the main thread, which AppKit and AVFoundation need.
"""
from __future__ import annotations

import ctypes
import os
import subprocess
import sys
import threading
from pathlib import Path

HERE = Path(__file__).resolve().parent
IS_MAC = sys.platform == "darwin"
NOTHING, LOADING, READY, FAILED = 0, 1, 2, 3

_lock = threading.Lock()
_built: Path | None = None
_build_state = "idle"              # idle → building → done
_lib: ctypes.CDLL | None = None
_load_failed = False


def wanted() -> bool:
    """On a Mac, unless SAFE_FINDER_NATIVE_VIEWER=0."""
    return IS_MAC and os.environ.get("SAFE_FINDER_NATIVE_VIEWER", "1") != "0"


def _source() -> Path | None:
    candidates = [HERE / "viewer_surface.swift"]
    if getattr(sys, "frozen", False):
        contents = Path(sys.executable).resolve().parent.parent
        candidates += [contents / "Resources" / "viewer_surface.swift",
                       Path(getattr(sys, "_MEIPASS", HERE)) / "viewer_surface.swift"]
    return next((c for c in candidates if c.is_file()), None)


def _build() -> Path | None:
    """The compiled library, building it when it's missing or older than its source. None without swiftc."""
    src = _source()
    if src is None:
        return None
    out = Path.home() / "Library" / "Caches" / "PhotoBrowser" / "libviewer_surface.dylib"
    log = out.with_name("viewer_surface.log")
    if out.is_file() and out.stat().st_mtime >= src.stat().st_mtime:
        return out
    if log.is_file() and log.stat().st_mtime >= src.stat().st_mtime:
        return None                                        # this source failed to build: don't try every launch
    # Don't call swiftc when the Command Line Tools aren't installed: the stub would pop an installer.
    if subprocess.run(["xcode-select", "-p"], capture_output=True).returncode != 0:
        return None
    out.parent.mkdir(parents=True, exist_ok=True)
    tmp = out.with_name(f"{out.name}.{os.getpid()}.tmp")    # a library is never loaded half-written
    try:
        r = subprocess.run(["xcrun", "swiftc", "-O", "-emit-library", "-swift-version", "5",
                            "-module-name", "ViewerSurface", "-o", str(tmp), str(src)],
                           capture_output=True, text=True, timeout=900)
        if r.returncode != 0 or not tmp.is_file():
            log.write_text(f"swiftc failed ({r.returncode}) building {src}\n\n{r.stderr or ''}{r.stdout or ''}")
            sys.stderr.write(f"viewer_surface: swiftc failed — see {log}\n")
            return None
        os.replace(tmp, out)
        try:
            log.unlink()
        except OSError:
            pass
        return out
    except (OSError, subprocess.SubprocessError):
        return None
    finally:
        try:
            tmp.unlink()
        except OSError:
            pass


def _run_build() -> None:
    global _built, _build_state
    built = _build()
    with _lock:
        _built, _build_state = built, "done"


def prepare() -> None:
    """Starts building the library in the background (once), so it's there when the viewer opens."""
    global _build_state
    if not wanted():
        return
    with _lock:
        if _build_state != "idle":
            return
        _build_state = "building"
    threading.Thread(target=_run_build, name="viewer-surface-build", daemon=True).start()


def _declare(lib: ctypes.CDLL) -> None:
    p, d, i = ctypes.c_void_p, ctypes.c_double, ctypes.c_int32
    sigs = {
        "pbv_create": ([p], p), "pbv_destroy": ([p], None), "pbv_layout": ([p], None),
        "pbv_set_rect": ([p, d, d, d, d], None), "pbv_clear": ([p], None), "pbv_state": ([p], i),
        "pbv_open_video": ([p, ctypes.c_char_p], None),
        "pbv_open_image": ([p, ctypes.c_char_p, ctypes.c_int64], None),
        "pbv_play": ([p], None), "pbv_pause": ([p], None), "pbv_is_playing": ([p], i),
        "pbv_set_rate": ([p, d], None), "pbv_seek": ([p, d], None), "pbv_step": ([p, i], None),
        "pbv_position": ([p], d), "pbv_duration": ([p], d), "pbv_set_loop": ([p, i], None),
        "pbv_take_ended": ([p], i), "pbv_set_muted": ([p, i], None),
        "pbv_content_size": ([p, ctypes.POINTER(d), ctypes.POINTER(d)], None),
    }
    for name, (args, res) in sigs.items():
        fn = getattr(lib, name)
        fn.argtypes = args
        fn.restype = res


def library() -> ctypes.CDLL | None:
    """The loaded library, or None while it's being built (the build is started if it hasn't been) or when it
    can't be had. Call on the main thread."""
    global _lib, _load_failed
    if _lib is not None or _load_failed or not wanted():
        return _lib
    with _lock:
        state, built = _build_state, _built
    if state == "idle":
        prepare()
        return None
    if state != "done":
        return None
    if built is None:
        _load_failed = True
        return None
    try:
        lib = ctypes.CDLL(str(built))
        _declare(lib)
    except (OSError, AttributeError) as e:
        sys.stderr.write(f"viewer_surface: can't load {built}: {e}\n")
        _load_failed = True
        return None
    _lib = lib
    return _lib


class Surface:
    """One surface inside a native view (`host`: the NSView of a Qt widget's `winId()`)."""

    def __init__(self, lib: ctypes.CDLL, host: int) -> None:
        self.lib = lib
        self.handle = lib.pbv_create(ctypes.c_void_p(host))
        if not self.handle:
            raise OSError("viewer_surface: no surface")

    def destroy(self) -> None:
        if self.handle:
            self.lib.pbv_destroy(self.handle)
            self.handle = None

    def _call(self, name: str, *args, default=None):
        if not self.handle:
            return default
        return getattr(self.lib, name)(self.handle, *args)

    def layout(self) -> None:
        self._call("pbv_layout")

    def set_rect(self, x: float, y: float, w: float, h: float) -> None:
        self._call("pbv_set_rect", float(x), float(y), float(w), float(h))

    def clear(self) -> None:
        self._call("pbv_clear")

    def state(self) -> int:
        return int(self._call("pbv_state", default=NOTHING))

    def open_video(self, path: str) -> None:
        self._call("pbv_open_video", os.fsencode(path))

    def open_image(self, path: str, max_pixels: int) -> None:
        self._call("pbv_open_image", os.fsencode(path), int(max_pixels))

    def play(self) -> None:
        self._call("pbv_play")

    def pause(self) -> None:
        self._call("pbv_pause")

    def is_playing(self) -> bool:
        return bool(self._call("pbv_is_playing", default=0))

    def set_rate(self, rate: float) -> None:
        self._call("pbv_set_rate", float(rate))

    def seek(self, seconds: float) -> None:
        self._call("pbv_seek", float(seconds))

    def step(self, frames: int) -> None:
        self._call("pbv_step", int(frames))

    def position(self) -> float:
        return float(self._call("pbv_position", default=0.0))

    def duration(self) -> float:
        return float(self._call("pbv_duration", default=0.0))

    def set_loop(self, on: bool) -> None:
        self._call("pbv_set_loop", 1 if on else 0)

    def take_ended(self) -> bool:
        return bool(self._call("pbv_take_ended", default=0))

    def set_muted(self, on: bool) -> None:
        self._call("pbv_set_muted", 1 if on else 0)

    def content_size(self) -> tuple[float, float]:
        w, h = ctypes.c_double(0), ctypes.c_double(0)
        self._call("pbv_content_size", ctypes.byref(w), ctypes.byref(h))
        return w.value, h.value
