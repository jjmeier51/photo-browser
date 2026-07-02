# Photo Browser — Feature Catalog, Shortcomings & Future Fixes

A running catalog of every feature added to the app during this line of work, plus an honest list
of the app's current shortcomings and concrete ideas for fixing them. Grouped by area; each entry
notes the relevant commit(s) where useful.

> Companion doc: [`photo-editor-capabilities.md`](photo-editor-capabilities.md) describes the editor
> tool-by-tool in more depth. This file is the broader ledger (editor **and** everything else), with a
> candid limitations section at the end.

---

## 1. Photo Editor (in-app, non-destructive)

A full Hypic/Facetune-style editor was built from scratch inside the app.

### Core & pipeline
- **Non-destructive editing session** — `EditRecipe` (a `Codable` list of ops) is the single source of
  truth; rendering is a pure function of `(original, recipe, masks, landmarks, stickers)`. Live preview on
  a downscaled proxy; full-res only on export. (`80473b2`)
- **Undo / redo / reset**, **hold-to-compare** with the original, **pinch-zoom + pan** preview.
- **Metadata-preserving, non-destructive save** — writes a *new* file, copying all EXIF/TIFF/GPS/IPTC and
  keeping the capture date byte-for-byte; orientation baked once. All writes funnel through `PhotoEditorIO`.
- **HDR retention** — HDR sources (gain-map / PQ-HLG / RAW) save as 10-bit HDR HEIC; warps route through a
  16-bit float wide-gamut raster so headroom survives. (`278f4a0`, `fbad399`, `9f1f110`)
- **Save-time upscaling** — None / 1.5× / 2× ("AI" = Lanczos + denoise + sharpen). (`fbad399`)

### Adjust / Filters / Crop / Detail
- **Light & color adjustments** (13): exposure, contrast, highlights, shadows, saturation, vibrance,
  warmth, tint, sharpen, structure, vignette, grain, fade — plus one-tap **Auto**. (`80473b2`)
- **Filters** — 10 → **42 preset looks** with per-filter intensity and live thumbnails; **background-only
  filter** (apply a look only behind the subject); **favorites + search** in the strip. (`72806b1`, `2aa8239`)
- **Crop & geometry** — freeform + fixed ratios, rotate, flip, straighten; **freeform crop**;
  **perspective / keystone correction** (H + V). (`f223398`, `2aa8239`)

### Reshape & body/face shaping
- **Manual reshape / liquify** — push-warp brush, mesh-based, with size + strength, **pinch-zoom canvas**,
  a **persistent size ring**, and a **finer mesh** so a small brush localizes. (`fec598b`, `560648e`,
  `1e18e92`, `37c1478`)
- **Body & face shaping** (Vision landmark-driven, confined to the subject) — Slim, Waist, Hips, Butt,
  Breasts, Legs, Height, Arms, Ankles, **Feet**, Neck, **Torso** (shorten), Head, Forehead, Eyes, Nose,
  Ears, Chin, Lips, Smile. Many rounds of tuning for isolation and to avoid warping arms/background.
  (`e727c4e`, `0e78713`, `33a54b9`, `67aaa98`, `3d80cb7`, `42c4f90`, `741f5d6`, `1255979`, `23ef47f`,
  `a1c6853`, `fa16dc9`)
- **Breast shaping — final model:** a single **fold-free radial "inflate"** (the localized magnification pro
  apps use) after earlier additive approaches caused tearing; cleavage/roundness/outer-edge fall out of it,
  confined to an arm-safe window. (`5353e00` → `70d3fc2` → `ada339f` → `2819239` → `4886f67`, `0493ee2`,
  `ce49863`)

### Retouch, brushes, skin, makeup, stickers, text
- **Object removal** (TouchRetouch-style magic eraser) — on-device coarse-to-fine diffusion inpainting with
  matched grain to blend. (`e1cda27`, `fa16dc9`)
- **Smooth / Paint / Teeth brushes** — freehand, recipe-stored; Smooth (skin), Paint (any color + eraser),
  Teeth-whiten; persistent size ring; **retroactive opacity** (slider changes already-painted strokes).
  (`122dc06`, `37c1478`, `0e068a1`)
- **Skin tone** (pale ↔ tan) — color-cube skin mask ∩ subject mask; YCbCr detector for dark→light skin
  coverage. (`cd90010`, `37c1478`)
