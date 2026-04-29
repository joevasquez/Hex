//
//  TranscriptionFeature.swift
//  Hex
//
//  Created by Kit Langton on 1/24/25.
//

import ApplicationServices
import ComposableArchitecture
import CoreGraphics
import Foundation
import HexCore
import Inject
import SwiftUI
import WhisperKit

private let transcriptionFeatureLogger = HexLog.transcription

@Reducer
struct TranscriptionFeature {
  @ObservableState
  struct State {
    var isRecording: Bool = false
    var isTranscribing: Bool = false
    var isPrewarming: Bool = false
    var isAIProcessing: Bool = false
    var error: String?
    var recordingStartTime: Date?
    var meter: Meter = .init(averagePower: 0, peakPower: 0)
    var sourceAppBundleID: String?
    var sourceAppName: String?
    var capturedContext: AppContext?
    var partialTranscript: String = ""
    /// Set at recording-start when `inlineEditEnabled` is on AND the
    /// focused app had a non-empty selection. When this is non-nil,
    /// the dictation is interpreted as an *instruction* for editing
    /// this text rather than as new content to paste. The transcript
    /// pipeline branches on this at finalize time.
    var inlineEditSelection: String?
    /// User-selected mode for the HUD pill. Cycles through
    /// Dictate → Edit → Action on tap.
    var selectedMode: TranscriptionIndicatorView.Mode = .dictate
    /// Transient message shown when the user tries to record in
    /// Edit mode without highlighting text. Auto-dismissed after 3s.
    var editNeedsSelectionMessage: String?
    /// After an inline edit replaces text, holds the original so
    /// the user can accept (✓) or undo (✗) from the HUD.
    var pendingEditResult: PendingEditResult?
    var pendingAction: ActionIntent?
    var isActionExecuting: Bool = false
    @Shared(.hexSettings) var hexSettings: HexSettings
    @Shared(.isRemappingScratchpadFocused) var isRemappingScratchpadFocused: Bool = false
    @Shared(.modelBootstrapState) var modelBootstrapState: ModelBootstrapState
    @Shared(.transcriptionHistory) var transcriptionHistory: TranscriptionHistory
  }

  enum Action {
    case task
    case audioLevelUpdated(Meter)

    // Hotkey actions
    case hotKeyPressed
    case hotKeyReleased

    // Recording flow
    case startRecording
    case stopRecording

    // Cancel/discard flow
    case cancel   // Explicit cancellation with sound
    case discard  // Silent discard (too short/accidental)

    // Transcription result flow
    case transcriptionResult(String, URL)
    case transcriptionError(Error, URL?)
    case aiProcessingFinished
    case contextCaptured(AppContext)
    case partialTranscriptUpdated(String)
    /// Fired after AX finishes reading the selection at recording-
    /// start (see `inlineEdit.captureSelection`). Non-nil value
    /// tells the finalize path to treat the dictation as an edit
    /// instruction and replace this selection rather than paste.
    case inlineEditSelectionCaptured(String)

    // Mode cycling
    case cycleMode

    // Edit mode
    case editNeedsSelectionDismiss
    /// Result of the clipboard fallback capture (Cmd+C → read).
    /// Sent when AX-based selection reading failed and we tried the
    /// clipboard path instead.
    case editClipboardFallbackResult(String?)
    case inlineEditApplied(PendingEditResult)
    case inlineEditAccept
    case inlineEditUndo

    // Action mode
    case actionIntentParsed(ActionIntent)
    case actionParsingFailed(String)
    case actionExecuted
    case actionCancelled
    case presentActionConfirmation(ActionIntent)

    // Model availability
    case modelMissing
  }

  /// Holds enough context to undo an inline edit.
  struct PendingEditResult: Equatable {
    let original: String
    let edited: String
    let sourceAppBundleID: String?
  }

  enum CancelID {
    case metering
    case recordingCleanup
    case transcription
    case liveTranscription
    case editNeedsSelectionTimer
    case editAcceptanceTimer
  }

  @Dependency(\.transcription) var transcription
  @Dependency(\.recording) var recording
  @Dependency(\.pasteboard) var pasteboard
  @Dependency(\.keyEventMonitor) var keyEventMonitor
  @Dependency(\.soundEffects) var soundEffect
  @Dependency(\.sleepManagement) var sleepManagement
  @Dependency(\.date.now) var now
  @Dependency(\.transcriptPersistence) var transcriptPersistence
  @Dependency(\.aiProcessing) var aiProcessing
  @Dependency(\.contextClient) var contextClient
  @Dependency(\.inlineEdit) var inlineEdit
  @Dependency(\.actionParsing) var actionParsing

  var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      // MARK: - Lifecycle / Setup

      case .task:
        // Starts two concurrent effects:
        // 1) Observing audio meter
        // 2) Monitoring hot key events
        // 3) Priming the recorder for instant startup
        return .merge(
          startMeteringEffect(),
          startHotKeyMonitoringEffect(),
          warmUpRecorderEffect()
        )

