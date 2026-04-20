# Quill – Dev Notes for Agents

This file provides guidance for coding agents working in this repo.

> **Naming note:** The project was renamed from **Hex** (Kit Langton's original) to **Quill** (Joe Vasquez's fork). Internal module names like `HexCore`, `HexSettings`, and `HexLog` intentionally retain the "Hex" name — they are internal technical identifiers, and renaming them would be pure churn. User-facing identifiers (bundle ID, product name, storage paths, copyright, About view) have all been updated to Quill / Joe Vasquez.

## Project Overview

Quill is a macOS menu bar application (plus an iOS companion app) for on-device voice-to-text with optional AI post-processing. It supports Whisper (Core ML via WhisperKit) and Parakeet TDT v3 (Core ML via FluidAudio). Users activate transcription with hotkeys; text can be auto-pasted into the active app, with optional LLM clean-up via OpenAI or Anthropic.

**Bundle IDs:**
- macOS: `com.joevasquez.Quill` (release), `com.joevasquez.Quill.debug` (debug)
- iOS: `com.joevasquez.Quill.iOS`

**Storage:** `~/Library/Application Support/com.joevasquez.Quill/` on macOS.

## Build & Development Commands

```bash
# Build the macOS app
xcodebuild -scheme Quill -configuration Release

# Build the iOS app (Simulator)
xcodebuild -scheme "Quill iOS" -destination 'generic/platform=iOS Simulator' build

# Run tests (must be run from HexCore directory for unit tests)
cd HexCore && swift test

# Or run all tests via Xcode
xcodebuild test -scheme Hex

# Open in Xcode (recommended for development)
open Hex.xcodeproj
```

## Architecture

The app uses **The Composable Architecture (TCA)** for state management. Key architectural components:

### Features (TCA Reducers)
- `AppFeature`: Root feature coordinating the app lifecycle
- `TranscriptionFeature`: Core recording and transcription logic
- `SettingsFeature`: User preferences and configuration
- `HistoryFeature`: Transcription history management

### Dependency Clients
- `TranscriptionClient`: WhisperKit integration for ML transcription
- `RecordingClient`: AVAudioRecorder wrapper for audio capture
- `PasteboardClient`: Clipboard operations
- `KeyEventMonitorClient`: Global hotkey monitoring via Sauce framework

### Key Dependencies
- **WhisperKit**: Core ML transcription (tracking main branch)
- **FluidAudio (Parakeet)**: Core ML ASR (multilingual) default model
- **Sauce**: Keyboard event monitoring
- **Sparkle**: Auto-update framework is linked but the feed URL has been removed for the Quill fork. Joe can host his own appcast on GitHub Releases or an S3 bucket if/when he wants to ship updates.
- **Swift Composable Architecture**: State management
- **Inject** Hot Reloading for SwiftUI

## Important Implementation Details

1. **Hotkey Recording Modes**: The app supports both press-and-hold and double-tap recording modes, implemented in `HotKeyProcessor.swift`. See `docs/hotkey-semantics.md` for detailed behavior specifications including:
   - **Modifier-only hotkeys** (e.g., Option) use a **0.3s threshold** to prevent accidental triggers from OS shortcuts
   - **Regular hotkeys** (e.g., Cmd+A) use user's `minimumKeyTime` setting (default 0.2s)
   - Mouse clicks and extra modifiers are discarded within threshold, ignored after
   - Only ESC cancels recordings after the threshold

2. **Model Management**: Models are managed by `ModelDownloadFeature`. Curated defaults live in `Hex/Resources/Data/models.json`. The Settings UI shows a compact opinionated list (Parakeet + three Whisper sizes). No dropdowns.

3. **Sound Effects**: Audio feedback is provided via `SoundEffect.swift` using files in `Resources/Audio/`

4. **Window Management**: Uses an `InvisibleWindow` for the transcription indicator overlay

5. **Permissions**: Requires audio input and automation entitlements (see `Hex.entitlements`)

6. **Logging**: All diagnostics should use the unified logging helper `HexLog` (`HexCore/Sources/HexCore/Logging.swift`). Pick an existing category (e.g., `.transcription`, `.recording`, `.settings`) or add a new case so Console predicates stay consistent. Avoid `print` and prefer privacy annotations (`, privacy: .private`) for anything potentially sensitive like transcript text or file paths.

