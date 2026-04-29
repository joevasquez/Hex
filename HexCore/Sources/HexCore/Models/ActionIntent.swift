import Foundation

public struct ActionIntent: Codable, Equatable, Sendable {
  public enum ActionType: String, Codable, Sendable {
    case createReminder
    case createTask
  }

  public var actionType: ActionType
  public var targetIntegration: Integration.Identifier
  public var title: String
  public var dueDate: String?
  public var notes: String?
  public var listName: String?
  /// Todoist priority: 1 (lowest) … 4 (highest). nil → use service default.
  public var priority: Int?

  public init(
    actionType: ActionType,
    targetIntegration: Integration.Identifier = .appleReminders,
    title: String,
    dueDate: String? = nil,
    notes: String? = nil,
    listName: String? = nil,
    priority: Int? = nil
  ) {
    self.actionType = actionType
    self.targetIntegration = targetIntegration
    self.title = title
    self.dueDate = dueDate
    self.notes = notes
    self.listName = listName
    self.priority = priority
  }
}

extension Integration.Identifier: Codable {}
