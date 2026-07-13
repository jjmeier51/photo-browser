# Changelog

Major changes to Photo Browser. Dates are when the work landed on `main`.

## 2026-07-13

- **New: in-app web browser with long-press-to-download video** (root "…" menu → "Browse the
  Web & Download Video…"), modeled on Aloha Browser's core feature. Browse any site; an injected
  script watches page traffic for media (direct `.mp4`/`.m4v`/`.mov`/`.webm` and `.m3u8` HLS
  playlists) and reports the `<video>` under your finger. **Long-press a playing video** → the app
  offers to download it into the current folder. Direct files stream to disk; HLS streams fetch
  every segment (bounded-concurrent), decrypt AES-128 on the fly (CommonCrypto), and merge —
  fMP4/CMAF into a clean `.mp4`, MPEG-TS into `.ts` (remuxed to `.mp4` when FFmpegKit is present).
  Requests carry the browser's cookies + Referer so hotlink-/login-gated media saves the same way
  it played. DRM (Widevine/FairPlay) and pure-`blob:` MSE with no discoverable manifest can't be
  captured — the same limits Aloha has. `WebBrowserView` + `WebVideoDownloader`.
- **Web browser also downloads files, not just video** — long-press a file link (`.zip`, `.pdf`,
  an image, an installer, …) to save it, and any response the web view can't render inline (or that
  the server marks `Content-Disposition: attachment`) is intercepted and offered as a download, so
  a site's "Download" button works. Files stream to disk with true byte-progress in the Downloads
  tab, keeping the server-suggested filename + extension. `WebVideoDownloader.downloadFile`.
- **Web-browser downloads carry a members-only login** — the username/password entered at a site's
  HTTP Basic-Auth prompt is remembered per host and sent as an `Authorization` header on the
  download request, so `.htpasswd`-protected videos/files save instead of failing with a 401. If a
  download still hits a 401 with no stored login (WKWebView can be silently authenticated from a
  prior session), it now shows a "Sign In to Download" prompt and retries with what you enter.
- **Downloaded files keep their EXIF** — the browser writes downloaded bytes verbatim (EXIF was
  never stripped); it now also sets an image's file date from its EXIF capture date so Age/date are
  right, rather than stamping the download time.
