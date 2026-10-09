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

### With a built-in browser (`pornpics_browser.py`)

Same downloader, but inside a web browser window so there's no copy-pasting: browse the site,
and whenever you're on a gallery the **Download Gallery** button (⌘D) lights up with the photo
count — click it and keep browsing while it downloads. Galleries queue up and download one at a
time; you can also right-click any gallery link → **Download Linked Gallery** without opening it.
The panel at the bottom shows the queue (double-click a row to open its folder), the log, the
destination, and Stop All. It saves into the same folders as `pornpics_downloader.py`, and the
button shows "Downloaded ✓" for galleries you already have. Cookies persist between runs.

```sh
./mac/run.sh                                   # once, to create mac/.venv with PySide6
mac/.venv/bin/python mac/pornpics_browser.py   # opens pornpics.com
mac/.venv/bin/python mac/pornpics_browser.py <gallery URL>
```

### Every gallery of one star (`pornpics_star_downloader.py`)

Give it a pornstar page and it downloads all of their galleries in one go (stdlib only):

```sh
./mac/run.sh     # once, to create mac/.venv with PySide6 (used to scroll the star page)
mac/.venv/bin/python mac/pornpics_star_downloader.py https://www.pornpics.com/pornstars/lucie-wilde/ [destination]
mac/.venv/bin/python mac/pornpics_star_downloader.py lucie-wilde --limit 10     # just the 10 newest
```

