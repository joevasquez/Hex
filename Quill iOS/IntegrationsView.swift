//
//  IntegrationsView.swift
//  Quill (iOS)
//
//  Settings sub-screen listing the integrations Quill plans to ship.
//  Frontend only — connection state is persisted via UserDefaults for
//  now; actual OAuth flows and send adapters land in a follow-up.
//

import EventKit
import HexCore
import SwiftUI

struct IntegrationsView: View {
  @Environment(\.dismiss) private var dismiss
  @AppStorage(IntegrationConnectionStore.userDefaultsKey) private var connectedData: Data = Data()

  @State private var showingComingSoon = false
  @State private var showingTodoistSheet = false
  @State private var showingGoogleSheet = false
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

        if connectedFreeCount >= IntegrationLimits.freeTierMaxConnections,
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
      .sheet(isPresented: $showingTodoistSheet) {
        TodoistTokenSheetIOS(onConnected: {
          var current = connected
          current.insert(.todoist)
          connectedData = IntegrationConnectionStore.encode(current)
        })
      }
      .sheet(isPresented: $showingGoogleSheet) {
        // Reuse the dedicated Google Account screen rather than a
        // bespoke OAuth sheet — keeps sign-in/disconnect logic in one
        // place. NavigationStack so the inner view's title shows.
        NavigationStack {
          GoogleAccountView()
            .toolbar {
              ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { showingGoogleSheet = false }
              }
            }
        }
      }
    }
  }

  private var connected: Set<Integration.Identifier> {
    IntegrationConnectionStore.decode(connectedData)
  }

  private var connectedCount: Int { connected.count }

  /// The free-tier cap only counts non-Pro integrations toward the
  /// quota — Pro integrations (Gmail, Google Calendar, etc.) come in
  /// through their own OAuth path and would otherwise squeeze out the
  /// free three. Without this filter, signing into Google fills the
  /// cap and disables every Connect button below.
  private var connectedFreeCount: Int {
    connected.filter { id in
      Integration.all.first(where: { $0.identifier == id })?.requiresPro == false
    }.count
  }

  private func isConnected(_ integration: Integration) -> Bool {
    // For Gmail / Google Calendar, OAuth keychain state wins over the
    // UserDefaults integration set. This keeps the row in sync even if
    // the user signed in before the connection-state backfill landed
    // (tokens present, store entry missing).
    if integration.identifier == .gmail || integration.identifier == .googleCalendar {
      return IOSGoogleOAuthClient.isAuthorized()
    }
    return connected.contains(integration.identifier)
  }

  private func canConnect(_ integration: Integration) -> Bool {
    if isConnected(integration) { return true }
    if integration.requiresPro { return false }
    return connectedFreeCount < IntegrationLimits.freeTierMaxConnections
  }

  private func toggle(_ integration: Integration) {
    var current = connected

    // Use the same is-connected logic as the row UI so taps always
    // match what the button is showing. Falls through to the OAuth
    // check for Gmail/GCal.
    if isConnected(integration) {
      current.remove(integration.identifier)
      // Disconnecting either Gmail or Google Calendar revokes both
      // (single sign-in covers both scopes). Mirrors the macOS toggle.
      if integration.identifier == .gmail || integration.identifier == .googleCalendar {
        current.remove(.gmail)
        current.remove(.googleCalendar)
        IOSGoogleOAuthClient.disconnect()
      }
      connectedData = IntegrationConnectionStore.encode(current)
      if integration.identifier == .todoist {
        KeychainStore.delete(account: KeychainKey.todoistAPIToken)
      }
      UISelectionFeedbackGenerator().selectionChanged()
      return
    }

    switch integration.identifier {
    case .appleReminders:
      Task {
        let store = EKEventStore()
        let granted = (try? await store.requestFullAccessToReminders()) ?? false
        if granted {
          var updated = connected
          updated.insert(.appleReminders)
          connectedData = IntegrationConnectionStore.encode(updated)
        }
      }
    case .calendar:
      Task {
        let store = EKEventStore()
        let granted = (try? await store.requestFullAccessToEvents()) ?? false
        if granted {
          var updated = connected
          updated.insert(.calendar)
          connectedData = IntegrationConnectionStore.encode(updated)
        }
      }
    case .todoist:
      showingTodoistSheet = true
    case .gmail, .googleCalendar:
      // One sign-in covers both — present the shared Google Account
      // sheet. The sheet itself writes both identifiers into the store
      // on success.
      showingGoogleSheet = true
    default:
      pending = integration
      showingComingSoon = true
      current.insert(integration.identifier)
      connectedData = IntegrationConnectionStore.encode(current)
    }
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
