import Combine
import EventKit
import HexCore
import SwiftUI

/// Posted by `ActionConfirmationViewModel` when an action couldn't run
/// online and was saved to the offline queue. ContentView listens to
/// surface a brief "Saved offline — will retry when online" banner.
extension Notification.Name {
  static let quillActionQueuedOffline = Notification.Name("quill.actionQueuedOffline")
}

@MainActor
final class ActionConfirmationViewModel: ObservableObject {
  @Published var intent: ActionIntent
  @Published var selectedIntegration: Integration.Identifier
  @Published var availableIntegrations: [Integration.Identifier] = []
  @Published var availableLists: [String] = []
  @Published var selectedList: String = ""
  @Published var editableTitle: String = ""
  @Published var editableDueDate: String = ""
  @Published var editableNotes: String = ""
  @Published var editablePriority: Int = 0
  @Published var editableStartDate: Date = Date()
  @Published var editableEndDate: Date = Date().addingTimeInterval(3600)
  @Published var editableAttendees: String = ""
  /// Gmail draft recipient (only used when targetIntegration == .gmail).
  @Published var editableRecipient: String = ""
  /// Gmail draft subject (defaults to the parsed title).
  @Published var editableSubject: String = ""
  /// Gmail draft body (defaults to the parsed notes).
  @Published var editableBody: String = ""
  @Published var isExecuting: Bool = false
  @Published var error: String?
  /// Set after a successful (or queued) execution so the sheet can
  /// flip to the success badge before dismissing. Mirrors the
  /// completion treatment we want on macOS so users get a brief
  /// "this actually worked" before the sheet disappears.
  @Published var completion: Completion?

  /// Result that drives the success badge view.
  struct Completion: Equatable {
    enum Kind: Equatable { case created, queued }
    let kind: Kind
    let integration: Integration.Identifier
    let title: String
  }

  init(intent: ActionIntent) {
    self.intent = intent
    self.selectedIntegration = intent.targetIntegration
    self.editableTitle = intent.title
    self.editableDueDate = intent.dueDate ?? ""
    self.editableNotes = intent.notes ?? ""
    self.selectedList = intent.listName ?? ""
    self.editablePriority = intent.priority ?? 0
    self.editableAttendees = intent.attendees?.joined(separator: ", ") ?? ""
    self.editableRecipient = intent.recipient ?? ""
    self.editableSubject = intent.subject ?? intent.title
    self.editableBody = intent.notes ?? ""

    let parsedStart = (intent.dueDate.flatMap { parseDateAndTime($0) }) ?? Self.defaultEventStart()
    let minutes = intent.duration ?? 60
    self.editableStartDate = parsedStart
    self.editableEndDate = parsedStart.addingTimeInterval(Double(minutes) * 60)
  }

  private static func defaultEventStart() -> Date {
    let cal = Calendar.current
    let now = Date()
    let components = cal.dateComponents([.year, .month, .day, .hour], from: now)
    let topOfHour = cal.date(from: components) ?? now
    return cal.date(byAdding: .hour, value: 1, to: topOfHour) ?? now
  }

  func loadIntegrations() async {
    let connected = IntegrationConnectionStore.decode(
      UserDefaults.standard.data(forKey: IntegrationConnectionStore.userDefaultsKey)
    )
    var available: [Integration.Identifier] = [.appleReminders, .calendar]
    if connected.contains(.todoist) {
      let (token, _) = KeychainStore.read(account: KeychainKey.todoistAPIToken)
      if let token, !token.isEmpty {
        available.append(.todoist)
      }
    }
    // OAuth authorization is the source of truth for Gmail/GCal — the
    // IntegrationConnectionStore is just a UI cache that historically
    // got out of sync with the keychain (users who signed in before the
    // backfill landed had tokens but no store entries). Trusting OAuth
    // directly avoids the desync entirely.
    if IOSGoogleOAuthClient.isAuthorized() {
      available.append(.googleCalendar)
      available.append(.gmail)
    }
    availableIntegrations = available
    if !available.contains(selectedIntegration) {
      selectedIntegration = .appleReminders
    }
    await loadLists()
  }

  func changeIntegration(_ id: Integration.Identifier) async {
    selectedIntegration = id
    await loadLists()
  }

