//
//  NoteTextView.swift
//  Quill (iOS)
//
//  Renders a chunk of note body text with light markdown awareness:
//  `- ` and `* ` become visual bullets with a real `•` glyph,
//  `**Heading**` / `## Heading` render as bold headings, and inline
//  markdown (bold, italic, code, links) is rendered via
//  `AttributedString(markdown:)`. SwiftUI's built-in `Text(markdown:)`
//  doesn't do block-level lists, so we walk line-by-line and stack
//  the pieces vertically — otherwise Notes-mode output shows up as
//  literal hyphens instead of proper bullets.
//

import SwiftUI

struct NoteTextView: View {
  let text: String
  var font: Font = .body
  var textColor: Color = .primary
  var bulletColor: Color = .secondary
  var headingColor: Color? = nil

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
        render(line: line)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var lines: [String] {
    text.components(separatedBy: "\n")
  }

  @ViewBuilder
  private func render(line: String) -> some View {
    let leadingSpaces = line.prefix { $0 == " " }.count
    let trimmed = line.trimmingCharacters(in: .whitespaces)

    if trimmed.isEmpty {
      // Preserve paragraph-break spacing without an empty `Text` (which
      // collapses to zero height in a VStack).
      Color.clear.frame(height: 6)
    } else if let heading = matchHeading(trimmed) {
      Text(inline(heading))
        .font(font.weight(.bold))
        .foregroundStyle(headingColor ?? textColor)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    } else if let bullet = matchBullet(trimmed) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text("•")
          .font(font)
          .foregroundStyle(bulletColor)
        Text(inline(bullet))
          .font(font)
          .foregroundStyle(textColor)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(.leading, CGFloat(leadingSpaces) * 6)
    } else {
      Text(inline(trimmed))
        .font(font)
        .foregroundStyle(textColor)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func matchBullet(_ s: String) -> String? {
    if s.hasPrefix("- ") { return String(s.dropFirst(2)) }
    if s.hasPrefix("* ") { return String(s.dropFirst(2)) }
    if s.hasPrefix("• ") { return String(s.dropFirst(2)) }
    return nil
  }

  /// Recognizes `**Bold heading**` / `## Heading` / `# Heading` — the
  /// formats the Notes prompt asks the model to produce.
  private func matchHeading(_ s: String) -> String? {
    if s.hasPrefix("**"), s.hasSuffix("**"), s.count > 4 {
      return String(s.dropFirst(2).dropLast(2))
    }
    if s.hasPrefix("### ") { return String(s.dropFirst(4)) }
    if s.hasPrefix("## ") { return String(s.dropFirst(3)) }
    if s.hasPrefix("# ") { return String(s.dropFirst(2)) }
    return nil
  }

  private func inline(_ s: String) -> AttributedString {
    (try? AttributedString(
      markdown: s,
      options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    )) ?? AttributedString(s)
  }
}
