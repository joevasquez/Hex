//
//  QuillDeepLinkRouter.swift
//  Quill (iOS)
//
//  Tiny publisher for `quill://` URLs arriving from the home-screen
//  widget (or any other deep-link source — shortcuts, share
//  extensions, etc.). Parses the URL into a `QuillDeepLink` enum and
//  publishes it on `pendingLink`; `ContentView` observes and reacts
//  by, e.g., opening the record flow or showing the notes list.
//
//  URL scheme registered in `Info.plist` under `CFBundleURLTypes`:
//    quill://record  → start recording immediately
//    quill://notes   → present the notes list sheet
//

import Combine
import Foundation

enum QuillDeepLink: Equatable {
  case record
  case notes
  /// Keyboard extension is requesting a recording on its behalf.
  /// `id` round-trips through the result so the keyboard can verify
  /// the result corresponds to its outstanding request.
  case keyboardBridge(id: UUID, mode: KeyboardBridgeMode)
}

enum KeyboardBridgeMode: String {
  case dictate
  case action
}

@MainActor
final class QuillDeepLinkRouter: ObservableObject {
  /// Monotonically-increasing sequence of pending deep links. Using a
  /// sequence (rather than a single optional) means back-to-back
  /// widget taps don't deduplicate — the consumer sees each one.
  @Published var pendingLink: IdentifiedLink?

  struct IdentifiedLink: Equatable {
    let id: UUID
    let link: QuillDeepLink
  }

  func handle(_ url: URL) {
    guard url.scheme == "quill" else { return }
    let host = url.host(percentEncoded: false) ?? url.path.trimmingCharacters(in: .init(charactersIn: "/"))
    switch host.lowercased() {
    case "record":
      pendingLink = IdentifiedLink(id: UUID(), link: .record)
    case "notes":
      pendingLink = IdentifiedLink(id: UUID(), link: .notes)
    case "keyboard":
      let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
      let idString = items.first(where: { $0.name == "id" })?.value ?? ""
      let modeString = items.first(where: { $0.name == "mode" })?.value ?? "dictate"
      guard let id = UUID(uuidString: idString) else { return }
      let mode = KeyboardBridgeMode(rawValue: modeString) ?? .dictate
      pendingLink = IdentifiedLink(id: UUID(), link: .keyboardBridge(id: id, mode: mode))
    default:
      break
    }
  }

  func consume() {
    pendingLink = nil
  }
}
