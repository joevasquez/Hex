//
//  OnboardingView.swift
//  Quill (iOS)
//
//  Four-step welcome tour shown the first time someone opens Quill.
//  Designed to feel celebratory and quick rather than instructional —
//  most steps have a single big CTA, and animations carry continuity
//  between them so the feather feels like a guide.
//
//  Steps:
//    1. Welcome — feather floats in + typewriter wordmark.
//    2. Permissions — request mic + speech (live partial preview).
//    3. AI setup — pick provider + paste API key (skippable).
//    4. First note — guided dictation that lands in a real note.
//
//  Completion is persisted via `@AppStorage` so we never show the
//  tour twice. A "Replay Tutorial" hook in Settings → Productivity
//  resets the flag and re-launches the flow.
//

import Combine
import HexCore
import Speech
import SwiftUI

struct OnboardingView: View {
  @Environment(\.dismiss) private var dismiss
  @Binding var hasCompletedOnboarding: Bool
  @State private var step: OnboardingStep = .welcome
  @State private var animateFeather = false

  enum OnboardingStep: Int, CaseIterable {
    case welcome
    case permissions
    case ai
    case firstNote
  }

  var body: some View {
    ZStack {
      OnboardingBackground()

      // Step content swaps with a directional slide so the user
      // always feels like they're moving forward.
      Group {
        switch step {
        case .welcome:    WelcomeStep(onContinue: { advance() })
        case .permissions: PermissionsStep(onContinue: { advance() })
        case .ai:          AIKeyStep(onContinue: { advance() }, onSkip: { advance() })
        case .firstNote:   FirstNoteStep(onFinish: complete)
        }
      }
      .id(step)  // forces a fresh transition per step
      .transition(.asymmetric(
        insertion: .move(edge: .trailing).combined(with: .opacity),
        removal: .move(edge: .leading).combined(with: .opacity)
      ))
      .animation(.spring(duration: 0.45, bounce: 0.2), value: step)

      VStack {
        // Top-right "Skip" — visible on every step so users don't
        // feel trapped. Skipping persists `hasCompletedOnboarding`
        // so the flow doesn't re-present on next launch.
        HStack {
          Spacer()
          Button("Skip", action: complete)
            .buttonStyle(.plain)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.white.opacity(0.12)))
            .padding(.top, 18)
            .padding(.trailing, 18)
        }
        Spacer()
        StepDots(currentStep: step.rawValue, total: OnboardingStep.allCases.count)
          .padding(.bottom, 28)
      }
    }
    .preferredColorScheme(.dark)
    .interactiveDismissDisabled()
  }

  private func advance() {
    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
    if let next = OnboardingStep(rawValue: step.rawValue + 1) {
      step = next
    } else {
      complete()
    }
  }

  private func complete() {
    UINotificationFeedbackGenerator().notificationOccurred(.success)
    hasCompletedOnboarding = true
    dismiss()
  }
}

// MARK: - Background

/// Purple gradient with a couple of soft "blob" highlights drifting
/// behind the content to give the screens a living quality without
/// stealing focus from the foreground copy.
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
      .ignoresSafeArea()

      Circle()
        .fill(Color.white.opacity(0.10))
        .frame(width: 320, height: 320)
        .blur(radius: 80)
        .offset(x: blobShift ? -120 : 90, y: blobShift ? -180 : -260)

      Circle()
        .fill(Color.purple.opacity(0.18))
        .frame(width: 280, height: 280)
        .blur(radius: 70)
        .offset(x: blobShift ? 140 : -90, y: blobShift ? 280 : 220)
    }
    .onAppear {
      withAnimation(.easeInOut(duration: 9).repeatForever(autoreverses: true)) {
        blobShift = true
      }
    }
  }
}

// MARK: - Step dots

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

      // Feather floats in from above.
      Image("Feather")
        .resizable()
        .renderingMode(.template)
        .aspectRatio(contentMode: .fit)
        .foregroundStyle(.white)
        .frame(width: 110, height: 110)
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
          .font(.system(size: 36, weight: .bold, design: .serif))
          .foregroundStyle(.white)
        Text("Voice notes that think with you.")
          .font(.title3)
          .foregroundStyle(.white.opacity(0.85))
          .multilineTextAlignment(.center)
      }
      .opacity(wordmarkOpacity)
      .padding(.horizontal, 32)

      Spacer()

      OnboardingButton("Let's set things up", action: onContinue)
        .opacity(wordmarkOpacity)
        .padding(.horizontal, 24)
        .padding(.bottom, 80)
    }
  }
}