      // MARK: - Metering

      case let .audioLevelUpdated(meter):
        state.meter = meter
        return .none

      // MARK: - HotKey Flow

      case .hotKeyPressed:
        // If we're transcribing, send a cancel first. Otherwise start recording immediately.
        // We'll decide later (on release) whether to keep or discard the recording.
        return handleHotKeyPressed(isTranscribing: state.isTranscribing)

      case .hotKeyReleased:
        // If we're currently recording, then stop. Otherwise, just cancel
        // the delayed "startRecording" effect if we never actually started.
        return handleHotKeyReleased(isRecording: state.isRecording)

      // MARK: - Recording Flow

      case .startRecording:
        return handleStartRecording(&state)

      case .stopRecording:
        return handleStopRecording(&state)

      // MARK: - Transcription Results

      case let .transcriptionResult(result, audioURL):
        return handleTranscriptionResult(&state, result: result, audioURL: audioURL)

      case let .transcriptionError(error, audioURL):
        return handleTranscriptionError(&state, error: error, audioURL: audioURL)

      case .aiProcessingFinished:
        state.isAIProcessing = false
        return .none

      case let .contextCaptured(context):
        state.capturedContext = context
        return .none

      case let .partialTranscriptUpdated(text):
        state.partialTranscript = text
        return .none

      case let .inlineEditSelectionCaptured(selection):
        state.inlineEditSelection = selection
        transcriptionFeatureLogger.info("Inline edit: captured selection (\(selection.count) chars)")
        return .none

      case .cycleMode:
        state.selectedMode = state.selectedMode.next
        let modeName = state.selectedMode.rawValue
        transcriptionFeatureLogger.info("Mode cycled to \(modeName)")
        return .none

      // MARK: - Edit Mode

      case .editNeedsSelectionDismiss:
        state.editNeedsSelectionMessage = nil
        return .none

      case let .editClipboardFallbackResult(selection):
        if let selection {
          state.inlineEditSelection = selection
          let charCount = selection.count
          transcriptionFeatureLogger.info(
            "Edit mode: clipboard fallback captured \(charCount) chars"
          )
          return .none
        } else {
          state.editNeedsSelectionMessage = "Highlight text first"
          state.isTranscribing = false
          state.isPrewarming = false
          transcriptionFeatureLogger.notice(
            "Edit mode: both AX and clipboard capture failed — cancelling transcription, showing selection hint"
          )
          return .merge(
            .cancel(id: CancelID.transcription),
            .run { [soundEffect] send in
              soundEffect.play(.cancel)
              try? await Task.sleep(for: .seconds(3))
              await send(.editNeedsSelectionDismiss)
            }
            .cancellable(id: CancelID.editNeedsSelectionTimer, cancelInFlight: true)
          )
        }

      case let .inlineEditApplied(pending):
        state.pendingEditResult = pending
        // Auto-accept after 8 seconds if the user doesn't act.
        return .run { send in
          try? await Task.sleep(for: .seconds(8))
          await send(.inlineEditAccept)
        }
        .cancellable(id: CancelID.editAcceptanceTimer, cancelInFlight: true)

      case .inlineEditAccept:
        state.pendingEditResult = nil
        return .cancel(id: CancelID.editAcceptanceTimer)

      case .inlineEditUndo:
        guard let pending = state.pendingEditResult else { return .none }
        state.pendingEditResult = nil
        let original = pending.original
        let bundleID = pending.sourceAppBundleID
        return .merge(
          .cancel(id: CancelID.editAcceptanceTimer),
          .run { [inlineEdit, pasteboard] _ in
            // Re-select and replace with the original text via AX.
            // If AX fails, paste the original so the user can
            // manually undo.
            let restored = await inlineEdit.replaceSelection(original)
            if !restored {
              transcriptionFeatureLogger.warning("Inline edit undo: AX restore failed; pasting original")
              await pasteboard.paste(original, bundleID)
            }
            soundEffect.play(.cancel)
          }
        )

      // MARK: - Action Mode

      case let .actionIntentParsed(intent):
        state.pendingAction = intent
        return .send(.presentActionConfirmation(intent))

      case let .actionParsingFailed(rawText):
        transcriptionFeatureLogger.warning("Action parsing failed; falling back to paste")
        let bundleID = state.sourceAppBundleID
        return .run { [pasteboard] _ in
          await pasteboard.paste(rawText, bundleID)
          soundEffect.play(.pasteTranscript)
        }

      case .actionExecuted:
        state.pendingAction = nil
        return .none

      case .actionCancelled:
        state.pendingAction = nil
        return .none

      case let .presentActionConfirmation(intent):
        transcriptionFeatureLogger.info("Posting action confirmation notification for intent: \(intent.title, privacy: .private)")
        return .run { _ in
          await MainActor.run {
            ActionConfirmationNotification.post(intent: intent)
          }
        }

