//
//  CloudSyncStatusRow.swift
//  Quill (iOS)
//
//  "Sync Now" button + live status row for the Settings cloud-sync section.
//  Observes `NotesStore.shared.syncStatus` so the user gets real feedback
//  during a sync (spinner) and after (counts + relative time, or error).
//

import SwiftUI

struct CloudSyncStatusRow: View {
  @ObservedObject private var notes = NotesStore.shared

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Button {
        Task { await notes.syncNow() }
      } label: {
        HStack {
          Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
          Spacer()
          if case .syncing = notes.syncStatus {
            ProgressView()
              .controlSize(.small)
          }
        }
      }
      .disabled(isSyncing)

      statusText
        .font(.caption)
        .foregroundStyle(statusColor)
    }
  }

  private var isSyncing: Bool {
    if case .syncing = notes.syncStatus { return true }
    return false
  }

  @ViewBuilder
  private var statusText: some View {
    switch notes.syncStatus {
    case .idle:
      Text("No sync since launch.")
    case .syncing:
      Text("Syncing…")
    case .completed(let up, let down, let at):
      let when = at.formatted(.relative(presentation: .named))
      if up == 0 && down == 0 {
        Text("Already up to date · \(when)")
      } else {
        Text("Synced \(up) up, \(down) down · \(when)")
      }
    case .failed(let msg):
      Text("Sync failed: \(msg)")
    }
  }

  private var statusColor: Color {
    switch notes.syncStatus {
    case .failed: return .red
    case .completed: return .secondary
    default: return .secondary
    }
  }
}
