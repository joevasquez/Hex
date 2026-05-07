//
//  KeyboardBridge.swift
//  HexCore
//
//  iOS keyboard extensions are non-focal processes and the OS denies them
//  audio input. To work around that, the QuillKeyboard extension trampolines
//  recording requests to the parent app via a `quill://keyboard` deep link
//  and an App Group "mailbox": the extension writes a request, the app reads
//  it, records as a focal process, writes a result back, and the extension
//  picks the result up the next time the user returns to a host app.
//

import Foundation

public enum KeyboardBridge {
  /// Shared App Group used by the main app, the widget, and the keyboard.
  public static let appGroup = "group.com.joevasquez.Quill"

  /// UserDefaults key under which the keyboard writes its outstanding
  /// request. Cleared by the app once it picks the request up.
  public static let requestKey = "quill.keyboard.bridge.request"

  /// UserDefaults key under which the app writes the recorded transcript.
  /// Cleared by the keyboard once it inserts the result at the cursor.
  public static let resultKey = "quill.keyboard.bridge.result"

  /// URL scheme + host the keyboard uses to open the parent app.
  /// `id` is required and must round-trip through the result so the
  /// keyboard can tell its own request apart from a stale one.
  public static let urlScheme = "quill"
  public static let urlHost = "keyboard"

  public enum Mode: String, Codable, Sendable {
    /// Plain dictation — app records, transcribes, returns text.
    case dictate
    /// Action mode — app records, transcribes, parses, runs the action
    /// itself (creates the Reminder/Todoist task/etc.), and returns an
    /// empty transcript so the keyboard inserts nothing.
    case action
  }

  public struct Request: Codable, Equatable, Sendable {
    public let id: UUID
    public let mode: Mode
    public let createdAt: Date

    public init(id: UUID = UUID(), mode: Mode, createdAt: Date = Date()) {
      self.id = id
      self.mode = mode
      self.createdAt = createdAt
    }
  }

  public struct Result: Codable, Equatable, Sendable {
    public let id: UUID
    public let transcript: String
    public let createdAt: Date

    public init(id: UUID, transcript: String, createdAt: Date = Date()) {
      self.id = id
      self.transcript = transcript
      self.createdAt = createdAt
    }
  }

  /// Write a request to the App Group mailbox. Called by the keyboard
  /// just before triggering the deep link.
  public static func writeRequest(_ request: Request) {
    guard let defaults = UserDefaults(suiteName: appGroup) else { return }
    if let data = try? JSONEncoder().encode(request) {
      defaults.set(data, forKey: requestKey)
    }
  }

  /// Read and clear the pending request. Called by the app after the
  /// deep link arrives.
  public static func consumeRequest() -> Request? {
    guard let defaults = UserDefaults(suiteName: appGroup) else { return nil }
    guard let data = defaults.data(forKey: requestKey) else { return nil }
    defaults.removeObject(forKey: requestKey)
    return try? JSONDecoder().decode(Request.self, from: data)
  }

  /// Peek at the current request without clearing it. Used by the app's
  /// bridge view as a fallback if the deep link's id parameter is missing.
  public static func peekRequest() -> Request? {
    guard let defaults = UserDefaults(suiteName: appGroup) else { return nil }
    guard let data = defaults.data(forKey: requestKey) else { return nil }
    return try? JSONDecoder().decode(Request.self, from: data)
  }

  /// Write a result. Called by the app after recording + transcription.
  public static func writeResult(_ result: Result) {
    guard let defaults = UserDefaults(suiteName: appGroup) else { return }
    if let data = try? JSONEncoder().encode(result) {
      defaults.set(data, forKey: resultKey)
    }
  }

  /// Read and clear the result. Called by the keyboard each time it
  /// becomes visible, to pick up text recorded while the user was in
  /// the parent app.
  public static func consumeResult() -> Result? {
    guard let defaults = UserDefaults(suiteName: appGroup) else { return nil }
    guard let data = defaults.data(forKey: resultKey) else { return nil }
    defaults.removeObject(forKey: resultKey)
    return try? JSONDecoder().decode(Result.self, from: data)
  }

  /// Build the deep-link URL the keyboard opens.
  public static func url(for request: Request) -> URL? {
    var components = URLComponents()
    components.scheme = urlScheme
    components.host = urlHost
    components.queryItems = [
      URLQueryItem(name: "id", value: request.id.uuidString),
      URLQueryItem(name: "mode", value: request.mode.rawValue),
    ]
    return components.url
  }
}