      case .modelMissing:
        return .none

      // MARK: - Cancel/Discard Flow

      case .cancel:
        // Only cancel if we're in the middle of recording, transcribing, or post-processing
        guard state.isRecording || state.isTranscribing else {
          return .none
        }
        return handleCancel(&state)

      case .discard:
        // Silent discard for quick/accidental recordings
        guard state.isRecording else {
          return .none
        }
        return handleDiscard(&state)
      }
    }
  }
}

// MARK: - Effects: Metering & HotKey

private extension TranscriptionFeature {
  /// Effect to begin observing the audio meter.
  func startMeteringEffect() -> Effect<Action> {
    .run { send in
      for await meter in await recording.observeAudioLevel() {
        await send(.audioLevelUpdated(meter))
      }
    }
    .cancellable(id: CancelID.metering, cancelInFlight: true)
  }

  /// Effect to start monitoring hotkey events through the `keyEventMonitor`.
  func startHotKeyMonitoringEffect() -> Effect<Action> {
    .run { send in
      nonisolated(unsafe) var hotKeyProcessor: HotKeyProcessor = .init(hotkey: HotKey(key: nil, modifiers: [.option]))
      let _isSettingHotKey = Shared(wrappedValue: false, .isSettingHotKey)
      let _hexSettings = Shared(wrappedValue: HexSettings(), .hexSettings)

      // Handle incoming input events (keyboard and mouse)
      let token = keyEventMonitor.handleInputEvent { inputEvent in
        // Skip if the user is currently setting a hotkey
        if _isSettingHotKey.wrappedValue {
          return false
        }

        let hexSettings = _hexSettings.wrappedValue
        // Always keep hotKeyProcessor in sync with current user hotkey preference
        hotKeyProcessor.hotkey = hexSettings.hotkey
        let useDoubleTapOnly = hexSettings.doubleTapLockEnabled && hexSettings.useDoubleTapOnly
        hotKeyProcessor.doubleTapLockEnabled = hexSettings.doubleTapLockEnabled
        hotKeyProcessor.useDoubleTapOnly = useDoubleTapOnly
        hotKeyProcessor.minimumKeyTime = hexSettings.minimumKeyTime

        switch inputEvent {
        case .keyboard(let keyEvent):
          // If Escape is pressed with no modifiers while idle, let's treat that as `cancel`.
          if keyEvent.key == .escape, keyEvent.modifiers.isEmpty,
             hotKeyProcessor.state == .idle
          {
            Task { await send(.cancel) }
            return false
          }

          // Process the key event
          switch hotKeyProcessor.process(keyEvent: keyEvent) {
          case .startRecording:
            // If double-tap lock is triggered, we start recording immediately
            if hotKeyProcessor.state == .doubleTapLock {
              Task { await send(.startRecording) }
            } else {
              Task { await send(.hotKeyPressed) }
            }
            // If the hotkey is purely modifiers, return false to keep it from interfering with normal usage
            // But if useDoubleTapOnly is true, always intercept the key
            return useDoubleTapOnly || keyEvent.key != nil

          case .stopRecording:
            Task { await send(.hotKeyReleased) }
            return false // or `true` if you want to intercept

          case .cancel:
            Task { await send(.cancel) }
            return true

          case .discard:
            Task { await send(.discard) }
            return false // Don't intercept - let the key chord reach other apps

          case .none:
            // If we detect repeated same chord, maybe intercept.
            if let pressedKey = keyEvent.key,
               pressedKey == hotKeyProcessor.hotkey.key,
               keyEvent.modifiers == hotKeyProcessor.hotkey.modifiers
            {
              return true
            }
            return false
          }

        case .mouseClick:
          // Process mouse click - for modifier-only hotkeys, this may cancel/discard
          switch hotKeyProcessor.processMouseClick() {
          case .cancel:
            Task { await send(.cancel) }
            return false // Don't intercept the click itself
          case .discard:
            Task { await send(.discard) }
            return false // Don't intercept the click itself
          case .startRecording, .stopRecording, .none:
            return false
          }
        }
      }

      defer { token.cancel() }

      await withTaskCancellationHandler {
        while !Task.isCancelled {
          try? await Task.sleep(for: .seconds(60))
        }
      } onCancel: {
        token.cancel()
      }
    }
  }

  func warmUpRecorderEffect() -> Effect<Action> {
    .run { _ in
      await recording.warmUpRecorder()
    }
  }

