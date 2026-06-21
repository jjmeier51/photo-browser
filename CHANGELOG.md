# Changelog

Major changes to Photo Browser. Dates are when the work landed on `main`.

## 2026-06-21

- **Auto folder thumbnails** — any folder with no cover gets one automatically as its cell
  appears, picked from a random photo/video inside it (descending into subfolders when it
  holds only folders). Filled lazily while you browse — reads just that folder, so it
  doesn't wait on the whole-drive index. Manually-set covers are never touched, and folders
  with no media stay plain. (`Library.ensureRandomCover`)
- **"Open … Stories" now navigates** — from a collected story's info panel, the link to
  that person's Stories folder tears down the viewer first, so the push is actually visible
  instead of just hiding the info card. Story links also survive folder moves now.
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
