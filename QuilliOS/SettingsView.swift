//
//  SettingsView.swift
//  Quill (iOS)
//
//  iOS settings: transcription model, AI provider/mode/API key.
//

import HexCore
import SwiftUI

struct SettingsView: View {
  @Environment(\.dismiss) private var dismiss

  @AppStorage(QuillIOSSettingsKey.selectedModel) private var selectedModel: String = QuillIOSSettingsKey.defaultModel
  @AppStorage(QuillIOSSettingsKey.aiProcessingEnabled) private var aiEnabled: Bool = false
  @AppStorage(QuillIOSSettingsKey.aiProcessingMode) private var aiModeRaw: String = QuillIOSSettingsKey.defaultMode
  @AppStorage(QuillIOSSettingsKey.aiProvider) private var aiProviderRaw: String = QuillIOSSettingsKey.defaultProvider

  @State private var apiKeyText: String = ""
  @State private var isAPIKeyVisible: Bool = false
  @State private var apiKeySaved: Bool = false

  // Available models for iOS
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

        Section("AI Enhancement") {
          Toggle("Enable AI Clean-up", isOn: $aiEnabled)

          if aiEnabled {
            Picker("Mode", selection: $aiModeRaw) {
              ForEach(AIProcessingMode.allCases.filter { $0 != .off }, id: \.rawValue) { mode in
                Text(mode.displayName).tag(mode.rawValue)
              }
            }

            Text(currentMode.description)
              .font(.caption)
              .foregroundStyle(.secondary)

            Picker("Provider", selection: $aiProviderRaw) {
              ForEach(AIProvider.allCases, id: \.rawValue) { provider in
                Text(provider.displayName).tag(provider.rawValue)
              }
            }
          }
        }

        if aiEnabled {
          Section("API Key") {
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

            Button("Save Key") {
              saveKey()
            }
            .disabled(apiKeyText.isEmpty)

            if apiKeySaved {
              Label("Saved to Keychain", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
            }

            Text("Get an API key from \(currentProvider == .openAI ? "platform.openai.com" : "console.anthropic.com"). Stored securely in Keychain; never leaves your device except when you make an API call.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
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

  private var currentMode: AIProcessingMode {
    AIProcessingMode(rawValue: aiModeRaw) ?? .clean
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
    Task {
      let existing = await KeychainClient.liveValue.read(keychainKey) ?? ""
      await MainActor.run {
        if !existing.isEmpty {
          apiKeyText = existing
          apiKeySaved = true
        }
      }
    }
  }

  private func saveKey() {
    let key = apiKeyText
    Task {
      do {
        try await KeychainClient.liveValue.save(keychainKey, key)
        await MainActor.run { apiKeySaved = true }
      } catch {
        await MainActor.run { apiKeySaved = false }
      }
    }
  }
}

#Preview {
  SettingsView()
}
