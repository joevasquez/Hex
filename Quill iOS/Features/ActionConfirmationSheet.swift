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
      return .succeeded
    } catch {
      // Transient network errors → save to the offline queue so the
      // user's intent isn't lost. Permission/auth/validation errors
      // stay visible so the user can fix them.
      if QueueableErrorClassifier.isQueueable(error) {
        await ActionQueueManager.shared.enqueue(finalIntent, lastError: error.localizedDescription)
        isExecuting = false
        return .queued
      }
      self.error = error.localizedDescription
      isExecuting = false
      return .failed
    }
  }
}

struct ActionConfirmationSheet: View {
  @Environment(\.dismiss) private var dismiss
  @StateObject var vm: ActionConfirmationViewModel

  init(intent: ActionIntent) {
    _vm = StateObject(wrappedValue: ActionConfirmationViewModel(intent: intent))
  }

  var body: some View {
    NavigationStack {
      Form {
        integrationSection
        fieldsSection
        if let error = vm.error {
          Section {
            Label(error, systemImage: "exclamationmark.triangle")
              .foregroundStyle(.red)
              .font(.caption)
          }
        }
      }
      .navigationTitle("Confirm Action")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            dismiss()
          }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button {
            Task {
              switch await vm.execute() {
              case .succeeded:
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                dismiss()
              case .queued:
                // Lighter haptic so the user can tell something
                // unusual happened (queued vs. created). The Action
                // mode summary banner in ContentView will show the
                // pending count.
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                NotificationCenter.default.post(name: .quillActionQueuedOffline, object: nil)
                dismiss()
              case .failed:
                // Stay on the sheet so the user can fix the inputs.
                break
              }
            }
          } label: {
            if vm.isExecuting {
              ProgressView().controlSize(.small)
            } else {
              Text(executeLabel)
            }
          }
          .disabled(executeDisabled)
        }
      }
      .task { await vm.loadIntegrations() }
    }
    .presentationDetents([.medium, .large])
  }

  // MARK: - Integration picker

  @ViewBuilder
  private var integrationSection: some View {
    if vm.availableIntegrations.count > 1 {
      Section {
        Picker("Integration", selection: Binding(
          get: { vm.selectedIntegration },
          set: { newValue in Task { await vm.changeIntegration(newValue) } }
        )) {
          ForEach(vm.availableIntegrations, id: \.self) { id in
            Label(integrationName(id), systemImage: integrationIcon(id))
              .tag(id)
          }
        }
      }
    }
  }

  // MARK: - Per-integration fields

  @ViewBuilder
  private var fieldsSection: some View {
    Section {
      if vm.selectedIntegration == .gmail {
        TextField("To (e.g. mike@acme.com)", text: $vm.editableRecipient)
          .textInputAutocapitalization(.never)
          .keyboardType(.emailAddress)
        TextField("Subject", text: $vm.editableSubject)
        TextField("Body", text: $vm.editableBody, axis: .vertical)
          .lineLimit(3...8)
      } else {
        TextField("Title", text: $vm.editableTitle)

        if vm.selectedIntegration == .calendar || vm.selectedIntegration == .googleCalendar {
          DatePicker("Start", selection: tiedStartDateBinding, displayedComponents: [.date, .hourAndMinute])
          DatePicker("End", selection: $vm.editableEndDate, displayedComponents: [.date, .hourAndMinute])
        } else {
          TextField("Due date (e.g. Friday, tomorrow)", text: $vm.editableDueDate)
        }

        if !vm.availableLists.isEmpty {
          Picker(listLabel, selection: $vm.selectedList) {
            ForEach(vm.availableLists, id: \.self) { list in
              Text(list).tag(list)
            }
          }
        }

        if vm.selectedIntegration == .todoist {
          Picker("Priority", selection: $vm.editablePriority) {
            Text("None").tag(0)
            Text("P1 (urgent)").tag(4)
            Text("P2").tag(3)
            Text("P3").tag(2)
            Text("P4 (low)").tag(1)
          }
        }

        if vm.selectedIntegration == .calendar || vm.selectedIntegration == .googleCalendar {
          TextField("Attendees (comma-separated emails)", text: $vm.editableAttendees)
            .textInputAutocapitalization(.never)
            .keyboardType(.emailAddress)
        }

        TextField("Notes (optional)", text: $vm.editableNotes)
      }
    }
  }

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

  /// Gmail's "title" is its subject; everything else uses editableTitle.
  /// Don't block on the body being empty — a draft with just a subject is
  /// fine to save (the user can fill it in later in Gmail).
  private var executeDisabled: Bool {
    if vm.isExecuting { return true }
    if vm.selectedIntegration == .gmail {
      return vm.editableSubject.isEmpty
    }
    return vm.editableTitle.isEmpty
  }

  private var listLabel: String {
    switch vm.selectedIntegration {
    case .todoist: "Project"
    case .calendar, .googleCalendar: "Calendar"
    default: "List"
    }
  }

  private var executeLabel: String {
    switch vm.selectedIntegration {
    case .todoist: "Add Task"
    case .calendar, .googleCalendar: "Add Event"
    case .gmail: "Save Draft"
    default: "Create"
    }
  }

  private func integrationName(_ id: Integration.Identifier) -> String {
    Integration.all.first { $0.identifier == id }?.name ?? id.rawValue
  }

  private func integrationIcon(_ id: Integration.Identifier) -> String {
    Integration.all.first { $0.identifier == id }?.systemImage ?? "questionmark.circle"
  }
}
