import ComposableArchitecture
import Foundation
import HexCore

private let actionLogger = HexLog.action

@Reducer
struct ActionConfirmationFeature {
  @ObservableState
  struct State: Equatable {
    var intent: ActionIntent
    /// Raw transcript that produced this intent — quoted in the
    /// confirmation panel's "HEARD" section.
    var rawTranscript: String
    var selectedIntegration: Integration.Identifier
    var availableIntegrations: [Integration.Identifier]
    var editableTitle: String
    var editableDueDate: String
    var editableNotes: String
    /// Names of available lists/projects for the current integration.
    var availableLists: [String] = []
    var selectedList: String = ""
    /// Todoist priority (1-4). 0 means "no priority set".
    var editablePriority: Int = 0
    /// Calendar event start (for DatePicker).
    var editableStartDate: Date = Date()
    /// Calendar event end (for DatePicker).
    var editableEndDate: Date = Date().addingTimeInterval(3600)
    /// Calendar event attendees (comma-separated emails).
    var editableAttendees: String = ""
    /// Gmail draft recipient.
    var editableRecipient: String = ""
    /// Gmail draft subject line.
    var editableSubject: String = ""
    /// Gmail draft body text.
    var editableBody: String = ""
    var isExecuting: Bool = false
    var error: String?
    /// Set after the action is created or queued so the panel can flip
    /// to the success badge before it dismisses. Mirrors the iOS sheet
    /// so users get the same "this actually worked" confirmation on
    /// both platforms.
    var completion: Completion?

    /// Result that drives the success badge view. Carries the
    /// integration + final title so the badge can render
    /// "Added to <Integration>" without re-deriving from the intent.
    /// `externalID` is the adapter-returned identifier (EventKit's
    /// `calendarItemIdentifier`, Todoist task id, etc.) — currently
    /// unused for the deep-link pill (we open the app root) but kept
    /// here so per-item links can land later without another state
    /// reshuffle.
    struct Completion: Equatable {
      enum Kind: Equatable { case created, queued }
      let kind: Kind
      let integration: Integration.Identifier
      let title: String
      let externalID: String?
    }

    init(intent: ActionIntent, rawTranscript: String = "") {
      self.intent = intent
      self.rawTranscript = rawTranscript
      self.selectedIntegration = intent.targetIntegration
      self.availableIntegrations = [intent.targetIntegration]
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

    /// Next top-of-the-hour from now (e.g. 2:43pm → 3:00pm).
    private static func defaultEventStart() -> Date {
      let cal = Calendar.current
      let now = Date()
      let components = cal.dateComponents([.year, .month, .day, .hour], from: now)
      let topOfHour = cal.date(from: components) ?? now
      return cal.date(byAdding: .hour, value: 1, to: topOfHour) ?? now
    }
  }

  enum Action: BindableAction {
    case binding(BindingAction<State>)
    case onAppear
    case integrationsLoaded([Integration.Identifier])
    case selectedIntegrationChanged(Integration.Identifier)
    case listsLoaded([String])
    case execute
    case cancel
    case executionSucceeded(String)
    case executionFailed(String)
    /// Network failure was caught and the intent was persisted to the
    /// offline queue. Treated as a soft success: panel dismisses, no
    /// scary error UI — the queue will retry on reconnect.
    case executionQueued
    /// Fired after the success badge has been on screen long enough to
    /// register. Posts the dismiss notification that closes the panel.
    case completionDismissed
  }

  @Dependency(\.reminders) var reminders
  @Dependency(\.todoist) var todoist
  @Dependency(\.calendarAdapter) var calendarAdapter
  @Dependency(\.gmailAdapter) var gmailAdapter
  @Dependency(\.googleCalendarAdapter) var googleCalendarAdapter
  @Dependency(\.googleOAuth) var googleOAuth
  @Dependency(\.keychain) var keychain
  @Dependency(\.soundEffects) var soundEffect

  var body: some ReducerOf<Self> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding:
        return .none

      case .onAppear:
        let initialIntegration = state.selectedIntegration
        return .run { [googleOAuth] send in
          let connected = IntegrationConnectionStore.decode(
            UserDefaults.standard.data(forKey: IntegrationConnectionStore.userDefaultsKey)
          )
          var available: [Integration.Identifier] = [.appleReminders, .calendar]
          if connected.contains(.todoist),
             let token = await keychain.read(KeychainKey.todoistAPIToken),
             !token.isEmpty {
            available.append(.todoist)
          }
          if await googleOAuth.isAuthorized() {
            if connected.contains(.googleCalendar) { available.append(.googleCalendar) }
            if connected.contains(.gmail) { available.append(.gmail) }
          }
          await send(.integrationsLoaded(available))
          await send(.selectedIntegrationChanged(initialIntegration))
        }

      case let .integrationsLoaded(integrations):
        state.availableIntegrations = integrations
        // If the LLM picked an unavailable integration, fall back to Reminders.
        if !integrations.contains(state.selectedIntegration) {
          state.selectedIntegration = .appleReminders
        }
        return .none

      case let .selectedIntegrationChanged(integration):
        state.selectedIntegration = integration
        return .run { [todoist, reminders, calendarAdapter, googleCalendarAdapter] send in
          let lists: [String]
          switch integration {
          case .todoist:
            lists = await todoist.fetchProjects().map(\.name)
          case .appleReminders:
            lists = await reminders.fetchLists()
          case .calendar:
            lists = await calendarAdapter.fetchCalendars()
          case .googleCalendar:
            lists = await googleCalendarAdapter.fetchCalendars().map(\.name)
          case .gmail:
            lists = []
          default:
            lists = []
          }
          await send(.listsLoaded(lists))
        }