  func loadLists() async {
    let lists: [String]
    switch selectedIntegration {
    case .appleReminders:
      lists = await IOSRemindersAdapter.fetchLists()
    case .calendar:
      lists = await IOSCalendarAdapter.fetchCalendars()
    case .todoist:
      lists = await IOSTodoistAdapter.fetchProjects().map(\.name)
    case .googleCalendar:
      lists = await IOSGoogleCalendarAdapter.fetchCalendars().map(\.name)
    case .gmail:
      // Gmail has no per-account "list" picker — drafts always go to
      // the user's inbox. Skip the picker UI entirely for this case.
      lists = []
    default:
      lists = []
    }
    availableLists = lists
    if !lists.contains(selectedList) {
      selectedList = lists.first ?? ""
    }
  }

  /// Three-way outcome so the sheet can distinguish "synced now" from
  /// "queued for later" from "user needs to fix something".
  enum ExecutionOutcome: Sendable {
    case succeeded
    case queued
    case failed
  }

  func execute() async -> ExecutionOutcome {
    isExecuting = true
    error = nil

    var finalIntent = intent
    finalIntent.targetIntegration = selectedIntegration
    finalIntent.title = editableTitle
    finalIntent.dueDate = editableDueDate.isEmpty ? nil : editableDueDate
    finalIntent.notes = editableNotes.isEmpty ? nil : editableNotes
    finalIntent.listName = selectedList.isEmpty ? nil : selectedList
    finalIntent.priority = editablePriority == 0 ? nil : editablePriority

    if selectedIntegration == .calendar || selectedIntegration == .googleCalendar {
      finalIntent.actionType = .createEvent
      finalIntent.startDate = editableStartDate
      finalIntent.endDate = editableEndDate
      let emails = editableAttendees
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
      finalIntent.attendees = emails.isEmpty ? nil : emails
    }
    if selectedIntegration == .gmail {
      finalIntent.actionType = .createDraft
      finalIntent.recipient = editableRecipient.isEmpty ? nil : editableRecipient
      finalIntent.subject = editableSubject.isEmpty ? nil : editableSubject
      finalIntent.notes = editableBody.isEmpty ? nil : editableBody
    }

    do {
      switch selectedIntegration {
      case .appleReminders:
        _ = try await IOSRemindersAdapter.createReminder(finalIntent)
      case .calendar:
        _ = try await IOSCalendarAdapter.createEvent(finalIntent)
      case .todoist:
        _ = try await IOSTodoistAdapter.createTask(finalIntent)
      case .gmail:
        _ = try await IOSGmailAdapter.createDraft(finalIntent)
      case .googleCalendar:
        _ = try await IOSGoogleCalendarAdapter.createEvent(finalIntent)
      default:
        throw IOSActionError.invalidResponse(selectedIntegration.rawValue)
      }
      isExecuting = false
      completion = Completion(
        kind: .created,
        integration: selectedIntegration,
        title: completionDisplayTitle(for: finalIntent)
      )
      return .succeeded
    } catch {
      // Transient network errors → save to the offline queue so the
      // user's intent isn't lost. Permission/auth/validation errors
      // stay visible so the user can fix them.
      if QueueableErrorClassifier.isQueueable(error) {
        await ActionQueueManager.shared.enqueue(finalIntent, lastError: error.localizedDescription)
        isExecuting = false
        completion = Completion(
          kind: .queued,
          integration: selectedIntegration,
          title: completionDisplayTitle(for: finalIntent)
        )
        return .queued
      }
      self.error = error.localizedDescription
      isExecuting = false
      return .failed
    }
  }

  private func completionDisplayTitle(for intent: ActionIntent) -> String {
    if intent.targetIntegration == .gmail, let subject = intent.subject, !subject.isEmpty {
      return subject
    }
    return intent.title.isEmpty ? "(untitled)" : intent.title
  }
}

