"""Who the app is: its name, and where it keeps things — on this Mac and on the drive.

The app was called **Safe Finder** until November 2026 and is **Photo Browser for Mac** now. A name isn't only
on the title bar: it's the folder in `~/Library/Application Support` (tags of files on the Mac's own disk, AI
models, watermarks, folder covers, the downloaders' saved logins), the settings file, the Keychain entry for the
Astria key, the logs folder, a thumbnail cache worth hours of work, and two hidden folders on the drive. So the
rename is done here, once, and **carries everything over** instead of starting again:

- `support()`, `logs()`, `web_cache()`, `thumb_cache()` return the new folders. The first time any of them is
  asked for (in any process — the app, or a command-line tool), the old folder is *renamed* to the new name
  (`_adopt`); if both exist — an old build was run again after the new one — what the new one lacks is moved
  over. Nothing is ever deleted or overwritten.
- `settings()` is the app's `QSettings`; the first time, every value of the old settings is copied in.
- `keychain_services()` lists the Keychain service names to try, new first (astria.py reads the old one and
  re-saves under the new).
- On the drive: `STAGING` / `CHECKSUMS` are the new hidden folder names, `OLD_STAGING` / `OLD_CHECKSUMS` the
  ones an earlier version left; `drive_folder` picks the one that's there. Shared files written by the Mac say
  `"by": APP_NAME`; readers (the iPhone app too) accept `WRITERS`.

Nothing here imports Qt until `settings()` is called, so the command-line tools can use it.

`python3 app_identity.py` prints what is where (and carries over anything still under the old name).
"""
from __future__ import annotations

import os
import shutil
import threading
from pathlib import Path

APP_NAME = "Photo Browser for Mac"
SHORT_NAME = "Photo Browser"                 # on buttons, where the whole name is too long: "Show in Photo Browser"
OLD_NAME = "Safe" + " Finder"                # split so a search of the code for the old name finds only this file's doc
BUNDLE_ID = "com.photobrowser.mac"
OLD_BUNDLE_ID = "com.photobrowser.safe" + "finder"

SETTINGS_ORG = "PhotoBrowser"
SETTINGS_APP = "PhotoBrowserForMac"          # ("PhotoBrowserMac" is the bulk editor's — bulk_editor/app.py)
OLD_SETTINGS_APP = "Safe" + "Finder"

STAGING = ".Photo Browser Staging"
OLD_STAGING = "." + OLD_NAME + " Staging"
CHECKSUMS = ".Photo Browser Checksums"
OLD_CHECKSUMS = "." + OLD_NAME + " Checksums"
HIDDEN_ON_DRIVE = (STAGING, OLD_STAGING, CHECKSUMS, OLD_CHECKSUMS)

WRITERS = (APP_NAME, OLD_NAME)               # "by" in the shared files: either means "the Mac wrote this"

URL = "photo-browser://"                     # the panes' made-up places (All Videos, a search, a tag)
OLD_URL = "safe" + "-finder://"

_lock = threading.Lock()
_adopted: set[str] = set()


def current_url(location: str) -> str:
    """A remembered place from before the rename, as it's spelled now."""
    return URL + location[len(OLD_URL):] if isinstance(location, str) and location.startswith(OLD_URL) else location


def _library(*parts: str) -> Path:
    return Path.home().joinpath("Library", *parts)


def _adopt(old: Path, new: Path) -> None:
    """Brings `old` to `new`, once per process: renamed whole when `new` isn't there yet, else whatever `new`
    lacks is moved in. Best effort — a folder that can't be moved is simply still where it was."""
    key = str(new)
    with _lock:
        if key in _adopted:
            return
        _adopted.add(key)
        try:
            if not old.is_dir() or old == new:
                return
            if not new.exists():
                new.parent.mkdir(parents=True, exist_ok=True)
                os.rename(old, new)
                return
            for item in sorted(old.iterdir()):
                target = new / item.name
                if not target.exists():
                    shutil.move(str(item), str(target))
            try:
                old.rmdir()                          # only when nothing was left behind
            except OSError:
                pass
        except OSError:
            pass


def support() -> Path:
    """`~/Library/Application Support/Photo Browser for Mac`."""
    new = _library("Application Support", APP_NAME)
    _adopt(_library("Application Support", OLD_NAME), new)
    return new


def logs() -> Path:
    new = _library("Logs", APP_NAME)
    _adopt(_library("Logs", OLD_NAME), new)
    return new


def web_cache() -> Path:
    """Where Qt keeps the downloaders' browser caches (named after the app)."""
    new = _library("Caches", APP_NAME)
    _adopt(_library("Caches", OLD_NAME), new)
    return new


def thumb_cache() -> Path:
    """The thumbnails kept between launches — carried over: re-making a library's thumbnails takes hours."""
    new = _library("Caches", "PhotoBrowser", "MacThumbs")
    _adopt(_library("Caches", "PhotoBrowser", OLD_SETTINGS_APP + "Thumbs"), new)
    return new


def carry_over() -> None:
    """Everything kept under the old name, brought to the new — before Qt makes fresh folders under the new
    one (the downloaders' logins live in the support folder)."""
    support()
    logs()
    web_cache()
    thumb_cache()


_settings_checked = False


def settings():
    """The app's settings (a new `QSettings` each call, as Qt intends). The first call copies the old ones in."""
    from PySide6.QtCore import QSettings
    global _settings_checked
    s = QSettings(SETTINGS_ORG, SETTINGS_APP)
    if not _settings_checked:
        _settings_checked = True
        if not s.contains("carried_from"):
            old = QSettings(SETTINGS_ORG, OLD_SETTINGS_APP)
            for key in old.allKeys():
                if not s.contains(key):
                    s.setValue(key, old.value(key))
            s.setValue("carried_from", OLD_NAME)
            s.sync()
    return s


def keychain_services(what: str) -> list[str]:
    """Keychain service names for `what` ("Astria"), the current one first."""
    return [f"{APP_NAME} {what}", f"{OLD_NAME} {what}"]


def drive_folder(drive: str | os.PathLike, new: str, old: str) -> str:
    """The hidden folder on `drive` to read: the one under the new name, else the one an earlier version left,
    else (nothing there yet) the new name."""
    here = os.path.join(drive, new)
    was = os.path.join(drive, old)
    return was if not os.path.isdir(here) and os.path.isdir(was) else here


def env(name: str, default: str | None = None) -> str | None:
    """An environment switch (`PHOTO_BROWSER_<name>`), under its old spelling too."""
    v = os.environ.get("PHOTO_BROWSER_" + name)
    return v if v is not None else os.environ.get("SAFE" + "_FINDER_" + name, default)


for _k, _v in list(os.environ.items()):          # old spellings of the switches keep working
    if _k.startswith("SAFE" + "_FINDER_"):
        os.environ.setdefault("PHOTO_BROWSER_" + _k[len("SAFE_FINDER_"):], _v)


if __name__ == "__main__":
    carry_over()
    for label, path in (("Support", support()), ("Logs", logs()), ("Browser cache", web_cache()),
                        ("Thumbnails", thumb_cache())):
        print(f"{label:14} {path}{'' if path.exists() else '   (not made yet)'}")
