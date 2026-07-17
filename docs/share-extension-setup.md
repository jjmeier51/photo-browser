# Share Extension setup (one-time, in Xcode)

This adds **PhotoBrowser** to the iOS share sheet so you can share an Instagram story
(or a photo/video) to it. The code is all committed; these steps wire up the new target,
the App Group, and the URL scheme — things that live in the Xcode project and can't be
added from source files alone.

Everything under **`PhotoBrowser/`** already builds without these steps (the app-side flow
is inert until something is shared). Do these when you're ready to enable the share sheet.

## 1. Add the Share Extension target

1. Xcode → **File ▸ New ▸ Target…**
2. Choose **Share Extension** → Next.
3. Product Name: **ShareExtension**. Language: Swift. Finish.
   - If prompted "Activate scheme?", Cancel is fine.
4. Xcode generates a `ShareExtension/` group with `ShareViewController.swift`, `Info.plist`,
   and a `MainInterface.storyboard`.

## 2. Use the committed extension files

The repo already contains the real implementation in **`ShareExtension/`**:
`ShareViewController.swift`, `Info.plist`, `ShareExtension.entitlements`.

- **Delete** the `MainInterface.storyboard` Xcode created (this extension has no storyboard).
- **Replace** Xcode's generated `ShareViewController.swift` and `Info.plist` with the committed
  ones (or copy their contents over). The committed `Info.plist` uses
  `NSExtensionPrincipalClass` (no storyboard) and accepts URLs + images + movies.
- In the ShareExtension target's **Build Settings**, make sure there's no
  `INFOPLIST_KEY_NSExtensionMainStoryboard` / storyboard reference left over.

## 3. Share the hand-off file with both targets

`PhotoBrowser/StorySharing.swift` defines the App Group id and the payload shape and must
compile into **both** targets:

- Select `StorySharing.swift` in the navigator → **File Inspector (right panel) ▸ Target
  Membership** → check **both** `PhotoBrowser` **and** `ShareExtension`.

(`ShareViewController.swift` should be a member of **ShareExtension** only.)

## 4. Turn on the App Group (both targets)

For **PhotoBrowser** *and* **ShareExtension**, in **Signing & Capabilities**:

1. **+ Capability ▸ App Groups**.
2. Add the group **`group.jayymei.PhotoBrowser`** (the exact string in `StorySharing.appGroupID`
   and both `.entitlements` files). Check its box on both targets.

## 5. Register the `photobrowser://` URL scheme (main app only)

The extension wakes the app with `photobrowser://share`. On the **PhotoBrowser** target →
**Info** tab → **URL Types** → **+**:

- **Identifier:** `jayymei.PhotoBrowser`
- **URL Schemes:** `photobrowser`
- Role: Editor

## 6. Build & run

- Build the **PhotoBrowser** scheme to the device.
- In Instagram, open a story → **Share ▸ …** → **PhotoBrowser**. The app opens to a sheet:
  choose a folder, toggle *2× AI upscale photos* / *Upscale videos to 1080p*, tap **Save**.

## Notes / limitations

- Downloading uses your **logged-in Instagram session** (the app's in-app browser cookies).
  If you're not logged in there, the sheet reports it — log in once via the app's Instagram
  feature, then re-share.
- A shared story link downloads **that account's current stories** (last 24h) into the folder —
  the specific story you shared is included. (Instagram's share is a link to the account's story
  tray, not a single-file export.)
- Sharing an actual photo/video file (e.g. from Photos) copies it straight into the folder,
  with the same upscale options.
