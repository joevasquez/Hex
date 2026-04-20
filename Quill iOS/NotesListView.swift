//
//  NotesListView.swift
//  Quill (iOS)
//
//  Sheet that lists all saved notes, lets the user pick one to make
//  active, and supports swipe-to-delete. Card style mirrors the macOS
//  HistoryFeature's TranscriptView (rounded container, body preview,
//  divider, metadata footer).
//

import SwiftUI

struct NotesListView: View {
  @ObservedObject var store: NotesStore
  @Environment(\.dismiss) private var dismiss
  @State private var renamingNoteID: UUID?
  @State private var renameDraft: String = ""

  var body: some View {
    NavigationStack {
      Group {
        if store.notes.isEmpty {
          ContentUnavailableView {
            Label("No Notes Yet", systemImage: "note.text")
          } description: {
            Text("Record something on the main screen to create your first note.")
          }
        } else {
          ScrollView {
            LazyVStack(spacing: 12) {
              ForEach(store.sortedNotes) { note in
                NoteRow(
                  note: note,
                  isActive: note.id == store.activeNoteID,
                  onTap: {
                    store.setActiveNote(id: note.id)
                    UISelectionFeedbackGenerator().selectionChanged()
                    dismiss()
                  },
                  onRename: {
                    renameDraft = note.title
                    renamingNoteID = note.id
                  },
                  onDelete: {
                    store.deleteNote(id: note.id)
                    UINotificationFeedbackGenerator().notificationOccurred(.warning)
                  }
                )
              }
            }
            .padding()
          }
        }
      }
      .alert("Rename Note", isPresented: Binding(
        get: { renamingNoteID != nil },
        set: { if !$0 { renamingNoteID = nil } }
      )) {
        TextField("Title", text: $renameDraft)
        Button("Save") {
          if let id = renamingNoteID {
            store.renameNote(id: id, to: renameDraft.trimmingCharacters(in: .whitespacesAndNewlines))
          }
          renamingNoteID = nil
        }
        Button("Cancel", role: .cancel) { renamingNoteID = nil }
      } message: {
        Text("Leave blank to auto-derive from the first line of the note.")
      }
      .navigationTitle("Notes")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
        ToolbarItem(placement: .topBarLeading) {
          Button {
            let new = store.startNewNote(location: nil)
            _ = new
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            dismiss()
          } label: {
            Label("New", systemImage: "square.and.pencil")
          }
        }
      }
    }
  }
}

// MARK: - NoteRow

private struct NoteRow: View {
  let note: Note
  let isActive: Bool
  let onTap: () -> Void
  let onRename: () -> Void
  let onDelete: () -> Void

  var body: some View {
    Button(action: onTap) {
      VStack(alignment: .leading, spacing: 0) {
        // Body preview + title
        VStack(alignment: .leading, spacing: 6) {
          HStack {
            Text(note.displayTitle)
              .font(.headline)
              .lineLimit(1)
              .foregroundStyle(.primary)
            if isActive {
              Text("Active")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(
                  Capsule().fill(Color.purple.opacity(0.18))
                )
                .foregroundStyle(.purple)
            }
            Spacer()
          }

          if !note.body.isEmpty {
            let preview = NoteContent.stripPhotos(from: note.body)
            if preview.isEmpty {
              Label("\(note.photoCount) photo\(note.photoCount == 1 ? "" : "s")",
                    systemImage: "photo")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            } else {
              Text(preview)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            }
          } else {
            Text("Empty")
              .font(.subheadline)
              .foregroundStyle(.tertiary)
              .italic()
          }
        }
        .padding(12)

        Divider()

        // Metadata footer — location · relative date · time · word count
        HStack(spacing: 6) {
          if let place = note.location?.placeName {
            Image(systemName: "location.fill")
            Text(place).lineLimit(1)
            Text("·")
          }
          Image(systemName: "clock")
          Text(note.updatedAt.quillRelativeFormatted())
          Text("·")
          Text(note.updatedAt.formatted(date: .omitted, time: .shortened))
          Text("·")
          Text("\(note.wordCount) words")
          if note.photoCount > 0 {
            Text("·")
            Image(systemName: "photo")
            Text("\(note.photoCount)")
          }
          Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
      }
      .background(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .fill(Color(.secondarySystemBackground))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .stroke(isActive ? Color.purple.opacity(0.5) : Color.secondary.opacity(0.15),
                  lineWidth: isActive ? 1.5 : 1)
      )
    }
    .buttonStyle(.plain)
    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
      Button(role: .destructive, action: onDelete) {
        Label("Delete", systemImage: "trash")
      }
    }
    // SwiftUI's swipeActions only work inside List, but VStack/ScrollView
    // users expect swipe-to-delete too. Fall back to a long-press menu for
    // consistent discoverability.
    .contextMenu {
      Button(action: onRename) {
        Label("Rename", systemImage: "pencil")
      }
      Button(role: .destructive, action: onDelete) {
        Label("Delete", systemImage: "trash")
      }
    }
  }
}

// MARK: - Date formatting (mirrors macOS Date.relativeFormatted)

extension Date {
  func quillRelativeFormatted() -> String {
    let calendar = Calendar.current
    if calendar.isDateInToday(self) { return "Today" }
    if calendar.isDateInYesterday(self) { return "Yesterday" }
    if let daysAgo = calendar.dateComponents([.day], from: self, to: Date()).day,
       daysAgo < 7 {
      let f = DateFormatter()
      f.dateFormat = "EEEE"
      return f.string(from: self)
    }
    return self.formatted(date: .abbreviated, time: .omitted)
  }
}
