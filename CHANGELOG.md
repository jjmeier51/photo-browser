# Changelog

Major changes to Photo Browser. Dates are when the work landed on `main`.

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
- **Faster large-folder loading** on a slow external drive (in-memory listing
  cache + lazy EXIF/caption reads).
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
