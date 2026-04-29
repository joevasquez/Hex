import ComposableArchitecture
import HexCore
import Inject
import SwiftUI

struct ActionConfirmationView: View {
  @Bindable var store: StoreOf<ActionConfirmationFeature>
  @ObserveInjection var inject

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider().opacity(0.3)
      form
      Divider().opacity(0.3)
      footer
    }
    .frame(width: 340)
    .background(
      RoundedRectangle(cornerRadius: 12)
        .fill(.ultraThinMaterial)
        .shadow(color: .black.opacity(0.3), radius: 16, y: 8)
    )
    .clipShape(RoundedRectangle(cornerRadius: 12))
    .overlay(
      RoundedRectangle(cornerRadius: 12)
        .strokeBorder(.white.opacity(0.1), lineWidth: 0.5)
    )
    .onAppear { store.send(.onAppear) }
    .enableInjection()
  }

  // MARK: - Header (integration picker)

  private var header: some View {
    HStack(spacing: 8) {
      Image(systemName: integrationIcon(store.selectedIntegration))
        .font(.system(size: 20))
        .foregroundStyle(integrationTint(store.selectedIntegration))

      if store.availableIntegrations.count > 1 {
        Picker("", selection: integrationBinding) {
          ForEach(store.availableIntegrations, id: \.self) { id in
            Text(integrationName(id)).tag(id)
          }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .tint(.white)
      } else {
        Text(integrationName(store.selectedIntegration))
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(.white)
      }

      Spacer()
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
  }

  private var integrationBinding: Binding<Integration.Identifier> {
    Binding(
      get: { store.selectedIntegration },
      set: { store.send(.selectedIntegrationChanged($0)) }
    )
  }

  // MARK: - Form (per-integration fields)

  @ViewBuilder
  private var form: some View {
    VStack(spacing: 10) {
      field("Title", text: $store.editableTitle)
      field("Due", text: $store.editableDueDate, placeholder: "e.g. Friday, tomorrow")

      if !store.availableLists.isEmpty {
        HStack {
          Text(listLabel)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.5))
            .frame(width: 50, alignment: .leading)
          Picker("", selection: $store.selectedList) {
            ForEach(store.availableLists, id: \.self) { list in
              Text(list).tag(list)
            }
          }
          .labelsHidden()
          .pickerStyle(.menu)
          .tint(.white.opacity(0.8))
        }
      }

      if store.selectedIntegration == .todoist {
        priorityPicker
      }

      field(notesLabel, text: $store.editableNotes, placeholder: "Optional")

      if let error = store.error {
        Text(error)
          .font(.system(size: 10))
          .foregroundStyle(.red.opacity(0.9))
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
  }

  private var listLabel: String {
    store.selectedIntegration == .todoist ? "Project" : "List"
  }

  private var notesLabel: String {
    store.selectedIntegration == .todoist ? "Notes" : "Notes"
  }

  private var priorityPicker: some View {
    HStack {
      Text("Priority")
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.white.opacity(0.5))
        .frame(width: 50, alignment: .leading)
      Picker("", selection: $store.editablePriority) {
        Text("None").tag(0)
        Text("P1 (urgent)").tag(4)
        Text("P2").tag(3)
        Text("P3").tag(2)
        Text("P4 (low)").tag(1)
      }
      .labelsHidden()
      .pickerStyle(.menu)
      .tint(.white.opacity(0.8))
    }
  }

  private func field(
    _ label: String,
    text: Binding<String>,
    placeholder: String = ""
  ) -> some View {
    HStack {
      Text(label)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.white.opacity(0.5))
        .frame(width: 50, alignment: .leading)
      TextField(placeholder, text: text)
        .textFieldStyle(.plain)
        .font(.system(size: 12))
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
          RoundedRectangle(cornerRadius: 6)
            .fill(.white.opacity(0.08))
        )
    }
  }

  // MARK: - Footer

  private var footer: some View {
    HStack(spacing: 12) {
      Spacer()

      Button { store.send(.cancel) } label: {
        HStack(spacing: 4) {
          Image(systemName: "xmark")
            .font(.system(size: 10, weight: .bold))
          Text("Cancel")
            .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(.white.opacity(0.12)))
      }
      .buttonStyle(.plain)

      Button { store.send(.execute) } label: {
        HStack(spacing: 4) {
          if store.isExecuting {
            ProgressView()
              .scaleEffect(0.6)
              .frame(width: 10, height: 10)
          } else {
            Image(systemName: "checkmark")
              .font(.system(size: 10, weight: .bold))
          }
          Text(executeLabel)
            .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(.green.opacity(0.7)))
      }
      .buttonStyle(.plain)
      .disabled(store.editableTitle.isEmpty || store.isExecuting)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
  }

  private var executeLabel: String {
    store.selectedIntegration == .todoist ? "Add Task" : "Create"
  }

  // MARK: - Integration display helpers

  private func integrationName(_ id: Integration.Identifier) -> String {
    Integration.all.first { $0.identifier == id }?.name ?? id.rawValue
  }

  private func integrationIcon(_ id: Integration.Identifier) -> String {
    Integration.all.first { $0.identifier == id }?.systemImage ?? "questionmark.circle"
  }

  private func integrationTint(_ id: Integration.Identifier) -> Color {
    let hex = Integration.all.first { $0.identifier == id }?.tintHex
    return Color(hex: hex ?? "") ?? .orange
  }
}

private extension Color {
  init?(hex: String) {
    var h = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    if h.hasPrefix("#") { h.removeFirst() }
    guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
    let r = Double((v >> 16) & 0xFF) / 255
    let g = Double((v >> 8) & 0xFF) / 255
    let b = Double(v & 0xFF) / 255
    self = Color(red: r, green: g, blue: b)
  }
}
