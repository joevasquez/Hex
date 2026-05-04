//
//  ErrorMonitoringService.swift
//  HexCore
//
//  Protocol-based error monitoring shared by macOS and iOS targets. The
//  protocol + types live here in HexCore so any module (clients, features,
//  views) can capture errors without importing platform-specific SDKs. Live
//  provider implementations (e.g. SentryErrorMonitoring) live in the app
//  targets and inject themselves via `ErrorMonitoring.installLiveService`.
//
//  Privacy posture: opt-in. The default service is `NoOpErrorMonitoring` —
//  even after a live service is installed, it should gate on the
//  `quill.crashReportingEnabled` UserDefaults flag (see
//  `ErrorMonitoringSettings.crashReportingEnabledKey`).
//

import Foundation

/// Protocol for error monitoring services.
///
/// Implementations should be thread-safe — capture/breadcrumb calls fire
/// from anywhere in the app and may interleave.
public protocol ErrorMonitoringService: Sendable {
  /// Configure the service. Called once at app launch and again whenever
  /// the user toggles the opt-in flag (so the service can start/stop the
  /// underlying SDK).
  func configure()

  /// Capture an error with optional context.
  func captureError(_ error: Error, context: ErrorContext?)

  /// Capture a free-form message at a given severity.
  func captureMessage(_ message: String, level: ErrorLevel)

  /// Add a breadcrumb that contextualizes future errors.
  func addBreadcrumb(_ breadcrumb: Breadcrumb)

  /// Set the current user (anonymized — never PII).
  func setUser(_ user: MonitoringUser?)

  /// Clear user + session state (e.g. on sign-out).
  func reset()
}

public extension ErrorMonitoringService {
  func captureError(_ error: Error) {
    captureError(error, context: nil)
  }
}

// MARK: - Severity

public enum ErrorLevel: String, Sendable, CaseIterable {
  case debug
  case info
  case warning
  case error
  case fatal
}

// MARK: - Anonymized user

public struct MonitoringUser: Sendable, Equatable {
  /// Anonymized identifier — hash of the real ID, NEVER an email.
  public let id: String
  public let segment: String?

  public init(id: String, segment: String? = nil) {
    self.id = id
    self.segment = segment
  }
}

// MARK: - Settings keys

/// Shared UserDefaults keys for the opt-in flag, used by both Settings UIs
/// (macOS + iOS) and by the live provider to gate capture.
public enum ErrorMonitoringSettings {
  public static let crashReportingEnabledKey = "quill.crashReportingEnabled"

  /// Convenience read — returns false (the privacy-safe default) when the
  /// key has never been written.
  public static var isCrashReportingEnabled: Bool {
    UserDefaults.standard.bool(forKey: crashReportingEnabledKey)
  }
}

// MARK: - Central accessor

/// Single point of access for the active error monitoring service.
///
/// App targets call `installLiveService` once at launch (after creating
/// e.g. a `SentryErrorMonitoring` instance) and then every other call site
/// uses the free `captureError(_:context:)` / `addBreadcrumb(_:)` helpers
/// below. Pre-installation (and in tests) the service is `NoOpErrorMonitoring`.
public enum ErrorMonitoring {
  /// `nonisolated(unsafe)` because we set this exactly once at app launch
  /// before any capture call could fire. Reads from any thread are safe;
  /// the underlying `ErrorMonitoringService` conformance is `Sendable`.
  nonisolated(unsafe) public private(set) static var service: ErrorMonitoringService = NoOpErrorMonitoring()

  /// Called once during app launch with the platform's chosen live
  /// implementation (e.g. `SentryErrorMonitoring()`).
  public static func installLiveService(_ service: ErrorMonitoringService) {
    Self.service = service
  }

  /// Calls `configure()` on the active service. Safe to call multiple
  /// times — providers that gate on the opt-in flag should re-check on
  /// each call so toggling the flag in Settings takes effect immediately.
  public static func configure() {
    service.configure()
  }
}

// MARK: - Free capture helpers

/// Capture an error from anywhere in the app without ceremony.
public func captureError(_ error: Error, context: ErrorContext? = nil) {
  ErrorMonitoring.service.captureError(error, context: context)
}

/// Capture a free-form message.
public func captureMessage(_ message: String, level: ErrorLevel = .info) {
  ErrorMonitoring.service.captureMessage(message, level: level)
}

/// Add a breadcrumb.
public func addBreadcrumb(_ breadcrumb: Breadcrumb) {
  ErrorMonitoring.service.addBreadcrumb(breadcrumb)
}