      case let .listsLoaded(lists):
        state.availableLists = lists
        if !lists.contains(state.selectedList) {
          state.selectedList = lists.first ?? ""
        }
        return .none

      case .execute:
        state.isExecuting = true
        state.error = nil
        var finalIntent = state.intent
        finalIntent.targetIntegration = state.selectedIntegration
        finalIntent.title = state.editableTitle
        finalIntent.dueDate = state.editableDueDate.isEmpty ? nil : state.editableDueDate
        finalIntent.notes = state.editableNotes.isEmpty ? nil : state.editableNotes
        finalIntent.listName = state.selectedList.isEmpty ? nil : state.selectedList
        finalIntent.priority = state.editablePriority == 0 ? nil : state.editablePriority
        if state.selectedIntegration == .calendar || state.selectedIntegration == .googleCalendar {
          finalIntent.actionType = .createEvent
          finalIntent.startDate = state.editableStartDate
          finalIntent.endDate = state.editableEndDate
          let emails = state.editableAttendees
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
          finalIntent.attendees = emails.isEmpty ? nil : emails
        }
        if state.selectedIntegration == .gmail {
          finalIntent.actionType = .createDraft
          finalIntent.recipient = state.editableRecipient.isEmpty ? nil : state.editableRecipient
          finalIntent.subject = state.editableSubject.isEmpty ? nil : state.editableSubject
          finalIntent.notes = state.editableBody.isEmpty ? nil : state.editableBody
        }

        return .run { [todoist, reminders, calendarAdapter, gmailAdapter, googleCalendarAdapter, integration = state.selectedIntegration] send in
          do {
            let id: String
            switch integration {
            case .todoist:
              id = try await todoist.createTask(finalIntent)
            case .appleReminders:
              id = try await reminders.createReminder(finalIntent)
            case .calendar:
              id = try await calendarAdapter.createEvent(finalIntent)
            case .gmail:
              id = try await gmailAdapter.createDraft(finalIntent)
            case .googleCalendar:
              id = try await googleCalendarAdapter.createEvent(finalIntent)
            default:
              throw ActionConfirmationError.unsupportedIntegration(integration)
            }
            await send(.executionSucceeded(id))
          } catch {
            actionLogger.error("Action execution failed for \(integration.rawValue, privacy: .public): \(error.localizedDescription)")
            // Transient network errors → save to the offline queue so the
            // user's intent isn't lost. Permission / auth / validation
            // errors fall through to the existing failure path so the
            // user can fix them in the panel.
            if QueueableErrorClassifier.isQueueable(error) {
              await ActionQueueManager.shared.enqueue(finalIntent, lastError: error.localizedDescription)
              await send(.executionQueued)
            } else {
              await send(.executionFailed(error.localizedDescription))
            }
          }
        }

      case let .executionSucceeded(externalID):
        state.isExecuting = false
        soundEffect.play(.pasteTranscript)
        state.completion = .init(
          kind: .created,
          integration: state.selectedIntegration,
          title: completionTitle(state),
          externalID: externalID
        )
        actionLogger.info("Action executed successfully")
        return .run { send in
          // Hold the success badge long enough to be noticed before
          // the panel dismisses. Matches the iOS sheet beat (1.4 s).
          try? await Task.sleep(for: .milliseconds(1400))
          await send(.completionDismissed)
        }

      case .executionQueued:
        state.isExecuting = false
        soundEffect.play(.pasteTranscript)
        state.completion = .init(
          kind: .queued,
          integration: state.selectedIntegration,
          title: completionTitle(state),
          externalID: nil
        )
        actionLogger.info("Action queued for offline retry")
        // Soft-success: same beat as the success path, but the badge
        // shows "Saved offline" so the user knows we'll retry rather
        // than thinking it just disappeared.
        return .run { send in
          try? await Task.sleep(for: .milliseconds(1400))
          await send(.completionDismissed)
        }

      case .completionDismissed:
        return .run { _ in
          NotificationCenter.default.post(name: .actionConfirmationExecuted, object: nil)
        }

      case let .executionFailed(message):
        state.isExecuting = false
        state.error = message
        return .none

      case .cancel:
        soundEffect.play(.cancel)
        return .run { _ in
          NotificationCenter.default.post(name: .actionConfirmationCancelled, object: nil)
        }
      }
    }
  }
}

/// Pulls the right "what was created" title out of state for the
/// success badge. Gmail's title is its subject, every other integration
/// uses `editableTitle`. Falls back to `(untitled)` when blank so the
/// pill doesn't render as empty quotes.
private func completionTitle(_ state: ActionConfirmationFeature.State) -> String {
  if state.selectedIntegration == .gmail, !state.editableSubject.isEmpty {
    return state.editableSubject
  }
  return state.editableTitle.isEmpty ? "(untitled)" : state.editableTitle
}

enum ActionConfirmationError: LocalizedError {
  case unsupportedIntegration(Integration.Identifier)

  var errorDescription: String? {
    switch self {
    case .unsupportedIntegration(let id):
      "\(id.rawValue) integration is not configured."
    }
  }
}
