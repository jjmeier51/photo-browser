# AI Live Activity (Dynamic Island)

The **notification** ("AI images ready") already works with no setup — it's posted
by the app (`AILiveActivity.swift`).

To also show the **Dynamic Island / Lock Screen Live Activity**, iOS requires a
**Widget Extension** target (a Live Activity's UI can only live in an extension).
This is a one-time, few-minute setup in Xcode — the code is already written.

## Steps

1. **File → New → Target… → Widget Extension.**
   - Name it e.g. `AIActivityWidget`.
   - **Uncheck** "Include Configuration App Intent".
   - **Check** "Include Live Activity".
   - Finish, and **activate** the scheme if prompted. Xcode adds the extension and
     embeds it in the app automatically.

2. **Replace the generated widget source** with this folder's
   `AIActivityWidget.swift` (delete the template `…LiveActivity.swift` /
   `…Bundle.swift` Xcode created, then drag in `LiveActivity/AIActivityWidget.swift`
   with "Copy items if needed" and target = the widget extension only).

3. **Share the attributes type with both targets.** Select
   `PhotoBrowser/AIActivityAttributes.swift` in the navigator and, in the File
   Inspector → *Target Membership*, **also check the widget extension** (keep the
   app checked too). Now both targets compile the same `AIActivityAttributes`.

4. The app target already has `NSSupportsLiveActivities = YES` (set in the project
   build settings), so nothing else is needed.

Build & run on a device (Live Activities don't show in older simulators). Start an
AI Edit or AI Extend, swipe to the Home Screen — you'll see "AI In Progress" in the
Dynamic Island, updating to "Ready" (or "Failed") when Astria returns, plus the
notification.

> Note on background time: iOS only guarantees a few minutes of background
> execution, and the Astria request uses a normal (foreground) URLSession, so if
> the system fully suspends the app mid-request the work pauses until you return.
> The Live Activity + notification cover the common case where it finishes within
> that window.
