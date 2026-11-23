# Photo Browser for Mac

The Mac side of the iOS **Photo Browser** app, in Python (PySide6): a Finder-like window onto the SSD that holds
the library — the same folders, tags, Favorites, To AI, folder covers and "Videos at the Top" as the iPhone, kept
in step through small files on the drive itself — with the tools that are easier at a desk: safe transfers onto
the drive, bulk rename and metadata, crop / upscale / retouch, Find Duplicates, the downloaders, Edit and Create
with AI, the Astria.ai Browser, AI models, a photo and video viewer, a PDF viewer, Clone Drive to a New SSD.

**It was called Safe Finder until November 2026.** Nothing was left behind by the rename: the first launch under
the new name moves the old settings, tags of files on the Mac's own disk, AI models, watermarks, folder covers,
saved downloader logins, logs and thumbnails across, and re-saves the Astria key in the Keychain under the new
name (`app_identity.py`). On the drive, the two hidden folders an earlier version made (`.Safe Finder Staging`,
`.Safe Finder Checksums`) are still read — the checksums folder is renamed `.Photo Browser Checksums` the first
time it's used.

```sh
open "mac/Photo Browser for Mac.command"     # double-click it in Finder: sets up mac/.venv once, then opens
sh mac/build_app.sh                          # or build "Photo Browser for Mac.app" into /Applications
```

Everything about the app is under [**The app**](#the-app-photo_browserpy) below. This folder also holds a few
separate tools (gallery downloaders, drive repair) and **the bulk editor** — the first, much smaller Mac
companion, which had this name before (`bulk_editor/`, at the end).

The app's icon is `photo_browser_icon.png`, drawn by `make_icon.py` (the iPhone icon's colours as a grid of photo
tiles round a folder); `build_app.sh` turns it into the app's `.icns`.

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

## ImageFap gallery downloader (`imagefap_downloader.py`)

Every full-size photo of one or more ImageFap galleries, in gallery order (stdlib only):

```sh
python3 mac/imagefap_downloader.py "https://www.imagefap.com/pictures/11350651/Gabrielle%20Santini%20NEW%20PICS"
python3 mac/imagefap_downloader.py 11350651 98765432 --dest ~/Pictures/ImageFap --airdrop
python3 mac/imagefap_downloader.py <gallery URL> --dry-run      # list what it would fetch
```

Each gallery becomes `~/Pictures/ImageFap/<Gallery Title>/` (`--dest` to choose) with its photos
named `001_<image id>.jpg`, `002_…` so sorting by name keeps the gallery's order, and a
`gallery.json` sidecar (title, uploader, date, categories, tags, photo list) in the same shape the
pornpics tools write — so the iOS app's Categories filter works on these folders too. A re-run only
fetches what's missing; `--limit N` takes the first N photos. Each file's date is the gallery's
"Date Added" (plus its position in seconds, so Date sorting keeps the order too), and JPEGs with no
EXIF get that date, the title as the caption and the uploader as the artist written in (`--no-exif`
to skip). `--airdrop` then sends the galleries that got new photos to the iPhone app, one archive
each (see the next section).

How it works: the gallery's `view=2` pages list every photo id (100 a page); the full-size files sit
behind signed CDN links (`…/images/full/…?secure=…`) that only photo pages hand out, and the strip
of 24 that the site's own `partial=true` photo endpoint returns carries them, so one request per 24
photos resolves a gallery. Downloads run 3 at a time (`--workers`); the site rate-limits, and a 429
is waited out and retried.

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
(`--airdrop` / `--airdrop-all`) and Photo Browser for Mac (right-click ▸ "AirDrop to iPhone…", for any folders
or files).

**Anything else AirDropped works too.** A folder sent straight from Finder arrives on the phone as a
zip, and a PDF, a video file, a document — any file — is offered to Photo Browser among the apps
that can take it; the same Received sheet puts it on the drive (an archive as a folder, any other
file as it is; an identical file already there is skipped, nothing is overwritten). The one thing
iOS keeps for itself: loose photos and videos AirDropped to an iPhone go straight into the Photos
app before any app is asked — send them inside a folder, or use the app's "Add from iOS Album".

## The app (`photo_browser.py`)

