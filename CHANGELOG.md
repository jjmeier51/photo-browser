# Changelog

Major changes to Photo Browser. Dates are when the work landed on `main`.

## 2026-07-03

- **accessKardashian downloads run app-wide and pause anywhere** — the run moved off the member
  screen onto `Library` (progress pill + completion popup, like Instagram/Drive), so you can
  close the sheet, browse the app, and briefly switch apps while it downloads; reopening the
  member screen reattaches to live progress, and Pause is available at any time (Resume picks
  up where it left off). Caption translation now completes app-wide too. Speed: Resume/Fetch
  New skips already-downloaded photos via one directory listing instead of a per-file stat on
  the drive — a big head start on galleries with tens of thousands already saved.
- **"Today's Instagram Stories" is flat again** — reverted the per-handle subfolders; collected
  stories go back to handle-prefixed filenames in one scrollable grid. Any leftover handle
  subfolders are flattened automatically the next time the folder is used (story links follow).

## 2026-07-02 — drive persistence + instant-browsing pass

- **The app no longer "forgets" the SSD.** The saved folder bookmark used to be tried exactly
  once at launch — launch without the drive and the app dropped to the first-run screen. Now a
  "Waiting for your drive…" screen retries until the volume mounts (and every return to
  foreground retries too), reopening the library automatically. A drive yanked **mid-session**
  is also detected and re-resolved — including when it comes back under a new mount path, which
  swaps the root over and re-keys everything.
- **Replug/move re-keying is now complete** — the People/faces library, "AI" badges, Clean Up
  progress, and dismissed duplicate pairs previously orphaned on every drive remount (and on
  in-app moves of their folders); they now follow along with everything else.
- **Every folder paints instantly on cold launch** — per-folder listing snapshots on disk
  (previously only the root had one), keyed drive-relative so they survive remounts.
- **Instant search/Library on launch** — the whole-drive index is persisted and loaded
  immediately; the fresh walk still runs in the background and replaces it.
- **Dimensions/HDR/durations persist to disk** like capture dates already did — the resolution
  filters, duration sort and video-length badges stop re-opening every AVAsset each launch. A
  background pass also pre-warms capture dates for the whole library (once ever per file), so
  first visits to folders sort by real capture date without an EXIF wait.
- **One edit no longer re-scans everything** — content-change notifications are scoped to the
  affected folder, so saving an edit or finishing a download stops evicting every cached
  listing and re-running the year/age passes app-wide.
- **Age computation is lazy** — the recursive walk + EXIF pass now runs only when an age
  sort/filter/search is engaged or the Age menu is opened, not on every visit to any folder
  under a birthday folder.
- **Photos-style viewer swiping** — the viewer preloads the neighbouring photos into a small
  decoded-page cache, so swipes land on an already-decoded image instead of a cold two-stage
  decode from the drive.
- **Misc:** highlight-bubble covers decode off the main thread (was a sync decode during
  layout); bulk capture-date/spec/caption reads are time-boxed so one corrupt file can't stall
  a folder pass (timeouts stay uncached and retry when the drive is healthy).
- **Export All Frames no longer reports phantom success** — frames were counted before
  their write was checked, so a run whose folder couldn't be created (e.g. a corrupt
  extension-less "data" file occupying the folder's name after an interrupted write on the
  drive) said "Exported N frames" with nothing saved. Now: only frames actually on disk are
  counted; a corrupt file-entry at the target name steps aside to "Name 2"; the resume
  checkpoint verifies its saved folder is a real directory; and a stat that transiently fails
  during listing re-checks instead of rendering a real folder as a "data" file tile.
- **TikTok "Get New" can no longer permanently skip failed downloads** — the incremental
  cutoff (`newestDate`) used to advance when links were *resolved*, so a queued background
  download that later failed fell behind the cutoff and was never re-listed. The cutoff now
  advances only when a video is actually filed onto the drive; anything that failed stays
  ahead of it and is re-fetched (id-dedup still prevents duplicates) on the next run.

## 2026-06-26