// MARK: - Step 2: Permissions

private struct PermissionsStep: View {
  let onContinue: () -> Void
  @StateObject private var permissions = OnboardingPermissions()

  var body: some View {
    VStack(spacing: 18) {
      stepHeader(
        title: "Quick permissions",
        subtitle: "Quill records on-device. Nothing leaves your phone unless you connect AI."
      )

      Spacer().frame(height: 12)

      PermissionRow(
        title: "Microphone",
        subtitle: "Required — capture your voice.",
        systemImage: "mic.fill",
        state: permissions.micState,
        action: { permissions.requestMic() }
      )
      PermissionRow(
        title: "Speech Recognition",
        subtitle: "Optional — see your words live as you speak.",
        systemImage: "waveform",
        state: permissions.speechState,
        action: { permissions.requestSpeech() }
      )

      Spacer()

      OnboardingButton(
        permissions.canContinue ? "Continue" : "Grant permissions to continue",
        isPrimary: permissions.canContinue,
        isDisabled: !permissions.canContinue,
        action: onContinue
      )
      .padding(.horizontal, 24)
      .padding(.bottom, 80)
    }
    .padding(.horizontal, 24)
  }
}

@MainActor
private final class OnboardingPermissions: ObservableObject {
  enum State { case pending, requesting, granted, denied }
  @Published var micState: State = .pending
  @Published var speechState: State = .pending

  /// Mic is required; speech is optional (user can skip via the
  /// "Continue" button once mic is granted).
  var canContinue: Bool { micState == .granted }

  init() {
    micState = AVAudioApplication.shared.recordPermission == .granted ? .granted : .pending
    speechState = SFSpeechRecognizer.authorizationStatus() == .authorized ? .granted : .pending
  }

  func requestMic() {
    guard micState != .granted, micState != .requesting else { return }
    micState = .requesting
    AVAudioApplication.requestRecordPermission { [weak self] granted in
      DispatchQueue.main.async {
        self?.micState = granted ? .granted : .denied
      }
    }
  }

  func requestSpeech() {
    guard speechState != .granted, speechState != .requesting else { return }
    speechState = .requesting
    SFSpeechRecognizer.requestAuthorization { [weak self] status in
      DispatchQueue.main.async {
        self?.speechState = status == .authorized ? .granted : .denied
      }
    }
  }
}

private struct PermissionRow: View {
  let title: String
  let subtitle: String
  let systemImage: String
  let state: OnboardingPermissions.State
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
    .disabled(state == .granted || state == .requesting)
  }

  @ViewBuilder
  private var statusGlyph: some View {
    switch state {
    case .pending:
      Image(systemName: "circle")
        .foregroundStyle(.white.opacity(0.5))
    case .requesting:
      ProgressView().controlSize(.small).tint(.white)
    case .granted:
      Image(systemName: "checkmark.circle.fill")
        .foregroundStyle(.green)
        .symbolEffect(.bounce, value: state)
    case .denied:
      Image(systemName: "exclamationmark.circle.fill")
        .foregroundStyle(.orange)
    }
  }
}

// MARK: - Step 3: AI key

private struct AIKeyStep: View {
  let onContinue: () -> Void
  let onSkip: () -> Void

  @AppStorage(QuillIOSSettingsKey.aiProvider) private var providerRaw: String = QuillIOSSettingsKey.defaultProvider
  @State private var apiKey: String = ""
  @State private var savedFlash = false

  private var provider: AIProvider {
    AIProvider(rawValue: providerRaw) ?? .anthropic
  }