  /// Periodically snapshots the in-progress recording and transcribes it for live display.
  func startLiveTranscriptionEffect(model: String, language: String?) -> Effect<Action> {
    .run { send in
      transcriptionFeatureLogger.info("Live transcription started, waiting 1.5s for initial audio...")
      try? await Task.sleep(for: .seconds(1.5))

      while !Task.isCancelled {
        if let snapshotURL = await recording.snapshotCurrentRecording() {
          transcriptionFeatureLogger.info("Live transcription: got snapshot, transcribing...")
          do {
            let options = DecodingOptions(
              language: language,
              detectLanguage: language == nil,
              chunkingStrategy: .vad
            )
            let result = try await transcription.transcribe(snapshotURL, model, options) { _ in }
            if !result.isEmpty {
              transcriptionFeatureLogger.info("Live transcript partial: '\(result)'")
              await send(.partialTranscriptUpdated(result))
            }
          } catch {
            transcriptionFeatureLogger.warning("Live transcription chunk failed: \(error.localizedDescription)")
          }
          try? FileManager.default.removeItem(at: snapshotURL)
        } else {
          transcriptionFeatureLogger.debug("Live transcription: no snapshot available")
        }

        try? await Task.sleep(for: .seconds(1.5))
      }
    }
    .cancellable(id: CancelID.liveTranscription, cancelInFlight: true)
  }
}

// MARK: - HotKey Press/Release Handlers

private extension TranscriptionFeature {
  func handleHotKeyPressed(isTranscribing: Bool) -> Effect<Action> {
    // If already transcribing, cancel first. Otherwise start recording immediately.
    let maybeCancel = isTranscribing ? Effect.send(Action.cancel) : .none
    let startRecording = Effect.send(Action.startRecording)
    return .merge(maybeCancel, startRecording)
  }

  func handleHotKeyReleased(isRecording: Bool) -> Effect<Action> {
    // Always stop recording when hotkey is released
    return isRecording ? .send(.stopRecording) : .none
  }
}

// MARK: - Recording Handlers

private extension TranscriptionFeature {
  func handleStartRecording(_ state: inout State) -> Effect<Action> {
    guard state.modelBootstrapState.isModelReady else {
      return .merge(
        .send(.modelMissing),
        .run { _ in soundEffect.play(.cancel) }
      )
    }
    state.pendingEditResult = nil
    state.editNeedsSelectionMessage = nil
    state.capturedContext = nil
    state.partialTranscript = ""
    state.inlineEditSelection = nil

    // Capture the active application
    if let activeApp = NSWorkspace.shared.frontmostApplication {
      state.sourceAppBundleID = activeApp.bundleIdentifier
      state.sourceAppName = activeApp.localizedName
    }

    // All modes (Dictate, Edit, Action) take the same path here.
    // Edit-mode selection capture is deferred to handleStopRecording
    // so no AX / clipboard work can interfere with recording start.
    return beginRecording(&state)
  }

  /// Start audio recording and associated effects (sound, sleep
  /// prevention, context capture). Mode-agnostic — Edit-mode
  /// selection capture happens later in `handleStopRecording`.
  func beginRecording(_ state: inout State) -> Effect<Action> {
    state.isRecording = true
    let startTime = now
    state.recordingStartTime = startTime
    transcriptionFeatureLogger.notice("Recording started at \(startTime.ISO8601Format())")

    let contextEnrichmentEnabled = state.hexSettings.contextEnrichmentEnabled && state.hexSettings.aiProcessingEnabled

    return .merge(
      .cancel(id: CancelID.recordingCleanup),
      .cancel(id: CancelID.liveTranscription),
      .run { [sleepManagement, contextClient, preventSleep = state.hexSettings.preventSystemSleep] send in
        // Play sound immediately for instant feedback
        soundEffect.play(.startRecording)

        if preventSleep {
          await sleepManagement.preventSleep(reason: "Hex Voice Recording")
        }

        // Capture context from active app before recording starts
        if contextEnrichmentEnabled {
          let context = await contextClient.captureContext()
          await send(.contextCaptured(context))
        }

        await recording.startRecording()
      },
      // Live transcription is disabled for now — chunked transcription conflicts with
      // the single-model architecture, causing the model lock to stall the event tap
      // and freeze keyboard/mouse input. Needs a dedicated lightweight model or
      // streaming API to work safely.
      // TODO: Re-enable with a separate model instance or WhisperKit streaming API
      .none
    )
  }