- **Instagram downloads run in the background** — "Download Instagram Profile" / "Get New Posts"
  and "Get All New Stories" now launch and dismiss, running as app-wide background activities
  (progress pill + completion popup, like Export All Frames), so you can keep using the app
  while they run. Generalized the frame-export progress into a shared multi-job activity system.
- **Much faster thumbnails in large folders** — photos now thumbnail via **ImageIO** and videos
  via **AVAssetImageGenerator**, both in-process, instead of routing every tile through
  QuickLook's out-of-process XPC service (fine for a few, a bottleneck for thousands). Prefetch
  also fans out across all CPU cores and warms more of the folder. QuickLook is kept for PDFs.
- **Export All Frames now saves each frame at 1.5× resolution** (high-quality Lanczos).
- **"AI Upscale" for a single photo** (context menu) — gentle denoise + subtle sharpen + a
  1.5× resolution bump, in place, EXIF/capture-date preserved (verify-before-replace).

## 2026-06-26 — performance pass

- **Navy→black background** replaces the orange gradient app-wide.
- **Faster homepage** — the root listing is persisted and painted instantly on cold launch
  (then refreshed), and the whole-drive search index now builds ~1.8s later so it doesn't
  fight the homepage for SSD I/O on launch.
- **Faster Move/Copy/Use-As-Album-Cover pickers** — they now list immediate subfolders via a
  lightweight scan (no statting every media file) and reuse cached listings.
- **Export All Frames** — now app-wide: keeps running while you browse other folders and view
  media, with a non-blocking progress pill and a completion popup. New FPS picker (every frame
  / half / quarter). (Frame decode/encode itself is still sequential.)
- **TikTok "Get New" is incremental** — for an already-downloaded profile it only checks for
  videos newer than the most recent one you have (stops paging at the cutoff).
- **Instagram "Get All New Stories"** — sweeps profiles concurrently (bounded), skips redundant
  profile-pic fetches, and adds opt-in "upscale videos to 1080p" / "double photo resolution"
  passes (dates preserved; videos keep HDR).
- **Caches survive reconnects** (already shipped) plus the listing cache above.

## 2026-06-25 (later)

- **Screenshots saved at 2× resolution** — capturing a still from a video now upscales the
  saved frame to double its dimensions (high-quality Lanczos), preserving HDR. The bulk
  every-frame export is unchanged.
- **Caches & labels survive a drive reconnect** — external drives remount under a new
  `…/userfsd/<UUID>/…` path each time they're replugged, which changed every file's absolute
  path and silently invalidated all per-file caches (thumbnails, capture dates, specs,
  durations) — the whole library regenerated on every reconnect. Per-file cache keys now drop
  the volatile mount-UUID segment, so caches persist across reconnects. The same path change
  also orphaned Favorites / To AI / captions / covers / Instagram·TikTok records / birthdays /
  likes; those are now re-keyed once when the same drive folder comes back under a new mount.

- **Download YouTube video here** — a folder-menu action that takes a YouTube link (auto-filled
  from the clipboard) and downloads it into the current folder at the highest quality the device
  can assemble. YouTube serves >720p as separate video+audio (DASH), so — like yt-dlp — it
  resolves through a public Piped instance (which deciphers server-side) and muxes on-device:
  best H.264+AAC (≤1080p) via AVFoundation, or VP9/AV1 (1440p/4K) → HEVC when FFmpegKit is added
  to the project. The title becomes the file name, the description the caption, and the upload
  date the capture date. Video + audio download in parallel; runs under a background-task window.

## 2026-06-25

- **TikTok: true HD + background downloads** — every video is now resolved through the
  resolver's single-video `hd=1` endpoint (like ssstik), so it downloads at the highest
  quality offered (1080p/HD, watermark-free) instead of a lower-res fallback. Transfers run
  on a **background `URLSession`**, so they continue — and finish — even if you close the app;
  completed videos are filed into the folder the next time the app is in the foreground.
  Resolution **streams**: each video's download starts the instant its HD link resolves
  (rather than after the whole profile), and resolution itself keeps running under a
  background-task window for a few minutes after you background the app — so whatever's been
  resolved keeps downloading even after the app is closed, and the rest is picked up on the
  next "Get New" run.
