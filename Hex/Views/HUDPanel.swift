//
//  HUDPanel.swift
//  Hex
//
//  A small floating panel for the always-visible mode HUD.
//  Draggable, non-activating, stays on top of all windows
//  and persists across Spaces. Position saved to UserDefaults.
//

import AppKit
import SwiftUI

class HUDPanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }

  private static let positionKey = "com.joevasquez.Quill.hudPosition"

  init() {
    let styleMask: NSWindow.StyleMask = [
      .borderless,
      .nonactivatingPanel,
      .utilityWindow,
    ]

    // Start with a generous frame — the SwiftUI pill is smaller
    // and the transparent surround passes clicks through.
    super.init(
      contentRect: .init(x: 0, y: 0, width: 260, height: 100),
      styleMask: styleMask,
      backing: .buffered,
      defer: false
    )

    level = .statusBar
    backgroundColor = .clear
    isOpaque = false
    hasShadow = false
    hidesOnDeactivate = false
    canHide = false
    // Native AppKit window dragging — any opaque region of the
    // SwiftUI pill that isn't a button becomes the drag handle.
    // No SwiftUI DragGesture needed (those wobble because the
    // coordinate system shifts as the panel moves).
    isMovableByWindowBackground = true
    collectionBehavior = [
      .fullScreenAuxiliary,
      .canJoinAllSpaces,
      .stationary,
      .ignoresCycle,
    ]

    restorePosition()

    // Persist position after every drag.
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(windowDidMove),
      name: NSWindow.didMoveNotification,
      object: self
    )
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  // MARK: - Position Persistence

  private func restorePosition() {
    if let dict = UserDefaults.standard.dictionary(forKey: Self.positionKey),
       let x = dict["x"] as? CGFloat,
       let y = dict["y"] as? CGFloat
    {
      setFrameOrigin(NSPoint(x: x, y: y))
    } else {
      centerOnMainScreen()
    }
  }

  private func centerOnMainScreen() {
    guard let screen = NSScreen.main else { return }
    let x = screen.frame.midX - frame.width / 2
    let y = screen.frame.maxY - 80
    setFrameOrigin(NSPoint(x: x, y: y))
  }

  @objc private func windowDidMove(_ notification: Notification) {
    let origin = frame.origin
    UserDefaults.standard.set(
      ["x": origin.x, "y": origin.y],
      forKey: Self.positionKey
    )
  }

  // MARK: - Factory

  static func hosting<V: View>(_ view: V) -> HUDPanel {
    let panel = HUDPanel()
    let hostingView = NSHostingView(rootView: view)
    hostingView.frame = panel.contentView!.bounds
    hostingView.autoresizingMask = [.width, .height]
    panel.contentView = hostingView
    return panel
  }
}
