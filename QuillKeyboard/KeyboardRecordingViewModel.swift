//
//  KeyboardRecordingViewModel.swift
//  QuillKeyboard
//
//  iOS keyboard extensions are non-focal processes and the OS denies them
//  audio input access regardless of Full Access / mic / speech permissions
//  (CoreAudio surfaces this as 'what' / 2003329396 from AURemoteIO_StartIO,
//  or as `record()` returning false from AVAudioRecorder). Both AVAudioEngine
//  and AVAudioRecorder hit the same wall.
//
//  Workaround: the keyboard never records audio. When the user taps Dictate,
//  the keyboard:
//    1. Writes a `KeyboardBridge.Request` to the App Group mailbox.
//    2. Opens the parent Quill app via the `quill://keyboard?id=…&mode=…`
//       deep link.
//    3. Stays dormant. The parent app (a focal process) records, transcribes,
//       and writes a `KeyboardBridge.Result` back to the App Group.
//    4. On every reappearance — `checkForBridgeResult()` is called from the
//       input view controller's `viewWillAppear` and `textDidChange` — the
//       keyboard reads the pending result, validates the request id matches,
//       inserts the transcript at the cursor, and clears the mailbox.
//
//  This is the same pattern Gboard / SwiftKey use for voice typing.
//

import AVFoundation
import Combine
import Foundation
import Speech
import UIKit

@MainActor
final class KeyboardRecordingViewModel: ObservableObject {
  enum Phase: Equatable {
    case idle
    /// User tapped Dictate; we've opened the parent app and are waiting
    /// for them to return. Reused as a "still expecting a result" state
    /// across keyboard reappearances until either a result lands or the
    /// user dismisses the request.
    case awaitingApp
    case enhancing
    case actionDone(title: String)
    case error(String)
  }

  enum Mode: String, CaseIterable {
    case dictate
    case action
  }

  @Published var phase: Phase = .idle
  @Published var mode: Mode = .dictate
  @Published var partialTranscript: String = ""
  @Published var meterLevel: Float = 0
  /// Persisted to App Group UserDefaults so the toggle survives the
  /// frequent keyboard-process restarts iOS does when the user switches
  /// apps. Without persistence, every Dictate flow that round-trips
  /// through the parent app starts with Enhance off, which silently
  /// strips the LLM cleanup users expect.
  @Published var enhanceEnabled: Bool {
    didSet {
      UserDefaults(suiteName: KeyboardBridge.appGroup)?
        .set(enhanceEnabled, forKey: Self.enhanceToggleKey)
    }
  }
  private static let enhanceToggleKey = "quill.keyboard.enhanceEnabled"

  init() {
    self.enhanceEnabled = UserDefaults(suiteName: KeyboardBridge.appGroup)?
      .bool(forKey: Self.enhanceToggleKey) ?? false
  }
  @Published private(set) var hostContextBefore: String = ""
  @Published private(set) var hostContextAfter: String = ""
  @Published private(set) var hasOpenAccess: Bool = false

  private weak var proxy: (any UITextDocumentProxy)?
  private var advanceKeyboardCallback: (() -> Void)?
  private var dismissKeyboardCallback: (() -> Void)?
  /// Opens a URL via the input view controller's `extensionContext`.
  /// Provided by `QuillKeyboardController` in `bind`. The closure returns
  /// `true` if the URL was successfully scheduled for opening.
  private var openURLCallback: ((URL) -> Void)?

  /// Outstanding bridge request id, persisted to App Group UserDefaults
  /// so it survives keyboard-extension process restarts (which iOS does
  /// freely whenever the user switches apps). Without persistence, a
  /// restart wipes the id, the keyboard can't validate incoming results,
  /// and stale or duplicate results in the mailbox replay as if they
  /// were new dictations.
  private static let outstandingIDKey = "quill.keyboard.outstandingRequestID"
  private var outstandingRequestID: UUID? {
    get {
      guard let raw = UserDefaults(suiteName: KeyboardBridge.appGroup)?
        .string(forKey: Self.outstandingIDKey) else { return nil }
      return UUID(uuidString: raw)
    }
    set {
      let defaults = UserDefaults(suiteName: KeyboardBridge.appGroup)
      if let id = newValue {
        defaults?.set(id.uuidString, forKey: Self.outstandingIDKey)
      } else {
        defaults?.removeObject(forKey: Self.outstandingIDKey)
      }
    }
  }

  // MARK: - Wiring

  func bind(
    proxy: any UITextDocumentProxy,
    advanceToNextKeyboard: @escaping () -> Void,
    dismissKeyboard: @escaping () -> Void,
    openURL: @escaping (URL) -> Void
  ) {
    self.proxy = proxy
    self.advanceKeyboardCallback = advanceToNextKeyboard
    self.dismissKeyboardCallback = dismissKeyboard
    self.openURLCallback = openURL
    refreshHostContext()
    refreshOpenAccess()
  }

  func refreshHostContext() {
    hostContextBefore = proxy?.documentContextBeforeInput ?? ""
    hostContextAfter = proxy?.documentContextAfterInput ?? ""
  }

  private func refreshOpenAccess() {
    hasOpenAccess = UIPasteboard.general.hasStrings
      || !(UserDefaults(suiteName: KeyboardBridge.appGroup)?.dictionaryRepresentation().isEmpty ?? true)
  }

  // MARK: - Standard keyboard actions