- **TikTok like counts** — each downloaded video's like count is captured and shown as a
  "Likes" row in the info panel and as a heart badge on its thumbnail (compact, e.g. 1.2M).
  TikTok folders gain a **"Most liked"** sort, and every "Get New TikTok Videos" run also
  refreshes the like counts on already-downloaded videos.
- **Sort by video length** — all folders gain **"Longest first" / "Shortest first"** sorts
  (durations are read once per video and cached with the other media specs).

## 2026-06-24

- **TikTok downloader rebuilt the ssstik way** — dropped the in-app web-scrape (TikTok caps
  the web grid to a screenful, virtualizes it, and gates it behind login, so downloads
  failed). It now resolves through a public TikTok API (no login, no signing): pages through
  the profile's **entire** video list and downloads each watermark-free at the highest
  quality offered, with post date + caption. Lands in a pinned `@handle` bubble inside the
  person's folder; profile remembered per folder; dedup by id on re-runs. *Only the public
  handle is sent out — nothing is uploaded.*
- **Faster folders** — thumbnail memory cache enlarged (4000 / 512 MB) and a folder's tiles
  are **prefetched** (bounded, off-main) the moment it opens, so they pop in instead of
  generating as you scroll. Re-opening / scrolling back is instant.
- **Upscale progress fixed** — the overlay said "Rotating…" for every op; it now shows the
  real action (Upscaling / Enhancing / Moving / …) and the upscale bar tracks true per-frame
  progress, not just per-video.
- **"AI Enhance to 1080p"** — a new upscale option that runs each frame through a denoise +
  unsharp-detail Core Image pipeline as it upscales, for a cleaner, sharper result than a
  plain rescale (SDR; HDR uses the standard upscale).
- **Highlight bubble thumbnails** — Stories/highlight bubbles that were missing a cover now
  fill one from a random item inside them.

## 2026-06-21

- **Auto folder thumbnails** — any folder with no cover gets one automatically as its cell
  appears, picked from a random photo/video inside it (descending into subfolders when it
  holds only folders). Filled lazily while you browse — reads just that folder, so it
  doesn't wait on the whole-drive index. Instagram profile folders are left for their
  profile photo (never given a random post), manually-set covers are never touched, and
  folders with no media stay plain. (`Library.ensureRandomCover`)