- **Capture date from the page HTML** — when a download's own file metadata has no capture date and
  the page prints one (e.g. hotwiferio's `<div class="cell update_date"> 06/30/2003 </div>`), the
  browser reads that date and stamps the saved media with it — real EXIF for photos, a lossless
  metadata re-mux for videos, plus the file date — so it sorts and ages by the right day.
- **Web browser: video playback is off by default, with a toolbar toggle** — a new ▶ button in the
  top-right turns video playback on/off. Off by default so a page's video can't autoplay or expand
  over what you're trying to download; tap it to watch. `WebController.setVideoPlayback`.
- **New: zip / unzip in the app** — long-press any file or folder (or select several) → "Compress
  to Zip" to create a `.zip` in the current folder. To unzip, **just tap a `.zip`** (or long-press it)
  → "Extract Here" unzips into a new subfolder. Contents are copied byte-for-byte so **all
  EXIF/metadata is preserved**, and
  extracted files get their archived modification dates back. Pure Apple frameworks —
  `NSFileCoordinator` for zipping, a hand-rolled ZIP reader + the `Compression` framework for
  unzipping (no third-party library). `Archiver.swift`.

## 2026-07-10b

- **Exported frames pre-warm their thumbnails** — "Export all frames" now generates each
  frame's grid thumbnail from the frame it already has in memory and writes it straight to the
  local thumbnail cache. Opening a huge frames folder (e.g. 6,000 frames) afterward reads small
  cached JPEGs from local storage instead of decoding every full HEIC off the external drive —
  eliminating the multi-minute thumbnail stall.

## 2026-07-10

- **New: VSCO downloader** — "Download VSCO Profile…" (root "…" menu): enter a public VSCO
  username and pull the whole gallery (photos + videos, full resolution) into a "username"
  folder. EXIF is preserved verbatim; a photo with no capture date gets VSCO's posting date
  (capture_date, else upload_date) written into EXIF and stamped on the file. Runs as a
  background activity like the other downloaders, dedups by media id for "Get New VSCO Photos",
  and writes a `vsco-log.txt` diagnostic. Uses VSCO's public web API (no login); best-effort.
- **TikTok: downloads photo/slideshow posts** — photo posts (image carousels) were dropped
  because the listing required a video URL; they now download one image per slide. (Downloads
  already ran on a true background URLSession.)
- **Rotating an HDR video keeps its HDR** — the rotate/crop re-encode now detects PQ/HLG and
  renders BT.2020 10-bit HEVC instead of tone-mapping to SDR.
- **AI Upscale for videos in the long-press menu** — long-pressing a video now offers AI
  Upscale (1080p / 4K) via the HDR-preserving path, matching the photo menu.
- **accessKardashian: full-drive warning** — a (nearly) full drive is now detected up front and
  called out in the result note and log (it's the cause of a "crawling" run — exFAT thrashes to
  place files on a 0-free volume).

## 2026-07-09d

- **Edit with AI records model + prompt (searchable, tap-to-copy)** — a kept AI edit now stores
  the model used (e.g. "Seedream 4.5") and the exact prompt, both embedded in the file's
  metadata (EXIF UserComment / Software) and in a path-keyed app store that follows the file on
  move/rename. The info panel shows an "Edited with AI" section with the model and a
  tap-to-copy prompt field, and both fields are matched by search (folder view + the whole-index
  search).
- **Home highlights 10% larger** — the Home-page album-highlight bubbles grew from 56 to 62 pt
  (still five per line).

## 2026-07-09c

- **Facebook downloader: per-run diagnostic log + wider album discovery** — a Facebook run now
  writes `facebook-log.txt` into the folder detailing every media set it walked: which album
  tokens were found, how many items each set (uploads/tagged/albums/videos) emitted, and why
  each walk stopped — crucially distinguishing "reached the real end" from "the next-photo
  chain broke while a page still had a photo" (the truncation signature). Album discovery also
  now recognizes more album-id shapes on the albums tab, so uploads don't fall back to the
  truncation-prone `pb` walk when the album list is parsed in a different form.

## 2026-07-09b

- **Home page: highlights wrap instead of scroll** — on the Home page only, the album
  highlights now lay out as a wrapping grid (max 5 per line, sorted A–Z) so all of them are
  visible at once rather than in a horizontal scroller. Bubbles are slightly smaller there so
  five fit a phone's width. Every other folder keeps the horizontal, drag-arrangeable row.

## 2026-07-09

- **Edit with AI: pick output resolution and dimensions** — the Edit-with-AI sheet now has an
  Output section: **Resolution** (1K / 2K / 4K) and **Dimensions** (Original / 1:1 / 4:5 / 9:16).
  Resolution sets the uploaded input size and, at 4K, asks Astria to super-resolve the result
  (the gallery tunes reject explicit sizes over ~2048, so 4K is reached via super-resolution
  rather than a larger upload). Dimensions forces a fixed aspect ratio, or keeps the photo's
  own shape on "Original".
- **HDR uploads to Astria: softer highlight tone-mapping** — HDR photos were still reading a
  touch washed-out/over-exposed because the upload hard-clamped every value above 1.0 to flat
  white. The upload now applies a soft highlight rolloff (a `CIColorCurves` tone curve over the
  extended range) that keeps midtones intact and compresses highlights toward white so their
  detail survives, falling back to the old clamp if the curve can't be built. (Astria itself
  only ever returns SDR — there's no way to make it hand back an HDR/gain-map image — so this
  is about sending it the best-looking SDR rendition.)
- **AI-completion notifications fire reliably** — the notification delegate is now installed at
  app launch instead of lazily when a job starts. iOS only guarantees the foreground-present
  callback when the delegate is set that early, which was the residual cause of alerts landing
  only some of the time.
- **OnlyFans: DRM videos are called out in the run summary** — DRM-protected videos are now
  reported as their own line ("N DRM-protected videos: X decrypted, Y skipped (daily 5/day
  extraction limit), …") in both the result note and the log, instead of the daily-limit skips
  disappearing into a generic "N failed" count.

## 2026-07-08

- **Thumbnail cache is now permanent** — the on-disk thumbnail cache moved from
  `Library/Caches/thumbs` (which iOS purges under storage pressure — the cause of the library
  re-thumbnailing itself a few times a day) to `Library/Application Support/thumbs`, which the
  OS never auto-purges. The directory is excluded from iCloud/iTunes backup since it's
  regenerable derived data, and a one-time migration folds the old cache into the new home so
  nothing regenerates on the update.
- **Safe removal for the external drive** — physically pulling an exFAT drive mid-write can tear
  the FAT (no journaling), the same reason desktops make you "Eject" first. Two additions close
  that gap without slowing downloads: the app now flushes the drive to a consistent, `fsync`'d
  baseline whenever it backgrounds (a no-op for active download windows — they keep committing
  at full speed), and a new **Prepare Drive for Removal…** action (root "…" menu) drains any
  in-flight write, pauses new ones, and confirms **Safe to Disconnect** before you unplug. Both
  build on the existing `DriveWriter`, which already serializes and flushes every file placement
  so at most one directory entry is ever in flight.

