//
//  IntegrationsView.swift
//  Quill (iOS)
//
//  Settings sub-screen listing the integrations Quill plans to ship.
//  Frontend only — connection state is persisted via UserDefaults for
//  now; actual OAuth flows and send adapters land in a follow-up.
//

import HexCore
import SwiftUI

struct IntegrationsView: View {
  @Environment(\.dismiss) private var dismiss
  @AppStorage(IntegrationConnectionStore.userDefaultsKey) private var connectedData: Data = Data()

  @State private var showingComingSoon = false
  @State private var pending: Integration?

  var body: some View {
    NavigationStack {
      List {
        Section {
          ForEach(Integration.all) { integration in
            IntegrationRow(
              integration: integration,
              isConnected: isConnected(integration),
              canConnect: canConnect(integration),
              onToggle: { toggle(integration) }
            )
          }
        } footer: {
          Text("Dictate naturally — \"remind me Friday to review the launch deck\" becomes a Todoist task. Free plan includes \(IntegrationLimits.freeTierMaxConnections) integrations; Pro unlocks all.")
        }

        if connectedCount >= IntegrationLimits.freeTierMaxConnections,
           Integration.all.contains(where: { !isConnected($0) && !$0.requiresPro }) {
          Section {
            HStack(alignment: .top, spacing: 8) {
              Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
              Text("Free plan is capped at \(IntegrationLimits.freeTierMaxConnections) connected integrations. Disconnect one to swap, or upgrade to Pro for unlimited.")
                .font(.footnote)
            }
          }
        }
      }
      .navigationTitle("Integrations")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("Done") { dismiss() }
        }
      }
      .alert("Coming Soon", isPresented: $showingComingSoon, presenting: pending) { _ in
        Button("OK") { pending = nil }
      } message: { integration in
        Text("\(integration.name) ships in a follow-up. We've saved your intent — you'll be prompted to finish the connection when it lands.")
      }
    }
  }

  private var connected: Set<Integration.Identifier> {
    IntegrationConnectionStore.decode(connectedData)
  }

  private var connectedCount: Int { connected.count }

  private func isConnected(_ integration: Integration) -> Bool {
    connected.contains(integration.identifier)
  }

  private func canConnect(_ integration: Integration) -> Bool {
    if isConnected(integration) { return true }
    if integration.requiresPro { return false }
    return connectedCount < IntegrationLimits.freeTierMaxConnections
  }

  private func toggle(_ integration: Integration) {
    var current = connected
    if current.contains(integration.identifier) {
      current.remove(integration.identifier)
    } else {
      current.insert(integration.identifier)
      pending = integration
      showingComingSoon = true
    }
    connectedData = IntegrationConnectionStore.encode(current)
    UISelectionFeedbackGenerator().selectionChanged()
  }
}

private struct IntegrationRow: View {
  let integration: Integration
  let isConnected: Bool
  let canConnect: Bool
  let onToggle: () -> Void

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(tint)
        .frame(width: 38, height: 38)
        .overlay(
          Image(systemName: integration.systemImage)
            .foregroundStyle(.white)
            .font(.system(size: 18, weight: .semibold))
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
          .lineLimit(3)
      }

      Spacer(minLength: 8)

      Button(isConnected ? "Disconnect" : "Connect", action: onToggle)
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .tint(isConnected ? .red : .purple)
        .disabled(!canConnect && !isConnected)
    }
    .padding(.vertical, 6)
  }

  private var tint: Color {
    Color(hex: integration.tintHex) ?? .secondary
  }
}

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