  func tapBackspace() { proxy?.deleteBackward() }
  func tapReturn() { proxy?.insertText("\n") }
  func tapSpace() { proxy?.insertText(" ") }
  func tapNextKeyboard() { advanceKeyboardCallback?() }
  func tapDismissKeyboard() { dismissKeyboardCallback?() }

  // MARK: - Dictation (delegated to parent app)

  func toggleRecording() async {
    switch phase {
    case .awaitingApp:
      // Second tap while waiting cancels the outstanding request.
      cancelIfNeeded()
    case .idle, .error, .actionDone:
      triggerHostRecording()
    case .enhancing:
      break
    }
  }

  func toggleMode() {
    cancelIfNeeded()
    mode = mode == .dictate ? .action : .dictate
  }

  func cancelIfNeeded() {
    if phase == .awaitingApp {
      // Clear the outstanding request from the App Group so the parent
      // app doesn't process a request the user no longer wants.
      _ = KeyboardBridge.consumeRequest()
      _ = KeyboardBridge.consumeResult()
      outstandingRequestID = nil
      partialTranscript = ""
      phase = .idle
    }
  }

  /// Writes a bridge request and asks the input view controller to open
  /// the parent Quill app. The app reads the request, records as a
  /// focal process, and writes the result back. We pick it up the next
  /// time the keyboard reappears (see `checkForBridgeResult`).
  ///
  /// Note: an earlier iteration tried `AudioQueueServices` directly here
  /// to see whether it bypassed the CoreAudio sandbox wall that breaks
  /// AVAudioEngine and AVAudioRecorder. It also failed — it generated a
  /// UserFault report (`ExcUserFault_QuillKeyboard.ips`) instead of a
  /// recoverable OSStatus error, which means iOS denies non-focal
  /// extension processes audio input at the kernel level. The trampoline
  /// is the only viable architecture.
  private func triggerHostRecording() {
    let bridgeMode: KeyboardBridge.Mode = mode == .dictate ? .dictate : .action
    let request = KeyboardBridge.Request(mode: bridgeMode)
    KeyboardBridge.writeRequest(request)
    outstandingRequestID = request.id

    guard let url = KeyboardBridge.url(for: request) else {
      phase = .error("Couldn't open Quill app.")
      return
    }
    openURLCallback?(url)
    phase = .awaitingApp
    partialTranscript = ""
  }

  /// Called by the input view controller when the keyboard becomes
  /// visible or the host text changes. Reads the bridge mailbox and,
  /// if a result for our outstanding request is there, inserts it.
  func checkForBridgeResult() {
    guard let result = KeyboardBridge.consumeResult() else { return }
    let age = Date().timeIntervalSince(result.createdAt)
    if age > 300 {
      NSLog("[QuillKeyboard] dropping stale bridge result (age=%.0fs)", age)
      return
    }
    // Validate the result corresponds to OUR outstanding request. Any
    // mismatch — including no outstanding id at all — means the result
    // is from a previous flow we already handled (or one the user
    // cancelled). Replaying it would surface as the "previous transcript
    // pasted again" bug.
    guard let outstanding = outstandingRequestID, result.id == outstanding else {
      NSLog("[QuillKeyboard] dropping result with mismatched id (have=%@ outstanding=%@)",
            result.id.uuidString,
            outstandingRequestID?.uuidString ?? "nil")
      return
    }
    NSLog("[QuillKeyboard] consumed bridge result: %ld chars", result.transcript.count)
    outstandingRequestID = nil

    let trimmed = result.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      // Action mode returns an empty transcript on success — the app
      // already created the reminder/task. Show a brief confirmation.
      if mode == .action {
        phase = .actionDone(title: "Action created")
        Task { @MainActor in
          try? await Task.sleep(for: .milliseconds(1600))
          if case .actionDone = phase { phase = .idle }
        }
      } else {
        phase = .idle
      }
      return
    }

    // Dictate mode (or action fallback): commit the text. Optionally
    // run AI Enhance first.
    Task { @MainActor in
      await commitDictate(transcript: trimmed)
    }
  }

  private func commitDictate(transcript: String) async {
    let toInsert: String
    if enhanceEnabled, hasOpenAccess {
      phase = .enhancing
      refreshHostContext()
      toInsert = await enhanceWithAI(transcript: transcript) ?? transcript
    } else {
      toInsert = transcript
    }
    insertIntoHost(toInsert)
    phase = .idle
    partialTranscript = ""
  }

  private func insertIntoHost(_ text: String) {
    guard let proxy else { return }
    let before = proxy.documentContextBeforeInput ?? ""
    let needsLeadingSpace = !before.isEmpty
      && !before.hasSuffix(" ")
      && !before.hasSuffix("\n")
    let payload = (needsLeadingSpace ? " " : "") + text
    proxy.insertText(payload)
  }

  // MARK: - AI Enhance (Open Access required)

  private func enhanceWithAI(transcript: String) async -> String? {
    guard let request = AIEnhanceRequest.build(
      transcript: transcript,
      contextBefore: hostContextBefore,
      contextAfter: hostContextAfter
    ) else {
      return nil
    }
    do {
      return try await AIEnhanceClient.shared.send(request)
    } catch {
      NSLog("[QuillKeyboard] enhance failed: %@", error as NSError)
      return nil
    }
  }
}

enum KeyboardError: LocalizedError {
  case bridgeOpenFailed

  var errorDescription: String? {
    switch self {
    case .bridgeOpenFailed: "Couldn't open the Quill app."
    }
  }
}
