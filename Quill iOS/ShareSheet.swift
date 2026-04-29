//
//  ShareSheet.swift
//  Quill (iOS)
//
//  Minimal UIActivityViewController wrapper. `ShareLink` can't host a
//  lazily-generated file (e.g. a PDF we only want to render when the
//  user actually asks to share), so we drive that path through a
//  classic activity view controller presented via `.sheet(item:)`.
//

import SwiftUI
import UIKit

/// Identifiable wrapper so we can drive presentation from a single
/// optional state property and avoid confirmationDialog → sheet race
/// conditions.
struct ShareRequest: Identifiable {
  let id = UUID()
  let items: [Any]
}

struct ShareSheet: UIViewControllerRepresentable {
  let items: [Any]

  func makeUIViewController(context: Context) -> UIActivityViewController {
    UIActivityViewController(activityItems: items, applicationActivities: nil)
  }

  func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
