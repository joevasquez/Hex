# Quill iOS Keyboard — Xcode target setup

The source files for the dictation keyboard live in `QuillKeyboard/`.
Custom keyboards require a dedicated target with a specific Info.plist
schema, an embed build phase, an App Group entitlement, and (for
AI Enhance) a shared keychain access group. Most of that is too
fragile to hand-edit in `project.pbxproj`, so this one-time setup
happens in the Xcode UI. Allow ~10 minutes.

## 1. Add the keyboard extension target

1. Open `Hex.xcodeproj` in Xcode.
2. File → New → Target… → iOS → **Custom Keyboard Extension** → Next.
3. Configure:
   - **Product Name:** `QuillKeyboard`
   - **Bundle Identifier:** `com.joevasquez.Quill.iOS.QuillKeyboard`
   - **Team:** `ND4KZ9EE2W`
   - **Language:** Swift
4. Finish. When prompted to activate the scheme, click **Cancel**
   (we always run the keyboard via the host scheme).

## 2. Wire in the files we wrote

Xcode generates a stub `QuillKeyboard/` folder with a stub
`KeyboardViewController.swift` and `Info.plist`. Replace those:

1. Delete the stub files Xcode generated:
   - `KeyboardViewController.swift` (the stub) — move to trash
   - `Info.plist` (the stub) — move to trash
2. In the Project Navigator, right-click `QuillKeyboard` → **Add Files to "Hex"…**
   and select the files in `QuillKeyboard/`:
   - `QuillKeyboardController.swift`
   - `KeyboardRootView.swift`
   - `KeyboardRecordingViewModel.swift`
   - `AIEnhanceClient.swift`
   - `Info.plist`
   - `QuillKeyboard.entitlements`
   - **Copy items if needed:** off
   - **Add to target:** only `QuillKeyboard` (NOT the main `Quill iOS` target).
3. Target **`QuillKeyboard`** → Build Settings:
   - `INFOPLIST_FILE` → `QuillKeyboard/Info.plist`
   - `CODE_SIGN_ENTITLEMENTS` → `QuillKeyboard/QuillKeyboard.entitlements`
   - `IPHONEOS_DEPLOYMENT_TARGET` → match the main `Quill iOS` target.

## 3. App Group capability

Both the main app and the keyboard need the same App Group so the
keyboard can read provider preferences (Anthropic vs OpenAI) the user
already configured in Settings.

1. Target **`Quill iOS`** → Signing & Capabilities. The App Group
   `group.com.joevasquez.Quill` should already be there (added by the
   widget). If not, `+ Capability` → **App Groups** → add it.
2. Target **`QuillKeyboard`** → Signing & Capabilities → `+ Capability` →
   **App Groups** → check the same `group.com.joevasquez.Quill` box.

## 4. Shared keychain access group (required for Enhance)

The "Enhance" toggle pipes the transcript through Anthropic / OpenAI
using whatever API key the user already pasted into the main app's
Settings. To give the keyboard read access without re-prompting for
keys, both targets share a keychain access group.

1. Target **`Quill iOS`** → Signing & Capabilities → `+ Capability` →
   **Keychain Sharing**.
2. Add an entry: `com.joevasquez.Quill.shared`. Xcode prefixes it with
   the team ID at build time.
3. Target **`QuillKeyboard`** → Signing & Capabilities → `+ Capability` →
   **Keychain Sharing** → add the same entry: `com.joevasquez.Quill.shared`.
4. Open `Quill iOS/Clients/KeychainStore.swift` and add the access
   group to both `save` and `read`:
   ```swift
   private static let accessGroup = "com.joevasquez.Quill.shared"

   private static func baseQuery(account: String) -> [String: Any] {
     [
       kSecClass as String: kSecClassGenericPassword,
       kSecAttrService as String: service,
       kSecAttrAccount as String: account,
       kSecAttrAccessGroup as String: accessGroup,
     ]
   }
   ```
   (The keyboard already reads with this access group via
   `KeyboardKeychain.readSharedKey` in `AIEnhanceClient.swift`.)
5. Have the user open Settings in the main app and re-save their
   Anthropic / OpenAI API key once after this change. Old items
   without the access group attribute won't be visible to the
   keyboard.

If you skip this step, the keyboard still works — it just falls back
to inserting the raw transcript and the Enhance toggle is greyed out.

## 5. Embed Foundation Extensions

Verify the main `Quill iOS` target embeds the keyboard automatically:

1. Target **`Quill iOS`** → Build Phases → look for
   **Embed Foundation Extensions** (Xcode auto-creates this when you
   add the keyboard target). `QuillKeyboard.appex` should be listed.
   If not, `+` → add it. Code Sign On Copy: on.

## 6. Verify

1. Scheme picker → `Quill iOS` → Run on a real device (the simulator
   doesn't have a microphone for keyboard extensions).
2. Settings → General → Keyboard → Keyboards → Add New Keyboard… →
   **Quill** → tap to enable.
3. Tap the same row again → toggle **Allow Full Access** on. iOS will
   warn you that the keyboard can transmit data — it's required for
   AI Enhance (network access) and the shared keychain.
4. Open any text app, tap into a field, long-press the globe key →
   pick **Quill**.
5. Tap Dictate → speak → tap Stop. The transcript inserts at the cursor.
6. Toggle **Enhance** on, dictate again. The text should be polished
   to match the surrounding context.

## 7. TestFlight

Archive the `Quill iOS` scheme as usual (`bash tools/scripts/testflight.sh`).
Xcode automatically embeds the keyboard extension into the archived
`.ipa` because of the embed build phase added in step 5.

## Architecture notes

- **Memory:** keyboard extensions are capped at ~48 MB on iPhone, so
  WhisperKit is intentionally NOT linked here. Transcription uses
  `SFSpeechRecognizer` (on-device when the locale supports it). v2
  could revisit this with a tiny custom Whisper variant or Apple's
  forthcoming `SpeechAnalyzer` API.
- **Context-aware enhance:** before each AI call, the keyboard reads
  `textDocumentProxy.documentContextBeforeInput` and
  `documentContextAfterInput`. Those snippets are injected into the
  system prompt so the model can match the surrounding tone (Slack
  thread vs email body vs search bar).
- **Open Access detection:** `KeyboardRecordingViewModel.refreshOpenAccess()`
  probes via `UIPasteboard.general.hasStrings` — sandboxed keyboards
  can't read the pasteboard, so a successful read is a reliable proxy
  for "Full Access is on".
- **No speech-recognition prompt UI:** the keyboard requests both mic
  and speech permissions inline on first tap. iOS surfaces the system
  dialogs above the keyboard automatically.
- **Provider preference:** read from
  `UserDefaults(suiteName: "group.com.joevasquez.Quill")` under the
  same key the main app writes (`quill.aiProvider`). The keyboard
  never writes this — Settings stays single-source-of-truth.
