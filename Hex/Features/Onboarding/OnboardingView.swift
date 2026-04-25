//
//  OnboardingView.swift
//  Hex (macOS)
//
//  First-launch walk-through. Same shape as the iOS sibling — paged
//  steps with animated transitions — but with macOS-specific
//  permissions (Mic + Accessibility + Input Monitoring) and an
//  optional hotkey configuration step. Designed to feel celebratory
//  and quick, not instructional.
//
//  Steps:
//    1. Welcome — feather floats in, wordmark fades in.
//    2. Permissions — Microphone, Accessibility, Input Monitoring.
//       Each row deep-links to System Settings; the live status
//       updates as the user grants them.
//    3. AI setup — provider + API key (skippable).
//    4. Done — confetti + "Start using Quill".
//
//  Completion is persisted in `HexSettings.hasCompletedOnboarding`.
//  A "Replay Tutorial" entry in Settings → General resets the flag.
//

import AppKit
import ComposableArchitecture
import Dependencies
import HexCore
import SwiftUI

struct OnboardingView: View {
  @Bindable var store: StoreOf<SettingsFeature>
  let microphonePermission: PermissionStatus
  let accessibilityPermission: PermissionStatus
  let inputMonitoringPermission: PermissionStatus
  let onDismiss: () -> Void

  @State private var step: Step = .welcome

  enum Step: Int, CaseIterable {
    case welcome
    case permissions
    case ai
    case done
  }

  var body: some View {
    ZStack {
      OnboardingBackground()

      Group {
        switch step {
        case .welcome:
          WelcomeStep(onContinue: { advance() })
        case .permissions:
          PermissionsStep(
            store: store,
            microphonePermission: microphonePermission,
            accessibilityPermission: accessibilityPermission,
            inputMonitoringPermission: inputMonitoringPermission,
            onContinue: { advance() }
          )
        case .ai:
          AIKeyStep(
            store: store,
            onContinue: { advance() },
            onSkip: { advance() }
          )
        case .done:
          DoneStep(onFinish: complete)
        }
      }
      .id(step)
      .transition(.asymmetric(
        insertion: .move(edge: .trailing).combined(with: .opacity),
        removal: .move(edge: .leading).combined(with: .opacity)
      ))
      .animation(.spring(duration: 0.45, bounce: 0.2), value: step)

      VStack {
        Spacer()
        StepDots(currentStep: step.rawValue, total: Step.allCases.count)
          .padding(.bottom, 28)
      }
    }
    .frame(minWidth: 640, minHeight: 520)
  }

  private func advance() {
    if let next = Step(rawValue: step.rawValue + 1) {
      step = next
    } else {
      complete()
    }
  }

  private func complete() {
    store.send(.markOnboardingComplete)
    onDismiss()
  }
}

// MARK: - Background + dots

private struct OnboardingBackground: View {
  @State private var blobShift = false

  var body: some View {
    ZStack {
      LinearGradient(
        colors: [
          Color(red: 0.20, green: 0.08, blue: 0.40),
          Color(red: 0.40, green: 0.20, blue: 0.65),
          Color(red: 0.30, green: 0.18, blue: 0.55),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )

      Circle()
        .fill(Color.white.opacity(0.10))
        .frame(width: 360, height: 360)
        .blur(radius: 80)
        .offset(x: blobShift ? -160 : 120, y: blobShift ? -200 : -300)

      Circle()
        .fill(Color.purple.opacity(0.18))
        .frame(width: 320, height: 320)
        .blur(radius: 70)
        .offset(x: blobShift ? 180 : -120, y: blobShift ? 280 : 240)
    }
    .onAppear {
      withAnimation(.easeInOut(duration: 9).repeatForever(autoreverses: true)) {
        blobShift = true
      }
    }
  }
}

private struct StepDots: View {
  let currentStep: Int
  let total: Int

  var body: some View {
    HStack(spacing: 8) {
      ForEach(0 ..< total, id: \.self) { idx in
        Capsule()
          .fill(idx == currentStep ? Color.white : Color.white.opacity(0.25))
          .frame(width: idx == currentStep ? 24 : 8, height: 8)
          .animation(.spring(duration: 0.4, bounce: 0.3), value: currentStep)
      }
    }
  }
}

// MARK: - Step 1: Welcome

private struct WelcomeStep: View {
  let onContinue: () -> Void
  @State private var featherOffset: CGFloat = -120
  @State private var featherOpacity: Double = 0
  @State private var wordmarkOpacity: Double = 0

