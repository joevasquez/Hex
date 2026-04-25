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

/// Catchall for cross-cutting settings that don't belong to a specific
/// recording / AI / integration concern: permissions, sound feedback,
/// general app behavior (open at login, dock icon, sleep), and the
/// transcript-history retention controls.
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
      HistorySectionView(store: store)

      // Welcome-tour replay — sits at the bottom of General because
      // it's the catchall settings tab and this is a low-frequency
      // action that doesn't deserve its own section header.
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

/// All knobs that affect how a recording becomes a transcript: which
/// model, which language, which mic, which hotkey. Pulled out of
/// General because users open these together (e.g. picking a new
/// language → revisiting model size).
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
      HotKeySectionView(store: store)
      if microphonePermission == .granted {
        MicrophoneSelectionSectionView(store: store)
      }
    }
    .formStyle(.grouped)
    .task { await store.send(.task).finish() }
    .enableInjection()
  }
}

// MARK: - AI

/// Everything that touches a cloud LLM: provider + key, the
/// post-processing modes (off / clean / email / notes / ...), voice
/// commands, inline edit, and the user's library of custom modes.
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
    IntegrationsSectionView(store: store)
      .task { await store.send(.task).finish() }
      .enableInjection()
  }
}
