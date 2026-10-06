# Photo Browser for Mac

A desktop companion to the iOS **Photo Browser** app, built in Python (PySide6). Connect the
SSD that holds your library, browse it with the same dark, square-tile look, and bulk-edit what
the phone can't comfortably do at scale:

- **EXIF & captions** — caption/description, title, keywords, creator, copyright, rating, camera
  make/model/lens, software, GPS. Captions are written with the MWG composite tags so EXIF
  `ImageDescription`, IPTC `Caption-Abstract` and XMP `dc:description` stay in sync (the iOS app,
  Photos and Lightroom all read the same value).
- **Dates** — set an exact capture date (stepping N seconds per file so order survives), shift a
  whole selection by ±days/hours/minutes (camera clock / time-zone fixes), or read the date out of
  the filename with a `strptime` pattern. Optionally the file's created/modified dates follow.
- **Filenames** — pattern rename with tokens (`{name} {n} {n:3} {date} {date:%Y%m%d} {folder} {ext}`),
  find & replace (plain or regex), prefix/suffix. Conflicts are flagged and never applied.

Every bulk editor previews each change in a table before anything is written. Single files are
edited inline in the right-hand inspector (filename, capture date, every field) with one Save.

Works on JPEG, HEIC, PNG, TIFF, RAW (DNG/CR2/CR3/NEF/ARW…) and MOV/MP4 video.

## PornPics gallery downloader (`pornpics_downloader.py`)

A separate, single-file desktop tool (tkinter, no third-party packages). Paste a gallery URL
such as `https://www.pornpics.com/galleries/beautiful-woman-posing-48115884/` and every
full-size photo is saved into a folder named after the gallery ("Beautiful Woman Posing")
inside the destination you pick (default `~/Pictures/PornPics`). Existing files are skipped, so a
re-run only fetches what's missing; Stop ends the batch cleanly.

```sh
python3 mac/pornpics_downloader.py                 # window
python3 mac/pornpics_downloader.py <gallery URL>   # window, URL pre-filled
python3 mac/pornpics_downloader.py --cli <gallery URL> [destination]
```

It needs a Python with Tk: the python.org installer and Apple's `/usr/bin/python3` have it;
Homebrew's needs `brew install python-tk`. `--cli` works without Tk.

## Requirements

- macOS 12+ (it also runs on Linux for development)
- Python 3.10+
- **ExifTool** — `brew install exiftool`. Browsing works without it; reading/writing metadata needs it.

## Run

```sh
cd mac
./run.sh            # creates .venv, installs PySide6 / Pillow / pillow-heif, launches
```

or manually:

```sh
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
.venv/bin/python -m photobrowser_mac
```

## Using it

1. Pick the drive in the top-left menu (everything under `/Volumes`), or **Folder…** for any folder.
   The last drive reopens on launch.
2. Click a folder in the tree; the grid fills with square tiles (double-click a folder tile to go
   in, a photo to open it in the default app). Search, filter photos/videos, drag the slider for
   tile size, and sort by **Capture Date** (the default — folders A–Z, then media newest-first by
   EXIF/QuickTime date, exactly the iOS app's default order), **Modified Date**, **Created Date**,
   Name or Size; the button next to the sort flips the direction. The inspector shows all three
   dates for the selection (capture date editable; the Dates editor can make the file dates follow).
3. Click one item to edit it in the inspector. Shift/⌘-click, rubber-band or **Select All** for
   many, then **Rename…**, **Dates…** or **Metadata…** (also in the Edit menu: ⌘⇧N / ⌘⇧D / ⌘⇧M).
4. Every write shows a progress pill at the bottom of the grid; the affected tiles and their
   metadata refresh when it finishes.

Thumbnails are cached in `~/Library/Caches/PhotoBrowserMac/thumbs` (keyed by path + mtime + size,
like the iOS app, so an edited file regenerates). Video thumbnails use macOS QuickLook.

## Layout

```
photobrowser_mac/
  app.py            window, menus, every write path (runs on a worker thread)
  theme.py          the stylesheet (iOS palette: navy→black gradient, translucent panels)
  library.py        volumes, folder scanning, Entry
  exiftool.py       ExifTool wrapper + the Field table (what each app field maps to)
  thumbnails.py     thumbnail cache + generation
  models.py         grid list model + sort/filter proxy
  workers.py        thread-pool jobs with queued signals
  widgets/          sidebar, grid (tile delegate), inspector, bulk dialogs, progress pills
```

Nothing is uploaded anywhere; the app only reads and writes files on the drive you point it at.
