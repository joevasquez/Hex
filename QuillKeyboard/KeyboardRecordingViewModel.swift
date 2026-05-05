//
//  KeyboardRecordingViewModel.swift
//  QuillKeyboard
//
//  Owns the keyboard extension's recording + transcription pipeline.
//  Uses AVAudioEngine + SFSpeechRecognizer (on-device when possible)
//  because keyboard extensions are too memory-constrained for WhisperKit.
//

import AVFoundation
import Combine
import Foundation
import Speech
import UIKit

@MainActor
final class KeyboardRecordingViewModel: ObservableObject {
  enum Phase: Equatable {
    case idle
    case requestingPermission
    case recording
    case enhancing
    case error(String)
  }

  @Published var phase: Phase = .idle
  @Published var partialTranscript: String = ""
  @Published var meterLevel: Float = 0
  @Published var enhanceEnabled: Bool = false
  /// Context the host app currently has around the cursor — used to
  /// enrich the AI cleanup prompt so the model knows whether you're
  /// dictating into a Slack reply, an email body, or a search field.
  @Published private(set) var hostContextBefore: String = ""
  @Published private(set) var hostContextAfter: String = ""
  /// True when "Open Access" is granted — needed for network calls
  /// (AI cleanup) and also to read the App Group container on devices
  /// where iOS sandboxes the keyboard more aggressively.
  @Published private(set) var hasOpenAccess: Bool = false

  // Wired in by the input view controller so this VM stays UIKit-free
  // outside the bind() seam. `UITextDocumentProxy` already conforms to
  // `UIKeyInput`, so a single protocol reference is enough — and it's
  // class-bound, so `weak` is allowed.
  private weak var proxy: (any UITextDocumentProxy)?
  private var advanceKeyboardCallback: (() -> Void)?
  private var dismissKeyboardCallback: (() -> Void)?

  // Audio
  private var engine: AVAudioEngine?

  // Speech
  private var recognizer: SFSpeechRecognizer?
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var task: SFSpeechRecognitionTask?

  // MARK: - Wiring

  func bind(
    proxy: any UITextDocumentProxy,
    advanceToNextKeyboard: @escaping () -> Void,
    dismissKeyboard: @escaping () -> Void
  ) {
    self.proxy = proxy
    self.advanceKeyboardCallback = advanceToNextKeyboard
    self.dismissKeyboardCallback = dismissKeyboard
    refreshHostContext()
    refreshOpenAccess()
  }

  func refreshHostContext() {
    hostContextBefore = proxy?.documentContextBeforeInput ?? ""
    hostContextAfter = proxy?.documentContextAfterInput ?? ""
  }

  /// "Open Access" is the user-granted permission that lets a custom
  /// keyboard make network calls and share state with its containing
  /// app. We probe it via `UIPasteboard.general.hasStrings` — sandboxed
  /// keyboards can't touch the pasteboard, so a successful read is a
  /// reliable proxy. Cheap, runs once at bind time.
  private func refreshOpenAccess() {
    hasOpenAccess = UIPasteboard.general.hasStrings
      || !(UserDefaults(suiteName: "group.com.joevasquez.Quill")?.dictionaryRepresentation().isEmpty ?? true)
  }

  // MARK: - Standard keyboard actions

  func tapBackspace() {
    proxy?.deleteBackward()
  }

  func tapReturn() {
    proxy?.insertText("\n")
  }

  func tapSpace() {
    proxy?.insertText(" ")
  }

  func tapNextKeyboard() {
    advanceKeyboardCallback?()
  }

  func tapDismissKeyboard() {
    dismissKeyboardCallback?()
  }

  // MARK: - Dictation

  func toggleRecording() async {
    switch phase {
    case .recording:
      await stopAndCommit()
    case .idle, .error:
      await start()
    case .requestingPermission, .enhancing:
      // Ignore taps mid-permission / mid-AI; the UI already shows a
      // spinner so the user isn't expecting another response.
      break
    }
  }

  func cancelIfNeeded() {
    if phase == .recording {
      teardownEngine()
      partialTranscript = ""
      phase = .idle
    }
  }

  private func start() async {
    phase = .requestingPermission
    let micGranted = await requestMicPermission()
    let speechGranted = await requestSpeechPermission()
    guard micGranted, speechGranted else {
      phase = .error("Microphone & speech access required.")
      return
    }
    do {
      try beginRecording()
      phase = .recording
      partialTranscript = ""
    } catch {
      phase = .error("Couldn't start recording: \(error.localizedDescription)")
    }
  }

  private func stopAndCommit() async {
    let captured = partialTranscript
    teardownEngine()

    let trimmed = captured.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      phase = .idle
      return
    }

