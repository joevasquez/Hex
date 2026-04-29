//
//  TranscriptionIndicatorView.swift
//  Hex
//
//  Always-visible floating HUD pill. Shows the current mode
//  (Dictate / Edit / Action), a live waveform during recording,
//  and an elapsed timer. Click to cycle modes; drag to reposition.
//

import Inject
import Pow
import SwiftUI

// MARK: - Data Types

struct TranscriptionIndicatorView: View {
  @ObserveInjection var inject

  // MARK: Status — what the pipeline is doing right now

  enum Status: Equatable {
    case idle
    case recording
    case transcribing
    case aiProcessing
  }

  // MARK: Mode — user-selected dictation kind

  enum Mode: String, CaseIterable, Equatable {
    case dictate = "Dictate"
    case edit = "Edit"
    case action = "Action"

    var icon: String {
      switch self {
      case .dictate: return "waveform"
      case .edit:    return "pencil"
      case .action:  return "bolt.fill"
      }
    }

    var accentColor: Color {
      switch self {
      case .dictate: return .blue
      case .edit:    return .orange
      case .action:  return .purple
      }
    }

    var next: Mode {
      let all = Mode.allCases
      let idx = all.firstIndex(of: self)!
      return all[(idx + 1) % all.count]
    }
  }

  // MARK: Inputs

  var status: Status
  var mode: Mode
  var meter: Meter
  var recordingStartTime: Date?
  /// Pre-formatted hotkey hint, e.g. "Hold ⌥ Space to dictate".
  var hotkeyHint: String
  /// Shown when the user tries to record in Edit mode without a
  /// selection — e.g. "Highlight text first".
  var editMessage: String?
  /// Non-nil after an inline edit lands — drives the ✓/✗ pill.
  var pendingEditResult: TranscriptionFeature.PendingEditResult?
  var onCycleMode: () -> Void
  var onEditUndo: () -> Void

  // MARK: Body

  var body: some View {
    VStack(spacing: 6) {
      pill
        .compositingGroup()
        .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
        .shadow(color: shadowGlow.opacity(0.3), radius: 12)

      // "Highlight text first" banner
      if let msg = editMessage {
        Text(msg)
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(.white.opacity(0.9))
          .padding(.horizontal, 10)
          .padding(.vertical, 5)
          .background(
            Capsule().fill(.red.opacity(0.7))
          )
          .transition(.move(edge: .top).combined(with: .opacity))
      }

      // Accept / Undo pill after inline edit
      if pendingEditResult != nil {
        editAcceptancePill
          .transition(.move(edge: .top).combined(with: .opacity))
      }
    }
    // Drag is handled natively by HUDPanel (isMovableByWindowBackground).
    // Only tap is handled here for mode cycling.
    .onTapGesture { onCycleMode() }
    .animation(.snappy(duration: 0.3), value: status)
    .animation(.snappy(duration: 0.25), value: mode)
    .animation(.snappy(duration: 0.25), value: editMessage != nil)
    .animation(.snappy(duration: 0.25), value: pendingEditResult != nil)
    .enableInjection()
  }

  // MARK: - Pill Content

  @ViewBuilder
  private var pill: some View {
    HStack(spacing: 12) {
      if status == .idle, pendingEditResult != nil {
        // Show "Edit applied" while the accept/undo pill is up
        HStack(spacing: 6) {
          Image(systemName: "pencil")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.green)
          Text("Edit applied")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white.opacity(0.9))
        }
      } else {
        modeChip
        statusContent
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(pillBackground)
  }

  @ViewBuilder
  private var statusContent: some View {
    switch status {
    case .idle:        idleHint
    case .recording:   recordingContent
    case .transcribing: processingLabel("Transcribing...")
    case .aiProcessing: processingLabel("Enhancing...")
    }
  }

  // MARK: Undo chip

  private var editAcceptancePill: some View {
    Button {
      onEditUndo()
    } label: {
      HStack(spacing: 4) {
        Image(systemName: "arrow.uturn.backward")
          .font(.system(size: 10, weight: .bold))
        Text("Undo")
          .font(.system(size: 11, weight: .semibold))
      }
      .foregroundStyle(.white)
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      .background(Capsule().fill(.red.opacity(0.6)))
    }
    .buttonStyle(.plain)
  }

  // MARK: Mode chip — always visible on the left