A star page only shows its first ~16–20 galleries; the rest load as you scroll. The downloader
first tries plain requests for the further pages, and if those fall short of the star's gallery
count it opens the star page in a small browser window (QtWebEngine) and scrolls it until
everything has loaded, then closes it and downloads. That needs PySide6: run with
`mac/.venv/bin/python`, or with plain `python3` and it borrows `mac/.venv` for that one step
(offering to create it if it doesn't exist). `--browser always` forces the window, `--browser never`
skips it. Every page request is logged, so a short count shows exactly what the site returned.

It creates `<destination>/Lucie Wilde/` with one folder per gallery, named exactly like the
single-gallery tool (so they share folders and re-runs only fetch what's missing). Galleries are
found on the star page plus all of its further pages (the page itself only shows ~20; it follows
the infinite-scroll/page links until no new galleries appear and warns if it falls short of the
site's own count), downloaded newest-first, and each gallery
folder's date is set so sorting by Date Modified lists the newest first. Photos are the full-size
files the site serves, saved byte-for-byte (existing EXIF kept). Each photo's file date is set to
the gallery date, and JPEGs with no EXIF get capture dates, the gallery title (shown as the caption
in the iOS app) and the model names written in (`--no-exif` to skip). Each gallery folder gets a
`gallery.json` (title, date, models, channel, categories, tags, photo list) and the star folder a
`pornstar.json` index. `--workers N` sets parallel downloads per gallery (default 4); Ctrl-C stops
cleanly.

## Safe Finder — a Finder window that moves files onto the SSD safely (`safe_finder.py`)

Looks and works like Finder: a sidebar (Favorites, and Locations with an eject button for the
SSD), and two panes side by side — **From** (your Mac) and **To** (the SSD) — each with icon view
(photo and video thumbnails, size slider) or list view, back/forward and a path bar. Select files
or folders on the left and press **Move to “Extreme SSD”** (or Copy), or drag them onto the right
pane — onto a folder there to put them inside it. Drags from the real Finder work too.

Before anything happens a sheet shows exactly what will: how many files and how much space, names
that will be adjusted for iOS, macOS junk left behind, folders that would get very large, and
whether there's room. Then:

- **Nothing half-written ever appears on the SSD.** Each file is written into a hidden staging
  folder at the top of the drive, flushed to the disk, checked, and only then moved into its
  folder under its real name. If the copy is interrupted, the half-written file is cleared up the
  next time you run a transfer.
- **Every copy is verified.** It's read back from the drive (not the Mac's memory) and compared
  with the original.
- **Move only trashes what's safe.** An original goes to the Trash only after its copy (for a
  folder, every file in it) was verified. On the same drive, a move is just a rename.
- **No `._` files, iOS-safe names, never overwrites.** An identical file already there is
  skipped, so running the same transfer again is safe. A different file with the same name is
  saved as "name (1)".
- **One file at a time.** You can Pause and Stop: the file in progress is cleaned up, finished
  files stay, and nothing is trashed. The Mac is kept from sleeping while it runs, and the transfer
  stops cleanly if the drive is unplugged.
- **Eject** (sidebar ⏏ or the button after a transfer) flushes everything and unmounts the SSD
  properly.

```sh
open "mac/Safe Finder.command"                     # or double-click it in Finder; the first run installs PySide6
mac/.venv/bin/python mac/safe_finder.py --from ~/Downloads --to "/Volumes/Extreme SSD"
```

## Copy or move folders onto the SSD safely (`safe_copy_to_ssd.py`)

Use this instead of dragging folders in Finder. A small window (standard library only):
- **No half-written files.** Each file is copied to a hidden temp file, flushed all the way to
  the disk, then renamed into place.
- **Verified copies.** Each file is re-read from the drive and checked against the original.
- **No macOS junk.** `._` and `.DS_Store` files are never copied or created.
- **iOS-safe names.** Names exFAT/iOS can't handle (`:` `?` etc., decomposed accents) are fixed.
- **Dates and duplicates.** Modification dates are kept, and an identical file already there is
  skipped, so re-running is safe.
- **Size warning.** It warns before a folder would grow past ~8,000 items, which iOS may fail to
  open.
- **Move mode.** Originals go to the Trash only after the whole folder copied and verified.
- **Pause, Stop and Eject.** Pause/Stop work between files, and *Eject SSD* unmounts it properly.

```sh
python3 mac/safe_copy_to_ssd.py                                   # the window
python3 mac/safe_copy_to_ssd.py --cli ~/Downloads/Folder --to "/Volumes/Extreme SSD/Porn" [--move]
```

## Repair the SSD when iOS can't see or open folders (`repair_drive.sh`) — try this first

If folders that Finder shows are missing in Photo Browser, look empty on iOS, or new "AI" /
"Screenshots" folders can't be created inside them, the exFAT file system on the SSD has damaged
folder entries that macOS tolerates and iOS doesn't. Repair it with Apple's own checker (the same
thing Disk Utility ▸ First Aid runs) — read-only check first, then the repair after you confirm:

```sh
sh mac/repair_drive.sh "/Volumes/<SSD name>"
```

Eject the SSD in Finder afterwards, then reconnect it to the iPhone/iPad.

If folders **still** can't be opened on iOS after a clean repair ("opendir errno 22 — Invalid
argument" in Drive Health), Apple's exFAT driver on iOS is rejecting something about them that
macOS tolerates. Export the list with Drive Health's Share button, then:

1. **Find out why** — read-only, reads the folders' directory entries straight off the disk and
   compares them with healthy folders (checksums, name hashes, names, timestamps, sizes, cluster
   chains, deleted entries, fragmentation). Run it *before* rebuilding — a rebuild erases the
   evidence. Paste the output to Claude.

   ```sh
   sudo python3 mac/exfat_inspect.py --list unreadable.txt --root "/Volumes/<SSD name>"
   sudo python3 mac/exfat_inspect.py "/Volumes/<SSD name>/Kardashians/Kylie Jenner"
   ```

   (`sudo` is needed to read the disk device; nothing is written. If macOS still refuses, give
   Terminal Full Disk Access in System Settings ▸ Privacy & Security.)

2. **Rebuild them** with `rebuild_exfat_folders.py` (below) — `--move` for big folders.

The app shows such folders as orange "Can't read on iOS" tiles instead of hiding them, and saves
into "AI 2" / "Screenshots 2" when the existing folder can't be read.

`diagnose_ios_unreadable.py` is the older, name-only version of step 1 (it sees names the way macOS
presents them, which can hide what's really stored).

## Fix folders iOS can't open or shows as empty (`rebuild_exfat_folders.py`)

Folders created or filled in Finder on the exFAT SSD sometimes show up on iOS — in Files and in
Photo Browser — but open **empty** or not at all, while the Mac shows their contents. Rewriting the
folder's directory fresh fixes it. Two ways, both keep the folder's exact name and place, so in-app
Favorites, captions, covers etc. stay attached (dry run by default):

- **Copy** (default): copies everything into a fresh folder, verifies every file's size, moves the
  original to the Trash and puts the copy under the same name. Rebuilds subfolders too. Needs free
  space for one copy of the folder.
- **`--move`**: no copying — `._*` / `.DS_Store` are deleted and every item is *renamed* into a fresh
  folder on the same drive (only the directory entries are written; the photos never move), then the
  fresh folder takes the original's name. No free space needed and fast, so it's the one for huge
  folders (the Kardashians folders). Rebuilds only that folder, not its subfolders. If it stops
  (unplugged, an error), run the same command again and it picks up where it left off.
  `--drop-leftovers` also deletes `<name>.sb-…` files (interrupted saves) whose finished file is
  there.

```sh
# the folders Drive Health lists as unreadable — export the list with its Share button:
python3 mac/rebuild_exfat_folders.py --list unreadable.txt --root "/Volumes/SSD" --move           # dry run
python3 mac/rebuild_exfat_folders.py --list unreadable.txt --root "/Volumes/SSD" --move --apply
python3 mac/rebuild_exfat_folders.py "/Volumes/SSD/Kardashians/Kylie Jenner" --move --apply
python3 mac/rebuild_exfat_folders.py "/Volumes/SSD/Porn/Briana Banks" --apply                    # copy mode
python3 mac/rebuild_exfat_folders.py /Volumes/SSD --since 7 --apply         # every folder created this week
```

Eject the SSD in Finder before unplugging it.

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
