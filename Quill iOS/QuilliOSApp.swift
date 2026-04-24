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

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environmentObject(deepLinkRouter)
        .onOpenURL { url in
          deepLinkRouter.handle(url)
        }
    }
  }
}
