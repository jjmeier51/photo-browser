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
destination, Stop All, and **AirDrop to iPhone** — sends the selected galleries (or every finished
one when nothing is selected) straight to the Photo Browser app on the phone; see "AirDrop galleries
to the iPhone app" below. It saves into the same folders as `pornpics_downloader.py`, and the
button shows "Downloaded ✓" for galleries you already have. Cookies persist between runs.

```sh
./mac/run.sh                                   # once, to create mac/.venv with PySide6
mac/.venv/bin/python mac/pornpics_browser.py   # opens pornpics.com
mac/.venv/bin/python mac/pornpics_browser.py <gallery URL>
```

### Every gallery of one star, or of a search (`pornpics_star_downloader.py`)

Give it a pornstar page and it downloads all of their galleries in one go (stdlib only); give it a
site search instead and it downloads every gallery the search finds:

```sh
./mac/run.sh     # once, to create mac/.venv with PySide6 (used to scroll the star page)
mac/.venv/bin/python mac/pornpics_star_downloader.py https://www.pornpics.com/pornstars/lucie-wilde/ [destination]
mac/.venv/bin/python mac/pornpics_star_downloader.py lucie-wilde --limit 10     # just the 10 newest
python3 mac/pornpics_star_downloader.py "https://www.pornpics.com/?q=star+makeup"   # a search (quote the URL)
python3 mac/pornpics_star_downloader.py --search "star makeup" --limit 50           # the same, by words
```

A search goes into `<destination>/Star Makeup/` (the words, title-cased), one folder per gallery
as below, in the site's order (best matches first — `--limit N` keeps the first N) and with no
model check; it writes a `search.json` index (hidden in the iOS app like `pornstar.json`). The
search page is paged with the same endpoint the site scrolls with, so it gets every result, not
just the first screen. `--airdrop` works the same way.

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
cleanly. `--airdrop` then sends what's new to the iPhone app (the galleries that got photos this run,
plus `pornstar.json`, as one archive of the star folder — the app merges it into the star's folder on
the drive); `--airdrop-all` sends every gallery. See the next section.

## AirDrop galleries to the iPhone app (`airdrop_to_iphone.py`)

Download on the Mac, send to the phone without unplugging the SSD from it:

```sh
python3 mac/airdrop_to_iphone.py "~/Pictures/PornPics/Lucie Wilde/Beautiful Woman Posing"   # one gallery
python3 mac/airdrop_to_iphone.py "~/Pictures/PornPics/Lucie Wilde"                           # the whole star
python3 mac/airdrop_to_iphone.py --one "Picked" gallery1 gallery2                            # several, as one folder
```

Each folder becomes a `.pbgallery` archive (a zip under a name only Photo Browser claims, so the
phone offers *only* that app), the Mac's AirDrop window opens, and you pick the iPhone. On the
phone: **Accept ▸ Open with Photo Browser** — the app's **Received** sheet lists the archives, you
pick the drive folder they go in (last used, or the folder you're in), and each one unpacks into its
own folder there, named after the folder you sent, with `gallery.json` / `pornstar.json` beside the
photos so the Categories filter works. A folder that already exists is merged into (re-sending adds
only what's new) unless you pick "Keep both". Several archives can arrive in one AirDrop; "Later"
keeps them on the phone (Settings ▸ Received Archives brings the sheet back) and a failed one stays
listed to try again.

The archives: photos and videos stored uncompressed (already compressed; AirDrop's speed is the
limit), small sidecars deflated, file dates kept, `.DS_Store` / `._*` / `.part` skipped; written to
`~/Library/Caches/PhotoBrowser/AirDrop/` and left there (`--clean` removes day-old ones). Opening
the AirDrop window needs a one-time build of `airdrop_helper.swift` with `swiftc` (Xcode or its
Command Line Tools — `xcode-select --install`); without it the archives are revealed in Finder:
right-click ▸ Share ▸ AirDrop. `--reveal` does that on purpose; `--no-send` only builds the archives.

The same button lives in the PornPics browser ("AirDrop to iPhone"), the star downloader
(`--airdrop` / `--airdrop-all`) and Safe Finder (right-click ▸ "AirDrop to iPhone…", for any folders
or files). A folder AirDropped straight from Finder also works — it arrives as a zip, and the phone
lists Photo Browser among the apps that can open it, with the same Received sheet.

## Safe Finder — a Finder window that moves files onto the SSD safely (`safe_finder.py`)

Looks and works like Finder: a sidebar (Favorites, and Locations with an eject button for the
SSD), and two panes side by side — **From** (your Mac) and **To** (the SSD) — each with icon view
(photo and video thumbnails, with a size slider up to 320 px and a spacing slider that packs the
tiles edge to edge for more per row) or list view, a Sort menu, a search field, back/forward and a
path bar. Select files
or folders on the left and press **Move to “Extreme SSD”** (or Copy), or drag them onto the right
pane — onto a folder there to put them inside it. Drags from the real Finder work too.

Before anything happens a sheet shows exactly what will: how many files and how much space, names
that will be adjusted for iOS, macOS junk left behind, folders that would get very large, and
whether there's room. Then:

- **It writes exactly like the rebuild script** — the one method whose folders the iPhone has
  always read: every file is created fresh under its final name, nothing is moved or renamed into
  place, nothing is flushed folder by folder, and the whole drive is synced between items. (Moving
  files out of a broken folder carried the breakage into the new folder, so even a "move" within
  the SSD makes fresh copies and sends the originals to the Trash.)
- **A new folder arrives whole.** It's built as a hidden ".<name>.incoming" folder and renamed to its
  real name only once every file is in and checked. If a transfer is cut off, the hidden folder is
  picked up again next time.
- **A file cut off mid-copy is cleaned up.** The file being written is noted in a hidden
  `.Safe Finder Staging` folder at the top of the drive; if the Mac or the drive goes away, the next
  transfer deletes the half-written file before starting.
- **Every copy is verified.** It's read back from the drive (not the Mac's memory) and compared
  with the original.
- **Move only trashes what's safe.** An original goes to the Trash only after its copy (for a
  folder, every file in it) was verified.
