//
//  AppFeature.swift
//  Hex
//
//  Created by Kit Langton on 1/26/25.
//

import AppKit
import ComposableArchitecture
import Dependencies
import HexCore
import SwiftUI

@Reducer
struct AppFeature {
  enum ActiveTab: Equatable {
    /// General settings: permissions, sound, general (login, dock,
    /// sleep), and history-retention configuration. The "catchall"
    /// landing tab.
    case general
    /// Recording-specific settings: Whisper/Parakeet model, output
    /// language, hotkey configuration, microphone selection.
    case recording
    /// AI post-processing settings: API keys, modes, voice commands,
    /// inline edit, custom user-authored modes.
    case ai
    /// Integration connections (Todoist, Apple Reminders, Notion,
    /// Things, Slack, Linear). Frontend-only as of 0.9.x — connection
    /// state is persisted but send adapters land in a follow-up.
    case integrations
    /// Word remapping / removal scratchpad (legacy name "transforms").
    case remappings
    /// Transcription history viewer.
    case history
    /// About / version / Sparkle update info.
    case about
  }

	@ObservableState
	struct State {
		var transcription: TranscriptionFeature.State = .init()
		var settings: SettingsFeature.State = .init()
		var history: HistoryFeature.State = .init()
		var activeTab: ActiveTab = .general
		@Shared(.hexSettings) var hexSettings: HexSettings
		@Shared(.modelBootstrapState) var modelBootstrapState: ModelBootstrapState

    // Permission state
    var microphonePermission: PermissionStatus = .notDetermined
    var accessibilityPermission: PermissionStatus = .notDetermined
    var inputMonitoringPermission: PermissionStatus = .notDetermined
  }

  enum Action: BindableAction {
    case binding(BindingAction<State>)
    case transcription(TranscriptionFeature.Action)
    case settings(SettingsFeature.Action)
    case history(HistoryFeature.Action)
    case setActiveTab(ActiveTab)
    case task
    case pasteLastTranscript

    // Permission actions
    case checkPermissions
    case permissionsUpdated(mic: PermissionStatus, acc: PermissionStatus, input: PermissionStatus)
    case appActivated
    case requestMicrophone
    case requestAccessibility
    case requestInputMonitoring
    case modelStatusEvaluated(Bool)
  }

  @Dependency(\.keyEventMonitor) var keyEventMonitor
  @Dependency(\.pasteboard) var pasteboard
  @Dependency(\.transcription) var transcription
  @Dependency(\.permissions) var permissions