  var body: some View {
    VStack(spacing: 24) {
      Spacer()

      Image(nsImage: featherImage)
        .resizable()
        .aspectRatio(contentMode: .fit)
        .frame(width: 130, height: 130)
        .shadow(color: .black.opacity(0.3), radius: 8, y: 6)
        .offset(y: featherOffset)
        .opacity(featherOpacity)
        .onAppear {
          withAnimation(.spring(duration: 1.2, bounce: 0.35)) {
            featherOffset = 0
            featherOpacity = 1
          }
          withAnimation(.easeIn(duration: 0.4).delay(0.6)) {
            wordmarkOpacity = 1
          }
        }

      VStack(spacing: 8) {
        Text("Welcome to Quill")
          .font(.system(size: 40, weight: .bold, design: .serif))
          .foregroundStyle(.white)
        Text("Voice-to-text that thinks with you.")
          .font(.title3)
          .foregroundStyle(.white.opacity(0.85))
      }
      .opacity(wordmarkOpacity)

      Spacer()

      OnboardingButton("Let's set things up", action: onContinue)
        .opacity(wordmarkOpacity)
        .padding(.horizontal, 32)
        .padding(.bottom, 80)
    }
  }

  /// Build a template feather NSImage on the fly so it tints white
  /// against the gradient background. Same approach as the menu bar
  /// icon — see `HexApp.menuBarIcon`.
  private var featherImage: NSImage {
    let side: CGFloat = 130
    guard let source = NSImage(named: "Feather") else { return NSImage() }
    let scaled = NSImage(size: NSSize(width: side, height: side))
    let rect = NSRect(x: 0, y: 0, width: side, height: side)
    scaled.lockFocus()
    source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    NSColor.white.setFill()
    rect.fill(using: .sourceIn)
    scaled.unlockFocus()
    return scaled
  }
}

// MARK: - Step 2: Permissions

private struct PermissionsStep: View {
  @Bindable var store: StoreOf<SettingsFeature>
  let microphonePermission: PermissionStatus
  let accessibilityPermission: PermissionStatus
  let inputMonitoringPermission: PermissionStatus
  let onContinue: () -> Void

  private var allGranted: Bool {
    microphonePermission == .granted
      && accessibilityPermission == .granted
      && inputMonitoringPermission == .granted
  }

  var body: some View {
    VStack(spacing: 18) {
      stepHeader(
        title: "Three quick permissions",
        subtitle: "Quill needs these to listen, paste, and respond to your hotkey. Click each row to grant."
      )

      Spacer().frame(height: 12)

      PermissionRow(
        title: "Microphone",
        subtitle: "Required — capture your voice.",
        systemImage: "mic.fill",
        state: microphonePermission,
        action: { store.send(.requestMicrophone) }
      )
      PermissionRow(
        title: "Accessibility",
        subtitle: "Required — paste transcriptions into the focused app.",
        systemImage: "hand.point.up.left",
        state: accessibilityPermission,
        action: { store.send(.requestAccessibility) }
      )
      PermissionRow(
        title: "Input Monitoring",
        subtitle: "Required — listen for your global hotkey.",
        systemImage: "keyboard",
        state: inputMonitoringPermission,
        action: { store.send(.requestInputMonitoring) }
      )

      Spacer()

      OnboardingButton(
        allGranted ? "Continue" : "Grant permissions to continue",
        isDisabled: !allGranted,
        action: onContinue
      )
      .padding(.horizontal, 32)
      .padding(.bottom, 80)
    }
    .padding(.horizontal, 40)
  }
}

private struct PermissionRow: View {
  let title: String
  let subtitle: String
  let systemImage: String
  let state: PermissionStatus
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(alignment: .center, spacing: 14) {
        Image(systemName: systemImage)
          .font(.title3.weight(.semibold))
          .foregroundStyle(.white)
          .frame(width: 36, height: 36)
          .background(Circle().fill(Color.white.opacity(0.18)))

        VStack(alignment: .leading, spacing: 2) {
          Text(title).font(.body.weight(.semibold)).foregroundStyle(.white)
          Text(subtitle).font(.caption).foregroundStyle(.white.opacity(0.75))
        }
        Spacer()
        statusGlyph
      }
      .padding(14)
      .background(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .fill(Color.white.opacity(state == .granted ? 0.20 : 0.08))
      )
    }
    .buttonStyle(.plain)
    .disabled(state == .granted)
  }

  @ViewBuilder
  private var statusGlyph: some View {
    switch state {
    case .granted:
      Image(systemName: "checkmark.circle.fill")
        .foregroundStyle(.green)
        .symbolEffect(.bounce, value: state)
    case .denied:
      Image(systemName: "exclamationmark.circle.fill")
        .foregroundStyle(.orange)
    case .notDetermined:
      Image(systemName: "circle")
        .foregroundStyle(.white.opacity(0.5))
    }
  }
}

// MARK: - Step 3: AI key

private struct AIKeyStep: View {
  @Bindable var store: StoreOf<SettingsFeature>
  let onContinue: () -> Void
  let onSkip: () -> Void

  @State private var apiKey: String = ""
  @State private var savedFlash = false

