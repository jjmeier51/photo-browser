# CLAUDE.md

Guidance for AI assistants working in this repository.

> **Photo editor:** for a full description of the in-app photo-editing module
> (every tool, how it's built, and the invariants), see
> [`docs/photo-editor-capabilities.md`](docs/photo-editor-capabilities.md). Read it
> before changing anything under `PhotoBrowser/PhotoEditor*.swift`.

> **Feature & change notes:** for in-depth notes on the cloud AI (Astria) features,
> Find Duplicates, Compare PNGs, exFAT/large-folder reading, Drive Health, Storage, folder
> filters, and the downloaders — with the *why* behind each and the hard-won
> constraints — see [`docs/feature-notes.md`](docs/feature-notes.md). Read it before
> touching `AIExtend.swift`, the AI views, `DuplicatesView.swift`,
> `coordinatedContents`/`listing` in `Library.swift`, or the downloaders.

> **Video editor (`PhotoBrowser/VideoEditor/`, all `VE*` types):** the CapCut-style
> non-destructive editor that keeps every byte under `<DriveRoot>/VideoEditor/`.
> See `docs/feature-notes.md` §11 for the architecture (document → composition builder →
> one Core Image compositor shared by preview, export and covers), the storage rules
> (nothing in the sandbox, atomic saves, drive-loss handling) and the phase plan before
> changing it. Entry points live in `FolderView` ("Edit in Video Editor", "New Video
> Project", "Add to Video Project…", Library ▸ Video Projects).

## What this is

**Photo Browser** is a native iOS/iPadOS app (SwiftUI) for browsing and managing
photos and videos that live in a **folder on an external drive** (or any
file-provider location), rather than in the system Photos library. You point it
at a root folder; it walks subfolders like albums, generates thumbnails, lets
you view/zoom/scrub media, edit metadata, label items (Favorites / "To AI"),
import from and export to the Photos library, and move whole folders between
drives — all while keeping per-item labels and captions attached.

There are no third-party dependencies — it is pure Apple frameworks. A core
design value is **offline, on-device, privacy-preserving** browsing: nothing is
ever uploaded, and the app reads only the one folder the user explicitly grants
access to. The network exceptions are both opt-in and *download-only* (never
upload): "Add from MEGA" pulls photos/videos from a user-pasted public MEGA
folder link, and "Browse taylorpictures.net" browses that public Coppermine
gallery and downloads whole albums into a drive folder. Outside those explicit
actions the app makes no network calls.

> History note: the project grew over ~50 commits from a simple browser into a
> Photos-like app. An earlier repo layout kept the app under an `ios-app/`
> subdirectory (built with XcodeGen, bundle id `com.example.photobrowser`) and
> also contained an unrelated Python forum-crawler. **This repo is the cleaned-up
> version** — the iOS app is at the root, built from a committed `.xcodeproj`
> (no XcodeGen), bundle id `jayymei.PhotoBrowser`.
> If you see references to `ios-app/` or `project.yml`, they are stale.

> **Mac companion (`mac/`):** a separate Python/PySide6 desktop app, *Photo Browser
> for Mac*, that browses the same SSD with the same look and bulk-edits EXIF,
> capture dates, filenames and captions via ExifTool. It shares no code with the
> iOS app — see `mac/README.md`. It is the only Python in the repo; keep it under
> `mac/` and don't add Python elsewhere.

### Feature surface (so you know where things live)
- **Browsing** — pick a folder → recursively scans it; square thumbnails for
  photos/videos; New Folder / rename / move; name search; sort by
  name/date/size/age; filters for type, year (EXIF date), location (GPS reverse-geocoded to
  "City, ST" / "City, Country" with counts, via the place index), tags (recursive, with
  counts; several at once — a file must carry all of them, or any one with "Match any"; "No Tags"
  for what's untagged), resolution/HDR, age; the chip bar runs Favorites, Type, Format, Sort, Year,
  then the rest; **at Home every one of these filters looks through the whole drive** (the full
  index — `deepFilterActive` in `FolderView`), not just the top level;
  Favorites / "To AI" modes; a **Categories** filter on folders whose subfolders hold
  `gallery.json` sidecars (from `mac/pornpics_*.py` and `mac/imagefap_downloader.py`) — galleries
  must carry every selected category; the sidecars (`gallery.json`, `pornstar.json`, `search.json`)
  are hidden from listings.
  (`FolderView`, `GalleryCategories`)
- **Viewer** — photo pinch + double-tap zoom; custom `AVPlayer` video page with
  zoom, ms-precision scrubber, looping, HDR/res badge. Gestures: swipe L/R =
  prev/next, down = exit, up = info. Video double-tap zones: left/right third =
  ∓15s, center = zoom, lower-third left/right corners = step one frame
  back/forward (via `AVPlayerItem.step(byCount:)`; the lower-middle is excluded).
  Long-press the video center = Slo-Mo mode (4×/8× slower via `player.rate`;
  long-press again to turn off). **Right-edge thumb zone** (outer ~22% of the width, between the top
  buttons and the bottom bars — one-handed use): single tap = play/pause (a double tap there is still
  +15 s, so the tap waits out the double-tap); drag up/down = a truly invisible fine scrubber — nothing
  drawn on the video, only haptic ticks per second, and the player controls and viewer buttons fade away
  as it starts (a tap brings them back) (up = forward, ~1 frame per point, up to 4× on a quick
  flick; pauses while dragging, resumes after); a hold there does nothing; swipe up/down stand aside there, swipe
  left/right and the double-taps still work (`inThumbZone`, `handleThumbScrub` in `VideoPage`; AVPlayer
  pages only, not WebM). The camera button saves the frame to a "Screenshots" folder beside the video
  (HDR video → 10-bit HDR HEIC); **press and hold it for a standard-range PNG** instead — never HDR or
  HEIC (`AVAssetImageGenerator`'s SDR tone mapping, 8-bit sRGB, up to 4K, metadata kept;
  `FileActions.saveStandardRangePNG`). Slideshow mode. **WebM** (`.webm`) — which AVFoundation can't
  open — plays in a `WKWebView` `<video>` fed by a Range-capable `pbmedia://` scheme handler,
  and gets WebKit-drawn grid posters. (`ViewerView`, `ZoomableImageView`, `VideoPage`,
  `WebMPlayer`)
- **Info panel** (swipe-up) — date, device, dimensions, size, GPS →
  reverse-geocoded place, "Saved from" (xattrs), Age, inline caption edit, tags (one at a
  time, with suggestions). Tags are also applied from a thumbnail's long-press menu and the
  selection bar (`tagMenu`: "Add Tag…" first, then every tag alphabetically, `.menuOrder(.fixed)`).
  **Folders carry tags of their own** (long-press Tags menu, selection bar, folder Get Info): tagging or
  untagging a folder asks whether the items inside change too (`FolderTags.swift`; Safe Finder asks the
  same, `ask_inside`) — `docs/feature-notes.md` §6j.
- **Tags shared with Safe Finder** — the drive's `.Photo Browser Metadata/shared-tags.json` holds
  the tags by drive-relative path; Safe Finder (`mac/shared_tags.py`, ⌘T / sidebar Tags) edits it
  directly while the drive is on the Mac, and the app three-way merges it with `Library.tags`
  whenever it opens or gets the drive back, returns to the foreground, or a tag changes — base kept
  by the file's id (`tagSyncBase`), so removals cross too and a lost file never wipes anything.
  Every tag change must reach `noteTagsEdited()` (the tag setters and `persistAllPathKeyed` call
  it). **Favorites and To AI ride in the same file** (`labels`: path → ["favorite", "ai"]), merged three ways the same
  way — Safe Finder edits them too (right-click / ⇧⌘F / ⇧⌘A / sidebar Labels); every favorite/To AI change calls
  `noteTagsEdited()`; copies don't get them, moves carry them (§6h). **Tags also travel inside each file** (not on exFAT) in a private attribute
  (`com.photobrowser.tags`: path + tags when written — deliberately *not* Finder's tags, which are the
  user's and are left alone). A file new to the index (moved/copied in by Finder or Files) is squared
  with the store (`adoptCarriedTags` → `SharedTags.reconcile`): its tags are adopted, a move drops the
  old path's entry, a put-back file gets its tags back. **Anything that rewrites a file in place must
  keep the attribute** — `SharedTags.carriedAttributes` before the replace, `restoreAttributes` after
  (`replaceInPlace`, the metadata writers and `PhotoEditorIO.promote` do). **A new file made from one
  gets its tags** (`Library.copyTags`): copies, photo-editor Save as New, Edit/Extend with AI results
  (review, recovery, and Astria.ai Browser saves via `astriaPromptSources`). AirDropped `.pbgallery`
  archives carry a `.photobrowser-tags.json` sidecar (`applyArchiveTags`). Metadata backups sync with the
  drive first. (`SharedTags.swift`, `docs/feature-notes.md` §6h)
- **Editing** — crop/rotate saved **in place** over the original (no duplicate),
  preserving EXIF/creation metadata, under a best-effort background-task window;
  bulk **rotate** (180°/left/right, mainly to fix upside-down videos) on a
  multi-selection; metadata editor (capture date + location, photos & videos),
  album covers (from a photo or a video frame, with cropper), captions (app
  overrides + pull-in of embedded IPTC/EXIF). (`MediaEditor`) **Upscales** (1080p / 4K video, AI
  photo) run as background activities through `Library.enqueueUpscale` (`UpscaleQueue.swift`):
  a video upscale first asks for the frame rate (30 / 60 / source — the composition is retimed,
  no interpolation), everything that comes out upscaled gets the "upscaled" tag, and the outcome
  is an activity popup. Duplicate copies the original's metadata (labels, caption, tags) to the copy
  via `duplicateMetadata`. **Batch crop** (selection ▸ More ▸ Crop…, `BatchCrop.swift`): one crop drawn
  on a photo goes on every selected photo in place — as fractions of each photo (a fixed ratio keeps its
  shape) — and each gets the "cropped" tag; the Edit screen and the photo editor tag their crops too and
  remember them for "Last Crop". Safe Finder's twin: right-click ▸ Crop… (`mac/batch_crop.py`,
  `mac/crop_window.py`, same arithmetic — `docs/feature-notes.md` §6i). Safe Finder also has
  right-click ▸ **AI Upscale 2×** — real Real-ESRGAN (Upscayl's engine) on the Mac, in place or saved as a
  new "name (upscaled)" photo with the same metadata, dates and tags, tagged "upscaled" (`mac/ai_upscale.py`;
  photos over 12 MP too, in tiles, after a warning of how big they'll be — §6l); the iPhone's "AI Upscale"
  is Lanczos + denoise + sharpen. And right-click ▸ **Erase Area…** — boxes
  drawn once over a watermark/stamp on one photo, erased from every selected one (see-through marks taken
  back out, the rest filled; Save as New or Replace; tagged "retouched" — `mac/retouch.py`, §6o).
  And right-click photos or folders ▸ **Remove Watermark…** — the person's own see-through watermark, anywhere on
  each piece, once or many times, with words that change every piece ("2025 n498rfhd", "34987h34rtf98"): learned
  from a box round one copy, kept in a library (`~/Library/Application Support/Safe Finder/Watermarks`), then found
  by itself on later pieces **by its look** (ink, see-through strength, letter size, slant — `detect`), or exactly
  by template when the words repeat; every copy un-blended, so what's under it comes back; Save as New
  "(no watermark)" or Replace; tagged "retouched" (`mac/watermark.py`, `mac/watermark_window.py`, §6x).
  And right-click ▸ **Remove Objects…** — TouchRetouch-style: lasso/brush round anything and it's filled from the
  photo itself (multi-scale PatchMatch completion, `mac/inpaint.py`; window `mac/remove_window.py`; §6t).
  Safe Finder's **Send to CapCut** (⇧⌘K / right-click / a folder's CapCut ▸; `mac/capcut.py`, `mac/capcut_window.py`):
  CapCut opened and a floating tray beside it with the clips in timeline order to drag in at once (never writes
  CapCut drafts — encrypted and version-bound); the tray (and Import from CapCut…) brings CapCut's exports back into
  the clips' folder, tagged "capcut" + the clips' tags, optionally dated like the earliest clip — §6y.
  Safe Finder's **Convert WebP to JPEG** (right-click a folder / selected WebPs / Photos menu; `mac/webp_convert.py`,
  `mac/webp_window.py`): full resolution, quality 95, 4:4:4, ICC/EXIF/XMP and file dates kept, transparency onto
  white, animated left, never overwrites ("name 2.jpg"); originals to the Trash only if asked and after the JPEG
  checks out — then tags and Favorites/To AI move to the JPEG (`carry` + `carry_labels` + `forget`) — §6z.
  Safe Finder's **Photos view** (⌘3, the iPhone's square grid with video lengths) and its **viewer** (double-click:
  the window is the full height of its display and takes each item's shape at that height, bars above/below the
  picture — never over it — a resolution + HDR badge top right, ♡/✦ labels, zoom for photos and videos, a
  click-anywhere scrubber + play/pause; photos zoom, videos loop with Slo-Mo/frame step, Info panel, Save Frame,
  slideshow — `mac/media_viewer.py`, `mac/media_info.py`; **videos and HDR photos are drawn by macOS itself**
  — AVFoundation/AppKit through `mac/viewer_surface.swift`, a Swift library loaded with ctypes — so HDR looks as in
  QuickTime/Preview; Qt's player is only the fallback, §6p) and **Export All Frames** (`mac/frame_export.py` + `video_helper.swift` `frames`; same names,
  rates and standard-range/HDR choice as the iPhone; resumes only the same export, else "<name> 2") — §6p.
  Safe Finder's **Find Duplicates** (right-click a folder; `mac/duplicates.py`, `mac/duplicates_window.py`): the
  iPhone's exact / visually similar / similar-name groups, plus an Identical (SHA-256) check and Select Extra
  Copies for identical groups only — it ticks, the person trashes — §6q.
  Safe Finder's **taylorpictures.net** window (right-click the Taylor Swift folder; `mac/taylor.py`,
  `mac/taylor_window.py`): first a pass of the whole site against the whole folder (resumable; "N of your
  photos are on the site", albums you have all/some/none of), then the iPhone's browser with "already here"
  marks (by name, then by picture) and Download Missing; both apps share `Taylor Swift/.taylorpictures.json`
  (`TaylorRecord.swift`) — §7.4c.
  Safe Finder's **Edit with AI / Create with AI / Astria.ai Browser** (`mac/astria.py`, `mac/ai_window.py`): the
  iPhone's Astria request path field for field (keep the two in step), key in the Mac's Keychain — §1.13.
  **Several photos, one prompt** (select photos ▸ Edit N Photos with AI…): a job per photo with the same prompt and
  settings, four at a time (`ai_window.LANES`), one `BatchResultsWindow` with every photo's results, Save All once
  they're all back (each into the "AI" folder beside its own photo), Try Again per failed photo. Safe Finder only.
  Safe Finder's **menu bar** (`mac/menubar.py`) holds every command and its ⌘ shortcut (one binding per key —
  panes keep only Return/Space); the right-click menu groups a folder's tools under Download ▸ / AI ▸.
  Safe Finder's **Edit Metadata** (right-click ▸ Edit Metadata… / ⌘I; `mac/metadata_edit.py`, `mac/metadata_window.py`):
  capture date (set / shift / from name / from file date / to file dates), location, caption, title, keywords,
  creator, copyright, rating, camera, any ExifTool tag, strip — for many photos and videos or whole folders, written
  with ExifTool in place in the tags the iPhone reads (the downloaders' tags) — §6s.
  Safe Finder's **funnel** holds the iPhone's **Type / Format / Location** filters beside Size (`Pane._filter_menu`;
  Location via `mac/places.py`, keyed like the iPhone so the drive's `.Photo Browser Metadata/places.json` names
  photos without asking again; new places through `mac/geocode_helper.swift`, CLGeocoder) — §6u.
  Safe Finder's **PDF viewer** (double-click a PDF; `mac/pdf_viewer.py`, QtPdf) has **Optimize for iPhone** (new
  "<name> (for iPhone).pdf": iPhone 17 Pro Max-shaped pages, margins trimmed, two-column pages read a column at a time,
  cut only between lines) and **Optimize for Safe Finder** (trimmed pages, blanks dropped) — `mac/pdf_optimize.py`
  plans, `mac/pdf_helper.swift` draws vectors (Qt pictures as fallback) — §6v.
  Safe Finder's **Make Book PDF** (right-click a .txt/.md/.rtf, or File menu; `mac/book_window.py` → the person's
  `mac/bookify.py`, ReportLab): the text typeset like a printed book beside it, incl. an iPhone-screen page size — §6w.
  **Make Book asks "add pictures?" first, makes the book, then opens the Pictures window** (`PicturesDialog`: each
  picture at the front / a chapter's start or end / on a page / the end; a page of its own, across the text or half
  width; a caption) and sets the book again in place (`BookHooks.replace`; `bookify.make_book(pictures=…)`, "on a
  page" kept as "after that paragraph"). bookify's contents entries are links and the chapters are the PDF outline.
  **The PDF viewer follows a click on a contents entry** — real links itself (`follow_link`: this Qt's `QPdfView`
  doesn't), and contents pages that are only text by reading the clicked line and resolving the printed number
  (`mac/pdf_contents.py`: labels, folio offset, the chapter's title); a **Contents** list, a chapter menu, `[`/`]`,
  ‹ Back, ⌘G. The viewer re-derives `QPdfView`'s page layout (`_page_rects`) to map clicks — §6w-2.
  Safe Finder opens as **one window**; **Split View** (header button, View ▸ Split View ⌘\\, remembered; `--to`
  forces it) adds the To pane and the Move/Copy bar for transfers (`MainWindow.set_split` — §6r).
- **PhotoKit** — browse iOS albums in-app, import into the drive folder,
  "Add from iOS Album" (import then delete the iOS originals), save drive media
  to Photos, capture/export HDR-preserving video frames. (`PhotosLibraryView`,
  `FileActions`)
- **Drive-to-drive transfer** — "Move Here from Another Drive…" recursively
  copies (4 concurrent), deletes originals, migrates Favorites/covers/captions
  to the new paths under a background-task window; "Re-link Favorites from a
  Drive…" re-attaches labels. (`DriveTransferView`, `FileActions`)
- **Copy** — "Copy to Folder…" (single item via long-press, or bulk via the
  selection bar's More menu) copies into a picked folder; copies are fresh files
  and carry *no* labels (the originals keep theirs) — except tags, which go with the copy
  (`Library.copyTags`). (`FileActions.copy`)
- **Pure File Transfer mode** — a switch on the pre-drive screen (and Settings) that
  turns the app into a plain phone→SSD conduit: thumbnails become memory-only (no
  disk cache), the downloaders / AI / pixel editors are hidden, background jobs are
  skipped; all file management (move/copy with duplicate detection, rename, delete,
  metadata, captions, labels) stays. (`Library.pureTransferMode`, see
  `docs/feature-notes.md` §5c.)
- **Appearance** — Settings ▸ Appearance: ready-made themes (everyday, Halloween, Christmas
  sets) or a custom background (solid / gradient), accent colour, typeface and light/dark chrome;
  `AppTheme` (persisted by `Library.theme`), drawn by `AppGradient`, applied at the app root
  (`.tint`, `.preferredColorScheme`, `.fontDesign`, default font) and in the chip bar.
  (`AppTheme`, `AppearanceView`)
- **Add from MEGA** — "Add from MEGA…" downloads the media inside a public
  `mega.nz/folder/…` link into a subfolder of the current folder, preserving
  structure. Pure-Swift implementation of MEGA's encrypted client protocol (no
  SDK). (`MegaImportView`, `MegaDownloader`, `MegaCrypto`)
- **Download from SimpCity** — on a person's folder (iPhone download menu; Safe Finder right-click):
  a simpcity.cr thread's goonbox photos (full size, via goonbox's `/api/images/<id>`), **pixhost** photos (thumbnail
  `t<N>`→`img<N>` when that server answers, else the show page's `image-img`; gallery links listed into their
  images — `SimpCityPixhost.swift` / `simpcity.pixhost_*`; kind "pixhost", `pixhost-<id>.<ext>`) and — with
  "Download videos" on — turbo videos plus the videos its posts link on pixeldrain, gofile, cyberdrop,
  bunkr, filester and fileditch (`SimpCityHosts` / `mac/filehosts.py`: host APIs, else the host's page in
  the browser; **gofile only through its own site** — never sign a gofile API request yourself, a stale
  token gets the IP banned; pixeldrain's hotlink-locked files come from another host or the person
  presses Download in the window) into `<person>/simpcity`, tagged "simpcity", own capture date kept else the post's date
  (XenForo's `data-timestamp` — `data-time` is a label); WebP → JPEG, photos under 250 KB upscaled 2×
  (Lanczos, tagged "upscaled"); **WebM → MP4 on the Mac** (`video_tools.webm_to_mp4`: ffmpeg, H.264 + AAC —
  AVFoundation can't open WebM, so the iPhone keeps its WebMs and Safe Finder's next run converts them); earlier
  downloads brought up to these rules once (`made`). **Zips** on pixeldrain/cyberdrop/bunkr (Mac only) are
  downloaded and unpacked as the run goes — photos and videos in as `<host>-<id>-<path in zip>`, the zip
  recorded with its `files`, never fetched again. **A video
  posted on several hosts is downloaded once** (`Dedup`: hosts' sizes up front, the server's size as a
  download starts, SHA-256 once in; other copies recorded `same_as`). Read in a real browser the person
  can see (DDoS-Guard/Cloudflare checks and the SimpCity login are answered there). **The record is on
  the drive** — `<person>/simpcity/.simpcity.json`, shared with Safe Finder — so neither app
  re-downloads what the other has. **Reaction scores**: each page read notes every media post's reaction
count (its reactions bar, not the member's sidebar "Reaction score") into the record by post; sort by
"Reaction Score" (Safe Finder) / "Most reactions" (iPhone, `SimpCityScores`); Safe Finder's right-click ▸
Get Reaction Scores re-reads a folder's threads for them alone. Page scripts are identical in Swift and
Python. (`SimpCityService`,
  `SimpCityRecord`, `SimpCityHosts`, `SimpCityImportView`, `mac/simpcity.py`, `mac/filehosts.py`,
  `mac/simpcity_downloader.py`; `docs/feature-notes.md` §7.4d)
- **Instagram / Facebook profiles in Safe Finder too** — right-click a folder ▸ Download Instagram/Facebook
  Profile… (`mac/social_downloader.py`, `mac/instagram.py`, `mac/facebook.py`, `mac/social.py` — ports of
  `InstagramService`/`FacebookService` reading the sites through `fetch()` from a hidden page in a logged-in
  Qt WebEngine browser). Facebook takes every uploaded and **every tagged** photo (walks stop early only after a
  full walk recorded in the record's `walked`; empty pages are re-read), upscales photos under 200 KB 2×
  automatically, and dates each file with its own upload time (`created(page, id)`, with the time zone); a run
  reads only what's new in an album it read to the end before (record `albums`: head/tail) and paces itself
  adaptively under 50 pages a minute. Same
  file names and folders as the iPhone; files tagged "instagram"/"facebook"
  on **both** apps now; options to upscale photos 2× and videos to 1080p (`mac/video_tools.py`,
  `mac/video_helper.swift` = the iPhone's mux/upscale code, ffmpeg fallback). **The profile folder's
  `.instagram.json` / `.facebook.json` is the shared record** (`SocialRecord.swift` / `social.Record`):
  both apps read its ids into "already downloaded" and merge theirs in after a run, so neither re-downloads
  the other's posts — or ones deleted since. `docs/feature-notes.md` §7.4e.
- **TikTok in Safe Finder too** — right-click a folder ▸ Download ▸ Download TikTok Profile… / Get New TikTok Videos
  (`mac/tiktok.py`, `mac/tiktok_downloader.py` — a port of `TikTokService`: tikwm, the same `<post id>.mp4` /
  `_<n>.jpg` names in the same `@handle` folder; a Cloudflare block is answered in a small browser in the window).
  A profile folder is recognised by its **shared record `.tiktok.json`** (`SocialRecord.Kind.tiktok`: ids +
  `likes` by post id — both apps read and write it), by the app's backup on the drive (`metadata.json` →
  `tiktokFolders`/`tiktokLikes`), or as an `@folder` of TikTok-id files. **Safe Finder lists the whole profile on
  every run so every video's like count is read again**; sort "Reactions / Likes", viewer Info ▸ Likes. Files
  tagged "tiktok" on both apps. `docs/feature-notes.md` §7.4b-2.
- **Safe Finder Rename / Remove Leading Spaces / Duplicate / Rotate** (`mac/rename_tools.py`, `mac/rename_window.py`):
  Rename… (F2); **Rename N Items… / Rename Files Inside…** — many at once by a pattern (`{n}` `{name}` `{date}`
  `{time}` `{folder}` `{camera}`…) numbered in an order (**capture date**, name, file dates, size), Find → Replace,
  every new name previewed, blocked when a name is taken outside the batch; names may trade places (`bulk_plan`,
  `apply_bulk` — two steps through passing names, with a consistent roll-back; §6ae); right-click a folder ▸
  Remove Leading Spaces from Names… (files and folders, listed first, never onto a taken name); Duplicate (⌘D); Rotate ▸ Left/Right/180° (photos via `batch_crop`, videos by display
  rotation with `ffmpeg -c copy` — no re-encode). **Any rename Safe Finder makes must go through
  `rename_tools.apply` / `apply_bulk`**: it re-keys the shared tags/labels (`TagStore.renamed`) and appends to the drive's
  `.Photo Browser Metadata/renames.json`, which the iPhone applies to its path-keyed stores on the next drive open
  (`RenameJournal.swift` → `applyMacRenames` → `itemsMoved`, called from `syncDriveTags`). §6aa.
- **Safe Finder Upscale Video** — right-click videos ▸ Upscale Video… : 1080p or 4K (never down), source / 30 / 60 fps,
  replace or save as new "name (1080p).mp4", tagged "upscaled" (`video_tools.upscale`, `mac/video_upscale_window.py`;
  the helper's AVFoundation code, else ffmpeg with HDR kept as 10-bit HEVC). §6ab.
- **Clone Drive to a New SSD** — File menu / `mac/clone_drive.py OLD NEW --apply`: the whole drive copied to a new
  (APFS) one, old drive read-only, every file read back and checksummed before it gets its name; creation dates
  (`setattrlist`), mtimes, xattrs, flags kept; dot-records (`.Photo Browser Metadata`, download records, `.Trash`)
  copied, macOS junk and exFAT workarounds not; resumable, never overwrites (only brings its own outdated copies up
  to date); `compare` (+ `--deep`, re-copy) and a report with the iPhone steps (Back Up Metadata Now before, same
  drive name → `rekeyRootIfRemounted`, else Restore from the Drive's Backup). §6ac.
- **Fanfix in Safe Finder** (Mac only) — right-click a folder ▸ Download ▸ Download from Fanfix… (`mac/fanfix_downloader.py`,
  `mac/fanfix.py`): the person's own purchased content from Fanfix creators, from a logged-in Qt WebEngine browser,
  **everything through that browser** (fanripper's documented model — its code is closed and its licence forbids
  taking it apart; don't): a script injected at document creation keeps every data answer the page loads (JSON
  *and* Next.js RSC streams / inline `__next_f` chunks; Firestore values made plain), the page is reloaded and
  scrolled to its end while what it *shows* is noted too, and **files download through Chromium's own download
  manager** (Cloudflare's clearance is the browser's — `urllib` gets the "Just a moment…" page; a web page that
  comes down is refused). Bought beats locked (`isPurchased` over `isLocked`). Creator pages are `/@handle`; Home
  Feed / Purchases (`/gallery`) / Messages sort into each creator's folder. Named by media id, tagged "fanfix",
  record `.fanfix.json`. **Fanfix's own media objects first** (`_take_asset`, learned from a real troubleshooting
  file: `messageAssets[].asset` with `sourceUrl` = the original; data via Next.js server actions): a chat is read
  upward through its whole history, Messages ▸ Download reads every chat; avatars (`static.fanfix.io/Public`,
  chat-list `imageUrl`, `/@` links, `_thumbnail`) are never media, and the earlier version's avatar files are offered
  for the Trash. **Bought pay-per-view is delivered only as FairPlay/Widevine DRM (photos too): counted, never
  downloaded — DRM is never worked around** (also DRM playlists and `encv`/`pssh` MP4s). §7.4f.
- **Receive from the Mac (AirDrop / Share sheet)** — the app opens `.pbgallery` archives (its own
  type, made by `mac/airdrop_to_iphone.py`; also offered by the pornpics browser, the star
  downloader's `--airdrop`, and Safe Finder's context menu) and, as an Alternate handler, **any
  file** (`public.data`: a folder AirDropped from Finder arrives as a zip; PDFs, videos, documents):
  an AirDropped one arrives via "Open with Photo Browser" (`onOpenURL` file URL → `ArchiveIntake`
  staging), the **Received** sheet (`ReceivedArchivesView`) lists the batch, you pick the drive
  folder, and each archive unpacks into its own folder there (single top folder dropped, sidecars
  kept; merge or keep both) while any other file is placed as it is (identical file skipped, never
  overwritten). Loose photos/videos AirDropped to an iPhone go to the Photos app — iOS decides that
  before any app is asked; "Add from iOS Album" brings them over. The Share Extension also takes
  archives and other files (and several items at once) and routes them to the same sheet. Document
  types live in `Config/Info.plist`. (`ArchiveIntake`, `ReceivedArchivesView`,
  `Archiver.peek`/`unzip(dropTopFolder:)`, `DriveWriter.moveItem`)

## Build / run

- **This is an Xcode project** (`PhotoBrowser.xcodeproj`), not a Swift Package.
  Open it in Xcode and build/run the `PhotoBrowser` scheme on a device or
  simulator. The scheme is autogenerated (none checked in).
- No `Package.swift`, no CocoaPods/Carthage, no SwiftPM dependencies.
- **No test target and no CI.** There is nothing to run for `swift test` /
  `xcodebuild test`; changes are verified by building and exercising the app.
- Command-line build (no signing) example:
  `xcodebuild -project PhotoBrowser.xcodeproj -scheme PhotoBrowser -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build`

### Key build settings (`PhotoBrowser.xcodeproj/project.pbxproj`)
- Deployment target: **iOS 17.0** (`IPHONEOS_DEPLOYMENT_TARGET` on the target).
  Note the *project-level* base config lists `26.5`; the **target** value (17.0)
  is what the app ships against — prefer APIs available on iOS 17+.
- `SWIFT_VERSION = 5.0`; `TARGETED_DEVICE_FAMILY = 1,2` (iPhone + iPad).
- Bundle id `jayymei.PhotoBrowser`. Info.plist is generated
  (`GENERATE_INFOPLIST_FILE = YES`) — Info keys (e.g. Photos usage strings) live
  as `INFOPLIST_KEY_*` build settings in the pbxproj, **not** in a standalone
  Info.plist file. Add new usage descriptions there. Both
  `NSPhotoLibraryUsageDescription` and `NSPhotoLibraryAddUsageDescription` are
  required — **PhotoKit APIs hard-crash without them**, so never remove these.
- A bridging header (`PhotoBrowser-Bridging-Header.h`) imports
  `<CommonCrypto/CommonCrypto.h>` — MEGA downloads need AES in ECB/CBC/CTR modes,
  which CryptoKit doesn't expose. Add other C interop imports here if needed.
- **The app group is a `PBXFileSystemSynchronizedRootGroup`** (Xcode 16,
  `objectVersion = 77`): the whole `PhotoBrowser/` folder is auto-synchronized
  into the target. **New `.swift` files are picked up automatically — you do NOT
  edit `project.pbxproj` to add files** (there is no XcodeGen and no per-file
  build entries to maintain).

## Architecture

Single-window SwiftUI app. Entry point `PhotoBrowserApp.swift` injects one
shared `Library` into the environment, forces dark mode, and restores the last
folder on launch.

### State model — `Library.swift`
The one source of app-wide state: `@Observable @MainActor final class Library`.
It owns the chosen `rootURL` (with a security-scoped bookmark persisted to
`UserDefaults` so access survives relaunch), the navigation `path`, the current
`sort`, and all user-attached metadata. It also performs the filesystem work
(directory listings, recursive search, folder stats, the full index) on detached
background tasks. Most of these methods are `nonisolated` + `Task.detached` so
heavy I/O on a slow external drive never blocks the main actor.

Persistence is keyed by absolute file path, in three places — **never add a growing store to
`UserDefaults`** (it rejects any value ≥ 4 MB and corrupts the prefs):
- **Bulk JSON files** (Application Support/`bulkStore`, `Library.loadBulk`/`saveBulk`): favorites,
  To AI, captions, tags, people, Clean Up progress, photo origins, the trash records… Stores changed
  by a single tap save through `scheduleBulkSave` (≈1 s later, off the main thread, coalesced);
  `flushBulkSaves(wait:)` runs when the app backgrounds and `persistAllPathKeyed` drops pending ones.
- **`FilePrefs`** (Application Support/`prefs/<key>.plist`, same API as `UserDefaults`): the path-keyed
  collections that used to be `UserDefaults` keys — folder covers, item thumbnails, birthdays, hidden
  folders/files, highlight/reviews/frames folders, bubble order, story links, the downloaders'
  per-folder records, AI prompts, Messages archives. A key moves over from `UserDefaults` on first read.
- **`UserDefaults`** only for small settings (`thumbSize`, `folderBookmark`, `theme`, …).

Keys are all under the `photoBrowser.*` namespace:
- `favorites`, `ai` — labeled item paths (Sets of path strings)
- `captions` — app caption overrides (path → text)
- `tags` — per-file tags (path → [tag]), bulk JSON store; the Tags chip filters a folder's
  subtree by them. `tagSyncBase` (bulk) — what the store and each drive's shared tag file last
  agreed on, by the file's id (see `SharedTags`)
- (not UserDefaults) the place index `placeIndex.json` — per-file GPS bins + per-bin names for
  search and the Location filter; backed up as `places.json` with every metadata backup
- `folderCovers` — folder path → cover image filename (images stored in
  Application Support/`folderCovers`)
- `photoOrigins` — imported file path → originating Photos asset id
- `birthdays` — folder path → Unix timestamp (drives the per-file "Age" feature)
- `thumbSize`, `folderBookmark`
- `theme` — the Appearance choice (`AppTheme` JSON: background, accent, typeface, light/dark)
- `lastArchiveDest` — where the last AirDropped/opened archives were unpacked (the Received sheet's default)

Because everything is keyed by path, **moving/renaming must re-key this data.**
When you add code that moves or renames files/folders, call
`library.itemMoved(from:to:)` (single item / subtree) or, for cross-drive
copies, `library.migrateMetadata(...)`. Forgetting this silently orphans
Favorites, captions, covers, and birthdays.

Change-notification counters that views observe:
- `changeToken` / `contentDidChange()` — bump to force the current folder to
  reload (used after edits made outside the folder view, e.g. saving a crop). Only the folder on
  top of the navigation stack reloads at once; the others reload when they're back on top. Pass
  the folder (`contentDidChange(under:)` / `underFolders:`) whenever you know it — it also re-reads
  just that folder into the drive index; the bare form re-walks the drive (unchanged folders reused).
- `labelsVersion` — bump on any label/birthday change so label-derived views
  re-query even when the count is unchanged.
- `indexRevision` — bumped whenever the whole-drive `index` changes. Key anything derived from the
  index on it (not `index.count`: a rename or move keeps the count). The index is kept current
  during a session (`noteIndexChange`, `remapIndex` from `itemsMoved`), not just rebuilt at launch.

**Deleting:** every Delete goes through `library.trashItems(_:)` — the drive's 30-day Recently
Deleted, labels kept for a restore, iOS Photos originals untouched; `restoreTrashed` puts items
back (a renamed restore keeps its labels). Never `FileActions.delete` from a screen.

**Results:** a success is `library.showToast(_:)` (or `resultMessage` in `FolderView`, shown as a
toast); a failure is `library.postNotice(title, message)` — an alert titled with what failed.
Activities (`beginActivity`/`endActivity`) route their result the same way; pass `cancellable: true`
and check `isActivityCancelled` between items to offer Stop in the activities sheet.

### Core data types — `Models.swift`
- `FileKind` (folder/image/video/pdf/other) and `classify(url:isDirectory:)`
  using `UTType` conformances.
- `Entry` — one directory item (`url`, `name`, `kind`, `size`, `modified`);
  `id == url`; helpers `isFolder`, `isViewable`, `isScreenshot`.
- Filter enums: `TypeFilter`, `VideoRes`, `ImageRes`, `LabelKind`, `SortKey`.
- `MediaSpec` (dimensions/HDR for res filters), `FolderStats` (Get Info).
- `Int64.sizeString` for human file sizes.

### View layer
- `ContentView.swift` — `NavigationStack` bound to `library.path`; shows
  `EmptyState` (add folder / add Photo library) until a root is chosen, then
  `FolderView` for the root and each pushed folder URL.
- `FolderView.swift` — **the main screen and by far the largest/most complex
  file (~1000 lines).** The grid of `ThumbCell`s plus every filter, the search
  field, multi-select with drag-to-select + auto-scroll, the toolbar menus, and
  presentation of all the sheets/covers (viewer, info, editors, pickers). The
  Favorites / "To AI" / Library "modes" are filtered presentations driven off
  `Library` data. When adding folder-level features this is usually where they
  land.
- `ThumbCell.swift` / `Thumbnailer.swift` — tiles and the thumbnail engine.
  `Thumbnailer` is a singleton with memory (`NSCache`) + disk
  (Application Support/`thumbs`, excluded from backup) caching, in-flight
  de-duplication, and QuickLook generation off the main thread. Disk cache key =
  SHA256 of `path|mtime|size`. The disk cache lives in Application Support (not
  Caches) on purpose: iOS auto-purges Caches under storage pressure, which was
  making the whole library re-thumbnail itself a few times a day.
- `ViewerView.swift` — full-screen one-item-at-a-time viewer; swipes are handled
  inside each page (UIKit) for reliability over the zoom scroll view.
  `ZoomableImageView.swift` (photos) and `VideoPage.swift` (Photos-style player)
  are the pages. `InfoPanel.swift` is the swipe-up details card.
- `MediaEditor.swift` / `AlbumCoverCropper.swift` / `ZoomableImageView` — crop &
  edit UI. `MetadataEditorView.swift` + `BirthdayEditorView.swift` /
  `FolderInfoView.swift` — metadata, birthday, and Get-Info editors.
- Pickers / transfer: `FolderPicker.swift`, `PhotosImportPicker.swift`,
  `PhotosLibraryView.swift` (browse the system Photos library/albums),
  `DriveTransferView.swift` (drive-to-drive folder move with progress).

### Services / helpers (non-View)
- `MetadataLoader.swift` — read-only metadata: EXIF/AVAsset capture dates,
  dimensions/HDR, RAW/48MP badges, embedded captions, reverse-geocoded place
  names, and "saved from" source via extended attributes. All reads are off the
  main actor and **time-boxed** (`withTimeout`) so a slow/corrupt file on an
  external drive can't hang the UI. Capture dates, captions and media specs
  (and video durations in `ThumbCell`) are **cached per file**, keyed by
  `path|mtime|size` — the thumbnail-cache scheme, so in-place edits invalidate
  naturally — meaning re-opening a folder doesn't re-read EXIF/AVAsset per item.
- `FileActions.swift` — all mutating filesystem operations and Photos-library
  I/O: delete/duplicate/rename/**move/copy**/createFolder, write metadata back
  into files, import from / save to Photos, cross-drive transfer with progress,
  plus video-frame export (SDR/HDR), the `BackgroundTaskHolder` (best-effort
  background window), and the `FilesExporter` / `QuickLookPreview`
  `UIViewControllerRepresentable` wrappers.
- `MediaEditor.swift` — the crop/rotate UI plus `MediaEditing`, which does the
  pixel work and writes the result **in place** over the original
  (`applyPhotoInPlace` / `exportVideoInPlace` → temp file → `replaceInPlace`),
  carrying metadata across. Reused by the folder view's bulk-rotate.
- `MegaDownloader.swift` / `MegaCrypto.swift` — pure-Swift MEGA folder-link
  downloader. `MegaDownloader` speaks MEGA's client API (node tree, per-file
  download URLs) and streams files to disk; `MegaCrypto` wraps CommonCrypto for
  the AES ECB/CBC/CTR steps. Both are entirely `nonisolated` (network + crypto +
  file I/O must stay off the main actor). The protocol is unofficial — treat it
  as best-effort and keep failures non-fatal.
- `CoverFrameSource.swift`, `MetadataEditorView.swift` — small supporting types.

## Conventions to follow

- **Match the existing style.** Swift API Design Guidelines, 4-space indent.
  Files carry a `///` doc comment at the top explaining their role and the *why*
  behind non-obvious choices (concurrency, isolation, timeouts) — keep that up
  and write comments at the same altitude (intent, not narration).
- **Concurrency / isolation:** the project relies on default-MainActor
  isolation. `Library` is `@MainActor`; anything doing real filesystem or
  AVFoundation/ImageIO work runs via `Task.detached(priority: .utility/.userInitiated)`
  and is marked `nonisolated`. Preserve this split — never add blocking I/O on
  the main actor, and bound fan-out work (the codebase uses a `maxConcurrent = 8`
  task-group pattern; reuse it rather than spawning unbounded tasks).
- **State changes go through `Library`**, not ad-hoc `UserDefaults` access in
  views. Persist with the existing `photoBrowser.*` keys and bump the right
  counter (`changeToken` / `labelsVersion`).
- **Path-keyed metadata must be re-keyed on move/rename** (see above).
- **Security-scoped access:** the root is opened via a bookmark and
  `startAccessingSecurityScopedResource()`. Don't assume raw filesystem access
  to arbitrary paths.
- **No new dependencies.** Stick to Apple frameworks (SwiftUI, UIKit, ImageIO,
  AVFoundation, PhotosUI, QuickLook, CoreLocation, CryptoKit). Adding a package
  would be a notable architectural change — confirm before doing so.
- **Privacy:** this app handles personal photo data and writes metadata back
  into user files. Be conservative with anything that deletes, overwrites, or
  exfiltrates user files; the existing destructive paths are gated behind
  confirmations.

## Hard-won constraints (don't relearn these)

These were discovered the painful way; the current code already respects them.

1. **Default-MainActor isolation is ON.** Heavy I/O (AVFoundation, CoreLocation,
   xattrs via `getxattr`, `CGImageSource`) **must** run `nonisolated` /
   `Task.detached`, or it freezes the UI on a slow external drive. This is the
   single biggest source of "the app froze" bugs. Beware: it applies to
   **unmarked classes too** — methods of a plain `final class` are MainActor-
   bound, so even `Task.detached { await self.work() }` hops back to the main
   thread (this silently put `Thumbnailer`'s disk I/O on main until the class
   was marked `nonisolated`).
2. **One `.fileImporter` per view.** Multiple importers/`.confirmationDialog`s
   conflict. Use a single importer driven by a purpose enum
   (`ImportPurpose { open, transfer, relink }` in `FolderView`) and push
   secondary flows into their own `.fullScreenCover(item:)` / `.sheet`.
3. `.fileImporter(isPresented:)` needs a **plain `@State Bool`** — custom
   `Binding`s don't fire it.
4. **Presenting from a `Menu` button can be swallowed** — defer the present with
   `DispatchQueue.main.asyncAfter` (or set the item in the next runloop tick).
5. **Invalid GPS coordinates crash uncatchably** in `CLLocation`/`CLGeocoder`.
   Always guard `CLLocationCoordinate2DIsValid` + finite + not `(0,0)` before
   constructing a location or geocoding (see `MetadataLoader.reverseGeocode`).
6. **Cross-volume moves are copy-then-delete**, under security-scoped resource
   access — there is no atomic move across drives.
7. **iOS background limits:** `beginBackgroundTask` lasts only minutes and
   nothing runs once the app is terminated — long transfers can't fully
   background. Don't promise durable background work.
8. **Video frame stepping** uses `AVPlayerItem.step(byCount:)` — pause first and
   check `canStepForward`/`canStepBackward`.
9. Metadata reads are **time-boxed** (`MetadataLoader.withTimeout`) so a slow or
   corrupt file on an external drive can never hang the info panel — keep new
   per-file metadata work behind the same pattern. (The info panel loads its
   three sources concurrently and each bounded — image, video, caption and
   "saved from" are all behind a timeout.)
10. **Edits replace the original in place** (write to a sibling temp file, then
    `replaceItemAt`). Preserve metadata when re-encoding (carry over EXIF/GPS for
    photos via `CGImageDestination` properties; set `export.metadata` for video)
    or you'll silently strip capture date / location and break Age/year/place.
    Don't manually evict thumbnails afterward — the cache key is
    `SHA256(path|mtime|size)`, so an in-place edit naturally misses the old entry
    and regenerates once the folder reloads (`changeToken`).
11. **MEGA crypto needs raw AES modes (ECB/CBC/CTR)** that CryptoKit doesn't
    provide — that's why CommonCrypto is bridged in. Keep all MEGA work
    `nonisolated`/off-main (it's network + crypto + large file writes), and treat
    the reverse-engineered protocol as best-effort: surface failures as notes.
12. **Every write to the drive goes through `DriveWriter`.** The SSD was exFAT (no
    journal) until Oct 20, 2026 — **the library now lives on a 4 TB APFS SSD**, and everything
    exFAT-specific below (F_FULLFSYNC, the 2.2 TB line, spare folders, the Mac relocate/inspect
    tools, iOS-safe name adjustment in Safe Finder) is gated on `DriveWriter.syncMode == .full` /
    `spare_folders.on_exfat` and stands down on APFS; keep it, the old drive still exists. Hidden
    folders on an APFS drive: `.Photo Browser Metadata` (keep — the backups), `.Spare Folders`
    (unused there; delete), `.Safe Finder Staging` (Safe Finder's crash note; harmless).
    On exFAT: a folder created with a bare `createDirectory`, a file written straight
    to its final path, or a write still in flight when iOS suspends the app leaves a
    torn directory that `fsck_exfat` later reports as "zero length directory",
    "cluster chain overlaps" or "unexpected critical primary directory entry" (the
    AI-folder corruption). Rules: create folders with `DriveWriter.createDirectory`,
    place files with `DriveWriter.shared.writeData` / `writeDataUnique` / `commit`
    (temp → fsync the file → rename, serialized) or the sync `writeDataSync`, never
    `Data.write`/`CGImageDestinationCreateWithURL` to a final drive path, and hold a
    `BackgroundTaskHolder` across the write when the user may have left the app (see
    `docs/feature-notes.md` §12).
    **Folders iOS can't open ("opendir errno 22") or that look empty — SOLVED Oct 11, 2026: it's
    where the folder's list sits on the drive.** The iPhone's exFAT driver misreads a folder's *list
    of contents* (its directory clusters) when it lies past 2^32 × 512 bytes = 2.20 TB into the
    volume (the SSD is 8 TB): depending on what sits 2.20 TB earlier it fails with EINVAL, lists
    nothing, or lists stale/other items. File data past the line reads fine; macOS reads everything.
    Proof: moving just the lists below the line (`mac/relocate_folders.py`, 179 folders) made every
    folder load on the iPhone — Kendall, Kylie, Kim, all of `Leaks`, the Porn folders. Nothing else
    was wrong with them. **Standing rule:** nearly all free space is past the line, so any new folder
    (made on the Mac *or* the iPhone) or any list that grows a cluster can land there and break —
    after adding folders, run `sudo python3 mac/relocate_folders.py "/Volumes/<SSD>"` (dry run; read
    only) and `--apply` if it lists anything. **Drive Health only flags errors**: a folder that reads
    as empty (and everything under it) never appears there — the Mac dry run is the complete list;
    `mac/exfat_inspect.py` shows where any folder sits. The app's "can't read this folder" and
    "empty folder" states and Drive Health's advice point to the tool.
    **New folders come from spares (Oct 11).** Neither iOS nor macOS lets a program choose where a new
    folder's list goes, but renaming/moving a folder never moves its list. `relocate_folders.py
    --spares N` keeps N empty folders in `<drive>/.Spare Folders` with their lists below the line;
    `DriveWriter.createDirectory` (via `SpareFolders`) and Safe Finder (`mac/spare_folders.py`) make
    each new folder by renaming a spare into place (POSIX `rename`), falling back to a plain mkdir —
    counted, shown in Drive Health ▸ New folders — when none are left. So: **create every folder on the
    drive with `DriveWriter.createDirectory`** (never `FileManager.createDirectory`, and never
    `copyItem` a folder onto the drive — `DriveWriter.copyItem` builds folders from spares, and
    `DriveWriter.moveItem` does cross-volume moves through it). The pool sits at the root the app
    browses, which must be the drive itself. Lasting fix if it keeps
    recurring: partitions under 2.2 TB, or APFS. Dead ends on the way (don't revisit): directory
    fsync, moved files' records, renames, write method, 32-bit ID twins, "cache issue" — and copy
    rebuilds only "worked" when the copy happened to land below the line. Hygiene rules that stay:
    never fsync a directory (`DriveWriter.fullSync` refuses them; `quiesce` uses `sync()`), and the
    Mac tools write like the copy rebuild (no renames, no fsync).
13. **`nonisolated async` is not "off the main thread".** The target builds with
    `SWIFT_APPROACHABLE_CONCURRENCY` (NonisolatedNonsendingByDefault), so a plain
    `nonisolated async func` runs on whatever actor *awaited* it — awaited from a
    `@MainActor` type's `Task { }`, it runs on main. That silently put the video
    editor's imports, composition builds and export pre-flight on the main thread.
    Mark heavy async entry points `@concurrent` (or call them from `Task.detached`);
    synchronous `nonisolated` work still needs `Task.detached`.

14. **A listed item iOS can't stat is not a 0-byte file.** Damaged exFAT folder entries (old
    "zero length" AI folders) are listed by their parent but fail every stat on iOS. Classify with
    `Library.directoryStatus` and keep them flagged (`Entry.unreadable`) — never let them fall into
    the "hide 0 KB files" rule. Create named save folders ("AI", "Screenshots", …) with
    `DriveWriter.usableDirectory(named:in:)`, not `fileExists` + `createDirectory` with the error
    swallowed: an unreadable entry holding the name makes that combination fail every save
    (see `docs/feature-notes.md` §3.5).

## Git workflow

- **Commit changes directly to `main`.** This is the repo owner's standing
  preference: commit with clear messages and push straight to `main`. Don't
  create feature branches or open pull requests for routine work unless the user
  explicitly asks. After pushing, verify `main` actually contains the change.
- `xcuserdata/` and other Xcode user files are gitignored.