  private var modeChip: some View {
    HStack(spacing: 5) {
      Image(systemName: mode.icon)
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(mode.accentColor)
        .contentTransition(.symbolEffect(.replace))

      Text(mode.rawValue)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.white.opacity(0.9))
        .contentTransition(.numericText())
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 5)
    .background(
      RoundedRectangle(cornerRadius: 7, style: .continuous)
        .fill(.white.opacity(0.08))
    )
  }

  // MARK: Idle — hotkey hint + status dot

  private var idleHint: some View {
    HStack(spacing: 12) {
      Text(hotkeyHint)
        .font(.system(size: 13, weight: .regular))
        .foregroundStyle(.white.opacity(0.45))

      Circle()
        .fill(.white.opacity(0.35))
        .frame(width: 8, height: 8)
    }
  }

  // MARK: Recording — red dot + waveform + timer

  private var recordingContent: some View {
    HStack(spacing: 10) {
      // Pulsing red dot
      Circle()
        .fill(.red)
        .frame(width: 8, height: 8)
        .shadow(color: .red.opacity(0.6), radius: 4)
        .modifier(PulseModifier())

      WaveformView(power: meter.averagePower)

      if let startTime = recordingStartTime {
        RecordingTimerView(startTime: startTime)
      }
    }
  }

  // MARK: Processing — label with shimmer

  @State private var shimmerTick = 0

  private func processingLabel(_ text: String) -> some View {
    HStack(spacing: 6) {
      ProgressView()
        .controlSize(.mini)
        .scaleEffect(0.8)

      Text(text)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.white.opacity(0.8))
    }
    .changeEffect(.shine(angle: .degrees(0), duration: 0.8), value: shimmerTick)
    .task {
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(0.5))
        shimmerTick += 1
      }
    }
  }

  // MARK: - Visual Helpers

  private var pillBackground: some View {
    Capsule()
      .fill(.ultraThinMaterial)
      .overlay(
        Capsule()
          .fill(backgroundTint)
      )
      .overlay(
        Capsule()
          .strokeBorder(.white.opacity(0.2), lineWidth: 1)
      )
  }

  private var backgroundTint: Color {
    switch status {
    case .idle:         return .black.opacity(0.3)
    case .recording:    return .red.opacity(0.15 + meter.averagePower * 0.15)
    case .transcribing: return .blue.opacity(0.12)
    case .aiProcessing: return .purple.opacity(0.12)
    }
  }

  private var shadowGlow: Color {
    switch status {
    case .idle:         return mode.accentColor
    case .recording:    return .red
    case .transcribing: return .blue
    case .aiProcessing: return .purple
    }
  }

}

// MARK: - Waveform View

/// Five bars that react to audio power, tallest in the center.
/// Flattens to a resting state during silence.
private struct WaveformView: View {
  var power: Double

  private let barCount = 5
  private let barWidth: CGFloat = 3
  private let spacing: CGFloat = 2
  private let minHeight: CGFloat = 4
  private let maxHeight: CGFloat = 28

  var body: some View {
    HStack(spacing: spacing) {
      ForEach(0..<barCount, id: \.self) { index in
        RoundedRectangle(cornerRadius: barWidth / 2)
          .fill(.white.opacity(0.9))
          .frame(width: barWidth, height: heightFor(index))
      }
    }
    .animation(.interpolatingSpring(stiffness: 280, damping: 14), value: power)
  }

  private func heightFor(_ index: Int) -> CGFloat {
    // Center bars respond more to audio level.
    let center = Double(barCount - 1) / 2.0
    let dist = abs(Double(index) - center) / center
    let scale = 1.0 - dist * 0.4

    let clamped = min(1.0, power * 2.5)
    let h = minHeight + (maxHeight - minHeight) * clamped * scale
    return max(minHeight, h)
  }
}

// MARK: - Recording Timer

/// Elapsed timer that ticks once per second.
private struct RecordingTimerView: View {
  var startTime: Date

  var body: some View {
    TimelineView(.periodic(from: startTime, by: 1.0)) { context in
      let elapsed = max(0, context.date.timeIntervalSince(startTime))
      let mins = Int(elapsed) / 60
      let secs = Int(elapsed) % 60
      Text(String(format: "%d:%02d", mins, secs))
        .font(.system(size: 12, weight: .medium).monospacedDigit())
        .foregroundStyle(.white.opacity(0.7))
    }
  }
}

// MARK: - Pulse Modifier

/// Loops opacity between 1.0 and 0.3 for a recording-dot pulse.
private struct PulseModifier: ViewModifier {
  @State private var on = true

  func body(content: Content) -> some View {
    content
      .opacity(on ? 1.0 : 0.3)
      .onAppear {
        withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
          on = false
        }
      }
  }
}

// MARK: - Preview

#Preview("HUD States") {
  VStack(spacing: 20) {
    TranscriptionIndicatorView(
      status: .idle, mode: .dictate,
      meter: .init(averagePower: 0, peakPower: 0),
      hotkeyHint: "Hold ⌥ Space to dictate",
      onCycleMode: {}, onEditUndo: {}
    )
    TranscriptionIndicatorView(
      status: .idle, mode: .edit,
      meter: .init(averagePower: 0, peakPower: 0),
      hotkeyHint: "Hold ⌥ Space to edit",
      editMessage: "Highlight text first",
      onCycleMode: {}, onEditUndo: {}
    )
    TranscriptionIndicatorView(
      status: .recording, mode: .dictate,
      meter: .init(averagePower: 0.5, peakPower: 0.7),
      recordingStartTime: Date().addingTimeInterval(-5),
      hotkeyHint: "Hold ⌥ Space to dictate",
      onCycleMode: {}, onEditUndo: {}
    )
    TranscriptionIndicatorView(
      status: .idle, mode: .edit,
      meter: .init(averagePower: 0, peakPower: 0),
      hotkeyHint: "Hold ⌥ Space to edit",
      pendingEditResult: .init(original: "old", edited: "new", sourceAppBundleID: nil),
      onCycleMode: {}, onEditUndo: {}
    )
    TranscriptionIndicatorView(
      status: .aiProcessing, mode: .edit,
      meter: .init(averagePower: 0, peakPower: 0),
      hotkeyHint: "Hold ⌥ Space to edit",
      onCycleMode: {}, onEditUndo: {}
    )
  }
  .padding(40)
  .background(.black)
}
