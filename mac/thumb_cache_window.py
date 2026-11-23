"""Cache All Thumbnails — the iPhone app's command, on the Mac.

Photo Browser for Mac already keeps every thumbnail it makes (Application Support ▸ Thumbnails, under a size limit
— `photo_browser.thumb_cache_dir`, `prune_thumbs`), so a folder looked at once opens with its pictures ready
ever after. This makes them **ahead**: every photo and video on a drive (View ▸ Cache All Thumbnails…) or in one
folder (right-click ▸ Cache Thumbnails Here…), so nothing is made while you scroll.

How it runs:

- a worker thread walks the folder (hidden folders left out) and, for each photo and video, works out the
  thumbnail's name and looks whether it's on the Mac already — only the ones that aren't go any further, so a
  second run over a cached library is just the walk;
- the window hands those to `Thumbnails.warm` a few dozen at a time (it makes them on its own low-priority lanes
  and writes them to the disk cache; nothing is kept in memory unless a tile on screen wants it), widening those
  lanes while this runs and giving them back after;
- **Stop** leaves what's made, drops what's waiting. Closing the window stops it. While it runs the window sets
  `running`, so Quit asks first.

Nothing on the drive is read more than a thumbnail needs, and nothing is written to it.
"""
from __future__ import annotations

import os
import threading
import time

from PySide6.QtCore import QObject, Qt, QTimer, Signal
from PySide6.QtWidgets import QHBoxLayout, QLabel, QProgressBar, QPushButton, QVBoxLayout, QWidget

FEED = 48                 # thumbnails handed over at a time…
AHEAD = 96                # …while fewer than this are waiting to be made
STALL = 240               # seconds with nothing finishing before the rest is given up on (a helper that died)


def _n(n: int) -> str:
    return f"{n:,}"


def _were(n: int) -> str:
    return f"{n:,} {'was' if n == 1 else 'were'} already cached"


class _Walk(QObject):
    """The walk, on its own thread: (found so far, already cached so far, paths that need a thumbnail)."""
    batch = Signal(int, int, list)
    done = Signal()

    def __init__(self, roots: list[str], is_media, key_of, cached) -> None:
        super().__init__()
        self.roots, self.is_media, self.key_of, self.cached = roots, is_media, key_of, cached
        self.stop = threading.Event()

    def start(self) -> None:
        threading.Thread(target=self._run, name="thumb-cache-walk", daemon=True).start()

    def _run(self) -> None:
        found = have = 0
        need: list[str] = []
        sent = time.monotonic()
        try:
            for root in self.roots:
                for folder, dirs, files in os.walk(root):
                    if self.stop.is_set():
                        return
                    dirs[:] = sorted(d for d in dirs if not d.startswith("."))
                    for name in sorted(files):
                        if name.startswith("."):
                            continue
                        path = os.path.join(folder, name)
                        if not self.is_media(path):
                            continue
                        try:
                            mtime = os.stat(path).st_mtime
                        except OSError:
                            continue
                        found += 1
                        if self.cached(self.key_of(path, mtime)):
                            have += 1
                        else:
                            need.append(path)
                    if need and (len(need) >= 200 or time.monotonic() - sent > 0.5) or time.monotonic() - sent > 1.0:
                        self.batch.emit(found, have, need)
                        need, sent = [], time.monotonic()
            self.batch.emit(found, have, need)
        finally:
            try:
                self.done.emit()
            except RuntimeError:                     # the window was closed meanwhile
                pass


