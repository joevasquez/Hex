//
//  NetworkMonitor.swift
//  HexCore
//
//  Tiny NWPathMonitor wrapper. Two consumers:
//  - `ActionQueueManager` (registers an observer; processes the queue when
//    connectivity returns)
//  - UI surfaces that want to badge "you're offline" hints
//
//  Single shared instance because NWPathMonitor is a system-level resource
//  and there's no benefit to multiple monitors per process.
//

import Foundation
import Network
import os

private let netLogger = HexLog.app

public final class NetworkMonitor: @unchecked Sendable {
  public static let shared = NetworkMonitor()

  private let monitor: NWPathMonitor
  private let monitorQueue = DispatchQueue(
    label: "com.joevasquez.Quill.NetworkMonitor",
    qos: .utility
  )

  /// Lock guards `_isConnected` and `observers`. The pathUpdateHandler
  /// fires on `monitorQueue`; observers may register/deregister from any
  /// thread (typically the actor that owns them).
  private let lock = NSLock()
  private var _isConnected: Bool = true
  private var observers: [(UUID, @Sendable (Bool) -> Void)] = []

  public var isConnected: Bool {
    lock.lock(); defer { lock.unlock() }
    return _isConnected
  }

  private init() {
    monitor = NWPathMonitor()
    monitor.pathUpdateHandler = { [weak self] path in
      let connected = path.status == .satisfied
      self?.handlePathUpdate(connected: connected)
    }
    monitor.start(queue: monitorQueue)
  }

  /// Register an observer. Returns a token the caller can pass to
  /// `removeObserver(token:)`. The block is invoked off the main thread
  /// (on `monitorQueue`); hop to MainActor or your own actor as needed.
  @discardableResult
  public func addObserver(_ block: @escaping @Sendable (Bool) -> Void) -> UUID {
    let id = UUID()
    lock.lock()
    observers.append((id, block))
    let current = _isConnected
    lock.unlock()
    // Deliver the current state immediately so the caller doesn't have to
    // poll `isConnected` separately on registration.
    block(current)
    return id
  }

  public func removeObserver(token: UUID) {
    lock.lock(); defer { lock.unlock() }
    observers.removeAll { $0.0 == token }
  }

  private func handlePathUpdate(connected: Bool) {
    lock.lock()
    let changed = (connected != _isConnected)
    _isConnected = connected
    let snapshot = observers.map(\.1)
    lock.unlock()

    if changed {
      netLogger.info("Network connectivity changed → \(connected ? "online" : "offline", privacy: .public)")
    }
    for block in snapshot {
      block(connected)
    }
  }
}
