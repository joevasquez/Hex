//
//  ErrorContext.swift
//  HexCore
//
//  Tagged context + breadcrumb types attached to captured errors. Adapted
//  from the generators/error-monitoring template; sliced down to what we
//  actually use today (no fingerprint, simpler factory helpers).
//

import Foundation

/// Tagged context attached to a captured error.
public struct ErrorContext: Sendable {
  /// Indexed string tags used for grouping and filtering on the dashboard
  /// (e.g. "feature": "action_mode").
  public var tags: [String: String]

  /// Free-form data attached to the error report. Values must be Sendable.
  public var extra: [String: any Sendable]

  public init(
    tags: [String: String] = [:],
    extra: [String: any Sendable] = [:]
  ) {
    self.tags = tags
    self.extra = extra
  }
}

public extension ErrorContext {
  /// Builder helper — returns a copy with `key`: `value` added to tags.
  func tag(_ key: String, _ value: String) -> ErrorContext {
    var copy = self
    copy.tags[key] = value
    return copy
  }

  /// Builder helper — returns a copy with `key`: `value` added to extra.
  func with(_ key: String, _ value: any Sendable) -> ErrorContext {
    var copy = self
    copy.extra[key] = value
    return copy
  }

  /// Common shorthand — categorize by feature ("ai", "action_mode", etc.).
  static func feature(_ name: String) -> ErrorContext {
    ErrorContext(tags: ["feature": name])
  }
}

// MARK: - Breadcrumb

public struct Breadcrumb: Sendable {
  public let timestamp: Date
  /// Category (e.g. "navigation", "ui", "network").
  public let category: String
  public let message: String
  public let level: ErrorLevel
  public let data: [String: String]?

  public init(
    category: String,
    message: String,
    level: ErrorLevel = .info,
    data: [String: String]? = nil
  ) {
    self.timestamp = .now
    self.category = category
    self.message = message
    self.level = level
    self.data = data
  }
}

public extension Breadcrumb {
  static func navigation(_ screen: String) -> Breadcrumb {
    Breadcrumb(category: "navigation", message: "Viewed \(screen)")
  }

  static func ui(_ action: String) -> Breadcrumb {
    Breadcrumb(category: "ui", message: action)
  }

  static func network(_ method: String, _ url: String, status: Int? = nil) -> Breadcrumb {
    var data = ["method": method, "url": url]
    if let status { data["status"] = String(status) }
    return Breadcrumb(category: "network", message: "\(method) \(url)", data: data)
  }
}
