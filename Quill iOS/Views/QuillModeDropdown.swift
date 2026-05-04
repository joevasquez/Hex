//
//  QuillModeDropdown.swift
//  Quill (iOS)
//
//  Single-pill dropdown that replaces the horizontal scrolling chip
//  row. Tapping the pill opens a system Menu with one row per mode +
//  user-authored custom modes; the selected mode shows a checkmark.
//
//  Modes that need an LLM (every built-in except `.off`, plus all custom
//  modes) are visually de-emphasized when no API key is configured for
//  the current provider — and tapping one surfaces an alert pointing
//  the user at Settings instead of selecting a broken option.
//

import HexCore
import SwiftUI

struct QuillModeDropdown: View {
  @Binding var selectionRaw: String
  let customModes: [CustomAIMode]
  let visibleBuiltInModes: [AIProcessingMode]
  let hasAPIKey: Bool
  let onRequestAPIKeySetup: () -> Void

  @State private var pendingDisabledMode: String?

  /// Decoded current selection. Falls back to `.builtIn(.off)` when the
  /// stored raw doesn't decode (e.g. a deleted custom mode).
  private var current: AIModeSelection {
    AIModeSelection(rawValue: selectionRaw) ?? .builtIn(.off)
  }

  var body: some View {
    Menu {
      // Built-in modes section
      Section {
        ForEach(visibleBuiltInModes, id: \.rawValue) { mode in
          modeRow(
            label: mode.iosDisplayName,
            icon: mode.iosIconName,
            description: nil,
            isSelected: current == .builtIn(mode),
            isDisabled: mode.requiresAPIKey && !hasAPIKey,
            onSelect: { selectionRaw = AIModeSelection.builtIn(mode).rawValue }
          )
        }
      }

      // Custom modes section (only when present)
      if !customModes.isEmpty {
        Section("Custom") {
          ForEach(customModes) { mode in
            modeRow(
              label: mode.displayName,
              icon: mode.icon,
              description: nil,
              isSelected: current == .custom(mode.id),
              isDisabled: !hasAPIKey, // all custom modes hit the LLM
              onSelect: { selectionRaw = AIModeSelection.custom(mode.id).rawValue }
            )
          }
        }
      }
    } label: {
      triggerPill
    }
    .alert("API Key Required", isPresented: Binding(
      get: { pendingDisabledMode != nil },
      set: { if !$0 { pendingDisabledMode = nil } }
    )) {
      Button("Open Settings") {
        pendingDisabledMode = nil
        onRequestAPIKeySetup()
      }
      Button("Cancel", role: .cancel) {
        pendingDisabledMode = nil
      }
    } message: {
      Text("\(pendingDisabledMode ?? "This mode") needs an AI provider API key. Add one in Settings → AI Provider to enable AI transformations.")
    }
  }

  // MARK: - Trigger pill

  /// The pill the user taps. Solid purple capsule, white glyph + label,
  /// chevron to telegraph the menu affordance. Deliberately flat:
  /// previous versions stacked a gradient stroke + drop shadow that
  /// SwiftUI ended up animating on every selection change, which read
  /// as sluggish. The Menu's native press / open transition is
  /// snappier without compounding effects to fight with.
  private var triggerPill: some View {
    HStack(spacing: 6) {
      Image(systemName: triggerIcon)
        .font(.caption.weight(.semibold))
      Text(triggerLabel)
        .font(.subheadline.weight(.medium))
      Image(systemName: "chevron.down")
        .font(.caption2.weight(.bold))
        .opacity(0.85)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
    .foregroundStyle(.white)
    .background(Capsule().fill(triggerTint))
    .contentShape(Capsule())
    // Suppress SwiftUI's implicit animations on the label — the system
    // Menu owns the press / open feel and we don't want a cascading
    // .animation modifier above us turning every label change into a
    // 0.4s crossfade.
    .transaction { $0.animation = nil }
    .accessibilityLabel("AI mode: \(triggerLabel). Tap to change.")
  }

  private var triggerIcon: String {
    switch current {
    case .builtIn(let mode): return mode.iosIconName
    case .custom(let id):
      return customModes.first(where: { $0.id == id })?.icon ?? "sparkles"
    }
  }

  private var triggerLabel: String {
    switch current {
    case .builtIn(let mode): return mode.iosDisplayName
    case .custom(let id):
      return customModes.first(where: { $0.id == id })?.displayName ?? "Custom"
    }
  }

  private var triggerTint: Color {
    if case .builtIn(.off) = current { return .blue }
    return .purple
  }

  // MARK: - Menu row

  /// Standardized row inside the menu. Disabled rows are intercepted
  /// (button still tappable so we can surface an alert) and rendered
  /// with a faded label — matches the spec: "options should be slightly
  /// greyed out … if they click, see a notice that they need to add an
  /// API key".
  @ViewBuilder
  private func modeRow(
    label: String,
    icon: String,
    description: String?,
    isSelected: Bool,
    isDisabled: Bool,
    onSelect: @escaping () -> Void
  ) -> some View {
    Button {
      if isDisabled {
        pendingDisabledMode = label
      } else {
        onSelect()
      }
    } label: {
      Label {
        HStack {
          VStack(alignment: .leading, spacing: 1) {
            Text(label)
            if isDisabled {
              Text("Needs API key")
                .font(.caption2)
                .foregroundStyle(.secondary)
            } else if let description {
              Text(description)
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
          }
          Spacer()
          if isSelected {
            Image(systemName: "checkmark")
          }
        }
      } icon: {
        Image(systemName: icon)
      }
    }
  }
}
