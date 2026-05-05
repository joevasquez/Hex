//
//  AIProcessingSectionView.swift
//  Hex
//

import AppKit
import ComposableArchitecture
import HexCore
import Inject
import SwiftUI

/// Renders the AI tab's grouped sections: the master toggle on top,
/// then Provider / Default Mode / Behavior subsections — each in its
/// own labeled `Section` so the AI tab reads as a scannable settings
/// hierarchy instead of a single long flat list.
struct AIProcessingSectionView: View {
  @ObserveInjection var inject
  @Bindable var store: StoreOf<SettingsFeature>
  @State private var apiKeyText: String = ""
  @State private var isAPIKeyVisible: Bool = false

  var body: some View {
    // Master toggle — always visible at the top of the tab.
    Section {
      Label {
        Toggle(
          "Enable AI Enhancement",
          isOn: Binding(
            get: { store.hexSettings.aiProcessingEnabled },
            set: { store.send(.setAIProcessingEnabled($0)) }
          )
        )
        Text("Process transcriptions through an AI model before pasting")
          .settingsCaption()
      } icon: {
        Image(systemName: "sparkles")
      }
    } header: {
      Text("AI Enhancement")
    }
    .enableInjection()

    if store.hexSettings.aiProcessingEnabled {
      providerSection
      defaultModeSection
      perAppOverridesSection
      behaviorSection
    }
  }

  // MARK: - Provider

