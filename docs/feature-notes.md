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

- **`AIModel`** (`seedream5Pro`, `seedream5Lite`, `seedream45`, `nanoBanana2`, `flux`):
  - `partnerModels` = the four closed gallery models. Used in Settings (default-model picker,
    tune-id overrides) which must **exclude Flux** (Flux has its own "Flux (extend)" tune field).
  - `composesLoRA` is true only for `.flux` — Flux is the only base that can run a user LoRA
    composed into the prompt via `<lora:id:weight>`.
  - `tuneID(for:)` maps a model to its Astria gallery tune id (editable in Settings; Flux
    shares the single editable Flux tune). Fallbacks: 5.0 Pro 5236038, **5.0 Lite 4160332**
    (from its public gallery URL), **4.5 3691308** (the id the app shipped with before 4.5 was
    dropped — now back), Nano Banana 2 4180298. "Nano Banana Pro" stays removed.
  - **`maxReferenceImages`**: 14 for Seedream 4.5 / 5.0 Lite / Nano Banana 2, 10 for Seedream
    5.0 Pro, 0 for Flux. Extra photos the model draws on, sent as repeated
    **`AIExtend.referenceImageField`** (`prompt[image_references][]`) multipart parts after
    `prompt[input_image]`. Astria documents that field (and "model-specific limits apply") for
    its video models and lists the image models' reference counts in its changelog without
    naming the field, so this is a best-supported guess — if Astria answers with a validation
    error naming it, change the constant.
  - **Reference picker UI** (`AIGenerators.swift`): `ReferenceImagesPicker` (grid of the
    current folder's photos, numbered in pick order, capped at the model's limit; the Edit flow
    excludes its source photo), `ReferenceImagesStrip` (chosen thumbnails with ✕) and
    `ReferenceThumb`. Both Create and Edit show a "References" section under Model & Tunes;
    switching to a model with a smaller limit keeps the first N. `RunSettings.referencePaths`
    remembers them (missing files dropped on restore). `Library.encodeReferences` JPEG-encodes
    them off-main (≤ 2048 px, 4 at a time) and `startAIEdit`/`startAICreate` pass them to
    `generate(referenceImages:)`. `TuneBaseModel` offers the two new Seedreams as FaceID bases.

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
  `AIProgressActivity` live activity and completion notification. `beginAIJob` marks the job
  live in `activeAIJobIDs`; `deliverAIResult` is the single completion path for both flows.
- **Durability:** the moment Astria accepts a prompt, `onPrompt` (built by `pendingRecorder`)
  persists a `PendingAstriaJob` (jobID, promptID, tune, paths, prompt, model, startedAt, plus
  `count`, `isCreate`, `attempts` — optional, so older records still decode) to
  `photoBrowser.pendingAstria`. **Both** Edit and Create are recorded (Create used not to be —
  a Create job killed mid-generation was simply lost).
- **Recovery — `resumePendingAIEdits()`** re-polls each record and saves the images straight into
  the "AI" folder (there's no review session to hand them to after a relaunch), then posts the
  ready alert (tap → that folder). It runs at **launch, on every return to the foreground, on a
  notification tap, and once ~1 min after an in-process failure** — the old launch-only pass left
  a job stranded until the next cold start whenever the app was merely suspended. It skips jobs
  in `activeAIJobIDs` (live in this process) and `recoveringAIJobIDs` (a pass already running),
  so nothing is ever double-polled or double-saved.
- **Recovery is quiet and bounded** (the "it keeps retrying hours later and the pop-up is
  annoying" fix). The only thing a pass may announce is success. Every other outcome — prompt not
  done, offline, drive unplugged, Astria failed the prompt, job abandoned — is **silent**: no
  alert, no `activityResults` pop-up. Limits, all in `Library`: a pass per job at most every
  `aiRecoveryCooldown` (10 min; `lastAttemptAt` on the record), **every pass counts** toward
  `maxAIRecoveryAttempts` (4) — including "images arrived but couldn't be written", which before
  retried every 2 min for 6 h with an alert each time — each pass polls at most
  `aiRecoveryPollTicks` (30 ≈ 90 s; `resumePrompt(maxTicks:)`) instead of 25 min, a job older than
  `maxAIJobAge` (2 h) is dropped unexamined, a job whose folder isn't reachable (drive away) is
  skipped without spending a pass or showing a pill, and **a pass never schedules another pass**.
  The attempt is counted *before* the poll so a kill mid-pass still counts. Settings → "AI jobs in
  progress" shows `pendingAIJobCount` with **Stop Waiting for Them** (`cancelPendingAIJobs`): the
  user's off switch. Nothing is lost by dropping a job — whatever Astria made is in the account and
  in the Astria.ai Browser.
- **Failure semantics** (`AIExtend.AIError`): `.timedOut` / `.network` mean "our wait ended,
  Astria may still deliver" → the record is **kept** and recovery takes over (the user is told the
  images will land in the "AI" folder, not "failed"). `.generationFailed` (Astria reported the
  prompt failed, e.g. moderation) and `.server` (request rejected) are terminal → record dropped.
- **Presentation — `ModalPresenter.swift`:** results (and the creator reopened after review) are
  presented with UIKit on the **top-most** view controller, not via a `.sheet` on `ContentView`.
  A root-view sheet silently failed to appear whenever the viewer's full-screen cover (or any
  modal) was up — exactly when most edits are started and finish — which stranded finished images
  in memory. The presenter retries on a short timer while the top controller is mid-transition or
  is an alert, so a presentation is delayed, never dropped. `ContentView` no longer observes an
  `aiResultPresentation`/`aiCreatorReopen`; the viewer no longer tears itself down for results.
- **`AIResultsView`** — Keep/Delete review of each result. `AISaveTarget` is `.edit(original:)`
  (saves into an "AI" subfolder beside the source, inheriting EXIF/date) or `.create(folder:)`.
  Results are **decoded downsampled OFF the main thread** via ImageIO (`downsample`,
  `maxPixel 1400`) so reviewing a batch of up to-4K images doesn't hitch; the full-res `Data`
  is still what gets saved. An optional `note` ("Astria returned 3 of 4 images") is shown when a
  batch came back short. After finishing, `reopenCreator(after:)` reopens the creator with the
  same settings.
- Upload encodes (`uploadJPEG`) run at **`.utility`** priority (CPU-heavy tone-map/JPEG must
  yield to scrolling when several edits run at once).

### 1.9a The Astria request path (speed + consistency): `AIExtend.swift`

Every item here was a real symptom ("no results", "partial results"):

- **`createPrompt`** — the prompt POST retries **safe** transient failures (429/5xx/52x, or a
  connection that never got established: `isPreSendFailure`) with backoff + jitter honouring
  `Retry-After`. An **ambiguous** failure (timeout / connection lost after the upload may have
  landed) is reconciled via `findRecentPrompt` — list the tune's newest prompts, adopt the one
  with our exact text created since we started — so a prompt Astria created but whose response
  we never saw is still polled instead of orphaned. Only a definitive "not found" allows a
  re-POST; a listing failure returns `.network` rather than risk a duplicate (billed) prompt.
