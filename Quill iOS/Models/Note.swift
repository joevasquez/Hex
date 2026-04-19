//
//  Note.swift
//  Quill (iOS)
//
//  Local-only note model. Each note is a flat text blob that recordings
//  append to. The "active" note is tracked separately in NotesStore —
//  every recording extends the active note unless the user explicitly
//  starts a new one.
//

import Foundation

struct Note: Codable, Identifiable, Equatable, Hashable {
  var id: UUID
  var title: String
  var body: String
  var createdAt: Date
  var updatedAt: Date
  /// Where the note was started. Captured once at creation when location
  /// permission is granted; never updated on subsequent appends so the
  /// value reflects "where this thought began."
  var location: NoteLocation?

  init(
    id: UUID = UUID(),
    title: String = "",
    body: String = "",
    createdAt: Date = Date(),
    updatedAt: Date? = nil,
    location: NoteLocation? = nil
  ) {
    self.id = id
    self.title = title
    self.body = body
    self.createdAt = createdAt
    self.updatedAt = updatedAt ?? createdAt
    self.location = location
  }

  /// Derive a title from the first meaningful line of body text.
  /// Used when a user hasn't set a custom title yet.
  static func derivedTitle(from body: String) -> String {
    let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "New Note" }

    let firstLine = trimmed.components(separatedBy: .newlines).first ?? trimmed
    let words = firstLine.split(separator: " ", omittingEmptySubsequences: true).prefix(6)
    let candidate = words.joined(separator: " ")
    let clipped = String(candidate.prefix(60))
    return clipped.isEmpty ? "New Note" : clipped
  }

  var displayTitle: String {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? Note.derivedTitle(from: body) : trimmed
  }

  var wordCount: Int {
    body.split { $0.isWhitespace || $0.isNewline }.count
  }
}

struct NoteLocation: Codable, Equatable, Hashable {
  var latitude: Double
  var longitude: Double
  /// Best-effort reverse-geocoded label (e.g. "Brooklyn, NY"). Optional
  /// because the geocode may fail even when we have coordinates.
  var placeName: String?
}
