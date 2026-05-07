#if os(macOS)
import ComposableArchitecture
import HexCore
import SwiftUI

struct CloudSyncSectionView: View {
  @Bindable var store: StoreOf<SettingsFeature>
  @ObservedObject private var cloudSync = MacCloudSync.shared

  private var isGoogleConnected: Bool {
    cloudSync.isGoogleAuthorized()
  }

  var body: some View {
    Section {
      if isGoogleConnected {
        Toggle(isOn: Binding(
          get: { store.hexSettings.cloudSyncEnabled },
          set: { store.send(.setCloudSyncEnabled($0)) }
        )) {
          Label("Sync to Cloud", systemImage: "icloud.and.arrow.up")
        }

        if store.hexSettings.cloudSyncEnabled {
          Button {
            store.send(.syncNow)
          } label: {
            HStack {
              Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
              Spacer()
              if case .syncing = cloudSync.status {
                ProgressView().controlSize(.small)
              }
            }
          }
          .disabled(isSyncing)

          statusText
            .font(.caption)
            .foregroundStyle(statusColor)
        }
      } else {
        HStack {
          Label("Sync to Cloud", systemImage: "icloud.and.arrow.up")
            .foregroundStyle(.secondary)
          Spacer()
          Text("Connect Google Account first")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    } header: {
      Text("Cloud Sync")
    } footer: {
      Text("When on, your transcriptions sync to Google Cloud so you can access them from your iPhone and other devices. Requires a Google account.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private var isSyncing: Bool {
    if case .syncing = cloudSync.status { return true }
    return false
  }

  @ViewBuilder
  private var statusText: some View {
    switch cloudSync.status {
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
    if case .failed = cloudSync.status { return .red }
    return .secondary
  }
}
#endif