  func handleStopRecording(_ state: inout State) -> Effect<Action> {
    state.isRecording = false
    state.partialTranscript = ""
    
    let stopTime = now
    let startTime = state.recordingStartTime
    let duration = startTime.map { stopTime.timeIntervalSince($0) } ?? 0

    let decision = RecordingDecisionEngine.decide(
      .init(
        hotkey: state.hexSettings.hotkey,
        minimumKeyTime: state.hexSettings.minimumKeyTime,
        recordingStartTime: state.recordingStartTime,
        currentTime: stopTime
      )
    )

    let startStamp = startTime?.ISO8601Format() ?? "nil"
    let stopStamp = stopTime.ISO8601Format()
    let minimumKeyTime = state.hexSettings.minimumKeyTime
    let hotkeyHasKey = state.hexSettings.hotkey.key != nil
    transcriptionFeatureLogger.notice(
      "Recording stopped duration=\(String(format: "%.3f", duration))s start=\(startStamp) stop=\(stopStamp) decision=\(String(describing: decision)) minimumKeyTime=\(String(format: "%.2f", minimumKeyTime)) hotkeyHasKey=\(hotkeyHasKey)"
    )

    guard decision == .proceedToTranscription else {
      // If the user recorded for less than minimumKeyTime and the hotkey is modifier-only,
      // discard the audio to avoid accidental triggers.
      transcriptionFeatureLogger.notice("Discarding short recording per decision \(String(describing: decision))")
      return .merge(
        .cancel(id: CancelID.liveTranscription),
        .run { _ in
          let url = await recording.stopRecording()
          guard !Task.isCancelled else { return }
          try? FileManager.default.removeItem(at: url)
        }
        .cancellable(id: CancelID.recordingCleanup, cancelInFlight: true)
      )
    }

    // ── Edit mode: capture selection at stop time ──
    //
    // Selection capture is done HERE (not at recording start) so that
    // no AX calls or clipboard work can block or delay the recording.
    // The source app is still frontmost with text highlighted because
    // the HUD is a non-activating panel, so AX reads the same state
    // the user saw when they pressed the hotkey.
    let isEditMode = state.selectedMode == .edit
    if isEditMode || state.hexSettings.inlineEditEnabled {
      if let selection = inlineEdit.captureSelectionSync() {
        state.inlineEditSelection = selection
        transcriptionFeatureLogger.info(
          "Edit capture: AX got \(selection.count) chars at stop time"
        )
      } else if !isEditMode {
        transcriptionFeatureLogger.info(
          "Inline edit enabled but no selection — normal paste path"
        )
      }
    }

    // Otherwise, proceed to transcription
    state.isTranscribing = true
    state.error = nil
    state.partialTranscript = ""
    let model = state.hexSettings.selectedModel
    let language = state.hexSettings.outputLanguage

    state.isPrewarming = true

    let transcriptionEffect: Effect<Action> = .merge(
      .cancel(id: CancelID.liveTranscription),
      .run { [sleepManagement] send in
        // Allow system to sleep again
        await sleepManagement.allowSleep()

        var audioURL: URL?
        do {
          let capturedURL = await recording.stopRecording()
          guard !Task.isCancelled else { return }
          soundEffect.play(.stopRecording)
          audioURL = capturedURL

          // Create transcription options with the selected language
          // Note: cap concurrency to avoid audio I/O overloads on some Macs
          let decodeOptions = DecodingOptions(
            language: language,
            detectLanguage: language == nil, // Only auto-detect if no language specified
            chunkingStrategy: .vad,
          )

          let result = try await transcription.transcribe(capturedURL, model, decodeOptions) { _ in }

          transcriptionFeatureLogger.notice("Transcribed audio from \(capturedURL.lastPathComponent) to text length \(result.count)")
          await send(.transcriptionResult(result, capturedURL))
        } catch {
          transcriptionFeatureLogger.error("Transcription failed: \(error.localizedDescription)")
          await send(.transcriptionError(error, audioURL))
        }
      }
      .cancellable(id: CancelID.transcription)
    )

    // If Edit mode and AX didn't capture, run clipboard fallback
    // (~150 ms) in parallel with transcription (~1-3 s). The
    // fallback result lands via editClipboardFallbackResult well
    // before handleTranscriptionResult needs it.
    if isEditMode && state.inlineEditSelection == nil {
      transcriptionFeatureLogger.info(
        "Edit mode: AX returned nil at stop — trying clipboard fallback in parallel with transcription"
      )
      return .merge(
        transcriptionEffect,
        .run { [inlineEdit] send in
          let selection = await inlineEdit.captureSelectionViaClipboard()
          await send(.editClipboardFallbackResult(selection))
        }
      )
    }

    return transcriptionEffect
  }
}

// MARK: - Transcription Handlers

