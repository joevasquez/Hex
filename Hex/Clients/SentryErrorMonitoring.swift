//
//  SentryErrorMonitoring.swift
//  Quill
//
//  Live ErrorMonitoringService backed by Sentry-Cocoa. Compiles on both
//  macOS and iOS targets — the iOS target picks it up via the
//  `membershipExceptions` list in `Hex.xcodeproj/project.pbxproj`.
//
//  Build behaviour:
//  - If the `Sentry` SPM dependency is not yet added, all Sentry calls are
//    elided via `#if canImport(Sentry)` and this class behaves like NoOp.
//    The adapter still installs itself, so adding the SDK later starts
//    capturing without code changes.
//  - When the Sentry SDK is present, capture only fires after BOTH:
//    1. The user has opted in via Settings → "Send anonymous crash reports"
//       (UserDefaults flag `quill.crashReportingEnabled`)
//    2. `configure()` has been called (which itself gates on the same flag
//       to avoid initializing the SDK for opted-out users).
//
//  Privacy notes:
//  - Never includes transcript text, audio, notes, contacts, or API keys
//    in error reports. Capture sites should pass only generic context
//    (feature name, error type) via `ErrorContext`.
//  - User identifier is the bundle's vendor ID hash — anonymized.
//

#if canImport(Sentry)
import Sentry
#endif
import Foundation
import HexCore
import os

private let sentryLogger = HexLog.app

public final class SentryErrorMonitoring: ErrorMonitoringService, @unchecked Sendable {
  /// Replace with your DSN from Sentry → Settings → Projects → <project>
  /// → Client Keys (DSN). The DSN is a public client identifier — Sentry's
  /// own docs confirm it's safe to commit.
  private static let dsn = "YOUR_SENTRY_DSN_HERE"

  /// Sample 100% of error events for an indie app — volume is low enough
  /// that paying for full visibility is worthwhile.
  private static let sampleRate: Float = 1.0

  /// Track the SDK lifecycle so toggling the opt-in flag at runtime
  /// (Settings → Send anonymous crash reports) starts/stops cleanly
  /// without re-initializing on every capture.
  private var isStarted = false

  public init() {}

  // MARK: - Configuration

  public func configure() {
    let optedIn = ErrorMonitoringSettings.isCrashReportingEnabled

    if !optedIn {
      // Toggled off (or never opted in) — make sure the SDK is shut down
      // if we ever started it. `SentrySDK.close()` is a no-op if not
      // started, so this is safe on first launch.
      #if canImport(Sentry)
      if isStarted {
        SentrySDK.close()
        isStarted = false
        sentryLogger.info("Sentry SDK stopped (opt-in flag is off)")
      }
      #endif
      return
    }

    guard !isStarted else { return }

    #if canImport(Sentry)
    SentrySDK.start { options in
      options.dsn = Self.dsn
      options.sampleRate = NSNumber(value: Self.sampleRate)
      options.releaseName = Self.releaseName

      // Performance tracing off by default — we don't have a server to
      // worry about and per-frame perf signal isn't worth the overhead.
      options.tracesSampleRate = 0.0

      #if DEBUG
      options.environment = "debug"
      options.debug = true
      #else
      options.environment = "release"
      options.debug = false
      #endif

      // Don't auto-attach screenshots / view hierarchies — those would
      // capture transcript text and notes content.
      options.attachScreenshot = false
      options.attachViewHierarchy = false
    }
    isStarted = true
    sentryLogger.info("Sentry SDK started (release: \(Self.releaseName, privacy: .public))")
    #else
    sentryLogger.info("Sentry SDK not linked; SentryErrorMonitoring acting as NoOp")
    #endif
  }

  // MARK: - Capture

  public func captureError(_ error: Error, context: ErrorContext?) {
    guard isStarted else { return }
    #if canImport(Sentry)
    SentrySDK.capture(error: error) { scope in
      Self.apply(context: context, to: scope)
    }
    #endif
  }

  public func captureMessage(_ message: String, level: ErrorLevel) {
    guard isStarted else { return }
    #if canImport(Sentry)
    SentrySDK.capture(message: message) { scope in
      scope.setLevel(level.sentryLevel)
    }
    #endif
  }

  public func addBreadcrumb(_ breadcrumb: Breadcrumb) {
    guard isStarted else { return }
    #if canImport(Sentry)
    let crumb = Sentry.Breadcrumb()
    crumb.category = breadcrumb.category
    crumb.message = breadcrumb.message
    crumb.level = breadcrumb.level.sentryLevel
    crumb.timestamp = breadcrumb.timestamp
    if let data = breadcrumb.data {
      crumb.data = data
    }
    SentrySDK.addBreadcrumb(crumb)
    #endif
  }

  public func setUser(_ user: MonitoringUser?) {
    guard isStarted else { return }
    #if canImport(Sentry)
    if let user {
      let sentryUser = Sentry.User()
      sentryUser.userId = user.id
      if let segment = user.segment {
        sentryUser.data = ["segment": segment]
      }
      SentrySDK.setUser(sentryUser)
    } else {
      SentrySDK.setUser(nil)
    }
    #endif
  }

  public func reset() {
    guard isStarted else { return }
    #if canImport(Sentry)
    SentrySDK.setUser(nil)
    SentrySDK.configureScope { scope in
      scope.clear()
    }
    #endif
  }

  // MARK: - Helpers

  private static var releaseName: String {
    let bundle = Bundle.main
    let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    let build = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    let identifier = bundle.bundleIdentifier ?? "com.joevasquez.Quill"
    return "\(identifier)@\(version)+\(build)"
  }

  #if canImport(Sentry)
  private static func apply(context: ErrorContext?, to scope: Scope) {
    guard let context else { return }
    for (key, value) in context.tags {
      scope.setTag(value: value, key: key)
    }
    for (key, value) in context.extra {
      scope.setExtra(value: value, key: key)
    }
  }
  #endif
}

// MARK: - Level mapping

#if canImport(Sentry)
private extension ErrorLevel {
  var sentryLevel: SentryLevel {
    switch self {
    case .debug: .debug
    case .info: .info
    case .warning: .warning
    case .error: .error
    case .fatal: .fatal
    }
  }
}
#endif
