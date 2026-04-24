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
  /// When true, inline phrases like "period", "comma", "new paragraph",
  /// etc. are substituted into punctuation / line breaks before AI
  /// post-processing runs. Mirrors the macOS `voiceCommandsEnabled`
  /// HexSettings flag.
  static let voiceCommandsEnabled = "quill.voiceCommandsEnabled"

  // Defaults
  static let defaultModel = "openai_whisper-tiny.en"  // Ships small, English-focused
  // AI defaults to .off so users see raw transcripts until they pick a mode.
  static let defaultMode = "off"
  static let defaultProvider = "anthropic"
  /// On by default — most users dictate naturally and expect "period"
  /// to become a `.` rather than the literal word.
  static let defaultVoiceCommandsEnabled = true
}
