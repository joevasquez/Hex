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
    case actionParsing
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
  /// Set when an Action recording finishes parsing. ContentView
  /// presents the confirmation sheet in response.
  @Published var parsedIntent: ActionIntent?
  /// True when the current recording was started via the Action FAB.
  var isActionRecording: Bool = false
  /// True while the WhisperKit model is loading (first launch, or
  /// after the user changes models in Settings). Surfaced in the
  /// status area so the user knows why the first transcription is
  /// slower than subsequent ones — otherwise it looks like AI
  /// processing is hanging.
  @Published var isPreparingModel: Bool = false

  private var recorder = IOSRecordingClient.shared
  private var whisperKit: WhisperKit?
  private var timerTask: Task<Void, Never>?
  private var recordingStartedAt: Date?
  private var cancellables: Set<AnyCancellable> = []

  /// Prepare (download if needed + load) the Whisper model for
  /// `modelName` ahead of any recording. Doing this on app launch
  /// means the first real transcription doesn't block on a 1–2
  /// minute WhisperKit init. Safe to call multiple times — it's a
  /// no-op when the requested model is already loaded.
  func prewarmModel(_ modelName: String) async {
    // Already loaded and matching? Nothing to do.
    if whisperKit != nil, whisperKit?.modelFolder?.lastPathComponent == modelName {
      return
    }
    isPreparingModel = true
    defer { isPreparingModel = false }
    do {
      whisperKit = try await WhisperKit(
        WhisperKitConfig(model: modelName, download: true)
      )
      print("RecordingViewModel: prewarmed Whisper model \(modelName)")
    } catch {
      // Non-fatal: if pre-warm fails (offline, corrupt cache, etc.)
      // the normal transcription path will retry on first record.
      print("RecordingViewModel: prewarm failed for \(modelName): \(error.localizedDescription)")
    }
  }

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
    provider: AIProvider,
    voiceCommandsEnabled: Bool,
    customSystemPrompt: String? = nil
  ) async {
    switch phase {
    case .idle, .done, .error:
      isActionRecording = false
      await startRecording(model: model, mode: mode, provider: provider)
    case .recording:
      if isActionRecording {
        await stopAndParseAction(model: model, provider: provider)
      } else {
        await stopAndProcess(
          model: model,
          mode: mode,
          provider: provider,
          voiceCommandsEnabled: voiceCommandsEnabled,
          customSystemPrompt: customSystemPrompt
        )
      }
    default:
      break
    }
  }

  func toggleActionRecording(
    model: String,
    provider: AIProvider
  ) async {
    switch phase {
    case .idle, .done, .error:
      isActionRecording = true
      parsedIntent = nil
      await startRecording(model: model, mode: .off, provider: provider)
    case .recording:
      await stopAndParseAction(model: model, provider: provider)
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
    provider: AIProvider,
    voiceCommandsEnabled: Bool,
    customSystemPrompt: String? = nil
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
      let cleaned = WhisperOutputCleaner.clean(rawText)
      // Inline voice-command substitution: "period", "comma",
      // "new paragraph" → real punctuation / line breaks. Runs before
      // AI post-processing so downstream modes see properly-punctuated
      // text. Gated by the user's Settings toggle.
      let text = voiceCommandsEnabled
        ? VoiceCommandSubstituter.substitute(in: cleaned)
        : cleaned
      if text != cleaned {
        print("RecordingViewModel: applied voice-command substitutions")
      }
      rawTranscript = text

      try? FileManager.default.removeItem(at: url)

      if text.isEmpty {
        phase = .error("No speech detected. Try again.")
        return
      }

      let shouldRunAI = mode != .off || customSystemPrompt != nil
      if shouldRunAI {
        phase = .aiProcessing
        do {
          processedTranscript = try await TextAIClient.process(
            text: text,
            mode: mode,
            provider: provider,
            customSystemPrompt: customSystemPrompt
          )
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

  private func stopAndParseAction(
    model: String,
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
      let cleaned = WhisperOutputCleaner.clean(rawText)
      rawTranscript = cleaned

      try? FileManager.default.removeItem(at: url)

      if cleaned.isEmpty {
        phase = .error("No speech detected. Try again.")
        return
      }

      phase = .actionParsing
      // Inner do/catch — transient network failures here become queued
      // raw transcripts (replayed when connectivity returns), instead
      // of being lost as a flash error. Outer catch still covers
      // WhisperKit / file IO failures, which queueing wouldn't help.
      do {
        let intent = try await IOSActionParsingClient.parse(
          transcript: cleaned,
          provider: provider
        )
        parsedIntent = intent
        phase = .done
        UINotificationFeedbackGenerator().notificationOccurred(.success)
      } catch {
        if QueueableErrorClassifier.isQueueable(error) {
          await ActionQueueManager.shared.enqueueTranscript(
            cleaned,
            provider: provider,
            lastError: error.localizedDescription
          )
          phase = .done
          UINotificationFeedbackGenerator().notificationOccurred(.warning)
          NotificationCenter.default.post(name: .quillActionQueuedOffline, object: nil)
        } else {
          phase = .error("Action parsing failed: \(error.localizedDescription)")
        }
      }
    } catch {
      phase = .error("Action parsing failed: \(error.localizedDescription)")
    }
  }
}

struct ContentView: View {
  @AppStorage(QuillIOSSettingsKey.selectedModel) private var selectedModel: String = QuillIOSSettingsKey.defaultModel
  @AppStorage(QuillIOSSettingsKey.aiProcessingMode) private var aiModeRaw: String = QuillIOSSettingsKey.defaultMode
  @AppStorage(QuillIOSSettingsKey.aiProvider) private var aiProviderRaw: String = QuillIOSSettingsKey.defaultProvider
  @AppStorage(QuillIOSSettingsKey.voiceCommandsEnabled) private var voiceCommandsEnabled: Bool = QuillIOSSettingsKey.defaultVoiceCommandsEnabled
  @AppStorage(CustomAIModesStorage.userDefaultsKey) private var customModesData: Data = Data()
  @AppStorage(QuillIOSSettingsKey.disabledBuiltInModes) private var disabledBuiltInModesData: Data = Data()

  @StateObject private var vm = RecordingViewModel()
  @StateObject private var notes = NotesStore.shared
  @EnvironmentObject private var deepLinks: QuillDeepLinkRouter
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
  @State private var showingActionConfirmation = false
  /// Transient banner state — set true when an action mode item is queued
  /// because we're offline. Auto-clears after a few seconds via the task
  /// kicked off in `.onReceive`.
  @State private var showOfflineQueuedBanner = false
  @State private var offlineBannerDismissTask: Task<Void, Never>?

  /// The currently-selected mode, which may be either a built-in
  /// `AIProcessingMode` or a user-created custom mode. Stored as
  /// string in `aiModeRaw` using `AIModeSelection.rawValue`
  /// (e.g. `"clean"`, `"notes"`, or `"custom:<uuid>"`).
  private var currentSelection: AIModeSelection {
    AIModeSelection(rawValue: aiModeRaw) ?? .builtIn(.off)
  }

  /// Back-compat helper — treated as `.off` whenever the current
  /// selection is a custom mode. Code paths that need to know
  /// "is AI processing on at all" should use
  /// `currentSelection.resolveSystemPrompt(...) != nil` instead.
  private var aiMode: AIProcessingMode {
    if case .builtIn(let mode) = currentSelection { return mode }
    // Custom mode selected — behaves like a non-off mode for UI
    // colouring. `.clean` is a reasonable placeholder because it's
    // purple-tinted and indicates "AI is on".
    return .clean
  }

  private var aiProvider: AIProvider {
    AIProvider(rawValue: aiProviderRaw) ?? .anthropic
  }

  private var customModes: [CustomAIMode] {
    CustomAIModesStorage.decode(customModesData)
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
                // Mode picker is no longer pinned to the canvas top —
                // it floats up next to the dictate button when the user
                // expands the FAB cluster (see `QuillFABCluster`).
                resultArea
                // Bottom-of-scroll buffer. During recording the safe-area
                // inset (waveform card) already pads the scroll content,
                // so we only need a small breath between the transcript
                // card and the waveform — 24pt. When not recording, the
                // FAB cluster sits in a separate ZStack overlay above
                // the scroll, so we keep 140pt to ensure the last note
                // line / action buttons aren't hidden behind it.
                Color.clear
                  .frame(height: vm.phase == .recording ? 24 : 140)
                  .id("noteBottom")
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
            // Pin the waveform card just above the FAB cluster while
            // recording. `safeAreaInset` is the cleanest way to do this:
            // the scroll view's content automatically gets padded so it
            // doesn't slide under the waveform.
            .safeAreaInset(edge: .bottom, spacing: 0) {
              if vm.phase == .recording {
                WaveformBottomBar(vm: vm)
                  .padding(.bottom, 116) // clear the FAB cluster + push up a bit per the spec
                  .transition(.move(edge: .bottom).combined(with: .opacity))
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
      .sheet(isPresented: $showingActionConfirmation) {
        if let intent = vm.parsedIntent {
          ActionConfirmationSheet(intent: intent)
        }
      }
      .onAppear {
        idlePulse = true
        // Pre-warm the Whisper model immediately on first appear so
        // the initial transcription doesn't block on a long
        // download + load. Happens in the background — user can
        // still interact with everything else.
        Task { await vm.prewarmModel(selectedModel) }
      }
      .onChange(of: selectedModel) { _, newModel in
        Task { await vm.prewarmModel(newModel) }
      }
      .onChange(of: deepLinks.pendingLink) { _, link in
        guard let link else { return }
        switch link.link {
        case .record:
          // Widget tap: always start a FRESH note, then begin
          // recording. Appending to an existing active note would
          // feel surprising to a user who just tapped a home-screen
          // widget — they expect a dedicated new capture.
          Task {
            let loc = await LocationClient.shared.currentPlace()
            _ = notes.startNewNote(location: loc)
            // Delay briefly to let the app finish becoming active so
            // the mic permission prompt (if any) and recording
            // startup don't race UIKit window transitions.
            try? await Task.sleep(for: .milliseconds(300))
            await vm.toggleRecording(
              model: selectedModel,
              mode: aiMode,
              provider: aiProvider,
              voiceCommandsEnabled: voiceCommandsEnabled
            )
            deepLinks.consume()
          }
        case .notes:
          showingNotesList = true
          deepLinks.consume()
        }
      }
      .onChange(of: vm.phase) { _, newPhase in
        if case .done = newPhase, !vm.isActionRecording {
          appendTranscriptToActiveNote()
        }
      }
      .onChange(of: vm.parsedIntent) { _, intent in
        if intent != nil {
          showingActionConfirmation = true
        }
      }
      .onReceive(NotificationCenter.default.publisher(for: .quillActionQueuedOffline)) { _ in
        // Show a transient pill above the FAB cluster acknowledging the
        // queue. Auto-dismiss after 3s — long enough to read, short
        // enough not to nag.
        offlineBannerDismissTask?.cancel()
        withAnimation(.spring(duration: 0.3, bounce: 0.2)) {
          showOfflineQueuedBanner = true
        }
        offlineBannerDismissTask = Task { @MainActor in
          try? await Task.sleep(for: .seconds(3))
          guard !Task.isCancelled else { return }
          withAnimation(.easeOut(duration: 0.3)) {
            showOfflineQueuedBanner = false
          }
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
          provider: aiProvider,
          voiceCommandsEnabled: voiceCommandsEnabled,
          customSystemPrompt: currentSelection.resolveSystemPrompt(customModes: customModes).flatMap { _ in
            // Only pass a custom prompt when the selection IS a custom mode;
            // built-in selections use their own `mode.systemPrompt` via `aiMode`.
            if case .custom = currentSelection {
              return currentSelection.resolveSystemPrompt(customModes: customModes)
            }
            return nil
          }
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

  /// Reusable purple header. The component lives in
  /// `Views/QuillHeaderBar.swift` so future screens (empty home,
  /// recording state, action confirmation) drop it in identically.
  private var headerBar: some View {
    QuillHeaderBar(
      onTapList: { showingNotesList = true },
      onTapNewNote: {
        Task {
          let loc = await LocationClient.shared.currentPlace()
          _ = notes.startNewNote(location: loc)
        }
      },
      onTapSettings: { showingSettings = true }
    )
  }

  // MARK: - Active-note strip

  /// Reusable "you're working on this note" strip. Lives in
  /// `Views/QuillActiveNoteStrip.swift` so attached screens render
  /// identical context framing without duplicating the metadata logic.
  private var activeNoteStrip: some View {
    QuillActiveNoteStrip(
      activeNote: notes.activeNote,
      onTapRename: tapRenameTitle,
      // Live timer + red dot when actively recording. Hidden during
      // post-recording phases (transcribing, AI, action parsing) so
      // the strip falls back to its normal metadata footprint.
      recordingElapsed: vm.phase == .recording ? vm.elapsedSeconds : nil
    )
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
        let note = notes.appendToActiveNote(text, locationIfCreating: loc)
        // Kick off AI title generation on the background. No-op if
        // the note already has a locked-in title (user-renamed or
        // previously AI-titled) — see `generateTitleIfNeeded`.
        notes.generateTitleIfNeeded(noteID: note.id, provider: aiProvider)
      }
    } else {
      let note = notes.appendToActiveNote(text, locationIfCreating: nil)
      notes.generateTitleIfNeeded(noteID: note.id, provider: aiProvider)
    }
  }

  // MARK: - Background

  @Environment(\.colorScheme) private var colorScheme

  private var backgroundGradient: some View {
    Group {
      if colorScheme == .dark {
        Color(red: 0.11, green: 0.11, blue: 0.12)
      } else {
        Color(red: 0.957, green: 0.945, blue: 0.973)
      }
    }
  }

  // MARK: - Mode chips

  /// Built-in modes the user has hidden via Settings → AI Modes.
  /// `.off` is never hideable — the user always needs a way back to
  /// Raw, even if every other mode is disabled.
  private var disabledBuiltInModes: Set<AIProcessingMode> {
    BuiltInModeVisibility.decode(disabledBuiltInModesData)
  }

  /// Built-in modes to render in the pill row — always includes `.off`,
  /// then any other mode the user hasn't toggled off.
  private var visibleBuiltInModes: [AIProcessingMode] {
    AIProcessingMode.allCases.filter { mode in
      mode == .off || !disabledBuiltInModes.contains(mode)
    }
  }

  // MARK: - Bottom action cluster (single + button → expands to a
  // vertical fan of dictate / photo / action, with the mode dropdown
  // floating in next to dictate)

  private var bottomActionCluster: some View {
    VStack(alignment: .trailing, spacing: 12) {
      statusCard
      QuillFABCluster(
        vm: vm,
        modeSelectionRaw: $aiModeRaw,
        customModes: customModes,
        visibleBuiltInModes: visibleBuiltInModes,
        hasAPIKey: aiProvider.hasAPIKey,
        onTapCamera: tapAddPhoto,
        onTapAction: {
          Task {
            await vm.toggleActionRecording(
              model: selectedModel,
              provider: aiProvider
            )
          }
        },
        onTapMic: {
          Task {
            await vm.toggleRecording(
              model: selectedModel,
              mode: aiMode,
              provider: aiProvider,
              voiceCommandsEnabled: voiceCommandsEnabled,
              customSystemPrompt: micCustomSystemPrompt
            )
          }
        },
        onRequestSettings: { showingSettings = true }
      )
    }
  }

  /// Resolved custom prompt to thread through `vm.toggleRecording`. Pulls
  /// the current selection's prompt only when it's a custom mode — built-
  /// in modes use their own `mode.systemPrompt` via `aiMode`.
  private var micCustomSystemPrompt: String? {
    if case .custom = currentSelection {
      return currentSelection.resolveSystemPrompt(customModes: customModes)
    }
    return nil
  }

  /// Compact floating status card rendered above the FAB cluster. Only
  /// visible for non-idle phases; hidden when `.idle` or `.done` so the
  /// notes underneath stay clean.
  @ViewBuilder
  private var statusCard: some View {
    if showOfflineQueuedBanner {
      statusPill(
        "Saved offline — will retry when online",
        icon: "wifi.exclamationmark",
        tint: .orange
      )
      .transition(.move(edge: .trailing).combined(with: .opacity))
    }
    if let aiError = vm.aiErrorMessage, vm.phase == .done {
      statusPill(aiError, icon: "exclamationmark.triangle", tint: .orange)
    }
    // Whisper model load runs on first launch (and when the user
    // switches models). The first transcription blocks on this if
    // it hasn't finished — surface it so users see "Loading model"
    // rather than a 60-120 s hang during "Transcribing…".
    if vm.isPreparingModel, vm.phase != .recording {
      statusPill("Loading Whisper model…", icon: "arrow.down.circle", tint: .blue)
    }
    switch vm.phase {
    case .recording:
      // No status pill while recording — the new layout owns the
      // recording UI: live transcript card in the canvas, waveform
      // pinned to the bottom, timer in the active-note strip. The
      // legacy floating timer pill that lived here is gone.
      EmptyView()
    case .requestingPermission:
      statusPill("Requesting mic…", icon: "mic.slash", tint: .secondary)
    case .transcribing:
      statusPill("Transcribing…", icon: "waveform", tint: .blue)
    case .actionParsing:
      statusPill("Parsing action…", icon: "bolt.fill", tint: .orange)
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
    // Three states drive what shows in the canvas region:
    // 1. Recording — full-bleed live transcript card + waveform card
    //    + 1-2 line caption. Replaces whatever was there.
    // 2. Active note with content — the existing note canvas (the
    //    user's actual writing).
    // 3. No active note (or empty active note) — pre-recording
    //    landing: feather mic + "Ready when you are." + example chips
    //    that map to the FAB cluster.
    if vm.phase == .recording {
      QuillRecordingTranscriptCard(transcript: recordingTranscript)
        .transition(.opacity)
    } else if let note = notes.activeNote, !note.body.isEmpty {
      noteCanvas(for: note)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    } else {
      QuillEmptyHome()
        .transition(.opacity)
    }
  }

  /// What QuillRecordingState should show in its big card. Falls back
  /// to whatever the active note already had (if any) appended with
  /// the recognizer's running partial — so a long ongoing note stays
  /// visible while the user adds more.
  private var recordingTranscript: String {
    let partial = vm.livePartial.trimmingCharacters(in: .whitespacesAndNewlines)
    let existing = notes.activeNote?.body.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if existing.isEmpty { return partial }
    if partial.isEmpty { return existing }
    return existing + "\n\n" + partial
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

  /// Shared toolbar-glyph styling for the note-card actions: 26pt round
  /// affordance with a near-transparent tint fill so the buttons read
  /// as a connected toolbar rather than three competing color blocks.
  /// The glyph itself carries the only saturated color.
  private static let noteToolbarGlyphSize: CGFloat = 26

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
      noteToolbarGlyph(systemName: "square.and.arrow.up", tint: tint)
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
      noteToolbarGlyph(systemName: "trash", tint: .red)
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
      noteToolbarGlyph(
        systemName: showCopied ? "checkmark" : "doc.on.doc",
        tint: effectiveTint,
        contentTransition: .symbolEffect(.replace)
      )
    }
    .buttonStyle(.plain)
    .animation(.easeInOut(duration: 0.2), value: showCopied)
    .accessibilityLabel(showCopied ? "Copied" : "Copy note text")
  }

  /// 26pt round glyph with a faint tint backdrop. Used by every note-
  /// card toolbar button so they share the same restrained visual
  /// weight — the glyph reads, the affordance recedes.
  @ViewBuilder
  private func noteToolbarGlyph(
    systemName: String,
    tint: Color,
    contentTransition: ContentTransition = .identity
  ) -> some View {
    Image(systemName: systemName)
      .contentTransition(contentTransition)
      .font(.caption.weight(.semibold))
      .foregroundStyle(tint)
      .frame(width: Self.noteToolbarGlyphSize, height: Self.noteToolbarGlyphSize)
      .background(Circle().fill(tint.opacity(0.06)))
      .contentShape(Circle())
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
        Image(systemName: mode.iosIconName)
          .font(.caption.weight(.semibold))
        Text(mode.iosDisplayName)
          .font(.subheadline.weight(.medium))
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 8)
      .modifier(ModeChipBackground(isSelected: isSelected, tint: tint))
      .foregroundStyle(isSelected ? Color.white : Color.primary)
    }
    .buttonStyle(.plain)
  }

  private var tint: Color {
    switch mode {
    case .off: .blue
    default: .purple
    }
  }
}

/// Mode chip for user-authored custom modes. Visually matches
/// `ModeChip` (same capsule / tint / padding) so the two types read
/// as one unified picker row.
private struct CustomModeChip: View {
  let mode: CustomAIMode
  let isSelected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 6) {
        Image(systemName: mode.icon)
          .font(.caption.weight(.semibold))
        Text(mode.displayName)
          .font(.subheadline.weight(.medium))
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 8)
      .modifier(ModeChipBackground(isSelected: isSelected, tint: .purple))
      .foregroundStyle(isSelected ? Color.white : Color.primary)
    }
    .buttonStyle(.plain)
  }
}

