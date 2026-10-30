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

- **`AIModel`** (`seedream5Pro`, `seedream5Lite`, `seedream45`, `nanoBanana21`, `nanoBanana2`, `flux`):
  - `partnerModels` = the five closed gallery models. Used in Settings (default-model picker,
    tune-id overrides) which must **exclude Flux** (Flux has its own "Flux (extend)" tune field).
  - `composesLoRA` is true only for `.flux` — Flux is the only base that can run a user LoRA
    composed into the prompt via `<lora:id:weight>`.
  - `tuneID(for:)` maps a model to its Astria gallery tune id (editable in Settings; Flux
    shares the single editable Flux tune). Fallbacks: 5.0 Pro 5236038, **5.0 Lite 4160332**
    (from its public gallery URL), **4.5 3691308** (the id the app shipped with before 4.5 was
    dropped — now back), **Nano Banana 2.1 4180298, Nano Banana 2 5850983**. "Nano Banana Pro"
    stays removed. (Oct 2026: Astria upgraded gallery tune 4180298 — until then this app's "Nano
    Banana 2" — to **2.1 in place** and gave the "Nano Banana 2.0" card its own id, 5850983.
    `tuneID(for:)` clears a stored "Nano Banana 2" override that still names 4180298, once, so it
    doesn't silently run 2.1; 2.1 supports the 1K/2K/4K `resolution` tiers like the others.)
  - **`maxReferenceImages`**: 14 for Seedream 4.5 / 5.0 Lite / Nano Banana 2 / 2.1 (2.1's limit per
    Astria's launch banner), 10 for Seedream 5.0 Pro, 0 for Flux.
  - **`fixedResolution`**: Seedream 5.0 Pro → `.k2` (2K is the most Astria supports for it), else
    nil. Edit and Create pin the Resolution picker to it (disabled, with a footer) whenever that
    model is selected and send it regardless of what the picker last held. **How references actually work on Astria (verified against
    docs.astria.ai and Astria's own CLI, astria-claude-skills `bin/astria --reference`):** image
    prompts take *no* raw reference images — `prompt[image_references][]` is video-only and image
    prompts fail with "video_first_frame, video_last_frame, audio_reference and image_references
    can only be used with a video prompt" (field-confirmed); `prompt[input_images][]` doesn't
    exist. A reference is an instant **faceid tune**: `POST /tunes` with `tune[model_type]=faceid`,
    `tune[base_tune_id]=<generating model>`, `tune[name]=image`, `tune[images][]=<jpeg>`, then
    `<faceid:ID:1> image` at the start of the prompt text. `AIExtend.referenceMentions` does this,
    caching `base|path|mtime|size → id|name` (`photoBrowser.astriaReferenceTunes`) so a photo is
    turned into a tune once per model; waits ≤ 2 min if `trained_at` isn't set; a reference that
    can't be made is left out with a note on the results screen (never fails the job); a rejected
    prompt that reused cached tunes forgets them. Reference tunes are titled
    `AIExtend.referenceTitlePrefix` ("Photo Browser reference · …") and filtered out of
    `Library.loadAITunes`, so they never show in the tune pickers.
  - **Reference picker UI** (`AIGenerators.swift`): `ReferenceImagesPicker` (a mini folder
    browser: opens in the folder the sheet came from, lists subfolders above the photo grid, an
    Up bar climbs to the drive's top, so references come from **any folder on the drive**; photos
    numbered in pick order across folders, capped at the model's limit; the Edit flow excludes its
    source photo), `ReferenceImagesStrip` (chosen thumbnails with ✕) and
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

- **`TuneBaseModel`** (in `AIGenerators.swift`): `nanoBanana21, nanoBanana2, seedream5Pro, seedream5Lite, seedream45, flux, sdxl, sd15`.
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

- Partner models (Seedream 5.0 Pro, Nano Banana 2 / 2.1) are **closed** models. You **cannot** LoRA-
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
  ready alert (tap → that folder). Like a kept result, each saved image is marked AI-generated (model
  + prompt) and an edit's images get the original photo's tags (Oct 26 — before, recovered images had
  neither). It runs at **launch, on every return to the foreground, on a
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

### 1.11b Surprise Me — `SurprisePrompts.swift`, `SurpriseMeSection`

A section under the prompt box in both Edit and Create: a **mood** picker (Any / Alluring / Sexy,
remembered in `photoBrowser.surpriseMood`) and two buttons. **Surprise Me** fills the prompt with
`SurprisePrompts.random(mood:flow:model:references:)` and calls the screen's normal `generate()`
at once — so the user's references, resolution, aspect, count, model and tunes all apply exactly
as for a typed prompt (the FaceID reference mentions are prepended by `AIExtend` as usual).
**Fill In a Random Prompt** only fills the field.
- **Banks** (all a woman posing for a photo): ~30 subjects (used only for Create with no
  references), ~160 looks tagged alluring / sexy **and by tier** — `clothed` (anything a model
  will take: tight workout sets, bodycon, swimwear, tight jeans, wedding dresses, sundresses,
  pyjamas, tailoring…) or `intimate` (bra-and-brief sets, thongs, slips, lace, sheer layers).
  **`allowsIntimate(model)`** gates the intimate tier to the Seedream family (Flux too): Nano
  Banana (Gemini) refuses underwear / see-through, so its sexy draws stay clothed. Glamour-shoot
  wardrobe only — no nudity and no sexual acts (the app composes these with real people's
  reference photos and FaceID tunes, which is why that line is fixed). ~70 settings, ~60 poses
  (sexy poses only for the sexy mood; alluring poses for both), 30 lights, 20 cameras, 12
  finishes, 12 hair notes, and ~60 hand-written **signature** scenes (`{subject}` placeholder, one
  draw in four; tiered the same way). Composed combinations run into the millions; the signatures add shots a recipe
  can't make.
- **Per-model voice** (`voice(for:)`): Nano Banana 2 / 2.1 get one flowing paragraph — a described
  moment with the light and camera in sentences (what Gemini-family image models answer best);
  Seedream 5.0 Pro (and Lite / 4.5 / Flux) get subject-first labelled sentences
  (`Subject / Outfit / Scene / Pose / Lighting / Camera / Style`) with explicit style words. Both
  end with the realism tail (real skin texture, no beauty-filter smoothing, grain, no text or
  watermark) matching `PromptingReminderSection`.
- **Flow**: Create with references → "the woman from the reference image(s), her face and features
  exactly as shown"; Create without → a random subject description; Edit → an edit lead-in that
  keeps the woman's identity (face, features, hair colour, skin, body) and restyles everything else.
- **The banks live on the drive — `Surprise Prompts.json` at the drive root** (`SurprisePrompts.fileName`,
  `load(root:)`). The first Surprise Me tap with a drive open writes the file with the whole built-in
  bank (`Bank.builtIn`, pretty-printed, through `DriveWriter.writeDataSync`); from then on the file is
  the bank: edit, add or delete freely in any text editor. Shape = `Bank` (`subjects`, `looks`
  `{heat,tier,text}`, `settings` `{text}`, `poses` `{heat,text}`, `lights`, `cameras`, `finishes`,
  `hair`, `signatures` `{heat,tier,text}` with `{subject}`), decoded leniently (missing key → empty
  list, missing `heat` → alluring, missing `tier` → clothed); a list left empty falls back to the
  built-in list (`filled()`), and a mood/model combination the user's list can't serve (only intimate
  looks on Nano Banana) draws that slot from the built-in list rather than failing. Unreadable or empty
  file → built-in bank plus a note under the section explaining why (`Loaded.note`). Reads happen off
  the main actor (`Task.detached` in the views' `surprise(send:)`) and are cached by the file's
  size + mtime (`LoadCache`), so a tap re-reads only after an edit. The file is hidden from the grid
  via `GalleryCategories.sidecarNames`. No drive open → built-in bank. A copy of the built-in bank
  in the file's exact shape is kept at `prompts/surprise-prompts.json` (exported from the Swift
  banks; regenerate it whenever the banks change) — a seed to edit and copy to the drive by hand.
- Astria's moderation still applies to whatever is sent; a refused prompt surfaces like any other.

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

### 3.4 Force Refresh from Drive — `Library.thoroughContents`, `FolderView.forceRefresh`

Folders created on the SSD in Finder (Mac) could still fail to appear even after a normal
re-listing: the coordinated read returned a non-empty but **stale** enumeration, and because
`coordinatedContents` stops at the first strategy that returns anything, no other path was asked.
Pull-to-refresh and ⋯ ▸ This Folder ▸ "Force Refresh from Drive" now:
- re-check the drive / re-resolve the bookmark (`prepareForceRefresh` → `reconnectIfNeeded`, a
  fresh security-scoped open) and drop the folder's cached listings so nothing stale paints first;
- list with `thorough: true`: drop cached URL resource values, `F_FULLFSYNC` the directory on a
  read-only fd (**nothing is written** — no probe files on the exFAT drive), then **union** the
  coordinated, URL, path-based, shallow-enumerator and POSIX listings by name;
- alert "Found N folders the drive hadn't shown yet" when the merge surfaced anything, so we learn
  whether this path is what fixed it. The normal (non-forced) listing is unchanged — the merge
  costs several directory reads.

### 3.5 Folders iOS can't stat — `Entry.unreadable`, `Library.directoryStatus`, `DriveWriter.usableDirectory`

**Symptoms (Oct 2026):** some folders visible in Finder never appeared in the grid (small ones
too); new video-frame captures didn't create a "Screenshots" folder and new AI results didn't
create an "AI" folder — "in certain folders" only. `rebuild_exfat_folders.py` didn't help.

**Cause (ours, on top of drive damage).** Old damaged exFAT folder entries (§12: "Directory
/X/AI has zero length", cross-linked clusters) are still listed by the parent directory, and macOS
shows them, but iOS can't stat them. Three code paths turned that into silent failure:
1. `listing` classified an item whose stat failed as a **file**; with size 0 it was then hidden by
   `applyHidden`'s "0 KB file = broken download" rule → the folder vanished. (Drive Health filed it
   under "unreadable files" and never offered Rebuild.)
2. `DriveWriter.createDirectory` / `FileActions.screenshotsFolder` asked `fileExists` → "no" for
   the damaged `AI`/`Screenshots` entry → `createDirectory` failed with "file exists" → the error
   was swallowed (`try?`) → every save into that folder failed ("Couldn't save" / no AI folder).
3. The grid read stopped at the first strategy that returned anything; the coordinated read can be
   stale (§3.4), so even a folder the app itself had just created could be missing.

**Fix.**
- `Library.directoryStatus`: stat → `fileExists` → `lstat` → the enumeration's directory flag →
  "extension-less ⇒ folder"; anything past the first two is flagged `Entry.unreadable` (optional,
  so old listing snapshots decode). `applyHidden` never hides an unreadable entry; `ThumbCell` draws
  it as an orange "Can't read on iOS" folder; opening it shows an explanation with the Mac repair
  (`Library.unreadableReason`). Names that only resolve under the other Unicode normalization
  (Finder can write decomposed accents) are retried via `normalizationVariant`.
- `Library.mergedContents`: the normal listing = coordinated read ∪ one plain read (names only the
  plain read sees must `fileExists`; skipped above 8000 entries). Force Refresh's union applies the
  same existence rule, so stale caches can't add ghosts.
- `DriveWriter.usableDirectory(named:in:)`: returns a readable existing folder or creates it; a name
  held by an unreadable entry falls through to "AI 2" / "Screenshots 2"…, so saves land somewhere
  visible. Used by `AIExtend.aiFolder` (both AI save paths; last resort = the source folder) and
  `FileActions.screenshotsFolder`.
- Drive Health reports a folder-shaped unreadable entry as an **unreadable folder**; the search walks
  (`search`, `enumerateAll` → the index) classify with `directoryStatus` too.
- **Force Refresh no longer undoes itself:** `prepareForceRefresh` used `contentDidChange`, whose
  `changeToken` bump queued a *normal* reload behind the thorough one; that stale re-list then
  overwrote the merged result. It now only evicts the cached listing (`evictListing`).
- **Huge folders:** the > 8000 path defers size/date (size 0, `modified == .distantPast`), and the
  0 KB rule was hiding *every file* there. `applyHidden` now only hides 0 KB files that were actually
  stat'd. Extra-read entries are dropped only on ENOENT (`existsOrDamaged`), so a damaged folder
  only one read reports is kept (flagged), while a stale cache can't add deleted items.
- **AI saves:** `AIResultsView` used to mark a result "Saved" before writing, never checked the
  outcome and then dropped the job's recovery record — so every failure above looked like "no AI
  folder". It now shows Saving… → "Saved to “<folder>”" or "Couldn't save" + Try Again, only
  auto-closes when everything is really saved/discarded, asks before leaving with failures, refreshes
  the grid per save, and `finish()` runs once. `usableDirectory` creates only the leaf (missing
  parent ⇒ fail visibly; it used to rebuild a phantom copy of a renamed folder or of the old mount
  path). A source already in an "AI" folder saves beside itself (no AI/AI); result names are capped
  for exFAT's 255-unit limit; `sanitizeName` strips control characters. `applyRemap` (moves, renames,
  remounts) now re-keys pending Astria jobs and the Astria browser's save folder.
- **Field result after a clean `fsck_exfat` (Oct 2026):** 24 folders still failed on iOS with
  `NSCocoaErrorDomain 256` + `opendir errno 22 (EINVAL)` although fsck found nothing. This matches a
  known bug in Apple's FSKit-based exFAT driver (macOS 15+/iOS): it returns "Invalid argument" for
  some valid directories that other exFAT drivers (Windows, exfat-fuse) read fine. Common thread in
  the list: heavily churned folders (AI, Screenshots, Duplicate PNGs, NO EXIF DATA, Today's Instagram
  Stories — files repeatedly moved in/out, leaving deleted entries). Writing the directory fresh is
  the fix available to us: `rebuild_exfat_folders.py --list <Drive Health export> --root <drive>`.
  A name with "/" (stored by macOS as ":") can never be opened on iOS — rename it.
- Drive Health's "contents don't match the extension" now says what the bytes really are ("Named
  HEIC but it's really a JPEG — it still opens fine"); `.mov` accepts classic QuickTime atoms
  (`moov`/`mdat`/`wide`/`free`), which were false alarms.
- The real repair is on the Mac: `mac/repair_drive.sh` (`diskutil verifyVolume` → confirm →
  `diskutil repairVolume`, i.e. fsck_exfat / Disk Utility First Aid). Copying folders can't mend a
  damaged parent directory or a cross-linked FAT.

### 3.6 Huge folders iOS stopped opening (Kardashians, Oct 2026)

**State after rebuilding:** Drive Health went from 24 unreadable folders to 5 — `Kardashians/Kendall
Jenner` (46,435 photos + 46,435 `._` sidecars), `Kardashians/Kylie Jenner` (32,807 + 32,807), one
`Duplicate PNGs` and two star folders downloaded on the Mac since (`…/Nina Hartley/Nina Hartley`,
`…/Sasha Grey/Kelly Wells`). Same error as the rest: `NSCocoaErrorDomain 256` + `opendir errno 22`.

**Not a size limit.** The Kardashian folders opened fine before (and §3.2's lazy listing was built
on a ~90k-entry folder that the Files app opened instantly), and iOS itself wrote both the photos
and their `._` sidecars. The copy rebuild that fixed the other folders was simply never run on them
— it needs free space for a second copy of 46k photos.

**What we know about them:** Access Kardashian wrote every photo straight to its final path — `Data
.write(options: .atomic)` or `CGImageDestinationCreateWithURL` on the drive — from 22 concurrent
download slots, i.e. tens of thousands of uncoordinated directory updates to one exFAT folder
(CLAUDE.md #12's exact failure mode). Kendall's folder still holds `<name>.jpg.sb-xxxxxxxx-XXXXXX`
leftovers of interrupted atomic writes, each with its own `._` sidecar.

**Fixes:**
- `AccessKardashian.saveImage` now embeds date/GPS in memory (`CGImageDestinationCreateWithData`)
  and places every file through `DriveWriter.shared.writeData` (controlled temp → flushed → renamed,
  one commit at a time; downloads stay concurrent). Its log file is created with
  `DriveWriter.writeDataSync`.
- `mac/rebuild_exfat_folders.py --move` (first version, Oct 8) renamed every item into a fresh
  hidden sibling instead of copying. **Superseded on Oct 10 by `--low-space`** (fresh copies, each
  original deleted once its copy checks out — see "Same day, contradicting test" in §12): moving
  files out of a broken folder carried the breakage into the new folder.
- `mac/exfat_inspect.py`: the evidence step — reads a folder's directory entries **off the raw
  device** (read-only, `sudo`) and checks every exFAT field: set checksums, NameHash (with the
  volume's up-case table), SecondaryCount vs name length (incl. stale name entries — the
  "rename to a shorter name" bug class a 2026 Linux exfat patch addresses), names (forbidden chars, invalid
  UTF-16, private-use stand-ins), timestamps / 10 ms / UTC-offset bytes, attributes and reserved
  bytes, ValidDataLength / allocation flags / first cluster vs the bitmap, the folder's own cluster
  chain, entries after the end marker, duplicate up-cased names, and the folder's *own* entry in its
  parent; plus layout facts (deleted entries, pieces on disk, entry sets split across clusters).
  Compares the listed folders with a breadth-first sample of the rest and names any finding that
  separates them. `diagnose_ios_unreadable.py` only saw names as macOS's driver presents them.
  Tested against a synthetic image with each defect planted.
- Drive Health's unreadable-folder detail now appends the whole `NSUnderlyingError` chain, so the
  next report says whether iOS answered EINVAL, a timeout, or a file-provider error.

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
   orphaned, and so are the original paths of items in **Recently Deleted** (their entries stay
   under the original path on purpose so a restore reconnects them — they used to be counted).
   **Re-link by Filename** ranks every same-named item elsewhere on the drive
   (`DriveHealthView.rankedCandidates`: most parent-folder names in common counted up from the
   item, then longest shared leading path) and re-keys through `Library.itemsMoved` — the exact
   machinery an in-app move uses — when there's a single candidate or the best one shares strictly
   more parent folders than the next. Tapping a category opens `OrphanListSheet`: every missing
   entry with its ranked matches to re-link by hand, or **Forget** (also "Forget All" per category
   and for everything). Forget = `Library.forgetMetadata(where:)`, which removes the entry from every
   audited store (plus Clean Up progress / Not-Duplicates pairs / FaceStore) and deletes cover and
   custom-thumbnail images no other entry names; Drive Health takes one automatic container
   backup per visit before the first Forget, so Restore undoes it.
4. **Purged trash forgets its metadata.** Deleting from Recently Deleted (one item, Empty, or the
   30-day expiry) used to leave every entry under the original path forever — one source of the
   35 "folder covers pointing at missing items" (Oct 2026). `Library.forgetPurgedMetadata` now
   forgets the purged originals' entries (subtree for folders), unless something new has since
   taken the original path.
5. **Reconnect Profile Folders — `Library.reconnectProfileFolders` (`ProfileReconnect.swift`).**
   The Instagram / TikTok records (`instagramFolders` / `tiktokFolders`) are what give a download
   folder its bubble, "@handle" subtitle, "Get New Posts / Videos" and the stories sweep; they are
   pruned with everything else by Forget while their folders are unreadable (a list past the 2.2 TB
   line reads as missing), and a partial restore can lose them too — the folders stay full, the app
   just no longer knows whose they are. The button (Metadata safety) re-attaches them without
   touching the drive: first from the backups, newest first (the drive's `.Photo Browser Metadata`
   and the phone's snapshots), merging only a **profile slice** — `profileSlice(of:)` keeps the
   records whose folder exists today and what belongs to those folders (highlights, posted-by,
   likes, handle prefills, covers, bubble order) and hands it to the normal `restoreMetadata`
   merge; then, for folders no backup knows, from the **files themselves** (`scanProfileFolders`: a
   bounded coordinated walk, 8 levels / 60k folders, hidden folders skipped; TikTok = an `@handle`
   folder with `<15–20 digit id>(.mp4|_n.jpg)` files; Instagram = posted-by entries, the handle
   remembered on the parent, a highlight already marked inside, or a handle-shaped name over
   shortcode / story-pk-named files). A rebuilt record carries the ids on disk (so "Get New" dedups
   and backfills — and every run also skips whatever is in the folder, so a record from an older
   backup can't cause re-downloads either: §7.4), `lastUpdated` = newest file date, blank user id / secUid (resolved by the next
   run), subfolders re-marked as highlights, the handle prefilled on the parent. Known profile,
   highlight, Facebook / OF / VSCO folders are never re-classified or entered.

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

### 4.3 Companion Mac scripts

- **`mac/rebuild_exfat_folders.py`** (in the repo) — the fix for folders iOS lists but shows as
  **empty** or can't open (Files app too) while Finder shows their contents: the iOS exFAT driver
  can't read directory entries macOS tolerates. Nothing on the iOS side can read past that (Force
  Refresh, 3.4, doesn't help — the folder *is* listed, its contents read as empty). The script
  copies the folder to a hidden sibling, verifies sizes, Trashes the original via Finder (or parks
  it as hidden `.<name>.original`), and swaps the copy in under the same name/path — metadata stays
  attached. `--low-space` does it with almost no free space (3.6). `--since DAYS` finds recently created folders;
  `--list` takes Drive Health's export; dry run unless `--apply`.
- **`mac/exfat_inspect.py`** — read-only raw-device check of what's actually stored (3.6). Run it
  before a rebuild; the rebuild erases the evidence.

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

## 6b. Location filter — `FolderView.swift`, `MetadataLoader.swift` (place index), `Library.placeLabels`

A "Location" chip next to Year lists every place the folder's photos and videos were taken, with
counts ("Hauppauge, NY (53)", "Limerick, Ireland (50)", "London, UK (40)"), most first, plus "No
Location (n)". It rides on the **place index** search already used: each file's GPS (EXIF for
photos, the QuickTime ISO-6709 tag for videos — v2 of the index; v1 never read videos, so loading
it drops their "no GPS" verdicts) reduces to a ~1 km bin, cached on disk by `path|mtime|size`, and
each *bin* is reverse-geocoded once. The index now stores a **label** per bin alongside the
lowercased search text: `shortLabel` gives "City, ST" in the US (`administrativeArea` is the
abbreviation), "City, UK" for GB, "City, UAE", else "City, Country", falling back through county /
region / country when there's no town. Bins named before labels existed get re-geocoded once for
their label; a geocoder *error* (offline, throttled) stores nothing so the bin is retried, while a
spot the geocoder has no name for stores "" ("Unnamed place").

Loading is lazy — opening the menu or an active filter runs `Library.placeLabels`: bounded GPS
reads (12 concurrent, time-boxed, a timeout isn't cached), then the distinct unlabelled bins are
geocoded serially at 1.2 s each (`geocodeBins`), at most 60 per load, so a never-indexed travelled
folder shows what it can and names the rest next time; the menu shows "Reading locations… n of m" /
"Naming places… d of t" meanwhile. Same 8000-file ceiling as the capture-date pass. The filter
keeps subfolders visible (naming every place under every subfolder would geocode the whole
subtree); "Index Locations" (the search pass) now covers videos too.

**Caching and backup (Oct 18).** Three layers: the per-file GPS bins and per-bin names are the
persisted place index (`placeIndex.json` in Application Support, keyed by drive-relative
`path|mtime|size`, so they survive remounts and relaunches and never re-read or re-geocode); a
folder's *finished* Location result is kept in `Library.placeLabelsCache` (memory, keyed by
folder path + the exact file set, cleared with the listing cache on `contentDidChange` /
`evictListing`, and only stored when every located file got a name, so a partial offline result
is retried) — reopening the menu is instant; and every metadata backup now writes the whole index
as **`places.json`** beside `metadata.json` (`MetadataLoader.placeIndexForBackup`), which Restore
merges back (`restorePlaceIndex` — adds unknown files and unnamed bins, never overwrites, then
`contentDidChange` so menus refresh). Backups without the file (pre-Oct 2026) restore as before.
Tags need no extra cache: `Library.tags` is in memory and in the bulk store, and the Tags menu's
counts are a scan of that dictionary; they're in `metadata.json` since the tags commit.

---

## 6c. Tags — `Library.tags`, `InfoPanel.tagsSection`, the Tags chip in `FolderView`

Per-file tags, added one at a time in the info panel's "Tags" section just below the caption:
the file's tags as chips (✕ removes one), a field + Add (Return adds too), and one-tap suggestions
from tags already in use anywhere (prefix-matched to what's typed). `Library.tags` is
`path → [tag]` in the bulk JSON store ("tags"), with `normalizedTag` (trimmed, inner whitespace
collapsed, no leading "#") and case-insensitive uniqueness per file. It has full parity with
captions: re-keyed by `applyRemap` / `itemsMoved` (`moveDict`) / `forgetMetadata` (`pruneKeys`),
persisted in the remap block, in the metadata backup (`MetadataSnapshot.tags` — *optional* so
backups made before tags existed still decode; `MetadataCategory.tags` for Drive Health's orphan
list), and matched by the index search. Changes bump `labelsVersion`.

The **Tags chip** (after Location) lists every tag under the folder *and its subfolders* with
counts (`tagCounts(under:)`, case-insensitive merge, most used first). **Several tags can be on
at once** (`tagFilters: Set<String>`, toggled by `toggleTag`); a file must carry **all** of them
(`taggedPaths(under:tags:)`), like the Categories filter, and while any are selected the menu's
counts come from `tagCounts(under:having:)` — what each further tag would narrow the selection
to (selected tags stay listed; others at zero drop out). Tags are a mode like Favorites:
`labeledEntries` gathers the tagged files from the whole subtree (the "labels" task), honouring
Type and the search box; the other modes step aside, and Favorites / To AI / Edited clear it.
Header subtitle "Tag: x" / "Tags: x, y"; chip "Tag: x" / "Tags: 2"; "Clear Tags" at the top of
the menu; the chip-bar Clear resets it too. **"No Tags"** (first menu item, `noTagsFilter`) shows
every photo/video under the folder with no tag yet — `unlabeledMedia(under:labeled:)` with
`taggedPathSet`, the same walk as the labels' "(No Label)" — so untagged work is easy to find.
The editor itself is `TagEditor` (chips + field + suggestions, a `Group` of rows), shared by the
info panel and both clean-up screens (`FrameCleanupView.tagRow`, under the card, keyed on the
item), so tags can be added while swiping through. Folders can be favorited too: the folder
context menu has Favorite/Unfavorite (Get Info had it already), the tile shows the heart, and the
Favorites mode lists them (its Folders sub-filter).

**Bulk tagging:** in selection mode, More ▸ **Tags** has "Add Tag…" (an alert with a text field,
presented deferred per constraint #4) that tags every selected item at once, plus the existing
tags (`allTags`, first 30) as toggle rows — checked when every selected item carries one; tapping
adds it to all, or removes it from all when they all have it. `Library.addTag(_:to:)` /
`removeTag(_:from:)` take `[URL]` and save once per batch; folders can be tagged too.

**Chip bar order (Oct 18):** Favorites, Type, Format, Sort, Year, To AI, Edited, Labels, then
Age / Categories / Location / Tags / Clear (or "Show:" in a label mode). Sort moved from the
toolbar into the bar — on a phone the toolbar overflowed it into "…". Type now applies in the
Favorites / To AI modes too (it's always visible); Year stays hidden in those modes, which don't
apply it.

---

## 6h. Tags shared with Safe Finder — `SharedTags.swift`, `mac/shared_tags.py` (Oct 26, 2026)

The app's tags and Safe Finder's are one set. **Where:** `<drive>/.Photo Browser Metadata/shared-tags.json`
(the metadata-backup folder at the app's root), `{"format", "version", "id", "updated", "by",
"files": {drive-relative path: [tag]}}` — the same key for a file on the Mac (`/Volumes/SSD/…`) and
here (`…/userfsd/<UUID>/SSD/…`). Tags are stored as `normalizedTag` makes them and compared ignoring
case on both sides; hidden paths (`.Trash`…) are never in it; Safe Finder writes keys NFC (Swift's
String equality is canonical, so NFD keys here match).

**Why a file on the drive, merged three ways.** The SSD is plugged into one device at a time, so
there is never a second writer to race. Safe Finder edits the drive's file directly — while the
drive is on the Mac it *is* the copy of record. The app keeps its own `Library.tags` (everything
else reads it) and `syncDriveTags` merges: for each path, a side that left the last-agreed state
alone takes the other side's tags; when both changed, removals from either side go and additions
from both stay (`SharedTags.merge`). The last-agreed state (`tagSyncBases`, bulk store
"tagSyncBase") is kept **by the file's `id`**, not by root path — the root path changes on every
replug (new mount UUID), which would have turned every sync into a no-history union and stopped Mac
removals from ever reaching the phone. No base for the file's id (new file, a drive never synced,
Safe Finder restarted a damaged file with a new id) → plain union, never a removal: a lost file can't
wipe tags. Timestamps were considered and rejected: last-writer-wins per path loses one side of a
both-changed file and depends on two clocks.

**When the app syncs:** `chooseFolder` / `restoreLastFolder` / a reconnect under a new mount path
(1 s later), every return to the foreground (the drive may have been on the Mac), 2 s after any tag
change (`noteTagsEdited` — from `addTag`/`removeTag` and from `persistAllPathKeyed`, which covers
moves, renames, prunes and backup restores), and on the way to the background (`flushTagSync`, under
a background-task window, saving the base before it closes). Coalesced (`scheduleTagSync`); one at a
time (`tagSyncRunning` / `tagSyncAgain`); an entry edited while a sync was reading is left for the next
one. Reading/merging/writing is detached; the write goes through `DriveWriter.writeDataSync`. A sync
that brings changes shows a toast ("Tags from Safe Finder: 12 files updated") and bumps
`labelsVersion`. Drive Health ▸ Metadata safety has **Sync Tags with Safe Finder** and the last
result (`tagSyncStatus`).

**Safe Finder** (`shared_tags.TagStore`): a drive file's table is found per folder by walking up to
the nearest folder holding `.Photo Browser Metadata` (else the volume root), cached per folder; files
on the Mac's own disk go into `~/Library/Application Support/Safe Finder/tags.json` (absolute keys)
and travel with Move/Copy (`Transfer` now reports `placed` (original → where its copy landed, incl.
"name (1)" and a renamed `.incoming` folder) and `trashed_paths`; `MainWindow._carry_tags` copies tags
over and drops the trashed originals'). The file is re-read when its mtime/size change (checked at most
every 2 s, forced before every edit). Writing: APFS temp + fsync + `os.replace`; exFAT in place (Mac tools
never rename or fsync there) — a torn file reads as damaged and is restarted with a new id. UI: ⌘T /
header button / right-click ▸ Tags ▸ Add Tags… open `TagDialog` (type, commas, completer for the last
segment; chips toggle on all / ✕ off all / "3/12" partial); right-click ▸ Tags lists every tag with
ticks; folders in a selection expand to their files on a thread (`expand_files`, hidden/bundles/
sidecars skipped); the sidebar's Tags section (counts, colour dot from a CRC of the folded name) opens
`safe-finder://tag/<name>` (a `TagScanner` collection), takes file drops, and renames / removes a tag
everywhere; `tag:x` / `#x` in a search field opens the same collection; tiles show a pill (dots + first
tag), list rows chips, the status line a single selection's tags; Move to Trash drops the tags.

**Sticky tags — they travel inside the file (Oct 26, 2026).** Path-keyed tables lose a file's tags
when something else moves or copies it (Finder, the Files app, `cp`). So each file also carries its tags
in a **private extended attribute**, `com.photobrowser.tags` (JSON `{"path": drive-relative key (absolute
for the Mac's own disk), "tags": [...]}`: where the file was and what it carried when last written) —
never on exFAT, where macOS writes `._` files. Finder, the Files app, cp/mv and ditto keep any extended
attribute through a copy or move; iCloud Drive and some cloud folders keep only a whitelist (Finder tags
yes, a private one no) — accepted. **Why private, not Finder's tags:** the first cut wrote Finder's own
`_kMDItemUserTags` too (Finder/Spotlight visibility, Finder edits flowing in), but that made every
existing Finder tag ("Red", "Work") a Photo Browser tag and put Photo Browser's tags all over Finder; the
user chose a private field the same day. Finder's tags are now never read except to take off ones that
build wrote (`ours_in_finder` / `isOursInFinder`: exactly the marker's tags, none coloured), and kept
across in-place rewrites like any other attribute. The marker is what tells the cases apart
(`SharedTags.reconcile` / `TagStore.apply_carried`, kept identical — `test_reconcile_parity.py` checks them
against each other): marker at another path → the file arrived from elsewhere: adopt its tags (union with
any here), and if nothing is at the old path any more it was a move, so drop the old entry; marker for this
very path on a file the store has nothing for → it came back (Put Back from a Trash, which dropped its
tags): restore them — only for an *arriving* file (`arrived:`), never while a sync writes out the store's own
removals; otherwise the store is the record and the marker follows it. **Who writes:** Safe Finder on
every edit (`TagStore._edit`, so a removal clears the marker at once) and when a folder is opened
(`check_carried` reads on a thread, applies on the UI thread); the app at each sync for every key whose
tags changed since the base — all of them once (`Base.markers`, nil in bases from the Finder-tag build, so
that pass also takes those Finder tags off) — and for files new to the index after a walk or patch
(`adoptCarriedTags`, diffing old vs new index, only under the patched folders for a patch; skipped with
no earlier index, so a first-ever walk never reads the whole drive). In-place rewrites keep the attributes (`carriedAttributes`/`restoreAttributes` around `replaceItemAt` in
`MediaEditing.replaceInPlace`, the capture-date/location writers, `PhotoEditorIO.promote`); the Mac
companion's ExifTool now writes with `-overwrite_original_in_place`, which keeps them too. Python has
no `os.getxattr` on macOS — `shared_tags` calls libc through ctypes (Linux tests use `user.*`).

**Copies and edits carry tags.** The app's copies (Copy to Folder, the viewer's copy, Clean Up's copy)
now get the original's tags (`Library.copyTags`; a copied folder's files theirs) — the one label that goes
with a copy. So do new photos made from one: the photo editor's **Save as New** (`PhotoEditorView.performSave`;
Overwrite keeps the file, or re-keys it with `itemMoved` on a container change), **Edit / Extend with AI**
results kept from the review (`AIResultsView.keep`, `.edit(original:)`) or saved later by recovery
(`resumePendingAIEdits`, which now also marks them AI-generated with model and prompt — it didn't, so
recovered images had no AI badge), and images saved from the **Astria.ai Browser** whose prompt was an
edit started here (`astriaPromptSources`: prompt id → original path, noted when Astria accepts the prompt
in `pendingRecorder`, remapped with moves; prompts from Astria's website, Create, or before Oct 26 have
no source). Crop/rotate/resize, upscales and metadata writes replace the file in place, so its tags stay. Safe Finder's transfers already did (`carry`). **AirDrop:** `airdrop_to_iphone._add_tags` puts
`<top>/.photobrowser-tags.json` (the tables' tags + Finder tags, keyed inside the top folder) in the
`.pbgallery`; `ReceivedArchivesView` → `Library.applyArchiveTags` applies and removes it (`Archiver.peek`
doesn't count it).

**Backups.** The metadata backup (`backUpMetadata`, manual and automatic) syncs with the drive's tag
file first, so Safe Finder's latest tags are in it (they were already in the snapshot's `tags`; the
drive copy sits in the same `.Photo Browser Metadata` folder). Safe Finder keeps a copy of each tag
table before its first change of a day in `~/Library/Application Support/Safe Finder/Tag Backups/<drive or
This Mac>/` (last 14).

---

## 6i. Batch crop — `BatchCrop.swift`, `mac/batch_crop.py`, `mac/crop_window.py` (Oct 29, 2026)

Crop one photo, put the same crop on many, and tag every one of them "cropped" — on the iPhone and in
Safe Finder.

- **iPhone.** Select photos ▸ More ▸ **Crop…** opens `BatchCropView`: the crop box (`CropOverlay`, the
  photo editor's — now shared, with side handles in Freeform so one side can be trimmed alone) over the
  first photo, the editor's ratios (Freeform, Original, 1:1, 4:5, 3:2, 16:9), quarter turns, **Last
  Crop**, and a strip of the selection — tap one to see the same crop on it. **Crop All** writes each in
  place through `MediaEditing.applyPhotoInPlace` (EXIF, capture date, HDR and the carried tag attribute
  kept, as for any crop), tags them "cropped", and remembers the crop. GIFs (animation) and RAWs (no RAW
  writer) are left out.
- **The crop travels as fractions** (`CropSpec`: turn + normalized top-left rect within the turned
  photo, the convention of `applyPhotoInPlace` and `EditRecipe.cropRect`), so it lands on the same spot
  of a photo of another size. A fixed ratio (`keepsShape`) keeps its own pixel shape on a photo shaped
  differently from the one it was drawn on: same center, as large as the fractions allow, kept inside.
  `CropSpec.rect(forWidth:height:)` and `batch_crop.CropSpec.rect_for` are the same arithmetic — change
  both or neither.
- **"cropped" everywhere a crop is saved.** The Edit screen (`MediaEditorView`, photos and videos) and
  the photo editor (overwrite or Save as New) also tag a file "cropped" when the crop trims something
  (a box within 0.4% of every edge is no crop), and a photo's crop becomes `Library.lastCrop` (bulk
  store `lastCrop`). The photo editor only offers a crop with no turn, flip, straighten or keystone as
  the Last Crop — its own turn runs the other way round in Core Image's Y-up space, so it isn't carried.
- **Safe Finder.** Right-click photos ▸ **Crop…** / **Crop N Photos…**: the same box, ratios, turns and
  Last Crop (kept in Safe Finder's settings), ‹ › to step through the selection. Pillow (pillow-heif for
  HEIC) rewrites each photo: upright first (EXIF orientation baked in, then 1), turn, crop, saved in its
  own format with its EXIF (pixel size updated), ICC profile and XMP (orientation and size fixed); a
  TIFF keeps its descriptive tags. The new bytes are made and decoded again in memory first, so a photo
  that can't be read or encoded is untouched. APFS: hidden temp beside it + its extended attributes
  (the carried tags, "where from") + rename; exFAT: written into the file in place (no rename on exFAT,
  CLAUDE.md #12). The modified and created dates are put back, so Safe Finder drops those thumbnails
  itself (`Thumbnails.forget` — its cache key is path + modified date). Not carried by Pillow: HDR gain
  maps (HDR photos come out standard range on the Mac) and a JPEG's extra MPF pictures.

## 6j. Folder tags — `FolderTags.swift`, `mac/safe_finder.py` (Oct 29, 2026)

A folder carries tags of its own. Its path is a key in `Library.tags` and in the drive's shared tag file
like any file's, so nothing new had to be built for it to sync, re-key on move/rename (`itemsMoved`
re-keys a folder's own path as well as its subtree), survive the trash, or show up in the Tags filter
(`taggedPaths` → `labeledEntries` hands back folder entries from the index; tap one to open it).

- **The question.** Whenever a tag goes on folders — or comes off — the person is asked whether the files
  inside them (any depth; hidden files and the downloaders' sidecars left out) change too: "Folder and
  Items Inside" / "Folder Only" / Cancel. Only the files the change would touch are counted, and when there
  are none nothing is asked. iPhone: `Library.folderTagQuestion` + the `folderTagPrompt` alert, from the
  folder long-press Tags menu, the selection bar, "Add Tag…" and the folder's Get Info (`TagEditor`'s
  `onChange`); files inside come from the drive index (`filesInside`), else a walk. Safe Finder:
  `ask_inside` from the right-click Tags menu, ⌘T (asked before the window opens — it then works on the
  folder, or the folder and its files), Remove All Tags and drops on a sidebar tag.
- **Carried.** A folder carries the `com.photobrowser.tags` marker like a file (not on exFAT), so a folder
  moved by Finder or Files keeps its tags: Safe Finder squares folders too when a folder is opened
  (`check_carried`, `read_folder`), and the app's `adoptCarriedTags` now includes folders new to the
  index. Safe Finder's transfers report placed folders (`Transfer.placed`), so a moved or copied folder
  — and its subfolders — keep their own tags.
- **Shown.** Safe Finder: the tag pill on folder tiles, chips in the list view, the status line, the
  sidebar counts and tag collections. iPhone: checked in the Tags menu, in folder Get Info, counted in
  the Tags chip, and listed in the Tags filter. (iPhone tiles show no tags for files either.)

## 6k. Safe Finder video thumbnails — `mac/thumb_helper.swift` (Oct 29, 2026)

Video thumbnails used to come only from `qlmanage`, a dozen files per run on one thread: Quick Look
started afresh for every run and nothing appeared until the whole dozen was done, so a folder of videos
filled in slowly. Now `_FrameRunner` keeps `thumb_helper.swift` running (built once with `xcrun swiftc
-swift-version 5` into `~/Library/Caches/PhotoBrowser/`, like the AirDrop helper; bundled as a resource in
the .app) and talks to it in JSON lines: AVFoundation frames (a tenth of the way in, at most 1 s; HDR
tone-mapped) and ImageIO previews (RAW), written as JPEGs straight into the thumbnail cache.

- At most 4 in flight; each result shows at once. On-screen requests go first, newest first; prefetches
  wait 0.2 s (so a fresh listing's first paint beats a prefetch queued before it) and are dropped once
  their listing is left. A prefetch that becomes visible is promoted.
- Fallbacks to Quick Look (now 4 files a run, so it streams too): while the helper builds, without
  Xcode's tools, for a file the helper can't read, after 30 s on one file, or when the helper keeps dying
  (10 restarts). Files in flight when it died are retried one at a time, so only the culprit goes without.
- Tested with a stand-in speaking the same protocol (`SAFE_FINDER_THUMB_HELPER` names one); the Swift
  itself is built on first use on the Mac.

## 6l. Safe Finder AI Upscale 2× — `mac/ai_upscale.py`, `mac/upscale_window.py` (Oct 30, 2026)

True AI upscaling on the Mac: Real-ESRGAN (realesrgan-ncnn-vulkan, Vulkan via MoltenVK on the GPU), local
only. The engine isn't shipped — it's found in the free Upscayl app (searched inside the bundle for
`upscayl-bin` and any folder of `.param`/`.bin` models, since Upscayl's layout isn't documented), in
`~/Library/Application Support/Safe Finder/Real-ESRGAN`, on the PATH, or picked by hand (QSettings
`upscale/engine`). Model: `PREFERRED` order (upscayl-standard-4x, realesrgan-x4plus, …), never anime /
digital-art. The network's 4× result is Lanczos'd to exactly 2× (`-s` must match the model's own factor).
Saved through `batch_crop.open_upright` / `encode_like` / `write_in_place` (split out of the crop's
`render` for this), so format, EXIF, ICC, XMP, the tag marker and dates are kept; tagged "upscaled".
Over 12.3 MP is skipped (the 4× pass would be ~200 MP). Asked first (in place is irreversible).

Considered and not used: Apple's VideoToolbox ML super-resolution (`VTSuperResolutionScalerConfiguration`,
input type image) — built in, but stills are limited to 1920 px tall on macOS (tiling needed) and its API
couldn't be checked from the sandbox this was written in; worth revisiting for a no-install path (and for
the iPhone, whose "AI Upscale" is Lanczos + denoise + sharpen, not a network).

## 6m. Safe Finder: each folder's own look, and the freeze in big moves — `mac/safe_finder.py` (Oct 30, 2026)

**View memory (`FolderViews`).** Every place a pane shows keeps the look it was last shown in — mode
(icons/list) and sort — recorded when a pane leaves it (and on every explicit change), restored when a
pane arrives (`Pane.go` / `_show_results` → `_restore_view`). Recording on *leave* is the point: a folder
whose look was only inherited still has to come back that way after Back, which "remember explicit
choices only" gets wrong. A place never shown inherits the look on screen. One store for both panes,
in QSettings `views` (JSON, last 1,000, LRU; search results session-only); collections keep the
results sort, folders the folder sort. `{role}/mode` / `{role}/sort` stay as the pane's current look.

**The freeze.** Moving many *loose* selected files: each top is trashed as it finishes, every removal
shrank the selection, and each `selectionChanged` ran `update_actions` + `update_status` synchronously
— both re-reading the whole selection (`os.path.isfile`/`getsize` per item, plus an O(n²)
`p not in files`). Measured offscreen, 1,500 selected 2 KB files: the window couldn't take an event for
**44.8 s** (the copy itself took 14 s); now the longest stall is ~0.3–0.9 s and the run takes ~6 s.
Fixes: `selection_changed` is coalesced (60 ms); `Pane.selection()` reads paths, kinds and sizes from
the model in one pass over the selection's row ranges (no disk); a move clears its originals from the
selection when it starts (`MainWindow._deselect`); transfer progress and log lines are batched to the
panel (200 ms — `QProgressBar.setValue` repaints the whole window synchronously); free space is read
at most every 3 s; a folder's sizes/thumbnail prefetch run once per burst of `directoryLoaded` (which
QFileSystemModel emits on every re-list of a changing folder — once a second while `TRANSFERRING`);
folder-size results re-sort/re-filter once per burst, not per folder; `check_carried` stands aside
while a transfer runs (re-run after); `TagStore.forget` makes one pass per table (5,000 trashed paths
against a 22,500-key table: 4 s → 44 ms, on the UI thread at the end of a move). What's left under a
~300 files/s stress is Qt re-listing and repainting both panes; real photos arrive far slower.
Checked and ruled out offscreen: the thumbnail pool and the GIL switch interval made no measurable
difference.

## 6a. WebM playback — `WebMPlayer.swift`

AVPlayer, AVAssetImageGenerator and QuickLook can't open WebM on iOS; WebKit can (VP8/VP9/AV1,
iOS 17+). `.webm` is classified as video (`webVideoExtensions`) and:
- **Viewer:** `PageView` routes it to `WebMPage` — a `WKWebView` with WebKit's own controls
  (autoplay, loop, inline) plus the viewer's swipes (L/R next/prev, down close, up info) added as
  simultaneous `UISwipeGestureRecognizer`s. The AVPlayer-only extras (frame step, slo-mo, zoom,
  frame capture) don't apply to WebM.
- **Bytes:** served by `WebMMediaSchemeHandler` (`pbmedia://media/<name>`), not `file://` — the
  web-content process can't be relied on to read a security-scoped file on the external drive,
  and copying a big video into the sandbox first is slow. It answers Range requests with bounded
  206 slices (8 MB) and plain requests with a chunked 200, all file I/O on a background queue.
- **Posters:** `Thumbnailer.generate` → `WebMPoster.poster` (nonisolated entry, hops to main):
  one offscreen `WKWebView` at a time, parked invisibly in the key window (WebKit may not load
  media outside a window), autoplays muted, seeks ~1 s (10 % of short clips), draws the frame to a
  canvas → JPEG data URL; 15 s timeout. Cached like every other thumbnail.
- Other AVFoundation features (Video Editor import, trim, bulk rotate, frame export, duration
  badge) don't support WebM.

## 6f. Home-wide filters, Any-tag matching, upscale queue (Oct 23, 2026)

- **Home looks through the whole drive.** At the root, a Type / Format / Resolution / Year / Location /
  Edited / Categories filter switches `filteredRaw` to `deepMedia` — every file in `library.index`, in
  the current sort — instead of the top level's own listing (`deepFilterActive`; tags, age, favorites
  and search already covered the subtree). The loaders follow: specs/places/capture dates run over
  the deep list (missing entries only, merged in), the Year menu at Home triggers a drive-wide
  capture-date pass (`deepYearsRequested`, mostly cache hits — the index build prewarms them), the
  Location menu at Home reads the whole drive's places (ceiling 200k files instead of 8k), and
  Categories at Home stat every folder in the index (`deepGalleryFolders`, via `labeledEntries`) so
  galleries two levels down are found (from the index's own `gallery.json` entries — no stats).
  First passes over an unindexed set (resolution, places) are slow by nature; repeats are cached.
  **The pass runs off-main** (Oct 23, later the same day): doing the sift + sort of 100k entries
  inside `filtered` on the main actor froze the grid, so `deepKey` drives a `.task` that snapshots
  the inputs (`DeepInputs`) and runs `deepFilter` detached; `filteredRaw` just returns
  `deepResults`. A banner under the chip bar (and the empty state) shows "Filtering the whole
  drive…" / "Reading capture dates / resolutions / places across the drive…" (`deepFiltering`,
  `deepStatus`) while it works; Home's years list is computed off-main too (`deepYears`).
  **The grid pages large results**: `displayed` is the first `visibleLimit` (400) of `filtered`
  and a footer that appears at the end draws the next page — a `ForEach` over tens of thousands
  of tiles re-diffed on every re-render is what made the result view lag. `filterSignature`
  (filters + sort, no counts) resets the page; All/None and drag-select still cover the whole
  `filtered`.
- **Match any.** The Tags chip's picker (`tagMatchAny`) switches `taggedPaths(under:tags:any:)` from
  "every tag" to "at least one"; the counts then are each tag's own (`tagCounts(under:)`), i.e. what
  choosing it adds. The header joins the tags with "or".
- **Tags from a long-press.** `tagMenu(for:)` serves both the thumbnail context menu and the
  selection bar: "Add Tag…" (one prompt, `tagTargets` says which items) first, then every tag
  alphabetically with a check when all targets carry it; `.menuOrder(.fixed)` stops iOS reversing the
  order when the selection-bar menu opens upward (which put "Add Tag…" at the bottom).
- **Search results select.** The navigation bar hides behind the active search field, taking the
  Select button with it; the chip bar now carries Select / Done / All while a search is submitted.
- **Upscales in the background.** `Library.enqueueUpscale` (`UpscaleQueue.swift`) runs one batch at a
  time as an activity (the progress pill), so the user keeps browsing; 1080p / 4K video upscales ask
  for the frame rate first (`askUpscale` → the Frame Rate alert → 30 / 60 / source; `MediaEditing.
  upscaleVideo(frameRate:)` and `enhanceVideo(frameRate:)` retime the composition — 60 from 30 repeats
  frames, no interpolation). Every upscaled item gets the "upscaled" tag; the in-place re-encode
  keeps its labels, caption and tags. Duplicate now returns (original, copy) pairs and
  `duplicateMetadata` carries every path-keyed store over to the copy.

## 6d. Appearance — `AppTheme`, `AppearanceView`, `Library.theme` (Oct 21, 2026)

Settings ▸ Appearance. `AppTheme` is one `Codable` value: `background` (`.solid(RGB)` or
`.gradient([RGB], Direction)`), `accent` (RGB), `typeface` (`FontChoice`: the four system designs
plus nine iOS families by PostScript name), `light`. `Library.theme` holds it (`photoBrowser.theme`
JSON; `setTheme` saves and pushes the family into `UINavigationBar.appearance()` — the proxy only
reaches bars made afterwards, so an existing title changes after a relaunch). Where it shows:
`AppGradient` (the background under every browsing screen, now reading the theme), the app root
(`.preferredColorScheme`, `.tint`, `.fontDesign`, `.environment(\.font)` for custom families), the
chip bar (`chip()` → `theme.font(.subheadline)`) and every former `Color.accentColor` in
`FolderView`. System designs reach every label through `.fontDesign`; a custom family reaches
titles, chips and un-styled text only — smaller labels keep the system font on purpose. Presets live
in `AppTheme.groups` (Everyday, Halloween, Christmas); `matchingPreset` names a custom choice that
equals one. The viewer stays black regardless.

## 6e. Multi-select responsiveness — `Memo` (Oct 21, 2026)

Every selection tap re-renders `FolderView`, and `filtered` (the whole filter/sort pipeline),
`igBubbles`, `tagOptions`, `locationOptions`, `availableYears` and `categoryOptions` were all
computed properties — recomputed per render, `filtered` twice (grid + the toolbar's All/None
label). They are now memoized in `Memo<T>` objects (`Models.swift`: a one-slot cache in a plain
class held by `@State`, refilled inside `body` without triggering another render) keyed on
everything they depend on: `entriesVersion` (bumped at every `entries =`), the library counters
(`changeToken`, `labelsVersion`), every filter/mode, and the counts of the derived dictionaries
(`fileSpecs`, `captureDates`, `placeLabels`, …). If a list ever looks stale, the key in
`filterKey` is missing an input — add it there rather than removing the memo.

**Cell frames out of @State (Oct 23).** Every visible tile publishes its frame through a preference
(for drag-select hit-testing), and that preference fires on every scroll tick. It used to land in a
`@State` dictionary, so each tick re-ran the whole `FolderView` body — every filter, memo key and the
grid — which made scrolling and anything timed against it sluggish in every folder. The frames now
live in a plain reference (`CellFrameStore`, `frameStore`), read only by `dragIndex(at:)` and the
auto-scroll step (which also uses the drag's index map instead of a linear search per visible cell).

## 6g. Safety, main-thread and viewer pass (Oct 25, 2026)

Implemented from the improvement report's top items.

- **No Tags showed tagged files as untagged (and dropped their hearts).** No Tags is built from the
  whole-drive `index`, and the index was only rebuilt at launch: a file moved or renamed mid-session
  kept its old path there while its tags, favorite and caption followed it to the new path, so No
  Tags listed the stale path as "untagged" with no labels. The index now follows every change
  (`noteIndexChange` re-reads the folder a `contentDidChange(under:)` names; `remapIndex` moves
  entries with `itemsMoved`), its walk spells every path under the root's own spelling (the
  enumerator can return `/private/var/…` for `/var/…`), and label lookups compare via
  `Library.canonicalPath`. Launch re-walks only folders whose modification date moved
  (`incrementalWalk`); a full walk still runs on exFAT, every sixth walk and after three days,
  because a file edited in place keeps its folder's date. The snapshot moved to Application Support.
- **Every Delete is reversible.** `Library.trashItems` is the one Delete (grid, viewer, Find
  Duplicates, Compare PNGs, Clean Up); the viewer used to delete for good and also delete the iOS
  Photos original. `restoreTrashed` copies labels onto a renamed restore.
- **DriveWriter sweep.** Frame export (`writeDataSync`), audio extraction, trim and combine (export to
  `DriveWriter.tempURL` then `commit`), metadata backups and `DriveWriter.copyItem` (temp + rename)
  no longer write straight to a final drive path; the photo editor's temp is `.pbtmp_…` and flushed.
- **Main thread.** `MetadataLoader` is `nonisolated` (its cache lookups no longer hop to main from
  the bulk passes); the bulk loaders in `Library` are `@concurrent`; `cachedCaptureDates` /
  `cachedMediaSpecs` answer the known files in one pass so tasks start only for misses; the folder's
  re-sorts and Live Photo pairing run detached.
- **Grid.** `EntryCell` is `Equatable` (wrapped in `.equatable()`), so a selection tap redraws the
  tiles that changed; tiles draw `Thumbnailer.cached(for:)` on their first frame; auto-picked folder
  covers are encoded off-main and published in one batch every 300 ms.
- **Saves.** Per-tap stores save through `scheduleBulkSave`; bulk favorite/To AI/caption use the batch
  setters (`setFavorite(_:for:)`, `setAI`, `setCaptions`); the remaining `UserDefaults` stores moved to
  `FilePrefs`.
- **Viewer.** Opens on the grid tile, decodes at the screen's native size (`fitPixels`), and swaps in
  a sharper decode (≤ 24 MP) once a zoom settles past 1.3×; the video the viewer opens on shows its
  tile as a poster until `isReadyForDisplay` — only that one (Oct 30): after a swipe a video starts on
  black and its own first frame, because the small tile (a frame Quick Look picked, not the first)
  stretched full-screen and cross-faded into a different picture made every swipe look smeared. A
  bottom bar carries Share, Favorite, Info and Delete.
- **Tile menus are built with the tile** (Oct 30). SwiftUI evaluates `.contextMenu`'s items whenever it
  builds a tile, not when the menu opens — so the Tags submenu's `library.allTags` (a pass over every
  tagged file, twice) ran for each tile that scrolled into view, and grew with every tagged download.
  The tag names are memoized on `labelsVersion` (`FolderView.tagNames`); keep per-tile menu work O(1).
- **Status.** Confirmations are toasts (`showToast`); failures are notices titled with what failed;
  the activity pill opens a sheet with each job's progress and Stop (upscales); a "Drive disconnected"
  banner shows when the drive vanishes mid-session (checked every 4 s) and clears when it returns.

**Follow-up (Oct 25): dull tiles, sort order, HDR screenshots.**
- *Dull, shadowed tiles* had two causes. `isDimmedHidden` drew any file with size 0 at 45%, including
  files whose size was never read (every file in a folder over 8,000 items; any file the drive
  refused to stat) — it now makes `applyHidden`'s exemption. And HDR stills (the 10-bit PQ HEICs that
  crop/rotate, the photo editor and frame capture save) came back from ImageIO in their HDR colour
  space and were cached as HDR-tagged JPEGs that drew flat and dark: thumbnails now decode with
  `kCGImageSourceDecodeRequest: DecodeToSDR`, anything still HDR (an HDR video's QuickLook poster) is
  redrawn as 8-bit Display P3 (`Thumbnailer.standardRange`), and a cached thumbnail found HDR-tagged
  is deleted and regenerated — only those. Storage ▸ Clear Caches rebuilds the rest if one slips by.
- *Default didn't sort by capture date.* `sortEntries(.smart)` orders files by modified date (when they
  landed on the drive); only a plain folder of ≤ 8,000 items re-sorted by capture date, after a flash.
  Every list now sorts with `Library.sortEntriesByCapture` — the dates already in the persisted store
  (filled for the whole drive by the index build), no file reads — so Favorites, Tags, No Tags,
  search, Home's filters and a folder's first paint are in capture order; huge folders look their
  dates up through the index (`knownCaptureDates(forUnstattedEntries:)`). Files with no embedded date
  still use their modified date.
- *HDR screenshots a little too bright.* A captured frame keeps none of the Dolby Vision metadata the
  player tone-maps with, so highlights showed at full strength. Screenshots (not bulk frame export)
  now ease highlights to 3× SDR white with `CIToneMapHeadroom` (iOS 18+) and trim 0.15 EV (0.3 EV on
  iOS 17): `FileActions.hdrFrameHeadroom` / `hdrFrameExposureTrim` to tune.

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

**Only new content, never a second copy (Oct 28, 2026)** — Instagram and TikTok alike. After
"Reconnect Profile Folders" a record can come back from a backup older than the files in its folder
(or be rebuilt from them), and "Get New" used to dedup against the record alone: everything downloaded
since that backup came down again — Instagram even saved it beside the original as "name 1.jpg". Now:
- **Every run skips the record's ids *and* what's in the folder** — `Library.postIDsOnDisk(in:tiktok:)`
  (`ProfileReconnect.swift`) reads the post ids from the downloaders' file names in the folder and its
  subfolders (highlights, Stories, folders the user sorted things into, DUPLICATES), 3 levels, hidden
  and `@` folders skipped; for Instagram both forms of `<stem>_<n>` are taken (carousel item, or a
  shortcode that ends in `_<digits>`). Used by the single Instagram run (`InstagramImportView`), the
  bulk run (`startBulkInstagramDownload`), the stories sweep (`AllStoriesView.fetchStories`) and TikTok
  (`TikTokImportView`, which also writes the found ids into the record first — `addKnownTikTokIDs`;
  Instagram's `InstagramApply.apply` already stores `already ∪ newIDs`). The stop-early paging and
  TikTok's full-scan check see the true set, so a reconnected profile pages only to its newest post.
- **A file already in place is never fetched again.** Instagram's `download(jobs:)` drops a job whose
  `<name>.jpg/.mp4` exists (not on Re-download Entire Profile) and records its id as done; TikTok
  doesn't enqueue a video or slideshow image whose file exists (filing already dropped a landed dupe).
- **One folder per profile.** Starting a download where the profile already lives reuses its folder,
  whatever it's called or however it's capitalised: `resolveIGDestination` (now records-only, no drive
  I/O, also used by the single run) and `tiktokDestination(in:handle:)`; TikTok from *inside* its
  `@handle` folder used to make `@handle/@handle` and download the whole profile again — it now runs
  in place, prefilled ("Get New TikTok Videos" shows there too).

**When Instagram refuses the app's requests — the logged-in browser takes over (Oct 28, 2026).**
"Couldn’t open @jenselter" for a public profile while logged in: Instagram ties a login to the browser
that made it, and the app's own `URLSession` calls (fixed cookie header, its own TLS stack, the desktop
app id with an iPhone UA, an old `X-ASBD-ID`) can be answered 401/403 "log in", or with the login page,
even though the session is fine. Now:
- **`apiData` asks again from the browser** when a call is refused (400/401/403, `require_login`,
  a checkpoint, "useragent mismatch", HTML where JSON belongs): `InstagramWebFetcher` keeps a hidden
  `WKWebView` (the login's cookie store and UA, parked behind the app like `TikTokWebFetcher`) on
  `www.instagram.com/robots.txt` — same origin as the API, no Instagram script running — and sends the
  call with `fetch(…, {credentials: 'include'})` plus the headers the web app adds (CSRF from the
  cookie, `X-IG-WWW-Claim` kept in sessionStorage, the app id read from the home page Instagram serves
  that browser). Once the browser is let in, every call goes that way for the rest of the app run
  (`APIRoute`); the plain path stays first otherwise because it keeps working in the background, which
  the web view doesn't. All `api/v1` calls (profile, feed, tagged, clips POST, stories, reels tray,
  highlights, media info) go through `apiData`.
- **The real reason is shown.** `lookupProfile` returns the profile or a sentence: no such account
  (`web_profile_info` 404), or Instagram's own message and status with what to do (log in again,
  finish the "is this you?" check, wait out a limit). `run` puts it in `note`; the import view shows it
  instead of the generic line, and its login button stays available while logged in ("Log in to
  Instagram again") since a dead or challenged session still has its cookie.
- **Exclusive (subscriber-only) content** comes from the same session: posts without a shortcode are
  keyed by pk, separately-keyed exclusive story reels come from the reels tray, and media that a public
  profile's anonymous download is refused (subscriber-only media is gated even there) is fetched again
  with the session — now including the DASH video+audio pair (`dashPair`), so an exclusive video keeps
  its best rendition rather than dropping to the progressive stream.

### 7.4d SimpCity threads — `SimpCityService.swift` / `SimpCityRecord.swift` / `SimpCityHosts.swift` / `SimpCityImportView.swift`, `mac/simpcity.py` / `mac/filehosts.py` / `mac/simpcity_downloader.py` (Oct 28, 2026)
"Download from SimpCity…" on a person's folder (iPhone: the download menu; Safe Finder: right-click a
folder, or the empty area of one): paste a `simpcity.cr/threads/…` address; every page is read, each
goonbox.cr image is saved full-size and — with **Download videos** on — each turbo.cr video and every
video the posts link on pixeldrain, gofile, cyberdrop, bunkr, filester and fileditch, into
`<person>/simpcity`, tagged "simpcity". Neither app ever fetches what the other already has, and a video
posted on several hosts is fetched once.
- **One record, on the drive.** `<person>/simpcity/.simpcity.json` (`format: photobrowser-simpcity`):
  `items` (`goonbox:<id>` / `turbo:<id>` → file, post id, post time), `threads` (address → title, last
  page read, when), `failed` (not downloaded yet — retried by the next run even when it doesn't re-read
  that page). Both apps read it before a run and merge it on every save (handled as plain dictionaries,
  so neither drops the other's fields). Files are `<id>.<ext>`, so a file already in the folder counts as
  done even if the record lost it; one deleted from the folder stays deleted. "Get New" starts at the
  last page read ("Read every page again" for all).
- **Real browser, by necessity.** simpcity.cr sits behind DDoS-Guard and shows thread content only to
  logged-in members (logged out, a thread is the login page); goonbox.cr is behind Cloudflare; the
  bunkr-family file servers turn away non-browser clients (§7.1). So pages are read in WebKit (iPhone)
  / Qt WebEngine (Mac) with a persistent cookie store, in a view the person can see: they log in once and
  answer any "you're human?" check there. Nothing works around a check — a check a hidden page meets is
  shown to the person (iPhone: only while the SimpCity screen is open; with it closed, the run stops
  with the record saved and says so). Files are fetched by the browser too (`WKDownload`; Chromium's
  `page.download`, with a plain-request fallback that carries the browser's cookies and UA).
- **Reading a page** (`EXTRACT_POSTS_JS`, kept byte-identical in Swift — a test checks): XenForo
  `article.message` posts, the post time from `time[data-time]` (else `datetime`, whose `-0400` offset
  Safari can't parse without a colon), links/`data-url`/`img`/iframes inside `.message-userContent`,
  skipping quotes and signatures, unwrapping `/redirect/?to=<base64>`; the last page from the page nav.
  A read only counts once the view is on *that* page (else it can return the page before).
  **Answers travel as JSON text** (`json_call`: `JSON.stringify` inside a try, `{error}` when the script
  throws) — an object handed through Qt's `runJavaScript` can arrive as nothing, which made every read
  time out ("Couldn't read page 1", Oct 28). **A page still loading after 12 s is read as it stands**:
  SimpCity's tracking scripts can keep a page from ever reaching `complete`. Posts are
  `article.message, .message--post, li.message` (the old crawler's proven selector). A "checking your
  browser" page counts only when no forum page (`.p-body`) is under it. A failed read says what the page
  showed (title, address, posts, page, load state — `describe_page`).
- **goonbox → full size**: its viewer is a script app over a JSON API — `GET /api/images/<id>` →
  `image.original_url` (found by the earlier crawler; the post's `img` is a thumbnail with a different
  UUID, so the full file can't be derived). Asked with `fetch` from a goonbox page in the lane, so one
  page load serves every image after it. Fallback: what the page shows once built (download link,
  `og:image`, the largest picture), thumbnails (`.md.`/`.th.`/`/thumbs/`) never taken.
- **turbo**: posts carry `turbo.cr/embed/<id>`; the player is built by script, so the lane page (muted
  autoplay allowed) is nudged to play and the mp4 it loads is taken (`<video>`, or the page's resource
  timing). HLS-only (m3u8) players aren't handled. goonbox albums (`/a/<slug>`) aren't expanded.
- **Downloads: a plain request first, the browser second** (Oct 28). The image server
  (`simp*.cuckcapital.cr`) answers plain requests — the earlier crawler fetched it with `requests`, no
  Referer or login — so `simpcity.fetch` / `SimpCityDownloader.fetch` (20 s to answer, 10 min a file)
  goes first, with the goonbox page as Referer; only a refusal falls back to the browser (Chromium
  `page.download` from the window's page, matched by address as well as name, 20 s to start; WebKit
  `WKDownload` on the iPhone). The first Safe Finder runs had it the other way round: Chromium's
  download never reported back from a view-less lane page, so every file waited out a 30 s watchdog
  ("pretty slow"), and the fallback then asked the browser profile for its User-Agent **from a worker
  thread** — Qt WebEngine objects belong to the GUI thread, and the call hung (Erin Gilfoy: 809 files,
  nothing in 5 minutes). Everything a worker needs (UA, cookie header) is now read on the GUI thread
  first. A failed download is logged with the address and why (the first three per server), and the
  summary counts failures by server with the last reason. The first three resolved addresses are logged.
  **The image servers need goonbox's Referer** (checked Oct 28): `simp1/simp2/simp6.cuckcapital.cr`
  answer a request without one with 403 `{"success": false, "message": "not allowed"}` — even a signed
  `/panda/…?s=` address — and serve the original (unsigned `original_url`) to one with
  `Referer: https://goonbox.cr/`. The plain request sends it (`simpcity.REFERER`); Chromium's own
  downloads send none, so Safe Finder's profile has a request interceptor (`_Referer`) that adds it for
  those hosts. A browser download that comes back **interrupted** can stay "resumable" and never count
  as finished — with only a "never started" watchdog that hung the run (Erin Gilfoy, second try) — so an
  interruption or cancel now ends it, and a started download has a limit too (2 min a photo, 15 a video).
  HTTPS for the plain request falls back to the Mac's `/etc/ssl/cert.pem` when Python has no
  certificates of its own (`ssl_context`).
  **Nothing may wait forever, and the log says what's happening** (third Erin Gilfoy try: files resolved,
  0% for minutes, nothing logged — the lanes were most likely queued behind a kept-open ExifTool that
  never answered, the one piece only tested against a stand-in). `ExifSession` now reads with `select`
  and a 30 s limit (`TIMEOUT`); a silent ExifTool is killed and the call made with a one-off ExifTool,
  and after two failures the run stays one-at-a-time (said once in the log). Every saved file gets a log
  line (name, size, which date, upscaled); a worker step still running after 60 s logs "still working
  on …" with what it is; the progress bar ("N of M") sits beside the status line.
- **Reading long threads without tripping SimpCity's rate limit** (Oct 28: a 60-page thread read back to
  back got "too many requests"). Pages are read `PAGE_GAP` (2 s) apart plus up to 1 s of jitter.
  `EXTRACT_POSTS_JS` reports `limited` — the navigation's HTTP status is 429
  (`performance` navigation timing `responseStatus`; Chromium only), or the page says "too many
  requests / rate limited / error 1015 / slow down / must wait at least" with no posts on it (a post
  that merely mentions a rate limit doesn't count; a DDoS-Guard check is still a check for the person).
  A limited page is waited out (`LIMIT_WAITS` 30/60/120/240/300 s) and read again, and the gap doubles
  for the rest of the run (to `MAX_GAP`, 12 s). When the waits run out — or a page won't load, or Stop —
  the read is **cut short but kept**: what pages first…N hold is downloaded, and a read from page 1
  records `threads[…].resume = N` so the next run carries on from page N (`full_read` / `fullRead`
  covers misdated entries, the host-link re-read and a resumed read alike); `hosts` and the misdated
  clean-up (`redate(read_all)`) only count a read that got to the end. Files found before a Stop are
  kept in `failed` for the next run (they used to be dropped with the pages they came from). Nothing
  read at all → "SimpCity says too many requests — wait a few minutes".
- **Lanes** (Mac 6, iPhone 4), each its own hidden page, so a check shown in the visible view never swaps
  a page under a lane; an answer is only accepted from the lane's own page (`href` contains the id).
  Polls run every 250 ms (80 ms for the goonbox API answer), and the Mac keeps **one ExifTool open for
  the whole run** (`ExifSession`, `-stay_open`) — a fresh process per read/write had cost about a second
  a file.
- **Dates.** A file that carries its own capture date keeps it (the fields the app sorts by:
  EXIF DateTimeOriginal/Digitized/TIFF DateTime; a video's creation date). Otherwise the post's date is
  written into it — iPhone: `CGImageDestinationCopyImageSource` (metadata only, no re-encode; JPEG/PNG/
  HEIC/TIFF — GIF/AVIF get file dates only) and a passthrough remux for video, on the temp copy
  before it goes to the drive; Mac: ExifTool (EXIF dates; QuickTime + `Keys:CreationDate` for video),
  file dates only when ExifTool isn't installed. File dates follow the capture date either way.
  **The post time is `data-timestamp`** (XenForo 2.2+), else the ISO `datetime`, else an all-digits
  `data-time` (older XenForo). The first downloads (Oct 28) read 2.2's `data-time` — a label like
  "12:34 PM" — as a number and wrote 12 s after 1970 (12/31/1969 in US time) into 33 files. Now a time
  before 2000 is no date, an embedded date up to 1970 doesn't count as the file's own, and a record with
  such entries (`misdated`) has the thread read from page 1 again: `fixes` rewrites those files with
  their post's real date where they lie, and `redate` corrects (or, post gone, zeroes) the record.
- **Photos: WebP → JPEG, small → 2×.** A WebP becomes a JPEG (quality 95, transparency on white, EXIF
  and colour profile kept; animated WebP left alone), and a JPEG/PNG/WebP under 250 KB is upscaled 2×
  with Lanczos (Mac: Pillow `LANCZOS`; iPhone: `CILanczosScaleTransform`) and tagged "upscaled" like the
  app's own upscales — on the temp copy, before the date rule (`prepare_image` / `prepareImage`).
  Record entries carry `made: 2` once under these rules; earlier ones still in the folder are brought up
  to them once, beside the new downloads (`fix_file` / `fixFile`: a copy prepared and committed back,
  the tag attribute kept; a WebP's new `.jpg` takes its tags — Safe Finder `carry`+`forget`, iPhone
  `itemMoved` — and the `.webp` goes).
- **Videos on file hosts** (Oct 28, `filehosts.py` / `SimpCityHosts.swift`, kept in step — same keys,
  ids and preference order; the page scripts byte-identical). A post's host link is a `Link` (a file or
  a folder: `pixeldrain /u/ /l/`, `gofile /d/`, `cyberdrop /a/ /f/ /e/`, `bunkr(.cr/.ws/.ru/…) /a/ /f/ /v/
  /i/`, `filester(.gg/.me) /d/ /f/`, fileditch `file.php?f=…`, `fileditchstuff` direct links,
  `fileditchvids.st`). Links are **listed before any download** — the lanes take them first — into the
  videos in them (`Remote`: name, and for most hosts the exact size; pixeldrain also the SHA-256);
  photos, archives and anything else in a folder are left alone. Saved as `<host>-<file id>.<ext>`,
  keyed `<host>:<file id>`. How each host is read: pixeldrain's public API (`/api/file/<id>/info`,
  `/api/list/<id>`, file `/api/file/<id>?download`); **gofile only through its own site** (below);
  cyberdrop's album page `/f/<id>` links → `api.<host>/api/
  file/info/<id>` → `auth_url` (asked just before the download — it doesn't last); bunkr's album
  `albumFiles` list (or `/f/` links) / a file page's `data-file-id` → `apidl.bunkr.ru/api/_001_v2`
  (base64 XOR'd with `SECRET_KEY_<ts/3600>`, the maintenance clip refused), also just before the
  download. **filester and fileditch have no public API** (filester's REST API wants an account key;
  fileditchfiles.me is behind Cloudflare), so their pages are read in a lane: `HOST_PAGE_JS` takes the
  video a page plays (muted autoplay), has loaded, or links, and — on a folder — the pages of the files
  in it; a file page showing nothing gets its **Download button pressed** once (`CLICK_DOWNLOAD_JS`,
  never "app"/"premium"/sign-up buttons) and the file it then plays, links, or hands the browser is
  taken by address (Safe Finder: `downloadRequested` from that lane page, cancelled; iPhone: the lane's
  navigation delegate). A host whose API answers with a check page, or fails, goes the same way (a
  folder's page is listed; a file's page is read at its turn). The browser download of a host file
  carries its page as Referer (Safe Finder: the interceptor's `by_url`; iPhone: the request) and gofile's
  cookie. A dead link (404 / "not found") is done; a folder that couldn't be listed is tried again next
  run; a failed video's link stays not done and is listed again (a video it no longer holds is done).
- **gofile: the site's own listing, never our own request** (Oct 28, after the first real run: every
  folder answered `401 error-notPremium`, then `429 error-rateLimit`). The website token is made by the
  site's `wt.obf.js` with a secret gofile **rotates server-side**, and its `core/wt.js` says a request
  signed with a retired secret gets the **IP banned on the spot** (the page itself refuses to sign after 6
  hours open). A re-implemented token (the fixed salt `LinkDownloadService` also had — now removed there
  too; its gofile links return a note) is exactly that. So: `CAPTURE_JS` / `captureScript` is injected
  before the page's own scripts (Safe Finder: a profile `QWebEngineScript` at DocumentCreation, main
  world; iPhone: a `WKUserScript` at document start) and, on gofile only, keeps the answers of the site's
  own `/contents/` calls (`fetch` and XHR; it only reads them — the site still gets its answer, tested in
  Chromium); `HOST_PAGE_JS` turns them into files with name, exact size and id (and reports each call's
  status as `api`). gofile folders get **one lane, one folder at a time, 2 s apart**; a `429`/
  `error-rateLimit` means one 60 s wait and one more try, then gofile is left for the next run; a refusal
  (`401`, `error-notPremium`, …) stops gofile at once (`api_trouble` / `apiTrouble`). Downloads carry the
  site's own `accountToken` cookie (the browser profile's cookie jar). A folder over 100 files only gets
  what the site lists on its first page.
- **pixeldrain's hotlink lock.** pixeldrain marks much-downloaded files `availability:
  file_rate_limited_captcha_required` and answers a plain (or Chromium) download with 403 "hotlinking is
  only supported when either the uploader or the downloader has a paid subscription". Such a file is
  `locked`: it is ranked last when grouping copies and never claims its size, so any other host's copy
  (or turbo, or a browser-read host) is downloaded instead and the pixeldrain one recorded `same_as`. One
  no other host has is never fetched directly; after the lanes finish, each opens **in the visible
  window** (Safe Finder) / on the SimpCity screen (iPhone, only while it's open — otherwise the run's note
  says to open it), the person presses Download and answers pixeldrain's captcha, and the download that
  starts there is taken as it is (its `cap_response` address works once) — Safe Finder: the view page's
  `downloadRequested`; iPhone: the page's navigation delegate turns it into a `WKDownload` that
  `SimpCityFileDownload.adopt` saves. Nobody pressing Download within 4 minutes ends the step; that video
  and the rest are kept for the next run (reported as waiting, not failed).
- **Gone means gone**: a 404 page that says "removed by the original uploader / an Admin" (bunkr) is
  reported as deleted, not retried.
- **One video, one copy** (`Dedup`, both apps; thread-safe). The same clip is routinely posted on
  gofile + pixeldrain + bunkr at once. Three checks, all by the bytes as downloaded (the record's `size`
  and `sha256` are taken **before** the date is written into the file, so another host's copy compares
  equal): (1) **sizes up front** — the hosts that say a size (pixeldrain, gofile's listing, cyberdrop, bunkr albums)
  are grouped by exact size (≥ 1 MB; two different videos of one exact size that big don't happen), the
  copy on the preferred host (pixeldrain > gofile > cyberdrop > turbo > filester > fileditch > bunkr) is
  queued and the others **wait on it**: recorded `same_as` it once it's saved, tried in its place if it
  fails (and then the failed one is recorded as the mirror that worked); a size equal to a video
  downloaded before is `same_as` at once; (2) **as a download starts** — the size the server gives
  (`Content-Length`; Chromium's `totalBytes`; on the iPhone a one-byte `Range` request first, headers
  only) is checked the same way, which catches turbo and the browser-read hosts; (3) **once it's in** —
  its SHA-256 against every video kept (pixeldrain's own hash counts too); a match is deleted and recorded
  `same_as`. Videos recorded before sizes were kept seed the check with their file's size (right whenever
  their own date was kept). A host link that answers with a photo/archive is `skipped` ("not a video").
- **Download videos** (Safe Finder checkbox, `QSettings`; iPhone toggle, `photoBrowser.simpCityVideos`;
  on by default). Off: turbo items are noted in `failed` with `skipped`, host links in `links` with
  `skipped` — so a later run with it on gets them without reading the thread again. A thread read before
  host links were collected (`threads[…].hosts` unset) is read from page 1 once when videos are on; a
  run that reads to the end (from page 1, or on top of such a read) sets it.
- **Record additions** (both apps merge them; the merge is additive like the rest): `links` (link key
  `<host>:<file|folder>:<id>` → url, post, posted, `files` (its videos' keys), `done`, `why`/`gone`/
  `skipped`; done on either side wins), item fields `size`, `sha256`, `via` (the link key), `name`,
  `same_as`, `skipped`. An older app that drops `links` only costs a re-listing.
- **Tags**: iPhone `library.addTag("simpcity", to:)` every 20 files and at the end; Safe Finder the
  shared tag store (`tag_store().add`) the same way.

### 7.4c taylorpictures.net — `TaylorGallery.swift` / `TaylorBrowserView.swift` (Oct 21, 2026)
Listing: the first page's pager gives the page count (`pageCount(in:pattern:)`), and the rest of a
section's album pages or an album's image pages are fetched six at a time (`fetchPages`) in page
order — it used to be one round trip per page. `images(inAlbum:onPage:)` streams each page's new
images so the album grid fills while listing. Downloading: 8 images in flight (was 4); the album
folder is **reused** and images already there are skipped, so running an album again only fetches
what's missing (it used to make "Title 1" folders and "name 1.jpg" copies); cancellation stops
cleanly. The browser has a `TaylorDownloads` queue (`@Observable`, app lifetime): albums are queued
from an album's page, a row's ↓ button, a swipe, or ⋯ ▸ "Download N Albums Here/Shown"; they come
down one after another under a `BackgroundTaskHolder`, progress shows in a bottom bar and as an
app-wide activity pill, the folder behind reloads after each (`onFinished`), and the browser is
never dismissed for you. Album lists are searchable (title or id). Everything heavy runs through
`Task.detached` (constraint 13).

### 7.4b TikTok — `TikTokService.swift` / `TikTokWebFetcher.swift` / `TikTokChallengeView.swift`
Profiles are listed and resolved through the public **tikwm.com** resolver (no login, no
request signing): `user/posts` pages the whole profile, the single-video endpoint gives the HD
watermark-free URL; the files themselves come straight from TikTok's CDN on a background
`URLSession`. **Oct 20, 2026: tikwm put its site and `user/posts` behind a Cloudflare *managed*
challenge ("Just a moment…", HTTP 403 + HTML) — only the single-video endpoint and the
`/video/media/…` redirects still answer plainly.** The first listing request of every run now
hits it. Handling: a plain request that gets 403/HTML goes to the hidden `WKWebView`
(`TikTokWebFetcher.fetchJSON`), which runs the challenge and banks `cf_clearance` + the UA it was
issued for, so the rest of the run uses `URLSession` again. When the challenge wants a tap
("Verify you are human") the hidden view can't give it one: the URL stays as
`pendingChallenge`, the import view says so and opens `TikTokChallengeSheet` — the same web
view, visible — and the moment the page turns into JSON the clearance is banked and the
download runs again by itself. The hidden view is kept **full-size behind the key window's root
view** (a 2-px view reads as no browser; a view outside any window gets its JS timers
suspended). If tikwm ever hard-blocks or moves the listing behind a login, that endpoint is the
only piece to replace — the resolve and download paths are unaffected.

**Download speed (Oct 21, 2026) — two lanes in `BackgroundDownloader`.** A background
`URLSession` runs out of process under the system's scheduling: a few transfers at a time, each
paced, so a profile of hundreds of videos crawled even with the app open. Now, while the app is
on screen, `enqueue` hands downloads to an in-process `fast` session (10 connections per host,
no system pacing); on `scenePhase == .background` `setForeground(false)` stops every fast task
with its resume data and re-queues it on the background session (`downloadTask(withResumeData:)`,
TikTok's CDN serves ranges), so "keeps going when you close the app" still holds; a fast task that
fails for a network reason gets one retry on the background session. Both lanes land files in the
same inbox; the downloader posts `BackgroundDownloader.landed` and the app files them at once.
`Library.processPendingTikTok` now does the inbox → drive moves in a detached task
(`fileTikTokRecords`) and applies captions / likes / the profile record on the main actor
(`applyFiledTikTok`), one pass at a time (`filingTikTok`), re-running if more landed meanwhile —
copying a video onto the drive used to block the UI. The listing and per-video HD resolve are
still paced at ~1 request/s: that is tikwm's limit, not ours.

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

### 7.6 Receive from the Mac — AirDrop archives (`ArchiveIntake`, `ReceivedArchivesView`, `mac/airdrop_to_iphone.py`) (Oct 22, 2026)

**Why.** Galleries downloaded on the Mac (`mac/pornpics_*.py`) used to reach the drive only by
plugging the SSD into the Mac (Safe Finder). AirDrop lets the SSD stay on the phone — but AirDrop
can't hand a folder to an iOS app, a Mac folder arrives on iOS as a zip, and a plain zip is claimed
by Files and every zip-capable app, so the phone would ask "which app?" each time.

**The route.**
- The Mac tool zips each folder into `<Name>.pbgallery` with the folder itself at the archive's top
  level (`Name/…`). Media is *stored* (already compressed), sidecars deflated, mtimes kept, Finder
  junk / `.part` skipped; archives land in `~/Library/Caches/PhotoBrowser/AirDrop/`. It then opens
  the Mac's AirDrop window through `airdrop_helper.swift` (NSSharingService; built once with
  `swiftc` — stock Python can't reach AppKit) and falls back to `open -R` + "Share ▸ AirDrop" when
  swiftc is missing. Exit codes: 0 sent, 3 cancelled, 2 unavailable. The pornpics browser's
  "AirDrop to iPhone" button, the star downloader's `--airdrop` (the galleries that got new photos
  this run + `pornstar.json`, as one archive of the star folder; `--airdrop-all` for all) and Safe
  Finder's "AirDrop to iPhone…" context item all call `archive_items`/`archive_folder` + `send` on
  a thread. `build_safe_finder_app.sh` bundles the tool and the helper source.
- `Config/Info.plist` declares the exported type `jayymei.PhotoBrowser.gallery-archive`
  (`.pbgallery`, conforms to `public.data`/`public.archive` — deliberately *not* `public.zip-archive`,
  so no other zip app claims it) as Owner, and `public.zip-archive` as Alternate (a folder
  AirDropped straight from Finder still works, via a chooser). An opened file reaches
  `PhotoBrowserApp.onOpenURL` as a `file://` URL (iOS copies it to `Documents/Inbox`) →
  `Library.receiveArchive` → `ArchiveIntake.stage` moves it into Application Support/
  `receivedArchives` (excluded from backup). The Inbox is also swept on launch/foreground
  (`refreshPendingArchives`), so an archive opened while the app wasn't running is picked up, and
  staging is the queue (`Library.pendingArchives`), so archives survive a crash or a dismissed sheet.
- `ReceivedArchivesView` (root-level sheet, `library.receivedSheetShown`) lists the batch — several
  archives arrive from one AirDrop — with a peek of each (`Archiver.peek`: single top folder,
  photo/video counts, size; central directory only, file mapped), one destination (`FolderPicker`;
  default: last used → the folder open in the app → root), and Merge / Keep both. Unpacking runs
  one archive at a time from `Task.detached` (constraint 13) under a `BackgroundTaskHolder`;
  `Archiver.unzip(dropTopFolder: true)` strips the single top folder so the result is
  `<dest>/<Name>/…`, never `Name/Name/…`. Success deletes the staged archive; failure keeps it listed
  (and removes a folder *we* created, never a merged-into one). "Later" keeps the queue; Settings ▸
  "Received Archives (N)" (shown only when non-empty) reopens the sheet after dismissing Settings —
  one modal at a time, hence the 0.6 s delay. `lastArchiveDest` remembers the destination.
- Share Extension: `NSExtensionActivationSupportsFileWithMaxCount` (20) plus archive detection
  (`UTType.zip` or the custom type, or a `.pbgallery` name) copies each archive to
  `share_<id>/<original name>` in the App Group (its own folder so the name survives — it names the
  unpacked folder) and records `PendingShare(kind: .archive)`. The extension now records *every*
  usable item in a share (archives, photos, links) instead of the first. `Library.refreshPendingShares`
  pulls `.archive` items out of the stash (`StorySharing.save` keeps the rest) and stages them
  through `receiveArchive`, which removes the emptied `share_<id>` folder.
- `Archiver` changes shared with "Extract Here": the archive is now `Data(.mappedIfSafe)` (a multi-GB
  archive no longer sits in memory whole), `__MACOSX/`, `.DS_Store` and `._*` are skipped, and the
  folder view's extraction passes `dropTopFolder: true` too (a Finder zip used to unpack as
  `Name/Name/…`). `.pbgallery` files on the drive get "Extract Here" like zips.

**Any file (Oct 22).** The Alternate document type is now `public.data`, so every AirDropped or
Files-opened file — a Finder folder (a zip), a PDF, a video, a document — offers Photo Browser.
`ArchiveIntake.Received.isArchive` (extension or `Archiver.isZip`) decides the path: archives unpack
as above; any other file is placed in the destination as it is by `DriveWriter.moveItem` (copy +
delete across volumes, so a failed copy leaves it staged), skipped when an identical file (same
name and size) is already there, numbered when a different same-named file is — nothing on the
drive is overwritten. The Share Extension's last branch takes any real file (`conforms(to: .data)`,
not text/url) the same way. What this can't reach: loose photos/videos AirDropped to an iPhone go
straight to the Photos app, before any app is asked.

**Gotchas.** The "Open with" tap on the phone can't be avoided (iOS asks before opening any received
file in an app; with `.pbgallery` the app is the only choice). `canPerform(withItems:)` is false with
AirDrop off/unavailable → exit 2 → Finder fallback. The custom UTI must stay listed under
`CFBundleDocumentTypes`, not only exported — iOS ignores an exported-only declaration for opening.

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
| Folder tags (+ "also the items inside?") | `FolderTags.swift`, `FolderView.tagMenu`, `FolderInfoView`, `mac/safe_finder.py` (`ask_inside`, `tag_items`) |
| Batch crop (one crop on many, "cropped" tag, Last Crop) | `BatchCrop.swift` (`CropSpec`, `BatchCropView`), `PhotoEditorView.swift` (`CropOverlay`), `mac/batch_crop.py`, `mac/crop_window.py` |
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

