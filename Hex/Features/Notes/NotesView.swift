#if os(macOS)
import AppKit
import ComposableArchitecture
import HexCore
import Sharing
import SwiftUI

/// Read-only viewer for cloud-synced notes that originated on iOS.
/// Two-pane layout: list on the left, detail on the right. Mirrors the
/// shape of `HistoryView` so the feel is consistent with Transcripts.
/// Edit/delete on Mac is a future addition; V1 is "see your iPhone notes."
struct NotesView: View {
  @ObservedObject private var cloudSync = MacCloudSync.shared
  @ObservedObject private var photoStore = MacPhotoStore.shared
  @State private var selectedNoteID: UUID?
  @State private var isManuallyRefreshing = false

  private var sortedNotes: [SyncableNote] {
    cloudSync.cloudNotes.sorted { $0.updatedAt > $1.updatedAt }
  }

  var body: some View {
    NavigationSplitView {
      list
        .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 400)
    } detail: {
      detail
    }
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          refresh()
        } label: {
          if case .syncing = cloudSync.status {
            ProgressView().controlSize(.small)
          } else {
            Image(systemName: "arrow.triangle.2.circlepath")
          }
        }
        .help("Refresh from cloud")
        .disabled(isSyncing)
      }
    }
    .task {
      // First open: fetch latest from cloud so the list isn't empty
      // until the user clicks refresh.
      refresh()
    }
  }

  // MARK: - List

  @ViewBuilder
  private var list: some View {
    if sortedNotes.isEmpty {
      VStack(spacing: 12) {
        Image(systemName: "note.text")
          .font(.system(size: 36))
          .foregroundStyle(.tertiary)
        Text("No synced notes yet")
          .font(.headline)
        Text("Notes you create on iPhone with Cloud Sync on will appear here.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .padding(.horizontal)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      List(selection: $selectedNoteID) {
        ForEach(sortedNotes) { note in
          NoteListRow(note: note)
            .tag(Optional(note.id))
        }
      }
      .listStyle(.sidebar)
    }
  }

  // MARK: - Detail

  @ViewBuilder
  private var detail: some View {
    if let id = selectedNoteID, let note = sortedNotes.first(where: { $0.id == id }) {
      NoteDetailView(note: note, photoStore: photoStore)
    } else if !sortedNotes.isEmpty {
      Text("Select a note")
        .foregroundStyle(.secondary)
    } else {
      EmptyView()
    }
  }

  private var isSyncing: Bool {
    if case .syncing = cloudSync.status { return true }
    return false
  }

  private func refresh() {
    @Shared(.transcriptionHistory) var history: TranscriptionHistory
    Task {
      await cloudSync.syncTranscripts(history.history)
    }
  }
}

// MARK: - Row

private struct NoteListRow: View {
  let note: SyncableNote

  private var displayTitle: String {
    let trimmed = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty { return trimmed }
    let stripped = NoteContent.stripPhotos(from: note.body)
    let firstLine = stripped.components(separatedBy: .newlines).first ?? stripped
    let words = firstLine.split(separator: " ", omittingEmptySubsequences: true).prefix(6).joined(separator: " ")
    return words.isEmpty ? "New Note" : String(words.prefix(60))
  }

  private var preview: String {
    let cleaned = NoteContent.stripPhotos(from: note.body)
    return String(cleaned.prefix(120))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(displayTitle)
        .font(.headline)
        .lineLimit(1)
      if !preview.isEmpty {
        Text(preview)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
      HStack(spacing: 6) {
        Text(note.updatedAt, format: .relative(presentation: .named))
          .font(.caption2)
          .foregroundStyle(.tertiary)
        if note.sourcePlatform == .iOS {
          Label("iOS", systemImage: "iphone")
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
      }
    }
    .padding(.vertical, 4)
  }
}

// MARK: - Detail

private struct NoteDetailView: View {
  let note: SyncableNote
  @ObservedObject var photoStore: MacPhotoStore

  private var segments: [NoteSegment] {
    NoteContent.segments(from: note.body)
  }

  var body: some View {
    ScrollView {
      // Outer HStack with a trailing Spacer is the trick to keep the
      // 720pt-wide content anchored to the leading edge instead of
      // SwiftUI centering it within the ScrollView's available width.
      HStack(alignment: .top, spacing: 0) {
        VStack(alignment: .leading, spacing: 16) {
          VStack(alignment: .leading, spacing: 6) {
            Text(displayTitle)
              .font(.title2.bold())
            HStack(spacing: 8) {
              Text(note.updatedAt, format: .dateTime.weekday(.wide).month().day().hour().minute())
                .font(.caption)
                .foregroundStyle(.secondary)
              if let place = note.placeName {
                Label(place, systemImage: "mappin.and.ellipse")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
          }
          Divider()

          ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
            segmentView(seg)
          }
        }
        .padding(20)
        .frame(maxWidth: 720, alignment: .leading)

        Spacer(minLength: 0)
      }
    }
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          copyText()
        } label: {
          Image(systemName: "doc.on.doc")
        }
        .help("Copy note text")
      }
    }
  }

  private var displayTitle: String {
    let trimmed = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty { return trimmed }
    let stripped = NoteContent.stripPhotos(from: note.body)
    return stripped.components(separatedBy: .newlines).first ?? "Untitled"
  }

  @ViewBuilder
  private func segmentView(_ segment: NoteSegment) -> some View {
    switch segment {
    case .text(let text):
      NoteTextView(text: text)
        .textSelection(.enabled)
    case .photo(let photoID):
      if let image = photoStore.image(noteID: note.id, photoID: photoID) {
        Image(nsImage: image)
          .resizable()
          .scaledToFit()
          .frame(maxWidth: 600)
          .clipShape(RoundedRectangle(cornerRadius: 12))
      } else {
        // Photo manifest may have arrived but the JPEG hasn't downloaded
        // yet (or the download failed). Show a placeholder so the user
        // knows something is missing rather than rendering nothing.
        VStack(spacing: 6) {
          Image(systemName: "photo")
            .font(.system(size: 28))
            .foregroundStyle(.tertiary)
          Text("Photo not yet downloaded")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
      }
    }
  }

  private func copyText() {
    let text = NoteContent.stripPhotos(from: note.body)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }
}
#endif