    let toInsert: String
    if enhanceEnabled, hasOpenAccess {
      phase = .enhancing
      refreshHostContext()
      toInsert = await enhanceWithAI(transcript: trimmed) ?? trimmed
    } else {
      toInsert = trimmed
    }

    insertIntoHost(toInsert)
    phase = .idle
    partialTranscript = ""
  }

  private func insertIntoHost(_ text: String) {
    guard let proxy else { return }
    // Match the spacing the user would expect: if the cursor sits
    // immediately after a non-whitespace character, add a leading
    // space; if the inserted text doesn't end with terminal punctuation
    // and the trailing context starts with a letter, add a trailing
    // space too.
    let before = proxy.documentContextBeforeInput ?? ""
    let needsLeadingSpace = !before.isEmpty
      && !before.hasSuffix(" ")
      && !before.hasSuffix("\n")
    let payload = (needsLeadingSpace ? " " : "") + text
    proxy.insertText(payload)
  }

  // MARK: - Permissions

  private func requestMicPermission() async -> Bool {
    if #available(iOS 17.0, *) {
      return await AVAudioApplication.requestRecordPermission()
    } else {
      return await withCheckedContinuation { cont in
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
          cont.resume(returning: granted)
        }
      }
    }
  }

  private func requestSpeechPermission() async -> Bool {
    await withCheckedContinuation { cont in
      SFSpeechRecognizer.requestAuthorization { status in
        cont.resume(returning: status == .authorized)
      }
    }
  }

  // MARK: - Audio engine + speech recognizer

  private func beginRecording() throws {
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(
      .playAndRecord,
      mode: .measurement,
      options: [.defaultToSpeaker, .allowBluetooth]
    )
    try session.setActive(true, options: .notifyOthersOnDeactivation)

    let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer()
    guard let recognizer, recognizer.isAvailable else {
      throw KeyboardError.recognizerUnavailable
    }
    self.recognizer = recognizer

    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    if recognizer.supportsOnDeviceRecognition {
      // Privacy + offline: keep the dictation on-device whenever the
      // user's locale model supports it. Falls back to network on
      // locales that don't have a downloaded model.
      request.requiresOnDeviceRecognition = true
    }
    self.request = request

    let engine = AVAudioEngine()
    let inputNode = engine.inputNode
    let format = inputNode.outputFormat(forBus: 0)

    inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
      guard let self else { return }
      // Hop to main to mutate published state. SFSpeech is fine to call
      // off main, but `request.append` is concurrency-safe on the
      // recognizer's own queue, so the cost is negligible.
      Task { @MainActor in
        self.request?.append(buffer)
      }
      // Cheap meter for the waveform.
      if let data = buffer.floatChannelData?[0] {
        let frames = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<frames { sum += abs(data[i]) }
        let level = frames > 0 ? sum / Float(frames) : 0
        Task { @MainActor in self.meterLevel = min(1, level * 4) }
      }
    }

    engine.prepare()
    try engine.start()
    self.engine = engine

    self.task = recognizer.recognitionTask(with: request) { [weak self] result, error in
      guard let self else { return }
      if let result {
        Task { @MainActor in
          self.partialTranscript = result.bestTranscription.formattedString
        }
      }
      if error != nil {
        // Silent: SFSpeech surfaces transient errors at end-of-stream
        // when we tear down. The captured `partialTranscript` is what
        // we ultimately commit, so we don't need to bubble these.
      }
    }
  }

  private func teardownEngine() {
    engine?.inputNode.removeTap(onBus: 0)
    engine?.stop()
    engine = nil
    request?.endAudio()
    request = nil
    task?.cancel()
    task = nil
    recognizer = nil
    meterLevel = 0
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }

  // MARK: - AI Enhance (Open Access required)

  /// Runs the transcript through the user's configured AI provider with
  /// a prompt that's aware of the surrounding text in the host field.
  /// Returns nil on any failure — the caller falls back to the raw
  /// transcript so the user's words aren't lost.
  private func enhanceWithAI(transcript: String) async -> String? {
    guard let request = AIEnhanceRequest.build(
      transcript: transcript,
      contextBefore: hostContextBefore,
      contextAfter: hostContextAfter
    ) else { return nil }

    do {
      return try await AIEnhanceClient.shared.send(request)
    } catch {
      // Don't surface a scary error — just fall through to the raw
      // transcript. The user still gets their dictation.
      return nil
    }
  }
}

enum KeyboardError: LocalizedError {
  case recognizerUnavailable

  var errorDescription: String? {
    switch self {
    case .recognizerUnavailable:
      "Speech recognition isn't available on this device or locale."
    }
  }
}
