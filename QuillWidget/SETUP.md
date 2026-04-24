# Quill iOS Widget — Xcode target setup

The source files for the widget live in `Quill iOS Widget/`. Widget
extensions require a dedicated Xcode target + embed build phase that's
too fragile to hand-edit in `project.pbxproj`, so this one-time setup
has to happen in the Xcode UI. Allow ~5 minutes.

## 1. Add the widget extension target

1. Open `Hex.xcodeproj` in Xcode.
2. File → New → Target… → iOS → **Widget Extension** → Next.
3. Configure:
   - **Product Name:** `QuillWidget`
   - **Bundle Identifier:** `com.joevasquez.Quill.iOS.QuillWidget` (Xcode defaults to appending the widget name — just accept it).
   - **Team:** `ND4KZ9EE2W`
   - **Include Configuration Intent:** **off** (we ship a static widget).
   - **Include Live Activity:** off.
4. Finish. When prompted to activate the scheme, click **Activate**.

Xcode creates `QuillWidget/` with stub source files. We won't use those.

## 2. Wire in the files we wrote

1. Delete the stub files Xcode generated in `QuillWidget/`:
   - `QuillWidget.swift` (the stub)
   - `QuillWidgetBundle.swift` (the stub)
   - `Info.plist` (the stub)
2. In the Project Navigator, right-click `QuillWidget` → **Add Files to "Hex"…** → select the four files in `Quill iOS Widget/`:
   - `QuillWidgetBundle.swift`
   - `QuillWidget.swift`
   - `Info.plist`
   - `SETUP.md` (not needed by the build, but convenient to keep next to the source)
   - Uncheck "Copy items if needed".
   - **Add to target:** only `QuillWidget` (NOT the main `Quill iOS` target).
3. Target **`QuillWidget`** → Build Settings → `INFOPLIST_FILE` → set to `Quill iOS Widget/Info.plist`.

## 3. Link HexCore into the widget

The widget reads `QuillWidgetSnapshot` (which lives in HexCore).

1. Target `QuillWidget` → **General** → **Frameworks and Libraries** → `+` → add `HexCore`.

## 4. App Group capability

Both the main app and the widget need the same App Group so the
snapshot JSON blob is readable by both.

1. Target **`Quill iOS`** → Signing & Capabilities → `+ Capability` → **App Groups**.
2. Click `+` under App Groups and enter `group.com.joevasquez.Quill`. Xcode will register it on the Developer Portal.
3. Target **`QuillWidget`** → Signing & Capabilities → `+ Capability` → **App Groups** → check the same `group.com.joevasquez.Quill` box.

No entitlements file exists today for either target; Xcode will create one for each automatically.

## 5. Verify

1. Scheme picker → `Quill iOS` → Run.
2. In a notes view, create/modify a note. That writes the `QuillWidgetSnapshot` via `NotesStore.updateWidgetSnapshot()`.
3. Switch scheme to `QuillWidget` → Run. The widget preview should show your latest note's title + preview. Small family shows "Dictate" CTA.
4. From the home screen, long-press → Add Widget → search Quill → add small or medium.
5. Tap the widget — it deep-links `quill://record` (small) or `quill://notes` (right half of medium), which `QuillDeepLinkRouter` routes into the app.

## 6. TestFlight

Archive the `Quill iOS` scheme as usual (`bash tools/scripts/testflight.sh`). Xcode automatically embeds the widget extension into the archived `.ipa` because of the extension's target dependency + embed phase it wired up when the target was added in step 1.

## Architecture notes

- **Main app → widget:** `NotesStore.save()` calls `updateWidgetSnapshot()` on every mutation; that serializes a `QuillWidgetSnapshot` (title, preview, updatedAt) to the App Group's `UserDefaults(suiteName: "group.com.joevasquez.Quill")` and calls `WidgetCenter.shared.reloadAllTimelines()` to force a redraw.
- **Widget → main app:** taps on the small family open `quill://record`; taps on the medium family's note half open `quill://notes`. `QuilliOSApp` wires the URL to a `QuillDeepLinkRouter` which `ContentView` observes and acts on — starting a recording or presenting the notes list respectively.
- **Widget UI:** small = feather logo + "Dictate" CTA + mic circle; medium = left half same CTA + right half last-note card.
- **Container background:** purple gradient matching the iOS header, using SwiftUI's `containerBackground(for: .widget)` (required for StandBy mode / Always-On).