## Models (2025‑11)

- Default: Parakeet TDT v3 (multilingual) via FluidAudio
- Additional curated: Whisper Small (Tiny), Whisper Medium (Base), Whisper Large v3
- Note: Distil‑Whisper is English‑only and not shown by default

### Storage Locations

- WhisperKit models
  - `~/Library/Application Support/com.joevasquez.Quill/models/argmaxinc/whisperkit-coreml/<model>`
- Parakeet (FluidAudio)
  - We set `XDG_CACHE_HOME` on launch so Parakeet caches under the app container:
  - `~/Library/Containers/com.joevasquez.Quill/Data/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3-coreml`
  - Legacy `~/.cache/fluidaudio/Models/…` is not visible to the sandbox; re‑download or import.

### Progress + Availability

- WhisperKit: native progress
- Parakeet: best‑effort progress by polling the model directory size during download
- Availability detection scans both `Application Support/FluidAudio/Models` and our app cache path

## Building & Running

- macOS 14+, Xcode 15+

### Packages

- WhisperKit: `https://github.com/argmaxinc/WhisperKit`
- FluidAudio: `https://github.com/FluidInference/FluidAudio.git` (link `FluidAudio` to Hex target)

### Entitlements (Sandbox)

- `com.apple.security.app-sandbox = true`
- `com.apple.security.network.client = true` (HF downloads)
- `com.apple.security.files.user-selected.read-write = true` (optional import)
- `com.apple.security.automation.apple-events = true` (media control)

### Cache root (Parakeet)

Set at app launch and logged:

```
XDG_CACHE_HOME = ~/Library/Containers/com.joevasquez.Quill/Data/Library/Application Support/com.joevasquez.Quill/cache
```

FluidAudio models reside under `Application Support/FluidAudio/Models`.

## UI

- Settings → Transcription Model shows a compact list with radio selection, accuracy/speed dots, size on right, and trailing menu / download‑check icon.
- Context menu offers Show in Finder / Delete.

## iOS Companion App

The iOS app lives in the `Quill iOS/` folder (note: folder name has a space — the Xcode build setting is `INFOPLIST_FILE = "Quill iOS/Info.plist"`). It's a lightweight companion, not a feature-parity port of macOS.

### Scope

- On-device transcription via WhisperKit (Core ML). No FluidAudio / Parakeet on iOS yet.
- AI post-processing of transcripts via `TextAIClient` (Anthropic or OpenAI).
- Local note store with inline photos; photos are analyzed by a vision model (`PhotoAnalysisClient`).
- PDF export of a note (text + inline photos + AI analyses).
- Editable note titles, share menu (text-only or PDF), location-tagged note creation.
- API keys stored via `KeychainStore` (direct Security-framework calls; see the keychain note below).
- No hotkeys, no auto-paste, no menu bar. Tap feather mic/camera → speak/snap → get structured note → share/export.

### Structure