- **Instagram download covers are reliable** — the `@handle` folder always takes the profile
  photo (forced, so the lazy auto-cover can't beat it to a random post), the person folder
  shows it too on a fresh download, and every Stories/highlight subfolder is marked a
  highlight bubble with its own thumbnail inside the Instagram folder.
- **"Open … Stories" now navigates** — from a collected story's info panel, the link to
  that person's Stories folder closes the viewer first, then pushes on the next runloop tick
  (changing the path mid-dismiss was being swallowed). Pushed folders also get a per-URL
  identity so a path *replace* actually reloads the listing (previously the title changed to
  the new folder but the files didn't). Story links also survive folder moves now.
- **TikTok profile downloader, reworked** — the in-app browser now harvests the **whole**
  profile, not just the last screenful: it installs a link accumulator + DOM observer so
  videos virtualized out of the grid are still captured as you scroll. Videos download at
  the highest available bitrate (HDR preserved) with post date + caption. The download lands
  in an `@handle` folder **inside** the person's folder, shown as a **pinned highlight
  bubble** (cyan→red ring) with the profile avatar. The profile is **remembered per folder**,
  so the menu becomes "Get New TikTok Videos" and re-runs only pull new videos (dedup by id).
  The screen stays awake during the scrape + download.
- **Screen stays awake during Instagram downloads** — single, bulk, and the "All New
  Stories" sweep disable the idle timer while running (re-enabled when they finish or the
  screen closes), so long downloads aren't interrupted by the phone sleeping.

## 2026-06-16 → 2026-06-19

### New download sources
- **Facebook profile downloader** — in-app Facebook login (only the session cookie
  is kept), paste a profile or share link, and download uploaded photos, profile
  pictures, tagged media, and videos. Capture date (from the post when EXIF is
  missing), caption, and the poster's name are written into the files. Appears as a
  highlight bubble with a **blue ring**, pinned immediately to the right of the
  Instagram bubble, with **"Get New Facebook Photos."** *Experimental — Facebook
  actively fights scraping; built against the lightweight `mbasic` HTML.*
- **accessKardashian.com.br gallery** — per-member downloader (Kim, Kourtney,
  Kendall, Kylie). Each downloads into her own folder stamped with her birthday,
  tagged by category (Public Appearances, Photoshoots, Candids, Brand Photos,
  Fashion Shows, Social Media, Others) with matching filter chips. Pause/resume,
  high-concurrency downloads, a cached album index (so re-runs skip the crawl), and
  Portuguese→English caption translation on iOS 18+. Replaced the earlier
  "KardashianWorld" Internet-Archive salvage.
- **TikTok profile downloader** (ssstik-style, best-effort).

### Instagram
- **Person folders stay regular folders** — bulk "Set Handles" / download now put the
  Instagram folder in a `@handle` subfolder *inside* the person folder (only the nested
  Instagram folder is a highlight bubble, not the person folder). A one-time migration
  relocates existing person-folder registrations into their `@handle` subfolder — for
  already-downloaded folders it also moves the known Instagram content (post files tracked
  as "posted by", plus Stories/highlight subfolders) down into the subfolder, leaving the
  user's own files untouched. The person folder keeps the profile photo as its thumbnail
  (and the nested bubble gets its own copy), so nesting never strips a folder's cover.
- **"Stories" is a pinned highlight bubble** — each profile's "Stories" folder is shown
  as a highlight bubble inside the Instagram folder, always pinned first.
- **Skip tagged media** and **Upscale videos to 1080p** options on both single and bulk
  downloads (upscale preserves HDR/EXIF/caption/capture-date, in place).
- **No duplicates** in "Today's Instagram Stories" (deterministic per-handle names), and
  each collected story links back to that person's own Stories folder (an **"Open
  Stories"** action in the info panel).
- Profile-picture download hardened to reliably pick the **largest** available size.
- Instagram downloads ~10–20% faster (wider connection pool + concurrency).
- **"Bulk Download Instagram Profiles"** (homepage) — map existing drive folders to
  Instagram handles in one screen, then either **Set Handles** (just save the folder ⇄
  handle mappings, no download) or **Download** every mapped profile in a single pass.
  Each download is exactly like a single import (posts + tagged into the folder, stories
  into "Stories", highlights into their own bubble subfolders, HD profile-photo cover,
  captions/dates), today's stories are also added to "Today's Instagram Stories", and
  the handle is remembered per folder. The download pass **skips** folders that are
  already downloaded Instagram profiles.
- **"Get All New Instagram Stories"** (homepage) — sweeps every saved Instagram
  profile folder on the drive, downloads each user's new last-24h stories into their
  own "Stories" folder, and gathers the collective new stories into a rolling
  **"Today's Instagram Stories"** folder at the root (appended while it's under 24h
  old, cleared and refilled once it ages past that). Finishes with a per-user count
  ("@spottssa 2 stories, @brenn_smith 4 stories").
- **Highest-resolution profile pictures** — profile downloads (and the stories sweep)
  now pull the full-size `hd_profile_pic_versions` image instead of the ~320px thumb,
  and long-pressing an Instagram folder offers **"View Profile Photo"** (full-screen,
  zoomable).
- Highlights shown as bubbles; stories/highlights, and **tagged-media** downloads.
- **Higher-quality video**: best DASH rendition muxed on-device, HDR-aware, with
  optional FFmpegKit transcoding (VP9/AV1 → HEVC); WebP metadata fix.
- "Re-download Entire Profile", remembered handle, "Posted by" metadata.
- Fixed the end-of-large-profile hang (batched caption/posted-by writes).
- **Failed posts are retried** on the next "Get New Posts."
- Modest download speedup.

### taylorpictures.net
- **Indexes every album/image** (paginate-until-empty + lenient link regex) instead
  of ~60% of albums.
- **Resume indexing** picks up newly-found albums without a full rebuild.
- Fixed **wrong cross-reference dates** (e.g. Eras Tour photos dated 2007) by
  requiring close content-hash matches to agree on the date.
- Downloaded images now get the **album/event date** written in, instead of today.

### Clean Up
- New **Randomized Clean Up** mode (shuffled order; shares review progress).
- **Orange gradient** background, **swipe-down to favorite**, **video auto-play +
  scrubbing**, and **Move / Copy** buttons.
- **iMessage quick-sort**: in the iMessage folder, one-tap chips (Caitlin Turney,
  Keri, Kelsey, Shannon, Mrs. McCarthy, Leighanne, Kim Murphy, Tyler Haas, or "Move
  elsewhere…") move the item to that person's folder at the **drive root**, confirm
  with a toast, and advance — no Done needed.

### Find Duplicates
- **Exact (size + dimensions) and similar-name groups are built separately** (no
  more cross-criteria chaining that grouped unrelated files), with an **"Exact
  Matches" filter**.
- Video-frame screenshots ("Frame.png", "Frame 2.png", …) are no longer flagged as
  name duplicates — only as exact matches when name, size, and dimensions all match.
- Clearer **"Not Duplicates"** button in the compare view.

### Editing & media
- **Upscale video to 1080p / 4K** in place — preserves **HDR** (HLG/PQ via 10-bit
  HEVC), metadata, path-keyed labels, and capture date; replaces the original.
- **Live Photo** pairing validated by content identifier (Apple maker-note ↔
  QuickTime), so unrelated same-named photo/video pairs aren't fused.
- **Restore Capture Dates** prefers the date in the filename.
- **"Check if on iPhone"** removes iPhone copies that exist on the drive; imports
  skip already-imported items.
- **"Turn into Album Highlight"** for any folder; **long-press to drag-rearrange**
  highlight bubbles (Instagram/Facebook stay pinned first).

### AI
- **Dynamic Island Live Activity + local notifications** for AI Edit/Extend, so
  progress shows and you're alerted after leaving the app. The Live Activity
  display needs a one-time Widget Extension target (code + steps in
  `LiveActivity/README.md`); notifications work with no setup.

### Performance & UX
- **Move / Copy** run off the main thread with a progress bar, batch the label
  re-keying, Copy checks for duplicates like Move, and both **remember the last
  destination folder**.
- **"Move Here from Another Drive…"** is faster (8-way copy, fully off-main) and now
  **pausable** — Pause finishes the in-flight files and parks the job; **Resume** picks
  up where it left off (already-transferred files are skipped, none re-copied). Moved
  files are deleted from the old drive as they go, and each file's **creation + capture
  date** is stamped from its embedded metadata (EXIF is carried over by the byte copy).
- **Faster large-folder loading** on a slow external drive (in-memory listing
  cache + lazy EXIF/caption reads; per-file stats now read concurrently so big
  folders that took 5–30s open far quicker).
- **Favorites / To AI** are scoped to the current folder (and its subfolders).
- **App-wide orange gradient** (vibrant orange → light) with transparent
  no-thumbnail folder tiles.

### Stability fixes
- **UserDefaults 4 MB overflow** — large per-photo collections (labels, captions,
  favorites, etc.) are now stored in JSON files in Application Support, with a
  one-time migration that also clears the corrupt oversized keys. A big download was
  exceeding the 4 MB UserDefaults limit, corrupting prefs and crashing the app.
- **Stack overflow in FolderView** — the view's `body`/`content` modifier chain had
  nested `ModifiedContent` ~60 levels deep; it's now built in `AnyView`-separated
  chunks so the runtime can't overflow computing the type metadata.

---

> Note: development and on-device verification happened on the repo owner's iPhone
> against an external SanDisk SSD. The scraping features (Facebook, TikTok,
> accessKardashian, taylorpictures) are best-effort and depend on those sites'
> markup, so they may need occasional tuning.