  var body: some ReducerOf<Self> {
    BindingReducer()

    Scope(state: \.transcription, action: \.transcription) {
      TranscriptionFeature()
    }

    Scope(state: \.settings, action: \.settings) {
      SettingsFeature()
    }

    Scope(state: \.history, action: \.history) {
      HistoryFeature()
    }

    Reduce { state, action in
      switch action {
      case .binding:
        return .none
        
      case .task:
        return .merge(
          startPasteLastTranscriptMonitoring(),
          ensureSelectedModelReadiness(),
          startPermissionMonitoring()
        )
        
      case .pasteLastTranscript:
        @Shared(.transcriptionHistory) var transcriptionHistory: TranscriptionHistory
        guard let lastTranscript = transcriptionHistory.history.first?.text else {
          return .none
        }
        return .run { _ in
          // No source app to reactivate — this action is triggered by
          // a user hotkey / menu click; the frontmost app at that
          // moment IS the target.
          await pasteboard.paste(lastTranscript, nil)
        }
        
      case .transcription(.modelMissing):
        HexLog.app.notice("Model missing - activating app and switching to Recording settings")
        // The model selector now lives in the Recording tab (split
        // out of the old monolithic Settings page in 0.9.x).
        state.activeTab = .recording
        state.settings.shouldFlashModelSection = true
        return .run { send in
          await MainActor.run {
            HexLog.app.notice("Activating app for model missing")
            NSApplication.shared.activate(ignoringOtherApps: true)
          }
          try? await Task.sleep(for: .seconds(2))
          await send(.settings(.set(\.shouldFlashModelSection, false)))
        }

      case .transcription:
        return .none

      case .settings:
        return .none

      case .history(.navigateToSettings):
        state.activeTab = .general
        return .none
      case .history:
        return .none
		case let .setActiveTab(tab):
			state.activeTab = tab
			return .none

      // Permission handling
      case .checkPermissions:
        return .run { send in
          async let mic = permissions.microphoneStatus()
          async let acc = permissions.accessibilityStatus()
          async let input = permissions.inputMonitoringStatus()
          await send(.permissionsUpdated(mic: mic, acc: acc, input: input))
        }

      case let .permissionsUpdated(mic, acc, input):
        state.microphonePermission = mic
        state.accessibilityPermission = acc
        state.inputMonitoringPermission = input
        return .none

      case .appActivated:
        // App became active - re-check permissions
        return .send(.checkPermissions)

      case .requestMicrophone:
        return .run { send in
          _ = await permissions.requestMicrophone()
          await send(.checkPermissions)
        }

      case .requestAccessibility:
        return .run { send in
          await permissions.requestAccessibility()
          // Poll for status change (macOS doesn't provide callback)
          for _ in 0..<10 {
            try? await Task.sleep(for: .seconds(1))
            await send(.checkPermissions)
          }
        }

      case .requestInputMonitoring:
        return .run { send in
          _ = await permissions.requestInputMonitoring()
          for _ in 0..<10 {
            try? await Task.sleep(for: .seconds(1))
            await send(.checkPermissions)
          }
        }

      case .modelStatusEvaluated:
        return .none
      }
    }
  }
  
  private func startPasteLastTranscriptMonitoring() -> Effect<Action> {
    .run { send in
      // Capture the shared *storage references* (Shared<Value> is Sendable) rather
      // than the @Shared property wrapper's var binding. Capturing the wrapper
      // produces a "reference to captured var in concurrently-executing code"
      // warning (hard error in Swift 6) and, more importantly, is a real data race
      // because the closure runs on the CGEvent tap's main-thread callback on every
      // key press. We project the Shared refs once and read them fresh on each hit.
      @Shared(.isSettingPasteLastTranscriptHotkey) var isSettingPasteLastTranscriptHotkey: Bool
      @Shared(.hexSettings) var hexSettings: HexSettings
      let sharedIsSettingPaste = $isSettingPasteLastTranscriptHotkey
      let sharedHexSettings = $hexSettings

      let token = keyEventMonitor.handleKeyEvent { keyEvent in
        // Skip if user is setting a hotkey
        if sharedIsSettingPaste.wrappedValue {
          return false
        }

        // Check if this matches the paste last transcript hotkey
        guard let pasteHotkey = sharedHexSettings.wrappedValue.pasteLastTranscriptHotkey,
              let key = keyEvent.key,
              key == pasteHotkey.key,
              keyEvent.modifiers.matchesExactly(pasteHotkey.modifiers) else {
          return false
        }

        // Trigger paste action - use MainActor to avoid escaping send
        MainActor.assumeIsolated {
          send(.pasteLastTranscript)
        }
        return true // Intercept the key event
      }

      defer { token.cancel() }

      await withTaskCancellationHandler {
        while !Task.isCancelled {
          try? await Task.sleep(for: .seconds(60))
        }
      } onCancel: {
        token.cancel()
      }
    }
  }

  private func ensureSelectedModelReadiness() -> Effect<Action> {
    .run { send in
      @Shared(.hexSettings) var hexSettings: HexSettings
      @Shared(.modelBootstrapState) var modelBootstrapState: ModelBootstrapState
      let selectedModel = hexSettings.selectedModel
      guard !selectedModel.isEmpty else {
        await send(.modelStatusEvaluated(false))
        return
      }
      let isReady = await transcription.isModelDownloaded(selectedModel)
      $modelBootstrapState.withLock { state in
        state.modelIdentifier = selectedModel
        if state.modelDisplayName?.isEmpty ?? true {
          state.modelDisplayName = selectedModel
        }
        state.isModelReady = isReady
        if isReady {
          state.lastError = nil
          state.progress = 1
        } else {
          state.progress = 0
        }
      }
      await send(.modelStatusEvaluated(isReady))
    }
  }

