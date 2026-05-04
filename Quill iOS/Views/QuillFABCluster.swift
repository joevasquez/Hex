//
//  QuillFABCluster.swift
//  Quill (iOS)
//
//  Single + button at the bottom of the home screen that fans up into
//  three vertically-stacked FABs (dictate, photo, action) when tapped.
//  The mode dropdown floats up alongside the dictate button on its
//  leading edge.
//
//  Rationale: replaces the prior three-FABs-always-on-screen layout to
//  reduce visual weight at rest. Most of the time the user is reading
//  notes, not staring at three colored circles.
//
//  Recording state: the + button stays as + (per the spec) but gains
//  a red pulsing ring + a corner dot so it's obvious recording is in
//  flight. To stop, the user taps + → expands → taps the now-red
//  dictate (or action) button.
//

import HexCore
import SwiftUI

struct QuillFABCluster: View {
  @ObservedObject var vm: RecordingViewModel
  @Binding var modeSelectionRaw: String
  let customModes: [CustomAIMode]
  let visibleBuiltInModes: [AIProcessingMode]
  let hasAPIKey: Bool
  let onTapCamera: () -> Void
  let onTapAction: () -> Void
  let onTapMic: () -> Void
  let onRequestSettings: () -> Void

  @State private var expanded = false

  /// Visible diameter of each round FAB. Trimmed slightly from the
  /// previous 72pt mic FAB so a vertical stack of three doesn't crowd
  /// the screen on smaller iPhones.
  private let fabSize: CGFloat = 60
  /// Outer slot — gives shadows + glows room without spilling into
  /// neighbours. ~20pt buffer past `fabSize` is the working minimum.
  private let fabSlot: CGFloat = 76
  /// + button diameter — matches `fabSize` for visual symmetry.
  private let plusSize: CGFloat = 60

  // MARK: - Recording-state booleans

  private var isAnyRecording: Bool {
    vm.phase == .recording
  }

  /// Recording started via the dictate FAB.
  private var isDictateRecording: Bool {
    isAnyRecording && !vm.isActionRecording
  }

  /// Recording started via the action FAB.
  private var isActionRecording: Bool {
    isAnyRecording && vm.isActionRecording
  }

  /// Action mode is in its post-recording parse phase. Disables the
  /// action button so the user can't double-fire while the LLM is
  /// resolving the intent.
  private var isActionParsing: Bool {
    vm.phase == .actionParsing
  }

  // MARK: - Body

