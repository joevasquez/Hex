//
//  RetryPolicy.swift
//  HexCore
//
//  Exponential-backoff-with-jitter for the offline action queue.
//
//  The queue manager calls `delay(forAttempt:)` after each failed retry to
//  decide how long to wait before the next attempt. Jitter spreads
//  reconnection-storm load — if the device just came back online and ten
//  items are pending, we don't want them all to retry at exactly the same
//  millisecond and pile pressure on a freshly-recovered upstream.
//

import Foundation

public struct RetryPolicy: Sendable {
  /// Wait time after the first failure (e.g. 2.0s).
  public let baseDelay: TimeInterval
  /// Hard cap on wait time, regardless of attempt count.
  public let maxDelay: TimeInterval
  /// Multiplier between attempts (2.0 = doubles each time).
  public let multiplier: Double

  public init(
    baseDelay: TimeInterval = 2.0,
    maxDelay: TimeInterval = 60.0,
    multiplier: Double = 2.0
  ) {
    self.baseDelay = baseDelay
    self.maxDelay = maxDelay
    self.multiplier = multiplier
  }

  /// Default policy — 2s, 4s, 8s, 16s, 32s, then capped at 60s. With
  /// `QueuedAction.defaultMaxRetries = 5`, the longest a stuck item
  /// blocks the queue is ~62s in the worst case.
  public static let `default` = RetryPolicy()

  /// Compute the delay before the next retry attempt.
  ///
  /// - Parameter attempt: zero-indexed retry count. Pass `retryCount`
  ///   from the QueuedAction; the first failure has attempt = 0.
  public func delay(forAttempt attempt: Int) -> TimeInterval {
    let exponential = baseDelay * pow(multiplier, Double(max(0, attempt)))
    let bounded = min(exponential, maxDelay)
    // Jitter ±25% — enough to spread retries, not so much that the user-
    // perceptible "saved offline" delay swings wildly.
    let jitter = Double.random(in: 0.75...1.25)
    return bounded * jitter
  }
}
