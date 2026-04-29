import Foundation

/// The tiny JSON blob the main iOS app writes for the home-screen
/// widget to read. Stored in App Group UserDefaults so both targets
/// can hit the same bytes. The snapshot carries just enough to draw
/// the medium-sized widget face: the active note's title, a short
/// preview (first ~120 chars of body with photo tokens stripped),
/// and when it was last touched.
///
/// The main app is expected to call `write(from:)` every time the
/// active note mutates and follow it with
/// `WidgetCenter.shared.reloadAllTimelines()` so the home-screen
/// widget redraws.
public struct QuillWidgetSnapshot: Codable, Equatable, Sendable {
  public var title: String
  public var preview: String
  public var updatedAt: Date

  public init(title: String, preview: String, updatedAt: Date) {
    self.title = title
    self.preview = preview
    self.updatedAt = updatedAt
  }

  // MARK: - App Group storage

  /// Must match the App Group capability added to both the main app
  /// and the widget extension (Signing & Capabilities → App Groups).
  public static let appGroupIdentifier = "group.com.joevasquez.Quill"
  private static let storageKey = "quill.widgetSnapshot"

  public static var placeholder: QuillWidgetSnapshot {
    QuillWidgetSnapshot(
      title: "Your latest note",
      preview: "Record a voice note in Quill and it'll show up here.",
      updatedAt: Date()
    )
  }

  /// Read the most recent snapshot from shared UserDefaults. Returns
  /// nil when nothing has been written yet (fresh install, or the
  /// App Group isn't configured).
  public static func load() -> QuillWidgetSnapshot? {
    guard let defaults = UserDefaults(suiteName: appGroupIdentifier),
          let data = defaults.data(forKey: storageKey)
    else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(QuillWidgetSnapshot.self, from: data)
  }

  public func save() {
    guard let defaults = UserDefaults(suiteName: Self.appGroupIdentifier) else { return }
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    if let data = try? encoder.encode(self) {
      defaults.set(data, forKey: Self.storageKey)
    }
  }

  public static func clear() {
    guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else { return }
    defaults.removeObject(forKey: storageKey)
  }
}