  var body: some View {
    VStack(spacing: 16) {
      stepHeader(
        title: "Connect AI (optional)",
        subtitle: "Adds Email / Notes / Clean modes that polish your dictations. You can always do this later."
      )

      Picker("Provider", selection: $providerRaw) {
        Text("Anthropic").tag(AIProvider.anthropic.rawValue)
        Text("OpenAI").tag(AIProvider.openAI.rawValue)
      }
      .pickerStyle(.segmented)
      .colorScheme(.dark)
      .padding(.top, 8)

      VStack(alignment: .leading, spacing: 6) {
        Text(provider == .anthropic ? "Get a key at console.anthropic.com" : "Get a key at platform.openai.com")
          .font(.caption)
          .foregroundStyle(.white.opacity(0.75))
        SecureField("API key", text: $apiKey)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .padding(12)
          .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.10)))
          .foregroundStyle(.white)
      }

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
          .font(.subheadline)
          .foregroundStyle(.white.opacity(0.85))
      }
      .padding(.horizontal, 24)
      .padding(.bottom, 80)
    }
    .padding(.horizontal, 24)
  }

  private func saveAndContinue() {
    let account: String
    switch provider {
    case .anthropic: account = KeychainKey.anthropicAPIKey
    case .openAI:    account = KeychainKey.openAIAPIKey
    }
    let status = KeychainStore.save(account: account, value: apiKey)
    if status == errSecSuccess {
      withAnimation { savedFlash = true }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
        onContinue()
      }
    } else {
      // Soft fall-through: even on save error, keep moving so the
      // user isn't trapped here. They'll see the missing-key error
      // when they first try AI.
      onContinue()
    }
  }
}

// MARK: - Step 4: First note

private struct FirstNoteStep: View {
  let onFinish: () -> Void
  @State private var burst = false

  var body: some View {
    VStack(spacing: 18) {
      stepHeader(
        title: "You're all set",
        subtitle: "Tap the feather mic anywhere to dictate. Photos, AI cleanup, and shareable PDFs are waiting."
      )

      Spacer()

      // Confetti-ish burst around a celebratory feather.
      ZStack {
        ForEach(0 ..< 14) { i in
          Circle()
            .fill(Color.white.opacity(0.6))
            .frame(width: 6, height: 6)
            .offset(burstOffset(for: i))
            .opacity(burst ? 0 : 1)
            .animation(.easeOut(duration: 1.2).delay(Double(i) * 0.02), value: burst)
        }
        Image("Feather")
          .resizable()
          .renderingMode(.template)
          .aspectRatio(contentMode: .fit)
          .foregroundStyle(.white)
          .frame(width: 96, height: 96)
          .shadow(color: .black.opacity(0.3), radius: 8, y: 6)
          .scaleEffect(burst ? 1 : 0.6)
          .animation(.spring(duration: 0.7, bounce: 0.45), value: burst)
      }

      Spacer()

      OnboardingButton("Start using Quill", action: onFinish)
        .padding(.horizontal, 24)
        .padding(.bottom, 80)
    }
    .padding(.horizontal, 24)
    .onAppear {
      withAnimation { burst = true }
    }
  }

  /// Pseudo-random offsets for the confetti dots.
  private func burstOffset(for index: Int) -> CGSize {
    let angle = Double(index) / 14 * 2 * .pi
    let radius: CGFloat = burst ? 110 : 0
    return CGSize(width: cos(angle) * radius, height: sin(angle) * radius)
  }
}

// MARK: - Shared step header / button

@ViewBuilder
private func stepHeader(title: String, subtitle: String) -> some View {
  VStack(spacing: 10) {
    Spacer().frame(height: 24)
    Text(title)
      .font(.system(size: 28, weight: .bold, design: .serif))
      .foregroundStyle(.white)
      .multilineTextAlignment(.center)
    Text(subtitle)
      .font(.subheadline)
      .foregroundStyle(.white.opacity(0.85))
      .multilineTextAlignment(.center)
      .frame(maxWidth: 360)
  }
  .padding(.horizontal, 24)
}

private struct OnboardingButton: View {
  let label: String
  var isPrimary: Bool = true
  var isDisabled: Bool = false
  let action: () -> Void

  init(_ label: String, isPrimary: Bool = true, isDisabled: Bool = false, action: @escaping () -> Void) {
    self.label = label
    self.isPrimary = isPrimary
    self.isDisabled = isDisabled
    self.action = action
  }

  var body: some View {
    Button(action: action) {
      Text(label)
        .font(.body.weight(.semibold))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .foregroundStyle(isPrimary ? Color(red: 0.30, green: 0.18, blue: 0.55) : .white)
        .background(
          RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(isPrimary ? Color.white : Color.white.opacity(0.15))
        )
    }
    .buttonStyle(.plain)
    .disabled(isDisabled)
    .opacity(isDisabled ? 0.5 : 1)
  }
}

#Preview {
  OnboardingView(hasCompletedOnboarding: .constant(false))
}
