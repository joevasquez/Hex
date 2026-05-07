//
//  KeyboardBridgeView.swift
//  Quill (iOS)
//
//  Full-screen surface presented when the QuillKeyboard extension opens
//  the app via `quill://keyboard?id=…&mode=…`. iOS denies microphone
//  access to keyboard extensions (non-focal processes), so the keyboard
//  trampolines recording requests to this view, which records as a
//  focal process, transcribes via WhisperKit, writes the transcript to
//  the App Group mailbox, and prompts the user to return to their host
//  app where the keyboard will pick the result up.
//
//  See `HexCore/Models/KeyboardBridge.swift` for the mailbox protocol.
//

import Combine
import HexCore
import SwiftUI
import WhisperKit

@MainActor
final class KeyboardBridgeViewModel: ObservableObject {
  enum Phase: Equatable {
    case ready
    case recording
    case transcribing
    case done(transcript: String)
    case error(String)
  }

  @Published var phase: Phase = .ready
  @Published var meterLevel: Float = 0
  @Published var elapsedSeconds: TimeInterval = 0

  let requestID: UUID
  let mode: KeyboardBridgeMode

  private let recorder = IOSRecordingClient.shared
  private var whisperKit: WhisperKit?
  private var timerTask: Task<Void, Never>?
  private var startedAt: Date?
  private var meterTask: Task<Void, Never>?

  init(requestID: UUID, mode: KeyboardBridgeMode) {
    self.requestID = requestID
    self.mode = mode
  }

  func prepare(model: String) async {
    do {
      whisperKit = try await WhisperKit(WhisperKitConfig(model: model, download: true))
    } catch {
      phase = .error("Couldn't load model: \(error.localizedDescription)")
    }
  }

  func startRecording() async {
    let micGranted = await recorder.requestPermission()
    let speechGranted = await recorder.requestSpeechPermission()
    guard micGranted, speechGranted else {
      phase = .error("Microphone & speech access required.")
      return
    }
    do {
      _ = try recorder.startRecording(livePreviewEnabled: true)
      startedAt = Date()
      phase = .recording
      timerTask = Task { [weak self] in
        while !Task.isCancelled {
          await MainActor.run {
            guard let self, let started = self.startedAt else { return }
            self.elapsedSeconds = Date().timeIntervalSince(started)
          }
          try? await Task.sleep(for: .milliseconds(200))
        }
      }
      meterTask = Task { [weak self] in
        while !Task.isCancelled {
          await MainActor.run {
            self?.meterLevel = self?.recorder.averagePower ?? 0
          }
          try? await Task.sleep(for: .milliseconds(50))
        }
      }
    } catch {
      phase = .error("Couldn't start recording: \(error.localizedDescription)")
    }
  }

  func stopAndTranscribe() async {
    timerTask?.cancel()
    meterTask?.cancel()
    timerTask = nil
    meterTask = nil
    guard let url = recorder.stopRecording() else {
      phase = .error("Recording produced no audio.")
      return
    }
    phase = .transcribing
    do {
      guard let whisperKit else {
        phase = .error("Model not loaded.")
        return
      }
      let results = try await whisperKit.transcribe(audioPath: url.path)
      let transcript = results
        .map(\.text)
        .joined(separator: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      try? FileManager.default.removeItem(at: url)

      // Write to bridge mailbox so the keyboard picks it up.
      let bridgeMode: KeyboardBridge.Mode = mode == .dictate ? .dictate : .action
      let result = KeyboardBridge.Result(
        id: requestID,
        transcript: bridgeMode == .action ? "" : transcript
      )
      KeyboardBridge.writeResult(result)
      _ = KeyboardBridge.consumeRequest()
      phase = .done(transcript: transcript)
    } catch {
      phase = .error("Transcription failed: \(error.localizedDescription)")
    }
  }

  func cancel() {
    timerTask?.cancel()
    meterTask?.cancel()
    if let url = recorder.stopRecording() {
      try? FileManager.default.removeItem(at: url)
    }
    _ = KeyboardBridge.consumeRequest()
  }
}

struct KeyboardBridgeView: View {
  @StateObject private var vm: KeyboardBridgeViewModel
  @Environment(\.dismiss) private var dismiss
  @AppStorage(QuillIOSSettingsKey.selectedModel) private var selectedModel: String = QuillIOSSettingsKey.defaultModel

  init(requestID: UUID, mode: KeyboardBridgeMode) {
    _vm = StateObject(wrappedValue: KeyboardBridgeViewModel(requestID: requestID, mode: mode))
  }

