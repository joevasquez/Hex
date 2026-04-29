//
//  IntegrationsSectionView.swift
//  Hex (macOS)
//
//  Frontend-only Settings section listing the integrations Quill
//  plans to offer. The connection state is persisted locally via
//  UserDefaults; the actual OAuth / API routing per integration
//  lands in a later pass. The UI is deliberately complete so users
//  can see what's coming and we can start capturing user intent
//  (which integrations get clicked, how often Pro-gated ones get
//  tapped by free users).
//

import ComposableArchitecture
import HexCore
import Inject
import SwiftUI

struct IntegrationsSectionView: View {
  @ObserveInjection var inject
  @Bindable var store: StoreOf<SettingsFeature>

  // Integration connection state. Stored in UserDefaults (shared with
  // iOS via the same key) — a later pass can elevate to HexSettings
  // if we want sync / structured migrations.
  @AppStorage(IntegrationConnectionStore.userDefaultsKey)
  private var connectedData: Data = Data()

  @State private var showingComingSoon = false
  @State private var showingTodoistSheet = false
  @State private var pendingIntegration: Integration?

  var body: some View {
    Form {
      Section {
        ForEach(Integration.all) { integration in
          IntegrationRow(
            integration: integration,
            isConnected: isConnected(integration),
            canConnect: canConnect(integration),
            onToggle: { toggle(integration) }
          )
          .padding(.vertical, 2)
        }

        if connectedCount >= IntegrationLimits.freeTierMaxConnections,
           Integration.all.contains(where: { !isConnected($0) && !$0.requiresPro }) {
          Text("Free plan is capped at \(IntegrationLimits.freeTierMaxConnections) connected integrations. Disconnect one to swap, or upgrade to Pro for unlimited.")
            .font(.caption)
            .foregroundStyle(.orange)
        }
      } header: {
        Text("Integrations")
      } footer: {
        Text("Send dictations into your favorite tools — \"remind me Friday to review the launch deck\" becomes a Todoist task. Free plan includes \(IntegrationLimits.freeTierMaxConnections) integrations; Pro unlocks all.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .alert("Coming Soon", isPresented: $showingComingSoon, presenting: pendingIntegration) { integration in
      Button("OK") { pendingIntegration = nil }
    } message: { integration in
      Text("\(integration.name) integration ships in a follow-up. We're saving your interest — you'll be prompted to finish the connection when it lands.")
    }
    .sheet(isPresented: $showingTodoistSheet) {
      TodoistTokenSheet(onConnected: {
        var current = connected
        current.insert(.todoist)
        connectedData = IntegrationConnectionStore.encode(current)
      })
    }
    .enableInjection()
  }

  // MARK: - Helpers

  private var connected: Set<Integration.Identifier> {
    IntegrationConnectionStore.decode(connectedData)
  }

  private var connectedCount: Int { connected.count }

  private func isConnected(_ integration: Integration) -> Bool {
    connected.contains(integration.identifier)
  }

  /// Free users can only connect up to `freeTierMaxConnections` at a
  /// time across all free integrations, and Pro-marked ones are
  /// always gated (until we ship paid tiers).
  private func canConnect(_ integration: Integration) -> Bool {
    if isConnected(integration) { return true }  // so they can still disconnect
    if integration.requiresPro { return false }
    return connectedCount < IntegrationLimits.freeTierMaxConnections
  }

  private func toggle(_ integration: Integration) {
    var current = connected
    if current.contains(integration.identifier) {
      // Disconnect: drop from set. For Todoist, also clear the token so the
      // adapter doesn't act on a "disconnected" integration.
      current.remove(integration.identifier)
      connectedData = IntegrationConnectionStore.encode(current)
      if integration.identifier == .todoist {
        Task {
          @Dependency(\.keychain) var keychain
          await keychain.delete(KeychainKey.todoistAPIToken)
        }
      }
      return
    }

    switch integration.identifier {
    case .todoist:
      // Real connection flow: prompt for API token.
      showingTodoistSheet = true
    default:
      // Other integrations are catalog-only for now.
      pendingIntegration = integration
      showingComingSoon = true
      current.insert(integration.identifier)
      connectedData = IntegrationConnectionStore.encode(current)
    }
  }
}

// MARK: - Row

private struct IntegrationRow: View {
  let integration: Integration
  let isConnected: Bool
  let canConnect: Bool
  let onToggle: () -> Void

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .fill(tint)
        .frame(width: 32, height: 32)
        .overlay(
          Image(systemName: integration.systemImage)
            .foregroundStyle(.white)
            .font(.system(size: 16, weight: .semibold))
        )

      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(integration.name)
            .font(.body.weight(.semibold))
          if integration.requiresPro {
            Text("PRO")
              .font(.caption2.weight(.bold))
              .foregroundStyle(.white)
              .padding(.horizontal, 6)
              .padding(.vertical, 1)
              .background(Capsule().fill(Color.purple))
          }
        }
        Text(integration.tagline)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }

      Spacer()

      Button(isConnected ? "Disconnect" : "Connect") {
        onToggle()
      }
      .controlSize(.small)
      .disabled(!canConnect && !isConnected)
    }
  }

  private var tint: Color {
    Color(hex: integration.tintHex) ?? .secondary
  }
}

// MARK: - Color hex helper

private extension Color {
  init?(hex: String) {
    var hex = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    if hex.hasPrefix("#") { hex.removeFirst() }
    guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
    let r = Double((value >> 16) & 0xFF) / 255
    let g = Double((value >> 8) & 0xFF) / 255
    let b = Double(value & 0xFF) / 255
    self = Color(red: r, green: g, blue: b)
  }
}
