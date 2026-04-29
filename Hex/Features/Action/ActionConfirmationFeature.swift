import ComposableArchitecture
import Foundation
import HexCore

private let actionLogger = HexLog.action

@Reducer
struct ActionConfirmationFeature {
  @ObservableState
  struct State: Equatable {
    var intent: ActionIntent
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
    var isExecuting: Bool = false
    var error: String?

    init(intent: ActionIntent) {
      self.intent = intent
      self.selectedIntegration = intent.targetIntegration
      self.availableIntegrations = [intent.targetIntegration]
      self.editableTitle = intent.title
      self.editableDueDate = intent.dueDate ?? ""
      self.editableNotes = intent.notes ?? ""
      self.selectedList = intent.listName ?? ""
      self.editablePriority = intent.priority ?? 0
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
  }

  @Dependency(\.reminders) var reminders
  @Dependency(\.todoist) var todoist
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
        return .run { send in
          // Resolve which integrations are actually usable right now.
          let connected = IntegrationConnectionStore.decode(
            UserDefaults.standard.data(forKey: IntegrationConnectionStore.userDefaultsKey)
          )
          // Apple Reminders is always available (no setup required).
          var available: [Integration.Identifier] = [.appleReminders]
          if connected.contains(.todoist),
             let token = await keychain.read(KeychainKey.todoistAPIToken),
             !token.isEmpty {
            available.append(.todoist)
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
        // Refresh the list/project picker to match the chosen integration.
        return .run { [todoist, reminders] send in
          let lists: [String]
          switch integration {
          case .todoist:
            lists = await todoist.fetchProjects().map(\.name)
          case .appleReminders:
            lists = await reminders.fetchLists()
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

        return .run { [todoist, reminders, integration = state.selectedIntegration] send in
          do {
            let id: String
            switch integration {
            case .todoist:
              id = try await todoist.createTask(finalIntent)
            case .appleReminders:
              id = try await reminders.createReminder(finalIntent)
            default:
              throw ActionConfirmationError.unsupportedIntegration(integration)
            }
            await send(.executionSucceeded(id))
          } catch {
            actionLogger.error("Action execution failed for \(integration.rawValue, privacy: .public): \(error.localizedDescription)")
            await send(.executionFailed(error.localizedDescription))
          }
        }

      case .executionSucceeded:
        state.isExecuting = false
        soundEffect.play(.pasteTranscript)
        actionLogger.info("Action executed successfully")
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

enum ActionConfirmationError: LocalizedError {
  case unsupportedIntegration(Integration.Identifier)

  var errorDescription: String? {
    switch self {
    case .unsupportedIntegration(let id):
      "\(id.rawValue) integration is not configured."
    }
  }
}
