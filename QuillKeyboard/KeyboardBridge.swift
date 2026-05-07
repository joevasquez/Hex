//
//  KeyboardBridge.swift
//  QuillKeyboard
//
//  Local copy of the bridge keys + types used to round-trip a recording
//  request between the keyboard and the parent Quill app via the App
//  Group mailbox. The authoritative copy lives in
//  `HexCore/Sources/HexCore/Models/KeyboardBridge.swift` for the iOS
//  app target. The keyboard intentionally doesn't link HexCore (the
//  whole framework would inflate the extension past its ~48 MB memory
//  cap), so the small surface area here is duplicated by hand. Keep
//  the two files in sync — drift will silently break the bridge.
//

import Foundation

enum KeyboardBridge {
  static let appGroup = "group.com.joevasquez.Quill"
  static let requestKey = "quill.keyboard.bridge.request"
  static let resultKey = "quill.keyboard.bridge.result"
  static let urlScheme = "quill"
  static let urlHost = "keyboard"

  enum Mode: String, Codable {
    case dictate
    case action
  }

  struct Request: Codable, Equatable {
    let id: UUID
    let mode: Mode
    let createdAt: Date

    init(id: UUID = UUID(), mode: Mode, createdAt: Date = Date()) {
      self.id = id
      self.mode = mode
      self.createdAt = createdAt
    }
  }

  struct Result: Codable, Equatable {
    let id: UUID
    let transcript: String
    let createdAt: Date
  }

  static func writeRequest(_ request: Request) {
    guard let defaults = UserDefaults(suiteName: appGroup) else { return }
    if let data = try? JSONEncoder().encode(request) {
      defaults.set(data, forKey: requestKey)
    }
  }

  static func consumeRequest() -> Request? {
    guard let defaults = UserDefaults(suiteName: appGroup) else { return nil }
    guard let data = defaults.data(forKey: requestKey) else { return nil }
    defaults.removeObject(forKey: requestKey)
    return try? JSONDecoder().decode(Request.self, from: data)
  }

  static func consumeResult() -> Result? {
    guard let defaults = UserDefaults(suiteName: appGroup) else { return nil }
    guard let data = defaults.data(forKey: resultKey) else { return nil }
    defaults.removeObject(forKey: resultKey)
    return try? JSONDecoder().decode(Result.self, from: data)
  }

  static func url(for request: Request) -> URL? {
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
