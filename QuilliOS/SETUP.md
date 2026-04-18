# Quill iOS — Xcode Setup

The code for the iOS app lives in `QuilliOS/` but a new Xcode target needs to be added through Xcode's UI (editing `project.pbxproj` by hand is error-prone).

Follow these steps once. Takes ~5 minutes.

## 1. Add the iOS app target

1. Open `Hex.xcodeproj` in Xcode
2. Select the project (top of the navigator) → click **+** at the bottom of the Targets list → **"App"** (under iOS)
3. Configure:
   - **Product Name:** `Quill iOS`
   - **Team:** Your personal team (the one with Apple ID `joe@joevasquez.com`)
   - **Organization Identifier:** `com.joevasquez`
   - **Bundle Identifier:** should auto-fill as `com.joevasquez.Quill-iOS` — edit to `com.joevasquez.Quill.iOS`
   - **Interface:** SwiftUI
   - **Language:** Swift
   - **Storage:** None
4. Click **Finish**

Xcode creates a new `Quill iOS/` folder with default files. We'll replace those.

## 2. Replace Xcode's default files with ours

1. In Xcode's Navigator, under **Quill iOS** group, delete (move to trash) these auto-generated files:
   - `Quill_iOSApp.swift` (or similar)
   - `ContentView.swift`
   - `Assets.xcassets`
   - `Preview Content` folder
   - `Info.plist` (if visible)

2. Right-click the **Quill iOS** group in the navigator → **Add Files to "Hex"...**
3. Navigate to `QuilliOS/` (in the repo root)
4. Select all files and folders inside:
   - `QuilliOSApp.swift`
   - `ContentView.swift`
   - `SettingsView.swift`
   - `QuillIOSSettings.swift`
   - `Info.plist`
   - `Clients/` folder
   - `Assets.xcassets/`
5. **Important:** In the dialog that appears:
   - ✅ **Copy items if needed** — UNCHECKED (files live in the repo)
   - ✅ **Create groups**
   - ✅ **Add to targets:** only `Quill iOS` (NOT `Hex`, NOT `HexTests`)
6. Click **Add**

## 3. Add shared files to the iOS target

The iOS app reuses `AIProcessingClient` and `KeychainClient` from the Mac app.

1. In the navigator, select `Hex/Clients/AIProcessingClient.swift`
2. Open the **File Inspector** (right panel, first tab)
3. Under **Target Membership**, check ✅ `Quill iOS` (keep `Hex` checked too)
4. Repeat for `Hex/Clients/KeychainClient.swift`

## 4. Add HexCore to the iOS target

1. Select the project in the navigator
2. Select the **Quill iOS** target
3. Go to the **General** tab
4. Scroll to **Frameworks, Libraries, and Embedded Content**
5. Click **+** → select `HexCore` → **Add**

## 5. Add WhisperKit to the iOS target

1. Still on the **Quill iOS** target's **General** tab
2. **Frameworks, Libraries, and Embedded Content** → **+**
3. Find `WhisperKit` (from Swift Package Manager — already fetched for the Mac target)
4. Click **Add**

## 6. Configure Info.plist path (if needed)

1. **Quill iOS** target → **Build Settings** tab
2. Search for `INFOPLIST_FILE`
3. Set value to `QuilliOS/Info.plist`
4. Search for `GENERATE_INFOPLIST_FILE`
5. Set to `NO` (we're using our own Info.plist)

## 7. Verify the scheme

1. Menu bar → **Product** → **Scheme** → **Manage Schemes...**
2. Make sure **Quill iOS** scheme exists and is checked **Shared**
3. Close

## 8. Build and run

1. Top of Xcode: select **Quill iOS** as the scheme (next to the Run button)
2. Select a destination: **iPhone 15 Simulator** (or your physical iPhone)
3. Press **⌘R**

The first build will take a while as WhisperKit compiles for iOS. On a physical device you'll need to trust your developer certificate in **Settings → General → VPN & Device Management**.

## Troubleshooting

- **"No such module 'WhisperKit'"** — Step 5 wasn't done correctly. Re-check Frameworks list.
- **"No such module 'HexCore'"** — Step 4 wasn't done. HexCore must be in the iOS target's frameworks.
- **Missing `AIProcessingClient` / `KeychainClient` symbols** — Step 3 wasn't done. Open each file and check Target Membership in the File Inspector.
- **iOS build errors about `NSWorkspace` or `AppKit`** — a file imported macOS-only code that wasn't gated. Report the error and I can fix the offending file.
- **FluidAudio/Parakeet errors** — FluidAudio may not support iOS. The iOS app intentionally uses WhisperKit only. If Parakeet is referenced anywhere, gate it with `#if canImport(FluidAudio)` or `#if os(macOS)`.