## 2026-07-06

- **Fix: watchdog kill after big moves; freezes on editor saves** — re-keying labels after a
  multi-item move compared every stored path against every moved item (a string concat per
  check, at 100k-photo scale) and then re-encoded *every* path-keyed collection to JSON — all
  inline on the main thread. Files finished moving, the bar froze on its last frame (~96%),
  and iOS killed the app before the success message. The remap is now O(1) per stored path
  (exact-match table for files, prefix pairs only for folders), and persistence runs on a
  serial background queue from copy-on-write snapshots (FIFO, so a rapid second move can't be
  overwritten by a stale earlier snapshot). The same machinery caused the occasional freeze
  when saving an edited photo: container-change overwrites re-key the path, and every save
  re-encoded the ever-growing "Edited" set inline — both now persist off-main. The crop
  editor's full-resolution decode/re-encode (`applyPhotoInPlace`) is also marked
  `nonisolated` so its `Task.detached` save genuinely leaves the main actor (hard-won
  constraint #1).
- **Facebook downloader: complete coverage, faster, upscaled** — discovery now enumerates the
  profile's *real albums* (Timeline/Mobile Uploads, **Profile Pictures**, Cover Photos, custom
  albums) and walks each one, instead of relying only on the classic `pb` virtual set that
  Facebook truncates around 100 photos (the "only 99 downloaded" ceiling); the `pb` and tagged
  sets are still walked too, with everything deduped by media id. A photo
  page that returns without an image or next-pointer is retried (and refetched via the
  alternate `photo.php` form) rather than silently ending the set, and page fetches retry
  transient failures (429/5xx) with backoff. Speed: all set walks run concurrently through one
  shared pacer (so the aggregate request rate stays polite), downloads start while discovery is
  still walking (streamed pipeline, width 8, CDN retries), and the per-page sleep is gone.
  Downloaded photos can run through the app's **2× AI Upscale** (denoise + sharpen + double
  resolution, on by default, metadata preserved). "Posted by" is fixed — the profile-name
  resolver no longer produces an empty name (og:title → embedded-JSON owner name → title →
  vanity fallbacks), each photo credits its *actual* poster (tagged photos are posted by
  someone else), and the info panel shows Facebook posters as plain names (no "@") with a
  "Facebook" label instead of "Instagram".
- **Facebook downloader works again** — rebuilt on www.facebook.com's embedded JSON after
  Facebook retired the `mbasic` HTML site the old scraper depended on (every request there now
  hits a login interstitial, which is why downloads found nothing). Media sets are walked photo
  by photo via each page's "next media" pointer (no volatile GraphQL doc_ids), which also brings
  real improvements: full-resolution originals, exact post timestamps from `created_time`
  (previously fuzzy text parsing), cleaner captions, an early stop for "Get New" runs once it
  hits a stretch of already-downloaded items, and a login-wall detector so an expired session
  says "log in again" instead of "no photos found". Also fixes the profile resolver matching
  `"userID"` — the *viewer's* id, not the profile's.

## 2026-07-05

