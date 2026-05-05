//
//  SpeechRecognitionClient.swift
//  Hex
//
//  Wraps Apple's `SFSpeechRecognizer` + a dedicated `AVAudioEngine` so the
//  HUD can show a live partial transcript while the user dictates. Runs in
//  parallel with the existing `RecordingClient` (which is `AVAudioRecorder`-
//  based and writes the authoritative audio to disk for WhisperKit/Parakeet).
//
//  On macOS, multiple consumers can read from the same default input device,
//  so the speech recognizer's engine and the recorder's file write don't
//  interfere — they're separate audio paths to the same hardware.
//
//  The recognizer prefers on-device recognition when supported. Falls back
//  to the system path when the locale or hardware isn't on-device-eligible.
//

import AVFoundation
import ComposableArchitecture
import Dependencies
import DependenciesMacros
import Foundation
import HexCore
import Speech

private let speechLogger = HexLog.transcription

@DependencyClient
struct SpeechRecognitionClient {
  /// Returns `true` when speech recognition is authorized. Triggers the
  /// system permission prompt the first time it's called.
  var requestAuthorization: @Sendable () async -> Bool = { false }

  /// Begins capturing audio and yields rolling partial transcripts. Each
  /// yielded value is the full best-effort transcript so far (not a delta).
  /// The stream finishes when `stopRecognition()` is called or the engine
  /// errors out — neither is a fatal condition for the caller.
  var startRecognition: @Sendable (_ localeIdentifier: String?) async -> AsyncStream<String> = { _ in
    AsyncStream { _ in }
  }

  /// Tears down the engine + recognition task. Safe to call repeatedly.
  var stopRecognition: @Sendable () async -> Void = {}
}

extension SpeechRecognitionClient: DependencyKey {
  static var liveValue: Self {
    let live = SpeechRecognitionLive()
    return Self(
      requestAuthorization: { await live.requestAuthorization() },
      startRecognition: { localeIdentifier in await live.startRecognition(localeIdentifier: localeIdentifier) },
      stopRecognition: { await live.stopRecognition() }
    )
  }

  static var testValue = Self()
}

extension DependencyValues {
  var speechRecognition: SpeechRecognitionClient {
    get { self[SpeechRecognitionClient.self] }
    set { self[SpeechRecognitionClient.self] = newValue }
  }
}

// MARK: - Live implementation

private actor SpeechRecognitionLive {
  private var engine: AVAudioEngine?
  private var recognizer: SFSpeechRecognizer?
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var task: SFSpeechRecognitionTask?
  private var continuation: AsyncStream<String>.Continuation?

  func requestAuthorization() async -> Bool {
    await withCheckedContinuation { continuation in
      SFSpeechRecognizer.requestAuthorization { status in
        continuation.resume(returning: status == .authorized)
      }
    }
  }

  func startRecognition(localeIdentifier: String?) -> AsyncStream<String> {
    // Tear down any prior session before starting a new one so back-to-back
    // recordings don't double-tap the input node.
    teardown()

    let stream = AsyncStream<String> { cont in
      self.continuation = cont
      cont.onTermination = { [weak self] _ in
        Task { await self?.teardown() }
      }
    }

    guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
      speechLogger.info("Live preview skipped — speech recognition not authorized")
      continuation?.finish()
      return stream
    }

    let locale = localeIdentifier.map(Locale.init(identifier:)) ?? Locale.current
    let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer()
    guard let recognizer, recognizer.isAvailable else {
      speechLogger.info("Live preview skipped — recognizer unavailable for locale \(locale.identifier, privacy: .public)")
      continuation?.finish()
      return stream
    }

    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    if recognizer.supportsOnDeviceRecognition {
      request.requiresOnDeviceRecognition = true
    }

    let engine = AVAudioEngine()
    let inputNode = engine.inputNode
    let inputFormat = inputNode.outputFormat(forBus: 0)
    // Some virtual / aggregate devices report 0-channel formats at boot;
    // the tap install will throw and we just skip the live preview rather
    // than crash the recording flow.
    guard inputFormat.channelCount > 0 else {
      speechLogger.info("Live preview skipped — input format has 0 channels")
      continuation?.finish()
      return stream
    }

    inputNode.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
      Task { await self?.append(buffer: buffer) }
    }

    do {
      engine.prepare()
      try engine.start()
    } catch {
      speechLogger.error("Live preview engine failed to start: \(error.localizedDescription, privacy: .public)")
      inputNode.removeTap(onBus: 0)
      continuation?.finish()
      return stream
    }

    self.engine = engine
    self.recognizer = recognizer
    self.request = request
    self.task = recognizer.recognitionTask(with: request) { [weak self] result, error in
      guard let self else { return }
      if let result {
        let text = result.bestTranscription.formattedString
        Task { await self.yield(text) }
      }
      if error != nil || (result?.isFinal ?? false) {
        Task { await self.teardown() }
      }
    }

    speechLogger.info("Live preview started locale=\(locale.identifier, privacy: .public) onDevice=\(recognizer.supportsOnDeviceRecognition, privacy: .public)")
    return stream
  }

  func stopRecognition() {
    teardown()
  }

  // MARK: - Private

  private func append(buffer: AVAudioPCMBuffer) {
    request?.append(buffer)
  }

  private func yield(_ text: String) {
    continuation?.yield(text)
  }

  private func teardown() {
    if let engine, engine.isRunning {
      engine.inputNode.removeTap(onBus: 0)
      engine.stop()
    }
    request?.endAudio()
    task?.cancel()
    task = nil
    request = nil
    recognizer = nil
    engine = nil
    continuation?.finish()
    continuation = nil
  }
}