  /// Where the AI request actually goes (OpenAI / Anthropic / …) plus
  /// the credential to authenticate it. Kept compact so users with the
  /// key already saved don't see a tall block.
  @ViewBuilder private var providerSection: some View {
    Section {
      Label {
        HStack {
          Text("AI Provider")
          Spacer()
          Picker("", selection: Binding(
            get: { store.hexSettings.aiProvider },
            set: { newProvider in
              store.send(.setAIProvider(newProvider))
              apiKeyText = ""
              store.send(.loadAPIKey(newProvider))
            }
          )) {
            ForEach(AIProvider.allCases, id: \.self) { provider in
              Text(provider.displayName).tag(provider)
            }
          }
          .pickerStyle(.menu)
        }
      } icon: {
        Image(systemName: "cloud")
      }

      Label {
        VStack(alignment: .leading, spacing: 4) {
          HStack {
            if isAPIKeyVisible {
              TextField("API Key", text: $apiKeyText)
                .textFieldStyle(.roundedBorder)
            } else {
              SecureField("API Key", text: $apiKeyText)
                .textFieldStyle(.roundedBorder)
            }
            Button {
              isAPIKeyVisible.toggle()
            } label: {
              Image(systemName: isAPIKeyVisible ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)
            Button("Save") {
              store.send(.saveAPIKey(apiKeyText, forProvider: store.hexSettings.aiProvider))
            }
            .buttonStyle(.borderless)
          }
          if store.apiKeySaved {
            Text("Key saved to Keychain")
              .font(.caption)
              .foregroundStyle(.green)
          } else {
            Text("Your API key is stored securely in the macOS Keychain")
              .settingsCaption()
          }
        }
      } icon: {
        Image(systemName: "key")
      }
      .onAppear {
        store.send(.loadAPIKey(store.hexSettings.aiProvider))
      }
      .onChange(of: store.loadedAPIKey) { _, newValue in
        if !newValue.isEmpty && apiKeyText.isEmpty {
          apiKeyText = newValue
        }
      }
    } header: {
      Text("Provider")
    }
  }

  // MARK: - Default Mode

  /// What flavor of post-processing runs by default, plus the
  /// auto-pick-by-app override. Grouped because both controls answer
  /// the same question: "which mode should fire when I dictate?"
  @ViewBuilder private var defaultModeSection: some View {
    Section {
      Label {
        HStack {
          Text("Default Mode")
          Spacer()
          Picker("", selection: Binding(
            get: { store.hexSettings.aiProcessingMode },
            set: { store.send(.setAIProcessingMode($0)) }
          )) {
            ForEach(AIProcessingMode.allCases, id: \.self) { mode in
              Text(mode.displayName).tag(mode)
            }
          }
          .pickerStyle(.menu)
        }
      } icon: {
        Image(systemName: "text.badge.star")
      }

      if store.hexSettings.aiProcessingMode != .off {
        Text(store.hexSettings.aiProcessingMode.description)
          .settingsCaption()
          .padding(.leading, 32)
      }

      Label {
        Toggle(
          "Auto-select mode by app",
          isOn: Binding(
            get: { store.hexSettings.contextAwareAutoMode },
            set: { store.send(.setContextAwareAutoMode($0)) }
          )
        )
        Text("Automatically choose AI mode based on the active application (e.g., Mail → Email, Slack → Message)")
          .settingsCaption()
      } icon: {
        Image(systemName: "app.badge")
      }
    } header: {
      Text("Default Mode")
    }
  }

  // MARK: - Per-app overrides

  /// User-managed list of "when I'm in <App>, use <Mode>" rules.
  /// Sits below the built-in "Auto-select mode by app" toggle and
  /// the default-mode picker — overrides win over both. Each rule is
  /// rendered as a row with an app picker (NSOpenPanel-driven) and
  /// a mode picker. Empty list shows a helpful empty-state row.
  @ViewBuilder private var perAppOverridesSection: some View {
    Section {
      if store.hexSettings.appModeRules.isEmpty {
        Label {
          VStack(alignment: .leading, spacing: 4) {
            Text("No per-app overrides yet")
              .foregroundStyle(.secondary)
            Text("Add a rule below to use a different AI mode in specific apps. Overrides beat both the default and the auto-select toggle.")
              .settingsCaption()
          }
        } icon: {
          Image(systemName: "app.dashed")
        }
      } else {
        ForEach(store.hexSettings.appModeRules) { rule in
          AppModeRuleRow(
            rule: rule,
            onPickApp: { picked in
              store.send(.updateAppModeRule(.init(
                id: rule.id,
                bundleIdentifier: picked.bundleIdentifier,
                appName: picked.appName,
                mode: rule.mode
              )))
            },
            onModeChange: { mode in
              store.send(.updateAppModeRule(.init(
                id: rule.id,
                bundleIdentifier: rule.bundleIdentifier,
                appName: rule.appName,
                mode: mode
              )))
            },
            onRemove: { store.send(.removeAppModeRule(rule.id)) }
          )
        }
      }

      Button {
        store.send(.addAppModeRule)
      } label: {
        Label("Add rule…", systemImage: "plus.circle")
      }
      .buttonStyle(.plain)
    } header: {
      Text("Per-app overrides")
    } footer: {
      Text("Pick an app and the AI mode Quill should use whenever you dictate while it's frontmost.")
        .settingsCaption()
    }
  }

  // MARK: - Behavior

  /// Cross-cutting AI behavior knobs that don't pick a mode or a
  /// provider — context awareness, voice commands, inline edit, and
  /// the placeholder for the streaming-transcript feature.
  @ViewBuilder private var behaviorSection: some View {
    Section {
      Label {
        Toggle(
          "Use app context to enrich results",
          isOn: Binding(
            get: { store.hexSettings.contextEnrichmentEnabled },
            set: { store.send(.setContextEnrichmentEnabled($0)) }
          )
        )
        Text("Read selected/surrounding text from the active app to improve AI formatting and tone (requires Accessibility permission)")
          .settingsCaption()
      } icon: {
        Image(systemName: "text.magnifyingglass")
      }

      Label {
        Toggle(
          "Voice Commands",
          isOn: Binding(
            get: { store.hexSettings.voiceCommandsEnabled },
            set: { store.send(.setVoiceCommandsEnabled($0)) }
          )
        )
        if store.hexSettings.voiceCommandsEnabled {
          Text("Inline: \"period\", \"comma\", \"question mark\", \"colon\", \"new paragraph\", \"new line\" become punctuation / breaks mid-sentence. Standalone: say \"select all\", \"undo\", or \"redo\" alone to trigger the editor command.")
            .settingsCaption()
        }
      } icon: {
        Image(systemName: "mic.badge.plus")
      }

      Label {
        Toggle(
          "Inline Edit (edit selected text with voice)",
          isOn: Binding(
            get: { store.hexSettings.inlineEditEnabled },
            set: { store.send(.setInlineEditEnabled($0)) }
          )
        )
        if store.hexSettings.inlineEditEnabled {
          Text("When text is selected in the focused app, your next dictation is treated as an edit instruction and applied to the selection. Try: \"tighten 20%\", \"make it warmer\", \"convert to bullets\", \"translate to Spanish\".")
            .settingsCaption()
        } else {
          Text("Off: all dictations paste as new content (current behavior).")
            .settingsCaption()
        }
      } icon: {
        Image(systemName: "text.cursor")
      }

      Label {
        Toggle(
          "Show live transcript while recording",
          isOn: .constant(false)
        )
        .disabled(true)
        Text("Coming soon — requires streaming transcription support")
          .settingsCaption()
      } icon: {
        Image(systemName: "text.bubble")
      }
    } header: {
      Text("Behavior")
    }
  }
}

// MARK: - AppModeRuleRow

/// Single row in the per-app overrides list. Pick app via NSOpenPanel
/// (so users can target apps by clicking them in /Applications instead
/// of typing bundle identifiers), pick mode via a menu, remove with a
/// red trash button. Kept as a separate view so the row layout doesn't
/// crowd the section view above it.
struct AppModeRuleRow: View {
  let rule: AppModeRule
  let onPickApp: (PickedApp) -> Void
  let onModeChange: (AIProcessingMode) -> Void
  let onRemove: () -> Void

