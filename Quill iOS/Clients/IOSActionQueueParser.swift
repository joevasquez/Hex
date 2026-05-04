//
//  IOSActionQueueParser.swift
//  Quill (iOS)
//
//  Bridges the offline action queue to `IOSActionParsingClient` so the
//  queue manager can parse a raw transcript that was queued before the
//  device had network access. Installed once at app launch alongside
//  `IOSSystemActionQueueExecutor`.
//

import Foundation
import HexCore

@MainActor
public final class IOSActionQueueParser: ActionQueueParser {
  public init() {}

  public func parse(transcript: String, provider: AIProvider) async throws -> ActionIntent {
    try await IOSActionParsingClient.parse(transcript: transcript, provider: provider)
  }
}