- `QuilliOSApp.swift` — `@main` entry point.
- `ContentView.swift` — main screen. Purple header with feather logo + list/new/gear buttons, active-note strip (tap title to rename), mode chip row, note canvas with inline photos + AI-analysis cards, floating mic + camera FAB cluster at bottom-right, status pill above it.
- `SettingsView.swift` — sheet with Whisper model selector, AI provider picker, API key field.
- `NotesListView.swift` — sheet listing all saved notes with rename/delete.
- `QuillIOSSettings.swift` — `@AppStorage` keys and defaults.
- `PhotoPicker.swift` — `PHPickerViewController` (library) and `UIImagePickerController` (camera) wrappers.
- `ShareSheet.swift` — `UIActivityViewController` wrapper driven by `ShareRequest` (Identifiable items wrapper).
- `NotePDFExporter.swift` — `ImageRenderer` → `CGContext` PDF of a note, including photo-analysis blocks.
- `Models/Note.swift` — `id`, `title`, `body` (flat string with inline photo tokens), timestamps, optional `location`. `wordCount` and `displayTitle` strip photo tokens before computing.
- `Models/NoteContent.swift` — tokenizer. Photos embed as `![photo](<uuid>)` in `body`. `segments(from:)` splits into `.text` / `.photo` segments for rendering; `stripPhotos(from:)` for share/copy/preview.
- `Models/PhotoAnalysis.swift` — Codable sidecar (`summary`, `keyDetails[]`, optional `transcribedText`, `analyzedAt`, `model`).
- `Clients/IOSRecordingClient.swift` — `AVAudioRecorder` wrapper with metering and permission handling.
- `Clients/NotesStore.swift` — JSON-persisted `[Note]` + active-note ID in UserDefaults. Also owns published `photoAnalyses: [UUID: PhotoAnalysis]`, `analyzingPhotoIDs`, `analysisErrors`. Loads analyses from disk on init so views refresh automatically.
- `Clients/PhotoStore.swift` — persists `Application Support/photos/<note-id>/<photo-id>.jpg` and sidecar `<photo-id>.json`. Downscales to 1568 px long edge at JPEG 0.75 with `UIGraphicsImageRendererFormat.scale = 1` (forcing scale-1 is critical — the default uses the screen scale and re-inflates the image).
- `Clients/PhotoAnalysisClient.swift` — ships a JPEG to Anthropic or OpenAI with a JSON-only system prompt, parses the structured response. Recompresses on the fly (`compressForVision`) if the on-disk image is over 4 MB (Anthropic caps at 5 MB).
- `Clients/TextAIClient.swift` — iOS-specific text post-processor. Mirrors the shared macOS `AIProcessingClient` but reads the API key via `KeychainStore` and logs per-call so "AI didn't run" failures are visible.
- `Clients/KeychainStore.swift` — direct Security-framework helpers (`SecItemAdd` / `SecItemCopyMatching`). See the keychain note below for why this exists.
- `Clients/LocationClient.swift` — one-shot best-effort reverse geocode used when a note is created.

### Keychain (iOS)

