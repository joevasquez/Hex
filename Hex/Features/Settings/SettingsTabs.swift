//
//  SettingsTabs.swift
//  Hex (macOS)
//
//  Wrapper views that compose the existing settings section views
//  into focused, scannable screens. The original `SettingsView`
//  stuffed eleven sections into a single Form, which made the
//  Settings sidebar tab feel like a kitchen drawer. As of 0.9.x the
//  app sidebar has separate destinations for General, Recording, AI,
//  and Integrations — each one renders one of these wrappers.
//
//  Each wrapper is intentionally tiny — just a `Form` that lists the
//  pre-existing section views. No new behavior; this is purely an
//  information-architecture pass.
//

import ComposableArchitecture
import HexCore
import Inject
import SwiftUI

// MARK: - General

/// Cross-cutting settings that don't belong to a specific recording /
/// AI / integration concern: permissions surface, sound feedback, and
/// the small set of app-level toggles (open on login, dock icon).
/// Recording-time behavior and transcript-history controls used to
/// live here too — those moved to the Recording tab in the 0.10
/// settings reorganization.
struct GeneralSettingsTabView: View {
  @ObserveInjection var inject
  @Bindable var store: StoreOf<SettingsFeature>
  let microphonePermission: PermissionStatus
  let accessibilityPermission: PermissionStatus
  let inputMonitoringPermission: PermissionStatus

  var body: some View {
    Form {
      if microphonePermission != .granted
          || accessibilityPermission != .granted
          || inputMonitoringPermission != .granted
      {
        PermissionsSectionView(
          store: store,
          microphonePermission: microphonePermission,
          accessibilityPermission: accessibilityPermission,
          inputMonitoringPermission: inputMonitoringPermission
        )
      }
      SoundSectionView(store: store)
      GeneralSectionView(store: store)
      OfflineQueueSectionView()
      CloudSyncSectionView(store: store)

      Section {
        Button {
          store.send(.replayOnboarding)
        } label: {
          Label("Replay Tutorial", systemImage: "sparkle.magnifyingglass")
        }
      } footer: {
        Text("Re-runs the first-launch welcome walk-through.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .task { await store.send(.task).finish() }
    .enableInjection()
  }
}

// MARK: - Recording

/// Comprehensive recording hub — every knob that touches the path from
/// "user pressed the hotkey" to "transcript pasted into another app":
/// model + language, microphone, hotkeys, what happens to system audio
/// during a recording, how the finished text is delivered, and the
/// transcript-history retention controls. Recording-time behavior and
/// history settings used to be split across General; the 0.10 settings
/// reorganization consolidated them here.
struct RecordingSettingsTabView: View {
  @ObserveInjection var inject
  @Bindable var store: StoreOf<SettingsFeature>
  let microphonePermission: PermissionStatus

  var body: some View {
    Form {
      ModelSectionView(store: store, shouldFlash: store.shouldFlashModelSection)
      // Parakeet is multilingual + auto-detects, so the language picker
      // only makes sense for the WhisperKit family.
      if ParakeetModel(rawValue: store.hexSettings.selectedModel) == nil {
        LanguageSectionView(store: store)
      }
      if microphonePermission == .granted {
        MicrophoneSelectionSectionView(store: store)
      }
      HotKeySectionView(store: store)
      RecordingBehaviorSectionView(store: store)
      RecordingOutputSectionView(store: store)
      HistorySectionView(store: store)
    }
    .formStyle(.grouped)
    .task { await store.send(.task).finish() }
    .enableInjection()
  }
}

// MARK: - AI

/// Everything that touches a cloud LLM, organized as a small hierarchy:
/// the master toggle on top, then **Provider** (which API + key),
/// **Default Mode** (which post-processing flavor + auto-pick-by-app),
/// **Behavior** (context, voice commands, inline edit, future
/// streaming-transcript), and the user's library of **Custom Modes**.
/// Future Pro-only AI features will cluster here.
struct AISettingsTabView: View {
  @ObserveInjection var inject
  @Bindable var store: StoreOf<SettingsFeature>

  var body: some View {
    Form {
      AIProcessingSectionView(store: store)
      CustomModesSectionView(store: store)
    }
    .formStyle(.grouped)
    .task { await store.send(.task).finish() }
    .enableInjection()
  }
}

// MARK: - Integrations

/// Stand-alone tab for the integrations catalog. Kept separate from
/// AI because integrations are about *destinations* (where a
/// dictation goes — Todoist, Notion, Slack, …), while AI is about
/// *transformations* (how the text reads when it gets there).
struct IntegrationsSettingsTabView: View {
  @ObserveInjection var inject
  @Bindable var store: StoreOf<SettingsFeature>

  var body: some View {
    // Stack the Google Account panel above the per-integration catalog so
    // sign-in is the first thing the user sees on this tab. ScrollView wraps
    // both because each child uses `.formStyle(.grouped)` — without it the
    // catalog can clip under the window's bottom edge on smaller windows.
    ScrollView {
      VStack(spacing: 0) {
        GoogleAccountSectionView(store: store)
        IntegrationsSectionView(store: store)
      }
    }
    .task { await store.send(.task).finish() }
    .enableInjection()
  }
}