  private func startPermissionMonitoring() -> Effect<Action> {
    .run { send in
      // Initial check on app launch
      await send(.checkPermissions)

      // Monitor app activation events
      for await activation in permissions.observeAppActivation() {
        if case .didBecomeActive = activation {
          await send(.appActivated)
        }
      }

    }
  }

}

/// Top-level "mode" the sidebar is in. The user toggles between
/// these via a segmented control at the top of the sidebar — when
/// Settings is selected the sidebar lists configuration sub-tabs,
/// when History is selected the sidebar collapses so the transcript
/// list and detail get the full window width.
private enum SidebarMode: String, CaseIterable, Identifiable {
  case settings, history
  var id: String { rawValue }
  var title: String {
    switch self {
    case .settings: "Settings"
    case .history: "History"
    }
  }
  var icon: String {
    switch self {
    case .settings: "gearshape.fill"
    case .history:  "clock.fill"
    }
  }
}

/// Custom two-segment toggle for switching between Settings and
/// History modes. Text-only — earlier revision included SF Symbols
/// next to each label, but at typical sidebar widths the icons
/// crowded the labels enough to force them onto two lines
/// ("Setti / ngs"). Dropping the icons gave each pill enough
/// horizontal room to read cleanly while matching the
/// minimalist look of macOS sidebar tab pickers.
///
/// A `matchedGeometryEffect` "thumb" slides between the two
/// options on selection. The active pill uses a softened purple
/// gradient that harmonizes with the rest of the app's brand tint
/// without screaming.
private struct SidebarModeToggle: View {
  let mode: SidebarMode
  let onSelect: (SidebarMode) -> Void
  /// Geometry IDs for the matched-geometry "thumb" animation.
  @Namespace private var thumbNamespace