- **Editor save choices** — saving now offers Overwrite Existing Photo / Overwrite + 2× AI
  Upscale / Save as New Photo / Save as New + 2× AI Upscale (replacing the old always-new-file
  save with 1.5×/2× options). Overwrite renders to a temp file and atomically swaps it over the
  original (`replaceItemAt` — a failed save can't destroy the photo), keeps the original's file
  dates so the timeline is stable, and keeps labels/captions attached; if the container changes
  (gain-map JPEG saved as HDR HEIC) the original is removed and path-keyed metadata re-keyed.
- **Object removal: optional CoreML (LaMa) tier** — if a converted LaMa inpainting model is
  dropped into `PhotoBrowser/` (`Inpainting.mlpackage` / `LaMa.mlpackage` — see
  `docs/ml-inpainting.md` for the 5-minute conversion), removals run through the generative
  network first (Neural Engine, context window ≥512pt, same feathered hole-only composite) and
  fall back to exemplar synthesis on any failure. Without a model the app builds and behaves
  exactly as before — `MLInpainter` discovers the model and its I/O contract at runtime.

## 2026-07-03

- **Object removal: strokes are independent** — each removal now inpaints in its own tight
  working window, incrementally on top of the previous result (and undo/redo replays strokes
  one at a time; save applies them the same way). A combined all-strokes mask used to connect
  distant removals into one giant window, dropping the fill resolution and re-synthesizing —
  visibly changing — earlier, unrelated areas whenever a new removal was made.
- **Object removal, round 3** — a re-search-and-vote refinement pass (each synthesized patch
  re-matches against the completed fill; overlapping matches average, Gaussian-weighted) blends
  the first-pass patch collage into continuous texture. Retouch UX: zoom no longer resets after
  a removal (the preview scroll view now preserves zoom + center across bounds changes, and the
  "Removing…" spinner no longer changes the panel height); removals joined the top-bar Undo/Redo
  history (each stroke = one step); the panel gained "Undo Last" and "Clear All" (removals only —
  ↺ Reset remains "undo everything").
- **Object removal, round 2** — adaptive working resolution (small removals like an earring now
  synthesize at near-native resolution — the fixed cap was upscaling the fill and printing square
  patch seams), overlapping patches cross-blend instead of meeting in hard edges, and the mask
  dilation widened so an object's anti-aliased rim can't survive. Retouch brush: smaller default
  and range, and the persistent size ring (like Smooth/Paint) now shows on the retouch canvas.
- **Object removal actually removes** — replaced the diffusion fill (whose blur-average of the
  surroundings was the "fuzzy grey area") with exemplar-based patch synthesis, the TouchRetouch /
  Content-Aware-Fill approach: real 9×9 patches of surrounding texture are copied into the hole
  (best-match search, onion-peel order, locality bias), so fills carry genuine texture and
  structure. Runs in a resolution-capped window around the mask; only the hole + a feathered
  seam changes. Masks covering most of the image fall back to the old diffusion fill.
- **Labels are fast at 100k+ photos** — applying a label to a selection is one mutation +
  one persist (was a full re-encode of the entire ~20MB label store *per selected item*, on
  the main thread); label persistence is now per-label files, debounced and written off-main,
  so a label tap is instant. Opening a Kardashian/Taylor Swift label view resolves against
  the in-memory index (dictionary join) instead of stat'ing every labeled path serially on
  the drive, and "No Label" filters the index instead of re-walking the whole subtree —
  Favorites and "To AI" get the same win.
- **Editor saves match the source format** — PNG in → PNG out (always), SDR JPEG → JPEG,
  HEIC → HEIC; fixes SDR files (e.g. BT.2020-tagged images) coming back as HDR HEICs, which
  came from the HDR detector treating a BT.2020 *gamut* tag as HDR. Genuinely HDR sources —
  including gain-map JPEGs — still save as 10-bit HDR HEIC so the headroom survives.
  Transparent cut-outs still force PNG.
- **Hide folders** — long-press a folder → "Hide Folder": it vanishes from the grid, the
  bubble row, and search (contents included) without touching the drive. The ⋯ menu's
  "Show Hidden Folders" toggle reveals them dimmed for unhiding. Hidden state follows
  moves/renames/remounts and copies to backup drives with the rest of the metadata.
- **Search: locations + dedup** — new "Index Locations" action (⋯ menu) reads photo GPS
  (cached per file), bins it to ~1km cells, and reverse-geocodes each *place* once
  (rate-limit-friendly, capped per run, resumable); search then matches place names
  ("paris", "brooklyn") alongside folder names, file names, captions, and OCR'd photo text.
  Index search results are now deduped by URL — folders could match twice (as an index entry
  and via parent expansion), and duplicate ids confused the results grid.
- **"Copy Metadata to Backup Drive…"** (⋯ menu) — after copying the library's files to a
  backup SSD, this duplicates *every* piece of path-keyed data onto the backup's matching
  paths, keeping the primary untouched: favorites, To AI, custom labels, captions, covers,
  birthdays, Edited/AI badges, Instagram/Facebook/TikTok profile records, highlights, bubble
  order, story links, likes, Clean Up progress, not-duplicate pairs, and the People library —
  plus the per-file caches (capture dates, media specs, OCR text) so the backup browses warm.
  Thumbnails are shared automatically when the backup's internal layout matches.
- **Bulk Instagram Download runs app-wide and updates existing profiles** — the run moved
  onto `Library` (progress pill + completion popup), so the sheet can be closed and the app
  navigated (and briefly backgrounded) while it works. Already-downloaded profiles are no
  longer skipped: they get an incremental "new posts only" check, targeting the profile's
  existing registered folder so nothing re-downloads. Also: "Edit with AI" gained a
  tap-to-reuse prompt history.
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
