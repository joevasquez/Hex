//
//  NotesStore.swift
//  Quill (iOS)
//
//  Simple JSON-backed note persistence in the app's Documents directory.
//  Holds the full note list in memory and serializes to disk on every
//  mutation. A "flat list of notes" is small enough that this is fine —
//  no need for SwiftData overhead.
//
//  Also tracks the "active" note ID in UserDefaults. Every recording
//  appends to whichever note is active. If no active note exists, a
//  new one is created on demand.
//

import Combine
import Foundation
import SwiftUI

@MainActor
final class NotesStore: ObservableObject {
  static let shared = NotesStore()

  @Published private(set) var notes: [Note] = []
  @Published private(set) var activeNoteID: UUID?

  private let fileURL: URL
  private let activeNoteKey = "quill.activeNoteID"

  private init() {
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    self.fileURL = docs.appendingPathComponent("notes.json")
    load()
    restoreActiveNoteID()
  }

  // MARK: - Queries

  var activeNote: Note? {
    guard let id = activeNoteID else { return nil }
    return notes.first(where: { $0.id == id })
  }

  /// Sort descending by updatedAt so freshly-touched notes float to the top
  /// — matches the Mac transcription history order.
  var sortedNotes: [Note] {
    notes.sorted { $0.updatedAt > $1.updatedAt }
  }

  // MARK: - Mutations

  /// Append text to the active note. If no active note exists yet, creates
  /// one (capturing location from the optional snapshot) and makes it
  /// active. Returns the note that was written to.
  @discardableResult
  func appendToActiveNote(_ text: String, locationIfCreating: NoteLocation?) -> Note {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return activeNote ?? startNewNote(location: nil) }

    let now = Date()
    if let idx = activeNoteIndex() {
      // Append with a blank line separator so successive recordings read
      // as paragraphs rather than running together.
      var note = notes[idx]
      if note.body.isEmpty {
        note.body = trimmed
      } else {
        note.body += "\n\n" + trimmed
      }
      note.updatedAt = now
      notes[idx] = note
      save()
      return note
    } else {
      // No active note — create one seeded with this text.
      var note = Note(
        title: Note.derivedTitle(from: trimmed),
        body: trimmed,
        createdAt: now,
        updatedAt: now,
        location: locationIfCreating
      )
      // If derivedTitle ran on the trimmed body, there's nothing more to do.
      _ = note  // silence shadow
      note.updatedAt = now
      notes.append(note)
      setActiveNote(id: note.id)
      save()
      return note
    }
  }

  /// Create a brand-new, empty note and make it active. Caller is expected
  /// to pass a location snapshot if one is available.
  @discardableResult
  func startNewNote(location: NoteLocation?) -> Note {
    let note = Note(
      title: "",
      body: "",
      createdAt: Date(),
      location: location
    )
    notes.append(note)
    setActiveNote(id: note.id)
    save()
    return note
  }

  func setActiveNote(id: UUID?) {
    activeNoteID = id
    if let id {
      UserDefaults.standard.set(id.uuidString, forKey: activeNoteKey)
    } else {
      UserDefaults.standard.removeObject(forKey: activeNoteKey)
    }
  }

  func renameNote(id: UUID, to title: String) {
    guard let idx = notes.firstIndex(where: { $0.id == id }) else { return }
    notes[idx].title = title
    notes[idx].updatedAt = Date()
    save()
  }

  func updateBody(id: UUID, to body: String) {
    guard let idx = notes.firstIndex(where: { $0.id == id }) else { return }
    notes[idx].body = body
    notes[idx].updatedAt = Date()
    save()
  }

  func deleteNote(id: UUID) {
    notes.removeAll { $0.id == id }
    if activeNoteID == id {
      // If we deleted the active one, fall back to the most-recent remaining
      // note, or clear active if the list is empty.
      setActiveNote(id: sortedNotes.first?.id)
    }
    save()
  }

  // MARK: - Persistence

  private func activeNoteIndex() -> Int? {
    guard let id = activeNoteID else { return nil }
    return notes.firstIndex(where: { $0.id == id })
  }

  private func load() {
    guard let data = try? Data(contentsOf: fileURL) else { return }
    do {
      let decoded = try JSONDecoder.notes.decode([Note].self, from: data)
      self.notes = decoded
    } catch {
      // Corrupted or schema-mismatched file — log but don't crash.
      print("NotesStore: failed to decode notes.json: \(error)")
    }
  }

  private func save() {
    do {
      let data = try JSONEncoder.notes.encode(notes)
      try data.write(to: fileURL, options: [.atomic])
    } catch {
      print("NotesStore: failed to persist notes.json: \(error)")
    }
  }

  private func restoreActiveNoteID() {
    guard let raw = UserDefaults.standard.string(forKey: activeNoteKey),
          let uuid = UUID(uuidString: raw),
          notes.contains(where: { $0.id == uuid })
    else { return }
    self.activeNoteID = uuid
  }
}

private extension JSONEncoder {
  static let notes: JSONEncoder = {
    let e = JSONEncoder()
    e.dateEncodingStrategy = .iso8601
    e.outputFormatting = [.prettyPrinted, .sortedKeys]
    return e
  }()
}

private extension JSONDecoder {
  static let notes: JSONDecoder = {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .iso8601
    return d
  }()
}
