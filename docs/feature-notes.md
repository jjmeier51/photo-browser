# Photo Browser — Feature & Change Notes

In-depth notes on the features and non-obvious engineering decisions layered onto the app,
written for a future Claude (or human) who needs to understand *why* the code is shaped the
way it is — not just what it does. Read this alongside `CLAUDE.md` (architecture + hard-won
constraints) and `docs/photo-editor-capabilities.md` (the photo editor).

Each section names the **key files/symbols** and the **reasoning**, and calls out the
gotchas that were discovered the painful way, so they aren't relearned.

---

## 1. Cloud AI (Astria) — Edit / Create / Extend / Tunes

The app has an opt-in cloud AI feature set backed by **astria.ai**. Everything is gated on
the user's API key (Settings); with no key the app is fully offline. All networking/parsing
is `nonisolated` and off the main actor.

### 1.1 Core file: `AIExtend.swift`

`enum AIExtend` is the whole Astria client + config. Key pieces:

- **`AIModel`** (`seedream5Pro`, `nanoBanana2`, `flux`):
  - `partnerModels` = `[.seedream5Pro, .nanoBanana2]` — the closed gallery models. Used in
    Settings (default-model picker, tune-id overrides) which must **exclude Flux** (Flux has
    its own "Flux (extend)" tune field).
  - `composesLoRA` is true only for `.flux` — Flux is the only base that can run a user LoRA
    composed into the prompt via `<lora:id:weight>`.
  - `tuneID(for:)` maps a model to its Astria gallery tune id (editable in Settings; Flux
    shares the single editable Flux tune).
  - We deliberately **removed** the older "Nano Banana Pro" and "Seedream 4.5" options and
    kept only Nano Banana 2 and Seedream 5.0 Pro.

- **`OutputResolution`** (`k1`/`k2`/`k4` → "1K"/"2K"/"4K"): sent as Astria's
  `prompt[resolution]` **size tier**. This is the documented way to actually reach 4K on the
  newer models. IMPORTANT: `prompt[resolution]` is **only accepted by the newer partner
  models**; any **Flux** base rejects it with a validation error. See resolution gating below.

- **`OutputAspect`** (`original`/`square`/`portrait`/`story`): sent as `prompt[aspect_ratio]`.
  `.original` → nil → `generate` derives the nearest supported ratio from the (upright) source
  dimensions. Astria's tunes reject the literal `"auto"` and default a blank value to
  landscape, so we always send a concrete ratio.

- **Two dedicated URLSessions** (perf): `apiSession` (small/timely calls) and
  `downloadSession` (result-image fetches, `networkServiceType = .background` so it yields to
  interactive traffic). Both cap `httpMaximumConnectionsPerHost`. This replaced
  `URLSession.shared`, which made the UI hitch while several edits generated at once.

### 1.2 Generation: `generate(...)`, `resolveGeneration(...)`, `Generation`

- **`generate(tune:token:prompt:imageData:count:width:height:aspect:resolutionTier:onPrompt:)`**
  is the unified img2img (Edit; `imageData` present) / text2img (Create; `imageData` nil) call.
  It POSTs a multipart prompt to `/tunes/{tune}/prompts`, then `poll`s the prompt id until its
  `images` array is populated, then downloads via `downloadPromptImages` (concurrent
  `withTaskGroup`, `downloadSession`, 2xx-only bodies).
  - Token/trigger injection: `token` is the **full trigger phrase** (e.g. `ohwx woman`), and
    `generate` prepends it when the prompt doesn't already contain its first word. See 1.4.
  - `resolutionTier` is only sent when non-nil (resolution gating, see 1.4).

- **`resolveGeneration(model:tunes:)`** turns the picked model + selected tunes (0…`maxTunes`,
  `maxTunes = 10`) into a `Generation { tuneID; promptPrefix; token; label; supportsResolution }`:
  - **No tune** → the model's own gallery tune; `supportsResolution = (model != .flux)`.
  - **One tune** (`resolveSingle`): Flux → `<lora:id:1>` prefix on the Flux base,
    `supportsResolution = false`; a partner model → POST to the tune's own id,
    `supportsResolution = !tune.isFluxLoRA`.
  - **Multiple tunes** → *stacked*: Flux → several `<lora:id:1>` tags + each subject's trigger
    phrase, on the Flux base; a partner model → several `<faceid:id:1>` tags on the partner
    gallery model.
  - `Generation.supportsResolution` is threaded to `startAIEdit`/`startAICreate` so the tier is
    omitted (`resolutionTier: nil`) whenever the effective base is Flux.