- **No `._` files, iOS-safe names, never overwrites.** An identical file already there is
  skipped, so running the same transfer again is safe. A different file with the same name is
  saved as "name (1)".
- **One file at a time.** You can Pause and Stop: the file in progress is cleaned up, finished
  files stay, and nothing is trashed. The Mac is kept from sleeping while it runs, and the transfer
  stops cleanly if the drive is unplugged.
- **Eject** (sidebar ⏏ or the button after a transfer) flushes everything and unmounts the SSD
  properly.

**Sort** (the ≡ button in each pane's header) orders a folder by Name, Kind, Date Modified, Date
Created, Date Added or Size, ascending or descending — folders first, names in Finder's natural
order (IMG_2 before IMG_10). Clicking a list-view column does the same. Date Added is the day a
file arrived in its folder, which macOS keeps per file on APFS; on the exFAT SSD it falls back to
the creation date. Each pane remembers its sort.

**Search** (the field in each pane's header, or ⌘F) finds files by words in the name, by extension
(`.heic`, `*.mov`, `ext:mp4,mov`) or by kind (`kind:video`, or the Kind menu — Images, Videos, RAW
photos, PDFs, Audio, Documents, Archives); everything typed must match. Press Return. The scope
bar picks where: the folder you're in (and everything inside it), or the whole drive — "This Mac"
on the Mac side, which asks Spotlight and so answers at once, walking your home folder itself only
when Spotlight has nothing (an external drive is always walked, streaming results as it goes).
Results come up in the same icon or list view, with thumbnails, newest first: open them, Quick
Look, select and Move or Copy to the SSD exactly as in a folder, or right-click ▸ **Show in Safe
Finder** to jump to the file in its folder, selected. Esc (or clearing the field) returns to the
folder; back/forward bring a search up again. Searching in the To pane is for finding things on
the SSD — Move/Copy wait until a folder is open there again.

**All Videos** (top of the sidebar) is a ready-made search: every video in your home folder in the
From pane, newest first, wherever it is — Movies, Downloads, Desktop, Documents, any subfolder — so
they can be picked and moved to the SSD from one place. It looks afresh each time you open it
(click it again to look again). Searches and All Videos skip `~/Library`, app and library bundles
(Photos, iMovie, Final Cut), hidden items and other drives; moved files drop off the list.
(`SAFE_FINDER_SEARCH_ROOTS=/path:/other` makes "This Mac" look elsewhere.)

```sh
open "mac/Safe Finder.command"                     # or double-click it in Finder; the first run installs PySide6
mac/.venv/bin/python mac/safe_finder.py --from ~/Downloads --to "/Volumes/Extreme SSD"
```

### Install it as a Mac app

```sh
sh mac/build_safe_finder_app.sh                    # → /Applications/Safe Finder.app (or ~/Applications)
```

Builds `Safe Finder.app` with [PyInstaller](https://pyinstaller.org) (installed into `mac/.venv`),
with its own icon, and copies it to `/Applications`, so it opens from Launchpad, Spotlight or the
Dock like any app. The first time it opens, macOS asks whether it may use Desktop, Documents,
Downloads and external drives — say yes (System Settings ▸ Privacy & Security ▸ Files and Folders
later). The app is a snapshot of the code: run the script again after every `git pull`. It keeps
the same settings, staging folder and journal as `Safe Finder.command`, and carries the drive
tools (`relocate_folders.py`, `exfat_inspect.py`, `spare_folders.py`) inside, so the "make spare
folders" command it shows works even without this folder. `--no-install` just builds into
`mac/dist/`.

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

> **APFS note (Oct 2026):** the library now lives on an APFS SSD. The two sections below, the
> relocation tool, spare folders and the name adjustments are for the old **exFAT** drive only — Safe
> Finder notices the filesystem and leaves all of that alone on APFS (names are copied exactly as they
> are). A `.Spare Folders` folder copied onto the APFS drive does nothing and can be deleted.

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
   chains, deleted entries, fragmentation) — and where on the drive each folder physically sits,
   since a structurally clean folder iOS still rejects points at the reader rather than the folder.
   Run it *before* rebuilding — a rebuild erases the evidence. Paste the output to Claude.
   `--sample 5000` compares against every folder on the drive instead of 150.

   ```sh
   sudo python3 mac/exfat_inspect.py --list unreadable.txt --root "/Volumes/<SSD name>" --sample 5000
   sudo python3 mac/exfat_inspect.py "/Volumes/<SSD name>/Kardashians/Kylie Jenner"
   ```

   (`sudo` is needed to read the disk device; nothing is written. If macOS still refuses, give
   Terminal Full Disk Access in System Settings ▸ Privacy & Security.)

   **Folders stored past 2.2 TB — the cause, confirmed Oct 11, 2026.** The iPhone misreads a folder whose
   list of contents sits more than 2.20 TB into the drive: it errors, shows nothing, or shows old
   items. Drive Health only catches the errors. `relocate_folders.py` moves those lists (a few MB in
   all) below the line without touching photos, names or paths. Dry run first, then one folder, then
   everything; it unmounts the SSD while it works, keeps an undo file, and has macOS check the drive
   before and after:

   ```sh
   sudo python3 mac/relocate_folders.py "/Volumes/<SSD name>"                       # dry run
   sudo python3 mac/relocate_folders.py "/Volumes/<SSD name>" --apply --only "Some/Folder"
   sudo python3 mac/relocate_folders.py "/Volumes/<SSD name>" --apply
   sudo python3 mac/relocate_folders.py "/Volumes/<SSD name>" --undo relocate-undo-….json
   ```

   Give it a folder on the SSD instead of the SSD itself to fix just that folder and the ones inside
   it. Run it again after adding folders: nearly all the free space is past the line.

   **Spare folders keep new folders below the line.** `--spares 100` keeps 100 ready-made empty
   folders in a hidden `.Spare Folders` folder with their lists below the line. Safe Finder and the
   iPhone app make every new folder by renaming one of those into place, so new folders open on the
   iPhone straight away. Top them up now and then (Drive Health ▸ New folders shows how many are left;
   Safe Finder warns before a transfer that needs more than there are):

   ```sh
   sudo python3 mac/relocate_folders.py "/Volumes/<SSD name>" --apply --spares 100
   ```

   **Controlled test** — when the checker finds nothing, find out which way of writing breaks a
   folder: `ios_folder_test.py` makes five tiny "iOS Test …" folders at the top of the drive, each
   holding the same photo but written a different way. Dump their raw records, eject, run Drive
   Health on the iPhone, and paste both to Claude:

   ```sh
   python3 mac/ios_folder_test.py "/Volumes/<SSD name>"            # prints the --dump command to run next
   python3 mac/ios_folder_test.py "/Volumes/<SSD name>" --remove   # afterwards
   ```

2. **Rebuild them** with `rebuild_exfat_folders.py` (below) — `--low-space` for big folders.

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
- **`--low-space`**: the same fresh copies for folders too big to copy whole (the Kardashians
  folders). Each original is deleted as soon as its copy checks out (in batches, after the drive
  has been synced), so it only needs room for about 2 GB. Rebuilds subfolders too. If it stops,
  run the same command again and it picks up where it left off. `--drop-leftovers` also deletes
  `<name>.sb-…` files (interrupted saves) whose finished file is there. (It used to *move* files
  into the fresh folder; moving files out of a broken folder carries the breakage along, so it
  doesn't any more.)

```sh
# the folders Drive Health lists as unreadable — export the list with its Share button:
python3 mac/rebuild_exfat_folders.py --list unreadable.txt --root "/Volumes/SSD"                 # dry run
python3 mac/rebuild_exfat_folders.py --list unreadable.txt --root "/Volumes/SSD" --apply
python3 mac/rebuild_exfat_folders.py "/Volumes/SSD/Kardashians/Kylie Jenner" --low-space --apply
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