- **Makeup** — 10 templated Looks + one-offs (Lips, Blush, Eyeshadow, Eyeliner, Lashes, Brows) + 5 freckle
  levels; freckles reworked repeatedly to be small/defined/on-face (nose+cheek band, skin-masked); lashes &
  brows made bold + robust. (`444d8ca`, `2d06657`, `3d80cb7`, `c8ebacd`, `0e068a1`, `0493ee2`, `ae4f122`,
  `ce49863`)
- **Image stickers** — import from Photos *and* in-app folders/Files; move/pinch/rotate; **cut-out**
  background; **HDR-preserving**; **shadow/glow** with size/intensity. (`bd35ffa`, `e0631a2`, `04a0126`,
  `37c1478`)
- **Text tool** — add/move/scale/rotate text; **50 fonts** (with previews), any color, bold/italic, **15
  styled effects** (glow, neon, fire, ice, gold, chrome, rainbow, 3D, sticker, outline, retro, bubble,
  emboss, shadow, plain); tap-away to "set". (`37c1478`, `0e068a1`)
- **Change Size (resize)** — resize by **percentage** or exact **pixels** (locked to aspect ratio),
  high-quality Lanczos, in place, metadata preserved. (`254bd35`)
- **Removed:** hair recolor (geometric approximation never worked well). (`868d89a` added, `122dc06` removed)

### Viewer entry points
- Viewer ⋯ menu actions: **Edit Photo**, Crop & Rotate, Resize/Extend, **Change Size…**, Edit with AI,
  Duplicate, Copy, Move, Delete, Use as Album Cover. (`f223398`, …)

---

## 2. Cloud & AI features (opt-in, on-device-first)

- **Edit with AI / Extend with AI (Astria)** — hardened: send `Accept`/`User-Agent` headers so Astria's
  Cloudflare layer returns JSON instead of a "Just a moment…" bot-challenge page, and show a clear error if
  it still challenges. (`22756db`)
- **Google Drive download — built-in browser** (`786eafc` → `1c4138d` → `5fe671e` → `6869f3b`):
  - A **WKWebView** where you sign in with your normal Google login (persistent, on-device).
  - **"This Folder"** downloads every loaded item; **Select mode** injects a tap-to-select layer (Drive's
    mobile web has no real multi-select) to pick specific items.
  - Downloads via the signed-in **session cookies** (no API key/token), **concurrent (fast)**, as an
    **app-wide background activity** so you can keep navigating; filenames from `Content-Disposition`.
  - **Large-file handling** — follows Drive's "can't virus-scan" confirm page for files >~100 MB.
  - (An earlier API-key/access-token + link/browse version exists in `GoogleDriveService.swift`, superseded
    by the browser but reusable.)

---

## 3. Instagram / stories

- **Downloads & stories run as app-wide background activities** — navigate around while they run. (`6f56a7e`,
  `40ba93b`)
- **"Today's Instagram Stories" organized by handle** — each user's stories go into their own handle
  subfolder instead of a flat prefixed pile. (`254bd35`)
- **Safer stories-folder clearing** — clear via atomic rename → background delete, so an interrupted delete
  can't leave a corrupt, un-listable folder. (`3878eb3`)

---

## 4. Browsing / folders / search fixes

- **Folder "Edited" filter** — shows in-app-edited photos; later fixed so it **no longer hides folders**.
  (`1e18e92`, `9bbc82e`)
- **Folder creation** now surfaces failures instead of failing silently. (`9bbc82e`)
- **Search finds folders by name** (the fast index path only matched media before); age computation no
  longer blocks a text search. (`079114b`)
- **Pull-to-refresh + re-list on foreground** — force a fresh disk listing; catch folders created while
  backgrounded or changed in Files. (`17c5a3e`)

---

## 5. Notable bug fixes

- Filter-intensity crash (`CIDissolveTransition` needed `inputTargetImage`). (`7950ec6`)
- `CGRect.isFinite` inaccessible → `!isInfinite && !isNull`. (`d413d24`)
- Sticker delete crash (binding to a removed index). (`04a0126`)
- Makeup oversaturating HDR saves (Vision on extended-range → detect on a clamped SDR copy). (`9f1f110`)
- Reshape zoom resetting mid-drag; HDR flattening on reshape save. (`560648e`, `fbad399`)

---

## 6. Documentation

- `docs/photo-editor-capabilities.md` — the editor reference. (`80587ac`)
- `docs/feature-catalog.md` — this file.

---

## 7. Shortcomings (honest)

**On-device ML / masking limits**
- **Subject mask quality** governs body-shaping isolation. On low-contrast photos the warp can bleed into
  the background/limbs. Apple's `VNGenerateForegroundInstanceMaskRequest` is the ceiling here.
