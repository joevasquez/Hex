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

  /// Clipboard-based selection capture fallback. Simulates Cmd+C,
  /// reads the copied text from the pasteboard, then restores the
  /// original clipboard contents. Used when AX-based selection
  /// reading returns nil — common in Chrome, Electron apps (Slack,
  /// VS Code, Discord), and apps with non-standard text controls.
  ///
  /// This is the same approach used by Raycast, Rewind, and most
  /// "AI text actions" apps. AX selection reading is too inconsistent
  /// across the macOS app ecosystem to rely on as the sole path.
  var captureSelectionViaClipboard: @Sendable () async -> String? = { nil }

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
      captureSelectionViaClipboard: {
        await clipboardFallbackCapture()
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

/// AX queries are inter-process calls. Timeouts prevent hangs when
/// the target app is unresponsive. 0.5 s covers slow renderers like
/// Chrome while staying below human-noticeable lag.
private let inlineEditAXTimeout: Float = 0.5

/// Whether AX permission has been granted. Cached so we only log
/// the missing-permission warning once per launch.
@MainActor
private var _axPermissionWarned = false

@MainActor
private func _captureSelectionFromAX() -> String? {
  guard AXIsProcessTrusted() else {
    if !_axPermissionWarned {
      _axPermissionWarned = true
      inlineEditLogger.error(
        "Inline edit: Accessibility permission NOT granted. Edit mode cannot read text selections. Grant permission in System Settings → Privacy & Security → Accessibility."
      )
    }
    return nil
  }

  // ── Strategy: query the frontmost app's AX element directly ──
  // Using the app-specific element (vs AXUIElementCreateSystemWide)
  // is more reliable for apps like Chrome that have a deep AX tree.
  guard let frontApp = NSWorkspace.shared.frontmostApplication else {
    inlineEditLogger.info("Inline edit: no frontmost application — skipping")
    return nil
  }

  // Don't try to read a selection from ourselves.
  let quillBundles: Set<String> = ["com.joevasquez.Quill", "com.joevasquez.Quill.debug"]
  if let bid = frontApp.bundleIdentifier, quillBundles.contains(bid) {
    inlineEditLogger.info("Inline edit: Quill is frontmost — no useful selection to capture")
    return nil
  }

  let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)
  AXUIElementSetMessagingTimeout(appElement, inlineEditAXTimeout)

  // Get the focused UI element within the frontmost app.
  var focusedRef: CFTypeRef?
  let focusStatus = AXUIElementCopyAttributeValue(
    appElement, kAXFocusedUIElementAttribute as CFString, &focusedRef
  )

  // Fallback: if app-specific query fails, try system-wide.
  if focusStatus != .success || focusedRef == nil {
    let systemWide = AXUIElementCreateSystemWide()
    AXUIElementSetMessagingTimeout(systemWide, inlineEditAXTimeout)
    let swStatus = AXUIElementCopyAttributeValue(
      systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef
    )
    if swStatus != .success || focusedRef == nil {
      let appName = frontApp.localizedName ?? "unknown"
      inlineEditLogger.notice(
        "Inline edit: could not find focused element in \(appName, privacy: .public) (app status=\(focusStatus.rawValue), system status=\(swStatus.rawValue))"
      )
      return nil
    }
  }

  let focused = focusedRef as! AXUIElement
  AXUIElementSetMessagingTimeout(focused, inlineEditAXTimeout)

  // Read the selected text attribute.
  var selRef: CFTypeRef?
  let selStatus = AXUIElementCopyAttributeValue(
    focused, kAXSelectedTextAttribute as CFString, &selRef
  )
  guard selStatus == .success, let selection = selRef as? String else {
    let appName = frontApp.localizedName ?? "unknown"
    inlineEditLogger.notice(
      "Inline edit: \(appName, privacy: .public) doesn't expose kAXSelectedTextAttribute (status=\(selStatus.rawValue)). Text selection may not be supported."
    )
    return nil
  }

  let trimmed = selection.trimmingCharacters(in: .whitespacesAndNewlines)
  if trimmed.isEmpty {
    inlineEditLogger.info("Inline edit: selection is empty / whitespace-only — skipping")
    return nil
  }
  let appName = frontApp.localizedName ?? "unknown"
  inlineEditLogger.info(
    "Inline edit: captured \(selection.count) chars from \(appName, privacy: .public)"
  )
  return selection
}

// MARK: - Clipboard fallback implementation

