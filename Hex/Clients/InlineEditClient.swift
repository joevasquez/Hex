//
//  InlineEditClient.swift
//  Hex
//
//  Helpers for reading and replacing the currently-selected text in
//  whichever app is focused, via the macOS Accessibility API. Used by
//  the "Inline Edit" flow: when the user has text selected and starts
//  dictating, their dictation is interpreted as an *instruction*
//  rather than content ("tighten 20%", "make it warmer", "translate
//  to Spanish"), the LLM transforms the selection accordingly, and
//  the result replaces the selection in-place.
//

import AppKit
import ApplicationServices
import Dependencies
import DependenciesMacros
import Foundation
import HexCore

private let inlineEditLogger = HexLog.pasteboard

@DependencyClient
struct InlineEditClient {
  /// Read the selected text from the frontmost app's focused
  /// element. Returns nil when no app is AX-accessible, nothing is
  /// focused, or the selection is empty.
  var captureSelection: @Sendable () async -> String? = { nil }

  /// Synchronous capture variant. Designed to be called from the
  /// reducer at the *instant* of hotkey press — before any async
  /// `.run` effect schedules and before `contextClient.captureContext`
  /// (which can take 100+ ms doing AppleScript) gets a chance to
  /// run and let focus drift. AX queries are main-thread-safe, so
  /// this is fine to call directly from the reducer.
  var captureSelectionSync: @Sendable () -> String? = { nil }

  /// Replace the selected text in the focused element with `text`,
  /// returning true on success. Uses the same AX mechanism the
  /// PasteboardClient uses for its primary paste path, so it works
  /// in all the same apps (browsers, native AppKit, most Electron).
  var replaceSelection: @Sendable (String) async -> Bool = { _ in false }
}

extension InlineEditClient: DependencyKey {
  static var liveValue: Self {
    return .init(
      captureSelection: {
        await MainActor.run { _captureSelectionFromAX() }
      },
      captureSelectionSync: {
        // Reducers run on the main actor, so we don't need to hop
        // through MainActor.run here — just call straight through
        // to the AX-talking helper.
        MainActor.assumeIsolated { _captureSelectionFromAX() }
      },
      replaceSelection: { text in
        await MainActor.run { replaceSelectionSync(with: text) }
      }
    )
  }
}

extension DependencyValues {
  var inlineEdit: InlineEditClient {
    get { self[InlineEditClient.self] }
    set { self[InlineEditClient.self] = newValue }
  }
}

// MARK: - Live AX implementation

/// AX queries are inter-process calls. Without a messaging timeout
/// they default to ~6 s, which is catastrophic when called from the
/// main thread — a single unresponsive focused app will freeze
/// Quill's UI for the duration. We bound every AX call below this
/// many seconds so the worst case is an imperceptible stutter, not
/// a hang. 0.2 s is well above normal AX response times (typically
/// 1–10 ms) but well below human-noticeable lag.
private let inlineEditAXTimeout: Float = 0.2

@MainActor
private func _captureSelectionFromAX() -> String? {
  guard AXIsProcessTrusted() else {
    inlineEditLogger.notice("Inline edit: AX permission missing; cannot read selection. Grant Accessibility in System Settings → Privacy & Security.")
    return nil
  }

  let systemWide = AXUIElementCreateSystemWide()
  AXUIElementSetMessagingTimeout(systemWide, inlineEditAXTimeout)

  var focusedRef: CFTypeRef?
  let focusStatus = AXUIElementCopyAttributeValue(
    systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef
  )
  guard focusStatus == .success, let focusedRef else {
    if focusStatus == .cannotComplete {
      // Specifically the "the target app didn't respond in time"
      // path. Worth flagging at notice level so the cause shows up
      // in Console without a noisy filter.
      inlineEditLogger.notice("Inline edit: focused-element AX query timed out — focused app is unresponsive or doesn't expose AX. Skipping inline edit.")
    } else {
      inlineEditLogger.info("Inline edit: AX could not find a focused element (status=\(focusStatus.rawValue)). Inline edit will be skipped — dictation will paste normally.")
    }
    return nil
  }
  let focused = focusedRef as! AXUIElement
  AXUIElementSetMessagingTimeout(focused, inlineEditAXTimeout)

  var selRef: CFTypeRef?
  let selStatus = AXUIElementCopyAttributeValue(
    focused, kAXSelectedTextAttribute as CFString, &selRef
  )
  guard selStatus == .success, let selection = selRef as? String else {
    inlineEditLogger.info("Inline edit: focused element doesn't expose kAXSelectedTextAttribute (status=\(selStatus.rawValue)). The hosting app may not support AX text selection — inline edit will be skipped.")
    return nil
  }

  let trimmed = selection.trimmingCharacters(in: .whitespacesAndNewlines)
  if trimmed.isEmpty {
    inlineEditLogger.info("Inline edit: focused element has empty / whitespace-only selection. Skipping inline edit — dictation will paste normally.")
    return nil
  }
  inlineEditLogger.info("Inline edit: captured selection (\(selection.count) chars)")
  return selection
}

