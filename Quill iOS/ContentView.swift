//
//  ContentView.swift
//  Quill (iOS)
//
//  Main screen: record → transcribe → optional AI clean-up → share.
//

import AVFoundation
import Combine
import HexCore
import SwiftUI
import UIKit
import WhisperKit

@MainActor
final class RecordingViewModel: ObservableObject {
  enum Phase: Equatable {
    case idle
    case requestingPermission
    case recording
    case transcribing
    case aiProcessing
    case done
    case error(String)
  }

  @Published var phase: Phase = .idle
  @Published var rawTranscript: String = ""
  @Published var processedTranscript: String = ""
  @Published var livePartial: String = ""
  @Published var meterLevel: Float = 0
  @Published var elapsedSeconds: TimeInterval = 0
  /// Set when an AI post-processing call failed and we fell back to
  /// the raw transcript. Cleared on the next successful run.
  @Published var aiErrorMessage: String?

  private var recorder = IOSRecordingClient.shared
  private var whisperKit: WhisperKit?
  private var timerTask: Task<Void, Never>?
  private var recordingStartedAt: Date?
  private var cancellables: Set<AnyCancellable> = []

  init() {
    // Mirror the recorder's published live partial onto our own @Published so
    // SwiftUI views observing the VM get live updates during recording.
    recorder.$livePartialTranscript
      .receive(on: RunLoop.main)
      .sink { [weak self] text in
        self?.livePartial = text
      }
      .store(in: &cancellables)
  }

  var displayedText: String {
    processedTranscript.isEmpty ? rawTranscript : processedTranscript
  }

  var hasResult: Bool {
    !rawTranscript.isEmpty
  }

  func toggleRecording(
    model: String,
    mode: AIProcessingMode,
    provider: AIProvider
  ) async {
    switch phase {
    case .idle, .done, .error:
      await startRecording(model: model, mode: mode, provider: provider)
    case .recording:
      await stopAndProcess(model: model, mode: mode, provider: provider)
    default:
      break
    }
  }

  private func startRecording(
    model: String,
    mode: AIProcessingMode,
    provider: AIProvider
  ) async {
    phase = .requestingPermission
    let granted = await recorder.requestPermission()
    guard granted else {
      phase = .error("Microphone permission required. Enable it in Settings > Quill.")
      return
    }

    // Speech recognition permission is best-effort; failure just disables the
    // live preview (Whisper-based final transcript still works).
    _ = await recorder.requestSpeechPermission()

    rawTranscript = ""
    processedTranscript = ""
    livePartial = ""
    aiErrorMessage = nil

    do {
      _ = try recorder.startRecording()
      recordingStartedAt = Date()
      phase = .recording
      UIImpactFeedbackGenerator(style: .medium).impactOccurred()

      // Meter + elapsed timer
      timerTask?.cancel()
      timerTask = Task { [weak self] in
        while !Task.isCancelled {
          guard let self else { return }
          self.meterLevel = self.recorder.averagePower
          if let start = self.recordingStartedAt {
            self.elapsedSeconds = Date().timeIntervalSince(start)
          }
          try? await Task.sleep(for: .milliseconds(100))
        }
      }
    } catch {
      phase = .error("Couldn't start recording: \(error.localizedDescription)")
    }
  }