  var body: some View {
    VStack(spacing: 16) {
      stepHeader(
        title: "Connect AI (optional)",
        subtitle: "Adds Email / Notes / Clean modes that polish your dictations. Bring your own OpenAI or Anthropic key."
      )

      Picker("Provider", selection: Binding(
        get: { store.hexSettings.aiProvider },
        set: { store.send(.setAIProvider($0)) }
      )) {
        Text("Anthropic").tag(AIProvider.anthropic)
        Text("OpenAI").tag(AIProvider.openAI)
      }
      .pickerStyle(.segmented)
      .colorScheme(.dark)
      .padding(.horizontal, 40)
      .padding(.top, 8)

      VStack(alignment: .leading, spacing: 6) {
        Text(
          store.hexSettings.aiProvider == .anthropic
            ? "Get a key at console.anthropic.com"
            : "Get a key at platform.openai.com"
        )
        .font(.caption)
        .foregroundStyle(.white.opacity(0.75))
        SecureField("API key", text: $apiKey)
          .textFieldStyle(.plain)
          .padding(12)
          .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.10)))
          .foregroundStyle(.white)
      }
      .padding(.horizontal, 40)

      if savedFlash {
        Label("Saved to Keychain", systemImage: "checkmark.circle.fill")
          .foregroundStyle(.green)
          .font(.caption)
          .transition(.opacity.combined(with: .move(edge: .bottom)))
      }

      Spacer()

      VStack(spacing: 10) {
        OnboardingButton("Save & continue", isDisabled: apiKey.isEmpty, action: saveAndContinue)
        Button("I'll add it later", action: onSkip)
          .buttonStyle(.plain)
          .font(.subheadline)
          .foregroundStyle(.white.opacity(0.85))
      }
      .padding(.horizontal, 32)
      .padding(.bottom, 80)
    }
  }

  private func saveAndContinue() {
    store.send(.saveAPIKey(apiKey, forProvider: store.hexSettings.aiProvider))
    withAnimation { savedFlash = true }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
      onContinue()
    }
  }
}

// MARK: - Step 4: Done

private struct DoneStep: View {
  let onFinish: () -> Void
  @State private var burst = false

  var body: some View {
    VStack(spacing: 18) {
      stepHeader(
        title: "You're all set",
        subtitle: "Hold your hotkey anywhere on macOS to dictate. Quill paste-routes into Chrome, Slack, VS Code, anywhere."
      )

      Spacer()

      ZStack {
        ForEach(0 ..< 16) { i in
          Circle()
            .fill(Color.white.opacity(0.6))
            .frame(width: 6, height: 6)
            .offset(burstOffset(for: i))
            .opacity(burst ? 0 : 1)
            .animation(.easeOut(duration: 1.4).delay(Double(i) * 0.02), value: burst)
        }
        Image(nsImage: featherImage)
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(width: 110, height: 110)
          .shadow(color: .black.opacity(0.3), radius: 8, y: 6)
          .scaleEffect(burst ? 1 : 0.6)
          .animation(.spring(duration: 0.7, bounce: 0.45), value: burst)
      }

      Spacer()

      OnboardingButton("Start using Quill", action: onFinish)
        .padding(.horizontal, 32)
        .padding(.bottom, 80)
    }
    .padding(.horizontal, 40)
    .onAppear { withAnimation { burst = true } }
  }

  private func burstOffset(for index: Int) -> CGSize {
    let angle = Double(index) / 16 * 2 * .pi
    let radius: Double = burst ? 130 : 0
    return CGSize(width: Foundation.cos(angle) * radius, height: Foundation.sin(angle) * radius)
  }

  private var featherImage: NSImage {
    let side: CGFloat = 110
    guard let source = NSImage(named: "Feather") else { return NSImage() }
    let scaled = NSImage(size: NSSize(width: side, height: side))
    let rect = NSRect(x: 0, y: 0, width: side, height: side)
    scaled.lockFocus()
    source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    NSColor.white.setFill()
    rect.fill(using: .sourceIn)
    scaled.unlockFocus()
    return scaled
  }
}

// MARK: - Shared

@ViewBuilder
private func stepHeader(title: String, subtitle: String) -> some View {
  VStack(spacing: 10) {
    Spacer().frame(height: 28)
    Text(title)
      .font(.system(size: 32, weight: .bold, design: .serif))
      .foregroundStyle(.white)
      .multilineTextAlignment(.center)
    Text(subtitle)
      .font(.subheadline)
      .foregroundStyle(.white.opacity(0.85))
      .multilineTextAlignment(.center)
      .frame(maxWidth: 460)
  }
}

private struct OnboardingButton: View {
  let label: String
  var isDisabled: Bool = false
  let action: () -> Void

  init(_ label: String, isDisabled: Bool = false, action: @escaping () -> Void) {
    self.label = label
    self.isDisabled = isDisabled
    self.action = action
  }

  var body: some View {
    Button(action: action) {
      Text(label)
        .font(.body.weight(.semibold))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .foregroundStyle(Color(red: 0.30, green: 0.18, blue: 0.55))
        .background(
          RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.white)
        )
    }
    .buttonStyle(.plain)
    .disabled(isDisabled)
    .opacity(isDisabled ? 0.5 : 1)
  }
}
