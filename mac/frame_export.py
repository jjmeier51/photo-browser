"""Save Frame and Export All Frames for Safe Finder — the iPhone app's camera button (its press-and-hold
standard-range PNG) and its Export All Frames (`ExportFramesSheet`, `FileActions.exportAllFrames`,
`BulkFrameExportView`), with the same names and the same choices.

**Save Frame** (`save_frame`): the frame at the moment shown, upright, as an 8-bit sRGB PNG — an HDR video's
frame tone-mapped to standard range the way the iPhone's press-and-hold screenshot is — doubled up to a 4K
long side, the video's capture date kept, into a "Screenshots" folder beside the video as
"Screenshot <date> at <time>.png".

**Export All Frames** (`export_all`, `FramesWindow`): every frame (or every other, every fourth) into a
folder beside the video — "<name> Frames" unless named otherwise — as "<folder name> <index>.heic", 1.5×
Lanczos, the capture date kept. An HDR video's frames get the screenshots' tone mapping: standard range
(the default, like the press-and-hold screenshot) or HDR with the tap screenshot's look; the choice is kept,
as on the iPhone. A stopped export carries on where it stopped: while it runs, the folder holds a small
hidden note (`.frames-export.json`: the video, the rate, the colour), gone once it finishes — exporting the
same video at the same rate and colour again resumes into that folder; anything else (a finished export, a
different rate) goes into a fresh "<name> 2", so two exports never mix in one folder. Several videos at once:
each into its own folder, one after another.

Both are `video_helper.swift` (`frame`, `frames` — the iPhone's AVFoundation and Core Image code). Without it
(no Xcode Command Line Tools, or it didn't build) ffmpeg does them: the frame as PNG and the frames as JPEG —
always standard range (a JPEG can't hold HDR), tone-mapped with `zscale`/`tonemap` when this ffmpeg has them.
ffmpeg's tone mapping isn't Apple's, so its frames look different from the video in QuickTime: whatever made
them with ffmpeg says so (`engine_note`), with why the helper isn't there.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import tempfile
import threading
import time
from datetime import datetime
from pathlib import Path
from typing import Callable

import media_info
import simpcity as sc
import video_tools

FPS_CHOICES = (("Every frame", 1), ("Half", 2), ("Quarter", 4))


def _on_exfat(path: str) -> bool:
    try:
        return sc._on_exfat(path)
    except Exception:  # noqa: BLE001
        return False


def _unique(folder: Path, name: str) -> Path:
    dest = folder / name
    stem, ext = os.path.splitext(name)
    n = 2
    while dest.exists():
        dest = folder / f"{stem} {n}{ext}"
        n += 1
    return dest


NOTE = ".frames-export.json"


def _frames_in(folder: Path, base: str) -> int:
    try:
        return sum(1 for n in os.listdir(folder) if n.startswith(base + " ") and not n.startswith("."))
    except OSError:
        return 0


def _note_for(video: str, every: int, standard_range: bool) -> dict:
    try:
        size = os.path.getsize(video)
    except OSError:
        size = 0
    return {"video": os.path.basename(video), "size": size, "every": every, "standard_range": standard_range}


def _note_matches(folder: Path, note: dict) -> bool:
    try:
        with open(folder / NOTE, encoding="utf-8") as f:
            return json.load(f) == note
    except (OSError, ValueError):
        return False


def frames_folder(parent: Path, name: str, video: str, every: int, standard_range: bool) -> tuple[Path, int]:
    """Where this export goes and the frame to start at: `parent/name` when it's new or holds no frames, the
    same folder part way through when its note says it's this very export stopped early, else "name 2",
    "name 3"… (a finished export or another rate stays as it is; a file — a damaged entry — holding a name
    is stepped over too)."""
    note = _note_for(video, every, standard_range)
    for n in range(1, 100):
        cand = parent / (name if n == 1 else f"{name} {n}")
        if cand.exists() and not cand.is_dir():
            continue
        if not cand.exists() or _frames_in(cand, cand.name) == 0:
            sc.make_folder(cand)
            return cand, 0
        if _note_matches(cand, note):
            return cand, _resume_index(cand, cand.name)
    cand = parent / f"{name} {int(time.time())}"
    sc.make_folder(cand)
    return cand, 0


def usable_folder(parent: Path, name: str) -> Path:
    """`parent/name` — or "name 2", "name 3"… when a file (a damaged entry) holds the name — made if needed."""
    cand = parent / name
    n = 2
    while cand.exists() and not cand.is_dir() and n < 100:
        cand = parent / f"{name} {n}"
        n += 1
    sc.make_folder(cand)
    return cand


# ----------------------------------------------------------------------------- ffmpeg pieces

def _is_hdr(video: str) -> bool:
    ff = video_tools.ffmpeg()
    if not ff:
        return False
    probe = ff.replace("ffmpeg", "ffprobe")
    try:
        r = subprocess.run([probe, "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=color_transfer",
                            "-of", "json", video], capture_output=True, text=True, timeout=60)
        streams = json.loads(r.stdout or "{}").get("streams") or [{}]
        return str(streams[0].get("color_transfer") or "") in ("arib-std-b67", "smpte2084")
    except (OSError, subprocess.SubprocessError, ValueError):
        return False


def _has_zscale() -> bool:
    ff = video_tools.ffmpeg()
    if not ff:
        return False
    try:
        r = subprocess.run([ff, "-hide_banner", "-filters"], capture_output=True, text=True, timeout=30)
        return " zscale " in r.stdout and " tonemap " in r.stdout
    except (OSError, subprocess.SubprocessError):
        return False


TONEMAP = ("zscale=t=linear:npl=203,format=gbrpf32le,zscale=p=bt709,tonemap=tonemap=hable:desat=0,"
           "zscale=t=bt709:m=bt709:r=tv,format=yuv420p")


def _ffmpeg_filters(video: str, standard_range: bool) -> list[str]:
    return [TONEMAP] if standard_range and _is_hdr(video) and _has_zscale() else []


def engine_note() -> str:
    """"" when the Mac's own frame tools (the helper) make the frames; otherwise a note that ffmpeg did, and why."""
    if video_tools.helper():
        return ""
    if not video_tools.ffmpeg():
        return ""
    return f"made with ffmpeg, not the Mac's own tools — {video_tools.problem or 'the video helper is missing'}"