  private func stopAndProcess(
    model: String,
    mode: AIProcessingMode,
    provider: AIProvider
  ) async {
    timerTask?.cancel()
    let url = recorder.stopRecording()
    phase = .transcribing
    UIImpactFeedbackGenerator(style: .light).impactOccurred()

    guard let url else {
      phase = .error("Recording file was not produced")
      return
    }

    do {
      if whisperKit == nil || whisperKit?.modelFolder?.lastPathComponent != model {
        whisperKit = try await WhisperKit(
          WhisperKitConfig(model: model, download: true)
        )
      }

      let results = try await whisperKit!.transcribe(audioPath: url.path)
      let rawText = results.map(\.text).joined(separator: " ")
      let text = WhisperOutputCleaner.clean(rawText)
      rawTranscript = text

      try? FileManager.default.removeItem(at: url)

      if text.isEmpty {
        phase = .error("No speech detected. Try again.")
        return
      }

      if mode != .off {
        phase = .aiProcessing
        do {
          processedTranscript = try await TextAIClient.process(text: text, mode: mode, provider: provider)
        } catch {
          // Fall through with the raw transcript so recording isn't
          // lost. The console log tells us why (usually: missing key).
          processedTranscript = ""
          aiErrorMessage = "AI \(mode.displayName) failed — \(error.localizedDescription)"
          print("TextAIClient failed: \(error.localizedDescription)")
        }
      } else {
        aiErrorMessage = nil
      }

      phase = .done
      UINotificationFeedbackGenerator().notificationOccurred(.success)
    } catch {
      phase = .error("Transcription failed: \(error.localizedDescription)")
    }
  }
}

struct ContentView: View {
  @AppStorage(QuillIOSSettingsKey.selectedModel) private var selectedModel: String = QuillIOSSettingsKey.defaultModel
  @AppStorage(QuillIOSSettingsKey.aiProcessingMode) private var aiModeRaw: String = QuillIOSSettingsKey.defaultMode
  @AppStorage(QuillIOSSettingsKey.aiProvider) private var aiProviderRaw: String = QuillIOSSettingsKey.defaultProvider

  @StateObject private var vm = RecordingViewModel()
  @StateObject private var notes = NotesStore.shared
  @State private var showingSettings = false
  @State private var showingNotesList = false
  @State private var idlePulse = false
  @State private var lastAppendedTranscript: String = ""
  @State private var showCopied = false
  @State private var copyResetTask: Task<Void, Never>?
  @State private var showingPhotoSourceDialog = false
  @State private var showingCamera = false
  @State private var showingLibrary = false
  @State private var showingRenameAlert = false
  @State private var renameDraft: String = ""
  @State private var shareRequest: ShareRequest?
  @State private var isBuildingPDF = false
  @State private var pendingDeleteNoteID: UUID?

  private var aiMode: AIProcessingMode {
    AIProcessingMode(rawValue: aiModeRaw) ?? .clean
  }

  private var aiProvider: AIProvider {
    AIProvider(rawValue: aiProviderRaw) ?? .anthropic
  }

