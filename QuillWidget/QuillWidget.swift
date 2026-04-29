//
//  QuillWidget.swift
//  Quill iOS Widget
//
//  Home-screen widget that:
//    • Shows Quill's feather logo + a "Dictate" call-to-action.
//    • Shows the most-recent note's title and a short preview when
//      sized medium or large.
//    • Taps anywhere in the widget deep-link into the app via a
//      `quill://` URL that opens the recording flow.
//
//  Data sharing between the main app and the widget is done through
//  the App Group `group.com.joevasquez.Quill` — the main app writes
//  the most-recent note's title + preview text + updatedAt timestamp
//  to the shared UserDefaults every time a note is mutated; the
//  widget reads that blob via `QuillWidgetSnapshot.load()`.
//
//  The widget's timeline is static: it re-renders whenever WidgetKit
//  requests a new timeline (app launch, system events, explicit
//  `WidgetCenter.shared.reloadAllTimelines()` from the main app).
//

import HexCore
import SwiftUI
import WidgetKit

// MARK: - Timeline

struct QuillWidgetEntry: TimelineEntry {
  let date: Date
  let snapshot: QuillWidgetSnapshot?
}

struct QuillWidgetProvider: TimelineProvider {
  func placeholder(in context: Context) -> QuillWidgetEntry {
    QuillWidgetEntry(date: .now, snapshot: QuillWidgetSnapshot.placeholder)
  }

  func getSnapshot(in context: Context, completion: @escaping (QuillWidgetEntry) -> Void) {
    let entry = QuillWidgetEntry(
      date: .now,
      snapshot: QuillWidgetSnapshot.load() ?? QuillWidgetSnapshot.placeholder
    )
    completion(entry)
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<QuillWidgetEntry>) -> Void) {
    let entry = QuillWidgetEntry(date: .now, snapshot: QuillWidgetSnapshot.load())
    // One entry that never auto-expires — the main app triggers
    // `WidgetCenter.shared.reloadAllTimelines()` whenever notes change.
    let timeline = Timeline(entries: [entry], policy: .never)
    completion(timeline)
  }
}

// MARK: - Widget definition

struct QuillWidget: Widget {
  static let kind = "QuillWidget"

  var body: some WidgetConfiguration {
    StaticConfiguration(kind: Self.kind, provider: QuillWidgetProvider()) { entry in
      QuillWidgetView(entry: entry)
        .containerBackground(for: .widget) {
          LinearGradient(
            colors: [
              Color(red: 0.25, green: 0.10, blue: 0.45),
              Color(red: 0.40, green: 0.20, blue: 0.65),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          )
        }
    }
    .configurationDisplayName("Quill")
    .description("Jump straight into a voice note, and see your most-recent one at a glance.")
    .supportedFamilies([.systemSmall, .systemMedium])
  }
}

// MARK: - Views

struct QuillWidgetView: View {
  let entry: QuillWidgetEntry
  @Environment(\.widgetFamily) var family

  var body: some View {
    switch family {
    case .systemSmall:
      SmallView(entry: entry)
    default:
      MediumView(entry: entry)
    }
  }
}

/// A slim, filled quill/feather drawn as a SwiftUI `Shape`. Uses a
/// vector path rather than the PNG asset because the shipped feather
/// PNG is a thin outline that collapses to an unreadable stroke at
/// widget-icon sizes.
///
/// Drawn into a tall-and-narrow bounding rect so the shape reads as
/// a *quill* (vertical pen-feather) rather than a leaf. Slanted to
/// the right so it visually agrees with the adjacent serif wordmark.
private struct FeatherShape: Shape {
  func path(in rect: CGRect) -> Path {
    let w = rect.width
    let h = rect.height
    var path = Path()

    // Main blade — slim almond shape, tip at top-left, nib at
    // bottom-right. Narrower along its minor axis than a leaf so it
    // reads as a pen-feather and not a vegetable.
    path.move(to: CGPoint(x: w * 0.18, y: h * 0.06))
    path.addQuadCurve(
      to: CGPoint(x: w * 0.82, y: h * 0.88),
      control: CGPoint(x: w * 0.98, y: h * 0.04)
    )
    path.addQuadCurve(
      to: CGPoint(x: w * 0.18, y: h * 0.06),
      control: CGPoint(x: w * 0.28, y: h * 0.70)
    )
    path.closeSubpath()

    // Tapered nib extending past the main blade's bottom tip.
    path.move(to: CGPoint(x: w * 0.78, y: h * 0.86))
    path.addLine(to: CGPoint(x: w * 0.95, y: h * 0.98))
    path.addLine(to: CGPoint(x: w * 0.84, y: h * 0.90))
    path.closeSubpath()

    return path
  }
}

/// Feather + "Quill" wordmark used as the widget's branding. The
/// feather sits in a slightly taller-than-wide box (aspect 0.75) so
/// it reads as a slim pen rather than a fat leaf, and is sized a
/// touch smaller than the wordmark's cap height so the "Quill" text
/// leads visually.
private struct QuillMark: View {
  /// Height of the feather. The wordmark is sized up a little
  /// relative to this so the two read as a balanced pair.
  var iconHeight: CGFloat = 18
  var textSize: CGFloat = 16

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 5) {
      FeatherShape()
        .fill(Color.white)
        // Narrower-than-tall box keeps the feather slim.
        .frame(width: iconHeight * 0.75, height: iconHeight)
        .shadow(color: .black.opacity(0.2), radius: 1.5, y: 1)
        .offset(y: iconHeight * 0.1)  // nudge down so it sits on text baseline
      Text("Quill")
        .font(.system(size: textSize, weight: .semibold, design: .serif))
        .foregroundStyle(.white)
        .kerning(0.3)
    }
  }
}

