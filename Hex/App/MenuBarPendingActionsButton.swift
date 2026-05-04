//
//  MenuBarPendingActionsButton.swift
//  Quill (macOS)
//
//  Pending-action indicator in the menu-bar dropdown. Hidden when the
//  queue is empty (the common case); appears as a small label "N pending
//  offline action(s)" when items are waiting. Tapping opens Settings,
//  which surfaces the offline-queue inspector under the General tab.
//
//  Refresh strategy: poll on view appear via `.task`. The MenuBarExtra
//  rebuilds each time the user opens it, so this always reflects the
//  current count without needing a push subscription from the actor.
//

import AppKit
import HexCore
import SwiftUI

struct MenuBarPendingActionsButton: View {
  let onSelect: () -> Void

  @State private var pendingCount: Int = 0

  var body: some View {
    Group {
      if pendingCount > 0 {
        Button {
          onSelect()
        } label: {
          Label("\(pendingCount) pending offline action\(pendingCount == 1 ? "" : "s")", systemImage: "tray.full")
        }
      }
    }
    .task { await refresh() }
  }

  private func refresh() async {
    pendingCount = await ActionQueueManager.shared.snapshot().count
  }
}