private extension TranscriptionFeature {
  func handleTranscriptionResult(
    _ state: inout State,
    result rawResult: String,
    audioURL: URL
  ) -> Effect<Action> {
    state.isTranscribing = false
    state.isPrewarming = false

    // Strip Whisper's non-speech diagnostic tokens ([BLANK_AUDIO],
    // [ Silence ], [Music], [APPLAUSE], [INAUDIBLE], etc.) before any
    // downstream step sees the transcript. Otherwise those tokens leak
    // into the active app's paste buffer, word-remapping output, voice
    // command detection, and history.
    let result = WhisperOutputCleaner.clean(rawResult)

    // Check for force quit command (emergency escape hatch)
    if ForceQuitCommandDetector.matches(result) {
      transcriptionFeatureLogger.fault("Force quit voice command recognized; terminating Hex.")
      return .run { _ in
        try? FileManager.default.removeItem(at: audioURL)
        await MainActor.run {
          NSApp.terminate(nil)
        }
      }
    }

    // If empty text, nothing else to do
    guard !result.isEmpty else {
      return .none
    }

    // Voice command detection — check before any text processing.
    // Whole-utterance editor commands (undo / redo / select all) are
    // executed here and short-circuit the transcript pipeline entirely.
    // Inline punctuation and structural commands ("period",
    // "new paragraph", etc.) fall through and get substituted into the
    // text below so they work mid-sentence, not only as standalone
    // utterances.
    if state.hexSettings.voiceCommandsEnabled,
       let command = VoiceCommandDetector.detect(result),
       VoiceCommand.editorCommands.contains(command)
    {
      transcriptionFeatureLogger.info("Voice command detected: \(String(describing: command))")
      return executeVoiceCommand(command, audioURL: audioURL, sourceAppBundleID: state.sourceAppBundleID)
    }

    // Inline substitution: turn "hello comma world period new paragraph
    // done" into "Hello, world.\n\nDone" before word remapping and AI
    // post-processing run. Gated by the same voiceCommandsEnabled
    // toggle as the standalone detector.
    let commandResult: String = state.hexSettings.voiceCommandsEnabled
      ? VoiceCommandSubstituter.substitute(in: result)
      : result
    if commandResult != result {
      transcriptionFeatureLogger.info("Voice command substitutions applied")
    }

    let duration = state.recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0

    transcriptionFeatureLogger.info("Raw transcription: '\(commandResult)'")
    let remappings = state.hexSettings.wordRemappings
    let removalsEnabled = state.hexSettings.wordRemovalsEnabled
    let removals = state.hexSettings.wordRemovals
    let modifiedResult: String
    if state.isRemappingScratchpadFocused {
      modifiedResult = commandResult
      transcriptionFeatureLogger.info("Scratchpad focused; skipping word modifications")
    } else {
      var output = commandResult
      if removalsEnabled {
        let removedResult = WordRemovalApplier.apply(output, removals: removals)
        if removedResult != output {
          let enabledRemovalCount = removals.filter(\.isEnabled).count
          transcriptionFeatureLogger.info("Applied \(enabledRemovalCount) word removal(s)")
        }
        output = removedResult
      }
      let remappedResult = WordRemappingApplier.apply(output, remappings: remappings)
      if remappedResult != output {
        transcriptionFeatureLogger.info("Applied \(remappings.count) word remapping(s)")
      }
      modifiedResult = remappedResult
    }

    guard !modifiedResult.isEmpty else {
      return .none
    }

    // Resolve AI processing mode (context-aware or manual)
    let resolvedMode = resolveAIMode(state: state)
    let aiEnabled = state.hexSettings.aiProcessingEnabled && resolvedMode != .off
    let aiProvider = state.hexSettings.aiProvider

    if aiEnabled {
      state.isAIProcessing = true
      transcriptionFeatureLogger.info("AI processing enabled: \(resolvedMode.displayName) mode via \(aiProvider.displayName)")
    }

    let sourceAppBundleID = state.sourceAppBundleID
    let sourceAppName = state.sourceAppName
    let capturedContext = state.capturedContext
    let transcriptionHistory = state.$transcriptionHistory
    let inlineEditSelection = state.inlineEditSelection

    // Decision-tree log — emitted before every finalize so we can
    // see at a glance which branch (inline-edit vs normal paste)
    // is taken and why. Surfaces in Console.app under the
    // `com.joevasquez.Quill` subsystem.
    let _inlineEditEnabled = state.hexSettings.inlineEditEnabled
    let _selectionLabel: String = {
      guard let sel = inlineEditSelection else { return "nil" }
      return "captured(\(sel.count) chars)"
    }()
    let _previewSnippet = String(modifiedResult.prefix(80))
    transcriptionFeatureLogger.info(
      "Finalize: inlineEditEnabled=\(_inlineEditEnabled) inlineEditSelection=\(_selectionLabel) aiEnabled=\(aiEnabled) mode=\(resolvedMode.rawValue) preview=\"\(_previewSnippet, privacy: .private)\""
    )

    // Inline-edit branch: user had text selected when they started
    // dictating AND (Edit mode is active OR inlineEditEnabled is on).
    // Skip the normal AI mode + paste flow and instead ask the LLM
    // to transform the selection per the dictated instruction, then
    // replace it via AX. On success, surface an Accept/Undo pill.
    if let selection = inlineEditSelection, !modifiedResult.isEmpty {
      state.isAIProcessing = true
      return .run { [aiProcessing, inlineEdit, pasteboard] send in
        let userMessage = InlineEditPrompt.userMessage(
          instruction: modifiedResult,
          selection: selection
        )
        do {
          let edited = try await aiProcessing.process(
            userMessage,
            .clean,
            aiProvider,
            nil,
            InlineEditPrompt.systemPrompt
          )
          await send(.aiProcessingFinished)

          let replaced = await inlineEdit.replaceSelection(edited)
          if replaced {
            // Surface accept/undo pill in the HUD.
            await send(.inlineEditApplied(PendingEditResult(
              original: selection,
              edited: edited,
              sourceAppBundleID: sourceAppBundleID
            )))
          } else {
            transcriptionFeatureLogger.warning("Inline edit: AX replace failed; falling back to paste")
            await pasteboard.paste(edited, sourceAppBundleID)
          }
          soundEffect.play(.pasteTranscript)
          try? FileManager.default.removeItem(at: audioURL)
        } catch {
          transcriptionFeatureLogger.error("Inline edit AI failed: \(error.localizedDescription); pasting instruction as raw text")
          await send(.aiProcessingFinished)
          await pasteboard.paste(modifiedResult, sourceAppBundleID)
          try? FileManager.default.removeItem(at: audioURL)
        }
      }
      .cancellable(id: CancelID.transcription)
    }

    // Action mode branch: parse the voice command into a structured
    // action intent via the LLM, then surface the confirmation panel.
    if state.selectedMode == .action && !modifiedResult.isEmpty {
      state.isAIProcessing = true
      return .run { [actionParsing] send in
        do {
          let intent = try await actionParsing.parse(modifiedResult, aiProvider)
          await send(.aiProcessingFinished)
          await send(.actionIntentParsed(intent))
        } catch {
          transcriptionFeatureLogger.error("Action parsing failed: \(error.localizedDescription)")
          await send(.aiProcessingFinished)
          await send(.actionParsingFailed(modifiedResult))
        }
        try? FileManager.default.removeItem(at: audioURL)
      }
      .cancellable(id: CancelID.transcription)
    }

    return .run { [aiProcessing] send in
      do {
        // AI post-processing (if enabled)
        var finalResult = modifiedResult
        if aiEnabled {
          do {
            finalResult = try await aiProcessing.process(modifiedResult, resolvedMode, aiProvider, capturedContext, nil)
            transcriptionFeatureLogger.info("AI processing produced \(finalResult.count) chars from \(modifiedResult.count) chars")
          } catch {
            transcriptionFeatureLogger.error("AI processing failed, using unprocessed text: \(error.localizedDescription)")
            // Fall back to unprocessed text on AI error
          }
          await send(.aiProcessingFinished)
        }

        try await finalizeRecordingAndStoreTranscript(
          result: finalResult,
          duration: duration,
          sourceAppBundleID: sourceAppBundleID,
          sourceAppName: sourceAppName,
          audioURL: audioURL,
          transcriptionHistory: transcriptionHistory
        )
      } catch {
        await send(.transcriptionError(error, audioURL))
      }
    }
    .cancellable(id: CancelID.transcription)
  }

