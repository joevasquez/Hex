//
//  ContentView.swift
//  Quill (iOS)
//
//  Main screen: record → transcribe → optional AI clean-up → share.
//

import AVFoundation
import Combine
import HexCore
import SwiftUI
import UIKit
import WhisperKit

@MainActor
final class RecordingViewModel: ObservableObject {
  enum Phase: Equatable {
    case idle
    case requestingPermission
    case recording
    case transcribing
    case aiProcessing
    case done
    case error(String)
  }

  @Published var phase: Phase = .idle
  @Published var rawTranscript: String = ""
  @Published var processedTranscript: String = ""
  @Published var meterLevel: Float = 0
  @Published var elapsedSeconds: TimeInterval = 0

  private var recorder = IOSRecordingClient.shared
  private var whisperKit: WhisperKit?
  private var timerTask: Task<Void, Never>?
  private var recordingStartedAt: Date?

  var displayedText: String {
    processedTranscript.isEmpty ? rawTranscript : processedTranscript
  }

  var hasResult: Bool {
    !rawTranscript.isEmpty
  }

  func toggleRecording(
    model: String,
    mode: AIProcessingMode,
    provider: AIProvider
  ) async {
    switch phase {
    case .idle, .done, .error:
      await startRecording(model: model, mode: mode, provider: provider)
    case .recording:
      await stopAndProcess(model: model, mode: mode, provider: provider)
    default:
      break
    }
  }

  private func startRecording(
    model: String,
    mode: AIProcessingMode,
    provider: AIProvider
  ) async {
    phase = .requestingPermission
    let granted = await recorder.requestPermission()
    guard granted else {
      phase = .error("Microphone permission required. Enable it in Settings > Quill.")
      return
    }

    rawTranscript = ""
    processedTranscript = ""

    do {
      _ = try recorder.startRecording()
      recordingStartedAt = Date()
      phase = .recording
      UIImpactFeedbackGenerator(style: .medium).impactOccurred()

      // Meter + elapsed timer
      timerTask?.cancel()
      timerTask = Task { [weak self] in
        while !Task.isCancelled {
          guard let self else { return }
          self.meterLevel = self.recorder.averagePower
          if let start = self.recordingStartedAt {
            self.elapsedSeconds = Date().timeIntervalSince(start)
          }
          try? await Task.sleep(for: .milliseconds(100))
        }
      }
    } catch {
      phase = .error("Couldn't start recording: \(error.localizedDescription)")
    }
  }

  private func stopAndProcess(
    model: String,
    mode: AIProcessingMode,
    provider: AIProvider
  ) async {
    timerTask?.cancel()
    let url = recorder.stopRecording()
    phase = .transcribing
    UIImpactFeedbackGenerator(style: .light).impactOccurred()

    guard let url else {
      phase = .error("Recording file was not produced")
      return
    }

    do {
      if whisperKit == nil || whisperKit?.modelFolder?.lastPathComponent != model {
        whisperKit = try await WhisperKit(
          WhisperKitConfig(model: model, download: true)
        )
      }

      let results = try await whisperKit!.transcribe(audioPath: url.path)
      let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
      rawTranscript = text

      try? FileManager.default.removeItem(at: url)

      if text.isEmpty {
        phase = .error("No speech detected. Try again.")
        return
      }

      if mode != .off {
        phase = .aiProcessing
        do {
          processedTranscript = try await AIProcessingClient.liveValue.process(text, mode, provider, nil)
        } catch {
          processedTranscript = ""
        }
      }

      phase = .done
      UINotificationFeedbackGenerator().notificationOccurred(.success)
    } catch {
      phase = .error("Transcription failed: \(error.localizedDescription)")
    }
  }
}

struct ContentView: View {
  @AppStorage(QuillIOSSettingsKey.selectedModel) private var selectedModel: String = QuillIOSSettingsKey.defaultModel
  @AppStorage(QuillIOSSettingsKey.aiProcessingMode) private var aiModeRaw: String = QuillIOSSettingsKey.defaultMode
  @AppStorage(QuillIOSSettingsKey.aiProvider) private var aiProviderRaw: String = QuillIOSSettingsKey.defaultProvider

  @StateObject private var vm = RecordingViewModel()
  @State private var showingSettings = false
  @State private var idlePulse = false