# ----------------------------------------------------------------------------- Save Frame

def save_frame(video: str, seconds: float) -> str | None:
    """The frame of `video` at `seconds` as a standard-range PNG in the "Screenshots" folder beside it (module
    notes). Returns the file, or None. Runs on a worker thread."""
    folder = usable_folder(Path(video).parent, "Screenshots")
    name = f"Screenshot {datetime.now():%Y-%m-%d at %H.%M.%S}.png"
    tmp = Path(tempfile.mkdtemp(prefix="safe-finder-frame-"))
    out = tmp / name
    try:
        helper = video_tools.helper()
        ok = False
        if helper:
            try:
                r = subprocess.run([*helper, "frame", video, f"{max(0.0, seconds):.3f}", str(out)],
                                   capture_output=True, timeout=180)
                ok = r.returncode == 0 and out.is_file() and out.stat().st_size > 0
            except (OSError, subprocess.SubprocessError):
                ok = False
        if not ok and (ff := video_tools.ffmpeg()):
            chain = ",".join([*_ffmpeg_filters(video, True), "format=rgb24"])
            try:
                r = subprocess.run([ff, "-y", "-v", "error", "-ss", f"{max(0.0, seconds):.3f}", "-i", video,
                                    "-frames:v", "1", "-vf", chain, str(out)], capture_output=True, timeout=180)
                ok = r.returncode == 0 and out.is_file() and out.stat().st_size > 0
            except (OSError, subprocess.SubprocessError):
                ok = False
        if not ok:
            return None
        return str(sc.place(out, folder, _unique(folder, name).name))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


# ----------------------------------------------------------------------------- Export All Frames

def default_name(video: str) -> str:
    return f"{Path(video).stem} Frames"


def _resume_index(folder: Path, base: str) -> int:
    """How far an earlier export of this video got (its frames are named by index): the run of frames from 0
    that are there, less two (they may have been mid-write when it stopped)."""
    have = set()
    rx = re.compile(re.escape(base) + r" (\d+)\.(?:heic|jpg)$")
    try:
        for n in os.listdir(folder):
            if m := rx.match(n):
                have.add(int(m.group(1)))
    except OSError:
        return 0
    i = 0
    while i in have:
        i += 1
    return max(0, i - 2)