  /// Resolves the AI mode based on context-aware rules or manual selection.
  func resolveAIMode(state: State) -> AIProcessingMode {
    if let autoMode = AppModeResolver.resolve(
      bundleID: state.sourceAppBundleID,
      customRules: state.hexSettings.appModeRules,
      contextAwareEnabled: state.hexSettings.contextAwareAutoMode
    ) {
      return autoMode
    }
    return state.hexSettings.aiProcessingMode
  }

  /// Executes a voice command via keyboard simulation instead of pasting text.
  /// Punctuation cases (period, comma, etc.) are unreachable as of 0.8.x —
  /// `VoiceCommandSubstituter` handles those inline now; only editor
  /// commands (undo, redo, selectAll, newLine, newParagraph) reach this
  /// path via `VoiceCommand.editorCommands` filtering. Kept for safety.
  func executeVoiceCommand(
    _ command: VoiceCommand,
    audioURL: URL,
    sourceAppBundleID: String?
  ) -> Effect<Action> {
    .run { [pasteboard, soundEffect] _ in
      try? FileManager.default.removeItem(at: audioURL)

      switch command {
      case .newParagraph:
        await pasteboard.sendKeyboardCommand(.enter)
        try? await Task.sleep(for: .milliseconds(50))
        await pasteboard.sendKeyboardCommand(.enter)
      case .newLine:
        await pasteboard.sendKeyboardCommand(.enter)
      case .selectAll:
        await pasteboard.sendKeyboardCommand(.init(key: .a, modifiers: [.command]))
      case .undo:
        await pasteboard.sendKeyboardCommand(.init(key: .z, modifiers: [.command]))
      case .redo:
        await pasteboard.sendKeyboardCommand(.init(key: .z, modifiers: [.command, .shift]))
      case .period:
        await pasteboard.paste(".", sourceAppBundleID)
      case .comma:
        await pasteboard.paste(",", sourceAppBundleID)
      case .questionMark:
        await pasteboard.paste("?", sourceAppBundleID)
      case .exclamationMark:
        await pasteboard.paste("!", sourceAppBundleID)
      }

      soundEffect.play(.pasteTranscript)
    }
  }

