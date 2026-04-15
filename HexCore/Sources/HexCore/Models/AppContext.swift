import Foundation

/// Context captured from the active application at recording start.
/// Used to enrich AI processing prompts with surrounding text.
public struct AppContext: Equatable, Sendable {
  public var selectedText: String?
  public var surroundingText: String?
  public var appName: String?
  public var bundleID: String?

  public init(
    selectedText: String? = nil,
    surroundingText: String? = nil,
    appName: String? = nil,
    bundleID: String? = nil
  ) {
    self.selectedText = selectedText
    self.surroundingText = surroundingText
    self.appName = appName
    self.bundleID = bundleID
  }

  /// Whether any meaningful context was captured.
  public var hasContent: Bool {
    (selectedText != nil && !selectedText!.isEmpty) ||
    (surroundingText != nil && !surroundingText!.isEmpty)
  }

  /// Returns a trimmed context string suitable for inclusion in an AI prompt.
  /// Truncates to maxLength to keep API calls fast and cheap.
  public func promptFragment(maxLength: Int = 500) -> String? {
    let text = selectedText ?? surroundingText
    guard let text, !text.isEmpty else { return nil }

    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.count <= maxLength {
      return trimmed
    }
    return String(trimmed.prefix(maxLength)) + "..."
  }
}