- **Progressive `images`.** Astria fills a prompt's `images` array **one at a time**; the old
  "first non-empty array wins" returned partial batches. `downloadPromptImages` waits for
  `expected` (`num_images` — from the request, or the prompt itself on recovery) and only accepts
  fewer once the list has stopped growing for `stableTicks` (20) polls.
- **Downloads start the moment each URL appears** (a task group fed from inside the poll loop),
  overlapping fetches with the rest of the generation. Each download **retries** (3×) and is
  validated with ImageIO (`downloadImage`) — an error page or a fetch truncated by suspension is
  never saved as a "result".
- **Poll budget is counted in polls, not wall-clock** (`maxTicks` 320 at an adaptive 2s→4s→6s
  cadence ≈ 25 min active), so a suspended app resumes where it left off instead of "timing out"
  on return. The old cap (130 × 3 s ≈ 6.5 min) was routinely exceeded by Seedream 5.0 Pro at 4K.
- A prompt-level `error` from Astria (with no images) → `.generationFailed(message)`.
- Both sessions cap `timeoutIntervalForResource`: with `waitsForConnectivity` on, a request made
  while offline otherwise waits up to the default *week* for connectivity, pinning a job.
- `heartbeat(ready, expected)` fires every poll tick → the pill shows "2 of 4 images ready —
  downloading…" and the fallback alert is re-armed (see 1.10).

### 1.10 Completion notifications: `AILiveActivity.swift`

- `AINotifications` installs a retained `ForegroundPresenter` (`UNUserNotificationCenterDelegate`)
  **at launch** so alerts appear even while the app is foregrounded, and requests authorization
  at launch. Tapping an alert routes `(jobID, folderPath)` via `tapHandler` → `presentAIResult`:
  a job still in memory reopens its results; otherwise (relaunch, or still pending) it navigates to
  the folder's "AI" subfolder and kicks a recovery pass — previously an unknown id did nothing,
  which read as "the notification is broken". A tap that *launched* the app arrives before the
  handler is installed and is held in `pendingTap` until it is.