def export_all(video: str, folder_name: str = "", every: int = 1, standard_range: bool = True,
               progress: Callable[[int, int], None] | None = None, stop: threading.Event | None = None
               ) -> tuple[str | None, int, str]:
    """Every `every`-th frame of `video` into a folder beside it (module notes). Returns (folder, frames now in
    it, why — "" unless nothing could be done). `progress(i, total)` is called from this (worker) thread."""
    wanted = (folder_name or "").strip() or default_name(video)
    info = media_info.video_info(video)
    native = float(info.get("fps") or 0)
    fps = 0.0 if every <= 1 else (native / every if native else 30.0 / every)
    folder, start = frames_folder(Path(video).parent, wanted, video, every, standard_range)
    name = folder.name                                   # frames are named by their folder, as on the iPhone
    try:
        sc.write_file(folder / NOTE, json.dumps(_note_for(video, every, standard_range)).encode())
    except OSError:
        pass                                             # without the note a stopped export starts afresh
    helper = video_tools.helper()
    if helper:
        mode = "direct" if _on_exfat(str(folder)) else "atomic"
        cmd = [*helper, "frames", video, str(folder), name, f"{fps:.4f}", "sdr" if standard_range else "hdr",
               str(start), mode]
        why = _run_lines(cmd, progress, stop)
    elif video_tools.ffmpeg():
        why = _ffmpeg_frames(video, folder, name, fps, standard_range, progress, stop, start)
    else:
        why = "exporting frames needs Xcode's Command Line Tools (xcode-select --install) or ffmpeg (brew install ffmpeg)"
    if not why and not (stop is not None and stop.is_set()):
        try:
            os.remove(folder / NOTE)                     # finished: nothing to carry on
        except OSError:
            pass
    count = _frames_in(folder, name)
    if count == 0:
        try:
            os.remove(folder / NOTE)
        except OSError:
            pass
        try:
            folder.rmdir()                      # don't leave an empty folder behind
        except OSError:
            pass
        return None, 0, why or "the video produced no frames"
    return str(folder), count, ""


def _run_lines(cmd: list[str], progress, stop) -> str:
    """The helper's `frames`: its "total"/"progress"/"done"/"error" lines read as they come; Stop ends it."""
    try:
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1)
    except OSError as e:
        return str(e)
    why, total = "", 0
    watcher = None
    if stop is not None:
        def watch() -> None:
            while proc.poll() is None:
                if stop.wait(0.3):
                    proc.terminate()
                    return
        watcher = threading.Thread(target=watch, daemon=True)
        watcher.start()
    for line in proc.stdout or []:
        parts = line.split()
        if not parts:
            continue
        if parts[0] == "total" and len(parts) > 1:
            total = int(parts[1])
            if progress:
                progress(0, total)
        elif parts[0] == "progress" and len(parts) > 2 and progress:
            progress(int(parts[1]), int(parts[2]))
        elif parts[0] == "error":
            why = line.split(" ", 1)[1].strip()
    proc.wait()
    return why if why or proc.returncode == 0 or (stop is not None and stop.is_set()) else "the video helper failed"


def _ffmpeg_frames(video: str, folder: Path, name: str, fps: float, standard_range: bool, progress, stop,
                   start: int = 0) -> str:
    """ffmpeg's way: JPEG frames (index from 0 — from `start` when carrying on, read from that moment),
    tone-mapped when it can; `-progress` for the bar."""
    ff = video_tools.ffmpeg()
    info = media_info.video_info(video)
    duration = float(info.get("duration") or 0)
    native = float(info.get("fps") or 30)
    rate = fps or native
    total = max(1, int(round(duration * rate))) if duration else 0
    # Standard range whatever was chosen: these are JPEGs, and an HDR picture written as one unmapped comes out flat.
    filters = [*(["fps=" + f"{fps:.4f}"] if fps else []), *_ffmpeg_filters(video, True),
               "scale=iw*1.5:ih*1.5:flags=lanczos"]
    seek = ["-ss", f"{start / rate:.4f}"] if start and rate else []
    cmd = [ff, "-y", "-v", "error", *seek, "-i", video, "-vf", ",".join(filters), "-q:v", "2",
           "-start_number", str(start if seek else 0), "-progress", "pipe:1", str(folder / f"{name} %d.jpg")]
    try:
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
    except OSError as e:
        return str(e)
    first = start if seek else 0
    if progress:
        progress(first, total)
    for line in proc.stdout or []:
        if stop is not None and stop.is_set():
            proc.terminate()
            break
        if line.startswith("frame=") and progress:
            try:
                progress(min(total, first + int(line.split("=", 1)[1])), total)
            except ValueError:
                pass
    proc.wait()
    if proc.returncode not in (0, None) and not (stop is not None and stop.is_set()):
        err = (proc.stderr.read() if proc.stderr else "").strip().splitlines()
        return err[-1] if err else "ffmpeg failed"
    return ""


