# PhotoBrowserTests

Unit tests for the app. The project ships without a test target (see `CLAUDE.md`), and the
`.pbxproj` uses Xcode 16 synchronized groups, so the target is added in Xcode rather than by
hand-editing the project file:

1. **File → New → Target… → Unit Testing Bundle.** Name it `PhotoBrowserTests`, host app
   `PhotoBrowser`, language Swift. Xcode creates a `PhotoBrowserTests/` group — point it at **this**
   folder (or delete the generated folder and drag this one in, "Create groups", target =
   `PhotoBrowserTests` only).
2. Make sure the target's *Host Application* is `PhotoBrowser` and *Allow testing Host Application
   APIs* is on, so `@testable import PhotoBrowser` resolves.
3. Run with **⌘U** (or `xcodebuild test -project PhotoBrowser.xcodeproj -scheme PhotoBrowser
   -destination 'platform=iOS Simulator,name=iPhone 16'`).

Files:

- `DuplicateDetectionTests.swift` — the move/copy duplicate rules (`DuplicateDetection`):
  same-name-different-picture must not match, same-picture-different-name with no EXIF matches
  via the perceptual hash, burst shots with identical EXIF don't match, PNG upscaler-suffix
  stripping, Rule A both branches, Rule B (every matching PNG), Rule A then B, incoming PNG
  diversion, `_1`/`_2` naming in `DUPLICATES/`, and one end-to-end move through
  `FileActions.moveItems` on a temp folder.

- `VideoEditorTests.swift` — the video editor's Phase 1 core: `project.json` round-trip with unknown
  keys preserved and deterministic encoding, clip time mapping with speed, main-track starts and
  transition overlaps, frame snapping and timecode formatting, canvas sizes for every ratio, layer
  placement maths, name sanitising and `(n)` uniqueness, `drive://` / package / `Library/` path
  resolution, the sandbox audit (every layout path is under the drive root; atomic save leaves a
  `.bak`), undo/redo round trips including coalesced transactions, recovery from a corrupt save,
  and the export bitrate table.