- **Suspended-app reminder (opt-in):** a local alert can only be *posted* while the app runs,
  so a job finishing after iOS suspends the app never notified until reopen. `armFallback` schedules
  a **time-triggered** notification (delivered even while suspended). It is a **dead-man's
  switch**: `heartbeat()` re-arms it (~150 s ahead, throttled to every 30 s) on every poll tick, so
  while the process is alive and polling it never fires; it lands only once the process stopped
  (suspended/killed). Wording: "AI images still in progress — the app was paused… open it to
  finish"; `finish()` cancels it (`notify: false` cancels without posting).
  **It nagged** (a reminder on every app switch, for days) because recovery passes armed it too and
  nothing capped it per job, so now: it is **off by default** (Settings → "Remind me if the app is
  paused mid-generation", `AINotifications.pauseRemindersEnabled`); only a job started in this
  session arms it — `resumePendingAIEdits` never does; it fires **at most once per job**
  (`reminderAlreadyFired`: the scheduled due time is persisted and, once past, the job is done
  reminding); stale scheduled reminders are removed at launch (`clearStaleReminders`); and a job
  older than `maxAIJobAge` (2 h) is dropped as stuck instead of being re-polled for 48 h. (True
  "server pushed the instant it's done" delivery would need a push server or a BackgroundTasks
  capability — not added.)

### 1.9b Results survive the review — record lifetime

The recovery record is **not** dropped when the images arrive; it stays until the review sheet
finishes (`AIResultsView.finish` → `Library.aiReviewFinished`). The job also stays in
`activeAIJobIDs` and `aiJobsUnderReview` meanwhile, so a foreground recovery pass never re-saves
what's on screen and a notification tap never stacks a second sheet. If the process is killed with
results on screen (or before they were shown), the next pass re-fetches them from Astria and saves
them to the "AI" folder. `downloadPromptImages` also runs a **second sweep** for any image the first
pass lost, against URLs re-read from the prompt (result URLs are signed and can expire).

### 1.12 Astria.ai Browser — `AstriaBrowserView.swift`

Folder menu → **"Astria.ai Browser…"** (full-screen cover, `currentFolder` = the folder it was
opened from). Lists **every** prompt on the account newest first (`AIExtend.listPrompts`: the
cross-tune `/prompts` listing, offset-paginated; if that endpoint fails it's assembled per tune —
gallery models the app uses + the account's tunes — so the browser is never empty because one
endpoint changed), grouped by prompt with model name (`modelName(forTune:tunes:)`), date and text.

- **Thumbnails**: `AstriaImageCache` (all `nonisolated`) — memory `NSCache` + disk
  (Caches/`astriaThumbs`, SHA-256 of the image URL, ≤ 480 px JPEG); full images cached in memory
  by cost. Downloads go through `AIExtend.downloadImage` (retries + ImageIO validation). The disk
  cache is listed/clearable in Storage.
- **Search**: a `.searchable` field (always shown) filters prompts by free text — every typed word
  must appear in the prompt text or the model/tune name, case-insensitively, in any order
  (`filteredPrompts`); the grid, selection and Save-all follow the filtered set, and a line above
  the grid reports how many prompts/images match.
- **Preview** (`AstriaImagePreview`): full-size decode at ≤ 2200 px off-main, prompt/date/model,
  Copy Prompt, and the two save buttons.
- **Saving**: single (preview / context menu) or **Select** + per-prompt Select All → bottom bar.
  Destination is either **"Save to “<last folder>”"** (one tap; `Library.astriaSaveFolder`,
  persisted under `photoBrowser.astriaBrowser.lastFolder` and set on every save) or **"Save to
  Folder…"** (`FolderPicker`, opened at the remembered folder, else the current folder). Files are
  written **directly into the chosen folder** (`saveGeneratedToFolder(… intoAISubfolder: false)`)
  stamped with the prompt's `created_at` and provenance, marked AI-generated, and remembered in
  `Library.astriaSavedImages` (image URL → path) so the grid badges what's already on the drive.

### 1.11 Reusable Prompts, prompt history with hearts, prompting reminder — `AIPromptSections.swift`

The prompt-helper sections are shared views (one file) used by both `AICreateView` and
`AIEditView`, in this order under the prompt box: `PromptingReminderSection`,
`ReusablePromptsSection`, `PromptHistorySection`.

- **Prompting reminder** — one fine-print row (`.caption2`, secondary, lightbulb) right under the
  prompt: "Order: subject → wardrobe → scene → framing (crop and camera position) → camera details
  (natural sensor noise, slight handheld imperfections, subtle HDR). Add imperfection keywords;
  ban beauty filters for realistic, non-plasticky skin." (`PromptingReminderSection.text`).
- `AIExtend.reusablePrompts: [String]` — a shared list surfaced as **"Reusable Prompts"** with
  one-tap **Use** (fills the prompt field) and **Copy** (UIPasteboard). Extend by appending to
  the array; both views update. Currently: the 8-heads-tall full-body portrait, and the
  braided-hair description ("long hair with a soft center part … three-strand braid draped over
  the right shoulder …"). The Use/Copy pair is `PromptActionButtons`: **plain-style buttons with
  explicit capsule padding, centred** — the stock `.borderedProminent` inside a Form row rendered
  Use as a tall, off-centre block.
- **Prompt history with hearts** — `Library.favoriteAIPrompts` (`photoBrowser.aiPromptFavorites`,
  a subset of `aiPromptHistory`; `isFavoriteAIPrompt` / `toggleFavoriteAIPrompt`). Each history
  row has a ♥ button (and Favorite/Unfavorite in its context menu); a segmented **All /
  Favorites** filter at the top of the section shows only hearted prompts. Hearted prompts are
  **never evicted** by the 50-prompt cap (`recordAIPrompt` drops the oldest unhearted ones), a
  re-run under different casing keeps its heart, and "Remove from History" also unhearts.

### 1.11a Negative Prompt

- A **"Negative Prompt" switch** (`NegativePromptField`, in `AIEditView.swift`) sits directly
  under the prompt box in both Edit and Create. On, it reveals a text field. On Generate the text
  is appended to the prompt **as free text** — the user's prompt, a blank line, then
  `Negative Prompt: <text>` (`AIExtend.composePrompt(_:negative:)`) — because the partner models
  (Seedream, Nano) have no separate negative field. Example of what Astria receives:
  "A cinematic photo of a man carrying an umbrella in the dark.⏎⏎Negative Prompt: light, woman,
  no umbrella." Off (or blank), the prompt is sent untouched; the text is kept for next time.
- Plumbing: `startAIEdit`/`startAICreate` take `negativePrompt: String?`; the **history** records
  the bare prompt (so reusing a past prompt never drags "Negative Prompt:" into the field), while
  the job's `prompt` — and therefore the saved files' provenance — is the full text sent. The
  `<lora:…>` prefix still goes in front of everything. `RunSettings` remembers `negativeEnabled`
  and `negativePrompt` per flow (lenient-decoded like the rest).

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
- Rows show count, size · dimensions · **file type(s)**, a colored kind badge, a › that opens
  Compare (`navigationDestination(item:)`), and **every file of the group as a tile**. Tapping a
  tile ticks that specific copy for deletion (red ring + trash badge); the bottom bar's **"Delete
  Selected (N)"** removes exactly the ticked files behind a confirmation. There is deliberately
  **no "keep the largest" bulk delete** — the user chooses which copy goes. `toggle` refuses to
  tick the last unticked file of a group, so one file per group always survives. **Not
  Duplicates** is a swipe action / context-menu item on the row (`library.markNotDuplicates`).
- **Oldest / Newest markers**: `DuplicatesView.loadCaptureDates` reads a **millisecond-precise**
  date for every file in the result off-main (`preciseDate`: `DuplicateDetection.readFacts` →
  EXIF `DateTimeOriginal` + `SubSecTimeOriginal` as a decimal fraction; file mtime as fallback,
  which also carries fractions). The whole-second capture-date cache is deliberately not used —
  burst shots and re-saves differ only in sub-seconds. Each row's `ages` marks the oldest tile
  (orange "Oldest") and newest (cyan "Newest") when the spread is ≥ 1 ms, and the tiles then show
  the day plus `HH:mm:ss.SSS` instead of the size.
- **Full-size viewing**: tapping a tile's picture (or a column thumbnail in Compare) opens the
  group's files in the normal `ViewerView` (`DuplicateViewerPresentation`, a nested
  `fullScreenCover`) starting at that file, so the copies can be swiped between and zoomed. The
  tick circle and the caption are separate buttons, so a tap never does the other thing. On
  dismiss, `pruneMissingFiles` drops anything the viewer deleted/moved from the groups and the
  remembered result.
- **Multi-select has full rein**: any number of a group's files can be ticked, including all of
  them (`toggle` no longer keeps one); the confirmation says how many groups would lose every
  copy. The row's context menu adds "Select All Copies" / "Deselect Group".
- **"Leave out “Frame” files"** toggle (`@AppStorage photoBrowser.duplicatesExcludeFrames`):
  video-frame screenshots are hundreds of visually similar, never-duplicate images. On, frame
  files are dropped from the scan itself (no hashing) *and* filtered out of remembered results
  (`withoutFrames`; a group left with one file disappears). Turning it off reloads: the
  remembered fingerprint keeps the skipped files' entries so this doesn't read as "new files"
  unless the frames were never scanned, in which case it rescans.
- **Results are remembered** — `DuplicateScanCache` (one JSON per folder in Application
  Support/`duplicateScans`, listed in Storage): the groups as paths plus a `size|mtime`
  fingerprint of every file the scan covered. On open, `load(force:false)` lists the folder and
  compares fingerprints: if no file is new or changed, the stored groups are rebuilt against the
  current listing (vanished files drop out, dismissed pairs are skipped) and shown instantly;
  otherwise a full scan runs. Deleting, renaming (Compare's `onRename` keeps the file in its
  groups under the new name) and Not Duplicates all update the record in place (`persist()`), so
  nothing re-scans until files actually change or the user taps ↻ Rescan. `.task(id: folder)` is
  guarded by `loaded`, so returning from Compare never triggers a scan either.
- **Compare view** (`DuplicateCompareView`): side-by-side of two items with a same/different
  metadata breakdown, per-item edit menu (rename/date/caption/labels), per-side delete, a
  **"Delete files" multi-select checklist** (tick several, delete together), and "Not Duplicates".
- Deletions re-key labels/origins (`clearLabels`/`clearOrigins`) and call `contentDidChange()`.

## 2a. Compare PNGs — `PNGMatchesView.swift` (+ `PNGMatching`, `PNGMatchScanCache`)

Folder menu → Maintenance → **Compare PNGs**. Built to look and work like Find Duplicates, but
asks one narrower question: *which PNGs here are another photo in this folder?* Every group has at
least one PNG; two JPEGs are never compared (that's Find Duplicates).

Rules — `PNGMatching`, a `nonisolated enum` of **pure** functions over `Candidate` values
(url, isPNG, isFrame, nameKey, aspect, hash), unit-tested in `PhotoBrowserTests/PNGMatchingTests.swift`:
- **Same name** (`Reason.name`): `nameKey` = lowercased, extension off, " (1)" / " copy N" stripped
  (numbers in the name are *kept* — `Frame 97` must not become `Frame`). `similarNames` = keys
  equal, or one is the other plus `_`/`-` + a tag that contains a letter (`img_2225_402c6dbe`,
  `frame 97_xhdn3`) or is ≤ 2 digits (`img_2225_1`). A bare space is **not** a separator and an
  all-digit tag of 3+ digits is **not** a match, so `Frame` ↔ `Frame 97` and `frame 9` ↔ `frame 97`
  stay apart.
- **Look alike** (`Reason.visual`): `PerceptualHash` dHash distance ≤ `maxHashDistance` (7) **and**
  aspect ratios within 1% (unknown aspect never blocks). Hashes come from the shared persistent
  `DuplicateDetection.HashCache` (`name|size|mtime`), so a folder is hashed once across this
  screen and the move/copy dedupe.
- **"Frame" files** (name contains "frame", any case) are **name-only, PNG-to-PNG**: never hashed
  (not even opened with ImageIO — `candidate(for:)` returns before `readFacts`), never paired with
  a JPEG/HEIC, never paired with a non-frame PNG by look. This is the user's rule: a folder of
  frames from one video is hundreds of look-alike, not-the-same images.
- `pairs` iterates PNGs × files (not files²); `cluster` is union-find with reasons merged per
  cluster. Dismissed pairs are filtered **on the main actor** between `pairs` and `cluster`
  (`Library.areNotDuplicates` — the same store as Find Duplicates, so "Not the Same Photo" here
  and "Not Duplicates" there agree).

UI (`PNGMatchesView`, full-screen cover from `FolderView.showPNGMatches`):
- Segmented filter All / Same name / Look alike. Rows: "IMG_2225.png ↔ IMG_2225.jpg" (or "↔ N
  photos"), count · types, a colored kind badge (green = both reasons, orange = name, blue = look),
  › to Compare, and every file as a tile with an extension capsule (purple PNG / grey other).
- **Tap the picture** → the group's files in `ViewerView` (swipe between, zoom); **tap the circle /
  caption** → tick; **long-press the picture** → Hide File / Unhide File, Mark for Deletion.
  Bottom bar: Clear · **Hide (N)** · **Delete (N)** (delete behind a confirmation that says how
  many groups lose every file). Swipe / context menu → **Not the Same** (`markNotDuplicates`),
  Select All in Group / Deselect Group.
- **Hide** = the app's existing per-file hide (`Library.setFileHidden`): the file leaves the grid
  (unless Show Hidden Items) and leaves future scans here, but stays on the drive. Within the
  visit the tile stays, dimmed with an eye-slash "Hidden" badge, so the choice can be undone.
  Deleting a hidden file clears its hidden mark. Hidden files are excluded from the scan
  (`!library.isHiddenFile`), which is how a pair settled by hiding stays settled.
- Compare reuses `DuplicateCompareView` (made internal, with a `dismissLabel` parameter — "Not the
  Same Photo" here) via `PNGMatchGroup.asDuplicateGroup`; its Edit menu gained **Hide File /
  Unhide File** (so Find Duplicates has it too). Renames flow back through `onRename` and keep
  the file in its group under the new name.
- **Remembered results** — `PNGMatchScanCache` (Application Support/`pngMatchScans`, listed in
  Storage as "PNG comparison results"), identical in shape and logic to `DuplicateScanCache`:
  groups as paths + a `size|mtime` fingerprint of every candidate; on open, if nothing is new or
  changed the record is rebuilt against the current listing (gone/hidden files drop out, dismissed
  groups skipped, groups left with one file or no PNG vanish) and shown instantly; the fingerprint
  keeps entries for files now hidden so unhiding one doesn't read as "new". Delete / hide / rename
  / Not the Same update the record in place. `.task(id:)` is `loaded`-guarded; ↻ forces a rescan.
- Scan work (ImageIO property reads + hashing) runs in a detached task with fan-out 8, and the
  hash cache is flushed once at the end of the scan.

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

## 4. Drive Health — `DriveHealthView.swift`, `DriveRepair.swift`, `MetadataSnapshot.swift` (Settings → Maintenance)

Recursively scans the SSD and flags **unreadable folders**, **unreadable files** (attributes
won't stat), **empty (0-byte) media** (the hallmark of an interrupted exFAT copy) and — with the
**"Also check file contents"** toggle (`photoBrowser.driveHealthDeepCheck`) — **files with no
data** (first 16 bytes all zero: exFAT allocated the size, the copy never landed) and **contents
that don't match the extension** (magic-number check for JPEG/PNG/GIF/HEIC/MP4/MOV/WebP/TIFF-RAW;
flagged yellow as "often just mislabelled"). `DriveRepair.probeHeader` does the 16-byte read;
probes fan out 8 at a time per folder.
- Uses the same `coordinatedContents` chain; a folder is only flagged after retries with
  backoff (external drives **throttle** a fast full-tree walk, and a single transient failure
  must not be reported as corruption — an early over-aggressive version cried wolf on 223
  perfectly-good folders).
- Captures the real error (`NSCocoaError` domain/code + `opendir` errno) into the row for
  diagnosis. (Field lesson: `opendir` returning `errno 22 (EINVAL)` here was a **red herring** —
  POSIX doesn't work on this provider; the true signal was directory *size*, see 3.2.)
- The scan returns a `ScanResult`: issues, folder/file counts (shown live while scanning), the
  set of **every path seen**, a **name → paths** table and the unreadable-folder list — so the
  metadata audit below needs no second walk. `complete` is false if the 200k-folder safety bound
  stopped it (the audit is then skipped rather than crying orphan).
- **Share button** exports the unreadable-folder paths (drive-relative, shallowest-first) as
  text, for a Mac-side rebuild/split script.

### 4.1 Metadata safety (the "fixing a drive must keep everything" rules)

The app's metadata is keyed by **absolute path**, so a fix that keeps names and places loses
nothing, and a fix that doesn't needs help. Three layers now guarantee it:

1. **Every store follows every move.** `Library.applyRemap` (in-app moves/renames, remounts)
   and the new shared `transferMetadata` behind `migrateMetadata` (cross-drive move, "Re-link
   Favorites from a Drive…") and `duplicateMetadata` (backup copy) cover the **whole** list:
   Favorites, To AI, custom labels, captions, covers, custom item thumbnails, Photos origins,
   birthdays, hidden folders/files, frames / reviews / Kardashian / highlight folders, bubble
   order, Instagram / Facebook / TikTok / VSCO / **OF** profile records and their last-handle
   prefills, Facebook URL prefill, likes, posted-by, story links, Messages archives, AI
   provenance (`aiGenerated`, `aiGenerations`, `editedInApp`), Clean Up progress,
   Not-Duplicates pairs, People faces (+ `FaceStore`), Access Kardashian state. Before this
   audit `migrateMetadata` carried only seven of these (a drive-to-drive move dropped every
   linked profile), and `applyRemap` missed OF records, OF/Facebook prefills and Messages
   archives. `persistAllMetadataNow()` writes everything at once (used by restore).
2. **Backup / restore — `MetadataSnapshot`.** `Library.makeMetadataSnapshot(root:)` serialises
   every store with **drive-relative** keys (so a reformat, rename, re-copy or reinstall that
   changes the mount path still matches); `MetadataBackup.write` stores `metadata.json` plus
   copies of the referenced cover / thumbnail / Messages-archive files, into the app container
   (Application Support/`metadataBackups/<timestamp>`, last three kept, listed in Storage) and,
   on request, into **`.Photo Browser Metadata/` at the drive root** (dot-prefixed: invisible to
   every listing and scan; travels with the photos). `restoreMetadata` **merges**: adds what's
   missing under the current root, never overwrites, copies image files in by their UUID names.
   Drive Health → "Metadata safety" shows both backup dates with Back Up / Restore buttons; a
   Rebuild takes an automatic container backup first.
3. **Orphan audit + Re-link by Filename.** After a scan, `Library.metadataPaths(under:)` is
   checked against the paths seen; entries whose item is gone are listed by `MetadataCategory`
   ("Metadata pointing at missing items"). Paths under unreadable folders are *unknown*, not
   orphaned. **Re-link by Filename** finds each missing name elsewhere on the drive and, for a
   unique match (preferring the same parent-folder name), re-keys it through
   `Library.itemsMoved` — the exact machinery an in-app move uses, so all stores follow. Nothing
   is ever deleted; ambiguous and unmatched names are counted and left alone.

### 4.2 Rebuild Folder in place — `DriveRepair.rebuildFolder`

Swipe an unreadable folder → **Rebuild**. The folder is inventoried through the full fallback
chain (coordinated → plain → enumerator → POSIX; a tree that can't be listed at all is refused
with a "re-copy from the Mac, keep the name and place" message), free space for a second copy is
checked, every file is copied into a hidden sibling `.<name>.rebuilding` with its **modification
date carried over** (keeps the `path|mtime|size` caches warm) and verified by size, and only if
*every* item copied are the two swapped: original → `<name>.damaged` (parked, never deleted),
rebuilt → the original's exact name and path. **The path never changes, so every piece of
metadata stays attached with no re-keying at all.** Parked originals show up in later scans as
"Parked originals from rebuilds" with a confirmed Delete. Any failure removes the temp copy and
leaves the original exactly as it was.

- Bad files can be deleted in place; unreadable folders get Rebuild or the re-copy guidance
  (same name, same place, clean eject).

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

## 5a. Folder Birthdays mapping — `BirthdayMappingView.swift` (Settings → Library)

One screen mapping every **top-level folder** (`library.subfolders(of: root)`) to a birthday.
Edits are **staged** in a `draft` dictionary and written together on Save via
`Library.setBirthdays(_:)` (one UserDefaults write + one `labelsVersion`/`changeToken` bump —
`setBirthday(_:for:)` now delegates to it). Rows: inline compact `DatePicker` (or "Add"), swipe to
Clear / Revert, an unsaved dot; filters All / Missing / Set + search; Cancel confirms discarding.
Bulk tools:
- **Paste a List of Birthdays…** (`BirthdayTextImportView`): one folder per line; the date is
  found anywhere in the line (a hand-parsed ISO `yyyy-mm-dd` first, then `NSDataDetector` for
  numeric / written-out forms), the rest is the name, matched case-insensitively to a folder —
  exact, else a *unique* prefix/containment match. A name with no date **clears** that folder.
  Shows matched/unmatched before "Use N".
- **Copy Mapping as Text**: `Name = yyyy-MM-dd` per folder (blank when unset) to the clipboard,
  in list order — the same shape the importer reads, so the whole mapping round-trips through
  Notes.
- **Clear All Birthdays** (staged, confirmed).

## 5c. Pure File Transfer mode — `Library.pureTransferMode`

A switch on the pre-drive screens (`EmptyState`, `WaitingForDrive` → `PureTransferToggle` in
`ContentView.swift`) and in Settings, persisted under `photoBrowser.pureTransfer`. Its purpose:
use the app as a plain conduit for moving files from this phone onto the exFAT SSD, leaving
nothing behind on the phone and nothing else in the way.

- **Thumbnails are memory-only**: `Thumbnailer.diskCacheEnabled` (set by
  `Library.applyPureTransferMode`, also at launch) skips the Application Support read/write and the
  legacy-key adoption in `produce`. Tiles still render — the grid, the pickers and duplicate
  review need them — they just aren't persisted.
- **Hidden UI** (all behind `if !library.pureTransferMode`): the toolbar Safari button, "Import Your
  Text Messages", the whole "Download from the Web…" submenu, Create with AI / Astria.ai Browser /
  Create AI Tune, People / Places / On This Day, Cache All Thumbnails, the text and location
  indexers; the pixel editors in the item context menu (Crop & Rotate, Edit Photo, Resize/Extend,
  Edit with AI, AI Upscale), in the selection bar (Rotate, Rotate preview, Edits, Upscale Video,
  AI Upscale Photos, Export Frames, Extract Audio, Combine Videos, Make Live Photo) and in the
  viewer menu.
- **Kept**: browsing, select, Move/Copy (with duplicate detection), rename, delete, New Folder,
  Get Info, Edit Metadata, captions, Favorites/labels, Save to Photos/Files, Add from iOS Album /
  Photos Library, Drives & Backup, Recently Deleted, Find Duplicates, Restore Capture Dates,
  Check if on iPhone, Clean Up, Settings.
- **No background jobs**: `PhotoBrowserApp` skips `refreshPendingShares`, `resumePendingAIEdits`
  and `processPendingTikTok` at launch and on foreground while the mode is on.

## 5b. Move/copy duplicate detection — `DuplicateDetection.swift`, `FileActions.moveItems/copyItems`

Before each photo is written into a destination folder, `FileActions.moveItems` / `copyItems`
(the batch paths behind the grid's Move/Copy and the viewer's) ask `DuplicateDetection.plan` what
to do; everything the rules don't touch (videos, unmatched files, same-name-different-picture)
follows the pre-existing path verbatim. Callers opt out with `detectDuplicates: false`.

- **Same photo** (`samePhoto`, all must hold): aspect within 1% either orientation; capture date
  equal to the second when both have one (sub-second too when both carry it); make/model equal and
  exposure/f-number/focal/ISO within 5% when both have them; dHash Hamming ≤ 8. A side that can't
  be hashed downgrades to `.same(verified: false)` and is logged as unverified. Name alone never
  matches. Capture date is EXIF `DateTimeOriginal` → `DateTimeDigitized` → TIFF `DateTime` via
  ImageIO with `kCGImageSourceShouldCache: false` — never the file's mtime.
- **Stem**: name minus extension, lowercased; PNGs also lose a trailing `_` + 6–12 hex chars
  (upscaler suffix).
- **Rules** (`plan(incoming:candidates:)`, pure, unit-tested): A — incoming ORIGINAL vs existing
  ORIGINAL: same byte size and not newer → existing to `DUPLICATES/`, incoming takes its place;
  else incoming to `DUPLICATES/`. B — incoming ORIGINAL vs PNG(s): incoming goes in, every
  matching PNG to `Duplicate PNGs/` (A before B when both apply). C — passthrough. An incoming
  PNG matching an ORIGINAL → `Duplicate PNGs/`; PNG vs PNG unchanged.
- **Candidates** = destination top-level files with the same stem ∪ same capture second
  (`DestinationIndex`, built **once per batch**, bounded fan-out of 8, off-main; helper folders
  and subfolders are never scanned). Hashes are computed **lazily** only for pairs that already
  pass rules 1–3, through `HashCache` (JSON in Application Support, key `name|size|mtime`).
- **Execution**: `relocateExisting` moves a destination file into the helper folder (created on
  first use, `_1`/`_2`… on clash — `uniqueURL`), `divertIncoming` moves/copies the incoming file
  there, `placeIncoming` is the old code path (collision rules intact). Files are only ever moved
  with `FileManager.moveItem` / cloned-copied — never re-encoded. Outcomes carry `relocated`
  (callers pass them to `library.itemsMoved` so labels follow) and `duplicateLog` (also written to
  the unified log, category "Duplicates").
- Tests: `PhotoBrowserTests/DuplicateDetectionTests.swift` (see its README for adding the target).
- The whole enum is `nonisolated` — it runs inside the batch's detached task.

## 5d. Video delay for CarPlay — `PlaybackSettings`, `VideoPage.swift`

Settings → Playback → **Delay video** (Off / 1 s / 2 s / 3 s, `photoBrowser.videoDelay`). CarPlay
and Bluetooth add audio latency the phone can't measure, so sound trails the picture. With a delay
set, `ZoomableVideoController` plays an `AVMutableComposition` instead of the file: audio tracks
inserted at 0, the video track inserted at `delay` (`delayedItem`), so the picture is held back by
that much and lines up with the late audio. No re-encode, orientation carried over, the first
`delay` seconds are black. The player is created empty and the composition built async (asset
loads must not block the main thread on an external drive); everything that hangs off the item
(looping notification, frame-capture output, pitch, orientation, ready observation) moved into
`attachItem()`, called immediately for a plain file or after `replaceCurrentItem`. Frame capture,
stepping and Slo-Mo all work on the composition item.

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

### 7.4a MPEG-TS → MP4 — `TSRemuxer.swift`

**iOS cannot play a `.ts` file.** AVFoundation has no file-level MPEG-2 transport-stream demuxer
(it only consumes TS inside a live HLS session), so `AVURLAsset` on a `.ts` reports no tracks.
The HLS downloader's old TS→MP4 step was an `AVAssetReader` passthrough — it silently failed on
every TS stream and the download was saved as an unplayable `.ts` (adultdvdempire.com was the
report; passes.com-style TS-HLS was the same). FFmpegKit isn't linked.

`TSRemuxer` is a pure-Swift demuxer feeding `AVAssetWriter` as **passthrough** (no re-encode):
- Walks 188-byte packets (resyncs on a lost boundary), PAT → PMT → PIDs; refuses scrambled
  streams. Video: H.264 (`0x1B`) / HEVC (`0x24`); audio: **AAC/ADTS (`0x0F`) only** — MP3 /
  AC-3 / LATM are noted but not written, so the video still saves (silent) instead of failing.
- Reassembles PES per PID, reads PTS/DTS, unwraps the 33-bit clock (`TSWrap`), re-bases to the
  earliest timestamp and applies a shared **discontinuity offset** when video DTS goes backwards
  or jumps > 10 s, so the writer always sees monotonic DTS.
- Video: Annex-B NALs → 4-byte length-prefixed samples; SPS/PPS(/VPS) collected into the format
  description (`CMVideoFormatDescriptionCreateFromH264/HEVCParameterSets`), AUD/filler/parameter
  NALs stripped from samples, IDR/CRA/BLA marked sync via `kCMSampleAttachmentKey_NotSync`, and
  **nothing is emitted before the first sync frame**. Durations = one-sample look-ahead on DTS.
- Audio: each ADTS frame → one 1024-sample packet; `CMAudioFormatDescriptionCreate` with an
  AudioSpecificConfig cookie built from the ADTS profile/rate/channels. Frames spanning a PES
  boundary are carried over (`audioLeftover`); timing runs from the PES PTS by frame count.
- Three passes over the file: a bounded **probe** (formats + first timestamps), then all video,
  then all audio — same shape as the fMP4 mux (`pump` with the once-only continuation resume).
- Wired in `WebVideoDownloader` (HLS and direct-`.ts` paths) between FFmpegKit and the old
  AVFoundation fallback; a `.ts` that still can't convert is saved with a note.
- **Convert to MP4** (long-press a `.ts`, or select several → More) runs
  `TSRemuxer.convertInPlace`: sibling `.mp4` with the same name, modification date kept, the
  `.ts` removed on success, metadata re-keyed via `library.itemMoved`.

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
   long jobs, re-armed as a dead-man's switch so it never fires while the job is alive (1.10).
7. **A `.sheet` on the root view can't present over the viewer's full-screen cover** (UIKit
   refuses a second presentation from the same hosting controller). Anything that must appear
   "wherever the user is" goes through `ModalPresenter` onto the top-most controller (1.9).
8. **Astria fills `images` progressively** — wait for `num_images`, never take the first
   non-empty array (1.9a).

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
| Top-most modal presentation (AI results / creator) | `ModalPresenter.swift` |
| Astria.ai Browser (past generations, save anywhere) | `AstriaBrowserView.swift` |
| Find duplicates | `DuplicatesView.swift`, `PerceptualHash.swift` |
| Compare PNGs (PNG ↔ original/PNG matches, hide or delete) | `PNGMatchesView.swift` (`PNGMatching`, `PNGMatchScanCache`), `PhotoBrowserTests/PNGMatchingTests.swift` |
| Storage / Drive Health | `StorageView.swift`, `DriveHealthView.swift`, `DriveRepair.swift` (rebuild, header probe), `MetadataSnapshot.swift` (backup/restore, orphan audit) |
| Directory reading / large folders | `Library.swift` (`coordinatedContents`, `listing`) |
| Folder filters | `Models.swift` (`FormatFilter`), `FolderView.swift` |
| Folder Birthdays mapping (bulk) | `BirthdayMappingView.swift`, `Library.setBirthdays` |
| Move/copy duplicate detection | `DuplicateDetection.swift`, `FileActions.moveItems/copyItems`, `PhotoBrowserTests/` |
| Pure File Transfer mode | `Library.pureTransferMode`, `ContentView.swift` (`PureTransferToggle`), `Thumbnailer.diskCacheEnabled` |
| Downloaders | `LinkDownloadService.swift`, `BunkrWebDownloader.swift`, `MegaDownloader.swift`, `InstagramService.swift`, `FacebookService.swift`, `WebBrowserView.swift` |

## 11. Video editor — `PhotoBrowser/VideoEditor/` (CapCut-parity module, Phase 1)

A non-destructive, drive-resident video editor built to the "Video Editor Module PRD (CapCut
parity)". Phase 1 delivers the storage model and a complete cut-and-export loop: import → main-track
timeline (split / trim / delete / copy / reorder / speed / volume / opacity / crop / rotate / mirror /
canvas transform / ratio / background) → AVPlayer preview → `AVAssetWriter` export into
`VideoEditor/Exports/`. Later phases add transitions, overlays, the audio stack, text/stickers,
keyframes, masks, chroma key and effects — all as **additive** schema fields.

### 11.1 Where things live (one type per responsibility, ARC-1)

| File | Role |
| --- | --- |
| `VEModel.swift` | `project.json` document (`VEProject`, `VEClip`, `VEMediaSource`, …), `VETime` (integer **microseconds**), `JSONValue` + `VEDynamicKey` for unknown-key preservation, `VECanvas` maths, `VENames` sanitising, `VEError` (the only user-facing error model). |
| `VEDriveStore.swift` | `VEDriveLayout` (every path under `<DriveRoot>/VideoEditor/`), `VEDriveStore` (coordinated reads/writes, atomic document save with `.bak`, free space / read-only / FAT32 queries, `drive://` ↔ absolute resolution), `VEDriveMonitor` (2 s reachability poll + error-driven loss), `VEEditorSettings` (`settings.json`, replaces UserDefaults), `VELog`. |
| `VEDocument.swift` | `VEDocument` (undo stack of 200 state snapshots, transactions for gestures, 500 ms/2 s autosave, lock heartbeat, `.bak` recovery, "Rebuild from media"), `VEProjectCatalog` (list/rename/duplicate/delete/sizes/clear caches). |
| `VEMediaService.swift` | Probe by format descriptions (unsupported codecs named), identity (size + mtime + SHA-256 of first/last MiB), import by reference or chunked copy with progress, relink search, throughput measurement, thumbnails (poster + 1 fps strips of 60 frames), waveforms (`.pk`, 10 ms Int16 min/max), 720p proxies. |
| `VECompositionBuilder.swift` | Project → `AVMutableComposition` (A/B main video tracks, A/B embedded-audio tracks, one track per audio lane), `AVMutableVideoComposition` with `VEInstruction`s, `AVMutableAudioMix`; `VELayerMath` (crop → fit → scale → rotate → flip → position, shared with the on-canvas gizmo). |
| `VECompositor.swift` | The one `AVVideoCompositing` renderer (Core Image on a Metal `CIContext`) for preview, export and covers — `VECompositor` (8-bit BGRA, sRGB) and its subclass `VECompositorHDR` (10-bit sources, RGBAh working format, 64-bit half output in BT.2020/HLG); `VEImageCache` for stills/GIF frames; `VEFrameRenderer`. |
| `VEFilters.swift` | `VEFilterCatalog`: the Filters tool's presets as pure `CIImage → CIImage` looks (`VEFilterDef`), mixed with the original at `VEFilter.intensity` via a dissolve. The compositor applies a clip's filter in source pixels, after crop and before placement. |
| `VEExportService.swift` | EXP-3 tiers, pre-flight (missing media, 1.5× space, FAT32 4 GiB, read-only), reader → writer pipeline on a dedicated queue (HEVC Main 10 + BT.2020/HLG tags for HDR), `VEExportMetadata` (the sources' metadata with the **oldest capture date** as the file's creation date, also set as the file-system dates), `renders/` → `Exports/` rename, background task + "export interrupted" notification, optional Photos copy. |
| `VEPlayback.swift` | `VEPlayback` (item swap keeps the playhead, coalesced zero-tolerance seeks ≤ 60/s, frame step, stall → proxy), `VEPreviewView` (player layer + pinch/drag/twist gizmo with centre-line and right-angle snapping). |
| `VETimelineView.swift` | UIKit timeline: fixed centre playhead, pinch zoom (1 min/screen … 20 pt/frame), ruler, filmstrips + waveform overlay, badges, trim handles with ripple and snapping, long-press reorder, cover/add tiles, cut handles. |
| `VEEditorSession.swift` | All edit commands, timeline delegate, import flow, derived-asset queue (2-wide, thermal-aware), relink, cover regeneration, drive-loss wiring; `VEThumbStore`. |
| `VEEditorView.swift` | The screen, tool bars, tool sheets (✓/✕ = one undo step; Speed, Volume, Opacity, Duration, Edit, **Filters**, Ratio, Canvas), project settings (incl. the HDR mode), cover sheet, drive-lost sheet. |
| `VECropScreen.swift`, `VEImportPicker.swift`, `VEExportSheet.swift`, `VEProjectsView.swift`, `VEHost.swift` | Crop UI, Drive/Files/Photos picker, export sheet + progress + completion, Projects screen, host adapter and entry points. `VEHost` shows a **determinate opening screen** (`VEOpenProgressView`): drive check → read/create project → per-file asset warm-up (existing projects) or the launch items' import (new projects) → preview build, so "Edit in Video Editor" never shows a black "Opening…" screen followed by a second "Importing…" pop-up. |

### 11.2 Rules that must survive future changes

- **Nothing in the sandbox.** Every write goes through `VEDriveLayout` paths and `VEDriveStore`
  (`assertUnderDrive` fires in Debug). Preferences live in `settings.json` on the drive. The only
  sandbox state is the host's bookmark. The Photos picker copies its temp file onto the drive
  *inside* the `loadFileRepresentation` handler (iOS deletes it when the handler returns).
- **Sources are never touched.** Drive-native files are referenced as `drive://…` with an identity
  record; moved files relink by identity on open. Files from outside the drive are copied into
  the package's `media/`.
- **Document saves are atomic** (`project.json.tmp` → replace, previous kept as `project.json.bak`)
  and never in place. Unknown JSON keys round-trip untouched (`extra`).
- **One compositor.** Preview, export and covers all render the same `VEInstruction` graph; export
  never consults any live UI state. Stills occupy *empty* time on video track A and are drawn by the
  compositor from the file (`VELayerSpec.imageURL`) — no bundled blank video. If a device ever
  refuses to call the compositor for an instruction with no source tracks, the fallback is a
  one-frame placeholder insert; nothing else needs to change.
- **Colour space follows the media (CAN-7).** `VEProjectSettings.hdrMode` is Auto / On / Off and
  `refreshHDR()` resolves it into `settings.hdr` (Auto = any HLG/PQ video *on the timeline*;
  re-resolved on every import, relink, settings change and on open). SDR projects declare BT.709
  on the video composition, so AVFoundation tone-maps HDR sources before the compositor sees them.
  HDR projects declare BT.2020/HLG and use `VECompositorHDR` (`supportsHDRSourceFrames`, 10-bit
  source formats, RGBAh working format, `kCVPixelFormatType_64RGBAHalf` output rendered into the
  `itur_2100_HLG` colour space); SDR clips and stills are lifted to standard white. Export of an
  HDR composition is HEVC Main 10 with BT.2020/HLG colour tags and a 10-bit 4:2:0 reader output;
  the export sheet's HDR toggle (default = the project's state) can force SDR instead. HDR sources
  no longer force proxies, and the proxies made for them use the 1080p **HEVC** preset (the H.264
  presets tone-map to SDR).
- **Orientation comes from the decoded track, not the source record.** A custom compositor
  receives raw, un-rotated frames; the builder reads `preferredTransform` from the track it
  actually inserted (original *or* proxy — `AVAssetExportSession` keeps the rotation flag rather
  than baking it in) and the compositor orients, then scales to the recorded display size. This
  is what fixed "portrait clip sideways and squished" when the preview was on proxies.
- **Progress is generation-stamped.** `VEEditorSession.importAndWait` tags each import; only its
  own ticks update the overlay and only it may clear it (ticks are separately enqueued main-actor
  tasks, so a late one used to leave "Importing…" up forever). `importFiles` reports per-file
  stages (identity → probe → copy) so a single file still moves the bar.
- **`@concurrent` on the heavy async entry points.** The target builds with
  `SWIFT_APPROACHABLE_CONCURRENCY` (NonisolatedNonsendingByDefault): a plain `nonisolated async`
  function runs on whatever actor *called* it, and the session, playback and export job call these
  from the main actor. `VEMediaService` (probe/import/copy/thumbs/waveform/proxy/frame),
  `VEAssetCache.asset(for:)`, `VECompositionBuilder.build`, `VEExportService.run`,
  `VEExportMetadata.collect` and `VEFrameRenderer.image` are `@concurrent` so they always run on
  the cooperative pool. Keep that attribute on anything new that touches the drive or AVFoundation.
- **Tool sheets are transactions.** `beginTool` → live `updateTransaction`s → `confirmTool` pushes
  one undo entry; `cancelTool` restores the pre-sheet state. Gestures (trim, canvas moves) use the
  same transaction API, so every PRD "one undo step" rule holds.
- **Drive loss.** `VEDriveMonitor` pauses playback and shows the blocking sheet; the document stays
  in memory and saves on reconnect. Any I/O error that is `ENODEV`/`EIO`/`ENXIO` counts as loss.
- **Concurrency.** `VEDriveStore`, `VEMediaService`, `VECompositionBuilder`, `VECompositor` and
  `VEExportService` are `nonisolated`; the document, session and views are `@MainActor`. The
  export pump runs on its own `DispatchQueue` so blocking on the writer never starves the
  cooperative pool.

### 11.3 Not yet built (by PRD phase)

Phase 2: transitions (the cut handles are drawn but tell the user they're coming), overlays, the
audio menu (music/SFX/voiceover/extract audio/fades UI), text, EXP-9 audio-only export. Phase 3:
keyframes, masks, chroma key, adjust/LUTs, effects, canvas images/eyedropper, replace, GIF
export (filters and HDR were brought forward and are built — see above). Phase 4: frame
blending, iPad two-pane, loop, beat detection. The schema already carries placeholders for all of
these (`tracks.overlays/audio/text/…`, `adjust`, `mask`, `chromaKey`, `animation`, `keyframes`,
`transitions`, `beats`).

### 11.4 Tests

`PhotoBrowserTests/VideoEditorTests.swift` covers the document round-trip, time mapping, canvas
sizes, placement maths, names/paths, the sandbox audit, undo/redo and recovery. Render and
performance tests need a device (custom compositors don't run in the Simulator).

## 12. exFAT write durability — `DriveWriter` (the "AI folder corruption" fix)

**Symptom (Oct 2026).** `fsck_exfat` on the SSD kept finding `Cluster chain for /X/AI overlaps a
previously allocated cluster`, `Directory /X/AI has zero length` and `Found an unexpected critical
primary directory entry in /X/AI` — mostly in the "AI" subfolders where Astria results are saved,
plus the occasional download folder.

**Root causes (all in our code).**

1. `AIExtend.saveToAIFolder` / `saveGeneratedToFolder` created the "AI" folder with a bare
   `createDirectory` (no flush) and then wrote the JPEG **straight to its final path** with
   `CGImageDestinationCreateWithURL`, then `setAttributes` — three unflushed directory mutations
   per image, none of them atomic.
2. "Keep all" in `AIResultsView` fired one detached task per image, so several writers created
   the same brand-new folder and chose the same "unique" file name at once (the second write
   clobbered the first) while mutating one exFAT directory concurrently.
3. The foreground recovery pass (`resumePendingAIEdits`) ended its `BackgroundTaskHolder`
   **before** saving the images, so a quick app switch suspended the app mid-write.
4. Dozens of other places created drive folders with a bare `createDirectory` — the folder's
   cluster allocation and the parent's new entry sat in the drive's cache until an unplug.

**Fix.**

- `DriveWriter.createDirectory(at:)` — creates the missing levels and, on exFAT/FAT, flushes each
  new directory plus the parent that gained the entry. Every drive-folder creation in the app
  (download services, import views, FileActions, Library, the video editor) now uses it; only
  container-side caches (Thumbnailer, DownloadLog, BackgroundDownloader inbox, dup-scan caches)
  keep the plain call. `FileActions.createFolder` (the user's New Folder) uses it too.
- `DriveWriter.shared.writeData(_:to:dates:)` now creates the parent folder inside the actor and
  stamps creation/modification dates on the temp, so the final entry is written exactly once.
  `writeDataUnique(_:named:in:dates:)` picks the non-colliding name **and** writes in one actor
  turn (no suspension between) — concurrent savers can't collide. `writeDataSync` is the same
  temp → fsync → rename → flush recipe for callers that can't await (screenshots).
- The AI saves encode to `Data` in memory and go through `writeDataUnique`; both save functions
  are `async`. `AIResultsView` holds one background window while any save is in flight; the
  recovery pass keeps its window open until the images are on the drive (`defer { bg.end() }`).
- TikTok inbox filing flushes each placed file; the video editor's chunked import copy and the
  Photos-picker staging copy write into a hidden `.pbtmp_` sibling and rename.

**What this does not cover.** A cable pulled during an active write can still tear the FAT —
exFAT has no journal, which is why "Prepare Drive for Removal…" exists. The fixes shrink the
window to a single in-flight, fsync'd entry and make every folder/file either fully present or
absent. Run Drive Health's deep check after any repair session.