### 1.3 Tunes (the account's own fine-tunes)

- **`AstriaTune`** (Identifiable/Sendable/Hashable): `id, title, name (class), branch,
  modelType, token, ready, baseTuneID`. `isFluxLoRA` = `branch == "flux1"`. `triggerPhrase`
  = `"<token> <class>"` (nil for FaceID tunes, which have no token). `baseTuneID` is parsed
  from Astria's `base_tune_id` and used for compatibility matching.
- **`listTunes`** — keyset pagination over `/tunes`. Cached ~2 min in `Library.loadAITunes`.
- **`tunes(_:compatibleWith:)`** — the picker only offers tunes that can run on the chosen
  model: Flux shows `flux1` LoRAs; a partner model shows tunes trained on it (matched by
  `baseTuneID`, else any non-Flux tune). This prevents building an impossible pair (a Flux LoRA
  can't run on Seedream/Nano and vice-versa), which otherwise produced a cryptic Astria error.

### 1.4 Two Astria constraints that caused real bugs

- **Trigger phrase must be `"<token> <class>"`.** When you POST to a LoRA/PTI tune (or compose
  it), Astria rejects the prompt unless it contains e.g. `ohwx woman`. We inject the full
  phrase from `tune.triggerPhrase`, testing membership on the first word so we don't duplicate
  it if the user typed the subject. (Symptom fixed: `{"text":["must include \`ohwx woman\`"]}`.)
- **`prompt[resolution]` is Flux-incompatible.** Any Flux base returns a validation error listing
  the models that support it. `resolveGeneration.supportsResolution` gates it off for Flux.
  (Symptom fixed: `{"resolution":["only supported for … Seedream 5.0 Pro …"]}`.)

### 1.5 Creating tunes: `CreateTuneView.swift`, `TuneBaseModel`, `startCreateTune`, `createTune`

- **`TuneBaseModel`** (in `AIGenerators.swift`): `nanoBanana2, seedream5Pro, flux, sdxl, sd15`.
  - `branch`: `flux1`/`sdxl1`/`sd15`, or **nil** for partner models (branch inherited from the
    base gallery tune).
  - `baseTuneID`: Flux → `trainingBaseTune`; partner → `tuneID(for:)`; SDXL/SD1.5 → nil.
  - `modelType`: partner → **`faceid`**, else `lora`.
  - `usesToken` = `modelType != "faceid"`. FaceID has **no subject token**.
  - `minPhotos`: **FaceID → 3, LoRA/PTI → 4** (the Train button's minimum is base-aware).
- **`createTune`** sends `tune[model_type]`, `tune[branch]` (only if non-nil), `tune[base_tune_id]`,
  and `tune[token]` **only when `modelType != "faceid"`** (FaceID rejects a token —
  `{"token":["not allowed for FaceID"]}`).

### 1.6 Critical conceptual point (documented for the user, must persist)

- Partner models (Seedream 5.0 Pro, Nano Banana 2) are **closed** models. You **cannot** LoRA-
  train them; the only personalization is **FaceID**, which is embedding-based and uses only
  ~3 reference faces regardless of how many you upload. To train on *all* of many photos you
  must use a **Flux LoRA** (or SDXL/SD1.5). This is why `TuneBaseModel.note` and
  `CreateTuneView`'s footer spell out the FaceID-vs-LoRA tradeoff, and why `minPhotos` differs.
- A **Flux LoRA cannot be applied to a Seedream/Nano generation** — different architectures.
  Multi-tune stacking composes `<lora:>` (Flux) or `<faceid:>` (partner) *within one family*.

### 1.7 Multi-tune selection UI: `AIGenerators.swift`

- **`AIModelTunePicker`** — a Model menu picker + a **`NavigationLink` to `TuneMultiSelectView`**
  (a checklist of the compatible tunes, cap `AIExtend.maxTunes = 10`, showing layering order).
  Switching model drops now-incompatible selections.

### 1.8 The two flows: `AICreateView.swift`, `AIEditView.swift`

Both pre-fill from remembered `RunSettings` (per flow), show the model/tune picker + a
`comboNote`, resolution/aspect/count, the **Reusable Prompts** section (1.11), and a prompt
history. On generate they save `RunSettings`, call `resolveGeneration`, then
`library.startAICreate`/`startAIEdit`.

- **`RunSettings`** (in `AIExtend.swift`): `prompt, model, tuneIDs:[Int], resolution, aspect,
  count`. Custom **lenient `Codable`** — tolerates older blobs (a single `tuneID`, or missing
  keys) so the rest of the remembered settings survive an upgrade. Persisted under
  `photoBrowser.aiRun.create` / `.edit`.
- **One-shot restore fix (important):** `.task` restores `selectedTunes` from `pendingTuneIDs`
  **then clears `pendingTuneIDs`**. Without clearing, `.task` re-runs when returning from the
  tune picker and re-restored the old selection — which made "set to No Tunes" impossible.

### 1.9 Background jobs, durability, results: `Library.swift`, `AIResultsView.swift`

- `startAIEdit` / `startAICreate` run app-wide behind the activity-pill system
  (`beginActivity`/`setActivity`/`endActivity`, `BackgroundTaskHolder`), plus an
  `AIProgressActivity` live activity and completion notification.
- **Durability:** the moment Astria accepts a prompt, `onPrompt` persists a `PendingAstriaJob`
  (jobID, promptID, tune, paths, prompt, model, startedAt) to `photoBrowser.pendingAstria`.
  `resumePendingAIEdits()` on launch re-polls and downloads any job the app was killed during
  (Astria keeps results server-side). Network/server failures **keep** the pending record;
  only definitively-unrecoverable errors drop it.
- **`AIResultsView`** — Keep/Delete review of each result. `AISaveTarget` is `.edit(original:)`
  (saves into an "AI" subfolder beside the source, inheriting EXIF/date) or `.create(folder:)`.
  Results are **decoded downsampled OFF the main thread** via ImageIO (`downsample`,
  `maxPixel 1400`) so reviewing a batch of up to-4K images doesn't hitch; the full-res `Data`
  is still what gets saved. After finishing, `reopenCreator(after:)` reopens the creator with
  the same settings (`AICreatorReopen` in `ContentView`).
- Upload encodes (`uploadJPEG`) run at **`.utility`** priority (CPU-heavy tone-map/JPEG must
  yield to scrolling when several edits run at once).

### 1.10 Completion notifications: `AILiveActivity.swift`

- `AINotifications` installs a retained `ForegroundPresenter` (`UNUserNotificationCenterDelegate`)
  **at launch** so alerts appear even while the app is foregrounded, and requests authorization
  at launch. Tapping an alert routes its `jobID` back via `tapHandler` → `presentAIResult`.
- **Suspended-app fallback (important):** a local alert can only be *posted* while the app runs,
  so a job finishing after iOS suspends the app never notified until reopen. `AIProgressActivity.
  armFallback(jobID:after:180)` schedules a **time-triggered** notification (delivered even while
  suspended) at job start; `finish()` cancels it once the job completes in-process. So the
  fallback only reaches the user when the normal alert couldn't. (True "server pushed the instant
  it's done" delivery would need a push server or a BackgroundTasks capability — not added.)

### 1.11 Reusable Prompts

- `AIExtend.reusablePrompts: [String]` — a shared list surfaced as a **"Reusable Prompts"**
  section in both `AICreateView` and `AIEditView`, each with one-tap **Use** (fills the prompt
  field) and **Copy** (UIPasteboard). Extend by appending to the array; both views update.

---

## 2. Find Duplicates — `DuplicatesView.swift`, `PerceptualHash.swift`

Non-recursive scan of one folder. Three **independent** match kinds (never chained across each
other, which previously produced nonsense groups):

- **Exact** — identical `size + longSide + pixels`. Video-frame screenshots ("Frame 2.png", …)
  are only grouped exact when the name matches too, so different frames of one video don't pair.
- **Visually similar** — a dependency-free perceptual **dHash** (`PerceptualHash.dHash`: 9×8
  grayscale via ImageIO, 64-bit) clustered by Hamming distance with union-find. Images only
  (videos can't be hashed here). Hashing + the O(n²) clustering run **off the main actor** in a
  detached task. **Threshold = 6** bits — deliberately tight so a photoshoot of similar poses
  doesn't chain into one giant group (an earlier threshold of 10 produced a "791 visually
  similar" blob).
- **Similar name** — names that normalize the same (`normalizedBaseName` strips " (1)", " copy",
  "-1"/"_1", trailing " 2", extension).

`DuplicateMatchKind` = `exact/similar/name` with a `rank` for sorting (exact → similar → name,
then largest first). `DuplicateGroup` carries display helpers `kindNoun/kindLabel/kindIcon/
kindColor` and **`typeLabel`** (the file type(s), e.g. "JPG" or "JPG/PNG").

UI:
- Rows show count, size · dimensions · **file type(s)**, and a colored kind badge.
- **List-level multi-select** (Edit → select groups): bottom bar offers **"Not Duplicates"**
  (records the group as non-dupes so future scans skip it — `library.markNotDuplicates`) and
  **"Delete Duplicates (N)"**, which keeps the **largest** file in each selected group and
  deletes the rest, behind a confirmation. (Because visual clusters can occasionally be wrong,
  deletion is always explicit + confirmed; a false group can be marked Not Duplicates instead.)
- **Compare view** (`DuplicateCompareView`): side-by-side of two items with a same/different
  metadata breakdown, per-item edit menu (rename/date/caption/labels), per-side delete, a
  **"Delete files" multi-select checklist** (tick several, delete together), and "Not Duplicates".
- Deletions re-key labels/origins (`clearLabels`/`clearOrigins`) and call `contentDidChange()`.

---

## 3. External / exFAT drive reading — `Library.swift`

This app's media lives on an external (often **exFAT**) drive reached through iOS's file
provider via a security-scoped bookmark. Several hard problems and their fixes:

### 3.1 `coordinatedContents(of:keys:)` — the robust directory reader

Escalating fallback chain used by the grid listing, subfolder scans, and Drive Health:
1. **`NSFileCoordinator` coordinated read** — so files another app (Finder) added to the volume
   are reconciled before enumeration (an uncoordinated read can return the provider's *stale*
   cache, so externally-copied folders sometimes never appeared).
2. plain `contentsOfDirectory` (coordination unavailable),
3. plain read with **no resource prefetch** (prefetch can choke on huge folders),
4. **shallow `FileManager.enumerator`** (`.skipsSubdirectoryDescendants`) — a lazy stream that
   survives very large directories where the all-at-once read fails,
5. raw **POSIX `opendir`/`readdir`** (`posixContents`) — last resort; note it returns EINVAL on
   this iOS file provider in practice, so it rarely helps, but it's harmless.

### 3.2 Large-folder listing must be lazy — `listing(of:sort:)`

The real cause of "huge folders won't open" was **ours, not iOS**: after enumerating, `listing`
used to `resourceValues`-stat **every** entry (32 concurrent) before painting the grid. For a
~90k-item folder that's ~90k file-provider round-trips up front → appears to hang, while the
Files app (lazy) opens it instantly.
- Fix: prefetch `.isDirectoryKey` during enumeration, and for folders **> 8000 entries** build
  the grid straight from the enumeration (classify folder-vs-file from the cached directory
  flag / trailing-slash URL, **defer size/date**) instead of statting every file.
- `FolderView.reload()` also **skips the bulk EXIF capture-date read** for folders > 8000 (a
  date/smart sort would otherwise re-introduce the same tens-of-thousands read). Such folders
  fall back to name order.
- The `> 8000` threshold: ~12k folders open fine via the enumerator; ~90k did not — 8000 leaves
  margin.

### 3.3 Coordinated reads elsewhere

The grid `listing` retries once (400 ms) when a coordinated read returns empty but the folder
exists (the provider can still be materializing right after a remount).

---

## 4. Drive Health — `DriveHealthView.swift` (Settings → Maintenance)

Recursively scans the SSD and flags **unreadable folders**, **unreadable files** (attributes
won't stat), and **empty (0-byte) media** (the hallmark of an interrupted exFAT copy).
- Uses the same `coordinatedContents` chain; a folder is only flagged after retries with
  backoff (external drives **throttle** a fast full-tree walk, and a single transient failure
  must not be reported as corruption — an early over-aggressive version cried wolf on 223
  perfectly-good folders).
- Captures the real error (`NSCocoaError` domain/code + `opendir` errno) into the row for
  diagnosis. (Field lesson: `opendir` returning `errno 22 (EINVAL)` here was a **red herring** —
  POSIX doesn't work on this provider; the true signal was directory *size*, see 3.2.)
- **Share button** exports the unreadable-folder paths (drive-relative, shallowest-first) as
  text, for a Mac-side rebuild/split script.
- Bad files can be deleted in place; unreadable folders get guidance (re-copy + clean eject).

### 4.1 Companion Mac scripts (not in the repo — delivered to the user)

- `fix-exfat-folders.sh` — rebuilds folders iOS can't open by re-copying them in place (rewrites
  clean exFAT directory entries). v2 counts only **real** files (ignores `._` AppleDouble
  sidecars macOS creates on exFAT, which had caused false "MISMATCH").
- `split-large-folders.sh` — splits folders with too many files into `part_NNN` subfolders. This
  was the *fallback* before we found the lazy-listing fix (3.2) made splitting unnecessary; kept
  for reference.

---

## 5. Storage screen — `StorageView.swift` (Settings → Maintenance)

Lists everything the app keeps **in its own container** (not the SSD), split into **Your data**
(labels/captions/covers/custom-thumbnails/message-archives — path-keyed, lost on reinstall but
re-linkable) and **Caches** (thumbnails, per-file metadata JSON, folder-listing snapshots,
download staging) with per-category sizes and a one-tap **Clear Caches**. Sizing/clearing run
off the main actor. See `StorageView.catalog()` for the exact on-disk locations (Application
Support subdirs + Caches/listings). Useful because sideload reinstalls wipe the container.

---

## 6. Folder file-format filter — `Models.swift`, `FolderView.swift`

`FormatFilter` (`all/jpeg/png/heif/raw/gif/mov/mp4/avi`) matches on file **extension** (RAW
covers the common camera formats: DNG, CR2/CR3, NEF, ARW, RAF, RW2, ORF, …). Applied in
`FolderView.filtered` via `applyFormat` (hides subfolders while active), so it works across
normal/search/age/label views. It's added to the filter menu next to "Type", to the Clear
action, the "filters active" checks, and the empty-state ("No matches for this filter").

---

## 7. Downloaders (from the broader project + this session)

The app has several **download-only, opt-in** importers. All are best-effort, `nonisolated`,
and treat reverse-engineered protocols as fragile (failures surface as notes, never crashes).

### 7.1 Link downloader — `LinkDownloadService.swift`
Paste an album/file link; the host picks a resolver → list of direct media URLs → streamed to
disk byte-for-byte (EXIF/HDR preserved). Hosts: pixeldrain, gofile, cyberdrop, **bunkr family**,
pixl (Chevereto), plus a generic scraper.
- **Cloudflare 522 handling (this session):** 522 ("origin timed out") and the other transient
  codes (408/425/429, 5xx, 520–524) now retry with **exponential backoff + jitter** (up to 5
  attempts), honoring `Retry-After`. `isTransient(_:)` classifies them. Scrape/generic hosts use
  a gentler concurrency (6) than the clean APIs (12) to avoid amplifying origin timeouts.
- **bunkr family** = bunkr + `turbo.` + `goonbox` + `cuckcapital` (`isBunkrFamily`). These route
  through the **WebKit** downloader below (their CDN fingerprints the client and 403s non-browser
  requests).

### 7.2 bunkr WebKit downloader — `BunkrWebDownloader.swift`
Downloads each file through a `WKWebView` (the only client whose TLS/HTTP fingerprint clears
bunkr's DDoS-Guard CDN): load the file's hub page, click bunkr's own Download control so its JS
mints an authorized CDN URL in-session, capture via `WKDownload`. Includes a visible
"unlock" browser step and a **transient-retry pass** (522/timeout/5xx retried across passes;
403/challenge/empty are terminal). `bunkrTestCap` is now effectively unlimited (was a diagnostic
cap of 3).

### 7.3 MEGA — `MegaDownloader.swift` / `MegaCrypto.swift`
Pure-Swift MEGA folder-link downloader (no SDK). Hardened for: **discovery** (a `k` node field
can carry multiple `handle:key` pairs — try all, validate via attribute decryption, so folders of
N don't under-report as N-2), per-file **retry** (`downloadFileWithRetry`, range/whole fetch
retries), a **two-pass gap-fill** and disk-truth final counts (was stopping ~95%), **EXIF/date
preservation** (`applyFileDate`), and higher concurrency. Everything is off-main; AES ECB/CBC/CTR
via CommonCrypto (bridging header), which CryptoKit can't do.

### 7.4 Instagram / Facebook — `InstagramService.swift` / `FacebookService.swift`
If an account is **public**, downloads without using the user's cookie. Meta anti-automation
mitigations: human-like pacing/headers while still downloading reasonably fast.

### 7.5 In-app browser downloads — `WebBrowserView.swift`
Long-press to save; `bestImgSrc` prefers the anchor's (base-aware) href so it grabs the full-size
image behind a thumbnail; captures the blog post **date** and keeps it with the photo
(`precedingDate`/`dateForImageURL`/`parseCaptureDate`; lightbox/fancybox handling).

---

## 8. Cross-cutting concurrency & sessions

- **AI**: dedicated `apiSession`/`downloadSession`; result images downsampled off-main; uploads
  at `.utility` (see 1.1, 1.9).
- **Directory reads / scans**: coordinated + lazy for large folders (see 3).
- General rule (from `CLAUDE.md`): heavy I/O runs `nonisolated`/`Task.detached`; bounded fan-out
  (`maxConcurrent` task-group pattern); never block the main actor on a slow external drive.

---

## 9. Hard-won constraints discovered in this work (add to the list in CLAUDE.md mentally)

1. **exFAT/iOS: never stat every file up front.** For folders with tens of thousands of entries,
   a per-file `resourceValues` loop before painting hangs the grid; the Files app is lazy. Build
   large folders from the enumeration and defer per-file metadata (3.2).
2. **`NSFileCoordinator` coordinated reads** are needed to see another app's changes on an
   external volume, but pair them with plain/enumerator/POSIX fallbacks (3.1).
3. **`opendir` errno on the iOS file provider is not diagnostic** (returns EINVAL for valid
   folders). Judge readability by `FileManager`, not POSIX.
4. **exFAT copies from macOS**: finish the copy → `sync` → **eject** before unplugging, or the
   directory table isn't flushed and iOS reads stale/partial. macOS also writes `._` AppleDouble
   sidecars (count/inflate directories; hidden by the app but they matter for entry counts).
5. **Astria**: LoRAs are architecture-specific (Flux only composes Flux LoRAs); partner models
   are FaceID-only (~3 images); `prompt[resolution]` is Flux-incompatible; LoRA/PTI tunes require
   `"<token> <class>"` in the prompt; FaceID tunes reject a token (1.4, 1.6).
6. **Local notifications** can't be posted while suspended — use a time-triggered fallback for
   long jobs (1.10).

---

## 10. Where to look (quick index)

| Area | Files |
|---|---|
| Astria client/config/generation | `AIExtend.swift` |
| AI pickers / tune-base model | `AIGenerators.swift` |
| Edit / Create with AI UIs | `AIEditView.swift`, `AICreateView.swift` |
| Create a tune | `CreateTuneView.swift` |
| AI results review | `AIResultsView.swift` |
| AI live activity / notifications | `AILiveActivity.swift` |
| AI jobs, durability, state | `Library.swift` |
| Find duplicates | `DuplicatesView.swift`, `PerceptualHash.swift` |
| Storage / Drive Health | `StorageView.swift`, `DriveHealthView.swift` |
| Directory reading / large folders | `Library.swift` (`coordinatedContents`, `listing`) |
| Folder filters | `Models.swift` (`FormatFilter`), `FolderView.swift` |
| Downloaders | `LinkDownloadService.swift`, `BunkrWebDownloader.swift`, `MegaDownloader.swift`, `InstagramService.swift`, `FacebookService.swift`, `WebBrowserView.swift` |
