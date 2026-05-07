//
//  NoteTextView.swift
//  HexCore (cross-platform)
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
//  Lives in HexCore so iOS notes and the macOS synced-notes viewer
//  render identically.
//

import SwiftUI

public struct NoteTextView: View {
  public let text: String
  public var font: Font = .body
  public var textColor: Color = .primary
  public var bulletColor: Color = .primary
  public var headingColor: Color? = nil

  public init(
    text: String,
    font: Font = .body,
    textColor: Color = .primary,
    bulletColor: Color = .primary,
    headingColor: Color? = nil
  ) {
    self.text = text
    self.font = font
    self.textColor = textColor
    self.bulletColor = bulletColor
    self.headingColor = headingColor
  }

  public var body: some View {
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
      Color.clear.frame(height: 6)
    } else if let heading = matchHeading(trimmed) {
      Text(inline(heading))
        .font(font.weight(.bold))
        .foregroundStyle(headingColor ?? textColor)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 16)
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