Looks and works like Finder: a sidebar (Favorites, Locations with an eject button for the SSD, and
your Tags) and **one window** of files, with icon view (photo and video thumbnails, with a size slider up
to 320 px and a spacing slider that packs the tiles edge to edge for more per row), list view or
**Photos** view (the iPhone app's grid — below), a Sort menu, a search field, back/forward and a path bar.

**Split View** is for transfers: the button at the right end of the header (two panes), **View ▸ Split
View** or **⌘\\** opens a second pane beside the first — **From** (your Mac) on the left and **To** (the
SSD) on the right, with the Move/Copy bar below — and the same again closes it. Right-click ▸ **Move or
Copy in Split View…** opens it with your selection kept. The To pane opens on the folder it was last on
(else the SSD), and Photo Browser for Mac remembers which way you left it. Select files or folders on the left and
press **Move to “Extreme SSD”** (or Copy), or drag them onto the right pane — onto a folder there to put
them inside it. Drags from the real Finder work too, onto either pane. **Swap Sides** — the ⇄ button in each
pane's header, or **View ▸ Swap Sides** (**⇧⌘\\**) — puts what's on the left on the right and what's on the
right on the left (From stays the left pane and To the right, so it turns a transfer round); the toast's
**Swap Back** undoes it.

**Selecting with a box**, as in Finder: drag from anywhere that isn't a picture or a name — the space
around a thumbnail or beside its name, a list row's other columns or the space after its name, the
empty space past the last item — and a box selects everything it touches (⇧ adds to the selection,
⌘ toggles). Dragging past the top or bottom scrolls. A drag that starts on a picture or a name still
drags those files, and a click in a tile's blank space still selects that tile.

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
  `.Photo Browser Staging` folder at the top of the drive; if the Mac or the drive goes away, the next
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
- **The window stays usable while it runs**, however many files: the files being moved leave the
  selection as the move starts, and the progress bar, the log and the folders' listings catch up a few
  times a second rather than once per file.

**Sort** (the ≡ button in each pane's header) orders a folder by Name, Kind, Date Modified, Date
Created, Date Added or Size, ascending or descending — folders first, names in Finder's natural
order (IMG_2 before IMG_10). Clicking a list-view column does the same. Date Added is the day a
file arrived in its folder, which macOS keeps per file on APFS; on the exFAT SSD it falls back to
the creation date.

**Each folder keeps its own look**, as in Finder: icons or list, and its sort. A folder full of folders
left as a list by size is still a list by size when you come back to it with Back (or Forward, the path
bar, or by opening it again — even after quitting), however the folder you were just in was shown. A
folder you've never opened takes the look of the one you came from. All Videos, Empty Folders and a
tag's files keep theirs too; the last 1,000 places are remembered, in either pane.

**Search** (the field in each pane's header, or ⌘F) finds files by words in the name **or among their
tags**, by extension (`.heic`, `*.mov`, `ext:mp4,mov`) or by kind (`kind:video`, or the Kind menu — Images,
Videos, RAW photos, PDFs, Audio, Documents, Archives); everything typed must match. Press Return — after
that the results follow as you type more. It also understands:

| Type | Finds |
| --- | --- |
| `"route 66"` | the words together |
| `-blurry` | leaves out anything with this word |
| `tag:beach` or `#beach` | files carrying the tag (`tag:bea*` — tags starting with) |
| `is:favorite` · `is:ai` · `is:tagged` · `is:untagged` | Favorites, To AI, with or without tags |
| `in:seligman` | anything inside a folder whose name has this |
| `date:2020` · `date:2020-06` · `date:2020-06-20` | modified in that year, month or day |
| `date:today` · `yesterday` · `week` · `month` · `year` | modified lately |
| `before:2021` · `after:2020-06` | modified before / after |
| `size:>100mb` · `size:<1mb` · `size:0` | by size |

Capitals, accents and separators don't matter: `img 1003` (or `img1003`) finds `IMG_1003.jpg`, `cafe`
finds `Café.jpg`, `new york` finds `New-York.mov`. **Add Filter** in the scope bar adds these for you
(Favorites, a tag, a date, a size) and lists your recent searches; the field also suggests them as you
type. The first search of a place reads its names from the drive; for the next couple of minutes further
searches there are instant. The scope
bar picks where: the folder you're in (and everything inside it), or the whole drive — "This Mac"
on the Mac side, which asks Spotlight and so answers at once, walking your home folder itself only
when Spotlight has nothing (an external drive is always walked, streaming results as it goes).
Results come up in the same icon or list view, with thumbnails, newest first: open them, Quick
Look, select and Move or Copy to the SSD exactly as in a folder, or right-click ▸ **Show in Photo Browser for
Mac** to jump to the file in its folder, selected. Esc (or clearing the field) returns to the
folder; back/forward bring a search up again. Searching in the To pane is for finding things on
the SSD — Move/Copy wait until a folder is open there again.

**All Videos** (top of the sidebar) is a ready-made search: every video in your home folder in the
From pane, newest first, wherever it is — Movies, Downloads, Desktop, Documents, any subfolder — so
they can be picked and moved to the SSD from one place. It looks afresh each time you open it
(click it again to look again). Searches and All Videos skip `~/Library`, app and library bundles
(Photos, iMovie, Final Cut), hidden items and other drives; moved files drop off the list.
(`PHOTO_BROWSER_SEARCH_ROOTS=/path:/other` makes "This Mac" look elsewhere.)

```sh
open "mac/Photo Browser for Mac.command"                     # or double-click it in Finder; the first run installs PySide6
mac/.venv/bin/python mac/photo_browser.py --from ~/Downloads --to "/Volumes/Extreme SSD"   # --to opens in Split View
```

### The menu bar

Everything Photo Browser for Mac does is in its menus, acting on the pane you're in and what's selected there
(greyed out when it can't):

- **File** — New Folder ⇧⌘N, Open ⌘O (or ⌘↓), Open With Default App, Quick Look (Space in the list), Show in
  Finder, Rename… F2, Rename Files…, Duplicate ⌘D, Copy / Move to the Other Side ⇧⌘C / ⇧⌘M (in one window they
  open Split View and say what to do next), AirDrop to iPhone, **Receive from iPhone… ⇧⌘I**, Make Book PDF, Clone
  Drive to a New SSD, Move to Trash ⌘⌫, Close Window ⌘W, Quit ⌘Q.
- **Edit** — **Undo ⌘Z** (the last rename — one or many — tag, or Favorite / To AI change; the menu says which),
  Copy Name, Copy Path ⌥⌘C, Select All, Find ⌘F, **Find a Command… ⇧⌘P**, Tags… ⌘T.
- **View** — as Icons / List / Photo Grid ⌘1–3, Tight Icons, Theme ▸, Folder Covers, Split View ⌘\\, Videos at
  the Top, Sort By ▸ (with Ascending / Descending and Calculate Folder Sizes — the same choices as the header's
  Sort button), **Show Hidden Files ⇧⌘.**, **Refresh ⌘R**, bigger / smaller thumbnails ⌘= / ⌘−.
- **Go** — Back ⌘[, Forward ⌘] (a mouse's side buttons too), Enclosing Folder ⌘↑, **Go to Folder… ⇧⌘G**, Home,
  Desktop, Downloads, Pictures, All Videos, Empty Folders, Favorites, To AI, Drives ▸.
- **Photos** — Edit Metadata ⌘I, Favorite ⇧⌘F, To AI ⇧⌘A (they read Unfavorite / Remove To AI when the selection
  already is), Use as Album Cover, Choose / Remove Folder Cover, Remove All Tags…, Find People…, Find
  Duplicates…, **Edit Photo… ⌘E**, **Paste Edits…**, **Make Collage…**, then
  the tools in groups: **Adjust ▸** (Crop, Rotate, Convert WebP to JPEG), **Retouch ▸** (AI Upscale 2×, Erase
  Area, Remove Watermark, Remove Objects), **Video ▸** (**Stitch Videos**, Export All Frames, Upscale Video), **CapCut ▸**, **AI ▸** (Edit / Create with AI, Astria.ai Browser, Make AI Model, AI Models),
  **Download ▸** (SimpCity, Instagram, Facebook, TikTok, Fanfix, Depop, Google Drive, taylorpictures.net).
- **Window** — Minimize, Zoom, Bring All to Front, and every viewer and tool window that's open.
- **Help** — the guide and the keyboard shortcuts in a window with a search field, Find a Command…, Welcome…,
  About.

**Find a Command… (⇧⌘P)** lists every one of those commands — over 140 — as you type a few letters of its name
("dupl", "theme", "frames"); Return runs it. It shows each command's menu and key, so it also teaches where
things are.

**The right-click menu** is in the order things are reached for: open it · file it (Move / Copy, Rename,
Duplicate, Tags ▸, Favorite, To AI, Edit Metadata, cover) · change it (**Edit Photo ▸** holds Crop, Rotate, AI
Upscale, Erase Area, Remove Watermark, Remove Objects; Edit with AI…) · send it (AirDrop, CapCut) · where it is
(Show in Finder, Copy Name, Copy Path — and Show in Enclosing Folder from results, a tag or Favorites) · Move to
Trash, last and on its own. A folder adds its tools: Find Duplicates, Rename Files Inside, **Download ▸**,
**AI ▸**, **CapCut ▸**, **Photos Inside ▸**.

### Knowing what happened, and taking it back

- **A toast** over the files says what was just done — "Renamed 14 items.", "Tagged 3 items “beach”." — for a few
  seconds, with an **Undo** button when it can be taken back. (Steps still under way stay on the status line.)
- **Undo (⌘Z)** takes back renames (through the same engine, so tags, labels and the note for the iPhone follow
  back), tags added or removed, and Favorite / To AI. A move to the Trash is put back from the Trash.
- **An empty view says why**: "This Folder Is Empty — drop files here, or press ⇧⌘N", "No Results", "Nothing
  Matches the Filter — 212 items hidden by photos · HEIF", "No Favorites Yet — select photos and press ⇧⌘F".
- Things that aren't errors don't stop you with an alert any more ("already here", "nothing to rename").
- **Files have tooltips** — the whole name (tiles cut long ones short), kind, size, date, tags — and the window is
  named for the folder it shows.
- **The first launch** shows a short welcome (Help ▸ Welcome… shows it again).

### Edit Metadata — many photos and videos at once

Select photos and videos — or folders, for every one inside them and their subfolders — and right-click ▸
**Edit Metadata…** (or **⌘I**, or Photos ▸ Edit Metadata…; right-click a folder's empty space for **Edit
Metadata of Everything Here…**). The window reads what the files hold now in the background, then each field
is ticked to change it; everything left unticked stays exactly as it is, and a ticked field left empty is
removed. Each field says what the files hold now — the one value they share, how many different ones, or none
— and ticking a field they all share fills it in, ready to edit.

- **Capture date** — **Set to** a date and time (each next file a few seconds later, in the order listed, so
  they keep that order when sorted by date), **Shift by** days/hours/minutes/seconds (a camera clock or time
  zone that was off), **From the file name** (IMG_20240613_101530, PXL_…, 2024-06-13 10.15.30, “Screenshot
  2024-06-13 at 10.15.30”, VID-20240613-WA0001 — a date alone is taken as noon — Unix times, or a pattern of
  your own like `%d.%m.%Y`), **From the file's own date** (modified or created), or **Copy to the files' own
  dates** (the capture date stays; Finder then sorts by when they were taken). *Only files that have no capture
  date yet* fills the gaps; *the files' own created and modified dates follow* (on by default) moves those too.
  A date keeps the time zone the file already has; one without gets this Mac's.
- **Location** — paste coordinates (`37.7749, -122.4194`, `37.7749 N 122.4194 W`, degrees-minutes-seconds) or a
  Google or Apple Maps link, or **Remove it**.
- **Description** — caption (line breaks and all), title, keywords (**Replace with**, **Add** or **Remove**,
  comma-separated), creator, copyright, rating (★ to ★★★★★, or none).
- **Camera** — make, model, lens (photos only) and software.
- **Other Tags** — any tag by its ExifTool name, one per line (`EXIF:ISO=200`, `XMP:Label=Red`,
  `IPTC:City=Paris`; `Tag=` removes it). Tags that would rename, move or link a file aren't accepted.
- **Remove Everything Else** — takes every other tag out first (camera, serial numbers, location, captions…),
  keeping only the capture date, how the photo is turned and its colour profile; RAW and TIFF files are left
  alone, since stripping them can make them unreadable.

The list underneath is the plan, file by file: the capture date now and after, and anything a file can't take
(no date to shift, no date in its name, a video has no lens) — those parts are skipped, the rest written.
**Write** asks first (it can't be undone), writes one file at a time with Stop between files, and lists any file
that wasn't changed with ExifTool's reason.

Everything is written the way Photo Browser on the iPhone reads it — a photo's date in EXIF with its time zone,
a video's in its QuickTime creation date; a photo's place in EXIF GPS, a video's in QuickTime's ISO 6709 location;
a photo's caption in IPTC (and EXIF and XMP), a video's in QuickTime — the same tags the downloaders write. It
needs **ExifTool** (`brew install exiftool`; the window says so, with *Choose ExifTool…* for one elsewhere). Each
file is rewritten in place, so it keeps its Photo Browser tags and its other extended attributes; a write isn't
cut off for taking long — a big video gets all the time it needs. JPEG, HEIC, PNG, WebP, TIFF, RAW, MOV, MP4 and
M4V can be edited; GIF, WebM, AVI and MKV can't hold these tags and are left out (the window counts them).

### Thumbnails

Each photo and video is rendered once, at one size (512 px), and that one thumbnail is drawn at
whatever icon size the slider is on — so resizing is instant, nothing re-renders. Thumbnails are kept
on disk in `~/Library/Caches/PhotoBrowser/MacThumbs/` (keyed by path and date, so an edited
file gets a fresh one) and come straight back on the next launch. Opening a folder renders what's on
screen first and then the rest of the listing in the background, so scrolling finds them ready.
Videos — and RAW and other formats Qt and Pillow can't read — come from a small helper,
`thumb_helper.swift`, that uses the Mac's own AVFoundation and ImageIO: it stays running, makes a few
at once, and each thumbnail appears the moment it's ready, the ones on screen first (the newest first
as you scroll). Photo Browser for Mac builds it once with Xcode's `swiftc` (the same way as the AirDrop helper),
into `~/Library/Caches/PhotoBrowser/`. Until it's built, without Xcode's tools, or for a file it can't
read, Quick Look does those thumbnails, four at a time. The system may clear the Caches folder under
disk pressure; the thumbnails just render again.

**A thumbnail is in the screen's colours** (`thumb_color.py`). Qt draws a tile's numbers as they are, so
the photo's own colour has to be dealt with as the thumbnail is made: an HDR photo stored in PQ or HLG —
the 10-bit HEICs that Save Frame and Export All Frames make from HDR video, HDR AVIFs — is brought to
standard range (highlights eased in under white, BT.2020 colours into sRGB), and a wide-colour (Display
P3) photo is converted by its profile. They used to come out flat and grey, or washed. The iPhone's own
HDR photos (a standard picture plus a gain map) show their standard picture, as in Finder. The helper
does the same for what it makes. Thumbnails of HEIC / HEIF / AVIF / JPEG XL photos made before this are
made again, once, the first time each folder is shown.

### Undo for crops and edits

Edit ▸ **Undo** (⌘Z) now takes back changes to a photo itself: a crop, a batch crop, a rotate, the photo editor's
Overwrite Original, Paste Edits, Erase Area / Remove Objects / Remove Watermark with Replace, and AI Upscale in
place. Each job is one step ("Undo Crop of 12 Photos"), and the message at the bottom of the window gets an Undo
button. The photo goes back exactly as it was — same bytes, same dates — and the tag the edit added comes off. If
you've edited a photo again since, undo that later edit first. The originals are kept on the Mac until you quit
(up to 6 GB). Rotated videos are turned back; an upscaled video that replaced its original isn't kept — choose Save
as New for those.

### Highlight folders (the iPhone's bubbles)

Folders the iPhone app shows as round highlights now show the same way here: a row of bubbles above a folder's
files — downloaded Instagram / Facebook / TikTok profiles, an Instagram profile's Stories and highlights, and any
folder you turned into an **album highlight**. Click one to open it. Right-click a folder ▸ **Turn into Album
Highlight** (or Remove from Highlights) to make your own; it shows on the iPhone too. A **Reviews folder**
(File ▸ New Reviews Folder…, or right-click ▸ Reviews Folder) shows only its folders, as large bubbles — press Show
Files to see the ordinary listing. View ▸ Show Highlights turns the row off.

### Thumbnails and folder covers are kept between launches

Thumbnails are kept in `~/Library/Application Support/Photo Browser for Mac/Thumbnails` (moved there from Caches,
which macOS empties when your disk runs low — the ones you had come along), up to 20 GB; the least recently used go
first once a day if it grows past that. Which picture each folder shows, and how long each video is, are remembered
too (`facts.sqlite` in the same folder), so folders don't have to be looked through again every time the app opens.

Export All Frames makes each frame's thumbnail while the export is still running, so the frames folder opens with
every thumbnail ready; the window says "Thumbnails ready." when the last one is made.

### Cache All Thumbnails

Every thumbnail the app makes is kept on the Mac (above), so a folder you've looked at once opens with its
pictures ready from then on. **View ▸ Cache All Thumbnails…** makes them all ahead of time — every photo and video
on the drive the window is showing — and right-click a folder ▸ **Cache Thumbnails…** does one folder and what's
inside it. A small window shows how far it is (how many were already cached, how many it has made, any that
couldn't be made) with **Stop**; you can keep using the app while it runs, and running it again only does what's
new. It's the iPhone app's Cache All Thumbnails; each app keeps its own thumbnails (they aren't shared through the
drive).

### More themes, Christmas wallpapers and typefaces

View ▸ Theme… now has 70 looks: new everyday ones (Slate, Espresso, Nordic, Charcoal and Gold, Lavender Mist, Mint,
Sand, Typewriter), a **Nature** set and a **Vivid** set, and ten Christmas themes with a **wallpaper** — little
drawings tiled behind your files: Santa Claus, Let It Snow, Snowfall, Candy Cane Lane, Christmas Tree Farm, Deck the
Halls (ornaments), Wrapped Presents, Holly Jolly, Gingerbread Village and Starry Christmas. Any theme you make can
have one too: Custom ▸ **Wallpaper**. There are 14 more typefaces (Baskerville, Didot, Gill Sans, Optima, American
Typewriter, Palatino, Cochin, Bodoni 72, Charter, Trebuchet, Avenir Next Condensed, Chalkduster, Party LET, Savoye
LET). The iPhone app has the same themes, wallpapers and typefaces in Settings ▸ Appearance.

### A true grid, folder covers and themes

**A true grid.** Two ways to have the pictures edge to edge, at any thumbnail size:
- the **Photo Grid** (⌘3, the third view button): squares only, no names, filling the width — the iPhone's
  grid (below). The spacing slider sets the gap between squares (0–12; 2 is the iPhone's);
- **icon view with the spacing slider all the way left** (or View ▸ **Tight Icons**): the same squares with
  the names kept underneath. Every picture is cropped to fill its square and the columns fill the width.

Folders remember how they were last shown, so a folder you looked at as loose icons stays that way. View ▸
**Use This View for Every Folder** shows them all the way the one on screen is.

**Folder covers** (`folder_covers.py`). A folder shows a picture instead of a plain folder icon: the cover
chosen for it, else the first photo or video inside it (looking into its subfolders if it only holds
folders). Right-click a folder ▸ **Choose Cover…** (or **Remove Cover**), or right-click any photo or video ▸
**Use as Album Cover** (also Photos ▸ Use as Album Cover, and ⋯ in the viewer — where a video gives the
frame that's on screen). View ▸ Folder Covers turns the pictures off.
Covers are **shared with Photo Browser on the iPhone**: they're kept on the drive (in its hidden
`.Photo Browser Metadata` folder), so a cover chosen here is the folder's cover in the app and the covers
set in the app show here. When both have chosen one, the later choice wins. (The app picks a random photo
for every folder that has no cover; those show here too, and any cover you choose replaces one.)

**Themes** (`themes.py`, `theme_window.py`). View ▸ **Theme**: *Match macOS* (the Finder look, light or
dark with your Mac), or one of forty ready-made themes in five sets — the same on the iPhone:

- **Everyday** — Photo Browser, Graphite, Midnight, Ocean, Rose, Forest, Sunset, Paper.
- **Halloween** — Pumpkin Patch, Witching Hour, Haunted House, Candy Corn, Ghost Story.
- **Thanksgiving** — Harvest Table, Autumn Leaves, Pumpkin Pie, Cranberry, Sage and Squash, Maple, Cornucopia.
- **Christmas** — Candy Cane, Evergreen, Winter Night, Cozy Fireplace, Snow Day, Silver Bells, Gingerbread,
  Nutcracker, Mistletoe, Christmas Eve, Santa's Workshop, North Pole.
- **Holiday** — Holiday Lights, Festival of Lights, Kwanzaa, Winter Solstice, Sugar Plum, Hot Cocoa, Midnight
  Toast, First Frost.

**Choose or Customize…** opens the chooser: every theme as a swatch, and your own background (one colour or a
gradient), accent colour, typeface and light or dark. A click shows it at once in every window. On the Mac:

- **My Themes** — **Save as My Theme…** keeps the look that's on under a name; it joins the chooser and the
  Theme menu (right-click one to rename or remove it).
- **Follow the Seasons** — through the holidays the window wears that season's themes, **a different one each
  day**: Halloween all October, Thanksgiving from November 1 to Thanksgiving Day, then Christmas, Holiday or
  both (your choice, "In December") to Christmas Day, and Holiday to New Year's Day. The rest of the year it
  shows the theme you chose. Choosing a theme by hand turns it off.
- **Surprise Me** — a ready-made theme picked for you.

Whatever the colours, small text stays readable: the grey text and the text on the accent colour are worked out
to keep their contrast on every part of the background.

### Photos view and the viewer — the iPhone app's grid and viewer (`media_viewer.py`, `media_info.py`)

**Nothing but the picture.** In the viewer the controls are see-through and get out of the way: dimmed while the
mouse is elsewhere, full strength under it, and — once the mouse has rested a few seconds — gone, pointer and
all, leaving the photo or video alone on black. Move the mouse and they're back. The picture never shifts when
they fade, and ←/→ doesn't bring them back. **⋯ ▸ Keep Controls Visible** if you'd rather they stayed.

The third view button in each pane (⌘3, beside icons and list) shows a folder the way Photo Browser on the
iPhone does: square tiles two pixels apart filling the pane's width in whole columns, each picture cropped
to fill its square; a video's length bottom left and a play badge bottom right; tag dots top right (the
reaction score top left while sorting by it); a folder shows the first photo or video inside it with its
name across the bottom. The size slider sets how many columns. A selected tile lightens and gets the
iPhone's blue check; dragging from a tile that isn't selected draws a selection box (from a selected one it
drags the files, as everywhere else). Each folder remembers it, like icons and list.

**One frame at a time**: in the viewer, the two buttons either side of Play step a video one frame back or
forward (hold one down and it keeps going) — also **,** and **.**, or **⇧←** and **⇧→**. The time then shows to
the millisecond, with the frame number when you point at it. **⋯ ▸ Edit with AI…** opens the photo on show in the Edit
with AI form. As you step through files with ← →, **the highlight in the window behind follows** — so when you
close the viewer, the last file you looked at is the one selected. **⋯ ▸ Use as Album Cover** makes the photo — or
the video frame you've stopped on — the cover of its folder; **⋯ ▸ Edit Photo…** opens the photo editor.

**Double-click a photo or video** (or press Return) — in any view — and it opens in the viewer instead of
Preview: one item at a time on black, in the folder's order (or just the ones you picked, if you picked
several).

- **The window fits the picture, as tall as the display.** It opens over Photo Browser for Mac's window, on the same
  display, the **full height of that display** (from the menu bar down to the Dock), and takes each item's
  shape at that height — a portrait video or photo gets a tall, narrow window with no black bars beside it, a
  wide one a wide window (only something too wide for the display at full height, like a panorama, is as wide
  as the display instead); moving to the next item re-fits it around the same centre. Resize it by hand and
  that becomes the size it fits within. The bar with the name and buttons sits **above** the picture and the
  one with the controls **below** it — never over it. A click on the picture hides them both (the iPhone's
  tap) and brings them back.
- **Top right:** the resolution, quietly — **720p, 1080p, 4K, 8K…** for a video (by its long side, as the
  iPhone app's filter), megapixels for a photo — and **HDR** when it is (an HLG, PQ or Dolby Vision video; a
  photo with an HDR gain map, as the iPhone takes them). Beside them: ♡ **Favorite** and ✦ **To AI** (⇧⌘F /
  ⇧⌘A — the iPhone app's, shared with it), the camera (**Save Frame**, videos), ⓘ **Info** and ⋯ (Slideshow,
  Full Screen, Export All Frames…, Loop, Tags…, Show in Folder, Open With Default App, Move to Trash).
- **HDR looks as it does in QuickTime Player and Preview.** Videos are played by macOS itself (AVFoundation —
  QuickTime's own player), so an HDR video is shown in HDR on a Mac display that can (and tone-mapped by macOS
  on one that can't), with the same colours and brightness as QuickTime — not Qt's brighter, harsher version. An
  HDR photo (an iPhone photo with an HDR gain map, or an HLG/PQ one) appears for a moment in standard range, then
  in HDR — made for the brightness your display can show right now, and made again as that changes (screen
  brightness, another display), the way Preview does, so its highlights are never cut off. This is a small Swift library (`viewer_surface.swift`) that Photo Browser for Mac builds in the background the
  first time it starts, with Xcode's Command Line Tools like the other helpers; until it's built, without the
  tools, and for videos macOS can't play (MKV, WebM, AVI…), Qt's player is used as before. If it won't build,
  the compiler's message is in `~/Library/Caches/PhotoBrowser/viewer_surface.log`.
- **Zoom** — the − / Fit / + buttons at the bottom right (or +, −, 0), for photos **and videos**; click the
  percentage for fit ⇄ actual size. **The mouse wheel zooms** photos and videos, about the pointer — roll it toward you to zoom
  in, away to zoom out (out no further than the fit); on a trackpad or Magic Mouse a two-finger scroll still swipes to the next item (and pans when
  zoomed in), and pinch or ⌘-scroll zoom. Double-click toggles fit ⇄ actual size; drag to pan.
  Photos fill the window (a small one is enlarged rather than framed in black). The ones either side are read
  ahead, so ←/→ is instant.
- **Videos** play and loop, as on the iPhone. Below the picture: the **scrubber** across the whole width —
  click anywhere along it to jump there, or drag (the video holds still while you drag, and hovering shows the
  time under the pointer) — then ‹ ›, **play/pause**, mute, a **volume slider** (click anywhere along it for that volume, or drag; remembered between videos and launches; turning it up takes the mute off) and speed (½×, ¼×, ⅛× — the iPhone's Slo-Mo). J / L
  skip 15 s, , and . step a frame. **Save Frame** saves the frame on screen as a standard-range PNG in a
  "Screenshots" folder beside the video (the iPhone's press-and-hold screenshot); ⋯ ▸ **Export All Frames…**
  opens Export All Frames (below).
- ←/→ (or a two-finger swipe) moves, Esc or ↓ closes, I or ↑ opens the **Info** panel (when it was taken or
  recorded, size, length, camera, place with a Maps link, caption, folder, labels, tags and Edit Tags…), F is
  full screen, S a slideshow (3 seconds a photo; a video plays to its end), Space plays/pauses, ⌘⌫ moves to the
  Trash (asking first), ⌘T edits tags. Notes ("Saved …", "Favorited.") show for a moment under the name.

Video lengths, dates, sizes and the camera are read from the files themselves (`media_info.py`: the MP4/MOV
boxes and the photo's EXIF — no ExifTool), off the main thread and once per file.

### The PDF viewer, and Optimize for Mac / for iPhone (`pdf_viewer.py`, `pdf_optimize.py`)

**Double-click a PDF** (or press Return) and it opens in Photo Browser for Mac's own PDF viewer instead of Preview — the
photo viewer's dark look, as tall as the display, the pages scrolling one after another fitted to the width.
←/→ (Page Up/Down) a page at a time, or type a page number at the bottom; − / + and the zoom menu (Fit Width, Fit
Page, 50–400 %), ⌘-scroll or pinch to zoom; **⌘F** searches — every match is marked, Return goes to the next and
⇧Return the one before; **☰** shows the pages as thumbnails. ⋯ has Open With Default App (Preview), Show in Folder
and AirDrop to iPhone. A protected PDF asks for its password. Right-click ▸ Open With Default App still opens
Preview.

Two buttons at the bottom make a **new PDF beside the original** (the original is never changed); it opens in the
viewer when it's made (**Back to Original** returns), carries the original's tags, and Show in Folder finds it:

- **Optimize for iPhone** → "<name> (for iPhone).pdf", made for the **iPhone 17 Pro Max**: every page is the shape
  of its screen (440 × 956 points), so one page fills the phone and the next is a swipe away. The margins are
  trimmed (to the same box on every page, so the text keeps one size); a **two-column page is read a column at a
  time** — the left column, then the right — so its text comes out nearly twice as large (a paper's 9-point text
  reads at about 16 on the phone); and the content flows from page to page, **cut only in the white between lines**.
  A title or figure across both columns stays whole, a picture taller than the screen is shrunk to fit it, and
  blank pages are left out. Nothing is retyped: it's the original's own drawing, cut and placed, so fonts,
  pictures and layout stay as they were. **AirDrop to iPhone…** sends it straight to the phone (Photo Browser
  takes it), or it travels on the drive beside the original.
- **Optimize for Mac** → "<name> (for Mac).pdf": the pages stay whole and in order, trimmed to
  their content — the same box on every page (left and right pages separately, as a book's margins alternate),
  grown for any page with something outside it — and blank pages left out, so in this viewer the page, not its
  margins, fills the window and the text comes out larger.

The new PDF is drawn by `pdf_helper.swift` (Core Graphics, built on first use with Xcode's Command Line Tools like
the other helpers): the original's pages drawn clipped and scaled, so text stays text — sharp at any zoom,
searchable and selectable — and the file stays small. Without it (or if it won't build — its message is in
`~/Library/Caches/PhotoBrowser/pdf_helper.log`) Qt draws the same layout from pictures of the pages at the iPhone's
3 pixels a point: sharp on the phone, but the text can't be searched or selected, and the viewer says so.

**Getting around a PDF.**

- **Click the contents page.** On a book's table of contents, click an entry — its **page number** or its
  title — and the viewer goes straight to that page. It works where the PDF has real links, and also where the
  contents page is only printed text (scanned books, exported documents): the viewer reads the line you clicked
  and works out which page the printed number means, even when the book's page 1 isn't the file's first page.
  **‹ Back** (⌘[) at the bottom returns to where you were.
- **Contents** (top left) opens the list of chapters beside the pages — click one to go there; the chapter
  you're reading is marked. The chapter's name in the bottom bar opens the same list as a menu, and **[** and
  **]** step to the chapter before and the next.
- **Any page**: type its number in the page box (⌘G puts the cursor there; it also takes a printed label like
  "xii"), ←/→ a page at a time, Home / End for the first and last page, ☰ for page thumbnails.

### Make Book PDF — a text file typeset like a printed book (`book_window.py`, `bookify.py`)

Right-click a **.txt, .md or .rtf** file ▸ **Make Book PDF…** (several selected: a book of each), or File ▸ Make
Book PDF…. It's `bookify.py` with a window: the text becomes a PDF that looks and reads like a printed book —
EB Garamond, justified and hyphenated, a title page, a contents page, chapters opening part-way down the page with a
drop cap and small-caps lead-in, running heads and page numbers, mirrored margins, smart quotes and dashes, scene
breaks, and cream paper with a light texture. It finds the title, author and chapters in the file ("Title:" /
"Author:" lines, "Chapter 1", "CHAPTER IV. The Storm", "Prologue", "# Heading", Project Gutenberg headers, RTF italics
and bold — see the top of `bookify.py`), and the window shows what it found before you start.

- **Title / Author** — leave empty to use what was found, or type your own.
- **Save in** — beside the text (the default), or **Choose Folder…** for anywhere else, on the Mac or a drive;
  **Beside the Text** goes back. Remembered and always shown in the window; a folder that isn't there any more
  (its drive unplugged) is said before anything is made.
- **Page size** — 6 × 9 in (a trade paperback), 5.5 × 8.5, 5 × 8, A5, US Letter, or **iPhone 17 Pro Max**: pages
  the shape of its screen, so one page fills it; 10-point type that reads at about 15 on the phone, equal narrow
  margins, no blank pages, saved as "<name> (for iPhone).pdf" — AirDrop it, or open it from the drive in Photo
  Browser.
- **Text size** (automatic suits the page), **Paper** (textured cream, flat cream, white for printing),
  **Hyphenation** language, the **drop caps and ornaments** colour, **your own fonts** (a folder with at least a
  Regular and an Italic), and Contents page, "Chapter One: Title" in the contents, drop caps, chapters on right-hand
  pages, equal margins. Your choices are remembered.

**Make Book** sets it in the background (Stop stops it); the PDF goes beside the text (or in the folder you chose) as
"<name>.pdf" — never over a file that's there — with the text's tags, and **Open** shows it in Photo Browser for Mac's PDF viewer (where Optimize
for iPhone works on it too). The first book downloads EB Garamond once. It needs ReportLab and pyphen (in
`requirements.txt`): `Photo Browser for Mac.command` adds them to an existing setup and `build_app.sh` builds them
into the app; if they're still missing, the window's main button is **Install ReportLab** instead of Make Book — it
fetches them (into Photo Browser for Mac's own Python, or for the built app into ~/Library/Application Support/Photo Browser for
Mac/python, with any Python on the Mac), then Make Book appears. `bookify.py` still works on its own: `python3 bookify.py story.txt --size iphone`.

**Pictures in the book.** When you press Make Book it first asks **"Would you like to add pictures to this
book?"** — Add Pictures, No Pictures, or Cancel. Either way the book is made. With Add Pictures, the **Pictures**
window then opens over the finished book. On the left are your pictures and the choices for the one selected; on
the right is **the page as it will be** — the real page, set again the moment you change anything.

Where a picture can go — anywhere:

- **Beside the text** — at the left or right, with the paragraph you put it at (and the ones after it, as many as
  fit) flowing round it;
- **Between two paragraphs** — at the left, in the middle or at the right;
- **A page of its own** — after any paragraph;
- **At the front**, **at the start or end of a chapter**, **at the end of the book** — on a page of its own or in
  the text.

How to put it there:

- Go to the page you want with **◀ ▶** or the page number (or **Find** some words from the text), then **Add
  Pictures…** — new pictures land beside the text on the page you're looking at.
- **Click a paragraph** on the page: the selected picture goes there. **Drag the picture** onto another paragraph
  to move it — drop it on the left or right half and it takes that side. **◀ Earlier / Later ▶** move it one
  paragraph at a time.
- **Drag a corner** of the picture to make it larger or smaller — any size — or use the **Width** slider (a per
  cent of the text's width). Beside the text a picture can take up to 70 %, so there's room for words next to it.
- Add a **caption** if you like; it sits under the picture.

If a picture doesn't fit where you put it (too tall for what's left of the page), it starts the next page, as it
would in any book — the window shows that page and says so; make it smaller or put it a paragraph earlier to keep
it where it was. **Add … to the Book** then sets the whole book again with the pictures in and puts it in place of
the one just made.

A picture stays with its paragraph however the pages move (the contents page is renumbered by itself). Your
choices are remembered for that text — the next time you make it into a book they're offered again — and
**Pictures…** beside Open reopens the window to add, move, resize or remove pictures. From Terminal:
`python3 bookify.py story.txt --picture "map.jpg@front" --picture "storm.jpg@chapter 4,40%,The storm"`.

**A contents page you can click.** In a book made here, every line of the contents page — the chapter's name and
its page number — is a link to that chapter, and the chapters are the PDF's outline (the sidebar in Preview and
Books, and the Contents list in Photo Browser for Mac's viewer).

### Export All Frames and Save Frame (`frame_export.py`)

Right-click a video ▸ **Export All Frames…** (or several videos ▸ **Export All Frames of N Videos…**, or
**All Frames…** in the viewer) — the iPhone app's Export All Frames, with the same choices and names:
every frame, half or a quarter (the rates shown in frames per second), into a folder beside the video named
"<video> Frames" unless you name it, as "<folder> 0.heic", "<folder> 1.heic"… at 1.5× (Lanczos), the
video's capture date kept. An HDR video's frames are tone-mapped like the iPhone's screenshots — **Standard
range** (the default, the press-and-hold screenshot's look; right anywhere) or **HDR** (kept HDR, highlights
eased) — and the choice is remembered. Several videos go one after another, each into its own folder.
**Stop** keeps what's done; exporting the same video at the same rate and colour again carries on where it
stopped. A finished export, or one at another rate, is left alone: the next goes into "<video> Frames 2".

Both use `video_helper.swift` (the iPhone's AVFoundation and Core Image code: frames, tone mapping, HEIC) —
not Qt, so the viewer's old HDR problem never touched them. Why a frame still won't look exactly like the
video in QuickTime: an iPhone video carries Dolby Vision information that the player uses to show it, and a
still frame keeps none of it; a standard-range frame is, on purpose, standard range (HDR highlights brought
down, not clipped); and an HDR frame gets the iPhone screenshots' look (highlights eased, a light trim). Two
things that were wrong are fixed: Save Frame could tone-map a frame that AVFoundation had already brought to
standard range a second time (a darker, duller screenshot), and an HDR frame saved as HEIC is now recognised as
HDR by the viewer (so it's shown in HDR rather than flattened).

Without the helper — no Xcode Command Line Tools, or it didn't build (the compiler's message is then in
`~/Library/Caches/PhotoBrowser/video_helper.log`) — ffmpeg does them instead: JPEG frames, always standard
range, tone-mapped with ffmpeg's own curve when that ffmpeg has `zscale`. Those look different from
QuickTime, so the result says "made with ffmpeg, not the Mac's own tools" and why.

### Send to CapCut, and bring the edit back (`capcut_window.py`, `capcut.py`)

For editing clips in the CapCut desktop app and getting the finished video back onto the drive in one go.

**Send.** Select videos and photos (or a folder) ▸ right-click ▸ **Send to CapCut** (⇧⌘K, also Photos ▸ Send to
CapCut; on a folder's empty area: **CapCut ▸ Send Photos & Videos Here to CapCut**). CapCut opens, and beside it a
small tray that floats over CapCut with the clips **in timeline order** — by date taken (the default), by name,
or as you selected them. Drag the big **Drag all into CapCut** tile onto CapCut's media panel or straight onto
its timeline and every clip goes in, in that order (or drag single rows). The clips stay where they are on the
drive — CapCut uses them from there; tick **Copy to this Mac first** for a project that has to work with the
drive unplugged (they're copied, numbered, into `~/Movies/Photo Browser for CapCut/`). **Copy** puts them on the
clipboard and **Show in Finder** reveals them.

**Back.** Keep the tray open while you edit. When you **Export** in CapCut, the video appears in the tray's
**Back from CapCut** list ("exporting…" until CapCut has finished writing it), and **Import into “<folder>”**
moves it onto the drive, into the folder the clips came from (**Change…** for another): tagged **capcut** plus
every tag its clips carry, and — with **Date it like its clips** — given the earliest clip's date (with ExifTool),
so it sorts with them by year on the iPhone. **Take it off the Mac** unticked copies it instead.

**Import from CapCut…** (right-click a folder ▸ CapCut ▸, or Photos ▸) does the same for any of CapCut's exports,
newest first, the ones already brought in greyed: tick them and bring them into that folder or each back to where
its clips came from. CapCut saves exports wherever its Export panel last pointed, so Photo Browser for Mac looks in the
usual places (~/Movies/CapCut, ~/Movies, Desktop, Downloads, Documents) and remembers the folder after the first
import; pick it in the window if yours is elsewhere.

Photo Browser for Mac never writes CapCut projects itself: recent CapCut versions encrypt them and reject ones made by
other tools, so dragging the clips in is what works with every version.

### Places — where your photos were taken (`places_window.py`, `geo_names.py`, `places.py`)

Every photo and video with a location has a place name the moment it's read — the nearest town, from a table of
170,000 places that ships with the app. Nothing is sent anywhere for it.

- **Go ▸ Places…** (⇧⌘L, or **Library ▸ Places** in the sidebar): a list — Country ▸ State or region ▸ Town, with
  counts — and a **map**. Scroll to zoom, drag to move; photos gather into numbered circles that split as you
  zoom in. Select a place (or a circle) and press **Show Photos**: the main window shows everything taken there
  — a town, a state, or a whole country — as a collection you can view, tag and sort like any folder.
  The map is drawn by the app from country outlines it carries; there's no map service behind it.
- **Read Locations…** in that window reads the photos whose location hasn't been read yet (the iPhone's index
  on the drive already covers whatever the iPhone has seen).
- **Search by place**: `place:paris`, `city:paris`, `state:ny`, `country:france`, `near:"lake tahoe"` (within
  25 km; `near:tahoe~50km` for another distance), `is:located`, `-is:located`. A plain word finds photos taken
  somewhere by that name too: `tokyo` finds files called that *and* photos taken there.
- **Filter by place**: the funnel's **Location** is Country ▸ State ▸ City with counts; pick a town, a state or
  a whole country.
- **Refine Place Names with Apple** (in the Places window): off, names come only from the app's own table. On
  — as the iPhone does — Apple's geocoder is also asked, a place at a time, for the names it knows better
  (neighbourhoods, parks); only coordinates are sent. The iPhone's own names on the drive are always used first.

Place names: GeoNames (geonames.org), CC BY 4.0, reduced to selected columns. Map: made with Natural Earth.
`mac/make_geo_data.py` rebuilds both files (`mac/geo/`) from the sources.

### People — the faces in your photos (`people_window.py`, `people.py`, `faces.py`)

**Go ▸ People…** (⇧⌘E, or **Library ▸ People**): the app finds the faces in your photos and groups the ones that
are the same person — like People in Photos. It all happens on this Mac; you give the names.

- **Find People ▾** — in the folder the main window shows, or on the whole drive. It works in the background
  (a count, and a Stop that loses nothing — next time it carries on). The first time, it explains itself and
  downloads the two small models it needs (39 MB, from OpenCV, checked) — the only time it uses the network.
- **The grid**: a circle per person, their name (or **Add Name**) and how many photos. **Double-click** to see
  their photos in the main window. **Click the name** to name them; a name someone already has merges the two
  (it asks).
- **Getting it right**: select two or more and **Merge**; right-click ▸ **Review Suggestions…** for faces that
  are probably theirs (click once for Yes, again for Not them); **Same Person?** goes through pairs who may be
  one; in a person's photos, right-click ▸ People ▸ **This Is Not Anna** takes a photo out for good, **Make Key
  Photo** chooses their circle. What you say stands — the app never undoes it, and never asks the same thing twice.
- **Also**: Favorite (shown first), Hide, **Tag Their Photos “Anna”** (the name as a tag — so the iPhone app
  shows it too), `person:anna` in the search field (or just `anna`).
- **Privacy**: face data stays in the app's folder on this Mac — never on the drive, never uploaded — and the
  app never puts a name to a face itself. **••• ▸ Forget All Face Data…** deletes every bit of it.

It needs `onnxruntime` (the launcher installs it). Faces in videos aren't looked at yet.

### Find Duplicates (`duplicates_window.py`, `duplicates.py`)

Right-click a folder ▸ **Find Duplicates…** (or a folder's empty space ▸ **Find Duplicates in This Folder…**; or
select several folders ▸ **Find Duplicates in These N Folders…**, which looks at them as one — copies of a photo
in two different folders are found). It's the iPhone app's Find Duplicates, with more. Groups of likely copies
come strongest first:

- **Exact match** (green) — the same size in bytes and the same pixel dimensions. The copies are then read
  through in the background and the group is marked **✓ Identical** when they're the same file byte for byte (or
  says "same size, different bytes" when they aren't). Files whose dimensions can't be read — a RAW the Mac has
  no reader for, a damaged video — are matched by size and their first and last bytes instead.
- **Visually similar** (blue) — the same picture re-saved, resized or lightly edited (a perceptual fingerprint;
  photos only), with **how alike** the copies are ("98% alike"). **Look-alikes: Strict / Normal / Loose** sets
  how alike they must be — Normal is the iPhone's; Loose also catches heavier edits, and more photos that only
  resemble each other.
- **Similar name** (orange) — copy-style names: `IMG_0001.jpg`, `IMG_0001 (1).jpg`, `IMG_0001 2.jpg`,
  `… copy.jpg` (a Live Photo's `.HEIC` and `.MOV` aren't copies of each other).

Each copy is a tile with its **dimensions and size** — or, when the copies' dates differ, the date and time to
the millisecond, with the **Oldest** and **Newest** marked. **Click the copies you don't want** (a red ring),
then **Move to Trash**; it asks first and says if a group would lose every copy. Double-click a tile (or
**View**) to see the group full size in the viewer. Right-click a copy ▸ **Keep Only This One**. **Not
Duplicates** hides a group for good.

**Which copy is kept is a rule** — the **Keep** box at the bottom: *the best copy* (most tags, then a plain name
— not "(1)" or "copy" — then the oldest), *the largest file*, *the highest resolution*, *the oldest*, *the
newest*; and **Prefer Copies in a Folder…** keeps the copy in a folder you choose over copies anywhere else
(scan *Sorted* and *Downloads* together, prefer *Sorted*). The copy the rule would keep wears a green **Keep**
mark in every group, before anything is ticked. **Select Extra Copies ▾** then ticks every other copy — *In
Identical Groups* (the safe pick: they're the same file), *In All Exact Groups*, or *In Every Group Shown*
(look-alikes too: check those).

When copies go to the Trash, **the kept copy takes their tags, Favorite and To AI** (a tick in the
confirmation, on by default) — so a tag put on the duplicate isn't lost with it.

**Include subfolders**, **Leave out “Frame” files** (video-frame screenshots), **Other files too** (documents,
archives and anything else, matched by their bytes) and the strictness are remembered; groups can be sorted by
space, number of copies, name or folder; the scan ends with "132 groups · 418 extra copies · up to 3.2 GB to
free." The photos' fingerprints are kept, so Rescan is quick.

### All of Photo Browser for Mac's windows, at once

Click **Photo Browser for Mac's icon in the Dock** and every Photo Browser for Mac window comes forward — the main window, an open
viewer, Edit with AI, a downloader — not just the main one, even when Photo Browser for Mac is already the app in
front. (Clicking one window still brings only that window forward, as in any Mac app.) **Window ▸ Bring All
to Front** does the same, and the Window menu lists every open window, minimized ones too.

### Videos at the Top — a folder's own choice

In the **Sort** menu (or **View ▸ Videos at the Top**), tick **Videos at the Top** and that folder lists its
**videos first** — right after its folders — and then its photos and other files. Whatever sort you've chosen
still orders the videos among themselves and the photos among themselves. It's remembered **for that
folder**: other folders stay as they are, and the folder comes back that way next time.

It's the same choice as **Photo Browser on the iPhone** (its Sort menu has the same tick): for a folder on
the drive the choice is kept on the drive itself, so a folder you set here is shown videos-first on the
iPhone too, and one you set on the iPhone is shown that way here.

### Sizes, filters, empty folders, and the Trash

- **Folder sizes.** Each pane adds up what its folders hold, in the background, and shows it in the
  list view's Size column (and the folder's tooltip); "Calculate Folder Sizes" in the Sort menu turns
  it off. Sort by Size orders folders by what they hold. The status line shows the selection's size;
  the Move/Copy summary counts folders by it too.
- **Filters — the iPhone app's Type, Format and Location, and Size.** The funnel button next to Sort
  opens four submenus, each titled with what it's set to; they combine, apply to the listing or to search
  results and collections, and the status line says how many are shown and by what ("12 items (4 shown —
  photos · HEIF · Hauppauge, NY)"). **Show Everything** clears them. Type, Format and Size stay as you go
  from folder to folder; a Location is the folder's own and is cleared when you leave it.
  - **Type**: Photos, Videos or Screenshots (a PNG, or a photo with "screenshot" in its name) — as on the
    iPhone. **Format**: JPEG, PNG, HEIF, RAW, GIF, MOV, MP4 or AVI. Either one shows files only.
  - **Location**: opening it reads where the folder's photos and videos were taken, in the background, and
    lists each place with how many are from it ("Hauppauge, NY (3)", "Paris, France (1)") — most first, **No
    Location** last; folders stay listed. It uses the iPhone app's own place names wherever it can: the
    drive's `.Photo Browser Metadata/places.json` (written with every metadata backup on the iPhone) already
    knows the photos it has seen, so they're never looked up again. For the rest it reads the GPS from the
    files (photos' EXIF, videos' QuickTime location) and names new places through Apple's geocoder, as the
    iPhone does — only the coordinates are sent, one place every 1.2 s, at most 60 a time (open it again to
    name more). What it learns is kept in `~/Library/Application Support/Photo Browser for Mac/places.json`. A folder
    with over 8,000 files asks you to open a subfolder, like the iPhone.
  - **Size**: Empty (0 KB), under 1 MB, or 1 MB / 10 MB / 100 MB / 1 GB and up — folders by their
    calculated size (one not calculated yet still shows, except under "Empty"). In a search, `size:>100mb`,
    `size:<1gb` or `size:0` does the same for files (`size:>1gb` alone finds the big ones).
- **Empty Folders** in the sidebar: every folder under Documents, Pictures, Movies and Downloads with
  nothing in it (0 KB — dot files like .DS_Store don't count; a folder holding only empty folders is
  listed once, as itself). Click one to see it in its folder, selected; click "All Empty Folders"
  for the whole list on the From side, where you can select them all and press ⌘⌫. The list refreshes
  after a transfer or a delete, and when you open the collection.
- **Move to Trash.** Select files or folders — in a folder, in search results, All Videos or Empty
  Folders, on either side — and press ⌘⌫ (or right-click ▸ Move to Trash). It asks first, with the
  names and the size, and uses the system Trash, so it can be undone from there.

### Tags — the same tags as Photo Browser on the iPhone

Photo Browser for Mac's tags *are* the app's tags: tag a file here and it has that tag in Photo Browser on the
iPhone (the Tags filter, the info panel, "No Tags"); tag it there and it shows up here. Removing a
tag, renaming one, or moving a file carries across the same way.

- **Folders have tags too.** A folder gets the tag itself — it shows the pill on its tile, it's listed
  under the tag in the sidebar, and on the iPhone it shows up in the Tags filter. Whenever you tag a
  folder (⌘T, the right-click menu, dropping it on a sidebar tag) Photo Browser for Mac asks whether the files
  inside it — in its subfolders too — get the tag as well: **Folder and Files Inside**, **Folder Only**,
  or Cancel. Taking a tag off a folder, or Remove All Tags, asks the same about the files inside that
  have it. Nothing is asked when no file inside would change. A folder carries its tags like a file
  does, so they go along when it's moved or copied.
- **One file or a thousand.** Select files or folders and press
  **⌘T** (or the tag button in the pane's header, or right-click ▸ Tags ▸ Add Tags…). Type a tag, or
  several separated by commas, and press Return; suggestions come from the tags you already use. Every
  existing tag is listed below as a chip: click one to put it on every selected file, click it again
  (✕) to take it off. A tag only some of the files have shows "3/12" — one click puts it on the rest.
  Return in an empty field (or Done) closes the window. Changes are saved as you make them.
- **Right-click ▸ Tags** lists every tag with a tick when all the selected files have it; choosing one
  adds it to all of them, or takes it off when they all have it. "Remove All Tags…" clears them.
- **The sidebar's Tags** lists every tag with how many files carry it. Click one to see all of those
  files together — on the Mac and on the drive — and select, Quick Look, move or re-tag them from
  there. **Drag files or folders onto a tag** in the sidebar to tag them. Right-click a tag to rename it
  or take it off every file. Typing `tag:beach` (or `#beach`) in a search field does the same as
  clicking it.
- **On the tiles:** a tagged file or folder shows a small pill with a coloured dot per tag (each tag
  always gets the same colour) and the first tag's name; the list view shows them as chips beside the
  name, and the status line lists a selected item's tags.
- **Tags stick to the file — however it's moved or copied.** Each tagged file carries its tags itself,
  in a small private field (with a note of where it was) that Finder doesn't show — Finder's own tags
  are a separate thing and are left alone. Move or copy it with Photo Browser for Mac, Finder, the Files app or
  `cp`, or AirDrop it to the iPhone with "AirDrop to iPhone…", and the tags go with it: Photo Browser for Mac picks
  them up when you open the folder it landed in, the app when it next opens the drive. A move leaves
  nothing behind at the old place; a copy keeps the original's tags too; a file put back from the Trash
  gets its tags back. (Cloud folders such as iCloud Drive may drop the private field, and on an exFAT
  drive files can't carry it without `._` clutter — there tags only travel through Photo Browser for Mac.) Tags on
  files still on the Mac are also listed in `~/Library/Application Support/Photo Browser for Mac/tags.json`. A file
  moved to the Trash loses its tags until it's put back. On the iPhone, copies, photos saved as new from
  the photo editor, and AI edits (Edit / Extend with AI, and their images saved later from the Astria.ai
  Browser) all get the original photo's tags.
- **Backed up.** The tags are part of the app's metadata backups (Drive Health ▸ Back Up Metadata Now,
  and the automatic ones), which now sync with the drive first so tags added here are in them. Photo Browser for
  Mac also keeps a copy of each drive's tag file (and the Mac's) from before the first change of each
  day in `~/Library/Application Support/Photo Browser for Mac/Tag Backups/` — the last 14.

**How they stay in step.** The tags of the files on a drive are saved *on the drive*, in the hidden
`.Photo Browser Metadata/shared-tags.json` (the folder the app keeps its metadata backups in), by each
file's path inside the drive. The drive is with one device at a time: Photo Browser for Mac edits that file
directly, and the app merges it with its own tags whenever it opens the drive, gets it back, or
returns to the foreground — and writes its own changes back a couple of seconds after each one (and
on the way to the background). The merge is three-way: a tag added or removed on one side wins over
one left alone, and additions from both sides are all kept. If the file is ever lost or damaged
nothing is wiped — the app fills it back in. Drive Health ▸ Sync Tags with Photo Browser for Mac syncs on
demand and shows when it last did. (Tags are only shared for files on the drive the app has open.)
Each file also carries its own tags (see "Tags stick to the file" above), which is how they survive a
move or copy that neither app saw.

### Favorites and To AI — the same as the iPhone app's

Select items and right-click ▸ **Favorite** / **To AI** (or Photos ▸ Favorite **⇧⌘F**, Photos ▸ To AI **⇧⌘A**, the
♡ and ✦ buttons in the viewer, or drop items on **Favorites** / **To AI** in the sidebar). Choosing it again when
every selected item already has it takes it off (Unfavorite / Remove To AI). A favorite shows a white heart on its
tile, a To AI item the iPhone's sparkles. The sidebar's **Labels** section shows how many there are and opens
either as a list of everything with it — on this Mac and every connected drive (Go ▸ Favorites / To AI too).
**Folders can be favorites as well as files**, exactly as on the iPhone: a favorited folder has the heart on its
tile and is in the Favorites list beside the photos and videos.

They are the iPhone app's Favorites and To AI, both ways: they're kept in the drive's shared tag file
(`.Photo Browser Metadata/shared-tags.json`, beside the tags, under `labels`), and the app merges that with its
own whenever it opens the drive, comes back to the foreground, or a label or tag changes — a heart added or taken
off on either side reaches the other, as tags do. Like the app's, they stay with the original when an item is
copied, follow it when Photo Browser for Mac moves it to the SSD, and go when it's moved to the Trash. Items on the Mac's
own disk keep theirs in Photo Browser for Mac's own file. A file moved by Finder (not Photo Browser for Mac) leaves its labels behind.

### Crop photos — one crop on many (`crop_window.py`, `batch_crop.py`)

Select photos, right-click ▸ **Crop…** (or **Crop N Photos…**). Draw the crop on the first: drag inside
the box to move it, a corner to resize, a side to trim just that side (Freeform), or pick a ratio —
Original, 1:1, 4:5, 3:2, 16:9 — and turn it a quarter left or right. **‹ ›** (or the arrow keys) show
the same crop on each of the other photos; **Last Crop** puts back the crop you saved last. **Crop N
Photos** crops them all in place, one at a time (**Stop** ends it after the photo in hand), and tags
every one "cropped" — the same tag, and the same arithmetic, as the iPhone app's Crop screen.

The crop is kept as fractions of the photo, so it lands on the same spot of photos of another size; a
fixed ratio keeps its shape on photos shaped differently. Each photo keeps its format, EXIF (capture
date, location — pixel size updated), colour profile, XMP, tags and dates. JPEG, HEIC (with
pillow-heif), PNG, WebP, TIFF and BMP can be cropped; GIFs and RAW files can't. HDR photos come out
standard range here (the iPhone app keeps HDR). A photo that can't be read is left as it was and
listed at the end.

### AI Upscale 2× (`ai_upscale.py`, `upscale_window.py`)

Select photos, right-click ▸ **AI Upscale 2×…** (or **AI Upscale N Photos 2×…**). Each photo is upscaled
by **Real-ESRGAN** — a real super-resolution neural network, not a resize — running on your Mac's graphics
chip; nothing is uploaded. Photo Browser for Mac asks first, with three choices (each remembered for next time):

- **Model** — the photo models beside the engine, each with a note on what it's like. They differ a lot:
  Upscayl Standard is clean and smooth; Remacri and High Fidelity keep more natural texture; UltraSharp is
  very crisp and cleans noise away.
- **Keep texture** (0–100 %, 25 % to start) — these networks are trained to clean noise away, and grain and
  fine texture go with it. This blends that much of a plain enlargement of the original back in: the
  original's grain at that strength, most of the AI sharpness kept. 20–40 % looks natural on most photos.
- **Save as New** or **Replace**:

- **Save as New** (the first time's default) puts each upscale beside its photo as "name (upscaled).jpg"
  ("(upscaled 2)" if that's taken) and leaves the original as it is. The new photo carries everything the
  original does: format, capture date, location, colour profile and the rest of the metadata, the same
  created and modified dates (so it sorts next to it), its other file attributes, and its tags.
- **Replace** rewrites each photo in place, keeping all of that.

Either way the result is tagged "upscaled" (the iPhone app's tag for its upscales), and the answer is
offered first next time. The bar follows the network as it works through each photo (Real-ESRGAN reports
its progress tile by tile), with the time left; **Stop** ends at once and leaves the photos in hand as they
were. The status line says how long it took.

**Speed.** The network runs on the Mac's GPU. What's done around it to go faster: the network's 4× result
comes back as a quality-100 JPEG rather than a PNG (for a 12 MP photo that's a 192 MP image, and PNG made
handing it over about as slow as the network itself) and is decoded straight at the 2× size; Macs with
more memory use bigger tiles than the engine picks on its own (fewer, larger GPU jobs — if that ever fails
or comes out black, the photo is done again at the engine's size and the rest follow); and with 16 GB or
more, two photos are upscaled at once, so the GPU works on one while the other is read or saved.
`PHOTO_BROWSER_UPSCALE_TILE=200` (or `0` for the engine's own pick) overrides the tile size.

Real-ESRGAN isn't part of macOS. The easy way to get it is the free **Upscayl** app
([upscayl.org](https://upscayl.org), or `brew install --cask upscayl`): install it and Photo Browser for Mac finds
its engine and models on its own. A `realesrgan-ncnn-vulkan` release works too — unzip it into
`~/Library/Application Support/Photo Browser for Mac/Real-ESRGAN` — or point Photo Browser for Mac at either with **Choose
Engine…** the first time (remembered). The best general-photo model found is used (Upscayl's standard
model, else `realesrgan-x4plus`; anime and digital-art models are passed over). The models are 4×: the
network upscales 4× and the result is brought to exactly 2× with Lanczos. GIFs and RAW files can't be
upscaled; HDR photos come out standard range. From the shell: `python3 mac/ai_upscale.py [--new] [--large]
photo.jpg …`.

**Photos that are already large** (over 12 MP) can be upscaled too. The options window then warns how big
the result will be — e.g. "this photo is already 8,064×6,048 (48.8 MP); upscaled 2× it would be
16,128×12,096 — 195 MP, about 176 MB as JPEG — and take about 4× as long as a 12 MP photo" (with the total
for several) — and, when only some of the selection is large, has a **Upscale the N large photos too** box
(untick it to leave them as they are). They go through the network in tiles, so the Mac's memory only ever
holds a 12 MP photo's worth of work plus the result. A result over 400 MP (a 100 MP photo), or wider than
its format can hold (JPEG 65,500 px, WebP 16,383 px), isn't attempted, and the window says which.

(The iPhone app's "AI Upscale" is not a neural network — it's Lanczos with denoise and sharpen.)

### Convert WebP to JPEG (`webp_window.py`, `webp_convert.py`)

Right-click a folder (or its empty area) ▸ **Convert WebP Photos Inside / Here to JPEG…**, or select some `.webp`
files ▸ **Convert to JPEG…** (also Photos ▸ Convert WebP to JPEG…). Photo Browser for Mac counts them, offers **Include
subfolders** and **Move the WebP originals to the Trash when their JPEG is saved** (both remembered), and makes
each one a JPEG beside it:

- **full resolution** — never scaled — at **quality 95 with full colour detail** (4:4:4, so colour edges stay
  sharp);
- the colour profile, EXIF (capture date, camera, GPS) and XMP kept, and the file's own dates, so it sorts where
  the WebP did; transparency goes onto white;
- a JPEG that only had a .webp name is kept byte for byte (no re-encoding); an animated WebP is left as it is (a
  JPEG can't move); a JPEG of the same name already there is never overwritten ("name 2.jpg");
- the tags go with each photo — and when the original goes to the Trash (only after its JPEG has been written and
  checked), its Favorites / To AI follow it too, as for a move.

### Erase Area — take a watermark off photos (`erase_window.py`, `retouch.py`)

Select photos, right-click ▸ **Erase Area…** (or **Erase Area on N Photos…**). Drag a box over what should
go — a watermark you added by mistake, a date stamp, a blemish; several boxes are fine (drag one to move
it, a corner to resize, Delete or right-click to remove it). The boxes are fractions of the photo, like a
crop, so one set fits every selected photo; ‹ › steps through them to check each.

- **Just the Mark** (the default) erases only what stands out inside the boxes — the letters or the logo
  — and keeps the photo between and under them. A see-through watermark (white or black text, a grey logo
  at some opacity) is *taken back out*, so the real photo under it comes back, detail and all; its soft
  edges, and any opaque or coloured mark, are filled from around it. **Sensitivity** sets how faint a mark
  still counts — higher also takes more of the photo, so check **Original**, which shows what will go in
  red.
- **Whole Box** replaces everything inside the boxes, filled from around them with the photo's own grain
  laid over it. Best for an opaque logo on a plain area; across a sharp edge (a face, a horizon) it can only
  blur.

The result shows as soon as a box is drawn. **Save as New** writes "name (retouched).jpg" beside each
photo with the same metadata, dates and tags; **Replace** rewrites them in place. The results are tagged
"retouched"; **Last Area** brings back the boxes used last. Photos where Just the Mark finds nothing in the
boxes are left alone (and counted). It erases what you box; it doesn't look for watermarks on its own.
(Needs numpy — `Photo Browser for Mac.command` installs it; rebuild the app with `build_app.sh`.)

### Remove Watermark — your own watermark, off many pieces at once (`watermark_window.py`, `watermark.py`)

For art you signed with a see-through watermark — anywhere on the piece, once or many times, and with words
that change from piece to piece ("John Meier artwork", "2025 n498rfhd", "34987h34rtf98") — where the original
without it is gone. Select the pieces — or folders of them — and right-click ▸ **Remove Watermark…** (or
**Remove Watermark from Photos Inside…** on folders; or Photos ▸ Remove Watermark…).

- **The first time**, drag a box round **one whole copy** of the watermark on the first piece. It learns the
  watermark from that copy (and any other copies on the piece) and shows the piece with them taken out.
  Stars, sparks and detail under the letters come back, because the see-through letters are *taken back out*
  of the picture, not painted over.
- **After that it finds it by its look**, whatever the words: the same white, the same see-through strength,
  the same size and slant of lettering. On the next pieces it finds every line of your watermark by itself —
  one copy or many, anywhere, in any words — and takes it out. Pieces with the very same words as one it has
  seen are matched exactly. It looks ahead through the pieces while you look at one, so ‹ › is quick.
- **If it finds nothing on a piece, or misses something**, drag a box round one copy on that piece — it
  learns that one too (handy if some pieces were signed in a different size or style). **Look Again**
  forgets a piece's result and looks again; **Original** shows the piece as it is with what will go in red.
  **Forget** clears everything it has learned.
- **Save as New Photos** writes "name (no watermark).jpg" beside each piece with the same metadata, dates and
  tags; **Replace Originals** rewrites them. Pieces where no watermark was found are left alone (and
  counted). Results are tagged "retouched". Running it again on a folder skips the "(no watermark)" copies.

It needs a watermark of one colour (a white or black see-through mark; a drop shadow would stay) and lines of
four letters or more. A copy sitting on art as light as the ink (white on near-white) can't be read and is
left. For a single opaque logo, use Remove Objects; for something boxed in the same spot on every photo,
Erase Area. Each piece takes ten to thirty seconds. Check a few results with **Original** before replacing
anything. The learned watermarks are kept in `~/Library/Application Support/Photo Browser for Mac/Watermarks`. (Needs
numpy, like Erase Area.)

### Remove Objects — draw round it and it's gone (`remove_window.py`, `inpaint.py`)

TouchRetouch on the Mac. Right-click a photo ▸ **Remove Objects…** (or Photos ▸ Remove Objects…, or ⋯ in the
viewer), then:

- **Lasso** (L) — draw round a person, a sign, a bin, a wire… and let go: it's gone. **Brush** (B) paints over
  it instead (handy for thin things); **Eraser** (E) takes back part of a mark; [ and ] change the brush size.
  With **Remove as I draw** off, mark several things and press **Remove** (or Return).
- **Undo** ⌘Z / **Redo** ⇧⌘Z, one removal at a time; **Compare** (press and hold, or hold Space) shows the
  original; ⌘-scroll or pinch zooms (or − / Fit / +), scrolling moves around. Esc stops a removal that's
  running, or clears the mark.
- **Save as New** puts the result beside the photo as "name (retouched).jpg" with the original's tags;
  **Replace Original** writes it in place. Either way the format, metadata (date, place, camera), the file's
  dates and its tags are kept, and the result is tagged "retouched". Closing with changes asks first.

**How it fills the hole.** Not by smearing the surroundings in (Erase Area's fill, made for thin watermarks),
but with the photo itself — the method behind Photoshop's Content-Aware Fill: every small patch of the hole is
matched to the most alike patch elsewhere in the photo, the matches vote on each pixel, and that repeats from
a small version of the photo up to full size, so the big shapes (a horizon, a wall, a path) carry through
first and then the texture and grain. The last pass copies real pixels rather than averages, so grass, sand,
skin and noise look like the rest of the photo. The object's soft edge is taken with it, and a big area is
worked at a smaller size and brought back to full resolution along the same matches. A person-sized area
takes a few seconds; the bar shows how far it's got. Everything happens on this Mac — nothing is uploaded.

It works best when what's behind the object is like something else in the photo (sky, grass, water, a wall, a
crowd); a unique thing hidden behind it can't be known, and gets the most plausible fill from around it. Draw
the lasso a little outside the object, with its shadow if it has one.

### The photo editor — filters, adjustments, retouch, text (`photo_editor_window.py`, `photo_edit.py`, `photo_text.py`)

Right-click a photo ▸ **Edit ▸ Photo Editor…** (**⌘E**), Photos ▸ Edit Photo…, or ⋯ ▸ Edit Photo… in the viewer.
What Hypic, Facetune, Snapseed and Lightroom do on a phone, done to the photo where it lives. The photo is on
the left; seven tabs on the right:

- **Filters** — 52 looks in ten groups (Film, Portrait, Black & White, Vivid, Moody, Warm, Cool, Vintage,
  Pastel, Duotone), each shown on your photo, with a **Strength** slider. A filter is a recipe of the
  adjustments below, so the adjustments go on top of it.
- **Adjust** — **Auto**, then Exposure, Brightness, Contrast, Highlights, Shadows, Whites, Blacks; Saturation,
  Vibrance, Warmth, Tint; Sharpen, Clarity, Texture, Dehaze, Noise Reduction; Fade, Grain, Vignette, Glow;
  Split Tone (a colour for the shadows, one for the highlights); eight **Colour Bands** (red … magenta) with
  Hue, Saturation and Lightness each; Black and White. Double-click a slider's name to put it back.
- **Crop** — a box with twelve shapes (Freeform, Original, 1:1, 4:5, 5:4, 3:4, 4:3, 2:3, 3:2, 9:16, 16:9, 2:1),
  turn left / right, flip either way, and **Straighten** (the photo is zoomed just enough to stay full).
- **Retouch** — brushes you paint with: **Smooth** (skin, noise), **Heal** (paint over a spot, a wire, a stray
  hair — it's filled from the photo, the same fill as Remove Objects), **Whiten** (teeth, eyes), **Details**,
  **Blur**, **Lighten**, **Darken**, **Red Eye** (click the pupil), **Reshape** (drag an edge to where it
  should be). Size, strength and soft edge are sliders; [ and ] change the size. Below them, **Background
  Blur**: a round or a band of sharpness you place by dragging, the rest blurred.
- **Face** — **Smooth Skin** works on all the skin in the photo. With the face finder the People feature uses
  (downloaded once, 40 MB, kept on this Mac) there are also Brighten Face, Brighten Eyes, Whiten Teeth, Larger
  Eyes, Slimmer Face, Narrower Nose and Smile, for every face in the photo. They're worked out from where the
  eyes, nose and mouth are, so they're gentle on purpose; for more, use Reshape.
- **Text** — **Add Text** (or double-click the photo), as many as you like. Drag text to move it; drag its
  corner dot to size and turn it. Eighteen ready-made styles (Outline, Shadow, Neon, Label, Pill, Subtitle,
  Banner, Poster, Sunset, Comic, Typewriter, Script, Stamp…), every font on the Mac grouped by kind, 28
  colours and any other, a fade into a second colour, bold / italic / underline / capitals, alignment, letter
  and line spacing, outline, shadow, glow, and a background (box, rounded, pill, or a bar across the photo).
  **Sticker ▾** adds an emoji you can move and size the same way.
- **Frame** — Border, Polaroid, Rounded Corners, Cinema Bars, and **Fit to Shape** (the whole photo in a
  square, a story or any other shape without cropping — on a colour, or on itself blurred).

**Undo** (⌘Z) and **Redo** (⇧⌘Z) step through everything; **Compare** — hold the button, or Space — shows the
photo before; ⌘-scroll or pinch zooms. While a slider moves you see a quick rough picture, and the proper one
when it rests.

Three ways to save, bottom right:

- **Save as New** (⌘S) — "name (edited).jpg" beside the photo; the original isn't touched.
- **Overwrite Original** — in place (it asks first: this one can't be taken back).
- **Save and Upscale…** — saves either of those ways, then enlarges the result with Real-ESRGAN — the engine
  inside [Upscayl](https://upscayl.org), on this Mac. You choose the **model** (every photo model your
  Upscayl has: Standard, High Fidelity, Remacri, UltraSharp…), **2×, 3× or 4×**, and how much of the photo's own
  **texture** to keep.

Whichever you choose, the saved photo is the same kind of file as the original — **a HEIC stays a HEIC**, with
its colour profile (Display P3 stays Display P3) — and keeps its capture date, camera, GPS, XMP, the file's
created and modified dates and its extended attributes. A new photo gets the original's **tags**; the result
is tagged **edited** (and **cropped** / **upscaled** when it was). Saving works on every pixel at once — a
48 MP photo needs about 3 GB of memory for those few seconds, and **Stop** (where Close was) ends it while the
picture is still being worked out.

**An iPhone photo stays HDR.** An iPhone photo is two pictures in one file: the ordinary one, and a small
grey *gain map* that says how much brighter each part should be on an HDR screen. The editor — and Crop,
Rotate, Erase Area, Remove Objects, Remove Watermark, AI Upscale and Paste Edits — now carry that map through:
it's turned, straightened, cropped and reshaped with the picture, filled in where something was removed (so a
lamp you took out doesn't go on glowing), given no extra brightness under a border, and written back with the
original's metadata, HEIC or JPEG. The editor says "HDR photo — it stays HDR when saved" under the picture's
size. Writing the map uses macOS itself (a small helper built the first time; it needs Xcode's Command Line
Tools — `xcode-select --install`); when it can't be done the photo is saved as before, in standard range, and
you're told. On macOS 14 and earlier only Photos shows the result as HDR; from macOS 15 Preview and Quick Look
do too. Filters and adjustments are seen *through* the map, as on the iPhone. A frame saved from an HDR video
(a PQ / HLG photo, which has no gain map) is still edited and saved in standard range, and collages are
standard range.

**Edits ▾** (bottom left) carries an edit to other photos:

- **Copy Edits** (⇧⌘C) keeps the filter, adjustments, face sliders, blur and frame — not the crop, brush
  strokes or text, which belong to this photo. **Paste Edits** (⇧⌘V) puts them on the photo you're editing.
- From the main window, select photos ▸ right-click ▸ **Edit ▸ Paste Edits onto N Photos…** (or Photos ▸ Paste
  Edits…): the copied edit on every one of them, saved as new photos or over the originals — metadata, tags
  and HDR kept, tagged **edited**.
- **Save as My Look…** keeps the edit by name; your looks are listed in the same menu, for any photo.

The **Adjust** tab begins with a histogram — the picture's tones from dark to light, with a red mark at an end
when shadows or highlights are clipped.

**Heal is saved as you saw it.** The fill a Heal stroke makes is decided once, on the picture shown in the
window, and carried to the full-size photo in the photo's own detail — it used to be worked out again at full
size, and could come out differently from what you'd approved.

**Edit Again from the Original** (`edit_history.py`). When you Save as New, the edit itself — every slider, the
crop, the brush strokes, the text — is kept on this Mac beside nothing (in Application Support; the drive and
the photo get nothing extra). Open the "(edited)" copy in the editor later and **Edits ▾ ▸ Edit Again from the
Original** opens the *original* with all of it back where you left it; change what you like and **Update the
Edited Copy** writes over the copy. The original is never touched. It's offered only while the copy and the
original are both unchanged since (crop the copy elsewhere, or overwrite the original, and it isn't — "again"
would silently undo that), and not for a copy that was renamed, moved, or saved with Save and Upscale.

### Make Collage — two to nine photos on one picture (`collage_window.py`, `collage.py`)

Select **two to nine photos** ▸ right-click ▸ **Make Collage of N Photos…** (or Photos ▸ Make Collage…).

- **Layout** — every arrangement in rows and columns for that many photos, drawn small: even grids, strips,
  one large with the rest small — up to forty for each number of photos.
- **Shape** — 32 of them: square; portrait 4:5, 3:4, 2:3, 9:16, 1:2, 1:3; landscape 5:4, 4:3, 3:2, 16:9, 2:1,
  21:9, 3:1; prints (4×6, 5×7, 8×10, A4, Letter, upright or sideways); screens (Instagram post and story,
  Facebook cover, X header, YouTube thumbnail, Pinterest pin, Mac desktop, iPhone wallpaper).
- **Size** — "as large as stays sharp" (no photo enlarged past its own pixels), or 1,080 to 8,192 px on the
  long side.
- **Spacing**, **Margin**, **Rounded Corners**; the **background** colour, or the first photo blurred.
- **Format** — JPEG, HEIC or PNG.

On the collage itself: **drag a photo onto another to swap them, drag inside its cell to slide it, scroll to
zoom** (double-click puts it back). Shuffle reorders; Add Photos… takes it up to nine; right-click a photo to
remove it.

**Save** writes "Collage 2024-07-04.jpg" beside the first photo. It takes **the oldest photo's capture date**
(in its metadata and as the file's dates) and that photo's place, and **every photo's tags**, plus
**collage**. **Save and Edit…** then opens it in the photo editor, for text, filters and frames.

### Stitch Videos — several clips into one (`stitch_window.py`, `video_stitch.py`)

Select **two or more videos** ▸ right-click ▸ **Edit ▸ Stitch N Videos…** (or Photos ▸ Video ▸ Stitch Videos…).
Drag the clips into the order they should play — or **Oldest First**, **Newest First**, **By Name** — and press
**Stitch**.

- Clips that are the same kind (two takes from the same iPhone, say) are **joined as they are**: no quality
  lost, done in seconds.
- Clips that differ in size, frame rate or format are **re-encoded** onto one canvas — each clip fitted inside
  it, with bars where a clip is another shape — at one frame rate. You choose the size (the first clip's, the
  largest clip's, 1080p, 4K) and the frame rate. HDR clips stay HDR (10-bit HEVC); a clip without sound gets
  silence.

The new video is saved beside the first clip as "name (stitched).mp4" and takes:

- **the oldest date** of the clips — as its capture date and as the file's created and modified dates;
- **the place** — the oldest clip's, or the first clip that has one;
- the oldest clip's camera make and model, title, description and keywords (with ExifTool installed);
- **every clip's tags**, plus **stitched**.

**Trim** a clip by selecting it and setting *from* and *to* (in seconds) under the list — exact when the clips
are re-encoded; at the nearest key frames when they're joined as they are (tick **Always re-encode** for exact
cuts). **Add Clips…** brings in more videos from anywhere. HDR clips mixed with standard ones are brought to
standard range, so the result looks right on every screen.

The window says all of that before you start. It needs ffmpeg (`brew install ffmpeg`); without it, a built-in
AVFoundation joiner is used (no trimming). The clips themselves are never changed.

### Receive from iPhone — AirDrop into "From iPhone" (`airdrop_window.py`, `airdrop_receive.py`)

On the iPhone, select photos and videos in Photos ▸ Share ▸ AirDrop ▸ this Mac. macOS always puts them in
**Downloads**. Then **File ▸ Receive from iPhone…** (**⇧⌘I**): they're listed, newest first, all ticked, and
**Move to “From iPhone”** puts them on the drive.

- The folder is the drive's **existing "From iPhone"** — found by name (near where you are, or at the top of
  the drive) and remembered. **Change…** picks another; if the drive has none, the window offers to make it.
- Each file is copied onto the drive, **read back and compared** with the original (SHA-256), and given the
  original's dates. Only then does the original go to the Mac's Trash — or stay in Downloads, if you choose that.
- The very same file already there is skipped. A different file with the same name is kept as "IMG_1234 2.HEIC".
  Nothing on the drive is replaced. A Live Photo's two halves (HEIC + MOV) — and an edit's .AAE — come over
  together and keep one name: if "IMG_1234" is taken, all of them become "IMG_1234 2".
- Only AirDropped photos and videos are listed (macOS marks what AirDrop received); tick **Show every photo
  and video in Downloads** to see the rest.

**Once you've opened this window, the app watches for AirDrops** while it's open and says so — "3 photos
arrived by AirDrop" with a **Move to “From iPhone”** button. Tick **Move them without asking** in the window and they go straight to the drive.
(The first time, macOS asks whether the app may read your Downloads folder.)

### Download an Instagram or Facebook profile (`social_downloader.py`, `instagram.py`, `facebook.py`)

Right-click a person's folder ▸ **Download Instagram Profile…** or **Download Facebook Profile…** (on a
profile's own folder it says **Get New Instagram Posts** / **Get New Facebook Posts**). Type the handle (or
paste the profile link) and press Download. The window holds a real browser: log in to Instagram or
Facebook there once — it stays logged in — and if the site asks "is this you?", answer it there. Photo Browser for Mac
then reads the profile *from inside that logged-in browser*, exactly as the site's own pages do, so it sees
what you see (private profiles you follow included), and never fills in a login or answers a check itself.

- **Instagram**: the posts, the posts it's tagged in, its reels, its current stories (into `Stories`) and
  highlights (a folder each) — the same as the iPhone app. Videos come at the best quality offered: when
  Instagram has a sharper version in two halves (picture and sound), they're put together on the Mac.
  **Checking for new posts asks Instagram as little as it can**: once the profile's folder knows the account's
  number (from an earlier run on either app) the run goes straight to its posts — no "looking up" step, which
  is what Instagram limits first. If Instagram says to slow down anyway, the newest posts still come (from the
  top of the profile page, opened once) and the log says to press Download again in 10–15 minutes for the
  rest. When posts have to be read from the page itself, scrolling stops as soon as it reaches posts that are
  already downloaded. If a run ever stops on an error, the details are kept in
  `~/Library/Logs/Photo Browser for Mac/instagram-downloads.log`.
- **Facebook**: every album (profile and cover pictures included), every photo it uploaded, **every photo
  it's tagged in** (always — whoever posted it), and its videos. The first run reads every uploaded and
  tagged photo; later runs stop once they reach 12 already downloaded in a row — but only after a run got
  all the way through with everything downloaded. An album read to its end is remembered by its first and
  last photo, so the next run reads only what's new at its front and its end (an unchanged album is two
  page reads instead of one per photo). A run that was stopped, hit a login wall, or had a photo fail reads
  the whole set again next time, and **Check every photo again** always does (it finds an old photo someone
  tagged since). The pace adapts: it speeds up a little while Facebook answers quickly and fully, slows down
  at the first slow, empty or "too many requests" answer, and never goes past 50 pages a minute — if
  Facebook answers a photo's page empty (it does when it's being asked too fast), it backs off and reads it
  again rather than taking it for the end. The log ends with how many pages a run read. **Photos under 200 KB are upscaled
  2× automatically** (tagged **upscaled**). Every photo and video gets **the date it was uploaded to
  Facebook** — written into it with its time zone and set as the file's dates.
- **Upscale photos 2×** (Lanczos with a light sharpen — or Real-ESRGAN when Upscayl is installed and
  "with Real-ESRGAN" is ticked) and **Upscale videos to 1080p**, as each file comes in. Upscaled files are
  tagged "upscaled" too.

Every file is tagged **instagram** or **facebook**, gets the post's date (and place, caption and poster
when ExifTool is installed), and lands in a folder for the profile inside the one you right-clicked —
`<person>/<handle>` for Instagram, `<person>/<name>` for Facebook — with the iPhone app's file names
(`<shortcode>.jpg`, `<shortcode>_2.mp4`, `FB_<id>.jpg`).

**Nothing is downloaded twice, by either app.** The profile's folder keeps a hidden record
(`.instagram.json` / `.facebook.json`) of every post downloaded into it — by Photo Browser for Mac *or* the iPhone,
which reads and writes the same file — and both apps also take the post ids in the folder's file names as
done. A post you delete from the folder stays deleted. "Get New" reads newest first and stops once it
reaches what's already there.

Videos are put together and upscaled with AVFoundation — a small helper Photo Browser for Mac builds the first time
(it needs Xcode's Command Line Tools: `xcode-select --install`), the iPhone app's own code — or with ffmpeg
when that's installed instead (`brew install ffmpeg`). Neither: videos come in their one-file version, not
upscaled (the log says so). The browser needs Qt WebEngine (part of PySide6, set up by `run.sh`).

### Folder birthdays and Age

Right-click a person's folder ▸ **Set Birthday…** and pick the date. Every photo and video in that folder (and its
folders) then shows an **Age** in the viewer's Info — how old they were when it was taken. **Go ▸ Folder
Birthdays…** lists every folder with a birthday, to change or remove one. The birthdays are the iPhone app's own:
they're kept on the drive, so one set on the Mac shows up on the iPhone the next time it opens the drive (or comes
back to the front), and the iPhone's show up here — including the ones you set on the iPhone before this existed.

### Dates from file names

Right-click photos, videos or folders ▸ **Dates ▸ Set Dates from File Names…** (or the Photos menu). Every photo and
video — inside the folders too — whose name holds a date gets that date as its own created and modified date:
`johnmeier_2026_11_16_4398yr.mp4` becomes 16 November 2026, `something_2025_12_16_4389348934_3498349834.jpeg`
16 December 2025 (at noon, when the name has no time), as do `IMG_20240613_101530`, `VID-20240613-WA0001`,
"Screenshot 2024-06-13 at 10.15.30" and the like. The window lists every file with the date it found before
anything changes. **Set** chooses whether the date also goes *inside* the photo or video as its capture date
(where it has none — the default — or always), which is what the iPhone app's Year filter and Age go by. Names in
another shape: type a pattern such as `name_%Y_%m_%d`. Undo (⌘Z) puts the file dates back.

**Restore Capture Dates…** is the iPhone app's: for files a copy or an import stamped with "now", each one's date
comes back from its name — or, when the name has none, from the date inside it.

### Exclusive (subscriber-only) posts from Instagram and Facebook

If you subscribe to a creator on Instagram or Facebook, their **Exclusive** posts, reels, stories and photos now come
down with everything else when you run Download Instagram/Facebook Profile… — as long as the window's browser is
logged in as the account that subscribes. They're tagged **exclusive** (as well as instagram / facebook), so the
sidebar's Tags ▸ exclusive or a search for `tag:exclusive` finds them. Exclusive things you downloaded before get
the tag too the next time a run comes across them. Posts that are locked for your login — only a blurred preview —
are left, and the log counts them.

On Facebook the creator's subscriber content is read **first**: the window opens the profile in its browser, finds
its tab for subscribers (Subscriptions / Exclusive, under More too), opens it and scrolls it to the end, then reads
every photo and video it showed. Tick **Only exclusive** to get just that — a quick run; leave it off and the full
download takes it first, then everything else. If nothing is found, the log says so and saves what Facebook showed
in `~/Library/Logs/Photo Browser for Mac/facebook-hub-….json` (it stays on your Mac) — send that along if you are
subscribed and it still comes up empty.

Long Facebook runs no longer hold the app up: the reading happens off the window, the browser shows a blank page
while it runs, and the tags are saved once every 90 seconds. The whole log is kept in
`~/Library/Logs/Photo Browser for Mac/facebook-downloads.log`, with a line whenever the window was held up for more
than 3 seconds and what it was doing at the time. Reads speed up (to 75 a minute) while Facebook answers well and slow
down at the first sign it doesn't.

### To Delete

Beside the ♡ in the viewer there's a bin: click it (or press **⇧⌘X**) to tag the photo or video **to-delete**. It
turns red, and the item's tile gets a small red bin next to its heart. In the main window it's under Favorite in
the right-click menu and in the Photos menu (⇧⌘X too), for everything selected; Undo (⌘Z) takes it back. Nothing is
deleted — it's a tag, so you can go through them later (sidebar ▸ Tags ▸ to-delete) and delete them then. The
iPhone app sees the tag too.

### Download from Google Drive — files and whole folders, with their dates (`gdrive_window.py`, `gdrive.py`)

Right-click a folder ▸ **Download ▸ Download from Google Drive…** (or the Download menu in the menu bar). What you
pick comes down into that folder.

- **Browse your Drive**: My Drive, Shared with me, Starred, Shared drives, or a search by name. Tick files — or tick
  a folder to take **everything inside it**, with its subfolders rebuilt on the drive. Click a folder's arrow to look
  inside first.
- **Or paste links** — one or several, files or folders — and press Add Links. They're added to the list, ticked.
- **Download** runs four files at a time, with a progress bar, Stop, and a line for anything that didn't come.

**What you get is the file exactly as it is in Drive** — the same bytes, nothing re-encoded, so the EXIF (capture
date, camera, GPS), colour profile and everything else inside a photo or video is untouched. Each file is checked
against Drive's own size and checksum before it's put on the drive. The file's **modified date is Drive's modified
date** (the file's own date from when it was uploaded) and its **created date** the earlier of that and Drive's
created date; folders get their Drive dates too. Nothing is overwritten: a file already there is skipped, and a
different file of the same name is kept beside it as "name 2.jpg". Run it again later and only what's new comes.

Google's own documents (Docs, Sheets, Slides) aren't files — they're counted and left; export them from Drive if you
want them.

**Signing in — a one-time setup.** Google lets a desktop app read a Drive only through its official sign-in, and
that needs a small free "project" of your own (about five minutes; the window's **Set Up…** button shows the same
steps and opens the page):

1. Open [console.cloud.google.com](https://console.cloud.google.com) and create a project (any name).
2. APIs & Services ▸ Library ▸ search "Google Drive API" ▸ **Enable**.
3. APIs & Services ▸ OAuth consent screen (also shown as "Google Auth Platform"): choose **External**, give it a
   name and your email, and under Audience ▸ **Test users** press Add users and add the Google address you'll
   sign in with — **your own too**. Without it Google answers *"Access blocked: … has not completed the Google
   verification process (Error 403: access_denied)"*; add the address and sign in again.
4. APIs & Services ▸ Credentials (or Google Auth Platform ▸ Clients) ▸ Create ▸ **OAuth client ID** ▸ Application
   type **Desktop app**. Copy the **Client ID** and **Client secret** into Set Up….
5. Optional: Create Credentials ▸ **API key** and paste it too — then links shared "anyone with the link" work
   without signing in.

Then **Sign In with Google…**: your own browser (Safari, Chrome) opens Google's page — "Google hasn't verified this
app" is expected for a project of your own, choose Continue — you approve, and the window carries on. (While it
waits, the window says what to do about "Access blocked" and has a button for the Test users page.) The access asked for is **read-only** — the app can't change or delete anything in your Drive. The
secret and the sign-in are kept in the Mac's Keychain. While the project is left in "Testing", Google ends the
sign-in after 7 days and the window asks you to sign in again; publishing the project (same page) removes that.

**Without any setup**, a single *file* shared "anyone with the link" can still be pasted and downloaded (not a
folder, and Drive gives less about its dates that way).

This is different from the iPhone app, which shows Drive in a browser inside the app. On the Mac, Google's own
sign-in in your own browser is the supported way, so that's what's used.

### Download photos from a Depop shop (`depop_downloader.py`, `depop.py`)

Right-click a folder ▸ **Download ▸ Download from Depop…** (or the Download menu in the menu bar).

1. Type the shop's name or paste its link and press **Open** — or find the shop in the page on the left; it's a
   real browser. If Depop shows a "checking your browser" box, answer it there.
2. The shop's photos appear on the right as the page loads them. **Load Whole Shop** scrolls to the end for you.
   With **Get each listing's other photos too** ticked, every photo of each listing shows up, not just the first
   (each listing's page is read for them, one every couple of seconds).
3. **Click the photos you want** — ⌘-click or ⇧-click for several, drag across them, double-click one to take
   its whole listing, or Select All.
4. Tick **Upscale every photo 2×** if you want them enlarged as they arrive (with the AI upscaler when one is
   installed — the one AI Upscale 2× uses — otherwise a plain enlargement).
5. Press **Download N Photos**.

**Upscaling**: tick **Upscale** and choose how — one of the AI upscaler's models (when one is installed; the
one AI Upscale 2× uses), or **Clean** (best for compressed shop photos: smooths JPEG blocks, keeps edges), **Sharp**
or **Soft** — then **2×, 3× or 4×**, and for AI, how much of the photo's own **texture** to keep (more = less
"plastic"). Select a photo and press **Preview…** to see it enlarged plainly and your way, side by side, before
downloading anything.

**Sold items**: with **Include sold items** ticked (it is to begin with), Load Whole Shop goes on into the shop's
Sold tab once the listings for sale are in — or press **Sold Items** to open that tab yourself. Sold listings' photos
get a yellow SOLD band, **Show:** picks Everything / For sale / Sold, and the ones you download are tagged **sold**
as well as depop.

Each photo comes down in the largest version the shop has of it — the window checks rather than assumes, and the
log says which it took — as `<listing>_<n>.jpg` in `<your folder>/Depop/<shop>`, with the listing's description
and date in the file and the "depop" tag ("upscaled" too, when it was). Photos already downloaded show a green
tick and aren't fetched again, in this window or the next time.

Depop's terms don't allow automated collecting; this saves photos you pick while you look through a shop, at a
person's pace. It hasn't been tried on depop.com itself yet (only on a stand-in shop): if a shop shows nothing on
the right, the status line says so rather than guessing.

### Download what you've bought on Fanfix (`fanfix_downloader.py`, `fanfix.py`)

For creators you subscribe to or bought posts from on Fanfix: a personal archive of the content your account
can open. Right-click a folder ▸ **Download ▸ Download from Fanfix…** (or Photos ▸ Download from Fanfix…; on a
creator's own folder it says **Get New Fanfix Posts**). The window holds a real browser: log in to Fanfix there
once — it stays logged in — and answer Cloudflare's "checking your browser" there if it asks. It never fills
in a login or answers a check itself.

Then open what you want saved — a creator's page (type the handle and press **Open Creator**: app.fanfix.io/@name),
**Home Feed** (everyone you subscribe to), **Purchases** (your Gallery of everything you've bought) or a chat in
**Messages** — and press **Download from This Page**. The page loads afresh and scrolls itself to the end, in
front of you, while Photo Browser for Mac reads what the page loads and shows (the same posts you see), and downloads
every photo and video you can open there **through that same browser** — your login and Cloudflare's OK go with
it, the way browser-extension downloaders do it:

- into a folder for each creator inside the one you right-clicked (`<folder>/<creator>`, or the folder itself
  when it's the creator's), named by Fanfix's media id, dated from the post (and captioned, with ExifTool),
  tagged **fanfix**; **Upscale photos 2×** and **Upscale videos to 1080p** as for Instagram;
- full size: the original of each photo (a WebP saved as a real JPEG), not its thumbnail; a video as its own
  file, or as one MP4 put together from its stream; pay-per-view posts you bought included;
- **left out** (and counted): posts you haven't bought (their blurred teasers), creators' avatars and banners,
  and anything protected by DRM — those can only be watched on Fanfix.

**Chats.** Open a chat and press Download: its whole history is read (the chat scrolls up until Fanfix has
nothing older). Open **Messages** itself and press Download: every chat, one after another, each into its
creator's folder.

**What Fanfix won't let anyone save.** Fanfix delivers what you've *bought* — pay-per-view messages and sets,
photos as well as videos — only as DRM-protected streams (FairPlay/Widevine); there's no plain file for them.
Photo Browser for Mac doesn't break DRM, so it counts those ("N bought photos/videos … protected by DRM") and leaves them on
Fanfix. Free messages and posts come down as their full-size originals.

**Profile pictures from the earlier version.** It mistook creators' avatars for posts. After a run, Photo Browser for Mac
lists any such files it recorded as downloads and offers to move them (and any folder made only for them) to the
Trash; nothing else is touched.

The creator's folder keeps a hidden record (`.fanfix.json`) of everything downloaded, so **Get New Fanfix
Posts** takes only what's new, and a file you delete stays deleted. Your Fanfix login never leaves that browser
(and Fanfix's own servers). If something you can see on a page isn't downloaded, press **Save Troubleshooting
File** — it writes the last run (what the page loaded and showed, what was found, what failed and why) to
`~/Library/Logs/Photo Browser for Mac`, on this Mac only — and send it over. Streams need yt-dlp (`run.sh` installs it) or
ffmpeg.

### Download a TikTok profile (`tiktok_downloader.py`, `tiktok.py`)

Right-click a folder ▸ **Download ▸ Download TikTok Profile…** — the iPhone app's TikTok downloader on the
Mac. Type the handle (or paste a profile link) and press Download: the profile's own videos come down
watermark-free at the highest quality offered, as `<post id>.mp4` (a slideshow's photos as
`<post id>_1.jpg`, `_2.jpg`…) in an `@handle` folder — exactly the names and folder the iPhone uses. No
login; only the public handle goes out.

- **It carries on from the iPhone.** A folder the iPhone downloaded into is recognised (by its record, by the
  app's backup on the drive, or simply by being an `@handle` folder of TikTok-named videos), the menu says
  **Get New TikTok Videos**, and only what isn't there yet is fetched. Both apps keep a record in the folder
  (`.tiktok.json`), so neither downloads what the other has.
- **Likes are read again every run** — for every video on the profile, not just the new ones — and saved in
  the record. Sort the folder by **Reactions / Likes** to see the most-liked first; the viewer's Info shows
  the count. The iPhone picks the counts up on its next run.
- Each file gets the post's date and caption and the tag **tiktok**.
- If the listing service (tikwm.com) puts up a "checking you're human" page, a small browser appears at the
  bottom of the window — tick its box if it asks; the download carries on by itself.

### Rename, Duplicate, Rotate — and Remove Leading Spaces from Names (`rename_tools.py`, `rename_window.py`)

- **Rename…** (F2, or right-click): a new name for one file or folder.
- **Rename several at once.** Select the files and right-click ▸ **Rename N Items…** (F2) — or right-click a
  folder ▸ **Rename Files Inside…** for every file in it. Choose how to name them and in what order:
  - **Name them** — a ready-made pattern or your own: *1, 2, 3 …*; *Photo 1, Photo 2 …*; *the capture date and
    time* (2024-03-15 14.30.05); *the capture date, then a number*; *the capture date, then the name it has*;
    *the folder's name and a number*. In your own pattern, `{n}` is the number, `{name}` the name it has now,
    `{date}` and `{time}` the capture date (also `{year}` `{month}` `{day}`), `{folder}`, `{camera}`,
    `{width}` `{height}` — so `Paris {n}` or `{date} {name}`.
  - **In the order of** — **Capture date** (when the photo or video was taken, read from the file), Name, Date
    modified, Date created, Size, or the order they're in now; *Last first* turns it round. So photos named
    for the time they were taken become **1, 2, 3 …** in the order they were shot: pattern `{n}`, order
    Capture date.
  - **Numbers** — where they start, and plain (1, 2, 3) or padded (01, 001…).
  - **Find → Replace** changes text inside `{name}`.
  The list shows every *now → becomes* and updates as you type. Extensions are kept. If a new name is already
  used by a file you're not renaming it says so in red and won't rename anything until the pattern (or the
  starting number) is changed; two files that would get the same name are told apart with " 2". A file with
  no capture date inside uses its file date (the list marks it). Names can swap ("2.jpg" becoming "1.jpg"
  while "1.jpg" becomes "2.jpg") — nothing is overwritten on the way.
- **Remove Leading Spaces from Names…** (right-click a folder, or the empty area for the folder you're in):
  every file *and folder* inside whose name starts with a space (or a tab, or an invisible space) gets the
  name without it. The window lists every `old → new` first; untick **Include subfolders** to do just the
  folder's own items. A name is never put over one that's taken — it gets a number instead ("a 2.jpg").
  From Terminal: `python3 mac/rename_tools.py "/Volumes/SSD/Folder"` (a dry run; `--apply` renames).
- **Duplicate** (⌘D): a copy beside each selected file — "name copy.jpg" — with its tags and Favorites.
- **Rotate ▸ Left / Right / 180°**: turns the selected photos and videos in place. A video isn't re-encoded
  (only its "show it turned" note changes, so nothing is lost and it takes a moment) — the quick fix for
  videos that play upside down. Needs ffmpeg for videos (`brew install ffmpeg`).

**Nothing is lost by a rename.** Tags, Favorites and To AI move to the new name at once. Everything the
iPhone app keeps itself — captions, covers, birthdays, hidden items, a download folder's link to its
profile — follows too: Photo Browser for Mac notes each rename on the drive, and the app applies them the next time
it opens the drive.

### Upscale Video — 1080p or 4K (`video_upscale_window.py`, `video_tools.py`)

Right-click one or more videos ▸ **Upscale Video…**. Choose **1080p** or **4K**, the **frame rate** (the
video's own, 30 or 60 — a different rate repeats or drops frames; nothing is invented), and whether to
**replace the video** or save the result **as a new video beside it** ("name (1080p).mp4"). Videos already
that size are left as they are — nothing is ever scaled down. The capture date, metadata and tags are kept;
results are tagged **upscaled**. HDR videos stay HDR. 4K is slow and makes large files. It uses the Mac's
own video engine when Xcode's Command Line Tools are installed, else ffmpeg.

### Clone Drive to a New SSD — move the whole library without losing anything (`clone_window.py`, `clone_drive.py`)

**File ▸ Clone Drive to a New SSD…** copies everything on one drive to the same place on another, and
proves it.

1. **On the iPhone first:** open the old drive in Photo Browser ▸ Drive Health ▸ **Back Up Metadata Now**
   (so the drive carries everything the phone knows). Restore or empty Recently Deleted if you can.
2. Erase the new SSD as **APFS** in Disk Utility. Plug both drives into the Mac.
3. In the window choose the old drive and the new one, and press **Clone**.
   - The old drive is only read — nothing on it changes.
   - Every file is written, **read back from the new drive and checked** before it counts; its dates
     (created and modified), tags and other attributes come with it, folders' too.
   - The hidden records come along: the iPhone app's backup and shared tags, each download folder's
     record, Recently Deleted. macOS's own clutter (`.DS_Store`, `._` files, Spotlight) doesn't.
   - **Stop**, a pulled cable or a sleeping Mac lose nothing: press Clone again and it carries on.
     Nothing of yours on the new drive is ever overwritten.
4. When it finishes the two drives are compared and a report is shown (and saved in
   `~/Library/Logs/Photo Browser for Mac/`). **"0 problems"** means everything is there. Tick *read every byte of both
   drives again* for the surest check (it takes about as long as the copy); if it ever finds a file that
   differs, **Copy … Different Files Again** fixes it.
   The report also names anything that's only on the new drive (things added there since).
   Lines that say **"COPIED, but not with the same modification date / creation date / attribute"** are
   items that *are* on the new drive — only that date or attribute isn't the old drive's (a folder's date moves
   as soon as anything is added to it; a stopped clone hasn't dated its folders yet). **Match Dates and
   Attributes** gives them the old drive's; it sets dates and attributes only, never a file's contents, and
   leaves a file that was really changed on the new drive as it is.
5. Press **Give the New Drive the Old Drive's Name…** (the old one becomes "Name (old)").
6. Plug the new SSD into the iPhone and choose its top folder. If any Favorites, captions or covers are
   missing: Drive Health ▸ **Restore from the Drive's Backup** — it only adds what's missing.
7. Keep the old drive as it is until you've looked through the new one.

**Check Files — is everything on the drive still what was written?** An SSD's file system (APFS) doesn't
notice when the contents of a file go bad; the file just reads back wrong. So the clone keeps a checksum of
every file it writes, on the new drive itself (a hidden `.Photo Browser Checksums` folder). Any time later,
choose the drive as the *new drive* and press **Check Files**: every file is read again and compared. A
file that has the same size and date as when it was written but different contents is listed as
**DAMAGED** — put that one back from another copy. Files you've edited since (a different size or date)
and files added since aren't damage; **Record New Files** reads them once so the next check covers them
too. On a drive cloned before this existed, tick *read every byte of both drives again* and Verify once
(with the old drive), or just press Record New Files. The old drive isn't needed for a check, and nothing
on the drive is changed.

The Mac is kept awake while a clone, a comparison or a check runs.

From Terminal: `python3 mac/clone_drive.py "/Volumes/Old" "/Volumes/New"` (a dry run), `--apply` to copy,
`--verify --deep` to compare byte for byte, `--verify --match-dates` to give items whose dates or
attributes differ the old drive's; `python3 mac/clone_drive.py --check "/Volumes/New"` to check a drive's
files against their checksums (`--record` to add the ones that have none yet).

### Browse taylorpictures.net — and see what's already in your Taylor Swift folder (`taylor_window.py`, `taylor.py`)

Right-click your Taylor Swift folder ▸ **Browse taylorpictures.net…** — the iPhone app's gallery browser, with
that folder as where albums go. Go through the site's sections (double-click; ‹ Back or ⌘[ to come out) to
its albums, each with its cover, a **Here** column and how many photos it has; the field at the top finds an
album by title.

**First, the whole site against the whole folder.** The first time the window opens on a Taylor Swift
folder it compares the two before anything else: it lists every section and album on taylorpictures.net,
reads each album's photo list, and checks every one against every photo in the folder. You can browse while
it runs (the panel at the top shows how far it's got; Stop keeps what's been read, and Continue — or simply
opening the window again — carries on from there). Then it says, e.g., **"8,912 of the 12,340 photos in your
Taylor Swift folder are on taylorpictures.net. Of the site's 3,260 albums, you have all of 1,203, some of 400
and none of 1,657"**, and every album everywhere shows its Here count. From there:
- **Albums With Photos to Get** — every album on the site you have only some of (the closest to complete
  first), with links to the ones you have none of and all of; double-click one to see what's missing, or
  pick several and Download Selected.
- **Tag Them…** — gives your photos that are on the site the tag "taylorpictures.net" (they then show under
  Tags in the sidebar, and on the iPhone). Only when you press it.
- **Check Again** — later on: looks for new albums on the site (reading only those) and compares again.
- **Also find photos saved under other names** — off by default: it also fetches every thumbnail on the site
  once (kept on the Mac afterwards) to recognise renamed copies by their picture. Much slower the first time.

The site's album and photo lists are kept in `~/Library/Caches/PhotoBrowser/taylor/` (`site.json`, and the
comparison per folder), so later opens show the totals at once.

**What you already have.** Photo Browser for Mac looks through the Taylor Swift folder when the window opens — every
photo's name at once, then its picture (a quick fingerprint, kept between launches) — and marks:
- in the album list, **✓ All here**, "87 of 120", "Folder here", or nothing yet. **Check Albums Here** reads
  every album of the section and fills the column in (by name, so it's quick);
- on an album's page (double-click it), a green ✓ on each photo you have — in the album's own folder, under
  another folder by the same (distinctive) name, or saved under another name entirely (found by its
  picture); hover to see where. **All / Missing / Here** filters the grid. Double-click a photo you have to
  see your copy in the viewer; one you don't opens on the site.

**Downloading.** **Download N Missing** on an album gets just the photos you don't have; **Download All**
everything not already in the album's folder; in the list, **Download Selected** or **Download N Not Here**
queues whole albums. They come down one after another, eight photos at a time, into `Taylor Swift/<album
title>` (the folder the iPhone app uses too), with the album's date on photos that carry none — from the
title ("2023-05-05 …", or "3/17 …" in a "2023" section) — written by ExifTool when it's installed. **Skip
photos already in Taylor Swift** (on by default) leaves out the ones found elsewhere in the folder. Stop
keeps what's done; downloading again finishes it.

Both apps keep `Taylor Swift/.taylorpictures.json` — the albums downloaded into the folder — so an album
downloaded on the iPhone shows as downloaded here, and the other way round. Pages are only read; nothing
is sent to the site.

**Connecting.** Photo Browser for Mac makes the iPhone app's request (its browser agent, Accept and language headers),
and reads a page whatever status the site sends it with, as the iPhone does. If Python's own networking can't
get through — a certificate chain macOS would complete but Python won't, a dropped connection — the same
request goes through the Mac's own networking (URLSession, what the iPhone uses; the video helper, built once
with Xcode's command line tools), which then goes first. If neither can read it, the window says why from each
(“the site answered 403 Forbidden”, “its certificate couldn't be checked …”, “it didn't answer within 30
seconds”).

### Edit with AI, Create with AI and the Astria.ai Browser (`ai_window.py`, `astria.py`)

The iPhone app's cloud AI (astria.ai), on the Mac. It's opt-in: until you add your Astria API key nothing is
sent anywhere, and then only the photo you're editing and any reference photos you pick. The key is kept in
the Mac's Keychain (every AI window asks for it the first time; **Astria Settings…** changes it, the default
model and the models' tune ids).

- **Upscale results 2× (Lanczos).** A tick under "How many" in the Edit and Create forms: every result is
  enlarged to twice its width and height on this Mac as it comes back from Astria — a 2K result becomes 4K —
  with plain Lanczos resampling (no AI, no sharpening, and nothing extra charged by Astria). The results
  window shows the enlarged pictures and that's what Save writes; saved files get the **upscaled** tag. The
  choice is remembered, and results picked up after the app was quit mid-generation are enlarged too.
- **If nothing reaches Astria.** Open **Astria Settings…** (the button in any AI window) and press **Check
  Connection**: it asks Astria one small question each of the two ways the app can reach it — Python's own
  networking and the Mac's built-in `curl` — and says in plain lines what each got and what that means; **Copy**
  puts the lines on the clipboard. The app also does this by itself: if Astria's front door (Cloudflare) answers
  one way with its "Just a moment…" browser check, the same request goes the other way at once, and whichever
  gets through is used from then on. **If both are checked, Cloudflare is checking your network's address** —
  a check only a person can answer. A small window, **Astria — Cloudflare's check**, then opens with the check
  in it: answer it as you would in Safari, the window closes by itself, and from then on the app's Astria
  requests go through that window's browser (it asks again whenever the check runs out; **Not Now** leaves it
  for a couple of minutes). Check Connection opens it too. If the check can't be passed there either, it's down
  to another network (a phone hotspot) or Astria's support — send them the lines Check Connection shows.
- **When Astria says wait.** If Astria's front door (Cloudflare) checks or rate-limits a request, the whole app
  pauses its Astria requests for as long as asked, the job's status says "Astria asked this Mac to wait —
  sending in 30 s", and it's sent again by itself (up to four times). If it still fails, the message says what
  actually came back — a Cloudflare check, a rate limit, an upload that's too large, Astria's servers not
  answering, or Astria's own refusal — with its reference number, and every refused request is kept in
  `~/Library/Logs/Photo Browser for Mac/astria-requests.log`. A check that keeps coming back is about the
  network (try without a VPN) or too many requests in a short time, not the API key — a wrong key gets its own
  message.
- **Edit with AI** — right-click a photo. Write what to change (an optional negative prompt goes along in
  the text, as on the iPhone); the prompting reminder, the two reusable prompts (Use / Copy) and your recent
  prompts (double-click to reuse; right-click to ♥ one — hearted prompts are never dropped) are right there.
  Pick the model — **Seedream 5.5** (the default), Seedream 5.0 Pro / 5.0 Lite / 4.5, Nano Banana Pro / 2.1 / 2,
  or Flux — and up to ten of your own tunes (only the ones that can run on that model are listed), reference
  photos (any photos; up to 10 or 14, none on Flux), resolution (1K/2K/4K — **Seedream 5.5 and 5.0 Pro are
  always 2K**, Flux takes none; a size a model doesn't have is greyed out), the shape
  (Original keeps the photo's) and how many (1–8). Everything is remembered for next time.
- **Several photos, one prompt.** Select the photos (2, 5, 30…), right-click ▸ **Edit N Photos with AI…**, and
  write the prompt once — "Remove the bookshelf behind Johnny". **Generate for N Photos** sends each photo to
  Astria with that prompt and the same settings (four at a time; the rest wait their turn) and opens **one
  window for all of them**: each photo with its original beside its name, its results appearing under it as they
  arrive. When every photo is back, **Save All** puts each photo's results in the "AI" folder beside it
  ("<name> AI.jpg", with that photo's date, place and tags). Click a result to leave it out; double-click to
  see it full size (←/→ then goes through the whole batch). A photo Astria couldn't do says why and has
  **Try Again** — the others aren't sent again. "How many" is per photo (5 photos × 2 = 10 images; over 20
  images it asks first). Closing while some are still with Astria is fine: they're saved to their folders when
  they arrive, the next time Photo Browser for Mac's AI is used.
- **Create with AI** — right-click a folder (or its empty space): the same, from a prompt alone.
- **Generate** opens the job's window: it shows what Astria's doing ("2 of 4 ready…"), then the results.
  Click one to leave it out, double-click to see it full size in the viewer, then **Save** — an edit's
  results go into an "AI" folder beside the photo as "<name> AI.jpg" with the photo's date, place and tags,
  a creation's into the folder's "AI" folder; the model and prompt are written into each file. Closing with
  results unsaved asks first. **Run Again** opens the form as it was. If you quit while Astria is still
  working, the images are saved to the folder the next time you use Photo Browser for Mac's AI (within two hours).
- **Astria.ai Browser…** — see the next section.

### The Astria.ai Browser (`astria_browser.py`)

Right-click a folder ▸ AI ▸ **Astria.ai Browser…** (or Photos ▸ Astria.ai Browser…): everything your Astria
account has made — from Photo Browser for Mac, the iPhone app, or Astria's own site — newest first.

- **Looking.** Each prompt has a heading (its model, date, how many pictures, how many you've downloaded) with
  the prompt under it and its pictures in a tight grid. **All Pictures** (top right) drops the headings for one
  dense grid; hold the pointer over any picture for its prompt. The Size slider sets the tiles. A green ✓ marks
  what's already downloaded. It opens on what it showed last time and brings itself up to date in the
  background; **Reload** (⌘R) reads again, **Load Older** goes further back.
- **Finding.** The search field (⌘F) takes words from the prompt, the model or the date — all must match;
  `"golden hour"` keeps words together, `-blurry` leaves a word out, `date:2026-10`, `before:2026`,
  `after:2026-06` go by when it was made. Capitals and accents don't matter. Beside it: one model, **Not
  Downloaded** / **Downloaded**, newest or oldest first.
- **Picking.** Click selects one; ⌘-click adds or removes; ⇧-click takes everything between; the circle in a
  tile's corner ticks it without touching the rest; a heading's **Select All**; ⌘A for everything shown.
- **Viewing.** Double-click (or Space): the picture as large as the window, ← → through everything shown,
  with its model, date, size and whole prompt beside it — Download, Copy Prompt, **Use Prompt in Create with
  AI…** (the prompt and model filled in), Copy Image, Show in Photo Browser.
- **Downloading.** **Download N Selected**, or with nothing selected **Download All N New** (everything shown
  that you don't have yet; more than 50 asks first). Four come down at a time with a progress bar and Stop;
  any that fail are counted and **Retry** fetches just those. Right-click a picture for the same on it alone.
- **Where to.** The **Download to:** button — *This Folder* (whatever folder Photo Browser for Mac is showing, so it
  follows you), *Its AI Folder*, one of the last few folders you chose, or **Choose Folder…**. The choice is
  remembered.
- **What you get.** The file exactly as Astria made it — nothing re-compressed, in its own format, with all of
  its own metadata — and added to that metadata, only where the file has none: the **prompt** (as its
  description/caption, and in the app's "AI-generated · Prompt: …" comment), the model, the date it was made,
  and the standard "made by AI" label. The file's date is when it was made. With ExifTool installed every
  format is handled; without it JPEG and PNG still are (the rest are kept as they came, and it says so).
  Every download gets the **AI** tag — in Photo Browser for Mac's Tags and, through the drive, on the iPhone.

It only reads from Astria: nothing is uploaded and nothing on your account is changed.

### AI models — a person, pet, object or style from your photos (`ai_models_window.py`, `ai_models.py`, `local_ai.py`)

Select 5 or more photos and right-click ▸ **Make AI Model from N Photos…** (or right-click a folder ▸ AI ▸
**Make AI Model from Photos Inside…**; up to 500 are looked at). Photo Browser for Mac keeps the sharpest, most varied
ones — about 30 for a person, pet or object, up to 100 for a style — and leaves out blurred shots, tiny ones
and near-copies; it tells you how many of each. Give it a name and say what it is ("woman", "golden
retriever", "ceramic mug"). For a person, tick that it's you or someone who has agreed. Your photos aren't
changed; the model is a set of copies kept on the Mac.

**AI ▸ AI Models…** (also in the Photos menu) lists them. Pick one, describe a picture, and choose what
makes it:

- **On this Mac — FLUX.2 klein 4B.** Private and free: nothing is uploaded, and after the one-time setup it
  doesn't use the network. The model's first photos go in as reference images. The first Generate sets it
  up, after telling you what it downloads (the engine, about 1 GB; the model, about 17 GB, of which about
  4 GB is kept). It needs **uv** first — `curl -LsSf https://astral.sh/uv/install.sh | sh` in Terminal, or
  `brew install uv`. What you get depends on the Mac's memory: with **16 GB**, pictures at 768 px by default,
  two reference photos, and a few minutes each — close other apps while it runs. Pictures go into the "AI"
  folder of the folder you're in, like any other creation, and are marked as AI-made.
- **Seedream 5.0 Pro, Nano Banana Pro / 2.1 / 2 … (Astria).** Opens Create with AI with the model's photos
  already attached as references (10 for Seedream 5.0 Pro, 14 for the others). These run on Astria, on your
  account, and the photos are uploaded there, as with any Create with AI.
- **Train on Astria…** makes a real trained model (a Flux LoRA) from the whole set, on Astria — a Mac needs
  32 GB of memory to train one itself, so a 16 GB Mac can't. Astria charges for it and it takes a while;
  when it's ready it's one more choice here and a tune in Create / Edit with AI, on the iPhone too.

"Nano Banana Pro" is new in the model list of both apps.

### Download a SimpCity thread into a person's folder (`simpcity_downloader.py`)

Right-click a person's folder (or the empty area inside it) ▸ **Download from SimpCity…**, paste the
thread's address (`https://simpcity.cr/threads/…` — any page of it), and press **Download**. Every page
of the thread is read; each goonbox.cr photo is saved at full size and each turbo.cr video saved, into
a `simpcity` folder inside the person's folder, tagged **simpcity**. A photo or video that carries its
own capture date keeps it; one that doesn't gets the date of the post it came from (needs
[ExifTool](https://exiftool.org) — `brew install exiftool` — otherwise only the file's date is set).
WebP photos are saved as JPEGs, and photos under 250 KB are upscaled 2× (Lanczos) and also tagged
**upscaled**. **WebM videos are made into MP4s** (H.264 + AAC, same size and length — the iPhone, Photos
and QuickTime don't play WebM); this needs ffmpeg (`brew install ffmpeg`) — without it they stay WebM and
the log says so. WebMs already in the folder, the iPhone's downloads included (it can't convert them),
are converted the next time you run it on that folder; their tags move to the MP4. Files downloaded before these rules — and the ones that got 12/31/1969 as their date —
are put right the next time you run it on that folder (it reads the thread from page 1 once to find
their real post dates).

**pixhost images.** Photos posted from pixhost (pixhost.cc — and pixhost.to, pixhost.org, pixho.st) come
too, full size: a post's pixhost thumbnail or its link to the image's page, and every image of a pixhost
**gallery** a post links. They're saved as `pixhost-<number>.<ext>`, tagged **simpcity**, dated like the
rest (a gallery's images get the date of the post that linked it), and kept in the same record, so neither
app downloads one twice. They're photos, so they come with **Download videos and zips** off too.

**Videos.** With **Download videos and zips** ticked (it remembers the setting), the turbo.cr videos come too,
and so do the videos the posts link on **pixeldrain, gofile, cyberdrop, bunkr** (.cr/.ws/.ru…),
**filester** (.gg/.me) and **fileditch** (fileditchfiles.me, fileditchvids.st) — single files and whole
folders/albums, videos only. They're saved as `<host>-<id>.mp4` (or `.mov`…), dated and tagged like the
rest. **The same video is downloaded once**, however many hosts it's posted on: hosts that say a
file's size up front are matched by it before anything is fetched (the preferred host's copy is the one
downloaded — pixeldrain, then gofile, cyberdrop, turbo, filester, fileditch, bunkr — and the next copy
is tried if that fails), a download whose size matches a video you already have is stopped as it
starts, and a finished one whose contents (SHA-256) match is dropped. The log says which ("= … is the
same video as …"). Untick it for photos only — the videos are remembered and come the next time it's
ticked, without reading the thread again. filester, fileditch and gofile are read through their own
pages in the window's browser (if one asks whether you're human, answer it there); gofile folders go one
at a time, and if gofile starts limiting requests the rest wait for the next run.

**Zips.** A zip file linked on **pixeldrain** (e.g. `pixeldrain.com/u/…`), **cyberdrop** or **bunkr** comes too
(with the same tick). Each is unpacked the moment it's downloaded, while the rest of the run goes on: every
photo and video in it — and in a zip inside it — goes into `simpcity` as `<host>-<id>-<its path in the zip>`
(e.g. `pixeldrain-DQBmsLp2-Set 1_IMG_0001.jpg`), with the same treatment as any download (WebP → JPEG, small
photos 2×, WebM → MP4, its own date or the post's, tagged **simpcity**, the post's reaction score). Anything
else in the zip (text files, macOS's `__MACOSX` leftovers) is left out, a password-protected file is skipped
with a note, and a video you already have from another link isn't saved twice. The zip itself isn't kept,
and it's never downloaded again. Links read before this — the ones that turned out to hold no video — are
looked at once more, so zips in threads you've already downloaded come in on the next run. (RAR and 7z
files can't be opened without extra tools and are still left alone; the iPhone app still skips zips.)

**Long threads.** SimpCity limits how fast pages can be read, so pages are read a couple of seconds
apart. If it still says "too many requests", the downloader waits (30 s, then longer) and reads that
page again, going slower from then on. If it keeps saying so, the run downloads what the pages read so
far hold, and the next **Get New** carries on from the page where it stopped.

**Locked pixeldrain videos.** pixeldrain locks popular files behind a captcha ("hotlinking"). When
another host has the same video, that copy is downloaded instead. When none does, each one opens in the
window at the end of the run: press **Download** there and answer pixeldrain's captcha, and the download
is saved like the rest. If nobody presses it within a few minutes, the remaining ones wait for the next
run.

The window is a real browser (Qt WebEngine, with its own saved login): SimpCity shows threads only to
members, so log in there once (**Log In to SimpCity**); if a site asks whether you're human, answer it
in the window and the download carries on by itself.

**It remembers.** What was downloaded is kept on the drive, in `<person>/simpcity/.simpcity.json` —
the same record the Photo Browser app on the iPhone uses — so a thread downloaded here is never
fetched again on the iPhone, or the other way round. The next time, the button says **Get New** and
starts at the last page it reached ("Read every page again" to start over); files that failed are tried
again. Deleting a downloaded file doesn't bring it back next time. Run it on its own with
`python3 mac/simpcity_downloader.py "/Volumes/SSD/Helen Owen" [thread-address]`.

**Reaction scores.** Every page read also notes how many reactions each post with a photo or video has
(the names under the post plus "and N others" — the post's own count, not the "Reaction score" next to a
member's name, which is their lifetime total). They're kept in the same record, so the iPhone reads them
too. Sort a `simpcity` folder by **Reactions / Likes** (sort menu; highest first) to see the most-reacted
downloads first — the score shows on each tile while you do; the iPhone app's sort is **Most reactions**.
For things downloaded before scores were kept — or to bring old scores up to date — right-click the
person's folder (or its `simpcity` folder) ▸ **Get Reaction Scores**: it reads every page of the threads
the folder was downloaded from, for the scores alone (nothing is downloaded). A big thread takes a while
(pages are read a couple of seconds apart, as SimpCity wants); stop it any time — the next run carries
on from the page it reached.

### Install it as a Mac app

```sh
sh mac/build_app.sh                    # → /Applications/Photo Browser for Mac.app (or ~/Applications)
```

Builds `Photo Browser for Mac.app` with [PyInstaller](https://pyinstaller.org) (installed into `mac/.venv`),
with its own icon, and copies it to `/Applications`, so it opens from Launchpad, Spotlight or the
Dock like any app. The first time it opens, macOS asks whether it may use Desktop, Documents,
Downloads and external drives — say yes (System Settings ▸ Privacy & Security ▸ Files and Folders
later). The app is a snapshot of the code: run the script again after every `git pull`. It keeps
the same settings, staging folder and journal as `Photo Browser for Mac.command`, and carries the drive
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
> relocation tool, spare folders and the name adjustments are for the old **exFAT** drive only — Photo Browser for
> Mac notices the filesystem and leaves all of that alone on APFS (names are copied exactly as they
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
   folders in a hidden `.Spare Folders` folder with their lists below the line. Photo Browser for Mac and the
   iPhone app make every new folder by renaming one of those into place, so new folders open on the
   iPhone straight away. Top them up now and then (Drive Health ▸ New folders shows how many are left;
   Photo Browser for Mac warns before a transfer that needs more than there are):

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

## The bulk editor (`bulk_editor/`) — the earlier, smaller app

The first Mac companion to the iOS app (it was the one called "Photo Browser for Mac" until November 2026;
the app above does all of this now — Edit Metadata…, Rename N Items… — and this one is kept as it was). Connect the
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

### Requirements

- macOS 12+ (it also runs on Linux for development)
- Python 3.10+
- **ExifTool** — `brew install exiftool`. Browsing works without it; reading/writing metadata needs it.

### Run

```sh
cd mac
./run.sh --bulk-editor   # creates .venv, installs PySide6 / Pillow / pillow-heif, launches
```

or manually:

```sh
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
.venv/bin/python -m bulk_editor
```

### Using it

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

### Layout

```
bulk_editor/
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
