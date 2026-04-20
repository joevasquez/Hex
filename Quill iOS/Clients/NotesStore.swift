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
import HexCore
import SwiftUI
import UIKit

@MainActor
final class NotesStore: ObservableObject {
  static let shared = NotesStore()

  @Published private(set) var notes: [Note] = []
  @Published private(set) var activeNoteID: UUID?
  /// Cached AI analyses keyed by photo UUID. Populated from disk on
  /// launch and updated in-place when a new analysis lands; views bind
  /// to this so they auto-refresh when an async vision call completes.
  @Published private(set) var photoAnalyses: [UUID: PhotoAnalysis] = [:]
  /// Photo UUIDs currently being analyzed — the renderer shows a
  /// spinner next to these until they drop out of the set.
  @Published private(set) var analyzingPhotoIDs: Set<UUID> = []
  /// Last error seen per photo (if analysis failed). Keyed by photo ID
  /// so the UI can surface a localized hint on the offending card.
  @Published private(set) var analysisErrors: [UUID: String] = [:]

  private let fileURL: URL
  private let activeNoteKey = "quill.activeNoteID"

  private init() {
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    self.fileURL = docs.appendingPathComponent("notes.json")
    load()
    restoreActiveNoteID()
    loadAllAnalysesFromDisk()
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
    PhotoStore.shared.deleteAllPhotos(noteID: id)
    if activeNoteID == id {
      // If we deleted the active one, fall back to the most-recent remaining
      // note, or clear active if the list is empty.
      setActiveNote(id: sortedNotes.first?.id)
    }
    save()
  }

  /// Save `image` to disk, make sure there's an active note to attach it
  /// to (creating one with the given location if not), and append a
  /// `![photo](<uuid>)` token to the body. Returns the IDs of the note
  /// and photo so the caller can kick off background analysis.
  @discardableResult
  func insertPhotoIntoActiveNote(
    _ image: UIImage,
    locationIfCreating: NoteLocation?
  ) -> (noteID: UUID, photoID: UUID)? {
    let targetID: UUID
    if let id = activeNoteID {
      targetID = id
    } else {
      targetID = startNewNote(location: locationIfCreating).id
    }

    do {
      let photoID = try PhotoStore.shared.savePhoto(image, for: targetID)
      guard let idx = notes.firstIndex(where: { $0.id == targetID }) else { return nil }
      let token = NoteContent.photoToken(for: photoID)
      var note = notes[idx]
      if note.body.isEmpty {
        note.body = token
      } else {
        note.body += "\n\n" + token
      }
      note.updatedAt = Date()
      notes[idx] = note
      save()
      return (targetID, photoID)
    } catch {
      print("NotesStore: failed to save photo: \(error)")
      return nil
    }
  }

  // MARK: - Photo analyses

  /// Walk every note's body on launch and load any `<photo-id>.json`
  /// sidecars into the published map. Keeps analyses visible across
  /// app restarts without re-calling the vision API.
  private func loadAllAnalysesFromDisk() {
    var out: [UUID: PhotoAnalysis] = [:]
    for note in notes {
      for photoID in NoteContent.photoIDs(in: note.body) {
        if let a = PhotoStore.shared.loadAnalysis(noteID: note.id, photoID: photoID) {
          out[photoID] = a
        }
      }
    }
    photoAnalyses = out
  }

  /// Fire-and-forget: ship the photo to the configured vision LLM,
  /// persist the result as a sidecar, and publish it. If the user has
  /// no API key for the chosen provider, record a localized error
  /// instead of blowing up.
  func analyzePhoto(noteID: UUID, photoID: UUID, provider: AIProvider) {
    // Guard against duplicate in-flight requests for the same photo
    // (e.g. user taps Retry twice).
    guard !analyzingPhotoIDs.contains(photoID) else { return }
    analyzingPhotoIDs.insert(photoID)
    analysisErrors[photoID] = nil

    Task { @MainActor in
      defer { analyzingPhotoIDs.remove(photoID) }

      guard let data = PhotoStore.shared.imageData(noteID: noteID, photoID: photoID) else {
        analysisErrors[photoID] = "Photo file not found on disk."
        return
      }

      do {
        let analysis = try await PhotoAnalysisClient.analyze(imageData: data, provider: provider)
        try? PhotoStore.shared.saveAnalysis(analysis, noteID: noteID, photoID: photoID)
        photoAnalyses[photoID] = analysis
      } catch {
        analysisErrors[photoID] = error.localizedDescription
        print("NotesStore: photo analysis failed for \(photoID): \(error)")
      }
    }
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
