//
//  ActionQueueManager.swift
//  HexCore
//
//  The brain of the offline action queue. Holds:
//  - The persistent store (file-backed list of QueuedActions)
//  - A registered executor (platform-specific — routes ActionIntent to the
//    right adapter)
//  - A registered parser (platform-specific — runs an LLM call against a
//    raw transcript). Optional; only needed if your app enqueues raw
//    transcripts via `enqueueTranscript`.
//  - A NetworkMonitor observer that triggers `processQueue()` on reconnect
//  - The retry policy (exponential backoff with jitter)
//
//  Flow for a `.ready` item (already-parsed intent failed at execute time):
//    enqueue → wait for reconnect → executor.execute → remove / bump retry
//
//  Flow for a `.pendingParse` item (LLM parse itself failed):
//    enqueueTranscript → wait for reconnect → parser.parse → promote to
//    `.ready` and persist → executor.execute → remove / bump retry
//
//  Promotion is persisted between parse and execute so a successful parse
//  followed by a failed execute doesn't re-pay the parse on the next pass.
//

import Foundation
import os

private let queueLogger = HexLog.app

/// Platform-specific dispatcher that knows how to execute a queued
/// ActionIntent. Each app target installs its own implementation.
public protocol ActionQueueExecutor: Sendable {
  /// Attempt to execute the intent. Throw on failure — the manager will
  /// classify the error and decide whether to retry or give up.
  func execute(_ intent: ActionIntent) async throws
}

/// Platform-specific LLM dispatcher used to convert a raw queued
/// transcript into a parsed `ActionIntent` once the device is back
/// online. Optional — apps that never enqueue raw transcripts don't
/// need to install one.
public protocol ActionQueueParser: Sendable {
  func parse(transcript: String, provider: AIProvider) async throws -> ActionIntent
}