  func handleTranscriptionError(
    _ state: inout State,
    error: Error,
    audioURL: URL?
  ) -> Effect<Action> {
    state.isTranscribing = false
    state.isPrewarming = false
    state.error = error.localizedDescription
    
    if let audioURL {
      try? FileManager.default.removeItem(at: audioURL)
    }

    return .none
  }

  /// Move file to permanent location, create a transcript record, paste text, and play sound.
  func finalizeRecordingAndStoreTranscript(
    result: String,
    duration: TimeInterval,
    sourceAppBundleID: String?,
    sourceAppName: String?,
    audioURL: URL,
    transcriptionHistory: Shared<TranscriptionHistory>
  ) async throws {
    @Shared(.hexSettings) var hexSettings: HexSettings

    if hexSettings.saveTranscriptionHistory {
      let transcript = try await transcriptPersistence.save(
        result,
        audioURL,
        duration,
        sourceAppBundleID,
        sourceAppName
      )

      transcriptionHistory.withLock { history in
        history.history.insert(transcript, at: 0)

        if let maxEntries = hexSettings.maxHistoryEntries, maxEntries > 0 {
          while history.history.count > maxEntries {
            if let removedTranscript = history.history.popLast() {
              Task {
                 try? await transcriptPersistence.deleteAudio(removedTranscript)
              }
            }
          }
        }
      }
    } else {
      try? FileManager.default.removeItem(at: audioURL)
    }

    await pasteboard.paste(result, sourceAppBundleID)
    soundEffect.play(.pasteTranscript)
  }
}

// MARK: - Cancel/Discard Handlers

private extension TranscriptionFeature {
  func handleCancel(_ state: inout State) -> Effect<Action> {
    state.isTranscribing = false
    state.isRecording = false
    state.isPrewarming = false
    state.isAIProcessing = false
    state.partialTranscript = ""

    return .merge(
      .cancel(id: CancelID.transcription),
      .cancel(id: CancelID.liveTranscription),
      .run { [sleepManagement] _ in
        // Allow system to sleep again
        await sleepManagement.allowSleep()
        // Stop the recording to release microphone access
        let url = await recording.stopRecording()
        guard !Task.isCancelled else { return }
        try? FileManager.default.removeItem(at: url)
        soundEffect.play(.cancel)
      }
      .cancellable(id: CancelID.recordingCleanup, cancelInFlight: true)
    )
  }

  func handleDiscard(_ state: inout State) -> Effect<Action> {
    state.isRecording = false
    state.isPrewarming = false

    // Silently discard - no sound effect
    return .run { [sleepManagement] _ in
      // Allow system to sleep again
      await sleepManagement.allowSleep()
      let url = await recording.stopRecording()
      guard !Task.isCancelled else { return }
      try? FileManager.default.removeItem(at: url)
    }
    .cancellable(id: CancelID.recordingCleanup, cancelInFlight: true)
  }
}

// MARK: - View

struct TranscriptionView: View {
  @Bindable var store: StoreOf<TranscriptionFeature>
  @ObserveInjection var inject

  var status: TranscriptionIndicatorView.Status {
    if store.isAIProcessing {
      return .aiProcessing
    } else if store.isTranscribing {
      return .transcribing
    } else if store.isRecording {
      return .recording
    } else {
      return .idle
    }
  }

  private var hotkeyHint: String {
    let hotkey = store.hexSettings.hotkey
    var parts: [String] = []
    if hotkey.modifiers.isHyperkey {
      parts.append("Hyper")
    } else {
      for mod in hotkey.modifiers.sorted {
        parts.append(mod.kind.symbol)
      }
    }
    if let key = hotkey.key {
      switch key {
      case .space: parts.append("Space")
      case .escape: parts.append("Esc")
      default: parts.append(key.toString)
      }
    }
    let keys = parts.joined(separator: " ")
    let verb: String = switch store.selectedMode {
    case .dictate: "to dictate"
    case .edit: "to edit"
    case .action: "for action"
    }
    return "Hold \(keys) \(verb)"
  }

  var body: some View {
    TranscriptionIndicatorView(
      status: status,
      mode: store.selectedMode,
      meter: store.meter,
      recordingStartTime: store.recordingStartTime,
      hotkeyHint: hotkeyHint,
      editMessage: store.editNeedsSelectionMessage,
      pendingEditResult: store.pendingEditResult,
      onCycleMode: { store.send(.cycleMode) },
      onEditUndo: { store.send(.inlineEditUndo) }
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .task {
      await store.send(.task).finish()
    }
    .enableInjection()
  }
}

// MARK: - Force Quit Command

private enum ForceQuitCommandDetector {
  static func matches(_ text: String) -> Bool {
    let normalized = normalize(text)
    return normalized == "force quit hex now" || normalized == "force quit hex"
  }

  private static func normalize(_ text: String) -> String {
    text
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
  }
}