/// iOS confirmation sheet. Visually mirrors the macOS `ActionConfirmationView`
/// (HEARD / WILL DO / footer with a purple Run action button) so the two
/// platforms read as the same product. Adapts to light/dark via
/// `colorScheme` — every color is either a system color or pulled from
/// the integration tint catalog.
struct ActionConfirmationSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.colorScheme) private var colorScheme
  @StateObject var vm: ActionConfirmationViewModel
  let rawTranscript: String

  init(intent: ActionIntent, rawTranscript: String = "") {
    _vm = StateObject(wrappedValue: ActionConfirmationViewModel(intent: intent))
    self.rawTranscript = rawTranscript
  }

  var body: some View {
    ZStack {
      panelBackground
        .ignoresSafeArea()

      if let completion = vm.completion {
        CompletionBadgeView(completion: completion)
          .padding(.horizontal, 18)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .transition(.scale(scale: 0.92).combined(with: .opacity))
          .task(id: completion) {
            // Fire the haptic immediately so the user feels the result
            // the moment the badge appears, then keep it on screen long
            // enough to read before dismissing. 1.4s matches the macOS
            // panel so the platforms feel consistent.
            switch completion.kind {
            case .created:
              UINotificationFeedbackGenerator().notificationOccurred(.success)
            case .queued:
              UINotificationFeedbackGenerator().notificationOccurred(.warning)
              NotificationCenter.default.post(name: .quillActionQueuedOffline, object: nil)
            }
            try? await Task.sleep(for: .milliseconds(1400))
            dismiss()
          }
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 14) {
            integrationChipRow
            header
            heardSection
            willDoSection
            footer
          }
          .padding(18)
        }
        .scrollDismissesKeyboard(.interactively)
      }
    }
    .animation(.spring(duration: 0.35, bounce: 0.18), value: vm.completion)
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.visible)
    .presentationBackground(.clear)
    .task { await vm.loadIntegrations() }
  }

  // MARK: - Background

  /// Ultra-thin material with an adaptive overlay. In dark mode it
  /// reads like the macOS panel; in light mode the overlay is much
  /// lighter so text contrast stays correct.
  private var panelBackground: some View {
    ZStack {
      Rectangle().fill(.ultraThinMaterial)
      Rectangle().fill(overlayTint)
    }
  }

  private var overlayTint: Color {
    colorScheme == .dark
      ? Color.black.opacity(0.45)
      : Color.white.opacity(0.35)
  }

  // MARK: - Integration chip row

  /// Horizontal scrolling row of integration chips. Pre-confirmation
  /// equivalent of the macOS HUD chip row — the user can re-route the
  /// action to a different integration with a tap before they hit Run.
  /// Hidden when there's only one available integration.
  @ViewBuilder
  private var integrationChipRow: some View {
    if vm.availableIntegrations.count > 1 {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
          ForEach(vm.availableIntegrations, id: \.self) { id in
            integrationChip(id)
          }
        }
        .padding(.vertical, 2)
      }
    }
  }

  private func integrationChip(_ id: Integration.Identifier) -> some View {
    let isSelected = vm.selectedIntegration == id
    let tint = integrationTint(id)
    return Button {
      UISelectionFeedbackGenerator().selectionChanged()
      Task { await vm.changeIntegration(id) }
    } label: {
      HStack(spacing: 6) {
        Image(systemName: integrationIcon(id))
          .font(.caption.weight(.semibold))
        Text(integrationName(id))
          .font(.subheadline.weight(.medium))
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .foregroundStyle(isSelected ? Color.white : primaryTextColor)
      .background(
        Capsule().fill(isSelected ? tint : Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.06))
      )
      .overlay(
        Capsule().stroke(isSelected ? Color.clear : Color.primary.opacity(0.10), lineWidth: 0.5)
      )
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  // MARK: - Header

  private var header: some View {
    HStack(alignment: .center, spacing: 12) {
      integrationTile(size: 36, cornerRadius: 8)
      VStack(alignment: .leading, spacing: 2) {
        Text("New \(actionNoun(for: vm.selectedIntegration)) in \(integrationName(vm.selectedIntegration))")
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(primaryTextColor)
        Text("Action detected")
          .font(.system(size: 11))
          .foregroundStyle(secondaryTextColor)
      }
      Spacer(minLength: 0)
    }
  }

  // MARK: - HEARD

  @ViewBuilder
  private var heardSection: some View {
    if !rawTranscript.isEmpty {
      VStack(alignment: .leading, spacing: 6) {
        sectionLabel("HEARD")
        Text("\u{201C}\(rawTranscript)\u{201D}")
          .font(.system(size: 13))
          .foregroundStyle(primaryTextColor.opacity(0.85))
          .lineSpacing(2)
          .frame(maxWidth: .infinity, alignment: .leading)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  // MARK: - WILL DO

  private var willDoSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      sectionLabel("WILL DO")
      VStack(alignment: .leading, spacing: 0) {
        HStack(alignment: .center, spacing: 10) {
          integrationTile(size: 32, cornerRadius: 6)
          VStack(alignment: .leading, spacing: 2) {
            Text(displayTitle)
              .font(.system(size: 13, weight: .semibold))
              .foregroundStyle(primaryTextColor)
              .lineLimit(1)
            Text(displaySubtitle)
              .font(.system(size: 11))
              .foregroundStyle(secondaryTextColor)
              .lineLimit(1)
          }
          Spacer(minLength: 0)
        }
        .padding(12)

        Divider().opacity(0.2)

        VStack(spacing: 0) {
          fieldRows
        }
        .padding(.vertical, 4)

        if let error = vm.error {
          Text(error)
            .font(.system(size: 11))
            .foregroundStyle(.red.opacity(0.9))
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .background(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(cardFill)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .strokeBorder(cardStroke, lineWidth: 0.5)
      )
    }
  }

  @ViewBuilder
  private var fieldRows: some View {
    if vm.selectedIntegration == .gmail {
      EditableRow(icon: "person", label: "To", colorScheme: colorScheme) {
        TextField("e.g. mike@acme.com", text: $vm.editableRecipient)
          .textFieldStyle(.plain)
          .font(.system(size: 13))
          .foregroundStyle(primaryTextColor)
          .textInputAutocapitalization(.never)
          .keyboardType(.emailAddress)
      }
      EditableRow(icon: "envelope", label: "Subject", colorScheme: colorScheme) {
        TextField("Subject", text: $vm.editableSubject)
          .textFieldStyle(.plain)
          .font(.system(size: 13))
          .foregroundStyle(primaryTextColor)
      }
      EditableRow(icon: "text.alignleft", label: "Body", colorScheme: colorScheme) {
        TextField("Draft body text", text: $vm.editableBody, axis: .vertical)
          .textFieldStyle(.plain)
          .font(.system(size: 13))
          .foregroundStyle(primaryTextColor)
          .lineLimit(2 ... 4)
      }
    } else {
      EditableRow(icon: integrationIcon(vm.selectedIntegration), label: "Title", colorScheme: colorScheme) {
        TextField("Title", text: $vm.editableTitle)
          .textFieldStyle(.plain)
          .font(.system(size: 13))
          .foregroundStyle(primaryTextColor)
      }

      if vm.selectedIntegration == .calendar || vm.selectedIntegration == .googleCalendar {
        EditableRow(icon: "calendar", label: "Start", colorScheme: colorScheme) {
          DatePicker("", selection: tiedStartDateBinding, displayedComponents: [.date, .hourAndMinute])
            .labelsHidden()
            .datePickerStyle(.compact)
        }
        EditableRow(icon: "clock", label: "End", colorScheme: colorScheme) {
          DatePicker("", selection: $vm.editableEndDate, displayedComponents: [.date, .hourAndMinute])
            .labelsHidden()
            .datePickerStyle(.compact)
        }
      } else {
        EditableRow(icon: "info.circle", label: "Due", colorScheme: colorScheme) {
          TextField("e.g. Friday, tomorrow", text: $vm.editableDueDate)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .foregroundStyle(primaryTextColor)
        }
      }

      if !vm.availableLists.isEmpty {
        EditableRow(icon: listIcon, label: listLabel, colorScheme: colorScheme) {
          Picker("", selection: $vm.selectedList) {
            ForEach(vm.availableLists, id: \.self) { list in
              Text(list).tag(list)
            }
          }
          .labelsHidden()
          .pickerStyle(.menu)
          .tint(primaryTextColor)
        }
      }

      if vm.selectedIntegration == .todoist {
        EditableRow(icon: "flag", label: "Priority", colorScheme: colorScheme) {
          Picker("", selection: $vm.editablePriority) {
            Text("None").tag(0)
            Text("P1 (urgent)").tag(4)
            Text("P2").tag(3)
            Text("P3").tag(2)
            Text("P4 (low)").tag(1)
          }
          .labelsHidden()
          .pickerStyle(.menu)
          .tint(primaryTextColor)
        }
      }

      if vm.selectedIntegration == .calendar || vm.selectedIntegration == .googleCalendar {
        EditableRow(icon: "person.2", label: "Attendees", colorScheme: colorScheme) {
          TextField("e.g. john@acme.com", text: $vm.editableAttendees)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .foregroundStyle(primaryTextColor)
            .textInputAutocapitalization(.never)
            .keyboardType(.emailAddress)
        }
      }

      EditableRow(icon: "note.text", label: "Notes", colorScheme: colorScheme) {
        TextField("Optional", text: $vm.editableNotes, axis: .vertical)
          .textFieldStyle(.plain)
          .font(.system(size: 13))
          .foregroundStyle(primaryTextColor)
          .lineLimit(1 ... 3)
      }
    }
  }

  // MARK: - Footer

  private var footer: some View {
    HStack(spacing: 10) {
      Button {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        dismiss()
      } label: {
        Text("Dismiss")
          .font(.system(size: 14, weight: .medium))
          .foregroundStyle(secondaryTextColor)
          .frame(maxWidth: .infinity)
          .padding(.vertical, 12)
      }
      .buttonStyle(.plain)
      .background(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.05))
      )

      Button {
        Task {
          let outcome = await vm.execute()
          if outcome == .failed {
            // Stay on the sheet — error is rendered inside the WILL DO
            // card so the user can fix and retry.
            UINotificationFeedbackGenerator().notificationOccurred(.error)
          }
          // .succeeded / .queued flip `vm.completion`, which switches
          // the view to the completion badge and dismisses on its own.
        }
      } label: {
        HStack(spacing: 8) {
          if vm.isExecuting {
            ProgressView().tint(.white).controlSize(.small)
          }
          Text("Run action")
            .font(.system(size: 14, weight: .semibold))
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(executeDisabled ? Color.purple.opacity(0.4) : Color.purple)
        )
      }
      .buttonStyle(.plain)
      .disabled(executeDisabled)
    }
  }

  // MARK: - Bindings & helpers

  private var tiedStartDateBinding: Binding<Date> {
    Binding(
      get: { vm.editableStartDate },
      set: { newStart in
        let delta = newStart.timeIntervalSince(vm.editableStartDate)
        vm.editableEndDate = vm.editableEndDate.addingTimeInterval(delta)
        vm.editableStartDate = newStart
      }
    )
  }

  private var executeDisabled: Bool {
    if vm.isExecuting { return true }
    if vm.selectedIntegration == .gmail {
      return vm.editableSubject.isEmpty
    }
    return vm.editableTitle.isEmpty
  }

  private var displayTitle: String {
    if vm.selectedIntegration == .gmail, !vm.editableSubject.isEmpty {
      return vm.editableSubject
    }
    return vm.editableTitle.isEmpty ? "(untitled)" : vm.editableTitle
  }

  private var displaySubtitle: String {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    switch vm.selectedIntegration {
    case .calendar, .googleCalendar:
      return formatter.string(from: vm.editableStartDate)
    case .gmail:
      return vm.editableRecipient.isEmpty ? "Draft" : "To: \(vm.editableRecipient)"
    default:
      if !vm.editableDueDate.isEmpty { return vm.editableDueDate }
      return vm.selectedList.isEmpty ? "No date" : vm.selectedList
    }
  }

  private var listLabel: String {
    switch vm.selectedIntegration {
    case .todoist: "Project"
    case .calendar, .googleCalendar: "Calendar"
    default: "List"
    }
  }

  private var listIcon: String {
    switch vm.selectedIntegration {
    case .todoist: "folder"
    case .calendar, .googleCalendar: "calendar.badge.plus"
    default: "list.bullet"
    }
  }

  private func sectionLabel(_ text: String) -> some View {
    Text(text)
      .font(.system(size: 10, weight: .semibold))
      .tracking(1.4)
      .foregroundStyle(secondaryTextColor.opacity(0.85))
  }

  private func integrationTile(size: CGFloat, cornerRadius: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
      .fill(integrationTint(vm.selectedIntegration))
      .frame(width: size, height: size)
      .overlay(
        Image(systemName: integrationIcon(vm.selectedIntegration))
          .font(.system(size: size * 0.5, weight: .semibold))
          .foregroundStyle(.white)
      )
  }

  private func actionNoun(for id: Integration.Identifier) -> String {
    switch id {
    case .calendar, .googleCalendar: "event"
    case .gmail: "draft"
    case .todoist: "task"
    case .appleReminders: "reminder"
    default: "item"
    }
  }

  private func integrationName(_ id: Integration.Identifier) -> String {
    Integration.all.first { $0.identifier == id }?.name ?? id.rawValue
  }

  private func integrationIcon(_ id: Integration.Identifier) -> String {
    Integration.all.first { $0.identifier == id }?.systemImage ?? "questionmark.circle"
  }

  private func integrationTint(_ id: Integration.Identifier) -> Color {
    let hex = Integration.all.first { $0.identifier == id }?.tintHex
    return Color(hex: hex ?? "") ?? .orange
  }

  // MARK: - Adaptive colors

  private var primaryTextColor: Color { .primary }
  private var secondaryTextColor: Color { .secondary }

  private var cardFill: Color {
    colorScheme == .dark
      ? Color.white.opacity(0.05)
      : Color.black.opacity(0.04)
  }

  private var cardStroke: Color {
    colorScheme == .dark
      ? Color.white.opacity(0.10)
      : Color.black.opacity(0.08)
  }
}

// MARK: - EditableRow

/// Single row inside the WILL DO card: leading icon, label, value control.
/// The pencil glyph signals "this is editable" without adding a state
/// machine for "expanded vs collapsed" rows. Mirrors the macOS layout.
private struct EditableRow<Content: View>: View {
  let icon: String
  let label: String
  let colorScheme: ColorScheme
  @ViewBuilder var content: () -> Content

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: icon)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.secondary)
        .frame(width: 16, height: 16)

      content()
        .frame(maxWidth: .infinity, alignment: .leading)

      Image(systemName: "pencil")
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary.opacity(0.7))
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
  }
}