public actor ActionQueueManager {
  public static let shared = ActionQueueManager()

  private let store = QueuedActionStore.shared
  private let retryPolicy: RetryPolicy
  private var executor: ActionQueueExecutor?
  private var parser: ActionQueueParser?

  /// Token from NetworkMonitor; cleared if we ever need to detach.
  private var monitorToken: UUID?

  /// Set true while a `processQueue()` pass is in flight so concurrent
  /// reconnect signals don't trigger overlapping passes.
  private var isProcessing = false

  /// In-memory mirror of the persisted count, updated as we mutate. Lets
  /// the UI peek at "how many pending" without hitting disk.
  public private(set) var pendingCount: Int = 0

  private init(retryPolicy: RetryPolicy = .default) {
    self.retryPolicy = retryPolicy
  }

  // MARK: - Setup

  /// Called once during app launch with the executor (always required)
  /// and an optional parser (only needed if the app enqueues raw
  /// transcripts via `enqueueTranscript`).
  public func install(executor: ActionQueueExecutor, parser: ActionQueueParser? = nil) async {
    self.executor = executor
    self.parser = parser
    pendingCount = await store.loadAll().count
    queueLogger.info("ActionQueueManager: installed (pending: \(self.pendingCount, privacy: .public), parser: \(parser != nil ? "yes" : "no", privacy: .public))")

    // Subscribe to connectivity changes. The block fires on the
    // monitor's queue; hop back into the actor before mutating state.
    let token = NetworkMonitor.shared.addObserver { [weak self] connected in
      guard connected else { return }
      Task { await self?.processQueue() }
    }
    monitorToken = token
  }

  // MARK: - Public API

  /// Append an already-parsed intent to the queue and persist.
  /// Caller is expected to have already confirmed the error is queueable
  /// (e.g. via `QueueableErrorClassifier.isQueueable`) — this method
  /// trusts the caller and just stores.
  public func enqueue(_ intent: ActionIntent, lastError: String? = nil) async {
    let item = QueuedAction(intent: intent, lastError: lastError)
    await store.append(item)
    pendingCount += 1
    queueLogger.info("ActionQueueManager: enqueued action for \(intent.targetIntegration.rawValue, privacy: .public) (pending: \(self.pendingCount, privacy: .public))")

    if NetworkMonitor.shared.isConnected {
      Task { await self.processQueue() }
    }
  }

  /// Append a raw transcript to be parsed-then-executed when the device
  /// is back online. Used when the LLM parsing call itself failed
  /// (typical case: device was offline before the user even tapped the
  /// Action FAB, or LLM provider was unreachable).
  public func enqueueTranscript(_ transcript: String, provider: AIProvider, lastError: String? = nil) async {
    let item = QueuedAction(
      payload: .pendingParse(transcript: transcript, provider: provider),
      lastError: lastError
    )
    await store.append(item)
    pendingCount += 1
    queueLogger.info("ActionQueueManager: enqueued raw transcript (\(transcript.count, privacy: .public) chars, provider: \(provider.rawValue, privacy: .public)) (pending: \(self.pendingCount, privacy: .public))")

    if NetworkMonitor.shared.isConnected {
      Task { await self.processQueue() }
    }
  }

  /// Manually trigger a processing pass (e.g. from a "Retry now" button
  /// in Settings). Safe to call when offline — short-circuits.
  public func retryNow() async {
    await processQueue()
  }

  /// Snapshot of the queue for UI surfaces. Returns a fresh load each
  /// time so it reflects on-disk state.
  public func snapshot() async -> [QueuedAction] {
    await store.loadAll()
  }

  /// Remove a specific item — e.g. user dismissed it from a "failed"
  /// list. Decrements `pendingCount` to match.
  public func discard(id: UUID) async {
    await store.remove(id: id)
    if pendingCount > 0 { pendingCount -= 1 }
  }

  // MARK: - Processing

  private func processQueue() async {
    guard let executor else {
      queueLogger.debug("ActionQueueManager: process skipped — no executor installed")
      return
    }
    guard !isProcessing else { return }
    guard NetworkMonitor.shared.isConnected else { return }

    isProcessing = true
    defer { isProcessing = false }

    let items = await store.loadAll()
    guard !items.isEmpty else { return }

    queueLogger.info("ActionQueueManager: processing \(items.count, privacy: .public) queued action(s)")

    for var item in items where !item.isExhausted {
      // Backoff window from the previous failure — skip this pass if
      // we're still inside it. The next reconnect / retryNow will
      // re-evaluate.
      if let lastAttempt = item.lastAttemptAt {
        let nextEligibleAt = lastAttempt.addingTimeInterval(
          retryPolicy.delay(forAttempt: item.retryCount - 1)
        )
        if Date() < nextEligibleAt { continue }
      }

      do {
        // Promote pendingParse → ready before executing. The promotion
        // is persisted so a successful parse followed by a failed
        // execute doesn't re-incur the parse on the next pass.
        if case let .pendingParse(transcript, provider) = item.payload {
          guard let parser else {
            queueLogger.error("ActionQueueManager: pendingParse item but no parser installed; skipping")
            continue
          }
          let parsed = try await parser.parse(transcript: transcript, provider: provider)
          item.payload = .ready(parsed)
          await store.update(item)
          queueLogger.info("ActionQueueManager: promoted transcript to action for \(parsed.targetIntegration.rawValue, privacy: .public)")
        }

        // At this point payload is .ready. Execute it.
        guard case let .ready(intent) = item.payload else { continue }
        try await executor.execute(intent)
        await store.remove(id: item.id)
        if pendingCount > 0 { pendingCount -= 1 }
        queueLogger.info("ActionQueueManager: replayed action for \(intent.targetIntegration.rawValue, privacy: .public)")
      } catch {
        item.retryCount += 1
        item.lastAttemptAt = Date()
        item.lastError = error.localizedDescription
        await store.update(item)
        let label: String = {
          switch item.payload {
          case .ready(let intent): return intent.targetIntegration.rawValue
          case .pendingParse: return "pendingParse"
          }
        }()
        queueLogger.error("ActionQueueManager: retry \(item.retryCount, privacy: .public)/\(QueuedAction.defaultMaxRetries, privacy: .public) failed for \(label, privacy: .public): \(error.localizedDescription, privacy: .public)")
      }
    }
  }
}
