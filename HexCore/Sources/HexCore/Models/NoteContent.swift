//
//  NoteContent.swift
//  HexCore (cross-platform)
//
//  Tokenizer for the flat note body string. Photos are embedded inline
//  as markdown-style tokens: `![photo](<uuid>)`. This file turns a body
//  into a segment list for rendering and provides a stripped form for
//  share/copy/preview surfaces where the token would be meaningless.
//
//  Lives in HexCore so both the iOS and macOS targets can render note
//  bodies the same way (iOS authors notes, macOS view-only renders
//  cloud-synced ones).
//

import Foundation

public enum NoteSegment: Equatable, Sendable {
  case text(String)
  case photo(UUID)
}

public enum NoteContent {
  private static let tokenRegex: NSRegularExpression = {
    try! NSRegularExpression(pattern: #"!\[photo\]\(([0-9A-Fa-f-]{36})\)"#)
  }()

  public static func photoToken(for photoID: UUID) -> String {
    "![photo](\(photoID.uuidString))"
  }

  public static func segments(from body: String) -> [NoteSegment] {
    let ns = body as NSString
    let range = NSRange(location: 0, length: ns.length)
    let matches = tokenRegex.matches(in: body, range: range)
    guard !matches.isEmpty else {
      let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? [] : [.text(trimmed)]
    }

    var segments: [NoteSegment] = []
    var cursor = 0
    for m in matches {
      if m.range.location > cursor {
        let chunk = ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
          .trimmingCharacters(in: .whitespacesAndNewlines)
        if !chunk.isEmpty { segments.append(.text(chunk)) }
      }
      let uuidString = ns.substring(with: m.range(at: 1))
      if let uuid = UUID(uuidString: uuidString) {
        segments.append(.photo(uuid))
      }
      cursor = m.range.location + m.range.length
    }
    if cursor < ns.length {
      let tail = ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if !tail.isEmpty { segments.append(.text(tail)) }
    }
    return segments
  }

  public static func stripPhotos(from body: String) -> String {
    let ns = body as NSString
    let range = NSRange(location: 0, length: ns.length)
    var stripped = tokenRegex.stringByReplacingMatches(in: body, range: range, withTemplate: "")
    while stripped.contains("\n\n\n") {
      stripped = stripped.replacingOccurrences(of: "\n\n\n", with: "\n\n")
    }
    return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public static func photoIDs(in body: String) -> [UUID] {
    segments(from: body).compactMap { seg in
      if case .photo(let id) = seg { return id }
      return nil
    }
  }
}
