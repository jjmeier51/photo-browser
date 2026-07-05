# Photo Editor — Capabilities Reference

A complete description of the in‑app photo editor inside **Photo Browser** (native
SwiftUI iOS/iPadOS app). This document is written to be consumed by an AI assistant:
it describes *what every tool does*, *how it is implemented*, and *the invariants that
must not be broken*. It is generated from the source under `PhotoBrowser/PhotoEditor*.swift`.

> Scope note: this is a **module inside an existing browser app**, not a standalone app.
> The editor is reached from the photo viewer's "Edit Photo" action. It is built per the
> `Photo_Editor_PRD.md` spec, whose defining constraint is **metadata preservation**.

---

## 1. Design invariants (non‑negotiable)

These hold for every tool below; violating them is a bug.

1. **Temp‑file writes, user‑chosen destiny.** Every save renders to a temp file first; the
   user picks **Save as New** (a new "`<name> edited.<ext>`" beside the untouched original)
   or **Overwrite** (atomic swap over the original via `replaceItemAt`; labels/captions stay
   attached, and a container change re‑keys via `library.itemMoved`). Editing is a pure
   function of `(original pixels, EditRecipe, masks/landmarks, stickers)`.
2. **Metadata‑preserving.** Every saved edit carries the original's full metadata —
   EXIF (incl. `DateTimeOriginal`), TIFF, GPS, IPTC, color profile — with the **capture
   date byte‑for‑byte unchanged** (so the browser's timeline/sort is undisturbed).
   Orientation is baked into the pixels exactly once and the tag reset to 1.
   All writes go through `PhotoEditorIO` (`CGImageSource`/`CGImageDestination`), never
   `UIImageJPEG/PNGRepresentation`.
3. **On‑device only.** No network in the editing pipeline. The only "AI" features are
   **background removal** and **object removal**, both on‑device (Apple Vision + Core Image).
4. **HDR‑preserving.** HDR sources (gain‑map / PQ‑HLG / RAW) save as 10‑bit HDR HEIC with
   headroom intact. Most stages are pure Core Image filters that preserve extended range;
   the warp stages route through a 16‑bit float wide‑gamut raster on the HDR path.
5. **Apple frameworks only.** No third‑party dependencies (SwiftUI, UIKit, Core Image,
   Vision, ImageIO, PhotosUI, CoreLocation, CommonCrypto).

---

## 2. Architecture in one minute

- **`EditRecipe`** (`PhotoEditorModel.swift`) is the single source of truth — a `Codable`
  struct of all operations + parameters. A fresh recipe is the identity edit.
- **`EditPipeline.render`** (`PhotoEditorPipeline.swift`) is a pure function applying the
  recipe in a fixed order (see §13). The same function renders the live proxy preview and
  the full‑res export, so they match.
- **`PhotoEditorIO`** is the *only* component that writes files (keeps metadata
  preservation in one place). Handles the SDR and HDR (`heif10Representation`) save paths,
  upscaling, and format selection.
- **`PhotoEditorView.swift`** is the editor UI: a top bar (compare/undo/redo/reset/save),
  a live preview area, and a scrollable **tab bar** of tools.
- Live preview renders on a **downscaled proxy** (2200 px; a 1000 px "fast" proxy during
  warp drags) for interactive framerates; full resolution is rendered only on save, off
  the main thread, with a progress indicator.

**Session‑wide controls (all tools):**
- **Undo / Redo** — step‑wise across every operation (recipe snapshots, depth 40).
- **Reset** — revert to the original, clears the stack.
- **Hold‑to‑Compare** — press to flash the unedited original over the preview.
- **Pinch‑to‑zoom / two‑finger pan** in the preview for precise work (reshape, brushes,
  body, makeup).

---

## 3. Tabs overview

The editor exposes these tools as tabs (scrollable bar):

`Adjust · Filters · Crop · Reshape · Retouch · Smooth · Paint · Teeth · Body · Makeup · Skin · Cut Out · Stickers`

Each is detailed below.

---

## 4. Adjust — light & color (`FR-ADJ-01`, partial `FR-ADJ-02`)

A chip strip of independent, resettable sliders. Each has a numeric readout and a
center‑zero track for bipolar controls. Implemented with Core Image
(`CIExposureAdjust`, `CIColorControls`, `CIToneCurve`, `CIVibrance`,
`CITemperatureAndTint`, etc.) in `EditPipeline.toneColor / detail / effects`.

| Control | Range | Notes |
|---|---|---|
| Exposure | −1…1 | brightness / EV |
| Contrast | −1…1 | |
| Highlights | −1…1 | bidirectional via tone curve |
| Shadows | −1…1 | bidirectional via tone curve |
| Saturation | −1…1 | |
| Vibrance | −1…1 | protects skin tones / already‑saturated pixels |
| Warmth | −1…1 | temperature, warm↔cool |
| Tint | −1…1 | green↔magenta |
| Sharpen | 0…1 | `CISharpenLuminance` (also under Detail) |
| Structure | −1…1 | mid‑tone local contrast / clarity (`CIUnsharpMask`) |
| Vignette | −1…1 | dark↔light corners |
| Grain | 0…1 | film grain |
| Fade | 0…1 | lifted‑blacks film fade |

- **Auto** — one‑tap baseline. Derives exposure/contrast/vibrance/shadows/highlights from
  the image's average luminance, then the user can tweak.
- *Still open from `FR-ADJ-02`:* full **tone curve** (RGB + per‑channel) and **HSL**
  (per‑color hue/sat/lum) are not yet implemented.

---

## 5. Filters (`FR-FILT-01`, `FR-FILT-02`)

- **42 preset looks** rendered as `CIFilter` chains, each with a **live thumbnail** of the
  current image. Per‑filter **intensity** slider (0–100%, cross‑dissolve from original).
- Looks: *Vivid, Warm, Cool, Film, Faded, Lo‑Fi, Chrome, B&W, Noir, Silver, Teal, Sunset,
  Vintage, Matte, Crisp, Moody, Golden, Pastel, Drama, Cinema, Sepia, X‑Pro, Frost, Ember,
  Olive, Rose, Azure, Mocha, Honey, Slate, Punch, Velvet, Dusk, Bloom, Retro, Ivory,
  Carbon, Coral, Mint, Plum, Lush, Smolder.*
- **Background‑only filter** — apply the chosen look *only behind the subject* (uses the
  Vision subject mask), leaving the person ungraded.
- **Search** — filter the preset list by name.
- **Favorites** — star any filter; favorites sort first and persist across sessions.
- Filters compose with manual adjustments in the fixed pipeline order.

---

## 6. Crop & geometry (`FR-CROP-01`, `FR-CROP-02`)

- **Crop** — Freeform drag, plus fixed ratios **1:1, 4:5, 3:2, 16:9, Original**.
  Interactive box on the preview (drag interior to move, corners to resize).
- **Rotate** 90° left/right; **Flip** horizontal/vertical.
- **Straighten** — fine angle slider ±45° with auto‑crop to valid bounds (largest inscribed
  rectangle, no blank corners).
- **Perspective / keystone correction** — **Vertical** and **Horizontal** sliders
  (−1…1). Converges the top/bottom or left/right edge via `CIPerspectiveTransform`, then a
  computed cover‑zoom refills the frame so no blank corners show.
- Orientation is handled correctly and never double‑applied on export; crop updates pixel
  dimensions consistently while leaving date/GPS intact.

---

## 7. Reshape — manual liquify (`FR-RESH-01`)

- **Push/warp brush**: drag on the photo to locally push pixels, mesh‑based and smooth.
- **Brush Size** (0.02–0.4 of image width) and **Strength** (0.1–1.0) sliders. The mesh is
  61×61 for the manual tool so a small brush can localize to a tiny area.
- **Size preview** — dragging the Size slider flashes a sized ring on the photo.
- **Pinch‑zoom + two‑finger pan** while reshaping; one‑finger drag is the brush.
- Stored as a normalized displacement mesh (`ReshapeField`) in the recipe; warp is a
  piecewise‑affine `ReshapeWarp` (16‑bit float path on the HDR save so headroom survives;
  high‑quality interpolation on export, faster interpolation during the drag).

---

## 8. Body & face shaping (`FR-RESH-02`)

Vision body/face landmark‑driven warps (`VNDetectHumanBodyPoseRequest`,
`VNDetectFaceLandmarksRequest`). Each is a small, smooth, landmark‑anchored mesh
contribution, **confined to the subject** via the Vision subject mask so the background
stays still. Chip + slider per control; pinch‑zoom supported.

- **Body (needs a detected body):** Slim, Waist, Hips, Butt, Breasts, Legs, Height, Arms,
  Ankles, Feet, Neck, **Torso** (shorten — brings the waist up toward the chest).
- **Face (needs a detected face):** Head, Forehead, Eyes, Nose, Ears, Chin, Lips, Smile.
- Only the chips whose landmarks were detected are shown. Effects are deliberately
  conservative and isolated (e.g., torso compresses only the chest→hip band; waist/hips are
  confined to the torso column so arms aren't dragged; butt rounds via a radial bulge that
  also works on straight‑on shots).
- *Limitation:* isolation quality depends on the Vision subject mask; low‑contrast subjects
  can bleed slightly. No clothing segmentation (Apple exposes none on‑device).

---

## 9. Retouch — object removal (`FR-CUT-02`)

- **TouchRetouch‑style magic eraser**: brush over an unwanted object; the region is filled
  to blend with its surroundings. Brush size slider; per‑stroke Undo.
- **Optional CoreML tier**: if a converted LaMa inpainting model is bundled (drop
  `Inpainting.mlpackage` into `PhotoBrowser/`; see `docs/ml-inpainting.md`), removals run
  through the generative network first — it understands structure (railings, skin, fabric)
  that patch copying can only approximate. Any failure falls through to exemplar synthesis;
  without a model the app builds and behaves identically.
- On‑device **exemplar‑based patch synthesis** (the TouchRetouch / Content‑Aware‑Fill
  approach): real 9×9 patches of the surrounding image are copied into the hole
  (best‑match SSD search, onion‑peel fill order, locality bias), so the fill carries
  genuine texture and structure. Runs on the CPU in a resolution‑capped window around the
  mask; only the hole plus a feathered seam is composited back. Degenerate cases (mask
  covering most of the image) fall back to the older diffusion fill.
- Resolution is preserved everywhere except the masked hole.

---

## 10. Brush tools — Smooth / Paint / Teeth (`FR-ADJ-03`‑adjacent)

Freehand brushes whose strokes are stored normalized in the recipe (resolution‑independent,
undoable, re‑rendered identically at proxy and full‑res). Applied over the final image,
under stickers. Live on‑photo stroke preview in the tool's color.

- **Smooth** — brush over skin to remove detail/roughness (Facetune‑style: median + gentle
  blur, only where painted). **Size** + **Intensity**.
- **Paint** — paint **any color** (system color picker) with **Size** + **Opacity**, plus a
  built‑in **Eraser** that restores the underlying pixels in the brushed area.
- **Teeth** — brush to **whiten** (cools the yellow cast, drops saturation, lifts
  brightness). **Size** + **Whiten** amount.

---

## 11. Skin tone (pale ↔ tan)

- A single bipolar **Skin Tone** slider: left = paler, right = more tan.
- Skin is isolated **by color** (a precomputed skin‑probability `CIColorCube`) and
  intersected with the Vision **subject mask** so the background is never touched. A
  warm/darker/saturated (tan) or cool/lighter/desaturated (pale) shift is blended only over
  skin, under makeup. *Limitation:* color‑based, so skin‑colored clothing can be caught.

---

## 12. Makeup (face‑landmark overlays)

Landmark‑anchored overlays on the primary detected face. Categories (chip + slider/palette):

- **Looks (10 presets):** Natural, Glam, Bold, Sweet, Smoky, Gothic, Bronze, Vintage, Doll,
  Editorial — each sets a bundle of the controls below, with an overall **Strength** slider.
- **One‑offs:** Lips (color palette + amount), Blush (palette + amount), Eyeshadow (palette +
  amount), Eyeliner, Lashes, Brows.
- **Freckles:** 5 density levels (barely any → full coverage), drawn as tiny soft warm specks
  biased to the nose/cheek band.

Rendered as a feathered SDR overlay composited over the base (`CISourceOverCompositing`), so
an HDR base keeps its headroom everywhere except the painted makeup pixels. Landmarks for
the HDR save path are detected on a clamped SDR copy so detection stays accurate.

---

## 13. Background removal / Cut Out (`FR-CUT-01`)

- On‑device subject mask (`VNGenerateForegroundInstanceMaskRequest`).
- Background options: **Transparent** (PNG), **Blur**, **White**, **Solid black**.
- The same subject mask drives background‑only filter, body‑shaping confinement, hair/skin
  masking, etc.
- *Open from the PRD:* a manual mask‑refine brush (add/remove + edge feather) is not yet
  implemented.

---

## 14. Stickers (image overlays)

- Import another image **from Photos** or **from in‑app folders / Files**; place **multiple**.
- **Move, pinch‑scale, rotate** each sticker on the canvas; delete individually.
- **Cut out** a sticker's background (Vision subject mask) so only the subject overlays.
- **HDR‑preserving**: the sticker is re‑decoded from its original data in HDR (`expandToHDR`)
  for the final composite, so imported HDR stickers keep their headroom.

---

## 15. Save & export (`FR-SAVE-01`, partial `FR-SAVE-02`)

- **Four save choices**: Overwrite Existing Photo · Overwrite + 2× AI Upscale · Save as New
  Photo · Save as New + 2× AI Upscale. Save‑as‑New writes a fresh file beside the untouched
  original; Overwrite atomically replaces it (temp file + `replaceItemAt`, so a failed save
  can't destroy the original) keeping its file dates, labels and captions. When Overwrite
  changes container (gain‑map JPEG → HDR HEIC), the new extension lands beside the original,
  the original is removed, and path‑keyed metadata is re‑keyed (`library.itemMoved`).
- **Metadata preserved** incl. capture date (see §1). Format auto‑matches the source
  (HEIC / JPEG / PNG); a transparent cut‑out forces PNG.
- **HDR retention** — HDR sources save as 10‑bit HDR HEIC (`heif10Representation`,
  Display P3 PQ) with headroom intact.
- **2× AI Upscale** — Lanczos + light denoise + sharpen at save time.
- Saved files are tagged in the library so a folder's **"Edited" filter** can list
  in‑app‑edited photos.
- *Open from the PRD:* an explicit export‑controls sheet (format/quality picker +
  share‑sheet) beyond the current options.

---

## 16. Pipeline order (deterministic)

`EditPipeline.render` applies operations in this fixed order so the proxy and export match:

```
cutout (background)  →  skin tone  →  makeup  →  body/face shaping  →  geometry
(rotate/flip/straighten/perspective/crop)  →  tone & color  →  filter  →  detail
(sharpen/structure)  →  effects (fade/grain/vignette)  →  reshape (manual liquify)
→  brush strokes (smooth/paint/teeth/erase)  →  stickers
```

Object‑removal inpainting is applied to the source *before* the pipeline; the subject mask
and face/body landmarks are computed once and supplied to the render.

---

## 17. PRD status summary

**Done:** non‑destructive session + undo/redo/revert (`FR-SESS-01/02`); crop/rotate/
straighten/flip + perspective (`FR-CROP-01/02`); core adjustments + Auto (`FR-ADJ-01`);
sharpen/structure (`FR-DET-01`); preset filters + intensity + thumbnails + favorites/search
(`FR-FILT-01/02`); manual reshape (`FR-RESH-01`); face/body landmark shaping (`FR-RESH-02`);
background removal core (`FR-CUT-01`); object removal (`FR-CUT-02`); metadata‑preserving save
(`FR-SAVE-01`). Plus extras beyond the PRD: skin tone, smooth/paint/teeth brushes, stickers,
HDR retention, save‑time upscaling.

**Outstanding (P1/P2):**
- `FR-ADJ-02` — **Tone Curve** (RGB + per‑channel) and **HSL** (per‑color H/S/L). The
  effects half (vignette/grain/fade/clarity) is done.
- `FR-ADJ-03` — a true **selective adjustment brush** (paint exposure/contrast/etc. onto a
  region). Partly anticipated by the Smooth/Paint/Teeth brushes.
- `FR-CUT-01` — manual **mask‑refine brush** (add/remove + edge feather).
- `FR-SAVE-02` — explicit **export controls** (format/quality picker + share sheet).

---

## 18. Source map

| File | Responsibility |
|---|---|
| `PhotoEditorModel.swift` | `EditRecipe`, `BodyShape`, `MakeupRecipe`, `ReshapeField`, enums |
| `PhotoEditorPipeline.swift` | `EditPipeline.render`, `EditFilter.all` (42), geometry/tone/filter/effects/perspective |
| `PhotoEditorIO.swift` | load/save, HDR (`heif10Representation`), upscaling, metadata preservation, landmark/mask detection |
| `PhotoEditorView.swift` | editor UI: tabs, panels, preview, canvases, save flow |
| `PhotoEditorBody.swift` | Vision body/face landmarks, `BodyWarp` (body/face shaping) |
| `PhotoEditorMakeup.swift` | `MakeupRenderer` (overlays, freckles) |
| `PhotoEditorSkin.swift` | `SkinRecolor` (skin‑color cube + tone shift) |
| `PhotoEditorBrush.swift` | `BrushStroke`, `BrushMask`, `BrushRender` (smooth/paint/teeth/erase) |
| `PhotoEditorRetouch.swift` | `RetouchMask`, `ObjectRemoval` (optional ML tier → exemplar patch synthesis → diffusion fallback) |
| `MLInpainter.swift` | Optional CoreML (LaMa‑class) inpainting engine; no‑op unless a model is bundled |
| `PhotoEditorCutout.swift` | subject mask (`VNGenerateForegroundInstanceMaskRequest`) |
| `PhotoEditorSticker.swift` | `EditSticker`, HDR sticker decode + cutout |

*(Hair recoloring was implemented and later removed — it did not work well.)*
