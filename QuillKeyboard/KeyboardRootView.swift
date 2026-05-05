//
//  KeyboardRootView.swift
//  QuillKeyboard
//
//  SwiftUI keyboard layout for Quill's dictation keyboard. Visual
//  language follows the iOS app: purple gradient surfaces, white
//  glyphs, frosted utility chips. Sized at ~270pt total height — the
//  default iPhone portrait keyboard height — so it doesn't shove the
//  host app's UI around.
//

import SwiftUI

struct KeyboardRootView: View {
  @ObservedObject var viewModel: KeyboardRecordingViewModel

  var body: some View {
    ZStack {
      LinearGradient(
        colors: [
          Color(red: 0.45, green: 0.36, blue: 0.85),
          Color(red: 0.36, green: 0.28, blue: 0.74),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      .opacity(0.96)

      VStack(spacing: 10) {
        topBar
        transcriptArea
        Spacer(minLength: 0)
        controlRow
      }
      .padding(.horizontal, 12)
      .padding(.top, 10)
      .padding(.bottom, 8)
    }
    .frame(height: 270)
  }

  // MARK: - Top bar

  private var topBar: some View {
    HStack(spacing: 8) {
      Image(systemName: "feather")
        .font(.system(size: 14, weight: .bold))
        .foregroundStyle(.white)
      Text("Quill")
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(.white)

      Spacer()

      enhanceToggle
    }
  }

  /// Mirrors the AI mode dropdown on the main iOS screen — a small
  /// frosted capsule with sparkles + label. Tapping it toggles the
  /// enhance behavior; long state ("Open Access required") shows when
  /// the user hasn't granted the keyboard network/keychain access.
  private var enhanceToggle: some View {
    Button {
      // Don't let the user enable Enhance when Open Access is off — it
      // can't do anything useful without network + shared keychain.
      guard viewModel.hasOpenAccess else { return }
      viewModel.enhanceEnabled.toggle()
    } label: {
      HStack(spacing: 6) {
        Image(systemName: viewModel.enhanceEnabled ? "sparkles" : "sparkle")
          .font(.system(size: 11, weight: .semibold))
        Text(enhanceLabel)
          .font(.system(size: 12, weight: .medium))
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .foregroundStyle(.white)
      .background(
        Capsule().fill(
          viewModel.enhanceEnabled
            ? Color.white.opacity(0.28)
            : Color.white.opacity(0.12)
        )
      )
      .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 0.5))
    }
    .buttonStyle(.plain)
    .opacity(viewModel.hasOpenAccess ? 1 : 0.55)
    .accessibilityLabel(enhanceAccessibilityLabel)
  }

  private var enhanceLabel: String {
    if !viewModel.hasOpenAccess { return "Enhance: Off" }
    return viewModel.enhanceEnabled ? "Enhance: On" : "Enhance: Off"
  }

  private var enhanceAccessibilityLabel: String {
    if !viewModel.hasOpenAccess {
      return "Enhance is disabled. Allow Full Access in Settings to use AI cleanup."
    }
    return "Toggle AI enhance. Currently \(viewModel.enhanceEnabled ? "on" : "off")."
  }

  // MARK: - Transcript area

  private var transcriptArea: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(.white.opacity(0.10))
        .overlay(
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(.white.opacity(0.20), lineWidth: 0.5)
        )

      switch viewModel.phase {
      case .idle:
        VStack(spacing: 4) {
          Text(idleHint)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white.opacity(0.85))
          if !viewModel.hasOpenAccess {
            Text("Tip: Allow Full Access in Settings → Keyboard for AI Enhance.")
              .font(.system(size: 11))
              .foregroundStyle(.white.opacity(0.6))
              .multilineTextAlignment(.center)
              .padding(.horizontal, 12)
          }
        }
      case .requestingPermission:
        statusLabel("Requesting microphone…", icon: "mic")
      case .recording:
        VStack(spacing: 6) {
          MeterView(level: viewModel.meterLevel)
            .frame(height: 22)
            .padding(.horizontal, 24)
          Text(viewModel.partialTranscript.isEmpty ? "Listening…" : viewModel.partialTranscript)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .lineLimit(3)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
        }
      case .enhancing:
        statusLabel("Enhancing…", icon: "sparkles")
      case .error(let msg):
        statusLabel(msg, icon: "exclamationmark.triangle")
      }
    }
    .frame(height: 92)
  }

  private var idleHint: String {
    "Tap to dictate. Inserts at the cursor."
  }

  private func statusLabel(_ text: String, icon: String) -> some View {
    HStack(spacing: 6) {
      Image(systemName: icon)
        .font(.system(size: 12, weight: .semibold))
      Text(text)
        .font(.system(size: 13, weight: .medium))
        .lineLimit(2)
        .multilineTextAlignment(.center)
    }
    .foregroundStyle(.white.opacity(0.9))
    .padding(.horizontal, 16)
  }

  // MARK: - Control row

  private var controlRow: some View {
    HStack(spacing: 10) {
      utilityButton(systemImage: "globe", action: viewModel.tapNextKeyboard)
        .accessibilityLabel("Next keyboard")
      utilityButton(systemImage: "delete.left.fill", action: viewModel.tapBackspace)
        .accessibilityLabel("Backspace")

      micButton

      utilityButton(systemImage: "space", action: viewModel.tapSpace)
        .accessibilityLabel("Space")
      utilityButton(systemImage: "return", action: viewModel.tapReturn)
        .accessibilityLabel("Return")
      utilityButton(systemImage: "keyboard.chevron.compact.down", action: viewModel.tapDismissKeyboard)
        .accessibilityLabel("Dismiss keyboard")
    }
    .frame(height: 76)
  }

  private func utilityButton(systemImage: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .font(.system(size: 18, weight: .semibold))
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(.white.opacity(0.14))
        )
        .overlay(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(.white.opacity(0.18), lineWidth: 0.5)
        )
    }
    .buttonStyle(.plain)
    .frame(width: 44)
  }

  /// The mic button is the keyboard's main affordance. Recording state
  /// flips the gradient red so it's clear a tap will stop the recording
  /// and insert the result.
  private var micButton: some View {
    let recording = viewModel.phase == .recording
    let busy = viewModel.phase == .enhancing || viewModel.phase == .requestingPermission
    return Button {
      Task { await viewModel.toggleRecording() }
    } label: {
      ZStack {
        Capsule()
          .fill(
            LinearGradient(
              colors: recording
                ? [Color.red, Color.red.opacity(0.82)]
                : [Color.white.opacity(0.95), Color.white.opacity(0.78)],
              startPoint: .topLeading,
              endPoint: .bottomTrailing
            )
          )
          .frame(maxWidth: .infinity)
          .frame(height: 56)
          .shadow(
            color: (recording ? Color.red : .black).opacity(0.25),
            radius: 6,
            y: 2
          )

        HStack(spacing: 8) {
          if busy {
            ProgressView()
              .tint(recording ? .white : .purple)
          } else {
            Image(systemName: recording ? "stop.fill" : "mic.fill")
              .font(.system(size: 20, weight: .bold))
          }
          Text(recording ? "Stop" : "Dictate")
            .font(.system(size: 16, weight: .semibold))
        }
        .foregroundStyle(recording ? Color.white : Color(red: 0.36, green: 0.28, blue: 0.74))
      }
    }
    .buttonStyle(.plain)
    .disabled(busy)
    .accessibilityLabel(recording ? "Stop dictating and insert" : "Start dictating")
  }
}

// MARK: - Meter

/// Lightweight bar-graph meter driven by `KeyboardRecordingViewModel.meterLevel`.
/// Twelve bars is enough to feel responsive without burning CPU in a
/// memory-constrained extension.
private struct MeterView: View {
  let level: Float
  private let bars = 12

  var body: some View {
    HStack(spacing: 4) {
      ForEach(0..<bars, id: \.self) { i in
        let phase = Float(i) / Float(bars)
        let h = max(0.18, CGFloat(min(1, level + phase * 0.2)))
        Capsule()
          .fill(.white.opacity(0.85))
          .frame(width: 4)
          .frame(maxHeight: .infinity)
          .scaleEffect(y: h, anchor: .center)
          .animation(.easeOut(duration: 0.12), value: level)
      }
    }
  }
}
