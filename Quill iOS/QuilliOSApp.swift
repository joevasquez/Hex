//
//  QuilliOSApp.swift
//  Quill (iOS)
//
//  Created by Joe Vasquez.
//

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
