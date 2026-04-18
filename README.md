# Quill — Voice → Text, with AI

Press-and-hold a hotkey to transcribe your voice and paste the result wherever you're typing. Optionally run it through an AI model first to clean up grammar, format as an email, convert to bullet notes, and more.

> Apple Silicon only. macOS 15+. iOS 16+ (iOS app in beta).

## What Quill does

**macOS app (menu bar):**
- Hold a global hotkey → speak → release → transcribed text is pasted into your active app
- Fully on-device transcription via [Parakeet TDT v3](https://github.com/FluidInference/FluidAudio) (default, multilingual) or [WhisperKit](https://github.com/argmaxinc/WhisperKit)
- Optional AI post-processing (OpenAI / Anthropic) with modes: Clean, Email, Notes, Message, Code
- Context-aware auto-mode: detect active app and pick the right AI mode (Mail → Email, Slack → Message, VS Code → Code)
- Voice commands: "new paragraph", "select all", "undo", etc. are detected and executed instead of being pasted as text
- Custom vocabulary, word removals (filler words), word remappings, full transcription history
- Drag-and-drop audio/video files to transcribe

**iOS app (standalone):**
- Record voice notes on-device with Whisper
- Optionally run through your AI mode of choice
- Share via iOS share sheet: email, iMessage, Notes, clipboard

## Installation

macOS builds are distributed via GitHub Releases on this repo. iOS requires building from source in Xcode with your Apple Developer account.

## Architecture

TCA (Composable Architecture) app with:
- `HexCore` Swift Package — shared logic, models, settings (cross-platform macOS + iOS)
- `Hex/` — macOS app target
- `QuilliOS/` — iOS app target

## Credits

Quill is a fork of [**Hex** by Kit Langton](https://github.com/kitlangton/Hex), extended by [Joe Vasquez](https://joevasquez.com) with AI post-processing, context enrichment, voice commands, file transcription, and an iOS app.

The original Hex project is the foundation — all props to Kit for the clean architecture and approach.

## License

MIT License. See `LICENSE` for details.
