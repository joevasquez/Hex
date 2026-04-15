//
//  ContextClient.swift
//  Hex
//
//  Reads text context from the active application using Accessibility APIs.
//

import AppKit
import Dependencies
import DependenciesMacros
import Foundation
import HexCore

private let contextLogger = HexLog.aiProcessing

@DependencyClient
struct ContextClient {
  var captureContext: @Sendable () async -> AppContext = { AppContext() }
}

extension ContextClient: DependencyKey {
  static var liveValue: Self {
    .init(
      captureContext: {
        let activeApp = NSWorkspace.shared.frontmostApplication
        let appName = activeApp?.localizedName
        let bundleID = activeApp?.bundleIdentifier

        // Read text from focused element via Accessibility API
        let (selectedText, surroundingText) = readFocusedElementText()

        let context = AppContext(
          selectedText: selectedText,
          surroundingText: surroundingText,
          appName: appName,
          bundleID: bundleID
        )

        if context.hasContent {
          contextLogger.info("Captured context from \(appName ?? "unknown"): \(context.selectedText?.count ?? 0) selected, \(context.surroundingText?.count ?? 0) surrounding chars")
        }

        return context
      }
    )
  }
}

extension DependencyValues {
  var contextClient: ContextClient {
    get { self[ContextClient.self] }
    set { self[ContextClient.self] = newValue }
  }
}

// MARK: - Accessibility Text Reading

private func readFocusedElementText() -> (selectedText: String?, surroundingText: String?) {
  let systemWideElement = AXUIElementCreateSystemWide()

  var focusedElementRef: CFTypeRef?
  let axError = AXUIElementCopyAttributeValue(
    systemWideElement,
    kAXFocusedUIElementAttribute as CFString,
    &focusedElementRef
  )

  guard axError == .success, let focusedElementRef else {
    return (nil, nil)
  }

  let focusedElement = focusedElementRef as! AXUIElement

  // Try to read selected text first (most relevant context)
  var selectedTextRef: CFTypeRef?
  let selectedText: String?
  if AXUIElementCopyAttributeValue(focusedElement, kAXSelectedTextAttribute as CFString, &selectedTextRef) == .success,
     let text = selectedTextRef as? String, !text.isEmpty
  {
    selectedText = text
  } else {
    selectedText = nil
  }

  // Read the full value of the text field (surrounding context)
  var valueRef: CFTypeRef?
  let surroundingText: String?
  if AXUIElementCopyAttributeValue(focusedElement, kAXValueAttribute as CFString, &valueRef) == .success,
     let text = valueRef as? String, !text.isEmpty
  {
    // Truncate long documents to a reasonable size
    surroundingText = String(text.suffix(1000))
  } else {
    surroundingText = nil
  }

  return (selectedText, surroundingText)
}
