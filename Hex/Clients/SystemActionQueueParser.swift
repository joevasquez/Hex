//
//  SystemActionQueueParser.swift
//  Quill (macOS)
//
//  Bridges the offline action queue to the macOS `ActionParsingClient` so
//  the queue manager can re-parse a raw transcript that was queued before
//  the LLM was reachable. Installed once at app launch alongside
//  `SystemActionQueueExecutor`.
//

import Dependencies
import Foundation
import HexCore

public final class SystemActionQueueParser: ActionQueueParser {
  public init() {}

  public func parse(transcript: String, provider: AIProvider) async throws -> ActionIntent {
    @Dependency(\.actionParsing) var actionParsing
    return try await actionParsing.parse(transcript, provider)
  }
}