  var body: some View {
    VStack(alignment: .trailing, spacing: 14) {
      if expanded {
        // Top: mode dropdown to the LEFT of the dictate button.
        // The dropdown is system-Menu-backed so its popup floats above
        // all of this — no clipping concerns from the cluster.
        HStack(spacing: 12) {
          QuillModeDropdown(
            selectionRaw: $modeSelectionRaw,
            customModes: customModes,
            visibleBuiltInModes: visibleBuiltInModes,
            hasAPIKey: hasAPIKey,
            onRequestAPIKeySetup: onRequestSettings
          )
          dictateFAB
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))

        photoFAB
          .transition(.move(edge: .bottom).combined(with: .opacity))

        actionFAB
          .transition(.move(edge: .bottom).combined(with: .opacity))
      }

      plusButton
    }
    .animation(.spring(response: 0.32, dampingFraction: 0.78), value: expanded)
  }

  // MARK: - Trigger button (+ when idle, stop when recording)

  /// Tapped when the user wants to either expand the cluster or stop
  /// the in-flight recording. Branches on `isAnyRecording`:
  /// - idle → toggle the expanded stack
  /// - recording → fire the matching stop (dictate or action) directly,
  ///   no expand step. Single tap to stop.
  private var plusButton: some View {
    Button {
      UISelectionFeedbackGenerator().selectionChanged()
      if isAnyRecording {
        // Route to whichever toggle started the recording so the right
        // VM method handles the stop.
        if vm.isActionRecording {
          onTapAction()
        } else {
          onTapMic()
        }
        // Defensive: collapse the stack if it was somehow open mid-
        // recording (shouldn't happen via normal flow but keeps state
        // tidy after the tap).
        expanded = false
      } else {
        expanded.toggle()
      }
    } label: {
      ZStack {
        // Filled circle — purple when idle, red when recording so the
        // button itself signals "tap to stop". No separate halo or
        // corner dot; the color swap is the indicator.
        Circle()
          .fill(
            LinearGradient(
              colors: isAnyRecording
                ? [Color.red, Color.red.opacity(0.82)]
                : [Color.purple, Color.purple.opacity(0.82)],
              startPoint: .topLeading,
              endPoint: .bottomTrailing
            )
          )
          .frame(width: plusSize, height: plusSize)
          .shadow(
            color: (isAnyRecording ? Color.red : Color.purple).opacity(0.4),
            radius: 8,
            y: 4
          )

        Image(systemName: isAnyRecording ? "stop.fill" : "plus")
          .font(.system(size: 26, weight: .bold))
          .foregroundStyle(.white)
          // Rotation only applies to the +. Stop glyph never rotates;
          // expanding has no meaning while recording.
          .rotationEffect(.degrees(expanded && !isAnyRecording ? 45 : 0))
      }
      .frame(width: fabSlot, height: fabSlot)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(plusAccessibilityLabel)
  }

  private var plusAccessibilityLabel: String {
    if isAnyRecording { return "Stop recording" }
    return expanded ? "Hide actions" : "Show actions"
  }

  // MARK: - Dictate

  private var dictateFAB: some View {
    let recording = isDictateRecording
    let tint: Color = recording ? .red : .purple

    return Button {
      onTapMic()
      // Collapse after tap — the recording state will be apparent
      // from the + button's red ring, no need to keep the stack open.
      expanded = false
    } label: {
      fabBubble(
        glyph: recording ? "stop.fill" : "mic.fill",
        tint: tint,
        glyphSize: 22
      )
    }
    .buttonStyle(.plain)
    .accessibilityLabel(recording ? "Stop dictating" : "Start dictating")
  }

  // MARK: - Photo

  private var photoFAB: some View {
    Button {
      onTapCamera()
      expanded = false
    } label: {
      fabBubble(glyph: "camera.fill", tint: .purple, glyphSize: 22)
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Add photo")
  }

  // MARK: - Action (voice command)

  private var actionFAB: some View {
    let recording = isActionRecording
    let tint: Color = recording ? .red : .orange

    return Button {
      if !isActionParsing {
        onTapAction()
        expanded = false
      }
    } label: {
      ZStack {
        fabBubble(
          glyph: recording ? "stop.fill" : "bolt.fill",
          tint: tint,
          glyphSize: 22
        )
        if isActionParsing {
          // Subtle parsing indicator — replaces the glyph with a
          // spinner without changing the tint, so "we heard you and
          // we're thinking" is visible.
          Circle()
            .fill(tint.opacity(0.5))
            .frame(width: fabSize, height: fabSize)
          ProgressView()
            .tint(.white)
            .controlSize(.regular)
        }
      }
    }
    .buttonStyle(.plain)
    .disabled(isActionParsing)
    .accessibilityLabel(actionLabel)
  }

  private var actionLabel: String {
    if isActionParsing { return "Parsing voice action…" }
    if isActionRecording { return "Stop voice action" }
    return "Start voice action"
  }

  // MARK: - Shared bubble

  /// The visual circle used by every FAB except + (which has its own
  /// recording-indicator extras). Centralized so tint changes only
  /// touch one place.
  private func fabBubble(glyph: String, tint: Color, glyphSize: CGFloat) -> some View {
    ZStack {
      Circle()
        .fill(
          LinearGradient(
            colors: [tint, tint.opacity(0.82)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          )
        )
        .frame(width: fabSize, height: fabSize)
        .shadow(color: tint.opacity(0.35), radius: 8, y: 4)

      Image(systemName: glyph)
        .font(.system(size: glyphSize, weight: .semibold))
        .foregroundStyle(.white)
    }
    .frame(width: fabSlot, height: fabSlot)
  }
}

