//
//  AIProcessingSectionView.swift
//  Hex
//

import ComposableArchitecture
import HexCore
import Inject
import SwiftUI

struct AIProcessingSectionView: View {
  @ObserveInjection var inject
  @Bindable var store: StoreOf<SettingsFeature>
  @State private var apiKeyText: String = ""
  @State private var isAPIKeyVisible: Bool = false

  var body: some View {
    Section {
      // Master toggle
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

      if store.hexSettings.aiProcessingEnabled {
        // Mode picker
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

        // Provider picker
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

        // API Key input
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

        // Context-aware auto-mode
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

        // Context enrichment
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

        // Live transcript (coming soon)
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

        // Voice commands
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
      }
    } header: {
      Text("AI Enhancement")
    }
    .enableInjection()
  }
}
