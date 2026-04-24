//
//  SettingsView.swift
//  Quill (iOS)
//
//  iOS settings: transcription model, AI provider, API keys. AI mode is
//  chosen on the main screen via the chip row.
//

import HexCore
import SwiftUI

struct SettingsView: View {
  @Environment(\.dismiss) private var dismiss

  @AppStorage(QuillIOSSettingsKey.selectedModel) private var selectedModel: String = QuillIOSSettingsKey.defaultModel
  @AppStorage(QuillIOSSettingsKey.aiProvider) private var aiProviderRaw: String = QuillIOSSettingsKey.defaultProvider
  @AppStorage(QuillIOSSettingsKey.voiceCommandsEnabled) private var voiceCommandsEnabled: Bool = QuillIOSSettingsKey.defaultVoiceCommandsEnabled

  @State private var apiKeyText: String = ""
  @State private var isAPIKeyVisible: Bool = false
  @State private var apiKeySaved: Bool = false

  private let availableModels: [(id: String, name: String, size: String)] = [
    ("openai_whisper-tiny.en", "Whisper Tiny (English)", "~75 MB"),
    ("openai_whisper-tiny", "Whisper Tiny (Multilingual)", "~75 MB"),
    ("openai_whisper-base.en", "Whisper Base (English)", "~145 MB"),
    ("openai_whisper-small.en", "Whisper Small (English)", "~460 MB"),
  ]

  var body: some View {
    NavigationStack {
      Form {
        Section("Transcription Model") {
          Picker("Model", selection: $selectedModel) {
            ForEach(availableModels, id: \.id) { model in
              VStack(alignment: .leading) {
                Text(model.name)
                Text(model.size).font(.caption).foregroundStyle(.secondary)
              }
              .tag(model.id)
            }
          }
          .pickerStyle(.navigationLink)

          Text("Models download on first use. Tiny is fastest and good enough for most voice notes.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Section {
          Picker("Provider", selection: $aiProviderRaw) {
            ForEach(AIProvider.allCases, id: \.rawValue) { provider in
              Text(provider.displayName).tag(provider.rawValue)
            }
          }
        } header: {
          Text("AI Provider")
        } footer: {
          Text("Choose your AI mode on the main screen. The provider is used whenever a non-Raw mode is selected.")
        }

        Section {
          HStack {
            if isAPIKeyVisible {
              TextField("API Key", text: $apiKeyText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            } else {
              SecureField("API Key", text: $apiKeyText)
            }
            Button {
              isAPIKeyVisible.toggle()
            } label: {
              Image(systemName: isAPIKeyVisible ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)
          }

          Button("Save Key") { saveKey() }
            .disabled(apiKeyText.isEmpty)

          if apiKeySaved {
            Label("Saved to Keychain", systemImage: "checkmark.circle.fill")
              .foregroundStyle(.green)
              .font(.caption)
          }
        } header: {
          Text("\(currentProvider.displayName) API Key")
        } footer: {
          Text("Get an API key from \(currentProvider == .openAI ? "platform.openai.com" : "console.anthropic.com"). Stored securely in the device Keychain; never leaves your device except when you make an API call.")
        }

        Section {
          Toggle("Inline voice commands", isOn: $voiceCommandsEnabled)
        } header: {
          Text("Dictation")
        } footer: {
          Text("When on, phrases like \"period\", \"comma\", \"new paragraph\", and \"new line\" are converted to punctuation and line breaks as you dictate — instead of being transcribed literally. Applies before AI cleanup.")
        }

        Section("About") {
          Label("Quill for iOS · v0.1.0", systemImage: "info.circle")
            .font(.caption)
          Link("joevasquez.com", destination: URL(string: "https://joevasquez.com")!)
            .font(.caption)
        }
      }
      .navigationTitle("Settings")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
      .onAppear { loadKey() }
      .onChange(of: aiProviderRaw) { _, _ in
        apiKeyText = ""
        apiKeySaved = false
        loadKey()
      }
    }
  }

  private var currentProvider: AIProvider {
    AIProvider(rawValue: aiProviderRaw) ?? .anthropic
  }

  private var keychainKey: String {
    switch currentProvider {
    case .openAI: return KeychainKey.openAIAPIKey
    case .anthropic: return KeychainKey.anthropicAPIKey
    }
  }

  private func loadKey() {
    let (existing, status) = KeychainStore.read(account: keychainKey)
    print("SettingsView.loadKey(account=\(keychainKey)) status=\(status) found=\(existing != nil)")
    if let existing, !existing.isEmpty {
      apiKeyText = existing
      apiKeySaved = true
    } else {
      apiKeyText = ""
      apiKeySaved = false
    }
  }

  private func saveKey() {
    let key = apiKeyText
    guard !key.isEmpty else { return }
    let status = KeychainStore.save(account: keychainKey, value: key)
    // Verify round-trip so we never show "Saved" when read would miss.
    let (roundTrip, readStatus) = KeychainStore.read(account: keychainKey)
    print("SettingsView.saveKey: save=\(status) readBack=\(readStatus) roundTripLen=\(roundTrip?.count ?? -1)")
    apiKeySaved = (status == errSecSuccess) && (roundTrip == key)
  }
}

#Preview {
  SettingsView()
}