  var body: some View {
    ZStack {
      LinearGradient(
        colors: [Color(red: 0.36, green: 0.28, blue: 0.74), Color(red: 0.24, green: 0.18, blue: 0.55)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      .ignoresSafeArea()

      VStack(spacing: 14) {
        Text(headerTitle)
          .font(.system(size: 20, weight: .semibold))
          .foregroundStyle(.white)
          .multilineTextAlignment(.center)
          .padding(.horizontal, 24)
          .padding(.top, 16)

        Text(subtitle)
          .font(.system(size: 14))
          .foregroundStyle(.white.opacity(0.85))
          .multilineTextAlignment(.center)
          .padding(.horizontal, 32)

        Spacer(minLength: 0)

        meterPanel

        Spacer(minLength: 0)

        actionRow
          .padding(.bottom, 20)
      }
    }
    .task {
      await vm.prepare(model: selectedModel)
      if case .ready = vm.phase {
        await vm.startRecording()
      }
    }
  }

  private var headerTitle: String {
    switch vm.phase {
    case .ready: "Preparing…"
    case .recording: "Recording for keyboard"
    case .transcribing: "Transcribing…"
    case .done: "Ready"
    case .error(let msg): msg
    }
  }

  private var subtitle: String {
    switch vm.phase {
    case .ready: "Loading the speech model."
    case .recording: "Tap Stop when you're done."
    case .transcribing: "Converting your speech to text."
    case .done: ""
    case .error: "Try again, or close this and use the keyboard's Cancel button."
    }
  }

  private var meterPanel: some View {
    VStack(spacing: 16) {
      if case .done(let transcript) = vm.phase {
        // Show the transcript so the user has visual confirmation it
        // worked, plus a prominent swipe-up cue to nudge them back to
        // their host app.
        VStack(spacing: 14) {
          Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 44, weight: .semibold))
            .foregroundStyle(.white)
          Text(transcript.isEmpty ? "Action complete" : "\u{201C}\(transcript)\u{201D}")
            .font(.system(size: 15))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
            .lineLimit(4)
          Image(systemName: "arrow.up")
            .font(.system(size: 22, weight: .bold))
            .foregroundStyle(.white)
            .padding(.top, 6)
          Text("Swipe up → switch back to your app")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
        }
      } else {
        Image(systemName: phaseIcon)
          .font(.system(size: 56, weight: .semibold))
          .foregroundStyle(.white)

        if vm.phase == .recording {
          Text(timeString(vm.elapsedSeconds))
            .font(.system(size: 32, weight: .medium, design: .rounded).monospacedDigit())
            .foregroundStyle(.white)

          Capsule()
            .fill(.white.opacity(0.7))
            .frame(width: 8 + CGFloat(max(0, vm.meterLevel + 50) * 2.4), height: 8)
            .frame(maxWidth: 240, alignment: .leading)
            .background(Capsule().fill(.white.opacity(0.18)).frame(maxWidth: 240))
            .animation(.easeOut(duration: 0.08), value: vm.meterLevel)
        }
      }
    }
  }

  private var phaseIcon: String {
    switch vm.phase {
    case .ready: "hourglass"
    case .recording: "waveform"
    case .transcribing: "text.bubble"
    case .done: "checkmark.circle.fill"
    case .error: "exclamationmark.triangle.fill"
    }
  }

  private var actionRow: some View {
    HStack(spacing: 12) {
      switch vm.phase {
      case .recording:
        Button {
          Task { await vm.stopAndTranscribe() }
        } label: {
          Label("Stop", systemImage: "stop.fill")
            .font(.system(size: 17, weight: .semibold))
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(Capsule().fill(Color.white))
            .foregroundStyle(Color(red: 0.36, green: 0.28, blue: 0.74))
        }
      case .done, .error:
        Button {
          dismiss()
        } label: {
          Text("Close")
            .font(.system(size: 17, weight: .semibold))
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(Capsule().fill(Color.white))
            .foregroundStyle(Color(red: 0.36, green: 0.28, blue: 0.74))
        }
      case .ready, .transcribing:
        ProgressView().tint(.white)
          .frame(maxWidth: .infinity, minHeight: 56)
      }

      if !isDonePhase(vm.phase) {
        Button {
          vm.cancel()
          dismiss()
        } label: {
          Text("Cancel")
            .font(.system(size: 16, weight: .medium))
            .frame(minHeight: 56)
            .padding(.horizontal, 18)
            .background(Capsule().fill(Color.white.opacity(0.18)))
            .foregroundStyle(.white)
        }
      }
    }
    .padding(.horizontal, 24)
  }

  private func isDonePhase(_ phase: KeyboardBridgeViewModel.Phase) -> Bool {
    if case .done = phase { return true }
    return false
  }

  private func timeString(_ seconds: TimeInterval) -> String {
    let total = Int(seconds)
    let m = total / 60
    let s = total % 60
    return String(format: "%d:%02d", m, s)
  }
}