  /// Lightweight DTO returned by the picker so we don't leak AppKit
  /// types up into the reducer.
  struct PickedApp {
    let bundleIdentifier: String
    let appName: String
  }

  var body: some View {
    HStack(spacing: 10) {
      Button {
        pickApp()
      } label: {
        HStack(spacing: 8) {
          Image(systemName: "app.badge")
            .foregroundStyle(.secondary)
          Text(displayName)
            .lineLimit(1)
            .foregroundStyle(rule.bundleIdentifier.isEmpty ? .secondary : .primary)
        }
        .padding(.vertical, 4)
      }
      .buttonStyle(.plain)
      .help("Click to pick the app this rule should apply to.")

      Spacer(minLength: 8)

      Picker(
        "",
        selection: Binding(
          get: { rule.mode },
          set: { onModeChange($0) }
        )
      ) {
        ForEach(AIProcessingMode.allCases, id: \.self) { mode in
          Text(mode.displayName).tag(mode)
        }
      }
      .labelsHidden()
      .pickerStyle(.menu)
      .frame(maxWidth: 140)

      Button(role: .destructive) {
        onRemove()
      } label: {
        Image(systemName: "trash")
      }
      .buttonStyle(.borderless)
      .help("Remove this rule.")
    }
  }

  private var displayName: String {
    if !rule.appName.isEmpty { return rule.appName }
    if !rule.bundleIdentifier.isEmpty { return rule.bundleIdentifier }
    return "Pick app…"
  }

  /// Open `NSOpenPanel` scoped to /Applications, read the picked
  /// bundle's `Info.plist` for the bundle identifier + display name.
  /// Falls back to the file basename if the plist read fails (rare,
  /// but possible for non-app bundles the user might pick by mistake).
  private func pickApp() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.allowedContentTypes = [.application]
    panel.directoryURL = URL(fileURLWithPath: "/Applications")
    panel.message = "Choose the app this rule should apply to"
    panel.prompt = "Select"
    guard panel.runModal() == .OK, let url = panel.url else { return }

    let bundle = Bundle(url: url)
    let bundleID = bundle?.bundleIdentifier ?? ""
    let name = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
      ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
      ?? url.deletingPathExtension().lastPathComponent

    onPickApp(.init(bundleIdentifier: bundleID, appName: name))
  }
}