# ----------------------------------------------------------------------------- the window

def _qt():
    from PySide6.QtCore import QObject, QSettings, Qt, Signal
    from PySide6.QtWidgets import (QButtonGroup, QHBoxLayout, QLabel, QLineEdit, QListWidget, QListWidgetItem,
                                   QProgressBar, QPushButton, QRadioButton, QVBoxLayout, QWidget)
    return locals()


def FramesWindow(videos: list[str], parent=None, on_done: Callable[[list[str]], None] | None = None):
    """The Export All Frames window for one video or several (module notes)."""
    q = _qt()
    QWidget, QVBoxLayout, QHBoxLayout, QLabel = q["QWidget"], q["QVBoxLayout"], q["QHBoxLayout"], q["QLabel"]
    QLineEdit, QRadioButton, QButtonGroup, QPushButton = q["QLineEdit"], q["QRadioButton"], q["QButtonGroup"], q["QPushButton"]
    QProgressBar, QListWidget, QListWidgetItem, QSettings = q["QProgressBar"], q["QListWidget"], q["QListWidgetItem"], q["QSettings"]
    QObject, Signal, Qt = q["QObject"], q["Signal"], q["Qt"]

    class Bridge(QObject):
        moved = Signal(int, int, int)             # video index, frame, total
        finished = Signal(int, str, int, str)     # video index, folder, count, why
        all_done = Signal()

    class Window(QWidget):
        def __init__(self) -> None:
            super().__init__(parent, Qt.WindowType.Window)
            self.setAttribute(Qt.WidgetAttribute.WA_DeleteOnClose)
            self.videos = list(videos)
            self.settings = QSettings("PhotoBrowser", "SafeFinder")
            self.stop = threading.Event()
            self.running = False
            self.folders: list[str] = []
            self.bridge = Bridge()
            self.bridge.moved.connect(self._moved)
            self.bridge.finished.connect(self._finished)
            self.bridge.all_done.connect(self._all_done)
            self.setWindowTitle("Export All Frames" + (f" — {len(videos)} videos" if len(videos) > 1 else ""))
            self.resize(560, 470 if len(videos) > 1 else 360)
            v = QVBoxLayout(self)
            v.setContentsMargins(18, 16, 18, 16)
            v.setSpacing(10)
            title = QLabel("Export All Frames")
            title.setObjectName("SheetTitle")
            v.addWidget(title)
            sub = QLabel(("Each video's frames go into a folder beside it, named “<video> Frames”."
                          if len(videos) > 1 else f"From “{os.path.basename(videos[0])}”, into a folder beside it."))
            sub.setObjectName("SheetSub")
            sub.setWordWrap(True)
            v.addWidget(sub)
            self.name = QLineEdit()
            self.name.setPlaceholderText(default_name(videos[0]))
            if len(videos) == 1:
                v.addWidget(QLabel("Folder name"))
                v.addWidget(self.name)
            native = float(media_info.video_info(videos[0]).get("fps") or 0) if len(videos) == 1 else 0
            v.addWidget(QLabel("Frames per second"))
            self.rates = QButtonGroup(self)
            row = QHBoxLayout()
            for i, (label, every) in enumerate(FPS_CHOICES):
                text = label + (f" · {max(1, round(native / every))} fps" if native else "")
                b = QRadioButton(text)
                b.setChecked(i == 0)
                self.rates.addButton(b, every)
                row.addWidget(b)
            row.addStretch(1)
            v.addLayout(row)
            hint = QLabel("“Every frame” exports the video's full frame rate; the lighter rates export fewer — faster "
                          "and smaller.")
            hint.setObjectName("SheetSub")
            hint.setWordWrap(True)
            v.addWidget(hint)
            v.addWidget(QLabel("HDR video"))
            self.colour = QButtonGroup(self)
            crow = QHBoxLayout()
            sdr = QRadioButton("Standard range")
            hdr = QRadioButton("HDR")
            self.colour.addButton(sdr, 1)
            self.colour.addButton(hdr, 0)
            keep_sdr = str(self.settings.value("frames/standard_range", "true")) == "true"
            (sdr if keep_sdr else hdr).setChecked(True)
            crow.addWidget(sdr)
            crow.addWidget(hdr)
            crow.addStretch(1)
            v.addLayout(crow)
            self.colour_hint = QLabel()
            self.colour_hint.setObjectName("SheetSub")
            self.colour_hint.setWordWrap(True)
            v.addWidget(self.colour_hint)
            self.colour.idToggled.connect(self._hint)
            self._hint()
            self.list = QListWidget()
            for p in self.videos:
                QListWidgetItem(f"{os.path.basename(p)} — waiting", self.list)
            self.list.setVisible(len(videos) > 1)
            v.addWidget(self.list, 1)
            if len(videos) == 1:
                v.addStretch(1)
            self.bar = QProgressBar()
            self.bar.setVisible(False)
            v.addWidget(self.bar)
            self.status = QLabel("")
            self.status.setObjectName("SheetSub")
            self.status.setWordWrap(True)
            v.addWidget(self.status)
            buttons = QHBoxLayout()
            buttons.addStretch(1)
            self.cancel = QPushButton("Cancel")
            self.cancel.clicked.connect(self._cancel)
            self.go = QPushButton("Export")
            self.go.setObjectName("Primary")
            self.go.setDefault(True)
            self.go.clicked.connect(self.start)
            buttons.addWidget(self.cancel)
            buttons.addWidget(self.go)
            v.addLayout(buttons)
            # tall enough for every wrapped line at this width (a fixed height clipped the hints)
            self.resize(560, max(self.height(), v.totalHeightForWidth(560) + 40))

        def _hint(self, *_a) -> None:
            self.colour_hint.setText(
                "HDR frames are tone-mapped to standard range, like the iPhone's press-and-hold screenshot — they "
                "look right anywhere." if self.colour.checkedId() == 1 else
                "HDR frames stay HDR, with the screenshot look — highlights eased so they aren't blown out.")

        def start(self) -> None:
            if self.running:
                return
            self.running = True
            self.stop.clear()
            sdr = self.colour.checkedId() == 1
            self.settings.setValue("frames/standard_range", "true" if sdr else "false")
            every = self.rates.checkedId()
            name = self.name.text().strip()
            for w in (self.go, self.name):
                w.setEnabled(False)
            self.cancel.setText("Stop")
            self.bar.setVisible(True)
            self.bar.setRange(0, 0)
            self.status.setText("Starting…")

            def work() -> None:
                for i, p in enumerate(self.videos):
                    if self.stop.is_set():
                        break
                    folder, count, why = export_all(p, name if len(self.videos) == 1 else "", every, sdr,
                                                    lambda a, b, i=i: self.bridge.moved.emit(i, a, b), self.stop)
                    self.bridge.finished.emit(i, folder or "", count, why)
                self.bridge.all_done.emit()
            threading.Thread(target=work, daemon=True).start()

        def _moved(self, i: int, frame: int, total: int) -> None:
            if total:
                self.bar.setRange(0, total)
                self.bar.setValue(min(frame, total))
            pre = f"{os.path.basename(self.videos[i])}: " if len(self.videos) > 1 else ""
            self.status.setText(f"{pre}frame {frame:,} of {total:,}…" if total else f"{pre}reading…")
            if len(self.videos) > 1:
                self.list.item(i).setText(f"{os.path.basename(self.videos[i])} — {frame * 100 // max(total, 1)}%")

        def _finished(self, i: int, folder: str, count: int, why: str) -> None:
            if folder:
                self.folders.append(folder)
            text = (f"{count:,} frames in “{os.path.basename(folder)}”" if count else f"didn't export — {why}")
            if count and (made_with := engine_note()):
                text += f" ({made_with})"
            if len(self.videos) > 1:
                self.list.item(i).setText(f"{os.path.basename(self.videos[i])} — {text}")
            else:
                self.status.setText(text[:1].upper() + text[1:] + ".")

        def _all_done(self) -> None:
            self.running = False
            self.bar.setVisible(False)
            stopped = self.stop.is_set()
            done = len(self.folders)
            if len(self.videos) > 1:
                self.status.setText(("Stopped — " if stopped else "") +
                                    f"{done} of {len(self.videos)} videos exported." +
                                    (" Export again to carry on where it stopped." if stopped else ""))
            elif stopped:
                self.status.setText("Stopped — export again to carry on where it stopped.")
            self.cancel.setText("Close")
            self.go.setText("Export Again" if stopped else "Export")
            self.go.setEnabled(True)
            if on_done is not None and self.folders:
                on_done(list(self.folders))

        def _cancel(self) -> None:
            if self.running:
                self.stop.set()
                self.status.setText("Stopping…")
            else:
                self.close()

        def closeEvent(self, event) -> None:  # noqa: N802
            self.stop.set()
            super().closeEvent(event)

    return Window()