private struct SmallView: View {
  let entry: QuillWidgetEntry

  var body: some View {
    Link(destination: URL(string: "quill://record")!) {
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          QuillMark(iconHeight: 17, textSize: 16)
          Spacer()
        }

        Spacer()

        VStack(alignment: .leading, spacing: 2) {
          Text("Dictate")
            .font(.title2.weight(.bold))
            .foregroundStyle(.white)
          Text("Tap to record a new note")
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.75))
        }

        HStack {
          Spacer()
          ZStack {
            Circle()
              .fill(Color.white.opacity(0.2))
              .frame(width: 40, height: 40)
            Image(systemName: "mic.fill")
              .font(.system(size: 18, weight: .semibold))
              .foregroundStyle(.white)
          }
        }
      }
    }
    .buttonStyle(.plain)
  }
}

private struct MediumView: View {
  let entry: QuillWidgetEntry

  var body: some View {
    HStack(spacing: 14) {
      Link(destination: URL(string: "quill://record")!) {
        VStack(alignment: .leading, spacing: 8) {
          QuillMark(iconHeight: 18, textSize: 17)
          Spacer()
          Text("Dictate")
            .font(.title3.weight(.bold))
            .foregroundStyle(.white)
          Text("Tap to record")
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.75))
        }
        .frame(maxWidth: 120, alignment: .leading)
      }
      .buttonStyle(.plain)

      Rectangle()
        .fill(Color.white.opacity(0.18))
        .frame(width: 1)

      Link(destination: URL(string: "quill://notes")!) {
        VStack(alignment: .leading, spacing: 6) {
          Text("Latest Note")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white.opacity(0.7))

          if let snapshot = entry.snapshot, !snapshot.title.isEmpty {
            Text(snapshot.title)
              .font(.headline)
              .foregroundStyle(.white)
              .lineLimit(1)
            Text(snapshot.preview)
              .font(.caption)
              .foregroundStyle(.white.opacity(0.85))
              .lineLimit(3)
            Spacer()
            // Format the timestamp as an absolute "updated N ago"
            // label instead of WidgetKit's `.relative` style, which
            // continuously counts up and reads like a live recording
            // timer. Computed at render time and only updated when
            // the timeline refreshes, so this string is stable
            // between widget reloads.
            Text("Updated \(Self.relativeUpdatedLabel(snapshot.updatedAt))")
              .font(.caption2)
              .foregroundStyle(.white.opacity(0.6))
          } else {
            Text("No notes yet")
              .font(.headline)
              .foregroundStyle(.white)
            Text("Record your first one — it'll show up here.")
              .font(.caption)
              .foregroundStyle(.white.opacity(0.75))
              .lineLimit(3)
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
      }
      .buttonStyle(.plain)
    }
  }

  /// Compact "5m", "2h", "3d" style label for how long ago a note was
  /// last updated. Prefix the return value with "Updated " at the
  /// call site to read as "Updated 5m ago".
  private static func relativeUpdatedLabel(_ date: Date) -> String {
    let seconds = Date().timeIntervalSince(date)
    if seconds < 60 {
      return "just now"
    }
    let minutes = Int(seconds / 60)
    if minutes < 60 {
      return "\(minutes)m ago"
    }
    let hours = Int(seconds / 3600)
    if hours < 24 {
      return "\(hours)h ago"
    }
    let days = Int(seconds / 86400)
    if days < 7 {
      return "\(days)d ago"
    }
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .none
    return formatter.string(from: date)
  }
}

// MARK: - Shared snapshot (lives in HexCore so both targets can read it)

/// Note: the concrete `QuillWidgetSnapshot` definition lives in
/// `HexCore/Sources/HexCore/Models/QuillWidgetSnapshot.swift` so
/// the main app can encode and the widget can decode against the
/// same type. Imported here via `@_exported` from HexCore.
///
/// See `QuillWidgetSnapshot.load()` / `.write(...)` in that file.
