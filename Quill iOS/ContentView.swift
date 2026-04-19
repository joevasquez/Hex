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
  @Published var livePartial: String = ""
  @Published var meterLevel: Float = 0
  @Published var elapsedSeconds: TimeInterval = 0

  private var recorder = IOSRecordingClient.shared
  private var whisperKit: WhisperKit?
  private var timerTask: Task<Void, Never>?
  private var recordingStartedAt: Date?
  private var cancellables: Set<AnyCancellable> = []

  init() {
    // Mirror the recorder's published live partial onto our own @Published so
    // SwiftUI views observing the VM get live updates during recording.
    recorder.$livePartialTranscript
      .receive(on: RunLoop.main)
      .sink { [weak self] text in
        self?.livePartial = text
      }
      .store(in: &cancellables)
  }

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

    // Speech recognition permission is best-effort; failure just disables the
    // live preview (Whisper-based final transcript still works).
    _ = await recorder.requestSpeechPermission()

    rawTranscript = ""
    processedTranscript = ""
    livePartial = ""

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
      let rawText = results.map(\.text).joined(separator: " ")
      let text = WhisperOutputCleaner.clean(rawText)
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
  @StateObject private var notes = NotesStore.shared
  @State private var showingSettings = false
  @State private var showingNotesList = false
  @State private var idlePulse = false
  @State private var lastAppendedTranscript: String = ""
  @State private var showCopied = false
  @State private var copyResetTask: Task<Void, Never>?

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

        VStack(spacing: 0) {
          headerBar
          activeNoteStrip

          ScrollView {
            VStack(spacing: 28) {
              modeChipRow
              recordButton
              statusLabel
              resultArea
              Spacer(minLength: 40)
            }
            .padding(.horizontal)
            .padding(.top, 16)
          }
        }
      }
      .toolbar(.hidden, for: .navigationBar)
      .sheet(isPresented: $showingSettings) {
        SettingsView()
      }
      .sheet(isPresented: $showingNotesList) {
        NotesListView(store: notes)
      }
      .onAppear { idlePulse = true }
      .onChange(of: vm.phase) { _, newPhase in
        if case .done = newPhase {
          appendTranscriptToActiveNote()
        }
      }
    }
  }

  // MARK: - Custom header

  private var headerBar: some View {
    HStack(spacing: 12) {
      logoMark

      Text("Quill")
        .font(.system(size: 34, weight: .bold, design: .serif))
        .foregroundStyle(.white)
        .kerning(0.5)
        .shadow(color: .black.opacity(0.2), radius: 2, y: 1)

      Spacer()

      Button {
        UISelectionFeedbackGenerator().selectionChanged()
        showingSettings = true
      } label: {
        Image(systemName: "gearshape")
          .font(.title3.weight(.semibold))
          .foregroundStyle(.white)
          .frame(width: 36, height: 36)
          .background(
            Circle().fill(Color.white.opacity(0.18))
          )
          .overlay(
            Circle().stroke(Color.white.opacity(0.25), lineWidth: 0.5)
          )
      }
      .buttonStyle(.plain)
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 12)
    .background(
      LinearGradient(
        colors: [
          Color(red: 0.25, green: 0.10, blue: 0.45),  // deep purple
          Color(red: 0.40, green: 0.20, blue: 0.65),  // brighter mid
          Color(red: 0.30, green: 0.18, blue: 0.55),  // settled bottom
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      .ignoresSafeArea(edges: .top)
    )
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(Color.black.opacity(0.25))
        .frame(height: 0.5)
    }
    .shadow(color: .purple.opacity(0.2), radius: 8, y: 4)
  }

  private var logoMark: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(Color.white.opacity(0.95))
        .frame(width: 38, height: 38)
        .shadow(color: .black.opacity(0.2), radius: 4, y: 2)

      Image(systemName: "pencil.tip")
        .font(.system(size: 20, weight: .semibold))
        .foregroundStyle(
          LinearGradient(
            colors: [Color(red: 0.35, green: 0.15, blue: 0.55), Color(red: 0.25, green: 0.20, blue: 0.60)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          )
        )
        .rotationEffect(.degrees(-12))
    }
  }

  // MARK: - Active-note strip

  /// Compact row under the header bar showing which note new recordings
  /// will append to, with controls to start a fresh note or browse all
  /// notes. Sits on the light gradient background (not the dark header).
  private var activeNoteStrip: some View {
    HStack(spacing: 10) {
      Image(systemName: "note.text")
        .font(.subheadline)
        .foregroundStyle(.purple)

      VStack(alignment: .leading, spacing: 1) {
        Text(notes.activeNote?.displayTitle ?? "No active note")
          .font(.subheadline.weight(.semibold))
          .lineLimit(1)
          .foregroundStyle(.primary)
        Text(activeNoteSubtitle)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      Spacer()

      Button {
        UISelectionFeedbackGenerator().selectionChanged()
        Task {
          // Capture location when the user explicitly starts a new note.
          let loc = await LocationClient.shared.currentPlace()
          _ = notes.startNewNote(location: loc)
        }
      } label: {
        Label("New", systemImage: "square.and.pencil")
          .labelStyle(.iconOnly)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.purple)
          .frame(width: 32, height: 32)
          .background(Circle().fill(Color.purple.opacity(0.12)))
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Start new note")

      Button {
        UISelectionFeedbackGenerator().selectionChanged()
        showingNotesList = true
      } label: {
        Image(systemName: "list.bullet")
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.purple)
          .frame(width: 32, height: 32)
          .background(Circle().fill(Color.purple.opacity(0.12)))
      }
      .buttonStyle(.plain)
      .accessibilityLabel("All notes")
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .background(
      Rectangle()
        .fill(.ultraThinMaterial)
    )
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(Color.primary.opacity(0.06))
        .frame(height: 0.5)
    }
  }

  private var activeNoteSubtitle: String {
    if let note = notes.activeNote {
      var parts: [String] = []
      if let place = note.location?.placeName {
        parts.append(place)
      }
      parts.append("Updated \(note.updatedAt.quillRelativeFormatted().lowercased())")
      parts.append("\(note.wordCount) words")
      return parts.joined(separator: " · ")
    }
    return "Tap record to start your first note"
  }

  // MARK: - Append-on-done

  /// Called whenever the recording VM transitions to .done. Appends the
  /// final transcript (AI-enhanced if a mode was selected, raw otherwise)
  /// to the active note, creating a new one with a location tag if none
  /// exists yet. Guards against double-append by tracking the last
  /// transcript we consumed.
  private func appendTranscriptToActiveNote() {
    let text = vm.displayedText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, text != lastAppendedTranscript else { return }
    lastAppendedTranscript = text

    // If we need to create a new note, fetch location first (best-effort).
    if notes.activeNote == nil {
      Task {
        let loc = await LocationClient.shared.currentPlace()
        notes.appendToActiveNote(text, locationIfCreating: loc)
      }
    } else {
      notes.appendToActiveNote(text, locationIfCreating: nil)
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
        VStack(spacing: 12) {
          Text(formatElapsed(vm.elapsedSeconds))
            .font(.system(size: 28, weight: .semibold, design: .rounded))
            .foregroundStyle(.red)
            .monospacedDigit()

          livePartialView
        }
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

  @ViewBuilder
  private var livePartialView: some View {
    if vm.livePartial.isEmpty {
      Text("Listening…")
        .font(.subheadline)
        .foregroundStyle(.tertiary)
        .italic()
    } else {
      Text(vm.livePartial)
        .font(.body)
        .foregroundStyle(.secondary)
        .italic()
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, 8)
        .animation(.easeOut(duration: 0.15), value: vm.livePartial)
        .transition(.opacity)
    }
  }

  private func formatElapsed(_ seconds: TimeInterval) -> String {
    let m = Int(seconds) / 60
    let s = Int(seconds) % 60
    let cs = Int((seconds - floor(seconds)) * 10)
    return String(format: "%02d:%02d.%d", m, s, cs)
  }

  // MARK: - Result

  /// The main content canvas below the record button. Shows the full
  /// active note's body (not just the latest recording's transcript) so
  /// successive recordings visibly stitch into a single continuous note —
  /// e.g. recording a few sections of a conference talk with a pause
  /// between them, you see the full composite transcript grow downward.
  /// Auto-scrolls to the bottom on every body change so the newest
  /// content is always in view.
  @ViewBuilder
  private var resultArea: some View {
    if let note = notes.activeNote, !note.body.isEmpty {
      VStack(alignment: .leading, spacing: 14) {
        noteCanvas(for: note)
        actionButtons(for: note.body)
      }
      .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
  }

  private func noteCanvas(for note: Note) -> some View {
    let tint: Color = aiMode == .off ? .blue : .purple
    return VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Label(
          aiMode == .off ? "Transcript" : "\(aiMode.displayName) mode",
          systemImage: aiMode == .off ? "waveform" : "sparkles"
        )
        .font(.caption.weight(.semibold))
        .foregroundStyle(tint)

        Spacer()

        Text("\(note.wordCount) words")
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }

      ScrollViewReader { proxy in
        ScrollView {
          Text(note.body)
            .textSelection(.enabled)
            .font(.body)
            .frame(maxWidth: .infinity, alignment: .leading)
            .id("noteBottom")
        }
        .frame(maxHeight: 320)
        // Animate the proxy scroll so the newest content slides into view
        // rather than jumping abruptly when an append lands.
        .onChange(of: note.body) { _, _ in
          withAnimation(.easeOut(duration: 0.4)) {
            proxy.scrollTo("noteBottom", anchor: .bottom)
          }
        }
        .onAppear {
          proxy.scrollTo("noteBottom", anchor: .bottom)
        }
      }
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

  private func actionButtons(for text: String) -> some View {
    let shareTint: Color = aiMode == .off ? .blue : .purple

    return HStack(spacing: 12) {
      ShareLink(item: text) {
        Label("Share", systemImage: "square.and.arrow.up")
          .frame(maxWidth: .infinity)
          .padding(.vertical, 4)
      }
      .buttonStyle(.borderedProminent)
      .tint(shareTint)

      Button {
        copyToClipboard(text)
      } label: {
        HStack(spacing: 6) {
          Image(systemName: showCopied ? "checkmark.circle.fill" : "doc.on.doc")
            .contentTransition(.symbolEffect(.replace))
          Text(showCopied ? "Copied" : "Copy")
            .contentTransition(.interpolate)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .foregroundStyle(showCopied ? Color.green : Color.primary)
      }
      .buttonStyle(.bordered)
      .tint(showCopied ? .green : .accentColor)
      .animation(.easeInOut(duration: 0.2), value: showCopied)
    }
  }

  private func copyToClipboard(_ text: String) {
    UIPasteboard.general.string = text
    UINotificationFeedbackGenerator().notificationOccurred(.success)

    // Flip to the "Copied" state, then auto-revert after ~1.5s.
    copyResetTask?.cancel()
    showCopied = true
    copyResetTask = Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(1500))
      guard !Task.isCancelled else { return }
      showCopied = false
    }
  }

  // Legacy signature kept for backwards-compat in case a preview still
  // references it — unused in the live layout now.
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
