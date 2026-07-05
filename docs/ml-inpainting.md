# Optional ML inpainting (LaMa → CoreML)

Object removal in the photo editor runs a three-tier chain:

1. **CoreML inpainting** — a LaMa-class generative network, *only if a model is
   bundled* (this document). Best quality: the network understands structure
   (railings, skin, fabric edges) that patch copying can only approximate.
2. **Exemplar patch synthesis** — always available, pure CPU, no model needed.
   This is the engine described in `photo-editor-capabilities.md`.
3. **Diffusion fill** — last-resort fallback for degenerate cases.

The app builds and runs identically with no model present — `MLInpainter`
simply reports `isAvailable == false` and tier 1 is skipped. Adding the model
is a drag-and-drop, no code or project changes.

## Converting LaMa to CoreML (run on your Mac)

The community-maintained [CoreMLaMa](https://github.com/mallman/CoreMLaMa)
project scripts the whole conversion of the
[LaMa](https://github.com/advimman/lama) inpainting model (specifically the
Big-LaMa checkpoint) to a CoreML package:

```bash
git clone https://github.com/mallman/CoreMLaMa.git
cd CoreMLaMa
python3 -m venv venv && source venv/bin/activate
pip install -r requirements.txt
python convert_lama.py
```

That produces `LaMa.mlpackage` (input/output size 800×800 by default; the
script has a size constant you can drop to 512 for a smaller/faster model —
either works, `MLInpainter` reads the size from the model itself).

If `convert_lama.py` fails on a newer Python, use Python 3.10/3.11 — the
`coremltools`/`torch` pins in that repo are known-good there.

## Installing the model into the app

1. Rename the output to `Inpainting.mlpackage` (or leave it `LaMa.mlpackage` —
   both names are accepted).
2. Drop it into the `PhotoBrowser/` source folder next to the Swift files.
   The project uses a file-synchronized group, so Xcode picks it up
   automatically — **no pbxproj editing**. Xcode compiles it to `.mlmodelc`
   inside the app bundle at build time.
3. Build and run. In the editor, object removal now routes through the model
   first; if it ever fails (bad render, weird mask), the exemplar engine takes
   over transparently.

## What to expect

- **App size**: Big-LaMa adds roughly 200 MB to the app. That's the trade for
  generative-quality fills; the 512 conversion is the same weights (input size
  doesn't change model size).
- **Speed**: one removal is a single network pass (Neural Engine preferred via
  `computeUnits = .all`) — typically well under a second on recent devices.
- **SDR only**: the model works in 8-bit RGB. Fills composite back into the
  working image, which the editor already processes in display space, so this
  matches the rest of the retouch pipeline. HDR sources keep their HDR on save
  as before — only the filled pixels are SDR-derived.
- **Windowing**: `ObjectRemoval.mlFill` crops a context window around the
  stroke (≥512 pt so small strokes aren't upscaled into the model's fixed
  input), letterboxes it into the model, and composites only the masked hole
  back with the same feathered seam the exemplar engine uses.
- **License**: LaMa is Apache-2.0 (SAIC-AI); CoreMLaMa is MIT. Both permit
  bundling in the app, including commercial distribution, with attribution in
  the license files.

## How the Swift side finds the model

`MLInpainter` (see `PhotoBrowser/MLInpainter.swift`) loads
`Inpainting.mlmodelc` or `LaMa.mlmodelc` from the main bundle and discovers
the I/O contract dynamically from `modelDescription` — the color image input,
the one-component (or "mask"-named) mask input, the image output, and the
input pixel size. So a 512, 800, or any other square conversion works without
touching the Swift code.