class ThumbCacheWindow(QWidget):
    """The window of a Cache All Thumbnails run. `thumbs` is the app's `Thumbnails`; `is_media(path)`,
    `key_of(path, mtime)` and `cached(key)` are photo_browser's own (which kinds get a thumbnail, its name, whether
    it's on disk)."""
    finished = Signal(int, int, int)          # (made, already there, couldn't be made)

    def __init__(self, thumbs, roots: list[str], what: str, is_media, key_of, cached, where: str = "",
                 parent=None) -> None:
        super().__init__(parent, Qt.WindowType.Window)
        self.setWindowTitle("Cache Thumbnails")
        self.setMinimumWidth(520)
        self.thumbs = thumbs
        self.running = True                    # (MainWindow.busy_windows: Quit asks)
        self.queue: list[str] = []
        self.found = self.have = self.fed = 0
        self.walked = False
        self._made0 = thumbs.warmed
        self._failed0 = thumbs.warm_failed
        self._last_left = -1
        self._moved = time.monotonic()
        self._gave_up = 0
        self._lanes = thumbs.warm_lanes()
        thumbs.set_warm_lanes(max(self._lanes, min(6, max(2, (os.cpu_count() or 4) // 2))))

        v = QVBoxLayout(self)
        title = QLabel(f"Thumbnails for {what}")
        title.setObjectName("SheetTitle")
        title.setWordWrap(True)
        v.addWidget(title)
        self.status = QLabel("Looking through it…")
        self.status.setWordWrap(True)
        v.addWidget(self.status)
        self.bar = QProgressBar()
        self.bar.setRange(0, 0)
        self.bar.setTextVisible(False)
        v.addWidget(self.bar)
        note = QLabel("Made once and kept on this Mac" + (f" ({where})" if where else "") + " — folders then open "
                      "with every picture ready. You can keep using the app while this runs.")
        note.setWordWrap(True)
        note.setObjectName("SheetSub")
        v.addWidget(note)
        row = QHBoxLayout()
        row.addStretch(1)
        self.button = QPushButton("Stop")
        self.button.clicked.connect(self._pressed)
        row.addWidget(self.button)
        v.addLayout(row)

        self.walk = _Walk(roots, is_media, key_of, cached)
        self.walk.batch.connect(self._found)
        self.walk.done.connect(self._walk_done)
        self.timer = QTimer(self)
        self.timer.setInterval(150)
        self.timer.timeout.connect(self._tick)
        self.walk.start()
        self.timer.start()

    # ------------------------------------------------------------------ the run
    def _found(self, found: int, have: int, need: list) -> None:
        self.found, self.have = found, have
        self.queue.extend(need)

    def _walk_done(self) -> None:
        self.walked = True

    def made(self) -> int:
        return max(0, (self.thumbs.warmed - self._made0) - (self.thumbs.warm_failed - self._failed0))

    def failed(self) -> int:
        return max(0, self.thumbs.warm_failed - self._failed0) + self._gave_up

    def _tick(self) -> None:
        if not self.running:
            return
        left = self.thumbs.warm_left()
        while self.queue and left < AHEAD:
            chunk, self.queue = self.queue[:FEED], self.queue[FEED:]
            queued = self.thumbs.warm(chunk)
            self.fed += len(chunk)
            self.have += len(chunk) - queued               # made by something else meanwhile (a tile, an export)
            left = self.thumbs.warm_left()
        if left != self._last_left:
            self._last_left, self._moved = left, time.monotonic()
        elif left and time.monotonic() - self._moved > STALL:
            self._gave_up += self.thumbs.cancel_warm(everything=True)       # nothing is coming back for these
            left = 0
        settled = self.have + self.made() + self.failed()
        if self.walked and not self.queue and left == 0:
            self._finish(stopped=False)
            return
        if self.found:
            self.bar.setRange(0, max(1, self.found))
            self.bar.setValue(min(settled, self.found))
        bits = [f"{_n(self.have)} already cached"] if self.have else []
        if self.made():
            bits.append(f"{_n(self.made())} made")
        if self.failed():
            bits.append(f"{_n(self.failed())} couldn't be made")
        if self.walked:
            self.status.setText(f"{_n(settled)} of {_n(self.found)}" + (" — " + ", ".join(bits) if bits else ""))
        else:
            self.status.setText(f"Looking through it… {_n(self.found)} photos and videos so far"
                                + (" — " + ", ".join(bits) if bits else ""))

    def _finish(self, stopped: bool) -> None:
        if not self.running:
            return
        self.running = False
        self.timer.stop()
        self.walk.stop.set()
        self.thumbs.set_warm_lanes(self._lanes)
        made, have, failed = self.made(), self.have, self.failed()
        self.bar.setRange(0, 1)
        self.bar.setValue(0 if stopped else 1)
        if stopped:
            text = f"Stopped. {_n(made)} made" + (f", {_were(have)}" if have else "") + \
                   " — the rest are made when you look at them, or by running this again."
        elif not self.found:
            text = "No photos or videos here."
        elif not made and not failed:
            text = f"All {_n(self.found)} thumbnails were already cached."
        else:
            text = f"All done: {_n(made)} made" + (f", {_were(have)}" if have else "") + "."
            if failed:
                text += (f" {_n(failed)} couldn't be made (files that can't be read, or a kind with no "
                         "preview) — they keep their icons.")
        self.status.setText(text)
        self.button.setText("Close")
        self.finished.emit(made, have, failed)

    def _pressed(self) -> None:
        if self.running:
            self.queue.clear()
            self.thumbs.cancel_warm()
            self._finish(stopped=True)
        else:
            self.close()

    def closeEvent(self, event) -> None:  # noqa: N802
        if self.running:
            self.queue.clear()
            self.thumbs.cancel_warm()
            self._finish(stopped=True)
        super().closeEvent(event)
