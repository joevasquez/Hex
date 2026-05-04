//
//  QuillEmptyHome.swift
//  Quill (iOS)
//
//  Pre-recording landing surface — replaces the previous "tap mic to
//  start" placeholder. Renders the editorial "Ready when you are."
//  headline, a floating purple feather mic, and three example-utterance
//  chips colored to match the FAB they map to (purple mic / orange bolt
//  / purple camera) so the user learns the cluster without a tutorial.
//
//  This view sits between the active-note strip and the FAB cluster
//  on the home screen when there is no active note (or the active
//  note is empty). The chips are non-interactive — they're teaching
//  prompts, not buttons — so users feel they own the next move.
//

import SwiftUI

struct QuillEmptyHome: View {
  var body: some View {
    VStack(spacing: 28) {
      Spacer().frame(height: 8)

      // Floating feather mic — matches the purple mic FAB so the eye
      // connects "this big illustration" with "the small button below".
      ZStack {
        Circle()
          .fill(Color.purple.opacity(0.10))
          .frame(width: 132, height: 132)
        Circle()
          .fill(Color.purple.opacity(0.16))
          .frame(width: 96, height: 96)
        Image(systemName: "mic.fill")
          .font(.system(size: 38, weight: .medium))
          .foregroundStyle(.purple)
      }

      VStack(spacing: 10) {
        Text("Ready when you are.")
          .font(.system(size: 32, weight: .bold, design: .serif))
          .foregroundStyle(.primary)
          .multilineTextAlignment(.center)

        Text("Tap the purple mic to dictate, the orange bolt for a voice action, or the camera to capture context.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .padding(.horizontal, 32)
      }

      VStack(spacing: 10) {
        ExampleUtteranceChip(
          icon: "mic",
          tint: .purple,
          example: "remember to call my mom on Friday"
        )
        ExampleUtteranceChip(
          icon: "bolt.fill",
          tint: .orange,
          example: "slack Amanda — push our 3pm to Thursday"
        )
        ExampleUtteranceChip(
          icon: "camera.fill",
          tint: .purple,
          example: "capture today's research call as bullets"
        )
      }
      .padding(.horizontal, 16)

      Spacer()
    }
    .frame(maxWidth: .infinity)
  }
}

// MARK: - Example chip

/// A single teaching prompt — circular icon disc + italic example
/// utterance. Non-interactive: these are illustrative, not buttons.
private struct ExampleUtteranceChip: View {
  let icon: String
  let tint: Color
  let example: String

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: icon)
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(tint)
        .frame(width: 32, height: 32)
        .background(Circle().fill(tint.opacity(0.14)))

      Text("\u{201C}\(example)\u{201D}")
        .font(.subheadline)
        .italic()
        .foregroundStyle(.primary)
        .lineLimit(2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .fill(Color(.systemBackground))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
    )
  }
}