The shared `KeychainClient` (in `Hex/Clients/`) uses `@DependencyClient`, which is unreliable on the iOS target under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`: `save(...)` returned success but nothing was actually persisted, and subsequent reads returned `errSecItemNotFound (-25300)`. **Do not use `KeychainClient.liveValue.save/read` on iOS.** Use `KeychainStore` in `Quill iOS/Clients/` for all keychain access from the iOS app. `KeychainStore` also splits save vs. lookup queries — `kSecAttrAccessible` is applied only on save (it is not a reliable filter on `SecItemCopyMatching`).

### Photo flow

1. Tap camera FAB → confirmation dialog (Take Photo / Choose from Library).
2. If recording, the dialog first stops recording so the dictated text is committed before the photo lands.
3. `NotesStore.insertPhotoIntoActiveNote(_:locationIfCreating:)` saves the JPEG and appends a `![photo](<uuid>)` token to the active note's `body`.
4. `analyzePhoto(noteID:photoID:provider:)` fires in the background — writes a `<photo-id>.json` sidecar and updates `photoAnalyses`. Views refresh automatically.

### Shared Code via `HexCore`

The iOS target imports `HexCore` for:
- `AIProcessingMode`, `AIProvider` (enums used by `TextAIClient` / `PhotoAnalysisClient`).

`Hex/Clients/KeychainClient.swift` is still included (via the iOS-target file-system-synchronized group exceptions) because `KeychainKey.openAIAPIKey` / `.anthropicAPIKey` constants live there, but iOS code should not call `KeychainClient.liveValue` methods — use `KeychainStore` instead.

macOS-only clients (`SleepManagementClient`, `PermissionClient`) have iOS stub `liveValue`s so `HexCore` compiles for both platforms.

### Settings Model

iOS uses `@AppStorage` with plain `UserDefaults` keys (namespaced as `quill.*`), **not** the macOS `HexSettings` struct. Keep the two in sync manually if adding shared settings.

Defaults: model = `openai_whisper-tiny.en`, mode = `off`, provider = `anthropic`.

### Permissions

`Quill iOS/Info.plist` declares:
- `NSMicrophoneUsageDescription` — recording.
- `NSSpeechRecognitionUsageDescription` — live partial transcript while recording.
- `NSCameraUsageDescription` — in-note photos.
- `NSPhotoLibraryUsageDescription` — library-sourced photos.
- `NSLocationWhenInUseUsageDescription` — optional, tags new notes with a rough place name.

### Xcode project

The iOS target is a `PBXFileSystemSynchronizedRootGroup` — new files in `Quill iOS/` are auto-included, no `pbxproj` edits needed. Shared files from `Hex/Clients/` are pulled into the iOS target via an explicit `membershipExceptions` list in `project.pbxproj`. Xcode occasionally normalizes bundle-ID quoting in the `pbxproj` on build; revert those with `git checkout -- Hex.xcodeproj/project.pbxproj` to keep diffs clean.

## Troubleshooting

- Repeated mic prompts during debug: ensure Debug signing uses "Apple Development" so TCC sticks
- Sandbox network errors (‑1003): add `com.apple.security.network.client = true` (already set)
- Parakeet not detected: ensure it resides under the container path above; downloading from Hex places it correctly.

## Changelog Workflow Expectations

1. **Always add a changeset:** Any feature, UX change, or bug fix that ships to users must come with a `.changeset/*.md` fragment. The summary should mention the user-facing impact plus the GitHub issue/PR number (for example, "Improve Fn hotkey stability (#89)").
2. **Use non-interactive changeset creation:** AI agents should use the non-interactive script:
   ```bash
   bun run changeset:add-ai patch "Your summary here"
   bun run changeset:add-ai minor "Add new feature"
   bun run changeset:add-ai major "Breaking change"
   ```
3. **Only create changesets, don't process them:** Agents should only create changeset fragments. The release tool is responsible for running `changeset version` to collect changesets into `CHANGELOG.md` and syncing to `Hex/Resources/changelog.md`.
4. **Reference GitHub issues:** When a change addresses a filed issue, link it in code comments and the changeset entry (`(#123)`) so release notes and Sparkle updates point users back to the discussion. If the work should close an issue, include "Fixes #123" (or "Closes #123") in the commit or PR description so GitHub auto-closes it once merged.

## Git Commit Messages

- Use a concise, descriptive subject line that captures the user-facing impact (roughly 50–70 characters).
- Follow up with as much context as needed in the body. Include the rationale, notable tradeoffs, relevant logs, or reproduction steps—future debugging benefits from having the full story directly in git history.
- Reference any related GitHub issues in the body if the change tracks ongoing work.

## Releasing a New Version

Releases are automated via a local CLI tool that handles building, signing, notarizing, and uploading.

### Prerequisites

1. **AWS credentials** must be set (for S3 uploads):
   ```bash
   export AWS_ACCESS_KEY_ID=...
   export AWS_SECRET_ACCESS_KEY=...
   ```

2. **Notarization credentials** stored in keychain (one-time setup):
   ```bash
   xcrun notarytool store-credentials "AC_PASSWORD"
   ```

3. **Dependencies installed** at project root and in tools:
   ```bash
   bun install                # project root (for changesets)
   cd tools && bun install    # tools dependencies
   ```

### Release Steps

1. **Ensure all changes are committed** - the release tool requires a clean working tree

2. **Ensure changesets exist** - any user-facing change should have a `.changeset/*.md` file:
   ```bash
   bun run changeset:add-ai patch "Fix microphone selection"
   ```

3. **Run the release command** from project root:
   ```bash
   bun run tools/src/cli.ts release
   ```

### What the Release Tool Does

1. Checks for clean working tree
2. Finds pending changesets and applies them (bumps version in `package.json`)
3. Syncs changelog to `Hex/Resources/changelog.md`
4. Updates `Info.plist` and `project.pbxproj` with new version
5. Increments build number
6. Cleans DerivedData and archives with xcodebuild
7. Exports and signs with Developer ID
8. Notarizes app with Apple
9. Creates and signs DMG
10. Notarizes DMG
11. Generates Sparkle appcast
12. Uploads to S3 (versioned DMG + `hex-latest.dmg` + appcast.xml)
13. Commits version changes, creates git tag, pushes
14. Creates GitHub release with DMG and ZIP attachments

### If No Changesets Exist

The tool will prompt you to either:
- Stop and create a changeset (recommended)
- Continue with manual version bump (useful for re-running failed releases)

### Artifacts

Each release produces:
- `Hex-{version}.dmg` - Signed, notarized DMG
- `Hex-{version}.zip` - For Homebrew cask
- `hex-latest.dmg` - Always points to latest
- `appcast.xml` - Sparkle update feed

### Troubleshooting

- **"Working tree is not clean"**: Commit or stash all changes before releasing
- **Notarization fails**: Check Apple ID credentials and app-specific password
- **S3 upload fails**: Verify AWS credentials and bucket permissions
- **Build fails**: Ensure Xcode 16+ and valid code signing certificates