  private var aiMode: AIProcessingMode {
    AIProcessingMode(rawValue: aiModeRaw) ?? .clean
  }

  private var aiProvider: AIProvider {
    AIProvider(rawValue: aiProviderRaw) ?? .anthropic
  }

  var body: some View {
    NavigationStack {
      ZStack {
        backgroundGradient
          .ignoresSafeArea()

        ScrollView {
          VStack(spacing: 28) {
            modeChipRow
            recordButton
            statusLabel
            resultArea
            Spacer(minLength: 40)
          }
          .padding(.horizontal)
          .padding(.top, 8)
        }
      }
      .navigationTitle("Quill")
      .navigationBarTitleDisplayMode(.large)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button {
            showingSettings = true
          } label: {
            Image(systemName: "gearshape")
              .font(.title3)
          }
        }
      }
      .sheet(isPresented: $showingSettings) {
        SettingsView()
      }
      .onAppear { idlePulse = true }
    }
  }

  // MARK: - Background

  private var backgroundGradient: some View {
    LinearGradient(
      colors: [
        Color.purple.opacity(0.08),
        Color.blue.opacity(0.04),
        Color(.systemBackground),
      ],
      startPoint: .topLeading,
      endPoint: .bottomTrailing
    )
  }

  // MARK: - Mode chips

  @ViewBuilder
  private var modeChipRow: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        ForEach(AIProcessingMode.allCases, id: \.rawValue) { mode in
          ModeChip(
            mode: mode,
            isSelected: mode == aiMode,
            action: {
              UISelectionFeedbackGenerator().selectionChanged()
              aiModeRaw = mode.rawValue
            }
          )
        }
      }
      .padding(.horizontal, 4)
    }
    .scrollClipDisabled()
  }

  // MARK: - Record button

  @ViewBuilder
  private var recordButton: some View {
    let isRecording = vm.phase == .recording
    let isBusy: Bool = {
      switch vm.phase {
      case .transcribing, .aiProcessing, .requestingPermission: return true
      default: return false
      }
    }()

    let buttonTint: Color = isRecording ? .red : (aiMode == .off ? .blue : .purple)
    let level = CGFloat(vm.meterLevel)

    Button {
      Task {
        await vm.toggleRecording(
          model: selectedModel,
          mode: aiMode,
          provider: aiProvider
        )
      }
    } label: {
      ZStack {
        // Outer glow — reacts to audio when recording, breathes when idle
        Circle()
          .fill(buttonTint.opacity(isRecording ? 0.25 + level * 0.5 : 0.15))
          .frame(width: 220, height: 220)
          .blur(radius: 20)
          .scaleEffect(isRecording ? 1.0 + level * 0.3 : (idlePulse ? 1.05 : 0.95))
          .animation(.easeInOut(duration: 0.2), value: level)
          .animation(
            .easeInOut(duration: 1.8).repeatForever(autoreverses: true),
            value: idlePulse
          )

        // Main circle
        Circle()
          .fill(
            LinearGradient(
              colors: [buttonTint, buttonTint.opacity(0.75)],
              startPoint: .topLeading,
              endPoint: .bottomTrailing
            )
          )
          .frame(width: 160, height: 160)
          .shadow(color: buttonTint.opacity(0.4), radius: 20, y: 10)
          .scaleEffect(isRecording ? 1.0 + level * 0.12 : 1.0)
          .animation(.easeInOut(duration: 0.15), value: level)

        if isBusy {
          ProgressView()
            .controlSize(.extraLarge)
            .tint(.white)
        } else {
          Image(systemName: isRecording ? "stop.fill" : "mic.fill")
            .font(.system(size: 56, weight: .medium))
            .foregroundStyle(.white)
            .symbolEffect(.bounce, value: isRecording)
        }
      }
    }
    .buttonStyle(.plain)
    .disabled(isBusy)
    .padding(.top, 20)
  }

  // MARK: - Status

  @ViewBuilder
  private var statusLabel: some View {
    Group {
      switch vm.phase {
      case .idle:
        VStack(spacing: 4) {
          Text("Tap to record")
            .font(.headline)
            .foregroundStyle(.secondary)
          Text(aiMode == .off ? "Raw transcript" : "\(aiMode.displayName) · \(aiProvider.displayName)")
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
      case .requestingPermission:
        Text("Requesting microphone permission…")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      case .recording:
        Text(formatElapsed(vm.elapsedSeconds))
          .font(.system(size: 28, weight: .semibold, design: .rounded))
          .foregroundStyle(.red)
          .monospacedDigit()
      case .transcribing:
        Label("Transcribing…", systemImage: "waveform")
          .font(.subheadline)
          .foregroundStyle(.blue)
      case .aiProcessing:
        Label("Enhancing with \(aiProvider.displayName)…", systemImage: "sparkles")
          .font(.subheadline)
          .foregroundStyle(.purple)
      case .done:
        EmptyView()
      case .error(let msg):
        Label(msg, systemImage: "exclamationmark.triangle")
          .font(.subheadline)
          .foregroundStyle(.red)
          .multilineTextAlignment(.center)
          .padding(.horizontal)
      }
    }
    .frame(minHeight: 44)
  }

  private func formatElapsed(_ seconds: TimeInterval) -> String {
    let m = Int(seconds) / 60
    let s = Int(seconds) % 60
    let cs = Int((seconds - floor(seconds)) * 10)
    return String(format: "%02d:%02d.%d", m, s, cs)
  }

  // MARK: - Result

  @ViewBuilder
  private var resultArea: some View {
    if vm.hasResult {
      VStack(alignment: .leading, spacing: 14) {
        if aiMode != .off && !vm.processedTranscript.isEmpty {
          resultCard(
            title: "\(aiMode.displayName) mode",
            icon: "sparkles",
            tint: .purple,
            text: vm.processedTranscript
          )

          DisclosureGroup {
            Text(vm.rawTranscript)
              .textSelection(.enabled)
              .font(.footnote)
              .foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.top, 8)
          } label: {
            Label("Raw transcript", systemImage: "waveform")
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
          .padding(.horizontal, 4)
        } else {
          resultCard(
            title: "Transcript",
            icon: "waveform",
            tint: .blue,
            text: vm.rawTranscript
          )
        }

        HStack(spacing: 12) {
          ShareLink(item: vm.displayedText) {
            Label("Share", systemImage: "square.and.arrow.up")
              .frame(maxWidth: .infinity)
              .padding(.vertical, 4)
          }
          .buttonStyle(.borderedProminent)
          .tint(aiMode == .off ? .blue : .purple)

          Button {
            UIPasteboard.general.string = vm.displayedText
            UINotificationFeedbackGenerator().notificationOccurred(.success)
          } label: {
            Label("Copy", systemImage: "doc.on.doc")
              .frame(maxWidth: .infinity)
              .padding(.vertical, 4)
          }
          .buttonStyle(.bordered)
        }
      }
      .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
  }

  private func resultCard(title: String, icon: String, tint: Color, text: String) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Label(title, systemImage: icon)
          .font(.caption.weight(.semibold))
          .foregroundStyle(tint)
        Spacer()
      }
      Text(text)
        .textSelection(.enabled)
        .font(.body)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(16)
    .background(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .fill(tint.opacity(0.08))
        .overlay(
          RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(tint.opacity(0.15), lineWidth: 1)
        )
    )
  }
}

// MARK: - Mode chip

private struct ModeChip: View {
  let mode: AIProcessingMode
  let isSelected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 6) {
        Image(systemName: iconName)
          .font(.caption.weight(.semibold))
        Text(mode == .off ? "Raw" : mode.displayName)
          .font(.subheadline.weight(.medium))
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 8)
      .background(
        Capsule()
          .fill(isSelected ? tint : Color.secondary.opacity(0.12))
      )
      .foregroundStyle(isSelected ? Color.white : Color.primary)
      .overlay(
        Capsule()
          .stroke(isSelected ? Color.clear : Color.secondary.opacity(0.2), lineWidth: 1)
      )
    }
    .buttonStyle(.plain)
  }

  private var iconName: String {
    switch mode {
    case .off: "waveform"
    case .clean: "sparkles"
    case .email: "envelope"
    case .notes: "list.bullet"
    case .message: "bubble.left"
    case .code: "chevron.left.forwardslash.chevron.right"
    }
  }

  private var tint: Color {
    switch mode {
    case .off: .blue
    default: .purple
    }
  }
}

#Preview {
  ContentView()
}
