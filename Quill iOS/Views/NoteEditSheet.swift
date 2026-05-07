//
//  NoteEditSheet.swift
//  Quill (iOS)
//
//  Modal editor for the active note's body. Sheet presentation so the
//  user can scroll through and revise the full note in a focused view.
//  Photo tokens (`![photo](<uuid>)`) are preserved verbatim so inline
//  photos still render after the edit lands. We don't try to render
//  photos inside the editor itself — that would require a custom
//  AttributedString-backed control. Instead we surface a small footer
//  hint and let the user see/edit the raw tokens.
//

import HexCore
import SwiftUI

struct NoteEditSheet: View {
  let note: Note
  @Environment(\.dismiss) private var dismiss
  @ObservedObject private var notesStore = NotesStore.shared

  @State private var draftBody: String
  @State private var draftTitle: String
  @FocusState private var bodyFocused: Bool

  init(note: Note) {
    self.note = note
    self._draftBody = State(initialValue: note.body)
    self._draftTitle = State(initialValue: note.title)
  }

  private var hasPhotoTokens: Bool {
    !NoteContent.photoIDs(in: note.body).isEmpty
  }

  private var hasChanges: Bool {
    draftBody != note.body || draftTitle != note.title
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("Title") {
          TextField("Title", text: $draftTitle)
            .textInputAutocapitalization(.sentences)
        }

        Section {
          TextEditor(text: $draftBody)
            .focused($bodyFocused)
            .frame(minHeight: 280)
            .scrollContentBackground(.hidden)
        } header: {
          Text("Body")
        } footer: {
          if hasPhotoTokens {
            Text("This note has inline photos. Don't edit the `![photo](...)` markers — they tell Quill where each photo belongs.")
              .font(.caption)
              .foregroundStyle(.orange)
          } else {
            Text("Plain text. Saved changes sync to the cloud automatically when cloud sync is on.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
      .navigationTitle("Edit Note")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") {
            commit()
            dismiss()
          }
          .disabled(!hasChanges)
        }
      }
      .onAppear { bodyFocused = true }
    }
  }

  private func commit() {
    let trimmedTitle = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmedTitle != note.title.trimmingCharacters(in: .whitespacesAndNewlines) {
      notesStore.renameNote(id: note.id, to: trimmedTitle)
    }
    if draftBody != note.body {
      notesStore.updateBody(id: note.id, to: draftBody)
    }
  }
}
