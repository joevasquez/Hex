import Foundation

/// A user-defined AI post-processing mode. The user provides a short
/// name (for UI) and a `systemPrompt` describing the transformation;
/// Quill wraps that prompt in the standard safety preamble (so the
/// model doesn't hallucinate content, treat the transcript as a
/// conversation, or refuse to transform it) before sending it to the
/// configured LLM.
///
/// Example values:
///   name: "Clinical note"
///   systemPrompt: "Rewrite as a clinical progress note in SOAP format
///                  (Subjective, Objective, Assessment, Plan). Preserve
///                  dates, medications, and dosages exactly. Use past
///                  tense."
///
///   name: "VC update"
///   systemPrompt: "Reformat as a weekly investor update with three
///                  short sections: Wins, Lowlights, Asks. Use `- `
///                  bullets. Be concise."
public struct CustomAIMode: Codable, Equatable, Identifiable, Sendable, Hashable {
  public var id: UUID
  public var name: String
  public var systemPrompt: String
  /// SF Symbol name used in the mode chip / picker. Defaults to
  /// `sparkles` because every user-created mode is still an AI
  /// transformation, and it reads as the right metaphor in the chip
  /// row next to the built-in modes.
  public var icon: String
  public var createdAt: Date

  public init(
    id: UUID = UUID(),
    name: String,
    systemPrompt: String,
    icon: String = "sparkles",
    createdAt: Date = Date()
  ) {
    self.id = id
    self.name = name
    self.systemPrompt = systemPrompt
    self.icon = icon
    self.createdAt = createdAt
  }

  /// Build the full prompt that actually ships to the LLM — the
  /// shared safety preamble (never invent content, never answer
  /// questions in the transcript, never write "I am a
  /// post-processor") followed by the user's transformation text.
  public var fullSystemPrompt: String {
    AIProcessingMode.preamble + "\n\nTransformation: " + systemPrompt
  }

  public var displayName: String {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "Custom Mode" : trimmed
  }
}

/// Storage helpers — macOS uses `HexSettings.customModes`, iOS uses
/// `@AppStorage` with this JSON blob under a single key. The `storage`
/// codable wrapper exists so adding a new field to `CustomAIMode`
/// later doesn't break existing persisted data (unknown fields in the
/// JSON are simply dropped by the decoder).
public enum CustomAIModesStorage {
  public static let userDefaultsKey = "quill.customAIModes"

  public static func encode(_ modes: [CustomAIMode]) -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return (try? encoder.encode(modes)) ?? Data()
  }

  public static func decode(_ data: Data?) -> [CustomAIMode] {
    guard let data, !data.isEmpty else { return [] }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return (try? decoder.decode([CustomAIMode].self, from: data)) ?? []
  }
}

/// A lightweight identifier used by the UI to select a mode — either
/// one of the built-in modes or a user-created custom mode.
/// Persisted as a simple string: `"off"`, `"clean"`, `"email"`,
/// `"notes"`, `"message"`, `"code"`, or `"custom:<uuid>"`.
public enum AIModeSelection: Equatable, Hashable, Sendable {
  case builtIn(AIProcessingMode)
  case custom(UUID)

  public var rawValue: String {
    switch self {
    case .builtIn(let mode): return mode.rawValue
    case .custom(let id): return "custom:\(id.uuidString)"
    }
  }

  public init?(rawValue: String) {
    if rawValue.hasPrefix("custom:") {
      let uuidString = String(rawValue.dropFirst("custom:".count))
      guard let id = UUID(uuidString: uuidString) else { return nil }
      self = .custom(id)
      return
    }
    guard let mode = AIProcessingMode(rawValue: rawValue) else { return nil }
    self = .builtIn(mode)
  }

  /// Resolve this selection to the concrete system prompt that should
  /// be sent to the LLM. Returns `nil` when the mode is off or a
  /// referenced custom mode has been deleted.
  public func resolveSystemPrompt(customModes: [CustomAIMode]) -> String? {
    switch self {
    case .builtIn(let mode):
      return mode == .off ? nil : mode.systemPrompt
    case .custom(let id):
      return customModes.first(where: { $0.id == id })?.fullSystemPrompt
    }
  }

  /// The user-facing display name. Built-ins use `AIProcessingMode`'s
  /// display name; customs use their stored name (or "Custom Mode" if
  /// the id doesn't resolve — indicates a stale selection after a
  /// delete).
  public func displayName(customModes: [CustomAIMode]) -> String {
    switch self {
    case .builtIn(let mode):
      return mode.displayName
    case .custom(let id):
      return customModes.first(where: { $0.id == id })?.displayName ?? "Custom Mode"
    }
  }
}