/// Captures the selected text by simulating Cmd+C, reading the
/// pasteboard, and restoring the original clipboard contents.
///
/// This is the robust fallback that works in Chrome, Electron apps,
/// and any app that supports standard copy — which is virtually all
/// of them. AX-based selection reading (`kAXSelectedTextAttribute`)
/// is faster and has no clipboard side effects, but it's unreliable
/// in Chrome (lazy AX tree), Electron (minimal AX support), and
/// apps with custom text engines.
///
/// Sequence: snapshot clipboard → Cmd+C → wait 150 ms → read → restore.
/// Named to avoid collision with the `@DependencyClient`-generated
/// `_captureSelectionViaClipboard` backing store.
@MainActor
private func clipboardFallbackCapture() async -> String? {
  guard AXIsProcessTrusted() else {
    // CGEvent.post silently fails without Accessibility permission —
    // same gate as the AX path.
    if !_axPermissionWarned {
      _axPermissionWarned = true
      inlineEditLogger.error(
        "Clipboard fallback: Accessibility permission required for Cmd+C simulation. Grant in System Settings → Privacy & Security → Accessibility."
      )
    }
    return nil
  }

  // Don't try to copy from ourselves.
  let quillBundles: Set<String> = ["com.joevasquez.Quill", "com.joevasquez.Quill.debug"]
  if let bid = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
     quillBundles.contains(bid)
  {
    inlineEditLogger.info("Clipboard fallback: Quill is frontmost — skipping")
    return nil
  }

  let pasteboard = NSPasteboard.general
  let savedChangeCount = pasteboard.changeCount

  // ── 1. Snapshot the current clipboard contents ──
  let savedItems: [[(NSPasteboard.PasteboardType, Data)]] =
    (pasteboard.pasteboardItems ?? []).map { item in
      item.types.compactMap { type in
        guard let data = item.data(forType: type) else { return nil }
        return (type, data)
      }
    }

  // ── 2. Simulate Cmd+C via CGEvent ──
  let source = CGEventSource(stateID: .combinedSessionState)
  let cKeyCode: CGKeyCode = 8     // 'C' virtual key code
  let cmdKeyCode: CGKeyCode = 55  // Left Command

  let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: cmdKeyCode, keyDown: true)
  let cDown = CGEvent(keyboardEventSource: source, virtualKey: cKeyCode, keyDown: true)
  cDown?.flags = .maskCommand
  let cUp = CGEvent(keyboardEventSource: source, virtualKey: cKeyCode, keyDown: false)
  cUp?.flags = .maskCommand
  let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: cmdKeyCode, keyDown: false)

  cmdDown?.post(tap: .cghidEventTap)
  cDown?.post(tap: .cghidEventTap)
  cUp?.post(tap: .cghidEventTap)
  cmdUp?.post(tap: .cghidEventTap)

  // ── 3. Wait for the target app to process the copy ──
  // 150 ms covers Chrome and Electron which can be sluggish.
  try? await Task.sleep(for: .milliseconds(150))

  // ── 4. Check if the pasteboard changed ──
  if pasteboard.changeCount == savedChangeCount {
    inlineEditLogger.info(
      "Clipboard fallback: pasteboard unchanged after Cmd+C — nothing selected or app didn't respond"
    )
    return nil
  }

  let copiedText = pasteboard.string(forType: .string)

  // ── 5. Restore original clipboard contents ──
  pasteboard.clearContents()
  for itemData in savedItems {
    let item = NSPasteboardItem()
    for (type, data) in itemData {
      item.setData(data, forType: type)
    }
    pasteboard.writeObjects([item])
  }

  guard let text = copiedText,
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  else {
    inlineEditLogger.info("Clipboard fallback: Cmd+C produced empty text")
    return nil
  }

  let appName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"
  inlineEditLogger.info(
    "Clipboard fallback: captured \(text.count) chars from \(appName, privacy: .public)"
  )
  return text
}

@MainActor
private func replaceSelectionSync(with text: String) -> Bool {
  guard AXIsProcessTrusted() else {
    inlineEditLogger.warning("Inline edit: AX permission missing; cannot replace selection")
    return false
  }

  // Try app-specific first, then system-wide fallback.
  var focusedRef: CFTypeRef?
  if let frontApp = NSWorkspace.shared.frontmostApplication {
    let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)
    AXUIElementSetMessagingTimeout(appElement, inlineEditAXTimeout)
    AXUIElementCopyAttributeValue(
      appElement, kAXFocusedUIElementAttribute as CFString, &focusedRef
    )
  }
  if focusedRef == nil {
    let systemWide = AXUIElementCreateSystemWide()
    AXUIElementSetMessagingTimeout(systemWide, inlineEditAXTimeout)
    AXUIElementCopyAttributeValue(
      systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef
    )
  }
  guard let focusedRef else {
    inlineEditLogger.warning("Inline edit: focused element not found for replace")
    return false
  }

  let focused = focusedRef as! AXUIElement
  AXUIElementSetMessagingTimeout(focused, inlineEditAXTimeout)

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
