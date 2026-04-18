//
//  ContentView.swift
//  Quill (iOS)
//
//  Main screen: record → transcribe → optional AI clean-up → share.
//

import AVFoundation
import HexCore
import SwiftUI
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
    aiEnabled: Bool,
    mode: AIProcessingMode,
    provider: AIProvider
  ) async {
    switch phase {
    case .idle, .done, .error:
      await startRecording(model: model, aiEnabled: aiEnabled, mode: mode, provider: provider)
    case .recording:
      await stopAndProcess(model: model, aiEnabled: aiEnabled, mode: mode, provider: provider)
    default:
      break
    }
  }

  private func startRecording(
    model: String,
    aiEnabled: Bool,
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
    aiEnabled: Bool,
    mode: AIProcessingMode,
    provider: AIProvider
  ) async {
    timerTask?.cancel()
    let url = recorder.stopRecording()
    phase = .transcribing

    guard let url else {
      phase = .error("Recording file was not produced")
      return
    }

    do {
      // Load WhisperKit (lazy; first call downloads the model)
      if whisperKit == nil || whisperKit?.modelFolder?.lastPathComponent != model {
        whisperKit = try await WhisperKit(
          WhisperKitConfig(model: model, download: true)
        )
      }

      let results = try await whisperKit!.transcribe(audioPath: url.path)
      let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
      rawTranscript = text

      // Clean up temp file
      try? FileManager.default.removeItem(at: url)

      if text.isEmpty {
        phase = .error("No speech detected. Try again.")
        return
      }

      // Optional AI processing
      if aiEnabled {
        phase = .aiProcessing
        do {
          processedTranscript = try await AIProcessingClient.liveValue.process(text, mode, provider, nil)
        } catch {
          // AI failure is non-fatal — just show raw
          processedTranscript = ""
        }
      }

      phase = .done
    } catch {
      phase = .error("Transcription failed: \(error.localizedDescription)")
    }
  }
}

struct ContentView: View {
  @AppStorage(QuillIOSSettingsKey.selectedModel) private var selectedModel: String = QuillIOSSettingsKey.defaultModel
  @AppStorage(QuillIOSSettingsKey.aiProcessingEnabled) private var aiEnabled: Bool = false
  @AppStorage(QuillIOSSettingsKey.aiProcessingMode) private var aiModeRaw: String = QuillIOSSettingsKey.defaultMode
  @AppStorage(QuillIOSSettingsKey.aiProvider) private var aiProviderRaw: String = QuillIOSSettingsKey.defaultProvider

  @StateObject private var vm = RecordingViewModel()
  @State private var showingSettings = false

  private var aiMode: AIProcessingMode {
    AIProcessingMode(rawValue: aiModeRaw) ?? .clean
  }

  private var aiProvider: AIProvider {
    AIProvider(rawValue: aiProviderRaw) ?? .anthropic
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(spacing: 24) {
          recordButton
          statusLabel
          resultArea
        }
        .padding()
      }
      .navigationTitle("Quill")
      .toolbar {
        Button {
          showingSettings = true
        } label: {
          Image(systemName: "gearshape")
        }
      }
      .sheet(isPresented: $showingSettings) {
        SettingsView()
      }
    }
  }

  @ViewBuilder
  private var recordButton: some View {
    let isRecording = vm.phase == .recording
    let isBusy: Bool = {
      switch vm.phase {
      case .transcribing, .aiProcessing, .requestingPermission: return true
      default: return false
      }
    }()

    Button {
      Task {
        await vm.toggleRecording(
          model: selectedModel,
          aiEnabled: aiEnabled,
          mode: aiMode,
          provider: aiProvider
        )
      }
    } label: {
      ZStack {
        Circle()
          .fill(isRecording ? Color.red : Color.purple)
          .frame(width: 160, height: 160)
          .scaleEffect(isRecording ? 1.0 + CGFloat(vm.meterLevel) * 0.2 : 1.0)
          .animation(.easeInOut(duration: 0.15), value: vm.meterLevel)

        if isBusy {
          ProgressView()
            .controlSize(.extraLarge)
            .tint(.white)
        } else {
          Image(systemName: isRecording ? "stop.fill" : "mic.fill")
            .font(.system(size: 56, weight: .medium))
            .foregroundStyle(.white)
        }
      }
    }
    .disabled(isBusy)
    .padding(.top, 40)
  }

  @ViewBuilder
  private var statusLabel: some View {
    switch vm.phase {
    case .idle:
      Text("Tap to record")
        .font(.headline)
        .foregroundStyle(.secondary)
    case .requestingPermission:
      Text("Requesting microphone permission...")
        .font(.subheadline)
        .foregroundStyle(.secondary)
    case .recording:
      Text(String(format: "Recording %.1fs", vm.elapsedSeconds))
        .font(.headline)
        .foregroundStyle(.red)
        .monospacedDigit()
    case .transcribing:
      Text("Transcribing...")
        .font(.subheadline)
        .foregroundStyle(.blue)
    case .aiProcessing:
      Text("Enhancing with AI...")
        .font(.subheadline)
        .foregroundStyle(.purple)
    case .done:
      EmptyView()
    case .error(let msg):
      Label(msg, systemImage: "exclamationmark.triangle")
        .font(.subheadline)
        .foregroundStyle(.red)
        .multilineTextAlignment(.center)
    }
  }

  @ViewBuilder
  private var resultArea: some View {
    if vm.hasResult {
      VStack(alignment: .leading, spacing: 16) {
        if aiEnabled && !vm.processedTranscript.isEmpty {
          VStack(alignment: .leading, spacing: 8) {
            HStack {
              Label("\(aiMode.displayName) mode", systemImage: "sparkles")
                .font(.caption)
                .foregroundStyle(.purple)
              Spacer()
            }
            Text(vm.processedTranscript)
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding()
              .background(Color.purple.opacity(0.1))
              .cornerRadius(12)
          }

          DisclosureGroup("Raw transcript") {
            Text(vm.rawTranscript)
              .textSelection(.enabled)
              .foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.top, 8)
          }
          .font(.caption)
        } else {
          Text(vm.rawTranscript)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(12)
        }

        HStack(spacing: 12) {
          ShareLink(item: vm.displayedText) {
            Label("Share", systemImage: "square.and.arrow.up")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(.borderedProminent)
          .tint(.purple)

          Button {
            UIPasteboard.general.string = vm.displayedText
          } label: {
            Label("Copy", systemImage: "doc.on.doc")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(.bordered)
        }
      }
    }
  }
}

#Preview {
  ContentView()
}
