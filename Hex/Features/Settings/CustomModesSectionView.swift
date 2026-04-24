//
//  CustomModesSectionView.swift
//  Hex (macOS)
//
//  Settings UI for managing user-authored AI post-processing modes.
//  Mirrors the iOS `CustomModesView` but adapted to the existing
//  TCA-driven macOS Settings layout. Lives inside the existing AI
//  Enhancement panel in SettingsView.
//

import ComposableArchitecture
import HexCore
import Inject
import SwiftUI

struct CustomModesSectionView: View {
  @ObserveInjection var inject
  @Bindable var store: StoreOf<SettingsFeature>

  @State private var editing: CustomAIMode?
  @State private var showingNew = false

  var body: some View {
    Form {
      Section {
        let modes = store.hexSettings.customAIModes
        if modes.isEmpty {
          VStack(alignment: .leading, spacing: 6) {
            Text("No custom modes yet.")
              .foregroundStyle(.secondary)
            Text("Create a mode to pair a name with a prompt — for the long tail of transforms Quill doesn't ship by default (Clinical note, VC update, Code review email, etc.).")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .padding(.vertical, 4)
        } else {
          ForEach(modes) { mode in
            HStack(alignment: .top, spacing: 10) {
              Image(systemName: mode.icon)
                .foregroundStyle(.purple)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.purple.opacity(0.14)))

              VStack(alignment: .leading, spacing: 2) {
                Text(mode.displayName)
                  .font(.body.weight(.semibold))
                Text(mode.systemPrompt)
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .lineLimit(2)
              }
              Spacer()
              Button("Edit") { editing = mode }
                .controlSize(.small)
              Button(role: .destructive) {
                store.send(.removeCustomAIMode(mode.id))
              } label: {
                Image(systemName: "trash")
              }
              .controlSize(.small)
            }
            .padding(.vertical, 4)
          }
        }

        Button {
          showingNew = true
        } label: {
          Label("New Mode…", systemImage: "plus.circle")
        }
        .controlSize(.small)
      } header: {
        Text("Custom AI Modes")
      } footer: {
        Text("Custom modes appear alongside built-ins in the mode picker. Quill wraps your prompt in the standard safety preamble automatically.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .sheet(isPresented: $showingNew) {
      CustomModeEditorMac(initial: nil) { newMode in
        store.send(.addCustomAIMode(newMode))
      }
    }
    .sheet(item: $editing) { mode in
      CustomModeEditorMac(initial: mode) { updated in
        store.send(.updateCustomAIMode(updated))
      }
    }
    .enableInjection()
  }
}

private struct CustomModeEditorMac: View {
  @Environment(\.dismiss) private var dismiss
  let initial: CustomAIMode?
  let onSave: (CustomAIMode) -> Void

  @State private var name: String
  @State private var prompt: String
  @State private var icon: String

  init(initial: CustomAIMode?, onSave: @escaping (CustomAIMode) -> Void) {
    self.initial = initial
    self.onSave = onSave
    _name = State(initialValue: initial?.name ?? "")
    _prompt = State(initialValue: initial?.systemPrompt ?? "")
    _icon = State(initialValue: initial?.icon ?? "sparkles")
  }

  private let iconChoices = [
    "sparkles", "stethoscope", "briefcase", "doc.text",
    "list.bullet.clipboard", "envelope", "bubble.left.and.bubble.right",
    "chevron.left.forwardslash.chevron.right", "heart.text.square",
    "books.vertical", "brain", "wand.and.stars",
  ]

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(initial == nil ? "New Custom Mode" : "Edit Custom Mode")
        .font(.title2.weight(.semibold))

      Form {
        TextField("Name", text: $name, prompt: Text("e.g. Clinical note, VC update"))
        Picker("Icon", selection: $icon) {
          ForEach(iconChoices, id: \.self) { name in
            Label(name, systemImage: name).tag(name)
          }
        }
        VStack(alignment: .leading, spacing: 4) {
          Text("Transformation prompt")
            .font(.caption.weight(.semibold))
          TextEditor(text: $prompt)
            .frame(minHeight: 160)
            .font(.body)
            .border(Color.secondary.opacity(0.3))
          Text("Quill wraps your prompt in the standard safety preamble. Describe only the transformation you want — e.g. \"Rewrite as a clinical progress note in SOAP format. Preserve dates, medications, and dosages. Use past tense.\"")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .formStyle(.grouped)

      HStack {
        Spacer()
        Button("Cancel") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Save") { save() }
          .keyboardShortcut(.defaultAction)
          .disabled(!canSave)
      }
    }
    .padding(20)
    .frame(minWidth: 540, minHeight: 420)
  }

  private var canSave: Bool {
    !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
      !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private func save() {
    let mode = CustomAIMode(
      id: initial?.id ?? UUID(),
      name: name.trimmingCharacters(in: .whitespacesAndNewlines),
      systemPrompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
      icon: icon,
      createdAt: initial?.createdAt ?? Date()
    )
    onSave(mode)
    dismiss()
  }
}
