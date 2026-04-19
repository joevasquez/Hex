//
//  QuillIOSSettings.swift
//  Quill (iOS)
//
//  Settings keys used via @AppStorage in views. Values persist to UserDefaults.
//

import Foundation

enum QuillIOSSettingsKey {
  static let selectedModel = "quill.selectedModel"
  static let aiProcessingMode = "quill.aiProcessingMode"
  static let aiProvider = "quill.aiProvider"

  // Defaults
  static let defaultModel = "openai_whisper-tiny.en"  // Ships small, English-focused
  // AI defaults to .off so users see raw transcripts until they pick a mode.
  static let defaultMode = "off"
  static let defaultProvider = "anthropic"
}