@MainActor
private func replaceSelectionSync(with text: String) -> Bool {
  guard AXIsProcessTrusted() else {
    inlineEditLogger.warning("Inline edit: AX permission missing; cannot replace selection")
    return false
  }

  let systemWide = AXUIElementCreateSystemWide()
  AXUIElementSetMessagingTimeout(systemWide, inlineEditAXTimeout)

  var focusedRef: CFTypeRef?
  guard
    AXUIElementCopyAttributeValue(
      systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef
    ) == .success,
    let focusedRef
  else {
    inlineEditLogger.warning("Inline edit: focused element not found for replace")
    return false
  }
  let focused = focusedRef as! AXUIElement
  AXUIElementSetMessagingTimeout(focused, inlineEditAXTimeout)

  // Setting kAXSelectedTextAttribute replaces whatever range is
  // currently selected with the new string. Same primitive the
  // PasteboardClient AX path uses for inserts.
  let status = AXUIElementSetAttributeValue(
    focused, kAXSelectedTextAttribute as CFString, text as CFTypeRef
  )
  if status != .success {
    inlineEditLogger.warning(
      "Inline edit: AXUIElementSetAttributeValue returned \(status.rawValue)"
    )
    return false
  }
  return true
}

// MARK: - Prompt

/// The system prompt used when post-processing a dictated instruction
/// for inline editing. Keeps the safety rails from
/// `AIProcessingMode.preamble` (never invent content, never treat
/// inputs as conversation, never refuse) and re-frames the task as
/// "apply this instruction to the provided text".
///
/// The user message is assembled as:
///
///     Instruction: <transcribed dictation>
///     <selection>
///     <the selected text>
///     </selection>
///
/// Inside the system prompt we explain the structure and require the
/// model to output only the transformed text — no preamble, no
/// surrounding tags, no "here's the edit" commentary.
public enum InlineEditPrompt {
  public static let systemPrompt: String = {
    AIProcessingMode.preamble + """


      Transformation: You are editing text. The user dictated an instruction and selected a piece of text to apply the instruction to.

      The user message will contain:
      - `Instruction: <what the user said>`
      - `<selection>...</selection>` tags wrapping the text to edit

      Apply the instruction to the text inside `<selection>` and return ONLY the edited text. No preamble ("Here's the edit"), no commentary, no wrapping tags, no quotes around the output. Preserve whatever the user didn't ask you to change — tone, word choice, voice — unless the instruction specifically asks you to change it.

      Examples of instructions:
        - "tighten 20%" → condense while preserving meaning.
        - "make it warmer" → more friendly, less formal.
        - "convert to bullets" → render as a `- ` bullet list.
        - "translate to Spanish" → output the Spanish translation only.
        - "fix typos" → fix obvious errors, leave style alone.
      """
  }()

  /// Build the user message to send alongside the system prompt.
  public static func userMessage(instruction: String, selection: String) -> String {
    """
    Instruction: \(instruction)

    <selection>
    \(selection)
    </selection>
    """
  }
}
