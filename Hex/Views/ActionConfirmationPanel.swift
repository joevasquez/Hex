import AppKit
import SwiftUI

class ActionConfirmationPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  init() {
    let styleMask: NSWindow.StyleMask = [
      .borderless,
      .nonactivatingPanel,
      .utilityWindow,
    ]

    super.init(
      contentRect: .init(x: 0, y: 0, width: 340, height: 260),
      styleMask: styleMask,
      backing: .buffered,
      defer: false
    )

    level = .popUpMenu
    backgroundColor = .clear
    isOpaque = false
    hasShadow = true
    hidesOnDeactivate = false
    canHide = false
    collectionBehavior = [
      .fullScreenAuxiliary,
      .canJoinAllSpaces,
      .stationary,
      .ignoresCycle,
    ]
  }

  func positionBelowStatusBar() {
    guard let screen = NSScreen.main else { return }
    let screenFrame = screen.frame
    let menuBarHeight: CGFloat = NSStatusBar.system.thickness
    let x = screenFrame.midX - frame.width / 2
    let y = screenFrame.maxY - menuBarHeight - frame.height - 4
    setFrameOrigin(NSPoint(x: x, y: y))
  }

  static func hosting<V: View>(_ view: V) -> ActionConfirmationPanel {
    let panel = ActionConfirmationPanel()
    let hostingView = NSHostingView(rootView: view)
    hostingView.frame = panel.contentView!.bounds
    hostingView.autoresizingMask = [.width, .height]
    panel.contentView = hostingView
    return panel
  }
}