  var body: some View {
    HStack(spacing: 0) {
      ForEach(SidebarMode.allCases) { option in
        let isSelected = option == mode
        Button {
          guard option != mode else { return }
          withAnimation(.spring(duration: 0.32, bounce: 0.18)) {
            onSelect(option)
          }
        } label: {
          Text(option.title)
            .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
            .foregroundStyle(isSelected ? Color.white : Color.primary.opacity(0.72))
            .lineLimit(1)
            .minimumScaleFactor(0.9)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background {
              if isSelected {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                  .fill(
                    LinearGradient(
                      colors: [
                        Color.purple.opacity(0.85),
                        Color(red: 0.42, green: 0.22, blue: 0.62),
                      ],
                      startPoint: .top,
                      endPoint: .bottom
                    )
                  )
                  .shadow(color: Color.purple.opacity(0.25), radius: 3, y: 1)
                  .matchedGeometryEffect(id: "thumb", in: thumbNamespace)
              }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
    }
    .padding(2)
    .background(
      RoundedRectangle(cornerRadius: 9, style: .continuous)
        .fill(Color.primary.opacity(0.07))
    )
    .frame(maxWidth: .infinity)
  }
}

struct AppView: View {
  @Bindable var store: StoreOf<AppFeature>
  @State private var columnVisibility = NavigationSplitViewVisibility.automatic
  /// Resolved from `store.activeTab` so sub-tab clicks keep the
  /// sidebar in the right mode without an extra source of truth.
  private var sidebarMode: SidebarMode {
    switch store.state.activeTab {
    case .history: .history
    default: .settings
    }
  }

  var body: some View {
    NavigationSplitView(columnVisibility: $columnVisibility) {
      VStack(alignment: .leading, spacing: 0) {
        // Mode pills — custom segmented control with brand-tinted
        // selection, animated thumb, and SF Symbols on each side.
        // Replaces the default `.segmented` picker style which felt
        // utilitarian and didn't visually center within the
        // sidebar's leading-aligned VStack.
        SidebarModeToggle(
          mode: sidebarMode,
          onSelect: { newMode in
            switch newMode {
            case .settings:
              if store.state.activeTab == .history {
                store.send(.setActiveTab(.general))
              }
            case .history:
              store.send(.setActiveTab(.history))
            }
          }
        )
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 10)

        // Sub-tabs — only meaningful in Settings mode. We render
        // an empty placeholder in History mode so the sidebar
        // stays a stable width and the pills don't shift.
        if sidebarMode == .settings {
          List(selection: $store.activeTab) {
            tabRow(.general, label: "General", icon: "gearshape")
            tabRow(.recording, label: "Recording", icon: "mic.circle")
            tabRow(.ai, label: "AI", icon: "sparkles")
            tabRow(.integrations, label: "Integrations", icon: "app.connected.to.app.below.fill")
            tabRow(.remappings, label: "Transforms", icon: "text.badge.plus")
            tabRow(.about, label: "About", icon: "info.circle")
          }
          .listStyle(.sidebar)
        } else {
          // Subtle hint that the sidebar is intentionally empty
          // while History owns the right pane.
          Spacer()
          HStack {
            Spacer()
            Text("Showing all transcripts")
              .font(.caption)
              .foregroundStyle(.secondary)
            Spacer()
          }
          .padding(.bottom, 16)
        }
      }
    } detail: {
      switch store.state.activeTab {
      case .general:
        GeneralSettingsTabView(
          store: store.scope(state: \.settings, action: \.settings),
          microphonePermission: store.microphonePermission,
          accessibilityPermission: store.accessibilityPermission,
          inputMonitoringPermission: store.inputMonitoringPermission
        )
        .navigationTitle("General")
      case .recording:
        RecordingSettingsTabView(
          store: store.scope(state: \.settings, action: \.settings),
          microphonePermission: store.microphonePermission
        )
        .navigationTitle("Recording")
      case .ai:
        AISettingsTabView(store: store.scope(state: \.settings, action: \.settings))
          .navigationTitle("AI")
      case .integrations:
        IntegrationsSettingsTabView(store: store.scope(state: \.settings, action: \.settings))
          .navigationTitle("Integrations")
      case .remappings:
        WordRemappingsView(store: store.scope(state: \.settings, action: \.settings))
          .navigationTitle("Transforms")
      case .history:
        HistoryView(store: store.scope(state: \.history, action: \.history))
          .navigationTitle("History")
      case .about:
        AboutView(store: store.scope(state: \.settings, action: \.settings))
          .navigationTitle("About")
      }
    }
    .sheet(isPresented: Binding(
      get: { !store.settings.hexSettings.hasCompletedOnboarding },
      set: { newValue in
        // The onboarding view fires `.markOnboardingComplete` itself
        // when it dismisses; this setter just handles the case where
        // SwiftUI dismisses the sheet for some other reason.
        if newValue == false {
          store.send(.settings(.markOnboardingComplete))
        }
      }
    )) {
      OnboardingView(
        store: store.scope(state: \.settings, action: \.settings),
        microphonePermission: store.microphonePermission,
        accessibilityPermission: store.accessibilityPermission,
        inputMonitoringPermission: store.inputMonitoringPermission,
        onDismiss: {
          // Already marked complete inside `OnboardingView.complete`,
          // but the SwiftUI sheet binding needs us to flip its
          // `isPresented` source-of-truth, which we do by sending
          // the same action defensively.
          store.send(.settings(.markOnboardingComplete))
        }
      )
    }
    .enableInjection()
  }

  /// Sidebar row builder. Encodes the consistent button-as-row
  /// pattern used by every entry in the navigation list and keeps
  /// the call sites readable.
  @ViewBuilder
  private func tabRow(_ tab: AppFeature.ActiveTab, label: String, icon: String) -> some View {
    Button {
      store.send(.setActiveTab(tab))
    } label: {
      Label(label, systemImage: icon)
    }
    .buttonStyle(.plain)
    .tag(tab)
  }
}