  var body: some View {
    NavigationStack {
      ZStack(alignment: .bottomTrailing) {
        backgroundGradient
          .ignoresSafeArea()

        VStack(spacing: 0) {
          headerBar
          activeNoteStrip

          ScrollViewReader { proxy in
            ScrollView {
              VStack(spacing: 20) {
                modeChipRow
                resultArea
                // Reserve space below the note so the floating mic/camera
                // cluster doesn't overlap the last line or action buttons.
                Color.clear.frame(height: 140).id("noteBottom")
              }
              .padding(.horizontal)
              .padding(.top, 16)
            }
            // Animate the outer scroll so the newest transcript/photo
            // lands just above the FAB cluster rather than off-screen.
            .onChange(of: notes.activeNote?.body) { _, _ in
              withAnimation(.easeOut(duration: 0.4)) {
                proxy.scrollTo("noteBottom", anchor: .bottom)
              }
            }
          }
        }

        bottomActionCluster
          .padding(.trailing, 20)
          .padding(.bottom, 24)
      }
      .toolbar(.hidden, for: .navigationBar)
      .sheet(isPresented: $showingSettings) {
        SettingsView()
      }
      .sheet(isPresented: $showingNotesList) {
        NotesListView(store: notes)
      }
      .sheet(isPresented: $showingCamera) {
        CameraPicker { image in
          showingCamera = false
          if let image { handlePickedPhoto(image) }
        }
        .ignoresSafeArea()
      }
      .sheet(isPresented: $showingLibrary) {
        PhotoLibraryPicker { image in
          showingLibrary = false
          if let image { handlePickedPhoto(image) }
        }
      }
      .confirmationDialog("Add Photo", isPresented: $showingPhotoSourceDialog, titleVisibility: .visible) {
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
          Button("Take Photo") { showingCamera = true }
        }
        Button("Choose from Library") { showingLibrary = true }
        Button("Cancel", role: .cancel) {}
      }
      .alert("Rename Note", isPresented: $showingRenameAlert) {
        TextField("Title", text: $renameDraft)
        Button("Save") { commitRename() }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text("Leave blank to auto-derive from the first line of the note.")
      }
      .alert("Delete Note?", isPresented: Binding(
        get: { pendingDeleteNoteID != nil },
        set: { if !$0 { pendingDeleteNoteID = nil } }
      )) {
        Button("Delete", role: .destructive) {
          if let id = pendingDeleteNoteID {
            notes.deleteNote(id: id)
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
          }
          pendingDeleteNoteID = nil
        }
        Button("Cancel", role: .cancel) { pendingDeleteNoteID = nil }
      } message: {
        Text("This removes the note and all attached photos. This can't be undone.")
      }
      .sheet(item: $shareRequest) { req in
        ShareSheet(items: req.items)
      }
      .onAppear { idlePulse = true }
      .onChange(of: vm.phase) { _, newPhase in
        if case .done = newPhase {
          appendTranscriptToActiveNote()
        }
      }
    }
  }

  // MARK: - Photo flow

  /// Tapped from the active-note strip. If a recording is in flight, stop
  /// it first (so the dictated text is committed to the note before the
  /// photo lands), then present the source chooser.
  private func tapAddPhoto() {
    UISelectionFeedbackGenerator().selectionChanged()
    if vm.phase == .recording {
      Task {
        await vm.toggleRecording(
          model: selectedModel,
          mode: aiMode,
          provider: aiProvider
        )
        showingPhotoSourceDialog = true
      }
    } else {
      showingPhotoSourceDialog = true
    }
  }

  private func handlePickedPhoto(_ image: UIImage) {
    Task {
      let loc = notes.activeNote == nil
        ? await LocationClient.shared.currentPlace()
        : nil
      if let ids = notes.insertPhotoIntoActiveNote(image, locationIfCreating: loc) {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        // Fire-and-forget: the store flips `analyzingPhotoIDs` and
        // publishes the result so the view refreshes automatically.
        notes.analyzePhoto(noteID: ids.noteID, photoID: ids.photoID, provider: aiProvider)
      }
    }
  }

  // MARK: - Rename flow

  /// Pre-fill the rename draft with the user's stored title (not the
  /// derived one) so saving an empty string falls back to derivation.
  private func tapRenameTitle() {
    guard let note = notes.activeNote else { return }
    UISelectionFeedbackGenerator().selectionChanged()
    renameDraft = note.title
    showingRenameAlert = true
  }

  private func commitRename() {
    guard let id = notes.activeNoteID else { return }
    let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    notes.renameNote(id: id, to: trimmed)
  }

  // MARK: - Share flow

  private func shareNoteText(_ note: Note) {
    let text = NoteContent.stripPhotos(from: note.body)
    guard !text.isEmpty else { return }
    shareRequest = ShareRequest(items: [text])
  }

  private func sharePDF(_ note: Note) {
    isBuildingPDF = true
    let snapshot = notes.photoAnalyses
    Task { @MainActor in
      defer { isBuildingPDF = false }
      if let url = NotePDFExporter.export(note, analyses: snapshot) {
        shareRequest = ShareRequest(items: [url])
      }
    }
  }

  // MARK: - Custom header

  private var headerBar: some View {
    HStack(spacing: 12) {
      logoMark

      Text("Quill")
        .font(.system(size: 34, weight: .bold, design: .serif))
        .foregroundStyle(.white)
        .kerning(0.5)
        .shadow(color: .black.opacity(0.2), radius: 2, y: 1)

      Spacer()

      Button {
        UISelectionFeedbackGenerator().selectionChanged()
        showingNotesList = true
      } label: {
        Image(systemName: "list.bullet")
          .font(.title3.weight(.semibold))
          .foregroundStyle(.white)
          .frame(width: 36, height: 36)
          .background(Circle().fill(Color.white.opacity(0.18)))
          .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 0.5))
      }
      .buttonStyle(.plain)
      .accessibilityLabel("All notes")

      Button {
        UISelectionFeedbackGenerator().selectionChanged()
        Task {
          let loc = await LocationClient.shared.currentPlace()
          _ = notes.startNewNote(location: loc)
        }
      } label: {
        Image(systemName: "square.and.pencil")
          .font(.title3.weight(.semibold))
          .foregroundStyle(.white)
          .frame(width: 36, height: 36)
          .background(Circle().fill(Color.white.opacity(0.18)))
          .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 0.5))
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Start new note")

      Button {
        UISelectionFeedbackGenerator().selectionChanged()
        showingSettings = true
      } label: {
        Image(systemName: "gearshape")
          .font(.title3.weight(.semibold))
          .foregroundStyle(.white)
          .frame(width: 36, height: 36)
          .background(
            Circle().fill(Color.white.opacity(0.18))
          )
          .overlay(
            Circle().stroke(Color.white.opacity(0.25), lineWidth: 0.5)
          )
      }
      .buttonStyle(.plain)
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 12)
    .background(
      LinearGradient(
        colors: [
          Color(red: 0.25, green: 0.10, blue: 0.45),  // deep purple
          Color(red: 0.40, green: 0.20, blue: 0.65),  // brighter mid
          Color(red: 0.30, green: 0.18, blue: 0.55),  // settled bottom
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      .ignoresSafeArea(edges: .top)
    )
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(Color.black.opacity(0.25))
        .frame(height: 0.5)
    }
    .shadow(color: .purple.opacity(0.2), radius: 8, y: 4)
  }

  private var logoMark: some View {
    Image("Feather")
      .resizable()
      .renderingMode(.template)
      .aspectRatio(contentMode: .fit)
      .foregroundStyle(.white)
      .frame(width: 34, height: 34)
      .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
  }

  // MARK: - Active-note strip

  /// Compact row under the header bar showing which note new recordings
  /// will append to, with controls to start a fresh note or browse all
  /// notes. Sits on the light gradient background (not the dark header).
  private var activeNoteStrip: some View {
    HStack(spacing: 10) {
      Image(systemName: "note.text")
        .font(.subheadline)
        .foregroundStyle(.purple)

      Button(action: tapRenameTitle) {
        VStack(alignment: .leading, spacing: 1) {
          HStack(spacing: 4) {
            Text(notes.activeNote?.displayTitle ?? "No active note")
              .font(.subheadline.weight(.semibold))
              .lineLimit(1)
              .foregroundStyle(.primary)
            if notes.activeNote != nil {
              Image(systemName: "pencil")
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
          }
          Text(activeNoteSubtitle)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      .buttonStyle(.plain)
      .disabled(notes.activeNote == nil)
      .accessibilityLabel("Rename active note")

      Spacer()

    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .background(
      Rectangle()
        .fill(.ultraThinMaterial)
    )
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(Color.primary.opacity(0.06))
        .frame(height: 0.5)
    }
  }

  private var activeNoteSubtitle: String {
    if let note = notes.activeNote {
      var parts: [String] = []
      if let place = note.location?.placeName {
        parts.append(place)
      }
      parts.append("Updated \(note.updatedAt.quillRelativeFormatted().lowercased())")
      parts.append("\(note.wordCount) words")
      return parts.joined(separator: " · ")
    }
    return "Tap record to start your first note"
  }

  // MARK: - Append-on-done

  /// Called whenever the recording VM transitions to .done. Appends the
  /// final transcript (AI-enhanced if a mode was selected, raw otherwise)
  /// to the active note, creating a new one with a location tag if none
  /// exists yet. Guards against double-append by tracking the last
  /// transcript we consumed.
  private func appendTranscriptToActiveNote() {
    let text = vm.displayedText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, text != lastAppendedTranscript else { return }
    lastAppendedTranscript = text

    // If we need to create a new note, fetch location first (best-effort).
    if notes.activeNote == nil {
      Task {
        let loc = await LocationClient.shared.currentPlace()
        notes.appendToActiveNote(text, locationIfCreating: loc)
      }
    } else {
      notes.appendToActiveNote(text, locationIfCreating: nil)
    }
  }

  // MARK: - Background

  private var backgroundGradient: some View {
    LinearGradient(
      colors: [
        Color.purple.opacity(0.08),
        Color.blue.opacity(0.04),
        Color(.systemBackground),
      ],
      startPoint: .topLeading,
      endPoint: .bottomTrailing
    )
  }

  // MARK: - Mode chips

  @ViewBuilder
  private var modeChipRow: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        ForEach(AIProcessingMode.allCases, id: \.rawValue) { mode in
          ModeChip(
            mode: mode,
            isSelected: mode == aiMode,
            action: {
              UISelectionFeedbackGenerator().selectionChanged()
              aiModeRaw = mode.rawValue
            }
          )
        }
      }
      .padding(.horizontal, 4)
    }
    .scrollClipDisabled()
  }

  // MARK: - Bottom action cluster (mic + camera FABs)

  private var bottomActionCluster: some View {
    VStack(alignment: .trailing, spacing: 12) {
      statusCard
      HStack(spacing: 14) {
        cameraFAB
        micFAB
      }
    }
  }

  /// Compact floating status card rendered above the FAB cluster. Only
  /// visible for non-idle phases; hidden when `.idle` or `.done` so the
  /// notes underneath stay clean.
  @ViewBuilder
  private var statusCard: some View {
    if let aiError = vm.aiErrorMessage, vm.phase == .done {
      statusPill(aiError, icon: "exclamationmark.triangle", tint: .orange)
    }
    switch vm.phase {
    case .recording:
      VStack(alignment: .trailing, spacing: 6) {
        Text(formatElapsed(vm.elapsedSeconds))
          .font(.system(size: 18, weight: .semibold, design: .rounded))
          .foregroundStyle(.red)
          .monospacedDigit()
        if !vm.livePartial.isEmpty {
          Text(vm.livePartial)
            .font(.caption)
            .foregroundStyle(.secondary)
            .italic()
            .multilineTextAlignment(.trailing)
            .lineLimit(3)
            .frame(maxWidth: 260, alignment: .trailing)
            .animation(.easeOut(duration: 0.15), value: vm.livePartial)
            .transition(.opacity)
        }
      }
      .padding(10)
      .background(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .fill(.ultraThinMaterial)
      )
    case .requestingPermission:
      statusPill("Requesting mic…", icon: "mic.slash", tint: .secondary)
    case .transcribing:
      statusPill("Transcribing…", icon: "waveform", tint: .blue)
    case .aiProcessing:
      statusPill("Enhancing with \(aiProvider.displayName)…", icon: "sparkles", tint: .purple)
    case .error(let msg):
      statusPill(msg, icon: "exclamationmark.triangle", tint: .red)
    case .idle, .done:
      EmptyView()
    }
  }

  private func statusPill(_ text: String, icon: String, tint: Color) -> some View {
    Label(text, systemImage: icon)
      .font(.caption.weight(.medium))
      .foregroundStyle(tint)
      .lineLimit(2)
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .background(
        Capsule().fill(.ultraThinMaterial)
      )
      .frame(maxWidth: 260, alignment: .trailing)
  }

  /// Shared size for both FABs so they read as a matched pair.
  private static let fabSize: CGFloat = 72
  /// Outer bounding box — large enough to hold the main circle plus its
  /// soft shadow/glow without spilling into its sibling or stretching
  /// the cluster layout.
  private static let fabSlot: CGFloat = 88

  private var cameraFAB: some View {
    Button(action: tapAddPhoto) {
      Circle()
        .fill(
          LinearGradient(
            colors: [Color.purple, Color.purple.opacity(0.82)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          )
        )
        .frame(width: Self.fabSize, height: Self.fabSize)
        .overlay(
          Image(systemName: "camera.fill")
            .font(.system(size: 26, weight: .semibold))
            .foregroundStyle(.white)
        )
        .shadow(color: Color.purple.opacity(0.35), radius: 8, y: 4)
        .frame(width: Self.fabSlot, height: Self.fabSlot)
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Add photo to note")
  }

  @ViewBuilder
  private var micFAB: some View {
    let isRecording = vm.phase == .recording
    let isBusy: Bool = {
      switch vm.phase {
      case .transcribing, .aiProcessing, .requestingPermission: return true
      default: return false
      }
    }()
    let tint: Color = isRecording ? .red : (aiMode == .off ? .blue : .purple)
    let level = CGFloat(vm.meterLevel)

    Button {
      Task {
        await vm.toggleRecording(
          model: selectedModel,
          mode: aiMode,
          provider: aiProvider
        )
      }
    } label: {
      ZStack {
        // Audio-reactive halo, only while recording. Contained inside
        // the fabSlot via the outer `.frame` so the blur doesn't
        // scatter across the cluster when it scales.
        if isRecording {
          Circle()
            .fill(tint.opacity(0.3 + level * 0.4))
            .frame(width: Self.fabSize + 8, height: Self.fabSize + 8)
            .blur(radius: 6)
            .scaleEffect(1.0 + level * 0.15)
            .animation(.easeInOut(duration: 0.18), value: level)
        }

        Circle()
          .fill(
            LinearGradient(
              colors: [tint, tint.opacity(0.75)],
              startPoint: .topLeading,
              endPoint: .bottomTrailing
            )
          )
          .frame(width: Self.fabSize, height: Self.fabSize)
          .shadow(color: tint.opacity(0.4), radius: 8, y: 4)
          .scaleEffect(isRecording ? 1.0 + level * 0.08 : 1.0)
          .animation(.easeInOut(duration: 0.15), value: level)

        if isBusy {
          ProgressView().controlSize(.regular).tint(.white)
        } else {
          Image(systemName: isRecording ? "stop.fill" : "mic.fill")
            .font(.system(size: 28, weight: .medium))
            .foregroundStyle(.white)
            .symbolEffect(.bounce, value: isRecording)
        }
      }
      .frame(width: Self.fabSlot, height: Self.fabSlot)
      .compositingGroup()
    }
    .buttonStyle(.plain)
    .disabled(isBusy)
    .accessibilityLabel(isRecording ? "Stop recording" : "Start recording")
  }

  private func formatElapsed(_ seconds: TimeInterval) -> String {
    let m = Int(seconds) / 60
    let s = Int(seconds) % 60
    let cs = Int((seconds - floor(seconds)) * 10)
    return String(format: "%02d:%02d.%d", m, s, cs)
  }

  // MARK: - Result

  /// The main content canvas below the record button. Shows the full
  /// active note's body (not just the latest recording's transcript) so
  /// successive recordings visibly stitch into a single continuous note —
  /// e.g. recording a few sections of a conference talk with a pause
  /// between them, you see the full composite transcript grow downward.
  /// Auto-scrolls to the bottom on every body change so the newest
  /// content is always in view.
  @ViewBuilder
  private var resultArea: some View {
    if let note = notes.activeNote, !note.body.isEmpty {
      noteCanvas(for: note)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
  }

  private func noteCanvas(for note: Note) -> some View {
    let tint: Color = aiMode == .off ? .blue : .purple
    let segments = NoteContent.segments(from: note.body)
    return VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 6) {
        Label(
          aiMode == .off ? "Transcript" : "\(aiMode.displayName) mode",
          systemImage: aiMode == .off ? "waveform" : "sparkles"
        )
        .font(.caption.weight(.semibold))
        .foregroundStyle(tint)

        Spacer()

        if note.photoCount > 0 {
          Label("\(note.photoCount)", systemImage: "photo")
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        Text("\(note.wordCount) words")
          .font(.caption2)
          .foregroundStyle(.tertiary)
          .padding(.trailing, 2)

        noteShareMenu(for: note, tint: tint)
        noteCopyButton(for: note, tint: tint)
        noteDeleteButton(for: note)
      }

      VStack(alignment: .leading, spacing: 12) {
        ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
          segmentView(seg, noteID: note.id)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(16)
    .background(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .fill(tint.opacity(0.08))
        .overlay(
          RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(tint.opacity(0.15), lineWidth: 1)
        )
    )
  }

  @ViewBuilder
  private func segmentView(_ seg: NoteSegment, noteID: UUID) -> some View {
    switch seg {
    case .text(let text):
      NoteTextView(text: text, headingColor: .purple)
        .textSelection(.enabled)
    case .photo(let photoID):
      VStack(alignment: .leading, spacing: 8) {
        if let ui = PhotoStore.shared.loadImage(noteID: noteID, photoID: photoID) {
          Image(uiImage: ui)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.secondary.opacity(0.12))
            .frame(height: 80)
            .overlay(
              Label("Missing photo", systemImage: "photo.badge.exclamationmark")
                .font(.caption)
                .foregroundStyle(.secondary)
            )
        }
        analysisCard(noteID: noteID, photoID: photoID)
      }
    }
  }

  @ViewBuilder
  private func analysisCard(noteID: UUID, photoID: UUID) -> some View {
    let analyzing = notes.analyzingPhotoIDs.contains(photoID)
    let analysis = notes.photoAnalyses[photoID]
    let error = notes.analysisErrors[photoID]

    if analyzing {
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text("Analyzing photo…")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding(10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 10).fill(Color.purple.opacity(0.06))
      )
    } else if let analysis {
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 6) {
          Image(systemName: "sparkles")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.purple)
          Text("AI Analysis")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.purple)
          Spacer()
        }

        if !analysis.summary.isEmpty {
          Text(analysis.summary)
            .font(.subheadline)
            .foregroundStyle(.primary)
            .textSelection(.enabled)
        }

        if !analysis.keyDetails.isEmpty {
          VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(analysis.keyDetails.enumerated()), id: \.offset) { _, detail in
              HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•").foregroundStyle(.purple)
                Text(detail)
                  .font(.footnote)
                  .foregroundStyle(.secondary)
                  .textSelection(.enabled)
              }
            }
          }
        }

        if let transcribed = analysis.transcribedText, !transcribed.isEmpty {
          DisclosureGroup {
            Text(transcribed)
              .font(.footnote.monospaced())
              .foregroundStyle(.primary)
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.top, 4)
          } label: {
            Label("Transcribed text", systemImage: "text.viewfinder")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
      .padding(10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 10).fill(Color.purple.opacity(0.08))
      )
    } else if let error {
      VStack(alignment: .leading, spacing: 6) {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
          Text(error)
            .font(.caption)
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
        }
        HStack(spacing: 8) {
          Button {
            showingSettings = true
          } label: {
            Label("Open Settings", systemImage: "gearshape")
              .font(.caption.weight(.semibold))
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
          .tint(.orange)

          Button {
            notes.analyzePhoto(noteID: noteID, photoID: photoID, provider: aiProvider)
          } label: {
            Label("Retry", systemImage: "arrow.clockwise")
              .font(.caption.weight(.semibold))
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
          .tint(.orange)
        }
      }
      .padding(10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.1)))
    }
  }

  /// Compact round icon button used in the note title row. Light tinted
  /// background, tint-coloured glyph — mirrors the other circular pill
  /// controls in the header/active-note strip.
  private func circleIconButton(
    systemName: String,
    tint: Color,
    accessibilityLabel: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: systemName)
        .font(.caption.weight(.semibold))
        .foregroundStyle(tint)
        .frame(width: 30, height: 30)
        .background(Circle().fill(tint.opacity(0.14)))
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(accessibilityLabel)
  }

  private func noteShareMenu(for note: Note, tint: Color) -> some View {
    let text = NoteContent.stripPhotos(from: note.body)
    let hasPhotos = note.photoCount > 0

    return Menu {
      Button {
        shareNoteText(note)
      } label: {
        Label("Share Text Only", systemImage: "text.alignleft")
      }
      .disabled(text.isEmpty)

      Button {
        sharePDF(note)
      } label: {
        Label(
          hasPhotos ? "Share as PDF (text + photos)" : "Share as PDF",
          systemImage: "doc.richtext"
        )
      }
    } label: {
      Image(systemName: "square.and.arrow.up")
        .font(.caption.weight(.semibold))
        .foregroundStyle(tint)
        .frame(width: 30, height: 30)
        .background(Circle().fill(tint.opacity(0.14)))
        .contentShape(Circle())
    }
    .disabled(isBuildingPDF)
    .opacity(isBuildingPDF ? 0.5 : 1.0)
    .accessibilityLabel("Share note")
  }

  private func noteDeleteButton(for note: Note) -> some View {
    Button {
      UISelectionFeedbackGenerator().selectionChanged()
      pendingDeleteNoteID = note.id
    } label: {
      Image(systemName: "trash")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.red)
        .frame(width: 30, height: 30)
        .background(Circle().fill(Color.red.opacity(0.14)))
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Delete note")
  }

  private func noteCopyButton(for note: Note, tint: Color) -> some View {
    let text = NoteContent.stripPhotos(from: note.body)
    let effectiveTint: Color = showCopied ? .green : tint
    return Button {
      copyToClipboard(text)
    } label: {
      Image(systemName: showCopied ? "checkmark" : "doc.on.doc")
        .contentTransition(.symbolEffect(.replace))
        .font(.caption.weight(.semibold))
        .foregroundStyle(effectiveTint)
        .frame(width: 30, height: 30)
        .background(Circle().fill(effectiveTint.opacity(0.14)))
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .animation(.easeInOut(duration: 0.2), value: showCopied)
    .accessibilityLabel(showCopied ? "Copied" : "Copy note text")
  }

  private func copyToClipboard(_ text: String) {
    UIPasteboard.general.string = text
    UINotificationFeedbackGenerator().notificationOccurred(.success)

    // Flip to the "Copied" state, then auto-revert after ~1.5s.
    copyResetTask?.cancel()
    showCopied = true
    copyResetTask = Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(1500))
      guard !Task.isCancelled else { return }
      showCopied = false
    }
  }

  // Legacy signature kept for backwards-compat in case a preview still
  // references it — unused in the live layout now.
  private func resultCard(title: String, icon: String, tint: Color, text: String) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Label(title, systemImage: icon)
          .font(.caption.weight(.semibold))
          .foregroundStyle(tint)
        Spacer()
      }
      Text(text)
        .textSelection(.enabled)
        .font(.body)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(16)
    .background(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .fill(tint.opacity(0.08))
        .overlay(
          RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(tint.opacity(0.15), lineWidth: 1)
        )
    )
  }
}

// MARK: - Mode chip

private struct ModeChip: View {
  let mode: AIProcessingMode
  let isSelected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 6) {
        Image(systemName: iconName)
          .font(.caption.weight(.semibold))
        Text(mode == .off ? "Raw" : mode.displayName)
          .font(.subheadline.weight(.medium))
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 8)
      .background(
        Capsule()
          .fill(isSelected ? tint : Color.secondary.opacity(0.12))
      )
      .foregroundStyle(isSelected ? Color.white : Color.primary)
      .overlay(
        Capsule()
          .stroke(isSelected ? Color.clear : Color.secondary.opacity(0.2), lineWidth: 1)
      )
    }
    .buttonStyle(.plain)
  }

  private var iconName: String {
    switch mode {
    case .off: "waveform"
    case .clean: "sparkles"
    case .email: "envelope"
    case .notes: "list.bullet"
    case .message: "bubble.left"
    case .code: "chevron.left.forwardslash.chevron.right"
    }
  }

  private var tint: Color {
    switch mode {
    case .off: .blue
    default: .purple
    }
  }
}

#Preview {
  ContentView()
}
