//
//  QuilliOSApp.swift
//  Quill (iOS)
//
//  Created by Joe Vasquez.
//

import HexCore
import SwiftUI

@main
struct QuilliOSApp: App {
  /// Published signal the root `ContentView` observes to know when a
  /// `quill://` deep link has arrived — currently fired by the home-
  /// screen widget to request "start recording immediately" or "open
  /// the notes list". See `QuillDeepLink` for the routing table.
  @StateObject private var deepLinkRouter = QuillDeepLinkRouter()

  @AppStorage(QuillIOSSettingsKey.hasCompletedOnboarding)
  private var hasCompletedOnboarding: Bool = false

  init() {
    // Install Sentry-backed error monitoring up front so launch-time
    // crashes get captured (it stays inert until the user opts in via
    // Settings → Privacy → Send anonymous crash reports).
    ErrorMonitoring.installLiveService(SentryErrorMonitoring())
    ErrorMonitoring.configure()
    // Install the offline action queue executor + parser so any actions
    // queued by ActionConfirmationViewModel (post-parse adapter failure)
    // OR by RecordingViewModel.stopAndParseAction (pre-parse network
    // failure) are retried automatically when connectivity returns.
    Task {
      await ActionQueueManager.shared.install(
        executor: IOSSystemActionQueueExecutor(),
        parser: IOSActionQueueParser()
      )
    }
    // Backfill `IntegrationConnectionStore` from OAuth state. Users who
    // signed in to Google before the store was being updated have valid
    // keychain tokens but no `.gmail`/`.googleCalendar` entries in the
    // store, which leaves them invisible in the Action confirmation
    // dropdown until they re-sign-in. This one-time sync repairs them.
    Self.syncGoogleIntegrationsFromOAuth()
  }

  /// Reflect the OAuth-authorized state of Google into the integration
  /// connection set. Idempotent — a no-op when the store is already in
  /// sync. Runs on every launch (cheap), not just first launch.
  @MainActor
  private static func syncGoogleIntegrationsFromOAuth() {
    let key = IntegrationConnectionStore.userDefaultsKey
    let raw = UserDefaults.standard.data(forKey: key)
    var current = IntegrationConnectionStore.decode(raw)
    let authorized = IOSGoogleOAuthClient.isAuthorized()

    if authorized {
      let needsInsert = !current.contains(.gmail) || !current.contains(.googleCalendar)
      guard needsInsert else { return }
      current.insert(.gmail)
      current.insert(.googleCalendar)
      UserDefaults.standard.set(IntegrationConnectionStore.encode(current), forKey: key)
    } else {
      // OAuth tokens were cleared (e.g. user revoked access via
      // accounts.google.com). Clean the store to match so the rows
      // don't lie.
      let needsRemove = current.contains(.gmail) || current.contains(.googleCalendar)
      guard needsRemove else { return }
      current.remove(.gmail)
      current.remove(.googleCalendar)
      UserDefaults.standard.set(IntegrationConnectionStore.encode(current), forKey: key)
    }
  }

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environmentObject(deepLinkRouter)
        .onOpenURL { url in
          deepLinkRouter.handle(url)
        }
        // First-launch walk-through. Modal full-screen so the user
        // can't tap around the main UI before granting at least
        // microphone permission. The bound flag flips to true once
        // they finish or skip-through; resetting it (Settings →
        // Productivity → Replay Tutorial) re-enters the flow.
        .fullScreenCover(isPresented: Binding(
          get: { !hasCompletedOnboarding },
          set: { newValue in hasCompletedOnboarding = !newValue }
        )) {
          OnboardingView(hasCompletedOnboarding: $hasCompletedOnboarding)
        }
    }
  }
}
