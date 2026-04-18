//
//  QuillIOSSettings.swift
//  Quill (iOS)
//
//  Settings keys used via @AppStorage in views. Values persist to UserDefaults.
//

import Foundation

enum QuillIOSSettingsKey {
  static let selectedModel = "quill.selectedModel"
  static let aiProcessingEnabled = "quill.aiProcessingEnabled"
  static let aiProcessingMode = "quill.aiProcessingMode"
  static let aiProvider = "quill.aiProvider"

  // Defaults
  static let defaultModel = "openai_whisper-tiny.en"  // Ships small, English-focused
  static let defaultMode = "clean"
  static let defaultProvider = "anthropic"
}
