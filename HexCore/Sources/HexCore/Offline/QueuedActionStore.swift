//
//  QueuedActionStore.swift
//  HexCore
//
//  File-based JSON persistence for the offline action queue. Single
//  consolidated file at
//  `~/.../Application Support/com.joevasquez.Quill/queued-actions.json`,
//  re-written atomically on every mutation.
//
//  Why a single file instead of one-file-per-item: the queue is normally
//  empty or holds a handful of items at most. A single file keeps the
//  persistence layer trivial and makes "clear all" / "load all" the obvious
//  operations they should be. Re-writing on each mutation isn't a perf
//  concern — these are user-driven Action mode events, not high-volume
//  background mutations.
//

import Foundation
import os

private let queueLogger = HexLog.app

public actor QueuedActionStore {
  public static let shared = QueuedActionStore()

  /// Lazily resolved on first access — Application Support might not be
  /// reachable during early launch on iOS Simulator quirks, so we don't
  /// throw at construction time.
  private var cachedURL: URL?

  private let fileName = "queued-actions.json"

  public init() {}

  // MARK: - Public

  public func loadAll() -> [QueuedAction] {
    guard let url = try? fileURL() else { return [] }
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }

    do {
      let data = try Data(contentsOf: url)
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      return try decoder.decode([QueuedAction].self, from: data)
    } catch {
      queueLogger.error("QueuedActionStore: load failed: \(error.localizedDescription, privacy: .public)")
      return []
    }
  }

  public func save(_ items: [QueuedAction]) {
    do {
      let url = try fileURL()
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let data = try encoder.encode(items)
      try data.write(to: url, options: [.atomic])
    } catch {
      queueLogger.error("QueuedActionStore: save failed: \(error.localizedDescription, privacy: .public)")
    }
  }

  /// Convenience for "append, persist" without a manual load+save dance.
  public func append(_ item: QueuedAction) {
    var items = loadAll()
    items.append(item)
    save(items)
  }

  /// Replace a single item (matched by id). Used by the manager to bump
  /// `retryCount` / `lastError` after a failed attempt.
  public func update(_ item: QueuedAction) {
    var items = loadAll()
    if let idx = items.firstIndex(where: { $0.id == item.id }) {
      items[idx] = item
      save(items)
    }
  }

  public func remove(id: UUID) {
    var items = loadAll()
    items.removeAll { $0.id == id }
    save(items)
  }

  public func clear() {
    save([])
  }

  // MARK: - Internal

  private func fileURL() throws -> URL {
    if let cachedURL { return cachedURL }
    let url = try URL.hexApplicationSupport.appendingPathComponent(fileName, isDirectory: false)
    cachedURL = url
    return url
  }
}