> **Oct 20, 2026 — the library moved to a 4 TB APFS SSD** (copied with Carbon Copy Cloner, metadata
> restored from the phone's backup). Everything in this section and §3.5/§3.6 is exFAT-specific and
> now dormant: `DriveWriter.configureForVolume` picks `.barrier` on APFS, `SpareFolders.pool/remaining`
> return nil unless `syncMode == .full`, Drive Health hides the New-folders section and the 2.2 TB
> advice, FolderView's "can't read this folder" text points at First Aid instead, and Safe Finder
> (`spare_folders.on_exfat`, cached per volume) neither takes spares nor adjusts names on an APFS
> destination (`plain_name` only caps 255 UTF-8 bytes). Keep the code — the exFAT drive still exists
> as the old copy.

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

- `DriveWriter.createDirectory(at:)` — creates the missing levels (it used to flush each new
  directory and its parent; that turned out to be the cause, see "Correction" below). Every drive-folder creation in the app
  (download services, import views, FileActions, Library, the video editor) now uses it; only
  container-side caches (Thumbnailer, DownloadLog, BackgroundDownloader inbox, dup-scan caches)
  keep the plain call. `FileActions.createFolder` (the user's New Folder) uses it too.
- `DriveWriter.shared.writeData(_:to:dates:)` now creates the parent folder inside the actor and
  stamps creation/modification dates on the temp, so the final entry is written exactly once.
  `writeDataUnique(_:named:in:dates:)` picks the non-colliding name **and** writes in one actor
  turn (no suspension between) — concurrent savers can't collide. `writeDataSync` is the same
  temp → fsync → rename recipe for callers that can't await (screenshots).
- The AI saves encode to `Data` in memory and go through `writeDataUnique`; both save functions
  are `async`. `AIResultsView` holds one background window while any save is in flight; the
  recovery pass keeps its window open until the images are on the drive (`defer { bg.end() }`).
- TikTok inbox filing flushes each placed file; the video editor's chunked import copy and the
  Photos-picker staging copy write into a hidden `.pbtmp_` sibling and rename.

**Correction (Oct 10, 2026): never flush a folder.** Folder flushes (`F_FULLFSYNC` on a
directory fd) were themselves breaking folders. Every folder iOS refused to open had been flushed
as a directory right after it was created or while it grew: the AI / Screenshots / Duplicate PNGs
helper folders (flushed at creation and after every commit), the Kardashian member folders (a parent
flush after each of 46k photos), Force Refresh (`thoroughContents` flushed the folder it re-read),
and Safe Finder v1 on the Mac (flushed each new folder and after every file). The copy rebuild,
which never flushes a folder, produced folders iOS reads. The drive root, flushed on every
backgrounding, stayed fine because, unlike other folders, it has no record inside a parent folder.
Taken together, this points to Apple's exFAT driver writing a stale copy of a flushed folder's own
record into its parent (fsck: "Directory /X/AI has zero length"). `DriveWriter.fullSync` now refuses directories (so
`fullSyncFileAndParent`, `commit`, `createDirectory`, `thoroughContents`, the unzip paths and every
other caller only flush files), and `quiesce` uses a whole-volume `sync()`. The Mac tools
(`safe_transfer.py`, `safe_copy_to_ssd.py`, `rebuild_exfat_folders.py --move`) dropped their
folder flushes too. To confirm on a broken folder: `sudo python3 mac/exfat_inspect.py <folder>`
before rebuilding it (look for `own-entry:` findings: dir-length, valid-length, alloc-flags,
chain).

**Same day, contradicting test:** the user moved (same-drive rename, via the fixed Safe Finder) the
files of a broken folder into a brand-new, never-flushed folder, and the new folder became
unreadable too. So the folder flush is at most part of it — the damage can travel with the moved
items' own records (or renaming into a folder triggers it). Response, pending inspector output:
the Mac tools now write exactly like the copy rebuild, the one proven method — `safe_transfer.py`
creates every file fresh under its final name (no staging rename, no same-drive rename: a "move" on
the SSD is a fresh copy + Trash), with no fsync at all, `sync()` between items, and a journal in
`.Safe Finder Staging/in-progress.txt` so a file cut off by a crash is deleted on the next run;
`rebuild_exfat_folders.py --move` became `--low-space` (fresh `copy2` copies into hidden
`.<name>.fresh`, each original deleted only after its copy hashes equal and the batch was synced +
`F_FULLFSYNC`'d via a small journal file). The iOS app is unchanged beyond the directory-flush rule
until the inspector shows which record is bad.

**Inspector results (Oct 10) rule out two more theories.** The new unreadable folder (37 items, one
cluster) is structurally clean, its own record and every item's record included — so neither the
flush nor the moved files' records are visibly bad. Location first looked ruled out — but that
run used an outdated list of folders the rebuild had already fixed. With Drive Health's current
list, **all 9 unreadable folders store their contents past 2.20 TB** (2^32 × 512-byte blocks; the
8 TB SSD has data out to 3.94 TB), while every folder the copy rebuild fixed landed below it — and
the one listed folder still broken after a rebuild (Porn/Japanese) is at 2.29 TB. ~200 readable
folders also sit past the line, so the theory under test is a reader that wraps 32-bit block
numbers: a read past 2.20 TB lands 2.20 TB earlier, and what happens to be there decides the
outcome — other files' bytes → EINVAL, zeros → an *empty* folder (Drive Health never flags empty
folders; the Oct 6 "new Finder folders show empty in Files" report fits), another folder's
contents → wrong items. `exfat_inspect.py` now reads those exact spots and predicts each folder's
iPhone view, so the prediction can be checked on the phone. Result: all 9 predicted to fail, but
so were 129 of the 163 other folders past the line that Drive Health reads fine — a plain read
wrap is out. Two refinements are now reported: a **same-ID test** (if iOS derives an item's ID
from a 32-bit block number, a folder past the line shares its ID with whatever item's data starts
exactly 2.20 TB earlier, and only folders with such a twin would break) and a **recency** check
(all 9 were created Oct 5–10, the days directory-flushing writers were in use: is any other folder
that new and past the line readable?). Results: no twins (0 of 9), and 102 folders created since
Oct 5 sit past the line and open fine — so neither explains it. What the 9 do share: every one was
written by a tool that flushed folders at the time (the iOS app from Oct 5 — Kendall, Kylie, Kari
Diviney/Duplicate PNGs; `safe_copy_to_ssd.py` / Safe Finder Oct 8–10 — the Porn folders; Japanese
is the "NewFolder" of the move test, made by a Safe Finder window that may still have been running
the old code). The checker now adds the places a flush could leave a mark that it hadn't read: the
FAT entries of each folder's clusters (contiguous folders shouldn't need any), clusters shared with
a file (cross-links), and the writer fingerprint of each folder's own record (attributes, 10 ms
fields, UTC offsets, timestamp pattern), compared against folders made in the same days.
Result (Oct 10): no cross-links, and the folders' FAT entries look like everyone else's. The one
difference is the record's dates: 8 of the 9 were modified after they were created, versus 9% of
the 508 folders made in the same days (87% of those carry an older modified date — copies that
keep the source's date, like the copy rebuild). That is the signature of a folder a tool kept
writing into over time (the app's downloads/rebuilds, Safe Finder's copies), consistent with the
flush explanation but not proof of it. Kendall and Kylie are also the drive's only folders over
one cluster (~10,000 items), so their straddling entry sets can't be compared with anything.

**Oct 11 — the rebuild test points back to location.** The copy rebuild (fresh files, no fsync) of
the 7 small folders fixed none of the 5 whose copies landed past 2.20 TB (2.97–3.83 TB) and stopped
the errors for the 2 that landed below it (1.08, 1.19 TB) — which also kills the flush explanation.
On the phone: `Porn/Sasha Grey/Sasha Grey` (past the line, predicted "wrong items") shows *older*
content; `Leaks` and its subfolders (past the line) show nothing; `JRG` (list below, photos past)
displays fine. And the earlier objection — "~160 other folders past the line aren't in Drive
Health" — was Drive Health's blind spot: it only flags folders whose read *errors*; one that reads
as empty passes, and its subfolders are never reached. Another user reports the same pair of
symptoms ("Invalid argument" or an empty folder under Apple's exFAT driver, fine under exfat-fuse)
on a 24 TB drive. Working model: the iPhone's driver reads directory clusters past 2^32 × 512 bytes
from the wrong place; file data is read correctly.

The fix is `mac/relocate_folders.py`: for every folder whose list reaches past the line (minus a
1 GB margin), copy the list into free clusters below it (first fit, at least 1 GB under the line),
mark the copy contiguous (NoFatChain, plus a valid FAT chain for readers that follow the FAT anyway),
repoint the folder's stream extension and recompute its entry-set checksum, then free the old
clusters. Lists with deleted entries are compacted (live sets byte-identical, verified) — Kendall's
46k live + 46k deleted sets fit in half the space, leaving room to grow. Dry run by default;
`--apply` unmounts first (so macOS can't write cached changes afterwards), refuses unless
`fsck_exfat -n` is clean and no folder has a broken chain, checks the chosen clusters against every
file's and folder's clusters (not just the bitmap), writes an undo file of every byte it changes
(except the copies, which land in free space), writes in a crash-safe order (copy → FAT → mark used
→ repoint → free old, with F_FULLFSYNC between phases and VolumeDirty set meanwhile), re-reads every
moved folder, runs `fsck_exfat -n` again and remounts. Tested on mkfs.exfat images built with a
test writer that places folders at chosen clusters — including a sparse 2.5 TB image with 1 MB
clusters and the real line — with exfatprogs' `fsck.exfat` clean before and after, every file
byte-identical, nested moves inside a compacted parent, `--only`, and refusals (damaged drive,
"free" cluster in use) leaving the image untouched; `--undo` restores the original tree. Hidden
(dot) folders are left alone unless `--include-hidden`; the drive's top-level list isn't moved.
Because nearly all free space is past the line, new folders (from the Mac or the iPhone) keep
landing there, so rerun it after adding folders; the lasting fix is partitions under 2.2 TB or APFS.
First real run (Oct 11) stopped while planning — nothing written — with "not enough free space"
for a 7-cluster list: the free space below the line is mostly gaps left by deleted photos, and the
tool insisted on one unbroken stretch. Now lists are placed biggest first, contiguous when a stretch
exists and otherwise gathered from the gaps and chained in the FAT (NoFatChain cleared); compacted
lists shrink to what their live entries need plus one cluster (Kendall 14 → ~7); the dry run reports
the free space below the line and its largest gap and refuses up front if the total isn't enough.
A folder path (rather than the SSD's root) limits the run to that folder and its subfolders — the
user ran it on one folder expecting exactly that, and it had planned the whole drive.
The first whole-drive dry run: 179 lists past the line (all of `Leaks`, Kendall, Kim, Kylie,
iMessage, the rebuilt Porn folders, parts of `_CCC SafetyNet`), 598 MB free below the line in 562
gaps (largest 3 MB), 209 MB needed — so the multi-cluster lists land in 3–5 pieces. Compaction now
also keeps every entry set inside one cluster (unused 0x05 filler entries before a set that wouldn't
fit), since sets split across non-adjacent pieces were among the few oddities of Kendall and Kylie
and no readable folder on the drive has one.

**Confirmed (Oct 11).** A trial on the 7 lists under `_CCC SafetyNet/…/Leaks Old`, then the whole
drive (179 lists): macOS's `fsck_exfat` clean before and after, and on the iPhone every folder
loads — Kendall, Kylie, Kim, iMessage, all of `Leaks`, the Porn folders. The location of a folder's
list was the whole story. Keep doing: after adding folders, a dry run of `relocate_folders.py`
(read-only) and `--apply` when it lists anything; new lists grow into free space that is almost
all past the line.

**New folders from spares (Oct 11).** To keep new folders below the line without the Mac tool every
time: neither macOS nor iOS lets a program pick where a new folder's list goes, but a rename or move
within the volume never moves it. `relocate_folders.py --spares N` (mounted: makes the shortfall of
empty folders in `<drive>/.Spare Folders`; then unmounted: moves their lists — and the pool's — below
the line like any other) keeps a stock of ready folders. Every folder the iOS app creates on the drive
goes through `DriveWriter.createDirectory`, which now renames a spare into place (`SpareFolders`,
POSIX `rename` so it can never become a copy; creation/modification dates reset to now); with none
left it makes the folder the usual way and bumps `photoBrowser.foldersWithoutSpare`, which Drive
Health ▸ New folders shows next to the spares left (orange under 10) with "I've Run the Fix on the
Mac" to clear it. `DriveWriter.copyItem` of a folder onto the drive builds it folder by folder with
`createDirectory`, and `DriveWriter.moveItem` (used by FileActions' move fallbacks) does cross-volume
moves through that copy — `FileManager.moveItem` across volumes would make the folders anew. Safe
Finder does the same through `mac/spare_folders.py`: New Folder and every folder of a copied tree
(including the hidden ".incoming" build folder, which is then renamed into place) take a spare; the
confirmation says how many new folders a transfer makes and whether the spares cover them, and the
result says how many were made without one plus the command that fixes them. Each spare costs one
cluster (1 MB) of the limited free space below the line (~390 MB after the first relocation).
Also a controlled test: `mac/ios_folder_test.py` makes five tiny folders at the drive root that differ only
in how they were written (empty mkdir; fresh file; file moved in; hidden-then-renamed like the
rebuild; macOS `cp` with xattrs, so a `._` file). The iPhone's Drive Health says which fail, and
`exfat_inspect.py --dump` prints each one's raw records field by field for a byte-level diff. The
checker also now flags non-zero bytes after a folder's end-of-directory marker (`after-end-bytes`).

**What this does not cover.** A cable pulled during an active write can still tear the FAT —
exFAT has no journal, which is why "Prepare Drive for Removal…" exists. The fixes shrink the
window to a single in-flight, fsync'd entry and make every folder/file either fully present or
absent. Run Drive Health's deep check after any repair session.