- **No clothing segmentation** on-device (no Apple API), so "keep the bikini top the same size" isn't
  possible; body warps move fabric with skin.
- **Color-based detection** (skin tone, freckle skin-mask) can catch skin-colored clothing, wood tones, or
  reddish hair; and can miss skin near a same-toned hairline.
- **Object removal can't synthesize texture** — clean on smooth/gently-textured backgrounds (sky, wall,
  skin), soft on heavily-textured ones. Matched grain only partly hides it.
- **Makeup/freckles are heuristic** and depend on Vision face sub-landmarks (eyes/brows/lips), which can be
  sparse on tilted/occluded faces.

**Editor**
- Edits **bake into pixels**; they aren't stored as a re-editable recipe on the saved file (no PhotoKit
  `adjustmentData`-style round-trip). Re-opening a saved edit starts fresh.
- **Change Size / Crop / Resize save in place** — downscaling permanently reduces resolution for that file.
- Tone Curve + HSL (**FR-ADJ-02**), a selective *adjustment* brush (**FR-ADJ-03**), cutout **mask-refine**
  brush, and an explicit **export-controls** sheet (**FR-SAVE-02**) are still unimplemented from the PRD.
- Text tool: the 50 fonts fall back to the system font if unavailable; gradient effects are heuristic.

**Cloud / Google Drive**
- **Web-scrape fragility** — the Drive browser reads Google's web DOM (`data-id`, injected tap-select). A
  Drive web UI change can break selection or "This Folder".
- **Embedded Google login can be blocked** ("browser may not be secure") despite the Safari UA.
- **"This Folder" only sees loaded items** (Drive lazy-loads on scroll); **subfolders aren't recursed**;
  Google-native Docs/Sheets are skipped.
- **Astria** depends on their Cloudflare config and content moderation; the access-token path (if used)
  expires ~1 h.

**Platform / reliability**
- **iOS background limits** — long transfers/downloads can't finish once the app is terminated; only a few
  minutes of background time.
- **External-drive filesystem corruption** — an interrupted write (app killed mid-delete, drive unplugged,
  or a failing SSD) can corrupt a directory entry so a folder shows as a *file* or won't list. This is a
  filesystem/hardware issue (repair with Disk Utility First Aid); the app now avoids in-place deletes of the
  stories folder, but any write path is exposed to a yanked drive.
- ~~**Age computation** over a large library (100+ albums) runs on every content change and can be slow~~ —
  fixed: it's now lazy (runs only when an age sort/filter/search is engaged or the Age menu is opened),
  and capture dates are pre-warmed into a persistent store in the background.
- **No test target / CI**; every change is verified by building and exercising the app (the dev environment
  can't compile it — all Swift here was written blind and verified on device).

---

## 8. Potential fixes / roadmap

**Better masks & inpainting**
- Bundle a small **CoreML segmentation model** (person + clothing/hair) to replace the geometric/color masks
  — would fix body-warp isolation, skin/freckle spill, and enable "keep fabric size".
- Bundle or vendor a **CoreML inpainting model** (or a Telea/Navier-Stokes/patch-match implementation) for
  texture-aware object removal.

**Editor**
- **Persist `EditRecipe`** alongside the saved file (or in a sidecar) so edits stay re-editable.
- Add an **"save as copy"** option to Change Size/Crop so downscales don't overwrite the original.
- Finish the PRD gaps: **Tone Curve + HSL**, a **selective adjustment brush**, **cutout mask-refine**, and
  an **export sheet** (format/quality/share).

**Google Drive**
- Replace scraping with **proper OAuth** (a Google client ID + a URL scheme in the build config +
  `ASWebAuthenticationSession`): persistent sign-in, **refresh tokens** (no ~1 h expiry), **recursive**
  folder download, and no dependence on the web DOM. This is the single biggest robustness win for Drive.

**Reliability & performance**
- ~~Make **age computation lazy**~~ — done (computed only when the Age filter/sort/search or menu is used);
  the whole-drive index and per-file dates/specs now persist across launches too.
- Add **retry/backoff** and resumable downloads for cloud transfers; consider chunked range requests so a
  cut-off large download can resume.
- Harden **all** external-drive write paths the way the stories folder was hardened (write to a temp name,
  fsync, atomic rename), and detect a corrupt/duplicated directory entry to warn the user early.
- Stand up a **metadata-preservation test** (§5.4 of the PRD) and a small **CI** so the save path is guarded
  against regressions.

**Nice-to-haves**
- Set the per-handle **stories subfolder covers** to each user's profile picture.
- A **People/faces** library and **OCR text search** (drafted in an earlier plan; not yet built).