/// Shared chip background for built-in `ModeChip` and `CustomModeChip`.
/// On the selected state, layers (1) the tinted capsule fill,
/// (2) a top-edge inset white highlight that reads as a slight bevel,
/// and (3) a purple drop-glow so the chip lifts off the row.
/// Unselected stays restrained — light gray fill + 1pt outline.
private struct ModeChipBackground: ViewModifier {
  let isSelected: Bool
  let tint: Color

  func body(content: Content) -> some View {
    content
      .background {
        ZStack {
          Capsule()
            .fill(isSelected ? tint : Color.secondary.opacity(0.12))
          if isSelected {
            // Inset white glow at the top edge — fades from 35% white
            // at the top to nothing by the midpoint. Reads as a
            // pressed-button highlight rather than a border.
            Capsule()
              .strokeBorder(
                LinearGradient(
                  colors: [.white.opacity(0.35), .clear],
                  startPoint: .top,
                  endPoint: .bottom
                ),
                lineWidth: 1
              )
          }
        }
      }
      .overlay {
        if !isSelected {
          Capsule().stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        }
      }
      // Drop glow only on selected — soft purple-tint shadow that
      // signals brand-pressed state, distinct from the light gray
      // inactive chips.
      .shadow(
        color: isSelected ? tint.opacity(0.40) : .clear,
        radius: 6,
        y: 2
      )
  }
}

#Preview {
  ContentView()
}