// MARK: - Completion badge

/// Replaces the panel content with a single "Added to <Integration>"
/// confirmation. Stays on screen briefly before the sheet dismisses,
/// so the user has visible proof the action actually went through.
struct CompletionBadgeView: View {
  let completion: ActionConfirmationViewModel.Completion
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    VStack(spacing: 16) {
      ZStack {
        Circle()
          .fill(badgeTint.opacity(0.18))
          .frame(width: 86, height: 86)
        Circle()
          .fill(badgeTint)
          .frame(width: 64, height: 64)
        Image(systemName: badgeIcon)
          .font(.system(size: 30, weight: .bold))
          .foregroundStyle(.white)
      }
      .accessibilityHidden(true)

      VStack(spacing: 4) {
        Text(headline)
          .font(.system(size: 17, weight: .semibold))
          .foregroundStyle(.primary)
        Text(subhead)
          .font(.system(size: 13))
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .lineLimit(2)
      }

      // Small pill that mirrors the macOS post-paste confirmation toast.
      HStack(spacing: 6) {
        Image(systemName: integrationIcon)
          .font(.caption.weight(.semibold))
        Text(pillText)
          .font(.subheadline.weight(.medium))
      }
      .foregroundStyle(.white)
      .padding(.horizontal, 14)
      .padding(.vertical, 8)
      .background(Capsule().fill(integrationColor))
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(headline). \(subhead)")
  }

  private var badgeTint: Color {
    switch completion.kind {
    case .created: .green
    case .queued: .orange
    }
  }

  private var badgeIcon: String {
    switch completion.kind {
    case .created: "checkmark"
    case .queued: "wifi.exclamationmark"
    }
  }

  private var headline: String {
    switch completion.kind {
    case .created: "Done"
    case .queued: "Saved offline"
    }
  }

  private var subhead: String {
    switch completion.kind {
    case .created: "\u{201C}\(completion.title)\u{201D}"
    case .queued: "Will retry when you're back online."
    }
  }

  private var pillText: String {
    switch completion.kind {
    case .created: "Added to \(integrationName)"
    case .queued: "Queued for \(integrationName)"
    }
  }

  private var integrationName: String {
    Integration.all.first { $0.identifier == completion.integration }?.name
      ?? completion.integration.rawValue
  }

  private var integrationIcon: String {
    Integration.all.first { $0.identifier == completion.integration }?.systemImage
      ?? "checkmark.circle.fill"
  }

  private var integrationColor: Color {
    let hex = Integration.all.first { $0.identifier == completion.integration }?.tintHex
    return Color(hex: hex ?? "") ?? .purple
  }
}
