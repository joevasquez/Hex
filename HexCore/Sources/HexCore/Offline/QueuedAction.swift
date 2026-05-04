//
//  QueuedAction.swift
//  HexCore
//
//  A single offline action waiting to be retried. Two shapes:
//  - `.ready(ActionIntent)` — already parsed by the LLM, just needs to
//    be dispatched. Created when an Action mode confirmation panel hits a
//    network error after the user pressed Create.
//  - `.pendingParse(transcript:provider:)` — the LLM parse itself failed
//    (e.g. the device went offline before the LLM call returned). The
//    raw transcript is queued; on reconnect, the manager parses it via
//    the registered `ActionParser` and promotes the item to `.ready`
//    before executing.
//
//  Why a discriminated union rather than two separate queues:
//  - One persistence file, one process loop.
//  - Promotion (`.pendingParse` → `.ready`) survives a process restart —
//    if we successfully parse but fail to execute, the next reconnect
//    skips the parse and goes straight to execution.
//

import Foundation

public struct QueuedAction: Codable, Identifiable, Sendable, Equatable {
  public let id: UUID
  public var payload: Payload
  public let createdAt: Date
  public var retryCount: Int
  public var lastAttemptAt: Date?
  public var lastError: String?

  public enum Payload: Codable, Sendable, Equatable {
    case ready(ActionIntent)
    case pendingParse(transcript: String, provider: AIProvider)
  }

  /// Hard cap on retries — past this we stop trying and surface the item
  /// as "failed" so the user can manually retry or discard.
  public static let defaultMaxRetries = 5

  public init(
    id: UUID = UUID(),
    payload: Payload,
    createdAt: Date = Date(),
    retryCount: Int = 0,
    lastAttemptAt: Date? = nil,
    lastError: String? = nil
  ) {
    self.id = id
    self.payload = payload
    self.createdAt = createdAt
    self.retryCount = retryCount
    self.lastAttemptAt = lastAttemptAt
    self.lastError = lastError
  }

  /// Convenience initializer for the common case (already-parsed intent).
  public init(intent: ActionIntent, lastError: String? = nil) {
    self.init(payload: .ready(intent), lastError: lastError)
  }

  /// True when retries have been exhausted. Items in this state stay on
  /// disk so the user can see them in the offline queue inspector but
  /// the manager stops auto-retrying them on connectivity changes.
  public var isExhausted: Bool {
    retryCount >= Self.defaultMaxRetries
  }

  /// Best-effort title for UI surfaces. For ready items it's the parsed
  /// intent's title; for pending-parse items we show a snippet of the
  /// transcript so users can recognize what they queued.
  public var displayTitle: String {
    switch payload {
    case .ready(let intent):
      return intent.title
    case .pendingParse(let transcript, _):
      let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.count <= 60 { return trimmed }
      return String(trimmed.prefix(57)) + "…"
    }
  }

  /// Optional integration target. Nil for `.pendingParse` because we
  /// don't know the target until the LLM parses the transcript.
  public var targetIntegration: Integration.Identifier? {
    switch payload {
    case .ready(let intent): return intent.targetIntegration
    case .pendingParse: return nil
    }
  }
}
