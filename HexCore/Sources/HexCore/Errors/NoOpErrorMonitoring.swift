//
//  NoOpErrorMonitoring.swift
//  HexCore
//
//  Default implementation used until an app target installs a live
//  provider, and used permanently when the user has opted out.
//
//  In DEBUG builds, captures are echoed to HexLog so developers can see
//  what would have been reported without a Sentry account. In RELEASE,
//  it's silent.
//

import Foundation

public final class NoOpErrorMonitoring: ErrorMonitoringService {
  public init() {}

  public func configure() {
    #if DEBUG
    HexLog.app.debug("[ErrorMonitoring] NoOp service configured")
    #endif
  }

  public func captureError(_ error: Error, context: ErrorContext?) {
    #if DEBUG
    if let context, !context.tags.isEmpty {
      HexLog.app.debug("[ErrorMonitoring] would-capture error tags=\(context.tags): \(error.localizedDescription)")
    } else {
      HexLog.app.debug("[ErrorMonitoring] would-capture error: \(error.localizedDescription)")
    }
    #endif
  }

  public func captureMessage(_ message: String, level: ErrorLevel) {
    #if DEBUG
    HexLog.app.debug("[ErrorMonitoring] would-capture \(level.rawValue): \(message)")
    #endif
  }

  public func addBreadcrumb(_ breadcrumb: Breadcrumb) {
    #if DEBUG
    HexLog.app.debug("[ErrorMonitoring] breadcrumb [\(breadcrumb.category)] \(breadcrumb.message)")
    #endif
  }

  public func setUser(_ user: MonitoringUser?) {
    #if DEBUG
    HexLog.app.debug("[ErrorMonitoring] would-set user: \(user?.id ?? "nil")")
    #endif
  }

  public func reset() {
    #if DEBUG
    HexLog.app.debug("[ErrorMonitoring] would-reset session")
    #endif
  }
}
